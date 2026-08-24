/* 
 * resample.v
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
 * resample - Main chroma resampling module. Synchronizes resampling and motion compensation.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

`undef CHECK
`ifdef __IVERILOG__
`define CHECK 1
`endif

module resample(
  clk, rst, 
  output_frame, output_frame_valid, output_frame_rd,
  progressive_sequence, progressive_frame, top_field_first, repeat_first_field, mb_width, mb_height, horizontal_size, vertical_size, resample_wr_overflow,
  disp_wr_addr_full, disp_wr_addr_almost_full, disp_wr_addr_en, disp_wr_addr_ack, disp_wr_addr, disp_rd_dta_empty, disp_rd_dta_en, disp_rd_dta_valid, disp_rd_dta,
  pixel_wr_almost_full, interlaced, deinterlace, persistence, repeat_frame,
  y, u, v, osd_out, position_out, pixel_wr_en
  );

  input              clk;                      // clock
  input              rst;                      // synchronous active low reset

  input        [2:0]output_frame;              // frame to be displayed
  input             output_frame_valid;        // asserted when output_frame valid
  output            output_frame_rd;           // assert for next output frame

  input             progressive_sequence;
  input             progressive_frame;
  input             top_field_first;
  input             repeat_first_field;
  input        [7:0]mb_width;                  // par. 6.3.3. width of the encoded luminance component of pictures in macroblocks
  input        [7:0]mb_height;                 // par. 6.3.3. height of the encoded luminance component of frame pictures in macroblocks
  input       [13:0]horizontal_size;           // par. 6.2.2.1, par. 6.3.3 
  input       [13:0]vertical_size;             // par. 6.2.2.1, par. 6.3.3

  /* reading reconstructed frame */
  /* reading reconstructed frame: writing address */
  input            disp_wr_addr_full;
  input            disp_wr_addr_almost_full;
  output           disp_wr_addr_en;
  input            disp_wr_addr_ack;
  output     [21:0]disp_wr_addr;
  /* reading reconstructed frame: reading data */
  input            disp_rd_dta_empty;
  output           disp_rd_dta_en;
  input            disp_rd_dta_valid;
  input      [63:0]disp_rd_dta;

  input            interlaced;                // asserted if display modeline is interlaced
  input            deinterlace;               // asserted if video has to be deinterlaced
  input            persistence;               // asserted if last shown image persists
  input       [4:0]repeat_frame;

  input              pixel_wr_almost_full;
  output        [7:0]y;
  output        [7:0]u;
  output        [7:0]v;
  output        [7:0]osd_out;
  output        [2:0]position_out;
  output             pixel_wr_en;

  /* resample fifo */
  wire          [2:0]resample_wr_dta;
  wire               resample_wr_en;
  output             resample_wr_overflow;           // to probe
  wire               resample_wr_almost_full;
  wire          [2:0]resample_rd_dta;
  wire               resample_rd_en;
  wire               resample_rd_valid;

  wire               resample_addr_busy;

  wire         [12:0]mb_width_ext = {5'b0, mb_width};

`include "fifo_size.v"

  // Generates the memory read requests for displaying a frame
  resample_addrgen resample_addrgen (
    .clk(clk), 
    .clk_en(1'b1),
    .rst(rst), 
    .output_frame(output_frame), 
    .output_frame_valid(output_frame_valid), 
    .output_frame_rd(output_frame_rd),
    .progressive_sequence(progressive_sequence), 
    .progressive_frame(progressive_frame), 
    .top_field_first(top_field_first), 
    .repeat_first_field(repeat_first_field), 
    .mb_width(mb_width),
    .mb_height(mb_height),
    .horizontal_size(horizontal_size),
    .vertical_size(vertical_size),

    .disp_wr_addr_full(disp_wr_addr_full), 
    .disp_wr_addr_en(disp_wr_addr_en), 
    .disp_wr_addr_ack(disp_wr_addr_ack), 
    .disp_wr_addr(disp_wr_addr),

    .interlaced(interlaced),
    .deinterlace(deinterlace),
    .persistence(persistence),
    .repeat_frame(repeat_frame),

    .resample_wr_dta(resample_wr_dta),
    .resample_wr_en(resample_wr_en),
    
    .disp_wr_addr_almost_full(disp_wr_addr_almost_full),
    .resample_wr_almost_full(resample_wr_almost_full),
    .busy(resample_addr_busy)
    );

  wire        fifo_read;
  wire        fifo_valid;
  wire [127:0]fifo_osd;          /* osd data */
  wire [127:0]fifo_y;            /* lumi */
  wire  [63:0]fifo_u_upper;      /* chromi, upper row */
  wire  [63:0]fifo_u_lower;      /* chromi, lower row */
  wire  [63:0]fifo_v_upper;      /* chromi, upper row */
  wire  [63:0]fifo_v_lower;      /* chromi, lower row */
  wire   [2:0]fifo_position;     /* position of pixels, as in  resample_codes */

  // Reads the pixels from memory fifo
  resample_dta resample_dta (
    .clk(clk), 
    .clk_en(1'b1),
    .rst(rst), 
    .fifo_read(fifo_read),
    .fifo_valid(fifo_valid),
    .disp_rd_dta_empty(disp_rd_dta_empty), 
    .disp_rd_dta_en(disp_rd_dta_en), 
    .disp_rd_dta_valid(disp_rd_dta_valid), 
    .disp_rd_dta(disp_rd_dta), 
    .resample_rd_dta(resample_rd_dta),
    .resample_rd_en(resample_rd_en),
    .resample_rd_valid(resample_rd_valid),
    .fifo_osd(fifo_osd), 
    .fifo_y(fifo_y), 
    .fifo_u_upper(fifo_u_upper), 
    .fifo_u_lower(fifo_u_lower), 
    .fifo_v_upper(fifo_v_upper), 
    .fifo_v_lower(fifo_v_lower),
    .fifo_position(fifo_position)
    );

  // bilinear chroma upscaling, 4:2:0 to 4:4:4
  resample_bilinear resample_bilinear (
    .clk(clk), 
    .clk_en(1'b1),
    .rst(rst), 
    .fifo_read(fifo_read),
    .fifo_valid(fifo_valid),
    .fifo_osd(fifo_osd), 
    .fifo_y(fifo_y), 
    .fifo_u_upper(fifo_u_upper), 
    .fifo_u_lower(fifo_u_lower), 
    .fifo_v_upper(fifo_v_upper), 
    .fifo_v_lower(fifo_v_lower),
    .fifo_position(fifo_position),
    .y(y), 
    .u(u), 
    .v(v), 
    .osd_out(osd_out),
    .position_out(position_out),
    .pixel_wr_en(pixel_wr_en),
    .pixel_wr_almost_full(pixel_wr_almost_full)
    );

  // fifo between resample_addr and resample_dta
  fifo_sc 
    #(.addr_width(RESAMPLE_DEPTH),
    .dta_width(9'd3),
    .prog_thresh(RESAMPLE_THRESHOLD))
    resample_fifo (
    .rst(rst), 
    .clk(clk), 
    .din(resample_wr_dta), 
    .wr_en(resample_wr_en), 
    .full(), 
    .wr_ack(), 
    .overflow(resample_wr_overflow), 
    .prog_full(resample_wr_almost_full), 
    .dout(resample_rd_dta), 
    .rd_en(resample_rd_en), 
    .prog_empty(),
    .empty(), 
    .valid(resample_rd_valid), 
    .underflow()
    );

`ifdef CHECK
  always @(posedge clk)
    if (resample_wr_overflow)
      begin
        #0 $display("%m\t*** error: resample_fifo overflow. **");
        $stop;
      end
`endif

`ifdef DEBUG

  always @(posedge clk)
    $strobe("%m\toutput_frame: %d output_frame_valid: %d addr_clk_en: %d", 
                 output_frame, output_frame_valid, addr_clk_en);

  always @(posedge clk)
    if (disp_wr_addr_almost_full)
      $display("%m\taddr_clk_en: disp_wr_addr_almost_full");

`endif
endmodule
/* not truncated */
