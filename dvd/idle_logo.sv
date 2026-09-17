// ============================================================================
// idle_logo.sv -- bouncing-logo idle screen (launch-feedback, 2026-08-26)
//
// Shown while no disc image is mounted (emu gates `vis`): a 1-bpp logo mask,
// rendered 2x (max 256x64 on screen), DVD-screensaver-bouncing inside the
// active raster. Design: docs/idle_screen.md. Structural template:
// dvd/seek_bar.sv's (x,y)-pure registered pipeline; ROM init pattern:
// dvd/transport_hud.sv's $readmemh glyph ROM.
//
// ROM = FOUR M10K, 2048 x 16, TWO BANKS (resolution x4, 2026-08-26 -- the
// original 1-M10K/128x32 budget predated the area-reclaim pass):
//   bank 0 (words    0..1023): built-in default (tools/idle_logo.py), up to
//     256x64, displayed NATIVE (1x) -- same on-screen size as the old
//     103x29-at-2x default at double the detail.
//   bank 1 (words 1024..2047): user bitmap, streamed at core load from
//     /media/fat/games/DVD/boot.rom via ioctl (index 0, the framework's
//     zero-CONF_STR boot.rom convention). The write port is HARD-GATED to
//     bank 1 ({1'b1, wa[9:0]}), so no file -- valid, corrupt, truncated or
//     hostile -- can ever touch the default: the never-garbage guarantee is
//     structural, not procedural. tools/idle_logo.py initialises bank 1 as a
//     copy of bank 0, so even a stuck bank select shows the default.
//
// Two boot.rom formats (byte 6): 0x01 = 256x64-capable, dims stored MINUS
// ONE, 32-byte row stride, flags bit1 selects 1x (native) vs 2x display
// scale; 0x00 = the original 128x32 / 16-byte-stride layout, accepted for
// back-compat and always displayed 2x. The bounce box is the DISPLAYED size.
//
// Word address = {bank, row[5:0], col[7:4]}; bit = word[15 - col[3:0]]
// (MSB = leftmost pixel, the hud_font convention). Pure concatenation + a
// 16:1 mux -- no arithmetic in the display hotspot.
//
// ⚠ TRAPS baked into this file (do not "clean up"):
//  - The $readmemh contents load at FPGA CONFIGURATION, not at core reset.
//    Every register describing the ROM contents (logo_valid, u_w, u_h,
//    colour, speed) therefore has NO reset term -- power-up init only --
//    or an OSD Reset would desync geometry from bitmap and render garbage.
//    (Precedent: emu.sv's entropy_ctr.)
//  - (* ramstyle = "M10K, no_rw_check" *) is LOAD-BEARING: without it
//    Quartus 17 may infer MLAB for a 512-deep memory and silently drop the
//    $readmemh init (see dvd/spu_decode.sv for the precedent).
//  - The file length is only knowable at download END (hps_io carries no
//    size up front), so a truncated good-header file WILL have part-written
//    bank 1 -- the commit rule (exact length match) then drops logo_valid
//    and bank 0 renders, bit-identical to a fresh boot.
//  - last_addr is tracked locally on ioctl_wr: sampling ioctl_addr at the
//    falling edge of ioctl_download races hps_io's same-cycle update.
//  - frame_tick (emu's av_refresh_tick) is per-FIELD when interlaced, and the
//    logo now moves on EVERY tick (2026-09-03, user decision after HW round 1 of
//    the single-raster analog build: "the logo is slower in Interlaced"). The
//    earlier fld_tog divider halved it so the two fields of a frame sampled one
//    position (no edge comb on a woven frame); the cost was half-speed motion on
//    the CRT for a one-pixel comb nobody sees on a bouncing logo. Per-field
//    motion is what an interlaced camera pan looks like. il_mode is kept as a
//    port (unused) so emu's wiring and the bench stay put.
//  - LOGO_QX_LEAD is a SUBTRACTED horizontal lead, like the subpicture's
//    SP_QX_ADJ and UNLIKE the HUD/seek-bar's added constants. ⚠ HW round 3
//    (2026-08-26) disproved this file's original "needs no calibration"
//    claim: the raster counter LEADS the RGB datapath, so an overlay
//    queried at h_pos renders LEFT of the screen window -- invisible for
//    the centred HUD/bar boxes, but the logo's wall-bounce exposed it as a
//    symmetric left-overlap/right-gap (~16 px: the +4 sign error plus the
//    12-px uncompensated lead). Value transposed from the HW-calibrated
//    SP_QX_ADJ=13 (subpic query path = 3 regs, this one = 4, so 13-1=12);
//    residual +/-1-2 px would need an HW trim exactly like SP_QX_ADJ's.
//
// boot.rom format ("MDL1", 16-byte header + h rows x 16 bytes 1-bpp
// MSB-first): see tools/idle_logo.py's docstring -- the tool is the format's
// reference implementation and converts PNGs (--png in.png --out boot.rom).
// ============================================================================

