/* 
 * motcomp_picbuf.v
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
 * motcomp_picbuf.v - Motion compensation: picture buffer management
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

`undef CHECK
`ifdef __IVERILOG__
`define CHECK 1
`endif

module motcomp_picbuf(
  clk, clk_en, rst,
  source_select, 
  progressive_sequence, progressive_frame, top_field_first, repeat_first_field, last_frame,
  picture_coding_type,
  forward_reference_frame, backward_reference_frame, current_frame,
  output_frame, output_frame_valid, output_frame_rd, output_progressive_sequence, output_progressive_frame, output_top_field_first, output_repeat_first_field, 
  update_picture_buffers, picbuf_busy
  );

  input              clk;                          // clock
  input              clk_en;                       // clock enable
  input              rst;                          // synchronous active low reset

  input         [2:0]source_select;                // select video out source
  input         [2:0]picture_coding_type;          // identifies whether a picture is an I, P or B picture.
  input              progressive_sequence;
  input              progressive_frame;
  input              top_field_first;
  input              repeat_first_field;
  input              last_frame;                   // asserted when frame is the last frame of a bitstream

  /* saved values */
  reg           [2:0]vld_picture_coding_type;
  reg                vld_progressive_sequence;
  reg                vld_progressive_frame;
  reg                vld_top_field_first;
  reg                vld_repeat_first_field;
  reg                vld_last_frame;

  /* picture buffers */
  output reg    [2:0]forward_reference_frame;      /* forward reference frame. Has value 2'd0 or 2'd1 */
  output reg    [2:0]backward_reference_frame;     /* backward reference frame. Has value 2'd0 or 2'd1 */

  reg           [2:0]aux_frame;                    /* auxiliary frame 1. Has value 2'd2 or 2'd3 */
  reg           [2:0]prev_aux_frame;

  output reg    [2:0]current_frame;                /* current frame being decoded */
  reg                current_frame_valid;
  reg           [2:0]current_frame_coding_type;    /* I, P or B-TYPE */
  reg                current_frame_progressive_sequence;
  reg                current_frame_progressive_frame;
  reg                current_frame_top_field_first;
  reg                current_frame_repeat_first_field;

  output reg    [2:0]output_frame;                 /* frame being displayed */
  output reg         output_frame_valid;           /* asserted during one clock cycle */
  input              output_frame_rd;              /* asserted when output_frame read */

  output reg         output_progressive_sequence;
  output reg         output_progressive_frame;
  output reg         output_top_field_first;
  output reg         output_repeat_first_field;
  output reg         picbuf_busy;

  input              update_picture_buffers;

  reg                prev_output_frame_valid;

  reg           [2:0]prev_i_p_frame;               /* previous I or P frame */
  reg                prev_i_p_frame_valid;         /* high if previous I or P frame exists, low when no previous I or P frame exists (at video sequence start) */
  reg                prev_i_p_frame_progressive_sequence;
  reg                prev_i_p_frame_progressive_frame;
  reg                prev_i_p_frame_top_field_first;
  reg                prev_i_p_frame_repeat_first_field;

