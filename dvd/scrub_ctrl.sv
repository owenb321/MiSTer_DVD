// ============================================================================
// dvd/scrub_ctrl.sv -- Hold-to-seek, SEEK-ON-RELEASE with a position indicator
// ============================================================================
// Hold the Fast Fwd/Rewind buttons (in a playing title) to choose a seek target,
// then release to jump there. (These are dedicated gamepad buttons, NOT the
// D-pad -- the D-pad stays free for directional menu/game navigation so seeking
// never conflicts with a game that wants left/right input over seekable video.
// ★ AMENDED: that exclusion is now CONDITIONAL, not absolute. The opt-in
// O[45] "D-Pad Seek" toggle -- default OFF, so the guarantee above still holds
// out of the box -- routes D-pad presses through dvd/dpad_seek.sv, which
// resolves a FIXED-TIME target from the disc's DSI tables and hands it to the
// JUMP MODE below. The held scrub itself remains exclusively FF/REW.)
// While held the video simply PAUSES (a plain, proven
// freeze -- no repeated flushing) and a target cursor moves along the on-screen
// position bar, ACCELERATING the longer the button is held. On release ONE
// raw-RBN seek is issued (the known-good single-seek path).
//
// ★ WHY SEEK-ON-RELEASE (HW rounds 1-2 dead end, 2026-07-10): the MPEG-2 decoder
// has a ~1-2 MB VBUF cushion + a watchdog and is built for CONTINUOUS playback.
// A live "still scan" that flushes + re-locks on every hop fought that latency:
// it re-flushed before any frame displayed (mostly black), played in the gaps
// (motion + audio), and the un-frozen ~1 s re-lock window tripped the watchdog
// (720x179 resync / black). Seek-on-release avoids all of it -- holding is just a
// pause, and there is exactly ONE flush/re-lock, on release. The user sees where
// they are going via the position bar (dvd/seek_bar.sv), not live frames.
//
// Position math is sector/RBN-based against the title's VTSTT_VOBS span
// (title_first_rbn..title_last_rbn from the reader). The accumulated offset grows
// with hold time via the same 4 tiers as before (bigger step = faster):
//   tier 0 (0-1.5s)  tier 1 (1.5-3s)  tier 2 (3-5s)  tier 3 (>5s)
//   step = span >> {10, 8, 6, 5} sectors per tick (~each ~0.06 s).
//
// See docs/dvd_nav.md "Seeking / Phase 8a" and memory phase8a-hold-to-seek-scrub.
// ============================================================================

