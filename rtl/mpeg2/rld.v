/* 
 * rld.v
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
 * rld - run/length decoder.
 * input:  DCT coefficients, as run/signed level pairs, quantizer matrix updates. output: blocks of 64 DCT coefficients, signed.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1
`undef DEBUG_IQUANT
//`define DEBUG_IQUANT 1
`undef CHECK
`ifdef __IVERILOG__
`define CHECK 1
`endif

module rld(clk, clk_en, rst, 
  idct_fifo_almost_full,
  dct_coeff_rd_run, dct_coeff_rd_signed_level, dct_coeff_rd_end,                                            // dct run/level values input
  alternate_scan_rd, q_scale_type_rd, macroblock_intra_rd, intra_dc_precision_rd, quantiser_scale_code_rd,  // aux variables
  quant_wr_data_rd, quant_wr_addr_rd, quant_rst_rd, quant_wr_intra_rd, quant_wr_non_intra_rd,               // quantizer matrix updates
  quant_wr_chroma_intra_rd, quant_wr_chroma_non_intra_rd,
  rld_cmd_rd,                                                                                               // rld command: rld_DCT or RLD_QUANT
  rld_rd_valid, rld_rd_en,                                                                                  // rld_fifo read enable
  quant_rst, quant_rd_addr, quant_rd_intra_data, quant_rd_non_intra_data,		                    // interface with quantizer matrices
  quant_wr_data, quant_wr_addr, quant_wr_en_intra, quant_wr_en_non_intra,
  quant_wr_en_chroma_intra, quant_wr_en_chroma_non_intra, quant_alternate_scan,
  iquant_level, iquant_eob, iquant_valid         		                                            // interface with idct - dct coefficients output 
  );

  input                    clk;                          // clock
  input                    clk_en;                       // clock enable
  input                    rst;                          // synchronous active low reset
  input                    idct_fifo_almost_full;
  input               [5:0]dct_coeff_rd_run;
  input signed       [11:0]dct_coeff_rd_signed_level;
  input                    dct_coeff_rd_end;
  input                    alternate_scan_rd;            // choose zigzag scan order 0 or 1
  input                    q_scale_type_rd;              // whether linear or non-linear quantiser scale
  input                    macroblock_intra_rd;          // whether intra or non-intra macroblock
  input               [1:0]intra_dc_precision_rd;        // 
  input               [4:0]quantiser_scale_code_rd;      // quantiser scale code, par. 7.4.2.2
  input               [7:0]quant_wr_data_rd;
  input               [5:0]quant_wr_addr_rd;
  input                    quant_rst_rd;
  input                    quant_wr_intra_rd;
  input                    quant_wr_non_intra_rd;
  input                    quant_wr_chroma_intra_rd;
  input                    quant_wr_chroma_non_intra_rd;
  input               [1:0]rld_cmd_rd;
  input                    rld_rd_valid;
  output reg               rld_rd_en;

  output reg               quant_rst;
  output reg          [5:0]quant_rd_addr;             // address bus for reading quantizer matrix rams
  input               [7:0]quant_rd_intra_data;       // data bus for reading quantizer matrix rams
  input               [7:0]quant_rd_non_intra_data;   // data bus for reading quantizer matrix rams
  output reg          [7:0]quant_wr_data;
  output reg          [5:0]quant_wr_addr;
  output reg               quant_wr_en_intra;
  output reg               quant_wr_en_non_intra;
  output reg               quant_wr_en_chroma_intra;
  output reg               quant_wr_en_chroma_non_intra;
  output reg               quant_alternate_scan;

  output reg signed  [11:0]iquant_level;              // inverse quantized dct coefficient
  output reg               iquant_eob;                // asserted at last inverse quantized dct coefficient of block
  output reg               iquant_valid;              // asserted when inverse quantized dct coefficient valid

  reg          [6:0]run;
  reg signed  [11:0]level;       // 12 bits
  wire signed [12:0]sign_level;  // 13 bits; sign(level): 0 if level == 0; 1 if level > 0; -1 if level < 0.
  reg               level_valid;
  reg               end_of_block;
  reg          [6:0]cnt;
  reg          [6:0]quantiser_scale;

  reg signed  [12:0]iquant_level_0; // 13 bits
  reg signed  [12:0]iquant_level_1; // 13 bits
  reg signed  [12:0]iquant_level_2; // 13 bits
  reg signed  [22:0]iquant_level_3; // 22 bits
  reg signed  [11:0]iquant_level_4; // 12 bits
  reg signed  [11:0]iquant_level_5; // 12 bits
  reg         [14:0]iquant_factor_2; // 15 bits
  reg          [5:0]iquant_addr_0;
  reg          [5:0]iquant_addr_1;
  reg          [5:0]iquant_addr_2;
  reg          [5:0]iquant_addr_3;
  reg          [5:0]iquant_addr_4;
  reg          [5:0]iquant_addr_5;
  reg               iquant_intra_dc;
  reg               iquant_intra_dc_0;
  reg               iquant_intra_dc_1;
  reg               iquant_intra_dc_2;
  reg               iquant_eob_0;
  reg               iquant_eob_1;
  reg               iquant_eob_2;
  reg               iquant_eob_3;
  reg               iquant_eob_4;
  reg               iquant_eob_5;
  reg               iquant_valid_0;
  reg               iquant_valid_1;
  reg               iquant_valid_2;
  reg               iquant_valid_3;
  reg               iquant_valid_4;
  reg               iquant_valid_5;

  reg               iquant_oddness;
  reg               iquant_valid_out_0;
  reg               iquant_eob_out_0;

  reg          [6:0]ram_rd_addr;
  wire        [11:0]ram0_rd_data;
  wire        [11:0]ram1_rd_data;
  reg          [5:0]ram_wr_addr;
  reg         [11:0]ram_wr_data;
  reg               ram0_wr_enable;
  reg               ram1_wr_enable;
  reg               ram0_rd_enable;
  reg               ram1_rd_enable;
  reg               ram_write_select;
  reg               ram_initialized;          // reset at powerup, set after first block is written.

  reg          [2:0]state;
  reg          [2:0]next;

  parameter [2:0]
    STATE_INIT      = 3'd0,
    STATE_IDLE      = 3'd1,
    STATE_RUN       = 3'd2,
    STATE_LEVEL     = 3'd3,
    STATE_END_RUN   = 3'd4,
    STATE_QUANT     = 3'd5;

`include "zigzag_table.v"
`include "vld_codes.v"

/* next state logic */
  always @*
    case (state)                  
      STATE_INIT:                 if (idct_fifo_almost_full) next = STATE_INIT;
                                  else next = STATE_IDLE;

      STATE_IDLE:                 if (~rld_rd_valid) next = STATE_IDLE;                                                                // wait for next input
                                  else if ((rld_cmd_rd == RLD_DCT) && dct_coeff_rd_end) next = STATE_END_RUN;                             // end of block received
                                  else if ((rld_cmd_rd == RLD_DCT) && (cnt <= 7'd63) && (dct_coeff_rd_run == 6'd0)) next = STATE_LEVEL;   // output level
                                  else if ((rld_cmd_rd == RLD_DCT) && (cnt <= 7'd63)) next = STATE_RUN;                                // output run of zeroes
                                  else if (rld_cmd_rd == RLD_QUANT) next = STATE_QUANT;                                                // update quantiser matrices
                                  else next = STATE_IDLE;


      STATE_RUN:                  if (cnt == 7'd63) next = STATE_IDLE;                                             // all 64 levels have been output. 
                                  else if (run == 6'd1) next = STATE_LEVEL;                                        // run of zeroes has been output. output level next.
                                  else next = STATE_RUN;                                                           // output run of zeroes 

      STATE_LEVEL:                if (cnt == 7'd63) next = STATE_IDLE;                                             // all 64 levels have been output.
                                  else next = STATE_IDLE;                                                          // level has been output. wait for next coefficient.

      STATE_END_RUN:              if (cnt >= 7'd63) next = STATE_INIT;                                             // final zeroes have been output. wait for next block.
                                  else next = STATE_END_RUN;                                                       // output end run of zeroes

      STATE_QUANT:                next = STATE_IDLE;                                                               // update quantiser matrix

      default                     next = STATE_INIT;
    endcase

/* state */
  always @(posedge clk)
    if(~rst) state <= STATE_INIT;
    else if (clk_en) state <= next;
    else  state <= state;
              
/* buffer fifo output */
  reg                 [5:0]dct_coeff_run;
  reg signed         [11:0]dct_coeff_signed_level;
  reg                      dct_coeff_end;
  reg                      alternate_scan;            // choose zigzag scan order 0 or 1
  reg                      q_scale_type;              // whether linear or non-linear quantiser scale
  reg                      macroblock_intra;          // whether intra or non-intra macroblock
  reg                 [1:0]intra_dc_precision;        // 
  reg                 [4:0]quantiser_scale_code;      // quantiser scale code, par. 7.4.2.2

  always @(posedge clk)
    if (~rst) dct_coeff_run <= 6'd0;
    else if (clk_en && rld_rd_valid) dct_coeff_run <= dct_coeff_rd_run;
    else  dct_coeff_run <= dct_coeff_run;

  always @(posedge clk)
    if (~rst) dct_coeff_signed_level <= 12'd0;
    else if (clk_en && rld_rd_valid) dct_coeff_signed_level <= dct_coeff_rd_signed_level;
    else  dct_coeff_signed_level <= dct_coeff_signed_level;

  always @(posedge clk)
    if (~rst) dct_coeff_end <= 1'd0;
    else if (clk_en && rld_rd_valid) dct_coeff_end <= dct_coeff_rd_end;
    else  dct_coeff_end <= dct_coeff_end;

  always @(posedge clk)
    if (~rst) alternate_scan <= 1'd0;
    else if (clk_en && rld_rd_valid) alternate_scan <= alternate_scan_rd;
    else  alternate_scan <= alternate_scan;

  always @(posedge clk)
    if (~rst) q_scale_type <= 1'd0;
    else if (clk_en && rld_rd_valid) q_scale_type <= q_scale_type_rd;
    else  q_scale_type <= q_scale_type;

  always @(posedge clk)
    if (~rst) macroblock_intra <= 1'd0;
    else if (clk_en && rld_rd_valid) macroblock_intra <= macroblock_intra_rd;
    else  macroblock_intra <= macroblock_intra;

  always @(posedge clk)
    if (~rst) intra_dc_precision <= 2'd0;
    else if (clk_en && rld_rd_valid) intra_dc_precision <= intra_dc_precision_rd;
    else  intra_dc_precision <= intra_dc_precision;

  always @(posedge clk)
    if (~rst) quantiser_scale_code <= 5'd0;
    else if (clk_en && rld_rd_valid) quantiser_scale_code <= quantiser_scale_code_rd;
    else  quantiser_scale_code <= quantiser_scale_code;

/* internal registers */

  always @(posedge clk)
    if (~rst) run <= 6'd0;
    else if (clk_en && (state == STATE_IDLE)) run <= dct_coeff_rd_run;
    else if (clk_en && (state == STATE_RUN)) run <= run - 6'd1;
    else run <= run;

  always @(posedge clk)
    if (~rst) cnt <= 6'd0;
    else if (clk_en && (state == STATE_INIT)) cnt <= 6'd0;
    else if (clk_en && ((state == STATE_RUN) || (state == STATE_LEVEL) || (state == STATE_END_RUN))) cnt <= cnt + 6'd1;
    else cnt <= cnt;

  always @(posedge clk)
    if (~rst) level <= 12'd0;
    else if (clk_en && ((state == STATE_RUN) || (state == STATE_END_RUN))) level <= 12'd0;
    else if (clk_en && (state == STATE_LEVEL)) level <= dct_coeff_signed_level;
    else level <= level;

  always @(posedge clk)
    if (~rst) level_valid <= 1'd0;
    else if (clk_en) level_valid <= ((state == STATE_RUN) || (state == STATE_LEVEL) || (state == STATE_END_RUN)) && (cnt <= 6'd63);
    else level_valid <= level_valid;

  always @(posedge clk)
    if (~rst) end_of_block <= 1'd0;
    else if (clk_en) end_of_block <= ((state == STATE_RUN) || (state == STATE_LEVEL) || (state == STATE_END_RUN)) && (cnt == 6'd63);
    else end_of_block <= end_of_block;

  always @(posedge clk)
    if (~rst) iquant_intra_dc <= 1'd0;
    else if (clk_en) iquant_intra_dc <= macroblock_intra && (cnt == 6'd0);
    else iquant_intra_dc <= iquant_intra_dc;

  always @(posedge clk)
    if (~rst) rld_rd_en <= 1'd0;
    else if (clk_en && (state == STATE_IDLE)) rld_rd_en <= ~rld_rd_en && ~rld_rd_valid;
    else if (clk_en) rld_rd_en <= 1'b0;
    else rld_rd_en <= rld_rd_en;

  /*
   * quantiser rams interface
   */

  always @(posedge clk)
    if (~rst) quant_rst <= 1'b0;
    else if (clk_en && (state == STATE_IDLE) && rld_rd_valid && (rld_cmd_rd == RLD_QUANT)) quant_rst <= quant_rst_rd;
    else if (clk_en) quant_rst <= 1'b0;
    else quant_rst <= quant_rst;

  always @(posedge clk)
    if (~rst) quant_rd_addr <= 6'd0;
    else if (clk_en) quant_rd_addr <= scan_reverse(quant_alternate_scan, cnt[5:0]); // do inverse zig-zag
    else quant_rd_addr <= quant_rd_addr;

  always @(posedge clk)
    if (~rst) quant_wr_data <= 8'b0;
    else if (clk_en && (state == STATE_IDLE) && rld_rd_valid && (rld_cmd_rd == RLD_QUANT)) quant_wr_data <= quant_wr_data_rd;
    else quant_wr_data <= quant_wr_data;

  always @(posedge clk)
    if (~rst) quant_wr_addr <= 6'b0;
    else if (clk_en && (state == STATE_IDLE) && rld_rd_valid && (rld_cmd_rd == RLD_QUANT)) quant_wr_addr <= quant_wr_addr_rd;
    else quant_wr_addr <= quant_wr_addr;

  always @(posedge clk)
    if (~rst) quant_wr_en_intra <= 1'b0;
    else if (clk_en && (state == STATE_IDLE) && rld_rd_valid && (rld_cmd_rd == RLD_QUANT)) quant_wr_en_intra <= quant_wr_intra_rd;
    else if (clk_en) quant_wr_en_intra <= 1'b0;
    else quant_wr_en_intra <= quant_wr_en_intra;

  always @(posedge clk)
    if (~rst) quant_wr_en_non_intra <= 1'b0;
    else if (clk_en && (state == STATE_IDLE) && rld_rd_valid && (rld_cmd_rd == RLD_QUANT)) quant_wr_en_non_intra <= quant_wr_non_intra_rd;
    else if (clk_en) quant_wr_en_non_intra <= 1'b0;
    else quant_wr_en_non_intra <= quant_wr_en_non_intra;

  always @(posedge clk)
    if (~rst) quant_wr_en_chroma_intra <= 1'b0;
    else if (clk_en && (state == STATE_IDLE) && rld_rd_valid && (rld_cmd_rd == RLD_QUANT)) quant_wr_en_chroma_intra <= quant_wr_chroma_intra_rd;
    else if (clk_en) quant_wr_en_chroma_intra <= 1'b0;
    else quant_wr_en_chroma_intra <= quant_wr_en_chroma_intra;

  always @(posedge clk)
    if (~rst) quant_wr_en_chroma_non_intra <= 1'b0;
    else if (clk_en && (state == STATE_IDLE) && rld_rd_valid && (rld_cmd_rd == RLD_QUANT)) quant_wr_en_chroma_non_intra <= quant_wr_chroma_non_intra_rd;
    else if (clk_en) quant_wr_en_chroma_non_intra <= 1'b0;
    else quant_wr_en_chroma_non_intra <= quant_wr_en_chroma_non_intra;

  always @(posedge clk)
    if (~rst) quant_alternate_scan <= 1'b0;
    else if (clk_en && (state == STATE_IDLE) && rld_rd_valid && ((rld_cmd_rd == RLD_DCT) || (rld_cmd_rd == RLD_QUANT))) quant_alternate_scan <= alternate_scan_rd;
    else quant_alternate_scan <= quant_alternate_scan;

  /*
   * inverse quantisation, pipelined. (par. 7.4)
   */

  /* 
   * first stage. Special case of Intra DC coefficient. (par. 7.4.1)
   *
   */
  assign sign_level = { {12{level[11]}}, |level}; // +1 if level > 0 ; 0 if level = 0; -1 if level < 0

  always @(posedge clk)
    if (~rst) iquant_level_0 <= 13'd0;
    else if (clk_en) 
      begin // Par. 7.4.2.3
        if (iquant_intra_dc)
          case (intra_dc_precision) // intra dc coefficient, par. 7.4.1
            2'd0: iquant_level_0 <= level << 3;
	    2'd1: iquant_level_0 <= level << 2;
	    2'd2: iquant_level_0 <= level << 1;
	    2'd3: iquant_level_0 <= {level[11], level}; // sign extend level
          endcase
        else if (macroblock_intra) // intra block but not dc coefficient
	  iquant_level_0 <= level << 1; // iquant_valid_0 <= 2 * level (par. 7.4.2.3)
        else // non-intra block
	  iquant_level_0 <= (level <<< 1) + sign_level; // iquant_valid_0 <= 2 * level + k; k = sign(level) (par. 7.4.2.3)
      end
    else iquant_level_0 <= iquant_level_0;
 
  /* 
   * "oddness" of sum of previous iquant_levels. See par. 7.4.4, note 1.
   */

  always @(posedge clk) 
    if (~rst) iquant_oddness <= 1'd0;
    else if (clk_en && iquant_valid_4 && iquant_eob_4) iquant_oddness <= 1'b0;
    else if (clk_en && iquant_valid_4) iquant_oddness <= iquant_oddness ^ iquant_level_4[0];
    else iquant_oddness <= iquant_oddness;

  /* 
   * "oddness" of sum of all iquant_levels (previous and current). See par. 7.4.4, note 1.
   */

  wire iquant_oddness_sum = iquant_oddness ^ iquant_level_4[0];
  wire signed [15:0]iquant_factor_2_signed = {1'b0, iquant_factor_2};
  wire signed [22:0]iquant_level_3_correction = {17'b0, {5{iquant_level_2[12]}}};
 
  always @(posedge clk)
    if (~rst) 
      begin
        iquant_level_1 <= 13'd0;
        iquant_level_2 <= 13'd0;
        iquant_level_3 <= 18'd0;
        iquant_level_4 <= 12'd0;
        iquant_level_5 <= 12'd0;
      end
    else if (clk_en)
      begin
        iquant_level_1 <= iquant_level_0; 
        iquant_level_2 <= iquant_level_1; 
        if (iquant_intra_dc_2) 
	  iquant_level_3 <= {{10{iquant_level_2[12]}}, iquant_level_2} ; // sign extend
	else 
	  /* 
	   * par. 7.4.2.3, note 1: the above equation uses the "/" operator as defined in 4.1
	   * par. 4.1 defines / as Integer division with truncation of the result toward zero. 
	   * For example, 7/4 and -7/-4 are truncated to 1 and -7/4 and 7/-4 are truncated to -1.
	   *
	   * >>> 5 divides positive numbers correctly by 32. 
	   * It does not correctly divide negative numbers by 32; for instance -1 >>> 5 is -1. 
	   * For correct results, add sd31 to negative numbers. 
	   * Here: add 5'bsssss, with s the sign bit of the product.
	   */
	  // Xilinx ISE 6.3 doesn't know $signed
	  //iquant_level_3 <= (iquant_level_2 * $signed({1'b0, iquant_factor_2}) + $signed({5{iquant_level_2[12]}})) >>> 5; // signed multiply
	  iquant_level_3 <= (iquant_level_2 * iquant_factor_2_signed + iquant_level_3_correction) >>> 5; // signed multiply
	if ((iquant_level_3[22:11] == 12'b000000000000) || (iquant_level_3[22:11] == 12'b111111111111)) 
	  iquant_level_4 <= iquant_level_3[11:0];
	else 
	  iquant_level_4 <= {iquant_level_3[22], {11{~iquant_level_3[22]}}}; // Saturation, par. 7.4.3
        iquant_level_5 <= (iquant_oddness_sum || ~iquant_eob_4) ? iquant_level_4 : {iquant_level_4[11:1], ~iquant_level_4[0]}; // Mismatch control, par. 7.4.4, implemented as of note 1.
      end
    else
      begin
        iquant_level_1 <= iquant_level_1;
        iquant_level_2 <= iquant_level_2;
        iquant_level_3 <= iquant_level_3;
        iquant_level_4 <= iquant_level_4;
        iquant_level_5 <= iquant_level_5;
      end

  wire [7:0]quant_mat = macroblock_intra ? quant_rd_intra_data : quant_rd_non_intra_data;

  reg          [6:0]quantiser_scale_0;
  reg          [6:0]quantiser_scale_1;

  always @(posedge clk)
    if (~rst) 
      begin
        quantiser_scale_0 <= 7'd0;
        quantiser_scale_1 <= 7'd0;
      end
    else if (clk_en)
      begin
        quantiser_scale_0 <= quantiser_scale;
        quantiser_scale_1 <= quantiser_scale_0;
      end
    else 
      begin
        quantiser_scale_0 <= quantiser_scale_0;
        quantiser_scale_1 <= quantiser_scale_1;
      end

  always @(posedge clk)
    if (~rst) iquant_factor_2 <= 15'd0;
    else if (clk_en) iquant_factor_2 <= quantiser_scale_1 * quant_mat; // unsigned multiply
    else iquant_factor_2 <= iquant_factor_2;

  always @(posedge clk)
    if (~rst) 
      begin
        iquant_addr_0 <= 6'b0;
        iquant_addr_1 <= 6'b0;
        iquant_addr_2 <= 6'b0;
        iquant_addr_3 <= 6'b0;
        iquant_addr_4 <= 6'b0;
        iquant_addr_5 <= 6'b0;
      end
    else if (clk_en)
      begin
        iquant_addr_0 <= quant_rd_addr;
        iquant_addr_1 <= iquant_addr_0;
        iquant_addr_2 <= iquant_addr_1;
        iquant_addr_3 <= iquant_addr_2;
        iquant_addr_4 <= iquant_addr_3;
        iquant_addr_5 <= iquant_addr_4;
      end
    else
      begin
        iquant_addr_0 <= iquant_addr_0;
        iquant_addr_1 <= iquant_addr_1;
        iquant_addr_2 <= iquant_addr_2;
        iquant_addr_3 <= iquant_addr_3;
        iquant_addr_4 <= iquant_addr_4;
        iquant_addr_5 <= iquant_addr_5;
      end

  always @(posedge clk)
    if (~rst) 
      begin
        iquant_valid_0 <= 1'b0;
        iquant_valid_1 <= 1'b0;
        iquant_valid_2 <= 1'b0;
        iquant_valid_3 <= 1'b0;
        iquant_valid_4 <= 1'b0;
        iquant_valid_5 <= 1'b0;
      end
    else if (clk_en)
      begin
        iquant_valid_0 <= level_valid;
        iquant_valid_1 <= iquant_valid_0;
        iquant_valid_2 <= iquant_valid_1;
        iquant_valid_3 <= iquant_valid_2;
        iquant_valid_4 <= iquant_valid_3;
        iquant_valid_5 <= iquant_valid_4;
      end
    else
      begin
        iquant_valid_0 <= iquant_valid_0;
        iquant_valid_1 <= iquant_valid_1;
        iquant_valid_2 <= iquant_valid_2;
        iquant_valid_3 <= iquant_valid_3;
        iquant_valid_4 <= iquant_valid_4;
        iquant_valid_5 <= iquant_valid_5;
      end

  always @(posedge clk)
    if (~rst) 
      begin
        iquant_intra_dc_0 <= 1'b0;
        iquant_intra_dc_1 <= 1'b0;
        iquant_intra_dc_2 <= 1'b0;
      end
    else if (clk_en)
      begin
        iquant_intra_dc_0 <= iquant_intra_dc;
        iquant_intra_dc_1 <= iquant_intra_dc_0;
        iquant_intra_dc_2 <= iquant_intra_dc_1;
      end
    else 
      begin
        iquant_intra_dc_0 <= iquant_intra_dc_0;
        iquant_intra_dc_1 <= iquant_intra_dc_1;
        iquant_intra_dc_2 <= iquant_intra_dc_2;
      end

  always @(posedge clk)
    if (~rst) 
      begin
        iquant_eob_0 <= 1'b0;
        iquant_eob_1 <= 1'b0;
        iquant_eob_2 <= 1'b0;
        iquant_eob_3 <= 1'b0;
        iquant_eob_4 <= 1'b0;
        iquant_eob_5 <= 1'b0;
      end
    else if (clk_en)
      begin
        iquant_eob_0 <= end_of_block;
        iquant_eob_1 <= iquant_eob_0;
        iquant_eob_2 <= iquant_eob_1;
        iquant_eob_3 <= iquant_eob_2;
        iquant_eob_4 <= iquant_eob_3;
        iquant_eob_5 <= iquant_eob_4;
      end
    else
      begin
        iquant_eob_0 <= iquant_eob_0;
        iquant_eob_1 <= iquant_eob_1;
        iquant_eob_2 <= iquant_eob_2;
        iquant_eob_3 <= iquant_eob_3;
        iquant_eob_4 <= iquant_eob_4;
        iquant_eob_5 <= iquant_eob_5;
      end

  /* ram select */

  always @(posedge clk)
    if (~rst) ram_write_select <= 1'd0;
    else if (clk_en && iquant_valid_5 && iquant_eob_5) ram_write_select <= ~ram_write_select;
    else ram_write_select <= ram_write_select;

  always @(posedge clk)
    if (~rst) ram_initialized <= 1'd0; // reset at powerup
    else if (clk_en && iquant_valid_5) ram_initialized <= ram_initialized || iquant_eob_5; // set once first block has been written
    else ram_initialized <= ram_initialized;

  /* write to ram */

  always @(posedge clk)
    if (~rst) ram_wr_addr <= 6'd0;
    else if (clk_en) ram_wr_addr <= iquant_addr_5;
    else ram_wr_addr <= ram_wr_addr;

  always @(posedge clk)
    if (~rst) ram_wr_data <= 12'd0;
    else if (clk_en) ram_wr_data <= iquant_level_5;
    else ram_wr_data <= ram_wr_data;

  always @(posedge clk)
    if (~rst) ram0_wr_enable <= 1'b0;
    else if (clk_en) ram0_wr_enable <= iquant_valid_5 && ram_write_select;
    else ram0_wr_enable <= ram0_wr_enable;

  always @(posedge clk)
    if (~rst) ram1_wr_enable <= 1'b0;
    else if (clk_en) ram1_wr_enable <= iquant_valid_5 && ~ram_write_select;
    else ram1_wr_enable <= ram1_wr_enable;

  /* read from ram */

  always @(posedge clk)
    if (~rst) ram0_rd_enable <= 1'b0;
    else if (clk_en && iquant_valid_5 && iquant_eob_5) ram0_rd_enable <= ram_write_select;
    else ram0_rd_enable <= ram0_rd_enable;

  always @(posedge clk)
    if (~rst) ram1_rd_enable <= 1'b0;
    else if (clk_en && iquant_valid_5 && iquant_eob_5) ram1_rd_enable <= ~ram_write_select;
    else ram1_rd_enable <= ram1_rd_enable;

  /* ram_rd_addr counts from 0 to 64; 64 being "idle". */
  always @(posedge clk)
    if (~rst) ram_rd_addr <= 7'd64;
    else if (clk_en && iquant_valid_5 && iquant_eob_5) ram_rd_addr <= 6'd0;
    else if (clk_en && ~ram_rd_addr[6] ) ram_rd_addr <= ram_rd_addr + 1'd1; // count to 64
    else ram_rd_addr <= ram_rd_addr;

  always @(posedge clk)
    if (~rst) iquant_level <= 12'd0;
    else if (clk_en && ram_initialized) iquant_level <= ram_write_select ? ram1_rd_data : ram0_rd_data;
    else iquant_level <= iquant_level;

  always @(posedge clk)
    if (~rst) iquant_valid_out_0 <= 1'd0;
    else if (clk_en) iquant_valid_out_0 <= ~ram_rd_addr[6] && ram_initialized;
    else iquant_valid_out_0 <= iquant_valid_out_0;

  always @(posedge clk)
    if (~rst) iquant_eob_out_0 <= 1'd0;
    else if (clk_en) iquant_eob_out_0 <= (ram_rd_addr == 6'd63);
    else iquant_eob_out_0 <= iquant_eob_out_0;
 
  always @(posedge clk)
    if (~rst) iquant_valid <= 1'd0;
    else if (clk_en) iquant_valid <= iquant_valid_out_0;
    else iquant_valid <= iquant_valid;

  always @(posedge clk)
    if (~rst) iquant_eob <= 1'd0;
    else if (clk_en) iquant_eob <= iquant_eob_out_0;
    else iquant_eob <= iquant_eob;
 
  /* 
   * The two rams for un-zigzagging the dct coefficients. 
   * One is being written while the other is being read.
   */

  dpram_sc
    #(.addr_width(6),                                         // number of bits in address bus
    .dta_width(12))                                           // number of bits in data bus
    ram0 (
    .rst(rst),                                                // reset, active low
    .clk(clk),                                                // clock, rising edge trigger
    .wr_en(ram0_wr_enable),                                   // write enable, active high
    .wr_addr(ram_wr_addr),                                    // write address
    .din(ram_wr_data),                                        // data input
    .rd_en(ram0_rd_enable),                                   // read enable, active high
    .rd_addr(ram_rd_addr[5:0]),                               // read address
    .dout(ram0_rd_data)                                       // data output
    );

  dpram_sc
    #(.addr_width(6),                                         // number of bits in address bus
    .dta_width(12))                                           // number of bits in data bus
    ram1 (
    .rst(rst),                                                // reset, active low
    .clk(clk),                                                // clock, rising edge trigger
    .wr_en(ram1_wr_enable),                                   // write enable, active high
    .wr_addr(ram_wr_addr),                                    // write address
    .din(ram_wr_data),                                        // data input
    .rd_en(ram1_rd_enable),                                   // read enable, active high
    .rd_addr(ram_rd_addr[5:0]),                               // read address
    .dout(ram1_rd_data)                                       // data output
    );

  /* Calculate quantiser scale, using Table 7-6, par. 7.4.2.2 */

  always @(posedge clk)
    if (~rst) quantiser_scale <= 7'd0;
    else if (clk_en) quantiser_scale <= q_scale_type ? non_linear_quantiser_scale(quantiser_scale_code) : {1'b0, quantiser_scale_code, 1'b0};
    else quantiser_scale <= quantiser_scale;

  /*
   * Table 7-6: Relation between quantiser_scale and quantiser_scale_code
   */

  function [6:0]non_linear_quantiser_scale;
    input [4:0]scale_code;
    begin
      casex(scale_code)
        5'd1:  non_linear_quantiser_scale = 7'd1;
        5'd2:  non_linear_quantiser_scale = 7'd2;
        5'd3:  non_linear_quantiser_scale = 7'd3;
        5'd4:  non_linear_quantiser_scale = 7'd4;
        5'd5:  non_linear_quantiser_scale = 7'd5;
        5'd6:  non_linear_quantiser_scale = 7'd6;
        5'd7:  non_linear_quantiser_scale = 7'd7;
        5'd8:  non_linear_quantiser_scale = 7'd8;
        5'd9:  non_linear_quantiser_scale = 7'd10;
        5'd10: non_linear_quantiser_scale = 7'd12;
        5'd11: non_linear_quantiser_scale = 7'd14;
        5'd12: non_linear_quantiser_scale = 7'd16;
        5'd13: non_linear_quantiser_scale = 7'd18;
        5'd14: non_linear_quantiser_scale = 7'd20;
        5'd15: non_linear_quantiser_scale = 7'd22;
        5'd16: non_linear_quantiser_scale = 7'd24;
        5'd17: non_linear_quantiser_scale = 7'd28;
        5'd18: non_linear_quantiser_scale = 7'd32;
        5'd19: non_linear_quantiser_scale = 7'd36;
        5'd20: non_linear_quantiser_scale = 7'd40;
        5'd21: non_linear_quantiser_scale = 7'd44;
        5'd22: non_linear_quantiser_scale = 7'd48;
        5'd23: non_linear_quantiser_scale = 7'd52;
        5'd24: non_linear_quantiser_scale = 7'd56;
        5'd25: non_linear_quantiser_scale = 7'd64;
        5'd26: non_linear_quantiser_scale = 7'd72;
        5'd27: non_linear_quantiser_scale = 7'd80;
        5'd28: non_linear_quantiser_scale = 7'd88;
        5'd29: non_linear_quantiser_scale = 7'd96;
        5'd30: non_linear_quantiser_scale = 7'd104;
        5'd31: non_linear_quantiser_scale = 7'd112;
        default non_linear_quantiser_scale = 7'd0; // Error
      endcase
    end
  endfunction


`ifdef CHECK
  always @(posedge clk)
    if (rst && clk_en && iquant_valid && (^iquant_level === 1'bx))
      begin 
        $display ("%m\t*** Error: iquant value undefined ***");
        $stop;
      end
`endif

`ifdef DEBUG
/* show input runlength/level values */
always @(posedge clk)
  if (clk_en && rld_rd_valid)
    begin
      if (dct_coeff_end)
        begin
	  $display ("%m\tDCT: end of block");
	end
      else
        begin
          $display ("%m\tDCT: %0d/%0d", dct_coeff_run, dct_coeff_signed_level);
	end
    end
`endif


`ifdef DEBUG_IQUANT
/* show output runlength/level values */

always @(posedge clk)
  if (clk_en && ((state == STATE_RUN) || (state == STATE_END_RUN) || (state == STATE_LEVEL)))
    begin
      $strobe ("%m\t\tlevel: %d", level);
    end

always @(posedge clk)
  if (clk_en)
    $strobe("%m\t\tcnt: %x run: %x rld_rd_en: %d", cnt, run, rld_rd_en);

always @(posedge clk)
  if (clk_en)
    begin
      $strobe("%m\t\tlevel:          %5d quant_rd_addr: %2d level_valid_0:  %d end_of_block: %d macroblock_intra:", level, quant_rd_addr, level_valid, end_of_block, macroblock_intra);
      $strobe("%m\t\tiquant_level_0: %5d iquant_addr_0: %2d iquant_valid_0: %d iquant_eob_0: %d iquant_intra_dc_0: %d quant_mat: %d quantiser_scale: %d ", iquant_level_0, iquant_addr_0, iquant_valid_0, iquant_eob_0, iquant_intra_dc_0, quant_mat , quantiser_scale);
      $strobe("%m\t\tiquant_level_1: %5d iquant_addr_1: %2d iquant_valid_1: %d iquant_eob_1: %d iquant_intra_dc_1: %d quant_mat: %d quantiser_scale: %d", iquant_level_1, iquant_addr_1, iquant_valid_1, iquant_eob_1, iquant_intra_dc_1,quant_mat , quantiser_scale);
      $strobe("%m\t\tiquant_level_2: %5d iquant_addr_2: %2d iquant_valid_2: %d iquant_eob_2: %d iquant_intra_dc_2: %d quant_mat: %d quantiser_scale: %d iquant_factor_2: %d", iquant_level_2, iquant_addr_2, iquant_valid_2, iquant_eob_2, iquant_intra_dc_2, quant_mat , quantiser_scale, iquant_factor_2);
      $strobe("%m\t\tiquant_level_3: %5d iquant_addr_3: %2d iquant_valid_3: %d iquant_eob_3: %d", iquant_level_3, iquant_addr_3, iquant_valid_3, iquant_eob_3);
      $strobe("%m\t\tiquant_level_4: %5d iquant_addr_4: %2d iquant_valid_4: %d iquant_eob_4: %d", iquant_level_4, iquant_addr_4, iquant_valid_4, iquant_eob_4);
      $strobe("%m\t\tiquant_level_5: %5d iquant_addr_5: %2d iquant_valid_5: %d iquant_eob_5: %d iquant_oddness: %d iquant_oddness_sum: %d", iquant_level_5, iquant_addr_5, iquant_valid_5, iquant_eob_5, iquant_oddness, iquant_oddness_sum);
      $strobe("%m\t\tiquant_level:   %5d ram_rd_addr:   %2d iquant_valid:   %d iquant_eob:   %d", iquant_level, ram_rd_addr, iquant_valid, iquant_eob);
    end

always @(posedge clk)
  if (clk_en)
    begin
      if (iquant_valid) $strobe("%m\t\tiquant_level", iquant_level);
    end

always @(posedge clk)
  if (clk_en)
    case (state)
      STATE_INIT:         #0 $display("%m\t\tSTATE_INIT");
      STATE_IDLE:         #0 $display("%m\t\tSTATE_IDLE");
      STATE_RUN:          #0 $display("%m\t\tSTATE_RUN");
      STATE_LEVEL:        #0 $display("%m\t\tSTATE_LEVEL");
      STATE_END_RUN:      #0 $display("%m\t\tSTATE_END_RUN");
      STATE_QUANT:        #0 $display("%m\t\tSTATE_QUANT");
      default             #0 $display("%m\t\t *** Unknown state %h *** ", state);
    endcase

`endif

endmodule

/*
 * rld_fifo - run/length decoder fifo.
 * input:  DCT coefficients, as run/signed level pairs. Quantizer updates. output: DCT coefficients, as run/signed level pairs. Quantizer updates.
 */

module rld_fifo(clk, clk_en, rst, 
  dct_coeff_wr_run, dct_coeff_wr_signed_level, dct_coeff_wr_end,                                                  // dct run/level values input
  alternate_scan_wr, macroblock_intra_wr, intra_dc_precision_wr, q_scale_type_wr, quantiser_scale_code_wr,        // aux variables input
  quant_wr_data_wr, quant_wr_addr_wr,                                                                             // quantizer input
  quant_rst_wr, quant_wr_intra_wr, quant_wr_non_intra_wr, quant_wr_chroma_intra_wr, quant_wr_chroma_non_intra_wr, // quantizer input
  rld_cmd_wr, rld_wr_en, rld_wr_almost_full, rld_wr_overflow,                                                     // command to run-length decoding
  dct_coeff_rd_run, dct_coeff_rd_signed_level, dct_coeff_rd_end,                                                  // dct run/level values output
  alternate_scan_rd, macroblock_intra_rd, intra_dc_precision_rd, q_scale_type_rd, quantiser_scale_code_rd,        // aux variables output
  quant_wr_data_rd, quant_wr_addr_rd,                                                                             // quantizer output
  quant_rst_rd, quant_wr_intra_rd, quant_wr_non_intra_rd, quant_wr_chroma_intra_rd, quant_wr_chroma_non_intra_rd, // quantizer output
  rld_cmd_rd, rld_rd_en, rld_rd_valid                                                                             // command to run-length decoding
  );

  input                    clk;                              // clock
  input                    clk_en;                           // clock enable
  input                    rst;                              // synchronous active low reset
  input               [5:0]dct_coeff_wr_run;
  input signed       [11:0]dct_coeff_wr_signed_level;
  input                    dct_coeff_wr_end;

  input                    alternate_scan_wr;                // from slice - choose zigzag scan order 0 or 1
  input                    macroblock_intra_wr;              // from slice - whether intra or non-intra macroblock
  input               [1:0]intra_dc_precision_wr;            // from ves
  input                    q_scale_type_wr;                  // from ves - whether linear or non-linear quantiser scale
  input               [4:0]quantiser_scale_code_wr;          // from slice - quantiser scale code, par. 7.4.2.2

  input               [7:0]quant_wr_data_wr;                 // data bus for quantizer matrix rams
  input               [5:0]quant_wr_addr_wr;                 // address bus for quantizer matrix rams
  input                    quant_rst_wr;                     // reset quantizer matrices to default values
  input                    quant_wr_intra_wr;                // write to intra quantizer matrix
  input                    quant_wr_non_intra_wr;            // write to non-intra quantizer matrix
  input                    quant_wr_chroma_intra_wr;         // write to intra chroma quantizer matrix
  input                    quant_wr_chroma_non_intra_wr;     // write to non-intra chroma quantizer matrix

  input               [1:0]rld_cmd_wr;
  input                    rld_wr_en;
  output                   rld_wr_almost_full;               // ask vld to wait for rld
  output                   rld_wr_overflow;

  output              [5:0]dct_coeff_rd_run;
  output signed      [11:0]dct_coeff_rd_signed_level;
  output                   dct_coeff_rd_end;

  output                   alternate_scan_rd;
  output                   macroblock_intra_rd;
  output              [1:0]intra_dc_precision_rd;
  output                   q_scale_type_rd;
  output              [4:0]quantiser_scale_code_rd;

  output              [7:0]quant_wr_data_rd;                 // data bus for quantizer matrix rams
  output              [5:0]quant_wr_addr_rd;                 // address bus for quantizer matrix rams
  output                   quant_rst_rd;                     // reset quantizer matrices to default values
  output                   quant_wr_intra_rd;                // write to intra quantizer matrix
  output                   quant_wr_non_intra_rd;            // write to non-intra quantizer matrix
  output                   quant_wr_chroma_intra_rd;         // write to intra chroma quantizer matrix
  output                   quant_wr_chroma_non_intra_rd;     // write to non-intra chroma quantizer matrix

  output               [1:0]rld_cmd_rd;
  input                    rld_rd_en;                        // read dct run/level values
  output                   rld_rd_valid;

`include "fifo_size.v" 
`include "vld_codes.v" 

 /* 
  * We write dct or iquant data to the fifo, depending upon rld_cmd. 
  * Note alternate_scan and rld_cmd are common to both, so we put them in the same position (bits 0..2) in both cases.
  */

  wire                     alternate_scan_rd_dummy;
  wire                [1:0]rld_cmd_rd_dummy;
  wire                [8:0]dummy_1 = 9'b0;
  wire                [8:0]dummy_2;
  
  wire               [30:0]dct_wr_dta = {dct_coeff_wr_run, dct_coeff_wr_signed_level, dct_coeff_wr_end, macroblock_intra_wr, intra_dc_precision_wr, q_scale_type_wr, quantiser_scale_code_wr, alternate_scan_wr, rld_cmd_wr};
  wire               [30:0]quant_wr_dta = {dummy_1, quant_wr_data_wr, quant_wr_addr_wr, quant_rst_wr, quant_wr_intra_wr, quant_wr_non_intra_wr, quant_wr_chroma_intra_wr, quant_wr_chroma_non_intra_wr, alternate_scan_wr, rld_cmd_wr};

  wire               [30:0]rld_rd_dta;
  assign                   {dct_coeff_rd_run, dct_coeff_rd_signed_level, dct_coeff_rd_end, macroblock_intra_rd, intra_dc_precision_rd, q_scale_type_rd, quantiser_scale_code_rd, alternate_scan_rd, rld_cmd_rd} = rld_rd_dta;
  assign                   {dummy_2, quant_wr_data_rd, quant_wr_addr_rd, quant_rst_rd, quant_wr_intra_rd, quant_wr_non_intra_rd, quant_wr_chroma_intra_rd, quant_wr_chroma_non_intra_rd, alternate_scan_rd_dummy, rld_cmd_rd_dummy} = rld_rd_dta;

  fifo_sc
    #(.addr_width(RLD_DEPTH),
    .dta_width(9'd31),
    .prog_thresh(RLD_THRESHOLD))
    rld_fifo (
    .rst(rst),
    .clk(clk),
    .din((rld_cmd_wr == RLD_DCT) ? dct_wr_dta : quant_wr_dta),
    .wr_en(rld_wr_en && clk_en),
    .full(),
    .wr_ack(),
    .overflow(rld_wr_overflow),
    .prog_full(rld_wr_almost_full),
    .dout(rld_rd_dta),
    .rd_en(rld_rd_en && clk_en),
    .empty(),
    .valid(rld_rd_valid),
    .underflow(),
    .prog_empty()
    );


`ifdef CHECK
  always @(posedge clk)
    if (rld_wr_overflow)
      begin
        #0 $display("%m\t*** error: rld_fifo overflow. **");
        $stop;
      end
`endif

`ifdef DEBUG
always @(posedge clk)
  if (clk_en)
    begin
      $strobe("%m\tclk_en: %d dct_coeff_wr_run: %d dct_coeff_wr_signed_level: %d dct_coeff_wr_end: %d alternate_scan_wr: %d macroblock_intra_wr: %d intra_dc_precision_wr: %d q_scale_type_wr: %d quantiser_scale_code_wr: %d rld_cmd_wr: %d rld_wr_en: %d",
      clk_en, dct_coeff_wr_run, dct_coeff_wr_signed_level, dct_coeff_wr_end, alternate_scan_wr, macroblock_intra_wr, intra_dc_precision_wr, q_scale_type_wr, quantiser_scale_code_wr, rld_cmd_wr, rld_wr_en);
      $strobe("%m\tclk_en: %d quant_wr_data_wr: %d quant_wr_addr_wr: %d quant_rst_wr: %d quant_wr_intra_wr: %d quant_wr_non_intra_wr: %d quant_wr_chroma_intra_wr: %d quant_wr_chroma_non_intra_wr: %d rld_cmd_wr: %d rld_wr_en: %d",
      clk_en, quant_wr_data_wr, quant_wr_addr_wr, quant_rst_wr, quant_wr_intra_wr, quant_wr_non_intra_wr, quant_wr_chroma_intra_wr, quant_wr_chroma_non_intra_wr, rld_cmd_wr, rld_wr_en);
    end

`endif
endmodule 
/* not truncated */
