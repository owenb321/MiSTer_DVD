
/*
 * xilinx_fifo_dc.v - Generic dual-clock FIFO for Cyclone V (MiSTer port)
 *
 * Original Copyright (c) 2007 Koen De Vleeschauwer.
 * Replacement implementation using Gray-code pointers for clock domain
 * crossing, compatible with Intel/Altera Cyclone V.
 *
 * Behavioral contract matches the original Xilinx FIFO18/FIFO36 wrappers:
 *   - rst is active LOW (directly from mpeg2video core)
 *   - FIRST_WORD_FALL_THROUGH = FALSE (standard read: data appears cycle after rd_en)
 *   - valid/wr_ack are registered acknowledgements (1-cycle latency)
 *   - Writing when full or reading when empty is safe (no data corruption)
 *   - prog_full asserts when free space <= prog_thresh
 *   - prog_empty asserts when fill level <= prog_thresh
 */

`include "timescale.v"

module xilinx_fifo_dc (
	rst,
	wr_clk,
	din,
	wr_en,
	full,
	wr_ack,
	overflow,
	prog_full,
	rd_clk,
	dout,
	rd_en,
	empty,
	valid,
	underflow,
	prog_empty
);

  parameter [8:0]dta_width=9'd8;      /* Data bus width */
  parameter [8:0]addr_width=9'd8;     /* Address bus width, determines fifo size by evaluating 2^addr_width */
  parameter [8:0]prog_thresh=9'd1;    /* Programmable threshold constant for prog_empty and prog_full */

  input          rst;         /* low active sync master reset */
  /* read port */
  input          rd_clk;
  output reg [dta_width-1:0]dout;
  input          rd_en;
  output reg     empty;
  output reg     valid;
  output reg     underflow;
  output reg     prog_empty;
  /* write port */
  input          wr_clk;
  input  [dta_width-1:0]din;
  input          wr_en;
  output reg     full;
  output reg     overflow;
  output reg     wr_ack;
  output reg     prog_full;

  localparam DEPTH = 1 << addr_width;

  // -----------------------------------------------------------------------
  // Internal Memory
  // -----------------------------------------------------------------------
  reg [dta_width-1:0] mem [0:DEPTH-1];

  // -----------------------------------------------------------------------
  // Pointer declarations  (addr_width+1 bits to distinguish full from empty)
  // -----------------------------------------------------------------------
  reg [addr_width:0] wptr_bin  = 0, wptr_gray  = 0;
  reg [addr_width:0] rptr_bin  = 0, rptr_gray  = 0;

  // 2-stage synchronizers for cross-domain pointer transfer
  reg [addr_width:0] rptr_gray_sync1 = 0, rptr_gray_sync2 = 0;  // rptr into wr_clk domain
  reg [addr_width:0] wptr_gray_sync1 = 0, wptr_gray_sync2 = 0;  // wptr into rd_clk domain

  // -----------------------------------------------------------------------
  // Binary-to-Gray and Gray-to-Binary helpers
  // -----------------------------------------------------------------------
  function [addr_width:0] bin2gray;
    input [addr_width:0] b;
    bin2gray = (b >> 1) ^ b;
  endfunction

  function [addr_width:0] gray2bin;
    input [addr_width:0] g;
    integer k;
    begin
      gray2bin[addr_width] = g[addr_width];
      for (k = addr_width-1; k >= 0; k = k - 1)
        gray2bin[k] = gray2bin[k+1] ^ g[k];
    end
  endfunction

  // Gray-code full condition:
  //   wptr_gray and rptr_gray have same lower bits but inverted top 2 bits
  function is_full_gray;
    input [addr_width:0] wg, rg;
    is_full_gray = (wg == {~rg[addr_width], ~rg[addr_width-1], rg[addr_width-2:0]});
  endfunction

  // -----------------------------------------------------------------------
  // Cross-clock synchronizers
  // -----------------------------------------------------------------------
  // Sync rptr_gray into wr_clk domain
  always @(posedge wr_clk or negedge rst) begin
    if (!rst) begin
      rptr_gray_sync1 <= 0;
      rptr_gray_sync2 <= 0;
    end else begin
      rptr_gray_sync1 <= rptr_gray;
      rptr_gray_sync2 <= rptr_gray_sync1;
    end
  end

  // Sync wptr_gray into rd_clk domain
  always @(posedge rd_clk or negedge rst) begin
    if (!rst) begin
      wptr_gray_sync1 <= 0;
      wptr_gray_sync2 <= 0;
    end else begin
      wptr_gray_sync1 <= wptr_gray;
      wptr_gray_sync2 <= wptr_gray_sync1;
    end
  end

  // -----------------------------------------------------------------------
  // Write-side logic  (wr_clk domain)
  // -----------------------------------------------------------------------
  wire [addr_width:0] wptr_bin_next  = wptr_bin + 1'd1;
  wire [addr_width:0] wptr_gray_next = bin2gray(wptr_bin_next);
  wire [addr_width:0] rptr_bin_sync  = gray2bin(rptr_gray_sync2);

  // Effective write pointer: advances only on successful write
  wire               do_write       = wr_en & ~full;
  wire [addr_width:0] wptr_eff      = do_write ? wptr_bin_next : wptr_bin;
  wire [addr_width:0] wptr_gray_eff = do_write ? wptr_gray_next : wptr_gray;

  // Free space = DEPTH - (wptr - rptr)   (unsigned arithmetic, modular)
  wire [addr_width:0] wr_fill = wptr_eff - rptr_bin_sync;
  wire [addr_width:0] wr_free = DEPTH[addr_width:0] - wr_fill;

  always @(posedge wr_clk or negedge rst) begin
    if (!rst) begin
      wptr_bin  <= 0;
      wptr_gray <= 0;
      full      <= 0;
      overflow  <= 0;
      wr_ack    <= 0;
      prog_full <= 0;
    end else begin
      // --- Data write ---
      if (do_write) begin
        mem[wptr_bin[addr_width-1:0]] <= din;
        wptr_bin  <= wptr_bin_next;
        wptr_gray <= wptr_gray_next;
      end

      // --- Status flags (use effective pointer = state after this cycle) ---
      full      <= is_full_gray(wptr_gray_eff, rptr_gray_sync2);
      wr_ack    <= do_write;
      overflow  <= wr_en & full;
      prog_full <= (wr_free <= prog_thresh);
    end
  end

  // -----------------------------------------------------------------------
  // Read-side logic  (rd_clk domain)
  // -----------------------------------------------------------------------
  wire [addr_width:0] rptr_bin_next  = rptr_bin + 1'd1;
  wire [addr_width:0] rptr_gray_next = bin2gray(rptr_bin_next);
  wire [addr_width:0] wptr_bin_sync  = gray2bin(wptr_gray_sync2);

  // Effective read pointer: advances only on successful read
  wire               do_read        = rd_en & ~empty;
  wire [addr_width:0] rptr_gray_eff = do_read ? rptr_gray_next : rptr_gray;

  // Fill level = wptr - rptr  (unsigned, modular)
  wire [addr_width:0] rd_fill = wptr_bin_sync - (do_read ? rptr_bin_next : rptr_bin);

  always @(posedge rd_clk or negedge rst) begin
    if (!rst) begin
      rptr_bin   <= 0;
      rptr_gray  <= 0;
      empty      <= 1;
      valid      <= 0;
      underflow  <= 0;
      dout       <= 0;
      prog_empty <= 1;
    end else begin
      // --- Data read ---
      if (do_read) begin
        dout      <= mem[rptr_bin[addr_width-1:0]];
        rptr_bin  <= rptr_bin_next;
        rptr_gray <= rptr_gray_next;
      end

      // --- Status flags (use effective pointer = state after this cycle) ---
      empty      <= (rptr_gray_eff == wptr_gray_sync2);
      valid      <= do_read;
      underflow  <= rd_en & empty;
      prog_empty <= (rd_fill <= prog_thresh);
    end
  end

endmodule
/* not truncated */
