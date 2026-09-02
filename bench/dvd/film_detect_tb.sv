`timescale 1ns/1ps
//
// film_detect_tb.sv — verify the automatic film cadence detector in
// dvd/resample_addrgen.v (Film 24p Out, issue #124 Phase 2).
//
// The detector watches the committed progressive_frame + repeat_first_field flags
// once per display pickup and produces two sticky, hysteretic verdicts:
//   film_det_ntsc = sustained clean 3:2 soft-telecine (progressive + ALTERNATING rff)
//   film_det_pal  = sustained progressive_frame run (PAL native 25p)
//
// The two must correctly SEPARATE the cadence classes so emu can engage 24p/25p
// only when safe (a false positive forces the film raster onto true video = a
// dropped-frame REGRESSION):
//   NTSC 24p film      (pf=1, rff 1,0,1,0..)  -> det_ntsc=1, det_pal=1
//   30fps prog. video  (pf=1, rff=0 constant) -> det_ntsc=0 (!!), det_pal=1
//   60i / 50i video    (pf=0)                 -> det_ntsc=0,     det_pal=0
// Plus hysteresis: it takes a LONG confirming run to engage, and a sustained
// non-film run to disengage (a lone cadence hiccup must not flip it).
//
// Build:
//   iverilog -g2012 -I rtl/mpeg2 -o bench/dvd/film_detect_sim \
//       dvd/resample_addrgen.v rtl/mpeg2/mem_addr.v bench/dvd/film_detect_tb.sv
//   vvp bench/dvd/film_detect_sim
//
module film_detect_tb;
  reg         clk = 0, clk_en = 1, rst = 0;
  reg   [2:0] output_frame = 3'd1;
  wire        output_frame_rd;
  reg         progressive_sequence = 0, progressive_frame = 1;
  // DVD-FORK (film evidence gate): 1 = this picture carried real evidence. Default 1,
  // so every pre-existing scenario below runs exactly as it did before the gate.
  reg         tb_informative = 1;
  reg         top_field_first = 0, repeat_first_field = 0;
  reg   [7:0] mb_width = 8'd1, mb_height = 8'd1;   // tiny frame -> very fast scans
  reg  [13:0] horizontal_size = 14'd16, vertical_size = 14'd4;
  reg         interlaced = 0, deinterlace = 1, persistence = 1;
  reg   [4:0] repeat_frame = 0;
  reg         disp_wr_addr_full = 0, disp_wr_addr_ack = 1;
  wire        disp_wr_addr_en;
  wire [21:0] disp_wr_addr;
  wire  [2:0] resample_wr_dta;
  wire        resample_wr_en;
  reg         disp_wr_addr_almost_full = 0, resample_wr_almost_full = 0;
  wire        busy;
  wire        frame_late;
  wire        film_det_ntsc, film_det_pal;
  wire        det_video;                    // DVD-FORK (Interlaced Out auto): true-interlaced verdict

  // decoder-supply model: keep a few frames buffered so pickups keep flowing
  integer     supplied = 0, consumed = 0;
  wire        output_frame_valid_w = (supplied != consumed);

  resample_addrgen dut (
    .clk(clk), .clk_en(clk_en), .rst(rst),
    .output_frame(output_frame), .output_frame_valid(output_frame_valid_w), .output_frame_rd(output_frame_rd),
    .progressive_sequence(progressive_sequence), .progressive_frame(progressive_frame), .informative(tb_informative),
    .top_field_first(top_field_first), .repeat_first_field(repeat_first_field),
    .mb_width(mb_width), .mb_height(mb_height),
    .horizontal_size(horizontal_size), .vertical_size(vertical_size),
    .interlaced(interlaced), .deinterlace(deinterlace),
    .persistence(persistence), .repeat_frame(repeat_frame),
    .disp_wr_addr_full(disp_wr_addr_full), .disp_wr_addr_en(disp_wr_addr_en),
    .disp_wr_addr_ack(disp_wr_addr_ack), .disp_wr_addr(disp_wr_addr),
    .resample_wr_dta(resample_wr_dta), .resample_wr_en(resample_wr_en),
    .disp_wr_addr_almost_full(disp_wr_addr_almost_full), .resample_wr_almost_full(resample_wr_almost_full),
    .busy(busy), .frame_late(frame_late),
    .film_det_ntsc(film_det_ntsc), .film_det_pal(film_det_pal),
    .det_video(det_video),
    .video_live(), .pickup_hold(1'b0), .pause(1'b0),
    .raster_par_err(1'b0), .vscale_mode(2'd0), .hcrop_en(1'b0), .menu_ff(1'b0), .film24(1'b0));

  always #5 clk = ~clk;

  // consume a decoded frame when the governor reads one
  always @(posedge clk)
    if (rst && output_frame_rd) consumed <= consumed + 1;

  // keep the supply topped up (>=2 frames ahead) so pickups happen back-to-back
  always @(posedge clk)
    if (rst && ((supplied - consumed) < 3)) supplied <= supplied + 1;

  // ---- cadence driver: set the NEXT frame's flags right after each pickup, so
  //      they are stable well before the following pickup samples them. ----
  //   mode 0 = NTSC film   : pf=1, rff alternates every frame (3:2)
  //   mode 1 = 30fps video : pf=1, rff=0 constant (no telecine)
  //   mode 2 = 60i/50i vid : pf=0
  //   mode 3 = film + a SINGLE hiccup injected once (hysteresis probe)
  integer mode = 0;
  integer pk = 0;          // pickup counter
  integer hiccup_at = -1;  // pickup index to inject one non-toggling frame (mode 3)
  always @(posedge clk)
    if (rst && output_frame_rd) begin
      pk <= pk + 1;
      case (mode)
        0: begin progressive_frame <= 1'b1; repeat_first_field <= ~repeat_first_field; end
        1: begin progressive_frame <= 1'b1; repeat_first_field <= 1'b0; end
        2: begin progressive_frame <= 1'b0; repeat_first_field <= 1'b0; end
        3: begin
             progressive_frame <= 1'b1;
             // one held (non-toggling) frame at hiccup_at, else keep alternating
             if (pk == hiccup_at) repeat_first_field <= repeat_first_field;
             else                 repeat_first_field <= ~repeat_first_field;
           end
        4: begin
             // film with a PERIODIC hiccup (every 8th pickup non-toggling) — models
             // the menu/VM-path cadence breaks that a strict consecutive-run detector
             // never survived. Must still ENGAGE (issue-1 regression).
             progressive_frame <= 1'b1;
             if (pk % 8 == 7) repeat_first_field <= repeat_first_field;
             else             repeat_first_field <= ~repeat_first_field;
           end
      endcase
    end

  integer errors = 0;
  task chk(input cond, input [255:0] msg);
    if (!cond) begin $display("  FAIL: %0s", msg); errors = errors + 1; end
  endtask

  // MUTUAL EXCLUSIVITY: the true-interlaced verdict (progressive_frame==0) and the film
  // verdicts (progressive_frame==1) can never co-assert — they key on opposite senses of
  // the same flag. Continuously guard it (a co-assert would let emu pick two output modes).
  always @(posedge clk)
    if (rst && det_video && (film_det_ntsc || film_det_pal)) begin
      $display("  FAIL: det_video co-asserted with a film verdict (n=%b p=%b v=%b)",
               film_det_ntsc, film_det_pal, det_video);
      errors = errors + 1;
    end

  // run until `n` more pickups have completed
  task run_pickups(input integer n);
    integer target; begin
      target = pk + n;
      while (pk < target) @(posedge clk);
    end
  endtask

  initial begin
    rst = 0; supplied = 0; consumed = 0;
    repeat (4) @(posedge clk);
    rst = 1;
    repeat (4) @(posedge clk);

    // ===== 1. NTSC 24p film: alternating rff, progressive =====
    mode = 0;
    run_pickups(30);
    chk(!film_det_ntsc, "det_ntsc engaged too early (< ENGAGE_N frames)");
    run_pickups(40);   // > ENGAGE_N (48) clean film frames total
    chk(film_det_ntsc, "det_ntsc did NOT engage on sustained 3:2 film");
    chk(film_det_pal,  "det_pal did NOT engage on progressive film");
    chk(!det_video,    "det_video FALSELY engaged on progressive film (must stay 0)");
    $display("  [1] NTSC film: det_ntsc=%b det_pal=%b det_video=%b after sustained 3:2 (expect 1/1/0)",
             film_det_ntsc, film_det_pal, det_video);

    // ===== 2. transition to 30fps progressive VIDEO (pf=1, rff=0) =====
    // det_ntsc must RELEASE (rff no longer toggles) but det_pal must HOLD
    // (still progressive) — this is the key false-positive guard: a 30p NTSC
    // video disc must NOT be forced to 24p. Deep hysteresis makes disengage
    // slow-by-design (~52 frames from full confidence at DN_SOFT=2), so run a
    // sustained non-toggling stretch — a real film→video transition costs a
    // couple of seconds of 24p-on-video before it backs off (acceptable; the
    // priority is robust ENGAGE through menu-path hiccups, see the detector).
    mode = 1;
    run_pickups(60);
    chk(!film_det_ntsc, "det_ntsc did NOT release on sustained 30fps progressive video");
    chk(film_det_pal,   "det_pal wrongly released on progressive video");
    chk(!det_video,     "det_video FALSELY engaged on 30fps progressive video");
    $display("  [2] 30fps video: det_ntsc=%b det_pal=%b det_video=%b (expect 0/1/0)",
             film_det_ntsc, film_det_pal, det_video);

    // ===== G. THE EVIDENCE GATE (informative=0 pickups) =====
    // The whole point of the gate: on a fade to black the encoder stops
    // describing field structure and marks pictures interlaced by default, so
    // progressive_frame goes 0 for reasons that have nothing to do with the
    // content. APOLLO_13's credits did that for seconds at a time and dropped
    // film lock nine times in 46 s. Those pickups must not count -- while a
    // GENUINE video stretch, which is informative, still must.
    mode = 0;
    run_pickups(60);
    chk(film_det_ntsc, "[G] setup: det_ntsc should be engaged on film before the fade");

    // G1: a long uninformative interlaced run = a fade. Film lock must HOLD.
    tb_informative = 1'b0;
    mode = 2;                       // pf=0, exactly what a black picture carries
    run_pickups(80);                // far longer than the ~13 pickups that release
    chk(film_det_ntsc, "[G1] film lock dropped on an UNINFORMATIVE interlaced run (the APOLLO_13 bug)");
    chk(!det_video,    "[G1] det_video engaged on uninformative pickups");
    $display("  [G1] 80 uninformative pf=0 pickups: det_ntsc=%b det_video=%b (expect 1/0)",
             film_det_ntsc, det_video);

    // G2: the same run, now INFORMATIVE = a real film->video change. Must follow it.
    tb_informative = 1'b1;
    run_pickups(80);
    chk(!film_det_ntsc, "[G2] film lock did NOT release on a genuine interlaced video run");
    chk(det_video,      "[G2] det_video did not engage on genuine interlaced video");
    $display("  [G2] 80 informative pf=0 pickups: det_ntsc=%b det_video=%b (expect 0/1)",
             film_det_ntsc, det_video);

    // G3: gated pickups must not disturb the 3:2 toggle test either -- the run
    // resumes across the gap rather than seeing a false rff edge.
    mode = 0; tb_informative = 1'b1;
    run_pickups(60);
    chk(film_det_ntsc, "[G3] film did not re-engage after the gated stretch");
    tb_informative = 1'b0;
    run_pickups(40);
    tb_informative = 1'b1;
    run_pickups(20);
    chk(film_det_ntsc, "[G3] film lock lost across a gated gap in the 3:2 run");
    $display("  [G3] film survives a 40-pickup gated gap: det_ntsc=%b (expect 1)", film_det_ntsc);

    // ===== 3. transition to 60i/50i interlaced VIDEO (pf=0) =====
    // Both film verdicts release AND the true-interlaced verdict must ENGAGE — this is
    // the signal that drives Interlaced Out Auto to the native fields path (480i/576i).
    mode = 2;
    run_pickups(30);
    chk(!film_det_ntsc, "det_ntsc engaged on interlaced video");
    chk(!film_det_pal,  "det_pal did NOT release on interlaced video");
    chk(!det_video,     "det_video engaged too early (< ENGAGE_TH interlaced frames)");
    run_pickups(30);    // > ENGAGE_TH (120 / UP_STEP 3 = 40) sustained interlaced frames
    chk(det_video,      "det_video did NOT engage on sustained interlaced video");
    $display("  [3] 60i video: det_ntsc=%b det_pal=%b det_video=%b (expect 0/0/1)",
             film_det_ntsc, film_det_pal, det_video);

    // ===== 4. false-positive guard: START on 30fps progressive video and run a
    //          LONG time — det_ntsc must NEVER engage (only det_pal). =====
    mode = 1;
    run_pickups(120);
    chk(!film_det_ntsc, "det_ntsc FALSELY engaged on a long 30fps-video run (REGRESSION)");
    chk(film_det_pal,   "det_pal did not hold on long progressive video");
    chk(!det_video,     "det_video did NOT release on sustained progressive video");
    $display("  [4] long 30fps video: det_ntsc=%b det_video=%b (expect 0/0 — false-positive guards)",
             film_det_ntsc, det_video);

    // ===== 4b. ISSUE-1 REGRESSION: film reached via a menu = periodic cadence
    //          hiccups (every 8th frame breaks the rff alternation). Starting from
    //          the just-floored (conf=0) state, det_ntsc must STILL engage — a strict
    //          consecutive-run detector would never reach lock here. =====
    mode = 4;
    run_pickups(120);
    chk(film_det_ntsc, "det_ntsc did NOT engage on hiccup-laden (menu-path) film — issue-1 regression");
    $display("  [4b] periodic-hiccup film: det_ntsc=%b (expect 1 — robust engage)", film_det_ntsc);

    // ===== 5. hysteresis: re-lock film, then inject ONE non-toggling frame —
    //          det_ntsc must NOT drop out for a single-frame cadence hiccup. =====
    mode = 0; run_pickups(70);        // re-engage clean film
    chk(film_det_ntsc, "det_ntsc did not re-engage before hysteresis probe");
    // switch to mode 3 with a single hiccup at the next pickup boundary
    hiccup_at = pk + 5; mode = 3;
    run_pickups(20);                  // includes the one hiccup + alternating around it
    chk(film_det_ntsc, "det_ntsc dropped out on a SINGLE cadence hiccup (hysteresis too weak)");
    $display("  [5] single hiccup: det_ntsc=%b (expect 1 — hysteresis holds)", film_det_ntsc);

    if (errors == 0)
      $display("\n==== PASS: film cadence detector separates film/30p/60i with hysteresis ====");
    else
      $display("\n==== FAIL: %0d error(s) ====", errors);
    $finish;
  end

  initial begin
    #50_000_000;
    $display("TIMEOUT (pk=%0d det_ntsc=%b det_pal=%b)", pk, film_det_ntsc, film_det_pal);
    $finish;
  end
endmodule
