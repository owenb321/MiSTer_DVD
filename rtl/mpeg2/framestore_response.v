/* 
 * framestore_response.v
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
 * Frame Store Response. Read response from memory controller.
 *
 * Receives data read from the memory controller; 
 * passes data read on to motion compensation or display.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

`undef CHECK
//`define CHECK 1

`ifdef __IVERILOG__
`define CHECK 1
`endif

//`define SIMULATION_ONLY
`ifdef __IVERILOG__
`define SIMULATION_ONLY 1
`endif

module framestore_response(rst, clk, 
                  fwd_wr_dta_full, fwd_wr_dta_en, fwd_wr_dta_ack, fwd_wr_dta, fwd_wr_dta_almost_full,
                  bwd_wr_dta_full, bwd_wr_dta_en, bwd_wr_dta_ack, bwd_wr_dta, bwd_wr_dta_almost_full,
                  disp_wr_dta_full, disp_wr_dta_en, disp_wr_dta_ack, disp_wr_dta, disp_wr_dta_almost_full,
                  vbr_wr_full, vbr_wr_en, vbr_wr_ack, vbr_wr_dta, vbr_wr_almost_full, 
                  mem_res_rd_dta, mem_res_rd_en, mem_res_rd_empty, mem_res_rd_valid, 
                  tag_rd_dta, tag_rd_empty, tag_rd_en, tag_rd_valid
                  );

  input            rst;
  input            clk;
  /* motion compensation: reading forward reference frame */
  input             fwd_wr_dta_full;
  input             fwd_wr_dta_almost_full;
  output reg        fwd_wr_dta_en;
  input             fwd_wr_dta_ack;
  output reg     [63:0]fwd_wr_dta;
  /* motion compensation: reading backward reference frame */
  input             bwd_wr_dta_full;
  input             bwd_wr_dta_almost_full;
  output reg        bwd_wr_dta_en;
  input             bwd_wr_dta_ack;
  output reg  [63:0]bwd_wr_dta;
  /* display: reading reconstructed frame */
  input             disp_wr_dta_full;
  input             disp_wr_dta_almost_full;
  output reg        disp_wr_dta_en;
  input             disp_wr_dta_ack;
  output reg  [63:0]disp_wr_dta;
  /* video buffer: reading from circular buffer */
  input             vbr_wr_full;
  input             vbr_wr_almost_full;
  output reg        vbr_wr_en;
  input             vbr_wr_ack;
  output reg  [63:0]vbr_wr_dta;

  /* memory response fifo */
  input       [63:0]mem_res_rd_dta;
  output reg        mem_res_rd_en;
  input             mem_res_rd_empty;
  input             mem_res_rd_valid;

  /* tag fifo */
  input        [2:0]tag_rd_dta;
  input             tag_rd_empty;
  output reg        tag_rd_en;
  input             tag_rd_valid;

`include "mem_codes.v"

  parameter [2:0] 
    STATE_INIT        = 4'h0,      
    STATE_FLUSH       = 4'h1,
    STATE_WAIT        = 4'h2,
    STATE_READ        = 4'h3,      
    STATE_WRITE       = 4'h4;      

  reg         [2:0]state;
  reg         [2:0]next;

  reg        [15:0]flush_counter;

  always @(posedge clk)
    if (~rst) flush_counter <= 0;
    else if (state == STATE_FLUSH) flush_counter <= flush_counter + 16'd1;
    else flush_counter <= flush_counter;

  wire             fifos_not_ready = fwd_wr_dta_full || bwd_wr_dta_full || disp_wr_dta_full || vbr_wr_full || tag_rd_empty || mem_res_rd_empty;
  wire             fifos_ready = ~fifos_not_ready;

  /* next state logic */
  always @*
    case (state)
`ifdef SIMULATION_ONLY
      STATE_INIT:         next = STATE_WAIT;
