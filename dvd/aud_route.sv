//============================================================================
//  dvd/aud_route.sv — audio_ring read-side arbiter for Passthru.
//
//  In Passthru the wire must always carry something the sink can use, so the
//  codec decides the path per frame: AC-3 and DTS are bitstreamed by
//  iec61937_wrap, while LPCM and MP2 are decoded by dvd_audio_decode and sent
//  as ordinary PCM. Both consumers therefore have to read the SAME ring, and
//  `dvd/audio_ring.sv` has exactly one byte pointer, one descriptor pointer and
//  no internal arbitration — so something has to hand frames between them.
//
//  WHY A MODULE AND NOT A FEW LINES IN emu.sv: emu has no testbench, and the
//  failure this arbiter can cause is invisible until it is catastrophic (a
//  half-consumed frame leaves rd_ptr inside it and every later read is shifted,
//  permanently). Same reasoning that produced flush_ctl.sv, css_detect.sv and
//  dpad_seek.sv.
//
//  THE GRANT IS PER FRAME, NOT PER CYCLE, and it is released by counting bytes
//  rather than by watching the consumer:
//
//    * A consumer pops the descriptor at the START of a frame and then streams
//      its payload, so "the descriptor was popped" does NOT mean the frame is
//      finished. Releasing there would let the other consumer interleave into
//      the middle of a payload.
//    * The release condition is therefore the SAME invariant the ring itself
//      relies on: a frame is done when frame_len bytes have left the byte ring.
//      Counting `ring_ready` measures exactly that and needs no new signal from
//      either consumer.
//
//  ⚠ `frame_valid` de-asserts for up to 2 clk_sys cycles after a pop while the
//  head refills from the descriptor RAM (audio_ring.sv:139-145). A grant must
//  only ever be taken while frame_valid is high, or the type read is stale.
//
//  ⚠ A held frame is NOT an idle one. iec61937_wrap holds a codec frame for A/V
//  sync without popping it, sometimes for many burst periods. The grant stays
//  with the wrapper throughout: the head really is its frame, and starving the
//  decoder meanwhile is correct, not a deadlock.
//============================================================================

`timescale 1ns/1ps

module aud_route (
    input  logic       clk,
    input  logic       rst_n,          // audio-chain reset (aud_rst_n)

    // 1 = Passthru: split by codec. 0 = Decode: the decoder takes everything,
    // which is the pre-existing behaviour, bit for bit.
    input  logic       split_en,

    // audio_ring head (read-only; the arbiter never pops anything itself)
    input  logic       frame_valid,
    input  logic [1:0] frame_type,     // 0=AC3 1=DTS 2=LPCM 3=MP2/unknown
    input  logic [15:0] frame_len,
    input  logic       ring_ready,     // a payload byte left the ring this cycle

    // Exactly one of these is high at a time. Gate each consumer's frame_valid
    // with its own grant; leave ring_byte/ring_valid shared.
    output logic       dec_owns,
    output logic       wrap_owns,

    // Content class of the frames being routed, latched at each grant so it
    // holds through gaps instead of flapping. 1 = LPCM/MP2 (this is a PCM
    // session), 0 = AC-3/DTS. Drives the HDMI link-format request.
    output logic       pcm_session
);

    // AC-3 and DTS are the IEC 61937 codecs; everything else is decoded to PCM.
    // Note type 3 is MP2 *and* the legacy "unknown" sentinel -- routing it to the
    // decoder is right either way, since mp2_decode simply never syncs on junk.
    // ⚠ A plain wire, not a function: CLAUDE.md records five `function automatic`
    // helpers that Quartus 17 miscompiled SILENTLY (sim bit-exact, silicon mute).
    wire is_bitstream = (frame_type == 2'd0) || (frame_type == 2'd1);

    typedef enum logic [0:0] { S_IDLE, S_BUSY } state_t;
    state_t          st;
    logic            owner_wrap;   // who holds the current grant
    logic [15:0]     bytes_left;

    // A grant can be taken the moment a head is visible, so the consumer sees
    // its gated frame_valid in the same cycle the ring presents it -- no bubble.
    wire take        = (st == S_IDLE) && frame_valid;
    wire take_wrap   = take && split_en && is_bitstream;
    wire take_dec    = take && !take_wrap;

    assign wrap_owns = split_en && ((st == S_IDLE) ? take_wrap : owner_wrap);
    assign dec_owns  = (st == S_IDLE) ? (take_dec || !split_en)
                                      : (!owner_wrap || !split_en);

    // A byte can in principle leave the ring in the very cycle the grant is taken.
    // Neither consumer does that today (the wrapper reaches S_B0 four states after
    // S_IDLE, the decoder two), but a counter that ignored it would hold the grant
    // one byte too long and hand the NEXT frame's first byte to the wrong consumer.
    // Cheap to get right; a latent trap for the next consumer if it is not.
    wire [15:0] take_byte = (frame_len != 16'd0 && ring_ready) ? 16'd1 : 16'd0;
    wire [15:0] take_rem  = frame_len - take_byte;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st          <= S_IDLE;
            owner_wrap  <= 1'b0;
            bytes_left  <= 16'd0;
            pcm_session <= 1'b0;
        end else begin
            case (st)
            S_IDLE: if (take) begin
                owner_wrap <= take_wrap;
                bytes_left <= take_rem;
                // Latched, not combinational: it must survive the gaps between
                // frames or the HDMI link format would flap at every pause.
                if (split_en) pcm_session <= !is_bitstream;
                // take_rem is 0 for a zero-length frame, which would otherwise
                // strand the grant waiting for a count that can never arrive.
                if (take_rem != 16'd0) st <= S_BUSY;
            end

            S_BUSY: if (ring_ready) begin
                bytes_left <= bytes_left - 16'd1;
                if (bytes_left == 16'd1) st <= S_IDLE;
            end
            endcase
        end
    end

endmodule
