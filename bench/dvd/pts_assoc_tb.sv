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
//       rtl/mpeg2/vld.v rtl/mpeg2/getbits.v bench/dvd/pts_assoc_tb.sv
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
    if (errors == 0)
      $display("PASS: pts_assoc_tb [A] position — %0d/%0d picture start codes at the golden byte offset exactly (delta range %0d..%0d)",
               n_seen, n_golden, min_delta, max_delta);
    else begin
      $display("FAIL: pts_assoc_tb — %0d error(s) (%0d position; delta range %0d..%0d)",
               errors, pos_err, min_delta, max_delta);
      $fatal(1);
    end
    $finish;
  end

endmodule
