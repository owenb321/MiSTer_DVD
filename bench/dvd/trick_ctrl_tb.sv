// trick_ctrl_tb.sv -- dvd/trick_ctrl.sv, every gesture (bench/dvd/run_trick_ctrl.sh).
// Time-compressed: GO_PERIOD 10, T1/T2/T3 100/200/300 clocks.
`timescale 1ns/1ps
module trick_ctrl_tb;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0;
    reg held_ff = 0, held_rew = 0, allowed = 1, trick_vobu = 0, trick_edge = 0;
    reg shown = 0, skipped = 0, flush = 0;
    wire tail, shown_ovf;
    reg [31:0] cur_rbn = 32'd5000, trick_nav = 0;
    wire active, rev, go, seek_pulse;
    wire [1:0] tier;
    wire [31:0] seek_rbn;
    wire [15:0] n_entries;
    wire owns;

    trick_ctrl #(.GO_PERIOD(10), .T1(100), .T2(200), .T3(300), .TAIL_MAX(50)) dut (
        .clk(clk), .rst_n(rst_n),
        .held_ff(held_ff), .held_rew(held_rew), .allowed(allowed), .cur_rbn(cur_rbn),
        .trick_vobu(trick_vobu), .trick_nav(trick_nav), .trick_edge(trick_edge),
        .shown(shown), .skipped(skipped), .flush(flush),
        .tail(tail), .shown_ovf(shown_ovf),
        .active(active), .tier(tier), .rev(rev), .go(go),
        .seek_pulse(seek_pulse), .seek_rbn(seek_rbn), .n_entries(n_entries), .owns(owns));

    integer errors = 0, n_seek = 0, n_go = 0, i;
    reg [31:0] last_seek = 0;
    reg        active_at_seek = 0;
    always @(posedge clk) begin
        if (seek_pulse) begin n_seek = n_seek + 1; last_seek = seek_rbn; end
        if (go) n_go = n_go + 1;
    end

    task fail(input [8*80-1:0] m); begin errors = errors + 1; $display("FAIL %0s", m); end endtask
    task arm(input [31:0] nav); begin
        @(negedge clk) trick_nav = nav; trick_vobu = 1;
        @(negedge clk) trick_vobu = 0;
    end endtask
    task show; begin
        @(negedge clk) shown = 1;
        @(negedge clk) shown = 0;
    end endtask
    task idle_check; begin
        repeat (3) @(posedge clk);
        if (active) fail("still active after the exit");
    end endtask

    initial begin
        repeat (3) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

        // [1] press FF: ONE entry seek to the playhead, active, forward, tier 0
        n_seek = 0;
        @(negedge clk) held_ff = 1;
        repeat (3) @(posedge clk);
        if (!active || rev || tier != 0) fail("[1] FF did not enter forward at tier 0");
        if (n_seek != 1 || last_seek != 32'd5000) fail("[1] no single entry seek to the playhead");
        // [2] go every GO_PERIOD while held
        n_go = 0; repeat (100) @(posedge clk);
        if (n_go < 9 || n_go > 11) begin fail("[2] go pulses not every GO_PERIOD"); $display("  n_go %0d", n_go); end
        // [3] the tiers ramp with hold time
        repeat (60) @(posedge clk);  if (tier != 1) fail("[3] not 8x after T1");
        repeat (100) @(posedge clk); if (tier != 2) fail("[3] not 40x after T2");
        repeat (100) @(posedge clk); if (tier != 3) fail("[3] not 120x after T3");
        // [4] 3 armed, 2 shown: the exit seeks to the LAST SHOWN (200), inactive in
        //     the same cycle as the seek
        arm(100); arm(200); arm(300); show; show;
        n_seek = 0;
        @(negedge clk) held_ff = 0;
        @(posedge clk); #1;
        if (!seek_pulse || active) fail("[4] the exit seek and active-low are not in the same cycle");
        if (seek_rbn != 32'd200) begin fail("[4] exit not to the VOBU on screen"); $display("  seek %0d", seek_rbn); end
        idle_check;
        if (n_seek != 1) fail("[4] not exactly one exit seek");

        // [5] REW, one VOBU armed, release: exit to that VOBU, backwards
        @(negedge clk) held_rew = 1;
        repeat (3) @(posedge clk);
        if (!active || !rev) fail("[5] REW did not enter backwards");
        arm(777); show;
        n_seek = 0;
        @(negedge clk) held_rew = 0;
        repeat (2) @(posedge clk);
        if (n_seek != 1 || last_seek != 32'd777) fail("[5] exit after one arm not to it");
        idle_check;

        // [6] nothing armed: exit back to the entry point
        cur_rbn = 32'd4242;
        @(negedge clk) held_ff = 1; repeat (3) @(posedge clk);
        n_seek = 0;
        @(negedge clk) held_ff = 0; repeat (2) @(posedge clk);
        if (n_seek != 1 || last_seek != 32'd4242) fail("[6] exit with nothing armed not to the entry point");
        idle_check;

        // [7] the PGC's edge: exit to the edge VOBU (the latest armed)
        @(negedge clk) held_rew = 1; repeat (3) @(posedge clk);
        arm(50); arm(10);
        n_seek = 0;
        @(negedge clk) trick_edge = 1; repeat (2) @(posedge clk); trick_edge = 0;
        if (n_seek != 1 || last_seek != 32'd10) fail("[7] the edge did not exit to the edge VOBU");
        if (active) fail("[7] still active at the edge");
        repeat (20) @(posedge clk);
        if (!owns) fail("[7] the gesture not owned while the button is still held after the exit");
        @(negedge clk) held_rew = 0; repeat (20) @(posedge clk);
        if (n_seek != 1) fail("[7] releasing after the edge seeked again");
        if (owns) fail("[7] the gesture still owned after the release");

        // [8] not allowed: a press does nothing; allowed falling mid-run exits
        allowed = 0; n_seek = 0;
        @(negedge clk) held_ff = 1; repeat (20) @(posedge clk);
        if (active || n_seek != 0) fail("[8] entered while not allowed");
        @(negedge clk) held_ff = 0; allowed = 1; repeat (2) @(posedge clk);
        @(negedge clk) held_ff = 1; repeat (5) @(posedge clk);
        n_seek = 0;
        @(negedge clk) allowed = 0; repeat (2) @(posedge clk);
        if (active || n_seek != 1) fail("[8] allowed falling did not exit with one seek");
        @(negedge clk) held_ff = 0; allowed = 1; repeat (5) @(posedge clk);

        // [9] both held: not a gesture; the other button mid-run exits
        n_seek = 0;
        @(negedge clk) begin held_ff = 1; held_rew = 1; end repeat (20) @(posedge clk);
        if (active || n_seek != 0) fail("[9] both buttons entered");
        @(negedge clk) begin held_ff = 0; held_rew = 0; end repeat (2) @(posedge clk);
        @(negedge clk) held_ff = 1; repeat (5) @(posedge clk);
        n_seek = 0;
        @(negedge clk) held_rew = 1; repeat (2) @(posedge clk);
        if (active || n_seek != 1) fail("[9] the other button did not exit");
        @(negedge clk) begin held_ff = 0; held_rew = 0; end repeat (5) @(posedge clk);

        // [10] the edge in the SAME clock as its VOBU's arm (the reader raises both
        //      together): exit to THAT VOBU, not the one before (TFA rewind, 2026-11-24)
        @(negedge clk) held_rew = 1; repeat (3) @(posedge clk);
        arm(1339);
        n_seek = 0;
        @(negedge clk) begin trick_nav = 0; trick_vobu = 1; trick_edge = 1; end
        @(negedge clk) begin trick_vobu = 0; trick_edge = 0; end
        repeat (2) @(posedge clk);
        if (n_seek != 1 || last_seek != 32'd0) begin
            fail("[10] an edge with its own arm exited to the previous VOBU"); $display("  seek %0d", last_seek); end
        @(negedge clk) held_rew = 0; repeat (5) @(posedge clk);

        // [11] the one-ahead fallback (a lost queue, [16]) with a release in the same
        //      clock as an arm: that arm is the latest, so the exit goes to the one
        //      before it
        @(negedge clk) held_ff = 1; repeat (3) @(posedge clk);
        arm(400); arm(500);
        @(negedge clk) skipped = 1; @(negedge clk) skipped = 0;
        n_seek = 0;
        @(negedge clk) begin trick_nav = 600; trick_vobu = 1; held_ff = 0; end
        @(negedge clk) trick_vobu = 0;
        repeat (2) @(posedge clk);
        if (n_seek != 1 || last_seek != 32'd500) begin
            fail("[11] a release on an arm's clock did not exit to the VOBU before it"); $display("  seek %0d", last_seek); end
        repeat (5) @(posedge clk);

        // [12] the reader TWO ahead of the screen (the rig, The Matrix at 120x,
        //      2026-11-27): 3 armed, 1 shown -> the exit goes to the one shown (100),
        //      not one before the latest (200)
        @(negedge clk) held_ff = 1; repeat (3) @(posedge clk);
        arm(100); arm(200); arm(300); show;
        n_seek = 0;
        @(negedge clk) held_ff = 0; repeat (2) @(posedge clk);
        if (n_seek != 1 || last_seek != 32'd100) begin
            fail("[12] two ahead: the exit did not land on the picture shown"); $display("  seek %0d", last_seek); end
        repeat (5) @(posedge clk);

        // [13] armed but nothing shown yet: the screen still holds the picture from
        //      before the entry -> back to the entry point
        cur_rbn = 32'd9000;
        @(negedge clk) held_ff = 1; repeat (3) @(posedge clk);
        arm(9100); arm(9200);
        n_seek = 0;
        @(negedge clk) held_ff = 0; repeat (2) @(posedge clk);
        if (n_seek != 1 || last_seek != 32'd9000) begin
            fail("[13] nothing shown: the exit did not return to the entry point"); $display("  seek %0d", last_seek); end
        repeat (5) @(posedge clk);

        // [14] a picture shown on the release's own clock is the one on screen;
        //      pickups before the entry (or after the exit) touch nothing
        show; show;                                    // outside a session: ignored
        @(negedge clk) held_ff = 1; repeat (3) @(posedge clk);
        arm(700); arm(800); show;
        n_seek = 0;
        @(negedge clk) begin shown = 1; held_ff = 0; end
        @(negedge clk) shown = 0;
        repeat (2) @(posedge clk);
        if (n_seek != 1 || last_seek != 32'd800) begin
            fail("[14] a pickup on the release's clock was not counted"); $display("  seek %0d", last_seek); end
        repeat (5) @(posedge clk);

        // [15] the tail: up at the exit seek, down at the flush; not up at an entry;
        //      and TAIL_MAX ends it when no flush comes
        @(negedge clk) held_ff = 1; repeat (3) @(posedge clk);
        if (tail) fail("[15] tail up at an entry");
        @(negedge clk) held_ff = 0; @(posedge clk); #1;
        if (!seek_pulse || !tail) fail("[15] tail not up in the exit seek's cycle");
        repeat (10) @(posedge clk);
        if (!tail) fail("[15] tail dropped before the flush");
        @(negedge clk) flush = 1; @(negedge clk) flush = 0;
        @(posedge clk); #1;
        if (tail) fail("[15] tail still up after the flush");
        @(negedge clk) held_ff = 1; repeat (3) @(posedge clk);
        @(negedge clk) held_ff = 0; repeat (40) @(posedge clk);
        if (!tail) fail("[15] tail timed out too early");
        repeat (20) @(posedge clk);
        if (tail) fail("[15] tail not ended by TAIL_MAX without a flush");

        // [16] an overflowing queue, or a filter skip, is not trusted: shown_ovf
        //      and the old one-ahead rule
        @(negedge clk) held_ff = 1; repeat (3) @(posedge clk);
        arm(1); arm(2); arm(3); arm(4); arm(5);
        if (!shown_ovf) fail("[16] 5 arms, no picture: no overflow flag");
        n_seek = 0;
        @(negedge clk) held_ff = 0; repeat (2) @(posedge clk);
        if (n_seek != 1 || last_seek != 32'd4) begin
            fail("[16] overflow: the exit did not fall back to one-ahead"); $display("  seek %0d", last_seek); end
        repeat (5) @(posedge clk);
        @(negedge clk) held_ff = 1; repeat (3) @(posedge clk);
        if (shown_ovf) fail("[16] shown_ovf not cleared at the next entry");
        arm(11); arm(12); arm(13); show;
        @(negedge clk) skipped = 1; @(negedge clk) skipped = 0;
        @(posedge clk); #1;
        if (!shown_ovf) fail("[16] a filter skip did not mark the queue lost");
        n_seek = 0;
        @(negedge clk) held_ff = 0; repeat (2) @(posedge clk);
        if (n_seek != 1 || last_seek != 32'd12) begin
            fail("[16] skip: the exit did not fall back to one-ahead"); $display("  seek %0d", last_seek); end
        repeat (5) @(posedge clk);

        if (n_entries == 0) fail("n_entries never counted");
        if (errors == 0) $display("PASS: trick_ctrl_tb -- 16 scenarios");
        else begin $display("FAIL: trick_ctrl_tb -- %0d error(s)", errors); $fatal(1); end
        $finish;
    end
endmodule
