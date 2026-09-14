/*
 * csync_p240_tb.sv — the SMPTE/BT.470 vertical block on the PROGRESSIVE 240p/288p raster.
 *
 * WHY A SEPARATE BENCH.  bench/dvd/csync_field_tb.sv is the interlaced gate end to end:
 * its field-A/field-B model, its FIELD/FRAME constants and its [G5] congruence and [G8]
 * first-field checks all presuppose two fields.  Bending it around a raster with one
 * would either weaken those checks or make them lie, so the progressive arm lives here
 * and that bench keeps running on exactly the raster it was written against.
 *
 * WHAT 240p CHANGES IN dvd/csync_smpte.sv, and therefore what this gates:
 *   - the line/field decode.  syncgen packs {line, parity} into v_pos only when
 *     `interlaced`; on this raster v_pos IS v_cntr, so the module must take it whole.
 *   - the half-line offset.  Interlace is what makes one field open the block half a
 *     line late; a progressive raster opens it on a LINE boundary, every frame.
 * Everything else — the nine-line block, every pulse width, VSS 244/292 — is REUSED
 * unchanged, and [P2]'s census is what proves that reuse was legitimate rather than
 * merely convenient.
 *
 * THE CHECKS.
 *   [P1] EQUALITY OUTSIDE THE BLOCK.  Away from the vertical interval the module is
 *        `h_sync` delayed one clock, so "did we break anything" is an equality gate over
 *        millions of clocks rather than a hand-tuned constant. This is the check that
 *        would catch a progressive path that accidentally emitted block pulses across
 *        the picture.
 *   [P2] THE BLOCK IS THE STANDARD'S.  18 half-line slots (6 pre-equalizing, 6 broad,
 *        6 post-equalizing for 525; 5/5/5 for 625), each carrying one pulse, at the
 *        equalizing and broad widths the module derives from the modeline registers.
 *   [P3] ⚠ THE LOAD-BEARING ONE: the block opens on a LINE BOUNDARY.  Measured as the
 *        phase of the block's first pulse within the line, against the hsync position —
 *        it must be 0, not half a line. That IS blk_half == 0, measured on the emitted
 *        waveform rather than read off the signal the fix names.
 *        ★ A frame-to-frame congruence check could NOT catch a stuck blk_half: the block
 *        starts on the same line every frame, so a half-line offset would be applied
 *        equally to all of them and they would still agree with each other. It has to be
 *        measured against the line grid, which is why [P3] is phrased this way.
 *   [P4] EVERY FRAME IS THE SAME.  The progressive analogue of [G5]: no alternation
 *        survives anywhere, so all captured blocks must be identical in offset and width.
 *   [P5] The raster itself: vsync spacing constant (262/312 lines), so the block has a
 *        stable grid to sit on.
 *
 *   +pal=1 runs the 288p arm. +red_half=1 is the TB-side RED arm for [P3].
 */
