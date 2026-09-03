// ============================================================================
// dvd/seek_time.sv -- what time will this seek land on?
// ============================================================================
// The transport HUD's clock showed the LIVE playhead and nothing else, so it
// sat frozen through every seek gesture while the seek bar's amber cursor
// travelled -- the bar told you where you were going and the number told you
// where you had been. Two different reasons, one symptom:
//   - a held FF/REW asserts hold_freeze, which stops the governor; the demux
//     stops draining, DSI packets stop arriving and dsi_c_eltm coasts then
//     stops. cell_i cannot change either, so cur_cell_start is nailed too.
//   - a chapter burst does not pause at all: nothing seeks until the ~500 ms
//     debounce closes, so the clock honestly reports the old position while the
//     chapter number counts up to the projected target.
// dvd/seek_bar.sv already solved exactly this for the CURSOR (its header
// records that "the bar sat frozen at the live playhead while the chapter
// number counted up"). This does it for the number.
//
// ★ THREE SOURCES, IN THE ORDER THEY CAN BE TRUSTED.
//   1. D-pad gesture -- dpad_seek already knows the request as an exact signed
//      MM:S0, so the answer is live +/- delta. No map, no division.
//   2. Chapter skip -- pmap[chapter] gives the entry CELL and cell_start gives
//      its authored start time. EXACT, and the same two-step seek_bar walks to
//      place its notches.
//   3. Held scrub / a resolved D-pad jump -- only an RBN is known, so bracket
//      it between the two cells it falls between and interpolate inside:
//        secs = lo_secs + ((hi_secs - lo_secs) * q) >> 8,  q = (off << 8) / cell
//      Bitrate varies little INSIDE one cell, so the error is seconds. The
//      obvious cheaper model -- scale the title's total time by the bar's own
//      0..512 fraction -- was rejected: it assumes a constant bitrate across the
//      WHOLE title, so on a VBR DVD the preview would disagree with the landed
//      time by minutes and the number would visibly jump when the seek
//      completed, which is a worse bug than the frozen clock it replaces.
//
// ★ EVERYTHING IS BINARY SECONDS UNTIL THE LAST STEP. dvd/bcd_time_add.sv has
// no subtract port and cannot cheaply get one, and a backward jump and a
// prev-chapter burst both need one; meanwhile the reader's per-cell duration is
// ALREADY binary seconds. So the reader carries a binary prefix sum alongside
// its BCD one (cellf_secs) and this module converts once, at the end.
//
// ★ WHY A SIBLING OF seek_bar AND NOT PART OF IT. seek_bar's cellf_ram has one
// read port and its divider FSM owns it; arbitrating a second consumer onto a
// proven display module is the wrong risk for a readout. The cost is a second
// shadow of maps that are only written once per PGC load.
//
// ★ FIT DISCIPLINE: the three shadows are SYNC-read (never async-indexed -- the
// recurring LUT-RAM ALM explosion), and there is no *, / or % operator here.
// The one product and the one quotient are serial.
//
// KNOWN CHARACTERISTICS (documented, not bugs):
//  - A cell's RBN span is taken as first[i+1] - first[i]. With interleaved or
//    angle blocks that is an approximation; for a preview it is immaterial.
//  - The shadows hold 128 entries and index cell[6:0], so cells >= 128 alias.
//    That is exactly what the reader's own cur_cell_start does today; it is not
//    a new limit.
// ============================================================================
`default_nettype none

module seek_time (
    input  wire        clk,
    input  wire        rst_n,             // reset_n -- the maps must survive the
                                          // seeks this module describes

    // ---- shadow taps (the streams emu already routes to seek_bar) ----------
    input  wire        pm_we,
    input  wire [6:0]  pm_waddr,
    input  wire [7:0]  pm_wdata,          // program -> entry cell, 1-based
    input  wire        cellf_we,
    input  wire [6:0]  cellf_idx,
    input  wire [31:0] cellf_rbn,
    input  wire [15:0] cellf_secs,
    input  wire [15:0] title_secs,        // total, = the last cell's end

    input  wire [31:0] title_first_rbn,
    input  wire [31:0] title_last_rbn,

    // ---- requests, highest priority first ---------------------------------
    input  wire        dpad_pend,
    input  wire        dpad_dir,          // 1 = forward
    input  wire [6:0]  dpad_min,          // |request| whole minutes
    input  wire [2:0]  dpad_sec,          // ...and TENS of seconds (0..5)
    input  wire        chap_prev,
    input  wire [7:0]  chap_pgm,          // projected chapter, 1-based
    input  wire        bar_active,
    input  wire [31:0] bar_tgt_rbn,

    input  wire [31:0] live_time,         // packed BCD playhead

    // In SECONDS; dvd/secs_bcd.sv (shared with dvd/lin_rate.sv) renders it as
    // the packed BCD the HUD reads. Only one clock is ever displayed at a time,
    // so a private converter here bought nothing -- measured, 166 ALUTs and 56
    // registers.
    output reg  [16:0] prev_secs,
    output reg         prev_ok
);
    // =====================================================================
    // Shadows. Each stream rewrites from index 0 on every PGC walk, so a
    // write to index 0 is the reset point for the entry count -- no separate
    // "maps are being rebuilt" handshake is needed.
    // =====================================================================
    reg [7:0]  pmap_ram  [0:127];
    reg [31:0] cellf_ram [0:127];
    reg [15:0] cstart_ram[0:127];
    reg [7:0]  cell_n, pm_n;

    reg [6:0]  pm_ra, cf_ra;
    reg [7:0]  pm_q;
    reg [31:0] cf_q;
    reg [15:0] cs_q;

    always @(posedge clk) begin
        if (pm_we)    pmap_ram[pm_waddr] <= pm_wdata;
        if (cellf_we) begin
            cellf_ram [cellf_idx] <= cellf_rbn;
            cstart_ram[cellf_idx] <= cellf_secs;
        end
        pm_q <= pmap_ram [pm_ra];
        cf_q <= cellf_ram[cf_ra];
        cs_q <= cstart_ram[cf_ra];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cell_n <= 8'd0; pm_n <= 8'd0; end
        else begin
            if (cellf_we) cell_n <= (cellf_idx == 7'd0) ? 8'd1
                                                        : {1'b0, cellf_idx} + 8'd1;
            if (pm_we)    pm_n   <= (pm_waddr  == 7'd0) ? 8'd1
                                                        : {1'b0, pm_waddr}  + 8'd1;
        end
    end

    // =====================================================================
    // Request selection + change detection.
    // =====================================================================
    localparam [1:0] SEL_NONE = 2'd0, SEL_DPAD = 2'd1,
                     SEL_CHAP = 2'd2, SEL_BAR  = 2'd3;

    // BCD playhead -> seconds. Every constant multiply is written as a sum of
    // SHIFTS on a pre-widened value: x10 = <<3 + <<1, x60 = <<5+<<4+<<3+<<2,
    // x3600 = <<11+<<10+<<9+<<4. Doing it with concatenations instead is how
    // the first version of this block silently computed h*44.
    // ⚠ The TENS-of-hours digit is deliberately not decoded. Every producer of
    // live_time saturates at 9:59:59 (dvd/secs_bcd.sv clamps it there, and a PGC
    // playback time is spec-capped too), and transport_hud renders only [27:8]
    // -- the hours ONES nibble -- so a tens digit could not be displayed even if
    // one arrived. Decoding it cost two 17-bit adds for a provably-zero term.
    wire [7:0]  hh_o = {4'd0, live_time[27:24]};
    wire [7:0]  mm_t = {4'd0, live_time[23:20]};
    wire [7:0]  mm_o = {4'd0, live_time[19:16]};
    wire [7:0]  ss_t = {4'd0, live_time[15:12]};
    wire [7:0]  ss_o = {4'd0, live_time[11:8]};
    wire [16:0] lv_h = {9'd0, hh_o};
    wire [16:0] lv_m = {9'd0, (mm_t << 3) + (mm_t << 1) + mm_o};
    wire [16:0] lv_s = {9'd0, (ss_t << 3) + (ss_t << 1) + ss_o};
    wire [16:0] lv_secs = (lv_h << 11) + (lv_h << 10) + (lv_h << 9) + (lv_h << 4)
                        + (lv_m << 5)  + (lv_m << 4)  + (lv_m << 3) + (lv_m << 2)
                        + lv_s;
    // dpad_sec is TENS of seconds, and dpad_min minutes: delta = m*60 + s*10.
    wire [16:0] dp_m = {10'd0, dpad_min};
    wire [16:0] dp_s = {14'd0, dpad_sec};
    wire [16:0] dp_delta = (dp_m << 5) + (dp_m << 4) + (dp_m << 3) + (dp_m << 2)
                         + (dp_s << 3) + (dp_s << 1);

    wire [1:0]  sel = dpad_pend  ? SEL_DPAD :
                      chap_prev  ? SEL_CHAP :
                      bar_active ? SEL_BAR  : SEL_NONE;
    // 32 bits is the widest request any source can pose (a bar target RBN); the
    // D-pad's dir+min+sec+seconds is 28 and a chapter is 8.
    wire [31:0] key = (sel == SEL_DPAD) ? {2'd0, dpad_dir, dpad_min, dpad_sec,
                                           4'd0, lv_secs}
                    : (sel == SEL_CHAP) ? {24'd0, chap_pgm}
                    : (sel == SEL_BAR ) ? bar_tgt_rbn
                                        : 32'd0;

    reg [1:0]  sel_l;
    reg [31:0] key_l;

    // =====================================================================
    // Resolve FSM.
    // =====================================================================
    localparam [3:0] S_IDLE  = 4'd0,  S_CH_A = 4'd1,  S_CH_B = 4'd2,
                     S_CH_C  = 4'd3,  S_CH_D = 4'd4,
                     S_SC_A  = 4'd5,  S_SC_B = 4'd6,  S_SC_C = 4'd7,
                     S_LO    = 4'd8,  S_HI   = 4'd9,  S_DIV  = 4'd10,
                     S_MUL   = 4'd11, S_SUM  = 4'd12, S_PUB  = 4'd13;

    reg [3:0]  st;
    reg [31:0] tgt;
    reg [7:0]  scan_i;
    reg        lo_ok;
    reg [31:0] lo_rbn, hi_rbn;
    reg [15:0] lo_secs, hi_secs;
    reg [16:0] secs;

    // ⚠ WIDTHS ARE ARGUED. off < c_span, and c_span is one cell's sector span,
    // bounded by a whole dual-layer DVD (~4.2 M sectors = 2^22). dv_n therefore
    // holds off<<8 in 30 bits and the remainder needs only c_span's width + 1;
    // carrying 31 bits cost 7 spare bits of comparator and subtractor in the
    // divide loop. c_span_ok is the guard that keeps that bound honest rather
    // than assumed -- an out-of-range span degenerates to the cell start instead
    // of silently producing a wrong quotient.
    reg [29:0] dv_n;
    reg [23:0] dv_rem;
    reg [8:0]  dv_q;
    reg [5:0]  dv_i;
    wire [24:0] rem_n    = {dv_rem[23:0], dv_n[29]};
    wire [31:0] c_span   = hi_rbn - lo_rbn;
    wire        c_span_ok= (c_span[31:23] == 9'd0) && (c_span != 32'd0);
    wire [24:0] c_span_x = {2'd0, c_span[22:0]};
    wire        div_ge   = (rem_n >= c_span_x);
    wire [24:0] rem_next = div_ge ? (rem_n - c_span_x) : rem_n;
    // off < c_span always (tgt is inside the bracket), so the quotient of
    // (off << 8) / c_span is at most 256 and the 9-bit dv_q cannot lose a
    // significant bit out of the top.
    wire [31:0] cell_off = tgt - lo_rbn;

    reg [23:0] ml_acc;
    reg [3:0]  ml_i;

    // No readout clamp here either -- dvd/secs_bcd.sv owns the single 9:59:59
    // clamp, so it is the one place a test can prove it exists.

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; sel_l <= SEL_NONE; key_l <= 32'd0;
            prev_secs <= 17'd0; prev_ok <= 1'b0;
            pm_ra <= 7'd0; cf_ra <= 7'd0;
            tgt <= 32'd0; scan_i <= 8'd0; lo_ok <= 1'b0;
            lo_rbn <= 32'd0; hi_rbn <= 32'd0; lo_secs <= 16'd0; hi_secs <= 16'd0;
            secs <= 17'd0;
            dv_n <= 30'd0; dv_rem <= 24'd0; dv_q <= 9'd0; dv_i <= 6'd0;
            ml_acc <= 24'd0; ml_i <= 4'd0;
        end else begin
            if (sel == SEL_NONE) begin
                prev_ok <= 1'b0;
                sel_l   <= SEL_NONE;
                st      <= S_IDLE;
            end else if ((sel != sel_l) || (key != key_l)) begin
                // A new question. Answer it from scratch -- never mix a latched
                // bracket with a later target.
                sel_l  <= sel;
                key_l  <= key;
                lo_ok  <= 1'b0;
                scan_i <= 8'd0;
                case (sel)
                    SEL_DPAD: begin
                        // live +/- delta, floored at 0 and capped at the title,
                        // because scrub_ctrl clamps the real seek the same way.
                        if (dpad_dir)
                            secs <= ((lv_secs + dp_delta) > {1'b0, title_secs})
                                    ? {1'b0, title_secs} : (lv_secs + dp_delta);
                        else
                            secs <= (lv_secs > dp_delta) ? (lv_secs - dp_delta)
                                                         : 17'd0;
                        st <= S_PUB;
                    end
                    SEL_CHAP: begin
                        pm_ra <= (chap_pgm != 8'd0) ? (chap_pgm[6:0] - 7'd1) : 7'd0;
                        st    <= S_CH_A;
                    end
                    default: begin
                        tgt <= (bar_tgt_rbn < title_first_rbn) ? title_first_rbn :
                               (bar_tgt_rbn > title_last_rbn)  ? title_last_rbn
                                                               : bar_tgt_rbn;
                        st  <= S_SC_A;
                    end
                endcase
            end else begin
                case (st)
                    S_IDLE: ;                       // answered; waiting on a change

                    // ---- chapter: pmap[c-1] -> cell, cstart[cell] ----------
                    S_CH_A: st <= S_CH_B;           // pm_q settling
                    S_CH_B: begin
                        // Out of range, or a chapter this PGC's map does not
                        // describe: say nothing rather than guess.
                        if ((chap_pgm == 8'd0) || (chap_pgm > pm_n)
                            || (pm_q == 8'd0) || (pm_q > cell_n)) begin
                            secs <= 17'd0; st <= S_IDLE;
                            prev_ok <= 1'b0;
                        end else begin
                            cf_ra <= pm_q[6:0] - 7'd1;
                            st    <= S_CH_C;
                        end
                    end
                    S_CH_C: st <= S_CH_D;           // cs_q settling
                    S_CH_D: begin
                        secs <= {1'b0, cs_q};
                        st <= S_PUB;
                    end

                    // ---- RBN: find the bracketing cell --------------------
                    S_SC_A: begin cf_ra <= scan_i[6:0]; st <= S_SC_B; end
                    S_SC_B: st <= S_SC_C;           // cf_q / cs_q settling
                    S_SC_C: begin
                        if ((scan_i >= cell_n) || (cf_q > tgt)) begin
                            // bracket closed: the last cell at or below tgt,
                            // and scan_i above it. The upper edge
                            // of the LAST cell is the title's own end, which is
                            // why the reader exports title_secs.
                            hi_rbn  <= (scan_i >= cell_n) ? title_last_rbn : cf_q;
                            hi_secs <= (scan_i >= cell_n) ? title_secs     : cs_q;
                            // Before the first cell there is nothing to
                            // interpolate between -- go straight to the digits
                            // with 0, never through S_SUM, which would fold in
                            // a stale product from a previous request.
                            if (lo_ok) st <= S_LO;
                            else begin
                                secs <= 17'd0;
                                st <= S_PUB;
                            end
                        end else begin
                            lo_ok   <= 1'b1;
                            lo_rbn  <= cf_q;
                            lo_secs <= cs_q;
                            scan_i  <= scan_i + 8'd1;
                            st      <= S_SC_A;
                        end
                    end
                    S_LO: begin
                        // q = (off << 8) / cell_span, a 0..255 fraction.
                        if (!c_span_ok) begin
                            secs <= {1'b0, lo_secs};     // degenerate cell
                            st <= S_PUB;
                        end else begin
                            dv_n   <= {cell_off[21:0], 8'd0};
                            dv_rem <= 24'd0;
                            dv_q   <= 9'd0;
                            dv_i   <= 6'd30;
                            st     <= S_DIV;
                        end
                    end
                    S_DIV: begin
                        dv_rem <= rem_next[23:0];
                        dv_n   <= {dv_n[28:0], 1'b0};
                        dv_q   <= {dv_q[7:0], div_ge};
                        if (dv_i == 6'd1) begin
                            ml_acc <= 24'd0; ml_i <= 4'd8; st <= S_MUL;
                        end else dv_i <= dv_i - 6'd1;
                    end
                    S_MUL: begin
                        // (hi_secs - lo_secs) * q, MSB-first over 9 bits.
                        ml_acc <= {ml_acc[22:0], 1'b0}
                                  + (dv_q[ml_i] ? {8'd0, (hi_secs - lo_secs)} : 24'd0);
                        if (ml_i == 4'd0) st <= S_SUM;
                        else              ml_i <= ml_i - 4'd1;
                    end
                    S_SUM: begin                    // reached ONLY by S_MUL
                        secs <= {1'b0, lo_secs} + {1'b0, ml_acc[23:8]};
                        st <= S_PUB;
                    end

                    default: begin                  // S_PUB
                        prev_secs <= secs;
                        prev_ok   <= 1'b1;
                        st        <= S_IDLE;
                    end
                endcase
            end
        end
    end
endmodule
`default_nettype wire
