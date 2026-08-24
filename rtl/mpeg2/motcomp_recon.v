/* 
 * motcomp_recon.v
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
 * motcomp_recon.v - Motion Compensation: pixel reconstruction.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

 /*
  Block reconstruction summary:
   - read work to be done from dst fifo.
   - combine forward prediction (fwd_rd_dta) and backward prediction (bwd_rd_dta) (p[y][x] in Figure 7-5)
   - add idct coefficients (f[y][x] in Figure 7-5)
   - clip and saturate to 0..255 range
   - write reconstructed pixels to frame store (recon_wr_dta, recon_wr_addr) 

  Can produce one 8-pixel row every two clock cycles. In practice this means speed is limited by how fast 
  the memory subsystem can feed it with pixels.

  In detail:
   - from dst fifo, read work to be done. This includes write_address_0, the address where the reconstructed pixels have to be written
     if write_recon_0 is high.

   - Compute forward prediction: (prediction_fwd_row)
     if motion_forward_0 is high, read  a row of 16 pixels from forward motion compensation data fifo (fwd_row_0).                           
     Shift the double row left by fwd_hor_offset_0 pixels. 
     If fwd_hor_halfpixel_0, do linear interpolation between two adjacent pixels on same horizontal.
     If fwd_ver_halfpixel_0, do linear interpolation between two adjacent pixels on fwd_row_0 and the previous row, prev_fwd_2.

     If motion_forward_0 is low, forward prediction is not used (is zero).

   - Compute forward prediction: (prediction_bwd_row)
     if motion_backward_0 is high, read  a row of 16 pixels from backward motion compensation data fifo (bwd_row_0).                           
     Shift the double row left by bwd_hor_offset_0 pixels. 
     If bwd_hor_halfpixel_0, do linear interpolation between two adjacent pixels on same horizontal.
     If bwd_ver_halfpixel_0, do linear interpolation between two adjacent pixels on bwd_row_0 and the previous row, prev_bwd_2.

     If motion_backward_0 is low, backward prediction is not used (is zero).

   - Obtain idct coefficients
     - If write_recon_0 is high, read  a row of eight idct coefficients from idct_row_0.
     - If write_recon_0 is low, idct coefficients are not used.

   - Combine predictions (combine_row)
     - If motion_forward_0 is asserted but motion_backward_0 is not asserted, prediction is forward prediction.
     - If motion_backward_0 is asserted but motion_forward_0 is not asserted, prediction is backward prediction.
     - If both motion_forward_0 and motion_backward_0 are asserted, prediction is the average of forward and backward prediction. 
     - If neither motion_forward_0 nor motion_backward_0 are asserted, prediction is all zeroes.
     - add idct coefficients to the prediction.
     - clip and saturate each pixel to 0..255 range.
     This produces the reconstructed block row.

   - If write_recon_0 is high, write the reconstructed block row to frame store at address write_address_0.
     If write_recon_0 is low, no action is taken. 

  Use of write_recon_0:
     In vertical halfpixel calculations we need the value of the pixels above the current pixel (the previous row)
     to do vertical interpolation. By setting write_recon_0 low, the fwd/bwd pixels of the first row are loaded into the appropriate
     registers, but do not produce a write to the frame store. A write would be inappropriate: since it's the first row, 
     there's no previous row and vertical halfpixel calculations would fail.

     As an example, consider motion compensation of an 8x8 block. dst_rd_write_recon is low during the first row of fwd/bwd pixels,
     and high during the eight following rows. Then comes the next 8x8 block: again dst_rd_write_recon is low during the first row, 
     and high during the next eight rows.

  Note motcomp_recon reconstructs a row of 8 pixels in parallel.

  The pixels are stored in the frame store as signed 8-bit values, with values between -128 and 127.
  One can obtain the unsigned pixel values by adding 128.
  Thus, -128 corresponding to 0 and 127 corresponding to 255.
  Storing the pixels as signed 8-bit values has the advantage that one can average two frames without the dc level going up. 
  The 128 gets added at the end, in the yuv to rgb conversion.
  */

