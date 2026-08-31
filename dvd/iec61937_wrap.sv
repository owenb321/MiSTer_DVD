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
    input  wire        sync_armed,     // sync intended (~av_freerun); holds until anchored
    input  wire        stc_anchored,   // av_sync STC has anchored on the video timeline
    input  wire [32:0] stc,            // av_sync video-referenced STC
    input  wire signed [17:0] av_ofs,  // A/V offset (90 kHz ticks, O[23:21])

    // ---- audio domain (clk_audio, 24.576 MHz) ----
    input  wire        clk_audio,
    input  wire        rst_audio_n,
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

    // ---- HDMI IEC958-direct serial output (clk_audio) ----
    // The same burst, clocked out for the ADV7513's I2S input in IEC958-direct
    // mode (reg 0x0C[1:0]=3). sys_top muxes these three onto HDMI_SCLK/LRCLK/I2S
    // while the HPS ack is set; MCLK is unaffected. All three come from HERE
    // rather than from the framework's serializer so the word select and bit
    // clock are phase-consistent with the subframes by construction.
    output wire        hdmi_sck_o,
    output wire        hdmi_ws_o,
    output wire        hdmi_sd_o,
    input  wire [1:0]  hdmi_variant,   // HW A/B, see dvd/i2s_iec958.sv

    // ---- debug taps (producer word stream, clk_sys) ----
    output reg  [15:0] dbg_word,      // word committed this cycle
    output reg         dbg_word_stb
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
        .wr_rst_n (rst_sys_n),
        .wr_en    (wr_en),
        .wr_data  (wr_pair),
        .full     (fifo_full),
        .rd_clk   (clk_audio),
        .rd_rst_n (rst_audio_n),
        .rd_en    (fifo_rd_en),
        .rd_data  (fifo_rd_data),
        .empty    (fifo_empty)
    );

    // =============================================================
    // Producer FSM (clk_sys) — emit the 61937 word stream
    // =============================================================
    localparam [2:0] S_IDLE = 3'd0,
                     S_PA   = 3'd1,
                     S_PB   = 3'd2,
                     S_PC   = 3'd3,
                     S_PD   = 3'd4,
                     S_B0   = 3'd5,  // fetch first byte of a payload word
                     S_B1   = 3'd6,  // fetch second byte, emit payload word
                     S_PAD  = 3'd7;  // emit zero words to fill the period

    reg  [2:0]  st;
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
    assign ring_ready = enable && (st == S_B0 || st == S_B1) && ring_valid && emit_ok;

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

    // The IEC 61937 data-burst REPETITION PERIOD must stay constant for a given
    // codec or the receiver drops lock. Null/hold bursts therefore reuse the
    // ACTIVE codec's period (not a hardcoded AC-3 1536): the front frame's period
    // while one is queued/held, else the last codec's latched period. This fixes
    // the DTS case (a real DTS burst is 512 samples, so a hardcoded-1536 null burst
    // beside it made the Pa/Pb spacing jump 1536<->512 across every hold — a
    // track-switch / re-lock failure).
    reg  [15:0] cur_period;
    wire [15:0] null_period = (frame_valid && is_codec) ? period_sel : cur_period;

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            st          <= S_IDLE;
            words_total <= {PERIOD_AC3, 1'b0};
            widx        <= 17'd0;
            bytes_left  <= 16'd0;
            pd_bits     <= 16'd0;
            pc_val      <= PC_AC3;
            cur_period  <= PERIOD_AC3;
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
        end else begin
            wr_en        <= 1'b0;
            frame_pop_r  <= 1'b0;
            dbg_word_stb <= 1'b0;

            if (!enable) begin
                st   <= S_IDLE;
                half <= 1'b0;
                widx <= 17'd0;
            end else begin
                case (st)
                S_IDLE: begin
                    widx <= 17'd0;
                    half <= 1'b0;
                    // Track the active codec's burst period so null/hold bursts keep
                    // a constant Pa/Pb repetition period (latched even while holding).
                    if (frame_valid && is_codec) cur_period <= period_sel;
                    if (frame_valid && is_codec && !hold_frame && !mute_i) begin
                        // AC-3/DTS frame, due -> wrap it into a real 61937 burst
                        bytes_left  <= frame_len;
                        pc_val      <= (frame_type == 2'd1) ? PC_DTS : PC_AC3;
                        pd_bits     <= {frame_len[12:0], 3'b000}; // frame_len*8 (bits)
                        words_total <= {period_sel, 1'b0};
                        burst_silent<= 1'b0;   // real data-burst
                        cur_nonpcm  <= 1'b1;   // -> set the channel-status non-PCM bit
                        frame_pop_r <= 1'b1;
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
                        st <= S_PA;
                    end else if (frame_valid && !is_codec) begin
                        // LPCM/unknown -> not wrappable: consume + emit PCM silence
                        bytes_left  <= 16'd0;
                        pc_val      <= 16'd0;
                        pd_bits     <= 16'd0;
                        words_total <= {null_period, 1'b0};
                        burst_silent<= 1'b1;
                        cur_nonpcm  <= 1'b0;
                        frame_pop_r <= 1'b1;   // drop it (no backpressure buildup)
                        st <= S_PA;
                    end else begin
                        // No frame ready, OR a codec frame HELD (pre-anchor / not due).
                        // Emit LINEAR-PCM SILENCE (all-zero words, non-PCM bit cleared)
                        // rather than a Pc=0 non-PCM null burst: a real player presents
                        // PCM before the bitstream starts, and HW showed the receiver
                        // fails to acquire across non-PCM null bursts (it re-locks fine
                        // on the single clean PCM->DD/DTS switch). Period-matched so the
                        // producer re-checks S_IDLE on the codec's burst cadence.
                        bytes_left  <= 16'd0;
                        pc_val      <= 16'd0;
                        pd_bits     <= 16'd0;
                        words_total <= {null_period, 1'b0};
                        burst_silent<= 1'b1;
                        cur_nonpcm  <= 1'b0;
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
    always @(posedge clk_audio or negedge rst_audio_n)
        if (!rst_audio_n) ce_cnt <= 2'd0; else ce_cnt <= ce_cnt + 2'd1;
    wire bit_ce = (ce_cnt == 2'd0); // 24.576/4 = 6.144 MHz

    wire        sample_req;
    reg  [32:0] cur_pair;

    assign fifo_rd_en = sample_req && !fifo_empty;
    always @(posedge clk_audio or negedge rst_audio_n)
        if (!rst_audio_n) cur_pair <= 33'd0;       // underflow -> PCM zeros (flag 0)
        else if (sample_req) cur_pair <= fifo_empty ? 33'd0 : fifo_rd_data;

    // HDMI bitstream tap: pure aliases, no added logic. `sample_req` is the same
    // strobe that reloads cur_pair, so bs_stb_o marks the frame boundary of the
    // pair the consumer is about to see.
    assign bs_l_o      = cur_pair[15:0];
    assign bs_r_o      = cur_pair[31:16];
    assign bs_nonpcm_o = cur_pair[32];
    assign bs_stb_o    = sample_req;

    wire [31:0] sub_w;
    wire        sub_load;

    spdif_pass u_spdif (
        .clk_i       (clk_audio),
        .rst_i       (~rst_audio_n),
        .bit_out_en_i(bit_ce),
        .spdif_o     (spdif_o),
        .nonpcm_i    (cur_pair[32]),  // per-pair PCM/non-PCM flag (latched per block)
        .sample_i    (cur_pair[31:0]),
        .sample_req_o(sample_req),
        .sub_w_o     (sub_w),
        .sub_load_o  (sub_load)
    );

    // HDMI leg: the same subframes, serialized for the ADV7513 instead of
    // biphase-encoded. Driven off the SAME load pulse as the S/PDIF encoder, so
    // the two outputs cannot drift apart — there is one subframe source.
    i2s_iec958 u_hdmi_i2s (
        .clk       (clk_audio),
        .rst_n     (rst_audio_n),
        .ce_i      (bit_ce),
        .sub_w_i   (sub_w),
        .sub_load_i(sub_load),
        .variant_i (hdmi_variant),
        .sck_o     (hdmi_sck_o),
        .ws_o      (hdmi_ws_o),
        .sd_o      (hdmi_sd_o)
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
