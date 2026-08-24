//============================================================================
//  lpcm_unpack_tb.sv — unit test for dvd/lpcm_unpack.sv
//
//  Exercises all three DVD LPCM word lengths (16 / 20 / 24-bit, stereo 48 kHz)
//  via the `quant` input and checks that:
//    - each sample's HIGH 16 bits are assembled big-endian -> s16,
//    - L/R interleave is preserved,
//    - the trailing low-bit bytes (20-bit: 2, 24-bit: 4 per 2-pair group) are
//      DISCARDED, not leaked into the output (top-16 truncation),
//    - exactly the expected number of pairs is popped, one per aud_ce, in order,
//    - signed full-scale negatives survive (0x8000 -> -32768),
//    - aud_valid stays low (and the last sample is held) once drained,
//    - quant=16 is bit-for-bit the original 16-bit-only behaviour.
//
//  Packing (per FFmpeg libavcodec/pcm-dvd.c): a stereo group spans 2 sample-
//  times. The four high 16-bit words `L0 R0 L1 R1` (8 bytes) come first — the
//  same layout as plain 16-bit — followed by the low bytes we discard.
//============================================================================
`timescale 1ns/1ps

module lpcm_unpack_tb;
    logic clk = 0; always #5 clk = ~clk;
    logic rst;
    logic [1:0]  quant;
    logic        wr_en;
    logic [7:0]  wr_data;
    logic        full;
    logic        aud_ce;
    logic signed [15:0] audio_l, audio_r;
    logic        aud_valid;

    lpcm_unpack #(.FIFO_AW(6)) dut (
        .clk(clk), .rst(rst), .quant(quant),
        .wr_en(wr_en), .wr_data(wr_data), .full(full),
        .aud_ce(aud_ce), .audio_l(audio_l), .audio_r(audio_r), .aud_valid(aud_valid)
    );

    // golden pairs (high 16 bits of each sample — the truncated output)
    localparam int MAXP = 8;
    logic [15:0] gL [0:MAXP-1];
    logic [15:0] gR [0:MAXP-1];

    // built byte stream (max group = 12 bytes -> generous headroom)
    logic [7:0] stream [0:MAXP*6-1];
    integer     slen;

    integer errs = 0;

    // capture popped pairs in order whenever aud_valid pulses
    logic [15:0] cL [0:MAXP+3];
    logic [15:0] cR [0:MAXP+3];
    integer cap = 0;
    always @(posedge clk) begin
        if (!rst && aud_valid) begin
            if (cap <= MAXP+3) begin cL[cap] = audio_l; cR[cap] = audio_r; end
            cap = cap + 1;
        end
    end

    task push_byte(input [7:0] b);
        begin
            @(negedge clk);
            while (full) @(negedge clk);
            wr_en = 1; wr_data = b;
            @(negedge clk);
            wr_en = 0;
        end
    endtask

    // Build a byte stream for `np` pairs (np even = whole groups of 2 pairs) at
    // word length `qm`. The 8 high-word bytes per group are the golden samples;
    // the trailing low bytes are distinct nonzero fillers (must be discarded).
    task build_stream(input [1:0] qm, input integer np);
        integer g, k, si, skip_n;
        begin
            skip_n = (qm == 2'd1) ? 2 : (qm == 2'd2) ? 4 : 0;
            si = 0;
            for (g = 0; g < np/2; g = g + 1) begin
                // pair 2g:   L0 hi/lo, R0 hi/lo
                stream[si] = gL[2*g][15:8];   si = si + 1;
                stream[si] = gL[2*g][7:0];    si = si + 1;
                stream[si] = gR[2*g][15:8];   si = si + 1;
                stream[si] = gR[2*g][7:0];    si = si + 1;
                // pair 2g+1: L1 hi/lo, R1 hi/lo
                stream[si] = gL[2*g+1][15:8]; si = si + 1;
                stream[si] = gL[2*g+1][7:0];  si = si + 1;
                stream[si] = gR[2*g+1][15:8]; si = si + 1;
                stream[si] = gR[2*g+1][7:0];  si = si + 1;
                // trailing low bytes — distinct nonzero, MUST NOT appear in output
                for (k = 0; k < skip_n; k = k + 1) begin
                    stream[si] = 8'hA5 + k[3:0]; si = si + 1;
                end
            end
            slen = si;
        end
    endtask

    task run_test(input [1:0] qm, input integer np, input [63:0] name);
        integer i;
        begin
            quant = qm;
            build_stream(qm, np);

            // reset the DUT + capture between sub-tests
            rst = 1; wr_en = 0; wr_data = 0; aud_ce = 0; cap = 0;
            repeat (4) @(negedge clk);
            rst = 0;

            // feed all bytes
            for (i = 0; i < slen; i = i + 1) push_byte(stream[i]);
            repeat (4) @(negedge clk);

            // pop one pair per aud_ce (+3 extra to exercise underflow/hold)
            for (i = 0; i < np+3; i = i + 1) begin
                @(negedge clk); aud_ce = 1;
                @(negedge clk); aud_ce = 0;
            end
            repeat (4) @(negedge clk);

            if (cap !== np) begin
                $display("FAIL[%0s]: popped %0d pairs, expected %0d", name, cap, np);
                errs = errs + 1;
            end
            for (i = 0; i < np; i = i + 1) begin
                if (cL[i] !== gL[i]) begin
                    $display("FAIL[%0s] pair %0d: L dut=%04x exp=%04x", name, i, cL[i], gL[i]);
                    errs = errs + 1;
                end
                if (cR[i] !== gR[i]) begin
                    $display("FAIL[%0s] pair %0d: R dut=%04x exp=%04x", name, i, cR[i], gR[i]);
                    errs = errs + 1;
                end
            end
            // last sample held on underflow
            if (audio_l !== gL[np-1] || audio_r !== gR[np-1]) begin
                $display("FAIL[%0s]: last sample not held on underflow", name);
                errs = errs + 1;
            end
            $display("  [%0s] popped %0d pairs OK", name, cap);
        end
    endtask

    initial begin
        gL[0]=16'h1234; gR[0]=16'h5678;
        gL[1]=16'h8000; gR[1]=16'h7FFF;   // full-scale neg / pos
        gL[2]=16'hFFFF; gR[2]=16'h0001;   // -1 / +1
        gL[3]=16'h0000; gR[3]=16'hABCD;
        gL[4]=16'hDEAD; gR[4]=16'hBEEF;
        gL[5]=16'hCAFE; gR[5]=16'hF00D;
        gL[6]=16'h0102; gR[6]=16'h0304;
        gL[7]=16'hA5A5; gR[7]=16'h5A5A;

        quant = 2'd0; rst = 1; wr_en = 0; wr_data = 0; aud_ce = 0;
        repeat (4) @(negedge clk);

        run_test(2'd0, 4, "16bit");   // baseline: no low bytes
        run_test(2'd1, 4, "20bit");   // 2 low bytes/group discarded
        run_test(2'd2, 4, "24bit");   // 4 low bytes/group discarded

        if (errs == 0) $display("PASS: lpcm_unpack 16/20/24-bit");
        else           $display("FAIL: %0d error(s)", errs);
        $finish;
    end

    initial begin #400000 $display("FAIL: timeout"); $finish; end
endmodule
