/* 
 * syncgen_intf.v
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
 * syncgen_intf - interface between decoder clock region and video
 * synchronization generator.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

module syncgen_intf    
                  (clk, clk_en, rst,
                   horizontal_size, vertical_size, display_horizontal_size, display_vertical_size,
                   syncgen_rst,
                   horizontal_resolution, horizontal_sync_start, horizontal_sync_end, horizontal_length,
                   vertical_resolution, vertical_sync_start, vertical_sync_end, horizontal_halfline, vertical_length,
                   interlaced, clip_display_size, pixel_repetition,
                   h_pos, v_pos, pixel_en, h_sync, v_sync, c_sync, h_blank, v_blank);

  input            clk;
  input            clk_en;
  input            rst;

  input      [13:0]horizontal_size;               /* par. 6.2.2.1, par. 6.3.3 */
  input      [13:0]vertical_size;                 /* par. 6.2.2.1, par. 6.3.3 */
  input      [13:0]display_horizontal_size;       /* par. 6.2.2.4, par. 6.3.6 */
  input      [13:0]display_vertical_size;         /* par. 6.2.2.4, par. 6.3.6 */

  input            syncgen_rst;                   /* reset sync generator whenever modeline parameter is changed */
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
  input            pixel_repetition;              /* asserted if each pixel drawn twice */
  input            clip_display_size;             /* assert to clip image to (display_horizontal_size, display_vertical_size) */

  output     [11:0]h_pos;                         /* horizontal position */
  output     [11:0]v_pos;                         /* vertical position */
  output           pixel_en;                      /* pixel enable, asserted when pixel drawn */
  output           h_sync;                        /* horizontal sync */
  output           v_sync;                        /* vertical sync */
  output           c_sync;                        /* complex sync */
  output           h_blank;                       /* horizontal blanking */
  output           v_blank;                       /* vertical blanking */

  wire             dot_syncgen_rst;               /* sync generator reset, synchronized to dot_clk */
  wire       [13:0]dot_horizontal_size;
  wire       [13:0]dot_vertical_size;
  wire       [13:0]dot_display_horizontal_size;
  wire       [13:0]dot_display_vertical_size;
  wire       [11:0]dot_horizontal_resolution;
  wire       [11:0]dot_horizontal_sync_start;
  wire       [11:0]dot_horizontal_sync_end;
  wire       [11:0]dot_horizontal_length;
  wire       [11:0]dot_vertical_resolution;
  wire       [11:0]dot_vertical_sync_start;
  wire       [11:0]dot_vertical_sync_end;
  wire       [11:0]dot_horizontal_halfline;
  wire       [11:0]dot_vertical_length;
  wire             dot_interlaced;
  wire             dot_pixel_repetition;
  wire             dot_clip_display_size;

  /* 
   * Synchronize sync generator reset signal with dot clock.
   */


  sync_reset syncgen_sreset (
    .clk(clk),
    .asyncrst(syncgen_rst),
    .syncrst(dot_syncgen_rst)
     );

  /* 
   * Synchronize video parameters with dot clock 
   */

  sync_reg #(.width(14)) sync_horizontal_size (
    .clk(clk),
    .rst(rst),
    .asyncreg(horizontal_size),
    .syncreg(dot_horizontal_size)
    );

  sync_reg #(.width(14)) sync_vertical_size (
    .clk(clk),
    .rst(rst),
    .asyncreg(vertical_size),
    .syncreg(dot_vertical_size)
    );

  sync_reg #(.width(14)) sync_display_horizontal_size (
    .clk(clk),
    .rst(rst),
    .asyncreg(display_horizontal_size),
    .syncreg(dot_display_horizontal_size)
    );

  sync_reg #(.width(14)) sync_display_vertical_size (
    .clk(clk),
    .rst(rst),
    .asyncreg(display_vertical_size),
    .syncreg(dot_display_vertical_size)
    );

  sync_reg #(.width(12)) sync_horizontal_resolution (
    .clk(clk),
    .rst(rst),
    .asyncreg(horizontal_resolution),
    .syncreg(dot_horizontal_resolution)
    );

  sync_reg #(.width(12)) sync_horizontal_sync_start (
    .clk(clk),
    .rst(rst),
    .asyncreg(horizontal_sync_start),
    .syncreg(dot_horizontal_sync_start)
    );

  sync_reg #(.width(12)) sync_horizontal_sync_end (
    .clk(clk),
    .rst(rst),
    .asyncreg(horizontal_sync_end),
    .syncreg(dot_horizontal_sync_end)
    );

  sync_reg #(.width(12)) sync_horizontal_length (
    .clk(clk),
    .rst(rst),
    .asyncreg(horizontal_length),
    .syncreg(dot_horizontal_length)
    );

  sync_reg #(.width(12)) sync_vertical_resolution (
    .clk(clk),
    .rst(rst),
    .asyncreg(vertical_resolution),
    .syncreg(dot_vertical_resolution)
    );

  sync_reg #(.width(12)) sync_vertical_sync_start (
    .clk(clk),
    .rst(rst),
    .asyncreg(vertical_sync_start),
    .syncreg(dot_vertical_sync_start)
    );

  sync_reg #(.width(12)) sync_vertical_sync_end (
    .clk(clk),
    .rst(rst),
    .asyncreg(vertical_sync_end),
    .syncreg(dot_vertical_sync_end)
    );

  sync_reg #(.width(12)) sync_horizontal_halfline (
    .clk(clk),
    .rst(rst),
    .asyncreg(horizontal_halfline),
    .syncreg(dot_horizontal_halfline)
    );

  sync_reg #(.width(12)) sync_vertical_length (
    .clk(clk),
    .rst(rst),
    .asyncreg(vertical_length),
    .syncreg(dot_vertical_length)
    );

  sync_reg #(.width(1)) sync_interlaced (
    .clk(clk),
    .rst(rst),
    .asyncreg(interlaced),
    .syncreg(dot_interlaced)
    );

  sync_reg #(.width(1)) sync_pixel_repetition (
    .clk(clk),
    .rst(rst),
    .asyncreg(pixel_repetition),
    .syncreg(dot_pixel_repetition)
    );

  sync_reg #(.width(1)) sync_clip_display_size (
    .clk(clk),
    .rst(rst),
    .asyncreg(clip_display_size),
    .syncreg(dot_clip_display_size)
    );

  /* 
   * Pixel repetition
   */

  reg        [13:0]syncgen_horizontal_size;
  reg        [13:0]syncgen_display_horizontal_size;
  reg        [11:0]syncgen_horizontal_resolution;
  reg        [11:0]syncgen_horizontal_sync_start;
  reg        [11:0]syncgen_horizontal_sync_end;
  reg        [11:0]syncgen_horizontal_length;
  reg        [11:0]syncgen_horizontal_halfline;

  always @(posedge clk)
    if (~rst) syncgen_horizontal_size <= 14'b0;
    else if (clk_en) syncgen_horizontal_size <= dot_pixel_repetition ? {dot_horizontal_size[12:0], 1'b0} : dot_horizontal_size;
    else syncgen_horizontal_size <= syncgen_horizontal_size;

  always @(posedge clk)
    if (~rst) syncgen_display_horizontal_size <= 14'b0;
    else if (clk_en) syncgen_display_horizontal_size <= (dot_pixel_repetition && (dot_display_horizontal_size != 14'd0)) ? {dot_display_horizontal_size[12:0], 1'b1} : dot_display_horizontal_size;
    else syncgen_display_horizontal_size <= syncgen_display_horizontal_size;

  always @(posedge clk)
    if (~rst) syncgen_horizontal_resolution <= 12'b0;
    else if (clk_en) syncgen_horizontal_resolution <= dot_pixel_repetition ? {dot_horizontal_resolution[10:0], 1'b1} : dot_horizontal_resolution;
    else syncgen_horizontal_resolution <= syncgen_horizontal_resolution;

  always @(posedge clk)
    if (~rst) syncgen_horizontal_sync_start <= 12'b0;
    else if (clk_en) syncgen_horizontal_sync_start <= dot_pixel_repetition ? {dot_horizontal_sync_start[10:0], 1'b1} : dot_horizontal_sync_start;
    else syncgen_horizontal_sync_start <= syncgen_horizontal_sync_start;

  always @(posedge clk)
    if (~rst) syncgen_horizontal_sync_end <= 12'b0;
    else if (clk_en) syncgen_horizontal_sync_end <= dot_pixel_repetition ? {dot_horizontal_sync_end[10:0], 1'b1} : dot_horizontal_sync_end;
    else syncgen_horizontal_sync_end <= syncgen_horizontal_sync_end;

  always @(posedge clk)
    if (~rst) syncgen_horizontal_length <= 12'b0;
    else if (clk_en) syncgen_horizontal_length <= dot_pixel_repetition ? {dot_horizontal_length[10:0], 1'b1} : dot_horizontal_length;
    else syncgen_horizontal_length <= syncgen_horizontal_length;

  always @(posedge clk)
    if (~rst) syncgen_horizontal_halfline <= 12'b0;
    else if (clk_en) syncgen_horizontal_halfline <= dot_pixel_repetition ? {dot_horizontal_halfline[10:0], 1'b1}     : dot_horizontal_halfline;
    else syncgen_horizontal_halfline <= syncgen_horizontal_halfline;

  /* 
   * Synchronisation generator
   */

  sync_gen sync_gen (
    .clk(clk), 
    .clk_en(clk_en), 
    .rst(dot_syncgen_rst), 
    .horizontal_size(syncgen_horizontal_size), 
    .vertical_size(dot_vertical_size), 
    .display_horizontal_size(syncgen_display_horizontal_size), 
    .display_vertical_size(dot_display_vertical_size), 
    .horizontal_resolution(syncgen_horizontal_resolution), 
    .horizontal_sync_start(syncgen_horizontal_sync_start), 
    .horizontal_sync_end(syncgen_horizontal_sync_end), 
    .horizontal_length(syncgen_horizontal_length), 
    .vertical_resolution(dot_vertical_resolution), 
    .vertical_sync_start(dot_vertical_sync_start), 
    .vertical_sync_end(dot_vertical_sync_end), 
    .horizontal_halfline(syncgen_horizontal_halfline), 
    .vertical_length(dot_vertical_length), 
    .interlaced(dot_interlaced), 
    .clip_display_size(dot_clip_display_size), 
    .h_pos(h_pos), 
    .v_pos(v_pos), 
    .pixel_en(pixel_en), 
    .h_sync(h_sync), 
    .v_sync(v_sync), 
    .c_sync(c_sync), 
    .h_blank(h_blank), 
    .v_blank(v_blank)
    );

endmodule
/* not truncated */
