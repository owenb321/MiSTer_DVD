// nav_pci_early_tb.sv - a SCORING window arms EARLY_LEAD before its start time
// (issue #176, docs/dvd_nav.md "A scoring window arms early").
//
// libdvdnav players answer a button as soon as they READ its NAV pack, ahead of the
// picture; a Mad Dog McCree gameplay video shoots ~1 s before this core allowed.
// nav_pci now arms an HLI EARLY_LEAD early when (1) the reader says the cell's
// command can see a press (early_ok) and (2) every button is Set-or-nothing with at
// least one Set. A later window on the same timeline as an armed scoring window
// gets no lead (multi-window cells: Bambi, Harry Potter).
//
// The instrument is the player's: press Select (nav_act) at a display time and see
// WHICH command fires (btn_cmd_valid / btn_cmd) -- never `armed` or the slot state.
// Packets are synthetic (979-byte PCI), built field by field from the layout in the
// nav_pci header. LEAD is the module default (1.0 s); the window opens at S.
//
//   (a) set-only + early_ok: fires from S - LEAD, not just before it
//   (b) early_ok low: only from S
//   (c) one button LINKS: only from S
//   (d) all-Nop (no Set): only from S
//   (e) a LATER window on the same timeline, while a scoring window is armed: the
//       armed window keeps answering until the later one's own S
//   (f) an EARLIER-timeline window (a new cell restarts PTS) while one is armed:
//       gets the lead
//   (g) Mad Dog VTS 15: the next cell's 0.93 s window (PTS restarted, start 0.108 s)
//       commits while the clock still reads the OLD cell's timeline (~4 s): it must
//       answer at once, not after the ~1 s fallback (the window would be over)
//
// Run: bench/dvd/run_cmd_hold.sh (green + mutations)

`timescale 1ns/1ps
`default_nettype none

