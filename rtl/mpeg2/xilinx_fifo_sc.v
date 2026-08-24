/* 
 * xilinx_fifo_sc.v
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

module xilinx_fifo_sc (
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
  output [dta_width-1:0]dout; /* data output */
  input          rd_en;       /* read enable */
  output         empty;       /* asserted if fifo is empty; no additional reads can be performed */
  output         valid;       /* valid (read acknowledge): indicates rd_en was asserted during previous clock cycle and data was succesfully read from fifo and placed on dout */
  output         underflow;   /* underflow (read error): indicates rd_en was asserted during previous clock cycle but no data was read from fifo because fifo was empty */
  output         prog_empty;  /* indicates the fifo has prog_thresh entries, or less. threshold for asserting prog_empty is prog_thresh */
  /* write port */
  input  [dta_width-1:0]din;  /* data input */
  input          wr_en;       /* write enable */
  output         full;        /* asserted if fifo is full; no additional writes can be performed */
  output         overflow;    /* overflow (write error): indicates wr_en was asserted during previous clock cycle but no data was written to fifo because fifo was full */
  output         wr_ack;      /* write acknowledge: indicates wr_en was asserted during previous clock cycle and data was succesfully written to fifo */
  output         prog_full;   /* indicates the fifo has prog_thresh free entries, or less, left. threshold for asserting prog_full is 2^addr_width - prog_thresh */

  /* Writing when the fifo is full, or reading while the fifo is empty, does not destroy the contents of the fifo. */

  xilinx_fifo #(
    .ALMOST_FULL_OFFSET(prog_thresh),
    .ALMOST_EMPTY_OFFSET(prog_thresh),
    .DATA_WIDTH(dta_width),
    .ADDR_WIDTH(addr_width),
    .DO_REG(0),
    .EN_SYN("TRUE")
    )
  xilinx_fifo_sc (
    .ALMOSTEMPTY(prog_empty), 
    .ALMOSTFULL(prog_full), 
    .DO(dout), 
    .EMPTY(empty), 
    .FULL(full), 
    .RDERR(underflow), 
    .VALID(valid),
    .WRERR(overflow), 
    .WR_ACK(wr_ack),
    .DI(din), 
    .RDCLK(clk), 
    .RDEN(rd_en), 
    .RST(rst), 
    .WRCLK(clk), 
    .WREN(wr_en)
     );

`ifdef CHECK_GENERATE
    initial 
      $display("%m: fifo parameters: dta_width=%0d addr_width=%0d prog_thresh=%0d", dta_width, addr_width, prog_thresh);
`endif

endmodule
/* not truncated */
