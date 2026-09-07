// =============================================================================
// disp_sched_tb.sv — the display scheduler against its OWN model of the world.
// =============================================================================
// dvd/disp_sched.sv decides, at every pickup opportunity the raster offers,
// whether the picture waiting at picbuf's output is due against a free-running
// 90 kHz STC. This bench builds the world around it from first principles, not
// from the RTL's expressions:
//
//   * a DECODER that produces a scripted picture list in display order (PTS
//     tags on some pictures, the rest untagged; flags; a "ready" time; some
//     pictures DROPPED by the vld, which then only pulse skip_ack);
//   * a RASTER that offers a pickup opportunity every image-scan period of the
//     chosen mode (1501.5 ticks NTSC field/frame, 1800 PAL, 3753.75 film24,
//     3600 film25), and on an interlaced raster stays busy for the picture's
//     field count after a pickup;
//   * a CLOCK: one tick every TICK_DIV clocks (time compressed; the DUT never
//     sees the divisor).
//
// The measurement at every pickup is the DUT's own disp_lag (= PTS the picture
// wanted - STC at the pickup), and the bench computes the picture's wanted
// time independently from the scenario's PTS list and the same duration rules
// (frame_rate_code x fields) to check the DUT is scheduling the picture the
// scenario intended, not just "a" picture. PASS per scenario: every steady-
// state pickup within half a scan of its PTS, lates/re-anchors exactly as the
// scenario predicts. Mutation-checked by bench/dvd/run_disp_sched.sh.
//
// Build: iverilog -g2012 -o bench/dvd/disp_sched_sim dvd/disp_sched.sv bench/dvd/disp_sched_tb.sv
// =============================================================================
`timescale 1ns/1ps
module disp_sched_tb;

  reg clk = 0; always #5 clk = ~clk;
  reg rst_n = 0;
  localparam integer TICK_DIV = 4;

  // ---------------------------------------------------------------- DUT I/O
  reg         flush = 0, sched_en = 1, tick = 0, video_live = 0, pause = 0;
  reg  [32:0] prov_pts = 0; reg prov_valid = 0;
  reg         pic_valid = 0, pic_pts_valid = 0, pic_pts_2nd = 0, pic_ps = 0, pic_pf = 1, pic_tff = 1, pic_rff = 0;
  reg  [32:0] pic_pts = 0;
  reg   [3:0] frc = 4;
  reg         pickup = 0;
  reg         skip_ack = 0, skip_field = 0, skip_ps = 0, skip_pf = 1, skip_tff = 1, skip_rff = 0;
  reg  [15:0] half_scan = 750;
  wire        pic_due, next_due, anchored, disp_anchored, anchor_req, disp_lag_valid, catchup_late;
  wire [32:0] stc;
  wire signed [33:0] anchor_delta, disp_lag;

  disp_sched dut (
    .clk(clk), .rst_n(rst_n), .flush(flush), .sched_en(sched_en),
    .tick(tick), .video_live(video_live), .pause(pause),
    .prov_pts(prov_pts), .prov_valid(prov_valid),
    .pic_valid(pic_valid), .pic_pts_valid(pic_pts_valid), .pic_pts(pic_pts), .pic_pts_2nd(pic_pts_2nd),
    .pic_ps(pic_ps), .pic_pf(pic_pf), .pic_tff(pic_tff), .pic_rff(pic_rff),
    .frame_rate_code(frc), .pickup(pickup),
    .skip_ack(skip_ack), .skip_field(skip_field), .skip_ps(skip_ps), .skip_pf(skip_pf),
    .skip_tff(skip_tff), .skip_rff(skip_rff),
    .half_scan(half_scan),
    .pic_due(pic_due), .next_due(next_due), .stc(stc), .anchored(anchored), .disp_anchored(disp_anchored),
    .anchor_req(anchor_req), .anchor_delta(anchor_delta),
    .disp_lag_valid(disp_lag_valid), .disp_lag(disp_lag),
    .dbg_flags(), .dbg_dur(), .catchup_late(catchup_late));

  // ------------------------------------------------------------- the clock
  integer now = 0;                       // ticks since scenario start
  integer div = 0;
  always @(posedge clk) begin
    tick <= 1'b0;
    if (div == TICK_DIV - 1) begin div <= 0; tick <= 1'b1; now <= now + 1; end
    else div <= div + 1;
  end

  // ------------------------------------------------------- scripted pictures
  localparam MAXPIC = 4096;
  reg        s_tag  [0:MAXPIC-1];
  reg [32:0] s_pts  [0:MAXPIC-1];       // the PTS the tag carries (may name the second field)
  reg [32:0] s_true [0:MAXPIC-1];       // the picture's TRUE first-field PTS (always known to the bench)
  reg        s_2nd  [0:MAXPIC-1];
  reg        s_ps   [0:MAXPIC-1], s_pf [0:MAXPIC-1], s_tff [0:MAXPIC-1], s_rff [0:MAXPIC-1];
  reg        s_drop [0:MAXPIC-1];
  reg        s_field[0:MAXPIC-1];
  integer    s_ready[0:MAXPIC-1];       // tick at which the decoder finishes it
  integer    n_pic = 0;

  // the raster
  integer scan_a = 1501, scan_b = 1502;  // alternating scan lengths (1501.5 avg)
  integer scan_pat = 2;                  // pattern length (film24: 3754,3754,3753,3754 -> use 4)
  integer scan_c = 0, scan_d = 0;
  reg     ilace = 0;

  // ---------------------------------------------------------------- engine
  integer di = 0;                        // next picture the decoder produces
  integer next_opp = 0;                  // tick of the next pickup opportunity
  integer busy = 0;                      // scans still owned by the last pickup (interlaced)
  integer scan_i = 0;
  integer cur = -1;                      // index of the picture at the output
  integer lates = 0, pickups = 0, reanchors = 0, max_abs_lag = 0, worst_pic = -1;
  integer settle = 0;                    // pickups to ignore for the lag statistic (anchoring)
  integer lag_i;
  integer fields_of;

  task automatic set_out(input integer i);
    begin
      cur = i; pic_valid = 1;
      pic_pts_valid = s_tag[i]; pic_pts = s_pts[i]; pic_pts_2nd = s_2nd[i];
      pic_ps = s_ps[i]; pic_pf = s_pf[i]; pic_tff = s_tff[i]; pic_rff = s_rff[i];
    end
  endtask

  integer scan_len;
  reg tight = 0;                          // hand pictures over in the opportunity's own tick
  always @(posedge clk) if (rst_n && tick) begin
    // decoder side: hand the next ready picture to the output, or drop it
    if (di < n_pic && s_ready[di] <= now && !(tight && ((di % 4) == 0))) begin
      if (s_drop[di]) begin
        skip_ack <= 1'b1; skip_field <= s_field[di]; skip_ps <= s_ps[di]; skip_pf <= s_pf[di];
        skip_tff <= s_tff[di]; skip_rff <= s_rff[di];
        di = di + 1;
      end else if (!pic_valid) begin
        set_out(di); di = di + 1;
      end
    end
  end
  always @(posedge clk) begin
    if (skip_ack && !tick) skip_ack <= 1'b0;
    else if (skip_ack && tick) skip_ack <= 1'b0;
  end

  // raster side: opportunities every scan; check and pick up
  always @(posedge clk) if (rst_n && tick && (now >= next_opp)) begin
    case (scan_i % scan_pat)
      0: scan_len = scan_a; 1: scan_len = scan_b; 2: scan_len = scan_c; default: scan_len = scan_d;
    endcase
    scan_i = scan_i + 1;
    next_opp = next_opp + scan_len;
    // `tight`: EVERY FOURTH picture appears at picbuf's output in the SAME cycle the
    // display looks at it -- the coincidence that happens whenever the decoder is
    // running at the display's own rate. Done HERE, inside the raster block, so the
    // ordering is deterministic (relying on inter-always-block order is not). Making
    // EVERY picture coincide is pathological: the decoder could then never run ahead
    // and a one-cycle capture gate would cost a whole opportunity per picture.
    if (tight && ((di % 4) == 0) && !pic_valid && di < n_pic && s_ready[di] <= now && !s_drop[di]) begin
      set_out(di); di = di + 1;
    end
    if (busy > 0) busy = busy - 1;
    else if (pic_valid && pic_due) begin
      pickup <= 1'b1;
      if (ilace) begin
        fields_of = pic_ps ? (pic_rff ? (pic_tff ? 6 : 4) : 2) : ((pic_pf && pic_rff) ? 3 : 2);
        busy = fields_of - 1;
      end
    end else if (!pic_valid && next_due) lates = lates + 1;
  end
  always @(posedge clk) if (pickup) begin
    pickup <= 1'b0; pic_valid <= 1'b0; video_live <= 1'b1;
  end
  reg verbose = 0;
  always @(posedge clk) if (anchor_req && verbose)
    $display("    anchor: pic %0d stc->%0d delta=%0d has_tag=%0d next_valid=%0d d_pic_next=%0d d_stc_pic=%0d now=%0d",
             cur, stc, anchor_delta, dut.has_tag, dut.next_valid, dut.d_pic_next, dut.d_stc_pic, now);
  // THE MEASUREMENT: the scenario's TRUE PTS for the picture against the DUT's
  // clock at the pickup -- never the DUT's own idea of when the picture was
  // wanted (a wrong idea would then score a perfect lag). Sampled on the pickup
  // clk, when `cur` still names the picture and stc is not yet re-anchored.
  reg signed [33:0] true_lag;
  always @(posedge clk) if (pickup) begin
    true_lag = $signed({1'b0, s_true[cur]}) - $signed({1'b0, stc});
    pickups = pickups + 1;
    if (settle > 0) settle = settle - 1;
    else if (dut.anchor_now) ;             // the anchoring pickup defines the timeline; its lag is the jump itself
    else begin
      lag_i = true_lag; if (lag_i < 0) lag_i = -lag_i;
      if (lag_i > max_abs_lag) begin max_abs_lag = lag_i; worst_pic = cur; end
    end
  end
  always @(posedge clk) if (anchor_req) reanchors = reanchors + 1;
  integer catchups = 0;
  always @(posedge clk) if (catchup_late) catchups = catchups + 1;

  // ------------------------------------------------------------ scenarios
  integer errors = 0;
  integer i, t, p;
  integer stat_lates, stat_re, stat_lag;

  task automatic reset_world(input integer hs, input integer sa, input integer sb, input integer sc, input integer sd, input integer pat, input integer il, input integer code);
    begin
      half_scan = hs; scan_a = sa; scan_b = sb; scan_c = sc; scan_d = sd; scan_pat = pat; ilace = il; frc = code;
      n_pic = 0; di = 0; cur = -1; pic_valid = 0; video_live = 0; pause = 0; prov_valid = 0;
      lates = 0; pickups = 0; reanchors = 0; catchups = 0; max_abs_lag = 0; worst_pic = -1; busy = 0; scan_i = 0; settle = 2;
      flush = 1; repeat (4) @(posedge clk); flush = 0;
      now = 0; next_opp = 20;
      repeat (4) @(posedge clk);
    end
  endtask

  // append one picture: true pts, tagged?, flags, ready tick (relative), dropped?
  task automatic add_pic(input integer pts, input integer tag, input integer ps, input integer pf, input integer tff, input integer rff, input integer ready, input integer drop, input integer second, input integer fieldpic);
    begin
      s_pts[n_pic] = pts; s_true[n_pic] = pts; s_tag[n_pic] = tag; s_ps[n_pic] = ps; s_pf[n_pic] = pf; s_tff[n_pic] = tff; s_rff[n_pic] = rff;
      s_ready[n_pic] = ready; s_drop[n_pic] = drop; s_2nd[n_pic] = second; s_field[n_pic] = fieldpic;
      n_pic = n_pic + 1;
    end
  endtask

  // 3:2 film: NTSC 29.97 timebase, progressive_frame=1, rff alternating -> 3,2,3,2 fields
  task automatic film_32(input integer count, input integer pts0, input integer tag_every, input integer lead);
    integer k, pts, rff;
    begin
      pts = pts0;
      for (k = 0; k < count; k = k + 1) begin
        rff = k & 1;   // pattern 0,1,0,1 -> 2,3,2,3 fields
        add_pic(pts, ((k % tag_every) == 0) ? 1 : 0, 0, 1, 1, rff, pts0 - lead, 0, 0, 0);   // pre-decoded: a full VBUF
        pts = pts + (rff ? 4504 : 3003) + ((rff && (k & 2)) ? 1 : 0);   // 3 fields = 4504.5 -> alternate the half
      end
    end
  endtask

  task automatic run_until_done(input integer extra);
    integer guard;
    begin
      guard = 0;
      while (((di < n_pic) || pic_valid) && (guard < 20000000)) begin @(posedge clk); guard = guard + 1; end
      repeat (extra) @(posedge clk);
    end
  endtask

  task automatic report(input [200*8-1:0] name, input integer want_lates_zero, input integer want_re, input integer lag_tol);
    begin
      $display("  %0s: pickups=%0d lates=%0d reanchors=%0d max|lag|=%0d (worst pic %0d) stc=%0d",
               name, pickups, lates, reanchors, max_abs_lag, worst_pic, stc);
      if (pickups == 0) begin $display("FAIL %0s: nothing displayed", name); errors = errors + 1; end
      if (want_lates_zero && (lates != 0)) begin $display("FAIL %0s: %0d lates, expected 0", name, lates); errors = errors + 1; end
      if (!want_lates_zero && (lates == 0)) begin $display("FAIL %0s: expected lates, saw none", name); errors = errors + 1; end
      if ((want_re >= 0) && (reanchors != want_re)) begin $display("FAIL %0s: %0d re-anchors, expected %0d", name, reanchors, want_re); errors = errors + 1; end
      if (max_abs_lag > lag_tol) begin $display("FAIL %0s: max |lag| %0d > %0d", name, max_abs_lag, lag_tol); errors = errors + 1; end
    end
  endtask

  initial begin
    #40 rst_n = 1;
    if ($test$plusargs("VERBOSE")) verbose = 1;

    // [1] 3:2 film on the 59.94 interlaced raster: the cadence must emerge from PTS
    reset_world(750, 1501, 1502, 0, 0, 2, 1, 4);
    film_32(120, 100000, 12, 20000);
    prov_pts <= 100000; prov_valid <= 1; @(posedge clk); prov_valid <= 0;   // NBA: a blocking pulse races the DUT's sample
    run_until_done(200);
    report("[1] 3:2 on 480i", 1, 1, 752);

    // [2] the same content on the film24 raster (one picture per scan)
    reset_world(1877, 3754, 3754, 3753, 3754, 4, 0, 4);
    film_32(120, 100000, 12, 20000);
    run_until_done(200);
    report("[2] 3:2 on film24", 1, 1, 1879);

    // [3] PAL 25 fps on the PAL interlaced raster (2 fields per picture)
    reset_world(900, 1800, 1800, 0, 0, 2, 1, 3);
    for (i = 0; i < 100; i = i + 1) add_pic(50000 + i * 3600, ((i % 12) == 0) ? 1 : 0, 0, 0, 1, 0, 30000, 0, 0, 0);
    run_until_done(200);
    report("[3] PAL 25 on 576i", 1, 1, 902);

    // [4] per-picture PTS (VCD-like) on the progressive 59.94 raster, 29.97 content
    reset_world(750, 1501, 1502, 0, 0, 2, 0, 4);
    for (i = 0; i < 100; i = i + 1) add_pic(9000 + i * 3003, 1, 1, 1, 0, 0, 4000, 0, 0, 0);
    run_until_done(200);
    report("[4] per-picture PTS 29.97 on 480p", 1, 1, 752);

    // [5] a late decoder: pictures 30..59 become ready growing later (up to ~6 frames),
    //     then early again. Lates must appear; lateness stays under LATE_MAX so no re-anchor;
    //     the lag statistic is only judged after the recovery.
    reset_world(750, 1501, 1502, 0, 0, 2, 1, 4);
    film_32(120, 100000, 12, 20000);
    for (i = 30; i < 60; i = i + 1) s_ready[i] = s_pts[i] - 20000 + (i - 29) * 600;   // late by up to 200 ms
    run_until_done(200);
    if (lates == 0) begin $display("FAIL [5] late decoder: no lates counted"); errors = errors + 1; end
    if (reanchors != 1) begin $display("FAIL [5] late decoder: %0d re-anchors", reanchors); errors = errors + 1; end
    $display("  [5] late decoder: lates=%0d reanchors=%0d (lag not judged: lateness is the stimulus)", lates, reanchors);
    // recovery: a late display cannot catch up by itself (every picture still owns its
    //     full duration); the frame-drop governor does that by dropping B's -- so the
    //     decoder drops 8 pictures after the window (skip_ack) and the display, now ahead,
    //     WAITS for its PTS again: pictures after that must land on time.
    reset_world(750, 1501, 1502, 0, 0, 2, 1, 4);
    film_32(120, 100000, 12, 20000);
    for (i = 30; i < 60; i = i + 1) s_ready[i] = s_pts[i] - 20000 + (i - 29) * 600;
    for (i = 61; i < 77; i = i + 2) if ((i % 12) != 0) s_drop[i] = 1;
    settle = 80;   // judge only the pictures after the drops
    run_until_done(200);
    if (max_abs_lag > 752) begin $display("FAIL [5b] after the drops pictures still off by %0d", max_abs_lag); errors = errors + 1; end
    if (reanchors != 1) begin $display("FAIL [5b] %0d re-anchors", reanchors); errors = errors + 1; end
    $display("  [5b] post-recovery max|lag|=%0d lates=%0d reanchors=%0d", max_abs_lag, lates, reanchors);

    // [6] drops: every 7th B is dropped (skip_ack), in BOTH orderings -- some acks land while
    //     a picture waits at the output (deferred), some while nothing waits. The next TAGGED
    //     picture must not re-anchor and the timeline must stay within half a scan.
    reset_world(750, 1501, 1502, 0, 0, 2, 1, 4);
    film_32(160, 100000, 12, 20000);
    for (i = 3; i < 160; i = i + 7) if ((i % 12) != 0) s_drop[i] = 1;
    run_until_done(200);
    report("[6] governor drops, deferred and immediate", 1, 1, 752);

    // [7a] backward jump (a menu loop): PTS restarts 5 s earlier -> exactly one re-anchor
    reset_world(750, 1501, 1502, 0, 0, 2, 1, 4);
    film_32(60, 600000, 12, 20000);
    film_32(60, 150000, 12, 20000);
    for (i = 60; i < 120; i = i + 1) s_ready[i] = s_ready[59] + (i - 59) * 3754;
    run_until_done(200);
    report("[7a] backward PTS jump", 1, 2, 752);

    // [7d] a 200 ms backward jump: too small for LATE_MAX, so only the backward rule re-anchors
    reset_world(750, 1501, 1502, 0, 0, 2, 1, 4);
    film_32(60, 600000, 12, 20000);
    film_32(60, 600000 + 60 * 3754 - 18000, 12, 20000);
    run_until_done(200);
    report("[7d] 200 ms backward jump", 1, 2, 752);

    // [7b] a 0.3 s forward gap is WAITED OUT (no re-anchor): the picture after the gap is
    //      decoded EARLY (it is in the buffer) and must be held until its PTS, no lates
    reset_world(750, 1501, 1502, 0, 0, 2, 1, 4);
    film_32(60, 100000, 12, 20000);
    film_32(60, 100000 + 60 * 3754 + 27000, 12, 20000);
    for (i = 60; i < 120; i = i + 1) s_ready[i] = s_ready[59] + (i - 59) * 3754;
    run_until_done(200);
    report("[7b] 0.3 s forward gap waited out", 1, 1, 752);

    // [7c] a 2 s forward gap re-anchors (an authored discontinuity, too long to wait)
    reset_world(750, 1501, 1502, 0, 0, 2, 1, 4);
    film_32(60, 100000, 12, 20000);
    film_32(60, 100000 + 60 * 3754 + 180000, 12, 20000);
    for (i = 60; i < 120; i = i + 1) s_ready[i] = s_ready[59] + (i - 59) * 3754;
    run_until_done(200);
    report("[7c] 2 s forward gap re-anchors", 1, 2, 752);

    // [8] LATE_MAX: the reader holds a still for 1 s (no pictures, clock runs), then the
    //     continuous timeline resumes -> the first picture is 1 s late -> re-anchor, then on time
    reset_world(750, 1501, 1502, 0, 0, 2, 1, 4);
    film_32(120, 100000, 12, 20000);
    for (i = 60; i < 120; i = i + 1) s_ready[i] = s_pts[i] - 20000 + 360000;  // decoded 4 s after its PTS: a reader-held still (past LATE_MAX)
    settle = 62;
    run_until_done(200);
    report("[8] LATE_MAX after a held still", 0, 2, 752);

    // [8b] ⚠ THE REGRESSION FOR THE HW ROUND-B DEFECT: a 400 ms starvation is
    //      RECOVERABLE lateness, not a discontinuity. It must re-anchor ZERO times
    //      (only the initial anchor), or the clock is dragged backwards and the
    //      audio with it -- "out of sync by a varying amount" that a seek cannot fix.
    //      The governor's drops are what put the display back on schedule.
    reset_world(750, 1501, 1502, 0, 0, 2, 1, 4);
    film_32(120, 100000, 12, 20000);
    // ⚠ Model BOTH halves or the scenario asserts something the design never claimed:
    // a BURST of starvation (not a permanent delivery delay -- the decoder gets ahead
    // again, which is what the drops buy it), and the DROPS themselves, because on the
    // interlaced path a picture always occupies its own field count and the display
    // cannot fast-forward through a backlog on its own.
    for (i = 40; i < 60; i = i + 1) s_ready[i] = s_pts[i] - 20000 + 36000;   // 400 ms late, 20 pictures
    for (i = 61; i < 85; i = i + 2) if ((i % 12) != 0) s_drop[i] = 1;        // the governor works it off
    settle = 88;
    run_until_done(200);
    if (reanchors != 1) begin
      $display("FAIL [8b] a 400 ms starvation re-anchored %0d time(s) -- lateness is not a discontinuity", reanchors);
      errors = errors + 1;
    end
    if (max_abs_lag > 752) begin
      $display("FAIL [8b] after the drops pictures still off by %0d", max_abs_lag); errors = errors + 1; end
    $display("  [8b] 400 ms starvation: lates=%0d reanchors=%0d max|lag|=%0d (must be 1 re-anchor)", lates, reanchors, max_abs_lag);

    // [8d] CATCH-UP: at maximum display rate the display cannot recover a phase
    //      error on its own (one picture per scan IS the content rate in film24),
    //      so a picture picked up while more than a frame late must REQUEST A DROP.
    //      Measured on hardware before this existed: the timeline sat flat but
    //      1.83 s behind the clock, audio a fixed 1.83 s ahead of the picture.
    //      Here the film24 raster is started 1 s behind the content; the scheduler
    //      must ask for drops, and must stop asking once it is back in step.
    //      ⚠ The offset must appear AFTER the timeline is established: a clock
    //      skewed before the first pickup is simply erased by the anchor. So the
    //      display is starved for ~1 s mid-run, which at max rate it can never
    //      work off -- exactly the hardware case.
    reset_world(1877, 3754, 3754, 3753, 3754, 4, 0, 4);
    film_32(200, 100000, 12, 20000);
    for (i = 40; i < 64; i = i + 1) s_ready[i] = s_pts[i] - 20000 + 90000;   // 1 s of starvation
    settle = 70;
    run_until_done(200);
    if (catchups == 0) begin
      $display("FAIL [8d] display 1 s behind at max rate: no drop requested -- it can never recover");
      errors = errors + 1;
    end
    $display("  [8d] catch-up: %0d drop requests, %0d pickups, reanchors=%0d", catchups, pickups, reanchors);

    // [8e] the steady state must NOT request drops
    reset_world(1877, 3754, 3754, 3753, 3754, 4, 0, 4);
    film_32(200, 100000, 12, 20000);
    run_until_done(200);
    if (catchups != 0) begin
      $display("FAIL [8e] steady state requested %0d drops -- the threshold is too tight", catchups);
      errors = errors + 1;
    end
    $display("  [8e] steady state: %0d drop requests (must be 0)", catchups);

    // [8f] A RASTER CHANGE IS A KNOWN DISCONTINUITY: a video->film engage restarts
    //      the raster and fires no flush, so the clock free-runs across a transition
    //      in which nothing is displayed. The scheduler must re-anchor at the next
    //      TAGGED picture -- without dropping anything -- instead of carrying the
    //      lost time forever. Modelled by switching half_scan mid-run while the
    //      decoder stalls across the change.
    reset_world(750, 1501, 1502, 0, 0, 2, 1, 4);
    film_32(160, 100000, 12, 20000);
    for (i = 60; i < 76; i = i + 1) s_ready[i] = s_pts[i] - 20000 + 72000;   // 0.8 s dark transition
    fork
      begin
        wait (pickups >= 60);
        half_scan = 1877; scan_a = 3754; scan_b = 3754; scan_c = 3753; scan_d = 3754;
        scan_pat = 4; ilace = 0;                       // the film raster
      end
      run_until_done(200);
    join
    settle = 0;
    // ⚠ REVERSED 2026-09-07: this used to require a RE-ANCHOR here. That made the
    // telemetry perfect and the sync wrong -- pulling the clock back does not move
    // the audio, which has already played that time. The display must ADVANCE to
    // meet the audio, i.e. request drops, and must NOT re-anchor.
    if (catchups == 0) begin
      $display("FAIL [8f] raster change: no drop requested -- the display can never meet the audio");
      errors = errors + 1;
    end
    if (reanchors > 1) begin
      $display("FAIL [8f] raster change re-anchored (%0d) -- that moves the clock away from the audio", reanchors);
      errors = errors + 1;
    end
    $display("  [8f] raster change: reanchors=%0d catchups=%0d (want 1 anchor, >0 drops)", reanchors, catchups);

    // [9] second-field tags: the tag names the SECOND field (one field later)
    reset_world(750, 1501, 1502, 0, 0, 2, 1, 4);
    film_32(120, 100000, 12, 20000);
    for (i = 0; i < 120; i = i + 12) begin s_2nd[i] = 1; s_pts[i] = s_pts[i] + 1501; end
    run_until_done(200);
    report("[9] second-field tags", 1, 1, 754);

    // [10] a PTS-less stream (bare .m2v): anchors at 0 at the first pickup, extrapolated schedule
    reset_world(750, 1501, 1502, 0, 0, 2, 0, 4);
    for (i = 0; i < 100; i = i + 1) add_pic(i * 3003, 0, 1, 1, 0, 0, 1000, 0, 0, 0);
    run_until_done(200);
    if (dut.stc < 33'd200000) begin $display("FAIL [10] PTS-less: stc %0d did not advance from 0", dut.stc); errors = errors + 1; end
    report("[10] PTS-less stream", 1, 1, 752);

    // [11] pause freezes the clock; on resume the next picture is due at once, no lates
    reset_world(750, 1501, 1502, 0, 0, 2, 1, 4);
    film_32(120, 100000, 12, 20000);
    for (i = 40; i < 120; i = i + 1) s_ready[i] = s_ready[i] + 60000;   // the decoder also stops during the pause
    fork
      begin
        wait (pickups == 40); pause = 1;
        repeat (60000 * TICK_DIV) @(posedge clk);
        pause = 0;
      end
      run_until_done(200);
    join
    report("[11] pause", 1, 1, 752);

    // [12] provisional anchor equals the first tagged pickup -> delta 0
    reset_world(750, 1501, 1502, 0, 0, 2, 1, 4);
    film_32(30, 100000, 12, 20000);
    prov_pts <= 100000; prov_valid <= 1; @(posedge clk); prov_valid <= 0;   // NBA: a blocking pulse races the DUT's sample
    repeat (3) @(posedge clk);
    if (verbose) $display("    [12] after prov pulse: stc=%0d anchored=%0d", dut.stc, dut.anchored);
    run_until_done(200);
    if (anchor_delta != 0) begin $display("FAIL [12] first pickup delta %0d, expected 0", anchor_delta); errors = errors + 1; end
    report("[12] provisional anchor", 1, 1, 752);

    // [13] disp_anchored: THE PROVISIONAL ANCHOR MUST NOT SET IT.
    //      On a cold mount the parse front runs up to ~1.6 s ahead of the picture, so
    //      a clock anchored provisionally is NOT on the display's timeline. Audio's
    //      playback phase is latched ONCE against this flag, so a flag that rises
    //      early leaves audio permanently that far ahead -- MEASURED on APOLLO_13,
    //      2026-09-07, with the raster unchanged throughout.
    //      Asserted in three parts: not set by prov alone; not set by an UNTAGGED
    //      pickup (the case that actually bit -- the clock anchors to its own
    //      parse-front value and nothing changes); set at the first TAGGED pickup.
    reset_world(750, 1501, 1502, 0, 0, 2, 1, 4);
    film_32(30, 100000, 4, 20000);                    // tag_every=4 -> tags at 0,4,8,...
    for (i = 0; i < 4; i = i + 1) s_tag[i] = 0;        // ...so picture 4 is the FIRST tagged one
    prov_pts <= 900000; prov_valid <= 1; @(posedge clk); prov_valid <= 0;   // parse front, ~10 s ahead
    repeat (4) @(posedge clk);
    if (!anchored) begin
      $display("FAIL [13] the provisional pulse did not anchor the clock at all");
      errors = errors + 1;
    end
    if (disp_anchored) begin
      $display("FAIL [13] provisional anchor set disp_anchored -- audio would start against the parse front");
      errors = errors + 1;
    end
    fork
      begin
        wait (pickups >= 1);
        repeat (4) @(posedge clk);
        if (disp_anchored) begin
          $display("FAIL [13] an UNTAGGED pickup set disp_anchored -- that anchor keeps the parse-front value");
          errors = errors + 1;
        end
        wait (pickups >= 6);                            // past the untagged run
        repeat (4) @(posedge clk);
        if (!disp_anchored) begin
          $display("FAIL [13] disp_anchored never set after a tagged pickup -- audio would wait for the fallback on every load");
          errors = errors + 1;
        end
      end
      run_until_done(200);
    join
    $display("  [13] disp_anchored: prov=no, untagged=no, tagged=yes");

    // [13b] disp_anchored must arrive PROMPTLY, not only on a discontinuity.
    //       [13] uses a 10 s provisional lead, which trips disc_w, so it would pass
    //       even if the first tagged picture only anchored when it also looked like a
    //       jump. The dangerous case is a SMALL provisional error (here 22 ms, inside
    //       one frame): disc_w never fires, so without the !disp_anchored term the
    //       flag can go unset for the whole title and audio falls through to the
    //       ~2.5 s arm_timer fallback -- which releases against the provisional clock,
    //       i.e. straight back to the defect this whole change removes.
    reset_world(750, 1501, 1502, 0, 0, 2, 1, 4);
    film_32(30, 100000, 4, 20000);
    for (i = 0; i < 4; i = i + 1) s_tag[i] = 0;
    prov_pts <= 100000 + 2000; prov_valid <= 1; @(posedge clk); prov_valid <= 0;   // 22 ms < one frame
    fork
      begin
        wait (pickups >= 8);                            // 4 untagged, then tagged from 4
        repeat (4) @(posedge clk);
        if (!disp_anchored) begin
          $display("FAIL [13b] a small provisional error never yielded a display anchor -- audio takes the fallback against the parse front");
          errors = errors + 1;
        end
      end
      run_until_done(200);
    join
    $display("  [13b] disp_anchored arrives without a discontinuity");

    if (errors == 0) $display("PASS: disp_sched_tb — 18 scenarios");
    else begin $display("FAIL: disp_sched_tb — %0d error(s)", errors); $fatal(1); end
    $finish;
  end

endmodule
