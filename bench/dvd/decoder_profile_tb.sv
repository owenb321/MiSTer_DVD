// =============================================================================
// bench/dvd/decoder_profile_tb.sv — verify dvd/decoder_profile.sv duty windows
// =============================================================================
// Drives the four tapped backpressure/starvation signals with known duty cycles
// and checks the windowed 8-bit fractions land where expected. The profiler
// localizes the high-motion decode bottleneck (memory: cache-missrate-row6
// proved COMPUTE; this says which COMPUTE stage). Output packing:
//   prof0 = {idct_fifo_af%, mvec_af%}   prof1 = {idct_empty%, rld_af%}
// =============================================================================
`timescale 1ns/1ps
module decoder_profile_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg ifaf = 0, mvaf = 0, empt = 0, rdaf = 0;
    wire [15:0] prof0, prof1;

    // rdaf drives the 4th signal — now recon_ref_stall (precise reference-feed stall)
    decoder_profile dut (
        .clk(clk), .rst_n(rst_n),
        .idct_fifo_almost_full(ifaf),
        .mvec_wr_almost_full(mvaf),
        .recon_ref_stall(rdaf),
        .idct_rd_dta_empty(empt),
        .prof0(prof0), .prof1(prof1)
    );

    integer errors = 0;
    localparam integer WIN = 65536;

    task check(input [127:0] name, input [7:0] got, input [7:0] lo, input [7:0] hi);
        begin
            if (got < lo || got > hi) begin
                $display("  FAIL %0s: 0x%02h (%0d) not in [%0d..%0d]", name, got, got, lo, hi);
                errors = errors + 1;
            end else
                $display("  ok   %0s: 0x%02h (%0d) in [%0d..%0d]", name, got, got, lo, hi);
        end
    endtask

    // hold the four inputs at fixed duty patterns for two full windows, then sample.
    // duty is set by asserting on a modulo of a free cycle counter.
    integer fc = 0;
    integer m_ifaf=1, m_mvaf=1, m_empt=1, m_rdaf=1;  // assert when (fc % m)==0  => 1/m duty
    always @(posedge clk) begin
        fc <= fc + 1;
        ifaf <= (m_ifaf > 0) && ((fc % m_ifaf) == 0);
        mvaf <= (m_mvaf > 0) && ((fc % m_mvaf) == 0);
        empt <= (m_empt > 0) && ((fc % m_empt) == 0);
        rdaf <= (m_rdaf > 0) && ((fc % m_rdaf) == 0);
    end

    task set_duty(input integer a, input integer b, input integer c, input integer d);
        begin m_ifaf=a; m_mvaf=b; m_empt=c; m_rdaf=d; end
    endtask

    initial begin
        rst_n = 0; repeat (5) @(posedge clk); rst_n = 1;

        // Phase 1: ifaf=100% (m=1), mvaf=0 (m=0), empt=50% (m=2), rdaf=25% (m=4).
        // Expect ifaf%~0xFF, mvaf%~0x00, empt%~0x80, rdaf%~0x40.
        set_duty(1, 0, 2, 4);
        repeat (2*WIN + 1000) @(posedge clk);
        check("ifaf 100%", prof0[15:8], 8'hFA, 8'hFF);
        check("mvaf   0%", prof0[7:0],  8'h00, 8'h02);
        check("empt  50%", prof1[15:8], 8'h78, 8'h88);
        check("rdaf  25%", prof1[7:0],  8'h38, 8'h48);

        // Phase 2: swap roles — mvaf high (motcomp MV-bound signature), others low.
        // ifaf=0, mvaf=100%, empt=0, rdaf=0. Expect prof0 lo ~0xFF, all others ~0.
        set_duty(0, 1, 0, 0);
        repeat (2*WIN + 1000) @(posedge clk);
        check("ifaf->0  ", prof0[15:8], 8'h00, 8'h02);
        check("mvaf 100%", prof0[7:0],  8'hFA, 8'hFF);
        check("empt->0  ", prof1[15:8], 8'h00, 8'h02);
        check("rdaf->0  ", prof1[7:0],  8'h00, 8'h02);

        $display("=================================================");
        if (errors == 0) $display("  RESULT: PASS");
        else             $display("  RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("  RESULT: FAIL — global timeout");
        $finish;
    end
endmodule
