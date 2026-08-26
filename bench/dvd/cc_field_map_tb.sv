/*
 * cc_field_map_tb.sv — does the caption line carry the field the TELEVISION
 * expects there?
 *
 * This bench exists because the mapping was wrong in the first cut and the
 * failure mode is indistinguishable from "the feature does nothing": if CC1 is
 * emitted on the wrong field it lands on broadcast line 284, and a set switched
 * to "CC1" simply shows nothing. No garbled text, no partial result — just
 * silence. So it is asserted here rather than argued in a comment.
 *
 * The subtlety: syncgen's vertical counter starts at the first ACTIVE line and
 * puts blanking at the END of the field, so the VBI lines that a field owns in
 * broadcast numbering are emitted while odd_field still reads the PREVIOUS field.
 * NTSC line 21 belongs to field 1 and precedes field 1's active video.
 *
 * ASSERTION: the candidate caption line (v_cntr == vertical_length == 261) with
 * v_pos[0] == 1 must be followed by the TOP field's active lines, because TOP is
 * NTSC field 1 = the CC1/CC2 field — and that is exactly the value
 * dvd/re_interlace.sv feeds cc_line21 as `field1`.
 *
 * Build:
 *   iverilog -g2012 -I rtl/mpeg2 -o bench/dvd/cc_field_map_sim \
 *       rtl/mpeg2/syncgen.v bench/dvd/cc_field_map_tb.sv
 *   vvp bench/dvd/cc_field_map_sim
 */
`timescale 1ns/1ps

module cc_field_map_tb;

  reg clk = 0; always #18 clk = ~clk;
  reg ce2 = 0; always @(posedge clk) ce2 <= ~ce2;
  reg rst = 0;

  wire [11:0] hp, vp;
  wire        pe;

  // The NTSC parameters dvd/re_interlace.sv gives its sync_gen instance.
  sync_gen sg (
    .clk(clk), .clk_en(ce2), .rst(rst),
    .horizontal_size(14'd720), .vertical_size(14'd480),
    .display_horizontal_size(14'd0), .display_vertical_size(14'd0),
    .horizontal_resolution(12'd720), .horizontal_sync_start(12'd735),
    .horizontal_sync_end(12'd797), .horizontal_length(12'd857),
    .vertical_resolution(12'd479), .vertical_sync_start(12'd244),
    .vertical_sync_end(12'd247), .horizontal_halfline(12'd429),
    .vertical_length(12'd261), .interlaced(1'b1), .clip_display_size(1'b0),
    .h_pos(hp), .v_pos(vp), .pixel_en(pe),
    .h_sync(), .v_sync(), .c_sync(), .h_blank(), .v_blank()
  );

  integer checked = 0, errors = 0;
  reg     pend = 1'b0;
  reg     cc_field1;                 // what re_interlace would pass as `field1`

  always @(posedge clk) if (ce2 && rst) begin
    if (vp[11:1] == 12'd261 && hp == 12'd0) begin
      cc_field1 <= vp[0];            // mirrors dvd/re_interlace.sv cc_fld1 = sg_vpos[0]
      pend      <= 1'b1;
    end else if (pend && pe && hp == 12'd0) begin
      // vp[0] == 0 on an active line means the TOP field (odd_field == 1)
      if (cc_field1 !== ~vp[0]) begin
        $display("FAIL: caption line claimed field1=%0d but the following active field is %0s",
                 cc_field1, vp[0] ? "BOTTOM (field 2)" : "TOP (field 1)");
        errors = errors + 1;
      end
      pend    <= 1'b0;
      checked = checked + 1;
      if (checked == 4) begin
        if (errors == 0)
          $display("PASS: cc_field_map_tb — field1 marks the line preceding TOP-field active video (%0d fields checked)",
                   checked);
        else begin
          $display("FAIL: cc_field_map_tb — %0d error(s)", errors);
          $fatal(1);
        end
        $finish;
      end
    end
  end

  initial begin
    #200 rst = 1;
    #120_000_000;
    $display("FAIL: cc_field_map_tb — timeout (only %0d fields seen)", checked);
    $fatal(1);
  end

endmodule
