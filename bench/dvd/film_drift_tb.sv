/*
 * film_drift_tb.sv — measure the FILM drop-reclaim drift (video-ahead creep).
 *
 * HW (round 10): with audio locked to the wall-clock STC, video pulls ahead at
 * ~8 ms/s on MiB and ~4 ms/s on Matrix — proportional to each disc's drop rate.
 * This bench reproduces the mechanism with the REAL dvd/frame_drop_ctl.sv and a
 * behavioral 3:2-film governor + compute-bound decoder, and MEASURES the drift:
 *
 *   drift(t) = content_refreshes_passed(t) - wall_refreshes(t)
 *
 * where every source frame k has a true display duration dur(k) = rff(k)?3:2
 * refreshes (alternating rff = 2.5 avg = NTSC soft-telecine film), and a DROPPED
 * frame's duration passes instantly (its content is skipped on screen). In sync,
 * drift stays bounded near 0; the HW symptom is drift growing positive.
 *
 * Three debit modes for the controller's per-drop reclaim:
 *   +MODE=flat2   — debit 2 (the pre-fix behavior; expect positive drift)
 *   +MODE=curshow — debit the governor's on-display cur_show (the shipped fix)
 *   +MODE=exact   — debit the DROPPED frame's own duration (ground truth)
 *
 * +BCORR=1 (2026-07-03, the Shea-Stadium over-advance): correlate rff with the
 * droppable B's (dur(B)=3, dur(I/P)=2) — the crush pattern measured on HW
 * (+268 lates / +103 drops balancing at debit ~2.6 while the dropped frames'
 * true durations averaged ~3.0; video ended ~900 ms AHEAD with audio provably
 * on schedule). With the default (uncorrelated) pattern curshow == exact, which
 * is exactly why the original run of this bench exonerated the curshow proxy;
 * with +BCORR=1 curshow leaks ~+0.5 refresh per drop (video AHEAD) and exact
 * stays neutral — the RTL now debits the dropped frame's own duration
 * (vld drop_pic_rff), i.e. MODE=exact is the shipped behavior.
 *
 * Build:
 *   iverilog -g2012 -I rtl/mpeg2 -o bench/dvd/film_drift_sim \
 *       dvd/frame_drop_ctl.sv bench/dvd/film_drift_tb.sv
 *   vvp bench/dvd/film_drift_sim +MODE=flat2 (etc.)
 */
