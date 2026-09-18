`timescale 1ns/1ps
/*
 * picbuf_tag_flush_tb.sv -- a picture picbuf holds across a VBUF flush must
 * reach the display UNTAGGED (2026-09-18, Scooby-Doo 2 "good job" heard as
 * "job"; docs/dvd_nav.md "A picture from before the flush must not set the
 * clock").
 *
 * THE DEFECT.  After a seek the display still shows the held I/P anchor once
 * (IPB reorder: the new cell's first I emits the PREVIOUS anchor --
 * docs/seek_realign.md §5.1). It carried its pre-flush PTS tag, so it anchored
 * disp_sched's clock on the OLD timeline, the new cell's first picture then
 * read as a backward jump, and the audio re-phase discarded the new cell's
 * buffered opening. MEASURED on the rig: reanchors=2, disp_lag -2024 ms, audio
 * held 1.25 s with the ring full -- once per whac-a-mole round.
 *
 * WHAT THIS MEASURES.  The REAL motcomp_picbuf driven like the vld drives it,
 * with a pts_assoc model (a tag register, set per picture header, cleared by
 * the flush exactly as dvd/pts_assoc.sv does). A display model picks up every
 * emitted picture and records the TAG IT SAW -- what disp_sched would anchor
 * on. Never a signal the fix names.
 *
 *   [A] the stale anchor emitted after the flush arrives with no tag
 *   [B] the new cell's first I keeps its tag (the fix must not over-reach)
 *   [C] a run with NO flush keeps every tag (control)
 *
 * RED arm: -Ppicbuf_tag_flush_tb.WIRE_FLUSH=0 ties picbuf's vbuf_flush low =
 * the pre-fix picbuf. [A] must fail there and only there.
 *
 *   iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o .sim/ptf \
 *       rtl/mpeg2/motcomp_picbuf.v bench/dvd/picbuf_tag_flush_tb.sv && vvp .sim/ptf
 */
module picbuf_tag_flush_tb;
  parameter integer WIRE_FLUSH = 1;

  reg clk = 0; always #5 clk = ~clk;
  reg rst = 0;                       // synchronous, ACTIVE LOW
`include "vld_codes.v"

  reg  [2:0]  picture_coding_type = I_TYPE;
  reg         update_picture_buffers = 1'b0;
  reg         output_frame_rd = 1'b0;
  reg         flush = 1'b0;
  // pts_assoc model: the tag of the picture whose header was parsed last
  reg  [32:0] tag_pts = 0;
  reg         tag_valid = 1'b0;

  wire [2:0]  fwd, bwd, current_frame, output_frame;
  wire        output_frame_valid, picbuf_busy;
  wire [32:0] output_pts;
  wire        output_pts_valid;

  motcomp_picbuf dut (
    .vbuf_flush(WIRE_FLUSH ? flush : 1'b0),
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .source_select(3'd0),
    .progressive_sequence(1'b1), .progressive_frame(1'b1),
    .top_field_first(1'b1), .repeat_first_field(1'b0),
    .last_frame(1'b0),
    .picture_coding_type(picture_coding_type),
    .forward_reference_frame(fwd), .backward_reference_frame(bwd),
    .current_frame(current_frame),
    .output_frame(output_frame), .output_frame_valid(output_frame_valid),
    .output_frame_rd(output_frame_rd),
    .output_progressive_sequence(), .output_progressive_frame(),
    .output_top_field_first(), .output_repeat_first_field(),
    .update_picture_buffers(update_picture_buffers),
    .picbuf_busy(picbuf_busy),
    .flags_commit(1'b0),
    .pic_informative(1'b1), .informative_commit(1'b0),
    .output_informative(),
    .vld_pic_pts(tag_pts), .vld_pic_pts_valid(tag_valid),
    .vld_pic_pts_2nd(1'b0), .pts_commit(1'b0),
    .output_pts(output_pts), .output_pts_valid(output_pts_valid), .output_pts_2nd()
  );

  // ---- display model: take every emitted picture, record the tag it saw ----
  integer    n_pick = 0;
  reg [32:0] pick_pts   [0:15];
  reg        pick_valid [0:15];
  reg        gov_ack = 1'b0;
  integer    scan = 0;
  always @(posedge clk)
    if (~rst) begin output_frame_rd <= 1'b0; gov_ack <= 1'b0; scan <= 0; end
    else begin
      output_frame_rd <= 1'b0;
      if (~gov_ack && output_frame_valid) begin
        if (scan < 30) scan <= scan + 1;
        else begin
          scan <= 0;
          pick_pts[n_pick]   <= output_pts;
          pick_valid[n_pick] <= output_pts_valid;
          n_pick <= n_pick + 1;
          output_frame_rd <= 1'b1;
          gov_ack <= 1'b1;
        end
      end else if (gov_ack && ~output_frame_valid) gov_ack <= 1'b0;
    end

  // ---- vld model: a picture header sets the tag, then the rotation ---------
  task push(input [2:0] ptype, input [32:0] pts);
    begin
      wait (picbuf_busy == 1'b0); @(posedge clk);
      tag_pts <= pts; tag_valid <= 1'b1;          // pts_assoc: tag decided at the header
      picture_coding_type    <= ptype;
      update_picture_buffers <= 1'b1;
      @(posedge clk);
      update_picture_buffers <= 1'b0;
      wait (picbuf_busy == 1'b0);
      repeat (40) @(posedge clk);                  // "decode", let the display pick up
    end
  endtask
  task do_flush;
    begin
      @(posedge clk); flush <= 1'b1; tag_valid <= 1'b0;   // pts_assoc clears on the flush too
      repeat (20) @(posedge clk); flush <= 1'b0;
      repeat (4) @(posedge clk);
    end
  endtask
  task reset_dut;
    begin
      rst = 1'b0; tag_valid = 1'b0; n_pick = 0;
      repeat (4) @(posedge clk); rst = 1'b1; @(posedge clk);
    end
  endtask

  integer errors = 0, k, base;
  task fail(input [639:0] m); begin $display("FAIL: %0s", m); errors = errors + 1; end endtask

  initial begin
    // ---- [A]/[B]: I P | flush | I P ----------------------------------------
    reset_dut;
    push(I_TYPE, 33'd1000);
    push(P_TYPE, 33'd2000);          // emits the I (tag 1000); P now the held anchor
    base = n_pick;
    do_flush;                        // the seek
    push(I_TYPE, 33'd50);            // new cell: emits the HELD, pre-flush P
    push(P_TYPE, 33'd60);            // emits the new I
    repeat (200) @(posedge clk);
    if (n_pick < base + 2) fail("[A] the display did not pick up the two post-flush pictures");
    else begin
      $display("   post-flush pickup 1: tag %0d valid %0d   pickup 2: tag %0d valid %0d",
               pick_pts[base], pick_valid[base], pick_pts[base+1], pick_valid[base+1]);
      if (pick_valid[base])
        fail("[A] stale pre-flush anchor reached the display TAGGED (old-timeline anchor)");
      else $display("   [A] stale pre-flush anchor arrives untagged  ok");
      if (!pick_valid[base+1] || pick_pts[base+1] != 33'd50)
        fail("[B] the new cell's first I lost its tag");
      else $display("   [B] the new cell's first I keeps tag 50  ok");
    end

    // ---- [C] control: the same shape with no flush keeps every tag ----------
    reset_dut;
    push(I_TYPE, 33'd1000); push(P_TYPE, 33'd2000);
    push(I_TYPE, 33'd50);   push(P_TYPE, 33'd60);
    repeat (200) @(posedge clk);
    for (k = 0; k < n_pick; k = k + 1)
      if (!pick_valid[k]) fail("[C] a tag was lost with no flush");
    if (n_pick < 3) fail("[C] too few pickups -- the control measured nothing");
    else $display("   [C] no flush: %0d pickups, all tagged  ok", n_pick);

    if (errors == 0) $display("RESULT: PASS");
    else begin $display("RESULT: FAIL (%0d)", errors); $fatal(1, "picbuf_tag_flush_tb failed"); end
    $finish;
  end
endmodule
