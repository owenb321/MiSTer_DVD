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
// with hold time via 4 tiers (bigger step = faster):
//   tier 0 (0-2s)  tier 1 (2-4.5s)  tier 2 (4.5-8s)  tier 3 (>8s)
//
// ★★ THE RATE IS A CONTENT RATE, NOT A FRACTION OF THE TITLE (2026-09-12).
// The header used to end "numbers are span-RELATIVE, so the feel is the same
// fraction-of-title on a 5-minute clip and a 3-hour epic; keep it that way."
// That sentence is the decision this module now overturns, and it was wrong in
// the one direction a user notices: a fraction of a SHORT title is a crawl.
// MEASURED at tier 0 with the old `span >> 12`: a 2 h feature moves 29 content-
// seconds per second, a 3-minute clip 0.58, a 30-second clip 0.19 -- the shorter
// the title, the slower the scrub, which is exactly backwards from what the
// gesture is for. Worse, the shift TRUNCATES what little is left: 15504 >> 12 is
// 3 and throws away 21 % of the step, 2584 >> 12 is 0 and throws away all of it
// (the `| 1` floor is what kept it moving at all, one sector per tick).
//
// So the step is now derived per SOURCE, and both answers are in content-seconds:
//
//   LINEAR (.mpg / VCD / SVCD, lin_rate_ok):  step = (lin_blk10 * 6) >> LSn
//     lin_blk10 is blocks per 10 s of file (dvd/lin_rate.sv -- exact CD geometry
//     for a raw image, a measured rate for a flat program stream), so the shift
//     IS the rate: 60 s / 2^LSn per tick = 1000 / 2^LSn content-seconds per
//     second, and {6,4,2,0} gives ~16 / 63 / 250 / 1000 s/s.
//     ★★ THE *6 IS NOT A FUDGE -- IT ALIGNS TWO LATTICES THAT OTHERWISE CANNOT
//     MEET. Unscaled, this path can only ever produce 166.7 / 2^n, while the DVD
//     path below produces 120000 / 2^m at the anchor; those differ by a factor of
//     720 = 2^9.49, i.e. HALF A POWER OF TWO, so no choice of SHn and LSn brings
//     them closer than 41%. Scaling the base by 6 moves this lattice onto that
//     one (worst case 7% apart, far inside the DVD side's own bucket spread) and
//     removes the NEGATIVE shifts the unscaled match would otherwise need for the
//     top tiers. It costs two shifts and an adder: 6x = (x<<2) + (x<<1).
//     ⚠ Gated on the rate being VALID, never on a zero slipping through -- the
//     dvd/dpad_seek.sv precedent (its own .lin_mode is ANDed with lin_blk10_ok).
//     An invalid rate falls back to the span path below.
//
//   DVD (a PGC title):  step = span >> (SHn + log2(title_secs) - SECS_REF)
//     span cancels out of the content rate ALGEBRAICALLY -- (span >> sh) divided
//     by (span / title_secs) is title_secs / 2^sh -- so biasing the shift by the
//     title's DURATION BUCKET fixes the rate without a divide and without ever
//     computing span / title_secs.
//     ⛔ Do NOT "improve" this into that divide. On a seamless-branch disc the
//     span contains the OTHER branch's ILVUs (885-1679 sectors/s against a ~600
//     ceiling, ALIEN_VS_PREDATOR_SE, issue #49), and that inflation hits the
//     bucketed shift and the divide IDENTICALLY -- the divide fixes nothing and
//     costs area. The area objection to a divide has expired (post-reclaim main
//     fits at ~87 %); area was never the load-bearing reason.
//     ★ SECS_REF = 12 is the ANCHOR: a title in [4096, 8192) seconds -- 68 to
//     136 minutes, i.e. every ordinary feature -- gets bias 0, so SHn means
//     exactly what it says there and shorter or longer titles bend around it.
//     title_secs == 0 (not yet known) also means bias 0.
//     ⚠⚠ THE ANCHOR NO LONGER MEANS "BIT-IDENTICAL TO WHAT SHIPPED", AND THAT IS
//     A DELIBERATE REVERSAL (maintainer, 2026-09-12: "these both should have the
//     same seek steps -- maybe we meet in the middle"). The first cut of this
//     module kept SHn = {12,10,8,6} precisely so a 2 h title's step was unchanged
//     from the hardware-signed-off build; but that pinned the DVD ladder at
//     29/117/469/1875 s/s while the linear one ran 5/21/83/167, and a tier that
//     means two different speeds depending on the source is the defect this
//     module exists to remove. Meeting in the middle costs the identity: the DVD
//     ladder is now HALVED at every tier. The anchor MECHANISM is untouched and
//     still load-bearing -- it is what makes the rate absolute rather than
//     span-relative; only its value moved.
//     ⚠ The bucket is a power of two, so within one bucket the DVD rate still
//     varies 2x with title length (a 68-minute title scrubs at 8.3 s/s in tier 0,
//     a 2h16 title at 16.7). That is inherent: correcting it means dividing by
//     title_secs, and the step is in SECTORS, so that is span/title_secs -- the
//     divide this design refuses. The DVD/linear gap is now SMALLER than this
//     residual spread, which is the honest place to stop.
//
// ★ THE LADDERS AND THE DWELLS ARE PARAMETERS (SH0..SH3, LS0..LS3, T1..T3), not
// magic numbers in a ternary, because this is a FEEL setting that gets retuned
// from hardware and every retune otherwise costs a hunt through four documents.
// The span ladder was relaxed once already (2026-09-03, user report "it ramps up
// too fast"): the old {10,8,6,5} / 1.5-3-5 s ladder moved ~2 MINUTES of a 2 h
// title per second even in tier 0 -- there was no fine-positioning tier at all,
// and 5 s of holding crossed 77 minutes.
// ★ THE TWO LADDERS NOW AGREE, which is the point: ~15 / 60 / 240 / 960
// content-seconds per second on a DVD and ~16 / 63 / 250 / 1000 on a linear
// file. x1..x4 of the tier means the same speed whatever is mounted.
// ⚠ If a hardware round wants the whole ramp faster or slower, move BOTH -- SHn
// and LSn step in lockstep (one shift = one factor of two on either side), and
// scrub_ctrl_tb's ladder-parity arm fails if they drift apart.
// If you retune, update dvd/dpad_seek.sv's header (it contrasts its fixed-time
// step against this one), docs/dvd_nav.md "Seeking / Phase 8a" and
// docs/transport_hud.md -- and NOT the user manual, which deliberately says only
// "it accelerates the longer you hold".
//
// See docs/dvd_nav.md "Seeking / Phase 8a" and memory phase8a-hold-to-seek-scrub.
// ============================================================================

