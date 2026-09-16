// =============================================================================
// bench/dvd/es_stuff_tb.sv -- dvd/es_stuff.sv: zero_byte stuffing at a menu hop
// =============================================================================
// Scoreboard bench: every scenario builds the EXPECTED {mark,byte} sequence on
// the wire from the stimulus alone, and the sink records what actually crossed
// under random backpressure. A wrong count, a wrong order, a lost or duplicated
// byte, a mark on the wrong byte, or a zero run on the wrong side of a byte all
// read as a mismatch. $fatal on any failure (a bench that $finishes on failure
// exits 0 -- the bench/ac3 M17 trap).
//
//   T1  no arm ever            -> bit-exact passthrough (marks included)
//   T2  arm, pipe reset, land  -> exactly N zeros, then the landing, mark on
//                                 the landing's FIRST real byte and not on a zero
//   T3  the ack-cycle window   -> a byte presented between the ack and the
//                                 reset (the OUTGOING cell's last byte) passes
//                                 UN-stuffed, ahead of the run
//   T4  backpressure mid-run   -> out_ready toggling inside the run costs no
//                                 zero and never leaks the held landing byte
//   T5  two hops               -> two runs; an arm DURING a run re-arms
//   T6  arm with no reset      -> nothing is stuffed until a reset is seen
// =============================================================================
`timescale 1ns/1ps
module es_stuff_tb;
    localparam integer N = 16;        // small so the arms are readable; the
                                      // RTL's 128 is a parameter, same logic
    reg clk = 0; always #18.5 clk = ~clk;
    reg rst_n = 0;
    reg arm = 0, pipe_rst_n = 1;
    reg  [7:0] in_byte = 0; reg in_mark = 0; reg in_valid = 0;
    wire in_ready;
    wire [8:0] out_data; wire out_valid; reg out_ready = 1;
    wire stuffing;

    es_stuff #(.N(N)) dut (
        .clk(clk), .rst_n(rst_n), .arm(arm), .pipe_rst_n(pipe_rst_n),
        .in_byte(in_byte), .in_mark(in_mark), .in_valid(in_valid), .in_ready(in_ready),
        .out_data(out_data), .out_valid(out_valid), .out_ready(out_ready),
        .stuffing(stuffing));

    // ---- scoreboard -----------------------------------------------------------
    localparam integer MAXQ = 4096;
    reg [8:0] exp_q [0:MAXQ-1]; integer exp_n = 0;
    reg [8:0] got_q [0:MAXQ-1]; integer got_n = 0;
    integer errors = 0;
    integer rseed = 32'h5EED_0001;
    reg bp_random = 0;               // random out_ready when set

    always @(posedge clk) begin
        if (rst_n && out_valid && out_ready) begin
            if (got_n < MAXQ) got_q[got_n] = out_data;
            got_n = got_n + 1;
        end
        if (bp_random) out_ready <= (($random(rseed) % 4) != 0);
        else           out_ready <= 1'b1;
    end

    task expect_byte(input [8:0] v); begin exp_q[exp_n] = v; exp_n = exp_n + 1; end endtask
    task expect_zeros(input integer n); integer k; begin for (k = 0; k < n; k = k + 1) expect_byte(9'h000); end endtask

    // Present one byte from the "demux" and hold it until accepted. Driven on
    // the NEGEDGE so the stimulus never races the DUT (mode_realign_tb lesson).
    task feed(input [7:0] b, input m); begin
        @(negedge clk); in_byte = b; in_mark = m; in_valid = 1;
        @(posedge clk); while (!(in_valid && in_ready)) @(posedge clk);
        @(negedge clk); in_valid = 0; in_mark = 0;
    end endtask
    task feed_n(input [7:0] b0, input integer n, input mark_first); integer k; begin
        for (k = 0; k < n; k = k + 1) begin
            feed(b0 + k[7:0], (k == 0) && mark_first);
            expect_byte({(k == 0) && mark_first, b0 + k[7:0]});
        end
    end endtask
    task pulse_arm; begin @(negedge clk); arm = 1; @(negedge clk); arm = 0; end endtask
    // the hop's load_flush: ~64 cycles low, the demux presents nothing meanwhile
    task pipe_reset(input integer cycles); begin
        @(negedge clk); pipe_rst_n = 0; repeat (cycles) @(negedge clk); pipe_rst_n = 1;
    end endtask
    task drain; begin repeat (N + 40) @(posedge clk); end endtask

    task check(input [8*32-1:0] name); integer k; begin
        drain;
        if (got_n != exp_n) begin
            $display("  FAIL %0s: %0d bytes crossed, expected %0d", name, got_n, exp_n);
            errors = errors + 1;
        end
        for (k = 0; k < exp_n && k < got_n && k < MAXQ; k = k + 1)
            if (got_q[k] !== exp_q[k]) begin
                if (errors < 8)
                    $display("  FAIL %0s: idx %0d got %03h exp %03h", name, k, got_q[k], exp_q[k]);
                errors = errors + 1;
            end
        if (errors == 0) $display("  %0s: ok (%0d bytes)", name, got_n);
        exp_n = 0; got_n = 0;
    end endtask

    integer t;
    initial begin
        repeat (4) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);

        // ---- T1: no arm, random sink backpressure: bit-exact passthrough -----
        bp_random = 1;
        feed_n(8'h10, 200, 1);
        feed_n(8'h40, 50, 0);
        check("T1 passthrough");

        // ---- T2: arm -> reset -> landing: N zeros, then the landing, mark on
        //          its first real byte
        bp_random = 0;
        pulse_arm; pipe_reset(64);
        expect_zeros(N);
        feed_n(8'hB3, 40, 1);           // landing (first byte carries the PTS mark)
        check("T2 arm/reset/land");
        // ...and the run is one-shot: more bytes flow un-stuffed
        feed_n(8'h20, 20, 0);
        check("T2b one-shot");

        // ---- T3: the ack-cycle window. The OUTGOING cell's byte is presented in
        //          the cycles between the ack and the reset; it must pass first,
        //          un-stuffed. (With XX=0x01 a run in front of it would fabricate
        //          a picture start code out of `01 00 00 01`.)
        //          One byte in the ack cycle, one in the cycle after (armed, no
        //          reset yet): both must cross, in order, before any zero.
        @(negedge clk); arm = 1; in_byte = 8'h01; in_mark = 0; in_valid = 1;
        @(posedge clk); if (!in_ready) begin $display("  FAIL T3: ack-cycle byte held"); errors = errors + 1; end
        @(negedge clk); arm = 0; in_byte = 8'h02;         // ack over; pipe_rst_n still high
        @(posedge clk); if (!in_ready) begin $display("  FAIL T3: post-ack byte held"); errors = errors + 1; end
        @(negedge clk); in_valid = 0;
        expect_byte(9'h001); expect_byte(9'h002);
        pipe_reset(64);
        expect_zeros(N);
        feed_n(8'hB3, 10, 1);
        check("T3 ack-cycle window");

        // ---- T4: backpressure INSIDE the run: still exactly N zeros, the held
        //          landing byte neither lost nor leaked early
        bp_random = 1;
        pulse_arm; pipe_reset(64);
        expect_zeros(N);
        feed_n(8'hB3, 60, 1);
        check("T4 backpressure in run");
        bp_random = 0;

        // ---- T5: two hops back to back, the second armed DURING the first run
        pulse_arm; pipe_reset(64);
        expect_zeros(N);
        @(negedge clk); in_byte = 8'hB3; in_mark = 1; in_valid = 1;   // landing 1 presented
        repeat (3) @(negedge clk);                                     // run in progress
        arm = 1; @(negedge clk); arm = 0;                              // hop 2 acked mid-run
        @(posedge clk); while (!(in_valid && in_ready)) @(posedge clk);
        @(negedge clk); in_valid = 0; in_mark = 0;
        expect_byte(9'h1B3);
        feed_n(8'hC0, 5, 0);
        pipe_reset(64);                                                // hop 2's reset
        expect_zeros(N);
        feed_n(8'hB3, 12, 1);                                          // landing 2
        check("T5 double hop");

        // ---- T6: an arm with NO pipe reset stuffs nothing
        pulse_arm;
        feed_n(8'h30, 30, 0);
        check("T6 arm without reset");
        pipe_reset(64);                                                // now it lands
        expect_zeros(N);
        feed_n(8'hB3, 4, 1);
        check("T6b then the reset arrives");

        if (errors) begin $display("FAIL: %0d errors", errors); $fatal(1); end
        $display("PASS: es_stuff_tb");
        $finish;
    end
    initial begin #4_000_000; $display("FAIL: watchdog"); $fatal(1); end
endmodule
