/*
 * mem_addr.v
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
 * Memory address generation.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

 /*
  Calculates resulting memory address. Assumes 4:2:0 format. Coordinate origin is at top left.
  x axis is from left to right; y axis is from top to bottom.

    +------> x
    |
    |
    |
    v y

  - mv_x and mv_y are signed quantities, and will be scaled by 2 if chrominance addresses are computed.
  - delta_x and delta_y are unsigned, and will not be scaled if chrominance addresses are computed.
  - field_in_frame is asserted if a coordinates of a field-encoded frame picture are to be computed.

  Output:
  - address of 8-pixel 64-bit word.
  - offset_x: offset in bytes into the 8-pixel 64-bit word.
    If offset_x is 0, pixel is the leftmost byte of the 64-bit word. If offset_x is 7, pixel is the rightmost byte in the 64-bit word.
  - halfpixel_x: if set, horizontal halfpixel interpolation is needed.
  - halfpixel_y: if set, vertical halfpixel interpolation is needed.
  */

  /*
   * Note: par. 7.6.3.8, Semantic restrictions concerning predictions: (restricted slice structure)
   * "it is a restriction on the bitstream that reconstructed motion vectors shall not
   * refer to samples outside the boundary of the coded picture."
   */

module memory_address (
  clk, clk_en, rst,
  frame, frame_picture, field_in_frame, field, component, mb_width, horizontal_size, vertical_size,  macroblock_address, delta_x, delta_y, mv_x, mv_y, dta_in, valid_in,
  address, offset_x, halfpixel_x, halfpixel_y, dta_out, valid_out
  );

parameter dta_width=64;                        // dta_in, dta_out width

  input              clk;                      // clock
  input              clk_en;                   // clock enable
  input              rst;                      // synchronous active low reset
  input         [2:0]frame;                    // e.g. forward_reference_frame, backward_reference_frame, aux_frame, current_frame.
  input              frame_picture;            // assert if frame picture.
  input              field_in_frame;           // assert if accessing a field within a frame picture.
  input              field;                    // field number; 0 is top field, 1 is bottom field. Used in field pictures, or when accessing a field within a frame picture.
  input         [1:0]component;                // Luminance or chrominance. One of COMP_Y, COMP_CR, COMP_CB.
  input         [7:0]mb_width;                 // par. 6.3.3. width of the encoded luminance component of pictures in macroblocks
  input        [13:0]horizontal_size;          // par. 6.3.3. width of the displayable part of the luminance component of pictures in samples.
  input        [13:0]vertical_size;            // par. 6.3.3. height of the displayable part of the luminance component of the frame in lines.
  input        [12:0]macroblock_address;       // absolute position of the current macroblock. top-left macroblock has macroblock_address zero.
  input signed [12:0]delta_x;                  // horizontal offset, positive, in pixels.
  input signed [12:0]delta_y;                  // vertical offset, positive, in pixels.
  input signed [12:0]mv_x;                     // motion vector, horizontal component, signed, in halfpixels.
  input signed [12:0]mv_y;                     // motion vector, horizontal component, signed, in halfpixels.
  input [dta_width-1:0]dta_in;                 // data in
  input              valid_in;

  output reg   [21:0]address;                  // memory address of the 8-pixel block row.
  output reg    [2:0]offset_x;                 // Determines pixel offset within the 8-pixel block row. 0..7, 0 = leftmost pixel, msb; 7 = rightmost pixel, lsb.
  output reg         halfpixel_x;              // horizontal halfpixel offset. least significant bit of mv_x.
  output reg         halfpixel_y;              // vertical halfpixel offset. least significant bit of mv_x.
  output reg [dta_width-1:0]dta_out;           // data out is dta_in delayed so as to balance the delay in calculating address
  output reg         valid_out;

