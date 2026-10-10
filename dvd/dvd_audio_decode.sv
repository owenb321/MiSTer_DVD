//============================================================================
//  dvd_audio_decode.sv — in-fabric DVD audio: AC-3, DTS, MP2 and LPCM -> s16 L/R.
//
//  Replaces the old DDR3-ring + HPS-daemon audio path.  Drains the audio_ring
//  read side (committed byte stream + {len,type} frame descriptors), dispatches
//  each frame by codec, decodes it in fabric, and presents stereo s16 PCM at the
//  NCO's rate (48 kHz; MP2's and CD-DA's own 44.1/32 kHz; 96 kHz for a 96 kHz LPCM
//  track on a 96 kHz HDMI link) for emu.sv to drive onto AUDIO_L/AUDIO_R.
//
//    frame_type (from ps_demux / audio_ring): 0=AC-3  1=DTS  2=LPCM  3=MP2
//      AC-3   -> audio_engine (the microcoded engine's AC-3 program + imdct_512:
//                decode + 5.1->stereo downmix; 1+1 dual mono as left/right) ->
//                pcm_out (Q8.23->s16)
//      LPCM   -> lpcm_unpack: every DVD-Video form (docs/lpcm_full.md), 16/20/24-bit
//                to s16, 1-8 channels downmixed to stereo, 96 kHz decimated to 48 by
//                lpcm_hb unless the link is 96 kHz (link96); a reserved header
//                (lpcm_bad) is drained and announced (lpcm_unsup)
//      MP2    -> audio_engine (the engine's MP2 program; docs/mp2_engine.md M3), its
//                pairs serialised into lpcm_unpack's FIFO, as DTS's
//      DTS    -> audio_engine (the engine's DTS core program, stereo; docs/dts_decoder.md,
//                PRs #148/#149) once the codebooks have copied (cb_tables_ok);
//                discarded if that copy failed.
//  Bitstream passthrough is not here: iec61937_wrap in emu.sv takes the ring's AC-3
//  and DTS frames instead (docs/iec61937.md).
//
//  Everything runs in clk_sys (~27 MHz) — the same domain as ps_demux/audio_ring.
//  The AC-3 core has ~3000x real-time headroom at this clock, and pcm_out's async
//  output FIFO is run with aud_clk = clk so its CDC degenerates harmlessly.
//
//  PACING / A-V SYNC: pcm_out drains one pair per aud_ce (a 48 kHz fractional NCO
//  off clk).  When its FIFO backs up, pcm_out stalls -> the engine's pcm_done is
//  delayed -> the input FIFO fills -> the dispatch holds out_ready low.  audio_ring
//  then asserts almost_full and emu.sv stalls the DEMUX stream (STD-model flow
//  control, watchdog-guarded; drop-on-full remains the fallback) — see the FLOW
//  CONTROL note in dvd/audio_ring.sv.
//
//  A/V SYNC is the PTS-scheduled drain gate (docs/stc_freerun.md): decoded audio waits
//  in the output FIFOs until the STC reaches the dispatched frame's PTS. The NCO
//  free-runs: the `nco_trim` genlock port is tied 0 in emu.sv since the lip-sync v3
//  retirement (2026-07-02, docs/fabric_audio.md). `dispatch_pts` is still emitted (the
//  PTS of each frame as it enters the decoder) for the gate and the telemetry.
//============================================================================

