/* 
 * resample_addrgen.v
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
 * resample_addrgen - chroma resampling: address generation
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

module resample_addrgen (
  clk, clk_en, rst,
  output_frame, output_frame_valid, output_frame_rd,
  progressive_sequence, progressive_frame, top_field_first, repeat_first_field, mb_width, mb_height, horizontal_size, vertical_size,
  interlaced, deinterlace, persistence, repeat_frame,
  disp_wr_addr_full, disp_wr_addr_en, disp_wr_addr_ack, disp_wr_addr,
  resample_wr_dta, resample_wr_en,
  disp_wr_addr_almost_full, resample_wr_almost_full,
  busy
  );

  input              clk;                      // clock
  input              clk_en;                   // clock enable
  input              rst;                      // synchronous active low reset

  input        [2:0]output_frame;              /* frame to be displayed */
  input             output_frame_valid;        /* asserted when output_frame valid */
  output reg        output_frame_rd;

  input             progressive_sequence;
  input             progressive_frame;
  input             top_field_first;
  input             repeat_first_field;
  input         [7:0]mb_width;                 // par. 6.3.3. width of the encoded luminance component of pictures in macroblocks
  input         [7:0]mb_height;                // par. 6.3.3. height of the encoded luminance component of frame pictures in macroblocks
  input        [13:0]horizontal_size;          // par. 6.2.2.1, par. 6.3.3 
  input        [13:0]vertical_size;            // par. 6.2.2.1, par. 6.3.3

  input              interlaced;               // asserted if display modeline is interlaced
  input              deinterlace;              // asserted if video has to be deinterlaced
  input              persistence;              // asserted if last shown image persists
  input         [4:0]repeat_frame;             // repeat frame if non-zero

  /* reading reconstructed frame: writing address */
  input              disp_wr_addr_full;
  output             disp_wr_addr_en;
  input              disp_wr_addr_ack;
  output       [21:0]disp_wr_addr;

  output reg    [2:0]resample_wr_dta;
  output reg         resample_wr_en;

  input              disp_wr_addr_almost_full;
  input              resample_wr_almost_full;
  output reg         busy;                     // asserted when generating addresses