module motcomp_recon(
  clk, clk_en, rst, 
  dst_rd_dta_empty, dst_rd_dta_en, dst_rd_dta, dst_rd_dta_valid,
  idct_rd_dta_empty, idct_rd_dta_en, idct_rd_dta, idct_rd_dta_valid,
  fwd_rd_dta_empty, fwd_rd_dta_en, fwd_rd_dta, fwd_rd_dta_valid,
  bwd_rd_dta_empty, bwd_rd_dta_en, bwd_rd_dta, bwd_rd_dta_valid,
  recon_wr_full, recon_wr_almost_full, recon_wr_en, recon_wr_addr, recon_wr_dta
  );

  input              clk;                      // clock
  input              clk_en;                   // clock enable
  input              rst;                      // synchronous active low reset

  /* reading block address and recon parameters */
  input             dst_rd_dta_empty;          // low if dst fifo is not empty
  input             dst_rd_dta_valid;          // high if dst fifo read successful
  output            dst_rd_dta_en;             // assert to read dst fifo
  input       [34:0]dst_rd_dta;                // reconstruction parameters: address to write reconstructed block row to, whether to use forward or backward motion compensation, ...

  /* reading idct data */
  input       [71:0]idct_rd_dta;               // fifo of idct coefficients. Each idct_rd_dta is a row of 8 idct coefficients. Each idct coefficient is 9-bit signed.
  output            idct_rd_dta_en;            // assert to read next idct coefficients
  input             idct_rd_dta_empty;         // low if idct_rd_dta fifo not empty
  input             idct_rd_dta_valid;         // asserted if idct_rd_dta valid

  /* reading forward reference frame: reading data */
  input             fwd_rd_dta_empty;          // low if fwd_rd_dta fifo not empty
  output            fwd_rd_dta_en;             // assert to read next fwd_rd_dta
  input       [63:0]fwd_rd_dta;                // fifo of forward block rows
  input             fwd_rd_dta_valid;

  /* reading backward reference frame: reading data */
  input             bwd_rd_dta_empty;          // low if bwd_rd_dta fifo not empty
  output            bwd_rd_dta_en;             // assert to read next bwd_rd_dta
  input       [63:0]bwd_rd_dta;                // fifo of backward block rows
  input             bwd_rd_dta_valid;

  /* writing reconstructed frame: writing address and data */
  input             recon_wr_full;             // high if recon_wr_dta/recon_wr_addr fifo full.
  input             recon_wr_almost_full;      // high if recon_wr_dta/recon_wr_addr fifo is almost full (8 free slots left) XXX
  output reg        recon_wr_en;               // assert to write recon_wr_addr/recon_wr_dta to fifo.
  output reg  [21:0]recon_wr_addr;             // address to write reconstructed block row to
  output reg  [63:0]recon_wr_dta;              // reconstructed block row

  /*
   To reconstruct a row 
    - if dst_rd_motion_forward is asserted, fwd_rd_dta_empty should be low: forward prediction data is needed (~fwd_rd_dta_empty)
    - if dst_rd_motion_backward is asserted, bwd_rd_dta_empty should be low: backward prediction data is needed (~bwd_rd_dta_empty)
    - idct_rd_dta_empty is not asserted: eight idct coefficients are available in the fifo pipeline. (~idct_rd_dta_empty)
      (For skipped macroblocks and uncoded blocks , the inverse discrete cosine transform data are all zeroes.)
    - recon_wr_full is not asserted: there is room to write the reconstructed block row.
   */

  parameter [1:0]
    STATE_WAIT       = 3'b001, // wait for data ready
    STATE_RUN        = 3'b010; // start pipeline and read next data

  reg           [1:0]state;
  reg           [1:0]next;

  /* stage 0 variables */
  reg                dst_rd_en;
  wire               dst_valid_0;

  wire               valid_0;
  wire        [127:0]fwd_row_0; // one row of 16 pixels, each pixel an 8 bit unsigned reg. 
  wire               fwd_row_0_valid;
  reg                fwd_row_0_rd_en;
  wire        [127:0]bwd_row_0; // one row of 16 pixels, each pixel an 8 bit unsigned reg.
  wire               bwd_row_0_valid;
  reg                bwd_row_0_rd_en;
  wire         [71:0]idct_row_0; // one row of 8 idct coefficients; each idct coefficient a 9 bit signed reg.
  wire               idct_row_0_valid;
  reg                idct_row_0_rd_en;
  wire               write_recon_0;
  wire         [21:0]write_address_0;
  wire               motion_forward_0;
  wire          [2:0]fwd_hor_offset_0;
  wire               fwd_hor_halfpixel_0;
  wire               fwd_ver_halfpixel_0;
  wire               motion_backward_0;
  wire          [2:0]bwd_hor_offset_0;
  wire               bwd_hor_halfpixel_0;
  wire               bwd_ver_halfpixel_0;

  /* next state */

  always @*
    case (state)
                     /* 
                      * If recon_wr_almost_full is low, we're sure there will be enough room in the reconstruction fifo to write the reconstructed pixels and their address,
                      * If recon_wr_almost_full is high, wait until the framestore has written reconstruction write requests already in the queue.
                      *
                      * If dst_valid_0 is low, we have no work to do. Wait.
                      */
      STATE_WAIT:    if (recon_wr_almost_full || ~dst_valid_0) next = STATE_WAIT;
                     /*
		      * If write_recon_0 is high, the reconstructed pixels will be written to write_address_0.
		      * Reconstructing the pixels will need the idct values, hence idct_row_0_valid has to be high. 
		      * If write_recon_0 is low, the reconstructed pixels are thrown away. We just want to load values in prev_fwd_row_0 and prev_bwd_row_0.
		      * As the reconstructed pixels are thrown away, there's no need for idct_row_0_valid to be high.
		      *
		      * If motion_forward_0 is high, we will use forward motion compensation, and fwd_row_0_valid has to be high.
		      *
		      * If motion_backward_0 is high, we will use backward motion compensation, and bwd_row_0_valid has to be high.
		      */
                     else if ((~write_recon_0 || idct_row_0_valid) && (~motion_forward_0 || fwd_row_0_valid) && (~motion_backward_0 || bwd_row_0_valid)) next = STATE_RUN;
		     else next = STATE_WAIT;
      STATE_RUN:     next = STATE_WAIT;
      default        next = STATE_WAIT;
    endcase

  always @(posedge clk)
    if (~rst) state <= STATE_WAIT;
    else if (clk_en) state <= next;
    else state <= state;

  /* fifo read enables */
  always @(posedge clk)
    if (~rst) dst_rd_en <= 1'b0;
    else if (clk_en) dst_rd_en <= (next == STATE_RUN);
    else dst_rd_en <= dst_rd_en;

  always @(posedge clk)
    if (~rst) idct_row_0_rd_en <= 1'b0;
    // If reconstructed pixels are written to the framestore, read next idct values.
    else if (clk_en) idct_row_0_rd_en <= write_recon_0 && (next == STATE_RUN); 
    else idct_row_0_rd_en <= idct_row_0_rd_en;

  always @(posedge clk)
    if (~rst) fwd_row_0_rd_en <= 1'b0;
    // If we used forward motion compensation, read next row of forward motion compensation pixels.
    else if (clk_en) fwd_row_0_rd_en <= motion_forward_0 && (next == STATE_RUN);
    else fwd_row_0_rd_en <= fwd_row_0_rd_en;

  always @(posedge clk)
    if (~rst) bwd_row_0_rd_en <= 1'b0;
    // If we used backward motion compensation, read next row of backward motion compensation pixels.
    else if (clk_en) bwd_row_0_rd_en <= motion_backward_0 && (next == STATE_RUN);
    else bwd_row_0_rd_en <= bwd_row_0_rd_en;

  /* stage 0 */
  assign valid_0 = dst_rd_en;

  fwft_reader #(.dta_width(9'd35)) dst_fwft_reader (
    .rst(rst), 
    .clk(clk), 
    .clk_en(clk_en), 
    .fifo_rd_en(dst_rd_dta_en), 
    .fifo_valid(dst_rd_dta_valid), 
    .fifo_dout(dst_rd_dta), 
    .valid(dst_valid_0), 
    .dout({write_recon_0, write_address_0, motion_forward_0, fwd_hor_offset_0, fwd_hor_halfpixel_0, fwd_ver_halfpixel_0, motion_backward_0, bwd_hor_offset_0, bwd_hor_halfpixel_0, bwd_ver_halfpixel_0}),
    .rd_en(dst_rd_en)
    );

  fwft_reader #(.dta_width(9'd72)) idct_fwft_reader (
    .rst(rst), 
    .clk(clk), 
    .clk_en(clk_en), 
    .fifo_rd_en(idct_rd_dta_en), 
    .fifo_valid(idct_rd_dta_valid), 
    .fifo_dout(idct_rd_dta), 
    .valid(idct_row_0_valid), 
    .dout(idct_row_0), 
    .rd_en(idct_row_0_rd_en)
    );

  fwft2_reader #(.dta_width(9'd64)) fwd_fwft2_reader (
    .rst(rst), 
    .clk(clk), 
    .clk_en(clk_en), 
    .fifo_rd_en(fwd_rd_dta_en), 
    .fifo_valid(fwd_rd_dta_valid), 
    .fifo_dout(fwd_rd_dta), 
    .valid(fwd_row_0_valid), 
    .dout(fwd_row_0), 
    .rd_en(fwd_row_0_rd_en)
    );

  fwft2_reader #(.dta_width(9'd64)) bwd_fwft2_reader (
    .rst(rst), 
    .clk(clk), 
    .clk_en(clk_en), 
    .fifo_rd_en(bwd_rd_dta_en), 
    .fifo_valid(bwd_rd_dta_valid), 
    .fifo_dout(bwd_rd_dta), 
    .valid(bwd_row_0_valid), 
    .dout(bwd_row_0), 
    .rd_en(bwd_row_0_rd_en)
    );

  /* horizontal offset, including horizontal halfpixel */
  wire               valid_2;
  wire               write_recon_2;
  wire         [71:0]idct_row_2;
  wire         [21:0]write_address_2;
  wire               motion_forward_2;
  wire               fwd_hor_halfpixel_2;
  wire               fwd_ver_halfpixel_2;
  wire               motion_backward_2;
  wire               bwd_hor_halfpixel_2;
  wire               bwd_ver_halfpixel_2;

  wire signed   [7:0]fwd_2_pixel_0;
  wire signed   [7:0]fwd_2_pixel_1;
  wire signed   [7:0]fwd_2_pixel_2;
  wire signed   [7:0]fwd_2_pixel_3;
  wire signed   [7:0]fwd_2_pixel_4;
  wire signed   [7:0]fwd_2_pixel_5;
  wire signed   [7:0]fwd_2_pixel_6;
  wire signed   [7:0]fwd_2_pixel_7;
  wire signed   [7:0]fwd_2_pixel_8;

  wire signed   [7:0]bwd_2_pixel_0;
  wire signed   [7:0]bwd_2_pixel_1;
  wire signed   [7:0]bwd_2_pixel_2;
  wire signed   [7:0]bwd_2_pixel_3;
  wire signed   [7:0]bwd_2_pixel_4;
  wire signed   [7:0]bwd_2_pixel_5;
  wire signed   [7:0]bwd_2_pixel_6;
  wire signed   [7:0]bwd_2_pixel_7;
  wire signed   [7:0]bwd_2_pixel_8;

  wire signed   [8:0]idct_2_pixel_0;
  wire signed   [8:0]idct_2_pixel_1;
  wire signed   [8:0]idct_2_pixel_2;
  wire signed   [8:0]idct_2_pixel_3;
  wire signed   [8:0]idct_2_pixel_4;
  wire signed   [8:0]idct_2_pixel_5;
  wire signed   [8:0]idct_2_pixel_6;
  wire signed   [8:0]idct_2_pixel_7;

  assign {idct_2_pixel_0, idct_2_pixel_1, idct_2_pixel_2, idct_2_pixel_3, idct_2_pixel_4, idct_2_pixel_5, idct_2_pixel_6, idct_2_pixel_7} = idct_row_2;

  wire signed   [7:0]prev_fwd_2_pixel_0;
  wire signed   [7:0]prev_fwd_2_pixel_1;
  wire signed   [7:0]prev_fwd_2_pixel_2;
  wire signed   [7:0]prev_fwd_2_pixel_3;
  wire signed   [7:0]prev_fwd_2_pixel_4;
  wire signed   [7:0]prev_fwd_2_pixel_5;
  wire signed   [7:0]prev_fwd_2_pixel_6;
  wire signed   [7:0]prev_fwd_2_pixel_7;
  wire signed   [7:0]prev_fwd_2_pixel_8;

  wire signed   [7:0]prev_bwd_2_pixel_0;
  wire signed   [7:0]prev_bwd_2_pixel_1;
  wire signed   [7:0]prev_bwd_2_pixel_2;
  wire signed   [7:0]prev_bwd_2_pixel_3;
  wire signed   [7:0]prev_bwd_2_pixel_4;
  wire signed   [7:0]prev_bwd_2_pixel_5;
  wire signed   [7:0]prev_bwd_2_pixel_6;
  wire signed   [7:0]prev_bwd_2_pixel_7;
  wire signed   [7:0]prev_bwd_2_pixel_8;

  reg [71:0]prev_fwd_2;

  assign {prev_fwd_2_pixel_0, prev_fwd_2_pixel_1, prev_fwd_2_pixel_2, prev_fwd_2_pixel_3, prev_fwd_2_pixel_4, 
          prev_fwd_2_pixel_5, prev_fwd_2_pixel_6, prev_fwd_2_pixel_7, prev_fwd_2_pixel_8} = prev_fwd_2;

  always @(posedge clk)
    if (~rst) prev_fwd_2 <= 72'b0;
    else if (clk_en && valid_2) prev_fwd_2 <= {fwd_2_pixel_0, fwd_2_pixel_1, fwd_2_pixel_2, fwd_2_pixel_3, fwd_2_pixel_4, fwd_2_pixel_5, fwd_2_pixel_6, fwd_2_pixel_7, fwd_2_pixel_8};
    else prev_fwd_2 <= prev_fwd_2;

  reg [71:0]prev_bwd_2;

  assign {prev_bwd_2_pixel_0, prev_bwd_2_pixel_1, prev_bwd_2_pixel_2, prev_bwd_2_pixel_3, prev_bwd_2_pixel_4, 
          prev_bwd_2_pixel_5, prev_bwd_2_pixel_6, prev_bwd_2_pixel_7, prev_bwd_2_pixel_8} = prev_bwd_2;

  always @(posedge clk)
    if (~rst) prev_bwd_2 <= 72'b0;
    else if (clk_en && valid_2) prev_bwd_2 <= {bwd_2_pixel_0, bwd_2_pixel_1, bwd_2_pixel_2, bwd_2_pixel_3, bwd_2_pixel_4, bwd_2_pixel_5, bwd_2_pixel_6, bwd_2_pixel_7, bwd_2_pixel_8};
    else prev_bwd_2 <= prev_bwd_2;

  prediction_horizontal_offset #(.dta_width(8'd101)) prediction_fwd_row (
    .rst(rst), 
    .clk(clk), 
    .clk_en(clk_en), 
    .valid_in(valid_0),
    .row_in(fwd_row_0),
    .motion_compensation_in(motion_forward_0),
    .hor_offset_in(fwd_hor_offset_0),
    .dta_in({write_recon_0, idct_row_0, write_address_0, motion_forward_0, fwd_hor_halfpixel_0, fwd_ver_halfpixel_0, motion_backward_0, bwd_hor_halfpixel_0, bwd_ver_halfpixel_0}),
    .valid_out(valid_2),
    .pixel_0_out(fwd_2_pixel_0),
    .pixel_1_out(fwd_2_pixel_1),
    .pixel_2_out(fwd_2_pixel_2),
    .pixel_3_out(fwd_2_pixel_3),
    .pixel_4_out(fwd_2_pixel_4),
    .pixel_5_out(fwd_2_pixel_5),
    .pixel_6_out(fwd_2_pixel_6),
    .pixel_7_out(fwd_2_pixel_7),
    .pixel_8_out(fwd_2_pixel_8),
    .dta_out({write_recon_2, idct_row_2, write_address_2, motion_forward_2, fwd_hor_halfpixel_2, fwd_ver_halfpixel_2, motion_backward_2, bwd_hor_halfpixel_2, bwd_ver_halfpixel_2})
    );

  prediction_horizontal_offset #(.dta_width(8'd1)) prediction_bwd_row (
    .rst(rst), 
    .clk(clk), 
    .clk_en(clk_en), 
    .valid_in(valid_0),
    .row_in(bwd_row_0),
    .motion_compensation_in(motion_backward_0),
    .hor_offset_in(bwd_hor_offset_0),
    .dta_in(1'b0),
    .valid_out(),
    .pixel_0_out(bwd_2_pixel_0),
    .pixel_1_out(bwd_2_pixel_1),
    .pixel_2_out(bwd_2_pixel_2),
    .pixel_3_out(bwd_2_pixel_3),
    .pixel_4_out(bwd_2_pixel_4),
    .pixel_5_out(bwd_2_pixel_5),
    .pixel_6_out(bwd_2_pixel_6),
    .pixel_7_out(bwd_2_pixel_7),
    .pixel_8_out(bwd_2_pixel_8),
    .dta_out()
    );

  /* vertical halfpixel, and prediction error */

  wire               valid_out;
  wire               write_recon_out;
  wire         [21:0]write_address_out;
  wire          [7:0]pixel_out_0;
  wire          [7:0]pixel_out_1;
  wire          [7:0]pixel_out_2;
  wire          [7:0]pixel_out_3;
  wire          [7:0]pixel_out_4;
  wire          [7:0]pixel_out_5;
  wire          [7:0]pixel_out_6;
  wire          [7:0]pixel_out_7;

  combine_predictions combine_predictions_0 (
    .rst(rst), 
    .clk(clk), 
    .clk_en(clk_en), 
    .valid_in(valid_2),
    .write_recon_in(write_recon_2),
    .write_address_in(write_address_2),
    .motion_forward_in(motion_forward_2),
    .fwd_hor_halfpixel_in(fwd_hor_halfpixel_2),
    .fwd_ver_halfpixel_in(fwd_ver_halfpixel_2),
    .motion_backward_in(motion_backward_2),
    .bwd_hor_halfpixel_in(bwd_hor_halfpixel_2),
    .bwd_ver_halfpixel_in(bwd_ver_halfpixel_2),
    .fwd_left_pixel_in(fwd_2_pixel_0),
    .fwd_rght_pixel_in(fwd_2_pixel_1),
    .prev_fwd_left_pixel_in(prev_fwd_2_pixel_0),
    .prev_fwd_rght_pixel_in(prev_fwd_2_pixel_1),
    .bwd_left_pixel_in(bwd_2_pixel_0),
    .bwd_rght_pixel_in(bwd_2_pixel_1),
    .prev_bwd_left_pixel_in(prev_bwd_2_pixel_0),
    .prev_bwd_rght_pixel_in(prev_bwd_2_pixel_1),
    .idct_pixel_in(idct_2_pixel_0),
    .valid_out(valid_out),
    .write_recon_out(write_recon_out),
    .write_address_out(write_address_out),
    .pixel_out(pixel_out_0)
    );

  combine_predictions combine_predictions_1 (
    .rst(rst), 
    .clk(clk), 
    .clk_en(clk_en), 
    .valid_in(valid_2),
    .write_recon_in(write_recon_2),
    .write_address_in(write_address_2),
    .motion_forward_in(motion_forward_2),
    .fwd_hor_halfpixel_in(fwd_hor_halfpixel_2),
    .fwd_ver_halfpixel_in(fwd_ver_halfpixel_2),
    .motion_backward_in(motion_backward_2),
    .bwd_hor_halfpixel_in(bwd_hor_halfpixel_2),
    .bwd_ver_halfpixel_in(bwd_ver_halfpixel_2),
    .fwd_left_pixel_in(fwd_2_pixel_1),
    .fwd_rght_pixel_in(fwd_2_pixel_2),
    .prev_fwd_left_pixel_in(prev_fwd_2_pixel_1),
    .prev_fwd_rght_pixel_in(prev_fwd_2_pixel_2),
    .bwd_left_pixel_in(bwd_2_pixel_1),
    .bwd_rght_pixel_in(bwd_2_pixel_2),
    .prev_bwd_left_pixel_in(prev_bwd_2_pixel_1),
    .prev_bwd_rght_pixel_in(prev_bwd_2_pixel_2),
    .idct_pixel_in(idct_2_pixel_1),
    .valid_out(),
    .write_recon_out(),
    .write_address_out(),
    .pixel_out(pixel_out_1)
    );

  combine_predictions combine_predictions_2 (
    .rst(rst), 
    .clk(clk), 
    .clk_en(clk_en), 
    .valid_in(valid_2),
    .write_recon_in(write_recon_2),
    .write_address_in(write_address_2),
    .motion_forward_in(motion_forward_2),
    .fwd_hor_halfpixel_in(fwd_hor_halfpixel_2),
    .fwd_ver_halfpixel_in(fwd_ver_halfpixel_2),
    .motion_backward_in(motion_backward_2),
    .bwd_hor_halfpixel_in(bwd_hor_halfpixel_2),
    .bwd_ver_halfpixel_in(bwd_ver_halfpixel_2),
    .fwd_left_pixel_in(fwd_2_pixel_2),
    .fwd_rght_pixel_in(fwd_2_pixel_3),
    .prev_fwd_left_pixel_in(prev_fwd_2_pixel_2),
    .prev_fwd_rght_pixel_in(prev_fwd_2_pixel_3),
    .bwd_left_pixel_in(bwd_2_pixel_2),
    .bwd_rght_pixel_in(bwd_2_pixel_3),
    .prev_bwd_left_pixel_in(prev_bwd_2_pixel_2),
    .prev_bwd_rght_pixel_in(prev_bwd_2_pixel_3),
    .idct_pixel_in(idct_2_pixel_2),
    .valid_out(),
    .write_recon_out(),
    .write_address_out(),
    .pixel_out(pixel_out_2)
    );

  combine_predictions combine_predictions_3 (
    .rst(rst), 
    .clk(clk), 
    .clk_en(clk_en), 
    .valid_in(valid_2),
    .write_recon_in(write_recon_2),
    .write_address_in(write_address_2),
    .motion_forward_in(motion_forward_2),
    .fwd_hor_halfpixel_in(fwd_hor_halfpixel_2),
    .fwd_ver_halfpixel_in(fwd_ver_halfpixel_2),
    .motion_backward_in(motion_backward_2),
    .bwd_hor_halfpixel_in(bwd_hor_halfpixel_2),
    .bwd_ver_halfpixel_in(bwd_ver_halfpixel_2),
    .fwd_left_pixel_in(fwd_2_pixel_3),
    .fwd_rght_pixel_in(fwd_2_pixel_4),
    .prev_fwd_left_pixel_in(prev_fwd_2_pixel_3),
    .prev_fwd_rght_pixel_in(prev_fwd_2_pixel_4),
    .bwd_left_pixel_in(bwd_2_pixel_3),
    .bwd_rght_pixel_in(bwd_2_pixel_4),
    .prev_bwd_left_pixel_in(prev_bwd_2_pixel_3),
    .prev_bwd_rght_pixel_in(prev_bwd_2_pixel_4),
    .idct_pixel_in(idct_2_pixel_3),
    .valid_out(),
    .write_recon_out(),
    .write_address_out(),
    .pixel_out(pixel_out_3)
    );

  combine_predictions combine_predictions_4 (
    .rst(rst), 
    .clk(clk), 
    .clk_en(clk_en), 
    .valid_in(valid_2),
    .write_recon_in(write_recon_2),
    .write_address_in(write_address_2),
    .motion_forward_in(motion_forward_2),
    .fwd_hor_halfpixel_in(fwd_hor_halfpixel_2),
    .fwd_ver_halfpixel_in(fwd_ver_halfpixel_2),
    .motion_backward_in(motion_backward_2),
    .bwd_hor_halfpixel_in(bwd_hor_halfpixel_2),
    .bwd_ver_halfpixel_in(bwd_ver_halfpixel_2),
    .fwd_left_pixel_in(fwd_2_pixel_4),
    .fwd_rght_pixel_in(fwd_2_pixel_5),
    .prev_fwd_left_pixel_in(prev_fwd_2_pixel_4),
    .prev_fwd_rght_pixel_in(prev_fwd_2_pixel_5),
    .bwd_left_pixel_in(bwd_2_pixel_4),
    .bwd_rght_pixel_in(bwd_2_pixel_5),
    .prev_bwd_left_pixel_in(prev_bwd_2_pixel_4),
    .prev_bwd_rght_pixel_in(prev_bwd_2_pixel_5),
    .idct_pixel_in(idct_2_pixel_4),
    .valid_out(),
    .write_recon_out(),
    .write_address_out(),
    .pixel_out(pixel_out_4)
    );

  combine_predictions combine_predictions_5 (
    .rst(rst), 
    .clk(clk), 
    .clk_en(clk_en), 
    .valid_in(valid_2),
    .write_recon_in(write_recon_2),
    .write_address_in(write_address_2),
    .motion_forward_in(motion_forward_2),
    .fwd_hor_halfpixel_in(fwd_hor_halfpixel_2),
    .fwd_ver_halfpixel_in(fwd_ver_halfpixel_2),
    .motion_backward_in(motion_backward_2),
    .bwd_hor_halfpixel_in(bwd_hor_halfpixel_2),
    .bwd_ver_halfpixel_in(bwd_ver_halfpixel_2),
    .fwd_left_pixel_in(fwd_2_pixel_5),
    .fwd_rght_pixel_in(fwd_2_pixel_6),
    .prev_fwd_left_pixel_in(prev_fwd_2_pixel_5),
    .prev_fwd_rght_pixel_in(prev_fwd_2_pixel_6),
    .bwd_left_pixel_in(bwd_2_pixel_5),
    .bwd_rght_pixel_in(bwd_2_pixel_6),
    .prev_bwd_left_pixel_in(prev_bwd_2_pixel_5),
    .prev_bwd_rght_pixel_in(prev_bwd_2_pixel_6),
    .idct_pixel_in(idct_2_pixel_5),
    .valid_out(),
    .write_recon_out(),
    .write_address_out(),
    .pixel_out(pixel_out_5)
    );

  combine_predictions combine_predictions_6 (
    .rst(rst), 
    .clk(clk), 
    .clk_en(clk_en), 
    .valid_in(valid_2),
    .write_recon_in(write_recon_2),
    .write_address_in(write_address_2),
    .motion_forward_in(motion_forward_2),
    .fwd_hor_halfpixel_in(fwd_hor_halfpixel_2),
    .fwd_ver_halfpixel_in(fwd_ver_halfpixel_2),
    .motion_backward_in(motion_backward_2),
    .bwd_hor_halfpixel_in(bwd_hor_halfpixel_2),
    .bwd_ver_halfpixel_in(bwd_ver_halfpixel_2),
    .fwd_left_pixel_in(fwd_2_pixel_6),
    .fwd_rght_pixel_in(fwd_2_pixel_7),
    .prev_fwd_left_pixel_in(prev_fwd_2_pixel_6),
    .prev_fwd_rght_pixel_in(prev_fwd_2_pixel_7),
    .bwd_left_pixel_in(bwd_2_pixel_6),
    .bwd_rght_pixel_in(bwd_2_pixel_7),
    .prev_bwd_left_pixel_in(prev_bwd_2_pixel_6),
    .prev_bwd_rght_pixel_in(prev_bwd_2_pixel_7),
    .idct_pixel_in(idct_2_pixel_6),
    .valid_out(),
    .write_recon_out(),
    .write_address_out(),
    .pixel_out(pixel_out_6)
    );

  combine_predictions combine_predictions_7 (
    .rst(rst), 
    .clk(clk), 
    .clk_en(clk_en), 
    .valid_in(valid_2),
    .write_recon_in(write_recon_2),
    .write_address_in(write_address_2),
    .motion_forward_in(motion_forward_2),
    .fwd_hor_halfpixel_in(fwd_hor_halfpixel_2),
    .fwd_ver_halfpixel_in(fwd_ver_halfpixel_2),
    .motion_backward_in(motion_backward_2),
    .bwd_hor_halfpixel_in(bwd_hor_halfpixel_2),
    .bwd_ver_halfpixel_in(bwd_ver_halfpixel_2),
    .fwd_left_pixel_in(fwd_2_pixel_7),
    .fwd_rght_pixel_in(fwd_2_pixel_8),
    .prev_fwd_left_pixel_in(prev_fwd_2_pixel_7),
    .prev_fwd_rght_pixel_in(prev_fwd_2_pixel_8),
    .bwd_left_pixel_in(bwd_2_pixel_7),
    .bwd_rght_pixel_in(bwd_2_pixel_8),
    .prev_bwd_left_pixel_in(prev_bwd_2_pixel_7),
    .prev_bwd_rght_pixel_in(prev_bwd_2_pixel_8),
    .idct_pixel_in(idct_2_pixel_7),
    .valid_out(),
    .write_recon_out(),
    .write_address_out(),
    .pixel_out(pixel_out_7)
    );

  always @(posedge clk)
    if (~rst) recon_wr_en <= 1'b0;
    else if (clk_en) recon_wr_en <= write_recon_out && valid_out;
    else recon_wr_en <= recon_wr_en;

  always @(posedge clk)
    if (~rst) recon_wr_addr <= 22'b0;
    else if (clk_en && valid_out) recon_wr_addr <= write_address_out;
    else recon_wr_addr <= recon_wr_addr;

  always @(posedge clk)
    if (~rst) recon_wr_dta <= 64'b0;
    else if (clk_en && valid_out) recon_wr_dta <= {pixel_out_0, pixel_out_1, pixel_out_2, pixel_out_3, pixel_out_4, pixel_out_5, pixel_out_6, pixel_out_7};
    else recon_wr_dta <= recon_wr_dta;

