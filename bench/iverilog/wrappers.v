/* 
 * wrappers.v
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
 * Wrappers for dpram and fifos. 
 * For each component, two versions are provided: one where read and write port share a common clock;
 * and one where read and write port have independent clocks.
 */

`undef DEBUG
//`define DEBUG 1

/* check prog_thresh is less than fifo size */
`undef CHECK_FIFO_PARAMS
`ifdef __IVERILOG__
`define CHECK_FIFO_PARAMS 1
`endif

/*
 dual-port ram with same clock for read and write port.
 */

`include "timescale.v"

module dpram_sc (
	rst,
	din,
	clk,
        wr_addr,
	wr_en,
	dout,
        rd_addr,
	rd_en
        );

  parameter dta_width=8;           /* Data bus width */
  parameter addr_width=8;          /* Address bus width, determines dpram size by evaluating 2^addr_width */
  
  input                 rst;       /* low active sync master reset */
  input                 clk;       /* clock */
                                   /* read port */
  output reg [dta_width-1:0]dout;      /* data output */
  input                 rd_en;     /* read enable */
  input [addr_width-1:0]rd_addr;   /* read address */
                                   /* write port */
  input  [dta_width-1:0]din;       /* data input */
  input                 wr_en;     /* write enable */
  input [addr_width-1:0]wr_addr;   /* read address */

  /*
   * More or less in the style given in XST User Guide v9.1, "RAMs and ROMs Coding Examples",
   * "Verilog Coding Example for Dual Port RAM With Enable On Each Port"
   */ 

  reg    [dta_width-1:0]ram[(1 << addr_width)-1:0];

  always @(posedge clk)
    if (rd_en) dout <= ram[rd_addr];
    else dout <= dout;

  always @(posedge clk)
    if (wr_en) ram[wr_addr] <= din;

endmodule


/*
 dual-port ram with different clocks for read and write port
 */

module dpram_dc (
	din,
	wr_rst,
	wr_clk,
        wr_addr,
	wr_en,
	dout,
	rd_rst,
	rd_clk,
        rd_addr,
	rd_en
        );

  parameter dta_width=8;           /* Data bus width */
  parameter addr_width=8;          /* Address bus width, determines dpram size by evaluating 2^addr_width */
  
                                   /* read port */
  output reg [dta_width-1:0]dout;      /* data output */
  input                 rd_rst;    /* low active master reset, sync with read clock */
  input                 rd_clk;    /* read clock */
  input                 rd_en;     /* read enable */
  input [addr_width-1:0]rd_addr;   /* read address */
                                   /* write port */
  input  [dta_width-1:0]din;       /* data input */
  input                 wr_rst;    /* low active master reset, sync with write clock */
  input                 wr_clk;    /* write clock */
  input                 wr_en;     /* write enable */
  input [addr_width-1:0]wr_addr;   /* read address */

  reg    [dta_width-1:0]ram[(1 << addr_width)-1:0];

  always @(posedge rd_clk)
    if (rd_en) dout <= ram[rd_addr];
    else dout <= dout;

  always @(posedge wr_clk)
    if (wr_en) ram[wr_addr] <= din;

endmodule

/*
 fifo with common clock for read and write port.
 */

module fifo_sc (
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

  parameter FIFO_XILINX=0;    /* use Xilinx FIFO primitives */
  parameter check_valid=1;    /* assign x's to fifo output when valid is not asserted */
  
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

  /* Implementation using "soft" fifo */
  xfifo_sc #(
    .dta_width(dta_width),
    .addr_width(addr_width),
    .prog_thresh(prog_thresh)
    )
  xfifo_sc (
    .clk(clk), 
    .rst(rst), 
    .din(din), 
    .wr_en(wr_en), 
    .full(full), 
    .wr_ack(wr_ack), 
    .overflow(overflow), 
    .prog_full(prog_full), 
    .dout(dout), 
    .rd_en(rd_en), 
    .empty(empty), 
    .valid(valid), 
    .underflow(underflow), 
    .prog_empty(prog_empty)
    );

`ifdef DEBUG
  always @(posedge clk)
    $strobe("%m\tread: %h dout: %h", fifo_valid, dout);
`endif

`ifdef CHECK_FIFO_PARAMS
  initial #0
      begin
        if (prog_thresh > (1<<addr_width))
          begin
            #0 $display ("%m\t*** error: inconsistent fifo parameters. addr_width: %d prog_thresh: %d. ***", addr_width, prog_thresh);
            $finish;
          end
      end

  always @(posedge clk)
    if (overflow) 
      begin
        #0 $display ("%m\t*** error: fifo overflow. ***");
      end
