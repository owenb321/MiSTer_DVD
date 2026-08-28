// frame_drop_ctl_tb.sv — DVD-FORK (frame-drop governor, O[19])
//
// Verifies the timeline-debt catch-up controller (dvd/frame_drop_ctl.sv):
//   1. Below-threshold lateness does NOT drop (the MiB over-drop / speed-up fix):
//      a single frame_late (debt=1 < DROP_THRESHOLD=2) leaves drop_req low.
//   2. At/above threshold, drop_req asserts.
//   3. A drop_ack reclaims DROP_THRESHOLD refreshes of debt.
//   4. debt never goes negative (guarded) => can never overshoot into a speed-up.
//   5. debt saturates at DEBT_MAX (sustained deficit pins drop_req, no wrap).
//   6. Coincident late+drop nets to (+1 - THRESHOLD).
//   7. enable=0 forces drop_req low and holds debt at 0 (safe A/B / no banked debt).
//   8. Debug counters tally every event.
//
// Build:
//   iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 \
//       dvd/frame_drop_ctl.sv bench/dvd/frame_drop_ctl_tb.sv -o bench/dvd/frame_drop_ctl_sim
//   vvp bench/dvd/frame_drop_ctl_sim

`timescale 1ns/1ns

module frame_drop_ctl_tb;

  localparam DROP_THRESHOLD = 2;
  localparam DEBT_MAX       = 15;

  reg         clk = 1'b0;
  reg         clk_en = 1'b1;
  reg         rst = 1'b0;
  reg         enable = 1'b0;
  reg         frame_late = 1'b0;
  reg         drop_ack = 1'b0;

  wire        drop_req;
  wire [15:0] frames_late_cnt;
  wire [15:0] frames_dropped_cnt;
  wire  [4:0] debt_out;

  integer errors = 0;

  reg bitstream_ok = 1'b1;   // healthy by default; the guard case toggles it
  reg flush = 1'b0;          // VBUF-flush level; case [9] drives it
  reg [3:0] drop_cost = 4'd2; // flat SHOW_N by default; the film case drives 3

  frame_drop_ctl #(.DROP_THRESHOLD(DROP_THRESHOLD), .DEBT_MAX(DEBT_MAX)) dut (
    .clk(clk), .clk_en(clk_en), .rst(rst),
    .enable(enable), .bitstream_ok(bitstream_ok), .flush(flush),
    .frame_late(frame_late), .drop_ack(drop_ack), .drop_cost(drop_cost),
    .drop_req(drop_req),
    .frames_late_cnt(frames_late_cnt),
    .frames_dropped_cnt(frames_dropped_cnt),
    .debt_out(debt_out)
  );

  always #5 clk = ~clk;

  // starvation-guard case runs from the main initial block via this task
  task check_guard; begin
    // accrue debt to the threshold while healthy -> drop_req asserts
    bitstream_ok = 1'b1;
    pulse_late; pulse_late;
    @(negedge clk);
    if (!drop_req) begin $display("FAIL: drop_req low with debt at threshold (pre-guard)"); errors = errors + 1; end
    // starve the bitstream -> drop_req must gate off even with debt banked
    bitstream_ok = 1'b0;
    @(negedge clk);
    if (drop_req) begin $display("FAIL: drop_req asserted while bitstream starved"); errors = errors + 1; end
    // starvation lates must NOT accrue debt
    begin : g1
      reg [4:0] d0; d0 = debt_out;
      pulse_late; pulse_late; pulse_late;
      if (debt_out !== d0) begin $display("FAIL: debt accrued during starvation (%0d -> %0d)", d0, debt_out); errors = errors + 1; end
    end
    // recover -> drop_req returns (debt still banked from before)
    bitstream_ok = 1'b1;
    @(negedge clk);
    if (!drop_req) begin $display("FAIL: drop_req did not return after recovery"); errors = errors + 1; end
    // drain the banked debt so following cases start clean
    pulse_ack; pulse_ack; pulse_ack; pulse_ack;
    $display("guard case done (debt=%0d)", debt_out);
  end endtask

  task pulse_late; begin
    @(negedge clk); frame_late = 1'b1;
    @(negedge clk); frame_late = 1'b0;
  end endtask

  task pulse_ack; begin
    @(negedge clk); drop_ack = 1'b1;
    @(negedge clk); drop_ack = 1'b0;
  end endtask

  task pulse_both; begin
    @(negedge clk); frame_late = 1'b1; drop_ack = 1'b1;
    @(negedge clk); frame_late = 1'b0; drop_ack = 1'b0;
  end endtask

  task check(input [8*48:1] name, input cond); begin
    if (!cond) begin
      $display("  FAIL: %0s (debt=%0d drop_req=%0b late=%0d drop=%0d)",
               name, debt_out, drop_req, frames_late_cnt, frames_dropped_cnt);
      errors = errors + 1;
    end else
      $display("  ok:   %0s (debt=%0d drop_req=%0b)", name, debt_out, drop_req);
  end endtask

  integer i;

  initial begin
    rst = 1'b0; enable = 1'b0;
    @(negedge clk); @(negedge clk);
    rst = 1'b1;
    @(negedge clk);
    check("reset: debt 0",       debt_out == 5'd0);
    check("reset: drop_req low", drop_req == 1'b0);

    // ---- 1. THE MiB FIX: one late (debt=1) is below threshold => NO drop ----
    $display("[1] enabled, single late (below threshold) must NOT drop");
    enable = 1'b1;
    pulse_late;
    @(negedge clk);
    check("debt 1",                 debt_out == 5'd1);
    check("drop_req LOW (no drop)",  drop_req == 1'b0);

    // ---- 2. second late reaches threshold => drop_req asserts ----
    $display("[2] second late reaches threshold");
    pulse_late;
    @(negedge clk);
    check("debt 2",                 debt_out == 5'd2);
    check("drop_req HIGH",           drop_req == 1'b1);

    // ---- 3. a drop reclaims DROP_THRESHOLD refreshes ----
    $display("[3] drop_ack reclaims SHOW_N refreshes");
    pulse_ack;
    @(negedge clk);
    check("debt back to 0",         debt_out == 5'd0);
    check("drop_req low",            drop_req == 1'b0);
    check("dropped counted 1",       frames_dropped_cnt == 16'd1);
    check("late counted 2",          frames_late_cnt == 16'd2);

    // ---- 4. debt never underflows: a drop with debt<THRESHOLD clamps to 0 ----
    $display("[4] drop with sub-threshold debt clamps at 0 (never speeds up)");
    pulse_late;             // debt 1
    @(negedge clk);
    check("debt 1 pre",             debt_out == 5'd1);
    pulse_ack;             // would subtract 2 -> clamp 0
    @(negedge clk);
    check("debt clamped 0 (no negative)", debt_out == 5'd0);

    // ---- 5. saturation at DEBT_MAX ----
    $display("[5] debt saturates at DEBT_MAX=%0d", DEBT_MAX);
    for (i = 0; i < DEBT_MAX + 4; i = i + 1) pulse_late;
    @(negedge clk);
    check("debt saturated",         debt_out == DEBT_MAX[4:0]);
    check("drop_req high (deficit)", drop_req == 1'b1);
    // drain to below threshold with drops
    for (i = 0; i < 8; i = i + 1) pulse_ack;
    @(negedge clk);
    check("drained below threshold", debt_out < DROP_THRESHOLD[4:0]);
    check("drop_req low again",       drop_req == 1'b0);

    // re-baseline: earlier signed-carry residue (floor) cleared via disable
    enable = 1'b0; @(negedge clk); enable = 1'b1; @(negedge clk);

    // ---- 6. coincident late+drop = net (+1 - THRESHOLD) ----
    $display("[6] coincident late+drop net (+1 - THRESHOLD)");
    // build debt up to 3
    pulse_late; pulse_late; pulse_late;
    @(negedge clk);
    check("debt 3 pre",             debt_out == 5'd3);
    pulse_both;            // +1 -2 = net -1 -> debt 2
    @(negedge clk);
    check("coincident: debt 2",     debt_out == 5'd2);

    // ---- 7. disable clears debt ----
    $display("[7] disable clears debt");
    enable = 1'b0;
    @(negedge clk); @(negedge clk);
    check("disable: debt 0",        debt_out == 5'd0);
    check("disable: drop_req low",  drop_req == 1'b0);
    // a late while disabled must not bank debt
    pulse_late;
    @(negedge clk);
    check("disabled: debt stays 0", debt_out == 5'd0);

    // ---- starvation guard (bitstream_ok) ----
    enable = 1'b1;
    @(negedge clk);
    check_guard;

    // ---- 8. film-aware reclaim: cost=3 debits 3 and the balance goes SIGNED ----
    // (a flat 2 against film's 2.5-refresh frames crept the display +0.5/drop;
    //  debiting the live cur_show is zero-mean — verify a 3-cost drop over-debits
    //  and the next lates repay the credit before drop_req re-fires)
    $display("[8] film-aware reclaim (cost=3, signed carry)");
    enable = 1'b0; @(negedge clk); enable = 1'b1; @(negedge clk);  // debt = 0
    drop_cost = 4'd3;
    pulse_late; pulse_late;                       // debt = 2 -> drop_req fires
    @(negedge clk);
    check("film: req at debt 2",   drop_req == 1'b1);
    pulse_ack;                                   // debit 3: debt = -1 (carried credit)
    @(negedge clk);
    check("film: req off after over-debit", drop_req == 1'b0);
    pulse_late; pulse_late;                       // -1 +2 = 1: still below threshold
    @(negedge clk);
    check("film: credit repaid first (no req at net 1)", drop_req == 1'b0);
    pulse_late;                                   // net 2 -> fires again
    @(negedge clk);
    check("film: req after credit + 3 lates", drop_req == 1'b1);
    pulse_ack;                                   // -3 again -> -1
    @(negedge clk);
    check("film: long-run neutral (req off)", drop_req == 1'b0);
    drop_cost = 4'd2;

    // ---- 9. VBUF flush clears carried debt (2026-08-28 mount/seek fix) ----
    // Debt used to survive every discontinuity (reset only by sync_rst), so a
    // warm mount/seek carried stale lateness into the new position and fired
    // spurious B-drops the moment vbuf_healthy re-armed.
    $display("[9] flush clears carried debt");
    enable = 1'b0; @(negedge clk); enable = 1'b1; @(negedge clk);  // debt = 0
    for (i = 0; i < 5; i = i + 1) pulse_late;    // bank 5 refreshes of "old title" debt
    @(negedge clk);
    check("flush: debt banked pre", debt_out == 5'd5);
    check("flush: req armed pre",   drop_req == 1'b1);
    flush = 1'b1;                                 // the seek/mount VBUF flush level
    @(negedge clk); @(negedge clk);
    check("flush: debt cleared",    debt_out == 5'd0);
    check("flush: req off",         drop_req == 1'b0);
    pulse_late;                                   // a late DURING the flush window
    @(negedge clk);
    check("flush: holds debt at 0 while asserted", debt_out == 5'd0);
    flush = 1'b0;
    @(negedge clk);
    pulse_late; pulse_late;                       // normal accounting resumes
    @(negedge clk);
    check("flush: accounting resumes (debt 2)", debt_out == 5'd2);
    check("flush: req resumes",                 drop_req == 1'b1);
    pulse_ack; @(negedge clk);                    // leave the ledger clean
    // telemetry must NOT have been cleared by the flush (free-running totals)
    check("flush: late counter untouched", frames_late_cnt > 16'd0);

    $display("");
    if (errors == 0) $display("PASS: frame_drop_ctl_tb (all checks)");
    else             $fatal(1, "FAIL: frame_drop_ctl_tb (%0d errors)", errors);
    $finish;
  end

  initial begin
    #200000;
    $display("FAIL: timeout");
    $finish;
  end

endmodule
