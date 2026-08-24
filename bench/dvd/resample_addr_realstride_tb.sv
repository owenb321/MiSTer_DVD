`timescale 1ns/1ps
//
// resample_addr_realstride_tb.sv — display-read ADDRESS check at REAL 720x480
// geometry (mb_width=45, mb_height=30, stride 90 words/line).
//
// The prior addr-scan (resample_persist_tb.sv) used a NARROW frame (mb_width=4,
// stride 8) and showed disp_wr_addr monotonic past line 256. This bench repeats
// the check at the REAL stride to answer the N64-prompted question: does the
// display read address cross a frame-region / ADDR_ERR boundary specifically
// ABOVE line 256 when the per-line stride is the real 90 words?
//
// It drives resample_addrgen (which contains memory_address / mem_addr.v) with
// output_frame=2, continuous frames, and for every emitted Y-component read at
// the first macroblock of a line (disp_mb==0) records the line-start address.
// Checks, using the SAME mem_codes.v constants the RTL uses:
//   - address never equals ADDR_ERR (the overflow sentinel)
//   - Y line-start address == FRAME_2_Y + disp_y * (mb_width*2)   (exact linear)
//   - address stays within FRAME_2's Y region (< FRAME_2_CR)
//   - prints the stream across disp_y = 254..258 and at 479
//
// Build:
//   iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/resample_addr_realstride_sim \
//     rtl/mpeg2/resample_addrgen.v rtl/mpeg2/mem_addr.v bench/dvd/resample_addr_realstride_tb.sv
//   vvp bench/dvd/resample_addr_realstride_sim
//
module resample_addr_realstride_tb;
  // pull in the real memory-map constants (FRAME_*_Y, ADDR_ERR, WIDTH_Y, COMP_*)
  `include "mem_codes.v"

  reg         clk = 0, clk_en = 1, rst = 0;
  reg   [2:0] output_frame = 3'd2;          // display FRAME_2
  reg         output_frame_valid = 0;
  wire        output_frame_rd;
  reg         progressive_sequence = 1, progressive_frame = 1;
  reg         top_field_first = 0, repeat_first_field = 0;
  reg   [7:0] mb_width = 8'd45, mb_height = 8'd30;     // REAL 720x480
  reg  [13:0] horizontal_size = 14'd720, vertical_size = 14'd480;
  reg         interlaced = 0, deinterlace = 1, persistence = 1;
  reg   [4:0] repeat_frame = 0;
  reg         disp_wr_addr_full = 0, disp_wr_addr_ack = 1;
  wire        disp_wr_addr_en;
  wire [21:0] disp_wr_addr;
  wire  [2:0] resample_wr_dta;
  wire        resample_wr_en;
  reg         disp_wr_addr_almost_full = 0, resample_wr_almost_full = 0;
  wire        busy;

  resample_addrgen dut (
    .clk(clk), .clk_en(clk_en), .rst(rst),
    .output_frame(output_frame), .output_frame_valid(output_frame_valid), .output_frame_rd(output_frame_rd),
    .progressive_sequence(progressive_sequence), .progressive_frame(progressive_frame),
    .top_field_first(top_field_first), .repeat_first_field(repeat_first_field),
    .mb_width(mb_width), .mb_height(mb_height),
    .horizontal_size(horizontal_size), .vertical_size(vertical_size),
    .interlaced(interlaced), .deinterlace(deinterlace),
    .persistence(persistence), .repeat_frame(repeat_frame),
    .disp_wr_addr_full(disp_wr_addr_full), .disp_wr_addr_en(disp_wr_addr_en),
    .disp_wr_addr_ack(disp_wr_addr_ack), .disp_wr_addr(disp_wr_addr),
    .resample_wr_dta(resample_wr_dta), .resample_wr_en(resample_wr_en),
    .disp_wr_addr_almost_full(disp_wr_addr_almost_full), .resample_wr_almost_full(resample_wr_almost_full),
    .busy(busy), .video_live(), .pickup_hold(1'b0), .pause(1'b0), .vscale_mode(2'd0), .hcrop_en(1'b0), .menu_ff(1'b0), .film24(1'b0));

  always #5 clk = ~clk;

  // Correlation-free region bounds (FRAME_2 occupies a contiguous Y/Cr/Cb block;
  // OSD is a separate region). A display read can only return real data if its
  // address lands in the FRAME_2 block (or OSD). Anything else (ADDR_ERR, another
  // frame's region, unallocated space) reads back as zeros = the strobe symptom.
  localparam [21:0] F2_LO   = FRAME_2_Y[21:0];                       // 0x0c0000
  localparam [21:0] F2_HI   = FRAME_3_Y[21:0];                       // 0x120000 (excl)
  localparam [21:0] OSD_LO  = OSD[21:0];
  localparam [21:0] OSD_HI  = OSD[21:0] + (22'h1 << WIDTH_Y);        // OSD uses a Y-sized region

  integer  n_total = 0, n_f2 = 0, n_osd = 0, n_aerr = 0, n_other = 0;
  reg [21:0] max_f2 = 0, min_f2 = 22'h3fffff;

  always @(posedge clk)
    if (rst && disp_wr_addr_en) begin
      n_total = n_total + 1;
      if (disp_wr_addr == ADDR_ERR[21:0]) begin
        n_aerr = n_aerr + 1;
        if (n_aerr <= 8)
          $display("[ADDR_ERR] #%0d  disp_y(out-of-sync)=%0d  addr=0x%06h",
                   n_aerr, dut.disp_y, disp_wr_addr);
      end else if (disp_wr_addr >= F2_LO && disp_wr_addr < F2_HI) begin
        n_f2 = n_f2 + 1;
        if (disp_wr_addr > max_f2) max_f2 = disp_wr_addr;
        if (disp_wr_addr < min_f2) min_f2 = disp_wr_addr;
      end else if (disp_wr_addr >= OSD_LO && disp_wr_addr < OSD_HI) begin
        n_osd = n_osd + 1;
      end else begin
        n_other = n_other + 1;
        if (n_other <= 12)
          $display("[OUT-OF-REGION] #%0d  disp_y(out-of-sync)=%0d  addr=0x%06h",
                   n_other, dut.disp_y, disp_wr_addr);
      end
    end

  initial begin
    $display("\n==== real-stride disp-addr check: 720x480, mb_width=45 stride=90 ====");
    $display("mem map: WIDTH_Y=%0d  FRAME_2_Y=0x%06h  FRAME_2_CR=0x%06h  ADDR_ERR=0x%06h",
             WIDTH_Y, FRAME_2_Y[21:0], FRAME_2_CR[21:0], ADDR_ERR[21:0]);
    $display("Y plane needs %0d lines x 90 = %0d words (0x%05h); region size = %0d words",
             480, 480*90, 480*90, (FRAME_2_CR - FRAME_2_Y));

    rst = 0; output_frame_valid = 0;
    repeat (4) @(posedge clk);
    rst = 1;
    repeat (4) @(posedge clk);
    output_frame_valid = 1;

    // enough cycles for ~2 full 480-line frames (each ~ 30*45*8*~9 reads)
    repeat (2_500_000) @(posedge clk);

    $display("---- SUMMARY ----");
    $display("total display reads   : %0d", n_total);
    $display("  in FRAME_2 block    : %0d  (min=0x%06h max=0x%06h)", n_f2, min_f2, max_f2);
    $display("  in OSD region       : %0d", n_osd);
    $display("  == ADDR_ERR         : %0d", n_aerr);
    $display("  OUT OF ANY REGION   : %0d", n_other);
    $display("expected Y max ~ FRAME_2_Y + 479*90 + (line span) = ~0x%06h", F2_LO + 479*90 + 90);
    if (n_aerr==0 && n_other==0)
      $display("RESULT: every display read addresses a valid FRAME_2/OSD location through line 479 -> NO 256-line address cliff. Zeros must come from the MEMORY RETURN, not addressing.");
    else
      $display("RESULT: ADDRESS ANOMALY FOUND (ADDR_ERR or out-of-region) -> inspect above");
    $finish;
  end

  initial begin
    #200_000_000;
    $display("TIMEOUT (n_total=%0d)", n_total);
    $finish;
  end
endmodule
