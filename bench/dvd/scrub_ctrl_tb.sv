// scrub_ctrl_tb.sv - unit test for dvd/scrub_ctrl.sv (hold-to-seek, SEEK-ON-RELEASE).
//
// Holding D-pad L/R pauses (hold_freeze) and accumulates an accelerating target
// offset against the title RBN span; releasing issues ONE raw-RBN seek. Checks:
// hold->release seeks in the held direction; a longer hold seeks further
// (acceleration); backward; clamp at title start/end; a too-short tap does
// nothing; hold_freeze high only while held; direction-flip restarts; in_title
// gate; the acceleration LADDER and the tier dwells (T13-T15, 2026-09-03); the
// step as an absolute CONTENT RATE rather than a fraction of the title span
// (T16-T18, 2026-09-12).
// Time thresholds are shrunk via parameter override -- the SHIFT ladders are
// NOT, so T13/T14 measure the shipping steps.
//
// ★ T13/T14 run with title_secs = 7200 (two hours) and that is load-bearing, not
// incidental: it is the ANCHOR of the duration bucket, so those two arms double
// as the proof that the 2 h feel signed off on hardware is BIT-IDENTICAL after
// the rate change. If they ever need new expected numbers, the anchor moved.
//
//   iverilog -g2012 -o /tmp/scrub_sim dvd/scrub_ctrl.sv bench/dvd/scrub_ctrl_tb.sv
//   vvp /tmp/scrub_sim
`timescale 1ns/1ps
`default_nettype none

