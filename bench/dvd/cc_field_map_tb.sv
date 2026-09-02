/*
 * cc_field_map_tb.sv — does CC1 go out on the field the TELEVISION calls field 1?
 *
 * This mapping has been wrong in both directions once each, so the bench now
 * asserts it the way a TV decides it, with no room for premise error:
 *
 *   SMPTE 170M: broadcast FIELD 1's vertical sync begins coincident with a line
 *   boundary; FIELD 2's begins mid-line. A caption decoder slices CC1 from line
 *   21 of the field whose vsync it saw LINE-ALIGNED. Nothing about the picture
 *   content enters into it.
 *
 * So this bench watches sync_gen's OUTPUT sync stream exactly as a TV would:
 * classify each vsync leading edge by the h_pos it rises at (line-aligned vs
 * mid-line), then check that the caption line inside the line-aligned-vsync
 * field is the one dvd/cc_vbi.sv's formula (cc_fld1 = ~v_pos[0]) marks
 * for the field-1 (CC1) slot.
 *
 * ⚠ HISTORY, so nobody re-derives the wrong premise: the first version of this
 * bench asserted "field 1 = the line preceding TOP-field active video" — the DVD
 * decoder-side labeling, where TOP = field 1 in the picture-coding sense. That
 * is a statement about picture geometry, not sync phase, and in this raster TOP
 * content displays inside SYNC field 2 (NTSC is bottom-field-first: field 1
 * shows the bottom lines). Encoding that premise "pinned" an inverted mapping,
 * and on hardware every field-1 service (C1/C2/T1/T2) showed nothing while the
 * CC Test Line proved the rest of the chain worked.
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
  wire        pe, vs;

  // The NTSC 480i half-line parameters (native 858-dot line; the shipped main
  // raster is the pixrep-doubled twin of this — same v_pos/field structure).
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
    .h_sync(), .v_sync(vs), .c_sync(), .h_blank(), .v_blank()
  );

  // ---- the TV model: classify each vsync leading edge by where it rises ----
  // h_pos and v_sync ride the same 3-stage output pipeline, so comparing them
  // against each other is delay-consistent. Line-aligned rise = h_pos near 0;
  // mid-line rise = h_pos near halfline (429). The quadrant test keeps it robust
  // to the constant pipeline offset.
  reg  vs_q = 1'b0;
  reg  f1_period  = 1'b0;   // current field period began with a line-aligned vsync
  reg  have_class = 1'b0;

  integer checked = 0, errors = 0;

  always @(posedge clk) if (ce2 && rst) begin
    vs_q <= vs;
    if (vs && !vs_q) begin
      f1_period  <= (hp < 12'd214) || (hp > 12'd643);   // line-aligned => FIELD 1
      have_class <= 1'b1;
    end

    // The caption line (v_cntr == 261) lies between this field's vsync and the
    // next active region, so f1_period still describes the field it belongs to.
    if (have_class && vp[11:1] == 12'd261 && hp == 12'd0) begin
      // (a) raster sanity: field 1's VBI must carry v_pos[0]==0 here
      if (f1_period !== ~vp[0]) begin
        $display("FAIL: %0s-vsync field has caption-line v_pos[0]=%0d",
                 f1_period ? "line-aligned (field 1)" : "mid-line (field 2)", vp[0]);
        errors = errors + 1;
      end
      // (b) the DUT formula: cc_fld1 = ~sg_vpos[0] must mark exactly field 1
      if ((~vp[0]) !== f1_period) begin
        $display("FAIL: cc_fld1 formula (~v_pos[0]=%0d) disagrees with the TV's field (field1=%0d)",
                 ~vp[0], f1_period);
        errors = errors + 1;
      end
      checked = checked + 1;
      if (checked == 4) begin
        if (errors == 0)
          $display("PASS: cc_field_map_tb — CC1 rides the line-aligned-vsync (broadcast field 1) VBI (%0d fields checked)",
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
