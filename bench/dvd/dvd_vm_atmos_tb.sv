// dvd_vm_atmos_tb.sv - direct test of the RTL DVD-VM (dvd/dvd_vm.sv) running
// Atmosfear's real scenario-dispatch jump tables. After the player-setup the
// disc's VM does `JumpSS VMGM(pgc 2)` -> PGC2/PGC3 = a big literal jump table
// (`g0=k; if (g0==g3) JumpTT k+...`) that turns g[3] into the scenario title:
//   g3 0x42(66) -> JumpTT 66  = the 49:00 game (VTS 66) the disc should play
//   g3 0x34(52) -> JumpTT 52  = the green 24:31 game (best_vts, the wrong title)
// PGC2 covers g3=1..50 (else LinkPGCN 3); PGC3 covers 51..75. This TB feeds the
// REAL command bytes (bench/dvd/test_vobs/atmos_pgc{2,3}_cmds.hex) and asserts
// the RTL VM issues the correct JumpTT for each g3 -- verifying the 109-/52-
// command jump table (SetGPRM + register compare + Goto flow + JumpTT) that no
// prior dvd_vm_tb vector exercises. Ground truth: tools/dvd_vm_ref.py.
`timescale 1ns/1ps

module dvd_vm_atmos_tb;
    reg clk = 0;
    always #18.5 clk = ~clk;

    reg rst_n = 0, enable = 1, start = 0, nav_ready = 0;
    reg [7:0] auto_vts = 8'd52, best_menu_vts = 8'd1;

    reg        cmd_we = 0;
    reg [11:0] cmd_waddr = 0;
    reg [7:0]  cmd_wdata = 0;
    reg [7:0]  nr_pre = 0, nr_post = 0, nr_cell = 0;
    reg        pm_we = 0; reg [6:0] pm_waddr = 0; reg [7:0] pm_wdata = 0, nr_pgms = 0;
    reg        pgc_loaded = 0, pgc_error = 0, vm_cell_cmd = 0;
    reg [7:0]  cell_cmd_nr = 0;
    reg        vm_pgc_end = 0, menu_active = 0;
    reg [7:0]  cur_vts = 8'd1, cur_pgcn = 8'd2, cur_cell = 8'd0, cell_count = 8'd1;
    reg [7:0]  next_pgcn = 0, prev_pgcn = 0, goup_pgcn = 0;
    reg        key_menu = 0, key_resume = 0;
    reg [63:0] btn_cmd = 0; reg btn_cmd_valid = 0;
    reg [5:0]  btn_sel = 6'd1; reg btns_armed = 0;
    reg [15:0] rnd_seed = 16'hACE1; reg sec_tick = 0, ent_stir = 0; reg [15:0] ent_val = 0;

    wire        btn_force; wire [5:0] btn_force_val;
    reg  [6:0]  cap_jttn;
    wire        jump_pulse; wire [1:0] jump_domain;
    wire [7:0]  jump_vts, jump_pgcn, jump_cell, jump_pgn;
    wire [3:0]  jump_entry; wire [6:0] jump_ttn;
    wire        seek_pulse; wire [7:0] seek_cell;
    wire        vm_replay, vm_adv; wire [7:0] sprm_astn, sprm_spstn; wire [7:0] dbg_state;
    wire        vm_pgc_end_o, menu_active_o;
    wire [7:0]  cur_vts_o, cur_pgcn_o, cur_cell_o, next_pgcn_o, prev_pgcn_o, goup_pgcn_o;

    dvd_vm dut (
        .clk(clk), .rst_n(rst_n), .enable(enable), .start(start),
        .rnd_seed(rnd_seed), .sec_tick(sec_tick),
        .entropy_stir(ent_stir), .entropy_val(ent_val),
        .nav_ready(nav_ready), .auto_vts(auto_vts), .best_menu_vts(best_menu_vts),
        .res_ttn(cap_jttn),
        .cmd_we(cmd_we), .cmd_waddr(cmd_waddr), .cmd_wdata(cmd_wdata),
        .nr_pre(nr_pre), .nr_post(nr_post), .nr_cell(nr_cell),
        .pm_we(pm_we), .pm_waddr(pm_waddr), .pm_wdata(pm_wdata), .nr_pgms(nr_pgms),
        .pgc_loaded(pgc_loaded), .pgc_error(pgc_error),
        .vm_cell_cmd(vm_cell_cmd), .cell_cmd_nr(cell_cmd_nr),
        .vm_pgc_end(vm_pgc_end), .menu_active(menu_active),
        .cur_vts(cur_vts), .cur_pgcn(cur_pgcn), .cur_cell(cur_cell),
        .cell_count(cell_count),
        .next_pgcn(next_pgcn), .prev_pgcn(prev_pgcn), .goup_pgcn(goup_pgcn),
        .key_menu(key_menu), .key_resume(key_resume), .key_title(1'b0), .key_return(1'b0),
        .btn_cmd(btn_cmd), .btn_cmd_valid(btn_cmd_valid),
        .btn_sel(btn_sel), .btns_armed(btns_armed),
        .btn_force(btn_force), .btn_force_val(btn_force_val),
        .jump_pulse(jump_pulse), .jump_domain(jump_domain),
        .jump_vts(jump_vts), .jump_pgcn(jump_pgcn), .jump_entry(jump_entry),
        .jump_ttn(jump_ttn), .jump_pgn(jump_pgn), .jump_cell(jump_cell),
        .seek_pulse(seek_pulse), .seek_cell(seek_cell),
        .vm_replay(vm_replay), .vm_adv(vm_adv), .wait_hold(1'b0),
        .sprm_astn(sprm_astn), .sprm_spstn(sprm_spstn),
        .dbg_state(dbg_state)
    );

    // ---- action capture ----
    reg saw_jump; reg [1:0] cap_jdom; reg [7:0] cap_jpgcn;
    always @(posedge clk) begin
        if (jump_pulse) begin
            saw_jump  <= 1'b1; cap_jdom <= jump_domain;
            cap_jttn  <= jump_ttn; cap_jpgcn <= jump_pgcn;
        end
    end
    task clear_actions; begin saw_jump = 0; cap_jdom = 0; cap_jttn = 0; cap_jpgcn = 0; end endtask

    task wr_cmd(input [8:0] idx, input [63:0] c);
        integer b;
    begin
        for (b = 0; b < 8; b = b + 1) begin
            @(negedge clk);
            cmd_we = 1; cmd_waddr = {idx, 3'b000} + b[11:0]; cmd_wdata = c[63 - b*8 -: 8];
        end
        @(negedge clk); cmd_we = 0;
    end
    endtask

    task pulse_loaded; begin @(negedge clk); pgc_loaded = 1; @(negedge clk); pgc_loaded = 0; end endtask

    wire vm_pending = dut.ev_boot | dut.ev_loaded | dut.ev_error | dut.ev_cellcmd |
                      dut.ev_pgcend | dut.ev_btn | dut.ev_menu | dut.ev_resume;
    task wait_settled; integer t; begin
        repeat (4) @(negedge clk); t = 0;
        while (((dbg_state[3:0] != 4'd0 && dbg_state[3:0] != 4'd10) ||
                (dbg_state[3:0] == 4'd0 && vm_pending)) && t < 200000) begin
            @(negedge clk); t = t + 1; end
        repeat (4) @(negedge clk);
    end endtask

    // load a command block (from a hex fixture) as the PRE block of a PGC
    reg [7:0] cmds [0:511*8-1];
    integer errors = 0, ci;
    reg [63:0] cw;

    task load_block(input [8:0] ncmd);
        integer k, bb;
    begin
        for (k = 0; k < ncmd; k = k + 1) begin
            cw = 64'd0;
            for (bb = 0; bb < 8; bb = bb + 1) cw = {cw[55:0], cmds[k*8 + bb]};
            wr_cmd(k[8:0], cw);
        end
        nr_pre = ncmd[7:0]; nr_post = 0; nr_cell = 0;
    end
    endtask

    // set g3, run the loaded PGC's PRE, assert JumpTT == exp (dom TT=3)
    task chk_jtt(input [15:0] g3, input [6:0] exp);
    begin
        dut.gprm[3] = g3;
        clear_actions;
        pulse_loaded;
        wait_settled;
        if (!saw_jump) begin errors=errors+1;
            $display("  ERR g3=0x%0x: no jump issued (exp JumpTT %0d)", g3, exp); end
        else if (cap_jdom != 2'd3) begin errors=errors+1;
            $display("  ERR g3=0x%0x: jump_domain=%0d not TT (exp JumpTT %0d)", g3, cap_jdom, exp); end
        else if (cap_jttn != exp) begin errors=errors+1;
            $display("  ERR g3=0x%0x: JumpTT %0d, EXPECTED %0d  <-- jump-table bug", g3, cap_jttn, exp); end
        else
            $display("  OK  g3=0x%0x -> JumpTT %0d", g3, cap_jttn);
    end
    endtask

    initial begin
        rst_n = 0; repeat (6) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);
        nav_ready = 1;                       // FP boot -> VM issues FP jump, waits
        wait_settled;

        // ---- PGC3 (scenarios 51..75): the range that includes 52/64/66 ----
        $display("== PGC3 jump table (g3 0x33..0x4b -> JumpTT 51..75) ==");
        $readmemh("bench/dvd/test_vobs/atmos_pgc3_cmds.hex", cmds);
        load_block(9'd52);
        chk_jtt(16'h0033, 7'd51);
        chk_jtt(16'h0034, 7'd52);   // the wrong title our core shows (green 24:31)
        chk_jtt(16'h0040, 7'd64);
        chk_jtt(16'h0042, 7'd66);   // THE 49:00 GAME the disc should play
        chk_jtt(16'h004b, 7'd75);

        // ---- PGC2 (scenarios 1..50; g3>=0x33 -> LinkPGCN 3) ----
        $display("== PGC2 jump table (g3 1..50 -> JumpTT; >=0x33 -> LinkPGCN 3) ==");
        $readmemh("bench/dvd/test_vobs/atmos_pgc2_cmds.hex", cmds);
        load_block(9'd109);
        chk_jtt(16'h0005, 7'd5);    // low range: g3=5 -> JumpTT 5
        // g3=0x42 in PGC2 -> LinkPGCN 3 (not a JumpTT): verify it links, not jumps TT
        dut.gprm[3] = 16'h0042; clear_actions; pulse_loaded; wait_settled;
        if (!saw_jump || cap_jpgcn != 8'd3)
            begin errors=errors+1; $display("  ERR PGC2 g3=0x42: expected LinkPGCN 3, got jump dom=%0d pgcn=%0d ttn=%0d",
                                            cap_jdom, cap_jpgcn, cap_jttn); end
        else $display("  OK  PGC2 g3=0x42 -> LinkPGCN 3 (routes to PGC3)");

        if (errors == 0) $display("DVD_VM_ATMOS_TB: PASSED (jump tables correct: g3=0x42 -> JumpTT 66)");
        else             $display("DVD_VM_ATMOS_TB: FAILED with %0d errors", errors);
        $finish;
    end
    initial begin #50000000; $display("DVD_VM_ATMOS_TB: TIMEOUT"); $finish; end
endmodule
