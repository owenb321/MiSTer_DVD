// kbd_hold_tb.sv -- dvd/kbd_hold.sv: tap vs hold for keyboard / remote FF/REW
// (bench/dvd/run_kbd_hold.sh). Time-compressed: BRIDGE 20, T_HOLD 40, MAX_DOWN 500.
`timescale 1ns/1ps
module kbd_hold_tb;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0, press = 0, release_ = 0;
    wire tap, held;
    kbd_hold #(.BRIDGE(20), .T_HOLD(40), .MAX_DOWN(500)) dut (
        .clk(clk), .rst_n(rst_n), .press(press), .release_(release_), .tap(tap), .held(held));

    integer taps = 0, held_rises = 0, held_falls = 0, errors = 0, i;
    reg held_q = 0;
    always @(posedge clk) begin
        if (tap) taps = taps + 1;
        if (held && !held_q) held_rises = held_rises + 1;
        if (!held && held_q) held_falls = held_falls + 1;
        held_q <= held;
    end
    task pulse_press;   begin @(negedge clk) press = 1;    @(negedge clk) press = 0;    end endtask
    task pulse_release; begin @(negedge clk) release_ = 1; @(negedge clk) release_ = 0; end endtask
    task reset_counts;  begin taps = 0; held_rises = 0; held_falls = 0; end endtask
    task fail(input [8*72-1:0] m); begin errors = errors + 1; $display("FAIL %0s", m); end endtask

    initial begin
        repeat (3) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);

        // [1] a tap: down 10, up -> one tap, no hold
        reset_counts;
        pulse_press; repeat (10) @(posedge clk); pulse_release; repeat (60) @(posedge clk);
        if (taps != 1 || held_rises != 0) fail("[1] a tap was not exactly one tap");

        // [2] a keyboard hold: down 100 -> held from ~40 until BRIDGE after the release, no tap
        reset_counts;
        pulse_press; repeat (45) @(posedge clk);
        if (!held) fail("[2] not held after T_HOLD");
        repeat (55) @(posedge clk); pulse_release; repeat (10) @(posedge clk);
        if (!held) fail("[2] held dropped inside the bridge");
        repeat (30) @(posedge clk);
        if (held || taps != 0 || held_rises != 1) fail("[2] a hold ended wrongly (tap, or still held)");

        // [3] an IR remote's held button: down 8, up 3, repeated -> ONE continuous hold
        reset_counts;
        for (i = 0; i < 12; i = i + 1) begin
            pulse_press; repeat (8) @(posedge clk); pulse_release; repeat (3) @(posedge clk);
        end
        if (!held) fail("[3] a tap stream was not bridged into a hold");
        repeat (40) @(posedge clk);
        if (held || held_rises != 1 || held_falls != 1 || taps != 0)
            fail("[3] the tap stream was not one hold (flickered, or tapped)");

        // [4] two taps further apart than BRIDGE: two taps
        reset_counts;
        pulse_press; repeat (5) @(posedge clk); pulse_release; repeat (40) @(posedge clk);
        pulse_press; repeat (5) @(posedge clk); pulse_release; repeat (40) @(posedge clk);
        if (taps != 2 || held_rises != 0) fail("[4] two separate taps were not two taps");

        // [5] a lost release: held, then let go after MAX_DOWN by itself
        reset_counts;
        pulse_press; repeat (100) @(posedge clk);
        if (!held) fail("[5] not held");
        repeat (450) @(posedge clk);
        if (held) fail("[5] a lost release held past MAX_DOWN");
        if (taps != 0) fail("[5] a lost release tapped");

        if (errors == 0) $display("PASS: kbd_hold_tb -- 5 scenarios");
        else begin $display("FAIL: kbd_hold_tb -- %0d error(s)", errors); $fatal(1); end
        $finish;
    end
endmodule
