//============================================================================
//  pcm_out_tb.sv — standalone unit test for pcm_out (M9).
//
//  Drives the two clock domains ASYNCHRONOUSLY (decode clk 10 ns, audio clk
//  14 ns) to exercise the Gray-pointer CDC FIFO, and deliberately instantiates
//  the DUT with a SMALL FIFO (FIFO_AW=7 -> 128 entries) so the 256-sample block
//  overruns it: the drain FSM must stall on `full` and the pointers must wrap —
//  the worst case for the async FIFO.  Checks:
//    - Q8.23 -> s16 format + saturation, computed against an INDEPENDENT
//      real-arithmetic reference (round-half-toward-+inf, clamp [-32768,32767]),
//      so the DUT's integer ((raw+128)>>>8 + sat) path is genuinely verified.
//    - L/R interleave + sample ordering: pop sequence must equal {gL,gR}[0..255].
//    - underflow hold: once the block is drained, further aud_ce ticks must keep
//      aud_valid low and hold the last sample.
//
//  No liba52 needed — the input PCM is a hand-built pattern covering full-scale,
//  over-range (both signs), the rounding half-step, and a ramp.  Driven by
//  bench/ac3/run_pcm_out.sh.
//============================================================================
`timescale 1ns/1ps

module pcm_out_tb;
    // ---- decode + audio clocks (asynchronous on purpose) ----
    logic clk = 0;      always #5 clk = ~clk;      // 100 MHz decode
    logic aud_clk = 0;  always #7 aud_clk = ~aud_clk; // ~71 MHz audio
    logic rst, aud_rst;

    // ---- stand-in for imdct_512.pcm_mem (Q8.23, {ch,idx}) ----
    logic signed [31:0] pcm_src [0:511];
    logic [8:0]  pcm_rd_addr;
    logic signed [31:0] pcm_rd_data;
    assign pcm_rd_data = pcm_src[pcm_rd_addr];

    logic        start, busy;
    logic        aud_ce, aud_valid;
    logic signed [15:0] audio_l, audio_r;

    pcm_out #(.FIFO_AW(7)) dut (
        .clk(clk), .rst(rst), .start(start), .mono(1'b0),
        .pcm_rd_addr(pcm_rd_addr), .pcm_rd_data(pcm_rd_data), .busy(busy),
        .aud_clk(aud_clk), .aud_rst(aud_rst), .aud_ce(aud_ce),
        .audio_l(audio_l), .audio_r(audio_r), .aud_valid(aud_valid)
    );

    // ---- independent reference: Q8.23 -> s16 (round half toward +inf, sat) ----
    function automatic integer ref_s16(input integer raw);
        real v; real t; integer fl;
        begin
            v  = raw / 256.0;
            t  = v + 0.5;
            fl = $rtoi(t);
            if (fl > t) fl = fl - 1;          // floor(v+0.5)
            if      (fl >  32767) fl =  32767;
            else if (fl < -32768) fl = -32768;
            ref_s16 = fl;
        end
    endfunction

    integer i;
    integer gL [0:255];
    integer gR [0:255];

    // ---- audio-domain sample-rate strobe (divide aud_clk) ----
    localparam integer CE_DIV = 3;
    integer ce_cnt = 0;
    always @(posedge aud_clk) begin
        if (aud_rst) begin ce_cnt <= 0; aud_ce <= 0; end
        else begin
            aud_ce <= 0;
            if (ce_cnt == CE_DIV-1) begin ce_cnt <= 0; aud_ce <= 1; end
            else ce_cnt <= ce_cnt + 1;
        end
    end

    // ---- capture popped pairs in the audio domain ----
    integer gi = 0;
    integer errs = 0;
    always @(posedge aud_clk) begin
        if (!aud_rst && aud_valid) begin
            if (gi < 256) begin
                if (audio_l !== gL[gi][15:0]) begin
                    errs = errs + 1;
                    if (errs <= 10) $display("  L mismatch idx%0d: dut=%0d ref=%0d",
                                             gi, $signed(audio_l), gL[gi]);
                end
                if (audio_r !== gR[gi][15:0]) begin
                    errs = errs + 1;
                    if (errs <= 10) $display("  R mismatch idx%0d: dut=%0d ref=%0d",
                                             gi, $signed(audio_r), gR[gi]);
                end
            end
            gi = gi + 1;     // count even past 256 to catch over-production
        end
    end

    integer timeout;
    initial begin
        // -------- build the input PCM pattern + golden --------
        for (i = 0; i < 512; i = i + 1) pcm_src[i] = 0;
        // idx 0: full-scale +1.0 / -1.0
        pcm_src[{1'b0, 8'd0}] =  32'sd8388608;   // +2^23 -> +32768 -> sat +32767
        pcm_src[{1'b1, 8'd0}] = -32'sd8388608;   // -2^23 -> -32768 (exact)
        // idx 1: over-range both signs -> saturate
        pcm_src[{1'b0, 8'd1}] =  32'sd16777216;  // +2*2^23 -> sat +32767
        pcm_src[{1'b1, 8'd1}] = -32'sd16777216;  // -2*2^23 -> sat -32768
        // idx 2: rounding half-step
        pcm_src[{1'b0, 8'd2}] =  32'sd128;       // +0.5 LSB -> +1
        pcm_src[{1'b1, 8'd2}] = -32'sd128;       // -0.5 LSB -> 0
        // idx 3: just under/over the half-step
        pcm_src[{1'b0, 8'd3}] =  32'sd127;       // -> 0
        pcm_src[{1'b1, 8'd3}] = -32'sd129;       // -> -1
        // idx 4..255: a signed ramp through mid-scale
        for (i = 4; i < 256; i = i + 1) begin
            pcm_src[{1'b0, i[7:0]}] =  (i - 128) * 257;
            pcm_src[{1'b1, i[7:0]}] = -(i - 128) * 191;
        end
        for (i = 0; i < 256; i = i + 1) begin
            gL[i] = ref_s16(pcm_src[{1'b0, i[7:0]}]);
            gR[i] = ref_s16(pcm_src[{1'b1, i[7:0]}]);
        end

        // -------- reset both domains --------
        rst = 1; aud_rst = 1; start = 0;
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge aud_clk);
        aud_rst = 0;

        // -------- kick the drain (deassert off-edge to avoid a sample race) --------
        @(posedge clk); start = 1; @(posedge clk); #1 start = 0;

        // -------- wait until 256 pairs popped (bounded) --------
        timeout = 0;
        while (gi < 256 && timeout < 2000000) begin @(posedge aud_clk); timeout = timeout + 1; end
        if (gi < 256) begin
            $display("FAIL: only %0d/256 pairs popped (timeout)", gi);
            $finish;
        end

        // -------- underflow: a few more ticks must not pop or advance --------
        repeat (10 * CE_DIV) @(posedge aud_clk);
        if (gi != 256) begin
            $display("FAIL: over-production, gi=%0d (expected 256)", gi);
            errs = errs + 1;
        end
        if (audio_l !== gL[255][15:0] || audio_r !== gR[255][15:0]) begin
            $display("FAIL: underflow did not hold last sample (L=%0d R=%0d)",
                     $signed(audio_l), $signed(audio_r));
            errs = errs + 1;
        end

        if (errs == 0) $display("PASS: pcm_out 256 pairs format/order/CDC/underflow ok");
        else           $display("FAIL: %0d error(s)", errs);
        $finish;
    end

    // global hang guard
    initial begin #5_000_000; $display("FAIL: global timeout"); $finish; end
endmodule
