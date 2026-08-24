`timescale 1ns/1ps
//
// mem_addr_recon_vs_disp_tb.sv — does the DECODE WRITE (recon) address equal the
// DISPLAY READ address for the SAME pixel, across the line-256 boundary?
//
// The strobe reads back zeros above line 256. One hypothesis: decode writes
// reconstructed line >=256 to a DIFFERENT address than the display reads it from
// (so display finds unwritten memory = black). Both paths use memory_address but
// with very different drives:
//   - RECON write: macroblock_address counts up (0,1,2,...); pixel_y = mb_row*16.
//   - DISPLAY read: macroblock_address=0 always; pixel_y = delta_y (full line).
//
// This bench drives ONE memory_address the recon way (sequential macroblocks,
// 720x480 = mb_width 45 x mb_height 30) and prints the Y line-start address for
// each macroblock ROW. Compare the row-16 (line 256) base against the display
// read's known line-256 address 0x0c5a00 (from resample_addr_realstride_tb).
// If they MATCH, decode writes exactly where display reads -> no address-mismatch
// mechanism, the zeros are not an addressing divergence.
//
// Build:
//   iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/mem_addr_recon_vs_disp_sim \
//     rtl/mpeg2/mem_addr.v bench/dvd/mem_addr_recon_vs_disp_tb.sv
//
module mem_addr_recon_vs_disp_tb;
  `include "mem_codes.v"

  reg          clk = 0, clk_en = 1, rst = 0;
  reg   [2:0]  frame = 3'd2;            // FRAME_2 (matches the disp test)
  reg          frame_picture = 1, field_in_frame = 0, field = 0;
  reg   [1:0]  component = 0;           // COMP_Y
  reg   [7:0]  mb_width = 8'd45;
  reg  [13:0]  horizontal_size = 14'd720, vertical_size = 14'd480;
  reg  [12:0]  macroblock_address = 0;
  reg signed [12:0] delta_x = 0, delta_y = 0, mv_x = 0, mv_y = 0;
  reg          valid_in = 0;
  wire [21:0]  address;
  wire  [2:0]  offset_x;
  wire         halfpixel_x, halfpixel_y, valid_out;

  memory_address #(.dta_width(1)) dut (
    .clk(clk), .clk_en(clk_en), .rst(rst),
    .frame(frame), .frame_picture(frame_picture), .field_in_frame(field_in_frame),
    .field(field), .component(component), .mb_width(mb_width),
    .horizontal_size(horizontal_size), .vertical_size(vertical_size),
    .macroblock_address(macroblock_address),
    .delta_x(delta_x), .delta_y(delta_y), .mv_x(mv_x), .mv_y(mv_y),
    .dta_in(1'b0), .valid_in(valid_in),
    .address(address), .offset_x(offset_x),
    .halfpixel_x(halfpixel_x), .halfpixel_y(halfpixel_y),
    .dta_out(), .valid_out(valid_out));

  always #5 clk = ~clk;

  // expected display read addr for a line (from the real-stride model):
  //   FRAME_2_Y + line*mb_width*2
  function [21:0] disp_line_addr(input [12:0] line);
    disp_line_addr = FRAME_2_Y[21:0] + line * (mb_width * 2);
  endfunction

  // capture: pipeline latency from valid_in to valid_out is 13. We tag each
  // input macroblock_address through a shift register so we can label outputs.
  reg [12:0] mba_pipe [0:15];
  integer p;
  always @(posedge clk) if (rst) begin
    mba_pipe[0] <= macroblock_address;
    for (p = 1; p < 16; p = p + 1) mba_pipe[p] <= mba_pipe[p-1];
  end

  integer mism = 0, checks = 0;
  integer si;
  // mem_addr latency is 12 stages (valid_in@stage0 -> address@stage12)
  localparam LAT = 13;

  always @(posedge clk)
    if (rst && valid_out) begin
      begin : c
        reg [12:0] mba; reg [7:0] row, col; reg [21:0] exp_a;
        mba = mba_pipe[LAT-1];
        row = mba / mb_width;
        col = mba % mb_width;
        // only check first macroblock of each row (col 0) = the line start
        if (col == 8'd0) begin
          checks = checks + 1;
          exp_a = disp_line_addr(row * 16);   // display addr for line = row*16
          if (row == 8'd0 || (row >= 8'd14 && row <= 8'd18) || row == 8'd29)
            $display("  mb_row=%0d (line %0d)  RECON addr=0x%06h  DISP addr=0x%06h  %s",
                     row, row*16, address, exp_a,
                     (address == exp_a) ? "MATCH" : "** DIVERGE **");
          if (address != exp_a) mism = mism + 1;
        end
      end
    end

  initial begin
    $display("\n==== recon-write vs disp-read address @720x480 (mb_width=45) ====");
    rst = 0; valid_in = 0; macroblock_address = 0;
    repeat (4) @(posedge clk); rst = 1; repeat (4) @(posedge clk);

    // stream macroblocks 0..(30*45-1) sequentially, one per cycle (recon order)
    @(negedge clk); valid_in = 1;
    for (si = 0; si < 30*45; si = si + 1) begin
      macroblock_address = si[12:0];   // set on negedge -> stable at the posedge the DUT samples
      @(negedge clk);
    end
    valid_in = 0;
    repeat (20) @(posedge clk);

    $display("---- SUMMARY ----");
    $display("line-start checks: %0d   diverge: %0d", checks, mism);
    if (mism == 0)
      $display("RESULT: decode WRITE addr == display READ addr for every line incl. >256 -> NO address-mismatch; zeros are not from write/read divergence.");
    else
      $display("RESULT: WRITE/READ ADDRESS DIVERGENCE FOUND -> that is the zero source.");
    $finish;
  end

  initial begin #5_000_000; $display("TIMEOUT"); $finish; end
endmodule
