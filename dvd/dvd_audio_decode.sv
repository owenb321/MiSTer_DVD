//============================================================================
//  dvd_audio_decode.sv — in-fabric DVD audio: AC-3 + LPCM -> s16 L/R.
//
//  Replaces the old DDR3-ring + HPS-daemon audio path.  Drains the audio_ring
//  read side (committed byte stream + {len,type} frame descriptors), dispatches
//  each frame by codec, decodes it in fabric, and presents stereo s16 PCM at
//  ~48 kHz for emu.sv to drive onto AUDIO_L/AUDIO_R.
//
//    frame_type (from ps_demux / audio_ring): 0=AC-3  1=DTS  2=LPCM  3=unknown
//      AC-3   -> ac3_front (decode + 5.1->stereo downmix) -> pcm_out (Q8.23->s16)
//      LPCM   -> lpcm_unpack (BE->LE 16-bit, L/R interleave)
//      DTS    -> discarded (no fabric DTS decoder yet; future: IEC 61937 to the
//                Digital I/O board). unknown -> discarded.
//
//  Everything runs in clk_sys (~27 MHz) — the same domain as ps_demux/audio_ring.
//  The AC-3 core has ~3000x real-time headroom at this clock, and pcm_out's async
//  output FIFO is run with aud_clk = clk so its CDC degenerates harmlessly.
//
//  PACING / A-V SYNC: pcm_out drains one pair per aud_ce (a 48 kHz fractional NCO
//  off clk).  When its FIFO backs up, pcm_out stalls -> ac3_front.pcm_done is
//  delayed -> the input FIFO fills -> the dispatch holds out_ready low.  audio_ring
//  then asserts almost_full and emu.sv stalls the DEMUX stream (STD-model flow
//  control, watchdog-guarded; drop-on-full remains the fallback) — see the FLOW
//  CONTROL note in dvd/audio_ring.sv.
//
//  The 48 kHz NCO is GENLOCKED to the video-referenced STC by dvd/av_sync.sv: the
//  signed `nco_trim` input slews the increment (±0.5%) so the dispatched audio PTS
//  tracks the video presentation clock (PTS-driven A/V sync).  We also emit
//  `dispatch_pts` (the PTS of each frame as it enters the decoder) for av_sync's
//  loop.  Free-running fallback: with av_sync disabled, nco_trim=0 and this reverts
//  to the prior fixed-rate behaviour.
//============================================================================

