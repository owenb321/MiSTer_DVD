/*
 * cc_e2e_tb.sv — closed captions END TO END: re_interlace's own output pins,
 * demodulated by a television model.
 *
 * WHY THIS BENCH EXISTS (round 3, 2026-08-26): every caption bench drove the
 * pieces separately — cc_line21_tb drives the inserter's ports, cc_field_map_tb
 * drives sync_gen, re_interlace_tb holds cc_enable low. So when an edit deleted
 * the cc_vline/cc_line wire declarations inside re_interlace, Verilog silently
 * created an undriven implicit net, Quartus tied it to ground, the whole caption
 * chain went dead on hardware — and every bench still passed. The wiring BETWEEN
 * the proven pieces was the only untested thing, and it was the thing that broke.
 *
 * So this bench treats re_interlace exactly as the analog chain does: synthetic
 * progressive NTSC main raster in, caption pairs injected on a separate producer
 * clock, and the ONLY signals observed are out_r/out_hs/out_vs/out_de/out_ce —
 * the pins. The checker is a TV model:
 *
 *   [1] finds caption bursts in the VBI (never during out_de),
 *   [2] classifies each field by its vsync leading-edge alignment to hsync
 *       (SMPTE 170M: line-aligned = field 1, mid-line = field 2),
 *   [3] demodulates each burst (slice at ~25 IRE, sample at bit centres) and
 *       requires the FIELD-1 pair on the field-1 line and the FIELD-2 pair on
 *       the field-2 line — the full slot-routing contract at the pins,
 *   [4] requires the burst to sit 17 lines after the vsync leading edge
 *       (v_cntr 244 -> 261 = broadcast line 21's position in this raster).
 *
 * Build:
 *   iverilog -g2012 -I rtl/mpeg2 -o bench/dvd/cc_e2e_sim \
 *       rtl/mpeg2/syncgen.v dvd/re_interlace.sv dvd/cc_line21.sv \
 *       rtl/mpeg2/wrappers.v rtl/mpeg2/xilinx_fifo_dc.v rtl/mpeg2/xfifo_sc.v \
 *       rtl/mpeg2/xilinx_fifo_sc.v bench/dvd/cc_e2e_tb.sv
 *   vvp bench/dvd/cc_e2e_sim
 */
