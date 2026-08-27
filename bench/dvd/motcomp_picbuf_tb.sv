`timescale 1ns/1ps
/*
 * motcomp_picbuf_tb.sv — does the decoder ever write into the frame slot the
 * DISPLAY is currently scanning out?
 *
 * The pixelated-menu-still bug. motcomp_picbuf hands the VLD a decode target
 * (current_frame) and tells resample which slot to show (output_frame). A
 * handshake in STATE_IP_FRAME_0 exists precisely to stop those aliasing —
 * its own comment says "don't overwrite a picture which still needs to be
 * displayed". At a sequence_end_code that handshake is bypassed:
 *
 *   1. STATE_UPDATE with vld_last_frame=1 guards current_frame and
 *      prev_i_p_frame, but NOT the fwd/bwd reference swap (:322/:327), so the
 *      slot pointers rotate one extra step.
 *   2. STATE_LAST_FRAME emits prev_i_p_frame for display and clears
 *      prev_i_p_frame_valid.
 *   3. The next sequence's first I gets current_frame <= forward_reference_frame
 *      — which the extra swap has just made equal to the displayed slot.
 *   4. The I/P emit branch sets output_frame_valid <= prev_i_p_frame_valid = 0,
 *      so STATE_IP_FRAME_0's `~output_frame_valid` shortcut releases the VLD
 *      immediately, and the new picture paints into the slot on screen.
 *
 * MEASURED on the real Harry Potter Interactive DVD (HOGWARTS CHALLENGE):
 * every still cell is `SEQ GOP PIC:I SEQ_END` with the B7 ending a video PES
 * (so ps_demux's S_VID_FLUSH filler fires and the VLD really does reach
 * STATE_SEQUENCE_END), while every video/transition cell ends on a coded B.
 * So a STILL arms the collision for whatever decodes next -> still->still menu
 * navigation collides every time; video->still does not. Scenarios A and B
 * below are exactly those two measured shapes.
 *
 * The first link of that chain was verified against the REAL disc bytes rather
 * than by reading the demux source. bench/dvd/test_vobs/ is gitignored, so
 * regenerate the fixture locally from the Harry Potter Interactive DVD image in
 * your own disc library: demux stream_id 0xE0 out of the 9 sectors at
 * VTS_04_1.VOB RBN 319831..319839 (the still_time=255 cell), append the 24 filler
 * bytes dvd/ps_demux.sv's S_VID_FLUSH emits after a 000001B7 at a PES end, and
 * write it as 64-bit big-endian $readmemh words. Then:
 *   vvp bench/dvd/vld_drop_rff_sim +ES=bench/dvd/test_vobs/hp_still_i.hex
 * emits exactly one frame at picture 0 -- i.e. STATE_SEQUENCE_END really is
 * reached and last_frame really does fire on this disc's stills. (Observed
 * 2026-08-26: "EMIT n=1 at_pic=0".)
 *
 * Build:
 *   iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/motcomp_picbuf_sim \
 *       rtl/mpeg2/motcomp_picbuf.v bench/dvd/motcomp_picbuf_tb.sv
 *   vvp bench/dvd/motcomp_picbuf_sim [+SCAN=n] [+VERBOSE=1]
 */

module motcomp_picbuf_tb;

  reg clk = 0; always #5 clk = ~clk;
  reg rst = 0;                       // synchronous, ACTIVE LOW

`include "vld_codes.v"

  // picbuf's own state encoding (parameters are not visible through the
  // hierarchical reference, so mirror the ones the checker needs)
  localparam [3:0] ST_IP_FRAME_1 = 4'h3,
                   ST_B_FRAME_0  = 4'h4,
                   ST_LAST_FRAME = 4'h6;

  integer SCAN    = 40;              // display scan-out length, in clocks
  integer VERBOSE = 0;

  // ---------------- DUT ----------------
  reg  [2:0] picture_coding_type = I_TYPE;
  reg        last_frame = 1'b0;
  reg        update_picture_buffers = 1'b0;
  reg        output_frame_rd = 1'b0;

  wire [2:0] fwd, bwd, current_frame, output_frame;
  wire       output_frame_valid, picbuf_busy;

  motcomp_picbuf dut (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .source_select(3'd0),
    .progressive_sequence(1'b1), .progressive_frame(1'b1),
    .top_field_first(1'b1), .repeat_first_field(1'b0),
    .last_frame(last_frame),
    .picture_coding_type(picture_coding_type),
    .forward_reference_frame(fwd), .backward_reference_frame(bwd),
    .current_frame(current_frame),
    .output_frame(output_frame), .output_frame_valid(output_frame_valid),
    .output_frame_rd(output_frame_rd),
    .output_progressive_sequence(), .output_progressive_frame(),
    .output_top_field_first(), .output_repeat_first_field(),
    .update_picture_buffers(update_picture_buffers),
    .picbuf_busy(picbuf_busy),
    .flags_commit(1'b0)
    );

  // ---------------- display model ----------------
  // Mirrors dvd/resample_addrgen.v: pickup is gated on output_frame_valid
  // (:543 ofv_pickup, :598), the picked-up slot is latched (:1065
  // output_frame_sav) and then PERSISTENCE-re-scanned every refresh while
  // nothing new decodes — so disp_held never drops once set.
  reg  [2:0] disp_slot = 3'd0;
  reg        disp_held = 1'b0;
  integer    scan_cnt  = 0;
  integer    pickups   = 0;
  reg        gov_ack   = 1'b0;

  always @(posedge clk)
    if (~rst) begin
      output_frame_rd <= 1'b0; gov_ack <= 1'b0; scan_cnt <= 0; disp_held <= 1'b0;
    end else begin
      output_frame_rd <= 1'b0;
      if (~gov_ack && output_frame_valid) begin
        if (scan_cnt < SCAN) scan_cnt <= scan_cnt + 1;
        else begin
          scan_cnt        <= 0;
          disp_slot       <= output_frame;
          disp_held       <= 1'b1;
          pickups         <= pickups + 1;
          output_frame_rd <= 1'b1;
          gov_ack         <= 1'b1;
        end
      end else if (gov_ack && ~output_frame_valid) gov_ack <= 1'b0;
    end

  // ---------------- the invariant ----------------
  // Checked on the cycles picbuf releases the VLD to write macroblocks.
  // STATE_LAST_FRAME also drops picbuf_busy, but no macroblocks can follow it
  // before the next update_picture_buffers, so it is deliberately excluded —
  // without that mask the bench false-fails on every sequence end.
  integer fails = 0;
  integer checks = 0;

  always @(posedge clk)
    if (rst && ((dut.state == ST_IP_FRAME_1) || (dut.state == ST_B_FRAME_0))) begin
      checks = checks + 1;
      if (disp_held && (current_frame == disp_slot)) begin
        fails = fails + 1;
        $display("  FAIL t=%0t: VLD released to decode into slot %0d while the display is scanning slot %0d  (fwd=%0d bwd=%0d ofv=%0d)",
                 $time, current_frame, disp_slot, fwd, bwd, output_frame_valid);
      end
    end

  always @(posedge clk)
    if (rst && (fwd == bwd)) begin
      fails = fails + 1;
      $display("  FAIL t=%0t: forward_reference_frame == backward_reference_frame == %0d", $time, fwd);
    end

  // ---------------- VLD model ----------------
  // motcomp.v:265-268 freezes the VLD while picbuf_busy, so a picture is never
  // announced while the previous one is still being placed.
  task push(input [2:0] ptype, input lastf);
    begin
      wait (picbuf_busy == 1'b0); @(posedge clk);
      picture_coding_type    <= ptype;
      last_frame             <= lastf;
      update_picture_buffers <= 1'b1;
      @(posedge clk);
      update_picture_buffers <= 1'b0;
      wait (picbuf_busy == 1'b0);           // released -> "decoding macroblocks"
      repeat (20) @(posedge clk);
      if (VERBOSE)
        $display("    push %s%s -> current=%0d fwd=%0d bwd=%0d out=%0d disp=%0d",
                 (ptype==I_TYPE)?"I":(ptype==P_TYPE)?"P":"B", lastf?" +SEQ_END":"",
                 current_frame, fwd, bwd, output_frame, disp_slot);
    end
  endtask

  task wait_pickup(input integer n);       // let the display latch what was emitted
    begin : wp
      integer target; target = pickups + n;
      fork
        begin wait (pickups >= target); end
        begin repeat (20*SCAN + 2000) @(posedge clk); end
      join_any
      disable fork;
    end
  endtask

  task reset_dut;
    begin
      rst = 1'b0; disp_held = 1'b0; disp_slot = 3'd0;
      repeat (4) @(posedge clk);
      rst = 1'b1; @(posedge clk);
    end
  endtask

  integer f0;
  integer sc;
  initial begin
    if (!$value$plusargs("SCAN=%d", SCAN))       SCAN = 40;
    if (!$value$plusargs("VERBOSE=%d", VERBOSE)) VERBOSE = 0;

    // ---- A: still -> still (the MEASURED Harry Potter shape) ----------------
    // Each still cell is SEQ GOP PIC:I SEQ_END. The seq_end update pulse carries
    // the retained coding type of the last coded picture, which for a still is I.
    reset_dut; f0 = fails;
    $display("[A] still -> still   (SEQ,I,SEQ_END then SEQ,I,SEQ_END)");
    push(I_TYPE, 1'b0);          // the still's single I picture
    push(I_TYPE, 1'b1);          // sequence_end_code
    wait_pickup(1);              // the still is now on screen, reader parked
    push(I_TYPE, 1'b0);          // the NEXT still's I  <-- collides pre-fix
    wait_pickup(1);
    $display("[A] %s  (%0d new failures)", (fails==f0)?"pass":"FAIL", fails-f0);

    // ---- B: video -> still (control; measured transition cells end on a B) ---
    reset_dut; f0 = fails;
    $display("[B] video -> still   (I,B,B,P,B,B,SEQ_END-carrying-B then still I)");
    push(I_TYPE, 1'b0);
    push(B_TYPE, 1'b0); push(B_TYPE, 1'b0);
    push(P_TYPE, 1'b0);
    push(B_TYPE, 1'b0); push(B_TYPE, 1'b0);
    push(B_TYPE, 1'b1);          // seq_end, retained type = B -> swap must NOT fire
    wait_pickup(1);
    push(I_TYPE, 1'b0);
    wait_pickup(1);
    $display("[B] %s  (%0d new failures)", (fails==f0)?"pass":"FAIL", fails-f0);

    // ---- C: cold boot must not stall (guards the rejected IP_FRAME_0 change) --
    reset_dut; f0 = fails;
    $display("[C] cold boot        (first I after reset must release the VLD)");
    fork
      begin push(I_TYPE, 1'b0); end
      begin
        repeat (500) @(posedge clk);
        fails = fails + 1;
        $display("  FAIL: picbuf_busy never dropped for the first picture — DEADLOCK");
      end
    join_any
    disable fork;
    $display("[C] %s  (%0d new failures)", (fails==f0)?"pass":"FAIL", fails-f0);

    // ---- D: two back-to-back sequence ends -----------------------------------
    reset_dut; f0 = fails;
    $display("[D] double seq_end   (I,SEQ_END,SEQ_END then I)");
    push(I_TYPE, 1'b0);
    push(I_TYPE, 1'b1);
    wait_pickup(1);
    push(I_TYPE, 1'b1);
    wait_pickup(1);
    push(I_TYPE, 1'b0);
    wait_pickup(1);
    $display("[D] %s  (%0d new failures)", (fails==f0)?"pass":"FAIL", fails-f0);

    // ---- E: steady-state playback, no sequence ends ---------------------------
    reset_dut; f0 = fails;
    $display("[E] steady state     (40 pictures, I B B P B B ...)");
    push(I_TYPE, 1'b0);
    for (sc = 0; sc < 13; sc = sc + 1) begin
      push(B_TYPE, 1'b0); push(B_TYPE, 1'b0); push(P_TYPE, 1'b0);
    end
    wait_pickup(1);
    $display("[E] %s  (%0d new failures)", (fails==f0)?"pass":"FAIL", fails-f0);

    $display("\nSUMMARY: release-point checks=%0d pickups=%0d fails=%0d", checks, pickups, fails);
    if (fails == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end

  initial begin
    #20_000_000;
    $display("\nSUMMARY: TIMEOUT — the FSM stalled (fails=%0d)", fails);
    $display("RESULT: FAIL");
    $finish;
  end

endmodule
