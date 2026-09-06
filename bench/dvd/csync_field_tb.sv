/*
 * csync_field_tb.sv — what does the analog composite sync actually look like, and do
 * the two fields of the 2:1 raster present a television with the same thing?
 *
 * WHY (2026-09-03, the RGBS / YPbPr field reports; extended 2026-09-05 for
 * dvd/csync_smpte.sv): a CRT or a scaler on composite sync (SCART RGBS, sync-on-Y)
 * derives vertical timing by INTEGRATING the sync signal — a low-pass filter and a
 * threshold — or by measuring the width of the first broad pulse. The two fields of a
 * 2:1 interlaced raster must trigger that circuit exactly half a line apart (262.5
 * lines vsync-to-vsync) or the fields do not interleave: the second field's lines land
 * on top of the first field's instead of between them, which reads as line-pairing
 * jitter / "sawtooth" edges. Broadcast sync carries equalizing pulses for exactly this
 * reason.
 *
 * ★ THE MEASUREMENT THAT MOTIVATES THE WHOLE CHANGE. The framework `csync`
 * (sys/sys_top.v) carries no equalizing pulses and serrates at LINE rate, so the two
 * fields — whose vsyncs start half a line apart while the serration grid does not move
 * with them — present first broad pulses of ~50 us and ~18 us. 18 us is at or below the
 * threshold of a width-based separator: a set can lock a line late on one field, or flip
 * between the two readings field to field. dvd/csync_smpte.sv emits the SMPTE 170M /
 * BT.470 block instead, and this bench gates that it did.
 *
 * ARMS (+arm=0 SMPTE, 1 2H serrations, 2 Stock; +pal=1 for the 625-line raster):
 *
 *   [G1] STOCK arm: the mux output must equal the real framework module's output on
 *        EVERY clock, for the whole run. "Stock is bit-identical" is a claim about the
 *        shipped escape hatch, so it is checked as an equality, not asserted in a
 *        comment. (bench/dvd/csync_extract.sh additionally CHECKSUMS the module it
 *        lifted out of sys_top.v, so the claim cannot be quietly redefined.)
 *   [G3] SMPTE / 2H arms: away from the vertical interval the generated sync must ALSO
 *        equal stock's, clock for clock. Outside the block the module is a one-clock
 *        hsync delay by construction, so this catches a wrong pipeline depth, an
 *        inverted polarity or a dropped hsync — the integration mistakes that a
 *        pulse-shape census would sail straight past.
 *   [G4] SMPTE arm: the pulse census against SMPTE 170M Table 3 / BT.470 Table 2 —
 *        n_pre equalizing pulses, n_broad broad pulses, n_post equalizing pulses, each
 *        of the specified width, every leading edge on the half-line grid.
 *   [G5] FIELD CONGRUENCE, the gate that actually means "equalised": take each field's
 *        pulse list in a window anchored on ITS OWN first broad pulse, and require the
 *        two fields to be identical — same pulse count, same relative positions, same
 *        widths. ★ The anchor is a MEASURED feature of the waveform, not one of the
 *        module's constants, so this gate cannot degenerate into a restatement of the
 *        RTL (the failure mode that let the field-parity corrector defect ship green —
 *        docs/single_raster_analog.md §3.9).
 *   [G6] Both separator models, PER FIELD: the width detector's trigger spacing and the
 *        RC integrator's must each be 262.5 lines EVERY field, not merely in pairs.
 *        Gated on the SMPTE/2H arms. On the Stock arm the per-field asymmetry is the
 *        known defect, so it is asserted to be PRESENT — a bench that passed on both
 *        waveforms would not be distinguishing them.
 *   [G7] Raster sanity: hsync cadence, three-line raster vsync, one frame per field pair.
 *
 * RED arms are driven by run_csync_field.sh --red, which compiles sed-mutated copies of
 * dvd/csync_smpte.sv (block anchored on the plain line grid; equalizing pulses emitted
 * at broad width; the pre-equalizing segment dropped) plus a TB-side +red_lag, and
 * requires each to FAIL.
 *
 * Chain under test: rtl/mpeg2/syncgen.v with the interlaced modeline exactly as syncgen
 * sees it (pixel repetition applied) -> dvd/csync_smpte.sv, muxed against the REAL
 * sys_top.v `csync` module (extracted at run time by bench/dvd/csync_extract.sh) exactly
 * as sys/sys_top.v muxes them. The CS_PIPE delay sys_top applies is NOT modelled here —
 * both sources are one clock behind hsync at this point, which is the property that lets
 * one fixed delay serve both; bench/dvd/csync_pipe_tb.sv measures that delay through the
 * real scanlines/osd chain and pins it against sys_top's own constant.
 *
 * Build/run: bash bench/dvd/run_csync_field.sh [--red]
 */
