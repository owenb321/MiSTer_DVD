/* 
 * vbuf.v
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
 * vbuf - Video Buffer
 * Decoder input buffer. 
 * vbuf_write writes incoming mpeg2 stream to a circular buffer in memory.
 * getbits_fifo reads the incoming mpeg2 stream from a circular buffer in memory.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

/*
 Converter from byte-parallel to 64-bits parallel 
 */

module vbuf_write (
  clk, clk_en, rst, 
  vid_in, vid_in_wr_en,
  vid_out, vid_out_wr_en
  );

  input              clk;
  input              clk_en;
  input              rst;                      // synchronous active low reset

  input         [7:0]vid_in;
  input              vid_in_wr_en;

  output reg   [63:0]vid_out;
  output reg         vid_out_wr_en;

  reg           [7:0]loop;

  always @(posedge clk)
    if (~rst) vid_out <= 64'b0;
    else if (clk_en && vid_in_wr_en) vid_out <= {vid_out[55:0], vid_in};
    else vid_out <= vid_out;

  always @(posedge clk)
    if (~rst) loop <= 8'b0;
    else if (clk_en && vid_in_wr_en) loop <= {loop[6:0], &(~loop[6:0])};
    else loop <= loop;

  always @(posedge clk)
    if (~rst) vid_out_wr_en <= 1'b0;
    else if (clk_en && vid_in_wr_en) vid_out_wr_en <= loop[6];
    else if (clk_en) vid_out_wr_en <= 1'b0;
    else vid_out_wr_en <= vid_out_wr_en;

`ifdef DEBUG                        
  always @(posedge clk)
    $strobe("%m\tvid_in: %h vid_in_wr_en: %d vid_out: %h vid_out_wr_en: %d loop: %8b",
                 vid_in, vid_in_wr_en, vid_out, vid_out_wr_en, loop);
`endif

endmodule
/* not truncated */
