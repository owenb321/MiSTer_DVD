// ps_demux.sv — MPEG-2 / MPEG-1 Program (System) Stream Demuxer
// Part of MiSTer DVD Player Core
//
// Parses MPEG-2 Program Stream pack/PES headers from VOB data and routes:
//   - Video PES (stream_id 0xE0) → MPEG-2 decoder input
//   - Audio PES (stream_id 0xBD) → audio ring buffer (AC-3/DTS/LPCM substreams)
//   - MPEG audio PES (stream_id 0xC0-0xC7) → audio ring buffer as MP2 (type 3).
//     No substream_id / sub-header: payload starts after the PES optional
//     header. Track select = stream_id low 3 bits (== aud_track).
//
// MPEG-2 Program Stream packet structure:
//   Pack header:   start code 0x000001BA (14 bytes)
//   PES packets:   start code 0x000001xx
//     stream_id 0xE0 = video
//     stream_id 0xBD = private stream 1 (audio — check substream_id)
//     stream_id 0xBE = padding (skip by length)
//     stream_id 0xBF = private stream 2 / DVD nav packs (skip by length)
//     stream_id 0xB9 = end code
//
// System / nav / padding / un-routed PES streams (any stream_id >= 0xBB that
// isn't pack/video/audio) are skipped *by their declared PES length* rather than
// hunted past. DVD VOBs interleave private_stream_2 (0xBF) NV_PCK navigation
// packs whose PCI/DSI payload can contain 00 00 01 byte patterns; hunting would
// false-trigger a start code and desync the demux, so we consume the whole
// packet explicitly.
//
//   For stream_id 0xBD, substream_id = first byte of PES data:
//     0x80-0x87 = AC-3, 0x88-0x8F = DTS, 0xA0-0xA7 = LPCM
//
// Raw elementary streams (no pack/PES wrapper — a bare .m2v / .mpv that begins
// with a video start code such as 0x000001B3) are auto-detected and passed
// straight through to the video output. If the FIRST start code is a
// video-layer code (<= 0xB8) rather than a 0xBA pack, the demuxer reconstructs
// the 00 00 01 <code> preamble and forwards every subsequent byte unchanged.
// This is what lets bare elementary streams (and ffmpeg `-c copy` .m2v extracts
// of DVD video) play, not just program streams / VOBs.
//
// MPEG-1 SYSTEM STREAMS (VCD): auto-detected per pack from the byte after
// 0xBA — marker nibble 0010 = MPEG-1 (ISO 11172-1), marker bits 01 = MPEG-2.
// An MPEG-1 pack is 12 bytes flat (no stuffing-length byte), and the PES
// optional header is a different shape: 0xFF stuffing* -> optional 2-byte STD
// buffer field (top bits 01) -> 0x2X + PTS(5) | 0x3X + PTS(5)+DTS(5) | one
// no-timestamp byte (spec 0x0F). The `mpeg1_ps` latch (re-set at every pack)
// routes S_PES_LEN_LO into the S_M1_HDR/S_M1_STD group instead of the MPEG-2
// flags/hdr_len triple; the 5-byte PTS bit-packing is IDENTICAL to MPEG-2's,
// so S_PTS is reused as-is (entered with pts_buf[0] preloaded). pes_scrambled
// (a DVD/CSS concept) is never touched on the MPEG-1 path. Golden model:
// tools/mpeg1_ps_ref.py; TB: bench/dvd/ps_demux_m1_tb.sv (real VCD packs).

