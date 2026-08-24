//============================================================================
//  lpcm_unpack.sv — DVD LPCM frame bytes -> s16 L/R sample pairs (fabric audio).
//
//  Consumes the LPCM payload bytes that ps_demux has already stripped of the
//  6-byte private_stream_1 LPCM sub-header, so the byte stream here is raw
//  interleaved PCM samples.  DVD LPCM is BIG-ENDIAN; the MiSTer framework wants
//  signed little-endian s16 on AUDIO_L/R, so each 16-bit sample is assembled
//  hi-byte-first (b0<<8 | b1).  Samples are interleaved L,R,L,R...; we pack
//  {L,R} pairs into a small FIFO drained one pair per `aud_ce` (~48 kHz).
//
//  SCOPE: 48 kHz stereo, 16 / 20 / 24-bit (top-16-bit truncation for the 16-bit
//  HDMI path).  The `quant` input carries the LPCM sub-header word-length that
//  ps_demux now captures (0=16, 1=20, 2=24).  96 kHz and multichannel (>2 ch)
//  LPCM are still NOT handled — see docs/fabric_audio.md.
//
//  20/24-bit DVD LPCM packing (per FFmpeg libavcodec/pcm-dvd.c): a group spans
//  2 sample-times per channel.  For STEREO the group is the four high 16-bit
//  words in stream order `L0 R0 L1 R1` (8 bytes) — the SAME layout as plain
//  16-bit interleave — followed by the low bits: 20-bit adds 2 trailing
//  nibble-bytes, 24-bit adds 4 trailing bytes.  Since AUDIO_L/R is 16-bit we
//  keep only the four high words and DISCARD the trailing low bytes.  So the
//  unpacker assembles two {L,R} pairs exactly as at 16-bit, then skips
//  `skip_n` bytes (0 / 2 / 4) before the next group.  quant=16 => skip_n=0 =>
//  behaviour identical to the original 16-bit-only assembler (bit-for-bit).
//
//  Back-pressure: `full` is asserted when the pair FIFO can't take another pair;
//  the caller (dvd_audio_decode dispatch) must hold its read side off the audio
//  ring while full, which lets audio_ring drop a whole frame on its own overflow
//  rather than ever stalling video.
//============================================================================

`timescale 1ns/1ps

module lpcm_unpack #(
    parameter int FIFO_AW = 9            // pair-FIFO depth = 2^AW (>= one frame)
) (
    input  logic        clk,
    input  logic        rst,             // synchronous, active-high

    // LPCM word length from ps_demux (sub-header byte +5 bits[7:6]):
    // 0=16-bit, 1=20-bit, 2=24-bit. Stable per track. Sampled at group
    // boundaries so a mid-group change can't desync the assembler.
    input  logic [1:0]  quant,

    // byte input (raw BE PCM, sub-header already stripped)
    input  logic        wr_en,
    input  logic [7:0]  wr_data,
    output logic        full,            // pair FIFO can't accept another pair

    // audio-domain pop (single clock here: aud_ce is a clk-domain enable)
    input  logic        aud_ce,          // ~48 kHz sample tick (1-cycle enable)
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    output logic        aud_valid        // 1 = a real pair was popped this aud_ce
);

    // ---- group-aware byte assembler ----------------------------------------
    // A DVD LPCM group = 2 stereo sample-pairs.  The first 8 bytes hold the four
    // high 16-bit words (L0 R0 L1 R1) and assemble two {L,R} pairs exactly like
    // plain 16-bit.  20-bit adds 2 trailing low-nibble bytes, 24-bit adds 4 —
    // discarded (top-16 truncation).  `gbyte` walks 0..glen-1; bytes 0-7 are data
    // (phase = gbyte[1:0], pair = gbyte[2]), bytes >=8 are skipped.
    logic [3:0]  gbyte;                   // byte index within the current group
    logic [3:0]  glen;                    // group length: 8 (16b) / 10 (20b) / 12 (24b)
    logic [7:0]  lhi, llo, rhi;           // held bytes
    logic [15:0] samp_l, samp_r;
    logic        pair_wr;

    // Group length selected by quant (latched at each group start so a mid-group
    // change can't shorten/lengthen the group in flight).
    wire [3:0] glen_next = (quant == 2'd1) ? 4'd10 :   // 20-bit: 8 + 2 low bytes
                           (quant == 2'd2) ? 4'd12 :   // 24-bit: 8 + 4 low bytes
                                             4'd8;      // 16-bit: no low bytes

    // ---- pair FIFO (depth 2^FIFO_AW), entry = {L[15:0], R[15:0]} ------------
    localparam int DEPTH = (1 << FIFO_AW);
    logic [31:0] mem [0:DEPTH-1];
    logic [FIFO_AW:0] wptr, rptr;         // extra MSB for full/empty disambiguation
    wire  [FIFO_AW:0] level = wptr - rptr;
    wire        empty = (wptr == rptr);
    wire        fifo_full = (level == DEPTH[FIFO_AW:0]);

    // We must be able to take a full pair; `full` warns the producer one slot out.
    assign full = fifo_full;

    // assemble bytes -> pair_wr
    always_ff @(posedge clk) begin
        if (rst) begin
            gbyte   <= 4'd0;
            glen    <= 4'd8;               // 16-bit default until first group start
            pair_wr <= 1'b0;
        end else begin
            pair_wr <= 1'b0;
            if (wr_en) begin
                // Latch the group length at the start of each group.
                if (gbyte == 4'd0) glen <= glen_next;
                // Data bytes 0-7: assemble two {L,R} pairs (phase gbyte[1:0]).
                // Bytes >=8 are trailing low bits — consumed and discarded.
                if (gbyte < 4'd8) begin
                    case (gbyte[1:0])
                        2'd0: lhi <= wr_data;
                        2'd1: llo <= wr_data;
                        2'd2: rhi <= wr_data;
                        2'd3: begin
                            samp_l  <= {lhi, llo};
                            samp_r  <= {rhi, wr_data};
                            pair_wr <= 1'b1;   // push assembled pair next cycle
                        end
                    endcase
                end
                // Advance within the group; wrap at glen (uses the freshly latched
                // value on the group's first byte, else the held one).
                if (gbyte == (((gbyte == 4'd0) ? glen_next : glen) - 4'd1))
                    gbyte <= 4'd0;
                else
                    gbyte <= gbyte + 4'd1;
            end
        end
    end

    // FIFO write
    always_ff @(posedge clk) begin
        if (rst) begin
            wptr <= '0;
        end else if (pair_wr && !fifo_full) begin
            mem[wptr[FIFO_AW-1:0]] <= {samp_l, samp_r};
            wptr <= wptr + 1'b1;
        end
    end

    // FIFO read — one pair per aud_ce; hold last sample + drop aud_valid on empty
    always_ff @(posedge clk) begin
        if (rst) begin
            rptr      <= '0;
            audio_l   <= '0;
            audio_r   <= '0;
            aud_valid <= 1'b0;
        end else begin
            aud_valid <= 1'b0;
            if (aud_ce) begin
                if (!empty) begin
                    audio_l   <= mem[rptr[FIFO_AW-1:0]][31:16];
                    audio_r   <= mem[rptr[FIFO_AW-1:0]][15:0];
                    aud_valid <= 1'b1;
                    rptr      <= rptr + 1'b1;
                end
                // empty: hold audio_l/r, aud_valid stays low (silence/hold)
            end
        end
    end

endmodule