`timescale 1ns / 1ps
`include "field_polarity.vh"
`default_nettype none

module csync_p240_tb;

  reg clk = 0;
  always #1 clk = ~clk;              // 27 MHz dot clock (time unit irrelevant)
  reg rst = 0;

  localparam integer LINE_N = 1716, LINE_P = 1728;
  localparam integer FRAME_N = 262 * LINE_N;       // 449592
  localparam integer FRAME_P = 312 * LINE_P;       // 539136

  integer pal = 0;
  integer red_half = 0;              // RED: re-introduce the half-line block offset
  // ⚠ LINE/FRAME/EQ_W/BROAD_W/NSEG are derived HERE, in the same initial that reads the
  // plusargs, and not in an always @(*): as integers in a combinational block they read
  // as x until their first change, and the clocked block below needs them from its first
  // cycle -- every comparison against them silently evaluated false and the bench passed
  // nothing while looking like it ran. rst rises at #40, after this block, so the values
  // are in place before anything samples them.
  integer LINE, FRAME, EQ_W, BROAD_W, NSEG, HSS_REF, HS_W;
  initial begin
    void'($value$plusargs("pal=%d", pal));
    void'($value$plusargs("red_half=%d", red_half));
    LINE    = pal ? LINE_P  : LINE_N;
    FRAME   = pal ? FRAME_P : FRAME_N;
    EQ_W    = pal ? 63  : 62;      // hsync/2
    BROAD_W = pal ? 737 : 731;     // half-line - serration
    NSEG    = pal ? 5   : 6;       // half-lines per segment
    HSS_REF = pal ? 1465 : 1471;   // hsync start dot, the line-phase reference
    HS_W    = pal ? 127 : 125;     // an ordinary hsync's width on the wire (HSE-HSS+1)
  end

  // ---- the 240p / 288p raster, exactly as emu.sv's p240_prev branch writes it,
  // ---- after syncgen_intf's pixel-repetition doubling (2x+1 for start/end/length,
  // ---- 2x for resolution and the half-line).
  wire [11:0] HRES  = 12'd1440;
  wire [11:0] HSS   = pal ? 12'd1465 : 12'd1471;
  wire [11:0] HSE   = pal ? 12'd1591 : 12'd1595;
  wire [11:0] HLEN  = pal ? 12'd1727 : 12'd1715;   // 1728 / 1716 dots
  wire [11:0] VRES  = pal ? 12'd288  : 12'd240;    // ACTIVE count: syncgen does NOT halve
  wire [11:0] VSS   = pal ? 12'd292  : 12'd244;
  wire [11:0] VSE   = pal ? 12'd295  : 12'd247;
  wire [11:0] VLEN  = pal ? 12'd311  : 12'd261;    // 312 / 262 lines

  // expected pulse widths are stated independently from SMPTE 170M Table 3 / BT.470
  // Table 2; the module derives its own from the modeline registers.

  wire [11:0] h_pos, v_pos;
  wire pixel_en, h_sync, v_sync, c_sync_unused, h_blank, v_blank;

  sync_gen dut (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .horizontal_size(14'd1440), .vertical_size({2'b0, VRES}),
    .display_horizontal_size(14'd0), .display_vertical_size(14'd0),
    .horizontal_resolution(HRES),
    .horizontal_sync_start(HSS), .horizontal_sync_end(HSE),
    .horizontal_length(HLEN),
    .vertical_resolution(VRES),
    .vertical_sync_start(VSS), .vertical_sync_end(VSE),
    .horizontal_halfline(12'd0),                 // ★ no half-line: this is what 240p is
    .vertical_length(VLEN),
    .interlaced(1'b0), .clip_display_size(1'b0),
    .h_pos(h_pos), .v_pos(v_pos), .pixel_en(pixel_en),
    .h_sync(h_sync), .v_sync(v_sync), .c_sync(c_sync_unused),
    .h_blank(h_blank), .v_blank(v_blank));

  // RED arm: hand the generator a v_pos whose bit 0 is NOT FIELD1_VPOS on the block's
  // line, which is what an un-forced fpar would read on a progressive raster -- the
  // block then opens half a line late and [P3] must fire.
  wire [11:0] v_pos_eff = red_half ? {v_pos[11:1], ~`FIELD1_VPOS} : v_pos;
  wire        prog_eff  = red_half ? 1'b0 : 1'b1;

  wire cs, cs_en;
  csync_smpte gen_i (
    .clk(clk), .rst_n(rst),
    .mode(1'b0), .en(1'b1), .prog(prog_eff), .pal(pal != 0),
    .h_sync(h_sync), .v_pos(v_pos_eff),
    .cs(cs), .cs_en(cs_en));

  // ---------------------------------------------------------------- capture
  integer dot = 0;
  reg     hs_d = 0, vs_d = 0, cs_d = 0;
  integer last_hs_rise = -1, last_vs_rise = -1;
  integer vs_rises = 0, bad_vs_sp = 0, vs_period = 0;

  // pulse log
  localparam integer MAXP = 512;
  integer p_start [0:MAXP-1];
  integer p_width [0:MAXP-1];
  integer p_ph    [0:MAXP-1];   // phase of the rise within its line, from the hsync rise
  integer np = 0;
  integer cs_rise_dot = -1;
  integer cs_rise_ph  = -1;

  // equality-outside-the-block bookkeeping
  reg  hs_dly = 0;
  integer eq_mismatch = 0, eq_clocks = 0;
  // the block window: the module can only differ from h_sync inside the vertical
  // interval, so exclude a generous band around it (10 lines each side of VSS).
  wire in_band = (v_pos >= (VSS - 12'd12)) && (v_pos <= (VSS + 12'd12));

  always @(posedge clk) if (rst) begin
    dot    <= dot + 1;
    hs_d   <= h_sync;
    vs_d   <= v_sync;
    cs_d   <= cs;
    hs_dly <= h_sync;

    if (!in_band && dot > FRAME) begin
      eq_clocks = eq_clocks + 1;
      if (cs !== hs_dly) eq_mismatch = eq_mismatch + 1;
    end

    if (h_sync && !hs_d) last_hs_rise = dot;

    if (v_sync && !vs_d) begin
      vs_rises = vs_rises + 1;
      if (last_vs_rise >= 0 && vs_rises > 2) begin
        vs_period = dot - last_vs_rise;
        if (vs_period != FRAME) begin
          if (bad_vs_sp < 5)
            $display("FAIL[P5]: vsync spacing %0d dots (expect %0d = %0d lines)",
                     vs_period, FRAME, FRAME/LINE);
          bad_vs_sp = bad_vs_sp + 1;
        end
      end
      last_vs_rise = dot;
    end

    if (cs && !cs_d) begin cs_rise_dot = dot; cs_rise_ph = dot - last_hs_rise; end
    // ⚠ log only inside the band. Outside it cs IS h_sync, so an unfiltered log is one
    // pulse per line (~1000 per frame) and MAXP fills long before a block is reached --
    // which is how the first run of this bench "captured 512 pulses" and located none.
    if (!cs && cs_d && cs_rise_dot >= 0 && np < MAXP && in_band) begin
      p_start[np] = cs_rise_dot;
      p_width[np] = dot - cs_rise_dot;
      p_ph[np]    = cs_rise_ph;
      np = np + 1;
    end
  end

  // ---------------------------------------------------------------- checks
  integer i, j, k;
  integer errors = 0;
  integer blk0 [0:7];            // start DOT of each captured block's first pulse
  integer blk_i [0:7];           // and its index in the pulse log
  integer nblk = 0;
  integer cen_bad = 0, ph_bad = 0, cong_bad = 0, nexp = 0, ref_ph = -1;
  integer ph, base, w_exp, off, off0;

  initial begin
    #40 rst = 1;
    repeat (FRAME_P * 4 + 64) @(posedge clk);

    nexp = 3 * NSEG;             // 18 NTSC / 15 PAL half-line slots, one pulse each

    // locate each block: a run of pulses that contains a BROAD one
    for (i = 1; i < np; i = i + 1) begin
      if (p_width[i] > (EQ_W * 4) && p_width[i] < (LINE / 2)) begin
        // first broad pulse of a block -> the block began NSEG pulses earlier
        if (i >= NSEG && nblk < 8) begin
          // only record once per block
          if (nblk == 0 || (p_start[i - NSEG] - blk0[nblk-1]) > (FRAME / 2)) begin
            blk0[nblk]  = p_start[i - NSEG];
            blk_i[nblk] = i - NSEG;
            nblk = nblk + 1;
          end
        end
      end
    end

    $display("csync_p240_tb: %s raster — %0d dots/line, %0d lines/frame (%0d dots), %0d pulses captured, %0d blocks located",
             pal ? "PAL 288p" : "NTSC 240p", LINE, FRAME/LINE, FRAME, np, nblk);

    if (nblk < 2) begin
      $display("FAIL: located %0d blocks, need at least 2 to compare", nblk);
      errors = errors + 1;
    end else begin
      // ---- [P2] pulse census against the standard's table --------------------
      // find the pulse index at which the first located block starts
      base = -1;
      for (i = 0; i < np; i = i + 1) if (base < 0 && p_start[i] == blk0[0]) base = i;
      if (base < 0 || (base + nexp) > np) begin
        $display("FAIL[P2]: the first block is not fully captured (base %0d, need %0d of %0d)", base, nexp, np);
        errors = errors + 1;
      end else begin
        for (k = 0; k < nexp; k = k + 1) begin
          w_exp = (k >= NSEG && k < 2*NSEG) ? BROAD_W : EQ_W;
          if (p_width[base+k] != w_exp) begin
            if (cen_bad < 6)
              $display("FAIL[P2]: block pulse %0d width %0d (expect %0d, %s)",
                       k, p_width[base+k], w_exp, (k >= NSEG && k < 2*NSEG) ? "broad" : "equalizing");
            cen_bad = cen_bad + 1;
          end
          if (k > 0) begin
            if ((p_start[base+k] - p_start[base+k-1]) != (LINE/2)) begin
              if (cen_bad < 6)
                $display("FAIL[P2]: block pulse %0d starts %0d dots after the previous (expect one half-line, %0d)",
                         k, p_start[base+k] - p_start[base+k-1], LINE/2);
              cen_bad = cen_bad + 1;
            end
          end
        end
        if (cen_bad) errors = errors + 1;
        else $display("csync_p240_tb: [P2] census %0d pulses on the half-line grid, %s Table widths (eq %0d, broad %0d, %0d/%0d/%0d half-lines)",
                      nexp, pal ? "BT.470" : "SMPTE 170M", EQ_W, BROAD_W, NSEG, NSEG, NSEG);
      end

      // ---- [P3] VERTICAL SYNC opens on a LINE BOUNDARY ------------------------
      // ★ SELF-CALIBRATING, deliberately. The reference is the phase of an ORDINARY
      // hsync in the SAME captured stream (outside the block cs is h_sync delayed one
      // clock), so this compares against the line grid the raster actually emitted
      // rather than against a hand-computed dot number. The first attempt anchored the
      // phase to `dot % LINE` -- but `dot` starts at reset, not on a line boundary, so
      // every block measured a constant 4-dot offset that was pure bench artefact. A
      // reference taken from the waveform cannot be wrong about pipeline delay or about
      // where the line starts.
      // ⚠⚠ AND IT MEASURES THE BROAD SEGMENT, NOT THE BLOCK'S FIRST PULSE. Asserting
      // that the whole block opens on a line boundary is TRUE FOR 525 AND FALSE FOR 625:
      // BT.470's segments are 2.5 lines (5 half-lines), so the pre-equalizing sequence
      // legitimately begins mid-line and only the broad segment -- vertical sync itself,
      // at the start of line VSS -- is line-aligned in both standards. The first version
      // of this check asserted the block and failed PAL against correct RTL. A
      // half-line-offset block still moves the broad segment, so nothing is lost.
      ref_ph = -1;
      for (i = 0; i < np; i = i + 1)
        if (ref_ph < 0 && p_width[i] == HS_W) ref_ph = p_ph[i];
      if (ref_ph < 0) begin
        $display("FAIL[P3]: no ordinary hsync pulse in the capture to calibrate the line phase against");
        errors = errors + 1;
      end else begin
        for (j = 0; j < nblk; j = j + 1) begin
          ph = p_ph[blk_i[j] + NSEG];          // the FIRST BROAD pulse = vertical sync
          if (ph != ref_ph) begin
            if (ph_bad < 4)
              $display("FAIL[P3]: block %0d starts vertical sync at line phase %0d, an ordinary hsync at %0d — a difference of %0d (half a line is %0d). A progressive raster has NO half-line offset.",
                       j, ph, ref_ph, ph - ref_ph, LINE/2);
            ph_bad = ph_bad + 1;
          end
        end
        if (ph_bad) errors = errors + 1;
        else $display("csync_p240_tb: [P3] all %0d blocks start vertical sync at the same line phase as an ordinary hsync (%0d) — blk_half is 0, measured on the wire against the raster's own line grid",
                      nblk, ref_ph);
      end

      // ---- [P4] every frame's block is identical -----------------------------
      off0 = blk0[0] % FRAME;
      for (j = 1; j < nblk; j = j + 1) begin
        off = blk0[j] % FRAME;
        if (off != off0) begin
          if (cong_bad < 4)
            $display("FAIL[P4]: block %0d sits at frame offset %0d, block 0 at %0d — no alternation may survive on a progressive raster",
                     j, off, off0);
          cong_bad = cong_bad + 1;
        end
      end
      if (cong_bad) errors = errors + 1;
      else $display("csync_p240_tb: [P4] all %0d blocks at the same frame offset (%0d) — every frame presents the SAME sync waveform",
                    nblk, off0);
    end

    // ---- [P1] equality away from the vertical interval -----------------------
    if (eq_mismatch) begin
      $display("FAIL[P1]: %0d of %0d clocks outside the vertical interval differ from a one-clock-delayed h_sync — picture lines must be untouched",
               eq_mismatch, eq_clocks);
      errors = errors + 1;
    end else
      $display("csync_p240_tb: [P1] %0d clocks outside the vertical interval are bit-identical to h_sync delayed one clock",
               eq_clocks);

    // ---- [P5] ---------------------------------------------------------------
    if (bad_vs_sp) errors = errors + 1;
    else $display("csync_p240_tb: [P5] vsync spacing constant at %0d dots (%0d lines) over %0d rises",
                  FRAME, FRAME/LINE, vs_rises);

    if (errors == 0)
      $display("\n==== PASS: csync_p240_tb [%s] ====", pal ? "PAL 288p" : "NTSC 240p");
    else begin
      $display("\n==== FAIL: csync_p240_tb [%s] — %0d check(s) failed ====", pal ? "PAL 288p" : "NTSC 240p", errors);
      $fatal(1, "csync_p240_tb failed");
    end
    $finish;
  end

endmodule

`default_nettype wire
