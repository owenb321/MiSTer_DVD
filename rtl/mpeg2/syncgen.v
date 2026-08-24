/* 
 * syncgen.v
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
 * sync_gen - Sync generator.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

/*
 * Generates horizontal and vertical synchronisation and timing.
 *
 * Inputs:
 *
 * horizontal_size, vertical_size, display_horizontal_size, and display_vertical_size
 * are parameters extracted from the MPEG2 bitstream. 
 * horizontal_size and vertical_size determine the size of the reconstructed bitmap in frame memory;
 * display_horizontal_size and display_vertical_size - if non-zero - are the displayable part of this bitmap.
 *
 * horizontal_resolution, horizontal_sync_start, horizontal_sync_end, horizontal_length,
 * vertical_resolution, vertical_sync_start, vertical_sync_end, horizontal_halfline and vertical_length determine video timing.
 *                                       
 * The timing parameters can be deduced from the X11 modeline for the display.
 * See "XFree86 Video Timings HOWTO".
 *
 * Note vertical_resolution, vertical_sync_start, vertical_sync_end and vertical_length refer to a frame if
 * progressive, and to a field if interlaced.
 *
 * For instance, vertical_resolution is number of visible lines per frame if progressive,
 * and number of visible lines per field if interlaced.
 *
 * If 'interlaced' is asserted, vertical sync is delayed one-half scan line at the end of odd frames.
 * This is similar to "interlace sync and video mode" of the mc6845 crtc.
 *
 * Outputs:
 * h_pos and v_pos are the coordinates of the current pixel.
 * pixel_en is not asserted if blanking is required.
 * h_sync and v_sync are horizontal and vertical synchronisation,
 * respectively.
 *
 */