`default_nettype none

module ps_demux (
    input  wire         clk,
    input  wire         rst_n,

    // Input: byte stream from mpg_streamer.sv
    input  wire  [7:0]  in_byte,
    input  wire         in_valid,
    output logic        in_ready,

    // Audio substream/track select (low 3 bits of substream_id). A DVD can carry
    // SEVERAL audio substreams of the same type (e.g. Matrix: AC-3 0x80 5.1, 0x81
    // & 0x82 stereo). Only the substream whose track number == aud_track is
    // forwarded; the rest are discarded. Without this, all substreams interleave
    // into the one in-fabric decoder and the audio is garbage. Default 0 = 0x80.
    input  wire  [2:0]  aud_track,

    // Subpicture (DVD subtitle) substream select. Subpicture rides in the same
    // private_stream_1 (0xBD) as audio but with substream_id 0x20-0x3F (up to 32
    // streams). Only the substream whose low-3-bit track number == sp_track is
    // forwarded, and only when sp_enable is high; otherwise the PES is discarded
    // (mirrors the aud_track filter). See dvd/spu_decode.sv for the SPU decoder.
    input  wire  [2:0]  sp_track,
    input  wire         sp_enable,

    // Output: video elementary stream → MPEG-2 decoder
    output logic [7:0]  vid_byte,
    output logic        vid_valid,
    input  wire         vid_ready,

    // Output: audio frames → audio_ring.sv
    // aud_type: 0=AC3, 1=DTS, 2=LPCM, 3=MP2 (MPEG-1 Layer II)
    output logic [7:0]  aud_byte,
    output logic        aud_valid,
    output logic [1:0]  aud_type,
    output logic        aud_frame_start,   // pulsed on first byte of a new audio frame
    input  wire         aud_ready,

    // PTS timestamps for A/V sync (33-bit, in 90kHz ticks)
    output logic [32:0] vid_pts,
    output logic        vid_pts_valid,
    output logic [32:0] aud_pts,
    output logic        aud_pts_valid,

    // Per-frame audio PTS for the A/V-sync loop: held value valid coincident with
    // aud_frame_start, so audio_ring can stamp each frame descriptor with the PTS
    // of the PES it came from. aud_frame_pts_valid reflects whether THIS PES
    // actually carried a PTS (some PES packets don't); when low the held PTS is
    // stale and the consumer should treat the frame as PTS-less.
    output logic [32:0] aud_frame_pts,
    output logic        aud_frame_pts_valid,

    // Output: subpicture (subtitle) SPU payload → spu_decode.sv. Raw SPU bytes with
    // NO private_stream_1 sub-header stripped (subpicture has none — the SPU begins
    // at the byte right after the substream_id). sp_frame_start pulses on the first
    // payload byte of each subpicture PES; sp_pts carries that PES's PTS (spu_decode
    // owns SPU-unit boundaries via the SPDSZ length, since one SPU spans several PES
    // and only the first carries a meaningful PTS).
    output logic [7:0]  sp_byte,
    output logic        sp_valid,
    output logic        sp_frame_start,
    output logic [32:0] sp_pts,
    output logic        sp_pts_valid,

    // PCI (NAV pack) output -> dvd/nav_pci.sv (Phase-3 disc-menu buttons).
    // private_stream_2 (0xBF) uses SYSTEM-stream syntax: NO PES optional
    // header - the byte after the 2-byte length is the substream id
    // (0x00 = PCI, 0x01 = DSI). PCI payload bytes (after the substream id)
    // are forwarded accept-always when pci_enable (O[1] Disc Menus) is set;
    // DSI stays discarded. Routed off S_SYS_LEN_LO, never S_PES_HDR_*.
    input  wire         pci_enable,
    output logic [7:0]  pci_byte,
    output logic        pci_valid,
    output logic        pci_frame_start,

    // DSI (NAV pack) output -> dvd/nav_dsi.sv (Phase-7 nav foundation:
    // seek/time/angle). The SECOND private_stream_2 PES (substream 0x01) that
    // shares the nav pack with PCI. Forwarded accept-always when dsi_enable is
    // set (tied on in emu - DSI is needed for the time readout even with menus
    // off, and the nav pack is skip-by-length either way so it's harmless).
    input  wire         dsi_enable,
    output logic [7:0]  dsi_byte,
    output logic        dsi_valid,
    output logic        dsi_frame_start,

    // LPCM format: quantization word-length from the private_stream_1 LPCM
    // sub-header byte +5 (bits[7:6]: 0=16-bit, 1=20-bit, 2=24-bit). Latched each
    // time an LPCM sub-header is parsed; stable per track (a DVD audio track has a
    // single fixed word length). lpcm_unpack uses it to depack 20/24-bit groups
    // (top-16-bit truncation for the 16-bit HDMI path). Held (not a strobe).
    output logic [1:0]  aud_lpcm_quant,

    // CSS detection: one-cycle pulse when a video/audio PES header carries
    // PES_scrambling_control != 0 (bits [5:4] of the first PES-flags byte) — the
    // payload is CSS-scrambled and will decode as garbage (green macroblocks /
    // audio static). emu.sv accumulates these into a sticky per-mount latch
    // (ps_demux itself resets on every jump via pipe_rst_n, so the latch can't
    // live here) that drives the HUD "CSS ENCRYPTED" popup + the audio mute.
    output logic        pes_scrambled
);

// ============================================================================
// State machine
// ============================================================================
typedef enum logic [4:0] {
    S_HUNT,           // searching for 0x000001 start code
    S_STREAM_ID,      // (unused; stream_id dispatch is folded into S_HUNT)
    S_PACK_SKIP,      // skip pack header bytes (after 0xBA), incl. stuffing
    S_PES_LEN_HI,     // PES packet length high byte
    S_PES_LEN_LO,     // PES packet length low byte
    S_PES_HDR_FLAGS1, // PES header flags byte 1
    S_PES_HDR_FLAGS2, // PES header flags byte 2 (contains PTS_DTS_flags)
    S_PES_HDR_LEN,    // PES header data length
    S_PES_HDR_SKIP,   // skip optional PES header fields
    S_PTS,            // read 5-byte PTS field
    S_SUBSTREAM_ID,   // read substream_id (first byte of private stream payload)
    S_AUD_SUBHDR,     // skip private_stream_1 sub-header (after substream_id)
    S_SYS_LEN_HI,     // system/nav/padding PES length high byte (skip-by-length)
    S_SYS_LEN_LO,     // system/nav/padding PES length low byte
    S_VIDEO_DATA,     // forward bytes to video output
    S_AUDIO_DATA,     // forward bytes to audio output
    S_SP_DATA,        // forward bytes to subpicture output (no sub-header)
    S_PS2_SUB,        // private_stream_2 substream id (0x00 PCI / 0x01 DSI)
    S_PCI_DATA,       // forward PCI payload bytes to nav_pci (accept-always)
    S_DSI_DATA,       // forward DSI payload bytes to nav_dsi (accept-always)
    S_DISCARD,        // discard bytes_remaining bytes, then S_HUNT
    S_M1_HDR,         // MPEG-1 PES optional header: stuffing/STD/timestamp dispatch
    S_M1_STD,         // MPEG-1 STD buffer field second byte
    S_ES_EMIT,        // raw ES: emit reconstructed 00 00 01 <code> preamble
    S_ES_PASS,        // raw ES: forward every input byte to video (no demux)
    S_VID_FLUSH       // after a sequence_end_code: emit trailing filler so the
                      //   VLD can flush the still's last slice (see below)
} state_t;

state_t state;

// STILL-FRAME FLUSH: a DVD menu/ad still is an I-frame that ends with a
// sequence_end_code (00 00 01 B7), immediately followed by nav/padding packs
// that this demuxer DROPS. The decoder's VLD then has no bytes past the B7 to
// shift the last slice's start-code terminator through, so the final slice-rows
// never decode (black / gray-box bottom on the ad). When a video PES ends on a
// sequence_end_code, emit a short run of 0x00 filler on the video output so the
// VLD flushes the completed picture. Zeros after B7 form no start code -> benign.
logic [31:0] vid_hist;                    // last 4 forwarded video bytes
localparam [7:0] VID_FLUSH_LEN = 8'd24;   // filler bytes to emit
logic [7:0]  flush_cnt;
wire         seqend_at_pes_end = ({vid_hist[23:0], in_byte} == 32'h000001B7);

// Start code detector — shift register for 0x000001
logic [23:0] start_shift;
logic        start_code_detected;
assign start_code_detected = (start_shift == 24'h000001) && in_valid;

// Byte counters / captured header fields
logic [15:0] pes_length;       // bytes left in current PES packet (after length field)
logic  [7:0] pes_len_hi;       // captured PES length high byte
logic [15:0] bytes_remaining;  // generic countdown (pack/header/sub-header skip)
logic  [7:0] stream_id_r;      // captured stream_id
logic  [7:0] pts_buf [4:0];    // 5-byte PTS buffer (bytes 0..3; byte 4 used directly)
logic  [2:0] pts_byte_count;
logic        pts_present;
logic  [7:0] pes_hdr_len;      // PES header data length (optional-field byte count)
logic [1:0]  aud_type_r;       // 0=AC3, 1=DTS, 2=LPCM, 3=MP2 (MPEG-1 Layer II; was
                               // the never-forwarded "unknown" sentinel — code 3 only
                               // ever reaches the ring with payload for MP2)
logic [1:0]  lpcm_quant_r;     // LPCM word-length (sub-header byte +5 bits[7:6])
logic        first_aud_byte;   // marks first forwarded byte of an audio frame
logic        first_sp_byte;    // marks first forwarded byte of a subpicture PES
logic        first_pci_byte;   // marks first forwarded byte of a PCI packet
logic        first_dsi_byte;   // marks first forwarded byte of a DSI packet
logic        aud_pes_has_pts;  // current PES carried a PTS (set at PES_HDR_FLAGS2)

// Raw elementary-stream passthrough (no PS pack/PES wrapper)
logic  [7:0] es_code;          // saved video start-code byte (e.g. 0xB3 seq header)
logic  [1:0] es_emit_idx;      // index into reconstructed 00 00 01 <code> preamble
logic        ever_seen_pack;   // a 0xBA pack was seen -> stream is PS, lock out ES mode
logic        mpeg1_ps;         // stream flavour, re-latched at every pack marker:
                               // 1 = MPEG-1 system stream (VCD), 0 = MPEG-2 PS (DVD)

// ============================================================================
// Output handshake (1:1 passthrough, no buffering)
//   - in_ready follows the active output's ready in data-forwarding states
//   - a byte is "consumed" only when in_valid && in_ready
// ============================================================================
always_comb begin
    in_ready  = 1'b1;
    vid_valid = 1'b0;
    vid_byte  = in_byte;
    case (state)
        // Forward input bytes to the decoder (PS video payload or raw ES)
        S_VIDEO_DATA,
        S_ES_PASS:    begin in_ready = vid_ready; vid_valid = in_valid; end
        // Emit the reconstructed 00 00 01 <code> preamble that detection consumed.
        // Hold input (in_ready=0); the byte comes from es_emit_idx, not in_byte.
        S_ES_EMIT: begin
            in_ready  = 1'b0;
            vid_valid = 1'b1;
            case (es_emit_idx)
                2'd0:    vid_byte = 8'h00;
                2'd1:    vid_byte = 8'h00;
                2'd2:    vid_byte = 8'h01;
                default: vid_byte = es_code;
            endcase
        end
        // Still-frame flush: emit 0x00 filler to the video decoder (input held).
        S_VID_FLUSH: begin
            in_ready  = 1'b0;
            vid_valid = 1'b1;
            vid_byte  = 8'h00;
        end
        S_AUDIO_DATA: in_ready = aud_ready;
        // Subpicture: spu_decode writes to a BRAM with no backpressure, so accept
        // always (in_ready=1) — never stall the shared stream on subtitle data.
        S_SP_DATA:    in_ready = 1'b1;
        default:      in_ready = 1'b1;
    endcase
end

wire consume = in_valid && in_ready;

// MPEG audio stream_id 0xC0-0xC7 (DVD MP2): payload starts straight after the
// PES optional header (no substream byte / sub-header), so the three header-exit
// branches route it directly to S_AUDIO_DATA instead of S_SUBSTREAM_ID.
wire is_mp2_sid = (stream_id_r[7:3] == 5'b11000);

assign aud_byte        = in_byte;
assign aud_valid       = (state == S_AUDIO_DATA) && in_valid;
assign aud_type        = aud_type_r;
assign aud_lpcm_quant  = lpcm_quant_r;
assign aud_frame_start = (state == S_AUDIO_DATA) && in_valid && first_aud_byte;

// Per-frame PTS: aud_pts is a held register carrying the current PES's audio PTS
// (assembled back in S_PTS, which always precedes this PES's audio payload), so it
// is already correct at aud_frame_start. aud_pes_has_pts says whether this PES had
// one. The FSM is serial per-PES, so these stay valid from PES_HDR_FLAGS2 through
// this PES's frame_start with no other PES intervening.
assign aud_frame_pts       = aud_pts;
assign aud_frame_pts_valid = aud_pes_has_pts;

// Subpicture outputs. sp_pts reuses the aud_pts register: S_PTS assembles the PTS
// into aud_pts for ANY 0xBD PES (it only special-cases stream_id 0xE0 vs "else"),
// so aud_pts is already the correct PTS for a subpicture PES. No second assembler.
assign sp_byte        = in_byte;
assign sp_valid       = (state == S_SP_DATA) && in_valid;
assign sp_frame_start = (state == S_SP_DATA) && in_valid && first_sp_byte;
assign sp_pts         = aud_pts;
assign sp_pts_valid   = aud_pes_has_pts;

// PCI outputs (accept-always sink like the subpicture: nav_pci writes a BRAM
// with no backpressure - never stall the shared stream on nav data).
assign pci_byte        = in_byte;
assign pci_valid       = (state == S_PCI_DATA) && in_valid;
assign pci_frame_start = (state == S_PCI_DATA) && in_valid && first_pci_byte;

// DSI outputs (same accept-always sink -> nav_dsi)
assign dsi_byte        = in_byte;
assign dsi_valid       = (state == S_DSI_DATA) && in_valid;
assign dsi_frame_start = (state == S_DSI_DATA) && in_valid && first_dsi_byte;

// ============================================================================
// Start code shift register (advances only on actual consumption)
// ============================================================================
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        start_shift <= 24'h0;
    else if (consume)
        start_shift <= {start_shift[15:0], in_byte};
end

// ============================================================================
// Main demux FSM
//
// PTS extraction (5 bytes, MPEG-2 PES header):
//   pts[32]    = byte0[3]
//   pts[31:30] = byte0[2:1]
//   pts[29:22] = byte1[7:0]
//   pts[21:15] = byte2[7:1]
//   pts[14:7]  = byte3[7:0]
//   pts[6:0]   = byte4[7:1]
// ============================================================================
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state          <= S_HUNT;
        pes_length     <= 16'd0;
        pes_len_hi     <= 8'd0;
        bytes_remaining<= 16'd0;
        stream_id_r    <= 8'd0;
        pts_byte_count <= 3'd0;
        pts_present    <= 1'b0;
        pes_hdr_len    <= 8'd0;
        aud_type_r     <= 2'd0;
        lpcm_quant_r   <= 2'd0;    // default 16-bit
        first_aud_byte <= 1'b0;
        first_sp_byte  <= 1'b0;
        first_pci_byte <= 1'b0;
        first_dsi_byte <= 1'b0;
        aud_pes_has_pts<= 1'b0;
        es_code        <= 8'd0;
        es_emit_idx    <= 2'd0;
        ever_seen_pack <= 1'b0;
        mpeg1_ps       <= 1'b0;
        vid_hist       <= 32'd0;
        flush_cnt      <= 8'd0;
        vid_pts        <= 33'd0;
        vid_pts_valid  <= 1'b0;
        aud_pts        <= 33'd0;
        aud_pts_valid  <= 1'b0;
        pes_scrambled  <= 1'b0;
    end else begin
        // PTS-valid strobes are one-cycle pulses
        vid_pts_valid <= 1'b0;
        aud_pts_valid <= 1'b0;
        pes_scrambled <= 1'b0;

        // ES preamble emit advances on the OUTPUT handshake (input is held).
        if (state == S_ES_EMIT) begin
            if (vid_ready) begin
                if (es_emit_idx == 2'd3) state       <= S_ES_PASS;
                else                     es_emit_idx <= es_emit_idx + 2'd1;
            end
        // Still-frame flush: emit VID_FLUSH_LEN filler bytes on the output
        // handshake (input held), then resume hunting.
        end else if (state == S_VID_FLUSH) begin
            if (vid_ready) begin
                if (flush_cnt == 8'd1) state <= S_HUNT;
                else                   flush_cnt <= flush_cnt - 8'd1;
            end
        end else if (consume) begin
            case (state)

            // ---- Hunt for 0x000001 start code, then dispatch on stream_id ----
            S_HUNT: begin
                if (start_code_detected) begin
                    stream_id_r <= in_byte;
                    casez (in_byte)
                        8'hBA:   begin ever_seen_pack <= 1'b1; bytes_remaining <= 16'd9; state <= S_PACK_SKIP; end
                        8'hE0:   state <= S_PES_LEN_HI;   // video
                        8'hBD:   state <= S_PES_LEN_HI;   // private stream 1 (audio)
                        // MPEG audio 0xC0-0xC7 (DVD-spec MP2, MPEG-1 Layer II).
                        // Unlike private_stream_1 there is NO substream_id byte and
                        // NO sub-header: the elementary stream starts right after the
                        // PES optional header. Track select = stream_id low 3 bits
                        // (the 0xBD path compares substream_id low 3 bits instead).
                        // A conforming DVD authors audio stream n as EITHER 0xBD
                        // substream 0x80+n/0xA0+n OR stream_id 0xC0+n, never both,
                        // so no cross-codec ambiguity on the shared track number.
                        // Non-selected MP2 tracks fall to the skip-by-length path.
                        8'b1100_0???: begin
                            if (in_byte[2:0] == aud_track) begin
                                aud_type_r <= 2'd3;          // T_MP2 (was the dead "unknown" sentinel)
                                state      <= S_PES_LEN_HI;
                            end else state <= S_SYS_LEN_HI;
                        end
                        default: begin
                            // A video-layer start code (<= 0xB8: picture 0x00,
                            // slices 0x01-0xAF, user 0xB2, seq-hdr 0xB3, ext 0xB5,
                            // seq-end 0xB7, GOP 0xB8) as the FIRST start code means
                            // this is a raw elementary stream, not a program stream.
                            // Reconstruct 00 00 01 <code> and pass everything to the
                            // decoder. Locked out once a PS pack (0xBA) has appeared.
                            if (!ever_seen_pack && (in_byte <= 8'hB8)) begin
                                es_code     <= in_byte;
                                es_emit_idx <= 2'd0;
                                state       <= S_ES_EMIT;
                            end else if (in_byte >= 8'hBB) begin
                                // System / nav / padding / un-routed PES streams that
                                // carry a 2-byte length field (system_header 0xBB,
                                // program_stream_map 0xBC, padding 0xBE,
                                // private_stream_2 / NV_PCK nav packs 0xBF, MPEG audio
                                // 0xC8-0xDF, extra video 0xE1-0xEF, etc). Skip the WHOLE
                                // packet by its declared length so a 00 00 01 pattern
                                // embedded in the payload (common in DVD nav packs) can
                                // never false-trigger a start code and desync the stream.
                                state <= S_SYS_LEN_HI;
                            end else state <= S_HUNT;  // 0xB9 end code & low codes: keep hunting
                        end
                    endcase
                end
            end

            // ---- Pack header: MPEG-2 = 9 fixed bytes then a stuffing-length
            //      byte; MPEG-1 = 8 flat bytes (SCR + mux_rate), no stuffing.
            //      Discriminated on the marker in the first byte after 0xBA
            //      (bytes_remaining==9): 0010xxxx = MPEG-1, 01xxxxxx = MPEG-2.
            //      The markers are disjoint, and every pack re-latches
            //      mpeg1_ps, so a conforming stream can never mis-latch. ----
            S_PACK_SKIP: begin
                if (bytes_remaining == 16'd9 && in_byte[7:4] == 4'b0010) begin
                    mpeg1_ps        <= 1'b1;
                    bytes_remaining <= 16'd7;    // marker byte consumed; 7 more
                    state           <= S_DISCARD;
                end else if (bytes_remaining != 16'd0) begin
                    if (bytes_remaining == 16'd9) mpeg1_ps <= 1'b0;
                    bytes_remaining <= bytes_remaining - 16'd1;
                end else begin
                    // this byte = pack_stuffing_length (low 3 bits)
                    if (in_byte[2:0] == 3'd0)
                        state <= S_HUNT;
                    else begin
                        bytes_remaining <= {13'd0, in_byte[2:0]};
                        state <= S_DISCARD;
                    end
                end
            end

            // ---- Generic skip of bytes_remaining bytes, then hunt ----
            S_DISCARD: begin
                if (bytes_remaining <= 16'd1) state <= S_HUNT;
                else bytes_remaining <= bytes_remaining - 16'd1;
            end

            // ---- PES packet length ----
            S_PES_LEN_HI: begin pes_len_hi <= in_byte; state <= S_PES_LEN_LO; end
            S_PES_LEN_LO: begin
                pes_length <= {pes_len_hi, in_byte};
                if (mpeg1_ps) state <= S_M1_HDR;
                else          state <= S_PES_HDR_FLAGS1;
            end

            // ---- MPEG-2 PES optional header ----
            S_PES_HDR_FLAGS1: begin
                // '10' marker bits + PES_scrambling_control[1:0] in bits [5:4]:
                // nonzero = this PES payload is CSS-scrambled (undecryptable here).
                if (in_byte[7:6] == 2'b10 && in_byte[5:4] != 2'b00)
                    pes_scrambled <= 1'b1;
                pes_length <= pes_length - 16'd1;
                state <= S_PES_HDR_FLAGS2;
            end
            S_PES_HDR_FLAGS2: begin
                pts_present     <= in_byte[7];   // PTS_DTS_flags MSB
                aud_pes_has_pts <= in_byte[7];   // remember per-PES (sampled at frame_start)
                pes_length      <= pes_length - 16'd1;
                state <= S_PES_HDR_LEN;
            end
            S_PES_HDR_LEN: begin
                pes_hdr_len     <= in_byte;
                bytes_remaining <= {8'd0, in_byte};
                pts_byte_count  <= 3'd0;
                pes_length      <= pes_length - 16'd1;
                if (in_byte == 8'd0) begin
                    // no optional header -> straight to payload
                    if (pes_length == 16'd1) state <= S_HUNT;        // no payload
                    else if (stream_id_r == 8'hE0) state <= S_VIDEO_DATA;
                    else if (is_mp2_sid) begin first_aud_byte <= 1'b1; state <= S_AUDIO_DATA; end
                    else begin state <= S_SUBSTREAM_ID; end
                end else if (pts_present) begin
                    state <= S_PTS;
                end else begin
                    state <= S_PES_HDR_SKIP;
                end
            end

            // ---- 5-byte PTS ----
            S_PTS: begin
                pts_buf[pts_byte_count] <= in_byte;
                pes_length      <= pes_length - 16'd1;
                bytes_remaining <= bytes_remaining - 16'd1;
                if (pts_byte_count == 3'd4) begin
                    // assemble 33-bit PTS (byte4 = in_byte)
                    if (stream_id_r == 8'hE0) begin
                        vid_pts <= {pts_buf[0][3], pts_buf[0][2:1], pts_buf[1],
                                    pts_buf[2][7:1], pts_buf[3], in_byte[7:1]};
                        vid_pts_valid <= 1'b1;
                    end else begin
                        aud_pts <= {pts_buf[0][3], pts_buf[0][2:1], pts_buf[1],
                                    pts_buf[2][7:1], pts_buf[3], in_byte[7:1]};
                        aud_pts_valid <= 1'b1;
                    end
                    // decide what follows the header
                    if (pes_length == 16'd1) state <= S_HUNT;       // packet ends at PTS
                    else if (bytes_remaining == 16'd1) begin        // header done
                        if (stream_id_r == 8'hE0) state <= S_VIDEO_DATA;
                        else if (is_mp2_sid) begin first_aud_byte <= 1'b1; state <= S_AUDIO_DATA; end
                        else state <= S_SUBSTREAM_ID;
                    end else state <= S_PES_HDR_SKIP;
                end else begin
                    pts_byte_count <= pts_byte_count + 3'd1;
                end
            end

            // ---- MPEG-1 PES optional header (ISO 11172-1): 0xFF stuffing* ->
            //      optional 2-byte STD buffer field ('01......') -> 0x2X+PTS /
            //      0x3X+PTS+DTS / one no-timestamp byte (spec 0x0F; any other
            //      value is treated the same — graceful on junk). The 5-byte
            //      timestamp packing matches MPEG-2, so S_PTS is entered with
            //      pts_buf[0] preloaded and pts_byte_count=1: PTS-only lands on
            //      the existing bytes_remaining==1 header-done dispatch, and
            //      PTS+DTS falls into S_PES_HDR_SKIP with exactly the 5 DTS
            //      bytes left to consume. ----
            S_M1_HDR: begin
                pes_length <= pes_length - 16'd1;
                if (in_byte == 8'hFF) begin                    // stuffing
                    if (pes_length == 16'd1) state <= S_HUNT;
                end else if (in_byte[7:6] == 2'b01) begin      // STD buffer field
                    if (pes_length == 16'd1) state <= S_HUNT;
                    else                     state <= S_M1_STD;
                end else if (in_byte[7:5] == 3'b001) begin     // 0x2X PTS / 0x3X PTS+DTS
                    aud_pes_has_pts <= 1'b1;
                    pts_buf[0]      <= in_byte;
                    pts_byte_count  <= 3'd1;
                    bytes_remaining <= in_byte[4] ? 16'd9 : 16'd4;
                    if (pes_length == 16'd1) state <= S_HUNT;  // truncated packet
                    else                     state <= S_PTS;
                end else begin                                 // 0x0F: no timestamp
                    aud_pes_has_pts <= 1'b0;
                    if (pes_length == 16'd1) state <= S_HUNT;  // no payload
                    else if (stream_id_r == 8'hE0) state <= S_VIDEO_DATA;
                    else if (is_mp2_sid) begin first_aud_byte <= 1'b1; state <= S_AUDIO_DATA; end
                    else state <= S_SUBSTREAM_ID;
                end
            end
            S_M1_STD: begin                                    // STD field 2nd byte
                pes_length <= pes_length - 16'd1;
                if (pes_length == 16'd1) state <= S_HUNT;
                else                     state <= S_M1_HDR;
            end

            // ---- Skip remaining optional-header bytes ----
            S_PES_HDR_SKIP: begin
                pes_length <= pes_length - 16'd1;
                if (pes_length == 16'd1) state <= S_HUNT;
                else if (bytes_remaining <= 16'd1) begin
                    if (stream_id_r == 8'hE0) state <= S_VIDEO_DATA;
                    else if (is_mp2_sid) begin first_aud_byte <= 1'b1; state <= S_AUDIO_DATA; end
                    else state <= S_SUBSTREAM_ID;
                end else bytes_remaining <= bytes_remaining - 16'd1;
            end

            // ---- private_stream_1 substream_id: classify audio + start sub-header skip ----
            S_SUBSTREAM_ID: begin
                pes_length <= pes_length - 16'd1;
                if (pes_length == 16'd1) begin
                    state <= S_HUNT;   // substream_id was the only payload byte
                end else if (in_byte[7:5] == 3'b001) begin
                    // Subpicture (subtitle) substream 0x20-0x3F. Intercepted BEFORE
                    // the audio-track filter below. Subpicture has NO sub-header, so
                    // the SPU payload begins with the NEXT byte -> S_SP_DATA directly.
                    if (sp_enable && (in_byte[2:0] == sp_track)) begin
                        first_sp_byte <= 1'b1;
                        state         <= S_SP_DATA;
                    end else begin
                        bytes_remaining <= pes_length - 16'd1;
                        state           <= S_DISCARD;
                    end
                end else if (in_byte[2:0] != aud_track) begin
                    // Not the selected audio track. A DVD interleaves several audio
                    // substreams (e.g. Matrix AC-3 0x80/0x81/0x82); forwarding all of
                    // them garbles the one in-fabric decoder. Discard this PES.
                    bytes_remaining <= pes_length - 16'd1;
                    state           <= S_DISCARD;
                end else begin
                    casez (in_byte)
                        8'b1000_0???: begin aud_type_r <= 2'd0; bytes_remaining <= 16'd3; state <= S_AUD_SUBHDR; end // AC-3
                        8'b1000_1???: begin aud_type_r <= 2'd1; bytes_remaining <= 16'd3; state <= S_AUD_SUBHDR; end // DTS
                        8'b1010_0???: begin aud_type_r <= 2'd2; bytes_remaining <= 16'd6; state <= S_AUD_SUBHDR; end // LPCM
                        default:      begin aud_type_r <= 2'd3; bytes_remaining <= pes_length - 16'd1; state <= S_DISCARD; end
                    endcase
                end
            end

            // ---- Skip AC-3/DTS (3) or LPCM (6) sub-header bytes ----
            S_AUD_SUBHDR: begin
                pes_length <= pes_length - 16'd1;
                // Capture the LPCM word-length before the sub-header is discarded.
                // LPCM header = 6 bytes (bytes_remaining 6->1); byte +5 (quant/freq/
                // channels) is in in_byte when bytes_remaining == 2. bits[7:6] =
                // 0=16, 1=20, 2=24-bit. (aud_type_r==2 gates out AC-3/DTS, which
                // also pass through bytes_remaining==2 but carry no such field.)
                if (aud_type_r == 2'd2 && bytes_remaining == 16'd2)
                    lpcm_quant_r <= in_byte[7:6];
                if (pes_length == 16'd1) state <= S_HUNT;       // no audio payload
                else if (bytes_remaining <= 16'd1) begin
                    first_aud_byte <= 1'b1;
                    state <= S_AUDIO_DATA;
                end else bytes_remaining <= bytes_remaining - 16'd1;
            end

            // ---- System/nav/padding PES: capture 2-byte length, skip payload ----
            S_SYS_LEN_HI: begin pes_len_hi <= in_byte; state <= S_SYS_LEN_LO; end
            S_SYS_LEN_LO: begin
                bytes_remaining <= {pes_len_hi, in_byte};
                if ({pes_len_hi, in_byte} == 16'd0) state <= S_HUNT;  // empty packet
                // private_stream_2 (NAV pack): peek the substream id (PS2 has NO
                // PES optional header - the id is the first payload byte) when
                // either sink is enabled. Everything else: skip by length.
                else if (stream_id_r == 8'hBF && (pci_enable || dsi_enable))
                    state <= S_PS2_SUB;
                else state <= S_DISCARD;
            end

            // ---- private_stream_2 substream id: 0x00 = PCI (nav_pci),
            //      0x01 = DSI (nav_dsi); each routed only if its sink is
            //      enabled, else discarded by length ----
            S_PS2_SUB: begin
                if (bytes_remaining <= 16'd1) state <= S_HUNT;  // id was the last byte
                else begin
                    bytes_remaining <= bytes_remaining - 16'd1;
                    if (in_byte == 8'h00 && pci_enable) begin
                        first_pci_byte <= 1'b1;
                        state <= S_PCI_DATA;
                    end else if (in_byte == 8'h01 && dsi_enable) begin
                        first_dsi_byte <= 1'b1;
                        state <= S_DSI_DATA;
                    end else
                        state <= S_DISCARD;
                end
            end

            // ---- Forward the PCI payload to nav_pci ----
            S_PCI_DATA: begin
                first_pci_byte <= 1'b0;
                if (bytes_remaining <= 16'd1) state <= S_HUNT;
                else bytes_remaining <= bytes_remaining - 16'd1;
            end

            // ---- Forward the DSI payload to nav_dsi ----
            S_DSI_DATA: begin
                first_dsi_byte <= 1'b0;
                if (bytes_remaining <= 16'd1) state <= S_HUNT;
                else bytes_remaining <= bytes_remaining - 16'd1;
            end

            // ---- Forward elementary stream payloads ----
            S_VIDEO_DATA: begin
                vid_hist   <= {vid_hist[23:0], in_byte};   // track forwarded bytes
                pes_length <= pes_length - 16'd1;
                if (pes_length == 16'd1) begin
                    // End of this video PES. If it ended on a sequence_end_code,
                    // flush the decoder's last slice with trailing filler.
                    if (seqend_at_pes_end) begin
                        flush_cnt <= VID_FLUSH_LEN;
                        state     <= S_VID_FLUSH;
                    end else
                        state <= S_HUNT;
                end
            end
            S_AUDIO_DATA: begin
                first_aud_byte <= 1'b0;
                pes_length <= pes_length - 16'd1;
                if (pes_length == 16'd1) state <= S_HUNT;
            end
            S_SP_DATA: begin
                first_sp_byte <= 1'b0;
                pes_length <= pes_length - 16'd1;
                if (pes_length == 16'd1) state <= S_HUNT;
            end

            // ---- Raw elementary stream: forward every byte, never leave ----
            S_ES_PASS: ;  // forwarding handled in the output comb block; stay here

            default: state <= S_HUNT;
            endcase
        end
    end
end

endmodule

`default_nettype wire
