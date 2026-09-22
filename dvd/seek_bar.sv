// ============================================================================
// dvd/seek_bar.sv -- Phase 11: position bar (scrub cursor + progress popup)
// ============================================================================
// Two duties on one renderer:
//
// 3. PROGRESS BAR (force_show): held up for a whole session by an audio-only
//    source (WAV / CD-DA), where there is no picture and this bar plus the
//    status line ARE the playback screen. Costs nothing extra -- the position
//    model below already resolves a linear file, because the reader publishes
//    the whole file as the title span and lin_blk as the playhead.
//
// 1. SCRUB FEEDBACK (core): the visual for the Phase-8a SEEK-ON-RELEASE scrub
//    (PR #101) -- while D-pad Left/Right is held the video is just paused, so
//    the only indication of where the release lands is this bar. scrub_ctrl
//    exports bar_base_rbn (playhead at hold start -> FILL), bar_tgt_rbn (the
//    accumulating target -> amber CURSOR) and bar_active (held + ~1.5 s
//    linger). Position model = sector/RBN against title_first_rbn..
//    title_last_rbn (docs/roadmap.md "Progress bar -- design").
//
// 2. PROGRESS POPUP with CHAPTER TICKS (stretch, severable): the bar also
//    pops on pause and for ~2.5 s after any landed seek/chapter skip
//    (show_evt), showing the LIVE playhead (cur_rbn fill, no cursor) with a
//    notch at each chapter start. Tick columns come from shadow copies of the
//    reader's program map (the existing pm_* stream) and cell first-sector
//    table (the new cellf_* stream tap): after each PGC load (pgc_loaded
//    rise) a converter walks pmap[p] -> cellf[pm-1] -> the shared divider ->
//    tick_col[p], once (~45 cycles per chapter). Dropping this stretch =
//    delete the shadow RAMs/converter/notch branch + the emu stream wires.
//
// 3. CHAPTER-SKIP PREVIEW (chap_prev/chap_pgm): B2/B3 chapter skips get the
//    SAME "where will this land" cursor as the scrub. emu already projects the
//    target chapter live through the ~500 ms multi-press debounce and holds it
//    until the reader lands (chap_disp_hold/_act, the HUD's "CH n/N" preview);
//    that chapter's START COLUMN is exactly tick_col[chap_pgm-1], already
//    computed for the notches -- so the preview costs no divider time and no
//    new math, just one more sync read port on the tick list. Without it the
//    bar sat frozen at the live playhead while the chapter number counted up,
//    so a multi-chapter skip gave no sense of where it was going.
//
// MATH (control path, off the display hotspot): ONE serial restoring divider
//   px = ((clamp(v) - first) << 9) / span        (0..512, 10 bits)
// alternates fill/cursor (~3 us per refresh, far faster than scrub_ctrl's
// ~0.06 s tick) and serves the tick conversion after a PGC load. No DSP.
//
// DISPLAY (hotspot rule): registered pipeline, pure function of (h_pos, v_pos)
// -- notches come out of a 512-BIT COLUMN BITMAP (one register, one indexed
// read), which is what replaced the old monotonic tick pointer when a PGC whose
// program order is not its physical order drew only one notch (2026-09-13).
// Geometry matches the HUD text box: a centred box, 512 px wide on a normal
// window and 256 on a narrow one, sitting between the popup row and the status
// line. Both modules take act_w_i and the same 544 knee, so they stay aligned.
// ============================================================================

