/* 
 * mixer.v
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
 * mixer: synchronize pixels to video h_sync, v_sync
 */

 /*
  * HDMI Specification 1.0:
  *   6.4 Pixel-Repetition
  *   Video formats with native pixel rates below 25 Mpixels/sec require pixel-repetition in order to be
  *   carried across a TMDS link. 720x480i and 720x576i video format timings shall always be pixel-repeated.
  *
  * Here: if pixel_repetition repetition is asserted, each pixel is duplicated.
  */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

module mixer(
  clk, clk_en, rst, 
  pixel_repetition,
  y_in, u_in, v_in, osd_in, position_in, pixel_rd_en, pixel_rd_valid, pixel_rd_underflow,
  h_pos, v_pos, h_sync_in, v_sync_in, pixel_en_in,
  y_out, u_out, v_out, osd_out, h_sync_out, v_sync_out, pixel_en_out,
  dbg_lines_displayed, dbg_first_vpos, dbg_last_vpos,             // DVD-FORK DEBUG (256-line strobe probe)
  disp_v_offset                                                   // DVD-FORK (CRT anamorphic letterbox bar offset)
  );

  input              clk;                      // clock
  input              clk_en;                   // clock enable
  input              rst;                      // synchronous active low reset

  input              pixel_repetition;         // if asserted, repeat each pixel once

  /* from pixel_queue fifo */
  input         [7:0]y_in;
  input         [7:0]u_in;
  input         [7:0]v_in;
  input         [7:0]osd_in;
  input         [2:0]position_in;
  output reg         pixel_rd_en;
  input              pixel_rd_valid;
  input              pixel_rd_underflow; // if pixel_rd_underflow we're outputting pixels faster than we're computing them
 
  /* from video sync generator */
  input        [11:0]h_pos;
  input        [11:0]v_pos;
  input              h_sync_in;
  input              v_sync_in;
  input              pixel_en_in;

  /* to dvi transmitter */
  output reg    [7:0]y_out;
  output reg    [7:0]u_out;
  output reg    [7:0]v_out;
  output reg    [7:0]osd_out;
  output reg         h_sync_out;
  output reg         v_sync_out;
  output reg         pixel_en_out;

  /* DVD-FORK DEBUG (256-line strobe probe): per-output-frame instrumentation,
   * latched at end of frame (on v_sync_out rising edge) so emu reads a stable value.
   * Underflow was confirmed ZERO on HW, so these now report the on-screen BAND of the
   * displayed picture (which v_pos lines actually got pixels) to reconcile the line
   * count with what is seen:
   *  - dbg_lines_displayed : number of lines displayed this frame (STATE_FIRST_PIXEL).
   *  - dbg_first_vpos      : v_pos of the FIRST displayed (non-blanked) pixel (0xFFF none).
   *  - dbg_last_vpos       : v_pos of the LAST displayed pixel this frame. */
  output reg   [11:0]dbg_lines_displayed;
  output reg   [11:0]dbg_first_vpos;
  output reg   [11:0]dbg_last_vpos;

  /* DVD-FORK (CRT anamorphic letterbox, 2026-07-05): raster v_pos of the first
   * displayed picture line (the top black bar height, in woven frame lines). The
   * picture frame-top (ROW_0_COL_0 top field / ROW_1_COL_0 bottom field) is held in
   * STATE_WAIT until v_pos reaches this offset, so lines 0..offset-1 stay at the mixer's
   * black default (top bar); the picture then fills down and runs out before the raster
   * bottom (bottom bar is automatic). v_pos is the woven frame-line number in BOTH
   * progressive (v_cntr) and interlaced (2*v_cntr+parity, syncgen.v) modes, so one value
   * serves both paths (letterbox = vertical_size/8; FIT/ZOOM = 0). At offset 0 the two
   * comparisons below reduce to the original (v_pos<=1) / (v_pos!=0 && v_pos!=1) — the
   * FIT path is bit-identical. Quasi-static (menu-rate) level. */
  input        [11:0]disp_v_offset;

  /* store pixel_queue fifo output */
  reg           [7:0]y_0;
  reg           [7:0]u_0;
  reg           [7:0]v_0;
  reg           [7:0]osd_0;
  reg           [2:0]position_in_0;
  reg                h_sync_0;
  reg                v_sync_0;
  reg                pixel_en_0;
  /* delay h_sync, v_sync, pixel_en by two clocks */
  reg                pixel_en_1;
  reg                h_sync_1;
  reg                v_sync_1;

  reg                pixel_en_2;
  reg                h_sync_2;
  reg                v_sync_2;

