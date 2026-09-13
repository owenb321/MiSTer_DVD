// ============================================================================
// dvd/aspect_ctl.sv -- the Aspect button (B15)
// ============================================================================
// A real remote has an aspect / "wide-normal" key. This core has TWO aspect
// controls, and which one is live depends on the output in use:
//
//   Aspect Ratio  O[20:19]  Auto / 4:3 / 16:9   -- the scaler aspect (HDMI)
//   Analog Aspect O[4:3]    Auto / Fit / Letterbox / Crop
//                                               -- the raster rescale, and it
//                                                  is gated on interlaced_eff,
//                                                  so it does NOTHING at all in
//                                                  Progressive or on an
//                                                  HDMI-only rig.
//
// Binding the button to Analog Aspect alone would therefore read as a dead
// button to most users. It cycles whichever control is actually live instead:
// Analog Aspect while the analog raster is engaged, Aspect Ratio otherwise.
//
// ⛔ THE CORE CANNOT WRITE status[]. dvd/dvd_telem.sv records why: stock Main
// polls UIO_GET_STATUS every frame and writes the result straight into
// cur_status, so a core driving status_in would overwrite the user's own OSD
// settings. This module therefore holds an OVERRIDE that emu muxes in front of
// status[], rather than trying to change status[] itself.
//
// ★ THE OSD STILL WINS WHEN THE USER TOUCHES IT. The override is surrendered on
// any change to the underlying status bits, so the OSD and the button cannot
// fight: whichever was touched most recently is in charge. That is the same
// shape as emu's vm_owns_aud / vm_owns_sp arbitration, which exists because a
// HW round found a menu selection permanently locking out its button.
//
// ⚠⚠ THE HAZARD THIS MODULE MOSTLY EXISTS TO CONTAIN: every VIDEO_ARX/ARY
// change makes the framework re-init the scaler and pop a resolution notice,
// and emu.sv warns twice that a FLAPPING value means video never stabilises at
// all. A user mashing this button would otherwise produce one re-init per
// press. The verdict is therefore SETTLED: presses move an internal target
// freely (so the HUD can show every step), but the published value only follows
// once the button has been quiet for SETTLE_MS.
// ============================================================================

`default_nettype none

module aspect_ctl #(
    parameter CLK_HZ    = 27_000_000,
    parameter SETTLE_MS = 250
) (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       aspct_edge,     // B15 press
    input  wire       analog_live,    // the analog raster is engaged
    input  wire [1:0] osd_ar,         // status[20:19]  Aspect Ratio
    input  wire [1:0] osd_aa,         // status[4:3]    Analog Aspect

    output wire [1:0] ar_sel,         // effective Aspect Ratio  (3 values: 0..2)
    output wire [1:0] aa_sel,         // effective Analog Aspect (4 values: 0..3)
    output reg        evt,            // one-cycle: the target moved (HUD popup)
    output reg        evt_analog,     // which control moved, valid at evt
    output reg  [1:0] evt_val         // the value it is MOVING TO, valid at evt
);

    localparam integer SETTLE_TICKS = (CLK_HZ / 1000) * SETTLE_MS;

    reg [1:0] ar_t, aa_t;             // targets: move on every press
    reg [1:0] ar_p, aa_p;             // published: follow once settled
    reg       ar_own, aa_own;         // 1 = the button owns this control
    reg [1:0] osd_ar_q, osd_aa_q;
    reg [31:0] settle;

    // The button owns the value only while ar_own/aa_own; otherwise the OSD's
    // own bits pass straight through, so a fresh core (or a user who just
    // touched the OSD) behaves exactly as before this module existed.
    assign ar_sel = ar_own ? ar_p : osd_ar;
    assign aa_sel = aa_own ? aa_p : osd_aa;

    // Aspect Ratio has THREE values (Auto/4:3/16:9) and Analog Aspect FOUR
    // (Auto/Fit/Letterbox/Crop), so the wrap differs -- a shared 2-bit
    // increment would offer a 4th Aspect Ratio value the OSD does not have.
    wire [1:0] ar_next = (ar_t == 2'd2) ? 2'd0 : ar_t + 2'd1;
    wire [1:0] aa_next = aa_t + 2'd1;            // natural 2-bit wrap = 4 values

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_t <= 2'd0; aa_t <= 2'd0;
            ar_p <= 2'd0; aa_p <= 2'd0;
            ar_own <= 1'b0; aa_own <= 1'b0;
            osd_ar_q <= 2'd0; osd_aa_q <= 2'd0;
            settle <= 32'd0;
            evt <= 1'b0; evt_analog <= 1'b0; evt_val <= 2'd0;
        end else begin
            evt      <= 1'b0;
            osd_ar_q <= osd_ar;
            osd_aa_q <= osd_aa;

            // The OSD reclaims its control the moment the user changes it.
            if (osd_ar != osd_ar_q) ar_own <= 1'b0;
            if (osd_aa != osd_aa_q) aa_own <= 1'b0;

            if (aspct_edge) begin
                evt        <= 1'b1;
                evt_analog <= analog_live;
                settle     <= SETTLE_TICKS[31:0];
                if (analog_live) begin
                    // ⚠ Taking ownership and publishing are SEPARATE. aa_own
                    // gates the output immediately, so aa_p must already hold
                    // what is on screen RIGHT NOW -- otherwise the first press
                    // would snap the picture to a stale published value (0 =
                    // Auto after reset) before the settle window even opened,
                    // i.e. the exact mid-film scaler re-init this module exists
                    // to prevent. Seed it from the OSD on the press that claims
                    // ownership; the target moves on ahead of it.
                    if (!aa_own) aa_p <= osd_aa;
                    aa_t    <= aa_own ? aa_next
                                      : ((osd_aa == 2'd3) ? 2'd0 : osd_aa + 2'd1);
                    evt_val <= aa_own ? aa_next
                                      : ((osd_aa == 2'd3) ? 2'd0 : osd_aa + 2'd1);
                    aa_own  <= 1'b1;
                end else begin
                    if (!ar_own) ar_p <= osd_ar;
                    ar_t    <= ar_own ? ar_next
                                      : ((osd_ar >= 2'd2) ? 2'd0 : osd_ar + 2'd1);
                    evt_val <= ar_own ? ar_next
                                      : ((osd_ar >= 2'd2) ? 2'd0 : osd_ar + 2'd1);
                    ar_own  <= 1'b1;
                end
            end else if (settle != 32'd0) begin
                settle <= settle - 32'd1;
                // publish exactly once, on the last tick of the quiet window
                if (settle == 32'd1) begin
                    ar_p <= ar_t;
                    aa_p <= aa_t;
                end
            end
        end
    end

endmodule

`default_nettype wire
