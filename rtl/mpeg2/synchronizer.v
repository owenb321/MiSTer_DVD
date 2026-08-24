/* 
 * synchronizer.v
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
 * reset synchronizer.
 * input: asynchronous reset asyncrst_n, active low.
 * output: synchronous reset syncrst_n, active low, with a width of four clocks.
 *
 * After http://www.sunburst-design.com/papers/CummingsSNUG2002SJ_Resets.pdf , par. 6.0
 */

`undef DEBUG
//`define DEBUG 1

`include "timescale.v"

module sync_reset (clk, asyncrst, syncrst); 

  input  clk, asyncrst; 
  output reg syncrst; 

  reg    [3:0]rff1; 

  always @(posedge clk or negedge asyncrst) 
    if (!asyncrst) {syncrst, rff1} <= 5'b0; 
    else           {syncrst, rff1} <= {rff1, 1'b1}; 

endmodule 

/*
 * register synchronizer.
 * input: asynchronous register asyncreg
 * output: syncreg, register synchronized to clk
 * parameter 'width' determines register width.
 */

module sync_reg (clk, rst, asyncreg, syncreg); 

parameter width=8;

  input                clk;
  input                rst;  // synchronous with clk
  input     [width-1:0]asyncreg;
  output reg[width-1:0]syncreg;


  reg   [width-1:0]rff1;

  always @(posedge clk or negedge rst)
    if (!rst) {syncreg, rff1} <= {(2*width){1'b0}};
    else      {syncreg, rff1} <= {rff1, asyncreg};

`ifdef DEBUG
  always @(posedge clk)
    $strobe("%m\trst: %h asyncreg : %h syncreg: %h", rst, asyncreg, syncreg);
`endif

endmodule 
/* not truncated */
