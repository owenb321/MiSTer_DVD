/*
 * vld_mpeg1_tb.sv — MPEG-1 parse-level gate for the vld (docs/mpeg1.md Part B).
 *
 * Runs the REAL vld + getbits_fifo + motcomp_picbuf (with the motcomp freeze
 * interlock) over an MPEG-1 elementary stream and self-checks:
 *   (a) pictures actually parse (per-type counts >= thresholds — the MPEG-2-era
 *       gate at CODE_PICTURE_START required sequence_extension_seen and stalled
 *       forever on MPEG-1);
 *   (b) no vld_err over the whole run;
 *   (c) the COMMITTED display flags are the MPEG-1 constants — every picbuf
 *       emission must read progressive_frame=1, rff=0, tff=0 (the flags_commit
 *       trap: with no coding extension the MPEG-2 commit pulse never fires);
 *   (d) horizontal_size/vertical_size == 352x240 (incl. the extension-loaded
 *       [13:12] MSBs muxed to 0);
 *   (e) DCT coefficients actually flow (rld_wr_en RLD_DCT writes > threshold);
 *   (f) the vld's mpeg1 flag is latched.
 * With +REQ=1 the frame-drop governor path is exercised too: acks must occur
 * (drop_ps_lat trap — MPEG-1 has no STATE_PICTURE_CODING_EXT0, so without the
 * mpeg1 arm the governor could never drop) and every ack must report rff=0 and
 * field=0.
 *
 * +HAND=1 runs a small hand-assembled MPEG-1 stream embedded below (sequence
 * header + one I picture + one slice) that deterministically covers the syntax
 * ffmpeg never emits, with a BYTE-EXACT golden coefficient list:
 *   - macroblock_stuffing ('0000 0001 111') x2 before the first addr_inc;
 *   - all three MPEG-1 escape-level forms: direct signed 8-bit (-1),
 *     double-byte positive (0x00 b => +133), double-byte negative
 *     (0x80 b => -129).
 *
 * Build (note: unlike vld_drop_rff_tb's documented line, motcomp_picbuf.v is
 * required — that TB's header omits it):
 *   iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/vld_mpeg1_sim \
 *       rtl/mpeg2/vld.v rtl/mpeg2/getbits.v rtl/mpeg2/motcomp_picbuf.v \
 *       bench/dvd/vld_mpeg1_tb.sv
 *   vvp bench/dvd/vld_mpeg1_sim +ES=bench/dvd/test_vobs/m1v_test.hex
 *   vvp bench/dvd/vld_mpeg1_sim +ES=bench/dvd/test_vobs/m1v_test.hex +REQ=1
 *   vvp bench/dvd/vld_mpeg1_sim +HAND=1
 *
 * Fixture regen (bench/dvd/test_vobs/ is gitignored — do not commit):
 *   mkdir -p bench/dvd/test_vobs
 *   ffmpeg -y -loglevel error -f lavfi \
 *       -i "testsrc2=size=352x240:rate=30000/1001:duration=4" \
 *       -c:v mpeg1video -b:v 1150k -bf 2 -f mpeg1video /tmp/m1v_test.m1v
 *   python3 -c "
 *   d=open('/tmp/m1v_test.m1v','rb').read(); d+=b'\x00'*(-len(d)%8)
 *   open('bench/dvd/test_vobs/m1v_test.hex','w').write(
 *       '\n'.join(d[i:i+8].hex() for i in range(0,len(d),8)))"
 *   ffprobe census of that stream (asserted approximately below):
 *       11 I / 30 P / 79 B  (120 pictures)
 *
 * +ES     : $readmemh file, 64-bit big-endian words (first byte in [63:56]).
 * +MAXPIC : stop after N coded pictures (default 115 — just before EOS).
 * +REQ=1  : hold drop_pic_req high (default 0 for the pure parse gate).
 * +MINI/+MINP/+MINB : per-type picture-count thresholds (default 10/25/70;
 *           pass +MINB=0 etc. for I/P-only or differently coded streams).
 * +HS/+VS : expected coded size (default 352/240).
 * +MINDCT : minimum RLD_DCT coefficient writes (default 10000).
 */
