/* 
 * motcomp.v
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
 * motcomp - Motion Compensation.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

`undef CHECK
`ifdef __IVERILOG__
`define CHECK 1
`endif

module motcomp(
  clk, clk_en, rst, busy,
  picture_coding_type, picture_structure, motion_type, dct_type,
  macroblock_address, macroblock_motion_forward, macroblock_motion_backward, macroblock_intra,
  mb_width, mb_height, horizontal_size, vertical_size, chroma_format,
  motion_vector_valid,
  pmv_0_0_0, pmv_0_0_1, pmv_1_0_0, pmv_1_0_1, pmv_0_1_0, pmv_0_1_1, pmv_1_1_0, pmv_1_1_1,
  dmv_0_0, dmv_0_1, dmv_1_0, dmv_1_1,
  motion_vert_field_select_0_0, motion_vert_field_select_0_1, motion_vert_field_select_1_0, motion_vert_field_select_1_1,
  second_field, update_picture_buffers, progressive_sequence, progressive_frame, top_field_first, repeat_first_field, last_frame,
  idct_rd_dta_empty, idct_rd_dta_en, idct_rd_dta, idct_rd_dta_valid, frame_idct_wr_overflow, dct_block_wr_overflow, mvec_wr_almost_full, mvec_wr_overflow, dst_wr_overflow,
  source_select,
  fwd_wr_addr_clk_en, fwd_wr_addr_full, fwd_wr_addr_almost_full, fwd_wr_addr_en, fwd_wr_addr_ack, fwd_wr_addr, fwd_rd_dta_clk_en, fwd_rd_dta_empty, fwd_rd_dta_en, fwd_rd_dta_valid, fwd_rd_dta,
  bwd_wr_addr_clk_en, bwd_wr_addr_full, bwd_wr_addr_almost_full, bwd_wr_addr_en, bwd_wr_addr_ack, bwd_wr_addr, bwd_rd_dta_clk_en, bwd_rd_dta_empty, bwd_rd_dta_en, bwd_rd_dta_valid, bwd_rd_dta,
  recon_wr_full, recon_wr_almost_full, recon_wr_en, recon_wr_ack, recon_wr_addr, recon_wr_dta,
  output_frame, output_frame_valid, output_frame_rd, output_progressive_sequence, output_progressive_frame, output_top_field_first, output_repeat_first_field
  );

  input              clk;                      // clock
  input              clk_en;                   // clock enable
  input              rst;                      // synchronous active low reset
  output reg         busy;                     // addrgen freezes vld while processing motion vectors 

  input         [2:0]picture_coding_type;      // identifies whether a picture is an I, P or B picture.
  input         [1:0]picture_structure;        // one of FRAME_PICTURE, TOP_FIELD or BOTTOM_FIELD
  input         [1:0]motion_type;              // one of MC_FIELD, MC_FRAME, MC_16X8 or MC_DMV
  input              dct_type;                 // dct_type == 1 : field dct coded; dct_type == 0 : frame dct coded
  input        [12:0]macroblock_address;       // absolute position of the current macroblock. top-left macroblock has macroblock_address zero.
  input              macroblock_motion_forward;
  input              macroblock_motion_backward;
  input              macroblock_intra;
  input         [7:0]mb_width;                 // par. 6.3.3. width of the encoded luminance component of pictures in macroblocks
  input         [7:0]mb_height;                // par. 6.3.3. height of the encoded luminance component of frame pictures in macroblocks
  input        [13:0]horizontal_size;               /* par. 6.2.2.1, par. 6.3.3 */
  input        [13:0]vertical_size;                 /* par. 6.2.2.1, par. 6.3.3 */
  input         [1:0]chroma_format;
  input              motion_vector_valid;      // asserted when pmv_x_x_x, dmv_x_x valid
  input signed [12:0]pmv_0_0_0;                // predicted motion vector
  input signed [12:0]pmv_0_0_1;                // predicted motion vector
  input signed [12:0]pmv_1_0_0;                // predicted motion vector
  input signed [12:0]pmv_1_0_1;                // predicted motion vector
  input signed [12:0]pmv_0_1_0;                // predicted motion vector
  input signed [12:0]pmv_0_1_1;                // predicted motion vector
  input signed [12:0]pmv_1_1_0;                // predicted motion vector
  input signed [12:0]pmv_1_1_1;                // predicted motion vector
  input signed [12:0]dmv_0_0;                  // dual-prime motion vector.
  input signed [12:0]dmv_0_1;                  // dual-prime motion vector.
  input signed [12:0]dmv_1_0;                  // dual-prime motion vector.
  input signed [12:0]dmv_1_1;                  // dual-prime motion vector.
  input              motion_vert_field_select_0_0;
  input              motion_vert_field_select_0_1;
  input              motion_vert_field_select_1_0;
  input              motion_vert_field_select_1_1;
  input              second_field;
  input              update_picture_buffers;
  input              progressive_sequence;
  input              progressive_frame;
  input              top_field_first;
  input              repeat_first_field;
  input              last_frame;

  /* for probe */
  output             dct_block_wr_overflow;
  output             frame_idct_wr_overflow;
  /* reading idct coefficients */
  input              idct_rd_dta_empty;
  output             idct_rd_dta_en;
  input        [71:0]idct_rd_dta;
  input              idct_rd_dta_valid;

  /* trick modes */
  input         [2:0]source_select;                 /* select video out source */
 
  /* reading forward reference frame */
  /* reading forward reference frame: writing address */
  output           fwd_wr_addr_clk_en;
  input            fwd_wr_addr_full;
  input            fwd_wr_addr_almost_full;
  output           fwd_wr_addr_en;
  input            fwd_wr_addr_ack;
  output     [21:0]fwd_wr_addr;
  /* reading forward reference frame: reading data */
  output           fwd_rd_dta_clk_en;
  input            fwd_rd_dta_empty;
  output           fwd_rd_dta_en;
  input            fwd_rd_dta_valid;
  input      [63:0]fwd_rd_dta;

  /* reading backward reference frame: writing address */
  output           bwd_wr_addr_clk_en;
  input            bwd_wr_addr_full;
  input            bwd_wr_addr_almost_full;
  output           bwd_wr_addr_en;
  input            bwd_wr_addr_ack;
  output     [21:0]bwd_wr_addr;
  /* reading backward reference frame: reading data */
  output           bwd_rd_dta_clk_en;
  input            bwd_rd_dta_empty;
  output           bwd_rd_dta_en;
  input            bwd_rd_dta_valid;
  input      [63:0]bwd_rd_dta;

  /* writing reconstructed frame: writing address and data */
  input            recon_wr_full;
  input            recon_wr_almost_full;
  input            recon_wr_ack;
  output           recon_wr_en;
  output     [21:0]recon_wr_addr;
  output     [63:0]recon_wr_dta;

  /* frame being displayed */
  output       [2:0]output_frame;                 /* frame to be displayed. Has value 2'd0, 2'd1 or 2'd2 */
  output            output_frame_valid;           /* asserted when output_frame valid */
  input             output_frame_rd;              /* asserted to read next output_frame */
  output            output_progressive_sequence;
  output            output_progressive_frame;
  output            output_top_field_first;
  output            output_repeat_first_field;
  wire              picbuf_busy;

  /* motion vector fifo */ 

  /* writing motion vector fifo */
  wire               mvec_wr_full;
  output             mvec_wr_almost_full;
  wire               mvec_wr_ack;
  output             mvec_wr_overflow;

  reg                mvec_wr_en;
  reg         [187:0]mvec_wr_dta;
  wire        [187:0]mvec_rd_dta;

  /* fwft reading motion vector fifo */
  wire               mvec_rd_dta_en;
  wire               mvec_rd_dta_valid;
  wire               mvec_rd_en;
  wire               mvec_rd_valid;

  wire          [2:0]mvec_rd_picture_coding_type;
  wire          [1:0]mvec_rd_picture_structure;
  wire          [1:0]mvec_rd_motion_type;
  wire               mvec_rd_dct_type;
  wire         [12:0]mvec_rd_macroblock_address;
  wire               mvec_rd_macroblock_motion_forward;
  wire               mvec_rd_macroblock_motion_backward;
  wire               mvec_rd_macroblock_intra;
  wire  signed [12:0]mvec_rd_pmv_0_0_0;
  wire  signed [12:0]mvec_rd_pmv_0_0_1;
  wire  signed [12:0]mvec_rd_pmv_1_0_0;
  wire  signed [12:0]mvec_rd_pmv_1_0_1;
  wire  signed [12:0]mvec_rd_pmv_0_1_0;
  wire  signed [12:0]mvec_rd_pmv_0_1_1;
  wire  signed [12:0]mvec_rd_pmv_1_1_0;
  wire  signed [12:0]mvec_rd_pmv_1_1_1;
  wire  signed [12:0]mvec_rd_dmv_0_0;
  wire  signed [12:0]mvec_rd_dmv_0_1;
  wire  signed [12:0]mvec_rd_dmv_1_0;
  wire  signed [12:0]mvec_rd_dmv_1_1;
  wire               mvec_rd_motion_vert_field_select_0_0;
  wire               mvec_rd_motion_vert_field_select_0_1;
  wire               mvec_rd_motion_vert_field_select_1_0;
  wire               mvec_rd_motion_vert_field_select_1_1;
  wire               mvec_rd_second_field;
  wire               mvec_rd_update_picture_buffers;
  wire               mvec_rd_last_frame;
  wire               mvec_rd_motion_vector_valid;

  /* block reconstruction fifo */
  /* writing block reconstruction fifo */
  wire             dst_wr_full;
  wire             dst_wr_almost_full;
  wire             dst_wr_en;
  wire             dst_wr_ack;
  output           dst_wr_overflow;
  wire             dst_wr_write_recon;
  wire       [21:0]dst_wr_write_address;
  wire             dst_wr_motion_forward;
  wire        [2:0]dst_wr_fwd_hor_offset;
  wire             dst_wr_fwd_hor_halfpixel;
  wire             dst_wr_fwd_ver_halfpixel;
  wire             dst_wr_motion_backward;
  wire        [2:0]dst_wr_bwd_hor_offset;
  wire             dst_wr_bwd_hor_halfpixel;
  wire             dst_wr_bwd_ver_halfpixel;
  /* reading block reconstruction fifo */
  wire             dst_rd_empty;
  wire             dst_rd_en;
  wire             dst_rd_valid;
  wire       [34:0]dst_rd_dta;

  /* dct type fifo */
  /* writing dct type fifo */
  wire             dct_block_wr_full;
  wire             dct_block_wr_almost_full;
  wire             dct_block_wr_en;
  wire        [2:0]dct_block_wr_cmd;
  /* reading dct type fifo */
  wire             dct_block_rd_empty;
  wire             dct_block_rd_en;
  wire             dct_block_rd_valid;
  wire        [2:0]dct_block_rd_cmd;

  /* idct data after conversion to frame coding */
  wire             frame_idct_dta_empty;
  wire       [71:0]frame_idct_dta;
  wire             frame_idct_dta_en;
  wire             frame_idct_dta_valid;


  assign fwd_wr_addr_clk_en = clk_en;
  assign fwd_rd_dta_clk_en = clk_en;

  assign bwd_wr_addr_clk_en = clk_en;
  assign bwd_rd_dta_clk_en = clk_en;


  /* freeze vld when vld asserts update_picture_buffers until motcomp_picbuf has updated the picture buffers.
     Else vld might generate motion vectors for the new frame before current_frame, forward and backward reference frame have been updated.
     Algorithm: assert flush_mvec_fifo when update_picture_buffers enters the mvec motion vector fifo, and clear flush_mvec_fifo when picbuf takes over. */

  reg              flush_mvec_fifo;

  always @(posedge clk)
    if (~ rst) flush_mvec_fifo <= 1'b0;
    else if (update_picture_buffers) flush_mvec_fifo <= 1'b1;
    else if (picbuf_busy) flush_mvec_fifo <= 1'b0;
    else flush_mvec_fifo <= flush_mvec_fifo;

  /* freeze vld when vld asserts update_picture_buffers; release vld when motcomp_picbuf has updated the picture buffers  */
  always @(posedge clk)
    if (~ rst) busy <= 1'b0;
    else if (update_picture_buffers) busy <= 1'b1;
    else busy <= flush_mvec_fifo || picbuf_busy;

