// dvd_vm_tb.sv - unit test for dvd/dvd_vm.sv (the Phase-4 DVD-VM interpreter).
//
// PART 1 - fixture vectors: every case from tools/dvd_vm_ref.py selftest
//   (bench/dvd/test_vobs/vm_selftest_{cmds,expect}.txt, COMMITTED - synthetic,
//   regenerate with `python3 tools/dvd_vm_ref.py selftest --emit`). Each case
//   is loaded as a PRE block and run via pgc_loaded; final GPRM/SPRM state is
//   compared bit-exactly (incl. the rnd LFSR) and the terminating link is
//   checked against the ACTION the RTL must emit (replay/seek/jump/adv).
//
// PART 2 - scenario tests (the vm.c dispatch semantics):
//   [S1] boot: nav_ready rise -> FP jump; FP pre {SetGPRM, JumpTT 4} ->
//        TT jump with jump_ttn=4 and SPRM4=4 (the BBB boot shape).
//   [S2] menu key in a title -> VTSM Root jump + RSM saved; the menu's
//        0-cell root stub pre LinkPGCN 2 -> chained jump pgcn=2 (MiB shape).
//   [S3] menu key in the menu -> RSM resume jump back to the saved
//        {vts,pgcn,cell} AND the next pgc_loaded does NOT run pre commands
//        (skip_pre - a poisoned pre table proves it).
//   [S4] cell command LinkTopC -> vm_replay (the menu loop, no flush).
//   [S5] pgc end -> POST block runs; post JumpSS VMGM menu -> VMGM jump.
//   [S6] post falls through -> vm_adv (authored next_pgcn policy).
//   [S7] fallback chain: menu jump errors walk own-VTSM -> best_menu_vts
//        VTSM -> VMGM Title -> RSM resume.
//   [S8] SetSTN -> sprm_astn/sprm_spstn outputs (the emu track mux source).
//   [S9] button activate: SetGPRM g14 + LinkTailPGC (MiB Play shape) ->
//        POST block runs -> its JumpSS lands (g14 checked via the dispatch).
//   [S10] CallSS_VTSM stays in the current VTS (white-rabbit boot regression).
//   [S11] HL_BTNN durable latch: activate button 2, dispatch PRE reads
//         `g15 = HL_BTNN` after menu teardown -> must resolve button 2, not the
//         reset default (TP Star Wars / Atmosfear "always option 1" fix).
//   [S12] LinkTailPGC dispatch with the menu STILL armed: activate button 2,
//         btn_sel drifts to 1 (re-arm) -> the POST's `g0 = HL_BTNN` must still
//         resolve button 2 (sprm8_frozen fix; Atmosfear menu selection).
//   [S15] tail-drain Phase B provenance (vm_from_wait): 1 on a CELL-command
//         jump/seek and on a POST jump; 0 on button/PRE jumps and - the
//         stale-blk fix - on a Menu-key jump issued AFTER a prior CELL
//         dispatch left blk=BLK_CELL (the V_IDLE event arms force BLK_BTN).
//   [S16] key_resume gated on came_via_menukey: Select with no buttons in a
//         DISC-driven menu (RSM filled by the disc's own CallSS) is a no-op
//         (Cluedo intro -> "Please Wait" park); the user Menu->Select toggle
//         still resumes.
//   [S17] key_title (B12 "Top Menu"): VMGM Title (entry 2) jump; from a title
//         saves RSM + sets came_via_menukey (Select resumes back); from a
//         disc-driven menu jumps WITHOUT touching RSM/toggle (the boot-stub
//         RSM must not be re-blessed).
//   [S18] key_return (B13 "Return"): GoUp = in-domain jump to the loaded
//         PGC's authored goup_pgcn (dvdnav_go_up); goup==0 = strict no-op.
//
// Run: iverilog -g2012 -o /tmp/vmtb dvd/dvd_vm.sv bench/dvd/dvd_vm_tb.sv && vvp /tmp/vmtb

