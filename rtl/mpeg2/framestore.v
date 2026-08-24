/* 
 * framestore.v
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
 * Frame Store.
 *
 * Receives memory read and write requests from motion compensation and display; 
 * passes the read and write requests on to the memory controller. 
 * Receives data read from the memory controller; 
 * passes data read on to motion compensation or display.
 */

 /*

   Frame store subsystem 

   +--------------+                                 +--------------+                                                                     +--------------+                       +--------------+
   |              | -> fwd fifo                  -> |              |                                                                     |              | -> fwd fifo (dta)  -> |              |
   |              |    read request  (addr)         |              |                                                                     |              |    |     |            |              |
   |              |                                 |              |                                                                     |              |    |     |            |              |
   | motion       | -> bwd fifo                  -> |              |                                                                     |              | -> bwd fifo (dta)  -> | motion       |
   | compensation |    read request  (addr)         |              |                           +------------+                            |              |    ||    ||           | compensation |
   |              |                                 |              |                           |  memory    |                            |              |    ||    ||           |              |
   |              | -> recon fifo                -> | framestore   | -> memory request fifo -> | controller | -> memory response fifo -> | framestore   |    ||    ||           |              |
   +--------------+    write request (addr,dta)     |  request     |    (addr, dta, command)   |            |         (dta)              | response     |    ||    ||           +--------------+
   +--------------+                                 |              |            |              +------------+          |                 |              |    ||    ||           +--------------+
   | chroma       | -> disp fifo                 -> |              |            |                        ^             |                 |              | -> disp fifo (dta) -> |  chroma      |
   | resampling   |    read request  (addr)         |              |            |                        + ------------+                 |              |    |||   |||          |  resampling  |
   +--------------+                                 |              |            |                         mem_res_wr_almost_full         |              |    |||   |||          +--------------+
   +--------------+                                 |              |            |                                                        |              |    |||   |||          +--------------+
   | stream input | -> vbuf_write_fifo (dta)     -> |              |            |                                                        |              | -> vbuf_read_fifo  -> | getbits      |
   | buffer write |                                 |              |            |                                                        |              |         (dta)         | buffer read  |
   +--------------+                                 |              |            |                                                        |              |    |||   |||          +--------------+
   +--------------+                                 |              |            |                                                        |              |    |||   |||
   | register     | -> osd fifo                  -> |              | ---------------------------> tag fifo ----------------------------> |              |    |||   |||
   | file         |    write request (addr,dta)     |              |            |                  (tag)                                 |              |    |||   |||
   +--------------+                                 +--------------+            |                    |                                   +--------------+    |||   |||
                                                          ^    ^ ^              |                    |                                             ^         |||   |||
                                                          |    | |              |                    |                                             |         |||   |||
                                                          |    | +--------------+                    |                                             +---------+++   |||
                                                          |    |mem_req_wr_almost_full               |                                    fwd_wr_dta_full,         |||
                                                          |    +-------------------------------------+                                    bwd_wr_dta_full,         |||
                                                          |     tag_wr_almost_full                                                        disp_wr_dta_full         |||
                                                          |                                                                               vbr_wr_full              |||
                                                          +--------------------------------------------------------------------------------------------------------+++
                                                                                                                                          fwd_wr_dta_almost_full,
                                                                                                                                          bwd_wr_dta_almost_full,
                                                                                                                                          disp_wr_dta_almost_full,
                                                                                                                                          vbr_wr_almost_full 


    Motion compensation issues read requests for forward motion compensation (fwd), 
    read requests for backward motion compensation (bwd), 
    and write requests for the reconstructed image (recon).
    Chroma upsampling issues read requests for displaying frames (disp).
    The register file issues write requests for updating the on-screen display.

    Framestore_request prioritizes the incoming requests and joins them into a single queue (memory request fifo, mem_request_fifo).
    When framestore_request sends a read request to the memory controller (mem_ctl) it also writes a tag to the tag fifo (mem_tag_fifo). 
    The tag has the value fwd, bwd, or disp, depending upon which fifo issued the read request.
   
    The memory controller reads memory requests from the memory request fifo, and issues the corresponding commands to ram. 
    If the memory request is a read request, the data read is sent to the memory response fifo (mem_response_fifo).

    Framestore_response reads data from the memory response fifo, and tags from the tag fifo. The data is written to the fifo that corresponds to the tag (fwd, bwd, disp).

    There is feedback in the frame store subsystem. The purpose of this feedback is to avoid fifo's overflowing:
    - framestore_request stops handling fwd read requests when the fwd data fifo is almost full (fwd_wr_dta_almost_full)
    - framestore_request stops handling bwd read requests when the bwd data fifo is almost full  (bwd_wr_dta_almost_full)
    - framestore_request stops handling disp read requests when the disp data fifo is almost full  (disp_wr_dta_almost_full)
    - framestore_request stops handling all requests when the memory request fifo is almost full (mem_req_wr_almost_full)
    - framestore_request stops handling all requests when the tag fifo is almost full (tag_wr_almost_full)
    - the memory controller stops handling requests when the memory controller output fifo is almost full (mem_res_wr_almost_full)
    - framestore_response stops reading the memory response fifo when fwd, bwd or disp fifo is full (fwd_wr_dta_full, bwd_wr_dta_full, disp_wr_dta_full, vbr_wr_full). 
      This is a last-ditch attempt to avoid the fifo's overflowing,  and - with well-dimensioned fifo's - should happen rarely, if at all.

    The main feedback loop is the feedback from fwd_wr_dta_almost_full, bwd_wr_dta_almost_full, disp_wr_dta_almost_full and vbr_wr_almost_full to framestore_request.
*/

 /*
  * Behavior upon reset
  *
  * Upon reset, framestore_request will go to STATE_CLEAR and 
  * write zeroes to the whole of the frame memory. 
  * For MP@ML, this takes at least 077fff hex = 491519 dec clock cycles.
  * After having written zeroes to the whole of the frame memory, 
  * framestore_request begins accepting memory reads/writes.
  *
  * Upon reset, and simultaneously with framestore_request clearing memory, framestore_response will go into STATE_FLUSH and 
  * flush any data in the memory response fifo. 
  * This takes 0ffff hex = 65535 clock cyles. 
  * After having flushed the memory response fifo,
  * framestore_response begins handling memory read data. 
  *
  * As 65535 is less than 491519, framestore_response is guaranteed to begin
  * handling memory read data before framestore_request begins accepting
  * memory reads/writes. This is neccessary, because otherwise
  * framestore_response might flush valid memory read data.
  *
  * The flushing of the memory response fifo upon reset guarantees the decoder
  * does not use stale data if the decoder is reset while decoding, 
  * but the external memory controller and memory fifos are not reset.
  * This could happen e.g. when a watchdog-generated reset occurs.
  */

