/*
 * cc_e2e_tb.sv — closed captions END TO END on the MAIN raster: the core's own
 * output pins, demodulated by a television model.
 *
 * WHY THIS BENCH EXISTS (round 3, 2026-08-26): every caption bench drove the
 * pieces separately — cc_line21_tb drives the inserter's ports, cc_field_map_tb
 * drives sync_gen. So when an edit deleted the cc_vline/cc_line wire declarations
 * inside the (then) re_interlace wrapper, Verilog silently created an undriven
 * implicit net, Quartus tied it to ground, the whole caption chain went dead on
 * hardware — and every bench still passed. The wiring BETWEEN the proven pieces
 * was the only untested thing, and it was the thing that broke.
 *
 * 2026-09-03 (single-raster analog): the second raster is gone. The captions now
 * ride the interlaced MAIN raster's VBI through dvd/cc_vbi.sv and the registered
 * output stage in dvd/emu.sv. This bench builds that exact chain: the REAL
 * rtl/mpeg2/syncgen.v with the interlaced modeline as syncgen sees it (pixel
 * repetition doubled, halfline 1 = line-aligned), the REAL dvd/cc_vbi.sv on its coordinates,
 * and a copy of emu.sv's output stage (caption level outside DE, black elsewhere,
 * CE_PIXEL = one clock per pixrep pair). Caption pairs are injected on a separate
 * producer clock, and the ONLY signals observed are the pins. The checker is a TV
 * model, sampling at the pixel enable (858 samples per line):
 *
 *   [1] finds caption bursts in the VBI (never during DE),
 *   [2] classifies each field by the raster's own field marker (v_pos[0] = ~VGA_F1);
 *       that it is the broadcast field 1 is proven by cc_field_map_tb (sync signature)
 *       and csync_field_tb (the analog pin),
 *   [3] demodulates each burst (slice at ~25 IRE, sample at bit centres) and
 *       requires the FIELD-1 pair on the field-1 line and the FIELD-2 pair on
 *       the field-2 line — the full slot-routing contract at the pins,
 *   [4] requires the burst to sit 17 lines after the vsync leading edge
 *       (v_cntr 244 -> 261 = broadcast line 21's position in this raster),
 *   [5] the pixel-enable contract: exactly 720 enabled samples inside DE per
 *       active line (Main reports 720x480i), DE 1440 clocks wide.
 *
 * Build:
 *   iverilog -g2012 -I rtl/mpeg2 -o bench/dvd/cc_e2e_sim \
 *       rtl/mpeg2/syncgen.v dvd/cc_vbi.sv dvd/cc_line21.sv \
 *       rtl/mpeg2/wrappers.v rtl/mpeg2/xilinx_fifo_dc.v rtl/mpeg2/xfifo_sc.v \
 *       rtl/mpeg2/xilinx_fifo_sc.v bench/dvd/cc_e2e_tb.sv
 *   vvp bench/dvd/cc_e2e_sim
 */
