// nav_pci_rejudge_tb.sv - a window arms at its authored start, and a window whose
// PTS restarted is re-judged at the clock's re-anchor (issue #176, docs/dvd_nav.md
// "A window committed on the old timeline is re-judged at the re-anchor").
//
// A cell whose PTS restarts sends its HLI while the clock still reads the previous
// cell's timeline (the reader leads the display). That commit cannot be scheduled,
// and the re-anchor at the new cell's first picture used to leave it for the ~1 s
// fallback, timed from the commit (Mad Dog VTS 15 cell 2: a 0.93 s window armed
// 0.81 s late). Now, a few cycles after a re-anchor, a pending whose s_ptm is no more
// than RJ_TOL behind the NEW clock is taken onto the new timeline and promotes at its
// own s_ptm. The 1 s scoring-window lead (EARLY_LEAD, dev-cellcmdhold2..6) is gone:
// it let Mad Dog's continue-screen duel be won before the gunman drew.
//
// The instrument is the player's: press Select (nav_act) at a display time and see
// WHICH command fires (btn_cmd_valid / btn_cmd) -- never `armed` or the slot state.
// Packets are synthetic (979-byte PCI), built field by field from the layout in the
// nav_pci header.
//
//   (a) a scoring-shaped window (set-only buttons) arms AT its start, not before
//   (b) Mad Dog VTS 15: cell 2's window (PTS restarted, s_ptm 0.108 s) commits while
//       the clock reads cell 1's timeline. Before the re-anchor, cell 1's window
//       still answers; at the re-anchor onto cell 2's first picture, cell 2's answers
//       at once (not after the ~1 s fallback)
//   (c) the continue duel: after a flush (clock at 0), a window opening 0.86 s in
//       arms at 0.86 s, with or without a re-anchor in between
//   (d) a pending further than RJ_TOL behind the new clock is another timeline's:
//       not taken (no arm at the re-anchor)
//   (e) a pending 50 ms behind the new clock (inside RJ_TOL) arms at the re-anchor
//
// Run: bench/dvd/run_cmd_hold.sh (green + mutations)

`timescale 1ns/1ps
`default_nettype none

