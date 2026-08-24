/* 
 * resample_bilinear.v
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
 * resample_bilinear - chroma resampling: bilinear interpolation. Doesn't increase sharpness, but doesn't "ring" either.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

module resample_bilinear (
  clk, clk_en, rst, 
  fifo_read, fifo_valid,
  fifo_osd, fifo_y, fifo_u_upper, fifo_u_lower, fifo_v_upper, fifo_v_lower, fifo_position,
  y, u, v, osd_out, position_out, pixel_wr_en, pixel_wr_almost_full
  );

  input              clk;                      // clock
  input              clk_en;                   // clock enable
  input              rst;                      // synchronous active low reset

  output reg         fifo_read;
  input              fifo_valid;

  /* chroma resampling: writing pixels and osd */
  output reg    [7:0]y;
  output reg    [7:0]u;
  output reg    [7:0]v;
  output reg    [7:0]osd_out;
  output reg    [2:0]position_out;
  output reg         pixel_wr_en;
  input              pixel_wr_almost_full;

  /* pixel data from resample_dta */
  input       [127:0]fifo_osd;        /* osd data */
  input       [127:0]fifo_y;          /* lumi */
  input        [63:0]fifo_u_upper;    /* chromi, upper row */
  input        [63:0]fifo_u_lower;    /* chromi, lower row */
  input        [63:0]fifo_v_upper;    /* chromi, upper row */
  input        [63:0]fifo_v_lower;    /* chromi, lower row */
  input         [2:0]fifo_position;   /* position code */