`timescale 1ns/1ps

module dvd_audio_decode #(
    parameter int CLK_HZ = 27000000,
    parameter int AUD_HZ = 48000,
    // Drain-gate fallback release timer width: 2^W / CLK_HZ seconds of ARMED with
    // data but no scheduled release before free-running anyway (liveness guard for
    // streams that never yield a usable PTS/anchor). 26 -> ~2.5 s. TBs shrink it.
    parameter int ARM_TIMEOUT_W = 26
) (
    input  logic        clk,             // clk_sys
    input  logic        rst_n,
    input  logic        enable,          // O5 "Audio" toggle (default On)
    input  logic        pause,           // gamepad transport: freeze audio (hold, silence)

    // audio_ring read side (FWFT committed byte stream + descriptor FIFO)
    input  logic [7:0]  ring_byte,
    input  logic        ring_valid,
    output logic        ring_ready,
    input  logic        frame_valid,
    input  logic [15:0] frame_len,
    input  logic [1:0]  frame_type,
    input  logic [1:0]  lpcm_quant,       // LPCM word length (ps_demux): 0=16,1=20,2=24-bit
    input  logic [32:0] frame_pts,        // PES PTS of the queued frame
    input  logic        frame_pts_valid,  // that PTS is meaningful
    output logic        frame_pop,

    // A/V sync (dvd/av_sync.sv): signed trim added to the 48 kHz NCO increment to
    // genlock audio to the video-referenced STC; PTS of each dispatched frame out.
    input  logic signed [21:0] nco_trim,
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
    // Bypassed only when sched_en is low (O13 Audio Genlock Off). Held from reset
    // otherwise (v3.1 — see the drain-gate controller comment); a stream that never
    // yields a schedulable reference free-runs via the ~2.5 s fallback timer.
    input  logic        sched_en,
    input  logic        stc_anchored,
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
    output logic        dbg_mp2_pcm_nz
);

    localparam logic [1:0] T_AC3 = 2'd0, T_DTS = 2'd1, T_LPCM = 2'd2, T_MP2 = 2'd3;

    wire rst = ~rst_n;

    // ---------------------------------------------------------------------
    // 48 kHz sample tick — fractional NCO so the average rate is exact even
    // though CLK_HZ/AUD_HZ (27e6/48e3 = 562.5) isn't an integer.
    //   acc += INC each clk; aud_ce on overflow.  INC = AUD_HZ/CLK_HZ * 2^32.
    // ---------------------------------------------------------------------
    localparam logic [63:0] NCO_INC64 = (64'(AUD_HZ) << 32) / CLK_HZ;
    localparam logic [31:0] NCO_INC   = NCO_INC64[31:0];
    // Effective increment = nominal + av_sync trim (signed, ±0.5% so always > 0).
    // av_sync genlocks the audio sample rate to the video-referenced STC.
    wire signed [33:0] nco_inc_s   = $signed({2'b00, NCO_INC}) + $signed(nco_trim);
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
    wire head_catchup = sched_en && draining && stc_anchored && video_live && arr_current &&
                        ( frame_pts_valid
                            ? (head_delta > (skip_run ? STALE_TICKS : CATCHUP_TICKS))
                            : skip_run );
    wire head_discard = head_stale || head_catchup;

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

    // codec sink readiness for the byte currently offered
    logic        ac3_full;
    logic        lpcm_full;
    logic        mp2_full;
    wire         sink_ready = discard_cur         ? 1'b1 :   // stale: null sink
                              (cur_type == T_AC3)  ? ~ac3_full  :
                              (cur_type == T_LPCM) ? ~lpcm_full :
                              (cur_type == T_MP2)  ? ~mp2_full  :
                              1'b1;                       // DTS: discard

    // consume a byte this cycle?
    wire consume = (state == S_ROUTE) && ring_valid && sink_ready;
    assign ring_ready = consume;                          // pop on consume only

    assign frame_pop = (state == S_POP);                  // 1-cycle descriptor pop

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
        end else begin
            dispatch_pts_valid <= 1'b0;       // 1-cycle pulse
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
                    S_IDLE: if (frame_valid && !pre_anchor_hold) begin
                        bytes_left    <= frame_len;
                        cur_type      <= frame_type;
                        cur_pts       <= frame_pts;        // latch with the descriptor
                        cur_pts_valid <= frame_pts_valid;
                        discard_cur   <= head_discard;     // stale-skip / catch-up decision at pop
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
            if (cur_type != T_DTS) cur_codec <= cur_type;
            // DTS/discarded: keep the previous playable codec selected
        end
    end

    // ---------------------------------------------------------------------
    // AC-3 decoder: ac3_front (decode + downmix) feeding pcm_out (Q8.23->s16).
    // ---------------------------------------------------------------------
    // Feed ac3_front from the dispatch FSM when the current frame is AC-3.
    wire        ac3_wr   = consume && (cur_type == T_AC3) && !discard_cur;
    wire [7:0]  ac3_data = ring_byte;

    // ac3_front <-> pcm_out block handshake
    wire        imdct_done, pcm_done_w;
    wire [8:0]  pcm_rd_addr9;             // {ch, idx[7:0]} from pcm_out
    wire signed [31:0] pcm_rd_data;
    wire signed [15:0] ac3_l, ac3_r;
    wire        ac3_aud_valid;

    // ---------------------------------------------------------------------
    // AC-3 self-heal. err_unsupported is STICKY and halts ac3_front (P_HALT) —
    // a single frame the decoder rejects would otherwise silence AC-3 for the
    // rest of the disc. Also watchdog a decode stall (no imdct_done for ~0.6 s
    // while AC-3 is the active codec). On either, pulse a local reset so the
    // front-end re-syncs on the next 0x0B77 syncframe (brief glitch, then audio
    // resumes) instead of dying. rsthold gives a clean multi-cycle reset and a
    // one-shot (it won't re-fire until the condition recurs after recovery).
    // ---------------------------------------------------------------------
    wire        ac3_core_rst;
    logic [4:0]  ac3_rsthold;
    logic [23:0] ac3_wdog;                 // 2^24/27e6 ~= 0.62 s
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
            if (imdct_done || (cur_codec != T_AC3) || !drain_en) ac3_wdog <= '0;
            else                           ac3_wdog <= ac3_wdog + 1'b1;
            // input-activity tracker: cleared on decode progress, set when a byte is fed
            if (imdct_done || (cur_codec != T_AC3)) ac3_fed_since_prog <= 1'b0;
            else if (ac3_wr)               ac3_fed_since_prog <= 1'b1;
            // start a reset pulse on a fresh error, or a stall timeout WHILE FED
            if (ac3_rsthold != 0)
                ac3_rsthold <= ac3_rsthold - 1'b1;
            else if (ac3_err || ac3_stall_rst)
                ac3_rsthold <= 5'd31;
        end
    end
    assign ac3_core_rst = rst | (ac3_rsthold != 0);

    // Debug: count self-heal reset pulses (rising edges), split by cause so HW can
    // tell ERR-caused resets (a real bitstream the decoder rejects) from stall-wdog
    // resets. (The old dbg_ac3_underruns counter was bogus: it gated on aud_ce &&
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
            if ((ac3_rsthold != 0) && !ac3_rst_d) begin
                dbg_ac3_resets <= dbg_ac3_resets + 1'b1;              // total
                if (ac3_err) dbg_ac3_err_resets <= dbg_ac3_err_resets + 1'b1; // ERR-caused
            end
        end
    end

    ac3_front #(.FIFO_DEPTH(4096)) ac3_front_inst (
        .clk             (clk),
        .rst             (ac3_core_rst),
        .wr_en           (ac3_wr),
        .wr_data         (ac3_data),
        .full            (ac3_full),

        .synced          (ac3_synced),
        .frame_hdr_valid (),
        .frame_words     (),
        .frame_bytes     (),
        .fscod           (),
        .frmsizcod       (),
        .crc1            (),
        .sync_bitpos     (),

        .bsi_valid       (),
        .bsid            (),
        .bsmod           (),
        .acmod           (),
        .dsurmod         (),
        .cmixlev         (),
        .surmixlev       (),
        .lfeon           (),
        .dialnorm        (),

        .block_side_valid(),
        .blk_bits        (),

        .chincpl         (),
        .cplstrtmant     (),
        .cplendmant      (),
        .ncplbnd         (),
        .cplstrtbnd      (),
        .phsflginu       (),
        .rematflg        (),
        .cplco_rd_addr   (8'd0),
        .cplco_rd_data   (),

        .exp_done        (),
        .dexp_rd_addr    (11'd0),
        .dexp_rd_data    (),

        .ba_done         (),
        .bap_rd_addr     (11'd0),
        .bap_rd_data     (),

        .mant_done       (),
        .coeff_rd_addr   (11'd0),
        .coeff_rd_data   (),

        // PCM read port — pcm_out walks ch 0/1; zero-extend its 9-bit addr to the
        // 11-bit {ch[2:0],idx[7:0]} ac3_front expects (only ch 0/1 are read).
        .imdct_done      (imdct_done),
        .pcm_rd_addr     ({2'b00, pcm_rd_addr9}),
        .pcm_rd_data     (pcm_rd_data),

        .pcm_done        (pcm_done_w),
        .err_unsupported (ac3_err)
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
        .pcm_rd_addr (pcm_rd_addr9),
        .pcm_rd_data (pcm_rd_data),
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
    wire        lpcm_wr   = consume && (cur_type == T_LPCM) && !discard_cur;
    wire signed [15:0] lpcm_l, lpcm_r;
    wire        lpcm_aud_valid;

    // FIFO_AW=12 -> 4096 sample-pairs (~85 ms) of elastic buffering so bursty
    // demux delivery (governor releases ~1 frame of audio then holds) doesn't
    // underrun the steady 48 kHz output.
    lpcm_unpack #(.FIFO_AW(12)) lpcm_unpack_inst (
        .clk      (clk),
        .rst      (rst),
        .quant    (lpcm_quant),
        .wr_en    (lpcm_wr),
        .wr_data  (ring_byte),
        .full     (lpcm_full),
        .aud_ce   (aud_ce_play),
        .audio_l  (lpcm_l),
        .audio_r  (lpcm_r),
        .aud_valid(lpcm_aud_valid)
    );

    // ---------------------------------------------------------------------
    // MP2 (MPEG-1 Layer II) decoder — the DVD-spec "MPEG audio" format
    // (stream_id 0xC0+n, T_MP2 = 2'd3). Bit-exact vs tools/mp2_ref.py; see
    // dvd/mp2/mp2_decode.sv. Internal ~85 ms PCM FIFO (PCM_AW=12), same
    // elastic-buffer sizing rationale as lpcm_unpack.
    // ---------------------------------------------------------------------
    wire        mp2_wr = consume && (cur_type == T_MP2) && !discard_cur;
    wire signed [15:0] mp2_l, mp2_r;
    wire        mp2_aud_valid;
    wire        mp2_err;

    // MP2 self-heal, mirroring the AC-3 pattern above: sticky err_unsupported
    // (free-format / corrupt header after sync) or a fed-but-stuck stall pulses
    // a local reset so the decoder re-syncs; starvation (no bytes) never resets
    // (the pop lesson). Progress signal = mp2_aud_valid (a popped pair proves
    // the whole decode path is moving); held clear while the drain gate blocks
    // output, exactly like the AC-3 watchdog.
    wire        mp2_core_rst;
    logic [4:0]  mp2_rsthold;
    logic [23:0] mp2_wdog;
    logic        mp2_fed_since_prog;
    wire         mp2_stall_rst = (&mp2_wdog) && mp2_fed_since_prog;
    always_ff @(posedge clk) begin
        if (rst) begin
            mp2_rsthold        <= '0;
            mp2_wdog           <= '0;
            mp2_fed_since_prog <= 1'b0;
        end else begin
            if (mp2_aud_valid || (cur_codec != T_MP2) || !drain_en) mp2_wdog <= '0;
            else                                                    mp2_wdog <= mp2_wdog + 1'b1;
            if (mp2_aud_valid || (cur_codec != T_MP2)) mp2_fed_since_prog <= 1'b0;
            else if (mp2_wr)                           mp2_fed_since_prog <= 1'b1;
            if (mp2_rsthold != 0)
                mp2_rsthold <= mp2_rsthold - 1'b1;
            else if (mp2_err || mp2_stall_rst)
                mp2_rsthold <= 5'd31;
        end
    end
    assign mp2_core_rst = rst | (mp2_rsthold != 0);

    mp2_decode #(.PCM_AW(12)) mp2_decode_inst (
        .clk            (clk),
        .rst            (mp2_core_rst),
        .wr_en          (mp2_wr),
        .wr_data        (ring_byte),
        .full           (mp2_full),
        .aud_ce         (aud_ce_play),
        .audio_l        (mp2_l),
        .audio_r        (mp2_r),
        .aud_valid      (mp2_aud_valid),
        .synced         (),
        .err_unsupported(mp2_err),
        .dbg_s_nz       (dbg_mp2_s_nz),
        .dbg_pcm_nz     (dbg_mp2_pcm_nz)
    );

    // ---------------------------------------------------------------------
    // Output mux: pick the active codec and latch each new sample. The source's
    // aud_valid pulse (one per aud_ce, asserted the cycle AFTER aud_ce because
    // pcm_out/lpcm_unpack register it) is the correct "new sample" strobe — do
    // NOT additionally gate on aud_ce, or the strobe and aud_ce never align and
    // nothing is ever captured. Between pulses the last sample is held (silence
    // → DC hold), which the framework samples at its own 48 kHz.
    // ---------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst || !enable) begin
            audio_l <= '0;
            audio_r <= '0;
        end else if (cur_codec == T_LPCM) begin
            if (lpcm_aud_valid) begin audio_l <= lpcm_l; audio_r <= lpcm_r; end
        end else if (cur_codec == T_MP2) begin
            if (mp2_aud_valid)  begin audio_l <= mp2_l;  audio_r <= mp2_r;  end
        end else begin
            if (ac3_aud_valid)  begin audio_l <= ac3_l;  audio_r <= ac3_r;  end
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
    //   BYPASS: only sched_en low (O13 Audio Genlock Off) free-runs the drain.
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

    wire active_avalid = (cur_codec == T_LPCM) ? lpcm_aud_valid :
                         (cur_codec == T_MP2)  ? mp2_aud_valid  : ac3_aud_valid;

    assign dbg_cur_codec  = cur_codec;
    assign dbg_mp2_avalid = mp2_aud_valid;
    // start when stc - play_pts - av_ofs >= 0 (35-bit signed headroom)
    wire signed [34:0] start_delta =
        $signed({2'b0, stc}) - $signed({2'b0, play_pts}) - 35'($signed(av_ofs));

    // Held from reset; only O13 Genlock Off bypasses (see comment above).
    assign drain_en = draining || !sched_en;

    // ---- Playback-position tracker (drift instrument; see dbg_play_err port) ----
    // pos_acc8 counts the playback position since the last release in 1/8-tick
    // units: 90000/48000 = 1.875 = 15/8 ticks per sample, so += 15 per play tick.
    // play_anchor is the PTS the release scheduled the FIFO head for (the head
    // sample exits when STC == play_pts + av_ofs, so err starts ~av_ofs; on a
    // fallback release with no latched PTS, anchor = STC and err starts ~0 —
    // either way the SLOPE is the measurement).
    logic [32:0] play_anchor;
    logic [36:0] pos_acc8;
    wire signed [34:0] play_err_w =
        $signed({2'b0, stc}) - $signed({2'b0, play_anchor}) - $signed({1'b0, pos_acc8[36:3]});

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
            pos_acc8       <= '0;
            dbg_play_err   <= '0;
        end else begin
            ce_play_d <= aud_ce_play;

            // latch the phase reference: first PTS-tagged dispatch while armed
            if (!draining && !play_pts_valid && dispatch_pts_valid) begin
                play_pts       <= dispatch_pts;
                play_pts_valid <= 1'b1;
            end

            if (!sched_en) begin
                // O13 free-run diagnostic: keep the state clear for a clean re-arm
                draining       <= 1'b0;
                play_pts_valid <= 1'b0;
                seen_valid     <= 1'b0;
                armed_data     <= 1'b0;
                arm_timer      <= '0;
            end else if (!draining) begin
                if (frame_pop)               armed_data <= 1'b1;
                // Liveness hardening (v5.3): the fallback timer runs whenever ARMED
                // with audio anywhere in the pipe — not only after a frame_pop. A
                // re-arm with full FIFOs has no pops (dispatch stalled mid-frame),
                // which previously kept the fallback dead and could silence audio
                // forever. Any armed state with data now always releases eventually.
                if ((armed_data || frame_valid || (state != S_IDLE)) && ~&arm_timer)
                    arm_timer <= arm_timer + 1'b1;

                if (play_pts_valid && stc_anchored && video_live && (start_delta >= 0)) begin
                    draining    <= 1'b1;       // scheduled release (the normal path)
                    seen_valid  <= 1'b0;
                    play_anchor <= play_pts;
                    pos_acc8    <= '0;
                end else if (armed_data && (&arm_timer)) begin
                    draining    <= 1'b1;       // fallback: free-run rather than wedge
                    seen_valid  <= 1'b0;
                    play_anchor <= play_pts_valid ? play_pts : stc;
                    pos_acc8    <= '0;
                    if (!(&dbg_fbrel_cnt)) dbg_fbrel_cnt <= dbg_fbrel_cnt + 1'b1;
                end
            end else begin
                armed_data <= 1'b0;
                arm_timer  <= '0;
                // playback-position tracker: advance 15/8 ticks per play tick and
                // publish the error while playing (held across armed gaps)
                if (aud_ce_play) pos_acc8 <= pos_acc8 + 37'd15;
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
