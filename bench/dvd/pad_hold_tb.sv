// pad_hold_tb.sv -- dvd/pad_hold.sv, every gesture (bench/dvd/run_pad_hold.sh).
// Time-compressed: T_HOLD = 100 clocks.
`timescale 1ns/1ps
module pad_hold_tb;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0, ff = 0, rew = 0;
    wire tap_ff, tap_rew, held_ff, held_rew;
    pad_hold #(.T_HOLD(100)) dut (.clk(clk), .rst_n(rst_n), .ff(ff), .rew(rew),
        .tap_ff(tap_ff), .tap_rew(tap_rew), .held_ff(held_ff), .held_rew(held_rew));

    integer errors = 0, n_tf = 0, n_tr = 0;
    always @(posedge clk) begin
        if (tap_ff === 1'b1)  n_tf = n_tf + 1;
        if (tap_rew === 1'b1) n_tr = n_tr + 1;
    end
    task fail(input [8*80-1:0] m); begin errors = errors + 1; $display("FAIL %0s", m); end endtask
    task clr; begin n_tf = 0; n_tr = 0; end endtask

    initial begin
        repeat (3) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

        // [1] a short Fast Fwd: one tap_ff at the release, never held
        clr; @(negedge clk) ff = 1; repeat (40) @(posedge clk);
        if (held_ff !== 1'b0) fail("[1] held before T_HOLD");
        @(negedge clk) ff = 0; repeat (5) @(posedge clk);
        if (n_tf != 1 || n_tr != 0) begin fail("[1] a short press is not ONE Fast Fwd tap"); $display("  tf %0d tr %0d", n_tf, n_tr); end

        // [2] a long Fast Fwd: held from T_HOLD to the release, and NO tap
        clr; @(negedge clk) ff = 1; repeat (90) @(posedge clk);
        if (held_ff !== 1'b0) fail("[2] held early");
        repeat (20) @(posedge clk);
        if (held_ff !== 1'b1 || held_rew !== 1'b0) fail("[2] not held_ff after T_HOLD");
        @(negedge clk) ff = 0; repeat (3) @(posedge clk);
        if (held_ff !== 1'b0) fail("[2] held_ff outlived the release");
        if (n_tf != 0 || n_tr != 0) fail("[2] a hold also tapped");

        // [3] Rewind, short and long: the same, on the other outputs
        clr; @(negedge clk) rew = 1; repeat (30) @(posedge clk); @(negedge clk) rew = 0; repeat (5) @(posedge clk);
        if (n_tr != 1 || n_tf != 0) fail("[3] a short Rewind is not ONE Rewind tap");
        clr; @(negedge clk) rew = 1; repeat (120) @(posedge clk);
        if (held_rew !== 1'b1 || held_ff !== 1'b0) fail("[3] not held_rew after T_HOLD");
        @(negedge clk) rew = 0; repeat (3) @(posedge clk);
        if (held_rew !== 1'b0 || n_tr != 0) fail("[3] a Rewind hold tapped or stayed held");

        // [4] both buttons: no tap; a hold drops when the other joins
        clr; @(negedge clk) ff = 1; repeat (10) @(posedge clk); @(negedge clk) rew = 1;
        repeat (10) @(posedge clk); @(negedge clk) begin ff = 0; rew = 0; end repeat (5) @(posedge clk);
        if (n_tf != 0 || n_tr != 0) fail("[4] two buttons tapped");
        clr; @(negedge clk) ff = 1; repeat (120) @(posedge clk);
        if (held_ff !== 1'b1) fail("[4] setup: not held");
        @(negedge clk) rew = 1; repeat (3) @(posedge clk);
        if (held_ff !== 1'b0 || held_rew !== 1'b0) fail("[4] a hold survived the other button joining");
        @(negedge clk) begin ff = 0; rew = 0; end repeat (5) @(posedge clk);
        if (n_tf != 0 || n_tr != 0) fail("[4] the aborted hold tapped at the release");

        // [5] pressed together from idle: not a run at all
        clr; @(negedge clk) begin ff = 1; rew = 1; end repeat (150) @(posedge clk);
        if (held_ff !== 1'b0 || held_rew !== 1'b0) fail("[5] both together held");
        @(negedge clk) begin ff = 0; rew = 0; end repeat (5) @(posedge clk);
        if (n_tf != 0 || n_tr != 0) fail("[5] both together tapped");

        if (errors == 0) $display("PASS: pad_hold_tb -- 5 scenarios");
        else begin $display("FAIL: pad_hold_tb -- %0d error(s)", errors); $fatal(1); end
        $finish;
    end
endmodule
