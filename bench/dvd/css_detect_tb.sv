// css_detect_tb.sv — the CSS density verdict (issue #59).
//
// The rule this replaces counted four scrambled PES headers per session, however
// far apart, and latched permanently. A genuinely scrambled source gives a marker
// about every 5 packs; a stray gives a handful in an hour. The old rule could not
// tell them apart, so discs that play perfectly lost all their audio.
//
// ★ HOW THIS BENCH AVOIDS BEING VACUOUS. A bench that pokes 16 markers, sees a
// latch and stops would pass with the leak deleted, with LEAK_CLEAN wrong, and with
// the denominator ignored. So:
//   - it carries a VERBATIM copy of the deleted rule (leg_*) and asserts that the
//     old rule latches on stimulus the new one must refuse. Every RED claim here is
//     an assertion, not a comment;
//   - it MEASURES how many headers a latch took and asserts a band, never "!= 0";
//   - it finds the density knee and the periodic-stimulus boundary by SEARCH and
//     compares them against numbers DERIVED from the parameters, so changing a
//     parameter without changing the bench fails.
//
// Arms: A1/A2 the false positive (RED vs the old rule) · A3 real density latches
// promptly · A4 density sweep finds the knee · A5 periodic adversary finds the
// boundary · A6 exact latch index · A7 the denominator is load-bearing · A8 the
// leak is load-bearing · A9 sticky, and what clears it · A10 census saturates.
`timescale 1ns/1ps
`default_nettype none

