/* 
 * xilinx_fifo216.v
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
 * FIFO216
 * Connect three 72-bit wide FIFO36_72 in parallel to create one 216-bit wide fifo.
 */

`include "timescale.v"

module FIFO216 (ALMOSTEMPTY, ALMOSTFULL, DO, EMPTY, FULL, RDERR, WRERR, DI, RDCLK, RDEN, RST, WRCLK, WREN);

  parameter [8:0]ALMOST_FULL_OFFSET=9'h080;
  parameter [8:0]ALMOST_EMPTY_OFFSET=9'h080;
  parameter DO_REG=1;
  parameter EN_SYN="FALSE";

  output ALMOSTEMPTY;
  output ALMOSTFULL;
  output [215:0]DO;
  output EMPTY;
  output FULL;
  output reg RDERR;
  output reg WRERR;
  input [215:0]DI;
  input RDCLK;
  input RDEN;
  input RST;
  input WRCLK;
  input WREN;

  wire fifo_wren;
  wire fifo_rden;

  wire [63:0]fifo1_di;
  wire [7:0]fifo1_dip;
  wire [63:0]fifo1_do;
  wire [7:0]fifo1_dop;
  wire fifo1_empty;
  wire fifo1_full;
  wire fifo1_almost_empty;
  wire fifo1_almost_full;
  wire fifo1_rderr;
  wire fifo1_wrerr;

  wire [63:0]fifo2_di;
  wire [7:0]fifo2_dip;
  wire [63:0]fifo2_do;
  wire [7:0]fifo2_dop;
  wire fifo2_empty;
  wire fifo2_full;
  wire fifo2_almost_empty;
  wire fifo2_almost_full;
  wire fifo2_rderr;
  wire fifo2_wrerr;

  wire [63:0]fifo3_di;
  wire [7:0]fifo3_dip;
  wire [63:0]fifo3_do;
  wire [7:0]fifo3_dop;
  wire fifo3_empty;
  wire fifo3_full;
  wire fifo3_almost_empty;
  wire fifo3_almost_full;
  wire fifo3_rderr;
  wire fifo3_wrerr;

  assign DO = {fifo3_dop, fifo3_do, fifo2_dop, fifo2_do, fifo1_dop, fifo1_do};
  assign {fifo3_dip, fifo3_di, fifo2_dip, fifo2_di, fifo1_dip, fifo1_di} = DI;

  assign EMPTY = fifo1_empty || fifo2_empty || fifo3_empty;
  assign FULL = fifo1_full || fifo2_full || fifo3_full;
  assign ALMOSTEMPTY = fifo1_almost_empty || fifo2_almost_empty || fifo3_almost_empty;
  assign ALMOSTFULL = fifo1_almost_full || fifo2_almost_full || fifo3_almost_full;

  always @(posedge RDCLK)
    if (RST) RDERR <= 1'b0;
    else RDERR <= RDEN && EMPTY;

  always @(posedge WRCLK)
    if (RST) WRERR <= 1'b0;
    else WRERR <= WREN && FULL;

  assign fifo_wren = WREN && ~FULL;
  assign fifo_rden = RDEN && ~EMPTY;

  // FIFO36_72: 72x36k Synchronous/Asynchronous BlockRAM FIFO /w ECC
  //             Virtex-5
  // Xilinx HDL Libraries Guide, version 8.2.2
  FIFO36_72 #(
     .ALMOST_FULL_OFFSET(ALMOST_FULL_OFFSET),   // Sets almost full threshold
     .ALMOST_EMPTY_OFFSET(ALMOST_EMPTY_OFFSET), // Sets the almost empty threshold
     .DO_REG(DO_REG),                           // Enable output register (0 or 1)
                                                //   Must be 1 if EN_SYN = "FALSE"
     .EN_ECC_READ("FALSE"),                     // Enable ECC decoder, "TRUE" or "FALSE"
     .EN_ECC_WRITE("FALSE"),                    // Enable ECC encoder, "TRUE" or "FALSE"
     .EN_SYN(EN_SYN),                           // Specifies FIFO as Asynchronous ("FALSE")
                                                //   or Synchronous ("TRUE")
     .FIRST_WORD_FALL_THROUGH("FALSE")          // Sets the FIFO FWFT to "TRUE" or "FALSE
  ) FIFO36_72_slice0 (
     .ALMOSTEMPTY(fifo1_almost_empty),          // 1-bit almost empty output flag
     .ALMOSTFULL(fifo1_almost_full),            // 1-bit almost full output flag
     .DBITERR(),                                // 1-bit double bit error status output
     .DO(fifo1_do),                             // 64-bit data output
     .DOP(fifo1_dop),                           // 8-bit parity data output
     .ECCPARITY(),                              // 8-bit generated error correction parity
     .EMPTY(fifo1_empty),                       // 1-bit empty output flag
     .FULL(fifo1_full),                         // 1-bit full output flag
     .RDCOUNT(),                                // 9-bit read count output
     .RDERR(fifo1_rderr),                       // 1-bit read error output
     .SBITERR(),                                // 1-bit single bit error status output
     .WRCOUNT(),                                // 9-bit write count output
     .WRERR(fifo1_wrerr),                       // 1-bit write error
     .DI(fifo1_di),                             // 64-bit data input
     .DIP(fifo1_dip),                           // 8-bit parity input
     .RDCLK(RDCLK),                             // 1-bit read clock input
     .RDEN(fifo_rden),                          // 1-bit read enable input
     .RST(RST),                                 // 1-bit reset input
     .WRCLK(WRCLK),                             // 1-bit write clock input
     .WREN(fifo_wren)                           // 1-bit write enable input
  );

  // FIFO36_72: 72x36k Synchronous/Asynchronous BlockRAM FIFO /w ECC
  //             Virtex-5
  // Xilinx HDL Libraries Guide, version 8.2.2
  FIFO36_72 #(
     .ALMOST_FULL_OFFSET(ALMOST_FULL_OFFSET),   // Sets almost full threshold
     .ALMOST_EMPTY_OFFSET(ALMOST_EMPTY_OFFSET), // Sets the almost empty threshold
     .DO_REG(DO_REG),                           // Enable output register (0 or 1)
                                                //   Must be 1 if EN_SYN = "FALSE"
     .EN_ECC_READ("FALSE"),                     // Enable ECC decoder, "TRUE" or "FALSE"
     .EN_ECC_WRITE("FALSE"),                    // Enable ECC encoder, "TRUE" or "FALSE"
     .EN_SYN(EN_SYN),                           // Specifies FIFO as Asynchronous ("FALSE")
                                                //   or Synchronous ("TRUE")
     .FIRST_WORD_FALL_THROUGH("FALSE")          // Sets the FIFO FWFT to "TRUE" or "FALSE
  ) FIFO36_72_slice1 (
     .ALMOSTEMPTY(fifo2_almost_empty),          // 1-bit almost empty output flag
     .ALMOSTFULL(fifo2_almost_full),            // 1-bit almost full output flag
     .DBITERR(),                                // 1-bit double bit error status output
     .DO(fifo2_do),                             // 64-bit data output
     .DOP(fifo2_dop),                           // 8-bit parity data output
     .ECCPARITY(),                              // 8-bit generated error correction parity
     .EMPTY(fifo2_empty),                       // 1-bit empty output flag
     .FULL(fifo2_full),                         // 1-bit full output flag
     .RDCOUNT(),                                // 9-bit read count output
     .RDERR(fifo2_rderr),                       // 1-bit read error output
     .SBITERR(),                                // 1-bit single bit error status output
     .WRCOUNT(),                                // 9-bit write count output
     .WRERR(fifo2_wrerr),                       // 1-bit write error
     .DI(fifo2_di),                             // 64-bit data input
     .DIP(fifo2_dip),                           // 8-bit parity input
     .RDCLK(RDCLK),                             // 1-bit read clock input
     .RDEN(fifo_rden),                          // 1-bit read enable input
     .RST(RST),                                 // 1-bit reset input
     .WRCLK(WRCLK),                             // 1-bit write clock input
     .WREN(fifo_wren)                           // 1-bit write enable input
  );

  // FIFO36_72: 72x36k Synchronous/Asynchronous BlockRAM FIFO /w ECC
  //             Virtex-5
  // Xilinx HDL Libraries Guide, version 8.2.2
  FIFO36_72 #(
     .ALMOST_FULL_OFFSET(ALMOST_FULL_OFFSET),   // Sets almost full threshold
     .ALMOST_EMPTY_OFFSET(ALMOST_EMPTY_OFFSET), // Sets the almost empty threshold
     .DO_REG(DO_REG),                           // Enable output register (0 or 1)
                                                //   Must be 1 if EN_SYN = "FALSE"
     .EN_ECC_READ("FALSE"),                     // Enable ECC decoder, "TRUE" or "FALSE"
     .EN_ECC_WRITE("FALSE"),                    // Enable ECC encoder, "TRUE" or "FALSE"
     .EN_SYN(EN_SYN),                           // Specifies FIFO as Asynchronous ("FALSE")
                                                //   or Synchronous ("TRUE")
     .FIRST_WORD_FALL_THROUGH("FALSE")          // Sets the FIFO FWFT to "TRUE" or "FALSE
  ) FIFO36_72_slice2 (
     .ALMOSTEMPTY(fifo3_almost_empty),          // 1-bit almost empty output flag
     .ALMOSTFULL(fifo3_almost_full),            // 1-bit almost full output flag
     .DBITERR(),                                // 1-bit double bit error status output
     .DO(fifo3_do),                             // 64-bit data output
     .DOP(fifo3_dop),                           // 8-bit parity data output
     .ECCPARITY(),                              // 8-bit generated error correction parity
     .EMPTY(fifo3_empty),                       // 1-bit empty output flag
     .FULL(fifo3_full),                         // 1-bit full output flag
     .RDCOUNT(),                                // 9-bit read count output
     .RDERR(fifo3_rderr),                       // 1-bit read error output
     .SBITERR(),                                // 1-bit single bit error status output
     .WRCOUNT(),                                // 9-bit write count output
     .WRERR(fifo3_wrerr),                       // 1-bit write error
     .DI(fifo3_di),                             // 64-bit data input
     .DIP(fifo3_dip),                           // 8-bit parity input
     .RDCLK(RDCLK),                             // 1-bit read clock input
     .RDEN(fifo_rden),                          // 1-bit read enable input
     .RST(RST),                                 // 1-bit reset input
     .WRCLK(WRCLK),                             // 1-bit write clock input
     .WREN(fifo_wren)                           // 1-bit write enable input
  );

`ifdef CHECK_GENERATE
  initial 
    $display("%m: fifo parameters: ALMOST_FULL_OFFSET=%0d ALMOST_EMPTY_OFFSET=%0d DO_REG=%0d EN_SYN=%s", 
      ALMOST_FULL_OFFSET, ALMOST_EMPTY_OFFSET, DO_REG, EN_SYN);
`endif

endmodule
/* not truncated */
