// vm_ab_tb.sv -- runs one VM stimulus script on an RTL VM and logs what it does, in
// the format of tools/nav_shell.py, so tools/vm_ab.py can diff three VMs against
// each other: the old hardwired FSM (bench/dvd/ref/dvd_vm_hw.sv, the oracle), the
// Python model (microcode emulator + wrapper model), and the microcoded RTL.
//
//   default         DUT = dvd_vm_hw (the pre-microcode FSM, unchanged)
//   +define+VM_NEW  DUT = dvd_vm (the microcoded wrapper)
//
// The script arrives as numeric ops (tools/vm_ab.py writes them), one per line,
// `op a b` in hex:
//   1 set     a = input index (nav_shell.INPUTS order), b = value
//   2 cmd     a = command index, b = the 8 bytes
//   3 pm      a = index, b = value
//   4 pulse   a = mask (nav_shell.PULSES order), with the args from op 7
//   5 timeout
//   6 settle
//   7 arg     a = 0 cellcmd nr, 1 btn command, 2 chedge dir, 3 stir value, 4 agl value
// Every op but 7 is a step; after each the bench waits for quiescence and, for all
// but cmd/pm, prints the state. Pulses and SPRM changes are printed as they happen.
// A step that never settles is a [hang] and fatal.
`timescale 1ns/1ps
`default_nettype none

module vm_ab_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    // ---- inputs (nav_shell.INPUTS order) ----
    reg        enable = 1;
    reg [15:0] cfg_lang = 16'h656E, cfg_sprm14 = 16'h0100, cfg_sprm15 = 16'h7CFC, cfg_sprm20 = 16'h0001;
    reg        nav_ready = 0;
    reg [7:0]  auto_vts = 0, best_menu_vts = 0;
    reg [6:0]  res_ttn = 0;
    reg [15:0] rnd_seed = 16'hACE1;
    reg [7:0]  nr_pre = 0, nr_post = 0, nr_cell = 0, nr_pgms = 0;
    reg        menu_active = 0;
    reg [7:0]  cur_vts = 0;
    reg [15:0] cur_pgcn = 0;
    reg [7:0]  cur_cell = 0, cell_count = 0;
    reg [15:0] next_pgcn = 0, prev_pgcn = 0, goup_pgcn = 0;
    reg [5:0]  btn_sel = 0;
    reg        btns_armed = 0, wait_hold = 0;
    // ---- pulses ----
    reg        start = 0, sec_tick = 0, entropy_stir = 0;
    reg [15:0] entropy_val = 0;
    reg        cmd_we = 0;
    reg [11:0] cmd_waddr = 0;
    reg [7:0]  cmd_wdata = 0;
    reg        pm_we = 0;
    reg [6:0]  pm_waddr = 0;
    reg [7:0]  pm_wdata = 0;
    reg        pgc_loaded = 0, pgc_error = 0, vm_cell_cmd = 0, vm_pgc_end = 0;
    reg [7:0]  cell_cmd_nr = 0;
    reg        key_menu = 0, key_title = 0, key_return = 0, key_cmenu = 0;
    reg        key_chedge = 0, key_chedge_dir = 0;
    reg [63:0] btn_cmd = 0;
    reg        btn_cmd_valid = 0;
    reg        agl_set = 0;
    reg [3:0]  agl_set_val = 0;

    wire        btn_force; wire [5:0] btn_force_val; wire [5:0] hl_btnn;
    wire        jump_pulse; wire [1:0] jump_domain; wire [7:0] jump_vts; wire [15:0] jump_pgcn;
    wire [3:0]  jump_entry; wire [6:0] jump_ttn; wire [7:0] jump_pgn; wire [9:0] jump_ptt;
    wire [7:0]  jump_cell;
    wire        seek_pulse; wire [7:0] seek_cell; wire vm_replay, vm_adv, vm_from_wait;
    wire [7:0]  sprm_astn, sprm_spstn, sprm_agln;
    wire        pre_done, link_fail; wire [7:0] link_fail_pgcn;
    wire [7:0]  dbg_state; wire [15:0] dbg_g3, dbg_g14_9, dbg_rsm, dbg_deadend;

