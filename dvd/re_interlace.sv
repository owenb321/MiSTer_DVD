// re_interlace.sv — DVD-FORK (analog fields re-timer; dual-raster 2026-07-29,
// fieldpass-only since the 2026-09-02 Video Output consolidation)
//
// Native 15 kHz broadcast-timed 480i/576i for the analog pins, re-timed 1:1 from
// the core's interlaced fields raster.
//
// WHY: a real CRT on the analog I/O board needs broadcast 480i/576i (alternating
// 262/263 or 312/313 field totals with the HALF-LINE vsync), but the main raster
// must NOT carry a half-line — vsync landing at a different horizontal position
// every field makes ascal's HDMI consumer HUNT for lock (the ff01ac8 issue: ~1-2 s
// brightness pulse + scanline comb, HW-observed). So this module re-times the main
// raster onto a second, local raster that adds the half-line:
//
//   main fields raster (pixel-repeated 480i/576i, 27 MHz CE=1, no half-line,
//   tapped at the registered vga_*_q output stage) --> 4-line sync-read BRAM -->
//   second sync_gen instance (rtl/mpeg2/syncgen.v, the HW-proven N64-model
//   half-line machinery, clk_en = 13.5 MHz CE) --> registered out_* -->
//   sys_top VGA2_* --> direct analog chain.
//
// The source is `Video Output = Interlaced`'s main raster (il_eff): the decoder
// emits AUTHORED TOP/BOTTOM field images in top_field_first order with the true
// rff 3:2 field cadence, so every displayed refresh is one genuine field of
// exactly one picture, and content-field-to-raster-field alignment is actively
// corrected upstream (docs/field_parity.md). Source and local rasters have
// IDENTICAL line and field structure (1716 clk27/line, field totals alternating
// 262/263 // 312/313), so every source pixel is read a CONSTANT SKEW_FP after it
// is written. Two differences only: the source carries 2 dots per pixel (pixel
// repetition — decimated on the write port) and samples vsync at dot 0 in both
// fields (no half-line; HDMI uses VGA_F1 instead), while our local sync_gen adds
// the half-line the CRT needs.
//
// LOCK FSM: HUNT (sync_gen held in reset, outputs blank/no syncs) -> ARM (skew
// countdown from a verified main frame top) -> RUN (free-run; locked=1). The
// main raster is health-checked by PERIOD, not coordinates: consecutive frame
// tops must be exactly 900900 (NTSC) / 1080000 (PAL) clk27 apart. Any other main
// raster (the progressive raster during a mode walk, Film-24p 23.976 Hz, mid-walk
// garbage) fails the check and the module simply stays unlocked —
// self-protecting. pal/enable changes and a frame-top timeout also drop to HUNT.
// Phase lock is by construction: locked once at a frame top, the identical
// periods mean it never drifts.
//
// HISTORY: this module originally ALSO derived 480i from the standard progressive
// main raster (the 2026-07-29 dual-raster "weave" mode: field A = even source
// lines of frame N, field B = odd lines of frame N+1, SKEW window (1716,1994)),
// so a CRT could get 480i while HDMI stayed progressive. That mode was DELETED
// 2026-09-02 (branch feature/video-output-consolidation): its field pairing vs
// the governor's frame holds was structurally unstable — a governor late re-scans
// one FRAME = an ODD +1 refresh that flips the pairing parity, at ~4 lates/s even
// on healthy content — and was field-reported as "extremely wobbly" on a real
// CRT. Fieldpass is immune (a late re-scans a field PAIR = even), so it became
// the only mode and the derive constants/muxes were removed. The full derive
// design lives in docs/analog_dual_raster.md (history) and git.

`include "timescale.v"
// An undeclared identifier becomes a compile ERROR, not a silent undriven net.
// Instituted after round 3 (2026-08-26): an edit deleted the cc_line declaration,
// Verilog created an implicit net, Quartus tied it to ground, and the whole
// caption chain went dead on hardware while every bench still passed.
`default_nettype none

