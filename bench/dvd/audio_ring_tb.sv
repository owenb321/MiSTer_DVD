// audio_ring_tb.sv — testbench for dvd/audio_ring.sv
//
// Covers the three behaviours the audio ring must guarantee:
//   1. Two well-formed frames: bytes come out in order and the per-frame
//      descriptor FIFO reports the right {length, type} for each, in order.
//      (Length is deferred: frame N finalizes when frame N+1 starts, so a
//      trailing start pulse is used to finalize the last checked frame.)
//   2. Overflow / drop-on-full: a frame larger than the byte buffer is dropped
//      whole, overflow_count increments, and a following small frame still
//      passes intact.
//   3. Invariant: aud_ready stays HIGH for the entire run on both instances —
//      audio must never be able to backpressure (stall) the shared video path.
//
//   iverilog -g2012 -o bench/dvd/audio_ring_sim dvd/audio_ring.sv bench/dvd/audio_ring_tb.sv
//   vvp bench/dvd/audio_ring_sim

`timescale 1ns/1ps
`default_nettype none

module audio_ring_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    int errors = 0;

    // ---- DUT A: roomy ring for the ordering test (cases 1 & 3) ----
    logic  [7:0] a_byte;  logic a_valid, a_fs; logic [1:0] a_type; logic a_ready;
    logic  [7:0] a_out_byte; logic a_out_valid, a_out_ready;
    logic        a_frame_valid; logic [15:0] a_frame_len; logic [1:0] a_frame_type; logic a_frame_pop;
    logic [15:0] a_frames_avail, a_bytes_avail, a_ovf;
    logic [32:0] a_fpts = 0; logic a_fpts_v = 0;          // per-frame PTS feed
    wire  [32:0] a_frame_pts; wire a_frame_pts_v;          // read-side PTS

    audio_ring #(.BYTE_DEPTH(64), .FRAME_DEPTH(8)) dut_a (
        .clk(clk), .rst_n(rst_n),
        .aud_byte(a_byte), .aud_valid(a_valid), .aud_type(a_type),
        .aud_frame_start(a_fs), .drop_pulse(1'b0),
        .aud_frame_pts(a_fpts), .aud_frame_pts_valid(a_fpts_v), .aud_ready(a_ready),
        .out_byte(a_out_byte), .out_valid(a_out_valid), .out_ready(a_out_ready),
        .frame_valid(a_frame_valid), .frame_len(a_frame_len),
        .frame_type(a_frame_type),
        .frame_pts(a_frame_pts), .frame_pts_valid(a_frame_pts_v), .frame_pop(a_frame_pop),
        .frames_available(a_frames_avail), .bytes_available(a_bytes_avail),
        .overflow_count(a_ovf)
    );

    // ---- DUT B: tiny ring for the overflow test (case 2) ----
    logic  [7:0] b_byte;  logic b_valid, b_fs; logic [1:0] b_type; logic b_ready;
    logic  [7:0] b_out_byte; logic b_out_valid, b_out_ready;
    logic        b_frame_valid; logic [15:0] b_frame_len; logic [1:0] b_frame_type; logic b_frame_pop;
    logic [15:0] b_frames_avail, b_bytes_avail, b_ovf;

    audio_ring #(.BYTE_DEPTH(8), .FRAME_DEPTH(4)) dut_b (
        .clk(clk), .rst_n(rst_n),
        .aud_byte(b_byte), .aud_valid(b_valid), .aud_type(b_type),
        .aud_frame_start(b_fs), .drop_pulse(1'b0),
        .aud_frame_pts(33'd0), .aud_frame_pts_valid(1'b0), .aud_ready(b_ready),
        .out_byte(b_out_byte), .out_valid(b_out_valid), .out_ready(b_out_ready),
        .frame_valid(b_frame_valid), .frame_len(b_frame_len),
        .frame_type(b_frame_type),
        .frame_pts(), .frame_pts_valid(), .frame_pop(b_frame_pop),
        .frames_available(b_frames_avail), .bytes_available(b_bytes_avail),
        .overflow_count(b_ovf)
    );

    // ---- case 3: continuous invariant check ----
    always @(posedge clk) if (rst_n) begin
        if (a_ready !== 1'b1) begin
            $display("FAIL: dut_a aud_ready dropped low (backpressure into video)"); errors++;
        end
        if (b_ready !== 1'b1) begin
            $display("FAIL: dut_b aud_ready dropped low (backpressure into video)"); errors++;
        end
    end

    // ---- write-side helpers ----
    task feed_a(input [7:0] d, input first, input [1:0] t);
        begin
            @(negedge clk); a_byte = d; a_valid = 1; a_fs = first; a_type = t;
            @(posedge clk);
            @(negedge clk); a_valid = 0; a_fs = 0;
        end
    endtask
    task feed_b(input [7:0] d, input first, input [1:0] t);
        begin
            @(negedge clk); b_byte = d; b_valid = 1; b_fs = first; b_type = t;
            @(posedge clk);
            @(negedge clk); b_valid = 0; b_fs = 0;
        end
    endtask

    // ---- read-side helpers (FWFT: sample head, then pop on the edge) ----
    task pop_byte_a(output [7:0] b);
        begin
            @(negedge clk);
            if (!a_out_valid) begin $display("FAIL: dut_a byte pop while empty"); errors++; end
            b = a_out_byte; a_out_ready = 1;
            @(posedge clk);
            @(negedge clk); a_out_ready = 0;
        end
    endtask
    task pop_byte_b(output [7:0] b);
        begin
            @(negedge clk);
            if (!b_out_valid) begin $display("FAIL: dut_b byte pop while empty"); errors++; end
            b = b_out_byte; b_out_ready = 1;
            @(posedge clk);
            @(negedge clk); b_out_ready = 0;
        end
    endtask
    task pop_frame_a(output [15:0] len, output [1:0] typ);
        begin
            @(negedge clk);
            if (!a_frame_valid) begin $display("FAIL: dut_a frame pop while empty"); errors++; end
            len = a_frame_len; typ = a_frame_type; a_frame_pop = 1;
            @(posedge clk);
            @(negedge clk); a_frame_pop = 0;
        end
    endtask
    task pop_frame_b(output [15:0] len, output [1:0] typ);
        begin
            @(negedge clk);
            if (!b_frame_valid) begin $display("FAIL: dut_b frame pop while empty"); errors++; end
            len = b_frame_len; typ = b_frame_type; b_frame_pop = 1;
            @(posedge clk);
            @(negedge clk); b_frame_pop = 0;
        end
    endtask

    task chk(input [31:0] got, input [31:0] exp, input [255:0] what);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s — got %0d expected %0d", what, got, exp); errors++;
            end
        end
    endtask

    logic [7:0]  bb;
    logic [15:0] flen;
    logic [1:0]  ftyp;
    int          i;

    initial begin
        a_byte=0; a_valid=0; a_fs=0; a_type=0; a_out_ready=0; a_frame_pop=0;
        b_byte=0; b_valid=0; b_fs=0; b_type=0; b_out_ready=0; b_frame_pop=0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // =========================================================
        // Case 1 (dut_a): two well-formed frames
        //   F1: AC3 (type 0), 4 bytes A0..A3
        //   F2: DTS (type 1), 5 bytes B0..B4
        //   F3 start (type 2) finalizes F2 (length-deferred)
        // =========================================================
        feed_a(8'hA0, 1, 2'd0); feed_a(8'hA1, 0, 2'd0);
        feed_a(8'hA2, 0, 2'd0); feed_a(8'hA3, 0, 2'd0);
        feed_a(8'hB0, 1, 2'd1); feed_a(8'hB1, 0, 2'd1); feed_a(8'hB2, 0, 2'd1);
        feed_a(8'hB3, 0, 2'd1); feed_a(8'hB4, 0, 2'd1);
        feed_a(8'hC0, 1, 2'd2);   // starts F3 → finalizes F2

        repeat (2) @(posedge clk);
        chk(a_frames_avail, 2, "case1 frames_available");
        chk(a_bytes_avail,  9, "case1 bytes_available (4+5)");

        pop_frame_a(flen, ftyp);
        chk(flen, 4, "case1 F1 len"); chk(ftyp, 0, "case1 F1 type");
        for (i = 0; i < 4; i++) begin
            pop_byte_a(bb); chk(bb, 8'hA0 + i, "case1 F1 byte");
        end
        pop_frame_a(flen, ftyp);
        chk(flen, 5, "case1 F2 len"); chk(ftyp, 1, "case1 F2 type");
        for (i = 0; i < 5; i++) begin
            pop_byte_a(bb); chk(bb, 8'hB0 + i, "case1 F2 byte");
        end
        chk(a_frames_avail, 0, "case1 frames drained");

        // =========================================================
        // Case 2 (dut_b, BYTE_DEPTH=8): overflow / drop-on-full
        //   G1: 12 bytes (> 8) → dropped whole, overflow_count = 1
        //   G2: 3 bytes D0..D2 (type 2) → passes intact
        //   G3 start finalizes G2
        // =========================================================
        feed_b(8'h00, 1, 2'd0);                       // G1 first byte
        for (i = 1; i < 12; i++) feed_b(8'h00 + i, 0, 2'd0);
        feed_b(8'hD0, 1, 2'd2);                       // G2 start → drops G1
        feed_b(8'hD1, 0, 2'd2); feed_b(8'hD2, 0, 2'd2);
        feed_b(8'hE0, 1, 2'd0);                       // G3 start → finalizes G2

        repeat (2) @(posedge clk);
        chk(b_ovf,          1, "case2 overflow_count (G1 dropped)");
        chk(b_frames_avail, 1, "case2 frames_available (only G2)");

        pop_frame_b(flen, ftyp);
        chk(flen, 3, "case2 G2 len"); chk(ftyp, 2, "case2 G2 type");
        for (i = 0; i < 3; i++) begin
            pop_byte_b(bb); chk(bb, 8'hD0 + i, "case2 G2 byte");
        end

        // =========================================================
        // Case 4 (dut_a): per-frame PTS round-trips through the descriptor.
        //   H1: PTS=111111 (valid), 3 bytes; H2: PTS=222222 (valid), 2 bytes;
        //   H3 start (no PTS) finalizes H2. Check frame_pts/_valid on pop.
        // =========================================================
        a_fpts = 33'd111111; a_fpts_v = 1; feed_a(8'hF0, 1, 2'd0);
        a_fpts_v = 0;                        feed_a(8'hF1, 0, 2'd0);
                                             feed_a(8'hF2, 0, 2'd0);
        a_fpts = 33'd222222; a_fpts_v = 1; feed_a(8'hF3, 1, 2'd0);   // finalizes H1
        a_fpts_v = 0;                        feed_a(8'hF4, 0, 2'd0);
        a_fpts = 33'd0;      a_fpts_v = 0; feed_a(8'hF5, 1, 2'd2);   // finalizes H2

        repeat (2) @(posedge clk);
        // Case 1 left frame F3 (the lone C0 byte) open; H1's start finalized it,
        // so it is now the oldest committed frame. Drain it before checking H1/H2.
        chk(a_frames_avail, 3, "case4 frames_available (F3 + H1 + H2)");
        pop_frame_a(flen, ftyp); chk(flen, 1, "case4 stray-F3 len"); pop_byte_a(bb);
        @(negedge clk);
        chk(a_frame_pts,   111111, "case4 H1 frame_pts");
        chk(a_frame_pts_v, 1,      "case4 H1 frame_pts_valid");
        pop_frame_a(flen, ftyp); chk(flen, 3, "case4 H1 len");
        for (i = 0; i < 3; i++) pop_byte_a(bb);
        @(negedge clk);
        chk(a_frame_pts,   222222, "case4 H2 frame_pts");
        chk(a_frame_pts_v, 1,      "case4 H2 frame_pts_valid");
        pop_frame_a(flen, ftyp); chk(flen, 2, "case4 H2 len");

        // =========================================================
        // Case 5 (dut_a): pop-immediately-after-commit race.
        //   Case 4 left H2's 2 payload bytes undrained and frame F5 (lone byte
        //   0xF5, type 2) still OPEN. Drain those leftovers, then commit ONE new
        //   frame into the now-empty descriptor ring and POLL for frame_valid with
        //   no settling delay — this exercises the FWFT head-register refill
        //   latency (head loads 1 cycle after the commit lands; the M10K read
        //   never races its own write). The head must present the right descriptor
        //   and payload.
        chk(a_frames_avail, 0, "case5 no committed frames at start");
        pop_byte_a(bb); chk(bb, 8'hF3, "case5 drain H2 leftover byte0");
        pop_byte_a(bb); chk(bb, 8'hF4, "case5 drain H2 leftover byte1");

        a_fpts = 33'd333333; a_fpts_v = 1; feed_a(8'h5A, 1, 2'd1);  // I1 start → finalizes stray F5
        a_fpts_v = 0;                        feed_a(8'h5B, 0, 2'd1);
        a_fpts = 33'd0;      a_fpts_v = 0; feed_a(8'h60, 1, 2'd0);  // I2 start → finalizes I1

        // Drain the stray F5 (oldest committed: len 1, type 2, the 0xF5 byte).
        @(negedge clk);
        while (!a_frame_valid) @(negedge clk);
        pop_frame_a(flen, ftyp); chk(flen, 1, "case5 stray-F5 len"); chk(ftyp, 2, "case5 stray-F5 type");
        pop_byte_a(bb); chk(bb, 8'hF5, "case5 stray-F5 byte");

        // Now I1 is the head — poll (not a fixed wait) so head-load latency gates us.
        @(negedge clk);
        while (!a_frame_valid) @(negedge clk);
        chk(a_frame_pts,   333333, "case5 I1 frame_pts");
        chk(a_frame_pts_v, 1,      "case5 I1 frame_pts_valid");
        pop_frame_a(flen, ftyp);
        chk(flen, 2, "case5 I1 len"); chk(ftyp, 1, "case5 I1 type");
        pop_byte_a(bb); chk(bb, 8'h5A, "case5 I1 byte0");
        pop_byte_a(bb); chk(bb, 8'h5B, "case5 I1 byte1");

        repeat (2) @(posedge clk);
        if (errors == 0) $display("PASS: audio_ring all cases OK");
        else             $display("FAIL: audio_ring %0d error(s)", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: timeout"); $finish;
    end
endmodule

`default_nettype wire
