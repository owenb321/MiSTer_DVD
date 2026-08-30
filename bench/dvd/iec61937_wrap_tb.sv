// -----------------------------------------------------------------
// bench/dvd/iec61937_wrap_tb.sv
// Verifies the IEC 61937 producer word-stream layout (Pa/Pb/Pc/Pd,
// payload packing, byte_swap, zero-pad to the burst period, null burst)
// and the non-PCM channel-status bit in the spdif_pass encoder.
// -----------------------------------------------------------------
`timescale 1ns/1ps

module iec61937_wrap_tb;

    localparam PA = 16'hF872, PB = 16'h4E1F, PC_AC3 = 16'h0001;

    reg         clk_sys = 0, clk_audio = 0;
    reg         rst_sys_n = 0, rst_audio_n = 0;
    reg         enable = 0, byte_swap = 0, mute = 0;

    // ring model
    reg  [7:0]  ring_byte;
    reg         ring_valid;
    wire        ring_ready;
    reg         frame_valid;
    reg  [15:0] frame_len;
    reg  [1:0]  frame_type;
    reg  [15:0] frame_samples;
    wire        frame_pop;
    // A/V sync inputs (free-run defaults for tests 1-5; driven in TESTs 6/7)
    reg         sync_armed_r  = 0;
    reg         stc_anch_r    = 0;
    reg  [32:0] stc_r         = 0;
    reg signed [17:0] avofs_r  = 0;
    reg  [32:0] fpts_r        = 0;
    reg         fptsv_r       = 0;

    wire        spdif_o;
    wire [15:0] dbg_word;
    wire        dbg_word_stb;
    wire [15:0] bs_l, bs_r;
    wire        bs_nonpcm, bs_stb;

    // ~27 MHz and 24.576 MHz
    always #18.5 clk_sys   = ~clk_sys;
    always #20.3 clk_audio = ~clk_audio;

    // Large FIFO so the producer never stalls waiting on the consumer during
    // the layout capture.
    iec61937_wrap #(.FIFO_AW(12)) dut (
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n), .enable(enable), .byte_swap(byte_swap),
        .mute_i(mute),
        .ring_byte(ring_byte), .ring_valid(ring_valid), .ring_ready(ring_ready),
        .frame_valid(frame_valid), .frame_len(frame_len), .frame_type(frame_type),
        .frame_samples(frame_samples),
        .frame_pts(fpts_r), .frame_pts_valid(fptsv_r),
        .sync_armed(sync_armed_r), .stc_anchored(stc_anch_r), .stc(stc_r), .av_ofs(avofs_r),
        .frame_pop(frame_pop),
        .clk_audio(clk_audio), .rst_audio_n(rst_audio_n), .spdif_o(spdif_o),
        .bs_l_o(bs_l), .bs_r_o(bs_r), .bs_nonpcm_o(bs_nonpcm), .bs_stb_o(bs_stb),
        .dbg_word(dbg_word), .dbg_word_stb(dbg_word_stb)
    );

    // ---- HDMI bitstream tap monitors (TEST 9) --------------------------------
    // The tap feeds the HDMI I2S serializer. Two properties must hold or the
    // HDMI path silently diverges from S/PDIF:
    //  (a) COHERENCE - the tap presents exactly the pair spdif_pass is playing,
    //      so both outputs carry the same burst. Structural today, but this
    //      guards a future refactor that gates one path and not the other.
    //  (b) PACING - in STEADY STATE the strobe is exactly one per 512 clk_audio
    //      (48.000 kHz). The whole no-handshake argument rests on this: the I2S
    //      frame is also 512 clk, so a fixed offset means one frame per pair,
    //      forever.
    //
    // MEASURED startup transient: the FIRST interval after an audio-domain reset
    // is 509, not 512. `bit_ce` is (ce_cnt==0) of a free-running 2-bit counter
    // that reset clears, while spdif_pass's own subframe counter restarts from
    // its reset state, so the two re-align three clk_audio into the first frame.
    // That is a genuine PHASE STEP against the I2S frame counter, and it is
    // exactly what the post-reset hold-off in sys/audio_out.v and dvd/emu.sv
    // exists to hide -- rst_audio_n pulses on every audio-track switch and
    // aud_flush, not just at power-on. Steady state must still be exact, so the
    // hard check starts once the transient has passed.
    localparam TAP_SETTLE = 4;   // strobes to ignore after a reset
    integer tap_incoherent = 0;
    integer tap_badperiod  = 0;  // steady-state deviations: must be ZERO
    integer tap_startup    = 0;  // transient deviations: one per reset, bounded
    integer tap_strobes    = 0;
    integer tap_resets     = 0;
    always @(posedge clk_audio) begin : tap_mon
        reg [15:0] gap;
        if (!rst_audio_n) begin
            if (tap_strobes != 0) tap_resets = tap_resets + 1;
            gap = 16'd0; tap_strobes = 0;
        end else begin
            if ({bs_r, bs_l} !== dut.u_spdif.sample_i || bs_nonpcm !== dut.u_spdif.nonpcm_i)
                tap_incoherent = tap_incoherent + 1;
            gap = gap + 16'd1;
            if (bs_stb) begin
                if (tap_strobes > 0 && gap != 16'd512) begin
                    if (tap_strobes < TAP_SETTLE) tap_startup   = tap_startup + 1;
                    else                          tap_badperiod = tap_badperiod + 1;
                end
                tap_strobes = tap_strobes + 1;
                gap = 16'd0;
            end
        end
    end

    // captured producer word stream, indexed by the DUT's word index so a
    // burst always lands at cap[0..N]; count committed words since reset.
    reg [15:0] cap [0:8191];
    integer    pulses = 0;
    always @(posedge clk_sys) begin
        if (!rst_sys_n) pulses <= 0;
        else if (dbg_word_stb) begin
            // dbg_word_stb is registered alongside widx's increment, so the
            // emitted word's true index is widx-1.
            if ((dut.widx - 17'd1) < 17'd8192) cap[dut.widx - 17'd1] <= dbg_word;
            pulses <= pulses + 1;
        end
    end

    // frame_pop counter (for the A/V-sync hold test)
    integer pop_count = 0;
    always @(posedge clk_sys) if (frame_pop) pop_count = pop_count + 1;

    // ring_ready counter (for the mute test: payload bytes must still DRAIN)
    integer rr_count = 0;
    always @(posedge clk_sys) if (ring_ready) rr_count = rr_count + 1;

    // ring byte source; restart at each frame_pop (frame repeats every burst)
    reg  [7:0] payload [0:63];
    integer    plen;
    integer    pidx = 0;
    always @(posedge clk_sys) begin
        if (frame_pop)        pidx <= 0;
        else if (ring_ready)  pidx <= pidx + 1;
    end
    always @(*) begin
        ring_byte  = payload[pidx];
        ring_valid = (pidx < plen);
    end

    task do_reset; begin
        enable = 0;                 // hold the producer idle across reset so the
        rst_sys_n = 0; rst_audio_n = 0;  // first post-reset burst reflects the new frame
        repeat (4) @(posedge clk_sys);
        rst_sys_n = 1; rst_audio_n = 1;
        repeat (2) @(posedge clk_sys);
    end endtask

    integer i, errors = 0;
    task expect_word(input integer idx, input [15:0] exp, input [8*16:1] name);
        begin
            if (cap[idx] !== exp) begin
                $display("  FAIL %0s: cap[%0d]=%04h expected %04h", name, idx, cap[idx], exp);
                errors = errors + 1;
            end
        end
    endtask

    // ---- non-PCM channel-status capture (encoder) ----
    // sample channel_status_bit_r at each left subframe load
    reg cs_seen [0:191];
    integer f;
    initial for (f=0;f<192;f=f+1) cs_seen[f]=1'bx;
    always @(posedge clk_audio)
        if (dut.u_spdif.load_subframe_q && dut.u_spdif.subframe_count_q[0]==1'b0) begin
            cs_seen[dut.u_spdif.subframe_count_q[8:1]] = dut.u_spdif.channel_status_bit_r;
        end

    initial begin
        // -------- TEST 1: AC-3 burst layout, byte_swap=0 --------
        ring_valid=0; frame_valid=0; frame_len=0; frame_type=0; frame_samples=0;
        plen = 8;
        for (i=0;i<8;i=i+1) payload[i] = (i+1)*8'h11; // 11 22 33 .. 88
        do_reset;

        enable=1; byte_swap=0;
        frame_len=16'd8; frame_type=2'd0; frame_valid=1;

        wait (pulses >= 3072);          // one full AC-3 burst produced
        @(posedge clk_sys);

        $display("TEST 1: AC-3 burst layout (byte_swap=0), pulses=%0d", pulses);
        expect_word(0, PA,       "Pa");
        expect_word(1, PB,       "Pb");
        expect_word(2, PC_AC3,   "Pc");
        expect_word(3, 16'd8*8,  "Pd");        // 64 bits
        expect_word(4, 16'h1122, "pl0");
        expect_word(5, 16'h3344, "pl1");
        expect_word(6, 16'h5566, "pl2");
        expect_word(7, 16'h7788, "pl3");
        expect_word(8, 16'h0000, "pad0");
        expect_word(3071, 16'h0000, "padLast");
        if (dut.cur_nonpcm !== 1'b1) begin
            $display("  FAIL: real AC-3 burst not tagged non-PCM"); errors=errors+1; end

        // -------- TEST 2: byte_swap=1 --------
        frame_valid = 0; do_reset;
        byte_swap = 1;
        frame_len = 16'd4; plen = 4; frame_type = 2'd0; frame_valid = 1;
        enable = 1;
        wait (pulses >= 3072);
        @(posedge clk_sys);
        $display("TEST 2: byte_swap=1");
        expect_word(4, 16'h2211, "pl0sw");
        expect_word(5, 16'h4433, "pl1sw");
        expect_word(6, 16'h0000, "pad-after-swap");

        // -------- TEST 3: odd frame_len tail --------
        frame_valid = 0; do_reset;
        byte_swap = 0;
        frame_len = 16'd3; plen = 3; frame_type = 2'd0; frame_valid = 1;
        enable = 1;
        wait (pulses >= 3072);
        @(posedge clk_sys);
        $display("TEST 3: odd length tail");
        expect_word(3, 16'd3*8,  "Pd-odd");
        expect_word(4, 16'h1122, "pl0-odd");
        expect_word(5, 16'h3300, "pl1-odd-tail"); // last byte + zero pad
        expect_word(6, 16'h0000, "pad-odd");

        // -------- TEST 4: hold/underflow burst = PCM SILENCE (no Pa/Pb) --------
        frame_valid = 0; do_reset;
        frame_valid = 0;   // stays low → silence bursts
        enable = 1;
        wait (pulses >= 3072);
        @(posedge clk_sys);
        $display("TEST 4: PCM-silence burst, cur_nonpcm=%0b", dut.cur_nonpcm);
        expect_word(0, 16'h0000, "sil-w0");    // no Pa
        expect_word(1, 16'h0000, "sil-w1");    // no Pb
        expect_word(2, 16'h0000, "sil-w2");
        expect_word(3, 16'h0000, "sil-w3");
        expect_word(4, 16'h0000, "sil-pad");
        if (dut.cur_nonpcm !== 1'b0) begin
            $display("  FAIL: silence burst not tagged PCM (cur_nonpcm=%0b)", dut.cur_nonpcm);
            errors=errors+1; end
        // the encoder must DROP the non-PCM channel-status bit for PCM silence
        // (after a 192-frame block boundary re-latches the flag)
        repeat (110000) @(posedge clk_audio);
        if (cs_seen[1] !== 1'b0) begin
            $display("  FAIL: non-PCM bit still set during PCM silence (cs[1]=%0b)", cs_seen[1]);
            errors=errors+1; end

        // -------- TEST 5: non-PCM channel status --------
        // The non-PCM bit latches once per 192-frame block (~98304 clk_audio); the
        // first block latches PCM before the FIFO fills, so run >=2 blocks for the
        // real-frame flag to assert (this ~4 ms lag at content start is expected HW
        // behaviour). 210000 cycles covers ~2.1 blocks.
        frame_valid = 0; do_reset;
        frame_len = 16'd8; plen = 8; frame_type = 2'd0; frame_valid = 1;
        enable = 1;
        repeat (210000) @(posedge clk_audio);
        $display("TEST 5: channel-status bits");
        if (cs_seen[1] !== 1'b1) begin $display("  FAIL: non-PCM bit (frame 1) not set"); errors=errors+1; end
        if (cs_seen[2] !== 1'b1) begin $display("  FAIL: frame 2 (copy) not set"); errors=errors+1; end
        if (cs_seen[15]!== 1'b1) begin $display("  FAIL: frame 15 not set"); errors=errors+1; end
        if (cs_seen[25]!== 1'b1) begin $display("  FAIL: frame 25 (48k) not set"); errors=errors+1; end
        if (cs_seen[0] === 1'b1) begin $display("  FAIL: frame 0 (consumer) should be 0"); errors=errors+1; end
        if (cs_seen[3] === 1'b1) begin $display("  FAIL: frame 3 should be 0"); errors=errors+1; end

        // -------- TEST 6: A/V sync hold (STC gate) --------
        // A frame whose PTS is ahead of the STC must be HELD (null bursts, no
        // frame_pop) until the STC reaches it, then emitted (real burst).
        // Inputs are set while disabled + given settle cycles to avoid a tb
        // clock-edge race (on HW these come from stable registers).
        frame_valid = 0; sync_armed_r = 0; stc_anch_r = 0; enable = 0; do_reset;
        byte_swap=0; frame_len=16'd8; plen=8; frame_type=2'd0;
        for (i=0;i<8;i=i+1) payload[i] = (i+1)*8'h11;
        fpts_r = 33'd100000; fptsv_r = 1'b1; avofs_r = 18'sd0;
        stc_r  = 33'd90000;         // 10000 ticks (~111 ms) BEFORE due -> hold
        sync_armed_r = 1'b1; stc_anch_r = 1'b1;   // anchored: exercise the due-time gate
        @(posedge clk_sys); @(posedge clk_sys);   // settle
        frame_valid = 1'b1;
        @(posedge clk_sys); @(posedge clk_sys);   // enable the producer after inputs are stable
        enable = 1'b1;
        @(posedge clk_sys); @(posedge clk_sys);
        pop_count = 0;
        // let a couple of burst periods elapse while holding
        wait (pulses >= 3072);
        @(posedge clk_sys);
        $display("TEST 6: A/V sync hold (stc<pts), pop_count=%0d", pop_count);
        if (pop_count !== 0) begin
            $display("  FAIL: frame popped while held (pop_count=%0d)", pop_count);
            errors = errors + 1;
        end
        expect_word(2, 16'h0000, "held-null-Pc");   // burst is a null (Pc=0)
        // now advance the STC past the frame PTS -> frame becomes due
        pop_count = 0;
        stc_r = 33'd110000;
        // wait for it to be emitted (bounded)
        for (i=0;i<20000 && pop_count==0;i=i+1) @(posedge clk_sys);
        $display("TEST 6b: STC advanced (stc>pts), pop_count=%0d", pop_count);
        if (pop_count == 0) begin
            $display("  FAIL: frame never emitted after STC caught up");
            errors = errors + 1;
        end

        // -------- TEST 7: anchor-gate + null-burst period tracking --------
        // (a) sync ARMED but STC NOT anchored -> a would-be-due frame is still HELD
        //     (null bursts, no pop) until the anchor arrives.
        // (b) the null/hold burst uses the DTS period (512 samples -> 1024 words),
        //     NOT the old hardcoded 1536, so the Pa/Pb grid matches the real burst.
        frame_valid=0; sync_armed_r=0; stc_anch_r=0; enable=0; do_reset;
        byte_swap=0; frame_len=16'd8; plen=8; frame_type=2'd1;   // DTS
        for (i=0;i<8;i=i+1) payload[i]=(i+1)*8'h11;
        fpts_r=33'd50000; fptsv_r=1'b1; avofs_r=18'sd0;
        stc_r=33'd90000;                    // STC well PAST pts: due-gate WOULD pass...
        sync_armed_r=1'b1; stc_anch_r=1'b0; // ...but not anchored -> must hold
        @(posedge clk_sys); @(posedge clk_sys);
        frame_valid=1'b1;
        @(posedge clk_sys); @(posedge clk_sys);
        enable=1'b1;
        @(posedge clk_sys); @(posedge clk_sys);
        pop_count=0;
        wait (pulses >= 1024);              // one DTS-period (512) burst = 1024 words
        @(posedge clk_sys);
        $display("TEST 7: anchor-gate hold (armed,!anchored), pop_count=%0d words_total=%0d",
                 pop_count, dut.words_total);
        if (pop_count !== 0) begin
            $display("  FAIL: frame emitted before the STC anchored"); errors=errors+1; end
        expect_word(2, 16'h0000, "pre-anchor-null-Pc");
        if (dut.words_total !== 17'd1024) begin
            $display("  FAIL: held-DTS null burst period=%0d words, expected 1024",
                     dut.words_total); errors=errors+1; end
        // now anchor -> the frame is due (stc>pts) and emits a real DTS burst
        pop_count=0;
        stc_anch_r=1'b1;
        for (i=0;i<20000 && pop_count==0;i=i+1) @(posedge clk_sys);
        $display("TEST 7b: anchored, pop_count=%0d", pop_count);
        if (pop_count==0) begin
            $display("  FAIL: DTS frame never emitted after the anchor"); errors=errors+1; end

        // -------- TEST 8: mute (CSS-scrambled source) --------
        // A codec frame with mute_i=1 must be CONSUMED (frame_pop, payload bytes
        // drained from the ring at the burst cadence) but emitted as PCM SILENCE
        // (all-zero words, no Pa/Pb, cur_nonpcm=0). Even a sync-HELD frame is
        // consumed (no STD-backpressure wedge). Unmute -> real bursts resume.
        frame_valid=0; sync_armed_r=0; stc_anch_r=0; enable=0; do_reset;
        byte_swap=0; frame_len=16'd8; plen=8; frame_type=2'd0;   // AC-3
        for (i=0;i<8;i=i+1) payload[i]=(i+1)*8'h11;
        fpts_r=33'd100000; fptsv_r=1'b1; avofs_r=18'sd0;
        stc_r=33'd90000;                     // pts AHEAD of stc: hold would engage...
        sync_armed_r=1'b1; stc_anch_r=1'b1;  // ...but mute must consume anyway
        mute=1'b1;
        @(posedge clk_sys); @(posedge clk_sys);
        frame_valid=1'b1; enable=1'b1;
        @(posedge clk_sys); @(posedge clk_sys);
        pop_count=0; rr_count=0;
        wait (pulses >= 3072);               // one AC-3-period burst
        @(posedge clk_sys); @(posedge clk_sys);  // settle past the pop-counter race
        $display("TEST 8: mute, pop_count=%0d rr_count=%0d", pop_count, rr_count);
        expect_word(0, 16'h0000, "mute-w0");   // no Pa
        expect_word(1, 16'h0000, "mute-w1");   // no Pb
        expect_word(2, 16'h0000, "mute-w2");   // Pc=0
        expect_word(3, 16'h0000, "mute-w3");   // Pd=0
        expect_word(4, 16'h0000, "mute-pl0");  // payload zeroed
        expect_word(5, 16'h0000, "mute-pl1");
        expect_word(6, 16'h0000, "mute-pl2");
        expect_word(7, 16'h0000, "mute-pl3");
        if (dut.cur_nonpcm !== 1'b0) begin
            $display("  FAIL: muted burst not tagged PCM"); errors=errors+1; end
        if (pop_count == 0) begin
            $display("  FAIL: muted frame never consumed (sync-hold wedge)"); errors=errors+1; end
        if (rr_count < 8) begin
            $display("  FAIL: payload bytes not drained from the ring (rr=%0d)", rr_count);
            errors=errors+1; end
        // unmute: real bursts resume (check burst 3's Pa after mute drops)
        mute=1'b0; stc_r=33'd200000;         // frame now due
        wait (pulses >= 3*3072);
        @(posedge clk_sys);
        $display("TEST 8b: unmute, cur_nonpcm=%0b", dut.cur_nonpcm);
        expect_word(0, PA,     "unmute-Pa");
        expect_word(1, PB,     "unmute-Pb");
        expect_word(2, PC_AC3, "unmute-Pc");
        if (dut.cur_nonpcm !== 1'b1) begin
            $display("  FAIL: unmuted burst not tagged non-PCM"); errors=errors+1; end

        // ---- TEST 9: HDMI bitstream tap -------------------------------------
        $display("TEST 9: HDMI tap, strobes=%0d incoherent=%0d steady_bad=%0d startup_dev=%0d (resets=%0d)",
                 tap_strobes, tap_incoherent, tap_badperiod, tap_startup, tap_resets);
        if (tap_strobes < 100) begin
            $display("  FAIL: tap strobe never ran (%0d)", tap_strobes); errors=errors+1; end
        if (tap_incoherent != 0) begin
            $display("  FAIL: tap diverged from the pair spdif_pass is playing (%0d cycles)",
                     tap_incoherent); errors=errors+1; end
        if (tap_badperiod != 0) begin
            $display("  FAIL: steady-state tap strobe not 512 clk_audio -- the fixed-offset");
            $display("        pacing argument is void and HDMI would slip against S/PDIF (%0d)",
                     tap_badperiod); errors=errors+1; end
        // The transient is expected and hold-off-covered, but it must stay a
        // transient: at most one short interval per reset. More than that means
        // the re-alignment is not settling and the hold-off cannot bound it.
        if (tap_startup > tap_resets + 1) begin
            $display("  FAIL: post-reset re-alignment not settling (%0d deviations, %0d resets)",
                     tap_startup, tap_resets); errors=errors+1; end

        if (errors==0) $display("\nALL TESTS PASSED");
        else           $display("\n%0d FAILURES", errors);
        $finish;
    end

    // safety timeout
    initial begin
        #60_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