module scrub_ctrl_tb;
    localparam T1_C = 100, T2_C = 200, T3_C = 300, TICK_C = 10, LING_C = 50;

    logic        clk = 0, rst_n = 0;
    logic        held_right = 0, held_left = 0, in_title = 1;
    logic [31:0] cur_rbn = 32'd100000;
    logic [31:0] title_first = 32'd0, title_last = 32'd1000000;

    logic        seek_rbn_pulse;
    logic [31:0] seek_rbn;
    logic        hold_freeze, bar_active;
    logic [31:0] bar_base_rbn, bar_tgt_rbn;

    // jump mode (dpad_seek)
    logic        jump_fire = 0, jump_dir = 0;
    logic [31:0] jump_base = 0, jump_off = 0;

    // what the span is worth. 7200 s = the duration anchor, so every scenario
    // written before 2026-09-12 keeps its original expected numbers.
    logic [15:0] tsecs    = 16'd7200;
    logic [23:0] lblk10   = 24'd0;
    logic        lrate_ok = 1'b0;

    always #5 clk = ~clk;

    scrub_ctrl #(.T1(T1_C), .T2(T2_C), .T3(T3_C), .TICK(TICK_C), .LINGER(LING_C)) dut (
        .clk(clk), .rst_n(rst_n),
        .held_right(held_right), .held_left(held_left), .in_title(in_title),
        .cur_rbn(cur_rbn), .title_first_rbn(title_first), .title_last_rbn(title_last),
        .title_secs(tsecs), .lin_blk10(lblk10), .lin_rate_ok(lrate_ok),
        .seek_rbn_pulse(seek_rbn_pulse), .seek_rbn(seek_rbn),
        .hold_freeze(hold_freeze),
        .bar_active(bar_active), .bar_base_rbn(bar_base_rbn), .bar_tgt_rbn(bar_tgt_rbn),
        .jump_fire(jump_fire), .jump_dir(jump_dir),
        .jump_base(jump_base), .jump_off(jump_off)
    );

    // ---- a defaults-only instance, used ONLY to read back the shipped
    // parameter values (T15). Held in reset; drives nothing.
    scrub_ctrl dut_def (
        .clk(clk), .rst_n(1'b0),
        .held_right(1'b0), .held_left(1'b0), .in_title(1'b0),
        .cur_rbn(32'd0), .title_first_rbn(32'd0), .title_last_rbn(32'd0),
        .title_secs(16'd0), .lin_blk10(24'd0), .lin_rate_ok(1'b0),
        .seek_rbn_pulse(), .seek_rbn(),
        .hold_freeze(),
        .bar_active(), .bar_base_rbn(), .bar_tgt_rbn(),
        .jump_fire(1'b0), .jump_dir(1'b0),
        .jump_base(32'd0), .jump_off(32'd0)
    );

    integer errors = 0;
    // ⚠ 128 chars, not the original 32: a [255:0] message SILENTLY TRUNCATES
    // from the left, so a long assertion label printed as "hin 2x of the 2 h
    // rate" and nothing downstream could grep for the arm that failed.
    task automatic chk(input cond, input [1023:0] msg);
        if (!cond) begin $display("  FAIL: %0s", msg); errors = errors + 1; end
    endtask

    // ---- measured per-tick increment of the target (T13/T14) ----------------
    // Reads bar_tgt_rbn only, so it measures what the accumulator actually did.
    // hold_freeze == want, so it brackets the gesture exactly.
    logic [31:0] tgt_prev, last_delta;
    logic        hf_d;
    always @(posedge clk) begin
        hf_d <= hold_freeze;
        if (hold_freeze && !hf_d) begin
            tgt_prev   <= bar_tgt_rbn;
            last_delta <= 32'd0;
        end else if (hold_freeze && (bar_tgt_rbn != tgt_prev)) begin
            last_delta <= bar_tgt_rbn - tgt_prev;
            tgt_prev   <= bar_tgt_rbn;
        end
    end

    // capture the release seek
    logic        got; logic [31:0] cap_rbn;
    always @(posedge clk) if (seek_rbn_pulse) begin got <= 1'b1; cap_rbn <= seek_rbn; end

    task automatic tick(input integer n);
        integer k; begin for (k = 0; k < n; k = k + 1) @(posedge clk); end
    endtask

    // T14: hold on to a given hold_cnt, tracked in the TB so each wait can be
    // written as an absolute point on the ramp rather than a delta.
    localparam SETTLE = 4 * (TICK_C + 1);
    integer hc = 0;
    task automatic hold_until(input integer n);
        begin if (n > hc) begin tick(n - hc); hc = n; end end
    endtask

    // hold `dir` (1=right/fwd, 0=left/bwd) for `cyc` cycles, release, capture seek.
    task automatic gesture(input dir, input integer cyc);
        begin
            got = 1'b0;
            if (dir) held_right = 1'b1; else held_left = 1'b1;
            tick(cyc);
            held_right = 1'b0; held_left = 1'b0;
            tick(6);                       // let the release pulse land
        end
    endtask

    integer fwd_short, fwd_long, ms_tick, ss;

    // A measured linear step, converted into CONTENT-SECONDS PER SECOND using
    // the SHIPPED tick period -- step blocks is step * 10000 / blk10 content-ms,
    // and there are 27e6 / TICK ticks a second.
    function automatic integer lin_rate(input [31:0] stp);
        integer ms_per_tick;
        begin
            ms_per_tick = (stp * 10000) / 861;
            lin_rate    = (ms_per_tick * (27_000_000 / dut_def.TICK)) / 1000;
        end
    endfunction

    // fire a resolved jump (one cycle), then let the jump_go stage land.
    task automatic jump(input dir, input [31:0] base, input [31:0] off);
        begin
            got = 1'b0;
            @(posedge clk);
            jump_dir = dir; jump_base = base; jump_off = off; jump_fire = 1'b1;
            @(posedge clk);
            jump_fire = 1'b0;
            tick(4);
        end
    endtask

    initial begin
        rst_n = 0; tick(4); rst_n = 1; tick(2);

        // ---------- TEST 1: hold forward -> release seeks forward ----------
        $display("TEST 1: hold fwd -> seek fwd");
        cur_rbn = 32'd100000; tick(2);
        gesture(1'b1, 60);
        chk(got, "fwd: a seek issued on release");
        chk(cap_rbn > 32'd100000, "fwd: target ahead of base");
        chk(cap_rbn <= 32'd1000000, "fwd: within title end");
        chk(hold_freeze == 1'b0, "fwd: unfrozen after release");

        // ---------- TEST 2: longer hold seeks further (acceleration) ----------
        $display("TEST 2: acceleration (longer hold = further)");
        cur_rbn = 32'd100000; tick(2);
        gesture(1'b1, 40);  fwd_short = cap_rbn - 32'd100000;
        cur_rbn = 32'd100000; tick(2);
        gesture(1'b1, 400); fwd_long  = cap_rbn - 32'd100000;
        chk(fwd_long > fwd_short, "accel: longer hold -> larger offset");

        // ---------- TEST 3: backward ----------
        $display("TEST 3: hold back -> seek back");
        cur_rbn = 32'd500000; tick(2);
        gesture(1'b0, 60);
        chk(got, "back: a seek issued");
        chk(cap_rbn < 32'd500000, "back: target behind base");

        // ---------- TEST 4: clamp at title end / start ----------
        $display("TEST 4: clamp");
        cur_rbn = 32'd990000; tick(2);
        gesture(1'b1, 1500);                  // long fwd hold near the end
        chk(cap_rbn == 32'd1000000, "clamp: forward clamps to title_last");
        cur_rbn = 32'd5000; tick(2);
        gesture(1'b0, 1500);                  // long back hold near the start
        chk(cap_rbn == 32'd0, "clamp: backward clamps to title_first");

        // ---------- TEST 5: too-short tap does nothing ----------
        $display("TEST 5: sub-tick tap = no seek");
        cur_rbn = 32'd100000; tick(2);
        got = 1'b0;
        held_right = 1'b1; tick(3); held_right = 1'b0;   // < 1 TICK -> no accumulation
        tick(6);
        chk(!got, "tap: no seek when nothing accumulated");

        // ---------- TEST 6: hold_freeze high only while held ----------
        $display("TEST 6: hold_freeze");
        cur_rbn = 32'd100000; tick(2);
        held_right = 1'b1; tick(20);
        chk(hold_freeze == 1'b1, "freeze: high while held");
        held_right = 1'b0; tick(6);
        chk(hold_freeze == 1'b0, "freeze: low after release");

        // ---------- TEST 7: direction flip restarts the gesture ----------
        $display("TEST 7: direction flip");
        cur_rbn = 32'd500000; tick(2);
        got = 1'b0;
        held_right = 1'b1; tick(80);          // accumulate forward
        held_right = 1'b0; held_left = 1'b1;  // flip to backward (no release between)
        tick(80);
        held_left = 1'b0; tick(6);
        chk(got, "flip: a seek issued on release");
        chk(cap_rbn < 32'd500000, "flip: final direction (backward) wins");

        // ---------- TEST 8: in_title gate ----------
        $display("TEST 8: in_title gate");
        in_title = 0; cur_rbn = 32'd100000; tick(2);
        got = 1'b0;
        held_right = 1'b1; tick(200);
        chk(hold_freeze == 1'b0, "gate: no freeze when !in_title");
        held_right = 1'b0; tick(6);
        chk(!got, "gate: no seek when !in_title");
        in_title = 1; tick(2);

        // ---------- TEST 9: jump mode seeks base +/- off ----------
        $display("TEST 9: jump mode");
        cur_rbn = 32'd400000; tick(2);
        jump(1'b1, 32'd300000, 32'd25000);
        chk(got, "jump fwd: a seek issued");
        chk(cap_rbn == 32'd325000, "jump fwd: target = jump_base + jump_off (NOT cur_rbn)");
        jump(1'b0, 32'd300000, 32'd25000);
        chk(got, "jump bwd: a seek issued");
        chk(cap_rbn == 32'd275000, "jump bwd: target = jump_base - jump_off");
        chk(hold_freeze == 1'b0, "jump: never freezes video");

        // ---------- TEST 10: jump clamps to the title span ----------
        $display("TEST 10: jump clamp");
        jump(1'b1, 32'd990000, 32'd500000);
        chk(cap_rbn == 32'd1000000, "jump: clamped at title_last");
        jump(1'b0, 32'd10000, 32'd500000);
        chk(cap_rbn == 32'd0, "jump: clamped at title_first");

        // ---------- TEST 11: a held FF/REW gesture always wins ----------
        $display("TEST 11: jump ignored while held");
        cur_rbn = 32'd500000; tick(2);
        got = 1'b0;
        held_right = 1'b1; tick(30);
        jump_dir = 1'b0; jump_base = 32'd10; jump_off = 32'd5; jump_fire = 1'b1;
        @(posedge clk); jump_fire = 1'b0; tick(4);
        chk(!got, "jump: no seek issued while a hold gesture is live");
        held_right = 1'b0; tick(6);
        chk(got && cap_rbn > 32'd500000, "jump: the HOLD's own release seek is unharmed");

        // ---------- TEST 12: jump gated by in_title ----------
        $display("TEST 12: jump in_title gate");
        in_title = 0; tick(2);
        jump(1'b1, 32'd300000, 32'd25000);
        chk(!got, "jump: no seek when !in_title");
        in_title = 1; tick(2);

        // ---------- TEST 13: the acceleration ladder, MEASURED ----------
        // span = 1_000_000, so the shipped {12,10,8,6} ladder gives
        // (span>>SH)|1 = 245 / 977 / 3907 / 15625 sectors per tick. Measured off
        // bar_tgt_rbn, not read out of the DUT, so a changed ladder fails here.
        $display("TEST 13: acceleration ladder (span >> {12,10,8,6})");
        cur_rbn = 32'd100000; tick(4);
        held_right = 1'b1;
        tick(60);   chk(last_delta == 32'd245,   "ladder: tier 0 step = span>>12");
        tick(100);  chk(last_delta == 32'd977,   "ladder: tier 1 step = span>>10");
        tick(100);  chk(last_delta == 32'd3907,  "ladder: tier 2 step = span>>8");
        tick(120);  chk(last_delta == 32'd15625, "ladder: tier 3 step = span>>6");
        held_right = 1'b0; tick(6);

        // ---------- TEST 14: the tier boundaries sit on T1/T2/T3 ----------
        // An accumulate lands every TICK_C+1 cycles, so the resolution here is
        // one tick: this brackets each boundary rather than pinning a cycle.
        // Waits are expressed in the parameters (SETTLE = 4 ticks past a
        // boundary, so at least three accumulates land in the new tier) --
        // hand-tuned cycle counts silently stop bracketing when TICK_C moves.
        $display("TEST 14: tier boundaries");
        cur_rbn = 32'd100000; tick(4);
        hc = 0; held_right = 1'b1;
        hold_until(T1_C - 2);        chk(last_delta == 32'd245,   "bound: tier 0 holds to T1");
        hold_until(T1_C + SETTLE);   chk(last_delta == 32'd977,   "bound: tier 1 after T1");
        hold_until(T2_C - 2);        chk(last_delta == 32'd977,   "bound: tier 1 holds to T2");
        hold_until(T2_C + SETTLE);   chk(last_delta == 32'd3907,  "bound: tier 2 after T2");
        hold_until(T3_C - 2);        chk(last_delta == 32'd3907,  "bound: tier 2 holds to T3");
        hold_until(T3_C + SETTLE);   chk(last_delta == 32'd15625, "bound: tier 3 after T3");
        held_right = 1'b0; tick(6);

        // ---------- TEST 15: the SHIPPED defaults are the intended feel ----------
        // This gate exists so a change to the scrub feel is deliberate. If it
        // fails because you retuned on purpose, update it -- and the four docs
        // named in scrub_ctrl.sv's header.
        $display("TEST 15: shipped default parameters");
        chk(dut_def.T1  == 54_000_000,  "defaults: T1 = 2.0 s @ 27 MHz");
        chk(dut_def.T2  == 121_500_000, "defaults: T2 = 4.5 s @ 27 MHz");
        chk(dut_def.T3  == 216_000_000, "defaults: T3 = 8.0 s @ 27 MHz");
        chk(dut_def.SH0 == 5'd12,       "defaults: SH0 = 12");
        chk(dut_def.SH1 == 5'd10,       "defaults: SH1 = 10");
        chk(dut_def.SH2 == 5'd8,        "defaults: SH2 = 8");
        chk(dut_def.SH3 == 5'd6,        "defaults: SH3 = 6");
        chk(dut_def.LS0 == 5'd5,        "defaults: LS0 = 5");
        chk(dut_def.LS1 == 5'd3,        "defaults: LS1 = 3");
        chk(dut_def.LS2 == 5'd1,        "defaults: LS2 = 1");
        chk(dut_def.LS3 == 5'd0,        "defaults: LS3 = 0");
        chk(dut_def.SECS_REF == 5'd12,  "defaults: SECS_REF = 12 (the 2 h anchor)");
        // T3 must fit hold_cnt (28 bits) or the ramp would never reach tier 3.
        chk(dut_def.T3  < 28'h fff_ffff, "defaults: T3 fits hold_cnt");

        // ---------- TEST 16: the 2 h ANCHOR -- an unchanged step -----------
        // The duration bucket may only move titles AWAY from two hours. Every
        // title whose leading one sits at bit 12 (4096..8191 s = 68..136 min)
        // must produce the step that shipped, and so must a title whose length
        // is not known yet. Measured against the same numbers TEST 13 pins.
        $display("TEST 16: the 2 h anchor is bit-identical");
        title_first = 32'd0; title_last = 32'd1000000;
        tsecs = 16'd4096; cur_rbn = 32'd100000; tick(4);
        held_right = 1'b1; tick(60);
        chk(last_delta == 32'd245, "anchor: 4096 s (the bucket's floor) = span>>12");
        held_right = 1'b0; tick(8);
        tsecs = 16'd8191; cur_rbn = 32'd100000; tick(4);
        held_right = 1'b1; tick(60);
        chk(last_delta == 32'd245, "anchor: 8191 s (the bucket's ceiling) = span>>12");
        held_right = 1'b0; tick(8);
        tsecs = 16'd0; cur_rbn = 32'd100000; tick(4);
        held_right = 1'b1; tick(60);
        chk(last_delta == 32'd245, "anchor: an unknown duration keeps the old step");
        held_right = 1'b0; tick(8);
        // ...and a title well away from the anchor must NOT be unchanged, or the
        // bucket is inert and this whole arm proves nothing.
        tsecs = 16'd180; cur_rbn = 32'd100000; tick(4);
        held_right = 1'b1; tick(60);
        chk(last_delta != 32'd245, "anchor: a 3-minute title does move off the shipped step");
        held_right = 1'b0; tick(8);
        tsecs = 16'd7200;

        // ---------- TEST 17: a short title scrubs at a COMPARABLE RATE -------
        // The defect, in the units a viewer feels. A 3-minute clip measured
        // 15504 sectors and 0.58 content-seconds per second at tier 0, against
        // 29 for a 2 h feature -- the shorter the title, the slower the scrub.
        // Scored as content-MILLISECONDS PER TICK (step * title_secs / span), so
        // this is a rate the user experiences and not a restatement of the shift.
        $display("TEST 17: a 3-minute title, scored as a content rate");
        title_first = 32'd0; title_last = 32'd15504; tsecs = 16'd180;
        cur_rbn = 32'd200; tick(4);
        held_right = 1'b1; tick(40);            // inside tier 0, before the cap
        ms_tick = (last_delta * 180 * 1000) / 15504;
        held_right = 1'b0; tick(8);
        $display("  tier 0 on a 3-minute clip: step=%0d sectors = %0d content-ms/tick",
                 last_delta, ms_tick);
        // The 2 h reference is 1054 * 7200 * 1000 / 4320000 = 1757 ms/tick. Half
        // to double that is the band; the pre-change RTL scores 34 and the `| 1`
        // floor alone scores 11, so both failure shapes are outside it.
        chk(ms_tick >= 878 && ms_tick <= 3514,
            "rate: a 3-minute clip scrubs within 2x of the 2 h rate at tier 0");
        title_first = 32'd0; title_last = 32'd1000000; tsecs = 16'd7200;

        // ---------- TEST 18: the LINEAR arm, in content-seconds per second ----
        // lin_blk10 is blocks per 10 s, so the shift IS the rate and the bench
        // can say so in the user's units. The tick rate comes from the SHIPPED
        // TICK parameter (read off the defaults instance), not from this bench's
        // shrunk override -- otherwise "seconds per second" would be fiction.
        $display("TEST 18: the linear ladder as content-seconds per second");
        lblk10 = 24'd861;                       // exact CD geometry (VCD/SVCD)
        lrate_ok = 1'b1;
        cur_rbn = 32'd100000; tick(4);
        held_right = 1'b1;
        tick(60);   ss = lin_rate(last_delta);
        $display("  tier 0: step=%0d blocks = %0d content-s/s", last_delta, ss);
        chk(last_delta == 32'd27 && ss >= 4 && ss <= 7,   "linear: tier 0 ~5 s/s");
        tick(100);  ss = lin_rate(last_delta);
        $display("  tier 1: step=%0d blocks = %0d content-s/s", last_delta, ss);
        chk(last_delta == 32'd107 && ss >= 17 && ss <= 26, "linear: tier 1 ~21 s/s");
        tick(100);  ss = lin_rate(last_delta);
        $display("  tier 2: step=%0d blocks = %0d content-s/s", last_delta, ss);
        chk(last_delta == 32'd431 && ss >= 70 && ss <= 100, "linear: tier 2 ~83 s/s");
        tick(120);  ss = lin_rate(last_delta);
        $display("  tier 3: step=%0d blocks = %0d content-s/s", last_delta, ss);
        chk(last_delta == 32'd861 && ss >= 140 && ss <= 200, "linear: tier 3 ~167 s/s");
        held_right = 1'b0; tick(8);
        // ...and the rate must be TRUSTED, not merely present: with the valid
        // flag low the module falls back to the span path exactly as it shipped.
        // (dvd/dpad_seek.sv's precedent -- a zero rate through this arm would
        // pin the step at the `| 1` floor and the scrub would look broken.)
        lrate_ok = 1'b0; lblk10 = 24'd0;
        cur_rbn = 32'd100000; tick(4);
        held_right = 1'b1; tick(60);
        chk(last_delta == 32'd245, "linear: an untrusted rate falls back to the span step");
        held_right = 1'b0; tick(8);

        if (errors == 0) $display("\nscrub_ctrl_tb: ALL TESTS PASSED");
        else begin
            $display("\nscrub_ctrl_tb: %0d FAILURE(S)", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin #10_000_000; $display("GLOBAL TIMEOUT"); $finish; end
endmodule
`default_nettype wire