`timescale 1ns/1ps

module vld_mpeg1_tb;

  reg clk = 0; always #5 clk = ~clk;
  reg rst = 0;

  // ---- ES feed: behavioral vbuf-read fifo (64-bit, big-endian words) ----
  localparam MAXW = 2 ** 21;
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
    .getbits_valid(getbits_valid), .vld_en(vld_en)
  );

  reg  drop_pic_req = 1'b0;
  wire drop_pic_ack, drop_pic_rff, drop_pic_field;
  wire update_picture_buffers, flags_commit;
  wire [2:0] picture_coding_type;
  wire repeat_first_field, top_field_first, progressive_frame, progressive_sequence;
  wire [13:0] horizontal_size, vertical_size;
  wire [1:0]  chroma_format;
  wire vld_err, mpeg1_flag;

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
    .horizontal_size(horizontal_size), .vertical_size(vertical_size),
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
    .last_frame(), .chroma_format(chroma_format), .motion_vector_valid(),
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
    .flags_commit(flags_commit),
    .mpeg1(mpeg1_flag),
    .vbuf_flush(1'b0)   // DVD-FORK FIX (seek realign, issue #45): not exercised here
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
    .top_field_first(top_field_first),
    .repeat_first_field(repeat_first_field),
    .last_frame(1'b0),
    .update_picture_buffers(update_picture_buffers),
    .flags_commit(flags_commit),
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

  // governor stub: one clean pickup per presented frame (as in vld_drop_rff_tb),
  // checking the committed flags at every emission — check (c).
  integer emits = 0;
  reg gov_ack;
  always @(posedge clk)
    if (~rst) begin output_frame_rd <= 1'b0; gov_ack <= 1'b0; end
    else begin
      output_frame_rd <= 1'b0;
      if (~gov_ack && output_frame_valid) begin
        emits = emits + 1;
        // First emission tolerated unchecked: at picture 1 the frame emitted is
        // picbuf's power-up slot content in some orderings. From then on every
        // emitted frame carries MPEG-1 constants.
        if (emits > 1 && !(out_pf === 1'b1 && out_rff === 1'b0 && out_tff === 1'b0))
          $fatal(1, "FAIL: emission %0d flags pf=%b rff=%b tff=%b (want 1/0/0 — stale-flag trap)",
                 emits, out_pf, out_rff, out_tff);
        output_frame_rd <= 1'b1;
        gov_ack <= 1'b1;
      end else if (gov_ack && ~output_frame_valid)
        gov_ack <= 1'b0;
    end

  // ---- per-picture logging + counters ----
  localparam [7:0] STATE_PICTURE_HEADER  = 8'h02;
  localparam [7:0] STATE_NEXT_MACROBLOCK = 8'h34;
  localparam [7:0] STATE_DCT_ESCAPE_B14  = 8'h79;
  localparam [7:0] STATE_DCT_ESCAPE_M1   = 8'h7d;

  integer maxpic = 115;
  integer nI = 0, nP = 0, nB = 0;
  integer errs = 0, drops = 0, bad_acks = 0;
  integer dct_writes = 0, esc_b14 = 0, esc_m1 = 0, stuff_cnt = 0;
  integer min_i = 10, min_p = 25, min_b = 70, min_dct = 10000;
  integer exp_hs = 352, exp_vs = 240;
  integer hand = 0, req_arg_v;

  // +TRACE=1: print every vld state transition (debug aid for hand vectors)
  integer trace = 0;
  reg [7:0] prev_state = 8'hff;
  always @(posedge clk)
    if (rst && trace && vld_en && (vld.state != prev_state)) begin
      $display("T=%0t state=%02h getbits=%06h", $time, vld.state, vld.getbits);
      prev_state <= vld.state;
    end

  always @(posedge clk) if (rst) begin
    if (vld_en && (vld.state == STATE_PICTURE_HEADER)) begin
      npic = npic + 1;
      case (vld.getbits[13:11])
        3'd1: nI = nI + 1;
        3'd2: nP = nP + 1;
        3'd3: nB = nB + 1;
      endcase
      if (!hand && (npic >= maxpic)) final_checks;
    end
    if (drop_pic_ack) begin
      drops = drops + 1;
      if (drop_pic_rff !== 1'b0 || drop_pic_field !== 1'b0) bad_acks = bad_acks + 1;
    end
    if (vld_en && vld_err) errs = errs + 1;
    // NB: rld_wr_en is a strict 1-cycle pulse (it self-clears on non-enabled cycles:
    // vld.v "else rld_wr_en <= 1'b0") — do NOT gate this on vld_en, the pulse can land
    // on a wait-state cycle where vld_en is low.
    if (vld.rld_wr_en && (vld.rld_cmd == 2'd0)) dct_writes = dct_writes + 1;
    if (vld_en && (vld.state == STATE_DCT_ESCAPE_B14) && vld.mpeg1) esc_b14 = esc_b14 + 1;
    if (vld_en && (vld.state == STATE_DCT_ESCAPE_M1)) esc_m1 = esc_m1 + 1;
    if (vld_en && (vld.state == STATE_NEXT_MACROBLOCK) && vld.macroblock_addr_inc_stuffing) stuff_cnt = stuff_cnt + 1;
  end

  task final_checks;
    begin
      $display("SUMMARY: pictures=%0d (I=%0d P=%0d B=%0d) errs=%0d dct_writes=%0d",
               npic, nI, nP, nB, errs, dct_writes);
      $display("         emits=%0d drops=%0d bad_acks=%0d esc_b14=%0d esc_m1=%0d stuffing=%0d",
               emits, drops, bad_acks, esc_b14, esc_m1, stuff_cnt);
      $display("         hsize=%0d vsize=%0d mpeg1=%b", horizontal_size, vertical_size, mpeg1_flag);
      if (errs != 0)                    $fatal(1, "FAIL: vld_err asserted (%0d cycles)", errs);
      if (nI < min_i)                   $fatal(1, "FAIL: I pictures %0d < %0d", nI, min_i);
      if (nP < min_p)                   $fatal(1, "FAIL: P pictures %0d < %0d", nP, min_p);
      if (nB < min_b)                   $fatal(1, "FAIL: B pictures %0d < %0d", nB, min_b);
      if (horizontal_size != exp_hs)    $fatal(1, "FAIL: horizontal_size %0d != %0d", horizontal_size, exp_hs);
      if (vertical_size != exp_vs)      $fatal(1, "FAIL: vertical_size %0d != %0d", vertical_size, exp_vs);
      if (mpeg1_flag !== 1'b1)          $fatal(1, "FAIL: vld.mpeg1 not latched");
      if (chroma_format != 2'd1)        $fatal(1, "FAIL: chroma_format %0d != 4:2:0", chroma_format);
      if (dct_writes < min_dct)         $fatal(1, "FAIL: only %0d DCT coefficient writes (< %0d)", dct_writes, min_dct);
      if (emits < 2)                    $fatal(1, "FAIL: only %0d picbuf emissions", emits);
      if (drop_pic_req && (drops == 0)) $fatal(1, "FAIL: +REQ=1 but zero drop acks (drop_ps_lat trap)");
      if (bad_acks != 0)                $fatal(1, "FAIL: %0d drop acks with rff/field != 0", bad_acks);
      $display("PASS");
      $finish;
    end
  endtask

  // ---- HAND mode: golden coefficient compare ----
  // Expected (run, level, end) writes for the embedded stream (see header).
  localparam integer NEXP = 15;
  reg  [5:0]        exp_run [0:NEXP-1];
  reg signed [11:0] exp_lvl [0:NEXP-1];
  reg               exp_end [0:NEXP-1];
  integer ncoef = 0;
  task set_exp(input integer i, input [5:0] r, input signed [11:0] l, input e);
    begin exp_run[i] = r; exp_lvl[i] = l; exp_end[i] = e; end
  endtask

  always @(posedge clk)
    if (rst && hand && vld.rld_wr_en && (vld.rld_cmd == 2'd0)) begin
      if (ncoef >= NEXP)
        $fatal(1, "FAIL(hand): extra coefficient write %0d (run=%0d lvl=%0d end=%b)",
               ncoef, vld.dct_coeff_run, vld.dct_coeff_signed_level, vld.dct_coeff_end);
      if (vld.dct_coeff_end !== exp_end[ncoef] ||
          (!exp_end[ncoef] && (vld.dct_coeff_run !== exp_run[ncoef] ||
                               vld.dct_coeff_signed_level !== exp_lvl[ncoef])))
        $fatal(1, "FAIL(hand): coeff %0d got (run=%0d lvl=%0d end=%b) want (run=%0d lvl=%0d end=%b)",
               ncoef, vld.dct_coeff_run, vld.dct_coeff_signed_level, vld.dct_coeff_end,
               exp_run[ncoef], exp_lvl[ncoef], exp_end[ncoef]);
      $display("HAND coeff %0d OK: run=%0d lvl=%0d end=%b",
               ncoef, vld.dct_coeff_run, vld.dct_coeff_signed_level, vld.dct_coeff_end);
      ncoef = ncoef + 1;
      if (ncoef == NEXP) hand_final;
    end

  task hand_final;
    begin
      #2000; // let trailing states settle
      $display("HAND SUMMARY: coeffs=%0d errs=%0d esc_b14=%0d esc_m1=%0d stuffing=%0d hsize=%0d vsize=%0d mpeg1=%b",
               ncoef, errs, esc_b14, esc_m1, stuff_cnt, horizontal_size, vertical_size, mpeg1_flag);
      if (errs != 0)        $fatal(1, "FAIL(hand): vld_err asserted");
      if (esc_b14 != 3)     $fatal(1, "FAIL(hand): esc_b14 %0d != 3", esc_b14);
      if (esc_m1 != 2)      $fatal(1, "FAIL(hand): esc_m1 %0d != 2 (double-byte escapes)", esc_m1);
      if (stuff_cnt != 2)   $fatal(1, "FAIL(hand): stuffing count %0d != 2", stuff_cnt);
      if (horizontal_size != 352 || vertical_size != 240)
                            $fatal(1, "FAIL(hand): size %0dx%0d", horizontal_size, vertical_size);
      if (mpeg1_flag !== 1'b1) $fatal(1, "FAIL(hand): mpeg1 not latched");
      $display("PASS");
      $finish;
    end
  endtask

  // ---- drive ----
  string esf;
  initial begin
    // golden list for HAND mode (block 0: DC + three escape forms + EOB;
    // Y1-3: DC 128 + EOB; Cb/Cr: DC 0 + EOB)
    set_exp( 0, 6'd0,  12'sd128, 1'b0);
    set_exp( 1, 6'd1, -12'sd1,   1'b0);
    set_exp( 2, 6'd2,  12'sd133, 1'b0);
    set_exp( 3, 6'd0, -12'sd129, 1'b0);
    set_exp( 4, 6'd0,  12'sd0,   1'b1);
    set_exp( 5, 6'd0,  12'sd128, 1'b0);
    set_exp( 6, 6'd0,  12'sd0,   1'b1);
    set_exp( 7, 6'd0,  12'sd128, 1'b0);
    set_exp( 8, 6'd0,  12'sd0,   1'b1);
    set_exp( 9, 6'd0,  12'sd128, 1'b0);
    set_exp(10, 6'd0,  12'sd0,   1'b1);
    set_exp(11, 6'd0,  12'sd0,   1'b0);
    set_exp(12, 6'd0,  12'sd0,   1'b1);
    set_exp(13, 6'd0,  12'sd0,   1'b0);
    set_exp(14, 6'd0,  12'sd0,   1'b1);

    void'($value$plusargs("MAXPIC=%d", maxpic));
    void'($value$plusargs("MINI=%d",   min_i));
    void'($value$plusargs("MINP=%d",   min_p));
    void'($value$plusargs("MINB=%d",   min_b));
    void'($value$plusargs("MINDCT=%d", min_dct));
    void'($value$plusargs("HS=%d",     exp_hs));
    void'($value$plusargs("VS=%d",     exp_vs));
    void'($value$plusargs("HAND=%d",   hand));
    void'($value$plusargs("TRACE=%d",  trace));
    if ($value$plusargs("REQ=%d", req_arg_v)) drop_pic_req = req_arg_v[0];

    if (hand) begin
      // Hand-assembled MPEG-1 ES (see header; 48 bytes). Seq header 352x240,
      // I picture, one slice: stuffing x2, one intra MB, escapes -1/+133/-129.
      es[0] = 64'h000001b31600f014;
      es[1] = 64'h02cee0a000000100;
      es[2] = 64'h000ffff800000101;
      es[3] = 64'h400780fff40020ff;
      es[4] = 64'h8210042820403fd2;
      es[5] = 64'h948880000001b700;
      // trailing zero padding: getbits_fifo starves ~2 words before true EOS,
      // so keep the real payload clear of the tail (zeros are hunt-over noise).
      es[6] = 64'h0; es[7] = 64'h0; es[8] = 64'h0; es[9] = 64'h0;
      es_words = 10;
    end else begin
      if (!$value$plusargs("ES=%s", esf)) esf = "bench/dvd/test_vobs/m1v_test.hex";
      $readmemh(esf, es);
      begin : count_words
        integer k;
        k = 0;
        while (k < MAXW && es[k] !== 64'hx) k = k + 1;
        es_words = k;
      end
    end
    $display("ES: %0d words (%0d bytes), drop_pic_req=%0d, maxpic=%0d, hand=%0d",
             es_words, es_words * 8, drop_pic_req, maxpic, hand);
    rst = 0;
    repeat (8) @(posedge clk);
    rst = 1;
  end

  initial begin
    #2_000_000_000;
    $fatal(1, "TIMEOUT: pictures=%0d (I=%0d P=%0d B=%0d) errs=%0d coeffs(hand)=%0d",
           npic, nI, nP, nB, errs, ncoef);
  end
endmodule