module seek_bar #(
    parameter BAR_QX_ADJ = 4,               // pipeline lead (raster px)
    parameter POP_TICKS  = 27'd67_500_000   // ~2.5 s @ 27 MHz
)(
    input  wire        clk,                 // clk_sys
    input  wire        rst_n,

    // raster
    input  wire [11:0] h_pos,
    input  wire [11:0] v_pos,
    input  wire        pal_mode,
    // DVD-FORK (native 240p, 2026-09-14): the raster's ACTIVE HEIGHT, supplied rather
    // than derived. It was `pal_mode ? 576 : 480`, which is wrong on the 240p/288p
    // raster SIF content now gets -- everything anchored to it would sit off the
    // bottom of the screen. emu.sv owns the value; pal_mode is still used for the
    // things that really are per-STANDARD rather than per-raster.
    input  wire [11:0] act_h_i,
    // DVD-FORK (narrow DE window, 2026-09-14): the raster's ACTIVE WIDTH, same contract as
    // dvd/transport_hud.sv's -- h_pos space (pixel repetition already undone), owned by
    // emu.sv (act_w_eff). The bar shares the HUD's box, so it takes the same knee.
    input  wire [11:0] act_w_i,

    // scrub state (dvd/scrub_ctrl.sv)
    input  wire        bar_active,
    input  wire [31:0] base_rbn,            // fill while scrubbing
    input  wire [31:0] tgt_rbn,             // cursor while scrubbing
    input  wire [31:0] first_rbn,           // title span (reader)
    input  wire [31:0] last_rbn,

    // Level: keep the bar up for the whole session. Set for WAV/CD-DA, where
    // there is no picture and the bar IS the playback screen -- the same role
    // transport_hud's force_show plays for the status line. Still yields to
    // menu_active below, so it cannot fight the HLI layer.
    input  wire        force_show,

    // progress-popup state (stretch)
    // Visibility-only here (this module has no pause icon), so it is named for what it
    // MEANS rather than for the register it usually comes from: a pause the user started
    // with B1 keeps the bar up, a pause the FRAME STEP button started does not
    // (2026-09-17, by user decision). Feeding a masked value into a port called
    // `pause_q` would be a wrong fact on a correctly-named port -- the issue #81 class.
    input  wire        pause_vis,           // 1 = this pause holds the bar up
    input  wire        show_evt,            // landed seek / chapter / pause edge
    input  wire        menu_active,         // suppress in menus
    input  wire [31:0] cur_rbn,             // live playhead (nav_dsi)

    // chapter-tick feeds (stretch): reader streams during PGC parse
    input  wire        pgc_loaded,          // level; rise = new PGC parsed
    input  wire [7:0]  nr_pgm,
    input  wire        pm_we,               // program map: pmap[p] = entry cell (1-based)
    input  wire [6:0]  pm_waddr,
    input  wire [7:0]  pm_wdata,
    input  wire        cellf_we,            // cell first_sector stream tap
    input  wire [7:0]  cellf_idx,
    input  wire [31:0] cellf_rbn,

    // chapter-skip preview (emu's projected B2/B3 target, 1-based)
    input  wire        chap_prev,           // a chapter skip is pending/settling
    input  wire [7:0]  chap_pgm,            // projected target chapter

    // Level: never draw chapter notches or the chapter-skip cursor. Set on an
    // audio CD, whose bar spans ONE track. ⚠ It is a gate rather than relying
    // on nr_pgm = 0 because tick_ok is only rebuilt on a pgc_loaded RISE, which
    // a CD never produces -- so a DVD played earlier in the session would
    // otherwise leave ITS notches on the CD's bar.
    input  wire        ticks_off,

    // pixel out, REGISTERED (feeds emu's pre-blend register stage)
    output reg         bar_on,
    output reg  [7:0]  bar_r,
    output reg  [7:0]  bar_g,
    output reg  [7:0]  bar_b,
    output reg  [3:0]  bar_alpha
);

    // ---- geometry -----------------------------------------------------------
    // The bar is drawn 512 px wide when the window can hold it and 256 px wide when it
    // cannot, on the SAME 544 knee and the SAME centred box as dvd/transport_hud.sv -- the
    // two must stay aligned, which is why the constants are duplicated rather than each
    // module inventing its own rule. Only the DRAWN width changes: the bar's internal
    // column space stays 0..511 throughout (the divider, fill_px, cur_px and the 512-bit
    // tick bitmap are all untouched), and the narrow render samples it 2 columns at a time.
    localparam [11:0] HS2_MIN = 12'd544;    // 512 + a 16 px margin
    localparam [11:0] BAR_H   = 12'd10;
    // between the popup row (activeH-112..-81) and the status row (-64..-33)
    wire [11:0] y0 = act_h_i - 12'd78;

    // Registered box (quasi-static input; keeps the hotspot register-vs-register).
    // Reset to the 720 geometry so the first frame out of reset is the historical one.
    reg         hs2_q;                      // 1 = full 512 px bar
    reg  [11:0] x0_q, x1_q;                 // box left/right edge, in h_pos space
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs2_q <= 1'b1; x0_q <= 12'd104; x1_q <= 12'd616;
        end else begin
            hs2_q <= (act_w_i >= HS2_MIN);
            x0_q  <= ((act_w_i >= HS2_MIN) ? (act_w_i - 12'd512) : (act_w_i - 12'd256)) >> 1;
            x1_q  <= (((act_w_i >= HS2_MIN) ? (act_w_i - 12'd512) : (act_w_i - 12'd256)) >> 1)
                     + ((act_w_i >= HS2_MIN) ? 12'd512 : 12'd256);
        end
    end

    // ---- visibility ---------------------------------------------------------
    reg [26:0] pop_tmr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        pop_tmr <= 27'd0;
        else if (show_evt) pop_tmr <= POP_TICKS;
        else if (pop_tmr != 27'd0) pop_tmr <= pop_tmr - 27'd1;
    end
    wire vis = (force_show | bar_active | pause_vis | (pop_tmr != 27'd0)) && !menu_active;

    // ---- shadow maps + tick columns (stretch) -------------------------------
    reg [7:0]  pmap_ram  [0:127];           // program -> entry cell (1-based)
    reg [31:0] cellf_ram [0:255];           // cell -> first_sector RBN
    // 256, not 128: a PGC may carry up to 255 cells (the spec's cap and the
    // reader's MAXCELL), and 47 title PGCs in the library exceed 128 -- worst
    // 200. At 128 the index aliased and cell 128 overwrote cell 0's notch.
    reg [9:0]  tick_col  [0:99];            // converted notch columns, PROGRAM order
    // ★ ONE BIT PER BAR COLUMN. tick_col is written in PROGRAM order but holds
    //   PHYSICAL columns, so it is ascending only while a PGC's program order
    //   matches its physical order -- and on 51 of 958 library discs it does not.
    //   The renderer used to walk it with a single monotonic pointer, which on
    //   BIG_TROUBLE_LITTLE_CHINA (first program at the TOP of the disc, so
    //   chapter 1 converts to column ~511 and the rest to low columns) could
    //   never advance past entry 0: reported from the board as "only one chapter
    //   marker shows up". A bitmap has no order to get wrong. 512 flops, and it
    //   deletes the pointer, the lag guard and the per-line walk.
    reg [511:0] tick_bm;
    // registered read, aligned with s0_x (both take hx in the same stage)
    reg        tk_bit;
    always @(posedge clk) if (pm_we)    pmap_ram [pm_waddr]  <= pm_wdata;
    always @(posedge clk) if (cellf_we) cellf_ram[cellf_idx] <= cellf_rbn;

    reg [6:0]  pm_raddr_b;
    reg [7:0]  pm_q_b;
    reg [6:0]  cf_raddr_b;
    reg [31:0] cf_q_b;
    always @(posedge clk) begin
        pm_q_b <= pmap_ram [pm_raddr_b];
        cf_q_b <= cellf_ram[cf_raddr_b];
    end

    // ---- serial divider (shared: fill / cursor / tick conversion) ----------
    wire [31:0] span = (last_rbn > first_rbn) ? (last_rbn - first_rbn) : 32'd1;

    localparam [1:0] DV_FILL = 2'd0, DV_CUR = 2'd1, DV_TICK = 2'd2;
    reg  [1:0]  dv_mode;
    reg  [5:0]  dv_i;                       // 46=sched, 45..42=tick reads, 41..1=divide, 0=publish
    reg  [40:0] dv_n;                       // numerator shifter (32+9 bits)
    reg  [32:0] dv_rem;
    reg  [9:0]  dv_q;
    reg  [9:0]  fill_px, cur_px;            // published results (0..512)
    reg         pgc_q, tk_pend, tick_ok;
    reg  [6:0]  tk_p, tick_n;

    // fill = live playhead unless a scrub gesture owns the bar
    wire [31:0] fill_v   = bar_active ? base_rbn : cur_rbn;
    wire [31:0] dv_v     = (dv_mode == DV_TICK) ? cf_q_b :
                           (dv_mode == DV_CUR)  ? tgt_rbn : fill_v;
    wire [31:0] dv_delta = (dv_v <= first_rbn) ? 32'd0 :
                           (dv_v >= last_rbn)  ? span  : (dv_v - first_rbn);
    wire [32:0] dv_rem_n = {dv_rem[31:0], dv_n[40]};
    wire        dv_ge    = (dv_rem_n >= {1'b0, span});
    wire [9:0]  dv_qcap  = (dv_q > 10'd512) ? 10'd512 : dv_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dv_mode <= DV_FILL; dv_i <= 6'd46; dv_n <= 41'd0; dv_rem <= 33'd0;
            dv_q <= 10'd0; fill_px <= 10'd0; cur_px <= 10'd0;
            pgc_q <= 1'b0; tk_pend <= 1'b0; tick_ok <= 1'b0;
            tk_p <= 7'd0; tick_n <= 7'd0;
            pm_raddr_b <= 7'd0; cf_raddr_b <= 7'd0;
        end else begin
            pgc_q <= pgc_loaded;
            if (pgc_loaded && !pgc_q) begin
                // fresh PGC: re-run the tick conversion once the maps settled.
                // ★ Clearing 512 bits is ONE cycle because this is a register and
                //   not a memory -- which is most of why it is a register.
                tick_bm <= 512'd0;
                tk_pend <= 1'b1;
                tick_ok <= 1'b0;
                tk_p    <= 7'd0;
                tick_n  <= (nr_pgm > 8'd100) ? 7'd100 : nr_pgm[6:0];
            end

            case (dv_i)
                6'd46: begin
                    // schedule the next job (tk_p/tick_n settled here)
                    if (tk_pend && tk_p < tick_n) begin
                        dv_mode    <= DV_TICK;
                        pm_raddr_b <= tk_p;
                        dv_i       <= 6'd45;
                    end else begin
                        if (tk_pend) begin tk_pend <= 1'b0; tick_ok <= (tick_n != 7'd0); end
                        dv_mode <= (dv_mode == DV_FILL) ? DV_CUR : DV_FILL;
                        dv_i    <= 6'd42;      // straight to load
                    end
                end
                6'd45: dv_i <= 6'd44;                       // pm_q_b settling
                6'd44: begin
                    cf_raddr_b <= (pm_q_b != 8'd0) ? (pm_q_b[6:0] - 7'd1) : 7'd0;
                    dv_i       <= 6'd43;
                end
                6'd43: dv_i <= 6'd42;                       // cf_q_b settling
                6'd42: begin
                    // load the numerator (dv_v routed by dv_mode)
                    dv_n   <= {dv_delta, 9'd0};
                    dv_rem <= 33'd0;
                    dv_q   <= 10'd0;
                    dv_i   <= 6'd41;
                end
                6'd0: begin
                    case (dv_mode)
                        DV_FILL: fill_px <= dv_qcap;
                        DV_CUR:  cur_px  <= dv_qcap;
                        default: begin
                            tick_col[tk_p] <= dv_qcap;
                            // the notch is 2 px, so light both columns here and
                            // let the renderer test a single bit.
                            if (dv_qcap <= 10'd511) tick_bm[dv_qcap[8:0]] <= 1'b1;
                            if (dv_qcap <= 10'd510) tick_bm[dv_qcap[8:0] + 9'd1] <= 1'b1;
                            tk_p <= tk_p + 7'd1;
                        end
                    endcase
                    dv_i <= 6'd46;
                end
                default: begin                              // 41..1: divide
                    dv_rem <= dv_ge ? (dv_rem_n - {1'b0, span}) : dv_rem_n;
                    dv_n   <= {dv_n[39:0], 1'b0};
                    dv_q   <= {dv_q[8:0], dv_ge};           // low 10 bits suffice
                    dv_i   <= dv_i - 6'd1;
                end
            endcase
        end
    end

    // ---- chapter-skip preview cursor ----------------------------------------
    // The projected chapter's start column is tick_col[chap_pgm-1] (already
    // converted for the notches), so this is a second sync read port on that
    // list plus a register -- no divider job, no extra arithmetic. The address
    // only moves at button-press rate, so the 3-cycle read latency is invisible.
    // Falls silent when the tick list isn't available (tick_ok = 0, e.g. linear
    // .VOB playback), and the scrub always wins the cursor if both are up.
    wire [7:0] ch_idx0 = (chap_pgm != 8'd0) ? (chap_pgm - 8'd1) : 8'd0;
    reg  [6:0] ch_raddr;
    reg  [9:0] ch_tk_q, chap_px;
    always @(posedge clk) begin
        ch_raddr <= ch_idx0[6:0];
        ch_tk_q  <= tick_col[ch_raddr];
        chap_px  <= ch_tk_q;
    end
    wire tick_show = tick_ok & ~ticks_off;
    wire chap_cur = chap_prev && tick_show && (chap_pgm != 8'd0) &&
                    (chap_pgm <= {1'b0, tick_n});

    // Selected cursor (registered, event-rate) so the display path keeps its
    // flat register->compare shape in the hotspot.
    reg  [9:0] curc_q;
    reg        curs_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            curc_q <= 10'd0;
            curs_q <= 1'b0;
        end else begin
            curc_q <= bar_active ? cur_px : chap_px;
            curs_q <= bar_active | chap_cur;
        end
    end

    // ---- pixel pipeline ------------------------------------------------------
    wire [11:0] hq  = h_pos + BAR_QX_ADJ[11:0];
    wire [11:0] hx  = hq - x0_q;            // 0 .. drawn width - 1
    wire        inx = (hq >= x0_q) && (hq < x1_q);
    wire [11:0] vy  = v_pos - y0;
    wire        iny = (v_pos >= y0) && (v_pos < y0 + BAR_H);
    // drawn pixel -> bar column (0..511). At the narrow pitch one drawn pixel covers a
    // column PAIR, so a notch renders 1 px and the cursor 3 px instead of 2 and 5.
    wire [9:0]  hcol = hs2_q ? hx[9:0] : {hx[8:0], 1'b0};
    wire [11:0] hlast = hs2_q ? 12'd511 : 12'd255;   // rightmost DRAWN pixel

    // ⚠ The narrow read must be the ODD SIBLING of the same column (hcol | 1), not a
    // shifted index -- a notch is written as a column PAIR {c, c+1}, so reading only the
    // even column of each drawn pixel would drop every notch whose pair starts odd. (It
    // also keeps a notch written at column 511, which no even sample can reach.) A notch
    // therefore renders 1 px when its pair starts even and 2 px when it starts odd.
    always @(posedge clk) tk_bit <= tick_bm[hcol[8:0]] |
                                    (~hs2_q & tick_bm[hcol[8:0] | 9'd1]);

    // A: hit-test + local coords
    reg       s0_in, s0_edge, s0_low;
    reg [9:0] s0_x;
    // B (output): compare against fill/cursor/tick
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_in <= 1'b0; s0_edge <= 1'b0; s0_low <= 1'b0; s0_x <= 10'd0;
            bar_on <= 1'b0; bar_r <= 8'd0; bar_g <= 8'd0; bar_b <= 8'd0;
            bar_alpha <= 4'd0;
        end else begin
            s0_in   <= vis && inx && iny;
            s0_edge <= (vy == 12'd0) || (vy == BAR_H - 12'd1) ||
                       (hx == 12'd0) || (hx == hlast);
            s0_low  <= (vy >= BAR_H/2);
            s0_x    <= hcol;

            bar_on    <= s0_in;
            bar_alpha <= 4'd0;
            bar_r <= 8'd0; bar_g <= 8'd0; bar_b <= 8'd0;
            if (s0_in) begin
                if (curs_q &&
                    s0_x >= (curc_q < 10'd2 ? 10'd0 : curc_q - 10'd2) &&
                    s0_x <= curc_q + 10'd2) begin
                    // seek target / chapter-skip target cursor: 5 px, opaque amber
                    bar_r <= 8'hFF; bar_g <= 8'hC8; bar_b <= 8'h20;
                    bar_alpha <= 4'd15;
                end else if (tick_show && s0_low && tk_bit) begin

                    // chapter notch: 2 px, lower half
                    bar_r <= 8'hE8; bar_g <= 8'hE8; bar_b <= 8'hE8;
                    bar_alpha <= 4'd14;
                end else if (s0_edge) begin
                    bar_r <= 8'hE0; bar_g <= 8'hE0; bar_b <= 8'hE0;
                    bar_alpha <= 4'd12;             // track border
                end else if (s0_x < fill_px) begin
                    bar_r <= 8'hFF; bar_g <= 8'hFF; bar_b <= 8'hFF;
                    bar_alpha <= 4'd10;             // played portion
                end else begin
                    bar_alpha <= 4'd7;              // remaining: dark backing
                end
            end
        end
    end

endmodule
