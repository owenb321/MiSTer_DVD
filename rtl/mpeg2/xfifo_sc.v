/* 
 * fifo_sc.v
 * 
 * Copyright (c) 2007 Koen De Vleeschauwer. 
 * 
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND 
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
 * ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE 
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL 
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS 
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) 
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY 
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF 
 * SUCH DAMAGE.
 */

/*
 * fifo with common clock for read and write port.
 */

`include "timescale.v"

module xfifo_sc (
	clk,
	rst,
	din,
	wr_en,
	full,
	wr_ack,
	overflow,
	prog_full,
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
  
  input          clk;
  input          rst;         /* low active sync master reset */
  /* read port */
  output reg [dta_width-1:0]dout; /* data output */
  input          rd_en;       /* read enable */
  output reg     empty;       /* asserted if fifo is empty; no additional reads can be performed */
  output reg     valid;       /* valid (read acknowledge): indicates rd_en was asserted during previous clock cycle and data was succesfully read from fifo and placed on dout */
  output reg     underflow;   /* underflow (read error): indicates rd_en was asserted during previous clock cycle but no data was read from fifo because fifo was empty */
  output reg     prog_empty;  /* indicates the fifo has prog_thresh entries, or less. threshold for asserting prog_empty is prog_thresh */
  /* write port */
  input  [dta_width-1:0]din;  /* data input */
  input          wr_en;       /* write enable */
  output reg     full;        /* asserted if fifo is full; no additional writes can be performed */
  output reg     overflow;    /* overflow (write error): indicates wr_en was asserted during previous clock cycle but no data was written to fifo because fifo was full */
  output reg     wr_ack;      /* write acknowledge: indicates wr_en was asserted during previous clock cycle and data was succesfully written to fifo */
  output reg     prog_full;   /* indicates the fifo has prog_thresh free entries, or less, left. threshold for asserting prog_full is 2^addr_width - prog_thresh */

  /* Writing when the fifo is full, or reading while the fifo is empty, does not destroy the contents of the fifo. */

  /*
   * read and write addresses 
   */

  reg  [addr_width:0]wr_addr;
  reg  [addr_width:0]rd_addr;
  reg  [addr_width:0]next_wr_addr;
  reg  [addr_width:0]next_rd_addr;

  always @*
    if (wr_en && ~full) next_wr_addr = wr_addr + 1'b1;
    else next_wr_addr = wr_addr;

  always @*
    if (rd_en && ~empty) next_rd_addr = rd_addr + 1'b1;
    else next_rd_addr = rd_addr;

  always @(posedge clk)
    if (~rst) wr_addr <= 1'b0;
    else wr_addr <= next_wr_addr;

  always @(posedge clk)
    if (~rst) rd_addr <= 1'b0;
    else rd_addr <= next_rd_addr;

  /*
   * empty and full
   */

  always @(posedge clk)
    if (~rst) empty <= 1'b1;
    else empty <= (next_wr_addr == next_rd_addr);

  always @(posedge clk)
    if (~rst) full <= 1'b0;
    else full <= (next_wr_addr[addr_width-1:0] == next_rd_addr[addr_width-1:0]) && (next_wr_addr[addr_width] != next_rd_addr[addr_width]);

  /*
   * valid and wr_ack
   */

  always @(posedge clk)
    if (~rst) valid <= 1'b0;
    else valid <= rd_en && ~empty;

  always @(posedge clk)
    if (~rst) wr_ack <= 1'b0;
    else wr_ack <= wr_en && ~full;

  /*
   * underflow and overflow
   */

  always @(posedge clk)
    if (~rst) underflow <= 1'b0;
    else underflow <= rd_en && empty;

  always @(posedge clk)
    if (~rst) overflow <= 1'b0;
    else overflow <= wr_en && full;

  /*
   * prog_empty and prog_full
   */

  wire [addr_width:0]next_count = next_wr_addr - next_rd_addr;
  wire [addr_width:0]lower_threshold = prog_thresh + 1'b1;
  wire [addr_width:0]max_count = 1'b1 << addr_width;
  wire [addr_width:0]upper_threshold = max_count - lower_threshold;

  always @(posedge clk)
    if (~rst) prog_empty <= 1'b1;
    else prog_empty <= (next_count < lower_threshold);

  always @(posedge clk)
    if (~rst) prog_full <= 1'b0;
    else prog_full <= (next_count > upper_threshold);

  /*
   * dual-port ram w/registered output
   */

  reg    [dta_width-1:0]ram[(1 << addr_width)-1:0];

  always @(posedge clk)
    if (~rst) dout <= 0;
    else if (~empty) dout <= ram[rd_addr[addr_width-1:0]];
    else dout <= dout;

  always @(posedge clk)
    if (wr_en && ~full) ram[wr_addr[addr_width-1:0]] <= din;

endmodule
/* not truncated */
