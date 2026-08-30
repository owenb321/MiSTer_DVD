`timescale 1ns/1ps
//
// resample_cadence_rate_tb.sv — measure the governor's AVERAGE release rate on a
// textbook 3:2 soft-telecine stream (rff alternating every frame, as ffprobe
// confirms Matrix/MiB code it): expect exactly 2.5 refreshes/frame (= 23.976 fps
// on 59.94). Catches any systematic over-hold (e.g. 3,3,2 patterns) that would
// make video consume the shared stream slower than real time and starve audio.
//
// Supply model: next frame is ALWAYS available (film decode is easy; picbuf runs
// ahead), flags alternate with each consumed frame — worst case for latch-timing
// bugs at the pickup boundary.
//
// Build:
//   iverilog -g2012 -I rtl/mpeg2 -o bench/dvd/resample_cadence_rate_sim \
//       dvd/resample_addrgen.v rtl/mpeg2/mem_addr.v bench/dvd/resample_cadence_rate_tb.sv
//   vvp bench/dvd/resample_cadence_rate_sim
//
module resample_cadence_rate_tb;
  reg         clk = 0, clk_en = 1, rst = 0;
  reg   [2:0] output_frame = 3'd1;
  wire        output_frame_rd;
  // real HW config: deinterlace branch, DVD coding
  reg         progressive_sequence = 0, progressive_frame = 1;
  wire        top_field_first;
  wire        repeat_first_field;
  reg   [7:0] mb_width = 8'd1, mb_height = 8'd1;
  reg  [13:0] horizontal_size = 14'd16, vertical_size = 14'd4;
  reg         interlaced = 0, deinterlace = 1, persistence = 1;
  reg   [4:0] repeat_frame = 0;
  reg         disp_wr_addr_full = 0, disp_wr_addr_ack = 1;
  wire        disp_wr_addr_en;
  wire [21:0] disp_wr_addr;
  wire  [2:0] resample_wr_dta;
  wire        resample_wr_en;
  reg         disp_wr_addr_almost_full = 0, resample_wr_almost_full = 0;
  wire        busy;
  wire        frame_late;

  // ---- supply: always available; flags alternate per consumed frame ----
  integer     consumed = 0;
  wire        output_frame_valid_w = 1'b1;
  // display-order 3:2 flags (per ffprobe of the real disc): rff alternates,
  // tff toggles every rff frame — the exact coded pattern.
  assign repeat_first_field = consumed[0];        // frames 1,3,5,... are rff
  assign top_field_first    = consumed[1];        // irrelevant to cur_show; realism

  resample_addrgen dut (
    .clk(clk), .clk_en(clk_en), .rst(rst),
    .output_frame(output_frame), .output_frame_valid(output_frame_valid_w), .output_frame_rd(output_frame_rd),
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
    .busy(busy), .frame_late(frame_late), .video_live(), .pickup_hold(1'b0), .pause(1'b0), .vscale_mode(2'd0), .hcrop_en(1'b0), .menu_ff(1'b0), .film24(1'b0));

  always #5 clk = ~clk;

  always @(posedge clk)
    if (rst && output_frame_rd) consumed <= consumed + 1;

  // count display refreshes (completed image scans)
  localparam STATE_NEXT_MB = 4'h3;
  wire    pass_done = (dut.state == STATE_NEXT_MB) && dut.last_mb && dut.last_y;
  integer refreshes = 0;
  always @(posedge clk) if (rst && pass_done) refreshes = refreshes + 1;

  integer errs = 0;
  integer c0, r0, dc, dr;
  real    avg;

  initial begin
    rst = 0;
    repeat (4) @(posedge clk);
    rst = 1;

    // warm up: let a few frames flow (skip start-up transients)
    wait (consumed >= 8);
    c0 = consumed; r0 = refreshes;

    // measure over 80 released frames
    wait (consumed >= c0 + 80);
    dc = consumed - c0;
    dr = refreshes - r0;
    avg = $itor(dr) / $itor(dc);
    $display("released %0d frames over %0d refreshes -> avg %.3f refreshes/frame (expect 2.500)",
             dc, dr, avg);

    if (dr !== dc * 5 / 2) begin
      $display("FAIL: cadence average is not exactly 2.5 (video rate wrong: %.2f%% of real time)",
               250.0 / avg);
      errs = errs + 1;
    end
    if (errs == 0) $display("==== PASS: 3:2 alternating stream releases at exactly 2.5 refreshes/frame ====");
    else           $display("==== FAIL ====");
    $finish;
  end

  initial begin #200_000_000 $display("TIMEOUT"); $finish; end
endmodule
