/*
 * csync_field_tb.sv — does the framework's composite sync, built from THIS core's
 * interlaced main raster, give a television's vertical sync separator the same
 * trigger point in both fields?
 *
 * WHY (2026-09-03, the RGBS / YPbPr field reports): a CRT or a scaler on
 * composite sync (SCART RGBS, sync-on-Y) derives vertical timing by INTEGRATING
 * the sync signal — a low-pass filter and a threshold. The two fields of a 2:1
 * interlaced raster must trigger that integrator exactly half a line apart
 * (262.5 lines vsync-to-vsync) or the fields do not interleave: the second field's
 * lines land on top of the first field's instead of between them, which reads as
 * line-pairing jitter / "sawtooth" edges. Broadcast sync carries equalizing pulses
 * for exactly this reason; the framework `csync` module (sys/sys_top.v) carries
 * none and serrates at line rate. Every other MiSTer 480i core survives that, so
 * the question is whether OUR vsync placement (field A's vsync begins at active
 * dot 0, i.e. ~4.5 us after hsync, field B's mid-line) leaves the integrator the
 * same pre-charge in both fields. This bench MEASURES it instead of guessing.
 *
 * Chain under test: rtl/mpeg2/syncgen.v with the interlaced modeline exactly as
 * syncgen sees it (pixel repetition doubled, half-line 858) -> the REAL sys_top.v
 * `csync` module (extracted at run time by bench/dvd/run_csync_field.sh, since
 * sys_top.v cannot be compiled standalone) -> a first-order RC integrator sampled at 27 MHz (tau ~ 40 us, the classic
 * vertical-integrator value) with a Schmitt threshold (60 % / 30 %).
 *
 * Two separator models, because real sets differ:
 *   - a BROAD-PULSE WIDTH detector (what digital sync processors and modern jungle
 *     chips do): vertical = the leading edge of the first sync pulse longer than
 *     ~20 us. This is the PASS criterion: [1] its triggers must be EXACTLY 450450
 *     clk27 apart (262.5 lines of 1716) every field, and [2] each field's first
 *     broad pulse must be at least a standard broad pulse wide (27 us) so no
 *     plausible threshold can reject one field's and accept the other's;
 *   - an RC INTEGRATOR (tau ~ 40 us, Schmitt 60/30 %): reported, not gated. Its
 *     per-field trigger asymmetry is inherent to the framework's LINE-RATE
 *     serrations (every MiSTer 480i core has it) — printed so the docs carry a
 *     number.
 *   [3] hsync cadence 1716 clk27, vsync width 3 lines in both fields (raster sanity).
 * FINDING (2026-09-03, why syncgen.v anchors vsync on the hsync edge): with the
 * old dot-0 reference field B's first broad pulse was only ~18 us (below many
 * detectors' threshold, borderline for the rest) against field A's ~50 us — a
 * set could lock a line late on field B or flip between the two readings field
 * to field. Anchored: ~59 us / ~27 us.
 *
 * Build/run: bash bench/dvd/run_csync_field.sh
 */