`include "vld_codes.v"
`include "mem_codes.v"
`include "resample_codes.v"

  /* 
    progressive_sequence == 1: progressive video, no interlacing. use progressive chroma upsampling.
      repeat_first_field == 0: show frame once.
      repeat_first_field == 1: 
        top_field_first == 0: show frame twice.
        top_field_first == 1: show frame three times.
     
    progressive_sequence == 0: interlacing.
      progressive_frame == 0: use interlaced chroma upsampling.
        top_field_first == 1: show top field, then show bottom field.
        top_field_first == 0: show bottom field, then show top field.
      progressive_frame == 1: use progressive chroma upsampling.
        repeat_first_field == 0: 
          top_field_first == 1: show top field, then show bottom field.
          top_field_first == 0: show bottom field, then show top field.
        repeat_first_field == 1: 
          top_field_first == 1: show top field, then show bottom field, then show top field.
          top_field_first == 0: show bottom field, then show top field, then show bottom field.

    See par. 7.12, Output of the decoding process 

    A slight complication: as a workaround for popular mpeg2 encoder bug,
    if the current frame's progressive_frame flag is "true"
      use progressive chroma upsampling
    else
      if the previous frame's progressive_frame AND repeat_first_field flags are "true"
        use progressive chroma upsampling
       else
        use interlaced chroma upsampling
    ( From: http://www.hometheaterhifi.com/volume_8_2/dvd-benchmark-special-report-chroma-bug-4-2001.html )
  */

  parameter [1:0] 
    NO_OUTPUT         = 3'h0,      // No output
    FRAME             = 3'h1,      // Output frame, progressive chroma upsampling.
    TOP               = 3'h2,      // Output top field, progressive or interlaced chroma upsampling.
    BOTTOM            = 3'h3;      // Output bottom field, progressive or interlaced chroma upsampling.ç

  reg               encoder_bug_workaround;
  reg          [1:0]last_image;
  reg          [1:0]image;
  reg          [1:0]image_0;
  reg          [1:0]image_1;
  reg          [1:0]image_2;
  reg          [1:0]image_3;
  reg          [1:0]image_4;
  reg          [1:0]image_5;
  reg          [4:0]repeat_cnt;

  wire          [7:0]mb_height_minus_one = mb_height - 8'd1;
  wire          [7:0]mb_width_minus_one = mb_width - 8'd1;

  reg          [2:0]output_frame_sav;        /* saved 'output_frame' value */
  reg          [2:0]disp_frame;              /* frame to be fetched from memory. May be OSD_FRAME */
  reg          [1:0]disp_comp;               /* Component to be fetched from memory. If frame, has value COMP_Y, COMP_CR or COMP_CB. If osd, has value COMP_Y */
 /*
  disp_mb counts left to right, one macroblock at a time. 
  disp_y counts top to bottom, one (frame) or two (field) lines at a time.
  */
  reg          [7:0]disp_mb;                 /* horizontal macroblock counter */
  wire        [11:0]disp_x = {disp_mb, 4'b0};/* horizontal coordinate */
  reg         [11:0]disp_y;                  /* vertical line counter */
  reg signed  [12:0]disp_delta_x;            /* address generator input */
  reg signed  [12:0]disp_delta_y;            /* address generator input */
  reg signed  [12:0]disp_mv_x;               /* address generator input */
  reg signed  [12:0]disp_mv_y;               /* address generator input */
  reg               disp_valid_in;

  reg               progressive_upscaling;   /* asserted if progressive upscaling, low if interlaced upscaling */
  wire        [11:0]disp_height = {mb_height, 4'b0}; // height in lines
  wire              last_mb = (disp_mb + 1) == mb_width; // asserted in rightmost macroblock of line
  wire              last_y = (disp_y[11:4] == mb_height_minus_one) && (disp_y[3:0] == ((image == TOP) ? 4'd14 : 4'd15));

  parameter [3:0] 
    STATE_INIT        = 4'h0,      
    STATE_NEXT_IMG    = 4'h1,
    STATE_REPEAT      = 4'h2,
    STATE_NEXT_MB     = 4'h3,
    STATE_WAIT        = 4'h4,
    STATE_WR_OSD_MSB  = 4'h5,
    STATE_WR_OSD_LSB  = 4'h6,
    STATE_WR_Y_MSB    = 4'h7,
    STATE_WR_Y_LSB    = 4'h8,
    STATE_WR_U_UPPER  = 4'h9,
    STATE_WR_U_LOWER  = 4'ha,
    STATE_WR_V_UPPER  = 4'hb,
    STATE_WR_V_LOWER  = 4'hc;

  reg         [3:0]state;
  reg         [3:0]next;

  /* next state logic */
  always @*
    case (state)
      STATE_INIT:         if (output_frame_valid) next = STATE_NEXT_IMG; // wait for next output frame
                          else next = STATE_INIT;

      STATE_NEXT_IMG:     if ((image_0 == NO_OUTPUT) && (image_1 == NO_OUTPUT) && (image_2 == NO_OUTPUT) &&
                              (image_3 == NO_OUTPUT) && (image_4 == NO_OUTPUT) && (image_5 == NO_OUTPUT)) next = STATE_REPEAT; 
                          else next = STATE_WR_OSD_MSB; 

      STATE_REPEAT:       if (repeat_cnt != 5'd0) next = STATE_NEXT_IMG; // repeat frame 
                          else if (~output_frame_valid && persistence && (last_image != NO_OUTPUT)) next = STATE_NEXT_IMG; // persistence: repeat last image until next image decoded
                          else next = STATE_INIT;

      STATE_NEXT_MB:      if (last_mb && last_y) next = STATE_NEXT_IMG;
                          else next = STATE_WAIT;

      STATE_WAIT:         if (disp_wr_addr_almost_full || resample_wr_almost_full) next = STATE_WAIT;
                          else next = STATE_WR_OSD_MSB;

      STATE_WR_OSD_MSB:   next = STATE_WR_OSD_LSB; // output osd read requests - 16 pixels

      STATE_WR_OSD_LSB:   next = STATE_WR_Y_MSB;

      STATE_WR_Y_MSB:     next = STATE_WR_Y_LSB; // output luminance read requests - 16 pixels

      STATE_WR_Y_LSB:     next = STATE_WR_U_UPPER; 

      STATE_WR_U_UPPER:   next = STATE_WR_U_LOWER; // output chroma read requests - 2 rows of 8 

      STATE_WR_U_LOWER:   next = STATE_WR_V_UPPER;

      STATE_WR_V_UPPER:   next = STATE_WR_V_LOWER; // output chroma read requests - 2 rows of 8

      STATE_WR_V_LOWER:   next = STATE_NEXT_MB;

      default             next = STATE_INIT;

    endcase

  /* state */
  always @(posedge clk)
    if(~rst) state <= STATE_INIT;
    else if (clk_en) state <= next;
    else state <= state;

  always @(posedge clk)
    if (~rst) busy <= 1'd0;
    else if (clk_en) busy <= (next != STATE_INIT);
    else busy <= busy;

  always @(posedge clk)
    if (~rst) output_frame_rd <= 1'd0;
    else if (clk_en) output_frame_rd <= (state == STATE_INIT) && output_frame_valid;
    else output_frame_rd <= output_frame_rd;

  /*
   * repeat frame counter
   */

  always @(posedge clk)
    if (~rst) repeat_cnt <= 5'd0;
    else if (clk_en && (state == STATE_INIT)) repeat_cnt <= repeat_frame;
    else if (clk_en && (state == STATE_REPEAT) && (repeat_cnt == 5'd31)) repeat_cnt <= repeat_frame;
    else if (clk_en && (state == STATE_REPEAT) && (repeat_cnt != 5'd0)) repeat_cnt <= repeat_cnt - 5'd1;
    else repeat_cnt <= repeat_cnt;

  /* counters */

  always @(posedge clk)
    if (~rst) disp_mb <= 8'd0;
    else if (clk_en && (state == STATE_NEXT_IMG)) disp_mb <= 8'd0;
    else if (clk_en && (state == STATE_NEXT_MB) && last_mb) disp_mb <= 8'd0;
    else if (clk_en && (state == STATE_NEXT_MB)) disp_mb <= disp_mb + 8'd1;
    else disp_mb <= disp_mb;

  always @(posedge clk)
    if (~rst) disp_y <= 12'd0;
    else if (clk_en && (state == STATE_NEXT_IMG)) disp_y <= (image_0 == BOTTOM) ? 12'd1 : 12'd0;
    else if (clk_en && (state == STATE_NEXT_MB) && last_mb) disp_y <= (image == FRAME) ? disp_y + 12'd1 : disp_y + 12'd2;
    else disp_y <= disp_y;

  /* one output frame may have to be shown up to three times (par. 7.12) */
  always @(posedge clk)
    if (~rst)
      begin
        image   <= NO_OUTPUT;
        image_0 <= NO_OUTPUT;
        image_1 <= NO_OUTPUT;
        image_2 <= NO_OUTPUT;
        image_3 <= NO_OUTPUT;
        image_4 <= NO_OUTPUT;
        image_5 <= NO_OUTPUT;
        progressive_upscaling <= 1'b0;
      end
    else if (clk_en && (state == STATE_INIT) && output_frame_valid)
      begin
        /*
         * display progressive sequence on progressive display. Display frames.
         */
        if (progressive_sequence && ~interlaced)
          begin
            image   <= NO_OUTPUT;
            image_0 <= FRAME;
            image_1 <= (repeat_first_field) ? FRAME : NO_OUTPUT;
            image_2 <= (repeat_first_field && top_field_first) ? FRAME : NO_OUTPUT;
            image_3 <= NO_OUTPUT;
            image_4 <= NO_OUTPUT;
            image_5 <= NO_OUTPUT;
            progressive_upscaling <= 1'b1;
          end
        /*
         * Interlacing: display progressive sequence on interlaced display. Display fields.
         */
        else if (progressive_sequence && interlaced)
          begin
            image   <= NO_OUTPUT;
            image_0 <= TOP;
            image_1 <= BOTTOM;
            image_2 <= (repeat_first_field) ? TOP : NO_OUTPUT;
            image_3 <= (repeat_first_field) ? BOTTOM : NO_OUTPUT;
            image_4 <= (repeat_first_field && top_field_first) ? TOP : NO_OUTPUT;
            image_5 <= (repeat_first_field && top_field_first) ? BOTTOM : NO_OUTPUT;
            progressive_upscaling <= 1'b1;
          end
        /*
         * XXX Deinterlacing: display is progressive and deinterlacing is requested. Display frame.
         */
        else if (deinterlace && ~interlaced) 
          begin
            image   <= NO_OUTPUT;
            image_0 <= FRAME;
            image_1 <= NO_OUTPUT;
            image_2 <= NO_OUTPUT;
            image_3 <= NO_OUTPUT;
            image_4 <= NO_OUTPUT;
            image_5 <= NO_OUTPUT;
            progressive_upscaling <= (progressive_frame || encoder_bug_workaround);
          end
         /*
          * Interlaced display, progressive frame.
          */
        else if (progressive_frame)
          begin
            image   <= NO_OUTPUT;
            image_0 <= (top_field_first) ? TOP : BOTTOM;
            image_1 <= (top_field_first) ? BOTTOM : TOP;
            image_2 <= (repeat_first_field) ? ((top_field_first) ? TOP : BOTTOM) : NO_OUTPUT;
            image_3 <= NO_OUTPUT;
            image_4 <= NO_OUTPUT;
            image_5 <= NO_OUTPUT;
            progressive_upscaling <= 1'b1;
          end
        else
         /*
          * Interlaced display, interlaced frame.
          */
          begin
            image   <= NO_OUTPUT;
            image_0 <= (top_field_first) ? TOP : BOTTOM;
            image_1 <= (top_field_first) ? BOTTOM : TOP;
            image_2 <= NO_OUTPUT;
            image_3 <= NO_OUTPUT;
            image_4 <= NO_OUTPUT;
            image_5 <= NO_OUTPUT;
            progressive_upscaling <= encoder_bug_workaround;
          end
      end
    else if (clk_en && (state == STATE_REPEAT) && (next == STATE_NEXT_IMG))
      /*
       * Repeat last shown image.
       * If last shown image was a frame, show frame.
       * If last shown image was a field image, show both fields.
       */
      begin
        image   <= NO_OUTPUT;
        case (last_image)
          FRAME: 
            begin
              image_0 <= FRAME;
              image_1 <= NO_OUTPUT;
            end
          TOP:
            begin
              image_0 <= BOTTOM;
              image_1 <= TOP;
            end
          BOTTOM:
            begin
              image_0 <= TOP;
              image_1 <= BOTTOM;
            end
          NO_OUTPUT:
            begin
              image_0 <= NO_OUTPUT;
              image_1 <= NO_OUTPUT;
            end
          default
            begin
              image_0 <= NO_OUTPUT;
              image_1 <= NO_OUTPUT;
            end
        endcase
        image_2 <= NO_OUTPUT;
        image_3 <= NO_OUTPUT;
        image_4 <= NO_OUTPUT;
        image_5 <= NO_OUTPUT;
        progressive_upscaling <= progressive_upscaling;
      end
    else if (clk_en && (state == STATE_NEXT_IMG))
      begin
        image   <= image_0;
        image_0 <= image_1;
        image_1 <= image_2;
        image_2 <= image_3;
        image_3 <= image_4;
        image_4 <= image_5;
        image_5 <= NO_OUTPUT;
        progressive_upscaling <= progressive_upscaling;
      end
    else
      begin
        image   <= image;
        image_0 <= image_0;
        image_1 <= image_1;
        image_2 <= image_2;
        image_3 <= image_3;
        image_4 <= image_4;
        image_5 <= image_5;
        progressive_upscaling <= progressive_upscaling;
      end

  always @(posedge clk)
    if (~rst) last_image <= NO_OUTPUT;
    else if (clk_en && (state == STATE_INIT) && ~persistence) last_image <= NO_OUTPUT;
    else if (clk_en && (state == STATE_NEXT_IMG)) last_image <= image;
    else last_image <= last_image;

  /* registers */
  /* save output_frame */
  always @(posedge clk)
    if (~rst) output_frame_sav <= 3'b0;
    else if (clk_en && (state == STATE_INIT) && output_frame_valid) output_frame_sav <= output_frame;
    else output_frame_sav <= output_frame_sav;

  /* determine frame, top, bottom sequence */
  always @(posedge clk)
    if (~rst) encoder_bug_workaround <= 1'b0;
    else if (clk_en && (state == STATE_INIT) && output_frame_valid) encoder_bug_workaround <= progressive_frame && repeat_first_field;
    else encoder_bug_workaround <= encoder_bug_workaround;

  always @(posedge clk)
    if (~rst) disp_frame <= 3'b0;
    else if (clk_en)
      case (state)
        STATE_INIT,
        STATE_NEXT_IMG,
        STATE_REPEAT,
        STATE_NEXT_MB,
        STATE_WAIT:       disp_frame <= output_frame_sav;
        STATE_WR_OSD_MSB,
        STATE_WR_OSD_LSB: disp_frame <= OSD_FRAME; /* osd frame */
        STATE_WR_Y_MSB,
        STATE_WR_Y_LSB,
        STATE_WR_U_UPPER,
        STATE_WR_U_LOWER,
        STATE_WR_V_UPPER,
        STATE_WR_V_LOWER: disp_frame <= output_frame_sav;
        default           disp_frame <= output_frame_sav;
      endcase
    else disp_frame <= disp_frame;

  always @(posedge clk)
    if (~rst) disp_comp <= 2'b0;
    else if (clk_en)
      case (state)
        STATE_INIT,
        STATE_NEXT_IMG,
        STATE_REPEAT,
        STATE_NEXT_MB,
        STATE_WAIT,
        STATE_WR_OSD_MSB,
        STATE_WR_OSD_LSB,
        STATE_WR_Y_MSB,
        STATE_WR_Y_LSB:   disp_comp <= COMP_Y;
        STATE_WR_U_UPPER,
        STATE_WR_U_LOWER: disp_comp <= COMP_CR;
        STATE_WR_V_UPPER,
        STATE_WR_V_LOWER: disp_comp <= COMP_CB;
        default           disp_comp <= COMP_Y;
      endcase
    else disp_comp <= disp_comp;

  always @(posedge clk)
    if (~rst) disp_delta_x <= 13'sd0;
    else if (clk_en)
      case (state)
        STATE_INIT,
        STATE_NEXT_IMG,
        STATE_REPEAT,
        STATE_NEXT_MB,
        STATE_WAIT,
        STATE_WR_OSD_MSB,
        STATE_WR_OSD_LSB,
        STATE_WR_Y_MSB,
        STATE_WR_Y_LSB:   disp_delta_x <= {1'b0, disp_x};
        STATE_WR_U_UPPER,
        STATE_WR_U_LOWER,
        STATE_WR_V_UPPER,
        STATE_WR_V_LOWER: disp_delta_x <= {2'b0, disp_x[11:1]};
        default           disp_delta_x <= 13'sd0;
      endcase
    else disp_delta_x <= disp_delta_x;

  always @(posedge clk)
    if (~rst) disp_delta_y <= 13'sd0;
    else if (clk_en)
      case (state)
        STATE_INIT,
        STATE_NEXT_IMG,
        STATE_REPEAT,
        STATE_NEXT_MB,
        STATE_WAIT,
        STATE_WR_OSD_MSB,
        STATE_WR_OSD_LSB,
        STATE_WR_Y_MSB,
        STATE_WR_Y_LSB:   disp_delta_y <= {1'b0, disp_y};
        STATE_WR_U_UPPER,
        STATE_WR_U_LOWER,
        STATE_WR_V_UPPER,
        STATE_WR_V_LOWER: if (progressive_upscaling) disp_delta_y <= {2'b0, disp_y[11:1]};
                          else disp_delta_y <= {2'b0, disp_y[11:2], disp_y[0]};
        default           disp_delta_y <= 13'sd0;
      endcase
    else disp_delta_y <= disp_delta_y;

  always @(posedge clk)
    if (~rst) disp_mv_x <= 2'b0;
    else if (clk_en)
      case (state)
        STATE_INIT,
        STATE_NEXT_IMG,
        STATE_REPEAT,
        STATE_NEXT_MB,
        STATE_WAIT,
        STATE_WR_OSD_MSB: disp_mv_x <= 13'sd0;
        STATE_WR_OSD_LSB: disp_mv_x <= 13'sd16; // 16 halfpixels
        STATE_WR_Y_MSB:   disp_mv_x <= 13'sd0;
        STATE_WR_Y_LSB:   disp_mv_x <= 13'sd16; // 16 halfpixels
        STATE_WR_U_UPPER,
        STATE_WR_U_LOWER,
        STATE_WR_V_UPPER,
        STATE_WR_V_LOWER: disp_mv_x <= 13'sd0;
        default           disp_mv_x <= 13'sd0;
      endcase
    else disp_mv_x <= disp_mv_x;

  /* border cases */
  wire signed [12:0]disp_mv_y_minus_4 =  (disp_y[11:2] == 10'b0)                                            ? 13'sd0 : -13'sd4;
  wire signed [12:0]disp_mv_y_minus_2 =  (disp_y[11:1] == 11'b0)                                            ? 13'sd0 : -13'sd2;
  wire signed [12:0]disp_mv_y_plus_2  =  ((disp_y[11:4] == mb_height_minus_one) && (disp_y[3:1] == 3'b111)) ? 13'sd0 : 13'sd2;
  wire signed [12:0]disp_mv_y_plus_4  =  ((disp_y[11:4] == mb_height_minus_one) && (disp_y[3:2] == 2'b11))  ? 13'sd0 : 13'sd4;

  /* bilinear chroma upsampling; see text file 'bilinear.txt' */
  always @(posedge clk)
    if (~rst) disp_mv_y <= 2'b0;
    else if (clk_en)
      case (state)
        STATE_INIT,
        STATE_NEXT_IMG,
        STATE_REPEAT,
        STATE_NEXT_MB,
        STATE_WAIT:       disp_mv_y <= 13'sd0;
        STATE_WR_OSD_MSB,
        STATE_WR_OSD_LSB,
        STATE_WR_Y_MSB,
        STATE_WR_Y_LSB,
        STATE_WR_U_UPPER,
        STATE_WR_V_UPPER: disp_mv_y <= 13'sd0;
        STATE_WR_U_LOWER,
        STATE_WR_V_LOWER: if (progressive_upscaling) disp_mv_y <= disp_y[0] ? disp_mv_y_plus_2 : disp_mv_y_minus_2;
                          else disp_mv_y <= disp_y[1] ? disp_mv_y_plus_4 : disp_mv_y_minus_4;
        default           disp_mv_y <= 13'sd0;
      endcase
    else disp_mv_y <= disp_mv_y;

  always @(posedge clk)
    if (~rst) disp_valid_in <= 1'b0;
    else if (clk_en)
      case (state)
        STATE_INIT,
        STATE_NEXT_IMG,
        STATE_REPEAT,
        STATE_NEXT_MB,
        STATE_WAIT:       disp_valid_in <= 1'b0;
        STATE_WR_OSD_MSB,
        STATE_WR_OSD_LSB,
        STATE_WR_Y_MSB,
        STATE_WR_Y_LSB,
        STATE_WR_U_UPPER,
        STATE_WR_U_LOWER,
        STATE_WR_V_UPPER,
        STATE_WR_V_LOWER: disp_valid_in <= 1'b1;
        default           disp_valid_in <= 1'b0;
      endcase
    else disp_valid_in <= disp_valid_in;

  /* 
   Write to resample fifo.
   */

  always @(posedge clk)
    if (~rst) resample_wr_dta <= 2'b0;
    else if (clk_en && (state == STATE_WR_OSD_MSB) && (disp_mb == 8'd0) && (disp_y == 12'd0)) resample_wr_dta <= ROW_0_COL_0;
    else if (clk_en && (state == STATE_WR_OSD_MSB) && (disp_mb == 8'd0) && (disp_y == 12'd1)) resample_wr_dta <= ROW_1_COL_0;
    else if (clk_en && (state == STATE_WR_OSD_MSB) && (disp_mb == 8'd0)) resample_wr_dta <= ROW_X_COL_0;
    else if (clk_en && (state == STATE_WR_OSD_MSB) && (disp_mb == mb_width_minus_one)) resample_wr_dta <= ROW_X_COL_LAST;
    else if (clk_en && (state == STATE_WR_OSD_MSB)) resample_wr_dta <= ROW_X_COL_X;
    else resample_wr_dta <= resample_wr_dta;

  always @(posedge clk)
    if (~rst) resample_wr_en <= 1'b0;
    else if (clk_en) resample_wr_en <= (state == STATE_WR_OSD_MSB);
    else resample_wr_en <= resample_wr_en;

  /* display address generator */
  memory_address
    #(.dta_width(1))
    disp_mem_addr (
    .clk(clk), 
    .clk_en(clk_en), 
    .rst(rst), 
    /* in */
    .frame(disp_frame), 
    .frame_picture(1'b1), 
    .field_in_frame(1'b0), 
    .field(1'b0), 
    .component(disp_comp), 
    .mb_width(mb_width), 
    .horizontal_size(horizontal_size),
    .vertical_size(vertical_size),
    .macroblock_address(13'd0), 
    .delta_x(disp_delta_x), 
    .delta_y(disp_delta_y), 
    .mv_x(disp_mv_x), 
    .mv_y(disp_mv_y), 
    .dta_in(1'b0), 
    .valid_in(disp_valid_in), 
    /* out */
    .address(disp_wr_addr), 
    .offset_x(), 
    .halfpixel_x(), 
    .halfpixel_y(), 
    .dta_out(), 
    .valid_out(disp_wr_addr_en)
    );

`ifdef DEBUG
  always @(posedge clk)
    if (clk_en)
      case (state)
        STATE_INIT:                               #0 $display("%m         STATE_INIT");
        STATE_NEXT_IMG:                           #0 $display("%m         STATE_NEXT_IMG");
        STATE_REPEAT:                             #0 $display("%m         STATE_REPEAT");
        STATE_NEXT_MB:                            #0 $display("%m         STATE_NEXT_MB");
        STATE_WAIT:                               #0 $display("%m         STATE_WAIT");
        STATE_WR_OSD_MSB:                         #0 $display("%m         STATE_WR_OSD_MSB");
        STATE_WR_OSD_LSB:                         #0 $display("%m         STATE_WR_OSD_LSB");
        STATE_WR_Y_MSB:                           #0 $display("%m         STATE_WR_Y_MSB");
        STATE_WR_Y_LSB:                           #0 $display("%m         STATE_WR_Y_LSB");
        STATE_WR_U_UPPER:                         #0 $display("%m         STATE_WR_U_UPPER");
        STATE_WR_U_LOWER:                         #0 $display("%m         STATE_WR_U_LOWER");
        STATE_WR_V_UPPER:                         #0 $display("%m         STATE_WR_V_UPPER");
        STATE_WR_V_LOWER:                         #0 $display("%m         STATE_WR_V_LOWER");
        default                                   #0 $display("%m         *** Error: unknown state %d", state);
      endcase

  always @(posedge clk)
    if (clk_en && (state == STATE_INIT))
      $strobe("%m\toutput_frame: %d output_frame_valid: %d progressive_sequence: %d progressive_frame: %d top_field_first: %d repeat_first_field: %d mb_width: %d mb_height: %d", output_frame, output_frame_valid, progressive_sequence, progressive_frame, top_field_first, repeat_first_field, mb_width, mb_height);

  always @(posedge clk)
    if (clk_en && (state == STATE_NEXT_IMG))
      $strobe("%m\timage: %d image_0: %d image_1: %d image_2: %d image_3: %d image_4: %d image_5: %d", image, image_0, image_1, image_2, image_3, image_4, image_5);

  always @(posedge clk)
    if (clk_en) 
      $strobe("%m\tstate: %d image: %d disp_frame: %d disp_comp: %d disp_mb: %d disp_x: %d disp_y: %d disp_delta_x: %d disp_delta_y: %d disp_mv_x: %d disp_mv_y: %d disp_valid_in: %d resample_wr_dta: %d resample_wr_en: %d",
                   state, image, disp_frame, disp_comp, disp_mb, disp_x, disp_y, disp_delta_x, disp_delta_y, disp_mv_x, disp_mv_y, disp_valid_in, resample_wr_dta, resample_wr_en);
`endif
endmodule
/* not truncated */
