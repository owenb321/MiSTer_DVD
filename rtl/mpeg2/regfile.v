/* 
 * regfile.v
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
 * regfile - Register file. Provides a set of registers software can read from and write to.
 *
 * Note: two reset signals are available, hard_rst and rst.
 * hard_rst is a reset signal, synchronous to clk, which goes low when the "rst" input pin goes low.
 * rst is a reset signal, synchronous to clk, which goes low when either the "rst" input pin goes low or when the watchdog timer expires.
 *
 * The register file is reset when the "rst" input pin goes low. 
 * With the exception of the On-Screen-Display, the register file keeps its contents if the watchdog timer expires. 
 * In particular, the registers with the video condiguration (horizontal_resolution, vertical_resolution, etc.) 
 * keep their value if the watchdog timer expires. Hence the video modeline does not change if the watchdog timer expires.
 *
 * If the watchdog timer expires, the decoder is reset and the memory controller initializes external memory to zero. 
 * External memory includes the On-Screen Display. 
 * Because the On-Screen Display memory is zeroed out when the watchdog timer expires, 
 * any On-Screen Display shown when the watchdog timer expires is lost.
 * As the On-Screen Display loses its contents when the watchdog timer expires,
 * the On-Screen Display is disabled (osd_enable <= 0) when the watchdog timer expires.
 * This is the only configuration register which changes value when the watchdog timer expires.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

/* allows software to read version number. eg. VERSION 12 = version 1.2 */
`define VERSION 'd12

module regfile    (clk, clk_en, hard_rst, rst,
                   reg_addr, reg_wr_en, reg_dta_in, reg_rd_en, reg_dta_out,
                   progressive_sequence, horizontal_size, vertical_size, display_horizontal_size, display_vertical_size,
		   frame_rate_code, frame_rate_extension_n, frame_rate_extension_d, aspect_ratio_information, mb_width, 
                   matrix_coefficients, update_picture_buffers,
                   horizontal_resolution, horizontal_sync_start, horizontal_sync_end, horizontal_length,
                   vertical_resolution, vertical_sync_start, vertical_sync_end, horizontal_halfline, vertical_length,
                   interlaced, pixel_repetition, clip_display_size, syncgen_rst, 
                   watchdog_interval_wr, watchdog_interval, watchdog_status_rd, watchdog_status,
                   osd_clt_wr_en, osd_clt_wr_addr, osd_clt_wr_dta, 
                   osd_enable,
                   osd_wr_full, osd_wr_en, osd_wr_ack, osd_wr_addr, osd_wr_dta,
                   error, vld_err, interrupt, v_sync,
                   deinterlace, repeat_frame, persistence, source_select, flush_vbuf,
                   testpoint_sel, testpoint);

  input            clk;
  input            clk_en;
  input            hard_rst;
  input            rst;

  input       [3:0]reg_addr;
  input      [31:0]reg_dta_in;
  input            reg_wr_en;
  output reg [31:0]reg_dta_out;
  input            reg_rd_en;

  output reg       error;
  input            vld_err;
  input            v_sync;
  output reg       interrupt;

  input            progressive_sequence;          /* par. 6.3.5 */
  input      [13:0]horizontal_size;               /* par. 6.2.2.1, par. 6.3.3 */
  input      [13:0]vertical_size;                 /* par. 6.2.2.1, par. 6.3.3 */
  input      [13:0]display_horizontal_size;       /* par. 6.2.2.4, par. 6.3.6 */
  input      [13:0]display_vertical_size;         /* par. 6.2.2.4, par. 6.3.6 */
  input       [3:0]aspect_ratio_information;      /* par. 6.3.3 */
  input       [3:0]frame_rate_code;               /* par. 6.3.3, Table 6-4 */
  input       [1:0]frame_rate_extension_n;        /* par. 6.3.3, par. 6.3.5 */
  input       [4:0]frame_rate_extension_d;        /* par. 6.3.3, par. 6.3.5 */
  input       [7:0]mb_width;                      /* par. 6.3.3 */
  input       [7:0]matrix_coefficients;           /* par. 6.3.6 */
  input            update_picture_buffers;        /* asserted when picture header encountered in bitstream */
 
  output reg [11:0]horizontal_resolution;         /* horizontal resolution. number of dots per line, minus one  */
  output reg [11:0]horizontal_sync_start;         /* the dot the horizontal sync pulse begins. */
  output reg [11:0]horizontal_sync_end;           /* the dot the horizontal sync pulse ends. */
  output reg [11:0]horizontal_length;             /* total horizontal length */

  output reg [11:0]vertical_resolution;           /* vertical resolution. number of visible lines per frame (progressive) or field (interlaced), minus one */
  output reg [11:0]vertical_sync_start;           /* the line number within the frame (progressive) or field (interlaced) the vertical sync pulse begins. */
  output reg [11:0]vertical_sync_end;             /* the line number within the frame (progressive) or field (interlaced) the vertical sync pulse ends. */
  output reg [11:0]horizontal_halfline;           /* the dot the vertical sync begins on odd frames of interlaced video. Not used in progressive mode. */
  output reg [11:0]vertical_length;               /* total number of lines of a vertical frame (progressive) or field (interlaced) */

  output reg       clip_display_size;             /* assert to clip image to (display_horizontal_size, display_vertical_size) */
  output reg       interlaced;                    /* assert if interlaced output required. */
  output reg       pixel_repetition;              /* assert for dot clock rates < 25 MHz, repeats each pixel once */
  output reg       syncgen_rst;                   /* reset sync generator whenever modeline parameter is changed */

  output reg  [7:0]watchdog_interval;             /* watchdog interval. 255 = never expire; 0 = expire immediate. */
  output reg       watchdog_interval_wr;          /* asserted when the watchdog interval is written */
  output reg       watchdog_status_rd;            /* asserted when the watchdog status is read */
  input            watchdog_status;               /* high if watchdog expired */

                                                  /* On-Screen Display Color Lookup Table */
  output reg       osd_clt_wr_en;                 /* assert when updating clt */
  output reg  [7:0]osd_clt_wr_addr;               /* color lookup table address, 8 bits */
  output reg [31:0]osd_clt_wr_dta;                /* color lookup table entry, 32 bits: 8 bits y, 8 bits u, 8 bits v, 8 bits mode. See matrix_coefficients for yuv coding details */
  output reg       osd_enable;                    /* assert to show osd */

                                                  /* On-Screen Display framestore_writer */
  input            osd_wr_full;                   /* high when osd framestore_writer fifo full */
  input            osd_wr_ack;                    /* asserted if previous clocks' osd write successful */
  output           osd_wr_en;                     /* assert to write osd_wr_dta to osd_wr_addr */
  output     [21:0]osd_wr_addr;                   /* osd address */
  output     [63:0]osd_wr_dta;                    /* osd data */

  reg        [31:0]osd_wr_dta_high;
  reg        [31:0]osd_wr_dta_low;
  reg              osd_wr_en_in;
  reg         [2:0]osd_frame;                     /* frame of line to be written. Always OSD_FRAME for OSD writes.  */
  reg         [1:0]osd_comp;                      /* component of line to be written. Always COMP_Y for OSD writes.  */
  reg         [7:0]osd_x;                         /* x coordinate of line to be written, divided by 8 */
  reg        [10:0]osd_y;                         /* y coordinate of line to be written */

  reg              osd_wr_en_0;                 
  reg              osd_wr_en_sav;                 /* set when osd write registered; cleared when status register read */
  reg              osd_wr_ack_sav;                /* set when osd write successful; cleared when status register read */
  reg              picture_hdr;                   /* set when picture header encountered in bitstream; cleared when status register read */
  reg              frame_end;                     /* set when displaying pixel 0 of line 0; cleared when status register read */
  reg              video_ch;                      /* set when video resolution or frame rate changes; cleared when status register read */

  reg              video_ch_intr_en;              /* normally low; assert to generate interrupts when video resolution/frame rate changes */
  reg              frame_end_intr_en;             /* normally low; assert to generate interrupts when vertical sync begins */
  reg              picture_hdr_intr_en;           /* normally low; assert to generate interrupts when picture header encountered */

  output reg       deinterlace;                   /* assert if video has to be deinterlaced */
  output reg  [4:0]repeat_frame;                  /* repeat decoded images */
  output reg       persistence;                   /* last decoded image persists */
  output reg  [2:0]source_select;                 /* select video out source */
  output reg       flush_vbuf;                    /* flush video buffer */

  output reg  [3:0]testpoint_sel;                 /* selects one of up to 16 internal test points to be muxed to the logical analyzer probe testpoint */
  input      [31:0]testpoint;                     /* bits 31..0 of test point, synchronized  to clk */ 

`include "modeline.v"
`include "mem_codes.v"
`include "vld_codes.v"

  /* 
   * Verify all changes to REG_RD_STATUS (watchdog_status) and REG_WR_STREAM (watchdog_interval) with watchdog.v
   */

