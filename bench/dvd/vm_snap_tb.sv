// vm_snap_tb.sv -- the VM state snapshot end to end: dvd_vm (the real microcode) and
// dvd/vm_snap.sv, driven over the EXT_BUS protocol as the HPS drives it
// (docs/nav_engine.md "State snapshot"; run by bench/dvd/run_vm_snap.sh).
//
// The A/B (bench/dvd/run_vm_ab.sh) already proves the microcode's side: a snapshot
// changes nothing the VM does, and the words equal the Python model's. This bench
// proves the rest -- that the words reaching the HOST are the VM's state, named as
// tools/nav_isa.py snap_layout() names them, and that the protocol never hands out a
// torn or stale buffer.
//
// ARMS
//   [absent]   0x7D answers MAGIC; a command that shares its low byte (0x017D) does
//              not take the bus
//   [empty]    before any snapshot: seq 0, len 0, busy 0, fmt = USNAP_FMT, no payload
//   [req]      a requesting transaction writes NO snapshot word while it is open; once
//              it ends exactly one snapshot completes: seq 1, busy 0, len USNAP_WORDS
//   [words]    every word = the VM's state by name: data RAM 0x00..0x27, SPRM 0..23 as
//              a command reads it (RAM image | the wrapper's window), input ports 0..31
//   [nochange] the VM's RAM and registers are the same after the snapshot
//   [pos]      the position latched with it: lbn, prev_video, c_eltm, ids; has_video
//              follows 1stref_ea; pos_fresh clears on a flush, sets on a NAV pack
//   [busy]     a request while the VM waits on a jump's verdict waits too: busy = 1,
//              seq unchanged, NO payload streamed; the verdict lets it complete
//   [reread]   the same snapshot read twice gives the same words (the read-ahead)
//
// RESTORE (save states step 3, docs/nav_engine.md §9):
//   [load]     a good blob (the snapshot read back) is checked, taken at rest, and the
//              VM jumps to the saved PGCN / cell / domain; after the landing its GPRMs
//              and RSM equal the blob's; verdict 1 then 2, the restore count moves, and
//              the header no longer claims a snapshot (len 0)
//   [refuse]   a wrong format, length or checksum: verdict 3 / 4 / 5, no restore, the
//              VM's RAM untouched
//   [pending]  a load while a restore is still pending (the VM is waiting on a jump):
//              verdict 6, and the pending blob is not overwritten
//
// EXACT LANDING (docs/nav_engine.md §10):
//   [land]     a load with a time target fires ONE rst_seek_pulse carrying that time and
//              the fallback RBN, at the landing's first NAV pack after its PGC load (or
//              its first picture, if that comes first); none before the load, none
//              without a target, none when a menu landed, none when another PGC loaded
//              first; [pos] also checks the clock / s_ptm / STC latches
//
// THE OSD's SAVE STATE ROWS (save states step 4, docs/nav_engine.md §11):
//   [ui]       word 2 carries {vm_en, slot, load_n, save_n}: each press moves its own
//              2-bit count once (wrapping), the slot is the Slot row AT the press -- a
//              row moved afterwards does not change it -- and vm_en follows enable
//   [menusoff] with Disc Menus off a good blob is refused as verdict 7 and never
//              raises restore_req; back on, the same blob is taken
//
// Run: iverilog -g2012 -I dvd -o /tmp/vs dvd/dvd_vm.sv dvd/vm_snap.sv bench/dvd/vm_snap_tb.sv && vvp /tmp/vs
`timescale 1ns/1ps
`default_nettype none

