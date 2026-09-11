//============================================================================
// dvd_telem.sv -- core -> HPS telemetry over the hps_io EXT_BUS extension.
//
// Reads out the decoder's pacing counters so a host-side tool can measure them
// directly, instead of photographing the debug overlay. Built for the
// hardware-in-the-loop harness (docs/hil_harness.md); the immediate question is
// whether the display governor shows each content frame for exactly SHOW_N
// refreshes on average, which a measured drift of ~450 ppm says it may not.
//
// WHY EXT_BUS AND NOT status_in
// hps_io exposes status_in/status_set, which looks like the obvious channel and
// is not: stock Main polls UIO_GET_STATUS every frame and writes the result
// straight into cur_status (Main_MiSTer/user_io.cpp:2640), so a core driving it
// would overwrite the user's OSD settings. EXT_BUS is the sanctioned
// core-specific extension -- hps_io passes the bus through and lets the core
// drive HPS_BUS[15:0] whenever it asserts EXT_BUS[32] (sys/hps_io.sv:220).
//
// PROTOCOL (mirrors hps_io's own command handling)
//   io_enable frames a transaction; io_strobe clocks one 16-bit word.
//   The FIRST strobe carries the command in io_din. If it is CMD we take the
//   bus for the rest of the transaction and answer with:
//     word 0  MAGIC          -- so the host can tell a real reply from a stuck
//                               bus or another core; checked before use
//     word 1  refreshes      -- raster vsyncs
//     word 2  pickups        -- content frames picked up for display
//     word 3  lates          -- governor deadline misses
//     word 4  drops          -- pictures dropped
//     word 5  vid_err        -- SIGNED, 1 unit = 1 refresh
//     word 6  {debt, drop_costs}
//     word 7  {vbuf_fill, flags}
//     word 8  aud_frames     -- audio frames queued
//     word 9  aud_play       -- audio play ticks / 16 (what reaches the DAC)
//     word 10 aud_gate       -- drain-gate closures
//     word 11 disp_lag       -- SIGNED, PTS of the picture just DISPLAYED - STC, 1 LSB = 16 ticks
//     word 12 play_err       -- SIGNED, audio playback position vs its anchor, same scale
//     word 13 av_drift       -- SIGNED, dispatched audio PTS - STC, same scale
//   Word 11 is the measurement docs/av_sync.md "THE STC IS A CLOCK" is built
//   on: the picture on SCREEN against the clock the audio is scheduled by. It
//   is ~0 when the display is scheduled by PTS (Stage 1) and reads the whole
//   buffering lead (about -1 s in Film 24p) before that.
//   Word 9 over word 1 is the audio-vs-raster ratio, the companion to
//   refreshes/pickups: both are ratios of counters in ONE clock domain, so
//   neither needs an external reference or an assumption about which clock is
//   right.
//   All counters are free-running 16-bit and WRAP; the host unwraps. Word 1
//   over word 2 is the number this exists to answer: for 29.97 content on a
//   59.94 Hz raster it must be exactly 2.000.
//
// ⚠ THE SNAPSHOT IS ATOMIC, and it has to be. The counters live in three clock
// domains and advance while the transaction runs; reading them one word at a
// time would mix samples taken milliseconds apart and turn a ratio of exactly
// 2.000 into noise. They are latched together on the command strobe.
//
// ⚠ CDC IS A STABILITY FILTER, NOT A PLAIN 2-FF SYNC. These are multi-bit
// BINARY counters from clk_dec/clk_mem: catching one mid-increment can read
// 0x00FF as 0x01FF -- not a small error, a wild one, and a single bad sample
// corrupts a rate measurement. The sampler commits a value only when two
// consecutive samples agree, which is cheap and sufficient because nothing here
// advances faster than ~60 Hz against a 27 MHz clock.
//============================================================================

// (telem_sync, the per-source 3-register filter, was retired by the 2026-09-10
//  area pass in favour of the shared round-robin sampler inside dvd_telem.)


