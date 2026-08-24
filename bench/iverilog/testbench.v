/* 
 * testbench.v
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
 *
 */

/*
 * testbench - mpeg2 decoder test bench
 */

`include "timescale.v"

/* max number of bytes in stream.dat mpeg2 stream */
`define MAX_STREAM_LENGTH 4194304

/* clk at 75 MHz */
`define CLK_PERIOD 13.3

/* mem_clk at 125 MHz */
`define MEMCLK_PERIOD 8.0

/* dot_clk at 27 MHz */
`define VIDCLK_PERIOD 37.0

`undef DEBUG
`define DEBUG 1

/* write (lxt) dumpfile of simulation run */
`undef DEBUG_DUMP
`define DEBUG_DUMP 1

// write rgb+sync output to file tvout_0.ppm or tv_out_1.ppm, alternately.
`undef DUMP_TVOUT
`define DUMP_TVOUT 1

module testbench();
  /* clocks and reset */
  reg        clk;     // system clock
  reg        mem_clk; // clock for memory controller and dram
  reg        dot_clk; // video dot clock
  reg   [7:0]rst_ff;
  wire       rst;
  /* mpeg2 stream input */ 
  reg   [7:0]stream_data;
  reg        stream_valid;
  /* status output */ 
  wire       busy;
  wire       error;
  wire       interrupt;
  /* video output */
  wire       pixel_en;
  wire       h_sync;
  wire       v_sync;
  wire  [7:0]r; // red
  wire  [7:0]g; // green
  wire  [7:0]b; // blue
  wire  [7:0]y; // luminance
  wire  [7:0]u; // chrominance
  wire  [7:0]v; // chrominance
  /* register file interface */
  reg   [3:0]reg_addr;
  reg        reg_wr_en;
  reg  [31:0]reg_dta_in;
  reg        reg_rd_en;
  wire [31:0]reg_dta_out;
  /* memory controller interface */
  wire  [1:0]mem_req_rd_cmd;
  wire [21:0]mem_req_rd_addr;
  wire [63:0]mem_req_rd_dta;
  wire       mem_req_rd_en;
  wire       mem_req_rd_valid;
  wire [63:0]mem_res_wr_dta;
  wire       mem_res_wr_en;
  wire       mem_res_wr_almost_full;
  wire [33:0]testpoint;

  /*
   * clocks 
   */
  
  initial
    begin
      clk = 1'b0;
      #(`CLK_PERIOD/2);
      forever #(`CLK_PERIOD/2) clk = ~clk;
    end

  initial
    begin
      mem_clk = 1'b0;
      #(`MEMCLK_PERIOD/2);
      forever #(`MEMCLK_PERIOD/2) mem_clk = ~mem_clk;
    end

  initial
    begin
      dot_clk = 1'b0;
      #(`VIDCLK_PERIOD/2);
      forever #(`VIDCLK_PERIOD/2) dot_clk = ~dot_clk;
    end

  /*
   * read mpeg2 clip from file "stream.dat"
   */

  integer    i;
  reg   [7:0]stream[0:`MAX_STREAM_LENGTH];
  integer file;
  integer fread_rc;

  initial #0
    begin
      // Open the file in read-binary mode
      file = $fopen("vid.mpg", "rb");
      if (!file) begin
          $display("Error: Could not open file vid.mpg");
          $finish;
      end

      // Read the file into the stream array
      // $fread returns the number of bytes read
      fread_rc = $fread(stream, file);
      $display("Loaded %0d bytes from vid.mpg", fread_rc);
      $fclose(file);

      rst_ff    = 8'b0;
      i         = 0;
      stream_data  = 0;
      stream_valid = 0;
      reg_dta_in = 32'd0;
      reg_addr  = 4'b0;
      reg_wr_en = 0;
      reg_rd_en = 0;
    end

  assign rst = rst_ff[7];

  always @(posedge clk)
    rst_ff <= {rst_ff[6:0], 1'b1};

  /* timing simulation: add #1 = 1 ns hold time to stream_data and stream_valid */

  always @(posedge clk)
    if (~rst)
      begin
        i <= 0;
        stream_data <= #1 0;
        stream_valid <= #1 1'b0;
      end
    else if (~busy && (i < `MAX_STREAM_LENGTH) && (^stream [i] !== 1'bx))
      begin
        i <= i + 1;
        stream_data <= #1 stream [i];
        stream_valid <= #1 1'b1;
        if ((i % 10000) == 0) $display("Fed %d bytes", i);
      end
    else
      begin
        i <= i;
        stream_data <= #1 0;
        stream_valid <= #1 1'b0;
      end
  
   /*
    * mpeg2 decoder
    */
  
  mpeg2video mpeg2 (
    .clk(clk), 
    .mem_clk(mem_clk), 
    .dot_clk(dot_clk), 
    .rst(rst), 
    .stream_data(stream_data), 
    .stream_valid(stream_valid), 
    .reg_addr(reg_addr), 
    .reg_wr_en(reg_wr_en), 
    .reg_dta_in(reg_dta_in), 
    .reg_rd_en(reg_rd_en), 
    .reg_dta_out(reg_dta_out), 
    .busy(busy), 
    .error(error), 
    .interrupt(interrupt), 
    .watchdog_rst(),
    .r(r), 
    .g(g), 
    .b(b), 
    .y(y), 
    .u(u), 
    .v(v), 
    .pixel_en(pixel_en), 
    .h_sync(h_sync), 
    .v_sync(v_sync), 
    .c_sync(), 
    .mem_req_rd_cmd(mem_req_rd_cmd), 
    .mem_req_rd_addr(mem_req_rd_addr), 
    .mem_req_rd_dta(mem_req_rd_dta), 
    .mem_req_rd_en(mem_req_rd_en), 
    .mem_req_rd_valid(mem_req_rd_valid), 
    .mem_res_wr_dta(mem_res_wr_dta), 
    .mem_res_wr_en(mem_res_wr_en), 
    .mem_res_wr_almost_full(mem_res_wr_almost_full),
    .testpoint(testpoint),
    .testpoint_dip(4'h0),
    .testpoint_dip_en(1'b1)
    );

   /*
    * Memory controller
    */
  
    mem_ctl mem_ctl (
    .clk(mem_clk),
    .rst(rst),
    .mem_req_rd_cmd(mem_req_rd_cmd),
    .mem_req_rd_addr(mem_req_rd_addr),
    .mem_req_rd_dta(mem_req_rd_dta),
    .mem_req_rd_en(mem_req_rd_en),
    .mem_req_rd_valid(mem_req_rd_valid),
    .mem_res_wr_dta(mem_res_wr_dta),
    .mem_res_wr_en(mem_res_wr_en),
    .mem_res_wr_almost_full(mem_res_wr_almost_full)
    );

`ifdef DEBUG_DUMP
  /*
   * begin vcd dump 
   */

  initial
    // generate vcd dump, for use with gtkwave 
    // set IVERILOG_DUMPER=lxt environment variable for lxt format (smaller)
    // export IVERILOG_DUMPER=lxt
    begin
      $dumpfile("testbench.lxt");
//      $dumpvars;
//        $dumpvars(0, testbench.mpeg2.resample.resample_dta);
//        $dumpvars(0, testbench.mpeg2.resample.resample_bilinear);
        $dumpvars(0, testbench.mpeg2.probe);
    end
`endif

`ifdef DUMP_TVOUT

/*
  Writes rgb output to portable pixmap graphics file "tv_out_xxxx.ppm".
 */

  integer fp = 0;
  reg [31:0]fname_cnt = "0000";
  integer v_sync_seen = 1;
  integer pixel_count = 0;
  integer img_count = 0;

  wire [11:0]syncgen_horizontal_resolution;
  wire [11:0]syncgen_horizontal_sync_start;
  wire [11:0]syncgen_horizontal_sync_end;
  wire [11:0]syncgen_horizontal_length;
  wire [11:0]dot_vertical_resolution;
  wire [11:0]dot_vertical_sync_start;
  wire [11:0]dot_vertical_sync_end;
  wire [11:0]dot_vertical_length;
  wire       dot_interlaced;
  wire [11:0]syncgen_horizontal_halfline;

  /*
   * Note: these assignments have to be modified if synthesis assigns other names to these nets. 
   * Use commands such as "find signals -r *name*" at the simulator prompt to find suitable candidates.
   */

  assign syncgen_horizontal_resolution = testbench.mpeg2.syncgen_intf.syncgen_horizontal_resolution;
  assign syncgen_horizontal_sync_start = testbench.mpeg2.syncgen_intf.syncgen_horizontal_sync_start;
  assign syncgen_horizontal_sync_end   = testbench.mpeg2.syncgen_intf.syncgen_horizontal_sync_end;
  assign syncgen_horizontal_length     = testbench.mpeg2.syncgen_intf.syncgen_horizontal_length;
  assign syncgen_horizontal_halfline   = testbench.mpeg2.syncgen_intf.syncgen_horizontal_halfline;
  assign dot_vertical_resolution       = testbench.mpeg2.syncgen_intf.dot_vertical_resolution;
  assign dot_vertical_sync_start       = testbench.mpeg2.syncgen_intf.dot_vertical_sync_start;
  assign dot_vertical_sync_end         = testbench.mpeg2.syncgen_intf.dot_vertical_sync_end;
  assign dot_vertical_length           = testbench.mpeg2.syncgen_intf.dot_vertical_length;
  assign dot_interlaced                = testbench.mpeg2.syncgen_intf.dot_interlaced;

  always @(posedge dot_clk)
    begin
      if (v_sync) v_sync_seen = 1;

      if (v_sync_seen && pixel_en && (^syncgen_horizontal_length !== 1'bx) && (^dot_vertical_length !== 1'bx))
        begin
          // pad and close old dump file
          if (fp != 0)
            begin
              while (pixel_count < (syncgen_horizontal_length + 1) * (dot_vertical_length + 1))
                begin
                  $fwrite(fp, " 48  48  48\n");
                  pixel_count = pixel_count + 1;
                end
              $fclose(fp);
            end
          v_sync_seen = 0;
          pixel_count = 0;
          // open new dump file
          fp=$fopen({"tv_out_", fname_cnt, ".ppm"}, "w");
          /* implement a counter for string "fname_cnt" */
          if (fname_cnt[7:0] != "9")
            fname_cnt[7:0] = fname_cnt[7:0] + 1;
          else
            begin
              fname_cnt[7:0] = "0";
              if (fname_cnt[15:8] != "9")
                fname_cnt[15:8] = fname_cnt[15:8] + 1;
              else
                begin
                  fname_cnt[15:8] = "0";
                  if (fname_cnt[23:16] != "9")
                    fname_cnt[23:16] = fname_cnt[23:16] + 1;
                  else
                    begin
                      fname_cnt[23:16] = "0";
                      if (fname_cnt[31:24] != "9")
                        fname_cnt[31:24] = fname_cnt[31:24] + 1;
                      else
                        fname_cnt[31:24] = "0";
                    end
                end
            end
          // write header
          if (fp != 0) 
            begin
              $fwrite(fp, "P3\n"); // Portable pixmap, ascii.
              $timeformat(-3, 2, " ms", 8);
              $fwrite(fp, "# picture %0d  @ %t\n", img_count, $time);
              $timeformat(-9, 2, " ns", 20);
              $fwrite(fp, "# horizontal resolution %0d sync_start %0d sync_end %0d length %0d\n", syncgen_horizontal_resolution, syncgen_horizontal_sync_start, syncgen_horizontal_sync_end, syncgen_horizontal_length);
              $fwrite(fp, "# vertical resolution %0d sync_start %0d sync_end %0d length %0d\n", dot_vertical_resolution, dot_vertical_sync_start, dot_vertical_sync_end, dot_vertical_length);
              $fwrite(fp, "# interlaced %0d halfline %0d\n", dot_interlaced, syncgen_horizontal_halfline);
              img_count = img_count + 1;
              $fwrite(fp, "%5d %5d 255\n", syncgen_horizontal_length + 1, dot_vertical_length + 1);
            end
        end
      
      // write rgb values to dump file
      if (fp != 0) 
        begin
          if (pixel_en && ((^r === 1'bx) || (^g === 1'bx) || (^g === 1'bx))) 
            begin
              $fwrite(fp, "    255   0   0\n"); // draw pixel in vivid red if r, g or b undefined
            end
          else if (pixel_en) $fwrite(fp, "%3d %3d %3d\n", r, g, b);
          else if (v_sync || h_sync) $fwrite(fp, "  0   0   0\n");
          else $fwrite(fp, " 48  48  48\n");
          pixel_count = pixel_count + 1;
        end
    end

`endif

`ifdef DEBUG
  always @(posedge clk)
    if (error) 
      begin
        $display("%m\terror asserted\n");
//        $stop;
      end
  
  // Memory interface debug
  always @(posedge mem_clk) begin
      if (mem_req_rd_valid && mem_req_rd_en)
          $strobe("%m\t[MEM_REQ] cmd:%d addr:%h valid:%d en:%d", mem_req_rd_cmd, mem_req_rd_addr, mem_req_rd_valid, mem_req_rd_en);
      if (mem_res_wr_en)
          $strobe("%m\t[MEM_RES] wr_en:%d almost_full:%d", mem_res_wr_en, mem_res_wr_almost_full);
  end

  always @(posedge clk) begin
      if ((i % 100000) == 0 && i > 0)
          $strobe("%m\t[STATUS] Fed %d bytes, busy:%d mem_req_rd_en:%d mem_res_wr_almost_full:%d", i, busy, mem_req_rd_en, mem_res_wr_almost_full);
  end


`endif
   
endmodule
/* not truncated */
