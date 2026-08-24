/* 
 * fwft.v
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
 * fwft.v - convert standard fifo in first-word fall-through fifo.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

/* 
 * Converts a normal fifo to a a first-word fall-through fifo.
 * Does not change data width: output data has same width as input data.
 */

module fwft_reader (rst, clk, clk_en,
                    fifo_rd_en, fifo_valid, fifo_dout,
                    valid, dout, rd_en);

  parameter [8:0]dta_width=9'd8;

  input                 rst;
  input                 clk;
  input                 clk_en;
  output reg            fifo_rd_en;
  input                 fifo_valid;
  input  [dta_width-1:0]fifo_dout;
  output                valid;
  output [dta_width-1:0]dout;
  input                 rd_en;

  reg    [dta_width-1:0]dta_0;
  reg    [dta_width-1:0]next_dta_0;
  reg                   dta_0_valid;
  reg                   next_dta_0_valid;

  reg    [dta_width-1:0]dta_1;
  reg    [dta_width-1:0]next_dta_1;
  reg                   dta_1_valid;
  reg                   next_dta_1_valid;

  reg    [dta_width-1:0]dta_2;
  reg    [dta_width-1:0]next_dta_2;
  reg                   dta_2_valid;
  reg                   next_dta_2_valid;

  /* keep reading until dta_1 valid */
  always @(posedge clk)
    if (~rst) fifo_rd_en <= 1'b0;
    else if (clk_en) fifo_rd_en <= ~next_dta_1_valid;

  /* outputs */
  assign valid = dta_0_valid;
  assign dout  = dta_0;

  /* writing data */
  always @*
    if (fifo_valid && ~dta_0_valid && ~dta_1_valid && ~dta_2_valid)
      begin
        next_dta_0 = fifo_dout;
        next_dta_0_valid = fifo_valid;
      end
    else
      begin
        next_dta_0 = dta_0;
        next_dta_0_valid = dta_0_valid;
      end

  always @*
    if (fifo_valid &&  dta_0_valid && ~dta_1_valid && ~dta_2_valid)
      begin
        next_dta_1 = fifo_dout;
        next_dta_1_valid = fifo_valid;
      end
    else
      begin
        next_dta_1 = dta_1;
        next_dta_1_valid = dta_1_valid;
      end

  always @*
    if (fifo_valid &&  dta_0_valid &&  dta_1_valid && ~dta_2_valid)
      begin
        next_dta_2 = fifo_dout;
        next_dta_2_valid = fifo_valid;
      end
    else
      begin
        next_dta_2 = dta_2;
        next_dta_2_valid = dta_2_valid;
      end

  /* reading data */
  always @(posedge clk)
    if (~rst)
      begin
        dta_0 <= {dta_width{1'b0}};
        dta_1 <= {dta_width{1'b0}};
        dta_2 <= {dta_width{1'b0}};
        dta_0_valid <= 1'b0;
        dta_1_valid <= 1'b0;
        dta_2_valid <= 1'b0;
      end
    else if (clk_en && rd_en && valid) /* discard rd_en if dout not valid */
      begin
        dta_0 <= next_dta_1;
        dta_1 <= next_dta_2;
        dta_2 <= {dta_width{1'b0}};
        dta_0_valid <= next_dta_1_valid;
        dta_1_valid <= next_dta_2_valid;
        dta_2_valid <= 1'b0;
      end
    else if (clk_en)
      begin
        dta_0 <= next_dta_0;
        dta_1 <= next_dta_1;
        dta_2 <= next_dta_2;
        dta_0_valid <= next_dta_0_valid;
        dta_1_valid <= next_dta_1_valid;
        dta_2_valid <= next_dta_2_valid;
      end
    else
      begin
        dta_0 <= dta_0;
        dta_1 <= dta_1;
        dta_2 <= dta_2;
        dta_0_valid <= dta_0_valid;
        dta_1_valid <= dta_1_valid;
        dta_2_valid <= dta_2_valid;
      end

`ifdef DEBUG
  always @(posedge clk)
    if (clk_en)
      begin
        $strobe("%m\tdout: %h valid: %h rd_en: %h fifo_dout: %h fifo_valid: %h fifo_rd_en: %h",
                     dout, valid, rd_en, fifo_dout, fifo_valid, fifo_rd_en);
        $strobe("%m\tdta_0: %h dta_0_valid: %h dta_1: %h dta_1_valid: %h dta_2: %h dta_2_valid: %h",
	             dta_0, dta_0_valid, dta_1, dta_1_valid, dta_2, dta_2_valid)
      end
`endif

endmodule


/*
 * Converts a normal fifo to a a first-word fall-through fifo.
 * Converts data width: output data is 2 times as wide as input data. 
 */

module fwft2_reader (rst, clk, clk_en,
                    fifo_rd_en, fifo_valid, fifo_dout,
                    valid, dout, rd_en);

  parameter [8:0]dta_width=9'd8;

  input                 rst;
  input                 clk;
  input                 clk_en;
  output reg            fifo_rd_en;
  input                 fifo_valid;
  input  [dta_width-1:0]fifo_dout;
  output                valid;
  output [2*dta_width-1:0]dout;
  input                 rd_en;

  reg    [dta_width-1:0]dta_0;
  reg    [dta_width-1:0]next_dta_0;
  reg                   dta_0_valid;
  reg                   next_dta_0_valid;

  reg    [dta_width-1:0]dta_1;
  reg    [dta_width-1:0]next_dta_1;
  reg                   dta_1_valid;
  reg                   next_dta_1_valid;

  reg    [dta_width-1:0]dta_2;
  reg    [dta_width-1:0]next_dta_2;
  reg                   dta_2_valid;
  reg                   next_dta_2_valid;

  reg    [dta_width-1:0]dta_3;
  reg    [dta_width-1:0]next_dta_3;
  reg                   dta_3_valid;
  reg                   next_dta_3_valid;

  reg    [dta_width-1:0]dta_4;
  reg    [dta_width-1:0]next_dta_4;
  reg                   dta_4_valid;
  reg                   next_dta_4_valid;

  /* keep reading until dta_3 valid */
  always @(posedge clk)
    if (~rst) fifo_rd_en <= 1'b0;
    else if (clk_en) fifo_rd_en <= ~next_dta_3_valid;

  /* outputs */
  assign valid = dta_1_valid;
  assign dout  = {dta_0, dta_1};

  /* writing data */
  always @*
    if (fifo_valid && ~dta_0_valid && ~dta_1_valid && ~dta_2_valid && ~dta_3_valid && ~dta_4_valid)
      begin
        next_dta_0 = fifo_dout;
        next_dta_0_valid = fifo_valid;
      end
    else
      begin
        next_dta_0 = dta_0;
        next_dta_0_valid = dta_0_valid;
      end

  always @*
    if (fifo_valid &&  dta_0_valid && ~dta_1_valid && ~dta_2_valid && ~dta_3_valid && ~dta_4_valid)
      begin
        next_dta_1 = fifo_dout;
        next_dta_1_valid = fifo_valid;
      end
    else
      begin
        next_dta_1 = dta_1;
        next_dta_1_valid = dta_1_valid;
      end

  always @*
    if (fifo_valid &&  dta_0_valid &&  dta_1_valid && ~dta_2_valid && ~dta_3_valid && ~dta_4_valid)
      begin
        next_dta_2 = fifo_dout;
        next_dta_2_valid = fifo_valid;
      end
    else
      begin
        next_dta_2 = dta_2;
        next_dta_2_valid = dta_2_valid;
      end

  always @*
    if (fifo_valid &&  dta_0_valid &&  dta_1_valid &&  dta_2_valid && ~dta_3_valid && ~dta_4_valid)
      begin
        next_dta_3 = fifo_dout;
        next_dta_3_valid = fifo_valid;
      end
    else
      begin
        next_dta_3 = dta_3;
        next_dta_3_valid = dta_3_valid;
      end

  always @*
    if (fifo_valid &&  dta_0_valid &&  dta_1_valid &&  dta_2_valid &&  dta_3_valid && ~dta_4_valid)
      begin
        next_dta_4 = fifo_dout;
        next_dta_4_valid = fifo_valid;
      end
    else
      begin
        next_dta_4 = dta_4;
        next_dta_4_valid = dta_4_valid;
      end

  /* reading data */
  always @(posedge clk)
    if (~rst)
      begin
        dta_0 <= {dta_width{1'b0}};
        dta_1 <= {dta_width{1'b0}};
        dta_2 <= {dta_width{1'b0}};
        dta_3 <= {dta_width{1'b0}};
        dta_4 <= {dta_width{1'b0}};
        dta_0_valid <= 1'b0;
        dta_1_valid <= 1'b0;
        dta_2_valid <= 1'b0;
        dta_3_valid <= 1'b0;
        dta_4_valid <= 1'b0;
      end
    else if (clk_en && rd_en && valid) /* discard rd_en if dout not valid */
      begin
        dta_0 <= next_dta_2;
        dta_1 <= next_dta_3;
        dta_2 <= next_dta_4;
        dta_3 <= {dta_width{1'b0}};
        dta_4 <= {dta_width{1'b0}};
        dta_0_valid <= next_dta_2_valid;
        dta_1_valid <= next_dta_3_valid;
        dta_2_valid <= next_dta_4_valid;
        dta_3_valid <= 1'b0;
        dta_4_valid <= 1'b0;
      end
    else if (clk_en)
      begin
        dta_0 <= next_dta_0;
        dta_1 <= next_dta_1;
        dta_2 <= next_dta_2;
        dta_3 <= next_dta_3;
        dta_4 <= next_dta_4;
        dta_0_valid <= next_dta_0_valid;
        dta_1_valid <= next_dta_1_valid;
        dta_2_valid <= next_dta_2_valid;
        dta_3_valid <= next_dta_3_valid;
        dta_4_valid <= next_dta_4_valid;
      end
    else
      begin
        dta_0 <= dta_0;
        dta_1 <= dta_1;
        dta_2 <= dta_2;
        dta_3 <= dta_3;
        dta_4 <= dta_4;
        dta_0_valid <= dta_0_valid;
        dta_1_valid <= dta_1_valid;
        dta_2_valid <= dta_2_valid;
        dta_3_valid <= dta_3_valid;
        dta_4_valid <= dta_4_valid;
      end

`ifdef DEBUG
  always @(posedge clk)
    if (clk_en)
      begin
        $strobe("%m\tdout: %h valid: %h rd_en: %h fifo_dout: %h fifo_valid: %h fifo_rd_en: %h",
                     dout, valid, rd_en, fifo_dout, fifo_valid, fifo_rd_en);
        $strobe("%m\tdta_0: %h dta_0_valid: %h dta_1: %h dta_1_valid: %h dta_2: %h dta_2_valid: %h dta_3: %h dta_3_valid: %h dta_4: %h dta_4_valid: %h",
	             dta_0, dta_0_valid, dta_1, dta_1_valid, dta_2, dta_2_valid, dta_3, dta_3_valid, dta_4, dta_4_valid);
      end
`endif
endmodule
/* not truncated */