module scrub_ctrl #(
    parameter T1     = 54_000_000,   // 2.0 s -> tier 1
    parameter T2     = 121_500_000,  // 4.5 s -> tier 2
    parameter T3     = 216_000_000,  // 8.0 s -> tier 3  (hold_cnt is 28 bits: max 268M)
    // ONE ladder, ~15 / 60 / 240 / 960 content-seconds per second, expressed
    // twice because the two sources measure the content differently.
    // DVD: step = span >> (SHn + duration bias) -- 120000 / 2^SHn s/s at the
    // anchor, so {13,11,9,7} = ~15/59/234/938.
    parameter SH0    = 5'd13,
    parameter SH1    = 5'd11,
    parameter SH2    = 5'd9,
    parameter SH3    = 5'd7,
    // Linear: step = (lin_blk10 * LIN_K) >> LSn -- 1000 / 2^LSn s/s with
    // LIN_K = 6, so {6,4,2,0} = ~16/63/250/1000. ⚠ Move SHn and LSn TOGETHER:
    // one shift is one factor of two on either side, and they are only 7% apart
    // because LIN_K puts them on the same lattice (see the header).
    parameter LS0    = 5'd6,
    parameter LS1    = 5'd4,
    parameter LS2    = 5'd2,
    parameter LS3    = 5'd0,
    parameter LIN_K  = 3'd6,
    // The duration anchor: a title whose leading one sits at bit SECS_REF
    // (4096..8191 s = 68..136 min) takes SHn unbiased.
    parameter SECS_REF = 5'd12,
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

    // ---- what the span is WORTH, so the ramp can be a content rate ---------
    // title_secs: the PGC title's duration (dvd/seek_time.sv title_secs_o).
    // Only its leading-one position is used -- a bucket, never a divisor. 0 =
    // not known yet, which keeps the pre-2026-09-12 step.
    input  wire [15:0] title_secs,
    // lin_blk10 / lin_rate_ok: blocks per 10 s of a linear file and whether that
    // measurement can be trusted (dvd/lin_rate.sv). ⚠ Gate on the VALID flag,
    // never on the value -- a zero rate would pin the step at the `| 1` floor
    // and the scrub would look broken. Invalid = fall back to the span path.
    input  wire [23:0] lin_blk10,
    input  wire        lin_rate_ok,

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
    // the accumulate direction, for the transport icon. dvd/transport_hud.sv
    // draws the tier as 2..5 ARROWS; it printed "xN" until 2026-09-12, which was
    // the tier ordinal posing as a rate ("x1" for ~29x real time).
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
    wire [4:0] sh   = (tier == 2'd3) ? SH3 :
                      (tier == 2'd2) ? SH2 :
                      (tier == 2'd1) ? SH1 : SH0;
    wire [4:0] ls   = (tier == 2'd3) ? LS3 :
                      (tier == 2'd2) ? LS2 :
                      (tier == 2'd1) ? LS1 : LS0;

    // ---- the title's duration BUCKET: a priority encoder, no divide --------
    // secs_lz = floor(log2(title_secs)). Biasing the span shift by
    // (secs_lz - SECS_REF) makes the step track the title's LENGTH, which is
    // what turns a fraction-of-span into a content rate (see the header).
    wire [4:0] secs_lz = title_secs[15] ? 5'd15 : title_secs[14] ? 5'd14 :
                         title_secs[13] ? 5'd13 : title_secs[12] ? 5'd12 :
                         title_secs[11] ? 5'd11 : title_secs[10] ? 5'd10 :
                         title_secs[9]  ? 5'd9  : title_secs[8]  ? 5'd8  :
                         title_secs[7]  ? 5'd7  : title_secs[6]  ? 5'd6  :
                         title_secs[5]  ? 5'd5  : title_secs[4]  ? 5'd4  :
                         title_secs[3]  ? 5'd3  : title_secs[2]  ? 5'd2  :
                         title_secs[1]  ? 5'd1  : 5'd0;
    // Signed, and clamped at both ends: a very short title can drive the shift
    // below zero (there the whole title is one tick, which the span cap already
    // bounds), a very long one past the span's width.
    wire signed [7:0] sh_bias = $signed({3'd0, secs_lz}) - $signed({3'd0, SECS_REF});
    wire signed [7:0] sh_sum  = $signed({3'd0, sh}) + sh_bias;
    wire [4:0] sh_eff = (title_secs == 16'd0) ? sh :
                        (sh_sum < 8'sd0)      ? 5'd0 :
                        (sh_sum > 8'sd31)     ? 5'd31 : sh_sum[4:0];

    // The `| 1` floor stays on BOTH arms: a step that rounds to zero is a scrub
    // that does not move, which is how the 30-second case failed.
    wire [31:0] step_span = (span >> sh_eff) | 32'd1;
    // *6 before the shift, so the linear ladder lands on the DVD one. 24 bits of
    // rate times 6 needs 27; the product is taken at full width and only then
    // shifted, because doing it the other way round would throw away the low bits
    // the scaling exists to keep.
    wire [31:0] lin_scaled = {8'd0, lin_blk10} * {29'd0, LIN_K};
    wire [31:0] step_lin  = (lin_scaled >> ls) | 32'd1;
    wire [31:0] step      = lin_rate_ok ? step_lin : step_span;

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
