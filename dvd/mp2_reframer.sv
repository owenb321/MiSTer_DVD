//============================================================================
//  mp2_reframer.sv — re-frame the demuxed MP2 (MPEG-1 Layer II) byte stream on
//  MP2 FRAME boundaries before it enters audio_ring.
//
//  Mirror of ac3_reframer (see its header for the full rationale): ps_demux's
//  aud_frame_start is PES-granular (~2 KB), so audio_ring's overflow drop unit
//  would cut an MP2 frame mid-stream -> decoder desync -> pop. Regenerating
//  frame_start on real frame boundaries makes every drop a clean whole-frame
//  gap the decoder resyncs over.
//
//  SYNC + FRAME-LENGTH LOCK:
//    The MP2 syncword is only 12 bits (0xFFF) vs AC-3's 16, so the length lock
//    matters MORE here. We qualify sync harder: held_byte == 0xFF and the
//    successor == 1111_1_10_x (sync[3:0]=1111, ID=1 (MPEG-1), layer=10
//    (Layer II)) -> a 15-bit match that also rejects Layer I/III and MPEG-2
//    LSF headers outright. Frame length comes from header byte 2
//    {bitrate_index[3:0], sampling_frequency[1:0], padding, private}:
//    N = 144000 * bitrate / fs + padding (Layer II), tabulated per
//    (fs, bitrate_index). Invalid codes (free format, index 15, fs=11) leave
//    the gate in plain-sync fallback, exactly like ac3_reframer's non-48k path.
//
//  Foreign types (AC-3/DTS/LPCM) pass through untouched — chain order in
//  emu.sv is ps_demux -> ac3_reframer -> dts_reframer -> mp2_reframer ->
//  audio_ring, each reframer owning only its own codec (T_MP2 = 2'd3).
//
//  No backpressure (audio_ring accepts always); 1-byte pipeline latency,
//  byte stream delivered unchanged. Reset by pipe_rst_n like its siblings.
//============================================================================