/*
  always @(posedge clk)
    if (underflow) 
      begin
        #0 $display ("%m\t*** warning: fifo underflow. ***");
      end
*/
`endif

endmodule

/*
 fifo with independent clock for read and write port.
 */

module fifo_dc (
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

  parameter FIFO_XILINX=0;    /* use Xilinx FIFO primitives */
  parameter check_valid=1;    /* assign x's to fifo output when valid is not asserted */
         
  input          rst;         /* low active sync master reset */
  /* read port */
  input          rd_clk;      /* read clock. positive edge active */
  output [dta_width-1:0]dout; /* data output */
  input          rd_en;       /* read enable */
  output         empty;       /* asserted if fifo is empty; no additional reads can be performed */
  output         valid;       /* valid (read acknowledge): indicates rd_en was asserted during previous clock cycle and data was succesfully read from fifo and placed on dout */
  output         underflow;   /* underflow (read error): indicates rd_en was asserted during previous clock cycle but no data was read from fifo because fifo was empty */
  output         prog_empty;  /* indicates the fifo has prog_thresh entries, or less. threshold for asserting prog_empty is prog_thresh */
  /* write port */
  input          wr_clk;      /* write clock. positive edge active */
  input  [dta_width-1:0]din;  /* data input */
  input          wr_en;       /* write enable */
  output         full;        /* asserted if fifo is full; no additional writes can be performed */
  output         overflow;    /* overflow (write error): indicates wr_en was asserted during previous clock cycle but no data was written to fifo because fifo was full */
  output         wr_ack;      /* write acknowledge: indicates wr_en was asserted during previous clock cycle and data was succesfully written to fifo */
  output         prog_full;   /* indicates the fifo has prog_thresh free entries, or less, left. threshold for asserting prog_full is 2^addr_width - prog_thresh  */
 
  /* Writing when the fifo is full, or reading while the fifo is empty, does not destroy the contents of the fifo. */
  
  /* Implementation using opencores generic_fifo */
  wire           fifo_full;
  wire           fifo_empty;
  wire           fifo_full_n;
  wire           fifo_empty_n;

  reg            fifo_valid;
  reg            fifo_underflow;
  reg            fifo_wr_ack;
  reg            fifo_overflow;

  assign empty = fifo_empty;
  assign full = fifo_full;
  assign prog_empty = fifo_empty_n;
  assign prog_full = fifo_full_n;
  assign valid = fifo_valid;
  assign underflow = fifo_underflow;
  assign wr_ack = fifo_wr_ack;
  assign overflow = fifo_overflow;

  always @(posedge rd_clk)
    if (~rst) fifo_valid <= 1'b0;
    else fifo_valid <= rd_en && ~fifo_empty;

  always @(posedge rd_clk)
    if (~rst) fifo_underflow <= 1'b0;
    else fifo_underflow <= rd_en && fifo_empty;

  always @(posedge wr_clk)
    if (~rst) fifo_wr_ack <= 1'b0;
    else fifo_wr_ack <= wr_en && ~fifo_full;

  always @(posedge wr_clk)
    if (~rst) fifo_overflow <= 1'b0;
    else fifo_overflow <= wr_en && fifo_full;

  generic_fifo_dc 
    #(.aw(addr_width),
    .dw(dta_width),
    .n(prog_thresh))
    gfifo_dc (
    .rd_clk(rd_clk), 
    .wr_clk(wr_clk), 
    .rst(rst), 
    .clr(1'b0), 
    .din(din), 
    .we(wr_en && ~fifo_full), 
    .dout(dout), 
    .re(rd_en && ~fifo_empty), 
    .full(fifo_full), 
    .empty(fifo_empty), 
    .full_n(fifo_full_n), 
    .empty_n(fifo_empty_n), 
    .level()
    );

`ifdef DEBUG
  always @(posedge rd_clk)
    $strobe("%m\tread: %h dout: %h", fifo_valid, dout);
`endif

`ifdef CHECK_FIFO_PARAMS
  initial #0
      begin
        if (prog_thresh > (1<<addr_width))
          begin
            #0 $display ("%m\t*** error: inconsistent fifo parameters. addr_width: %d prog_thresh: %d. ***", addr_width, prog_thresh);
            $finish;
          end
      end

  always @(posedge wr_clk)
    if (fifo_overflow) 
      begin
        #0 $display ("%m\t*** error: fifo overflow. ***");
      end
/*
  always @(posedge rd_clk)
    if (fifo_underflow) 
      begin
        #0 $display ("%m\t*** warning: fifo underflow. ***");
      end
*/
`endif
endmodule
/* not truncated */
