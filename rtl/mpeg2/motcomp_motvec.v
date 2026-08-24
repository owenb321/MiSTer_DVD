/* 
 * motcomp_motvec.v
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
 * motcomp_motvec - Motion compensation: motion vector selection
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

module motcomp_motvec (
  clk, clk_en, rst,
  picture_coding_type, picture_structure, motion_type, dct_type,
  macroblock_motion_forward, macroblock_motion_backward, macroblock_intra, column, row, block, comp, macroblock_address_in, motvec_update, 
  pmv_0_0_0, pmv_0_0_1, pmv_1_0_0, pmv_1_0_1, pmv_0_1_0, pmv_0_1_1, pmv_1_1_0, pmv_1_1_1,
  dmv_0_0, dmv_0_1, dmv_1_0, dmv_1_1,
  motion_vert_field_select_0_0, motion_vert_field_select_0_1, motion_vert_field_select_1_0, motion_vert_field_select_1_1,
  second_field, 
  forward_reference_frame, backward_reference_frame, current_frame, 
  frame_picture, field_in_frame, comp_out, macroblock_address_out,
  delta_x, delta_y,
  fwd_src_frame, fwd_src_field, fwd_mv_x, fwd_mv_y, fwd_valid,
  bwd_src_frame, bwd_src_field, bwd_mv_x, bwd_mv_y, bwd_valid,
  recon_dst_frame, recon_dst_field, recon_delta_x, recon_delta_y, recon_valid,
  write_recon,
  dct_block_cmd, dct_block_en
  );

  input              clk;                          // clock
  input              clk_en;                       // clock enable
  input              rst;                          // synchronous active low reset

  input         [2:0]picture_coding_type;          // identifies whether a picture is an I, P or B picture.
  input         [1:0]picture_structure;            // one of FRAME_PICTURE, TOP_FIELD or BOTTOM_FIELD
  input         [1:0]motion_type;                  // one of MC_FIELD, MC_FRAME, MC_16X8 or MC_DMV
  input              dct_type;                     // either DCT_FIELD or DCT_FRAME
  input              macroblock_motion_forward;
  input              macroblock_motion_backward;
  input              macroblock_intra;
  input              column;
  input signed  [3:0]row;
  input         [1:0]block;                        // number of block, 0..3.
  input         [1:0]comp;
  input        [12:0]macroblock_address_in;
  input              motvec_update;                // asserted when pmv_x_x_x, dmv_x_x valid
  input              motion_vert_field_select_0_0; // motion_vertical_field_select. Indicates which reference field shall be used to form the prediction.
                                                   // If motion_vertical_field_select[r][s] is zero, then the top reference field shall be used,
                                                   // if it is one then the bottom reference field shall be used.
  input              motion_vert_field_select_0_1;
  input              motion_vert_field_select_1_0;
  input              motion_vert_field_select_1_1;
  input              second_field;
  input         [2:0]forward_reference_frame;      /* forward reference frame. Has value 3'd0 or 3'd1 */
  input         [2:0]backward_reference_frame;     /* backward reference frame. Has value 3'd0 or 3'd1 */
  input         [2:0]current_frame;                /* current frame. */
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

