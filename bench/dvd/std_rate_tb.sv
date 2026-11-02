// std_rate_tb.sv -- the STC tick and NCO trim for standard conversion (dvd/std_rate.sv).
// The contract is the CONSUMER's: an exact tick count over the ratio's period, even spacing,
// no burst across a mode change, and an NCO increment that achieves the ratio. Trim is scored
// by the rate it produces, so a constant copied wrongly into both files still fails.
// Runner: bench/dvd/run_std_rate.sh (--red = mutations, each must fail exactly its own arm).
`timescale 1ns/1ps
module std_rate_tb;
    reg        clk = 0, rst_n = 0;
    reg  [1:0] mode = 0, nco_fs = 1;
    wire       tick;
    wire signed [21:0] nco_trim;
    integer    fails = 0;

    std_rate dut (.clk(clk), .rst_n(rst_n), .mode(mode), .nco_fs(nco_fs),
                  .tick(tick), .nco_trim(nco_trim));

    always #5 clk = ~clk;

    task fail(input [8*12-1:0] arm, input [8*72-1:0] msg);
        begin $display("FAIL [%0s] %0s", arm, msg); fails = fails + 1; end
    endtask

    // Count ticks over `cycles`; report the tightest and widest spacing. An X tick is a failure.
    integer got, gmin, gmax, gap;
    reg     sawx;
    task count(input integer cycles);
        integer i;
        begin
            got = 0; gmin = 1 << 30; gmax = 0; gap = 0; sawx = 0;
            for (i = 0; i < cycles; i = i + 1) begin
                @(negedge clk);
                if (tick !== 1'b0 && tick !== 1'b1) sawx = 1;
                gap = gap + 1;
                if (tick === 1'b1) begin
                    if (got > 0) begin
                        if (gap < gmin) gmin = gap;
                        if (gap > gmax) gmax = gap;
                    end
                    got = got + 1; gap = 0;
                end
            end
        end
    endtask

    task setmode(input [1:0] m);
        begin @(negedge clk); mode = m; @(negedge clk); end
    endtask

    // The increment the NCO actually adds, against the exact rate for this fs and ratio.
    real exact, eff, ppm, worst;
    integer base;
    task trimcheck(input [1:0] m, input [1:0] fs, input integer hz, input real ratio);
        begin
            mode = m; nco_fs = fs; #1;
            if (^nco_trim === 1'bx) fail("trim", "X on nco_trim");
            exact = (hz * 4294967296.0) / 27000000.0;
            base  = $rtoi(exact);                       // dvd_audio_decode's floored nominal
            eff   = base + nco_trim;
            ppm   = (eff / (exact * ratio) - 1.0) * 1000000.0;
            if (ppm < 0) ppm = -ppm;
            if (ppm > worst) worst = ppm;
            if (ppm > 0.15) begin
                $display("  fs=%0d mode=%0d trim=%0d: %f ppm off", hz, m, nco_trim, ppm);
                fail("trim", "increment misses the ratio by more than 0.15 ppm");
            end
        end
    endtask

    integer i;
    reg ref_hit;
    integer ref_div;
    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1;

        // [unity] cycle-identical to the divider it replaces: same reset phase, same cycles.
        ref_div = 0;
        for (i = 0; i < 3000000; i = i + 1) begin
            ref_hit = (ref_div == 299);
            if (tick !== ref_hit) begin
                fail("unity", "tick differs from clk/300");
                i = 3000000;
            end
            ref_div = ref_hit ? 0 : ref_div + 1;
            @(negedge clk);
        end
        $display("  [unity] 3000000 cycles against the /300 reference");

        // [slow] exactly 960 per 300300 clocks, over several whole periods.
        setmode(2'd1);
        count(300300 * 7);
        if (sawx) fail("slow", "X on tick");
        if (got !== 960 * 7) begin $display("  got %0d", got); fail("slow", "wrong tick count"); end
        if (gmin < 312 || gmax > 313) begin
            $display("  gaps %0d..%0d", gmin, gmax); fail("slow", "ticks not evenly spaced");
        end
        $display("  [slow] %0d ticks, gaps %0d..%0d", got, gmin, gmax);

        // [fast] exactly 1001 per 288000 clocks.
        setmode(2'd2);
        count(288000 * 7);
        if (sawx) fail("fast", "X on tick");
        if (got !== 1001 * 7) begin $display("  got %0d", got); fail("fast", "wrong tick count"); end
        if (gmin < 287 || gmax > 288) begin
            $display("  gaps %0d..%0d", gmin, gmax); fail("fast", "ticks not evenly spaced");
        end
        $display("  [fast] %0d ticks, gaps %0d..%0d", got, gmin, gmax);

        // [switch] from a late slow-mode accumulator straight to unity: no burst, and the first
        // tick is a full period away. Without the restart this is ~1000 ticks in ~1000 clocks.
        setmode(2'd1);
        count(300300 + 311);
        mode = 2'd0;
        count(299);
        if (got !== 0) begin $display("  got %0d", got); fail("switch", "tick burst after a mode change"); end
        count(3000);
        if (got !== 10) begin $display("  got %0d", got); fail("switch", "wrong rate after a mode change"); end
        if (gmin !== 300 || gmax !== 300) fail("switch", "unity gaps not 300 after a mode change");
        $display("  [switch] no burst slow->unity");

        // [mode3] the unused encoding is unity, not a stopped clock.
        setmode(2'd3);
        count(30000);   // long enough that fast (104) cannot round to unity (100)
        if (got !== 100) begin $display("  got %0d", got); fail("mode3", "mode 3 is not unity"); end
        setmode(2'd0);

        // [trim] every rate in both directions; unity and mode 3 are exactly zero.
        worst = 0;
        trimcheck(2'd1, 2'd0, 44100, 960.0/1001.0);
        trimcheck(2'd1, 2'd1, 48000, 960.0/1001.0);
        trimcheck(2'd1, 2'd2, 32000, 960.0/1001.0);
        trimcheck(2'd1, 2'd3, 96000, 960.0/1001.0);
        trimcheck(2'd2, 2'd0, 44100, 1001.0/960.0);
        trimcheck(2'd2, 2'd1, 48000, 1001.0/960.0);
        trimcheck(2'd2, 2'd2, 32000, 1001.0/960.0);
        trimcheck(2'd2, 2'd3, 96000, 1001.0/960.0);
        for (i = 0; i < 4; i = i + 1) begin
            nco_fs = i[1:0];
            mode = 2'd0; #1; if (nco_trim !== 22'sd0) fail("trim", "unity trim not zero");
            mode = 2'd3; #1; if (nco_trim !== 22'sd0) fail("trim", "mode 3 trim not zero");
        end
        $display("  [trim] worst %f ppm", worst);

        if (fails == 0) $display("PASS std_rate_tb");
        else $fatal(1, "std_rate_tb: %0d failures", fails);
        $finish;
    end
endmodule
