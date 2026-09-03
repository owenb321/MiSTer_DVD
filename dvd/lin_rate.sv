// ============================================================================
// dvd/lin_rate.sv -- how fast a LINEAR file plays, and what time it is
// ============================================================================
// Two jobs for non-DVD playback, sharing one serial arithmetic engine:
//
//   1. blk10   -- blocks per 10 s of file, the step dvd/dpad_seek.sv needs to
//                 turn "+10 s" into a raw-RBN target (issue #39).
//   2. cur/total/prev_time -- an elapsed / total / seek-preview clock for the
//                 transport HUD, which read 0:00:00 in linear modes until now.
//
// ★ RAW VCD/SVCD IS A COMBINATIONAL BYPASS, NOT A MEASUREMENT. A CD plays at a
// fixed 75 sectors/s of 2352 B, which over the reader's 2048-byte linear block
// unit is 86.13 blk/s => 861 blocks per 10 s EXACTLY, whatever the MPEG inside
// does. So raw_mode routes BLK10_RAW straight out with no FSM and no reset
// dependency: dpad_seek sees the identical constant with the identical timing
// it saw when 861 was a parameter inside it. That is deliberate -- it makes
// this module a structural no-op on the one path that already worked.
//
// ★ WHY MEASURE PTS AGAINST BLOCKS, AND NOT A WALL CLOCK. A flat .mpg/.VOB has
// no seek tables and no fixed geometry, so its rate has to be measured. Both
// lin_blk (the reader's fetch front) and vid_pts (the demux's parse front) are
// STREAM POSITIONS, and the reader's cache is 16 KB = 8 blocks, so they never
// separate by more than that. Buffer fill, pause, STD backpressure and governor
// drops therefore move the two fronts TOGETHER, and their ratio stays the true
// file rate through every one of them -- no gating needed, and the estimate
// arms in far less wall time than its window suggests because a startup burst
// advances PTS fast. A sec_tick block count would need explicit gating against
// each of those, and would inherit the display governor's own rate error.
//
// ⛔ REJECTED, so nobody re-proposes them:
//   - program_mux_rate from the pack header. Arms instantly and is exact on
//     CBR, but it needs surgery in ps_demux -- the one module every DVD, VCD
//     and flat path runs through -- it is the PEAK rate on VBR (so every jump
//     would undershoot), and MPEG-1 and MPEG-2 packs put it at different
//     offsets and widths.
//   - SCR. Same ps_demux objection, buys nothing PTS does not.
//   - PTS-derived elapsed for the clock. Exact even on VBR, but it would
//     disagree with a rate-derived seek bar and a rate-derived +/-10 s jump: on
//     a VBR file a "+10 s" would move the clock by something other than 10 s,
//     which reads as broken. One model keeps clock, bar and D-pad coherent, and
//     coherence is worth more here than absolute accuracy.
//
// ★ THE RATIO IS DIVIDED, NOT SCALED BY A SHIFT. A window closes on the first
// vid_pts sample at or past its length, and PTS samples are a picture apart
// (~3003 ticks), so d_pts OVERSHOOTS -- by up to 6.7% of the 0.5 s arm window.
// Scaling d_blk by a fixed factor would bake that in as a SYSTEMATIC
// over-estimate of the rate. Dividing by the measured d_pts costs one pass of a
// serial engine this module needs for the clock anyway, and is exact.
//
// ★ RESET DOMAIN: reset_n, NEVER pipe_rst_n. pipe_rst_n pulses on load_flush,
// which is exactly what a D-pad seek causes -- on that domain the estimate
// would be wiped by every jump and the next tap refused, the same trap
// dpad_seek's own reset_n comment exists to avoid. `flush` here restarts only
// the measurement WINDOW (the position jumped; the file's rate did not change);
// only `mount` clears the estimate.
//
// ★ FIT DISCIPLINE (the parse_buf 226%-ALM incident): this module holds NO
// arrays and uses NO *, / or % operator. Every product and quotient is one pass
// of the shared serial engine below.
//
// KNOWN CHARACTERISTICS (documented, not bugs) -- docs/vcd_svcd.md 3a:
//  - The clock is a rate MODEL, not a decoded timecode. On a bursty VBR file
//    the elapsed reading drifts against real time within the file; it always
//    agrees with the seek bar and with a D-pad jump, by construction.
//  - It LEADS the picture by the decoder VBUF (~1-3 s), because lin_blk is the
//    reader's fetch front -- the same characteristic the DVD c_eltm readout has.
//  - A stream whose video is not stream_id 0xE0 never asserts vid_pts_valid, so
//    it never arms: the D-pad stays inert and the clock stays 0, i.e. exactly
//    today's behaviour. An aud_pts fallback is cheap but deliberately not built
//    (area, and mixing two PTS timelines into one window adds error).
//  - total_time on a raw CD image is file-length based, so a single-bin image
//    with a leading ISO track reads slightly long.
// ============================================================================
`default_nettype none

module lin_rate #(
    // Window lengths in 90 kHz PTS ticks. The first is short so the D-pad is
    // usable almost immediately after a load; later ones are long so the
    // estimate is stable.
    parameter [31:0] WIN_ARM   = 32'd45_000,      // 0.5 s
    parameter [31:0] WIN_REF   = 32'd720_000,     // 8 s
    parameter [31:0] PTS_MAX   = 32'd1_800_000,   // >20 s in one window = a
                                                  // discontinuity, not a rate
    parameter [31:0] DBLK_MAX  = 32'd131_072,     // 256 MB in one window ditto
    parameter [23:0] BLK10_RAW = 24'd861,         // 75*2352/2048*10, exact CD
    parameter [23:0] BLK10_MIN = 24'd100,         // ~20 KB/s  -- reject below
    parameter [23:0] BLK10_MAX = 24'd12_000,      // ~2.4 MB/s -- reject above
    parameter [15:0] SEC_CAP   = 16'd35_999       // 9:59:59, the widest readout
) (
    input  wire        clk,
    input  wire        rst_n,           // reset_n -- NOT pipe_rst_n (see above)
    input  wire        en,              // linear playback active
    input  wire        raw_mode,        // 1 = raw MODE2/2352 CD image
    input  wire        mount,           // start_streaming: drop the estimate
    input  wire        flush,           // load_flush: restart the window only
    input  wire        sec_tick,        // 1 Hz: recompute the clock

    input  wire [32:0] vid_pts,
    input  wire        vid_pts_valid,
    input  wire [31:0] lin_blk,         // reader fetch front, 2048-B blocks
    input  wire [31:0] total_blk,       // title_last_rbn + 1

    input  wire [31:0] prev_rbn,        // seek-preview target
    input  wire        prev_req,

    output wire [23:0] blk10,
    output wire        blk10_ok,
    output reg  [31:0] cur_time,        // packed BCD {hh,mm,ss,8'h00}
    output reg  [31:0] total_time,
    output reg  [31:0] prev_time,
    output reg         prev_ok,
    output reg  [15:0] total_secs,      // the same total, in seconds -- the cap
                                        // dvd/seek_time.sv's D-pad arm needs
    output reg         time_ok
);

    // =====================================================================
    // Measurement: latch (pts0, blk0), close the window on a later sample.
    // =====================================================================
    reg  [23:0] blk10_r;
    reg         blk10_ok_r;
    reg  [32:0] pts0;
    reg  [31:0] blk0;
    reg         win_open;

    // Raw CD bypasses everything (see the header).
    assign blk10    = raw_mode ? BLK10_RAW : blk10_r;
    assign blk10_ok = raw_mode ? en        : blk10_ok_r;

    wire [33:0] d_pts   = {1'b0, vid_pts} - {1'b0, pts0};
    wire [31:0] d_blk   = lin_blk - blk0;
    wire [31:0] win_cur = blk10_ok_r ? WIN_REF : WIN_ARM;

    // A window is only evidence if it is monotonic and plausible in both axes.
    wire win_bad  = d_pts[33] || (d_pts[32:0] > {12'd0, PTS_MAX[20:0]})
                    || (lin_blk < blk0) || (d_blk > DBLK_MAX);
    wire win_done = !win_bad && (d_pts[32:0] >= {12'd0, win_cur[20:0]});

    // =====================================================================
    // Shared serial engine: q = (a * k) / b, then optionally seconds -> BCD.
    // Four jobs; see the job constants. RATE is the only one that skips the
    // BCD stage, and the only one whose divisor is a PTS delta.
    // =====================================================================
    localparam [1:0] J_RATE = 2'd0, J_PREV = 2'd1, J_CUR = 2'd2, J_TOT = 2'd3;
    localparam [2:0] S_IDLE = 3'd0, S_MUL = 3'd1, S_DIV = 3'd2,
                     S_SEC  = 3'd3, S_PUB = 3'd4;
    // k = 900000 (PTS ticks in 10 s) for RATE, 10 (blocks -> block-seconds) for
    // the clock jobs. 20 bits covers both.
    localparam [19:0] K_RATE = 20'd900_000;   // 900000 < 2^20, fits exactly
    localparam [19:0] K_TEN  = 20'd10;

    reg  [2:0]  st;
    reg  [1:0]  job;
    reg  [3:0]  req;                    // pending, indexed by job
    // ⚠ WIDTHS ARE ARGUED, NOT ROUNDED UP. acc must hold the largest product:
    // RATE is d_blk (<= DBLK_MAX = 2^17) x 900000 (< 2^20) = 37 bits; a clock job
    // is a block count clamped to 24 bits x 10 = 28. So acc is 38 and everything
    // feeding it is narrower. divisor only ever holds d_pts (<= PTS_MAX, 21 bits)
    // or blk10 (24), so rem needs divisor+1 = 25 -- carrying 38/39-bit versions of
    // these cost ~14 bits of comparator and subtractor in the divide loop for
    // nothing.
    reg  [37:0] acc;                    // product, then the divide numerator
    reg  [23:0] mul_a;
    reg  [4:0]  mul_i;
    reg  [23:0] divisor;
    reg  [24:0] rem;
    reg  [23:0] quo;
    reg         quo_sat;
    reg  [5:0]  div_i;

    // Latched job operands, so a request can never be paired with a later value.
    // d_blk_l is bounded by the DBLK_MAX window guard; block counts are clamped to
    // 24 bits, which is 16.7 M blocks = 34 GB of file -- an order of magnitude past
    // any medium this core reads, and the readout saturates at 9:59:59 anyway.
    reg  [17:0] d_blk_l;
    reg  [20:0] d_pts_l;
    reg  [23:0] prev_rbn_l;
    wire [23:0] lin_blk_c   = (lin_blk   > 32'h00FF_FFFF) ? 24'hFF_FFFF : lin_blk[23:0];
    wire [23:0] total_blk_c = (total_blk > 32'h00FF_FFFF) ? 24'hFF_FFFF : total_blk[23:0];
    wire [23:0] prev_rbn_c  = (prev_rbn  > 32'h00FF_FFFF) ? 24'hFF_FFFF : prev_rbn[23:0];
    reg         prev_new;               // prev_rbn_l has not been resolved yet
    reg         tot_seen;               // total_time resolved at least once
    reg         cur_seen;
    reg         ok_d;                   // blk10_ok delayed, for the first-arm
                                        // one-shot below

    wire [24:0] rem_n = {rem[23:0], acc[37]};
    wire        div_ge = (rem_n >= {1'b0, divisor});
    // The multiplier's constant is one of exactly two, so it is a mux on the job
    // rather than a 20-bit register reloaded per job.
    // ⚠ The constant is muxed onto a WIRE and the bit selected from that, never
    // bit-selected off the localparam directly (`K_TEN[mul_i]`): a variable
    // bit-select of a parameter is not portable, and it read as 0 under Icarus --
    // every product came out zero. Same family as the Quartus 17 `function`
    // miscompiles: it elaborates quietly and behaves differently per tool.
    wire [19:0] mul_kw  = (job == J_RATE) ? K_RATE : K_TEN;
    wire        mul_bit = mul_kw[mul_i];

    // seconds -> BCD by repeated subtraction (the dpad_seek MM:SS trick), which
    // yields the DIGITS directly, so no separate binary-to-BCD pass is needed.
    reg  [15:0] sec_t;
    reg  [15:0] sec_t_l;                // the clamped seconds, before the digits
                                        // consume sec_t
    reg  [3:0]  bcd_h, bcd_mt, bcd_mo, bcd_st;
    reg  [2:0]  sec_st;

    wire [23:0] quo_c   = quo_sat ? 24'hFFFFFF : quo;
    wire [15:0] sec_cap = (quo_c > {8'd0, SEC_CAP}) ? SEC_CAP : quo_c[15:0];
    wire [23:0] ema     = blk10_r - (blk10_r >> 2) + (quo_c >> 2);
    wire        rate_ok = (quo_c >= BLK10_MIN) && (quo_c <= BLK10_MAX);
    wire [31:0] bcd_out = {4'd0, bcd_h, bcd_mt, bcd_mo, bcd_st, sec_t[3:0], 8'h00};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blk10_r <= 24'd0; blk10_ok_r <= 1'b0; win_open <= 1'b0;
            pts0 <= 33'd0; blk0 <= 32'd0;
            st <= S_IDLE; job <= J_RATE; req <= 4'd0;
            acc <= 38'd0; mul_a <= 24'd0; mul_i <= 5'd0;
            divisor <= 24'd0; rem <= 25'd0; quo <= 24'd0; quo_sat <= 1'b0;
            div_i <= 6'd0;
            d_blk_l <= 18'd0; d_pts_l <= 21'd0; prev_rbn_l <= 24'd0;
            prev_new <= 1'b0; tot_seen <= 1'b0; cur_seen <= 1'b0; ok_d <= 1'b0;
            sec_t <= 16'd0; sec_t_l <= 16'd0;
            bcd_h <= 4'd0; bcd_mt <= 4'd0; bcd_mo <= 4'd0;
            bcd_st <= 4'd0; sec_st <= 3'd0;
            cur_time <= 32'd0; total_time <= 32'd0; prev_time <= 32'd0;
            total_secs <= 16'd0; prev_ok <= 1'b0; time_ok <= 1'b0;
        end else begin
            ok_d <= blk10_ok;
            // ---- measurement -------------------------------------------
            if (mount) begin
                blk10_r <= 24'd0; blk10_ok_r <= 1'b0; win_open <= 1'b0;
                cur_seen <= 1'b0; tot_seen <= 1'b0; prev_new <= 1'b0;
                ok_d     <= 1'b0;
                cur_time <= 32'd0; total_time <= 32'd0; prev_time <= 32'd0;
                total_secs <= 16'd0;
            end else if (flush || !en) begin
                // the position jumped; the file's rate did not. Keep it.
                win_open <= 1'b0;
            end else if (vid_pts_valid) begin
                if (!win_open) begin
                    pts0 <= vid_pts; blk0 <= lin_blk; win_open <= 1'b1;
                end else if (win_bad) begin
                    pts0 <= vid_pts; blk0 <= lin_blk;      // restart, keep est.
                end else if (win_done) begin
                    d_blk_l <= d_blk[17:0];      // bounded by the DBLK_MAX guard
                    d_pts_l <= d_pts[20:0];
                    req[J_RATE] <= 1'b1;
                    pts0 <= vid_pts; blk0 <= lin_blk;
                end
            end

            // ---- clock job requests ------------------------------------
            if (mount) begin
                // handled above; do not queue work for a file we know nothing
                // about yet.
            end else begin
                // ⚠ The first-arm trigger MUST be an edge. As a level
                // (blk10_ok && !tot_seen) it re-raises req[J_CUR] every cycle
                // until tot_seen sets -- and since CUR outranks TOT, TOT never
                // reaches the engine, tot_seen never sets, and time_ok never
                // rises. The clock simply never appeared.
                if (sec_tick || (blk10_ok && !ok_d)) begin
                    req[J_CUR] <= 1'b1;
                    req[J_TOT] <= 1'b1;
                end
                if (prev_req && (!prev_new || (prev_rbn_c != prev_rbn_l))) begin
                    prev_rbn_l  <= prev_rbn_c;
                    prev_new    <= 1'b1;
                    req[J_PREV] <= 1'b1;
                end
            end
            if (!prev_req) begin
                prev_new <= 1'b0;
                prev_ok  <= 1'b0;
            end
            time_ok <= en && blk10_ok && cur_seen && tot_seen;

            // ---- the engine --------------------------------------------
            case (st)
                S_IDLE: begin
                    // RATE first (everything else divides by its result), then
                    // the preview (a live gesture), then the clock.
                    if (req[J_RATE]) begin
                        job <= J_RATE; req[J_RATE] <= 1'b0;
                        mul_a <= {6'd0, d_blk_l};
                        divisor <= {3'd0, d_pts_l};
                        st <= S_MUL;
                    end else if (blk10 != 24'd0) begin
                        if (req[J_PREV]) begin
                            job <= J_PREV; req[J_PREV] <= 1'b0;
                            mul_a <= prev_rbn_l;
                            divisor <= blk10;
                            st <= S_MUL;
                        end else if (req[J_CUR]) begin
                            job <= J_CUR; req[J_CUR] <= 1'b0;
                            mul_a <= lin_blk_c;
                            divisor <= blk10;
                            st <= S_MUL;
                        end else if (req[J_TOT]) begin
                            job <= J_TOT; req[J_TOT] <= 1'b0;
                            mul_a <= total_blk_c;
                            divisor <= blk10;
                            st <= S_MUL;
                        end
                    end
                    acc <= 38'd0; rem <= 25'd0; quo <= 24'd0; quo_sat <= 1'b0;
                    mul_i <= 5'd19; div_i <= 6'd38;
                end

                // product = mul_a * mul_k, MSB-first shift-add (one adder).
                S_MUL: begin
                    acc <= {acc[36:0], 1'b0} + (mul_bit ? {14'd0, mul_a} : 38'd0);
                    if (mul_i == 5'd0) st <= S_DIV;
                    else               mul_i <= mul_i - 5'd1;
                end

                // quotient = acc / divisor, restoring, saturating at 24 bits.
                S_DIV: begin
                    rem     <= div_ge ? (rem_n - {1'b0, divisor}) : rem_n;
                    acc     <= {acc[36:0], 1'b0};
                    quo     <= {quo[22:0], div_ge};
                    if (quo[23]) quo_sat <= 1'b1;
                    if (div_i == 6'd1) begin
                        sec_st <= 3'd0;
                        st     <= (job == J_RATE) ? S_PUB : S_SEC;
                    end else div_i <= div_i - 6'd1;
                end

                // seconds -> BCD digits by repeated subtraction. Bounded: at
                // most 9 + 5 + 9 + 5 iterations from the SEC_CAP clamp.
                S_SEC: begin
                    case (sec_st)
                        3'd0: begin                       // load + clamp
                            sec_t  <= sec_cap;
                            sec_t_l<= sec_cap;                // kept for total_secs
                            bcd_h  <= 4'd0; bcd_mt <= 4'd0;
                            bcd_mo <= 4'd0; bcd_st <= 4'd0;
                            sec_st <= 3'd1;
                        end
                        3'd1: if (sec_t >= 16'd3600) begin
                                  sec_t <= sec_t - 16'd3600; bcd_h <= bcd_h + 4'd1;
                              end else sec_st <= 3'd2;
                        3'd2: if (sec_t >= 16'd600) begin
                                  sec_t <= sec_t - 16'd600; bcd_mt <= bcd_mt + 4'd1;
                              end else sec_st <= 3'd3;
                        3'd3: if (sec_t >= 16'd60) begin
                                  sec_t <= sec_t - 16'd60; bcd_mo <= bcd_mo + 4'd1;
                              end else sec_st <= 3'd4;
                        3'd4: if (sec_t >= 16'd10) begin
                                  sec_t <= sec_t - 16'd10; bcd_st <= bcd_st + 4'd1;
                              end else sec_st <= 3'd5;
                        default: st <= S_PUB;
                    endcase
                end

                default: begin                            // S_PUB
                    case (job)
                        J_RATE: if (rate_ok) begin
                                    blk10_r    <= blk10_ok_r ? ema : quo_c;
                                    blk10_ok_r <= 1'b1;
                                end
                        J_PREV: begin prev_time  <= bcd_out;
                                      prev_ok    <= prev_req && prev_new; end
                        J_CUR:  begin cur_time   <= bcd_out; cur_seen <= 1'b1; end
                        default:begin total_time  <= bcd_out;
                                      total_secs  <= sec_t_l;
                                      tot_seen    <= 1'b1; end
                    endcase
                    st <= S_IDLE;
                end
            endcase
        end
    end
endmodule
`default_nettype wire
