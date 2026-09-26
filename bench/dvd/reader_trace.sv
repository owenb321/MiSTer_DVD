// reader_trace.sv -- bit-identity trace of dvd_iso_reader's output ports.
//
// A SECOND ROOT module, compiled beside any bench that instantiates the reader.
// It never touches the DUT: it reads the reader's output ports hierarchically and
// writes every change to a file, so a refactor of dvd/dvd_iso_reader.sv can be
// proven cycle-identical by diffing the trace of the refactored reader against
// the trace of `main`'s reader on the same bench. Driven by
// bench/dvd/run_reader_regress.sh; see docs/logic_reclaim.md "Branch D".
//
//   iverilog ... -DRTRACE_DUT=iso_reader_tb.dut <bench>.sv bench/dvd/reader_trace.sv
//   vvp sim +RTRACE=out.trace
//
// Why $fmonitor rather than a clocked sampler: $fmonitor prints in the postponed
// region, after every update of the time step has settled, and only when a value
// changed. A sampler on the DUT clock races whatever edge the bench drives its
// stimulus on (benches use both), and a combinational output fed by a bench input
// would then read differently depending on process order -- which a change to the
// reader can reorder. The time stamp comes from the bench's own clocking, which the
// reader cannot move, so identical behaviour gives an identical file.
//
// The vector holds the KEPT ports only: the ports that survive the whole
// feature/reader-slim branch. One trace of `main` therefore serves as the
// baseline for every commit on the branch, including the ones that delete the
// dead debug ports. Adding a port here that `main` lacks breaks the baseline run.
`ifndef RTRACE_DUT
  `define RTRACE_DUT iso_reader_tb.dut
`endif

module reader_trace;
    wire [1023:0] vec = {
        `RTRACE_DUT.tmap_used,        `RTRACE_DUT.tmap_fell,
        `RTRACE_DUT.seek_ack,         `RTRACE_DUT.cur_cell,
        `RTRACE_DUT.cell_ready,       `RTRACE_DUT.cell_seamless,
        `RTRACE_DUT.cur_angle,        `RTRACE_DUT.angle_count,
        `RTRACE_DUT.jump_ack,         `RTRACE_DUT.keep_vbuf,
        `RTRACE_DUT.jump_cross,       `RTRACE_DUT.pgc_loaded,
        `RTRACE_DUT.pgc_error,        `RTRACE_DUT.menu_active,
        `RTRACE_DUT.still_active,     `RTRACE_DUT.cur_vts,
        `RTRACE_DUT.cur_pgcn_o,       `RTRACE_DUT.best_menu_vts,
        `RTRACE_DUT.vm_cell_cmd,      `RTRACE_DUT.vm_pgc_end,
        `RTRACE_DUT.nat_wait_o,       `RTRACE_DUT.nav_ready_o,
        `RTRACE_DUT.auto_vts,         `RTRACE_DUT.cell_count_o,
        `RTRACE_DUT.res_ttn,          `RTRACE_DUT.audio_ntracks,
        `RTRACE_DUT.subp_ntracks,     `RTRACE_DUT.attr_a_fmt,
        `RTRACE_DUT.attr_a_lang,      `RTRACE_DUT.attr_s_lang,
        `RTRACE_DUT.cmd_we,           `RTRACE_DUT.cmd_waddr,
        `RTRACE_DUT.cmd_wdata,        `RTRACE_DUT.cmd_nr_pre,
        `RTRACE_DUT.cmd_nr_post,      `RTRACE_DUT.cmd_nr_cell,
        `RTRACE_DUT.pm_we,            `RTRACE_DUT.pm_waddr,
        `RTRACE_DUT.pm_wdata,         `RTRACE_DUT.cmd_nr_pgm,
        `RTRACE_DUT.cur_pgm,          `RTRACE_DUT.nr_ptt_o,
        `RTRACE_DUT.pgc_playback_time,
        `RTRACE_DUT.next_pgcn,        `RTRACE_DUT.prev_pgcn,
        `RTRACE_DUT.goup_pgcn,        `RTRACE_DUT.cur_cell_start,
        `RTRACE_DUT.cellf_we,         `RTRACE_DUT.cellf_idx,
        `RTRACE_DUT.cellf_rbn,        `RTRACE_DUT.cellf_secs,
        `RTRACE_DUT.cellf_lwe,        `RTRACE_DUT.cellf_last,
        `RTRACE_DUT.title_secs_o,     `RTRACE_DUT.cur_cell_cmdnr,
        `RTRACE_DUT.title_first_rbn,  `RTRACE_DUT.title_last_rbn,
        `RTRACE_DUT.title_start_rbn,  `RTRACE_DUT.title_end_rbn,
        `RTRACE_DUT.menu_ar_wide,     `RTRACE_DUT.title_ar_wide,
        `RTRACE_DUT.sd_lba,           `RTRACE_DUT.sd_rd,
        `RTRACE_DUT.stream_data,      `RTRACE_DUT.stream_valid,
        `RTRACE_DUT.pal_we,           `RTRACE_DUT.pal_waddr,
        `RTRACE_DUT.pal_wdata,        `RTRACE_DUT.pgc_ctl_we,
        `RTRACE_DUT.pgc_ctl_waddr,    `RTRACE_DUT.pgc_ctl_wdata,
        `RTRACE_DUT.pgc_ctl_valid,    `RTRACE_DUT.pgc_dom_tt,
        `RTRACE_DUT.raw_mode_o,       `RTRACE_DUT.cdda_mode_o,
        `RTRACE_DUT.cdda_fs_o,        `RTRACE_DUT.wav_bad_o,
        `RTRACE_DUT.lin_seek_ok_o,    `RTRACE_DUT.lin_blk_o,
        `RTRACE_DUT.debug_active,     `RTRACE_DUT.debug_iso_mode,
        `RTRACE_DUT.debug_play_vtsn
    };

    integer f = 0;
    reg [8*512-1:0] fn;
    initial begin
        if ($value$plusargs("RTRACE=%s", fn)) begin
            f = $fopen(fn, "w");
            if (f == 0) $fatal(1, "reader_trace: cannot open %0s", fn);
            $fmonitor(f, "%0t %h", $time, vec);
        end
    end
endmodule