module scrub_ctrl #(
    parameter T1     = 40_500_000,   // 1.5 s -> tier 1
    parameter T2     = 81_000_000,   // 3.0 s -> tier 2
    parameter T3     = 135_000_000,  // 5.0 s -> tier 3
    parameter TICK   = 1_620_000,    // ~0.06 s accumulate tick
    parameter LINGER = 40_000_000    // ~1.5 s show the bar after release
) (
    input  wire        clk,             // clk_sys (27 MHz)
    input  wire        rst_n,

    input  wire        held_right,      // Fast Fwd button = seek forward
    input  wire        held_left,       // Rewind   button = seek backward
    input  wire        in_title,        // cell_ready && !menu_active

    input  wire [31:0] cur_rbn,         // live playhead RBN (nav_dsi.dsi_nv_pck_lbn)
    input  wire [31:0] title_first_rbn, // title span (reader)
    input  wire [31:0] title_last_rbn,

    // ---- JUMP MODE (dvd/dpad_seek.sv, O[45]) ------------------------------
    // A pre-resolved one-shot seek: dpad_seek has already turned "+30 s" into a
    // sector offset against a SPECIFIC VOBU, so it supplies its own base rather
    // than letting us re-sample cur_rbn (the two must come from the same VOBU or
    // the target is nonsense -- see the stale-table note in dpad_seek.sv). We
    // add the title-span clamp, the bar/linger, and the single seek issue.
    input  wire        jump_fire,       // 1-cyc: resolved, go
    input  wire        jump_dir,        // 1 = forward
    input  wire [31:0] jump_base,       // base the offset was resolved against
    input  wire [31:0] jump_off,        // magnitude (sectors / linear blocks)

    // ONE raw-RBN seek, issued on release.
    output reg         seek_rbn_pulse,
    output reg  [31:0] seek_rbn,

    // Freeze the video (plain pause) while a direction is held.
    output wire        hold_freeze,

    // Position bar (dvd/seek_bar.sv): shown while held + a short linger.
    output wire        bar_active,
    output reg  [31:0] bar_base_rbn,    // playhead when the hold began (bar fill)
    output wire [31:0] bar_tgt_rbn,     // pending/landed seek target (bar cursor)

    // Phase 11 HUD: speed tier (0..3, registered for a glitch-free readout) and
    // the accumulate direction, for the transport icon (>> x1..x4 / << x1..x4).
    output reg  [1:0]  hud_tier,
    output wire        hud_dir          // 1 = forward
);

    // ---- want / direction -------------------------------------------------
    wire want_fwd = in_title && held_right && ~held_left;
    wire want_bwd = in_title && held_left  && ~held_right;
    wire want     = want_fwd || want_bwd;
    wire want_dir = want_fwd;                 // 1 = forward
    assign hold_freeze = want;                // pause while held

    reg        want_q;
    wire       want_rise = want && ~want_q;
    wire       want_fall = ~want && want_q;

    // ---- hold-time ramp -> tier -> accumulate step ------------------------
    reg  [27:0] hold_cnt;
    wire [1:0] tier = (hold_cnt >= T3) ? 2'd3 :
                      (hold_cnt >= T2) ? 2'd2 :
                      (hold_cnt >= T1) ? 2'd1 : 2'd0;
    wire [31:0] span = (title_last_rbn > title_first_rbn)
                       ? (title_last_rbn - title_first_rbn) : 32'd1;
    wire [4:0] sh   = (tier == 2'd3) ? 5'd5 :
                      (tier == 2'd2) ? 5'd6 :
                      (tier == 2'd1) ? 5'd8 : 5'd10;
    wire [31:0] step = (span >> sh) | 32'd1;  // >=1 sector/tick

    reg  [31:0] pending_off;                   // magnitude (sectors), 0..span
    reg         pending_dir;                   // 1 = forward
    reg  [20:0] tick_cnt;

    // target = base ± pending_off, clamped into [first, last].
    wire [31:0] tgt_raw = pending_dir
                        ? (bar_base_rbn + pending_off)
                        : ((bar_base_rbn > pending_off) ? (bar_base_rbn - pending_off) : title_first_rbn);
    wire [31:0] target  = (tgt_raw > title_last_rbn)  ? title_last_rbn  :
                          (tgt_raw < title_first_rbn) ? title_first_rbn : tgt_raw;

    reg  [31:0] released_tgt;                   // latched at release (for the linger)
    reg  [25:0] linger_cnt;
    reg         jump_go;                        // 1-cyc staging (see below)
    assign bar_active  = want || jump_go || (linger_cnt != 26'd0);
    assign bar_tgt_rbn = want ? target : released_tgt;
    assign hud_dir     = pending_dir;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            want_q <= 1'b0; hold_cnt <= 28'd0; pending_off <= 32'd0; pending_dir <= 1'b0;
            tick_cnt <= 21'd0; bar_base_rbn <= 32'd0; released_tgt <= 32'd0;
            linger_cnt <= 26'd0; seek_rbn_pulse <= 1'b0; seek_rbn <= 32'd0;
            hud_tier <= 2'd0; jump_go <= 1'b0;
        end else begin
            want_q <= want;
            hud_tier <= tier;
            seek_rbn_pulse <= 1'b0;             // default: one-cycle pulse
            if (linger_cnt != 26'd0) linger_cnt <= linger_cnt - 26'd1;

            if (!want) hold_cnt <= 28'd0;
            else if (hold_cnt < T3) hold_cnt <= hold_cnt + 28'd1;

            if (want_rise) begin
                // start a new seek gesture: freeze here, reset the accumulator.
                bar_base_rbn <= cur_rbn;
                pending_off  <= 32'd0;
                pending_dir  <= want_dir;
                tick_cnt     <= TICK[20:0];
                linger_cnt   <= 26'd0;
            end else if (want) begin
                if (want_dir != pending_dir) begin
                    // direction flip -> restart the accumulation the other way.
                    pending_dir <= want_dir; pending_off <= 32'd0; tick_cnt <= TICK[20:0];
                end else if (tick_cnt == 21'd0) begin
                    tick_cnt <= TICK[20:0];
                    if (pending_off + step >= span) pending_off <= span;   // cap at span
                    else                            pending_off <= pending_off + step;
                end else begin
                    tick_cnt <= tick_cnt - 21'd1;
                end
            end

            if (want_fall) begin
                released_tgt <= target;
                linger_cnt   <= LINGER[25:0];
                if (pending_off != 32'd0) begin
                    seek_rbn <= target; seek_rbn_pulse <= 1'b1;   // ONE seek on release
                end
                pending_off <= 32'd0;
            end

            // ---- JUMP MODE ------------------------------------------------
            // A held FF/REW gesture always wins: jump_ok requires want_q==0, so
            // this is mutually exclusive with want_rise/want/want_fall above.
            // The one-cycle jump_go stage is LOAD-BEARING -- `target` is
            // combinational off the pending_off/pending_dir/bar_base_rbn
            // REGISTERS, so it cannot be consumed in the cycle that writes them.
            if (jump_fire && in_title && !want && !want_q) begin
                bar_base_rbn <= jump_base;
                pending_dir  <= jump_dir;
                pending_off  <= jump_off;
                jump_go      <= 1'b1;
            end else if (jump_go) begin
                jump_go <= 1'b0;
                if (!want) begin
                    seek_rbn     <= target;  seek_rbn_pulse <= 1'b1;
                    released_tgt <= target;  linger_cnt     <= LINGER[25:0];
                end
                pending_off <= 32'd0;
            end
        end
    end

endmodule
