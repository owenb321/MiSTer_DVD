// bench/dvd/dts_seq_tb.sv -- the engine's sequencer against its emulator (both programs)
//
// Feeds STEM.frames (descriptors) and STEM.bytes (tools/dts_golden.py, or
// tools/ac3_golden.py with +codec=1, tools/mp2_golden.py with +codec=2) into dts_seq, with optional input stalls
// (+stall=N: a gap of up to N cycles before a byte or a descriptor) and XQ
// back-pressure (+xstall=N), and a stub vector engine: done 1-4 cycles after a start,
// or after the op's last item is taken -- XQ 8 codes; AC-3's AQ hi - lo bins (r11 -
// r10), AQC 1 + its coupled channels' coordinates + hi - lo bins (r10 - r9; the channel
// count from the band's 0x7F0 item). A refusal (err_valid) ends the op without done;
// the one item still pending is taken and discarded, as the real vector engine
// processes it (docs/ac3_engine.md). The program never reads an
// engine's result and the codes' bits are read here, so the trace does not depend on
// the engine. Every register write, store, item and unit record write is compared, in
// order, against STEM.trace: kind, pc, register / address / index, value.
// With +cyc (an arm with no stalls), the cycles each AC-3 op spends in its own states
// (not the vector engine's: S_VOP, S_XQ_W) are compared with STEM.cyc, the emulator's
// RTL-exact charge (tools/ac3_isa.py UNIT_CYCLES).
// Arms: [trace] an event differs; [count] too few / too many events, frames,
// refusals, overrun bits, lenient block codes (D5) or CNT ops; [cycles] an op's unit
// cycles differ from the emulator's; [hang] no progress.

`default_nettype none
`timescale 1ns/1ps

