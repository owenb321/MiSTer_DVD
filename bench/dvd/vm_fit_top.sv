// vm_fit_top.sv -- the two VMs as emu.sv instantiates them, for tools/fit_unit.sh
// (docs/nav_engine.md "Checkpoint B"): every functional port is a top-level port
// (fit_unit.sh makes them virtual pins) and the dbg_* ports are left OPEN, as emu
// leaves them, so the debug mirrors are pruned here exactly as they are in the core.
//
//   USE_DOCKER=1 tools/fit_unit.sh vm_fit_new "clk=27" dvd/dvd_vm.sv bench/dvd/vm_fit_top.sv
//   USE_DOCKER=1 tools/fit_unit.sh vm_fit_old "clk=27" bench/dvd/ref/dvd_vm_hw.sv bench/dvd/vm_fit_top.sv
`define VM_FIT_PORTS \
    input clk, input rst_n, input enable, input start, input [15:0] cfg_lang, \
    input [15:0] cfg_sprm14, input [15:0] cfg_sprm15, input [15:0] cfg_sprm20, \
    input nav_ready, input [7:0] auto_vts, input [7:0] best_menu_vts, input [6:0] res_ttn, \
    input [15:0] rnd_seed, input sec_tick, input entropy_stir, input [15:0] entropy_val, \
    input cmd_we, input [11:0] cmd_waddr, input [7:0] cmd_wdata, input [7:0] nr_pre, \
    input [7:0] nr_post, input [7:0] nr_cell, input pm_we, input [6:0] pm_waddr, \
    input [7:0] pm_wdata, input [7:0] nr_pgms, input pgc_loaded, input pgc_error, \
    input vm_cell_cmd, input [7:0] cell_cmd_nr, input vm_pgc_end, input menu_active, \
    input [7:0] cur_vts, input [15:0] cur_pgcn, input [7:0] cur_cell, input [7:0] cell_count, \
    input [15:0] next_pgcn, input [15:0] prev_pgcn, input [15:0] goup_pgcn, \
    input key_menu, input key_title, input key_return, input key_cmenu, input key_chedge, \
    input key_chedge_dir, input [63:0] btn_cmd, input btn_cmd_valid, input [5:0] btn_sel, \
    input btns_armed, output btn_force, output [5:0] btn_force_val, output [5:0] hl_btnn, \
    output jump_pulse, output [1:0] jump_domain, output [7:0] jump_vts, \
    output [15:0] jump_pgcn, output [3:0] jump_entry, output [6:0] jump_ttn, \
    output [7:0] jump_pgn, output [9:0] jump_ptt, output [7:0] jump_cell, \
    output seek_pulse, output [7:0] seek_cell, output vm_replay, output vm_adv, \
    output vm_from_wait, input wait_hold, output [7:0] sprm_astn, output [7:0] sprm_spstn, \
    output [7:0] sprm_agln, output pre_done, input agl_set, input [3:0] agl_set_val, \
    output link_fail, output [7:0] link_fail_pgcn

`define VM_FIT_CONN \
    .clk(clk), .rst_n(rst_n), .enable(enable), .start(start), .cfg_lang(cfg_lang), \
    .cfg_sprm14(cfg_sprm14), .cfg_sprm15(cfg_sprm15), .cfg_sprm20(cfg_sprm20), \
    .nav_ready(nav_ready), .auto_vts(auto_vts), .best_menu_vts(best_menu_vts), \
    .res_ttn(res_ttn), .rnd_seed(rnd_seed), .sec_tick(sec_tick), \
    .entropy_stir(entropy_stir), .entropy_val(entropy_val), .cmd_we(cmd_we), \
    .cmd_waddr(cmd_waddr), .cmd_wdata(cmd_wdata), .nr_pre(nr_pre), .nr_post(nr_post), \
    .nr_cell(nr_cell), .pm_we(pm_we), .pm_waddr(pm_waddr), .pm_wdata(pm_wdata), \
    .nr_pgms(nr_pgms), .pgc_loaded(pgc_loaded), .pgc_error(pgc_error), \
    .vm_cell_cmd(vm_cell_cmd), .cell_cmd_nr(cell_cmd_nr), .vm_pgc_end(vm_pgc_end), \
    .menu_active(menu_active), .cur_vts(cur_vts), .cur_pgcn(cur_pgcn), .cur_cell(cur_cell), \
    .cell_count(cell_count), .next_pgcn(next_pgcn), .prev_pgcn(prev_pgcn), \
    .goup_pgcn(goup_pgcn), .key_menu(key_menu), .key_title(key_title), \
    .key_return(key_return), .key_cmenu(key_cmenu), .key_chedge(key_chedge), \
    .key_chedge_dir(key_chedge_dir), .btn_cmd(btn_cmd), .btn_cmd_valid(btn_cmd_valid), \
    .btn_sel(btn_sel), .btns_armed(btns_armed), .btn_force(btn_force), \
    .btn_force_val(btn_force_val), .hl_btnn(hl_btnn), .jump_pulse(jump_pulse), \
    .jump_domain(jump_domain), .jump_vts(jump_vts), .jump_pgcn(jump_pgcn), \
    .jump_entry(jump_entry), .jump_ttn(jump_ttn), .jump_pgn(jump_pgn), .jump_ptt(jump_ptt), \
    .jump_cell(jump_cell), .seek_pulse(seek_pulse), .seek_cell(seek_cell), \
    .vm_replay(vm_replay), .vm_adv(vm_adv), .vm_from_wait(vm_from_wait), \
    .wait_hold(wait_hold), .sprm_astn(sprm_astn), .sprm_spstn(sprm_spstn), \
    .sprm_agln(sprm_agln), .pre_done(pre_done), .agl_set(agl_set), \
    .agl_set_val(agl_set_val), .link_fail(link_fail), .link_fail_pgcn(link_fail_pgcn), \
    .dbg_state(), .dbg_g3(), .dbg_g14_9(), .dbg_rsm(), .dbg_deadend()

module vm_fit_new (`VM_FIT_PORTS);
    dvd_vm u (`VM_FIT_CONN);
endmodule

module vm_fit_old (`VM_FIT_PORTS);
    dvd_vm_hw u (`VM_FIT_CONN);
endmodule