`include "timescale.v"

// The framework csync module is extracted from sys/sys_top.v at run time into
// bench/dvd/csync_ref_gen.v (module csync_ref) by run_csync_field.sh.

module csync_field_tb;

  reg clk = 0; always #18.5 clk = ~clk;      // 27 MHz
  reg rst = 0;

  wire [11:0] h_pos, v_pos;
  wire        pixel_en, h_sync, v_sync, c_sync_unused, h_blank, v_blank;

  // The interlaced main raster as sync_gen sees it (after syncgen_intf's pixrep
  // doubling of the dvd/emu.sv modeline walk): 1716 dots/line, hsync 1471..1595,
  // 1440 active, 262/263-line fields, vsync lines 244..246, half-line 858.
  sync_gen dut (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .horizontal_size(14'd1440), .vertical_size(14'd480),
    .display_horizontal_size(14'd0), .display_vertical_size(14'd0),
    .horizontal_resolution(12'd1440),
    .horizontal_sync_start(12'd1471), .horizontal_sync_end(12'd1595),
    .horizontal_length(12'd1715),
    .vertical_resolution(12'd480),
    .vertical_sync_start(12'd243), .vertical_sync_end(12'd246),
    .horizontal_halfline(12'd858), .vertical_length(12'd261),
    .interlaced(1'b1), .clip_display_size(1'b0),
    .h_pos(h_pos), .v_pos(v_pos), .pixel_en(pixel_en),
    .h_sync(h_sync), .v_sync(v_sync), .c_sync(c_sync_unused),
    .h_blank(h_blank), .v_blank(v_blank));

  // The framework chain: sync_fix normalises both syncs to active-high pulses
  // (sync_gen already emits them that way), then csync XORs them. The pin carries
  // ~csync, so "asserted" below means csync == 1.
  wire cs;
  csync_ref csync_i (.clk(clk), .hsync(h_sync), .vsync(v_sync), .csync(cs));

  // ---- the television: first-order RC integrator + threshold -----------------
  // v += (x - v) / N per 27 MHz sample; N = tau * 27e6. tau = 40 us -> N = 1080.
  localparam integer N_TAU = 1080;
  localparam integer LINE  = 1716;
  localparam integer FIELD = 450450;               // 262.5 * 1716
  localparam integer TOL   = 86;                   // 0.05 line
  real     integ = 0.0;
  reg      trig_q = 1'b0;
  // Schmitt threshold, like a real separator: fire above 60 %, re-arm below 30 %
  // (the line-rate serration gaps ripple the integrator by ~10 % near the
  // threshold; a bare comparator double-triggers on them).
  reg      trig = 1'b0;
  always @(posedge clk) begin
    if (integ > 0.6)      trig <= 1'b1;
    else if (integ < 0.3) trig <= 1'b0;
  end

  integer  dot = 0;
  integer  last_trig = -1, last_hs = -1, last_vs = -1;
  integer  sp_a = -1, sp_b = -1;                   // the two alternating spacings
  integer  n_trig = 0, bad = 0, bad_hs = 0, bad_vsw = 0;
  integer  vs_start_off_a = -1, vs_start_off_b = -1;
  integer  vs_width = 0, vs_rise = -1;
  reg      hs_q = 0, vs_q = 0;

  // ---- broad-pulse width detector ------------------------------------------
  localparam integer BROAD_MIN = 540;              // 20 us: "longer than any hsync"
  localparam integer BROAD_STD = 734;              // 27.2 us: a standard broad pulse
  reg      cs_q = 0;
  integer  cs_rise = -1;                           // start of the current asserted pulse
  integer  wd_last = -1, wd_n = 0, wd_bad = 0, wd_sp_a = -1, wd_sp_b = -1;
  integer  first_broad_a = -1, first_broad_b = -1; // width of each field's FIRST broad pulse
  reg      wd_armed = 1'b1;                        // re-armed once a field's syncs are back to hsync-rate
  integer  narrow_run = 0;
  always @(posedge clk) if (rst) begin
    cs_q <= cs;
    if (cs && !cs_q) cs_rise = dot;
    if (!cs && cs_q) begin                         // a sync pulse just ended: classify it
      if ((dot - cs_rise) >= BROAD_MIN) begin
        if (wd_armed) begin                        // FIRST broad pulse of this field
          wd_armed = 1'b0;
          if (v_pos[0] == 1'b0) first_broad_a = dot - cs_rise; else first_broad_b = dot - cs_rise;
          wd_n = wd_n + 1;
          if (wd_last >= 0 && wd_n > 2) begin
            if (wd_n[0]) wd_sp_a = cs_rise - wd_last; else wd_sp_b = cs_rise - wd_last;
            if ((cs_rise - wd_last) != FIELD) begin
              wd_bad = wd_bad + 1;
              if (wd_bad <= 6) $display("FAIL: broad-pulse trigger spacing %0d clk27 (expect exactly %0d) at dot %0d",
                                        cs_rise - wd_last, FIELD, dot);
            end
          end
          wd_last = cs_rise;
        end
        narrow_run = 0;
      end else begin
        narrow_run = narrow_run + 1;
        if (narrow_run >= 8) wd_armed = 1'b1;      // eight plain hsyncs = vsync is over
      end
    end
  end

  always @(posedge clk) if (rst) begin
    dot <= dot + 1;
    integ = integ + ((cs ? 1.0 : 0.0) - integ) / N_TAU;
    trig_q <= trig;
    hs_q   <= h_sync;
    vs_q   <= v_sync;

    if (h_sync && !hs_q) begin
      if (last_hs >= 0 && (dot - last_hs) != LINE) bad_hs = bad_hs + 1;
      last_hs = dot;
    end
    if (v_sync && !vs_q) begin
      vs_rise = dot;
      // where does this field's vsync begin, relative to the last hsync leading edge?
      if (v_pos[0] == 1'b0) vs_start_off_a = dot - last_hs; else vs_start_off_b = dot - last_hs;
    end
    if (!v_sync && vs_q) begin
      vs_width = dot - vs_rise;
      if (vs_width != 3 * LINE) bad_vsw = bad_vsw + 1;
    end

    if (trig && !trig_q) begin
      n_trig = n_trig + 1;
      if (last_trig >= 0 && n_trig > 3) begin        // let the integrator settle
        if (n_trig[0]) sp_a = dot - last_trig; else sp_b = dot - last_trig;
        if ((dot - last_trig) > FIELD + TOL || (dot - last_trig) < FIELD - TOL) begin
          bad = bad + 1;
          if (bad <= 6) $display("FAIL: integrator trigger spacing %0d clk27 (expect %0d +/- %0d) at dot %0d",
                                 dot - last_trig, FIELD, TOL, dot);
        end
      end
      last_trig = dot;
    end
  end

  initial begin
    #500 rst = 1;
    // 12 fields
    repeat (12 * FIELD) @(posedge clk);
    $display("csync_field_tb: hsync %0d clk27, vsync width %0d clk27 (%0d lines)",
             LINE, vs_width, vs_width / LINE);
    $display("csync_field_tb: vsync begins %0d clk27 after the hsync leading edge on field A, %0d on field B (half line = %0d)",
             vs_start_off_a, vs_start_off_b, LINE / 2);
    $display("csync_field_tb: first broad pulse per field: A %0d clk27 (%0d us), B %0d clk27 (%0d us); standard 734 (27 us)",
             first_broad_a, first_broad_a / 27, first_broad_b, first_broad_b / 27);
    $display("csync_field_tb: broad-pulse detector spacings: %0d / %0d clk27 (ideal %0d) over %0d triggers, %0d wrong",
             wd_sp_a, wd_sp_b, FIELD, wd_n, wd_bad);
    $display("csync_field_tb: RC integrator (tau=%0d clk27, Schmitt) spacings: %0d / %0d clk27 (ideal %0d) — informational, %0d outside +/-%0d",
             N_TAU, sp_a, sp_b, FIELD, bad, TOL);
    if (wd_bad == 0 && wd_n >= 8 && first_broad_a >= BROAD_STD && first_broad_b >= BROAD_STD
        && bad_hs == 0 && bad_vsw == 0)
      $display("PASS: csync_field_tb — both fields present a >= standard first broad pulse and trigger a width detector exactly 262.5 lines apart");
    else begin
      $display("FAIL: csync_field_tb — %0d bad width-detector spacings (%0d triggers), first broad A=%0d B=%0d (need >= %0d), %0d bad hsync, %0d bad vsync widths",
               wd_bad, wd_n, first_broad_a, first_broad_b, BROAD_STD, bad_hs, bad_vsw);
      $fatal(1);
    end
    $finish;
  end

endmodule
