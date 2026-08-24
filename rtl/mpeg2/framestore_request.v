/* 
 * framestore_request.v
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
 * Frame Store Requests. Write requests to memory controller.
 *
 * Receives memory read and write requests from motion compensation and display; 
 * passes the read and write requests on to the memory controller. 
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

`undef DEBUG_2
//`define DEBUG_2

`undef CHECK
`ifdef __IVERILOG__
`define CHECK 1
`endif

//`define SIMULATION_ONLY
`ifdef __IVERILOG__
`define SIMULATION_ONLY 1
`endif

module framestore_request(rst, clk, 
                  fwd_rd_addr_empty, fwd_rd_addr_en, fwd_rd_addr_valid, fwd_rd_addr, fwd_wr_dta_full, fwd_wr_dta_almost_full, fwd_rd_dta_almost_empty,
                  bwd_rd_addr_empty, bwd_rd_addr_en, bwd_rd_addr_valid, bwd_rd_addr, bwd_wr_dta_full, bwd_wr_dta_almost_full, bwd_rd_dta_almost_empty,
                  recon_rd_empty, recon_rd_almost_empty, recon_rd_en, recon_rd_valid, recon_rd_addr, recon_rd_dta, recon_wr_almost_full,
                  disp_rd_addr_empty, disp_rd_addr_en, disp_rd_addr_valid, disp_rd_addr, disp_wr_dta_full, disp_wr_dta_almost_full, disp_rd_dta_almost_empty,
                  osd_rd_empty, osd_rd_almost_empty, osd_rd_en, osd_rd_valid, osd_rd_addr, osd_rd_dta, osd_wr_almost_full,
                  vbw_rd_empty, vbw_rd_almost_empty, vbw_rd_en, vbw_rd_valid, vbw_rd_dta, vbw_wr_almost_full,
                  vbr_wr_full, vbr_wr_almost_full, vbr_rd_almost_empty,
                  vb_flush,
                  mem_req_wr_cmd, mem_req_wr_addr, mem_req_wr_dta, mem_req_wr_en, mem_req_wr_almost_full, 
                  tag_wr_dta, tag_wr_en, tag_wr_almost_full
                  );

  input            rst;
  input            clk;
  /* motion compensation: reading forward reference frame */
  input             fwd_rd_addr_empty;
  output reg        fwd_rd_addr_en;
  input             fwd_rd_addr_valid;
  input       [21:0]fwd_rd_addr;
  input             fwd_wr_dta_full;
  input             fwd_wr_dta_almost_full;
  input             fwd_rd_dta_almost_empty;
  /* motion compensation: reading backward reference frame */
  input             bwd_rd_addr_empty;
  output reg        bwd_rd_addr_en;
  input             bwd_rd_addr_valid;
  input       [21:0]bwd_rd_addr;
  input             bwd_wr_dta_full;
  input             bwd_wr_dta_almost_full;
  input             bwd_rd_dta_almost_empty;
  /*  motion compensation: writing reconstructed frame */
  input             recon_rd_empty;
  input             recon_rd_almost_empty;
  output reg        recon_rd_en;
  input             recon_rd_valid;
  input       [21:0]recon_rd_addr;
  input       [63:0]recon_rd_dta;
  input             recon_wr_almost_full;
  /* display: reading reconstructed frame */
  input             disp_rd_addr_empty;
  output reg        disp_rd_addr_en;
  input             disp_rd_addr_valid;
  input       [21:0]disp_rd_addr;
  input             disp_wr_dta_full;
  input             disp_wr_dta_almost_full;
  input             disp_rd_dta_almost_empty;
  /* video buffer: writing to circular buffer */
  input       [63:0]vbw_rd_dta;
  output reg        vbw_rd_en;
  input             vbw_rd_valid;
  input             vbw_rd_empty;
  input             vbw_rd_almost_empty;
  input             vbw_wr_almost_full;
  /* video buffer: reading from circular buffer */
  input             vbr_wr_full;
  input             vbr_wr_almost_full;
  input             vbr_rd_almost_empty;
  /* video buffer: flushing circular buffer */
  input             vb_flush;
  /*  register file: writing on-screen display */
  input             osd_rd_empty;
  input             osd_rd_almost_empty;
  output reg        osd_rd_en;
  input             osd_rd_valid;
  input       [21:0]osd_rd_addr;
  input       [63:0]osd_rd_dta;
  input             osd_wr_almost_full;
  /* memory request fifo */
  output reg   [1:0]mem_req_wr_cmd;
  output reg  [21:0]mem_req_wr_addr;
  output reg  [63:0]mem_req_wr_dta;
  output reg        mem_req_wr_en;
  input             mem_req_wr_almost_full;
  /* memory tag fifo */
  output reg   [2:0]tag_wr_dta;
  output reg        tag_wr_en;
  input             tag_wr_almost_full;

 parameter [15:0]
   REFRESH_CYCLES = 16'd1024; /* number of mem_clk clock cycles between memory refreshes. */

 parameter 
   REFRESH_EN = 1'b0; /* 1 if needs to issue REFRESH; 0 if no need to issue refresh commands, eg. sram */

 /*
  * memory controller commands.
  */

