/*
 * std_rate.sv — the STC tick and audio NCO trim for standard conversion by speed change
 *
 * DVD-FORK (docs/standard_convert.md). Playing PAL film at 960/1001 speed gives 23.976
 * frames/s, and NTSC film at 1001/960 gives 25. Everything scheduled against the STC (picture
 * due test, audio drain gate, SPU, highlights) compares PTS to that clock, so scaling the
 * clock's RATE scales all of them together, and the audio NCO must follow by the same ratio.
 *
 * ★ EXACT, NOT APPROXIMATE. The tick is a rational divider of the 27 MHz clk_sys, so it cannot
 * accumulate error against the raster, which comes from the same crystal:
 *     unity  1 tick per     300 clocks                  90000     Hz
 *     slow 960 ticks per 300300 clocks (= 300 x 1001)   86313.686 Hz
 *     fast 1001 ticks per 288000 clocks (= 300 x 960)   93843.75  Hz
 * At unity the tick lands on the same cycles as the old stc_div == 299, so a build with
 * conversion off is cycle-identical.
 *
 * ⚠ THIS IS NOT THE ONLY 90 kHz TICK, ON PURPOSE. emu's stc_div stays a true clk_sys/300 for
 * nav_trace's `free` counter, which maps trace entries onto the HPS's CLOCK_MONOTONIC. Scaling
 * that would corrupt every timestamp mapping (dvd/nav_trace.sv "WHY TWO TIMESTAMPS").
 *
 * THE ACCUMULATOR RESTARTS ON A MODE CHANGE. An accumulator left at up to 300299 by slow mode
 * would otherwise pay down at 300 per clock in unity mode: ~1000 consecutive ticks, a jump of
 * 11 ms in the STC. Restarting costs under one tick of phase, and a mode change restarts the
 * raster anyway.
 *
 * NCO TRIM. Added to the increment dvd_audio_decode already uses, so nominal + trim equals
 * round(fs * 2^32 / 27e6 * ratio). The constants are pinned by bench/dvd/std_rate_tb.sv, which
 * recomputes the ratio each one achieves. Worst error is 0.10 ppm; the existing nominals
 * themselves are off by up to 0.12 ppm, and those floors have always been accepted. Trim is
 * exact enough that the drift between the audio and the STC stays in that same class.
 * Plain constants rather than an elaboration-time calculation: the arithmetic is one line of
 * Python in the bench, and Quartus 17 has miscompiled recently added functions and casts here.
 */

`default_nettype none

module std_rate (
    input  wire               clk,        // clk_sys, 27 MHz
    input  wire               rst_n,
    input  wire        [1:0]  mode,       // 0 unity, 1 slow (960/1001), 2 fast (1001/960)
    input  wire        [1:0]  nco_fs,     // dvd_audio_decode's: 0 44.1k, 1 48k, 2 32k, 3 96k

    output wire               tick,       // one clk pulse per STC tick
    output reg  signed [21:0] nco_trim
);

wire        slow = (mode == 2'd1);
wire        fast = (mode == 2'd2);
wire [18:0] n    = slow ? 19'd960    : fast ? 19'd1001   : 19'd1;
wire [18:0] d    = slow ? 19'd300300 : fast ? 19'd288000 : 19'd300;

reg  [18:0] acc;                          // < d in steady state; acc + n < 2^19 always
reg  [1:0]  mode_q;
wire [18:0] sum        = acc + n;
wire        mode_edge  = (mode != mode_q);

assign tick = (sum >= d) & ~mode_edge;

always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        acc    <= 19'd0;
        mode_q <= 2'd0;
    end else begin
        mode_q <= mode;
        acc    <= mode_edge ? 19'd0 : tick ? (sum - d) : sum;
    end

always @(*)
    case ({fast, slow, nco_fs})
        4'b01_00: nco_trim = -22'sd287332;    // 44.1 kHz slow
        4'b01_01: nco_trim = -22'sd312742;    // 48 kHz   slow
        4'b01_10: nco_trim = -22'sd208494;    // 32 kHz   slow
        4'b01_11: nco_trim = -22'sd625484;    // 96 kHz   slow
        4'b10_00: nco_trim =  22'sd299604;    // 44.1 kHz fast
        4'b10_01: nco_trim =  22'sd326100;    // 48 kHz   fast
        4'b10_10: nco_trim =  22'sd217400;    // 32 kHz   fast
        4'b10_11: nco_trim =  22'sd652200;    // 96 kHz   fast
        default:  nco_trim =  22'sd0;
    endcase

endmodule

`default_nettype wire
