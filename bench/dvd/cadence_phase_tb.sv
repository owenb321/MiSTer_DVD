/*
 * cadence_phase_tb.sv — reproduce the post-crash lip step + vid_err climb from
 * the LIVE-FLAG cadence sampling (the DVD_drift5 row-20 finding).
 *
 * HW observations to reproduce (MiB, Frame Drop On, through the Unisphere
 * crash): lips in sync before the crash; audio behind ~900 ms AFTER it and
 * STABLE; overlay row 20 (vid_err = wall − content-credited) balanced ±3 until
 * the crash, then climbing linearly ~+5 refr/s forever; audio provably
 * schedule-locked throughout (so lips == video content position vs wall).
 *
 * Suspect: the governor's `show_next` samples `repeat_first_field` from the
 * decoder's LIVE parse-side register. That register belongs to a picture a few
 * positions ahead of the one being picked up (picture-buffer queue depth), and
 * the offset SHIFTS by one on every VLD drop and wanders during stall/recovery
 * transients. With 3:2 film (rff alternating per frame) an EVEN offset reads
 * the correct value, an ODD offset reads the INVERTED cadence — mis-pacing that
 * converts into late-repeats + drops churn (and transient content-rate error
 * while the display is supply-unconstrained during the post-crush VBUF-backlog
 * burst).
 *
 * Model: 24 fps film, fdur(idx) = rff(idx)?3:2 alternating; decoder with a
 * display queue (depth QD, the picbuf bound) and per-frame decode cost; a
 * CRUSH window with huge cost followed by a fast catch-up burst (the VBUF
 * backlog). REAL dvd/frame_drop_ctl.sv decides drops (exact per-frame debit);
 * a dropped frame's content passes instantly. The governor shows each picked
 * frame for cur_show refreshes where cur_show is sampled per +FLAG mode:
 *     +FLAG=live   — rff of the frame the decoder is currently parsing (the
 *                    shipped RTL behaviour, the suspect)
 *     +FLAG=tagged — rff of the PICKED frame itself (the candidate fix:
 *                    carry the flag with the picture)
 * A frame not ready at its due refresh = late repeat (wall +1, ctl pulse).
 *
 * Measures, reported per 10 s bucket:
 *     lips    = content presented (true durations, incl. dropped) − wall
 *               (refreshes; POSITIVE = video content AHEAD = audio-behind lips)
 *     vid_err = wall − (Σ credited cur_show at pickup + Σ dropped durations)
 *               (the row-20 instrument)
 *     lates, drops
 *
 * Build:
 *   iverilog -g2012 -I rtl/mpeg2 -o bench/dvd/cadence_phase_sim \
 *       dvd/frame_drop_ctl.sv bench/dvd/cadence_phase_tb.sv
 *   vvp bench/dvd/cadence_phase_sim +FLAG=live
 *   vvp bench/dvd/cadence_phase_sim +FLAG=tagged
 */
