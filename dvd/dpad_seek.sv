// ============================================================================
// dvd/dpad_seek.sv -- VLC-style FIXED-TIME seek on the D-pad (O[45] opt-in)
// ============================================================================
// Left/Right = -/+10 s, Down/Up = -/+60 s while a TITLE plays. Unlike the
// hold-to-seek scrub (dvd/scrub_ctrl.sv), whose step is SPAN-relative
// (span >> {12,10,8,6} sectors per tick = "percent of title"), this module seeks
// by SECONDS, using the disc's OWN authored seek tables.
//
// ★ WHERE THE TARGET COMES FROM. Every DVD NAV pack's DSI carries the VOBU_SRI
// +/-time seek tables fwda[19]/bwda[19] (dvd/nav_dsi.sv parses them into the
// dsi_tbl BRAM; golden decoder tools/nav_extract.py --dpad). Interval for entry
// i is stime[i]/2 s with stime = {240,120,60,20,15,14,...,2,1}, so:
//     +120 s = fwda[0]   +60 s = fwda[1]   +30 s = fwda[2]   +10 s = fwda[3]
// and the backward mirror of fwd index a is bwda address (37 - a) -- i.e.
//     -120 s = addr 37   -60 s = addr 36   -30 s = addr 35   -10 s = addr 34.
//   offset = entry[29:0];  valid = entry[31] && offset != 0x3fffffff (END_OF_CELL)
//   target = dsi_nv_pck_lbn +/- offset            [VTSTT_VOBS RBN space]
// The target is handed to scrub_ctrl's jump port, which clamps it to the title
// span and issues the ONE proven raw-RBN seek. The reader then VOBU-snaps it
// (S_NAV_SEEK), so every landing is an I-frame.
//
// ★ WHY COALESCE, NEVER AUTO-REPEAT. Holding a direction to fire a jump every
// VOBU would be exactly the rapid flush/re-lock regime that HW rounds 1-2 of the
// scrub proved fatal (mostly-black playback + watchdog resync -- see the header
// of dvd/scrub_ctrl.sv). Instead presses ACCUMULATE over a ~400 ms window and
// exactly ONE seek fires when it closes -- the same debounce shape as the
// chapter-skip burst in emu.sv. Tap Right 3x = one +30 s jump, one flush.
//
// ★ WHY A GREEDY LADDER, NOT N x THE 10 s ENTRY. All 19 entries are offsets from
// the SAME nv_pck_lbn, so a multi-term sum models "T1+T2 seconds" only if the
// average bitrate is flat over the window -- exact on CBR, approximate on VBR.
// Decomposing greedily over the COARSE ladder {120,60,30,10} s minimises the
// number of terms, which makes the common gestures EXACT single lookups:
//     1xR=10 s -> fwda[3]   3xR=30 s -> fwda[2]   6xR / 1xU=60 s -> fwda[1]
//     2xU=120 s -> fwda[0]                        (2xR=20 s: no 20 s rung exists)
// Keep tapping and the total keeps growing -- there is no small artificial
// ceiling. UNIT_CAP only exists so the MM:SS readout stays exact (99:50 max);
// what really bounds a jump is scrub_ctrl's clamp to the title span, which is
// the honest limit. A big total just decomposes into more 120 s rungs (a few
// cycles each), so the resolve stays cheap.
// There is no better composition available: the interval set is fixed by the
// spec, and true absolute time seek needs the VTS TMAP -- RETIRED by user
// decision (docs/dvd_nav.md), do NOT re-propose it.
//
// ★ THE STALE-TABLE TRAP (this is why dsi_fresh exists). nav_dsi's rst_n is
// pipe_rst_n, which resets on every load/seek/jump: it clears dsi_nv_pck_lbn to
// 0, but dsi_tbl/tbl_rdata are written by a SEPARATE UNRESET always block and
// keep the PREVIOUS VOBU's offsets. Resolving in that window computes
// target = 0 + stale_offset, which scrub_ctrl clamps -> A JUMP TO THE START OF
// THE TITLE. And "tap, then tap again 200 ms later" is exactly what a real user
// does. So: dsi_fresh (set by dsi_commit, cleared by nav_flush) gates ENTRY to
// the resolve, and nav_flush / a new DSI packet mid-resolve RESTARTS it. The
// base is latched ONCE, on entry, and exported as jump_base so scrub_ctrl can
// never pair it with a different VOBU's offsets.
//
// ★ FIT DISCIPLINE (the parse_buf 226%-ALM and AC-3 baptab incidents). There is
// exactly ONE nav_dsi read port and this FSM drives it SEQUENTIALLY. Do NOT
// "simplify" by latching all four rungs at once (that replicates the M10K x4),
// do NOT mirror dsi_tbl locally, and do NOT add a seconds->address lookup array
// (the ladder is a case over four constants plus a counter). This module holds
// no arrays at all.
//
// KNOWN, DOCUMENTED CHARACTERISTICS (docs/dvd_nav.md 2b):
//  - dsi_nv_pck_lbn is PARSE-FRONT timed, ~1 s ahead of the displayed picture,
//    so +10 s lands ~+11 s and -10 s ~-9 s relative to what is on screen.
//  - bwda's 60 s rung is END_OF_CELL for the first 60 s of every cell, so a
//    backward 60 s there cascades down to ~10 s or the cell start.
//  - Raw VCD/SVCD (no DSI) uses the exact CD geometry instead: 75 sectors/s of
//    2352 B over the reader's 2048-byte linear block unit = 86.13 blk/s, so
//    10 s = 861 blocks. Exact for VCD (CBR); approximate for SVCD (VBR).
//    Flat .mpg/.VOB has no derivable rate and is deliberately inert here.
// ============================================================================

