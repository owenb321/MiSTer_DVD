/* 
 * motcomp_addrgen.v
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

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

/*
 * motcomp_addrgen - Motion compensation address generator. Handles 4:2:0 only.
 */

 /*
  par. 7.6.4, Forming Predictions:
   A positive value of the horizontal component of a motion vector indicates that the prediction is made from samples (in the reference field/frame) that lie to the right of the samples being predicted.
   A positive value of the vertical component of a motion vector indicates that the prediction is made from samples (in the reference field/frame) that lie below the samples being predicted.
   All motion vectors are specified to an accuracy of one half sample.
   Thus, if a component of the motion vector is odd, the samples will be read from mid-way between the actual samples in the reference field/frame.
   These half-samples are calculated by simple linear interpolation from the actual samples.
 */

module motcomp_addrgen(
  clk, clk_en, rst, 
  mvec_rd_en, mvec_rd_valid, 
  picture_coding_type, picture_structure, motion_type, dct_type,
  macroblock_address, macroblock_motion_forward, macroblock_motion_backward, macroblock_intra,
  mb_width, mb_height, horizontal_size, vertical_size, chroma_format,
  pmv_0_0_0, pmv_0_0_1, pmv_1_0_0, pmv_1_0_1, pmv_0_1_0, pmv_0_1_1, pmv_1_1_0, pmv_1_1_1,
  dmv_0_0, dmv_0_1, dmv_1_0, dmv_1_1,
  motion_vert_field_select_0_0, motion_vert_field_select_0_1, motion_vert_field_select_1_0, motion_vert_field_select_1_1,
  second_field, progressive_sequence, progressive_frame, top_field_first, repeat_first_field, last_frame, update_picture_buffers, motion_vector_valid,
  source_select,
  fwd_wr_addr_en, fwd_wr_addr, fwd_wr_addr_almost_full,
  bwd_wr_addr_en, bwd_wr_addr, bwd_wr_addr_almost_full,
  dst_wr_en, dst_wr_write_recon, dst_wr_write_address, dst_wr_almost_full,
  dst_wr_motion_forward, dst_wr_fwd_hor_offset, dst_wr_fwd_hor_halfpixel, dst_wr_fwd_ver_halfpixel,
  dst_wr_motion_backward, dst_wr_bwd_hor_offset, dst_wr_bwd_hor_halfpixel, dst_wr_bwd_ver_halfpixel,
  output_frame, output_frame_valid, output_frame_rd, output_progressive_sequence, output_progressive_frame, output_top_field_first, output_repeat_first_field, picbuf_busy,
  dct_block_cmd, dct_block_en, dct_block_wr_almost_full
  );