module nav_pci_rejudge_tb;
    logic clk = 0, rst_n = 0;
    logic [7:0] pci_byte = 0;
    logic pci_valid = 0, pci_frame_start = 0;
    logic [32:0] stc = 33'd0;
    logic stc_reanchor = 0;
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
        .stc_reanchor(stc_reanchor),
        .sel_force(1'b0), .sel_force_btn(6'd0), .hl_btnn(6'd0),
        .num_sel(1'b0), .num_btn(6'd0),
        .nav_up(1'b0), .nav_dn(1'b0), .nav_lf(1'b0), .nav_rt(1'b0), .nav_act(nav_act),
        .hl_on(hl_on), .hl_x1(hl_x1), .hl_x2(hl_x2), .hl_y1(hl_y1), .hl_y2(hl_y2),
        .hl_coli(hl_coli), .btn_cmd(btn_cmd), .btn_cmd_valid(btn_cmd_valid),
        .btns_armed(btns_armed), .btns_pend(btns_pend), .btn_sel(btn_sel),
        .dbg_btn_ns(dbg_btn_ns), .hli_seen(hli_seen), .hli_arm(hli_arm)
    );

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
    logic a_ok, b_ok, c_ok, d_ok, e_ok;
    integer k;
    int e0;

    // re-anchor the clock onto a new timeline. emu's clock (av_sync's mirror) and
    // the pulse (the anchor-delta CDC) cross separately, and the mirror only moves on
    // a 90 kHz tick (~300 clk_sys cycles): here the value lands 600 cycles after the
    // pulse, past the 255 cycles hold7-9 waited (the HIL race). nav_pci re-judges
    // ~4095 cycles after the pulse.
    task reanchor(input [31:0] t);
        begin
            stc_reanchor <= 1; @(posedge clk); stc_reanchor <= 0;
            repeat (599) @(posedge clk); stc <= {1'b0, t};
        end
    endtask

    // press Select NOW (the clock where it is); fired = the command, or 1 for none
    task press_now;
        begin
            repeat (4500) @(posedge clk);       // re-judge (~4095) + promotion + button fetch
            nav_act <= 1; @(posedge clk); nav_act <= 0;
            fired = 64'd1;
            for (k = 0; k < 10; k++) begin @(posedge clk); if (btn_cmd_valid) fired = btn_cmd; end
        end
    endtask

    initial begin
        // ---------- (a) a scoring-shaped window arms at S, not before ----------
        reset_dut; e0 = errors;
        stc <= {1'b0, S - 32'd180_000};
        build(2'd1, S, C_G21, C_NOP, C_NOP); feed;
        press_at(S - 50*MS);  expect_cmd("a", "50 ms before S", 64'd1);
        press_at(S + 50*MS);  expect_cmd("a", "50 ms after S", C_G21);
        a_ok = (errors == e0);
        $display("a %s: a scoring window arms at its start, no lead", a_ok ? "PASS" : "FAIL");

        // ---------- (b) VTS 15: the next cell's window commits on the OLD clock ----------
        reset_dut; e0 = errors;
        stc <= {1'b0, 32'd9_000};
        build(2'd1, 32'd16_920, C_G21, C_NOP, C_NOP); feed;       // cell 1: 0.188 s
        press_at(32'd300_000);  expect_cmd("b", "cell 1's window armed", C_G21);
        // the reader reaches cell 2 while the display is at ~3.9 s of cell 1
        stc <= {1'b0, 32'd351_000};
        build(2'd1, 32'd9_720, C_G22, C_NOP, C_NOP); feed;        // cell 2: PTS restarts
        press_now;
        expect_cmd("b", "before the re-anchor, cell 1 still answers", C_G21);
        reanchor(32'd9_720);                                       // cell 2's first picture
        press_now;
        expect_cmd("b", "at the re-anchor, cell 2 answers at once", C_G22);
        b_ok = (errors == e0);
        $display("b %s: a restarted-PTS window arms at its first picture", b_ok ? "PASS" : "FAIL");

        // ---------- (c) the continue duel: a window 0.86 s into a cell after a flush ----------
        reset_dut; e0 = errors;
        stc <= {1'b0, 32'd0};                                      // flushed: clock at 0
        build(2'd1, 32'd77_594, C_G21, C_NOP, C_NOP); feed;       // s_ptm 0.862 s
        press_at(32'd45_000);   expect_cmd("c", "0.5 s, before the draw", 64'd1);
        press_at(32'd82_000);   expect_cmd("c", "0.91 s, after s_ptm", C_G21);
        reset_dut;
        stc <= {1'b0, 32'd0};
        build(2'd1, 32'd77_594, C_G21, C_NOP, C_NOP); feed;
        reanchor(32'd8_525);                                       // the first picture, 0.095 s
        press_now;              expect_cmd("c", "at the re-anchor (0.095 s)", 64'd1);
        press_at(32'd45_000);   expect_cmd("c", "0.5 s after a re-anchor", 64'd1);
        press_at(32'd82_000);   expect_cmd("c", "0.91 s after a re-anchor", C_G21);
        c_ok = (errors == e0);
        $display("c %s: the duel arms at its authored start", c_ok ? "PASS" : "FAIL");

        // ---------- (d) a pending far behind the new clock is not taken ----------
        reset_dut; e0 = errors;
        stc <= {1'b0, 32'd351_000};
        build(2'd1, 32'd400_000, C_G21, C_NOP, C_NOP); feed;      // pending, 4.4 s
        reanchor(32'd580_000);                                     // a new timeline at 6.4 s: 2 s past it
        press_now;              expect_cmd("d", "2 s behind: not taken at the re-anchor", 64'd1);
        d_ok = (errors == e0);
        $display("d %s: another timeline's pending is not re-judged", d_ok ? "PASS" : "FAIL");

        // ---------- (e) a pending 50 ms behind the new clock is taken ----------
        reset_dut; e0 = errors;
        stc <= {1'b0, 32'd351_000};
        build(2'd1, 32'd9_000, C_G23, C_NOP, C_NOP); feed;        // pending, 0.1 s
        reanchor(32'd9_000 + 50*MS);
        press_now;              expect_cmd("e", "50 ms behind: armed at the re-anchor", C_G23);
        e_ok = (errors == e0);
        $display("e %s: a pending inside RJ_TOL arms at the re-anchor", e_ok ? "PASS" : "FAIL");

        if (errors == 0) $display("NAV_PCI_REJUDGE_TB: ALL TESTS PASSED");
        else             $fatal(1, "NAV_PCI_REJUDGE_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $fatal(1, "NAV_PCI_REJUDGE_TB: TIMEOUT");
    end
endmodule