`include "timescale.v"
`undef DEBUG
//`define DEBUG 1
`undef CHECK
`ifdef __IVERILOG__
`define CHECK 1
`endif

module framestore(rst, clk, mem_clk,
                  fwd_rd_addr_empty, fwd_rd_addr_en, fwd_rd_addr_valid, fwd_rd_addr, fwd_wr_dta_full, fwd_wr_dta_almost_full, fwd_wr_dta_en, fwd_wr_dta_ack, fwd_wr_dta, fwd_rd_dta_almost_empty,
                  bwd_rd_addr_empty, bwd_rd_addr_en, bwd_rd_addr_valid, bwd_rd_addr, bwd_wr_dta_full, bwd_wr_dta_almost_full, bwd_wr_dta_en, bwd_wr_dta_ack, bwd_wr_dta, bwd_rd_dta_almost_empty,
                  recon_rd_empty, recon_rd_almost_empty, recon_rd_en, recon_rd_valid, recon_rd_addr, recon_rd_dta, recon_wr_almost_full,
                  disp_rd_addr_empty, disp_rd_addr_en, disp_rd_addr_valid, disp_rd_addr, disp_wr_dta_full, disp_wr_dta_almost_full, disp_wr_dta_en, disp_wr_dta_ack, disp_wr_dta, disp_rd_dta_almost_empty,
                  osd_rd_empty, osd_rd_almost_empty, osd_rd_en, osd_rd_valid, osd_rd_addr, osd_rd_dta, osd_wr_almost_full,
                  vbw_rd_empty, vbw_rd_almost_empty, vbw_rd_en, vbw_rd_valid, vbw_rd_dta, vbw_wr_almost_full,
                  vbr_wr_full, vbr_wr_almost_full, vbr_wr_dta, vbr_wr_en, vbr_wr_ack, vb_flush, vbr_rd_almost_empty,
                  mem_req_rd_cmd, mem_req_rd_addr, mem_req_rd_dta, mem_req_rd_en, mem_req_rd_valid, 
                  mem_res_wr_dta, mem_res_wr_en, mem_res_wr_almost_full, mem_res_wr_full, mem_res_wr_overflow,
                  mem_req_wr_almost_full, mem_req_wr_full, mem_req_wr_overflow, 
		  tag_wr_almost_full, tag_wr_full, tag_wr_overflow
                  );

  input            rst;
  input            clk;
  input            mem_clk;
  /* motion compensation: reading forward reference frame */
  input             fwd_rd_addr_empty;
  output            fwd_rd_addr_en;
  input             fwd_rd_addr_valid;
  input       [21:0]fwd_rd_addr;
  input             fwd_wr_dta_full;
  input             fwd_wr_dta_almost_full;
  output            fwd_wr_dta_en;
  input             fwd_wr_dta_ack;
  output      [63:0]fwd_wr_dta;
  input             fwd_rd_dta_almost_empty;
  /* motion compensation: reading backward reference frame */
  input             bwd_rd_addr_empty;
  output            bwd_rd_addr_en;
  input             bwd_rd_addr_valid;
  input       [21:0]bwd_rd_addr;
  input             bwd_wr_dta_full;
  input             bwd_wr_dta_almost_full;
  output            bwd_wr_dta_en;
  input             bwd_wr_dta_ack;
  output      [63:0]bwd_wr_dta;
  input             bwd_rd_dta_almost_empty;
  /*  motion compensation: writing reconstructed frame */
  input             recon_rd_empty;
  input             recon_rd_almost_empty;
  output            recon_rd_en;
  input             recon_rd_valid;
  input       [21:0]recon_rd_addr;
  input       [63:0]recon_rd_dta;
  input             recon_wr_almost_full;
  /* display: reading reconstructed frame */
  input             disp_rd_addr_empty;
  output            disp_rd_addr_en;
  input             disp_rd_addr_valid;
  input       [21:0]disp_rd_addr;
  input             disp_wr_dta_full;
  input             disp_wr_dta_almost_full;
  output            disp_wr_dta_en;
  input             disp_wr_dta_ack;
  output      [63:0]disp_wr_dta;
  input             disp_rd_dta_almost_empty;
  /* video buffer: writing to circular buffer */
  input       [63:0]vbw_rd_dta;
  output            vbw_rd_en;
  input             vbw_rd_valid;
  input             vbw_rd_empty;
  input             vbw_rd_almost_empty;
  input             vbw_wr_almost_full;
  /* video buffer: reading from circular buffer */
  output      [63:0]vbr_wr_dta;
  output            vbr_wr_en;
  input             vbr_wr_ack;
  input             vbr_wr_full;
  input             vbr_wr_almost_full;
  input             vb_flush;
  input             vbr_rd_almost_empty;
  /*  register file: writing on-screen display */
  input             osd_rd_empty;
  input             osd_rd_almost_empty;
  output            osd_rd_en;
  input             osd_rd_valid;
  input       [21:0]osd_rd_addr;
  input       [63:0]osd_rd_dta;
  input             osd_wr_almost_full;

  /* local fifo registers */

  wire          [1:0]mem_req_wr_cmd;
  wire         [21:0]mem_req_wr_addr;
  wire         [63:0]mem_req_wr_dta;
  wire               mem_req_wr_en;
  output             mem_res_wr_full;
  output             mem_req_wr_full;
  output             mem_req_wr_overflow;
  output             mem_req_wr_almost_full;
  output        [1:0]mem_req_rd_cmd;
  output       [21:0]mem_req_rd_addr;
  output       [63:0]mem_req_rd_dta;
  input              mem_req_rd_en;
  output             mem_req_rd_valid;

  wire          [2:0]tag_wr_dta;
  wire               tag_wr_en;
  output             tag_wr_overflow;
  output             tag_wr_full;
  output             tag_wr_almost_full;
  wire          [2:0]tag_rd_dta;
  wire               tag_rd_en;
  wire               tag_rd_empty;
  wire               tag_rd_valid;

  input        [63:0]mem_res_wr_dta;
  input              mem_res_wr_en;
  output             mem_res_wr_overflow;
  output             mem_res_wr_almost_full;
  wire         [63:0]mem_res_rd_dta;
  wire               mem_res_rd_en;
  wire               mem_res_rd_empty;
  wire               mem_res_rd_valid;

