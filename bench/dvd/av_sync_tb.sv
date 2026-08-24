//============================================================================
//  av_sync_tb.sv — testbench for dvd/av_sync.sv (PTS-driven A/V sync).
//
//  Verifies:
//    1. STC tracking — after anchoring on a video PTS, the STC advances by
//       TICKS_PER_REFRESH (~1501.5 @ 59.94 Hz) per refresh_tick.
//    2. Control direction — a dispatched audio PTS held BELOW the STC (audio
//       behind) drives nco_trim POSITIVE (speed up); held ABOVE STC+lead drives
//       it NEGATIVE (slow down).
//    3. Closed-loop convergence — with a behavioural audio-clock plant whose
//       rate is set by nco_trim plus a fixed bias, the loop nulls the bias and
//       settles the dispatched-PTS lead at LEAD_TARGET, with bounded trim.
//    4. Seek re-anchor — a video PTS jump > REANCHOR_TICKS snaps the STC and
//       bumps reanchor_count exactly once.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module av_sync_tb;
    localparam int CLK_HZ      = 27000000;
    localparam int AUD_HZ      = 48000;
    localparam int LEAD_TARGET = 13500;
    localparam int REANCHOR    = 63000;

    // mirror the DUT's derived constants for the plant / checks
    localparam longint TPR_Q16  = (longint'(90000)*1000*65536)/59940;
    localparam int     TPR_INT  = TPR_Q16 >> 16;                 // 1501
    localparam longint NCO_INC  = (longint'(AUD_HZ) << 32)/CLK_HZ;
    localparam int     TRIM_CL  = NCO_INC/200;

    logic        clk = 0, rst_n = 0, enable = 1;
    logic [32:0] vid_pts = 0;
    logic        vid_pts_valid = 0;
    logic        refresh_tick = 0;
    logic [32:0] dispatch_pts = 0;
    logic        dispatch_pts_valid = 0;
    wire signed [21:0] nco_trim;
    wire [32:0] stc;
    wire signed [31:0] drift;
    wire [15:0] reanchor_count;

    // lead_target is a runtime port now (OSD-tunable); drive the old default.
    logic [15:0] lead_target = 16'(LEAD_TARGET);
    wire         stc_anchored;
    // display governor "first decoded frame shown" level: STC holds until this.
    logic        video_live = 1'b0;
    // gamepad transport pause: when high, the STC must freeze.
    logic        pause = 1'b0;

    av_sync #(.CLK_HZ(CLK_HZ), .AUD_HZ(AUD_HZ), .REFRESH_MHZ(59940),
              .REFRESH_MHZ_PAL(50000),
              .REANCHOR_TICKS(REANCHOR)) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable), .pause(pause),
        .refresh_50hz(1'b0),   // NTSC for the existing checks
        .refresh_24hz(1'b0),
        .refresh_25hz(1'b0),
        .lead_target(lead_target),
        .vid_pts(vid_pts), .vid_pts_valid(vid_pts_valid),
        .refresh_tick(refresh_tick), .video_live(video_live),
        .dispatch_pts(dispatch_pts), .dispatch_pts_valid(dispatch_pts_valid),
        .nco_trim(nco_trim), .stc_anchored(stc_anchored), .stc(stc), .drift(drift),
        .reanchor_count(reanchor_count)
    );

    // Second instance in PAL (50 Hz) mode: STC must advance ~1800 ticks/refresh
    // (90000/50) instead of ~1501.5. Shares clk + the refresh/anchor stimulus.
    wire [32:0] stc_pal;
    av_sync #(.CLK_HZ(CLK_HZ), .AUD_HZ(AUD_HZ), .REFRESH_MHZ(59940),
              .REFRESH_MHZ_PAL(50000),
              .REANCHOR_TICKS(REANCHOR)) dut_pal (
        .clk(clk), .rst_n(rst_n), .enable(enable), .pause(pause),
        .refresh_50hz(1'b1),   // PAL 50 Hz
        .refresh_24hz(1'b0),
        .refresh_25hz(1'b0),
        .lead_target(lead_target),
        .vid_pts(vid_pts), .vid_pts_valid(vid_pts_valid),
        .refresh_tick(refresh_tick), .video_live(video_live),
        .dispatch_pts(dispatch_pts), .dispatch_pts_valid(dispatch_pts_valid),
        .nco_trim(), .stc_anchored(), .stc(stc_pal), .drift(), .reanchor_count()
    );

    // Third instance in Film 24p (23.976 Hz) mode: STC must advance ~3754.6
    // ticks/refresh (90000/23.976). refresh_24hz wins over refresh_50hz. Shares
    // clk + the refresh/anchor stimulus. (Film 24p Out, issue #124.)
    wire [32:0] stc_film;
    av_sync #(.CLK_HZ(CLK_HZ), .AUD_HZ(AUD_HZ), .REFRESH_MHZ(59940),
              .REFRESH_MHZ_PAL(50000),
              .REANCHOR_TICKS(REANCHOR)) dut_film (
        .clk(clk), .rst_n(rst_n), .enable(enable), .pause(pause),
        .refresh_50hz(1'b0),
        .refresh_24hz(1'b1),   // Film 24p 23.976 Hz
        .refresh_25hz(1'b0),
        .lead_target(lead_target),
        .vid_pts(vid_pts), .vid_pts_valid(vid_pts_valid),
        .refresh_tick(refresh_tick), .video_live(video_live),
        .dispatch_pts(dispatch_pts), .dispatch_pts_valid(dispatch_pts_valid),
        .nco_trim(), .stc_anchored(), .stc(stc_film), .drift(), .reanchor_count()
    );

    // Fourth instance in PAL Film 25p (25.000 Hz) mode: STC must advance exactly
    // 3600 ticks/refresh (90000/25). Under PAL film BOTH refresh_25hz and
    // refresh_50hz assert on hardware, so drive both here and check 25hz WINS
    // (3600/refresh, not the 1800 of plain PAL 50p). (Film 25p Out, issue #124.)
    wire [32:0] stc_film25;
    av_sync #(.CLK_HZ(CLK_HZ), .AUD_HZ(AUD_HZ), .REFRESH_MHZ(59940),
              .REFRESH_MHZ_PAL(50000),
              .REANCHOR_TICKS(REANCHOR)) dut_film25 (
        .clk(clk), .rst_n(rst_n), .enable(enable), .pause(pause),
        .refresh_50hz(1'b1),   // PAL asserts 50hz too...
        .refresh_24hz(1'b0),
        .refresh_25hz(1'b1),   // ...but 25hz must win
        .lead_target(lead_target),
        .vid_pts(vid_pts), .vid_pts_valid(vid_pts_valid),
        .refresh_tick(refresh_tick), .video_live(video_live),
        .dispatch_pts(dispatch_pts), .dispatch_pts_valid(dispatch_pts_valid),
        .nco_trim(), .stc_anchored(), .stc(stc_film25), .drift(), .reanchor_count()
    );

    always #18 clk = ~clk;   // ~27 MHz

    integer errs = 0;
    task chk(input cond, input [255:0] msg);
        if (!cond) begin $display("  FAIL: %0s", msg); errs = errs + 1; end
    endtask

    // one clk pulse on a named signal
    task pulse_refresh; begin
        @(posedge clk); refresh_tick <= 1'b1;
        @(posedge clk); refresh_tick <= 1'b0;
    end endtask

    localparam [32:0] BASE = 33'd900000;   // 10 s in 90 kHz ticks

    // behavioural audio-clock plant: advances per refresh by TPR + bias + trim gain
    longint model_aud;
    integer bias;
    integer i;
    longint plant_delta;

    initial begin
        // ---- reset ----
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        repeat (2) @(posedge clk);

        // ================= 1. STC tracking =================
        chk(!stc_anchored, "stc_anchored high before any vid_pts");
        // anchor on the first video PTS
        @(posedge clk); vid_pts <= BASE; vid_pts_valid <= 1'b1;
        @(posedge clk); vid_pts_valid <= 1'b0;
        @(posedge clk);
        chk(stc == BASE, "STC did not anchor to first vid_pts");
        chk(stc_anchored, "stc_anchored not asserted after first vid_pts");

        // ---- video_live gate: refreshes on a dead display must NOT advance the
        //      STC (it holds at the anchor until a decoded frame is on screen),
        //      and a forward parse-lead vid_pts (buffering) must NOT re-anchor.
        for (i = 0; i < 20; i = i + 1) pulse_refresh();
        @(posedge clk);
        chk(stc == BASE, "STC advanced while video_live=0");
        @(posedge clk); vid_pts <= BASE + 33'd90000; vid_pts_valid <= 1'b1;  // parse 1 s ahead
        @(posedge clk); vid_pts_valid <= 1'b0;
        @(posedge clk);
        chk(stc == BASE, "forward parse-lead re-anchored the held STC");
        $display("  [0] STC held at anchor through 20 dead refreshes + 1 s parse lead");
        video_live = 1'b1;   // display shows its first decoded frame

        // advance 100 refreshes with no audio -> STC ~= BASE + 100*1501.5
        for (i = 0; i < 100; i = i + 1) pulse_refresh();
        @(posedge clk);
        chk(stc > BASE + 33'd149000 && stc < BASE + 33'd151000,
            "STC tracking off after 100 refreshes");
        $display("  [1] STC after 100 refreshes = %0d (expect ~%0d)", stc-BASE, 150150);

        // PAL instance saw the same anchor + 100 refreshes -> ~100*1800 = 180000 ticks.
        chk(stc_pal > BASE + 33'd178000 && stc_pal < BASE + 33'd182000,
            "PAL STC rate wrong after 100 refreshes");
        $display("  [1p] PAL STC after 100 refreshes = %0d (expect ~%0d)", stc_pal-BASE, 180000);

        // Film 24p instance: same anchor + 100 refreshes -> ~100*3754.6 = 375460 ticks.
        chk(stc_film > BASE + 33'd373000 && stc_film < BASE + 33'd378000,
            "Film 24p STC rate wrong after 100 refreshes");
        $display("  [1f] Film24 STC after 100 refreshes = %0d (expect ~%0d)", stc_film-BASE, 375460);

        // Film 25p (PAL) instance: same anchor + 100 refreshes -> ~100*3600 = 360000
        // ticks (exact per-refresh: 3600 has no Q16 fraction). Well clear of plain PAL
        // 50p's 180000 -> confirms refresh_25hz WINS over the co-asserted refresh_50hz.
        chk(stc_film25 > BASE + 33'd359000 && stc_film25 < BASE + 33'd361000,
            "Film 25p STC rate wrong (25hz must win over 50hz) after 100 refreshes");
        $display("  [1f25] Film25 STC after 100 refreshes = %0d (expect ~%0d)", stc_film25-BASE, 360000);

        // ================= 2. Control direction =================
        // hold dispatch_pts well BELOW stc (audio behind) -> trim should go +.
        for (i = 0; i < 40; i = i + 1) begin
            @(posedge clk); dispatch_pts <= stc - 33'd20000; dispatch_pts_valid <= 1'b1;
            @(posedge clk); dispatch_pts_valid <= 1'b0;
            pulse_refresh();
        end
        chk(nco_trim > 0, "audio-behind did not drive trim positive");
        $display("  [2a] audio behind -> nco_trim = %0d (expect > 0)", nco_trim);

        // hold dispatch_pts well ABOVE stc+lead (audio ahead) -> trim should go -.
        for (i = 0; i < 80; i = i + 1) begin
            @(posedge clk); dispatch_pts <= stc + 33'd40000; dispatch_pts_valid <= 1'b1;
            @(posedge clk); dispatch_pts_valid <= 1'b0;
            pulse_refresh();
        end
        chk(nco_trim < 0, "audio-ahead did not drive trim negative");
        $display("  [2b] audio ahead  -> nco_trim = %0d (expect < 0)", nco_trim);

        // ================= 3. Closed-loop convergence =================
        // Re-anchor cleanly to start fresh, then run the plant.
        @(posedge clk); vid_pts <= BASE; vid_pts_valid <= 1'b1;
        @(posedge clk); vid_pts_valid <= 1'b0;
        repeat (3) @(posedge clk);
        // (BASE is far BEHIND the current stc after the runs above -> a BACKWARD
        //  jump > REANCHOR -> counts as a seek under the one-sided detector, fine)

        model_aud = BASE;        // audio clock starts level with STC (drift 0)
        bias      = -3;          // audio nominally 3 ticks/refresh slow (needs +trim)
        for (i = 0; i < 60000; i = i + 1) begin
            // plant: how far the audio clock moves this refresh
            plant_delta = TPR_INT + bias + (longint'(nco_trim) * TPR_INT) / NCO_INC;
            model_aud   = model_aud + plant_delta;
            @(posedge clk); dispatch_pts <= model_aud[32:0]; dispatch_pts_valid <= 1'b1;
            @(posedge clk); dispatch_pts_valid <= 1'b0;
            pulse_refresh();
        end
        @(posedge clk);
        $display("  [3] converged drift = %0d (target LEAD=%0d), trim = %0d (clamp %0d)",
                 drift, LEAD_TARGET, nco_trim, TRIM_CL);
        chk(drift > (LEAD_TARGET-3000) && drift < (LEAD_TARGET+3000),
            "closed-loop drift did not settle near LEAD_TARGET");
        chk(nco_trim > 0 && nco_trim < TRIM_CL,
            "closed-loop trim out of expected positive/bounded range");

        // ================= 4. Seek re-anchor (one-sided detector) =================
        begin
            reg [15:0] ra0;
            reg [32:0] newpts;

            // 4a. FORWARD +2.2 s = normal buffering parse-lead -> must NOT re-anchor.
            ra0    = reanchor_count;
            newpts = stc + 33'd200000;
            @(posedge clk); vid_pts <= newpts; vid_pts_valid <= 1'b1;
            @(posedge clk); vid_pts_valid <= 1'b0;
            repeat (3) @(posedge clk);
            chk(reanchor_count == ra0, "forward buffering lead spuriously re-anchored");
            chk(stc < newpts - 33'd100000, "STC snapped to a forward buffering lead");
            $display("  [4a] +2.2 s parse lead: no re-anchor (count %0d)", reanchor_count);

            // 4b. BACKWARD -2.2 s = impossible in linear play -> re-anchor.
            ra0    = reanchor_count;
            newpts = stc - 33'd200000;
            @(posedge clk); vid_pts <= newpts; vid_pts_valid <= 1'b1;
            @(posedge clk); vid_pts_valid <= 1'b0;
            repeat (3) @(posedge clk);
            chk(reanchor_count == ra0 + 16'd1, "backward seek did not re-anchor");
            chk(stc >= newpts && stc < newpts + 33'd3000, "STC did not snap to backward seek PTS");
            chk(nco_trim == 0, "trim not cleared on re-anchor");
            $display("  [4b] -2.2 s seek: reanchor %0d->%0d, stc snapped", ra0, reanchor_count);

            // 4c. FORWARD +16 s = beyond any buffering horizon -> re-anchor.
            ra0    = reanchor_count;
            newpts = stc + 33'd1440000;
            @(posedge clk); vid_pts <= newpts; vid_pts_valid <= 1'b1;
            @(posedge clk); vid_pts_valid <= 1'b0;
            repeat (3) @(posedge clk);
            chk(reanchor_count == ra0 + 16'd1, "+16 s forward seek did not re-anchor");
            chk(stc >= newpts && stc < newpts + 33'd3000, "STC did not snap to +16 s seek PTS");
            $display("  [4c] +16 s seek: reanchor %0d->%0d, stc snapped", ra0, reanchor_count);
        end

        // ---- 5. PAUSE: the presentation STC must FREEZE while pause is high,
        //         then resume advancing when it releases. This is what freezes
        //         video AND (PTS-scheduled) audio dispatch on a gamepad pause. ----
        begin
            reg [32:0] stc_at_pause;
            // ensure we're anchored + advancing
            chk(stc_anchored, "not anchored before pause test");
            pulse_refresh; pulse_refresh;
            @(posedge clk); pause <= 1'b1;
            @(posedge clk);
            stc_at_pause = stc;
            repeat (6) pulse_refresh;                 // refreshes keep ticking...
            chk(stc == stc_at_pause, "STC advanced while paused");
            $display("  [5a] paused: STC frozen at %0d across 6 refreshes", stc_at_pause);
            @(posedge clk); pause <= 1'b0;
            repeat (3) pulse_refresh;                 // ...resume
            chk(stc > stc_at_pause, "STC did not resume after unpause");
            $display("  [5b] unpaused: STC resumed to %0d", stc);
        end

        $display("=== av_sync_tb: %0d error(s) ===", errs);
        if (errs == 0) $display("PASS: av_sync");
        else           $display("FAIL: av_sync");
        $finish;
    end

    // safety timeout
    initial begin #200000000; $display("FAIL: timeout"); $finish; end
endmodule

`default_nettype wire
