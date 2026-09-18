/*
 * field_order_tb.sv -- does the decoder DISPLAY the field the disc coded first?
 *
 * THE DEFECT (2026-09-18, Thayer's Quest "not interlaced properly on a CRT"):
 * on a FIELD-coded picture ISO 13818-2 6.3.10 forces top_field_first to 0, so
 * the syntax element carries no information -- the display order is given by
 * WHICH PARITY IS CODED FIRST in each pair. dvd/resample_addrgen.v ordered its
 * two field images from top_field_first alone, so field-coded content was
 * emitted BOTTOM-then-TOP unconditionally. On film that costs nothing (both
 * fields of a 3:2 frame are the same instant); on true-interlaced field-coded
 * content the two fields are distinct instants 1/59.94 s apart, so the display
 * sequence becomes t1,t0,t3,t2,... See docs/field_parity.md.
 *
 * ★ WHAT THIS SCORES, AND WHY IT IS NOT first_field_top. The bench reads
 * motcomp_picbuf's OUTPUT PIN output_top_field_first at each presented frame --
 * the value dvd/resample_addrgen.v actually orders the fields from -- and
 * compares it against a truth file derived independently, in Python, from the
 * SPEC (coded parity + 6.1.1.11's display reorder). It never looks at the
 * signal the fix introduces, so it cannot agree with the implementation by
 * construction: the failure mode that kept field_parity_tb.sv and dvd_vm_ref.py
 * green through real defects.
 *
 * ★ THE RED ARM IS THE SEAM, NOT A HAND-MADE MUTATION. -Pfield_order_tb.SEAM=0
 * feeds picbuf vld's RAW top_field_first, which is exactly the pre-fix wiring in
 * rtl/mpeg2/mpeg2video.v -- the same mechanism seek_realign_tb uses.
 *
 * Build:
 *   iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/field_order_sim \
 *       rtl/mpeg2/vld.v rtl/mpeg2/getbits.v rtl/mpeg2/motcomp_picbuf.v \
 *       bench/dvd/field_order_tb.sv
 *   vvp bench/dvd/field_order_sim +ES=<stem>.hex +TRUTH=<stem>.truth
 *
 * +ES    : ES as 64-bit big-endian words (getbits_fifo shift order).
 * +TRUTH : one word per DISPLAYED picture, bit0 = first displayed field is TOP.
 * +MAXPIC: stop after N coded pictures (default 4000).
 * +REQ=1 : hold drop_pic_req high (the DROP arm -- field pairs drop atomically).
 */