`include "mem_codes.v"
`include "vld_codes.v"
`include "motcomp_dctcodes.v"

  /* 
     frame_picture and field_in_frame determine whether to treat the picture as a progressive frame picture, an interlaced frame picture or a field picture.
     If frame_picture == 1 and field_in_frame == 0 picture is a progressive frame picture. 
     If frame_picture == 1 and field_in_frame == 1 picture is an interlaced frame picture, and fwd_src_field, bwd_src_field or recon_dst_field determine which of the two fields to use.
     If frame_picture == 0 picture is an field picture, and fwd_src_field, bwd_src_field or recon_dst_field determine which of the two fields to use.
   */

  output reg               frame_picture;
  output reg               field_in_frame;
  output reg          [1:0]comp_out;                    /* Component. One of COMP_Y, COMP_CR, COMP_CB */
  output reg         [12:0]macroblock_address_out;      /* macroblock address, 0... */
  output reg signed  [12:0]delta_x;                     /* horizontal offset, positive, in pixels, applied to forward and backward motion compensation */
  output reg signed  [12:0]delta_y;                     /* vertical offset, positive, in pixels, applied to forward and backward motion compensation */
  output reg          [2:0]fwd_src_frame;               /* forward source frame */
  output reg               fwd_src_field;               /* forward source field */
  output reg signed  [12:0]fwd_mv_x;                    /* forward motion vector, horizontal component, signed, in halfpixels */
  output reg signed  [12:0]fwd_mv_y;                    /* forward motion vector, horizontal component, signed, in halfpixels */
  output reg               fwd_valid;                   /* assert to enable forward motion compensation */
  output reg          [2:0]bwd_src_frame;               /* backward source frame */
  output reg               bwd_src_field;               /* backward source field */
  output reg signed  [12:0]bwd_mv_x;                    /* backward motion vector, horizontal component, signed, in halfpixels */
  output reg signed  [12:0]bwd_mv_y;                    /* backward motion vector, horizontal component, signed, in halfpixels */
  output reg               bwd_valid;                   /* assert to enable backward motion compensation */ 
  output reg          [2:0]recon_dst_frame;             /* reconstruction destination frame */
  output reg               recon_dst_field;             /* reconstruction destination field */
  output reg signed  [12:0]recon_delta_x;               /* horizontal offset, positive, in pixels, applied to reconstruction */
  output reg signed  [12:0]recon_delta_y;               /* vertical offset, positive, in pixels, applied to reconstruction */
  output reg               write_recon;                 /* write_recon == 0 causes recon to just load the row but not to write any reconstructed pixels to memory. 
                                                           write_recon == 1 causes recon not only to load the row, but also to write the reconstructed pixels to memory. 
                                                           Typically write_recon == 0 in row 0 (load), write_recon == 1 in row 1..8 (reconstruct)
                                                         */
  output reg               recon_valid;                 /* assert to enable motion compensation reconstruction */
  output reg          [2:0]dct_block_cmd;               /* dct frame/field coding translation command. Issued when dct_block_en is asserted. See ISO/IEC 13818-2, par. 6.1.3, fig. 6-13 and 6-14. */
  output reg               dct_block_en;                /* dct frame/field coding translation enable. Asserted once per block. See ISO/IEC 13818-2, par. 6.1.3, fig. 6-13 and 6-14. */


  reg                      next_frame_picture;
  reg                      next_field_in_frame;
  reg                 [1:0]next_comp_out;
  reg                [12:0]next_macroblock_address_out;
  reg signed         [12:0]next_delta_x;
  reg signed         [12:0]next_delta_y;
  reg                 [2:0]next_fwd_src_frame;
  reg                      next_fwd_src_field;
  reg signed         [12:0]next_fwd_mv_x;
  reg signed         [12:0]next_fwd_mv_y;
  reg                      next_fwd_valid;
  reg                 [2:0]next_bwd_src_frame;
  reg                      next_bwd_src_field;
  reg signed         [12:0]next_bwd_mv_x;
  reg signed         [12:0]next_bwd_mv_y;
  reg                      next_bwd_valid;
  reg                 [2:0]next_recon_dst_frame;
  reg                      next_recon_dst_field;
  reg signed         [12:0]next_recon_delta_x;
  reg signed         [12:0]next_recon_delta_y;
  reg                      next_write_recon;
  reg                      next_recon_valid;
  reg                 [2:0]next_dct_block_cmd;
  reg                      next_dct_block_en;

`ifdef DEBUG
  reg               [63:0]mc_descript;
  reg               [63:0]next_mc_descript;
