/*
 * seek_realign_tb.sv -- after a seek, does any displayed picture still predict
 * from a reference slot holding the PRE-SEEK scene?  (Issue #45.)
 *
 * The field report is unambiguous about the signature: the new chapter decodes
 * correctly AND IS IN MOTION while the old scene bleeds through as residual,
 * for ~6 frames (~100 ms) on a 60 Hz HDMI recording. That is motion
 * compensation against stale references, not a corrupt or truncated picture --
 * so the thing to measure is not "does the picture look wrong" but "which slot
 * did this picture predict FROM, and what was written into that slot".
 *
 * WHAT THIS BENCH MEASURES
 *   Two elementary-stream cuts from different points of a real title are fed
 *   through the REAL getbits_fifo + vld + motcomp_picbuf. Partway through cut A
 *   the bench does what hardware does on a seek: asserts the VBUF flush level
 *   and jumps the read pointer to cut B. getbits is deliberately NOT reset --
 *   its 129-bit window keeps up to 16 bytes of cut A, so the in-flight picture
 *   truncates and completes on cut B's first start code, exactly as on hardware.
 *
 *   A shadow slot_tag[] records, for each of picbuf's frame slots, which CUT
 *   last wrote it. Every picture that reaches picbuf is then checked against
 *   the slots it actually predicts from (fwd for P, fwd+bwd for B; I is intra).
 *   A post-flush picture reading a slot tagged A is a VIOLATION.
 *
 *   That is a property of the byte stream and of picbuf's own pointers. It
 *   names no signal in the fix, so it cannot degenerate into a golden model
 *   that agrees with its RTL by construction (memory: bench-that-cannot-fail).
 *
 * RED / GREEN
 *   The RED arm is a TESTBENCH parameter, not an RTL one: SEEK_REALIGN=0 ties
 *   the vld's vbuf_flush input low, which reverts update_picture_buffers and
 *   drop_this_picture to their byte-identical pre-fix expressions. So the same
 *   binary proves both that the defect is real and that the added logic is
 *   inert when unarmed.
 *     RED   : viol == meta[3] (the leading-B count of cut B's first GOP)
 *     GREEN : viol == 0  AND  realign_drops == meta[3]
 *   The GREEN count is asserted EXACTLY, not as ">= 1": dropping too much is a
 *   failure too (it costs display frames at every seek).
 *
 * FIDELITY NOTE -- do not "improve" this into the full motcomp path.
 *   In the real decoder update_picture_buffers reaches picbuf through the mvec
 *   FIFO; here it is a direct pulse plus the motcomp.v freeze interlock. That
 *   is faithful FOR THIS MEASUREMENT because the fix lives entirely in the vld
 *   and the freeze already serialises header-vs-rotation ordering. It is NOT
 *   faithful for anything that tries to correct picbuf from outside the vld --
 *   see docs/seek_realign.md on the mvec-FIFO ordering hazard.
 *
 * Build (see bench/dvd/run_seek_realign.sh):
 *   iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/seek_realign_sim \
 *       rtl/mpeg2/vld.v rtl/mpeg2/getbits.v rtl/mpeg2/motcomp_picbuf.v \
 *       bench/dvd/seek_realign_tb.sv
 *   vvp bench/dvd/seek_realign_sim [+FLUSHPIC=n] [+FLUSHDLY=k] [+FLUSHW=w]
 *                                  [+DRAIN=n] [+NOFLUSH=1] [+REFLUSH=k]
 */
`timescale 1ns/1ps
`include "vld_codes.v"