module idle_logo #(
    parameter [11:0] LOGO_QX_LEAD = 12'd12  // subtracted; see the ⚠ note above
) (
    input  wire        clk,               // clk_sys 27 MHz
    input  wire        rst_n,             // pixel pipeline + motion ONLY (see traps)

    // raster query (same taps as seek_bar/transport_hud)
    input  wire [11:0] h_pos,             // ov_h_gen (interlace-x2-inverse x)
    input  wire [11:0] v_pos,             // core_v_pos
    input  wire        pal_mode,          // pal_eff: 576-line active area
    // DVD-FORK (native 240p, 2026-09-14): the raster's ACTIVE HEIGHT, supplied rather
    // than derived. It was `pal_mode ? 576 : 480`, which is wrong on the 240p/288p
    // raster SIF content now gets -- everything anchored to it would sit off the
    // bottom of the screen. emu.sv owns the value; pal_mode is still used for the
    // things that really are per-STANDARD rather than per-raster.
    input  wire [11:0] act_h_i,
    // DVD-FORK (narrow DE window, 2026-09-14): the raster's ACTIVE WIDTH, same contract
    // as act_h_i (h_pos space, owned by emu.sv as act_w_eff). The bounce box was a literal
    // 720 wide, so on the PROGRESSIVE output a VCD (352) or SVCD (480) let the logo wander
    // hundreds of pixels off the right of the picture -- and the logo is NOT idle-only:
    // the screensaver and Stop both show it over a mounted title.
    input  wire [11:0] act_w_i,
    input  wire        il_mode,           // il_eff: frame_tick is per-field
    input  wire        frame_tick,        // av_refresh_tick (one per v_sync)
    input  wire        vis,               // emu's logo_vis gate
    input  wire [31:0] entropy,           // emu's entropy_ctr (free-running)
    // Fine-tune the bounce trajectory and step the palette. One-cycle pulse, driven
    // from the Angle button while nothing is mounted (emu: angle_edge &&
    // !media_seen), where all three of that edge's real consumers are inert.
    // Latched into nudge_pend because this module only does work on a frame tick.
    input  wire        nudge,

    // user bitmap delivery (boot.rom -> ioctl, index 0)
    input  wire        ioctl_download,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,
    input  wire  [7:0] ioctl_dout,
    input  wire [15:0] ioctl_index,

    // registered pixel out -> emu's overlay priority mux (alpha is a
    // constant 15 there: opaque passthrough through subpic_blend)
    output reg         logo_on,
    output reg  [7:0]  logo_r,
    output reg  [7:0]  logo_g,
    output reg  [7:0]  logo_b
);

// ---------------------------------------------------------------------------
// Logo ROM -- one M10K, two banks (see header)
// ---------------------------------------------------------------------------
(* ramstyle = "M10K, no_rw_check" *) reg [15:0] logo_rom [0:2047];
initial $readmemh("dvd/idle_logo.mem", logo_rom);

