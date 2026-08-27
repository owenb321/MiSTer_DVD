// scrub_ctrl_tb.sv - unit test for dvd/scrub_ctrl.sv (hold-to-seek, SEEK-ON-RELEASE).
//
// Holding D-pad L/R pauses (hold_freeze) and accumulates an accelerating target
// offset against the title RBN span; releasing issues ONE raw-RBN seek. Checks:
// hold->release seeks in the held direction; a longer hold seeks further
// (acceleration); backward; clamp at title start/end; a too-short tap does
// nothing; hold_freeze high only while held; direction-flip restarts; in_title
// gate. Thresholds shrunk via parameter override.
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

    always #5 clk = ~clk;

    scrub_ctrl #(.T1(T1_C), .T2(T2_C), .T3(T3_C), .TICK(TICK_C), .LINGER(LING_C)) dut (
        .clk(clk), .rst_n(rst_n),
        .held_right(held_right), .held_left(held_left), .in_title(in_title),
        .cur_rbn(cur_rbn), .title_first_rbn(title_first), .title_last_rbn(title_last),
        .seek_rbn_pulse(seek_rbn_pulse), .seek_rbn(seek_rbn),
        .hold_freeze(hold_freeze),
        .bar_active(bar_active), .bar_base_rbn(bar_base_rbn), .bar_tgt_rbn(bar_tgt_rbn),
        .jump_fire(jump_fire), .jump_dir(jump_dir),
        .jump_base(jump_base), .jump_off(jump_off)
    );

    integer errors = 0;
    task automatic chk(input cond, input [255:0] msg);
        if (!cond) begin $display("  FAIL: %0s", msg); errors = errors + 1; end
    endtask

    // capture the release seek
    logic        got; logic [31:0] cap_rbn;
    always @(posedge clk) if (seek_rbn_pulse) begin got <= 1'b1; cap_rbn <= seek_rbn; end

    task automatic tick(input integer n);
        integer k; begin for (k = 0; k < n; k = k + 1) @(posedge clk); end
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

    integer fwd_short, fwd_long;

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
