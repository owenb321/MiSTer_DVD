//============================================================================
//  ac3_reframer.sv — re-frame the demuxed AC-3 byte stream on AC-3 FRAME
//  boundaries (the 0x0B77 sync word) before it enters audio_ring.
//
//  WHY (static-pops root cause):
//    ps_demux sets aud_frame_start once per PES PAYLOAD (~2 KB), so audio_ring's
//    drop unit is a PES chunk, NOT a decodable AC-3 frame. On overflow (the
//    frame-rate governor floods the ring during high-action video) audio_ring
//    drops a whole "frame" = a PES chunk, which cuts an AC-3 frame mid-stream ->
//    ac3_front desyncs -> self-heal reset -> audible POP.
//
//    A clean AC-3-FRAME-aligned drop is harmless (proven: liba52 cosim, 0 errors —
//    ac3_front resyncs on the next 0x0B77).  So if audio_ring's frames ARE AC-3
//    frames, every overflow drop becomes a silent gap of whole frames, not a pop.
//
//  WHAT:
//    Transparent 1-byte-delay passthrough of the audio byte stream that REGENERATES
//    frame_start for AC-3 (aud_type==0): it pulses on the first byte of each AC-3
//    frame, ignoring the incoming PES-granular frame_start.  Non-AC-3 types
//    (LPCM/DTS/unknown) pass their frame_start through unchanged.  The PES PTS is
//    carried to the next regenerated AC-3 frame_start (MPEG semantics: a PES PTS
//    refers to the first access unit that STARTS in that packet).
//
//    Bytes are forwarded byte-for-byte (1-byte pipeline latency), so the data
//    delivered to ac3_front is identical to before — the reframer is transparent
//    when no overflow occurs; it only changes WHERE audio_ring may drop.
//
//  FRAME-LENGTH LOCK (v2 — robust to in-payload 0x0B77):
//    A coincidental 0x0B77 inside AC-3 payload data (~4 % of frames at 640 kb/s)
//    would otherwise create a spurious frame boundary; an overflow drop landing
//    there is non-aligned -> the residual pop seen on BBB.  To prevent that we
//    parse each frame header: after a 0x0B77 the byte at frame offset 4 is
//    {fscod[1:0], frmsizcod[5:0]}; for 48 kHz (fscod==0) the frame size is a fixed
//    function of frmsizcod (A/52 Table 5.18).  We compute the frame length in bytes
//    and only ACCEPT the next 0x0B77 once a full frame has been emitted
//    (foff >= frame_len) — spurious in-payload syncs are ignored.  The decoder is
//    48 kHz-only; for fscod!=0 (unsupported) we fall back to plain sync detection.
//    The reframer's input is the COMPLETE demuxed stream (drops happen later, in
//    audio_ring), so frame offsets are exact and the lock is deterministic; if it
//    ever slips it re-locks on the next real frame (foff>=frame_len opens the gate).
//
//  No backpressure: audio_ring ties aud_ready high (audio must never stall video),
//  so out_valid simply follows the (delayed) in_valid; there is no out_ready.
//============================================================================