`include "timescale.v"

module cc_e2e_tb;
  // ---------------------------------------------------------------- clocks
  reg clk = 0;  always #5 clk = ~clk;          // "27 MHz"
  reg dec_clk = 0; always #3 dec_clk = ~dec_clk;
  reg rst_n = 0;

  // ---------------------------------------------------------------- the raster
  wire [11:0] h_pos, v_pos;
  wire        pixel_en, h_sync, v_sync, c_sync_u, h_blank, v_blank;
  sync_gen sg (
    .clk(clk), .clk_en(1'b1), .rst(rst_n),
    .horizontal_size(14'd1440), .vertical_size(14'd480),
    .display_horizontal_size(14'd0), .display_vertical_size(14'd0),
    .horizontal_resolution(12'd1440),
    .horizontal_sync_start(12'd1471), .horizontal_sync_end(12'd1595),
    .horizontal_length(12'd1715),
    .vertical_resolution(12'd480),
    .vertical_sync_start(12'd244), .vertical_sync_end(12'd247),
    .horizontal_halfline(12'd1), .vertical_length(12'd261),
    .interlaced(1'b1), .clip_display_size(1'b0),
    .h_pos(h_pos), .v_pos(v_pos), .pixel_en(pixel_en),
    .h_sync(h_sync), .v_sync(v_sync), .c_sync(c_sync_u),
    .h_blank(h_blank), .v_blank(v_blank));

  // ---------------------------------------------------------------- DUT wiring
  reg         dec_pair_valid = 0;
  reg  [15:0] dec_pair = 0;
  reg         dec_pair_field = 0;
  wire [7:0]  cc_level;
  wire        cc_on, cc_active;
  cc_vbi dut (
    .clk(clk), .rst_n(rst_n),
    .dec_clk(dec_clk), .dec_pair_valid(dec_pair_valid),
    .dec_pair(dec_pair), .dec_pair_field(dec_pair_field),
    .enable(1'b1), .test(1'b0), .flush(1'b0), .pal(1'b0),
    .h_pos(h_pos), .v_pos(v_pos), .pixel_en(pixel_en),
    .level(cc_level), .on(cc_on), .active(cc_active));

  // emu.sv's registered output stage (flat active video, no overlays)
  reg  [7:0] out_r;
  reg        out_hs, out_vs, out_de, out_ce;
  always @(posedge clk) begin
    out_r  <= cc_on ? cc_level : ~pixel_en ? 8'd0 : 8'h20;
    out_hs <= h_sync;
    out_vs <= v_sync;
    out_de <= pixel_en;
    out_ce <= ~h_pos[0];                    // first clock of each pixrep pair
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
  integer verbose = 0;
  initial void'($value$plusargs("verbose=%d", verbose));

  // [5] pixel-enable contract, counted on the raw clock
  integer de_clk_cnt = 0, de_ce_cnt = 0, de_lines = 0;
  reg     de_q = 0;
  always @(posedge clk) if (rst_n) begin
    de_q <= out_de;
    if (out_de) begin
      de_clk_cnt = de_clk_cnt + 1;
      if (out_ce) de_ce_cnt = de_ce_cnt + 1;
    end
    if (!out_de && de_q) begin
      de_lines = de_lines + 1;
      if (de_lines > 1) begin            // line 0 starts inside the reset release
        if (de_clk_cnt != 1440) fail($sformatf("DE line is %0d clocks wide (expect 1440)", de_clk_cnt));
        if (de_ce_cnt  != 720)  fail($sformatf("%0d pixel enables inside DE (expect 720)", de_ce_cnt));
      end
      de_clk_cnt = 0; de_ce_cnt = 0;
    end
  end

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
          fail($sformatf("burst on line %0d after vsync (expect 17 = line 21) [%0s field]", line_no, f1_field ? "line-aligned" : "mid-line"));
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
      // Classify the field. The MAIN raster is line-aligned in both fields on purpose
      // (a half-line here combs ascal's weave — HW round 3), so the vsync position no
      // longer distinguishes them; the 2:1 half-line is applied downstream, to the
      // analog composite sync, by sys_top's csync. The raster's own field marker is
      // v_pos[0] (= ~VGA_F1), and that it marks the BROADCAST field-1 line-aligned
      // vsync is proven by bench/dvd/cc_field_map_tb.sv (sync_gen with the analog
      // half-line) and bench/dvd/csync_field_tb.sv (the csync pin, both fields
      // 262.5 lines apart).
      f1_field <= ~v_pos[0];
      line_no  <= 0;
      if (verbose) $display("  vsync rise at h_dot=%0d v_pos=%0d (field %0s) line_no was %0d",
                            h_dot, v_pos, (~v_pos[0]) ? "1" : "2", line_no);
    end

    // capture non-active luma; captions must NEVER coincide with out_de
    if (h_dot < 1024) cap[h_dot] <= out_r;
    if (!out_de && out_r > 8'd40 && !out_vs) begin
      cap_burst <= cap_burst + 1;
      if (burst_start < 0) burst_start <= h_dot;
    end
    if (out_de && out_r != 8'h20)
      fail("active video corrupted (caption leaked into out_de region)");
  end

  initial begin
    #200 rst_n = 1;
    // ~8 fields of caption lines
    #80_000_000;
    if (checked_f1 < 3) fail($sformatf("only %0d field-1 caption lines demodulated", checked_f1));
    if (checked_f2 < 3) fail($sformatf("only %0d field-2 caption lines demodulated", checked_f2));
    if (de_lines < 100) fail($sformatf("only %0d DE lines seen", de_lines));
    if (errors == 0)
      $display("PASS: cc_e2e_tb — %0d field-1 + %0d field-2 caption lines demodulated at the pins, line 21, correct slots; %0d DE lines x 720 enables",
               checked_f1, checked_f2, de_lines);
    else begin
      $display("FAIL: cc_e2e_tb — %0d error(s)", errors);
      $fatal(1);
    end
    $finish;
  end

endmodule
