/* 
 * iquant.v
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

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

module intra_quant_matrix(clk, rst, rd_addr, rd_clk_en, dta_out, wr_addr, dta_in, wr_clk_en, wr_en, rst_values, alternate_scan);
  input           clk;
  input           rst;
  input      [5:0]rd_addr;
  input           rd_clk_en;
  output reg [7:0]dta_out;
  input      [5:0]wr_addr;
  input      [7:0]dta_in;
  input           wr_en; 
  input           wr_clk_en;
  input           rst_values;
  input           alternate_scan;

  reg default_values;
  wire    [7:0]dout_wire;
  reg     [7:0]default_do;
  reg     [5:0]iquant_wr_addr;
  reg          iquant_wr_en;
  reg     [7:0]iquant_wr_dta;

  parameter [2:0]
    STATE_INIT  = 3'b001,
    STATE_CLEAR = 3'b010,
    STATE_RUN   = 3'b100;

  reg [2:0]next;
  reg [2:0]state;

  /*
   * state machine to initialize intra_quantiser_matrix at reset
   */

  always @*
    case (state)
      STATE_INIT:  next = STATE_CLEAR;
      STATE_CLEAR: if (iquant_wr_addr == 6'h3f) next = STATE_RUN;
                   else next = STATE_CLEAR;
      STATE_RUN:   next = STATE_RUN;
      default:     next = STATE_INIT;
    endcase 

  always @(posedge clk)
    if (~rst) state <= STATE_INIT;
    else state <= next;

  always @(posedge clk)
    if (~rst) iquant_wr_en <= 1'b0;
    else
      case (state)
        STATE_INIT:  iquant_wr_en <= 1'b0;
	STATE_CLEAR: iquant_wr_en <= 1'b1;
	STATE_RUN:   iquant_wr_en <= wr_clk_en && wr_en;
	default      iquant_wr_en <= 1'b0;
      endcase

  always @(posedge clk)
    if (~rst) iquant_wr_addr <= 6'b0;
    else
      case (state)
        STATE_INIT:  iquant_wr_addr <= 6'b0;
	STATE_CLEAR: iquant_wr_addr <= iquant_wr_addr + 6'b1;
	STATE_RUN:   iquant_wr_addr <= scan_reverse(alternate_scan, wr_addr);
	default      iquant_wr_addr <= 6'b0;
      endcase

  always @(posedge clk)
    if (~rst) iquant_wr_dta <= 8'b0;
    else
      case (state)
        STATE_INIT:  iquant_wr_dta <= 8'b0;
	STATE_CLEAR: iquant_wr_dta <= 8'b0;
	STATE_RUN:   iquant_wr_dta <= dta_in;
	default      iquant_wr_dta <= 8'b0;
      endcase

  /* reading */

  always @(posedge clk) 
    if (~rst) default_do <= 8'b0;
    else if (rd_clk_en) default_do <= default_intra_quant(rd_addr);
    else default_do <= default_do;

  always @(posedge clk) 
    if (~rst) dta_out <= 8'b0;
    else if (rd_clk_en && default_values) dta_out <= default_do;
    else if (rd_clk_en) dta_out <= dout_wire;
    else dta_out <= dta_out;

  always @(posedge clk)
    if (~rst) default_values <= 1;
    else if (wr_clk_en && rst_values) default_values <= 1;
    else if (wr_clk_en && wr_en && (wr_addr == 6'h3f)) default_values <= 0; // set after last of intra_quant values has been uploaded
    else default_values <= default_values;

`include "zigzag_table.v"  

 /* 
    intra block quantisation matrix. 
    par. 6.3.11: when sequence_header_code is decoded all matrices shall be reset to their default values.
    par. 7.3.1: inverse scan for quantization matrix download: 
    the quantisation matrix is sent in zigzag (scan 0) order, so here we un-zigzag it using scan0_reverse.
  */

  dpram_sc
    #(.addr_width(6),                                         // number of bits in address bus
    .dta_width(8))                                            // number of bits in data bus
    intra_quantiser_matrix (
    .rst(rst),                                                // reset, active low
    .clk(clk),                                                // clock, rising edge trigger
    .wr_en(iquant_wr_en),                                     // write enable, active high
    .wr_addr(iquant_wr_addr),                                 // write address
    .din(iquant_wr_dta),                                      // data input
    .rd_en(1'b1),                                             // read enable, active high
    .rd_addr(rd_addr),                                        // read address
    .dout(dout_wire)                                                 // data output
    );

  /*
    Default intra block quantisation matrix values. par. 6.3.11. 
  */
     
  function [7:0]default_intra_quant;
    input [5:0]u_v;
    begin
      casex(u_v)
        6'd00: default_intra_quant = 8;
        6'd01: default_intra_quant = 16;
        6'd02: default_intra_quant = 19;
        6'd03: default_intra_quant = 22;
        6'd04: default_intra_quant = 26;
        6'd05: default_intra_quant = 27;
        6'd06: default_intra_quant = 29;
        6'd07: default_intra_quant = 34;
        6'd08: default_intra_quant = 16;
        6'd09: default_intra_quant = 16;
        6'd10: default_intra_quant = 22;
        6'd11: default_intra_quant = 24;
        6'd12: default_intra_quant = 27;
        6'd13: default_intra_quant = 29;
        6'd14: default_intra_quant = 34;
        6'd15: default_intra_quant = 37;
        6'd16: default_intra_quant = 19;
        6'd17: default_intra_quant = 22;
        6'd18: default_intra_quant = 26;
        6'd19: default_intra_quant = 27;
        6'd20: default_intra_quant = 29;
        6'd21: default_intra_quant = 34;
        6'd22: default_intra_quant = 34;
        6'd23: default_intra_quant = 38;
        6'd24: default_intra_quant = 22;
        6'd25: default_intra_quant = 22;
        6'd26: default_intra_quant = 26;
        6'd27: default_intra_quant = 27;
        6'd28: default_intra_quant = 29;
        6'd29: default_intra_quant = 34;
        6'd30: default_intra_quant = 37;
        6'd31: default_intra_quant = 40;
        6'd32: default_intra_quant = 22;
        6'd33: default_intra_quant = 26;
        6'd34: default_intra_quant = 27;
        6'd35: default_intra_quant = 29;
        6'd36: default_intra_quant = 32;
        6'd37: default_intra_quant = 35;
        6'd38: default_intra_quant = 40;
        6'd39: default_intra_quant = 48;
        6'd40: default_intra_quant = 26;
        6'd41: default_intra_quant = 27;
        6'd42: default_intra_quant = 29;
        6'd43: default_intra_quant = 32;
        6'd44: default_intra_quant = 35;
        6'd45: default_intra_quant = 40;
        6'd46: default_intra_quant = 48;
        6'd47: default_intra_quant = 58;
        6'd48: default_intra_quant = 26;
        6'd49: default_intra_quant = 27;
        6'd50: default_intra_quant = 29;
        6'd51: default_intra_quant = 34;
        6'd52: default_intra_quant = 38;
        6'd53: default_intra_quant = 46;
        6'd54: default_intra_quant = 56;
        6'd55: default_intra_quant = 69;
        6'd56: default_intra_quant = 27;
        6'd57: default_intra_quant = 29;
        6'd58: default_intra_quant = 35;
        6'd59: default_intra_quant = 38;
        6'd60: default_intra_quant = 46;
        6'd61: default_intra_quant = 56;
        6'd62: default_intra_quant = 69;
        6'd63: default_intra_quant = 83;
      endcase
    end
  endfunction

`ifdef DEBUG
  always @(posedge clk) 
    if (rd_clk_en && default_values) #0 $display("%m\tread %h from %h (default value)", default_intra_quant(rd_addr), rd_addr);
    else if (rd_clk_en) #0 $display("%m\tread %h from %h", do, rd_addr);

  always @(posedge clk)
    if (~rst) $display("%m\tset to default values");
    else if (wr_clk_en && rst_values) $display("%m\tset to default values");
    else if (wr_clk_en && wr_en) $display("%m\tset to uploaded table");

  always @(posedge clk)
    if (wr_clk_en && wr_en) #0 $display("%m\twrite %h to %h (was %h)", dta_in, scan_reverse(alternate_scan, wr_addr), wr_addr);

`endif 

endmodule
  
module non_intra_quant_matrix(clk, rst, rd_addr, rd_clk_en, dta_out, wr_addr, dta_in, wr_clk_en, wr_en, rst_values, alternate_scan);
  input           clk;
  input           rst;
  input      [5:0]rd_addr;
  input           rd_clk_en;
  output reg [7:0]dta_out;
  input      [5:0]wr_addr;
  input      [7:0]dta_in;
  input           wr_clk_en; 
  input           wr_en; 
  input           rst_values;
  input           alternate_scan;

  reg default_values;
  wire [7:0]dout_wire;
  reg     [5:0]non_iquant_wr_addr;
  reg          non_iquant_wr_en;
  reg     [7:0]non_iquant_wr_dta;

  parameter [2:0]
    STATE_INIT  = 3'b001,
    STATE_CLEAR = 3'b010,
    STATE_RUN   = 3'b100;

  reg [2:0]next;
  reg [2:0]state;

  /*
   * state machine to initialize intra_quantiser_matrix at reset
   */

  always @*
    case (state)
      STATE_INIT:  next = STATE_CLEAR;
      STATE_CLEAR: if (non_iquant_wr_addr == 6'h3f) next = STATE_RUN;
                   else next = STATE_CLEAR;
      STATE_RUN:   next = STATE_RUN;
      default:     next = STATE_INIT;
    endcase 

  always @(posedge clk)
    if (~rst) state <= STATE_INIT;
    else state <= next;

  always @(posedge clk)
    if (~rst) non_iquant_wr_en <= 1'b0;
    else
      case (state)
        STATE_INIT:  non_iquant_wr_en <= 1'b0;
	STATE_CLEAR: non_iquant_wr_en <= 1'b1;
	STATE_RUN:   non_iquant_wr_en <= wr_clk_en && wr_en;
	default      non_iquant_wr_en <= 1'b0;
      endcase

  always @(posedge clk)
    if (~rst) non_iquant_wr_addr <= 6'b0;
    else
      case (state)
        STATE_INIT:  non_iquant_wr_addr <= 6'b0;
	STATE_CLEAR: non_iquant_wr_addr <= non_iquant_wr_addr + 6'b1;
	STATE_RUN:   non_iquant_wr_addr <= scan_reverse(alternate_scan, wr_addr);
	default      non_iquant_wr_addr <= 6'b0;
      endcase

  always @(posedge clk)
    if (~rst) non_iquant_wr_dta <= 8'b0;
    else
      case (state)
        STATE_INIT:  non_iquant_wr_dta <= 8'b0;
	STATE_CLEAR: non_iquant_wr_dta <= 8'b0;
	STATE_RUN:   non_iquant_wr_dta <= dta_in;
	default      non_iquant_wr_dta <= 8'b0;
      endcase

  /* reading */

  always @(posedge clk) 
    if (rd_clk_en && default_values) dta_out <= 8'd16 ; // Default non intra block quantisation matrix value is 8'd16. par. 6.3.11.
    else if (rd_clk_en) dta_out <= dout_wire;
    else dta_out <= dta_out;

  always @(posedge clk)
    if (~rst) default_values <= 1;
    else if (wr_clk_en && rst_values) default_values <= 1;
    else if (wr_clk_en && wr_en && (wr_addr == 6'h3f)) default_values <= 0; // set after last of non_intra_quant values has been uploaded
    else default_values <= default_values;

`include "zigzag_table.v"  
  /* 
    non intra block quantisation matrix. 
    par. 6.3.11: when sequence_header_code is decoded all matrices shall be reset to their default values.
    par. 7.3.1: inverse scan for quantization matrix download: 
    the quantisation matrix is sent in zigzag (scan 0) order, so here we un-zigzag it using scan0_reverse.
  */

  dpram_sc
    #(.addr_width(6),                                         // number of bits in address bus
    .dta_width(8))                                            // number of bits in data bus
    non_intra_quantiser_matrix (
    .rst(rst),                                                // reset, active low
    .clk(clk),                                                // clock, rising edge trigger
    .wr_en(non_iquant_wr_en),                                 // write enable, active high
    .wr_addr(non_iquant_wr_addr),                             // write address
    .din(non_iquant_wr_dta),                                  // data input
    .rd_en(1'b1),                                             // read enable, active high
    .rd_addr(rd_addr),                                        // read address
    .dout(dout_wire)                                                 // data output
    );

`ifdef DEBUG
  always @(posedge clk) 
    if (rd_clk_en && default_values) #0 $display("%m\tread %h from %h (default value)", 8'd16, rd_addr);
    else if (rd_clk_en) #0 $display("%m\tread %h from %h", dout_wire, rd_addr);

  always @(posedge clk)
    if (~rst) $display("%m\tset to default values");
    else if (wr_clk_en && rst_values) $display("%m\tset to default values");
    else if (wr_clk_en && wr_en && (wr_addr == 6'h3f)) $display("%m\tset to uploaded table");

  always @(posedge clk)
    if (wr_clk_en && wr_en) #0 $display("%m\twrite %h to %h (was %h)", dta_in, scan_reverse(alternate_scan, wr_addr), wr_addr);

`endif 

endmodule
/* not truncated */
