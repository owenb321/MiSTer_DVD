// re_interlace.sv — DVD-FORK (dual-raster analog output, 2026-07-29)
//
// Progressive -> native 15 kHz 2:1-interlaced scan converter ("re-interlacer").
//
// WHY: the core's main raster stays progressive (480p/576p @ 27 MHz CE=1) for
// ascal/HDMI quality, but a real CRT on the analog I/O board needs broadcast
// 480i/576i (alternating 262/263 or 312/313 field totals with the half-line
// vsync). Instead of mode-switching the whole core (the retired O[14] CRT mode),
// this module derives a SECOND, simultaneous raster from the main one:
//
//   main raster (720x480p/576p, 27 MHz, CE=1, tapped at the registered vga_*_q
//   output stage) --> 4-line sync-read BRAM --> second sync_gen instance
//   (rtl/mpeg2/syncgen.v, the HW-proven N64-model half-line machinery, clk_en =
//   13.5 MHz CE) --> registered out_* --> sys_top VGA2_* --> direct analog chain.
//
// TIMING (the whole trick): one interlaced line = 858 dots @ 13.5 MHz = 1716
// clk27 = exactly TWO progressive lines, and two fields (262+263 lines NTSC,
// 312+313 PAL) = exactly TWO main frames (900900 / 1080000 clk27). So a single
// arming alignment at a main frame top stays phase-locked FOREVER by
// construction — one field is emitted per main frame, field A (even source
// lines) from frame N, field B (odd source lines) from frame N+1.
//
// SKEW derivation (frame-top-relative clk27 units; source line L pixel x is
// written at L*858 + x because the frame-top detector and the writes ride the
// same in_hpos/in_vpos stream):
//   field A (released at +SKEW): reads line L=2k at SKEW + L*858 + 2x
//     -> read-after-write margin = SKEW + x  (always fine)
//     -> slot L%4 overwritten by line L+4 at L*858+3432; last read at
//        SKEW + L*858 + 2*719  ==> SKEW < 3432 - 1438 = 1994
//   field B starts one main line EARLY relative to frame N+1's top (field A is
//   262 lines = 449592 clk27 = one main frame MINUS 858): reads line L=2k+1 at
//   SKEW - 1716 + L*858 + 2x
//     -> read-after-write: SKEW - 1716 + x > 0 ==> SKEW > 1716
//   ==> SKEW in (1716, 1994); the read-side pipeline (sync_gen 3 stages @ ce2 +
//   BRAM reg = ~7 clk27, constant) shifts both bounds down by the same amount.
//   SKEW = 1848 centers the window; re_interlace_tb's pixel-exact content check
//   is the proof (it fails outside the window).
//
// LOCK FSM: HUNT (sync_gen held in reset, outputs blank/no syncs) -> ARM (skew
// countdown from a verified main frame top) -> RUN (free-run; locked=1). The
// main raster is health-checked by PERIOD, not coordinates: consecutive frame
// tops must be exactly 450450 (NTSC) / 540000 (PAL) clk27 apart. Any other main
// raster (Film-24p 23.976 Hz, HDMI-480i pixrep, mid-walk garbage) fails the
// check and the module simply stays unlocked — self-protecting. pal/enable
// changes and a frame-top timeout also drop to HUNT.
//
// v1 caveat (progressive-derive path only): for true-interlaced (weave-decoded)
// content the field pairing vs the governor's frame hold is not phase-guaranteed.
// It is WORSE than "a drop/late can swap it until the next slip": a governor LATE
// re-scans one FRAME image = +1 refresh = an ODD hold, which flips the pairing
// parity, and lates run at ~4/s even on healthy content (docs/lipsync_pickup.md).
// So the pairing is re-randomised several times a second and cannot be fixed by
// arming on a picture flip. See docs/analog_dual_raster.md caveat 2.
//
// FIELD PASSTHROUGH (`fieldpass`, Analog Out = Native Fields) is the structural fix:
// the decoder is put in native-fields mode (il_eff), so resample_addrgen emits
// authored TOP/BOTTOM field images in top_field_first order with the true rff 3:2
// field cadence. Every displayed refresh is then one genuine field of exactly one
// picture, so there is no "pairing" to get wrong, and a late re-scans a FIELD PAIR
// (+2 refreshes = even) so governor churn is parity-neutral by construction.
//
// In that mode this module degenerates to a RE-TIMER. The source raster is the
// pixel-repeated interlaced raster (1716 clk27/line, field totals alternating
// 262/263 exactly as ours do), so source and local rasters have IDENTICAL line and
// field structure and every source pixel is read exactly SKEW_FP after it is
// written — a constant, uniform skew. Two differences only: the source carries
// 2 dots per pixel (decimated on the write port) and samples vsync at dot 0 in both
// fields (no half-line — HDMI uses VGA_F1 instead), while our local sync_gen adds
// the half-line the CRT needs. That is why the main raster does NOT need a
// half-line: putting one there would expose HDMI to the ff01ac8 receiver-hunting
// issue for no gain.

