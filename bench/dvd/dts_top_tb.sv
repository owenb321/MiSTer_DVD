// bench/dvd/dts_top_tb.sv -- the whole DTS engine against its emulator
//
// Feeds STEM.frames and STEM.bytes (tools/dts_golden.py) into dts_top, answers its
// codebook port from CB/cb_adpcm.mem and CB/cb_vq.mem after +cblat=N cycles (default
// 20), with optional input stalls (+stall=N) and PCM back-pressure (+ostall=N), and
// scores:
//   [vop]   after every vector op, the engine buffers' checksums (X, the ADPCM history,
//           the IMDCT rings, the window's carried sums: tools/dts_isa.py
//           Machine.checksums, in the RTL's own address order) against the
//           emulator's -- the first op that differs is named, not just the PCM;
//   [pcm]   every stereo pair, in order, bit-exact;
//   [count] vector ops, pairs, frames, refusals, overrun bits, lenient codes and
//           ignored downmixes;
//   [hang]  no progress.
// It reports each frame's cycles against its real-time budget (27 MHz / 48 kHz =
// 562.5 cycles a stereo pair), the worst and the mean.
// +codec=2 runs MP2 (goldens tools/mp2_golden.py, the same format): the checksums at
// MP2's widths (X 27 bits, the whole 2,048 x 32 ring; tools/mp2_isa.py
// Machine.checksums), the budget at the stream's own rate (+fs=0 44.1 kHz, 1 48, 2 32
// kHz), and [count] also checks the rate dts_top exports (mp2_fs) against the golden's.

`default_nettype none
`timescale 1ns/1ps

