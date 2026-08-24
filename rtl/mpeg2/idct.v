/* 
 * idct.v
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
 * Inverse Discrete Cosine Transform.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1
//`define DEBUG_IDCT_1D 1
//`define DEBUG_TRANSPOSE 1
`undef CHECK
`ifdef __IVERILOG__
`define CHECK 1
`endif

  /*
   * 2-dimensional inverse discrete cosine transform.
   *
   * Uses row/column decomposition method:
   * 1. do a one-dimensional idct om the rows
   * 2. swap rows and columns,
   * 3. do a one-dimensional idct om the columns
   * 4. swap rows and columns to go back to row order.
   *
   * Thought to meet or exceed the former IEEE 1180-1990 standard.
   * Can do streaming.
   * Uses 12 multipliers, all smaller than 18x18, and 2 dual-ported rams.
   *
   * The 8-point 1-dimensional inverse discrete cosine transform can be written as:
   *
   * | y0 |   1   |  a  b  a  c |   | x0 |   1   |  d  e  f  g |   | x1 |
   * | y1 | = - * |  a  c -a -b | * | x2 | + - * |  e -g -d -f | * | x3 |
   * | y2 |   2   |  a -c -a  b |   | x4 |   2   |  f -d  g  e |   | x5 |
   * | y3 |       |  a -b  a  c |   | x6 |       |  g -f  e -d |   | x7 |
   *
   * | y7 |   1   |  a  b  a  c |   | x0 |   1   |  d  e  f  g |   | x1 |
   * | y6 | = - * |  a  c -a -b | * | x2 | - - * |  e -g -d -f | * | x3 |
   * | y5 |   2   |  a -c -a  b |   | x4 |   2   |  f -d  g  e |   | x5 |
   * | y4 |       |  a -b  a  c |   | x6 |       |  g -f  e -d |   | x7 |
   *
   * where
   *   a = cos (pi/4)
   *   b = cos (pi/8)
   *   c = sin (pi/8)
   *   d = cos (pi/16)
   *   e = cos (3*pi/16)
   *   f = sin (3*pi/16)
   *   g = sin (pi/16)
   *
   * For fixed-point calculations, a..g are multiplied by sqrt(8) * 2**scale
   * where scale = 13 or 14, depending upon accuracy desired.
   * Multiplying by sqrt(8) causes a to be a power of two.
   * This way a*x0 and a*x4 can be calculated using shifts, saving two multipliers.
   *
   * Multipliers and adders are dimensioned according to:
   * "Systematic approach of Fixed Point 8x8 IDCT and DCT Design and Implementation",
   * Zhang, Wang, Yu.
   *
   * We choose:
   *   scheme = 4
   *   scale = 14
   *   row_shift = 10
   *   col_shift = 21
   *
   * Calculation of theoretical register sizes:
   *   sample = 8 (in mpeg2 video)
   *   input of idct_row:
   *     input_bits =  sample_bits + 4 = 8 + 4 = 12 (Form. 6)
   *   outout of idct_row:
   *     output_bits_row = scale - row_shift + sample_bits + 5 = 14 - 10 + 8 + 5 = 17 (Form. 11)
   *   size of internal registers during calculation of idct_row:
   *     max_inter_bits_row = scale + sample_bits + 5 = 13 + 8 + 5 = 26
   *   output of idct_col:
   *     output_bits_col = sample_bits  + 3 = 8 + 3 = 11 (Form. 12)
   *   size of internal registers during calculation of idct_col:
   *     max_inter_bits_col = col_shift + sample_bits  + 3 = 21 + 8 + 3 = 32 (Form. 13)
   *
   * We choose:
   *   register for idct_row: 32 bits
   *   output of idct_row: 22 bits
   *   registers for idct_col: 42 bits
   *   output of idct_col: 22 bits
   *
   */

module idct(clk, clk_en, rst,
            iquant_level, iquant_eob, iquant_valid,
            idct_data, idct_valid, idct_eob);

  input              clk;                       // clock
  input              clk_en;                    // clock enable
  input              rst;                       // synchronous active low reset
  input signed [11:0]iquant_level;              // inverse quantized dct coefficient
  input              iquant_eob;                // asserted at last inverse quantized dct coefficient of block
  input              iquant_valid;              // asserted when inverse quantized dct coefficient valid
  output signed [8:0]idct_data;                 // inverse quantized dct coefficient
  output             idct_eob;                  // asserted at last inverse quantized dct coefficient of block
  output             idct_valid;                // asserted when idct_data, idct_eob valid

  wire signed  [21:0]idct_row_data;
  wire               idct_row_valid;
  wire signed  [21:0]idct_col_data_in;
  wire               idct_col_valid_in;
  wire signed  [20:0]idct_col_data_out;
  wire               idct_col_valid_out;
  wire signed   [8:0]idct_col_clip_data_out;
  wire               idct_col_clip_valid_out;

  /* apply 1-d idct to rows */
  idct1d_row      #(.scale(14), .dta_in_width(12), .dta_shift(10), .reg_width(32))
                  idct_row(.clk(clk), .clk_en(clk_en), .rst(rst),
                  .dta_in(iquant_level), .dta_in_valid(iquant_valid),
                  .dta_out(idct_row_data), .dta_out_valid(idct_row_valid));

  /*
   * Result from idct_row is 22 bit wide.
   */

  /* swap rows and columns */
  transpose       #(.dta_width(22))
                  row2col(.clk(clk), .clk_en(clk_en), .rst(rst),
                  .dta_in(idct_row_data), .dta_in_valid(idct_row_valid),
                  .dta_out(idct_col_data_in), .dta_out_valid(idct_col_valid_in), .dta_out_eob());

  /* apply 1-d idct to columns */
  idct1d_col      #(.scale(14), .dta_in_width(22), .dta_shift(21), .reg_width(42))
                  idct_col(.clk(clk), .clk_en(clk_en), .rst(rst),
                  .dta_in(idct_col_data_in), .dta_in_valid(idct_col_valid_in),
                  .dta_out(idct_col_data_out), .dta_out_valid(idct_col_valid_out));

  /*
   * Result from idct_col is 22 bits,
   * Clip to 9 bits.
   */

  clip_col        clip_col(.clk(clk), .clk_en(clk_en), .rst(rst),
                  .dta_in(idct_col_data_out), .dta_in_valid(idct_col_valid_out),
                  .dta_out(idct_col_clip_data_out), .dta_out_valid(idct_col_clip_valid_out));

  /* swap back to rows */
  transpose       #(.dta_width(9))
                  col2row(.clk(clk), .clk_en(clk_en), .rst(rst),
                  .dta_in(idct_col_clip_data_out), .dta_in_valid(idct_col_clip_valid_out),
                  .dta_out(idct_data), .dta_out_valid(idct_valid), .dta_out_eob(idct_eob));

`ifdef DEBUG
always @(posedge clk)
  if (rst && clk_en && idct_valid && (idct_data === 9'bx))
    begin
      $display ("%m\t*** Error: idct value undefined ***");
      $stop;
    end

always @(posedge clk)
  if (clk_en && iquant_valid)
    begin
      if (iquant_eob)
        begin
          #0 $display("%m\t\tidct input: %d (eob)", iquant_level);
        end
      else
        begin
          #0 $display("%m\t\tidct input: %d", iquant_level);
        end
    end

always @(posedge clk)
  if (clk_en && idct_row_valid)
    begin
        #0 $display("%m\t\tafter idct_row: %d", idct_row_data);
    end

always @(posedge clk)
  if (clk_en && idct_col_valid_in)
    begin
        #0 $display("%m\t\tafter row2col: %d", idct_col_data_in);
    end

always @(posedge clk)
  if (clk_en && idct_col_valid_out)
    begin
        #0 $display("%m\t\tafter idct_col: %d", idct_col_data_out);
    end

always @(posedge clk)
  if (clk_en && idct_col_clip_valid_out)
    begin
        #0 $display("%m\t\tafter clipping: %d", idct_col_clip_data_out);
    end

always @(posedge clk)
  if (clk_en && idct_valid)
    begin
      #0 $display("%m\t\tafter col2row: %d", idct_data);
    end

`endif

