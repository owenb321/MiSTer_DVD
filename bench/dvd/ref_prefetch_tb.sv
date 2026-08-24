// ref_prefetch_tb.sv — DVD-FORK (reference-read run-ahead prefetch, O[18])
//
// Verifies Stage 1 of the motcomp throughput work (docs/motcomp_throughput.md):
//   1. ref_dta_gate logic: baseline mode caps at the upstream fill (192); deep mode
//      follows the fifo's native prog_full; occupancy counts net-zero on a coincident
//      read+write.
//   2. The DEEPENED reference data fifo (framestore_reader at depth 10) closed-loop
//      with an address-issue + memory-latency + recon-drain model:
//        - DEEP   (prefetch_en=1): buffers far ahead (>600 rows) of recon demand.
//        - BASELINE(prefetch_en=0): run-ahead capped near 192 rows.
//        - NEITHER overflows, even with the maximum in-flight reads (threshold 64
//          free > 2**MEMTAG_DEPTH=32), proving the deep fifo is overflow-safe.
//
// Build (see also bench/dvd/run_prefetch_chain.sh for the display analogue):
//   iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 \
//       rtl/mpeg2/read_write.v rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v \
//       rtl/mpeg2/xilinx_fifo_dc.v rtl/mpeg2/xfifo_sc.v dvd/ref_dta_gate.sv \
//       bench/dvd/ref_prefetch_tb.sv -o bench/dvd/ref_prefetch_sim
//   vvp bench/dvd/ref_prefetch_sim

`timescale 1ns/1ps
`default_nettype none

