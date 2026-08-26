`timescale 1ns/1ps
//
// re_interlace_tb.sv — verify dvd/re_interlace.sv (dual-raster analog output).
//
// The DUT converts the main progressive raster (720x480p/576p, 27 MHz CE=1)
// into a native 15 kHz 2:1-interlaced raster (NTSC 858x262/263 half-line 429;
// PAL 864x312/313 half-line 432) through a 4-line BRAM + a second sync_gen.
//
// Invariants proven here:
//   A (lock):    consecutive out_vs rising edges are EXACTLY 225225 13.5 MHz
//                dots apart every field (PAL: 270000) — the same single check
//                as crt_syncgen_tb: it proves the half-line, the alternating
//                field totals, and the odd frame total simultaneously.
//   B (content): every active output pixel decodes to source pixel (x, line)
//                with the RIGHT line parity per field (A=even, B=odd), lines
//                stepping +2, x stepping +1 from 0..719, 240 (288) active
//                lines per field, and ONE consistent source-frame tag per
//                field that increments by exactly 1 each field — the direct
//                proof of the SKEW window math (a read/write race shows up as
//                a mixed or wrong frame tag).
//   C (health):  a non-standard main raster (Film-24p length) never locks;
//                enable-drop and NTSC->PAL geometry switches re-lock cleanly.
//
// Build:
//   iverilog -g2012 -I rtl/mpeg2 -o bench/dvd/re_interlace_sim \
//       rtl/mpeg2/syncgen.v dvd/re_interlace.sv dvd/cc_line21.sv \
//       rtl/mpeg2/wrappers.v rtl/mpeg2/xilinx_fifo_dc.v rtl/mpeg2/xfifo_sc.v \
//       rtl/mpeg2/xilinx_fifo_sc.v bench/dvd/re_interlace_tb.sv
//   vvp bench/dvd/re_interlace_sim
//
`include "timescale.v"