module vm_snap_tb;
    `include "nav/nav_ucode.svh"
    localparam [15:0] CMD = 16'h007D, MAGIC = 16'h5E02;
    localparam integer HDR = 19;

    reg clk = 0;
    always #5 clk = ~clk;
    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;
    reg rst_n = 0;

    // ---- the VM's inputs ----
    reg        enable = 1, start = 0, nav_ready = 0;
    reg [15:0] cfg_lang = 16'h656E, cfg_sprm14 = 16'h0100, cfg_sprm15 = 16'h7CFC, cfg_sprm20 = 16'h0001;
    reg [7:0]  auto_vts = 8'd3, best_menu_vts = 8'd4;
    reg [6:0]  res_ttn = 7'd5;
    reg [15:0] rnd_seed = 16'hACE1;
    reg        sec_tick = 0, entropy_stir = 0;
    reg [15:0] entropy_val = 0;
    reg        cmd_we = 0; reg [11:0] cmd_waddr = 0; reg [7:0] cmd_wdata = 0;
    reg [7:0]  nr_pre = 0, nr_post = 0, nr_cell = 0, nr_pgms = 8'd7;
    reg        pm_we = 0; reg [6:0] pm_waddr = 0; reg [7:0] pm_wdata = 0;
    reg        pgc_loaded = 0, pgc_error = 0, vm_cell_cmd = 0, vm_pgc_end = 0;
    reg [7:0]  cell_cmd_nr = 0;
    reg        menu_active = 1;
    reg [7:0]  cur_vts = 8'd2, cur_cell = 8'd9, cell_count = 8'd11;
    reg [15:0] cur_pgcn = 16'd6, next_pgcn = 16'd7, prev_pgcn = 16'd5, goup_pgcn = 16'd1;
    reg        key_menu = 0, key_title = 0, key_return = 0, key_cmenu = 0, key_chedge = 0, key_chedge_dir = 0;
    reg [63:0] btn_cmd = 0; reg btn_cmd_valid = 0;
    reg [5:0]  btn_sel = 0; reg btns_armed = 0, wait_hold = 0;
    reg        agl_set = 0; reg [3:0] agl_set_val = 0;
    reg        ptt_upd = 0; reg [10:0] ptt_val = 0;

    // ---- the displayed time's raw parts, and the landing ----
    reg [31:0] eltm = 0, vobu_sptm = 0;
    reg [32:0] stc = 0;
    reg        video_live = 0, mount = 0;
    reg        ui_save = 0, ui_load = 0; reg [1:0] ui_slot = 0;
    wire       rst_seek_pulse; wire [16:0] rst_seek_secs; wire [31:0] rst_seek_rbn;
    // ---- the position ----
    reg        pos_clr = 0, pos_commit = 0;
    reg [31:0] nv_pck_lbn = 0, first_ref_ea = 0, prev_video = 0, c_eltm = 0;
    reg [15:0] vob_idn = 0; reg [7:0] c_idn = 0;

    // ---- EXT_BUS ----
    reg        io_enable = 0, io_strobe = 0;
    reg [15:0] io_din = 0;
    wire       drive; wire [15:0] dout;

    wire        snap_req, snap_we, snap_done; wire [15:0] snap_d, snap_fmt;
    wire        restore_req, rst_done, jump_ttn_hint; wire [6:0] rst_ra; wire [15:0] rst_q;
    wire        jump_pulse; wire [1:0] jump_domain; wire [15:0] jump_pgcn; wire [7:0] jump_cell;
    wire [7:0]  jump_vts; wire [6:0] jump_ttn;

    dvd_vm vm (
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
        .btns_armed(btns_armed), .btn_force(), .btn_force_val(), .hl_btnn(),
        .jump_pulse(jump_pulse), .jump_domain(jump_domain), .jump_vts(jump_vts),
        .jump_pgcn(jump_pgcn), .jump_entry(), .jump_ttn(jump_ttn), .jump_pgn(), .jump_ptt(),
        .jump_cell(jump_cell),
        .seek_pulse(), .seek_cell(), .vm_replay(), .vm_adv(), .vm_from_wait(),
        .wait_hold(wait_hold), .sprm_astn(), .sprm_spstn(), .sprm_agln(), .pre_done(),
        .agl_set(agl_set), .agl_set_val(agl_set_val), .ptt_upd(ptt_upd), .ptt_val(ptt_val),
        .dbg_state(), .dbg_g3(), .dbg_g14_9(), .dbg_rsm(), .dbg_deadend(),
        .link_fail(), .link_fail_pgcn(), .trc_gprm_we(), .trc_gprm_a(), .trc_gprm_d(),
        .snap_req(snap_req), .snap_we(snap_we), .snap_d(snap_d), .snap_done(snap_done),
        .snap_fmt(snap_fmt), .restore_req(restore_req), .rst_ra(rst_ra), .rst_q(rst_q),
        .rst_done(rst_done), .jump_ttn_hint(jump_ttn_hint));

    vm_snap dut (
        .clk(clk), .rst_n(rst_n), .io_enable(io_enable), .io_strobe(io_strobe), .io_din(io_din),
        .drive(drive), .dout(dout), .snap_req(snap_req), .snap_we(snap_we), .snap_d(snap_d),
        .snap_done(snap_done), .snap_fmt(snap_fmt), .restore_req(restore_req), .rst_ra(rst_ra),
        .rst_q(rst_q), .rst_done(rst_done), .pos_clr(pos_clr), .pos_commit(pos_commit),
        .nv_pck_lbn(nv_pck_lbn), .first_ref_ea(first_ref_ea), .prev_video(prev_video),
        .c_eltm(c_eltm), .vob_idn(vob_idn), .c_idn(c_idn),
        .eltm(eltm), .vobu_sptm(vobu_sptm), .stc(stc), .pgc_loaded(pgc_loaded),
        .video_live(video_live), .menu_active(menu_active), .mount(mount),
        .rst_seek_pulse(rst_seek_pulse), .rst_seek_secs(rst_seek_secs), .rst_seek_rbn(rst_seek_rbn),
        .ui_save(ui_save), .ui_load(ui_load), .ui_slot(ui_slot), .vm_en(enable));

    reg drive_seen = 1'b0;
    always @(posedge clk) if (drive === 1'b1) drive_seen <= 1'b1;
    // snapshot words written while a transaction is open (the [req] contract)
    integer we_in_txn = 0;
    always @(posedge clk) if (snap_we === 1'b1 && io_enable) we_in_txn = we_in_txn + 1;

    // ---- verdicts ----
    integer arm_fail, any_fail = 0;
    reg [8*10-1:0] arm_name;
    task begin_arm(input [8*10-1:0] n); begin arm_name = n; arm_fail = 0; end endtask
    task check(input cond, input [8*72-1:0] what); begin
        if (cond !== 1'b1) begin
            if (arm_fail < 6) $display("FAIL [%0s] %0s", arm_name, what);
            arm_fail = arm_fail + 1;
        end
    end endtask
    task end_arm; begin
        if (arm_fail == 0) $display("PASS [%0s]", arm_name);
        else begin $display("FAIL [%0s] (%0d checks)", arm_name, arm_fail); any_fail = 1; end
    end endtask
    task nclk(input integer n); repeat (n) @(negedge clk); endtask

    // ---- one transaction: the command, the control word at strobe 1, then `n` more
    //      words; strobes 3 cycles apart (the module needs >= 2) ----
    reg [15:0] w [0:255];
    reg [15:0] tx [0:255];                 // the host's words from strobe 2 on (a load)
    integer    ntx = 0;
    task txn(input [15:0] cmd, input [15:0] ctl, input integer n); integer k; begin
        @(negedge clk); io_enable = 1; drive_seen = 0; nclk(2);
        io_din = cmd; io_strobe = 1; @(negedge clk); io_strobe = 0; io_din = 0;
        w[0] = dout;
        for (k = 1; k < n; k = k + 1) begin
            nclk(2);
            io_din = (k == 1) ? ctl : (k - 2 < ntx) ? tx[k - 2] : 16'd0;
            io_strobe = 1; @(negedge clk); io_strobe = 0; io_din = 0;
            w[k] = dout;
        end
        nclk(2); io_enable = 0; nclk(3);
    end endtask
    task read_all; txn(CMD, 16'd0, HDR + USNAP_WORDS + 4); endtask
    // request, then wait for the stream; -> the cycles it took
    integer t_req;
    task request; begin
        txn(CMD, 16'd1, 3);
        t_req = cyc;
    end endtask
    task wait_done(input integer limit); integer g; begin
        g = 0;
        while (dut.busy === 1'b1 && g < limit) begin @(negedge clk); g = g + 1; end
    end endtask

    // ---- the expected words, from the VM by name ----
    reg [15:0] exp [0:USNAP_WORDS-1];
    function [15:0] sprm_win(input integer n);
        case (n)
        0, 16, 18: sprm_win = cfg_lang;
        1: sprm_win = vm.sprm1;  2: sprm_win = vm.sprm2;  3: sprm_win = vm.sprm3;
        6: sprm_win = vm.sprm6;  7: sprm_win = vm.sprm7;  8: sprm_win = vm.sprm8_eff;
        12: sprm_win = 16'h5553; 14: sprm_win = cfg_sprm14; 15: sprm_win = cfg_sprm15;
        20: sprm_win = cfg_sprm20;
        default: sprm_win = 16'd0;
        endcase
    endfunction
    task expect_words; integer i; begin
        for (i = 0; i < 40; i = i + 1) exp[i] = vm.u_seq.dram[i];
        for (i = 0; i < 24; i = i + 1) exp[40 + i] = vm.u_seq.dram[UM_SPRMI + i] | sprm_win(i);
        exp[64] = cur_vts;   exp[65] = cur_pgcn;  exp[66] = cur_cell;  exp[67] = cell_count;
        exp[68] = next_pgcn; exp[69] = prev_pgcn; exp[70] = goup_pgcn; exp[71] = nr_pre;
        exp[72] = nr_post;   exp[73] = nr_cell;   exp[74] = nr_pgms;   exp[75] = auto_vts;
        exp[76] = best_menu_vts; exp[77] = res_ttn; exp[78] = menu_active;
        exp[79] = vm.ev_cellcmd_nr; exp[80] = vm.ev_chedge_dir; exp[81] = vm.lfsr;
        exp[82] = vm.vm_dom; exp[83] = vm.vm_vts; exp[84] = vm.menu_seen; exp[85] = vm.last_menu_v;
        exp[86] = vm.last_menu_dom; exp[87] = vm.last_menu_vts; exp[88] = vm.last_menu_pgcn;
        exp[89] = vm.jump_pgcn; exp[90] = vm.ev; exp[91] = 16'd0;
        exp[92] = vm.ev_btn_cmd[63:48]; exp[93] = vm.ev_btn_cmd[47:32];
        exp[94] = vm.ev_btn_cmd[31:16]; exp[95] = vm.ev_btn_cmd[15:0];
    end endtask

    // the VM's state, for [nochange]
    reg [15:0] ram_before [0:255];
    reg [255:0] regs_before;
    wire [255:0] regs_now = {vm.sprm1, vm.sprm2, vm.sprm3, vm.sprm6, vm.sprm7, vm.sprm8,
                             vm.lfsr, vm.last_menu_pgcn, vm.jump_pgcn, 5'd0, vm.ev, vm.flags,
                             vm.vm_dom, vm.vm_vts, vm.menu_seen, vm.last_menu_v, vm.tick_pending,
                             vm.u_seq.rf[7], vm.u_seq.rf[8], vm.u_seq.rf[9], vm.u_seq.rf[10],
                             vm.u_seq.rf[11]};

    integer i, k, n_before, seq0;
    reg ok;
    // ---- restores ----
    reg  [15:0] blob [0:127];
    reg  [15:0] tx2  [0:127];
    reg  [15:0] sum, sum2;
    integer     n_rreq = 0, n_jump = 0, n_seek = 0;
    reg  [16:0] s_secs; reg [31:0] s_rbn;
    always @(posedge clk) if (rst_seek_pulse === 1'b1) begin
        n_seek = n_seek + 1; s_secs = rst_seek_secs; s_rbn = rst_seek_rbn;
    end
    reg  [15:0] j_pgcn; reg [7:0] j_cell; reg [1:0] j_dom;
    always @(posedge clk) begin
        if (restore_req === 1'b1) n_rreq = n_rreq + 1;
        if (jump_pulse === 1'b1) begin
            n_jump = n_jump + 1; j_pgcn = jump_pgcn; j_cell = jump_cell; j_dom = jump_domain;
        end
    end
    // a LOAD: control bit 1, then fmt, len, checksum and the first n words of `blob`
    // `sm` is the blob's sum; the landing's words (ld_tm, ld_rbn) are added to it here,
    // as the host's checksum covers them
    reg [15:0] ld_tm = 16'hFFFF;
    reg [31:0] ld_rbn = 32'd0;
    task load(input [15:0] fmt, input [15:0] ln, input [15:0] sm, input integer n); begin
        tx[0] = fmt; tx[1] = ln; tx[2] = sm + ld_tm + ld_rbn[31:16] + ld_rbn[15:0];
        tx[3] = ld_tm; tx[4] = ld_rbn[31:16]; tx[5] = ld_rbn[15:0];
        for (k = 0; k < n; k = k + 1) tx[6 + k] = blob[k];
        ntx = 6 + n;
        txn(CMD, 16'd2, 2 + ntx);
        ntx = 0;
    end endtask
    task wait_rst(input integer limit); integer g; begin
        g = 0;
        while (dut.rbusy === 1'b1 && g < limit) begin @(negedge clk); g = g + 1; end
        nclk(20);
    end endtask
    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk) rst_n = 1;
        nclk(40);                                    // the microcode's RESET walk

        // ------------------------------------------------------------ [absent]
        begin_arm("absent");
        txn(16'h017D, 16'd0, 4);
        check(drive_seen === 1'b0, "a command sharing 0x7D's low byte took the bus");
        txn(CMD, 16'd0, 4);
        check(drive_seen === 1'b1, "0x7D did not take the bus");
        check(w[0] === MAGIC, "word 0 is not MAGIC");
        end_arm;

        // ------------------------------------------------------------ [empty]
        begin_arm("empty");
        read_all;
        check(w[1] === 16'd0, "seq is not 0 before any snapshot");
        check(w[2] === 16'h4000, "word 2 not {vm_en=1, 0...} before any snapshot");
        check(w[3] === USNAP_FMT, "fmt is not USNAP_FMT");
        ok = 1; for (i = HDR; i < HDR + USNAP_WORDS + 4; i = i + 1) if (w[i] !== 16'd0) ok = 0;
        check(ok, "payload words before any snapshot");
        end_arm;

        // ------------------------------------------------------------ [ui]
        begin_arm("ui");
        ui_slot = 2'd2;
        @(negedge clk) ui_save = 1; @(negedge clk) ui_save = 0;
        ui_slot = 2'd1;                                // moved after the press
        txn(CMD, 16'd0, 4);
        check(w[2][9:8] === 2'd1 && w[2][11:10] === 2'd0, "one save press is not save_n 1, load_n 0");
        check(w[2][13:12] === 2'd2, "the slot is not the row AT the press");
        @(negedge clk) ui_load = 1; @(negedge clk) ui_load = 0;
        txn(CMD, 16'd0, 4);
        check(w[2][11:10] === 2'd1 && w[2][9:8] === 2'd1, "one load press is not load_n 1, save_n unchanged");
        check(w[2][13:12] === 2'd1, "a load press did not latch the slot");
        for (i = 0; i < 3; i = i + 1) begin @(negedge clk) ui_save = 1; @(negedge clk) ui_save = 0; end
        txn(CMD, 16'd0, 4);
        check(w[2][9:8] === 2'd0, "save_n does not wrap at 4");
        check(w[2][14] === 1'b1, "vm_en is not set with enable on");
        check(w[2][15] === 1'b0 && w[2][7:0] === 8'd0, "the presses disturbed busy/len");
        end_arm;
        // put word 2's request fields back to 0 so the arms below read busy/len plainly
        for (i = 0; i < 2; i = i + 1) begin @(negedge clk) ui_load = 1; @(negedge clk) ui_load = 0; end
        @(negedge clk) ui_load = 1; ui_slot = 2'd0; @(negedge clk) ui_load = 0;

        // give the VM a state worth reading: distinct RAM words, SPRMs, wrapper state
        for (i = 0; i < 40; i = i + 1) vm.u_seq.dram[i] = 16'h1000 + i * 16'h0101;
        for (i = 0; i < 24; i = i + 1)
            if (i == 4 || i == 5 || i == 9 || i == 10 || i == 13) vm.u_seq.dram[UM_SPRMI + i] = 16'h4400 + i;
        vm.sprm1 = 16'h0002; vm.sprm2 = 16'h0041; vm.sprm3 = 16'h0003; vm.sprm6 = 16'h0012;
        vm.sprm7 = 16'h0004; vm.sprm8 = 16'h0C00; vm.vm_dom = 2'd2; vm.vm_vts = 8'd2;
        vm.last_menu_pgcn = 16'h0033; vm.ev_btn_cmd = 64'h0123_4567_89AB_CDEF;
        nv_pck_lbn = 32'h0001_5513; first_ref_ea = 32'd0; prev_video = 32'hBFFF_FF3C;
        c_eltm = 32'h0001_1823; vob_idn = 16'd7; c_idn = 8'd4;
        eltm = 32'h0012_51D0; vobu_sptm = 32'h0002_7AC4; stc = 33'h1_0001_2345;
        @(negedge clk) pos_commit = 1; @(negedge clk) pos_commit = 0;
        nclk(4);

        // ------------------------------------------------------------ [req]
        begin_arm("req");
        for (i = 0; i < 256; i = i + 1) ram_before[i] = vm.u_seq.dram[i];
        regs_before = regs_now;
        we_in_txn = 0;
        // ask, and hold the transaction open for 40 strobes (~120 cycles): the stream
        // starts ~6 cycles after a request, so a short transaction would close first
        // and could not see a request that fires early
        txn(CMD, 16'd1, 40);
        check(we_in_txn == 0, "a snapshot word was written while the requesting transaction was open");
        expect_words;                                 // the state it must capture
        wait_done(2000);
        nclk(4);
        check(dut.busy === 1'b0, "the snapshot never completed");
        read_all;
        check(w[1] === 16'd1, "seq is not 1 after one snapshot");
        check(w[2] === {8'h40, 8'd96}, "busy/len is not {0, 96}");
        check(w[3] === USNAP_FMT, "fmt is not USNAP_FMT");
        end_arm;

        // ------------------------------------------------------------ [words]
        begin_arm("words");
        for (i = 0; i < USNAP_WORDS; i = i + 1)
            if (w[HDR + i] !== exp[i]) begin
                check(1'b0, "a word differs from the VM's state");
                $display("      word %0d: got %04h want %04h", i, w[HDR + i], exp[i]);
            end
        ok = 1; for (i = HDR + USNAP_WORDS; i < HDR + USNAP_WORDS + 4; i = i + 1) if (w[i] !== 16'd0) ok = 0;
        check(ok, "words past len are not 0");
        end_arm;

        // ------------------------------------------------------------ [nochange]
        begin_arm("nochange");
        ok = 1; for (i = 0; i < 256; i = i + 1) if (i < UM_T0 || i >= UM_T0 + 8) if (vm.u_seq.dram[i] !== ram_before[i]) ok = 0;
        check(ok, "the snapshot changed the VM's data RAM");
        check(regs_now === regs_before, "the snapshot changed the VM's registers");
        end_arm;

        // ------------------------------------------------------------ [pos]
        begin_arm("pos");
        check(w[4] === 16'b10, "flags not {fresh=1, has_video=0} for a VOBU without a picture");
        check({w[5], w[6]} === 32'h0001_5513, "nv_pck_lbn");
        check({w[7], w[8]} === 32'hBFFF_FF3C, "prev_video");
        check({w[9], w[10]} === 32'h0001_1823, "c_eltm");
        check(w[11] === 16'd7 && w[12] === 16'd4, "vob_idn / c_idn");
        check({w[13], w[14]} === 32'h0012_51D0, "the clock (eltm)");
        check({w[15], w[16]} === 32'h0002_7AC4, "the front VOBU's s_ptm");
        check({w[17], w[18]} === 32'h0001_2345, "the STC's low 32 bits");
        // a flush makes the position stale; a VOBU with a picture sets has_video
        @(negedge clk) pos_clr = 1; @(negedge clk) pos_clr = 0;
        first_ref_ea = 32'd45;
        request; wait_done(2000); nclk(4); read_all;
        check(w[4] === 16'b01, "flags not {fresh=0, has_video=1} after a flush");
        @(negedge clk) pos_commit = 1; @(negedge clk) pos_commit = 0;
        request; wait_done(2000); nclk(4); read_all;
        check(w[4] === 16'b11, "flags not {fresh=1, has_video=1} after a NAV pack");
        end_arm;

        // ------------------------------------------------------------ [reread]
        begin_arm("reread");
        for (i = 0; i < HDR + USNAP_WORDS; i = i + 1) exp[i % USNAP_WORDS] = 16'd0;
        read_all;
        for (i = 0; i < USNAP_WORDS; i = i + 1) exp[i] = w[HDR + i];
        read_all;
        ok = 1; for (i = 0; i < USNAP_WORDS; i = i + 1) if (w[HDR + i] !== exp[i]) ok = 0;
        check(ok, "a second read of the same snapshot differs");
        check(w[HDR] === vm.u_seq.dram[0], "the second read does not start at word 0");
        end_arm;

        // ------------------------------------------------------------ [busy]
        begin_arm("busy");
        // boot: the VM jumps to First Play and waits for the verdict
        @(negedge clk) nav_ready = 1;
        nclk(200);
        check(vm.u_seq.parked_wait === 1'b1, "precondition: the VM is not waiting on a verdict");
        read_all; seq0 = w[1];
        request;
        nclk(400);
        read_all;
        check(w[1] === seq0[15:0], "a snapshot completed while the VM was waiting");
        check(w[2][15] === 1'b1, "busy is not set while the request waits");
        ok = 1; for (i = HDR; i < HDR + USNAP_WORDS; i = i + 1) if (w[i] !== 16'd0) ok = 0;
        check(ok, "a buffer was streamed while busy");
        // the verdict: a PGC with no PRE loads, the VM comes to rest, the snapshot runs
        @(negedge clk) pgc_loaded = 1; @(negedge clk) pgc_loaded = 0;
        wait_done(4000); nclk(4);
        read_all;
        check(w[1] === seq0[15:0] + 16'd1, "the waiting snapshot did not complete at rest");
        check(w[2] === {8'h40, 8'd96}, "busy/len after the waiting snapshot");
        end_arm;

        // ------------------------------------------------------------ restores
        // reach rest in a known place: the [busy] arm left the VM at rest after a load
        nclk(200);
        nav_ready = 0;
        request; wait_done(4000); nclk(4);
        read_all;                                   // the reference snapshot
        for (i = 0; i < USNAP_WORDS; i = i + 1) blob[i] = w[HDR + i];
        // then the VM goes elsewhere: different RAM, a different reader position
        for (i = 0; i < 40; i = i + 1) vm.u_seq.dram[i] = 16'h7700 + i;
        cur_pgcn = 16'd29; cur_cell = 8'd3; cur_vts = 8'd6;

        // ------------------------------------------------------------ [refuse]
        begin_arm("refuse");
        sum = 0; for (i = 0; i < USNAP_WORDS; i = i + 1) sum = sum + blob[i];
        load(USNAP_FMT ^ 16'h0100, 16'd96, sum, USNAP_WORDS); read_all;
        check(w[4][15:13] === 3'd3, "a wrong format is not refused as one");
        load(USNAP_FMT, 16'd95, sum, USNAP_WORDS); read_all;
        check(w[4][15:13] === 3'd4, "a wrong length is not refused as one");
        load(USNAP_FMT, 16'd96, sum, USNAP_WORDS - 1); read_all;
        check(w[4][15:13] === 3'd4, "a short blob is not refused as a length");
        load(USNAP_FMT, 16'd96, sum ^ 16'h0001, USNAP_WORDS); read_all;
        check(w[4][15:13] === 3'd5, "a wrong checksum is not refused as one");
        nclk(400);
        ok = 1; for (i = 0; i < 40; i = i + 1) if (vm.u_seq.dram[i] !== 16'h7700 + i) ok = 0;
        check(ok, "a refused blob changed the VM's RAM");
        check(n_rreq == 0, "a refused blob raised restore_req");
        end_arm;

        // ------------------------------------------------------------ [load]
        begin_arm("load");
        n_jump = 0;
        load(USNAP_FMT, 16'd96, sum, USNAP_WORDS);
        read_all;
        check(w[4][15:13] === 3'd1 || w[4][15:13] === 3'd2, "a good blob is not pending or applied");
        check(w[2][7:0] === 8'd0, "the header still claims a snapshot after a load");
        wait_rst(4000);
        check(n_jump == 1, "the restore did not issue exactly one jump");
        check(j_pgcn === blob[65] && j_cell === blob[66][7:0] && j_dom === blob[82][1:0],
              "the jump is not the saved PGCN / cell / domain");
        // the reader lands: the saved place loads
        cur_pgcn = blob[65]; cur_cell = blob[66][7:0]; cur_vts = blob[64][7:0];
        @(negedge clk) pgc_loaded = 1; @(negedge clk) pgc_loaded = 0;
        nclk(400);
        ok = 1; for (i = 0; i < 16; i = i + 1) if (vm.u_seq.dram[i] !== blob[i]) ok = 0;
        check(ok, "the GPRMs are not the blob's after the landing");
        ok = 1; for (i = UM_RSM_VTS; i <= UM_RSM_R8; i = i + 1)
            if (i != UM_DE_SEEN && i != UM_DE_VTS && i != UM_DE_PGCN && vm.u_seq.dram[i] !== blob[i]) ok = 0;
        check(ok, "RSM is not the blob's after the landing");
        read_all;
        check(w[4][15:13] === 3'd2 && w[4][12:8] === 5'd1, "verdict / restore count not {applied, 1}");
        end_arm;

        // ------------------------------------------------------------ [pending]
        begin_arm("pending");
        // a jump the VM waits on: boot again, no verdict -- the restore cannot run
        @(negedge clk) nav_ready = 1;
        nclk(200);
        check(vm.u_seq.parked_wait === 1'b1, "precondition: the VM is not waiting on a verdict");
        load(USNAP_FMT, 16'd96, sum, USNAP_WORDS); read_all;
        check(w[4][15:13] === 3'd1, "the first load is not pending");
        for (i = 0; i < USNAP_WORDS; i = i + 1) tx2[i] = blob[i];
        for (i = 0; i < USNAP_WORDS; i = i + 1) blob[i] = 16'h5A00 + i;
        sum2 = 0; for (i = 0; i < USNAP_WORDS; i = i + 1) sum2 = sum2 + blob[i];
        load(USNAP_FMT, 16'd96, sum2, USNAP_WORDS); read_all;
        check(w[4][15:13] === 3'd6, "a load over a pending restore is not refused");
        ok = 1; for (i = 0; i < USNAP_WORDS; i = i + 1) if (dut.buf_m[i] !== tx2[i]) ok = 0;
        check(ok, "the pending blob was overwritten");
        end_arm;

        // ------------------------------------------------------------ [land]
        begin_arm("land");
        // finish [pending]: its verdict lets the pending restore (no target) run and land
        @(negedge clk) pgc_loaded = 1; @(negedge clk) pgc_loaded = 0;
        wait_rst(4000);
        @(negedge clk) pgc_loaded = 1; @(negedge clk) pgc_loaded = 0;
        nclk(40); video_live = 1; nclk(40); video_live = 0;
        check(n_seek == 0, "a restore without a time target sought");
        for (i = 0; i < USNAP_WORDS; i = i + 1) blob[i] = tx2[i];
        // (a) a target: one seek, at the landing's first NAV pack after its load
        ld_tm = 16'd123; ld_rbn = 32'h0001_2345; menu_active = 0;
        load(USNAP_FMT, 16'd96, sum, USNAP_WORDS); wait_rst(4000);
        nclk(40); video_live = 1; nclk(10); video_live = 0;
        @(negedge clk) pos_commit = 1; @(negedge clk) pos_commit = 0;
        check(n_seek == 0, "the seek fired before the landing's PGC loaded");
        @(negedge clk) pgc_loaded = 1; @(negedge clk) pgc_loaded = 0;
        nclk(40);
        check(n_seek == 0, "the seek fired before the landing's first NAV pack");
        @(negedge clk) pos_commit = 1; @(negedge clk) pos_commit = 0;
        nclk(4);
        check(n_seek == 1 && s_secs === 17'd123 && s_rbn === 32'h0001_2345,
              "not one seek to the target time with the fallback RBN");
        @(negedge clk) pos_commit = 1; @(negedge clk) pos_commit = 0;
        video_live = 1; nclk(10); video_live = 0;
        check(n_seek == 1, "a second NAV pack or the picture fired the seek again");
        // (a2) no NAV pack before the picture: the picture fires it
        load(USNAP_FMT, 16'd96, sum, USNAP_WORDS); wait_rst(4000);
        @(negedge clk) pgc_loaded = 1; @(negedge clk) pgc_loaded = 0;
        nclk(20); video_live = 1; nclk(10); video_live = 0;
        check(n_seek == 2, "the first picture did not fire the seek as the fallback");
        // (b) a menu landed: no seek
        ld_tm = 16'd200; menu_active = 1;
        load(USNAP_FMT, 16'd96, sum, USNAP_WORDS); wait_rst(4000);
        @(negedge clk) pgc_loaded = 1; @(negedge clk) pgc_loaded = 0;
        nclk(20); video_live = 1; nclk(10); video_live = 0;
        check(n_seek == 2, "a menu landing sought");
        menu_active = 0;
        // (c) another PGC loads before the landing's picture: abandoned
        load(USNAP_FMT, 16'd96, sum, USNAP_WORDS); wait_rst(4000);
        @(negedge clk) pgc_loaded = 1; @(negedge clk) pgc_loaded = 0;
        nclk(20);
        @(negedge clk) pgc_loaded = 1; @(negedge clk) pgc_loaded = 0;
        nclk(20); video_live = 1; nclk(10); video_live = 0;
        check(n_seek == 2, "a seek fired after another PGC loaded first");
        // (d) a mount in between: abandoned
        load(USNAP_FMT, 16'd96, sum, USNAP_WORDS); wait_rst(4000);
        @(negedge clk) mount = 1; @(negedge clk) mount = 0;
        @(negedge clk) pgc_loaded = 1; @(negedge clk) pgc_loaded = 0;
        nclk(20); video_live = 1; nclk(10); video_live = 0;
        check(n_seek == 2, "a seek fired across a mount");
        end_arm;

        // ------------------------------------------------------------ [menusoff]
        begin_arm("menusoff");
        ld_tm = 16'hFFFF; ld_rbn = 32'd0;
        nclk(400);
        n_rreq = 0;
        enable = 0;
        txn(CMD, 16'd0, 4);
        check(w[2][14] === 1'b0, "vm_en still set with Disc Menus off");
        load(USNAP_FMT, 16'd96, sum, USNAP_WORDS); read_all;
        check(w[4][15:13] === 3'd7, "a load with Disc Menus off is not refused as verdict 7");
        nclk(200);
        check(n_rreq == 0, "a load with Disc Menus off raised restore_req");
        enable = 1;
        load(USNAP_FMT, 16'd96, sum, USNAP_WORDS); read_all;
        check(w[4][15:13] === 3'd1 || w[4][15:13] === 3'd2, "with Disc Menus back on the blob is not taken");
        check(n_rreq == 1, "with Disc Menus back on no restore_req");
        end_arm;

        if (any_fail) $display("RESULT: FAIL");
        else $display("RESULT: PASS");
        $finish;
    end
endmodule
