//============================================================================
//  av_sync.sv — PTS-driven A/V sync: video-referenced STC + audio-NCO genlock.
//
//  Models a commercial DVD player's clock recovery.  Video is the master
//  timebase (it is hard-locked to the HDMI refresh and is what the user
//  watches), so we build a System Time Clock (STC) that tracks the *video
//  presentation timeline* and gently slew the audio sample NCO to follow it —
//  exactly as a DVD player slaves its audio DAC to the recovered STC.  PTS sets
//  the phase; the slew holds the rate, so the two crystals (HDMI pixel clock vs
//  clk_sys) can no longer drift apart.
//
//  STC (no decoder surgery): the governor releases the picture at the display
//  refresh rate, and a per-image refresh edge is available in clk_sys (emu
//  derives `refresh_tick` from core_v_pos).  STC = anchor + Σ TICKS_PER_REFRESH,
//  anchored on the first video PTS.  Each refresh = one displayed image (a
//  progressive frame OR an interlaced field) = 1/refresh_rate of real time, so
//  STC advances by TICKS_PER_REFRESH (90000/refresh_rate, Q16 fractional) per
//  edge.  Both NTSC (59.94 Hz) and PAL (50 Hz) are supported: `refresh_50hz`
//  (the O[16] PAL toggle) picks the per-edge tick at runtime.
//
//  Regulator: both the audio frame PTS and the video PTS are sampled at the same
//  point (ps_demux parse), so comparing them yields the authoring-intended A/V
//  skew regardless of pipeline latency.  We hold the dispatched audio PTS at
//  STC + lead_target via a PI loop driving a signed `nco_trim` added to the audio
//  NCO increment.  lead_target is the knob that matches the audio buffer delay to
//  the video pipeline delay for correct lip-sync — a runtime input driven from the
//  OSD "A/V Lead" menu so it can be dialled live on hardware.
//
//    error = dispatched_aud_pts - STC - lead_target
//    error > 0  -> audio is ahead of video  -> slow NCO (trim < 0)
//    error < 0  -> audio is behind video    -> speed NCO (trim > 0)
//
//  Seek/discontinuity: a video PTS that jumps from STC by more than
//  REANCHOR_TICKS (~0.7 s) re-anchors the STC and clears the integrator (clean
//  phase reset on a chapter change) rather than slewing for minutes.
//
//  All clk_sys (~27 MHz) — same domain as ps_demux / audio_ring / the audio NCO,
//  so there is no clock-domain crossing.
//============================================================================

