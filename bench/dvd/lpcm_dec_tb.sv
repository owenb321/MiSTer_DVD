//============================================================================
//  lpcm_dec_tb.sv -- dvd_audio_decode's LPCM seams (docs/lpcm_full.md): the header
//  fields reach lpcm_unpack, the NCO runs at 96 kHz only for a 96 kHz track on a
//  96 kHz link, a reserved header is muted and announced, and CD-DA ignores a stale
//  DVD LPCM header. lpcm_full_tb proves the arithmetic; this proves the wiring.
//
//    S1  96 kHz stereo, 96 kHz link: every pair out, in order; aud_ce at 96 kHz
//    S2  96 kHz stereo, 48 kHz link: half the pairs (DC in -> DC out once the
//        half-band is full); aud_ce at 48 kHz
//    S3  a reserved header (lpcm_bad): the bytes are drained, nothing plays,
//        lpcm_unsup is high while LPCM is the codec
//    S4  48 kHz 5.1: one pair per 6 samples (DC in -> DC out: each side's gains
//        sum to exactly 1.0); lpcm_unsup low
//    S5  CD-DA with a stale 96 kHz 5.1 DVD LPCM header on the ports: still stereo
//        pairs, in order
//
//  Output: "PASS Sn" / "FAIL Sn: ..." and LPCM_DEC_TB: ALL TESTS PASSED, or $fatal.
//============================================================================
`timescale 1ns/1ps

module lpcm_dec_tb;
    logic clk = 0; always #18.5 clk = ~clk;      // 27 MHz: the NCO's rates are real
    logic rst_n;

    logic [7:0]  ring_byte;
    logic        ring_valid;
    wire         ring_ready;
    logic        frame_valid;
    logic [15:0] frame_len;
    logic [1:0]  frame_type;
    wire         frame_pop;
    wire signed [15:0] audio_l, audio_r;

    logic [2:0]  nch_m1;
    logic        fs96, bad, link96;
    wire         unsup;
    logic        cdda_mode = 1'b0, cdda_wr_en = 1'b0;
    logic [7:0]  cdda_wr_data = 8'd0;
    wire         cdda_full;

    dvd_audio_decode #(.CLK_HZ(27000000), .AUD_HZ(48000), .ARM_TIMEOUT_W(13)) dut (
        .cb_cp_mode(1'b0), .cb_lpcm_step(1'b0), .cb_mp2_step(1'b0), .cb_lpcm_q(), .cb_mp2_q(),
        .cb_req(), .cb_sel(), .cb_addr(), .cb_valid(1'b0), .cb_data(64'd0), .dts_tables_ok(1'b0),
        .clk(clk), .rst_n(rst_n), .enable(1'b1), .drc_mode(2'd0), .pause(1'b0), .aud_soft_switch(1'b0),
        .ring_byte(ring_byte), .ring_valid(ring_valid), .ring_ready(ring_ready),
        .frame_valid(frame_valid), .frame_len(frame_len), .frame_type(frame_type),
        .lpcm_quant(2'd0), .lpcm_nch_m1(nch_m1), .lpcm_fs96(fs96), .lpcm_bad(bad),
        .link96(link96), .lpcm_unsup(unsup),
        .cdda_mode(cdda_mode), .cdda_fs(2'd1), .cdda_wr_en(cdda_wr_en),
        .cdda_wr_data(cdda_wr_data), .cdda_flush(1'b0), .cdda_full(cdda_full),
        .frame_pts(33'd0), .frame_pts_valid(1'b0), .frame_seamless(1'b0),
        .frame_pop(frame_pop),
        .nco_trim(22'sd0), .dispatch_pts(), .dispatch_pts_valid(),
        .sched_en(1'b0), .stc_anchored(1'b0), .disp_anchored(1'b1), .video_live(1'b1),
        .arr_pts(33'd0), .arr_pts_valid(1'b0), .stc(33'd0), .av_ofs(18'sd0),
        .anchor_pulse(1'b0), .anchor_delta(34'sd0), .anchor_disc(1'b0),
        .audio_l(audio_l), .audio_r(audio_r), .ac3_synced(), .ac3_err(),
        .dbg_rearm_cnt(), .dbg_fbrel_cnt(), .dbg_skip_cnt(), .dbg_play_err()
    );

    // ---- one descriptor of LPCM bytes ----
    localparam int MEM = 8192;
    logic [7:0] mem [0:MEM-1];
    integer committed, rd, nd, dptr;
    logic [15:0] flen;
    assign ring_byte = mem[rd];
    always @(*) ring_valid  = (rd < committed);
    always @(*) frame_valid = (dptr < nd);
    always @(*) frame_len   = flen;
    assign frame_type = 2'd2;                    // LPCM (a constant: always @* would never run)
    always @(posedge clk) if (rst_n) begin
        if (ring_ready && ring_valid) rd <= rd + 1;
        if (frame_pop && frame_valid) dptr <= dptr + 1;
    end

    // ---- what plays: every sample the FIFO pops (lpcm_unpack's aud_valid), and the
    // NCO's ticks ----
    logic [31:0] got [0:4095];
    integer ngot, nce, unsup_seen;
    always @(posedge clk) if (rst_n) begin
        if (dut.lpcm_aud_valid) begin
            if (ngot < 4096) got[ngot] = {dut.lpcm_l, dut.lpcm_r};
            ngot = ngot + 1;
        end
        if (dut.aud_ce) nce = nce + 1;
        if (unsup) unsup_seen = 1;
    end

    integer errs = 0, arm_errs, i, n;

    task automatic start(input [2:0] nm1, input f96, input b, input l96);
        nch_m1 = nm1; fs96 = f96; bad = b; link96 = l96;
        rst_n = 0; committed = 0; rd = 0; nd = 0; dptr = 0;
        repeat (8) @(posedge clk);
        ngot = 0; nce = 0; unsup_seen = 0; arm_errs = 0;
        rst_n = 1;
    endtask

    task automatic frame(input integer nbytes);
        flen = nbytes; committed = nbytes; nd = 1;
    endtask

    task automatic run_for(input integer cycles);
        repeat (cycles) @(posedge clk);
    endtask

    task automatic fail(input string arm, input string what);
        $display("FAIL %0s: %0s", arm, what); arm_errs = arm_errs + 1;
    endtask

    task automatic done(input string arm);
        if (arm_errs == 0) $display("PASS %0s", arm);
        errs = errs + arm_errs;
    endtask

    // ticks in a window of W cycles at rate R: W * R / 27e6 (+-2)
    task automatic check_rate(input string arm, input integer w, input integer hz);
        integer want; want = (w / 1000) * hz / 27000;
        if (nce < want - 2 || nce > want + 2) begin
            $display("FAIL %0s: %0d NCO ticks in %0d cycles, want ~%0d (%0d Hz)", arm, nce, w, want, hz);
            arm_errs = arm_errs + 1;
        end
    endtask

    initial begin
        rst_n = 0; nch_m1 = 3'd1; fs96 = 0; bad = 0; link96 = 0;
        committed = 0; rd = 0; nd = 0; dptr = 0;

        // ---- S1: 96 kHz stereo on a 96 kHz link: native ----
        start(3'd1, 1'b1, 1'b0, 1'b1);
        n = 300;
        for (i = 0; i < n; i = i + 1) begin           // a ramp: every pair distinct
            mem[4*i+0] = (i >> 8);  mem[4*i+1] = i[7:0];
            mem[4*i+2] = 8'h40;     mem[4*i+3] = i[7:0];
        end
        frame(4 * n);
        run_for(200000);
        if (ngot != n) begin $display("FAIL S1: %0d pairs played, want %0d", ngot, n); arm_errs++; end
        for (i = 0; i < n && i < ngot; i = i + 1)
            if (got[i] !== {i[15:0], 8'h40, i[7:0]}) begin
                if (arm_errs < 4) $display("FAIL S1: pair %0d = %08h", i, got[i]); arm_errs++;
            end
        nce = 0; run_for(100000); check_rate("S1", 100000, 96000);
        if (unsup_seen) fail("S1", "lpcm_unsup rose on a legal track");
        done("S1");

        // ---- S2: 96 kHz stereo on a 48 kHz link: decimated ----
        start(3'd1, 1'b1, 1'b0, 1'b0);
        n = 400;
        for (i = 0; i < n; i = i + 1) begin           // DC: 0x1234 / -0x0567
            mem[4*i+0] = 8'h12; mem[4*i+1] = 8'h34; mem[4*i+2] = 8'hFA; mem[4*i+3] = 8'h99;
        end
        frame(4 * n);
        run_for(300000);
        if (ngot != n / 2) begin $display("FAIL S2: %0d pairs played, want %0d", ngot, n / 2); arm_errs++; end
        for (i = 40; i < ngot && i < n / 2; i = i + 1)  // past the half-band's 35-output fill
            if (got[i] !== 32'h1234FA99) begin
                if (arm_errs < 4) $display("FAIL S2: pair %0d = %08h, want 1234fa99", i, got[i]); arm_errs++;
            end
        nce = 0; run_for(100000); check_rate("S2", 100000, 48000);
        done("S2");

        // ---- S3: a reserved header: drained, silent, announced ----
        start(3'd1, 1'b0, 1'b1, 1'b0);
        n = 100;
        for (i = 0; i < 4 * n; i = i + 1) mem[i] = 8'h55;
        frame(4 * n);
        run_for(100000);
        if (rd != 4 * n) begin $display("FAIL S3: %0d/%0d bytes drained", rd, 4 * n); arm_errs++; end
        if (ngot != 0) begin $display("FAIL S3: %0d pairs played", ngot); arm_errs++; end
        if (!unsup) fail("S3", "lpcm_unsup low with a reserved header playing");
        done("S3");

        // ---- S4: 48 kHz 5.1 (16-bit): downmixed, DC through ----
        start(3'd5, 1'b0, 1'b0, 1'b0);
        n = 200;                                      // sample-times
        for (i = 0; i < 6 * n; i = i + 1) begin
            mem[2*i+0] = (i % 6 == 3) ? 8'h7F : 8'h0C;   // LFE at near full scale: dropped
            mem[2*i+1] = (i % 6 == 3) ? 8'hFF : 8'h80;
        end
        frame(12 * n);
        run_for(400000);
        if (ngot != n) begin $display("FAIL S4: %0d pairs played, want %0d", ngot, n); arm_errs++; end
        for (i = 0; i < ngot && i < n; i = i + 1)
            if (got[i] !== 32'h0C800C80) begin
                if (arm_errs < 4) $display("FAIL S4: pair %0d = %08h, want 0c800c80", i, got[i]); arm_errs++;
            end
        nce = 0; run_for(100000); check_rate("S4", 100000, 48000);
        if (unsup_seen) fail("S4", "lpcm_unsup rose on a legal track");
        done("S4");

        // ---- S5: CD-DA ignores a stale DVD LPCM header (96 kHz 5.1) ----
        start(3'd5, 1'b1, 1'b0, 1'b0);
        cdda_mode = 1'b1;
        n = 100;
        for (i = 0; i < n; i = i + 1) begin           // little-endian L, R
            @(negedge clk); while (cdda_full) @(negedge clk);
            cdda_wr_en = 1; cdda_wr_data = i[7:0];       @(negedge clk);
            cdda_wr_data = 8'h11;                        @(negedge clk);
            cdda_wr_data = 8'h22;                        @(negedge clk);
            cdda_wr_data = i[7:0];                       @(negedge clk);
            cdda_wr_en = 0;
        end
        run_for(200000);
        if (ngot != n) begin $display("FAIL S5: %0d pairs played, want %0d", ngot, n); arm_errs++; end
        for (i = 0; i < ngot && i < n; i = i + 1)
            if (got[i] !== {8'h11, i[7:0], i[7:0], 8'h22}) begin
                if (arm_errs < 4) $display("FAIL S5: pair %0d = %08h", i, got[i]); arm_errs++;
            end
        cdda_mode = 1'b0;
        done("S5");

        if (errs == 0) $display("LPCM_DEC_TB: ALL TESTS PASSED");
        else $fatal(1, "LPCM_DEC_TB: %0d errors", errs);
        $finish;
    end
endmodule
