// spu_decode.sv — DVD Subpicture (SPU) decoder + on-screen renderer
// Part of MiSTer DVD Player Core
//
// Consumes the selected subpicture substream from ps_demux (sp_* port), buffers
// one whole SPU (Sub-Picture Unit) into a synchronous BRAM, parses its header +
// display-control sequence (DCSQ), RLE-decodes the 4-colour bitmap into a
// full-frame 2-bpp BRAM, tracks show/hide timing against the video STC, and
// answers per-pixel colour-index queries from the display path.
//
// Format reference: docs/subpicture.md. Golden model + fixture: tools/spu_ref.py,
// verified against a real Matrix SPU ("You hear that, Mr. Anderson?").
//
// v1 scope (see docs/subpicture.md): HDMI progressive render (720x480/576p), a
// SET_COLOR now captured (Phase-1 disc menus): the four 4-bit palette indices are
// output as col0..col3; the caller looks the RGB up in pgc_palette (fed the PGC
// IFO palette @164). SET_CONTR alpha honoured as before. Single decode buffer / one
// SPU on screen. CHG_COLCON and FSTA_DSP-as-menu-highlight are still out of scope.
//
// FIT DISCIPLINE (see memory dvd-iso-navigator): the SPU byte buffer and the
// bitmap are SYNCHRONOUS single-read-port BRAMs read sequentially / one-address-
// per-cycle — never indexed asynchronously at many offsets (that exploded the ISO
// reader to 226% ALMs). The parser walks the buffer with a 2-cycle byte fetch.