`ifdef DEBUG
   always @(posedge clk)
     if (clk_en) 
       begin
         $strobe("%m\tvalid_0: %h  write_recon_0: %h  write_address_0: %h",
                  valid_0, write_recon_0, write_address_0);
	 $strobe("%m\tmotion_forward_0: %h  fwd_hor_offset_0: %h  fwd_hor_halfpixel_0: %h  fwd_ver_halfpixel_0: %h",
	          motion_forward_0, fwd_hor_offset_0, fwd_hor_halfpixel_0, fwd_ver_halfpixel_0);
	 $strobe("%m\tmotion_backward_0: %h  bwd_hor_offset_0: %h  bwd_hor_halfpixel_0: %h  bwd_ver_halfpixel_0: %h",
	          motion_backward_0, bwd_hor_offset_0, bwd_hor_halfpixel_0, bwd_ver_halfpixel_0);
	 $strobe("%m\tfwd_row_0_valid: %h  fwd_row_0: %h",
	          fwd_row_0_valid, fwd_row_0);
	 $strobe("%m\tbwd_row_0_valid: %h  bwd_row_0: %h",
	          bwd_row_0_valid, bwd_row_0);
	 $strobe("%m\tidct_row_0: %h  idct_row_0_valid: %h",
	          idct_row_0, idct_row_0_valid);

         $strobe("%m\trecon_wr_en: %h recon_wr_addr: %h recon_wr_dta: %h", 
	              recon_wr_en, recon_wr_addr, recon_wr_dta);
       end
`endif

