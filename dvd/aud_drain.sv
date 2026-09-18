// aud_drain.sv -- "the audio a cell delivered has been PRESENTED", for the
// reader's natural-transition gate (dvd_iso_reader.aud_drained).
//
// WHY THIS EXISTS (2026-09-18, Scooby-Doo 2 "Shaggy's commentary is cut off").
// A NATURAL jump or seek (a cell command or a POST, never a user press) waits
// in the reader for nat_drained: the reader's cache, the demux pipe and the
// VBUF are empty. That is a statement about VIDEO only. The jump then fires
// flush_ctl's aud_flush (every title-domain jump/seek), which discards
// whatever the 32 KB audio ring and the decoder still hold.
//
// On a normal motion cell that is a few tens of ms: the demux is paced by the
// display, so when the last picture is on screen the audio queued behind it is
// nearly spent. On a cell carrying ONE picture and many seconds of audio it is
// not. The picture drains the VBUF at once, the ring backpressures the demux,
// and the reader finishes delivering while a full ring is still to play:
// 32 KB of 192 kbps AC-3 is ~1.3 s. MEASURED on the disc
// (Scooby-Doo 2 VTS_02 PGCN 26): cells 1-13 and 19-22 each carry exactly one
// video PTS and 3.9-29.9 s of audio. Cells 10-13 are 4-5 s clips that end in a
// cell command, so ~1.3 s of a 4 s line was cut every time.
//
// WHAT IT ASSERTS.  drained = the ring holds no COMMITTED frame, the decoder is
// not holding one back, and that has been true for SETTLE cycles (~128 ms) --
// long enough for the frame the dispatcher already popped (decode + 32 ms of
// play), one more the codec may hold, and the 512-pair PCM FIFO (~11 ms) to
// play out. ⚠ It is a TIMER, not a decoder-idle signal: the cost of erring
// long is up to 128 ms of held last picture at a natural transition, the cost
// of erring short is the reported defect. MEASURED in the bench: a settle
// shorter than pop-to-played cuts exactly one frame. The ring's LAST frame is never
// committed (audio_ring finalizes a frame's length at the NEXT frame start), so
// "no committed frame" is reachable at a cell's end; that trailing frame is
// lost exactly as it was before, and the settle does not wait for it.
//
// ⚠ ESCAPE: consumer_alive is emu's ring-drain watchdog (aud_bp_armed). It is
// low when nothing has proven the audio consumer alive: audio Off, no audio
// stream, a wedged decoder. Then nothing will ever drain the ring, so the
// predicate reads DRAINED at once. The navigation must never wait on a
// consumer that is not consuming. (DRAIN_WD in the reader bounds the wait
// anyway, but at 60 s, which is not an escape a user can live with.)
//
// ⚠ dec_holding (a PTS-tagged frame has dispatched and the drain gate is
// holding it back) keeps the predicate LOW with the ring empty: those samples
// are due and not yet played. It is bounded by the decoder's own ~2.5 s
// fallback timer and by the STC reaching play_pts.
`default_nettype none
module aud_drain #(
    parameter int SETTLE = 3_456_000      // ~128 ms @ 27 MHz = 4 AC-3 frames
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] frames_avail,      // audio_ring: committed frames queued
    input  wire        consumer_alive,    // emu aud_bp_armed
    input  wire        dec_holding,       // decoder drain gate holding PTS'd audio
    output wire        drained
);
    localparam int W = $clog2(SETTLE + 1);
    // ⚠ a sized localparam, NOT W'(SETTLE): Quartus 17 miscompiles N'(expr)
    // size casts silently (docs/mpeg1.md, the MP2 bring-up).
    localparam logic [W-1:0] SETTLE_W = SETTLE;

    wire quiet = (frames_avail == 16'd0) && ~dec_holding;

    reg [W-1:0] settle;
    always @(posedge clk) begin
        if (!rst_n || !quiet)   settle <= '0;
        else if (settle != SETTLE_W) settle <= settle + 1'b1;
    end

    assign drained = ~consumer_alive || (quiet && (settle == SETTLE_W));
endmodule
`default_nettype wire
