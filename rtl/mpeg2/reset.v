/* 
 * reset.v
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
 * Generate reset signals.
 *   Accepts an asynchronous reset signal, and generates reset signals in the clk, mem_clk and dot_clk domains
 *   which are at least three clock cycles long. 
 *
 * Xilinx FIFO18/FIFO36 primitives:
 * "The reset signal must be high for at least three read clock and three write clock cycles."
 *
 */

`include "timescale.v"

module reset (clk, mem_clk, dot_clk, async_rst, watchdog_rst,
              clk_rst, mem_rst, dot_rst, hard_rst);

  input clk;                  /* decoder clock */
  input mem_clk;              /* memory clock */
  input dot_clk;              /* pixel clock */
  input async_rst;            /* global reset, asynchronous. */
  input watchdog_rst;         /* watchdog-generated reset, synchronous with clk. Goes low when watchdog timer expires. */
  output clk_rst;             /* global reset, synchronized to decoder clock. Goes low when "async_rst" or "watchdog_rst" goes low. */
  output mem_rst;             /* global reset, synchronized to memory clock. Goes low when "async_rst" or "watchdog_rst" goes low. */
  output dot_rst;             /* global reset, synchronized to pixel clock. Goes low when "async_rst" or "watchdog_rst" goes low. */
  output hard_rst;            /* "hard" reset signal. Goes low when "async_rst" input pin goes low. */

  /* synchronize async_rst and watchdog with clk */

  wire clk_rst_0;
  wire clk_watchdog_0;

  sync_reset clk_sreset_0 (
    .clk(clk), 
    .asyncrst(async_rst),
    .syncrst(clk_rst_0)
    );

  sync_reset clk_swatchdog_0 (
    .clk(clk), 
    .asyncrst(watchdog_rst),
    .syncrst(clk_watchdog_0)
    );

  /* combine async_rst and watchdog into a common reset signal */
  wire comm_rst = clk_rst_0 && clk_watchdog_0;

  /* synchronize common reset signal to the three system clocks */
  wire clk_rst_1;
  wire mem_rst_1;
  wire dot_rst_1;

  sync_reset clk_sreset_1 (
    .clk(clk), 
    .asyncrst(comm_rst),
    .syncrst(clk_rst_1)
    );

  sync_reset mem_sreset_1 (
    .clk(mem_clk), 
    .asyncrst(comm_rst),
    .syncrst(mem_rst_1) 
    );

  sync_reset dot_sreset_1 (
    .clk(dot_clk), 
    .asyncrst(comm_rst),
    .syncrst(dot_rst_1) 
    );

  /* 
   * combine all three resets - this produces a reset which is at least three clock cycles long in any clock domain
   */

  wire global_rst = clk_rst_1 && mem_rst_1 && dot_rst_1;

  /*
   * Now synchronize global reset back to the individual clocks
   */

  sync_reset clk_sreset_2 (
    .clk(clk), 
    .asyncrst(global_rst),
    .syncrst(clk_rst)
    );

  sync_reset mem_sreset_2 (
    .clk(mem_clk), 
    .asyncrst(global_rst),
    .syncrst(mem_rst) 
    );

  sync_reset dot_sreset_2 (
    .clk(dot_clk), 
    .asyncrst(global_rst),
    .syncrst(dot_rst) 
    );

  /*
   * "Hard" reset signal. Goes low when the "rst" input pin goes low.
   * Use two synchronizers so delay from async_rst to hard_rst is the same as the delay from async_rst to clk_rst.
   */

  wire hard_rst_1;

  sync_reset hard_sreset_1 (
    .clk(clk), 
    .asyncrst(clk_rst_0),
    .syncrst(hard_rst_1)
    );

  sync_reset hard_sreset_2 (
    .clk(clk), 
    .asyncrst(hard_rst_1),
    .syncrst(hard_rst)
    );

endmodule
/* not truncated */

