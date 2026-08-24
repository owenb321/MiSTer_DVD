//============================================================================
//  dvd_audio_decode_tb.sv — integration TB for dvd/dvd_audio_decode.sv
//
//  Models the audio_ring read side (committed byte stream + {len,type} frame
//  descriptor FIFO) and drives two frames through the dispatcher:
//    Phase A: an LPCM frame (type=2) -> verify the bytes are routed to
//             lpcm_unpack and pop out as the correct BE->LE s16 L/R pairs.
//    Phase B: a real AC-3 frame (type=0, first bytes of an ffmpeg 48k stereo
//             frame) -> verify the bytes are routed to ac3_front and it locks
//             sync (ac3_synced) with no err_unsupported.
//
//  This exercises the dispatch FSM contract (descriptor pop + exact-length byte
//  routing + per-codec sink-ready back-pressure) end-to-end.  Full AC-3 PCM
//  output is covered by the AC-3 core's own Verilator/liba52 cosim.
//    Phase C: the PTS-SCHEDULED DRAIN GATE (playback-start phase) — with the
//             gate armed, an early frame is decoded but NO samples exit until
//             STC >= play_pts + av_ofs; an output underrun re-arms the gate so
//             the next stretch re-enters at phase; sched_en=0 bypasses (free-run).
//============================================================================
`timescale 1ns/1ps

module dvd_audio_decode_tb;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n;

    // ring read-side model
    logic [7:0]  ring_byte;
    logic        ring_valid;
    wire         ring_ready;
    logic        frame_valid;
    logic [15:0] frame_len;
    logic [1:0]  frame_type;
    wire         frame_pop;

    wire signed [15:0] audio_l, audio_r;
    wire         ac3_synced, ac3_err;

    // PTS-scheduled drain controls (Phase C; off for Phases A/B)
    logic        sched_en     = 1'b0;
    logic        stc_anchored = 1'b0;
    logic        video_live   = 1'b1;   // display live (C1 exercises the 0 hold)
    logic [32:0] stc          = '0;
    logic signed [17:0] av_ofs = 18'sd0;
    logic [32:0] frame_pts;
    logic        frame_pts_valid;

    // arrival-front PTS (ps_demux parse tap; gates the mid-play catch-up, C9)
    logic [32:0] arr_pts       = '0;
    logic        arr_pts_valid = 1'b0;

    // drift-instrument counters (Phase C7)
    logic [3:0]  dbg_rearm_cnt, dbg_fbrel_cnt;
    logic [7:0]  dbg_skip_cnt;
    logic [15:0] dbg_play_err;

    // ARM_TIMEOUT_W shrunk 26 -> 13 (8192 clk) so the fallback release is testable.
    dvd_audio_decode #(.CLK_HZ(27000000), .AUD_HZ(48000), .ARM_TIMEOUT_W(13)) dut (
        .clk(clk), .rst_n(rst_n), .enable(1'b1), .pause(1'b0),
        .ring_byte(ring_byte), .ring_valid(ring_valid), .ring_ready(ring_ready),
        .frame_valid(frame_valid), .frame_len(frame_len), .frame_type(frame_type),
        .lpcm_quant(2'd0),           // 16-bit LPCM in this TB
        .frame_pts(frame_pts), .frame_pts_valid(frame_pts_valid),
        .frame_pop(frame_pop),
        .nco_trim(22'sd0), .dispatch_pts(), .dispatch_pts_valid(),
        .sched_en(sched_en), .stc_anchored(stc_anchored), .video_live(video_live),
        .arr_pts(arr_pts), .arr_pts_valid(arr_pts_valid),
        .stc(stc), .av_ofs(av_ofs),
        .audio_l(audio_l), .audio_r(audio_r),
        .ac3_synced(ac3_synced), .ac3_err(ac3_err),
        // drift-instrument counters (Phase C7)
        .dbg_rearm_cnt(dbg_rearm_cnt), .dbg_fbrel_cnt(dbg_fbrel_cnt),
        .dbg_skip_cnt(dbg_skip_cnt), .dbg_play_err(dbg_play_err)
    );

    // ---- byte ring + descriptor ring model -----------------------------
    localparam int MEM = 4096;
    logic [7:0]  mem [0:MEM-1];
    integer      committed = 0;       // bytes available on the stream
    integer      rd        = 0;       // stream read pointer

    localparam int NDESC = 16;
    logic [15:0] desc_len  [0:NDESC-1];
    logic [1:0]  desc_type [0:NDESC-1];
    logic [32:0] desc_pts  [0:NDESC-1];
    logic        desc_ptsv [0:NDESC-1];
    integer      ndesc = 0;           // descriptors enqueued
    integer      dptr  = 0;           // descriptor read pointer

    assign ring_byte  = mem[rd];
    always @(*) ring_valid = (rd < committed);
    always @(*) frame_valid = (dptr < ndesc);
    always @(*) frame_len   = desc_len[dptr];
    always @(*) frame_type  = desc_type[dptr];
    always @(*) frame_pts       = desc_pts[dptr];
    always @(*) frame_pts_valid = desc_ptsv[dptr];

    always @(posedge clk) begin
        if (rst_n) begin
            if (ring_ready && ring_valid) rd   <= rd + 1;
            if (frame_pop  && frame_valid) dptr <= dptr + 1;
        end
    end

    // ---- capture pairs as they appear on the MODULE OUTPUT (audio_l/r) -----
    // Sampling the real output (not an internal signal) is deliberate: it proves
    // the output mux actually latches decoded samples onto audio_l/r. Record each
    // new distinct (non-zero) output value.
    logic [15:0] cL [0:15];
    logic [15:0] cR [0:15];
    logic signed [15:0] pL = 0, pR = 0;
    integer cap = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            if ((audio_l !== pL) || (audio_r !== pR)) begin
                pL <= audio_l; pR <= audio_r;
                if ((audio_l !== 16'sd0) || (audio_r !== 16'sd0)) begin
                    if (cap < 16) begin cL[cap] = audio_l; cR[cap] = audio_r; end
                    cap = cap + 1;
                end
            end
        end
    end

    // free-running 48 kHz tick is internal (NCO); we also let it drain LPCM.

    integer errs = 0, i, t;
    integer ac3_n;
    logic [7:0] ac3hex [0:767];

    // golden LPCM pairs
    localparam int NP = 3;
    logic [15:0] gL [0:NP-1];
    logic [15:0] gR [0:NP-1];


    initial begin
        gL[0]=16'h1111; gR[0]=16'h2222;
        gL[1]=16'h8001; gR[1]=16'h7FFE;
        gL[2]=16'hABCD; gR[2]=16'hEF01;

        rst_n = 0;
        committed = 0; rd = 0; ndesc = 0; dptr = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;

        // ---------------- Phase A: LPCM frame ----------------
        for (i = 0; i < NP; i = i + 1) begin
            mem[i*4+0] = gL[i][15:8];
            mem[i*4+1] = gL[i][7:0];
            mem[i*4+2] = gR[i][15:8];
            mem[i*4+3] = gR[i][7:0];
        end
        for (i = 0; i < NDESC; i = i + 1) begin desc_pts[i] = '0; desc_ptsv[i] = 1'b0; end
        desc_len[0]  = NP*4;
        desc_type[0] = 2'd2;          // LPCM
        committed = NP*4;
        ndesc = 1;

        // wait for the dispatcher to consume the whole LPCM frame
        t = 0;
        while (rd < NP*4 && t < 100000) begin @(posedge clk); t = t + 1; end
        if (rd < NP*4) begin $display("FAIL: LPCM bytes not consumed (rd=%0d)", rd); errs=errs+1; end

        // give the internal 48 kHz NCO time to drain the LPCM pair FIFO
        // (27 MHz / 48 kHz ~= 562 clk per pair) — wait for NP pops.
        t = 0;
        while (cap < NP && t < 2000000) begin @(posedge clk); t = t + 1; end
        if (cap < NP) begin $display("FAIL: only %0d/%0d LPCM pairs popped", cap, NP); errs=errs+1; end
        for (i = 0; i < NP && i < cap; i = i + 1) begin
            if (cL[i] !== gL[i]) begin $display("FAIL LPCM %0d L dut=%04x exp=%04x", i, cL[i], gL[i]); errs=errs+1; end
            if (cR[i] !== gR[i]) begin $display("FAIL LPCM %0d R dut=%04x exp=%04x", i, cR[i], gR[i]); errs=errs+1; end
        end

        // ---------------- Phase B: AC-3 frame ----------------
        $readmemh("bench/dvd/test_ac3/tone_1k_48k_stereo_192k.ac3.frame0.hex", ac3hex);
        ac3_n = 96;                    // enough bytes to sync + parse the header
        for (i = 0; i < ac3_n; i = i + 1) mem[committed + i] = ac3hex[i];
        desc_len[1]  = ac3_n;
        desc_type[1] = 2'd0;           // AC-3
        committed = committed + ac3_n;
        ndesc = 2;

        // wait for sync lock
        t = 0;
        while (!ac3_synced && t < 200000) begin @(posedge clk); t = t + 1; end
        if (!ac3_synced) begin $display("FAIL: AC-3 did not sync"); errs=errs+1; end
        if (ac3_err)     begin $display("FAIL: AC-3 err_unsupported asserted"); errs=errs+1; end

        // ---------------- Phase C: PTS-scheduled DRAIN gate ----------------
        // C1: gate armed from the moment sched_en rises — held while the STC is
        // still UN-ANCHORED (v3.1: no pre-anchor bypass), still held while
        // stc < play_pts once anchored, releases exactly at stc = play_pts.
        sched_en     = 1'b1;
        stc_anchored = 1'b0;                                  // no video PTS yet
        av_ofs       = 18'sd0;
        stc          = 33'd2000000;
        begin
            integer cap0;
            cap0 = cap;
            mem[committed+0]=8'h11; mem[committed+1]=8'h22;   // L=0x1122
            mem[committed+2]=8'h33; mem[committed+3]=8'h44;   // R=0x3344
            desc_len[2]  = 4;
            desc_type[2] = 2'd2;                              // LPCM
            desc_pts[2]  = stc + 33'd9000;                    // 100 ms early
            desc_ptsv[2] = 1'b1;
            committed = committed + 4;
            ndesc = 3;
            // v5.1: dispatch itself is HELD while the STC is un-anchored (the
            // pre-anchor race let stale audio into the FIFOs and poisoned
            // play_pts). The frame must NOT dispatch yet.
            repeat (2000) @(posedge clk);                     // < pre-anchor fallback (4096)
            if (dptr != 2) begin $display("FAIL C1: dispatched before the STC anchored (dptr=%0d)", dptr); errs=errs+1; end
            if (cap != cap0) begin $display("FAIL C1: samples leaked while STC un-anchored (cap %0d->%0d)", cap0, cap); errs=errs+1; end
            stc_anchored = 1'b1;                              // video PTS arrives; stc < pts
            t = 0;                                            // now it dispatches (drain still held)
            while (dptr != 3 && t < 10000) begin @(posedge clk); t = t + 1; end
            if (dptr != 3) begin $display("FAIL C1: frame did not dispatch after anchor"); errs=errs+1; end
            repeat (1000) @(posedge clk);
            if (cap != cap0) begin $display("FAIL C1: samples exited before schedule (cap %0d->%0d)", cap0, cap); errs=errs+1; end
            video_live = 1'b0;                                // display not yet live:
            stc = desc_pts[2];                                // schedule reached but must HOLD
            repeat (1000) @(posedge clk);
            if (cap != cap0) begin $display("FAIL C1: released while video not live"); errs=errs+1; end
            video_live = 1'b1;                                // display shows its first frame
            t = 0;
            while (cap < cap0+1 && t < 200000) begin @(posedge clk); t = t + 1; end
            if (cap < cap0+1) begin $display("FAIL C1: samples did not play at schedule"); errs=errs+1; end
            else if (cL[cap0] !== 16'h1122 || cR[cap0] !== 16'h3344)
                 begin $display("FAIL C1: wrong sample at head (%04x/%04x)", cL[cap0], cR[cap0]); errs=errs+1; end
            else $display("  [C1] held un-anchored + early, released at stc = play_pts");
        end

        // C2: the C1 frame drains dry -> UNDERRUN re-arms the gate; the next early
        // frame is held again and plays only at its schedule (re-entry at phase).
        begin
            integer cap0;
            repeat (5000) @(posedge clk);                     // let C1 finish + underrun
            cap0 = cap;
            mem[committed+0]=8'h55; mem[committed+1]=8'h66;
            mem[committed+2]=8'h77; mem[committed+3]=8'h88;
            desc_len[3]  = 4;
            desc_type[3] = 2'd2;
            desc_pts[3]  = stc + 33'd9000;                    // early again
            desc_ptsv[3] = 1'b1;
            committed = committed + 4;
            ndesc = 4;
            repeat (3000) @(posedge clk);
            if (cap != cap0) begin $display("FAIL C2: no re-arm after underrun (cap %0d->%0d)", cap0, cap); errs=errs+1; end
            stc = desc_pts[3];
            t = 0;
            while (cap < cap0+1 && t < 200000) begin @(posedge clk); t = t + 1; end
            if (cap < cap0+1) begin $display("FAIL C2: re-armed drain did not release at schedule"); errs=errs+1; end
            else $display("  [C2] underrun re-armed; next stretch re-entered at phase");
        end

        // C3: sched_en=0 (Genlock Off) bypasses — early frame plays immediately.
        begin
            integer cap0;
            repeat (5000) @(posedge clk);                     // drain dry + re-arm
            sched_en = 1'b0;
            cap0 = cap;
            mem[committed+0]=8'h99; mem[committed+1]=8'hAA;
            mem[committed+2]=8'hBB; mem[committed+3]=8'hCC;
            desc_len[4]  = 4;
            desc_type[4] = 2'd2;
            desc_pts[4]  = stc + 33'd90000;                   // 1 s "early"
            desc_ptsv[4] = 1'b1;
            committed = committed + 4;
            ndesc = 5;
            t = 0;
            while (cap < cap0+1 && t < 200000) begin @(posedge clk); t = t + 1; end
            if (cap < cap0+1) begin $display("FAIL C3: bypass (sched_en=0) still gated"); errs=errs+1; end
            else $display("  [C3] sched_en=0 free-runs immediately");
        end

        // C4: FALLBACK release — armed with data but no schedulable reference
        // (PTS-less frame + STC never anchors): held at first, then free-runs
        // after the ARM_TIMEOUT (8192 clk in this TB) instead of wedging silent.
        begin
            integer cap0;
            repeat (5000) @(posedge clk);                     // drain dry + settle
            sched_en     = 1'b1;                              // re-arm (state cleared in bypass)
            stc_anchored = 1'b0;
            cap0 = cap;
            mem[committed+0]=8'hDD; mem[committed+1]=8'hEE;
            mem[committed+2]=8'hF0; mem[committed+3]=8'h0F;
            desc_len[5]  = 4;
            desc_type[5] = 2'd2;
            desc_ptsv[5] = 1'b0;                              // no PTS either
            committed = committed + 4;
            ndesc = 6;
            repeat (4000) @(posedge clk);                     // < timeout: still held
            if (cap != cap0) begin $display("FAIL C4: released before the fallback timeout"); errs=errs+1; end
            t = 0;
            while (cap < cap0+1 && t < 200000) begin @(posedge clk); t = t + 1; end
            if (cap < cap0+1) begin $display("FAIL C4: fallback did not release (silence wedge)"); errs=errs+1; end
            else $display("  [C4] fallback timer released an unschedulable stretch");
        end

        // C5: STALE-SKIP — a frame whose PTS is already >STALE_TICKS past its
        // deadline is discarded while armed (mid-title VOB cut: audio precedes the
        // first displayable video frame); the next FRESH frame becomes the head,
        // holds until its schedule, and its samples are the first to play.
        begin
            integer cap0;
            sched_en = 1'b0;                                  // clean re-arm
            repeat (3000) @(posedge clk);
            sched_en     = 1'b1;
            stc_anchored = 1'b1;
            video_live   = 1'b0;   // LOAD WINDOW: the stale-skip only fires here
                                   // (treadmill fix confines it to !video_live)
            stc          = 33'd3000000;
            cap0 = cap;
            // stale frame: 100 ms PAST due -> must be discarded entirely
            mem[committed+0]=8'hBA; mem[committed+1]=8'hAD;
            mem[committed+2]=8'hBA; mem[committed+3]=8'hAD;
            desc_len[6]  = 4;
            desc_type[6] = 2'd2;
            desc_pts[6]  = stc - 33'd9000;
            desc_ptsv[6] = 1'b1;
            committed = committed + 4;
            ndesc = 7;
            // fresh frame: ~22 ms ahead -> becomes the held head
            mem[committed+0]=8'h12; mem[committed+1]=8'h34;
            mem[committed+2]=8'h56; mem[committed+3]=8'h78;
            desc_len[7]  = 4;
            desc_type[7] = 2'd2;
            desc_pts[7]  = stc + 33'd2000;
            desc_ptsv[7] = 1'b1;
            committed = committed + 4;
            ndesc = 8;
            repeat (3000) @(posedge clk);                     // both dispatched; held
            if (cap != cap0) begin $display("FAIL C5: output before the fresh frame's schedule"); errs=errs+1; end
            video_live = 1'b1;                                // STD hold releases the display
            stc = desc_pts[7];                                // fresh frame due
            t = 0;
            while (cap < cap0+1 && t < 200000) begin @(posedge clk); t = t + 1; end
            if (cap < cap0+1) begin $display("FAIL C5: fresh frame did not play"); errs=errs+1; end
            else if (cL[cap0] !== 16'h1234 || cR[cap0] !== 16'h5678)
                 begin $display("FAIL C5: stale frame leaked to the head (%04x/%04x)", cL[cap0], cR[cap0]); errs=errs+1; end
            else $display("  [C5] stale frame discarded; fresh frame played first, on schedule");
        end

        // C6 (v5.3): an av_ofs change MID-PLAY must NOT disturb playback — no
        // re-arm, no dropout (the v5.2 live re-phase deadlocked on full FIFOs and
        // was reverted; the offset binds at the next (re)start event).
        begin
            integer cap0;
            sched_en = 1'b0;                                  // clean state
            repeat (3000) @(posedge clk);
            sched_en     = 1'b1;
            stc_anchored = 1'b1;
            video_live   = 1'b1;
            av_ofs       = 18'sd0;
            stc          = 33'd4000000;
            // frame at now: dispatches + plays immediately (draining=1)
            cap0 = cap;
            mem[committed+0]=8'h21; mem[committed+1]=8'h43;
            mem[committed+2]=8'h65; mem[committed+3]=8'h87;
            desc_len[8]  = 4;
            desc_type[8] = 2'd2;
            desc_pts[8]  = stc;
            desc_ptsv[8] = 1'b1;
            committed = committed + 4;
            ndesc = 9;
            t = 0;
            while (cap < cap0+1 && t < 200000) begin @(posedge clk); t = t + 1; end
            if (cap < cap0+1) begin $display("FAIL C6: baseline frame did not play"); errs=errs+1; end
            // change the offset MID-PLAY -> playback must continue undisturbed:
            // the next frame dispatches and plays normally (no re-arm, no wedge)
            av_ofs = 18'sd4500;                               // +50 ms, mid-drain
            cap0 = cap;
            mem[committed+0]=8'hA1; mem[committed+1]=8'hB2;
            mem[committed+2]=8'hC3; mem[committed+3]=8'hD4;
            desc_len[9]  = 4;
            desc_type[9] = 2'd2;
            desc_pts[9]  = stc - 33'd9000;                    // 100 ms past due: releases
            desc_ptsv[9] = 1'b1;                              // at once, within stale margin+ofs
            committed = committed + 4;
            ndesc = 10;
            t = 0;
            while (cap < cap0+1 && t < 200000) begin @(posedge clk); t = t + 1; end
            if (cap < cap0+1) begin $display("FAIL C6: ofs change mid-play disturbed playback (dropout)"); errs=errs+1; end
            else $display("  [C6] av_ofs change mid-play: playback undisturbed (applies at next start)");
        end

        // C7: drift-instrument counters — the phases above already produced one of
        // each event class: C2 an underrun re-arm (plus every drain-dry since),
        // C4 a fallback release, C5 a stale-skip discard. play_err was last
        // published while draining with a static STC and a handful of samples
        // played, so it must sit near 0 (loose band; the arithmetic smoke test).
        begin
            if (dbg_rearm_cnt < 4'd1) begin $display("FAIL C7: rearm_cnt=0 (C2 re-armed)"); errs=errs+1; end
            if (dbg_fbrel_cnt < 4'd1) begin $display("FAIL C7: fbrel_cnt=0 (C4 fell back)"); errs=errs+1; end
            if (dbg_skip_cnt  < 8'd1) begin $display("FAIL C7: skip_cnt=0 (C5 discarded)"); errs=errs+1; end
            if (($signed(dbg_play_err) > 16'sd16) || ($signed(dbg_play_err) < -16'sd16))
                begin $display("FAIL C7: play_err=%0d units (expected ~0)", $signed(dbg_play_err)); errs=errs+1; end
            if (errs == 0)
                $display("  [C7] counters: rearm=%0d fbrel=%0d skip=%0d play_err=%0d",
                         dbg_rearm_cnt, dbg_fbrel_cnt, dbg_skip_cnt, $signed(dbg_play_err));
        end

        // C8: ARRIVAL-LIMITED stale head — with NO current audio arrived (the
        // arrival front itself is stale), the head must NOT be discarded: it
        // plays (late), keeping audio stream-synced with the equally-late video
        // instead of latching the discard/fallback treadmill (the DVD_drift1 HW
        // collapse: ring pinned empty + VBUF full + skip/fallback saturated).
        begin
            integer cap0, skip0;
            sched_en = 1'b0;                                  // clean re-arm
            repeat (3000) @(posedge clk);
            sched_en     = 1'b1;
            stc_anchored = 1'b1;
            video_live   = 1'b1;
            av_ofs       = 18'sd0;
            stc          = 33'd6000000;
            skip0 = dbg_skip_cnt;
            cap0  = cap;
            // lone stale frame, 100 ms past due; arrival front = the SAME pts
            mem[committed+0]=8'h5A; mem[committed+1]=8'h5B;
            mem[committed+2]=8'h5C; mem[committed+3]=8'h5D;
            desc_len[10]  = 4;
            desc_type[10] = 2'd2;
            desc_pts[10]  = stc - 33'd9000;
            desc_ptsv[10] = 1'b1;
            committed = committed + 4;
            ndesc = 11;
            t = 0;
            while (cap < cap0+1 && t < 200000) begin @(posedge clk); t = t + 1; end
            if (cap < cap0+1) begin $display("FAIL C8: arrival-limited stale head was not played"); errs=errs+1; end
            else if (dbg_skip_cnt != skip0[7:0]) begin $display("FAIL C8: arrival-limited head was DISCARDED"); errs=errs+1; end
            else if (cL[cap0] !== 16'h5A5B || cR[cap0] !== 16'h5C5D)
                 begin $display("FAIL C8: wrong samples (%04x/%04x)", cL[cap0], cR[cap0]); errs=errs+1; end
            else $display("  [C8] arrival-limited stale head played late (no treadmill discard)");
        end

        // C9: MID-PLAY CATCH-UP (Shea-Stadium ratchet fix) — playback running
        // >300 ms late skips the stale backlog and re-phases, but ONLY once
        // CURRENT audio has ARRIVED (arr_pts at/past the play target). C8 is
        // the complementary case (no current arrival -> the late head plays).
        begin
            integer cap0, skip0;
            sched_en = 1'b0;                                  // clean re-arm
            repeat (3000) @(posedge clk);
            sched_en     = 1'b1;
            stc_anchored = 1'b1;
            video_live   = 1'b1;
            av_ofs       = 18'sd0;
            stc          = 33'd7000000;
            cap0  = cap;
            skip0 = dbg_skip_cnt;
            // F0: current frame -> latches play_pts, releases, plays (draining=1)
            mem[committed+0]=8'h11; mem[committed+1]=8'h22;
            mem[committed+2]=8'h33; mem[committed+3]=8'h44;
            desc_len[11]=4; desc_type[11]=2'd2;
            desc_pts[11]=stc; desc_ptsv[11]=1'b1;
            committed = committed + 4; ndesc = 12;
            t = 0;
            while (cap < cap0+1 && t < 200000) begin @(posedge clk); t = t + 1; end
            if (cap < cap0+1) begin $display("FAIL C9: baseline frame did not play"); errs=errs+1; end
            // playback is now live; simulate the post-crush recovery: a stale
            // backlog (500/400 ms past due) followed by a current frame, with
            // the ARRIVAL FRONT current (the demux has raced ahead)
            arr_pts = stc + 33'd2000; arr_pts_valid = 1'b1; repeat (2) @(posedge clk); arr_pts_valid = 1'b0;
            mem[committed+0]=8'hBA; mem[committed+1]=8'hAD;
            mem[committed+2]=8'hBA; mem[committed+3]=8'hAD;
            desc_len[12]=4; desc_type[12]=2'd2;
            desc_pts[12]=stc - 33'd45000; desc_ptsv[12]=1'b1;   // 500 ms late
            committed = committed + 4;
            mem[committed+0]=8'hDE; mem[committed+1]=8'hAD;
            mem[committed+2]=8'hDE; mem[committed+3]=8'hAD;
            desc_len[13]=4; desc_type[13]=2'd2;
            desc_pts[13]=stc - 33'd36000; desc_ptsv[13]=1'b1;   // 400 ms late (continuation)
            committed = committed + 4;
            mem[committed+0]=8'h77; mem[committed+1]=8'h88;
            mem[committed+2]=8'h99; mem[committed+3]=8'hAA;
            desc_len[14]=4; desc_type[14]=2'd2;
            desc_pts[14]=stc + 33'd2000; desc_ptsv[14]=1'b1;    // current
            committed = committed + 4;
            ndesc = 15;
            t = 0;
            while (cap < cap0+2 && t < 200000) begin @(posedge clk); t = t + 1; end
            if (cap < cap0+2) begin $display("FAIL C9: current frame did not play after catch-up"); errs=errs+1; end
            else if (cL[cap0+1] !== 16'h7788 || cR[cap0+1] !== 16'h99AA)
                 begin $display("FAIL C9: stale backlog leaked (%04x/%04x)", cL[cap0+1], cR[cap0+1]); errs=errs+1; end
            else if (dbg_skip_cnt != skip0[7:0] + 8'd2)
                 begin $display("FAIL C9: expected 2 catch-up discards (skip %0d->%0d)", skip0, dbg_skip_cnt); errs=errs+1; end
            else $display("  [C9] mid-play catch-up: 2 stale frames skipped once current audio arrived");
        end

        if (errs == 0) $display("PASS: dvd_audio_decode (LPCM %0d pairs, AC-3 synced=%0b err=%0b, drain gate ok)", cap, ac3_synced, ac3_err);
        else           $display("FAIL: %0d error(s)", errs);
        $finish;
    end

    initial begin #50000000 $display("FAIL: global timeout"); $finish; end
endmodule