module dts_top_tb;
    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    logic [15:0] fr_len;
    logic        fr_valid, fr_ready;
    logic [7:0]  in_byte;
    logic        in_valid, in_ready;
    logic        cb_req, cb_sel, cb_valid;
    logic [11:0] cb_addr;
    logic [63:0] cb_data;
    logic [15:0] pcm_l, pcm_r;
    logic        pcm_valid, pcm_ready;
    logic [15:0] frames, refused, overrun_bits, lenient_codes, dmix_ignored;
    logic [4:0]  last_err;
    logic [31:0] err_seen;
    logic        vop_start, vop_done, tr_valid;
    logic [5:0]  vop_op;
    logic [10:0] tr_pc;
    logic [1:0]  codec, mp2_fs;
    logic [1:0]  tr_kind;
    logic [10:0] tr_addr;
    logic [23:0] tr_val;

    dts_top dut (
        .clk, .rst_n, .codec, .mp2_fs, .fr_len, .fr_valid, .fr_ready, .in_byte, .in_valid, .in_ready,
        .cb_req, .cb_sel, .cb_addr, .cb_valid, .cb_data,
        .pcm_l, .pcm_r, .pcm_valid, .pcm_ready,
        .frames, .refused, .last_err, .err_seen, .overrun_bits, .lenient_codes,
        .dmix_ignored, .vop_start, .vop_op, .vop_done,
        .tr_valid, .tr_pc, .tr_kind, .tr_addr, .tr_val,
        // AC-3's IMDCT and PCM ports, tied off: codec 0 / 2 never reach op 25
        .imdct_req(), .imdct_go(1'b0), .imdct_fin(), .pcm_ra(9'd0), .pcm_q(),
        .coef_ra(11'd0), .coef_q());

    string stem, cbdir;
    int stall, ostall, cblat;
    logic [7:0]   bytes [];
    logic [15:0]  flen [];
    logic [31:0]  pcm_exp [];
    logic [133:0] vop_exp [];
    logic [63:0]  cb_ad [0:4095];
    logic [63:0]  cb_vq [0:4095];
    int n_bytes, n_frames, n_ev, n_vops, n_pairs, n_err, n_ovr, n_len, n_dmix, n_fs;
    real pair_cyc;                       // cycles a stereo pair in real time
    int bi, fi, pi, vi, gap, fgap, ogap, busy, idle, last_prog, quiet;
    logic [5:0] cur_op;
    // +opstats: cycles by vector op (start to done), and the sequencer's own (the rest)
    longint op_cyc [0:8];
    int op_n [0:8];
    int op_t0;
    logic opstats;

    initial begin
        int fd, r;
        logic [31:0] v0, v1, v2, v3, v4;
        if (!$value$plusargs("stem=%s", stem)) $fatal(1, "FAIL [setup] no +stem");
        if (!$value$plusargs("cb=%s", cbdir)) $fatal(1, "FAIL [setup] no +cb");
        if (!$value$plusargs("stall=%d", stall)) stall = 0;
        if (!$value$plusargs("ostall=%d", ostall)) ostall = 0;
        if (!$value$plusargs("cblat=%d", cblat)) cblat = 20;
        opstats = $test$plusargs("opstats");
        if (!$value$plusargs("codec=%d", r)) r = 0;
        codec = r[1:0];
        for (int i = 0; i < 9; i++) begin op_cyc[i] = 0; op_n[i] = 0; end
        fd = $fopen({stem, ".meta"}, "r");
        if (fd == 0) $fatal(1, "FAIL [setup] no %s.meta", stem);
        n_fs = 1;
        r = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d", n_bytes, n_frames, n_ev, n_vops,
                    n_pairs, n_err, n_ovr, n_len, n_dmix, n_fs);
        pair_cyc = (codec == 2'd2 && n_fs == 0) ? 27.0e6 / 44100 :
                   (codec == 2'd2 && n_fs == 2) ? 27.0e6 / 32000 : 562.5;
        $fclose(fd);
        bytes = new[n_bytes];
        flen = new[n_frames];
        pcm_exp = new[n_pairs];
        vop_exp = new[n_vops];
        fd = $fopen({stem, ".bytes"}, "r");
        for (int i = 0; i < n_bytes; i++) begin r = $fscanf(fd, "%h", v0); bytes[i] = v0[7:0]; end
        $fclose(fd);
        fd = $fopen({stem, ".frames"}, "r");
        for (int i = 0; i < n_frames; i++) begin r = $fscanf(fd, "%h", v0); flen[i] = v0[15:0]; end
        $fclose(fd);
        fd = $fopen({stem, ".pcm"}, "r");
        for (int i = 0; i < n_pairs; i++) begin
            r = $fscanf(fd, "%h %h", v0, v1); pcm_exp[i] = {v0[15:0], v1[15:0]};
        end
        $fclose(fd);
        fd = $fopen({stem, ".vops"}, "r");
        for (int i = 0; i < n_vops; i++) begin
            r = $fscanf(fd, "%h %h %h %h %h", v0, v1, v2, v3, v4);
            vop_exp[i] = {v0[5:0], v1, v2, v3, v4};
        end
        $fclose(fd);
        $readmemh({cbdir, "/cb_adpcm.mem"}, cb_ad);
        $readmemh({cbdir, "/cb_vq.mem"}, cb_vq);
    end

    // the descriptor and byte sources
    always @(posedge clk) begin
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
    always @(posedge clk) begin
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

    // the codebook port: one request outstanding, answered cblat cycles later
    int cbt, n_cb;
    logic cb_busy;
    always @(posedge clk) begin
        cb_valid <= 1'b0;
        if (!rst_n) begin cb_busy <= 1'b0; n_cb <= 0; end
        else begin
            if (cb_req) begin
                if (cb_busy) $fatal(1, "FAIL [count] a codebook request while one is outstanding");
                cb_busy <= 1'b1; cbt <= cblat; n_cb <= n_cb + 1;
                cb_data <= 64'hx;
            end else if (cb_busy) begin
                if (cbt <= 1) begin
                    cb_valid <= 1'b1; cb_busy <= 1'b0;
                    cb_data <= cb_sel ? cb_vq[cb_addr] : cb_ad[cb_addr];
                end else cbt <= cbt - 1;
            end
        end
    end

    // the PCM sink, and each frame's cycles against its budget
    int fstart, fpairs, nfr_t;
    real worst, sumfrac;
    always @(posedge clk) begin
        if (!rst_n) begin pcm_ready <= 1'b0; ogap <= 0; pi <= 0; end
        else begin
            if (pcm_valid && pcm_ready) begin
                if (pi >= n_pairs) $fatal(1, "FAIL [count] a pair past the golden's %0d", n_pairs);
                if ({pcm_l, pcm_r} !== pcm_exp[pi]) begin
                    logic [31:0] e;
                    e = pcm_exp[pi];
                    $fatal(1, "FAIL [pcm] pair %0d (during vector op %0d): rtl %04x %04x, emulator %04x %04x",
                           pi, vi, pcm_l, pcm_r, e[31:16], e[15:0]);
                end
                pi <= pi + 1;
                ogap <= (ostall > 0) ? ($urandom % (ostall + 1)) : 0;
                pcm_ready <= (ostall == 0);
            end else if (ogap > 0) begin ogap <= ogap - 1; pcm_ready <= 1'b0; end
            else pcm_ready <= 1'b1;
        end
    end
    task automatic close_frame(input int now);
        real f;
        if (fpairs > 0) begin
            f = (now - fstart) / (fpairs * pair_cyc);
            if (f > worst) worst = f;
            sumfrac += f; nfr_t++;
        end
    endtask
    always @(posedge clk) begin
        if (!rst_n) begin fstart <= 0; fpairs <= 0; end
        else begin
            if (fr_valid && fr_ready) begin
                if (fi > 0) close_frame(busy);
                fstart <= busy; fpairs <= 0;
            end else if (pcm_valid && pcm_ready) fpairs <= fpairs + 1;
        end
    end

    // the engine buffers' checksums: sum (i + 1) (v mod 2^w), mod 2^32
    function automatic logic [31:0] ck_x(input int dummy);
        logic [63:0] acc; acc = 0;
        for (int i = 0; i < 1280; i++)                  // DTS's 25 bits, MP2's 27
            acc = acc + (i + 1) * ((codec == 2'd2) ? dut.u_vec.xb[i] : {2'b0, dut.u_vec.xb[i][24:0]});
        return acc[31:0];
    endfunction
    function automatic logic [31:0] ck_h(input int dummy);
        logic [63:0] acc; acc = 0;
        for (int i = 0; i < 640; i++) acc = acc + (i + 1) * dut.u_vec.hb[i];
        return acc[31:0];
    endfunction
    function automatic logic [31:0] ck_r(input int dummy);
        logic [63:0] acc; acc = 0;
        if (codec == 2'd2)                              // MP2's V {ch, i}, 32 bits
            for (int i = 0; i < 2048; i++) acc = acc + (i + 1) * dut.u_vec.ring[i];
        else                                            // DTS's {0, side, i}, 24 bits
            for (int i = 0; i < 1024; i++) acc = acc + (i + 1) * dut.u_vec.ring[i][23:0];
        return acc[31:0];
    endfunction
    function automatic logic [31:0] ck_b(input int dummy);
        logic [63:0] acc; acc = 0;
        for (int i = 0; i < 64; i++) acc = acc + (i + 1) * dut.u_vec.sm[64 + i];   // b2
        return acc[31:0];
    endfunction

    always @(posedge clk) begin
        if (!rst_n) vi <= 0;
        else begin
            if (vop_start) begin cur_op <= vop_op; op_t0 = busy; end
            if (vop_done) begin op_cyc[cur_op] += busy - op_t0; op_n[cur_op]++; end
            if (vop_done) begin
                logic [133:0] e;
                logic [31:0] cx, ch, cr, cb;
                if (vi >= n_vops) $fatal(1, "FAIL [count] a vector op past the golden's %0d", n_vops);
                e = vop_exp[vi];
                #1;
                cx = ck_x(0); ch = ck_h(0); cr = ck_r(0); cb = ck_b(0);
                if (cur_op !== e[133:128])
                    $fatal(1, "FAIL [vop] op %0d: rtl op %0d, emulator op %0d", vi, cur_op, e[133:128]);
                if (cx !== e[127:96]) $fatal(1, "FAIL [vop] op %0d (%0d): X differs (%08x, emulator %08x)", vi, cur_op, cx, e[127:96]);
                if (ch !== e[95:64])  $fatal(1, "FAIL [vop] op %0d (%0d): the ADPCM history differs (%08x, emulator %08x)", vi, cur_op, ch, e[95:64]);
                if (cr !== e[63:32])  $fatal(1, "FAIL [vop] op %0d (%0d): the IMDCT rings differ (%08x, emulator %08x)", vi, cur_op, cr, e[63:32]);
                if (cb !== e[31:0])   $fatal(1, "FAIL [vop] op %0d (%0d): the window's carried sums differ (%08x, emulator %08x)", vi, cur_op, cb, e[31:0]);
                vi <= vi + 1;
            end
        end
    end

    // +dirty: the ring and the carried sums start as garbage (what another program left):
    // a program's RESET must clear them (RCLR), or the first op's checksums differ
    initial if ($test$plusargs("dirty")) begin
        #1;
        for (int i = 0; i < 2048; i++) dut.u_vec.ring[i] = $urandom;
        for (int i = 64; i < 128; i++) dut.u_vec.sm[i] = $urandom;
    end

    initial begin
        busy = 0; idle = 0; last_prog = 0; quiet = 0; worst = 0.0; sumfrac = 0.0; nfr_t = 0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        forever begin
            @(posedge clk);
            busy++;
            if (fi == n_frames && fr_ready && !pcm_valid) idle++; else idle = 0;
            if (idle > 64) begin
                close_frame(busy - idle);
                if (vi != n_vops) $fatal(1, "FAIL [count] %0d of %0d vector ops", vi, n_vops);
                if (pi != n_pairs) $fatal(1, "FAIL [count] %0d of %0d pairs", pi, n_pairs);
                if (frames != n_frames - n_err)
                    $fatal(1, "FAIL [count] %0d frames decoded, the golden %0d", frames, n_frames - n_err);
                if (refused != n_err) $fatal(1, "FAIL [count] %0d refusals, the golden %0d", refused, n_err);
                if (overrun_bits != n_ovr) $fatal(1, "FAIL [count] %0d overrun bits, the golden %0d", overrun_bits, n_ovr);
                if (lenient_codes != n_len) $fatal(1, "FAIL [count] %0d lenient codes, the golden %0d", lenient_codes, n_len);
                if (dmix_ignored != n_dmix) $fatal(1, "FAIL [count] %0d ignored downmixes, the golden %0d", dmix_ignored, n_dmix);
                if (codec == 2'd2 && n_pairs > 0 && mp2_fs != n_fs[1:0])
                    $fatal(1, "FAIL [count] the exported rate %0d, the golden %0d", mp2_fs, n_fs);
                $display("dts_top_tb: %0d bytes, %0d vector ops, %0d pairs, %0d frames, %0d refused, %0d codebook rows (latency %0d), %0d cycles; real time: worst frame %0.1f %%, mean %0.1f %%",
                         n_bytes, vi, pi, frames, refused, n_cb, cblat, busy - idle,
                         100.0 * worst, nfr_t ? 100.0 * sumfrac / nfr_t : 0.0);
                if (opstats) begin
                    longint vt; vt = 0;
                    for (int i = 0; i < 9; i++) begin
                        vt += op_cyc[i];
                        if (op_n[i]) $display("opstats: op %0d  n %0d  cycles %0d  mean %0.1f",
                                              i, op_n[i], op_cyc[i], 1.0 * op_cyc[i] / op_n[i]);
                    end
                    $display("opstats: sequencer %0d cycles (%0d total)", busy - idle - vt, busy - idle);
                end
                $display("PASS: dts_top_tb");
                $finish;
            end
            if (vi + pi != last_prog) begin last_prog = vi + pi; quiet = 0; end else quiet++;
            if (quiet > 400000)
                $fatal(1, "FAIL [hang] at vector op %0d, pair %0d, byte %0d, frame %0d", vi, pi, bi, fi);
        end
    end
endmodule
