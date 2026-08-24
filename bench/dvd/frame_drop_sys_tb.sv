/*
 * frame_drop_sys_tb.sv — SYSTEM-level reproduction of the frame-drop speed-up.
 *
 * Purpose (measure-first): the unit tb (frame_drop_ctl_tb) proves the debt
 * arithmetic is correct in isolation, yet on HW the O[12] frame-drop still
 * SPEEDS UP MiB/Matrix (video + av_sync-slaved audio). This bench wires the REAL
 * dvd/frame_drop_ctl.sv to a *behavioral* model of the governor + a compute-bound
 * decoder, and MEASURES the on-screen content position vs real (wall-clock) time
 * so we can SEE whether/why the timeline compresses (speed-up).
 *
 * Model (integer refresh-tick time; display-order production — see NOTE):
 *   - Real time advances one "refresh" every REFRESH clk cycles (the 60/50 Hz
 *     display). The governor is HARD refresh-locked: it shows each source frame for
 *     SHOW_N refreshes, then consumes the next decoded frame if one is ready, else
 *     HOLDS (repeats) and emits a 1-clk frame_late pulse that refresh.
 *   - The decoder produces source frames in order into a FIFO, each costing
 *     COST_x clk cycles (B pricier — bidirectional). Sum(cost) > SHOW_N*REFRESH
 *     per frame => compute-bound (falls behind).
 *   - When the decoder is about to START a droppable B and frame_drop_ctl asserts
 *     drop_req, it SKIPS that B: no FIFO push, no cost spent (the catch-up), and it
 *     pulses drop_ack. The skipped source index is therefore never displayed.
 *
 * Metric: content_idx = source display-order index currently on screen. Ideal
 *   playback advances content_idx by exactly 1 per SHOW_N refreshes (content_time
 *   == real_time). speed = content_span / (real_refreshes/SHOW_N); 1.0 = correct,
 *   >1.0 = sped up. We run with drop DISABLED then ENABLED and compare.
 *
 * NOTE (simplification): real MPEG-2 decodes in coded order and reorders B's for
 * display; here we produce in display order. The speed-up is a content-time-removal
 * effect independent of reorder, so this is faithful for the diagnosis; refine later
 * if the reorder proves to matter.
 */
