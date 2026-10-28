// bench/dvd/ac3_ab_tb.sv -- today's AC-3 front end against the engine that replaces it
//
// The same stream into both: dvd/ac3/ac3_front (the decoder that ships, fed the raw
// bytes, finding sync itself) and dvd/audio_engine.sv (the engine + the unchanged
// imdct_512, fed one frame at a time: a descriptor, then its bytes, as
// dvd_audio_decode's dispatcher delivers them). A pcm_out stand-in on each side
// reads every block out of pcm_mem (the registered read port, ch0 and ch1; ch0 alone
// for acmod 1, whose ch1 pcm_out never reads) with the block's lvl_q and acmod, then
// pulses pcm_done after +drain=N cycles (default 600: pcm_out's own read time), so
// the engine's run-ahead against a slow drain is exercised.
// Scores, block by block, in order:
//   [pcm]   a sample differs (named by block, channel, index)
//   [lvl]   lvl_q or acmod differs
//   [count] the block counts differ -- except with +refuse (a refusal window), where
//           only the blocks before the engine's FIRST refusal are compared: from there
//           the two differ by design. ac3_front halts on an out-of-scope field, but
//           decodes an invalid grouped mantissa code through an out-of-range level
//           read (X in simulation, whatever the ROM returns in silicon); the engine
//           refuses that frame and goes on (docs/ac3_engine.md, "invalid codes
//           refused and counted").
//           With +halt (a 1+1 dual-mono stream): ac3_front refuses acmod 0 and halts,
//           the engine decodes it (docs/lpcm_full.md §7). ac3_front must halt, the
//           engine must decode past that point, and the blocks before it are compared.
//   [hang]  no block for 2M cycles while input remains
// STEM.bytes / STEM.frames / STEM.meta ("bytes frames"): bench/dvd/run_ac3_ab.sh.

`default_nettype none
`timescale 1ns/1ps