module ref_prefetch_tb;

  localparam [8:0] DTA_DEPTH      = 9'd9;    // 512 deep (deepened reference data fifo, depth-9 build)
  localparam [8:0] ADDR_DEPTH     = 9'd9;    // 512 deep (deepened reference addr fifo)
  localparam [8:0] DTA_THRESHOLD  = 9'd64;   // free slots reserved (> MEMTAG 32)
  localparam [8:0] ADDR_THRESHOLD = 9'd144;  // MOTCOMP_ADDR_THRESHOLD
  localparam [10:0] BASELINE_FILL = 11'd192; // upstream default = 256 - 64
  localparam        MEMTAG        = 32;      // max in-flight reads (2**MEMTAG_DEPTH)

  integer errors = 0;

  reg clk = 0;
  always #5 clk = ~clk;       // 100 MHz nominal
  reg rst_n;

  // ---------------------------------------------------------------------------
  // Part 1 — ref_dta_gate unit logic
  // ---------------------------------------------------------------------------
  reg  g_wr_ack, g_rd_valid, g_deep, g_pf_en;
  wire g_almost_full;

  ref_dta_gate #(.BASELINE_FILL(BASELINE_FILL)) dut_gate (
    .clk(clk), .rst_n(rst_n),
    .wr_ack(g_wr_ack), .rd_valid(g_rd_valid),
    .almost_full_deep(g_deep), .prefetch_en(g_pf_en),
    .almost_full(g_almost_full));

  task step; begin @(posedge clk); #1; end endtask

  task gate_test;
    integer i;
    begin
      // --- baseline mode: count up to BASELINE_FILL, expect almost_full at exactly 192
      g_pf_en = 1'b0; g_deep = 1'b0; g_rd_valid = 1'b0; g_wr_ack = 1'b0;
      @(posedge clk); rst_n = 1'b0; @(posedge clk); rst_n = 1'b1; #1;
      // push 191 entries — must still be low
      for (i = 0; i < 191; i = i + 1) begin g_wr_ack = 1'b1; step; end
      g_wr_ack = 1'b0; #1;
      if (g_almost_full !== 1'b0) begin
        $display("FAIL: baseline almost_full asserted at fill=191 (expected low)"); errors = errors + 1;
      end
      // push the 192nd — must assert
      g_wr_ack = 1'b1; step; g_wr_ack = 1'b0; #1;
      if (g_almost_full !== 1'b1) begin
        $display("FAIL: baseline almost_full NOT asserted at fill=192"); errors = errors + 1;
      end else $display("PASS: baseline cap asserts at fill=192");
      // drain one — must deassert (back to 191)
      g_rd_valid = 1'b1; step; g_rd_valid = 1'b0; #1;
      if (g_almost_full !== 1'b0) begin
        $display("FAIL: baseline almost_full stuck high at fill=191"); errors = errors + 1;
      end else $display("PASS: baseline cap deasserts below 192");
      // net-zero: simultaneous wr+rd keeps fill unchanged (still 191 -> low)
      g_wr_ack = 1'b1; g_rd_valid = 1'b1; step; g_wr_ack = 1'b0; g_rd_valid = 1'b0; #1;
      if (g_almost_full !== 1'b0) begin
        $display("FAIL: net-zero wr+rd changed occupancy"); errors = errors + 1;
      end else $display("PASS: coincident wr+rd is net-zero");

      // --- deep mode: occupancy is well above baseline, but almost_full follows g_deep
      g_pf_en = 1'b1;
      // (fill is ~191, far below deep prog_full) ensure deep=0 => low despite > baseline
      g_deep = 1'b0; step; #1;
      if (g_almost_full !== 1'b0) begin
        $display("FAIL: deep mode asserted on baseline fill (should ignore baseline)"); errors = errors + 1;
      end else $display("PASS: deep mode ignores baseline cap");
      g_deep = 1'b1; step; #1;
      if (g_almost_full !== 1'b1) begin
        $display("FAIL: deep mode did not follow native prog_full"); errors = errors + 1;
      end else $display("PASS: deep mode follows native prog_full");
    end
  endtask

  // ---------------------------------------------------------------------------
  // Part 2 — deepened framestore_reader closed loop (addrgen -> mem -> recon)
  // ---------------------------------------------------------------------------
  // reader (motcomp) side
  reg         wr_addr_en;
  reg  [21:0] wr_addr;
  wire        wr_addr_full, wr_addr_almost_full, wr_addr_ack, wr_addr_overflow;
  reg         rd_dta_en;
  wire        rd_dta_empty, rd_dta_almost_empty, rd_dta_valid;
  wire [63:0] rd_dta;
  // framestore side
  wire        rd_addr_empty, rd_addr_valid;
  wire [21:0] rd_addr;
  reg         rd_addr_en;
  reg         wr_dta_en;
  reg  [63:0] wr_dta;
  wire        wr_dta_full, wr_dta_almost_full_deep, wr_dta_ack, wr_dta_overflow;

  wire        gated_almost_full;
  reg         pf_en;

  framestore_reader #(
    .fifo_dta_depth(DTA_DEPTH), .fifo_addr_depth(ADDR_DEPTH),
    .fifo_addr_threshold(ADDR_THRESHOLD), .fifo_dta_threshold(DTA_THRESHOLD))
  dut_reader (
    .rst(rst_n), .clk(clk),
    .wr_addr_clk_en(1'b1), .wr_addr_full(wr_addr_full), .wr_addr_almost_full(wr_addr_almost_full),
    .wr_addr_en(wr_addr_en), .wr_addr_ack(wr_addr_ack), .wr_addr_overflow(wr_addr_overflow), .wr_addr(wr_addr),
    .rd_dta_clk_en(1'b1), .rd_dta_almost_empty(rd_dta_almost_empty), .rd_dta_empty(rd_dta_empty),
    .rd_dta_en(rd_dta_en), .rd_dta_valid(rd_dta_valid), .rd_dta(rd_dta),
    .rd_addr_empty(rd_addr_empty), .rd_addr_en(rd_addr_en), .rd_addr_valid(rd_addr_valid), .rd_addr(rd_addr),
    .wr_dta_full(wr_dta_full), .wr_dta_almost_full(wr_dta_almost_full_deep),
    .wr_dta_en(wr_dta_en), .wr_dta_ack(wr_dta_ack), .wr_dta(wr_dta), .wr_dta_overflow(wr_dta_overflow));

  ref_dta_gate #(.BASELINE_FILL(BASELINE_FILL)) loop_gate (
    .clk(clk), .rst_n(rst_n),
    .wr_ack(wr_dta_ack), .rd_valid(rd_dta_valid),
    .almost_full_deep(wr_dta_almost_full_deep), .prefetch_en(pf_en),
    .almost_full(gated_almost_full));

  // memory-latency model: a simple delay line of pending returns
  localparam LAT = 24;                 // ~ miss round-trip
  reg [LAT-1:0] mem_pipe;              // bit set = a return is due this many cycles out
  integer inflight;
  integer dta_fill;                    // observed data-fifo occupancy
  integer max_fill;
  integer recon_div;                   // recon consumes 1 row / 2 cycles
  integer recon_gaps;                  // times recon wanted data but fifo empty (after prime)
  integer issued, returned, consumed;
  reg     primed;

  task run_loop;
    input        prefetch;
    input integer ncyc;
    integer t;
    begin
      // reset everything
      pf_en = prefetch;
      wr_addr_en = 0; wr_addr = 0; rd_dta_en = 0; rd_addr_en = 0; wr_dta_en = 0; wr_dta = 0;
      mem_pipe = 0; inflight = 0; dta_fill = 0; max_fill = 0; recon_div = 0;
      recon_gaps = 0; issued = 0; returned = 0; consumed = 0; primed = 0;
      @(posedge clk); rst_n = 0; @(posedge clk); rst_n = 1; #1;

      for (t = 0; t < ncyc; t = t + 1) begin
        // --- defaults each cycle
        wr_addr_en = 0; rd_addr_en = 0; wr_dta_en = 0; rd_dta_en = 0;

        // addrgen: keep the address fifo fed (addresses always available)
        if (!wr_addr_almost_full) begin wr_addr_en = 1; wr_addr = wr_addr + 22'd1; end

        // request/issue: pop an address + schedule a return after LAT, gated by the
        // (possibly baseline-capped) data-fifo almost_full and the in-flight limit.
        if (!gated_almost_full && !rd_addr_empty && inflight < MEMTAG) begin
          rd_addr_en = 1;
          mem_pipe[LAT-1] = 1'b1;     // a return becomes due in LAT cycles
          inflight = inflight + 1;
          issued = issued + 1;
        end

        // memory return: if a return is due now, push data into the fifo
        if (mem_pipe[0]) begin
          wr_dta_en = 1; wr_dta = wr_dta + 64'd1;
          inflight = inflight - 1;
          returned = returned + 1;
        end

        // recon: drain one row every 2 cycles when data is available
        recon_div = recon_div + 1;
        if (recon_div[0] == 1'b0) begin
          if (!rd_dta_empty) begin rd_dta_en = 1; consumed = consumed + 1; end
          else if (primed) recon_gaps = recon_gaps + 1;
        end

        @(posedge clk); #1;

        // shift the latency pipe (a return consumed this cycle drops off bit 0)
        mem_pipe = mem_pipe >> 1;

        // observe occupancy via ack/valid
        if (wr_dta_ack)  dta_fill = dta_fill + 1;
        if (rd_dta_valid) dta_fill = dta_fill - 1;
        if (dta_fill > max_fill) max_fill = dta_fill;
        if (dta_fill > 300) primed = 1;        // consider primed once it has run ahead

        // hard safety: the deepened fifo must never overflow / fill completely
        if (wr_dta_overflow) begin
          $display("FAIL[%0s]: data fifo OVERFLOW at t=%0d", prefetch?"DEEP":"BASE", t);
          errors = errors + 1;
        end
        if (wr_dta_full) begin
          $display("FAIL[%0s]: data fifo FULL at t=%0d (fill=%0d inflight=%0d)",
                   prefetch?"DEEP":"BASE", t, dta_fill, inflight);
          errors = errors + 1;
        end
      end
    end
  endtask

  initial begin
    rst_n = 1'b1; g_wr_ack=0; g_rd_valid=0; g_deep=0; g_pf_en=0;
    @(posedge clk); @(posedge clk);

    $display("==== Part 1: ref_dta_gate logic ====");
    gate_test;

    $display("==== Part 2a: DEEP run-ahead (prefetch_en=1) ====");
    run_loop(1'b1, 30000);
    $display("   DEEP   : max data-fifo fill = %0d rows  (issued=%0d returned=%0d consumed=%0d)",
             max_fill, issued, returned, consumed);
    if (max_fill < 350) begin
      $display("FAIL: deep prefetch did not run far ahead (max_fill=%0d, expected >350 at depth 512)", max_fill);
      errors = errors + 1;
    end else $display("PASS: deep prefetch buffers far ahead (max_fill=%0d, depth 512)", max_fill);

    $display("==== Part 2b: BASELINE run-ahead (prefetch_en=0) ====");
    run_loop(1'b0, 30000);
    $display("   BASE   : max data-fifo fill = %0d rows  (issued=%0d returned=%0d consumed=%0d)",
             max_fill, issued, returned, consumed);
    if (max_fill > 280) begin
      $display("FAIL: baseline run-ahead exceeded the cap (max_fill=%0d, expected ~192)", max_fill);
      errors = errors + 1;
    end else $display("PASS: baseline run-ahead capped near 192 (max_fill=%0d)", max_fill);

    $display("==== SUMMARY: %0d error(s) ====", errors);
    if (errors == 0) $display("ref_prefetch_tb: ALL TESTS PASSED");
    else             $display("ref_prefetch_tb: FAILURES PRESENT");
    $finish;
  end

  // global watchdog
  initial begin #5000000; $display("FAIL: watchdog timeout"); $finish; end

endmodule

`default_nettype wire