`endif

  /* Table 7-13 and 7-14. Determine motion vectors, source and destination field and frame to use. */

  wire                     current_field = (picture_structure == BOTTOM_FIELD);
  wire                     current_field_in_frame = (comp == COMP_Y) ? ((block == 2'd2) || (block == 2'd3)) : (block == 2'd1);
  wire                     upper_half = (comp == COMP_Y) ? ((block == 2'd0) || (block == 2'd1)) : (block == 2'd0);
  wire signed        [12:0]row_ext = {{9{row[3]}}, row};
  
  always @* 
    if (motvec_update)
      begin
        next_comp_out               = comp;
        next_macroblock_address_out = macroblock_address_in;
        next_dct_block_en           = (block == 2'd0) && (row == -4'sd1) && (column == 1'd0);
      end
    else /* no motvec_update */
      begin
        next_comp_out               = comp_out;
        next_macroblock_address_out = macroblock_address_out;
        next_dct_block_en           = 1'b0;
      end

  always @*
    if (motvec_update && (picture_structure == FRAME_PICTURE))
      begin
        if ((motion_type == MC_FRAME) || (~macroblock_motion_forward && (picture_coding_type == P_TYPE))) /* frame-based prediction in frame picture, including zero motion vector in P-pictures */ // XXX Check
          begin
            next_frame_picture   = 1'b1;
            next_field_in_frame  = 1'b0;
            next_delta_x         = (column ? 13'sd8 : 13'sd0) + (((comp == COMP_Y) && ((block == 2'd1) || (block == 2'd3))) ? 13'sd8 : 13'sd0);
            next_delta_y         = row_ext + 13'sd1 + ((comp == COMP_Y) ? (((block == 2'd2) || (block == 2'd3)) ? 13'sd8 : 13'sd0) : ((block == 2'd1) ? 13'sd4 : 13'sd0));
            next_fwd_src_frame   = forward_reference_frame;
            next_fwd_src_field   = 1'b0;
            next_fwd_mv_x        = pmv_0_0_0;
            next_fwd_mv_y        = pmv_0_0_1;
            next_fwd_valid       = (macroblock_motion_forward || (picture_coding_type == P_TYPE)) && ~macroblock_intra; /* forward prediction, including zero motion vector in P-pictures */
            next_bwd_src_frame   = backward_reference_frame;
            next_bwd_src_field   = 1'b0;
            next_bwd_mv_x        = pmv_0_1_0;
            next_bwd_mv_y        = pmv_0_1_1;
            next_bwd_valid       = macroblock_motion_backward && ~macroblock_intra; /* backward prediction */
            next_recon_dst_frame = current_frame;
            next_recon_dst_field = 1'b0;
            next_recon_delta_x   = (((comp == COMP_Y) && ((block == 2'd1) || (block == 2'd3))) ? 13'sd8 : 13'sd0); 
            next_recon_delta_y   = row_ext + ((comp == COMP_Y) ? (((block == 2'd2) || (block == 2'd3)) ? 13'sd8 : 13'sd0) : ((block == 2'd1) ? 13'sd4 : 13'sd0));
            next_recon_valid     = (column == 1'd1);
            next_write_recon     = (row != -4'sd1);
            next_dct_block_cmd   = (comp == COMP_Y) ? ((dct_type == DCT_FRAME) ? DCT_L4_PASS : DCT_L4_TOP_FIELD_TO_FRAME) : DCT_C1_PASS; /* 4:2:0 chromi blocks are always frame coding, even if dct_type == DCT_FIELD. par. 6.1.3 */
`ifdef DEBUG
            next_mc_descript     = "MC_FRAME";
`endif
          end

        else if (motion_type == MC_FIELD) /* field-based prediction in frame picture. vertical dimensions divided by 2 to scale from frame to field. */
          begin
            next_frame_picture   = 1'b1;
            next_field_in_frame  = 1'b1;
            next_delta_x         = (column ? 13'sd8 : 13'sd0) + (((comp == COMP_Y) && ((block == 2'd1) || (block == 2'd3))) ? 13'sd8 : 13'sd0);
            next_delta_y         = row_ext + 13'sd1;
            next_fwd_src_frame   = forward_reference_frame;
            next_fwd_src_field   = ~current_field_in_frame ? motion_vert_field_select_0_0 /* top field */ : motion_vert_field_select_1_0 /* bottom field */;
            next_fwd_mv_x        = ~current_field_in_frame ? pmv_0_0_0                    /* top field */ : pmv_1_0_0                    /* bottom field */;
            next_fwd_mv_y        = ~current_field_in_frame ? (pmv_0_0_1 >>> 1)            /* top field */ : (pmv_1_0_1 >>> 1)            /* bottom field */;
            next_fwd_valid       = macroblock_motion_forward && ~macroblock_intra; /* forward prediction */
            next_bwd_src_frame   = backward_reference_frame;
            next_bwd_src_field   = ~current_field_in_frame ? motion_vert_field_select_0_1 /* top field */ : motion_vert_field_select_1_1 /* bottom field */;
            next_bwd_mv_x        = ~current_field_in_frame ? pmv_0_1_0                    /* top field */ : pmv_1_1_0                    /* bottom field */;
            next_bwd_mv_y        = ~current_field_in_frame ? (pmv_0_1_1 >>> 1)            /* top field */ : (pmv_1_1_1 >>> 1)            /* bottom field */;
            next_bwd_valid       = macroblock_motion_backward && ~macroblock_intra; /* backward prediction */
            next_recon_dst_frame = current_frame;
            next_recon_dst_field = current_field_in_frame;
            next_recon_delta_x   = (((comp == COMP_Y) && ((block == 2'd1) || (block == 2'd3))) ? 13'sd8 : 13'sd0);
            next_recon_delta_y   = row_ext;
            next_recon_valid     = (column == 1'b1);
            next_write_recon     = (row != -4'sd1);
            next_dct_block_cmd   = (comp == COMP_Y) ? ((dct_type == DCT_FIELD) ? DCT_L4_PASS : DCT_L4_FRAME_TO_TOP_FIELD) : DCT_C1_FRAME_TO_TOP_FIELD;
`ifdef DEBUG
            next_mc_descript     = "MC_FIELD";
