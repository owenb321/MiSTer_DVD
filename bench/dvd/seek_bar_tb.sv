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
    reg  [6:0]  pm_waddr = 0, cellf_idx = 0;
    reg  [7:0]  pm_wdata = 0;
    reg  [31:0] cellf_rbn = 0;
    wire        bar_on;
    wire [7:0]  bar_r, bar_g, bar_b;
    wire [3:0]  bar_alpha;

    seek_bar #(.POP_TICKS(27'd2000)) dut (
        .clk(clk), .rst_n(rst_n),
        .h_pos(h_pos), .v_pos(v_pos), .pal_mode(1'b0),
        .bar_active(bar_active),
        .base_rbn(base_rbn), .tgt_rbn(tgt_rbn),
        .first_rbn(first_rbn), .last_rbn(last_rbn),
        .pause_q(pause_q), .show_evt(show_evt), .menu_active(menu_active),
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

    // render one line: capture settled output per input h (2-stage pipe);
    // index by the hit-test coordinate hx = h + 4 - 104
    reg       on_l   [0:511];
    reg [3:0] a_l    [0:511];
    reg [7:0] r_l    [0:511];
    integer x, hx;
    task render_line(input [11:0] vv);
        begin
            v_pos = vv;
            for (x = 90; x < 630; x = x + 1) begin
                h_pos = x[11:0];
                @(posedge clk); @(posedge clk);   // fill the 2-stage pipe
                #1;
                hx = x + 4 - 104;
                if (hx >= 0 && hx < 512) begin
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

        // T4: render a mid-bar line (y0=402 for NTSC, upper-half row 405)
        first_rbn = 32'd1000; last_rbn = 32'd101000;
        base_rbn = 32'd51000; tgt_rbn = 32'd76000;        // fill 256, cursor 384
        settle;
        render_line(12'd405);
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
        render_line(12'd402);
        if (!(on_l[300] && a_l[300] == 4'd12))
        begin errors = errors + 1; $display("  FAIL T4e top border row (a=%0d)", a_l[300]); end
        else $display("  ok  T4e top border row");
        render_line(12'd400);
        if (on_l[300] !== 1'b0)
        begin errors = errors + 1; $display("  FAIL T4f renders above the bar"); end
        else $display("  ok  T4f nothing above the bar");

        // T5: inactive
        bar_active = 0;
        render_line(12'd405);
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
        render_line(12'd405);
        if (!(on_l[100] && a_l[100] == 4'd10 && on_l[300] && a_l[300] == 4'd7))
        begin errors = errors + 1; $display("  FAIL T7a popup fill/backing"); end
        else $display("  ok  T7a popup live fill at 256");
        if (a_l[384] == 4'd15)
        begin errors = errors + 1; $display("  FAIL T7b cursor drawn while not scrubbing"); end
        else $display("  ok  T7b no cursor in popup mode");
        repeat (2600) @(posedge clk);                     // expire (render burned some)
        render_line(12'd405);
        if (on_l[300] !== 1'b0)
        begin errors = errors + 1; $display("  FAIL T7c popup did not expire"); end
        else $display("  ok  T7c popup expired");

        // T8: chapter notches in the lower half (popup mode via pause)
        pause_q = 1;
        settle;
        render_line(12'd408);                             // vy=6, lower half
        if (!(on_l[128] && a_l[128] == 4'd14 && on_l[129] && a_l[129] == 4'd14 &&
              on_l[384] && a_l[384] == 4'd14))
        begin errors = errors + 1; $display("  FAIL T8a notches at 128/384 (a128=%0d a384=%0d)", a_l[128], a_l[384]); end
        else $display("  ok  T8a notches at 128 + 384");
        if (a_l[200] !== 4'd10)
        begin errors = errors + 1; $display("  FAIL T8b fill between notches (a=%0d)", a_l[200]); end
        else $display("  ok  T8b fill between notches");
        render_line(12'd404);                             // vy=2, upper half
        if (a_l[128] !== 4'd10)
        begin errors = errors + 1; $display("  FAIL T8c notch leaked to the upper half"); end
        else $display("  ok  T8c notches lower-half only");
        pause_q = 0;

        // T9: chapter-skip preview (ticks from T6: ch1=0, ch2=128, ch3=384).
        // Visibility rides show_evt exactly like a real B2/B3 press.
        chap_prev = 1; chap_pgm = 8'd2;
        @(posedge clk); show_evt = 1; @(posedge clk); show_evt = 0;
        settle;
        render_line(12'd405);                             // upper half: no notches
        if (!(on_l[128] && a_l[128] == 4'd15 && r_l[128] == 8'hFF &&
              a_l[126] == 4'd15 && a_l[130] == 4'd15))
        begin errors = errors + 1; $display("  FAIL T9a chapter cursor at 128 (a=%0d)", a_l[128]); end
        else $display("  ok  T9a chapter-2 cursor at 128");

        chap_pgm = 8'd3;                                  // burst continues
        @(posedge clk); show_evt = 1; @(posedge clk); show_evt = 0;
        settle;
        render_line(12'd405);
        if (!(on_l[384] && a_l[384] == 4'd15) || a_l[128] == 4'd15)
        begin errors = errors + 1; $display("  FAIL T9b cursor did not follow to 384"); end
        else $display("  ok  T9b cursor follows the burst to 384");

        chap_prev = 0;                                    // skip landed
        @(posedge clk); show_evt = 1; @(posedge clk); show_evt = 0;
        settle;
        render_line(12'd405);
        if (a_l[384] == 4'd15)
        begin errors = errors + 1; $display("  FAIL T9c cursor persists after the skip settles"); end
        else $display("  ok  T9c cursor clears when the skip settles");

        chap_prev = 1; chap_pgm = 8'd99;                  // beyond the tick list
        @(posedge clk); show_evt = 1; @(posedge clk); show_evt = 0;
        settle;
        render_line(12'd405);
        if (a_l[0] == 4'd15)
        begin errors = errors + 1; $display("  FAIL T9d out-of-range chapter drew a cursor"); end
        else $display("  ok  T9d out-of-range chapter = no cursor");

        chap_pgm = 8'd2;                                  // scrub owns the cursor
        bar_active = 1; base_rbn = 32'd51000; tgt_rbn = 32'd76000;
        settle;
        render_line(12'd405);
        if (!(a_l[384] == 4'd15) || a_l[128] == 4'd15)
        begin errors = errors + 1; $display("  FAIL T9e scrub cursor lost to the chapter preview"); end
        else $display("  ok  T9e scrub cursor wins over the preview");
        bar_active = 0; chap_prev = 0;

        if (errors == 0) $display("SEEK_BAR_TB: ALL TESTS PASSED");
        else             $display("SEEK_BAR_TB: FAILED (%0d errors)", errors);
        $finish;
    end
endmodule
