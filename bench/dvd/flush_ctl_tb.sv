`timescale 1ns/1ps
//
// flush_ctl_tb.sv — trigger-matrix testbench for dvd/flush_ctl.sv.
//
// The flush glue decides which of the three pipeline resets fire on each
// playback event. It lived inline in emu.sv with NO sim coverage, and the
// mid-play mount A/V-desync bug (2026-08-28) lived exactly there: a mount
// fired load_flush + aud_flush but NOT seek_flush, so the decoder played the
// OLD file's buffered VBUF tail against the NEW file's STC anchor — a
// permanent audio lead only a core reload avoided. This TB locks the matrix:
//
//   event                                  load  aud   seek  mount  aud_resync
//   start_streaming (mount)                 x     x     x     x        -
//   start_streaming with keep_vbuf=1        x     x     x     x        -   (ungated!)
//   seek_ack / jump_ack, keep_vbuf=0        x     x     x     -        -
//   seek_ack / jump_ack, keep_vbuf=1        x     -     -     -        -   (menu hop)
//   mode_switch (interlace/film raster)     x     x     x     -        -
//   aud_switch (audio track)                -     -     -     -        x
//
// mount_flush = the decoder soft-reset request (mpeg2video.soft_flush): fires on a
// MOUNT ONLY, never on seeks/jumps/mode switches (those need display continuity).
//
// Plus: reset clears everything; every flush level is exactly 64 cycles;
// pipe_rst_n = rst_n & ~load_flush; aud_rst_n = rst_n & ~aud_flush & ~aud_resync.
//
// Build:
//   iverilog -g2012 -o bench/dvd/flush_ctl_sim \
//       dvd/flush_ctl.sv bench/dvd/flush_ctl_tb.sv
//   vvp bench/dvd/flush_ctl_sim
//
module flush_ctl_tb;

  reg  clk = 0;
  reg  rst_n = 0;
  reg  start_streaming = 0, seek_ack = 0, jump_ack = 0;
  reg  mode_switch = 0, aud_switch = 0, keep_vbuf = 0;
  wire load_flush, aud_flush, aud_resync, seek_flush, mount_flush;
  wire pipe_rst_n, aud_rst_n;

  flush_ctl dut (
    .clk             (clk),
    .rst_n           (rst_n),
    .start_streaming (start_streaming),
    .seek_ack        (seek_ack),
    .jump_ack        (jump_ack),
    .mode_switch     (mode_switch),
    .aud_switch      (aud_switch),
    .keep_vbuf       (keep_vbuf),
    .load_flush      (load_flush),
    .aud_flush       (aud_flush),
    .aud_resync      (aud_resync),
    .seek_flush      (seek_flush),
    .mount_flush     (mount_flush),
    .pipe_rst_n      (pipe_rst_n),
    .aud_rst_n       (aud_rst_n)
  );

  always #10 clk = ~clk;             // 50 MHz-ish; frequency is irrelevant

  integer errors = 0;
  integer n_load, n_aud, n_seek, n_resync, n_mount;

  task fail(input [8*64-1:0] msg);
    begin
      errors = errors + 1;
      $display("FAIL: %0s (t=%0t)", msg, $time);
    end
  endtask

  // Expect all four outputs idle.
  task expect_idle(input [8*64-1:0] ctx);
    begin
      if (load_flush || aud_flush || seek_flush || aud_resync || mount_flush) begin
        $display("  state: load=%b aud=%b seek=%b resync=%b mount=%b", load_flush, aud_flush, seek_flush, aud_resync, mount_flush);
        fail(ctx);
      end
      if (!pipe_rst_n || !aud_rst_n) fail("rst_n outputs not idle-high");
    end
  endtask

  // Pulse one event for exactly one cycle, then measure how many cycles each
  // flush output stays high (counted until all four are low again).
  task pulse_and_measure;
    begin
      n_load = 0; n_aud = 0; n_seek = 0; n_resync = 0; n_mount = 0;
      @(posedge clk);   // event registered here
      // event inputs are cleared by the caller right after this task starts;
      // count the level durations
      begin : count
        integer guard;
        guard = 0;
        forever begin
          @(posedge clk);
          if (load_flush)  n_load   = n_load   + 1;
          if (aud_flush)   n_aud    = n_aud    + 1;
          if (seek_flush)  n_seek   = n_seek   + 1;
          if (aud_resync)  n_resync = n_resync + 1;
          if (mount_flush) n_mount  = n_mount  + 1;
          // reset-derivation invariants hold on every cycle
          if (pipe_rst_n !== (rst_n & ~load_flush))               fail("pipe_rst_n derivation");
          if (aud_rst_n  !== (rst_n & ~aud_flush & ~aud_resync))  fail("aud_rst_n derivation");
          if (!load_flush && !aud_flush && !seek_flush && !aud_resync && !mount_flush) disable count;
          guard = guard + 1;
          if (guard > 300) begin fail("flush level never released"); disable count; end
        end
      end
    end
  endtask

  // One matrix row: fire the event, check which outputs pulsed and that every
  // active output held exactly 64 cycles.
  task check_row(input integer e_load, input integer e_aud,
                 input integer e_seek, input integer e_resync,
                 input integer e_mount,
                 input [8*64-1:0] ctx);
    begin
      if ((e_load   ? n_load   != 64 : n_load   != 0) ||
          (e_aud    ? n_aud    != 64 : n_aud    != 0) ||
          (e_seek   ? n_seek   != 64 : n_seek   != 0) ||
          (e_resync ? n_resync != 64 : n_resync != 0) ||
          (e_mount  ? n_mount  != 64 : n_mount  != 0)) begin
        $display("  got load=%0d aud=%0d seek=%0d resync=%0d mount=%0d, want %0d/%0d/%0d/%0d/%0d x64",
                 n_load, n_aud, n_seek, n_resync, n_mount, e_load, e_aud, e_seek, e_resync, e_mount);
        fail(ctx);
      end
    end
  endtask

  initial begin
    // ---- reset ----
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    expect_idle("outputs not idle after reset release");

    // [1] mount -> ALL THREE flushes (THE 2026-08-28 BUG: pre-fix, seek_flush
    //     stayed 0 here and the old file's VBUF survived into the new file)
    start_streaming = 1;
    fork pulse_and_measure; begin @(posedge clk); start_streaming <= 0; end join
    check_row(1, 1, 1, 0, 1, "[1] mount must fire load+aud+seek+mountrst");

    // [2] mount with keep_vbuf=1 held (stale level from a previous menu hop)
    //     -> STILL all three (the mount terms are ungated by keep_vbuf)
    keep_vbuf = 1;
    start_streaming = 1;
    fork pulse_and_measure; begin @(posedge clk); start_streaming <= 0; end join
    check_row(1, 1, 1, 0, 1, "[2] mount under keep_vbuf must fire all four");
    keep_vbuf = 0;

    // [3] title seek (keep_vbuf=0) -> all three
    seek_ack = 1;
    fork pulse_and_measure; begin @(posedge clk); seek_ack <= 0; end join
    check_row(1, 1, 1, 0, 0, "[3] title seek: trio, NO mount reset");

    // [4] VM jump (keep_vbuf=0, e.g. menu->title Play) -> all three
    jump_ack = 1;
    fork pulse_and_measure; begin @(posedge clk); jump_ack <= 0; end join
    check_row(1, 1, 1, 0, 0, "[4] ~keep_vbuf jump: trio, NO mount reset");

    // [5] menu->menu jump (keep_vbuf=1) -> load_flush ONLY (video tail plays
    //     out, audio rides through: docs/dvd_menu_refinements.md sec.2/5d)
    keep_vbuf = 1;
    jump_ack = 1;
    fork pulse_and_measure; begin @(posedge clk); jump_ack <= 0; end join
    check_row(1, 0, 0, 0, 0, "[5] keep_vbuf jump must fire load only");

    // [6] menu-internal seek (keep_vbuf=1) -> load_flush only
    seek_ack = 1;
    fork pulse_and_measure; begin @(posedge clk); seek_ack <= 0; end join
    check_row(1, 0, 0, 0, 0, "[6] keep_vbuf seek must fire load only");
    keep_vbuf = 0;

    // [7] raster-regime switch (mode_switch, today il_switch) -> all
    //     three (the il_switch full re-sync rule)
    mode_switch = 1;
    fork pulse_and_measure; begin @(posedge clk); mode_switch <= 0; end join
    check_row(1, 1, 1, 0, 0, "[7] mode_switch: trio, NO mount reset");

    // [8] a second mode_switch pulse (e.g. the opposite-direction edge) fires
    //     the same trio again — the counters re-arm cleanly back-to-back
    mode_switch = 1;
    fork pulse_and_measure; begin @(posedge clk); mode_switch <= 0; end join
    check_row(1, 1, 1, 0, 0, "[8] repeat mode_switch: trio, NO mount reset");

    // [9] mode_switch under keep_vbuf=1 (detector flip while a stale menu level
    //     lingers) -> still all three (mode_switch terms ungated by keep_vbuf)
    keep_vbuf = 1;
    mode_switch = 1;
    fork pulse_and_measure; begin @(posedge clk); mode_switch <= 0; end join
    check_row(1, 1, 1, 0, 0, "[9] mode_switch under keep_vbuf: trio only");
    keep_vbuf = 0;

    // [10] audio track switch -> aud_resync ONLY (minimal scope: ring + decoder)
    aud_switch = 1;
    fork pulse_and_measure; begin @(posedge clk); aud_switch <= 0; end join
    check_row(0, 0, 0, 1, 0, "[10] aud_switch must fire aud_resync only");

    // [11] core reset mid-flush clears every counter
    start_streaming = 1;
    @(posedge clk);
    start_streaming <= 0;   // NBA: the DUT must still sample the pulse at this edge
    repeat (5) @(posedge clk);
    if (!load_flush || !seek_flush) fail("[11] setup: flushes not running");
    rst_n = 0;
    @(posedge clk); @(posedge clk);
    #1;
    if (load_flush || aud_flush || seek_flush || aud_resync || mount_flush) fail("[11] reset must clear all counters");
    if (pipe_rst_n || aud_rst_n) fail("[11] rst_n low must drive both rst outputs low");
    rst_n = 1;
    repeat (2) @(posedge clk);
    expect_idle("[11] outputs not idle after reset");

    if (errors == 0) $display("flush_ctl_tb: ALL TESTS PASSED (11 scenarios)");
    else             $fatal(1, "flush_ctl_tb: %0d FAILURE(S)", errors);
    $finish;
  end

endmodule
