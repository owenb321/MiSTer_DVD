/* 
 * mpeg2video.v
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
 *
 * MPEG-2 License Notice
 * 
 * Commercial implementations of MPEG-1 and MPEG-2 video, including shareware,
 * are subject to royalty fees to patent holders.  Many of these patents are
 * general enough such that they are unavoidable regardless of implementation
 * design.
 *
 * "MPEG-2 INTERMEDIATE PRODUCT. USE OF THIS PRODUCT IN ANY MANNER THAT COMPLIES
 * WITH THE MPEG-2 STANDARD IS EXPRESSLY PROHIBITED WITHOUT A LICENSE UNDER 
 * APPLICABLE PATENTS IN THE MPEG-2 PATENT PORTFOLIO, WHICH LICENSE IS AVAILABLE 
 * FROM MPEG LA, L.L.C., 250 STELLE STREET, SUITE 300, DENVER, COLORADO 80206."
 *
 */

/*
 * mpeg2 decoder.
 *
 * Input:
 *   stream_data:  video elementary stream
 * Output:
 *   r, g, b, pixel_en, h_sync, v_sync: rgb values and video synchronisation
 */

`include "timescale.v"

`undef CHECK
`ifdef __IVERILOG__
`define CHECK 1
`endif

module mpeg2video(clk, mem_clk, dot_clk, 
             rst,                                                                                                                 // clocked with clk
             stream_data, stream_valid,                                                                                           // clocked with clk
	     reg_addr, reg_wr_en, reg_dta_in, reg_rd_en, reg_dta_out,                                                             // clocked with clk
             busy, error, interrupt, watchdog_rst,                                                                                // clocked with clk
             r, g, b, y, u, v, pixel_en, h_sync, v_sync, c_sync, h_pos, v_pos,                                                     // clocked with dot_clk
             mem_req_rd_cmd, mem_req_rd_addr, mem_req_rd_dta, mem_req_rd_en, mem_req_rd_valid,                                    // clocked with mem_clk
             mem_res_wr_dta, mem_res_wr_en, mem_res_wr_almost_full,                                                               // clocked with mem_clk
             testpoint_dip, testpoint_dip_en, testpoint
	     );

  input            clk;                     // clock. Typically a multiple of 27 Mhz as MPEG2 timestamps have a 27 Mhz resolution.
  input            mem_clk;                 // memory clock. Typically 133-166 MHz.
  input            dot_clk;                 // video clock. Typically between 25 and 75 Mhz, depending upon MPEG2 resolution and frame rate.

  input            rst;                     // active low reset. Internally synchronized.

  /* MPEG stream input */
  input       [7:0]stream_data;             // packetized elementary stream input
  input            stream_valid;            // stream_data valid

  /* RGB output */
  output      [7:0]r;                       // red component
  output      [7:0]g;                       // green component
  output      [7:0]b;                       // blue component
  output      [7:0]y;                       // luminance 
  output      [7:0]u;                       // chrominance
  output      [7:0]v;                       // chrominance
  output           pixel_en;                // pixel enable - asserted if r, g and b valid.
  output           h_sync;                  // horizontal synchronisation
  output           v_sync;                  // vertical synchronisation
  output           c_sync;                  // composite synchronisation
  output     [11:0]h_pos;                   // horizontal position; 0 = left
  output     [11:0]v_pos;                   // vertical position; 0 = top

  /* register file access */
  input       [3:0]reg_addr;
  input      [31:0]reg_dta_in;
  input            reg_wr_en;
  output     [31:0]reg_dta_out;
  input            reg_rd_en;

  output reg       busy;                    // assert busy when input fifo risks overflow
  output           error;
  output           interrupt;               // asserted when image size changes, or when vld error occurs. cleared when status register read.

  /* memory controller interface */
  output      [1:0]mem_req_rd_cmd;
  output     [21:0]mem_req_rd_addr;
  output     [63:0]mem_req_rd_dta;
  input            mem_req_rd_en;
  output           mem_req_rd_valid;
  input      [63:0]mem_res_wr_dta;
  input            mem_res_wr_en;
  output           mem_res_wr_almost_full;
  wire             mem_res_wr_full;

  /* logical analyzer test point */
  input       [3:0]testpoint_dip;
  input            testpoint_dip_en;
  output     [33:0]testpoint;
  wire        [3:0]testpoint_regfile;

  /* reset signals */
  wire             sync_rst;                // reset, either from rst input pin or watchdog, synchronized to clk
  wire             mem_rst;                 // reset, either from rst input pin or watchdog, synchronized to mem_clk
  wire             dot_rst;                 // reset, either from rst input pin or watchdog, synchronized to dot_clk
  wire             hard_rst;                // reset, only from rst input, synchronized to clk

  /* watchdog timer */
  output           watchdog_rst;            // low when watchdog timer expires.
  wire        [7:0]watchdog_interval;       // new value of the watchdog interval. 255 = never expire; 0 = expire immediate. 
  wire             watchdog_interval_wr;    // asserted when the watchdog interval is written 
  wire             watchdog_status_rd;      // asserted when the watchdog status is read 
  wire             watchdog_status;         // high if watchdog timer has expired

  /* vbuf_write - vbw fifo interface */
  wire  [63:0]vbw_wr_dta;
  wire        vbw_wr_en;
  wire        vbw_wr_full;
  wire        vbw_wr_almost_full;

  /* vbw fifo - framestore interface */
  wire  [63:0]vbw_rd_dta;
  wire        vbw_rd_en;
  wire        vbw_rd_valid;
  wire        vbw_rd_empty;
  wire        vbw_rd_almost_empty;

  /* framestore - vbr fifo interface */
  wire  [63:0]vbr_wr_dta;
  wire        vbr_wr_en;
  wire        vbr_wr_ack;
  wire        vbr_wr_full;
  wire        vbr_wr_almost_full;

  /* vbr fifo - getbits fifo interface */
  wire  [63:0]vbr_rd_dta;
  wire        vbr_rd_en;
  wire        vbr_rd_valid;
  wire        vbr_rd_almost_empty;
  wire        vbr_rd_empty;

  /* getbits_fifo - vld interface */
  wire  [4:0]advance;                       // number of bits to advance the bitstream (advance <= 24)   
  wire       align;                         // byte-align getbits and move forward one byte.
  wire [23:0]getbits;                       // elementary stream data. 
  wire       signbit;                       // sign bit, used when decoding dct variable length codes.
  wire       getbits_valid;                 // getbits_valid is asserted when getbits is valid.
  wire       wait_state;                    // after vld requesting getbits to advance or align, vld should wait one cycle for getbits to process the request.
  wire       vld_en;                        // enable vld when getbits, rld, motcomp not busy, and not a wait state 
         
  /* vld - rld_fifo interface */
  wire  [5:0]dct_coeff_wr_run;              // dct coefficient runlength, from vlc decoding
  wire [11:0]dct_coeff_wr_signed_level;     // dct coefficient level, 2's complement format, from vlc decoding
  wire       dct_coeff_wr_end;              // dct_coeff_end_in is asserted at end of block 
  wire       rld_wr_almost_full;            // rld fifo almost full signal; used as throttle for vld 
  wire       rld_wr_en;                     // rld fifo write enable
  wire       rld_wr_overflow;               // rld fifo write overflow
  wire  [1:0]rld_cmd_wr;                    // rld command (dct run/level code or quantizer matrix update)
  wire  [4:0]quantiser_scale_code;
  wire       alternate_scan;
  wire       q_scale_type;                  // quantizer scale type
  wire       macroblock_intra;
  wire  [1:0]intra_dc_precision;
  wire  [7:0]quant_wr_data_wr;              // data bus for writing quantizer matrix rams
  wire  [5:0]quant_wr_addr_wr;              // address bus for writing quantizer matrix rams
  wire       quant_rst_wr;                  // reset quantizer matrix to default values
  wire       quant_wr_intra_wr;             // write enable for intra quantiser matrix
  wire       quant_wr_non_intra_wr;         // write enable for non intra quantiser matrix
  wire       quant_wr_chroma_intra_wr;      // write enable for chroma intra quantiser matrix
  wire       quant_wr_chroma_non_intra_wr;  // write enable for chroma non intra quantiser matrix

  /* rld_fifo - rld interface */
  wire  [5:0]dct_coeff_rd_run;              // dct coefficient runlength, from vlc decoding
  wire [11:0]dct_coeff_rd_signed_level;     // dct coefficient level, 2's complement format, from vlc decoding
  wire       dct_coeff_rd_end;              // dct_coeff_end_out is asserted at end of block 
  wire       alternate_scan_rd;
  wire       q_scale_type_rd;               // quantizer scale type
  wire       macroblock_intra_rd;
  wire  [1:0]intra_dc_precision_rd;
  wire  [4:0]quantiser_scale_code_rd;
  wire  [7:0]quant_wr_data_rd;              // data bus for writing quantizer matrix rams
  wire  [5:0]quant_wr_addr_rd;              // address bus for writing quantizer matrix rams
  wire       quant_rst_rd;                  // reset quantizer matrix to default values
  wire       quant_wr_intra_rd;             // write enable for intra quantiser matrix
  wire       quant_wr_non_intra_rd;         // write enable for non intra quantiser matrix
  wire       quant_wr_chroma_intra_rd;      // write enable for chroma intra quantiser matrix
  wire       quant_wr_chroma_non_intra_rd;  // write enable for chroma non intra quantiser matrix
  wire  [1:0]rld_cmd_rd;
  wire       rld_rd_en;                     // rld fifo read enable
  wire       rld_rd_valid;                  // asserted when fifo outputs are valid

  /* quantiser ram - rld interface */
  wire       quant_rst;                     // reset quantizer matrix to default values
  wire  [5:0]quant_rd_addr;                 // address bus for reading quantizer matrix rams
  wire  [7:0]quant_rd_intra_data;           // data bus for reading quantizer matrix rams
  wire  [7:0]quant_rd_non_intra_data;       // data bus for reading quantizer matrix rams
  wire  [7:0]quant_wr_data;                 // data bus for writing quantizer matrix rams
  wire  [5:0]quant_wr_addr;                 // address bus for writing quantizer matrix rams
  wire       quant_wr_en_intra;             // write enable for intra quantiser matrix
  wire       quant_wr_en_non_intra;         // write enable for non intra quantiser matrix
  wire       quant_wr_en_chroma_intra;      // write enable for chroma intra quantiser matrix
  wire       quant_wr_en_chroma_non_intra;  // write enable for chroma non intra quantiser matrix
  wire       quant_alternate_scan;          // alternate scan

  /* idct - rld interface */
  wire [11:0]iquant_level;                  // inverse quantized dct coefficient
  wire       iquant_eob;                    // asserted at last inverse quantized dct coefficient of block
  wire       iquant_valid;                  // asserted when inverse quantized dct coefficient valid

  /* idct - idct_fifo interface */
  wire  [8:0]idct_data;
  wire       idct_eob;
  wire       idct_valid;

  /* idct_fifo - motcomp interface */
  wire             idct_fifo_almost_full;
  wire             idct_fifo_overflow;
  wire             idct_rd_dta_valid;
  wire             idct_rd_dta_empty;
  wire             idct_rd_dta_en;
  wire       [71:0]idct_rd_dta;

  /* vld - motcomp interface */
  wire         [2:0]picture_coding_type;
  wire         [1:0]picture_structure;
  wire         [1:0]motion_type;
  wire              dct_type;
  wire        [12:0]macroblock_address;
  wire              macroblock_motion_forward;
  wire              macroblock_motion_backward;
  wire         [7:0]mb_width;
  wire         [7:0]mb_height;
  wire              motion_vert_field_select_0_0;
  wire              motion_vert_field_select_0_1;
  wire              motion_vert_field_select_1_0;
  wire              motion_vert_field_select_1_1;
  wire              second_field;
  wire              update_picture_buffers;
  wire              last_frame;
  wire         [1:0]chroma_format;
  wire              motion_vector_valid;    // asserted when pmv_x_x_x, dmv_x_x valid
  wire signed [12:0]pmv_0_0_0;              // predicted motion vector
  wire signed [12:0]pmv_0_0_1;              // predicted motion vector
  wire signed [12:0]pmv_1_0_0;              // predicted motion vector
  wire signed [12:0]pmv_1_0_1;              // predicted motion vector
  wire signed [12:0]pmv_0_1_0;              // predicted motion vector
  wire signed [12:0]pmv_0_1_1;              // predicted motion vector
  wire signed [12:0]pmv_1_1_0;              // predicted motion vector
  wire signed [12:0]pmv_1_1_1;              // predicted motion vector
  wire signed [12:0]dmv_0_0;                // dual-prime motion vector
  wire signed [12:0]dmv_0_1;                // dual-prime motion vector
  wire signed [12:0]dmv_1_0;                // dual-prime motion vector
  wire signed [12:0]dmv_1_1;                // dual-prime motion vector
  wire              mvec_wr_almost_full;    // asserted if motion vector fifo fills up; used for flow control


  /* motcomp output */
  wire             motcomp_busy;            // asserted when motcomp input fifo's full

  /* vld - syncgen interface */
  wire       [13:0]horizontal_size;         // horizontal size of frame
  wire       [13:0]vertical_size;           // vertical size of frame
  wire       [13:0]display_horizontal_size; // displayable part of frame. If non-zero, always less than horizontal_size.
  wire       [13:0]display_vertical_size;   // displayable part of frame. If non-zero, always less than vertical_size.

  /* syncgen - mixer interface */
  wire             pixel_en_gen;            // pixel enable generated by syncgen
  wire             h_sync_gen;              // h_sync generated by syncgen
  wire             v_sync_gen;              // v_sync generated by syncgen

  /* vld - syncgen interface */
  wire        [7:0]matrix_coefficients;     // determines yuv to rgb conversion factors

  /* resample - pixel queue interface */
  wire        [7:0]y_resample;              // luminance
  wire        [7:0]u_resample;              // chrominance
  wire        [7:0]v_resample;              // chrominance
  wire        [7:0]osd_resample;            // osd pixel color 
  wire        [2:0]position_resample;       // position, as in resample_codes.v
  wire             pixel_wr_en;
  wire             pixel_wr_almost_full;
  wire             pixel_wr_full;
  wire             pixel_wr_overflow;

  /* pixel queue - pixel repetition interface */
  wire        [7:0]y_pqueue;                // luminance
  wire        [7:0]u_pqueue;                // chrominance
  wire        [7:0]v_pqueue;                // chrominance
  wire        [7:0]osd_pqueue;              // osd pixel color 
  wire        [2:0]position_pqueue;         // position, as in resample_codes.v
  wire             pixel_rd_en_pqueue;
  wire             pixel_rd_empty_pqueue;
  wire             pixel_rd_valid_pqueue;
  wire             pixel_rd_underflow_pqueue;

  /* mixer - osd interface */
  wire        [7:0]y_mixer;                 // luminance
  wire        [7:0]u_mixer;                 // chrominance
  wire        [7:0]v_mixer;                 // chrominance
  wire        [7:0]osd_mixer;               // osd pixel color 
  wire             h_sync_mixer;
  wire             v_sync_mixer;
  wire             pixel_en_mixer;

  /* osd - yuv2rgb interface */
  wire             pixel_en_osd;            // pixel enable 
  wire             h_sync_osd;              // h_sync 
  wire             v_sync_osd;              // v_sync
  wire        [7:0]y_osd;                   // luminance
  wire        [7:0]u_osd;                   // chrominance
  wire        [7:0]v_osd;                   // chrominance

  /* osd - osd_clt interface */
  wire        [7:0]osd_clt_rd_addr;
  wire             osd_clt_rd_en;
  wire       [31:0]osd_clt_rd_dta;

  /* regfile - osd_clt interface */
  wire             osd_clt_wr_en;
  wire        [7:0]osd_clt_wr_addr;
  wire       [31:0]osd_clt_wr_dta;

  /* regfile - osd interface */
  wire             osd_enable;

  /* vld - regfile interface */
  wire             vld_err;
  wire        [3:0]frame_rate_code;         // par. 6.3.3, Table 6-4
  wire        [1:0]frame_rate_extension_n;  // par. 6.3.3, par. 6.3.5
  wire        [4:0]frame_rate_extension_d;  // par. 6.3.3, par. 6.3.5
  wire        [3:0]aspect_ratio_information;// par. 6.3.3

  assign           error = vld_err;

  /* regfile - syncgen interface */
  wire [11:0]horizontal_resolution;         /* horizontal resolution. number of dots per line, minus one  */
  wire [11:0]horizontal_sync_start;         /* the dot the horizontal sync pulse begins. */
  wire [11:0]horizontal_sync_end;           /* the dot the horizontal sync pulse ends. */
  wire [11:0]horizontal_length;             /* total horizontal length */
  wire [11:0]vertical_resolution;           /* vertical resolution. number of visible lines per frame (progressive) or field (interlaced), minus one */
  wire [11:0]vertical_sync_start;           /* the line number within the frame (progressive) or field (interlaced) the vertical sync pulse begins. */
  wire [11:0]vertical_sync_end;             /* the line number within the frame (progressive) or field (interlaced) the vertical sync pulse ends. */
  wire [11:0]horizontal_halfline;           /* the dot the vertical sync begins on odd frames of interlaced video. Not used in progressive mode. */
  wire [11:0]vertical_length;               /* total number of lines of a vertical frame (progressive) or field (interlaced) */
  wire       interlaced;                    /* asserted if interlaced output required. */
  wire       pixel_repetition;              /* assert for dot clock rates < 25 MHz, repeats each pixel */
  wire       clip_display_size;             /* assert to clip image to (display_horizontal_size, display_vertical_size) */
  wire       syncgen_rst;                   /* resets sync generator whenever a modeline parameter changes */

  /* regfile - picbuf  interface */
  wire  [2:0]source_select;                 /* select video out source */

  /* regfile - resample interface */
  wire       deinterlace;                   /* assert if video has to be deinterlaced */
  wire  [4:0]repeat_frame;                  /* repeat decoded images */
  wire       persistence;                   /* last decoded image persists */

  /* motcomp - resample interface */
  wire  [2:0]output_frame;                  /* frame to be displayed */
  wire       output_frame_valid;            /* asserted when output_frame valid */
  wire       output_frame_rd;               /* asserted to read next output_frame */
  wire       output_progressive_sequence;
  wire       output_progressive_frame;
  wire       output_top_field_first;
  wire       output_repeat_first_field;

  /* vld - motcomp_picbuf interface */
  wire       progressive_sequence;
  wire       progressive_frame;
  wire       top_field_first;
  wire       repeat_first_field;

  /*
   * Interface with frame store is through fifo's.
   */
  
  /* 
   * fifo between motion compensation and frame store:
   * reading forward reference frame.
   */ 

  wire       fwd_wr_addr_clk_en;
  wire       fwd_wr_addr_full;
  wire       fwd_wr_addr_almost_full;
  wire       fwd_wr_addr_en;
  wire       fwd_wr_addr_ack;
  wire [21:0]fwd_wr_addr;
  wire       fwd_rd_dta_clk_en;
  wire       fwd_rd_dta_almost_empty;
  wire       fwd_rd_dta_empty;
  wire       fwd_rd_dta_en;
  wire       fwd_rd_dta_valid;
  wire [63:0]fwd_rd_dta;
  wire       fwd_rd_addr_empty;
  wire       fwd_rd_addr_en;
  wire       fwd_rd_addr_valid;
  wire [21:0]fwd_rd_addr;
  wire       fwd_wr_dta_full;
  wire       fwd_wr_dta_almost_full;
  wire       fwd_wr_dta_en;
  wire       fwd_wr_dta_ack;
  wire [63:0]fwd_wr_dta;

  /* 
   * fifo between motion compensation and frame store:
   * reading backward reference frame.
   */ 

  wire       bwd_wr_addr_clk_en;
  wire       bwd_wr_addr_full;
  wire       bwd_wr_addr_almost_full;
  wire       bwd_wr_addr_en;
  wire       bwd_wr_addr_ack;
  wire [21:0]bwd_wr_addr;
  wire       bwd_rd_dta_clk_en;
  wire       bwd_rd_dta_empty;
  wire       bwd_rd_dta_almost_empty;
  wire       bwd_rd_dta_en;
  wire       bwd_rd_dta_valid;
  wire [63:0]bwd_rd_dta;
  wire       bwd_rd_addr_empty;
  wire       bwd_rd_addr_en;
  wire       bwd_rd_addr_valid;
  wire [21:0]bwd_rd_addr;
  wire       bwd_wr_dta_full;
  wire       bwd_wr_dta_almost_full;
  wire       bwd_wr_dta_en;
  wire       bwd_wr_dta_ack;
  wire [63:0]bwd_wr_dta;

  /* 
   * fifo between motion compensation and frame store:
   * writing reconstructed frame.
   */ 
 
  wire       recon_wr_full;
  wire       recon_wr_almost_full;
  wire       recon_wr_en;
  wire       recon_wr_ack;
  wire [21:0]recon_wr_addr;
  wire [63:0]recon_wr_dta;
  wire       recon_rd_empty;
  wire       recon_rd_almost_empty;
  wire       recon_rd_en;
  wire       recon_rd_valid;
  wire [21:0]recon_rd_addr;
  wire [63:0]recon_rd_dta;

  /*
   * fifo between chroma resampling and frame store:
   * reading reconstructed frames.
   */

  wire       disp_wr_addr_full;
  wire       disp_wr_addr_almost_full;
  wire       disp_wr_addr_en;
  wire       disp_wr_addr_ack;
  wire [21:0]disp_wr_addr;
  wire       disp_rd_dta_empty;
  wire       disp_rd_dta_almost_empty;
  wire       disp_rd_dta_en;
  wire       disp_rd_dta_valid;
  wire [63:0]disp_rd_dta;
  wire       disp_rd_addr_empty;
  wire       disp_rd_addr_en;
  wire       disp_rd_addr_valid;
  wire [21:0]disp_rd_addr;
  wire       disp_wr_dta_full;
  wire       disp_wr_dta_almost_full;
  wire       disp_wr_dta_en;
  wire       disp_wr_dta_ack;
  wire [63:0]disp_wr_dta;

  /* 
   * fifo between register file and frame store:
   * writing on-screen display
   */ 

  wire       osd_wr_almost_full;
  wire       osd_wr_full;
  wire       osd_wr_en;
  wire       osd_wr_ack;
  wire [21:0]osd_wr_addr;
  wire [63:0]osd_wr_dta;
  wire       osd_rd_almost_empty;
  wire       osd_rd_empty;
  wire       osd_rd_en;
  wire       osd_rd_valid;
  wire [21:0]osd_rd_addr;
  wire [63:0]osd_rd_dta;

  /* more overflows */
  wire       mem_req_wr_almost_full;
  wire       mem_req_wr_full;
  wire       mem_req_wr_overflow;
  wire       tag_wr_almost_full;
  wire       tag_wr_full;
  wire       tag_wr_overflow;
  wire       mem_res_wr_overflow;
  wire       vbw_wr_overflow;
  wire       vbr_wr_overflow;
  wire       dct_block_wr_overflow;
  wire       frame_idct_wr_overflow;
  wire       mvec_wr_overflow;
  wire       dst_wr_overflow;
  wire       fwd_wr_addr_overflow;
  wire       fwd_wr_dta_overflow;
  wire       bwd_wr_addr_overflow;
  wire       bwd_wr_dta_overflow;
  wire       recon_wr_overflow;
  wire       resample_wr_overflow;
  wire       disp_wr_addr_overflow;
  wire       disp_wr_dta_overflow;
  wire       osd_wr_overflow;

`include "fifo_size.v"

  /* 
   * assert "busy" at power-on, to allow dual-port rams such as
   * quantizer matrices and osd lookup-table to be cleared / initialized.
   */
  reg [8:0]init_cnt;
  always @(posedge clk)
    if (~sync_rst) init_cnt <= 9'h0;
    else init_cnt <= (init_cnt == 9'h1ff) ? init_cnt : init_cnt + 9'd1;

  always @(posedge clk)
    if (~sync_rst) busy <= 1'b1;
    else busy <= vbw_wr_almost_full || ~sync_rst || (init_cnt != 9'h1ff);

  /* reset signal synchronizers */

  reset reset (
    .clk(clk), 
    .mem_clk(mem_clk), 
    .dot_clk(dot_clk), 
    .async_rst(rst),
    .watchdog_rst(watchdog_rst),
    .clk_rst(sync_rst), 
    .mem_rst(mem_rst), 
    .dot_rst(dot_rst),
    .hard_rst(hard_rst)
    );

  /* register synchronizers */

  wire  [7:0]dot_matrix_coefficients;
  wire       dot_interlaced;
  wire       dot_pixel_repetition;
  wire       dot_osd_enable;

  sync_reg #(.width(8))  sync_matrix_coefficients     (dot_clk, dot_rst, matrix_coefficients, dot_matrix_coefficients);
  sync_reg #(.width(1))  sync_interlaced              (dot_clk, dot_rst, interlaced, dot_interlaced);
  sync_reg #(.width(1))  sync_pixel_repetition        (dot_clk, dot_rst, pixel_repetition, dot_pixel_repetition);
  sync_reg #(.width(1))  sync_osd_enable              (dot_clk, dot_rst, osd_enable, dot_osd_enable);

  /* test point synchronizer, for reading test point via register file */
  wire [31:0]regfile_testpoint;
  sync_reg #(.width(32)) sync_testpoint               (clk, sync_rst, testpoint[31:0], regfile_testpoint); // Only pass on bits 31..0. bits 32 and 33 are likely to be clocks and clock enables.

  /* vertical sync synchronizer, for generating interrupt at vertical sync start */
  wire       regfile_v_sync;
  sync_reg #(.width(1))  sync_v_sync                  (clk, sync_rst, v_sync_gen, regfile_v_sync);

  /* flush video buffer */
  wire       flush_vbuf;                              /* flush video buffer */
  wire       vbuf_rst;                                /* circular video buffer reset signal, synchronized and at least three clocks long */

  sync_reset sync_vbuf_reset (
    .clk(clk),
    .asyncrst(rst && ~flush_vbuf),
    .syncrst(vbuf_rst)
    );

  /* write elementary stream to circular buffer */
  vbuf_write vbuf_write (
    .clk(clk),
    .clk_en(1'b1),
    .rst(sync_rst),
    .vid_in(stream_data),                                    // program stream input
    .vid_in_wr_en(stream_valid),                             // program stream input
    .vid_out(vbw_wr_dta),                                    // to vbuf_write_fifo
    .vid_out_wr_en(vbw_wr_en)                                // to vbuf_write_fifo
    );

  /* vbuf write fifo */
  fifo_sc
    #(.addr_width(VBUF_WR_DEPTH),
    .dta_width(9'd64),
    .prog_thresh(VBUF_WR_THRESHOLD))
    vbuf_write_fifo (
    .rst(vbuf_rst), 
    .clk(clk),  
    .din(vbw_wr_dta),                                        // from vbuf_write
    .wr_en(vbw_wr_en),                                       // from vbuf_write
    .wr_ack(),   
    .full(vbw_wr_full),   
    .overflow(vbw_wr_overflow),
    .dout(vbw_rd_dta),                                       // to framestore
    .rd_en(vbw_rd_en),                                       // to framestore
    .valid(vbw_rd_valid),                                    // to framestore
    .empty(vbw_rd_empty),                                    // to framestore
    .prog_empty(vbw_rd_almost_empty),                        // to framestore
    .prog_full(vbw_wr_almost_full),                          // to framestore and output pin "busy"
    .underflow()
    );           

  /* vbuf read fifo */
  fifo_sc
    #(.addr_width(VBUF_RD_DEPTH),
    .dta_width(9'd64),
    .prog_thresh(VBUF_RD_THRESHOLD))
    vbuf_read_fifo (
    .rst(vbuf_rst), 
    .clk(clk),  
    .din(vbr_wr_dta),                                        // from framestore
    .wr_en(vbr_wr_en),                                       // from framestore
    .wr_ack(vbr_wr_ack),                                     // to framestore
    .full(vbr_wr_full),                                      // to framestore
    .overflow(vbr_wr_overflow),                              // to probe
    .dout(vbr_rd_dta),                                       // to getbits_fifo
    .rd_en(vbr_rd_en),                                       // from getbits_fifo
    .valid(vbr_rd_valid),                                    // to getbits_fifo
    .empty(vbr_rd_empty),                                    // to probe
    .prog_empty(vbr_rd_almost_empty),                        // to framestore
    .prog_full(vbr_wr_almost_full),                          // to framestore
    .underflow()
    );           

  /* read elementary stream from circular buffer, one bitfield at a time */
  getbits_fifo getbits_fifo (
    .clk(clk), 
    .clk_en(1'b1), 
    .rst(sync_rst), 
    .vid_in(vbr_rd_dta),                                     // from vbuf_read_fifo
    .vid_in_rd_en(vbr_rd_en),                                // to vbuf_read_fifo
    .vid_in_rd_valid(vbr_rd_valid),                          // from vbuf_read_fifo
    .advance(advance),                                       // from vld
    .align(align),                                           // from vld
    .wait_state(wait_state),                                 // from vld
    .rld_wr_almost_full(rld_wr_almost_full),                 // from rld fifo
    .mvec_wr_almost_full(mvec_wr_almost_full),               // from motcomp
    .motcomp_busy(motcomp_busy),                             // from motcomp
    .getbits(getbits),                                       // to vld
    .signbit(signbit),                                       // to vld
    .getbits_valid(getbits_valid),                           // to probe
    .vld_en(vld_en)                                          // to vld
    );

  /* variable length decoder */
  vld vld(
    .clk(clk), 
    .clk_en(vld_en),                                         // from getbits
    .rst(sync_rst),
    .getbits(getbits),                                       // from getbits
    .signbit(signbit),                                       // from getbits
    .advance(advance),                                       // to getbits
    .align(align),                                           // to getbits
    .wait_state(wait_state),                                 // to getbits
    .quant_wr_data(quant_wr_data_wr),                        // to rld_fifo
    .quant_wr_addr(quant_wr_addr_wr),                        // to rld_fifo
    .quant_rst(quant_rst_wr),                                // to rld_fifo
    .wr_intra_quant(quant_wr_intra_wr),                      // to rld_fifo
    .wr_non_intra_quant(quant_wr_non_intra_wr),              // to rld_fifo
    .wr_chroma_intra_quant(quant_wr_chroma_intra_wr),        // to rld_fifo
    .wr_chroma_non_intra_quant(quant_wr_chroma_non_intra_wr),  // to rld_fifo
    .rld_wr_en(rld_wr_en),                                   // to rld_fifo
    .rld_cmd(rld_cmd_wr),                                    // to rld_fifo
    .dct_coeff_run(dct_coeff_wr_run),                        // to rld_fifo
    .dct_coeff_signed_level(dct_coeff_wr_signed_level),      // to rld_fifo
    .dct_coeff_end(dct_coeff_wr_end),                        // to rld_fifo
    .alternate_scan(alternate_scan),                         // to rld_fifo
    .q_scale_type(q_scale_type),                             // to rld_fifo
    .quantiser_scale_code(quantiser_scale_code),             // to rld_fifo
    .macroblock_intra(macroblock_intra),                     // to rld_fifo and motcomp
    .intra_dc_precision(intra_dc_precision),                 // to rld_fifo
    .matrix_coefficients(matrix_coefficients),               // to yuv2rgb
    .horizontal_size(horizontal_size),                       // to regfile
    .vertical_size(vertical_size),                           // to regfile
    .display_horizontal_size(display_horizontal_size),       // to regfile
    .display_vertical_size(display_vertical_size),           // to regfile
    .aspect_ratio_information(aspect_ratio_information),     // to regfile
    .frame_rate_code(frame_rate_code),                       // to regfile
    .frame_rate_extension_n(frame_rate_extension_n),         // to regfile
    .frame_rate_extension_d(frame_rate_extension_d),         // to regfile
    .picture_coding_type(picture_coding_type),               // to motcomp
    .picture_structure(picture_structure),                   // to motcomp
    .motion_type(motion_type),                               // to motcomp
    .dct_type(dct_type),                                     // to motcomp
    .macroblock_address(macroblock_address),                 // to motcomp
    .macroblock_motion_forward(macroblock_motion_forward),   // to motcomp
    .macroblock_motion_backward(macroblock_motion_backward), // to motcomp
    .mb_width(mb_width),                                     // to motcomp
    .mb_height(mb_height),                                   // to motcomp
    .motion_vert_field_select_0_0(motion_vert_field_select_0_0), // to motcomp
    .motion_vert_field_select_0_1(motion_vert_field_select_0_1), // to motcomp
    .motion_vert_field_select_1_0(motion_vert_field_select_1_0), // to motcomp
    .motion_vert_field_select_1_1(motion_vert_field_select_1_1), // to motcomp
    .second_field(second_field),                             // to motcomp
    .update_picture_buffers(update_picture_buffers),         // to motcomp
    .last_frame(last_frame),                                 // to motcomp
    .chroma_format(chroma_format),                           // to motcomp
    .motion_vector_valid(motion_vector_valid),               // to motcomp
    .pmv_0_0_0(pmv_0_0_0),                                   // to motcomp
    .pmv_0_0_1(pmv_0_0_1),                                   // to motcomp
    .pmv_1_0_0(pmv_1_0_0),                                   // to motcomp
    .pmv_1_0_1(pmv_1_0_1),                                   // to motcomp
    .pmv_0_1_0(pmv_0_1_0),                                   // to motcomp
    .pmv_0_1_1(pmv_0_1_1),                                   // to motcomp
    .pmv_1_1_0(pmv_1_1_0),                                   // to motcomp
    .pmv_1_1_1(pmv_1_1_1),                                   // to motcomp
    .dmv_0_0(dmv_0_0),                                       // to motcomp
    .dmv_0_1(dmv_0_1),                                       // to motcomp
    .dmv_1_0(dmv_1_0),                                       // to motcomp
    .dmv_1_1(dmv_1_1),                                       // to motcomp
    .progressive_sequence(progressive_sequence),             // to resample
    .progressive_frame(progressive_frame),                   // to resample
    .top_field_first(top_field_first),                       // to resample
    .repeat_first_field(repeat_first_field),                 // to resample
    .vld_err(vld_err)
    );

  rld_fifo rld_fifo (
    .clk(clk), 
    .clk_en(1'b1), 
    .rst(sync_rst), 
    .dct_coeff_wr_run(dct_coeff_wr_run), 
    .dct_coeff_wr_signed_level(dct_coeff_wr_signed_level), 
    .dct_coeff_wr_end(dct_coeff_wr_end), 
    .alternate_scan_wr(alternate_scan), 
    .macroblock_intra_wr(macroblock_intra), 
    .intra_dc_precision_wr(intra_dc_precision), 
    .q_scale_type_wr(q_scale_type), 
    .quantiser_scale_code_wr(quantiser_scale_code), 
    .quant_wr_data_wr(quant_wr_data_wr), 
    .quant_wr_addr_wr(quant_wr_addr_wr), 
    .quant_rst_wr(quant_rst_wr), 
    .quant_wr_intra_wr(quant_wr_intra_wr), 
    .quant_wr_non_intra_wr(quant_wr_non_intra_wr), 
    .quant_wr_chroma_intra_wr(quant_wr_chroma_intra_wr), 
    .quant_wr_chroma_non_intra_wr(quant_wr_chroma_non_intra_wr), 
    .rld_cmd_wr(rld_cmd_wr), 
    .rld_wr_en(rld_wr_en), 
    .rld_wr_almost_full(rld_wr_almost_full), 
    .rld_wr_overflow(rld_wr_overflow), 
    .dct_coeff_rd_run(dct_coeff_rd_run), 
    .dct_coeff_rd_signed_level(dct_coeff_rd_signed_level), 
    .dct_coeff_rd_end(dct_coeff_rd_end), 
    .alternate_scan_rd(alternate_scan_rd), 
    .macroblock_intra_rd(macroblock_intra_rd), 
    .intra_dc_precision_rd(intra_dc_precision_rd), 
    .q_scale_type_rd(q_scale_type_rd), 
    .quantiser_scale_code_rd(quantiser_scale_code_rd), 
    .quant_wr_data_rd(quant_wr_data_rd), 
    .quant_wr_addr_rd(quant_wr_addr_rd), 
    .quant_rst_rd(quant_rst_rd), 
    .quant_wr_intra_rd(quant_wr_intra_rd), 
    .quant_wr_non_intra_rd(quant_wr_non_intra_rd), 
    .quant_wr_chroma_intra_rd(quant_wr_chroma_intra_rd), 
    .quant_wr_chroma_non_intra_rd(quant_wr_chroma_non_intra_rd), 
    .rld_cmd_rd(rld_cmd_rd), 
    .rld_rd_en(rld_rd_en), 
    .rld_rd_valid(rld_rd_valid)
    );

  /* Run-length decoding */
  rld rld (
    .clk(clk), 
    .clk_en(1'b1), 
    .rst(sync_rst), 
    .idct_fifo_almost_full(idct_fifo_almost_full),               // from idct_fifo
    .dct_coeff_rd_run(dct_coeff_rd_run),                         // from rld_fifo
    .dct_coeff_rd_signed_level(dct_coeff_rd_signed_level),       // from rld_fifo
    .dct_coeff_rd_end(dct_coeff_rd_end),                         // from rld_fifo
    .alternate_scan_rd(alternate_scan_rd),                       // from rld_fifo
    .q_scale_type_rd(q_scale_type_rd),                           // from rld_fifo
    .macroblock_intra_rd(macroblock_intra_rd),                   // from rld_fifo
    .intra_dc_precision_rd(intra_dc_precision_rd),               // from rld_fifo
    .quantiser_scale_code_rd(quantiser_scale_code_rd),           // from rld_fifo
    .quant_wr_data_rd(quant_wr_data_rd),                         // from rld_fifo
    .quant_wr_addr_rd(quant_wr_addr_rd),                         // from rld_fifo
    .quant_rst_rd(quant_rst_rd),                                 // from rld_fifo
    .quant_wr_intra_rd(quant_wr_intra_rd),                       // from rld_fifo
    .quant_wr_non_intra_rd(quant_wr_non_intra_rd),               // from rld_fifo
    .quant_wr_chroma_intra_rd(quant_wr_chroma_intra_rd),         // from rld_fifo
    .quant_wr_chroma_non_intra_rd(quant_wr_chroma_non_intra_rd), // from rld_fifo
    .rld_cmd_rd(rld_cmd_rd),                                     // from rld_fifo
    .rld_rd_en(rld_rd_en),                                       // to rld_fifo
    .rld_rd_valid(rld_rd_valid),                                 // from rld_fifo
    .quant_rst(quant_rst),                                       // to quantiser rams
    .quant_rd_addr(quant_rd_addr),                               // to quantiser rams
    .quant_rd_intra_data(quant_rd_intra_data),                   // from quantiser rams
    .quant_rd_non_intra_data(quant_rd_non_intra_data),           // from quantiser rams
    .quant_wr_data(quant_wr_data),                               // to quantiser rams
    .quant_wr_addr(quant_wr_addr),                               // to quantiser rams
    .quant_wr_en_intra(quant_wr_en_intra),                       // to quantiser rams
    .quant_wr_en_non_intra(quant_wr_en_non_intra),               // to quantiser rams
    .quant_wr_en_chroma_intra(quant_wr_en_chroma_intra),         // to quantiser rams
    .quant_wr_en_chroma_non_intra(quant_wr_en_chroma_non_intra), // to quantiser rams
    .quant_alternate_scan(quant_alternate_scan),                 // to quantiser rams
    .iquant_level(iquant_level),                                 // to idct
    .iquant_eob(iquant_eob),                                     // to idct
    .iquant_valid(iquant_valid)                                  // to idct
    );

  /* inverse discrete cosine transform */
  idct idct(
    .clk(clk), 
    .clk_en(1'b1),
    .rst(sync_rst), 
    .iquant_level(iquant_level),                             // from rld
    .iquant_eob(iquant_eob),                                 // from rld
    .iquant_valid(iquant_valid),                             // from rld
    .idct_data(idct_data),                                   // to idct_fifo
    .idct_eob(idct_eob),                                     // to idct_fifo
    .idct_valid(idct_valid)                                  // to idct_fifo
    );

  /* group inverse discrete cosine transform coefficients in rows of eight */
  idct_fifo idct_fifo(
    .clk(clk), 
    .clk_en(1'b1),
    .rst(sync_rst), 
    .idct_data(idct_data),                                   // from idct
    .idct_eob(idct_eob),                                     // from idct
    .idct_valid(idct_valid),                                 // from idct
    .idct_wr_dta_almost_full(idct_fifo_almost_full),         // from idct
    .idct_wr_dta_full(),
    .idct_wr_dta_overflow(idct_fifo_overflow),               // from idct
    .idct_rd_dta_empty(idct_rd_dta_empty),                   // to motcomp
    .idct_rd_dta_en(idct_rd_dta_en),                         // to motcomp
    .idct_rd_dta(idct_rd_dta),                               // to motcomp
    .idct_rd_dta_valid(idct_rd_dta_valid),                   // to motcomp
    .idct_rd_dta_almost_empty()
    );

  /* motion compensation */
  motcomp motcomp(
    .clk(clk), 
    .clk_en(1'b1),
    .rst(sync_rst), 
    .busy(motcomp_busy),
    .picture_coding_type(picture_coding_type),               // from vld
    .picture_structure(picture_structure),                   // from vld
    .motion_type(motion_type),                               // from vld
    .dct_type(dct_type),                                     // from vld
    .macroblock_address(macroblock_address),                 // from vld
    .macroblock_motion_forward(macroblock_motion_forward),   // from vld
    .macroblock_motion_backward(macroblock_motion_backward), // from vld
    .macroblock_intra(macroblock_intra),                     // from vld
    .mb_width(mb_width),                                     // from vld
    .mb_height(mb_height),                                   // from vld
    .horizontal_size(horizontal_size),                       // from vld
    .vertical_size(vertical_size),                           // from vld
    .motion_vert_field_select_0_0(motion_vert_field_select_0_0), // from vld
    .motion_vert_field_select_0_1(motion_vert_field_select_0_1), // from vld
    .motion_vert_field_select_1_0(motion_vert_field_select_1_0), // from vld
    .motion_vert_field_select_1_1(motion_vert_field_select_1_1), // from vld
    .second_field(second_field),                             // from vld
    .update_picture_buffers(update_picture_buffers),         // from vld
    .progressive_sequence(progressive_sequence),             // from vld
    .progressive_frame(progressive_frame),                   // from vld
    .top_field_first(top_field_first),                       // from vld
    .repeat_first_field(repeat_first_field),                 // from vld
    .last_frame(last_frame),                                 // from vld
    .chroma_format(chroma_format),                           // from vld
    .motion_vector_valid(motion_vector_valid),               // from vld
    .pmv_0_0_0(pmv_0_0_0),                                   // from vld
    .pmv_0_0_1(pmv_0_0_1),                                   // from vld
    .pmv_1_0_0(pmv_1_0_0),                                   // from vld
    .pmv_1_0_1(pmv_1_0_1),                                   // from vld
    .pmv_0_1_0(pmv_0_1_0),                                   // from vld
    .pmv_0_1_1(pmv_0_1_1),                                   // from vld
    .pmv_1_1_0(pmv_1_1_0),                                   // from vld
    .pmv_1_1_1(pmv_1_1_1),                                   // from vld
    .dmv_0_0(dmv_0_0),                                       // from vld
    .dmv_0_1(dmv_0_1),                                       // from vld
    .dmv_1_0(dmv_1_0),                                       // from vld
    .dmv_1_1(dmv_1_1),                                       // from vld

    .idct_rd_dta_empty(idct_rd_dta_empty),                   // from idct_fifo
    .idct_rd_dta_en(idct_rd_dta_en),                         // from idct_fifo
    .idct_rd_dta(idct_rd_dta),                               // from idct_fifo
    .idct_rd_dta_valid(idct_rd_dta_valid),                   // from idct_fifo
    .dct_block_wr_overflow(dct_block_wr_overflow),           // to probe
    .frame_idct_wr_overflow(frame_idct_wr_overflow),         // to probe

    .source_select(source_select),                           // from regfile

    .fwd_wr_addr_clk_en(fwd_wr_addr_clk_en),                 // to fwd framestore_reader
    .fwd_wr_addr_full(fwd_wr_addr_full),                     // to fwd framestore_reader
    .fwd_wr_addr_almost_full(fwd_wr_addr_almost_full),       // to fwd framestore_reader
    .fwd_wr_addr_en(fwd_wr_addr_en),                         // to fwd framestore_reader
    .fwd_wr_addr_ack(fwd_wr_addr_ack),                       // to fwd framestore_reader
    .fwd_wr_addr(fwd_wr_addr),                               // to fwd framestore_reader
    .fwd_rd_dta_clk_en(fwd_rd_dta_clk_en),                   // to fwd framestore_reader
    .fwd_rd_dta_empty(fwd_rd_dta_empty),                     // to fwd framestore_reader
    .fwd_rd_dta_en(fwd_rd_dta_en),                           // to fwd framestore_reader
    .fwd_rd_dta_valid(fwd_rd_dta_valid),                     // to fwd framestore_reader
    .fwd_rd_dta(fwd_rd_dta),                                 // to fwd framestore_reader

    .bwd_wr_addr_clk_en(bwd_wr_addr_clk_en),                 // to bwd framestore_reader
    .bwd_wr_addr_full(bwd_wr_addr_full),                     // to bwd framestore_reader
    .bwd_wr_addr_almost_full(bwd_wr_addr_almost_full),       // to bwd framestore_reader
    .bwd_wr_addr_en(bwd_wr_addr_en),                         // to bwd framestore_reader
    .bwd_wr_addr_ack(bwd_wr_addr_ack),                       // to bwd framestore_reader
    .bwd_wr_addr(bwd_wr_addr),                               // to bwd framestore_reader
    .bwd_rd_dta_clk_en(bwd_rd_dta_clk_en),                   // to bwd framestore_reader
    .bwd_rd_dta_empty(bwd_rd_dta_empty),                     // to bwd framestore_reader
    .bwd_rd_dta_en(bwd_rd_dta_en),                           // to bwd framestore_reader
    .bwd_rd_dta_valid(bwd_rd_dta_valid),                     // to bwd framestore_reader
    .bwd_rd_dta(bwd_rd_dta),                                 // to bwd framestore_reader

    .recon_wr_full(recon_wr_full),                           // to recon framestore_writer
    .recon_wr_almost_full(recon_wr_almost_full),             // to recon framestore_writer
    .recon_wr_en(recon_wr_en),                               // to recon framestore_writer
    .recon_wr_ack(recon_wr_ack),                             // to recon framestore_writer
    .recon_wr_addr(recon_wr_addr),                           // to recon framestore_writer
    .recon_wr_dta(recon_wr_dta),                             // to recon framestore_writer

    .output_frame(output_frame),                             // to resample
    .output_frame_valid(output_frame_valid),                 // to resample
    .output_frame_rd(output_frame_rd),                       // from resample
    .output_progressive_sequence(output_progressive_sequence),// to resample
    .output_progressive_frame(output_progressive_frame),     // to resample
    .output_top_field_first(output_top_field_first),         // to resample
    .output_repeat_first_field(output_repeat_first_field),   // to resample

    .mvec_wr_almost_full(mvec_wr_almost_full),               // to getbits
    .mvec_wr_overflow(mvec_wr_overflow),                     // to probe
    .dst_wr_overflow(dst_wr_overflow)                        // to probe
    );

  /* Quantisation coefficients */ 
  intra_quant_matrix intra_quantiser_matrix (
    .clk(clk), 
    .rst(sync_rst), 
    .rd_addr(quant_rd_addr),                                 // from rld
    .rd_clk_en(1'b1),                                        // same as rld
    .dta_out(quant_rd_intra_data),                           // to rld
    .wr_addr(quant_wr_addr),                                 // from rld
    .dta_in(quant_wr_data),                                  // from rld
    .wr_clk_en(1'b1),                                        // same as rld
    .wr_en(quant_wr_en_intra),                               // from rld
    .rst_values(quant_rst),                                  // from rld
    .alternate_scan(quant_alternate_scan)                    // from rld
    );
  
  non_intra_quant_matrix non_intra_quantiser_matrix (
    .clk(clk), 
    .rst(sync_rst), 
    .rd_addr(quant_rd_addr),                                 // from rld
    .rd_clk_en(1'b1),                                        // same as rld
    .dta_out(quant_rd_non_intra_data),                       // to rld
    .wr_addr(quant_wr_addr),                                 // from rld
    .dta_in(quant_wr_data),                                  // from rld
    .wr_clk_en(1'b1),                                        // same as rld
    .wr_en(quant_wr_en_non_intra),                           // from rld
    .rst_values(quant_rst),                                  // from rld
    .alternate_scan(quant_alternate_scan)                    // from rld
    );

  /* Chroma resampling */
  resample resample (
    .clk(clk), 
    .rst(sync_rst), 

    .output_frame(output_frame),                             // from motcomp
    .output_frame_valid(output_frame_valid),                 // from motcomp
    .output_frame_rd(output_frame_rd),                       // to motcomp

    .progressive_sequence(output_progressive_sequence),      // from motcomp_picbuf
    .progressive_frame(output_progressive_frame),            // from motcomp_picbuf
    .top_field_first(output_top_field_first),                // from motcomp_picbuf
    .repeat_first_field(output_repeat_first_field),          // from motcomp_picbuf
    .mb_width(mb_width),                                     // from vld
    .mb_height(mb_height),                                   // from vld
    .horizontal_size(horizontal_size),                       // from vld
    .vertical_size(vertical_size),                           // from vld
    .resample_wr_overflow(resample_wr_overflow),             // to probe
    .disp_wr_addr_full(disp_wr_addr_full),                   // to disp framestore_reader
    .disp_wr_addr_almost_full(disp_wr_addr_almost_full),     // to disp framestore_reader
    .disp_wr_addr_en(disp_wr_addr_en),                       // to disp framestore_reader
    .disp_wr_addr_ack(disp_wr_addr_ack),                     // to disp framestore_reader
    .disp_wr_addr(disp_wr_addr),                             // to disp framestore_reader
    .disp_rd_dta_empty(disp_rd_dta_empty),                   // to disp framestore_reader
    .disp_rd_dta_en(disp_rd_dta_en),                         // to disp framestore_reader
    .disp_rd_dta_valid(disp_rd_dta_valid),                   // to disp framestore_reader
    .disp_rd_dta(disp_rd_dta),                               // to disp framestore_reader
    .interlaced(interlaced),                                 // from regfile
    .deinterlace(deinterlace),                               // from regfile
    .persistence(persistence),                               // from regfile
    .repeat_frame(repeat_frame),                             // from regfile

    .y(y_resample),                                          // to pixel queue
    .u(u_resample),                                          // to pixel queue
    .v(v_resample),                                          // to pixel queue
    .osd_out(osd_resample),                                  // to pixel queue
    .position_out(position_resample),                        // to pixel queue
    .pixel_wr_en(pixel_wr_en),                               // to pixel queue
    .pixel_wr_almost_full(pixel_wr_almost_full)              // to pixel queue
    );

  /* Pixel Queue */
  pixel_queue pixel_queue (
    .clk_in(clk), 
    .clk_in_en(1'b1), 
    .rst(sync_rst), 
    /* from resampling */
    .y_in(y_resample),                                       // from resample
    .u_in(u_resample),                                       // from resample
    .v_in(v_resample),                                       // from resample
    .osd_in(osd_resample),                                   // from resample
    .position_in(position_resample),                         // from resample
    .pixel_wr_en(pixel_wr_en),                               // from resample
    .pixel_wr_almost_full(pixel_wr_almost_full),             // to resample
    .pixel_wr_full(pixel_wr_full),                           // to probe
    .pixel_wr_overflow(pixel_wr_overflow),                   // to probe
    .clk_out(dot_clk), 
    .clk_out_en(1'b1), 
    /* to mixer */
    .y_out(y_pqueue),                                        // to mixer
    .u_out(u_pqueue),                                        // to mixer
    .v_out(v_pqueue),                                        // to mixer
    .osd_out(osd_pqueue),                                    // to mixer
    .position_out(position_pqueue),                          // to mixer
    .pixel_rd_en(pixel_rd_en_pqueue),                        // from mixer
    .pixel_rd_empty(pixel_rd_empty_pqueue),                  // to probe
    .pixel_rd_valid(pixel_rd_valid_pqueue),                  // to mixer
    .pixel_rd_underflow(pixel_rd_underflow_pqueue)           // to mixer
    );

  /* Video synchronisation and timing generator */
  syncgen_intf syncgen_intf (
    .clk(dot_clk), 
    .clk_en(1'b1), 
    .rst(dot_rst), 
    .horizontal_size(horizontal_size),                       // from vld
    .vertical_size(vertical_size),                           // from vld
    .display_horizontal_size(display_horizontal_size),       // from vld
    .display_vertical_size(display_vertical_size),           // from vld
    .syncgen_rst(syncgen_rst),                               // from regfile
    .horizontal_resolution(horizontal_resolution),           // from regfile
    .horizontal_sync_start(horizontal_sync_start),           // from regfile
    .horizontal_sync_end(horizontal_sync_end),               // from regfile
    .horizontal_length(horizontal_length),                   // from regfile
    .vertical_resolution(vertical_resolution),               // from regfile
    .vertical_sync_start(vertical_sync_start),               // from regfile
    .vertical_sync_end(vertical_sync_end),                   // from regfile
    .horizontal_halfline(horizontal_halfline),               // from regfile
    .vertical_length(vertical_length),                       // from regfile
    .interlaced(interlaced),                                 // from regfile
    .clip_display_size(clip_display_size),                   // from regfile
    .pixel_repetition(pixel_repetition),                     // from regfile
    .h_pos(h_pos),                                           // to mixer
    .v_pos(v_pos),                                           // to mixer
    .pixel_en(pixel_en_gen),                                 // to mixer
    .h_sync(h_sync_gen),                                     // to mixer
    .v_sync(v_sync_gen),                                     // to mixer
    .c_sync(),
    .h_blank(),
    .v_blank()
    );

  /* Mixer */
  mixer mixer (
    .clk(dot_clk), 
    .rst(dot_rst), 
    .pixel_repetition(dot_pixel_repetition),                 // from register file
    .y_in(y_pqueue),                                         // from pixel queue
    .u_in(u_pqueue),                                         // from pixel queue
    .v_in(v_pqueue),                                         // from pixel queue
    .osd_in(osd_pqueue),                                     // from pixel queue
    .position_in(position_pqueue),                           // from pixel queue
    .pixel_rd_en(pixel_rd_en_pqueue),                        // to pixel queue
    .pixel_rd_valid(pixel_rd_valid_pqueue),                  // from pixel queue
    .pixel_rd_underflow(pixel_rd_underflow_pqueue),          // from pixel queue
    .h_pos(h_pos),                                           // from sync_gen
    .v_pos(v_pos),                                           // from sync_gen
    .h_sync_in(h_sync_gen),                                  // from sync_gen
    .v_sync_in(v_sync_gen),                                  // from sync_gen
    .pixel_en_in(pixel_en_gen),                              // from sync_gen
    .y_out(y_mixer),                                         // to osd
    .u_out(u_mixer),                                         // to osd
    .v_out(v_mixer),                                         // to osd
    .osd_out(osd_mixer),                                     // to osd
    .h_sync_out(h_sync_mixer),                               // to osd
    .v_sync_out(v_sync_mixer),                               // to osd
    .pixel_en_out(pixel_en_mixer)                            // to osd
    );

  /* On-Screen Display */

  mpeg2_osd osd (
    .clk(dot_clk), 
    .clk_en(1'b1), 
    .rst(dot_rst), 
    .y_in(y_mixer),                                          // from mixer
    .u_in(u_mixer),                                          // from mixer
    .v_in(v_mixer),                                          // from mixer
    .h_sync_in(h_sync_mixer),                                // from mixer
    .v_sync_in(v_sync_mixer),                                // from mixer
    .pixel_en_in(pixel_en_mixer),                            // from mixer
    .osd_in(osd_mixer),                                      // from mixer
    .y_out(y_osd),                                           // to yuv2rgb
    .u_out(u_osd),                                           // to yuv2rgb
    .v_out(v_osd),                                           // to yuv2rgb
    .h_sync_out(h_sync_osd),                                 // to yuv2rgb
    .v_sync_out(v_sync_osd),                                 // to yuv2rgb
    .pixel_en_out(pixel_en_osd),                             // to yuv2rgb
    .osd_clt_rd_addr(osd_clt_rd_addr),                       // to osd color lookup table
    .osd_clt_rd_en(osd_clt_rd_en),                           // to osd color lookup table
    .osd_clt_rd_dta(osd_clt_rd_dta),                         // from osd color lookup table
    .osd_enable(dot_osd_enable),                             // from regfile
    .interlaced(dot_interlaced)                              // from regfile
    );

  /* Luminance, chrominance to RGB conversion */
  yuv2rgb yuv2rgb (
    .clk(dot_clk), 
    .clk_en(1'b1), 
    .rst(dot_rst), 
    .matrix_coefficients(dot_matrix_coefficients),           // from vld
    .y(y_osd),                                               // from osd
    .u(u_osd),                                               // from osd
    .v(v_osd),                                               // from osd
    .h_sync_in(h_sync_osd),                                  // from osd
    .v_sync_in(v_sync_osd),                                  // from osd
    .pixel_en_in(pixel_en_osd),                              // from osd
    .r(r),                                                   // to panellink transmitter
    .g(g),                                                   // to panellink transmitter
    .b(b),                                                   // to panellink transmitter
    .y_out(y),                                               // to panellink transmitter
    .u_out(u),                                               // to panellink transmitter
    .v_out(v),                                               // to panellink transmitter
    .h_sync_out(h_sync),                                     // to panellink transmitter
    .v_sync_out(v_sync),                                     // to panellink transmitter
    .c_sync_out(c_sync),				     // to panellink transmitter
    .pixel_en_out(pixel_en)                                  // to panellink transmitter
    );

 /* OSD color look-up table */
  osd_clt osd_clt (
    .clk(clk), 
    .rst(sync_rst), 
    .osd_clt_wr_en(osd_clt_wr_en),                           // from register file.
    .osd_clt_wr_addr(osd_clt_wr_addr),                       // from register file.
    .osd_clt_wr_dta(osd_clt_wr_dta),                         // from register file.
    .dot_clk(dot_clk),
    .dot_rst(dot_rst),
    .osd_clt_rd_addr(osd_clt_rd_addr),                       // from osd
    .osd_clt_rd_en(osd_clt_rd_en),                           // from osd
    .osd_clt_rd_dta(osd_clt_rd_dta)                          // to osd
    );

  /* Register file */
  regfile regfile (
    .clk(clk), 
    .clk_en(1'b1), 
    .hard_rst(hard_rst),                                     // "hard" reset from rst input pin
    .rst(sync_rst),                                          // "soft" reset from rst input pin or watchdog expiry
    .reg_addr(reg_addr),                                     // register file. register address
    .reg_wr_en(reg_wr_en),                                   // register file. register write enable
    .reg_dta_in(reg_dta_in),                                 // register file. register write data
    .reg_rd_en(reg_rd_en),                                   // register file. register read enable
    .reg_dta_out(reg_dta_out),                               // register file. register read data
    .progressive_sequence(progressive_sequence),             // from vld
    .horizontal_size(horizontal_size),                       // from vld
    .vertical_size(vertical_size),                           // from vld
    .display_horizontal_size(display_horizontal_size),       // from vld
    .display_vertical_size(display_vertical_size),           // from vld
    .frame_rate_code(frame_rate_code),                       // from vld
    .frame_rate_extension_n(frame_rate_extension_n),         // from vld
    .frame_rate_extension_d(frame_rate_extension_d),         // from vld
    .aspect_ratio_information(aspect_ratio_information),     // from vld
    .mb_width(mb_width),                                     // from vld
    .matrix_coefficients(matrix_coefficients),               // from vld
    .update_picture_buffers(update_picture_buffers),         // from vld
    .horizontal_resolution(horizontal_resolution),           // to syncgen
    .horizontal_sync_start(horizontal_sync_start),           // to syncgen
    .horizontal_sync_end(horizontal_sync_end),               // to syncgen
    .horizontal_length(horizontal_length),                   // to syncgen
    .vertical_resolution(vertical_resolution),               // to syncgen
    .vertical_sync_start(vertical_sync_start),               // to syncgen
    .vertical_sync_end(vertical_sync_end),                   // to syncgen
    .horizontal_halfline(horizontal_halfline),               // to syncgen
    .vertical_length(vertical_length),                       // to syncgen
    .interlaced(interlaced),                                 // to syncgen
    .clip_display_size(clip_display_size),                   // to syncgen
    .pixel_repetition(pixel_repetition),                     // to syncgen
    .syncgen_rst(syncgen_rst),                               // to syncgen

    .watchdog_interval(watchdog_interval),                   // to watchdog
    .watchdog_interval_wr(watchdog_interval_wr),             // to watchdog
    .watchdog_status_rd(watchdog_status_rd),                 // to watchdog
    .watchdog_status(watchdog_status),                       // from watchdog

    .osd_enable(osd_enable),                                 // to osd
    .osd_clt_wr_en(osd_clt_wr_en),                           // to osd color lookup table
    .osd_clt_wr_addr(osd_clt_wr_addr),                       // to osd color lookup table
    .osd_clt_wr_dta(osd_clt_wr_dta),                         // to osd color lookup table

    .osd_wr_full(osd_wr_full),                               // from osd framestore_writer
    .osd_wr_en(osd_wr_en),                                   // to osd framestore_writer
    .osd_wr_ack(osd_wr_ack),                                 // from osd framestore_writer
    .osd_wr_addr(osd_wr_addr),                               // to osd framestore_writer
    .osd_wr_dta(osd_wr_dta),                                 // to osd framestore_writer

    .deinterlace(deinterlace),                               // to resample
    .repeat_frame(repeat_frame),                             // to motcomp_picbuf
    .persistence(persistence),                               // to motcomp_picbuf
    .source_select(source_select),                           // to motcomp_picbuf
    .flush_vbuf(flush_vbuf),                                 // to framestore_request
    .interrupt(interrupt),                                   // to interrupt pin
    .error(),                                           
    .vld_err(vld_err),                                       // from vld
    .v_sync(regfile_v_sync),                                 // from sync_gen
    .testpoint_sel(testpoint_regfile),                       // to probe
    .testpoint(regfile_testpoint)                            // from probe, synchronized to clk.
    );

  /*
   * Frame store
   */

  framestore framestore (
    .rst(sync_rst), 
    .clk(clk), 
    .mem_clk(mem_clk),
    /* motion compensation: reading forward reference frame */
    .fwd_rd_addr_empty(fwd_rd_addr_empty), 
    .fwd_rd_addr_en(fwd_rd_addr_en), 
    .fwd_rd_addr_valid(fwd_rd_addr_valid), 
    .fwd_rd_addr(fwd_rd_addr), 
    .fwd_wr_dta_full(fwd_wr_dta_full), 
    .fwd_wr_dta_almost_full(fwd_wr_dta_almost_full), 
    .fwd_wr_dta_en(fwd_wr_dta_en), 
    .fwd_wr_dta_ack(fwd_wr_dta_ack), 
    .fwd_wr_dta(fwd_wr_dta), 
    .fwd_rd_dta_almost_empty(fwd_rd_dta_almost_empty),
    /* motion compensation: reading backward reference frame */
    .bwd_rd_addr_empty(bwd_rd_addr_empty), 
    .bwd_rd_addr_en(bwd_rd_addr_en), 
    .bwd_rd_addr_valid(bwd_rd_addr_valid), 
    .bwd_rd_addr(bwd_rd_addr), 
    .bwd_wr_dta_full(bwd_wr_dta_full), 
    .bwd_wr_dta_almost_full(bwd_wr_dta_almost_full), 
    .bwd_wr_dta_en(bwd_wr_dta_en), 
    .bwd_wr_dta_ack(bwd_wr_dta_ack), 
    .bwd_wr_dta(bwd_wr_dta), 
    .bwd_rd_dta_almost_empty(bwd_rd_dta_almost_empty),
    /* motion compensation: writing reconstructed frame */
    .recon_rd_empty(recon_rd_empty), 
    .recon_rd_almost_empty(recon_rd_almost_empty),
    .recon_rd_en(recon_rd_en), 
    .recon_rd_valid(recon_rd_valid), 
    .recon_rd_addr(recon_rd_addr), 
    .recon_rd_dta(recon_rd_dta),
    .recon_wr_almost_full(recon_wr_almost_full),
    /* display: reading reconstructed frame */
    .disp_rd_addr_empty(disp_rd_addr_empty), 
    .disp_rd_addr_en(disp_rd_addr_en), 
    .disp_rd_addr_valid(disp_rd_addr_valid), 
    .disp_rd_addr(disp_rd_addr), 
    .disp_wr_dta_full(disp_wr_dta_full), 
    .disp_wr_dta_almost_full(disp_wr_dta_almost_full), 
    .disp_wr_dta_en(disp_wr_dta_en), 
    .disp_wr_dta_ack(disp_wr_dta_ack), 
    .disp_wr_dta(disp_wr_dta), 
    .disp_rd_dta_almost_empty(disp_rd_dta_almost_empty),
    /* regfile: writing on-screen display */
    .osd_rd_empty(osd_rd_empty), 
    .osd_rd_almost_empty(osd_rd_almost_empty),
    .osd_rd_en(osd_rd_en), 
    .osd_rd_valid(osd_rd_valid), 
    .osd_rd_addr(osd_rd_addr), 
    .osd_rd_dta(osd_rd_dta), 
    .osd_wr_almost_full(osd_wr_almost_full),
    /* writing to circular video buffer */
    .vbw_rd_empty(vbw_rd_empty), 
    .vbw_rd_almost_empty(vbw_rd_almost_empty),
    .vbw_rd_en(vbw_rd_en), 
    .vbw_rd_valid(vbw_rd_valid), 
    .vbw_rd_dta(vbw_rd_dta),
    .vbw_wr_almost_full(vbw_wr_almost_full),
    .vb_flush(flush_vbuf),
    /* reading from circular video buffer */
    .vbr_wr_full(vbr_wr_full), 
    .vbr_wr_almost_full(vbr_wr_almost_full), 
    .vbr_wr_dta(vbr_wr_dta), 
    .vbr_wr_en(vbr_wr_en), 
    .vbr_wr_ack(vbr_wr_ack), 
    .vbr_rd_almost_empty(vbr_rd_almost_empty),
    /* memory controller interface */
    .mem_req_wr_almost_full(mem_req_wr_almost_full),
    .mem_req_wr_full(mem_req_wr_full),
    .mem_req_wr_overflow(mem_req_wr_overflow),
    .mem_req_rd_cmd(mem_req_rd_cmd),
    .mem_req_rd_addr(mem_req_rd_addr),
    .mem_req_rd_dta(mem_req_rd_dta),
    .mem_req_rd_en(mem_req_rd_en),
    .mem_req_rd_valid(mem_req_rd_valid),
    .mem_res_wr_dta(mem_res_wr_dta),
    .mem_res_wr_en(mem_res_wr_en),
    .mem_res_wr_almost_full(mem_res_wr_almost_full),
    .mem_res_wr_full(mem_res_wr_full),
    .mem_res_wr_overflow(mem_res_wr_overflow),
    /* tag fifo status for probe */
    .tag_wr_almost_full(tag_wr_almost_full),
    .tag_wr_full(tag_wr_full),
    .tag_wr_overflow(tag_wr_overflow)
    );

  /*
   * Interface with frame store is through fifo's.
   */

  /* 
   * fifo between motion compensation and frame store:
   * reading forward reference frame.
   */ 

  framestore_reader 
    #(.fifo_addr_depth(FWD_ADDR_DEPTH),
    .fifo_dta_depth(FWD_DTA_DEPTH),
    .fifo_addr_threshold(FWD_ADDR_THRESHOLD), // same value for fifo_threshold fwd_reader, bwd_reader and prog_thresh dst_fifo
    .fifo_dta_threshold(FWD_DTA_THRESHOLD)) // same value for fifo_threshold fwd_reader, bwd_reader and prog_thresh dst_fifo
    fwd_reader (
    .rst(sync_rst), 
    .clk(clk), 
    .wr_addr_clk_en(fwd_wr_addr_clk_en), 
    .wr_addr_full(fwd_wr_addr_full), 
    .wr_addr_almost_full(fwd_wr_addr_almost_full), 
    .wr_addr_en(fwd_wr_addr_en), 
    .wr_addr_ack(fwd_wr_addr_ack),
    .wr_addr(fwd_wr_addr), 
    .wr_addr_overflow(fwd_wr_addr_overflow), 
    .rd_dta_clk_en(fwd_rd_dta_clk_en), 
    .rd_dta_almost_empty(fwd_rd_dta_almost_empty), 
    .rd_dta_empty(fwd_rd_dta_empty), 
    .rd_dta_en(fwd_rd_dta_en), 
    .rd_dta_valid(fwd_rd_dta_valid),
    .rd_dta(fwd_rd_dta), 
    .rd_addr_empty(fwd_rd_addr_empty), 
    .rd_addr_en(fwd_rd_addr_en), 
    .rd_addr_valid(fwd_rd_addr_valid),
    .rd_addr(fwd_rd_addr), 
    .wr_dta_full(fwd_wr_dta_full), 
    .wr_dta_almost_full(fwd_wr_dta_almost_full), 
    .wr_dta_en(fwd_wr_dta_en), 
    .wr_dta_ack(fwd_wr_dta_ack),
    .wr_dta(fwd_wr_dta),
    .wr_dta_overflow(fwd_wr_dta_overflow)
    );

  /* 
   * fifo between motion compensation and frame store:
   * reading backward reference frame.
   */ 

  framestore_reader 
    #(.fifo_addr_depth(BWD_ADDR_DEPTH),
    .fifo_dta_depth(BWD_DTA_DEPTH),
    .fifo_addr_threshold(BWD_ADDR_THRESHOLD), // same value for fifo_threshold fwd_reader, bwd_reader and prog_thresh dst_fifo
    .fifo_dta_threshold(BWD_DTA_THRESHOLD)) // same value for fifo_threshold fwd_reader, bwd_reader and prog_thresh dst_fifo
    bwd_reader (
    .rst(sync_rst), 
    .clk(clk), 
    .wr_addr_clk_en(bwd_wr_addr_clk_en), 
    .wr_addr_full(bwd_wr_addr_full), 
    .wr_addr_almost_full(bwd_wr_addr_almost_full), 
    .wr_addr_en(bwd_wr_addr_en), 
    .wr_addr(bwd_wr_addr), 
    .wr_addr_ack(bwd_wr_addr_ack),
    .wr_addr_overflow(bwd_wr_addr_overflow), 
    .rd_dta_clk_en(bwd_rd_dta_clk_en), 
    .rd_dta_almost_empty(bwd_rd_dta_almost_empty), 
    .rd_dta_empty(bwd_rd_dta_empty), 
    .rd_dta_en(bwd_rd_dta_en), 
    .rd_dta_valid(bwd_rd_dta_valid),
    .rd_dta(bwd_rd_dta), 
    .rd_addr_empty(bwd_rd_addr_empty), 
    .rd_addr_en(bwd_rd_addr_en), 
    .rd_addr_valid(bwd_rd_addr_valid),
    .rd_addr(bwd_rd_addr), 
    .wr_dta_full(bwd_wr_dta_full), 
    .wr_dta_almost_full(bwd_wr_dta_almost_full), 
    .wr_dta_en(bwd_wr_dta_en), 
    .wr_dta_ack(bwd_wr_dta_ack),
    .wr_dta(bwd_wr_dta),
    .wr_dta_overflow(bwd_wr_dta_overflow)
    );

  /* 
   * fifo between motion compensation and frame store:
   * writing reconstructed frame.
   */ 

  framestore_writer 
    #(.fifo_depth(RECON_DEPTH),
    .fifo_threshold(RECON_THRESHOLD))
    recon_writer (
    .rst(sync_rst), 
    .clk(clk), 
    .clk_en(1'b1), 
    .wr_full(recon_wr_full), 
    .wr_almost_full(recon_wr_almost_full), 
    .wr_en(recon_wr_en), 
    .wr_ack(recon_wr_ack),
    .wr_addr(recon_wr_addr), 
    .wr_dta(recon_wr_dta), 
    .wr_overflow(recon_wr_overflow), 
    .rd_empty(recon_rd_empty), 
    .rd_almost_empty(recon_rd_almost_empty), 
    .rd_en(recon_rd_en), 
    .rd_valid(recon_rd_valid),
    .rd_addr(recon_rd_addr), 
    .rd_dta(recon_rd_dta)
    );

  /*
   * fifo between chroma resampling and frame store:
   * reading reconstructed frames.
   */

  framestore_reader 
    #(.fifo_addr_depth(DISP_ADDR_DEPTH),
    .fifo_dta_depth(DISP_DTA_DEPTH),
    .fifo_addr_threshold(DISP_ADDR_THRESHOLD),
    .fifo_dta_threshold(DISP_DTA_THRESHOLD))
    disp_reader (
    .rst(sync_rst), 
    .clk(clk), 
    .wr_addr_clk_en(1'b1), 
    .wr_addr_full(disp_wr_addr_full), 
    .wr_addr_almost_full(disp_wr_addr_almost_full), 
    .wr_addr_en(disp_wr_addr_en), 
    .wr_addr_ack(disp_wr_addr_ack),
    .wr_addr(disp_wr_addr), 
    .wr_addr_overflow(disp_wr_addr_overflow), 
    .rd_dta_clk_en(1'b1), 
    .rd_dta_almost_empty(disp_rd_dta_almost_empty), 
    .rd_dta_empty(disp_rd_dta_empty), 
    .rd_dta_en(disp_rd_dta_en), 
    .rd_dta_valid(disp_rd_dta_valid),
    .rd_dta(disp_rd_dta), 
    .rd_addr_empty(disp_rd_addr_empty), 
    .rd_addr_en(disp_rd_addr_en), 
    .rd_addr_valid(disp_rd_addr_valid),
    .rd_addr(disp_rd_addr), 
    .wr_dta_full(disp_wr_dta_full), 
    .wr_dta_almost_full(disp_wr_dta_almost_full), 
    .wr_dta_en(disp_wr_dta_en), 
    .wr_dta_ack(disp_wr_dta_ack),
    .wr_dta(disp_wr_dta),
    .wr_dta_overflow(disp_wr_dta_overflow)
    );

  /* 
   * fifo between register file and frame store:
   * writing on-screen display
   */ 

  framestore_writer 
    #(.fifo_depth(OSD_DEPTH),
    .fifo_threshold(OSD_THRESHOLD))
    osd_writer (
    .rst(sync_rst), 
    .clk(clk), 
    .clk_en(1'b1), 
    .wr_full(osd_wr_full), 
    .wr_almost_full(osd_wr_almost_full), 
    .wr_en(osd_wr_en), 
    .wr_ack(osd_wr_ack),
    .wr_addr(osd_wr_addr), 
    .wr_dta(osd_wr_dta), 
    .wr_overflow(osd_wr_overflow), 
    .rd_empty(osd_rd_empty), 
    .rd_almost_empty(osd_rd_almost_empty), 
    .rd_en(osd_rd_en), 
    .rd_valid(osd_rd_valid), 
    .rd_addr(osd_rd_addr), 
    .rd_dta(osd_rd_dta)
    );

 /*
  * Watchdog timer
  */

  watchdog watchdog (
    .clk(clk), 
    .hard_rst(hard_rst), 
    .source_select(source_select), 
    .repeat_frame(repeat_frame), 
    .busy(busy), 
    .watchdog_rst(watchdog_rst),
    .watchdog_interval(watchdog_interval),                   // from regfile
    .watchdog_interval_wr(watchdog_interval_wr),             // from regfile
    .watchdog_status_rd(watchdog_status_rd),                 // from regfile
    .watchdog_status(watchdog_status)                        // to regfile
    );

  /*
   * logical analyzer test point 
   */

  probe probe (
    .clk(clk),
    .mem_clk(mem_clk),
    .dot_clk(dot_clk),
    .sync_rst(sync_rst),
    .mem_rst(mem_rst),
    .dot_rst(dot_rst),
    .testpoint(testpoint),
    .testpoint_regfile(testpoint_regfile),
    .testpoint_dip(testpoint_dip),
    .testpoint_dip_en(testpoint_dip_en),
    /* program stream in */
    .stream_data(stream_data),
    .stream_valid(stream_valid),
    .busy(busy),
    /* getbits in */
    .vbr_rd_dta(vbr_rd_dta),
    .vbr_rd_en(vbr_rd_en),
    .vbr_rd_valid(vbr_rd_valid),
    .advance(advance),
    .align(align),
    /* vld in */
    .getbits(getbits),
    .signbit(signbit),
    .getbits_valid(getbits_valid),
    /* vld out */
    .vld_en(vld_en),
    .error(error),
    .motcomp_busy(motcomp_busy),
    /* rld in */
    .dct_coeff_wr_run(dct_coeff_wr_run),
    .dct_coeff_wr_signed_level(dct_coeff_wr_signed_level),
    .dct_coeff_wr_end(dct_coeff_wr_end),
    .rld_wr_en(rld_wr_en),
    /* regfile */
    .reg_addr(reg_addr),
    .reg_wr_en(reg_wr_en),
    .reg_dta_in(reg_dta_in),
    .reg_rd_en(reg_rd_en),
    .reg_dta_out(reg_dta_out),
    /* watchdog */
    .watchdog_rst(watchdog_rst),
    /* fifo's @ clk */
    .bwd_wr_addr_almost_full(bwd_wr_addr_almost_full),
    .bwd_wr_addr_full(bwd_wr_addr_full),
    .bwd_wr_addr_overflow(bwd_wr_addr_overflow),
    .bwd_rd_addr_empty(bwd_rd_addr_empty),
    .bwd_wr_dta_almost_full(bwd_wr_dta_almost_full),
    .bwd_wr_dta_full(bwd_wr_dta_full),
    .bwd_wr_dta_overflow(bwd_wr_dta_overflow),
    .bwd_rd_dta_empty(bwd_rd_dta_empty),
    .disp_wr_addr_almost_full(disp_wr_addr_almost_full),
    .disp_wr_addr_full(disp_wr_addr_full),
    .disp_wr_addr_overflow(disp_wr_addr_overflow),
    .disp_rd_addr_empty(disp_rd_addr_empty),
    .disp_wr_dta_almost_full(disp_wr_dta_almost_full),
    .disp_wr_dta_full(disp_wr_dta_full),
    .disp_wr_dta_overflow(disp_wr_dta_overflow),
    .disp_rd_dta_empty(disp_rd_dta_empty),
    .fwd_wr_addr_almost_full(fwd_wr_addr_almost_full),
    .fwd_wr_addr_full(fwd_wr_addr_full),
    .fwd_wr_addr_overflow(fwd_wr_addr_overflow),
    .fwd_rd_addr_empty(fwd_rd_addr_empty),
    .fwd_wr_dta_almost_full(fwd_wr_dta_almost_full),
    .fwd_wr_dta_full(fwd_wr_dta_full),
    .fwd_wr_dta_overflow(fwd_wr_dta_overflow),
    .fwd_rd_dta_empty(fwd_rd_dta_empty),
    .dct_block_wr_overflow(dct_block_wr_overflow),
    .frame_idct_wr_overflow(frame_idct_wr_overflow),
    .idct_fifo_almost_full(idct_fifo_almost_full),
    .idct_fifo_overflow(idct_fifo_overflow),
    .idct_rd_dta_empty(idct_rd_dta_empty),
    .mvec_wr_almost_full(mvec_wr_almost_full),
    .mvec_wr_overflow(mvec_wr_overflow),
    .dst_wr_overflow(dst_wr_overflow),
    .mem_req_wr_almost_full(mem_req_wr_almost_full),
    .mem_req_wr_full(mem_req_wr_full),
    .mem_req_wr_overflow(mem_req_wr_overflow),
    .osd_wr_full(osd_wr_full),
    .osd_wr_overflow(osd_wr_overflow),
    .osd_rd_empty(osd_rd_empty),
    .resample_wr_overflow(resample_wr_overflow),
    .pixel_wr_almost_full(pixel_wr_almost_full),
    .pixel_wr_full(pixel_wr_full),
    .pixel_wr_overflow(pixel_wr_overflow),
    .pixel_rd_empty(pixel_rd_empty_pqueue),
    .recon_wr_almost_full(recon_wr_almost_full),
    .recon_wr_full(recon_wr_full),
    .recon_wr_overflow(recon_wr_overflow),
    .recon_rd_empty(recon_rd_empty),
    .rld_wr_almost_full(rld_wr_almost_full),
    .rld_wr_overflow(rld_wr_overflow),
    .tag_wr_almost_full(tag_wr_almost_full),
    .tag_wr_full(tag_wr_full),
    .tag_wr_overflow(tag_wr_overflow),
    .vbr_wr_almost_full(vbr_wr_almost_full),
    .vbr_wr_full(vbr_wr_full),
    .vbr_wr_overflow(vbr_wr_overflow),
    .vbr_rd_empty(vbr_rd_empty),
    .vbw_wr_almost_full(vbw_wr_almost_full),
    .vbw_wr_full(vbw_wr_full),
    .vbw_wr_overflow(vbw_wr_overflow),
    .vbw_rd_empty(vbw_rd_empty),
    /* fifo's @ mem_clk */
    .mem_req_rd_en(mem_req_rd_en),
    .mem_req_rd_valid(mem_req_rd_valid),
    .mem_res_wr_en(mem_res_wr_en),
    .mem_res_wr_almost_full(mem_res_wr_almost_full),
    .mem_res_wr_full(mem_res_wr_full),
    .mem_res_wr_overflow(mem_res_wr_overflow),
    /* motion comp */
    .macroblock_address(macroblock_address),
    .macroblock_motion_forward(macroblock_motion_forward),
    .macroblock_motion_backward(macroblock_motion_backward),
    .macroblock_intra(macroblock_intra),
    .second_field(second_field),
    .update_picture_buffers(update_picture_buffers),
    .last_frame(last_frame),
    .motion_vector_valid(motion_vector_valid),
    /* output frame */
    .output_frame(output_frame),
    .output_frame_valid(output_frame_valid),
    .output_frame_rd(output_frame_rd),
    .output_progressive_sequence(output_progressive_sequence),
    .output_progressive_frame(output_progressive_frame),
    .output_top_field_first(output_top_field_first),
    .output_repeat_first_field(output_repeat_first_field),
    /* osd writes */
    .osd_wr_en(osd_wr_en),
    .osd_wr_ack(osd_wr_ack),
    .osd_wr_addr(osd_wr_addr),
    /* yuv video in */
    .y(y),
    .u(u),
    .v(v),
    .pixel_en(pixel_en),
    .h_sync(h_sync),
    .v_sync(v_sync)
    );

`ifdef CHECK
  always @(posedge clk)
    if (vbw_wr_overflow)
      begin
        #0 $display("%m\t*** error: vbw_wr_overflow overflow. **");
        $stop;
      end

  always @(posedge clk)
    if (vbr_wr_overflow)
      begin
        #0 $display("%m\t*** error: vbr_wr_overflow overflow. **");
        $stop;
      end

`endif

endmodule
/* not truncated */