`timescale 1ns/1ps

module dvd_audio_decode #(
    parameter int CLK_HZ = 27000000,
    parameter int AUD_HZ = 48000,
    // Drain-gate fallback release timer width: 2^W / CLK_HZ seconds of ARMED with
    // data but no scheduled release before free-running anyway (liveness guard for
    // streams that never yield a usable PTS/anchor). 26 -> ~2.5 s. TBs shrink it.
    parameter int ARM_TIMEOUT_W = 26,
    // In-band re-time hold bound: 2^W / CLK_HZ s a discontinuity head may wait at
    // the ring head (for the old tail to play out AND for the clock to reach its
    // timeline) before it is dispatched anyway. 24 -> ~0.62 s. TBs shrink it.
    parameter int HOLD_W = 24,
    // AC-3/engine decode-stall watchdog width: 2^W / CLK_HZ s with no decode
    // progress while fed before a self-heal reset. 24 -> ~0.62 s. TBs shrink it.
    parameter int WDOG_W = 24,
    // D4 (docs/dts_decoder.md): the codebook halves the LPCM and MP2 PCM FIFOs carry as
    // their power-up contents (the core passes dvd/dts/cb_host_*.mem; "" = none)
    parameter     LPCM_INIT = "",
    parameter     MP2_INIT  = ""
) (
    input  logic        clk,             // clk_sys
    input  logic        rst_n,
    input  logic        enable,          // O5 "Audio" toggle (default On)
    input  logic        pause,           // gamepad transport: freeze audio (hold, silence)
    // dvd/flush_ctl.sv's aud_resync mirrored (aud_resync_o): rst_n (=aud_rst_n) is
    // asserted for this GENTLE cause (an audio-track switch -- content keeps playing,
    // only the audio phase resets; a display re-anchor no longer resets audio since
    // 2026-09-29, see IN-BAND TIMELINE RE-TIME) as opposed to a HARD cause (aud_flush: seek/mount/jump, a real
    // discontinuity). Selects instant-cut vs. de-click ramp in the output mux below.
    input  logic        aud_soft_switch,

    // audio_ring read side (FWFT committed byte stream + descriptor FIFO)
    input  logic [7:0]  ring_byte,
    input  logic        ring_valid,
    output logic        ring_ready,
    input  logic        frame_valid,
    input  logic [15:0] frame_len,
    input  logic [1:0]  frame_type,
    input  logic [1:0]  lpcm_quant,       // LPCM word length (ps_demux): 0=16,1=20,2=24-bit
    // The rest of the LPCM header (ps_demux, docs/lpcm_full.md): channels - 1, a 96 kHz
    // track, and a value the format reserves (44.1/32 kHz, quant 3: muted, and
    // lpcm_unsup raises AUDIO UNSUPPORTED). link96: the HDMI link runs at 96 kHz
    // (MiSTer.ini hdmi_audio_96k, sys_top's cfg[6], synchronised in emu): 96 kHz LPCM
    // then plays at its own rate; on a 48 kHz link lpcm_unpack decimates it.
    input  logic [2:0]  lpcm_nch_m1,
    input  logic        lpcm_fs96,
    input  logic        lpcm_bad,
    input  logic        link96,
    output logic        lpcm_unsup,
    input  logic [32:0] frame_pts,        // PES PTS of the queued frame
    input  logic        frame_pts_valid,  // that PTS is meaningful
    input  logic        frame_seamless,   // audio_ring: the frame's cell is authored seamless_play
    output logic        frame_pop,

    // CD-DA/WAV direct-PCM injection (feature/wav-audio): raw little-endian
    // 16-bit stereo bytes straight from the reader, bypassing ps_demux /
    // audio_ring / the dispatch FSM entirely. cdda_mode (static per mount)
    // forces the LPCM unpacker onto the output mux (le byte order, quant=0)
    // and cdda_fs onto the NCO rate select; cdda_full (lpcm_unpack.afull) is
    // the reader's backpressure tap. cdda_flush pulses on a seek: it clears
    // the unpacker's assembler phase + pair FIFO so a seek can never
    // channel-swap and stale pre-seek audio doesn't play out. There is no
    // PTS in this mode — emu holds sched_en low so the drain gate free-runs.
    input  logic        cdda_mode,
    input  logic [1:0]  cdda_fs,
    input  logic        cdda_wr_en,
    input  logic [7:0]  cdda_wr_data,
    input  logic        cdda_flush,
    output logic        cdda_full,

    // A/V sync (dvd/av_sync.sv): signed trim added to the 48 kHz NCO increment to
    // genlock audio to the video-referenced STC; PTS of each dispatched frame out.
    input  logic signed [21:0] nco_trim,
    // DVD-FORK (telemetry): free-running observation counters, see below
    output logic        [15:0] dbg_play_cnt,   // aud_ce_play ticks / 16
    output logic        [15:0] dbg_gate_cnt,   // drain-gate closures
    output logic [32:0] dispatch_pts,
    output logic        dispatch_pts_valid,  // pulse when a PTS-tagged frame dispatches

    // PTS-SCHEDULED PLAYBACK START (lip-sync phase; v3 of the lip-sync work).
    // Phase is set at the PCM-FIFO EXIT, the only place it is settable: the 48 kHz
    // drain is HELD while the decode chain buffers, and released when the STC
    // reaches the first buffered sample's PTS (+ the signed OSD A/V Offset). From
    // then on the phase is locked by sample continuity — the audio NCO and the
    // display raster share one crystal, so the rate matches by construction and no
    // slew/trim is needed (or wanted: an entry-side PI would grind the phase away).
    // An output underrun RE-ARMS the gate, so audio re-enters at the correct phase
    // after any starvation instead of wherever data happened to resume.
    //   (v2's dispatch-side gate — hold frames entering the decoder — was HW-inert:
    //   scheduling the ENTRY to an elastic buffer does not control its EXIT time;
    //   playback phase was dispatch phase minus buffer occupancy, and the occupancy
    //   absorbed any lead change in either direction. See docs/av_sync.md.)
    // Bypassed only when sched_en is low (O[13] A/V Sync Off). Held from reset
    // otherwise (v3.1 — see the drain-gate controller comment); a stream that never
    // yields a schedulable reference free-runs via the ~2.5 s fallback timer.
    input  logic        sched_en,
    input  logic        stc_anchored,
    // ★ THE CLOCK IS ON THE DISPLAY'S TIMELINE (not the parse front). The scheduled
    // playback release waits for THIS, not for stc_anchored. stc_anchored is set by
    // the provisional parse-front anchor, which on a cold mount is up to ~1.6 s ahead
    // of the picture; releasing against it commits the playback phase to the parse
    // front, and the display's own first tagged picture then pulls the clock back
    // that far -- leaving audio permanently ahead, with nothing to re-time it
    // (play_anchor is latched once and playback is never re-phased mid-flow).
    // MEASURED 2026-09-07 on APOLLO_13: av_drift decayed to ~0 as the clock caught up
    // to play_pts, then STEPPED to +1.6 s at the tagged anchor and held there for the
    // rest of the title -- with the raster unchanged, so it was not a mode switch.
    // ⚠ NOT circular with emu's video pickup-hold. That hold releases on audio
    // ARRIVAL (the play_pts latch, taken at DISPATCH, which runs freely while the
    // drain gate is shut); this releases on video DISPLAY. Order: dispatch -> play_pts
    // -> pickup_hold releases -> first pickup -> disp_anchored -> playback releases.
    // ⚠ A stream that never yields a tagged picture (bare .m2v) never sets this and
    // takes the existing ~2.5 s arm_timer fallback, which is what it does today.
    input  logic        disp_anchored,
    // Newest PARSE-time audio PTS from ps_demux (arrival front; pulse). Gates
    // the mid-play CATCH-UP skip: audio may only jump forward when current
    // audio has actually ARRIVED — see the catch-up comment at head_catchup.
    input  logic [32:0] arr_pts,
    input  logic        arr_pts_valid,
    // Display governor "first frame is on screen" (2-FF synced). The scheduled
    // release ALSO waits for this so audio playback starts together with the
    // (STD-held) video start, not against the still-frozen STC. Not circular
    // with emu's pickup-hold: that releases on audio ARRIVAL (play_pts latch),
    // this on video DISPLAY. The fallback timer covers video-less streams.
    input  logic        video_live,
    input  logic [32:0] stc,
    // THE STC IS A CLOCK (docs/stc_freerun.md): when the display re-anchors the
    // clock (a PTS discontinuity -- a menu loop, a cell boundary, a held still),
    // it jumps by anchor_delta (one pulse per re-anchor, clk_sys). The play_err
    // re-base this was first wired for was retired (see the ⛔ note in the gate
    // controller); both stay wired and unused. Step 8 keys on anchor_disc below.
    input  logic        anchor_pulse,
    input  logic signed [33:0] anchor_delta,
    // one clk: the display re-anchored on a CONTENT jump (disp_sched anchor_disc:
    // a tagged picture's PTS stepped BACKWARD off the displayed timeline). Unlike
    // a raw backward anchor_delta it EXCLUDES the first anchor after a flush --
    // the provisional parse-front clock routinely re-anchors backward onto the
    // first picture, and that must never orphan the startup latch (step 8).
    input  logic        anchor_disc,
    input  logic signed [17:0] av_ofs,   // 90 kHz ticks; >0 = audio later (OSD "A/V Offset"; 18b: +/-2.9s)

    // decoded stereo PCM (held; update at aud_ce ~48 kHz)
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,

    // status / debug
    output logic        ac3_synced,
    output logic        ac3_err,
    output logic [15:0] dbg_ac3_resets,    // count of AC-3 self-heal reset pulses (total)
    output logic [15:0] dbg_ac3_err_resets,// of those, the ERR-caused ones (vs stall-wdog)
    // drain-gate live state for the overlay (lip-sync HW diagnosis) + the latched
    // playback-start PTS (consumed by emu's STD pickup-hold controller: video's
    // first display is deferred until this reaches the STC anchor).
    output logic        dbg_draining,
    output logic        dbg_play_pts_valid,
    output logic        dbg_armed_data,
    output logic        dbg_skip_run,
    output logic [32:0] dbg_play_pts,
    // Drift-instrument round (2026-07-03, feature/lipsync-drift): the AC-3
    // reset counter read 0 on HW while the drift meter decayed 500 ms — the
    // FIFO-dump theory is dead, and a 500 ms dispatch-PTS swing exceeds what
    // the decode-side FIFOs (~213 ms) can express, so a RE-PHASE event or an
    // STC rate error must be involved. These counters catch the event class:
    output logic [3:0]  dbg_rearm_cnt,   // underrun re-arms (saturating)
    output logic [3:0]  dbg_fbrel_cnt,   // fallback (timer) releases (saturating)
    output logic [7:0]  dbg_skip_cnt,    // stale-skip discarded frames (saturating)
    // ...of which the MID-PLAY CATCH-UP decided (head_catchup, not the load-
    // window stale-skip). Split out 2026-09-18 so telemetry can tell the two
    // apart: they discard for opposite reasons (docs/dvd_nav.md).
    output logic [3:0]  dbg_catch_cnt,
    // In-band timeline re-times (a discontinuity head dispatched into a re-armed
    // gate; docs/nonseamless_audio.md 4a). Saturating.
    output logic [3:0]  dbg_retime_cnt,
    // One-cycle request for the audio-only re-phase (flush_ctl aud_resync): a
    // re-time head is ALREADY LATCHED and has gone stale on the clock's own
    // timeline (see IN-BAND TIMELINE RE-TIME, step 6). Frames already dispatched
    // cannot be un-dispatched, so the reset is the only way to drop them.
    output logic        resync_req,
    // Playback-position error vs STC: (stc - play_anchor) - samples*1.875,
    // in 90 kHz ticks >> 4 (same 178 us/unit scale as the drift row). Positive
    // = playback LATE. Starts ~av_ofs at each release; the SLOPE is the read
    // (a slope with no re-arm events = STC-vs-NCO rate error; a step at a
    // fallback release = re-phased late). Held while armed.
    output logic [15:0] dbg_play_err,

    // TEMPORARY (MP2 silent-audio bisect, MP2_TONE_PROBE in emu): which codec
    // the output mux has selected, the MP2 core's sample strobe, and the v2
    // data-liveness taps. Cheap wires; remove with the probe once the HW
    // fault is found.
    output logic [1:0]  dbg_cur_codec,
    output logic        dbg_mp2_avalid,
    output logic        dbg_mp2_s_nz,
    output logic        dbg_mp2_pcm_nz,

    // DTS (docs/dts_decoder.md D4, P2/P3). The codebook copy (emu's dts_cb_mem) reads
    // the two FIFOs through their own read paths while cb_cp_mode (the caller holds
    // the audio path idle: enable low, no ring or CD-DA writes); cb_* is the engine's
    // codebook port, answered from DDR3; dts_tables_ok low refuses DTS. Benches tie
    // the inputs off (cb_cp_mode / steps / cb_valid / dts_tables_ok 0).
    input  logic        cb_cp_mode,
    input  logic        cb_lpcm_step,
    input  logic        cb_mp2_step,
    output logic [31:0] cb_lpcm_q,
    output logic [31:0] cb_mp2_q,
    output logic        cb_req,
    output logic        cb_sel,
    output logic [11:0] cb_addr,
    input  logic        cb_valid,
    input  logic [63:0] cb_data,
    input  logic        dts_tables_ok,
    // the engine's telemetry (dvd_telem words 26, 29, 30)
    output logic [15:0] dbg_eng_frames,
    output logic [15:0] dbg_eng_refused,
    output logic  [4:0] dbg_eng_last_err,
    output logic        dbg_dts_active
);

    localparam logic [1:0] T_AC3 = 2'd0, T_DTS = 2'd1, T_LPCM = 2'd2, T_MP2 = 2'd3;

    wire rst = ~rst_n;

    // ---------------------------------------------------------------------
    // Sample tick — fractional NCO so the average rate is exact even though
    // CLK_HZ/rate (27e6/48e3 = 562.5) isn't an integer.
    //   acc += INC each clk; aud_ce on overflow.  INC = rate/CLK_HZ * 2^32.
    //
    // RATE SELECT (VCD/SVCD): DVD audio is always 48 kHz, but MP2 on VCD/SVCD
    // is 44.1 kHz (32 kHz also legal). The increment muxes on the MP2 header
    // rate (mp2_decode.fs_o, qualified by its sync) whenever the active codec
    // is MP2; AC-3/DTS/LPCM stay 48 kHz. The select is latched ONLY while the
    // drain gate is closed (!draining — load / seek / underrun re-arm), so a
    // mid-play header rate change can't phase-kick the FIFO drain; the rate
    // swap lands with the next scheduled release. The framework side needs
    // nothing: sys/audio_out.v low-pass filters the held AUDIO_L/R and samples
    // it at the link's rate, so a 44.1 kHz core tick gives correct pitch.
    // 96 kHz (nco_fs 3): an LPCM track at 96 kHz on a 96 kHz HDMI link
    // (docs/lpcm_full.md); on a 48 kHz link lpcm_unpack decimates it instead.
    // (Localparams are elaboration-time constants — the Quartus-17 N'() cast
    // hazard applies to runtime expressions, not these.)
    // ---------------------------------------------------------------------
    localparam logic [63:0] NCO_INC64   = (64'(AUD_HZ) << 32) / CLK_HZ;
    localparam logic [31:0] NCO_INC     = NCO_INC64[31:0];
    localparam logic [63:0] NCO441_64   = (64'd44100 << 32) / CLK_HZ;
    localparam logic [31:0] NCO_INC_441 = NCO441_64[31:0];
    localparam logic [63:0] NCO32K_64   = (64'd32000 << 32) / CLK_HZ;
    localparam logic [31:0] NCO_INC_32K = NCO32K_64[31:0];
    localparam logic [63:0] NCO96K_64   = (64'd96000 << 32) / CLK_HZ;
    localparam logic [31:0] NCO_INC_96K = NCO96K_64[31:0];

    // fs coding matches the MP2 header: 0 = 44.1 k, 1 = 48 k (reset), 2 = 32 k;
    // 3 = 96 k (LPCM only).
    // nco_fs is latched in the drain-gate controller at the end of this file
    // (where `draining`/`cur_codec` are in scope — declaration-before-use).
    wire [1:0] mp2_fs;                       // the engine's (MFS: the MP2 header's rate)
    logic [1:0] nco_fs;

    // Effective increment = nominal + av_sync trim (signed, ±0.5% so always > 0).
    // av_sync genlocks the audio sample rate to the video-referenced STC.
    wire [31:0] nco_inc_base = (nco_fs == 2'd0) ? NCO_INC_441 :
                               (nco_fs == 2'd2) ? NCO_INC_32K :
                               (nco_fs == 2'd3) ? NCO_INC_96K : NCO_INC;
    wire signed [33:0] nco_inc_s   = $signed({2'b00, nco_inc_base}) + $signed(nco_trim);
    wire        [31:0] nco_inc_eff = nco_inc_s[31:0];
    logic [32:0] nco_acc;
    logic        aud_ce;
    always_ff @(posedge clk) begin
        if (rst) begin
            nco_acc <= '0;
            aud_ce  <= 1'b0;
        end else begin
            nco_acc <= {1'b0, nco_acc[31:0]} + {1'b0, nco_inc_eff};
            aud_ce  <= nco_acc[32];          // carry-out = sample tick
        end
    end

    // Drain gate (PTS-scheduled playback start — controller at end of file): the
    // NCO free-runs, but the tick only reaches the codecs' output FIFOs once the
    // scheduled start releases it. While held, dispatch/decode keep filling the
    // FIFOs; audio_l/r hold (silence).
    wire drain_en;
    // Gamepad PAUSE reuses the drain-hold: gating the play tick freezes the
    // output-FIFO read pointer (no samples consumed) and holds audio_l/r at
    // silence, so on resume playback continues seamlessly from the same sample
    // (no lost audio -> no A/V drift from the pause). The NCO keeps free-running,
    // so phase is preserved. The video side freezes in lock-step (governor +
    // watchdog-suppress + frozen STC), so nothing drifts while held.
    wire aud_ce_play = aud_ce && drain_en && ~pause;

    /* DVD-FORK (telemetry, dvd/dvd_telem.sv): count the play tick and the gate
     * closures. Pure observation.
     *
     * The NCO itself is exact -- (48000<<32)/27e6 truncates to an increment
     * worth 47999.9973 Hz, 0.06 ppm -- and it shares clk_sys with the raster,
     * so on paper audio and video cannot drift. Measured A/V drift is ~500 ppm,
     * so the discrepancy has to be downstream of the NCO: aud_ce_play is what
     * actually drains PCM, and every tick the gate swallows is a sample the
     * timeline loses. play_cnt/refreshes is that, measured internally as a
     * ratio of two counters in one clock domain -- no external reference, and
     * no assumption about which clock is right.
     *
     * Prescaled by 16 so a 16-bit counter wraps every ~21 s rather than every
     * 1.4 s, which is comfortably longer than the host's sampling interval.
     * 16 samples is 0.33 ms; over a 100 s window that is ~3 ppm of resolution. */
    logic [3:0]  dbg_play_pre;
    logic        drain_en_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            dbg_play_pre <= 4'd0;
            dbg_play_cnt <= 16'd0;
            dbg_gate_cnt <= 16'd0;
            drain_en_q   <= 1'b0;
        end else begin
            if (aud_ce_play) begin
                dbg_play_pre <= dbg_play_pre + 4'd1;
                if (dbg_play_pre == 4'd15) dbg_play_cnt <= dbg_play_cnt + 16'd1;
            end
            drain_en_q <= drain_en;
            if (drain_en_q && ~drain_en) dbg_gate_cnt <= dbg_gate_cnt + 16'd1;
        end
    end

    // ---------------------------------------------------------------------
    // Dispatch FSM: pop a descriptor, then route exactly frame_len bytes from
    // the committed byte stream to the codec sink selected by frame_type.
    // ---------------------------------------------------------------------
    typedef enum logic [1:0] { S_IDLE, S_POP, S_ROUTE } state_t;
    state_t      state;
    logic [15:0] bytes_left;
    logic [1:0]  cur_type;
    logic [32:0] cur_pts;        // PTS of the frame being dispatched
    logic        cur_pts_valid;

    // Drain-gate state (controller at end of file; declared here because the
    // stale-skip below reads `draining`).
    logic        draining;
    logic [32:0] play_pts;
    logic        play_pts_valid;
    logic        seen_valid;
    logic        ce_play_d;
    logic        armed_data;                    // a frame dispatched since (re-)arm
    logic        retime;                        // this arm was taken at a timeline discontinuity
    logic        anc_bwd;                       // a BACKWARD display re-anchor came after the latch
    logic [ARM_TIMEOUT_W-1:0] arm_timer;        // fallback-release timer

    // ---- STALE-SKIP (v4, armed only): discard audio whose PTS is already past
    // its play deadline, so the FIFO head aligns with the video timeline.
    // Why: a VOB cut mid-title yields several hundred ms of audio whose PTS
    // precede the first DISPLAYABLE video frame (video must wait for the next
    // sequence header + I-frame; audio parses immediately). That stale backlog
    // used to sit at the FIFO head: the release compare saw the head past due
    // for EVERY A/V Offset value (knob inert) and playback ran late by the
    // backlog length (the per-disc constant skews). A real player skips late
    // audio; so do we — but only while ARMED (start / underrun re-arm), never
    // mid-play (continuity wins; the underrun re-arm is the catch-up path).
    // skip_run extends a discard across following PTS-less frames (they continue
    // the stale region) until a fresh PTS-tagged frame ends it.
    localparam logic signed [34:0] STALE_TICKS   = 35'sd4500;    // ~50 ms (~1.5 AC-3 frames)
    localparam logic signed [34:0] CATCHUP_TICKS = 35'sd27000;   // ~300 ms (catch-up entry)
    logic discard_cur;   // current frame is being discarded (null sink)
    logic skip_run;      // inside a stale region (PTS-less frames follow suit)
    wire signed [34:0] head_delta =
        $signed({2'b0, stc}) - $signed({2'b0, frame_pts}) - 35'($signed(av_ofs));
    // ---- TREADMILL FIX (2026-07-03, from the DVD_drift1 HW read): the ARMED skip
    // is confined to the LOAD WINDOW (!video_live — STC frozen at the anchor, STD
    // pickup-hold pending). That is the v4 mid-title-cut backlog it was built
    // for, and it is what lets play_pts latch a CURRENT frame so `aud_caught`
    // can release the hold. An unconditional mid-play skip must never fire:
    // when delivery runs behind real time it discards audio as fast as it
    // arrives — emptying the ring, killing the STD backpressure so the demux
    // races the VBUF full and arrivals stay stale forever, latching a
    // re-arm/fallback/silence churn loop. HW-observed collapse signature: ring
    // pinned empty + VBUF pinned full + skip/fallback counters saturated.
    wire head_stale = sched_en && !draining && stc_anchored && !video_live &&
                      ( (frame_pts_valid && (head_delta > STALE_TICKS)) ||
                        (!frame_pts_valid && skip_run) );

    // ---- MID-PLAY CATCH-UP (2026-07-03 round 3, the Shea-Stadium ratchet fix).
    // HW (user recording, drops verified firing): a heavy-drop sequence starves
    // audio delivery (shared stream pinned by the compute crush); audio can only
    // play LATE through it (the data isn't there — correct). But afterwards the
    // VIDEO catches back up via the drop governor while audio had no catch-up
    // path (the treadmill fix above removed the mid-play skip) — audio stayed
    // ~1 s behind PERMANENTLY, one step per hard sequence.
    // Fix: audio may skip forward MID-PLAY, but only when current audio has
    // actually ARRIVED — arr_pts (the ps_demux parse front) at/past the play
    // target. That arrival gate is what makes this safe where the old always-on
    // skip treadmilled: in a sustained deficit nothing current ever arrives, so
    // playback keeps playing late (tracks delivery); after a transient crush the
    // demux races ahead, the front crosses current, and the dispatcher discards
    // the >CATCHUP_TICKS-stale backlog down to STALE_TICKS — one audible forward
    // jump back into lip-sync, exactly a real player's post-starvation resync.
    // Hysteresis: enter at 300 ms (never triggers on the healthy pipeline's
    // dispatch lead, which keeps head_delta NEGATIVE), exit at 50 ms.
    logic [32:0] arr_pts_l;
    logic        arr_seen;
    always_ff @(posedge clk) begin
        if (rst || !enable) begin
            arr_pts_l <= '0;
            arr_seen  <= 1'b0;
        end else if (arr_pts_valid) begin
            arr_pts_l <= arr_pts;
            arr_seen  <= 1'b1;
        end
    end
    wire signed [34:0] arr_delta =
        $signed({2'b0, stc}) - $signed({2'b0, arr_pts_l}) - 35'($signed(av_ofs));
    wire arr_current = arr_seen && (arr_delta <= STALE_TICKS);
    // TWO-SIDED "the arrivals and the clock are on the same timeline" (the re-time's
    // discriminator, 2026-09-29). arr_current above is one-sided -- it was built
    // for the catch-up, where the sign is known -- and reads "current" for an
    // arrival any distance AHEAD of the clock, e.g. new-timeline audio seen
    // against an old clock across a forward restart. The parse front normally
    // leads the clock by ~1.1-1.6 s, so the lower bound is 3 s; the upper bound is
    // the catch-up's own STALE.
    // ⚠ SIZE ARR_LEAD_MAX FROM THE VIDEO VBUF, NOT FROM THIS RING. The demux parses
    // audio and video out of ONE stream, so the audio arrival front can lead the
    // clock by no more than the video buffering allows (the VBUF depth, ~1-1.6 s):
    // the demux stalls on a full VBUF long before this ring alone would bound it.
    // (At 64 kbps a 32 KB ring holds ~4 s -- sizing the bound from the ring would
    // make it wrong for exactly the low-bitrate tracks.)
    localparam logic signed [34:0] ARR_LEAD_MAX = 35'sd270000;   // 3 s
    wire arr_agree = arr_seen && (arr_delta <= STALE_TICKS) && (arr_delta > -ARR_LEAD_MAX);
    wire head_catchup = sched_en && draining && stc_anchored && video_live && arr_current &&
                        ( frame_pts_valid
                            ? (head_delta > (skip_run ? STALE_TICKS : CATCHUP_TICKS))
                            : skip_run );
    wire head_retime_stale;           // IN-BAND RE-TIME (below): late head on the new timeline
    wire head_discard = head_stale || head_catchup || head_retime_stale;

    // ---- PRE-ANCHOR DISPATCH HOLD (v5.1): audio packs reach the demux BEFORE
    // the first video PTS, so for a brief window stc_anchored=0 and the
    // stale-skip has no jurisdiction — stale frames entered the decode FIFOs
    // and the first PTS-tagged one latched play_pts with a PRE-ANCHOR value
    // (~mux-lag behind the anchor). play_pts_valid then stuck: aud_caught could
    // never fire, emu's video hold expired via fallback, and the release compare
    // was instantly past-due for every A/V Offset (HW: drift parked at −455 ms,
    // knob inert, through five otherwise-correct builds). Hold dispatch in
    // S_IDLE until the STC anchors; the anchor comes from the VIDEO side of the
    // demux, which flows regardless of audio, so this cannot deadlock — and a
    // ~half-ARM_TIMEOUT fallback opens it for video-PTS-less streams (raw ES).
    logic [ARM_TIMEOUT_W-2:0] anchor_tmr;
    wire pre_anchor_hold = sched_en && !stc_anchored && !(&anchor_tmr);

    // ---- IN-BAND TIMELINE RE-TIME (2026-09-29, docs/nonseamless_audio.md 4a) ----
    // A content discontinuity (a non-seamless cell join, a menu loop, a PGC
    // boundary) restarts the audio PTS in the stream itself: the frame that
    // carries it is the exact point where the old timeline's audio ends and the
    // new one's begins. Re-time HERE, at that frame, instead of flushing:
    //   1. DETECT: a PTS-tagged head whose PTS steps off the dispatched timeline
    //      (backward > DISC_BACK, or forward > DISC_FWD -- above the spec's
    //      0.7 s maximum PTS spacing, so ordinary sparse tags never trip it).
    //   2. HOLD: while the old timeline still has audio downstream (draining, or
    //      armed with a latched play_pts) the frame is NOT popped. The decode
    //      and PCM FIFOs play the old tail out at the normal rate -- nothing
    //      is discarded -- until the underrun re-arm below closes the gate.
    //   3. RE-ARM WITH EMPTY FIFOs: then the frame dispatches into the armed
    //      gate and latches play_pts. This is the one re-arm that cannot hit the
    //      v5.3 deadlock (a re-arm with FULL FIFOs): here they are empty.
    //   4. RELEASE ON THE RIGHT TIMELINE: that arm is a `retime` arm, whose
    //      release also needs stc - play_pts < RETIME_WIN. While the display
    //      has not yet crossed, the clock is still on the OLD timeline and a
    //      backward-stepped frame reads grossly LATE; releasing it there is how
    //      Thayer's audio ended up 1.4 s early for whole clips (2b step 3).
    //      The display's own re-anchor brings the clock within the window.
    // ★ WHY NOT THE DISPLAY-TIME FLUSH IT REPLACES (flush_ctl aud_resync on
    // disc_rephase): that fired when the PICTURE crossed the join, but it reset
    // the RING -- a parse-front buffer that by then already held the new cell's
    // first ~1.1-1.4 s. Every such flush threw that opening away (Thayer: ~1.3 s
    // of silence at every clip; Scooby-Doo 2's "good job" -> "job" was the same
    // loss behind a different trigger).
    //   6. A STALE LATCH (safety net): a re-time head latched and then the clock
    //      moved again -- a second re-anchor -- to where that head is RETIME_WIN or
    //      more late while the arrivals agree. Since the hold now waits for
    //      arr_agree before dispatching (step 2), a latch normally happens on the
    //      head's own timeline and this does not fire; it covers the HOLD_W expiry
    //      and double re-anchors. Nothing already in the
    //      decoder can be dropped except by a reset, so the decoder asks for the
    //      audio-only re-phase (resync_req -> flush_ctl aud_resync): the same
    //      reset the old display-time path fired at every discontinuity, now only
    //      on the decoder's own evidence that its latch is wrong.
    // Liveness: a hold that never sees its underrun (HOLD_W, ~0.6 s) forces the
    // re-arm; a retime arm that never reaches its window takes the ordinary
    // arm_timer fallback. Only with scheduling on (sched_en): the A/V Sync Off
    // diagnostic free-runs exactly as before.
    localparam logic signed [34:0] DISC_BACK_TICKS = 35'sd4500;     // 50 ms
    localparam logic signed [34:0] DISC_FWD_TICKS  = 35'sd90000;    // 1 s
    localparam logic signed [34:0] RETIME_WIN      = 35'sd45000;    // 0.5 s
    logic [32:0] last_pts;          // PTS of the last tagged frame dispatched to play
    logic        last_pts_v;
    logic        cur_disc;          // the frame being dispatched is a discontinuity head
    logic [HOLD_W-1:0] hold_tmr;
    wire  signed [34:0] pts_step = $signed({2'b0, frame_pts}) - $signed({2'b0, last_pts});
    //   7. NOT AT AN AUTHORED-SEAMLESS JOIN (HW 2026-09-29, The Matrix white-rabbit
    //      cells, control arm = the pre-change build). A seamless_play cell restarts
    //      its PTS while the soundtrack runs on SAMPLE FOR SAMPLE; the author's
    //      audio-vs-video offset at the boundary is not a phase to honour. Re-timing
    //      there took a ~190 ms gap and then released the head ~0.2 s LATE against
    //      the first picture (c4, c7), where the old build -- which just played on --
    //      lost 0 ms. frame_seamless is the reader's cell_seamless stamped per frame
    //      by audio_ring at its WRITE side (the old flush_ctl carve-out sampled the
    //      same level at display time, ~1 s later in content -- the wrong cell).
    //      Such a head is simply dispatched: sample-continuous, last_pts follows it.
    //      ★ Menus never carry the stamp, BY CONSTRUCTION: the reader writes
    //      cell_seamless only in S_CELL_LOAD2's title branch (the menu_dom branch
    //      never does), and every PGC load and transport seek clears it -- so a
    //      looping menu cell always takes the re-time (the #63 lip-sync case).
    wire  head_disc = sched_en && last_pts_v && frame_pts_valid && !frame_seamless &&
                      ((pts_step < -DISC_BACK_TICKS) || (pts_step > DISC_FWD_TICKS));
    // HOLD until (a) the old timeline's audio has played out (the gate re-armed with
    // empty FIFOs) AND (b) the clock is on the head's timeline -- the demux's
    // arrivals agree with it (arr_agree). (b) was added after HW round 2: a head
    // dispatched while the clock was still elsewhere gets LATCHED, and a latch can
    // only be undone by a reset; waiting for the clock instead lets the dispatch-
    // side trim below see the head's true lateness and drop only the late part.
    wire  disc_hold = head_disc && (draining || play_pts_valid || !arr_agree) && !(&hold_tmr);
    // the bound expired with old audio still queued: force the re-arm (liveness)
    wire  hold_expired = head_disc && (draining || play_pts_valid) && (&hold_tmr);
    // 5. OVERLAP: the old cell's audio may run a little past its video, so the
    //    display can re-anchor while the old tail is still playing. The new
    //    head then reads slightly LATE on its own timeline. Playing it anyway
    //    would leave the whole new clip that late (the mid-play catch-up only
    //    acts past 300 ms), so a discontinuity head that is late by more than
    //    STALE but less than RETIME_WIN is discarded at the re-armed gate,
    //    exactly like the load-window stale-skip -- bounded by the overlap.
    //    Late by RETIME_WIN or more means the clock is still on the OTHER
    //    timeline: that head is kept and waits (step 4), never discarded.
    //    ⚠ CORRECTED 2026-09-29 (HW, ULTIMATE_T2 boot -> menu): "late by
    //    RETIME_WIN or more means the other timeline" is NOT always true. After
    //    a still, the display re-anchored to the new menu segment and its first
    //    audio then arrived 0.53 s LATE on that same new timeline, with current
    //    audio queued behind it; held as "other timeline", it went out via the
    //    2.5 s fallback and played 2.5 s late. The discriminator is the ARRIVALS:
    //    if the demux's newest audio agrees with the clock (arr_agree), a late
    //    head is stale on the clock's own timeline and is discarded at any
    //    lateness; if the arrivals disagree too, the clock is elsewhere -> wait.
    assign head_retime_stale = head_disc && !draining && !play_pts_valid &&
                               (head_delta > STALE_TICKS) &&
                               ((head_delta < RETIME_WIN) || arr_agree);

    // DTS (docs/dts_decoder.md P3): a DTS frame goes to the audio engine, like AC-3, once
    // its codebooks are in DDR3 (dts_tables_ok); before that, or if the copy's checksum
    // failed, it is discarded as before. eng_frame: the current frame is the engine's.
    wire         dts_ok_frame = (cur_type == T_DTS) && dts_tables_ok;
    // MP2 (docs/mp2_engine.md M3) is the engine's too: mp2_decode is gone, bit-identical
    // pair for pair (bench/dvd/run_mp2_ab.sh)
    wire         eng_frame    = (cur_type == T_AC3) || dts_ok_frame || (cur_type == T_MP2);

    // codec sink readiness for the byte currently offered
    logic        ac3_full;
    logic        lpcm_full;
    wire         sink_ready = discard_cur         ? 1'b1 :   // stale: null sink
                              eng_frame            ? ~ac3_full  :   // AC-3, DTS, MP2
                              (cur_type == T_LPCM) ? (~lpcm_full | lpcm_bad) :
                              1'b1;                       // DTS without tables: discard

    // consume a byte this cycle?
    wire consume = (state == S_ROUTE) && ring_valid && sink_ready;
    assign ring_ready = consume;                          // pop on consume only

    assign frame_pop = (state == S_POP);                  // 1-cycle descriptor pop
    // a discontinuity head entering the (re-armed) decoder: its arm is a retime arm
    wire disc_dispatch = (state == S_POP) && cur_disc && cur_pts_valid && !discard_cur;

    always_ff @(posedge clk) begin
        if (rst) begin
            state              <= S_IDLE;
            bytes_left         <= '0;
            cur_type           <= T_AC3;
            cur_pts            <= '0;
            cur_pts_valid      <= 1'b0;
            dispatch_pts       <= '0;
            dispatch_pts_valid <= 1'b0;
            discard_cur        <= 1'b0;
            skip_run           <= 1'b0;
            anchor_tmr         <= '0;
            dbg_skip_cnt       <= '0;
            dbg_catch_cnt      <= '0;
            last_pts           <= '0;
            last_pts_v         <= 1'b0;
            cur_disc           <= 1'b0;
            hold_tmr           <= '0;
            dbg_retime_cnt     <= '0;
        end else begin
            dispatch_pts_valid <= 1'b0;       // 1-cycle pulse
            // in-band re-time: the hold timer runs only while a discontinuity head waits
            if (disc_hold && frame_valid && (state == S_IDLE)) hold_tmr <= hold_tmr + 1'b1;
            else if (!head_disc)                               hold_tmr <= '0;
            if (!sched_en) last_pts_v <= 1'b0;
            // pre-anchor fallback timer: counts while a frame waits un-anchored
            if (!sched_en)                                        anchor_tmr <= '0;
            else if (!stc_anchored && frame_valid && ~&anchor_tmr) anchor_tmr <= anchor_tmr + 1'b1;
            // a stale/catch-up region now spans armed AND draining states (the
            // mid-play catch-up needs skip_run); it ends at the next PTS-tagged
            // frame that is played (below), or when scheduling is off entirely
            if (!sched_en) skip_run <= 1'b0;
            if (!enable) begin
                state <= S_IDLE;              // parked; audio_ring drops frames
            end else begin
                case (state)
                    S_IDLE: if (frame_valid && !pre_anchor_hold && !disc_hold) begin
                        bytes_left    <= frame_len;
                        cur_disc      <= head_disc;         // dispatched as a re-time head
                        cur_type      <= frame_type;
                        cur_pts       <= frame_pts;        // latch with the descriptor
                        cur_pts_valid <= frame_pts_valid;
                        discard_cur   <= head_discard;     // stale-skip / catch-up decision at pop
                        if (head_catchup && !head_stale && !(&dbg_catch_cnt))
                            dbg_catch_cnt <= dbg_catch_cnt + 1'b1;
                        if (head_discard)          skip_run <= 1'b1;
                        else if (frame_pts_valid)  skip_run <= 1'b0;  // fresh PTS ends the region
                        state         <= S_POP;
                    end
                    S_POP: begin
                        // dispatching this frame into the decoder — emit its PTS
                        // (suppressed for discarded frames: they never play, so they
                        // must not become the drain-gate phase reference or drive
                        // av_sync's telemetry)
                        dispatch_pts       <= cur_pts;
                        dispatch_pts_valid <= cur_pts_valid && !discard_cur;
                        if (cur_pts_valid && !discard_cur && sched_en) begin
                            last_pts   <= cur_pts;      // the timeline now playing
                            last_pts_v <= 1'b1;
                            if (cur_disc && !(&dbg_retime_cnt)) dbg_retime_cnt <= dbg_retime_cnt + 1'b1;
                        end
                        if (discard_cur && !(&dbg_skip_cnt)) dbg_skip_cnt <= dbg_skip_cnt + 1'b1;
                        if (bytes_left == 16'd0) state <= S_IDLE;
                        else                     state <= S_ROUTE;
                    end
                    S_ROUTE: if (consume) begin
                        if (bytes_left == 16'd1) state <= S_IDLE;
                        bytes_left <= bytes_left - 16'd1;
                    end
                endcase
            end
        end
    end

    // latch the active *playable* codec for the output mux (ignore DTS).
    // cur_type is valid from S_POP onward (set when leaving S_IDLE).
    // Was a 1-bit cur_is_lpcm; widened to a 2-bit selector when MP2 became the
    // third playable codec (T_MP2 reuses the old "unknown" code — see ps_demux).
    logic [1:0] cur_codec;
    always_ff @(posedge clk) begin
        if (rst) cur_codec <= T_AC3;
        else if ((state == S_POP) && !discard_cur) begin
            // DTS and MP2 play out of the LPCM FIFO (the engine's pairs are fed into it)
            if (cur_type == T_MP2) cur_codec <= T_LPCM;
            else if (cur_type != T_DTS) cur_codec <= cur_type;
            else if (dts_tables_ok) cur_codec <= T_LPCM;
            // DTS without tables: discarded; keep the previous playable codec selected
        end
    end

    // ---------------------------------------------------------------------
    // AC-3 decoder: audio_engine (the engine's AC-3 program + imdct_512: decode +
    // downmix) feeding pcm_out (Q8.23->s16). docs/ac3_engine.md "W1". It replaced
    // ac3_front (2026-10-03), bit-identical block for block (bench/dvd/run_ac3_ab.sh).
    // ---------------------------------------------------------------------
    // The engine takes a FRAME: a descriptor (the frame's byte length), then exactly
    // that many bytes. The descriptor is presented as the dispatcher pops an AC-3
    // frame it will play (S_POP), and held until the engine's FRAME instruction takes
    // it; the bytes follow through the normal route, accepted when the engine asks for
    // one (in_ready).
    // ⚠ An engine reset mid-frame (the stall watchdog, `enable` low) loses the frame:
    // the engine restarts waiting for a descriptor and would never take the rest of
    // its bytes, so the dispatcher would wait in S_ROUTE for ever (ac3_front's byte
    // FIFO always took them). ac3_drop discards the remainder of that frame instead,
    // and the engine starts clean on the next one.
    wire         ac3_core_rst;
    logic        ac3_drop;
    wire        ac3_wr   = consume && eng_frame && !discard_cur && !ac3_drop;
    wire [7:0]  ac3_data = ring_byte;
    logic        ac3_desc_v;
    logic [15:0] ac3_desc_len;
    wire         ac3_fr_ready, ac3_in_ready, eng_codec_busy, eng_frame_ok;
    // the program the engine runs: 1 AC-3, 0 DTS, 2 MP2, chosen by the frame popped (a
    // change waits for the engine to idle, then resets it; the descriptor waits)
    logic  [1:0] eng_codec_req;
    // the last frame the dispatcher played was DTS / MP2: the stall watchdog then watches
    // the engine's frames (cur_codec reads LPCM, the FIFO both play out of), the LPCM
    // unpacker takes the serialised pairs as 16-bit, and MP2's rate drives the NCO
    logic        dts_active, mp2_active;
    wire         eng_pcm = dts_active || mp2_active;
    assign dbg_dts_active = dts_active;
    // DTS's PCM pairs from the engine (serialised into the LPCM FIFO further down)
    wire [15:0]  dts_l, dts_r;
    wire         dts_valid;
    logic        ser_v;
    wire         dts_ready = !ser_v;
    always_ff @(posedge clk) begin
        if (rst) begin eng_codec_req <= 2'd1; dts_active <= 1'b0; mp2_active <= 1'b0; end
        else if ((state == S_POP) && !discard_cur) begin
            if (eng_frame) eng_codec_req <= (cur_type == T_AC3) ? 2'd1 : (cur_type == T_MP2) ? 2'd2 : 2'd0;
            dts_active <= dts_ok_frame;
            mp2_active <= (cur_type == T_MP2);
        end
    end
    always_ff @(posedge clk) begin
        if (rst) ac3_drop <= 1'b0;
        else if (ac3_core_rst && eng_frame && ((state == S_POP) || (state == S_ROUTE)))
            ac3_drop <= 1'b1;
        else if (state == S_POP) ac3_drop <= 1'b0;           // a new frame
        if (ac3_core_rst) ac3_desc_v <= 1'b0;
        else begin
            if (ac3_desc_v && ac3_fr_ready) ac3_desc_v <= 1'b0;
            if ((state == S_POP) && eng_frame && !discard_cur && (bytes_left != 16'd0)) begin
                ac3_desc_v   <= 1'b1;
                ac3_desc_len <= bytes_left;
            end
        end
    end
    // a byte is accepted only when the engine asks for one (it asks only inside a frame
    // whose descriptor it has taken), or dropped after a mid-frame reset
    assign ac3_full = !(ac3_in_ready || ac3_drop);

    // DVD-FORK 2026-08-31: acmod 1 (1/0 mono) decodes a single fbw channel, so
    // pcm_mem ch1 is not written. Tell pcm_out to read ch0 for BOTH outputs.
    wire [2:0]  ac3_acmod;
    wire        ac3_mono = (ac3_acmod == 3'd1);

    // ac3_front <-> pcm_out block handshake
    wire        imdct_done, pcm_done_w;
    wire [8:0]  pcm_rd_addr9;             // {ch, idx[7:0]} from pcm_out
    wire signed [31:0] pcm_rd_data;
    wire [15:0] ac3_lvl_q;               // DVD-FORK: per-frame output level (Q2.14)
    wire signed [15:0] ac3_l, ac3_r;
    wire        ac3_aud_valid;

    // ---------------------------------------------------------------------
    // AC-3 self-heal. The engine REFUSES a frame it cannot decode (drains it and
    // waits for the next: ac3_err pulses, counted in dbg_ac3_err_resets), so a
    // refusal needs no reset -- ac3_front's err_unsupported was sticky and halted it,
    // which is what this reset used to clear. What remains is the decode-STALL
    // watchdog (no imdct_done for ~0.6 s while fed) and `enable` going low (the
    // dispatcher parks mid-frame): either resets the engine, so it restarts at a frame
    // boundary. rsthold gives a clean multi-cycle reset and a one-shot.
    // ---------------------------------------------------------------------
    logic [4:0]  ac3_rsthold;
    logic [WDOG_W-1:0] ac3_wdog;           // 2^24/27e6 ~= 0.62 s
    wire         ac3_wdog_to = (&ac3_wdog);
    // Distinguish a genuinely STUCK decoder (fed bytes but produced no output) from
    // mere INPUT STARVATION (a governor/demux delivery GAP: no bytes arriving). The
    // AC-3 byte stream is delivered in per-frame bursts paced to video, so a stall
    // (>0.62 s with no imdct_done) routinely means "ran out of input," NOT "hung."
    // Resetting on starvation is HARMFUL: it desyncs ac3_front, so when bytes resume
    // the re-sync produces an audible "pop" (HW: row-15 dbg_ac3_resets ticks on every
    // static pop, while the co-sim — which feeds bytes continuously — shows 0 errors).
    // fed_since_prog tracks whether we actually fed >=1 byte since the last decode
    // progress; only reset on a stall if we WERE fed (stuck), not if starved (wait).
    logic        ac3_fed_since_prog;
    wire         ac3_stall_rst = ac3_wdog_to && ac3_fed_since_prog;
    always_ff @(posedge clk) begin
        if (rst) begin
            ac3_rsthold        <= '0;
            ac3_wdog           <= '0;
            ac3_fed_since_prog <= 1'b0;
        end else begin
            // stall watchdog: clear on progress, count only while AC-3 selected.
            // Also held clear while the drain gate withholds the output (!drain_en):
            // the decoder is then OUTPUT-blocked on the full pcm fifo by design —
            // not stuck — and a self-heal reset would dump the very bytes queued
            // for the scheduled playback start.
            // ★ AND while PAUSED, for the same reason: `pause` withholds the play
            // tick (aud_ce_play), so the decoder blocks on the full pcm fifo by
            // design. Without this term (issue: "out of sync after a pause",
            // 2026-10-09) the watchdog fired every ~0.62 s of pause, each reset
            // dumped the frame in the engine and the dispatcher fed it the next --
            // ~one 32 ms frame lost per 0.65 s paused, so audio resumed EARLY by
            // about 5% of the pause (measured on the rig: a 10 s pause -> +480 ms
            // av_drift, a long one ~2.9 s lost). Gate: bench/dvd/run_pause_wdog.sh.
            if (imdct_done || eng_frame_ok || !((cur_codec == T_AC3) || eng_pcm) || !drain_en || pause)
                ac3_wdog <= '0;
            else                           ac3_wdog <= ac3_wdog + 1'b1;
            // input-activity tracker: cleared on decode progress, set when a byte is fed
            if (imdct_done || eng_frame_ok || !((cur_codec == T_AC3) || eng_pcm))
                ac3_fed_since_prog <= 1'b0;
            else if (ac3_wr)               ac3_fed_since_prog <= 1'b1;
            // start a reset pulse on a fresh error, or a stall timeout WHILE FED
            if (ac3_rsthold != 0)
                ac3_rsthold <= ac3_rsthold - 1'b1;
            else if (ac3_stall_rst)
                ac3_rsthold <= 5'd31;
        end
    end
    assign ac3_core_rst = rst | (ac3_rsthold != 0) | !enable;    // parked: held in reset

    // Debug: count self-heal reset pulses (rising edges); dbg_ac3_err_resets now
    // counts the engine's REFUSED frames (a real bitstream it rejects -- no reset
    // follows one any more), the name kept for the telemetry consumers. (The old dbg_ac3_underruns counter was bogus: it gated on aud_ce &&
    // !ac3_aud_valid, but ac3_aud_valid is asserted the cycle AFTER aud_ce, so the
    // two never coincide and it counted ~every tick — it measured nothing useful.)
    logic ac3_rst_d;
    always_ff @(posedge clk) begin
        if (rst) begin
            dbg_ac3_resets     <= '0;
            dbg_ac3_err_resets <= '0;
            ac3_rst_d          <= 1'b0;
        end else begin
            ac3_rst_d <= (ac3_rsthold != 0);
            if ((ac3_rsthold != 0) && !ac3_rst_d)
                dbg_ac3_resets <= dbg_ac3_resets + 1'b1;              // stall / park resets
            if (ac3_err && !(&dbg_ac3_err_resets))
                dbg_ac3_err_resets <= dbg_ac3_err_resets + 1'b1;      // refused frames
        end
    end

    audio_engine ac3_engine_inst (
        .clk         (clk),
        .rst         (ac3_core_rst),
        .codec_req   (eng_codec_req),
        .codec_busy  (eng_codec_busy),
        .fr_len      (ac3_desc_len),
        .fr_valid    (ac3_desc_v),
        .fr_ready    (ac3_fr_ready),
        .in_byte     (ac3_data),
        .in_valid    ((state == S_ROUTE) && ring_valid && eng_frame && !discard_cur && !ac3_drop),
        .in_ready    (ac3_in_ready),
        // PCM read port -- pcm_out walks ch 0/1; zero-extend its 9-bit addr to the
        // 11-bit {ch[2:0],idx[7:0]} imdct_512 expects (only ch 0/1 are read).
        .imdct_done  (imdct_done),
        .pcm_rd_addr ({2'b00, pcm_rd_addr9}),
        .pcm_rd_data (pcm_rd_data),
        .lvl_q       (ac3_lvl_q),
        .pcm_acmod   (ac3_acmod),
        .pcm_done    (pcm_done_w),
        .dts_l       (dts_l),
        .dts_r       (dts_r),
        .dts_valid   (dts_valid),
        .dts_ready   (dts_ready),
        .mp2_fs      (mp2_fs),
        .n_ignored   (),
        .cb_req      (cb_req),
        .cb_sel      (cb_sel),
        .cb_addr     (cb_addr),
        .cb_valid    (cb_valid),
        .cb_data     (cb_data),
        .synced      (ac3_synced),
        .frame_ok    (eng_frame_ok),
        .refused     (ac3_err),
        .err_code    (dbg_eng_last_err),
        .n_frames    (dbg_eng_frames),
        .n_refused   (dbg_eng_refused),
        .err_seen    (),
        .n_overrun   ()
    );

    // FIFO_AW=11 -> 2048 sample-pairs (~43 ms) to ride out the demux/governor's
    // per-frame burst delivery without underrunning.
    // NOTE: pcm_out is reset by `rst` only, NOT ac3_core_rst. A self-heal resync of
    // ac3_front must NOT dump pcm_out's output FIFO — keeping it lets the buffered
    // samples play through the brief resync gap (smooth) instead of a hard cut.
    pcm_out #(.FIFO_AW(11)) pcm_out_inst (
        .clk         (clk),
        .rst         (rst),
        .start       (imdct_done),
        .mono        (ac3_mono),
        .pcm_rd_addr (pcm_rd_addr9),
        .pcm_rd_data (pcm_rd_data),
        .lvl_q       (ac3_lvl_q),
        .busy        (),
        .done        (pcm_done_w),

        .aud_clk     (clk),
        .aud_rst     (rst),
        .aud_ce      (aud_ce_play),
        .audio_l     (ac3_l),
        .audio_r     (ac3_r),
        .aud_valid   (ac3_aud_valid)
    );

    // ---------------------------------------------------------------------
    // LPCM unpacker (BE->LE 16-bit, L/R interleave).
    // ---------------------------------------------------------------------
    wire        lpcm_wr   = consume && (cur_type == T_LPCM) && !discard_cur && !lpcm_bad;
    // DVD LPCM is the playing codec (not the engine's pairs, not CD-DA)
    wire        lpcm_src  = (cur_codec == T_LPCM) && !eng_pcm && !cdda_mode;
    assign      lpcm_unsup = lpcm_src && lpcm_bad;
    wire signed [15:0] lpcm_l, lpcm_r;
    wire        lpcm_aud_valid;

    // DTS's stereo PCM plays out of this FIFO (idle while DTS plays; zero new M10K): the
    // engine's s16 pairs become the 4 big-endian bytes of a 16-bit LPCM pair (L hi, L
    // lo, R hi, R lo), written when the FIFO has room and the ring is not writing LPCM.
    logic [31:0] ser_pair;
    logic  [1:0] ser_k;
    wire         ser_wr = ser_v && !lpcm_full && !lpcm_wr && !cdda_mode;
    wire  [7:0]  ser_byte = (ser_k == 2'd0) ? ser_pair[31:24] : (ser_k == 2'd1) ? ser_pair[23:16] :
                            (ser_k == 2'd2) ? ser_pair[15:8]  : ser_pair[7:0];
    always_ff @(posedge clk) begin
        if (rst) begin ser_v <= 1'b0; ser_k <= 2'd0; end
        else begin
            if (dts_valid && dts_ready) begin ser_pair <= {dts_l, dts_r}; ser_v <= 1'b1; ser_k <= 2'd0; end
            else if (ser_wr) begin
                ser_k <= ser_k + 2'd1;
                if (ser_k == 2'd3) ser_v <= 1'b0;
            end
        end
    end

    // FIFO_AW=12 -> 4096 sample-pairs (~85 ms) of elastic buffering so bursty
    // demux delivery (governor releases ~1 frame of audio then holds) doesn't
    // underrun the steady 48 kHz output.
    // CD-DA/WAV mode takes the unpacker over wholesale: bytes come from the
    // reader (little-endian, plain 16-bit), and a seek flush resets the
    // assembler + FIFO. DVD LPCM behaviour (cdda_mode=0) is bit-identical.
    lpcm_unpack #(.FIFO_AW(12), .CB_INIT(LPCM_INIT)) lpcm_unpack_inst (
        .clk      (clk),
        .rst      (rst | (cdda_mode & cdda_flush)),
        .quant    ((cdda_mode || eng_pcm) ? 2'd0 : lpcm_quant),
        .le       (cdda_mode),
        // the channel count and the 2:1 decimation are DVD LPCM's alone: CD-DA and the
        // engine's serialised pairs take the original stereo path
        .nch_m1   ((cdda_mode || eng_pcm) ? 3'd1 : lpcm_nch_m1),
        .dec      (!(cdda_mode || eng_pcm) && lpcm_fs96 && !link96),
        .wr_en    ((cdda_mode ? cdda_wr_en : (lpcm_wr || ser_wr)) && !cb_cp_mode),
        .wr_data  (cdda_mode ? cdda_wr_data : lpcm_wr ? ring_byte : ser_byte),
        .full     (lpcm_full),
        .afull    (cdda_full),
        .aud_ce   (aud_ce_play),
        .audio_l  (lpcm_l),
        .audio_r  (lpcm_r),
        .aud_valid(lpcm_aud_valid),
        .cp_mode  (cb_cp_mode),            // D4 codebook copy
        .cp_step  (cb_lpcm_step)
    );
    assign cb_lpcm_q = {lpcm_l, lpcm_r};

    // ---------------------------------------------------------------------
    // MP2 (MPEG-1 Layer II) decodes on the audio engine (docs/mp2_engine.md M3; above):
    // mp2_decode, its own FIFO and its self-heal are gone. A frame the engine cannot
    // decode is refused and drained (no reset), as AC-3 and DTS. What stays is the
    // half of the DTS ADPCM codebook its PCM FIFO carried at power-up (D4): the same
    // 4096 x 32 words, read out once by dts_cb_mem (dvd/dts/cb_host_ram.sv).
    // ---------------------------------------------------------------------
    cb_host_ram #(.AW(12), .CB_INIT(MP2_INIT)) cb_host_mp2_inst (
        .clk     (clk),
        .rst     (rst),
        .cp_step (cb_mp2_step),             // D4 codebook copy
        .cp_q    (cb_mp2_q)
    );
    assign dbg_mp2_s_nz   = 1'b0;           // (MP2_TONE_PROBE: mp2_decode's taps)
    assign dbg_mp2_pcm_nz = mp2_active && dts_valid && ((dts_l != 16'd0) || (dts_r != 16'd0));

    // ---------------------------------------------------------------------
    // Target mux: pick the active codec and latch each new sample into
    // tgt_l/tgt_r. The source's aud_valid pulse (one per aud_ce, asserted the
    // cycle AFTER aud_ce because pcm_out/lpcm_unpack register it) is the
    // correct "new sample" strobe — do NOT additionally gate on aud_ce, or
    // the strobe and aud_ce never align and nothing is ever captured.
    // Between pulses the last sample is held (silence -> DC hold).
    //
    // This is exactly the module's original mux (unchanged conditions, same
    // "reset to 0 / latch on aud_valid" semantics). tgt_nl/tgt_nr is its NEXT
    // value, computed combinationally, and the output register below follows
    // THAT, not tgt_l: outside a de-click audio_l <= tgt_nl is the original
    // register cycle for cycle. ⚠ Following the registered tgt_l instead adds
    // one clk_sys of latency, which mp2_chain_tb / vcd_chain_tb (they capture
    // one cycle after aud_valid) report as thousands of sample mismatches.
    // cdda_mode pins it to the LPCM unpacker regardless of what the (idle)
    // dispatch FSM last latched.
    // ---------------------------------------------------------------------
    wire [1:0] eff_codec = cdda_mode ? T_LPCM : cur_codec;
    reg signed [15:0] tgt_l, tgt_r;
    logic signed [15:0] tgt_nl, tgt_nr;
    always_comb begin
        tgt_nl = tgt_l;
        tgt_nr = tgt_r;
        if (rst || !enable) begin
            tgt_nl = '0;
            tgt_nr = '0;
        end else if (eff_codec == T_LPCM) begin
            if (lpcm_aud_valid) begin tgt_nl = lpcm_l; tgt_nr = lpcm_r; end
        end else begin
            if (ac3_aud_valid)  begin tgt_nl = ac3_l;  tgt_nr = ac3_r;  end
        end
    end
    always_ff @(posedge clk) begin
        tgt_l <= tgt_nl;
        tgt_r <= tgt_nr;
    end

    // ---------------------------------------------------------------------
    // De-click: a GENTLE reset (aud_soft_switch) must not step the module's
    // actual audio_l/audio_r pins to 0 in one clk_sys cycle — by the time any
    // logic outside this module could react to rst_n falling, tgt_l/tgt_r
    // above has already snapped to 0, so the ramp has to live here, chasing
    // that target rather than following it directly. A HARD reset
    // (rst && !aud_soft_switch: a seek/mount/jump/other flush, a real
    // content discontinuity) keeps today's instant cut.
    //
    // Two edges, two arms:
    //  * RAMP-OUT: aud_soft_switch starts a DECLICK_WIN window, so the old
    //    track's held sample walks down to the (already 0) target.
    //  * RAMP-IN: soft_arm stays set from the gentle reset until the FIRST
    //    new sample lands in tgt_l/tgt_r, and THAT sample restarts the
    //    window, so 0 -> the new track's level walks up too.
    // ⚠ A window counted from the reset alone does NOT cover the ramp-in:
    // after aud_resync the ring is empty, the next frame of the new
    // substream must come through the demux, and the drain gate then holds
    // it until the STC reaches its PTS -- tens to hundreds of ms against a
    // 2.4 ms window. (dvd_audio_decode_tb D5 is that case; D3 runs with the
    // scheduler off and could not see it.) Waiting while armed costs
    // nothing: the target is 0 until a sample arrives, so the output is
    // already at rest. A hard reset disarms.
    // Outside the window audio_l/r follows tgt_l/tgt_r on the SAME cycle as
    // before the mux was split: ordinary playback is NEVER slew-limited (a
    // legitimate full-scale transient can swing the whole 16-bit range
    // between two consecutive samples).
    //
    // DECLICK_STEP=1 LSB/clk_sys cycle covers the full 16-bit range (65535)
    // in DECLICK_WIN cycles = ~2.43 ms @ 27 MHz — a standard, imperceptible-
    // as-a-fade de-click time, chosen (like the IEC 61937 pacing counters
    // elsewhere in this codebase) so one register width IS the divider,
    // with no extra arithmetic needed to size the window to the step.
    // ---------------------------------------------------------------------
    localparam logic [16:0]      DECLICK_WIN  = 17'd65535;
    localparam logic signed [15:0] DECLICK_STEP = 16'sd1;

    // the target mux's own "a new sample was latched" condition, verbatim
    wire tgt_upd = !rst && enable &&
                   ((eff_codec == T_LPCM) ? lpcm_aud_valid : ac3_aud_valid);

    reg [16:0] declick_win = 17'd0;
    reg        soft_arm    = 1'b0;
    always_ff @(posedge clk) begin
        if (rst && !aud_soft_switch) begin          // hard cause: no ramp either way
            soft_arm    <= 1'b0;
            declick_win <= 17'd0;
        end else if (aud_soft_switch) begin
            soft_arm    <= 1'b1;
            declick_win <= DECLICK_WIN;
        end else if (soft_arm && tgt_upd) begin     // first sample after the switch
            soft_arm    <= 1'b0;
            declick_win <= DECLICK_WIN;
        end else if (declick_win != 17'd0) begin
            declick_win <= declick_win - 17'd1;
        end
    end
    // aud_soft_switch itself is in the OR: the output follows the NEXT target,
    // which is already 0 on the switch's first cycle, while soft_arm and
    // declick_win (registered) only rise a cycle later -- without it that
    // first cycle is exactly the one-cycle step this exists to remove.
    wire declicking = aud_soft_switch || soft_arm || (declick_win != 17'd0);

    always_ff @(posedge clk) begin
        if (!enable) begin
            audio_l <= '0;
            audio_r <= '0;
        end else if (rst && !aud_soft_switch) begin
            audio_l <= '0;                       // hard cause: instant, as before
            audio_r <= '0;
        end else if (declicking) begin
            // DECLICK_STEP is exactly 1 LSB, so a single hop can never overshoot
            // tgt_l/tgt_r in either direction -- deliberately no saturating
            // "remaining distance > step" guard, which would need tgt-audio
            // computed a bit wider than 16 signed bits to avoid overflowing on
            // the largest possible gap (up to 65535, e.g. tgt=+32767 just after
            // audio snapped toward -32768). If DECLICK_STEP is ever widened,
            // add that guard back.
            audio_l <= (audio_l < tgt_nl) ? audio_l + DECLICK_STEP
                     : (audio_l > tgt_nl) ? audio_l - DECLICK_STEP
                     : audio_l;
            audio_r <= (audio_r < tgt_nr) ? audio_r + DECLICK_STEP
                     : (audio_r > tgt_nr) ? audio_r - DECLICK_STEP
                     : audio_r;
        end else begin
            audio_l <= tgt_nl;                   // ordinary playback: the original register
            audio_r <= tgt_nr;
        end
    end

    // ---------------------------------------------------------------------
    // Drain-gate controller: PTS-scheduled playback start (see port comment).
    //
    //   ARMED (draining=0): the 48 kHz tick is withheld from the codec output
    //     FIFOs; dispatch/decode fill them. The first PTS-tagged frame dispatched
    //     while armed latches play_pts — the FIFOs were empty at (re-)arm, so its
    //     samples are (approximately) the FIFO head. Worst-case head error is one
    //     in-flight/PTS-less frame (~32-64 ms), eyeball-grade.
    //   START: when STC >= play_pts + av_ofs (signed; av_ofs > 0 delays audio),
    //     release the drain. The head sample then exits when the display timeline
    //     reads its PTS — lip-sync by construction. If audio is LATE (starved),
    //     the condition is already true at latch time and the drain starts
    //     immediately: the gate can only delay EARLY audio, never add lateness.
    //   UNDERRUN: a tick that finds the active FIFO empty (aud_valid missing the
    //     cycle after a delivered tick, after at least one good sample) re-ARMS —
    //     audio re-enters at the correct phase after a starvation gap instead of
    //     wherever data resumed. seen_valid guards the just-started window where
    //     the first decode may still be in flight.
    //   HELD FROM RESET (v3.1): the gate is armed from reset — there is NO
    //     pre-anchor bypass. v3.0 free-ran until the STC anchored, which armed the
    //     gate MID-FLOW with the FIFOs already full: play_pts could then only
    //     latch from a NEW dispatch, dispatch was stalled on the full FIFOs, and
    //     the FIFOs could only drain if released — a deadlock (HW: Matrix played
    //     a split second of pre-anchor audio then went silent forever, and the
    //     stalled ring backpressured the shared stream for the ~1.2 s watchdog
    //     window, freezing video ~1 s). Arming from reset guarantees the FIFOs
    //     are EMPTY when the phase reference latches — the transition can't exist.
    //   BYPASS: only sched_en low (O[13] A/V Sync Off) free-runs the drain.
    //
    // Liveness: STC advances every refresh once video is live, so a held start
    // always releases; and a FALLBACK timer (~2.5 s armed-with-data but no
    // scheduled release: no PTS ever, or no video PTS to anchor the STC)
    // free-runs the stretch rather than wedge into silence — the next underrun
    // re-arms and tries the schedule again. The ring drain-watchdog in emu
    // remains the outer guard for a fully-wedged chain.
    // ---------------------------------------------------------------------
    // (drain-gate state registers are declared up at the dispatch FSM, where the
    // stale-skip reads `draining`)
    assign dbg_draining       = draining;
    assign dbg_play_pts_valid = play_pts_valid;
    assign dbg_armed_data     = armed_data;
    assign dbg_skip_run       = skip_run;
    assign dbg_play_pts       = play_pts;

    wire active_avalid = (cur_codec == T_LPCM) ? lpcm_aud_valid : ac3_aud_valid;

    assign dbg_cur_codec  = cur_codec;
    assign dbg_mp2_avalid = mp2_active && lpcm_aud_valid;
    // start when stc - play_pts - av_ofs >= 0 (35-bit signed headroom)
    wire signed [34:0] start_delta =
        $signed({2'b0, stc}) - $signed({2'b0, play_pts}) - 35'($signed(av_ofs));

    // Held from reset; only O[13] A/V Sync Off bypasses (see comment above).
    assign drain_en = draining || !sched_en;

    // ---- step 6: stale-latch re-phase request (one pulse per latch) ----------
    logic resync_sent;
    always_ff @(posedge clk) begin
        if (rst || !sched_en) begin
            resync_req  <= 1'b0;
            resync_sent <= 1'b0;
        end else begin
            resync_req <= 1'b0;
            if (draining || !play_pts_valid) resync_sent <= 1'b0;
            else if (retime && !resync_sent && arr_agree && (start_delta >= RETIME_WIN)) begin
                resync_req  <= 1'b1;
                resync_sent <= 1'b1;
            end
        end
    end

    // ---- Playback-position tracker (drift instrument; see dbg_play_err port) ----
    // Counts the playback position since the last release in whole 90 kHz ticks
    // plus a per-rate fractional accumulator, so the slope is exact at every
    // sample rate: 90000/48000 = 1+7/8, 90000/44100 = 2+2/49, 90000/32000 =
    // 2+13/16 ticks per sample. play_anchor is the PTS the release scheduled
    // the FIFO head for (the head sample exits when STC == play_pts + av_ofs,
    // so err starts ~av_ofs; on a fallback release with no latched PTS,
    // anchor = STC and err starts ~0 — either way the SLOPE is the measurement).
    logic [32:0] play_anchor;
    logic [33:0] pos_ticks;
    logic [5:0]  pos_frac;
    // (96 kHz: 90000/96000 = 0+15/16)
    wire  [1:0]  pos_int = (nco_fs == 2'd1) ? 2'd1 : (nco_fs == 2'd3) ? 2'd0 : 2'd2;
    wire  [5:0]  pos_num = (nco_fs == 2'd0) ? 6'd2  : (nco_fs == 2'd2) ? 6'd13 :
                           (nco_fs == 2'd3) ? 6'd15 : 6'd7;
    wire  [5:0]  pos_den = (nco_fs == 2'd0) ? 6'd49 : (nco_fs == 2'd2) ? 6'd16 :
                           (nco_fs == 2'd3) ? 6'd16 : 6'd8;
    wire  [6:0]  pos_frac_nx = {1'b0, pos_frac} + {1'b0, pos_num};
    wire         pos_carry   = (pos_frac_nx >= {1'b0, pos_den});
    wire signed [34:0] play_err_w =
        $signed({2'b0, stc}) - $signed({2'b0, play_anchor}) - $signed({1'b0, pos_ticks});

    always_ff @(posedge clk) begin
        if (rst || !enable) begin
            draining       <= 1'b0;
            play_pts       <= '0;
            play_pts_valid <= 1'b0;
            seen_valid     <= 1'b0;
            ce_play_d      <= 1'b0;
            armed_data     <= 1'b0;
            arm_timer      <= '0;
            dbg_rearm_cnt  <= '0;
            dbg_fbrel_cnt  <= '0;
            play_anchor    <= '0;
            pos_ticks      <= '0;
            pos_frac       <= '0;
            nco_fs         <= 2'd1;    // 48 kHz until an MP2 header says otherwise
            dbg_play_err   <= '0;
            retime         <= 1'b0;
            anc_bwd        <= 1'b0;
        end else begin
            ce_play_d <= aud_ce_play;

            // NCO rate select: MP2's header rate while MP2 is the active codec
            // (44.1/32 kHz VCD/SVCD audio), 96 kHz for a 96 kHz LPCM track on a
            // 96 kHz link, else 48 kHz. Latched ONLY while the
            // drain gate is closed so a swap can never phase-kick mid-playback.
            // CD-DA/WAV overrides unconditionally: cdda_fs is static for the
            // whole mount (no mid-play change exists to phase-kick).
            if (cdda_mode)
                nco_fs <= cdda_fs;
            else if (!draining)
                nco_fs <= mp2_active ? mp2_fs :            // the engine's MFS (the header's)
                          (lpcm_src && lpcm_fs96 && link96 && !lpcm_bad) ? 2'd3 : 2'd1;

            // latch the phase reference: first PTS-tagged dispatch while armed
            if (!draining && !play_pts_valid && dispatch_pts_valid) begin
                play_pts       <= dispatch_pts;
                play_pts_valid <= 1'b1;
                anc_bwd        <= 1'b0;    // a latch is judged against re-anchors AFTER it
            end
            // step 8: remember a backward display re-anchor (a content jump) taken
            // while a latch is pending -- see the ORPHAN release below
            if (anchor_disc) anc_bwd <= 1'b1;

            // an in-band re-time head just entered the re-armed gate (see IN-BAND
            // TIMELINE RE-TIME at the dispatcher): its release must land on its own
            // timeline
            if (disc_dispatch) retime <= 1'b1;

            if (!sched_en) begin
                // O[13] free-run diagnostic: keep the state clear for a clean re-arm
                draining       <= 1'b0;
                play_pts_valid <= 1'b0;
                seen_valid     <= 1'b0;
                armed_data     <= 1'b0;
                arm_timer      <= '0;
                retime         <= 1'b0;
            end else if (!draining && play_pts_valid && anc_bwd && disp_anchored && video_live &&
                         (start_delta < -RETIME_WIN)) begin
                // step 8 -- AN ORPHANED LATCH (HW round 3, ULTIMATE_T2 boot -> menu):
                // the gate latched the old timeline's last audio, and the display
                // then jumped BACKWARD onto a new timeline (a one-picture still cell
                // with no audio, c1). That latch is now far EARLY on the new clock
                // and can never come due; the next discontinuity head then waited
                // behind it for the whole HOLD_W (0.62 s -- measured exactly), was
                // late by then, and took the step-6 reset: menu audio ~0.7 s later
                // than the old build. It is the old timeline's tail -- a few ms of
                // audio that belonged before the jump: release it now, it plays out,
                // underruns, and the gate re-arms cleanly for the next head.
                // Only after a BACKWARD re-anchor that followed the latch: a latch
                // legitimately early by more than RETIME_WIN (a mux lead at start,
                // an authored forward gap) sees no such jump and keeps waiting.
                draining    <= 1'b1;
                seen_valid  <= 1'b0;
                play_anchor <= play_pts;
                pos_ticks   <= '0;
                pos_frac    <= '0;
                retime      <= 1'b0;
                anc_bwd     <= 1'b0;
            end else if (hold_expired) begin
                // a discontinuity head waited HOLD_W without the old tail's
                // underrun closing the gate: re-arm anyway (liveness), so it can
                // dispatch and schedule; arm_timer remains the outer bound
                draining       <= 1'b0;
                play_pts_valid <= 1'b0;
                seen_valid     <= 1'b0;
            end else if (!draining) begin
                if (frame_pop)               armed_data <= 1'b1;
                // Liveness hardening (v5.3): the fallback timer runs whenever ARMED
                // with audio anywhere in the pipe — not only after a frame_pop. A
                // re-arm with full FIFOs has no pops (dispatch stalled mid-frame),
                // which previously kept the fallback dead and could silence audio
                // forever. Any armed state with data now always releases eventually.
                if ((armed_data || frame_valid || (state != S_IDLE)) && ~&arm_timer)
                    arm_timer <= arm_timer + 1'b1;

                if (play_pts_valid && disp_anchored && video_live && (start_delta >= 0) &&
                    (!retime || (start_delta < RETIME_WIN))) begin
                    draining    <= 1'b1;       // scheduled release (the normal path)
                    retime      <= 1'b0;
                    seen_valid  <= 1'b0;
                    play_anchor <= play_pts;
                    pos_ticks   <= '0;
                    pos_frac    <= '0;
                end else if (armed_data && (&arm_timer)) begin
                    draining    <= 1'b1;       // fallback: free-run rather than wedge
                    retime      <= 1'b0;
                    seen_valid  <= 1'b0;
                    play_anchor <= play_pts_valid ? play_pts : stc;
                    pos_ticks   <= '0;
                    pos_frac    <= '0;
                    if (!(&dbg_fbrel_cnt)) dbg_fbrel_cnt <= dbg_fbrel_cnt + 1'b1;
                end
            end else begin
                armed_data <= 1'b0;
                arm_timer  <= '0;
                // ⛔ DO NOT re-base play_anchor on a clock re-anchor. That was added
                // 2026-09-06 reasoning that a sample-continuous stream across a PTS
                // discontinuity is still in sync -- but play_err IS the lip-sync
                // measurement (clock minus audio playback position), so dragging the
                // anchor along with every re-anchor forces it toward zero and makes it
                // STRUCTURALLY UNABLE to show an accumulated error. MEASURED: play_err
                // read -98 ms while the user heard audio 1.6 s ahead. The instrument
                // must be able to report the thing it exists to report.
                // playback-position tracker: advance the rate-exact ticks/sample
                // (integer + fraction) per play tick and publish the error while
                // playing (held across armed gaps)
                if (aud_ce_play) begin
                    pos_ticks <= pos_ticks + {32'd0, pos_int} + {33'd0, pos_carry};
                    pos_frac  <= pos_carry ? (pos_frac_nx[5:0] - pos_den) : pos_frac_nx[5:0];
                end
                dbg_play_err <= play_err_w[19:4];
                // (v5.2's live re-phase on an av_ofs change was REVERTED in v5.3:
                //  re-arming with FULL decode FIFOs deadlocks — play_pts can only
                //  re-latch from a NEW dispatch, dispatch is stalled on the full
                //  FIFOs, and the FIFOs only drain when released; the fallback
                //  never ran because frame_pop couldn't fire (HW: knob change =
                //  permanent silence). The offset now applies at the next
                //  (re)start event: clip load, seek, or an underrun re-arm.)
                if (active_avalid) seen_valid <= 1'b1;
                // underrun: a delivered tick with no sample -> re-arm at phase
                else if (ce_play_d && seen_valid) begin
                    draining       <= 1'b0;
                    play_pts_valid <= 1'b0;
                    seen_valid     <= 1'b0;
                    if (!(&dbg_rearm_cnt)) dbg_rearm_cnt <= dbg_rearm_cnt + 1'b1;
                end
            end
        end
    end

endmodule
