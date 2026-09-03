// =============================================================================
// film_evidence_tb.sv — does the vld measure coded picture size correctly, and
// does its informativeness verdict match the golden model?
// =============================================================================
// The film evidence gate rests entirely on one number: how many bits the
// encoder spent on a picture. Everything downstream — the running mean, the
// verdict, whether the film detector counts a pickup — is arithmetic on top of
// it. So this bench does not assert the counter is right; it MEASURES it,
// against tools/film_evidence_probe.py, through the REAL getbits_fifo + vld
// over REAL disc bytes. Same technique as cc_extract_tb, and for the same
// reason: a hand-driven model of the vld would be checking my understanding of
// the FSM rather than the FSM.
//
// The fixture deliberately spans a fade in APOLLO_13's opening credits, so it
// contains both the ~17 kB content pictures and the 384 B black ones whose
// meaningless progressive_frame flag is the entire bug.
//
// EV_WARM is overridden to 2 so the gate arms inside a short cut. The shipped
// value is 16; the warm-up LENGTH is a tuning constant, whereas what this bench
// has to prove is that the measurement and the arithmetic are right.
//
// Fixture (gitignored — regenerate with bench/dvd/run_film_evidence.sh):
//   tools/film_evidence_probe.py <apollo.iso> --start-frac 0.0028 --sectors 240 \
//       --cut bench/dvd/test_vobs/film_ev --cut-warm 2
//
// Build:
//   iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/film_evidence_sim \
//       rtl/mpeg2/vld.v rtl/mpeg2/getbits.v bench/dvd/film_evidence_tb.sv
//   vvp bench/dvd/film_evidence_sim
// =============================================================================
module film_evidence_tb;

  reg clk = 0; always #5 clk = ~clk;
  reg rst = 0;

  // sized to the fixture (~645 kB = ~80k words), not to a round power of two:
  // an oversized TB array is an Icarus compile cliff, not free headroom
  localparam MAXW = 12288;   // sized to the fixture; an oversized array is an Icarus compile cliff
  reg [63:0] es [0:MAXW-1];
  integer    es_words = 0;
  integer    rd_ptr   = 0;

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

  // ---- golden: {informative[24], coded size in bytes[23:0]} per picture ----
  localparam MAXP = 4096;
  reg [31:0] gold [0:MAXP-1];
  integer    n_golden = 0;
  integer    n_seen   = 0;
  integer    errors   = 0;
  reg        verbose  = 0;
  integer    size_err = 0;
  integer    verd_err = 0;

  wire  [4:0] advance;
  wire        align, wait_state;
  wire [23:0] getbits;
  wire        signbit, vld_en;

  getbits_fifo getbits_fifo (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .vid_in(vid_in), .vid_in_rd_en(vid_in_rd_en), .vid_in_rd_valid(vid_in_rd_valid),
    .advance(advance), .align(align), .wait_state(wait_state),
    .rld_wr_almost_full(1'b0), .mvec_wr_almost_full(1'b0), .motcomp_busy(1'b0),
    .getbits(getbits), .signbit(signbit),
    .getbits_valid(), .vld_en(vld_en)
  );

  wire pic_informative, informative_commit;

  vld #(.EV_WARM(5'd2)) vld (
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
    .picture_coding_type(), .picture_structure(),
    .motion_type(), .dct_type(), .macroblock_address(),
    .macroblock_motion_forward(), .macroblock_motion_backward(),
    .mb_width(), .mb_height(),
    .motion_vert_field_select_0_0(), .motion_vert_field_select_0_1(),
    .motion_vert_field_select_1_0(), .motion_vert_field_select_1_1(),
    .second_field(), .update_picture_buffers(),
    .last_frame(), .chroma_format(), .motion_vector_valid(),
    .pmv_0_0_0(), .pmv_0_0_1(), .pmv_1_0_0(), .pmv_1_0_1(),
    .pmv_0_1_0(), .pmv_0_1_1(), .pmv_1_1_0(), .pmv_1_1_1(),
    .dmv_0_0(), .dmv_0_1(), .dmv_1_0(), .dmv_1_1(),
    .progressive_sequence(), .progressive_frame(),
    .top_field_first(), .repeat_first_field(),
    .vld_err(),
    .drop_pic_req(1'b0), .drop_pic_ack(), .drop_pic_rff(), .drop_pic_field(),
    .dbg_drop_probe(),
    .flags_commit(),
    .pic_informative(pic_informative), .informative_commit(informative_commit),
    .cc_pair_valid(), .cc_pair(), .cc_pair_field(),
    .mpeg1(),
    .vbuf_flush(1'b0)   // DVD-FORK FIX (seek realign, issue #45): not exercised here
  );

  // The counter measures from STATE_PICTURE_HEADER to the terminating start
  // code; the golden measures start-code to start-code. The constant 4-byte
  // difference is the picture start code itself, and it is CHECKED rather than
  // absorbed: a drifting delta would mean the counter is missing bitstream
  // movement somewhere, which is exactly the failure this bench exists to catch.
  // The vld measures from STATE_PICTURE_HEADER to the terminating start code;
  // the golden measures start-code to start-code. They differ by the picture
  // start code itself and by however far the byte-at-a-time start-code hunt has
  // walked when the terminator is recognised, which is content-dependent —
  // measured at -2..+18 B on this fixture.
  //
  // TOL is therefore a stated ACCURACY, not a knob tuned until the bench passed:
  // 32 B against a discrimination threshold of 380 B vs 9,668 B is two orders of
  // magnitude of headroom, and max_delta is printed so the real figure stays
  // visible instead of hiding inside the tolerance. What must match EXACTLY is
  // the verdict — that is the contract the feature actually depends on.
  localparam integer SC_BYTES  = 0;
  localparam integer TOL_BYTES = 32;
  integer max_delta = 0;

  integer got_bytes, want_bytes, delta;
  reg [23:0] want_size;
  reg        want_inf;

  always @(posedge clk) if (rst && informative_commit) begin
    got_bytes  = vld.pic_bits >> 3;
    want_size  = gold[n_seen][23:0];
    want_inf   = gold[n_seen][24];
    want_bytes = want_size - SC_BYTES;
    delta      = got_bytes - want_bytes;
    if (verbose && (n_seen < 24))
      $display("  #%0d vld %0d B inf=%0d | golden %0d B inf=%0d",
               n_seen, got_bytes, pic_informative, want_bytes, want_inf);
    if (n_seen >= n_golden) begin
      $display("FAIL: extra picture #%0d committed (%0d expected)", n_seen, n_golden);
      errors = errors + 1;
    end else begin
      if (delta > max_delta)  max_delta = delta;
      if (-delta > max_delta) max_delta = -delta;
      if ((delta > TOL_BYTES) || (delta < -TOL_BYTES)) begin
        if (size_err < 8)
          $display("FAIL size  #%0d: vld %0d B, golden %0d B (delta %0d)",
                   n_seen, got_bytes, want_bytes, delta);
        size_err = size_err + 1;
        errors   = errors + 1;
      end
      if (pic_informative !== want_inf) begin
        if (verd_err < 8)
          $display("FAIL verdict #%0d: vld %0d, golden %0d (size %0d B)",
                   n_seen, pic_informative, want_inf, got_bytes);
        verd_err = verd_err + 1;
        errors   = errors + 1;
      end
    end
    n_seen = n_seen + 1;
  end

  integer i, n_black, guard;

  initial begin
    for (i = 0; i < MAXW; i = i + 1) es[i] = 64'hx;
    for (i = 0; i < MAXP; i = i + 1) gold[i] = 32'hx;
    $readmemh("bench/dvd/test_vobs/film_ev.hex", es);
    $readmemh("bench/dvd/test_vobs/film_ev.golden.hex", gold);
    i = 0; while (i < MAXW && es[i]   !== 64'hx) i = i + 1; es_words = i;
    i = 0; while (i < MAXP && gold[i] !== 32'hx) i = i + 1; n_golden = i;
    if (es_words == 0 || n_golden == 0) begin
      $display("SKIP: film_evidence_tb — fixture missing; run bench/dvd/run_film_evidence.sh");
      $finish;
    end
    n_black = 0;
    for (i = 0; i < n_golden; i = i + 1) if (!gold[i][24]) n_black = n_black + 1;
    $display("film_evidence_tb: %0d ES words, %0d golden pictures (%0d uninformative)",
             es_words, n_golden, n_black);

    if ($test$plusargs("VERBOSE")) verbose = 1;
    #100 rst = 1;
    // Run to COMPLETION, not to a fixed delay. A computed delay is a trap here:
    // the fixture is ~180 kB, so clocks x timescale overflows Verilog's 32-bit
    // integer arithmetic and the bench either stops early -- silently testing
    // almost nothing -- or never stops at all.
    guard = 0;
    while ((n_seen < (n_golden - 1)) && (guard < (es_words * 192))) begin
      @(posedge clk);
      guard = guard + 1;
    end
    repeat (100) @(posedge clk);
    if ((guard >= (es_words * 192)) && (n_seen < (n_golden - 1)))
      $display("FAIL: watchdog hit after %0d clocks with only %0d/%0d pictures", guard, n_seen, n_golden - 1);

    // A run that commits nothing would "pass" every check above, so the count
    // is itself an assertion -- and so is having seen both verdicts, otherwise
    // a gate stuck at 1 would look identical to a gate that works.
    // Exactly n_golden-1: the final picture in the cut has no terminating start
    // code, so it can never commit. Anything less is a genuine lost commit --
    // which is the failure mode to watch for, since informative_commit follows
    // flags_commit's pattern of clearing itself while clk_en is low.
    if (n_seen != (n_golden - 1)) begin
      $display("FAIL: committed %0d pictures, expected %0d (n_golden-1)", n_seen, n_golden - 1);
      errors = errors + 1;
    end
    if (n_black == 0) begin
      $display("FAIL: fixture has no uninformative pictures - it cannot tell a working gate from one wired to 1");
      errors = errors + 1;
    end

    if (errors == 0)
      $display("PASS: film_evidence_tb - %0d/%0d committable pictures, max size delta %0d B (tol %0d), every verdict matches golden", n_seen, n_golden - 1, max_delta, TOL_BYTES);
    else begin
      $display("FAIL: film_evidence_tb — %0d error(s) (%0d size, %0d verdict)",
               errors, size_err, verd_err);
      $fatal(1);
    end
    $finish;
  end

endmodule