`endif
          end

        else if (motion_type == MC_DMV) /* dual prime prediction in frame picture */
          begin
            next_frame_picture   = 1'b1;
            next_field_in_frame  = 1'b1;
            next_delta_x         = (column ? 13'sd8 : 13'sd0) + (((comp == COMP_Y) && ((block == 2'd1) || (block == 2'd3))) ? 13'sd8 : 13'sd0);
            next_delta_y         = row_ext + 13'sd1;
            next_fwd_src_frame   = forward_reference_frame;
            next_fwd_src_field   = current_field_in_frame;
            next_fwd_mv_x        = pmv_0_0_0;
            next_fwd_mv_y        = pmv_0_0_1 >>> 1;
            next_fwd_valid       = macroblock_motion_forward && ~macroblock_intra; /* forward prediction */
            next_bwd_src_frame   = forward_reference_frame;
            next_bwd_src_field   = ~current_field_in_frame;
            next_bwd_mv_x        = current_field_in_frame ? dmv_1_0                      /* bottom field */ : dmv_0_0                      /* top field */;
            next_bwd_mv_y        = current_field_in_frame ? dmv_1_1                      /* bottom field */ : dmv_0_1                      /* top field */;
            next_bwd_valid       = macroblock_motion_forward && ~macroblock_intra; /* forward prediction */
            next_recon_dst_frame = current_frame;
            next_recon_dst_field = current_field_in_frame;
            next_recon_delta_x   = (((comp == COMP_Y) && ((block == 2'd1) || (block == 2'd3))) ? 13'sd8 : 13'sd0);
            next_recon_delta_y   = row_ext;
            next_recon_valid     = (column == 1'b1);
            next_write_recon     = (row != -4'sd1);
            next_dct_block_cmd   = (comp == COMP_Y) ? ((dct_type == DCT_FIELD) ? DCT_L4_PASS : DCT_L4_FRAME_TO_TOP_FIELD) : DCT_C1_FRAME_TO_TOP_FIELD;
`ifdef DEBUG
            next_mc_descript     = "MC_DMV";
`endif
          end

        else /* invalid motion_type for frame picture, should never happen. flush dct blocks to avoid dct fifo stalling */
          begin
            next_frame_picture   = 1'b1;
            next_field_in_frame  = 1'b0;
            next_delta_x         = 13'sd0;
            next_delta_y         = 13'sd0;
            next_fwd_src_frame   = fwd_src_frame;
            next_fwd_src_field   = 1'b0;
            next_fwd_mv_x        = 13'sd0;
            next_fwd_mv_y        = 13'sd0;
            next_fwd_valid       = 1'b0;
            next_bwd_src_frame   = bwd_src_frame;
            next_bwd_src_field   = 1'b0;
            next_bwd_mv_x        = 13'sd0;
            next_bwd_mv_y        = 13'sd0;
            next_bwd_valid       = 1'b0;
            next_recon_dst_frame = current_frame;
            next_recon_dst_field = 1'b0;
            next_recon_delta_x   = (((comp == COMP_Y) && ((block == 2'd1) || (block == 2'd3))) ? 13'sd8 : 13'sd0); 
            next_recon_delta_y   = row_ext + ((comp == COMP_Y) ? (((block == 2'd2) || (block == 2'd3)) ? 13'sd8 : 13'sd0) : ((block == 2'd1) ? 13'sd4 : 13'sd0));
            next_recon_valid     = (column == 1'd1);
            next_write_recon     = (row != -4'sd1);
            next_dct_block_cmd   = (comp == COMP_Y) ? ((dct_type == DCT_FRAME) ? DCT_L4_PASS : DCT_L4_TOP_FIELD_TO_FRAME) : DCT_C1_PASS;
`ifdef DEBUG
            next_mc_descript     = (motion_type == MC_NONE) ? "MC_NONE" : "MC_ERR";