`include "timescale.v"

module re_interlace (
    input             clk,          // clk_sys 27 MHz
    input             rst_n,
    input             ce2,          // free-running 13.5 MHz clock enable (ce_13m5)

    // quasi-static config
    input             enable,       // analog raster wanted AND the main raster is the expected one
    input             pal,          // 1 = 576i params (864x312/313), 0 = 480i (858x262/263)
    input             fieldpass,    // 1 = main raster is the pixrep INTERLACED fields raster (re-time
                                    //     1:1); 0 = standard progressive raster (derive fields)

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
    output            locked        // diagnostics: RUN state reached
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
// Progressive source: 858x525 / 864x625 dots at CE=1.
// Fieldpass source:   the SAME total dots per frame, redistributed as two fields of
//   pixel-repeated lines — NTSC 1716 clk27/line x (262+263) lines = 900900;
//   PAL 1728 x (312+313) = 1080000. (frame_top still pulses once per FRAME: v_pos =
//   {v_cntr, ~odd_field} is only 0 when v_cntr==0 AND odd_field==1.)
localparam [20:0] PERIOD_NTSC    = 21'd450450;
localparam [20:0] PERIOD_PAL     = 21'd540000;
localparam [20:0] PERIOD_FP_NTSC = 21'd900900;
localparam [20:0] PERIOD_FP_PAL  = 21'd1080000;
localparam [11:0] SKEW           = 12'd1848;    // progressive-derive: window (1716,1994)
// Fieldpass skew: source pixel (x, absolute line L) is written at (L>>1)*1716 + 2x
// relative to the frame top (field A emits L=0,2,4..., then field B L=1,3,5...), and
// our reader emits exactly the same line at the same offset + SKEW_FP. So every read
// trails its write by a CONSTANT SKEW_FP. Bounds:
//   read-after-write : SKEW_FP > 0
//   no-overwrite     : a 4-line slot is reused by absolute line L+4, i.e. 2 reader
//                      lines later => SKEW_FP + 2*719 < 2*1716  ==>  SKEW_FP < 1994
// SKEW_FP = 858 (one main line) centres the window with ~858 clk27 of margin either
// way. Proven pixel-exactly by bench/dvd/re_interlace_tb.sv scenario [6].
localparam [11:0] SKEW_FP        = 12'd858;
wire       [20:0] period_exp     = fieldpass ? (pal ? PERIOD_FP_PAL : PERIOD_FP_NTSC)
                                             : (pal ? PERIOD_PAL    : PERIOD_NTSC);
wire       [11:0] skew_sel       = fieldpass ? SKEW_FP : SKEW;

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

// Fieldpass: the source line carries each pixel TWICE (pixel repetition), so keep the
// even dot of each pair and index by in_hpos>>1 — the buffer always holds 720 native
// pixels per line in both modes, and the read port is untouched.
wire [9:0] wr_col = fieldpass ? in_hpos[10:1] : in_hpos[9:0];
wire       wr_en  = in_de & (fieldpass ? ~in_hpos[0] : 1'b1);

always @(posedge clk) begin
    if (wr_en) linebuf[{in_vpos[1:0], wr_col}] <= {in_r, in_g, in_b};
    rd_q <= linebuf[{sg_vpos[1:0], sg_hpos[9:0]}];
end

// ---------------------------------------------------------------------------
// Registered output stage (mirrors the main vga_*_q placement defense).
// sg2's outputs hold each pixel for 2 clk27; rd_q (1-clk BRAM latency) is
// stable by the NEXT ce2 tick, where the out_* registers latch pixel and syncs
// together (non-blocking: sg_* still hold the old pixel's values there).
// ---------------------------------------------------------------------------
wire run = (state == S_RUN);

always @(posedge clk) begin
    if (!rst_n) begin
        out_r <= 8'd0; out_g <= 8'd0; out_b <= 8'd0;
        out_hs <= 1'b0; out_vs <= 1'b0; out_de <= 1'b0;
    end else if (ce2) begin
        out_r  <= (run && sg_pixel_en) ? rd_q[23:16] : 8'd0;
        out_g  <= (run && sg_pixel_en) ? rd_q[15:8]  : 8'd0;
        out_b  <= (run && sg_pixel_en) ? rd_q[7:0]   : 8'd0;
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
