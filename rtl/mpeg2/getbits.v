/* 
 * getbits.v
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
 * getbits - read bitfields from incoming video stream
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

module getbits_fifo (clk, clk_en, rst, 
   vid_in, vid_in_rd_en, vid_in_rd_valid,
   advance, align,
   getbits, signbit, getbits_valid,
   wait_state, rld_wr_almost_full, mvec_wr_almost_full, motcomp_busy, vld_en);

  input            clk;                      // clock
  input            clk_en;                   // clock enable
  input            rst;                      // synchronous active low reset

  input      [63:0]vid_in;
  output reg       vid_in_rd_en;
  input            vid_in_rd_valid;

  input       [4:0]advance;                  // number of bits to advance the bitstream (advance <= 24). Enabled when getbits_valid asserted.
  input            align;                    // byte-align getbits and move forward one byte. Enabled when getbits_valid asserted.
  input            wait_state;               // asserted if vld needs to be frozen next clock cycle.
  input            rld_wr_almost_full;       // asserted if rld fifo almost full
  input            mvec_wr_almost_full;      // asserted if motion vector fifo almost full
  input            motcomp_busy;             // asserted if motcomp fifo almost full

  output reg [23:0]getbits;                  // bit-aligned elementary stream data. 
  output reg       signbit;                  // In table B-14 and B-15, the rightmost bit of the variable length code is the sign bit.
                                             // When decoding DCT variable length codes, signbit contains the sign bit of the
                                             // previous clock's coefficient.

  output reg       getbits_valid;            // getbits_valid is asserted when getbits is valid.
  output reg       vld_en;                   // vld clock enable

  reg       [128:0]dta;                      // 129 bits. No typo.
  reg       [103:0]dummy;                    // dummy variable, not used.
  reg         [7:0]cursor;
  reg       [128:0]next_dta;
  reg         [7:0]next_cursor;
  reg        [23:0]next_getbits;
  reg              next_signbit;

  parameter 
    STATE_INIT      = 1'b0,
    STATE_READY     = 1'b1;

  reg               state;
  reg               next;

  /* next state logic */
  always @*
    case (state)
      STATE_INIT:  if (vid_in_rd_valid && (next_cursor < 8'd64)) next = STATE_READY;
                   else next = STATE_INIT;

      STATE_READY: if (next_cursor > 63) next = STATE_INIT;
                   else next = STATE_READY;

      default      next = STATE_INIT;
    endcase

  /* state */
  always @(posedge clk)
    if(~rst) state <= STATE_INIT;
    else if (clk_en) state <= next;
    else state <= next;

  /* registers */

  always @*
    if ((state == STATE_INIT) && vid_in_rd_valid) next_dta = {dta[64:0], vid_in};
    else next_dta = dta;

  wire [7:0]cursor_aligned = {cursor[7:3], 3'b0};
  wire [7:0]advance_ext = {3'b0, advance};

  always @*
    case (state)
      STATE_INIT:  if (vid_in_rd_valid) next_cursor = cursor - 8'd64;
                   else next_cursor = cursor;
      
      STATE_READY: if (align) next_cursor = cursor_aligned + 8'd8;
                   else next_cursor = cursor + advance_ext;

      default      next_cursor = cursor;
    endcase

  always @*
    {next_signbit, next_getbits, dummy} = next_dta << next_cursor;

  always @(posedge clk)
    if (~rst) dta <= 129'b0;
    else if (clk_en) dta <= next_dta;
    else dta <= dta;

  always @(posedge clk)
    if (~rst) cursor <= 8'd128;
    else if (clk_en) cursor <= next_cursor;
    else cursor <= cursor;

  always @(posedge clk)
    if (~rst) signbit <= 1'b0;
    else if (clk_en) signbit <= next_signbit;
    else signbit <= signbit;

  always @(posedge clk)
    if (~rst) getbits <= 24'b0;
    else if (clk_en) getbits <= next_getbits;
    else getbits <= getbits;

  always @(posedge clk)
    if (~rst) getbits_valid <= 1'b0;
    else if (clk_en) getbits_valid <= (next == STATE_READY);
    else getbits_valid <= getbits_valid;

  always @(posedge clk)
    if (~rst) vid_in_rd_en <= 1'b0;
    else if (clk_en) vid_in_rd_en <= (next == STATE_INIT) && ~vid_in_rd_en && ~vid_in_rd_valid;
    else vid_in_rd_en <= vid_in_rd_en;

  /* vld clock enable */

  /*
   * variable length decoding and fifo take turns;
   * First vld determines how much to move forward in the bitstream;
   * next clock, getbits moves that amount forward in the stream while vld waits;
   * then vld analyzes the new position in the bitstream while getbits waits,
   * and so on.
   */

  always @(posedge clk)
    if (~rst) vld_en <= 1'b1;
    // enable vld when getbits, rld, and motcomp ready, and not a wait state
    else if (clk_en && vld_en) vld_en <= (next == STATE_READY) && ~wait_state && ~rld_wr_almost_full && ~mvec_wr_almost_full && ~motcomp_busy;
    else if (clk_en) vld_en <= (next == STATE_READY) && ~rld_wr_almost_full && ~mvec_wr_almost_full && ~motcomp_busy;                
    else vld_en <= vld_en;

  /* Debugging */
`ifdef DEBUG
   always @(posedge clk)
     if (clk_en)
       $strobe("%m\tvid_in: %h vid_in_rd_en: %d vid_in_rd_valid: %d advance: %d align: %d state: %d dta: %h cursor: %h signbit: %d getbits: %h getbits_valid: %d ",
                    vid_in, vid_in_rd_en, vid_in_rd_valid, advance, align, state, dta, cursor, signbit, getbits, getbits_valid);
`endif

endmodule
/* not truncated */