`include "vld_codes.v"
`include "mem_codes.v"

  /*
   * stage 0
   * - calculate macroblock (x, y) coordinates
   * - scale motion vectors
   */

  reg           [2:0]frame_0;
  reg                frame_picture_0;
  reg                field_in_frame_0;
  reg                field_0;
  reg           [1:0]component_0;
  reg           [7:0]mb_width_0;
  reg          [13:0]horizontal_size_0;
  reg          [13:0]vertical_size_0;
  reg signed   [12:0]delta_x_0;
  reg signed   [12:0]delta_y_0;
  reg signed   [12:0]mv_x_0;
  reg signed   [12:0]mv_y_0;
  reg signed   [12:0]mv_x_corr_0;
  reg signed   [12:0]mv_y_corr_0;
  reg           [7:0]macroblock_x_0; // current x-position, in macroblocks
  reg           [7:0]macroblock_y_0; // current y-position, in macroblocks
  reg [dta_width-1:0]dta_0;
  reg                valid_0;
  reg                error_0;

  /*
   * Macroblock (x, y) coordinate calculation assumes macroblock address
   * - starts at zero
   * - either stays the same, increments by one or is reset to zero.
   * Other combinations - eg. incrementing by two - are in error.
   */

  reg          [12:0]previous_macroblock_address;

  always @(posedge clk)
    if (~rst) previous_macroblock_address <= 13'd0;
    else if (clk_en) previous_macroblock_address <= macroblock_address;
    else previous_macroblock_address <= previous_macroblock_address;

  always @(posedge clk)
    if (~rst)
      begin
        macroblock_x_0 <= 8'd0;
        macroblock_y_0 <= 8'd0;
        error_0        <= 1'b1; // macroblock coordinates are unknown at reset
      end
    else if (clk_en && (macroblock_address == 13'd0))
      begin
        macroblock_x_0 <= 8'd0;
        macroblock_y_0 <= 8'd0;
        error_0        <= 1'b0; // coordinates of macroblock 0 are known
      end
    else if (clk_en && (macroblock_address == previous_macroblock_address))
      begin
        macroblock_x_0 <= macroblock_x_0;
        macroblock_y_0 <= macroblock_y_0;
        error_0        <= error_0;
      end
    else if (clk_en && (macroblock_address == (previous_macroblock_address + 13'd1)) && ((macroblock_x_0 + 8'd1) == mb_width))
      begin
        macroblock_x_0 <= 8'd0;
        macroblock_y_0 <= macroblock_y_0 + 8'd1;
        error_0        <= error_0;
      end
    else if (clk_en && (macroblock_address == (previous_macroblock_address + 13'd1)))
      begin
        macroblock_x_0 <= macroblock_x_0 + 8'd1;
        macroblock_y_0 <= macroblock_y_0;
        error_0        <= error_0;
      end
    else if (clk_en) // neither resets, nor stays the same, nor increments by one: assert error
      begin
        macroblock_x_0 <= macroblock_x_0;
        macroblock_y_0 <= macroblock_y_0;
        error_0        <= 1'b1;
      end
    else
      begin
        macroblock_x_0 <= macroblock_x_0;
        macroblock_y_0 <= macroblock_y_0;
        error_0        <= error_0;
      end

  /*
   *
   * - Motion vector scaling: divide motion vectors by two for chrominance macroblocks. par. 7.6.3.7 Motion vectors for chrominance components.
   *   Division by two is evaluated as a/2 = ( a + signbit(a))>>> 1;
   *   part1: set up signbit registers.
   */

  always @(posedge clk)
    if (~rst)
      begin
        mv_x_corr_0   <= 12'd0;
        mv_y_corr_0   <= 12'd0;
      end
    else if (clk_en)
      begin
        mv_x_corr_0   <= {11'b0, mv_x[12]};
        mv_y_corr_0   <= {11'b0, mv_y[12]};
      end
    else
      begin
        mv_x_corr_0   <= mv_x_corr_0;
        mv_y_corr_0   <= mv_y_corr_0;
     end

  /*
   * Pass on other registers
   */

  always @(posedge clk)
    if (~rst)
      begin
        frame_0          <= 3'b0;
        frame_picture_0  <= 1'b0;
        field_in_frame_0 <= 1'b0;
        field_0          <= 1'b0;
        component_0      <= 2'b0;
        mb_width_0       <= 8'd0;
        horizontal_size_0<= 14'd0;
        vertical_size_0  <= 14'd0;
        delta_x_0        <= 13'sd0;
        delta_y_0        <= 13'sd0;
        mv_x_0           <= 13'sd0;
        mv_y_0           <= 13'sd0;
        dta_0            <= {dta_width{1'b0}};
        valid_0          <= 1'b0;
      end
    else if (clk_en)
      begin
        frame_0          <= frame;
        frame_picture_0  <= frame_picture;
        field_in_frame_0 <= field_in_frame;
        field_0          <= field;
        component_0      <= component;
        mb_width_0       <= mb_width;
        horizontal_size_0<= horizontal_size;
        vertical_size_0  <= vertical_size;
        delta_x_0        <= delta_x;
        delta_y_0        <= delta_y;
        mv_x_0           <= mv_x;
        mv_y_0           <= mv_y;
        dta_0            <= dta_in;
        valid_0          <= valid_in;
      end
    else
      begin
        frame_0          <= frame_0;
        frame_picture_0  <= frame_picture_0;
        field_in_frame_0 <= field_in_frame_0;
        field_0          <= field_0;
        component_0      <= component_0;
        mb_width_0       <= mb_width_0;
        horizontal_size_0<= horizontal_size_0;
        vertical_size_0  <= vertical_size_0;
        delta_x_0        <= delta_x_0;
        delta_y_0        <= delta_y_0;
        mv_x_0           <= mv_x_0;
        mv_y_0           <= mv_y_0;
        dta_0            <= dta_0;
        valid_0          <= valid_0;
      end

  /*
   * Stage 1
   * - Motion vector scaling, part2: Apply motion vector correction and shift
   * - Calculate macroblock (x, y) coordinates in pixels
   */

  reg           [2:0]frame_1;
  reg                frame_picture_1;
  reg                field_in_frame_1;
  reg                field_1;
  reg           [1:0]component_1;
  reg           [7:0]mb_width_1;
  reg          [13:0]horizontal_size_1;
  reg          [13:0]vertical_size_1;
  reg signed   [12:0]delta_x_1;
  reg signed   [12:0]delta_y_1;
  reg signed   [12:0]mv_x_1;
  reg signed   [12:0]mv_y_1;
  reg signed   [12:0]pixel_x_1;
  reg signed   [12:0]pixel_y_1;
  reg [dta_width-1:0]dta_1;
  reg                valid_1;
  reg                error_1;

  always @(posedge clk)
    if (~rst)
      begin
        mv_x_1        <= 12'd0;
        mv_y_1        <= 12'd0;
      end
    else if ((clk_en) && (component_0 == COMP_Y)) /* luminance */
      begin
        mv_x_1        <= mv_x_0;
        mv_y_1        <= mv_y_0;
      end
    else if (clk_en) /* chrominance */
      begin
        mv_x_1        <= (mv_x_0 + mv_x_corr_0) >>> 1;
        mv_y_1        <= (mv_y_0 + mv_y_corr_0) >>> 1;
      end
    else
      begin
        mv_x_1        <= mv_x_1;
        mv_y_1        <= mv_y_1;
      end

  /*
   * Calculate macroblock (x, y) coordinates in pixels
   */

  always @(posedge clk)
    if (~rst)
      begin
        pixel_x_1     <= 12'sd0;
        pixel_y_1     <= 12'sd0;
      end
    else if ((clk_en) && (component_0 == COMP_Y)) /* luminance: 16x16 pixels/macroblock */
      begin
        pixel_x_1     <= macroblock_x_0 <<< 4 ;
        pixel_y_1     <= macroblock_y_0 <<< 4;
      end
    else if (clk_en) /* 4:2:0 chrominance: 8x8 pixels/macroblock*/
      begin
        pixel_x_1     <= macroblock_x_0 <<< 3 ;
        pixel_y_1     <= macroblock_y_0 <<< 3;
      end
    else
      begin
        pixel_x_1     <= pixel_x_1;
        pixel_y_1     <= pixel_y_1;
      end

  /*
   * Pass on other registers
   */

  always @(posedge clk)
    if (~rst)
      begin
        frame_1          <= 3'b0;
        frame_picture_1  <= 1'b0;
        field_in_frame_1 <= 1'b0;
        field_1          <= 1'b0;
        component_1      <= 2'b0;
        mb_width_1       <= 8'd0;
        horizontal_size_1<= 14'd0;
        vertical_size_1  <= 14'd0;
        delta_x_1        <= 12'sd0;
        delta_y_1        <= 12'sd0;
        dta_1            <= {dta_width{1'b0}};
        valid_1          <= 1'b0;
        error_1          <= 1'b0;
      end
    else if (clk_en)
      begin
        frame_1          <= frame_0;
        frame_picture_1  <= frame_picture_0;
        field_in_frame_1 <= field_in_frame_0;
        field_1          <= field_0;
        component_1      <= component_0;
        mb_width_1       <= mb_width_0;
        horizontal_size_1<= horizontal_size_0;
        vertical_size_1  <= vertical_size_0;
        delta_x_1        <= delta_x_0;
        delta_y_1        <= delta_y_0;
        dta_1            <= dta_0;
        valid_1          <= valid_0;
        error_1          <= error_0;
      end
    else
      begin
        frame_1          <= frame_1;
        frame_picture_1  <= frame_picture_1;
        field_in_frame_1 <= field_in_frame_1;
        field_1          <= field_1;
        component_1      <= component_1;
        mb_width_1       <= mb_width_1;
        horizontal_size_1<= horizontal_size_1;
        vertical_size_1  <= vertical_size_1;
        delta_x_1        <= delta_x_1;
        delta_y_1        <= delta_y_1;
        dta_1            <= dta_1;
        valid_1          <= valid_1;
        error_1          <= error_1;
      end

  /*
   * Stage 2
   * - Motion vector scaling: split motion vector in pixel and halfpixel components.
   */

  reg           [2:0]frame_2;
  reg                frame_picture_2;
  reg                field_in_frame_2;
  reg                field_2;
  reg           [1:0]component_2;
  reg           [7:0]mb_width_2;
  reg          [13:0]horizontal_size_2;
  reg          [13:0]vertical_size_2;
  reg signed   [12:0]delta_x_2;
  reg signed   [12:0]delta_y_2;
  reg signed   [12:0]mv_x_2;
  reg signed   [12:0]mv_y_2;
  reg signed   [12:0]pixel_x_2;
  reg signed   [12:0]pixel_y_2;
  reg                halfpixel_x_2;
  reg                halfpixel_y_2;
  reg [dta_width-1:0]dta_2;
  reg                valid_2;
  reg                error_2;

  always @(posedge clk)
    if (~rst)
      begin
        mv_x_2        <= 12'sd0;
        halfpixel_x_2 <= 1'd0;
        mv_y_2        <= 12'sd0;
        halfpixel_y_2 <= 1'd0;
      end
    else if (clk_en)
      begin
        mv_x_2        <= {mv_x_1[12], mv_x_1[12:1]};
        halfpixel_x_2 <= mv_x_1[0];
        mv_y_2        <= {mv_y_1[12], mv_y_1[12:1]};
        halfpixel_y_2 <= mv_y_1[0];
      end
    else
      begin
        mv_x_2        <= mv_x_2;
        halfpixel_x_2 <= halfpixel_x_2;
        mv_y_2        <= mv_y_2;
        halfpixel_y_2 <= halfpixel_y_2;
      end

  /*
   * Pass on other registers
   */

  always @(posedge clk)
    if (~rst)
      begin
        frame_2          <= 3'b0;
        frame_picture_2  <= 1'b0;
        field_in_frame_2 <= 1'b0;
        field_2          <= 1'b0;
        component_2      <= 2'b0;
        mb_width_2       <= 8'd0;
        horizontal_size_2<= 14'd0;
        vertical_size_2  <= 14'd0;
        delta_x_2        <= 12'sd0;
        delta_y_2        <= 12'sd0;
        pixel_x_2        <= 12'sd0;
        pixel_y_2        <= 12'sd0;
        dta_2            <= {dta_width{1'b0}};
        valid_2          <= 1'b0;
        error_2          <= 1'b0;
      end
    else if (clk_en)
      begin
        frame_2          <= frame_1;
        frame_picture_2  <= frame_picture_1;
        field_in_frame_2 <= field_in_frame_1;
        field_2          <= field_1;
        component_2      <= component_1;
        mb_width_2       <= mb_width_1;
        horizontal_size_2<= horizontal_size_1;
        vertical_size_2  <= vertical_size_1;
	delta_x_2        <= delta_x_1;
	delta_y_2        <= delta_y_1;
        pixel_x_2        <= pixel_x_1;
        pixel_y_2        <= pixel_y_1;
        dta_2            <= dta_1;
        valid_2          <= valid_1;
        error_2          <= error_1;
      end
    else
      begin
        frame_2          <= frame_2;
        frame_picture_2  <= frame_picture_2;
        field_in_frame_2 <= field_in_frame_2;
        field_2          <= field_2;
        component_2      <= component_2;
        mb_width_2       <= mb_width_2;
        horizontal_size_2<= horizontal_size_2;
        vertical_size_2  <= vertical_size_2;
	delta_x_2        <= delta_x_2;
	delta_y_2        <= delta_y_2;
        pixel_x_2        <= pixel_x_2;
        pixel_y_2        <= pixel_y_2;
        dta_2            <= dta_2;
        valid_2          <= valid_2;
        error_2          <= error_2;
      end

  /*
   * Stage 3
   * Frame and field images
   * - If top field of a field image
   *     - multiply y by two
   *     - multiply motion vector y by two
   *     - multiply delta y by two
   * - If bottom field of a field image
   *     - multiply y by two and add one
   *     - multiply motion vector y by two
   *     - multiply delta y by two
   * - If frame image and field_in_frame is not set
   *     - pass on y, motion vector y and delta y unchanged
   * - If frame image and field_in_frame is set and field is top field
   *     - pass on y unchanged
   *     - multiply motion vector y by two
   *     - multiply delta y by two
   * - If frame image and field_in_frame is set and field is bottom field
   *     - add one to y
   *     - multiply motion vector y by two
   *     - multiply delta y by two
   */

  reg           [2:0]frame_3;
  reg           [1:0]component_3;
  reg           [7:0]mb_width_3;
  reg          [13:0]horizontal_size_3;
  reg          [13:0]vertical_size_3;
  reg signed   [12:0]delta_x_3;
  reg signed   [12:0]delta_y_3;
  reg signed   [12:0]mv_x_3;
  reg signed   [12:0]mv_y_3;
  reg signed   [12:0]pixel_x_3;
  reg signed   [12:0]pixel_y_3;
  reg                halfpixel_x_3;
  reg                halfpixel_y_3;
  reg [dta_width-1:0]dta_3;
  reg                valid_3;
  reg                error_3;

  always @(posedge clk)
    if (~rst)
      begin
        delta_y_3 <= 13'sd0;
	mv_y_3    <= 13'sd0;
	pixel_y_3 <= 13'sd0;
      end
    else if (clk_en && ~frame_picture_2) /* field picture */
      begin
        delta_y_3 <= delta_y_2 <<< 1;
	mv_y_3    <= mv_y_2 <<< 1;
	pixel_y_3 <= {pixel_y_2[11:0], field_2}; /* multiply by 2; add 1 if bottom field */
      end
    else if (clk_en && frame_picture_2 && field_in_frame_2 && field_2) /* field-in-frame, bottom field */
      begin
        delta_y_3 <= delta_y_2 <<< 1;
	mv_y_3    <= mv_y_2 <<< 1;
	pixel_y_3 <= pixel_y_2 + 12'sd1;
      end
    else if (clk_en && frame_picture_2 && field_in_frame_2 && ~field_2) /* field-in-frame, top field */
      begin
        delta_y_3 <= delta_y_2 <<< 1;
	mv_y_3    <= mv_y_2 <<< 1;
	pixel_y_3 <= pixel_y_2;
      end
    else if (clk_en && frame_picture_2 && ~field_in_frame_2) /* frame picture */
      begin
        delta_y_3 <= delta_y_2;
	mv_y_3    <= mv_y_2;
	pixel_y_3 <= pixel_y_2;
      end
    else
      begin
        delta_y_3 <= delta_y_3;
	mv_y_3    <= mv_y_3;
	pixel_y_3 <= pixel_y_3;
      end

  /*
   * Pass on other registers
   */

  always @(posedge clk)
    if (~rst)
      begin
        frame_3          <= 3'b0;
        component_3      <= 2'b0;
        mb_width_3       <= 8'd0;
        horizontal_size_3<= 14'd0;
        vertical_size_3  <= 14'd0;
        delta_x_3        <= 12'sd0;
        mv_x_3           <= 12'sd0;
	pixel_x_3        <= 13'sd0;
	halfpixel_x_3    <= 1'b0;
	halfpixel_y_3    <= 1'b0;
        dta_3            <= {dta_width{1'b0}};
        valid_3          <= 1'b0;
        error_3          <= 1'b0;
      end
    else if (clk_en)
      begin
        frame_3          <= frame_2;
        component_3      <= component_2;
        mb_width_3       <= mb_width_2;
        horizontal_size_3<= horizontal_size_2;
        vertical_size_3  <= vertical_size_2;
        delta_x_3        <= delta_x_2;
        mv_x_3           <= mv_x_2;
	pixel_x_3        <= pixel_x_2;
	halfpixel_x_3    <= halfpixel_x_2;
	halfpixel_y_3    <= halfpixel_y_2;
        dta_3            <= dta_2;
        valid_3          <= valid_2;
        error_3          <= error_2;
      end
    else
      begin
        frame_3          <= frame_3;
        component_3      <= component_3;
        mb_width_3       <= mb_width_3;
        horizontal_size_3<= horizontal_size_3;
        vertical_size_3  <= vertical_size_3;
        delta_x_3        <= delta_x_3;
        mv_x_3           <= mv_x_3;
	pixel_x_3        <= pixel_x_3;
	halfpixel_x_3    <= halfpixel_x_3;
	halfpixel_y_3    <= halfpixel_y_3;
        dta_3            <= dta_3;
        valid_3          <= valid_3;
        error_3          <= error_3;
      end

  /*
   * Stage 4
   * Add (delta_x, delta_y) to (pixel_x, pixel_y)
   */

  reg           [2:0]frame_4;
  reg           [1:0]component_4;
  reg           [7:0]mb_width_4;
  reg signed   [12:0]mv_x_4;
  reg signed   [12:0]mv_y_4;
  reg signed   [12:0]pixel_x_4;
  reg signed   [12:0]pixel_y_4;
  reg                halfpixel_x_4;
  reg                halfpixel_y_4;
  reg signed   [12:0]width_4; // width in pixels of component
  reg signed   [12:0]height_4; // width in pixels of component
  reg [dta_width-1:0]dta_4;
  reg                valid_4;
  reg                error_4;

  always @(posedge clk)
    if (~rst)
      begin
        pixel_x_4     <= 12'sd0;
        pixel_y_4     <= 12'sd0;
      end
    else if (clk_en)
      begin
        pixel_x_4     <= pixel_x_3 + delta_x_3;
        pixel_y_4     <= pixel_y_3 + delta_y_3;
      end
    else
      begin
        pixel_x_4     <= pixel_x_4;
        pixel_y_4     <= pixel_y_4;
      end

  always @(posedge clk)
    if (~rst)
      begin
        width_4       <= 14'd0;
        height_4      <= 14'd0;
      end
    else if (clk_en && (component_3 == COMP_Y))
      begin
        width_4       <= {1'b0, horizontal_size_3[11:0]};
        height_4      <= {1'b0, vertical_size_3[11:0]};
      end
    else if (clk_en)
      begin
        width_4       <= {2'b0, horizontal_size_3[11:1]};
        height_4      <= {2'b0, vertical_size_3[11:1]};
      end
    else
      begin
        width_4       <= width_4;
        height_4      <= height_4;
      end

  /*
   * Pass on other registers
   */

  always @(posedge clk)
    if (~rst)
      begin
        frame_4          <= 3'b0;
        component_4      <= 2'b0;
        mb_width_4       <= 8'd0;
        mv_x_4           <= 12'sd0;
        mv_y_4           <= 12'sd0;
	halfpixel_x_4    <= 1'b0;
	halfpixel_y_4    <= 1'b0;
        dta_4            <= {dta_width{1'b0}};
        valid_4          <= 1'b0;
        error_4          <= 1'b0;
      end
    else if (clk_en)
      begin
        frame_4          <= frame_3;
        component_4      <= component_3;
        mb_width_4       <= mb_width_3;
	mv_x_4           <= mv_x_3;
	mv_y_4           <= mv_y_3;
	halfpixel_x_4    <= halfpixel_x_3;
	halfpixel_y_4    <= halfpixel_y_3;
        dta_4            <= dta_3;
        valid_4          <= valid_3;
        error_4          <= error_3;
      end
    else
      begin
        frame_4          <= frame_4;
        component_4      <= component_4;
        mb_width_4       <= mb_width_4;
	mv_x_4           <= mv_x_4;
	mv_y_4           <= mv_y_4;
	halfpixel_x_4    <= halfpixel_x_4;
	halfpixel_y_4    <= halfpixel_y_4;
        dta_4            <= dta_4;
        valid_4          <= valid_4;
        error_4          <= error_4;
      end

  /*
   * Stage 5
   * Add (mv_x, mv_y) to (pixel_x, pixel_y)
   */

  reg           [2:0]frame_5;
  reg           [1:0]component_5;
  reg           [7:0]mb_width_5;
  reg signed   [12:0]pixel_x_5;
  reg signed   [12:0]pixel_y_5;
  reg                halfpixel_x_5;
  reg                halfpixel_y_5;
  reg signed   [12:0]width_5;
  reg signed   [12:0]height_5;
  reg [dta_width-1:0]dta_5;
  reg                valid_5;
  reg                error_5;

  always @(posedge clk)
    if (~rst)
      begin
        pixel_x_5     <= 12'd0;
        pixel_y_5     <= 12'd0;
      end
    else if (clk_en)
      begin
        pixel_x_5     <= pixel_x_4 + mv_x_4;
        pixel_y_5     <= pixel_y_4 + mv_y_4;
      end
    else
      begin
        pixel_x_5     <= pixel_x_5;
        pixel_y_5     <= pixel_y_5;
      end

  always @(posedge clk)
    if (~rst)
      begin
        width_5       <= 13'sd0;
        height_5      <= 13'sd0;
      end
    else if (clk_en && ((width_4 == 13'sd0) || (height_4 == 13'sd0)))
      begin
        width_5       <= 13'sd0;
        height_5      <= 13'sd0;
      end
    else if (clk_en)
      begin
        width_5       <= width_4 - 13'sd1;
        height_5      <= height_4 - 13'sd1;
      end
    else
      begin
        width_5       <= width_5;
        height_5      <= height_5;
      end

  /*
   * Pass on other registers
   */

  always @(posedge clk)
    if (~rst)
      begin
        frame_5          <= 3'b0;
        component_5      <= 2'b0;
        mb_width_5       <= 8'd0;
	halfpixel_x_5    <= 1'b0;
	halfpixel_y_5    <= 1'b0;
        dta_5            <= {dta_width{1'b0}};
        valid_5          <= 1'b0;
        error_5          <= 1'b0;
      end
    else if (clk_en)
      begin
        frame_5          <= frame_4;
        component_5      <= component_4;
        mb_width_5       <= mb_width_4;
	halfpixel_x_5    <= halfpixel_x_4;
	halfpixel_y_5    <= halfpixel_y_4;
        dta_5            <= dta_4;
        valid_5          <= valid_4;
        error_5          <= error_4;
      end
    else
      begin
        frame_5          <= frame_5;
        component_5      <= component_5;
        mb_width_5       <= mb_width_5;
	halfpixel_x_5    <= halfpixel_x_5;
	halfpixel_y_5    <= halfpixel_y_5;
        dta_5            <= dta_5;
        valid_5          <= valid_5;
        error_5          <= error_5;
      end

  /*
   * Stage 6
   * - clip to image borders
   * - convert pixel_x, pixel_y to unsigned.
   * At this point pixel_x, pixel_y, halfpixel_x and halfpixel_y have been fully computed.
   */

  reg           [2:0]frame_6;
  reg           [1:0]component_6;
  reg           [7:0]mb_width_6;
  reg          [11:0]pixel_x_6;
  reg          [11:0]pixel_y_6;
  reg           [2:0]offset_x_6;
  reg                halfpixel_x_6;
  reg                halfpixel_y_6;
  reg [dta_width-1:0]dta_6;
  reg                valid_6;
  reg                error_6;

  wire signed  [12:0]horizontal_diff = pixel_x_5 - width_5;
  wire signed  [12:0]vertical_diff   = pixel_y_5 - height_5;

  /*
   * Even though par. 7.6.3.8 guarantees:
   * "it is a restriction on the bitstream that reconstructed motion vectors shall not
   * refer to samples outside the boundary of the coded picture."
   * we clip coordinates to safe ranges.
   * For luminance:
   * Clip pixel_x to range [0, horizontal_size-1]
   * Clip pixel_y to range [0, vertical_size-1]
   * For chrominance:
   * Clip pixel_x to range [0, (horizontal_size>>1)-1]
   * Clip pixel_y to range [0, (vertical_size>>1)-1]
   * Convert pixel_x, pixel_y to unsigned
   */

  always @(posedge clk)
    if (~rst) pixel_x_6 <= 12'd0;
    else if (clk_en && pixel_x_5[12]) pixel_x_6 <= 12'd0; // if pixel_x_5 < 0, clip to 0
    else if (clk_en && horizontal_diff[12]) pixel_x_6 <= pixel_x_5[11:0]; // if pixel_x_5 > horizontal_size - 1, clip to horizontal_size - 1
    else if (clk_en) pixel_x_6 <= width_5[11:0];
    else pixel_x_6 <= pixel_x_6;

  always @(posedge clk)
    if (~rst) pixel_y_6 <= 12'd0;
    else if (clk_en && pixel_y_5[12]) pixel_y_6 <= 12'd0; // if pixel_y_5 < 0, clip to 0
    else if (clk_en && vertical_diff[12]) pixel_y_6 <= pixel_y_5[11:0]; // if pixel_y_5 > vertical_size - 1, clip to vertical_size - 1
    else if (clk_en) pixel_y_6 <= height_5[11:0];
    else pixel_y_6 <= pixel_y_6;

  /*
   *   Calculate byte offset within 8-byte word (offset_x)
   */

  always @(posedge clk)
    if (~rst) offset_x_6 <= 3'd0;
    else if (clk_en) offset_x_6 <= pixel_x_5[2:0];
    else offset_x_6 <= offset_x_6;

  always @(posedge clk)
    if (~rst) error_6 <= 1'b0;
    else if (clk_en) error_6 <= error_5;
    else error_6 <= error_6;

  /*
   * Pass on other registers
   */

  always @(posedge clk)
    if (~rst)
      begin
        frame_6          <= 3'b0;
        component_6      <= 2'b0;
        mb_width_6       <= 8'd0;
	halfpixel_x_6    <= 1'b0;
	halfpixel_y_6    <= 1'b0;
        dta_6            <= {dta_width{1'b0}};
        valid_6          <= 1'b0;
      end
    else if (clk_en)
      begin
        frame_6          <= frame_5;
        component_6      <= component_5;
        mb_width_6       <= mb_width_5;
	halfpixel_x_6    <= halfpixel_x_5;
	halfpixel_y_6    <= halfpixel_y_5;
        dta_6            <= dta_5;
        valid_6          <= valid_5;
      end
    else
      begin
        frame_6          <= frame_6;
        component_6      <= component_6;
        mb_width_6       <= mb_width_6;
	halfpixel_x_6    <= halfpixel_x_6;
	halfpixel_y_6    <= halfpixel_y_6;
        dta_6            <= dta_6;
        valid_6          <= valid_6;
      end

  /*
   * Stage 7
   * Line stride, part1.
   * - multiply y with mb_width
   * - split x into two parts: 
   *   - byte offset within 8-byte word (offset_x)
   *   - number of 8-byte words (word_x)
   */

  reg           [2:0]frame_7;
  reg           [1:0]component_7;
  reg                halfpixel_x_7;
  reg                halfpixel_y_7;
  reg          [21:0]address_7;
  reg           [2:0]offset_x_7;
  reg           [8:0]word_x_7;
  reg [dta_width-1:0]dta_7;
  reg                valid_7;
  reg                error_7;

  always @(posedge clk)
    if (~rst) address_7 <= 22'd0;
    else if (clk_en) address_7 <= pixel_y_6 * mb_width_6; /* Instantiate a multiplier :( */
    else address_7 <= address_7;

  always @(posedge clk)
    if (~rst) word_x_7 <= 3'd0;
    else if (clk_en) word_x_7 <= pixel_x_6[11:3];
    else word_x_7 <= word_x_7;

  /* if mb_width is zero we don't know MPEG2 horizontal picture size */
  always @(posedge clk)
    if (~rst) error_7 <= 1'b0;
    else if (clk_en) error_7 <= error_6 || (mb_width_6 == 8'd0); 
    else error_7 <= error_7;

  /*
   * Pass on other registers
   */

  always @(posedge clk)
    if (~rst)
      begin
        frame_7          <= 3'b0;
        component_7      <= 2'b0;
	halfpixel_x_7    <= 1'b0;
	halfpixel_y_7    <= 1'b0;
        offset_x_7       <= 3'd0;
        dta_7            <= {dta_width{1'b0}};
        valid_7          <= 1'b0;
      end
    else if (clk_en)
      begin
        frame_7          <= frame_6;
        component_7      <= component_6;
	halfpixel_x_7    <= halfpixel_x_6;
	halfpixel_y_7    <= halfpixel_y_6;
        offset_x_7       <= offset_x_6;
        dta_7            <= dta_6;
        valid_7          <= valid_6;
      end
    else
      begin
        frame_7          <= frame_7;
        component_7      <= component_7;
	halfpixel_x_7    <= halfpixel_x_7;
	halfpixel_y_7    <= halfpixel_y_7;
        offset_x_7       <= offset_x_7;
        dta_7            <= dta_7;
        valid_7          <= valid_7;
      end

  /*
   * Stage 8
   * Line stride, part 2.
   * - if macroblock is a luminance block, multiply address by two
   *   (luminance blocks are 16 pixels (bytes) wide; chrominance blocks only 8)
   * - extend word_x
   */

  reg           [2:0]frame_8;
  reg           [1:0]component_8;
  reg                halfpixel_x_8;
  reg                halfpixel_y_8;
  reg          [21:0]address_8;
  reg           [2:0]offset_x_8;
  reg          [21:0]word_x_8;
  reg [dta_width-1:0]dta_8;
  reg                valid_8;
  reg                error_8;

  always @(posedge clk)
    if (~rst) address_8 <= 22'd0;
    else if (clk_en && (component_7 == COMP_Y)) address_8 <= address_7 << 1;
    else if (clk_en) address_8 <= address_7;
    else address_8 <= address_8;

  always @(posedge clk)
    if (~rst) word_x_8 <= 22'd0;
    else if (clk_en) word_x_8 <= word_x_7;
    else word_x_8 <= word_x_8;

  /*
   * Pass on other registers
   */

  always @(posedge clk)
    if (~rst)
      begin
        frame_8          <= 3'b0;
        component_8      <= 2'b0;
	halfpixel_x_8    <= 1'b0;
	halfpixel_y_8    <= 1'b0;
	offset_x_8       <= 3'd0;
        dta_8            <= {dta_width{1'b0}};
        valid_8          <= 1'b0;
        error_8          <= 1'b0;
      end
    else if (clk_en)
      begin
        frame_8          <= frame_7;
        component_8      <= component_7;
	halfpixel_x_8    <= halfpixel_x_7;
	halfpixel_y_8    <= halfpixel_y_7;
	offset_x_8       <= offset_x_7;
        dta_8            <= dta_7;
        valid_8          <= valid_7;
        error_8          <= error_7;
      end
    else
      begin
        frame_8          <= frame_8;
        component_8      <= component_8;
	halfpixel_x_8    <= halfpixel_x_8;
	halfpixel_y_8    <= halfpixel_y_8;
	offset_x_8       <= offset_x_8;
        dta_8            <= dta_8;
        valid_8          <= valid_8;
        error_8          <= error_8;
      end

  /*
   * Stage 9
   * Line stride, part 3.
   * - add word_x to address
   * - determine begin/end addresses of frame in memory.
   */

  reg          [21:0]address_9;
  reg          [21:0]base_address_9;
  reg          [21:0]end_address_9;
  reg                halfpixel_x_9;
  reg                halfpixel_y_9;
  reg           [2:0]offset_x_9;
  reg [dta_width-1:0]dta_9;
  reg                valid_9;
  reg                error_9;

  always @(posedge clk)
    if (~rst) address_9 <= 22'd0;
    else if (clk_en) address_9 <= address_8 + word_x_8;
    else address_9 <= address_9;

  always @(posedge clk)
    if(~rst) base_address_9 <= 22'b0;
    else if (clk_en) 
      case ({frame_8, component_8}) 
        {3'd0, COMP_Y  }: base_address_9 <= FRAME_0_Y; 
        {3'd0, COMP_CR }: base_address_9 <= FRAME_0_CR; 
        {3'd0, COMP_CB }: base_address_9 <= FRAME_0_CB; 
        {3'd1, COMP_Y  }: base_address_9 <= FRAME_1_Y; 
        {3'd1, COMP_CR }: base_address_9 <= FRAME_1_CR; 
        {3'd1, COMP_CB }: base_address_9 <= FRAME_1_CB; 
        {3'd2, COMP_Y  }: base_address_9 <= FRAME_2_Y; 
        {3'd2, COMP_CR }: base_address_9 <= FRAME_2_CR; 
        {3'd2, COMP_CB }: base_address_9 <= FRAME_2_CB; 
        {3'd3, COMP_Y  }: base_address_9 <= FRAME_3_Y; 
        {3'd3, COMP_CR }: base_address_9 <= FRAME_3_CR; 
        {3'd3, COMP_CB }: base_address_9 <= FRAME_3_CB; 
        {3'd4, COMP_Y  }: base_address_9 <= OSD; 
        default           base_address_9 <= ADDR_ERR;
      endcase
    else base_address_9 <= base_address_9;

  always @(posedge clk)
    if(~rst) end_address_9 <= 22'b0;
    else if (clk_en) 
      case (component_8) 
        COMP_Y  : end_address_9 <= (22'd1 << WIDTH_Y); 
        COMP_CR,
        COMP_CB : end_address_9 <= (22'd1 << WIDTH_C); 
        default   end_address_9 <= 22'b0;
      endcase
    else end_address_9 <= end_address_9;

  /*
   * Pass on other registers
   */

  always @(posedge clk)
    if (~rst)
      begin
	halfpixel_x_9    <= 1'b0;
	halfpixel_y_9    <= 1'b0;
	offset_x_9       <= 3'd0;
        dta_9            <= {dta_width{1'b0}};
        valid_9          <= 1'b0;
        error_9          <= 1'b0;
      end
    else if (clk_en)
      begin
	halfpixel_x_9    <= halfpixel_x_8;
	halfpixel_y_9    <= halfpixel_y_8;
	offset_x_9       <= offset_x_8;
        dta_9            <= dta_8;
        valid_9          <= valid_8;
        error_9          <= error_8;
      end
    else
      begin
	halfpixel_x_9    <= halfpixel_x_9;
	halfpixel_y_9    <= halfpixel_y_9;
	offset_x_9       <= offset_x_9;
        dta_9            <= dta_9;
        valid_9          <= valid_9;
        error_9          <= error_9;
      end

  /*
   * Stage 10
   * - add base_address to address
   * - if address exceeds end_address, set error flag.
   */

  reg          [21:0]address_10;
  reg                halfpixel_x_10;
  reg                halfpixel_y_10;
  reg           [2:0]offset_x_10;
  reg [dta_width-1:0]dta_10;
  reg                valid_10;
  reg                error_10;

  /*
   * add base_address to address
   */

  always @(posedge clk)
    if (~rst) address_10 <= 22'd0;
    else if (clk_en) address_10 <= address_9 + base_address_9;
    else address_10 <= address_10;

  /*
   * if address exceeds end_address, set error flag.
   */

  always @(posedge clk)
    if (~rst) error_10 <= 1'b0;
    else if (clk_en) error_10 <= error_9 || (address_9 > end_address_9);
    else error_10 <= error_10;

  /*
   * Pass on other registers
   */

  always @(posedge clk)
    if (~rst)
      begin
	halfpixel_x_10    <= 1'b0;
	halfpixel_y_10    <= 1'b0;
	offset_x_10       <= 3'd0;
        dta_10            <= {dta_width{1'b0}};
        valid_10          <= 1'b0;
      end
    else if (clk_en)
      begin
	halfpixel_x_10    <= halfpixel_x_9;
	halfpixel_y_10    <= halfpixel_y_9;
	offset_x_10       <= offset_x_9;
        dta_10            <= dta_9;
        valid_10          <= valid_9;
      end
    else
      begin
	halfpixel_x_10    <= halfpixel_x_10;
	halfpixel_y_10    <= halfpixel_y_10;
	offset_x_10       <= offset_x_10;
        dta_10            <= dta_10;
        valid_10          <= valid_10;
      end

  /*
   * Stage 11
   * - Does nothing. (passes on data)
   */

  reg          [21:0]address_11;
  reg                halfpixel_x_11;
  reg                halfpixel_y_11;
  reg           [2:0]offset_x_11;
  reg [dta_width-1:0]dta_11;
  reg                valid_11;
  reg                error_11;

  always @(posedge clk)
    if (~rst) error_11 <= 1'b0;
    else if (clk_en) error_11 <= error_10;
    else error_11 <= error_11;

  /*
   * Pass on other registers
   */

  always @(posedge clk)
    if (~rst)
      begin
        address_11        <= 22'b0;
	halfpixel_x_11    <= 1'b0;
	halfpixel_y_11    <= 1'b0;
	offset_x_11       <= 3'd0;
        dta_11            <= {dta_width{1'b0}};
        valid_11          <= 1'b0;
      end
    else if (clk_en)
      begin
        address_11        <= address_10;
	halfpixel_x_11    <= halfpixel_x_10;
	halfpixel_y_11    <= halfpixel_y_10;
	offset_x_11       <= offset_x_10;
        dta_11            <= dta_10;
        valid_11          <= valid_10;
      end
    else
      begin
        address_11        <= address_11;
	halfpixel_x_11    <= halfpixel_x_11;
	halfpixel_y_11    <= halfpixel_y_11;
	offset_x_11       <= offset_x_11;
        dta_11            <= dta_11;
        valid_11          <= valid_11;
      end

  /*
   * Stage 12
   * - assign output variables
   * - if error flag set, set address to ADDR_ERR
   */

  always @(posedge clk)
    if (~rst) address <= 22'd0;
    else if (clk_en && error_11) address <= ADDR_ERR;
    else if (clk_en) address <= address_11;
    else address <= address;

  /*
   * Assign outputs
   */

  always @(posedge clk)
    if (~rst)
      begin
	halfpixel_x       <= 1'b0;
	halfpixel_y       <= 1'b0;
	offset_x          <= 3'd0;
        dta_out           <= {dta_width{1'b0}};
        valid_out         <= 1'b0;
      end
    else if (clk_en)
      begin
	halfpixel_x       <= halfpixel_x_11;
	halfpixel_y       <= halfpixel_y_11;
	offset_x          <= offset_x_11;
        dta_out           <= dta_11;
        valid_out         <= valid_11;
      end
    else
      begin
	halfpixel_x       <= halfpixel_x;
	halfpixel_y       <= halfpixel_y;
	offset_x          <= offset_x;
        dta_out           <= dta_out;
        valid_out         <= valid_out;
      end


`ifdef DEBUG
  always @(posedge clk)
    begin
      $strobe("%m\tclk_en: %d frame: %d frame_picture: %d field_in_frame: %d field: %d component: %d mb_width: %d macroblock_address: %h delta_x: %d delta_y: %d mv_x: %d mv_y: %d dta_in: %d valid_in: %d", 
                   clk_en, frame, frame_picture, field_in_frame, field, component, mb_width, macroblock_address, delta_x, delta_y, mv_x, mv_y, dta_in, valid_in);
      $strobe("%m\tclk_en: %d address: %h offset_x: %d halfpixel_x: %d halfpixel_y: %d dta_out: %d valid_out: %d", 
                   clk_en, address, offset_x, halfpixel_x, halfpixel_y, dta_out, valid_out);
      $strobe("%m\tclk_en: %d frame_6: %d component_6: %d pixel_x_6: %d pixel_y_6: %d offset_x_6: %d halfpixel_x_6: %d halfpixel_y_6: %d dta_6: %d valid_6: %d", 
                   clk_en, frame_6, component_6, pixel_x_6, pixel_y_6, offset_x_6, halfpixel_x_6, halfpixel_y_6, dta_6, valid_6);

    end
`endif

endmodule
/* not truncated */