`timescale 1ns/1ps

module frame_drop_sys_tb;

  localparam integer REFRESH  = 20;   // clk cycles per display refresh
  localparam integer SHOW_N   = 2;    // refreshes per source frame (governor)
  localparam integer BUDGET   = SHOW_N*REFRESH; // real-time cycles per displayed frame = 40
  // decode costs (clk cycles). I/P FIT within budget (40); B's push the GOP average
  // OVER budget => mildly compute-bound. Dropping ~1 B per GOP lets the decoder keep
  // up. This is the realistic regime (MiB/Matrix): the decoder ALMOST keeps up.
  localparam integer COST_I   = 38;
  localparam integer COST_P   = 34;
  localparam integer COST_B   = 52;   // P B B over 3 slots = 34+52+52=138 vs 120 budget (+15%)
  // A DROPPED B still costs parse cycles (vld routes to STATE_NEXT_START_CODE, a
  // byte-aligned start-code hunt) — it is NOT free. This spacing lets drop_ack->debt
  // settle between drops, matching real HW where B picture-headers are far apart.
  localparam integer DROP_COST = 10;
  localparam integer NFRAMES  = 120;  // source frames to run
  localparam integer TARGET   = NFRAMES-2;          // "clip end" content index
  localparam integer RT_IDEAL = NFRAMES*SHOW_N;     // ideal real-refreshes to play the clip

  // GOP pattern in DISPLAY order: I B B P B B P ... (0=I,1=P,2=B)
  function integer ftype(input integer idx);
    integer m;
    begin
      if (idx == 0) ftype = 0;            // I
      else begin
        m = idx % 3;
        if (m == 0) ftype = 1;            // P every 3rd
        else        ftype = 2;            // B otherwise
      end
    end
  endfunction

  // Difficulty schedule: real content is BURSTY, not uniformly slow. HARD stretches
  // (high-motion) overrun the budget; EASY stretches let the decoder RUN AHEAD and
  // catch up on its own. HARD_LEN hard frames then EASY_LEN easy frames, repeating.
  localparam integer HARD_LEN = 15;
  localparam integer EASY_LEN = 15;
  localparam integer EASY_COST = 18;   // << BUDGET(40): decoder outruns real time
  function integer is_hard(input integer idx);
    is_hard = ((idx % (HARD_LEN+EASY_LEN)) < HARD_LEN);
  endfunction
  // per-frame decode cost given type + difficulty
  function integer fcost(input integer idx);
    begin
      if (!is_hard(idx)) fcost = EASY_COST;
      else fcost = (ftype(idx)==0)?COST_I : (ftype(idx)==1)?COST_P : COST_B;
    end
  endfunction

  reg clk = 0; always #5 clk = ~clk;
  reg rst_n;

  // ---- frame_drop_ctl (DUT: the REAL controller) ----
  reg  enable;
  reg  frame_late;   // 1-clk pulse from governor model
  reg  drop_ack;     // 1-clk pulse from decoder model
  wire drop_req;
  wire [15:0] flate_cnt, fdrop_cnt;
  wire [4:0]  debt;

  frame_drop_ctl #(.DROP_THRESHOLD(SHOW_N), .DEBT_MAX(15)) dut (
    .clk(clk), .clk_en(1'b1), .rst(rst_n),
    .enable(enable), .frame_late(frame_late), .drop_ack(drop_ack), .drop_cost(4'd2),
    .drop_req(drop_req),
    .frames_late_cnt(flate_cnt), .frames_dropped_cnt(fdrop_cnt), .debt_out(debt)
  );

  // ---- shared frame FIFO (decoder -> governor), stores source indices ----
  integer fifo[0:255];
  integer fifo_wr, fifo_rd;
  function integer fifo_count; fifo_count = fifo_wr - fifo_rd; endfunction

  // ---- decoder model ----
  integer dec_idx;        // next source frame to produce
  integer dec_timer;      // cycles left on current decode
  integer dec_active;     // 1 while spending cost on a real (non-dropped) frame
  integer dec_pending;    // source idx being decoded

  // ---- governor model ----
  integer refresh_div;    // clk divider -> refresh ticks
  integer refresh_cnt;    // refreshes since last frame consumed
  integer content_idx;    // source idx currently displayed (-1 before first)
  integer consumed;       // # source frames consumed (display slots filled w/ new frame)
  integer real_refresh;   // total refreshes elapsed (wall clock)
  integer holds;          // total late holds (repeats)

  integer dropped_total;

  task run_scenario(input integer en);
    begin
      // reset all model state
      rst_n = 0; enable = en[0:0];
      frame_late = 0; drop_ack = 0;
      fifo_wr = 0; fifo_rd = 0;
      dec_idx = 0; dec_timer = 0; dec_active = 0; dec_pending = 0;
      refresh_div = 0; refresh_cnt = 0; content_idx = -1; consumed = 0;
      real_refresh = 0; holds = 0; dropped_total = 0;
      repeat (4) @(posedge clk);
      rst_n = 1;

      // run until the clip's LAST content index is on screen (clip finished),
      // or a generous real-time safety cap. Measuring the real-time to finish the
      // same content span is the clean speed test: < RT_IDEAL => sped up.
      while (content_idx < TARGET && real_refresh < RT_IDEAL*4) begin
        @(posedge clk);
        frame_late <= 0;  // default; pulsed below
        drop_ack   <= 0;

        // ---------- DECODER ----------
        if (dec_active) begin
          if (dec_timer > 0) dec_timer = dec_timer - 1;
          if (dec_timer == 0) begin           // finished current decode/parse
            if (dec_pending >= 0) begin        // real frame -> push; -1 = dropped B
              fifo[fifo_wr[7:0]] = dec_pending;
              fifo_wr = fifo_wr + 1;
            end
            dec_active = 0;
          end
        end else if (dec_idx < NFRAMES) begin
          // about to start dec_idx
          if (ftype(dec_idx) == 2 && drop_req && enable) begin
            // DROP this B: skip its EXPENSIVE decode (save COST_B - DROP_COST), but it
            // still costs DROP_COST parse cycles; never pushed to fifo (not displayed).
            drop_ack    <= 1;
            dropped_total = dropped_total + 1;
            dec_pending = -1;                  // sentinel: dropped, do not push
            dec_timer   = DROP_COST;
            dec_active  = 1;
            dec_idx     = dec_idx + 1;
          end else begin
            dec_pending = dec_idx;
            dec_timer   = fcost(dec_idx);
            dec_active  = 1;
            dec_idx     = dec_idx + 1;
          end
        end

        // ---------- REAL-TIME / GOVERNOR ----------
        refresh_div = refresh_div + 1;
        if (refresh_div >= REFRESH) begin
          refresh_div  = 0;
          real_refresh = real_refresh + 1;
          refresh_cnt  = refresh_cnt + 1;
          if (refresh_cnt >= SHOW_N) begin
            if (fifo_count() > 0) begin
              content_idx = fifo[fifo_rd[7:0]];
              fifo_rd     = fifo_rd + 1;
              consumed    = consumed + 1;
              refresh_cnt = 0;
            end else begin
              // frame DUE but not decoded -> late hold (repeat), pulse frame_late
              frame_late <= 1;
              holds = holds + 1;
              // refresh_cnt stays >= SHOW_N so it re-fires next refresh
            end
          end
        end
      end

      // ---- report ---- (time to play the SAME content span = TARGET frames)
      $display("---- scenario: frame_drop %s ----", en ? "ENABLED " : "disabled");
      $display("  content span played : %0d frames (target %0d)", content_idx+1, TARGET+1);
      $display("  real refreshes used : %0d   (IDEAL = %0d)", real_refresh, RT_IDEAL);
      $display("  frames consumed     : %0d display slots", consumed);
      $display("  late holds (repeats): %0d", holds);
      $display("  B-frames dropped    : %0d   (ctl count=%0d)", dropped_total, fdrop_cnt);
      // speed = ideal_time / actual_time to play the same content. 1.00 = correct,
      // >1 = FAST (finished early = the HW bug), <1 = slow (held/judder).
      $display("  SPEED (playback rate): %0d.%02d  (1.00=correct, >1=SPED UP, <1=slow)",
               (RT_IDEAL*100/real_refresh)/100, (RT_IDEAL*100/real_refresh)%100);
      $display("");
    end
  endtask

  initial begin
    run_scenario(0);   // baseline: no dropping (expect slow-motion: content behind real-time, many holds)
    run_scenario(1);   // dropping ON: does content stay == real-time, or speed up?
    $finish;
  end

endmodule