`include "motcomp_dctcodes.v"

  input              clk;                          // clock
  input              clk_en;                       // clock enable
  input              rst;                          // synchronous active low reset
  output reg         mvec_rd_en;                   // motion vector fifo read enable
  input              mvec_rd_valid;                // motion vector fifo read valid

  input         [2:0]picture_coding_type;          // identifies whether a picture is an I, P or B picture.
  input         [1:0]picture_structure;            // one of FRAME_PICTURE, TOP_FIELD or BOTTOM_FIELD
  input         [1:0]motion_type;                  // one of MC_FIELD, MC_FRAME, MC_16X8 or MC_DMV
  input              dct_type;                     // dct_type == 1 : field dct coded; dct_type == 0 : frame dct coded
  input        [12:0]macroblock_address;           // absolute position of the current macroblock. top-left macroblock has macroblock_address zero.
  input              macroblock_motion_forward;
  input              macroblock_motion_backward;
  input              macroblock_intra;
  input         [7:0]mb_width;                     // par. 6.3.3. width of the encoded luminance component of pictures in macroblocks
  input         [7:0]mb_height;                    // par. 6.3.3. height of the encoded luminance component of frame pictures in macroblocks
  input        [13:0]horizontal_size;              // par. 6.2.2.1, par. 6.3.3
  input        [13:0]vertical_size;                // par. 6.2.2.1, par. 6.3.3 
  input         [1:0]chroma_format;
  input              motion_vert_field_select_0_0; // motion_vertical_field_select. Indicates which reference field shall be used to form the prediction.
                                                   // If motion_vertical_field_select[r][s] is zero, then the top reference field shall be used,
                                                   // if it is one then the bottom reference field shall be used.
  input              motion_vert_field_select_0_1;
  input              motion_vert_field_select_1_0;
  input              motion_vert_field_select_1_1;
  input              second_field;
  input signed [12:0]pmv_0_0_0;                    // predicted motion vector
  input signed [12:0]pmv_0_0_1;                    // predicted motion vector
  input signed [12:0]pmv_1_0_0;                    // predicted motion vector
  input signed [12:0]pmv_1_0_1;                    // predicted motion vector
  input signed [12:0]pmv_0_1_0;                    // predicted motion vector
  input signed [12:0]pmv_0_1_1;                    // predicted motion vector
  input signed [12:0]pmv_1_1_0;                    // predicted motion vector
  input signed [12:0]pmv_1_1_1;                    // predicted motion vector
  input signed [12:0]dmv_0_0;                      // dual-prime motion vector.
  input signed [12:0]dmv_0_1;                      // dual-prime motion vector.
  input signed [12:0]dmv_1_0;                      // dual-prime motion vector.
  input signed [12:0]dmv_1_1;                      // dual-prime motion vector.
  input              progressive_sequence;
  input              progressive_frame;
  input              top_field_first;
  input              repeat_first_field;

  input              last_frame;
  input              update_picture_buffers;
  input              motion_vector_valid;
  /* trick modes */
  input         [2:0]source_select;                 /* select video out source */

`include "mem_codes.v"
`include "vld_codes.v"

  /* picture buffers */
  reg               do_update_picture_buffers;
  wire         [2:0]forward_reference_frame;      /* forward reference frame. Has value 2'd0 or 2'd1 */
  wire         [2:0]backward_reference_frame;     /* backward reference frame. Has value 2'd0 or 2'd1 */
  wire         [2:0]current_frame;                /* current frame */
  output       [2:0]output_frame;                 /* frame to be displayed */
  output            output_frame_valid;           /* asserted when output_frame valid */
  input             output_frame_rd;              /* asserted to read next output_frame */
  output            output_progressive_sequence;
  output            output_progressive_frame;
  output            output_top_field_first;
  output            output_repeat_first_field;
  output            picbuf_busy;

  /* reading forward reference frame: writing address */
  input             fwd_wr_addr_almost_full;
  output            fwd_wr_addr_en;
  output      [21:0]fwd_wr_addr;

  /* reading backward reference frame: writing address */
  input             bwd_wr_addr_almost_full;
  output            bwd_wr_addr_en;
  output      [21:0]bwd_wr_addr;

  /* writing block reconstruction fifo */
  input             dst_wr_almost_full;
  output            dst_wr_en;
  output            dst_wr_write_recon;
  output      [21:0]dst_wr_write_address;
  output            dst_wr_motion_forward;
  output       [2:0]dst_wr_fwd_hor_offset;
  output            dst_wr_fwd_hor_halfpixel;
  output            dst_wr_fwd_ver_halfpixel;
  output            dst_wr_motion_backward;
  output       [2:0]dst_wr_bwd_hor_offset;
  output            dst_wr_bwd_hor_halfpixel;
  output            dst_wr_bwd_ver_halfpixel;

  /* field/frame dct decoding */
  input            dct_block_wr_almost_full;
  output      [2:0]dct_block_cmd;
  output           dct_block_en;

  /* motvec output */
  wire              frame_picture_0;
  wire              field_in_frame_0;
  wire        [12:0]macroblock_address_0;
  wire         [1:0]comp_0;
  wire signed [12:0]delta_x_0;
  wire signed [12:0]delta_y_0;
  wire         [2:0]fwd_src_frame_0;
  wire              fwd_src_field_0;
  wire signed [12:0]fwd_mv_x_0;
  wire signed [12:0]fwd_mv_y_0;
  wire              fwd_valid_0;
  wire         [2:0]bwd_src_frame_0;
  wire              bwd_src_field_0;
  wire signed [12:0]bwd_mv_x_0;
  wire signed [12:0]bwd_mv_y_0;
  wire              bwd_valid_0;
  wire         [2:0]recon_dst_frame_0;
  wire              recon_dst_field_0;
  wire signed [12:0]recon_delta_x_0;
  wire signed [12:0]recon_delta_y_0;
  wire              write_recon_0;
  wire              recon_valid_0;

  /* ripple counter */
  reg              column;
  reg signed  [3:0]row;
  reg signed  [3:0]last_row;
  reg         [1:0]block;
  reg         [1:0]comp;          /* COMP_Y, COMP_CR or COMP_CB */
  reg              mb_end;
  reg              motvec_update;
  reg              next_column;
  reg signed  [3:0]next_row;
  reg         [1:0]next_block;
  reg         [1:0]next_comp;
  reg              next_mb_end;

  /* basic motion compensation state machine  */

  parameter [2:0] 
    STATE_INIT        = 4'h0,      
    STATE_READ        = 4'h1,
    STATE_UPDATE      = 4'h2,      
    STATE_MOTVEC      = 4'h3,  
    STATE_NEXT        = 4'h4;

  reg         [2:0]state;
  reg         [2:0]next;

  /* next state logic */
  always @*
    case (state)
      STATE_INIT:         if (~mvec_rd_valid || fwd_wr_addr_almost_full || bwd_wr_addr_almost_full || dst_wr_almost_full || dct_block_wr_almost_full) next = STATE_INIT; // wait until mvec_rd_valid
                          else next = STATE_READ;

      STATE_READ:         if (mvec_rd_valid && update_picture_buffers) next = STATE_UPDATE; // update picture buffers
                          else if (mvec_rd_valid && motion_vector_valid) next = STATE_MOTVEC; // motion vector valid: process macroblock
                          else next = STATE_INIT;

      STATE_MOTVEC:       if (mb_end) next = STATE_NEXT;
                          else next = STATE_MOTVEC; // reconstruct pixels from predictions

      STATE_UPDATE:       next = STATE_NEXT; // perform picture buffer update

      STATE_NEXT:         next = STATE_INIT; // wait for clk_en; 

      default             next = STATE_INIT;

    endcase

  /* state */
  always @(posedge clk)
    if(~rst) state <= STATE_INIT;
    else if (clk_en) state <= next;
    else  state <= state;

  always @(posedge clk)
    if (~rst) mvec_rd_en <= 1'b0;
    else if (clk_en && (state == STATE_NEXT)) mvec_rd_en <= 1'b1;
    else if (clk_en) mvec_rd_en <= 1'b0;
    else mvec_rd_en <= 1'b0;

  always @(posedge clk)
    if(~rst) motvec_update <= 1'b0;
    else if (clk_en) motvec_update <= (next == STATE_MOTVEC);
    else  motvec_update <= motvec_update;

  /*
   This represents a "ripple counter" which cycles through all possible component/block/row/column combinations.

     4:2:0       
     Component   Block      Row    Column 
         Y       0..3       -1..7   0..1
         Cr      0..1       -1..3   0..1
         Cb      0..1       -1..3   0..1
   
    Luminance is reconstructed in blocks of 8x8 pixels.

    For horizontal halfpixel calculations, we need the pixel to the right of the current pixel.
    For vertical halfpixel calculations, we need the pixel below the current pixel.
    Hence, for reconstructing a 8x8 pixel block we need 9x9 pixels.
    As we retrieve pixels from memory 8 at a time, this means we need to retrieve 9x16 pixels from memory.
   
           | column 0               | column 1
    -------|------------------------+------------------------          
     row -1| 0  1  2  3  4  5  6  7 |  0  1  2  3  4  5  6  7          dst_wr_write_recon <= 1'b0. block: 0..3
     row 0 | 0  1  2  3  4  5  6  7 |  0  1  2  3  4  5  6  7          dst_wr_write_recon <= 1'b1.
     row 1 | 0  1  2  3  4  5  6  7 |  0  1  2  3  4  5  6  7          dst_wr_write_recon <= 1'b1.
     row 2 | 0  1  2  3  4  5  6  7 |  0  1  2  3  4  5  6  7          dst_wr_write_recon <= 1'b1.
     row 3 | 0  1  2  3  4  5  6  7 |  0  1  2  3  4  5  6  7          dst_wr_write_recon <= 1'b1.
     row 4 | 0  1  2  3  4  5  6  7 |  0  1  2  3  4  5  6  7          dst_wr_write_recon <= 1'b1.
     row 5 | 0  1  2  3  4  5  6  7 |  0  1  2  3  4  5  6  7          dst_wr_write_recon <= 1'b1.
     row 6 | 0  1  2  3  4  5  6  7 |  0  1  2  3  4  5  6  7          dst_wr_write_recon <= 1'b1.
     row 7 | 0  1  2  3  4  5  6  7 |  0  1  2  3  4  5  6  7          dst_wr_write_recon <= 1'b1.
    -------|------------------------+------------------------          

    The first row (16 pixels) is sent to motcomp_recon with dst_wr_write_recon <= 1'b0;
    causing recon to just load the row but not to write any reconstructed pixels to memory.
    The remaining 8 rows are sent to motcomp_recon with dst_wr_write_recon <= 1'b1.
    This causes recon not only to load the row, but also to write the reconstructed pixels to memory.

    For chrominance, reconstruction happens in "blocks" of 8x4 pixels.
    
           | column 0               | column 1
    -------|------------------------+------------------------          
     row -1| 0  1  2  3  4  5  6  7 |  0  1  2  3  4  5  6  7          dst_wr_write_recon <= 1'b0. block: 0..1
     row 0 | 0  1  2  3  4  5  6  7 |  0  1  2  3  4  5  6  7          dst_wr_write_recon <= 1'b1.
     row 1 | 0  1  2  3  4  5  6  7 |  0  1  2  3  4  5  6  7          dst_wr_write_recon <= 1'b1.
     row 2 | 0  1  2  3  4  5  6  7 |  0  1  2  3  4  5  6  7          dst_wr_write_recon <= 1'b1.
     row 3 | 0  1  2  3  4  5  6  7 |  0  1  2  3  4  5  6  7          dst_wr_write_recon <= 1'b1.
    -------|------------------------+------------------------          
 */

  always @(posedge  clk)
    if (~rst) last_row <= 4'd0;
    else if (clk_en && (state == STATE_INIT)) last_row <= 4'sd7;
    else if (clk_en && (state == STATE_MOTVEC) && (comp == COMP_Y)) last_row <= 4'sd7;
    else if (clk_en && (state == STATE_MOTVEC)) last_row <= 4'sd3;
    else last_row <= last_row;

  always @*
    next_column = ~column;
 
  always @*
    if ((row == last_row) && (column == 1'd1)) next_row = -4'sd1;
    else if (column == 1'd1) next_row = row + 4'sd1;
    else next_row = row;

  always @*
    if ((row == last_row) && (column == 1'd1) && (comp == COMP_Y)) next_block = block + 2'd1; // COMP_Y: 0 1 2 3 0
    else if ((row == last_row) && (column == 1'd1) && (block == 2'd0)) next_block = block + 2'd1; // COMP_CR/CB: 0 1 0
    else if ((row == last_row) && (column == 1'd1)) next_block = 2'd0;
    else next_block = block;

  always @*
    if ((row == last_row) && (column == 1'd1))
      case (comp)
        COMP_Y:     if (block == 2'd3) next_comp = COMP_CR;
                    else next_comp = COMP_Y;
        COMP_CR:    if (block == 2'd1) next_comp = COMP_CB;
                    else next_comp = COMP_CR;
        COMP_CB:    if (block == 2'd1) next_comp = COMP_Y;
                    else next_comp = COMP_CB;
        default     next_comp = COMP_Y;
      endcase
    else next_comp = comp;

  always @*
    if ((block == 2'd1) && (row == last_row) && (column == 1'd0) && (next_comp == COMP_CB)) next_mb_end = 1'b1;
    else next_mb_end = 1'b0;

  always @(posedge  clk)
    if (~rst) column <= 1'b0;
    else if (clk_en && (state == STATE_INIT)) column <= 1'b0;
    else if (clk_en && (state == STATE_MOTVEC)) column <= next_column;
    else column <= column;
    
  always @(posedge  clk)
    if (~rst) row <= -4'sd1;
    else if (clk_en && (state == STATE_INIT)) row <= -4'sd1;
    else if (clk_en && (state == STATE_MOTVEC)) row <= next_row;
    else row <= row;
    
  always @(posedge  clk)
    if (~rst) block <= 2'b0;
    else if (clk_en && (state == STATE_INIT)) block <= 2'b0;
    else if (clk_en && (state == STATE_MOTVEC)) block <= next_block;
    else block <= block;
    
  always @(posedge  clk)
    if (~rst) comp <= COMP_Y;
    else if (clk_en && (state == STATE_INIT)) comp <= COMP_Y;
    else if (clk_en && (state == STATE_MOTVEC)) comp <= next_comp;
    else comp <= comp;

  always @(posedge  clk)
    if (~rst) mb_end <= 1'b0;
    else if (clk_en && (state == STATE_INIT)) mb_end <= 1'b0;
    else if (clk_en && (state == STATE_MOTVEC)) mb_end <= next_mb_end;
    else mb_end <= mb_end;

  /* picture buffers */
  always @(posedge clk)
    if (~rst) do_update_picture_buffers <= 1'b0;
    else if (clk_en) do_update_picture_buffers <= (next == STATE_UPDATE);
    else do_update_picture_buffers <= do_update_picture_buffers;

  motcomp_picbuf picbuf (
    .clk(clk), 
    .clk_en(clk_en), 
    .rst(rst), 
    .source_select(source_select),                           // from regfile
    .picture_coding_type(picture_coding_type), 
    .progressive_sequence(progressive_sequence),             // from vld
    .progressive_frame(progressive_frame),                   // from vld
    .top_field_first(top_field_first),                       // from vld
    .repeat_first_field(repeat_first_field),                 // from vld
    .last_frame(last_frame),
    .update_picture_buffers(do_update_picture_buffers), 
    .forward_reference_frame(forward_reference_frame), 
    .backward_reference_frame(backward_reference_frame), 
    .current_frame(current_frame), 
    .output_frame(output_frame), 
    .output_frame_valid(output_frame_valid),
    .output_frame_rd(output_frame_rd),
    .output_progressive_sequence(output_progressive_sequence),// to resample
    .output_progressive_frame(output_progressive_frame),     // to resample
    .output_top_field_first(output_top_field_first),         // to resample
    .output_repeat_first_field(output_repeat_first_field),   // to resample
    .picbuf_busy(picbuf_busy)
    );

  /* motion vector selection */
  /* 
     Note motion vector is not constant for a macroblock.
     Some motion types have different motion vectors for the upper two blocks and the lower two blocks.
   */
  motcomp_motvec motvec (
    .clk(clk), 
    .clk_en(clk_en), 
    .rst(rst), 
    /* in */
    .picture_coding_type(picture_coding_type), 
    .picture_structure(picture_structure), 
    .motion_type(motion_type), 
    .dct_type(dct_type), 
    .macroblock_motion_forward(macroblock_motion_forward), 
    .macroblock_motion_backward(macroblock_motion_backward), 
    .macroblock_intra(macroblock_intra),
    .macroblock_address_in(macroblock_address),
    .pmv_0_0_0(pmv_0_0_0), 
    .pmv_0_0_1(pmv_0_0_1), 
    .pmv_1_0_0(pmv_1_0_0), 
    .pmv_1_0_1(pmv_1_0_1), 
    .pmv_0_1_0(pmv_0_1_0), 
    .pmv_0_1_1(pmv_0_1_1), 
    .pmv_1_1_0(pmv_1_1_0), 
    .pmv_1_1_1(pmv_1_1_1), 
    .dmv_0_0(dmv_0_0), 
    .dmv_0_1(dmv_0_1), 
    .dmv_1_0(dmv_1_0), 
    .dmv_1_1(dmv_1_1), 
    .motion_vert_field_select_0_0(motion_vert_field_select_0_0), 
    .motion_vert_field_select_0_1(motion_vert_field_select_0_1), 
    .motion_vert_field_select_1_0(motion_vert_field_select_1_0), 
    .motion_vert_field_select_1_1(motion_vert_field_select_1_1), 
    .second_field(second_field), 
    .forward_reference_frame(forward_reference_frame),
    .backward_reference_frame(backward_reference_frame),
    .current_frame(current_frame),
    .column(column),
    .row(row),
    .block(block),
    .comp(comp),
    .motvec_update(motvec_update), 
    /* out */
    .frame_picture(frame_picture_0), 
    .field_in_frame(field_in_frame_0), 
    .comp_out(comp_0),
    .macroblock_address_out(macroblock_address_0),
    .delta_x(delta_x_0), 
    .delta_y(delta_y_0), 
    .fwd_src_frame(fwd_src_frame_0), 
    .fwd_src_field(fwd_src_field_0), 
    .fwd_mv_x(fwd_mv_x_0), 
    .fwd_mv_y(fwd_mv_y_0), 
    .fwd_valid(fwd_valid_0), 
    .bwd_src_frame(bwd_src_frame_0), 
    .bwd_src_field(bwd_src_field_0), 
    .bwd_mv_x(bwd_mv_x_0), 
    .bwd_mv_y(bwd_mv_y_0), 
    .bwd_valid(bwd_valid_0), 
    .write_recon(write_recon_0),
    .recon_delta_x(recon_delta_x_0), 
    .recon_delta_y(recon_delta_y_0), 
    .recon_valid(recon_valid_0),
    .recon_dst_frame(recon_dst_frame_0), 
    .recon_dst_field(recon_dst_field_0),
    .dct_block_cmd(dct_block_cmd),
    .dct_block_en(dct_block_en)
    );

  /* forward */
  memory_address
    #(.dta_width(1))
    fwd_mem_addr (
    .clk(clk), 
    .clk_en(clk_en), 
    .rst(rst), 
    /* in */
    .frame(fwd_src_frame_0), 
    .frame_picture(frame_picture_0),
    .field_in_frame(field_in_frame_0),
    .field(fwd_src_field_0), 
    .component(comp_0), 
    .mb_width(mb_width), 
    .horizontal_size(horizontal_size),
    .vertical_size(vertical_size),
    .macroblock_address(macroblock_address_0), 
    .delta_x(delta_x_0), 
    .delta_y(delta_y_0), 
    .mv_x(fwd_mv_x_0), 
    .mv_y(fwd_mv_y_0), 
    .dta_in(1'b0), 
    .valid_in(fwd_valid_0), 
    /* out */
    .address(fwd_wr_addr), 
    .offset_x(dst_wr_fwd_hor_offset), 
    .halfpixel_x(dst_wr_fwd_hor_halfpixel), 
    .halfpixel_y(dst_wr_fwd_ver_halfpixel), 
    .dta_out(), 
    .valid_out(fwd_wr_addr_en)
    );

  /* backward */
  memory_address
    #(.dta_width(1))
    bwd_mem_addr (
    .clk(clk), 
    .clk_en(clk_en), 
    .rst(rst), 
    /* in */
    .frame(bwd_src_frame_0), 
    .frame_picture(frame_picture_0),
    .field_in_frame(field_in_frame_0),
    .field(bwd_src_field_0), 
    .component(comp_0), 
    .mb_width(mb_width), 
    .horizontal_size(horizontal_size),
    .vertical_size(vertical_size),
    .macroblock_address(macroblock_address_0), 
    .delta_x(delta_x_0), 
    .delta_y(delta_y_0), 
    .mv_x(bwd_mv_x_0), 
    .mv_y(bwd_mv_y_0), 
    .dta_in(1'b0), 
    .valid_in(bwd_valid_0), 
    /* out */
    .address(bwd_wr_addr), 
    .offset_x(dst_wr_bwd_hor_offset), 
    .halfpixel_x(dst_wr_bwd_hor_halfpixel), 
    .halfpixel_y(dst_wr_bwd_ver_halfpixel), 
    .dta_out(), 
    .valid_out(bwd_wr_addr_en)
    );

  /* reconstruction */
  memory_address
    #(.dta_width(3))
    recon_mem_addr (
    .clk(clk), 
    .clk_en(clk_en), 
    .rst(rst), 
    /* in */
    .frame(recon_dst_frame_0), 
    .frame_picture(frame_picture_0),
    .field_in_frame(field_in_frame_0),
    .field(recon_dst_field_0), 
    .component(comp_0), 
    .mb_width(mb_width), 
    .horizontal_size(horizontal_size),
    .vertical_size(vertical_size),
    .macroblock_address(macroblock_address_0), 
    .delta_x(recon_delta_x_0), 
    .delta_y(recon_delta_y_0), 
    .mv_x(13'sd0), 
    .mv_y(13'sd0), 
    .dta_in({fwd_valid_0, bwd_valid_0, write_recon_0}), 
    .valid_in(recon_valid_0), 
    /* out */
    .address(dst_wr_write_address), 
    .offset_x(), 
    .halfpixel_x(), 
    .halfpixel_y(), 
    .dta_out({dst_wr_motion_forward, dst_wr_motion_backward, dst_wr_write_recon}), 
    .valid_out(dst_wr_en)
    );

`ifdef DEBUG
  /* debugging */

  always @(posedge clk)
    if (clk_en && (state == STATE_READ) && motion_vector_valid)
      begin
        case (chroma_format)
          CHROMA420:     #0 $display("%m         CHROMA420");
          CHROMA422:     #0 $display("%m         CHROMA422");
          CHROMA444:     #0 $display("%m         CHROMA444");
          default        #0 $display("%m         chroma_format %h", chroma_format);
        endcase
        case (picture_coding_type)
          P_TYPE:        #0 $display("%m         P_TYPE");
          I_TYPE:        #0 $display("%m         I_TYPE");
          B_TYPE:        #0 $display("%m         B_TYPE");
          D_TYPE:        #0 $display("%m         D_TYPE"); // mpeg1 only; mpeg2 does not have D pictures
        endcase
        case (picture_structure)
          FRAME_PICTURE: #0 $display("%m         FRAME_PICTURE");
          TOP_FIELD:     #0 $display("%m         TOP_FIELD");
          BOTTOM_FIELD:  #0 $display("%m         BOTTOM_FIELD");
          default        #0 $display("%m         picture_structure %h", picture_structure);
        endcase
  
        /* 
           MC_FRAME and MC_16X8 share the same code; which one is used depends upon picture_structure.
           In a FRAME_PICTURE you can have MC_FRAME, but never MC_16X8. 
           In a field picture (TOP_FIELD, BOTTOM_FIELD) you can have MC_16X8, but never MC_FRAME.
         */
        case (picture_structure)
          FRAME_PICTURE: 
            case (motion_type)
              MC_FIELD:      #0 $display("%m         MC_FIELD");
              MC_FRAME:      #0 $display("%m         MC_FRAME");
              MC_DMV:        #0 $display("%m         MC_DMV");
              MC_NONE:       #0 $display("%m         MC_NONE");
              default        #0 $display("%m         *** unknown motion_type %h ***", motion_type);
            endcase
          TOP_FIELD,
          BOTTOM_FIELD:  
            case (motion_type)
              MC_FIELD:      #0 $display("%m         MC_FIELD");
              MC_16X8:       #0 $display("%m         MC_16X8");
              MC_DMV:        #0 $display("%m         MC_DMV");
              MC_NONE:       #0 $display("%m         MC_NONE");
              default        #0 $display("%m         *** unknown motion_type %h ***", motion_type);
            endcase
        endcase
        #0 $display("%m         macroblock_address: %d", macroblock_address);
        if (macroblock_intra)           #0 $display("%m         macroblock_intra");
        if (macroblock_motion_forward && macroblock_motion_backward)  #0 $display("%m         macroblock_motion_forward, macroblock_motion_backward");
        else if (macroblock_motion_forward)  #0 $display("%m         macroblock_motion_forward");
        else if (macroblock_motion_backward) #0 $display("%m         macroblock_motion_backward");
        else #0 $display("%m         no macroblock_motion_forward, no macroblock_motion_backward");
        if (dct_type) #0 $display("%m         dct_type field");
        else #0 $display("%m         dct_type frame");
        #0 $display("%m\tpmv_0_0_0: %d pmv_0_0_1: %d pmv_1_0_0: %d pmv_1_0_1: %d pmv_0_1_0: %d pmv_0_1_1: %d pmv_1_1_0: %d pmv_1_1_1: %d", pmv_0_0_0, pmv_0_0_1, pmv_1_0_0, pmv_1_0_1, pmv_0_1_0, pmv_0_1_1, pmv_1_1_0, pmv_1_1_1);
        #0 $display("%m\tdmv_0_0: %d dmv_0_1: %d dmv_1_0: %d dmv_1_1: %d", dmv_0_0, dmv_0_1, dmv_1_0, dmv_1_1);
        #0 $display("%m\tmotion_vert_field_select_0_0: %d motion_vert_field_select_0_1: %d motion_vert_field_select_1_0: %d motion_vert_field_select_1_1: %d", motion_vert_field_select_0_0, motion_vert_field_select_0_1, motion_vert_field_select_1_0, motion_vert_field_select_1_1);
      end

  always @(posedge clk)
    if (clk_en && (state == STATE_READ) && update_picture_buffers)
      begin
        #0 $display("%m\tupdate picture buffers");
      end

  always @(posedge clk)
    if (clk_en)
      case (state)
        STATE_INIT:                               #0 $display("%m         STATE_INIT");
        STATE_READ:                               #0 $display("%m         STATE_READ");
        STATE_UPDATE:                             #0 $display("%m         STATE_UPDATE");
        STATE_MOTVEC:                             #0 $display("%m         STATE_MOTVEC");
        STATE_NEXT:                               #0 $display("%m         STATE_NEXT");
        default                                   #0 $display("%m         *** Error: unknown state %d", state);
      endcase

  always @(posedge clk)
    begin
      $strobe("%m\tclk_en: %d mvec_rd_en: %d mvec_rd_valid: %d", clk_en, mvec_rd_en, mvec_rd_valid);    
      $strobe("%m\tclk_en: %d mb_end: %d last_row: %d comp: %d block: %d row: %d col:%d motvec_update: %d", clk_en, mb_end, last_row, comp, block, row, column, motvec_update);    

      $strobe("%m\tclk_en: %d fwd_src_frame_0: %d frame_picture_0: %d field_in_frame_0: %d fwd_src_field_0: %d comp_0: %d macroblock_address_0: %d delta_x_0: %d delta_y_0: %d fwd_mv_x_0: %d fwd_mv_y_0: %d fwd_valid_0: %d",
                   clk_en, fwd_src_frame_0, frame_picture_0, field_in_frame_0, fwd_src_field_0, comp_0, macroblock_address_0, delta_x_0, delta_y_0, fwd_mv_x_0, fwd_mv_y_0, fwd_valid_0);

      $strobe("%m\tclk_en: %d bwd_src_frame_0: %d frame_picture_0: %d field_in_frame_0: %d bwd_src_field_0: %d comp_0: %d macroblock_address_0: %d delta_x_0: %d delta_y_0: %d bwd_mv_x_0: %d bwd_mv_y_0: %d bwd_valid_0: %d",
                   clk_en, bwd_src_frame_0, frame_picture_0, field_in_frame_0, bwd_src_field_0, comp_0, macroblock_address_0, delta_x_0, delta_y_0, bwd_mv_x_0, bwd_mv_y_0, bwd_valid_0);

      $strobe("%m\tclk_en: %d recon_dst_frame_0: %d frame_picture_0: %d field_in_frame_0: %d recon_dst_field_0: %d comp_0: %d macroblock_address_0: %d recon_delta_x_0: %d recon_delta_y_0: %d recon_valid_0: %d write_recon_0: %d",
                   clk_en, recon_dst_frame_0, frame_picture_0, field_in_frame_0, recon_dst_field_0, comp_0, macroblock_address_0, recon_delta_x_0, recon_delta_y_0, recon_valid_0, write_recon_0);
      $strobe("%m\tclk_en: %d dst_wr_en: %d dst_wr_write_recon: %d dst_wr_write_address: %h dst_wr_motion_forward: %d dst_wr_motion_backward: %d ",
                   clk_en, dst_wr_en, dst_wr_write_recon, dst_wr_write_address, dst_wr_motion_forward, dst_wr_motion_backward);
      $strobe("%m\tclk_en: %d dst_wr_en: %d dst_wr_fwd_hor_offset: %d dst_wr_fwd_hor_halfpixel: %d dst_wr_fwd_ver_halfpixel: %d dst_wr_bwd_hor_offset: %d dst_wr_bwd_hor_halfpixel: %d dst_wr_bwd_ver_halfpixel: %d",
                   clk_en, dst_wr_en, dst_wr_fwd_hor_offset, dst_wr_fwd_hor_halfpixel, dst_wr_fwd_ver_halfpixel, dst_wr_bwd_hor_offset, dst_wr_bwd_hor_halfpixel, dst_wr_bwd_ver_halfpixel);

      $strobe("%m\tclk_en: %d dct_block_cmd: %d dct_block_en: %d",
                   clk_en, dct_block_cmd, dct_block_en);
    end

`endif

endmodule
/* not truncated */
