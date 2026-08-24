`timescale 1ns/1ps
//
// pickup_hold_tb.sv — the STD mux-lead hold + per-load video_live re-arm in
// dvd/resample_addrgen.v.
//
// DVD muxes audio ~0.5 s behind video; emu defers the governor's FIRST pickup
// (pickup_hold) until the audio side has caught the STC anchor, so video starts
// the mux-lead behind the demux front. Checks:
//   1. pickup_hold=1 + a decoded frame waiting, COLD (no prior frame) -> NO
//      pickup (output_frame_rd stays low, video_live stays 0) and NO scans
//      (nothing to hold — screen correctly stays black until first pickup).
//   2. hold released -> pickup happens, video_live sets, scanning starts.
//   3. hold RE-ASSERTED mid-play (clip reload) -> video_live re-arms to 0 and
//      the next pickup is again deferred while held — but the display KEEPS
//      RE-SCANNING the last frame (hold-frame transitions: the persistence
//      branch must stay live through the hold, both while starved AND once the
//      new clip's first frame is parked waiting; the pre-fix governor parked in
//      STATE_INIT in the latter phase = black frames between clips). frame_late
//      must never fire during the hold (no drop debt banked at clip start),
//      and output_frame_sav must keep the OLD clip's frame.
//   4. once released again, exactly one pickup resumes, video_live re-sets,
//      and the NEW frame is latched for scanning.
//
// Build:
//   iverilog -g2012 -o bench/dvd/pickup_hold_sim \
//       dvd/resample_addrgen.v rtl/mpeg2/mem_addr.v bench/dvd/pickup_hold_tb.sv
//   vvp bench/dvd/pickup_hold_sim
//
module pickup_hold_tb;
  reg         clk = 0, clk_en = 1, rst = 0;
  reg   [2:0] output_frame = 3'd1;
  wire        output_frame_rd;
  reg         progressive_sequence = 0, progressive_frame = 1;
  reg         top_field_first = 0, repeat_first_field = 0;
  reg   [7:0] mb_width = 8'd1, mb_height = 8'd1;
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
  wire        video_live;
  reg         pickup_hold = 1;   // held from "load"

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
    .busy(busy), .frame_late(frame_late),
    .video_live(video_live), .pickup_hold(pickup_hold), .pause(1'b0), .vscale_mode(2'd0), .hcrop_en(1'b0), .menu_ff(1'b0), .film24(1'b0));

  always #5 clk = ~clk;

  always @(posedge clk)
    if (rst && output_frame_rd) consumed <= consumed + 1;

  // Scan-activity monitor: counts resample write pulses, tracks the longest
  // idle gap between pulses, and latches any frame_late. Windowed via mon_arm
  // (counters reset on arm) so each test phase gets a clean measurement.
  reg     mon_arm = 0;
  integer scan_pulses = 0;
  integer gap = 0, max_gap = 0;
  integer late_hits = 0;
  always @(posedge clk) begin
    if (!mon_arm) begin
      scan_pulses <= 0; gap <= 0; max_gap <= 0; late_hits <= 0;
    end else begin
      if (resample_wr_en) begin
        scan_pulses <= scan_pulses + 1;
        gap <= 0;
      end else begin
        gap <= gap + 1;
        if (gap + 1 > max_gap) max_gap <= gap + 1;
      end
      if (frame_late) late_hits <= late_hits + 1;
    end
  end

  integer errs = 0;
  task chk(input cond, input [255:0] msg);
    if (!cond) begin $display("  FAIL: %0s", msg); errs = errs + 1; end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    rst = 1;
    repeat (4) @(posedge clk);

    // 1. COLD: frame decoded, hold asserted -> no pickup, and no scans either
    //    (last_image == NO_OUTPUT, nothing to hold — correct park-black).
    mon_arm = 1;
    supplied = 1;
    repeat (200) @(posedge clk);
    chk(consumed == 0,     "pickup happened while held");
    chk(!video_live,       "video_live set while held");
    chk(scan_pulses == 0,  "cold-start hold produced scans (nothing to hold)");
    mon_arm = 0;
    $display("  [1] cold hold: frame parked, no pickup, no scans (consumed=%0d)", consumed);

    // 2. release -> pickup + video_live + scanning starts
    pickup_hold = 0;
    repeat (200) @(posedge clk);
    chk(consumed == 1, "no pickup after release");
    chk(video_live,    "video_live not set after first pickup");
    $display("  [2] released: pickup done, video_live=1");

    // let a couple more frames flow un-held (mid-play must never stall)
    supplied = 3;
    repeat (600) @(posedge clk);
    chk(consumed == 3, "mid-play frames did not flow");

    // 3. re-assert (clip reload): video_live re-arms; next pickup deferred —
    //    but the LAST FRAME keEPS re-scanning (hold-frame transitions).
    //    Phase 3a: starved (no new frame yet — the VBUF-refill window).
    pickup_hold = 1;
    repeat (10) @(posedge clk);
    chk(!video_live, "video_live did not re-arm on hold rising edge");
    mon_arm = 1;
    repeat (400) @(posedge clk);
    chk(consumed == 3,       "pickup happened during starved hold");
    chk(scan_pulses >= 20,   "held frame not re-scanned during starved hold (black)");
    chk(max_gap < 100,       "scan gap during starved hold (flicker window)");
    chk(late_hits == 0,      "frame_late fired during hold (drop debt would bank at clip start)");
    mon_arm = 0;
    $display("  [3a] starved hold: re-scan live (pulses=%0d max_gap=%0d), no lates", scan_pulses, max_gap);
    repeat (2) @(posedge clk);       // let the monitor window reset

    //    Phase 3b: the new clip's first frame arrives while still held — the
    //    pre-fix governor parked in STATE_INIT here (ofv_paced true, pickup
    //    gated) = the black frames between clips. Must keep re-scanning the
    //    OLD frame and not pick the new one up.
    output_frame = 3'd2;             // the new clip's frame slot
    supplied = 4;
    mon_arm = 1;
    repeat (400) @(posedge clk);
    chk(consumed == 3,                    "reload pickup happened while held");
    chk(scan_pulses >= 20,                "governor parked with a frame waiting (the black-frame bug)");
    chk(max_gap < 100,                    "scan gap while frame waiting under hold");
    chk(late_hits == 0,                   "frame_late fired with frame waiting under hold");
    chk(dut.output_frame_sav == 3'd1,     "held display switched off the OLD clip's frame");
    mon_arm = 0;
    $display("  [3b] frame-waiting hold: old frame re-scan live (pulses=%0d max_gap=%0d)", scan_pulses, max_gap);

    // 4. release again -> exactly one pickup, video_live re-set, NEW frame latched
    pickup_hold = 0;
    repeat (200) @(posedge clk);
    chk(consumed == 4,                "no pickup after reload release");
    chk(video_live,                   "video_live not re-set after reload pickup");
    chk(dut.output_frame_sav == 3'd2, "new clip's frame not latched after release");
    $display("  [4] reload released: pickup resumed, video_live=1, new frame latched");

    if (errs == 0) begin $display("PASS: pickup_hold (STD mux-lead hold + per-load re-arm + hold-frame re-scan)"); $finish; end
    else           $fatal(1, "FAIL: %0d error(s)", errs);
  end

  initial begin #10000000; $fatal(1, "FAIL: timeout"); end
endmodule
