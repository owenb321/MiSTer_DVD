// -----------------------------------------------------------------
// dvd/iec61937_wrap.sv  —  IEC 61937 bitstream passthrough formatter
// -----------------------------------------------------------------
// Wraps the UNDECODED AC-3 / DTS frames coming out of dvd/audio_ring.sv
// into IEC 61937 data-bursts and biphase-encodes them onto the S/PDIF
// pin, so an external AV receiver decodes the bitstream. This is
// "Path B" in docs/audio.md; the in-fabric decode path (dvd_audio_decode
// → AUDIO_L/R) is the alternative selected by the "Audio Out" toggle.
//
// Data flow:
//   audio_ring (clk_sys, 27 MHz)                      clk_audio (24.576 MHz)
//   ┌───────────────────────────┐   async FIFO   ┌───────────────────────┐
//   │ producer FSM: assemble the │  32-bit {R,L} │ ÷4 → 6.144 MHz CE      │
//   │ 61937 word stream          │──── pairs ───▶│ spdif_pass encoder     │──▶ spdif_o
//   │  Pa,Pb,Pc,Pd,payload,pad   │               │ (non-PCM chan status)  │
//   └───────────────────────────┘               └───────────────────────┘
//
// Self-pacing: one 61937 burst carries exactly one codec frame, zero-
// padded to the codec's burst period expressed in stereo sample pairs
// (AC-3 = 1536, DTS = frame sample count). The encoder drains one pair
// per 48 kHz sample, so emitting exactly `period` pairs per frame makes
// the average word rate real-time; the async FIFO only smooths CDC
// jitter. On ring underflow the producer emits a NULL burst (Pc=0).
//
// The producer emits a stream of 16-bit WORDS; the burst is:
//   word 0 = Pa, 1 = Pb, 2 = Pc, 3 = Pd, 4.. = payload, rest = 0,
//   total = period*2 words (2 words per stereo pair). Words are packed
//   two-per-pair (low word = first transmitted = the LEFT subframe).
//
// Byte order (payload byte→16-bit word packing) is the classic
// "passthrough plays static" gotcha, so `byte_swap` is a live input
// (wired to a menu bit) to flip it on hardware without a rebuild.
// See docs/iec61937.md.
// -----------------------------------------------------------------