module ac3_ab_tb;
    logic clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    string stem;
    int drain, refuse, halt, n_bytes, n_frames;
    logic [7:0]  bytes [0:65535];           // a fixed array: icarus cannot read a dynamic one in a port
    logic [15:0] flen [];
    initial begin
        int fd, r;
        logic [31:0] v;
        if (!$value$plusargs("stem=%s", stem)) $fatal(1, "FAIL [setup] no +stem");
        if (!$value$plusargs("drain=%d", drain)) drain = 600;
        refuse = $test$plusargs("refuse");
        halt   = $test$plusargs("halt");
        fd = $fopen({stem, ".meta"}, "r");
        if (fd == 0) $fatal(1, "FAIL [setup] no %s.meta", stem);
        r = $fscanf(fd, "%d %d", n_bytes, n_frames);
        $fclose(fd);
        if (n_bytes > 65536) $fatal(1, "FAIL [setup] %0d bytes: the fixture holds 65,536", n_bytes);
        flen = new[n_frames];
        fd = $fopen({stem, ".bytes"}, "r");
        for (int i = 0; i < n_bytes; i++) begin r = $fscanf(fd, "%h", v); bytes[i] = v[7:0]; end
        $fclose(fd);
        fd = $fopen({stem, ".frames"}, "r");
        for (int i = 0; i < n_frames; i++) begin r = $fscanf(fd, "%h", v); flen[i] = v[15:0]; end
        $fclose(fd);
        // the old side's imdct_512 memories start at zero, as its M10K does at power-up
        // (bench/ac3/imdct_xcheck_tb.sv does the same): a 3/0 fold multiplies a never-written
        // surround slot by slev = 0, which is 0 on silicon and X x 0 = X in simulation. The
        // engine (docs/imdct_engine.md) skips a zero-gain share, so it has no such read.
        for (int k = 0; k < 1536; k++) u_old.u_parse.u_imdct.pcm_mem[k] = 32'sd0;
        for (int k = 0; k < 512; k++) u_old.u_parse.u_imdct.delay_mem[k] = 64'd0;
    end

    // ---------------------------------------------------------------- old: ac3_front
    logic        o_full, o_done, o_pdone, o_err;
    logic [10:0] o_ra;
    logic signed [31:0] o_rd;
    logic [15:0] o_lvl;
    logic [2:0]  o_acmod;
    int          oi;
    wire         o_wr = !rst && (oi < n_bytes) && !o_full;
    wire  [7:0]  o_byte = bytes[oi[15:0]];
    always @(posedge clk) if (rst) oi <= 0; else if (o_wr) oi <= oi + 1;

    ac3_front #(.FIFO_DEPTH(4096)) u_old (
        .clk, .rst, .wr_en(o_wr), .wr_data(o_byte), .full(o_full),
        .synced(), .frame_hdr_valid(), .frame_words(), .frame_bytes(), .fscod(), .frmsizcod(),
        .crc1(), .sync_bitpos(), .bsi_valid(), .bsid(), .bsmod(), .acmod(o_acmod), .dsurmod(),
        .cmixlev(), .surmixlev(), .lfeon(), .dialnorm(), .block_side_valid(), .blk_bits(),
        .chincpl(), .cplstrtmant(), .cplendmant(), .ncplbnd(), .cplstrtbnd(), .phsflginu(),
        .rematflg(), .cplco_rd_addr(8'd0), .cplco_rd_data(), .exp_done(), .dexp_rd_addr(11'd0),
        .dexp_rd_data(), .ba_done(), .bap_rd_addr(11'd0), .bap_rd_data(), .mant_done(),
        .coeff_rd_addr(11'd0), .coeff_rd_data(),
        .imdct_done(o_done), .pcm_rd_addr(o_ra), .pcm_rd_data(o_rd), .lvl_q(o_lvl),
        .pcm_done(o_pdone), .err_unsupported(o_err));

    // ---------------------------------------------------------------- new: the engine
    logic [15:0] fr_len;
    logic        fr_valid, fr_ready, in_valid, in_ready;
    logic [7:0]  in_byte;
    logic        n_done, n_pdone;
    logic [10:0] n_ra;
    logic signed [31:0] n_rd;
    logic [15:0] n_lvl;
    logic [2:0]  n_acmod;
    logic        synced, frame_ok, refused;
    logic [4:0]  err_code;
    logic [15:0] nfr, nref, novr;
    logic [31:0] eseen;

    audio_engine u_new (
        .codec_req(2'd1), .codec_busy(), .mp2_fs(), .n_ignored(), .dts_l(), .dts_r(), .dts_valid(), .dts_ready(1'b1),
        .cb_req(), .cb_sel(), .cb_addr(), .cb_valid(1'b0), .cb_data(64'd0),
        .clk, .rst, .fr_len, .fr_valid, .fr_ready, .in_byte, .in_valid, .in_ready,
        .imdct_done(n_done), .pcm_rd_addr(n_ra), .pcm_rd_data(n_rd), .lvl_q(n_lvl),
        .pcm_acmod(n_acmod), .pcm_done(n_pdone),
        .synced, .frame_ok, .refused, .err_code, .n_frames(nfr), .n_refused(nref),
        .err_seen(eseen), .n_overrun(novr));

    int fi, bi;
    always @(posedge clk) begin
        if (rst) begin
            fi <= 0; bi <= 0; fr_valid <= 1'b0; in_valid <= 1'b0;
        end else begin
            if (fr_valid && fr_ready) begin fr_valid <= 1'b0; fi <= fi + 1; end
            else if (!fr_valid && fi < n_frames) begin
                fr_valid <= 1'b1; fr_len <= flen[fi];
            end
            if (in_valid && in_ready) begin in_valid <= 1'b0; bi <= bi + 1; end
            else if (!in_valid && bi < n_bytes) begin in_valid <= 1'b1; in_byte <= bytes[bi]; end
        end
    end

    // ---------------------------------------------------------------- the stand-ins
    localparam int MAXB = 128;
    logic signed [31:0] pcm [0:1][0:MAXB-1][0:511];
    logic [15:0] lvl [0:1][0:MAXB-1];
    logic [2:0]  acm [0:1][0:MAXB-1];
    int nb [0:1];
    int r_i [0:1], r_w [0:1];
    logic r_on [0:1], r_v1 [0:1], r_v2 [0:1];
    logic [9:0] r_a1 [0:1], r_a2 [0:1];

    task automatic reader(input int s, input logic done, input logic signed [31:0] rd,
                          input logic [15:0] lv, input logic [2:0] am,
                          inout logic [10:0] ra, output logic pdone);
        pdone = 1'b0;
        // the word addressed two edges ago
        if (r_v2[s]) pcm[s][nb[s]][r_a2[s]] = rd;
        r_v2[s] = r_v1[s]; r_a2[s] = r_a1[s]; r_v1[s] = 1'b0;
        if (done) begin
            if (r_on[s]) $fatal(1, "FAIL [count] side %0d: a block before the last was drained", s);
            if (nb[s] >= MAXB) $fatal(1, "FAIL [count] more than %0d blocks", MAXB);
            r_on[s] = 1'b1; r_i[s] = 0; r_w[s] = 0;
            lvl[s][nb[s]] = lv; acm[s][nb[s]] = am;
        end
        if (r_on[s]) begin
            if (r_i[s] < 512) begin
                ra = {2'd0, r_i[s][8], r_i[s][7:0]};    // {ch, idx}: ch0 then ch1
                r_a1[s] = r_i[s][9:0]; r_v1[s] = 1'b1;
                r_i[s]++;
            end else if (r_w[s] < drain) r_w[s]++;
            else begin
                pdone = 1'b1; r_on[s] = 1'b0; nb[s]++;
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            for (int s = 0; s < 2; s++) begin
                nb[s] = 0; r_on[s] = 0; r_v1[s] = 0; r_v2[s] = 0;
            end
            o_pdone <= 1'b0; n_pdone <= 1'b0; o_ra <= 11'd0; n_ra <= 11'd0;
        end else begin
            logic [10:0] a; logic p;
            a = o_ra; reader(0, o_done, o_rd, o_lvl, o_acmod, a, p); o_ra <= a; o_pdone <= p;
            a = n_ra; reader(1, n_done, n_rd, n_lvl, n_acmod, a, p); n_ra <= a; n_pdone <= p;
        end
    end

    // ---------------------------------------------------------------- the score
    int quiet, last0, last1, nstart1, first_ref;
    always @(posedge clk)
        if (rst) begin nstart1 = 0; first_ref = -1; end
        else begin
            if (refused && first_ref < 0) first_ref = nstart1;   // blocks begun before it
            if (n_done) nstart1++;
        end
    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;
        quiet = 0; last0 = 0; last1 = 0;
        forever begin
            @(posedge clk);
            if (nb[0] != last0 || nb[1] != last1) begin quiet = 0; last0 = nb[0]; last1 = nb[1]; end
            else quiet++;
            if (quiet > 2000000) begin
                int n, bad;
                if (oi < n_bytes && !o_err) $fatal(1, "FAIL [hang] ac3_front took %0d of %0d bytes", oi, n_bytes);
                if (bi < n_bytes) $fatal(1, "FAIL [hang] the engine took %0d of %0d bytes", bi, n_bytes);
                if (!refuse && !halt && nb[0] != nb[1])
                    $fatal(1, "FAIL [count] ac3_front %0d blocks, the engine %0d", nb[0], nb[1]);
                n = nb[0];
                if (halt) begin
                    if (!o_err) $fatal(1, "FAIL [count] +halt, but ac3_front did not halt");
                    if (nb[1] <= nb[0])
                        $fatal(1, "FAIL [count] +halt: the engine decoded %0d blocks, not past ac3_front's %0d",
                               nb[1], nb[0]);
                    n = nb[0];
                end
                if (refuse) begin
                    if (first_ref < 0) $fatal(1, "FAIL [count] +refuse, but the engine refused nothing");
                    if (nb[0] < first_ref || nb[1] < first_ref)
                        $fatal(1, "FAIL [count] %0d blocks before the refusal; ac3_front %0d, the engine %0d",
                               first_ref, nb[0], nb[1]);
                    n = first_ref;
                end
                for (int k = 0; k < n; k++) begin
                    if (lvl[0][k] !== lvl[1][k] || acm[0][k] !== acm[1][k])
                        $fatal(1, "FAIL [lvl] block %0d: ac3_front lvl_q %04x acmod %0d, the engine %04x %0d",
                               k, lvl[0][k], acm[0][k], lvl[1][k], acm[1][k]);
                    for (int i = 0; i < 512; i++)
                        if ((i < 256 || acm[0][k] != 3'd1) && pcm[0][k][i] !== pcm[1][k][i])
                            $fatal(1, "FAIL [pcm] block %0d ch %0d idx %0d: ac3_front %08x, the engine %08x",
                                   k, i / 256, i % 256, pcm[0][k][i], pcm[1][k][i]);
                end
                $display("ac3_ab_tb: %0d frames, %0d blocks identical (ac3_front %0d, halted %0d; the engine %0d, %0d frames refused, the first after block %0d)",
                         n_frames, n, nb[0], o_err, nb[1], nref, first_ref);
                if (n == 0 && !(refuse && nref > 0) && !(halt && nb[1] > 0)) $fatal(1, "FAIL [count] no block decoded");
                $display("PASS: ac3_ab_tb");
                $finish;
            end
        end
    end
endmodule