`include "resample_codes.v"

  parameter [2:0]
    STATE_INIT               = 3'h0, /* read pixel queue until the first pixel of a line is found */
    STATE_WAIT               = 3'h1, /* wait until first pixel of the line will be displayed */
    STATE_FIRST_PIXEL        = 3'h2, /* display first pixel of the line */
    STATE_REPEAT_FIRST_PIXEL = 3'h3, /* pixel repetition */
    STATE_PIXEL              = 3'h4, /* display pixels */
    STATE_REPEAT_PIXEL       = 3'h5, /* pixel repetition */
    STATE_LAST_PIXEL         = 3'h6, /* display last pixel of the line */
    STATE_REPEAT_LAST_PIXEL  = 3'h7; /* pixel repetition */
  
  reg          [2:0]state;
  reg          [2:0]next;

  wire              first_pixel_read    = (pixel_rd_valid && ((position_in == ROW_0_COL_0) || (position_in == ROW_1_COL_0) || (position_in == ROW_X_COL_0)))      // first pixel at fifo output
                                                         || ((position_in_0 == ROW_0_COL_0) || (position_in_0 == ROW_1_COL_0) || (position_in_0 == ROW_X_COL_0)); // first pixel already stored
  // DVD-FORK FIX (interlaced 3:2 field-parity / black fields): a field's first line
  // carries ROW_0_COL_0 (top field) or ROW_1_COL_0 (bottom field); upstream only START a
  // frame when that code matches the syncgen's free-running v_pos parity (ROW_0@v_pos0,
  // ROW_1@v_pos1). But 3:2 pulldown repeats a field, so the content field sequence is NOT
  // strictly alternating (…T,B,T,T,B…); the repeated/boundary field then arrives on the
  // OPPOSITE parity slot, never matches, and the mixer emits 0 lines = a BLACK field (black
  // frame in bob, woven scanlines/"pulse" in weave). Fix: treat EITHER frame-top code as a
  // frame start whenever v_pos is at the top of the active region (0 or 1), so every field
  // displays regardless of its parity. Cost: a field landing on the off-parity slot is
  // offset <=1 line (irrelevant for bob; minor weave comb on 3:2 boundary frames only).
  // Progressive/strobe path is unchanged: FRAME emits ROW_0_COL_0 and lands at v_pos 0.
  wire              is_frame_top        = (position_in_0 == ROW_0_COL_0) || (position_in_0 == ROW_1_COL_0);
  /* DVD-FORK (CRT anamorphic letterbox): the frame-top window and the "not-frame-top"
   * line gate are shifted by disp_v_offset (0 in FIT/ZOOM => bit-identical to upstream's
   * v_pos 0/1). The picture starts at v_pos==offset (top field, even) / offset+1 (bottom
   * field, odd), giving a centred top bar. */
  wire              display_first_pixel = (h_pos == 12'd0) && ((is_frame_top && (v_pos >= disp_v_offset) && (v_pos <= disp_v_offset + 12'd1)) ||
                                                               ((position_in_0 == ROW_X_COL_0) && (v_pos != disp_v_offset) && (v_pos != disp_v_offset + 12'd1)));
  wire              last_pixel_read     = pixel_rd_valid && (position_in == ROW_X_COL_LAST);

  /* next state logic */
  always @*
    case (state)
      STATE_INIT:               if (first_pixel_read) next = STATE_WAIT;
                                else next = STATE_INIT;

      STATE_WAIT:               if (pixel_en_in && display_first_pixel) next = STATE_FIRST_PIXEL;
                                else next = STATE_WAIT;

      STATE_FIRST_PIXEL:        if (pixel_repetition) next = STATE_REPEAT_FIRST_PIXEL;
				else next = STATE_PIXEL;

      STATE_REPEAT_FIRST_PIXEL: next = STATE_PIXEL;

      STATE_PIXEL:              if (pixel_rd_underflow) next = STATE_INIT; 
				else if (pixel_repetition) next = STATE_REPEAT_PIXEL;
                                else if (last_pixel_read) next = STATE_LAST_PIXEL;
                                else next = STATE_PIXEL;

      STATE_REPEAT_PIXEL:       if (pixel_rd_underflow) next = STATE_INIT;
                                else if (last_pixel_read) next = STATE_LAST_PIXEL;
                                else next = STATE_PIXEL;
   
      STATE_LAST_PIXEL:         if (pixel_repetition) next = STATE_REPEAT_LAST_PIXEL;
                                else next = STATE_INIT;

      STATE_REPEAT_LAST_PIXEL:  next = STATE_INIT;

      default                   next = STATE_INIT;

    endcase

  /* state */
  always @(posedge clk)
    if(~rst) state <= STATE_INIT;
    else if (clk_en) state <= next;

  /* registers */
  /* store pixel_fifo output */
  always @(posedge clk)
    if (~rst) y_0 <= 8'd0;
    else if (clk_en && pixel_rd_valid) y_0 <= y_in;
    else y_0 <= y_0;

  always @(posedge clk)
    if (~rst) u_0 <= 8'd0;
    else if (clk_en && pixel_rd_valid) u_0 <= u_in;
    else u_0 <= u_0;

  always @(posedge clk)
    if (~rst) v_0 <= 8'd0;
    else if (clk_en && pixel_rd_valid) v_0 <= v_in;
    else v_0 <= v_0;

  always @(posedge clk)
    if (~rst) osd_0 <= 8'd0;
    else if (clk_en && pixel_rd_valid) osd_0 <= osd_in;
    else osd_0 <= osd_0;

  always @(posedge clk)
    if (~rst) position_in_0 <= ROW_X_COL_X;
    else if (clk_en && pixel_rd_valid) position_in_0 <= position_in;
    else position_in_0 <= position_in_0;

  /* read from pixel_fifo */
  always @(posedge clk)
    if (~rst) pixel_rd_en <= 1'b0;
    else if (clk_en)
      case (state)
        STATE_INIT:               pixel_rd_en <= ~pixel_rd_en && ~first_pixel_read;
	STATE_WAIT:               pixel_rd_en <= 1'b0;
	STATE_FIRST_PIXEL:        pixel_rd_en <= ~pixel_repetition;
	STATE_REPEAT_FIRST_PIXEL: pixel_rd_en <= 1'b1;
	STATE_PIXEL:              pixel_rd_en <= ~pixel_repetition && ~last_pixel_read; // stop if last pixel of this line read
	STATE_REPEAT_PIXEL:       pixel_rd_en <= ~last_pixel_read;
	STATE_LAST_PIXEL:         pixel_rd_en <= 1'b0;
        STATE_REPEAT_LAST_PIXEL:  pixel_rd_en <= 1'b0;
	default                   pixel_rd_en <= 1'b0;
      endcase

  /* delay sync gen output */
  always @(posedge clk)
    if (~rst) h_sync_0 <= 1'b0;
    else if (clk_en) h_sync_0 <= h_sync_in;

  always @(posedge clk)
    if (~rst) v_sync_0 <= 1'b0;
    else if (clk_en) v_sync_0 <= v_sync_in;

  always @(posedge clk)
    if (~rst) pixel_en_0 <= 1'b0;
    else if (clk_en) pixel_en_0 <= pixel_en_in;

  /* default values of y_out, u_out and v_out are 16, 128, 128, which maps onto black */

  wire displaying = (state == STATE_FIRST_PIXEL) || 
                    (state == STATE_REPEAT_FIRST_PIXEL) || 
	            (state == STATE_PIXEL) || 
	            (state == STATE_REPEAT_PIXEL) || 
	            (state == STATE_LAST_PIXEL) ||
	            (state == STATE_REPEAT_LAST_PIXEL);

  always @(posedge clk)
    if (~rst) y_out <= 8'b0;
    else if (clk_en && pixel_en_2 && displaying) y_out <= y_0;
    else if (clk_en) y_out <= 8'd16;

  always @(posedge clk)
    if (~rst) u_out <= 8'b0;
    else if (clk_en && pixel_en_2 && displaying) u_out <= u_0;
    else if (clk_en) u_out <= 8'd128;

  always @(posedge clk)
    if (~rst) v_out <= 8'b0;
    else if (clk_en && pixel_en_2 && displaying) v_out <= v_0;
    else if (clk_en) v_out <= 8'd128;

  always @(posedge clk)
    if (~rst) osd_out <= 8'b0;
    else if (clk_en && pixel_en_2 && displaying) osd_out <= osd_0;
    else if (clk_en) osd_out <= 8'd0;

 /*
  * delay h_sync, v_sync, pixel_en_out by two clocks
  */

  always @(posedge clk)
    if (~rst) pixel_en_1 <= 1'b0;
    else if (clk_en) pixel_en_1 <= pixel_en_0;

  always @(posedge clk)
    if (~rst) h_sync_1 <= 1'b0;
    else if (clk_en) h_sync_1 <= h_sync_0;

  always @(posedge clk)
    if (~rst) v_sync_1 <= 1'b0;
    else if (clk_en) v_sync_1 <= v_sync_0;

  always @(posedge clk)
    if (~rst) pixel_en_2 <= 1'b0;
    else if (clk_en) pixel_en_2 <= pixel_en_1;

  always @(posedge clk)
    if (~rst) h_sync_2 <= 1'b0;
    else if (clk_en) h_sync_2 <= h_sync_1;

  always @(posedge clk)
    if (~rst) v_sync_2 <= 1'b0;
    else if (clk_en) v_sync_2 <= v_sync_1;

  always @(posedge clk)
    if (~rst) pixel_en_out <= 1'b0;
    else if (clk_en) pixel_en_out <= pixel_en_2;

  always @(posedge clk)
    if (~rst) h_sync_out <= 1'b0;
    else if (clk_en) h_sync_out <= h_sync_2;

  always @(posedge clk)
    if (~rst) v_sync_out <= 1'b0;
    else if (clk_en) v_sync_out <= v_sync_2;

  /* DVD-FORK DEBUG (256-line strobe probe) ------------------------------------
   * Count displayed lines + capture underflow position, per output frame.
   * A line is "displayed" when the FSM enters STATE_FIRST_PIXEL (next==FP from
   * STATE_WAIT). Latch the running tallies on the v_sync_out rising edge.       */
  reg        v_sync_out_dly;
  reg [11:0] lines_run;        // displayed lines so far this frame
  reg [11:0] first_vpos_run;   // v_pos of first displayed pixel this frame (0xFFF = none yet)
  reg [11:0] last_vpos_run;    // v_pos of last displayed pixel this frame
  wire       line_started = (state == STATE_WAIT) && (next == STATE_FIRST_PIXEL);
  wire       displaying_now = (pixel_en_2 && displaying);   // a real pixel is being emitted
  always @(posedge clk)
    if (~rst) begin
      v_sync_out_dly <= 1'b0; lines_run <= 12'd0; first_vpos_run <= 12'hfff; last_vpos_run <= 12'd0;
      dbg_lines_displayed <= 12'd0; dbg_first_vpos <= 12'hfff; dbg_last_vpos <= 12'd0;
    end else if (clk_en) begin
      v_sync_out_dly <= v_sync_out;
      if (v_sync_out && ~v_sync_out_dly) begin           // start of a new output frame
        dbg_lines_displayed <= lines_run;                // latch previous frame's tallies
        dbg_first_vpos      <= first_vpos_run;
        dbg_last_vpos       <= last_vpos_run;
        lines_run      <= 12'd0;
        first_vpos_run <= 12'hfff;
        last_vpos_run  <= 12'd0;
      end else begin
        if (line_started && (lines_run != 12'hfff)) lines_run <= lines_run + 12'd1;
        if (displaying_now) begin
          if (first_vpos_run == 12'hfff) first_vpos_run <= v_pos;  // first displayed line
          last_vpos_run <= v_pos;                                   // keeps the last
        end
      end
    end

`ifdef DEBUG
  always @(posedge clk)
    case (state)
      STATE_INIT:                               #0 $display("%m         STATE_INIT");
      STATE_WAIT:                               #0 $display("%m         STATE_WAIT");
      STATE_FIRST_PIXEL:                        #0 $display("%m         STATE_FIRST_PIXEL");
      STATE_REPEAT_FIRST_PIXEL:                 #0 $display("%m         STATE_REPEAT_FIRST_PIXEL");
      STATE_PIXEL:                              #0 $display("%m         STATE_PIXEL");
      STATE_REPEAT_PIXEL:                       #0 $display("%m         STATE_REPEAT_PIXEL");
      STATE_LAST_PIXEL:                         #0 $display("%m         STATE_LAST_PIXEL");
      STATE_REPEAT_LAST_PIXEL:                  #0 $display("%m         STATE_REPEAT_LAST_PIXEL");
      default                                   #0 $display("%m         *** Error: unknown state %d", state);
    endcase

  always @(posedge clk)
    $strobe("%m\tstate: %d y_in %d u_in %d v_in %d osd_in %d position_in %d pixel_rd_en %d pixel_rd_valid %d h_pos %d v_pos %d h_sync_in %d v_sync_in %d pixel_en_in %d y_out %d u_out %d v_out %d osd_out %d h_sync_out %d v_sync_out %d pixel_en_out %d", 
                 state, y_in, u_in, v_in, osd_in, position_in, pixel_rd_en, pixel_rd_valid, h_pos, v_pos, h_sync_in, v_sync_in, pixel_en_in, y_out, u_out, v_out, osd_out, h_sync_out, v_sync_out, pixel_en_out);

`endif
endmodule
/* not truncated */
