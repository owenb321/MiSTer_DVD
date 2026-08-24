/* 
 * read_write.v
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
 * read_write - Interface for framestore readers/writers.
 */

`include "timescale.v"

/*
 *   Address is a 22-bit memory address, which unequivocally determines the location of one 64-bit macroblock row, 8 pixels wide, 8 bits per pixel.
 *   Data is one 64-bit macroblock row, 8 pixels wide, 8 bits per pixel.
 *
 * Frame store and reader/writer may have different clocks.
 * Reader/writer uses clock "clk", frame store uses clock "mem_clk".
 * Only the reader/writer side has a clock enable clk_en; the frame store is free running.
 */

`undef CHECK
`ifdef __IVERILOG__
`define CHECK 1
`endif

module framestore_reader(
  rst, clk, 
  wr_addr_clk_en, wr_addr_full, wr_addr_almost_full, wr_addr_en, wr_addr_ack, wr_addr_overflow, wr_addr, rd_dta_clk_en, rd_dta_almost_empty, rd_dta_empty, rd_dta_en, rd_dta_valid, rd_dta,
  rd_addr_empty, rd_addr_en, rd_addr_valid, rd_addr, wr_dta_full, wr_dta_almost_full, wr_dta_en, wr_dta_ack, wr_dta_overflow, wr_dta
  );

  /*
   * Note: maximum clock frequency may depend upon fifo depth. 
   * On Xilinx Spartan, once the fifo is too long to fit in single block ram, speed drops. 
   * For 64-bit words, a depth of 127-256 entries seems optimal. YMMV.
   */
  parameter [8:0]fifo_dta_depth=9'd7;       // number of levels in fifo = 2 ** fifo_depth. eg. fifo_depth=7 gives a fifo 128 levels deep.
  parameter [8:0]fifo_addr_depth=9'd5;      // number of levels in fifo = 2 ** fifo_depth. eg. fifo_depth=5 gives a fifo 32 levels deep.
  parameter [8:0]fifo_addr_threshold=9'd8;  // assert wr_addr_almost_full when 8 free slots left.
  parameter [8:0]fifo_dta_threshold=9'd6;   // assert wr_dta_almost_full when 6 free slots left.

  /* address and data fifo reset and clock */
  input        rst;               
  input        clk;               
  /* reader side, writing address */
  input        wr_addr_clk_en;               
  output       wr_addr_full;
  output       wr_addr_almost_full;
  input        wr_addr_en;
  input  [21:0]wr_addr;
  output       wr_addr_ack;
  output       wr_addr_overflow;
  /* reader side, reading data */
  input        rd_dta_clk_en;               
  output       rd_dta_almost_empty;
  output       rd_dta_empty;
  input        rd_dta_en;
  output [63:0]rd_dta;
  output       rd_dta_valid;

  /* frame store side, reading address */
  output       rd_addr_empty;
  input        rd_addr_en;
  output [21:0]rd_addr;
  output       rd_addr_valid;
  /* frame store side, writing data */
  output       wr_dta_full;
  output       wr_dta_almost_full;
  input        wr_dta_en;
  output       wr_dta_ack;
  input  [63:0]wr_dta;
  output       wr_dta_overflow;

  /* address fifo */
  fifo_sc 
    #(.addr_width(fifo_addr_depth),
    .dta_width(9'd22), // block row address is 22 bits.
    .prog_thresh(fifo_addr_threshold))  
    reader_addr_fifo (
    .rst(rst), 
    .clk(clk), 
    .din(wr_addr), 
    .wr_en(wr_addr_en && wr_addr_clk_en), 
    .wr_ack(wr_addr_ack),
    .full(wr_addr_full), 
    .overflow(wr_addr_overflow),
    .prog_full(wr_addr_almost_full), 
    .dout(rd_addr), 
    .rd_en(rd_addr_en), 
    .valid(rd_addr_valid),
    .underflow(),
    .empty(rd_addr_empty),
    .prog_empty()
    );

  /*
   * Generate an "almost full" signal when framestore should stop treating read requests for this reader.
   * The 'almost full' signal is actually asserted when only 6 free slots remain in the fifo.
   */

  fifo_sc 
    #(.addr_width(fifo_dta_depth),
    .dta_width(9'd64), // one block row is 8 pixels at 8 bits each, 64 bits total.
    .prog_thresh(fifo_dta_threshold))   // assert prog_full when fifo has space for 8 (or less) entries (= 1 block).
    reader_dta_fifo (
    .rst(rst), 
    .clk(clk), 
    .din(wr_dta), 
    .wr_en(wr_dta_en), 
    .wr_ack(wr_dta_ack),
    .full(wr_dta_full), 
    .overflow(wr_dta_overflow),
    .dout(rd_dta), 
    .rd_en(rd_dta_en && rd_dta_clk_en), 
    .valid(rd_dta_valid),
    .underflow(),
    .empty(rd_dta_empty), 
    .prog_empty(rd_dta_almost_empty),
    .prog_full(wr_dta_almost_full)
    );

`ifdef CHECK
  always @(posedge clk)
    if (wr_addr_overflow) 
      begin
        #0 $display ("%m\t*** error: framestore_reader addr fifo overflow. ***");
        $stop;
      end

  always @(posedge clk)
    if (wr_dta_overflow) 
      begin
        #0 $display ("%m\t*** error: framestore_reader data fifo overflow. ***");
        $stop;
      end
