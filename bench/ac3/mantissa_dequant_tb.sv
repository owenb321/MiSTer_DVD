//============================================================================
//  mantissa_dequant_tb.sv — standalone iverilog TB for mantissa_dequant (M7).
//
//  Chain: FIFO -> bit_reader -> mantissa_dequant, with the per-coefficient
//  exp[]/bap[] supplied by behavioural providers (mem files from gen_mant_vec.c,
//  which also emitted the mantissa bitstream and the two goldens).  The DUT
//  pulls the mantissa bits, dequantizes, and writes coeff_mem; we then:
//    - check every coeff BIT-EXACT against mant_gold_fixed.mem (the exact Q1.23
//      the RTL must compute) — proves the ungroup/cache/scale/dither logic, and
//    - measure max |dut − mant_goldf.mem| (liba52 float, Q1.23) to bound the
//      fixed-point quantization error (architecture.md §5).
//
//  Run via bench/ac3/run_mantissa.sh.
//============================================================================
`timescale 1ns/1ps

module mantissa_dequant_tb;
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    // ---- vectors from the generator ----
    logic [7:0]         mbits  [0:8191];
    logic [4:0]         exp_p  [0:511];
    logic signed [7:0]  bap_p  [0:511];
    logic signed [23:0] goldx  [0:511];   // exact fixed-point target
    logic signed [23:0] goldf  [0:511];   // liba52 float reference
    logic [15:0]        params [0:7];

    initial begin
        $readmemh("mant_bits.mem",        mbits);
        $readmemh("mant_exp.mem",         exp_p);
        $readmemh("mant_bap.mem",         bap_p);
        $readmemh("mant_gold_fixed.mem",  goldx);
        $readmemh("mant_goldf.mem",       goldf);
        $readmemh("mant_params.mem",      params);
    end

    wire [8:0] endmant0 = params[0][8:0];
    wire [8:0] endmant1 = params[1][8:0];
    wire [15:0] nbytes  = params[3];

    // ---- M14 packed buses (2 fbw channels; coupling/LFE unused here) ----
    wire [44:0] endmant  = {{27{1'b0}}, endmant1, endmant0};   // 9 bits/ch
    wire [4:0]  dithflag = {3'd0, params[2][1:0]};             // 1 bit/ch

    // ---- feed the mantissa bitstream into the FIFO ----
    logic        full, wr;
    logic [7:0]  wdata;
    integer      fed = 0;
    wire [15:0]  feed_n = nbytes + 16'd8;   // a few pad bytes past the stream
    assign wr    = (!rst) && (fed < feed_n) && !full;
    assign wdata = (fed < nbytes) ? mbits[fed] : 8'h00;
    always_ff @(posedge clk) if (rst) fed <= 0; else if (wr) fed <= fed + 1;

    // ---- DUT chain ----
    logic        start = 0;
    logic [7:0]  fdout; logic fempty, frd;
    logic        br_req; logic [5:0] br_nbits; logic br_ack;
    logic [31:0] br_data, br_bitpos;

    // M14: mant exp/bap/coeff addrs are 11-bit (ch 5 = cpl, 6 = LFE, unused here).
    wire [10:0]  mant_exp_rd_addr;
    wire [4:0]   mant_exp_rd_data = exp_p[mant_exp_rd_addr[8:0]];
    wire [10:0]  mant_bap_rd_addr;
    wire signed [7:0] mant_bap_rd_data = bap_p[mant_bap_rd_addr[8:0]];

    logic [10:0] coeff_rd_addr = 11'd0;
    wire signed [23:0] coeff_rd_data;
    wire         done;

    bit_fifo #(.DW(8), .DEPTH(2048)) u_fifo (
        .clk(clk), .rst(rst), .wr_en(wr), .wr_data(wdata), .full(full),
        .rd_data(fdout), .empty(fempty), .rd_en(frd));

    bit_reader #(.MAXW(32)) u_reader (
        .clk(clk), .rst(rst), .fifo_dout(fdout), .fifo_empty(fempty), .fifo_rd(frd),
        .req(br_req), .nbits(br_nbits), .ack(br_ack), .data(br_data), .bitpos(br_bitpos));

    // M12 coupling is not exercised by this TB: chincpl=0 (no coupling pass),
    // rematflg=0 (no rematrixing).
    mantissa_dequant dut (
        .clk(clk), .rst(rst), .start(start),
        .nfchans(3'd2), .lfeon(1'b0),
        .endmant(endmant), .dithflag(dithflag),
        .chincpl(5'd0), .cplstrtmant(9'd0), .cplendmant(9'd0),
        .cplbndstrc(18'd0), .rematflg(4'd0),
        .cplco_rd_addr(), .cplco_rd_data(24'sd0),
        .req(br_req), .nbits(br_nbits), .ack(br_ack), .data_in(br_data),
        .mant_exp_rd_addr(mant_exp_rd_addr), .mant_exp_rd_data(mant_exp_rd_data),
        .mant_bap_rd_addr(mant_bap_rd_addr), .mant_bap_rd_data(mant_bap_rd_data),
        .coeff_rd_addr(coeff_rd_addr), .coeff_rd_data(coeff_rd_data),
        .coeff_rd2_addr(11'd0), .coeff_rd2_data(),
        .done(done));

    integer errors = 0;
    integer ch, idx, em, a, d, maxerr = 0;

    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("mantissa_dequant_tb.vcd");
            $dumpvars(0, mantissa_dequant_tb);
        end

        repeat (6) @(posedge clk);
        rst = 0;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        fork
            begin : wd
                repeat (200000) @(posedge clk);
                $display("RESULT: FAIL (timeout waiting for done)");
                $fatal(1);
            end
            begin @(posedge done); disable wd; end
        join

        @(posedge clk);
        // ---- compare every coefficient ----
        for (ch = 0; ch < 2; ch = ch + 1) begin
            em = ch ? endmant1 : endmant0;
            // active coeffs + the HF zero-fill tail (must be 0 through 255)
            for (idx = 0; idx < 256; idx = idx + 1) begin
                coeff_rd_addr = (ch << 8) | idx;
                #1;
                // exact (bit-for-bit) check vs the RTL-equivalent golden
                if (coeff_rd_data !== goldx[(ch << 8) | idx]) begin
                    if (errors < 16)
                        $display("MISMATCH ch%0d coeff[%0d]: dut=%0d golden=%0d (bap=%0d exp=%0d)",
                                 ch, idx, coeff_rd_data, goldx[(ch << 8) | idx],
                                 bap_p[(ch<<8)|idx], exp_p[(ch<<8)|idx]);
                    errors = errors + 1;
                end
                // error budget vs liba52 float
                d = coeff_rd_data - goldf[(ch << 8) | idx];
                if (d < 0) d = -d;
                if (idx < em && d > maxerr) maxerr = d;
            end
        end

        $display("mantissa_dequant_tb: max |dut-liba52_float| = %0d LSB @ Q1.23 (%g abs)",
                 maxerr, maxerr / 8388608.0);
        if (errors == 0)
            $display("RESULT: PASS (coeff bit-exact vs RTL golden; endmant=%0d,%0d)",
                     endmant0, endmant1);
        else
            $display("RESULT: FAIL (%0d coeff mismatches)", errors);
        if (errors != 0) $fatal(1, "mantissa_dequant_tb FAILED");
        $finish;
    end
endmodule