`timescale 1ns/1ps

module dvd_vm_tb;

    reg clk = 0;
    always #18.5 clk = ~clk;      // ~27 MHz

    reg rst_n  = 0;
    reg enable = 1;
    reg start  = 0;
    reg nav_ready = 0;
    reg [7:0] auto_vts = 8'd5;
    reg [7:0] best_menu_vts = 8'd2;

    reg        cmd_we = 0;
    reg [11:0] cmd_waddr = 0;
    reg [7:0]  cmd_wdata = 0;
    reg [7:0]  nr_pre = 0, nr_post = 0, nr_cell = 0;
    reg        pm_we = 0;
    reg [6:0]  pm_waddr = 0;
    reg [7:0]  pm_wdata = 0;
    reg [7:0]  nr_pgms = 0;

    reg        pgc_loaded = 0, pgc_error = 0;
    reg        vm_cell_cmd = 0;
    reg [7:0]  cell_cmd_nr = 0;
    reg        vm_pgc_end = 0;
    reg        menu_active = 0;
    reg [7:0]  cur_vts = 8'd5, cur_cell = 8'd0;
    reg [15:0] cur_pgcn = 16'd1;
    reg [7:0]  cell_count = 8'd3;
    reg [15:0] next_pgcn = 0, prev_pgcn = 0, goup_pgcn = 0;

    reg        key_menu = 0, key_resume = 0, key_title = 0, key_return = 0;
    reg [63:0] btn_cmd = 0;
    reg        btn_cmd_valid = 0;
    reg [5:0]  btn_sel = 6'd1;
    reg        btns_armed = 0;

    wire        btn_force;
    wire [5:0]  btn_force_val;
    reg  [6:0]  cap_jttn;      // declared before the DUT: feeds res_ttn
    wire        jump_pulse;
    wire [1:0]  jump_domain;
    wire [7:0]  jump_vts, jump_cell, jump_pgn;
    wire [15:0] jump_pgcn;
    wire [3:0]  jump_entry;
    wire [6:0]  jump_ttn;
    wire        seek_pulse;
    wire [7:0]  seek_cell;
    wire        vm_replay, vm_adv;
    wire        vm_from_wait;             // Phase B natural-jump provenance
    wire [7:0]  sprm_astn, sprm_spstn;
    wire [7:0]  dbg_state;

    // DVD-game entropy inputs. Existing vectors drive the fixed 0xACE1 seed
    // and no ticks/stir -> bit-exact with the pre-entropy behaviour. PART 3
    // exercises sec_tick / rnd_seed / entropy_stir.
    reg [15:0] rnd_seed  = 16'hACE1;
    reg        sec_tick  = 1'b0;
    reg        ent_stir  = 1'b0;
    reg [15:0] ent_val   = 16'd0;

    dvd_vm dut (
        .clk(clk), .rst_n(rst_n), .enable(enable), .start(start), .cfg_lang(16'h656E),
        .rnd_seed(rnd_seed), .sec_tick(sec_tick),
        .entropy_stir(ent_stir), .entropy_val(ent_val),
        .nav_ready(nav_ready), .auto_vts(auto_vts),
        .best_menu_vts(best_menu_vts),
        .res_ttn(cap_jttn),   // "resolved" ttn = the requested one (tb model)
        .cmd_we(cmd_we), .cmd_waddr(cmd_waddr), .cmd_wdata(cmd_wdata),
        .nr_pre(nr_pre), .nr_post(nr_post), .nr_cell(nr_cell),
        .pm_we(pm_we), .pm_waddr(pm_waddr), .pm_wdata(pm_wdata),
        .nr_pgms(nr_pgms),
        .pgc_loaded(pgc_loaded), .pgc_error(pgc_error),
        .vm_cell_cmd(vm_cell_cmd), .cell_cmd_nr(cell_cmd_nr),
        .vm_pgc_end(vm_pgc_end), .menu_active(menu_active),
        .cur_vts(cur_vts), .cur_pgcn(cur_pgcn), .cur_cell(cur_cell),
        .cell_count(cell_count),
        .next_pgcn(next_pgcn), .prev_pgcn(prev_pgcn), .goup_pgcn(goup_pgcn),
        .key_menu(key_menu), .key_resume(key_resume), .key_title(key_title), .key_return(key_return),
        .btn_cmd(btn_cmd), .btn_cmd_valid(btn_cmd_valid),
        .btn_sel(btn_sel), .btns_armed(btns_armed),
        .btn_force(btn_force), .btn_force_val(btn_force_val),
        .jump_pulse(jump_pulse), .jump_domain(jump_domain),
        .jump_vts(jump_vts), .jump_pgcn(jump_pgcn), .jump_entry(jump_entry),
        .jump_ttn(jump_ttn), .jump_pgn(jump_pgn), .jump_cell(jump_cell),
        .seek_pulse(seek_pulse), .seek_cell(seek_cell),
        .vm_replay(vm_replay), .vm_adv(vm_adv), .wait_hold(1'b0),
        .vm_from_wait(vm_from_wait),
        .sprm_astn(sprm_astn), .sprm_spstn(sprm_spstn),
        .dbg_state(dbg_state)
    );

    integer errors = 0;
    integer n_cases = 0;

    // ---- action capture (latched between clear_actions() calls) ----------
    reg        saw_jump, saw_seek, saw_replay, saw_adv, saw_btnf;
    reg [1:0]  cap_jdom;
    reg [7:0]  cap_jvts, cap_jcell, cap_jpgn;
    reg [15:0] cap_jpgcn;
    reg [3:0]  cap_jentry;
    reg [7:0]  cap_scell;
    reg [5:0]  cap_btnf;
    reg        cap_natural, cap_snat;   // vm_from_wait sampled on the pulse cycle
    always @(posedge clk) begin
        if (jump_pulse) begin
            saw_jump  <= 1'b1;
            cap_jdom  <= jump_domain;  cap_jvts  <= jump_vts;
            cap_jpgcn <= jump_pgcn;    cap_jentry<= jump_entry;
            cap_jttn  <= jump_ttn;     cap_jpgn  <= jump_pgn;
            cap_jcell <= jump_cell;
            cap_natural <= vm_from_wait;
        end
        if (seek_pulse) begin
            saw_seek <= 1'b1; cap_scell <= seek_cell;
            cap_snat <= vm_from_wait;
        end
        if (vm_replay)  saw_replay <= 1'b1;
        if (vm_adv)     saw_adv    <= 1'b1;
        if (btn_force)  begin saw_btnf <= 1'b1; cap_btnf <= btn_force_val; end
    end

    task clear_actions;
    begin
        @(negedge clk);
        saw_jump = 0; saw_seek = 0; saw_replay = 0; saw_adv = 0; saw_btnf = 0;
        cap_jdom = 0; cap_jvts = 0; cap_jpgcn = 0; cap_jcell = 0; cap_jpgn = 0;
        cap_jentry = 0; cap_jttn = 0; cap_scell = 0; cap_btnf = 0;
        cap_natural = 1'bx; cap_snat = 1'bx;
    end
    endtask

    task fail(input [511:0] msg);
    begin
        $display("FAIL: %0s", msg);
        errors = errors + 1;
    end
    endtask

    // ---- helpers ----------------------------------------------------------
    // write one 8-byte command into the cmd BRAM at command index idx
    task wr_cmd(input [7:0] idx, input [63:0] c);
        integer b;
    begin
        for (b = 0; b < 8; b = b + 1) begin
            @(negedge clk);
            cmd_we    = 1;
            cmd_waddr = {idx, 3'b000} + b[10:0];
            cmd_wdata = c[63 - b*8 -: 8];
        end
        @(negedge clk);
        cmd_we = 0;
    end
    endtask

    // write one program-map entry (pm[idx] = 1-based entry cell of program idx+1)
    task wr_pm(input [6:0] idx, input [7:0] v);
    begin
        @(negedge clk); pm_we = 1; pm_waddr = idx; pm_wdata = v;
        @(negedge clk); pm_we = 0;
    end
    endtask

    task pulse_loaded;
    begin
        @(negedge clk); pgc_loaded = 1;
        @(negedge clk); pgc_loaded = 0;
    end
    endtask

    task pulse_error;
    begin
        @(negedge clk); pgc_error = 1;
        @(negedge clk); pgc_error = 0;
    end
    endtask

    // any event latched but not yet consumed = the VM is still busy
    wire vm_pending = dut.ev_boot | dut.ev_loaded | dut.ev_error |
                      dut.ev_cellcmd | dut.ev_pgcend | dut.ev_btn |
                      dut.ev_menu | dut.ev_resume;

    // wait for the VM to return to V_IDLE with nothing pending
    task wait_idle;
        integer t;
    begin
        repeat (4) @(negedge clk);   // let a just-pulsed event get latched
        t = 0;
        // dbg_state[3:0] = state; V_IDLE = 0, V_WAIT = 10
        while ((dbg_state[3:0] != 4'd0 || vm_pending) && t < 200000) begin
            @(negedge clk);
            t = t + 1;
        end
        if (t >= 200000) fail("wait_idle timeout");
        repeat (4) @(negedge clk);
    end
    endtask

    // wait until the VM is either settled idle or parked in V_WAIT (jump out)
    task wait_settled;
        integer t;
    begin
        repeat (4) @(negedge clk);
        t = 0;
        while (((dbg_state[3:0] != 4'd0 && dbg_state[3:0] != 4'd10) ||
                (dbg_state[3:0] == 4'd0 && vm_pending)) && t < 200000) begin
            @(negedge clk);
            t = t + 1;
        end
        if (t >= 200000) fail("wait_settled timeout");
        repeat (4) @(negedge clk);
    end
    endtask

    // reset the whole VM between fixture cases (fresh registers)
    task vm_restart;
    begin
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        repeat (2) @(negedge clk);
    end
    endtask

    // ========================================================================
    // PART 1: fixture vectors
    // ========================================================================
    integer fh_c, fh_e, rc;
    reg [8*32-1:0]  cname, ename;
    integer         cn;
    reg [15:0]      g9init;
    reg [63:0]      cmds [0:7];
    reg [15:0]      e_g3, e_g4, e_g5, e_g9, e_s1, e_s2, e_s8;
    reg [8*24-1:0]  e_link;
    integer         e_d1, e_d2, e_d3;
    integer         ci;
    reg [1023:0]    line_c;

    task run_fixture_case;
        integer i;
    begin
        n_cases = n_cases + 1;
        vm_restart;
        // preload g9 (the only setup the selftest uses)
        dut.gprm[9] = g9init;
        // load as a PRE block
        for (i = 0; i < cn; i = i + 1) wr_cmd(i[7:0], cmds[i]);
        nr_pre = cn[7:0]; nr_post = 0; nr_cell = 0;
        cell_count = 8'd3;           // nonzero: pre fall-through = play
        clear_actions;
        pulse_loaded;
        wait_settled;

        // register state must match the golden model bit-exactly
        if (dut.gprm[3] !== e_g3) begin fail(cname); $display("  g3=%04x exp %04x", dut.gprm[3], e_g3); end
        if (dut.gprm[4] !== e_g4) begin fail(cname); $display("  g4=%04x exp %04x", dut.gprm[4], e_g4); end
        if (dut.gprm[5] !== e_g5) begin fail(cname); $display("  g5=%04x exp %04x", dut.gprm[5], e_g5); end
        if (dut.gprm[9] !== e_g9) begin fail(cname); $display("  g9=%04x exp %04x", dut.gprm[9], e_g9); end
        if ({8'd0, sprm_astn}  !== e_s1) begin fail(cname); $display("  sprm1=%02x exp %04x", sprm_astn, e_s1); end
        if ({8'd0, sprm_spstn} !== e_s2) begin fail(cname); $display("  sprm2=%02x exp %04x", sprm_spstn, e_s2); end
        // sprm8: the golden fixture is eval-level (no dispatch), but the RTL
        // dispatch applies a link's button field to SPRM8 - skip the check
        // when the expected link carries a button.
        if (!(e_link == "LinkTopC" && e_d1 != 0) &&
            dut.sprm8 !== e_s8) begin fail(cname); $display("  sprm8=%04x exp %04x", dut.sprm8, e_s8); end

        // terminating link -> expected RTL action
        if (e_link == "None") begin
            if (saw_jump || saw_seek || saw_replay)
                begin fail(cname); $display("  unexpected action (link=None)"); end
        end else if (e_link == "LinkTopC") begin
            if (!saw_replay) begin fail(cname); $display("  expected vm_replay"); end
            if (e_d1 != 0 && (!saw_btnf || cap_btnf != e_d1[5:0]))
                begin fail(cname); $display("  expected btn_force %0d", e_d1); end
        end else if (e_link == "LinkTailPGC") begin
            // fixture blocks have nr_post=0 -> authored policy = vm_adv
            if (!saw_adv) begin fail(cname); $display("  expected vm_adv (TailPGC, no post)"); end
        end else if (e_link == "LinkPGCN") begin
            if (!saw_jump || cap_jpgcn != e_d1[15:0])
                begin fail(cname); $display("  expected jump pgcn=%0d got %0d (saw=%0d)", e_d1, cap_jpgcn, saw_jump); end
        end else if (e_link == "JumpTT") begin
            if (!saw_jump || cap_jdom != 2'd3 || {25'd0, cap_jttn} != e_d1)
                begin fail(cname); $display("  expected TT jump ttn=%0d", e_d1); end
            if (dut.sprm4 != e_d1[15:0]) begin fail(cname); $display("  SPRM4 != ttn"); end
        end else if (e_link == "JumpSS_VTSM") begin
            if (!saw_jump || cap_jdom != 2'd2 || cap_jvts != e_d1[7:0] ||
                cap_jentry != e_d3[3:0])
                begin fail(cname); $display("  expected VTSM jump vts=%0d menu=%0d", e_d1, e_d3); end
            if (dut.sprm5 != e_d2[15:0]) begin fail(cname); $display("  SPRM5 != title"); end
        end else if (e_link == "CallSS_VTSM") begin
            if (!saw_jump || cap_jdom != 2'd2 || cap_jentry != e_d1[3:0])
                begin fail(cname); $display("  expected CallSS VTSM menu=%0d", e_d1); end
            // rsm_cell field d2 (1-based) -> saved cell d2-1
            if (e_d2 != 0 && dut.rsm_cell != (e_d2[7:0] - 8'd1))
                begin fail(cname); $display("  rsm_cell=%0d exp %0d", dut.rsm_cell, e_d2-1); end
        end else begin
            $display("NOTE: no action mapping for link %0s (case %0s) - state-only check", e_link, cname);
        end
        // release a V_WAIT (the fixture jumps get answered so the next case
        // starts clean; skip pre: nr_pre=0)
        if (dbg_state[3:0] == 4'd10) begin
            nr_pre = 0;
            pulse_loaded;
            wait_idle;
        end
        nr_pre = 0;
    end
    endtask

    task part1;
        integer i;
        reg [63:0] cw;
        reg [1023:0] hexs;
        integer nb;
    begin
        fh_c = $fopen("bench/dvd/test_vobs/vm_selftest_cmds.txt", "r");
        fh_e = $fopen("bench/dvd/test_vobs/vm_selftest_expect.txt", "r");
        if (fh_c == 0 || fh_e == 0) begin
            $display("NOTE: vm_selftest fixtures missing - regenerate with");
            $display("      python3 tools/dvd_vm_ref.py selftest --emit");
            fail("fixtures missing");
        end else begin
            while (!$feof(fh_c)) begin
                rc = $fscanf(fh_c, "%s %d %h", cname, cn, g9init);
                if (rc == 3) begin
                    for (i = 0; i < cn; i = i + 1) begin
                        rc = $fscanf(fh_c, "%s", hexs);
                        cw = 64'd0;
                        for (nb = 0; nb < 16; nb = nb + 1)
                            cw = (cw << 4) | hex_nib(hexs[8*(16-nb)-1 -: 8]);
                        cmds[i] = cw;
                    end
                    rc = $fscanf(fh_e, "%s %h %h %h %h %h %h %h %s %d %d %d",
                                 ename, e_g3, e_g4, e_g5, e_g9, e_s1, e_s2,
                                 e_s8, e_link, e_d1, e_d2, e_d3);
                    if (rc != 12) begin
                        fail("expect-file parse");
                    end else if (cname != ename) begin
                        fail("fixture name mismatch");
                    end else begin
                        run_fixture_case;
                    end
                end
            end
            $fclose(fh_c);
            $fclose(fh_e);
        end
    end
    endtask

    function [3:0] hex_nib(input [7:0] ch);
        if (ch >= "0" && ch <= "9")      hex_nib = ch - "0";
        else if (ch >= "a" && ch <= "f") hex_nib = ch - "a" + 10;
        else if (ch >= "A" && ch <= "F") hex_nib = ch - "A" + 10;
        else                             hex_nib = 4'd0;
    endfunction

    // ========================================================================
    // PART 2: scenario tests
    // ========================================================================
    task part2;
    begin
        // ---------------- [S1] BOOT: FP -> JumpTT 4 -------------------------
        vm_restart;
        clear_actions;
        @(negedge clk); nav_ready = 1;
        wait_settled;
        if (!saw_jump || cap_jdom != 2'd0)
            fail("S1: expected FP jump on nav_ready");
        // reader answers: FP PGC with pre = {g14 = 0x3500; JumpTT 4}
        wr_cmd(0, 64'h71_00_0E_35_00_00_00_00);  // hmm: type3 mov g14? see below
        // type 3 mov: 71 00 00 0E 35 00 00 00 = g[14] = 0x3500
        wr_cmd(0, 64'h7100000E35000000);
        wr_cmd(1, 64'h3002000000040000);         // JumpTT 4
        nr_pre = 2; nr_post = 0; nr_cell = 0;
        cell_count = 0;                          // FP: no cells
        clear_actions;
        pulse_loaded;
        wait_settled;
        if (!saw_jump || cap_jdom != 2'd3 || cap_jttn != 7'd4)
            fail("S2: expected TT jump ttn=4 from FP pre");
        if (dut.gprm[14] !== 16'h3500) fail("S1: g14 != 0x3500");
        if (dut.sprm4 !== 16'd4) fail("S1: SPRM4 != 4");
        // reader answers: the title loaded (no pre), 3 cells
        nr_pre = 0; cell_count = 8'd3;
        cur_vts = 8'd4; cur_pgcn = 8'd1; cur_cell = 8'd0;
        pulse_loaded;
        wait_idle;
        $display("S1 boot chain PASS");

        // ---------------- [S2] MENU KEY in a title --------------------------
        menu_active = 0;
        cur_vts = 8'd4; cur_pgcn = 8'd1; cur_cell = 8'd2;
        clear_actions;
        @(negedge clk); key_menu = 1;
        @(negedge clk); key_menu = 0;
        wait_settled;
        if (!saw_jump || cap_jdom != 2'd2 || cap_jvts != 8'd4 ||
            cap_jentry != 4'd3)
            fail("S2: expected VTSM Root jump");
        if (dut.rsm_vts !== 8'd4 || dut.rsm_cell !== 8'd2)
            fail("S2: RSM not saved");
        // reader answers: 0-cell root stub, pre = LinkPGCN 2
        wr_cmd(0, 64'h2004000000000002);         // LinkPGCN 2
        nr_pre = 1; cell_count = 0;
        menu_active = 1;
        clear_actions;
        pulse_loaded;
        wait_settled;
        if (!saw_jump || cap_jpgcn != 8'd2 || cap_jdom != 2'd2)
            fail("S2: expected chained LinkPGCN 2 jump");
        // reader answers: the real menu PGC (2 cells, no pre)
        nr_pre = 0; cell_count = 8'd2;
        cur_pgcn = 8'd2; cur_cell = 8'd0;
        pulse_loaded;
        wait_idle;
        $display("S2 menu-key chain PASS");

        // ---------------- [S3] MENU KEY in the menu -> RSM ------------------
        clear_actions;
        @(negedge clk); key_menu = 1;
        @(negedge clk); key_menu = 0;
        wait_settled;
        if (!saw_jump || cap_jdom != 2'd3 || cap_jvts != 8'd4 ||
            cap_jpgcn != 8'd1 || cap_jcell != 8'd2)
            fail("S3: expected RSM resume jump to vts4/pgcn1/cell2");
        // POISONED pre table: if skip_pre fails this would jump to PGC 99
        wr_cmd(0, 64'h2004000000000063);         // LinkPGCN 99
        nr_pre = 1; cell_count = 8'd3;
        menu_active = 0;
        cur_vts = 8'd4; cur_pgcn = 8'd1; cur_cell = 8'd2;
        clear_actions;
        pulse_loaded;
        wait_idle;
        if (saw_jump) fail("S3: resume ran PRE commands (skip_pre broken)");
        $display("S3 RSM resume (pre skipped) PASS");

        // ---------------- [S4] cell command LinkTopC -> vm_replay -----------
        // cell cmds live after pre+post: nr_pre=0, nr_post=0, cell cmd 1 @0
        wr_cmd(0, 64'h2001000000000001);         // LinkTopC (button 0)
        nr_pre = 0; nr_post = 0; nr_cell = 1;
        clear_actions;
        @(negedge clk); vm_cell_cmd = 1; cell_cmd_nr = 8'd1;
        @(negedge clk); vm_cell_cmd = 0;
        wait_idle;
        if (!saw_replay) fail("S4: expected vm_replay from LinkTopC cell cmd");
        if (saw_seek || saw_jump) fail("S4: unexpected seek/jump");
        $display("S4 cell-cmd replay PASS");

        // ---------------- [S4b] MiB root-menu loop: LinkTopPG / LinkPGN -----
        // The MiB root menu (VTSM PGCN 5, program map [1..6]) loops its montage:
        // cell 1's cell-cmd = LinkPGN 3 (-> seek to program 3 = cell 2), cell 2's
        // cell-cmd = LinkTopPG (-> restart the CURRENT program = replay cell 2).
        // Both resolve through the program-map walk (V_PGSCAN/V_PMRD), which S4's
        // LinkTopC does NOT exercise. nr_pgms=6 (> the current program) is what
        // triggers the V_PGSCAN off-by-one bug: pmem_q is a registered read, so
        // pg_hit used to compare pm[pg_i-1] and over-counted cur_pg, making
        // LinkTopPG SEEK to cell 3 instead of replaying cell 2 (MiB montage ->
        // parks on the still -> black). Must be vm_replay. (With the pre-fix code
        // and nr_pgms<=current-program the stale value happened to be correct, so
        // this MUST use nr_pgms>cur-program to catch the regression.)
        wr_pm(0, 8'd1); wr_pm(1, 8'd2); wr_pm(2, 8'd3);
        wr_pm(3, 8'd4); wr_pm(4, 8'd5); wr_pm(5, 8'd6);   // pm[p] = cell p (1-based)
        nr_pgms = 8'd6;
        // LinkTopPG at cell 2 (= program 3's first cell) -> vm_replay
        wr_cmd(0, 64'h2001000000000005);         // LinkTopPG
        nr_pre = 0; nr_post = 0; nr_cell = 1; cur_cell = 8'd2; cell_count = 8'd8;
        clear_actions;
        @(negedge clk); vm_cell_cmd = 1; cell_cmd_nr = 8'd1;
        @(negedge clk); vm_cell_cmd = 0;
        wait_idle;
        if (!saw_replay) fail("S4b: LinkTopPG@cell2 expected vm_replay (loop)");
        if (saw_seek || saw_jump) fail("S4b: LinkTopPG unexpected seek/jump");
        // LinkPGN 3 at cell 1 -> seek to program 3's first cell (cell 2)
        wr_cmd(0, 64'h2006000000000003);         // LinkPGN 3
        nr_pre = 0; nr_post = 0; nr_cell = 1; cur_cell = 8'd1; cell_count = 8'd8;
        clear_actions;
        @(negedge clk); vm_cell_cmd = 1; cell_cmd_nr = 8'd1;
        @(negedge clk); vm_cell_cmd = 0;
        wait_idle;
        if (!saw_seek || cap_scell != 8'd2) fail("S4b: LinkPGN 3@cell1 expected seek to cell 2");
        if (saw_replay || saw_jump) fail("S4b: LinkPGN 3 unexpected replay/jump");
        nr_pgms = 8'd0;                          // restore for later cases
        $display("S4b MiB montage loop (LinkTopPG replay / LinkPGN seek) PASS");

        // ---------------- [S5] pgc end -> POST JumpSS VMGM menu -------------
        wr_cmd(0, 64'h7100000411110000);         // pre[0] g4=0x1111 (not run)
        wr_cmd(1, 64'h30060000000C0000);
        // ^ type1 jump op6 dom=? bits23:22: byte5=0x0C ->'b00001100: bits23:22=11?
        // byte5 bits are ins[23:16]=0x0C -> ins[23:22]=2'b00 -> FP. Want VMGM
        // menu (dom=1, menu=2): ins[23:22]=01, ins[19:16]=2 -> byte5=0x42.
        wr_cmd(1, 64'h3006000000420000);         // JumpSS VMGM (menu 2)
        nr_pre = 1; nr_post = 1; nr_cell = 0;
        clear_actions;
        @(negedge clk); vm_pgc_end = 1;
        @(negedge clk); vm_pgc_end = 0;
        wait_settled;
        if (!saw_jump || cap_jdom != 2'd1 || cap_jentry != 4'd2)
            fail("S5: expected VMGM menu-2 jump from POST");
        if (dut.gprm[4] === 16'h1111) fail("S5: PRE ran instead of POST");
        nr_pre = 0; cell_count = 8'd2;
        pulse_loaded;
        wait_idle;
        $display("S5 post-command jump PASS");

        // ---------------- [S6] post falls through -> vm_adv -----------------
        wr_cmd(0, 64'h7100000400010000);         // post[0]: g4 = 1 (no link)
        nr_pre = 0; nr_post = 1; nr_cell = 0;
        clear_actions;
        @(negedge clk); vm_pgc_end = 1;
        @(negedge clk); vm_pgc_end = 0;
        wait_idle;
        if (!saw_adv) fail("S6: expected vm_adv on post fall-through");
        if (saw_jump) fail("S6: unexpected jump");
        if (dut.gprm[4] !== 16'd1) fail("S6: post did not execute");
        $display("S6 post fall-through PASS");

        // ---------------- [S7] fallback chain -------------------------------
        // S5 left vm_dom = VMGM. Use the dedicated Resume key (key_resume) to get
        // back to the title domain first (also re-checks resume from VMGM). NB
        // BOTH the Menu key and the Resume key are gated on came_via_menukey
        // (the toggle is covered by S2/S3; TP-Star-Wars "no toggle -> re-invoke
        // Root" is S13; the Cluedo "Select in a disc-driven menu = no-op" case
        // is S16) -- force the toggle flag here so the resume goes through.
        dut.came_via_menukey = 1'b1;
        menu_active = 0;
        clear_actions;
        @(negedge clk); key_resume = 1;
        @(negedge clk); key_resume = 0;
        wait_settled;
        if (!saw_jump || cap_jdom != 2'd3)
            fail("S7-pre: expected resume-to-title from the VMGM domain");
        nr_pre = 0; cell_count = 8'd8;
        pulse_loaded;
        wait_idle;
        // now press Menu from the title (fresh resume point)
        cur_vts = 8'd7; cur_pgcn = 8'd3; cur_cell = 8'd5;
        clear_actions;
        @(negedge clk); key_menu = 1;
        @(negedge clk); key_menu = 0;
        wait_settled;
        if (!saw_jump || cap_jdom != 2'd2 || cap_jvts != 8'd7)
            fail("S7: expected own-VTSM jump");
        clear_actions; pulse_error; wait_settled;
        if (!saw_jump || cap_jdom != 2'd2 || cap_jvts != best_menu_vts ||
            cap_jentry != 4'd3)
            fail("S7: expected best_menu_vts VTSM fallback");
        clear_actions; pulse_error; wait_settled;
        if (!saw_jump || cap_jdom != 2'd1 || cap_jentry != 4'd2)
            fail("S7: expected VMGM Title fallback");
        clear_actions; pulse_error; wait_settled;
        if (!saw_jump || cap_jdom != 2'd3 || cap_jvts != 8'd7 ||
            cap_jpgcn != 8'd3 || cap_jcell != 8'd5)
            fail("S7: expected RSM resume fallback");
        nr_pre = 0; cell_count = 8'd8;
        pulse_loaded;
        wait_idle;
        $display("S7 fallback chain PASS");

        // ---------------- [S8] SetSTN -> stream-select outputs --------------
        wr_cmd(0, 64'h51000083C1810000);         // SetSTN a=3 sp=0x41 ang=1
        nr_pre = 1; nr_post = 0; nr_cell = 0;
        cell_count = 8'd3;
        clear_actions;
        pulse_loaded;
        wait_idle;
        if (sprm_astn !== 8'd3)    fail("S8: sprm_astn != 3");
        if (sprm_spstn !== 8'h41)  fail("S8: sprm_spstn != 0x41");
        $display("S8 SetSTN PASS");

        // ---------------- [S9] button: SetGPRM + LinkTailPGC (MiB Play) -----
        // post block dispatches on g14: if (g14 == 0xABCD) JumpSS VMGM pgc 1
        // button: type 4 set: g14 = 0xABCD ALWAYS, if (g14==0xABCD) LinkTailPGC
        // build: byte0 = 100 1 0001 = 0x91 (type4, imm, mov)
        //        byte1 = 1 010 1110 = 0xAE (cmp-imm, op2 ==, reg=14)
        //        bytes2-3 = set imm 0xABCD; bytes4-5 = cmp imm 0xABCD
        //        byte6 = btn 0; byte7 = 0x0D LinkTailPGC
        menu_active = 1;
        wr_cmd(0, 64'h7100000400020000);         // post[0]: g4 = 2 (marker)
        // post[1]: if (g14 == 0xABCD) JumpSS VMGM pgc 1:
        //   type1 jump: byte0=0x30|imm? jumps need bit60=1 -> 0x30. compare
        //   if_v2 compares regs; simpler: unconditional JumpSS VMGM pgc 1.
        wr_cmd(1, 64'h30060000_01_C0_0000 | 64'h0);
        // JumpSS VMGM pgc: op6, ins[23:22]=3 -> byte5[7:6]=11, pgc@ins[46:32]
        //   byte3..4 = pgc (15b): pgc 1 -> byte4=0x01; byte5=0xC0
        wr_cmd(1, 64'h3006000001C00000);
        nr_pre = 0; nr_post = 2; nr_cell = 0;
        clear_actions;
        @(negedge clk);
        btn_cmd = 64'h91AEABCDABCD000D;          // g14=0xABCD, LinkTailPGC
        btn_cmd_valid = 1;
        @(negedge clk); btn_cmd_valid = 0;
        wait_settled;
        if (dut.gprm[14] !== 16'hABCD) fail("S9: button set g14 failed");
        if (dut.gprm[4]  !== 16'd2)    fail("S9: TailPGC did not run POST");
        if (!saw_jump || cap_jdom != 2'd1 || cap_jpgcn != 8'd1)
            fail("S9: expected VMGM pgc-1 jump from POST after TailPGC");
        nr_pre = 0; nr_post = 0; cell_count = 8'd2;
        pulse_loaded;
        wait_idle;
        $display("S9 button TailPGC dispatch PASS");

        // ---------------- [S10] CallSS_VTSM stays in the current VTS --------
        // Matrix "Follow the White Rabbit" BOOT regression. The bumper title's
        // POST runs `CallSS VTSM (menu=3, rsm_cell=1)`. The shared JumpSS/CallSS
        // VTSM handler used to apply JumpSS_VTSM's field layout to CallSS too,
        // reading the rsm_cell byte (ins[31:24]=1) as a TARGET VTS -> jump to
        // VTS 1, whose VTSM Root is a command stub that trampolines JumpSS VMGM
        // PGC19 -> JumpTT 6 -> the rabbit branch PGCN 6, so the rabbit played
        // the whole movie. Correct (libdvdnav): CallSS_VTSM has NO vts field ->
        // STAY in the current VTS (2) and open menu 3. This asserts cap_jvts,
        // which the fixture CallSS_VTSM check never covered (how the bug slipped).
        vm_restart;
        clear_actions;
        @(negedge clk); nav_ready = 1;
        wait_settled;                              // FP jump (DOM_FP)
        wr_cmd(0, 64'h3002000000020000);           // FP pre: JumpTT 2 (bumper title)
        nr_pre = 1; nr_post = 0; nr_cell = 0; cell_count = 0;
        clear_actions; pulse_loaded; wait_settled;
        if (!saw_jump || cap_jdom != 2'd3 || cap_jttn != 7'd2)
            fail("S10: expected FP JumpTT 2");
        // reader answers: bumper loaded in VTS 2, 1 cell, POST = CallSS VTSM
        wr_cmd(0, 64'h3008000001830000);           // POST[0]: CallSS VTSM menu=3, rsm_cell=1
        nr_pre = 0; nr_post = 1; nr_cell = 0; cell_count = 8'd1;
        cur_vts = 8'd2; cur_pgcn = 8'd2; cur_cell = 8'd0;
        pulse_loaded; wait_idle;                   // bumper plays out
        clear_actions;
        @(negedge clk); vm_pgc_end = 1;            // bumper end -> run POST
        @(negedge clk); vm_pgc_end = 0;
        wait_settled;
        if (!saw_jump || cap_jdom != 2'd2 || cap_jentry != 4'd3)
            fail("S10: CallSS_VTSM expected VTSM menu-3 jump");
        if (cap_jvts != 8'd2) begin
            fail("S10: CallSS_VTSM must STAY in VTS 2 (rsm_cell mis-read as VTS)");
            $display("      cap_jvts=%0d expected 2", cap_jvts);
        end
        if (dut.rsm_vts !== 8'd2)
            fail("S10: CallSS_VTSM resume (vts=2) not saved");
        $display("S10 CallSS_VTSM stay-in-VTS (white-rabbit boot) PASS");

        // ---------------- [S11] HL_BTNN durable latch across menu teardown ---
        // Trivial Pursuit Star Wars / Atmosfear game-menu shape: every button
        // carries the SAME link (here LinkPGCN 2) - the SELECTION is read by the
        // TARGET PGC's PRE via `g[15] = HL_BTNN; if (g[15]==0x400) ...`. That PRE
        // runs AFTER the menu tears down (btns_armed low), so SPRM8 must have been
        // DURABLY latched at activation; otherwise it reads the reset default
        // 0x0400 (button 1) and every selection collapses to option 1 (the HW
        // symptom). Real encodings extracted from TP_SW VTS_01 PGCN2.
        vm_restart;                                // sprm8 = reset default 0x0400
        menu_active = 1;
        // activate BUTTON 2 while armed; its command jumps to the dispatch PGC.
        btns_armed = 1; btn_sel = 6'd2;
        clear_actions;
        @(negedge clk);
        btn_cmd = 64'h2004000000000002;            // LinkPGCN 2 (btn field 0)
        btn_cmd_valid = 1;
        @(negedge clk); btn_cmd_valid = 0;
        btns_armed = 0;                            // menu tears down before the PRE
        wait_settled;
        if (!saw_jump || cap_jpgcn != 8'd2)
            fail("S11: button LinkPGCN 2 dispatch jump");
        if (dut.sprm8 !== 16'h0800)
            fail("S11: HL_BTNN (SPRM8) not latched to activated button 2 (0x0800)");
        // reader answers with the dispatch PGC: PRE reads HL_BTNN and branches.
        wr_cmd(0, 64'h6100000f00880000);           // pre[0]: g[15] = HL_BTNN
        wr_cmd(1, 64'h20a4000f04000014);           // pre[1]: if (g15==0x400) LinkPGCN 20 (btn1)
        wr_cmd(2, 64'h20a4000f08000015);           // pre[2]: if (g15==0x800) LinkPGCN 21 (btn2)
        nr_pre = 3; nr_post = 0; nr_cell = 0; cur_pgcn = 8'd2; cell_count = 8'd6;
        clear_actions;
        pulse_loaded;
        wait_settled;
        if (dut.gprm[15] !== 16'h0800)
            fail("S11: g15 = HL_BTNN read the wrong button after teardown");
        if (!saw_jump || cap_jpgcn != 8'd21)
            fail("S11: dispatch collapsed to button-1 default (LinkPGCN 20) not 2 (21)");
        $display("S11 HL_BTNN durable latch (TP_SW/Atmosfear always-first fix) PASS");

        // ---------------- [S12] Atmosfear LinkTailPGC dispatch (menu ARMED) --
        // Atmosfear's menu buttons are all LinkTailPGC -> the SAME PGC's POST
        // reads HL_BTNN and dispatches per button. Unlike S11 (LinkPGCN tears
        // the menu down so the dispatch reads the LATCHED sprm8), LinkTailPGC
        // runs the POST while the menu is STILL armed. HW: highlight moves but
        // every option -> the SAME clip, because the live btn_sel shadow (which
        // drifts after activation on a menu re-arm) wins over the latch. The
        // sprm8_frozen fix makes the dispatch read the ACTIVATED button. Real
        // Atmosfear VTSM PGC7 POST encodings.
        vm_restart;
        menu_active = 1;
        wr_cmd(0, 64'h7100000300000000);   // post[0]: g3 = 0
        wr_cmd(1, 64'h6100000000880000);   // post[1]: g0 = HL_BTNN
        wr_cmd(2, 64'h7600000004000000);   // post[2]: g0 /= 0x400
        wr_cmd(3, 64'h00b1000000010008);   // post[3]: if (g0 != 1) Goto 8
        wr_cmd(4, 64'h200400000000003a);   // post[4]: LinkPGCN 58 (button 1)
        wr_cmd(5, 64'd0); wr_cmd(6, 64'd0);
        wr_cmd(7, 64'h00b100000002000c);   // post[7]: if (g0 != 2) Goto 12
        wr_cmd(8, 64'h2004000000000054);   // post[8]: LinkPGCN 84 (button 2)
        nr_pre = 0; nr_post = 9; nr_cell = 0; cur_pgcn = 8'd7; cell_count = 8'd1;
        // S12a BASELINE: btn_sel held at 2 through the POST -> dispatch btn 2.
        btns_armed = 1; btn_sel = 6'd2;
        clear_actions;
        @(negedge clk);
        btn_cmd = 64'h200100000000000d;    // LinkTailPGC
        btn_cmd_valid = 1;
        @(negedge clk); btn_cmd_valid = 0;
        wait_settled;
        if (dut.gprm[0] !== 16'd2 || !saw_jump || cap_jpgcn != 8'd84)
            fail("S12a: LinkTailPGC dispatch != button 2 (LinkPGCN 84)");
        // S12b BUG CASE: after activating button 2, btn_sel drifts to 1 (a menu
        // re-arm reset) while btns_armed stays 1. The dispatch must STILL be
        // button 2 (activation froze the selection). Fails without sprm8_frozen.
        vm_restart;
        menu_active = 1;
        wr_cmd(0, 64'h7100000300000000);
        wr_cmd(1, 64'h6100000000880000);
        wr_cmd(2, 64'h7600000004000000);
        wr_cmd(3, 64'h00b1000000010008);
        wr_cmd(4, 64'h200400000000003a);
        wr_cmd(5, 64'd0); wr_cmd(6, 64'd0);
        wr_cmd(7, 64'h00b100000002000c);
        wr_cmd(8, 64'h2004000000000054);
        nr_pre = 0; nr_post = 9; nr_cell = 0; cur_pgcn = 8'd7; cell_count = 8'd1;
        btns_armed = 1; btn_sel = 6'd2;
        clear_actions;
        @(negedge clk);
        btn_cmd = 64'h200100000000000d;    // activate button 2 (LinkTailPGC)
        btn_cmd_valid = 1;
        @(negedge clk); btn_cmd_valid = 0;
        btn_sel = 6'd1;                     // btn_sel drifts to 1 (menu re-arm)
        wait_settled;
        if (dut.gprm[0] !== 16'd2 || !saw_jump || cap_jpgcn != 8'd84)
            fail("S12b: dispatch collapsed to button 1 (LinkPGCN 58) on btn_sel drift");
        $display("S12 Atmosfear LinkTailPGC dispatch survives btn_sel drift PASS");

        // ---------------- [S13] 15-bit PGCN: LinkPGCN / JumpSS_VMGM_PGC ------
        // REGRESSION for the Weakest Link root cause (docs/disc_sweep.md): the
        // DVD LinkPGCN operand is a 15-BIT field (libdvdnav decoder.c
        // eval_link_instruction: getbits(14,15)) and JumpSS_VMGM_PGC's pgcN is
        // getbits(46,15). We took ins[7:0] / ins[39:32], so a disc with a big
        // PGCIT aliased: Weakest Link's VTS_02 has 1394 PGCs and its jump to
        // PGC 1381 (0x565) landed on PGC 101 -- deterministically, which is why
        // EVERY menu option ended on the same wrong screen.
        vm_restart;
        wr_cmd(0, 64'h2004000000000565);   // pre[0]: LinkPGCN 1381
        nr_pre = 1; nr_post = 0; nr_cell = 0; cur_pgcn = 16'd1; cell_count = 8'd1;
        clear_actions;
        pulse_loaded;
        wait_settled;
        if (!saw_jump || cap_jpgcn !== 16'd1381)
            begin fail("S13a: LinkPGCN 1381 truncated"); $display("  got pgcn=%0d", cap_jpgcn); end
        // a small PGCN must be unaffected (no regression on normal discs)
        vm_restart;
        wr_cmd(0, 64'h200400000000001b);   // LinkPGCN 27
        nr_pre = 1; nr_post = 0; nr_cell = 0; cur_pgcn = 16'd1; cell_count = 8'd1;
        clear_actions; pulse_loaded; wait_settled;
        if (!saw_jump || cap_jpgcn !== 16'd27)
            begin fail("S13b: small LinkPGCN regressed"); $display("  got pgcn=%0d", cap_jpgcn); end
        // JumpSS_VMGM_PGC with a >255 pgcN (field at ins[46:32])
        vm_restart;
        wr_cmd(0, 64'h3006056500c00000);   // JumpSS_VMGM_PGC 1381 (pgcN @ ins[46:32])
        nr_pre = 1; nr_post = 0; nr_cell = 0; cur_pgcn = 16'd1; cell_count = 8'd1;
        clear_actions; pulse_loaded; wait_settled;
        if (!saw_jump || cap_jpgcn !== 16'd1381)
            begin fail("S13c: JumpSS_VMGM_PGC 1381 truncated"); $display("  got pgcn=%0d", cap_jpgcn); end
        $display("S13 15-bit PGCN (LinkPGCN + JumpSS_VMGM_PGC) PASS");

        // ---------------- [S13] Trivial Pursuit Star Wars menu-key fix ------
        // TP_SW is a SINGLE-VTS disc whose VTS1/title1 IS the First-Play
        // copyright+intro (FP does JumpTT 1 -> intro -> menu), and boot's
        // CallSS_VMGM_PGC leaves RSM pointing at that intro. So a Menu press in
        // one of the game's authored menus used to LinkRSM back to the intro =
        // "hitting Menu in a question replays the copyright". Fix: a Menu press
        // in a menu we did NOT enter via the Menu key (came_via_menukey=0)
        // RE-INVOKES the Root menu instead of resuming the FP intro.

        // S13: in a menu (VMGM), RSM = the FP intro (vts1/pgc1), reached NOT via
        // the Menu key. A Menu press must re-invoke VTSM Root, not resume.
        nav_ready = 0;            // drop the leftover boot request before restarting
        vm_restart;
        wait_idle;
        dut.came_via_menukey = 1'b0;
        dut.rsm_vts = 8'd1; dut.rsm_pgcn = 8'd1; dut.rsm_cell = 8'd0;
        dut.vm_dom = 2'd1;                 // DOM_VMGM
        dut.vm_vts = 8'd0;
        dut.fb = 3'd0;                     // FB_NONE
        menu_active = 1;
        clear_actions;
        @(negedge clk); key_menu = 1;
        @(negedge clk); key_menu = 0;
        wait_settled;
        if (cap_jdom == 2'd3)
            fail("S13a: menu key RESUMED the FP intro (the copyright bug)");
        if (!saw_jump || cap_jdom != 2'd2 || cap_jentry != 4'd3)
            fail("S13a: menu key in a non-toggle menu must re-invoke VTSM Root");
        nr_pre = 0; cell_count = 8'd2; cur_pgcn = 8'd1; cur_cell = 8'd0;
        pulse_loaded; wait_idle;
        $display("S13 menu-key re-invokes Root (no copyright resume) PASS");

        // ---------------- [S14] 0-cell menu dead-end -> menu, not copyright --
        // A menu PGC that arrives 0-cell with nr_pre==0 (its command table's
        // nr_pre was delivered as 0 -- the reveal-return stub, TP Star Wars
        // symptom 1) is a dead-end. It must recover through the MENU fallback
        // chain (best_menu_vts VTSM Root -> ...), NOT the auto-title (= VTS1/
        // title1 = the copyright). Also latches dbg_deadend = the failing PGC.
        nav_ready = 0; vm_restart; wait_idle;
        dut.vm_dom = 2'd2;                 // DOM_VTSM
        dut.vm_vts = 8'd1;
        dut.came_via_menukey = 1'b0;
        cur_vts = 8'd1; cur_pgcn = 8'd27; cur_cell = 8'd0;   // the dead-end stub
        nr_pre = 0; nr_post = 0; nr_cell = 0; cell_count = 8'd0;
        menu_active = 1;
        clear_actions;
        pulse_loaded;                      // reader-internal load while idle
        wait_settled;
        if (cap_jdom == 2'd3 && cap_jvts == auto_vts)
            fail("S14: 0-cell menu dead-end fell to the auto-title (copyright)");
        if (!saw_jump || cap_jdom != 2'd2 || cap_jvts != best_menu_vts ||
            cap_jentry != 4'd3)
            fail("S14: dead-end must recover via best_menu_vts VTSM Root");
        if (dut.deadend_pgcn !== 8'd27 || dut.deadend_vts !== 8'd1)
            fail("S14: dbg_deadend did not latch the failing PGC {01,27}");
        nr_pre = 0; cell_count = 8'd2; pulse_loaded; wait_idle;
        $display("S14 0-cell menu dead-end recovers to a menu + latches PGC PASS");

        // ---------------- [S15] Phase-B provenance (vm_from_wait) -----------
        // Natural = the jump/seek is the verdict on a CELL or POST command
        // block (the reader is parked in S_VM_WAIT). User/boot/menu event
        // jumps must sample 0 - including AFTER a prior CELL/POST dispatch
        // left a stale blk (the V_IDLE arms force blk <= BLK_BTN).
        nav_ready = 0; vm_restart; wait_idle;
        menu_active = 0;
        cur_vts = 8'd5; cur_pgcn = 8'd1; cur_cell = 8'd0; cell_count = 8'd3;
        // (a) CELL-command jump -> natural = 1
        wr_cmd(0, 64'h2004000000000003);         // cell cmd 1: LinkPGCN 3
        nr_pre = 0; nr_post = 0; nr_cell = 1;
        clear_actions;
        @(negedge clk); vm_cell_cmd = 1; cell_cmd_nr = 8'd1;
        @(negedge clk); vm_cell_cmd = 0;
        wait_settled;
        if (!saw_jump || cap_jpgcn != 8'd3)
            fail("S15a: cell-cmd LinkPGCN 3 jump missing");
        if (cap_natural !== 1'b1)
            fail("S15a: cell-cmd jump must sample vm_from_wait=1");
        nr_pre = 0; nr_cell = 0; cell_count = 8'd3;
        pulse_loaded; wait_idle;                 // answer; blk stays BLK_CELL
        // (b) Menu key AFTER the CELL dispatch -> natural must read 0
        // (without the BLK_BTN discipline the stale BLK_CELL leaks through
        // and a user Menu jump would tail-drain-gate for seconds).
        clear_actions;
        @(negedge clk); key_menu = 1;
        @(negedge clk); key_menu = 0;
        wait_settled;
        if (!saw_jump || cap_jdom != 2'd2)
            fail("S15b: menu-key VTSM jump missing");
        if (cap_natural !== 1'b0)
            fail("S15b: menu-key jump misclassified natural (stale CELL blk)");
        nr_pre = 0; cell_count = 8'd2; menu_active = 1;
        pulse_loaded; wait_idle;
        // (c) POST jump -> natural = 1
        wr_cmd(0, 64'h3006000000420000);         // post[0]: JumpSS VMGM menu 2
        nr_pre = 0; nr_post = 1; nr_cell = 0;
        clear_actions;
        @(negedge clk); vm_pgc_end = 1;
        @(negedge clk); vm_pgc_end = 0;
        wait_settled;
        if (!saw_jump || cap_jdom != 2'd1)
            fail("S15c: POST JumpSS jump missing");
        if (cap_natural !== 1'b1)
            fail("S15c: POST jump must sample vm_from_wait=1");
        nr_pre = 0; nr_post = 0; cell_count = 8'd2;
        pulse_loaded; wait_idle;                 // answer; blk stays BLK_POST
        // (d) button jump (stale BLK_POST from (c)) -> natural = 0
        clear_actions;
        @(negedge clk); btn_cmd = 64'h2004000000000002; btn_cmd_valid = 1;
        @(negedge clk); btn_cmd_valid = 0;
        wait_settled;
        if (!saw_jump || cap_jpgcn != 8'd2)
            fail("S15d: button LinkPGCN 2 jump missing");
        if (cap_natural !== 1'b0)
            fail("S15d: button jump must sample vm_from_wait=0");
        nr_pre = 0; cell_count = 8'd2;
        pulse_loaded; wait_idle;
        // (e) CELL-command SEEK -> natural = 1
        wr_cmd(0, 64'h2007000000000002);         // cell cmd 1: LinkCN 2
        nr_pre = 0; nr_post = 0; nr_cell = 1; cur_cell = 8'd0; cell_count = 8'd3;
        clear_actions;
        @(negedge clk); vm_cell_cmd = 1; cell_cmd_nr = 8'd1;
        @(negedge clk); vm_cell_cmd = 0;
        wait_idle;
        if (!saw_seek || cap_scell != 8'd1)
            fail("S15e: cell-cmd LinkCN 2 seek missing");
        if (cap_snat !== 1'b1)
            fail("S15e: cell-cmd seek must sample vm_from_wait=1");
        // (f) PRE-block jump -> natural = 0
        wr_cmd(0, 64'h2004000000000004);         // pre[0]: LinkPGCN 4
        nr_pre = 1; nr_post = 0; nr_cell = 0; cell_count = 8'd3;
        clear_actions;
        pulse_loaded;
        wait_settled;
        if (!saw_jump || cap_jpgcn != 8'd4)
            fail("S15f: PRE LinkPGCN 4 jump missing");
        if (cap_natural !== 1'b0)
            fail("S15f: PRE jump must sample vm_from_wait=0");
        nr_pre = 0; cell_count = 8'd2;
        pulse_loaded; wait_idle;
        // (g) BUTTON LinkTailPGC -> POST jump: natural = 0 (the Tomb Raider
        // Select scene-skip regression: the POST reads blk=BLK_POST, but the
        // chain was USER-started, so nat_src must keep vm_from_wait low -
        // gating here tail-drained the whole VBUF before the skip landed).
        wr_cmd(0, 64'h2004000000000007);         // post[0]: LinkPGCN 7
        nr_pre = 0; nr_post = 1; nr_cell = 0; cell_count = 8'd3;
        clear_actions;
        @(negedge clk); btn_cmd = 64'h200100000000000d; btn_cmd_valid = 1;  // LinkTailPGC
        @(negedge clk); btn_cmd_valid = 0;
        wait_settled;
        if (!saw_jump || cap_jpgcn != 8'd7)
            fail("S15g: button TailPGC -> POST LinkPGCN 7 jump missing");
        if (cap_natural !== 1'b0)
            fail("S15g: button-initiated POST jump must sample vm_from_wait=0 (TR skip)");
        nr_pre = 0; nr_post = 0; cell_count = 8'd2;
        pulse_loaded; wait_idle;
        // (h) control for (g): the SAME POST reached via a natural PGC end
        // must still sample 1 (nat_src distinguishes the two).
        wr_cmd(0, 64'h2004000000000007);         // post[0]: LinkPGCN 7
        nr_pre = 0; nr_post = 1; nr_cell = 0;
        clear_actions;
        @(negedge clk); vm_pgc_end = 1;
        @(negedge clk); vm_pgc_end = 0;
        wait_settled;
        if (!saw_jump || cap_jpgcn != 8'd7)
            fail("S15h: PGC-end POST LinkPGCN 7 jump missing");
        if (cap_natural !== 1'b1)
            fail("S15h: PGC-end POST jump must sample vm_from_wait=1");
        nr_pre = 0; nr_post = 0; cell_count = 8'd2;
        pulse_loaded; wait_idle;
        $display("S15 Phase-B vm_from_wait provenance (stale-blk + TR-skip fixes) PASS");

        // ---------------- [S16] Cluedo: Select in a DISC-driven menu = no-op --
        // Cluedo's boot: FP JumpTT 1 -> VTS1 PGC1 PRE dispatches on g5 then
        // CallSS VMGM pgc2 (saves RSM = VTS1 PGC1 cell 1) -> copyright/logos/
        // intro (VMGM PGC2-5, ZERO HLI buttons) -> game menu. Select during the
        // intro hit emu's "no buttons armed = resume", RSM'd into VTS1 PGC1's
        // lone 3 s cell (the "Please Wait, Processing" card; skip_pre correctly
        // skips the dispatch PRE), and its PGC has no POST and no next -> park
        // forever. Fix: ev_resume is gated on came_via_menukey like ev_menu.
        // (a) disc-driven menu (came_via_menukey=0, RSM filled by the disc's
        //     own CallSS): key_resume must do NOTHING.
        nav_ready = 0; vm_restart; wait_idle;
        dut.came_via_menukey = 1'b0;
        dut.rsm_vts = 8'd1; dut.rsm_pgcn = 8'd1; dut.rsm_cell = 8'd1;
        dut.vm_dom = 2'd1;                 // DOM_VMGM (the intro chain)
        dut.vm_vts = 8'd0;
        menu_active = 1;
        clear_actions;
        @(negedge clk); key_resume = 1;
        @(negedge clk); key_resume = 0;
        wait_settled;
        if (saw_jump || saw_seek || saw_replay)
            fail("S16a: Select in a disc-driven menu must be a no-op (Cluedo park)");
        if (dut.state !== 4'd0)            // V_IDLE: event consumed, no dangling wait
            fail("S16a: VM not back in V_IDLE after the gated resume");
        // (b) the USER toggle still resumes: same RSM but came_via_menukey=1.
        dut.came_via_menukey = 1'b1;
        clear_actions;
        @(negedge clk); key_resume = 1;
        @(negedge clk); key_resume = 0;
        wait_settled;
        if (!saw_jump || cap_jdom != 2'd3 || cap_jvts != 8'd1 ||
            cap_jpgcn != 8'd1 || cap_jcell != 8'd1)
            fail("S16b: menu-key-entered resume broken (must still LinkRSM)");
        nr_pre = 0; cell_count = 8'd2; menu_active = 0;
        cur_vts = 8'd1; cur_pgcn = 8'd1; cur_cell = 8'd1;
        pulse_loaded; wait_idle;
        $display("S16 Select resume gated on came_via_menukey (Cluedo intro park) PASS");

        // ---------------- [S17] TITLE key (B12 "Top Menu") ------------------
        // (a) From a playing title: jump VMGM Title (entry 2), save RSM and
        //     set came_via_menukey (Menu/Select toggle back, like the Menu key).
        nav_ready = 0; vm_restart; wait_idle;
        menu_active = 0;
        cur_vts = 8'd3; cur_pgcn = 8'd2; cur_cell = 8'd4; cell_count = 8'd6;
        clear_actions;
        @(negedge clk); key_title = 1;
        @(negedge clk); key_title = 0;
        wait_settled;
        if (!saw_jump || cap_jdom != 2'd1 || cap_jentry != 4'd2)
            fail("S17a: title key must jump VMGM Title (entry 2)");
        if (dut.rsm_vts !== 8'd3 || dut.rsm_pgcn !== 8'd2 || dut.rsm_cell !== 8'd4)
            fail("S17a: title key from a title must save RSM");
        if (dut.came_via_menukey !== 1'b1)
            fail("S17a: title key from a title must set came_via_menukey");
        nr_pre = 0; cell_count = 8'd2; menu_active = 1;
        cur_vts = 8'd0; cur_pgcn = 8'd1; cur_cell = 8'd0;
        pulse_loaded; wait_idle;
        // (b) Select with no buttons in that menu -> resumes the title (the
        //     toggle rides the Title key exactly like the Menu key).
        clear_actions;
        @(negedge clk); key_resume = 1;
        @(negedge clk); key_resume = 0;
        wait_settled;
        if (!saw_jump || cap_jdom != 2'd3 || cap_jvts != 8'd3 ||
            cap_jpgcn != 8'd2 || cap_jcell != 8'd4)
            fail("S17b: Select after Title key must resume the saved title");
        nr_pre = 0; cell_count = 8'd6; menu_active = 0;
        cur_vts = 8'd3; cur_pgcn = 8'd2; cur_cell = 8'd4;
        pulse_loaded; wait_idle;
        // (c) From a DISC-driven menu (came_via_menukey=0, RSM = the boot
        //     trampoline stub): jump VMGM Title but do NOT touch RSM or the
        //     toggle flag - the stub RSM must not be re-blessed (see S16).
        nav_ready = 0; vm_restart; wait_idle;
        dut.came_via_menukey = 1'b0;
        dut.rsm_vts = 8'd1; dut.rsm_pgcn = 8'd1; dut.rsm_cell = 8'd1;
        dut.vm_dom = 2'd1;                 // DOM_VMGM
        dut.vm_vts = 8'd0;
        menu_active = 1;
        cur_vts = 8'd1; cur_pgcn = 8'd2; cur_cell = 8'd0;
        clear_actions;
        @(negedge clk); key_title = 1;
        @(negedge clk); key_title = 0;
        wait_settled;
        if (!saw_jump || cap_jdom != 2'd1 || cap_jentry != 4'd2)
            fail("S17c: title key in a menu must jump VMGM Title (entry 2)");
        if (dut.rsm_vts !== 8'd1 || dut.rsm_pgcn !== 8'd1 || dut.rsm_cell !== 8'd1)
            fail("S17c: title key in a menu must not clobber RSM");
        if (dut.came_via_menukey !== 1'b0)
            fail("S17c: title key in a disc-driven menu must not set came_via_menukey");
        nr_pre = 0; cell_count = 8'd2; menu_active = 1;
        cur_vts = 8'd0; cur_pgcn = 8'd1; cur_cell = 8'd0;
        pulse_loaded; wait_idle;
        $display("S17 Title key (VMGM Top Menu + RSM toggle discipline) PASS");

        // ---------------- [S18] RETURN key (B13, GoUp) ----------------------
        // (a) Loaded menu PGC authors goup_pgcn -> in-domain jump to it
        //     (mirrors the LinkGoUpPGC command exec; libdvdnav dvdnav_go_up).
        nav_ready = 0; vm_restart; wait_idle;
        dut.vm_dom = 2'd2;                 // DOM_VTSM
        dut.vm_vts = 8'd5;
        menu_active = 1;
        cur_vts = 8'd5; cur_pgcn = 8'd9; cur_cell = 8'd0; cell_count = 8'd2;
        goup_pgcn = 8'd4;
        clear_actions;
        @(negedge clk); key_return = 1;
        @(negedge clk); key_return = 0;
        wait_settled;
        if (!saw_jump || cap_jdom != 2'd2 || cap_jvts != 8'd5 ||
            cap_jpgcn != 8'd4)
            fail("S18a: Return must jump in-domain to the authored goup_pgcn");
        nr_pre = 0; cell_count = 8'd2; cur_pgcn = 8'd4;
        pulse_loaded; wait_idle;
        // (b) goup_pgcn == 0 (no authored parent - most movie titles): a
        //     strict no-op, VM stays idle.
        goup_pgcn = 8'd0;
        clear_actions;
        @(negedge clk); key_return = 1;
        @(negedge clk); key_return = 0;
        wait_settled;
        if (saw_jump || saw_seek || saw_replay)
            fail("S18b: Return with goup_pgcn==0 must be a no-op");
        if (dut.state !== 4'd0)
            fail("S18b: VM not back in V_IDLE after the gated Return");
        goup_pgcn = 8'd0;
        $display("S18 Return key (GoUp jump / no-op without a parent) PASS");

        // ---------------- [S19] Hobbit PGCN3 POST trampoline (real block) ----
        // THE_HOBBIT_UNEXPECTED_JOURNEY boots FP -> warnings -> VTSM pre
        // JumpVTS_TT 3 -> TT PGCN 3 (a settings-trampoline title whose only
        // cell is zero-backed on this pressing) -> this 34-command POST:
        // language-pref GPRM setup, ★g[6]=1 at post[28] (the flag that stops
        // the VTSM pre from re-running JumpVTS_TT 3 = the infinite-boot-loop
        // guard), CallSS_VMGM_PGC 1 at post[33]. Golden model
        // (tools/dvd_vm_ref.py, captured from the full runboot chain): enters
        // all-gprm-zero, exits with ONLY g[6]=1, sprm1 15->0, link
        // CallSS_VMGM_PGC 1. Exotic ops on the path: type-3 compare-gated
        // sets (71 a0 .. vs ASCII 'fr'/'es'), indirect SetSTN (41 ..).
        nav_ready = 1; vm_restart; wait_idle;
        dut.vm_dom = 2'd3;                 // DOM_TT (title domain)
        dut.vm_vts = 8'd1;
        menu_active = 0;
        cur_vts = 8'd1; cur_pgcn = 8'd3; cur_cell = 8'd0; cell_count = 8'd1;
        begin : s19_init integer i;
            for (i = 0; i < 16; i = i + 1) dut.gprm[i] = 16'd0;
        end
        dut.sprm1 = 16'd15; dut.sprm2 = 16'd0;  dut.sprm3 = 16'd1;
        dut.sprm4 = 16'd4;  dut.sprm5 = 16'd3;  dut.sprm6 = 16'd3;
        dut.sprm7 = 16'd1;  dut.sprm8 = 16'h0400;
        wr_cmd(0,  64'h00a1000600010009);   // if (g6 == 1) Goto 9
        wr_cmd(1,  64'h00a100050001000d);   // if (g5 == 1) Goto 13
        wr_cmd(2,  64'h6100000300920000);   // g3 = SPRM18 (subp pref = 'en')
        wr_cmd(3,  64'h7100000500000000);   // g5 = 0
        wr_cmd(4,  64'h71a0030500016672);   // if (g3 == 'fr') g5 = 1
        wr_cmd(5,  64'h71a0030500026573);   // if (g3 == 'es') g5 = 2
        wr_cmd(6,  64'h4100000085000000);   // SetSTN SPSTN = g0 (indirect)
        wr_cmd(7,  64'h000100000000000d);   // Goto 13
        wr_cmd(8,  64'h00a100040001001a);   // if (g4 == 1) Goto 26
        wr_cmd(9,  64'h00b1000b0001001a);   // if (g11 != 1) Goto 26  <- path
        wr_cmd(10, 64'h4100008d00000000);
        wr_cmd(11, 64'h000100000000001a);
        wr_cmd(12, 64'h00a100040001001a);
        wr_cmd(13, 64'h6100000300900000);   // g3 = SPRM16 (audio pref)
        wr_cmd(14, 64'h7100000400000000);
        wr_cmd(15, 64'h00a1000366720014);
        wr_cmd(16, 64'h00a1000365730017);
        wr_cmd(17, 64'h4100008400000000);
        wr_cmd(18, 64'h000100000000001a);
        wr_cmd(19, 64'h5100008100000000);
        wr_cmd(20, 64'h51000000c3000000);
        wr_cmd(21, 64'h000100000000001a);
        wr_cmd(22, 64'h5100008200000000);
        wr_cmd(23, 64'h51000000c4000000);
        wr_cmd(24, 64'h000100000000001a);
        wr_cmd(25, 64'h7100000300000000);   // g3 = 0
        wr_cmd(26, 64'h7100000400000000);   // g4 = 0
        wr_cmd(27, 64'h7100000500000000);   // g5 = 0
        wr_cmd(28, 64'h7100000600010000);   // ★ g6 = 1
        wr_cmd(29, 64'h7100000800000000);   // g8 = 0
        wr_cmd(30, 64'h7100000b00000000);   // g11 = 0
        wr_cmd(31, 64'h7100000e00000000);   // g14 = 0
        wr_cmd(32, 64'h7100000700000000);   // g7 = 0
        wr_cmd(33, 64'h3008000101c00000);   // CallSS_VMGM_PGC 1 (rsm cell 1)
        nr_pre = 0; nr_post = 34; nr_cell = 0;
        clear_actions;
        @(negedge clk); vm_pgc_end = 1;
        @(negedge clk); vm_pgc_end = 0;
        wait_settled;
        if (!saw_jump || cap_jdom != 2'd1 || cap_jpgcn != 16'd1)
            fail("S19: expected CallSS_VMGM_PGC 1 jump");
        if (dut.gprm[6] !== 16'd1)
            fail("S19: g6 != 1 - the boot-loop guard flag was NOT set");
        if (dut.gprm[3] !== 16'd0 || dut.gprm[4] !== 16'd0 ||
            dut.gprm[5] !== 16'd0 || dut.gprm[11] !== 16'd0 ||
            dut.gprm[14] !== 16'd0)
            fail("S19: g3/g4/g5/g11/g14 not zeroed per the golden model");
        if (dut.sprm1 !== 16'd0)
            fail("S19: sprm1 != 0 (SetSTN ASTN path diverged)");
        $display("S19 Hobbit PGCN3 POST trampoline (g6=1 + CallSS) PASS");

        // ---------------- [S20] Hobbit VTSM PGC1 PRE (both rounds) ----------
        // Round 1 (g6=0): pre[0] Goto 11 -> pre[10] JumpVTS_TT 3 (the
        // trampoline dispatch). Round 2 (g6=1 after S19's block, g11=0):
        // pre[1] Goto 6 -> g13=ASTN -> g10=1 -> pre[8] LinkCN 1 (button 1)
        // = the menu finally plays. An RTL divergence in EITHER round loops
        // the boot forever = the HW black screen.
        nav_ready = 1;
        dut.vm_dom = 2'd2;                 // DOM_VTSM
        dut.vm_vts = 8'd1;
        menu_active = 1;
        cur_vts = 8'd1; cur_pgcn = 8'd1; cur_cell = 8'd0; cell_count = 8'd3;
        begin : s20_init integer i;
            for (i = 0; i < 16; i = i + 1) dut.gprm[i] = 16'd0;
        end
        wr_cmd(0,  64'h00a100060000000b);   // if (g6 == 0) Goto 11
        wr_cmd(1,  64'h00a1000b00000006);   // if (g11 == 0) Goto 6
        wr_cmd(2,  64'h00a1000a0001000a);   // if (g10 == 1) Goto 10
        wr_cmd(3,  64'h7100000a00010000);   // g10 = 1
        wr_cmd(4,  64'h2007000000000401);   // LinkCN 1 (button 1)
        wr_cmd(5,  64'h6100000d00810000);   // g13 = ASTN
        wr_cmd(6,  64'h00a1000a0001000a);   // if (g10 == 1) Goto 10
        wr_cmd(7,  64'h7100000a00010000);   // g10 = 1
        wr_cmd(8,  64'h2007000000000401);   // LinkCN 1 (button 1)
        wr_cmd(9,  64'h2007000000000403);   // LinkCN 3 (button 1)
        wr_cmd(10, 64'h3003000000030000);   // JumpVTS_TT 3
        nr_pre = 11; nr_post = 1; nr_cell = 0;
        // round 1: fresh boot state, g6=0 -> JumpVTS_TT 3
        clear_actions;
        pulse_loaded;
        wait_settled;
        if (!saw_jump || cap_jdom != 2'd3 || cap_jttn != 7'd3)
            fail("S20a: round-1 pre must dispatch JumpVTS_TT 3");
        // round 2: g6=1 (the S19 flag) -> LinkCN 1 = play the menu
        dut.vm_dom = 2'd2;
        dut.vm_vts = 8'd1;
        dut.gprm[6] = 16'd1;
        dut.gprm[10] = 16'd0;
        clear_actions;
        pulse_loaded;
        wait_settled;
        // LinkCN 1 with cur_cell==0 legitimately answers vm_replay (gapless
        // replay of the just-loaded menu cell) instead of a seek - both mean
        // "play the menu". The failure mode being guarded is a JUMP (loop).
        if (!(saw_replay || (saw_seek && cap_scell === 8'd0)))
            fail("S20b: round-2 pre must play the menu (replay/seek cell 0)");
        if (saw_jump)
            fail("S20b: round-2 pre must NOT jump (infinite boot loop)");
        $display("S20 Hobbit VTSM PGC1 pre (trampoline round + menu round) PASS");
    end
    endtask

    // ========================================================================
    // PART 3: DVD-game entropy (counter-mode GPRM tick, rnd seed, entropy stir)
    // Encodings are real, decode_vmcmd-validated commands (from SCENEIT_JR).
    // ========================================================================
    task do_ticks(input integer n);   // apply n one-second ticks (idle-gated)
        integer k;
    begin
        for (k = 0; k < n; k = k + 1) begin
            @(negedge clk); sec_tick = 1;
            @(negedge clk); sec_tick = 0;
            repeat (4) @(negedge clk);   // let V_IDLE apply tick_pending
        end
    end
    endtask

    task part3;
    begin
        // ---- T1: counter-mode GPRM 1 Hz tick + harvest (Scene It mechanism) --
        vm_restart;                          // rnd_seed = 0xACE1 (default)
        wr_cmd(0, 64'h53000005008d0000);     // SetMode Counter g[13] = 5
        wr_cmd(1, 64'h5300006400050000);     // SetMode Register g[5]  = 100
        nr_pre = 2; nr_post = 0; nr_cell = 0; cell_count = 8'd3;
        clear_actions; pulse_loaded; wait_idle;
        if (dut.gprm[13]      !== 16'd5) fail("T1: counter g13 initial != 5");
        if (dut.gprm_mode[13] !== 1'b1)  fail("T1: g13 not in counter mode");
        do_ticks(3);
        if (dut.gprm[13] !== 16'd8)   fail("T1: g13 != 8 after 3 ticks");
        if (dut.gprm[5]  !== 16'd100) fail("T1: register g5 ticked (must not)");
        // harvest the ticked counter into g4 (like PGCN8 pre#0 'g[14] += g[13]')
        wr_cmd(0, 64'h63000004000d0000);     // g[4] += g[13]
        nr_pre = 1; clear_actions; pulse_loaded; wait_idle;
        if (dut.gprm[4] !== 16'd8) fail("T1: harvest g4 != ticked counter (8)");
        $display("T1 counter tick + harvest PASS");

        // ---- T2: rnd seeded from rnd_seed -> different seed, different rnd ---
        // rnd result = 1 + (lfsr_next(seed) % K); seed 0xACE1,K=31 -> 26;
        // seed 0x1234,K=31 -> 6 (precomputed, deterministic).
        rnd_seed = 16'hACE1; vm_restart;
        if (dut.lfsr !== 16'hACE1) fail("T2: lfsr != seed 0xACE1 at mount");
        wr_cmd(0, 64'h78000002001f0000);     // g[2] rnd 0x1f
        nr_pre = 1; nr_post = 0; nr_cell = 0; cell_count = 8'd3;
        clear_actions; pulse_loaded; wait_idle;
        if (dut.gprm[2] !== 16'd26) fail("T2: rnd(seed=ACE1,K=31) != 26");
        rnd_seed = 16'h1234; vm_restart;
        if (dut.lfsr !== 16'h1234) fail("T2: lfsr != seed 0x1234 at mount");
        wr_cmd(0, 64'h78000002001f0000);
        nr_pre = 1; clear_actions; pulse_loaded; wait_idle;
        if (dut.gprm[2] !== 16'd6)  fail("T2: rnd(seed=1234,K=31) != 6");
        $display("T2 rnd seed variation PASS");
        rnd_seed = 16'hACE1;                 // restore default

        // ---- T3: entropy_stir folds user-input timing into the LFSR --------
        vm_restart;                          // lfsr = 0xACE1
        @(negedge clk); ent_val = 16'h00FF; ent_stir = 1;
        @(negedge clk); ent_stir = 0;
        repeat (3) @(negedge clk);
        if (dut.lfsr !== (16'hACE1 ^ 16'h00FF))
            fail("T3: entropy_stir did not XOR the LFSR");
        ent_val = 16'd0;
        $display("T3 entropy stir PASS");

        // ---- T4: a zero seed must not lock the LFSR at 0 -------------------
        rnd_seed = 16'h0000; vm_restart;
        if (dut.lfsr === 16'd0) fail("T4: zero seed locked the LFSR at 0");
        rnd_seed = 16'hACE1;
        $display("T4 nonzero-seed guard PASS");
    end
    endtask

    // ========================================================================
    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (4) @(negedge clk);

        part1;
        $display("PART 1: %0d fixture cases run", n_cases);
        part2;
        part3;

        if (errors == 0) $display("ALL TESTS PASS (dvd_vm_tb)");
        else             $display("%0d ERRORS (dvd_vm_tb)", errors);
        $finish;
    end

endmodule