`include "timescale.v"

module cc_e2e_tb;

  // ---------------------------------------------------------------- clocks
  reg clk = 0;  always #5 clk = ~clk;          // "27 MHz"
  reg dec_clk = 0; always #3 dec_clk = ~dec_clk;
  reg ce2 = 0;  always @(posedge clk) ce2 <= ~ce2;

  // ---------------------------------------------------------------- DUT
  reg         rst_n = 0;
  reg  [7:0]  in_r, in_g, in_b;
  reg         in_de;
  reg  [11:0] in_hpos, in_vpos;
  wire [7:0]  out_r, out_g, out_b;
  wire        out_hs, out_vs, out_de, out_ce, locked, cc_active;

  reg         dec_pair_valid = 0;
  reg  [15:0] dec_pair = 0;
  reg         dec_pair_field = 0;

  re_interlace dut (
    .clk(clk), .rst_n(rst_n), .ce2(ce2),
    .enable(1'b1), .pal(1'b0), .fieldpass(1'b0),
    .in_r(in_r), .in_g(in_g), .in_b(in_b), .in_de(in_de),
    .in_hpos(in_hpos), .in_vpos(in_vpos),
    .out_r(out_r), .out_g(out_g), .out_b(out_b),
    .out_hs(out_hs), .out_vs(out_vs), .out_de(out_de),
    .out_ce(out_ce), .locked(locked),
    .cc_enable(1'b1), .cc_test(1'b0), .cc_flush(1'b0), .dec_clk(dec_clk),
    .cc_pair_valid(dec_pair_valid), .cc_pair(dec_pair),
    .cc_pair_field(dec_pair_field), .cc_active(cc_active)
  );

  // ------------------------------------------- synthetic NTSC main raster
  integer g_h = 0, g_v = 0;
  always @(posedge clk) begin
    if (g_h >= 857) begin
      g_h <= 0;
      g_v <= (g_v >= 524) ? 0 : g_v + 1;
    end else g_h <= g_h + 1;
  end
  always @(*) begin
    in_hpos = g_h[11:0];
    in_vpos = g_v[11:0];
    in_de   = (g_h < 720) && (g_v < 480);
    in_r    = 8'h20; in_g = 8'h30; in_b = 8'h40;   // flat active video
  end

  // ------------------------------------------- caption producer (dec_clk)
  // Keep both slots supplied: the DUT consumes one pair per field per parity.
  localparam [15:0] PAIR_F1 = 16'hC341;   // field-1 payload ('C' odd parity, 'A')
  localparam [15:0] PAIR_F2 = 16'h1F2E;   // field-2 payload, distinct
  reg fld_toggle = 0;
  always begin
    @(posedge dec_clk);
    if (rst_n) begin
      dec_pair       <= fld_toggle ? PAIR_F1 : PAIR_F2;
      dec_pair_field <= fld_toggle;
      dec_pair_valid <= 1'b1;
      @(posedge dec_clk);
      dec_pair_valid <= 1'b0;
      fld_toggle     <= ~fld_toggle;
      repeat (2000) @(posedge dec_clk);   // ~2 pairs per output line time
    end
  end

  // ------------------------------------------- TV model (pins only)
  // Dot clock = out_ce ticks. Track h position from out_hs rises; classify each
  // out_vs rise by that h position; count lines since the vs rise.
  integer h_dot = 0;          // dots since last hsync rise
  integer line_no = -1;       // lines since last vsync rise (-1 = none seen)
  reg     f1_field = 0;       // current field began with a line-aligned vsync
  reg     hs_q = 0, vs_q = 0;

  // per-line capture
  reg [7:0] cap [0:1023];
  integer   cap_burst = 0;    // nonzero luma dots seen this line
  integer   burst_start = -1;

  integer checked_f1 = 0, checked_f2 = 0, errors = 0;

  task fail(input string msg);
    begin
      errors = errors + 1;
      $display("FAIL @%0t: %0s", $time, msg);
    end
  endtask

  // demod: slice at 64 (25 IRE of the 128 = 50 IRE peak), bit = 858/32 dots.
  // Anchor on the FIRST RUN-IN PEAK, the way a real slicer locks: an amplitude
  // threshold lands mid-slope (5 dots late here) and shifts every bit centre.
  // Peak of bit 0 sits at tx0 + 858/64 dots => tx0 = first-peak - 13.
  function [16:0] demod;      // {ok, b1, b2}
    integer k, tx0;
    reg [7:0] b1, b2;
    reg ok;
    begin
      tx0 = -1;
      for (k = burst_start - 8; k < burst_start + 30; k = k + 1)
        if (tx0 < 0 && cap[k] >= 8'd125) tx0 = k - 13;
      ok = (tx0 >= 0);
      if (ok) begin
        for (k = 0; k < 7; k = k + 1)
          if (cap[tx0 + ((2*k+1)*858)/64] < 8'd110) ok = 1'b0;   // run-in peaks
        if (cap[tx0 + (15*858)/64] > 8'd64) ok = 1'b0;           // start bit 0
        if (cap[tx0 + (17*858)/64] > 8'd64) ok = 1'b0;           // start bit 0
        if (cap[tx0 + (19*858)/64] < 8'd64) ok = 1'b0;           // start bit 1
      end
      b1 = 0; b2 = 0;
      for (k = 0; k < 8; k = k + 1) begin
        if (cap[tx0 + ((2*(10+k)+1)*858)/64] >= 8'd64) b1[k] = 1'b1;
        if (cap[tx0 + ((2*(18+k)+1)*858)/64] >= 8'd64) b2[k] = 1'b1;
      end
      demod = {ok, b1, b2};
    end
  endfunction

  reg [16:0] d;
  integer dbg_i;

  always @(posedge clk) if (out_ce && rst_n) begin
    hs_q <= out_hs;
    vs_q <= out_vs;

    // end of line: evaluate any captured burst
    if (out_hs && !hs_q) begin
      if (cap_burst > 100) begin           // a real burst, not noise
        d = demod();
        if (!d[16]) begin
          fail("burst framing did not demodulate");
          if (errors == 1) begin
            $write("burst_start=%0d dots:", burst_start);
            for (dbg_i = -4; dbg_i < 60; dbg_i = dbg_i + 1)
              $write(" %0d", cap[burst_start + dbg_i]);
            $display("");
          end
        end
        else if (line_no != 17)
          fail($sformatf("burst on line %0d after vsync (expect 17 = line 21)", line_no));
        else if (f1_field && d[15:0] != PAIR_F1)
          fail($sformatf("FIELD-1 line carries %04x (want %04x)", d[15:0], PAIR_F1));
        else if (!f1_field && d[15:0] != PAIR_F2)
          fail($sformatf("FIELD-2 line carries %04x (want %04x)", d[15:0], PAIR_F2));
        else if (f1_field) checked_f1 = checked_f1 + 1;
        else               checked_f2 = checked_f2 + 1;
      end
      h_dot <= 0;
      cap_burst   <= 0;
      burst_start <= -1;
      if (line_no >= 0) line_no <= line_no + 1;
    end else begin
      h_dot <= h_dot + 1;
    end

    if (out_vs && !vs_q) begin
      // classify: line-aligned (h near 0 or wrapped near 858) = FIELD 1
      f1_field <= (h_dot < 214) || (h_dot > 643);
      line_no  <= 0;
    end

    // capture non-active luma; captions must NEVER coincide with out_de
    if (out_de && cc_active)
      ;  // cc_active is a diagnostic, may span the tx window; the real check:
    if (h_dot < 1024) cap[h_dot] <= out_r;
    if (!out_de && out_r > 8'd40 && !out_vs) begin
      cap_burst <= cap_burst + 1;
      if (burst_start < 0) burst_start <= h_dot;
    end
    if (out_de && out_r != 8'h20 && locked)
      fail("active video corrupted (caption leaked into out_de region)");
  end

  initial begin
    #200 rst_n = 1;
    // lock (~2 frames) + 8 fields of caption lines
    #80_000_000;
    if (checked_f1 < 3) fail($sformatf("only %0d field-1 caption lines demodulated", checked_f1));
    if (checked_f2 < 3) fail($sformatf("only %0d field-2 caption lines demodulated", checked_f2));
    if (errors == 0)
      $display("PASS: cc_e2e_tb — %0d field-1 + %0d field-2 caption lines demodulated at the pins, line 21, correct slots",
               checked_f1, checked_f2);
    else begin
      $display("FAIL: cc_e2e_tb — %0d error(s)", errors);
      $fatal(1);
    end
    $finish;
  end

endmodule
