/*
 * vld_drop_rff_tb.sv — does the VLD's drop_pic_rff export the DROPPED
 * picture's own repeat_first_field? (Round 9 of the lip-sync saga.)
 *
 * Round-8 measurement (docs/lipsync_pickup.md): on HW the frame-drop debt
 * controller pays debit ~2.0 on essentially every drop (measured lates/drops
 * = 2.04) while the droppable-B population is 50/50 rff (ground truth from
 * the MiB ES) — i.e. drop_pic_rff reads 0 on HW, the film-aware debit is
 * inert, and every dropped rff B leaks +1 unreclaimed refresh (~+3% video
 * speed until the VBUF cushion exhausts = the permanent audio-behind step).
 *
 * This bench runs the REAL vld + getbits_fifo over a REAL film elementary
 * stream (extracted from the MiB VOB) with drop_pic_req held HIGH, so every
 * frame-picture B is dropped, and logs per coded picture:
 *     <n> <I|P|B> parsed_rff=<r>  [DROP ack_rff=<r'>]
 * A companion Python step compares against an independent bitstream parse
 * (the ground-truth file). If ack_rff matches the dropped picture's true rff
 * for all drops, the RTL is CLEAN and the HW discrepancy moves to the build
 * (physical synthesis) / an integration difference — next step then is the
 * {drops_rff1, drops_rff0} overlay word.
 *
 * Build:
 *   iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/vld_drop_rff_sim \
 *       rtl/mpeg2/vld.v rtl/mpeg2/getbits.v rtl/mpeg2/motcomp_picbuf.v \
 *       bench/dvd/vld_drop_rff_tb.sv
 *   vvp bench/dvd/vld_drop_rff_sim +ES=<stream.hex> [+MAXPIC=N] [+REQ=0]
 *
 * +ES    : $readmemh file of the ES as 64-bit big-endian words (first stream
 *          byte in bits [63:56], matching getbits_fifo's shift order).
 * +MAXPIC: stop after N coded pictures (default 200).
 * +REQ=0 : run with drop_pic_req low (control run — no drops, pure parse).
 */
