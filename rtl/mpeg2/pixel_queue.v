/* 
 * pixel_queue.v
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
 * pixel_queue - Pixel output queue
 */

`include "timescale.v"

module pixel_queue(
  clk_in, clk_in_en, 
  rst, 
  y_in, u_in, v_in, osd_in, position_in, pixel_wr_en, pixel_wr_almost_full, pixel_wr_full, pixel_wr_overflow,
  clk_out, clk_out_en,
  y_out, u_out, v_out, osd_out, position_out, pixel_rd_en, pixel_rd_empty, pixel_rd_valid, pixel_rd_underflow
  );

  input              clk_in;                   // write clock
  input              clk_in_en;                // write clock enable

  input              rst;                      // synchronous active low reset

  input         [7:0]y_in;
  input         [7:0]u_in;
  input         [7:0]v_in;
  input         [7:0]osd_in;
  input         [2:0]position_in;
  input              pixel_wr_en;
  output             pixel_wr_almost_full;
  output             pixel_wr_full;
  output             pixel_wr_overflow;

  input              clk_out;                  // read clock
  input              clk_out_en;               // read clock enable

  output        [7:0]y_out;
  output        [7:0]u_out;
  output        [7:0]v_out;
  output        [7:0]osd_out;
  output        [2:0]position_out;
  input              pixel_rd_en;
  output             pixel_rd_empty;
  output             pixel_rd_valid;
  output             pixel_rd_underflow;

`include "fifo_size.v"

  /* DVD-FORK FIX (CRT 480i / clk_out_en != 1, 2026-07-05): the FIFO's `valid` and
   * `underflow` are 1-cycle pulses registered on the RAW rd_clk (xilinx_fifo_dc.v:
   * `valid <= do_read` every rd_clk edge). The pop itself is correctly gated
   * (`rd_en && clk_out_en`), but the resulting pulse occupies exactly the cycle
   * AFTER the enabled edge — which, with the 13.5 MHz CRT-mode pixel CE, is always
   * a DISABLED cycle. The CE'd consumer (mixer) then never samples valid=1: it
   * never latches a pixel or position code, its FSM hunts in STATE_INIT forever,
   * and the screen shows black while the pipeline drains normally (the exact
   * first-CRT-build HW symptom: audio + overlay fine, video black). Latent for
   * every prior mode because clk_out_en was constant 1.
   * Fix: stretch the pulses across DISABLED cycles only — set on a disabled edge,
   * cleared on any enabled edge (consumption point). When clk_out_en==1 the
   * stretch registers can never set, so all legacy modes are bit-identical.
   * dout is safe to pair with the stretched valid: it only changes on pops, and
   * pops only happen on enabled edges. */
  wire fifo_rd_valid_raw;
  wire fifo_rd_underflow_raw;
  reg  rd_valid_ext, rd_underflow_ext;
  always @(posedge clk_out)
    if (~rst) begin
      rd_valid_ext     <= 1'b0;
      rd_underflow_ext <= 1'b0;
    end else if (clk_out_en) begin
      rd_valid_ext     <= 1'b0;
      rd_underflow_ext <= 1'b0;
    end else begin
      rd_valid_ext     <= rd_valid_ext     | fifo_rd_valid_raw;
      rd_underflow_ext <= rd_underflow_ext | fifo_rd_underflow_raw;
    end
  assign pixel_rd_valid     = fifo_rd_valid_raw     | rd_valid_ext;
  assign pixel_rd_underflow = fifo_rd_underflow_raw | rd_underflow_ext;

  fifo_dc
    #(.addr_width(PIXEL_DEPTH),
    .dta_width(9'd35),
    .prog_thresh(PIXEL_THRESHOLD),
    .FIFO_XILINX(1))
    pixel_fifo (
    .rst(rst),
    .wr_clk(clk_in),
    .din({y_in, u_in, v_in, osd_in, position_in}),
    .wr_en(pixel_wr_en && clk_in_en),
    .wr_ack(),
    .full(pixel_wr_full),
    .overflow(pixel_wr_overflow),
    .rd_clk(clk_out),
    .dout({y_out, u_out, v_out, osd_out, position_out}),
    .rd_en(pixel_rd_en && clk_out_en),
    .valid(fifo_rd_valid_raw),
    .empty(pixel_rd_empty),
    .underflow(fifo_rd_underflow_raw),
    .prog_full(pixel_wr_almost_full),
    .prog_empty()
    );

endmodule
/* not truncated */