`include "mem_codes.v"

  wire do_refresh;
  wire do_disp;
  wire do_vbr;
  wire do_fwd;
  wire do_bwd;
  wire do_recon;
  wire do_osd;
  wire do_vbw;

  /* 
   * memory clear address
   */

  reg [21:0]mem_clr_addr;
  reg [21:0]mem_clr_addr_0;

  /*
   * circular video buffer addresses 
   */

  reg [21:0]vbuf_wr_addr;
  reg [21:0]vbuf_rd_addr;

  reg       vbuf_full;
  reg       vbuf_empty;

  /*
   * State machine 
   * Implements priority scheme.
   * From highest to lowest priority:
   * - disp  display read
   * - vbr   video buffer read
   * - fwd   forward motion compensation read
   * - bwd   backward motion compensation read
   * - vbw   video buffer write
   * - recon motion compensation write
   * - osd   on-screen display write
   * Roughly modeled after the priority scheme in
   * "Architecture and Bus-Arbitration Schemes for MPEG-2 Video Decoder",
   * Jui-Hua Li and Nam Ling,
   * IEEE Transactions on Circuits and Systems for Video Technology, Vol. 9, No. 5, August 1999, p.727-736.
   */


  parameter [10:0]
    STATE_INIT        = 11'b00000000001,
    STATE_CLEAR       = 11'b00000000010,
    STATE_IDLE        = 11'b00000000100,
    STATE_REFRESH     = 11'b00000001000,
    STATE_DISP        = 11'b00000010000,
    STATE_VBR         = 11'b00000100000,
    STATE_FWD         = 11'b00001000000,
    STATE_BWD         = 11'b00010000000,
    STATE_VBW         = 11'b00100000000,
    STATE_RECON       = 11'b01000000000,
    STATE_OSD         = 11'b10000000000;

  reg  [10:0]state;
  reg  [10:0]next;
  reg  [10:0]previous;

  /* next state logic */
  always @*
    case (state)
      STATE_INIT:       next = STATE_CLEAR;
      STATE_CLEAR:      if ((mem_clr_addr == VBUF_END) && ~mem_req_wr_almost_full) next = STATE_IDLE; // initialize memory
                        else next = STATE_CLEAR;
      STATE_IDLE,
      STATE_DISP,
      STATE_VBR,
      STATE_FWD,
      STATE_BWD,
      STATE_VBW,
      STATE_RECON,
      STATE_OSD:         if (do_refresh) next = STATE_REFRESH;                                 // schedule a dram refresh
                         else if (do_disp) next = STATE_DISP;                                  // schedule a read for the display fifo
                         else if (do_vbr) next = STATE_VBR;                                    // schedule a read from circular video buffer
                         else if (do_fwd) next = STATE_FWD;                                    // schedule a read for forward motion compensation
                         else if (do_bwd) next = STATE_BWD;                                    // schedule a read for backward motion compensation
                         else if (do_vbw) next = STATE_VBW;                                    // schedule a write to circular video buffer
                         else if (do_recon) next = STATE_RECON;                                // schedule a write for motion compensation to write the reconstructed frame
                         else if (do_osd) next = STATE_OSD;                                    // schedule a write for register file to write to the on-screen display
                         else next = STATE_IDLE;                                               // nothing to do

      STATE_REFRESH:     if (do_disp) next = STATE_DISP;
                         else if (do_vbr) next = STATE_VBR;
                         else if (do_fwd) next = STATE_FWD;
                         else if (do_bwd) next = STATE_BWD;
                         else if (do_vbw) next = STATE_VBW;
                         else if (do_recon) next = STATE_RECON;
                         else if (do_osd) next = STATE_OSD;
                         else next = STATE_IDLE;

      default            next = STATE_IDLE;

    endcase

  always @(posedge clk)
    if (~rst) state <= STATE_INIT;
    else state <= next;

  always @(posedge clk)
    if (~rst) previous <= STATE_INIT;
    else previous <= state;

  /*
   * Read data from fifo's
   */

  always @(posedge clk)
    if (~rst) disp_rd_addr_en <= 1'b0;
    else disp_rd_addr_en <= (next == STATE_DISP);

  always @(posedge clk)
    if (~rst) fwd_rd_addr_en <= 1'b0;
    else fwd_rd_addr_en <= (next == STATE_FWD);

  always @(posedge clk)
    if (~rst) bwd_rd_addr_en <= 1'b0;
    else bwd_rd_addr_en <= (next == STATE_BWD);

  always @(posedge clk)
    if (~rst) recon_rd_en <= 1'b0;
    else recon_rd_en <= (next == STATE_RECON);

  always @(posedge clk)
    if (~rst) vbw_rd_en <= 1'b0;
    else vbw_rd_en <= (next == STATE_VBW);

  always @(posedge clk)
    if (~rst) osd_rd_en <= 1'b0;
    else osd_rd_en <= (next == STATE_OSD);

  /*
   * Write address, data, command to memory request fifo.
   * Write tag to tag fifo.
   */

  always @(posedge clk)
    if (~rst) tag_wr_dta <= TAG_CTRL;
    else
      case (previous)
        STATE_INIT:        tag_wr_dta <= TAG_CTRL;
        STATE_CLEAR:       tag_wr_dta <= TAG_CTRL;
        STATE_IDLE:        tag_wr_dta <= TAG_CTRL;
        STATE_REFRESH:     tag_wr_dta <= TAG_CTRL;
        STATE_DISP:        tag_wr_dta <= TAG_DISP;
        STATE_VBR:         tag_wr_dta <= TAG_VBUF;
        STATE_FWD:         tag_wr_dta <= TAG_FWD;
        STATE_BWD:         tag_wr_dta <= TAG_BWD;
        STATE_RECON:       tag_wr_dta <= TAG_RECON;
        STATE_VBW:         tag_wr_dta <= TAG_VBUF;
        STATE_OSD:         tag_wr_dta <= TAG_OSD;
        default            tag_wr_dta <= TAG_CTRL;
      endcase

  always @(posedge clk)
    if (~rst) tag_wr_en <= 1'b0;
    else
      case (previous)
        STATE_INIT:        tag_wr_en <= 1'b0;
        STATE_CLEAR:       tag_wr_en <= 1'b0;
        STATE_IDLE:        tag_wr_en <= 1'b0;
        STATE_REFRESH:     tag_wr_en <= 1'b0;
        STATE_DISP:        tag_wr_en <= disp_rd_addr_valid;
        STATE_VBR:         tag_wr_en <= ~vbuf_empty;
        STATE_FWD:         tag_wr_en <= fwd_rd_addr_valid;
        STATE_BWD:         tag_wr_en <= bwd_rd_addr_valid;
        STATE_RECON:       tag_wr_en <= 1'b0;
        STATE_VBW:         tag_wr_en <= 1'b0;
        STATE_OSD:         tag_wr_en <= 1'b0;
        default            tag_wr_en <= 1'b0;
      endcase

  always @(posedge clk)
    if (~rst) mem_req_wr_cmd <= CMD_NOOP;
    else 
      case (previous)
        STATE_INIT:        mem_req_wr_cmd <= CMD_NOOP;
        STATE_CLEAR:       mem_req_wr_cmd <= CMD_WRITE;
        STATE_IDLE:        mem_req_wr_cmd <= CMD_NOOP;
        STATE_REFRESH:     mem_req_wr_cmd <= CMD_REFRESH;
        STATE_DISP:        mem_req_wr_cmd <= disp_rd_addr_valid  ? CMD_READ  : CMD_NOOP;
        STATE_VBR:         mem_req_wr_cmd <= ~vbuf_empty         ? CMD_READ  : CMD_NOOP;
        STATE_FWD:         mem_req_wr_cmd <= fwd_rd_addr_valid   ? CMD_READ  : CMD_NOOP;
        STATE_BWD:         mem_req_wr_cmd <= bwd_rd_addr_valid   ? CMD_READ  : CMD_NOOP;
        STATE_RECON:       mem_req_wr_cmd <= recon_rd_valid      ? CMD_WRITE : CMD_NOOP;
        STATE_VBW:         mem_req_wr_cmd <= vbw_rd_valid        ? CMD_WRITE : CMD_NOOP;
        STATE_OSD:         mem_req_wr_cmd <= osd_rd_valid        ? CMD_WRITE : CMD_NOOP;
        default            mem_req_wr_cmd <= CMD_NOOP;
      endcase

  always @(posedge clk)
    if (~rst) mem_req_wr_addr <= 22'b0;
    else 
      case (previous)
        STATE_INIT:        mem_req_wr_addr <= 22'b0;
        STATE_CLEAR:       mem_req_wr_addr <= mem_clr_addr_0;
        STATE_IDLE:        mem_req_wr_addr <= 22'b0;
        STATE_REFRESH:     mem_req_wr_addr <= 22'b0;
        STATE_DISP:        mem_req_wr_addr <= disp_rd_addr_valid  ? disp_rd_addr     : 22'b0;
        STATE_VBR:         mem_req_wr_addr <= ~vbuf_empty         ? vbuf_rd_addr     : 22'b0;
        STATE_FWD:         mem_req_wr_addr <= fwd_rd_addr_valid   ? fwd_rd_addr      : 22'b0;
        STATE_BWD:         mem_req_wr_addr <= bwd_rd_addr_valid   ? bwd_rd_addr      : 22'b0;
        STATE_RECON:       mem_req_wr_addr <= recon_rd_valid      ? recon_rd_addr    : 22'b0;
        STATE_VBW:         mem_req_wr_addr <= vbw_rd_valid        ? vbuf_wr_addr     : 22'b0;
        STATE_OSD:         mem_req_wr_addr <= osd_rd_valid        ? osd_rd_addr      : 22'b0;
        default            mem_req_wr_addr <= 22'b0;
      endcase


  /*
   * All y,u and v values are stored in memory with an offset of 128; hence every memory byte is initialized to 8'd128. 
   * This corresponds to y=u=v=0; a dull green.
   */

  always @(posedge clk)
    if (~rst) mem_req_wr_dta <= 64'b0;
    else 
      case (previous)
        STATE_INIT:        mem_req_wr_dta <= 64'b0;
        STATE_CLEAR:       mem_req_wr_dta <= {8{8'd128}}; // initialize memory to all zeroes; all zeroes in yuv is a dull green
//        STATE_CLEAR:       mem_req_wr_dta <= {mem_clr_addr_0, 32'hdeadbeef}; // initialize memory so reads from addresses not written to can be easily detected
        STATE_IDLE:        mem_req_wr_dta <= 64'b0;
        STATE_REFRESH:     mem_req_wr_dta <= 64'b0;
        STATE_DISP:        mem_req_wr_dta <= 64'b0;
        STATE_VBR:         mem_req_wr_dta <= 64'b0;
        STATE_FWD:         mem_req_wr_dta <= 64'b0;
        STATE_BWD:         mem_req_wr_dta <= 64'b0;
        STATE_RECON:       mem_req_wr_dta <= recon_rd_valid       ? recon_rd_dta : 64'b0;
        STATE_VBW:         mem_req_wr_dta <= vbw_rd_valid         ? vbw_rd_dta : 64'b0;
        STATE_OSD:         mem_req_wr_dta <= osd_rd_valid         ? osd_rd_dta   : 64'b0;
        default            mem_req_wr_dta <= 64'b0;
      endcase

  always @(posedge clk)
    if (~rst) mem_req_wr_en <= 1'b0;
    else 
      case (previous)
        STATE_INIT:        mem_req_wr_en <= 1'b0;
        STATE_CLEAR:       mem_req_wr_en <= ~mem_req_wr_almost_full;
        STATE_IDLE:        mem_req_wr_en <= 1'b0;
        STATE_REFRESH:     mem_req_wr_en <= 1'b1;
        STATE_DISP:        mem_req_wr_en <= disp_rd_addr_valid;
        STATE_VBR:         mem_req_wr_en <= ~vbuf_empty;
        STATE_FWD:         mem_req_wr_en <= fwd_rd_addr_valid;
        STATE_BWD:         mem_req_wr_en <= bwd_rd_addr_valid;
        STATE_RECON:       mem_req_wr_en <= recon_rd_valid;
        STATE_VBW:         mem_req_wr_en <= vbw_rd_valid;
        STATE_OSD:         mem_req_wr_en <= osd_rd_valid;
        default            mem_req_wr_en <= 1'b0;
      endcase


  /*
   * Clearing memory at start-up.
   * When we're simulating, SIMULATION_ONLY is defined and we only clear 10 addresses at the end of memory, else simulation takes forever.
   * When we're synthesizing, SIMULATION_ONLY is not defined, and we initialize all of memory.
   */

  always @(posedge clk)
    if (~rst) mem_clr_addr <= 22'd0;
`ifdef SIMULATION_ONLY
    else if (state == STATE_INIT) mem_clr_addr <= VBUF_END - 22'd10; /* only clear ten last addresses */