`endif
          end
      end

    else if (motvec_update) /* ((picture_structure == TOP_FIELD) || (picture_structure == BOTTOM_FIELD)) */
      begin
        if ((motion_type == MC_FIELD) || (~macroblock_motion_forward && (picture_coding_type == P_TYPE))) /* field-based prediction in field picture, including zero motion vector in P-pictures */
          begin
            next_frame_picture   = 1'b0;
            next_field_in_frame  = 1'b0;
            next_delta_x         = (column ? 13'sd8 : 13'sd0) + (((comp == COMP_Y) && ((block == 2'd1) || (block == 2'd3))) ? 13'sd8 : 13'sd0);
            next_delta_y         = row_ext + 13'sd1 + ((comp == COMP_Y) ? (((block == 2'd2) || (block == 2'd3)) ? 13'sd8 : 13'sd0) : ((block == 2'd1) ? 13'sd4 : 13'sd0));
            next_fwd_src_frame   = ((picture_coding_type == P_TYPE) && second_field && (current_field != motion_vert_field_select_0_0)) ? backward_reference_frame /* same frame */ : forward_reference_frame /* previous frame */;
            next_fwd_src_field   = motion_vert_field_select_0_0;
            next_fwd_mv_x        = pmv_0_0_0;
            next_fwd_mv_y        = pmv_0_0_1;
            next_fwd_valid       = (macroblock_motion_forward || (picture_coding_type == P_TYPE)) && ~macroblock_intra;
            next_bwd_src_frame   = backward_reference_frame;
            next_bwd_src_field   = motion_vert_field_select_0_1;
            next_bwd_mv_x        = pmv_0_1_0;
            next_bwd_mv_y        = pmv_0_1_1;
            next_bwd_valid       = macroblock_motion_backward && ~macroblock_intra;
            next_recon_dst_frame = current_frame;
            next_recon_dst_field = current_field;
            next_recon_delta_x   = (((comp == COMP_Y) && ((block == 2'd1) || (block == 2'd3))) ? 13'sd8 : 13'sd0); 
            next_recon_delta_y   = row_ext + ((comp == COMP_Y) ? (((block == 2'd2) || (block == 2'd3)) ? 13'sd8 : 13'sd0) : ((block == 2'd1) ? 13'sd4 : 13'sd0));
            next_recon_valid     = (column == 1'd1);
            next_write_recon     = (row != -4'sd1);
            next_dct_block_cmd   = (comp == COMP_Y) ? DCT_L4_PASS : DCT_C1_PASS;
`ifdef DEBUG
            next_mc_descript     = "MC_FIELD";
`endif
          end

        else if (motion_type == MC_16X8) /* 16x8 based motion compensation in field picture */
          begin
            next_frame_picture   = 1'b0;
            next_field_in_frame  = 1'b0;
            next_delta_x         = (column ? 13'sd8 : 13'sd0) + (((comp == COMP_Y) && ((block == 2'd1) || (block == 2'd3))) ? 13'sd8 : 13'sd0);
            next_delta_y         = row_ext + 13'sd1 + ((comp == COMP_Y) ? (((block == 2'd2) || (block == 2'd3)) ? 13'sd8 : 13'sd0) : ((block == 2'd1) ? 13'sd4 : 13'sd0));
            next_fwd_src_frame   = ((picture_coding_type == P_TYPE) && second_field && (current_field != (upper_half ? motion_vert_field_select_0_0 : motion_vert_field_select_1_0))) ? backward_reference_frame /* same frame */ : forward_reference_frame /* previous frame */;
            next_fwd_src_field   = upper_half ? motion_vert_field_select_0_0 : motion_vert_field_select_1_0;
            next_fwd_mv_x        = upper_half ? pmv_0_0_0 : pmv_1_0_0;
            next_fwd_mv_y        = upper_half ? pmv_0_0_1 : pmv_1_0_1;
            next_fwd_valid       = macroblock_motion_forward && ~macroblock_intra;
            next_bwd_src_frame   = backward_reference_frame;
            next_bwd_src_field   = upper_half ? motion_vert_field_select_0_1 : motion_vert_field_select_1_1;
            next_bwd_mv_x        = upper_half ? pmv_0_1_0 : pmv_1_1_0;
            next_bwd_mv_y        = upper_half ? pmv_0_1_1 : pmv_1_1_1;
            next_bwd_valid       = macroblock_motion_backward && ~macroblock_intra;
            next_recon_dst_frame = current_frame;
            next_recon_dst_field = current_field;
            next_recon_delta_x   = (((comp == COMP_Y) && ((block == 2'd1) || (block == 2'd3))) ? 13'sd8 : 13'sd0);
            next_recon_delta_y   = row_ext + ((comp == COMP_Y) ? (((block == 2'd2) || (block == 2'd3)) ? 13'sd8 : 13'sd0) : ((block == 2'd1) ? 13'sd4 : 13'sd0));
            next_recon_valid     = (column == 1'b1);
            next_write_recon     = (row != -4'sd1);
            next_dct_block_cmd   = (comp == COMP_Y) ? DCT_L4_PASS : DCT_C1_PASS;
`ifdef DEBUG
            next_mc_descript     = "MC_16X8";
