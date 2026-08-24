//============================================================================
//  dts_reframer.sv — re-frame the demuxed DTS byte stream on DTS FRAME
//  boundaries (the 0x7FFE8001 core sync word) before it enters audio_ring.
//
//  WHY: identical in spirit to dvd/ac3_reframer.sv, but for DTS. ps_demux sets
//  aud_frame_start once per PES payload, so audio_ring's frame unit for DTS is
//  a PES chunk, not a decodable DTS frame. For IEC 61937 passthrough
//  (dvd/iec61937_wrap.sv) the burst unit MUST be one whole DTS frame — the ring
//  measures frame_len from the gap between frame_starts (DVD DTS frames are
//  contiguous, so that gap == FSIZE+1 bytes = the exact frame size), and a clean
//  frame boundary keeps each 61937 burst aligned to a DTS syncframe.
//
//  WHAT: transparent 4-byte-delay passthrough that REGENERATES frame_start for
//  DTS (aud_type==1): it pulses on the first byte (0x7F) of each DTS core
//  syncframe. Non-DTS types (AC-3/LPCM/unknown) pass their incoming frame_start
//  through unchanged (delayed to match). Bytes are forwarded byte-for-byte, so
//  the data delivered downstream is identical — the reframer is transparent and
//  only changes WHERE audio_ring sees frame boundaries. Chain it AFTER
//  ac3_reframer (each reframer only touches its own codec; the other type passes
//  through), i.e. ps_demux -> ac3_reframer -> dts_reframer -> audio_ring.
//
//  SYNC: the DVD DTS core sync is the 16-bit big-endian pattern
//  7F FE 80 01 (0x7FFE8001), verified against libdca parse.c dca_syncinfo and a
//  real T2 DTS track. It is a 32-bit pattern (false-trigger probability ~1 in
//  4e9 bytes), so unlike AC-3's 16-bit 0x0B77 no frame-length lock is needed —
//  every detected sync is accepted as a boundary. (The header fields for the
//  burst sample count, NBLKS -> (NBLKS+1)*32, are parsed downstream in
//  iec61937_wrap; the reframer only needs the boundary.)
//
//  No backpressure: audio_ring ties aud_ready high; out_valid follows the
//  (delayed) in_valid. See docs/iec61937.md.
//============================================================================

`timescale 1ns/1ps

module dts_reframer (
    input  logic        clk,
    input  logic        rst_n,

    // from ps_demux / ac3_reframer audio output
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
    localparam logic [1:0] T_DTS = 2'd1;

    // 4-deep byte pipeline: stage 0 is the byte emitted this cycle; the DTS sync
    // spans stages 0..3 (stage0 = the 0x7F first byte). Emission lags input by 4
    // cycles (fill) but drops no bytes.
    logic [7:0] b0, b1, b2, b3;
    logic [1:0] t0, t1, t2, t3;
    logic       p0, p1, p2, p3;    // carried (delayed) incoming frame_start
    logic [3:0] fill;              // pipeline occupancy; fill[3]=1 -> 4 bytes valid

    // Pending PES PTS, attached to the next regenerated frame_start (MPEG
    // semantics: a PES PTS refers to the first access unit STARTING in it).
    logic [32:0] pend_pts;
    logic        pend_pts_valid;

    wire win_sync    = (b0 == 8'h7F) && (b1 == 8'hFE) && (b2 == 8'h80) && (b3 == 8'h01);
    wire out_is_dts  = (t0 == T_DTS);
    wire dts_start   = out_is_dts && win_sync;                // 32-bit sync: accept always
    wire nondts_start= ~out_is_dts && p0;                     // pass-through frame_start
    wire start_out   = dts_start | nondts_start;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b0<=8'd0; b1<=8'd0; b2<=8'd0; b3<=8'd0;
            t0<=2'd0; t1<=2'd0; t2<=2'd0; t3<=2'd0;
            p0<=1'b0; p1<=1'b0; p2<=1'b0; p3<=1'b0;
            fill<=4'd0;
            pend_pts<=33'd0; pend_pts_valid<=1'b0;
            out_byte<=8'd0; out_valid<=1'b0; out_type<=2'd0;
            out_frame_start<=1'b0; out_frame_pts<=33'd0; out_frame_pts_valid<=1'b0;
        end else begin
            out_valid           <= 1'b0;
            out_frame_start     <= 1'b0;
            out_frame_pts_valid <= 1'b0;

            if (in_valid) begin
                // Emit stage 0 once the pipeline is primed (no bytes dropped —
                // the first 4 in_valid cycles just fill the pipe).
                if (fill[3]) begin
                    out_byte        <= b0;
                    out_type        <= t0;
                    out_valid       <= 1'b1;
                    out_frame_start <= start_out;
                    if (start_out && pend_pts_valid) begin
                        out_frame_pts       <= pend_pts;
                        out_frame_pts_valid <= 1'b1;
                        pend_pts_valid      <= 1'b0;   // consumed
                    end
                end

                // Latch an arriving PES PTS (ordered after the consume so a PTS
                // arriving the same cycle a frame_start is emitted stays pending
                // for the FOLLOWING frame).
                if (in_frame_pts_valid) begin
                    pend_pts       <= in_frame_pts;
                    pend_pts_valid <= 1'b1;
                end

                // Shift the pipeline (stage3 = newest = in_byte).
                b0<=b1; b1<=b2; b2<=b3; b3<=in_byte;
                t0<=t1; t1<=t2; t2<=t3; t3<=in_type;
                p0<=p1; p1<=p2; p2<=p3; p3<=in_frame_start;
                fill <= {fill[2:0], 1'b1};
            end
        end
    end
endmodule