endmodule

module prediction_horizontal_offset (rst, clk, clk_en, 
  valid_in, row_in, motion_compensation_in, hor_offset_in, dta_in, 
  valid_out, pixel_0_out, pixel_1_out, pixel_2_out, pixel_3_out, pixel_4_out, pixel_5_out, pixel_6_out, pixel_7_out, pixel_8_out, dta_out);

  parameter [8:0]dta_width=9'd8;

  input              clk;                      // clock
  input              clk_en;                   // clock enable
  input              rst;                      // synchronous active low reset
  input              valid_in;
  input       [127:0]row_in;                   // one row of 16 pixels, each pixel an 8 bit unsigned reg.
  input              motion_compensation_in;
  input         [2:0]hor_offset_in;
  input [dta_width-1:0]dta_in;
  output reg         valid_out;
  output signed [7:0]pixel_0_out;
  output signed [7:0]pixel_1_out;
  output signed [7:0]pixel_2_out;
  output signed [7:0]pixel_3_out;
  output signed [7:0]pixel_4_out;
  output signed [7:0]pixel_5_out;
  output signed [7:0]pixel_6_out;
  output signed [7:0]pixel_7_out;
  output signed [7:0]pixel_8_out;
  output reg [dta_width-1:0]dta_out;

  /* stage 1 */
  reg                valid_1;
  reg         [127:0]row_1;
  reg           [2:0]hor_offset_1;
  reg [dta_width-1:0]dta_1;

  always @(posedge clk)
    if (~rst) valid_1 <= 1'b0;
    else if (clk_en) valid_1 <= valid_in;
    else valid_1 <= valid_1;

  always @(posedge clk)
    if (~rst) row_1 <= 128'b0;
    else if (clk_en && motion_compensation_in) row_1 <= row_in;
    else if (clk_en) row_1 <= 128'b0;
    else row_1 <= row_1;

  always @(posedge clk)
    if (~rst) hor_offset_1 <= 3'd0;
    else if (clk_en && motion_compensation_in) hor_offset_1 <= hor_offset_in;
    else if (clk_en) hor_offset_1 <= 3'd0;
    else hor_offset_1 <= hor_offset_1;

  always @(posedge clk)
    if (~rst) dta_1 <= 1'b0;
    else if (clk_en) dta_1 <= dta_in;
    else dta_1 <= dta_1;

  /* stage 2 */
  reg          [71:0]row_2;

  always @(posedge clk)
    if (~rst) valid_out <= 1'b0;
    else if (clk_en) valid_out <= valid_1;
    else valid_out <= valid_out;

  /* shift by horizontal offset */
  always @(posedge clk)
    if (~rst) row_2 <= 72'b0;
    else if (clk_en)
      case (hor_offset_1)
        3'd0: row_2 <= row_1[127:56];
        3'd1: row_2 <= row_1[119:48];
        3'd2: row_2 <= row_1[111:40];
        3'd3: row_2 <= row_1[103:32];
        3'd4: row_2 <= row_1[95:24];
        3'd5: row_2 <= row_1[87:16];
        3'd6: row_2 <= row_1[79:8];
        3'd7: row_2 <= row_1[71:0];
      endcase
    else row_2 <= row_2;

  always @(posedge clk)
    if (~rst) dta_out <= 1'b0;
    else if (clk_en) dta_out <= dta_1;
    else dta_out <= dta_out;

  /* individual pixels within the row */
  assign pixel_0_out = row_2[71:64];
  assign pixel_1_out = row_2[63:56];
  assign pixel_2_out = row_2[55:48];
  assign pixel_3_out = row_2[47:40];
  assign pixel_4_out = row_2[39:32];
  assign pixel_5_out = row_2[31:24];
  assign pixel_6_out = row_2[23:16];
  assign pixel_7_out = row_2[15:8];
  assign pixel_8_out = row_2[7:0];