module css_detect_tb;
    localparam int LATCH_HITS = 16;
    localparam int LEAK_CLEAN = 64;

    logic clk = 0, rst_n = 0;
    logic mount = 0, eject = 0, hdr_ok = 0, scrambled = 0;
    logic css;
    logic [15:0] hdr_census, scram_census;

    always #5 clk = ~clk;

    css_detect #(.LATCH_HITS(LATCH_HITS), .LEAK_CLEAN(LEAK_CLEAN)) dut (
        .clk(clk), .rst_n(rst_n),
        .mount(mount), .eject(eject),
        .hdr_ok(hdr_ok), .scrambled(scrambled),
        .css_scrambled(css), .hdr_census(hdr_census), .scram_census(scram_census)
    );

    // ---- the rule being deleted, verbatim from dvd/emu.sv, as a reference model ----
    reg [2:0] leg_cnt;
    reg       leg_latched;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                            begin leg_cnt <= 0; leg_latched <= 0; end
        else if (mount || eject)               begin leg_cnt <= 0; leg_latched <= 0; end
        else if (scrambled && !leg_latched) begin
            leg_cnt <= leg_cnt + 3'd1;
            if (leg_cnt == 3'd3) leg_latched <= 1'b1;   // 4th scrambled PES
        end
    end

    // ---- instruments ----
    int hdr_n = 0, latch_at = -1, fails = 0;
    always @(posedge clk) if (rst_n) begin
        if (hdr_ok) hdr_n <= hdr_n + 1;
        if (css && latch_at < 0) latch_at <= hdr_n;
    end

    integer rseed = 32'h1234_5678;
    function automatic int rnd1m;
        int v;
        begin
            v = $random(rseed);
            if (v < 0) v = -v;
            rnd1m = v % 1000000;
        end
    endfunction

    task automatic tick(input bit s);
        begin
            hdr_ok    <= 1'b1;
            scrambled <= s;
            @(posedge clk);
            hdr_ok    <= 1'b0;
            scrambled <= 1'b0;
            @(posedge clk);
        end
    endtask

    // n headers; a marker every `period` (period 0 = random at ppm/1e6).
    task automatic feed(input int n, input int ppm, input int period);
        int i;
        begin
            for (i = 0; i < n; i++) begin
                if (period > 0) tick((i % period) == 0);
                else            tick(rnd1m() < ppm);
            end
        end
    endtask

    task automatic new_media;
        begin
            mount <= 1'b1; @(posedge clk); mount <= 1'b0; @(posedge clk);
            hdr_n = 0; latch_at = -1; rseed = 32'h1234_5678;
        end
    endtask

    task automatic chk(input string name, input bit want, input bit got);
        begin
            if (want !== got) begin
                $display("  FAIL %s: got %0d, expected %0d", name, got, want);
                fails = fails + 1;
            end
        end
    endtask

    int i, p, knee_lo, knee_hi, bound;
    int dens [0:10];
    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        $display("=== css_detect: CSS density verdict (LATCH_HITS=%0d LEAK_CLEAN=%0d) ===",
                 LATCH_HITS, LEAK_CLEAN);
        $display("    knee p* = 1/(LEAK_CLEAN+1) = %0.4f", 1.0/(LEAK_CLEAN+1));

        // ---- A1: the issue #59 regression. Four markers, 4096 headers apart.
        new_media;
        feed(4*4096, 0, 4096);
        $display("A1 4 strays 4096 apart          old rule latched=%0d  new=%0d",
                 leg_latched, css);
        chk("A1 old rule must latch (else the stimulus proves nothing)", 1'b1, leg_latched);
        chk("A1 new rule must NOT latch",                                1'b0, css);

        // ---- A2: the reported shape -- a handful of strays at irregular spacing.
        new_media;
        for (i = 0; i < 8; i++) begin
            feed(400 + i*370, 0, 0);      // clean run
            tick(1'b1);                   // one stray
        end
        $display("A2 8 strays, gaps 400..2990     old rule latched=%0d  new=%0d",
                 leg_latched, css);
        chk("A2 old rule must latch", 1'b1, leg_latched);
        chk("A2 new rule must NOT latch", 1'b0, css);

        // ---- A3: a real CSS density must still latch, and FAST.
        new_media;
        feed(5000, 190000, 0);            // p = 0.19, the measured figure
        $display("A3 p=0.19                       latched=%0d after %0d headers (expect ~%0d)",
                 css, latch_at, (LATCH_HITS*1000)/(190 - (810/LEAK_CLEAN)));
        chk("A3 must latch at real CSS density", 1'b1, css);
        if (css && (latch_at < LATCH_HITS || latch_at > 300)) begin
            $display("  FAIL A3: latched after %0d headers, expected 16..300", latch_at);
            fails = fails + 1;
        end

        // ---- A4: sweep the density and locate the knee by search.
        $display("A4 density sweep:");
        knee_lo = 0; knee_hi = 1000000;
        dens[0]=0; dens[1]=100; dens[2]=1000; dens[3]=4000; dens[4]=8000;
        dens[5]=30000; dens[6]=50000; dens[7]=100000; dens[8]=190000;
        dens[9]=500000; dens[10]=1000000;
        for (i = 0; i <= 10; i++) begin
            new_media;
            feed(dens[i] <= 8000 ? 100000 : 20000, dens[i], 0);
            $display("     p=%0.6f  latched=%0d  headers=%0d",
                     dens[i]/1000000.0, css, latch_at);
            if (css) begin if (dens[i] < knee_hi) knee_hi = dens[i]; end
            else     begin if (dens[i] > knee_lo) knee_lo = dens[i]; end
        end
        $display("     measured knee between p=%0.6f and p=%0.6f (design p*=%0.6f)",
                 knee_lo/1000000.0, knee_hi/1000000.0, 1.0/(LEAK_CLEAN+1));
        // ⚠ THE MEASURED KNEE SITS BELOW THE DESIGN KNEE, AND THAT IS REAL, NOT AN
        // ARTEFACT. Below p* the bucket is a random walk with NEGATIVE drift, not a
        // pinned zero: it still reaches LATCH_HITS on a rare excursion, and the
        // longer the session the likelier that is. Measured here at p=0.008 (about
        // half the knee): latched after ~67,000 headers. So the honest claim is
        // "the further below p*, the exponentially longer it takes", and a session
        // is finite. The false positive this fixes is three orders of magnitude
        // lower (a handful of markers, i.e. p ~ 1e-5), where 100,000 headers do not
        // move the bucket off zero at all.
        // The assertion is therefore a factor-of-four band around the DERIVED knee,
        // which still fails on any parameter change the bench was not told about
        // (deleting the leak drops the measured knee to ~0.001, an order out).
        if (!(knee_hi*4*(LEAK_CLEAN+1) >= 1000000 && knee_lo*(LEAK_CLEAN+1) <= 4000000)) begin
            $display("  FAIL A4: measured knee %0.6f..%0.6f is not within 4x of p*=%0.6f",
                     knee_lo/1000000.0, knee_hi/1000000.0, 1.0/(LEAK_CLEAN+1));
            fails = fails + 1;
        end

        // ---- A5: the periodic adversary that kills a "reset after N clean" rule.
        // Deterministic: a marker every P headers latches iff P <= LEAK_CLEAN.
        $display("A5 periodic adversary:");
        bound = 0;
        for (i = 0; i < 7; i++) begin
            p = (i == 0) ? 8   : (i == 1) ? 16  : (i == 2) ? 32  : (i == 3) ? 64 :
                (i == 4) ? 65  : (i == 5) ? 250 : 1000;
            new_media;
            feed(p*40 > 60000 ? 60000 : p*40, 0, p);
            $display("     period=%0d  latched=%0d", p, css);
            if (css && p > bound) bound = p;
            chk($sformatf("A5 period %0d", p), (p <= LEAK_CLEAN), css);
        end
        $display("     largest latching period = %0d (LEAK_CLEAN = %0d)", bound, LEAK_CLEAN);
        if (bound !== LEAK_CLEAN) begin
            $display("  FAIL A5: boundary %0d, expected LEAK_CLEAN = %0d", bound, LEAK_CLEAN);
            fails = fails + 1;
        end

        // ---- A6: latches on exactly the LATCH_HITS'th marker, not the one before.
        new_media;
        feed(LATCH_HITS-1, 0, 1);
        chk("A6 must not latch on hit 15", 1'b0, css);
        tick(1'b1);
        chk("A6 must latch on hit 16", 1'b1, css);
        repeat (2) @(posedge clk);   // latch_at is captured non-blocking on the edge
        if (latch_at !== LATCH_HITS) begin
            $display("  FAIL A6: latched at header %0d, expected %0d", latch_at, LATCH_HITS);
            fails = fails + 1;
        end

        // ---- A7: the denominator is load-bearing -- scrambled without hdr_ok is
        // not evidence. Guards against a future ps_demux edit that drops it.
        new_media;
        for (i = 0; i < 64; i++) begin
            scrambled <= 1'b1; @(posedge clk); scrambled <= 1'b0; @(posedge clk);
        end
        $display("A7 64 markers with hdr_ok low   latched=%0d census=%0d/%0d",
                 css, scram_census, hdr_census);
        chk("A7 must not latch", 1'b0, css);
        if (hdr_census !== 0 || scram_census !== 0) begin
            $display("  FAIL A7: census moved without hdr_ok");
            fails = fails + 1;
        end

        // ---- A8: the leak is load-bearing. 15 hits repaid in full, 20 times over.
        new_media;
        for (i = 0; i < 20; i++) begin
            feed(15, 0, 1);                       // 15 back-to-back markers
            feed(LEAK_CLEAN*15, 0, 0);            // exactly enough clean to repay them
        end
        $display("A8 15 hits repaid x20           latched=%0d scram_census=%0d (expect 300)",
                 css, scram_census);
        chk("A8 must not latch", 1'b0, css);
        if (scram_census !== 300) begin
            $display("  FAIL A8: scram_census %0d, expected 300 (were the hits delivered?)",
                     scram_census);
            fails = fails + 1;
        end

        // ---- A9: sticky, and only media changes clear it.
        new_media;
        feed(5000, 190000, 0);
        chk("A9 latched to begin with", 1'b1, css);
        feed(100000, 0, 0);
        chk("A9 stays latched through 100k clean headers", 1'b1, css);
        new_media;
        chk("A9 mount clears it", 1'b0, css);
        feed(4*4096, 0, 4096);
        chk("A9 does not re-latch on strays after a mount", 1'b0, css);
        feed(5000, 190000, 0);
        chk("A9 latched again", 1'b1, css);
        eject <= 1'b1; @(posedge clk); eject <= 1'b0; @(posedge clk);
        chk("A9 eject clears it", 1'b0, css);

        // ---- A10: the census saturates rather than wrapping.
        new_media;
        feed(70000, 0, 0);
        $display("A10 70000 clean headers         hdr_census=%0d (expect 65535)", hdr_census);
        if (hdr_census !== 16'hFFFF) begin
            $display("  FAIL A10: census %0d, expected saturation at 65535", hdr_census);
            fails = fails + 1;
        end

        if (fails != 0) begin
            $display("FAIL: %0d check(s) failed", fails);
            $fatal(1);
        end
        $display("PASS: density verdict -- strays cannot latch; real CSS (p=0.19) latched");
        $finish;
    end
endmodule
`default_nettype wire