`default_nettype none

module av_sync #(
    parameter int CLK_HZ      = 27000000,  // clk_sys
    parameter int AUD_HZ      = 48000,     // audio sample rate
    // Display refresh in milli-Hz: NTSC default and the PAL alternate. The active
    // rate is chosen at runtime by `refresh_50hz` (PAL toggle), so the same instance
    // tracks either standard. STC ticks/refresh = 90000 / refresh_rate, carried as a
    // Q16 fixed-point increment.
    parameter int REFRESH_MHZ      = 59940,   // NTSC 59.94 Hz
    parameter int REFRESH_MHZ_PAL  = 50000,   // PAL  50.00 Hz
    parameter int REFRESH_MHZ_FILM = 23976,   // Film 24p 23.976 Hz (issue #124)
    parameter int REFRESH_MHZ_25   = 25000,   // PAL film 25p 25.000 Hz (issue #124 Phase 2)
    // Re-anchor thresholds. IMPORTANT ASYMMETRY (2026-07-02 fix): vid_pts is sampled
    // at DEMUX PARSE time, which in normal play legitimately LEADS the display-
    // referenced STC by the whole buffering window (audio_ring time window + VBUF
    // fill — up to several seconds with the 2 MB VBUF, and content-dependent).
    // Treating any ±0.7 s skew as a seek made the STC re-anchor to the demux front
    // whenever the window exceeded 0.7 s — pinning the STC seconds ahead of the
    // screen, saturating the genlock, and making the A/V Lead knob inert (HW
    // symptom: 0 ms and 400 ms identical; skew content-dependent). So:
    //   BACKWARD skew (vid_pts behind STC) is impossible in linear play -> a real
    //   discontinuity; re-anchor past ~0.7 s.
    //   FORWARD skew is normal buffering lead; only re-anchor past FWD_REANCHOR
    //   (~15 s, beyond any plausible buffering horizon = a forward seek).
    parameter int REANCHOR_TICKS     = 63000,     // backward (~0.7 s)
    parameter int FWD_REANCHOR_TICKS = 1350000,   // forward  (~15 s)
    // PI gains as right-shifts. trim = -(error>>>KP_SHIFT) - (integ>>>KI_SHIFT).
    parameter int KP_SHIFT    = 1,
    parameter int KI_SHIFT    = 9
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,            // when low, hold trim at 0 (free-run NCO)
    input  wire        pause,             // 1 = freeze the presentation clock (STC)
    input  wire        refresh_50hz,      // 1 = PAL 50 Hz STC rate, 0 = NTSC 59.94 Hz
    input  wire        refresh_24hz,      // 1 = Film 24p 23.976 Hz STC rate (NTSC film; wins over all)
    input  wire        refresh_25hz,      // 1 = Film 25p 25.000 Hz STC rate (PAL film; wins over refresh_50hz)

    // Target lead of the dispatched audio PTS over the STC, in 90 kHz ticks
    // (≈ the audio pipeline+buffer delay; matches video pipeline delay).
    // RUNTIME input (was a parameter): driven from the OSD "A/V Lead" menu so
    // lip-sync can be dialled live on hardware without a rebuild. ~13500 = 150 ms.
    input  wire [15:0] lead_target,

    // Video PTS from ps_demux (pulse) — anchors / re-anchors the STC.
    input  wire [32:0] vid_pts,
    input  wire        vid_pts_valid,

    // Display refresh edge (one per displayed image: frame or field), clk_sys.
    input  wire        refresh_tick,

    // Sticky level from the display governor (2-FF synced): a decoded frame has
    // been picked up for display. Until it asserts, the STC holds at its anchor
    // (and the PI holds), so STC(anchor_pts) begins advancing when the anchor
    // frame actually REACHES THE SCREEN — killing the content-dependent
    // parse-to-display offset (VBUF flood + decode pipeline fill) that otherwise
    // biased the audio genlock target early by that amount.
    input  wire        video_live,

    // Audio frame PTS at the moment it is dispatched into the decoder (pulse),
    // from dvd_audio_decode. Only frames whose PES carried a PTS pulse here.
    input  wire [32:0] dispatch_pts,
    input  wire        dispatch_pts_valid,

    // Genlock output: signed increment added to the audio NCO step.
    output wire signed [21:0] nco_trim,

    // STC lock state — high once the first video PTS has anchored the STC.
    // Consumed by dvd_audio_decode's PTS-scheduled dispatch gate (never gate
    // before the STC means anything).
    output wire        stc_anchored,

    // Debug / overlay
    output wire [32:0] stc,
    output wire signed [31:0] drift,       // dispatched_aud_pts - STC (signed)
    output wire [15:0] reanchor_count
);

    // ---- TICKS_PER_REFRESH as a Q16 increment: 90000/refresh_rate * 65536 ----
    // refresh_rate[Hz] = REFRESH_MHZ/1000 -> ticks = 90000*1000/REFRESH_MHZ.
    // Both standards' increments are precomputed; `refresh_50hz` selects at runtime.
    localparam longint TPR_Q16_L      = (longint'(90000) * 1000 * 65536) / REFRESH_MHZ;
    localparam longint TPR_Q16_PAL_L  = (longint'(90000) * 1000 * 65536) / REFRESH_MHZ_PAL;
    localparam longint TPR_Q16_FILM_L = (longint'(90000) * 1000 * 65536) / REFRESH_MHZ_FILM;
    localparam longint TPR_Q16_25_L   = (longint'(90000) * 1000 * 65536) / REFRESH_MHZ_25;
    localparam [48:0]  TPR_Q16_NTSC = 49'(TPR_Q16_L);      // fits ~27 bits; 49 for the acc
    localparam [48:0]  TPR_Q16_PAL  = 49'(TPR_Q16_PAL_L);
    localparam [48:0]  TPR_Q16_FILM = 49'(TPR_Q16_FILM_L); // ~3754.6 ticks/refresh @ 23.976 Hz
    localparam [48:0]  TPR_Q16_25   = 49'(TPR_Q16_25_L);   // exactly 3600 ticks/refresh @ 25.000 Hz
    // Priority: NTSC film 24p (exclusive with PAL) > PAL film 25p > PAL 50p > NTSC 60p.
    // Under PAL film, BOTH refresh_25hz and refresh_50hz assert (film25 = filmp & pal),
    // so refresh_25hz must be tested before refresh_50hz.
    wire       [48:0]  TPR_Q16 = refresh_24hz ? TPR_Q16_FILM
                               : refresh_25hz ? TPR_Q16_25
                               : refresh_50hz ? TPR_Q16_PAL : TPR_Q16_NTSC;

    // ---- Trim clamp = 0.5% of the nominal NCO increment ----
    localparam longint NCO_INC_L  = (longint'(AUD_HZ) << 32) / CLK_HZ;
    localparam signed [21:0] TRIM_CLAMP  = 22'(NCO_INC_L / 200);          // 0.5%
    localparam signed [40:0] INTEG_CLAMP = 41'(TRIM_CLAMP) <<< KI_SHIFT;  // anti-windup

    wire rst = ~rst_n;

    // ---- STC accumulator: [48:16] = 33-bit integer ticks, [15:0] = Q16 frac ----
    logic [48:0] stc_acc;
    logic        anchored;

    // ---- Latched dispatched audio PTS (the loop reference) ----
    logic [32:0] disp_pts_l;
    logic        disp_valid_l;

    // ---- PI state ----
    logic signed [40:0] integ;
    logic signed [21:0] trim_r;
    logic [15:0]        reanchor_q;

    assign nco_trim       = enable ? trim_r : 22'sd0;
    assign stc            = stc_acc[48:16];
    assign stc_anchored   = anchored;
    assign reanchor_count = reanchor_q;

    // signed A/V skew for debug
    wire signed [33:0] drift_w = $signed({1'b0, disp_pts_l}) - $signed({1'b0, stc});
    assign drift = drift_w[31:0];

    // error = disp_pts - stc - lead_target (35-bit signed headroom)
    wire signed [34:0] err_w =
        $signed({2'b0, disp_pts_l}) - $signed({2'b0, stc}) - $signed({19'b0, lead_target});

    // Seek detector (one-sided; see the parameter comment): backward jump past
    // REANCHOR_TICKS, or forward jump past the buffering horizon FWD_REANCHOR_TICKS.
    wire signed [33:0] vskew_w = $signed({1'b0, vid_pts}) - $signed({1'b0, stc});
    wire               vbig    = (vskew_w >  $signed(34'(FWD_REANCHOR_TICKS))) ||
                                 (vskew_w < -$signed(34'(REANCHOR_TICKS)));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stc_acc      <= '0;
            anchored     <= 1'b0;
            disp_pts_l   <= '0;
            disp_valid_l <= 1'b0;
            integ        <= '0;
            trim_r       <= '0;
            reanchor_q   <= '0;
        end else begin
            // ---- latch the dispatched audio PTS (loop reference) ----
            if (dispatch_pts_valid) begin
                disp_pts_l   <= dispatch_pts;
                disp_valid_l <= 1'b1;
            end

            // ---- anchor / re-anchor on video PTS (takes priority over advance) ----
            if (vid_pts_valid && (!anchored || vbig)) begin
                stc_acc  <= {vid_pts, 16'd0};
                if (anchored) begin                 // a re-anchor (seek), not first lock
                    integ      <= '0;
                    trim_r     <= '0;
                    reanchor_q <= reanchor_q + 1'b1;
                end
                anchored <= 1'b1;
            end else begin
                // ---- STC advances one refresh worth of ticks per displayed image.
                //      Held at the anchor until the display actually shows a decoded
                //      frame (video_live) — refresh ticks on a dead/black display
                //      must not advance the presentation clock. PAUSE freezes it:
                //      the presentation clock is the master, so a frozen STC halts
                //      video advance AND (PTS-scheduled) audio dispatch together. ----
                if (refresh_tick && anchored && video_live && !pause)
                    stc_acc <= stc_acc + TPR_Q16;

                // ---- PI update, paced by the refresh tick (~60 Hz) ----
                if (refresh_tick && anchored && video_live && disp_valid_l && !pause) begin
                    // (no SystemVerilog N'(expr) size-casts here — Quartus 17.0
                    //  rejects them in procedural context; widths are sized by the
                    //  signed declarations below, which carry the needed headroom.)
                    logic signed [40:0] integ_n;
                    logic signed [34:0] p_term;
                    logic signed [34:0] i_term;
                    logic signed [35:0] sum;

                    integ_n = integ + err_w;                 // accumulate error
                    if      (integ_n >  INTEG_CLAMP) integ_n =  INTEG_CLAMP;  // anti-windup
                    else if (integ_n < -INTEG_CLAMP) integ_n = -INTEG_CLAMP;
                    integ <= integ_n;

                    p_term = err_w   >>> KP_SHIFT;
                    i_term = integ_n >>> KI_SHIFT;
                    sum    = -(p_term + i_term);             // negative feedback

                    if      (sum >  TRIM_CLAMP) trim_r <=  TRIM_CLAMP;
                    else if (sum < -TRIM_CLAMP) trim_r <= -TRIM_CLAMP;
                    else                        trim_r <= sum[21:0];
                end
            end
        end
    end

endmodule

`default_nettype wire