module re_interlace_tb;

  // ---------------------------------------------------------------- clocks
  reg clk = 0;
  always #5 clk = ~clk;              // "27 MHz"

  reg ce2 = 0;
  always @(posedge clk) ce2 <= ~ce2; // free-running 13.5 MHz CE

  // ---------------------------------------------------------------- DUT io
  reg         rst_n  = 0;
  reg         enable = 0;
  reg         pal    = 0;
  reg         fieldpass = 0;   // DUT mode: 1 = re-time the interlaced pixrep raster 1:1
  reg         src_fp    = 0;   // stimulus select (kept separate so a MISMATCH is testable)
  reg  [7:0]  in_r, in_g, in_b;
  reg         in_de;
  reg  [11:0] in_hpos, in_vpos;
  wire [7:0]  out_r, out_g, out_b;
  wire        out_hs, out_vs, out_de, out_ce, locked;

  re_interlace dut (
    .clk(clk), .rst_n(rst_n), .ce2(ce2),
    .enable(enable), .pal(pal), .fieldpass(fieldpass),
    .in_r(in_r), .in_g(in_g), .in_b(in_b), .in_de(in_de),
    .in_hpos(in_hpos), .in_vpos(in_vpos),
    .out_r(out_r), .out_g(out_g), .out_b(out_b),
    .out_hs(out_hs), .out_vs(out_vs), .out_de(out_de),
    .out_ce(out_ce), .locked(locked),
    // line-21 captions: disabled here — this bench proves the RASTER. The
    // inserter has its own bench (bench/dvd/cc_line21_tb.sv), and holding
    // cc_enable low keeps every pixel-exact content check below unchanged,
    // which is itself the assertion that captions cannot touch active video.
    .cc_enable(1'b0), .cc_flush(1'b0), .dec_clk(clk),
    .cc_pair_valid(1'b0), .cc_pair(16'd0), .cc_pair_field(1'b0), .cc_active()
  );

  // ------------------------------------------- synthetic main raster model
  // Pixel payload encodes (x, line, frame) uniquely:
  //   R = x[7:0]   G = line[7:0]   B = {frame[3:0], line[9:8], x[9:8]}
  integer g_hlen  = 858;   // dots per line (NTSC); 864 PAL
  integer g_vlen  = 525;   // lines per frame (NTSC); 625 PAL; 1287 "film"
  integer g_hact  = 720;
  integer g_vact  = 480;   // 576 PAL
  integer g_h = 0, g_v = 0, g_frame = 0;

  always @(posedge clk) begin
    // >= so a mid-frame geometry shrink (test [3]/[5]) can't strand the counters
    if (g_h >= g_hlen - 1) begin
      g_h <= 0;
      if (g_v >= g_vlen - 1) begin
        g_v <= 0;
        g_frame <= g_frame + 1;
      end else g_v <= g_v + 1;
    end else g_h <= g_h + 1;
  end

  // ------------------------------- fieldpass source raster model (scenario [6])
  // The pixel-repeated INTERLACED main raster the decoder emits under il_eff:
  //   line   = 1716 clk27 (NTSC) / 1728 (PAL)  -- same duration as our output line
  //   field A = 262 (312) lines, EVEN absolute v_pos; field B = 263 (313), ODD
  //             (syncgen: v_pos = {v_cntr, ~odd_field}, eff_vertical_length +1 on B)
  //   active  = 240 (288) lines/field, 1440 dots = 720 source pixels each sent TWICE
  // Payload encoding is identical to the progressive model, keyed on the SOURCE
  // pixel index and the ABSOLUTE frame line, so the invariant-B decoder is shared.
  integer f_hlen = 1716, f_vlenA = 262, f_vlenB = 263, f_hact = 1440, f_vact = 240;
  integer f_h = 0, f_vc = 0, f_fld = 0, f_frame = 0;

  always @(posedge clk) begin
    if (f_h >= f_hlen - 1) begin
      f_h <= 0;
      if (f_vc >= (f_fld ? f_vlenB : f_vlenA) - 1) begin
        f_vc  <= 0;
        f_fld <= 1 - f_fld;
        if (f_fld) f_frame <= f_frame + 1;   // a frame closes at the end of field B
      end else f_vc <= f_vc + 1;
    end else f_h <= f_h + 1;
  end

  integer f_absline, f_x;

  always @(*) begin
    f_absline = 2*f_vc + f_fld;
    f_x       = f_h >> 1;
    if (src_fp) begin
      in_hpos = f_h[11:0];
      in_vpos = f_absline[11:0];
      in_de   = (f_h < f_hact) && (f_vc < f_vact);
      in_r    = f_x[7:0];
      in_g    = f_absline[7:0];
      in_b    = {f_frame[3:0], f_absline[9:8], f_x[9:8]};
    end else begin
      in_hpos = g_h[11:0];
      in_vpos = g_v[11:0];
      in_de   = (g_h < g_hact) && (g_v < g_vact);
      in_r    = g_h[7:0];
      in_g    = g_v[7:0];
      in_b    = {g_frame[3:0], g_v[9:8], g_h[9:8]};
    end
  end

  // ------------------------------------------------------------- checkers
  integer errors = 0;
  task fail(input string msg);
    begin
      errors = errors + 1;
      $display("FAIL @%0t: %0s", $time, msg);
      if (errors > 20) begin
        $display("re_interlace_tb: too many errors, aborting");
        $fatal(1);
      end
    end
  endtask

  // dot counting / vsync spacing (invariant A)
  integer exp_field_dots = 225225;   // NTSC; 270000 PAL
  integer dot_cnt = 0;
  integer last_vs_dot = -1;
  integer vs_edges = 0;
  reg     prev_vs = 0;
  integer check_arm = 0;             // set once locked; cleared on relock tests

  // content decode (invariant B)
  integer exp_lines_per_field;       // 240 NTSC / 288 PAL
  integer cur_x, lines_in_field, cur_line, prev_line;
  integer cur_frame_tag, prev_field_tag, have_prev_field_tag;
  integer field_parity;              // 0 = even lines (field A), 1 = odd
  reg     prev_de = 0;
  integer px_x, px_line, px_frame;
  integer exp_field_tag;

  initial begin
    cur_x = -1; lines_in_field = 0; cur_line = -1; prev_line = -1;
    cur_frame_tag = -1; prev_field_tag = -1; have_prev_field_tag = 0;
    field_parity = -1;
    exp_lines_per_field = 240;
  end

  always @(posedge clk) if (out_ce) begin
    dot_cnt = dot_cnt + 1;

    // --- invariant A: vsync spacing
    if (out_vs && !prev_vs) begin
      vs_edges = vs_edges + 1;
      if (check_arm && last_vs_dot >= 0) begin
        if (dot_cnt - last_vs_dot != exp_field_dots)
          fail($sformatf("vsync spacing %0d dots (expected %0d)",
                         dot_cnt - last_vs_dot, exp_field_dots));
      end
      last_vs_dot = dot_cnt;

      // --- field bookkeeping closes at vsync (mid-blanking, after actives)
      if (check_arm && lines_in_field != 0) begin
        if (lines_in_field != exp_lines_per_field)
          fail($sformatf("field had %0d active lines (expected %0d)",
                         lines_in_field, exp_lines_per_field));
        // Expected tag progression differs by MODE, and that difference is the
        // whole point of fieldpass:
        //   derive   : field A reads main frame N, field B frame N+1 -> +1 EVERY field
        //   fieldpass: both fields of a source frame are that frame's own authored
        //              fields -> the tag repeats on field B (odd lines) and advances
        //              on field A (even lines), i.e. +1 every TWO fields.
        // field_parity holds the parity of the field being closed here.
        exp_field_tag = (fieldpass && (field_parity == 1))
                        ? prev_field_tag
                        : ((prev_field_tag + 1) % 16);
        if (have_prev_field_tag && (cur_frame_tag != exp_field_tag))
          fail($sformatf("field frame tag %0d after %0d (expected %0d, %0s)",
                         cur_frame_tag, prev_field_tag, exp_field_tag,
                         fieldpass ? "fieldpass" : "derive"));
        prev_field_tag = cur_frame_tag;
        have_prev_field_tag = 1;
      end
      lines_in_field = 0;
      cur_frame_tag = -1;
      prev_line = -1;
      field_parity = -1;
    end
    prev_vs = out_vs;

    // --- invariant B: pixel content
    if (out_de) begin
      px_x     = {out_b[1:0], out_r};
      px_line  = {out_b[3:2], out_g};
      px_frame = out_b[7:4];

      if (!prev_de) begin            // line start
        cur_x = 0;
        cur_line = px_line;
        lines_in_field = lines_in_field + 1;
        if (field_parity < 0) begin
          field_parity = px_line % 2;
        end else if (px_line % 2 != field_parity)
          fail($sformatf("line %0d parity flips inside a field (parity %0d)",
                         px_line, field_parity));
        if (prev_line >= 0 && px_line != prev_line + 2)
          fail($sformatf("line %0d follows %0d (expected +2)", px_line, prev_line));
        prev_line = px_line;
        if (cur_frame_tag < 0) cur_frame_tag = px_frame;
      end

      if (check_arm) begin
        if (px_x != cur_x)
          fail($sformatf("x=%0d decoded %0d (line %0d)", cur_x, px_x, px_line));
        if (px_line != cur_line)
          fail($sformatf("line changes mid-line: %0d -> %0d", cur_line, px_line));
        if (px_frame != cur_frame_tag)
          fail($sformatf("frame tag %0d != field tag %0d (line %0d x %0d) — read/write race",
                         px_frame, cur_frame_tag, px_line, cur_x));
      end
      cur_x = cur_x + 1;
      if (cur_x > 720) fail("active line longer than 720");
    end else if (prev_de && check_arm) begin
      if (cur_x != 720)
        fail($sformatf("active line only %0d px (expected 720)", cur_x));
    end
    prev_de = out_de;
  end

  // ------------------------------------------------------------- stimulus
  task wait_fields(input integer n);
    integer target;
    begin
      target = vs_edges + n;
      while (vs_edges < target) @(posedge clk);
    end
  endtask

  task reset_checker;
    begin
      check_arm = 0;
      last_vs_dot = -1;
      lines_in_field = 0; cur_frame_tag = -1; prev_line = -1;
      have_prev_field_tag = 0; field_parity = -1;
      prev_de = 0;
    end
  endtask

  integer t0;
  initial begin
    $display("re_interlace_tb: start");
    repeat (10) @(posedge clk);
    rst_n = 1;

    // ------------------------------------------------ [1] NTSC lock + run
    enable = 1;
    t0 = $time;
    while (!locked && ($time - t0) < 40_000_000) @(posedge clk);
    if (!locked) fail("[1] no lock on NTSC main raster");
    // let the first (possibly partial-checked) field pass, then arm checks
    wait_fields(2);
    reset_checker;
    check_arm = 1;
    wait_fields(8);
    if (!locked) fail("[1] lost lock during NTSC run");
    $display("[1] NTSC: 8 checked fields OK (spacing %0d)", exp_field_dots);

    // ------------------------------------------------ [2] enable drop / re-lock
    check_arm = 0;
    enable = 0;
    repeat (100) @(posedge clk);
    if (locked) fail("[2] still locked with enable=0");
    if (out_hs !== 1'b0 || out_vs !== 1'b0 || out_de !== 1'b0)
      fail("[2] outputs not quiet while disabled");
    enable = 1;
    t0 = $time;
    while (!locked && ($time - t0) < 40_000_000) @(posedge clk);
    if (!locked) fail("[2] no re-lock after enable");
    wait_fields(2);
    reset_checker; check_arm = 1;
    wait_fields(4);
    $display("[2] enable drop + re-lock OK");

    // ------------------------------------------------ [3] NTSC -> PAL switch
    check_arm = 0;
    // geometry and pal flag change together (as the modeline walk would)
    pal = 1;
    g_hlen = 864; g_vlen = 625; g_vact = 576;
    exp_field_dots = 270000;
    exp_lines_per_field = 288;
    t0 = $time;
    // must drop lock (wrong period detected), then re-lock on PAL
    while (locked && ($time - t0) < 40_000_000) @(posedge clk);
    if (locked) fail("[3] never dropped lock on geometry change");
    t0 = $time;
    while (!locked && ($time - t0) < 60_000_000) @(posedge clk);
    if (!locked) fail("[3] no lock on PAL raster");
    wait_fields(2);
    reset_checker; check_arm = 1;
    wait_fields(8);
    if (!locked) fail("[3] lost lock during PAL run");
    $display("[3] PAL: 8 checked fields OK (spacing %0d)", exp_field_dots);

    // ------------------------------------------------ [4] film raster never locks
    check_arm = 0;
    enable = 0;
    repeat (20) @(posedge clk);
    pal = 0;
    g_hlen = 875; g_vlen = 1287; g_vact = 480;   // Film-24p NTSC frame (875x1287 exact-rate, PR #158)
    enable = 1;
    // wait ~3 film frames
    repeat (3 * 875 * 1287) @(posedge clk);
    if (locked) fail("[4] locked onto a Film-24p raster (period check broken)");
    $display("[4] film raster correctly rejected");

    // ------------------------------------------------ [5] back to NTSC
    // BOTH axes must be restored: the Film-24p raster is 875 dots/line (not 858 —
    // an odd htotal is what makes 24000/1001 exact, PR #158), so restoring only
    // g_vlen would leave 875 x 525 = 459,375 != 450,450 and re_interlace would
    // correctly refuse to lock. (Caught exactly that way when the film numbers were
    // updated — an incidental confirmation that the period check covers h as well.)
    g_hlen = 858; g_vlen = 525;
    exp_field_dots = 225225;
    exp_lines_per_field = 240;
    t0 = $time;
    while (!locked && ($time - t0) < 40_000_000) @(posedge clk);
    if (!locked) fail("[5] no re-lock after film -> NTSC");
    wait_fields(2);
    reset_checker; check_arm = 1;
    wait_fields(4);
    $display("[5] film -> NTSC re-lock OK");

    // ------------------------------------------------ [6] fieldpass NTSC
    // Native Fields: the source is already the interlaced pixrep raster, so the
    // module re-times authored fields 1:1 instead of splitting a weave. Same output
    // raster (invariant A unchanged), but each field now carries its OWN source
    // frame's tag -> the tag advances every TWO fields (see the checker).
    check_arm = 0;
    enable = 0;
    repeat (20) @(posedge clk);
    pal = 0; fieldpass = 1; src_fp = 1;
    f_hlen = 1716; f_vlenA = 262; f_vlenB = 263; f_hact = 1440; f_vact = 240;
    exp_field_dots = 225225;
    exp_lines_per_field = 240;
    enable = 1;
    t0 = $time;
    while (!locked && ($time - t0) < 80_000_000) @(posedge clk);
    if (!locked) fail("[6] no lock on the fieldpass NTSC raster");
    wait_fields(2);
    reset_checker; check_arm = 1;
    wait_fields(8);
    if (!locked) fail("[6] lost lock during the fieldpass NTSC run");
    $display("[6] fieldpass NTSC: 8 checked fields OK (spacing %0d)", exp_field_dots);

    // ------------------------------------------------ [7] fieldpass PAL
    check_arm = 0;
    enable = 0;
    repeat (20) @(posedge clk);
    pal = 1;
    f_hlen = 1728; f_vlenA = 312; f_vlenB = 313; f_hact = 1440; f_vact = 288;
    exp_field_dots = 270000;
    exp_lines_per_field = 288;
    enable = 1;
    t0 = $time;
    while (!locked && ($time - t0) < 100_000_000) @(posedge clk);
    if (!locked) fail("[7] no lock on the fieldpass PAL raster");
    wait_fields(2);
    reset_checker; check_arm = 1;
    wait_fields(8);
    if (!locked) fail("[7] lost lock during the fieldpass PAL run");
    $display("[7] fieldpass PAL: 8 checked fields OK (spacing %0d)", exp_field_dots);

    // ------------------------------------------------ [8] mode/source mismatch
    // fieldpass expects a 900900-clk27 (NTSC) frame period. Feeding it the
    // PROGRESSIVE raster (450450) must be rejected by the period check, exactly
    // as the film raster is in [4] — the backstop that keeps a mis-set mode silent
    // rather than showing a torn picture.
    check_arm = 0;
    enable = 0;
    repeat (20) @(posedge clk);
    pal = 0; fieldpass = 1; src_fp = 0;
    g_hlen = 858; g_vlen = 525; g_hact = 720; g_vact = 480;
    enable = 1;
    repeat (3 * 858 * 525) @(posedge clk);
    if (locked) fail("[8] locked onto a progressive raster while fieldpass=1");
    $display("[8] fieldpass correctly rejects the progressive raster");

    // ------------------------------------------------ [9] back to derive mode
    check_arm = 0;
    enable = 0;
    repeat (20) @(posedge clk);
    fieldpass = 0; src_fp = 0;
    exp_field_dots = 225225;
    exp_lines_per_field = 240;
    enable = 1;
    t0 = $time;
    while (!locked && ($time - t0) < 40_000_000) @(posedge clk);
    if (!locked) fail("[9] no re-lock after returning to derive mode");
    wait_fields(2);
    reset_checker; check_arm = 1;
    wait_fields(4);
    $display("[9] fieldpass -> derive re-lock OK");

    if (errors == 0) begin
      $display("re_interlace_tb: PASS");
      $finish;
    end else begin
      $display("re_interlace_tb: %0d ERRORS", errors);
      $fatal(1);
    end
  end

  // global watchdog
  initial begin
    #400_000_000;
    $display("re_interlace_tb: TIMEOUT");
    $fatal(1);
  end

endmodule