`timescale 1ns/1ps

module field_order_tb;

  // 1 = the shipping seam (picbuf fed the DISPLAY ORDER).
  // 0 = the pre-fix seam (picbuf fed the raw syntax element) -- the RED arm.
  parameter SEAM = 1;

  reg clk = 0; always #5 clk = ~clk;
  reg rst = 0;

  // ---- ES feed: behavioral vbuf-read fifo (64-bit, big-endian words) ----
  localparam MAXW = 2 ** 17;                    // 1 MB of ES -- fixtures are cut to fit
  reg [63:0] es [0:MAXW-1];
  integer    es_words = 0;
  integer    rd_ptr = 0;

  wire        vid_in_rd_en;
  reg         vid_in_rd_valid = 0;
  reg  [63:0] vid_in = 64'h0;

  always @(posedge clk) begin
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
  wire        motcomp_busy;
  integer     npic = -1;

  getbits_fifo getbits_fifo (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .vid_in(vid_in), .vid_in_rd_en(vid_in_rd_en), .vid_in_rd_valid(vid_in_rd_valid),
    .advance(advance), .align(align), .wait_state(wait_state),
    .rld_wr_almost_full(1'b0),
    .mvec_wr_almost_full(1'b0),
    .motcomp_busy(motcomp_busy),
    .getbits(getbits), .signbit(signbit),
    .getbits_valid(getbits_valid), .vld_en(vld_en),
    .pos_clr(1'b0), .bitpos()
  );

  reg  drop_pic_req = 1'b0;
  wire drop_pic_ack, drop_pic_rff, drop_pic_field;
  wire pic_informative, informative_commit;
  wire update_picture_buffers, flags_commit;
  wire [2:0] picture_coding_type;
  wire repeat_first_field, top_field_first, progressive_frame, progressive_sequence;
  wire first_field_top;
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
    .first_field_top(first_field_top),
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
    .vbuf_flush(1'b0),   // DVD-FORK FIX (seek realign, issue #45): not exercised here
    .bitpos(32'd0), .pic_hdr_pulse(), .pic_hdr_bitpos(), .pic_hdr_upd(), .pic_hdr_second()
  );

  // ---- REAL motcomp_picbuf + the motcomp.v freeze interlock ----
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
    /* THE SEAM under test -- mirrors rtl/mpeg2/mpeg2video.v. SEAM=0 restores the
     * pre-fix wiring rather than mutating any RTL, so the RED arm runs the real
     * shipped modules. */
    .top_field_first(SEAM ? first_field_top : top_field_first),
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

  // ---- truth: one word per DISPLAYED picture, bit0 = first field is TOP ----
  localparam MAXT = 4096;
  reg [31:0] truth [0:MAXT-1];
  integer    n_truth = 0;

  integer emits = 0, mism = 0, top_seen = 0, bot_seen = 0, errs = 0;

  /* +EXPECT=0|1 -- score against a CONSTANT instead of the truth file. Used by
   * the MPEG-1 control, where there is no picture coding extension to derive a
   * truth from and the required answer is a property of the format: vld.v forces
   * top_field_first (and first_field_top) to 0 for every MPEG-1 picture, so every
   * displayed picture must show BOTTOM first, exactly as before this change. */
  integer expect_mode = -1;

  /* +MINEMIT=N -- how many displayed pictures this arm EXPECTS to reach the
   * output. The default (half the truth file) is a vacuity guard: a run that
   * scored almost nothing is a broken fixture, not a verdict. The DROP arm is
   * the case where fewer emissions is the POINT -- drop_pic_req drops whole
   * field pairs -- so it states its own floor instead of tripping the guard. */
  integer min_emit = -1;

  // governor stub: one clean 1-cycle output_frame_rd per presented frame.
  reg gov_ack;
  always @(posedge clk)
    if (~rst) begin output_frame_rd <= 1'b0; gov_ack <= 1'b0; end
    else begin
      output_frame_rd <= 1'b0;
      if (~gov_ack && output_frame_valid) begin
        if ((expect_mode >= 0) || (emits < n_truth)) begin : score
          reg want;
          want = (expect_mode >= 0) ? expect_mode[0] : truth[emits][0];
          if (out_tff) top_seen = top_seen + 1; else bot_seen = bot_seen + 1;
          if (out_tff !== want) begin
            mism = mism + 1;
            if (mism <= 8)
              $display("MISMATCH disp=%0d  shown_first=%0s  disc_wants=%0s",
                       emits, out_tff ? "TOP" : "BOTTOM", want ? "TOP" : "BOTTOM");
          end
        end
        emits = emits + 1;
        output_frame_rd <= 1'b1;
        gov_ack <= 1'b1;
      end else if (gov_ack && ~output_frame_valid)
        gov_ack <= 1'b0;
    end

  localparam [7:0] STATE_PICTURE_HEADER = 8'h02;
  integer maxpic = 4000;

  reg done = 1'b0;
  task summary;
    begin
      if (done) $finish;          // the drain condition holds every cycle after it fires
      done = 1'b1;
      $display("SUMMARY: seam=%0d displayed=%0d scored=%0d mismatches=%0d shown_top=%0d shown_bottom=%0d vld_err=%0d",
               SEAM, emits, (expect_mode >= 0) ? emits : ((emits < n_truth) ? emits : n_truth),
               mism, top_seen, bot_seen, errs);
      // A run that scored almost nothing is a broken fixture, not a pass.
      if (emits < ((min_emit >= 0) ? min_emit
                                   : ((expect_mode >= 0) ? 8 : n_truth / 2))) begin
        $display("RESULT: FAIL (only %0d displayed pictures reached the output, wanted at least %0d -- fixture or harness problem, not a verdict)",
                 emits, (min_emit >= 0) ? min_emit
                                        : ((expect_mode >= 0) ? 8 : n_truth / 2));
        $fatal(1);
      end
      if (mism == 0) begin $display("RESULT: PASS"); $finish; end
      else begin
        $display("RESULT: FAIL (%0d displayed pictures shown in the wrong field order)", mism);
        $fatal(1);
      end
    end
  endtask

  /* End on the STREAM, not on a picture count: the fixture holds only a few tens
   * of pictures, so a maxpic-only exit would idle for the whole absolute timeout
   * (measured: minutes of empty simulation per arm). Once the ES is consumed,
   * give the pipeline a settle window to present what it still holds. */
  integer drain_cyc = 0;
  localparam DRAIN_SETTLE = 120000;

  always @(posedge clk) if (rst) begin
    if (vld_en && (vld.state == STATE_PICTURE_HEADER)) begin
      npic = npic + 1;
      if (npic >= maxpic) summary();
    end
    if (vld_en && vld_err) errs = errs + 1;
    if (rd_ptr >= es_words) begin
      drain_cyc = drain_cyc + 1;
      if (drain_cyc >= DRAIN_SETTLE) summary();
    end
  end

  string esf, trf;
  initial begin
    if (!$value$plusargs("ES=%s", esf))
      esf = "bench/dvd/test_vobs/field_order_thayer.hex";
    if (!$value$plusargs("TRUTH=%s", trf))
      trf = "bench/dvd/test_vobs/field_order_thayer.truth";
    void'($value$plusargs("MAXPIC=%d", maxpic));
    void'($value$plusargs("EXPECT=%d", expect_mode));
    void'($value$plusargs("MINEMIT=%d", min_emit));
    begin : req_arg
      integer r;
      if ($value$plusargs("REQ=%d", r)) drop_pic_req = r[0];
    end
    $readmemh(esf, es);
    begin : count_words
      integer k;
      k = 0;
      while (k < MAXW && es[k] !== 64'hx) k = k + 1;
      es_words = k;
    end
    $readmemh(trf, truth);
    begin : count_truth
      integer k;
      k = 0;
      while (k < MAXT && truth[k] !== 32'hx) k = k + 1;
      n_truth = k;
    end
    $display("ES: %0d words (%0d bytes)  truth: %0d displayed  seam=%0d req=%0d",
             es_words, es_words * 8, n_truth, SEAM, drop_pic_req);
    if (es_words == 0 || ((n_truth == 0) && (expect_mode < 0))) begin
      $display("SKIP: field_order_tb - fixture missing; run bench/dvd/run_field_order.sh");
      $finish;
    end
    rst = 0;
    repeat (8) @(posedge clk);
    rst = 1;
  end

  initial begin
    #600_000_000;                 // absolute backstop; the drain exit above is normal
    $display("TIMEOUT -- the drain exit never fired");
    summary();
  end
endmodule