module re_interlace (
    input             clk,          // clk_sys 27 MHz
    input             rst_n,
    input             ce2,          // free-running 13.5 MHz clock enable (ce_13m5)

    // quasi-static config
    input             enable,       // analog raster wanted AND the main raster is the fields raster
    input             pal,          // 1 = 576i params (864x312/313), 0 = 480i (858x262/263)

    // line-21 closed captions (dvd/cc_line21.sv) — the caption inserter lives here
    // because the line number and the field parity are properties of THIS raster's
    // modeline, and nothing outside should have to re-derive them.
    input             cc_enable,    // captions wanted (NTSC only — see cc_line below)
    input             cc_test,      // diagnostic: paint the caption waveform on a VISIBLE
                                    //   line instead of line 21, so it can be seen without
                                    //   a scope or a caption-capable TV
    input             cc_flush,     // seek / new title: drop the caption backlog
    input             dec_clk,      // clk_dec — the VLD's domain
    input             cc_pair_valid,
    input      [15:0] cc_pair,
    input             cc_pair_field,

    // main raster tap — the registered vga_*_q output stage plus its matching
    // coordinates (emu delays core_h_pos/core_v_pos/core_pixel_en 1 clk to align)
    input      [7:0]  in_r,
    input      [7:0]  in_g,
    input      [7:0]  in_b,
    input             in_de,
    input      [11:0] in_hpos,
    input      [11:0] in_vpos,

    // 15 kHz interlaced output (registered)
    output reg [7:0]  out_r,
    output reg [7:0]  out_g,
    output reg [7:0]  out_b,
    output reg        out_hs,
    output reg        out_vs,
    output reg        out_de,
    output            out_ce,       // 13.5 MHz CE aligned to the out_* registers
    output            locked,       // diagnostics: RUN state reached
    output            cc_active     // diagnostics: a caption pair is on the wire
);

// ---------------------------------------------------------------------------
// Static modeline parameters (byte-identical to the retired CRT branch of the
// runtime modeline walk = the PR #65 HW-CONFIRMED 480i raster; PAL by analogy,
// flagged for HW confirmation in docs/analog_dual_raster.md).
// ---------------------------------------------------------------------------
wire [11:0] p_hres = 12'd720;
wire [11:0] p_hss  = pal ? 12'd732 : 12'd735;
wire [11:0] p_hse  = pal ? 12'd795 : 12'd797;
wire [11:0] p_hlen = pal ? 12'd863 : 12'd857;   // 864 / 858 dots per line
wire [11:0] p_vres = pal ? 12'd575 : 12'd479;
wire [11:0] p_vss  = pal ? 12'd292 : 12'd244;
wire [11:0] p_vse  = pal ? 12'd295 : 12'd247;
wire [11:0] p_half = pal ? 12'd432 : 12'd429;   // horizontal_length/2 -> N64 model armed
wire [11:0] p_vlen = pal ? 12'd311 : 12'd261;   // SHORT field's last line index
wire [13:0] p_vsize= pal ? 14'd576 : 14'd480;

// Expected main-frame period in clk27 and arming skew.
//
// Source = the pixel-repeated fields raster: two fields of pixrep lines —
//   NTSC 1716 clk27/line x (262+263) lines = 900900;
//   PAL 1728 x (312+313) = 1080000. (frame_top pulses once per FRAME: v_pos =
//   {v_cntr, ~odd_field} is only 0 when v_cntr==0 AND odd_field==1.)
// The progressive raster's period (450450 / 540000) fails this check, which is
// exactly the mode-walk transient guard: during an il_switch walk the module
// stays unlocked until the fields raster is back.
localparam [20:0] PERIOD_FP_NTSC = 21'd900900;
localparam [20:0] PERIOD_FP_PAL  = 21'd1080000;
// Skew: source pixel (x, absolute line L) is written at (L>>1)*1716 + 2x
// relative to the frame top (field A emits L=0,2,4..., then field B L=1,3,5...), and
// our reader emits exactly the same line at the same offset + SKEW_FP. So every read
// trails its write by a CONSTANT SKEW_FP. Bounds:
//   read-after-write : SKEW_FP > 0
//   no-overwrite     : a 4-line slot is reused by absolute line L+4, i.e. 2 reader
//                      lines later => SKEW_FP + 2*719 < 2*1716  ==>  SKEW_FP < 1994
// SKEW_FP = 858 (one main line) centres the window with ~858 clk27 of margin either
// way. Proven pixel-exactly by bench/dvd/re_interlace_tb.sv scenario [6].
localparam [11:0] SKEW_FP        = 12'd858;
wire       [20:0] period_exp     = pal ? PERIOD_FP_PAL : PERIOD_FP_NTSC;
wire       [11:0] skew_sel       = SKEW_FP;

