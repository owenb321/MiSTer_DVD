// =============================================================================
// quant_matrix_tb.sv -- does the picture get dequantised with the matrix the
//                       disc DOWNLOADED, across a VBUF flush?
//
// THE DEFECT (docs/quant_matrix.md). A menu still's sequence header downloads a
// custom quantiser matrix. rtl/mpeg2/vld.v resets its state machine only on
// `rst`, so a vbuf_flush leaves it mid-picture; when the flush level drops and
// the landing stream arrives, it resumes IN THAT STALE STATE and can eat
// 00 00 01 B3 and the 128-byte download before resyncing on a later start code.
// rtl/mpeg2/iquant.v then keeps default_values=1 -- it clears only on a write to
// address 0x3F -- so the WHOLE custom matrix is discarded and the picture is
// dequantised with the MPEG defaults: every AC coefficient 4x to 20.75x too big.
// On screen that is a "deep fried" menu still.
//
// WHAT THIS BENCH MEASURES, AND WHY IT IS NOT A GOLDEN MODEL
// ----------------------------------------------------------
// It compares the matrix the hardware ends up holding against THE BYTES ON THE
// DISC (tools/quant_fixture.py parses the download and writes <stem>.qmat.hex).
// It does NOT assert on `default_values`, which is the flag the fix touches --
// that is reported as diagnostic only. So the pass condition cannot degenerate
// into a copy of the RTL's own expression, which is how field_parity_tb and
// dvd_vm_ref.py both went green over real defects (memory: bench-that-cannot-
// fail).
//
// The read port is a SHADOW pair of the same two matrix modules, fed the
// identical rld write stream. That is not a model: it is the same RTL with the
// same stimulus, instantiated only because rld drives the live RAM's read
// address and a bench cannot sweep it.
//
// ⚠⚠ FIDELITY DETAIL THAT WILL SILENTLY INVERT THE VERDICT. On hardware
// mpeg2video.v holds the VBUF in reset for the whole flush level
// (`.asyncrst(rst && ~flush_vbuf_eff)`), so NO landing byte can reach getbits
// until the level drops. seek_realign_tb keeps feeding across its jump; this
// bench must not. If it did, the FIXED forced hunt would eat real landing start
// codes and the arm would condemn correct RTL. +FEEDTHRU=1 reproduces that
// hazard on purpose, as a documented negative arm, so nobody "simplifies" the
// feed model back.
//
// Plusargs / parameters:
//   QM_FIX=0     tie vld.vbuf_flush low -> pre-fix vld (the RED arm)
//   +FLUSHDLY=n  cycles after the arm point before the flush fires (swept)
//   +NOFLUSH=1   control A: walk the same splice with NO flush (the sharp one)
//   +COLDSTART=1 control B: feed the landing alone, no cut A at all
//   +FEEDTHRU=1  negative arm: keep feeding through the flush window
//   +REDECODE=1  v0.4.0 replay: decode cut B a SECOND time, no flush between
//   +FREEZE=1    hold motcomp_busy across the window (clk_en-gating arm)
// =============================================================================
`timescale 1ns/1ps

module quant_matrix_tb;

  parameter QM_FIX = 1;

  reg clk = 0; always #5 clk = ~clk;
  reg rst = 0;

  localparam MAXW = 140000;
  reg [63:0] es [0:MAXW-1];
  integer    es_words = 0;

  reg [31:0] meta [0:7];
  reg  [7:0] qmat  [0:63];            // expected intra, RASTER order
  reg  [7:0] qmatn [0:63];            // expected non-intra, RASTER order
  integer    b_word, pics_a, load_intra, load_nonintra;
  integer    alt_a, idc_b, qst_b, pics_b;

  integer flushdly = 0, noflush = 0, feedthru = 0, redecode = 0, freeze = 0;
  integer coldstart = 0;
  reg [1023:0] fixture;

  // ---- ES feed -------------------------------------------------------------
  wire        vid_in_rd_en;
  reg         vid_in_rd_valid = 0;
  reg  [63:0] vid_in = 64'h0;
  integer     rd_ptr = 0;
  reg         feed_en = 1'b0;

  always @(posedge clk) begin
    vid_in_rd_valid <= 1'b0;
    if (rst && feed_en && vid_in_rd_en && (rd_ptr < es_words)) begin
      vid_in          <= es[rd_ptr];
      vid_in_rd_valid <= 1'b1;
      rd_ptr          <= rd_ptr + 1;
    end
  end

  // ---- getbits + vld -------------------------------------------------------
  wire  [4:0] advance;
  wire        align, wait_state;
  wire [23:0] getbits;
  wire        signbit, getbits_valid, vld_en;
  reg         motcomp_busy = 1'b0;
  wire        rld_wr_almost_full;

  reg flush_lvl = 1'b0;                     // the ~192 clk_dec VBUF flush level

  // ★ Mirrors mpeg2video.v's wiring: the bit window is flushed WITH the VBUF.
  // It used to be on sync_rst, so after a flush the 129-bit window still held
  // up to 16 bytes of the stream that had just been discarded -- while pos_clr
  // was already clearing the position counter at the same flush, so content and
  // position disagreed. The parser then matched a phantom start code inside
  // that residue, dispatched on it, left itself BIT-MISALIGNED and walked past
  // the landing's real 00 00 01 B3.
  // MEASURED over the flush sweep: vld's flush_resync alone recovers 9 of 10
  // positions and this closes the tenth (the flush landing at a picture
  // header). QM_FIX=0 restores BOTH pre-fix behaviours, so the RED arm is a
  // faithful pre-fix core and not a half-fixed one.
  getbits_fifo getbits_fifo (
    .clk(clk), .clk_en(1'b1), .rst(QM_FIX ? (rst && ~flush_lvl) : rst),
    .vid_in(vid_in), .vid_in_rd_en(vid_in_rd_en), .vid_in_rd_valid(vid_in_rd_valid),
    .advance(advance), .align(align), .wait_state(wait_state),
    // ⚠ NOT tied off: the rld fifo's backpressure is part of the timing under
    // test -- it decides where the flush lands relative to the parse.
    .rld_wr_almost_full(rld_wr_almost_full), .mvec_wr_almost_full(1'b0),
    .motcomp_busy(motcomp_busy),
    .getbits(getbits), .signbit(signbit),
    .getbits_valid(getbits_valid), .vld_en(vld_en),
    .pos_clr(1'b0), .bitpos()
  );

  wire  [7:0] quant_wr_data_wr;
  wire  [5:0] quant_wr_addr_wr;
  wire        quant_rst_wr, quant_wr_intra_wr, quant_wr_non_intra_wr;
  wire        quant_wr_chroma_intra_wr, quant_wr_chroma_non_intra_wr;
  wire        rld_wr_en;
  wire  [1:0] rld_cmd_wr;
  wire  [5:0] dct_coeff_wr_run;
  wire [11:0] dct_coeff_wr_signed_level;
  wire        dct_coeff_wr_end;
  wire        alternate_scan, q_scale_type, macroblock_intra, mpeg1_es;
  wire  [4:0] quantiser_scale_code;
  wire  [1:0] intra_dc_precision;
  wire        update_picture_buffers, last_frame, vld_err;
  wire  [2:0] picture_coding_type;

  vld vld (
    .clk(clk), .clk_en(vld_en), .rst(rst),
    .getbits(getbits), .signbit(signbit),
    .advance(advance), .align(align), .wait_state(wait_state),
    .quant_wr_data(quant_wr_data_wr), .quant_wr_addr(quant_wr_addr_wr),
    .quant_rst(quant_rst_wr),
    .wr_intra_quant(quant_wr_intra_wr), .wr_non_intra_quant(quant_wr_non_intra_wr),
    .wr_chroma_intra_quant(quant_wr_chroma_intra_wr),
    .wr_chroma_non_intra_quant(quant_wr_chroma_non_intra_wr),
    .rld_wr_en(rld_wr_en), .rld_cmd(rld_cmd_wr),
    .dct_coeff_run(dct_coeff_wr_run),
    .dct_coeff_signed_level(dct_coeff_wr_signed_level),
    .dct_coeff_end(dct_coeff_wr_end),
    .alternate_scan(alternate_scan), .q_scale_type(q_scale_type),
    .quantiser_scale_code(quantiser_scale_code),
    .macroblock_intra(macroblock_intra), .intra_dc_precision(intra_dc_precision),
    .matrix_coefficients(),
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
    .last_frame(last_frame), .chroma_format(), .motion_vector_valid(),
    .pmv_0_0_0(), .pmv_0_0_1(), .pmv_1_0_0(), .pmv_1_0_1(),
    .pmv_0_1_0(), .pmv_0_1_1(), .pmv_1_1_0(), .pmv_1_1_1(),
    .dmv_0_0(), .dmv_0_1(), .dmv_1_0(), .dmv_1_1(),
    .progressive_sequence(), .progressive_frame(),
    .top_field_first(), .repeat_first_field(),
    .vld_err(vld_err),
    .drop_pic_req(1'b0), .drop_pic_ack(), .drop_pic_rff(), .drop_pic_field(),
    .dbg_drop_probe(),
    .flags_commit(), .pic_informative(), .informative_commit(),
    .cc_pair_valid(), .cc_pair(), .cc_pair_field(), .mpeg1(mpeg1_es),
    .vbuf_flush(QM_FIX ? flush_lvl : 1'b0),
    .bitpos(32'd0), .pic_hdr_pulse(), .pic_hdr_bitpos(), .pic_hdr_upd(),
    .pic_hdr_second()
  );

  // ---- rld_fifo + rld ------------------------------------------------------
  wire  [5:0] dct_coeff_rd_run;
  wire [11:0] dct_coeff_rd_signed_level;
  wire        dct_coeff_rd_end;
  wire        alternate_scan_rd, q_scale_type_rd, macroblock_intra_rd, mpeg1_es_rd;
  wire  [1:0] intra_dc_precision_rd;
  wire  [4:0] quantiser_scale_code_rd;
  wire  [7:0] quant_wr_data_rd;
  wire  [5:0] quant_wr_addr_rd;
  wire        quant_rst_rd, quant_wr_intra_rd, quant_wr_non_intra_rd;
  wire        quant_wr_chroma_intra_rd, quant_wr_chroma_non_intra_rd;
  wire  [1:0] rld_cmd_rd;
  wire        rld_rd_en, rld_rd_valid;

  rld_fifo rld_fifo (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .dct_coeff_wr_run(dct_coeff_wr_run),
    .dct_coeff_wr_signed_level(dct_coeff_wr_signed_level),
    .dct_coeff_wr_end(dct_coeff_wr_end),
    .alternate_scan_wr(alternate_scan), .macroblock_intra_wr(macroblock_intra),
    .intra_dc_precision_wr(intra_dc_precision), .q_scale_type_wr(q_scale_type),
    .quantiser_scale_code_wr(quantiser_scale_code), .mpeg1_wr(mpeg1_es),
    .quant_wr_data_wr(quant_wr_data_wr), .quant_wr_addr_wr(quant_wr_addr_wr),
    .quant_rst_wr(quant_rst_wr), .quant_wr_intra_wr(quant_wr_intra_wr),
    .quant_wr_non_intra_wr(quant_wr_non_intra_wr),
    .quant_wr_chroma_intra_wr(quant_wr_chroma_intra_wr),
    .quant_wr_chroma_non_intra_wr(quant_wr_chroma_non_intra_wr),
    .rld_cmd_wr(rld_cmd_wr), .rld_wr_en(rld_wr_en),
    .rld_wr_almost_full(rld_wr_almost_full), .rld_wr_overflow(),
    .dct_coeff_rd_run(dct_coeff_rd_run),
    .dct_coeff_rd_signed_level(dct_coeff_rd_signed_level),
    .dct_coeff_rd_end(dct_coeff_rd_end),
    .alternate_scan_rd(alternate_scan_rd),
    .macroblock_intra_rd(macroblock_intra_rd),
    .intra_dc_precision_rd(intra_dc_precision_rd),
    .q_scale_type_rd(q_scale_type_rd),
    .quantiser_scale_code_rd(quantiser_scale_code_rd), .mpeg1_rd(mpeg1_es_rd),
    .quant_wr_data_rd(quant_wr_data_rd), .quant_wr_addr_rd(quant_wr_addr_rd),
    .quant_rst_rd(quant_rst_rd), .quant_wr_intra_rd(quant_wr_intra_rd),
    .quant_wr_non_intra_rd(quant_wr_non_intra_rd),
    .quant_wr_chroma_intra_rd(quant_wr_chroma_intra_rd),
    .quant_wr_chroma_non_intra_rd(quant_wr_chroma_non_intra_rd),
    .rld_cmd_rd(rld_cmd_rd), .rld_rd_en(rld_rd_en), .rld_rd_valid(rld_rd_valid)
  );

  wire       quant_rst;
  wire [5:0] quant_rd_addr;
  wire [7:0] quant_rd_intra_data, quant_rd_non_intra_data;
  wire [7:0] quant_wr_data;
  wire [5:0] quant_wr_addr;
  wire       quant_wr_en_intra, quant_wr_en_non_intra;
  wire       quant_wr_en_chroma_intra, quant_wr_en_chroma_non_intra;
  wire       quant_alternate_scan;
  wire       iquant_valid, iquant_eob;
  wire [11:0] iquant_level;

  rld rld (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .idct_fifo_almost_full(1'b0),
    .dct_coeff_rd_run(dct_coeff_rd_run),
    .dct_coeff_rd_signed_level(dct_coeff_rd_signed_level),
    .dct_coeff_rd_end(dct_coeff_rd_end),
    .alternate_scan_rd(alternate_scan_rd), .q_scale_type_rd(q_scale_type_rd),
    .macroblock_intra_rd(macroblock_intra_rd),
    .intra_dc_precision_rd(intra_dc_precision_rd),
    .quantiser_scale_code_rd(quantiser_scale_code_rd), .mpeg1_rd(mpeg1_es_rd),
    .quant_wr_data_rd(quant_wr_data_rd), .quant_wr_addr_rd(quant_wr_addr_rd),
    .quant_rst_rd(quant_rst_rd), .quant_wr_intra_rd(quant_wr_intra_rd),
    .quant_wr_non_intra_rd(quant_wr_non_intra_rd),
    .quant_wr_chroma_intra_rd(quant_wr_chroma_intra_rd),
    .quant_wr_chroma_non_intra_rd(quant_wr_chroma_non_intra_rd),
    .rld_cmd_rd(rld_cmd_rd), .rld_rd_en(rld_rd_en), .rld_rd_valid(rld_rd_valid),
    .quant_rst(quant_rst), .quant_rd_addr(quant_rd_addr),
    .quant_rd_intra_data(quant_rd_intra_data),
    .quant_rd_non_intra_data(quant_rd_non_intra_data),
    .quant_wr_data(quant_wr_data), .quant_wr_addr(quant_wr_addr),
    .quant_wr_en_intra(quant_wr_en_intra),
    .quant_wr_en_non_intra(quant_wr_en_non_intra),
    .quant_wr_en_chroma_intra(quant_wr_en_chroma_intra),
    .quant_wr_en_chroma_non_intra(quant_wr_en_chroma_non_intra),
    .quant_alternate_scan(quant_alternate_scan),
    .iquant_level(iquant_level), .iquant_eob(iquant_eob),
    .iquant_valid(iquant_valid)
  );

  // ---- the live matrices, exactly as mpeg2video wires them ----------------
  intra_quant_matrix intra_quantiser_matrix (
    .clk(clk), .rst(rst),
    .rd_addr(quant_rd_addr), .rd_clk_en(1'b1), .dta_out(quant_rd_intra_data),
    .wr_addr(quant_wr_addr), .dta_in(quant_wr_data), .wr_clk_en(1'b1),
    .wr_en(quant_wr_en_intra), .rst_values(quant_rst),
    .alternate_scan(quant_alternate_scan)
  );
  non_intra_quant_matrix non_intra_quantiser_matrix (
    .clk(clk), .rst(rst),
    .rd_addr(quant_rd_addr), .rd_clk_en(1'b1), .dta_out(quant_rd_non_intra_data),
    .wr_addr(quant_wr_addr), .dta_in(quant_wr_data), .wr_clk_en(1'b1),
    .wr_en(quant_wr_en_non_intra), .rst_values(quant_rst),
    .alternate_scan(quant_alternate_scan)
  );

  // ---- SHADOW pair: identical RTL, identical stimulus, bench-driven read ---
  reg  [5:0] sh_addr = 6'd0;
  wire [7:0] sh_intra_do, sh_nonintra_do;

  intra_quant_matrix shadow_intra (
    .clk(clk), .rst(rst),
    .rd_addr(sh_addr), .rd_clk_en(1'b1), .dta_out(sh_intra_do),
    .wr_addr(quant_wr_addr), .dta_in(quant_wr_data), .wr_clk_en(1'b1),
    .wr_en(quant_wr_en_intra), .rst_values(quant_rst),
    .alternate_scan(quant_alternate_scan)
  );
  non_intra_quant_matrix shadow_nonintra (
    .clk(clk), .rst(rst),
    .rd_addr(sh_addr), .rd_clk_en(1'b1), .dta_out(sh_nonintra_do),
    .wr_addr(quant_wr_addr), .dta_in(quant_wr_data), .wr_clk_en(1'b1),
    .wr_en(quant_wr_en_non_intra), .rst_values(quant_rst),
    .alternate_scan(quant_alternate_scan)
  );

  // ---- instrumentation -----------------------------------------------------
  integer cyc = 0, pics_seen = 0, pics_after = 0;
  integer downloads = 0, dl_bytes = 0;
  reg     in_b = 1'b0, armed = 1'b0, flush_done = 1'b0;
  integer flush_at = 0, vlden_in_window = 0;
  reg [7:0] state_at_flush = 8'hFF;
  reg       used [0:255];                 // distinct quant_mat values seen in cut B
  integer   i, used_n = 0, foreign_n = 0;
  integer   redecode_pending = 0;
  integer   dl_before = 0;
  integer   seq_after = 0, nsc_after = 0, sc_after = 0, qrst_after = 0;
  integer   fr_cycles = 0; reg [7:0] state_after_flush = 8'hFF; reg got_first = 0;
  reg [7:0] first_codes [0:11]; integer n_codes = 0;

  // Bounded so an arm that never resyncs still finishes. SETTLE_MAX is ~1.5x
  // the cycles a healthy landing needs to reach its download; SETTLE_TAIL then
  // lets coefficients flow for the quant_mat corroboration.
  localparam SETTLE_MAX  = 400000;
  localparam SETTLE_TAIL = 60000;

  always @(posedge clk) if (rst) begin
    cyc <= cyc + 1;
    if (update_picture_buffers) begin
      pics_seen <= pics_seen + 1;
      if (in_b) pics_after <= pics_after + 1;
    end
    // a completed intra download: 64 in-order writes ending at 0x3F
    if (quant_wr_en_intra) begin
      dl_bytes <= dl_bytes + 1;
      if (quant_wr_addr == 6'h3f) downloads <= downloads + 1;
    end
    if (flush_lvl && vld_en) vlden_in_window <= vlden_in_window + 1;
    if (in_b && vld_en) begin
      if (vld.state == vld.STATE_SEQUENCE_HEADER)  seq_after <= seq_after + 1;
      if (vld.state == vld.STATE_NEXT_START_CODE)  nsc_after <= nsc_after + 1;
      if (vld.state == vld.STATE_START_CODE)       sc_after  <= sc_after  + 1;
    end
    if (in_b && quant_rst) qrst_after <= qrst_after + 1;
    if (vld.flush_resync) fr_cycles <= fr_cycles + 1;
    if (in_b && vld_en && !got_first) begin
      state_after_flush <= vld.state; got_first <= 1'b1;
    end
    // what start codes did it actually dispatch on, in order?
    if (in_b && vld_en && (vld.state == vld.STATE_START_CODE) && n_codes < 12) begin
      first_codes[n_codes] <= getbits[7:0];
      n_codes <= n_codes + 1;
    end
    // distinct matrix values actually used while cut B's picture dequantises
    if (in_b && iquant_valid && macroblock_intra_rd) begin
      if (!used[rld.quant_mat]) begin
        used[rld.quant_mat] <= 1'b1;
        used_n              <= used_n + 1;
      end
    end
  end

  // ---- scenario ------------------------------------------------------------
  integer k, mism_i = 0, mism_n = 0, perm_i = 0;
  reg [7:0] got;
  integer   exp_multiset [0:255];
  integer   got_multiset  [0:255];

  initial begin
    if (!$value$plusargs("fixture=%s", fixture)) fixture = "bench/dvd/test_vobs/quant_matrix";
    if ($value$plusargs("FLUSHDLY=%d", flushdly)) ;
    if ($value$plusargs("NOFLUSH=%d",  noflush))  ;
    if ($value$plusargs("FEEDTHRU=%d", feedthru)) ;
    if ($value$plusargs("REDECODE=%d", redecode)) ;
    if ($value$plusargs("FREEZE=%d",   freeze))   ;
    if ($value$plusargs("COLDSTART=%d", coldstart)) ;

    $readmemh({fixture, ".hex"}, es);
    $readmemh({fixture, ".meta.hex"}, meta);
    $readmemh({fixture, ".qmat.hex"}, qmat);
    $readmemh({fixture, ".qmatn.hex"}, qmatn);
    for (i = 0; i < MAXW; i = i + 1)
      if (es[i] !== 64'hxxxxxxxxxxxxxxxx) es_words = i + 1;
    b_word        = meta[0];  pics_a        = meta[1];
    load_intra    = meta[2];  load_nonintra = meta[3];
    alt_a         = meta[4];  idc_b         = meta[5];
    qst_b         = meta[6];  pics_b        = meta[7];
    for (i = 0; i < 256; i = i + 1) used[i] = 1'b0;

    if (es_words < 16) begin
      $display("SKIP: no fixture at %0s.hex -- run tools/quant_fixture.py", fixture);
      $finish;
    end
    $display("== quant_matrix_tb: QM_FIX=%0d FLUSHDLY=%0d NOFLUSH=%0d FEEDTHRU=%0d REDECODE=%0d FREEZE=%0d",
             QM_FIX, flushdly, noflush, feedthru, redecode, freeze);
    $display("   fixture %0d words, cut B at word %0d, cut A %0d pics, cut B %0d pics, load_intra=%0d",
             es_words, b_word, pics_a, pics_b, load_intra);

    #100 rst = 1;
    // ⚠ intra_quant_matrix/non_intra_quant_matrix run a 64-cycle STATE_CLEAR
    // init out of reset, and writes during it are overridden by the clear loop.
    // Feeding immediately let a COLDSTART download start inside that window and
    // lose its first ten entries -- which reads exactly like the defect (got=0
    // at the first ten ZIGZAG positions) and is pure bench artifact: on hardware
    // the decoder cannot reach a sequence header within 64 cycles of reset.
    repeat (200) @(posedge clk);
    feed_en = 1'b1;

    if (coldstart) begin
      // CONTROL B: a cold start on the landing alone -- cut A is never fed.
      // Proves the measurement can report SUCCESS at all, i.e. that a passing
      // arm means something.
      in_b   = 1'b1;
      rd_ptr = b_word;
    end else if (noflush) begin
      // ★ CONTROL A, and the sharp one: walk the SAME splice with no flush, so
      // the flush is the only variable between this arm and arm [2]. MEASURED
      // to pass on unmodified RTL (downloads=1, 0/64 mismatches).
      //
      // It passes because without a flush the parser still has cut A's ~400
      // trailing bytes to chew, errors out on them and resyncs BEFORE the
      // landing's sequence header arrives. A flush discards that tail and hands
      // the stale parser the landing directly -- which is exactly the real
      // mechanism, and exactly why this A/B isolates it.
      in_b = 1'b1;
      // Far enough into the landing that the parser has met its sequence
      // header, no further: the settle below stops on the download itself, and
      // decoding deeper into a 233 kB I-frame costs minutes and proves nothing.
      wait (rd_ptr > b_word + 40);
    end else begin
      // Arm once the vld is inside cut A, then wait FLUSHDLY cycles so the
      // sweep lands the flush at different parse positions.
      wait (pics_seen >= 1);
      armed = 1'b1;
      repeat (flushdly) @(posedge clk);

      state_at_flush = vld.state;
      flush_at       = cyc;
      flush_lvl      = 1'b1;
      if (freeze) motcomp_busy = 1'b1;
      // ⚠ the VBUF is in reset for the whole level on hardware: no landing byte
      // can arrive yet. +FEEDTHRU=1 breaks that on purpose (negative arm).
      if (!feedthru) feed_en = 1'b0;
      rd_ptr = b_word;                    // the reader has jumped
      repeat (192) @(posedge clk);        // the real flush level
      flush_lvl  = 1'b0;
      feed_en    = 1'b1;
      motcomp_busy = 1'b0;
      flush_done = 1'b1;
      in_b       = 1'b1;
    end

    // Run until the landing's download has landed, or give up. Decoding the
    // whole 233 kB still would cost minutes of wall clock and prove nothing
    // extra: the matrix is written at the sequence header, in the landing's
    // first few hundred bytes. The extra window afterwards lets coefficients
    // flow so the `quant_mat` corroboration has something to look at.
    // Stop as soon as the landing has been RESOLVED either way: the download
    // landed (healthy) or a picture decoded without it (fried). Waiting the
    // full backstop in the fried case cost 121 s a run and proved nothing.
    dl_before = downloads;
    fork : settle
      begin wait (downloads > dl_before); disable settle; end
      begin wait (pics_after >= 1);       disable settle; end
      begin repeat (SETTLE_MAX) @(posedge clk); disable settle; end
    join
    repeat (SETTLE_TAIL) @(posedge clk);

    if (redecode) begin
      // v0.4.0's cold re-decode: re-stream the SAME cell, no flush between.
      $display("   [redecode] replaying cut B (this is what v0.4.0 did)");
      for (i = 0; i < 256; i = i + 1) used[i] = 1'b0;
      used_n = 0;
      dl_before = downloads;
      rd_ptr = b_word;
      fork : settle2
        begin wait (downloads > dl_before); disable settle2; end
        begin repeat (SETTLE_MAX) @(posedge clk); disable settle2; end
      join
      repeat (SETTLE_TAIL) @(posedge clk);
    end

    // ---- primary: sweep the shadow RAM and compare against the disc --------
    for (i = 0; i < 256; i = i + 1) begin
      exp_multiset[i] = 0; got_multiset[i] = 0;
    end
    for (k = 0; k < 64; k = k + 1) begin
      sh_addr = k[5:0];
      @(posedge clk); @(posedge clk); @(posedge clk);
      got = sh_intra_do;
      exp_multiset[qmat[k]] = exp_multiset[qmat[k]] + 1;
      got_multiset[got]     = got_multiset[got] + 1;
      if (got !== qmat[k]) begin
        if (mism_n < 8)
          $display("   MISMATCH addr=%0d got=%0d want=%0d", k, got, qmat[k]);
        mism_n = mism_n + 1;
      end
    end
    // A PERMUTATION is the iquant.v scan bug; a wholesale default matrix is the
    // flush bug. Distinguishing them in the report is the difference between
    // two very different fixes.
    perm_i = 1;
    for (i = 0; i < 256; i = i + 1)
      if (exp_multiset[i] != got_multiset[i]) perm_i = 0;

    $display("SUMMARY: mismatches=%0d/64 permutation=%0d downloads=%0d dl_bytes=%0d pics_after_flush=%0d default_values=%0b state_at_flush=%0h vlden_in_window=%0d distinct_used=%0d",
             mism_n, (mism_n > 0) && perm_i, downloads, dl_bytes, pics_after,
             shadow_intra.default_values, state_at_flush, vlden_in_window, used_n);
    $display("DIAG: seqhdr_after=%0d startcode_after=%0d nextsc_after=%0d quant_rst_after=%0d",
             seq_after, sc_after, nsc_after, qrst_after);
    $write("DIAG: flush_resync_cycles=%0d state_at_first_en_after_flush=%0h codes=",
           fr_cycles, state_after_flush);
    for (i = 0; i < n_codes; i = i + 1) $write("%02h ", first_codes[i]);
    $display("");

    // Anti-vacuity: if nothing decoded after the flush the arm proves nothing.
    if (!noflush && !coldstart && pics_after == 0)
      $display("VACUOUS: no picture decoded after the flush -- move +FLUSHDLY");

    if (mism_n == 0) $display("RESULT: PASS (matrix matches the disc)");
    else             $display("RESULT: FRIED (%0d/64 entries wrong)", mism_n);
    $finish;
  end

  initial begin
    #400000000;
    $display("SUMMARY: mismatches=99 TIMEOUT");
    $display("RESULT: TIMEOUT");
    $finish;
  end

endmodule