module dpad_seek #(
    parameter COALESCE = 24'd10_800_000,  // ~400 ms @ 27 MHz coalesce window
    parameter FRESH_TO = 26'd54_000_000,  // ~2 s wait-for-fresh, then drop
    parameter LIN_10S  = 24'd861,         // 10 s of raw-CD file blocks (75*2352/2048)
    parameter UNIT_CAP = 12'd599,         // 599 units = 99:50, the widest MM:SS
                                          // readout. Not a seek limit: the title
                                          // span clamp in scrub_ctrl is.
    parameter MAXTERMS = 10'd64           // bound the resolve loop (>= 599/12)
) (
    input  wire        clk,               // clk_sys (27 MHz)
    input  wire        rst_n,             // reset_n -- NOT pipe_rst_n: a pending
                                          // gesture must survive the seek it causes
    input  wire        en,                // O[45] "D-Pad Seek"
    input  wire        in_title,          // (cell_ready||lin_seek_ok) && !menu_active
                                          //                          && !in_title_menu
    input  wire        dvd_mode,          // cell_ready  -> DSI table path
    input  wire        lin_mode,          // raw CD image -> fixed-rate constants

    input  wire        up_edge,           // D-pad press edges
    input  wire        dn_edge,
    input  wire        lf_edge,
    input  wire        rt_edge,
    input  wire        cancel,            // abort any pending gesture

    // ---- nav_dsi coupling -------------------------------------------------
    input  wire        nav_flush,         // load_flush: scalars cleared, dsi_tbl STALE
    input  wire        dsi_commit,        // 1-cyc: a DSI packet finished parsing
    input  wire        dsi_stream,        // ps_dsi_valid: DSI bytes rewriting dsi_tbl
    input  wire [31:0] dsi_nv_pck_lbn,
    input  wire [31:0] dsi_vobu_ea,
    input  wire [31:0] dsi_next_vobu,
    input  wire [31:0] dsi_prev_vobu,
    output reg  [5:0]  tbl_raddr,         // -> nav_dsi.tbl_raddr  (THE one port)
    input  wire [31:0] tbl_rdata,         // <- nav_dsi.tbl_rdata  (1-cycle latency)

    input  wire [31:0] lin_blk,           // linear playhead (base in lin_mode)
    input  wire [23:0] lin_blk10,         // blocks per 10 s of linear file.
                                          // 0 = no rate known -> off_acc stays 0
                                          // and S_FIRE's existing guard turns
                                          // the gesture into pend_fail.

    // ---- -> scrub_ctrl jump mode ------------------------------------------
    output reg         jump_fire,         // 1-cyc: resolved, go
    output reg         jump_dir,          // 1 = forward
    output reg  [31:0] jump_base,         // the base the offsets were READ against
    output reg  [31:0] jump_off,          // magnitude (RBN sectors / file blocks)

    // ---- -> HUD ------------------------------------------------------------
    output wire        pend,              // a gesture is open
    output reg         pend_dir,          // 1 = forward
    output reg  [1:0]  pend_n,            // presses-1, saturating (the "xN" field)
    output reg  [6:0]  pend_min,          // |request| as MM:SS -- whole minutes
    output reg  [2:0]  pend_sec,          //   ...and tens of seconds (0..5)
    output reg         pend_evt,          // 1-cyc per counted press (pop the HUD)
    output reg         pend_fail          // 1-cyc: resolve dead-ended / timed out
);

    localparam [2:0] S_IDLE = 3'd0,   // no gesture
                     S_WIN  = 3'd1,   // coalesce window open
                     S_WAIT = 3'd2,   // window closed; wait for a trustworthy DSI
                     S_PICK = 3'd3,   // choose the rung / accumulate (linear)
                     S_RD   = 3'd4,   // BRAM read-latency bubble
                     S_EVAL = 3'd5,   // consume tbl_rdata
                     S_VOBU = 3'd6,   // +/-1-VOBU structural fallback
                     S_FIRE = 3'd7;   // hand off to scrub_ctrl

    localparam [29:0] END_OF_CELL = 30'h3fff_ffff;

    reg  [2:0]  state;
    reg  [23:0] win_cnt;              // coalesce window
    reg  [25:0] wait_tmr;             // bounded wait for dsi_fresh
    reg signed [13:0] net10;          // signed request, units of 10 s (+-UNIT_CAP)
    reg  [11:0] units_left;           // units of 10 s still to resolve
    reg  [4:0]  ridx;                 // FORWARD-equivalent table index 0..18
    reg  [23:0] off_acc;              // accumulated offset (sectors / blocks)
    reg  [9:0]  terms;                // resolve-loop term count
    reg         req_dir;              // 1 = forward
    reg  [2:0]  press_n;              // presses this gesture, saturating at 4
    reg         dsi_fresh;            // dsi_tbl + scalars belong to the SAME VOBU
    // MM:SS readout. The accumulator counts units of 10 s, so the display needs
    // units/6 and units%6 -- done by repeated subtraction over the (idle) cycles
    // of the coalesce window rather than a divider: <=99 iterations vs a ~400 ms
    // window, and it keeps the module free of any wide arithmetic.
    reg  [11:0] dv_rem;
    reg  [6:0]  dv_min;
    reg         dv_busy;

    assign pend = (state != S_IDLE);

    // ---- press decode ------------------------------------------------------
    // Seeking is only offered where a target is derivable: a DVD title (DSI
    // tables) or a raw CD image (fixed geometry). A flat .mpg/.VOB is seekable
    // by the scrub but has no derivable byte rate, so the D-pad stays inert.
    wire seek_ok  = en && in_title && (dvd_mode || lin_mode);
    wire any_pr   = rt_edge | lf_edge | up_edge | dn_edge;
    wire press    = seek_ok && any_pr;
    // Right beats Left, Up beats Down if two edges land in one cycle.
    wire signed [13:0] pr_delta = rt_edge ? 14'sd1 : lf_edge ? -14'sd1 :
                                  up_edge ? 14'sd6 : -14'sd6;

    wire signed [13:0] cap_p   =  $signed({2'd0, UNIT_CAP});
    wire signed [13:0] cap_n   = -$signed({2'd0, UNIT_CAP});
    wire signed [13:0] net_sum = net10 + pr_delta;
    wire signed [13:0] net_nxt = (net_sum > cap_p) ? cap_p :
                                 (net_sum < cap_n) ? cap_n : net_sum;
    wire [11:0] net_abs = net_nxt[13] ? (~net_nxt[11:0] + 12'd1) : net_nxt[11:0];
    // |net10| itself: the window close needs the magnitude with no fresh press.
    wire [11:0] net_mag = net10[13]  ? (~net10[11:0]   + 12'd1) : net10[11:0];

    // ---- table entry decode ------------------------------------------------
    wire        ent_ok  = tbl_rdata[31] && (tbl_rdata[29:0] != END_OF_CELL);
    wire        nxv_ok  = dsi_next_vobu[31] && (dsi_next_vobu[29:0] != END_OF_CELL);
    wire        pvv_ok  = dsi_prev_vobu[31] && (dsi_prev_vobu[29:0] != END_OF_CELL);

    // saturating 24-bit accumulate (a dual-layer disc is ~4.2M sectors, so 24
    // bits never actually saturates on real media -- this only bounds garbage).
    function [23:0] sat_add(input [23:0] acc, input [29:0] add);
        reg [24:0] s;
        begin
            if (add[29:24] != 6'd0) sat_add = 24'hffffff;
            else begin
                s = {1'b0, acc} + {1'b0, add[23:0]};
                sat_add = s[24] ? 24'hffffff : s[23:0];
            end
        end
    endfunction

    // coarse ladder rung -> units of 10 s (12=120s, 6=60s, 3=30s, 1=10s)
    function [11:0] rung_u(input [4:0] r);
        case (r)
            5'd0:    rung_u = 12'd12;
            5'd1:    rung_u = 12'd6;
            5'd2:    rung_u = 12'd3;
            default: rung_u = 12'd1;
        endcase
    endfunction

    // greedy pick: the largest coarse rung that fits in what's left
    wire [4:0] pick_r = (units_left >= 12'd12) ? 5'd0 :
                        (units_left >= 12'd6)  ? 5'd1 :
                        (units_left >= 12'd3)  ? 5'd2 : 5'd3;

    // fwd index a -> table address; the backward mirror of a is (37 - a).
    function [5:0] addr_of(input dir, input [4:0] r);
        addr_of = dir ? {1'b0, r} : (6'd37 - {1'b0, r});
    endfunction

    wire [11:0] use_u  = rung_u(ridx);
    wire       last_t  = (units_left <= use_u) || ((terms + 10'd1) >= MAXTERMS);

    // A new DSI packet rewriting dsi_tbl, or a flush changing the base, makes a
    // resolve in flight untrustworthy -- restart it rather than mixing VOBUs.
    wire resolve_busy = (state == S_PICK) || (state == S_RD) ||
                        (state == S_EVAL) || (state == S_VOBU);
    wire disturb      = nav_flush || dsi_stream || dsi_commit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            win_cnt    <= 24'd0;
            wait_tmr   <= 26'd0;
            net10      <= 14'sd0;
            units_left <= 12'd0;
            ridx       <= 5'd0;
            off_acc    <= 24'd0;
            terms      <= 10'd0;
            dv_rem     <= 12'd0;
            dv_min     <= 7'd0;
            dv_busy    <= 1'b0;
            req_dir    <= 1'b0;
            press_n    <= 3'd0;
            dsi_fresh  <= 1'b0;
            tbl_raddr  <= 6'd0;
            jump_fire  <= 1'b0;
            jump_dir   <= 1'b0;
            jump_base  <= 32'd0;
            jump_off   <= 32'd0;
            pend_dir   <= 1'b0;
            pend_n     <= 2'd0;
            pend_min   <= 7'd0;
            pend_sec   <= 3'd0;
            pend_evt   <= 1'b0;
            pend_fail  <= 1'b0;
        end else begin
            jump_fire <= 1'b0;                  // defaults: one-cycle pulses
            pend_evt  <= 1'b0;
            pend_fail <= 1'b0;

            // ---- freshness latch (see the STALE-TABLE TRAP note above) -----
            if (nav_flush)       dsi_fresh <= 1'b0;
            else if (dsi_commit) dsi_fresh <= 1'b1;

            // ---- MM:SS readout: units/6 by repeated subtraction ------------
            // Restarted by each press below (a later assignment in this block),
            // so it always converges on the newest total.
            if (dv_busy) begin
                if (dv_rem >= 12'd6) begin
                    dv_rem <= dv_rem - 12'd6;
                    dv_min <= dv_min + 7'd1;
                end else begin
                    dv_busy  <= 1'b0;
                    pend_min <= dv_min;
                    pend_sec <= dv_rem[2:0];
                end
            end

            if (cancel || !seek_ok) begin
                // No late surprise jumps: leaving the title, a VM jump, a
                // chapter skip or a FF/REW grab drops the gesture entirely.
                state      <= S_IDLE;
                net10      <= 14'sd0;
                off_acc    <= 24'd0;
                terms      <= 10'd0;
                units_left <= 12'd0;
                dv_busy    <= 1'b0;
                pend_min   <= 7'd0;
                pend_sec   <= 3'd0;
            end else if (press) begin
                // A press always (re)opens the window and invalidates any
                // partial resolve -- the total changed, so the offset must be
                // recomputed from scratch against a single base.
                net10      <= net_nxt;
                dv_rem     <= net_abs;      // restart the MM:SS conversion
                dv_min     <= 7'd0;
                dv_busy    <= 1'b1;
                pend_dir   <= (net_nxt > 14'sd0);
                press_n    <= (state == S_IDLE) ? 3'd1 :
                              (press_n >= 3'd4) ? 3'd4 : press_n + 3'd1;
                pend_n     <= (state == S_IDLE) ? 2'd0 :
                              (press_n >= 3'd4) ? 2'd3 : press_n[1:0];
                pend_evt   <= 1'b1;
                win_cnt    <= COALESCE;
                off_acc    <= 24'd0;
                terms      <= 10'd0;
                state      <= S_WIN;
            end else if (disturb && resolve_busy) begin
                // Restart against a trustworthy base. wait_tmr is NOT reloaded,
                // so the total wait stays bounded by FRESH_TO.
                off_acc <= 24'd0;
                terms   <= 10'd0;
                state   <= S_WAIT;
            end else begin
                case (state)

                // ---- coalesce window ----------------------------------------
                S_WIN: begin
                    if (win_cnt != 24'd0) win_cnt <= win_cnt - 24'd1;
                    else if (net10 == 14'sd0) begin
                        state <= S_IDLE;                 // L+R cancelled out
                    end else begin
                        req_dir    <= (net10 > 14'sd0);
                        units_left <= net_mag;
                        wait_tmr   <= FRESH_TO;
                        if (lin_mode) jump_base <= lin_blk;
                        state      <= S_WAIT;
                    end
                end

                // ---- wait for a base + table from the SAME VOBU --------------
                S_WAIT: begin
                    if (lin_mode) begin
                        state <= S_PICK;                 // no DSI involved
                    end else if (wait_tmr == 26'd0) begin
                        pend_fail <= 1'b1;               // never fire on stale data
                        net10     <= 14'sd0;
                        state     <= S_IDLE;
                    end else begin
                        wait_tmr <= wait_tmr - 26'd1;
                        if (dsi_fresh && !dsi_stream && !dsi_commit) begin
                            jump_base <= dsi_nv_pck_lbn; // latched ONCE
                            ridx      <= pick_r;
                            tbl_raddr <= addr_of(req_dir, pick_r);
                            state     <= S_RD;
                        end
                    end
                end

                // ---- pick the next rung (DVD) / accumulate (linear) ----------
                S_PICK: begin
                    if (lin_mode) begin
                        off_acc <= sat_add(off_acc, {6'd0, LIN_10S});
                        if (units_left <= 12'd1) state <= S_FIRE;
                        else units_left <= units_left - 12'd1;
                    end else begin
                        ridx      <= pick_r;
                        tbl_raddr <= addr_of(req_dir, pick_r);
                        state     <= S_RD;
                    end
                end

                // ---- BRAM latency bubble ------------------------------------
                S_RD: state <= S_EVAL;

                // ---- consume the entry --------------------------------------
                S_EVAL: begin
                    if (ent_ok) begin
                        off_acc <= sat_add(off_acc, tbl_rdata[29:0]);
                        if (ridx >= 5'd4) begin
                            // a FINE rung (7.5 s .. 2 s): take it and stop, so a
                            // 60 s request can't degenerate into a long chain of
                            // sub-second extrapolations.
                            state <= S_FIRE;
                        end else begin
                            terms      <= terms + 10'd1;
                            units_left <= (units_left > use_u) ? (units_left - use_u) : 12'd0;
                            state      <= last_t ? S_FIRE : S_PICK;
                        end
                    end else if (ridx >= 5'd15) begin
                        state <= S_VOBU;                 // whole ladder exhausted
                    end else begin
                        // END_OF_CELL: descend one rung. Leftover seconds are
                        // credited automatically (only the rung actually USED is
                        // subtracted), and 3 -> 4 walks straight into the fine
                        // entries.
                        ridx      <= ridx + 5'd1;
                        tbl_raddr <= addr_of(req_dir, ridx + 5'd1);
                        state     <= S_RD;
                    end
                end

                // ---- structural +/-1-VOBU fallback --------------------------
                S_VOBU: begin
                    if (off_acc != 24'd0) begin
                        state <= S_FIRE;                 // partial jump: keep it
                    end else if (req_dir) begin
                        // Forward off the last VOBU of a cell: next_vobu, else
                        // the first sector past this VOBU -- the head of the next
                        // cell in RBN order, which the reader's S_RBN_SCAN
                        // re-selects and S_NAV_SEEK snaps to a NAV pack.
                        off_acc <= nxv_ok ? sat_add(24'd0, dsi_next_vobu[29:0])
                                          : sat_add(24'd0, dsi_vobu_ea[29:0] + 30'd1);
                        state   <= S_FIRE;
                    end else if (pvv_ok) begin
                        off_acc <= sat_add(24'd0, dsi_prev_vobu[29:0]);
                        state   <= S_FIRE;
                    end else begin
                        // Backward from a cell's first VOBU is not expressible in
                        // these tables. A guessed offset is worse than nothing.
                        pend_fail <= 1'b1;
                        net10     <= 14'sd0;
                        state     <= S_IDLE;
                    end
                end

                // ---- hand off ------------------------------------------------
                S_FIRE: begin
                    if (off_acc != 24'd0) begin
                        jump_fire <= 1'b1;
                        jump_dir  <= req_dir;
                        jump_off  <= {8'd0, off_acc};
                    end else begin
                        pend_fail <= 1'b1;
                    end
                    net10 <= 14'sd0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
