// bench/dvd/dts_dec_tb.sv -- DTS through dvd_audio_decode: the T_DTS arm (docs/dts_decoder.md P3)
//
// An audio_ring read-side model delivers STEM's DTS frames (tools/dts_golden.py: .bytes,
// .frames, .pcm) as type-1 descriptors -- optionally after +ac3=ACSTEM's AC-3 frames
// (tools/ac3_golden.py), so the engine must change program mid-stream -- and a codebook
// responder answers the engine's cb port from CB/cb_adpcm.mem + CB/cb_vq.mem after
// +cblat=N cycles (the DDR3 fetch dts_cb_mem does in the core). Scores:
//   [pcm]   every pair the LPCM FIFO plays out (DTS's output path) equals the golden's,
//           in order, bit-exact
//   [out]   ...and the module's own output (audio_l/audio_r) carries each pair before the
//           next one is popped: the output mux follows DTS's FIFO
//   [ac3]   with +ac3: every AC-3 block before the change of program is decoded (6 a
//           frame): the change waits for the engine to finish the last AC-3 frame
//   [count] the pairs, and every byte delivered taken
//   [off]   +notables: dts_tables_ok low -- DTS is discarded: not a pair, every byte
//           consumed (the behaviour before P3, and the refusal while the copy has not
//           landed or its checksum failed)
//   [hang]  no progress
// The drain gate free-runs (sched_en 0); the output mux follows the LPCM FIFO for DTS.

`default_nettype none
`timescale 1ns/1ps