`endif
          end

        else if (motion_type == MC_DMV) /* dual-prime prediction in field picture */
          begin
            next_frame_picture   = 1'b0;
            next_field_in_frame  = 1'b0;
            next_delta_x         = (column ? 13'sd8 : 13'sd0) + (((comp == COMP_Y) && ((block == 2'd1) || (block == 2'd3))) ? 13'sd8 : 13'sd0);
            next_delta_y         = row_ext + 13'sd1 + ((comp == COMP_Y) ? (((block == 2'd2) || (block == 2'd3)) ? 13'sd8 : 13'sd0) : ((block == 2'd1) ? 13'sd4 : 13'sd0));
            next_fwd_src_frame   = forward_reference_frame;
            next_fwd_src_field   = current_field; /* prediction from field of same parity */
            next_fwd_mv_x        = pmv_0_0_0;
            next_fwd_mv_y        = pmv_0_0_1;
            next_fwd_valid       = macroblock_motion_forward && ~macroblock_intra;
            next_bwd_src_frame   = (second_field) ? backward_reference_frame /* same frame */ : forward_reference_frame /* previous frame */;
            next_bwd_src_field   = ~current_field; /* prediction from field of opposite parity */
            next_bwd_mv_x        = dmv_0_0;
            next_bwd_mv_y        = dmv_0_1;
            next_bwd_valid       = macroblock_motion_forward && ~macroblock_intra;
            next_recon_dst_frame = current_frame;
            next_recon_dst_field = current_field;
            next_recon_delta_x   = (((comp == COMP_Y) && ((block == 2'd1) || (block == 2'd3))) ? 13'sd8 : 13'sd0);
            next_recon_delta_y   = row_ext + ((comp == COMP_Y) ? (((block == 2'd2) || (block == 2'd3)) ? 13'sd8 : 13'sd0) : ((block == 2'd1) ? 13'sd4 : 13'sd0));
            next_recon_valid     = (column == 1'b1);
            next_write_recon     = (row != -4'sd1);
            next_dct_block_cmd   = (comp == COMP_Y) ? DCT_L4_PASS : DCT_C1_PASS;
`ifdef DEBUG
            next_mc_descript     = "MC_DMV";
`endif
          end

        else /* invalid motion_type for field picture, should never happen. flush dct blocks to avoid dct fifo stalling */
          begin
            next_frame_picture   = 1'b0;
            next_field_in_frame  = 1'b0;
            next_delta_x         = 13'sd0;
            next_delta_y         = 13'sd0;
            next_fwd_src_frame   = fwd_src_frame;
            next_fwd_src_field   = current_field;
            next_fwd_mv_x        = 13'sd0;
            next_fwd_mv_y        = 13'sd0;
            next_fwd_valid       = 1'b0;
            next_bwd_src_frame   = bwd_src_frame;
            next_bwd_src_field   = current_field;
            next_bwd_mv_x        = 13'sd0;
            next_bwd_mv_y        = 13'sd0;
            next_bwd_valid       = 1'b0;
            next_recon_dst_frame = current_frame;
            next_recon_dst_field = current_field;
            next_recon_delta_x   = (((comp == COMP_Y) && ((block == 2'd1) || (block == 2'd3))) ? 13'sd8 : 13'sd0); 
            next_recon_delta_y   = row_ext + ((comp == COMP_Y) ? (((block == 2'd2) || (block == 2'd3)) ? 13'sd8 : 13'sd0) : ((block == 2'd1) ? 13'sd4 : 13'sd0));
            next_recon_valid     = (column == 1'd1);
            next_write_recon     = (row != -4'sd1);
            next_dct_block_cmd   = (comp == COMP_Y) ? DCT_L4_PASS : DCT_C1_PASS;
`ifdef DEBUG
            next_mc_descript     = (motion_type == MC_NONE) ? "MC_NONE" : "MC_ERR";