// ---------------------------------------------------------------------------
// ioctl receive: header parse + bank-1 write + commit.
// ⚠ NO reset terms anywhere in this section (trap #1 above).
// ---------------------------------------------------------------------------
// Power-up geometry = the DEFAULT art's trimmed bounding box, reported by
// tools/idle_logo.py when it writes idle_logo.mem (idle_logo_tb asserts the
// two stay in sync). The bounce box is exactly the declared w x h, so any
// mask margin bounces early on that side -- HW round 2: the untrimmed
// 128-wide default had a 22-column right margin = a 44 px early right
// bounce ("bounces well before the border"); the tool now trims all art.
localparam [8:0] DEF_W = 9'd201;       // native (1x-displayed) default
localparam [6:0] DEF_H = 7'd58;

reg        logo_valid = 1'b0;          // bank select: 1 = user bitmap
reg  [8:0] u_w   = DEF_W;              // committed geometry, MASK pixels
reg  [6:0] u_h   = DEF_H;
reg        u_scale1x = 1'b1;           // 1 = native, 0 = classic 2x
reg        u_fixcol = 1'b0;
reg  [7:0] u_r = 8'd0, u_g = 8'd0, u_b = 8'd0;
reg  [7:0] u_spd = 8'd0;               // committed speed byte (0 = defaults)

reg        dl_prev = 1'b0, idx0_q = 1'b0;
reg        m_ok = 1'b0, fok = 1'b0;
reg        fmt1_s = 1'b0;              // format byte 0x01 (else legacy 0x00)
reg  [7:0] w_raw = 8'd0;               // header bytes AS STORED (the format
reg  [7:0] h_raw = 8'd0;               // byte arrives after them, so dims
                                       // are interpreted at use time)
reg        fixcol_s = 1'b0;
reg        scale1x_s = 1'b0;
reg  [7:0] r_s = 8'd0, g_s = 8'd0, b_s = 8'd0, spd_s = 8'd0;
reg  [7:0] ld_hi = 8'd0;               // even payload byte (word high half)
reg        pix_over = 1'b0;
reg [26:0] last_addr = 27'd0;