module dts_dec_tb;
    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    string stem, acstem, cbdir;
    int cblat, notables, n_bytes, n_frames, n_pairs, a_bytes, a_frames;
    localparam int MAXB = 1 << 17;
    logic [7:0]  bmem [0:MAXB-1];
    logic [15:0] dlen [0:511];
    logic [1:0]  dtyp [0:511];
    logic [31:0] pexp [0:16383];
    logic [63:0] t_adpcm [0:4095];
    logic [63:0] t_vq    [0:4095];
    int total_bytes, total_frames;

    initial begin
        int fd, r, x, y, z, w;
        logic [31:0] v, l, rr;
        if (!$value$plusargs("stem=%s", stem)) $fatal(1, "FAIL [setup] no +stem");
        if (!$value$plusargs("cb=%s", cbdir)) $fatal(1, "FAIL [setup] no +cb");
        if (!$value$plusargs("cblat=%d", cblat)) cblat = 20;
        notables = $test$plusargs("notables");
        $readmemh({cbdir, "/cb_adpcm.mem"}, t_adpcm);
        $readmemh({cbdir, "/cb_vq.mem"}, t_vq);
        total_bytes = 0; total_frames = 0;
        a_bytes = 0; a_frames = 0;
        if ($value$plusargs("ac3=%s", acstem)) begin       // AC-3 first: a program change
            fd = $fopen({acstem, ".meta"}, "r");
            r = $fscanf(fd, "%d %d", a_bytes, a_frames);
            $fclose(fd);
            fd = $fopen({acstem, ".bytes"}, "r");
            for (int i = 0; i < a_bytes; i++) begin r = $fscanf(fd, "%h", v); bmem[i] = v[7:0]; end
            $fclose(fd);
            fd = $fopen({acstem, ".frames"}, "r");
            for (int i = 0; i < a_frames; i++) begin r = $fscanf(fd, "%h", v); dlen[i] = v[15:0]; dtyp[i] = 2'd0; end
            $fclose(fd);
        end
        fd = $fopen({stem, ".meta"}, "r");
        if (fd == 0) $fatal(1, "FAIL [setup] no %s.meta", stem);
        r = $fscanf(fd, "%d %d %d %d %d", n_bytes, n_frames, x, y, n_pairs);
        $fclose(fd);
        fd = $fopen({stem, ".bytes"}, "r");
        for (int i = 0; i < n_bytes; i++) begin r = $fscanf(fd, "%h", v); bmem[a_bytes + i] = v[7:0]; end
        $fclose(fd);
        fd = $fopen({stem, ".frames"}, "r");
        for (int i = 0; i < n_frames; i++) begin
            r = $fscanf(fd, "%h", v); dlen[a_frames + i] = v[15:0]; dtyp[a_frames + i] = 2'd1;
        end
        $fclose(fd);
        fd = $fopen({stem, ".pcm"}, "r");
        for (int i = 0; i < n_pairs; i++) begin r = $fscanf(fd, "%h %h", l, rr); pexp[i] = {l[15:0], rr[15:0]}; end
        $fclose(fd);
        total_bytes = a_bytes + n_bytes; total_frames = a_frames + n_frames;
    end

    // ---- the ring read side
    logic [7:0]  ring_byte;
    logic        ring_valid, frame_valid;
    wire         ring_ready, frame_pop;
    logic [15:0] frame_len;
    logic [1:0]  frame_type;
    int rd = 0, dptr = 0;
    always @(*) begin
        ring_byte = bmem[rd]; ring_valid = rd < total_bytes;
        frame_valid = dptr < total_frames; frame_len = dlen[dptr]; frame_type = dtyp[dptr];
    end
    always @(posedge clk) if (rst_n) begin
        if (ring_ready && ring_valid) rd <= rd + 1;
        if (frame_pop && frame_valid) dptr <= dptr + 1;
    end

    // ---- the codebook responder
    logic        cb_req, cb_sel, cb_valid;
    logic [11:0] cb_addr;
    logic [63:0] cb_data;
    int cb_cnt; logic cb_s; logic [11:0] cb_a; int ncb;
    always @(posedge clk) begin
        cb_valid <= 1'b0;
        if (!rst_n) begin cb_cnt = 0; ncb = 0; end
        else begin
            if (cb_req) begin
                if (cb_cnt != 0) $fatal(1, "FAIL [pcm] a codebook request while one is pending");
                cb_cnt = cblat + 1; cb_s = cb_sel; cb_a = cb_addr; ncb++;
            end else if (cb_cnt > 0) begin
                cb_cnt--;
                if (cb_cnt == 0) begin cb_valid <= 1'b1; cb_data <= cb_s ? t_vq[cb_a] : t_adpcm[cb_a]; end
            end
        end
    end

    // ---- the DUT
    wire signed [15:0] audio_l, audio_r;
    wire ac3_synced, ac3_err;
    dvd_audio_decode #(.CLK_HZ(27000000), .AUD_HZ(48000), .ARM_TIMEOUT_W(13)) dut (
        .cb_cp_mode(1'b0), .cb_lpcm_step(1'b0), .cb_mp2_step(1'b0), .cb_lpcm_q(), .cb_mp2_q(),
        .cb_req, .cb_sel, .cb_addr, .cb_valid, .cb_data, .dts_tables_ok(!notables),
        .clk(clk), .rst_n(rst_n), .enable(1'b1), .drc_mode(2'd0), .pause(1'b0), .aud_soft_switch(1'b0),
        .ring_byte, .ring_valid, .ring_ready, .frame_valid, .frame_len, .frame_type,
        .lpcm_quant(2'd2),                    // a stale LPCM 24-bit word length: DTS must force 16
        .lpcm_nch_m1(3'd1), .lpcm_fs96(1'b0), .lpcm_bad(1'b0), .link96(1'b0), .lpcm_unsup(),
        .cdda_mode(1'b0), .cdda_fs(2'd0), .cdda_wr_en(1'b0), .cdda_wr_data(8'd0),
        .cdda_flush(1'b0), .cdda_full(),
        .frame_pts(33'd0), .frame_pts_valid(1'b0), .frame_seamless(1'b0), .frame_pop,
        .nco_trim(22'sd0), .dispatch_pts(), .dispatch_pts_valid(),
        .sched_en(1'b0), .stc_anchored(1'b0), .disp_anchored(1'b1), .video_live(1'b1),
        .arr_pts(33'd0), .arr_pts_valid(1'b0), .stc(33'd0), .av_ofs(18'sd0),
        .anchor_pulse(1'b0), .anchor_delta(34'sd0), .anchor_disc(1'b0),
        .audio_l, .audio_r, .ac3_synced, .ac3_err,
        .dbg_rearm_cnt(), .dbg_fbrel_cnt(), .dbg_skip_cnt(), .dbg_play_err());

    // ---- the score: every pair the LPCM FIFO plays
    int got = 0, quiet = 0, last = 0, nimdct = 0;
    always @(posedge clk) if (rst_n && dut.imdct_done) nimdct++;
    logic [31:0] prev_pair; logic prev_v = 1'b0;
    always @(posedge clk) if (rst_n && dut.lpcm_aud_valid) begin
        if (prev_v && {audio_l, audio_r} !== prev_pair)
            $fatal(1, "FAIL [out] the module output %04x %04x before pair %0d, not the pair played (%04x %04x)",
                   audio_l, audio_r, got, prev_pair[31:16], prev_pair[15:0]);
        prev_pair = {dut.lpcm_l, dut.lpcm_r}; prev_v = 1'b1;
        if (notables) $fatal(1, "FAIL [off] a pair played with dts_tables_ok low");
        if (got >= n_pairs) $fatal(1, "FAIL [count] a pair past the golden's %0d", n_pairs);
        if ({dut.lpcm_l, dut.lpcm_r} !== pexp[got])
            $fatal(1, "FAIL [pcm] pair %0d: rtl %04x %04x, golden %04x %04x", got,
                   dut.lpcm_l, dut.lpcm_r, pexp[got][31:16], pexp[got][15:0]);
        got++;
    end

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        forever begin
            @(posedge clk);
            if (got != last || rd != quiet) begin last = got; quiet = rd; end
            else if (rd >= total_bytes && dptr >= total_frames) begin
                repeat (notables ? 20000 : 400000) @(posedge clk);
                if (got == last) begin
                    if (!notables && got != n_pairs)
                        $fatal(1, "FAIL [count] %0d of %0d pairs played", got, n_pairs);
                    if (rd != total_bytes) $fatal(1, "FAIL [count] %0d of %0d bytes taken", rd, total_bytes);
                    if (nimdct != 6 * a_frames)
                        $fatal(1, "FAIL [ac3] %0d AC-3 blocks decoded before the change of program, not %0d", nimdct, 6 * a_frames);
                    $display("dts_dec_tb: %0d AC-3 + %0d DTS frames, %0d DTS pairs bit-exact, %0d codebook rows (latency %0d)%s",
                             a_frames, n_frames, got, ncb, cblat, notables ? ", DTS discarded (no tables)" : "");
                    $display("PASS: dts_dec_tb");
                    $finish;
                end
            end
        end
    end
    initial begin
        #(64'd40_000_000_000);
        $fatal(1, "FAIL [hang] %0d of %0d pairs, byte %0d of %0d", got, n_pairs, rd, total_bytes);
    end
endmodule
