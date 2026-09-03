`timescale 1ns/1ps
//
// mode_realign_tb.sv — unit test for dvd/mode_realign.sv (issue #42 leg 1).
//
// A live raster-mode change used to fire the flush trio WITHOUT moving the reader, so the
// decoder resumed mid-VOBU with no GOP boundary and could freeze on a malformed frame.
// The fix turns the mode switch into a reader seek and lets seek_ack drive the trio.
//
// ⚠ THE TRAP THIS BENCH IS BUILT TO AVOID (CLAUDE.md: bench-that-cannot-fail). Every
// expectation below is a COUNT or a VALUE the testbench itself supplied — never a read of
// the DUT's internals and never a copy of an RTL expression. The playhead is driven to a
// distinctive value per scenario, so a DUT that latched the wrong one (at the mode edge
// instead of at the issue, or re-sampled after its own flush cleared nav_dsi) is visible.
// The pre-fix behaviour is modelled alongside and selected by +realign=0, and it MUST FAIL
// scenarios [1], [3] and [7].
//
// ⚠ TIMING DISCIPLINE: all stimulus is driven from the NEGEDGE and all sampling/counting
// from the posedge. Driving a blocking assignment at the posedge itself is a race between
// this process and the DUT's, and it silently read as "nothing ever happened" -- every
// count came back 0 and the first version of this bench failed all eleven scenarios
// against correct RTL.
//
// Build/run: bench/dvd/run_mode_realign.sh   (or, standalone)
//   iverilog -g2012 -o bench/dvd/mode_realign_sim \
//       dvd/mode_realign.sv bench/dvd/mode_realign_tb.sv
//   vvp bench/dvd/mode_realign_sim             # GREEN
//   vvp bench/dvd/mode_realign_sim +realign=0  # RED — failures EXPECTED
//
module mode_realign_tb;

  localparam [23:0] WDOG      = 24'd200;   // sim-scale watchdog
  localparam [25:0] BLANK_MAX = 26'd300;   // sim-scale blank ceiling

  reg clk = 0, rst_n = 0;
  reg mode_edge = 0;
  reg in_title = 1, dvd_mode = 1, lin_mode = 0;
  reg still_active = 0, hold_freeze = 0;
  reg nav_flush = 0, dsi_commit = 0, dsi_stream = 0;
  reg [31:0] dsi_nv_pck_lbn = 32'd0;
  reg [31:0] lin_blk = 32'd0;
  reg seek_ack = 0, jump_ack = 0, keep_vbuf = 0, start_streaming = 0;
  reg scrub_pulse = 0;
  reg [31:0] scrub_rbn = 32'd0;
  reg video_live = 1, blank_en = 1;

  wire        dut_sp;
  wire [31:0] dut_srbn;
  wire        dut_ms, realign_pend, sw_blank;

  integer realign = 1;                   // 1 = the fixed module, 0 = the pre-fix path

  mode_realign #(.WDOG(WDOG), .BLANK_MAX(BLANK_MAX)) dut (
    .clk(clk), .rst_n(rst_n),
    .mode_edge(mode_edge),
    .in_title(in_title), .dvd_mode(dvd_mode), .lin_mode(lin_mode),
    .still_active(still_active), .hold_freeze(hold_freeze),
    .nav_flush(nav_flush), .dsi_commit(dsi_commit), .dsi_stream(dsi_stream),
    .dsi_nv_pck_lbn(dsi_nv_pck_lbn), .lin_blk(lin_blk),
    .seek_ack(seek_ack), .jump_ack(jump_ack), .keep_vbuf(keep_vbuf),
    .start_streaming(start_streaming),
    .video_live(video_live), .blank_en(blank_en),
    .scrub_pulse(scrub_pulse), .scrub_rbn(scrub_rbn),
    .seek_rbn_pulse(dut_sp), .seek_rbn(dut_srbn),
    .mode_switch(dut_ms), .realign_pend(realign_pend), .sw_blank(sw_blank)
  );

  // ---- the PRE-FIX path: `wire mode_switch = il_switch;` and scrub_ctrl as the only
  //      producer of the reader's RBN-seek port. Registered once so the two arms are
  //      counted on the same footing.
  reg legacy_ms;
  always @(posedge clk) legacy_ms <= rst_n ? mode_edge : 1'b0;

  wire        eff_sp   = realign[0] ? dut_sp   : scrub_pulse;
  wire [31:0] eff_srbn = realign[0] ? dut_srbn : scrub_rbn;
  wire        eff_ms   = realign[0] ? dut_ms   : legacy_ms;

  always #5 clk = ~clk;

  integer errors = 0;
  integer n_sp = 0, n_ms = 0;
  reg [31:0] last_srbn = 32'hFFFF_FFFF;

  task fail(input [8*76-1:0] msg);
    begin errors = errors + 1; $display("FAIL: %0s  (t=%0t)", msg, $time); end
  endtask

  // Global invariant: a seek to RBN 0 is the stale-playhead trap landing on the start of
  // the title. Nothing in this bench ever legitimately targets 0.
  always @(posedge clk) begin
    if (eff_sp) begin
      n_sp      = n_sp + 1;
      last_srbn = eff_srbn;
      if (eff_srbn == 32'd0) fail("a seek was issued against a STALE (zero) playhead");
    end
    if (eff_ms) n_ms = n_ms + 1;
  end

  // ---- reader model: acknowledge a seek after ack_lat cycles ------------------------
  integer ack_lat = 6;
  reg     ack_en  = 1;
  reg     ack_keep = 0;
  always @(posedge clk) begin
    if (eff_sp && ack_en) begin
      repeat (ack_lat) @(posedge clk);
      keep_vbuf <= ack_keep;
      seek_ack  <= 1'b1;
      @(posedge clk);
      seek_ack  <= 1'b0;
    end
  end

  task clr;  begin @(negedge clk); n_sp = 0; n_ms = 0; last_srbn = 32'hFFFF_FFFF; end endtask

  task chk_counts(input integer wsp, input integer wms, input [8*76-1:0] msg);
    begin
      if (n_sp !== wsp || n_ms !== wms) begin
        $display("  seeks=%0d flushes=%0d, want %0d/%0d", n_sp, n_ms, wsp, wms);
        fail(msg);
      end
    end
  endtask

  task chk_tgt(input [31:0] want, input [8*76-1:0] msg);
    begin
      if (last_srbn !== want) begin
        $display("  target=%0d, want %0d", last_srbn, want);
        fail(msg);
      end
    end
  endtask

  task wait_n(input integer n); begin repeat (n) @(negedge clk); end endtask

  task chk_blank(input want, input [8*76-1:0] msg);
    begin
      if (sw_blank !== want) begin
        $display("  sw_blank=%0b, want %0b", sw_blank, want);
        fail(msg);
      end
    end
  endtask

  task edge_pulse; begin mode_edge = 1; @(negedge clk); mode_edge = 0; @(negedge clk); end endtask

  // A DSI packet finished parsing and left this VOBU NAV-pack RBN in force.
  task commit_lbn(input [31:0] v);
    begin
      dsi_stream = 1; dsi_nv_pck_lbn = v; repeat (2) @(negedge clk);
      dsi_stream = 0; dsi_commit = 1;     @(negedge clk);
      dsi_commit = 0;                     @(negedge clk);
    end
  endtask

  task flush_pulse; begin nav_flush = 1; repeat (3) @(negedge clk); nav_flush = 0; @(negedge clk); end endtask

  task do_reset;
    begin
      rst_n = 0; mode_edge = 0; in_title = 1; dvd_mode = 1; lin_mode = 0;
      still_active = 0; hold_freeze = 0; nav_flush = 0; dsi_commit = 0; dsi_stream = 0;
      start_streaming = 0; scrub_pulse = 0; ack_en = 1; ack_lat = 6; ack_keep = 0;
      video_live = 1; blank_en = 1;
      repeat (4) @(negedge clk);
      rst_n = 1;
      repeat (2) @(negedge clk);
    end
  endtask

  initial begin
    if (!$value$plusargs("realign=%d", realign)) realign = 1;
    $display("mode_realign_tb: %0s path", realign[0] ? "FIXED" : "PRE-FIX (+realign=0)");

    do_reset;
    commit_lbn(32'd5000);

    // ============================================================= [1]
    // A mode switch on a title with a trustworthy playhead issues ONE seek at that
    // playhead and NO in-place flush. This is the whole fix.
    clr;
    edge_pulse;
    repeat (20) @(negedge clk);
    chk_counts(1, 0, "[1] a title mode switch must seek, not flush in place");
    chk_tgt(32'd5000, "[1] the seek target must be the live playhead");

    // ============================================================= [2]
    // The reader's ack completes the arm (and it is the ack that drove the trio).
    repeat (10) @(negedge clk);
    if (realign[0] && realign_pend) fail("[2] the arm must clear on the reader's ack");
    chk_counts(1, 0, "[2] no fallback flush after a successful re-align");

    // ============================================================= [3]
    // If the reader never acknowledges, the mode change must still get its flush.
    ack_en = 0;
    commit_lbn(32'd6100);
    clr;
    edge_pulse;
    repeat (WDOG/4) @(negedge clk);
    chk_counts(1, 0, "[3a] must not fall back before the watchdog elapses");
    repeat (WDOG + 40) @(negedge clk);
    chk_counts(1, 1, "[3b] an unacknowledged seek must fall back to the in-place trio");
    ack_en = 1;

    // ============================================================= [4]  control
    // A disc menu: no re-align possible (the reader's VOBU snap is bypassed there), so
    // this is today's behaviour exactly. Must pass in BOTH arms.
    in_title = 0;
    clr;
    edge_pulse;
    repeat (20) @(negedge clk);
    chk_counts(0, 1, "[4] a menu-domain switch must flush in place, immediately");
    in_title = 1;

    // ============================================================= [5]  control
    // A raw .m2v elementary stream: not seekable at all.
    dvd_mode = 0; lin_mode = 0;
    clr;
    edge_pulse;
    repeat (20) @(negedge clk);
    chk_counts(0, 1, "[5] an unseekable stream must flush in place, immediately");
    dvd_mode = 1;

    // ============================================================= [6]
    // THE STALE-TABLE TRAP. nav_dsi is on pipe_rst_n, so a flush clears the playhead to
    // 0; seeking against that lands at the start of the title. The arm must WAIT for a
    // freshly parsed DSI and then seek THAT — the global invariant above catches a 0.
    flush_pulse;
    dsi_nv_pck_lbn = 32'd0;
    clr;
    edge_pulse;
    repeat (30) @(negedge clk);
    chk_counts(0, 0, "[6a] must not seek while the playhead is stale");
    commit_lbn(32'd7350);
    repeat (20) @(negedge clk);
    chk_counts(1, 0, "[6b] must seek once the playhead is fresh again");
    chk_tgt(32'd7350, "[6c] the target must be the FRESH playhead");

    // ============================================================= [7]  ** RED **
    // COALESCING. il_eff is a level, so N toggles converge on one raster and need exactly
    // ONE re-align. The pre-fix path fires the trio five times, mid-parse, which is the
    // repeated-flush loop class that killed the film edge (docs/film_24p_plan.md §13).
    commit_lbn(32'd8000);
    clr;
    edge_pulse; edge_pulse; edge_pulse; edge_pulse; edge_pulse;
    repeat (WDOG + 60) @(negedge clk);
    if (n_sp > 1 || n_ms > 1) begin
      $display("  seeks=%0d flushes=%0d, want at most 1/1", n_sp, n_ms);
      fail("[7] five mode edges must coalesce into ONE re-align and ONE flush");
    end

    // ============================================================= [8]
    // The user's own scrub outranks ours: the reader must latch the SCRUB's target, and
    // the arm completes on that seek rather than issuing a second one.
    commit_lbn(32'd9000);
    clr;
    mode_edge = 1; @(negedge clk); mode_edge = 0;
    scrub_rbn = 32'd12345; scrub_pulse = 1; @(negedge clk); scrub_pulse = 0;
    repeat (30) @(negedge clk);
    chk_counts(1, 0, "[8a] a scrub during the arm must not add a second seek");
    chk_tgt(32'd12345, "[8b] the scrub's target must win the mux");

    // ============================================================= [9]
    // A mount supersedes: it fires its own trio AND the decoder soft reset, and our
    // latched target belongs to the previous disc.
    ack_en = 0;
    commit_lbn(32'd9500);
    clr;
    in_title = 0;                          // a mount unloads the title first
    edge_pulse;                            // (fallback path) -- then re-arm properly
    in_title = 1; commit_lbn(32'd9600);
    clr;
    mode_edge = 1; @(negedge clk); mode_edge = 0;
    start_streaming = 1; @(negedge clk); start_streaming = 0;
    repeat (WDOG + 60) @(negedge clk);
    chk_counts(0, 0, "[9] a mount during the arm must cancel it silently");
    ack_en = 1;

    // ============================================================= [10]
    // Linear playback (raw VCD/SVCD .bin, flat .mpg): the base is the linear block.
    dvd_mode = 0; lin_mode = 1; lin_blk = 32'd4242;
    clr;
    edge_pulse;
    repeat (20) @(negedge clk);
    chk_counts(1, 0, "[10a] a linear-file mode switch must also re-align");
    chk_tgt(32'd4242, "[10b] the linear target must be the linear playhead");
    dvd_mode = 1; lin_mode = 0;

    // ============================================================= [11]
    // A held Fast Fwd / Rewind is not a timeout — its release issues the seek that
    // satisfies the arm. Spending the watchdog during the hold would fire the in-place
    // flush mid-gesture, which is the thing being removed.
    commit_lbn(32'd11000);
    clr;
    hold_freeze = 1;
    edge_pulse;
    repeat (WDOG*3) @(negedge clk);
    chk_counts(0, 0, "[11a] a held scrub must not spend the fallback watchdog");
    hold_freeze = 0;
    scrub_rbn = 32'd11500; scrub_pulse = 1; @(negedge clk); scrub_pulse = 0;
    repeat (30) @(negedge clk);
    chk_counts(1, 0, "[11b] the release seek must satisfy the arm");
    chk_tgt(32'd11500, "[11c] the release target must be the scrub's");

    // =====================================================================
    // THE SWITCH BLANK. Tested against the DUT directly and NOT through the eff_*
    // muxes: it is new behaviour with no pre-fix counterpart, so there is nothing for
    // a +realign=0 arm to disagree with. What these lock is the WINDOW's two endpoints.
    // =====================================================================
    do_reset;
    commit_lbn(32'd20000);

    // ============================================================= [12]
    // The normal path: blank on the edge, clear on the first video_live HIGH *after*
    // it has been seen LOW (our own flush re-arms it). Modelled explicitly here.
    ack_en = 0;                            // drive the timeline by hand
    chk_blank(1'b0, "[12a] no blank before the switch");
    edge_pulse;
    chk_blank(1'b1, "[12b] the edge must start the blank");
    video_live = 0; wait_n(8);             // the flush lands: video_live re-arms
    chk_blank(1'b1, "[12c] blank must hold while no frame is displayed");
    video_live = 1; wait_n(4);
    chk_blank(1'b0, "[12d] the first new-mode frame must clear the blank");

    // ============================================================= [13]  ** the trap **
    // ⚠ At the edge itself video_live is STILL HIGH (from the old content — the flush
    // lands a few ms later). A naive "clear when video_live" would clear immediately and
    // blank nothing at all. Requiring the LOW first is what makes the window real.
    wait_n(4);
    edge_pulse;
    wait_n(BLANK_MAX/3);                   // video_live left HIGH throughout
    chk_blank(1'b1, "[13] a still-high video_live must NOT clear the blank early");
    video_live = 0; wait_n(4); video_live = 1; wait_n(4);
    chk_blank(1'b0, "[13b] ...and the drop-then-rise still clears it");

    // ============================================================= [14]
    // THE MENU PATH. emu forces the STD mux-lead hold off while a menu is up, so
    // pickup_hold never rises and video_live never re-arms: the timeout is the ONLY exit.
    // It also bounds the fix so it can never mask a persistent fault.
    wait_n(4);
    edge_pulse;
    wait_n(BLANK_MAX - 20);
    chk_blank(1'b1, "[14a] blank must still be up just before the ceiling");
    wait_n(60);
    chk_blank(1'b0, "[14b] the ceiling must release the blank with video_live stuck high");

    // ============================================================= [15]
    // Never blank before the first mount: the boot-time edge (il_eff_q resets to 0, so an
    // Interlaced rig pulses one at reset release) would otherwise black the idle screen
    // for the whole ceiling -- the launch-feedback regression docs/idle_screen.md exists
    // to prevent.
    blank_en = 0;
    wait_n(4);
    edge_pulse;
    wait_n(30);
    chk_blank(1'b0, "[15] blank_en low must suppress the blank entirely");
    blank_en = 1;

    // ============================================================= [16]
    // A second edge mid-blank RESTARTS the window. The seek arm coalesces; the blank must
    // not, or the second toggle uncovers the transient it just caused.
    wait_n(4);
    edge_pulse;
    wait_n(BLANK_MAX - 40);
    edge_pulse;                            // re-trigger
    wait_n(BLANK_MAX - 40);
    chk_blank(1'b1, "[16] a second edge must restart the blank window, not ride the old one");
    video_live = 0; wait_n(4); video_live = 1; wait_n(4);
    chk_blank(1'b0, "[16b] ...and it still clears normally");

    // ============================================================= [17]
    // A mount cuts to black and cold-starts on its own; holding a blank across it would
    // only delay the new disc's first frame.
    wait_n(4);
    edge_pulse;
    chk_blank(1'b1, "[17a] setup: blank is up");
    start_streaming = 1; wait_n(1); start_streaming = 0; wait_n(4);
    chk_blank(1'b0, "[17b] a mount must clear the blank");
    ack_en = 1;

    if (errors == 0) $display("mode_realign_tb: ALL TESTS PASSED (17 scenarios)");
    else begin
      $display("mode_realign_tb: %0d FAILURE(S)", errors);
      $fatal(1, "mode_realign_tb FAILED");
    end
    $finish;
  end

endmodule
