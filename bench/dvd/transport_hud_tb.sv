// transport_hud_tb.sv -- Phase 11 HUD behavioural test (formatter + visibility).
//
// Drives events/values and checks the TEXT PLANE contents (decoded back to
// ASCII against expected strings) plus the visibility ledger:
//   T1: persist toggle (B9) -> visible; play icon + times + CH n/N formatted
//   T2: pause -> pause icon
//   T3: scrub fwd tier2 -> ">>x3" icon field
//   T4: scrub rev tier0 -> "<<x1"
//   T5: CH section hidden when cur_pgm = 0
//   T6: menu_active suppresses visibility (persist survives -> back on resume)
//   T7: show_evt arms the timer; expires after SHOW_TICKS (shrunk for sim)
//   T8: load_evt clears persistent mode
//
// Run: iverilog -g2012 -o /tmp/hud_sim dvd/transport_hud.sv bench/dvd/transport_hud_tb.sv
//      vvp /tmp/hud_sim   (from the repo root -- the ROM loads dvd/hud_font.mem)
`timescale 1ns/1ps

module transport_hud_tb;

    reg clk = 0, rst_n = 0;
    always #18.5 clk = ~clk;                 // ~27 MHz

    reg  [11:0] h_pos = 0, v_pos = 0;
    reg         pal_mode = 0;
    reg         menu_active = 0, pause_q = 0, bar_active = 0;
    reg         scrub_held = 0, scrub_dir = 0;
    reg  [1:0]  scrub_tier = 0;
    reg         display_edge = 0, load_evt = 0, show_evt = 0;
    reg  [31:0] cur_time = 0, total_time = 0;
    reg  [7:0]  cur_pgm = 0, nr_pgm = 0;
    reg         aud_evt = 0, sub_evt = 0, angle_evt = 0, chap_evt = 0;
    reg         css_warn = 0;
    reg         img_warn = 0;      // Phase-2: unplayable image
    reg         aud_warn = 0;      // Phase-2: unsupported audio format
    reg         vts_evt  = 0;      // Phase-2: title-VTS notice pulse
    reg  [7:0]  vts_no   = 8'd0;
    reg  [3:0]  aud_no = 0, aud_cnt = 0, sub_no = 0, sub_cnt = 0;
    reg  [3:0]  ang_no = 0, ang_cnt = 0;
    reg  [15:0] aud_lang = 0, sub_lang = 0;
    reg         sub_enabled = 0;
    wire        hud_on;
    wire [7:0]  hud_r, hud_g, hud_b;
    wire [3:0]  hud_alpha;

    transport_hud #(.SHOW_TICKS(27'd2000)) dut (
        .clk(clk), .rst_n(rst_n),
        .h_pos(h_pos), .v_pos(v_pos), .pal_mode(pal_mode),
        .menu_active(menu_active), .dbg_mode(1'b0), .pause_q(pause_q), .bar_active(bar_active),
        .scrub_held(scrub_held), .scrub_dir(scrub_dir), .scrub_tier(scrub_tier),
        .display_edge(display_edge), .load_evt(load_evt), .show_evt(show_evt),
        .cur_time(cur_time), .total_time(total_time),
        .cur_pgm(cur_pgm), .nr_pgm(nr_pgm),
        .aud_evt(aud_evt), .sub_evt(sub_evt), .angle_evt(angle_evt),
        .chap_evt(chap_evt), .css_warn(css_warn),
        .img_warn(img_warn), .aud_warn(aud_warn),
        .vts_evt(vts_evt), .vts_no(vts_no),
        .aud_no(aud_no), .aud_cnt(aud_cnt), .aud_lang(aud_lang),
        .sub_enabled(sub_enabled), .sub_no(sub_no), .sub_cnt(sub_cnt),
        .sub_lang(sub_lang), .ang_no(ang_no), .ang_cnt(ang_cnt),
        .hud_on(hud_on), .hud_r(hud_r), .hud_g(hud_g), .hud_b(hud_b),
        .hud_alpha(hud_alpha)
    );

    integer errors = 0;

    // decode one text-plane cell to ASCII
    function [7:0] g2a(input [5:0] g);
        begin
            if (g <= 6'd9)       g2a = "0" + {2'b00, g};
            else if (g == 6'd10) g2a = ":";
            else if (g == 6'd11) g2a = "/";
            else if (g == 6'd12) g2a = ".";
            else if (g == 6'd13) g2a = "-";
            else if (g == 6'd14) g2a = " ";
            else if (g == 6'd15) g2a = "x";
            else if (g >= 6'd16 && g <= 6'd41) g2a = "A" + {2'b00, g - 6'd16};
            else if (g == 6'd42) g2a = ">";
            else if (g == 6'd43) g2a = "\"";
            else if (g == 6'd44) g2a = "<";
            else if (g == 6'd63) g2a = "~";
            else                 g2a = "?";
        end
    endfunction

    reg [8*32-1:0] line;
    task read_line(input integer row);
        integer i;
        begin
            // wait for the formatter to be idle after a full fresh pass
            @(posedge clk);
            wait (dut.fmt_col == 7'd0);       // a pass is starting
            wait (dut.fmt_col > 7'd63);       // ... and has finished
            @(posedge clk);
            for (i = 0; i < 32; i = i + 1)
                line[8*(31-i) +: 8] = g2a(dut.plane[row*32 + i][5:0]);
        end
    endtask

    task check_line(input [127:0] label, input [8*32-1:0] want);
        begin
            read_line(0);
            if (line !== want) begin
                errors = errors + 1;
                $display("  FAIL %0s:\n    got  '%s'\n    want '%s'", label, line, want);
            end else
                $display("  ok  %0s: '%s'", label, line);
        end
    endtask

    task check_popup(input [127:0] label, input [8*32-1:0] want);
        begin
            read_line(1);
            if (line !== want) begin
                errors = errors + 1;
                $display("  FAIL %0s:\n    got  '%s'\n    want '%s'", label, line, want);
            end else
                $display("  ok  %0s: '%s'", label, line);
        end
    endtask

    task check_vis(input [127:0] label, input want);
        begin
            @(posedge clk);
            if (dut.vis !== want) begin
                errors = errors + 1;
                $display("  FAIL %0s: vis=%b want %b", label, dut.vis, want);
            end else
                $display("  ok  %0s: vis=%b", label, dut.vis);
        end
    endtask

    initial begin
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);

        // values: 0:12:34 elapsed / 1:37:05 total, CH 12/23
        cur_time   = {8'h00, 8'h12, 8'h34, 8'h00};
        total_time = {8'h01, 8'h37, 8'h05, 8'hC0};
        cur_pgm = 8'd12; nr_pgm = 8'd23;

        // T1: persist on -> visible, play line
        check_vis("T1a hidden at boot", 1'b0);
        @(posedge clk); display_edge = 1; @(posedge clk); display_edge = 0;
        check_vis("T1b persist on", 1'b1);
        check_line("T1c play line", ">    0:12:34/1:37:05 CH 12/23~~~");

        // T2: pause icon
        pause_q = 1;
        check_line("T2 pause icon", "\"    0:12:34/1:37:05 CH 12/23~~~");
        pause_q = 0;

        // T3: scrub forward, tier 2 -> ">>x3"
        scrub_held = 1; scrub_dir = 1; scrub_tier = 2'd2; bar_active = 1;
        check_line("T3 ffwd x3", ">>x3 0:12:34/1:37:05 CH 12/23~~~");

        // T4: scrub reverse, tier 0 -> "<<x1"
        scrub_dir = 0; scrub_tier = 2'd0;
        check_line("T4 rev x1", "<<x1 0:12:34/1:37:05 CH 12/23~~~");
        scrub_held = 0; bar_active = 0;

        // T5: CH hidden when unresolved
        cur_pgm = 8'd0;
        check_line("T5 no chapter", ">    0:12:34/1:37:05         ~~~");
        cur_pgm = 8'd12;

        // T6: menu suppression (persist survives)
        menu_active = 1;
        check_vis("T6a menu hides", 1'b0);
        menu_active = 0;
        check_vis("T6b resume shows", 1'b1);

        // T7: timer arm + expiry (persist off first)
        @(posedge clk); display_edge = 1; @(posedge clk); display_edge = 0;
        repeat (2100) @(posedge clk);      // drain the toggle's own timer arm
        check_vis("T7a hidden (persist off)", 1'b0);
        @(posedge clk); show_evt = 1; @(posedge clk); show_evt = 0;
        check_vis("T7b event shows", 1'b1);
        repeat (2100) @(posedge clk);
        check_vis("T7c timer expired", 1'b0);

        // T8: load clears persist
        @(posedge clk); display_edge = 1; @(posedge clk); display_edge = 0;
        check_vis("T8a persist on", 1'b1);
        @(posedge clk); load_evt = 1; @(posedge clk); load_evt = 0;
        repeat (2100) @(posedge clk);      // the toggle also armed the timer
        check_vis("T8b load cleared", 1'b0);

        // T9: audio popup
        aud_no = 4'd2; aud_cnt = 4'd4; aud_lang = "fr";
        @(posedge clk); aud_evt = 1; @(posedge clk); aud_evt = 0;
        if (dut.pop_vis !== 1'b1) begin errors = errors+1; $display("  FAIL T9a popup not visible"); end
        check_popup("T9b audio popup", "AUDIO  2/ 4 FR~~~~~~~~~~~~~~~~~~");

        // T10: subtitle popup (on, then OFF variant)
        sub_enabled = 1; sub_no = 4'd1; sub_cnt = 4'd3; sub_lang = "en";
        @(posedge clk); sub_evt = 1; @(posedge clk); sub_evt = 0;
        check_popup("T10a sub popup", "SUB    1/ 3 EN~~~~~~~~~~~~~~~~~~");
        sub_enabled = 0;
        @(posedge clk); sub_evt = 1; @(posedge clk); sub_evt = 0;
        check_popup("T10b sub off", "SUB   OFF~~~~~~~~~~~~~~~~~~~~~~~");

        // T11: angle + chapter popups (no language field)
        ang_no = 4'd2; ang_cnt = 4'd3;
        @(posedge clk); angle_evt = 1; @(posedge clk); angle_evt = 0;
        check_popup("T11a angle popup", "ANGLE  2/ 3~~~~~~~~~~~~~~~~~~~~~");
        @(posedge clk); chap_evt = 1; @(posedge clk); chap_evt = 0;
        check_popup("T11b chapter popup", "CH    12/23~~~~~~~~~~~~~~~~~~~~~");

        // T12: popup expires independently of the (hidden) status line
        repeat (2100) @(posedge clk);
        @(posedge clk);
        if (dut.pop_vis !== 1'b0) begin errors = errors+1; $display("  FAIL T12 popup did not expire"); end
        else $display("  ok  T12 popup expired");

        // T13: CSS warning — persistent, menu-proof, yields to user popups
        css_warn = 1;
        repeat (4) @(posedge clk);
        if (dut.pop_vis !== 1'b1) begin errors = errors+1; $display("  FAIL T13a css popup not visible"); end
        check_popup("T13b css text", "CSS ENCRYPTED~~~~~~~~~~~~~~~~~~~");
        menu_active = 1;
        @(posedge clk); @(posedge clk);
        if (dut.pop_vis !== 1'b1) begin errors = errors+1; $display("  FAIL T13c css popup hidden in menu"); end
        else $display("  ok  T13c css popup survives menu");
        menu_active = 0;
        // user popup takes the slot for SHOW_TICKS, then CSS re-arms. (Checked on
        // pop_type, not the rendered plane: the TB's shrunk SHOW_TICKS is shorter
        // than a formatter pass period, so the transient text never renders here.)
        @(posedge clk); aud_evt = 1; @(posedge clk); aud_evt = 0;
        @(posedge clk);
        if (dut.pop_type !== 3'd0) begin errors = errors+1; $display("  FAIL T13d user popup did not take the slot"); end
        else $display("  ok  T13d user popup wins the slot");
        repeat (2100) @(posedge clk);
        check_popup("T13e css re-arms", "CSS ENCRYPTED~~~~~~~~~~~~~~~~~~~");
        // cleared latch (new mount) -> popup expires for good
        css_warn = 0;
        repeat (2100) @(posedge clk);
        @(posedge clk);
        if (dut.pop_vis !== 1'b0) begin errors = errors+1; $display("  FAIL T13f css popup did not clear"); end
        else $display("  ok  T13f css popup cleared");

        // ------------------------------------------------------------------
        // T14: unplayable image — persistent + menu-proof, like CSS
        // ------------------------------------------------------------------
        menu_active = 0;
        img_warn = 1;
        repeat (60) @(posedge clk);
        check_popup("T14a image text", "UNSUPPORTED IMAGE~~~~~~~~~~~~~~~");
        menu_active = 1;
        repeat (10) @(posedge clk);
        if (dut.pop_vis !== 1'b1) begin errors = errors+1; $display("  FAIL T14b image popup hidden in menu"); end
        else $display("  ok  T14b image popup survives menu");
        menu_active = 0;
        img_warn = 0;
        repeat (2100) @(posedge clk);
        @(posedge clk);
        if (dut.pop_vis !== 1'b0) begin errors = errors+1; $display("  FAIL T14c image popup did not clear"); end
        else $display("  ok  T14c image popup cleared");

        // ------------------------------------------------------------------
        // T15: unsupported audio — and image OUTRANKS it (root-cause order)
        // ------------------------------------------------------------------
        aud_warn = 1;
        repeat (60) @(posedge clk);
        check_popup("T15a audio text", "AUDIO UNSUPPORTED~~~~~~~~~~~~~~~");
        img_warn = 1;                      // both asserted: image must win
        repeat (2100) @(posedge clk);
        repeat (60) @(posedge clk);
        check_popup("T15b image outranks audio", "UNSUPPORTED IMAGE~~~~~~~~~~~~~~~");
        img_warn = 0; aud_warn = 0;
        repeat (2100) @(posedge clk);

        // ------------------------------------------------------------------
        // T16: title-VTS notice — one-shot pulse, hidden in menus, expires
        // ------------------------------------------------------------------
        vts_no = 8'd21;
        vts_evt = 1; @(posedge clk); vts_evt = 0;
        repeat (60) @(posedge clk);
        check_popup("T16a vts text", "TITLE VTS 21~~~~~~~~~~~~~~~~~~~~");
        menu_active = 1;
        repeat (10) @(posedge clk);
        if (dut.pop_vis !== 1'b0) begin errors = errors+1; $display("  FAIL T16b vts notice should hide in menus"); end
        else $display("  ok  T16b vts notice hidden in menus");
        menu_active = 0;
        repeat (2100) @(posedge clk);
        @(posedge clk);
        if (dut.pop_vis !== 1'b0) begin errors = errors+1; $display("  FAIL T16c vts notice did not expire"); end
        else $display("  ok  T16c vts notice expired");

        // ------------------------------------------------------------------
        // T17: warning PREEMPTION (HW round 1). A higher-priority warning must
        // take the slot from a lower one MID-SHOW, not wait for it to expire —
        // on a scrambled disc aud_warn (arms at nav_ready) beat css_warn (needs
        // 4 scrambled PES) to the slot and held it for the full 2.5 s.
        // ------------------------------------------------------------------
        aud_warn = 1;
        repeat (60) @(posedge clk);
        check_popup("T17a audio holds slot", "AUDIO UNSUPPORTED~~~~~~~~~~~~~~~");
        css_warn = 1;                      // arrives late, must preempt IMMEDIATELY
        repeat (60) @(posedge clk);
        check_popup("T17b css preempts audio", "CSS ENCRYPTED~~~~~~~~~~~~~~~~~~~");
        css_warn = 0; aud_warn = 0;
        repeat (2100) @(posedge clk);

        // img must likewise preempt aud, but NOT the other way round
        aud_warn = 1;
        repeat (60) @(posedge clk);
        img_warn = 1;
        repeat (60) @(posedge clk);
        check_popup("T17c image preempts audio", "UNSUPPORTED IMAGE~~~~~~~~~~~~~~~");
        img_warn = 0;                      // aud alone must retake it on expiry
        repeat (2100) @(posedge clk);
        repeat (60) @(posedge clk);
        check_popup("T17d audio retakes slot", "AUDIO UNSUPPORTED~~~~~~~~~~~~~~~");

        // a USER event must still win, and must NOT be preempted by a warning
        css_warn = 1;
        aud_evt = 1; @(posedge clk); aud_evt = 0;
        repeat (60) @(posedge clk);
        if (dut.pop_type !== 3'd0) begin errors = errors+1; $display("  FAIL T17e user popup was preempted by a warning"); end
        else $display("  ok  T17e user popup not preempted by warning");
        css_warn = 0; aud_warn = 0;
        repeat (2100) @(posedge clk);

        if (errors == 0) $display("TRANSPORT_HUD_TB: ALL TESTS PASSED");
        else             $display("TRANSPORT_HUD_TB: FAILED (%0d errors)", errors);
        $finish;
    end
endmodule