`timescale 1ns/1ps

module vld_drop_rff_tb;

  reg clk = 0; always #5 clk = ~clk;
  reg rst = 0;

  // ---- ES feed: behavioral vbuf-read fifo (64-bit, big-endian words) ----
  localparam MAXW = 2 ** 21;             // up to 16 MB of ES
  reg [63:0] es [0:MAXW-1];
  integer    es_words = 0;
  integer    rd_ptr = 0;

  wire        vid_in_rd_en;
  reg         vid_in_rd_valid = 0;
  reg  [63:0] vid_in = 64'h0;

  always @(posedge clk) begin
    // registered fifo model: one-cycle read latency, like fifo_sc's valid
    vid_in_rd_valid <= 1'b0;
    if (rst && vid_in_rd_en && (rd_ptr < es_words)) begin
      vid_in          <= es[rd_ptr];
      vid_in_rd_valid <= 1'b1;
      rd_ptr          <= rd_ptr + 1;
    end
  end

  // ---- DUT: getbits_fifo + vld (real RTL) ----
  wire  [4:0] advance;
  wire        align, wait_state;
  wire [23:0] getbits;
  wire        signbit, getbits_valid, vld_en;
  wire        motcomp_busy;            // freeze interlock (defined below)
  integer     npic = -1;               // coded picture index (ground-truth order)

  getbits_fifo getbits_fifo (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .vid_in(vid_in), .vid_in_rd_en(vid_in_rd_en), .vid_in_rd_valid(vid_in_rd_valid),
    .advance(advance), .align(align), .wait_state(wait_state),
    .rld_wr_almost_full(1'b0),      // downstream never backpressures
    .mvec_wr_almost_full(1'b0),
    .motcomp_busy(motcomp_busy),    // REAL freeze interlock (replicates motcomp.v)
    .getbits(getbits), .signbit(signbit),
    .getbits_valid(getbits_valid), .vld_en(vld_en)
  );

  reg  drop_pic_req = 1'b1;
  wire drop_pic_ack, drop_pic_rff, drop_pic_field;
  wire pic_informative, informative_commit;
  wire update_picture_buffers, flags_commit;
  wire [2:0] picture_coding_type;
  wire repeat_first_field, top_field_first, progressive_frame, progressive_sequence;
  wire vld_err;

  vld vld (
    .clk(clk), .clk_en(vld_en), .rst(rst),
    .getbits(getbits), .signbit(signbit),
    .advance(advance), .align(align), .wait_state(wait_state),
    // downstream consumers dangle (we only exercise parsing + the drop path)
    .quant_wr_data(), .quant_wr_addr(), .quant_rst(),
    .wr_intra_quant(), .wr_non_intra_quant(),
    .wr_chroma_intra_quant(), .wr_chroma_non_intra_quant(),
    .rld_wr_en(), .rld_cmd(), .dct_coeff_run(), .dct_coeff_signed_level(),
    .dct_coeff_end(), .alternate_scan(), .q_scale_type(), .quantiser_scale_code(),
    .macroblock_intra(), .intra_dc_precision(), .matrix_coefficients(),
    .horizontal_size(), .vertical_size(),
    .display_horizontal_size(), .display_vertical_size(),
    .aspect_ratio_information(), .frame_rate_code(),
    .frame_rate_extension_n(), .frame_rate_extension_d(),
    .picture_coding_type(picture_coding_type), .picture_structure(),
    .motion_type(), .dct_type(), .macroblock_address(),
    .macroblock_motion_forward(), .macroblock_motion_backward(),
    .mb_width(), .mb_height(),
    .motion_vert_field_select_0_0(), .motion_vert_field_select_0_1(),
    .motion_vert_field_select_1_0(), .motion_vert_field_select_1_1(),
    .second_field(), .update_picture_buffers(update_picture_buffers),
    .last_frame(), .chroma_format(), .motion_vector_valid(),
    .pmv_0_0_0(), .pmv_0_0_1(), .pmv_1_0_0(), .pmv_1_0_1(),
    .pmv_0_1_0(), .pmv_0_1_1(), .pmv_1_1_0(), .pmv_1_1_1(),
    .dmv_0_0(), .dmv_0_1(), .dmv_1_0(), .dmv_1_1(),
    .progressive_sequence(progressive_sequence), .progressive_frame(progressive_frame),
    .top_field_first(top_field_first), .repeat_first_field(repeat_first_field),
    .vld_err(vld_err),
    .drop_pic_req(drop_pic_req),
    .drop_pic_ack(drop_pic_ack),
    .drop_pic_rff(drop_pic_rff),
    .drop_pic_field(drop_pic_field),
    .dbg_drop_probe(),
    .flags_commit(flags_commit),
    // ports added to vld since this bench was written (2026-09-03 repair):
    // outputs may dangle, but picbuf's pic_informative/informative_commit are
    // INPUTS and were floating to z -- connect them from the real vld.
    .pic_informative(pic_informative),
    .informative_commit(informative_commit),
    .cc_pair_valid(), .cc_pair(), .cc_pair_field(),
    .mpeg1(),
    .vbuf_flush(1'b0)   // DVD-FORK FIX (seek realign, issue #45): not exercised here
  );

  // ---- REAL motcomp_picbuf + the motcomp.v freeze interlock (round 11) ----
  // In the real system update_picture_buffers reaches picbuf through the mvec
  // fifo while the vld FREEZES at the picture header until picbuf processes
  // it (motcomp.v flush/busy). Replicate the interlock with a direct pulse:
  // busy from the update pulse until picbuf_busy has risen and fallen through
  // the picbuf FSM — sufficient to reproduce the ordering that makes the
  // STATE_UPDATE flag capture pre-extension (the stale-flag bug) and to
  // verify flags_commit corrects it.
  wire picbuf_busy;
  reg  flush_pend;
  always @(posedge clk)
    if (~rst) flush_pend <= 1'b0;
    else if (update_picture_buffers) flush_pend <= 1'b1;
    else if (picbuf_busy) flush_pend <= 1'b0;
  assign motcomp_busy = flush_pend || picbuf_busy;

  wire [2:0] output_frame;
  wire       output_frame_valid;
  reg        output_frame_rd;
  wire       out_ps, out_pf, out_tff, out_rff;

  motcomp_picbuf picbuf (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .source_select(3'd0),
    .picture_coding_type(picture_coding_type),
    .progressive_sequence(progressive_sequence),
    .progressive_frame(progressive_frame),
    .top_field_first(top_field_first),
    .repeat_first_field(repeat_first_field),
    .last_frame(1'b0),
    .update_picture_buffers(update_picture_buffers),
    .flags_commit(flags_commit),
    .pic_informative(pic_informative),
    .informative_commit(informative_commit),
    .output_informative(),
    .forward_reference_frame(), .backward_reference_frame(), .current_frame(),
    .output_frame(output_frame),
    .output_frame_valid(output_frame_valid),
    .output_frame_rd(output_frame_rd),
    .output_progressive_sequence(out_ps),
    .output_progressive_frame(out_pf),
    .output_top_field_first(out_tff),
    .output_repeat_first_field(out_rff),
    .picbuf_busy(picbuf_busy)
  );

  // governor stub: replicate resample's pickup handshake exactly — one clean
  // 1-cycle output_frame_rd pulse per presented frame, then wait for ofv to
  // drop (a toggling rd makes picbuf's WAIT_1 `ofv <= rd` bounce and the
  // emission gets logged multiple times).
  // +DRAIN=N (2026-08-05, Thayer drops=0 HW-vs-sim divergence): hold each
  // presented frame N cycles before acking, so the picbuf backs up and the vld
  // runs DISPLAY-BLOCKED (vld_en frozen most of the time) exactly like HW,
  // instead of the instant drain that always parses ahead unhindered. N=0 =
  // original behaviour.
  integer emits = 0;
  integer drain = 0;
  integer drain_cnt = 0;
  reg gov_ack;
  always @(posedge clk)
    if (~rst) begin output_frame_rd <= 1'b0; gov_ack <= 1'b0; drain_cnt <= 0; end
    else begin
      output_frame_rd <= 1'b0;
      if (~gov_ack && output_frame_valid) begin
        if (drain_cnt < drain) drain_cnt <= drain_cnt + 1;
        else begin
          drain_cnt <= 0;
          emits = emits + 1;
          $display("EMIT n=%0d at_pic=%0d out_rff=%0d out_pf=%0d out_tff=%0d",
                   emits, npic, out_rff, out_pf, out_tff);
          output_frame_rd <= 1'b1;
          gov_ack <= 1'b1;
        end
      end else if (gov_ack && ~output_frame_valid)
        gov_ack <= 1'b0;
    end

  // ---- per-picture logging ----
  // Track coded pictures by the PICTURE_HEADER state; capture the coding type
  // there; capture rff after the picture coding extension has parsed (we log
  // at the NEXT picture header / at the drop ack, both after the ext).
  localparam [7:0] STATE_PICTURE_HEADER = 8'h02;

  integer maxpic = 200;
  reg [2:0] cur_type = 3'd0;
  integer drops = 0, rff1_acks = 0, rff0_acks = 0, errs = 0;

  function [7:0] tname(input [2:0] t);
    tname = (t == 3'd1) ? "I" : (t == 3'd2) ? "P" : (t == 3'd3) ? "B" : "?";
  endfunction

  always @(posedge clk) if (rst) begin
    if (vld_en && (vld.state == STATE_PICTURE_HEADER)) begin
      // previous picture is complete: its (final) parsed rff is current
      if (npic >= 0)
        $display("PIC %0d %s parsed_rff=%0d", npic, tname(cur_type), repeat_first_field);
      npic     = npic + 1;
      cur_type = vld.getbits[13:11];   // same field the vld's drop test reads
      if (npic >= maxpic) begin
        $display("SUMMARY: pictures=%0d drops=%0d ack_rff1=%0d ack_rff0=%0d vld_err=%0d",
                 npic, drops, rff1_acks, rff0_acks, errs);
        $finish;
      end
    end
    if (drop_pic_ack) begin
      drops = drops + 1;
      if (drop_pic_rff) rff1_acks = rff1_acks + 1;
      else              rff0_acks = rff0_acks + 1;
      $display("DROP pic=%0d ack_rff=%0d (parsed_rff=%0d)", npic, drop_pic_rff, repeat_first_field);
    end
    if (vld_en && vld_err) errs = errs + 1;
  end

  // ---- drive ----
  string esf;
  initial begin
    // bench/dvd/mib6.hex was never committed and no longer exists; default to a
    // fixture the repo's own tooling regenerates (bench/dvd/run_seek_realign.sh).
    if (!$value$plusargs("ES=%s", esf)) esf = "bench/dvd/test_vobs/seek_realign.hex";
    void'($value$plusargs("MAXPIC=%d", maxpic));
    void'($value$plusargs("DRAIN=%d", drain));
    begin : req_arg
      integer r;
      if ($value$plusargs("REQ=%d", r)) drop_pic_req = r[0];
    end
    $readmemh(esf, es);
    begin : count_words
      integer k;
      k = 0;
      while (k < MAXW && es[k] !== 64'hx) k = k + 1;   // readmemh leaves tail X
      es_words = k;
    end
    $display("ES: %0d words (%0d bytes), drop_pic_req=%0d, maxpic=%0d",
             es_words, es_words * 8, drop_pic_req, maxpic);
    if (es_words == 0) begin
      $display("SKIP: vld_drop_rff_tb - fixture %0s missing; run bench/dvd/run_seek_realign.sh", esf);
      $finish;
    end
    rst = 0;
    repeat (8) @(posedge clk);
    rst = 1;
  end

  initial begin
    #2_000_000_000;
    $display("TIMEOUT: pictures=%0d drops=%0d ack_rff1=%0d ack_rff0=%0d",
             npic, drops, rff1_acks, rff0_acks);
    $finish;
  end
endmodule
