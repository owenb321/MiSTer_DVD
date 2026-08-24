// mp2_reframer_tb.sv — MP2 frame-boundary regeneration tests
//
//   T1: two back-to-back 48 kHz/224 kbps frames with only a PES-granular
//       frame_start on byte 0 -> out_frame_start regenerated at BOTH frame
//       boundaries (offset 0 and 672); byte stream byte-identical (1-byte lag).
//   T2: a fake in-payload sync pattern (FF FD) inside frame 1 does NOT create
//       a boundary (frame-length lock closed).
//   T3: PES PTS attaches to the NEXT regenerated frame_start only.
//   T4: foreign type (AC-3, type 0) passes its PES frame_start through
//       unchanged and never triggers MP2 sync logic.
//   T5: padding bit -> frame_len+1 (boundary at 673, not 672).
//
// Run:
//   iverilog -g2012 -o bench/dvd/mp2_reframer_sim dvd/mp2_reframer.sv bench/dvd/mp2_reframer_tb.sv
//   vvp bench/dvd/mp2_reframer_sim

`timescale 1ns/1ps
`default_nettype none

module mp2_reframer_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0;

    logic [7:0]  in_byte;
    logic        in_valid = 0;
    logic [1:0]  in_type = 2'd3;
    logic        in_frame_start = 0;
    logic [32:0] in_frame_pts = '0;
    logic        in_frame_pts_valid = 0;

    wire [7:0]  out_byte;
    wire        out_valid;
    wire [1:0]  out_type;
    wire        out_frame_start;
    wire [32:0] out_frame_pts;
    wire        out_frame_pts_valid;

    mp2_reframer dut (.*);

    int errs = 0;
    task check(input bit cond, input string msg);
        if (!cond) begin errs++; $display("FAIL: %s", msg); end
    endtask

    // Output capture
    byte cap[$];
    int  starts[$];
    logic [32:0] pts_q[$];
    logic        ptsv_q[$];
    always @(posedge clk) begin
        if (out_valid) begin
            if (out_frame_start) begin
                starts.push_back(cap.size());
                pts_q.push_back(out_frame_pts);
                ptsv_q.push_back(out_frame_pts_valid);
            end
            cap.push_back(out_byte);
        end
    end

    // Frame constants: 48 kHz (fs=01), 224 kbps (bidx=11) -> 672 bytes, no pad.
    localparam int FLEN = 672;
    localparam byte H0 = 8'hFF, H1 = 8'hFD, H2 = 8'hB4;   // {1011,01,0,0}
    localparam byte H2P = 8'hB6;                          // padding bit set

    task feed(input byte b, input bit fstart, input bit ptsv, input logic [32:0] pts);
        begin
            in_byte            <= b;
            in_valid           <= 1'b1;
            in_frame_start     <= fstart;
            in_frame_pts       <= pts;
            in_frame_pts_valid <= ptsv;
            @(posedge clk);
            in_valid           <= 1'b0;
            in_frame_start     <= 1'b0;
            in_frame_pts_valid <= 1'b0;
        end
    endtask

    // Feed one whole frame; PES start/PTS only on the first byte if flagged.
    task feed_frame(input byte h2, input bit pes_start, input bit ptsv,
                    input logic [32:0] pts, input bit fake_sync);
        int flen;
        begin
            flen = FLEN + ((h2 == H2P) ? 1 : 0);
            feed(H0, pes_start, ptsv, pts);
            feed(H1, 1'b0, 1'b0, '0);
            feed(h2, 1'b0, 1'b0, '0);
            for (int i = 3; i < flen; i++) begin
                if (fake_sync && i == 100)      feed(8'hFF, 1'b0, 1'b0, '0);
                else if (fake_sync && i == 101) feed(8'hFD, 1'b0, 1'b0, '0);
                else feed(byte'(i & 8'hEF), 1'b0, 1'b0, '0);  // never 0xFF
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // T1 + T2 + T3: frame A (PES start + PTS), frame B with fake sync inside,
        // frame C carrying a new PTS mid-stream (PES boundary != frame boundary).
        feed_frame(H2, 1'b1, 1'b1, 33'h11111, 1'b0);   // frame A
        feed_frame(H2, 1'b0, 1'b0, '0, 1'b1);          // frame B (fake sync at 100)
        feed_frame(H2, 1'b0, 1'b1, 33'h22222, 1'b0);   // frame C (PTS on 1st byte)
        feed(8'h00, 1'b0, 1'b0, '0);                   // flush the holding register
        repeat (4) @(posedge clk);

        // N bytes fed -> N-1 emitted (one still in the holding register)
        check(cap.size() == 3*FLEN, "T1 byte count");
        check(starts.size() == 3, "T1 three regenerated frame starts");
        if (starts.size() == 3) begin
            check(starts[0] == 0,        "T1 start at 0");
            check(starts[1] == FLEN,     "T2 start at 672 (fake sync ignored)");
            check(starts[2] == 2*FLEN,   "T1 start at 1344");
            check(ptsv_q[0] && pts_q[0] == 33'h11111, "T3 PTS on frame A");
            check(!ptsv_q[1],                          "T3 no PTS on frame B");
            check(ptsv_q[2] && pts_q[2] == 33'h22222, "T3 PTS on frame C");
        end
        // byte-transparency
        check(cap[0] == H0 && cap[1] == H1 && cap[2] == H2, "T1 header bytes intact");
        check(cap[FLEN+100] == 8'hFF && cap[FLEN+101] == 8'hFD, "T2 fake sync bytes forwarded");

        // T4: foreign type passthrough (reset first: scenario isolation — the
        // holding register still carries the T1 flush byte)
        rst_n = 0; repeat (2) @(posedge clk); rst_n = 1; @(posedge clk);
        cap.delete(); starts.delete(); pts_q.delete(); ptsv_q.delete();
        in_type = 2'd0;
        feed(8'h0B, 1'b1, 1'b0, '0);
        feed(8'h77, 1'b0, 1'b0, '0);
        feed(8'hAA, 1'b0, 1'b0, '0);
        feed(8'h00, 1'b0, 1'b0, '0);
        repeat (4) @(posedge clk);
        check(starts.size() == 1 && starts[0] == 0, "T4 PES start passed through");
        check(cap.size() == 3 && cap[0] == 8'h0B, "T4 bytes passed through");

        // T5: padded frame -> next boundary at FLEN+1
        rst_n = 0; repeat (2) @(posedge clk); rst_n = 1; @(posedge clk);
        cap.delete(); starts.delete(); pts_q.delete(); ptsv_q.delete();
        in_type = 2'd3;
        feed_frame(H2P, 1'b1, 1'b0, '0, 1'b0);   // padded frame (673 bytes)
        feed_frame(H2, 1'b0, 1'b0, '0, 1'b0);
        feed(8'h00, 1'b0, 1'b0, '0);
        repeat (4) @(posedge clk);
        check(starts.size() == 2 && starts[0] == 0 && starts[1] == FLEN + 1,
              "T5 padded frame boundary at 673");

        if (errs == 0) begin
            $display("PASS: mp2_reframer_tb (5 scenarios)");
            $finish;
        end else begin
            $display("RESULT: %0d error(s)", errs);
            $fatal(1, "mp2_reframer_tb failed");
        end
    end

    initial begin
        #2_000_000;
        $display("TIMEOUT");
        $fatal(1, "mp2_reframer_tb timeout");
    end

endmodule

`default_nettype wire