module sync_gen    (clk, clk_en, rst,
                   horizontal_size, vertical_size, display_horizontal_size, display_vertical_size,
                   horizontal_resolution, horizontal_sync_start, horizontal_sync_end, horizontal_length,
                   vertical_resolution, vertical_sync_start, vertical_sync_end, horizontal_halfline, vertical_length,
                   interlaced, clip_display_size,
                   h_pos, v_pos, pixel_en, h_sync, v_sync, c_sync, h_blank, v_blank);

  input            clk;
  input            clk_en;
  input            rst;

  input      [13:0]horizontal_size;               /* par. 6.2.2.1, par. 6.3.3 */
  input      [13:0]vertical_size;                 /* par. 6.2.2.1, par. 6.3.3 */
  input      [13:0]display_horizontal_size;       /* par. 6.2.2.4, par. 6.3.6 */
  input      [13:0]display_vertical_size;         /* par. 6.2.2.4, par. 6.3.6 */

  input      [11:0]horizontal_resolution;         /* horizontal resolution. number of dots per line */
  input      [11:0]horizontal_sync_start;         /* the dot the horizontal sync pulse begins. */
  input      [11:0]horizontal_sync_end;           /* the dot the horizontal sync pulse ends. */
  input      [11:0]horizontal_length;             /* total horizontal length */
  input      [11:0]vertical_resolution;           /* vertical resolution. number of visible lines per frame (progressive) or field (interlaced) */
  input      [11:0]vertical_sync_start;           /* the line number within the frame (progressive) or field (interlaced) the vertical sync pulse begins. */
  input      [11:0]vertical_sync_end;             /* the line number within the frame (progressive) or field (interlaced) the vertical sync pulse ends. */
  input      [11:0]horizontal_halfline;           /* the dot the vertical sync begins on odd frames of interlaced video. Not used in progressive mode. */
  input      [11:0]vertical_length;               /* total number of lines of a vertical frame (progressive) or field (interlaced) */
  input            interlaced;                    /* asserted if interlaced output required. */
  input            clip_display_size;             /* assert to clip image to (display_horizontal_size, display_vertical_size) */

  output reg [11:0]h_pos;                         /* horizontal position */
  output reg [11:0]v_pos;                         /* vertical position */
  output reg       pixel_en;                      /* pixel enable, asserted when pixel drawn */
  output reg       h_sync;                        /* horizontal sync */
  output reg       v_sync;                        /* vertical sync */
  output reg       c_sync;                        /* complex sync */
  output reg       h_blank;                       /* horizontal blanking */
  output reg       v_blank;                       /* vertical blanking */

  /* 
   * general registers 
   */

  reg        [11:0]h_size;
  reg        [11:0]h_display_size;
  reg        [11:0]v_size;
  reg        [11:0]v_display_size;
  reg        [11:0]v_sync_h_pos;
  reg              odd_field;

  /*
   * v_sync_h_pos: horizontal position of vertical sync.
   * In progressive video,  the vertical sync begins at horizontal position 0,
   * In interlaced video:
   *  - in even fields, vertical sync begins at horizontal position 0
   *  - in odd fields,  vertical sync is delayed horizontal_halfline dots. 
   *  A common value for horizontal_halfline is horizontal_length/2.
   */

  always @(posedge clk)
    if (~rst) v_sync_h_pos <= 12'd0;
    else if (clk_en) v_sync_h_pos <= (interlaced && odd_field) ? horizontal_halfline : 12'd0;
    else v_sync_h_pos <= v_sync_h_pos;

  /*
   * for h_display_size and v_display_size:
   * display_horizontal_size and display_vertical_size are optional mpeg2 parameters.
   * If display_horizontal_size and display_vertical_size are  zero, the whole frame is displayable; use horizontal_size and vertical_size instead.
   * If display_horizontal_size and display_vertical_size are non-zero, only display_horizontal_size by display_vertical_size of the frame is displayable.
   */

  always @(posedge clk)
    if (~rst) h_display_size <= 12'd0;
    else if (clk_en) h_display_size <= ((display_horizontal_size != 0) && clip_display_size) ? display_horizontal_size[11:0] : ((horizontal_size != 0) ? horizontal_size[11:0] : horizontal_resolution); 
    else h_display_size <= h_display_size;

  always @(posedge clk)
    if (~rst) v_display_size <= 12'd0;
    else if (clk_en && interlaced) v_display_size <= ((display_vertical_size != 0) && clip_display_size) ? display_vertical_size[11:1] : ((vertical_size != 0) ? vertical_size[11:1] : vertical_resolution[11:1]); // interlacing; one field contains half the visible lines.
    else if (clk_en) v_display_size <= ((display_vertical_size != 0) && clip_display_size) ? display_vertical_size[11:0] : ((vertical_size != 0) ? vertical_size[11:0] : vertical_resolution); // no interlacing; one frame contains all visible lines.
    else v_display_size <= v_display_size;

  always @(posedge clk)
    if (~rst) h_size <= 12'd0;
    else if (clk_en) h_size <= (horizontal_size != 0) ? horizontal_size[11:0] : horizontal_resolution;
    else h_size <= h_size;

  always @(posedge clk)
    if (~rst) v_size <= 12'd0;
    else if (clk_en && interlaced) v_size <= (vertical_size != 0) ? vertical_size[11:1] : vertical_resolution[11:1];
    else if (clk_en) v_size <= (vertical_size != 0) ? vertical_size[11:0] : vertical_resolution;
    else v_size <= v_size;
 
  /* 
   * Stage 0
   */

  reg        [11:0]h_cntr;
  reg        [11:0]v_cntr;

  /* horizontal counter */
  always @(posedge clk)
    if (~rst) h_cntr <= 12'd0;
    else if (clk_en) h_cntr <= (h_cntr >= horizontal_length) ? 12'd0 : (h_cntr + 1);
    else h_cntr <= h_cntr;

  /* vertical counter */
  always @(posedge clk)
    if (~rst) v_cntr <= 12'd0;
    else if (clk_en && (h_cntr >= horizontal_length)) v_cntr <= (v_cntr >= vertical_length) ? 12'd0 : (v_cntr + 1);
    else v_cntr <= v_cntr;

  /* 
   * Stage 1
   */
 
  reg        [11:0]h_cntr_1;
  reg        [11:0]v_cntr_1;
  reg              h_blank_1;
  reg              v_blank_1;
  reg              h_sync_1;
  reg              v_sync_1;

  always @(posedge clk)
    if (~rst) h_cntr_1 <= 12'd0;
    else if (clk_en) h_cntr_1 <= h_cntr;
    else h_cntr_1 <= h_cntr_1;

  always @(posedge clk)
    if (~rst) v_cntr_1 <= 12'd0;
    else if (clk_en) v_cntr_1 <= v_cntr;
    else v_cntr_1 <= v_cntr_1;

  /* horizontal synchronisation */
  always @(posedge clk)
    if (~rst) h_sync_1 <= 1'b0;
    else if (clk_en) h_sync_1 <= (h_cntr >= horizontal_sync_start) && (h_cntr <= horizontal_sync_end);
    else h_sync_1 <= h_sync_1;

  /* horizontal blanking */
  always @(posedge clk)
    if (~rst) h_blank_1 <= 1'b1;
    else if (clk_en) h_blank_1 <= (h_cntr >= horizontal_resolution) || (h_cntr >= h_size) || (h_cntr >= h_display_size);
    else h_blank_1 <= h_blank_1;

  /* vertical synchronisation */
  always @(posedge clk)
    if (~rst) v_sync_1 <= 1'b0;
    else if (clk_en) v_sync_1 <= ((v_cntr == vertical_sync_start) && (h_cntr >= v_sync_h_pos)) 
                              || ((v_cntr > vertical_sync_start) && (v_cntr < vertical_sync_end))
                              || ((v_cntr == vertical_sync_end) && (h_cntr < v_sync_h_pos));
    else v_sync_1 <= v_sync_1;

  /* vertical blanking */
  always @(posedge clk)
    if (~rst) v_blank_1 <= 1'b1;
    else if (clk_en) v_blank_1 <= (v_cntr >= vertical_resolution) || (v_cntr >= v_size) || (v_cntr >= v_display_size);
    else v_blank_1 <= v_blank_1;

  /* 
   * odd_field is asserted during odd fields of interlaced pictures.
   * odd_field is not asserted when video is not interlaced.
   */

  always @(posedge clk)
    if (~rst) odd_field <= 1'b0;
    else if (clk_en && ~interlaced) odd_field <= 1'b0;
    else if (clk_en && interlaced && (h_cntr == 12'b0) && (v_cntr == 12'b0)) odd_field <= ~odd_field; // when interlaced, toggle 
    else odd_field <= odd_field;

  /* 
   * Stage 2
   */

  reg        [11:0]h_cntr_2;
  reg        [11:0]v_cntr_2;
  reg              h_blank_2;
  reg              v_blank_2;
  reg              h_sync_2;
  reg              v_sync_2;

  always @(posedge clk)
    if (~rst) h_cntr_2 <= 12'd0;
    else if (clk_en) h_cntr_2 <= h_cntr_1;
    else h_cntr_2 <= h_cntr_2;

  always @(posedge clk)
    if (~rst) v_cntr_2 <= 12'd0;
    else if (clk_en) v_cntr_2 <= v_cntr_1;
    else v_cntr_2 <= v_cntr_2;

  always @(posedge clk)
    if (~rst) h_blank_2 <= 1'b1;
    else if (clk_en) h_blank_2 <= h_blank_1;
    else h_blank_2 <= h_blank_2;

  always @(posedge clk)
    if (~rst) v_blank_2 <= 1'b1;
    else if (clk_en) v_blank_2 <= v_blank_1;
    else v_blank_2 <= v_blank_2;

  always @(posedge clk)
    if (~rst) h_sync_2 <= 1'b0;
    else if (clk_en) h_sync_2 <= h_sync_1;
    else h_sync_2 <= h_sync_2;

  always @(posedge clk)
    if (~rst) v_sync_2 <= 1'b0;
    else if (clk_en) v_sync_2 <= v_sync_1;
    else v_sync_2 <= v_sync_2;

  /*
   * horizontal coordinate
   */

  always @(posedge clk)
    if (~rst) h_pos <= 12'd0;
    else if (clk_en) h_pos <= h_cntr_2;
    else h_pos <= h_pos;

  /*
   * vertical coordinate: line number.
   * If progressive, v_pos sequences through the line number 0, 1, 2, 3, 4, 5, ...
   * If interlaced, v_pos sequences through even numbers on odd fields 0, 2, 4, ...
   * and through odd numbers on even fields 1, 3, 5, ...
   * (This is because tv people start counting from 1, not 0.)
   */

  always @(posedge clk)
    if (~rst) v_pos <= 12'd0;
    else if (clk_en) v_pos <= interlaced ? { v_cntr_2[10:0], ~odd_field } : v_cntr_2;
    else v_pos <= v_pos;

  always @(posedge clk)
    if (~rst) h_sync <= 1'b0;
    else if (clk_en) h_sync <= h_sync_2;
    else h_sync <= h_sync;

  always @(posedge clk)
    if (~rst) v_sync <= 1'b0;
    else if (clk_en) v_sync <= v_sync_2;
    else v_sync <= v_sync;

  always @(posedge clk)
    if (~rst) h_blank <= 1'b1;
    else if (clk_en) h_blank <= h_blank_2;
    else h_blank <= h_blank;

  always @(posedge clk)
    if (~rst) v_blank <= 1'b1;
    else if (clk_en) v_blank <= v_blank_2;
    else v_blank <= v_blank;

  /*
   * pixel enable
   */

  always @(posedge clk)
    if (~rst) pixel_en <= 1'd0;
    else if (clk_en) pixel_en <= ~h_blank_2 && ~v_blank_2;
    else pixel_en <= pixel_en;

  /*
   * composite sync
   */

  always @(posedge clk)
    if (~rst) c_sync <= 1'b0;
    else if (clk_en) c_sync <= ~(h_sync_2 ^ v_sync_2);
    else c_sync <= c_sync;

