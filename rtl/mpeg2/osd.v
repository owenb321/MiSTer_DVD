/* 
 * osd.v
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
 * osd.v - On-Screen Display
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

/*
 * The On-Screen Display (OSD) is used for menus and user interaction.
 * It offers a palette of 256 24-bit colors, transparency and blinking.
 * The osd has the same resolution as the mpeg video being shown.
 *
 * Each osd pixel is looked up in the osd color lookup table.
 * The osd color lookup table returns, for every 8-bit osd pixel, 32 bits:
 *   y (8 bit), u (8 bit), v(8 bit), m(8 bit).
 * y, u, and v are the luma and chroma values of the osd color.
 * m is the osd color mode, and determines the displayed pixel according
 * to the following table:
 *   m (mode)
 *   xxx00000: alpha = 0/16
 *   xxx00001: alpha = 1/16
 *   xxx00010: alpha = 2/16
 *   xxx00011: alpha = 3/16
 *   xxx00100: alpha = 4/16
 *   xxx00101: alpha = 5/16
 *   xxx00110: alpha = 6/16
 *   xxx00111: alpha = 7/16
 *   xxx01000: alpha = 8/16
 *   xxx01001: alpha = 9/16
 *   xxx01010: alpha = 10/16
 *   xxx01011: alpha = 11/16
 *   xxx01100: alpha = 12/16
 *   xxx01101: alpha = 13/16
 *   xxx01110: alpha = 14/16
 *   xxx01111: alpha = 15/16
 *   xxx11111: alpha = 16/16
 *   xx0xxxxx: attenuate mpeg pixel
 *   xx1xxxxx: alpha blend osd and mpeg pixel
 *   00xxxxxx: output is mpeg pixel
 *   01xxxxxx: output is attenuated/alpha blended pixel
 *   10xxxxxx: output is osd pixel
 *   11xxxxxx: blink; alternate between osd and attenuated/alpha blended pixel
 *
 * By combining these values, it is possible to show an OSD, either blinking
 * or static, on a black or a transparent background.
 */