`timescale 1ns/1ps

module film_drift_tb;

  // clk per display refresh. 59.94 Hz model = 20; Film 24p = 50, because ONE 24p
  // refresh spans the same wall time as 2.5 refreshes at 59.94 (a film frame is
  // 41.7 ms either way) — keeping the decoder's per-frame budget identical so the
  // late statistics are comparable between the two modes.
  integer refresh_p;
  localparam integer NFRAMES   = 4000;      // ~166 s of film content
  // film: alternating repeat_first_field -> durations 3,2,3,2 (2.5 avg);
  // +BCORR=1 instead puts the rff on the droppable B's (the HW crush pattern)
  integer bcorr = 0;
  // +FILM24=1 (2026-08-02): Film 24p Out — the governor gives EVERY frame exactly
  // one refresh (show_next = film24 ? 1 : ...) and ascal does the 3:2 downstream.
  integer film24 = 0;
  // the frame's repeat_first_field flag (what the VLD reports as drop_pic_rff)
  function integer frff(input integer idx);
    frff = bcorr ? ((ftype(idx) == 2) ? 1 : 0) : (idx[0] ? 0 : 1);
  endfunction
  // TRUE display duration in refreshes
  function integer fdur(input integer idx);
    fdur = film24 ? 1 : (frff(idx) ? 3 : 2);
  endfunction
  // GOP display pattern I B B P B B ... (0=I,1=P,2=B)
  function integer ftype(input integer idx);
    integer m;
    begin
      if (idx == 0) ftype = 0;
      else begin m = idx % 3; ftype = (m == 0) ? 1 : 2; end
    end
  endfunction
  // compute-bound decode costs in clk: budget per frame = 2.5*REFRESH = 50
  localparam integer COST_I = 50, COST_P = 48, COST_B = 72, COST_EASY = 30;
  localparam integer DROP_COST = 10;
  localparam integer HARD_LEN = 48, EASY_LEN = 24;   // bursty, mostly hard (MiB-like)
  function integer is_hard(input integer idx);
    is_hard = ((idx % (HARD_LEN+EASY_LEN)) < HARD_LEN);
  endfunction
  function integer fcost(input integer idx);
    if (!is_hard(idx)) fcost = COST_EASY;
    else fcost = (ftype(idx)==0)?COST_I : (ftype(idx)==1)?COST_P : COST_B;
  endfunction

  reg clk = 0; always #5 clk = ~clk;
  reg rst_n = 0;

  // ---- the REAL controller ----
  reg  enable = 1;
  reg  frame_late, drop_ack;
  reg  [3:0] drop_cost;
  wire drop_req;
  wire [15:0] flate_cnt, fdrop_cnt;
  wire [4:0]  debt;
  frame_drop_ctl #(.DROP_THRESHOLD(2), .DEBT_MAX(15)) dut (
    .clk(clk), .clk_en(1'b1), .rst(rst_n),
    .enable(enable), .bitstream_ok(1'b1),
    .frame_late(frame_late), .drop_ack(drop_ack), .drop_cost(drop_cost),
    .drop_req(drop_req),
    .frames_late_cnt(flate_cnt), .frames_dropped_cnt(fdrop_cnt), .debt_out(debt)
  );

  // ---- decoder model: produces display-order frames into a FIFO ----
  integer fifo [0:255];           // source indices decoded, awaiting display
  integer fifo_wr = 0, fifo_rd = 0;
  function integer fifo_cnt; fifo_cnt = fifo_wr - fifo_rd; endfunction

  integer dec_idx = 0;            // next source index to decode
  integer dec_busy = 0;           // cycles remaining on current decode
  integer dropped_dur_pend = 0;   // content refreshes skipped by drops (credited at next consume)
  string  mode;

  always @(posedge clk) begin
    drop_ack <= 0;
    if (rst_n && dec_idx < NFRAMES) begin
      if (dec_busy > 0) begin
        dec_busy <= dec_busy - 1;
        if (dec_busy == 1 && fifo_cnt() < 4) begin
          fifo[fifo_wr % 256] <= dec_idx;
          fifo_wr <= fifo_wr + 1;
          dec_idx <= dec_idx + 1;
        end
      end else if (fifo_cnt() < 4) begin
        // about to start the next frame: drop a B if requested
        if ((ftype(dec_idx) == 2) && drop_req) begin
          drop_ack         <= 1;
          dropped_dur_pend <= dropped_dur_pend + fdur(dec_idx);
          if (mode == "exact") drop_cost <= fdur(dec_idx);
          // MODE=hw reproduces the RTL's drop_cost expression BEFORE the film24 fix
          // (mpeg2video.v: drop_pic_rff ? 3 : 2) — in film24 the truth is 1.
          if (mode == "hw")    drop_cost <= frff(dec_idx) ? 3 : 2;
          dec_idx  <= dec_idx + 1;
          dec_busy <= DROP_COST;
        end else begin
          dec_busy <= fcost(dec_idx);
        end
      end
    end
  end

  // ---- governor model: film-cadence display, refresh-locked ----
  integer wall_refresh = 0;       // wall clock in refreshes
  integer refresh_div  = 0;
  integer cur = -1;               // source index on display (-1 = none yet)
  integer shown = 0;              // refreshes the current frame has been shown
  integer content_passed = 0;     // content refreshes fully presented (incl. skipped)
  integer late_total = 0;

  wire refresh_tick = (refresh_div == refresh_p-1);
  always @(posedge clk) begin
    frame_late <= 0;
    if (rst_n) begin
      refresh_div <= (refresh_tick) ? 0 : refresh_div + 1;
      if (refresh_tick) begin
        wall_refresh <= wall_refresh + 1;
        if (cur < 0) begin
          if (fifo_cnt() > 0) begin
            cur <= fifo[fifo_rd % 256]; fifo_rd <= fifo_rd + 1; shown <= 1;
          end
        end else if (shown >= fdur(cur)) begin
          // frame's slot complete: content advances by its duration (+ any skipped)
          if (fifo_cnt() > 0) begin
            content_passed <= content_passed + fdur(cur) + dropped_dur_pend;
            dropped_dur_pend <= 0;
            if (mode == "curshow") drop_cost <= fdur(fifo[fifo_rd % 256]);
            cur <= fifo[fifo_rd % 256]; fifo_rd <= fifo_rd + 1; shown <= 1;
          end else begin
            frame_late <= 1;               // DUE but not decoded: hold (real late)
            late_total <= late_total + 1;
            shown <= shown + 1;            // keep holding
          end
        end else shown <= shown + 1;
      end
    end
  end

  // ---- run + report ----
  integer drift_r, secs_r, ms_r;
  initial begin
    if (!$value$plusargs("MODE=%s", mode)) mode = "curshow";
    if (!$value$plusargs("BCORR=%d", bcorr)) bcorr = 0;
    if (!$value$plusargs("FILM24=%d", film24)) film24 = 0;
    refresh_p = film24 ? 50 : 20;
    drop_cost = 4'd2;                       // flat2 default; other modes override live
    repeat (4) @(posedge clk);
    rst_n = 1;
    // run until the decoder finishes and the fifo drains
    while (dec_idx < NFRAMES) @(posedge clk);
    while (fifo_wr != fifo_rd) @(posedge clk);
    repeat (200) @(posedge clk);
    drift_r = content_passed + dropped_dur_pend - wall_refresh;
    // wall seconds: a 59.94 refresh is 16.68 ms, a 24p refresh 41.71 ms
    secs_r = film24 ? (wall_refresh*4171)/100000 : (wall_refresh*1668)/100000;
    ms_r   = film24 ? (drift_r*4171)/100 : (drift_r*1668)/100;
    $display("MODE=%0s FILM24=%0d frames=%0d lates=%0d drops=%0d wall=%0d content=%0d",
             mode, film24, NFRAMES, flate_cnt, fdrop_cnt, wall_refresh,
             content_passed + dropped_dur_pend);
    $display("  DRIFT = %0d refreshes over %0d s = %0d ms  (+ = video AHEAD / audio behind)",
             drift_r, secs_r, ms_r);
    if (secs_r > 0)
      $display("  EXTRAPOLATED = %0d ms/hour  (%0d s/hour)",
               (ms_r*3600)/secs_r, (ms_r*36)/secs_r/10);
    $finish;
  end

  initial begin #400000000; $display("TIMEOUT (deadlock?)"); $finish; end
endmodule
