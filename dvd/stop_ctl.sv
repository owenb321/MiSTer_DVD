// ============================================================================
// dvd/stop_ctl.sv -- two-stage Stop + the pause/stop screensaver
// ============================================================================
// Two features in one module because they share a state: "the disc is loaded
// but nothing is playing right now".
//
// ---- STOP (B14) -- the authentic two-stage "resume stop" -------------------
// A real set-top player stops twice. The first press halts and REMEMBERS where
// you were ("press PLAY to resume"); the second forgets it, so the next PLAY
// starts the disc from the top.
//
// ★ This is built out of the EXISTING pause holds rather than a new halt path,
// which is what makes it cheap: `stopped` ORs into emu's pause_gov/pause_aud,
// so the governor freeze, the watchdog suppression (repeat_frame=31), the STC
// stall and the audio hold all come along for free and are already HW-proven
// for indefinite holds. Stage 1 therefore tears NOTHING down, and resuming is
// simply releasing the hold -- there is no bookmark to save, because nothing
// was lost.
//
// ⛔ Stage 2 must NOT go through a remount. The core cannot re-issue
// img_mounted to itself (that is a Main action), so "start the disc again" is
// a `restart` pulse into dvd_iso_reader.start / dvd_vm.start -- the image is
// still mounted, and the reader's `if (start)` re-inits to S_INIT and re-probes
// it. Unloading to the idle screen stays the OSD R0,Reset row; Stop is not that.
//
// ⚠ The restart fires on the PLAY after the second Stop, not on the second
// Stop itself -- otherwise "full stop" would immediately start playing again.
//
// ⚠ dvd_vm zeroes rsm_vts inside `if (start)`, so the restart pulse wipes the
// RSM bookmark. That is CORRECT for stage 2 ("position forgotten") and is
// exactly why stage 1 must not pulse it.
//
// ---- SCREENSAVER ----------------------------------------------------------
// After a few minutes paused or stopped, the bouncing idle logo takes over and
// any input dismisses it. Burn-in protection, which matters more here than on
// most cores because this one drives real CRTs.
//
// ⛔⛔ THE TRAP, and it is the whole design: do NOT clear media_seen to trigger
// this. That is the obvious route and it is wrong -- emu.sv derives
// `idle_wide = ~media_seen & disp_wide_q` into VIDEO_ARX/ARY, so clearing it
// mid-title flips the aspect and makes Main re-init the scaler (a resolution
// popup in the middle of a film; emu.sv says so at the media_seen latch). This
// module therefore changes NO playback state: `saver_on` is a pure display-layer
// verdict -- but emu consumes it in TWO roles, and this header used to name only
// the first:
//   1. it ORs into logo_vis            -- show the bouncing logo
//   2. it feeds pic_blank, which MASKS everything derived from the picture --
//      the decoded frame, subtitles, and the disc-menu button highlight
// Role 2 was missing until 2026-09-15 and the highlight burned in: a menu
// subpicture never expires on its own (spu_decode's menu_mode bypasses the STC
// show/hide window), so it sat on the blanked screen for the whole screensaver,
// and on Stop -- which has no timer at all -- indefinitely.
// ⚠ The layer is MASKED, not torn down. Nothing here or in spu_decode/nav_pci is
// reset, so `any_input` brings it back one clk_sys later, bit-identically. That
// is what preserves the HW-measured "dismissing it restored the bit-identical
// paused frame" property. The full layer table is docs/screensaver.md.
//
// ⚠ Value order on the OSD row is load-bearing: status[] powers up at zero, so
// index 0 IS the default. "5min" sits at index 0 deliberately -- a natural
// Off,2min,5min,10min list would ship the feature disabled and protect nobody.
// Re-ordering these later forces a "v,N" bump and resets every user's settings.
// ============================================================================