`default_nettype none

module spu_decode #(
    parameter int BMP_N   = 414720,   // 720*576 (covers NTSC 720*480 and PAL 720*576)
    parameter int STRIDE  = 720,
    parameter int SPU_CAP = 53248,     // max buffered SPU bytes >= the DVD-Video SPEC
                                       // MAXIMUM of 53,220 (spec-hardening Phase 2).
                                       // Subtitles are < 2 KB, but MENU subpictures
                                       // (full-frame button/highlight graphics) are large,
                                       // and this exact cap has bitten TWICE: 8 KB dropped
                                       // T2's 23.9 KB scene-range menus (PR #84 raised it
                                       // to 32 KB), and the Phase-1 library audit then
                                       // measured a real 28,556 B SPU (87% of 32 KB) — so
                                       // the cap now sits at the spec max instead of the
                                       // largest-seen. The DCSQ table sits at the END of
                                       // the SPU, so a too-small cap drops it entirely (no
                                       // DAREA/show/colour -> never commits = the deep-menu
                                       // "no highlight/graphic"). Addr regs are [15:0];
                                       // a malformed > SPU_CAP unit whose DCSQ start lies
                                       // beyond the cap is DROPPED cleanly (pre-Phase-2 the
                                       // 15-bit truncation aliased it into garbage).
    parameter int HOLD_CYCLES = 18_900_000  // ~700 ms at 27 MHz: the display-order
                                       // hold's hard bound. A PARAMETER so a bench can
                                       // shrink it -- at 27 MHz the real value is 70 M
                                       // simulation cycles, which no Icarus run reaches.
                                       // Bound rationale at the S_HOLD state below.
                                       // ⚠ Must stay under 2^25 (hold_tmr's width); a
                                       // larger value truncates. That fails SAFE -- a
                                       // shorter hold degrades toward the pre-fix
                                       // behaviour rather than stalling -- but it would
                                       // silently not be the bound you wrote.
) (
    input  wire        clk,           // clk_sys 27 MHz
    input  wire        rst_n,
    input  wire        enable,        // O[15]; when low, nothing is shown

    // Interlaced (CRT 480i, O[14]) render mode. In interlaced output syncgen encodes
    // the ABSOLUTE frame line directly in v_pos (= {v_cntr, ~odd_field}), so q_y already
    // carries top=even / bottom=odd absolute lines — but it steps by 2 per field-line
    // (bit 0 = constant field parity), which breaks the progressive +1 row-base
    // accumulator. When high, the render addressing steps by 2*STRIDE and re-bases on the
    // field parity. Progressive (HDMI) render is byte-identical when low. See
    // docs/subpicture.md + docs/crt_480i.md.
    input  wire        interlaced,

    // Selected subpicture payload from ps_demux (clk_sys, no CDC)
    input  wire  [7:0] sp_byte,
    input  wire        sp_valid,
    input  wire        sp_frame_start,
    // MENU MODE (Phase-3 disc menus, emu: menus_on && menu_active): menus
    // RE-SEND their subpicture every VOBU (Matrix: ~124 copies per loop; the
    // stream runs seconds ahead of presentation), and accepting a re-send
    // early REPLACES the committed show window with one that hasn't opened
    // yet - the on-screen menu graphic (and with it the button highlight)
    // blinks at the stream's stall cadence. In menu mode a NEW packet is
    // only accepted once ITS PTS is due; early re-sends are discarded
    // (lossless: they repeat). Titles keep the decode-early pipeline.
    //
    // ⚠ THAT LAST CLAUSE USED TO READ "their subpics are muxed near their PTS and
    // are NOT re-sent" AND IT IS FALSE FOR AN IN-TITLE HLI BUTTON GRAPHIC. The Matrix's
    // "Follow the White Rabbit" icon is authored exactly like a menu's: MEASURED on the
    // disc, one FSTA_DSP at PTS 101885 and one STP_DSP at 866659 (8.4975 s solid), with
    // the SAME unit re-sent BYTE-IDENTICALLY 8 times, 90090 ticks (1.001 s) apart. It is
    // a single-button HLI (btn_ns==1), so nav_pci's hli_seen (>1 button) never fires and
    // emu's menu_mode stays 0 -- it runs the windowed path below.
    // That was harmless while the STC LED the display: a re-send arriving at the parse
    // front was already due at commit. PR #63 moved the STC onto the displayed picture
    // (disp_lag ~0), so each re-send began committing a show window ~a VBUF depth in the
    // FUTURE and blanked the icon until the clock caught up -- the ~1 s blink reported
    // from the field. The fix is not another menu_mode exemption: see the HOLD and the
    // CONTIGUITY CLAMP below, which fix the mechanism for subtitles too.
    input  wire        menu_mode,
    input  wire [32:0] sp_pts,
    input  wire        sp_pts_valid,

    // Video-referenced System Time Clock (av_sync.stc), 90 kHz ticks
    input  wire [32:0] stc,

    // Display query: colour index at screen (q_x, q_y). Result is registered
    // (1-cycle BRAM latency) — the caller aligns video by one cycle to match.
    input  wire [11:0] q_x,
    input  wire [11:0] q_y,
    output wire [1:0]  q_idx,
    output reg         q_inside,      // registered: inside DAREA AND currently visible

    // Per-index alpha from SET_CONTR (0=transparent..15=opaque); caller muxes by q_idx
    output wire [3:0]  alpha0,
    output wire [3:0]  alpha1,
    output wire [3:0]  alpha2,
    output wire [3:0]  alpha3,

    // Per-index palette index from SET_COLOR (4-bit index into the PGC palette);
    // caller muxes by q_idx then looks up the RGB in pgc_palette. Phase-1 menus.
    output wire [3:0]  col0,
    output wire [3:0]  col1,
    output wire [3:0]  col2,
    output wire [3:0]  col3,

    output wire        sp_active      // a decoded SPU is currently shown (debug)
);
    localparam int ABW     = $clog2(BMP_N);
    localparam int STRIDE2  = STRIDE * 2;   // interlaced field-line step (skips 1 abs line)
    localparam int STRIDE4  = STRIDE * 4;   // CRT-letterbox field-line skip step (see below)

    // ------------------------------------------------------------------
    // SPU byte buffer (sync single read port) + write port (fill)
    // ------------------------------------------------------------------
    (* ramstyle = "M10K" *) reg [7:0] spubuf [0:SPU_CAP-1];
    reg  [15:0] rd_ptr;
    reg  [7:0]  rd_data;
    reg         spu_we;
    reg  [15:0] spu_waddr;
    reg  [7:0]  spu_wdata;
    always @(posedge clk) begin
        if (spu_we) spubuf[spu_waddr] <= spu_wdata;
        rd_data <= spubuf[rd_ptr];
    end

    // ------------------------------------------------------------------
    // Full-frame 2-bpp bitmap (simple dual port: RLE write / render read)
    // ------------------------------------------------------------------
    (* ramstyle = "M10K" *) reg [1:0] bmp [0:BMP_N-1];
    reg              bmp_we;
    reg  [ABW-1:0]   bmp_waddr;
    reg  [1:0]       bmp_wdata;
    reg  [1:0]       bmp_rd;
    reg  [ABW-1:0]   q_row_base;      // q_y*STRIDE (per-line adder; see below)
    always @(posedge clk) begin
        if (bmp_we) bmp[bmp_waddr] <= bmp_wdata;
        bmp_rd <= bmp[q_row_base + {{(ABW-12){1'b0}}, q_x}];   // 1-cycle sync read
    end
    assign q_idx = bmp_rd;

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    typedef enum logic [5:0] {
        S_IDLE, S_SKIP, S_FILL, S_DRAIN,
        GETB0, GETB1,
        D_DLY0, D_DLY1, D_NXT0, D_NXT1, D_CMD,
        RP_LOOP, RP_STORE, RP_DONE, SKIP_LOOP,
        DCSQ_END, S_HOLD,
        RLE_LINE, RLE_ACC, RLE_LOAD, RLE_EMIT, RLE_EOL,
        COMMIT
    } state_t;
    state_t state, ret;

    // fill / header
    reg  [15:0] wr_ptr;
    reg  [15:0] spdsz;
    reg  [15:0] dcsqt_sa;
    reg  [32:0] pts_latched;

    // byte-fetch result
    reg  [7:0]  gb;

    // DCSQ walk
    reg  [15:0] dcsq_off;
    reg  [15:0] dcsq_delay;
    reg  [15:0] dcsq_next;
    reg  [7:0]  cur_op;
    reg  [2:0]  need;         // bytes to read for current command
    reg  [2:0]  pcnt;
    reg  [7:0]  pbuf [0:5];
    reg  [15:0] skip_cnt;

    // working (uncommitted) params
    reg  [11:0] w_sx, w_ex, w_sy, w_ey;
    reg  [15:0] w_top, w_bot;
    reg  [3:0]  w_a0, w_a1, w_a2, w_a3;
    reg  [3:0]  w_c0, w_c1, w_c2, w_c3;    // SET_COLOR palette indices (into PGC palette)
    reg  [32:0] w_show, w_hide;
    reg         w_has_show, w_has_hide, w_has_area, w_has_xa;

    // committed params (what the renderer uses)
    reg  [11:0] c_sx, c_ex, c_sy, c_ey;
    reg  [3:0]  c_a0, c_a1, c_a2, c_a3;
    reg  [3:0]  c_c0, c_c1, c_c2, c_c3;    // committed SET_COLOR palette indices
    reg  [32:0] c_show, c_hide;
    reg         c_valid;
    reg  [32:0] c_pts;         // PTS of the committed SPU (menu re-send discriminator)

    // ------------------------------------------------------------------
    // DISPLAY-ORDER COMMIT (2026-09-08). The RLE decode is the ONLY destructive
    // step -- it overwrites the single full-frame bitmap, so committing a unit
    // early destroys the one on screen before its authored window has expired.
    // Two guards, both keyed off values the DCSQ walk has already produced by the
    // time DCSQ_END is reached (w_show/w_hide/DAREA/palette are all known there,
    // strictly BEFORE `state <= RLE_LINE`).
    //
    // ⛔ Double-buffering the bitmap is not available: 720*576 at 2 bpp = 829,440
    // bits, and at x2 width an M10K holds 4,096 entries => ~102 M10Ks for a second
    // copy. RAM is the binding constraint and has sat at 498/553 blocks (90%) in
    // EVERY build since v0.4.0 -- 55 free against the ~102 needed -- so the guards
    // have to be near-free. They are: one counter and two compares. (MEASURED with
    // them in: 39,113/41,910 ALMs = 93%, SEED 5 held, clk_dec 95.57/92.68 vs the
    // 86.0 gate.)
    reg  [24:0] hold_tmr;

    // the unit's effective show time (COMMIT's own default when no STA_DSP delay)
    wire [32:0] w_show_eff = w_has_show ? w_show : pts_latched;
    // due against the DISPLAY clock. Signed on the low 32 bits so a 33-bit PTS wrap
    // cannot park the hold (the bounded timer is the backstop, not the primary).
    wire        spu_due    = $signed(w_show_eff[31:0] - stc[31:0]) <= 0;
    // "stay if no STP_DSP" is encoded as an all-ones c_hide; a plain compare against
    // that sentinel wraps and reads as NOT contiguous, which is the one case that
    // matters most here (a persistent button graphic), so test it explicitly.
    wire        c_hide_inf = &c_hide;
    // CONTIGUITY: the author wrote no gap between the committed unit and this one,
    // so blanking between them would invent a hole that is not on the disc. A
    // persistent unit (c_hide_inf) is contiguous with every successor by
    // construction -- which is exactly the white-rabbit re-send chain.
    wire        spu_contig = c_valid &&
                             (c_hide_inf ||
                              ($signed(w_show_eff[31:0] - c_hide[31:0]) <= 0));
    // a genuine SPU START: sp_frame_start pulses on the first byte of EVERY
    // subpicture PES, but only the first PES of a unit carries a PTS (see the
    // sp_frame_start port comment in ps_demux.sv), so this is the same boundary
    // rule S_DRAIN already uses.
    wire        spu_unit_start = sp_valid && sp_frame_start && sp_pts_valid;

    // RLE state
    reg  [11:0] width, height;
    reg  [11:0] nl_top, nl_bot;
    reg         field;          // 0=top,1=bottom
    reg  [11:0] lif;            // line index within field
    reg  [11:0] abs_line;       // absolute line within DAREA
    reg  [11:0] x;
    reg  [15:0] run;
    reg  [1:0]  color;
    reg  [7:0]  nib_buf;
    reg  [1:0]  nib_cnt;        // nibbles available (0,1,2)
    reg  [1:0]  nstep;          // run-length accumulation step
    reg  [15:0] acc;
    reg  [ABW-1:0] wr_row_base; // (w_sy+abs_line)*STRIDE, computed per line

    assign alpha0 = c_a0;
    assign alpha1 = c_a1;
    assign alpha2 = c_a2;
    assign alpha3 = c_a3;

    assign col0 = c_c0;
    assign col1 = c_c1;
    assign col2 = c_c2;
    assign col3 = c_c3;

    // current nibble and the accumulated run value using it
    function automatic [3:0] cur_nib; cur_nib = (nib_cnt == 2'd2) ? nib_buf[7:4] : nib_buf[3:0]; endfunction
    function automatic [15:0] vext;   vext = (acc << 4) | {12'd0, cur_nib()}; endfunction

    // ------------------------------------------------------------------
    // Visibility + render read address
    // ------------------------------------------------------------------
    // MENU subpicture: show whenever committed, IGNORING the STC show/hide window.
    // The window (c_show..c_hide) is on the demux parse-front PTS, but the STC leads
    // the displayed frame by the VBUF depth (seconds on a keep_vbuf menu), so by the
    // time the menu frame is on screen the STC has already passed c_hide -> the menu
    // subpicture (the button GRAPHIC — e.g. T2's scene-range numbers) was declared
    // "expired" and never shown, which also left the HLI highlight nothing to recolour
    // (HW diag: armed + video_live OK, but "subpic shown this frame" RED). A menu's
    // subpicture is shown the whole time the menu is up (until a new SPU replaces it
    // or the flush clears c_valid), so drop the timed window for menu_mode. Subtitles
    // (menu_mode=0) keep the exact STC window — their show/hide timing is authored.
    wire visible = enable && c_valid &&
                   (menu_mode || ((stc >= c_show) && (stc < c_hide)));
    assign sp_active = visible;

    // q_row_base tracks q_y*STRIDE via a per-line adder (no multiplier in the hot
    // path). It updates one cycle after q_y changes, but q_y is constant across a whole
    // scanline and DAREA never starts at column 0 (typ. sx>~150), so it is settled long
    // before the first in-DAREA pixel. Jumps outside raster are gated off by q_inside.
    //
    //   Progressive: q_y is a clean 0,1,2,.. raster -> reset at q_y==0, step +STRIDE.
    //   Interlaced (CRT 480i): q_y = absolute frame line but advances by 2 within a field
    //     (bit0 = constant field parity). The even field scans q_y 0,2,4,..; the odd field
    //     1,3,5,.. -> reset at the field top (q_y<=1, uniquely per field) to the parity
    //     offset (q_y[0] ? STRIDE : 0), then step +2*STRIDE per field-line. This lands the
    //     read on the same absolute-line bitmap the RLE decoder wrote (top=even/bottom=odd),
    //     so the two fields reassemble the identical progressive image.
    //   CRT anamorphic Letterbox (DVD-FORK, crt_ov_map): q_y is the INVERSE-MAPPED source
    //     line, which walks the 4/3 Bresenham pattern — steps of +1/+2 (progressive) or
    //     +2/+4 (field) as every 4th source line is skipped. The extra +2/+4 branches
    //     below track those skips; the band start still lands on q_y<=1 (the mapper
    //     emits source line 0/1 there) so the existing reset arms the walk.
    reg  [11:0]    q_y_d;
    always @(posedge clk) begin
        q_y_d <= q_y;
        if (interlaced) begin
            if (q_y <= 12'd1)              q_row_base <= q_y[0] ? STRIDE[ABW-1:0] : '0;
            else if (q_y == q_y_d + 12'd2) q_row_base <= q_row_base + STRIDE2[ABW-1:0];
            else if (q_y == q_y_d + 12'd4) q_row_base <= q_row_base + STRIDE4[ABW-1:0];
        end else begin
            if (q_y == 12'd0)              q_row_base <= '0;
            else if (q_y == q_y_d + 12'd1) q_row_base <= q_row_base + STRIDE[ABW-1:0];
            else if (q_y == q_y_d + 12'd2) q_row_base <= q_row_base + STRIDE2[ABW-1:0];
        end
    end

    wire in_x = (q_x >= c_sx) && (q_x <= c_ex);
    wire in_y = (q_y >= c_sy) && (q_y <= c_ey);

    always @(posedge clk) begin
        q_inside <= visible && in_x && in_y;      // registered to match q_idx (bmp_rd)
    end

    // ------------------------------------------------------------------
    // Main decode FSM
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            c_valid  <= 1'b0;
            c_pts    <= 33'd0;
            spu_we   <= 1'b0;
            bmp_we   <= 1'b0;
            wr_ptr   <= '0;
            rd_ptr   <= '0;
            hold_tmr <= 25'd0;
            c_a0 <= 0; c_a1 <= 0; c_a2 <= 0; c_a3 <= 0;
            // Default palette indices = identity (idx k -> palette entry k) so a SPU
            // lacking SET_COLOR (rare) still maps to distinct entries.
            c_c0 <= 4'd0; c_c1 <= 4'd1; c_c2 <= 4'd2; c_c3 <= 4'd3;
            w_c0 <= 4'd0; w_c1 <= 4'd1; w_c2 <= 4'd2; w_c3 <= 4'd3;
        end else begin
            spu_we <= 1'b0;
            bmp_we <= 1'b0;

            case (state)
            // ---- wait for the first byte of a new SPU ----
            S_IDLE: begin
                // ⚠ spu_unit_start, NOT a bare sp_valid. spu_decode does not
                // backpressure ps_demux, so every byte arriving while it is busy is
                // dropped and S_IDLE used to resume at an ARBITRARY byte -- reading a
                // continuation byte as an SPDSZ header. That was survivable while
                // "busy" was one RLE pass; the display-order hold below makes the busy
                // window far longer, so resume at a real unit boundary instead.
                // Every SPU's first PES carries a PTS by construction (MEASURED: 37
                // PTS-bearing subpicture PES = 37 units over 40,000 sectors of a real
                // title), which is why S_DRAIN has always been able to use this rule.
                if (spu_unit_start) begin
                    // MENU re-send discriminator (fixes "highlight only on the 2nd loop
                    // after returning from a submenu"): a menu cell RE-SENDS the same
                    // subpicture(s) every loop, and some menus author MORE THAN ONE per
                    // loop with increasing PTS - e.g. Matrix's root cell 2 sends a tiny
                    // transparent DUMMY (pts A) then the REAL full-screen highlight overlay
                    // (pts B > A). Skipping by `stc < sp_pts` dropped the NEWER unit B until
                    // the STC crawled past B's PTS a full loop later (the dummy stayed
                    // committed = no highlight). Compare against the COMMITTED PTS instead:
                    // SKIP only a re-send of the current-or-older unit (sp_pts <= c_pts);
                    // ACCEPT a genuinely newer one (sp_pts > c_pts) immediately. c_valid==0
                    // (fresh after a flush) always accepts. Subtitles (menu_mode=0) untouched.
                    if (menu_mode && c_valid && sp_pts_valid &&
                        $signed(sp_pts[31:0] - c_pts[31:0]) <= 0) begin
                        state <= S_SKIP;     // re-send of the committed-or-older SPU: discard
                    end else begin
                        spu_we    <= 1'b1; spu_waddr <= '0; spu_wdata <= sp_byte;
                        spdsz[15:8] <= sp_byte;
                        if (sp_pts_valid) pts_latched <= sp_pts;
                        wr_ptr    <= 16'd1;
                        state     <= S_FILL;
                    end
                end
            end

            // ---- discard an early menu re-send; re-evaluate at the next
            //      packet boundary (sp_frame_start) ----
            S_SKIP: begin
                if (sp_valid && sp_frame_start) begin
                    if (menu_mode && c_valid && sp_pts_valid &&
                        $signed(sp_pts[31:0] - c_pts[31:0]) <= 0)
                        state <= S_SKIP;     // still a re-send of the committed-or-older SPU
                    else begin
                        spu_we    <= 1'b1; spu_waddr <= '0; spu_wdata <= sp_byte;
                        spdsz[15:8] <= sp_byte;
                        if (sp_pts_valid) pts_latched <= sp_pts;
                        wr_ptr    <= 16'd1;
                        state     <= S_FILL;
                    end
                end
            end

            // ---- drop-drain: swallow the tail of an over-cap unit until the
            //      next PTS-carrying packet boundary (a real unit start) ----
            S_DRAIN: begin
                if (sp_valid && sp_frame_start && sp_pts_valid) begin
                    spu_we    <= 1'b1; spu_waddr <= '0; spu_wdata <= sp_byte;
                    spdsz[15:8] <= sp_byte;
                    pts_latched <= sp_pts;
                    wr_ptr    <= 16'd1;
                    state     <= S_FILL;
                end
            end

            // ---- accumulate the SPU until spdsz bytes are in the buffer ----
            S_FILL: begin
                if (sp_valid) begin
                    if (wr_ptr < SPU_CAP[15:0]) begin
                        spu_we <= 1'b1; spu_waddr <= wr_ptr; spu_wdata <= sp_byte;
                    end
                    if (wr_ptr == 16'd1) spdsz[7:0]     <= sp_byte;
                    if (wr_ptr == 16'd2) dcsqt_sa[15:8]  <= sp_byte;
                    if (wr_ptr == 16'd3) dcsqt_sa[7:0]   <= sp_byte;
                    // completion: wrote spdsz bytes (or hit the buffer cap)
                    if ((wr_ptr >= 16'd3) &&
                        ((({1'b0, wr_ptr} + 17'd1) >= {1'b0, spdsz}) ||
                         (({1'b0, wr_ptr} + 17'd1) >= {1'b0, SPU_CAP[15:0]}))) begin
                        if (dcsqt_sa >= SPU_CAP[15:0]) begin
                            // truncated unit whose DCSQ table never made it into
                            // the buffer (> SPU_CAP, i.e. > spec): DROP cleanly
                            // instead of parsing garbage at an aliased address.
                            // The unit's REMAINING bytes are still arriving, so
                            // drain until a genuine unit START (a packet boundary
                            // CARRYING a PTS — continuation PES have none; the
                            // same boundary rule as tools/spec_audit.py's scanner)
                            // rather than letting S_IDLE misread a tail byte as a
                            // new unit header.
                            state <= S_DRAIN;
                        end else begin
                            w_has_show <= 1'b0; w_has_hide <= 1'b0;
                            w_has_area <= 1'b0; w_has_xa <= 1'b0;
                            dcsq_off <= dcsqt_sa;
                            rd_ptr   <= dcsqt_sa;
                            ret      <= D_DLY0;
                            state    <= GETB0;
                        end
                    end else begin
                        wr_ptr <= wr_ptr + 16'd1;
                    end
                end
            end

            // ---- generic 2-cycle byte fetch: result in `gb`, rd_ptr auto-advances
            GETB0: state <= GETB1;
            GETB1: begin gb <= rd_data; rd_ptr <= rd_ptr + 16'd1; state <= ret; end

            // ---- DCSQ header: delay(2), next-offset(2) ----
            D_DLY0: begin dcsq_delay[15:8] <= gb; ret <= D_DLY1; state <= GETB0; end
            D_DLY1: begin dcsq_delay[7:0]  <= gb; ret <= D_NXT0; state <= GETB0; end
            D_NXT0: begin dcsq_next[15:8]  <= gb; ret <= D_NXT1; state <= GETB0; end
            D_NXT1: begin dcsq_next[7:0]   <= gb; ret <= D_CMD;  state <= GETB0; end

            // ---- read one command opcode ----
            D_CMD: begin
                cur_op <= gb; pcnt <= 3'd0;
                case (gb)
                    8'h00, 8'h01: begin  // (F)STA_DSP -> show
                        w_show <= pts_latched + ({17'd0, dcsq_delay} << 10);
                        w_has_show <= 1'b1;
                        ret <= D_CMD; state <= GETB0;   // no params; next opcode
                    end
                    8'h02: begin         // STP_DSP -> hide
                        w_hide <= pts_latched + ({17'd0, dcsq_delay} << 10);
                        w_has_hide <= 1'b1;
                        ret <= D_CMD; state <= GETB0;
                    end
                    8'h03: begin need <= 3'd2; state <= RP_LOOP; end  // SET_COLOR (palette idx)
                    8'h04: begin need <= 3'd2; state <= RP_LOOP; end  // SET_CONTR
                    8'h05: begin need <= 3'd6; state <= RP_LOOP; end  // SET_DAREA
                    8'h06: begin need <= 3'd4; state <= RP_LOOP; end  // SET_DSPXA
                    8'h07: begin need <= 3'd2; state <= RP_LOOP; end  // CHG_COLCON len
                    8'hFF: state <= DCSQ_END;                         // end of DCSQ
                    default: state <= DCSQ_END;                       // unknown -> stop
                endcase
            end

            // ---- read `need` param bytes into pbuf ----
            RP_LOOP: begin
                if (pcnt == need) state <= RP_DONE;
                else begin ret <= RP_STORE; state <= GETB0; end
            end
            RP_STORE: begin pbuf[pcnt] <= gb; pcnt <= pcnt + 3'd1; state <= RP_LOOP; end

            RP_DONE: begin
                case (cur_op)
                    8'h03: begin  // SET_COLOR: pbuf0=c3|c2, pbuf1=c1|c0 (palette indices)
                        w_c3 <= pbuf[0][7:4]; w_c2 <= pbuf[0][3:0];
                        w_c1 <= pbuf[1][7:4]; w_c0 <= pbuf[1][3:0];
                        ret <= D_CMD; state <= GETB0;
                    end
                    8'h04: begin  // SET_CONTR: pbuf0=a3|a2, pbuf1=a1|a0
                        w_a3 <= pbuf[0][7:4]; w_a2 <= pbuf[0][3:0];
                        w_a1 <= pbuf[1][7:4]; w_a0 <= pbuf[1][3:0];
                        ret <= D_CMD; state <= GETB0;
                    end
                    8'h05: begin  // SET_DAREA
                        w_sx <= {pbuf[0], pbuf[1][7:4]};
                        w_ex <= {pbuf[1][3:0], pbuf[2]};
                        w_sy <= {pbuf[3], pbuf[4][7:4]};
                        w_ey <= {pbuf[4][3:0], pbuf[5]};
                        w_has_area <= 1'b1;
                        ret <= D_CMD; state <= GETB0;
                    end
                    8'h06: begin  // SET_DSPXA
                        w_top <= {pbuf[0], pbuf[1]};
                        w_bot <= {pbuf[2], pbuf[3]};
                        w_has_xa <= 1'b1;
                        ret <= D_CMD; state <= GETB0;
                    end
                    8'h07: begin  // CHG_COLCON: skip (len includes the 2 len bytes)
                        skip_cnt <= {pbuf[0], pbuf[1]} - 16'd2;
                        state <= SKIP_LOOP;
                    end
                    default: begin  // SET_COLOR (0x03) and any other: discard
                        ret <= D_CMD; state <= GETB0;
                    end
                endcase
            end

            SKIP_LOOP: begin
                if (skip_cnt == 16'd0) begin ret <= D_CMD; state <= GETB0; end
                else begin skip_cnt <= skip_cnt - 16'd1; ret <= SKIP_LOOP; state <= GETB0; end
            end

            // ---- end of one DCSQ: advance to next, or finish the table ----
            DCSQ_END: begin
                if (dcsq_next == dcsq_off || dcsq_next == 16'd0) begin
                    if (w_has_area && w_has_xa) begin
                        width    <= w_ex - w_sx + 12'd1;
                        height   <= w_ey - w_sy + 12'd1;
                        nl_top   <= (w_ey - w_sy + 12'd2) >> 1;   // ceil(h/2)
                        nl_bot   <= (w_ey - w_sy + 12'd1) >> 1;   // floor(h/2)
                        field    <= 1'b0; lif <= 12'd0; abs_line <= 12'd0;
                        nib_cnt  <= 2'd0;
                        rd_ptr   <= w_top;
                        hold_tmr <= 25'd0;
                        // HOLD when committing now would destroy a unit that is still
                        // inside its authored window. Every register the RLE pass needs
                        // is set above, so S_HOLD only defers the transition.
                        // menu_mode is excluded: it bypasses the window entirely and
                        // has its own re-send discriminator, so menus stay bit-identical.
                        // (if/else, not a ternary: an enum-typed ternary needs an
                        // explicit cast, and this project has been bitten by Quartus 17
                        // mis-compiling casts that simulate correctly -- memory
                        // quartus-sizecast-netlist-cosim.)
                        if (c_valid && !spu_due && !menu_mode) state <= S_HOLD;
                        else                                   state <= RLE_LINE;
                    end else begin
                        state <= S_IDLE;   // malformed; drop
                    end
                end else begin
                    dcsq_off <= dcsq_next;
                    rd_ptr   <= dcsq_next;
                    ret      <= D_DLY0;
                    state    <= GETB0;
                end
            end

            // ---- DISPLAY-ORDER HOLD: wait until this unit is actually due ----
            // Leaves on whichever comes first:
            //   spu_due        - the authored moment; the outgoing unit got its full
            //                    window and this one lands on time (the fix);
            //   spu_unit_start - a NEW unit is arriving and there is only one buffer,
            //                    so decode this one now rather than strand it;
            //   HOLD_MAX       - a hard ~700 ms bound.
            // ⚠ THE BOUND IS MEASURED, NOT PICKED. Cutting the hold short costs
            // nothing (the contiguity clamp at COMMIT stops it opening a hole), but
            // being IN the hold when the next unit arrives costs that unit its head
            // bytes. On a real subtitle stream consecutive units are never closer than
            // 1034 ms (n=36; p10 1335 ms, median 2369 ms), so a bound safely under
            // that minimum keeps the hold from ever being the reason a line is lost,
            // while still covering the VBUF lead in the normal case.
            S_HOLD: begin
                if (spu_due || spu_unit_start || (hold_tmr == HOLD_CYCLES[24:0]))
                    state <= RLE_LINE;
                else
                    hold_tmr <= hold_tmr + 25'd1;
            end

            // ---- start a new RLE line ----
            RLE_LINE: begin
                wr_row_base <= (w_sy + abs_line) * STRIDE[10:0];
                x     <= 12'd0;
                nstep <= 2'd0;
                acc   <= 16'd0;
                state <= RLE_ACC;
            end

            // ---- accumulate a run code from the nibble stream ----
            RLE_ACC: begin
                if (nib_cnt == 2'd0) begin
                    ret <= RLE_LOAD; state <= GETB0;   // need a fresh byte
                end else begin
                    nib_cnt <= nib_cnt - 2'd1;
                    case (nstep)
                    2'd0: begin
                        if (cur_nib() >= 4'd4) begin
                            run <= {14'd0, cur_nib()>>2}; color <= cur_nib()&2'b11; state <= RLE_EMIT;
                        end else begin acc <= {12'd0, cur_nib()}; nstep <= 2'd1; end
                    end
                    2'd1: begin
                        if (vext() >= 16'h10) begin
                            run <= vext() >> 2; color <= cur_nib()&2'b11; state <= RLE_EMIT;
                        end else begin acc <= vext(); nstep <= 2'd2; end
                    end
                    2'd2: begin
                        if (vext() >= 16'h40) begin
                            run <= vext() >> 2; color <= cur_nib()&2'b11; state <= RLE_EMIT;
                        end else begin acc <= vext(); nstep <= 2'd3; end
                    end
                    default: begin
                        color <= cur_nib()&2'b11;
                        if ((vext() >> 2) == 16'd0) run <= {4'd0, width} - {4'd0, x};  // fill to EOL
                        else                        run <= vext() >> 2;
                        state <= RLE_EMIT;
                    end
                    endcase
                end
            end
            RLE_LOAD: begin nib_buf <= gb; nib_cnt <= 2'd2; state <= RLE_ACC; end

            // ---- emit `run` pixels of `color` into the bitmap ----
            RLE_EMIT: begin
                if (run != 16'd0 && x < width) begin
                    bmp_we    <= 1'b1;
                    bmp_waddr <= wr_row_base + {{(ABW-12){1'b0}}, w_sx} + {{(ABW-12){1'b0}}, x};
                    bmp_wdata <= color;
                    x   <= x + 12'd1;
                    run <= run - 16'd1;
                end else begin
                    if (x >= width) state <= RLE_EOL;
                    else begin nstep <= 2'd0; state <= RLE_ACC; end
                end
            end

            // ---- end of line: byte-align nibbles, advance line / field ----
            RLE_EOL: begin
                if (nib_cnt == 2'd1) nib_cnt <= 2'd0;   // discard leftover low nibble
                if (lif + 12'd1 >= (field ? nl_bot : nl_top)) begin
                    if (field == 1'b0 && nl_bot != 12'd0) begin
                        field    <= 1'b1;
                        lif      <= 12'd0;
                        abs_line <= 12'd1;
                        nib_cnt  <= 2'd0;
                        rd_ptr   <= w_bot;
                        state    <= RLE_LINE;
                    end else begin
                        state <= COMMIT;
                    end
                end else begin
                    lif      <= lif + 12'd1;
                    abs_line <= field ? (((lif + 12'd1) << 1) | 12'd1) : ((lif + 12'd1) << 1);
                    state    <= RLE_LINE;
                end
            end

            // ---- commit the working params: the subtitle becomes visible ----
            COMMIT: begin
                c_sx <= w_sx; c_ex <= w_ex; c_sy <= w_sy; c_ey <= w_ey;
                c_a0 <= w_a0; c_a1 <= w_a1; c_a2 <= w_a2; c_a3 <= w_a3;
                c_c0 <= w_c0; c_c1 <= w_c1; c_c2 <= w_c2; c_c3 <= w_c3;
                // CONTIGUITY CLAMP: never open a hole the author did not write. If
                // the hold was cut short, w_show_eff is still in the future and
                // committing it would blank the outgoing unit -- which is the whole
                // defect. When the two windows abut (or the outgoing one is
                // persistent), show immediately instead; when the author DID write a
                // gap, keep the authored time and let the outgoing unit hide on its
                // own schedule.
                c_show  <= (spu_contig && !spu_due) ? stc : w_show_eff;
                c_hide  <= w_has_hide ? w_hide : 33'h1_FFFF_FFFF;  // stay if no STP_DSP
                c_valid <= 1'b1;
                c_pts   <= pts_latched;    // remember this unit's PTS (menu re-send guard)
                state   <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