`include "regfile_codes.v"

  /*
   * watchdog timer setting at power-up. Setting the watchdog timer to 8'd255
   * will turn the watchdog circuit off.
   */

  parameter [7:0] 
    DEFAULT_WATCHDOG_TIMER= 8'd127;
//    DEFAULT_WATCHDOG_TIMER= 8'd255; // watchdog disable

  /*
   * reading registers
   */
 
  always @(posedge clk)
    if (~hard_rst) reg_dta_out <= 32'b0;
    else if (clk_en && reg_rd_en) 
      case (reg_addr)
        REG_RD_VERSION:               reg_dta_out <= {16'd0, 16`VERSION};
        REG_RD_STATUS:                reg_dta_out <= {16'd0, matrix_coefficients, watchdog_status, osd_wr_en_sav, osd_wr_ack_sav, osd_wr_full, picture_hdr, frame_end, video_ch, error};
        REG_RD_SIZE:                  reg_dta_out <= {2'b0, horizontal_size, 2'b0, vertical_size};
        REG_RD_DISP_SIZE:             reg_dta_out <= {2'b0, display_horizontal_size, 2'b0, display_vertical_size};
        REG_RD_FRAME_RATE:            reg_dta_out <= {16'b0, aspect_ratio_information, progressive_sequence, frame_rate_extension_d, frame_rate_extension_n, frame_rate_code};
        REG_RD_TESTPOINT:             reg_dta_out <= testpoint;
	default:                      reg_dta_out <= 32'b0;
      endcase
    else reg_dta_out <= reg_dta_out;

  /*
   * REG_RD_STATUS
   */

  always @(posedge clk)
    if (~hard_rst) watchdog_status_rd <= 1'b0;
    else if (clk_en) watchdog_status_rd <= (reg_rd_en && (reg_addr == REG_RD_STATUS)); // assert when status register read
    else watchdog_status_rd <= watchdog_status_rd;

  always @(posedge clk)
    if (~hard_rst) osd_wr_en_0 <= 1'b0; 
    else if (clk_en) osd_wr_en_0 <= osd_wr_en;
    else osd_wr_en_0 <= osd_wr_en_0;

  always @(posedge clk)
    if (~hard_rst) osd_wr_ack_sav <= 1'b0; 
    else if (clk_en && osd_wr_en_0) osd_wr_ack_sav <= osd_wr_ack;
    else if (clk_en && reg_rd_en && (reg_addr == REG_RD_STATUS)) osd_wr_ack_sav <= 1'b0;
    else osd_wr_ack_sav <= osd_wr_ack_sav;

  always @(posedge clk)
    if (~hard_rst) osd_wr_en_sav <= 1'b0; 
    else if (clk_en && osd_wr_en_0) osd_wr_en_sav <= 1'b1;
    else if (clk_en && reg_rd_en && (reg_addr == REG_RD_STATUS)) osd_wr_en_sav <= 1'b0;
    else osd_wr_en_sav <= osd_wr_en_sav;

  always @(posedge clk)
    if (~hard_rst) picture_hdr <= 1'b0;
    else if (clk_en && reg_rd_en && (reg_addr == REG_RD_STATUS)) picture_hdr <= 1'b0;
    else if (clk_en) picture_hdr <= picture_hdr || update_picture_buffers;
    else picture_hdr <= picture_hdr;

  /* video frame end indicator, set at vertical sync start */
  reg              v_sync_0;

  always @(posedge clk)
    if (~hard_rst) v_sync_0 <= 1'b0; 
    else if (clk_en) v_sync_0 <= v_sync;
    else v_sync_0 <= v_sync_0;

  always @(posedge clk)
    if (~hard_rst) frame_end <= 1'b0;
    else if (clk_en && reg_rd_en && (reg_addr == REG_RD_STATUS)) frame_end <= 1'b0;
    else if (clk_en) frame_end <= frame_end || (v_sync && ~v_sync_0);
    else frame_end <= frame_end;

  /* video modeline change indicator */

  wire       [71:0]current_vid_params = {horizontal_size, vertical_size, display_horizontal_size, display_vertical_size, progressive_sequence, aspect_ratio_information, frame_rate_code, frame_rate_extension_n, frame_rate_extension_d};
  reg        [71:0]previous_vid_params;
  wire             video_params_changed = update_picture_buffers && (previous_vid_params != current_vid_params);

  always @(posedge clk)
    if (~hard_rst) previous_vid_params <= 72'b0;
    else if (clk_en && update_picture_buffers) previous_vid_params <= current_vid_params;
    else previous_vid_params <= previous_vid_params;

  always @(posedge clk)
    if (~hard_rst) video_ch <= 1'b0;
    else if (clk_en && reg_rd_en && (reg_addr == REG_RD_STATUS)) video_ch <= video_params_changed;
    else if (clk_en) video_ch <= video_ch || video_params_changed;
    else video_ch <= video_ch;

  /* error flag is set when vld error occurs; cleared whenever status register is read */

  always @(posedge clk)
    if (~hard_rst) error <= 1'b0;
    else if (clk_en && reg_rd_en && (reg_addr == REG_RD_STATUS)) error <= 1'b0;
    else if (clk_en) error <= error || vld_err;
    else error <= error;

  /*
   * REG_WR_STREAM
   */

  always @(posedge clk)
    if (~hard_rst) watchdog_interval_wr <= 1'b0;
    else if (clk_en) watchdog_interval_wr <= (reg_wr_en && (reg_addr == REG_WR_STREAM)); // assert when new watchdog_interval written
    else watchdog_interval_wr <= watchdog_interval_wr;

  always @(posedge clk)
    if (~hard_rst) watchdog_interval <= DEFAULT_WATCHDOG_TIMER;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_STREAM)) watchdog_interval <= reg_dta_in[15:8]; // new watchdog_interval 
    else watchdog_interval <= watchdog_interval;

  always @(posedge clk)
    if (~hard_rst) osd_enable <= 1'b0; 
    else if (~rst) osd_enable <= 1'b0; // switch off OSD if watchdog timer expires
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_STREAM)) osd_enable <= reg_dta_in[3];
    else osd_enable <= osd_enable;

  always @(posedge clk)
    if (~hard_rst) picture_hdr_intr_en <= 1'b0;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_STREAM)) picture_hdr_intr_en <= reg_dta_in[2];
    else picture_hdr_intr_en <= picture_hdr_intr_en;

  always @(posedge clk)
    if (~hard_rst) frame_end_intr_en <= 1'b0;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_STREAM)) frame_end_intr_en <= reg_dta_in[1];
    else frame_end_intr_en <= frame_end_intr_en;

  always @(posedge clk)
    if (~hard_rst) video_ch_intr_en <= 1'b0;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_STREAM)) video_ch_intr_en <= reg_dta_in[0];
    else video_ch_intr_en <= video_ch_intr_en;

  /*
   * REG_WR_HOR
   */

  always @(posedge clk)
    if (~hard_rst) horizontal_resolution <= HORZ_RES;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_HOR)) horizontal_resolution <= reg_dta_in[27:16];
    else horizontal_resolution <= horizontal_resolution;
 
  always @(posedge clk)
    if (~hard_rst) horizontal_length <= HORZ_LEN;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_HOR)) horizontal_length <= reg_dta_in[11:0];
    else horizontal_length <= horizontal_length;
 
  /*
   * REG_WR_HOR_SYNC
   */

  always @(posedge clk)
    if (~hard_rst) horizontal_sync_start <= HORZ_SYNC_STRT;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_HOR_SYNC)) horizontal_sync_start <= reg_dta_in[27:16];
    else horizontal_sync_start <= horizontal_sync_start;
 
  always @(posedge clk)
    if (~hard_rst) horizontal_sync_end <= HORZ_SYNC_END;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_HOR_SYNC)) horizontal_sync_end <= reg_dta_in[11:0];
    else horizontal_sync_end <= horizontal_sync_end;
 
  /*
   * REG_WR_VER
   */

  always @(posedge clk)
    if (~hard_rst) vertical_resolution <= VERT_RES;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_VER)) vertical_resolution <= reg_dta_in[27:16];
    else vertical_resolution <= vertical_resolution;
 
  always @(posedge clk)
    if (~hard_rst) vertical_length <= VERT_LEN;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_VER)) vertical_length <= reg_dta_in[11:0];
    else vertical_length <= vertical_length;
 
  /*
   * REG_WR_VER_SYNC
   */

  always @(posedge clk)
    if (~hard_rst) vertical_sync_start <= VERT_SYNC_STRT;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_VER_SYNC)) vertical_sync_start <= reg_dta_in[27:16];
    else vertical_sync_start <= vertical_sync_start;
 
  always @(posedge clk)
    if (~hard_rst) vertical_sync_end <= VERT_SYNC_END;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_VER_SYNC)) vertical_sync_end <= reg_dta_in[11:0];
    else vertical_sync_end <= vertical_sync_end;

  /*
   * REG_WR_VID_MODE
   */

  always @(posedge clk)
    if (~hard_rst) horizontal_halfline <= HALFLINE;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_VID_MODE)) horizontal_halfline <= reg_dta_in[27:16];
    else horizontal_halfline <= horizontal_halfline;

  /*
   * If pixel_repetition is asserted, each pixel is output twice.
   * This can be used if the original dotclock is too low for the transmitter.
   * As an example, DVI and HDMI may require a dot clock of 25...165 MHz.
   * An SDTV image may have a dotclock of 13.5 MHz; asserting pixel_repetition
   * and doubling dotclock results in a dotclock of 27 MHz and
   * allows video to be transmitted across the link.
   */

  always @(posedge clk)
    if (~hard_rst) {clip_display_size, pixel_repetition, interlaced} <= VID_MODE;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_VID_MODE)) {clip_display_size, pixel_repetition, interlaced} <= reg_dta_in[2:0];
    else {clip_display_size, pixel_repetition, interlaced} <= {clip_display_size, pixel_repetition, interlaced};

  /*
   * REG_WR_CLT_YUVM
   */

  always @(posedge clk)
    if (~hard_rst) osd_clt_wr_dta <= 32'b0;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_CLT_YUVM)) osd_clt_wr_dta <= reg_dta_in;
    else osd_clt_wr_dta <= osd_clt_wr_dta;

  /*
   * REG_WR_CLT_ADDR
   */

  always @(posedge clk)
    if (~hard_rst) osd_clt_wr_addr <= 8'b0;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_CLT_ADDR)) osd_clt_wr_addr <= reg_dta_in[7:0];
    else osd_clt_wr_addr <= osd_clt_wr_addr;

  always @(posedge clk)
    if (~hard_rst) osd_clt_wr_en <= 1'b0; 
    else if (clk_en) osd_clt_wr_en <= (reg_addr == REG_WR_CLT_ADDR) && reg_wr_en;
    else osd_clt_wr_en <= osd_clt_wr_en;

  /*
   * REG_WR_OSD_DTA_HIGH
   */

  always @(posedge clk)
    if (~hard_rst) osd_wr_dta_high <= 32'b0;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_OSD_DTA_HIGH)) osd_wr_dta_high <= reg_dta_in;
    else osd_wr_dta_high <= osd_wr_dta_high;

  /*
   * REG_WR_OSD_DTA_LOW
   */

  always @(posedge clk)
    if (~hard_rst) osd_wr_dta_low <= 32'b0;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_OSD_DTA_LOW)) osd_wr_dta_low <= reg_dta_in;
    else osd_wr_dta_low <= osd_wr_dta_low;

  /*
   * REG_WR_OSD_ADDR
   */

  always @(posedge clk)
    if (~hard_rst) osd_frame <= 3'b0;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_OSD_ADDR)) osd_frame <= reg_dta_in[31:29]; // Always OSD_FRAME for OSD writes
    else osd_frame <= osd_frame;

  always @(posedge clk)
    if (~hard_rst) osd_comp <= 2'b0;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_OSD_ADDR)) osd_comp <= reg_dta_in[28:27]; // Always COMP_Y for OSD writes
    else osd_comp <= osd_comp;

  always @(posedge clk)
    if (~hard_rst) osd_x <= 8'b0;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_OSD_ADDR)) osd_x <= reg_dta_in[26:19]; // reg_dta_in[18:16] has to be 3'b0, as osd_addr_x has to be a multiple of 8
    else osd_x <= osd_x;

  always @(posedge clk)
    if (~hard_rst) osd_y <= 11'b0;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_OSD_ADDR)) osd_y <= reg_dta_in[10:0];
    else osd_y <= osd_y;

  always @(posedge clk)
    if (~hard_rst) osd_wr_en_in <= 1'b0; 
    else if (clk_en && reg_wr_en) osd_wr_en_in <= (reg_addr == REG_WR_OSD_ADDR) && ~osd_wr_full;
    else if (clk_en) osd_wr_en_in <= 1'b0;
    else osd_wr_en_in <= osd_wr_en_in;

  /*
   * REG_WR_TRICK
   */

  always @(posedge clk)
    if (~hard_rst) deinterlace <= 1'b1;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_TRICK)) deinterlace <= reg_dta_in[10];
    else deinterlace <= deinterlace;

  always @(posedge clk)
    if (~hard_rst) repeat_frame <= 5'd0;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_TRICK)) repeat_frame <= reg_dta_in[9:5];
    else repeat_frame <= repeat_frame;

  always @(posedge clk)
    if (~hard_rst) persistence <= 1'b1;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_TRICK)) persistence <= reg_dta_in[4];
    else persistence <= persistence;

  always @(posedge clk)
    if (~hard_rst) source_select <= 3'b0;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_TRICK)) source_select <= reg_dta_in[3:1];
    else source_select <= source_select;

  /*
   * Signal used to clear circular video buffer. 
   * This includes resetting FIFO's. For  Xilinx FIFO18/FIFO36 primitives:
   * "The reset signal must be high for at least three read clock and three write clock cycles."
   */

  always @(posedge clk)
    if (~hard_rst) flush_vbuf <= 1'b1;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_TRICK)) flush_vbuf <= reg_dta_in[0];
    else if (clk_en) flush_vbuf <= 1'b0;
    else flush_vbuf <= flush_vbuf;

  /*
   * REG_WR_TESTPOINT
   */

  always @(posedge clk)
    if (~hard_rst) testpoint_sel <= 4'b0;
    else if (clk_en && reg_wr_en && (reg_addr == REG_WR_TESTPOINT)) testpoint_sel <= reg_dta_in[31:28];
    else testpoint_sel <= testpoint_sel;

  /*
   * Reset sync_gen when video modeline changes
   */

  always @(posedge clk)
    if (~hard_rst) syncgen_rst <= 1'b0;
    else if (clk_en) syncgen_rst <= ~(reg_wr_en && ((reg_addr == REG_WR_HOR) || (reg_addr == REG_WR_HOR_SYNC) || (reg_addr == REG_WR_VER) || (reg_addr == REG_WR_VER_SYNC) || (reg_addr == REG_WR_VID_MODE)));
    else syncgen_rst <= syncgen_rst;

  /*
   * interrupt.
   * assert interrupt whenever one of the following signals changes:
   * horizontal_size, vertical_size, display_horizontal_size, display_vertical_size, aspect_ratio_information,
   * progressive_sequence, aspect_ratio_information, frame_rate_extension_n, frame_rate_extension_d, frame_rate_code.
   */

  always @(posedge clk)
    if (~hard_rst) interrupt <= 1'b0;
    else if (clk_en && reg_rd_en && (reg_addr == REG_RD_STATUS)) interrupt <= 1'b0; // reset when REG_RD_STATUS read
    else if (clk_en) interrupt <= interrupt || (video_ch_intr_en && video_ch) || (frame_end_intr_en && frame_end) || (picture_hdr_intr_en && picture_hdr); // set when video modeline changes, vertical sync begins or picture header encountered.
    else interrupt <= interrupt;

  /*
   * OSD write address generator
   */

  wire         [63:0]osd_wr_dta_in = {osd_wr_dta_high, osd_wr_dta_low};
  wire signed  [12:0]osd_x_in = {2'b0, osd_x, 3'b0}; // osd_x is x-coordinate, divided by 8.
  wire signed  [12:0]osd_y_in = {2'b0, osd_y};

  /* osd address generator */
  memory_address
    #(.dta_width(64))
    osd_mem_addr (
    .clk(clk), 
    .clk_en(clk_en), 
    .rst(rst), 
    /* in */
    .frame(osd_frame), 
    .frame_picture(1'b1), 
    .field_in_frame(1'b0), 
    .field(1'b0), 
    .component(osd_comp), 
    .mb_width(mb_width), 
    .horizontal_size(horizontal_size),
    .vertical_size(vertical_size),
    .macroblock_address(13'd0), 
    .delta_x(osd_x_in), 
    .delta_y(osd_y_in), 
    .mv_x(13'sd0), 
    .mv_y(13'sd0), 
    .dta_in(osd_wr_dta_in), 
    .valid_in(osd_wr_en_in), 
    /* out */
    .address(osd_wr_addr), 
    .offset_x(), 
    .halfpixel_x(), 
    .halfpixel_y(), 
    .dta_out(osd_wr_dta), 
    .valid_out(osd_wr_en)
    );

`ifdef DEBUG
  always @(posedge clk)
    if (clk_en)
      $strobe("%m\treg_addr: %d reg_rd_en: %d reg_wr_en: %d reg_dta_out: %h reg_dta_in: %h", reg_addr, reg_rd_en, reg_wr_en, reg_dta_out, reg_dta_in);

  always @(posedge clk)
    if (clk_en)
      $strobe("%m\tosd_x_in: %d osd_y_in: %d osd_wr_dta_in: %h osd_wr_en_in: %d mb_width: %d", osd_x_in, osd_y_in, osd_wr_dta_in, osd_wr_en_in, mb_width);

  always @(posedge clk)
    if (clk_en)
      $strobe("%m\tosd_wr_addr: %h osd_wr_dta: %h osd_wr_en: %d", osd_wr_addr, osd_wr_dta, osd_wr_en);
`endif
endmodule
/* not truncated */
