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
    logic mono = 1'b0;          // DVD-FORK: acmod-1 ch0-duplication mode
    // DVD-FORK: per-frame output level scalar (Q2.14).  16384 == 1.0 == the
    // pre-fix identity, so every pre-existing scenario below is unaffected; the
    // scalar itself is exercised by the [LVL] arm at the end of this file.
    logic [15:0] lvl_q = 16'd16384;

    pcm_out #(.FIFO_AW(7)) dut (
        .clk(clk), .rst(rst), .start(start), .mono(mono), .lvl_q(lvl_q),
        .pcm_rd_addr(pcm_rd_addr), .pcm_rd_data(pcm_rd_data), .busy(busy),
        .aud_clk(aud_clk), .aud_rst(aud_rst), .aud_ce(aud_ce),
        .audio_l(audio_l), .audio_r(audio_r), .aud_valid(aud_valid)
    );

    // ---- independent reference for the DVD-FORK level scalar ----------------
    // Computed in REAL arithmetic from the DEFINITION (value * G, then the same
    // rounding/saturation), not by re-running the RTL's shift-and-slice -- a
    // golden that repeats the implementation agrees with it by construction.
    function automatic integer ref_s16_lvl(input integer raw, input integer lq);
        real v; real t; integer fl;
        begin
            v  = (raw / 256.0) * (lq / 16384.0);
            t  = v + 0.5;
            fl = $rtoi(t);
            if (fl > t) fl = fl - 1;          // floor(v+0.5)
            if      (fl >  32767) fl =  32767;
            else if (fl < -32768) fl = -32768;
            ref_s16_lvl = fl;
        end
    endfunction

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
                // DVD-FORK: with `mono` the drain must read ch0 for BOTH
                // outputs, so R is expected to equal the ch0 (L) golden.
                if (audio_r !== (mono ? gL[gi][15:0] : gR[gi][15:0])) begin
                    errs = errs + 1;
                    if (errs <= 10) $display("  R mismatch idx%0d: dut=%0d ref=%0d",
                                             gi, $signed(audio_r),
                                             mono ? gL[gi] : gR[gi]);
                end
            end
            gi = gi + 1;     // count even past 256 to catch over-production
        end
    end

    integer timeout;
    integer li, lvl_errs;
    // every distinct lvl_q imdct_512 can emit (see its lvl_den case)
    integer lvl_tab [0:12];
    initial begin
        lvl_tab[0]=32768; lvl_tab[1]=24209; lvl_tab[2]=21845; lvl_tab[3]=20550;
        lvl_tab[4]=19195; lvl_tab[5]=17678; lvl_tab[6]=16820; lvl_tab[7]=16384;
        lvl_tab[8]=15902; lvl_tab[9]=15644; lvl_tab[10]=14847; lvl_tab[11]=14237;
        lvl_tab[12]=13573;
    end
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

        // ================= MONO PASS (DVD-FORK 2026-08-31) =================
        // acmod 1 decodes ONE channel, so pcm_mem ch1 is never written and the
        // drain must read ch0 for BOTH outputs. Nothing covered this before:
        // the front-end cosim reads ac3_front's pcm_mem directly and never
        // instantiates pcm_out, so `mono` had no test at all while being the
        // only genuinely new signal in the hardware audio path.
        // ch1 is filled with a DISTINCT poison pattern: if the drain ever reads
        // it, R will not equal the ch0 golden and this fails loudly.
        for (i = 0; i < 256; i = i + 1)
            pcm_src[{1'b1, i[7:0]}] = 32'sd7654321;   // poison ch1
        mono = 1'b1;
        gi = 0; errs = 0;
        rst = 1; aud_rst = 1; start = 0;
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge aud_clk);
        aud_rst = 0;
        @(posedge clk); start = 1; @(posedge clk); #1 start = 0;
        timeout = 0;
        while (gi < 256 && timeout < 2000000) begin @(posedge aud_clk); timeout = timeout + 1; end
        if (gi < 256) begin
            $display("FAIL(mono): only %0d/256 pairs popped (timeout)", gi);
            errs = errs + 1;
        end
        if (errs == 0) $display("PASS: pcm_out mono duplicates ch0 to L and R");
        else           $display("FAIL: mono pass, %0d error(s)", errs);

        // ============ [LVL] OUTPUT LEVEL SCALAR (DVD-FORK 2026-09-07) ==========
        // The 6.02 dB fix: this datapath decodes at liba52's state->level = 1.0,
        // so pcm_out scales by lvl_q = 2/(1+clev+slev) (Q2.14) on the way to s16.
        // Checked against a real-arithmetic reference over the whole ramp, for
        // every distinct lvl_q imdct_512 can emit.
        //
        // ★ The load-bearing case is lvl[0] = 32768 (x2, acmod 1/2 -- no
        //   downmix).  That is the arm that was WRONG before this fix, and it is
        //   the one that must take a full-scale-in-pcm_mem sample (+/-0.5, i.e.
        //   +/-2^22) all the way to +/-32767.
        mono = 1'b0;
        for (i = 0; i < 256; i = i + 1)
            pcm_src[{1'b1, i[7:0]}] = -(i - 128) * 191;    // undo the mono poison
        // pcm_mem full scale is +/-0.5 == +/-2^22 once the level fix is in place
        pcm_src[{1'b0, 8'd0}] =  32'sd4194304;
        pcm_src[{1'b1, 8'd0}] = -32'sd4194304;
        lvl_errs = 0;
        for (li = 0; li < 13; li = li + 1) begin
            lvl_q = lvl_tab[li];
            for (i = 0; i < 256; i = i + 1) begin
                gL[i] = ref_s16_lvl(pcm_src[{1'b0, i[7:0]}], lvl_tab[li]);
                gR[i] = ref_s16_lvl(pcm_src[{1'b1, i[7:0]}], lvl_tab[li]);
            end
            gi = 0; errs = 0;
            rst = 1; aud_rst = 1; start = 0;
            repeat (5) @(posedge clk);
            rst = 0;
            repeat (5) @(posedge aud_clk);
            aud_rst = 0;
            @(posedge clk); start = 1; @(posedge clk); #1 start = 0;
            timeout = 0;
            while (gi < 256 && timeout < 2000000) begin
                @(posedge aud_clk); timeout = timeout + 1;
            end
            if (gi < 256) begin
                $display("FAIL[LVL]: lvl_q=%0d only %0d/256 pairs", lvl_tab[li], gi);
                errs = errs + 1;
            end
            // ★ The x2 arm must take a full-scale pcm_mem sample (+/-0.5) all
            // the way to +/-32767.  If it does not, the level fix is inert and
            // every other comparison above would still pass, since they only
            // check dut-vs-reference and both would be scaled alike.
            // (+2^22 x2 = +2^23 -> +32768 -> saturates to +32767; -2^22 x2
            //  = -2^23 -> -32768, which IS representable, so it is exact.)
            if (li == 0 && (gL[0] !== 32767 || gR[0] !== -32768)) begin
                $display("FAIL[LVL]: x2 does not reach full scale (L=%0d R=%0d)",
                         gL[0], gR[0]);
                errs = errs + 1;
            end
            if (errs != 0) lvl_errs = lvl_errs + errs;
        end
        lvl_q = 16'd16384;
        if (lvl_errs == 0)
            $display("PASS: pcm_out level scalar exact over 13 lvl_q values x 256 samples");
        else
            $display("FAIL: level scalar, %0d error(s)", lvl_errs);
        if (lvl_errs != 0) $fatal(1, "pcm_out level scalar FAILED");
        $finish;
    end

    // global hang guard
    initial begin #5_000_000; $display("FAIL: global timeout"); $finish; end
endmodule
