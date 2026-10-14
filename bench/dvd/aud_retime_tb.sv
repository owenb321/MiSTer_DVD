//============================================================================
//  aud_retime_tb.sv — the IN-BAND TIMELINE RE-TIME in dvd/dvd_audio_decode.sv
//  (docs/nonseamless_audio.md 4a).
//
//  A content discontinuity restarts the audio PTS in the stream itself. The
//  dispatcher must hold the frame that carries it until the old timeline's
//  audio has played out, re-arm the gate with empty FIFOs, and release the new
//  head only once the clock is on the new timeline. Nothing is discarded except
//  a new head that the clock has already passed on its own timeline (overlap).
//
//  Every LPCM sample in this bench is UNIQUE: L = {timeline, frame, sample},
//  R = ~L. The capture records every value that leaves the module, in order,
//  with the STC at that moment, so each claim below is scored against what a
//  listener would hear -- which samples, in which order, on which timeline.
//
//    S1 display crosses exactly when the old audio ends  -> seamless, all kept
//    S2 old audio ends 150 ms BEFORE the display crosses -> no new-timeline
//       sample while the clock is on the old one; the head plays at its PTS
//    S3 old audio OVERLAPS the crossing by 70 ms          -> old tail kept, the
//       new head trimmed only until it is within STALE of the clock
//    S4 FORWARD jump > DISC_FWD (authored audio gap)     -> the head waits for
//       its PTS instead of playing early
//    S5 continuous stream (control)                      -> no hold, no re-arm
//    S6 the clock never re-anchors                       -> the fallback still
//       plays the new audio (no silence wedge)
//    S7 (HW, ULTIMATE_T2 boot -> menu) the clock is ALREADY on the new timeline
//       after a still; the first new audio arrives 0.6 s late with current audio
//       behind it -> the stale head is discarded, playback lands in phase (the
//       first build held it as "other timeline" and played it 2.5 s late)
//    S8 a head latched on its own timeline goes stale when a SECOND re-anchor
//       leaves it 0.7 s behind (arrivals agree) -> exactly one resync_req, and the
//       fresh audio after that reset plays in phase (the one case the hold cannot
//       prevent, since the latch was correct when it was taken)
//    S9 (HW, The Matrix white-rabbit cells) a PTS restart on frames stamped
//       SEAMLESS (audio_ring's per-frame cell_seamless), and the display re-anchors
//       to a picture 0.21 s off the audio -> sample-continuous: no re-time, no gap,
//       nothing lost (the first cut re-timed it: ~190 ms gap, then 0.2 s late)
//    S10 a NON-seamless join whose old audio ends 50 ms before its video and whose
//       new audio starts 0.2 s BEFORE its first picture:
//       the head must wait for the clock (arrivals agreeing) and then be trimmed to
//       land in phase -- dispatched early it latches, and releases 0.2 s late
//    S11 the old audio ends 0.5 s before the display crosses -- LONGER than HOLD_W,
//       so the hold times out and the head latches on the OLD clock; the release
//       window must then keep it waiting until the crossing (without it the new
//       clip plays early, against the old clock)
//    S12 (HW round 3, ULTIMATE_T2 boot -> menu, measured to the cycle) the old
//       timeline's LAST frame arrives after an underrun and latches; the display
//       then jumps BACKWARD to a one-picture, no-audio still cell (c1), holds it,
//       and the next cell's audio arrives before its first picture re-anchors.
//       The orphaned latch must be released at the backward jump, so the new
//       audio starts IN PHASE right after its picture -- not after HOLD_W and a
//       reset (~0.7 s later than the pre-change build)
//    S13 (issue #176, Mad Dog: the gunshot after a hit went silent for ~0.8 s) the
//       old timeline's audio plays out and UNDERRUNS first; only THEN does the new
//       cell's audio arrive (40 ms after), and the display crosses 60 ms after that.
//       The reader held the cell command until the VBUF drained, so nothing of the
//       new cell was parsed before the old audio ran out. The new head must play at
//       its PTS right at the crossing -- not after the hold's HOLD_W timeout.
//  S1-S7 must raise NO resync_req. The bench models the demux's arrival front
//  (arr_pts = the newest committed frame) and, on resync_req, the flush_ctl
//  aud_resync it causes (decoder reset + ring discard).
//
//  RED arms (bench/dvd/run_aud_retime.sh) each remove one step and must fail
//  their own scenario.
//============================================================================
`timescale 1ns/1ps

module aud_retime_tb;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0;

    // ---- ring read-side model (bigger than dvd_audio_decode_tb's) ----------
    localparam int MEM   = 1 << 18;          // bytes
    localparam int NDESC = 512;
    logic [7:0]  mem [0:MEM-1];
    integer      committed = 0, rd = 0;
    logic [15:0] desc_len  [0:NDESC-1];
    logic [32:0] desc_pts  [0:NDESC-1];
    logic        desc_ptsv [0:NDESC-1];
    logic        desc_seam [0:NDESC-1];      // audio_ring's per-frame seamless stamp
    logic        seam_next = 0;              // stamp for frames add_frame builds next
    integer      ndesc = 0, dptr = 0;

    // STAGED: frames are built into mem/desc, then PUBLISHED (made visible to the
    // dispatcher) only after the arrival front has moved -- in the core the demux
    // parses a frame (arr_pts) before audio_ring commits it, never after.
    integer      committed_pub = 0, ndesc_pub = 0;
    wire  [7:0]  ring_byte = mem[rd];
    wire         ring_valid = (rd < committed_pub);
    wire         ring_ready;
    wire         frame_valid = (dptr < ndesc_pub);
    wire  [15:0] frame_len   = desc_len[dptr];
    wire  [32:0] frame_pts   = desc_pts[dptr];
    wire         frame_pts_valid = desc_ptsv[dptr];
    wire         frame_seamless  = desc_seam[dptr];
    wire         frame_pop;

    always @(posedge clk) if (rst_n) begin
        if (ring_ready && ring_valid) rd   <= rd + 1;
        if (frame_pop  && frame_valid) dptr <= dptr + 1;
    end

    // ---- the clock: 90 kHz from a 2.7 MHz clk_sys = one tick per 30 clk -------
    // The DUT runs with CLK_HZ = 2.7 MHz (its 48 kHz NCO then ticks every 56.25
    // clk) -- 10x fewer cycles per second of audio than 27 MHz, same arithmetic.
    logic [32:0] stc = '0;
    logic        stc_run = 0;
    integer      tick_div = 0;
    always @(posedge clk) begin
        if (stc_run) begin
            if (tick_div == 29) begin tick_div <= 0; stc <= stc + 33'd1; end
            else tick_div <= tick_div + 1;
        end
    end

    logic sched_en = 1, stc_anchored = 1, disp_anchored = 1, video_live = 1;
    // the demux's arrival front: the newest frame committed to the ring
    logic [32:0] arr_pts = '0;
    logic        arr_pts_valid = 0;     // driven on NEGEDGES by publish (no NBA race)
    // the display's CONTENT-jump pulse (disp_sched anchor_disc -> emu rephase_req):
    // fires on a BACKWARD re-anchor, never on the first anchor after a flush
    logic        anchor_disc = 0;
    // +S=<n> runs only scenario n (the RED arms each run their own; 0 = all)
    integer      only = 0;
    initial if (!$value$plusargs("S=%d", only)) only = 0;
    function automatic bit run_s(input integer n); run_s = (only == 0) || (only == n); endfunction
    // resync_req -> the aud_resync it causes in emu (flush_ctl): decoder reset +
    // audio_ring discard. Counted per scenario.
    wire  resync_req;
    integer n_resync = 0;
    always @(posedge clk) if (resync_req) n_resync <= n_resync + 1;
    wire signed [15:0] audio_l, audio_r;
    wire [3:0] dbg_rearm_cnt, dbg_fbrel_cnt, dbg_catch_cnt, dbg_retime_cnt;
    wire [7:0] dbg_skip_cnt;

    // HOLD_W 20 = 2^20 clk = 388 ms and ARM_TIMEOUT_W 21 = 776 ms at 2.7 MHz. The
    // ORDER matters and mirrors the core (0.62 s < 2.5 s): the fallback must outlast
    // the hold, or a hold that times out (S11) is released by the fallback on the
    // old clock the same instant. Both longer than S2's deliberate 150 ms wait.
    dvd_audio_decode #(.CLK_HZ(2700000), .AUD_HZ(48000), .ARM_TIMEOUT_W(21), .HOLD_W(20)) dut ( .cb_cp_mode(1'b0), .cb_lpcm_step(1'b0), .cb_mp2_step(1'b0), .cb_lpcm_q(), .cb_mp2_q(), .cb_req(), .cb_sel(), .cb_addr(), .cb_valid(1'b0), .cb_data(64'd0), .dts_tables_ok(1'b0),
        .clk(clk), .rst_n(rst_n), .enable(1'b1), .pause(1'b0), .aud_soft_switch(1'b0),
        .ring_byte(ring_byte), .ring_valid(ring_valid), .ring_ready(ring_ready),
        .frame_valid(frame_valid), .frame_len(frame_len), .frame_type(2'd2),   // LPCM
        .lpcm_quant(2'd0), .lpcm_nch_m1(3'd1), .lpcm_fs96(1'b0), .lpcm_bad(1'b0),
        .link96(1'b0), .lpcm_unsup(), .frame_pts(frame_pts), .frame_pts_valid(frame_pts_valid),
        .frame_seamless(frame_seamless),
        .frame_pop(frame_pop),
        .cdda_mode(1'b0), .cdda_fs(2'd0), .cdda_wr_en(1'b0), .cdda_wr_data(8'd0),
        .cdda_flush(1'b0), .cdda_full(),
        .nco_trim(22'sd0), .dbg_play_cnt(), .dbg_gate_cnt(),
        .dispatch_pts(), .dispatch_pts_valid(),
        .sched_en(sched_en), .stc_anchored(stc_anchored), .disp_anchored(disp_anchored),
        .arr_pts(arr_pts), .arr_pts_valid(arr_pts_valid), .video_live(video_live), .stc(stc),
        .anchor_pulse(1'b0), .anchor_delta(34'sd0), .anchor_disc(anchor_disc), .av_ofs(18'sd0),
        .audio_l(audio_l), .audio_r(audio_r),
        .ac3_synced(), .ac3_err(), .dbg_ac3_resets(), .dbg_ac3_err_resets(),
        .dbg_draining(), .dbg_play_pts_valid(), .dbg_armed_data(), .dbg_skip_run(), .dbg_play_pts(),
        .dbg_rearm_cnt(dbg_rearm_cnt), .dbg_fbrel_cnt(dbg_fbrel_cnt), .dbg_skip_cnt(dbg_skip_cnt),
        .dbg_catch_cnt(dbg_catch_cnt), .dbg_retime_cnt(dbg_retime_cnt), .dbg_play_err(),
        .resync_req(resync_req),
        .dbg_cur_codec(), .dbg_mp2_avalid(), .dbg_mp2_s_nz(), .dbg_mp2_pcm_nz()
    );

    // ---- stream builder -------------------------------------------------------
    // SPF samples per frame; one sample = 1.875 ticks at 48 kHz, so a frame spans
    // SPF*15/8 ticks. The PTS of frame k of a timeline = base + k*FRAME_TICKS.
    localparam int SPF = 256;
    localparam int FRAME_TICKS = SPF * 15 / 8;          // 480 ticks = 5.33 ms
    function automatic [15:0] sval(input integer tl, input integer fr, input integer sm);
        sval = {tl[1:0], fr[5:0], sm[7:0]};             // unique within a scenario
    endfunction
    task automatic add_frame(input integer tl, input integer fr, input [32:0] pts);
        integer i; logic [15:0] v;
        begin
            for (i = 0; i < SPF; i = i + 1) begin
                v = sval(tl, fr, i);
                mem[committed + 4*i + 0] = v[15:8];  mem[committed + 4*i + 1] = v[7:0];
                mem[committed + 4*i + 2] = ~v[15:8]; mem[committed + 4*i + 3] = ~v[7:0];
            end
            desc_len[ndesc]  = SPF * 4;
            desc_pts[ndesc]  = pts;
            desc_ptsv[ndesc] = 1'b1;
            desc_seam[ndesc] = seam_next;
            committed = committed + SPF * 4;
            ndesc = ndesc + 1;
        end
    endtask
    // the demux's arrival front moves to the newest staged frame, THEN the ring
    // commits everything staged
    task automatic publish;
        begin
            if (ndesc > 0) begin
                @(negedge clk); arr_pts = desc_pts[ndesc-1]; arr_pts_valid = 1;
                @(negedge clk); arr_pts_valid = 0;
            end
            repeat (2) @(posedge clk);
            committed_pub = committed; ndesc_pub = ndesc;
        end
    endtask

    // ---- capture: every sample that leaves the module --------------------------
    localparam int NCAP = 40000;
    logic [15:0] cap_v   [0:NCAP-1];
    logic [32:0] cap_stc [0:NCAP-1];
    integer      cap_t   [0:NCAP-1];
    integer      ncap = 0, cyc = 0;
    logic [15:0] prev_l = 16'h0;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (rst_n && (audio_l !== prev_l)) begin
            prev_l <= audio_l;
            if (audio_l !== 16'h0 && ncap < NCAP) begin
                cap_v[ncap] = audio_l; cap_stc[ncap] = stc; cap_t[ncap] = cyc;
                ncap = ncap + 1;
            end
        end
    end

    integer errs = 0;
    task automatic fail(input [8*120-1:0] msg);
        begin $display("FAIL %0s", msg); errs = errs + 1; end
    endtask

    // fresh module state + empty model for each scenario
    task automatic fresh;
        begin
            // every scenario except S8 (which clears its own) must finish without one
            if (n_resync != 0) fail("a scenario other than S8 raised resync_req");
            rst_n = 0; stc_run = 0;
            repeat (10) @(posedge clk);
            committed = 0; rd = 0; ndesc = 0; dptr = 0; ncap = 0; prev_l = 16'h0;
            committed_pub = 0; ndesc_pub = 0; seam_next = 0;
            n_resync = 0;
            repeat (10) @(posedge clk);
            rst_n = 1;
        end
    endtask

    // what emu does with resync_req: aud_resync = reset the decoder AND discard the ring
    task automatic apply_resync;
        begin
            @(negedge clk); rst_n = 0;
            rd = committed_pub; dptr = ndesc_pub;         // audio_ring reset: queued data gone
            repeat (5) @(negedge clk); rst_n = 1;
        end
    endtask

    // index of the first capture from timeline tl (-1 if none)
    function automatic integer first_of(input integer tl);
        integer i; begin
            first_of = -1;
            for (i = ncap - 1; i >= 0; i = i - 1) if (cap_v[i][15:14] == tl[1:0]) first_of = i;
        end
    endfunction
    function automatic integer count_of(input integer tl);
        integer i; begin
            count_of = 0;
            for (i = 0; i < ncap; i = i + 1) if (cap_v[i][15:14] == tl[1:0]) count_of = count_of + 1;
        end
    endfunction
    // are timeline tl's samples contiguous, in order, starting at frame f0 sample 0?
    function automatic integer in_order(input integer tl, input integer f0);
        integer i, n, fr, sm; begin
            in_order = 1; n = 0;
            for (i = 0; i < ncap; i = i + 1) if (cap_v[i][15:14] == tl[1:0]) begin
                fr = f0 + n / SPF; sm = n % SPF;
                if (cap_v[i] !== sval(tl, fr, sm)) in_order = 0;
                n = n + 1;
            end
        end
    endfunction

    // run until `n` samples captured or a timeout (clk cycles)
    task automatic run_until(input integer n, input integer tmo);
        integer t; begin
            t = 0;
            while (ncap < n && t < tmo) begin @(posedge clk); t = t + 1; end
        end
    endtask

    localparam [32:0] OLD_BASE = 33'd1000000;   // old timeline (~11.1 s)
    localparam [32:0] NEW_BASE = 33'd9000;      // new timeline restarts near zero
    localparam int    N_OLD = 16, N_NEW = 8;
    localparam [32:0] OLD_END = OLD_BASE + N_OLD * FRAME_TICKS;

    // build the standard old+new stream, all committed at once (the ring is full
    // at a real join: the demux has parsed ~1 s past it)
    task automatic build_join(input [32:0] new_base);
        integer k; begin
            for (k = 0; k < N_OLD; k = k + 1) add_frame(1, k, OLD_BASE + k * FRAME_TICKS);
            for (k = 0; k < N_NEW; k = k + 1) add_frame(2, k, new_base + k * FRAME_TICKS);
        end
    endtask

    // start the old timeline: the clock sits at the old head, video live
    task automatic start_old;
        begin
            publish;
            stc = OLD_BASE; stc_run = 1;
        end
    endtask

    // the display crosses the join when the clock reaches `at` on the old timeline:
    // re-anchor it to `to` (the new cell's first picture PTS)
    // a display re-anchor: the clock jumps to `to`; a BACKWARD jump is a content
    // jump and pulses anchor_disc, exactly as disp_sched's anchor_disc does
    task automatic reanchor(input [32:0] to);
        begin
            @(negedge clk);                // negedge: the tick process's NBA cannot undo it
            if (to < stc) anchor_disc = 1;
            stc = to;
            @(negedge clk); anchor_disc = 0;
        end
    endtask
    task automatic cross_at(input [32:0] at, input [32:0] to);
        begin
            wait (stc >= at);
            reanchor(to);
        end
    endtask

    integer i0, f, n_old_exp, n_new_exp, r0, rt0;
    integer late;

    initial begin
        if (run_s(1)) begin
        // ======================= S1: crosses exactly at old end =================
            fresh; build_join(NEW_BASE); rt0 = dbg_retime_cnt; start_old;
            cross_at(OLD_END, NEW_BASE);
            run_until(N_OLD*SPF + N_NEW*SPF, 12_000_000);
            if (count_of(1) != N_OLD*SPF) fail("S1: old timeline lost samples");
            if (count_of(2) != N_NEW*SPF) fail("S1: new timeline lost samples (the head was discarded)");
            if (!in_order(1, 0) || !in_order(2, 0)) fail("S1: samples out of order");
            f = first_of(2);
            if (f >= 0 && cap_stc[f] >= OLD_BASE) fail("S1: new-timeline audio played while the clock was on the OLD timeline");
            if (f >= 0 && ((cap_stc[f] < NEW_BASE) || (cap_stc[f] > NEW_BASE + 60)))
                fail("S1: new head did not play at its PTS");
            if (f > 0 && (cap_t[f] - cap_t[f-1]) > 400) fail("S1: gap at a seamless crossing (> ~7 samples)");
            if (dbg_retime_cnt != rt0 + 1) fail("S1: expected exactly one re-time");
            if (errs == 0) $display("  [S1] crossing at the old end: all %0d+%0d samples, new head at stc=%0d (PTS %0d), gap %0d clk",
                                    count_of(1), count_of(2), cap_stc[f], NEW_BASE, cap_t[f]-cap_t[f-1]);
    
        end
        if (run_s(2)) begin
        // ======================= S2: old audio ends 150 ms early =================
            r0 = errs;
            fresh; build_join(NEW_BASE); start_old;
            cross_at(OLD_END + 33'd13500, NEW_BASE);           // video runs 150 ms past the audio
            run_until(N_OLD*SPF + N_NEW*SPF, 20_000_000);
            f = first_of(2);
            if (count_of(2) != N_NEW*SPF) fail("S2: new timeline lost samples");
            if (f < 0) fail("S2: new timeline never played");
            else begin
                if (cap_stc[f] >= OLD_BASE)
                    fail("S2: new-timeline audio played while the clock was on the OLD timeline (released early)");
                if ((cap_stc[f] < NEW_BASE) || (cap_stc[f] > NEW_BASE + 60))
                    fail("S2: new head did not play at its PTS on the new timeline");
            end
            if (errs == r0) $display("  [S2] old audio short by 150 ms: silence, then the new head at stc=%0d (PTS %0d)", cap_stc[f], NEW_BASE);
    
        end
        if (run_s(3)) begin
        // ======================= S3: old audio overlaps by 100 ms ================
            r0 = errs;
            fresh; build_join(NEW_BASE); start_old;
            cross_at(OLD_END - 33'd6300, NEW_BASE);            // display crosses 70 ms before the audio ends
            run_until(N_OLD*SPF + 1, 20_000_000);
            run_until(ncap + 2*SPF, 4_000_000);
            if (count_of(1) != N_OLD*SPF) fail("S3: the old tail was cut (it must play out)");
            f = first_of(2);
            if (f < 0) fail("S3: new timeline never played");
            else begin
                // lateness of the first new sample on its own timeline, in ticks
                late = cap_stc[f] - (NEW_BASE + (((cap_v[f][13:8]) * FRAME_TICKS) + (cap_v[f][7:0] * 15) / 8));
                if (cap_v[f][7:0] != 0) fail("S3: first new sample is not a frame head");
                if (late > 4500 + 60) fail("S3: new timeline resumed more than STALE late (the overlap was not trimmed)");
                if (late < -60) fail("S3: new timeline resumed EARLY");
                if (cap_v[f][13:8] == 0) fail("S3: nothing was trimmed although the head was 70 ms late");
                if (!in_order(2, cap_v[f][13:8])) fail("S3: new samples out of order after the trim");
            end
            if (errs == r0) $display("  [S3] 70 ms overlap: old tail intact, %0d new frames trimmed, resumed %0d ticks late",
                                     cap_v[f][13:8], late);
    
        end
        if (run_s(4)) begin
        // ======================= S4: forward jump > DISC_FWD =====================
            r0 = errs;
            fresh;
            begin : s4
                integer k;
                for (k = 0; k < 8; k = k + 1) add_frame(1, k, OLD_BASE + k * FRAME_TICKS);
                for (k = 0; k < 4; k = k + 1) add_frame(2, k, OLD_BASE + 8*FRAME_TICKS + 33'd180000 + k * FRAME_TICKS);
            end
            start_old;
            run_until(8*SPF, 4_000_000);                       // old stretch played out
            repeat (20000) @(posedge clk);
            if (count_of(2) != 0) fail("S4: the head after a 2 s forward gap played EARLY");
            @(negedge clk); stc = OLD_BASE + 8*FRAME_TICKS + 33'd180000 - 33'd300;   // fast-forward the (continuous) clock
            run_until(12*SPF, 4_000_000);
            f = first_of(2);
            if (f < 0) fail("S4: the head after the gap never played");
            else if ((cap_stc[f] < OLD_BASE + 8*FRAME_TICKS + 33'd180000) ||
                     (cap_stc[f] > OLD_BASE + 8*FRAME_TICKS + 33'd180000 + 60))
                fail("S4: the head after the gap did not play at its PTS");
            if (errs == r0) $display("  [S4] 2 s forward gap: head held, played at its PTS");
    
        end
        if (run_s(5)) begin
        // ======================= S5: continuous stream (control) ================
            r0 = errs;
            fresh;
            begin : s5
                integer k;
                for (k = 0; k < 16; k = k + 1) add_frame(1, k, OLD_BASE + k * FRAME_TICKS);
            end
            rt0 = dbg_retime_cnt;
            start_old;
            run_until(16*SPF, 8_000_000);
            if (count_of(1) != 16*SPF || !in_order(1, 0)) fail("S5: continuous stream lost or reordered samples");
            if (dbg_retime_cnt != rt0) fail("S5: a continuous stream triggered a re-time");
            if (dbg_rearm_cnt != 0)    fail("S5: a continuous stream re-armed the gate mid-play");
            begin : s5gap
                integer k, mx; mx = 0;
                for (k = 1; k < ncap; k = k + 1) if (cap_t[k] - cap_t[k-1] > mx) mx = cap_t[k] - cap_t[k-1];
                if (mx > 120) fail("S5: a gap inside a continuous stream");
            end
            if (errs == r0) $display("  [S5] continuous control: no re-time, no re-arm, no gap");
    
        end
        if (run_s(6)) begin
        // ======================= S6: the clock never re-anchors =================
            r0 = errs;
            fresh; build_join(NEW_BASE); start_old;
            run_until(N_OLD*SPF + 1, 40_000_000);              // 2^17-clk fallback must fire
            f = first_of(2);
            if (f < 0) fail("S6: the new timeline never played without a re-anchor (silence wedge)");
            if (errs == r0) $display("  [S6] no re-anchor: the fallback released the new timeline (fbrel=%0d)", dbg_fbrel_cnt);
    
            if (n_resync != 0) fail("S6: resync_req fired");
    
        end
        if (run_s(7)) begin
        // ======================= S7: T2 -- late head, clock already new ============
            r0 = errs;
            fresh;
            begin : s7
                integer k, nf, skip0; logic [32:0] t_new;
                for (k = 0; k < 4; k = k + 1) add_frame(1, k, OLD_BASE + k * FRAME_TICKS);
                start_old;
                run_until(4*SPF, 4_000_000);                   // old segment plays out
                repeat (2000) @(posedge clk);                  // underrun: the gate re-arms (a still)
                // the display crossed into the new segment 0.6 s before its audio arrives
                reanchor(NEW_BASE + 33'd54000);
                skip0 = dbg_skip_cnt;
                nf = (54000 + 27000) / FRAME_TICKS;            // audio from 0.6 s late to 0.3 s ahead
                for (k = 0; k < nf; k = k + 1) add_frame(2, k % 64, NEW_BASE + k * FRAME_TICKS);
                publish;
                run_until(4*SPF + 2*SPF, 6_000_000);
                f = first_of(2);
                if (f < 0) fail("S7: the new segment never played");
                else begin
                    // its PTS = NEW_BASE + (frame index)*FRAME_TICKS; frame index mod 64 is in
                    // the sample value -- recover the absolute index from the time instead
                    late = cap_stc[f] - (NEW_BASE + 33'd54000);  // clock advance since the crossing
                    if (cap_v[f][7:0] != 0) fail("S7: first new sample is not a frame head");
                    // the frame played must be within STALE of the clock
                    begin : s7late
                        integer fi, best; best = 1 << 30;
                        for (fi = 0; fi < nf; fi = fi + 1)
                            if ((fi % 64) == cap_v[f][13:8]) begin
                                integer d; d = cap_stc[f] - (NEW_BASE + fi * FRAME_TICKS);
                                if (d >= -60 && d < best) best = d;
                            end
                        late = best;
                    end
                    if (late > 4500 + 60) fail("S7: the new segment played LATE (stale head not discarded)");
                    if (dbg_skip_cnt == skip0) fail("S7: nothing was discarded although the head was 0.6 s late");
                end
                if (dbg_fbrel_cnt != 0) fail("S7: released by the fallback timer");
                if (n_resync != 0) fail("S7: resync_req fired (the dispatch-side discard should suffice)");
                if (errs == r0) $display("  [S7] T2 shape: stale head discarded, new segment in phase (%0d ticks late)", late);
            end
    
        end
        if (run_s(8)) begin
        // ======================= S8: a latched head goes stale ==================
            r0 = errs;
            fresh;
            begin : s8
                integer k, nf, c0;
                for (k = 0; k < 4; k = k + 1) add_frame(1, k, OLD_BASE + k * FRAME_TICKS);
                nf = 150;                                      // new timeline, 0..0.8 s
                for (k = 0; k < nf; k = k + 1) add_frame(2, k % 64, NEW_BASE + k * FRAME_TICKS);
                start_old;
                run_until(4*SPF, 4_000_000);                   // old tail plays; the new head is HELD
                repeat (20000) @(posedge clk);                 // (the clock is still on the old timeline)
                if (count_of(2) != 0) fail("S8: new timeline played against the OLD clock");
                // the display crosses: the clock lands 10 ms BEFORE the head -> the head
                // dispatches and latches as a retime arm, on its own timeline
                reanchor(NEW_BASE - 33'd900);
                repeat (400) @(posedge clk);
                if (!dut.play_pts_valid) fail("S8: setup -- the head did not latch on its own timeline");
                // a SECOND re-anchor leaves that latch 0.7 s behind (arrivals agreeing)
                reanchor(NEW_BASE + 33'd63000);
                k = 0;
                while (n_resync == 0 && k < 200000) begin @(posedge clk); k = k + 1; end
                if (n_resync != 1) fail("S8: no resync_req for a stale latch");
                else begin
                    apply_resync;                              // emu's aud_resync
                    c0 = ncap;
                    // fresh arrivals from the parse front, a little ahead of the clock
                    for (k = 0; k < 16; k = k + 1) add_frame(3, k, stc + 33'd900 + k * FRAME_TICKS);
                    publish;
                    run_until(c0 + SPF, 4_000_000);
                    f = first_of(3);
                    if (f < 0) fail("S8: nothing played after the re-phase");
                    else begin
                        late = cap_stc[f] - (desc_pts[ndesc-16]);
                        if (late < -60 || late > 60) fail("S8: audio after the re-phase is not in phase");
                    end
                    repeat (1000) @(posedge clk);
                    if (n_resync != 1) fail("S8: resync_req fired more than once");
                end
                if (errs == r0) $display("  [S8] stale latch: one resync_req, fresh audio in phase (%0d ticks)", late);
                n_resync = 0;                                  // S8's one request is accounted for
            end
    
        end
        if (run_s(9)) begin
        // ======================= S9: seamless PTS restart (Matrix) ===============
            r0 = errs;
            fresh;
            begin : s9
                integer k, mx, i0n; rt0 = dbg_retime_cnt;
                for (k = 0; k < N_OLD; k = k + 1) add_frame(1, k, OLD_BASE + k * FRAME_TICKS);
                seam_next = 1;                                 // the next cell is authored seamless_play
                for (k = 0; k < N_NEW; k = k + 1) add_frame(2, k, NEW_BASE + k * FRAME_TICKS);
                start_old;
                cross_at(OLD_END, NEW_BASE + 33'd18900);       // the first picture sits 0.21 s off the audio
                run_until(N_OLD*SPF + N_NEW*SPF, 12_000_000);
                if (count_of(1) != N_OLD*SPF || count_of(2) != N_NEW*SPF) fail("S9: samples lost at a seamless join");
                if (!in_order(1, 0) || !in_order(2, 0)) fail("S9: samples out of order at a seamless join");
                if (dbg_retime_cnt != rt0) fail("S9: a SEAMLESS join was re-timed");
                i0n = first_of(2);
                if (i0n > 0 && (cap_t[i0n] - cap_t[i0n-1]) > 120) fail("S9: a gap at a seamless join");
                if (n_resync != 0) fail("S9: resync_req at a seamless join");
                if (errs == r0) $display("  [S9] seamless restart: sample-continuous, %0d-clk step, no re-time", cap_t[i0n]-cap_t[i0n-1]);
            end
    
        end
        if (run_s(10)) begin
        // ======================= S10: audio leads its first picture ==============
            r0 = errs;
            fresh;
            begin : s10
                integer k;
                // a realistic ring: ~0.43 s of the new clip queued, so after the crossing
                // the arrival front LEADS the clock as it does in the core (8 frames =
                // 42 ms would leave the whole segment behind it -- starvation, not this)
                for (k = 0; k < N_OLD; k = k + 1) add_frame(1, k, OLD_BASE + k * FRAME_TICKS);
                for (k = 0; k < 80; k = k + 1)    add_frame(2, k, NEW_BASE + k * FRAME_TICKS);
                start_old;
                // the old clip's audio ends 50 ms BEFORE its video (so a head dispatched at
                // the underrun would latch on the OLD clock), and the new clip's first
                // picture is 0.2 s after its audio head
                cross_at(OLD_END + 33'd4500, NEW_BASE + 33'd18000);
                run_until(N_OLD*SPF + SPF, 12_000_000);
                f = first_of(2);
                if (f < 0) fail("S10: the new clip never played");
                else begin
                    late = cap_stc[f] - (NEW_BASE + cap_v[f][13:8] * FRAME_TICKS + (cap_v[f][7:0] * 15) / 8);
                    if (late > 4500 + 60) fail("S10: the new clip played LATE (the head latched on the old clock)");
                    if (late < -60)       fail("S10: the new clip played EARLY");
                end
                if (n_resync != 0) fail("S10: resync_req fired (the hold should have made it unnecessary)");
                if (errs == r0) $display("  [S10] audio leads picture by 0.2 s: head waited, trimmed, in phase (%0d ticks)", late);
            end
    
        end
        if (run_s(11)) begin
        // ======================= S11: gap longer than HOLD_W =======================
            r0 = errs;
            fresh; build_join(NEW_BASE); start_old;
            cross_at(OLD_END + 33'd45000, NEW_BASE);           // 0.5 s > HOLD_W (388 ms here)
            run_until(N_OLD*SPF + N_NEW*SPF, 20_000_000);
            f = first_of(2);
            if (f < 0) fail("S11: the new clip never played");
            else begin
                if (cap_stc[f] >= OLD_BASE)
                    fail("S11: new-timeline audio played while the clock was on the OLD timeline (hold expired, no window)");
                else if ((cap_stc[f] < NEW_BASE) || (cap_stc[f] > NEW_BASE + 60))
                    fail("S11: new head did not play at its PTS");
            end
            if (errs == r0) $display("  [S11] gap longer than HOLD_W: latched on the old clock, released at its PTS (stc=%0d)", cap_stc[f]);
    
        end
        // ======================= S12: T2 -- an orphaned latch ======================
        if (run_s(12)) begin
            r0 = errs;
            fresh;
            begin : s12
                integer k, c0, t_anchor;
                logic [32:0] still_clk;
                // c0: the old timeline, all but its last frame
                for (k = 0; k < 8; k = k + 1) add_frame(1, k, OLD_BASE + k * FRAME_TICKS);
                start_old;
                run_until(8*SPF, 4_000_000);
                repeat (400) @(posedge clk);                   // underrun: the gate re-arms
                // c0's LAST frame arrives late and latches, a little ahead of the clock
                add_frame(1, 8, stc + 33'd900);
                publish;
                repeat (400) @(posedge clk);
                if (!dut.play_pts_valid) fail("S12: setup -- c0's last frame did not latch");
                // c1: the display jumps BACKWARD to a one-picture, no-audio still
                still_clk = 33'd390000;                        // a clock far from c2's PTS
                reanchor(still_clk);
                repeat (30000) @(posedge clk);                 // the still is held (~0.33 s)
                // c2: its audio arrives (PTS restarts), then its first picture anchors
                c0 = ncap;
                for (k = 0; k < 80; k = k + 1) add_frame(2, k, 33'd3960 + k * FRAME_TICKS);
                publish;
                repeat (1800) @(posedge clk);                  // ~20 ms: the picture follows
                t_anchor = cyc;
                reanchor(33'd5670);                            // c2's first picture, 0.063 s
                run_until(c0 + SPF + 1, 4_000_000);
                f = first_of(2);
                if (f < 0) fail("S12: c2 never played");
                else begin
                    late = cap_stc[f] - (33'd3960 + cap_v[f][13:8] * FRAME_TICKS + (cap_v[f][7:0] * 15) / 8);
                    if (cap_t[f] - t_anchor > 5400)
                        fail("S12: c2 started late after its picture (waited behind the orphaned latch)");
                    if (late > 4500 + 60 || late < -60) fail("S12: c2 is not in phase");
                end
                if (n_resync != 0) fail("S12: resync_req fired (the orphan should have been released instead)");
                if (errs == r0) $display("  [S12] T2: orphaned latch released, c2 in phase %0d clk after its picture (%0d ticks)",
                                         cap_t[f] - t_anchor, late);
            end
        end
        if (run_s(13)) begin
        // ======================= S13: the new audio arrives AFTER the old underran ======
            r0 = errs;
            fresh;
            for (i0 = 0; i0 < N_OLD; i0 = i0 + 1) add_frame(1, i0, OLD_BASE + i0 * FRAME_TICKS);
            start_old;
            wait (stc >= OLD_END + 33'd3600);                   // old audio ran out 40 ms ago
            for (i0 = 0; i0 < N_NEW; i0 = i0 + 1) add_frame(2, i0, NEW_BASE + i0 * FRAME_TICKS);
            publish;                                            // the new cell's first audio arrives
            cross_at(OLD_END + 33'd9000, NEW_BASE);             // display crosses 60 ms later
            run_until(N_OLD*SPF + N_NEW*SPF, 20_000_000);
            f = first_of(2);
            if (count_of(1) != N_OLD*SPF) fail("S13: old timeline lost samples");
            if (f < 0) fail("S13: new timeline never played");
            else begin
                if (cap_stc[f] >= OLD_BASE)
                    fail("S13: new-timeline audio played while the clock was on the OLD timeline");
                if (cap_stc[f] > NEW_BASE + 33'd4500)
                    fail("S13: the new head played > 50 ms after its PTS (a silent gap after the join)");
            end
            if (errs == r0) $display("  [S13] head after the underrun: new head at stc=%0d (PTS %0d), %0d of %0d new samples",
                                     cap_stc[f], NEW_BASE, count_of(2), N_NEW*SPF);
            else if (f >= 0) $display("  [S13] measured: new head at stc=%0d (PTS %0d) = %0d ms late, %0d of %0d new samples",
                                      cap_stc[f], NEW_BASE, (cap_stc[f] - NEW_BASE) / 90, count_of(2), N_NEW*SPF);
        end

        if (errs == 0) $display("PASS: aud_retime_tb (S1-S12)");
        else begin $display("FAIL: aud_retime_tb -- %0d error(s)", errs); $fatal(1); end
        $finish;
    end
endmodule
