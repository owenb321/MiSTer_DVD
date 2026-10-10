//============================================================================
//  pause_wdog_tb.sv -- DOES A PAUSE LOSE AUDIO? (dvd/dvd_audio_decode.sv)
//
//  Field report (2026-10-09): "after a pause, audio is out of sync until a seek".
//  Measured on the rig (ALEXANDER, decoded AC-3): the engine's frame counter reset
//  ~0.7 s into every pause, and av_drift (dispatched audio PTS - STC) then climbed
//  in 32 ms steps -- a 10 s pause resumed with audio ~480 ms EARLY. Cause: the
//  AC-3/engine decode-stall watchdog was held clear while the drain gate was shut
//  (!drain_en) but NOT while paused. `pause` withholds the play tick, so the
//  decoder blocks on its full pcm fifo by design; after 2^WDOG_W clk the watchdog
//  read that as a hang, reset the engine (dumping the frame inside it) and the
//  dispatcher fed it the next one -- one frame lost per watchdog period.
//
//  The bench feeds N whole, real AC-3 frames (the 192 kbit/s tone, 1536 samples
//  each) with ascending PTS, opens the gate, and scores what a LISTENER gets:
//    [count]  every sample of every frame reaches the output: N*1536 sample
//             latches (dut.tgt_upd, the output mux's own "new sample" strobe --
//             dbg_play_cnt is no good, it counts ticks that found the fifo empty)
//    [reset]  no decoder self-heal reset (dbg_ac3_resets) while paused
//    [rearm]  no gate re-arm while paused (nothing underran: nothing played)
//  +PAUSE=0 is the control (no pause): it must score the same N*1536, which is
//  what proves the count can be met at all -- a bench whose control falls short
//  would be scoring the fixture, not the pause.
//  The pause lasts PAUSE_WD watchdog periods, so the defect loses ~PAUSE_WD frames.
//
//  RED arm (bench/dvd/run_pause_wdog.sh): remove the `|| pause` term -> [count]
//  and [reset] must fail.
//============================================================================
`timescale 1ns/1ps
module pause_wdog_tb;
    logic clk = 0; always #5 clk = ~clk;          // the DUT's CLK_HZ below is what counts
    logic rst_n = 0;

    localparam int CLK_HZ   = 27000000;
    localparam int WDOG_W   = 20;                  // 2^20 clk = 39 ms (core: 24 = 0.62 s)
    localparam int N        = 6;                   // frames in the stream
    localparam int FLEN     = 768;                 // 192 kbit/s @ 48 kHz
    localparam int SPF      = 1536;                // samples per AC-3 frame
    localparam int FTICKS   = 2880;                // 90 kHz ticks per frame
    localparam int PAUSE_WD = 5;                   // pause length, in watchdog periods

    logic pause = 0;
    logic [32:0] stc = '0;
    logic [8:0]  div = '0;
    // 90 kHz = clk/300. Frozen while paused, as disp_sched freezes it in the core.
    always @(posedge clk) if (rst_n && !pause) begin
        if (div == 9'd299) begin div <= '0; stc <= stc + 33'd1; end
        else div <= div + 9'd1;
    end

    // ---- ring read side: every frame committed up front ----------------------
    logic [7:0]  mem  [0:N*FLEN-1];
    logic [7:0]  frame0 [0:FLEN-1];
    integer      rd = 0, dptr = 0;
    wire         ring_ready, frame_pop;
    wire  [7:0]  ring_byte  = mem[rd];
    wire         ring_valid = (rd < N*FLEN);
    wire         frame_valid = (dptr < N);
    wire  [32:0] frame_pts  = dptr * FTICKS;
    always @(posedge clk) if (rst_n) begin
        if (ring_ready && ring_valid) rd   <= rd + 1;
        if (frame_pop  && frame_valid) dptr <= dptr + 1;
    end

    wire signed [15:0] audio_l, audio_r;
    wire [15:0] ac3_resets;
    wire [3:0]  rearm_cnt;

    dvd_audio_decode #(.CLK_HZ(CLK_HZ), .AUD_HZ(48000), .WDOG_W(WDOG_W)) dut (
        .cb_cp_mode(1'b0), .cb_lpcm_step(1'b0), .cb_mp2_step(1'b0), .cb_lpcm_q(), .cb_mp2_q(),
        .cb_req(), .cb_sel(), .cb_addr(), .cb_valid(1'b0), .cb_data(64'd0), .dts_tables_ok(1'b0),
        .clk(clk), .rst_n(rst_n), .enable(1'b1), .pause(pause), .aud_soft_switch(1'b0),
        .ring_byte(ring_byte), .ring_valid(ring_valid), .ring_ready(ring_ready),
        .frame_valid(frame_valid), .frame_len(16'(FLEN)), .frame_type(2'd0),      // AC-3
        .lpcm_quant(2'd0), .lpcm_nch_m1(3'd1), .lpcm_fs96(1'b0), .lpcm_bad(1'b0),
        .link96(1'b0), .lpcm_unsup(),
        .frame_pts(frame_pts), .frame_pts_valid(1'b1), .frame_seamless(1'b0),
        .frame_pop(frame_pop),
        .cdda_mode(1'b0), .cdda_fs(2'd0), .cdda_wr_en(1'b0), .cdda_wr_data(8'd0),
        .cdda_flush(1'b0), .cdda_full(),
        .nco_trim(22'sd0), .dbg_play_cnt(), .dbg_gate_cnt(),
        .dispatch_pts(), .dispatch_pts_valid(),
        .sched_en(1'b1), .stc_anchored(1'b1), .disp_anchored(1'b1), .video_live(1'b1),
        .arr_pts(33'((N - 1) * FTICKS)), .arr_pts_valid(1'b1), .stc(stc),
        .anchor_pulse(1'b0), .anchor_delta(34'sd0), .anchor_disc(1'b0), .av_ofs(18'sd0),
        .audio_l(audio_l), .audio_r(audio_r),
        .ac3_synced(), .ac3_err(), .dbg_ac3_resets(ac3_resets), .dbg_ac3_err_resets(),
        .dbg_draining(), .dbg_play_pts_valid(), .dbg_armed_data(), .dbg_skip_run(), .dbg_play_pts(),
        .dbg_rearm_cnt(rearm_cnt), .dbg_fbrel_cnt(), .dbg_skip_cnt(),
        .dbg_catch_cnt(), .dbg_retime_cnt(), .dbg_play_err(),
        .resync_req(),
        .dbg_cur_codec(), .dbg_mp2_avalid(), .dbg_mp2_s_nz(), .dbg_mp2_pcm_nz()
    );

    // ---- the listener: every sample the output mux latches -------------------
    integer samples = 0;
    always @(posedge clk) if (rst_n && dut.tgt_upd === 1'b1) samples <= samples + 1;

    integer errs = 0, i, t, do_pause = 1;
    integer s_at_pause, s_at_resume, resets_at_pause, rearm_at_pause;

    task automatic fail(input [8*100-1:0] msg);
        begin $display("FAIL %0s", msg); errs = errs + 1; end
    endtask

    initial begin
        if (!$value$plusargs("PAUSE=%d", do_pause)) do_pause = 1;
        $readmemh("bench/dvd/test_ac3/tone_1k_48k_stereo_192k.ac3.frame0.hex", frame0);
        for (i = 0; i < N * FLEN; i = i + 1) mem[i] = frame0[i % FLEN];
        repeat (5) @(posedge clk);
        rst_n = 1;

        // play two frames' worth (the gate releases at PTS 0 at once)
        t = 0;
        while (samples < 2 * SPF && t < 20_000_000) begin @(posedge clk); t = t + 1; end
        if (samples < 2 * SPF) fail("[setup] two frames never played -- the fixture or the gate, not the pause");

        if (do_pause) begin
            s_at_pause      = samples;
            resets_at_pause = ac3_resets;
            rearm_at_pause  = rearm_cnt;
            pause = 1;
            repeat (PAUSE_WD * (1 << WDOG_W)) @(posedge clk);
            s_at_resume = samples;
            if (s_at_resume != s_at_pause)
                fail("[hold] samples left the output while paused");
            if (ac3_resets != resets_at_pause) begin
                $display("      %0d self-heal resets during a %0d-period pause", ac3_resets - resets_at_pause, PAUSE_WD);
                fail("[reset] the decoder was reset while paused");
            end
            if (rearm_cnt != rearm_at_pause)
                fail("[rearm] the gate re-armed while paused");
            pause = 0;
        end

        // let the rest of the stream play out
        t = 0;
        while (samples < N * SPF && t < (N + 2) * 900_000) begin @(posedge clk); t = t + 1; end
        repeat (200_000) @(posedge clk);           // and anything extra would show up here
        $display("  [count] %0d samples of %0d (%0d frames lost)", samples, N * SPF,
                 (N * SPF - samples) / SPF);
        if (samples != N * SPF) fail("[count] the listener did not get every sample of every frame");

        if (errs == 0) $display("PASS: pause_wdog_tb (pause=%0d)", do_pause);
        else           $fatal(1, "FAIL: pause_wdog_tb (pause=%0d), %0d errors", do_pause, errs);
        $finish;
    end
endmodule
