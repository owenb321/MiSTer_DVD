/*
 * cc_vbi.sv — DVD-FORK (line-21 closed captions on the MAIN raster, 2026-09-03)
 *
 * The ten lines of glue between the decoder's raster coordinates and the EIA-608
 * inserter (dvd/cc_line21.sv). They used to live inside dvd/re_interlace.sv, the
 * second 15 kHz raster that the single-raster rework deleted: the interlaced main
 * raster now carries the N64-model half-line itself and goes to the analog pins
 * directly, so the caption waveform has to be painted into ITS vertical blanking
 * interval. Kept as a module rather than inline in emu.sv so that
 * bench/dvd/cc_e2e_tb.sv can drive the REAL wiring end to end (the round-3 lesson:
 * the wiring between proven pieces is the thing that breaks — an implicit net
 * killed the feature once while every unit bench passed).
 *
 * Coordinates (rtl/mpeg2/syncgen.v, interlaced + pixel repetition):
 *   - h_pos runs 0..1715 on the 1716-dot pixrep line; each source pixel occupies
 *     two clocks. The inserter's NCO was built for the 858-dot line at 13.5 MHz,
 *     so it is enabled on one clock of each pair and sees hpos = h_pos >> 1.
 *   - v_pos = {v_cntr, ~odd_field}: v_pos[11:1] is the line within the FIELD,
 *     v_pos[0] the raster field parity. Line 21 = the last line of the field's
 *     blanking, v_cntr == vertical_length (261 NTSC) = the 15th line after vsync
 *     end (docs/closed_captions.md), unchanged from the re_interlace raster this
 *     inserter used to live in. Field 1 = ~v_pos[0]: the SYNC-SIGNATURE
 *     derivation pinned by bench/dvd/cc_field_map_tb.sv (SMPTE 170M field 1 =
 *     the line-aligned vsync; NTSC content is bottom-field-first, so picture
 *     parity never identifies the broadcast field).
 *   - `on` is asserted only outside active video (a mis-derived line number can
 *     cost a blanking line, never punch a hole in the picture) unless `test`
 *     (P1O[44] CC Test Line) deliberately paints it on visible line 20.
 * NTSC only (EIA-608 line 21); `pal` forces it off.
 */
`include "timescale.v"
`default_nettype none   // see the note in dvd/cc_line21.sv (round-3 lesson)

module cc_vbi (
    input  wire        clk,             // clk_sys 27 MHz (the dot clock)
    input  wire        rst_n,

    input  wire        dec_clk,         // caption pairs from the VLD, clk_dec
    input  wire        dec_pair_valid,
    input  wire [15:0] dec_pair,
    input  wire        dec_pair_field,

    input  wire        enable,          // fields raster up and captions wanted
    input  wire        test,            // paint on visible line 20
    input  wire        flush,           // load / seek / menu jump: drop the backlog
    input  wire        pal,             // PAL raster: no line-21 captions

    input  wire [11:0] h_pos,           // main raster, pixrep domain 0..1715
    input  wire [11:0] v_pos,           // {line within field, field parity}
    input  wire        pixel_en,        // active video (DE)

    output wire [7:0]  level,           // luma level to drive on R, G and B
    output wire        on,              // drive `level` instead of normal video
    output wire        active           // diagnostics
);

wire [11:0] cc_vline  = test ? 12'd20 : 12'd261;      // NTSC vertical_length
wire        cc_line_w = ~pal & (v_pos[11:1] == cc_vline);
wire        cc_fld1_w = ~v_pos[0];
wire        level_en;

cc_line21 cc (
    .clk            (clk),
    .rst_n          (rst_n),
    .ce2            (h_pos[0]),                     // one clock per pixrep pair
    .dec_clk        (dec_clk),
    .dec_pair_valid (dec_pair_valid),
    .dec_pair       (dec_pair),
    .dec_pair_field (dec_pair_field),
    .enable         (enable & ~pal),
    .flush          (flush),
    .hpos           ({1'b0, h_pos[11:1]}),          // 0..857
    .cc_line        (cc_line_w),
    .field1         (cc_fld1_w),
    .level          (level),
    .level_en       (level_en),
    .active         (active)
);

assign on = enable & level_en & (test | ~pixel_en);

endmodule

`default_nettype wire   // restore for any file compiled after this one
