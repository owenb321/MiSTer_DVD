`timescale 1ns/1ps
//
// gov_field_late_tb.sv — verify the 480i FIELD-PATH timeline accounting fixes in
// dvd/resample_addrgen.v (DVD-FORK FIX, 2026-07-05).
//
// HW background (abandoned feature/crt-composite branch, re-diagnosed from its
// measurements): on the interlaced field path, audio drifted AHEAD of video on
// compute crushes with the SAME lates/drops rates as the drift-free progressive
// run — "each drop reclaims ~1.1 refreshes instead of 2". Root causes fixed here:
//   1. LATE UNDERCOUNT (dominant): an interlaced late repeat re-scans a FIELD PAIR
//      (2 refreshes of timeline slip) but late_raw fires ONCE per STATE_REPEAT
//      visit -> the debt ledger banked HALF the slip, so O[12] dropped at half the
//      needed rate. Fixed by stretching frame_late to 2 cycles on pair repeats.
//   2. show_next was a flat SHOW_N=2 on the interlaced arm: a soft-telecine rff
//      frame occupies 3 FIELD scans (TOP,BOTTOM,TOP) -> cur_show/pickup_show (the
//      drop debit and vid_err content credit) were 1 refresh short per rff frame.
//      Fixed with the mode-aware show_next (2/3 for film, 2 for video, 2/4/6 for
//      progressive_sequence).
//
// Checks (all on the interlaced=1, deinterlace=0 field path):
//   [VIDEO] rff=0 frame: held exactly 2 field scans, cur_show==2.
//   [FILM ] rff=1 progressive_frame: held exactly 3 field scans, cur_show==3.
//   [LATE ] withhold the supply: from the first late repeat to the next pickup,
//           frame_late-high CYCLES == field scans elapsed (1 cycle of debt per
//           refresh of slip — the progressive-path 1:1 contract, now mode-true).
//   [HOLD ] STD mux-lead hold (hold-frame transitions): pickup_hold asserted
//           mid-play -> the held frame keeps re-scanning on the field path but
//           frame_late banks ZERO debt (hold lateness is mux-lead policy, not
//           decode debt — pre-fix it banked a drop burst at clip start), a
//           waiting frame is NOT picked up, and after release the pickup and
//           the normal 1:1 late accounting both resume.
//
// Build:
//   iverilog -g2012 -o bench/dvd/gov_field_late_sim \
//       dvd/resample_addrgen.v rtl/mpeg2/mem_addr.v bench/dvd/gov_field_late_tb.sv
//   vvp bench/dvd/gov_field_late_sim
//
module gov_field_late_tb;
  reg         clk = 0, clk_en = 1, rst = 0;
  reg   [2:0] output_frame = 3'd1;
  wire        output_frame_rd;
  // 480i field path: DVDs are coded interlaced (progressive_sequence=0); film rides
  // progressive_frame + repeat_first_field. CRT/HDMI-480i runs interlaced=1 (raster)
  // with deinterlace=0 (emit raw fields).
  reg         progressive_sequence = 0, progressive_frame = 1;
  reg         top_field_first = 1, repeat_first_field = 0;
  reg   [7:0] mb_width = 8'd1, mb_height = 8'd1;   // tiny frame -> very fast scans
  reg  [13:0] horizontal_size = 14'd16, vertical_size = 14'd16;
  reg         interlaced = 1, deinterlace = 0, persistence = 1;
  reg   [4:0] repeat_frame = 0;
  reg         disp_wr_addr_full = 0, disp_wr_addr_ack = 1;
  wire        disp_wr_addr_en;
  wire [21:0] disp_wr_addr;
  wire  [2:0] resample_wr_dta;
  wire        resample_wr_en;
  reg         disp_wr_addr_almost_full = 0, resample_wr_almost_full = 0;
  wire        busy;
  wire        frame_late;
  wire  [3:0] cur_show_w;
  reg         pickup_hold = 0;

  integer     supplied = 0;
  integer     consumed = 0;
  wire        output_frame_valid_w = (supplied != consumed);

  resample_addrgen dut (
    .clk(clk), .clk_en(clk_en), .rst(rst),
    .output_frame(output_frame), .output_frame_valid(output_frame_valid_w), .output_frame_rd(output_frame_rd),
    .progressive_sequence(progressive_sequence), .progressive_frame(progressive_frame),
    .top_field_first(top_field_first), .repeat_first_field(repeat_first_field),
    .mb_width(mb_width), .mb_height(mb_height),
    .horizontal_size(horizontal_size), .vertical_size(vertical_size),
    .interlaced(interlaced), .deinterlace(deinterlace),
    .persistence(persistence), .repeat_frame(repeat_frame),
    .disp_wr_addr_full(disp_wr_addr_full), .disp_wr_addr_en(disp_wr_addr_en),
    .disp_wr_addr_ack(disp_wr_addr_ack), .disp_wr_addr(disp_wr_addr),
    .resample_wr_dta(resample_wr_dta), .resample_wr_en(resample_wr_en),
    .disp_wr_addr_almost_full(disp_wr_addr_almost_full), .resample_wr_almost_full(resample_wr_almost_full),
    .busy(busy), .frame_late(frame_late), .video_live(), .pickup_hold(pickup_hold), .pause(1'b0),
    .cur_show_out(cur_show_w), .vscale_mode(2'd0), .hcrop_en(1'b0), .menu_ff(1'b0), .film24(1'b0));

  always #5 clk = ~clk;

  always @(posedge clk)
    if (rst && output_frame_rd) consumed <= consumed + 1;

  // one refresh = one completed image (field) scan
  localparam STATE_NEXT_MB = 4'h3;
  wire    pass_done = (dut.state == STATE_NEXT_MB) && dut.last_mb && dut.last_y;
  integer refreshes = 0;
  always @(posedge clk) if (rst && pass_done) refreshes = refreshes + 1;

  // frame_late accounting: count CYCLES high (debt units in frame_drop_ctl)
  integer late_cycles = 0;
  reg     measure = 0;
  always @(posedge clk) if (rst && measure && frame_late) late_cycles = late_cycles + 1;

  // field scans inside the measurement window
  integer meas_scans = 0;
  always @(posedge clk) if (rst && measure && pass_done) meas_scans = meas_scans + 1;

  integer errors = 0;

  task supply; begin supplied = supplied + 1; end endtask
  task waitclk(input integer n); integer i; begin for (i=0;i<n;i=i+1) @(posedge clk); end endtask

  integer video_scans, film_scans;
  integer video_show, film_show;
  integer hold_consumed;

  initial begin
    rst = 0; supplied = 0; consumed = 0;
    waitclk(4);
    rst = 1;
    waitclk(4);

    // =====================================================================
    // [VIDEO] plain interlaced frame (rff=0): 2 field scans, cur_show=2
    // =====================================================================
    progressive_frame = 1'b0; repeat_first_field = 1'b0;
    supply;
    @(posedge output_frame_rd);
    refreshes = 0;
    waitclk(4);
    video_show = cur_show_w;
    // supply the next frame mid-display so pickup is clean when due
    progressive_frame = 1'b1; repeat_first_field = 1'b1;   // NEXT frame = film rff
    supply;
    @(posedge output_frame_rd);
    video_scans = refreshes;   // scans the VIDEO frame occupied
    $display("[VIDEO] interlaced rff=0 frame: %0d field scans (expect 2), cur_show=%0d (expect 2)",
             video_scans, video_show);
    if (video_scans != 2 || video_show != 2) begin errors = errors + 1; $display("FAIL: VIDEO"); end

    // =====================================================================
    // [FILM] rff=1 progressive_frame: 3 field scans (TOP,BOTTOM,TOP), cur_show=3
    // =====================================================================
    refreshes = 0;
    waitclk(4);
    film_show = cur_show_w;
    progressive_frame = 1'b0; repeat_first_field = 1'b0;   // NEXT frame = plain video
    supply;
    @(posedge output_frame_rd);
    film_scans = refreshes;
    $display("[FILM ] interlaced rff=1 frame: %0d field scans (expect 3), cur_show=%0d (expect 3)",
             film_scans, film_show);
    if (film_scans != 3 || film_show != 3) begin errors = errors + 1; $display("FAIL: FILM"); end

    // =====================================================================
    // [LATE] withhold: frame_late cycles == field scans of slip (1:1)
    // =====================================================================
    // current (video) frame displays its 2 scans; supply stays drained -> the
    // governor pair-repeats. Measure from the first late decision to the pickup
    // of the resupplied frame: every elapsed field scan is one refresh of slip
    // and must bank exactly one frame_late cycle.
    @(posedge dut.late_raw);
    late_cycles = 0; meas_scans = 0; measure = 1;
    // account for the pulse of THIS first late decision (frame_late registers on
    // the next cycles; measure just opened so both cycles are counted below)
    waitclk(1);
    // let it pair-repeat ~5 times (each pair = 2 tiny field scans)
    waitclk(3000);
    progressive_frame = 1'b1; repeat_first_field = 1'b0;
    supply;
    @(posedge output_frame_rd);
    measure = 0;
    $display("[LATE ] withheld window: %0d field scans of slip, %0d frame_late cycles banked (expect equal, >=4)",
             meas_scans, late_cycles);
    if (late_cycles != meas_scans || meas_scans < 4) begin errors = errors + 1; $display("FAIL: LATE"); end

    // =====================================================================
    // [HOLD] STD mux-lead hold: no debt banked, re-scan live, resume clean
    // =====================================================================
    // the LATE test just picked up a video (rff=0) frame; let it finish its
    // 2 field scans so the supply is drained, then assert the hold (a clip
    // reload: video_live re-arms internally -> hold_freeze).
    waitclk(200);
    pickup_hold = 1;
    waitclk(4);
    hold_consumed = consumed;
    late_cycles = 0; meas_scans = 0; measure = 1;
    waitclk(3000);                     // starved hold window (VBUF refill)
    supply;                            // the new clip's first frame arrives...
    waitclk(3000);                     // ...and waits (audio not caught yet)
    measure = 0;
    $display("[HOLD ] held window: %0d field scans (expect >=4, re-scan live), %0d frame_late cycles (expect 0), pickups=%0d (expect 0)",
             meas_scans, late_cycles, consumed - hold_consumed);
    if (late_cycles != 0 || meas_scans < 4 || consumed != hold_consumed)
      begin errors = errors + 1; $display("FAIL: HOLD"); end
    // release -> the waiting frame is picked up
    pickup_hold = 0;
    @(posedge output_frame_rd);
    waitclk(4);
    if (consumed != hold_consumed + 1) begin errors = errors + 1; $display("FAIL: HOLD release pickup"); end
    // and normal late accounting resumes (supply drained again after 2 scans)
    @(posedge dut.late_raw);
    late_cycles = 0; meas_scans = 0; measure = 1;
    waitclk(1);
    waitclk(1500);
    supply;
    @(posedge output_frame_rd);
    measure = 0;
    $display("[HOLD ] post-release: %0d field scans of slip, %0d frame_late cycles (expect equal, >=2)",
             meas_scans, late_cycles);
    if (late_cycles != meas_scans || meas_scans < 2) begin errors = errors + 1; $display("FAIL: HOLD resume"); end

    if (errors == 0) begin
      $display("\n==== PASS: 480i field-path pacing (2/3 scans) + 1:1 late accounting + hold window ====");
      $finish;
    end else
      $fatal(1, "==== FAIL: %0d error(s) ====", errors);
  end

  initial begin
    #40_000_000;
    $fatal(1, "TIMEOUT");
  end
endmodule
