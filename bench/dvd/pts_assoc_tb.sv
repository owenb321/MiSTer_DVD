// =============================================================================
// pts_assoc_tb.sv — PTS -> picture association, measured against a golden.
// =============================================================================
// Two things are pinned here, both against tools/pts_map.py over REAL disc bytes
// through the REAL getbits_fifo + vld (the cc_extract / film_evidence technique:
// a hand-driven model of the vld would only check my reading of its FSM):
//
//   [A] POSITION. The byte offset the vld reports for every picture start code
//       (pic_hdr_bitpos - 32, in bytes) must equal the golden's offset EXACTLY,
//       for every picture. Any constant other than 32 means the parse-position
//       bookkeeping is wrong; any drift means a bit moved that was not counted.
//       Nothing downstream can be exact if this is not.
//
//   [B] TAG (once dvd/pts_assoc.sv exists — see the `ifdef). Stamps from the
//       golden's marks file are pushed into the association FIFO at their ES
//       byte position, and every picture's tag {valid, pts} must match the
//       golden's MPEG-rule assignment.
//
// Fixtures (gitignored — cut with bench/dvd/run_pts_assoc.sh):
//   STEM.hex          video ES, 64-bit words, starts at a sequence header
//   STEM.marks.hex    {es_offset[31:0] << 40 | pts[32:0]} per PTS-bearing PES
//   STEM.golden.hex   {offset[31:0] << 40 | valid << 39 | second << 38 | pts}
//
// Build:
//   iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/pts_assoc_sim \
//       rtl/mpeg2/vld.v rtl/mpeg2/getbits.v dvd/pts_assoc.sv bench/dvd/pts_assoc_tb.sv
//   vvp bench/dvd/pts_assoc_sim +STEM=bench/dvd/test_vobs/pts_apollo
// =============================================================================
module pts_assoc_tb;

  reg clk = 0; always #5 clk = ~clk;
  reg rst = 0;

  // sized to the fixture (an oversized TB array is an Icarus compile cliff)
  parameter integer MAXW = 200000;
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

  localparam MAXP = 8192;
  reg [71:0] gold  [0:MAXP-1];
  reg [71:0] marks [0:MAXP-1];
  integer    n_golden = 0, n_marks = 0;
  integer    n_seen   = 0;
  integer    errors   = 0;
  integer    pos_err  = 0;
  reg        verbose  = 0;

  wire  [4:0] advance;
  wire        align, wait_state;
  wire [23:0] getbits;
  wire        signbit, vld_en;
  wire [31:0] bitpos;

  getbits_fifo getbits_fifo (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .vid_in(vid_in), .vid_in_rd_en(vid_in_rd_en), .vid_in_rd_valid(vid_in_rd_valid),
    .advance(advance), .align(align), .wait_state(wait_state),
    .rld_wr_almost_full(1'b0), .mvec_wr_almost_full(1'b0), .motcomp_busy(1'b0),
    .getbits(getbits), .signbit(signbit),
    .getbits_valid(), .vld_en(vld_en),
    .pos_clr(1'b0), .bitpos(bitpos)
  );

  wire        pic_hdr_pulse, pic_hdr_upd, pic_hdr_second;
  wire [31:0] pic_hdr_bitpos;

  vld vld (
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
    .pic_informative(), .informative_commit(),
    .cc_pair_valid(), .cc_pair(), .cc_pair_field(),
    .mpeg1(),
    .vbuf_flush(1'b0),
    .bitpos(bitpos),
    .pic_hdr_pulse(pic_hdr_pulse), .pic_hdr_bitpos(pic_hdr_bitpos),
    .pic_hdr_upd(pic_hdr_upd), .pic_hdr_second(pic_hdr_second)
  );

  // The start code's own 32 bits precede the header the vld is parsing.
  localparam integer SC_BITS = 32;

  // ---- [B] the association FIFO over the same run ----
  // Stamps are pushed as the feeder delivers the word holding each mark (the
  // hardware stamps at the packer, always ahead of the parse); the tag decided
  // at every header must match the golden's MPEG-rule assignment.
  reg         st_valid = 0; reg [32:0] st_pts = 0; reg [23:0] st_pos = 0;
  integer     st_ptr = 0;
  always @(posedge clk) begin
    st_valid <= 1'b0;
    if (rst && (st_ptr < n_marks) && ((rd_ptr * 8) > marks[st_ptr][71:40])) begin
      st_valid <= 1'b1; st_pts <= marks[st_ptr][32:0]; st_pos <= marks[st_ptr][63:40];
      st_ptr <= st_ptr + 1;
    end
  end
  reg  [23:0] hdr_pos_r = 0; reg hdr_pulse_r = 0, hdr_second_r = 0;
  wire [31:0] hdr_sc_bits = pic_hdr_bitpos - 32'd32;
  always @(posedge clk) begin
    hdr_pulse_r  <= rst && pic_hdr_pulse;
    hdr_pos_r    <= hdr_sc_bits[26:3];
    hdr_second_r <= pic_hdr_second;
  end
  wire        tag_valid, tag_second, tag_commit; wire [32:0] tag_pts;
  pts_assoc #(.DEPTH(16), .PW(24), .MIN_GAP_W(16)) pts_assoc (
    .clk(clk), .rst_n(rst), .flush(1'b0),
    .stamp_valid(st_valid), .stamp_pts(st_pts), .stamp_pos(st_pos),
    .hdr_pulse(hdr_pulse_r), .hdr_pos(hdr_pos_r), .hdr_second(hdr_second_r),
    .tag_valid(tag_valid), .tag_pts(tag_pts), .tag_second(tag_second), .tag_commit(tag_commit),
    .dbg_ovf());
  integer n_tagpic = 0, tag_err = 0, tags_seen = 0, second_tags = 0, exp_tags = 0;
  reg [71:0] g;
  // The stamp RATE LIMIT is documented policy (pts_assoc.sv): a mark closer
  // than MIN_GAP bytes to the previously ACCEPTED one is not stamped, so its
  // picture is expected UNTAGGED. Replayed here from the marks' positions --
  // independently of the RTL's own bookkeeping -- and a rate-dropped tag must
  // be ABSENT, never replaced by a neighbour's PTS.
  reg  mark_acc [0:MAXP-1];
  integer mk, last_acc;
  reg  exp_valid;
  task automatic replay_rate;
    begin
      last_acc = -1;
      for (mk = 0; mk < n_marks; mk = mk + 1) begin
        mark_acc[mk] = (last_acc < 0) || ((marks[mk][71:40] - last_acc) >= (1 << 16));
        if (mark_acc[mk]) last_acc = marks[mk][71:40];
      end
    end
  endtask
  task automatic expect_of(input [71:0] gg);   // golden tag -> expected after the rate rule
    integer q;
    begin
      exp_valid = 0;
      if (gg[39])
        for (q = 0; q < n_marks; q = q + 1)
          if (marks[q][32:0] == gg[32:0] && mark_acc[q]) exp_valid = 1;
    end
  endtask
  always @(posedge clk) if (rst && tag_commit) begin
    g = (n_tagpic < n_golden) ? gold[n_tagpic] : 72'd0;
    expect_of(g);
    if (exp_valid) exp_tags = exp_tags + 1;
    if ((tag_valid !== exp_valid) || (tag_valid && (tag_pts !== g[32:0]))) begin
      tag_err = tag_err + 1;
      if (tag_err < 8) $display("FAIL [B] pic %0d: tag valid=%0d pts=%0d, golden valid=%0d pts=%0d",
                                n_tagpic, tag_valid, tag_pts, g[39], g[32:0]);
    end
    if (tag_valid) tags_seen = tags_seen + 1;
    if (tag_valid && tag_second) second_tags = second_tags + 1;
    n_tagpic = n_tagpic + 1;
  end

  integer got_off, want_off, delta;
  reg [31:0] want_off_r;
  integer max_delta = 0, min_delta = 0;

  always @(posedge clk) if (rst && pic_hdr_pulse) begin
    got_off    = ($signed(pic_hdr_bitpos) - SC_BITS) >>> 3;
    want_off_r = gold[n_seen][71:40];
    want_off   = want_off_r;
    delta      = got_off - want_off;
    if (verbose && (n_seen < 16))
      $display("  #%0d vld off %0d (upd=%0d 2nd=%0d) | golden off %0d valid=%0d 2nd=%0d",
               n_seen, got_off, pic_hdr_upd, pic_hdr_second, want_off,
               gold[n_seen][39], gold[n_seen][38]);
    if (n_seen >= n_golden) begin
      $display("FAIL: extra picture header #%0d (%0d expected)", n_seen, n_golden);
      errors = errors + 1;
    end else begin
      if (delta > max_delta) max_delta = delta;
      if (delta < min_delta) min_delta = delta;
      if (delta != 0) begin
        if (pos_err < 8)
          $display("FAIL pos #%0d: vld %0d, golden %0d (delta %0d)", n_seen, got_off, want_off, delta);
        pos_err = pos_err + 1;
        errors  = errors + 1;
      end
    end
    n_seen = n_seen + 1;
  end

  integer i, guard;
  reg [1023:0] stem;
  reg [1023:0] fname;

  initial begin
    if (!$value$plusargs("STEM=%s", stem)) stem = "bench/dvd/test_vobs/pts_apollo";
    for (i = 0; i < MAXW; i = i + 1) es[i] = 64'hx;
    for (i = 0; i < MAXP; i = i + 1) begin gold[i] = 72'hx; marks[i] = 72'hx; end
    $sformat(fname, "%0s.hex", stem);        $readmemh(fname, es);
    $sformat(fname, "%0s.golden.hex", stem); $readmemh(fname, gold);
    $sformat(fname, "%0s.marks.hex", stem);  $readmemh(fname, marks);
    i = 0; while (i < MAXW && es[i]    !== 64'hx) i = i + 1; es_words = i;
    i = 0; while (i < MAXP && gold[i]  !== 72'hx) i = i + 1; n_golden = i;
    i = 0; while (i < MAXP && marks[i] !== 72'hx) i = i + 1; n_marks  = i;
    if (es_words == 0 || n_golden == 0) begin
      $display("SKIP: pts_assoc_tb — fixture %0s missing; run bench/dvd/run_pts_assoc.sh", stem);
      $finish;
    end
    if (es_words >= MAXW) begin
      $display("FAIL: fixture fills MAXW=%0d words — raise MAXW", MAXW);
      $fatal(1);
    end
    $display("pts_assoc_tb: %0s — %0d ES words, %0d pictures, %0d PTS marks",
             stem, es_words, n_golden, n_marks);
    if ($test$plusargs("VERBOSE")) verbose = 1;
    replay_rate;
    #100 rst = 1;
    guard = 0;
    while ((n_seen < n_golden) && (guard < (es_words * 192))) begin
      @(posedge clk);
      guard = guard + 1;
    end
    repeat (200) @(posedge clk);
    if (n_seen != n_golden) begin
      $display("FAIL: saw %0d picture headers, golden has %0d", n_seen, n_golden);
      errors = errors + 1;
    end
    if (tag_err != 0) begin
      $display("FAIL [B]: %0d picture tags disagree with the golden", tag_err);
      errors = errors + 1;
    end
    if (tags_seen != exp_tags) begin
      $display("FAIL [B]: %0d pictures tagged but %0d expected (%0d marks, rate rule applied)", tags_seen, exp_tags, n_marks);
      errors = errors + 1;
    end
    if (errors == 0)
      $display("PASS: pts_assoc_tb [A] position %0d/%0d start codes exact (delta %0d..%0d); [B] %0d/%0d marks landed on the golden picture with the golden PTS (%0d second-field, %0d rate-limited)",
               n_seen, n_golden, min_delta, max_delta, tags_seen, n_marks, second_tags, n_marks - exp_tags);
    else begin
      $display("FAIL: pts_assoc_tb — %0d error(s) (%0d position; delta range %0d..%0d)",
               errors, pos_err, min_delta, max_delta);
      $fatal(1);
    end
    $finish;
  end

endmodule