`endif

endmodule

module framestore_writer(
  rst, clk, clk_en,
  wr_full, wr_almost_full, wr_ack, wr_en, wr_addr, wr_dta, wr_overflow,
  rd_empty, rd_almost_empty, rd_valid, rd_en, rd_addr, rd_dta
  );

  /*
   * Fifo depth. 
   * Note: maximum clock frequency depends upon fifo depth. 
   * On Xilinx Spartan, once you go beyond a single block ram, speed drops.  XXX Check.
   * For 64-bit words, a depth of around 256 seems optimal. YMMV.
   */
  parameter [8:0]fifo_depth=9'd7;      // number of levels in fifo = 2 ** fifo_depth. eg. fifo_depth=7 gives a fifo 128 levels deep.
  parameter [8:0]fifo_threshold=9'd8;  // assert wr_almost_full when 8 free slots left.

  /* fifo reset and clock */
  input        rst;
  input        clk;
  input        clk_en;
  /* writer side, writing command and address */
  output       wr_full;
  output       wr_almost_full;
  output       wr_ack;
  input        wr_en;
  input  [21:0]wr_addr;
  input  [63:0]wr_dta;
  output       wr_overflow;

  /* frame store side, reading command and address */
  output       rd_empty;
  output       rd_almost_empty;
  output       rd_valid;
  input        rd_en;
  output [21:0]rd_addr;
  output [63:0]rd_dta;

  fifo_sc 
    #(.addr_width(fifo_depth),
    .dta_width(9'd86), // 22 bit address + 64 bit data = 86 bits
    .prog_thresh(fifo_threshold))  // assert prog_empty when fifo has 8 (or less than 8) entries.
    writer_fifo (
    .rst(rst), 
    .clk(clk), 
    .din({wr_addr, wr_dta}), 
    .wr_en(wr_en && clk_en), 
    .full(wr_full), 
    .prog_full(wr_almost_full), 
    .wr_ack(wr_ack),
    .overflow(wr_overflow),
    .dout({rd_addr, rd_dta}), 
    .rd_en(rd_en), 
    .empty(rd_empty),
    .prog_empty(rd_almost_empty), 
    .valid(rd_valid),
    .underflow()
    );

`ifdef CHECK
  always @(posedge clk)
    if (wr_overflow) 
      begin
        #0 $display ("%m\t*** error: framestore_writer fifo overflow ***");
        $stop;
      end
    
`endif

endmodule
/* not truncated */
