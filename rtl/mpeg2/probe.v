/* 
 * probe.v
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
 * logical analyzer probe
 *
 * Input:
 *   registers from all over the place.
 *   testpoint_regfile, testpoint_dip, testpoint_dip_en: selects which test point to output to logic analyzer. 
 * Output:
 *   testpoint: 34-channel test point. Convention: testpoint can contain up to two clocks. Any clocks are mapped on bits 32 and/or 33.
 *
 *   Note instantiating the probe makes routing/timing more difficult; don't instantiate the probe if you don't need it.
 */

`include "timescale.v"

// uncomment one and only one of the three following lines to instantiate testpoint
`define PROBE 1
//`define PROBE_VIDEO 1
//`define PROBE_MEMORY 1

/*
 * Define PROBE only when needed.
 * Define PROBE_VIDEO and/or PROBE_MEMORY only when really needed.
 */

module probe(clk, mem_clk, dot_clk, 
             sync_rst, mem_rst, dot_rst, 
             testpoint_dip, testpoint_dip_en , testpoint_regfile, testpoint,
             stream_data, stream_valid, busy,
             vbr_rd_dta, vbr_rd_en, vbr_rd_valid, advance, align,
             getbits, signbit, getbits_valid,
             dct_coeff_wr_run, dct_coeff_wr_signed_level, dct_coeff_wr_end, rld_wr_en,
             vld_en, motcomp_busy, error, watchdog_rst,
             macroblock_address, macroblock_motion_forward, macroblock_motion_backward, 
	     macroblock_intra, second_field, update_picture_buffers, last_frame, motion_vector_valid,
             /* fifo's @ clk */
	     mvec_wr_almost_full, mvec_wr_overflow, dst_wr_overflow, dct_block_wr_overflow,
             bwd_wr_addr_almost_full, bwd_wr_addr_full, bwd_wr_addr_overflow, bwd_rd_addr_empty, bwd_wr_dta_almost_full, bwd_wr_dta_full, bwd_wr_dta_overflow,
             bwd_rd_dta_empty,
             disp_wr_addr_almost_full, disp_wr_addr_full, disp_wr_addr_overflow, disp_rd_addr_empty, disp_wr_dta_almost_full, disp_wr_dta_full, disp_wr_dta_overflow,
             disp_rd_dta_empty,
             fwd_wr_addr_almost_full, fwd_wr_addr_full, fwd_wr_addr_overflow, fwd_rd_addr_empty, fwd_wr_dta_almost_full, fwd_wr_dta_full, fwd_wr_dta_overflow,
             fwd_rd_dta_empty,
             idct_fifo_almost_full, idct_fifo_overflow, idct_rd_dta_empty, frame_idct_wr_overflow,
             mem_req_wr_almost_full, mem_req_wr_full, mem_req_wr_overflow,
             resample_wr_overflow,
             pixel_wr_almost_full, pixel_wr_full, pixel_wr_overflow, pixel_rd_empty,
             recon_wr_almost_full, recon_wr_full, recon_wr_overflow, recon_rd_empty,
             rld_wr_almost_full, rld_wr_overflow,
             tag_wr_almost_full, tag_wr_full, tag_wr_overflow,
             vbr_wr_almost_full, vbr_wr_full, vbr_wr_overflow, vbr_rd_empty, vbw_wr_almost_full, vbw_wr_full, vbw_wr_overflow,
             vbw_rd_empty,
             /* fifo's @ mem_clk */
             mem_req_rd_en, mem_req_rd_valid,
             mem_res_wr_en, mem_res_wr_almost_full, mem_res_wr_full, mem_res_wr_overflow,
             /* register file */
             reg_addr, reg_wr_en, reg_dta_in, reg_rd_en, reg_dta_out,
             /* output frame */
             output_frame, output_frame_valid, output_frame_rd, 
             output_progressive_sequence, output_progressive_frame, output_top_field_first, output_repeat_first_field,
	     /* osd writes */
	     osd_wr_en, osd_wr_ack, osd_wr_addr, osd_wr_full, osd_wr_overflow, osd_rd_empty,
             /* video out */
             y, u, v, pixel_en, h_sync, v_sync
	     );

  input            clk;                     // clock. Typically a multiple of 27 Mhz as MPEG2 timestamps have a 27 Mhz resolution.
  input            mem_clk;                 // memory clock. Typically 133-166 MHz.
  input            dot_clk;                 // video clock. Typically between 25 and 75 Mhz, depending upon MPEG2 resolution and frame rate.

  /* reset signals */
  input            sync_rst;                // reset, synchronized to clk
  input            mem_rst;                 // reset, synchronized to mem_clk
  input            dot_rst;                 // reset, synchronized to dot_clk

  /* logical analyzer test point */
  output     [33:0]testpoint;               // to logic analyzer probe
  input       [3:0]testpoint_regfile;       // from register file; test point select.
  input       [3:0]testpoint_dip;           // from from on-board dipswitches
  input            testpoint_dip_en;        // from from on-board dipswitches. If high, testpoint_dip overrides testpoint_regfile

  /* MPEG stream input */
  input       [7:0]stream_data;              // packetized elementary stream input
  input            stream_valid;             // stream_data valid
  input            busy;                     // input fifo almost full

  /* vbr fifo - getbits fifo interface */
  input      [63:0]vbr_rd_dta;
  input            vbr_rd_en;
  input            vbr_rd_valid;

  /* getbits_fifo - vld interface */
  input       [4:0]advance;                  // number of bits to advance the bitstream (advance <= 24)   
  input            align;                    // byte-align getbits and move forward one byte.
  input      [23:0]getbits;                  // elementary stream data. 
  input            signbit;                  // sign bit, used when decoding dct variable length codes.
  input            getbits_valid;            // getbits_valid is asserted when getbits is valid.

  /* vld */
  input            vld_en;
  input            error;
  input            motcomp_busy;

  /* watchdog */
  input            watchdog_rst;             // watchdog-generated reset signal. normally high; low during one clock cycle when watchdog timer expires.

  /* rld - vld interface */
  input       [5:0]dct_coeff_wr_run;         // dct coefficient runlength, from vlc decoding
  input      [11:0]dct_coeff_wr_signed_level;// dct coefficient level, 2's complement format, from vlc decoding
  input            dct_coeff_wr_end;         // asserted at end of block 
  input            rld_wr_en;                // asserted when dct_coeff_wr_run, dct_coeff_wr_signed_level and dct_coeff_wr_end are valid

  /* motion compensation */
  input      [12:0]macroblock_address;
  input            macroblock_motion_forward;
  input            macroblock_motion_backward;
  input            macroblock_intra;
  input            second_field;
  input            update_picture_buffers;
  input            last_frame;
  input            motion_vector_valid;

  /* fifo status indicators @ clk */
  input            bwd_wr_addr_almost_full;
  input            bwd_wr_addr_full;
  input            bwd_wr_addr_overflow;
  input            bwd_rd_addr_empty;
  input            bwd_wr_dta_almost_full;
  input            bwd_wr_dta_full;
  input            bwd_wr_dta_overflow;
  input            bwd_rd_dta_empty;
  input            disp_wr_addr_almost_full;
  input            disp_wr_addr_full;
  input            disp_wr_addr_overflow;
  input            disp_rd_addr_empty;
  input            disp_wr_dta_almost_full;
  input            disp_wr_dta_full;
  input            disp_wr_dta_overflow;
  input            disp_rd_dta_empty;
  input            fwd_wr_addr_almost_full;
  input            fwd_wr_addr_full;
  input            fwd_wr_addr_overflow;
  input            fwd_rd_addr_empty;
  input            fwd_wr_dta_almost_full;
  input            fwd_wr_dta_full;
  input            fwd_wr_dta_overflow;
  input            fwd_rd_dta_empty;
  input            idct_fifo_almost_full;
  input            idct_fifo_overflow;
  input            idct_rd_dta_empty;
  input            mvec_wr_almost_full;
  input            mvec_wr_overflow;
  input            dst_wr_overflow;
  input            dct_block_wr_overflow;
  input            frame_idct_wr_overflow;
  input            mem_req_wr_almost_full;
  input            mem_req_wr_full;
  input            mem_req_wr_overflow;
  input            osd_wr_full;
  input            osd_wr_overflow;
  input            osd_rd_empty;
  input            resample_wr_overflow;
  input            pixel_wr_almost_full;
  input            pixel_wr_full;
  input            pixel_wr_overflow;
  input            pixel_rd_empty;
  input            recon_wr_almost_full;
  input            recon_wr_full;
  input            recon_wr_overflow;
  input            recon_rd_empty;
  input            rld_wr_almost_full;
  input            rld_wr_overflow;
  input            tag_wr_almost_full;
  input            tag_wr_full;
  input            tag_wr_overflow;
  input            vbr_wr_almost_full;
  input            vbr_wr_full;
  input            vbr_wr_overflow;
  input            vbr_rd_empty;
  input            vbw_wr_almost_full;
  input            vbw_wr_full;
  input            vbw_wr_overflow;
  input            vbw_rd_empty;
  /* fifo status indicators @ mem_clk */
  input            mem_req_rd_en;
  input            mem_req_rd_valid;
  input            mem_res_wr_en;
  input            mem_res_wr_almost_full;
  input            mem_res_wr_full;
  input            mem_res_wr_overflow;
  /* regfile */
  input       [3:0]reg_addr;
  input      [31:0]reg_dta_in;
  input            reg_wr_en;
  input      [31:0]reg_dta_out;
  input            reg_rd_en;
  /* output frame */
  input       [2:0]output_frame;
  input            output_frame_valid;
  input            output_frame_rd;
  input            output_progressive_sequence;
  input            output_progressive_frame;
  input            output_top_field_first;
  input            output_repeat_first_field;

  /* osd writes */
  input            osd_wr_en;
  input            osd_wr_ack;
  input      [21:0]osd_wr_addr;

  /* yuv video */
  input       [7:0]y;                       // luminance 
  input       [7:0]u;                       // chrominance
  input       [7:0]v;                       // chrominance
  input            pixel_en;                // pixel enable - asserted if r, g and b valid.
  input            h_sync;                  // horizontal synchronisation
  input            v_sync;                  // vertical synchronisation

  /* 
   * any clocks have to be bits 32 or 33 of testpoint, because that's where my la expects them.
   */

