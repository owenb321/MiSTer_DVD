// ============================================================================
// css_detect.sv — is this source CSS-scrambled? A DENSITY verdict.
// ============================================================================
// A CSS-encrypted rip (a raw disc copy with no decryption — VLC plays one because
// libdvdcss decrypts on the fly; this core never sees keys BY DESIGN, decryption is
// a PC-side rip step or the MiSTer_DVDcss Main's job) decodes as green macroblock
// garbage and LOUD AUDIO STATIC. So the core detects it from the PES headers
// (PES_scrambling_control != 0 — the headers themselves are never scrambled), warns
// via the transport HUD ("CSS ENCRYPTED", persistent, visible in menus too) and
// MUTES both audio paths. Video keeps playing so the disc stays identifiable.
//
// ★ WHY THIS IS A SEPARATE MODULE (issue #59, 2026-09-08). The rule used to be four
// lines inside emu.sv:
//
//     else if (ps_pes_scrambled && !css_scrambled) begin
//         css_det_cnt <= css_det_cnt + 3'd1;
//         if (css_det_cnt == 3'd3) css_scrambled <= 1'b1;   // 4th scrambled PES
//     end
//
// which has NO NOTION OF DENSITY OR TIME: four markers anywhere in a session —
// seconds or an hour apart — latch it permanently. A genuinely scrambled source
// gives a marker about every 5 packs (~19% of checked packs, measured on
// FAIRYTOPIA.iso by tools/css_scan.py). The rule could not tell 4 from 400,000, and
// multiple users lost all audio on discs that play perfectly. emu.sv has no
// testbench, which is why the rule could not be gated where it lived; extracted
// here for the same reason flush_ctl.sv, dpad_seek.sv and mode_realign.sv were.
//
// ★ THE RULE: A LEAKY BUCKET.
//     a scrambled header  -> bucket++ (latch at LATCH_HITS), leak counter reset
//     a clean header      -> every LEAK_CLEAN of them repay one bucket entry
// so the bucket drifts upward if and only if the scrambled FRACTION exceeds
// 1/(LEAK_CLEAN+1). With LEAK_CLEAN=64 that knee is p* = 1.54%:
//
//     real CSS (measured)   p=0.19    latches after ~90 checked headers (~0.15 s)
//     lightly scrambled     p=0.05    latches after ~455
//     knee                  p=0.0154  never
//     one stray per VOBU    p=0.004   never — DETERMINISTICALLY, not just unlikely
//     a handful per session p<=1e-4   never
//
// ⛔ NOT "reset the counter after N consecutive clean headers", which is the obvious
// form and was written first. It has no density interpretation, only a longest
// tolerable gap — and a VOBU is 200-500 packs, so a stray produced once per VOBU
// (the most plausible structure-driven periodicity on a DVD) never sees an N=512
// clean run and latches anyway. Raising N only moves the resonance. Below the knee
// the leak pins the bucket at zero, which a bench can prove rather than estimate.
//
// ⚠ scrambled without hdr_ok is IGNORED, and that is a benched property: it stops a
// future ps_demux edit that forgets the denominator from silently restoring the old
// count-anything behaviour.
//
// ⚠ STICKY PER MOUNT, DELIBERATELY. ps_demux resets on every jump via pipe_rst_n, so
// a latch that could drop would flap across menu jumps and seeks and leak static
// pops through the mute. It clears only on reset, a fresh mount, or an eject — NOT
// on load_flush/seek_ack/jump_ack.
//
// Parameters, not localparams, so the bench pins them explicitly and a retune is a
// reviewed edit. If a genuinely encrypted rip is ever measured below ~5% scrambled,
// raise LEAK_CLEAN (the knee moves as 1/(K+1)) and move css_detect_tb's knee band
// with it — the bench fails if the two disagree.
//
// Design note + the measured density table: docs/fabric_audio.md "CSS mute".
// Gate: bench/dvd/css_detect_tb.sv via bench/dvd/run_css.sh.
// ============================================================================
`default_nettype none

module css_detect #(
    parameter int LATCH_HITS = 16,   // scrambled headers in the bucket that latch
    parameter int LEAK_CLEAN = 64,   // clean headers that repay one bucket entry
    parameter int CENSUS_W   = 16    // width of the saturating diagnostic counters
) (
    input  wire clk,                 // clk_sys
    input  wire rst_n,               // async, active low (emu reset_n, OSD Reset included)
    input  wire mount,               // 1-cycle: fresh media -> re-evaluate
    input  wire eject,               // 1-cycle: slot emptied -> drop the verdict
    input  wire hdr_ok,              // 1-cycle: a checkable PES header was parsed
    input  wire scrambled,           // 1-cycle, coincident with hdr_ok: it was marked

    output reg  css_scrambled,       // sticky per mount -> HUD popup + both audio mutes
    output reg  [CENSUS_W-1:0] hdr_census,   // saturating: checkable headers seen
    output reg  [CENSUS_W-1:0] scram_census  // saturating: of those, marked scrambled
);

localparam int BUCKET_W = $clog2(LATCH_HITS + 1);
localparam int LEAK_W   = $clog2(LEAK_CLEAN);

reg [BUCKET_W-1:0] bucket;
reg [LEAK_W-1:0]   leak_cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bucket        <= '0;
        leak_cnt      <= '0;
        css_scrambled <= 1'b0;
        hdr_census    <= '0;
        scram_census  <= '0;
    end else if (mount || eject) begin
        bucket        <= '0;
        leak_cnt      <= '0;
        css_scrambled <= 1'b0;
        hdr_census    <= '0;
        scram_census  <= '0;
    end else if (css_scrambled) begin
        // Latched: hold everything. The verdict cannot be revisited until the media
        // changes (see the anti-flap note in the header).
    end else if (hdr_ok) begin
        if (~&hdr_census) hdr_census <= hdr_census + 1'b1;      // saturate, never wrap:
        if (scrambled) begin                                    // a wrapped census would
            if (~&scram_census) scram_census <= scram_census + 1'b1;  // lie in a bug report
            leak_cnt <= '0;
            if (bucket == BUCKET_W'(LATCH_HITS - 1)) css_scrambled <= 1'b1;
            else                                     bucket <= bucket + 1'b1;
        end else if (leak_cnt == LEAK_W'(LEAK_CLEAN - 1)) begin
            leak_cnt <= '0;
            if (bucket != '0) bucket <= bucket - 1'b1;
        end else begin
            leak_cnt <= leak_cnt + 1'b1;
        end
    end
end

endmodule

`default_nettype wire
