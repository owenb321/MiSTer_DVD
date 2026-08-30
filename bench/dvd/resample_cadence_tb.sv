`timescale 1ns/1ps
//
// resample_cadence_tb.sv — verify the film-3:2 cadence-aware PACING + frame_late honesty
// in dvd/resample_addrgen.v (the frame-rate / frame-drop governor).
//
// The governor holds each frame for `cur_show` refreshes. Baseline SHOW_N=2 (29.97@59.94,
// 25@50). A soft-telecined progressive frame with repeat_first_field is held for 3 refreshes
// so 24fps film gets its correct 3,2,3,2 cadence (2.5 avg = 60/24) instead of a flat 2 (=30fps,
// too fast). The extra refresh rides the persistence re-scan, INDEPENDENT of top_field_first
// (upstream wrongly gated the 3rd refresh on rff&&tff — tff is irrelevant for progressive
// frame display).
//
// With cur_show pacing, every deadline is the TRUE display duration, so ANY miss is a REAL
// decoder miss and frame_late must FIRE (a film_slack scheme that forgave one miss per
// pulldown frame was removed: on compute-marginal film it silently collapsed the cadence to
// 3,3,3,3 = ~20fps, starving audio, while hiding the lates from O[12] Frame Drop).
//
// This TB checks, on the progressive-display path (real HW config):
//   PHASE FILM: a LONG rff frame (tff=0 — the case upstream shortchanged) is held exactly
//               3 refreshes; a following withheld frame's miss FIRES frame_late.
//   PHASE PAL : short frames only (no pulldown) -> the real miss FIRES frame_late.
//
// Build:
//   iverilog -g2012 -o bench/dvd/resample_cadence_sim \
//       dvd/resample_addrgen.v rtl/mpeg2/mem_addr.v bench/dvd/resample_cadence_tb.sv
//   vvp bench/dvd/resample_cadence_sim
//
module resample_cadence_tb;
  reg         clk = 0, clk_en = 1, rst = 0;
  reg   [2:0] output_frame = 3'd1;
  wire        output_frame_rd;
  // REAL HW display config: DVDs are coded interlaced (progressive_sequence=0) with film
  // on progressive_frame + repeat_first_field; our 480p output runs deinterlace=1,
  // interlaced=0 -> the `deinterlace && ~interlaced` image-build branch (which ignored rff).
  reg         progressive_sequence = 0, progressive_frame = 1;
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

  // ---- decoder-supply model (no shared-variable race: tb writes `supplied`
  // (blocking), the clocked consume writes `consumed` (nonblocking)) ----
  integer     supplied = 0;   // frames the decoder has produced (tb-driven)
  integer     consumed = 0;   // frames the governor has read
  wire        output_frame_valid_w = (supplied != consumed);

  // pulldown flags are driven procedurally in the initial block, set stable before each
  // frame is supplied/picked. LONG frame = rff=1,tff=1 (3 built refreshes on progressive
  // display -> banks 1 slack); SHORT frame = rff=0 (1 built refresh, padded to SHOW_N).

  resample_addrgen dut (
    .clk(clk), .clk_en(clk_en), .rst(rst),
    .output_frame(output_frame), .output_frame_valid(output_frame_valid_w), .output_frame_rd(output_frame_rd),
    .progressive_sequence(progressive_sequence), .progressive_frame(progressive_frame), .informative(1'b1),
    .top_field_first(top_field_first), .repeat_first_field(repeat_first_field),
    .mb_width(mb_width), .mb_height(mb_height),
    .horizontal_size(horizontal_size), .vertical_size(vertical_size),
    .interlaced(interlaced), .deinterlace(deinterlace),
    .persistence(persistence), .repeat_frame(repeat_frame),
    .disp_wr_addr_full(disp_wr_addr_full), .disp_wr_addr_en(disp_wr_addr_en),
    .disp_wr_addr_ack(disp_wr_addr_ack), .disp_wr_addr(disp_wr_addr),
    .resample_wr_dta(resample_wr_dta), .resample_wr_en(resample_wr_en),
    .disp_wr_addr_almost_full(disp_wr_addr_almost_full), .resample_wr_almost_full(resample_wr_almost_full),
    .busy(busy), .frame_late(frame_late), .video_live(), .pickup_hold(1'b0), .pause(1'b0), .vscale_mode(2'd0), .hcrop_en(1'b0), .menu_ff(1'b0), .film24(1'b0));

  always #5 clk = ~clk;

  // consume a decoded frame when the governor reads one
  always @(posedge clk)
    if (rst && output_frame_rd) consumed <= consumed + 1;

  // count frame_late pulses within a measurement window
  integer late_count = 0;
  reg     measure = 0;
  always @(posedge clk)
    if (rst && measure && frame_late) late_count = late_count + 1;

  // count display refreshes (one per completed image scan) to check the 3:2 hold
  localparam STATE_NEXT_MB = 4'h3;
  wire    pass_done = (dut.state == STATE_NEXT_MB) && dut.last_mb && dut.last_y;
  integer refreshes = 0;
  always @(posedge clk) if (rst && pass_done) refreshes = refreshes + 1;

  integer errors = 0;

`ifdef PROBE
  reg [3:0] prev_st_probe = 0;
  always @(posedge clk) if (rst && measure) begin
    if (dut.state != prev_st_probe)
      $display("[t%0t] st=%0d refresh_cnt=%0d rptcnt=%0d ofv=%b frame_due=%b last_img=%0d late_raw=%b frame_late=%b",
               $time, dut.state, dut.refresh_cnt, dut.repeat_cnt, output_frame_valid_w,
               dut.frame_due, dut.last_image, dut.late_raw, frame_late);
    prev_st_probe <= dut.state;
  end