endmodule

module combine_predictions (rst, clk, clk_en,
  valid_in, write_recon_in, write_address_in, fwd_hor_halfpixel_in, fwd_ver_halfpixel_in, bwd_hor_halfpixel_in, bwd_ver_halfpixel_in, 
  motion_forward_in, fwd_left_pixel_in, fwd_rght_pixel_in, prev_fwd_left_pixel_in, prev_fwd_rght_pixel_in, 
  motion_backward_in, bwd_left_pixel_in, bwd_rght_pixel_in, prev_bwd_left_pixel_in, prev_bwd_rght_pixel_in, 
  idct_pixel_in, 
  valid_out, write_recon_out, write_address_out, pixel_out);

  input              clk;                      // clock
  input              clk_en;                   // clock enable
  input              rst;                      // synchronous active low reset
  input              valid_in;
  input              write_recon_in;
  input        [21:0]write_address_in;
  input              fwd_hor_halfpixel_in;
  input              fwd_ver_halfpixel_in;
  input              bwd_hor_halfpixel_in;
  input              bwd_ver_halfpixel_in;
  input              motion_forward_in;
  input signed  [7:0]fwd_left_pixel_in;
  input signed  [7:0]fwd_rght_pixel_in;
  input signed  [7:0]prev_fwd_left_pixel_in;
  input signed  [7:0]prev_fwd_rght_pixel_in;
  input              motion_backward_in;
  input signed  [7:0]bwd_left_pixel_in;
  input signed  [7:0]bwd_rght_pixel_in;
  input signed  [7:0]prev_bwd_left_pixel_in;
  input signed  [7:0]prev_bwd_rght_pixel_in;
  input signed  [8:0]idct_pixel_in;
  output reg         valid_out;
  output reg         write_recon_out;
  output reg   [21:0]write_address_out;
  output reg signed [7:0]pixel_out;

  /* stage 1 */
  wire               valid_4;
  wire               write_recon_4;
  wire         [21:0]write_address_4;
  wire               motion_forward_4;
  wire               motion_backward_4;
  wire signed   [8:0]idct_pixel_4;
  wire signed   [9:0]fwd_prediction_pixel_4;
  wire signed   [9:0]bwd_prediction_pixel_4;

  pixel_prediction #(.dta_width(8'd35)) forward_prediction (
    .rst(rst), 
    .clk(clk), 
    .clk_en(clk_en), 
    .dta_in({valid_in, write_recon_in, write_address_in, motion_forward_in, motion_backward_in, idct_pixel_in}),
    .hor_halfpixel_in(fwd_hor_halfpixel_in),
    .ver_halfpixel_in(fwd_ver_halfpixel_in),
    .left_pixel_in(fwd_left_pixel_in),
    .rght_pixel_in(fwd_rght_pixel_in),
    .prev_left_pixel_in(prev_fwd_left_pixel_in),
    .prev_rght_pixel_in(prev_fwd_rght_pixel_in),
    .pixel_out(fwd_prediction_pixel_4),
    .dta_out({valid_4, write_recon_4, write_address_4, motion_forward_4, motion_backward_4, idct_pixel_4})
    );

  pixel_prediction #(.dta_width(8'd1)) backward_prediction (
    .rst(rst), 
    .clk(clk), 
    .clk_en(clk_en), 
    .dta_in(1'b0),
    .hor_halfpixel_in(bwd_hor_halfpixel_in),
    .ver_halfpixel_in(bwd_ver_halfpixel_in),
    .left_pixel_in(bwd_left_pixel_in),
    .rght_pixel_in(bwd_rght_pixel_in),
    .prev_left_pixel_in(prev_bwd_left_pixel_in),
    .prev_rght_pixel_in(prev_bwd_rght_pixel_in),
    .pixel_out(bwd_prediction_pixel_4),
    .dta_out()
    );

  /* stage 5*/

  reg                valid_5;
  reg                write_recon_5;
  reg          [21:0]write_address_5;
  reg                motion_forward_5;
  reg                motion_backward_5;
  reg signed    [9:0]idct_pixel_5;
  reg signed    [9:0]fwd_prediction_pixel_5;
  reg signed    [9:0]bwd_prediction_pixel_5;
  reg signed    [9:0]fwd_bwd_prediction_pixel_5;
  wire signed   [9:0]fwd_bwd_prediction_pixel_round_5 = {9'b0, ~fwd_bwd_prediction_pixel_5[9]};

  always @(posedge clk)
    if (~rst) {valid_5, write_recon_5, write_address_5, motion_forward_5 ,motion_backward_5, fwd_prediction_pixel_5, bwd_prediction_pixel_5} <= 1'b0;
    else if (clk_en) {valid_5, write_recon_5, write_address_5, motion_forward_5 ,motion_backward_5, fwd_prediction_pixel_5, bwd_prediction_pixel_5} <= {valid_4, write_recon_4, write_address_4, motion_forward_4 ,motion_backward_4, fwd_prediction_pixel_4, bwd_prediction_pixel_4};
    else {valid_5, write_recon_5, write_address_5, motion_forward_5 ,motion_backward_5, fwd_prediction_pixel_5, bwd_prediction_pixel_5} <= {valid_5, write_recon_5, write_address_5, motion_forward_5 ,motion_backward_5, fwd_prediction_pixel_5, bwd_prediction_pixel_5};

  always @(posedge clk)
    if (~rst) idct_pixel_5 <= 10'sd0;
    else if (clk_en && write_recon_5) idct_pixel_5 <= {idct_pixel_4[8], idct_pixel_4};
    else if (clk_en) idct_pixel_5 <= 10'sd0;
    else idct_pixel_5 <= idct_pixel_5;

  always @(posedge clk)
    if (~rst) fwd_bwd_prediction_pixel_5 <= 10'sd0;
    else if (clk_en) fwd_bwd_prediction_pixel_5 <= fwd_prediction_pixel_4 + bwd_prediction_pixel_4;
    else fwd_bwd_prediction_pixel_5 <= fwd_bwd_prediction_pixel_5;

  /* stage 6 */

  reg                valid_6;
  reg                write_recon_6;
  reg          [21:0]write_address_6;
  reg signed    [9:0]idct_pixel_6;
  reg signed    [9:0]prediction_pixel_6;

  always @(posedge clk)
    if (~rst) {valid_6, write_recon_6, write_address_6, idct_pixel_6} <= 1'b0;
    else if (clk_en) {valid_6, write_recon_6, write_address_6, idct_pixel_6} <= {valid_5, write_recon_5, write_address_5, idct_pixel_5};
    else {valid_6, write_recon_6, write_address_6, idct_pixel_6} <= {valid_6, write_recon_6, write_address_6, idct_pixel_6};

  always @(posedge clk)
    if (~rst) prediction_pixel_6 <= 10'sd0;
    else if (clk_en)
      case ({motion_forward_5, motion_backward_5})
        2'b00:   prediction_pixel_6 <= 10'sd0;
	2'b01:   prediction_pixel_6 <= bwd_prediction_pixel_5;
	2'b10:   prediction_pixel_6 <= fwd_prediction_pixel_5;
	2'b11:   prediction_pixel_6 <= (fwd_bwd_prediction_pixel_5 + fwd_bwd_prediction_pixel_round_5) >>> 1;
	default  prediction_pixel_6 <= 10'sd0;
      endcase
    else prediction_pixel_6 <= prediction_pixel_6;

  /* stage 7 */

  reg                valid_7;
  reg                write_recon_7;
  reg          [21:0]write_address_7;
  reg signed    [9:0]pixel_7;

  always @(posedge clk)
    if (~rst) {valid_7, write_recon_7, write_address_7} <= 1'b0;
    else if (clk_en) {valid_7, write_recon_7, write_address_7} <= {valid_6, write_recon_6, write_address_6};
    else {valid_7, write_recon_7, write_address_7} <= {valid_7, write_recon_7, write_address_7};

  always @(posedge clk)
    if (~rst) pixel_7 <= 10'sd0;
    else if (clk_en) pixel_7 <= idct_pixel_6 + prediction_pixel_6;
    else pixel_7 <= pixel_7;

  /* stage 8 */

  always @(posedge clk)
    if (~rst) valid_out <= 1'b0;
    else if (clk_en) valid_out <= valid_7;
    else valid_out <= valid_out;

  always @(posedge clk)
    if (~rst) write_recon_out <= 1'b0;
    else if (clk_en) write_recon_out <= write_recon_7;
    else write_recon_out <= write_recon_out;

  always @(posedge clk)
    if (~rst) write_address_out <= 22'd0;
    else if (clk_en) write_address_out <= write_address_7;
    else write_address_out <= write_address_out;

  always @(posedge clk)
    if (~rst) pixel_out <= 8'b0;
    else if (clk_en && ((pixel_7[9:7] == 3'b000) || (pixel_7[9:7] == 3'b111))) pixel_out <= pixel_7[7:0]; /* between -128 and 127, copy */
    else if (clk_en) pixel_out <= {pixel_7[9], {7{~pixel_7[9]}}}; /* clip to -128 if negative, to 127 if positive */
    else pixel_out <= pixel_out;

`ifdef DEBUG
   always @(posedge clk)
     if (clk_en) 
       begin
         $strobe("%m\tvalid_5: %h write_recon_5: %h write_address_5: %h idct_pixel_5: %d fwd_prediction_pixel_5: %d bwd_prediction_pixel_5: %d", valid_5, write_recon_5, write_address_5, idct_pixel_5, fwd_prediction_pixel_5, bwd_prediction_pixel_5);
         $strobe("%m\tvalid_6: %h write_recon_6: %h write_address_6: %h idct_pixel_6: %d prediction_pixel_6: %d", valid_6, write_recon_6, write_address_6, idct_pixel_6, prediction_pixel_6);
         $strobe("%m\tvalid_7: %h write_recon_7: %h write_address_7: %h pixel_7: %d", valid_7, write_recon_7, write_address_7, pixel_7);
         $strobe("%m\tvalid_out: %h write_recon_out: %h write_address_out: %h pixel_out: %d", valid_out, write_recon_out, write_address_out, pixel_out);
       end 
`endif

endmodule

module pixel_prediction (rst, clk, clk_en, dta_in,
  hor_halfpixel_in, ver_halfpixel_in, left_pixel_in, rght_pixel_in, prev_left_pixel_in, prev_rght_pixel_in,
  pixel_out, dta_out);

  parameter [8:0]dta_width=9'd8;

  input              clk;                      // clock
  input              clk_en;                   // clock enable
  input              rst;                      // synchronous active low reset
  input [dta_width-1:0]dta_in;
  input              hor_halfpixel_in;
  input              ver_halfpixel_in;
  input signed  [7:0]left_pixel_in;
  input signed  [7:0]rght_pixel_in;
  input signed  [7:0]prev_left_pixel_in;
  input signed  [7:0]prev_rght_pixel_in;
  output reg signed [9:0]pixel_out;
  output reg [dta_width-1:0]dta_out;

  /* stage 1 */
  reg [dta_width-1:0]dta_1;
  reg               hor_halfpixel_1;
  reg               ver_halfpixel_1;
  reg signed   [9:0]prev_left_pixel_in_1;
  reg signed   [9:0]sum_prev_left_prev_right_1;
  reg signed   [9:0]sum_left_prev_left_1;
  reg signed   [9:0]sum_right_prev_right_1;

  wire signed [9:0]left_pixel_in_ext      = {left_pixel_in[7], left_pixel_in[7], left_pixel_in};
  wire signed [9:0]rght_pixel_in_ext      = {rght_pixel_in[7], rght_pixel_in[7], rght_pixel_in};
  wire signed [9:0]prev_left_pixel_in_ext = {prev_left_pixel_in[7], prev_left_pixel_in[7], prev_left_pixel_in};
  wire signed [9:0]prev_rght_pixel_in_ext = {prev_rght_pixel_in[7], prev_rght_pixel_in[7], prev_rght_pixel_in};

  always @(posedge clk)
    if (~rst) dta_1 <= 1'b0;
    else if (clk_en) dta_1 <= dta_in;
    else dta_1 <= dta_1;

  always @(posedge clk)
    if (~rst) hor_halfpixel_1 <= 1'b0;
    else if (clk_en) hor_halfpixel_1 <= hor_halfpixel_in;
    else hor_halfpixel_1 <= hor_halfpixel_1;

  always @(posedge clk)
    if (~rst) ver_halfpixel_1 <= 1'b0;
    else if (clk_en) ver_halfpixel_1 <= ver_halfpixel_in;
    else ver_halfpixel_1 <= ver_halfpixel_1;

  always @(posedge clk)
    if (~rst) prev_left_pixel_in_1 <= 1'b0;
    else if (clk_en) prev_left_pixel_in_1 <= prev_left_pixel_in_ext;
    else prev_left_pixel_in_1 <= prev_left_pixel_in_1;

  always @(posedge clk)
    if (~rst) sum_prev_left_prev_right_1 <= 10'sd0;
    else if (clk_en) sum_prev_left_prev_right_1 <= prev_left_pixel_in_ext + prev_rght_pixel_in_ext + 10'sd1;
    else sum_prev_left_prev_right_1 <= sum_prev_left_prev_right_1;

  always @(posedge clk)
    if (~rst) sum_left_prev_left_1 <= 10'sd0;
    else if (clk_en) sum_left_prev_left_1 <= left_pixel_in_ext + prev_left_pixel_in_ext + 10'sd1;
    else sum_left_prev_left_1 <= sum_left_prev_left_1;

  always @(posedge clk)
    if (~rst) sum_right_prev_right_1 <= 10'sd0;
    else if (clk_en) sum_right_prev_right_1 <= rght_pixel_in_ext + prev_rght_pixel_in_ext + 10'sd1;
    else sum_right_prev_right_1 <= sum_right_prev_right_1;

  /* stage 2 */

  always @(posedge clk)
    if (~rst) dta_out <= 1'b0;
    else if (clk_en) dta_out <= dta_1;
    else dta_out <= dta_out;

  always @(posedge clk)
    if (~rst) pixel_out <= 10'sd0;
    else if (clk_en)
      case ({hor_halfpixel_1, ver_halfpixel_1})
        2'b00:  pixel_out <= prev_left_pixel_in_1;
	2'b01:  pixel_out <= sum_left_prev_left_1 >>> 1;
	2'b10:  pixel_out <= sum_prev_left_prev_right_1 >>> 1;
	2'b11:  pixel_out <= (sum_left_prev_left_1 + sum_right_prev_right_1) >>> 2;
	default pixel_out <= prev_left_pixel_in_1;
      endcase
    else pixel_out <= pixel_out;

`ifdef DEBUG
   always @(posedge clk)
     if (clk_en) 
       $strobe("%m\tpixel_out: %d", pixel_out);
`endif

endmodule
/* not truncated */
