`timescale 1ns/1ps
//
// trick_es_filter_tb.sv -- streams a file through dvd/trick_es_filter.sv and writes what
// comes out (bench/dvd/run_trick_es_filter.sh compares it with tools/trick_splice.py).
//
// Plusargs:
//   +IN=<file>    input bytes (the video ES as ps_demux would emit it)
//   +OUT=<file>   output bytes
//   +EN=<0|1>     trick play enable (default 1); 0 checks the filter is a wire
//   +SEED=<n>     random gaps on in_valid and backpressure on out_ready (default 1)
//   +GAPS=<0|1>   0 = in_valid and out_ready always high (default 1)
//
// Prints "skip_n <n> pair_n <n> in <n> out <n>" and PASS when the input ran out cleanly.
// Every port is connected (CLAUDE.md: an unconnected input floats Z).
//
module trick_es_filter_tb;
  reg clk = 0; always #18.5 clk = ~clk;          // 27 MHz
  reg rst_n = 0;
  reg en = 1;

  reg  [7:0] in_byte = 0;
  reg        in_mark = 0;
  reg        in_valid = 0;
  wire       in_ready;
  wire [7:0] out_byte;
  wire       out_mark;
  wire       out_valid;
  reg        out_ready = 0;
  wire [15:0] skip_n, pair_n;

  trick_es_filter dut (
    .clk(clk), .rst_n(rst_n), .en(en),
    .in_byte(in_byte), .in_mark(in_mark), .in_valid(in_valid), .in_ready(in_ready),
    .out_byte(out_byte), .out_mark(out_mark), .out_valid(out_valid), .out_ready(out_ready),
    .skip_n(skip_n), .pair_n(pair_n)
  );

  string inp, outp;
  integer fi, fo, ch, seed = 1, gaps = 1, n_in = 0, n_out = 0, idle = 0, en_arg = 1;
  reg have = 0, eof = 0;

  // the source: one byte presented at a time, held until taken
  always @(posedge clk) if (rst_n) begin
    if (in_valid && in_ready) begin
      n_in <= n_in + 1;
      have = 0;
    end
    if (!have && !eof) begin
      ch = $fgetc(fi);
      if (ch < 0) eof = 1;
      else begin in_byte <= ch[7:0]; in_mark <= (($random(seed) & 63) == 0); have = 1; end
    end
    in_valid  <= have && (gaps == 0 || ($random(seed) & 3) != 0);
    out_ready <= (gaps == 0 || ($random(seed) & 3) != 0);
  end

  // the sink
  always @(posedge clk) if (rst_n && out_valid && out_ready) begin
    $fwrite(fo, "%c", out_byte);
    n_out <= n_out + 1;
  end

  initial begin
    if (!$value$plusargs("IN=%s", inp)) $fatal(1, "need +IN=");
    if (!$value$plusargs("OUT=%s", outp)) $fatal(1, "need +OUT=");
    if ($value$plusargs("EN=%d", en_arg)) en = en_arg[0];
    void'($value$plusargs("SEED=%d", seed));
    void'($value$plusargs("GAPS=%d", gaps));
    fi = $fopen(inp, "rb");
    if (fi == 0) $fatal(1, "cannot open %s", inp);
    fo = $fopen(outp, "wb");
    repeat (4) @(posedge clk);
    rst_n = 1;
    // run until the input is exhausted and nothing has moved for 64 cycles
    while (!(eof && !have && idle > 64)) begin
      @(posedge clk);
      if ((in_valid && in_ready) || (out_valid && out_ready)) idle = 0; else idle = idle + 1;
    end
    $fclose(fo);
    $display("skip_n %0d pair_n %0d in %0d out %0d", skip_n, pair_n, n_in, n_out);
    if (skip_n === 16'bx || pair_n === 16'bx) $fatal(1, "counters X");
    $display("PASS");
    $finish;
  end
endmodule
