// aud_drain_tb.sv - unit arms for dvd/aud_drain.sv (the audio half of the
// reader's natural-transition gate). The chain bench
// (iso_reader_auddrain_tb) measures what the listener hears; this one pins the
// terms that bench cannot reach on its own - chiefly dec_holding, which the
// chain ties low.
//
//   [U1] committed frames queued        -> not drained
//   [U2] ring empties                   -> drained exactly SETTLE cycles later
//   [U3] decoder holding a due frame    -> not drained, however long
//   [U4] a frame arrives mid-settle     -> the settle restarts
//   [U5] no live consumer               -> drained at once, frames or not
`timescale 1ns/1ps
module aud_drain_tb;
    localparam integer SETTLE = 50;
    reg         clk = 0, rst_n = 0;
    reg  [15:0] frames = 0;
    reg         alive = 1, holding = 0;
    wire        drained;
    always #5 clk = ~clk;

    aud_drain #(.SETTLE(SETTLE)) dut (
        .clk(clk), .rst_n(rst_n), .frames_avail(frames),
        .consumer_alive(alive), .dec_holding(holding), .drained(drained)
    );

    integer errors = 0, t;
    // 80 chars: a narrower vector truncates the LEADING [Un] tag, and the
    // runner scores mutations by that tag (measured: M5 read "none").
    task fail(input [639:0] m); begin $display("FAIL: %0s", m); errors = errors + 1; end endtask
    // cycles until drained rises, capped
    task time_to_drained(input integer cap, output integer n);
        begin n = 0; while (!drained && n < cap) begin @(negedge clk); n = n + 1; end end
    endtask

    initial begin
        repeat (3) @(negedge clk); rst_n = 1;

        frames = 5; repeat (4*SETTLE) @(negedge clk);
        if (drained) fail("[U1] drained with committed frames queued");
        else $display("   [U1] frames queued -> held  ok");

        frames = 0; time_to_drained(10*SETTLE, t);
        if (t < SETTLE || t > SETTLE + 2) begin
            $display("   [U2] drained after %0d cycles, SETTLE %0d", t, SETTLE); fail("[U2] settle wrong");
        end else $display("   [U2] drained %0d cycles after the ring emptied  ok", t);

        holding = 1; @(negedge clk); repeat (10*SETTLE) @(negedge clk);
        if (drained) fail("[U3] drained while the decoder holds a due frame");
        else $display("   [U3] decoder holding -> held  ok");
        holding = 0;

        repeat (SETTLE/2) @(negedge clk);
        frames = 1; @(negedge clk); frames = 0;
        time_to_drained(10*SETTLE, t);
        if (t < SETTLE) begin
            $display("   [U4] drained %0d cycles after a mid-settle frame", t); fail("[U4] settle did not restart");
        end else $display("   [U4] a mid-settle frame restarted the settle (%0d)  ok", t);

        frames = 9; holding = 1; alive = 0; @(negedge clk); #1;
        if (!drained) fail("[U5] a dead consumer still held the gate");
        else $display("   [U5] no live consumer -> drained at once  ok");

        if (errors == 0) $display("RESULT: PASS");
        else begin $display("RESULT: FAIL (%0d)", errors); $fatal(1, "aud_drain_tb failed"); end
        $finish;
    end
endmodule