endmodule

/*
 * 8-point 1-dimensional inverse discrete cosine transform. Row transform.
 */

module idct1d_row (clk, clk_en, rst, dta_in, dta_in_valid, dta_out, dta_out_valid);
  parameter                            dta_in_width=12,          // width of dta_in
                                       dta_shift=11,             // how much to shift result to the right
                                       reg_width=29,             // width of internal registers
                                       scale=13,                 // cosine values scaled by 2**scale
                                       dta_out_width=reg_width-dta_shift, // width of dta_out
                                       cosval_width=16,          // width of COSVAL_A .. COSVAL_G
                                       prod_width=dta_in_width+cosval_width;          // width of COSVAL_i * xi

  input                                clk;                      // clock
  input                                clk_en;                   // clock enable
  input                                rst;                      // synchronous active low reset
  input signed       [dta_in_width-1:0]dta_in;                   // data in
  input                                dta_in_valid;
  output reg signed [dta_out_width-1:0]dta_out;                  // data out - 18 bits wide
  output reg                           dta_out_valid;

  parameter [cosval_width-1:0]
    COSVAL_A      =  16'sd16384,  /*   SQRT(8)/2 * 2**14 * cos (pi/4) */
    COSVAL_MINUSA = -16'sd16384,  /* - SQRT(8)/2 * 2**14 * cos (pi/4) */
    COSVAL_B      =  16'sd21407,  /*   SQRT(8)/2 * 2**14 * cos (pi/8) */
    COSVAL_MINUSB = -16'sd21407,  /* - SQRT(8)/2 * 2**14 * cos (pi/8) */
    COSVAL_C      =  16'sd8867,   /*   SQRT(8)/2 * 2**14 * sin (pi/8) */
    COSVAL_MINUSC = -16'sd8867,   /* - SQRT(8)/2 * 2**14 * sin (pi/8) */
    COSVAL_D      =  16'sd22725,  /*   SQRT(8)/2 * 2**14 * cos (pi/16) */
    COSVAL_MINUSD = -16'sd22725,  /* - SQRT(8)/2 * 2**14 * cos (pi/16) */
    COSVAL_E      =  16'sd19266,  /*   SQRT(8)/2 * 2**14 * cos (3*pi/16) */
    COSVAL_MINUSE = -16'sd19266,  /* - SQRT(8)/2 * 2**14 * cos (3*pi/16) */
    COSVAL_F      =  16'sd12873,  /*   SQRT(8)/2 * 2**14 * sin (3*pi/16) */
    COSVAL_MINUSF = -16'sd12873,  /* - SQRT(8)/2 * 2**14 * sin (3*pi/16) */
    COSVAL_G      =  16'sd4520,   /*   SQRT(8)/2 * 2**14 * sin (pi/16) */
    COSVAL_MINUSG = -16'sd4520;   /* - SQRT(8)/2 * 2**14 * sin (pi/16) */

  /* dct coefficients input */
  reg signed [dta_in_width-1:0]q0;
  reg signed [dta_in_width-1:0]q1;
  reg signed [dta_in_width-1:0]q2;
  reg signed [dta_in_width-1:0]q3;
  reg signed [dta_in_width-1:0]q4;
  reg signed [dta_in_width-1:0]q5;
  reg signed [dta_in_width-1:0]q6;
  reg signed [dta_in_width-1:0]q7;

  reg signed [dta_in_width-1:0]x0;
  reg signed [dta_in_width-1:0]x1;
  reg signed [dta_in_width-1:0]x2;
  reg signed [dta_in_width-1:0]x3;
  reg signed [dta_in_width-1:0]x4;
  reg signed   [dta_in_width:0]minus_x4; // needs one bit more than x4, else two's complement of most negative x4 doesn't fit.
  reg signed [dta_in_width-1:0]x5;
  reg signed [dta_in_width-1:0]x6;
  reg signed [dta_in_width-1:0]x7;

  reg signed [cosval_width-1:0]cos1;
  reg signed [cosval_width-1:0]cos2;
  reg signed [cosval_width-1:0]cos3;
  reg signed [cosval_width-1:0]cos5;
  reg signed [cosval_width-1:0]cos6;
  reg signed [cosval_width-1:0]cos7;

  reg signed [prod_width-1:0]prod0; // product of xi * cosvali
  reg signed [prod_width-1:0]prod1;
  reg signed [prod_width-1:0]prod2;
  reg signed [prod_width-1:0]prod3;
  reg signed [prod_width-1:0]prod4;
  reg signed [prod_width-1:0]prod5;
  reg signed [prod_width-1:0]prod6;
  reg signed [prod_width-1:0]prod7;

  reg signed [reg_width-1:0]sum02; // sum of prodi and prodj
  reg signed [reg_width-1:0]sum46;
  reg signed [reg_width-1:0]sum13;
  reg signed [reg_width-1:0]sum57;
  reg signed [reg_width-1:0]sum0246; // sum of sumij and sumpq
  reg signed [reg_width-1:0]sum1357;

  reg signed [reg_width-1:0]y; // y sum or difference of sum0246 and sum0246

  reg [3:0]dta_in_cntr;

  reg dta_out_val_0;
  reg dta_out_val_1;
  reg dta_out_val_2;
  reg dta_out_val_3;

  reg add_0;
  reg add_1;
  reg add_2;

  // an offset which is added to x0 to round the results.
  parameter signed [reg_width-1:0] offset = {2'b01, {(dta_shift-1){1'b0}}};

  parameter [3:0]
    STATE_IDLE  = 4'd0,
    STATE_0     = 4'd1,
    STATE_1     = 4'd2,
    STATE_2     = 4'd3,
    STATE_3     = 4'd4,
    STATE_4     = 4'd5,
    STATE_5     = 4'd6,
    STATE_6     = 4'd7,
    STATE_7     = 4'd8;

  reg [3:0]state;
  reg [3:0]next;

  /*
   * IDCT data input
   */

  /* input shift register */
  always @(posedge clk)
    if (~rst)
      begin
        q0 <= 'sd0;
        q1 <= 'sd0;
        q2 <= 'sd0;
        q3 <= 'sd0;
        q4 <= 'sd0;
        q5 <= 'sd0;
        q6 <= 'sd0;
        q7 <= 'sd0;
      end
    else if (clk_en && dta_in_valid)
      begin
        q0 <= q1;
        q1 <= q2;
        q2 <= q3;
        q3 <= q4;
        q4 <= q5;
        q5 <= q6;
        q6 <= q7;
        q7 <= dta_in;
      end
    else
      begin
        q0 <= q0;
        q1 <= q1;
        q2 <= q2;
        q3 <= q3;
        q4 <= q4;
        q5 <= q5;
        q6 <= q6;
        q7 <= q7;
      end

  always @(posedge clk)
    if (~rst)
      begin
        x0 <= 'sd0;
        x1 <= 'sd0;
        x2 <= 'sd0;
        x3 <= 'sd0;
        x4 <= 'sd0;
        minus_x4 <= 'sd0;
        x5 <= 'sd0;
        x6 <= 'sd0;
        x7 <= 'sd0;
      end
    else if (clk_en && (dta_in_cntr == 4'd8))
      begin
        x0 <= q0;
        x1 <= q1;
        x2 <= q2;
        x3 <= q3;
        x4 <= q4;
        minus_x4 <= ~{q4[dta_in_width-1], q4}+1'b1;
        x5 <= q5;
        x6 <= q6;
        x7 <= q7;
      end
    else
      begin
        x0 <= x0;
        x1 <= x1;
        x2 <= x2;
        x3 <= x3;
        x4 <= x4;
        minus_x4 <= minus_x4;
        x5 <= x5;
        x6 <= x6;
        x7 <= x7;
      end

  /* input counter */
  always @(posedge clk)
    if (~rst) dta_in_cntr <= 4'b0;
    else if (clk_en && (dta_in_cntr == 4'd8) && dta_in_valid) dta_in_cntr <= 3'd1;
    else if (clk_en && (dta_in_cntr == 4'd8)) dta_in_cntr <= 3'd0;
    else if (clk_en && dta_in_valid) dta_in_cntr <= dta_in_cntr + 3'd1;
    else dta_in_cntr <= dta_in_cntr;

  /*
   * IDCT calculation
   */

  /* next state logic */
  always @*
    case (state)
      STATE_IDLE:   if (dta_in_cntr == 4'd8) next = STATE_0;
                    else next = STATE_IDLE;
      STATE_0:      next = STATE_1;
      STATE_1:      next = STATE_2;
      STATE_2:      next = STATE_3;
      STATE_3:      next = STATE_4;
      STATE_4:      next = STATE_5;
      STATE_5:      next = STATE_6;
      STATE_6:      next = STATE_7;
      STATE_7:      if (dta_in_cntr == 4'd8) next = STATE_0;
                    else next = STATE_IDLE;
      default       next = STATE_IDLE;
    endcase

  /* state */
  always @(posedge clk)
    if(~rst) state <= STATE_IDLE;
    else if (clk_en) state <= next;
    else  state <= state;

  always @(posedge clk)
    if (~rst)
      cos2 <= COSVAL_B;
    else if (clk_en)
      case (state)
        STATE_0:       cos2 <= COSVAL_C;
        STATE_1:       cos2 <= COSVAL_MINUSC;
        STATE_2:       cos2 <= COSVAL_MINUSB;
        STATE_3:       cos2 <= COSVAL_MINUSB;
        STATE_4:       cos2 <= COSVAL_MINUSC;
        STATE_5:       cos2 <= COSVAL_C;
        STATE_6:       cos2 <= COSVAL_B;
        STATE_7:       cos2 <= COSVAL_B;
        default        cos2 <= COSVAL_B;
      endcase
    else
      cos2 <= cos2;

  always @(posedge clk)
    if (~rst)
      cos6 <= COSVAL_C;
    else if (clk_en)
      case (state)
        STATE_0:       cos6 <= COSVAL_MINUSB;
        STATE_1:       cos6 <= COSVAL_B;
        STATE_2:       cos6 <= COSVAL_MINUSC;
        STATE_3:       cos6 <= COSVAL_MINUSC;
        STATE_4:       cos6 <= COSVAL_B;
        STATE_5:       cos6 <= COSVAL_MINUSB;
        STATE_6:       cos6 <= COSVAL_C;
        STATE_7:       cos6 <= COSVAL_C;
        default        cos6 <= COSVAL_C;
      endcase
    else
      cos6 <= cos6;

  always @(posedge clk)
    if (~rst)
      cos1 <= COSVAL_D;
    else if (clk_en)
      case (state)
        STATE_0:       cos1 <= COSVAL_E;
        STATE_1:       cos1 <= COSVAL_F;
        STATE_2:       cos1 <= COSVAL_G;
        STATE_3:       cos1 <= COSVAL_G;
        STATE_4:       cos1 <= COSVAL_F;
        STATE_5:       cos1 <= COSVAL_E;
        STATE_6:       cos1 <= COSVAL_D;
        STATE_7:       cos1 <= COSVAL_D;
        default        cos1 <= COSVAL_D;
      endcase
    else
      cos1 <= cos1;

  always @(posedge clk)
    if (~rst)
      cos3 <= COSVAL_E;
    else if (clk_en)
      case (state)
        STATE_0:       cos3 <= COSVAL_MINUSG;
        STATE_1:       cos3 <= COSVAL_MINUSD;
        STATE_2:       cos3 <= COSVAL_MINUSF;
        STATE_3:       cos3 <= COSVAL_MINUSF;
        STATE_4:       cos3 <= COSVAL_MINUSD;
        STATE_5:       cos3 <= COSVAL_MINUSG;
        STATE_6:       cos3 <= COSVAL_E;
        STATE_7:       cos3 <= COSVAL_E;
        default        cos3 <= COSVAL_E;
      endcase
    else
      cos3 <= cos3;

  always @(posedge clk)
    if (~rst)
      cos5 <= COSVAL_F;
    else if (clk_en)
      case (state)
        STATE_0:       cos5 <= COSVAL_MINUSD;
        STATE_1:       cos5 <= COSVAL_G;
        STATE_2:       cos5 <= COSVAL_E;
        STATE_3:       cos5 <= COSVAL_E;
        STATE_4:       cos5 <= COSVAL_G;
        STATE_5:       cos5 <= COSVAL_MINUSD;
        STATE_6:       cos5 <= COSVAL_F;
        STATE_7:       cos5 <= COSVAL_F;
        default        cos5 <= COSVAL_F;
      endcase
    else
      cos5 <= cos5;

  always @(posedge clk)
    if (~rst)
      cos7 <= COSVAL_G;
    else if (clk_en)
      case (state)
        STATE_0:       cos7 <= COSVAL_MINUSF;
        STATE_1:       cos7 <= COSVAL_E;
        STATE_2:       cos7 <= COSVAL_MINUSD;
        STATE_3:       cos7 <= COSVAL_MINUSD;
        STATE_4:       cos7 <= COSVAL_E;
        STATE_5:       cos7 <= COSVAL_MINUSF;
        STATE_6:       cos7 <= COSVAL_G;
        STATE_7:       cos7 <= COSVAL_G;
        default        cos7 <= COSVAL_G;
      endcase
    else
      cos7 <= cos7;

  always @(posedge clk)
    if (~rst)
      begin
        prod0 <= 'sd0;
        prod1 <= 'sd0;
        prod2 <= 'sd0;
        prod3 <= 'sd0;
        prod4 <= 'sd0;
        prod5 <= 'sd0;
        prod6 <= 'sd0;
        prod7 <= 'sd0;
        sum02 <= 'sd0;
        sum46 <= 'sd0;
        sum13 <= 'sd0;
        sum57 <= 'sd0;
        sum0246 <= 'sd0;
        sum1357 <= 'sd0;
      end
    else if (clk_en)
      begin
        /*
         * Next line implements
         * prod0 <= (cos0 * x0) + offset; // = cos0 * x0 + offset;
         * using shifts; offset added for proper rounding.
         */

        prod0 <= {{(reg_width - dta_in_width){x0[dta_in_width-1]}}, x0, {scale{1'b0}}} + offset; // = cos0 * x0 + offset; offset added for proper rounding. Avoids a multipier.

        /*
         * These ought to map to a hardware multiplier in the fpga.
         */
        prod1 <= cos1 * x1;
        prod2 <= cos2 * x2;
        prod3 <= cos3 * x3;

        /*
         * case implements
         *  prod4 <= cos4 * x4;
         * using shifts, saving a multiplier.
         */

        case (state)
          STATE_0,
          STATE_3,
          STATE_4,
          STATE_7: prod4 <=  {{(reg_width - dta_in_width){x4[dta_in_width-1]}}, x4, {scale{1'b0}}};
          STATE_1,
          STATE_2,
          STATE_5,
          STATE_6: prod4 <=  {{(reg_width - dta_in_width-1){minus_x4[dta_in_width]}}, minus_x4, {scale{1'b0}}};
          default  prod4 <=  {{(reg_width - dta_in_width){x4[dta_in_width-1]}}, x4, {scale{1'b0}}};
        endcase

        prod5 <= cos5 * x5;
        prod6 <= cos6 * x6;
        prod7 <= cos7 * x7;
        sum02 <= {{(reg_width-prod_width){prod0[prod_width-1]}}, prod0} + {{(reg_width-prod_width){prod2[prod_width-1]}}, prod2};
        sum46 <= {{(reg_width-prod_width){prod4[prod_width-1]}}, prod4} + {{(reg_width-prod_width){prod6[prod_width-1]}}, prod6};
        sum13 <= {{(reg_width-prod_width){prod1[prod_width-1]}}, prod1} + {{(reg_width-prod_width){prod3[prod_width-1]}}, prod3};
        sum57 <= {{(reg_width-prod_width){prod5[prod_width-1]}}, prod5} + {{(reg_width-prod_width){prod7[prod_width-1]}}, prod7};
        sum0246 <= sum02 + sum46;
        sum1357 <= sum13 + sum57;
      end
    else
      begin
        prod0 <= prod0;
        prod1 <= prod1;
        prod2 <= prod2;
        prod3 <= prod3;
        prod4 <= prod4;
        prod5 <= prod5;
        prod6 <= prod6;
        prod7 <= prod7;
        sum02 <= sum02;
        sum46 <= sum46;
        sum13 <= sum13;
        sum57 <= sum57;
        sum0246 <= sum0246;
        sum1357 <= sum1357;
      end

  always @(posedge clk)
    if (~rst)
      begin
        dta_out_val_0 <= 1'b0;
        dta_out_val_1 <= 1'b0;
        dta_out_val_2 <= 1'b0;
        dta_out_val_3 <= 1'b0;
        dta_out_valid <= 1'b0;
      end
    else if (clk_en)
      begin
        dta_out_val_0 <= (state != STATE_IDLE);
        dta_out_val_1 <= dta_out_val_0;
        dta_out_val_2 <= dta_out_val_1;
        dta_out_val_3 <= dta_out_val_2;
        dta_out_valid <= dta_out_val_3;
      end
    else
      begin
        dta_out_val_0 <= dta_out_val_0;
        dta_out_val_1 <= dta_out_val_1;
        dta_out_val_2 <= dta_out_val_2;
        dta_out_val_3 <= dta_out_val_3;
        dta_out_valid <= dta_out_valid;
      end


  /*
   * Looking at the equation for the 1d idct, the final step when calculating
   * y0..y3 is addition, when calculating y4..y7 subtraction.
   * register add_0 is 1 when one needs to add, 0 when one needs to subtract.
   */

  always @(posedge clk)
    if (~rst)
      add_0 <= 1'd0;
    else if (clk_en)
      case (state)
        STATE_0,
        STATE_1,
        STATE_2,
        STATE_3:       add_0 <= 1'b1;
        STATE_4,
        STATE_6,
        STATE_5,
        STATE_7:       add_0 <= 1'b0;
        default        add_0 <= 1'b0;
      endcase
    else
      add_0 <= add_0;

  always @(posedge clk)
    if (~rst)
      begin
        add_1 <= 1'b0;
        add_2 <= 1'b0;
      end
    else if (clk_en)
      begin
        add_1 <= add_0;
        add_2 <= add_1;
      end
    else
      begin
      add_1 <= add_1;
      add_2 <= add_2;
      end

  always @(posedge clk)
    if (~rst)
      y <= 'sd0;
    else if (clk_en && add_2)
      y <= sum0246 + sum1357;
    else if (clk_en)
      y <= sum0246 - sum1357;
    else
      y <= y;

  always @(posedge clk)
    if (~rst) dta_out <= 'sd0;
    else if (clk_en) dta_out <=  y >>> dta_shift;
    else dta_out <= dta_out;

`ifdef DEBUG_IDCT_1D
  always @(posedge clk)
    begin
      $strobe("%m\toffset: %d", offset);
      $strobe("%m\tcos0: -------- cos1: %8d cos2: %8d cos3: %8d cos4: -------- cos5: %8d cos6: %8d cos7: %8d", cos1, cos2, cos3, cos5, cos6, cos7);
      $strobe("%m\t  x0: %8d   x1: %8d   x2: %8d   x3: %8d   x4: %8d   x5: %8d   x6: %8d   x7: %8d",   x0,   x1,   x2,   x3,   x4,   x5,   x6,   x7);
      $strobe("%m\tprod0: %d prod1: %d prod2: %d prod3: %d prod4: %d prod5: %d prod6: %d prod7: %d", prod0, prod1, prod2, prod3, prod4, prod5, prod6, prod7);
      $strobe("%m\tsum02: %8d sum46: %8d sum13: %8d sum57: %8d", sum02, sum46, sum13, sum57);
      $strobe("%m\tsum0246: %8d sum1357: %8d", sum0246, sum1357);
      $strobe("%m\ty: %8d", y);
      $strobe("%m\tdta_out: %8d", dta_out);
    end
`endif

endmodule

/*
 * 8-point 1-dimensional inverse discrete cosine transform. Column transform.
 *
 * Mathematically identical to the row transform. 
 * However, the 22x16 multipliers have not been implemented as two 18x18 multipliers, 
 * but as an 18x18 multiplier with a few shifters and adders added.
 * This saves six multipliers. Clock speed improves, too.
 */

module idct1d_col (clk, clk_en, rst, dta_in, dta_in_valid, dta_out, dta_out_valid);
  parameter                            dta_in_width=12,          // width of dta_in
                                       dta_shift=11,             // how much to shift result to the right
                                       reg_width=29,             // width of internal registers
                                       scale=13,                 // cosine values scaled by 2**scale
                                       dta_out_width=reg_width-dta_shift, // width of dta_out
                                       cosval_width=16,          // width of COSVAL_A .. COSVAL_G
                                       prod_width=dta_in_width+cosval_width;          // width of COSVAL_i * xi

  input                                clk;                      // clock
  input                                clk_en;                   // clock enable
  input                                rst;                      // synchronous active low reset
  input signed       [dta_in_width-1:0]dta_in;                   // data in
  input                                dta_in_valid;
  output reg signed [dta_out_width-1:0]dta_out;                  // data out - 18 bits wide
  output reg                           dta_out_valid;

  parameter [cosval_width-1:0]
    COSVAL_A      =  16'sd16384,  /*   SQRT(8)/2 * 2**14 * cos (pi/4) */
    COSVAL_MINUSA = -16'sd16384,  /* - SQRT(8)/2 * 2**14 * cos (pi/4) */
    COSVAL_B      =  16'sd21407,  /*   SQRT(8)/2 * 2**14 * cos (pi/8) */
    COSVAL_MINUSB = -16'sd21407,  /* - SQRT(8)/2 * 2**14 * cos (pi/8) */
    COSVAL_C      =  16'sd8867,   /*   SQRT(8)/2 * 2**14 * sin (pi/8) */
    COSVAL_MINUSC = -16'sd8867,   /* - SQRT(8)/2 * 2**14 * sin (pi/8) */
    COSVAL_D      =  16'sd22725,  /*   SQRT(8)/2 * 2**14 * cos (pi/16) */
    COSVAL_MINUSD = -16'sd22725,  /* - SQRT(8)/2 * 2**14 * cos (pi/16) */
    COSVAL_E      =  16'sd19266,  /*   SQRT(8)/2 * 2**14 * cos (3*pi/16) */
    COSVAL_MINUSE = -16'sd19266,  /* - SQRT(8)/2 * 2**14 * cos (3*pi/16) */
    COSVAL_F      =  16'sd12873,  /*   SQRT(8)/2 * 2**14 * sin (3*pi/16) */
    COSVAL_MINUSF = -16'sd12873,  /* - SQRT(8)/2 * 2**14 * sin (3*pi/16) */
    COSVAL_G      =  16'sd4520,   /*   SQRT(8)/2 * 2**14 * sin (pi/16) */
    COSVAL_MINUSG = -16'sd4520;   /* - SQRT(8)/2 * 2**14 * sin (pi/16) */

  /* dct coefficients input */
  reg signed [dta_in_width-1:0]q0;
  reg signed [dta_in_width-1:0]q1;
  reg signed [dta_in_width-1:0]q2;
  reg signed [dta_in_width-1:0]q3;
  reg signed [dta_in_width-1:0]q4;
  reg signed [dta_in_width-1:0]q5;
  reg signed [dta_in_width-1:0]q6;
  reg signed [dta_in_width-1:0]q7;

  reg signed [dta_in_width-1:0]x0;
  reg signed [dta_in_width-1:0]x1;
  reg signed [dta_in_width-1:0]x2;
  reg signed [dta_in_width-1:0]x3;
  reg signed [dta_in_width-1:0]x4;
  reg signed   [dta_in_width:0]minus_x4; // needs one bit more than x4, else two's complement of most negative x4 doesn't fit.
  reg signed [dta_in_width-1:0]x5;
  reg signed [dta_in_width-1:0]x6;
  reg signed [dta_in_width-1:0]x7;

  reg signed [cosval_width-1:0]cos1;
  reg signed [cosval_width-1:0]cos2;
  reg signed [cosval_width-1:0]cos3;
  reg signed [cosval_width-1:0]cos5;
  reg signed [cosval_width-1:0]cos6;
  reg signed [cosval_width-1:0]cos7;

  reg  signed [prod_width-1:0]prod0; // product of xi * cosvali
  reg  signed [prod_width-1:0]prod0_delayed;
  wire signed [prod_width-1:0]prod1;
  wire signed [prod_width-1:0]prod2;
  wire signed [prod_width-1:0]prod3;
  reg  signed [prod_width-1:0]prod4;
  reg  signed [prod_width-1:0]prod4_delayed;
  wire signed [prod_width-1:0]prod5;
  wire signed [prod_width-1:0]prod6;
  wire signed [prod_width-1:0]prod7;

  reg signed [reg_width-1:0]sum02; // sum of prodi and prodj
  reg signed [reg_width-1:0]sum46;
  reg signed [reg_width-1:0]sum13;
  reg signed [reg_width-1:0]sum57;
  reg signed [reg_width-1:0]sum0246; // sum of sumij and sumpq
  reg signed [reg_width-1:0]sum1357;

  reg signed [reg_width-1:0]y; // y sum or difference of sum0246 and sum0246

  reg [3:0]dta_in_cntr;

  reg dta_out_val_0;
  reg dta_out_val_1;
  reg dta_out_val_2;
  reg dta_out_val_3;
  reg dta_out_val_4;

  reg add_0;
  reg add_1;
  reg add_2;
  reg add_3;

  // an offset which is added to x0 to round the results.
  parameter signed [reg_width-1:0] offset = {2'b01, {(dta_shift-1){1'b0}}};

  parameter [3:0]
    STATE_IDLE  = 4'd0,
    STATE_0     = 4'd1,
    STATE_1     = 4'd2,
    STATE_2     = 4'd3,
    STATE_3     = 4'd4,
    STATE_4     = 4'd5,
    STATE_5     = 4'd6,
    STATE_6     = 4'd7,
    STATE_7     = 4'd8;

  reg [3:0]state;
  reg [3:0]next;

  /*
   * IDCT data input
   */

  /* input shift register */
  always @(posedge clk)
    if (~rst)
      begin
        q0 <= 'sd0;
        q1 <= 'sd0;
        q2 <= 'sd0;
        q3 <= 'sd0;
        q4 <= 'sd0;
        q5 <= 'sd0;
        q6 <= 'sd0;
        q7 <= 'sd0;
      end
    else if (clk_en && dta_in_valid)
      begin
        q0 <= q1;
        q1 <= q2;
        q2 <= q3;
        q3 <= q4;
        q4 <= q5;
        q5 <= q6;
        q6 <= q7;
        q7 <= dta_in;
      end
    else
      begin
        q0 <= q0;
        q1 <= q1;
        q2 <= q2;
        q3 <= q3;
        q4 <= q4;
        q5 <= q5;
        q6 <= q6;
        q7 <= q7;
      end

  always @(posedge clk)
    if (~rst)
      begin
        x0 <= 'sd0;
        x1 <= 'sd0;
        x2 <= 'sd0;
        x3 <= 'sd0;
        x4 <= 'sd0;
        minus_x4 <= 'sd0;
        x5 <= 'sd0;
        x6 <= 'sd0;
        x7 <= 'sd0;
      end
    else if (clk_en && (dta_in_cntr == 4'd8))
      begin
        x0 <= q0;
        x1 <= q1;
        x2 <= q2;
        x3 <= q3;
        x4 <= q4;
        minus_x4 <= ~{q4[dta_in_width-1], q4}+1'b1;
        x5 <= q5;
        x6 <= q6;
        x7 <= q7;
      end
    else
      begin
        x0 <= x0;
        x1 <= x1;
        x2 <= x2;
        x3 <= x3;
        x4 <= x4;
        minus_x4 <= minus_x4;
        x5 <= x5;
        x6 <= x6;
        x7 <= x7;
      end

  /* input counter */
  always @(posedge clk)
    if (~rst) dta_in_cntr <= 4'b0;
    else if (clk_en && (dta_in_cntr == 4'd8) && dta_in_valid) dta_in_cntr <= 3'd1;
    else if (clk_en && (dta_in_cntr == 4'd8)) dta_in_cntr <= 3'd0;
    else if (clk_en && dta_in_valid) dta_in_cntr <= dta_in_cntr + 3'd1;
    else dta_in_cntr <= dta_in_cntr;

  /*
   * IDCT calculation
   */

  /* next state logic */
  always @*
    case (state)
      STATE_IDLE:   if (dta_in_cntr == 4'd8) next = STATE_0;
                    else next = STATE_IDLE;
      STATE_0:      next = STATE_1;
      STATE_1:      next = STATE_2;
      STATE_2:      next = STATE_3;
      STATE_3:      next = STATE_4;
      STATE_4:      next = STATE_5;
      STATE_5:      next = STATE_6;
      STATE_6:      next = STATE_7;
      STATE_7:      if (dta_in_cntr == 4'd8) next = STATE_0;
                    else next = STATE_IDLE;
      default       next = STATE_IDLE;
    endcase

  /* state */
  always @(posedge clk)
    if(~rst) state <= STATE_IDLE;
    else if (clk_en) state <= next;
    else  state <= state;

  always @(posedge clk)
    if (~rst)
      cos2 <= COSVAL_B;
    else if (clk_en)
      case (state)
        STATE_0:       cos2 <= COSVAL_C;
        STATE_1:       cos2 <= COSVAL_MINUSC;
        STATE_2:       cos2 <= COSVAL_MINUSB;
        STATE_3:       cos2 <= COSVAL_MINUSB;
        STATE_4:       cos2 <= COSVAL_MINUSC;
        STATE_5:       cos2 <= COSVAL_C;
        STATE_6:       cos2 <= COSVAL_B;
        STATE_7:       cos2 <= COSVAL_B;
        default        cos2 <= COSVAL_B;
      endcase
    else
      cos2 <= cos2;

  always @(posedge clk)
    if (~rst)
      cos6 <= COSVAL_C;
    else if (clk_en)
      case (state)
        STATE_0:       cos6 <= COSVAL_MINUSB;
        STATE_1:       cos6 <= COSVAL_B;
        STATE_2:       cos6 <= COSVAL_MINUSC;
        STATE_3:       cos6 <= COSVAL_MINUSC;
        STATE_4:       cos6 <= COSVAL_B;
        STATE_5:       cos6 <= COSVAL_MINUSB;
        STATE_6:       cos6 <= COSVAL_C;
        STATE_7:       cos6 <= COSVAL_C;
        default        cos6 <= COSVAL_C;
      endcase
    else
      cos6 <= cos6;

  always @(posedge clk)
    if (~rst)
      cos1 <= COSVAL_D;
    else if (clk_en)
      case (state)
        STATE_0:       cos1 <= COSVAL_E;
        STATE_1:       cos1 <= COSVAL_F;
        STATE_2:       cos1 <= COSVAL_G;
        STATE_3:       cos1 <= COSVAL_G;
        STATE_4:       cos1 <= COSVAL_F;
        STATE_5:       cos1 <= COSVAL_E;
        STATE_6:       cos1 <= COSVAL_D;
        STATE_7:       cos1 <= COSVAL_D;
        default        cos1 <= COSVAL_D;
      endcase
    else
      cos1 <= cos1;

  always @(posedge clk)
    if (~rst)
      cos3 <= COSVAL_E;
    else if (clk_en)
      case (state)
        STATE_0:       cos3 <= COSVAL_MINUSG;
        STATE_1:       cos3 <= COSVAL_MINUSD;
        STATE_2:       cos3 <= COSVAL_MINUSF;
        STATE_3:       cos3 <= COSVAL_MINUSF;
        STATE_4:       cos3 <= COSVAL_MINUSD;
        STATE_5:       cos3 <= COSVAL_MINUSG;
        STATE_6:       cos3 <= COSVAL_E;
        STATE_7:       cos3 <= COSVAL_E;
        default        cos3 <= COSVAL_E;
      endcase
    else
      cos3 <= cos3;

  always @(posedge clk)
    if (~rst)
      cos5 <= COSVAL_F;
    else if (clk_en)
      case (state)
        STATE_0:       cos5 <= COSVAL_MINUSD;
        STATE_1:       cos5 <= COSVAL_G;
        STATE_2:       cos5 <= COSVAL_E;
        STATE_3:       cos5 <= COSVAL_E;
        STATE_4:       cos5 <= COSVAL_G;
        STATE_5:       cos5 <= COSVAL_MINUSD;
        STATE_6:       cos5 <= COSVAL_F;
        STATE_7:       cos5 <= COSVAL_F;
        default        cos5 <= COSVAL_F;
      endcase
    else
      cos5 <= cos5;

  always @(posedge clk)
    if (~rst)
      cos7 <= COSVAL_G;
    else if (clk_en)
      case (state)
        STATE_0:       cos7 <= COSVAL_MINUSF;
        STATE_1:       cos7 <= COSVAL_E;
        STATE_2:       cos7 <= COSVAL_MINUSD;
        STATE_3:       cos7 <= COSVAL_MINUSD;
        STATE_4:       cos7 <= COSVAL_E;
        STATE_5:       cos7 <= COSVAL_MINUSF;
        STATE_6:       cos7 <= COSVAL_G;
        STATE_7:       cos7 <= COSVAL_G;
        default        cos7 <= COSVAL_G;
      endcase
    else
      cos7 <= cos7;

  /* The 22x18 multipliers */

  always @(posedge clk)                                         /* prod0 <= cos0 * x0 + offset; offset added for proper rounding. Uses shifts, avoids a multipier. */
    if (~rst) prod0_delayed <= 'sd0;
    else if (clk_en)
        prod0_delayed <= {{(reg_width - dta_in_width){x0[dta_in_width-1]}}, x0, {scale{1'b0}}} + offset; 
    else prod0_delayed <= prod0_delayed;

  always @(posedge clk)
    if (~rst) prod0 <= 'sd0;
    else if (clk_en) prod0 <= prod0_delayed;
    else prod0 <= prod0;

  mult22x16 mult_prod1(clk, clk_en, rst, prod1, cos1, x1);      /* prod1 <= cos1 * x1; */
  mult22x16 mult_prod2(clk, clk_en, rst, prod2, cos2, x2);      /* prod2 <= cos2 * x2; */
  mult22x16 mult_prod3(clk, clk_en, rst, prod3, cos3, x3);      /* prod3 <= cos3 * x3; */

  always @(posedge clk)                                         /* prod4 <= cos4 * x4. Uses shifts, avoids a multipier. */
    if (~rst) prod4_delayed <= 'sd0;
    else if (clk_en)
        case (state)
          STATE_0,
          STATE_3,
          STATE_4,
          STATE_7: prod4_delayed <=  {{(reg_width - dta_in_width){x4[dta_in_width-1]}}, x4, {scale{1'b0}}};
          STATE_1,
          STATE_2,
          STATE_5,
          STATE_6: prod4_delayed <=  {{(reg_width - dta_in_width-1){minus_x4[dta_in_width]}}, minus_x4, {scale{1'b0}}};
          default  prod4_delayed <=  {{(reg_width - dta_in_width){x4[dta_in_width-1]}}, x4, {scale{1'b0}}};
        endcase
    else prod4_delayed <= prod4_delayed;

  always @(posedge clk)
    if (~rst) prod4 <= 'sd0;
    else if (clk_en) prod4 <= prod4_delayed;
    else prod4 <= prod4;

  mult22x16 mult_prod5(clk, clk_en, rst, prod5, cos5, x5);      /* prod5 <= cos5 * x5; */
  mult22x16 mult_prod6(clk, clk_en, rst, prod6, cos6, x6);      /* prod6 <= cos6 * x6; */
  mult22x16 mult_prod7(clk, clk_en, rst, prod7, cos7, x7);      /* prod7 <= cos7 * x7; */
  
  always @(posedge clk)
    if (~rst)
      begin
        sum02 <= 'sd0;
        sum46 <= 'sd0;
        sum13 <= 'sd0;
        sum57 <= 'sd0;
        sum0246 <= 'sd0;
        sum1357 <= 'sd0;
      end
    else if (clk_en)
      begin
        sum02 <= {{(reg_width-prod_width){prod0[prod_width-1]}}, prod0} + {{(reg_width-prod_width){prod2[prod_width-1]}}, prod2};
        sum46 <= {{(reg_width-prod_width){prod4[prod_width-1]}}, prod4} + {{(reg_width-prod_width){prod6[prod_width-1]}}, prod6};
        sum13 <= {{(reg_width-prod_width){prod1[prod_width-1]}}, prod1} + {{(reg_width-prod_width){prod3[prod_width-1]}}, prod3};
        sum57 <= {{(reg_width-prod_width){prod5[prod_width-1]}}, prod5} + {{(reg_width-prod_width){prod7[prod_width-1]}}, prod7};
        sum0246 <= sum02 + sum46;
        sum1357 <= sum13 + sum57;
      end
    else
      begin
        sum02 <= sum02;
        sum46 <= sum46;
        sum13 <= sum13;
        sum57 <= sum57;
        sum0246 <= sum0246;
        sum1357 <= sum1357;
      end

  always @(posedge clk)
    if (~rst)
      begin
        dta_out_val_0 <= 1'b0;
        dta_out_val_1 <= 1'b0;
        dta_out_val_2 <= 1'b0;
        dta_out_val_3 <= 1'b0;
        dta_out_val_4 <= 1'b0;
        dta_out_valid <= 1'b0;
      end
    else if (clk_en)
      begin
        dta_out_val_0 <= (state != STATE_IDLE);
        dta_out_val_1 <= dta_out_val_0;
        dta_out_val_2 <= dta_out_val_1;
        dta_out_val_3 <= dta_out_val_2;
        dta_out_val_4 <= dta_out_val_3;
        dta_out_valid <= dta_out_val_4;
      end
    else
      begin
        dta_out_val_0 <= dta_out_val_0;
        dta_out_val_1 <= dta_out_val_1;
        dta_out_val_2 <= dta_out_val_2;
        dta_out_val_3 <= dta_out_val_3;
        dta_out_val_4 <= dta_out_val_4;
        dta_out_valid <= dta_out_valid;
      end

  /*
   * Looking at the equation for the 1d idct, the final step when calculating
   * y0..y3 is addition, when calculating y4..y7 subtraction.
   * register add_0 is 1 when one needs to add, 0 when one needs to subtract.
   */

  always @(posedge clk)
    if (~rst)
      add_0 <= 1'd0;
    else if (clk_en)
      case (state)
        STATE_0,
        STATE_1,
        STATE_2,
        STATE_3:       add_0 <= 1'b1;
        STATE_4,
        STATE_6,
        STATE_5,
        STATE_7:       add_0 <= 1'b0;
        default        add_0 <= 1'b0;
      endcase
    else
      add_0 <= add_0;

  always @(posedge clk)
    if (~rst)
      begin
        add_1 <= 1'b0;
        add_2 <= 1'b0;
        add_3 <= 1'b0;
      end
    else if (clk_en)
      begin
        add_1 <= add_0;
        add_2 <= add_1;
        add_3 <= add_2;
      end
    else
      begin
      add_1 <= add_1;
      add_2 <= add_2;
      add_3 <= add_3;
      end

  always @(posedge clk)
    if (~rst)
      y <= 'sd0;
    else if (clk_en && add_3)
      y <= sum0246 + sum1357;
    else if (clk_en)
      y <= sum0246 - sum1357;
    else
      y <= y;

  always @(posedge clk)
    if (~rst) dta_out <= 'sd0;
    else if (clk_en) dta_out <=  y >>> dta_shift;
    else dta_out <= dta_out;

`ifdef DEBUG_IDCT_1D
  always @(posedge clk)
    begin
      $strobe("%m\toffset: %d", offset);
      $strobe("%m\tcos0: -------- cos1: %8d cos2: %8d cos3: %8d cos4: -------- cos5: %8d cos6: %8d cos7: %8d", cos1, cos2, cos3, cos5, cos6, cos7);
      $strobe("%m\t  x0: %8d   x1: %8d   x2: %8d   x3: %8d   x4: %8d   x5: %8d   x6: %8d   x7: %8d",   x0,   x1,   x2,   x3,   x4,   x5,   x6,   x7);
      $strobe("%m\tprod0: %d prod1: %d prod2: %d prod3: %d prod4: %d prod5: %d prod6: %d prod7: %d", prod0, prod1, prod2, prod3, prod4, prod5, prod6, prod7);
      $strobe("%m\tsum02: %8d sum46: %8d sum13: %8d sum57: %8d", sum02, sum46, sum13, sum57);
      $strobe("%m\tsum0246: %8d sum1357: %8d", sum0246, sum1357);
      $strobe("%m\ty: %8d", y);
      $strobe("%m\tdta_out: %8d", dta_out);
    end
`endif

endmodule

/*
 * 8x8 transpose ram. Swaps rows and columns.
 */

module transpose(clk, clk_en, rst, dta_in, dta_in_valid, dta_out, dta_out_valid, dta_out_eob);
  parameter  dta_width=16;                           // data width;
  input                    clk;                      // clock
  input                    clk_en;                   // clock enable
  input                    rst;                      // synchronous active low reset

  input    [dta_width -1:0]dta_in;                   // data in
  input                    dta_in_valid;
  output   [dta_width -1:0]dta_out;                  // transposed data out
  output reg               dta_out_valid;
  output reg               dta_out_eob;

  reg                 [7:0]wr_cnt;
  reg                 [6:0]wr_addr;
  reg                      wr_en;
  reg      [dta_width -1:0]wr_din;

  reg                 [7:0]rd_cnt;
  reg                 [6:0]rd_addr;
  reg                      rd_en;

  /*
   * We've got one dual-port ram, sufficient for two 8x8 matrices, with simultaneous reads and writes.
   */

  /* 
   * write counter 
   * write data cyclically in dual-port ram.
   */ 

  always @(posedge clk)
    if (~rst) wr_cnt <= 8'b0;
    else if (clk_en && dta_in_valid) wr_cnt <= wr_cnt + 8'd1;
    else wr_cnt <= wr_cnt;

  always @(posedge clk)
    if (~rst) wr_addr <= 7'b0;
    else if (clk_en && dta_in_valid) wr_addr <= wr_cnt[6:0];
    else wr_addr <= wr_addr;

  always @(posedge clk)
    if (~rst) wr_en <= 1'b0;
    else if (clk_en) wr_en <= dta_in_valid;
    else wr_en <= wr_en;

  always @(posedge clk)
    if (~rst) wr_din <= 1'b0;
    else if (clk_en) wr_din <= dta_in;
    else wr_din <= wr_din;

  /* read counter */
  always @(posedge clk)
    if (~rst) rd_cnt <= 8'b0;
    else if (clk_en && (wr_cnt[7:6] != rd_cnt[7:6])) rd_cnt <= rd_cnt + 8'd1;
    else rd_cnt <= rd_cnt;

  always @(posedge clk)
    if (~rst) rd_addr <= 7'b0;
    else if (clk_en) rd_addr <= {rd_cnt[6], rd_cnt[2:0], rd_cnt[5:3]}; // swap rows and columns in address
    else rd_addr <= rd_addr;

  always @(posedge clk)
    if (~rst) rd_en <= 1'b0;
    else if (clk_en) rd_en <= (wr_cnt[7:6] != rd_cnt[7:6]);
    else rd_en <= rd_en;

  always @(posedge clk)
    if (~rst) dta_out_valid <= 1'b0;
    else if (clk_en) dta_out_valid <= rd_en;
    else dta_out_valid <= dta_out_valid;

  always @(posedge clk)
    if (~rst) dta_out_eob <= 1'b0;
    else if (clk_en) dta_out_eob <= rd_en && (rd_addr[5:0] == 6'd63);
    else dta_out_eob <= dta_out_eob;

  /* transposition memory */

  dpram_sc
    #(.addr_width(7),                                         // number of bits in address bus
    .dta_width(dta_width))                                    // number of bits in data bus
    ram0 (
    .rst(rst),                                                // reset, active low
    .clk(clk),                                                // clock, rising edge trigger
    .wr_en(wr_en),                                            // write enable, active high
    .wr_addr(wr_addr),                                        // write address
    .din(wr_din),                                             // data input
    .rd_en(rd_en),                                            // read enable, active high 
    .rd_addr(rd_addr),                                        // read address
    .dout(dta_out)                                            // data output
    );

`ifdef DEBUG_TRANSPOSE
  always @(posedge clk)
    begin
      $strobe("%m\twr_cnt: %d rd_cnt: %d dta_in: %d dta_in_valid: %d dta_out: %d dta_out_valid: %d dta_out_eob: %d", 
      wr_cnt, rd_cnt, dta_in, dta_in_valid, dta_out, dta_out_valid, dta_out_eob);
      $strobe("%m\twr_en: %d wr_addr: %d wr_din: %d rd_en: %d rd_addr: %d dta_out: %d",
      wr_en, wr_addr, wr_din, rd_en, rd_addr, dta_out);
    end
`endif

endmodule


/*
 * Clips idct output to -256..255
 */

module clip_col(clk, clk_en, rst, dta_in, dta_in_valid, dta_out, dta_out_valid);
  input                  clk;                      // clock
  input                  clk_en;                   // clock enable
  input                  rst;                      // synchronous active low reset
  input signed     [20:0]dta_in;                   // data in
  input                  dta_in_valid;
  output reg signed [8:0]dta_out;                 // data out
  output reg             dta_out_valid;

  always @(posedge clk)
    if (~rst) dta_out <= 'sd0;
    else if (clk_en && ((dta_in[20:8] == 13'b1111111111111) || (dta_in[20:8] == 13'b000000000000))) dta_out <= dta_in[8:0];
    else if (clk_en) dta_out <= {dta_in[20], {8{~dta_in[20]}}}; // clipping
    else dta_out <= dta_out;

  always @(posedge clk)
    if (~rst) dta_out_valid <= 'sd0;
    else if (clk_en) dta_out_valid <= dta_in_valid;
    else dta_out_valid <= dta_out_valid;

endmodule

module mult22x16(clk, clk_en, rst, product, multiplicand, multiplier); 
   input         clk;
   input         clk_en;
   input         rst;
   input signed [21:0]  multiplier;
   input signed [15:0]  multiplicand;
   output reg signed [37:0] product;

/* 
 * the following code implements
 *   always @(posedge clk)
 *     product <= multiplier * multiplicand;
 * using only a single 18x18 multiplier, a few shifts and adders.
 *
 * See "Expanding Virtex-II" by Ken Chapman, Xilinx UK, 06/30/2001 for
 * a discussion about expanding multipliers.
 *
 */
   wire /* unsigned */  [3:0] multiplier_lsb;
   wire signed         [17:0] multiplier_msb;

   reg signed [19:0] partial_product_1;
   reg signed [33:0] partial_product_2;

   assign multiplier_lsb = multiplier[3:0]; 
   assign multiplier_msb = multiplier[21:4];

   always @(posedge clk)
     if (~rst) partial_product_2 <= 34'b0;
     else if (clk_en) partial_product_2 <= multiplier_msb * multiplicand;
     else partial_product_2 <= partial_product_2;

   always @(posedge clk)
     if (~rst) partial_product_1 <= 20'b0;
     else if (clk_en) 
       partial_product_1 <= (multiplier_lsb[0] ? {{4{multiplicand[15]}}, multiplicand      } : 20'b0) + 
                            (multiplier_lsb[1] ? {{3{multiplicand[15]}}, multiplicand, 1'b0} : 20'b0) +
                            (multiplier_lsb[2] ? {{2{multiplicand[15]}}, multiplicand, 2'b0} : 20'b0) +
                            (multiplier_lsb[3] ? {{1{multiplicand[15]}}, multiplicand, 3'b0} : 20'b0);
     else partial_product_1 <= partial_product_1;

   always @(posedge clk)
     if (~rst) product <= 38'b0;
     else if (clk_en) product <=  {partial_product_2, 4'b0} + { {18{partial_product_1[19]}}, partial_product_1};
     else product <= product;

endmodule

 /*
  idct_fifo

  Groups idct coefficients into a row of eight.
 
  Input: 9-bit signed idct coefficients
  Output: one row of 72 bits, consisting of 8 idct coefficients,
  which is the  'prediction error', to be added to the motion compensation prediction.
  */

module idct_fifo(
  rst, clk_en, clk,
  idct_data, idct_valid, idct_eob,
  idct_wr_dta_full, idct_wr_dta_almost_full, idct_wr_dta_overflow,
  idct_rd_dta_empty, idct_rd_dta_almost_empty, idct_rd_dta_valid,
  idct_rd_dta_en, idct_rd_dta
  );

  input              rst;                      // synchronous active low reset
  input              clk_en;                   // clock enable
  input              clk;                      // clock

  input signed  [8:0]idct_data;
  input              idct_eob;
  input              idct_valid;

  /* idct coefficients fifo */
  /* idct coefficients fifo: writing */
  output             idct_wr_dta_full;
  output             idct_wr_dta_almost_full;
  output             idct_wr_dta_overflow;
  reg          [71:0]idct_wr_dta;
  reg                idct_wr_dta_en;
  /* idct coefficients fifo: reading */
  output             idct_rd_dta_empty;
  output             idct_rd_dta_almost_empty;
  input              idct_rd_dta_en;
  output       [71:0]idct_rd_dta;
  output             idct_rd_dta_valid;

  reg           [8:0]cnt;

`include "fifo_size.v"

  always @(posedge clk)
    if (~rst) idct_wr_dta <= 72'b0;
    else if (clk_en && idct_valid) idct_wr_dta <= {idct_wr_dta[62:0], idct_data};
    else idct_wr_dta <= idct_wr_dta;

  always @(posedge clk)
    if (~rst) cnt <= 8'b1;
    else if (clk_en && idct_valid) cnt <= {cnt[6:0], cnt[7]};
    else cnt <= cnt;

  always @(posedge clk)
    if (~rst) idct_wr_dta_en <= 1'b0;
    else if (clk_en) idct_wr_dta_en <= cnt[7] && idct_valid;
    else idct_wr_dta_en <= idct_wr_dta_en;

  /* 
     prediction error fifo. (f[y][x] in Figure 7-5).
     addr_width = 6 > big enough to hold all blocks of a macroblock (6 blocks for 4:2:0, 8 for 4:4:4) 

     Note one can read data from the fifo even when clk_en is low. 
     This allows motcomp to drain the fifo.
   */

  fifo_sc
    #(.addr_width(PREDICT_DEPTH),
    .dta_width(9'd72),
    .prog_thresh(PREDICT_THRESHOLD))
    predict_err_fifo (
    .rst(rst),
    .clk(clk),
    .din(idct_wr_dta),
    .wr_en(idct_wr_dta_en && clk_en),
    .full(idct_wr_dta_full),
    .wr_ack(),
    .overflow(idct_wr_dta_overflow),
    .prog_full(idct_wr_dta_almost_full),
    .dout(idct_rd_dta),
    .rd_en(idct_rd_dta_en),
    .empty(idct_rd_dta_empty),
    .valid(idct_rd_dta_valid),
    .underflow(),
    .prog_empty(idct_rd_dta_almost_empty)
    );

`ifdef CHECK
  always @(posedge clk)
    if (idct_wr_dta_overflow)
      begin
        #0 $display("%m\t*** error: idct fifo overflow ***");
        $stop;
      end
`endif

//`define DEBUG 1
`ifdef DEBUG
  always @(posedge clk)
    $strobe("%m\tclk_en: %d idct_data: %5d valid: %d  eob: %d", clk_en, idct_data, idct_valid, idct_eob);

  wire signed [8:0]predict_err_0;
  wire signed [8:0]predict_err_1;
  wire signed [8:0]predict_err_2;
  wire signed [8:0]predict_err_3;
  wire signed [8:0]predict_err_4;
  wire signed [8:0]predict_err_5;
  wire signed [8:0]predict_err_6;
  wire signed [8:0]predict_err_7;

  assign {predict_err_0, predict_err_1, predict_err_2, predict_err_3, predict_err_4, predict_err_5, predict_err_6, predict_err_7} = idct_rd_dta;

  always @(posedge clk)
    $strobe("%m\tpredict_err: %5d %5d %5d %5d %5d %5d %5d %5d valid: %d", predict_err_0, predict_err_1, predict_err_2, predict_err_3, predict_err_4, predict_err_5, predict_err_6, predict_err_7, idct_rd_dta_valid);

  always @(posedge clk)
    $strobe("%m\tidct_rd_dta: %18h idct_rd_dta_valid: %d idct_rd_dta_en: %d idct_rd_dta_empty: %d", idct_rd_dta, idct_rd_dta_valid, idct_rd_dta_en, idct_rd_dta_empty);
`endif
endmodule
/* not truncated */
