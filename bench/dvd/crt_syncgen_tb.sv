`timescale 1ns/1ps
//
// crt_syncgen_tb.sv — verify the N64-model CRT 2:1 interlace in rtl/mpeg2/syncgen.v
// (DVD-FORK FIX, 2026-07-05) and the non-CRT regression paths.
//
// A CRT locks 2:1 interlace only if vsync-to-vsync spacing is EXACTLY 262.5 lines
// every field (NTSC: 525-line odd frame total). The upstream syncgen only pulse-
// delayed the vsync edge inside fixed equal-length fields (even total) — HW-proven
// never to lock. The fix (armed by interlaced && horizontal_halfline != 0) is the
// N64 recipe: per-field totals alternate 262/263 AND the vsync line-counter
// reference samples at dot `halfline` on one field (dot 0 on the other).
//
// The single decisive invariant: consecutive vsync rising edges must be
// 262.5 * 858 = 225225 dots apart, EVERY field. 225225 is not a multiple of the
// 858-dot line, so constant spacing is only possible if every other vsync begins
// mid-line — this one check proves the half-line, the alternating totals, and the
// odd frame total simultaneously. Also checked: constant 858-dot hsync cadence,
// exactly 3-line vsync width in BOTH fields, 240 active lines per field with
// correct alternating v_pos parity, and bit-exact-shaped behavior of the two
// legacy modes (progressive 480p, HDMI-480i) that must not regress.
//
// PHASES 2/2b/4/5 (added 2026-08-02) assert the OTHER rate invariant this modeline
// family has to satisfy: EVERY raster period must equal the true content rate TO THE
// DOT, because the audio NCO is a fixed 48 kHz off the same crystal (nco_trim retired)
// — any raster-rate error is a permanent, linear A/V drift that nothing downstream can
// correct. This TB is the guard for all six shipped rasters:
//     480p     858 x 525            = 450,450   -> 59.94006  (PHASE 3)
//     HDMI480i (262+263) x 1716     = 900,900   -> 29.97003  (PHASE 2)
//     HDMI576i (312+313) x 1728     = 1,080,000 -> 25.000    (PHASE 2b)
//     CRT 480i 262.5 x 1716/field   = 900,900   -> 29.97003  (PHASE 1)
//     Film 24p 875 x 1287           = 1,126,125 -> 23.976024 (PHASE 4)
//     Film 25p 864 x 1250           = 1,080,000 -> 25.000    (PHASE 5)
// Audited 2026-08-02: only Film 24p was wrong — it shipped 858x1313 = 23.96689 Hz
// (0.0381% slow = audio ~1.37 s/hour ahead); fixed to 875x1287. See dvd/emu.sv
// REG_WR_HOR and docs/film_24p_plan.md §10.
//
// Build:
//   iverilog -g2012 -o bench/dvd/crt_syncgen_sim \
//       rtl/mpeg2/syncgen.v bench/dvd/crt_syncgen_tb.sv
//   vvp bench/dvd/crt_syncgen_sim
//
`include "timescale.v"