`timescale 1ns/1ps

module mp2_reframer (
    input  logic        clk,
    input  logic        rst_n,

    // from the reframer chain (dts_reframer output)
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
    localparam logic [1:0] T_MP2 = 2'd3;

    // Layer II frame length in bytes (without padding): 144000 * bitrate / fs.
    // fs: 00 = 44.1 kHz, 01 = 48 kHz, 10 = 32 kHz (ISO 11172-3 header coding).
    // Returns 0 for free format (0), invalid index (15) or reserved fs (11)
    // -> caller falls back to plain sync detection.
    function automatic [12:0] l2_bytes (input [1:0] fs, input [3:0] bidx);
        case ({fs, bidx})
            // 44.1 kHz: floor(144000*BR/44100)
            {2'b00, 4'd1}:  l2_bytes = 13'd104;   {2'b00, 4'd2}:  l2_bytes = 13'd156;
            {2'b00, 4'd3}:  l2_bytes = 13'd182;   {2'b00, 4'd4}:  l2_bytes = 13'd208;
            {2'b00, 4'd5}:  l2_bytes = 13'd261;   {2'b00, 4'd6}:  l2_bytes = 13'd313;
            {2'b00, 4'd7}:  l2_bytes = 13'd365;   {2'b00, 4'd8}:  l2_bytes = 13'd417;
            {2'b00, 4'd9}:  l2_bytes = 13'd522;   {2'b00, 4'd10}: l2_bytes = 13'd626;
            {2'b00, 4'd11}: l2_bytes = 13'd731;   {2'b00, 4'd12}: l2_bytes = 13'd835;
            {2'b00, 4'd13}: l2_bytes = 13'd1044;  {2'b00, 4'd14}: l2_bytes = 13'd1253;
            // 48 kHz: 3*BR exactly
            {2'b01, 4'd1}:  l2_bytes = 13'd96;    {2'b01, 4'd2}:  l2_bytes = 13'd144;
            {2'b01, 4'd3}:  l2_bytes = 13'd168;   {2'b01, 4'd4}:  l2_bytes = 13'd192;
            {2'b01, 4'd5}:  l2_bytes = 13'd240;   {2'b01, 4'd6}:  l2_bytes = 13'd288;
            {2'b01, 4'd7}:  l2_bytes = 13'd336;   {2'b01, 4'd8}:  l2_bytes = 13'd384;
            {2'b01, 4'd9}:  l2_bytes = 13'd480;   {2'b01, 4'd10}: l2_bytes = 13'd576;
            {2'b01, 4'd11}: l2_bytes = 13'd672;   {2'b01, 4'd12}: l2_bytes = 13'd768;
            {2'b01, 4'd13}: l2_bytes = 13'd960;   {2'b01, 4'd14}: l2_bytes = 13'd1152;
            // 32 kHz: 4.5*BR exactly
            {2'b10, 4'd1}:  l2_bytes = 13'd144;   {2'b10, 4'd2}:  l2_bytes = 13'd216;
            {2'b10, 4'd3}:  l2_bytes = 13'd252;   {2'b10, 4'd4}:  l2_bytes = 13'd288;
            {2'b10, 4'd5}:  l2_bytes = 13'd360;   {2'b10, 4'd6}:  l2_bytes = 13'd432;
            {2'b10, 4'd7}:  l2_bytes = 13'd504;   {2'b10, 4'd8}:  l2_bytes = 13'd576;
            {2'b10, 4'd9}:  l2_bytes = 13'd720;   {2'b10, 4'd10}: l2_bytes = 13'd864;
            {2'b10, 4'd11}: l2_bytes = 13'd1008;  {2'b10, 4'd12}: l2_bytes = 13'd1152;
            {2'b10, 4'd13}: l2_bytes = 13'd1440;  {2'b10, 4'd14}: l2_bytes = 13'd1728;
            default:        l2_bytes = 13'd0;
        endcase
    endfunction

    // 1-byte holding register (see ac3_reframer).
    logic [7:0]  held_byte;
    logic [1:0]  held_type;
    logic        held_pes_start;
    logic        held_valid;

    logic [32:0] pend_pts;
    logic        pend_pts_valid;

    logic [12:0] foff;
    logic [12:0] frame_len;
    logic        len_known;

    wire is_mp2    = (held_type == T_MP2);
    // 15-bit qualified sync: 0xFF + sync[3:0]=1111, ID=1 (MPEG-1), layer=10 (II).
    wire raw_sync  = is_mp2 && (held_byte == 8'hFF) && (in_byte[7:1] == 7'b1111_110);
    wire gate_open = (!len_known) || (foff >= frame_len);
    wire accept    = raw_sync && gate_open;
    wire start_out = is_mp2 ? accept : held_pes_start;
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
                if (held_valid) begin
                    out_byte        <= held_byte;
                    out_type        <= held_type;
                    out_valid       <= 1'b1;
                    out_frame_start <= start_out;
                    if (start_out && pend_pts_valid) begin
                        out_frame_pts       <= pend_pts;
                        out_frame_pts_valid <= 1'b1;
                        pend_pts_valid      <= 1'b0;
                    end

                    // Header byte 2 (frame offset 2) = {bitrate_index, fs, pad, priv}:
                    // lock the frame length (+1 if the padding bit is set).
                    if (is_mp2 && (emit_off == 13'd2)) begin
                        if (l2_bytes(held_byte[3:2], held_byte[7:4]) != 13'd0) begin
                            frame_len <= l2_bytes(held_byte[3:2], held_byte[7:4])
                                         + {12'd0, held_byte[1]};
                            len_known <= 1'b1;
                        end else begin
                            len_known <= 1'b0;   // free format / invalid -> fallback
                        end
                    end

                    foff <= emit_off + 13'd1;
                end

                if (in_frame_pts_valid) begin
                    pend_pts       <= in_frame_pts;
                    pend_pts_valid <= 1'b1;
                end

                held_byte      <= in_byte;
                held_type      <= in_type;
                held_pes_start <= in_frame_start;
                held_valid     <= 1'b1;
            end
        end
    end
endmodule