`ifdef DEBUG
  always @(posedge clk)
      begin
            $strobe("%m\th_pos: %4d v_pos: %4d h_cntr: %4d v_cntr: %4d h_sync: %d v_sync: %d h_blank: %d v_blank: %d pixel_en: %d odd_field: %d v_sync_h_pos: %d h_display_size: %d v_display_size: %d h_size: %d v_size: %d",
                          h_pos, v_pos, h_cntr, v_cntr, h_sync, v_sync, h_blank, v_blank, pixel_en, odd_field, v_sync_h_pos, h_display_size, v_display_size, h_size, v_size);

            $strobe("%m\thorizontal_size: %d vertical_size: %d display_horizontal_size: %d display_vertical_size: %d horizontal_resolution: %d horizontal_sync_start: %d horizontal_sync_end: %d horizontal_length: %d",
                         horizontal_size, vertical_size, display_horizontal_size, display_vertical_size, horizontal_resolution, horizontal_sync_start, horizontal_sync_end, horizontal_length);

            $strobe("%m\tvertical_resolution: %d vertical_sync_start: %d vertical_sync_end: %d horizontal_halfline: %d vertical_length: %d interlaced: %d",
                        vertical_resolution, vertical_sync_start, vertical_sync_end, horizontal_halfline, vertical_length, interlaced);

            $strobe("%m\t%4d.%4d h_sync: %0d v_sync: %0d h_blank: %0d v_blank: %0d pixel_en: %0d", h_pos, v_pos, h_sync, v_sync, h_blank, v_blank, pixel_en);

            $strobe("sync2graph %0d %0d %d %d %d", h_pos, v_pos, h_sync, v_sync, pixel_en); // for sync2graph testbench
      end
`endif
endmodule
/* not truncated */