// ---------------------------------------------------------------------------
// Main-raster frame-top detect + period health check
// ---------------------------------------------------------------------------
wire frame_top = (in_vpos == 12'd0) && (in_hpos == 12'd0);
reg  frame_top_q;
always @(posedge clk) frame_top_q <= rst_n ? frame_top : 1'b0;
wire frame_top_p = frame_top & ~frame_top_q;    // one pulse per main frame

reg [20:0] per_cnt;
reg        per_good;                            // last completed interval was exact
always @(posedge clk) begin
    if (!rst_n) begin
        per_cnt  <= 21'd0;
        per_good <= 1'b0;
    end else if (frame_top_p) begin
        per_good <= (per_cnt == period_exp - 21'd1);
        per_cnt  <= 21'd0;
    end else if (!(&per_cnt)) begin
        per_cnt  <= per_cnt + 21'd1;            // saturate (timeout detector below)
    end
end
wire per_timeout = (per_cnt > period_exp + 21'd8192);

// ---------------------------------------------------------------------------
// Lock FSM: HUNT -> ARM -> RUN
// ---------------------------------------------------------------------------
localparam [1:0] S_HUNT = 2'd0, S_ARM = 2'd1, S_RUN = 2'd2;
reg [1:0]  state;
reg [11:0] skew_cnt;
reg        sg_rst_n;                            // sync_gen reset (active low)
reg        pal_q;

always @(posedge clk) begin
    pal_q <= pal;
    if (!rst_n) begin
        state    <= S_HUNT;
        skew_cnt <= 12'd0;
        sg_rst_n <= 1'b0;
    end else if (!enable || (pal != pal_q) || per_timeout) begin
        state    <= S_HUNT;
        sg_rst_n <= 1'b0;
    end else begin
        case (state)
            S_HUNT: begin
                sg_rst_n <= 1'b0;
                // arm off a frame top whose PRECEDING interval was exact
                if (frame_top_p && (per_cnt == period_exp - 21'd1)) begin
                    state    <= S_ARM;
                    skew_cnt <= skew_sel;
                end
            end
            S_ARM: begin
                if (skew_cnt == 12'd0) begin
                    sg_rst_n <= 1'b1;           // release: field A line 0 begins
                    state    <= S_RUN;
                end else begin
                    skew_cnt <= skew_cnt - 12'd1;
                end
            end
            S_RUN: begin
                // free-runs locked by construction; drop out only if the main
                // raster's geometry changes (period mismatch on any frame top)
                if (frame_top_p && (per_cnt != period_exp - 21'd1)) begin
                    state    <= S_HUNT;
                    sg_rst_n <= 1'b0;
                end
            end
            default: state <= S_HUNT;
        endcase
    end
end

assign locked = (state == S_RUN);

// ---------------------------------------------------------------------------
// Second raster generator — reuse the HW-proven N64-model syncgen verbatim
// ---------------------------------------------------------------------------
wire [11:0] sg_hpos, sg_vpos;
wire        sg_pixel_en, sg_hsync, sg_vsync;
wire        sg_csync_nc, sg_hblank_nc, sg_vblank_nc;

sync_gen sg2 (
    .clk                     (clk),
    .clk_en                  (ce2),
    .rst                     (sg_rst_n),
    .horizontal_size         (14'd720),
    .vertical_size           (p_vsize),
    .display_horizontal_size (14'd0),
    .display_vertical_size   (14'd0),
    .horizontal_resolution   (p_hres),
    .horizontal_sync_start   (p_hss),
    .horizontal_sync_end     (p_hse),
    .horizontal_length       (p_hlen),
    .vertical_resolution     (p_vres),
    .vertical_sync_start     (p_vss),
    .vertical_sync_end       (p_vse),
    .horizontal_halfline     (p_half),
    .vertical_length         (p_vlen),
    .interlaced              (1'b1),
    .clip_display_size       (1'b0),
    .h_pos                   (sg_hpos),
    .v_pos                   (sg_vpos),      // interlaced: ABSOLUTE source frame line
    .pixel_en                (sg_pixel_en),
    .h_sync                  (sg_hsync),
    .v_sync                  (sg_vsync),
    .c_sync                  (sg_csync_nc),
    .h_blank                 (sg_hblank_nc),
    .v_blank                 (sg_vblank_nc)
);

// ---------------------------------------------------------------------------
// 4-line buffer — ONE sync-read BRAM (4096x24, 1024 stride per line).
// Sync-read is mandatory (the parse_buf 226%-ALM LUT-RAM lesson).
// ---------------------------------------------------------------------------
reg [23:0] linebuf [0:4095];
reg [23:0] rd_q;

// The source line carries each pixel TWICE (pixel repetition), so keep the even dot
// of each pair and index by in_hpos>>1 — the buffer holds 720 native pixels per line,
// and the read port is untouched.
wire [9:0] wr_col = in_hpos[10:1];
wire       wr_en  = in_de & ~in_hpos[0];

always @(posedge clk) begin
    if (wr_en) linebuf[{in_vpos[1:0], wr_col}] <= {in_r, in_g, in_b};
    rd_q <= linebuf[{sg_vpos[1:0], sg_hpos[9:0]}];
end

// ---------------------------------------------------------------------------
// Line-21 closed captions
// ---------------------------------------------------------------------------
// WHERE LINE 21 IS. sync_gen already publishes everything needed, so nothing in
// syncgen.v changes: in interlaced mode v_pos = {v_cntr[10:0], ~odd_field}, so
// sg_vpos[11:1] IS the field-relative line counter and sg_vpos[0] is the field
// parity — both already aligned to sg_hpos through the same output pipeline.
//
// The line number derives two ways and they agree, which is the reason to trust
// it without a set in front of us:
//   * BY COUNT — NTSC line 21 is the 15th line after the vertical sync ends. Our
//     vsync window is [244,247), so lines 247..261 are that back porch and 261 is
//     its 15th. p_vlen (the short field's last line index) is exactly 261.
//   * BY POSITION — line 21 is the last VBI line before active video. v_cntr 261
//     is the last line before the counter wraps to 0 = the first active line.
// The long field carries its extra line at the end (eff_vertical_length 262), so
// 261 is the 15th line after vsync in BOTH fields — one constant covers both.
//
// WHICH FIELD — identified by SYNC TIMING, the way the television does, NOT by
// picture content. This mapping has now been wrong in both directions once each,
// so the full derivation stays here and bench/dvd/cc_field_map_tb.sv pins it by
// measuring what a TV measures (the vsync leading-edge alignment):
//
//   * SMPTE 170M: broadcast FIELD 1's vertical sync begins coincident with a
//     line boundary; FIELD 2's begins mid-line. That alignment is the ONLY thing
//     a TV uses to name the fields.
//   * In sync_gen, vs_ref_dot = odd_field ? 0 : halfline — the LINE-ALIGNED
//     vsync is emitted during odd_field==1, i.e. in the blanking AFTER the
//     TOP-content active lines. The 15 back-porch lines that follow it carry
//     v_pos[0] = ~odd_field = 0, and the active field after the wrap is BOTTOM
//     content. So broadcast field 1 = { line-aligned vsync, VBI with
//     v_pos[0]==0, BOTTOM active } — consistent with NTSC being
//     bottom-field-first (field 1 displays the bottom lines).
//   * CC1/CC2 (and T1/T2) ride FIELD 1's line 21, hence: transmit the field-1
//     slot on the v_pos[0]==0 VBI line -> cc_fld1 = ~sg_vpos[0].
//
// ⚠ THE TRAP (fell into it round 1): content parity does NOT identify the
// broadcast field. The DVD decoder-side labels (TOP field = "field 1" in the
// picture-coding sense) are about picture geometry; the TV's field 1 is about
// sync phase, and in this raster TOP content displays inside SYNC field 2.
// Round 1 "fixed" cc_fld1 to sg_vpos[0] on the content-based premise — flipping
// a correct mapping — and the DE-gate bug masked it. Round 2 on HW (CC Test
// Line fine, C1/C2/T1/T2 all empty — every one a FIELD-1 service) exposed it.
//
// CC_TEST moves the burst to a visible line near the top of the picture. The
// waveform is unchanged — same data, same rate, same levels — so what shows up is
// literally the caption bits: a band of dashes that CHANGES AS DIALOGUE CHANGES,
// and goes quiet when the disc sends null pairs. That distinguishes "extraction
// and pacing work, the TV just isn't decoding" from "no data is arriving" without
// a scope, which is otherwise impossible to tell apart from the sofa.
wire [11:0] cc_vline = cc_test ? 12'd20 : p_vlen;
wire        cc_line  = ~pal & (sg_vpos[11:1] == cc_vline);
wire        cc_fld1  = ~sg_vpos[0];
wire [7:0]  cc_level;
wire        cc_level_en;

cc_line21 cc (
    .clk            (clk),
    .rst_n          (rst_n),
    .ce2            (ce2),
    .dec_clk        (dec_clk),
    .dec_pair_valid (cc_pair_valid),
    .dec_pair       (cc_pair),
    .dec_pair_field (cc_pair_field),
    .enable         (cc_enable & ~pal),
    .flush          (cc_flush),
    .hpos           (sg_hpos),
    .cc_line        (cc_line),
    .field1         (cc_fld1),
    .level          (cc_level),
    .level_en       (cc_level_en),
    .active         (cc_active)
);

// ---------------------------------------------------------------------------
// Registered output stage (mirrors the main vga_*_q placement defense).
// sg2's outputs hold each pixel for 2 clk27; rd_q (1-clk BRAM latency) is
// stable by the NEXT ce2 tick, where the out_* registers latch pixel and syncs
// together (non-blocking: sg_* still hold the old pixel's values there).
// ---------------------------------------------------------------------------
wire run   = (state == S_RUN);
// Normally VBI-only so a mis-derived line number can never punch a hole in the
// picture; in test mode it deliberately paints over active video.
wire cc_on = run & cc_level_en & (cc_test | ~sg_pixel_en);

always @(posedge clk) begin
    if (!rst_n) begin
        out_r <= 8'd0; out_g <= 8'd0; out_b <= 8'd0;
        out_hs <= 1'b0; out_vs <= 1'b0; out_de <= 1'b0;
    end else if (ce2) begin
        // Captions ride the VBI, above the active region, so they never contend
        // with a picture pixel — but the mux is written caption-first anyway so a
        // mis-derived line number can only ever cost one blanking line, never
        // punch a hole in the image. Equal on R/G/B = luma-only, no chroma.
        out_r  <= cc_on ? cc_level : (run && sg_pixel_en) ? rd_q[23:16] : 8'd0;
        out_g  <= cc_on ? cc_level : (run && sg_pixel_en) ? rd_q[15:8]  : 8'd0;
        out_b  <= cc_on ? cc_level : (run && sg_pixel_en) ? rd_q[7:0]   : 8'd0;
        out_hs <= run ? sg_hsync : 1'b0;
        out_vs <= run ? sg_vsync : 1'b0;
        out_de <= run ? sg_pixel_en : 1'b0;
    end
end

// out_ce: one pulse per output pixel, on the cycle after the out_* registers
// update (outputs guaranteed stable when a ce_in consumer samples them).
reg ce2_q;
always @(posedge clk) ce2_q <= ce2;
assign out_ce = ce2_q;

endmodule

`default_nettype wire   // restore for any file compiled after this one
