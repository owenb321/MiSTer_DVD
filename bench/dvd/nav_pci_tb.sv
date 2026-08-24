// nav_pci_tb.sv - Phase-3 HLI capture / button-nav test for dvd/nav_pci.sv,
// driven by REAL MiB NAV sectors (bench/dvd/test_vobs/mib_menu_pci.hex,
// regenerate: python3 tools/nav_extract.py MEN_IN_BLACK.iso --vts 2
//   --sector 6836 --count 1 --hex ... --hex-count 1   [sector 1: 7 buttons]
// + append --sector 22933 [sector 2: 1-button Nop still HLI]).
//
// Golden values from tools/nav_extract.py:
//   sector 1 (RBN 6836): hli_ss=1 s_ptm=2579208 e_ptm=0xFFFFFFFF btn_ns=7
//     fosl=0; coli grp1 sel=35400ff0 act=34500ee0
//     btn 1: rect x122..314 y128..182 links(u/d/l/r)=7/2/7/4 cmd LinkPGCN 9
//     btn 4: rect x414..599 y128..182 links=7/5/1/7        cmd LinkPGCN 8
//   sector 2 (RBN 22933): hli_ss=1 btn_ns=1 btn 1 rect x30..57 y14..44 cmd Nop
//
// TESTS: commit + arm vs STC window; initial selection; D-pad link walk;
// activation (cmd pulse + ACT-colour flash); new-HLI (ss=1) selection reset.
`timescale 1ns/1ps
`default_nettype none