`include "timescale.v"

// The framework csync module is extracted from sys/sys_top.v at run time into
// bench/dvd/csync_ref_gen.v (module csync_ref) by bench/dvd/csync_extract.sh.

module csync_field_tb;

  reg clk = 0; always #18.5 clk = ~clk;      // 27 MHz
  reg rst = 0;

  // ---- arm / standard selection --------------------------------------------------
  integer arm = 0;            // 0 SMPTE, 1 2H, 2 Stock
  integer pal = 0;
  integer tau_us = 40;
  integer red_lag = 0;        // RED: delay the generated sync one extra clock
  initial begin
    void'($value$plusargs("arm=%d", arm));
    void'($value$plusargs("pal=%d", pal));
    void'($value$plusargs("tau_us=%d", tau_us));
    void'($value$plusargs("red_lag=%d", red_lag));
  end

  // ---- the interlaced main raster, as sync_gen sees it ----------------------------
  // NTSC: emu writes htotal 857, hsync 735..797, halfline 429, vtotal 261, vsync
  // 244..247; syncgen_intf doubles the horizontal ones (2x+1 for start/end/length,
  // 2x for the halfline) under pixel repetition. PAL: 863 / 732..795 / 432 / 311 /
  // 292..295.
  wire [11:0] HLEN   = pal ? 12'd1727 : 12'd1715;
  wire [11:0] HSS    = pal ? 12'd1465 : 12'd1471;
  wire [11:0] HSE    = pal ? 12'd1591 : 12'd1595;
  wire [11:0] HALF   = pal ? 12'd864  : 12'd858;
  wire [11:0] VLEN   = pal ? 12'd311  : 12'd261;
  wire [11:0] VSS    = pal ? 12'd292  : 12'd244;
  wire [11:0] VSE    = pal ? 12'd295  : 12'd247;
  wire [13:0] VSIZE  = pal ? 14'd576  : 14'd480;

  wire [11:0] h_pos, v_pos;
  wire        pixel_en, h_sync, v_sync, c_sync_unused, h_blank, v_blank;

  sync_gen dut (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .horizontal_size(14'd1440), .vertical_size(VSIZE),
    .display_horizontal_size(14'd0), .display_vertical_size(14'd0),
    .horizontal_resolution(12'd1440),
    .horizontal_sync_start(HSS), .horizontal_sync_end(HSE),
    .horizontal_length(HLEN),
    .vertical_resolution(VSIZE[11:0]),
    .vertical_sync_start(VSS), .vertical_sync_end(VSE),
    .horizontal_halfline(HALF), .vertical_length(VLEN),
    .interlaced(1'b1), .clip_display_size(1'b0),
    .h_pos(h_pos), .v_pos(v_pos), .pixel_en(pixel_en),
    .h_sync(h_sync), .v_sync(v_sync), .c_sync(c_sync_unused),
    .h_blank(h_blank), .v_blank(v_blank));

  // ---- the two composite-sync sources, and sys_top's mux --------------------------
  wire cs_stock;
  csync_ref csync_i (.clk(clk), .hsync(h_sync), .vsync(v_sync), .csync(cs_stock));

  wire cs_gen, cs_gen_en;
  csync_smpte gen_i (
    .clk(clk), .rst_n(rst),
    .mode(arm[1:0]), .en(1'b1), .pal(pal != 0),
    .h_sync(h_sync), .v_pos(v_pos),
    .cs(cs_gen), .cs_en(cs_gen_en));

  reg cs_gen_d = 0;
  always @(posedge clk) cs_gen_d <= cs_gen;      // RED: an extra clock of pipeline
  wire cs_gen_eff = red_lag ? cs_gen_d : cs_gen;

  wire cs = cs_gen_en ? cs_gen_eff : cs_stock;

  // ---- expected geometry for the census -------------------------------------------
  integer EQ_W, BROAD_W, N_PRE, N_BROAD, N_POST;
  initial begin
    #1;
    EQ_W    = pal ? 63  : 62;
    BROAD_W = pal ? 737 : 731;
    // SMPTE 170M sys M: l = m = n = 3H  -> 6/6/6 half-lines.
    // BT.470 sys B/G/H/I: l = m = n = 2.5H -> 5/5/5.
    // The 2H arm keeps today's three-line vsync window and adds no equalizing pulses.
    N_BROAD = (arm == 0 && pal) ? 5 : 6;
    N_PRE   = (arm == 0) ? (pal ? 5 : 6) : 0;
    N_POST  = N_PRE;
  end

  localparam integer MAXP = 8192;
  integer p_rise [0:MAXP-1];
  integer p_wid  [0:MAXP-1];
  integer p_fld  [0:MAXP-1];
  integer np = 0;

  integer LINE, FIELD, FRAME;
  initial begin
    #1;
    LINE  = pal ? 1728 : 1716;
    FIELD = pal ? (1728*312 + 864) : (1716*262 + 858);   // 262.5 / 312.5 lines
    FRAME = 2*FIELD;
  end

  // ---- capture every composite-sync pulse ------------------------------------------
  integer dot = 0;
  reg     cs_q = 0;
  integer cs_rise = -1;
  always @(posedge clk) if (rst) begin
    dot  <= dot + 1;
    cs_q <= cs;
    if (cs && !cs_q) cs_rise = dot;
    if (!cs && cs_q && cs_rise >= 0 && np < MAXP) begin
      p_rise[np] = cs_rise;
      p_wid [np] = dot - cs_rise;
      p_fld [np] = v_pos[0];
      np = np + 1;
    end
  end

  // ---- [G1]/[G3] equality against the real framework module ------------------------
  // Stock arm: everywhere. SMPTE/2H arms: on picture lines only, i.e. clear of the
  // vertical interval — a region defined by the RASTER, not by the generator's own
  // block constants.
  integer eq_bad = 0, eq_n = 0;
  wire    picture_line = (v_pos[11:1] > 12'd20) && (v_pos[11:1] < (pal ? 12'd270 : 12'd220));
  always @(posedge clk) if (rst && dot > 4*LINE) begin
    if (arm == 2 || picture_line) begin
      eq_n = eq_n + 1;
      if (cs !== cs_stock) eq_bad = eq_bad + 1;
    end
  end

  // ---- [G6] separator model 1: broad-pulse width detector ---------------------------
  localparam integer BROAD_MIN = 540;              // 20 us: "longer than any hsync"
  integer wd_last = -1, wd_n = 0, wd_bad = 0, wd_pair_bad = 0, wd_prev = -1;
  integer wd_sp_a = -1, wd_sp_b = -1;
  integer first_broad_a = -1, first_broad_b = -1;
  integer fb_rise_a = -1, fb_rise_b = -1;
  // ⚠ The detector above only counts pulses >= BROAD_MIN (20 us), which is the point:
  // that IS what a width-based separator does, and a field whose first broad pulse falls
  // under the threshold has its trigger land a line late. So the RAW first
  // wider-than-an-hsync pulse is measured separately — otherwise the log reports the
  // pulse the detector happened to lock onto and hides the one that caused the miss.
  localparam integer WIDE_MIN = 250;               // ~9 us: wider than any hsync
  integer first_wide_a = -1, first_wide_b = -1;
  reg     wide_armed = 1'b1;
  integer wide_narrow = 0;
  reg     wd_armed = 1'b1;
  integer narrow_run = 0;
  localparam integer TOL_WD = 4;
  always @(posedge clk) if (rst) begin
    if (!cs && cs_q) begin
      if ((dot - cs_rise) >= WIDE_MIN) begin
        if (wide_armed) begin
          wide_armed = 1'b0;
          if (v_pos[0] == 1'b0) first_wide_a = dot - cs_rise;
          else                  first_wide_b = dot - cs_rise;
        end
        wide_narrow = 0;
      end else begin
        wide_narrow = wide_narrow + 1;
        if (wide_narrow >= 8) wide_armed = 1'b1;
      end
      if ((dot - cs_rise) >= BROAD_MIN) begin
        if (wd_armed) begin
          wd_armed = 1'b0;
          if (v_pos[0] == 1'b0) begin first_broad_a = dot - cs_rise; fb_rise_a = cs_rise; end
          else                  begin first_broad_b = dot - cs_rise; fb_rise_b = cs_rise; end
          wd_n = wd_n + 1;
          if (wd_last >= 0 && wd_n > 2) begin
            if (wd_n[0]) wd_sp_a = cs_rise - wd_last; else wd_sp_b = cs_rise - wd_last;
            // PER FIELD (the gate for SMPTE/2H): every spacing is 262.5 lines.
            if ((cs_rise - wd_last) > FIELD + TOL_WD || (cs_rise - wd_last) < FIELD - TOL_WD)
              wd_bad = wd_bad + 1;
            // PER PAIR (holds for any serration rate, so it is gated on every arm).
            if (wd_prev >= 0 && ((wd_prev + (cs_rise - wd_last)) > FRAME + TOL_WD ||
                                 (wd_prev + (cs_rise - wd_last)) < FRAME - TOL_WD))
              wd_pair_bad = wd_pair_bad + 1;
            wd_prev = cs_rise - wd_last;
          end
          wd_last = cs_rise;
        end
        narrow_run = 0;
      end else begin
        narrow_run = narrow_run + 1;
        if (narrow_run >= 8) wd_armed = 1'b1;      // eight plain hsyncs = the interval is over
      end
    end
  end

  // ---- [G6] separator model 2: RC integrator + Schmitt threshold ---------------------
  // v += (x - v) / N per 27 MHz sample; N = tau * 27e6. tau = 40 us -> N = 1080.
  wire [31:0] N_TAU = tau_us * 27;
  real     integ = 0.0;
  reg      trig = 1'b0, trig_q = 1'b0;
  always @(posedge clk) begin
    if (integ > 0.6)      trig <= 1'b1;
    else if (integ < 0.3) trig <= 1'b0;
  end
  integer last_trig = -1, n_trig = 0, int_bad = 0, sp_a = -1, sp_b = -1;
  localparam integer TOL_INT = 86;                 // 0.05 line

  // ---- [G7] raster sanity -----------------------------------------------------------
  integer last_hs = -1, bad_hs = 0, bad_vsw = 0, vs_rise = -1, vs_width = 0;
  integer vs_off_a = -1, vs_off_b = -1;
  reg     hs_q = 0, vs_q = 0;

  always @(posedge clk) if (rst) begin
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
      if (v_pos[0] == 1'b0) vs_off_a = dot - last_hs; else vs_off_b = dot - last_hs;
    end
    if (!v_sync && vs_q) begin
      vs_width = dot - vs_rise;
      if (vs_width != 3 * LINE) bad_vsw = bad_vsw + 1;
    end

    if (trig && !trig_q) begin
      n_trig = n_trig + 1;
      if (last_trig >= 0 && n_trig > 3) begin
        if (n_trig[0]) sp_a = dot - last_trig; else sp_b = dot - last_trig;
        if ((dot - last_trig) > FIELD + TOL_INT || (dot - last_trig) < FIELD - TOL_INT)
          int_bad = int_bad + 1;
      end
      last_trig = dot;
    end
  end

  // ---- analysis ---------------------------------------------------------------------
  // Everything below runs on the captured pulse list, which is far easier to reason
  // about (and to print when something fails) than streaming state machines.

  integer i, j, k;
  integer anchor_a, anchor_b;          // index of each field's first broad pulse
  integer cen_bad, cen_n;
  integer cong_bad, cong_n;
  integer nA, nB;
  integer relA, relB;

  // find the index of the pulse whose rise == `r`
  function integer idx_of(input integer r);
    integer m;
    begin
      idx_of = -1;
      for (m = 0; m < np; m = m + 1) if (p_rise[m] == r) idx_of = m;
    end
  endfunction

  // census one field's block, starting at the index of its first broad pulse
  task census(input integer a0, input string label);
    integer m, w, want, expect_w;
    begin
      // n_pre equalizing pulses before the anchor, then n_broad broad, then n_post eq.
      for (m = 0; m < N_PRE + N_BROAD + N_POST; m = m + 1) begin
        j = a0 - N_PRE + m;
        if (j < 0 || j >= np) begin
          cen_bad = cen_bad + 1;
          $display("FAIL[G4] %s: pulse %0d of the block is outside the capture", label, m);
        end else begin
          expect_w = (m >= N_PRE && m < N_PRE + N_BROAD) ? BROAD_W : EQ_W;
          cen_n = cen_n + 1;
          if (p_wid[j] < expect_w - 1 || p_wid[j] > expect_w + 1) begin
            cen_bad = cen_bad + 1;
            if (cen_bad <= 8)
              $display("FAIL[G4] %s: block pulse %0d width %0d clk27 (expect %0d +/-1)",
                       label, m, p_wid[j], expect_w);
          end
          if (m > 0) begin
            w = p_rise[j] - p_rise[j-1];
            if (w != (pal ? 864 : 858)) begin
              cen_bad = cen_bad + 1;
              if (cen_bad <= 8)
                $display("FAIL[G4] %s: block pulse %0d is %0d clk27 after the previous (expect one half-line, %0d)",
                         label, m, w, pal ? 864 : 858);
            end
          end
        end
      end
    end
  endtask

  initial begin
    #500 rst = 1;
    repeat (13 * FIELD) @(posedge clk);

    $display("csync_field_tb: arm=%0d (%s) %s, %0d pulses captured",
             arm, (arm==0)?"SMPTE":((arm==1)?"2H":"Stock"), pal ? "PAL 576i" : "NTSC 480i", np);
    $display("csync_field_tb: hsync %0d clk27, raster vsync %0d clk27 (%0d lines); vsync begins %0d / %0d clk27 after an hsync (half line = %0d)",
             LINE, vs_width, vs_width / LINE, vs_off_a, vs_off_b, LINE / 2);
    $display("csync_field_tb: FIRST BROAD PULSE per field: A %0d clk27 (%0d.%0d us), B %0d clk27 (%0d.%0d us)",
             first_broad_a, first_broad_a/27, (first_broad_a*10/27)%10,
             first_broad_b, first_broad_b/27, (first_broad_b*10/27)%10);
    $display("csync_field_tb: first pulse WIDER THAN AN HSYNC per field: A %0d clk27 (%0d.%0d us), B %0d clk27 (%0d.%0d us) — where these differ from the line above, a 20 us width detector MISSED one field's first broad pulse and locked a line late",
             first_wide_a, first_wide_a/27, (first_wide_a*10/27)%10,
             first_wide_b, first_wide_b/27, (first_wide_b*10/27)%10);
    $display("csync_field_tb: width-detector spacings %0d / %0d clk27 (ideal %0d each, %0d per pair); %0d per-field bad, %0d per-pair bad",
             wd_sp_a, wd_sp_b, FIELD, FRAME, wd_bad, wd_pair_bad);
    $display("csync_field_tb: RC integrator (tau=%0d us) spacings %0d / %0d clk27 (ideal %0d), %0d outside +/-%0d",
             tau_us, sp_a, sp_b, FIELD, int_bad, TOL_INT);

    // ---- [G4] pulse census, SMPTE arm ---------------------------------------------
    cen_bad = 0; cen_n = 0;
    if (arm == 0) begin
      anchor_a = idx_of(fb_rise_a);
      anchor_b = idx_of(fb_rise_b);
      if (anchor_a < 0 || anchor_b < 0) begin
        cen_bad = cen_bad + 1;
        $display("FAIL[G4]: could not locate a first broad pulse in both fields");
      end else begin
        census(anchor_a, "field A");
        census(anchor_b, "field B");
      end
      $display("csync_field_tb: [G4] census %0d pulses checked against %s Table (eq %0d, broad %0d, %0d/%0d/%0d half-lines), %0d bad",
               cen_n, pal ? "BT.470" : "SMPTE 170M", EQ_W, BROAD_W, N_PRE, N_BROAD, N_POST, cen_bad);
    end

    // ---- [G5] field congruence ------------------------------------------------------
    // Anchored on each field's OWN first broad pulse — a measured feature, not one of
    // the generator's constants.
    // ⚠ The window is the BLOCK, and stops there on purpose. The last ordinary hsync
    // before the block is one full line ahead of it in the line-aligned field and only
    // half a line ahead in the other — that difference IS interlace (the whole vertical
    // interval is offset half a line), not an asymmetry any standard removes, and it is
    // reported below rather than gated. What the equalizing pulses guarantee, and what a
    // separator integrates over, is that the BLOCK ITSELF is identical in both fields.
    cong_bad = 0; cong_n = 0;
    if (arm != 2 && fb_rise_a >= 0 && fb_rise_b >= 0) begin
      anchor_a = idx_of(fb_rise_a);
      anchor_b = idx_of(fb_rise_b);
      nA = 0; nB = 0;
      if (anchor_a - N_PRE - 1 >= 0 && anchor_b - N_PRE - 1 >= 0)
        $display("csync_field_tb: [G5] entry hsync sits %0d clk27 before field A's block and %0d before field B's — a half-line apart (%0d), which is interlace itself and is not gated",
                 fb_rise_a - N_PRE*(pal?864:858) - p_rise[anchor_a-N_PRE-1],
                 fb_rise_b - N_PRE*(pal?864:858) - p_rise[anchor_b-N_PRE-1], pal?864:858);
      for (i = -N_PRE; i <= N_BROAD + N_POST - 1; i = i + 1) begin
        j = anchor_a + i;
        k = anchor_b + i;
        if (j >= 0 && j < np && k >= 0 && k < np) begin
          relA = p_rise[j] - fb_rise_a;
          relB = p_rise[k] - fb_rise_b;
          cong_n = cong_n + 1;
          if (relA != relB || p_wid[j] != p_wid[k]) begin
            cong_bad = cong_bad + 1;
            if (cong_bad <= 8)
              $display("FAIL[G5]: pulse %0d differs between fields — A at %+0d w=%0d, B at %+0d w=%0d",
                       i, relA, p_wid[j], relB, p_wid[k]);
          end
        end
      end
      $display("csync_field_tb: [G5] field congruence over the %0d block pulses, %0d differ",
               cong_n, cong_bad);
    end

    // ---- verdict ---------------------------------------------------------------------
    $display("csync_field_tb: [G1/G3] generated vs stock outside the vertical interval: %0d mismatches over %0d clocks",
             eq_bad, eq_n);

    if (arm == 2) begin
      // Stock arm. It must be bit-identical to the framework module AND must still
      // exhibit the defect this whole change exists to remove — a bench that passed on
      // both waveforms would not be measuring anything.
      // ★ The "defect still present" check is on what a SEPARATOR DOES, not on a pulse
      // width: both models must disagree field to field. An earlier version asserted a
      // >2x width ratio on the detected first broad pulse and FAILED here — because the
      // detector, quite correctly, SKIPS field B's ~18 us pulse and locks onto the next
      // one a line later. That miss IS the defect; the width ratio was a proxy for it,
      // and a worse one.
      if (eq_bad == 0 && eq_n > 1000 && wd_pair_bad == 0 && bad_hs == 0 && bad_vsw == 0
          && wd_bad > 0 && int_bad > 0
          && (first_wide_a > 2*first_wide_b || first_wide_b > 2*first_wide_a))
        $display("PASS: csync_field_tb [Stock] — bit-identical to sys_top's csync over %0d clocks, and it still shows the defect this change removes: first wide pulse %0d vs %0d clk27, width-detector spacings %0d/%0d (%0d per-field errors), integrator %0d/%0d (%0d out of tolerance)",
                 eq_n, first_wide_a, first_wide_b, wd_sp_a, wd_sp_b, wd_bad, sp_a, sp_b, int_bad);
      else begin
        $display("FAIL: csync_field_tb [Stock] — %0d mismatches vs the framework module over %0d clocks; %0d bad pairs, %0d bad hsync, %0d bad vsync widths; first wide pulses %0d / %0d (expect a >2x asymmetry), per-field errors width %0d / integrator %0d (expect BOTH nonzero — the defect must still be measurable here)",
                 eq_bad, eq_n, wd_pair_bad, bad_hs, bad_vsw, first_wide_a, first_wide_b, wd_bad, int_bad);
        $fatal(1);
      end
    end else begin
      if (eq_bad == 0 && eq_n > 1000 && cen_bad == 0 && cong_bad == 0 && cong_n >= (N_PRE + N_BROAD + N_POST)
          && wd_bad == 0 && wd_pair_bad == 0 && wd_n >= 8 && int_bad == 0
          && bad_hs == 0 && bad_vsw == 0)
        $display("PASS: csync_field_tb [%s] — both fields present the SAME sync waveform, both separator models trigger 262.5 lines apart every field, and picture lines are untouched",
                 (arm==0)?"SMPTE":"2H");
      else begin
        $display("FAIL: csync_field_tb [%s] — [G1/G3] %0d mismatches/%0d clocks, [G4] %0d bad, [G5] %0d differ of %0d, [G6] width %0d per-field / %0d per-pair over %0d triggers, integrator %0d, [G7] %0d hsync / %0d vsync",
                 (arm==0)?"SMPTE":"2H", eq_bad, eq_n, cen_bad, cong_bad, cong_n,
                 wd_bad, wd_pair_bad, wd_n, int_bad, bad_hs, bad_vsw);
        $fatal(1);
      end
    end
    $finish;
  end

endmodule