module dts_seq_tb;
    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    logic [15:0]  fr_len;
    logic         fr_valid, fr_ready;
    logic [7:0]   in_byte;
    logic         in_valid, in_ready;
    logic         vop_start, vop_done;
    logic [5:0]   vop_op;
    logic [127:0] vop_args;
    logic [23:0]  xq_code;
    logic [10:0]  xq_addr;
    logic         xq_valid, xq_ready;
    logic   [1:0] codec;                 // 0 DTS, 1 AC-3, 2 MP2
    logic         err_valid, frame_done, overrun_bit, lenient;
    logic [4:0]   err_code;
    logic         tr_valid;
    logic [10:0]  tr_pc;
    logic [1:0]   tr_kind;
    logic [10:0]  tr_addr;
    logic [23:0]  tr_val;

    dts_seq dut (
        .clk, .rst_n, .codec, .fr_len, .fr_valid, .fr_ready, .in_byte, .in_valid, .in_ready,
        .vop_start, .vop_op, .vop_args, .vop_done, .xq_code, .xq_addr, .xq_valid, .xq_ready,
        .err_valid, .err_code, .frame_done, .overrun_bit, .lenient,
        .tr_valid, .tr_pc, .tr_kind, .tr_addr, .tr_val);

    string stem;
    int stall, xstall;
    logic [7:0]  bytes [];
    logic [15:0] flen [];
    logic [49:0] exp [];                 // {kind 2, pc 11, addr 13, val 24}
    int n_bytes, n_frames, n_ev, n_vops, n_pairs, n_err, n_ovr, n_len, n_dmix, n_fs, n_dynf, n_items;
    int bi, fi, ei, frames, errs, gap, fgap, busy, idle, last_ei, quiet, ovr, len, nlen, ncnt, ndynf;

    initial begin
        int fd, r;
        logic [31:0] k, pc, a, v;
        if (!$value$plusargs("stem=%s", stem)) $fatal(1, "FAIL [setup] no +stem");
        if (!$value$plusargs("stall=%d", stall)) stall = 0;
        if (!$value$plusargs("xstall=%d", xstall)) xstall = 0;
        if (!$value$plusargs("codec=%d", r)) r = 0;
        codec = r[1:0];
        fd = $fopen({stem, ".meta"}, "r");
        if (fd == 0) $fatal(1, "FAIL [setup] no %s.meta", stem);
        n_dynf = 0;
        r = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d", n_bytes, n_frames, n_ev, n_vops, n_pairs,
                    n_err, n_ovr, n_len, n_dmix, n_fs, n_dynf);
        $fclose(fd);
        bytes = new[n_bytes];
        flen = new[n_frames];
        exp = new[n_ev];
        fd = $fopen({stem, ".bytes"}, "r");
        for (int i = 0; i < n_bytes; i++) begin r = $fscanf(fd, "%h", v); bytes[i] = v[7:0]; end
        $fclose(fd);
        fd = $fopen({stem, ".frames"}, "r");
        for (int i = 0; i < n_frames; i++) begin r = $fscanf(fd, "%h", v); flen[i] = v[15:0]; end
        $fclose(fd);
        fd = $fopen({stem, ".trace"}, "r");
        n_items = 0;
        for (int i = 0; i < n_ev; i++) begin
            r = $fscanf(fd, "%h %h %h %h", k, pc, a, v);
            exp[i] = {k[1:0], pc[10:0], a[12:0], v[23:0]};
            if (k == 2) n_items++;
        end
        $fclose(fd);
    end

    // the descriptor source
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

    // the byte source
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bi <= 0; gap <= 0; in_valid <= 1'b0;
        end else begin
            if (in_valid && in_ready) begin
                bi <= bi + 1;
                in_valid <= 1'b0;
                gap <= (stall > 0) ? ($urandom % (stall + 1)) : 0;
            end else if (!in_valid && bi < n_bytes) begin
                if (gap > 0) gap <= gap - 1;
                else begin in_valid <= 1'b1; in_byte <= bytes[bi]; end
            end
        end
    end

    // the stub engine
    int vcnt, xtaken, xgap, xneed, ncpl, xtot;
    logic xq_op, xab;
    wire [15:0] a9 = vop_args[16 +: 16], a10 = vop_args[32 +: 16], a11 = vop_args[48 +: 16];
    always_comb begin
        ncpl = 0;
        for (int c = 0; c < 5; c++) if (c < xq_code[12:10] && xq_code[5 + c]) ncpl++;
    end
    always @(posedge clk) begin
        vop_done <= 1'b0;
        if (!rst_n) begin
            vcnt <= 0; xq_op <= 1'b0; xtaken <= 0; xq_ready <= 1'b0; xgap <= 0; xneed <= 0;
            xab <= 1'b0; xtot <= 0;
        end else begin
            if (vop_start) begin
                xtaken <= 0; xab <= 1'b0;
                case (vop_op)
                    6'd1:  xneed <= 8;
                    6'd21: xneed <= ($signed(a10) < $signed(a11)) ? a11 - a10 : 0;
                    6'd22: xneed <= 1 + a10 - a9;
                    default: xneed <= 0;
                endcase
                xq_op <= (vop_op == 6'd1) || (vop_op == 6'd22) ||
                         (vop_op == 6'd21 && $signed(a10) < $signed(a11));
                vcnt <= ((vop_op == 6'd1) || (vop_op == 6'd22) ||
                         (vop_op == 6'd21 && $signed(a10) < $signed(a11))) ? 0 : 1 + ($urandom % 4);
            end else if (vcnt > 0) begin
                vcnt <= vcnt - 1;
                if (vcnt == 1) vop_done <= 1'b1;
            end
            if (err_valid) begin vcnt <= 0; xq_op <= 1'b0; xab <= xq_op; end  // the op ends
            if (xq_valid && xq_ready) begin
                if (!xq_op && !xab) $fatal(1, "FAIL [trace] an item (addr %03x) outside an op", xq_addr);
                if (!xq_op) xab <= 1'b0;                       // the one pending item
                xtaken <= xtaken + 1; xtot <= xtot + 1;
                if (codec == 2'd1 && xq_addr == 11'h7F0) xneed <= xneed + ncpl;
                if (xtaken == xneed - 1 && !(codec == 2'd1 && xq_addr == 11'h7F0)) begin
                    vcnt <= 1 + ($urandom % 4); xq_op <= 1'b0;
                end
                xgap <= (xstall > 0) ? ($urandom % (xstall + 1)) : 0;
                xq_ready <= (xstall == 0);
            end else if (xgap > 0) begin xgap <= xgap - 1; xq_ready <= 1'b0; end
            else xq_ready <= 1'b1;
        end
    end

    // cycles in each op's own states (XQ's reader; AC-3's units), by op
    longint ucyc [0:63];
    int st;
    initial for (int i = 0; i < 64; i++) ucyc[i] = 0;
    always @(posedge clk) if (rst_n) begin
        st = dut.state;
        if ((st >= 10 && st <= 13) || st >= 15) ucyc[dut.u_op] = ucyc[dut.u_op] + 1;
    end

    // the scoreboard
    logic [49:0] e;
    always @(posedge clk) begin
        if (!rst_n) begin
            ei <= 0; frames <= 0; errs <= 0; ovr <= 0; nlen <= 0; ncnt <= 0; ndynf <= 0;
        end else begin
            if (tr_valid) begin
                if (ei >= n_ev)
                    $fatal(1, "FAIL [trace] an event past the golden's %0d: kind %0d pc %03x addr %03x val %06x",
                           n_ev, tr_kind, tr_pc, tr_addr, tr_val);
                e = exp[ei];
                if ({tr_kind, tr_pc, 2'd0, tr_addr, tr_val} !== e)
                    $fatal(1, "FAIL [trace] event %0d: rtl kind %0d pc %03x addr %03x val %06x, emulator kind %0d pc %03x addr %03x val %06x",
                           ei, tr_kind, tr_pc, tr_addr, tr_val, e[49:48], e[47:37], e[36:24], e[23:0]);
                ei <= ei + 1;
            end
            if (frame_done) frames <= frames + 1;
            if (err_valid) errs <= errs + 1;
            if (overrun_bit) ovr <= ovr + 1;
            if (lenient) nlen <= nlen + 1;
            // CNT's counter id is a0: 0 the ignored downmixes (MP2: its frames), 1 DYNF (#189)
            if (vop_start && vop_op == 6'd8 && vop_args[15:0] == 16'd0) ncnt <= ncnt + 1;
            if (vop_start && vop_op == 6'd8 && vop_args[15:0] == 16'd1) ndynf <= ndynf + 1;
        end
    end

    initial begin
        busy = 0; idle = 0; last_ei = 0; quiet = 0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        forever begin
            @(posedge clk);
            busy++;
            if (fi == n_frames && fr_ready) idle++; else idle = 0;
            if (idle > 64) begin
                if (ei != n_ev)
                    $fatal(1, "FAIL [count] %0d of %0d trace events", ei, n_ev);
                if (frames != n_frames - n_err)
                    $fatal(1, "FAIL [count] %0d frames decoded, the golden %0d", frames, n_frames - n_err);
                if (errs != n_err)
                    $fatal(1, "FAIL [count] %0d refusals, the golden %0d", errs, n_err);
                if (ovr != n_ovr)
                    $fatal(1, "FAIL [count] %0d overrun bits, the golden %0d", ovr, n_ovr);
                if (nlen != n_len)
                    $fatal(1, "FAIL [count] %0d lenient block codes, the golden %0d", nlen, n_len);
                if (ncnt != n_dmix)
                    $fatal(1, "FAIL [count] %0d CNT ops (dmix ignored), the golden %0d", ncnt, n_dmix);
                if (ndynf != n_dynf)
                    $fatal(1, "FAIL [count] %0d CNT ops (DYNF), the golden %0d", ndynf, n_dynf);
                if (bi != n_bytes)
                    $fatal(1, "FAIL [count] %0d of %0d bytes taken", bi, n_bytes);
                // every code / item emitted is taken: none dropped (a refusal keeps the
                // pending one for the engine, which processes it)
                if (xtot != n_items)
                    $fatal(1, "FAIL [count] the engine took %0d codes / items, the golden emitted %0d",
                           xtot, n_items);
                if ($test$plusargs("cyc")) begin
                    int fd, r, op;
                    longint c;
                    fd = $fopen({stem, ".cyc"}, "r");
                    if (fd == 0) $fatal(1, "FAIL [setup] no %s.cyc", stem);
                    while ($fscanf(fd, "%d %d", op, c) == 2)
                        if (ucyc[op] != c)
                            $fatal(1, "FAIL [cycles] op %0d: %0d cycles in its states, the emulator %0d",
                                   op, ucyc[op], c);
                    $fclose(fd);
                end
                $display("dts_seq_tb: %0d bytes, %0d events, %0d frames, %0d refusals, %0d overrun bits, %0d lenient, %0d dmix, %0d cycles (%0d a frame)",
                         n_bytes, ei, frames, errs, ovr, nlen, ncnt, busy, busy / n_frames);
                $write("dts_seq_tb units by op:");
                for (int i = 0; i < 64; i++) if (ucyc[i] != 0) $write(" %0d:%0d", i, ucyc[i]);
                $write("\n");
                $display("PASS: dts_seq_tb");
                $finish;
            end
            if (ei != last_ei) begin last_ei = ei; quiet = 0; end else quiet++;
            if (quiet > 200000 && !(fi == n_frames && fr_ready))
                $fatal(1, "FAIL [hang] at event %0d of %0d, byte %0d, frame %0d", ei, n_ev, bi, fi);
        end
    end
endmodule