wire        dl_here  = ioctl_download & idx0_q;
// effective dims: fmt-1 stores minus-one (256/64 fit a byte); fmt-0 as-is
wire  [8:0] w_eff    = fmt1_s ? ({1'b0, w_raw} + 9'd1) : {1'b0, w_raw};
wire  [6:0] h_eff    = fmt1_s ? ({1'b0, h_raw[5:0]} + 7'd1) : h_raw[6:0];
wire        dims_ok  = fmt1_s ? (h_raw <= 8'd63)             // w always 1..256
                              : ((w_raw >= 8'd1) && (w_raw <= 8'd128) &&
                                 (h_raw >= 8'd1) && (h_raw <= 8'd32));
wire        hdr_ok   = m_ok & fok & dims_ok;
wire        hdr_ph   = (ioctl_addr[26:4] == 23'd0);          // bytes 0..15
// payload byte index + per-format word address (fmt-0 rows are 16 bytes =
// 8 words, packed at 16-word row stride with the upper 8 words untouched --
// those columns are beyond fmt-0's 128-px width and never rendered)
wire [26:0] pb       = ioctl_addr - 27'd16;
wire  [9:0] pay_wa   = fmt1_s ? pb[10:1]
                              : {1'b0, pb[8:4], 1'b0, pb[3:1]};
wire        over_now = fmt1_s ? (pb >= 27'd2048) : (pb >= 27'd512);
wire        rom_we   = ioctl_wr & dl_here & hdr_ok & ~hdr_ph &
                       ioctl_addr[0] & ~over_now;
wire [26:0] want_len = fmt1_s ? ({15'd0, h_eff, 5'd0} + 27'd16)   // 32*h+16
                              : ({16'd0, h_eff, 4'd0} + 27'd16);  // 16*h+16

always @(posedge clk) begin
    dl_prev <= ioctl_download;

    if (ioctl_download & ~dl_prev) begin
        // download start: hps_io latches ioctl_index BEFORE raising download
        idx0_q    <= (ioctl_index == 16'd0);
        m_ok      <= 1'b0; fok <= 1'b0; fmt1_s <= 1'b0;
        w_raw     <= 8'd0; h_raw <= 8'd0;
        pix_over  <= 1'b0;
        last_addr <= 27'd0;
    end

    if (ioctl_wr & dl_here) begin
        last_addr <= ioctl_addr;
        if (hdr_ph) case (ioctl_addr[3:0])
            4'd0:  m_ok <= (ioctl_dout == 8'h4D);            // 'M'
            4'd1:  m_ok <= m_ok & (ioctl_dout == 8'h44);     // 'D'
            4'd2:  m_ok <= m_ok & (ioctl_dout == 8'h4C);     // 'L'
            4'd3:  m_ok <= m_ok & (ioctl_dout == 8'h31);     // '1'
            4'd4:  w_raw <= ioctl_dout;                      // interpreted at
            4'd5:  h_raw <= ioctl_dout;                      // use (see w_eff)
            4'd6:  begin fok <= (ioctl_dout <= 8'd1);        // fmt 0 or 1
                         fmt1_s <= ioctl_dout[0]; end
            4'd7:  begin fixcol_s <= ioctl_dout[0];
                         scale1x_s <= ioctl_dout[1]; end
            4'd8:  r_s <= ioctl_dout;
            4'd9:  g_s <= ioctl_dout;
            4'd10: b_s <= ioctl_dout;
            4'd11: spd_s <= ioctl_dout;
            default: ;                                       // 12..15 reserved
        endcase
        else begin
            if (~ioctl_addr[0]) ld_hi <= ioctl_dout;
            if (over_now)       pix_over <= 1'b1;
        end
    end

    if (rom_we) logo_rom[{1'b1, pay_wa}] <= {ld_hi, ioctl_dout};

    // commit at download end. A GOOD-header download decides logo_valid
    // (truncated/oversized -> 0, bank 1 is part-written -> default renders);
    // a BAD-header download wrote nothing -> keep the previous state (a
    // stray boot.rom must not brick an already-good logo).
    if (~ioctl_download & dl_prev & idx0_q) begin
        if (hdr_ok) begin
            if (~pix_over && ((last_addr + 27'd1) == want_len)) begin
                logo_valid <= 1'b1;
                u_w <= w_eff; u_h <= h_eff;
                u_scale1x <= fmt1_s & scale1x_s;   // fmt-0 is always 2x
                u_fixcol <= fixcol_s;
                u_r <= r_s; u_g <= g_s; u_b <= b_s;
                u_spd <= spd_s;
            end else
                logo_valid <= 1'b0;
        end
        // else: keep everything
    end
end

// ---------------------------------------------------------------------------
// Frame tick: every refresh, field or frame (see the header note on il_mode)
// ---------------------------------------------------------------------------
wire tick = frame_tick;
wire il_mode_unused = il_mode;

// ---------------------------------------------------------------------------
// Motion: Q12.4 position, clamp-bounce, entropy-re-rolled speeds, palette
// cycle on bounce, corner-hit flash. Display-side state -- reset is fine
// here (position is independent of ROM contents).
// ---------------------------------------------------------------------------
localparam [3:0] SPX_DEF = 4'd14;      // ~52 px/s @ 59.94: traverse ~9 s
localparam [3:0] SPY_DEF = 4'd9;       // ~34 px/s: traverse ~12 s

// on-screen (bounce-box) size: native or 2x per the logo's scale flag.
// ⚠ A 2x logo that cannot FIT the window renders native instead (scale1x_eff): the
// maximum is 256x64 in the ROM = 512x128 at 2x, which does not fit a 352- or 480-wide
// VCD/SVCD window, and a box wider than the screen has nowhere to bounce. u_scale1x
// itself is ROM geometry and is deliberately NOT touched -- this is a display decision,
// re-evaluated whenever the window changes.
wire        scale1x_eff = u_scale1x | ({2'd0, u_w, 1'b0} > act_w_i)
                                    | ({4'd0, u_h, 1'b0} > act_h_i);
wire [11:0] w2 = scale1x_eff ? {3'd0, u_w} : {2'd0, u_w, 1'b0};
wire [11:0] h2 = scale1x_eff ? {5'd0, u_h} : {4'd0, u_h, 1'b0};
// The box is the ACTIVE WINDOW, and both bounds clamp: a logo larger than the window on
// either axis pins that axis at 0 rather than underflowing to ~4095 (which would put the
// bounce wall off-screen and the logo with it).
wire [11:0] x_hi = (act_w_i > w2) ? act_w_i - w2 : 12'd0;
wire [11:0] y_hi = (act_h_i > h2) ? act_h_i - h2 : 12'd0;

wire [3:0] spx_eff_def = (u_spd == 8'd0) ? SPX_DEF : u_spd[3:0];
wire [3:0] spy_eff_def = (u_spd == 8'd0) ? SPY_DEF : u_spd[7:4];
wire       spd_user    = (u_spd != 8'd0);   // user speed: no bounce re-roll

reg [15:0] pxq, pyq;                   // Q12.4
reg        vxn, vyn;                   // 1 = moving toward 0
reg  [3:0] spx, spy;
reg  [2:0] cidx;
reg  [5:0] corner_tmr;
reg  [7:0] cur_r, cur_g, cur_b;

wire [11:0] px = pxq[15:4];
wire [11:0] py = pyq[15:4];
// precomputed per frame -- keeps the hotspot compares add-free
reg  [11:0] px_end, py_end;

wire hit_x0 = vxn  && (pxq <= {12'd0, spx});
wire hit_x1 = ~vxn && (pxq + {12'd0, spx} >= {x_hi, 4'd0});
wire hit_y0 = vyn  && (pyq <= {12'd0, spy});
wire hit_y1 = ~vyn && (pyq + {12'd0, spy} >= {y_hi, 4'd0});
wire hit_x  = hit_x0 | hit_x1;
wire hit_y  = hit_y0 | hit_y1;

// ---------------------------------------------------------------------------
// Trajectory fine-tune on request (`nudge`), so the corner can be AIMED AT.
//
// A corner flashes the logo white for 45 ticks (`corner_tmr` below) and is
// otherwise a once-an-hour coincidence. A press steps the trajectory by the
// SMALLEST amount it can, which is what makes lining one up a game.
//
// ⛔ A press must NOT re-roll the speeds from entropy, and that is measured, not
// taste. A re-roll re-draws both arrival times, so it destroys whatever approach
// you had set up: over 200,000 ticks, free-running scored 1 corner, blind
// nudging 2, and 3,222 presses timed while heading INTO a corner scored ZERO.
// Pressing was worse than not playing. A press is a notch, never a scramble.
//
// ⛔ And it does NOT aim FOR you. An earlier cut armed after four presses and
// converted the next near-miss bounce into a hit; it worked in sim and was
// dropped (2026-09-17) -- the payoff is only worth something if it is earned.
//
// The step is an ODOMETER: spx walks 8..15 and carries into spy (5..12), so one
// button reaches all 64 trajectories and every press is the finest change
// available. ⚠ Both ranges start well clear of 0 -- hit_x0 is
// `vxn && (pxq <= spx)`, so a zero step pins that axis against the wall for ever.
//
// ⚠ `spd_manual` is load-bearing: the BOUNCE re-roll (below) would otherwise
// re-randomise the axis you are not tuning at every wall, which is the same
// scramble by another route. The first press hands the speeds to the player and
// they stay put until pressed again. Cleared only by reset.
reg nudge_pend;   // a press waiting for the next frame tick
reg spd_manual;   // the player owns the speeds now: no bounce re-roll

// Distance to the wall each axis is currently heading for.
wire [11:0] dx_to = vxn ? px : ((x_hi > px) ? x_hi - px : 12'd0);
wire [11:0] dy_to = vyn ? py : ((y_hi > py) ? y_hi - py : 12'd0);

// A CORNER. Strictly both axes bouncing on the same tick -- UNLESS someone is
// playing, in which case the second axis only has to be within CORNER_TOL of its
// wall. Without a tolerance a corner needs both axes inside a ~1 px window on the
// same tick, which no amount of aiming can reliably hit.
//
// ★ `spd_manual` gates the tolerance, so an idle screen NOBODY HAS TOUCHED keeps
// the original condition exactly and stays bit-identical to the pre-2026-09-17
// module. The forgiving corner is something you opt into by playing, which also
// keeps the joke intact for everyone else: a DVD logo still never hits the corner
// on its own.
//
// MEASURED over 200,000 ticks (~55 min) free-running, and by sweeping all 64
// trajectories the odometer reaches and asking which ever produce a corner within
// 6000 ticks (~100 s). The tolerance trades one against the other:
//     TOL    corners/hr idling    aimable
//      1          2                3/64
//      2          4                5/64
//      3          4                7/64      <- chosen
//      4          5                8/64
//      6          7               11/64
//      8          8               15/64
//     12         12               21/64
// 3 puts a winning setting about 9 presses away while keeping an untouched idle
// screen at its natural rate. ⚠ Retune this constant, not the expression -- the
// table above is why it is the value it is.
localparam [11:0] CORNER_TOL = 12'd3;
wire corner_now = (hit_x && hit_y)
               || (spd_manual && ((hit_x && (dy_to <= CORNER_TOL))
                               || (hit_y && (dx_to <= CORNER_TOL))));

// spx walks its range and carries into spy. Written as an explicit range test
// rather than a counter wrap because spx/spy can arrive from the bounce re-roll
// (12..15 / 8..11), from SPX_DEF/SPY_DEF, or from a boot.rom-pinned u_spd, none
// of which are guaranteed to sit inside the odometer's range.
wire       spx_wrap = (spx >= 4'd15) || (spx < 4'd8);
wire [3:0] spx_next = spx_wrap ? 4'd8 : spx + 4'd1;
wire [3:0] spy_next = ((spy >= 4'd12) || (spy < 4'd5)) ? 4'd5 : spy + 4'd1;

// A nudge is a one-cycle pulse and this module only acts on frame ticks, so the
// press is held until the next one. ⚠ The set arm outranks the clear, so a press
// landing exactly on a tick is honoured on the following tick, not dropped.
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)      nudge_pend <= 1'b0;
    else if (nudge)  nudge_pend <= 1'b1;
    else if (tick)   nudge_pend <= 1'b0;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pxq <= {12'd100, 4'd0};        // safe for any logo on a full-width window
        pyq <= {12'd80,  4'd0};        // (100+256<=720, 80+128<=480 and <=240)
                                       // ⚠ On a NARROW window (a 352-wide VCD) the reset
                                       // x can sit outside the box -- the first frame tick
                                       // clamps it (hit_x1 pins pxq to x_hi), so it costs
                                       // at most one frame of a few clipped pixels and
                                       // needs no reset-time knowledge of the window.
        vxn <= 1'b0; vyn <= 1'b0;
        spx <= SPX_DEF; spy <= SPY_DEF;
        cidx <= 3'd0;
        corner_tmr <= 6'd0;
        spd_manual <= 1'b0;
        cur_r <= 8'hFF; cur_g <= 8'h3B; cur_b <= 8'h30;
    end else if (tick) begin
        // X axis
        if (hit_x0)      begin pxq <= 16'd0;         vxn <= 1'b0; end
        else if (hit_x1) begin pxq <= {x_hi, 4'd0};  vxn <= 1'b1; end
        else             pxq <= vxn ? pxq - {12'd0, spx} : pxq + {12'd0, spx};
        // Y axis
        if (hit_y0)      begin pyq <= 16'd0;         vyn <= 1'b0; end
        else if (hit_y1) begin pyq <= {y_hi, 4'd0};  vyn <= 1'b1; end
        else             pyq <= vyn ? pyq - {12'd0, spy} : pyq + {12'd0, spy};

        // bounce bookkeeping: speed re-roll (skip when the user pinned the speed,
        // or once a press has handed the speeds to the player), palette advance
        // (+3 mod 8 = coprime, no adjacent repeat)
        if (hit_x && !spd_user && !spd_manual) spx <= 4'd12 + {2'd0, entropy[1:0]};
        if (hit_y && !spd_user && !spd_manual) spy <= 4'd8  + {2'd0, entropy[3:2]};
        if (hit_x || hit_y) cidx <= cidx + 3'd3;

        // A requested fine-tune. Placed AFTER the bounce bookkeeping on purpose so
        // it wins on a tick that is both: a press is a deliberate setting and must
        // not be overwritten by the bounce's own re-roll, and it overrides spd_user
        // for the same reason (a pinned speed suppresses the BOUNCE re-roll; an
        // explicit press is not a bounce).
        if (nudge_pend) begin
            spd_manual <= 1'b1;
            spx        <= spx_next;
            if (spx_wrap) spy <= spy_next;          // odometer carry
            cidx       <= cidx + 3'd3;              // visible acknowledgement
        end

        if (corner_now) corner_tmr <= 6'd45;         // ~0.75 s white flash
        else if (corner_tmr != 6'd0) corner_tmr <= corner_tmr - 6'd1;

        // colour resolve (event rate, never per pixel)
        if (corner_tmr != 6'd0 || corner_now)
            {cur_r, cur_g, cur_b} <= 24'hFFFFFF;
        else if (u_fixcol && logo_valid)
            {cur_r, cur_g, cur_b} <= {u_r, u_g, u_b};
        else case (cidx)
            3'd0: {cur_r, cur_g, cur_b} <= 24'hFF3B30;   // red
            3'd1: {cur_r, cur_g, cur_b} <= 24'hFF9500;   // orange
            3'd2: {cur_r, cur_g, cur_b} <= 24'hFFD60A;   // yellow
            3'd3: {cur_r, cur_g, cur_b} <= 24'h34C759;   // green
            3'd4: {cur_r, cur_g, cur_b} <= 24'h00C7BE;   // teal
            3'd5: {cur_r, cur_g, cur_b} <= 24'h0A84FF;   // blue
            3'd6: {cur_r, cur_g, cur_b} <= 24'hAF52DE;   // purple
            3'd7: {cur_r, cur_g, cur_b} <= 24'hFF2D55;   // pink
        endcase

    end
end

// Precomputed box ends, registered the cycle AFTER a tick so they read the
// just-updated position -- keeps the per-pixel compares add-free. One frame
// tick moves the box <=1 px, so the 1-cycle lag is unobservable (and the
// compares below clamp anyway).
reg tick_d;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tick_d <= 1'b0;
        px_end <= 12'd100 + {3'd0, DEF_W};   // reset position + default (1x) size
        py_end <= 12'd80  + {5'd0, DEF_H};
    end else begin
        tick_d <= tick;
        if (tick_d) begin
            px_end <= px + w2;
            py_end <= py + h2;
        end
    end
end

// ---------------------------------------------------------------------------
// Pixel pipeline: 3 registered stages, pure (x,y) -- the seek_bar template.
// Stage A: window test + logo-space coords. Stage B: ROM read. Stage C:
// bit select + colour.
// ---------------------------------------------------------------------------
wire [11:0] hq  = h_pos - LOGO_QX_LEAD;   // SUBTRACT: lead comp (SP_QX_ADJ sign)
wire        inx = (hq >= px) && (hq < px_end);
wire        iny = (v_pos >= py) && (v_pos < py_end);
wire [11:0] hx  = hq - px;
wire [11:0] vy  = v_pos - py;

reg        s0_in, s1_in;
reg  [7:0] s0_lx;
reg  [5:0] s0_ly;
reg  [3:0] s1_sel;
reg [15:0] rom_q;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s0_in <= 1'b0; s1_in <= 1'b0;
        s0_lx <= 7'd0; s0_ly <= 5'd0; s1_sel <= 4'd0;
        logo_on <= 1'b0;
        logo_r <= 8'd0; logo_g <= 8'd0; logo_b <= 8'd0;
    end else begin
        // A
        s0_in <= vis && inx && iny;
        s0_lx <= scale1x_eff ? hx[7:0] : hx[8:1];   // native vs 2x render
        s0_ly <= scale1x_eff ? vy[5:0] : vy[6:1];
        // B (ROM read is outside the reset tree -- see below)
        s1_in  <= s0_in;
        s1_sel <= s0_lx[3:0];
        // C
        logo_on <= s1_in && rom_q[~s1_sel];
        logo_r  <= cur_r;
        logo_g  <= cur_g;
        logo_b  <= cur_b;
    end
end

// sync ROM read, no reset (M10K inference)
always @(posedge clk)
    rom_q <= logo_rom[{logo_valid, s0_ly, s0_lx[7:4]}];

endmodule