`else
    else if (state == STATE_INIT) mem_clr_addr <= FRAME_0_Y; /* lowest address used */
`endif
    else if ((state == STATE_CLEAR) && ~mem_req_wr_almost_full) mem_clr_addr <= mem_clr_addr + 22'd1;
    else mem_clr_addr <= mem_clr_addr;

  always @(posedge clk)
    if (~rst) mem_clr_addr_0 <= FRAME_0_Y;
    else if ((state == STATE_CLEAR) && ~mem_req_wr_almost_full) mem_clr_addr_0 <= mem_clr_addr;
    else mem_clr_addr_0 <= mem_clr_addr_0;

  /*
   * Refresh counter. Refresh at least every REFRESH_CYCLES cycles.
   */

  reg [15:0]refresh_cnt;

  always @(posedge clk)
    if (~rst) refresh_cnt <= REFRESH_CYCLES;
    else if (state == STATE_REFRESH) refresh_cnt <= REFRESH_CYCLES;
    else if (refresh_cnt != 0) refresh_cnt <= refresh_cnt - 1;
    else refresh_cnt <= refresh_cnt;

  /*
   * circular video buffer addresses 
   */

  reg [21:0]next_vbuf_wr_addr;
  reg [21:0]next_vbuf_rd_addr;
  reg next_vbuf_full;
  reg next_vbuf_empty;

  always @*
    if ((previous == STATE_VBW) && vbw_rd_valid) next_vbuf_wr_addr = (vbuf_wr_addr == VBUF_END) ? VBUF : (vbuf_wr_addr + 22'd1);
    else next_vbuf_wr_addr = vbuf_wr_addr;

  always @*
    if ((previous == STATE_VBR) && ~vbuf_empty) next_vbuf_rd_addr = (vbuf_rd_addr == VBUF_END) ? VBUF : (vbuf_rd_addr + 22'd1);
    else next_vbuf_rd_addr = vbuf_rd_addr;

  always @*
    next_vbuf_full = ((next_vbuf_wr_addr + 22'd1) == next_vbuf_rd_addr) || ((next_vbuf_wr_addr == VBUF_END) && (next_vbuf_rd_addr == VBUF));
  
  always @*
    next_vbuf_empty = (next_vbuf_wr_addr == next_vbuf_rd_addr);

  always @(posedge clk)
    if (~rst) vbuf_wr_addr <= VBUF;
    else if (vb_flush) vbuf_wr_addr <= VBUF;
    else vbuf_wr_addr <= next_vbuf_wr_addr;

  always @(posedge clk)
    if (~rst) vbuf_rd_addr <= VBUF;
    else if (vb_flush) vbuf_rd_addr <= VBUF;
    else vbuf_rd_addr <= next_vbuf_rd_addr;

  always @(posedge clk)
    if (~rst) vbuf_full <= 1'b0;
    else if (vb_flush) vbuf_full <= 1'b0;
    else vbuf_full <= next_vbuf_full;

  always @(posedge clk)
    if (~rst) vbuf_empty <= 1'b1;
    else if (vb_flush) vbuf_empty <= 1'b1;
    else vbuf_empty <= next_vbuf_empty;

  /*
   * Priority scheme: 
   *  refresh >  display frame read > forward frame read > backward frame read > reconstructed frame write > osd write
   *
   * Note we do not treat requests for a 'reader' when the data fifo is "almost full".
   * this way the data fifo never overflows (hopefully).
   * 
   * Note we do not allow two consecutive vbuf writes. 
   * The first vbuf write might cause vbuf_full to assert, which would make the second vbuf write overflow the fifo.
   * Not allowing two consecutive vbuf writes is not a problem, given program stream bitrates.
   */

  wire vbuf_holdoff = (state == STATE_VBW) || (state == STATE_VBR) || (previous == STATE_VBW) || (previous == STATE_VBR);
 
  assign do_refresh = (refresh_cnt == 0)                    && REFRESH_EN                 && ~mem_req_wr_almost_full;
  assign do_disp    = ~disp_rd_addr_empty                   && ~disp_wr_dta_almost_full   && ~mem_req_wr_almost_full && ~tag_wr_almost_full;
  assign do_vbr     = ~vbuf_empty          && ~vbuf_holdoff &&  vbr_rd_almost_empty       && ~mem_req_wr_almost_full && ~tag_wr_almost_full;
  assign do_fwd     = ~fwd_rd_addr_empty                    && ~fwd_wr_dta_almost_full    && ~mem_req_wr_almost_full && ~tag_wr_almost_full;
  assign do_bwd     = ~bwd_rd_addr_empty                    && ~bwd_wr_dta_almost_full    && ~mem_req_wr_almost_full && ~tag_wr_almost_full;
  assign do_recon   =                                          ~recon_rd_empty            && ~mem_req_wr_almost_full;
  assign do_vbw     = ~vbuf_full           && ~vbuf_holdoff && ~vbw_rd_empty              && ~mem_req_wr_almost_full;
  assign do_osd     =                                          ~osd_rd_empty              && ~mem_req_wr_almost_full;

`ifdef DEBUG
  always @(posedge clk)
    case (state)
      STATE_INIT:                                #0 $display("%m\tinit");
      STATE_CLEAR:       if (~mem_req_wr_almost_full) #0 $display("%m\tclear %h", mem_clr_addr);
      STATE_IDLE:                                #0 $display("%m\tidle");
      STATE_DISP:        if (disp_rd_addr_valid) #0 $display("%m\tdisp  read %h", disp_rd_addr);
      STATE_VBW:         if (vbw_rd_valid)       #0 $display("%m\tvbw   write %6h = %h", vbuf_wr_addr, vbw_rd_dta);
      STATE_FWD:         if (fwd_rd_addr_valid)  #0 $display("%m\tfwd   read %h", fwd_rd_addr);
      STATE_BWD:         if (bwd_rd_addr_valid)  #0 $display("%m\tbwd   read %h", bwd_rd_addr);
      STATE_RECON:       if (recon_rd_valid)     #0 $display("%m\trecon write %6h = %h", recon_rd_addr, recon_rd_dta);
      STATE_VBR:                                 #0 $display("%m\tvbr   read %h", vbuf_rd_addr);
      STATE_OSD:         if (osd_rd_valid)       #0 $display("%m\tosd   write %6h = %h", osd_rd_addr, osd_rd_dta);
      default            #0 $display("%m\t** Error: unknown state %d **", state);
    endcase

`endif

`ifdef CHECK
  always @(posedge clk)
    if (vbw_rd_valid && vbr_wr_full) 
      begin
        $display("%m\t***error*** vbw_rd_valid && vbr_wr_full");
        $finish();
      end

  always @(posedge clk)
    if ((state == STATE_VBW) && vbw_rd_valid && ((vbuf_wr_addr < VBUF) || (vbuf_wr_addr > VBUF_END))) 
      begin
        $display("%m\t***error*** vbuf_wr_addr out of range: %h", vbuf_wr_addr);
        $finish();
      end

  always @(posedge clk)
    if ((state == STATE_VBR) && ~vbuf_empty && ((vbuf_rd_addr < VBUF) || (vbuf_rd_addr > VBUF_END))) 
      begin
        $display("%m\t***error*** vbuf_rd_addr out of range: %h", vbuf_rd_addr);
        $finish();
      end
`endif

`ifdef DEBUG_2
  always @(posedge clk)
    case (state)
      STATE_INIT:        #0 $display("%m\tSTATE_INIT");
      STATE_CLEAR:       #0 $display("%m\tSTATE_CLEAR");
      STATE_IDLE:        #0 $display("%m\tSTATE_IDLE");
      STATE_REFRESH:     #0 $display("%m\tSTATE_REFRESH");
      STATE_DISP:        #0 $display("%m\tSTATE_DISP");
      STATE_VBR:         #0 $display("%m\tSTATE_VBR");
      STATE_FWD:         #0 $display("%m\tSTATE_FWD");
      STATE_BWD:         #0 $display("%m\tSTATE_BWD");
      STATE_RECON:       #0 $display("%m\tSTATE_RECON");
      STATE_VBW:         #0 $display("%m\tSTATE_VBW");
      STATE_OSD:         #0 $display("%m\tSTATE_OSD");
      default            #0 $display("%m\t** Error: unknown state %d **", state);
    endcase


  always @(posedge clk)
    begin
      $strobe("%m\tstate: %h  fwd_rd_addr_empty: %h  fwd_rd_addr_en: %h  fwd_rd_addr_valid: %h  fwd_rd_addr: %h  fwd_wr_dta_full: %h",
                   state, fwd_rd_addr_empty, fwd_rd_addr_en, fwd_rd_addr_valid, fwd_rd_addr, fwd_wr_dta_full);
      $strobe("%m\tbwd_rd_addr_empty: %h  bwd_rd_addr_en: %h  bwd_rd_addr_valid: %h  bwd_rd_addr: %h  bwd_wr_dta_full: %h",
                   bwd_rd_addr_empty, bwd_rd_addr_en, bwd_rd_addr_valid, bwd_rd_addr, bwd_wr_dta_full);
      $strobe("%m\trecon_rd_empty: %h  recon_rd_en: %h  recon_rd_valid: %h  recon_rd_addr: %h  recon_rd_dta: %h",
                   recon_rd_empty, recon_rd_en, recon_rd_valid, recon_rd_addr, recon_rd_dta);
      $strobe("%m\tdisp_rd_addr_empty: %h  disp_rd_addr_en: %h  disp_rd_addr_valid: %h  disp_rd_addr: %h  disp_wr_dta_full: %h",
                   disp_rd_addr_empty, disp_rd_addr_en, disp_rd_addr_valid, disp_rd_addr, disp_wr_dta_full);
      $strobe("%m\tosd_rd_empty: %h  osd_rd_en: %h  osd_rd_valid: %h  osd_rd_addr: %h  osd_rd_dta: %h",
                   osd_rd_empty, osd_rd_en, osd_rd_valid, osd_rd_addr, osd_rd_dta);
      $strobe("%m\tvbw_rd_empty: %h  vbw_rd_en: %h  vbw_rd_valid: %h  vbw_rd_dta: %h vbr_wr_full: %h  vbr_wr_almost_full: %h",
                   vbw_rd_empty, vbw_rd_en, vbw_rd_valid, vbw_rd_dta, vbr_wr_full, vbr_wr_almost_full);
      $strobe("%m\tvbuf_wr_addr: %h  vbuf_rd_addr: %h  vbuf_full: %h  vbuf_empty: %h next_vbuf_wr_addr: %h next_vbuf_rd_addr: %h",
                   vbuf_wr_addr, vbuf_rd_addr, vbuf_full, vbuf_empty, next_vbuf_wr_addr, next_vbuf_rd_addr);
      $strobe("%m\tvbw_rd_empty: %h  vbw_rd_en: %h  vbw_rd_valid: %h  vbw_rd_dta: %h  vbuf_wr_addr: %h  vbuf_rd_addr: %h  vbuf_full: %h  vbuf_empty: %h  vbr_wr_full: %h  vbr_wr_almost_full: %h",
                   vbw_rd_empty, vbw_rd_en, vbw_rd_valid, vbw_rd_dta, vbuf_wr_addr, vbuf_rd_addr, vbuf_full, vbuf_empty, vbr_wr_full, vbr_wr_almost_full);
      $strobe("%m\tmem_req_wr_cmd: %h  mem_req_wr_addr: %h  mem_req_wr_dta: %h  mem_req_wr_en: %h  mem_req_wr_almost_full: %h",
                   mem_req_wr_cmd, mem_req_wr_addr, mem_req_wr_dta, mem_req_wr_en, mem_req_wr_almost_full);
      $strobe("%m\ttag_wr_dta: %h  tag_wr_en: %h  tag_wr_almost_full: %h",
                   tag_wr_dta, tag_wr_en, tag_wr_almost_full);
    end
`endif
endmodule

/* not truncated */