`timescale 1ns/1ps

module cadence_phase_tb;

  localparam integer REFRESH  = 20;         // clk per display refresh
  localparam integer NFRAMES  = 6000;       // ~250 s of film
  localparam integer QD       = 3;          // display-queue depth (picbuf bound)
  // crush: frames [CR0, CR1) cost a lot; the shared stream keeps delivering, so
  // after the crush the decoder has a backlog it decodes at burst speed.
  localparam integer CR0 = 1500, CR1 = 1560;            // ~2.5 s of crush content
  localparam integer COST_NORM  = 46;                   // < 2.5*REFRESH: keeps up
  localparam integer COST_CRUSH = 150;                  // 3x budget: hard stall
  localparam integer COST_BURST = 12;                   // post-crush catch-up rate
  localparam integer DROP_COST  = 8;

  function integer rff(input integer idx);   rff  = ~idx[0]; endfunction
  function integer fdur(input integer idx);  fdur = rff(idx) ? 3 : 2; endfunction
  function integer ftype(input integer idx); // I B B P B B ...
    integer m;
    begin
      if (idx == 0) ftype = 0;
      else begin m = idx % 3; ftype = (m == 0) ? 1 : 2; end
    end
  endfunction

  reg clk = 0; always #5 clk = ~clk;
  reg rst_n = 0;

  // ---- the REAL drop controller ----
  reg  frame_late, drop_ack;
  reg  [3:0] drop_cost;
  wire drop_req;
  wire [15:0] flate_cnt, fdrop_cnt;
  wire [4:0]  debt;
  frame_drop_ctl #(.DROP_THRESHOLD(2), .DEBT_MAX(15)) dut (
    .clk(clk), .clk_en(1'b1), .rst(rst_n),
    .enable(1'b1), .bitstream_ok(1'b1),
    .frame_late(frame_late), .drop_ack(drop_ack), .drop_cost(drop_cost),
    .drop_req(drop_req),
    .frames_late_cnt(flate_cnt), .frames_dropped_cnt(fdrop_cnt), .debt_out(debt)
  );

  integer wall = 0;                 // display refreshes (declared early: arrival gate reads it)

  // ---- decoder model: display queue + parse pointer ----
  integer fifo [0:255];
  integer fifo_wr = 0, fifo_rd = 0;
  function integer fifo_cnt; fifo_cnt = fifo_wr - fifo_rd; endfunction

  integer dec_idx = 0;       // parse pointer: frame currently being decoded
  integer dec_busy = 0;
  integer backlog = 0;       // frames' worth of stream banked during the crush
  string  flagmode;

  // STREAM-PACED ARRIVAL (the HW reality the first model missed): the shared
  // demux delivers frames at REAL TIME — dropping a frame does NOT conjure a
  // replacement. Frame idx becomes decodable only once its data has arrived:
  // wall*2 >= (idx - CUSHION)*5  (durations avg 2.5 refr/frame; CUSHION = the
  // VBUF run-ahead in frames). This is what lets the drop-churn equilibrium
  // exist: with half the supply dropped, only ~12 shown-frames/s exist for a
  // display wanting ~24 -> perpetual lates -> perpetual debt -> more drops.
  localparam integer CUSHION = 24;   // ~2.5 s of VBUF run-ahead
  // (checked inline at the decode-start site; `wall` is declared below)

  function integer fcost(input integer idx);
    if (idx >= CR0 && idx < CR1) fcost = COST_CRUSH;
    else if (backlog > 0)        fcost = COST_BURST;   // draining the VBUF bank
    else                         fcost = COST_NORM;
  endfunction

  // content skipped by drops, credited to the display position when the next
  // frame is picked up (a dropped frame's content passes instantly)
  integer dropped_pend = 0;        // TRUE durations of dropped frames
  integer dropped_pend_cred = 0;   // ledger credit for them (== true here: exact debit)

  always @(posedge clk) begin
    drop_ack <= 0;
    if (rst_n && dec_idx < NFRAMES) begin
      // bank backlog while the crush stalls decode (stream keeps arriving)
      if (dec_idx >= CR0 && dec_idx < CR1 && dec_busy > 2) backlog <= backlog + 1;
      if (dec_busy > 0) begin
        dec_busy <= dec_busy - 1;
        if (dec_busy == 1 && fifo_cnt() < QD) begin
          fifo[fifo_wr % 256] <= dec_idx;
          fifo_wr <= fifo_wr + 1;
          dec_idx <= dec_idx + 1;
          if (backlog > 0) backlog <= backlog - 1;
        end
      end else if (fifo_cnt() < QD && (wall * 2) >= ((dec_idx - CUSHION) * 5)) begin
        if ((ftype(dec_idx) == 2) && drop_req) begin
          drop_ack          <= 1;
          drop_cost         <= fdur(dec_idx);           // exact debit (shipped)
          dropped_pend      <= dropped_pend + fdur(dec_idx);
          dropped_pend_cred <= dropped_pend_cred + fdur(dec_idx);
          dec_idx  <= dec_idx + 1;
          dec_busy <= DROP_COST;
        end else begin
          dec_busy <= fcost(dec_idx);
        end
      end
    end
  end

  // ---- governor model (resample_addrgen semantics) ----
  integer refresh_div = 0;
  integer cur = -1;                 // frame on display
  integer cur_show = 2;             // its SAMPLED display target
  integer shown = 0;
  integer content_true = 0;         // true content presented (lips numerator)
  integer content_cred = 0;         // ledger credit (vid_err numerator)
  integer late_total = 0;

  // the flag the governor samples at pickup
  function integer sampled_show(input integer picked_idx);
    if (flagmode == "tagged") sampled_show = fdur(picked_idx);
    else                      sampled_show = rff(dec_idx) ? 3 : 2;  // LIVE parse register
  endfunction

  wire refresh_tick = (refresh_div == REFRESH - 1);
  always @(posedge clk) begin
    frame_late <= 0;
    if (rst_n) begin
      refresh_div <= refresh_tick ? 0 : refresh_div + 1;
      if (refresh_tick) begin
        wall <= wall + 1;
        if (cur < 0) begin
          if (fifo_cnt() > 0) begin
            cur      <= fifo[fifo_rd % 256];
            cur_show <= sampled_show(fifo[fifo_rd % 256]);
            fifo_rd  <= fifo_rd + 1;
            shown    <= 1;
          end
        end else if (shown >= cur_show) begin
          if (fifo_cnt() > 0) begin
            // frame complete: true content advances by ITS true duration
            // (+ any dropped content that passed); ledger credits the SAMPLED
            // show + the drop credits — exactly the row-20 instrument
            content_true <= content_true + fdur(cur) + dropped_pend;
            content_cred <= content_cred + cur_show + dropped_pend_cred;
            dropped_pend <= 0; dropped_pend_cred <= 0;
            cur      <= fifo[fifo_rd % 256];
            cur_show <= sampled_show(fifo[fifo_rd % 256]);
            fifo_rd  <= fifo_rd + 1;
            shown    <= 1;
          end else begin
            frame_late <= 1;
            late_total <= late_total + 1;
            shown <= shown + 1;
          end
        end else shown <= shown + 1;
      end
    end
  end

  // ---- run + bucket report ----
  integer lips, viderr, t10, lastw = 0, lastl = 0, lastd = 0;
  initial begin
    if (!$value$plusargs("FLAG=%s", flagmode)) flagmode = "live";
    drop_cost = 4'd2;
    repeat (4) @(posedge clk);
    rst_n = 1;
    $display("FLAG=%0s  (crush = frames %0d..%0d, ~t=%0ds)", flagmode, CR0, CR1,
             (CR0 * 5) / (2 * 60));
    $display("  t(s) |  lips(refr) vid_err(refr) | lates drops   (per bucket)");
    t10 = 0;
    while (dec_idx < NFRAMES) begin
      @(posedge clk);
      if (wall >= (t10 + 1) * 600) begin   // 10 s buckets (60 refr/s model)
        t10 = t10 + 1;
        lips   = content_true + dropped_pend - wall;
        viderr = wall - (content_cred + dropped_pend_cred);
        $display("  %4d |  %6d      %6d       | %5d %5d", t10 * 10, lips, viderr,
                 flate_cnt - lastl, fdrop_cnt - lastd);
        lastl = flate_cnt; lastd = fdrop_cnt;
      end
    end
    lips   = content_true + dropped_pend - wall;
    viderr = wall - (content_cred + dropped_pend_cred);
    $display("FINAL: lips=%0d refr (%0d ms)  vid_err=%0d refr  lates=%0d drops=%0d",
             lips, (lips * 1668) / 100, viderr, flate_cnt, fdrop_cnt);
    $finish;
  end

  initial begin #600000000 $display("TIMEOUT"); $finish; end
endmodule
