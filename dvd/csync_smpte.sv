/*
 * csync_smpte.sv — DVD-FORK (standards-shaped analog composite sync, 2026-09-05)
 *
 * WHY THIS EXISTS
 * ---------------
 * The framework's composite sync (sys/sys_top.v `module csync`) emits **no
 * equalizing pulses** and serrates the vertical sync at LINE rate. SMPTE 170M-2004
 * §13.3 / Table 3 / Fig 7 (525-line) and ITU-R BT.470-6 Table 2 (625-line) both
 * specify a block of pre-equalizing pulses / serrated vertical sync / post-equalizing
 * pulses, and say why: the serrations are "provided to maintain horizontal
 * synchronization" and the block exists to "properly position the vertical sync".
 *
 * The cost of not doing it is MEASURED, not inferred (bench/dvd/csync_field_tb.sv,
 * docs/single_raster_analog.md §3.8): the two fields of a 2:1 raster start their
 * vsyncs half a line apart while the serration grid does not move with them, so the
 * fields present first broad pulses of ~50 us and ~18 us. 18 us is at or below the
 * trigger threshold of a width-based sync separator, so a television can read the
 * two fields differently and pair or swap them — line-pairing jitter, "sawtooth"
 * edges, and a display that resolves half the vertical detail it should.
 *
 * ★ WHY IT WAS NEVER BUILT, AND WHY THAT BLOCKER WAS FALSE.  sys/sys_top.v said
 * equalizing pulses "would need advance knowledge of vsync". True of THAT module:
 * it derives composite sync from a finished hsync/vsync pair and structurally cannot
 * emit a pulse BEFORE vsync starts. Not true here — `v_pos` carries the raster's own
 * line index and field parity, a full field ahead. The sync was being assembled in
 * the wrong place, not withheld for a good reason.
 *
 * ★ ANCHORED ON THE OUTPUT HSYNC, NOT ON h_pos.  `hcnt` locks to the leading edge of
 * the emitted `h_sync`, so every pulse this module places lands exactly where an
 * hsync would, and OUTSIDE the vertical block the output is `h_sync` delayed one
 * clock — which is bit-identical to what the stock module emits outside vsync
 * (`if (~vsync) csync_hs <= hsync;` then `csync = 0 ^ csync_hs`). That turns "did we
 * disturb anything?" into an equality gate the bench can check clock by clock,
 * instead of a hand-tuned delay constant. `v_pos` is used only to choose WHICH LINE
 * the block starts on, so the ~15-dot lead syncgen's outputs have over the emitted
 * picture is irrelevant here (it is well under half a line).
 *
 * ⚠ This places the analog vertical interval 245 dots (0.14 line) earlier than the
 * raster's own vsync edge, because the raster raises vsync at h_cntr 0 while hsync
 * sits at h_cntr 1471. That is the standards-correct placement — the vertical
 * interval begins at an H — it is invisible as a vertical shift, and it happens ONLY
 * on this analog composite-sync bit: VGA_HS/VS/DE/F1 and CE_PIXEL are untouched, so
 * HDMI is bit-identical on every mode. That decoupling is what makes this safe where
 * HW round 2's raster-level re-anchoring experiment was not (rtl/mpeg2/syncgen.v
 * vs_ref_dot: do not re-anchor the RASTER without a CRT to test on).
 *
 * COUNTING IN HALF-LINES is what makes both standards fall out of one generator:
 * SMPTE's 525-line block is 3H + 3H + 3H = 6/6/6 half-lines, BT.470's 625-line block
 * is 2.5H + 2.5H + 2.5H = 5/5/5. Every pulse width derives from modeline values the
 * raster already carries — no new constants — and each lands inside tolerance for
 * both standards:
 *
 *            | NTSC 480i        spec (sys M)  | PAL 576i         spec (B/G/H/I)
 *   line     | 1716 = 63.556 us  63.556       | 1728 = 64.000 us  64
 *   half     |  858              0.5H         |  864              0.5H
 *   serr  r  |  127 =  4.704 us  4.7  +/-0.1  |  127 =  4.704 us  4.7 +/-0.2 (I:0.1)
 *   broad q  |  731 = 27.074 us  27.1 nominal |  737 = 27.296 us  27.3 +/-0.1
 *   equal p  |   62 =  2.296 us  2.3  +/-0.1  |   63 =  2.333 us  2.35 +/-0.1
 *   l/m/n    |  6/6/6 = 9 lines  3H each      |  5/5/5 = 7.5 lines 2.5H each
 *
 * NTSC layout, field A: equalizing on lines 241-243, broad on 244-246 (exactly the
 * lines the raster's own vsync window covers), equalizing on 247-249 — all inside the
 * 22 blanked lines (active 0-239 of 262). PAL: 289.5-297 inside 24. Line 21
 * (v_cntr 261) is untouched, so dvd/cc_vbi.sv does not move.
 *
 * MODES (P1O[46] Analog CSync).  Mode 0 SMPTE is the shipped default; mode 1 is the
 * 2H-serration-only variant (the shape built as commit a2b72fb and reverted in 48c00cb —
 * a verdict taken while the field-parity corrector was defective and repeating fields
 * several times a second, so it was never a controlled A/B; it measures ~17x worse than
 * the full block and is kept only until field reports say whether any display prefers it).
 * ⛔ A third arm returning the framework's own csync was carried through bring-up and
 * REMOVED before release — it is a measurably broken signal (0.857 line between the
 * fields instead of 0.500, and a mis-identified first field), not a fallback.
 *
 * Interlaced only: `en` is interlaced_eff, and `cs_en` follows it, so a PROGRESSIVE
 * raster still takes the framework module — a nine-line vertical block is meaningless
 * there. That is gated in RTL rather than by user discipline, and it is the path
 * csync_field_tb's stock arm exercises now that the OSD value is gone.
 */
