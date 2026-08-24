//============================================================================
//  exponent_decode_tb.sv — self-checking unit TB for exponent_decode (M5).
//
//  exponent_decode is driven in isolation: a behavioural "packed-exp provider"
//  models audblk_parse's exp_mem (combinational read on exp_rd_addr), and the
//  TB pushes group codes + geometry directly.  Codes are chosen so the absolute
//  exponents stay inside [0,24] (no clamp), making the golden simply the A/52
//  ungroup algorithm — and matching liba52, which never clamps on valid data.
//
//  Run 1 (fill): ch0=D15 nchgrps=4, ch1=D45 nchgrps=2 — exercises group_size
//                1 and 4 and the per-channel hand-off.
//  Run 2 (reuse+D25): ch0=REUSE (must retain run-1 exps), ch1=D25 nchgrps=3 —
//                exercises group_size 2 and the reuse path.
//
//  Codes used (M0,M1,M2 -> diffs M-2):
//    67=(2,3,2)->(0,+1,0)  57=(2,1,2)->(0,-1,0)  87=(3,2,2)->(+1,0,0)
//    61=(2,2,1)->(0,0,-1)
//============================================================================

`timescale 1ns/1ps

module exponent_decode_tb;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    // ---- DUT ports (M14: packed buses, 11-bit decoded-exp addresses) ----
    logic        start;
    logic [9:0]  chexpstr;        // 2 bits/ch (ch0=[1:0], ch1=[3:2], ...)
    logic [34:0] nchgrps;         // 7 bits/ch
    logic [9:0]  exp_rd_addr;     // {ch[2:0], idx[6:0]}
    logic [7:0]  exp_rd_data;
    logic [6:0]  cpl_exp_rd_addr;
    logic [10:0] dexp_rd_addr;    // {ch[2:0], idx[7:0]}
    logic [4:0]  dexp_rd_data;
    logic        done;

    // ---- behavioural packed-exp provider (models audblk_parse.exp_mem) ----
    logic [7:0]  pmem [0:255];
    assign exp_rd_data = pmem[exp_rd_addr[7:0]];

    // M14: nfchans=2, lfeon=0; coupling + LFE channels not exercised here.
    exponent_decode dut (
        .clk(clk), .rst(rst), .start(start),
        .nfchans(3'd2), .lfeon(1'b0),
        .chexpstr(chexpstr), .nchgrps(nchgrps),
        .cplexpstr(2'd0), .cplstrtmant(9'd0), .cplendmant(9'd0),
        .lfeexpstr(1'b0),
        .exp_rd_addr(exp_rd_addr), .exp_rd_data(exp_rd_data),
        .cpl_exp_rd_addr(cpl_exp_rd_addr), .cpl_exp_rd_data(8'd0),
        .lfe_exp_rd_addr(), .lfe_exp_rd_data(8'd0),
        .dexp_rd_addr(dexp_rd_addr), .dexp_rd_data(dexp_rd_data),
        .ba_exp_rd_addr(11'd0), .ba_exp_rd_data(),
        .mant_exp_rd_addr(11'd0), .mant_exp_rd_data(),
        .done(done)
    );

    // ---- checker ----
    integer errors = 0;
    task automatic chk(input cond, input [255:0] msg);
        if (!cond) begin errors = errors + 1; $display("  FAIL  %0s", msg); end
    endtask

    // read one decoded exponent (combinational port) and compare
    task automatic chk_exp(input [2:0] ch, input [7:0] idx, input [4:0] exp_golden);
        dexp_rd_addr = {ch, idx};
        #1;
        if (dexp_rd_data !== exp_golden) begin
            errors = errors + 1;
            $display("  FAIL  ch%0d exp[%0d] = %0d, expected %0d",
                     ch, idx, dexp_rd_data, exp_golden);
        end
    endtask

    // golden arrays
    logic [4:0] g_ch0 [0:12];   // run-1 ch0 (D15), retained through run 2
    logic [4:0] g_ch1a [0:24];  // run-1 ch1 (D45)
    logic [4:0] g_ch1b [0:18];  // run-2 ch1 (D25)

    integer i;
    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("exponent_decode_tb.vcd"); $dumpvars(0, exponent_decode_tb);
        end

        for (i = 0; i < 256; i = i + 1) pmem[i] = 8'h00;
        start = 0; dexp_rd_addr = 0;
        chexpstr = 0; nchgrps = 0;

        // ---- golden: run 1 ch0 (D15, abs=5, codes 67,57,87,61) ----
        // [5, 5,6,6, 6,5,5, 6,6,6, 6,6,5]
        g_ch0[0]=5;
        g_ch0[1]=5;  g_ch0[2]=6;  g_ch0[3]=6;
        g_ch0[4]=6;  g_ch0[5]=5;  g_ch0[6]=5;
        g_ch0[7]=6;  g_ch0[8]=6;  g_ch0[9]=6;
        g_ch0[10]=6; g_ch0[11]=6; g_ch0[12]=5;

        // ---- golden: run 1 ch1 (D45, abs=10, codes 67,61) ----
        g_ch1a[0]=10;
        for (i=1;  i<=4;  i=i+1) g_ch1a[i]=10;   // g1 d0 (0)
        for (i=5;  i<=8;  i=i+1) g_ch1a[i]=11;   // g1 d1 (+1)
        for (i=9;  i<=12; i=i+1) g_ch1a[i]=11;   // g1 d2 (0)
        for (i=13; i<=16; i=i+1) g_ch1a[i]=11;   // g2 d0 (0)
        for (i=17; i<=20; i=i+1) g_ch1a[i]=11;   // g2 d1 (0)
        for (i=21; i<=24; i=i+1) g_ch1a[i]=10;   // g2 d2 (-1)

        // ---- golden: run 2 ch1 (D25, abs=8, codes 87,57,67) ----
        g_ch1b[0]=8;
        g_ch1b[1]=9;  g_ch1b[2]=9;   // g1 d0 (+1)
        g_ch1b[3]=9;  g_ch1b[4]=9;   // g1 d1 (0)
        g_ch1b[5]=9;  g_ch1b[6]=9;   // g1 d2 (0)
        g_ch1b[7]=9;  g_ch1b[8]=9;   // g2 d0 (0)
        g_ch1b[9]=8;  g_ch1b[10]=8;  // g2 d1 (-1)
        g_ch1b[11]=8; g_ch1b[12]=8;  // g2 d2 (0)
        g_ch1b[13]=8; g_ch1b[14]=8;  // g3 d0 (0)
        g_ch1b[15]=9; g_ch1b[16]=9;  // g3 d1 (+1)
        g_ch1b[17]=9; g_ch1b[18]=9;  // g3 d2 (0)

        repeat (4) @(negedge clk);
        rst = 0;
        @(negedge clk);

        // ================= RUN 1 =================
        // ch0: D15, nchgrps=4, abs=5, codes 67,57,87,61
        chexpstr[1:0] = 2'd1; nchgrps[6:0] = 7'd4;
        pmem[0] = 5;
        pmem[1] = 67; pmem[2] = 57; pmem[3] = 87; pmem[4] = 61;
        // ch1: D45, nchgrps=2, abs=10, codes 67,61
        chexpstr[3:2] = 2'd3; nchgrps[13:7] = 7'd2;
        pmem[128] = 10;
        pmem[129] = 67; pmem[130] = 61;

        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        wait (done); @(posedge clk);

        for (i = 0; i <= 12; i = i + 1) chk_exp(1'b0, i[7:0], g_ch0[i]);
        for (i = 0; i <= 24; i = i + 1) chk_exp(1'b1, i[7:0], g_ch1a[i]);

        // ================= RUN 2 =================
        // ch0: REUSE (retain run-1 ch0); ch1: D25, nchgrps=3, abs=8, codes 87,57,67
        chexpstr[1:0] = 2'd0;                    // reuse
        chexpstr[3:2] = 2'd2; nchgrps[13:7] = 7'd3;
        pmem[128] = 8;
        pmem[129] = 87; pmem[130] = 57; pmem[131] = 67;

        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        wait (done); @(posedge clk);

        // ch0 must be unchanged (reuse retains the previous block's exponents)
        for (i = 0; i <= 12; i = i + 1) chk_exp(1'b0, i[7:0], g_ch0[i]);
        // ch1 is the freshly decoded D25 set
        for (i = 0; i <= 18; i = i + 1) chk_exp(1'b1, i[7:0], g_ch1b[i]);

        $display("exponent_decode_tb: %0d errors", errors);
        $display("RESULT: %0s", (errors == 0) ? "PASS" : "FAIL");
        if (errors != 0) $fatal(1, "exponent_decode_tb FAILED");
        $finish;
    end

    initial begin
        #500000;
        $display("RESULT: FAIL (timeout)");
        $fatal(1, "exponent_decode_tb timeout");
    end

endmodule
