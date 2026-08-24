
/* 
 * xilinx_fifo_dc.v - Generic Replacement for MiSTer Port
 * 
 * Original Copyright (c) 2007 Koen De Vleeschauwer. 
 * Replacement implementation for portability.
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

  parameter [8:0]dta_width=9'd8;
  parameter [8:0]addr_width=9'd8; 
  parameter [8:0]prog_thresh=9'd1;
         
  input          rst;         /* low active sync master reset (actually usually treated as async or sync to respective clocks in generic logic) */
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

  // Internal Memory
  reg [dta_width-1:0] mem [(1<<addr_width)-1:0];

  // Pointers (Gray and Binary)
  reg [addr_width:0] wptr_bin, wptr_gray;
  reg [addr_width:0] rptr_bin, rptr_gray;
  reg [addr_width:0] wptr_gray_sync1, wptr_gray_sync2;
  reg [addr_width:0] rptr_gray_sync1, rptr_gray_sync2;

  // Reset logic is tricky because 'rst' is single input. 
  // We assume 'rst' is asynchronous active low? The usage says "low active sync master reset".
  // `xilinx_fifo_dc` is usually instantiated with `.rst(~rst)`.
  // We will treat it as async reset for pointers.

  // --- Synchronization ---
  always @(posedge wr_clk or negedge rst) begin
    if (!rst) begin
      rptr_gray_sync1 <= 0;
      rptr_gray_sync2 <= 0;
    end else begin
      rptr_gray_sync1 <= rptr_gray;
      rptr_gray_sync2 <= rptr_gray_sync1;
    end
  end

  always @(posedge rd_clk or negedge rst) begin
    if (!rst) begin
      wptr_gray_sync1 <= 0;
      wptr_gray_sync2 <= 0;
    end else begin
      wptr_gray_sync1 <= wptr_gray;
      wptr_gray_sync2 <= wptr_gray_sync1;
    end
  end

  // --- Write Logic ---
  wire [addr_width:0] wptr_bin_next = wptr_bin + 1;
  wire [addr_width:0] wptr_gray_next = (wptr_bin_next >> 1) ^ wptr_bin_next;
  
  // Convert rptr_gray_sync2 to binary for full check/prog_full
  integer i;
  reg [addr_width:0] rptr_bin_sync;
  always @* begin
    rptr_bin_sync[addr_width] = rptr_gray_sync2[addr_width];
    for (i = addr_width-1; i >= 0; i = i - 1)
      rptr_bin_sync[i] = rptr_bin_sync[i+1] ^ rptr_gray_sync2[i];
  end

  wire full_comb = (wptr_gray_next == {~rptr_gray_sync2[addr_width:addr_width-1], rptr_gray_sync2[addr_width-2:0]}); 
  // Standard Gray Full check: MSB differs, 2nd MSB differs, rest same ??
  // No, actually: wptr and rptr gray codes. 
  // Full condition: 
  // wptr_gray == {~rptr_gray[addr_width:addr_width-1], rptr_gray[addr_width-2:0]}
  
  // (Dead always block removed — was empty placeholder code)

  always @(posedge wr_clk or negedge rst) begin
    if (!rst) begin
      wptr_bin <= 0;
      wptr_gray <= 0;
      full <= 0;
      overflow <= 0;
      wr_ack <= 0;
      prog_full <= 0;
    end else begin
       if (wr_en && !full) begin
          mem[wptr_bin[addr_width-1:0]] <= din;
          wptr_bin <= wptr_bin_next;
          wptr_gray <= wptr_gray_next;
          wr_ack <= 1;
          overflow <= 0;
       end else begin
          wr_ack <= 0;
          if (wr_en) overflow <= 1; else overflow <= 0;
       end

       // Update Full: use next pointer only after actual write, current pointer otherwise
       if (wr_en && !full)
          full <= (wptr_gray_next == {~rptr_gray_sync2[addr_width], ~rptr_gray_sync2[addr_width-1], rptr_gray_sync2[addr_width-2:0]});
       else
          full <= (wptr_gray == {~rptr_gray_sync2[addr_width], ~rptr_gray_sync2[addr_width-1], rptr_gray_sync2[addr_width-2:0]});

       // Prog Full: use current write pointer when no write happened
       if (wr_en && !full)
           prog_full <= (((1<<addr_width) - (wptr_bin_next - rptr_bin_sync)) <= prog_thresh);
       else
           prog_full <= (((1<<addr_width) - (wptr_bin - rptr_bin_sync)) <= prog_thresh);
    end
  end

  // --- Read Logic ---
  wire [addr_width:0] rptr_bin_next = rptr_bin + 1;
  wire [addr_width:0] rptr_gray_next = (rptr_bin_next >> 1) ^ rptr_bin_next;

  // Convert wptr_gray_sync2 to binary
  reg [addr_width:0] wptr_bin_sync;
  always @* begin
    wptr_bin_sync[addr_width] = wptr_gray_sync2[addr_width];
    for (i = addr_width-1; i >= 0; i = i - 1)
      wptr_bin_sync[i] = wptr_bin_sync[i+1] ^ wptr_gray_sync2[i];
  end

  always @(posedge rd_clk or negedge rst) begin
    if (!rst) begin
      rptr_bin <= 0;
      rptr_gray <= 0;
      empty <= 1;
      underflow <= 0;
      valid <= 0;
      dout <= 0;
      prog_empty <= 1; 
    end else begin
      if (rd_en && !empty) begin
        dout <= mem[rptr_bin[addr_width-1:0]];
        rptr_bin <= rptr_bin_next;
        rptr_gray <= rptr_gray_next;
        valid <= 1;
        underflow <= 0;
      end else begin
        valid <= 0;
        if (rd_en) underflow <= 1; else underflow <= 0;
        // Keep old dout or X? 
      end

      // Update Empty: use next pointer only after actual read, current pointer otherwise
      if (rd_en && !empty)
        empty <= (rptr_gray_next == wptr_gray_sync2);
      else
        empty <= (rptr_gray == wptr_gray_sync2);

      // Prog Empty: use current read pointer when no read happened
      if (rd_en && !empty)
          prog_empty <= ((wptr_bin_sync - rptr_bin_next) <= prog_thresh);
      else
          prog_empty <= ((wptr_bin_sync - rptr_bin) <= prog_thresh);
    end
  end

endmodule
