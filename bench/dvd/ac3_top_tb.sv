// bench/dvd/ac3_top_tb.sv -- the whole engine running AC-3 (dts_top, codec 1) against
// the blocks imdct_512 must be handed
//
// Feeds STEM.frames and STEM.bytes (tools/ac3_golden.py) into dts_top with optional input
// stalls (+stall=N). At each imdct_req it reads the block out of the X buffer through
// coef_ra / coef_q and scores it against STEM.coef (the emulator's blocks, which
// ac3_golden.py has checked against the model, and with --rtl-gold against dvd/ac3's own
// dump), then gives imdct_go and waits for imdct_fin: the engine transforms the block
// itself (docs/imdct_engine.md), so the frame times below include the real IMDCT. Its
// PCM is scored against imdct_512 by run_ac3_ab.sh and run_imdct_eng.sh.
// Arms: [side] a block's blksw / dynrng / acmod / lfeon / cmixlev / surmixlev differs;
// [coef] a coefficient differs (named by block, channel, bin), or its 25-bit word is not
// the 24-bit value sign-extended; [count] blocks, frames, refusals, overrun bits or
// bytes taken; [hang] no progress. It reports each frame's cycles against 864,000 (a
// frame's 32 ms at 27 MHz), and with +budget=P fails [budget] if one exceeds P %.
// +xjunk fills the X buffer with random words first -- what a DTS track leaves there --
// so a coefficient the engine fails to write in a block (a missing CZERO tail, a bin
// AQ skips) is visible from block 0, not hidden by the power-up zeros.

`default_nettype none
`timescale 1ns/1ps