`default_nettype none

module stop_ctl #(
    parameter CLK_HZ = 27_000_000
) (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       stop_edge,        // B14 press
    input  wire       play_edge,        // B1 Pause press = PLAY while stopped
    input  wire       any_input,        // emu's vm_entropy_stir (any button/key edge)
    input  wire       start_streaming,  // fresh mount
    input  wire       media_seen,       // something is loaded
    input  wire       paused,           // emu's pause_q
    input  wire       resume_evt,       // a VM jump / chapter seek also resumes
    input  wire [1:0] saver_sel,        // O[48:47]: 0=5min 1=Off 2=2min 3=10min

    output reg        stopped,          // hold + blank the picture
    output wire       kept_o,           // 1 = stage 1 (position kept), for the HUD
    output reg        restart,          // one-cycle: re-start reader + VM from FP
    output reg        saver_on          // show the idle logo over everything
);

    // ---- two-stage stop ----------------------------------------------------
    // kept: 1 = a position is remembered (stage 1). 0 while stopped = stage 2,
    // "forgotten", so the next PLAY restarts the disc.
    reg kept;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stopped <= 1'b0;
            kept    <= 1'b0;
            restart <= 1'b0;
        end else begin
            restart <= 1'b0;                       // default: one-cycle pulse

            if (start_streaming) begin
                stopped <= 1'b0;
                kept    <= 1'b0;
            end else if (stop_edge && media_seen) begin
                // 1st press -> stopped, position kept. 2nd -> forget it.
                stopped <= 1'b1;
                kept    <= stopped ? 1'b0 : 1'b1;
            end else if (stopped && play_edge) begin
                stopped <= 1'b0;
                if (!kept) restart <= 1'b1;        // stage 2 -> boot from First Play
                kept    <= 1'b0;
            end else if (stopped && resume_evt) begin
                // a chapter skip / VM jump is also a resume; it names its own
                // destination, so it never wants the First-Play restart.
                stopped <= 1'b0;
                kept    <= 1'b0;
            end
        end
    end

    assign kept_o = kept;

    // ---- screensaver -------------------------------------------------------
    // Armed whenever nothing is moving on a loaded disc. The timer is a plain
    // 1 Hz prescaler + a seconds counter; nothing here schedules anything, so
    // it is deliberately a wall clock and not the STC.
    localparam [24:0] PRESCALE = CLK_HZ - 1;

    reg [24:0] pre;
    reg [9:0]  secs;

    // ⚠ A CONTINUOUS ASSIGN, not an always @(*) block. Icarus only triggers
    // always @(*) on a CHANGE, and a reg's declaration initialiser is not one,
    // so a bench that sets saver_sel once at time 0 and never touches it again
    // left `limit` (and therefore `armed`) reading X. `if (x)` takes the else
    // branch, so the counter still ran and the saver simply never armed --
    // failing only for whichever value the bench never re-assigned. Synthesis
    // was never affected; the simulation was silently wrong.
    wire [9:0] limit = (saver_sel == 2'd0) ? 10'd300 :   // 5 min  = index 0 = DEFAULT
                       (saver_sel == 2'd1) ? 10'd0   :   // Off
                       (saver_sel == 2'd2) ? 10'd120 :   // 2 min
                                             10'd600;    // 10 min

    wire armed = media_seen && (paused || stopped) && (limit != 10'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pre      <= 25'd0;
            secs     <= 10'd0;
            saver_on <= 1'b0;
        end else if (!armed || any_input || start_streaming) begin
            // Not armed, or the user did something: drop the saver and re-arm
            // the count from zero.
            pre      <= 25'd0;
            secs     <= 10'd0;
            saver_on <= 1'b0;
        end else begin
            if (pre >= PRESCALE) begin
                pre <= 25'd0;
                if (secs >= limit) saver_on <= 1'b1;
                else               secs     <= secs + 10'd1;
            end else begin
                pre <= pre + 25'd1;
            end
        end
    end

endmodule

`default_nettype wire
