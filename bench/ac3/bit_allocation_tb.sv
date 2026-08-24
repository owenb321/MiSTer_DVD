//============================================================================
//  bit_allocation_tb.sv — standalone iverilog TB for bit_allocation (M6).
//
//  Drives bit_allocation directly with a behavioural exponent + delta-ba
//  provider (mem files emitted by gen_balloc_vec.c, which also produced the
//  golden bap via liba52's a52_bit_allocate()).  Checks every block-0 bap
//  against that golden for both channels — including the DELTA_BIT_NEW channel
//  the streaming co-sim never exercises.  Run via bench/ac3/run_balloc.sh.
//============================================================================
`timescale 1ns/1ps

module bit_allocation_tb;
    logic clk = 0, rst = 1, start = 0;
    always #5 clk = ~clk;

    // ---- behavioural providers loaded from the generator's mem files ----
    logic [4:0]        exp_prov [0:511];
    logic signed [3:0] dba_prov [0:127];
    logic signed [7:0] gold     [0:511];
    logic [15:0]       params   [0:15];

    initial begin
        $readmemh("balloc_exp.mem",    exp_prov);
        $readmemh("balloc_deltba.mem", dba_prov);
        $readmemh("balloc_golden.mem", gold);
        $readmemh("balloc_params.mem", params);
    end

    wire [8:0] endmant0 = params[0][8:0];
    wire [8:0] endmant1 = params[1][8:0];
    wire [1:0] sdcycod  = params[2][1:0];
    wire [1:0] fdcycod  = params[3][1:0];
    wire [1:0] sgaincod = params[4][1:0];
    wire [1:0] dbpbcod  = params[5][1:0];
    wire [2:0] floorcod = params[6][2:0];
    wire [5:0] csnroffst= params[7][5:0];
    wire [3:0] fsnroffst0 = params[8][3:0];
    wire [2:0] fgaincod0  = params[9][2:0];
    wire [3:0] fsnroffst1 = params[10][3:0];
    wire [2:0] fgaincod1  = params[11][2:0];
    wire [1:0] deltbae0 = params[12][1:0];
    wire [1:0] deltbae1 = params[13][1:0];

    // ---- M14 packed buses (2 fbw channels; coupling/LFE unused here) ----
    wire [44:0] endmant   = {{27{1'b0}}, endmant1, endmant0};   // 9 bits/ch
    wire [19:0] fsnroffst = {{12{1'b0}}, fsnroffst1, fsnroffst0}; // 4 bits/ch
    wire [14:0] fgaincod  = {{9{1'b0}}, fgaincod1, fgaincod0};   // 3 bits/ch
    wire [9:0]  deltbae   = {{6{1'b0}}, deltbae1, deltbae0};     // 2 bits/ch

    // ---- DUT <-> provider wiring ---- (ba_exp/bap addrs now 11-bit; ch 5 = cpl,
    // 6 = LFE, unused here — chincpl=0 disables coupling, lfeon=0 disables LFE.)
    wire [10:0] ba_exp_rd_addr;
    // exp now comes from exponent_decode's M10K (registered, 1-cycle latency);
    // model that here so the prefetch pipeline (C_COPY/C_CCOPY) is exercised as
    // it is in hardware.  deltba stays combinational (audblk_parse.deltba_mem).
    reg  [4:0]  ba_exp_rd_data;
    always @(posedge clk) ba_exp_rd_data <= exp_prov[ba_exp_rd_addr[8:0]];
    wire [8:0]  deltba_rd_addr;
    wire signed [3:0] deltba_rd_data = dba_prov[deltba_rd_addr];

    logic [10:0] bap_rd_addr = 11'd0;
    wire  signed [7:0] bap_rd_data;
    wire        done;

    bit_allocation dut (
        .clk(clk), .rst(rst), .start(start),
        .nfchans(3'd2), .lfeon(1'b0),
        .endmant(endmant),
        .sdcycod(sdcycod), .fdcycod(fdcycod), .sgaincod(sgaincod),
        .dbpbcod(dbpbcod), .floorcod(floorcod),
        .csnroffst(csnroffst),
        .fsnroffst(fsnroffst), .fgaincod(fgaincod),
        .deltbae(deltbae),
        .lfeba_bai(7'd0),
        .chincpl(5'd0), .cplstrtmant(9'd0), .cplendmant(9'd0),
        .cplstrtbnd(6'd0), .cplfleak(4'd0), .cplsleak(4'd0), .cplba_bai(7'd0),
        .ba_exp_rd_addr(ba_exp_rd_addr), .ba_exp_rd_data(ba_exp_rd_data),
        .deltba_rd_addr(deltba_rd_addr), .deltba_rd_data(deltba_rd_data),
        .bap_rd_addr(bap_rd_addr), .bap_rd_data(bap_rd_data),
        .mant_bap_rd_addr(11'd0), .mant_bap_rd_data(),
        .done(done)
    );

    integer errors = 0;
    integer ch, idx, em;

    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("bit_allocation_tb.vcd");
            $dumpvars(0, bit_allocation_tb);
        end

        repeat (4) @(posedge clk);
        rst = 0;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        // bit allocation runs for a few hundred cycles; wait for done.
        fork
            begin : wd
                repeat (20000) @(posedge clk);
                $display("TIMEOUT waiting for done");
                $fatal(1);
            end
            begin
                @(posedge done);
                disable wd;
            end
        join

        @(posedge clk);
        // ---- compare every bap against the liba52 golden ----
        for (ch = 0; ch < 2; ch = ch + 1) begin
            em = ch ? endmant1 : endmant0;
            for (idx = 0; idx < em; idx = idx + 1) begin
                bap_rd_addr = (ch << 8) | idx;
                #1;
                if (bap_rd_data !== gold[(ch << 8) | idx]) begin
                    if (errors < 12)
                        $display("MISMATCH ch%0d bap[%0d]: dut=%0d golden=%0d",
                                 ch, idx, bap_rd_data, gold[(ch << 8) | idx]);
                    errors = errors + 1;
                end
            end
        end

        if (errors == 0)
            $display("bit_allocation_tb: PASS (bap bit-exact vs liba52, endmant=%0d,%0d)",
                     endmant0, endmant1);
        else
            $display("bit_allocation_tb: FAIL (%0d mismatches)", errors);
        $finish;
    end
endmodule