module crt_syncgen_tb;

  reg         clk = 0, clk_en = 1, rst = 0;
  reg  [13:0] horizontal_size = 14'd720, vertical_size = 14'd480;
  reg  [13:0] display_horizontal_size = 14'd0, display_vertical_size = 14'd0;
  reg  [11:0] horizontal_resolution, horizontal_sync_start, horizontal_sync_end, horizontal_length;
  reg  [11:0] vertical_resolution, vertical_sync_start, vertical_sync_end, horizontal_halfline, vertical_length;
  reg         interlaced, clip_display_size = 0;
  wire [11:0] h_pos, v_pos;
  wire        pixel_en, h_sync, v_sync, c_sync, h_blank, v_blank;

  sync_gen dut (
    .clk(clk), .clk_en(clk_en), .rst(rst),
    .horizontal_size(horizontal_size), .vertical_size(vertical_size),
    .display_horizontal_size(display_horizontal_size), .display_vertical_size(display_vertical_size),
    .horizontal_resolution(horizontal_resolution),
    .horizontal_sync_start(horizontal_sync_start), .horizontal_sync_end(horizontal_sync_end),
    .horizontal_length(horizontal_length),
    .vertical_resolution(vertical_resolution),
    .vertical_sync_start(vertical_sync_start), .vertical_sync_end(vertical_sync_end),
    .horizontal_halfline(horizontal_halfline), .vertical_length(vertical_length),
    .interlaced(interlaced), .clip_display_size(clip_display_size),
    .h_pos(h_pos), .v_pos(v_pos), .pixel_en(pixel_en),
    .h_sync(h_sync), .v_sync(v_sync), .c_sync(c_sync),
    .h_blank(h_blank), .v_blank(v_blank));

  always #5 clk = ~clk;

  integer errors = 0;

  // ---- dot counter + edge trackers -----------------------------------------
  integer dot = 0;                    // free-running enabled-dot index
  reg     hs_d = 0, vs_d = 0;
  integer last_hs_rise = -1, last_vs_rise = -1, vs_rise_dot = -1;
  integer hs_period, vs_period, vs_width;
  integer vs_rises = 0;

  // per-check accumulators (reset per phase)
  integer bad_hs = 0, bad_vs_spacing = 0, bad_vs_width = 0, bad_vs_pair = 0;
  integer exp_vs_pair = 0;            // 0 = skip the pair-sum check this phase
  integer prev_vs_period = -1;
  integer exp_vs_spacing = 0;         // 0 = skip spacing check this phase
  integer exp_vs_width   = 0;
  integer exp_hs_period  = 858;       // dots/line for the phase (Film 24p uses 875)
  integer settle_rises   = 0;         // ignore the first N vsync intervals

  always @(posedge clk) if (rst && clk_en) begin
    dot <= dot + 1;
    hs_d <= h_sync;
    vs_d <= v_sync;
    if (h_sync && !hs_d) begin
      if (last_hs_rise >= 0) begin
        hs_period = dot - last_hs_rise;
        if (hs_period != exp_hs_period) begin
          if (bad_hs < 5) $display("FAIL: hsync period %0d dots at dot %0d (expect %0d)", hs_period, dot, exp_hs_period);
          bad_hs = bad_hs + 1;
        end
      end
      last_hs_rise = dot;
    end
    if (v_sync && !vs_d) begin
      vs_rises = vs_rises + 1;
      if (last_vs_rise >= 0 && vs_rises > settle_rises) begin
        vs_period = dot - last_vs_rise;
        if (exp_vs_spacing != 0 && vs_period != exp_vs_spacing) begin
          if (bad_vs_spacing < 8) $display("FAIL: vsync spacing %0d dots at dot %0d (expect %0d)", vs_period, dot, exp_vs_spacing);
          bad_vs_spacing = bad_vs_spacing + 1;
        end
        // PAIR check (alternating field totals): individual field spacings differ by
        // one line, but every CONSECUTIVE PAIR must sum to the exact frame period —
        // that sum is the A/V-rate invariant for an interlaced raster.
        if (exp_vs_pair != 0) begin
          if (prev_vs_period >= 0 && (vs_period + prev_vs_period) != exp_vs_pair) begin
            if (bad_vs_pair < 8) $display("FAIL: field pair %0d+%0d = %0d dots at dot %0d (expect %0d)",
                                          prev_vs_period, vs_period, vs_period + prev_vs_period, dot, exp_vs_pair);
            bad_vs_pair = bad_vs_pair + 1;
          end
          prev_vs_period = vs_period;
        end
      end
      last_vs_rise = dot;
      vs_rise_dot = dot;
    end
    if (!v_sync && vs_d) begin
      if (vs_rise_dot >= 0 && vs_rises > settle_rises && exp_vs_width != 0) begin
        vs_width = dot - vs_rise_dot;
        if (vs_width != exp_vs_width) begin
          if (bad_vs_width < 8) $display("FAIL: vsync width %0d dots at dot %0d (expect %0d)", vs_width, dot, exp_vs_width);
          bad_vs_width = bad_vs_width + 1;
        end
      end
    end
  end

  // ---- active-line bookkeeping (CRT phase): v_pos parity + lines per field --
  // A "displayed line" is a line with pixel_en asserted at least once. In a field
  // scan all displayed v_pos values must share one parity; parity alternates
  // between consecutive fields; 240 displayed lines per field.
  integer lines_this_field = 0, parity_errs = 0, field_line_errs = 0, fields_seen = 0;
  integer cur_parity = -1, prev_field_parity = -1, parity_alt_errs = 0;
  reg     track_fields = 0;   // interlaced-phase-only checks (480p legitimately fails them)
  reg [11:0] vpos_line = 12'hFFF;
  always @(posedge clk) if (rst && clk_en && track_fields) begin
    if (pixel_en && vpos_line != v_pos) begin
      vpos_line <= v_pos;
      lines_this_field = lines_this_field + 1;
      if (cur_parity < 0) cur_parity = v_pos[0];
      else if (v_pos[0] !== cur_parity[0]) parity_errs = parity_errs + 1;
    end
    // field boundary = vsync rise
    if (v_sync && !vs_d) begin
      if (fields_seen > 1) begin  // first partial field ignored
        if (lines_this_field != 240) begin
          if (field_line_errs < 5) $display("FAIL: field displayed %0d lines (expect 240)", lines_this_field);
          field_line_errs = field_line_errs + 1;
        end
        if (prev_field_parity >= 0 && cur_parity >= 0 && (cur_parity == prev_field_parity)) begin
          if (parity_alt_errs < 5) $display("FAIL: consecutive fields share v_pos parity %0d (no interleave)", cur_parity);
          parity_alt_errs = parity_alt_errs + 1;
        end
      end
      prev_field_parity = cur_parity;
      fields_seen = fields_seen + 1;
      lines_this_field = 0;
      cur_parity = -1;
      vpos_line = 12'hFFF;
    end
  end

  task reset_trackers; begin
    dot = 0; last_hs_rise = -1; last_vs_rise = -1; vs_rise_dot = -1; vs_rises = 0;
    bad_hs = 0; bad_vs_spacing = 0; bad_vs_width = 0; bad_vs_pair = 0; prev_vs_period = -1;
    lines_this_field = 0; parity_errs = 0; field_line_errs = 0; fields_seen = 0;
    cur_parity = -1; prev_field_parity = -1; parity_alt_errs = 0; vpos_line = 12'hFFF;
  end endtask

  task waitclk(input integer n); integer i; begin for (i=0;i<n;i=i+1) @(posedge clk); end endtask

  // one NTSC field ~= 262.5*858 = 225225 dots
  localparam integer FIELD_DOTS = 225225;
  // exact film frame periods at the fixed 27 MHz dot clock (see PHASE 4/5)
  localparam integer FILM24_DOTS = 875 * 1287;   // 27e6 * 1001/24000 = 1126125
  localparam integer FILM25_DOTS = 864 * 1250;   // 27e6 / 25         = 1080000
  // exact INTERLACED frame periods (a field PAIR), post-pixel-repetition
  localparam integer ILACE480_DOTS = (262 + 263) * 1716;  // 27e6*1001/30000 = 900900
  localparam integer ILACE576_DOTS = (312 + 313) * 1728;  // 27e6/25         = 1080000

  initial begin
    // =======================================================================
    // PHASE 1 — CRT 480i (the new model): halfline=429, interlaced, len=261
    // =======================================================================
    rst = 0;
    horizontal_resolution = 12'd720; horizontal_sync_start = 12'd735;
    horizontal_sync_end   = 12'd797; horizontal_length     = 12'd857;
    vertical_resolution   = 12'd479; vertical_sync_start   = 12'd244;
    vertical_sync_end     = 12'd247; vertical_length       = 12'd261;
    horizontal_halfline   = 12'd429; interlaced            = 1'b1;
    waitclk(8); rst = 1;
    reset_trackers;
    exp_vs_spacing = FIELD_DOTS;      // 262.5 lines — THE 2:1 lock invariant
    exp_vs_width   = 3 * 858;         // 3.0 lines, both fields
    settle_rises   = 2;
    track_fields   = 1;
    waitclk(FIELD_DOTS * 8);          // 8 fields = 4 frames
    if (bad_hs || bad_vs_spacing || bad_vs_width || parity_errs || field_line_errs || parity_alt_errs) begin
      errors = errors + 1;
      $display("[CRT 480i] FAIL: hs=%0d vs_spacing=%0d vs_width=%0d parity=%0d lines=%0d alt=%0d",
               bad_hs, bad_vs_spacing, bad_vs_width, parity_errs, field_line_errs, parity_alt_errs);
    end else
      $display("[CRT 480i] PASS: vsync every 225225 dots (262.5 lines) x%0d, 3.0-line width, 240 lines/field, parity alternates over %0d fields",
               vs_rises, fields_seen);

    track_fields = 0;
    // =======================================================================
    // PHASE 2 — HDMI fields 480i (Video Output = Interlaced; was Interlaced Out O[10:9]), EXACT-RATE check.
    //
    // Driven with the values syncgen ACTUALLY sees in this mode, i.e. AFTER
    // syncgen_intf's pixel-repetition doubling (`x -> {x[10:0],1'b1}` = 2x+1,
    // rtl/mpeg2/syncgen_intf.v:238-260) of the emu.sv modeline writes:
    //     hres 720->1441  hsync 735..797->1471..1595  hlen 857->1715 (1716 dots)
    //     halfline 0 -> **1**   <-- 2*0+1, NOT 0
    // That last one is a trap worth knowing: the modeline writes halfline=0 (so an
    // HDMI receiver doesn't hunt), but pixrep turns it into 1, which is NONZERO —
    // so `crt_ilace` is already armed and the field totals already ALTERNATE
    // 262/263. That is what makes the frame pair exactly 525*1716 = 900,900 clk27
    // = 2 * 450,450 = 29.97 fps. The rate is therefore already correct, but it
    // holds only by accident of that doubling; syncgen now arms the alternation on
    // `interlaced` alone (2026-08-02) so it cannot silently regress, and this phase
    // pins the invariant. The 1-dot vsync reference shift (dot 0 vs dot 1) is
    // harmless and is why individual field spacings are checked as a PAIR.
    // =======================================================================
    rst = 0;
    horizontal_resolution = 12'd1441; horizontal_sync_start = 12'd1471;
    horizontal_sync_end   = 12'd1595; horizontal_length     = 12'd1715; // 1716 dots
    vertical_resolution   = 12'd479;  vertical_sync_start   = 12'd244;
    vertical_sync_end     = 12'd247;  vertical_length       = 12'd261;  // 262/263 fields
    horizontal_halfline   = 12'd1;    interlaced            = 1'b1;     // pixrep: 2*0+1
    waitclk(8); rst = 1;
    reset_trackers;
    exp_hs_period  = 1716;
    exp_vs_spacing = 0;                 // spacings alternate — check the PAIR
    exp_vs_pair    = ILACE480_DOTS;     // == 27e6 * 1001/60000 * 2, to the dot
    exp_vs_width   = 3 * 1716;
    settle_rises   = 3;
    waitclk(ILACE480_DOTS * 4);
    if (ILACE480_DOTS != 900900) begin
      errors = errors + 1;
      $display("[HDMI 480i] FAIL: expectation wrong — %0d != 900900", ILACE480_DOTS);
    end
    if (bad_hs || bad_vs_pair || bad_vs_width) begin
      errors = errors + 1;
      $display("[HDMI 480i] FAIL: hs=%0d vs_pair=%0d vs_width=%0d (raster is NOT 30000/1001 => A/V will drift)",
               bad_hs, bad_vs_pair, bad_vs_width);
    end else
      $display("[HDMI 480i] PASS: field pair %0d dots = 27 MHz * 1001/30000 = 29.970030 fps EXACT (262+263 lines)",
               ILACE480_DOTS);
    exp_vs_pair = 0;

    // =======================================================================
    // PHASE 2b — HDMI Interlaced Out (O[10:9]) PAL 576i, same invariant.
    // Post-pixrep: hlen 863->1727 (1728 dots), hsync 732..795 -> 1465..1591.
    // 312+313 = 625 lines * 1728 = 1,080,000 = 27e6/25 => 25.000 fps EXACT.
    // (dvd/emu.sv's modeline comment flagged "312.5 would be exact — 312 is the
    //  closer int" as an open sim-verify item; the alternation is what closes it.)
    // =======================================================================
    rst = 0;
    horizontal_sync_start = 12'd1465; horizontal_sync_end = 12'd1591;
    horizontal_length     = 12'd1727;                       // 1728 dots
    vertical_resolution   = 12'd575;  vertical_sync_start = 12'd292;
    vertical_sync_end     = 12'd295;  vertical_length     = 12'd311; // 312/313 fields
    waitclk(8); rst = 1;
    reset_trackers;
    exp_hs_period  = 1728;
    exp_vs_spacing = 0;
    exp_vs_pair    = ILACE576_DOTS;
    exp_vs_width   = 3 * 1728;
    settle_rises   = 3;
    waitclk(ILACE576_DOTS * 4);
    if (ILACE576_DOTS != 1080000) begin
      errors = errors + 1;
      $display("[HDMI 576i] FAIL: expectation wrong — %0d != 1080000", ILACE576_DOTS);
    end
    if (bad_hs || bad_vs_pair || bad_vs_width) begin
      errors = errors + 1;
      $display("[HDMI 576i] FAIL: hs=%0d vs_pair=%0d vs_width=%0d", bad_hs, bad_vs_pair, bad_vs_width);
    end else
      $display("[HDMI 576i] PASS: field pair %0d dots = 27 MHz / 25 = 25.000000 fps EXACT (312+313 lines)",
               ILACE576_DOTS);
    exp_vs_pair = 0;
    exp_hs_period = 858;

    // =======================================================================
    // PHASE 3 — 480p progressive regression: vsync spacing 525 lines constant.
    // =======================================================================
    rst = 0;
    // restore the full NTSC 480p horizontal modeline — the interlaced phases above
    // leave the post-pixel-repetition (doubled) values loaded.
    horizontal_resolution = 12'd720; horizontal_sync_start = 12'd735;
    horizontal_sync_end   = 12'd797; horizontal_length     = 12'd857;
    vertical_resolution = 12'd480; vertical_sync_start = 12'd488;
    vertical_sync_end   = 12'd494; vertical_length     = 12'd524;
    horizontal_halfline = 12'd0;   interlaced          = 1'b0;
    waitclk(8); rst = 1;
    reset_trackers;
    exp_vs_spacing = 525 * 858;
    exp_vs_width   = 6 * 858;      // (494-488) lines
    settle_rises   = 2;
    waitclk(525 * 858 * 4);
    if (bad_hs || bad_vs_spacing || bad_vs_width) begin
      errors = errors + 1;
      $display("[480p     ] FAIL: hs=%0d vs_spacing=%0d vs_width=%0d", bad_hs, bad_vs_spacing, bad_vs_width);
    end else
      $display("[480p     ] PASS: progressive timing unchanged (spacing 525 lines const)");

    // =======================================================================
    // PHASE 4 — Film 24p EXACT RATE (DVD-FORK FIX 2026-08-02, A/V drift).
    //
    // The audio NCO is a fixed 48 kHz off the same 27 MHz crystal (nco_trim
    // retired), so A/V stays locked over a 2-hour title ONLY if the raster
    // period equals the true content rate to the DOT. NTSC film = 24000/1001
    // fps => 27e6 * 1001/24000 = 1,126,125 dots/frame, exactly.
    //
    // The v1 modeline (858 x 1313 = 1,126,554) was 429 dots/frame long =
    // 0.0381% slow = audio walking ~1.37 s/hour ahead. 1,126,125 is ODD, so
    // no even htotal (858) can ever divide it; 875 x 1287 is the exact
    // factorization closest to the standard line. This phase FAILS on the
    // old numbers and passes only on an exact-rate modeline.
    // =======================================================================
    rst = 0;
    horizontal_resolution = 12'd720; horizontal_sync_start = 12'd735;
    horizontal_sync_end   = 12'd797; horizontal_length     = 12'd874;  // 875 dots/line
    vertical_resolution   = 12'd480; vertical_sync_start   = 12'd488;
    vertical_sync_end     = 12'd494; vertical_length       = 12'd1286; // 1287 lines/frame
    horizontal_halfline   = 12'd0;   interlaced            = 1'b0;
    waitclk(8); rst = 1;
    reset_trackers;
    exp_hs_period  = 875;
    exp_vs_spacing = FILM24_DOTS;      // == 27e6 * 1001/24000, to the dot
    exp_vs_width   = 6 * 875;          // (494-488) lines
    settle_rises   = 2;
    waitclk(FILM24_DOTS * 4);
    if (FILM24_DOTS != 1126125) begin  // guard the expectation itself
      errors = errors + 1;
      $display("[Film 24p ] FAIL: expectation wrong — %0d != 1126125", FILM24_DOTS);
    end
    if (bad_hs || bad_vs_spacing || bad_vs_width) begin
      errors = errors + 1;
      $display("[Film 24p ] FAIL: hs=%0d vs_spacing=%0d vs_width=%0d (raster is NOT 24000/1001 => A/V will drift)",
               bad_hs, bad_vs_spacing, bad_vs_width);
    end else
      $display("[Film 24p ] PASS: frame period %0d dots = 27 MHz * 1001/24000 = 23.976024 Hz EXACT (0 s/hour A/V drift)",
               FILM24_DOTS);
    exp_hs_period = 858;

    // =======================================================================
    // PHASE 5 — PAL 25p regression: 864 x 1250 = 1,080,000 = 27e6/25 exact.
    // (Included so the exact-rate invariant is asserted for BOTH film rates.)
    // =======================================================================
    rst = 0;
    horizontal_sync_start = 12'd732; horizontal_sync_end = 12'd795;
    horizontal_length     = 12'd863;                       // 864 dots/line
    vertical_resolution   = 12'd576; vertical_sync_start = 12'd581;
    vertical_sync_end     = 12'd586; vertical_length     = 12'd1249; // 1250 lines
    waitclk(8); rst = 1;
    reset_trackers;
    exp_hs_period  = 864;
    exp_vs_spacing = FILM25_DOTS;
    exp_vs_width   = 5 * 864;          // (586-581) lines
    settle_rises   = 2;
    waitclk(FILM25_DOTS * 3);
    if (FILM25_DOTS != 1080000) begin
      errors = errors + 1;
      $display("[Film 25p ] FAIL: expectation wrong — %0d != 1080000", FILM25_DOTS);
    end
    if (bad_hs || bad_vs_spacing || bad_vs_width) begin
      errors = errors + 1;
      $display("[Film 25p ] FAIL: hs=%0d vs_spacing=%0d vs_width=%0d", bad_hs, bad_vs_spacing, bad_vs_width);
    end else
      $display("[Film 25p ] PASS: frame period %0d dots = 27 MHz / 25 = 25.000000 Hz EXACT", FILM25_DOTS);

    if (errors == 0) $display("\n==== PASS: CRT 2:1 interlace locks (262.5-line vsync cadence), legacy modes unchanged, film rasters exact ====");
    else begin
      $display("\n==== FAIL: %0d phase(s) failed ====", errors);
      $fatal(1, "crt_syncgen_tb failed");   // non-zero exit (vvp masks plain $finish)
    end
    $finish;
  end

  initial begin
    #900_000_000;   // raised for the film + interlaced exact-rate phases
    $display("TIMEOUT"); $fatal(1, "crt_syncgen_tb timeout");
  end
endmodule
