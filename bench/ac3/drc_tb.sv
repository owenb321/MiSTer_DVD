//============================================================================
//  drc_tb.sv — standalone unit test for the M17 DRC (dynrng) path in imdct_512.
//
//  Identical harness to imdct_512_tb.sv, but runs NCASE independent blocks, each
//  with a different `dynrng` word (drc_dynrng.mem) applied to both channels.  The
//  golden (drc_golden.mem, from gen_drc_vec.c) is liba52's a52_imdct_512 of the
//  coeffs pre-scaled by the canonical dynrng gain; the dut gets the UNSCALED
//  coeffs (drc_coeff.mem) + the dynrng word and must reproduce it within the
//  usual fixed-point IMDCT tolerance.  Each case is reset first (zero delay line
//  = block 0), so cases are independent and the gain decode is checked across the
//  full -24..+24 dB range, including the unity (0x80) bit-exact-identity case.
//============================================================================
`timescale 1ns/1ps

module drc_tb;
    localparam integer NCASE = 6;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst;

    // NCASE blocks of 2 ch × 256 coeffs/golden, packed [case*512 + ch*256 + idx].
    logic signed [23:0] coeff_src [0:NCASE*512-1];
    logic signed [31:0] golden    [0:NCASE*512-1];
    logic [7:0]         dyn_src   [0:NCASE-1];

    integer cur_case;   // selects the 512-entry window for the active block

    logic [10:0] coeff_rd_addr;
    logic signed [23:0] coeff_rd_data;
    // 1-cycle synchronous read latency (models mantissa_dequant.coeff_mem M10K).
    always_ff @(posedge clk)
        coeff_rd_data <= coeff_src[cur_case*512 + coeff_rd_addr[8:0]];

    logic [10:0] pcm_rd_addr;
    logic signed [31:0] pcm_rd_data;
    logic        start, done;
    logic [7:0]  dynrng;

    imdct_512 dut (
        .clk(clk), .rst(rst),
        .start(start),
        .nfchans(3'd2), .blksw(5'd0), .dynrng(dynrng), .cmixlev(2'd0), .surmixlev(2'd0),
        .coeff_rd_addr(coeff_rd_addr), .coeff_rd_data(coeff_rd_data),
        .pcm_rd_addr(pcm_rd_addr), .pcm_rd_data(pcm_rd_data),
        .done(done)
    );

    // Tolerance scales with the gain: the fixed-point IMDCT error is proportional
    // to signal magnitude, and a +24 dB block is ~15.75× louder.  The coeffs are
    // kept to |·|<1/8 so even ×15.75 stays < 1.0 (output bounded like the unity
    // torture vector ⇒ base ~1700 LSB), but allow generous head-room per case.  A
    // FORMULA error (wrong shift/mantissa) mis-scales by a power of two and blows
    // way past this; precision is pinned tightly by the unity case + imdct_512_tb.
    localparam integer TOL_LSB = 8000;

    integer c, k, errs, maxerr, e, timeout, base;
    initial begin
        $readmemh("drc_coeff.mem",  coeff_src);
        $readmemh("drc_golden.mem", golden);
        $readmemh("drc_dynrng.mem", dyn_src);

        errs = 0; maxerr = 0;
        start = 0; pcm_rd_addr = 0;

        for (c = 0; c < NCASE; c = c + 1) begin
            cur_case = c;
            dynrng   = dyn_src[c];

            // reset → fresh zero delay line (this case is an independent block 0)
            rst = 1; repeat (4) @(posedge clk); rst = 0; @(posedge clk);
            start = 1; @(posedge clk); start = 0;

            timeout = 0;
            while (!done && timeout < 200000) begin @(posedge clk); timeout = timeout + 1; end
            if (!done) begin
                $display("FAIL: case %0d (dynrng=0x%02h) never asserted done", c, dyn_src[c]);
                $fatal;
            end

            base = c*512;
            for (k = 0; k < 512; k = k + 1) begin
                pcm_rd_addr = k[10:0];
                #1;
                e = pcm_rd_data - golden[base + k];
                if (e < 0) e = -e;
                if (e > maxerr) maxerr = e;
                if (e > TOL_LSB) begin
                    errs = errs + 1;
                    if (errs <= 10)
                        $display("  mismatch case%0d(dynrng=0x%02h) ch%0d idx%0d: dut=%0d golden=%0d (err=%0d LSB)",
                                 c, dyn_src[c], k[8], k[7:0], pcm_rd_data, golden[base+k], e);
                end
            end
            $display("  case %0d dynrng=0x%02h: done (running max err = %0d LSB)", c, dyn_src[c], maxerr);
        end

        $display("drc: max abs error = %0d Q8.23 LSB (~%e), tol = %0d (%0d cases)",
                 maxerr, maxerr / 8388608.0, TOL_LSB, NCASE);
        if (errs == 0) $display("PASS: DRC (dynrng) within tolerance across all cases");
        else begin
            $display("FAIL: %0d sample(s) exceeded tolerance", errs);
            $fatal(1);   // nonzero exit — a plain $finish let run scripts read FAIL as pass
        end
        $finish;
    end
endmodule