`ifdef PROBE
  reg   [3:0]testpoint_sel;
  reg  [32:0]testpoint_0_f;
  reg  [32:0]testpoint_0_7;
  reg  [32:0]testpoint_8_f;

  reg  [32:0]testpoint_0;
  reg  [32:0]testpoint_1;
  reg  [32:0]testpoint_2;
  reg  [32:0]testpoint_3;
  reg  [32:0]testpoint_4;
  reg  [32:0]testpoint_5;
  reg  [32:0]testpoint_6;
  reg  [32:0]testpoint_7;
  reg  [32:0]testpoint_8;
  reg  [32:0]testpoint_9;
  reg  [32:0]testpoint_a;
  reg  [32:0]testpoint_b;
  reg  [32:0]testpoint_c;
  reg  [32:0]testpoint_d;
  reg  [32:0]testpoint_e;
  reg  [32:0]testpoint_f;

  /*
   * testpoint_dip_en and testpoint_dip are dip switches. 
   * If testpoint_dip_en is high, testpoint output is hardware selectable using testpoint_dip dip switches.
   * If testpoint_dip_en is low,  testpoint output is software selectable using regfile register 15. 
   * Software can read testpoint output as well, using regfile register 15.
   */

  always @(posedge clk)
    testpoint_sel <= testpoint_dip_en ? testpoint_dip : testpoint_regfile;

  assign testpoint = {clk, testpoint_0_f};

  always @(posedge clk)
    case (testpoint_sel[2:0])
      3'h0:     testpoint_0_7 <= {testpoint_0[0], testpoint_0[32:1]};
      3'h1:     testpoint_0_7 <= {testpoint_1[0], testpoint_1[32:1]};
      3'h2:     testpoint_0_7 <= {testpoint_2[0], testpoint_2[32:1]};
      3'h3:     testpoint_0_7 <= {testpoint_3[0], testpoint_3[32:1]};
      3'h4:     testpoint_0_7 <= {testpoint_4[0], testpoint_4[32:1]};
      3'h5:     testpoint_0_7 <= {testpoint_5[0], testpoint_5[32:1]};
      3'h6:     testpoint_0_7 <= {testpoint_6[0], testpoint_6[32:1]};
      3'h7:     testpoint_0_7 <= {testpoint_7[0], testpoint_7[32:1]};
      default   testpoint_0_7 <= {32'hdeadbeef};
    endcase

  always @(posedge clk)
    case (testpoint_sel[2:0])
      3'h0:     testpoint_8_f <= {testpoint_8[0], testpoint_8[32:1]};
      3'h1:     testpoint_8_f <= {testpoint_9[0], testpoint_9[32:1]};
      3'h2:     testpoint_8_f <= {testpoint_b[0], testpoint_b[32:1]};
      3'h4:     testpoint_8_f <= {testpoint_c[0], testpoint_c[32:1]};
      3'h5:     testpoint_8_f <= {testpoint_d[0], testpoint_d[32:1]};
      3'h6:     testpoint_8_f <= {testpoint_e[0], testpoint_e[32:1]};
      default   testpoint_8_f <= {32'hdeadbeef};
    endcase

  always @(posedge clk)
    if (testpoint_sel[3]) testpoint_0_f <= testpoint_8_f;
    else testpoint_0_f <= testpoint_0_7;

  /* testpoint 0: incoming video */
  always @(posedge clk)
    if (~sync_rst) testpoint_0 <= 33'b0;
    else testpoint_0 <= {vbr_rd_dta[63:48], stream_data, 3'b0, watchdog_rst, busy, vbr_rd_en, vbr_rd_valid, stream_valid, sync_rst};

  /* testpoint 1: video buffer output  */
  always @(posedge clk)
    if (~sync_rst) testpoint_1 <= 33'b0;
    else testpoint_1 <= {vbr_rd_dta[63:32], vbr_rd_valid};

  /* testpoint 2: video buffer output  */
  always @(posedge clk)
    if (~sync_rst) testpoint_2 <= 33'b0;
    else testpoint_2 <= {vbr_rd_dta[31:0], vbr_rd_valid};

  /* testpoint 3: getbits */
  always @(posedge clk)
    if (~sync_rst) testpoint_3 <= 33'b0;
    else testpoint_3 <= {advance, align, getbits, signbit, getbits_valid, sync_rst};

  /* testpoint 4: vld */
  always @(posedge clk)
    if (~sync_rst) testpoint_4 <= 33'b0;
    else testpoint_4 <= {dct_coeff_wr_run, dct_coeff_wr_signed_level, dct_coeff_wr_end, 
                         vld_en, getbits_valid, rld_wr_almost_full, motcomp_busy, rld_wr_en};

  /* testpoint 5,6 and 7: regfile */
  always @(posedge clk)
    if (~sync_rst) testpoint_5 <= 33'b0;
    else testpoint_5 <= {reg_dta_out[7:0], reg_dta_in[7:0], 2'b0, reg_wr_en, reg_rd_en, reg_addr, sync_rst};

  always @(posedge clk)
    if (~sync_rst) testpoint_6 <= 33'b0;
    else testpoint_6 <= {reg_dta_in, reg_wr_en};

  always @(posedge clk)
    if (~sync_rst) testpoint_7 <= 33'b0;
    else testpoint_7 <= {reg_dta_out, reg_rd_en};

  /* testpoint 8 and 9: fifo status @ clk */ 
  always @(posedge clk)
    if (~sync_rst) testpoint_8 <= 33'b0;
    else testpoint_8 <= {bwd_wr_addr_almost_full, bwd_wr_addr_full, bwd_wr_addr_overflow, bwd_rd_addr_empty,
                         bwd_wr_dta_almost_full, bwd_wr_dta_full, bwd_wr_dta_overflow, bwd_rd_dta_empty,
                         disp_wr_addr_almost_full, disp_wr_addr_full, disp_wr_addr_overflow, disp_rd_addr_empty,
                         disp_wr_dta_almost_full, disp_wr_dta_full, disp_wr_dta_overflow, disp_rd_dta_empty,
                         fwd_wr_addr_almost_full, fwd_wr_addr_full, fwd_wr_addr_overflow, fwd_rd_addr_empty,
                         fwd_wr_dta_almost_full, fwd_wr_dta_full, fwd_wr_dta_overflow, fwd_rd_dta_empty,
                         recon_wr_almost_full, recon_wr_full, recon_wr_overflow, recon_rd_empty,
                         sync_rst};

  always @(posedge clk)
    if (~sync_rst) testpoint_9 <= 33'b0;
    else testpoint_9 <= {mvec_wr_almost_full, mvec_wr_overflow, 
                         dst_wr_overflow, resample_wr_overflow, dct_block_wr_overflow, 
                         idct_fifo_almost_full, idct_fifo_overflow, idct_rd_dta_empty, frame_idct_wr_overflow,
                         mem_req_wr_almost_full, mem_req_wr_full, mem_req_wr_overflow,
                         osd_wr_full, osd_wr_overflow, osd_rd_empty,
                         pixel_wr_almost_full, pixel_wr_full, pixel_wr_overflow, 
                         rld_wr_almost_full, rld_wr_overflow,
                         tag_wr_almost_full, tag_wr_full, tag_wr_overflow,
                         vbr_wr_almost_full, vbr_wr_full, vbr_wr_overflow, vbr_rd_empty,
                         vbw_wr_almost_full, vbw_wr_full, vbw_wr_overflow, vbw_rd_empty,
                         sync_rst};

  /* testpoint a: free */ 

  /* testpoint b: motion comp */
  always @(posedge clk)
    if (~sync_rst) testpoint_b <= 33'b0;
    else testpoint_b <= {macroblock_address, 2'b0, macroblock_motion_forward, macroblock_motion_backward, 
  	                 macroblock_intra, second_field, update_picture_buffers, last_frame, motion_vector_valid};

  /* testpoint c: osd writes; useful to check pixel coordinates to memory address translation */
  always @(posedge clk)
    if (~sync_rst) testpoint_c <= 33'b0;
    else testpoint_c <= {osd_wr_overflow, osd_wr_full, osd_wr_en, osd_wr_ack, osd_wr_addr, sync_rst};

  /* testpoint d: output frame */
  always @(posedge clk)
    if (~sync_rst) testpoint_d <= 33'b0;
    else testpoint_d <= {motcomp_busy, output_frame, output_frame_valid, output_frame_rd, 
                         output_progressive_sequence, output_progressive_frame, output_top_field_first, output_repeat_first_field, sync_rst};

  /* testpoint e: free */
  always @(posedge clk)
    if (~sync_rst) testpoint_e <= 33'b0;
    else testpoint_e <= {32'hdeadbeef, sync_rst};

  /* testpoint f: free */
`endif	

