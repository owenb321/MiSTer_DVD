/*
 * sub_anchor.sv — where a dialogue subtitle sits under Standard Convert's vertical scale
 *
 * DVD-FORK (docs/standard_convert.md "Phase 3 plan", subtitles: 1:1 repositioned, by the
 * maintainer's choice 2026-11-08). Plain dialogue subtitles on the analog output are drawn 1:1
 * at raster coordinates, never through crt_ov_map's nearest-tap inverse, which drops subtitle
 * lines and stair-steps them (the 2026-09-02 "subtitle sawtooth" fix). Under PAL->NTSC the
 * picture is scaled 5/6 (Fit) or 5/8 (Letterbox), so a 1:1 subtitle at its authored rows can
 * sit below the bottom of the 480-line raster. This module gives the ROW OFFSET spu_decode adds
 * to every raster query: the subtitle is still drawn 1:1 (sharp, no lines dropped), but moved
 * so its top lands where the scaled picture shows source row `sy`.
 *
 *   natural   off = sy - top,   top = round(sy*5/6) at 5/6, 60 + round(sy*5/8) at 5/8
 *   on screen off >= ey - 479, so the box's last row is still on the raster. A tight box near
 *             the bottom keeps its natural place; a full-screen area (some discs author
 *             0..575 around a line of text at the bottom) is bottom-aligned instead of losing
 *             its text.
 *   even      rounded UP to even, so each raster field still reads its own field's subtitle
 *             lines (an odd offset swaps the two fields' lines: jagged text).
 *
 * Accepted consequence: 1:1 text is about 20 % taller relative to the picture than the source
 * authored, as on a player that doesn't scale subtitles. A box taller than the raster keeps
 * its bottom rows and loses its top ones.
 *
 * To PAL (2026-11-09, Phase 4) is the same rule the other way: 6/5 (Fit) puts row sy at
 * round(6*sy/5), 9/10 (Letterbox) at 72 + round(9*sy/10), and the raster is 576 lines, so the
 * bottom bound is ey - 575. The offset is then usually negative: the subtitle moves DOWN with
 * the enlarged picture, and comes out about 17 % smaller relative to it.
 *
 * Every division is exact without a divider: round(5*sy/6) = (5*sy*10923 + 32768) >> 16,
 * round(5*sy/8) = (5*sy + 4) >> 3, round(6*sy/5) = (6*sy*13107 + 32768) >> 16 and
 * round(9*sy/10) = (9*sy*6554 + 32768) >> 16, checked for every sy up to 1152. ratio 0 (no
 * conversion) gives 0. Registered; the inputs change only when a subtitle unit commits.
 * Bench: bench/dvd/sub_anchor_tb.sv (every sy, several box heights, both ratios).
 */

`default_nettype none

module sub_anchor (
    input  wire               clk,        // clk_sys
    input  wire               rst_n,
    input  wire        [2:0]  ratio,      // disp_vscale's: 0 = none, 1 = 5/6, 2 = 5/8, 3 = 6/5, 4 = 9/10
    input  wire       [11:0]  sy,         // the committed subtitle box, source rows
    input  wire       [11:0]  ey,
    output reg  signed [11:0] off         // even; spu_decode reads raster row + off
);

wire [27:0] p6      = {16'd0, sy} * 28'd54615 + 28'd32768;     // 5*10923 = 54615
wire [11:0] top6    = p6[27:16];                                // round(5*sy/6)
wire [14:0] p8      = {3'd0, sy} * 15'd5 + 15'd4;
wire [11:0] top8    = 12'd60 + p8[14:3];                        // 60 + round(5*sy/8)
wire [31:0] p65     = {20'd0, sy} * 32'd78642 + 32'd32768;     // 6*13107 = 78642
wire [11:0] top65   = p65[27:16];                               // round(6*sy/5)
wire [31:0] p910    = {20'd0, sy} * 32'd58986 + 32'd32768;     // 9*6554 = 58986
wire [11:0] top910  = 12'd72 + p910[27:16];                     // 72 + round(9*sy/10)
wire [11:0] top     = (ratio == 3'd2) ? top8 : (ratio == 3'd3) ? top65 : (ratio == 3'd4) ? top910 : top6;
wire signed [13:0] nat = $signed({2'b00, sy}) - $signed({2'b00, top});
wire signed [13:0] bot = $signed({2'b00, ey}) - (ratio[2] | (ratio == 3'd3) ? 14'sd575 : 14'sd479);
wire signed [13:0] raw = (nat > bot) ? nat : bot;
wire signed [13:0] evn = (raw + 14'sd1) & ~14'sd1;              // ceil to even

always @(posedge clk or negedge rst_n)
    if (!rst_n)                              off <= 12'sd0;
    else if (ratio == 3'd0 || ratio > 3'd4)  off <= 12'sd0;
    else                                     off <= evn[11:0];

endmodule

`default_nettype wire
