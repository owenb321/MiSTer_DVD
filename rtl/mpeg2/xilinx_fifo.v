/* 
 * xilinx_fifo.v
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
 * fifos, implemented using Xilinx Virtex5 primitives.
 * See "Virtex-5 Libraries Guide for HDL Designs", Xilinx v5ldl.
 * and "Virtex-5 User Guide", Xilinx ug190.
 * 
 * Note when resetting Xilinx FIFO18/FIFO36 primitives:
 * "The reset signal must be high for at least three read clock and three write clock cycles." Caveat emptor.
 */  

`include "timescale.v"

module xilinx_fifo (
  ALMOSTEMPTY,
  ALMOSTFULL,
  DO,
  EMPTY,
  FULL,
  RDERR,
  VALID,
  WRERR,
  WR_ACK,
  DI,
  RDCLK,
  RDEN,
  RST,
  WRCLK,
  WREN
  );

  parameter [9:0]ALMOST_FULL_OFFSET=9'h080;
  parameter [9:0]ALMOST_EMPTY_OFFSET=9'h080;
  parameter [9:0]DATA_WIDTH=9'd217;
  parameter [9:0]ADDR_WIDTH=9'd14;
  parameter DO_REG=1;
  parameter EN_SYN="FALSE";
       
  output ALMOSTEMPTY;
  output ALMOSTFULL;
  output [DATA_WIDTH-1:0]DO;
  output EMPTY;
  output FULL;
  output RDERR;
  output reg VALID;
  output WRERR;
  output reg WR_ACK;
  input [DATA_WIDTH-1:0]DI;
  input RDCLK;
  input RDEN;
  input RST;
  input WRCLK;
  input WREN;

  /* VALID and WR_ACK flags */
  always @(posedge WRCLK)
    if (RST) WR_ACK <= 1'b0;
    else WR_ACK <= WREN && ~FULL;

  always @(posedge RDCLK)
    if (RST) VALID <= 1'b0;
    else VALID <= RDEN && ~EMPTY;

  /* instantiate FIFO */
  generate
    if ((DATA_WIDTH <= 9'd4) && (ADDR_WIDTH <= 9'd12))
      begin
        wire [15:0]din;
	wire  [1:0]dinp;
        wire [15:0]dout;
	wire  [1:0]doutp;

        assign DO = dout[3:0];
        assign din = DI;
	assign dinp = 2'b0;

        // FIFO18: 16k+2k Parity Synchronous/Asynchronous BlockRAM FIFO
        //         Virtex-5
        // Xilinx HDL Libraries Guide, version 8.2.2
        FIFO18 #(
           .ALMOST_FULL_OFFSET(ALMOST_FULL_OFFSET),     // Sets almost full threshold
           .ALMOST_EMPTY_OFFSET(ALMOST_EMPTY_OFFSET),   // Sets the almost empty threshold
           .DATA_WIDTH(9'd4),                           // Sets data width to 4, 9 or 18
           .DO_REG(DO_REG),                             // Enable output register (0 or 1) output register usage
                                                        //   Must be 1 if EN_SYN = "FALSE
           .EN_SYN(EN_SYN),                             // FALSE when using independent read/write clocks; TRUE when using the same clock
                                                        //   or Synchronous ("TRUE")
           .FIRST_WORD_FALL_THROUGH("FALSE")            // Sets the FIFO FWFT to "TRUE" or "FALSE"
        ) FIFO18_width_4 (
           .ALMOSTEMPTY(ALMOSTEMPTY),                   // 1-bit almost empty output flag
           .ALMOSTFULL(ALMOSTFULL),                     // 1-bit almost full output flag
           .DO(dout),                                   // 16-bit data output
           .DOP(doutp),                                 // 2-bit parity data output
           .EMPTY(EMPTY),                               // 1-bit empty output flag
           .FULL(FULL),                                 // 1-bit full output flag
           .RDERR(RDERR),                               // 1-bit read error output
           .WRCOUNT(),                                  // 12-bit write count output
           .WRERR(WRERR),                               // 1-bit write error
           .DI(din),                                    // 16-bit data input
           .DIP(dinp),                                  // 2-bit parity input
           .RDCLK(RDCLK),                               // 1-bit read clock input
           .RDEN(RDEN),                                 // 1-bit read enable input
           .RST(RST),                                   // 1-bit reset input
           .WRCLK(WRCLK),                               // 1-bit write clock input
           .WREN(WREN)                                  // 1-bit write enable input
          );
      end
    else if ((DATA_WIDTH <= 9'd4) && (ADDR_WIDTH <= 9'd13))
      begin
        wire [31:0]din;
        wire [3:0]dinp;
        wire [31:0]dout;
        wire [3:0]doutp;

        assign DO = dout[3:0];
        assign din = DI;
        assign dinp = 4'b0;

        // FIFO36: 32k+4k Parity Synchronous/Asynchronous BlockRAM FIFO
        //          Virtex-5
        // Xilinx HDL Libraries Guide, version 8.2.2
        FIFO36 #(
           .ALMOST_FULL_OFFSET(ALMOST_FULL_OFFSET),     // Sets almost full threshold
           .ALMOST_EMPTY_OFFSET(ALMOST_EMPTY_OFFSET),   // Sets the almost empty threshold
           .DATA_WIDTH(4),                              // Sets data width to 4, 9, 18 or 36
           .DO_REG(DO_REG),                             // Enable output register (0 or 1)register usage
                                                        //   Must be 1 if EN_SYN = "FALSE
           .EN_SYN(EN_SYN),                             // FALSE when using independent read/write clocks; TRUE when using the same clock
           .FIRST_WORD_FALL_THROUGH("FALSE")            // Sets the FIFO FWFT to "TRUE" or "FALSE
        ) FIFO36_width_4 (
           .ALMOSTEMPTY(ALMOSTEMPTY),                   // 1-bit almost empty output flag
           .ALMOSTFULL(ALMOSTFULL),                     // 1-bit almost full output flag
           .DO(dout),                                   // 32-bit data output
           .DOP(doutp),                                 // 4-bit parity data output
           .EMPTY(EMPTY),                               // 1-bit empty output flag
           .FULL(FULL),                                 // 1-bit full output flag
           .RDCOUNT(),                                  // 13-bit read count output
           .RDERR(RDERR),                               // 1-bit read error output
           .WRCOUNT(),                                  // 13-bit write count output
           .WRERR(WRERR),                               // 1-bit write error
           .DI(din),                                    // FIFO data input, width determined by DATA_WIDTH
           .DIP(dinp),                                  // 4-bit parity input
           .RDCLK(RDCLK),                               // 1-bit read clock input
           .RDEN(RDEN),                                 // 1-bit read enable input
           .RST(RST),                                   // 1-bit reset input
           .WRCLK(WRCLK),                               // 1-bit write clock input
           .WREN(WREN)                                  // 1-bit write enable input
        );
      end
    else if ((DATA_WIDTH <= 9'd9) && (ADDR_WIDTH <= 9'd11))
      begin
        wire [15:0]din;
	wire  [1:0]dinp;
        wire [15:0]dout;
	wire  [1:0]doutp;

        wire [8:0]DIN = DI; // extend DI to 9 bit, if needed

        assign DO = {doutp[0], dout[7:0]};
        assign din = DIN[7:0];
        assign dinp = DIN[8];

        // FIFO18: 16k+2k Parity Synchronous/Asynchronous BlockRAM FIFO
        //         Virtex-5
        // Xilinx HDL Libraries Guide, version 8.2.2
        FIFO18 #(
           .ALMOST_FULL_OFFSET(ALMOST_FULL_OFFSET),     // Sets almost full threshold
           .ALMOST_EMPTY_OFFSET(ALMOST_EMPTY_OFFSET),   // Sets the almost empty threshold
           .DATA_WIDTH(9),                              // Sets data width to 4, 9 or 18
           .DO_REG(DO_REG),                             // Enable output register (0 or 1) output register usage
                                                        //   Must be 1 if EN_SYN = "FALSE
           .EN_SYN(EN_SYN),                             // FALSE when using independent read/write clocks; TRUE when using the same clock
                                                        //   or Synchronous ("TRUE")
           .FIRST_WORD_FALL_THROUGH("FALSE")            // Sets the FIFO FWFT to "TRUE" or "FALSE"
        ) FIFO18_width_9 (
           .ALMOSTEMPTY(ALMOSTEMPTY),                   // 1-bit almost empty output flag
           .ALMOSTFULL(ALMOSTFULL),                     // 1-bit almost full output flag
           .DO(dout),                                   // 16-bit data output
           .DOP(doutp),                                 // 2-bit parity data output
           .EMPTY(EMPTY),                               // 1-bit empty output flag
           .FULL(FULL),                                 // 1-bit full output flag
           .RDERR(RDERR),                               // 1-bit read error output
           .WRCOUNT(),                                  // 12-bit write count output
           .WRERR(WRERR),                               // 1-bit write error
           .DI(din),                                    // 16-bit data input
           .DIP(dinp),                                  // 2-bit parity input
           .RDCLK(RDCLK),                               // 1-bit read clock input
           .RDEN(RDEN),                                 // 1-bit read enable input
           .RST(RST),                                   // 1-bit reset input
           .WRCLK(WRCLK),                               // 1-bit write clock input
           .WREN(WREN)                                  // 1-bit write enable input
          );
      end
    else if ((DATA_WIDTH <= 9'd9) && (ADDR_WIDTH <= 9'd12))
      begin
        wire [31:0]din;
        wire [3:0]dinp;
        wire [31:0]dout;
        wire [3:0]doutp;

        wire [8:0]DIN = DI; // extend DI to 9 bit, if needed

        assign DO = {doutp[0], dout[7:0]};
        assign din = DIN[7:0];
        assign dinp = DIN[8];

        // FIFO36: 32k+4k Parity Synchronous/Asynchronous BlockRAM FIFO
        //          Virtex-5
        // Xilinx HDL Libraries Guide, version 8.2.2
        FIFO36 #(
           .ALMOST_FULL_OFFSET(ALMOST_FULL_OFFSET),     // Sets almost full threshold
           .ALMOST_EMPTY_OFFSET(ALMOST_EMPTY_OFFSET),   // Sets the almost empty threshold
           .DATA_WIDTH(9),                              // Sets data width to 4, 9, 18 or 36
           .DO_REG(DO_REG),                             // Enable output register (0 or 1)register usage
                                                        //   Must be 1 if EN_SYN = "FALSE
           .EN_SYN(EN_SYN),                             // FALSE when using independent read/write clocks; TRUE when using the same clock
           .FIRST_WORD_FALL_THROUGH("FALSE")            // Sets the FIFO FWFT to "TRUE" or "FALSE
        ) FIFO36_width_9 (
           .ALMOSTEMPTY(ALMOSTEMPTY),                   // 1-bit almost empty output flag
           .ALMOSTFULL(ALMOSTFULL),                     // 1-bit almost full output flag
           .DO(dout),                                   // 32-bit data output
           .DOP(doutp),                                 // 4-bit parity data output
           .EMPTY(EMPTY),                               // 1-bit empty output flag
           .FULL(FULL),                                 // 1-bit full output flag
           .RDCOUNT(),                                  // 13-bit read count output
           .RDERR(RDERR),                               // 1-bit read error output
           .WRCOUNT(),                                  // 13-bit write count output
           .WRERR(WRERR),                               // 1-bit write error
           .DI(din),                                    // FIFO data input, width determined by DATA_WIDTH
           .DIP(dinp),                                  // 4-bit parity input
           .RDCLK(RDCLK),                               // 1-bit read clock input
           .RDEN(RDEN),                                 // 1-bit read enable input
           .RST(RST),                                   // 1-bit reset input
           .WRCLK(WRCLK),                               // 1-bit write clock input
           .WREN(WREN)                                  // 1-bit write enable input
        );
      end
    else if ((DATA_WIDTH <= 9'd18) && (ADDR_WIDTH <= 9'd10))
      begin
        wire [15:0]din;
	wire  [1:0]dinp;
        wire [15:0]dout;
	wire  [1:0]doutp;

        wire [17:0]DIN = DI; // extend DI to 18 bit, if needed

        assign DO = {doutp, dout};
        assign {dinp, din} = DIN;

        // FIFO18: 16k+2k Parity Synchronous/Asynchronous BlockRAM FIFO
        //         Virtex-5
        // Xilinx HDL Libraries Guide, version 8.2.2
        FIFO18 #(
           .ALMOST_FULL_OFFSET(ALMOST_FULL_OFFSET),     // Sets almost full threshold
           .ALMOST_EMPTY_OFFSET(ALMOST_EMPTY_OFFSET),   // Sets the almost empty threshold
           .DATA_WIDTH(18),                             // Sets data width to 4, 9 or 18
           .DO_REG(DO_REG),                             // Enable output register (0 or 1) output register usage
                                                        //   Must be 1 if EN_SYN = "FALSE
           .EN_SYN(EN_SYN),                             // FALSE when using independent read/write clocks; TRUE when using the same clock
                                                        //   or Synchronous ("TRUE")
           .FIRST_WORD_FALL_THROUGH("FALSE")            // Sets the FIFO FWFT to "TRUE" or "FALSE"
        ) FIFO18_width_18 (
           .ALMOSTEMPTY(ALMOSTEMPTY),                   // 1-bit almost empty output flag
           .ALMOSTFULL(ALMOSTFULL),                     // 1-bit almost full output flag
           .DO(dout),                                   // 16-bit data output
           .DOP(doutp),                                 // 2-bit parity data output
           .EMPTY(EMPTY),                               // 1-bit empty output flag
           .FULL(FULL),                                 // 1-bit full output flag
           .RDERR(RDERR),                               // 1-bit read error output
           .WRCOUNT(),                                  // 12-bit write count output
           .WRERR(WRERR),                               // 1-bit write error
           .DI(din),                                    // 16-bit data input
           .DIP(dinp),                                  // 2-bit parity input
           .RDCLK(RDCLK),                               // 1-bit read clock input
           .RDEN(RDEN),                                 // 1-bit read enable input
           .RST(RST),                                   // 1-bit reset input
           .WRCLK(WRCLK),                               // 1-bit write clock input
           .WREN(WREN)                                  // 1-bit write enable input
          );
      end
    else if ((DATA_WIDTH <= 9'd18) && (ADDR_WIDTH <= 9'd11))
      begin
        wire [31:0]din;
        wire [3:0]dinp;
        wire [31:0]dout;
        wire [3:0]doutp;

        wire [17:0]DIN = DI; // extend DI to 18 bit, if needed

        assign DO = {doutp[1:0], dout[15:0]};
        assign din = DIN[15:0];
        assign dinp = DIN[17:16];

        // FIFO36: 32k+4k Parity Synchronous/Asynchronous BlockRAM FIFO
        //          Virtex-5
        // Xilinx HDL Libraries Guide, version 8.2.2
        FIFO36 #(
           .ALMOST_FULL_OFFSET(ALMOST_FULL_OFFSET),     // Sets almost full threshold
           .ALMOST_EMPTY_OFFSET(ALMOST_EMPTY_OFFSET),   // Sets the almost empty threshold
           .DATA_WIDTH(18),                             // Sets data width to 4, 9, 18 or 36
           .DO_REG(DO_REG),                             // Enable output register (0 or 1)register usage
                                                        //   Must be 1 if EN_SYN = "FALSE
           .EN_SYN(EN_SYN),                             // FALSE when using independent read/write clocks; TRUE when using the same clock
           .FIRST_WORD_FALL_THROUGH("FALSE")            // Sets the FIFO FWFT to "TRUE" or "FALSE
        ) FIFO36_width_18 (
           .ALMOSTEMPTY(ALMOSTEMPTY),                   // 1-bit almost empty output flag
           .ALMOSTFULL(ALMOSTFULL),                     // 1-bit almost full output flag
           .DO(dout),                                   // 32-bit data output
           .DOP(doutp),                                 // 4-bit parity data output
           .EMPTY(EMPTY),                               // 1-bit empty output flag
           .FULL(FULL),                                 // 1-bit full output flag
           .RDCOUNT(),                                  // 13-bit read count output
           .RDERR(RDERR),                               // 1-bit read error output
           .WRCOUNT(),                                  // 13-bit write count output
           .WRERR(WRERR),                               // 1-bit write error
           .DI(din),                                    // FIFO data input, width determined by DATA_WIDTH
           .DIP(dinp),                                  // 4-bit parity input
           .RDCLK(RDCLK),                               // 1-bit read clock input
           .RDEN(RDEN),                                 // 1-bit read enable input
           .RST(RST),                                   // 1-bit reset input
           .WRCLK(WRCLK),                               // 1-bit write clock input
           .WREN(WREN)                                  // 1-bit write enable input
        );
      end
    else if ((DATA_WIDTH <= 9'd36) && (ADDR_WIDTH <= 9'd9))
      begin
        wire [31:0]din;
        wire [31:0]dout;
        wire [3:0]dinp;
        wire [3:0]doutp;

        assign DO = {doutp, dout};
        assign {dinp, din} = DI;

        // FIFO18_36: 36x18k Synchronous/Asynchronous BlockRAM FIFO
        //             Virtex-5
        // Xilinx HDL Libraries Guide, version 8.2.2
        FIFO18_36 #(
           .ALMOST_FULL_OFFSET(ALMOST_FULL_OFFSET),     // Sets almost full threshold
           .ALMOST_EMPTY_OFFSET(ALMOST_EMPTY_OFFSET),   // Sets the almost empty threshold
           .DO_REG(DO_REG),                             // Enable output register (0 or 1)
                                                        //   Must be 1 if EN_SYN = "FALSE
           .EN_SYN(EN_SYN),                             // Specifies FIFO as Asynchronous ("FALSE")
                                                        //   or Synchronous ("TRUE")
           .FIRST_WORD_FALL_THROUGH("FALSE")            // Sets the FIFO FWFT to "TRUE" or "FALSE
        ) FIFO18_36_width_36 (
           .ALMOSTEMPTY(ALMOSTEMPTY),                   // 1-bit almost empty output flag
           .ALMOSTFULL(ALMOSTFULL),                     // 1-bit almost full output flag
           .DO(dout),                                   // 32-bit data output
           .DOP(doutp),                                 // 4-bit parity data output
           .EMPTY(EMPTY),                               // 1-bit empty output flag
           .FULL(FULL),                                 // 1-bit full output flag
           .RDCOUNT(),                                  // 9-bit read count output
           .RDERR(RDERR),                               // 1-bit read error output
           .WRCOUNT(),                                  // 9-bit write count output
           .WRERR(WRERR),                               // 1-bit write error
           .DI(din),                                    // 32-bit data input
           .DIP(dinp),                                  // 4-bit parity input
           .RDCLK(RDCLK),                               // 1-bit read clock input
           .RDEN(RDEN),                                 // 1-bit read enable input
           .RST(RST),                                   // 1-bit reset input
           .WRCLK(WRCLK),                               // 1-bit write clock input
           .WREN(WREN)                                  // 1-bit write enable input
        );
      end
    else if ((DATA_WIDTH <= 9'd36) && (ADDR_WIDTH <= 9'd10))
      begin
        wire [31:0]din;
        wire [3:0]dinp;
        wire [31:0]dout;
        wire [3:0]doutp;

        assign DO = {doutp, dout};
        assign {dinp, din} = DI;

        // FIFO36: 32k+4k Parity Synchronous/Asynchronous BlockRAM FIFO
        //          Virtex-5
        // Xilinx HDL Libraries Guide, version 8.2.2
        FIFO36 #(
           .ALMOST_FULL_OFFSET(ALMOST_FULL_OFFSET),     // Sets almost full threshold
           .ALMOST_EMPTY_OFFSET(ALMOST_EMPTY_OFFSET),   // Sets the almost empty threshold
           .DATA_WIDTH(36),                             // Sets data width to 4, 9, 18 or 36
           .DO_REG(DO_REG),                             // Enable output register (0 or 1)register usage
                                                        //   Must be 1 if EN_SYN = "FALSE
           .EN_SYN(EN_SYN),                             // FALSE when using independent read/write clocks; TRUE when using the same clock
           .FIRST_WORD_FALL_THROUGH("FALSE")            // Sets the FIFO FWFT to "TRUE" or "FALSE
        ) FIFO36_width_36 (
           .ALMOSTEMPTY(ALMOSTEMPTY),                   // 1-bit almost empty output flag
           .ALMOSTFULL(ALMOSTFULL),                     // 1-bit almost full output flag
           .DO(dout),                                   // 32-bit data output
           .DOP(doutp),                                 // 4-bit parity data output
           .EMPTY(EMPTY),                               // 1-bit empty output flag
           .FULL(FULL),                                 // 1-bit full output flag
           .RDCOUNT(),                                  // 13-bit read count output
           .RDERR(RDERR),                               // 1-bit read error output
           .WRCOUNT(),                                  // 13-bit write count output
           .WRERR(WRERR),                               // 1-bit write error
           .DI(din),                                    // FIFO data input, width determined by DATA_WIDTH
           .DIP(dinp),                                  // 4-bit parity input
           .RDCLK(RDCLK),                               // 1-bit read clock input
           .RDEN(RDEN),                                 // 1-bit read enable input
           .RST(RST),                                   // 1-bit reset input
           .WRCLK(WRCLK),                               // 1-bit write clock input
           .WREN(WREN)                                  // 1-bit write enable input
        );
      end
    else if ((DATA_WIDTH <= 9'd72) && (ADDR_WIDTH <= 9'd9))
      begin
        wire [63:0]din;
        wire [63:0]dout;
        wire [7:0]dinp;
        wire [7:0]doutp;

        assign DO = {doutp, dout};
        assign {dinp, din} = DI;

        // FIFO36_72: 72x36k Synchronous/Asynchronous BlockRAM FIFO /w ECC
        //             Virtex-5
        // Xilinx HDL Libraries Guide, version 8.2.2
        FIFO36_72 #(
           .ALMOST_FULL_OFFSET(ALMOST_FULL_OFFSET),     // Sets almost full threshold
           .ALMOST_EMPTY_OFFSET(ALMOST_EMPTY_OFFSET),   // Sets the almost empty threshold
           .DO_REG(DO_REG),                             // Enable output register (0 or 1)
                                                        //   Must be 1 if EN_SYN = "FALSE
           .EN_ECC_READ("FALSE"),                       // Enable ECC decoder, "TRUE" or "FALSE
           .EN_ECC_WRITE("FALSE"),                      // Enable ECC encoder, "TRUE" or "FALSE
           .EN_SYN(EN_SYN),                             // Specifies FIFO as Asynchronous ("FALSE")
                                                        //   or Synchronous ("TRUE")
           .FIRST_WORD_FALL_THROUGH("FALSE")            // Sets the FIFO FWFT to "TRUE" or "FALSE
        ) FIFO36_72_width_72 (
           .ALMOSTEMPTY(ALMOSTEMPTY),                   // 1-bit almost empty output flag
           .ALMOSTFULL(ALMOSTFULL),                     // 1-bit almost full output flag
           .DBITERR(),                                  // 1-bit double bit error status output
           .DO(dout),                                   // 32-bit data output
           .DOP(doutp),                                 // 4-bit parity data output
           .ECCPARITY(),                                // 8-bit generated error correction parity
           .EMPTY(EMPTY),                               // 1-bit empty output flag
           .FULL(FULL),                                 // 1-bit full output flag
           .RDCOUNT(),                                  // 9-bit read count output
           .RDERR(RDERR),                               // 1-bit read error output
           .SBITERR(),                                  // 1-bit single bit error status output
           .WRCOUNT(),                                  // 9-bit write count output
           .WRERR(WRERR),                               // 1-bit write error
           .DI(din),                                    // 32-bit data input
           .DIP(dinp),                                  // 4-bit parity input
           .RDCLK(RDCLK),                               // 1-bit read clock input
           .RDEN(RDEN),                                 // 1-bit read enable input
           .RST(RST),                                   // 1-bit reset input
           .WRCLK(WRCLK),                               // 1-bit write clock input
           .WREN(WREN)                                  // 1-bit write enable input
        );
        // End of FIFO36_72_inst instantiation
      end
    else if ((DATA_WIDTH <= 9'd144) && (ADDR_WIDTH <= 9'd9))
      begin
        wire [143:0]din;
        wire [143:0]dout;
        assign DO = dout;
        assign din = DI;

        // FIFO144: 144x36k Synchronous/Asynchronous BlockRAM FIFO
        //             Virtex-5
        //
        FIFO144 #(
          .ALMOST_FULL_OFFSET(ALMOST_FULL_OFFSET),
          .ALMOST_EMPTY_OFFSET(ALMOST_EMPTY_OFFSET),
          .DO_REG(DO_REG),
          .EN_SYN(EN_SYN)
          )
        FIFO144_width_144 (
          .ALMOSTEMPTY(ALMOSTEMPTY), 
          .ALMOSTFULL(ALMOSTFULL), 
          .DO(dout), 
          .EMPTY(EMPTY), 
          .FULL(FULL), 
          .RDERR(RDERR), 
          .WRERR(WRERR), 
          .DI(din),
          .RDCLK(RDCLK), 
          .RDEN(RDEN), 
          .RST(RST), 
          .WRCLK(WRCLK), 
          .WREN(WREN)
          );
      end
    else if ((DATA_WIDTH <= 9'd216) && (ADDR_WIDTH <= 9'd9))
      begin
        wire [215:0]din;
        wire [215:0]dout;
        assign DO = dout;
        assign din = DI;

        // FIFO216: 216x36k Synchronous/Asynchronous BlockRAM FIFO
        //             Virtex-5
        //
        FIFO216 #(
          .ALMOST_FULL_OFFSET(ALMOST_FULL_OFFSET),
          .ALMOST_EMPTY_OFFSET(ALMOST_EMPTY_OFFSET),
          .DO_REG(DO_REG),
          .EN_SYN(EN_SYN)
          )
        FIFO216_width_216 (
          .ALMOSTEMPTY(ALMOSTEMPTY), 
          .ALMOSTFULL(ALMOSTFULL), 
          .DO(dout), 
          .EMPTY(EMPTY), 
          .FULL(FULL), 
          .RDERR(RDERR), 
          .WRERR(WRERR), 
          .DI(din),
          .RDCLK(RDCLK), 
          .RDEN(RDEN), 
          .RST(RST), 
          .WRCLK(WRCLK), 
          .WREN(WREN)
          );
      end
    else 
      begin
        /* 
	 * No suitable FIFO found. Generate error.
	 */
        initial $display("%m: fifo parameter error. DATA_WIDTH=%0d ADDR_WIDTH=%0d ALMOST_FULL_OFFSET=%0d ALMOST_EMPTY_OFFSET=%0d", DATA_WIDTH, ADDR_WIDTH, ALMOST_FULL_OFFSET, ALMOST_EMPTY_OFFSET);
        assign ALMOSTEMPTY = 1'bx;
        assign ALMOSTFULL = 1'bx;
        assign EMPTY = 1'bx;
        assign FULL = 1'bx;
        assign RDERR = 1'bx;
        assign WRERR = 1'bx;
        assign DO = {144{1'bx}};
        initial $stop;
      end
  endgenerate

`ifdef CHECK_GENERATE
  initial 
    $display("%m: fifo parameters: DATA_WIDTH=%0d ADDR_WIDTH=%0d ALMOST_FULL_OFFSET=%0d ALMOST_EMPTY_OFFSET=%0d DO_REG=%0d EN_SYN=%s", 
      DATA_WIDTH, ADDR_WIDTH, ALMOST_FULL_OFFSET, ALMOST_EMPTY_OFFSET, DO_REG, EN_SYN);
`endif

//`ifdef CHECK_FIFO_PARAMS
   initial #0
     begin
       if (  ((EN_SYN == "TRUE")  && ((ALMOST_FULL_OFFSET < 13'd1) || (ALMOST_EMPTY_OFFSET < 13'd1)))
          || ((EN_SYN == "FALSE") && ((ALMOST_FULL_OFFSET < 13'd4) || (ALMOST_EMPTY_OFFSET < 13'd5))) )
         begin
           #0 $display ("%m\t*** error: inconsistent fifo parameters. ALMOST_FULL_OFFSET: %d ALMOST_EMPTY_OFFSET: %d. ***", ALMOST_FULL_OFFSET, ALMOST_EMPTY_OFFSET);
           $finish;
         end
     end
//`endif

endmodule 
/* not truncated */