`endif
          end
      end

    else /* no motvec_update */
      begin
        next_frame_picture   = frame_picture;
        next_field_in_frame  = field_in_frame;
        next_delta_x         = delta_x;
        next_delta_y         = delta_y;
        next_fwd_src_frame   = fwd_src_frame;
        next_fwd_src_field   = fwd_src_field;
        next_fwd_mv_x        = fwd_mv_x;
        next_fwd_mv_y        = fwd_mv_y;
        next_fwd_valid       = 1'b0;
        next_bwd_src_frame   = bwd_src_frame;
        next_bwd_src_field   = bwd_src_field;
        next_bwd_mv_x        = bwd_mv_x;
        next_bwd_mv_y        = bwd_mv_y;
        next_bwd_valid       = 1'b0;
        next_recon_dst_frame = recon_dst_frame;
        next_recon_dst_field = recon_dst_field;
        next_recon_delta_x   = recon_delta_x;
        next_recon_delta_y   = recon_delta_y;
        next_recon_valid     = 1'b0;
        next_write_recon     = write_recon;
        next_dct_block_cmd   = dct_block_cmd;
`ifdef DEBUG
        next_mc_descript     = "MC_NONE";
`endif
      end


  always @(posedge clk) 
    if (~rst)
      begin
        frame_picture   <= 1'b0;
        field_in_frame  <= 1'b0;
        comp_out        <= COMP_Y;
        macroblock_address_out <= 13'd0;
        delta_x         <= 13'sd0;
        delta_y         <= 13'sd0;
        fwd_src_frame   <= 3'd0;
        fwd_src_field   <= 1'd0;
        fwd_mv_x        <= 13'sd0;
        fwd_mv_y        <= 13'sd0;
        fwd_valid       <= 1'b0;
        bwd_src_frame   <= 3'd0;
        bwd_src_field   <= 1'd0;
        bwd_mv_x        <= 13'sd0;
        bwd_mv_y        <= 13'sd0;
        bwd_valid       <= 1'b0;
        recon_dst_frame <= 3'd0;
        recon_dst_field <= 1'd0;
        recon_delta_x   <= 13'sd0;
        recon_delta_y   <= 13'sd0;
        recon_valid     <= 1'b0;
        write_recon     <= 1'b0;
        dct_block_cmd   <= 2'd0;
        dct_block_en    <= 1'b0;
`ifdef DEBUG
        mc_descript     <= "";
`endif
      end
    else if (clk_en)
      begin
        frame_picture   <= next_frame_picture;
        field_in_frame  <= next_field_in_frame;
        comp_out        <= next_comp_out;
        macroblock_address_out <= next_macroblock_address_out;
        delta_x         <= next_delta_x;
        delta_y         <= next_delta_y;
        fwd_src_frame   <= next_fwd_src_frame;
        fwd_src_field   <= next_fwd_src_field;
        fwd_mv_x        <= next_fwd_mv_x;
        fwd_mv_y        <= next_fwd_mv_y;
        fwd_valid       <= next_fwd_valid;
        bwd_src_frame   <= next_bwd_src_frame;
        bwd_src_field   <= next_bwd_src_field;
        bwd_mv_x        <= next_bwd_mv_x;
        bwd_mv_y        <= next_bwd_mv_y;
        bwd_valid       <= next_bwd_valid;
        recon_dst_frame <= next_recon_dst_frame;
        recon_dst_field <= next_recon_dst_field;
        recon_delta_x   <= next_recon_delta_x;
        recon_delta_y   <= next_recon_delta_y;
        recon_valid     <= next_recon_valid;
        write_recon     <= next_write_recon;
        dct_block_cmd   <= next_dct_block_cmd;
        dct_block_en    <= next_dct_block_en;
`ifdef DEBUG
        mc_descript     <= next_mc_descript;
`endif
      end
    else
      begin
        frame_picture   <= frame_picture;
        field_in_frame  <= field_in_frame;
        comp_out        <= comp_out;
        macroblock_address_out <= macroblock_address_out;
        delta_x         <= delta_x;
        delta_y         <= delta_y;
        fwd_src_frame   <= fwd_src_frame;
        fwd_src_field   <= fwd_src_field;
        fwd_mv_x        <= fwd_mv_x;
        fwd_mv_y        <= fwd_mv_y;
        fwd_valid       <= fwd_valid;
        bwd_src_frame   <= bwd_src_frame;
        bwd_src_field   <= bwd_src_field;
        bwd_mv_x        <= bwd_mv_x;
        bwd_mv_y        <= bwd_mv_y;
        bwd_valid       <= bwd_valid;
        recon_dst_frame <= recon_dst_frame;
        recon_dst_field <= recon_dst_field;
        recon_delta_x   <= recon_delta_x;
        recon_delta_y   <= recon_delta_y;
        recon_valid     <= recon_valid;
        write_recon     <= write_recon;
        dct_block_cmd   <= dct_block_cmd;
        dct_block_en    <= dct_block_en;
`ifdef DEBUG
        mc_descript     <= mc_descript;
