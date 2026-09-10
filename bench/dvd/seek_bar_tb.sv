// seek_bar_tb.sv -- Phase 11 seek-bar test (divider math + pixel render +
// stretch chapter ticks / progress popup).
//
//   T1: divider vs reference px = (v-first)*512/span (mid-span fill + cursor)
//   T2: clamps (target below first -> 0, above last -> 512)
//   T3: degenerate spans (first==last, span==1)
//   T4: scrub render -- border/fill/cursor/backing land where expected
//   T5: invisible when nothing arms it
//   T6: tick conversion -- pmap/cellf streams + pgc_loaded rise -> tick_col[]
//   T7: progress popup -- show_evt arms, fill = LIVE cur_rbn, no cursor, expiry
//   T8: notch render in the lower half at converted columns
//   T9: chapter-skip preview -- cursor parks on the projected chapter's start
//       column, tracks a multi-press burst, clears when the skip settles, and
//       yields to the scrub cursor when both are up
//  T11: an unsorted tick list still draws every notch
//  T12: NARROW WINDOW (2026-09-14) -- the box re-centres and halves, and the bar's
//       0..511 column space is sampled two columns per drawn pixel, so the fill edge,
//       the cursor and a notch all land at half the column they do at full width.
//       Runs on every invocation (it drives act_w_i itself), so the 720 arms above and
//       this one are one run.
//
// Run: iverilog -g2012 -o /tmp/bar_sim dvd/seek_bar.sv bench/dvd/seek_bar_tb.sv
`timescale 1ns/1ps

module seek_bar_tb;

    reg clk = 0, rst_n = 0;
    always #18.5 clk = ~clk;

    reg  [11:0] h_pos = 0, v_pos = 0;
    reg         bar_active = 0;
    reg  [31:0] base_rbn = 0, tgt_rbn = 0, first_rbn = 0, last_rbn = 0;
    reg         pause_q = 0, show_evt = 0, menu_active = 0;
    reg  [31:0] cur_rbn = 0;
    reg         pgc_loaded = 0;
    reg  [7:0]  nr_pgm = 0;
    reg         chap_prev = 0;
    reg  [7:0]  chap_pgm = 0;
    reg         pm_we = 0, cellf_we = 0;
    reg  [6:0]  pm_waddr = 0;
    // 8 bits since 2026-09-17: a PGC may carry up to 255 cells and the port
    // widened with it. A 7-bit driver into the 8-bit port does NOT simply
    // zero-extend here -- it shifted every notch column by one slot and read
    // as a seek_bar regression (T6/T9a/T11/T12f) when the only stale thing was
    // this declaration.
    reg  [7:0]  cellf_idx = 0;
    reg  [7:0]  pm_wdata = 0;
    reg  [31:0] cellf_rbn = 0;
    wire        bar_on;
    wire [7:0]  bar_r, bar_g, bar_b;
    wire [3:0]  bar_alpha;


    // DVD-FORK (native 240p, 2026-09-14): the raster's active height is now an INPUT.
    // Defaults to the standard so every pre-existing arm is bit-identical; +act_h=N
    // drives the 240p/288p arm, where the module must bottom-anchor to 240/288 instead.
    integer     act_h_arg = 0;
    initial     void'($value$plusargs("act_h=%d", act_h_arg));
    wire [11:0] act_h_tb = (act_h_arg != 0) ? act_h_arg[11:0]
                                            : (1'b0 ? 12'd576 : 12'd480);
    // DVD-FORK (narrow DE window, 2026-09-14): the raster's ACTIVE WIDTH is now an INPUT
    // too. Defaults to 720 so every pre-existing arm is bit-identical; +act_w=N drives the
    // narrow-window arms (VCD 352, SVCD 480), where the box must shrink and re-centre.
    // ⚠ DRIVEN by the bench, and deliberately NOT a plusarg: T1..T11 are written against
    // the full-width box (columns 0..511 of a 512 px bar), so starting the whole run
    // narrow would fail them against correct RTL. T12 sets the narrow widths itself and
    // sweeps BOTH of the real ones (a VCD's 352 and an SVCD's 480), which is the only
    // thing that differs between them -- the drawn coordinates are identical.
    reg  [11:0] act_w_tb;
    initial      act_w_tb = 12'd720;
    reg force_show = 1'b0;   // WAV/CD-DA: hold the bar up
    seek_bar #(.POP_TICKS(27'd2000)) dut (
        .clk(clk), .rst_n(rst_n),
        .h_pos(h_pos), .v_pos(v_pos), .pal_mode(1'b0), .act_h_i(act_h_tb), .act_w_i(act_w_tb),
        .bar_active(bar_active),
        .base_rbn(base_rbn), .tgt_rbn(tgt_rbn),
        .first_rbn(first_rbn), .last_rbn(last_rbn),
        .pause_vis(pause_q), .show_evt(show_evt), .menu_active(menu_active),
        .force_show(force_show),
        .cur_rbn(cur_rbn),
        .pgc_loaded(pgc_loaded), .nr_pgm(nr_pgm),
        .pm_we(pm_we), .pm_waddr(pm_waddr), .pm_wdata(pm_wdata),
        .cellf_we(cellf_we), .cellf_idx(cellf_idx), .cellf_rbn(cellf_rbn),
        .chap_prev(chap_prev), .chap_pgm(chap_pgm),
        .bar_on(bar_on), .bar_r(bar_r), .bar_g(bar_g), .bar_b(bar_b),
        .bar_alpha(bar_alpha)
    );

    integer errors = 0;

    task settle;                      // > two divider rounds incl. scheduling
        begin repeat (250) @(posedge clk); end
    endtask

    task check_px(input [127:0] label, input [9:0] wf, input [9:0] wc);
        begin
            settle;
            if (dut.fill_px !== wf || dut.cur_px !== wc) begin
                errors = errors + 1;
                $display("  FAIL %0s: fill=%0d cur=%0d want %0d/%0d",
                         label, dut.fill_px, dut.cur_px, wf, wc);
            end else
                $display("  ok  %0s: fill=%0d cur=%0d", label, dut.fill_px, dut.cur_px);
        end
    endtask

    // render one line: capture settled output per input h (2-stage pipe), indexed by the
    // DRAWN pixel hx = h + 4 - x0. The box comes from the bench's own statement of the
    // layout rule (centred; 512 px above the 544 knee, 256 below), never read out of the
    // DUT -- at 720 that is the historical 104/512 and every arm below is unchanged.
    function [11:0] box_w(input [11:0] aw); box_w = (aw >= 12'd544) ? 12'd512 : 12'd256; endfunction
    function [11:0] box_x0(input [11:0] aw); box_x0 = (aw - box_w(aw)) >> 1; endfunction
    reg       on_l   [0:511];
    reg [3:0] a_l    [0:511];
    reg [7:0] r_l    [0:511];
    integer x, hx, wsel;
    // ⚠ ROW COORDINATES FOLLOW act_h_i. They used to be literals (402/405/408) written for
    // a 480-line raster, so under +act_h=240 every render_line landed on a blank line and
    // the positive arms below asserted against nothing. run_p240.sh's "seek_bar_tb (240)"
    // arm reported ok on a bench reporting 13 errors for exactly that reason -- the bench
    // exited 0 on failure, which is why the $fatal at the bottom of this file matters.
    wire [11:0] bar_y0 = act_h_tb - 12'd78;      // = the DUT's y0, from the same rule
    task render_line(input [11:0] vv);
        integer x0, bw;
        begin
            v_pos = vv;
            x0 = box_x0(act_w_tb); bw = box_w(act_w_tb);
            for (x = 0; x < 512; x = x + 1) begin
                on_l[x] = 1'b0; a_l[x] = 4'd0; r_l[x] = 8'd0;
            end
            for (x = x0 - 14; x < x0 + bw + 14; x = x + 1) begin
                h_pos = x[11:0];
                @(posedge clk); @(posedge clk);   // fill the 2-stage pipe
                #1;
                hx = x + 4 - x0;
                if (hx >= 0 && hx < bw) begin
                    on_l[hx] = bar_on; a_l[hx] = bar_alpha; r_l[hx] = bar_r;
                end
            end
        end
    endtask

    // stream one pmap entry / one cellf entry
    task put_pm(input [6:0] p, input [7:0] cell1);
        begin @(posedge clk); pm_we=1; pm_waddr=p; pm_wdata=cell1;
              @(posedge clk); pm_we=0; end
    endtask
    task put_cf(input [6:0] c, input [31:0] rbn);
        begin @(posedge clk); cellf_we=1; cellf_idx=c; cellf_rbn=rbn;
              @(posedge clk); cellf_we=0; end
    endtask

    initial begin
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);

        // T1: mid-span (scrub mode: fill = base_rbn)
        bar_active = 1;
        first_rbn = 32'd1000; last_rbn = 32'd101000;      // span = 100000
        base_rbn  = 32'd51000;                            // 50% -> 256
        tgt_rbn   = 32'd76000;                            // 75% -> 384
        check_px("T1 mid-span", 10'd256, 10'd384);

        // T2: clamps
        tgt_rbn  = 32'd500;   check_px("T2a clamp low",  10'd256, 10'd0);
        tgt_rbn  = 32'd200000; check_px("T2b clamp high", 10'd256, 10'd512);

        // T3: degenerate spans
        first_rbn = 32'd5000; last_rbn = 32'd5000;        // span -> 1
        base_rbn = 32'd4000; tgt_rbn = 32'd6000;
        check_px("T3a first==last", 10'd0, 10'd512);
        last_rbn = 32'd5001;                              // span = 1
        base_rbn = 32'd5000; tgt_rbn = 32'd5001;
        check_px("T3b span=1", 10'd0, 10'd512);

        // T4: render a mid-bar line (y0 = activeH-78; upper half = y0+3)
        first_rbn = 32'd1000; last_rbn = 32'd101000;
        base_rbn = 32'd51000; tgt_rbn = 32'd76000;        // fill 256, cursor 384
        settle;
        render_line(bar_y0 + 12'd3);
        if (!(on_l[384] && a_l[384] == 4'd15 && r_l[384] == 8'hFF &&
              on_l[382] && on_l[386] && a_l[382] == 4'd15))
        begin errors = errors + 1; $display("  FAIL T4a cursor not at 384"); end
        else $display("  ok  T4a cursor at 384 (5 px, opaque)");
        if (!(on_l[100] && a_l[100] == 4'd10))
        begin errors = errors + 1; $display("  FAIL T4b fill alpha at 100 (a=%0d)", a_l[100]); end
        else $display("  ok  T4b fill region");
        if (!(on_l[300] && a_l[300] == 4'd7))
        begin errors = errors + 1; $display("  FAIL T4c backing at 300 (a=%0d)", a_l[300]); end
        else $display("  ok  T4c backing region");
        if (!(on_l[0] && a_l[0] == 4'd12 && on_l[511] && a_l[511] == 4'd12))
        begin errors = errors + 1; $display("  FAIL T4d side borders"); end
        else $display("  ok  T4d side borders");
        render_line(bar_y0);
        if (!(on_l[300] && a_l[300] == 4'd12))
        begin errors = errors + 1; $display("  FAIL T4e top border row (a=%0d)", a_l[300]); end
        else $display("  ok  T4e top border row");
        render_line(bar_y0 - 12'd2);
        if (on_l[300] !== 1'b0)
        begin errors = errors + 1; $display("  FAIL T4f renders above the bar"); end
        else $display("  ok  T4f nothing above the bar");

        // T5: inactive
        bar_active = 0;
        render_line(bar_y0 + 12'd3);
        if (on_l[300] !== 1'b0 || on_l[384] !== 1'b0)
        begin errors = errors + 1; $display("  FAIL T5 renders while inactive"); end
        else $display("  ok  T5 inactive = invisible");

        // T6: tick conversion (chapters at cells 1,2,4 -> RBNs 1000/26000/76000)
        put_pm(0, 8'd1); put_pm(1, 8'd2); put_pm(2, 8'd4);
        put_cf(0, 32'd1000);  put_cf(1, 32'd26000);
        put_cf(2, 32'd51000); put_cf(3, 32'd76000);
        nr_pgm = 8'd3;
        @(posedge clk); pgc_loaded = 1;
        settle;
        if (dut.tick_ok !== 1'b1 ||
            dut.tick_col[0] !== 10'd0 || dut.tick_col[1] !== 10'd128 ||
            dut.tick_col[2] !== 10'd384) begin
            errors = errors + 1;
            $display("  FAIL T6 ticks = %0d %0d %0d (ok=%b) want 0 128 384",
                     dut.tick_col[0], dut.tick_col[1], dut.tick_col[2], dut.tick_ok);
        end else $display("  ok  T6 tick columns 0/128/384");

        // T7: progress popup: live fill, no cursor, expiry
        cur_rbn = 32'd51000;                              // live 50% -> 256
        @(posedge clk); show_evt = 1; @(posedge clk); show_evt = 0;
        settle;
        render_line(bar_y0 + 12'd3);
        if (!(on_l[100] && a_l[100] == 4'd10 && on_l[300] && a_l[300] == 4'd7))
        begin errors = errors + 1; $display("  FAIL T7a popup fill/backing"); end
        else $display("  ok  T7a popup live fill at 256");
        if (a_l[384] == 4'd15)
        begin errors = errors + 1; $display("  FAIL T7b cursor drawn while not scrubbing"); end
        else $display("  ok  T7b no cursor in popup mode");
        repeat (2600) @(posedge clk);                     // expire (render burned some)
        render_line(bar_y0 + 12'd3);
        if (on_l[300] !== 1'b0)
        begin errors = errors + 1; $display("  FAIL T7c popup did not expire"); end
        else $display("  ok  T7c popup expired");

        // T8: chapter notches in the lower half (popup mode via pause)
        pause_q = 1;
        settle;
        render_line(bar_y0 + 12'd6);                             // vy=6, lower half
        if (!(on_l[128] && a_l[128] == 4'd14 && on_l[129] && a_l[129] == 4'd14 &&
              on_l[384] && a_l[384] == 4'd14))
        begin errors = errors + 1; $display("  FAIL T8a notches at 128/384 (a128=%0d a384=%0d)", a_l[128], a_l[384]); end
        else $display("  ok  T8a notches at 128 + 384");
        if (a_l[200] !== 4'd10)
        begin errors = errors + 1; $display("  FAIL T8b fill between notches (a=%0d)", a_l[200]); end
        else $display("  ok  T8b fill between notches");
        render_line(bar_y0 + 12'd2);                             // vy=2, upper half
        if (a_l[128] !== 4'd10)
        begin errors = errors + 1; $display("  FAIL T8c notch leaked to the upper half"); end
        else $display("  ok  T8c notches lower-half only");
        pause_q = 0;

        // T9: chapter-skip preview (ticks from T6: ch1=0, ch2=128, ch3=384).
        // Visibility rides show_evt exactly like a real B2/B3 press.
        chap_prev = 1; chap_pgm = 8'd2;
        @(posedge clk); show_evt = 1; @(posedge clk); show_evt = 0;
        settle;
        render_line(bar_y0 + 12'd3);                             // upper half: no notches
        if (!(on_l[128] && a_l[128] == 4'd15 && r_l[128] == 8'hFF &&
              a_l[126] == 4'd15 && a_l[130] == 4'd15))
        begin errors = errors + 1; $display("  FAIL T9a chapter cursor at 128 (a=%0d)", a_l[128]); end
        else $display("  ok  T9a chapter-2 cursor at 128");

        chap_pgm = 8'd3;                                  // burst continues
        @(posedge clk); show_evt = 1; @(posedge clk); show_evt = 0;
        settle;
        render_line(bar_y0 + 12'd3);
        if (!(on_l[384] && a_l[384] == 4'd15) || a_l[128] == 4'd15)
        begin errors = errors + 1; $display("  FAIL T9b cursor did not follow to 384"); end
        else $display("  ok  T9b cursor follows the burst to 384");

        chap_prev = 0;                                    // skip landed
        @(posedge clk); show_evt = 1; @(posedge clk); show_evt = 0;
        settle;
        render_line(bar_y0 + 12'd3);
        if (a_l[384] == 4'd15)
        begin errors = errors + 1; $display("  FAIL T9c cursor persists after the skip settles"); end
        else $display("  ok  T9c cursor clears when the skip settles");

        chap_prev = 1; chap_pgm = 8'd99;                  // beyond the tick list
        @(posedge clk); show_evt = 1; @(posedge clk); show_evt = 0;
        settle;
        render_line(bar_y0 + 12'd3);
        if (a_l[0] == 4'd15)
        begin errors = errors + 1; $display("  FAIL T9d out-of-range chapter drew a cursor"); end
        else $display("  ok  T9d out-of-range chapter = no cursor");

        chap_pgm = 8'd2;                                  // scrub owns the cursor
        bar_active = 1; base_rbn = 32'd51000; tgt_rbn = 32'd76000;
        settle;
        render_line(bar_y0 + 12'd3);
        if (!(a_l[384] == 4'd15) || a_l[128] == 4'd15)
        begin errors = errors + 1; $display("  FAIL T9e scrub cursor lost to the chapter preview"); end
        else $display("  ok  T9e scrub cursor wins over the preview");
        bar_active = 0; chap_prev = 0;

        // ---- T10: force_show = the audio-only progress bar --------------
        // WAV/CD-DA has no picture, so the bar must stay up with no gesture,
        // no pause and no event -- and must still yield to a disc menu.
        bar_active = 0; pause_q = 0; chap_prev = 0;
        first_rbn = 32'd0; last_rbn = 32'd1000; cur_rbn = 32'd500;
        tgt_rbn = 32'd500;                 // pin the cursor too, so the check
                                           // below asserts a value rather than
                                           // whatever T9 happened to leave
        repeat (4000) @(posedge clk);      // let any popup timer lapse
        settle;
        render_line(bar_y0 + 12'd3);
        if (on_l[128] || on_l[384])
        begin errors = errors + 1; $display("  FAIL T10a bar visible with nothing asserted"); end
        else $display("  ok  T10a idle: bar hidden");

        force_show = 1; settle;
        render_line(bar_y0 + 12'd3);
        if (!on_l[128])
        begin errors = errors + 1; $display("  FAIL T10b force_show did not raise the bar"); end
        else $display("  ok  T10b force_show holds the bar up with no gesture");

        // ...and the fill tracks the playhead: 500/1000 of the 512-px bar.
        check_px("T10c half fill", 10'd256, 10'd256);

        menu_active = 1; settle;
        render_line(bar_y0 + 12'd3);
        if (on_l[128])
        begin errors = errors + 1; $display("  FAIL T10d force_show overrode menu_active"); end
        else $display("  ok  T10d a disc menu still wins");
        menu_active = 0; force_show = 0;

        // ---- T11: an UNSORTED tick list must still draw every notch -------
        // ★ tick_col[] is built in PROGRAM order but holds PHYSICAL columns, so
        //   it is ascending ONLY while a PGC's program order matches its physical
        //   order. BIG_TROUBLE_LITTLE_CHINA's does not -- its first program sits
        //   at the TOP of the disc, so chapter 1 converts to column ~511 and the
        //   other 44 to low columns. The renderer used to walk the list with one
        //   monotonic pointer (advance while s0_x > tk_q + 1), which on that
        //   shape can never get past entry 0: measured on the board as "only one
        //   chapter marker shows up".
        // Measures what is DRAWN, not what tick_col holds.
        bar_active = 0; chap_prev = 0; pgc_loaded = 0; @(posedge clk);
        first_rbn = 32'd0; last_rbn = 32'd100000;
        put_pm(0, 8'd1); put_pm(1, 8'd2); put_pm(2, 8'd3); put_pm(3, 8'd4);
        put_cf(0, 32'd90000);   // chapter 1 -> col 460  <- HIGHEST, and FIRST
        put_cf(1, 32'd10000);   // chapter 2 -> col  51
        put_cf(2, 32'd30000);   // chapter 3 -> col 153
        put_cf(3, 32'd60000);   // chapter 4 -> col 307
        nr_pgm = 8'd4;
        cur_rbn = 32'd0;                                  // empty fill: notches only
        @(posedge clk); pgc_loaded = 1;
        settle; settle;
        @(posedge clk); show_evt = 1; @(posedge clk); show_evt = 0;
        settle;
        render_line(bar_y0 + 12'd6);                             // lower half = notch row
        begin : t11
            integer n, xx;
            reg [1:0] seen;
            n = 0; seen = 2'd0;
            for (xx = 0; xx < 512; xx = xx + 1)
                if (a_l[xx] == 4'd14) n = n + 1;
            // four notches, 2 px each = 8 columns
            // n == 8 pins the 2 px width as well as the four positions, so a
            // mutation that narrows the notch is caught here and not silently.
            if (!(a_l[51] == 4'd14 && a_l[153] == 4'd14 &&
                  a_l[307] == 4'd14 && a_l[460] == 4'd14 && n == 8)) begin
                errors = errors + 1;
                $display("  FAIL T11 unsorted ticks: drew %0d notch columns; 51=%0d 153=%0d 307=%0d 460=%0d (all should be 14)",
                         n, a_l[51], a_l[153], a_l[307], a_l[460]);
            end else
                $display("  ok  T11 unsorted tick list still draws all four notches (%0d columns)", n);
        end

        // ---- T12: narrow window (VCD 352 / SVCD 480) ----------------------
        // ★ Scored against the bar's COLUMN SPACE, which does not change: a fill at
        //   column 256 of 512 must render at drawn pixel 128 of 256, a cursor at 384 at
        //   drawn 192, and the notches from T11 (51/153/307/460) at their halves. A
        //   module that simply narrowed the box without re-mapping the columns would draw
        //   the left HALF of the bar and fail every one of these.
        bar_active = 0; chap_prev = 0; pgc_loaded = 0; @(posedge clk);
        for (wsel = 0; wsel < 2; wsel = wsel + 1) begin
        act_w_tb = (wsel == 0) ? 12'd352 : 12'd480;       // a VCD's, then an SVCD's
        $display("  -- T12 window %0d wide (box at %0d, %0d px)",
                 act_w_tb, box_x0(act_w_tb), box_w(act_w_tb));
        repeat (4) @(posedge clk);
        first_rbn = 32'd1000; last_rbn = 32'd101000;      // span 100000, as T1/T4
        base_rbn = 32'd51000; tgt_rbn = 32'd76000;        // fill col 256, cursor col 384
        bar_active = 1;
        settle;
        render_line(bar_y0 + 12'd3);
        if (!(on_l[192] && a_l[192] == 4'd15 && r_l[192] == 8'hFF))
        begin errors = errors + 1; $display("  FAIL T12a cursor not at drawn 192 (a=%0d)", a_l[192]); end
        else $display("  ok  T12a cursor at drawn pixel 192 (= column 384)");
        if (!(on_l[100] && a_l[100] == 4'd10))
        begin errors = errors + 1; $display("  FAIL T12b fill at drawn 100 (a=%0d)", a_l[100]); end
        else $display("  ok  T12b fill region (drawn 100 = column 200 < 256)");
        if (!(on_l[150] && a_l[150] == 4'd7))
        begin errors = errors + 1; $display("  FAIL T12c backing at drawn 150 (a=%0d)", a_l[150]); end
        else $display("  ok  T12c backing region (drawn 150 = column 300 > 256)");
        if (!(on_l[0] && a_l[0] == 4'd12 && on_l[255] && a_l[255] == 4'd12))
        begin errors = errors + 1; $display("  FAIL T12d side borders at 0/255 (a0=%0d a255=%0d)", a_l[0], a_l[255]); end
        else $display("  ok  T12d side borders at the NARROW edges (0 and 255)");
        if (on_l[256] !== 1'b0 || on_l[300] !== 1'b0)
        begin errors = errors + 1; $display("  FAIL T12e drew past the narrow box"); end
        else $display("  ok  T12e nothing drawn past drawn pixel 255");

        // Notches. T11's list writes the PAIRS {51,52} {153,154} {307,308} {460,461}, and
        // one drawn pixel covers columns {2k, 2k+1}: a pair starting ODD straddles two
        // drawn pixels, one starting EVEN falls inside one. So 51->{25,26}, 153->{76,77},
        // 307->{153,154}, 460->{230} = 7 lit columns, and every notch survives. The count
        // is asserted EXACTLY, so a sampling rule that smeared or dropped one is caught.
        bar_active = 0; pause_q = 1;
        settle;
        render_line(bar_y0 + 12'd6);                             // lower half = notch row
        begin : t12n
            integer n, xx;
            n = 0;
            for (xx = 0; xx < 256; xx = xx + 1) if (a_l[xx] == 4'd14) n = n + 1;
            if (!(a_l[25] == 4'd14 && a_l[26] == 4'd14 &&
                  a_l[76] == 4'd14 && a_l[77] == 4'd14 &&
                  a_l[153] == 4'd14 && a_l[154] == 4'd14 &&
                  a_l[230] == 4'd14 && n == 7)) begin
                errors = errors + 1;
                $display("  FAIL T12f narrow notches: %0d columns (want 7); 25=%0d 26=%0d 76=%0d 77=%0d 153=%0d 154=%0d 230=%0d",
                         n, a_l[25], a_l[26], a_l[76], a_l[77], a_l[153], a_l[154], a_l[230]);
            end else
                $display("  ok  T12f all four notches survive the narrow pitch (%0d lit columns)", n);
        end
        pause_q = 0;
        end
        act_w_tb = 12'd720;

        // ⚠ $fatal, NOT $finish: vvp exits 0 on $finish, so a runner that scores the
        // exit code sees a FAILING bench as a passing one -- which is exactly how the
        // bench/ac3 suites went silently red for weeks (docs/ac3_decoder_architecture.md
        // §4.11), and it makes every RED arm in bench/dvd/run_ov_geom.sh vacuous.
        if (errors == 0) begin
            $display("SEEK_BAR_TB: ALL TESTS PASSED");
            $finish;
        end else
            $fatal(1, "SEEK_BAR_TB: FAILED (%0d errors)", errors);
    end
endmodule
