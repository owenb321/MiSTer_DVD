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
// corrupts a rate measurement. telem_sync commits a value only when two
// consecutive samples agree, which is cheap and sufficient because nothing here
// advances faster than ~60 Hz against a 27 MHz clock.
//============================================================================

module telem_sync #(parameter W = 16) (
    input              clk,
    input      [W-1:0] d,
    output reg [W-1:0] q
);
    reg [W-1:0] s1, s2;
    always @(posedge clk) begin
        s1 <= d;
        s2 <= s1;
        if (s1 == s2) q <= s2;      // commit only a value seen twice running
    end
endmodule


module dvd_telem #(
    parameter [15:0] CMD   = 16'h007A,   // free: Main uses 0x00-0x44, 0x61-63, 0xF0-F9
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
    input  [15:0] av_drift               // word 13: dispatched audio PTS - STC
);

    wire [15:0] s_refresh, s_pickup, s_late, s_drop, s_viderr, s_costs, s_aud;
    wire  [7:0] s_vbuf, s_flags;
    telem_sync #(16) u_ref (clk, refreshes,  s_refresh);
    telem_sync #(16) u_pck (clk, pickups,    s_pickup);
    telem_sync #(16) u_lat (clk, lates,      s_late);
    telem_sync #(16) u_drp (clk, drops,      s_drop);
    telem_sync #(16) u_err (clk, vid_err,    s_viderr);
    telem_sync #(16) u_cst (clk, drop_costs, s_costs);
    telem_sync #(16) u_aud (clk, aud_frames, s_aud);
    telem_sync #(8)  u_vbf (clk, vbuf_fill,  s_vbuf);
    telem_sync #(8)  u_flg (clk, flags,      s_flags);
    wire [15:0] s_play, s_gate;
    telem_sync #(16) u_ply (clk, aud_play,   s_play);
    telem_sync #(16) u_gat (clk, aud_gate,   s_gate);
    wire [15:0] s_dlag, s_perr, s_drift;
    telem_sync #(16) u_dlg (clk, disp_lag,   s_dlag);
    telem_sync #(16) u_per (clk, play_err,   s_perr);
    telem_sync #(16) u_dft (clk, av_drift,   s_drift);

    reg  [3:0] wcnt;
    reg        active;
    reg [15:0] dout_r;

    // the atomic snapshot
    reg [15:0] q1, q2, q3, q4, q5, q6, q7, q8, q9, q10, q11, q12, q13;

    always @(posedge clk) begin
        if (!io_enable) begin
            wcnt   <= 4'd0;
            active <= 1'b0;
            dout_r <= 16'd0;
        end else if (io_strobe) begin
            if (wcnt == 4'd0) begin
                active <= (io_din == CMD);
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
                dout_r <= MAGIC;
            end else begin
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
                    default: dout_r <= 16'd0;
                endcase
            end
            if (wcnt != 4'hF) wcnt <= wcnt + 4'd1;
        end
    end

    assign drive = active;
    assign dout  = dout_r;

endmodule
