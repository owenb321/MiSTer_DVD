// bench/dvd/mp2_ab_tb.sv -- MP2: the shared engine against mp2_decode, pair for pair
// (docs/mp2_engine.md M2: the bar is bit identity with the decoder it replaces, scored
// directly, not through the model both were checked against).
//
// The same frames (STEM.bytes, STEM.frames: tools/mp2_golden.py's format) go to
// mp2_decode as its byte stream (it hunts the sync itself, as in the core today) and to
// dts_top running MP2 (codec 2) as descriptors and bytes. Every stereo pair each one
// plays is captured, and the two sequences are compared in order:
//   [pcm]   pair i of the engine equals pair i of mp2_decode
//   [count] both play every frame's 1,152 pairs, nothing more; the engine refuses
//           nothing; mp2_decode raises no err_unsupported; both report the same rate
//   [hang]  no progress
// mp2_decode is popped by an aud_ce every 64 cycles (its own bench's rate, faster than
// real time); the engine's PCM port is always ready.

`default_nettype none
`timescale 1ns/1ps

module mp2_ab_tb;
    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    string stem;
    logic [7:0]  bytes [];
    logic [15:0] flen [];
    int n_bytes, n_frames, n_exp;

    initial begin
        int fd, r, x;
        logic [31:0] v;
        if (!$value$plusargs("stem=%s", stem)) $fatal(1, "FAIL [setup] no +stem");
        fd = $fopen({stem, ".meta"}, "r");
        if (fd == 0) $fatal(1, "FAIL [setup] no %s.meta", stem);
        r = $fscanf(fd, "%d %d", n_bytes, n_frames);
        $fclose(fd);
        bytes = new[n_bytes];
        flen = new[n_frames];
        fd = $fopen({stem, ".bytes"}, "r");
        for (int i = 0; i < n_bytes; i++) begin r = $fscanf(fd, "%h", v); bytes[i] = v[7:0]; end
        $fclose(fd);
        fd = $fopen({stem, ".frames"}, "r");
        for (int i = 0; i < n_frames; i++) begin r = $fscanf(fd, "%h", v); flen[i] = v[15:0]; end
        $fclose(fd);
        n_exp = 1152 * n_frames;
    end

    // ---- mp2_decode: the byte stream
    logic        m_wr, m_full, aud_ce, m_valid, m_synced, m_err;
    logic [7:0]  m_wd;
    logic signed [15:0] m_l, m_r;
    logic [1:0]  m_fs;
    int mb = 0, ce = 0;
    mp2_decode #(.PCM_AW(12)) u_old (
        .clk, .rst(!rst_n), .wr_en(m_wr), .wr_data(m_wd), .full(m_full),
        .aud_ce, .audio_l(m_l), .audio_r(m_r), .aud_valid(m_valid),
        .synced(m_synced), .err_unsupported(m_err), .fs_o(m_fs),
        .dbg_s_nz(), .dbg_pcm_nz(), .cp_step(1'b0), .cp_q());
    always_comb begin
        m_wr = rst_n && mb < n_bytes;
        m_wd = bytes[mb < n_bytes ? mb : 0];
    end
    always @(posedge clk) begin
        if (rst_n && m_wr && !m_full) mb <= mb + 1;
        ce <= (ce == 63) ? 0 : ce + 1;
        aud_ce <= (ce == 63);
    end

    // ---- the engine: descriptors and bytes
    logic [15:0] fr_len;
    logic        fr_valid, fr_ready, in_valid, in_ready, e_valid;
    logic [7:0]  in_byte;
    logic [15:0] e_l, e_r, e_frames, e_refused;
    logic [1:0]  e_fs;
    int fi = 0, bi = 0;
    always_comb begin
        fr_valid = rst_n && fi < n_frames; fr_len = flen[fi < n_frames ? fi : 0];
        in_valid = rst_n && bi < n_bytes;  in_byte = bytes[bi < n_bytes ? bi : 0];
    end
    always @(posedge clk) if (rst_n) begin
        if (fr_valid && fr_ready) fi <= fi + 1;
        if (in_valid && in_ready) bi <= bi + 1;
    end
    dts_top u_new (
        .clk, .rst_n, .codec(2'd2), .fr_len, .fr_valid, .fr_ready, .in_byte, .in_valid,
        .in_ready, .cb_req(), .cb_sel(), .cb_addr(), .cb_valid(1'b0), .cb_data(64'd0),
        .pcm_l(e_l), .pcm_r(e_r), .pcm_valid(e_valid), .pcm_ready(1'b1),
        .frames(e_frames), .refused(e_refused), .last_err(), .err_seen(), .overrun_bits(),
        .lenient_codes(), .dmix_ignored(), .frame_end(), .refuse(), .refuse_code(),
        .imdct_req(), .imdct_go(1'b0), .imdct_fin(), .pcm_ra(9'd0), .pcm_q(), .coef_ra(11'd0), .coef_q(), .blk_blksw(),
        .blk_dynrng(), .blk_acmod(), .blk_lfeon(), .blk_cmix(), .blk_surmix(), .mp2_fs(e_fs),
        .vop_start(), .vop_op(), .vop_done(), .tr_valid(), .tr_pc(), .tr_kind(), .tr_addr(),
        .tr_val());

    // ---- capture both, compare in order
    logic [31:0] q_old [$], q_new [$];
    int n_old = 0, n_new = 0, ncmp = 0;
    always @(posedge clk) if (rst_n) begin
        if (m_valid) begin q_old.push_back({m_l, m_r}); n_old++; end
        if (e_valid) begin q_new.push_back({e_l, e_r}); n_new++; end
        if (q_old.size() > 0 && q_new.size() > 0) begin
            logic [31:0] a, b;
            a = q_old.pop_front(); b = q_new.pop_front();
            if (a !== b)
                $fatal(1, "FAIL [pcm] pair %0d (frame %0d): engine %04x %04x, mp2_decode %04x %04x",
                       ncmp, ncmp / 1152, b[31:16], b[15:0], a[31:16], a[15:0]);
            ncmp++;
        end
        if (n_new > n_exp) $fatal(1, "FAIL [count] the engine played pair %0d of %0d", n_new, n_exp);
        if (n_old > n_exp) $fatal(1, "FAIL [count] mp2_decode played pair %0d of %0d", n_old, n_exp);
        if (e_refused != 16'd0) $fatal(1, "FAIL [count] the engine refused a frame");
        if (m_err) $fatal(1, "FAIL [count] mp2_decode raised err_unsupported");
    end

    int last = -1, quiet = 0;
    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        forever begin
            @(posedge clk);
            if (ncmp == n_exp) begin
                repeat (5000) @(posedge clk);
                if (n_old != n_exp || n_new != n_exp)
                    $fatal(1, "FAIL [count] pairs: engine %0d, mp2_decode %0d, of %0d", n_new, n_old, n_exp);
                if (e_fs !== m_fs) $fatal(1, "FAIL [count] the rate: engine %0d, mp2_decode %0d", e_fs, m_fs);
                $display("mp2_ab_tb: %0d frames, %0d pairs identical, rate %0d", n_frames, ncmp, e_fs);
                $display("PASS: mp2_ab_tb");
                $finish;
            end
            if (ncmp != last) begin last = ncmp; quiet = 0; end
            else if (++quiet > 2000000)
                $fatal(1, "FAIL [hang] %0d of %0d pairs compared (engine %0d, mp2_decode %0d)",
                       ncmp, n_exp, n_new, n_old);
        end
    end
endmodule