`endif

  // helper: push a decoded frame into the supply
  task supply; begin supplied = supplied + 1; end endtask

  // helper: wait n clocks
  task waitclk(input integer n); integer i; begin for (i=0;i<n;i=i+1) @(posedge clk); end endtask

  integer film_late, pal_late, long_refreshes;

  initial begin
    rst = 0; supplied = 0; consumed = 0;
    waitclk(4);
    rst = 1;
    waitclk(4);

    // =====================================================================
    // PHASE FILM: LONG frame (banks 1 slack) then a withheld SHORT frame.
    // =====================================================================
    // Supply the LONG frame with rff=1, tff=0 -> the case upstream shortchanged to 2
    // refreshes (it required rff&&tff for the 3rd). Cadence-aware pacing must now hold it
    // for 3 refreshes (cur_show=3) and bank 1 slack regardless of tff.
    repeat_first_field = 1'b1; top_field_first = 1'b0;
    supply;
    // Wait for it to be picked up (output_frame_rd), then supply the SHORT frame
    // DURING its display so the long frame releases cleanly into the short one.
    @(posedge output_frame_rd);                // long frame picked up
    refreshes = 0;                             // count how long the long frame is held
    waitclk(2);
    repeat_first_field = 1'b0; top_field_first = 1'b0;  // next frame is SHORT
    supply;                                    // short frame ready
    // Wait for the short frame to be picked up, then WITHHOLD. With true per-frame
    // deadlines this miss is REAL and frame_late must FIRE (O[12] needs the signal
    // to drop a B-frame and hold the timeline).
    @(posedge output_frame_rd);                 // short frame picked up -> long frame released
    long_refreshes = refreshes;                 // refreshes the long (rff) frame occupied
    waitclk(2);                                 // short frame now displaying, supply drained
    late_count = 0; measure = 1;
    @(posedge dut.late_raw);                    // first structural miss
    waitclk(3);                                 // let frame_late register + settle
    measure = 0;
    film_late = late_count;
    $display("[FILM] rff frame held %0d refreshes (expect 3); at first miss frame_late pulses=%0d (expect >=1)",
             long_refreshes, film_late);

    // recover: supply SHORT frames and drain
    repeat_first_field = 1'b0; top_field_first = 1'b0;
    supply; supply; supply; waitclk(1200);

    // =====================================================================
    // PHASE PAL: only SHORT frames (no pulldown) then a withheld SHORT frame.
    // pick is already >=2, so all subsequent frames are SHORT (rff=0).
    // =====================================================================
    // Supply two short frames, let them play, then withhold on the 2nd. With no
    // pulldown, no slack was banked -> the first structural miss must FIRE frame_late.
    supply;
    @(posedge output_frame_rd); waitclk(2);
    supply;
    @(posedge output_frame_rd); waitclk(2);    // 2nd short frame displaying, supply drained
    late_count = 0; measure = 1;
    @(posedge dut.late_raw);                    // first structural miss
    waitclk(3);
    measure = 0;
    pal_late = late_count;
    $display("[PAL ] at first miss: frame_late pulses = %0d (expect >=1)", pal_late);

    // =====================================================================
    // Verdict
    // =====================================================================
    if (long_refreshes != 3) begin
      $display("FAIL: rff pulldown frame held %0d refreshes, expected 3 (24fps 3:2 cadence)", long_refreshes);
      errors = errors + 1;
    end
    if (film_late < 1) begin
      $display("FAIL: film-cadence real miss did NOT fire frame_late");
      errors = errors + 1;
    end
    if (pal_late < 1) begin
      $display("FAIL: genuine (PAL) late did NOT fire");
      errors = errors + 1;
    end

    if (errors == 0)
      $display("\n==== PASS: rff held 3 refreshes (24fps); real misses FIRE frame_late in both cadences ====");
    else
      $display("\n==== FAIL: %0d error(s) ====", errors);
    $finish;
  end

  initial begin
    #20_000_000;
    $display("TIMEOUT"); $finish;
  end
endmodule