`timescale 1ns/1ps

module ac3_reframer (
    input  logic        clk,
    input  logic        rst_n,

    // from ps_demux audio output
    input  logic [7:0]  in_byte,
    input  logic        in_valid,
    input  logic [1:0]  in_type,
    input  logic        in_frame_start,
    input  logic [32:0] in_frame_pts,
    input  logic        in_frame_pts_valid,

    // to audio_ring
    output logic [7:0]  out_byte,
    output logic        out_valid,
    output logic [1:0]  out_type,
    output logic        out_frame_start,
    output logic [32:0] out_frame_pts,
    output logic        out_frame_pts_valid
);
    localparam logic [1:0] T_AC3 = 2'd0;

    // AC-3 frame size in 16-bit WORDS for fscod=0 (48 kHz), indexed by frmsizcod>>1
    // (the two frmsizcod codes in each bitrate pair share the same 48 kHz size).
    // A/52 Table 5.18.  Returns 0 for invalid codes (>37) -> caller falls back.
    function automatic [12:0] words48 (input [5:0] frmsizcod);
        case (frmsizcod[5:1])
            5'd0:  words48 = 13'd64;   5'd1:  words48 = 13'd80;
            5'd2:  words48 = 13'd96;   5'd3:  words48 = 13'd112;
            5'd4:  words48 = 13'd128;  5'd5:  words48 = 13'd160;
            5'd6:  words48 = 13'd192;  5'd7:  words48 = 13'd224;
            5'd8:  words48 = 13'd256;  5'd9:  words48 = 13'd320;
            5'd10: words48 = 13'd384;  5'd11: words48 = 13'd448;
            5'd12: words48 = 13'd512;  5'd13: words48 = 13'd640;
            5'd14: words48 = 13'd768;  5'd15: words48 = 13'd896;
            5'd16: words48 = 13'd1024; 5'd17: words48 = 13'd1152;
            5'd18: words48 = 13'd1280; default: words48 = 13'd0;
        endcase
    endfunction

    // 1-byte holding register: we can only know whether the held byte begins a
    // 0x0B77 sync once its successor (in_byte) is on the wire.
    logic [7:0]  held_byte;
    logic [1:0]  held_type;
    logic        held_pes_start;   // the incoming frame_start that arrived with held_byte
    logic        held_valid;

    // PES PTS waiting to be attached to the next regenerated frame_start.
    logic [32:0] pend_pts;
    logic        pend_pts_valid;

    // Frame-length lock.
    logic [12:0] foff;             // offset of the held byte within the current frame
    logic [12:0] frame_len;        // current frame length in bytes (0 = unknown)
    logic        len_known;

    wire is_ac3    = (held_type == T_AC3);
    wire raw_sync  = is_ac3 && (held_byte == 8'h0B) && (in_byte == 8'h77);
    // Accept a sync only at/after a full frame boundary (or before we've locked).
    wire gate_open = (!len_known) || (foff >= frame_len);
    wire accept    = raw_sync && gate_open;
    // AC-3: frame boundaries come ONLY from accepted syncs. Other types pass the
    // PES-granular frame_start through.
    wire start_out  = is_ac3 ? accept : held_pes_start;
    // offset of the held byte being emitted this cycle (0 if it starts a new frame)
    wire [12:0] emit_off = accept ? 13'd0 : foff;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            held_byte           <= 8'd0;
            held_type           <= 2'd0;
            held_pes_start      <= 1'b0;
            held_valid          <= 1'b0;
            pend_pts            <= 33'd0;
            pend_pts_valid      <= 1'b0;
            foff                <= 13'd0;
            frame_len           <= 13'd0;
            len_known           <= 1'b0;
            out_byte            <= 8'd0;
            out_valid           <= 1'b0;
            out_type            <= 2'd0;
            out_frame_start     <= 1'b0;
            out_frame_pts       <= 33'd0;
            out_frame_pts_valid <= 1'b0;
        end else begin
            out_valid           <= 1'b0;
            out_frame_start     <= 1'b0;
            out_frame_pts_valid <= 1'b0;

            if (in_valid) begin
                // Emit the previously held byte now that we can classify it.
                if (held_valid) begin
                    out_byte        <= held_byte;
                    out_type        <= held_type;
                    out_valid       <= 1'b1;
                    out_frame_start <= start_out;
                    if (start_out && pend_pts_valid) begin
                        out_frame_pts       <= pend_pts;
                        out_frame_pts_valid <= 1'b1;
                        pend_pts_valid      <= 1'b0;     // consumed
                    end

                    // The byte at frame offset 4 is {fscod, frmsizcod}: lock length.
                    // fscod=0 -> 48 kHz; a valid frmsizcod gives a non-zero size.
                    if (is_ac3 && (emit_off == 13'd4)) begin
                        if ((held_byte[7:6] == 2'b00) && (words48(held_byte[5:0]) != 13'd0)) begin
                            frame_len <= words48(held_byte[5:0]) << 1;  // words -> bytes
                            len_known <= 1'b1;
                        end else begin
                            len_known <= 1'b0;     // non-48k or invalid code -> fallback
                        end
                    end

                    // advance the frame offset (reset to 0 at an accepted sync)
                    foff <= emit_off + 13'd1;
                end

                // Latch an arriving PES PTS for the next regenerated frame_start.
                // (Ordered AFTER the consume above so a PTS arriving the same cycle
                // a sync is emitted stays pending for the FOLLOWING frame.)
                if (in_frame_pts_valid) begin
                    pend_pts       <= in_frame_pts;
                    pend_pts_valid <= 1'b1;
                end

                // Shift the new byte into the holding register.
                held_byte      <= in_byte;
                held_type      <= in_type;
                held_pes_start <= in_frame_start;
                held_valid     <= 1'b1;
            end
        end
    end
endmodule