`include "timescale.v"
`include "field_polarity.vh"   // FIELD1_VPOS — shared with syncgen.v and cc_vbi.sv
`default_nettype none   // see the note in dvd/cc_line21.sv (round-3 lesson)

module csync_smpte (
    input  wire        clk,        // clk_sys 27 MHz (the dot clock)
    input  wire        rst_n,

    input  wire        mode,       // 0 SMPTE block, 1 2H serrations only
    input  wire        en,         // interlaced_eff: the 15 kHz raster is up
    input  wire        pal,        // 625-line raster

    input  wire        h_sync,     // the EMITTED hsync (core_h_sync), active high
    input  wire [11:0] v_pos,      // {line within field, raster field parity}

    output reg         cs,         // composite sync, 1 = sync tip
    output wire        cs_en       // 1 => sys_top must use `cs` instead of stock
);

// ---------------------------------------------------------------------------
// Per-standard geometry. All in the DOUBLED dot units the interlaced raster runs
// in (syncgen_intf doubles the modeline under pixel repetition), 27 MHz.
// ---------------------------------------------------------------------------
localparam [11:0] HALF_N  = 12'd858,  HALF_P  = 12'd864;   // half-line
localparam [11:0] EQ_N    = 12'd62,   EQ_P    = 12'd63;    // equalizing pulse  p
localparam [11:0] BROAD_N = 12'd731,  BROAD_P = 12'd737;   // broad pulse       q
localparam [11:0] VSS_N   = 12'd244,  VSS_P   = 12'd292;   // first broad LINE
localparam [3:0]  SEG_N   = 4'd6,     SEG_P   = 4'd5;      // half-lines per segment

wire [11:0] half_w  = pal ? HALF_P  : HALF_N;
wire [11:0] eq_w    = pal ? EQ_P    : EQ_N;
wire [11:0] broad_w = pal ? BROAD_P : BROAD_N;
wire [11:0] vss     = pal ? VSS_P   : VSS_N;

// Mode 1 (2H) keeps today's three-line vertical sync window and adds no equalizing
// pulses: it is the SAME generator with the two outer segments set to zero.
wire        smpte   = ~mode;
wire [3:0]  n_pre   = smpte ? (pal ? SEG_P : SEG_N) : 4'd0;
wire [3:0]  n_broad = smpte ? (pal ? SEG_P : SEG_N) : 4'd6;
wire [3:0]  n_post  = n_pre;

// ⚠ Gated on rst_n as well as `en`. If cs_en could assert while the counters are still
// held in reset, sys_top would take a `cs` that is not yet tracking hsync — i.e. the
// analog output would lose SYNC, not just picture, which is the re_interlace S_HUNT
// defect class (docs/single_raster_analog.md §3.2) and the one failure here that a
// television cannot ride out. In practice interlaced_eff is 0 through reset anyway
// (status is zero and analog_want_l resets low), so this costs nothing and removes the
// question.
assign cs_en = rst_n & en;

// ---------------------------------------------------------------------------
// Dot counter locked to the emitted hsync, plus the line/field it introduces.
// v_cntr has not yet advanced when hsync asserts (syncgen increments it at
// h_cntr >= horizontal_length, and hsync sits at 1471), so `cur_line` is the line
// that is ENDING and the block constants below are written against it directly —
// no +1, and so no wrap arithmetic at the field boundary. The block sits mid-field
// (lines 240-249 of 262) and can never straddle the wrap.
// ---------------------------------------------------------------------------
// ⚠ The position used below is the COMBINATIONAL one for the cycle in progress, not
// the register. A registered counter reset by the hsync edge does not read zero until
// the cycle AFTER the edge, so a pulse the block places at dot 0 of a line would be
// preceded by one cycle of `h_sync` passthrough — the pulse rises a clock early and
// measures one clock wide, but ONLY on the half-lines that start at a line boundary.
// The half-line-boundary pulses are unaffected, so the two fields disagree by exactly
// one clock and the block's first spacing reads 859 instead of 858. Caught by
// csync_field_tb's [G4] half-line-grid check and [G5] field congruence; it is precisely
// the kind of boundary error that a pulse-width-only census sails past.
reg  [11:0] hcnt;          // position of the PREVIOUS cycle
reg  [11:0] cur_line;
reg         fpar;          // 0 = the line-aligned-vsync field, 1 = the half-line one
reg         hs_q;

wire        hs_edge   = h_sync & ~hs_q;
wire [11:0] pos       = hs_edge ? 12'd0 : ((hcnt != 12'hFFF) ? (hcnt + 12'd1) : hcnt);
wire [11:0] line_now  = hs_edge ? v_pos[11:1] : cur_line;
wire        fpar_now  = hs_edge ? v_pos[0]    : fpar;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hcnt     <= 12'd0;
        cur_line <= 12'd0;
        fpar     <= 1'b0;
        hs_q     <= 1'b0;
    end else begin
        hs_q     <= h_sync;
        hcnt     <= pos;        // saturates rather than wraps if hsync ever stops
        cur_line <= line_now;
        fpar     <= fpar_now;
    end
end

// Half-line index within the field, and the phase inside the current half-line.
wire        second_half = (pos >= half_w);
wire [11:0] shl         = {line_now[10:0], 1'b0} + {11'd0, second_half};
wire [11:0] phase       = second_half ? (pos - half_w) : pos;

// The block's first half-line: the broad segment opens at the start of line `vss`,
// which is the half-line whose index is 2*(vss-1); the pre-equalizing segment opens
// n_pre half-lines earlier; and field B's whole block sits half a line later.
// Field 1 opens its block on a LINE boundary (even half-line index); the other field
// opens half a line later. Which one that is comes from the single shared constant, so
// this can never disagree with the raster's own vs_ref_dot — bench/dvd/csync_field_tb.sv
// gates that agreement directly.
wire        blk_half = (fpar_now != `FIELD1_VPOS);
wire [11:0] blk0  = {vss[10:0], 1'b0} - 12'd2 - {8'd0, n_pre} + {11'd0, blk_half};
wire [11:0] n_tot = {8'd0, n_pre} + {8'd0, n_broad} + {8'd0, n_post};
wire        in_blk = cs_en & (shl >= blk0) & (shl < (blk0 + n_tot));
wire [11:0] off    = shl - blk0;

wire        is_broad = (off >= {8'd0, n_pre}) & (off < ({8'd0, n_pre} + {8'd0, n_broad}));
wire [11:0] width    = is_broad ? broad_w : eq_w;

wire        cs_nxt = in_blk ? (phase < width) : h_sync;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) cs <= 1'b0;
    else        cs <= cs_nxt;
end

endmodule

`default_nettype wire