`ifdef VM_NEW
    dvd_vm dut (
`else
    dvd_vm_hw dut (
`endif
        .clk(clk), .rst_n(rst_n), .enable(enable), .start(start), .cfg_lang(cfg_lang),
        .cfg_sprm14(cfg_sprm14), .cfg_sprm15(cfg_sprm15), .cfg_sprm20(cfg_sprm20),
        .nav_ready(nav_ready), .auto_vts(auto_vts), .best_menu_vts(best_menu_vts),
        .res_ttn(res_ttn), .rnd_seed(rnd_seed), .sec_tick(sec_tick),
        .entropy_stir(entropy_stir), .entropy_val(entropy_val),
        .cmd_we(cmd_we), .cmd_waddr(cmd_waddr), .cmd_wdata(cmd_wdata),
        .nr_pre(nr_pre), .nr_post(nr_post), .nr_cell(nr_cell),
        .pm_we(pm_we), .pm_waddr(pm_waddr), .pm_wdata(pm_wdata), .nr_pgms(nr_pgms),
        .pgc_loaded(pgc_loaded), .pgc_error(pgc_error), .vm_cell_cmd(vm_cell_cmd),
        .cell_cmd_nr(cell_cmd_nr), .vm_pgc_end(vm_pgc_end), .menu_active(menu_active),
        .cur_vts(cur_vts), .cur_pgcn(cur_pgcn), .cur_cell(cur_cell), .cell_count(cell_count),
        .next_pgcn(next_pgcn), .prev_pgcn(prev_pgcn), .goup_pgcn(goup_pgcn),
        .key_menu(key_menu), .key_title(key_title), .key_return(key_return),
        .key_cmenu(key_cmenu), .key_chedge(key_chedge), .key_chedge_dir(key_chedge_dir),
        .btn_cmd(btn_cmd), .btn_cmd_valid(btn_cmd_valid), .btn_sel(btn_sel),
        .btns_armed(btns_armed), .btn_force(btn_force), .btn_force_val(btn_force_val),
        .hl_btnn(hl_btnn), .jump_pulse(jump_pulse), .jump_domain(jump_domain),
        .jump_vts(jump_vts), .jump_pgcn(jump_pgcn), .jump_entry(jump_entry),
        .jump_ttn(jump_ttn), .jump_pgn(jump_pgn), .jump_ptt(jump_ptt), .jump_cell(jump_cell),
        .seek_pulse(seek_pulse), .seek_cell(seek_cell), .vm_replay(vm_replay),
        .vm_adv(vm_adv), .vm_from_wait(vm_from_wait), .wait_hold(wait_hold),
        .sprm_astn(sprm_astn), .sprm_spstn(sprm_spstn), .sprm_agln(sprm_agln),
        .pre_done(pre_done), .agl_set(agl_set), .agl_set_val(agl_set_val),
        .dbg_state(dbg_state), .dbg_g3(dbg_g3), .dbg_g14_9(dbg_g14_9), .dbg_rsm(dbg_rsm),
        .dbg_deadend(dbg_deadend), .link_fail(link_fail), .link_fail_pgcn(link_fail_pgcn));

    // ---- the state each DUT keeps, by name ----
`ifdef VM_NEW
    `include "nav/nav_ucode.svh"
    `define RAMW(a)    dut.u_seq.dram[a]
    `define S_GPRM(i)  `RAMW(UM_GPRM + i)
    `define S_GMODE    `RAMW(UM_GMODE)
    `define S_SPRMI(n) `RAMW(UM_SPRMI + n)
    `define S_SPRM1    dut.sprm1
    `define S_SPRM2    dut.sprm2
    `define S_SPRM3    dut.sprm3
    `define S_SPRM8    dut.sprm8
    `define S_RSM_VTS  `RAMW(UM_RSM_VTS)
    `define S_RSM_PGCN `RAMW(UM_RSM_PGCN)
    `define S_RSM_CELL `RAMW(UM_RSM_CELL)
    `define S_RSM_R(n) `RAMW(UM_RSM_R4 + n - 4)
    `define S_FB       `RAMW(UM_FB)
    `define S_CVM      `RAMW(UM_CVM)
    `define S_SKIP     `RAMW(UM_SKIP_PRE)
    `define S_TTR      `RAMW(UM_TT_RESOLVE)
    `define S_DE_SEEN  `RAMW(UM_DE_SEEN)
    `define S_DE_VTS   `RAMW(UM_DE_VTS)
    `define S_DE_PGCN  `RAMW(UM_DE_PGCN)
    `define S_CHAIN    `RAMW(UM_CHAIN)
    `define S_FUSE     dut.u_seq.rf[11]
    `define S_BLK      dut.flags[1:0]
    `define S_NAT      dut.flags[2]
    `define S_USR      dut.flags[3]
    `define S_EVENTS   dut.ev
    `define S_MODE     (dut.u_seq.parked_wait ? 1 : 0)
    `define QUIET      (dut.u_seq.parked && !dut.u_seq.can_dispatch)
    `define TIMER      dut.wait_tmr
    `define WAITING    (dut.u_seq.parked_wait)
`else
    `define S_GPRM(i)  dut.gprm[i]
    `define S_GMODE    dut.gprm_mode
    `define S_SPRM1    dut.sprm1
    `define S_SPRM2    dut.sprm2
    `define S_SPRM3    dut.sprm3
    `define S_SPRM8    dut.sprm8
    `define S_RSM_VTS  dut.rsm_vts
    `define S_RSM_PGCN dut.rsm_pgcn
    `define S_RSM_CELL dut.rsm_cell
    `define S_FB       dut.fb
    `define S_CVM      dut.came_via_menukey
    `define S_SKIP     dut.skip_pre
    `define S_TTR      dut.tt_resolve
    `define S_DE_SEEN  dut.deadend_seen
    `define S_DE_VTS   dut.deadend_vts
    `define S_DE_PGCN  dut.deadend_pgcn
    `define S_CHAIN    dut.chain
    `define S_FUSE     dut.fuse
    `define S_BLK      dut.blk
    `define S_NAT      dut.nat_src
    `define S_USR      dut.usr_edge
    `define S_EVENTS   {dut.ev_return, dut.ev_cmenu, dut.ev_title, dut.ev_menu, dut.ev_chedge, \
                        dut.ev_pgcend, dut.ev_cellcmd, dut.ev_btn, dut.ev_loaded, dut.ev_error, dut.ev_boot}
    `define S_MODE     (dut.state == 4'd10 ? 1 : 0)
    `define QUIET      ((dut.state == 4'd0 && !dut.tick_pending && !dut.clr_busy && `S_EVENTS == 11'd0) || \
                        (dut.state == 4'd10 && !dut.ev_loaded && !dut.ev_error && dut.wait_tmr != 24'hFFFFFF))
    `define TIMER      dut.wait_tmr
    `define WAITING    (dut.state == 4'd10)
`endif

    integer fo, step = 0;
    // ---- pulses and level changes, as they happen (nav_shell's canonical order) ----
    reg [15:0] l1, l2, l3, l8;
    initial begin l1 = 16'd15; l2 = 16'd62; l3 = 16'd1; l8 = 16'h0400; end
    always @(negedge clk) if (rst_n) begin
        if (`S_SPRM1 !== l1) begin l1 = `S_SPRM1; $fwrite(fo, "L %0d sprm1 %04h\n", step, l1); end
        if (`S_SPRM2 !== l2) begin l2 = `S_SPRM2; $fwrite(fo, "L %0d sprm2 %04h\n", step, l2); end
        if (`S_SPRM3 !== l3) begin l3 = `S_SPRM3; $fwrite(fo, "L %0d sprm3 %04h\n", step, l3); end
        if (`S_SPRM8 !== l8) begin l8 = `S_SPRM8; $fwrite(fo, "L %0d sprm8 %04h\n", step, l8); end
        // PREDONE first: when it shares a cycle with a dispatch's first pulse (the old
        // FSM raises both in its V_IDLE cycle), the PRE it reports resolved before that
        // dispatch -- and the sequencer raises it while parked, before the handler runs
        if (pre_done)   $fwrite(fo, "P %0d PREDONE\n", step);
        if (btn_force)  $fwrite(fo, "P %0d BTNF %0d\n", step, btn_force_val);
        if (link_fail)  $fwrite(fo, "P %0d LINKFAIL %0d\n", step, link_fail_pgcn);
        if (jump_pulse) $fwrite(fo, "P %0d JUMP %0d %0d %0d %0d %0d %0d %0d %0d %0d\n", step,
                                jump_domain, jump_vts, jump_pgcn, jump_entry, jump_ttn,
                                jump_pgn, jump_ptt, jump_cell, vm_from_wait);
        if (seek_pulse) $fwrite(fo, "P %0d SEEK %0d %0d\n", step, seek_cell, vm_from_wait);
        if (vm_replay)  $fwrite(fo, "P %0d REPLAY\n", step);
        if (vm_adv)     $fwrite(fo, "P %0d ADV\n", step);
    end

`ifdef VM_NEW
    // the sequencer's own trace (tools/nav_isa.py Machine.trace) and its busy
    // cycles per step (the emulator's CYC model): +trace adds them to the log
    reg trace_on = 0;
    integer busy = 0;
    initial trace_on = $test$plusargs("trace");
    always @(negedge clk) if (rst_n && trace_on && step > 0) begin
        if (dut.u_seq.tr_valid)
            $fwrite(fo, "T %0d %0d %0d %0d %0d\n", step, dut.u_seq.tr_kind, dut.u_seq.tr_pc,
                    dut.u_seq.tr_addr, dut.u_seq.tr_val);
    end
    always @(posedge clk) if (rst_n)
        if ((dut.u_seq.run && !(dut.u_seq.wev_req && !dut.u_seq.ev_valid)) || dut.u_seq.q == 2'd2)
            busy = busy + 1;
`endif

    task dump;
        integer i;
    begin
`ifdef VM_NEW
        if (trace_on) begin $fwrite(fo, "C %0d %0d\n", step, busy); busy = 0; end
`endif
        $fwrite(fo, "S %0d", step);
        for (i = 0; i < 16; i = i + 1) $fwrite(fo, " g%0d=%0h", i, `S_GPRM(i));
        $fwrite(fo, " gmode=%0h sprm1=%0h sprm2=%0h sprm3=%0h", `S_GMODE, `S_SPRM1, `S_SPRM2, `S_SPRM3);