module iec61937_wrap #(
    parameter int FIFO_AW = 8   // async pair-FIFO depth = 2**FIFO_AW
) (
    // ---- ring domain (clk_sys) ----
    input  wire        clk_sys,
    input  wire        rst_sys_n,
    // SESSION-scope reset: core reset or a MOUNT, and nothing else. rst_sys_n is
    // aud_rst_n, which pulses on every seek, jump and audio-track switch — far too
    // often to hold "a codec stream is running" across, and that is exactly the
    // defect docs/iec61937.md:243-251 retracts: the old burst_seen latch cleared in
    // the two windows the hold FILL exists for, so every fill style degraded to PCM
    // silence there and the A/B that judged them could not have shown a difference.
    input  wire        rst_sess_n,
    input  wire        enable,        // passthrough active (else producer idles)
    input  wire        byte_swap,     // 0: first byte in word[15:8]; 1: swapped
    input  wire        mute_i,        // CSS-scrambled source: consume frames but
                                      // emit PCM silence (scrambled AC-3/DTS sent
                                      // raw = loud noise bursts on the receiver)

    // audio_ring read side (see dvd/audio_ring.sv)
    input  wire [7:0]  ring_byte,
    input  wire        ring_valid,    // committed byte available (out_valid)
    output wire        ring_ready,    // pop a byte (out_ready)
    input  wire        frame_valid,   // a completed frame descriptor is queued
    input  wire [15:0] frame_len,     // its payload length in bytes
    input  wire [1:0]  frame_type,    // 0=AC3 1=DTS 2=LPCM 3=unknown
    input  wire [15:0] frame_samples, // codec frame sample count (burst period);
                                      // 0 => default from frame_type
    input  wire [32:0] frame_pts,     // front frame's PES PTS (90 kHz)
    input  wire        frame_pts_valid,// that PTS is meaningful
    output wire        frame_pop,     // pop the front descriptor

    // ---- A/V sync (reuse av_sync's video STC; same convention as
    // dvd_audio_decode.sv head_delta). When sync is armed, a frame is HELD (null
    // bursts emitted) until the STC anchors AND reaches its PTS, so audio is
    // delayed to the video display timeline instead of free-running at the demux
    // parse front. Holding until the anchor keeps the receiver's first real burst
    // at the start of the sustained stream (no startup real->null->real flap). ----
    input  wire        sync_armed,     // sync intended (~av_freerun = O[13] A/V Sync On); holds until anchored
    input  wire        stc_anchored,   // av_sync STC has anchored on the video timeline
    input  wire [32:0] stc,            // av_sync video-referenced STC
    input  wire signed [17:0] av_ofs,  // A/V offset (90 kHz ticks, O[23:21])

    // ---- audio domain (clk_audio, 24.576 MHz) ----
    input  wire        clk_audio,
    // SESSION-scope reset in the audio domain (emu's clk_audio synchronizer of
    // rst_sess_n). Everything that forms the IEC 60958 CARRIER hangs off this and
    // NOT off rst_audio_n: the CE divider, cur_pair, the pair FIFO and both
    // serializers. rst_audio_n pulses on every seek, jump and audio-track switch,
    // and tearing the encoder down there restarts the biphase stream, re-phases
    // the subframe grid (the measured 509-vs-512 step) and restarts the 192-frame
    // channel-status block -- so the receiver re-acquires. That is a CARRIER
    // discontinuity, and no amount of changing what the burst CONTAINS can fix it;
    // it is why a chapter skip drops receiver lock under every hold_fill arm.
    // docs/iec61937.md "A track switch is a hard wire discontinuity" recorded the
    // mechanism; this input is what stops it being one.
    input  wire        rst_audio_sess_n,
    output wire        spdif_o,

    // ---- HDMI bitstream tap (clk_audio) ----
    // Aliases of the already-CDC'd, already-paced `cur_pair`, exported so the
    // SAME burst can also leave over HDMI (the ADV7513's I2S input) without a
    // second formatter. cur_pair is HELD for a whole 48 kHz frame, so a consumer
    // anywhere on this clock samples it exactly once — see docs/hdmi_bitstream.md
    // "Pacing". NOT a second FIFO reader: the FIFO has one read pointer and two
    // independent readers would diverge.
    //
    // Mute (`mute_i`), A/V-sync holds and PCM-silence are all applied BEFORE the
    // FIFO, so this tap already carries them and needs no gating of its own.
    output wire [15:0] bs_l_o,       // = cur_pair[15:0]  -> IEC 60958 channel A / I2S left
    output wire [15:0] bs_r_o,       // = cur_pair[31:16] -> channel B / I2S right
    output wire        bs_nonpcm_o,  // = cur_pair[32]    -> 1 = 61937 data burst
    output wire        bs_stb_o,     // 48 kHz pair strobe (slip instrument; not needed
                                     // for correctness — see "Pacing")

    // ---- HDMI serial output (clk_audio) ----
    // The same 61937 words as plain 16-bit standard I2S; the ADV7513 supplies the
    // non-PCM channel status from its register map. sys_top muxes these three
    // onto HDMI_SCLK/LRCLK/I2S while the HPS ack is set; MCLK is unaffected.
    // See docs/hdmi_bitstream.md.
    output wire        hdmi_sck_o,
    output wire        hdmi_ws_o,
    output wire        hdmi_sd_o,

    // ---- debug taps (producer word stream, clk_sys) ----
    output reg  [15:0] dbg_word,      // word committed this cycle
    output reg         dbg_word_stb,

    // ---- burst-classification taps (flap probe, clk_sys) ----
    // One pulse per burst START (the S_IDLE decision), with its classification.
    // These feed the emu-side gap/underrun counters (DEBUG_OVERLAY rows 23/24 in
    // Passthru) so the wire's real/silent burst pattern is readable on hardware.
    output reg         dbg_burst_stb,  // pulses when a burst begins
    output reg         dbg_burst_real, // 1 = real 61937 data-burst (Pa/Pb emitted)
    output reg         dbg_burst_held, // silent AND a codec frame was queued but
                                       // HELD (pacing) — else silent = no frame
                                       // queued (ring underrun) or LPCM/mute

    // Level: the front frame is being HELD BY DESIGN (A/V sync hold — pre-anchor
    // or not yet due). Exported so emu's ring drain watchdog can treat the hold
    // as "consumer alive" and keep the STD backpressure engaged: a hold produces
    // no frame_pop, and without this the watchdog reads it as a wedged consumer,
    // reverts the ring to drop-on-full, and the dropped frames punch forward PTS
    // holes into the stream — each hole = a multi-second silence gap on the wire
    // = the measured startup/track-change receiver flap. See docs/iec61937.md
    // "FLAP ROOT CAUSE".
    output wire        hold_active_o
);

    // -------------------------------------------------------------
    // IEC 61937 constants
    // -------------------------------------------------------------
    localparam [15:0] PA = 16'hF872;
    localparam [15:0] PB = 16'h4E1F;
    localparam [15:0] PC_AC3 = 16'h0001; // burst-info data type 1
    localparam [15:0] PC_DTS = 16'h000B; // burst-info data type 11 (DTS I/II/III)

    localparam [15:0] PERIOD_AC3 = 16'd1536; // samples (6144 bytes)
    localparam [15:0] PERIOD_DTS = 16'd512;  // samples (2048 bytes, core DTS)

    // =============================================================
    // Async FIFO (32-bit {high_word, low_word} pairs), clk_sys → clk_audio
    // =============================================================
    // 33-bit FIFO word: [32] = non-PCM flag (1 = 61937 data-burst, 0 = linear-PCM
    // silence), [31:0] = the {high_word, low_word} stereo pair. The flag rides WITH
    // the pair across the CDC so the encoder's channel-status bit stays aligned to
    // the data it describes (real-player behaviour: PCM silence during a hold, then
    // a single clean PCM->non-PCM switch when the bitstream starts).
    reg  [32:0] wr_pair;
    reg         wr_en;
    wire        fifo_full;
    wire        fifo_rd_en, fifo_empty;
    wire [32:0] fifo_rd_data;

    iec_dcfifo32 #(.AW(FIFO_AW), .DW(33)) u_fifo (
        .wr_clk   (clk_sys),
        .wr_rst_n (rst_sess_n),
        .wr_en    (wr_en),
        .wr_data  (wr_pair),
        .full     (fifo_full),
        .rd_clk   (clk_audio),
        .rd_rst_n (rst_audio_sess_n),
        .rd_en    (fifo_rd_en),
        .rd_data  (fifo_rd_data),
        .empty    (fifo_empty)
    );

    // =============================================================
    // Producer FSM (clk_sys) — emit the 61937 word stream
    // =============================================================
    localparam [3:0] S_IDLE = 4'd0,
                     S_PA   = 4'd1,
                     S_PB   = 4'd2,
                     S_PC   = 4'd3,
                     S_PD   = 4'd4,
                     S_B0   = 4'd5,  // fetch first byte of a payload word
                     S_B1   = 4'd6,  // fetch second byte, emit payload word
                     S_PAD  = 4'd7;  // emit zero words to fill the period

    // Draining a non-codec frame's payload needs its own state, NOT the S_B0/S_B1
    // burst path: those consume one byte per emitted word, i.e. one frame per burst
    // period, and LPCM arrives ~3x faster than that — the ring would back up into
    // STD backpressure. S_SKIP runs at clk_sys, so ~2 KB clears in ~74 us against
    // the CDC FIFO's 5.3 ms of slack, and the wire never notices.
    localparam [3:0] S_SKIP = 4'd8;

    reg  [3:0]  st;
    reg  [16:0] words_total;  // period*2
    reg  [16:0] widx;         // words emitted this burst
    reg  [15:0] bytes_left;   // payload bytes remaining
    reg  [15:0] pd_bits;      // Pd value
    reg  [15:0] pc_val;       // Pc value
    reg  [7:0]  b0;           // captured first byte of current word

    reg         half;         // 0: next committed word is the low word
    reg  [15:0] pair_lo;
    reg         frame_pop_r;
    reg         burst_silent; // this burst is a HOLD/underflow -> emit PCM silence
                              // (all-zero words, no Pa/Pb) instead of a null burst
    reg         cur_nonpcm;   // = ~burst_silent; tags every FIFO pair of this burst

    assign frame_pop = frame_pop_r;

    // A pair-completing (odd-index within the pair, half==1) word triggers a
    // FIFO write and needs space; the first word of a pair never writes.
    wire emit_ok = half ? !fifo_full : 1'b1;

    // Pop a ring byte only in the fetch states, when a byte is available and
    // emission can proceed.
    assign ring_ready = enable && ring_valid &&
                        ( ((st == S_B0 || st == S_B1) && emit_ok)
                       || (st == S_SKIP) );   // S_SKIP drains at clk_sys, no emit

    function [15:0] mkword(input [7:0] first, input [7:0] second);
        mkword = byte_swap ? {second, first} : {first, second};
    endfunction

    wire last_word_odd = (bytes_left == 16'd1);

    // Commit one 16-bit word into the pair packer.
    task commit_word(input [15:0] w); begin
        dbg_word     <= w;
        dbg_word_stb <= 1'b1;
        widx         <= widx + 17'd1;
        if (!half) begin
            pair_lo <= w;
            half    <= 1'b1;
        end else begin
            wr_pair <= {cur_nonpcm, w, pair_lo}; // flag + high word (second) + low (first)
            wr_en   <= 1'b1;
            half    <= 1'b0;
        end
    end endtask

    wire [15:0] period_sel = (frame_samples != 16'd0) ? frame_samples :
                             (frame_type == 2'd1) ? PERIOD_DTS : PERIOD_AC3;

    // A/V sync gate (same compare as dvd_audio_decode head_delta): the front
    // frame is DUE once the video STC reaches its PTS + the A/V offset. Until
    // then, hold it (emit a null burst) so passthrough audio tracks the video
    // display timeline. Holding fills the ring -> engages the demux STD
    // backpressure, so the lead is bounded without dropping frames. Frames with
    // no PTS (or sync disabled) are emitted immediately (continuity).
    // Only AC-3 (0) and DTS (1) are IEC 61937 passthrough codecs. LPCM (2) /
    // unknown (3) must NOT be wrapped (they are PCM/undecodable here) — a
    // wrong-mode selection discards them as silence (use Decode mode for LPCM).
    wire is_codec = (frame_type == 2'd0) || (frame_type == 2'd1);

    // Sync is ACTIVE (due-time gating) only once the video STC has anchored. While
    // sync is armed but NOT yet anchored, HOLD every codec frame (null bursts) so
    // the receiver's first real burst is the start of the SUSTAINED post-anchor
    // stream — not a pre-anchor free-run spurt that the anchor's hold then
    // interrupts (the "flashes Dolby Digital then drops at startup, chapter-skip
    // fixes it" symptom: a real->null->real flap breaks the receiver's acquisition).
    // Genlock Off (sync_armed=0) free-runs for continuity.
    wire sync_en = sync_armed && stc_anchored;
    wire signed [34:0] head_delta =
        $signed({2'b0, stc}) - $signed({2'b0, frame_pts}) - 35'($signed(av_ofs));
    wire hold_frame = is_codec &&
        ( (sync_armed && !stc_anchored)                              // wait for the anchor
       || (sync_en && frame_pts_valid && (head_delta < 35'sd0)) );   // anchored but not yet due

    // Deliberate-hold level for the emu drain watchdog (see the port comment).
    // Mute is excluded: muted frames still pop, so they feed the watchdog anyway.
    assign hold_active_o = enable && frame_valid && hold_frame && !mute_i;

    // The IEC 61937 data-burst REPETITION PERIOD must stay constant for a given
    // codec or the receiver drops lock. Null/hold bursts therefore reuse the
    // ACTIVE codec's period (not a hardcoded AC-3 1536): the front frame's period
    // while one is queued/held, else the last codec's latched period. This fixes
    // the DTS case (a real DTS burst is 512 samples, so a hardcoded-1536 null burst
    // beside it made the Pa/Pb spacing jump 1536<->512 across every hold — a
    // track-switch / re-lock failure).
    reg  [15:0] cur_period;
    wire [15:0] null_period = (frame_valid && is_codec) ? period_sel : cur_period;

    // ---- SESSION state (rst_sess_n, NOT rst_sys_n) -------------------------
    // Session-scoped so a track switch inside a DTS title cannot revert the silence
    // quantum to AC-3's 1536: rst_sys_n pulses on every seek, jump and track switch.
    //
    // ⛔ A GAP FILL LIVED HERE AND WAS REMOVED. Keep the reasoning, because the
    // question looks obviously worth solving and is not.
    // The old burst_seen latch cleared on rst_sys_n, so every fill style degraded
    // to PCM silence in exactly the two windows a fill exists for and the A/B that
    // retired two of them was vacuous (docs/iec61937.md:243-251). Re-measured over
    // OPTICAL with the arming fixed (2026-09-09): PCM silence flips the receiver to
    // PCM, and both a non-PCM hold and a compliant IEC 61937 pause burst -- Pd =
    // span AND Pd = 0 -- drop it to "Decoder Off". Only real data bursts hold it,
    // which pointed at canned silent frames ("digital black"), and those are cheap:
    // every silent frame is byte-identical and AC-3 is 1536 samples at ANY bitrate,
    // so ~1.3 KB of ROM covers AC-3 2/0, AC-3 3/2 and DTS with the Pa/Pb grid
    // unchanged.
    // ★ IT WAS STILL NOT BUILT: a PS5 playing a DVD was then measured doing the
    // same thing -- dropping the decoder on a pause and between menus. Leaving DD
    // during a gap is what a shipping player does, so there was nothing to fix.
    // ⚠ Do not re-derive this from docs/iec61937.md's "the only fix would be
    // digital black ... as some real players do": that sentence started this, and
    // it is wrong about real players.
    always @(posedge clk_sys or negedge rst_sess_n) begin
        if (!rst_sess_n)
            cur_period <= PERIOD_AC3;
        else if (enable && st == S_IDLE && frame_valid && is_codec)
            cur_period <= period_sel;   // latched even while HOLDING
    end

    // The producer resets on the SESSION scope too. rst_sys_n is now a synchronous
    // ABORT rather than a reset: restarting the FSM mid-burst leaves a partial
    // burst in the FIFO with the next Pa/Pb immediately behind it, which slips the
    // repetition grid -- the very thing keeping the carrier alive is meant to stop.
    // On a flush the burst is finished with zero padding instead, so the grid is
    // preserved and the cost is ONE corrupt frame (the receiver reads Pd bytes of
    // zeros where the payload was) rather than a re-acquisition.
    always @(posedge clk_sys or negedge rst_sess_n) begin
        if (!rst_sess_n) begin
            st          <= S_IDLE;
            words_total <= {PERIOD_AC3, 1'b0};
            widx        <= 17'd0;
            bytes_left  <= 16'd0;
            pd_bits     <= 16'd0;
            pc_val      <= PC_AC3;
            b0          <= 8'd0;
            half        <= 1'b0;
            pair_lo     <= 16'd0;
            wr_pair     <= 33'd0;
            wr_en       <= 1'b0;
            burst_silent<= 1'b1;
            cur_nonpcm  <= 1'b0;
            frame_pop_r <= 1'b0;
            dbg_word    <= 16'd0;
            dbg_word_stb<= 1'b0;
            dbg_burst_stb <= 1'b0;
            dbg_burst_real<= 1'b0;
            dbg_burst_held<= 1'b0;
        end else begin
            wr_en        <= 1'b0;
            frame_pop_r  <= 1'b0;
            dbg_word_stb <= 1'b0;
            dbg_burst_stb<= 1'b0;

            if (!rst_sys_n) begin
                // FLUSH (seek / jump / mount / audio-track switch). audio_ring is
                // being reset under us, so the payload in flight is gone; abandon
                // it but keep this burst's framing.
                bytes_left <= 16'd0;
                if (st == S_SKIP)                    st <= S_PA;   // nothing emitted yet
                else if (st == S_B0 || st == S_B1)   st <= S_PAD;  // pad out the burst
            end else if (!enable) begin
                st   <= S_IDLE;
                half <= 1'b0;
                widx <= 17'd0;
            end else begin
                case (st)
                S_IDLE: begin
                    widx <= 17'd0;
                    half <= 1'b0;
                    // cur_period / sess_* are latched in the session block above.
                    if (frame_valid && is_codec && !hold_frame && !mute_i) begin
                        // AC-3/DTS frame, due -> wrap it into a real 61937 burst
                        bytes_left  <= frame_len;
                        pc_val      <= (frame_type == 2'd1) ? PC_DTS : PC_AC3;
                        pd_bits     <= {frame_len[12:0], 3'b000}; // frame_len*8 (bits)
                        words_total <= {period_sel, 1'b0};
                        burst_silent<= 1'b0;   // real data-burst
                        cur_nonpcm  <= 1'b1;   // -> set the channel-status non-PCM bit
                        frame_pop_r <= 1'b1;
                        dbg_burst_stb <= 1'b1; dbg_burst_real <= 1'b1; dbg_burst_held <= 1'b0;
                        st <= S_PA;
                    end else if (frame_valid && is_codec && mute_i) begin
                        // MUTED codec frame (CSS-scrambled source): drain its
                        // payload bytes from the ring at the normal burst cadence
                        // (keeps rd_ptr in step with the descriptors and the ring
                        // fill behaving exactly like normal playback) but commit
                        // ALL-ZERO words — the receiver hears clean PCM silence
                        // instead of raw scrambled AC-3/DTS (loud noise bursts).
                        // Skips the sync hold too: silence either way, and popping
                        // keeps the STD backpressure from wedging the shared demux.
                        bytes_left  <= frame_len;
                        pc_val      <= 16'd0;
                        pd_bits     <= 16'd0;
                        words_total <= {period_sel, 1'b0};
                        burst_silent<= 1'b1;
                        cur_nonpcm  <= 1'b0;
                        frame_pop_r <= 1'b1;
                        dbg_burst_stb <= 1'b1; dbg_burst_real <= 1'b0; dbg_burst_held <= 1'b0;
                        st <= S_PA;
                    end else if (frame_valid && !is_codec) begin
                        // LPCM/unknown -> not wrappable here. Pop the descriptor AND
                        // drain its payload: the byte ring and the descriptor ring
                        // have independent pointers (audio_ring.sv advances rd_ptr
                        // only on out_ready, :339), so popping alone leaves rd_ptr
                        // frame_len bytes behind — PERMANENTLY, since nothing ever
                        // resyncs them. Every later burst then wraps a shifted byte
                        // window. The drain runs in S_SKIP, not the S_B0/S_B1 path
                        // the mute branch uses, because that consumes one byte per
                        // emitted word and LPCM arrives ~3x faster than that.
                        bytes_left  <= frame_len;
                        pc_val      <= 16'd0;
                        pd_bits     <= 16'd0;
                        words_total <= {null_period, 1'b0};
                        burst_silent<= 1'b1;
                        cur_nonpcm  <= 1'b0;
                        frame_pop_r <= 1'b1;   // drop it (no backpressure buildup)
                        dbg_burst_stb <= 1'b1; dbg_burst_real <= 1'b0; dbg_burst_held <= 1'b0;
                        st <= (frame_len == 16'd0) ? S_PA : S_SKIP;
                    end else begin
                        // No frame ready, OR a codec frame HELD (pre-anchor / not due).
                        // BEFORE the first real burst (sess_armed = 0) this is always
                        // LINEAR-PCM SILENCE — the fj#110 round-2 fix: a real player
                        // presents PCM before the bitstream starts, and HW showed the
                        // receiver cannot ACQUIRE across non-PCM silence. AFTER the
                        // stream is running the problem inverts: dropping back to PCM
                        // makes the receiver re-negotiate the format on every gap, so
                        // hold_fill can keep the format steady instead.
                        bytes_left  <= 16'd0;
                        words_total <= {null_period, 1'b0};
                        pd_bits     <= 16'd0;
                        pc_val      <= 16'd0;
                        burst_silent<= 1'b1;
                        cur_nonpcm  <= 1'b0;
                        // Classify: a queued codec frame reaching here is HELD
                        // (pacing); no frame queued = ring underrun / priming.
                        dbg_burst_stb  <= 1'b1;
                        dbg_burst_real <= 1'b0;
                        dbg_burst_held <= frame_valid && is_codec && !mute_i;
                        st <= S_PA;
                    end
                end

                // PCM-silence bursts emit all zeros (no Pa/Pb) so the receiver sees
                // clean linear-PCM silence; real bursts emit the 61937 preamble.
                S_PA: if (emit_ok) begin commit_word(burst_silent ? 16'd0 : PA); st <= S_PB; end
                S_PB: if (emit_ok) begin commit_word(burst_silent ? 16'd0 : PB); st <= S_PC; end
                S_PC: if (emit_ok) begin commit_word(pc_val); st <= S_PD; end
                S_PD: if (emit_ok) begin
                    commit_word(pd_bits);
                    st <= (bytes_left == 16'd0) ? S_PAD : S_B0;
                end

                // payload word: first byte
                S_B0: if (ring_valid && emit_ok) begin
                    b0         <= ring_byte;
                    bytes_left <= bytes_left - 16'd1;
                    if (last_word_odd) begin
                        // burst_silent (mute): drain the ring byte, commit zero
                        commit_word(burst_silent ? 16'd0 : mkword(ring_byte, 8'd0)); // odd tail
                        st <= S_PAD;
                    end else begin
                        st <= S_B1;
                    end
                end

                // payload word: second byte, emit the word
                S_B1: if (ring_valid && emit_ok) begin
                    commit_word(burst_silent ? 16'd0 : mkword(b0, ring_byte));
                    bytes_left <= bytes_left - 16'd1;
                    st <= (bytes_left == 16'd1) ? S_PAD : S_B0;
                end

                // Drain a non-codec frame's payload at clk_sys, emitting nothing.
                // Nothing is committed here, so the CDC FIFO free-wheels; at 27 MHz a
                // 2 KB LPCM PES clears in ~74 us against ~5.3 ms of FIFO, so the
                // 48 kHz drain side never sees the pause.
                S_SKIP: if (ring_valid) begin
                    bytes_left <= bytes_left - 16'd1;
                    if (bytes_left == 16'd1) st <= S_PA;  // then emit the silent burst
                end

                // zero-pad to fill the burst period
                S_PAD: if (emit_ok) begin
                    commit_word(16'd0);
                    if (widx + 17'd1 >= words_total)
                        st <= S_IDLE;
                end

                default: st <= S_IDLE;
                endcase
            end
        end
    end

    // =============================================================
    // Consumer (clk_audio) — 6.144 MHz CE + spdif_pass encoder
    // =============================================================
    reg [1:0] ce_cnt;
    always @(posedge clk_audio or negedge rst_audio_sess_n)
        if (!rst_audio_sess_n) ce_cnt <= 2'd0; else ce_cnt <= ce_cnt + 2'd1;
    wire bit_ce = (ce_cnt == 2'd0); // 24.576/4 = 6.144 MHz

    wire        sample_req;
    reg  [32:0] cur_pair;

    assign fifo_rd_en = sample_req && !fifo_empty;
    always @(posedge clk_audio or negedge rst_audio_sess_n)
        if (!rst_audio_sess_n) cur_pair <= 33'd0;  // underflow -> PCM zeros (flag 0)
        else if (sample_req) cur_pair <= fifo_empty ? 33'd0 : fifo_rd_data;

    // HDMI bitstream tap: pure aliases, no added logic. `sample_req` is the same
    // strobe that reloads cur_pair, so bs_stb_o marks the frame boundary of the
    // pair the consumer is about to see.
    assign bs_l_o      = cur_pair[15:0];
    assign bs_r_o      = cur_pair[31:16];
    assign bs_nonpcm_o = cur_pair[32];
    assign bs_stb_o    = sample_req;

    spdif_pass u_spdif (
        .clk_i       (clk_audio),
        .rst_i       (~rst_audio_sess_n),
        .bit_out_en_i(bit_ce),
        .spdif_o     (spdif_o),
        .nonpcm_i    (cur_pair[32]),  // per-pair PCM/non-PCM flag (latched per block)
        .sample_i    (cur_pair[31:0]),
        .sample_req_o(sample_req)
    );

    // HDMI leg: the same 61937 words, as plain 16-bit I2S for the ADV7513.
    // One word source feeds both outputs, so they cannot drift apart.
    hdmi_bs_i2s u_hdmi_i2s (
        .clk    (clk_audio),
        .rst_n  (rst_audio_sess_n),
        .ce_i   (bit_ce),
        .pcm_l_i(cur_pair[15:0]),
        .pcm_r_i(cur_pair[31:16]),
        .sck_o  (hdmi_sck_o),
        .ws_o   (hdmi_ws_o),
        .sd_o   (hdmi_sd_o)
    );

endmodule


// =================================================================
// Simple gray-code dual-clock FIFO (DW-bit, default 32), FWFT read.
// =================================================================
module iec_dcfifo32 #(
    parameter int AW = 8,
    parameter int DW = 32
) (
    input  wire          wr_clk,
    input  wire          wr_rst_n,
    input  wire          wr_en,
    input  wire [DW-1:0] wr_data,
    output reg           full,

    input  wire          rd_clk,
    input  wire          rd_rst_n,
    input  wire          rd_en,
    output wire [DW-1:0] rd_data,
    output reg           empty
);
    localparam DEPTH = (1 << AW);

    reg [DW-1:0] mem [0:DEPTH-1];

    // binary + gray pointers
    reg [AW:0] wr_bin, wr_gray;
    reg [AW:0] rd_bin, rd_gray;
    reg [AW:0] wr_gray_s1, wr_gray_s2; // synced into rd domain
    reg [AW:0] rd_gray_s1, rd_gray_s2; // synced into wr domain

    function [AW:0] bin2gray(input [AW:0] b); bin2gray = b ^ (b >> 1); endfunction

    // ---- write side (registered `full` — breaks the full→ptr→gray→full
    // combinational cycle; standard Cummings async FIFO) ----
    wire [AW:0] wr_bin_nxt  = wr_bin + {{AW{1'b0}}, (wr_en && !full)};
    wire [AW:0] wr_gray_nxt = bin2gray(wr_bin_nxt);
    wire full_nxt = (wr_gray_nxt == {~rd_gray_s2[AW:AW-1], rd_gray_s2[AW-2:0]});

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin <= 0; wr_gray <= 0; full <= 1'b0;
        end else begin
            if (wr_en && !full) mem[wr_bin[AW-1:0]] <= wr_data;
            wr_bin  <= wr_bin_nxt;
            wr_gray <= wr_gray_nxt;
            full    <= full_nxt;
        end
    end

    // ---- read side (FWFT, registered `empty`) ----
    wire [AW:0] rd_bin_nxt  = rd_bin + {{AW{1'b0}}, (rd_en && !empty)};
    wire [AW:0] rd_gray_nxt = bin2gray(rd_bin_nxt);
    wire empty_nxt = (rd_gray_nxt == wr_gray_s2);
    assign rd_data = mem[rd_bin[AW-1:0]];

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin <= 0; rd_gray <= 0; empty <= 1'b1;
        end else begin
            rd_bin  <= rd_bin_nxt;
            rd_gray <= rd_gray_nxt;
            empty   <= empty_nxt;
        end
    end

    // ---- pointer synchronizers ----
    always @(posedge rd_clk or negedge rd_rst_n)
        if (!rd_rst_n) begin wr_gray_s1 <= 0; wr_gray_s2 <= 0; end
        else          begin wr_gray_s1 <= wr_gray; wr_gray_s2 <= wr_gray_s1; end

    always @(posedge wr_clk or negedge wr_rst_n)
        if (!wr_rst_n) begin rd_gray_s1 <= 0; rd_gray_s2 <= 0; end
        else          begin rd_gray_s1 <= rd_gray; rd_gray_s2 <= rd_gray_s1; end

endmodule
