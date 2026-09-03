/*
 * pal_detect.sv — the PAL/NTSC verdict, hardened against garbage sequence headers
 *
 * DVD-FORK (2026-09-03, issue #42 leg 2). Extracted from dvd/emu.sv so the rule is
 * testbenchable (bench/dvd/pal_detect_tb.sv). It decides ONE bit — "the content is
 * 50 Hz" — from the decoder's parsed frame height, and that bit is load-bearing far
 * out of proportion to its size:
 *
 *   pal_eff -> the runtime modeline walk (emu.sv): a change RESTARTS THE RASTER, and
 *              unlike an il_eff change it carries NO pipeline flush
 *           -> av_sync .refresh_50hz: the STC tick rate
 *           -> film_det = pal_eff ? det_pal : det_ntsc -> film_want -> filmp_eff,
 *              which kicks the SAME walk again
 *           -> the reader's disp_fps, the letterbox geometry, cc_vbi, the SPU pal_mode
 *
 * So a wrong verdict is not a cosmetic error: it re-fires the raster while the pipeline
 * is draining, and through film_det it can re-fire it AGAIN. That is the self-feeding
 * corruption loop the reverted film-switch attempt died of (docs/film_24p_plan.md §13),
 * and issue #42's freeze is reached through the same amplifier.
 *
 * ★ WHY THE OLD RULE WAS NOT ENOUGH. It was two lines:
 *
 *     if (!reset_n)                 pal_detect_dec <= 1'b0;
 *     else if (vertical_size != 0)  pal_detect_dec <= (vertical_size > 480) || (== 288);
 *
 * The `!= 0` guard was added 2026-09-03 for a real bug — vertical_size is a VLD register
 * on sync_rst, so every watchdog expiry and mount soft reset zeroed it and a PAL disc
 * read "NTSC" for the gap until the next header. But it only masks ZERO. Any NON-ZERO
 * garbage height — the 186-wide resolution popups a mid-VOBU flush produces — flipped the
 * verdict on the spot, from one header, with no way back until the next one.
 *
 * ★ THE TWO TERMS THIS ADDS.
 *
 * (1) A PLAUSIBILITY BOUND. Outside 64..1152 lines is not a verdict, it is a parse error:
 *     hold, exactly as zero does. A BOUND and deliberately not a whitelist of
 *     {240,288,480,576} — the core also plays flat .mpg files, and a whitelist would hold
 *     the verdict on any unusual-but-real height. 1080 is not a multiple of 16, so do NOT
 *     "tighten" this with a multiple-of-16 test either.
 *
 * (2) A SUSTAINED DISAGREEMENT IS REQUIRED TO *CHANGE* AN ESTABLISHED VERDICT. The first
 *     plausible header after a mount latches IMMEDIATELY — PAL detection must not be
 *     delayed at load, or every PAL disc pays a spurious NTSC->PAL walk. After that, a
 *     disagreeing height must still be the parsed height HOLD_CYC cycles later.
 *
 * ⚠ WHY A TIMER AND NOT "N CONSECUTIVE HEADERS" (the design that was tried first and is
 * WRONG). vertical_size is a REGISTER, not an event: a real disc re-parses a sequence
 * header every GOP but writes the SAME value, so the register does not change and there
 * is no observable header event to count. A transition-counting rule can therefore never
 * reach N for a genuine change — the verdict would freeze forever. Counting time against
 * the value that is actually in force has neither problem, and it is the right shape
 * anyway: garbage is TRANSIENT (the next real header overwrites it within a GOP), a real
 * standard is PERSISTENT. Any change of the parsed height abandons the candidate, so a
 * burst of DIFFERENT garbage values never accumulates.
 *
 * Cost: HOLD_CYC must exceed one GOP comfortably. ~0.5 s at clk_dec (81 MHz) is ~15 GOPs.
 * A genuine mid-stream standard change is only reachable across a title/VTS jump, which
 * brings its own flush, so half a second of the old raster there is not a regression.
 */

`default_nettype none

module pal_detect #(
    parameter [26:0] HOLD_CYC = 27'd40_500_000   // ~0.5 s @ 81 MHz clk_dec
) (
    input  wire        clk,          // clk_dec (the domain vsize is parsed in)
    input  wire        rst_n,        // core reset_n, async active-low
    input  wire        mount_arm,    // a new file was mounted: the standard may
                                     // legitimately differ -> re-arm the immediate latch
                                     // (2-FF synced mount_flush; MOUNT only, never
                                     //  load_flush -- that also fires on a mode switch,
                                     //  i.e. exactly when the parse is least trustworthy)
    input  wire [13:0] vsize,        // decoder vertical_size_out (0 = no header in force)

    output reg         pal           // the held verdict: 1 = 50 Hz content
);

// A plausible parsed height, and what it would mean.
// MPEG-1 PAL SIF is 352x288 (288 = half of 576), which a bare ">480" test misses; MPEG-1
// NTSC SIF is 240, neither >480 nor 288, so it correctly stays NTSC.
wire vs_plaus = (vsize >= 14'd64) && (vsize <= 14'd1152);
wire vs_pal   = (vsize > 14'd480) || (vsize == 14'd288);

reg         pal_init;        // a verdict has been established for this file
reg  [13:0] cand;            // the disagreeing height being timed
reg  [26:0] tmr;             // 0 = no candidate armed; else cycles it has held

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pal      <= 1'b0;
        pal_init <= 1'b0;
        cand     <= 14'd0;
        tmr      <= 27'd0;
    end else if (mount_arm) begin
        // Re-arm only. `pal` deliberately KEEPS the previous verdict until the new file's
        // first header: the mount soft reset zeroes vsize, and blanking the verdict here
        // would read "NTSC" across that gap and fire the very walk this module exists to
        // prevent. Same reasoning as the `!= 0` hold it replaces.
        pal_init <= 1'b0;
        tmr      <= 27'd0;
    end else if (!pal_init) begin
        if (vs_plaus) begin
            pal      <= vs_pal;      // first verdict of the file: latch at once
            pal_init <= 1'b1;
            tmr      <= 27'd0;
        end
    end else begin
        if (!vs_plaus || (vs_pal == pal))
            tmr  <= 27'd0;                                   // no header / already agrees
        else if ((tmr == 27'd0) || (vsize != cand)) begin
            cand <= vsize;                                   // arm (or re-arm on a change)
            tmr  <= 27'd1;
        end else if (tmr >= HOLD_CYC) begin
            pal  <= vs_pal;                                  // held long enough: believe it
            tmr  <= 27'd0;
        end else
            tmr  <= tmr + 27'd1;
    end
end

endmodule

`default_nettype wire