`include "vld_codes.v"

  parameter     [3:0]
    STATE_IDLE         = 4'h0,
    STATE_UPDATE       = 4'h1,
    STATE_IP_FRAME_0   = 4'h2,
    STATE_IP_FRAME_1   = 4'h3,
    STATE_B_FRAME_0    = 4'h4,
    STATE_B_FRAME_1    = 4'h5,
    STATE_LAST_FRAME   = 4'h6,
    STATE_WAIT_0       = 4'h7,
    STATE_WAIT_1       = 4'h8,
    STATE_SRC_SELECT_0 = 4'h9,
    STATE_SRC_SELECT_1 = 4'ha;

  reg           [3:0]state;
  reg           [3:0]next;

  /* 
   * We need to synchronize motion compensation (computing the next image) and
   * resampling (showing the previous image). These processes run at different
   * speeds.
   *
   * goals:
   * - start decoding the next picture as soon as possible
   * - don't overwrite a picture which still needs to be displayed
   *
   * if (output_frame_rd == 1'b1): resampling finished the previous image, and wants the next image.
   * if (picbuf_busy == 1'b1): next image computed.
   */

  /* next state */
  always @*
    case (state)
                                 /* Wait until next frame decoded (picbuf_busy asserted) */
      STATE_IDLE:                if ((source_select != 3'd0) && ~source_select[2]) next = STATE_IDLE; // blank screen if source_select == 3'd1..3
                                 else if ((source_select != 3'd0) && source_select[2])next = STATE_SRC_SELECT_0; // next image forced through "source select" if source_select == 3'd4..7
                                 else if (picbuf_busy) next = STATE_UPDATE; // next frame
                                 else next = STATE_IDLE; // blank screen

                                 /* update forward reference frame, backward reference frame, current frame, output frame. */
      STATE_UPDATE:              if (vld_last_frame) next = STATE_LAST_FRAME;
                                 else if (vld_picture_coding_type == B_TYPE) next = STATE_B_FRAME_0; /* next frame is B-frame */
                                 else next = STATE_IP_FRAME_0; /* next frame is I- or P-frame */

                                 /* I-frame. wait until resample has finished showing previous frame, and wants to show this frame */
      STATE_IP_FRAME_0:          if (~output_frame_valid) next = STATE_IP_FRAME_1; // there's no previous I/P frame to show, start decoding right away
                                 else if (output_frame_rd) next = STATE_IP_FRAME_1; // resample has picked up previous I/P frame, start decoding
                                 else next = STATE_IP_FRAME_0;

                                 /* drop picbuf_busy. start decoding I or P-frame */
      STATE_IP_FRAME_1:          next = STATE_WAIT_1;  // wait until resample has finished showing previous I- or P-frame 

                                 /* B-frame. drop picbuf_busy, start decoding B-frame */
      STATE_B_FRAME_0:           next = STATE_B_FRAME_1;  

                                 /* wait until B-frame has been decoded (picbuf_busy high). Then raise output_frame_valid. */
      STATE_B_FRAME_1:           if (picbuf_busy) next = STATE_WAIT_0; 
                                 else next = STATE_B_FRAME_1;

      STATE_LAST_FRAME:          next = STATE_WAIT_0; // show last frame; start decoding next video

                                 /* wait until resample has finished showing the previous frame, and wants to show this frame */
      STATE_WAIT_0:              if (~output_frame_valid) next = STATE_IDLE;
                                 else if (output_frame_rd) next = STATE_WAIT_1;
                                 else next = STATE_WAIT_0;

                                 /* drop output_frame_valid, wait for output_frame_rd to drop */
      STATE_WAIT_1:              if (~output_frame_rd) next = STATE_IDLE;
                                 else next = STATE_WAIT_1;

                                 /* source_select is set. display selected frame and raise output_frame_valid. wait for resample to assert output_frame_rd */
      STATE_SRC_SELECT_0:        if (output_frame_rd) next = STATE_SRC_SELECT_1;
                                 else next = STATE_SRC_SELECT_0;
                                 
                                 /* drop output_frame_valid. wait for resample to drop output_frame_rd; then go to the next frame */
      STATE_SRC_SELECT_1:        if (~output_frame_rd) next = STATE_IDLE;
                                 else next = STATE_SRC_SELECT_1;

      default                    next  = STATE_IDLE;
    endcase

  /* state */
  always @(posedge clk)
    if(~rst) state <= STATE_IDLE;
    else if (clk_en) state <= next;
    else state <= state;

  /* 
   * clock enable for variable-length decoding; 
   * pause variable-length decoding 
   *
   */

  always @(posedge clk)
    if (~rst) picbuf_busy <= 1'd0;
    else if (clk_en && update_picture_buffers) picbuf_busy <= 1'b1;
    else if (clk_en && ((state == STATE_IP_FRAME_1) || (state == STATE_B_FRAME_0) || (state == STATE_LAST_FRAME))) picbuf_busy <= 1'b0;
    else picbuf_busy <= picbuf_busy;

  /*
   * Save vld values
   */

  always @(posedge clk)
    if (~rst) 
      begin
        vld_picture_coding_type <= 3'd0;
        vld_progressive_sequence <= 1'b0;
        vld_progressive_frame <= 1'b0;
        vld_top_field_first <= 1'b0;
        vld_repeat_first_field <= 1'b0;
        vld_last_frame <= 1'b0;
      end
    else if (clk_en && update_picture_buffers) 
      begin
        vld_picture_coding_type <= picture_coding_type;
        vld_progressive_sequence <= progressive_sequence;
        vld_progressive_frame <= progressive_frame;
        vld_top_field_first <= top_field_first;
        vld_repeat_first_field <= repeat_first_field;
        vld_last_frame <= last_frame;
      end
    else 
      begin
        vld_picture_coding_type <= vld_picture_coding_type;
        vld_progressive_sequence <= vld_progressive_sequence;
        vld_progressive_frame <= vld_progressive_frame;
        vld_top_field_first <= vld_top_field_first;
        vld_repeat_first_field <= vld_repeat_first_field;
        vld_last_frame <= vld_last_frame;
      end

  /*
   * current frame
   * If we're decoding a B picture, we store it in the auxiliary frame.
   * This is acceptable as no future pictures will use the B picture as reference frame.
   */

  always @(posedge clk)
    if (~rst) 
      begin
        current_frame <= 3'b0;
        current_frame_valid <= 1'b0;
        current_frame_coding_type <= I_TYPE;
        current_frame_progressive_sequence <= 1'b0;
        current_frame_progressive_frame <= 1'b0;
        current_frame_top_field_first <= 1'b0;
        current_frame_repeat_first_field <= 1'b0;
      end 
    else if (clk_en && (state == STATE_UPDATE) && (vld_picture_coding_type != B_TYPE) && ~vld_last_frame)
      begin
        current_frame <= forward_reference_frame;
        current_frame_valid <= 1'b1;
        current_frame_coding_type <= vld_picture_coding_type;
        current_frame_progressive_sequence <= vld_progressive_sequence;
        current_frame_progressive_frame <= vld_progressive_frame;
        current_frame_top_field_first <= vld_top_field_first;
        current_frame_repeat_first_field <= vld_repeat_first_field;
      end
    else if (clk_en && (state == STATE_UPDATE) && (vld_picture_coding_type == B_TYPE) && ~vld_last_frame)
      begin
        current_frame <= aux_frame;
        current_frame_valid <= 1'b1;
        current_frame_coding_type <= vld_picture_coding_type;
        current_frame_progressive_sequence <= vld_progressive_sequence;
        current_frame_progressive_frame <= vld_progressive_frame;
        current_frame_top_field_first <= vld_top_field_first;
        current_frame_repeat_first_field <= vld_repeat_first_field;
      end
    else
      begin
        current_frame <= current_frame;
        current_frame_valid <= current_frame_valid;
        current_frame_coding_type <= current_frame_coding_type;
        current_frame_progressive_sequence <= current_frame_progressive_sequence;
        current_frame_progressive_frame <= current_frame_progressive_frame;
        current_frame_top_field_first <= current_frame_top_field_first;
        current_frame_repeat_first_field <= current_frame_repeat_first_field;
      end

  /*
   If we are decoding an I or P picture,
   the old backward reference frame becomes the new forward reference frame,
   while the old forward reference frame is overwritten with the current frame and becomes the new backward reference frame.
   This is ok as decoding the I or P pictures doesn't need the old backward reference frame, 
   and subsequent B pictures will use the I or P picture being decoded as backward reference frame.
   */

  always @(posedge clk)
    if (~rst) forward_reference_frame <= 3'd0;
    else if (clk_en && (state == STATE_UPDATE) && (vld_picture_coding_type != B_TYPE)) forward_reference_frame <= backward_reference_frame;
    else forward_reference_frame <= forward_reference_frame;

  always @(posedge clk)
    if (~rst) backward_reference_frame <= 3'd1;
    else if (clk_en && (state == STATE_UPDATE) && (vld_picture_coding_type != B_TYPE)) backward_reference_frame <= forward_reference_frame;
    else backward_reference_frame <= backward_reference_frame;

  always @(posedge clk)
    if (~rst) aux_frame <= 3'd2;
    else if (clk_en && (state == STATE_UPDATE) && (vld_picture_coding_type == B_TYPE)) aux_frame <= prev_aux_frame;
    else aux_frame <= aux_frame;

  always @(posedge clk)
    if (~rst) prev_aux_frame <= 3'd3;
    else if (clk_en && (state == STATE_UPDATE) && (vld_picture_coding_type == B_TYPE)) prev_aux_frame <= aux_frame;
    else prev_aux_frame <= prev_aux_frame;

  /* 
   * prev_i_p_frame stores the previous I or P frame. 
   * prev_i_p_frame_valid is zero if no previous I or P frame exists, e,g, at video start.
   */

  always @(posedge clk)
    if (~rst) 
      begin
        prev_i_p_frame <= 3'b0;
        prev_i_p_frame_valid <= 1'b0;
        prev_i_p_frame_progressive_sequence <= 1'b0;
        prev_i_p_frame_progressive_frame <= 1'b0;
        prev_i_p_frame_top_field_first <= 1'b0;
        prev_i_p_frame_repeat_first_field <= 1'b0;
      end
    else if (clk_en && update_picture_buffers && (current_frame_coding_type != B_TYPE) && ~vld_last_frame) 
      begin
        prev_i_p_frame <= current_frame;
        prev_i_p_frame_valid <= current_frame_valid;
        prev_i_p_frame_progressive_sequence <= current_frame_progressive_sequence;
        prev_i_p_frame_progressive_frame <= current_frame_progressive_frame;
        prev_i_p_frame_top_field_first <= current_frame_top_field_first;
        prev_i_p_frame_repeat_first_field <= current_frame_repeat_first_field;
      end
    /*
     * Clear prev_i_p_frame_valid, in case a (new) mpeg2 stream comes after the last frame 
     */ 
    else if (clk_en && (state == STATE_LAST_FRAME))
      begin
        prev_i_p_frame <= prev_i_p_frame;
        prev_i_p_frame_valid <= 1'b0;
        prev_i_p_frame_progressive_sequence <= prev_i_p_frame_progressive_sequence;
        prev_i_p_frame_progressive_frame <= prev_i_p_frame_progressive_frame;
        prev_i_p_frame_top_field_first <= prev_i_p_frame_top_field_first;
        prev_i_p_frame_repeat_first_field <= prev_i_p_frame_repeat_first_field;
      end
    else
      begin
        prev_i_p_frame <= prev_i_p_frame;
        prev_i_p_frame_valid <= prev_i_p_frame_valid;
        prev_i_p_frame_progressive_sequence <= prev_i_p_frame_progressive_sequence;
        prev_i_p_frame_progressive_frame <= prev_i_p_frame_progressive_frame;
        prev_i_p_frame_top_field_first <= prev_i_p_frame_top_field_first;
        prev_i_p_frame_repeat_first_field <= prev_i_p_frame_repeat_first_field;
      end

  /*
   * output frame selection
   *
   * par. 6.1.1.11 Frame reordering
   *
   * ... sequence re-ordering is performed according to the following rules:
   * If the current frame in coded order is a B-frame the output frame is the frame reconstructed from that B-frame.
   * If the current frame in coded order is a I-frame or P-frame the output frame is the frame reconstructed
   * from the previous I-frame or P-frame if one exists. If none exists, at the start of the sequence, no frame is output.
   * The frame reconstructed from the final I-frame or P-frame in the sequence is output immediately after the
   * frame reconstructed when the last coded frame in the sequence was removed from the VBV buffer.
   *
   */

  always @(posedge clk)
    if (~rst)
      begin
        output_frame                  <= 3'd0;
        output_frame_valid            <= 1'b0;
        output_progressive_sequence   <= 1'b0;
        output_progressive_frame      <= 1'b0;
        output_top_field_first        <= 1'b0;
        output_repeat_first_field     <= 1'b0;
        prev_output_frame_valid       <= 1'b0;
      end
    else if (clk_en && (state == STATE_IDLE))
      begin
        output_frame                  <= output_frame;
        output_frame_valid            <= 1'b0;
        output_progressive_sequence   <= output_progressive_sequence;
        output_progressive_frame      <= output_progressive_frame;
        output_top_field_first        <= output_top_field_first;
        output_repeat_first_field     <= output_repeat_first_field;
        prev_output_frame_valid       <= prev_output_frame_valid;
      end
    /*
     * Emit last frame of sequence 
     */
    else if (clk_en && (state == STATE_LAST_FRAME)) /* emit last frame: Emit last decoded I or P frame */
      begin
        output_frame                  <= prev_i_p_frame;
        output_frame_valid            <= prev_i_p_frame_valid;
        output_progressive_sequence   <= prev_i_p_frame_progressive_sequence;
        output_progressive_frame      <= prev_i_p_frame_progressive_frame;
        output_top_field_first        <= prev_i_p_frame_top_field_first;
        output_repeat_first_field     <= prev_i_p_frame_repeat_first_field;
        prev_output_frame_valid       <= prev_i_p_frame_valid;
      end
    /*
     * Emit B-frame 
     */
    else if (clk_en && (state == STATE_B_FRAME_1) && (next == STATE_WAIT_0))
      begin
        output_frame                  <= current_frame;
        output_frame_valid            <= current_frame_valid;
        output_progressive_sequence   <= current_frame_progressive_sequence;
        output_progressive_frame      <= current_frame_progressive_frame;
        output_top_field_first        <= current_frame_top_field_first;
        output_repeat_first_field     <= current_frame_repeat_first_field;
        prev_output_frame_valid       <= current_frame_valid;
      end
    /*
     * Emit I-/P-frame 
     */
    else if (clk_en && (state == STATE_UPDATE) && (next == STATE_IP_FRAME_0))
      begin
        output_frame                  <= prev_i_p_frame;
        output_frame_valid            <= prev_i_p_frame_valid;
        output_progressive_sequence   <= prev_i_p_frame_progressive_sequence;
        output_progressive_frame      <= prev_i_p_frame_progressive_frame;
        output_top_field_first        <= prev_i_p_frame_top_field_first;
        output_repeat_first_field     <= prev_i_p_frame_repeat_first_field;
        prev_output_frame_valid       <= prev_i_p_frame_valid;
      end
    /*
     * Housekeeping 
     */
    else if (clk_en && ((state == STATE_WAIT_1) || (state == STATE_SRC_SELECT_1) || (state == STATE_IP_FRAME_1)))
      begin
        output_frame                  <= output_frame;
        output_frame_valid            <= output_frame_rd; // drop output_frame_valid when output_frame_rd is lowered
        output_progressive_sequence   <= output_progressive_sequence;
        output_progressive_frame      <= output_progressive_frame;
        output_top_field_first        <= output_top_field_first;
        output_repeat_first_field     <= output_repeat_first_field;
        prev_output_frame_valid       <= prev_output_frame_valid;
      end
    /*
     * source select
     */
    else if (clk_en && (state == STATE_SRC_SELECT_0)) /* force frame */
      begin
        output_frame                  <= source_select[1:0];
        output_frame_valid            <= source_select[2];
        output_progressive_sequence   <= progressive_sequence;
        output_progressive_frame      <= progressive_frame;
        output_top_field_first        <= top_field_first;
        output_repeat_first_field     <= 1'b0;
        prev_output_frame_valid       <= source_select[2];
      end
    else /* no change */
      begin
        output_frame                  <= output_frame;
        output_frame_valid            <= output_frame_valid;
        output_progressive_sequence   <= output_progressive_sequence;
        output_progressive_frame      <= output_progressive_frame;
        output_top_field_first        <= output_top_field_first;
        output_repeat_first_field     <= output_repeat_first_field;
        prev_output_frame_valid       <= prev_output_frame_valid;
      end

`ifdef DEBUG

  always @(posedge clk)
    case (state)
      STATE_IDLE:                               #0 $display("%m\tSTATE_IDLE");
      STATE_UPDATE:                             #0 $display("%m\tSTATE_UPDATE");
      STATE_IP_FRAME_0:                         #0 $display("%m\tSTATE_IP_FRAME_0");
      STATE_IP_FRAME_1:                         #0 $display("%m\tSTATE_IP_FRAME_1");
      STATE_B_FRAME_0:                          #0 $display("%m\tSTATE_B_FRAME_0");
      STATE_B_FRAME_1:                          #0 $display("%m\tSTATE_B_FRAME_1");
      STATE_WAIT_0:                             #0 $display("%m\tSTATE_WAIT_0");
      STATE_WAIT_1:                             #0 $display("%m\tSTATE_WAIT_1");
      STATE_SRC_SELECT_0:                       #0 $display("%m\tSTATE_SRC_SELECT_0");
      STATE_SRC_SELECT_1:                       #0 $display("%m\tSTATE_SRC_SELECT_1");
      default                                   #0 $display("%m\t*** Error: unknown state %d", state);
    endcase

  always @(posedge clk)
    begin 
      $strobe("%m\tupdate_picture_buffers: %d output_frame_rd: %d picbuf_busy: %d", 
                   update_picture_buffers, output_frame_rd, picbuf_busy);

      $strobe("%m\tforward_reference_frame: %d backward_reference_frame: %d aux_frame: %d prev_aux_frame: %d current_frame: %d",
                   forward_reference_frame, backward_reference_frame, aux_frame, prev_aux_frame, current_frame);

      $strobe("%m\tcurrent_frame_coding_type: %d output_frame: %d output_frame_valid: %d prev_i_p_frame: %d prev_i_p_frame_valid: %d",
                   current_frame_coding_type, output_frame, output_frame_valid, prev_i_p_frame, prev_i_p_frame_valid);
    end 

`endif
endmodule

/* not truncated */