`ifdef VM_NEW
        $fwrite(fo, " sprm4=%0h sprm5=%0h sprm6=%0h sprm7=%0h sprm8=%0h sprm9=%0h sprm10=%0h sprm13=%0h",
                `S_SPRMI(4), `S_SPRMI(5), `S_SPRMI(6), `S_SPRMI(7), `S_SPRM8, `S_SPRMI(9),
                `S_SPRMI(10), `S_SPRMI(13));
        $fwrite(fo, " rsm_vts=%0h rsm_pgcn=%0h rsm_cell=%0h rsm_r4=%0h rsm_r5=%0h rsm_r6=%0h rsm_r7=%0h rsm_r8=%0h",
                `S_RSM_VTS, `S_RSM_PGCN, `S_RSM_CELL, `S_RSM_R(4), `S_RSM_R(5), `S_RSM_R(6),
                `S_RSM_R(7), `S_RSM_R(8));
`else
        $fwrite(fo, " sprm4=%0h sprm5=%0h sprm6=%0h sprm7=%0h sprm8=%0h sprm9=%0h sprm10=%0h sprm13=%0h",
                dut.sprm4, dut.sprm5, dut.sprm6, dut.sprm7, dut.sprm8, dut.sprm9, dut.sprm10, dut.sprm13);
        $fwrite(fo, " rsm_vts=%0h rsm_pgcn=%0h rsm_cell=%0h rsm_r4=%0h rsm_r5=%0h rsm_r6=%0h rsm_r7=%0h rsm_r8=%0h",
                dut.rsm_vts, dut.rsm_pgcn, dut.rsm_cell, dut.rsm_r4, dut.rsm_r5, dut.rsm_r6,
                dut.rsm_r7, dut.rsm_r8);