`else
      STATE_INIT:         next = STATE_FLUSH;
`endif

      STATE_FLUSH:        if (flush_counter == 16'hffff) next = STATE_WAIT; // Flush any data in the memory response fifo's.
                          else next = STATE_FLUSH;

      STATE_WAIT:         if (fifos_not_ready) next = STATE_WAIT;  // wait until all fifos available
                          else next = STATE_READ;

      STATE_READ:         next = STATE_WRITE;

      STATE_WRITE:        next = STATE_WAIT;

      default             next = STATE_WAIT;

    endcase

  /* state */
  always @(posedge clk)
    if(~rst) state <= STATE_INIT;
    else state <= next;

  /* 
   * read from memory response and tag fifos
   */

  always @(posedge clk)
    if (~rst) mem_res_rd_en <= 1'b0;
    else if (state == STATE_FLUSH) mem_res_rd_en <= 1'b1;
    else if (state == STATE_READ) mem_res_rd_en <= fifos_ready;
    else mem_res_rd_en <= 1'b0;

  always @(posedge clk)
    if (~rst) tag_rd_en <= 1'b0;
    else if (state == STATE_READ) tag_rd_en <= fifos_ready;
    else tag_rd_en <= 1'b0;

  /*
   * second stage: if successful read from memory response fifo, write memory response data to fifo corresponding to tag (fwd, bwd, disp or vbr).
   */

  always @(posedge clk)
    if (~rst) fwd_wr_dta_en <= 1'b0;
    else fwd_wr_dta_en <= (tag_rd_dta == TAG_FWD) && tag_rd_valid;

  always @(posedge clk)
    if (~rst) fwd_wr_dta <= 64'b0;
    else if (mem_res_rd_valid) fwd_wr_dta <= mem_res_rd_dta;
    else fwd_wr_dta <= fwd_wr_dta;

  always @(posedge clk)
    if (~rst) bwd_wr_dta_en <= 1'b0;
    else bwd_wr_dta_en <= (tag_rd_dta == TAG_BWD) && tag_rd_valid;

  always @(posedge clk)
    if (~rst) bwd_wr_dta <= 64'b0;
    else if (mem_res_rd_valid) bwd_wr_dta <= mem_res_rd_dta;
    else bwd_wr_dta <= bwd_wr_dta;

  always @(posedge clk)
    if (~rst) disp_wr_dta_en <= 1'b0;
    else disp_wr_dta_en <= (tag_rd_dta == TAG_DISP) && tag_rd_valid;

  always @(posedge clk)
    if (~rst) disp_wr_dta <= 64'b0;
    else if (mem_res_rd_valid) disp_wr_dta <= mem_res_rd_dta;
    else disp_wr_dta <= disp_wr_dta;

  always @(posedge clk)
    if (~rst) vbr_wr_en <= 1'b0;
    else vbr_wr_en <= (tag_rd_dta == TAG_VBUF) && tag_rd_valid;

  always @(posedge clk)
    if (~rst) vbr_wr_dta <= 64'b0;
    else if (mem_res_rd_valid) vbr_wr_dta <= mem_res_rd_dta;
    else vbr_wr_dta <= vbr_wr_dta;

`ifdef DEBUG

  always @(posedge clk)
    case (state)
      STATE_INIT:                               #0 $display("%m         STATE_INIT");
      STATE_WAIT:                               #0 $display("%m         STATE_WAIT");
      STATE_FLUSH:                              #0 $display("%m         STATE_FLUSH");
      STATE_READ:                               #0 $display("%m         STATE_READ");
      STATE_WRITE:                              #0 $display("%m         STATE_WRITE");
      default                                   #0 $display("%m         *** Error: unknown state %d", state);
    endcase

  always @(posedge clk)
    $strobe("%m\tmem_res_rd_dta: %h mem_res_rd_valid: %h tag_rd_dta: %h tag_rd_valid: %h fifos_not_ready: %h mem_res_rd_en: %h", mem_res_rd_dta, mem_res_rd_valid, tag_rd_dta, tag_rd_valid, fifos_not_ready, mem_res_rd_en);

  always @(posedge clk)
    begin
      $strobe("%m\tfwd_wr_dta: %h fwd_wr_dta_en: %h", fwd_wr_dta, fwd_wr_dta_en);
      $strobe("%m\tbwd_wr_dta: %h bwd_wr_dta_en: %h", bwd_wr_dta, bwd_wr_dta_en);
      $strobe("%m\tdisp_wr_dta: %h disp_wr_dta_en: %h", disp_wr_dta, disp_wr_dta_en);
      $strobe("%m\tvbr_wr_dta: %h vbr_wr_en: %h", vbr_wr_dta, vbr_wr_en);
    end

  always @(posedge clk)
    if (tag_rd_valid)
    case (tag_rd_dta)
      TAG_FWD:  #0 $display ("%m\ttag_rd_dta: fwd");
      TAG_BWD:  #0 $display ("%m\ttag_rd_dta: bwd");
      TAG_DISP: #0 $display ("%m\ttag_rd_dta: disp");
      TAG_VBUF: #0 $display ("%m\ttag_rd_dta: vbuf");
      default:  #0 $display ("%m\t*** error: unknown tag %d ***", tag_rd_dta);
    endcase
 
`endif

`ifdef CHECK
  always @(posedge clk)
    if (fwd_wr_dta_full) #0 $display ("%m\t*** warning: memory stall possible: fwd_wr_dta_full ***");

  always @(posedge clk)
    if (bwd_wr_dta_full) #0 $display ("%m\t*** warning: memory stall possible: bwd_wr_dta_full ***");

  always @(posedge clk)
    if (disp_wr_dta_full) #0 $display ("%m\t*** warning: memory stall possible: disp_wr_dta_full ***");

  always @(posedge clk)
    if (vbr_wr_full) #0 $display ("%m\t*** warning: memory stall possible: vbr_wr_full ***");

  /*
   * Should never happen, but doesn't hurt to check.
   */

  always @(posedge clk)
    if ((state == STATE_READ) && ((tag_rd_valid && ~mem_res_rd_valid) || (mem_res_rd_valid && ~tag_rd_valid)))
      begin
        #0 $display("%m\t*** error: tag and mem_res fifo unsynchronized tag_rd_valid: %d mem_res_rd_valid: %d ***", tag_rd_valid, mem_res_rd_valid);
        $stop;
      end

  always @(posedge clk)
    if (tag_rd_valid && (tag_rd_dta != TAG_FWD) && (tag_rd_dta != TAG_BWD) && (tag_rd_dta != TAG_DISP) && (tag_rd_dta != TAG_VBUF)) 
      begin
        #0 $display("%m\t*** error: unknown tag %d ***", tag_rd_dta);
        $stop;
      end

`endif
endmodule
/* not truncated */
