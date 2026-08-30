`timescale 1ns/1ps
//
// menu_ff_tb.sv — verify the disc-menu VBUF-lag FAST-DRAIN override in
// dvd/resample_addrgen.v (docs/dvd_menu_refinements.md §5, candidate c).
//
// The governor normally holds each frame for cur_show refreshes (SHOW_N=2). When
// `menu_ff` is asserted (emu: a menu is up AND the compressed VBUF is deeply backed
// up) the per-frame display target drops to 1 refresh, so the governor picks up a
// NEW decoded frame every refresh — playing a deeply-buffered menu transition out at
// up to display rate (~2x here) so the settled still is reached promptly, WITHOUT
// cutting the transition. It only engages once video is live.
//
// Model: an infinite decoder supply (output_frame_valid=1 — menus decode cheaply, a
// frame is always ready), then count pickups vs display refreshes over a window with
// menu_ff=0 (baseline SHOW_N=2 -> ~2 refreshes/pickup) and menu_ff=1 (fast-drain ->
// ~1 refresh/pickup, ~2x the pickups). Proves menu_ff halves the per-frame hold.
//
// Build:
//   iverilog -g2012 -o bench/dvd/menu_ff_sim \
//       dvd/resample_addrgen.v rtl/mpeg2/mem_addr.v bench/dvd/menu_ff_tb.sv
//   vvp bench/dvd/menu_ff_sim
//
module menu_ff_tb;
  reg         clk = 0, clk_en = 1, rst = 0;
  reg   [2:0] output_frame = 3'd1;
  wire        output_frame_rd;
  reg         progressive_sequence = 0, progressive_frame = 1;
  reg         top_field_first = 0, repeat_first_field = 0;
  reg   [7:0] mb_width = 8'd1, mb_height = 8'd1;      // tiny frame -> very fast scans
  reg  [13:0] horizontal_size = 14'd16, vertical_size = 14'd4;
  reg         interlaced = 0, deinterlace = 1, persistence = 1;
  reg   [4:0] repeat_frame = 0;
  reg         disp_wr_addr_full = 0, disp_wr_addr_ack = 1;
  wire        disp_wr_addr_en;
  wire [21:0] disp_wr_addr;
  wire  [2:0] resample_wr_dta;
  wire        resample_wr_en;
  reg         disp_wr_addr_almost_full = 0, resample_wr_almost_full = 0;
  wire        busy, frame_late, video_live;
  reg         output_frame_valid = 1'b1;   // infinite supply: a decoded frame is always ready
  reg         menu_ff = 1'b0;

  resample_addrgen dut (
    .clk(clk), .clk_en(clk_en), .rst(rst),
    .output_frame(output_frame), .output_frame_valid(output_frame_valid), .output_frame_rd(output_frame_rd),
    .progressive_sequence(progressive_sequence), .progressive_frame(progressive_frame), .informative(1'b1),
    .top_field_first(top_field_first), .repeat_first_field(repeat_first_field),
    .mb_width(mb_width), .mb_height(mb_height),
    .horizontal_size(horizontal_size), .vertical_size(vertical_size),
    .interlaced(interlaced), .deinterlace(deinterlace),
    .persistence(persistence), .repeat_frame(repeat_frame),
    .disp_wr_addr_full(disp_wr_addr_full), .disp_wr_addr_en(disp_wr_addr_en),
    .disp_wr_addr_ack(disp_wr_addr_ack), .disp_wr_addr(disp_wr_addr),
    .resample_wr_dta(resample_wr_dta), .resample_wr_en(resample_wr_en),
    .disp_wr_addr_almost_full(disp_wr_addr_almost_full), .resample_wr_almost_full(resample_wr_almost_full),
    .busy(busy), .frame_late(frame_late), .video_live(video_live), .pickup_hold(1'b0), .pause(1'b0),
    .vscale_mode(2'd0), .hcrop_en(1'b0), .menu_ff(menu_ff), .film24(1'b0));

  always #5 clk = ~clk;

  localparam STATE_NEXT_MB = 4'h3;
  wire    pass_done = (dut.state == STATE_NEXT_MB) && dut.last_mb && dut.last_y;
  integer refreshes = 0, pickups = 0;
  reg     measure = 0;
  always @(posedge clk) if (rst && measure) begin
    if (pass_done)        refreshes = refreshes + 1;
    if (output_frame_rd)  pickups   = pickups   + 1;
  end

  task waitclk(input integer n); integer i; begin for (i=0;i<n;i=i+1) @(posedge clk); end endtask
  integer errors = 0;
  task chk(input cond, input [255:0] m); begin if (!cond) begin $display("  ERR %0s", m); errors = errors + 1; end end endtask

  integer base_pick, base_refr, ff_pick, ff_refr;
  initial begin
    rst = 0; waitclk(4); rst = 1; waitclk(10);
    waitclk(300);                            // let video_live set on the first pickup
    chk(video_live === 1'b1, "video_live set after first pickup");

    // ---- BASE (menu_ff=0): normal SHOW_N=2 pacing -> ~2 refreshes per pickup ----
    menu_ff = 1'b0; waitclk(50);
    refreshes = 0; pickups = 0; measure = 1; waitclk(6000); measure = 0;
    base_refr = refreshes; base_pick = pickups;
    $display("BASE menu_ff=0: refreshes=%0d pickups=%0d  (expect refr ~ 2*pick)", base_refr, base_pick);
    chk(base_pick > 10, "base picked up frames");
    // refr/pick ~ 2.0 (allow 1.6..2.4)
    chk(base_refr*10 >= base_pick*16 && base_refr*10 <= base_pick*24, "base holds ~2 refreshes/frame (SHOW_N=2)");

    // ---- FF (menu_ff=1): fast-drain -> ~1 refresh per pickup, ~2x pickups ----
    menu_ff = 1'b1; waitclk(50);
    refreshes = 0; pickups = 0; measure = 1; waitclk(6000); measure = 0;
    ff_refr = refreshes; ff_pick = pickups;
    $display("FF   menu_ff=1: refreshes=%0d pickups=%0d  (expect refr ~ pick)", ff_refr, ff_pick);
    chk(ff_pick > 10, "ff picked up frames");
    // refr/pick ~ 1.0 (allow up to 1.35)
    chk(ff_refr*100 <= ff_pick*135, "ff holds ~1 refresh/frame (fast-drain)");
    // over the SAME window, fast-drain pumps out clearly more frames than baseline
    chk(ff_pick*10 >= base_pick*15, "ff drains substantially faster than baseline (>=1.5x)");

    if (errors == 0) $display("MENU_FF_TB: ALL TESTS PASSED");
    else             $display("MENU_FF_TB: FAILED with %0d errors", errors);
    $finish;
  end

  initial begin #80000000; $display("MENU_FF_TB: TIMEOUT"); $finish; end
endmodule