`include "fifo_size.v"
`include "vld_codes.v"

  always @(posedge clk)
    if (~ rst) mvec_wr_dta <= 188'b0;
    else if (clk_en) mvec_wr_dta <= {picture_coding_type, picture_structure, motion_type, dct_type, macroblock_address, macroblock_motion_forward, macroblock_motion_backward, macroblock_intra, pmv_0_0_0, pmv_0_0_1, pmv_1_0_0, pmv_1_0_1, pmv_0_1_0, pmv_0_1_1, pmv_1_1_0, pmv_1_1_1, dmv_0_0, dmv_0_1, dmv_1_0, dmv_1_1, motion_vert_field_select_0_0, motion_vert_field_select_0_1, motion_vert_field_select_1_0, motion_vert_field_select_1_1, second_field, last_frame, update_picture_buffers, motion_vector_valid};
    else mvec_wr_dta <= mvec_wr_dta;

  always @(posedge clk)
    if (~ rst) mvec_wr_en <= 1'b0;
    else mvec_wr_en <= (motion_vector_valid || update_picture_buffers) && clk_en;

  /* motion vector fifo */
  fifo_sc
    #(.addr_width(MVEC_DEPTH),
    .prog_thresh(MVEC_THRESHOLD),
    .dta_width(9'd188))
    mvec_fifo (
    .rst(rst),
    .clk(clk),
    .din(mvec_wr_dta),
    .wr_en(mvec_wr_en),
    .full(mvec_wr_full),
    .wr_ack(mvec_wr_ack),
    .overflow(mvec_wr_overflow),
    .prog_full(mvec_wr_almost_full),
    .dout(mvec_rd_dta),
    .rd_en(mvec_rd_dta_en),
    .empty(),
    .valid(mvec_rd_dta_valid),
    .underflow(),
    .prog_empty()
    );

  fwft_reader #(.dta_width(9'd188)) mvec_fwft_reader (
    .rst(rst), 
    .clk(clk), 
    .clk_en(clk_en), 
    .fifo_rd_en(mvec_rd_dta_en), 
    .fifo_valid(mvec_rd_dta_valid), 
    .fifo_dout(mvec_rd_dta), 
    .valid(mvec_rd_valid), 
    .dout({mvec_rd_picture_coding_type, mvec_rd_picture_structure, mvec_rd_motion_type, mvec_rd_dct_type, mvec_rd_macroblock_address, mvec_rd_macroblock_motion_forward, mvec_rd_macroblock_motion_backward, mvec_rd_macroblock_intra, mvec_rd_pmv_0_0_0, mvec_rd_pmv_0_0_1, mvec_rd_pmv_1_0_0, mvec_rd_pmv_1_0_1, mvec_rd_pmv_0_1_0, mvec_rd_pmv_0_1_1, mvec_rd_pmv_1_1_0, mvec_rd_pmv_1_1_1, mvec_rd_dmv_0_0, mvec_rd_dmv_0_1, mvec_rd_dmv_1_0, mvec_rd_dmv_1_1, mvec_rd_motion_vert_field_select_0_0, mvec_rd_motion_vert_field_select_0_1, mvec_rd_motion_vert_field_select_1_0, mvec_rd_motion_vert_field_select_1_1, mvec_rd_second_field, mvec_rd_last_frame, mvec_rd_update_picture_buffers, mvec_rd_motion_vector_valid}),
    .rd_en(mvec_rd_en)
    );


  /* block reconstruction fifo */
  fifo_sc
    #(.addr_width(DST_DEPTH),
    .prog_thresh(DST_THRESHOLD),
    .dta_width(9'd35)) // same value for fifo_threshold fwd_reader, bwd_reader and prog_thresh dst_fifo
    dst_fifo (
    .rst(rst),
    .clk(clk),
    .din({dst_wr_write_recon, dst_wr_write_address, dst_wr_motion_forward, dst_wr_fwd_hor_offset, dst_wr_fwd_hor_halfpixel, dst_wr_fwd_ver_halfpixel, dst_wr_motion_backward, dst_wr_bwd_hor_offset, dst_wr_bwd_hor_halfpixel, dst_wr_bwd_ver_halfpixel}),
    .wr_en(dst_wr_en && clk_en),
    .full(dst_wr_full),
    .wr_ack(dst_wr_ack),
    .overflow(dst_wr_overflow),
    .prog_full(dst_wr_almost_full),
    .dout(dst_rd_dta),
    .rd_en(dst_rd_en && clk_en),
    .empty(dst_rd_empty),
    .valid(dst_rd_valid),
    .underflow(),
    .prog_empty()
    );

  /* dct type fifo */
  fifo_sc
    #(.addr_width(DST_DEPTH-9'd3),
    .prog_thresh(9'd6), // 6 = number of blocks in a macroblock (4:2:0). Hence if ~dct_block_wr_almost_full there's enough room to write the commands for a complete macroblock.
    .dta_width(9'd3))
    dct_type_fifo (
    .rst(rst),
    .clk(clk),
    .din({dct_block_wr_cmd}),
    .wr_en(dct_block_wr_en && clk_en),
    .full(dct_block_wr_full),
    .wr_ack(),
    .overflow(dct_block_wr_overflow),
    .prog_full(dct_block_wr_almost_full),
    .dout({dct_block_rd_cmd}),
    .rd_en(dct_block_rd_en && clk_en),
    .empty(dct_block_rd_empty),
    .valid(dct_block_rd_valid),
    .underflow(),
    .prog_empty()
    );

  /* address generation */
  motcomp_addrgen motcomp_addrgen (
    .clk(clk),
    .clk_en(clk_en), 
    .rst(rst),

    .mvec_rd_en(mvec_rd_en),
    .mvec_rd_valid(mvec_rd_valid),

    .picture_coding_type(mvec_rd_picture_coding_type),
    .picture_structure(mvec_rd_picture_structure),
    .motion_type(mvec_rd_motion_type),
    .dct_type(mvec_rd_dct_type),
    .macroblock_address(mvec_rd_macroblock_address),
    .macroblock_motion_forward(mvec_rd_macroblock_motion_forward),
    .macroblock_motion_backward(mvec_rd_macroblock_motion_backward),
    .macroblock_intra(mvec_rd_macroblock_intra),
    .mb_width(mb_width),
    .mb_height(mb_height),
    .horizontal_size(horizontal_size),
    .vertical_size(vertical_size),
    .chroma_format(chroma_format),
    .pmv_0_0_0(mvec_rd_pmv_0_0_0),
    .pmv_0_0_1(mvec_rd_pmv_0_0_1),
    .pmv_1_0_0(mvec_rd_pmv_1_0_0),
    .pmv_1_0_1(mvec_rd_pmv_1_0_1),
    .pmv_0_1_0(mvec_rd_pmv_0_1_0),
    .pmv_0_1_1(mvec_rd_pmv_0_1_1),
    .pmv_1_1_0(mvec_rd_pmv_1_1_0),
    .pmv_1_1_1(mvec_rd_pmv_1_1_1),
    .dmv_0_0(mvec_rd_dmv_0_0),
    .dmv_0_1(mvec_rd_dmv_0_1),
    .dmv_1_0(mvec_rd_dmv_1_0),
    .dmv_1_1(mvec_rd_dmv_1_1),
    .motion_vert_field_select_0_0(mvec_rd_motion_vert_field_select_0_0),
    .motion_vert_field_select_0_1(mvec_rd_motion_vert_field_select_0_1),
    .motion_vert_field_select_1_0(mvec_rd_motion_vert_field_select_1_0),
    .motion_vert_field_select_1_1(mvec_rd_motion_vert_field_select_1_1),
    .second_field(mvec_rd_second_field),
    .progressive_sequence(progressive_sequence),             // from vld
    .progressive_frame(progressive_frame),                   // from vld
    .top_field_first(top_field_first),                       // from vld
    .repeat_first_field(repeat_first_field),                 // from vld
    .last_frame(mvec_rd_last_frame),
    .update_picture_buffers(mvec_rd_update_picture_buffers),
    .motion_vector_valid(mvec_rd_motion_vector_valid),

    .source_select(source_select),

    .fwd_wr_addr_en(fwd_wr_addr_en),
    .fwd_wr_addr(fwd_wr_addr),
    .fwd_wr_addr_almost_full(fwd_wr_addr_almost_full),
    .bwd_wr_addr_en(bwd_wr_addr_en),
    .bwd_wr_addr(bwd_wr_addr),
    .bwd_wr_addr_almost_full(bwd_wr_addr_almost_full),
    .dst_wr_en(dst_wr_en),
    .dst_wr_almost_full(dst_wr_almost_full),
    .dst_wr_write_recon(dst_wr_write_recon),
    .dst_wr_write_address(dst_wr_write_address),
    .dst_wr_motion_forward(dst_wr_motion_forward),
    .dst_wr_fwd_hor_offset(dst_wr_fwd_hor_offset),
    .dst_wr_fwd_hor_halfpixel(dst_wr_fwd_hor_halfpixel),
    .dst_wr_fwd_ver_halfpixel(dst_wr_fwd_ver_halfpixel),
    .dst_wr_motion_backward(dst_wr_motion_backward),
    .dst_wr_bwd_hor_offset(dst_wr_bwd_hor_offset),
    .dst_wr_bwd_hor_halfpixel(dst_wr_bwd_hor_halfpixel),
    .dst_wr_bwd_ver_halfpixel(dst_wr_bwd_ver_halfpixel),
    .output_frame(output_frame),                             // to resample
    .output_frame_valid(output_frame_valid),                 // to resample
    .output_frame_rd(output_frame_rd),                       // to resample
    .output_progressive_sequence(output_progressive_sequence),// to resample
    .output_progressive_frame(output_progressive_frame),     // to resample
    .output_top_field_first(output_top_field_first),         // to resample
    .output_repeat_first_field(output_repeat_first_field),   // to resample
    .picbuf_busy(picbuf_busy),
    .dct_block_cmd(dct_block_wr_cmd),
    .dct_block_en(dct_block_wr_en),
    .dct_block_wr_almost_full(dct_block_wr_almost_full)
    );

  /* convert field dct coding to frame dct coding */
  motcomp_dcttype motcomp_dcttype (
    .clk(clk), 
    .clk_en(clk_en), 
    .rst(rst), 
    .dct_block_empty(dct_block_rd_empty), 
    .dct_block_cmd(dct_block_rd_cmd), 
    .dct_block_en(dct_block_rd_en), 
    .dct_block_valid(dct_block_rd_valid), 
    .idct_rd_dta_empty(idct_rd_dta_empty), 
    .idct_rd_dta(idct_rd_dta), 
    .idct_rd_dta_en(idct_rd_dta_en), 
    .idct_rd_dta_valid(idct_rd_dta_valid), 
    .frame_idct_wr_overflow(frame_idct_wr_overflow), 
    .frame_idct_rd_dta_empty(frame_idct_dta_empty), 
    .frame_idct_rd_dta(frame_idct_dta), 
    .frame_idct_rd_dta_en(frame_idct_dta_en),
    .frame_idct_rd_dta_valid(frame_idct_dta_valid)
    );

  /* block reconstruction */
  motcomp_recon motcomp_recon (
    .clk(clk),
    .clk_en(clk_en),
    .rst(rst),
    .dst_rd_dta_valid(dst_rd_valid),
    .dst_rd_dta_empty(dst_rd_empty),
    .dst_rd_dta_en(dst_rd_en),
    .dst_rd_dta(dst_rd_dta),
    .idct_rd_dta_empty(frame_idct_dta_empty),
    .idct_rd_dta_en(frame_idct_dta_en),
    .idct_rd_dta(frame_idct_dta),
    .idct_rd_dta_valid(frame_idct_dta_valid),
    .fwd_rd_dta_empty(fwd_rd_dta_empty),
    .fwd_rd_dta_en(fwd_rd_dta_en),
    .fwd_rd_dta(fwd_rd_dta),
    .fwd_rd_dta_valid(fwd_rd_dta_valid),
    .bwd_rd_dta_empty(bwd_rd_dta_empty),
    .bwd_rd_dta_en(bwd_rd_dta_en),
    .bwd_rd_dta(bwd_rd_dta),
    .bwd_rd_dta_valid(bwd_rd_dta_valid),
    .recon_wr_full(recon_wr_full),
    .recon_wr_almost_full(recon_wr_almost_full),
    .recon_wr_en(recon_wr_en),
    .recon_wr_addr(recon_wr_addr),
    .recon_wr_dta(recon_wr_dta)
    );


`ifdef CHECK
  always @(posedge clk)
    if (mvec_wr_overflow) 
      begin
        $strobe ("%m\t*** error: mvec_wr_overflow ***");
	$stop;
      end

  always @(posedge clk)
    if (dst_wr_overflow) 
      begin
        $strobe ("%m\t*** error: dst_wr_overflow ***");
	$stop;
      end

  always @(posedge clk)
    if (dct_block_wr_overflow) 
      begin
        $strobe ("%m\t*** error: dct_block_wr_overflow ***");
	$stop;
      end

`endif

  /*
   * fifos_almost_full is asserted if dst, fwd or bwd fifo is almost full.
   * No need to watch recon_wr_full; motcomp_recon does that
   */

`ifdef DEBUG
  wire               fifos_almost_full = (dst_wr_almost_full || fwd_wr_addr_almost_full || bwd_wr_addr_almost_full || dct_block_wr_almost_full);

  always @(posedge clk)
    $strobe("%m\tbusy: %d fifos_almost_full: %d dst_wr_almost_full: %d fwd_wr_addr_almost_full: %d bwd_wr_addr_almost_full: %d", busy, fifos_almost_full, dst_wr_almost_full, fwd_wr_addr_almost_full, bwd_wr_addr_almost_full);
  
  always @(posedge clk)
    if (dst_wr_almost_full)
      $display("%m\tbusy: dst_wr_almost_full");
  
  always @(posedge clk)
    if (fwd_wr_addr_almost_full)
      $display("%m\tbusy: fwd_wr_addr_almost_full");
  
  always @(posedge clk)
    if (bwd_wr_addr_almost_full)
      $display("%m\tbusy: bwd_wr_addr_almost_full");

  always @(posedge clk)
     if (clk_en && ~busy && motion_vector_valid) $strobe("%m\tmacroblock_address: %d", macroblock_address);

  always @(posedge clk)
    if (clk_en && ~busy && motion_vector_valid)
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
              default        #0 $display("%m         motion_type %h", motion_type);
            endcase
          TOP_FIELD,
          BOTTOM_FIELD:  
            case (motion_type)
              MC_FIELD:      #0 $display("%m         MC_FIELD");
              MC_16X8:       #0 $display("%m         MC_16X8");
              MC_DMV:        #0 $display("%m         MC_DMV");
              default        #0 $display("%m         motion_type %h", motion_type);
            endcase
        endcase
        #0 $display("%m         macroblock_address: %d", macroblock_address);
        if (macroblock_intra)           #0 $display("%m         macroblock_intra");
        if (macroblock_motion_forward && macroblock_motion_backward)  #0 $display("%m         macroblock_motion_forward, macroblock_motion_backward");
        else if (macroblock_motion_forward)  #0 $display("%m         macroblock_motion_forward");
        else if (macroblock_motion_backward) #0 $display("%m         macroblock_motion_backward");
        if (dct_type) #0 $display("%m\tdct_type field");
        else #0 $display("%m\tdct_type frame");
        #0 $display("%m\tpmv_0_0_0: %d pmv_0_0_1: %d pmv_1_0_0: %d pmv_1_0_1: %d pmv_0_1_0: %d pmv_0_1_1: %d pmv_1_1_0: %d pmv_1_1_1: %d", pmv_0_0_0, pmv_0_0_1, pmv_1_0_0, pmv_1_0_1, pmv_0_1_0, pmv_0_1_1, pmv_1_1_0, pmv_1_1_1);
        #0 $display("%m\tdmv_0_0: %d dmv_0_1: %d dmv_1_0: %d dmv_1_1: %d", dmv_0_0, dmv_0_1, dmv_1_0, dmv_1_1);
        #0 $display("%m\tmotion_vert_field_select_0_0: %d motion_vert_field_select_0_1: %d motion_vert_field_select_1_0: %d motion_vert_field_select_1_1: %d", motion_vert_field_select_0_0, motion_vert_field_select_0_1, motion_vert_field_select_1_0, motion_vert_field_select_1_1);
      end

`endif

endmodule
/* not truncated */
