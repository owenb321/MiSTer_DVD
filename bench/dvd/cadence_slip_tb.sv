`timescale 1ns/1ps
//
// cadence_slip_tb.sv — verify the Film-24p CADENCE-SLIP corrector in
// dvd/resample_addrgen.v (2026-08-02, the Film-24p A/V drift root cause).
//
// A flat 1 refresh/picture in film24 is timeline-exact ONLY for a perfect
// 3:2 cadence (rff alternating). MEN_IN_BLACK measures rff density 0.499158
// (~one broken alternation per 25 s), which retarded video by a measured
// +0.884 s over a 48-min HW capture (predicted from the disc's flags: +0.893 s;
// audio xcorr + motion-envelope matching vs the source VOB). The corrector
// accumulates the per-picture duration error in 0.5-field units (+1 per rff=1,
// -1 per rff=0) and corrects with whole refreshes at |acc| >= 5 (2.5 fields):
//   deficit  -> one frame_late pulse (-> frame_drop_ctl -> VLD drops one B)
//   surplus  -> one 2-refresh show (cur_show = 2 for that pickup)
// gated on film24 && det_ntsc (the detector's own NTSC-telecine verdict).
//
// Checks:
//   [1] perfect 3:2 cadence         -> ZERO corrections (either kind)
//   [2] MiB-like deficit (extra rff=0 every 20 pictures) -> frame_late count
//       == floor(anomalies/5) +-1, and NO surplus holds; long-run video-vs-true
//       content error stays bounded (< 2 refreshes) instead of growing linearly
//   [3] surplus (extra rff=1 every 20) -> 2-refresh shows == floor(anoms/5)+-1
//       (observed as pickup-rate deficit vs scans), ZERO frame_late
//   [4] film24=0 (60 Hz mode), same deficit pattern -> corrector inert
//   [5] 30p video (rff const 0) + film24=1 -> det_ntsc never engages -> inert
//       (the safety gate: without it the corrector would fire every 5 pickups)
//
// Build:
//   iverilog -g2012 -I rtl/mpeg2 -o bench/dvd/cadence_slip_sim \
//       dvd/resample_addrgen.v rtl/mpeg2/mem_addr.v bench/dvd/cadence_slip_tb.sv
//   vvp bench/dvd/cadence_slip_sim
//
module cadence_slip_tb;
  reg         clk = 0, clk_en = 1, rst = 0;
  reg   [2:0] output_frame = 3'd1;
  wire        output_frame_rd;
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
  wire        film_det_ntsc, film_det_pal, det_video;
  wire        refresh_tick_w;
  reg         film24 = 1'b1;

  integer     supplied = 0, consumed = 0;
  wire        output_frame_valid_w = (supplied != consumed);

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
    .busy(busy), .frame_late(frame_late),
    .film_det_ntsc(film_det_ntsc), .film_det_pal(film_det_pal),
    .det_video(det_video),
    .video_live(), .pickup_hold(1'b0), .pause(1'b0),
    .refresh_tick_dbg(refresh_tick_w),
    .raster_par_err(1'b0), .vscale_mode(2'd0), .hcrop_en(1'b0), .menu_ff(1'b0), .film24(film24));

  always #5 clk = ~clk;

  always @(posedge clk)
    if (rst && output_frame_rd) consumed <= consumed + 1;
  always @(posedge clk)
    if (rst && ((supplied - consumed) < 3)) supplied <= supplied + 1;

  // ---- cadence driver ------------------------------------------------------
  //   mode 0: perfect 3:2 alternation
  //   mode 1: deficit — every ANOM_P-th picture repeats rff=0 (breaks alternation
  //           with a short picture; net -1 step per ANOM_P pickups)
  //   mode 2: surplus — every ANOM_P-th picture repeats rff=1 (net +1 step)
  //   mode 3: 30p video — rff constant 0
  // NOTE the anomaly must be an INSERTION that does not consume the alternation
  // phase (`nat` untouched) — a naive "force rff=0 every Kth pickup" with even K
  // always lands where alternation yields 0 anyway and nets ZERO anomalies (the
  // first version of this TB did exactly that and read a dead corrector as pass).
  localparam integer ANOM_P = 21;
  integer mode = 0;
  integer pk = 0;
  reg nat = 0;                 // next natural alternation value
  always @(posedge clk)
    if (rst && output_frame_rd) begin
      pk <= pk + 1;
      progressive_frame <= 1'b1;
      case (mode)
        0: begin repeat_first_field <= nat; nat <= ~nat; end
        1: if (pk % ANOM_P == ANOM_P-1) repeat_first_field <= 1'b0;  // extra SHORT picture
           else begin repeat_first_field <= nat; nat <= ~nat; end
        2: if (pk % ANOM_P == ANOM_P-1) repeat_first_field <= 1'b1;  // extra LONG picture
           else begin repeat_first_field <= nat; nat <= ~nat; end
        3: repeat_first_field <= 1'b0;
      endcase
    end

  // ---- observation ---------------------------------------------------------
  // frame_late pulses; scans via the module's own refresh_tick_dbg (one pulse per
  // completed image scan). NOT busy-falls: busy never drops between the two scans
  // of a 2-refresh hold (the FSM repeats without passing STATE_INIT), so counting
  // busy-falls counts pickups and reads every hold as invisible — the trap the
  // first version of this observation fell into.
  integer lates = 0, scans = 0;
  reg late_q = 0, tick_q = 0;
  always @(posedge clk) begin
    late_q <= frame_late; tick_q <= refresh_tick_w;
    if (rst && frame_late && !late_q)       lates = lates + 1;
    if (rst && refresh_tick_w && !tick_q)   scans = scans + 1;
  end

  integer errors = 0;
  task chk(input cond, input [255:0] msg);
    if (!cond) begin $display("  FAIL: %0s", msg); errors = errors + 1; end
  endtask
  task run_pickups(input integer n);
    integer target; begin
      target = pk + n;
      while (pk < target) @(posedge clk);
    end
  endtask
  integer l0, s0, p0, holds;

  initial begin
    rst = 0;
    repeat (4) @(posedge clk); rst = 1; repeat (4) @(posedge clk);

    // ===== [1] perfect cadence: engage the detector, then observe quiet =====
    mode = 0;
    run_pickups(80);                     // detector engages (~40 clean frames)
    chk(film_det_ntsc, "[1] det_ntsc did not engage on clean 3:2");
    l0 = lates; s0 = scans; p0 = pk;
    run_pickups(2000);
    chk(lates - l0 == 0, "[1] corrections fired on a PERFECT cadence");
    // every pickup shows exactly 1 refresh: scans == pickups (no extra holds)
    holds = (scans - s0) - (pk - p0);
    chk((holds >= -2) && (holds <= 2), "[1] scans != pickups on perfect cadence (unexpected holds)");
    $display("  [1] perfect cadence: %0d pickups, %0d lates, hold-slack %0d  (expect 0 lates)", pk-p0, lates-l0, holds);

    // ===== [2] deficit cadence (MiB-like, concentrated) =====
    mode = 1;
    run_pickups(100);                    // let the pattern settle
    l0 = lates; s0 = scans; p0 = pk;
    run_pickups(3000);
    // net -1 step per ANOM_P pickups -> a correction every 5*ANOM_P pickups
    chk(lates - l0 >= 3000/(5*ANOM_P) - 1, "[2] too FEW deficit corrections (drift would leak)");
    chk(lates - l0 <= 3000/(5*ANOM_P) + 1, "[2] too MANY deficit corrections (over-correcting)");
    holds = (scans - s0) - (pk - p0);
    chk((holds >= -2) && (holds <= 2), "[2] surplus holds fired on a deficit pattern");
    $display("  [2] deficit: %0d pickups, %0d corrections (expect ~%0d), hold-slack %0d",
             pk-p0, lates-l0, 3000/(5*ANOM_P), holds);

    // ===== [3] surplus cadence =====
    mode = 2;
    run_pickups(200);                    // flush accumulator/pattern transition
    l0 = lates; s0 = scans; p0 = pk;
    run_pickups(3000);
    chk(lates - l0 == 0, "[3] frame_late fired on a SURPLUS pattern");
    holds = (scans - s0) - (pk - p0);   // each 2-refresh show adds one extra scan
    chk(holds >= 3000/(5*ANOM_P) - 2, "[3] too FEW surplus holds");
    chk(holds <= 3000/(5*ANOM_P) + 2, "[3] too MANY surplus holds");
    $display("  [3] surplus: %0d pickups, %0d lates, %0d extra scans (expect ~%0d holds)",
             pk-p0, lates-l0, holds, 3000/(5*ANOM_P));

    // ===== [4] film24 OFF: corrector inert on the deficit pattern =====
    film24 = 1'b0;
    mode = 1;
    run_pickups(200);
    l0 = lates; p0 = pk;
    run_pickups(1500);
    chk(lates - l0 == 0, "[4] cadence corrections fired with film24=0");
    $display("  [4] film24=0: %0d pickups, %0d lates (expect 0)", pk-p0, lates-l0);

    // ===== [5] 30p video in film24: safety gate (det_ntsc low -> inert) =====
    film24 = 1'b1;
    mode = 3;
    run_pickups(400);                    // detector disengages on constant rff
    chk(!film_det_ntsc, "[5] det_ntsc stayed high on constant-rff video");
    l0 = lates; p0 = pk;
    run_pickups(1500);
    chk(lates - l0 == 0, "[5] corrector fired on 30p video (safety gate broken — would fire every 5 pickups)");
    $display("  [5] 30p video gate: %0d pickups, %0d lates (expect 0)", pk-p0, lates-l0);

    if (errors == 0) $display("PASS: cadence_slip_tb");
    else begin
      $display("FAIL: cadence_slip_tb — %0d error(s)", errors);
      $fatal(1);
    end
    $finish;
  end

  initial begin
    #400_000_000;
    $display("TIMEOUT"); $fatal(1, "cadence_slip_tb timeout");
  end
endmodule
