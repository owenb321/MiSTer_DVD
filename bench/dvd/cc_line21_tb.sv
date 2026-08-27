/*
 * cc_line21_tb.sv — the line-21 EIA-608 inserter: waveform, pacing, flush.
 *
 * The waveform check is a DEMODULATOR, not a register-toggle check: it slices the
 * emitted luma at 25 IRE, samples at the bit centres the standard defines (the
 * positive peaks of the clock run-in), and reassembles the byte pair. If the NCO
 * rate, the bit order, the start bits or the levels are wrong, the bytes come back
 * wrong — which is the same thing a television's decoder would conclude.
 *
 * Scenarios:
 *   [1] run-in shape + a data pair demodulates back to the injected bytes
 *   [2] pacing: one pair per field, and each field serves its OWN parity
 *   [3] a field with no pair blanks line 21 (we transmit only what the disc gives)
 *   [4] flush drops the backlog instead of painting the pre-seek sentence
 *   [5] disabled = nothing on the wire
 *   [6] edge slope is SHAPED: no per-dot level step may exceed 70 (a square
 *       74 ns edge is a 128 step and fails; the ~310 ns half-cosine passes) —
 *       608 decoders drop bad-parity bytes, and over-sharp edges after the
 *       analog chain's filtering are exactly what makes parity fail (round 4)
 *   [7] bunched field parity (f1,f1,f2) transmits BOTH f1 pairs in order on
 *       successive field-1 lines — the first cut dropped the second one
 *
 * Build:
 *   iverilog -g2012 -I rtl/mpeg2 -o bench/dvd/cc_line21_sim \
 *       dvd/cc_line21.sv rtl/mpeg2/wrappers.v rtl/mpeg2/xilinx_fifo_dc.v \
 *       rtl/mpeg2/xfifo_sc.v rtl/mpeg2/xilinx_fifo_sc.v bench/dvd/cc_line21_tb.sv
 *   vvp bench/dvd/cc_line21_sim
 */