module dvd_telem #(
    parameter [15:0] CMD   = 16'h007A,   // free: Main uses 0x00-0x44, 0x61-63, 0xF0-F9
    // A SECOND command, for state Main needs in order to act rather than to log.
    // It is answered on the same EXT_BUS and is deliberately NOT part of the 0x7A
    // snapshot: that one is diagnostic telemetry whose HPS reader is gated behind
    // the /media/fat/dvd_hil arm file, so a feature that depended on it would work
    // only on a rig set up for hardware-in-the-loop testing.
    parameter [15:0] CMD_AF = 16'h007B,
    parameter [15:0] MAGIC = 16'hD7D1
) (
    input         clk,

    // --- EXT_BUS side (from hps_io) -------------------------------------
    input         io_enable,             // EXT_BUS[34]
    input         io_strobe,             // EXT_BUS[33]
    input  [15:0] io_din,                // EXT_BUS[31:16]
    output        drive,                 // -> EXT_BUS[32]
    output [15:0] dout,                  // -> EXT_BUS[15:0]

    // --- counters (asynchronous to clk; see the CDC note above) ---------
    input  [15:0] refreshes,
    input  [15:0] pickups,
    input  [15:0] lates,
    input  [15:0] drops,
    input  [15:0] vid_err,
    input  [15:0] drop_costs,            // {debt[4:0], drop_req, probe} as emu packs it
    input   [7:0] vbuf_fill,
    input  [15:0] aud_frames,
    input   [7:0] flags,
    input  [15:0] aud_play,
    input  [15:0] aud_gate,
    // A/V phase, SIGNED, the source value's bits [19:4] (1 LSB = 16 ticks of
    // the 90 kHz STC = 0.178 ms, full scale +/-5.8 s). Do NOT take [15:0]: that
    // wraps at +/-0.36 s and cannot represent the offsets these exist to show.
    input  [15:0] disp_lag,              // word 11: PTS of the picture just DISPLAYED - STC
    input  [15:0] play_err,              // word 12: audio playback position vs its anchor
    input  [15:0] av_drift,              // word 13: dispatched audio PTS - STC
    input  [15:0] sched_flags,           // word 14: {frame_rate_code, ps, pf, tff, rff} at the last pickup
    input  [15:0] sched_dur,              // word 15: the duration the scheduler applied, ticks

    // --- audio link format (CMD_AF) -------------------------------------
    // What the wire is actually carrying, which is NOT what the OSD bit says: in
    // Passthru an LPCM or MP2 track leaves as linear PCM, and the ADV7513 has to
    // be taken out of non-PCM mode for it. Main polls this to decide.
    input         af_passthru,            // Audio Out = Passthru
    input         af_pcm_session          // ...and the current content is LPCM/MP2
);

    // ---- ONE round-robin two-consecutive-agree sampler (area pass 2026-09-10) --
    // This used to be 19 telem_sync instances, each holding s1/s2/q = three
    // copies of its word (864 flops for 288 bits of data). The filter needs
    // two consecutive samples of ONE source to agree; nothing here changes
    // faster than ~60 Hz, so one sampler can walk the 19 sources in turn --
    // sample source n at cycle A, sample it again at cycle B, commit q[n] at
    // C if the two registered samples agree -- and every q is refreshed every
    // 57 cycles (2.1 us at 27 MHz) instead of every cycle. Same filter, same
    // registered-sample commit (never the raw asynchronous input), 1/3 the
    // flops. The atomic snapshot below is untouched: q[] is latched together
    // on the command strobe exactly as the 19 outputs were.
    localparam int NSRC = 19;
    wire [15:0] src [0:NSRC-1];
    assign src[0]  = refreshes;
    assign src[1]  = pickups;
    assign src[2]  = lates;
    assign src[3]  = drops;
    assign src[4]  = vid_err;
    assign src[5]  = drop_costs;
    assign src[6]  = aud_frames;
    assign src[7]  = {8'd0, vbuf_fill};
    assign src[8]  = {8'd0, flags};
    assign src[9]  = aud_play;
    assign src[10] = aud_gate;
    assign src[11] = disp_lag;
    assign src[12] = play_err;
    assign src[13] = av_drift;
    assign src[14] = sched_flags;
    assign src[15] = sched_dur;
    assign src[16] = {14'd0, af_pcm_session, af_passthru};
    assign src[17] = 16'd0;                 // spare slots keep the walk a plain counter
    assign src[18] = 16'd0;

    reg  [4:0]  cur;                        // source being sampled
    reg  [1:0]  sph;                        // 0: sample A, 1: sample B, 2: compare+commit
    reg  [15:0] s1, s2;
    reg  [15:0] q [0:NSRC-1];
    integer qi;
    // Power-up state (this module has no reset; telem_sync never needed one
    // because its samplers free-ran, but a walk needs a defined cursor).
    initial begin
        cur = 5'd0; sph = 2'd0;
        for (qi = 0; qi < NSRC; qi = qi + 1) q[qi] = 16'd0;
    end
    always @(posedge clk) begin
        case (sph)
            2'd0: begin s1 <= src[cur]; sph <= 2'd1; end
            2'd1: begin s2 <= src[cur]; sph <= 2'd2; end
            default: begin
                if (s1 == s2) q[cur] <= s2;   // commit only a value seen twice running
                cur <= (cur == NSRC - 1) ? 5'd0 : cur + 5'd1;
                sph <= 2'd0;
            end
        endcase
    end

    wire [15:0] s_refresh = q[0],  s_pickup = q[1],  s_late  = q[2],  s_drop  = q[3];
    wire [15:0] s_viderr  = q[4],  s_costs  = q[5],  s_aud   = q[6];
    wire  [7:0] s_vbuf    = q[7][7:0], s_flags = q[8][7:0];
    wire [15:0] s_play    = q[9],  s_gate   = q[10];
    wire [15:0] s_dlag    = q[11], s_perr   = q[12], s_drift = q[13];
    wire [15:0] s_sfl     = q[14], s_sdu    = q[15];
    wire [15:0] s_afmt    = q[16];

    reg  [3:0] wcnt;
    reg        active;
    reg [15:0] dout_r;

    // the atomic snapshot
    reg [15:0] q1, q2, q3, q4, q5, q6, q7, q8, q9, q10, q11, q12, q13, q14, q15;
    reg [15:0] q_afmt;
    reg        af_sel;

    always @(posedge clk) begin
        if (!io_enable) begin
            wcnt   <= 4'd0;
            active <= 1'b0;
            af_sel <= 1'b0;
            dout_r <= 16'd0;
        end else if (io_strobe) begin
            if (wcnt == 4'd0) begin
                active <= (io_din == CMD) || (io_din == CMD_AF);
                af_sel <= (io_din == CMD_AF);
                q1 <= s_refresh;
                q2 <= s_pickup;
                q3 <= s_late;
                q4 <= s_drop;
                q5 <= s_viderr;
                q6 <= s_costs;
                q7 <= {s_vbuf, s_flags};
                q8 <= s_aud;
                q9 <= s_play;
                q10 <= s_gate;
                q11 <= s_dlag;
                q12 <= s_perr;
                q13 <= s_drift;
                q14 <= s_sfl;
                q15 <= s_sdu;
                q_afmt <= s_afmt;
                dout_r <= MAGIC;
            end else begin
                if (af_sel) dout_r <= (wcnt == 4'd1) ? q_afmt : 16'd0;
                else
                case (wcnt)
                    4'd1:    dout_r <= q1;
                    4'd2:    dout_r <= q2;
                    4'd3:    dout_r <= q3;
                    4'd4:    dout_r <= q4;
                    4'd5:    dout_r <= q5;
                    4'd6:    dout_r <= q6;
                    4'd7:    dout_r <= q7;
                    4'd8:    dout_r <= q8;
                    4'd9:    dout_r <= q9;
                    4'd10:   dout_r <= q10;
                    4'd11:   dout_r <= q11;
                    4'd12:   dout_r <= q12;
                    4'd13:   dout_r <= q13;
                    4'd14:   dout_r <= q14;
                    4'd15:   dout_r <= q15;
                    default: dout_r <= 16'd0;
                endcase
            end
            if (wcnt != 4'hF) wcnt <= wcnt + 4'd1;
        end
    end

    assign drive = active;
    assign dout  = dout_r;

endmodule