`include "fifo_size.v"

  /* send read/write requests to memory controller */
  framestore_request framestore_request (
    .rst(rst), 
    .clk(clk), 
    .fwd_rd_addr_empty(fwd_rd_addr_empty), 
    .fwd_rd_addr_en(fwd_rd_addr_en), 
    .fwd_rd_addr_valid(fwd_rd_addr_valid), 
    .fwd_rd_addr(fwd_rd_addr), 
    .fwd_wr_dta_full(fwd_wr_dta_full), 
    .fwd_wr_dta_almost_full(fwd_wr_dta_almost_full), 
    .fwd_rd_dta_almost_empty(fwd_rd_dta_almost_empty),
    .bwd_rd_addr_empty(bwd_rd_addr_empty), 
    .bwd_rd_addr_en(bwd_rd_addr_en), 
    .bwd_rd_addr_valid(bwd_rd_addr_valid), 
    .bwd_rd_addr(bwd_rd_addr), 
    .bwd_wr_dta_full(bwd_wr_dta_full), 
    .bwd_wr_dta_almost_full(bwd_wr_dta_almost_full), 
    .bwd_rd_dta_almost_empty(bwd_rd_dta_almost_empty),
    .recon_rd_empty(recon_rd_empty), 
    .recon_rd_almost_empty(recon_rd_almost_empty), 
    .recon_rd_en(recon_rd_en), 
    .recon_rd_valid(recon_rd_valid), 
    .recon_rd_addr(recon_rd_addr), 
    .recon_rd_dta(recon_rd_dta), 
    .recon_wr_almost_full(recon_wr_almost_full), 
    .disp_rd_addr_empty(disp_rd_addr_empty), 
    .disp_rd_addr_en(disp_rd_addr_en), 
    .disp_rd_addr_valid(disp_rd_addr_valid), 
    .disp_rd_addr(disp_rd_addr), 
    .disp_wr_dta_full(disp_wr_dta_full), 
    .disp_wr_dta_almost_full(disp_wr_dta_almost_full), 
    .disp_rd_dta_almost_empty(disp_rd_dta_almost_empty),
    .osd_rd_empty(osd_rd_empty), 
    .osd_rd_almost_empty(osd_rd_almost_empty), 
    .osd_rd_en(osd_rd_en), 
    .osd_rd_valid(osd_rd_valid), 
    .osd_rd_addr(osd_rd_addr), 
    .osd_rd_dta(osd_rd_dta), 
    .osd_wr_almost_full(osd_wr_almost_full), 
    .vbw_rd_empty(vbw_rd_empty),
    .vbw_rd_almost_empty(vbw_rd_almost_empty),
    .vbw_rd_en(vbw_rd_en),
    .vbw_rd_valid(vbw_rd_valid),
    .vbw_rd_dta(vbw_rd_dta),
    .vbw_wr_almost_full(vbw_wr_almost_full),
    .vbr_wr_full(vbr_wr_full),
    .vbr_wr_almost_full(vbr_wr_almost_full),
    .vbr_rd_almost_empty(vbr_rd_almost_empty),
    .vb_flush(vb_flush),
    .mem_req_wr_cmd(mem_req_wr_cmd),
    .mem_req_wr_addr(mem_req_wr_addr),
    .mem_req_wr_dta(mem_req_wr_dta),
    .mem_req_wr_en(mem_req_wr_en),
    .mem_req_wr_almost_full(mem_req_wr_almost_full),
    .tag_wr_dta(tag_wr_dta),
    .tag_wr_en(tag_wr_en),
    .tag_wr_almost_full(tag_wr_almost_full)
    );

  /* accept data read from memory controller */
  framestore_response framestore_response (
    .rst(rst), 
    .clk(clk), 
    .fwd_wr_dta_full(fwd_wr_dta_full), 
    .fwd_wr_dta_almost_full(fwd_wr_dta_almost_full),
    .fwd_wr_dta_en(fwd_wr_dta_en), 
    .fwd_wr_dta_ack(fwd_wr_dta_ack), 
    .fwd_wr_dta(fwd_wr_dta), 
    .bwd_wr_dta_full(bwd_wr_dta_full), 
    .bwd_wr_dta_almost_full(bwd_wr_dta_almost_full),
    .bwd_wr_dta_en(bwd_wr_dta_en), 
    .bwd_wr_dta_ack(bwd_wr_dta_ack), 
    .bwd_wr_dta(bwd_wr_dta), 
    .disp_wr_dta_full(disp_wr_dta_full), 
    .disp_wr_dta_almost_full(disp_wr_dta_almost_full),
    .disp_wr_dta_en(disp_wr_dta_en), 
    .disp_wr_dta_ack(disp_wr_dta_ack), 
    .disp_wr_dta(disp_wr_dta), 
    .vbr_wr_full(vbr_wr_full),
    .vbr_wr_en(vbr_wr_en),
    .vbr_wr_ack(vbr_wr_ack),
    .vbr_wr_dta(vbr_wr_dta),
    .vbr_wr_almost_full(vbr_wr_almost_full),
    .mem_res_rd_dta(mem_res_rd_dta),
    .mem_res_rd_en(mem_res_rd_en),
    .mem_res_rd_empty(mem_res_rd_empty),
    .mem_res_rd_valid(mem_res_rd_valid),
    .tag_rd_dta(tag_rd_dta),
    .tag_rd_en(tag_rd_en),
    .tag_rd_empty(tag_rd_empty),
    .tag_rd_valid(tag_rd_valid)
    );

  
  /* memory request fifo */
  fifo_dc 
    #(.addr_width(MEMREQ_DEPTH),
    .dta_width(9'd88),
    .prog_thresh(MEMREQ_THRESHOLD),  // threshold to make framestore_request stop writing before mem_request_fifo overflows
    .FIFO_XILINX(1))
    mem_request_fifo (
    .rst(rst), 
    .wr_clk(clk), 
    .din({mem_req_wr_cmd, mem_req_wr_addr, mem_req_wr_dta}), 
    .wr_en(mem_req_wr_en), 
    .full(mem_req_wr_full), 
    .wr_ack(), 
    .overflow(mem_req_wr_overflow), 
    .prog_full(mem_req_wr_almost_full), 
    .rd_clk(mem_clk), 
    .dout({mem_req_rd_cmd, mem_req_rd_addr, mem_req_rd_dta}), 
    .rd_en(mem_req_rd_en), 
    .empty(), 
    .valid(mem_req_rd_valid), 
    .underflow(), 
    .prog_empty()
    );

  /*
   * Each memory request includes a a tag.
   * Data read from memory is accompanied by the same tag as the memory read request.
   * This allows the frame store to determine who (motion compensation, display)
   * asked for this data, and who should get it.
   */

  /* tag fifo */
  fifo_sc 
    #(.addr_width(MEMTAG_DEPTH),  // tag fifo size must be bigger - because of memory controller latency - than mem_req and mem_resp fifo's together.
                       // maximum number of tags stored: size of memory request fifo + number of requests in process in memory controller + size of memory response fifo
    .dta_width(3),
    .prog_thresh(MEMTAG_THRESHOLD))   // threshold to make framestore_request stop writing before tag_fifo overflows
    mem_tag_fifo (
    .rst(rst), 
    .clk(clk), 
    .din(tag_wr_dta), 
    .wr_en(tag_wr_en), 
    .full(tag_wr_full), 
    .wr_ack(), 
    .overflow(tag_wr_overflow), 
    .prog_full(tag_wr_almost_full), 
    .dout(tag_rd_dta), 
    .rd_en(tag_rd_en), 
    .empty(tag_rd_empty), 
    .valid(tag_rd_valid), 
    .underflow(),
    .prog_empty()
    );

  /* memory response fifo */
  fifo_dc 
    #(.addr_width(MEMRESP_DEPTH),
    .dta_width(9'd64),
    .prog_thresh(MEMRESP_THRESHOLD),   // threshold to make mem_ctl stop writing before mem_response_fifo overflows
    .FIFO_XILINX(1))
    mem_response_fifo (
    .rst(rst), 
    .wr_clk(mem_clk), 
    .din(mem_res_wr_dta), 
    .wr_en(mem_res_wr_en), 
    .full(mem_res_wr_full), 
    .wr_ack(), 
    .overflow(mem_res_wr_overflow), 
    .prog_full(mem_res_wr_almost_full), 
    .rd_clk(clk), 
    .dout(mem_res_rd_dta), 
    .rd_en(mem_res_rd_en), 
    .empty(mem_res_rd_empty), 
    .valid(mem_res_rd_valid), 
    .underflow(),
    .prog_empty()
    );

`ifdef CHECK
  /*
   * diagnostic messages. 
   * Should fifo overflow occur, carefully consider changes in fifo_size.v
   */

  always @(posedge clk)
    if (mem_req_wr_overflow) 
      begin
        #0 $display("%m\t*** error: mem_req fifo overflow. **");
        $stop;
      end

  always @(posedge clk)
    if (tag_wr_overflow)     
      begin
        #0 $display("%m\t*** error: tag fifo overflow. ***");
        $stop;
      end

  always @(posedge clk)
    if (mem_res_wr_overflow) 
      begin
        #0 $display("%m\t*** error: mem_res.  fifo overflow. ***");
        $stop;
      end
`endif

endmodule
/* not truncated */
