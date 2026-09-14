// ===========================================================================
// hli_window_tb — a SEQUENCE of authored HLI time windows must arm on the
// display schedule, not a window late.
//
// THE DEFECT (Scooby-Doo 2 "Monsters Unleashed Challenge", the Old Tyme Mining
// Town whack-a-mole, VTS_02 PGCN 26 cells 14..17):
//   a monster appears, the player presses that direction, the core reports a
//   MISS, plays the "all the monsters mock you" clip and restarts the round.
//
// WHAT THE DISC AUTHORS (all of it read out of the fixture below, never
// restated here): each round cell is cut into consecutive HLI TIME WINDOWS.
// The window's own hli_ss=1 NAV pack arrives one VOBU (~66 ms) before it
// starts and every further VOBU re-sends the same HLI as hli_ss=2. Every
// window carries the same 5 buttons — 1 left / 2 top / 3 right / 4 bottom, all
// auto_action=1 (landing the highlight FIRES the command), 5 = a neutral
// centre with fosl=5. In a NOTHING window all four directions carry the same
// `LinkCN <miss cell>`; in a MONSTER window the monster's direction carries a
// different command (the hit). So THE SAME BUTTON IS A HIT OR A MISS DEPENDING
// ON WHICH WINDOW IS ARMED, which is what makes a stale window observable at
// all — and observable exactly the way the player observes it.
//
// WHAT THIS BENCH MEASURES: press a direction at display time T, and record
// WHICH COMMAND FIRED. That is the whole instrument. It never reads `armed`,
// `nxt_*`, `h_sptm` or any other signal the fix names, so it cannot become a
// golden model that agrees with its RTL by construction ([[bench-that-cannot-
// fail]]). The expected command comes from the fixture's own button records.
//
// THE TWO CLOCKS, which is the point of the whole exercise:
//   * the DISPLAY clock (`stc`) — 90 kHz, what the viewer sees;
//   * the PARSE front — the reader runs a VBUF depth AHEAD of it, so pack i is
//     delivered at display time (its vobu_s_ptm − LEAD). +lead_ms sweeps that.
//   * a round is entered by a LinkCN seek, so the scene starts with the clock
//     still on the OLD cell's timeline (+prev_stc) and re-anchors, exactly
//     once, when the new cell's first picture reaches the screen.
//
// Run:  iverilog -g2012 -o /tmp/hw dvd/nav_pci.sv bench/dvd/hli_window_tb.sv
//       vvp /tmp/hw +lead_ms=1000
// Gate: bench/dvd/run_hli_window.sh --red
// ===========================================================================
`timescale 1ns/1ps

module hli_window_tb;

    // ---- the display clock is COMPRESSED 300x -----------------------------
    // 27 MHz / 90 kHz = 300 clk per tick is unsimulable over a 6 s game round
    // (165 M edges). CLKP=1 keeps the ONE ratio that matters — the fallback
    // timer measured in DISPLAY time — by scaling PROMOTE_FALLBACK with it:
    // 90_000 ticks = 1 display second, exactly as the shipped 27_000_000 clk
    // at 300 clk/tick. Feeding a pack costs 979 clk = 10.9 ms of display time,
    // which is still nothing beside a 500 ms VOBU.
    localparam int CLKP = 1;
    localparam int FB   = 90_000;
    localparam int TPS  = 90_000;                 // ticks per display second
    localparam int TPMS = 90;                     // ticks per display ms

    localparam int NSEC = 14;                     // NAV sectors in the fixture
    localparam int PCI  = 'h2D;                   // PCI payload offset in a NAV pack
    localparam int BREC = 'h8E;                   // button record 1, PCI-relative
    localparam int MAXW = 8;

    logic clk = 0;
    always #5 clk = ~clk;

    logic        rst_n = 0;
    logic [7:0]  pci_byte = 0;
    logic        pci_valid = 0, pci_frame_start = 0;
    logic [32:0] stc = 0;
    logic        video_live = 0, menu_settled = 0;
    logic        stc_fresh = 1, stc_reanchor = 0;
    logic        nav_up = 0, nav_dn = 0, nav_lf = 0, nav_rt = 0, nav_act = 0;

    wire         hl_on, btns_armed;
    wire [9:0]   hl_x1, hl_x2, hl_y1, hl_y2;
    wire [31:0]  hl_coli;
    wire [63:0]  btn_cmd;
    wire         btn_cmd_valid;
    wire [5:0]   btn_sel, dbg_btn_ns;

    nav_pci #(.PROMOTE_FALLBACK(FB)) dut (
        .clk(clk), .rst_n(rst_n),
        .pci_byte(pci_byte), .pci_valid(pci_valid), .pci_frame_start(pci_frame_start),
        .stc(stc),
        .disp_wide(1'b1), .disp_mode(2'd0),
        .video_live(video_live),
        .menu_settled(menu_settled),
        .stc_fresh(stc_fresh),
        .stc_reanchor(stc_reanchor),
        .sel_force(1'b0), .sel_force_btn(6'd0),
        .hl_btnn(6'd0),
        .num_sel(1'b0), .num_btn(6'd0),
        .nav_up(nav_up), .nav_dn(nav_dn), .nav_lf(nav_lf), .nav_rt(nav_rt),
        .nav_act(nav_act),
        .hl_on(hl_on), .hl_x1(hl_x1), .hl_x2(hl_x2), .hl_y1(hl_y1), .hl_y2(hl_y2),
        .hl_coli(hl_coli),
        .btn_cmd(btn_cmd), .btn_cmd_valid(btn_cmd_valid),
        .btns_armed(btns_armed), .btn_sel(btn_sel), .dbg_btn_ns(dbg_btn_ns)
    );

    // =======================================================================
    // Fixture + the golden window table parsed OUT OF IT
    // =======================================================================
    logic [7:0] nav [0:NSEC*2048-1];

    int          pk_ss   [0:NSEC-1];      // hli_ss of each pack
    int          pk_sptm [0:NSEC-1];      // its HLI's s_ptm
    int          pk_vobu [0:NSEC-1];      // its VOBU's presentation start
    int          pk_t    [0:NSEC-1];      // scene time at which it is PARSED

    int          n_win;
    int          w_sptm  [0:MAXW-1];      // window start (display time)
    int          w_hit   [0:MAXW-1];      // hit button 1..4, or 0 = nothing window
    logic [63:0] w_cmd   [0:MAXW-1][0:5]; // per-button command
    int          w_pack  [0:MAXW-1];      // the pack index that opened it
    int          dir_of  [0:63];          // button -> direction from the centre
    int          btn_of  [0:3];           // direction -> button from the centre

    int i, j, k, b, w, base, rec, ctr;
    logic [63:0] c;

    task parse_fixture;
        int p, nb, cbtn, same;
        begin
            n_win = 0;
            for (i = 0; i < NSEC; i = i + 1) begin
                p          = i*2048 + PCI;
                pk_ss[i]   = {nav[p+'h60], nav[p+'h61]} & 16'd3;
                pk_vobu[i] = {nav[p+'h0C], nav[p+'h0D], nav[p+'h0E], nav[p+'h0F]};
                pk_sptm[i] = {nav[p+'h62], nav[p+'h63], nav[p+'h64], nav[p+'h65]};
                nb         = nav[p+'h71] & 8'h3F;
                if (pk_ss[i] == 1) begin
                    if (n_win == MAXW) $fatal(1, "fixture has more than %0d windows", MAXW);
                    w_sptm[n_win] = pk_sptm[i];
                    w_pack[n_win] = i;
                    for (b = 1; b <= nb && b <= 5; b = b + 1) begin
                        rec = p + BREC + (b-1)*18;
                        w_cmd[n_win][b] = {nav[rec+10], nav[rec+11], nav[rec+12], nav[rec+13],
                                           nav[rec+14], nav[rec+15], nav[rec+16], nav[rec+17]};
                    end
                    // HIT = the one direction whose command differs from the
                    // other three. All four equal => a NOTHING window.
                    cbtn = 0;
                    for (b = 1; b <= 4; b = b + 1) begin
                        same = 0;
                        for (j = 1; j <= 4; j = j + 1)
                            if (j != b && w_cmd[n_win][j] == w_cmd[n_win][b]) same = same + 1;
                        if (same == 0) cbtn = b;
                    end
                    w_hit[n_win] = cbtn;
                    n_win = n_win + 1;
                end
            end
            // The centre button's own link record says which D-pad direction
            // reaches each outer button -- derived, never assumed.
            rec = w_pack[0]*2048 + PCI + BREC + 4*18;      // button 5
            btn_of[0] = nav[rec+6] & 8'h3F;    // up
            btn_of[1] = nav[rec+7] & 8'h3F;    // down
            btn_of[2] = nav[rec+8] & 8'h3F;    // left
            btn_of[3] = nav[rec+9] & 8'h3F;    // right
            for (b = 0; b < 64; b = b + 1) dir_of[b] = -1;
            for (j = 0; j < 4; j = j + 1) dir_of[btn_of[j]] = j;
        end
    endtask

    // =======================================================================
    // Scene clock: `t` = scene time in 90 kHz ticks, from the moment the
    // reader starts delivering this cell. The DISPLAY starts LEAD ticks later
    // (that is what a VBUF lead IS), so:
    //     t  < lead : stc is still the PREVIOUS cell's clock, free-running
    //     t == lead : the first picture of this cell reaches the screen; the
    //                 clock re-anchors onto the new timeline (one pulse)
    //     t  > lead : stc = w_sptm[0] + (t - lead)
    // and pack i, whose VOBU displays at vobu_s_ptm, is PARSED at
    //     t = vobu_s_ptm - w_sptm[0].
    // =======================================================================
    int  t, ckdiv, lead, prev_stc;
    bit  running, reanch_done;

    always @(posedge clk) begin
        if (!running) begin
            ckdiv <= 0;
            t     <= 0;              // ⚠ ONE driver for `t`: see run_scene
        end else if (ckdiv == CLKP-1) begin
            ckdiv <= 0;
            t     <= t + 1;
        end else begin
            ckdiv <= ckdiv + 1;
        end
    end

    always @(*) stc = running ? ((t < lead) ? (prev_stc + t)
                                            : (w_sptm[0] + (t - lead))) : 33'd0;

    always @(posedge clk) begin
        stc_reanchor <= 1'b0;
        if (running && !reanch_done && t >= lead) begin
            stc_reanchor <= 1'b1;
            reanch_done  <= 1'b1;
            video_live   <= 1'b1;
        end
    end

    // ---- what actually fired ---------------------------------------------
    logic [63:0] last_cmd;
    int          cmd_cnt;
    always @(posedge clk) if (btn_cmd_valid) begin
        last_cmd <= btn_cmd;
        cmd_cnt  <= cmd_cnt + 1;
    end

    task feed_pci(input int sec);
        int p, n;
        begin
            p = sec*2048 + PCI;
            for (n = 0; n < 979; n = n + 1) begin
                pci_byte        <= nav[p + n];
                pci_valid       <= 1;
                pci_frame_start <= (n == 0);
                @(posedge clk);
            end
            pci_valid       <= 0;
            pci_frame_start <= 0;
        end
    endtask

    task press(input int dir);        // 0=up 1=dn 2=lf 3=rt
        begin
            case (dir)
            0: nav_up <= 1;
            1: nav_dn <= 1;
            2: nav_lf <= 1;
            default: nav_rt <= 1;
            endcase
            @(posedge clk);
            nav_up <= 0; nav_dn <= 0; nav_lf <= 0; nav_rt <= 0;
        end
    endtask

    task wait_t(input int target);
        begin
            while (t < target) @(posedge clk);
        end
    endtask

    // =======================================================================
    // One scene: replay the round with a given VBUF lead, pressing once per
    // window at `off` ticks relative to that window's authored start.
    //   mode 0 = press the HIT direction (a nothing window has none: press the
    //            direction of button 1, which is a miss there by construction)
    //   mode 1 = press a direction that is NOT the hit
    // `first_pack` starts the delivery part-way through (a seek landing
    // mid-window, where only continuations are left to arm from).
    // `only_win` >= 0 presses in that ONE window and nowhere else -- without it
    // an earlier window's press leaves its command in the monitor, and a later
    // window that fires NOTHING then reads as if it had fired that one.
    // Results land in res_cmd[]/res_seen[], indexed by window.
    // =======================================================================
    localparam logic [63:0] NOFIRE = 64'hDEADDEADDEADDEAD;
    logic [63:0] res_cmd  [0:MAXW-1];
    bit          res_seen [0:MAXW-1];
    int          res_dir  [0:MAXW-1];

    task run_scene(input int lead_ms, input int off_ticks, input int mode,
                   input int first_pack, input int prev_stc_ticks,
                   input int only_win, input int skip_pack);
        int ip, iw, tp, tw, pre, dirw, hb;
        bit done;
        int pr_t [0:MAXW-1];
        begin
            // --- reset ---
            running = 0; rst_n = 0; video_live = 0; menu_settled = 0;
            pci_valid = 0; pci_frame_start = 0;
            nav_up = 0; nav_dn = 0; nav_lf = 0; nav_rt = 0;
            cmd_cnt = 0; last_cmd = 64'd0;
            // ⚠ do NOT zero `t`/`ckdiv` from here: the tick process above drives
            // them, and a blocking assignment from a task racing a nonblocking
            // one is a bench that silently measures the wrong moment. Holding
            // running=0 for a few edges is what resets the scene clock.
            reanch_done = 0;
            lead     = lead_ms * TPMS;
            prev_stc = prev_stc_ticks;
            repeat (4) @(posedge clk);       // running=0 here zeroes the scene clock
            rst_n = 1;
            @(posedge clk);
            if (t != 0) $fatal(1, "scene clock did not reset (t=%0d)", t);

            for (iw = 0; iw < n_win; iw = iw + 1) begin
                res_seen[iw] = 0;
                res_cmd[iw]  = NOFIRE;
                hb   = w_hit[iw];
                dirw = (mode == 0) ? ((hb != 0) ? dir_of[hb] : dir_of[1])
                                   : ((hb != 1) ? dir_of[1]  : dir_of[2]);
                res_dir[iw] = dirw;
                pr_t[iw]    = w_sptm[iw] + off_ticks - w_sptm[0] + lead;
            end

            running = 1;
            ip = first_pack; iw = 0; done = 0;
            // Once the window under test has answered there is nothing left to
            // measure, so stop: that is what keeps a per-window scene costing
            // one window rather than a whole round.
            while ((ip < NSEC || iw < n_win) && !done) begin
                tp = (ip < NSEC)   ? pk_t[ip] : 32'h3FFFFFFF;
                tw = (iw < n_win)  ? pr_t[iw] : 32'h3FFFFFFF;
                if (iw < n_win && only_win >= 0 && iw != only_win) begin
                    iw = iw + 1;                      // this window takes no press
                    continue;
                end
                if (tp <= tw) begin
                    wait_t(tp);
                    if (ip != skip_pack) feed_pci(ip);   // skip = this pack was lost
                    ip = ip + 1;
                end else begin
                    wait_t(tw);
                    pre = cmd_cnt;
                    // +dbg prints the DUT state at each press. Kept because it
                    // is what found the scene-clock race above: a press that
                    // reports the wrong `t` is a bench bug, not a fix bug.
                    if ($test$plusargs("dbg"))
                        $display("    [dbg] t=%0d stc=%0d press dir %0d: armed=%b sel=%0d btn_ns=%0d hl_on=%b",
                                 t, stc, res_dir[iw], btns_armed, btn_sel, dbg_btn_ns, hl_on);
                    press(res_dir[iw]);
                    wait_t(tw + 300);                 // ~3 ms: the fetch is ~10 ticks
                    res_seen[iw] = (cmd_cnt != pre);
                    res_cmd[iw]  = (cmd_cnt != pre) ? last_cmd : NOFIRE;
                    if (only_win >= 0 && iw == only_win) done = 1;
                    iw = iw + 1;
                end
            end
            running = 0;
        end
    endtask

    // =======================================================================
    // Checks
    // =======================================================================
    int errors = 0;
    task chk(input bit ok, input string m);
        begin
            if (!ok) begin
                $display("  ERR %s", m);
                errors = errors + 1;
            end
        end
    endtask

    function string cmdname(input int win, input logic [63:0] v);
        int bb;
        begin
            cmdname = "?";
            for (bb = 1; bb <= 5; bb = bb + 1)
                if (w_cmd[win][bb] == v)
                    cmdname = (bb == w_hit[win]) ? "HIT" : "miss";
        end
    endfunction

    // which window does a fired command belong to? (the miss command is shared
    // by every window here, so only a HIT identifies one -- that is what makes
    // the hit arms the load-bearing ones)
    int  lead_ms_arg, sweep, hits, earliest [0:MAXW-1];
    logic [63:0] exp;
    bit  patched;

    initial begin
        for (i = 0; i < NSEC*2048; i = i + 1) nav[i] = 8'h00;
        $readmemh("bench/dvd/test_vobs/scooby_mole_pci.hex", nav, 0, NSEC*2048-1);

        if (nav[0] !== 8'h00 || nav[3] !== 8'hBA) begin
            $display("HLI_WINDOW_TB: fixture absent -> SKIPPED (regen with tools/nav_extract.py --vts 2 --title-vob 1 --sector 141675 --count 2500 --hex bench/dvd/test_vobs/scooby_mole_pci.hex --hex-count 14)");
            $display("HLI_WINDOW_TB: ALL TESTS PASSED (skipped)");
            $finish;
        end

        parse_fixture;
        for (i = 0; i < NSEC; i = i + 1) pk_t[i] = pk_vobu[i] - w_sptm[0];

        $display("HLI_WINDOW_TB: %0d packs, %0d windows; centre links u/d/l/r = %0d/%0d/%0d/%0d",
                 NSEC, n_win, btn_of[0], btn_of[1], btn_of[2], btn_of[3]);
        for (w = 0; w < n_win; w = w + 1) begin
            if (w_hit[w] != 0)
                $display("  window %0d: s_ptm=%0d  MONSTER btn %0d (dir %0d) cmd %016x",
                         w, w_sptm[w], w_hit[w], dir_of[w_hit[w]], w_cmd[w][w_hit[w]]);
            else
                $display("  window %0d: s_ptm=%0d  nothing", w, w_sptm[w]);
        end
        if (n_win < 3) $fatal(1, "fixture must carry at least 3 windows");

        // ===============================================================
        // THE CONTRACT, and every arm below is one instance of it:
        //
        //     a press of direction d while window w is ON SCREEN must fire
        //     exactly the command w authored for d.
        //
        // That single statement covers a hit, a miss and an early press with
        // no special cases, and it is stated in terms of what the player does
        // and what the disc says -- never a signal the fix names.
        // ⚠ Both monster windows here author the SAME hit command (g[12]=0),
        // so "a hit fired" does not identify WHICH window fired it; comparing
        // against the pressed direction's own command in the expected window
        // is what keeps the arms unambiguous.
        // ===============================================================

        // ---------------------------------------------------------------
        // [A] THE REPORTED CASE. Press the monster's own direction 300 ms
        //     after it appears -- the reaction a player actually has -- at
        //     three VBUF leads. Every monster window must fire its HIT.
        //     RED: the armed set trails the picture by a window, so the press
        //     lands on the previous window's buttons and fires its miss.
        // ---------------------------------------------------------------
        for (sweep = 0; sweep < 3; sweep = sweep + 1) begin
            lead_ms_arg = (sweep == 0) ? 300 : (sweep == 1) ? 1000 : 1500;
            for (w = 0; w < n_win; w = w + 1) begin
                if (w_hit[w] == 0) continue;
                run_scene(lead_ms_arg, 300*TPMS, 0, 0, 300000, w, -1);
                exp = w_cmd[w][w_hit[w]];
                $display("[A lead=%0dms] window %0d, press its own direction +300ms -> %016x (%s)",
                         lead_ms_arg, w, res_cmd[w], cmdname(w, res_cmd[w]));
                chk(res_seen[w] && res_cmd[w] === exp,
                    $sformatf("[A lead=%0dms] window %0d: the monster's own direction must HIT",
                              lead_ms_arg, w));
            end
        end

        // ---------------------------------------------------------------
        // [B] LATENCY, in the only unit that matters: how long after a
        //     monster is drawn must a player wait before the core agrees it
        //     is there. A player cannot press before the monster appears, so
        //     anything past ~100 ms is the defect showing through.
        // ---------------------------------------------------------------
        for (w = 0; w < MAXW; w = w + 1) earliest[w] = -1;
        for (w = 0; w < n_win; w = w + 1) begin
            if (w_hit[w] == 0) continue;
            for (sweep = 0; sweep < 5; sweep = sweep + 1) begin
                k = (sweep == 0) ? 0 : (sweep == 1) ? 50 : (sweep == 2) ? 100 :
                    (sweep == 3) ? 300 : 1000;                   // ms into the window
                if (earliest[w] >= 0) continue;
                run_scene(1000, k*TPMS, 0, 0, 300000, w, -1);
                if (res_seen[w] && res_cmd[w] === w_cmd[w][w_hit[w]]) earliest[w] = k;
            end
            if (earliest[w] < 0)
                $display("[B] window %0d: earliest hitting press = NEVER", w);
            else
                $display("[B] window %0d: earliest hitting press = +%0dms", w, earliest[w]);
            chk(earliest[w] >= 0 && earliest[w] <= 100,
                $sformatf("[B] window %0d: the armed set must serve it within 100 ms of its start", w));
        end

        // ---------------------------------------------------------------
        // [C] CONTROL -- a direction that is NOT the monster's must fire that
        //     direction's own (miss) command. Without this arm, "arm
        //     everything, early and often" would pass [A].
        // ---------------------------------------------------------------
        for (w = 0; w < n_win; w = w + 1) begin
            if (w_hit[w] == 0) continue;
            run_scene(1000, 300*TPMS, 1, 0, 300000, w, -1);
            exp = w_cmd[w][btn_of[res_dir[w]]];
            $display("[C] window %0d, a WRONG direction +300ms -> %016x (%s)",
                     w, res_cmd[w], cmdname(w, res_cmd[w]));
            chk(res_seen[w] && res_cmd[w] === exp,
                $sformatf("[C] window %0d: a wrong direction must fire ITS OWN command", w));
        end

        // ---------------------------------------------------------------
        // [D] CONTROL -- 300 ms BEFORE a window starts, the PREVIOUS window is
        //     still on screen, so the press must fire what the PREVIOUS window
        //     authored for that direction. This is the arm that stops the fix
        //     from becoming "promote as soon as it is parsed", which would
        //     break the game the other way (hitting a monster not yet drawn).
        // ---------------------------------------------------------------
        for (w = 1; w < n_win; w = w + 1) begin
            if (w_hit[w] == 0) continue;
            // ⚠ skip a window whose predecessor is the CELL'S FIRST: that one is
            // committed while the clock is still on the previous cell's timeline
            // (the round is entered by a LinkCN seek), so it arms on the fallback
            // timer and there is legitimately nothing on screen to serve the
            // press. That residual is MEASURED by [G] rather than hidden here.
            if (w == 1) continue;
            run_scene(1000, -300*TPMS, 0, 0, 300000, w, -1);
            exp = w_cmd[w-1][w_hit[w]];               // same button, PREVIOUS window
            $display("[D] window %0d, its direction pressed -300ms -> %016x (expect the window before it: %016x)",
                     w, res_cmd[w], exp);
            chk(res_seen[w] && res_cmd[w] === exp,
                $sformatf("[D] window %0d: a press before it must serve the window still on screen", w));
        end

        // ---------------------------------------------------------------
        // [E] A SEEK LANDING MID-WINDOW has only CONTINUATIONS to arm from --
        //     the window's own hli_ss=1 pack is behind the playhead already.
        //     Deliver from its first continuation onward and require the
        //     highlight to arm and serve that window anyway. This is the arm
        //     that stops the fix from becoming "ignore every continuation".
        // ---------------------------------------------------------------
        w = 1;
        while (w < n_win && w_hit[w] == 0) w = w + 1;
        k = w_pack[w] + 1;                            // its first continuation
        run_scene(1000, 300*TPMS, 0, k, 300000, w, -1);
        $display("[E] landing mid-window (delivery starts at pack %0d): window %0d -> %016x (%s)",
                 k, w, res_cmd[w], cmdname(w, res_cmd[w]));
        chk(res_seen[w] && res_cmd[w] === w_cmd[w][w_hit[w]],
            "[E] a continuation must still arm when its own ss=1 pack was never delivered");

        // ---------------------------------------------------------------
        // [E2] A LOST ss=1 WHILE ANOTHER WINDOW IS ARMED. Same shape as [E],
        //     but the previous window really is on screen when the orphaned
        //     continuations arrive -- so suppressing a continuation must test
        //     WHICH window it continues, not merely that something is armed.
        //     prev_stc is below the cell's first s_ptm here (a round entered
        //     from a short clip), which is what lets window 0 arm on schedule
        //     and makes "another window is armed" true at the right moment.
        // ---------------------------------------------------------------
        run_scene(1000, 300*TPMS, 0, 0, 1000, w, w_pack[w]);
        $display("[E2] window %0d ss=1 pack %0d LOST, window %0d armed -> %016x (%s)",
                 w, w_pack[w], w-1, res_cmd[w], cmdname(w, res_cmd[w]));
        chk(res_seen[w] && res_cmd[w] === w_cmd[w][w_hit[w]],
            "[E2] a continuation of a DIFFERENT window must arm while one is armed");

        // ---------------------------------------------------------------
        // [F] hli_ss=3 is "same buttons, CHANGED COMMANDS" -- it must take
        //     effect, so it can never be suppressed the way a plain
        //     continuation is. Patch the LAST continuation of that window to
        //     ss=3 with a distinctive command on the monster's button, and
        //     press after it has had time to reach the display.
        // ---------------------------------------------------------------
        // Pick the first continuation of this window that is PARSED after the
        // window is already on screen (pack VOBU minus the 1000 ms lead past
        // w's start). An earlier one would still be pending when it commits,
        // where a same-s_ptm re-commit is discarded by the earliest-wins rule
        // -- a real limitation, but a different one, and pinning it here would
        // make this arm fail for a reason it is not about.
        k = w_pack[w] + 1;
        while (k + 1 < NSEC && pk_ss[k] == 2 &&
               (pk_vobu[k] - 1000*TPMS) <= w_sptm[w]) k = k + 1;
        base = k*2048 + PCI;
        nav[base + 'h61] = 8'h03;                     // hli_ss = 3
        rec = base + BREC + (w_hit[w]-1)*18;
        for (j = 0; j < 8; j = j + 1) nav[rec + 10 + j] = 8'hA5;
        // Press 1.5 s after that pack's own VOBU is on screen: its s_ptm is
        // long past by then, so it can only have reached the display through
        // the fallback timer -- which is the path a late re-commit must use.
        ctr = (pk_vobu[k] - w_sptm[w]) + 1200*TPMS;
        // the arm is only meaningful while that window is still the one on
        // screen -- fail loudly rather than drift into the next one
        if (w + 1 < n_win && (w_sptm[w] + ctr) >= w_sptm[w+1])
            $fatal(1, "[F] press at +%0d ticks falls outside window %0d", ctr, w);
        run_scene(1000, ctr, 0, 0, 300000, w, -1);
        $display("[F] ss=3 re-commit of window %0d -> %016x (expect a5a5a5a5a5a5a5a5)",
                 w, res_cmd[w]);
        chk(res_seen[w] && res_cmd[w] === 64'hA5A5A5A5A5A5A5A5,
            "[F] an hli_ss=3 re-commit must replace the armed commands");
        nav[base + 'h61] = 8'h02;                     // restore the fixture
        for (j = 0; j < 8; j = j + 1)
            nav[rec + 10 + j] = (w_cmd[w][w_hit[w]] >> (8*(7-j))) & 8'hFF;

        // ---------------------------------------------------------------
        // [J] A PENDING WINDOW MUST NOT BE DISPLACED BY A LATER ONE THAT IS
        //     ALSO SCHEDULABLE -- the 2026-08-05 Matrix rule ("newest wins let
        //     every VOBU overwrite the pending with a later start before it
        //     came due; the highlight never showed"). It is what stops
        //     `sched_outranks` degenerating into newest-schedulable-wins.
        //     ⚠ SYNTHESISED, because this fixture cannot produce it: its ss=1
        //     packs arrive ~66 ms before their own window, so two are never
        //     pending together. Patch a continuation into an ss=1 for a window
        //     FURTHER in the future, delivered while window w is still pending,
        //     and stamp its commands so that arming it instead would show.
        // ---------------------------------------------------------------
        k = w_pack[w] + 2;                            // pending, before w promotes
        base = k*2048 + PCI;
        nav[base + 'h61] = 8'h01;                                     // ss = 1
        nav[base + 'h62] = 8'h00; nav[base + 'h63] = 8'h04;
        nav[base + 'h64] = 8'h93; nav[base + 'h65] = 8'hE0;           // s_ptm = 300000
        for (b = 1; b <= 5; b = b + 1) begin
            rec = base + BREC + (b-1)*18;
            for (j = 0; j < 8; j = j + 1) nav[rec + 10 + j] = 8'h5A;
        end
        run_scene(1000, 300*TPMS, 0, 0, 1000, w, -1);
        $display("[J] a later schedulable window commits while window %0d is pending -> %016x (%s)",
                 w, res_cmd[w], cmdname(w, res_cmd[w]));
        chk(res_seen[w] && res_cmd[w] === w_cmd[w][w_hit[w]],
            "[J] a pending window must not be displaced by a later schedulable one");
        nav[base + 'h61] = 8'h02;                     // restore the fixture
        nav[base + 'h62] = (w_sptm[w] >> 24) & 8'hFF; nav[base + 'h63] = (w_sptm[w] >> 16) & 8'hFF;
        nav[base + 'h64] = (w_sptm[w] >>  8) & 8'hFF; nav[base + 'h65] =  w_sptm[w]        & 8'hFF;
        for (b = 1; b <= 5; b = b + 1) begin
            rec = base + BREC + (b-1)*18;
            for (j = 0; j < 8; j = j + 1)
                nav[rec + 10 + j] = (w_cmd[w][b] >> (8*(7-j))) & 8'hFF;
        end

        // ---------------------------------------------------------------
        // [I] TWO WINDOWS PENDING AT ONCE -- the EARLIER one must still arm on
        //     time. This is the rule the 2026-08-05 Matrix fix installed
        //     (newest-wins let every VOBU overwrite the pending with a later
        //     start before it came due, and the highlight never showed), and it
        //     is what keeps `sched_outranks` from degenerating into
        //     newest-schedulable-wins.
        //     Reached by entering the round from a SHORT clip (prev_stc below
        //     the cell's first s_ptm): the first window then schedules properly
        //     and is still pending when the NEXT window's ss=1 is parsed.
        //     ⚠ It doubles as the control for [G]: the same round entered with
        //     a low entry clock answers a press from the very start, which is
        //     what shows [G]'s delay is the entry clock and not the design.
        // ---------------------------------------------------------------
        run_scene(1000, 300*TPMS, 0, 0, 1000, 0, -1);
        $display("[I] first window with two pending at once -> %016x (%s)",
                 res_cmd[0], cmdname(0, res_cmd[0]));
        chk(res_seen[0] && res_cmd[0] === w_cmd[0][btn_of[res_dir[0]]],
            "[I] a pending window must not be displaced by a later one that is also schedulable");

        // ---------------------------------------------------------------
        // [G] THE KNOWN RESIDUAL, measured rather than asserted away. A round
        //     is entered by a LinkCN seek, so the cell's FIRST window is
        //     committed while the clock still measures the PREVIOUS cell --
        //     stc is past its s_ptm before it ever arrives, nothing about the
        //     compare is informative, and it reaches the screen on the ~1 s
        //     fallback timer instead. Every LATER window in the cell is
        //     display-scheduled ([B] = +0 ms), so this costs the opening
        //     moment of a round and nothing else; on this disc that opening
        //     window is a NOTHING window, so no input is lost.
        //     Tightening it means touching hli_coherent, which is what cost
        //     Harry Potter and Scene It their highlights -- docs/stc_freerun.md
        //     §11, nav_pci_tb T18/T18b. Bounded here so a regression that made
        //     it materially worse still fails.
        // ---------------------------------------------------------------
        earliest[0] = -1;
        for (sweep = 0; sweep < 6; sweep = sweep + 1) begin
            k = (sweep == 0) ? 0 : (sweep == 1) ? 100 : (sweep == 2) ? 300 :
                (sweep == 3) ? 600 : (sweep == 4) ? 1000 : 1400;
            if (earliest[0] >= 0) continue;
            run_scene(1000, k*TPMS, 0, 0, 300000, 0, -1);
            if (res_seen[0]) earliest[0] = k;
        end
        if (earliest[0] < 0)
            $display("[G] the round's FIRST window never arms within 1.4 s");
        else
            $display("[G] the round's first window serves a press from +%0dms (fallback-timed by design)",
                     earliest[0]);
        chk(earliest[0] >= 0 && earliest[0] <= 1400,
            "[G] the round's first window must arm within the fallback timer");

        if (errors == 0) $display("HLI_WINDOW_TB: ALL TESTS PASSED");
        else begin
            $display("HLI_WINDOW_TB: FAILED with %0d errors", errors);
            $fatal(1, "hli_window_tb failed");
        end
        $finish;
    end

endmodule