module ac3_top_tb;
    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    logic [15:0] fr_len;
    logic        fr_valid, fr_ready;
    logic [7:0]  in_byte;
    logic        in_valid, in_ready;
    logic        cb_req, cb_sel;
    logic [11:0] cb_addr;
    logic [15:0] pcm_l, pcm_r;
    logic        pcm_valid;
    logic [15:0] frames, refused, overrun_bits, lenient_codes, dmix_ignored;
    logic [4:0]  last_err;
    logic [31:0] err_seen;
    logic        vop_start, vop_done, tr_valid;
    logic [5:0]  vop_op;
    logic [10:0] tr_pc, tr_addr;
    logic [1:0]  tr_kind;
    logic [23:0] tr_val;
    logic        imdct_req, imdct_go, imdct_fin;
    logic [10:0] coef_ra;
    logic [24:0] coef_q;
    logic [4:0]  blk_blksw;
    logic [7:0]  blk_dynrng;
    logic [2:0]  blk_acmod;
    logic        blk_lfeon;
    logic [1:0]  blk_cmix, blk_surmix;

    dts_top dut (
        .clk, .rst_n, .codec(2'd1), .fr_len, .fr_valid, .fr_ready, .in_byte, .in_valid, .in_ready,
        .cb_req, .cb_sel, .cb_addr, .cb_valid(1'b0), .cb_data(64'd0),
        .pcm_l, .pcm_r, .pcm_valid, .pcm_ready(1'b1),
        .frames, .refused, .last_err, .err_seen, .overrun_bits, .lenient_codes,
        .dmix_ignored,
        .imdct_req, .imdct_go, .imdct_fin, .pcm_ra(9'd0), .pcm_q(), .coef_ra, .coef_q, .blk_blksw, .blk_dynrng, .blk_acmod,
        .blk_lfeon, .blk_cmix, .blk_surmix,
        .vop_start, .vop_op, .vop_done,
        .tr_valid, .tr_pc, .tr_kind, .tr_addr, .tr_val);

    string stem;
    int stall, budget;
    logic [7:0]  bytes [];
    logic [15:0] flen [];
    int n_bytes, n_frames, n_ev, n_x1, n_x2, n_err, n_ovr, n_x3, n_x4, n_blk, cfd;
    int bi, fi, gap, fgap;

    initial begin
        int fd, r;
        logic [31:0] v;
        if (!$value$plusargs("stem=%s", stem)) $fatal(1, "FAIL [setup] no +stem");
        if (!$value$plusargs("stall=%d", stall)) stall = 0;
        if (!$value$plusargs("budget=%d", budget)) budget = 0;
        fd = $fopen({stem, ".meta"}, "r");
        if (fd == 0) $fatal(1, "FAIL [setup] no %s.meta", stem);
        r = $fscanf(fd, "%d %d %d %d %d %d %d %d %d", n_bytes, n_frames, n_ev, n_x1, n_x2,
                    n_err, n_ovr, n_x3, n_x4);
        $fclose(fd);
        bytes = new[n_bytes];
        flen = new[n_frames];
        fd = $fopen({stem, ".bytes"}, "r");
        for (int i = 0; i < n_bytes; i++) begin r = $fscanf(fd, "%h", v); bytes[i] = v[7:0]; end
        $fclose(fd);
        fd = $fopen({stem, ".frames"}, "r");
        for (int i = 0; i < n_frames; i++) begin r = $fscanf(fd, "%h", v); flen[i] = v[15:0]; end
        $fclose(fd);
        #1;
        if ($test$plusargs("xjunk"))
            for (int i = 0; i < 2048; i++) dut.u_vec.xb[i] = $urandom;
        cfd = $fopen({stem, ".coef"}, "r");
        if (cfd == 0) $fatal(1, "FAIL [setup] no %s.coef", stem);
        r = $fscanf(cfd, "%h", n_blk);
    end

    // the descriptor and byte sources (as dts_seq_tb)
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fi <= 0; fgap <= 0; fr_valid <= 1'b0;
        end else begin
            if (fr_valid && fr_ready) begin
                fi <= fi + 1; fr_valid <= 1'b0;
                fgap <= (stall > 0) ? ($urandom % (stall + 1)) : 0;
            end else if (!fr_valid && fi < n_frames) begin
                if (fgap > 0) fgap <= fgap - 1;
                else begin fr_valid <= 1'b1; fr_len <= flen[fi]; end
            end
        end
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bi <= 0; gap <= 0; in_valid <= 1'b0;
        end else begin
            if (in_valid && in_ready) begin
                bi <= bi + 1; in_valid <= 1'b0;
                gap <= (stall > 0) ? ($urandom % (stall + 1)) : 0;
            end else if (!in_valid && bi < n_bytes) begin
                if (gap > 0) gap <= gap - 1;
                else begin in_valid <= 1'b1; in_byte <= bytes[bi]; end
            end
        end
    end

    // the block out of X, scored; then the engine's own transform
    int blk, nwords, ri, wait_n, e_nf, e_lfe, e_blksw, e_dyn, e_acmod, e_cmix, e_sur;
    logic busy, rd_v, rd_v2, armed;          // a word's address out; its data in (2 later)
    logic [10:0] rd_a, rd_a2;
    logic [23:0] e_coef;
    always @(posedge clk) begin
        imdct_go <= 1'b0;
        if (!rst_n) begin
            blk = 0; busy <= 1'b0; rd_v <= 1'b0; rd_v2 <= 1'b0; coef_ra <= 11'd0; armed <= 1'b1;
        end else begin
            // the word addressed two cycles ago (coef_ra, then X's registered read)
            rd_v2 <= rd_v; rd_a2 <= rd_a;
            if (!imdct_req) armed <= 1'b1;
            if (rd_v2) begin
                if ($fscanf(cfd, "%h", e_coef) != 1)
                    $fatal(1, "FAIL [count] STEM.coef ends inside block %0d", blk);
                if (coef_q[24] != coef_q[23])
                    $fatal(1, "FAIL [coef] block %0d slot %0d bin %0d: word %07x is not sign-extended",
                           blk, rd_a2[10:8], rd_a2[7:0], coef_q);
                if (coef_q[23:0] !== e_coef)
                    $fatal(1, "FAIL [coef] block %0d slot %0d bin %0d: rtl %06x, expected %06x",
                           blk, rd_a2[10:8], rd_a2[7:0], coef_q[23:0], e_coef);
            end
            rd_v <= 1'b0;
            if (imdct_req && armed && !busy) begin
                armed <= 1'b0;
                if (blk >= n_blk)
                    $fatal(1, "FAIL [count] a block past the golden's %0d", n_blk);
                if ($fscanf(cfd, "%h %h %h %h %h %h %h", e_nf, e_lfe, e_blksw, e_dyn, e_acmod,
                            e_cmix, e_sur) != 7)
                    $fatal(1, "FAIL [count] STEM.coef has no header for block %0d", blk);
                if ({blk_blksw, blk_dynrng, blk_acmod, blk_lfeon, blk_cmix, blk_surmix} !==
                    {e_blksw[4:0], e_dyn[7:0], e_acmod[2:0], e_lfe[0], e_cmix[1:0], e_sur[1:0]})
                    $fatal(1, "FAIL [side] block %0d: rtl blksw %02x dynrng %02x acmod %0d lfeon %0d cmix %0d surmix %0d, expected %02x %02x %0d %0d %0d %0d",
                           blk, blk_blksw, blk_dynrng, blk_acmod, blk_lfeon, blk_cmix, blk_surmix,
                           e_blksw, e_dyn, e_acmod, e_lfe, e_cmix, e_sur);
                nwords = e_nf * 256 + (e_lfe ? 7 : 0);
                ri = 0;
                wait_n = 0;
                busy <= 1'b1;
            end
            if (busy) begin
                if (ri < nwords) begin
                    coef_ra <= (ri < e_nf * 256) ? {ri[10:8], ri[7:0]} : {3'd6, 8'(ri - e_nf * 256)};
                    rd_a <= (ri < e_nf * 256) ? {ri[10:8], ri[7:0]} : {3'd6, 8'(ri - e_nf * 256)};
                    rd_v <= 1'b1;
                    ri = ri + 1;
                end else if (ri < nwords + 3) ri = ri + 1;          // the last word lands
                else if (wait_n == 0) begin imdct_go <= 1'b1; wait_n = 1; end   // the transform
                else if (imdct_fin) begin busy <= 1'b0; blk = blk + 1; end
                else if (++wait_n > 400000) $fatal(1, "FAIL [hang] block %0d: no imdct_fin", blk);
            end
        end
    end

    // the scoreboard and the frame clock
    int nfr, errs, last_ev, quiet, idle, cyc, fstart, worst;
    longint ftot;
    always @(posedge clk) begin
        if (!rst_n) begin
            nfr = 0; errs = 0; fstart = 0; worst = 0; ftot = 0;
        end else if (dut.frame_done || dut.err_valid) begin
            if (dut.frame_done) nfr++; else errs++;
            if (cyc - fstart > worst) worst = cyc - fstart;
            ftot += cyc - fstart;
            fstart = cyc;
        end
    end
    // a frame's clock starts when the engine takes its descriptor
    always @(posedge clk) if (rst_n && fr_valid && fr_ready) fstart = cyc;

    initial begin
        cyc = 0; idle = 0; last_ev = 0; quiet = 0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        forever begin
            @(posedge clk);
            cyc++;
            if (fi == n_frames && fr_ready && !busy) idle++; else idle = 0;
            if (idle > 64) begin
                if (blk != n_blk) $fatal(1, "FAIL [count] %0d of %0d blocks", blk, n_blk);
                if (nfr != n_frames - n_err)
                    $fatal(1, "FAIL [count] %0d frames decoded, the golden %0d", nfr, n_frames - n_err);
                if (errs != n_err) $fatal(1, "FAIL [count] %0d refusals, the golden %0d", errs, n_err);
                if (overrun_bits != n_ovr)
                    $fatal(1, "FAIL [count] %0d overrun bits, the golden %0d", overrun_bits, n_ovr);
                if (bi != n_bytes) $fatal(1, "FAIL [count] %0d of %0d bytes taken", bi, n_bytes);
                $display("ac3_top_tb: %0d bytes, %0d blocks, %0d frames, %0d refusals, %0d overrun bits; worst frame %0d cycles (%0d.%0d %% of real time), mean %0d",
                         n_bytes, blk, nfr, errs, overrun_bits, worst, worst * 100 / 864000,
                         (worst * 1000 / 864000) % 10, ftot / n_frames);
                if (budget > 0 && worst * 100 > budget * 864000)
                    $fatal(1, "FAIL [budget] the worst frame needs more than %0d %% of real time", budget);
                $display("PASS: ac3_top_tb");
                $finish;
            end
        end
    end
    // [hang]: no block and no byte for 400,000 cycles while input remains
    int still;
    always @(posedge clk) begin
        if (!rst_n) still = 0;
        else if ((in_valid && in_ready) || imdct_fin || (fr_valid && fr_ready)) still = 0;
        else if (!(fi == n_frames && fr_ready)) begin
            still++;
            if (still > 400000)
                $fatal(1, "FAIL [hang] at block %0d of %0d, byte %0d, frame %0d", blk, n_blk, bi, fi);
        end
    end
endmodule