`timescale 1ns/1ps

module cc_line21_tb;

  localparam CC_START = 19;
  localparam HLEN     = 858;

  reg clk = 0; always #18 clk = ~clk;          // ~27 MHz
  reg dec_clk = 0; always #6 dec_clk = ~dec_clk;
  reg rst_n = 0;

  reg ce2 = 0;
  always @(posedge clk) ce2 <= ~ce2;           // 13.5 MHz enable

  // ---- synthetic raster -----------------------------------------------------
  reg [11:0] hpos = 0;
  reg        field1 = 1;
  reg        cc_line = 0;
  reg        enable = 1, flush = 0;

  always @(posedge clk) if (ce2) begin
    if (hpos == HLEN - 1) hpos <= 0;
    else hpos <= hpos + 1'b1;
  end

  // ---- producer -------------------------------------------------------------
  reg        dec_pair_valid = 0;
  reg [15:0] dec_pair = 0;
  reg        dec_pair_field = 0;

  task push(input fld, input [7:0] b1, input [7:0] b2);
    begin
      @(posedge dec_clk);
      dec_pair       <= {b1, b2};
      dec_pair_field <= fld;
      dec_pair_valid <= 1'b1;
      @(posedge dec_clk);
      dec_pair_valid <= 1'b0;
    end
  endtask

  // ---- DUT ------------------------------------------------------------------
  wire [7:0] level;
  wire       level_en, active;

  cc_line21 dut (
    .clk(clk), .rst_n(rst_n), .ce2(ce2),
    .dec_clk(dec_clk), .dec_pair_valid(dec_pair_valid),
    .dec_pair(dec_pair), .dec_pair_field(dec_pair_field),
    .enable(enable), .flush(flush),
    .hpos(hpos), .cc_line(cc_line), .field1(field1),
    .level(level), .level_en(level_en), .active(active)
  );

  // ---- waveform capture: one line's worth of dots ---------------------------
  reg [7:0] cap  [0:HLEN-1];
  reg       capv [0:HLEN-1];
  integer   i;

  // Capture ONLY while the caption line is up: the raster keeps running for
  // several lines afterwards and would otherwise overwrite the capture with blank.
  always @(posedge clk) if (ce2 && rst_n && cc_line) begin
    cap[hpos]  <= level;
    capv[hpos] <= level_en;
  end

  task clear_cap;
    begin
      for (i = 0; i < HLEN; i = i + 1) begin capv[i] = 1'b0; cap[i] = 8'd0; end
    end
  endtask

  // Run one field: assert cc_line for a whole line, then a few idle lines.
  task run_field(input fld);
    begin
      field1 = fld;
      @(negedge hpos[0]);
      while (hpos != 12'd0) @(posedge clk);
      clear_cap();
      cc_line = 1'b1;
      while (hpos != HLEN - 1) @(posedge clk);
      @(posedge clk);
      while (hpos != 12'd0) @(posedge clk);
      cc_line = 1'b0;
      repeat (4 * HLEN) @(posedge clk);
    end
  endtask

  // ---- demodulator ----------------------------------------------------------
  // Lock to the transmission the way a television does — find where it starts
  // rather than assuming a dot — then sample at the bit centres. Bit k spans
  // 858/32 dots, so its centre is at start + (2k+1)*858/64; the arithmetic stays
  // in 1/64ths to remain exact in integers.
  integer tx_start;

  task find_start;
    begin
      tx_start = -1;
      for (i = 0; i < HLEN; i = i + 1)
        if (capv[i] && tx_start < 0) tx_start = i;
    end
  endtask

  function integer bit_centre(input integer k);
    bit_centre = tx_start + ((2*k + 1) * HLEN) / 64;
  endfunction

  integer errors = 0;

  task check(input cond, input [1023:0] what);
    begin
      if (!cond) begin
        $display("FAIL: %0s", what);
        errors = errors + 1;
      end
    end
  endtask

  // Demodulate the captured line into {ok, b1, b2}.
  function [16:0] demod;
    integer k, c;
    reg [7:0] b1, b2;
    reg       ok;
    begin
      ok = 1'b1;
      // run-in: high at every bit centre, low at every bit boundary
      for (k = 0; k < 7; k = k + 1) begin
        c = bit_centre(k);
        if (cap[c] < 8'd100) ok = 1'b0;                     // peak should be ~128
        if (cap[tx_start + (k * HLEN) / 32] > 8'd40) ok = 1'b0;  // edge should be ~0
      end
      // start bits 0,0,1
      if (cap[bit_centre(7)] > 8'd64) ok = 1'b0;
      if (cap[bit_centre(8)] > 8'd64) ok = 1'b0;
      if (cap[bit_centre(9)] < 8'd64) ok = 1'b0;
      b1 = 8'd0; b2 = 8'd0;
      for (k = 0; k < 8; k = k + 1) begin
        if (cap[bit_centre(10 + k)] >= 8'd64) b1[k] = 1'b1;   // LSB first
        if (cap[bit_centre(18 + k)] >= 8'd64) b2[k] = 1'b1;
      end
      demod = {ok, b1, b2};
    end
  endfunction

  reg [16:0] d;
  integer max_step, d_step;
  integer    n_on;

  initial begin
    clear_cap();
    #200 rst_n = 1;
    repeat (10) @(posedge clk);

    // ---------------------------------------------------------------- [1] ----
    // 'C' (0x43) with odd parity set = 0xC3; 'C' second byte 0x43 -> pick a pair
    // with a mix of ones and zeros so a stuck bit cannot pass.
    push(1'b1, 8'hC3, 8'h41);
    repeat (200) @(posedge clk);
    run_field(1'b1);
    find_start();
    // 10.5 us after the hsync leading edge is dot 18.75 and the tolerance is
    // +/-0.25 us = +/-3.4 dots. The real output adds one more register than this
    // bench sees, so 17..20 here is 18..21 on the wire — inside the window.
    check(tx_start >= 17 && tx_start <= 20,
          "[1] run-in does not start 10.5us +/-0.25us after hsync");
    d = demod();
    check(d[16],            "[1] run-in / start-bit framing not recognised");
    check(d[15:8] == 8'hC3, "[1] byte 1 mis-demodulated");
    check(d[7:0]  == 8'h41, "[1] byte 2 mis-demodulated");
    // the waveform must live inside the active window and nowhere else
    n_on = 0;
    for (i = 0; i < HLEN; i = i + 1) if (capv[i]) n_on = n_on + 1;
    check(n_on > 650 && n_on < 720, "[1] waveform length wrong (expect ~697 dots)");
    check(!capv[13],                "[1] transmitting far too early");
    check(!capv[730],               "[1] waveform runs past the active window");
    if (errors == 0) $display("PASS [1] waveform demodulates to the injected pair");

    // ---------------------------------------------------------------- [2] ----
    // Field parity: a field-2 pair must NOT be served on field 1, and vice versa.
    push(1'b0, 8'h1F, 8'h2E);          // field 2
    push(1'b1, 8'h55, 8'hAA);          // field 1
    repeat (200) @(posedge clk);
    run_field(1'b1);
    find_start();
    d = demod();
    check(d[16] && d[15:8] == 8'h55 && d[7:0] == 8'hAA,
          "[2] field 1 did not serve the field-1 pair");
    run_field(1'b0);
    find_start();
    d = demod();
    check(d[16] && d[15:8] == 8'h1F && d[7:0] == 8'h2E,
          "[2] field 2 did not serve the field-2 pair");
    if (errors == 0) $display("PASS [2] each field serves its own parity, one pair per field");

    // ---------------------------------------------------------------- [3] ----
    // Nothing queued -> line 21 stays blank (we transmit only what the disc gives).
    run_field(1'b1);
    n_on = 0;
    for (i = 0; i < HLEN; i = i + 1) if (capv[i]) n_on = n_on + 1;
    check(n_on == 0, "[3] transmitted with an empty slot");
    if (errors == 0) $display("PASS [3] empty slot blanks line 21");

    // ---------------------------------------------------------------- [4] ----
    // Backlog + flush -> nothing left to paint onto the new scene.
    push(1'b1, 8'h31, 8'h32);
    push(1'b1, 8'h33, 8'h34);
    push(1'b1, 8'h35, 8'h36);
    repeat (400) @(posedge clk);
    @(posedge clk) flush = 1'b1;
    repeat (8) @(posedge clk);
    flush = 1'b0;
    repeat (400) @(posedge clk);
    run_field(1'b1);
    n_on = 0;
    for (i = 0; i < HLEN; i = i + 1) if (capv[i]) n_on = n_on + 1;
    check(n_on == 0, "[4] flush did not drop the caption backlog");
    if (errors == 0) $display("PASS [4] flush drops the backlog");

    // ---------------------------------------------------------------- [5] ----
    enable = 1'b0;
    push(1'b1, 8'h41, 8'h42);
    repeat (400) @(posedge clk);
    run_field(1'b1);
    n_on = 0;
    for (i = 0; i < HLEN; i = i + 1) if (capv[i]) n_on = n_on + 1;
    check(n_on == 0, "[5] transmitted while disabled");
    if (errors == 0) $display("PASS [5] disabled = nothing on the wire");
    enable = 1'b1;

    // [5] pushed a pair while disabled — it sits in the FIFO (the producer side
    // does not see `enable`). Flush so scenarios [6]/[7] start from a clean
    // pipeline; this contaminated exactly these scenarios when first written.
    @(posedge clk) flush = 1'b1;
    repeat (8) @(posedge clk);
    flush = 1'b0;
    repeat (400) @(posedge clk);

    // ---------------------------------------------------------------- [6] ----
    push(1'b1, 8'h55, 8'hAA);          // alternating bits = maximum transitions
    repeat (400) @(posedge clk);
    run_field(1'b1);
    max_step = 0;
    for (i = 1; i < HLEN; i = i + 1) begin
      if (capv[i] && capv[i-1]) begin
        d_step = (cap[i] > cap[i-1]) ? (cap[i] - cap[i-1]) : (cap[i-1] - cap[i]);
        if (d_step > max_step) max_step = d_step;
      end
    end
    check(max_step != 0,  "[6] no waveform captured for the slope check");
    check(max_step <= 70, "[6] edge too sharp: per-dot step exceeds 70 (square edge?)");
    find_start();
    d = demod();
    check(d[16] && d[15:8] == 8'h55 && d[7:0] == 8'hAA,
          "[6] shaped waveform no longer demodulates");
    if (errors == 0) $display("PASS [6] edges shaped (max per-dot step %0d) and still demodulate", max_step);

    // ---------------------------------------------------------------- [7] ----
    // Bunched parity: two field-1 pairs back to back, then a field-2 pair.
    push(1'b1, 8'h31, 8'h32);
    push(1'b1, 8'h33, 8'h34);
    push(1'b0, 8'h35, 8'h36);
    repeat (600) @(posedge clk);
    run_field(1'b1);
    find_start(); d = demod();
    check(d[16] && d[15:8] == 8'h31 && d[7:0] == 8'h32, "[7] first f1 pair wrong");
    run_field(1'b0);
    find_start(); d = demod();
    check(d[16] && d[15:8] == 8'h35 && d[7:0] == 8'h36, "[7] f2 pair wrong");
    run_field(1'b1);
    find_start(); d = demod();
    check(d[16] && d[15:8] == 8'h33 && d[7:0] == 8'h34,
          "[7] second f1 pair lost or out of order (drop-on-mismatch?)");
    if (errors == 0) $display("PASS [7] bunched parity held and delivered in order");

    if (errors == 0) $display("PASS: cc_line21_tb — all scenarios green");
    else begin
      $display("FAIL: cc_line21_tb — %0d error(s)", errors);
      $fatal(1);
    end
    $finish;
  end

  initial begin
    #50_000_000;
    $display("FAIL: cc_line21_tb timeout");
    $fatal(1);
  end

endmodule