module mpeg2_osd (
  clk, clk_en, rst,
  y_in, u_in, v_in, h_sync_in, v_sync_in, pixel_en_in, osd_in,
  y_out, u_out, v_out, h_sync_out, v_sync_out, pixel_en_out,
  osd_clt_rd_addr, osd_clt_rd_en, osd_clt_rd_dta, 
  osd_enable, interlaced
  );
  input  clk;
  input  clk_en;
  input  rst;

  input [7:0]y_in;
  input [7:0]u_in;
  input [7:0]v_in;

  output reg [7:0]y_out;
  output reg [7:0]u_out;
  output reg [7:0]v_out;

  input pixel_en_in;
  input h_sync_in;
  input v_sync_in;

  output reg pixel_en_out;
  output reg h_sync_out;
  output reg v_sync_out;

 /* OSD pixel value */
  input      [7:0]osd_in;

 /* OSD color look-up table */
  output reg [7:0]osd_clt_rd_addr;
  output reg      osd_clt_rd_en;
  input     [31:0]osd_clt_rd_dta;
  input           osd_enable;
  input           interlaced;

  reg blink;

 /* 
  * stage 0
  * Look up osd color
  */
  reg [7:0]y_0;
  reg [7:0]u_0;
  reg [7:0]v_0;
  reg      pixel_en_0;
  reg      h_sync_0;
  reg      v_sync_0;

  always @(posedge clk)
    if (~rst) osd_clt_rd_addr <= 8'b0;
    else if (clk_en && pixel_en_in) osd_clt_rd_addr <= osd_in;
    else osd_clt_rd_addr <= osd_clt_rd_addr;

  always @(posedge clk)
    if (~rst) osd_clt_rd_en <= 1'b0;
    else if (clk_en) osd_clt_rd_en <= pixel_en_in;
    else osd_clt_rd_en <= osd_clt_rd_en;

  always @(posedge clk)
    if (~rst) {y_0, u_0, v_0} <= 24'b0;
    else if (clk_en && pixel_en_in) {y_0, u_0, v_0} <= {y_in, u_in, v_in};
    else {y_0, u_0, v_0} <= {y_0, u_0, v_0};
  
  always @(posedge clk)
    if (~rst) {pixel_en_0, h_sync_0, v_sync_0} <= 3'b0;
    else if (clk_en) {pixel_en_0, h_sync_0, v_sync_0} <= {pixel_en_in, h_sync_in, v_sync_in};
    else {pixel_en_0, h_sync_0, v_sync_0} <= {pixel_en_0, h_sync_0, v_sync_0};
  
 /* 
  * stage 1
  * Wait for osd clt lookup
  */
  reg [7:0]y_1;
  reg [7:0]u_1;
  reg [7:0]v_1;
  reg      pixel_en_1;
  reg      h_sync_1;
  reg      v_sync_1;

  always @(posedge clk)
    if (~rst) {y_1, u_1, v_1} <= 24'b0;
    else if (clk_en) {y_1, u_1, v_1} <= {y_0, u_0, v_0};
    else {y_1, u_1, v_1} <= {y_1, u_1, v_1};
  
  always @(posedge clk)
    if (~rst) {pixel_en_1, h_sync_1, v_sync_1} <= 3'b0;
    else if (clk_en) {pixel_en_1, h_sync_1, v_sync_1} <= {pixel_en_0, h_sync_0, v_sync_0};
    else {pixel_en_1, h_sync_1, v_sync_1} <= {pixel_en_1, h_sync_1, v_sync_1};
  
 /* 
  * stage 2
  * Read osd color 
  */
  reg [7:0]y_2;
  reg [7:0]u_2;
  reg [7:0]v_2;
  reg [7:0]y_blend_2;
  reg [7:0]u_blend_2;
  reg [7:0]v_blend_2;
  reg [7:0]osd_y_2;      /* stage 2: osd lumi */
  reg [7:0]osd_u_2;      /* stage 2: osd chromi */
  reg [7:0]osd_v_2;      /* stage 2: osd chromi */
  reg [3:0]osd_mode_2;   /* stage 2: osd mode: motion video, osd, blinking osd */
  reg [3:0]osd_transp_2; /* stage 2: osd transparency factor */
  reg      pixel_en_2;
  reg      h_sync_2;
  reg      v_sync_2;

  wire [7:0]osd_clt_y;
  wire [7:0]osd_clt_u;
  wire [7:0]osd_clt_v;
  wire [3:0]osd_clt_mode;
  wire [3:0]osd_clt_transp;

  assign {osd_clt_y, osd_clt_u, osd_clt_v, osd_clt_mode, osd_clt_transp} = osd_clt_rd_dta;

  always @(posedge clk)
    if (~rst) {osd_y_2, osd_u_2, osd_v_2, osd_mode_2, osd_transp_2} <= 32'b0;
    else if (clk_en) {osd_y_2, osd_u_2, osd_v_2, osd_mode_2, osd_transp_2} <= osd_clt_rd_dta;
    else {osd_y_2, osd_u_2, osd_v_2, osd_mode_2, osd_transp_2} <= {osd_y_2, osd_u_2, osd_v_2, osd_mode_2, osd_transp_2};

  always @(posedge clk)
    if (~rst) {y_2, u_2, v_2} <= 24'b0;
    else if (clk_en) {y_2, u_2, v_2} <= {y_1, u_1, v_1};
    else {y_2, u_2, v_2} <= {y_2, u_2, v_2};
  
  always @(posedge clk)
    if (~rst) {y_blend_2, u_blend_2, v_blend_2} <= 24'b0;
    else if (clk_en) {y_blend_2, u_blend_2, v_blend_2} <= osd_clt_mode[1] ? {osd_clt_y, osd_clt_u, osd_clt_v} : {8'd16, 8'd128, 8'd128}; /* (y, u, v) = (16, 128, 128) corresponds to black */
    else {y_blend_2, u_blend_2, v_blend_2} <= {y_blend_2, u_blend_2, v_blend_2};
  
  always @(posedge clk)
    if (~rst) {pixel_en_2, h_sync_2, v_sync_2} <= 3'b0;
    else if (clk_en) {pixel_en_2, h_sync_2, v_sync_2} <= {pixel_en_1, h_sync_1, v_sync_1};
    else {pixel_en_2, h_sync_2, v_sync_2} <= {pixel_en_2, h_sync_2, v_sync_2};
  
 /* 
  * stage 3-5
  * Transparency. Attenuate mpeg pixel.
  */ 
  wire [7:0]y_5;
  wire [7:0]u_5;
  wire [7:0]v_5;
  wire [7:0]y_transp_5;   /* stage 5: attenuated mpeg lumi */
  wire [7:0]u_transp_5;   /* stage 5: attenuated mpeg chromi */
  wire [7:0]v_transp_5;   /* stage 5: attenuated mpeg chromi */
  wire [7:0]osd_y_5;      /* stage 5: osd lumi */
  wire [7:0]osd_u_5;      /* stage 5: osd chromi */
  wire [7:0]osd_v_5;      /* stage 5: osd chromi */
  wire [3:0]osd_mode_5;   /* stage 5: osd mode: motion video, osd, transparent osd, blinking osd */
  wire      pixel_en_5;
  wire      h_sync_5;
  wire      v_sync_5;

  alpha_blend 
    #(.dta_width(55))
    alpha_blend_y (
    .clk(clk), 
    .clk_en(clk_en), 
    .rst(rst),
    .x_in(y_blend_2), 
    .y_in(y_2), 
    .dta_in({osd_y_2, osd_u_2, osd_v_2, osd_mode_2, y_2, u_2, v_2, pixel_en_2, h_sync_2, v_sync_2}),
    .z_out(y_transp_5), 
    .dta_out({osd_y_5, osd_u_5, osd_v_5, osd_mode_5, y_5, u_5, v_5, pixel_en_5, h_sync_5, v_sync_5}),
    .alpha_1(osd_mode_2[0]), 
    .alpha_2(osd_transp_2)
    );
  
  alpha_blend 
    #(.dta_width(1))
    alpha_blend_u (
    .clk(clk), 
    .clk_en(clk_en), 
    .rst(rst),
    .x_in(u_blend_2), 
    .y_in(u_2), 
    .dta_in(1'b0),
    .z_out(u_transp_5), 
    .alpha_1(osd_mode_2[0]), 
    .alpha_2(osd_transp_2),
    .dta_out()
    );
  
  alpha_blend 
    #(.dta_width(1))
    alpha_blend_v (
    .clk(clk), 
    .clk_en(clk_en), 
    .rst(rst),
    .x_in(v_blend_2), 
    .y_in(v_2), 
    .dta_in(1'b0),
    .z_out(v_transp_5), 
    .alpha_1(osd_mode_2[0]), 
    .alpha_2(osd_transp_2),
    .dta_out()
    );
  
 /*
  * stage 5
  * Select between mpeg pixel, attenuated mpeg pixel, osd pixel, or blinking osd.
  */

  always @(posedge clk)
    if (~rst) {y_out, u_out, v_out} <= 24'b0;
    else if (clk_en && ~pixel_en_5) {y_out, u_out, v_out} <= {8'd16, 8'd128, 8'd128};                                /* black during blanking */
    else if (clk_en && osd_enable)
      case (osd_mode_5[3:2])
        3'b00:  {y_out, u_out, v_out} <=         {y_5,        u_5,        v_5       }                              ; /* mpeg pixel */
        3'b01:  {y_out, u_out, v_out} <=         {y_transp_5, u_transp_5, v_transp_5}                              ; /* attenuated/alpha blended mpeg pixel */
        3'b10:  {y_out, u_out, v_out} <=                                                {osd_y_5, osd_u_5, osd_v_5}; /* osd pixel */
        3'b11:  {y_out, u_out, v_out} <= blink ? {y_transp_5, u_transp_5, v_transp_5} : {osd_y_5, osd_u_5, osd_v_5}; /* alternate between osd and attenuated/alpha blended mpeg pixel */
        default {y_out, u_out, v_out} <=         {y_5       , u_5       , v_5       }                              ; /* mpeg pixel */
      endcase
    else if (clk_en) {y_out, u_out, v_out} <= {y_5, u_5, v_5};                                                       /* osd switched off */
    else {y_out, u_out, v_out} <= {y_out, u_out, v_out};

  always @(posedge clk)
    if (~rst) {pixel_en_out, h_sync_out, v_sync_out} <= 3'b0;
    else if (clk_en) {pixel_en_out, h_sync_out, v_sync_out} <= {pixel_en_5, h_sync_5, v_sync_5};
    else {pixel_en_out, h_sync_out, v_sync_out} <= {pixel_en_out, h_sync_out, v_sync_out};
  
  /* Blinking */

  /*
   * count number of frames/fields. 
   * field_cnd increases by 1 on the falling edge of vsync 
   */

  reg [6:0]field_cnt;

  always @(posedge clk)
    if (~rst) field_cnt <= 0;
    else if (clk_en && (v_sync_1 == 1'b0) && (v_sync_2 == 1'b1)) field_cnt <= field_cnt + 1;
    else field_cnt <= field_cnt;
 
  always @(posedge clk)
    if (~rst) blink <= 0;
    else if (clk_en) blink <= interlaced ? field_cnt[6] : field_cnt[5]; // toggles every second or so. (Actually, every 32 frames if progressive, every 64 fields if interlaced)
    else blink <= blink;

`ifdef DEBUG
  always @(posedge clk)
    $strobe("%m\tin: %0d %0d %0d 1: %0d %0d %0d 2: %0d %0d %0d 5: %0d %0d %0d out: %0d %0d %0d enable: %d", y_in, u_in, v_in, y_1, u_1, v_1, y_2, u_2, v_2, y_5, u_5, v_5, y_out, u_out, v_out, osd_enable);
`endif
endmodule

/*
 * On-Screen Display Color Lookup Table 
 *
 * Register file writes to clt, 
 * osd reads from clt.
 */
`undef DEBUG
//`define DEBUG 1

module osd_clt (
  clk,
  rst,
  osd_clt_wr_en,
  osd_clt_wr_addr,
  osd_clt_wr_dta,
  dot_clk,
  dot_rst,
  osd_clt_rd_addr,
  osd_clt_rd_en,
  osd_clt_rd_dta);

  input        clk;
  input        rst;
  input        osd_clt_wr_en;
  input   [7:0]osd_clt_wr_addr;
  input  [31:0]osd_clt_wr_dta;
  input        dot_clk;
  input        dot_rst;
  input   [7:0]osd_clt_rd_addr;
  input        osd_clt_rd_en;
  output [31:0]osd_clt_rd_dta;

  reg     [7:0]clt_wr_addr;
  reg          clt_wr_en;
  reg    [31:0]clt_wr_dta;

  parameter [2:0]
    STATE_INIT  = 3'b001,
    STATE_CLEAR = 3'b010,
    STATE_RUN   = 3'b100;

  reg [2:0]next;
  reg [2:0]state;

  /*
   * state machine to initialize color-lookup table at reset
   */

  always @*
    case (state)
      STATE_INIT:  next = STATE_CLEAR;
      STATE_CLEAR: if (clt_wr_addr == 8'hff) next = STATE_RUN;
                   else next = STATE_CLEAR;
      STATE_RUN:   next = STATE_RUN;
      default:     next = STATE_INIT;
    endcase 

  always @(posedge clk)
    if (~rst) state <= STATE_INIT;
    else state <= next;

  always @(posedge clk)
    if (~rst) clt_wr_en <= 1'b0;
    else
      case (state)
        STATE_INIT:  clt_wr_en <= 1'b0;
	STATE_CLEAR: clt_wr_en <= 1'b1;
	STATE_RUN:   clt_wr_en <= osd_clt_wr_en;
	default      clt_wr_en <= 1'b0;
      endcase

  always @(posedge clk)
    if (~rst) clt_wr_addr <= 8'b0;
    else
      case (state)
        STATE_INIT:  clt_wr_addr <= 8'b0;
	STATE_CLEAR: clt_wr_addr <= clt_wr_addr + 8'b1;
	STATE_RUN:   clt_wr_addr <= osd_clt_wr_addr;
	default      clt_wr_addr <= 8'b0;
      endcase

  always @(posedge clk)
    if (~rst) clt_wr_dta <= 32'b0;
    else
      case (state)
        STATE_INIT:  clt_wr_dta <= 32'b0;
	STATE_CLEAR: clt_wr_dta <= 32'b0;
	STATE_RUN:   clt_wr_dta <= osd_clt_wr_dta;
	default      clt_wr_dta <= 32'b0;
      endcase

  /* OSD color look-up table */

  dpram_dc 
    #(.addr_width(8),                                         // number of bits in address bus
    .dta_width(32))                                           // number of bits in data bus
    osd_clt (
    .wr_rst(rst),                                             // reset, sync with write clock, active low
    .wr_clk(clk),                                             // write clock, rising edge trigger
    .wr_en(clt_wr_en),                                        // write enable, active high
    .wr_addr(clt_wr_addr),                                    // write address
    .din(clt_wr_dta),                                         // data input
    .rd_rst(dot_rst),                                         // reset, sync with read clock, active low
    .rd_clk(dot_clk),                                         // read clock, rising edge trigger
    .rd_en(osd_clt_rd_en),                                    // read enable, active high
    .rd_addr(osd_clt_rd_addr),                                // read address
    .dout(osd_clt_rd_dta)                                     // data output
    );

`ifdef DEBUG
  always @(posedge clk)
    $strobe("%m\tstate: %b clt_wr_en: %x clt_wr_addr: %x clt_wr_dta: %x", state, clt_wr_en, clt_wr_addr, clt_wr_dta);
`endif
endmodule

/*
 * Alpha blend x and y, using
 * z <= ( alpha_2 * x + ~alpha_2 * y + (alpha_1 ? x : y) + (1'b1 << (alpha_width - 1))) >> alpha_width;
 * where alpha_2 is 4 bits wide, alpha_width = 4.
 * To obtain alpha = 1, z = x set alpha_1 = 1, alpha_2 = 1111.
 * For values of alpha other than 1, set alpha_1 = 0.
 */
`undef DEBUG
//`define DEBUG 1

module alpha_blend (
  clk, clk_en, rst,
  x_in, y_in, alpha_1, alpha_2, dta_in, z_out, dta_out
  );
  parameter dta_width=8;
  input  clk;
  input  clk_en;
  input  rst;

  input [7:0]x_in;
  input [7:0]y_in;
  input      alpha_1;
  input [3:0]alpha_2;
  input [dta_width-1:0]dta_in;

  output reg [7:0]z_out;
  output reg [dta_width-1:0]dta_out;

  /* 
   * stage 1.
   */

  reg [12:0]x_prod_1;
  reg [12:0]y_prod_1;
  reg [dta_width-1:0]dta_1;

  wire [3:0]alpha_2_inv = ~alpha_2;

  always @(posedge clk)
    if (~rst) x_prod_1 <= 13'd0;
    else if (clk_en) x_prod_1 <= x_in * alpha_2 + 14'b1000;
    else x_prod_1 <= x_prod_1;

  always @(posedge clk)
    if (~rst) y_prod_1 <= 13'd0;
    else if (clk_en) y_prod_1 <= y_in * alpha_2_inv + (alpha_1 ? x_in : y_in);
    else y_prod_1 <= y_prod_1;

  always @(posedge clk)
    if (~rst) dta_1 <= 0;
    else if (clk_en) dta_1 <= dta_in;
    else dta_1 <= dta_1;

  /* 
   * stage 2.
   */

  reg [14:0]z_sum_2;
  wire [14:0]x_prod_1_ext = {1'b0, x_prod_1};
  wire [14:0]y_prod_1_ext = {1'b0, y_prod_1};
  reg [dta_width-1:0]dta_2;

  always @(posedge clk)
    if (~rst) z_sum_2 <= 15'd0;
    else if (clk_en) z_sum_2 <= (x_prod_1_ext + y_prod_1_ext) >> 4;
    else z_sum_2 <= z_sum_2;

  always @(posedge clk)
    if (~rst) dta_2 <= 0;
    else if (clk_en) dta_2 <= dta_1;
    else dta_2 <= dta_2;

  /* 
   * stage 3.
   */

  always @(posedge clk)
    if (~rst) z_out <= 8'd0;
    else if (clk_en) z_out <= (z_sum_2[14:8] == 7'b0) ? z_sum_2[7:0] : 8'd255;
    else z_out <= z_out;

  always @(posedge clk)
    if (~rst) dta_out <= 0;
    else if (clk_en) dta_out <= dta_2;
    else dta_out <= dta_out;

`ifdef DEBUG
  always @(posedge clk)
    $strobe("%m\tx_in: %d  y_in: %d  alpha_1: %d  alpha_2: %d  x_prod_1: %d  y_prod_1: %d  z_sum_2: %d  z_out: %d",
                 x_in, y_in, alpha_1, alpha_2, x_prod_1, y_prod_1, z_sum_2, z_out);
`endif
endmodule
/* not truncated */