`ifndef PROBE
`ifndef PROBE_VIDEO
`ifdef PROBE_MEMORY
  /* testpoint: fifo status @ mem_clk */ 

  reg  [32:0]testpoint_mem;

  assign testpoint = {mem_clk, testpoint_mem[0], testpoint_mem[32:1]};

  always @(posedge clk)
    if (~sync_rst) testpoint_mem <= 33'b0;
    else testpoint_mem <= {mem_req_rd_en, mem_req_rd_valid,
        	           mem_res_wr_en, mem_res_wr_almost_full, mem_res_wr_full, mem_res_wr_overflow,
                           mem_rst}; 

`endif	
`endif	
`endif	

`ifndef PROBE
`ifdef PROBE_VIDEO
`ifndef PROBE_MEMORY
	      
  /* testpoint: video output @ dot_clk */ 

  reg  [32:0]testpoint_video;

  assign testpoint = {dot_clk, testpoint_video[0], testpoint_video[32:1]};

  always @(posedge clk)
    if (~sync_rst) testpoint_video <= 33'b0;
    else testpoint_video <= {pixel_rd_empty, pixel_en, h_sync, v_sync, v, u, y, dot_rst};

`endif	
`endif	
`endif	

`ifndef PROBE
`ifndef PROBE_VIDEO
`ifndef PROBE_MEMORY
  assign testpoint = 34'hdeadbeef;
`endif	
`endif	
`endif	

endmodule
/* not truncated */