`include "resample_codes.v"

  parameter [2:0]
    STATE_INIT        = 3'h0,
    STATE_MACROBLOCK  = 3'h1,
    STATE_PIXEL       = 3'h2;
  
  reg          [2:0]state;
  reg          [2:0]next;

  reg         [15:0]loop;

  /* next state logic */
  always @*
    case (state)
      STATE_INIT:       if (~pixel_wr_almost_full && fifo_valid) next = STATE_MACROBLOCK;
                        else next = STATE_INIT;

      STATE_MACROBLOCK: next = STATE_PIXEL;

      STATE_PIXEL:      if (loop[15] == 1'b0) next = STATE_INIT;
                        else next = STATE_PIXEL;

      default           next = STATE_INIT;
    endcase

  /* state */
  always @(posedge clk)
    if(~rst) state <= STATE_INIT;
    else if (clk_en) state <= next;
    else state <= state;

  always @(posedge clk)
    if(~rst) loop <= 16'b0;
    else if (clk_en)
      case (state)
        STATE_INIT:
          if (fifo_valid)
            begin
              case (fifo_position)
                ROW_0_COL_0,
                ROW_1_COL_0,
                ROW_X_COL_0:        loop <= 16'b1111111111111000; // output 15 pixels for first macroblock of a row of pixels
                ROW_X_COL_X:        loop <= 16'b1111111111111100; // output 16 pixels for in-between macroblocks
                ROW_X_COL_LAST:     loop <= 16'b1111111111111110; // output 17 pixels for last macroblock of a row of pixels
                default             loop <= 16'b0;
              endcase
            end
          else
            loop <= loop;
        STATE_MACROBLOCK:       loop <= loop;
        STATE_PIXEL:            loop <= {loop[14:0], 1'b0};
        default                 loop <= loop;
      endcase
    else loop <= loop;

  always @(posedge clk)
    if(~rst) fifo_read <= 1'b0;
    else if (clk_en) fifo_read <= (state == STATE_MACROBLOCK);
    else  fifo_read <= fifo_read;

  /*
    What "bilinear upsampling" boils down to is this:
    - pass luminance on unchanged
    - if chroma horizontal position coincides with luma horizontal position, interpolate chroma vertically:
      chroma_out = 0.75 * chroma_upper + 0.25 * chroma_lower
    - if chroma horizontal position does not coincide with luma horizontal position, interpolate chroma both horizontally and vertically:
      chroma_out = 0.375 * chroma_upper_left + 0.125 * chroma_lower_left + 0.375 * chroma_upper_right + 0.125 * chroma_lower_right
    It's the responsibility of the chroma resampling address generator to make sure "upper" and "lower" row correspond to whatever is suitable for frame. top or bottom picture.
    resample_bilinear just does the math.
   */
   
  /* stage 0 */

  /* registers to read fifo_* in. 
     16 pixels - a macroblock - wide. 
     Two rows of chrominance information are stored, as we will have to interpolate between these two rows. */
  reg         [127:0]osd_0;        /* osd data */
  reg         [127:0]y_0;          /* lumi */
  reg          [63:0]u_upper_0;    /* chromi, upper row */
  reg          [63:0]u_lower_0;    /* chromi, lower row */
  reg          [63:0]v_upper_0;    /* chromi, upper row */
  reg          [63:0]v_lower_0;    /* chromi, lower row */
  reg           [2:0]position_0;   /* position code */

  always @(posedge clk)
    if (~rst)
      begin
        osd_0         <= 8'b0;
        y_0           <= 8'b0;
        u_upper_0     <= 12'sd0;
        u_lower_0     <= 12'sd0;
        v_upper_0     <= 12'sd0;
        v_lower_0     <= 12'sd0;
        position_0    <= 3'b0;
      end
    else if (clk_en && (state == STATE_INIT) && fifo_valid)
      begin
        osd_0         <= fifo_osd;
        y_0           <= fifo_y;
        u_upper_0     <= fifo_u_upper;
        u_lower_0     <= fifo_u_lower;
        v_upper_0     <= fifo_v_upper;
        v_lower_0     <= fifo_v_lower;
        position_0    <= fifo_position;
      end
    else
      begin
        osd_0         <= osd_0;
        y_0           <= y_0;
        u_upper_0     <= u_upper_0;
        u_lower_0     <= u_lower_0;
        v_upper_0     <= v_upper_0;
        v_lower_0     <= v_lower_0;
        position_0    <= position_0;
      end

  /* stage 1 */
  reg         [135:0]osd_1;
  reg         [135:0]y_1;
  reg         [135:0]u_upper_1;
  reg         [135:0]u_lower_1;
  reg         [135:0]v_upper_1;
  reg         [135:0]v_lower_1;
  reg           [2:0]position_1;
  reg                pixel_wr_en_1;
  reg           [2:0]position_0_saved;
  
  always @(posedge clk)
    if (~rst)
      begin
        osd_1            <= 135'b0;
        y_1              <= 135'b0;
        u_upper_1        <= 135'b0;
        u_lower_1        <= 135'b0;
        v_upper_1        <= 135'b0;
        v_lower_1        <= 135'b0;
        position_1       <= 3'b0;
        position_0_saved <= 3'b0;
        pixel_wr_en_1    <= 1'b0;
      end
    else if (clk_en && (state == STATE_INIT))
      begin
        osd_1            <= osd_1;
        y_1              <= y_1;
        u_upper_1        <= u_upper_1;
        u_lower_1        <= u_lower_1;
        v_upper_1        <= v_upper_1;
        v_lower_1        <= v_lower_1;
        position_1       <= position_1;
        position_0_saved <= position_0_saved;
        pixel_wr_en_1    <= 1'b0;
      end
    else if (clk_en && (state == STATE_MACROBLOCK) && ((position_0 == ROW_0_COL_0) || (position_0 == ROW_1_COL_0) || (position_0 == ROW_X_COL_0)))
      begin
        osd_1            <= {osd_0, 8'b0};
        y_1              <= {y_0, 8'b0};
        u_upper_1        <= {duplicate_pixel(u_upper_0), 8'b0};
        u_lower_1        <= {duplicate_pixel(u_lower_0), 8'b0};
        v_upper_1        <= {duplicate_pixel(v_upper_0), 8'b0};
        v_lower_1        <= {duplicate_pixel(v_lower_0), 8'b0};
        position_1       <= position_0;
        position_0_saved <= ROW_X_COL_X;
        pixel_wr_en_1    <= 1'b1;
      end
    else if (clk_en && (state == STATE_MACROBLOCK) && ((position_0 == ROW_X_COL_LAST) || (position_0 == ROW_X_COL_X)))
      begin
        osd_1            <= {osd_1[127:120], osd_0};
        y_1              <= {y_1[127:120], y_0};
        u_upper_1        <= {u_upper_1[127:120], duplicate_pixel(u_upper_0)};
        u_lower_1        <= {u_lower_1[127:120], duplicate_pixel(u_lower_0)};
        v_upper_1        <= {v_upper_1[127:120], duplicate_pixel(v_upper_0)};
        v_lower_1        <= {v_lower_1[127:120], duplicate_pixel(v_lower_0)};
        position_1       <= ROW_X_COL_X;
        position_0_saved <= position_0;
        pixel_wr_en_1    <= 1'b1;
      end
    else if (clk_en && (state == STATE_MACROBLOCK))
      begin
        osd_1            <= osd_1;
        y_1              <= y_1;
        u_upper_1        <= u_upper_1;
        u_lower_1        <= u_lower_1;
        v_upper_1        <= v_upper_1;
        v_lower_1        <= v_lower_1;
        position_1       <= position_1;
        position_0_saved <= position_0_saved;
        pixel_wr_en_1    <= 1'b0;
      end
    else if (clk_en && (state == STATE_PIXEL))
      begin
        osd_1            <= {osd_1[127:0], osd_1[7:0]};
        y_1              <= {y_1[127:0], y_1[7:0]};
        u_upper_1        <= {u_upper_1[127:0], u_upper_1[7:0]};
        u_lower_1        <= {u_lower_1[127:0], u_lower_1[7:0]};
        v_upper_1        <= {v_upper_1[127:0], v_upper_1[7:0]};
        v_lower_1        <= {v_lower_1[127:0], v_lower_1[7:0]};
        position_1       <= (loop[15] == 1'b0) ? position_0_saved : ROW_X_COL_X;
        position_0_saved <= position_0_saved;
        pixel_wr_en_1    <= 1'b1;
      end
    else 
      begin
        osd_1            <= osd_1;
        y_1              <= y_1;
        u_upper_1        <= u_upper_1;
        u_lower_1        <= u_lower_1;
        v_upper_1        <= v_upper_1;
        v_lower_1        <= v_lower_1;
        position_1       <= position_1;
        position_0_saved <= position_0_saved;
        pixel_wr_en_1    <= pixel_wr_en_1;
      end

  /* helper function. given a row of 8 pixels, repeat every pixel once, producing a row of 16 pixels */ 
  function [127:0]duplicate_pixel;
    input [63:0]u;
    begin
      duplicate_pixel = {u[63:56], u[63:56], u[55:48], u[55:48], u[47:40], u[47:40], u[39:32], u[39:32], u[31:24], u[31:24], u[23:16], u[23:16], u[15:8], u[15:8], u[7:0], u[7:0]};
    end
  endfunction

  /* For luminance, pick the leftmost. For chrominance, pick the leftmost two pixels - we'll need them to interpolate. */

  wire          [7:0]osd_pixel_1           = osd_1[135:128];
  wire signed   [7:0]y_pixel_1             = y_1[135:128];
  wire signed  [11:0]u_upper_left_pixel_1  = {{4{u_upper_1[135]}}, u_upper_1[135:128]}; // sign extend
  wire signed  [11:0]u_lower_left_pixel_1  = {{4{u_lower_1[135]}}, u_lower_1[135:128]}; // sign extend
  wire signed  [11:0]u_upper_right_pixel_1 = {{4{u_upper_1[127]}}, u_upper_1[127:120]}; // sign extend
  wire signed  [11:0]u_lower_right_pixel_1 = {{4{u_lower_1[127]}}, u_lower_1[127:120]}; // sign extend
  wire signed  [11:0]v_upper_left_pixel_1  = {{4{v_upper_1[135]}}, v_upper_1[135:128]}; // sign extend
  wire signed  [11:0]v_lower_left_pixel_1  = {{4{v_lower_1[135]}}, v_lower_1[135:128]}; // sign extend
  wire signed  [11:0]v_upper_right_pixel_1 = {{4{v_upper_1[127]}}, v_upper_1[127:120]}; // sign extend
  wire signed  [11:0]v_lower_right_pixel_1 = {{4{v_lower_1[127]}}, v_lower_1[127:120]}; // sign extend

  /* stage 2 */
  reg           [7:0]osd_pixel_2;
  reg signed    [7:0]y_pixel_2;
  reg signed   [11:0]u_upper_sum_2;
  reg signed   [11:0]u_lower_sum_2;
  reg signed   [11:0]v_upper_sum_2;
  reg signed   [11:0]v_lower_sum_2;
  reg           [2:0]position_2;
  reg                pixel_wr_en_2;

  always @(posedge clk)
    if (~rst)
      begin
        osd_pixel_2   <= 8'b0;
        y_pixel_2     <= 8'b0;
        u_upper_sum_2 <= 12'sd0;
        u_lower_sum_2 <= 12'sd0;
        v_upper_sum_2 <= 12'sd0;
        v_lower_sum_2 <= 12'sd0;
        position_2    <= 3'b0;
        pixel_wr_en_2 <= 1'b0;
      end
    else if (clk_en)
      begin
        osd_pixel_2   <= osd_pixel_1;
        y_pixel_2     <= y_pixel_1;
        u_upper_sum_2 <= u_upper_left_pixel_1 + u_upper_right_pixel_1;
        u_lower_sum_2 <= u_lower_left_pixel_1 + u_lower_right_pixel_1;
        v_upper_sum_2 <= v_upper_left_pixel_1 + v_upper_right_pixel_1;
        v_lower_sum_2 <= v_lower_left_pixel_1 + v_lower_right_pixel_1;
        position_2    <= position_1;
        pixel_wr_en_2 <= pixel_wr_en_1;
      end
    else
      begin
        osd_pixel_2   <= osd_pixel_2;
        y_pixel_2     <= y_pixel_2;
        u_upper_sum_2 <= u_upper_sum_2;
        u_lower_sum_2 <= u_lower_sum_2;
        v_upper_sum_2 <= v_upper_sum_2;
        v_lower_sum_2 <= v_lower_sum_2;
        position_2    <= position_2;
        pixel_wr_en_2 <= pixel_wr_en_2;
      end

  /* stage 3 */
  reg           [7:0]osd_pixel_3;
  reg signed    [7:0]y_pixel_3;
  reg signed   [11:0]u_upper_sum_3;
  reg signed   [11:0]u_lower_sum_3;
  reg signed   [11:0]v_upper_sum_3;
  reg signed   [11:0]v_lower_sum_3;
  reg           [2:0]position_3;
  reg                pixel_wr_en_3;

  wire signed  [11:0]double_u_upper_sum_2 = u_upper_sum_2 <<< 1;
  wire signed  [11:0]double_v_upper_sum_2 = v_upper_sum_2 <<< 1;

  always @(posedge clk)
    if (~rst)
      begin
        osd_pixel_3   <= 8'b0;
        y_pixel_3     <= 8'b0;
        u_upper_sum_3 <= 12'sd0;
        u_lower_sum_3 <= 12'sd0;
        v_upper_sum_3 <= 12'sd0;
        v_lower_sum_3 <= 12'sd0;
        position_3    <= 3'b0;
        pixel_wr_en_3 <= 1'b0;
      end
    else if (clk_en)
      begin
        osd_pixel_3   <= osd_pixel_2;
        y_pixel_3     <= y_pixel_2;
        u_upper_sum_3 <= u_upper_sum_2 + double_u_upper_sum_2; // multiply by 3
        u_lower_sum_3 <= u_lower_sum_2;
        v_upper_sum_3 <= v_upper_sum_2 + double_v_upper_sum_2; // multiply by 3
        v_lower_sum_3 <= v_lower_sum_2;
        position_3    <= position_2;
        pixel_wr_en_3 <= pixel_wr_en_2;
      end
    else
      begin
        osd_pixel_3   <= osd_pixel_3;
        y_pixel_3     <= y_pixel_3;
        u_upper_sum_3 <= u_upper_sum_3;
        u_lower_sum_3 <= u_lower_sum_3;
        v_upper_sum_3 <= v_upper_sum_3;
        v_lower_sum_3 <= v_lower_sum_3;
        position_3    <= position_3;
        pixel_wr_en_3 <= pixel_wr_en_3;
      end

  /* stage 4 */
  reg           [7:0]osd_pixel_4;
  reg signed    [7:0]y_pixel_4;
  reg signed   [11:0]u_pixel_4;
  reg signed   [11:0]v_pixel_4;
  reg           [2:0]position_4;
  reg                pixel_wr_en_4;

  always @(posedge clk)
    if (~rst)
      begin
        osd_pixel_4   <= 8'b0;
        y_pixel_4     <= 8'b0;
        u_pixel_4     <= 12'sd0;
        v_pixel_4     <= 12'sd0;
        position_4    <= 3'b0;
        pixel_wr_en_4 <= 1'b0;
      end
    else if (clk_en)
      begin
        osd_pixel_4   <= osd_pixel_3;
        y_pixel_4     <= y_pixel_3;
        u_pixel_4     <= (u_upper_sum_3 + u_lower_sum_3 + 12'sd7) >>> 3;
        v_pixel_4     <= (v_upper_sum_3 + v_lower_sum_3 + 12'sd7) >>> 3;
        position_4    <= position_3;
        pixel_wr_en_4 <= pixel_wr_en_3;
      end
    else
      begin
        osd_pixel_4   <= osd_pixel_4;
        y_pixel_4     <= y_pixel_4;
        u_pixel_4     <= u_pixel_4;
        v_pixel_4     <= v_pixel_4;
        position_4    <= position_4;
        pixel_wr_en_4 <= pixel_wr_en_4;
      end

  /* stage 5, clip to -128..127 */
  reg           [7:0]osd_pixel_5;
  reg signed    [7:0]y_pixel_5;
  reg signed    [7:0]u_pixel_5;
  reg signed    [7:0]v_pixel_5;
  reg           [2:0]position_5;
  reg                pixel_wr_en_5;

  always @(posedge clk)
    if (~rst)
      begin
        osd_pixel_5   <= 8'b0;
        y_pixel_5     <= 8'sd0;
        u_pixel_5     <= 8'sd0;
        v_pixel_5     <= 8'sd0;
        position_5    <= 3'b0;
        pixel_wr_en_5 <= 1'b0;
      end
    else if (clk_en)
      begin
        osd_pixel_5   <= osd_pixel_4;
        y_pixel_5     <= y_pixel_4;
        if ((u_pixel_4[11:8] == 4'b0000) || (u_pixel_4[11:8] == 4'b1111)) u_pixel_5 <= u_pixel_4[7:0];
        else u_pixel_5 <= {u_pixel_4[11], {7{~u_pixel_4[11]}}};
        if ((v_pixel_4[11:8] == 4'b0000) || (v_pixel_4[11:8] == 4'b1111)) v_pixel_5 <= v_pixel_4[7:0];
        else v_pixel_5 <= {v_pixel_4[11], {7{~v_pixel_4[11]}}};
        position_5    <= position_4;
        pixel_wr_en_5 <= pixel_wr_en_4;
      end
    else
      begin
        osd_pixel_5   <= osd_pixel_5;
        y_pixel_5     <= y_pixel_5;
        u_pixel_5     <= u_pixel_5;
        v_pixel_5     <= v_pixel_5;
        position_5    <= position_5;
        pixel_wr_en_5 <= pixel_wr_en_5;
      end

  /* stage 6, add offset of 128 to convert range to 0..255 and output */

  always @(posedge clk)
    if (~rst)
      begin
        osd_out      <= 8'b0;
        y            <= 8'b0;
        u            <= 8'b0;
        v            <= 8'b0;
        position_out <= 3'b0;
        pixel_wr_en  <= 1'b0;
      end
    else if (clk_en)
      begin
        osd_out      <= osd_pixel_5;
        y            <= y_pixel_5 + 8'd128;
        u            <= u_pixel_5 + 8'd128;
        v            <= v_pixel_5 + 8'd128;
        position_out <= position_5;
        pixel_wr_en  <= pixel_wr_en_5;
      end
    else
      begin
        osd_out      <= osd_out;
        y            <= y;
        u            <= u;
        v            <= v;
        position_out <= position_out;
        pixel_wr_en  <= pixel_wr_en;
      end

`ifdef DEBUG
  always @(posedge clk)
    case (state)
      STATE_INIT:                          #0 $display("%m         STATE_INIT");
      STATE_MACROBLOCK:                    #0 $display("%m         STATE_MACROBLOCK");
      STATE_PIXEL:                         #0 $display("%m         STATE_PIXEL");
      default                              #0 $display("%m         *** Error: unknown state %d", state);
    endcase

  always @(posedge clk)
    $strobe("%m\tloop: %18b", loop);

  always @(posedge clk)
    begin
      $strobe("%m\tosd_0: %32h y_0: %32h u_upper_0: %16h u_lower_0: %16h v_upper_0: %16h v_lower_0: %16h position_0: %d fifo_valid: %d", osd_0, y_0, u_upper_0, u_lower_0, v_upper_0, v_lower_0, position_0, fifo_valid);
      $strobe("%m\tosd_1: %32h y_1: %32h u_upper_1: %34h u_lower_1: %34h v_upper_1: %34h v_lower_1: %34h position_1: %d pixel_wr_en_1: %d", osd_1, y_1, u_upper_1, u_lower_1, v_upper_1, v_lower_1, position_1, pixel_wr_en_1);
      $strobe("%m\tosd_pixel_2: %h y_pixel_2: %h u_upper_sum_2: %h u_lower_sum_2: %h v_upper_sum_2: %h v_lower_sum_2: %h position_2: %d pixel_wr_en_2: %d", osd_pixel_2, y_pixel_2, u_upper_sum_2, u_lower_sum_2, v_upper_sum_2, v_lower_sum_2, position_2, pixel_wr_en_2);
      $strobe("%m\tosd_pixel_3: %h y_pixel_3: %h u_upper_sum_3: %h u_lower_sum_3: %h v_upper_sum_3: %h v_lower_sum_3: %h position_3: %d pixel_wr_en_3: %d", osd_pixel_3, y_pixel_3, u_upper_sum_3, u_lower_sum_3, v_upper_sum_3, v_lower_sum_3, position_3, pixel_wr_en_3);
      $strobe("%m\tosd_pixel_4: %h y_pixel_4: %h u_pixel_4: %h v_pixel_4: %h position_4: %d pixel_wr_en_4: %d", osd_pixel_4, y_pixel_4, u_pixel_4, v_pixel_4, position_4, pixel_wr_en_4);
      $strobe("%m\tosd_pixel_5: %h y_pixel_5: %h u_pixel_5: %h v_pixel_5: %h position_5: %d pixel_wr_en_5: %d", osd_pixel_5, y_pixel_5, u_pixel_5, v_pixel_5, position_5, pixel_wr_en_5);
      $strobe("%m\tosd_out: %h y: %h u: %h v: %h position_out: %d pixel_wr_en: %d", osd_out, y, u, v, position_out, pixel_wr_en);
    end

`endif

`ifdef STOP_IF_UNDEFINED_PIXEL
  /*
   Note not all undefined pixels indicate a decoder error;
   if a stream begins with a P or B image pixels may be undefined as well.
   */
  always @(posedge clk)
    if (pixel_wr_en && ((^y === 1'bx) || (^u === 1'bx) || (^v === 1'bx))) 
      begin
        $finish;
      end
`endif

endmodule
/* not truncated */
