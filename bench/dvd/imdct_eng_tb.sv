// bench/dvd/imdct_eng_tb.sv -- the AC-3 IMDCT on the engine (dts_vec op 25) against
// tools/imdct_isa.py, word for word and cycle for cycle (docs/imdct_engine.md I2).
//
// Vectors (+dir=DIR, tools/imdct_isa.py vec): one continuous run from a junk ring.
// Per item, the bench
//   N  writes the block's coefficients into X (slot = channel), starts op 25 with the
//      block's side information, gives imdct_go;
//   U  (ISKIP, a7[0]) writes an injected work buffer and channel 0's delay line into the
//      ring, marks channel 0 valid, starts op 25 at the IFFT -- the only way to reach
//      the 33-bit pre-sums (no coefficient block does through PRE);
// then scores:
//   [cycles] go -> imdct_fin equals the emulator's cycles (the budget gate charges
//            those, tools/test_ac3_isa.py, so a slower RTL would make the budget a lie);
//   [ring]   ALL 2,048 ring words equal the emulator's after the op (!==): PCM slots,
//            the delay lines, the buffer, the temporaries -- a stray write anywhere shows;
//   [hang]   imdct_fin and done arrive.
// Exit: $fatal on the first failure; "IMDCT_ENG PASS n" otherwise.

`default_nettype none
`timescale 1ns/1ps

module imdct_eng_tb;
    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    logic         start = 1'b0, done;
    logic   [5:0] op = 6'd0;
    logic [127:0] args = '0;
    logic         imdct_req, imdct_fin;
    logic         imdct_go = 1'b0;
    logic  [31:0] pcm_q;
    logic  [24:0] coef_q;
    logic  [15:0] pcm_l, pcm_r;
    logic         pcm_valid, xq_ready, cb_req, cb_sel;
    logic  [11:0] cb_addr;

    dts_vec dut (
        .clk, .rst_n, .start, .op, .args, .done,
        .xq_code(24'd0), .xq_valid(1'b0), .xq_ready,
        .cb_req, .cb_sel, .cb_addr, .cb_valid(1'b0), .cb_data(64'd0),
        .pcm_l, .pcm_r, .pcm_valid, .pcm_ready(1'b1),
        .xq_addr(11'd0), .abort(1'b0),
        .imdct_req, .imdct_go, .imdct_fin, .pcm_ra(9'd0), .pcm_q,
        .coef_ra(11'd0), .coef_q);

    string dir;
    logic [34:0] ring0  [0:2047];
    logic [34:0] expect_w [0:2047];
    integer fi, fc, fj, fe, n, cyc, gcyc, fcyc, nitems, nf, blksw, dyn, acmod, cmix, sur, ecyc, sh;
    logic [23:0] cw;
    logic [34:0] w;
    byte kind;

    always @(posedge clk) cyc <= cyc + 1;

    task automatic wait_cycles(input integer k);
        repeat (k) @(posedge clk);
    endtask

    initial begin
        cyc = 0;
        if (!$value$plusargs("dir=%s", dir)) $fatal(1, "FAIL [setup] +dir=");
        $readmemh({dir, "/ring0.mem"}, ring0);
        fi = $fopen({dir, "/items.txt"}, "r");
        fc = $fopen({dir, "/coeff.mem"}, "r");
        fj = $fopen({dir, "/inj.mem"}, "r");
        fe = $fopen({dir, "/expect.mem"}, "r");
        if (fi == 0 || fe == 0) $fatal(1, "FAIL [setup] vectors missing in %s", dir);
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        for (int k = 0; k < 2048; k++) dut.ring[k] = ring0[k];
        nitems = 0;
        while ($fscanf(fi, " %c", kind) == 1) begin
            args = '0;
            if (kind == "N") begin
                if ($fscanf(fi, "%d %d %d %d %d %d %d", nf, blksw, dyn, acmod, cmix, sur, ecyc) != 7)
                    $fatal(1, "FAIL [setup] items.txt line %0d", nitems);
                for (int ch = 0; ch < nf; ch++)
                    for (int b = 0; b < 256; b++) begin
                        if ($fscanf(fc, "%h", cw) != 1) $fatal(1, "FAIL [setup] coeff.mem short");
                        dut.xb[{ch[2:0], b[7:0]}] = {{3{cw[23]}}, cw};
                    end
                args[15:0] = blksw; args[31:16] = dyn; args[47:32] = acmod;
                args[79:64] = cmix; args[95:80] = sur;
            end else begin
                if ($fscanf(fi, "%d %d", sh, ecyc) != 2) $fatal(1, "FAIL [setup] items.txt line %0d", nitems);
                for (int k = 0; k < 256; k++) begin
                    if ($fscanf(fj, "%h", w) != 1) $fatal(1, "FAIL [setup] inj.mem short");
                    dut.ring[k] = w;
                end
                for (int k = 0; k < 128; k++) begin
                    if ($fscanf(fj, "%h", w) != 1) $fatal(1, "FAIL [setup] inj.mem short");
                    dut.ring[768 + k] = w;
                end
                dut.im_vld[0] = 1'b1;
                args[15:0] = sh; args[47:32] = 1; args[127:112] = 1;          // 1/0, ISKIP
            end
            // start op 25; give go once it has waited two cycles (ISKIP's schedule read)
            @(negedge clk); start = 1'b1; op = 6'd25;
            @(negedge clk); start = 1'b0;
            n = 0;
            while (!imdct_req) begin @(negedge clk); if (++n > 100) $fatal(1, "FAIL [hang] item %0d: no imdct_req", nitems); end
            @(negedge clk); @(negedge clk);
            imdct_go = 1'b1; gcyc = cyc;
            @(negedge clk); imdct_go = 1'b0;
            n = 0;
            while (!imdct_fin) begin
                @(posedge clk); #1;
                if (++n > 400000) $fatal(1, "FAIL [hang] item %0d: no imdct_fin", nitems);
            end
            fcyc = cyc - gcyc;
            n = 0;
            while (!done) begin @(posedge clk); #1; if (++n > 100) $fatal(1, "FAIL [hang] item %0d: no done", nitems); end
            for (int k = 0; k < 2048; k++) begin
                if ($fscanf(fe, "%h", expect_w[k]) != 1) $fatal(1, "FAIL [setup] expect.mem short");
            end
            for (int k = 0; k < 2048; k++)
                if (dut.ring[k] !== expect_w[k])
                    $fatal(1, "FAIL [ring] item %0d (%c): ring[%0d] = %09h, expected %09h", nitems, kind, k,
                           dut.ring[k], expect_w[k]);
            // the values first, then the time: a mutation that breaks both names [ring]
            if (fcyc != ecyc)
                $fatal(1, "FAIL [cycles] item %0d (%c): rtl %0d, the emulator %0d", nitems, kind, fcyc, ecyc);
            nitems++;
        end
        if (nitems == 0) $fatal(1, "FAIL [setup] no items");
        $display("IMDCT_ENG PASS %0d", nitems);
        $finish;
    end
endmodule