module nav_pci_early_tb;
    logic clk = 0, rst_n = 0;
    logic [7:0] pci_byte = 0;
    logic pci_valid = 0, pci_frame_start = 0;
    logic [32:0] stc = 33'd0;
    logic stc_reanchor = 0;
    logic early_ok = 0;
    logic nav_act = 0;

    wire hl_on;
    wire [9:0] hl_x1, hl_x2, hl_y1, hl_y2;
    wire [31:0] hl_coli;
    wire [63:0] btn_cmd;
    wire btn_cmd_valid, btns_armed, btns_pend, hli_seen, hli_arm;
    wire [5:0] btn_sel, dbg_btn_ns;

    always #5 clk = ~clk;

    nav_pci dut (
        .clk(clk), .rst_n(rst_n),
        .pci_byte(pci_byte), .pci_valid(pci_valid), .pci_frame_start(pci_frame_start),
        .stc(stc), .disp_wide(1'b0), .disp_mode(2'd0),
        .video_live(1'b1), .menu_settled(1'b0), .stc_fresh(1'b1),
        .stc_reanchor(stc_reanchor), .early_ok(early_ok),
        .sel_force(1'b0), .sel_force_btn(6'd0), .hl_btnn(6'd0),
        .num_sel(1'b0), .num_btn(6'd0),
        .nav_up(1'b0), .nav_dn(1'b0), .nav_lf(1'b0), .nav_rt(1'b0), .nav_act(nav_act),
        .hl_on(hl_on), .hl_x1(hl_x1), .hl_x2(hl_x2), .hl_y1(hl_y1), .hl_y2(hl_y2),
        .hl_coli(hl_coli), .btn_cmd(btn_cmd), .btn_cmd_valid(btn_cmd_valid),
        .btns_armed(btns_armed), .btns_pend(btns_pend), .btn_sel(btn_sel),
        .dbg_btn_ns(dbg_btn_ns), .hli_seen(hli_seen), .hli_arm(hli_arm)
    );

    localparam [31:0] LEAD = 32'd90_000;
    localparam [31:0] MS   = 32'd90;            // 1 ms of 90 kHz
    localparam [63:0] C_NOP  = 64'h0000000000000000;
    localparam [63:0] C_G21  = 64'h7100000000150000;   // g[0] = 21
    localparam [63:0] C_G22  = 64'h7100000000160000;   // g[0] = 22
    localparam [63:0] C_G23  = 64'h7100000000170000;   // g[0] = 23
    localparam [63:0] C_LINK = 64'h2007000000000003;   // LinkCN 3

    logic [7:0] pkt [0:978];

    // one PCI packet: hli_ss, the window [sptm, sptm + 2 s], 3 buttons, fosl 1
    task build(input [1:0] ss, input [31:0] sptm, input [63:0] c1, input [63:0] c2,
               input [63:0] c3);
        integer i, b;
        logic [63:0] c;
        begin
            for (i = 0; i < 979; i++) pkt[i] = 8'h00;
            {pkt['h0C], pkt['h0D], pkt['h0E], pkt['h0F]} = sptm - 32'd30_000;  // vobu_s_ptm
            pkt['h61] = {6'd0, ss};
            {pkt['h62], pkt['h63], pkt['h64], pkt['h65]} = sptm;
            {pkt['h66], pkt['h67], pkt['h68], pkt['h69]} = sptm + 32'd180_000;
            pkt['h6E] = 8'h10;                  // btngr_ns = 1, group 1 = 4:3
            pkt['h71] = 8'd3;                   // btn_ns
            pkt['h74] = 8'd1;                   // fosl: button 1
            for (b = 0; b < 3; b++) begin
                c = (b == 0) ? c1 : (b == 1) ? c2 : c3;
                pkt['h8E + b*18 + 2] = 8'd10;   // a non-empty rect
                pkt['h8E + b*18 + 5] = 8'd10;
                for (i = 0; i < 8; i++) pkt['h8E + b*18 + 10 + i] = c[8*(7-i) +: 8];
            end
        end
    endtask

    task feed;
        integer i;
        begin
            for (i = 0; i < 979; i++) begin
                pci_byte        <= pkt[i];
                pci_valid       <= 1;
                pci_frame_start <= (i == 0);
                @(posedge clk);
            end
            pci_valid <= 0; pci_frame_start <= 0;
            repeat (20) @(posedge clk);
        end
    endtask

    // press Select at display time t; return the fired command, or 1 for none
    logic [63:0] fired;
    task press_at(input [31:0] t);
        integer k;
        begin
            stc <= {1'b0, t};
            repeat (200) @(posedge clk);        // promotion + button fetch
            nav_act <= 1; @(posedge clk); nav_act <= 0;
            fired = 64'd1;
            for (k = 0; k < 10; k++) begin
                @(posedge clk);
                if (btn_cmd_valid) fired = btn_cmd;
            end
        end
    endtask

    task reset_dut;
        begin
            rst_n <= 0; repeat (5) @(posedge clk); rst_n <= 1; repeat (5) @(posedge clk);
        end
    endtask

    int errors = 0;
    task expect_cmd(input string arm, input string what, input [63:0] want);
        begin
            if (fired !== want) begin
                errors++;
                $display("FAIL: %s: %s: fired %h, want %h", arm, what, fired, want);
            end
        end
    endtask

    localparam [31:0] S = 32'd900_000;          // the window opens at 10 s
    logic a_ok, b_ok, c_ok, d_ok, e_ok, f_ok, g_ok;
    integer k;
    int e0;

    initial begin
        // ---------- (a) set-only + early_ok: armed from S - LEAD ----------
        reset_dut; e0 = errors;
        early_ok <= 1; stc <= {1'b0, S - 32'd180_000};
        build(2'd1, S, C_G21, C_NOP, C_NOP); feed;
        press_at(S - LEAD - 50*MS); expect_cmd("a", "50 ms before the lead", 64'd1);
        press_at(S - LEAD + 50*MS); expect_cmd("a", "50 ms into the lead", C_G21);
        a_ok = (errors == e0);
        $display("a %s: a scoring window arms LEAD before its start", a_ok ? "PASS" : "FAIL");

        // ---------- (b) early_ok low: armed only at S ----------
        reset_dut; e0 = errors;
        early_ok <= 0; stc <= {1'b0, S - 32'd180_000};
        build(2'd1, S, C_G21, C_NOP, C_NOP); feed;
        press_at(S - LEAD + 50*MS); expect_cmd("b", "inside the lead", 64'd1);
        press_at(S + 50*MS);        expect_cmd("b", "after S", C_G21);
        b_ok = (errors == e0);
        $display("b %s: not a scoring cell -> armed at S", b_ok ? "PASS" : "FAIL");

        // ---------- (c) a button links: armed only at S ----------
        reset_dut; e0 = errors;
        early_ok <= 1; stc <= {1'b0, S - 32'd180_000};
        build(2'd1, S, C_G21, C_LINK, C_NOP); feed;
        press_at(S - LEAD + 50*MS); expect_cmd("c", "inside the lead", 64'd1);
        press_at(S + 50*MS);        expect_cmd("c", "after S", C_G21);
        c_ok = (errors == e0);
        $display("c %s: a linking button -> not a scoring window", c_ok ? "PASS" : "FAIL");

        // ---------- (d) all Nop (no Set): armed only at S ----------
        reset_dut; e0 = errors;
        early_ok <= 1; stc <= {1'b0, S - 32'd180_000};
        build(2'd1, S, C_NOP, C_NOP, C_NOP); feed;
        press_at(S - LEAD + 50*MS); expect_cmd("d", "inside the lead", 64'd1);
        press_at(S + 50*MS);        expect_cmd("d", "after S", C_NOP);
        d_ok = (errors == e0);
        $display("d %s: no Set -> not a scoring window", d_ok ? "PASS" : "FAIL");

        // ---------- (e) a later same-timeline window while one is armed ----------
        reset_dut; e0 = errors;
        early_ok <= 1; stc <= {1'b0, S - 32'd180_000};
        build(2'd1, S, C_G21, C_NOP, C_NOP); feed;
        press_at(S + 50*MS);  expect_cmd("e", "window 1 armed", C_G21);
        // window 2 two seconds later, committed while window 1 is on screen
        build(2'd1, S + 32'd180_000, C_G22, C_NOP, C_NOP); feed;
        press_at(S + 32'd180_000 - LEAD + 50*MS);
        expect_cmd("e", "inside window 2's lead: window 1 still answers", C_G21);
        press_at(S + 32'd180_000 + 50*MS);
        expect_cmd("e", "window 2 at its own start", C_G22);
        e_ok = (errors == e0);
        $display("e %s: a later window of the same cell waits for its own start", e_ok ? "PASS" : "FAIL");

        // ---------- (f) a new cell restarts PTS while a scoring window is armed ----------
        reset_dut; e0 = errors;
        early_ok <= 1; stc <= {1'b0, S - 32'd180_000};
        build(2'd1, S, C_G21, C_NOP, C_NOP); feed;
        press_at(S + 50*MS);  expect_cmd("f", "window 1 armed", C_G21);
        // the next cell's timeline starts near 0; its window opens at 3 s
        stc <= {1'b0, 32'd9_000};
        stc_reanchor <= 1; @(posedge clk); stc_reanchor <= 0;
        repeat (5) @(posedge clk);
        build(2'd1, 32'd270_000, C_G23, C_NOP, C_NOP); feed;
        press_at(32'd270_000 - LEAD + 50*MS);
        expect_cmd("f", "inside the new cell's lead", C_G23);
        f_ok = (errors == e0);
        $display("f %s: the next cell's window (PTS restarted) gets the lead", f_ok ? "PASS" : "FAIL");

        // ---------- (g) the next cell's window commits on the OLD clock ----------
        reset_dut; e0 = errors;
        early_ok <= 1; stc <= {1'b0, 32'd180_000};
        build(2'd1, 32'd270_000, C_G21, C_NOP, C_NOP); feed;      // cell 1: 3 s window
        press_at(32'd300_000);  expect_cmd("g", "cell 1's window armed", C_G21);
        // the reader reaches cell 2 while the display is at ~3.9 s of cell 1
        stc <= {1'b0, 32'd351_000};
        build(2'd1, 32'd9_720, C_G22, C_NOP, C_NOP); feed;        // cell 2: PTS restarts
        repeat (200) @(posedge clk);
        nav_act <= 1; @(posedge clk); nav_act <= 0;
        fired = 64'd1;
        for (k = 0; k < 10; k++) begin @(posedge clk); if (btn_cmd_valid) fired = btn_cmd; end
        expect_cmd("g", "cell 2's window must answer at once (before the re-anchor)", C_G22);
        g_ok = (errors == e0);
        $display("g %s: a restarted-PTS scoring window arms at its commit", g_ok ? "PASS" : "FAIL");

        if (errors == 0) $display("NAV_PCI_EARLY_TB: ALL TESTS PASSED");
        else             $fatal(1, "NAV_PCI_EARLY_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $fatal(1, "NAV_PCI_EARLY_TB: TIMEOUT");
    end
endmodule