`endif
        $fwrite(fo, " fb=%0h cvm=%0h skip_pre=%0h tt_resolve=%0h menu_seen=%0h vm_dom=%0h vm_vts=%0h",
                `S_FB, `S_CVM, `S_SKIP, `S_TTR, dut.menu_seen, dut.vm_dom, dut.vm_vts);
        $fwrite(fo, " de_seen=%0h de_vts=%0h de_pgcn=%0h lfsr=%0h frozen=%0h chain=%0h fuse=%0h",
                `S_DE_SEEN, `S_DE_VTS, `S_DE_PGCN, dut.lfsr, dut.sprm8_frozen, `S_CHAIN, `S_FUSE);
        $fwrite(fo, " blk=%0h nat=%0h usr=%0h lm_v=%0h lm_dom=%0h lm_vts=%0h lm_pgcn=%0h events=%0h tick=%0h mode=%0h\n",
                `S_BLK, `S_NAT, `S_USR, dut.last_menu_v, dut.last_menu_dom, dut.last_menu_vts,
                dut.last_menu_pgcn, `S_EVENTS, dut.tick_pending, `S_MODE);
    end
    endtask

    // quiescent for 8 consecutive cycles (pulses drain, pre_done lands)
    task settle;
        integer q, n;
    begin
        q = 0; n = 0;
        while (q < 8) begin
            @(posedge clk); #1;
            q = `QUIET ? q + 1 : 0;
            n = n + 1;
            if (n > 8000000) begin                 // > 4096 commands x the slowest
                $display("FAIL [hang] step %0d never settled", step);
                $fatal(1);
            end
        end
    end
    endtask

    reg [63:0] arg [0:4];
    integer fi, rc, op;
    reg [63:0] a, b;
    reg [8*256-1:0] infile, outfile;
    integer k;

    initial begin
        if (!$value$plusargs("in=%s", infile)) begin $display("FAIL: +in=<ops>"); $fatal(1); end
        if (!$value$plusargs("out=%s", outfile)) begin $display("FAIL: +out=<log>"); $fatal(1); end
        fi = $fopen(infile, "r");
        fo = $fopen(outfile, "w");
        for (k = 0; k < 5; k = k + 1) arg[k] = 0;
        repeat (4) @(posedge clk);
        @(negedge clk) rst_n = 1;
`ifndef VM_NEW
        // The old FSM's reset block never clears these three (ev_menu is cleared, its
        // siblings were missed). Silicon powers them up 0 and a mount clears them; in
        // simulation they would sit at X and `if (X)` never dispatches. Deposit the
        // silicon value -- the oracle's RTL itself stays untouched.
        dut.ev_title = 1'b0; dut.ev_return = 1'b0; dut.ev_cmenu = 1'b0;
        // Likewise its command and program-map RAMs: never written before a read is
        // possible on silicon only because they power up 0.
        for (k = 0; k < 4096; k = k + 1) dut.cmem[k] = 8'd0;
        for (k = 0; k < 128; k = k + 1) dut.pmem[k] = 8'd0;
`endif
        settle;
`ifdef VM_NEW
        busy = 0;                          // the power-on reset is not a step
`endif
        while (!$feof(fi)) begin
            rc = $fscanf(fi, "%h %h %h\n", op, a, b);
            if (rc == 3) begin
                if (op != 7) step = step + 1;
                @(negedge clk);
                case (op)
                1: begin
                    case (a)
                    0: enable = b; 1: cfg_lang = b; 2: cfg_sprm14 = b; 3: cfg_sprm15 = b;
                    4: cfg_sprm20 = b; 5: nav_ready = b; 6: auto_vts = b; 7: best_menu_vts = b;
                    8: res_ttn = b; 9: rnd_seed = b; 10: nr_pre = b; 11: nr_post = b;
                    12: nr_cell = b; 13: nr_pgms = b; 14: menu_active = b; 15: cur_vts = b;
                    16: cur_pgcn = b; 17: cur_cell = b; 18: cell_count = b; 19: next_pgcn = b;
                    20: prev_pgcn = b; 21: goup_pgcn = b; 22: btn_sel = b; 23: btns_armed = b;
                    24: wait_hold = b;
                    default: begin $display("FAIL: input %0d", a); $fatal(1); end
                    endcase
                    settle; dump;
                end
                2: begin
                    for (k = 0; k < 8; k = k + 1) begin
                        cmd_we = 1; cmd_waddr = a * 8 + k; cmd_wdata = b[63 - 8 * k -: 8];
                        @(negedge clk);
                    end
                    cmd_we = 0;
                    settle;
                end
                3: begin
                    pm_we = 1; pm_waddr = a; pm_wdata = b;
                    @(negedge clk); pm_we = 0;
                    settle;
                end
                4: begin
                    pgc_loaded = a[0]; pgc_error = a[1];
                    vm_cell_cmd = a[2]; cell_cmd_nr = arg[0];
                    vm_pgc_end = a[3];
                    btn_cmd_valid = a[4]; btn_cmd = arg[1];
                    key_menu = a[5]; key_title = a[6]; key_return = a[7]; key_cmenu = a[8];
                    key_chedge = a[9]; key_chedge_dir = arg[2];
                    start = a[10]; sec_tick = a[11];
                    entropy_stir = a[12]; entropy_val = arg[3];
                    agl_set = a[13]; agl_set_val = arg[4];
                    @(negedge clk);
                    {pgc_loaded, pgc_error, vm_cell_cmd, vm_pgc_end, btn_cmd_valid, key_menu,
                     key_title, key_return, key_cmenu, key_chedge, start, sec_tick,
                     entropy_stir, agl_set} = 0;
                    settle; dump;
                end
                5: begin
                    if (`WAITING) `TIMER = 24'hFFFFFF;
                    settle; dump;
                end
                6: begin settle; dump; end
                7: arg[a] = b;
                default: begin $display("FAIL: op %0d", op); $fatal(1); end
                endcase
            end
        end
        $fclose(fo);
        $display("PASS: vm_ab_tb ran %0d steps", step);
        $finish;
    end
endmodule