module seek_realign_tb;

  // SEEK_REALIGN=0 ties the fix's input low -> pre-fix behaviour (the RED arm).
  parameter SEEK_REALIGN = 1;
  // RA_CAP is forwarded to the vld so the give-up path can be reached inside a
  // short fixture; the shipped default (48) never is.
  parameter RA_CAP = 6'd48;

  reg clk = 0; always #5 clk = ~clk;
  reg rst = 0;

  // ---- ES feed: behavioral vbuf-read fifo (64-bit, big-endian words) -------
  // Sized to the fixture, not to a round power of two: an oversized TB array is
  // an Icarus compile cliff, not free headroom.
  localparam MAXW = 70000;
  reg [63:0] es [0:MAXW-1];
  integer    es_words = 0;
  integer    rd_ptr   = 0;

  reg [31:0] meta [0:6];
  integer    b_word, pics_a, first_ct, lead_b, closed_b, pics_b, field_b;

  wire        vid_in_rd_en;
  reg         vid_in_rd_valid = 0;
  reg  [63:0] vid_in = 64'h0;
  reg         jump_now = 0;               // 1-cycle: reader lands on cut B

  always @(posedge clk) begin
    vid_in_rd_valid <= 1'b0;
    if (jump_now) rd_ptr <= b_word;
    else if (rst && vid_in_rd_en && (rd_ptr < es_words)) begin
      vid_in          <= es[rd_ptr];
      vid_in_rd_valid <= 1'b1;
      rd_ptr          <= rd_ptr + 1;
    end
  end

  // ---- DUT: getbits_fifo + vld + motcomp_picbuf (all real RTL) ------------
  wire  [4:0] advance;
  wire        align, wait_state;
  wire [23:0] getbits;
  wire        signbit, getbits_valid, vld_en;
  wire        motcomp_busy;

  getbits_fifo getbits_fifo (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .vid_in(vid_in), .vid_in_rd_en(vid_in_rd_en), .vid_in_rd_valid(vid_in_rd_valid),
    .advance(advance), .align(align), .wait_state(wait_state),
    .rld_wr_almost_full(1'b0), .mvec_wr_almost_full(1'b0),
    .motcomp_busy(motcomp_busy),
    .getbits(getbits), .signbit(signbit),
    .getbits_valid(getbits_valid), .vld_en(vld_en)
  );

  reg  flush_lvl = 1'b0;                  // the ~192 clk_dec VBUF flush level
  wire drop_pic_ack;
  integer cyc = 0;
  integer vld_err_cnt = 0;
  reg     flushed_seen = 0;               // 1 once the flush has fired
  wire update_picture_buffers, flags_commit, last_frame, second_field;
  wire pic_informative, informative_commit;
  wire [2:0] picture_coding_type;
  wire [1:0] picture_structure;
  wire repeat_first_field, top_field_first, progressive_frame, progressive_sequence;
  wire vld_err;

  vld #(.RA_CAP(RA_CAP)) vld (
    .clk(clk), .clk_en(vld_en), .rst(rst),
    .getbits(getbits), .signbit(signbit),
    .advance(advance), .align(align), .wait_state(wait_state),
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
    .picture_coding_type(picture_coding_type), .picture_structure(picture_structure),
    .motion_type(), .dct_type(), .macroblock_address(),
    .macroblock_motion_forward(), .macroblock_motion_backward(),
    .mb_width(), .mb_height(),
    .motion_vert_field_select_0_0(), .motion_vert_field_select_0_1(),
    .motion_vert_field_select_1_0(), .motion_vert_field_select_1_1(),
    .second_field(second_field), .update_picture_buffers(update_picture_buffers),
    .last_frame(last_frame), .chroma_format(), .motion_vector_valid(),
    .pmv_0_0_0(), .pmv_0_0_1(), .pmv_1_0_0(), .pmv_1_0_1(),
    .pmv_0_1_0(), .pmv_0_1_1(), .pmv_1_1_0(), .pmv_1_1_1(),
    .dmv_0_0(), .dmv_0_1(), .dmv_1_0(), .dmv_1_1(),
    .progressive_sequence(progressive_sequence), .progressive_frame(progressive_frame),
    .top_field_first(top_field_first), .repeat_first_field(repeat_first_field),
    .vld_err(vld_err),
    .drop_pic_req(1'b0),                  // governor OFF: every drop here is a realign drop
    .drop_pic_ack(drop_pic_ack), .drop_pic_rff(), .drop_pic_field(),
    .dbg_drop_probe(),
    .flags_commit(flags_commit),
    .pic_informative(pic_informative), .informative_commit(informative_commit),
    .cc_pair_valid(), .cc_pair(), .cc_pair_field(), .mpeg1(),
    .vbuf_flush(SEEK_REALIGN ? flush_lvl : 1'b0)
  );

  // motcomp.v's freeze interlock, replicated (see the fidelity note above).
  wire picbuf_busy;
  reg  flush_pend;
  always @(posedge clk)
    if (~rst) flush_pend <= 1'b0;
    else if (update_picture_buffers) flush_pend <= 1'b1;
    else if (picbuf_busy) flush_pend <= 1'b0;
  assign motcomp_busy = flush_pend || picbuf_busy;

  wire [2:0] fwd, bwd, cur_slot, output_frame;
  wire       output_frame_valid;
  reg        output_frame_rd;

  motcomp_picbuf picbuf (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .source_select(3'd0),
    .picture_coding_type(picture_coding_type),
    .progressive_sequence(progressive_sequence), .progressive_frame(progressive_frame),
    .top_field_first(top_field_first), .repeat_first_field(repeat_first_field),
    .last_frame(last_frame),
    .pic_informative(pic_informative), .informative_commit(informative_commit),
    .update_picture_buffers(update_picture_buffers), .flags_commit(flags_commit),
    .forward_reference_frame(fwd), .backward_reference_frame(bwd),
    .current_frame(cur_slot),
    .output_frame(output_frame), .output_frame_valid(output_frame_valid),
    .output_frame_rd(output_frame_rd),
    .output_progressive_sequence(), .output_progressive_frame(),
    .output_top_field_first(), .output_repeat_first_field(), .output_informative(),
    .picbuf_busy(picbuf_busy)
  );

  // ---- governor stub (resample's pickup handshake) + optional display block -
  integer emits = 0, drain = 0, drain_cnt = 0;
  integer last_emit_t = 0, max_gap = 0, gap_from = -1;
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
          if (flushed_seen && (gap_from >= 0) && ((cyc - last_emit_t) > max_gap))
            max_gap = cyc - last_emit_t;
          last_emit_t = cyc;
          if (flushed_seen && (gap_from < 0)) gap_from = cyc;
          output_frame_rd <= 1'b1;
          gov_ack <= 1'b1;
        end
      end else if (gov_ack && ~output_frame_valid)
        gov_ack <= 1'b0;
    end

  // ---- the seek: flush level + reader jump --------------------------------
  localparam [7:0] VS_PICTURE_HEADER  = 8'h02;
  localparam [7:0] VS_SEQUENCE_HEADER = 8'h06;
  localparam [3:0] PB_UPDATE          = 4'h1;

  always @(posedge clk) cyc = cyc + 1;

  integer flushpic = 3;        // flush during cut A's picture #3
  integer flushdly = 400;      // cycles after that header: >0 = mid-slice
  integer flushw   = 192;      // flush level width (dvd/flush_ctl.sv: ~64 clk_sys)
  integer reflush  = 0;        // >0: fire a SECOND flush this many cycles later
  reg     caparm   = 1'b0;     // RA_CAP arm: the give-up path, not the normal one
  reg     noflush  = 1'b0;     // control arm: no flush, no reader jump

  integer npic = -1;                       // coded picture index over the whole feed
  reg     arm = 0;
  integer arm_t = 0, wnd_end = 0, re_t = 0;
  reg     re_pend = 0;
  integer vlden_in_window = 0;             // vld_en cycles inside the flush window
  reg     seq_after_flush = 0;             // a sequence header was parsed post-flush
  reg     pic_after_flush = 0;

  always @(posedge clk) if (rst) begin
    jump_now <= 1'b0;
    if (vld_en && (vld.state == VS_PICTURE_HEADER)) begin
      npic = npic + 1;
      if (!noflush && !arm && !flushed_seen && (npic == flushpic)) begin
        arm   <= 1'b1;
        arm_t  = cyc + flushdly;
      end
      if (flushed_seen) pic_after_flush <= 1'b1;
    end
    if (vld_en && (vld.state == VS_SEQUENCE_HEADER) && flushed_seen && !pic_after_flush)
      seq_after_flush <= 1'b1;

    if (arm && (cyc >= arm_t)) begin
      arm          <= 1'b0;
      flush_lvl    <= 1'b1;
      jump_now     <= 1'b1;                // the reader lands on cut B
      flushed_seen <= 1'b1;
      wnd_end       = cyc + flushw;
      if (reflush > 0) begin re_pend <= 1'b1; re_t = cyc + reflush; end
    end
    if (flush_lvl) begin
      if (vld_en) vlden_in_window = vlden_in_window + 1;
      if (cyc >= wnd_end) flush_lvl <= 1'b0;
    end
    // a second flush landing on the same seek (scrub / double chapter skip):
    // it must RESTART the window, not be swallowed by the first.
    if (re_pend && (cyc >= re_t)) begin
      re_pend   <= 1'b0;
      flush_lvl <= 1'b1;
      wnd_end    = cyc + flushw;
    end
  end

  // ---- the measurement: slot provenance ------------------------------------
  // 0 = never written, 1 = cut A (pre-seek), 2 = cut B (post-seek).
  reg  [1:0] slot_tag [0:7];
  reg        upd_seg;                      // segment of the picture owning this update
  reg  [3:0] pb_state_d;
  integer    viol = 0, upds_b = 0, anchors_b = 0, hdr_b = 0, k;
  integer    lastf_upds = 0;

  always @(posedge clk) pb_state_d <= picbuf.state;

  // The freeze interlock guarantees at most one update in flight, so a single
  // latch carries the owning picture's segment to the rotation cycle.
  always @(posedge clk)
    if (~rst) upd_seg <= 1'b0;
    else if (update_picture_buffers) upd_seg <= flushed_seen;

  // Post-flush FRAME slots seen at the header (a field pair is one frame slot,
  // matching the condition update_picture_buffers itself uses).
  wire in_zone = noflush ? 1'b1 : flushed_seen;   // control arm counts the whole run
  always @(posedge clk)
    if (rst && vld_en && (vld.state == VS_PICTURE_HEADER) && in_zone &&
        ((picture_structure == FRAME_PICTURE) || second_field))
      hdr_b = hdr_b + 1;

  always @(posedge clk)
    if (~rst) begin
      for (k = 0; k < 8; k = k + 1) slot_tag[k] <= 2'd0;
    end else if ((pb_state_d == PB_UPDATE) && ~picbuf.vld_last_frame) begin
      // Sampled one cycle AFTER STATE_UPDATE, so fwd/bwd/current_frame carry
      // the values this picture actually decodes and predicts with.
      slot_tag[cur_slot] <= (upd_seg || noflush) ? 2'd2 : 2'd1;   // control arm: everything is "post"
      if (upd_seg || noflush) begin
        upds_b = upds_b + 1;
        if (picbuf.vld_picture_coding_type != B_TYPE) anchors_b = anchors_b + 1;
        case (picbuf.vld_picture_coding_type)
          P_TYPE: if (slot_tag[fwd] == 2'd1) begin
                    viol = viol + 1;
                    $display("  VIOL pic=%0d P slot=%0d predicts fwd=%0d (cut A)", npic, cur_slot, fwd);
                  end
          B_TYPE: if ((slot_tag[fwd] == 2'd1) || (slot_tag[bwd] == 2'd1)) begin
                    viol = viol + 1;
                    $display("  VIOL pic=%0d B slot=%0d predicts fwd=%0d(%0d) bwd=%0d(%0d) -- cut A residual",
                             npic, cur_slot, fwd, slot_tag[fwd], bwd, slot_tag[bwd]);
                  end
          default: ;                       // I_TYPE is intra: nothing to check
        endcase
      end
    end else if ((pb_state_d == PB_UPDATE) && picbuf.vld_last_frame)
      lastf_upds = lastf_upds + 1;

  // ---- drive ---------------------------------------------------------------
  integer errors = 0, guard = 0, realign_drops = 0;
  string  esf, mtf;

  initial begin
    if (!$value$plusargs("ES=%s", esf))   esf = "bench/dvd/test_vobs/seek_realign.hex";
    if (!$value$plusargs("META=%s", mtf)) mtf = "bench/dvd/test_vobs/seek_realign.meta.hex";
    void'($value$plusargs("FLUSHPIC=%d", flushpic));
    void'($value$plusargs("FLUSHDLY=%d", flushdly));
    void'($value$plusargs("FLUSHW=%d",   flushw));
    void'($value$plusargs("DRAIN=%d",    drain));
    void'($value$plusargs("REFLUSH=%d",  reflush));
    begin : noflush_arg
      integer nf;
      if ($value$plusargs("NOFLUSH=%d", nf)) noflush = nf[0];
      if ($value$plusargs("CAPARM=%d", nf)) caparm = nf[0];
    end
    $readmemh(esf, es);
    $readmemh(mtf, meta);
    begin : count_words
      integer j;
      j = 0;
      while (j < MAXW && es[j] !== 64'hx) j = j + 1;
      es_words = j;
    end
    b_word   = meta[0]; pics_a   = meta[1]; first_ct = meta[2]; lead_b = meta[3];
    closed_b = meta[4]; pics_b   = meta[5]; field_b  = meta[6];

    if (es_words == 0 || meta[0] === 32'hx) begin
      $display("SKIP: seek_realign_tb - fixture missing; run bench/dvd/run_seek_realign.sh");
      $finish;
    end
    if (es_words >= MAXW) begin
      $display("FAIL: fixture (%0d words) fills the TB array (MAXW=%0d) - it was truncated", es_words, MAXW);
      $fatal(1);
    end
    $display("seek_realign_tb: SEEK_REALIGN=%0d RA_CAP=%0d  ES %0d words, cut B at word %0d",
             SEEK_REALIGN, RA_CAP, es_words, b_word);
    $display("  fixture: cut A %0d pics, cut B %0d pics, leading B's %0d, closed=%0d, field=%0d",
             pics_a, pics_b, lead_b, closed_b, field_b);
    $display("  arm: flushpic=%0d flushdly=%0d flushw=%0d drain=%0d reflush=%0d noflush=%0d",
             flushpic, flushdly, flushw, drain, reflush, noflush);

    rst = 0;
    repeat (8) @(posedge clk);
    rst = 1;

    // Run to completion, not to a fixed delay: clocks x timescale overflows
    // 32-bit integer arithmetic on a fixture this size, and the bench then
    // either stops early (testing almost nothing) or never stops at all.
    guard = 0;
    while ((rd_ptr < es_words - 1) && (guard < (es_words * 192 + drain * 4096))) begin
      @(posedge clk);
      guard = guard + 1;
    end
    repeat (4000) @(posedge clk);          // let the tail drain through picbuf

    if (guard >= (es_words * 192 + drain * 4096)) begin
      $display("FAIL: watchdog expired at word %0d/%0d - the run did not complete", rd_ptr, es_words);
      errors = errors + 1;
    end

    realign_drops = hdr_b - upds_b;

    /* The DRAIN arm exists to prove ONE design decision: the flush arm inside
     * the vld is not gated by clk_en. With the display blocked, motcomp's
     * freeze holds vld_en low across the whole flush window, so a clk_en-gated
     * capture would miss the level entirely and the violations would come back.
     * This counter is the anti-vacuity guard on that: if the drain was not deep
     * enough the window was not actually a freeze and the arm proves nothing. */
    if (drain > 0 && !noflush) begin
      $display("  drain arm: vld_en high for %0d of the %0d flush-window cycles", vlden_in_window, flushw);
      if (vlden_in_window != 0) begin
        $display("FAIL: the flush window was not inside a vld freeze (+DRAIN too small or +FLUSHDLY misplaced) - this arm cannot test the ungated capture");
        errors = errors + 1;
      end
    end

    // ---- anti-vacuity: a bench that drops everything must not pass ---------
    if (!noflush) begin
      if (!flushed_seen) begin
        $display("FAIL: the flush never fired - cut A has fewer than %0d pictures", flushpic + 1);
        errors = errors + 1;
      end
      if (upds_b < 8) begin
        $display("FAIL: only %0d post-flush pictures reached picbuf (need >= 8) - 'drop everything forever' would score zero violations", upds_b);
        errors = errors + 1;
      end
      if (anchors_b < 2) begin
        $display("FAIL: only %0d post-flush anchors decoded (need >= 2) - the run never reached the point where the references are re-established", anchors_b);
        errors = errors + 1;
      end
      if (!seq_after_flush) begin
        $display("FAIL: no sequence header parsed between the flush and the first post-flush picture header - the cut-A/cut-B tagging is not trustworthy");
        errors = errors + 1;
      end
      if (lead_b == 0) begin
        $display("FAIL: fixture reports zero leading B's - it cannot tell a working re-align from one wired off");
        errors = errors + 1;
      end
    end
    if (vld_err_cnt > 0)
      $display("  note: %0d vld_err cycles (a truncated in-flight picture is expected)", vld_err_cnt);

    // ---- verdict -----------------------------------------------------------
    if (noflush) begin
      if (realign_drops != 0) begin
        $display("FAIL: control arm dropped %0d picture(s) - the re-align is not inert in steady state", realign_drops); errors = errors + 1;
      end
      if (upds_b < 8) begin
        $display("FAIL: control arm only decoded %0d pictures - it proves nothing", upds_b);
        errors = errors + 1;
      end
    end else if (caparm) begin
      // RA_CAP arm: the give-up must fire and decoding must RESUME. If the cap
      // were dead code this arm would look exactly like the normal one.
      if (realign_drops >= lead_b) begin
        $display("FAIL: RA_CAP=%0d arm dropped %0d picture(s) - the give-up never fired", RA_CAP, realign_drops);
        errors = errors + 1;
      end
      if (upds_b < 8) begin
        $display("FAIL: RA_CAP arm decoded only %0d pictures - the give-up did not restore decoding", upds_b);
        errors = errors + 1;
      end
    end else if (SEEK_REALIGN == 0) begin
      if (viol != lead_b) begin
        $display("FAIL: RED arm measured %0d violation(s), fixture says %0d leading B's",
                 viol, lead_b); errors = errors + 1;
      end
      if (realign_drops != 0) begin
        $display("FAIL: RED arm dropped %0d picture(s) - vbuf_flush is tied low, the re-align must be completely inert", realign_drops); errors = errors + 1;
      end
    end else begin
      if (viol != 0) begin
        $display("FAIL: %0d picture(s) predicted from a pre-seek slot", viol); errors = errors + 1;
      end
      if (realign_drops != lead_b) begin
        $display("FAIL: re-align dropped %0d picture(s), fixture says %0d leading B's - dropping too much costs display frames at every seek",
                 realign_drops, lead_b); errors = errors + 1;
      end
    end

    $display("SUMMARY: viol=%0d realign_drops=%0d post-flush{hdr=%0d upd=%0d anchors=%0d} emits=%0d max_post_flush_emit_gap=%0d cyc", viol, realign_drops,
             hdr_b, upds_b, anchors_b, emits, max_gap);

    if (errors == 0) $display("PASS: seek_realign_tb");
    else begin
      $display("FAIL: seek_realign_tb - %0d error(s)", errors);
      $fatal(1);
    end
    $finish;
  end

  always @(posedge clk) if (rst && vld_en && vld_err) vld_err_cnt = vld_err_cnt + 1;

endmodule
