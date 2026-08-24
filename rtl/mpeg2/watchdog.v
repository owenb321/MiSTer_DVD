/* 
 * watchdog.v
 * 
 * Copyright (c) 2009 Koen De Vleeschauwer. 
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
 * watchdog.v - watchdog timer. Generate reset if decoder not active during x seconds.
 *
 * The decoder is reset if the variable length decoding is inactive for 
 * 256*256*16*(repeat_frame+1)*(watchdog_interval+1) clock cycles.
 *
 * The watchdog timer begins to run if the decoder asserts busy.
 *
 * The watchdog timer is reset if
 * - the 'busy' signal is low OR
 * - the source_select is non-zero (software output frame override) OR
 * - repeat_frame is 31 ("freeze frame") OR
 * - watchdog_interval is 255 (watchdog timer manually switched off).
 *
 * multiplying the watchdog timeout by (repeat_frame+1) causes the watchdog
 * timeout to increase if the video is slowed down.
 *
 * The watchdog can't use the "sync_rst" global reset, because the "sync_rst" signal
 * goes low when the watchdog timer expires. 
 * If the watchdog were to use the "sync_rst" global reset, feedback might occur.
 * The watchdog uses the "hard_rst" global reset, which depends only on the
 * rst input pin.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

`undef CHECK
`ifdef __IVERILOG__
`define CHECK 1
`endif

module watchdog(
  clk, 
  hard_rst,
  source_select, 
  repeat_frame,
  busy,
  watchdog_rst,
  watchdog_interval,
  watchdog_interval_wr,
  watchdog_status_rd,
  watchdog_status
  );

  input              clk;                          // clock
  input              hard_rst;                     // "hard reset" input

  input         [2:0]source_select;                // select video out source
  input         [4:0]repeat_frame;
  input              busy;                         // high if decoder does not accept input

  output reg         watchdog_rst;                 // watchdog-generated reset signal. normally high; low during one clock cycle when watchdog timer expires.
  output reg         watchdog_status;              // asserted if watchdog expired

  input              watchdog_interval_wr;         // register file: asserted when the watchdog interval is written.
  input         [7:0]watchdog_interval;            // register file: value of the watchdog interval. 255 = never expire; 0 = expire immediate.
  input              watchdog_status_rd;           // register file: asserted if watchdog_status is read.
  wire               watchdog_expire_immediate = watchdog_interval_wr && (watchdog_interval == 8'd0);   // asserted if 8'd0 is written to watchdog_interval

  reg           [4:0]repeat_cnt;
  reg                decoder_active;
  reg           [7:0]watchdog_cnt;

  reg          [15:0]timer_lsb;                   // watchdog timer, lower 16 bits
  reg          [15:0]timer_msb;                   // watchdog timer, upper 16 bits

  reg          [15:0]holdoff_lsb;                 // holdoff timer, lower 16 bits
  reg          [15:0]holdoff_msb;                 // holdoff timer, upper 16 bits

  /*
   * FSM states
   */

  parameter [2:0]
    STATE_INIT     = 3'h0,
    STATE_HOLDOFF  = 3'h1,
    STATE_CLEAR    = 3'h2,
    STATE_TIMER    = 3'h3,
    STATE_EXPIRE   = 3'h4;

  reg          [2:0]state;
  reg          [2:0]next;

  /* next state logic */
  always @*
    case (state)
      STATE_INIT:              next = STATE_HOLDOFF;

      STATE_HOLDOFF:           if (watchdog_expire_immediate) next = STATE_EXPIRE;
                               else if (holdoff_msb[10]) next = STATE_CLEAR;
                               else next = STATE_HOLDOFF;

      STATE_CLEAR:             if (watchdog_expire_immediate) next = STATE_EXPIRE;
                               else if (decoder_active) next = STATE_CLEAR;
                               else next = STATE_TIMER;

      STATE_TIMER:             if (watchdog_expire_immediate) next = STATE_EXPIRE;
                               else if (decoder_active) next = STATE_CLEAR;
                               else if (watchdog_interval_wr) next = STATE_CLEAR; // reset watchdog timer if new watchdog_interval is written
                               else if (timer_msb[2]) next = STATE_EXPIRE;
                               else next = STATE_TIMER;

      STATE_EXPIRE:            next = STATE_INIT;

      default                  next = STATE_INIT;
    endcase

  /* state */
  always @(posedge clk)
    if(~hard_rst) state <= STATE_INIT;
    else state <= next;

  /*
   * Definition of decoder active:
   * - ~busy: decoder accepts data
   * - source_select != 3'd0: output frame override OR
   * - repeat_frame == 4'd31: output frame picture freeze OR
   * - watchdog_interval == 8'd0: watchdog timer expires and is switched off. (one-shot mode)
   * - watchdog_interval == 8'd255: watchdog timer switched off.
   *
   */

  always @(posedge clk)
    if (~hard_rst) decoder_active <= 1'b0;
    else decoder_active <= ~busy || (source_select != 3'd0) || (repeat_frame == 5'd31) || (watchdog_interval == 8'd0) || (watchdog_interval == 8'd255);

  /*
   * Watchdog reset and status outputs. 
   * Note the scaling factor of the watchdog timer can be changed. 
   * E.g. using timer_msb[3] instead of timer_msb[2] in will double the watchdog timeout, 
   * while using timer_msb[1] will halve the watchdog timeout.
   * The current tap (timer_msb[2]) ought to be OK for clocks in the 25MHz .. 100Mhz range. 
   * If watchdog_interval is 127 (default value) and repeat_frame is 0 (default value), 
   * a tap at bit 2  corresponds to a watchdog timer interval of 2**25, 
   * or 447 ms @ 75 MHz clock.
   */

  initial                 // Power-on value
    watchdog_rst <= 1'b1; // This synthesizes; see Xilinx AR# 29112

  always @(posedge clk)
    if (~hard_rst) watchdog_rst <= 1'b1;
    else if (state == STATE_EXPIRE) watchdog_rst <= 1'b0;
    else watchdog_rst <= 1'b1;

  always @(posedge clk)
    if (~hard_rst) watchdog_status <= 1'b0;
    else if (state == STATE_EXPIRE) watchdog_status <= 1'b1;  // set when watchdog timer expires
    else if (watchdog_status_rd) watchdog_status <= 1'b0; // clear when status register read access
    else watchdog_status <= watchdog_status;

  /*
   * Watchdog timer.
   */

  always @(posedge clk)
    if (~hard_rst) timer_lsb <= 16'b0;
    else if (state == STATE_CLEAR) timer_lsb <= 16'b0;
    else if ((state == STATE_TIMER) && (repeat_cnt == 5'b0) && (watchdog_cnt == 8'b0)) timer_lsb <= timer_lsb + 16'd1;
    else timer_lsb <= timer_lsb;

  always @(posedge clk)
    if (~hard_rst) timer_msb <= 16'b0;
    else if (state == STATE_CLEAR) timer_msb <= 16'b0;
    else if ((state == STATE_TIMER) && (repeat_cnt == 5'b0) && (watchdog_cnt == 8'b0) && (timer_lsb == 16'hffff)) timer_msb <= timer_msb + 16'd1;
    else timer_msb <= timer_msb;

  /*
   * Holdoff timer
   * Timer uses two 16-bit words. Tap at bit 10 of the second word (holdoff_msb[10]).
   * This corresponds to a holdoff timer of 2**(10+16) = 2**26 clk cycles,
   * or 894 ms @ 75 MHz clock.
   */

  always @(posedge clk)
    if (~hard_rst) holdoff_lsb <= 16'b0;
    else if (state == STATE_INIT) holdoff_lsb <= 16'b0;
    else if (state == STATE_HOLDOFF) holdoff_lsb <= holdoff_lsb + 16'b1;
    else holdoff_lsb <= holdoff_lsb;

  always @(posedge clk)
    if (~hard_rst) holdoff_msb <= 16'b0;
    else if (state == STATE_INIT) holdoff_msb <= 16'b0;
    else if ((state == STATE_HOLDOFF) && (holdoff_lsb == 16'hffff)) holdoff_msb <= holdoff_msb + 16'b1;
    else holdoff_msb <= holdoff_msb;

  /*
   * Counters. Divide clock by (repeat_frame + 1).(watchdog_interval + 1)
   * This results in the watchdog timeout being multiplied by (repeat_frame + 1) 
   * if the video images are shown (repeat_frame + 1) times.
   */

  always @(posedge clk)
    if (~hard_rst) repeat_cnt <= 5'b0;
    else if (repeat_cnt == 5'b0) repeat_cnt <= repeat_frame;
    else repeat_cnt <= repeat_cnt - 5'b1;

  always @(posedge clk)
    if (~hard_rst) watchdog_cnt <= 8'b0;
    else if ((repeat_cnt == 5'b0) && (watchdog_cnt == 8'b0)) watchdog_cnt <= watchdog_interval;
    else if (repeat_cnt == 5'b0) watchdog_cnt <= watchdog_cnt - 8'b1;
    else watchdog_cnt <= watchdog_cnt;

`ifdef DEBUG

  always @(posedge clk)
    case (state)
      STATE_INIT:                               #0 $display("%m         STATE_INIT");
      STATE_HOLDOFF:                            #0 $display("%m         STATE_HOLDOFF");
      STATE_CLEAR:                              #0 $display("%m         STATE_CLEAR");
      STATE_TIMER:                              #0 $display("%m         STATE_TIMER");
      STATE_EXPIRE:                             #0 $display("%m         STATE_EXPIRE");
      default                                   #0 $display("%m         *** Error: unknown state %d", state);
    endcase

  always @(posedge clk)
    begin 
      $strobe("%m\tdecoder_active: %d repeat_cnt: %3d watchdog_cnt: %3d timer: %3d watchdog_rst: %d watchdog_status: %d",
                   decoder_active, repeat_cnt, watchdog_cnt, timer, watchdog_rst, watchdog_status);
    end 

`endif

endmodule
/* not truncated */