`endif
      end

`ifdef DEBUG
  always @(posedge clk)
    if (clk_en && motvec_update && (comp == COMP_Y) && (block == 0 ) && (row == 0) && (column == 1))
      begin
        if (picture_structure == FRAME_PICTURE)
          begin
            if(fwd_valid && bwd_valid)
              $display("%m\t macroblock_address %4d %8s       fwd (%5d, %5d) bwd (%5d, %5d)",
                       macroblock_address_in, mc_descript, fwd_mv_x, fwd_mv_y, bwd_mv_x, bwd_mv_y);
            else if (fwd_valid && ~bwd_valid)
              $display("%m\t macroblock_address %4d %8s       fwd (%5d, %5d)",
                       macroblock_address_in, mc_descript, fwd_mv_x, fwd_mv_y);
            else if (~fwd_valid && bwd_valid)
              $display("%m\t macroblock_address %4d %8s                                 bwd (%5d, %5d)",
                       macroblock_address_in, mc_descript, bwd_mv_x, bwd_mv_y);
            else
              $display("%m\t macroblock_address %4d %8s intra",
                       macroblock_address_in, mc_descript);
          end
        else
          begin
            if(fwd_valid && bwd_valid)
              $display("%m\t macroblock_address %4d field %d %8s       fwd field %d (%5d, %5d) bwd field %d (%5d, %5d)",
                       macroblock_address_in, recon_dst_field, mc_descript, fwd_src_field, fwd_mv_x, fwd_mv_y, bwd_src_field, bwd_mv_x, bwd_mv_y);
            else if (fwd_valid && ~bwd_valid)
              $display("%m\t macroblock_address %4d field %d %8s       fwd field %d (%5d, %5d)",
                       macroblock_address_in, recon_dst_field, mc_descript, fwd_src_field, fwd_mv_x, fwd_mv_y);
            else if (~fwd_valid && bwd_valid)
              $display("%m\t macroblock_address %4d field %d %8s                                        bwd field %d (%5d, %5d)",
                       macroblock_address_in, recon_dst_field, mc_descript, bwd_src_field, bwd_mv_x, bwd_mv_y);
            else
              $display("%m\t macroblock_address %4d field %d %8s intra",
                       macroblock_address_in, recon_dst_field, mc_descript);
          end
      end
`endif

`ifdef DEBUG_MOTVEC
  always @(posedge clk)
    if (clk_en)
      begin
        $strobe("%m\t  motvec_update: %d macroblock_address_in: %d comp: %d block: %d row: %d column: %d",
                     motvec_update, macroblock_address_in, comp, block, row, column);
        $strobe("%m\t  current_field: %d frame_picture: %d field_in_frame: %d delta_x: %d delta_y: %d",
                     current_field, frame_picture, field_in_frame, delta_x, delta_y);
        $strobe("%m\t  fwd_src_frame: %d fwd_src_field: %d fwd_mv_x: %d fwd_mv_y: %d fwd_valid: %d",
                     fwd_src_frame, fwd_src_field, fwd_mv_x, fwd_mv_y, fwd_valid);
        $strobe("%m\t  bwd_src_frame: %d bwd_src_field: %d bwd_mv_x: %d bwd_mv_y: %d bwd_valid: %d",
                     bwd_src_frame, bwd_src_field, bwd_mv_x, bwd_mv_y, bwd_valid);
        $strobe("%m\t  recon_dst_frame: %d recon_dst_field: %d recon_delta_x: %d recon_delta_y: %d fwd_valid: %d bwd_valid: %d recon_valid: %d write_recon: %d",
                     recon_dst_frame, recon_dst_field, recon_delta_x, recon_delta_y, fwd_valid, bwd_valid, recon_valid, write_recon);
        $strobe("%m\t  dct_block_cmd: %d dct_block_en: %d",
                     dct_block_cmd, dct_block_en);
      end
`endif

endmodule
/* not truncated */