module nav_pci_tb;
    logic clk = 0, rst_n = 0;
    logic [7:0] pci_byte = 0;
    logic pci_valid = 0, pci_frame_start = 0;
    logic [32:0] stc = 33'd0;
    // display-mode verdict (Phase-3 button groups). Defaults model the HW common
    // case: 16:9 content presented wide -> group 1, which is also what the MiB
    // fixture's golden values were HW-validated against (its dsp_ty=(1,4): group
    // 1 = wide), so TESTS 1-10 are bit-identical to the pre-group behaviour.
    logic disp_wide = 1;
    logic [1:0] disp_mode = 0;
    logic video_live = 0;
    logic menu_settled = 0;   // settled-still promotion input (tests exercise the timer path unless raised)
    logic nav_up = 0, nav_dn = 0, nav_lf = 0, nav_rt = 0, nav_act = 0;
    logic num_sel = 0;
    logic [5:0] num_btn = 0;

    wire hl_on;
    wire [9:0] hl_x1, hl_x2, hl_y1, hl_y2;
    wire [31:0] hl_coli;
    wire [63:0] btn_cmd;
    wire btn_cmd_valid;
    wire btns_armed;
    wire [5:0] btn_sel, dbg_btn_ns;

    always #5 clk = ~clk;

    nav_pci #(.PROMOTE_FALLBACK(27'd300)) dut (   // small fallback for a fast sim
        .clk(clk), .rst_n(rst_n),
        .pci_byte(pci_byte), .pci_valid(pci_valid), .pci_frame_start(pci_frame_start),
        .stc(stc),
        .disp_wide(disp_wide), .disp_mode(disp_mode),
        .video_live(video_live),
        .menu_settled(menu_settled),
        .stc_fresh(1'b1),   // TB scenarios model full-flush loads (display-coherent STC)
        .sel_force(1'b0), .sel_force_btn(6'd0),
        .num_sel(num_sel), .num_btn(num_btn),
        .nav_up(nav_up), .nav_dn(nav_dn), .nav_lf(nav_lf), .nav_rt(nav_rt),
        .nav_act(nav_act),
        .hl_on(hl_on), .hl_x1(hl_x1), .hl_x2(hl_x2), .hl_y1(hl_y1), .hl_y2(hl_y2),
        .hl_coli(hl_coli),
        .btn_cmd(btn_cmd), .btn_cmd_valid(btn_cmd_valid),
        .btns_armed(btns_armed), .btn_sel(btn_sel), .dbg_btn_ns(dbg_btn_ns)
    );

    // count activation pulses + last cmd
    int acts = 0;
    logic [63:0] last_cmd;
    always_ff @(posedge clk) if (btn_cmd_valid) begin
        acts <= acts + 1; last_cmd <= btn_cmd;
    end

    logic [7:0] nav [0:12287];  // 2 real MiB sectors + 2 scratch (T8/9) + T2 2-group @8192

    // feed one sector's PCI payload (bytes 0x2D..0x2D+978 of the NAV sector)
    task feed_pci(input int base);
        int i;
        begin
            for (i = 0; i < 979; i++) begin
                pci_byte        <= nav[base + 'h2D + i];
                pci_valid       <= 1;
                pci_frame_start <= (i == 0);
                @(posedge clk);
            end
            pci_valid       <= 0;
            pci_frame_start <= 0;
            repeat (80) @(posedge clk);   // let the fetch FSM finish
        end
    endtask

    // NOTE: a task(output logic sig) only copies out at task END - the pulse
    // would never appear. Select the signal by index and drive it directly.
    task pulse(input int which);   // 0=up 1=dn 2=lf 3=rt 4=act
        begin
            case (which)
            0: nav_up  <= 1;
            1: nav_dn  <= 1;
            2: nav_lf  <= 1;
            3: nav_rt  <= 1;
            default: nav_act <= 1;
            endcase
            @(posedge clk);
            nav_up <= 0; nav_dn <= 0; nav_lf <= 0; nav_rt <= 0; nav_act <= 0;
            repeat (80) @(posedge clk);
        end
    endtask

    // numpad digit press: force selection to `b` (1-based) and activate it
    task num_press(input int b);
        begin
            num_btn <= b[5:0];
            num_sel <= 1;
            @(posedge clk);
            num_sel <= 0;
            repeat (80) @(posedge clk);   // let the fetch FSM refetch + activate
        end
    endtask

    int errors = 0;
    task chk(input bit c, input string m);
        if (!c) begin errors++; $display("  ERR %s", m); end
    endtask

    int i;
    // PCI payload byte offsets inside a NAV sector (data starts at 0x2D):
    localparam int PCI = 'h2D;
    localparam int OFF_SS   = PCI + 'h061;   // hli_ss low byte (low 2 bits)
    localparam int OFF_VPTM = PCI + 'h00C;   // pci_gi.vobu_s_ptm (BE u32 @0x0C..0x0F)
    localparam int OFF_EPTM = PCI + 'h066;   // hl_gi.hli_e_ptm  (BE u32 @0x66..0x69)
    initial begin
        for (i = 0; i < 12288; i++) nav[i] = 8'hXX;
        // real fixture = 2 sectors (0..4095); 4096.. are built at runtime (TEST 8/9).
        $readmemh("bench/dvd/test_vobs/mib_menu_pci.hex", nav, 0, 4095);
        // T2 VTSM VTS_01 RBN 8449 (regen: tools/nav_extract.py ULTIMATE_T2.iso
        //   --vts 1 --sector 8449 --count 1 --hex ... --hex-count 1):
        // btngr_ns=2 dsp_ty=(1,2)={wide,letterbox} btn_ns=5 fosl=0 s_ptm=14042
        // grp1 btn1 x343..655 y72..149  btn2 y154..239 (links: btn1 dn=2)
        // grp2 btn1 x343..655 y114..172 btn2 y181..245 (the 3/4+60 LB remap)
        $readmemh("bench/dvd/test_vobs/t2_menu_2grp.hex", nav, 8192, 10239);
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);

        if (nav[0] !== 8'h00 || nav[3] !== 8'hBA) begin
            $display("NAV_PCI_TB: fixture absent -> SKIPPED (regen with tools/nav_extract.py)");
            $display("NAV_PCI_TB: ALL TESTS PASSED (skipped)");
            $finish;
        end

        // ---- TEST 1: commit the 7-button HLI. v3: promotion is STRICTLY at
        // s_ptm (the highlight must appear WITH the video, not before it).
        stc = 33'd0;
        feed_pci(0);
        chk(btns_armed === 1'b0, "T1a not armed before s_ptm");
        stc = 33'd2579300;                       // cross s_ptm=2579208
        repeat (120) @(posedge clk);
        $display("T1: armed=%b btn_ns=%0d sel=%0d hl_on=%b (expect 1 7 1 1)",
                 btns_armed, dbg_btn_ns, btn_sel, hl_on);
        chk(btns_armed === 1'b1, "T1 armed at s_ptm");
        chk(dbg_btn_ns == 6'd7, "T1 btn_ns");
        chk(btn_sel == 6'd1, "T1 initial selection (fosl=0 -> button 1)");
        chk(hl_on === 1'b1, "T1 hl_on");

        // ---- TEST 2: btn 1 rect + coli
        stc = 33'd2579300;
        repeat (4) @(posedge clk);
        $display("T2: hl_on=%b rect x%0d..%0d y%0d..%0d coli=%08x",
                 hl_on, hl_x1, hl_x2, hl_y1, hl_y2, hl_coli);
        chk(hl_on === 1'b1, "T2 hl_on in window");
        chk(hl_x1 == 10'd122 && hl_x2 == 10'd314 &&
            hl_y1 == 10'd128 && hl_y2 == 10'd182, "T2 button-1 rect");
        chk(hl_coli === 32'h35400ff0, "T2 SEL colour word");

        // ---- TEST 3: D-pad right: btn1.right=4 -> button 4
        pulse(3);
        $display("T3: sel=%0d rect x%0d..%0d y%0d..%0d", btn_sel, hl_x1, hl_x2, hl_y1, hl_y2);
        chk(btn_sel == 6'd4, "T3 right -> button 4");
        chk(hl_x1 == 10'd414 && hl_x2 == 10'd599, "T3 button-4 rect");

        // ---- TEST 4: activate button 4 -> LinkPGCN 8 cmd + ACT flash
        pulse(4);
        $display("T4: acts=%0d cmd=%016x coli=%08x", acts, last_cmd, hl_coli);
        chk(acts == 1, "T4 one activation pulse");
        chk(last_cmd === 64'h2004000000000008, "T4 cmd = LinkPGCN 8");
        chk(hl_coli === 32'h34500ee0, "T4 ACT colour during the flash");

        // ---- TEST 5: dpad up from 4 -> 7; left from 7 -> 3
        pulse(0);
        chk(btn_sel == 6'd7, "T5 up -> button 7");
        pulse(2);
        chk(btn_sel == 6'd3, "T5 left -> button 3");

        // ---- TEST 6: a later HLI (the 1-button still, s_ptm=7978602) commits
        // to the PENDING slot: with something armed it must NOT apply until
        // the STC reaches its window (the Matrix stream-lead bug), then the
        // out-of-range selection (3 > btn_ns 1) resets to 1.
        feed_pci(2048);
        $display("T6a: pending held: btn_ns=%0d sel=%0d (expect still 7 3)",
                 dbg_btn_ns, btn_sel);
        chk(dbg_btn_ns == 6'd7, "T6a pending NOT applied before its s_ptm");
        chk(btn_sel == 6'd3, "T6a selection untouched while pending");
        stc = 33'd7978700;                      // cross the pending s_ptm
        repeat (120) @(posedge clk);            // promote + refetch
        $display("T6b: btn_ns=%0d sel=%0d rect x%0d..%0d y%0d..%0d",
                 dbg_btn_ns, btn_sel, hl_x1, hl_x2, hl_y1, hl_y2);
        chk(dbg_btn_ns == 6'd1, "T6b promoted at s_ptm");
        chk(btn_sel == 6'd1, "T6b invalid selection reset to 1");
        chk(hl_x1 == 10'd30 && hl_x2 == 10'd57 &&
            hl_y1 == 10'd14 && hl_y2 == 10'd44, "T6b still-HLI rect");

        // ---- TEST 7: FALLBACK promotion (keep_vbuf STC skew). Clean reset, feed
        // the 7-button HLI, but hold STC at 0 so the STC-scheduled path NEVER
        // fires (s_ptm=2579208). With video dead it must stay unarmed; once video
        // goes live and the pending ages past PROMOTE_FALLBACK it must promote so
        // the highlight ALWAYS eventually appears (HW: deep menus, no highlight).
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        video_live = 0; stc = 33'd0;
        feed_pci(0);
        repeat (400) @(posedge clk);            // aged, but video DEAD
        chk(btns_armed === 1'b0, "T7a no fallback while video dead");
        video_live = 1;
        repeat (100) @(posedge clk);            // video live but not yet aged (<300)
        chk(btns_armed === 1'b0, "T7b fallback waits for the age threshold");
        repeat (300) @(posedge clk);            // now aged past 300 with video live
        $display("T7: armed=%b btn_ns=%0d (STC never reached s_ptm)",
                 btns_armed, dbg_btn_ns);
        chk(btns_armed === 1'b1, "T7 fallback promoted with STC stuck below s_ptm");
        chk(dbg_btn_ns == 6'd7, "T7 fallback armed the 7-button HLI");

        // ---- Build a synthetic ss=0 DISARM packet in scratch sector @4096:
        // a copy of the 7-button sector with hli_ss forced to 0 and vobu_s_ptm
        // set small, so it schedules a disarm (off_v) that is immediately "due".
        for (i = 0; i < 2048; i++) nav[4096 + i] = nav[0 + i];
        nav[4096 + OFF_SS]     = 8'h00;                    // hli_ss = 0 -> disarm
        nav[4096 + OFF_VPTM+0] = 8'h00;
        nav[4096 + OFF_VPTM+1] = 8'h00;
        nav[4096 + OFF_VPTM+2] = 8'h01;
        nav[4096 + OFF_VPTM+3] = 8'h00;                    // vobu_s_ptm = 0x100 (256)

        // ---- TEST 8: FOREVER HLI is immune to a stale scheduled disarm (the T2
        // boot "theatrical/special" bug). Arm the 7-button HLI (e_ptm=0xFFFFFFFF),
        // then inject an ss=0 disarm scheduled at 256 while the STC is far past it.
        // Pre-fix: off_due fires and the highlight vanishes. Post-fix: h_forever
        // gates off_due, so the highlight HOLDS (like a real player on a still).
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        stc = 33'd0;
        feed_pci(0);
        stc = 33'd2579300;                                 // cross s_ptm -> arm
        repeat (120) @(posedge clk);
        chk(btns_armed === 1'b1, "T8a forever HLI armed");
        feed_pci(4096);                                    // inject the ss=0 disarm
        repeat (120) @(posedge clk);                       // STC(2579300) >> off(256)
        $display("T8: armed=%b hl_on=%b (forever HLI must survive the stale disarm)",
                 btns_armed, hl_on);
        chk(btns_armed === 1'b1, "T8 forever HLI SURVIVES the scheduled disarm");
        chk(hl_on === 1'b1, "T8 highlight still rendered");

        // ---- TEST 9 (control): a FINITE-e_ptm HLI is STILL disarmable (no
        // regression). Copy the 7-button sector to scratch @6144 with e_ptm set
        // to a finite value, arm it, then apply the same ss=0 disarm -> it must
        // clear (only forever HLIs are immune).
        for (i = 0; i < 2048; i++) nav[6144 + i] = nav[0 + i];
        nav[6144 + OFF_EPTM+0] = 8'h10;
        nav[6144 + OFF_EPTM+1] = 8'h00;
        nav[6144 + OFF_EPTM+2] = 8'h00;
        nav[6144 + OFF_EPTM+3] = 8'h00;                    // e_ptm = 0x10000000 (finite)
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        stc = 33'd0;
        feed_pci(6144);
        stc = 33'd2579300;                                 // past s_ptm, below e_ptm
        repeat (120) @(posedge clk);
        chk(btns_armed === 1'b1, "T9a finite HLI armed");
        feed_pci(4096);                                    // ss=0 disarm, off=256
        repeat (120) @(posedge clk);
        $display("T9: armed=%b (finite HLI must still disarm)", btns_armed);
        chk(btns_armed === 1'b0, "T9 finite HLI disarms on the scheduled ss=0");

        // ---- TEST 10: NUMPAD select+activate. Arm the 7-button HLI (initial
        // selection = button 1), then a numpad "4" must jump the selection to
        // button 4 AND fire its command (LinkPGCN 8) in one press - the DVD-remote
        // digit shortcut. An out-of-range digit (button 10 > btn_ns 7) is ignored.
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        acts = 0;
        stc = 33'd0;
        feed_pci(0);
        stc = 33'd2579300;                                 // cross s_ptm -> arm
        repeat (120) @(posedge clk);
        chk(btns_armed === 1'b1, "T10a armed");
        chk(btn_sel == 6'd1, "T10a initial selection button 1");
        num_press(4);                                      // digit "4"
        $display("T10: sel=%0d acts=%0d cmd=%016x rect x%0d..%0d",
                 btn_sel, acts, last_cmd, hl_x1, hl_x2);
        chk(btn_sel == 6'd4, "T10 digit 4 selects button 4");
        chk(hl_x1 == 10'd414 && hl_x2 == 10'd599, "T10 button-4 rect");
        chk(acts == 1, "T10 digit 4 activated (one pulse)");
        chk(last_cmd === 64'h2004000000000008, "T10 cmd = LinkPGCN 8");
        // out-of-range: button 10 with only 7 buttons -> no move, no activation
        num_press(10);
        $display("T10b: sel=%0d acts=%0d (out-of-range digit ignored)", btn_sel, acts);
        chk(btn_sel == 6'd4, "T10b out-of-range digit leaves selection");
        chk(acts == 1, "T10b out-of-range digit does not activate");

        // ================= Phase-3 spec-hardening: BUTTON GROUPS =================
        // Real T2 2-group fixture: group 1 = wide rects, group 2 = letterbox.
        // Like the MiB fixture, it is NOT tracked (regenerate from the ISO — see
        // the $readmemh comment above); skip T11-15 gracefully when absent.
        if (nav[8192] !== 8'h00 || nav[8195] !== 8'hBA) begin
            $display("NAV_PCI_TB: t2_menu_2grp.hex absent -> T11-15 SKIPPED (regen with tools/nav_extract.py)");
        end else begin
        // ---- TEST 11: arm in wide mode -> group-1 rect (also = old behaviour)
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        disp_wide = 1; disp_mode = 0;
        stc = 33'd0;
        feed_pci(8192);
        stc = 33'd14100;                                   // cross s_ptm=14042
        repeat (120) @(posedge clk);
        $display("T11: armed=%b btn_ns=%0d sel=%0d rect x%0d..%0d y%0d..%0d",
                 btns_armed, dbg_btn_ns, btn_sel, hl_x1, hl_x2, hl_y1, hl_y2);
        chk(btns_armed === 1'b1, "T11 armed");
        chk(dbg_btn_ns == 6'd5, "T11 btn_ns=5");
        chk(btn_sel == 6'd1, "T11 initial selection");
        chk(hl_x1 == 10'd343 && hl_x2 == 10'd655 &&
            hl_y1 == 10'd72  && hl_y2 == 10'd149, "T11 WIDE group-1 btn-1 rect");

        // ---- TEST 12: letterbox mode while armed -> auto refetch, group-2 rect
        disp_mode = 1;
        repeat (80) @(posedge clk);
        $display("T12: sel=%0d rect x%0d..%0d y%0d..%0d", btn_sel, hl_x1, hl_x2, hl_y1, hl_y2);
        chk(btn_sel == 6'd1, "T12 selection persists across the group swap");
        chk(hl_x1 == 10'd343 && hl_x2 == 10'd655 &&
            hl_y1 == 10'd114 && hl_y2 == 10'd172, "T12 LETTERBOX group-2 btn-1 rect");

        // ---- TEST 13: 4:3 content: dsp_ty (1,2) has no 4:3 group -> fallback grp 1
        disp_wide = 0;
        repeat (80) @(posedge clk);
        chk(hl_y1 == 10'd72 && hl_y2 == 10'd149, "T13 4:3 falls back to group 1");

        // ---- TEST 14: back to wide, D-pad down -> button 2, group-1 rect
        disp_wide = 1; disp_mode = 0;
        repeat (80) @(posedge clk);
        pulse(1);                                          // btn1.down = 2
        $display("T14: sel=%0d rect y%0d..%0d", btn_sel, hl_y1, hl_y2);
        chk(btn_sel == 6'd2, "T14 down -> button 2");
        chk(hl_y1 == 10'd154 && hl_y2 == 10'd239, "T14 WIDE group-1 btn-2 rect");

        // ---- TEST 15: letterbox again with button 2 selected -> group-2 btn-2 rect
        disp_mode = 1;
        repeat (80) @(posedge clk);
        $display("T15: sel=%0d rect y%0d..%0d", btn_sel, hl_y1, hl_y2);
        chk(btn_sel == 6'd2, "T15 selection persists");
        chk(hl_y1 == 10'd181 && hl_y2 == 10'd245, "T15 LETTERBOX group-2 btn-2 rect");
        disp_wide = 1; disp_mode = 0;
        end   // t2 fixture present

        if (errors == 0) $display("NAV_PCI_TB: ALL TESTS PASSED");
        else             $display("NAV_PCI_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin #10000000; $display("NAV_PCI_TB: TIMEOUT"); $finish; end
endmodule
`default_nettype wire
