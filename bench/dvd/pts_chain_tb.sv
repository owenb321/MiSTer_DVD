// =============================================================================
// pts_chain_tb.sv — byte positions through the REAL VBUF path, across a flush.
// =============================================================================
// pts_assoc_tb pins the vld's parse position against tools/pts_map.py with the
// ES fed straight into getbits. This bench closes the loop through everything
// that sits between the demux and getbits on hardware:
//
//   stream bytes -> vbuf_write (8-byte packer) -> vbuf_write_fifo
//     -> framestore_request -> [memory model with READ LATENCY] -> framestore_response
//     -> vbuf_read_fifo -> getbits_fifo -> vld
//
// and it does so across a VBUF FLUSH, which is where the two coordinates can
// silently diverge: up to 2**MEMTAG_DEPTH VBUF reads are in flight in the
// memory controller when the flush lands, and their responses arrive AFTER
// vbuf_read_fifo has been reset. Without the epoch tag (framestore_request /
// framestore_response TAG_VBUF1) those stale words are handed to the vld as
// the first words of the NEW stream, and every read-side position is off by
// exactly 8x that many bytes -- while the write side (dvd/vbuf_pos.sv) is not.
//
// Measured, not asserted-by-restatement: the golden offsets come from the
// Python model of the Program Stream, the write-side stamp from vbuf_pos, and
// the read-side position from getbits+vld. The checks are
//
//   [C1] pre-flush : stamp(mark k) == golden mark offset k, EXACTLY, and
//                    pos(picture j) == golden picture offset j, EXACTLY
//   [C2] post-flush: stamp(mark k) - golden(k) == pos(picture j) - golden(j)
//                    == one constant for the whole segment (the write and read
//                    sides agree on where byte 0 of the new stream landed),
//                    and that constant is small (a stale in-flight write word
//                    or two at most, never a stale READ)
//   [C3] the read fifo receives no word the framestore did not write for THIS
//        epoch (counted directly at vbr_wr_en against the model's issue log)
//
// The RED arm (bench/dvd/run_pts_assoc.sh --red) rebuilds framestore_response
// with the epoch compare removed; [C2]/[C3] must then FAIL.
//
// Build:
//   iverilog -g2012 -D__IVERILOG__ -I dvd/mem_override -I rtl/mpeg2 \
//       -o bench/dvd/pts_chain_sim rtl/mpeg2/vld.v rtl/mpeg2/getbits.v rtl/mpeg2/vbuf.v \
//       rtl/mpeg2/framestore.v rtl/mpeg2/framestore_request.v rtl/mpeg2/framestore_response.v \
//       rtl/mpeg2/synchronizer.v rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v rtl/mpeg2/xfifo_sc.v \
//       rtl/mpeg2/xilinx_fifo_dc.v rtl/mpeg2/read_write.v dvd/vbuf_pos.sv dvd/pts_assoc.sv bench/dvd/pts_chain_tb.sv
//   vvp bench/dvd/pts_chain_sim +STEM=bench/dvd/test_vobs/pts_apollo
// =============================================================================
`timescale 1ns/1ps
module pts_chain_tb;

`include "fifo_size.v"
`include "mem_codes.v"

  reg clk = 0; always #5 clk = ~clk;
  reg rst = 0;

  // ---------------------------------------------------------------- fixture
  parameter integer MAXW = 200000;
  parameter integer PRE_PICS = 8;           // flush after this many pre-flush pictures (the short fixture has 19)
  parameter integer RD_LAT   = 40;          // memory read latency, cycles (reads in flight at the flush)
  reg [63:0] es [0:MAXW-1];
  integer    es_words = 0;
  localparam MAXP = 8192;
  reg [71:0] gold  [0:MAXP-1];
  reg [71:0] marks [0:MAXP-1];
  integer    n_golden = 0, n_marks = 0;
  integer    errors = 0;
  reg        verbose = 0;
  integer    seg = 0;                       // 0 = pre-flush, 1 = post-flush

  // ------------------------------------------------------------ VBUF flush
  reg  flush_lvl = 0;                       // ~192-cycle level, as flush_vbuf_eff on hardware
  wire vbuf_rst;
  sync_reset sync_vbuf_reset (.clk(clk), .asyncrst(rst && ~flush_lvl), .syncrst(vbuf_rst));

  // ----------------------------------------------------------- stream feed
  reg        feed_on = 0;
  integer    feed_ptr = 0;                  // byte index into the fixture
  integer    feed_end = 0;
  integer    mark_ptr = 0;                  // next mark to emit
  wire       vbw_wr_almost_full;
  wire       stream_valid = feed_on && (feed_ptr < feed_end) && ~vbw_wr_almost_full && vbuf_rst;
  wire [63:0] es_word     = es[feed_ptr >> 3];
  wire [7:0] stream_data  = es_word[8 * (7 - (feed_ptr & 7)) +: 8];
  wire       stream_mark  = stream_valid && (mark_ptr < n_marks) && (feed_ptr == marks[mark_ptr][71:40]);

  // ------------------------------------------------------- packer + fifos
  wire [63:0] vbw_wr_dta;  wire vbw_wr_en;  wire [7:0] vbw_phase;
  vbuf_write vbuf_write (.clk(clk), .clk_en(1'b1), .rst(rst),
    .vid_in(stream_data), .vid_in_wr_en(stream_valid),
    .vid_out(vbw_wr_dta), .vid_out_wr_en(vbw_wr_en), .phase(vbw_phase));

  wire [63:0] vbw_rd_dta; wire vbw_rd_en, vbw_rd_valid, vbw_rd_empty, vbw_rd_almost_empty, vbw_wr_full;
  fifo_sc #(.addr_width(VBUF_WR_DEPTH), .dta_width(9'd64), .prog_thresh(VBUF_WR_THRESHOLD)) vbuf_write_fifo (
    .rst(vbuf_rst), .clk(clk), .din(vbw_wr_dta), .wr_en(vbw_wr_en), .wr_ack(), .full(vbw_wr_full),
    .overflow(), .dout(vbw_rd_dta), .rd_en(vbw_rd_en), .valid(vbw_rd_valid), .empty(vbw_rd_empty),
    .prog_empty(vbw_rd_almost_empty), .prog_full(vbw_wr_almost_full), .underflow());

  wire [63:0] vbr_wr_dta; wire vbr_wr_en, vbr_wr_ack, vbr_wr_full, vbr_wr_almost_full, vbr_rd_almost_empty;
  wire [63:0] vbr_rd_dta; wire vbr_rd_en, vbr_rd_valid;
  fifo_sc #(.addr_width(VBUF_RD_DEPTH), .dta_width(9'd64), .prog_thresh(VBUF_RD_THRESHOLD)) vbuf_read_fifo (
    .rst(vbuf_rst), .clk(clk), .din(vbr_wr_dta), .wr_en(vbr_wr_en), .wr_ack(vbr_wr_ack), .full(vbr_wr_full),
    .overflow(), .dout(vbr_rd_dta), .rd_en(vbr_rd_en), .valid(vbr_rd_valid), .empty(),
    .prog_empty(vbr_rd_almost_empty), .prog_full(vbr_wr_almost_full), .underflow());

  // ------------------------------------------------------------ framestore
  wire  [1:0] mem_req_rd_cmd;  wire [21:0] mem_req_rd_addr;  wire [63:0] mem_req_rd_dta;
  reg         mem_req_rd_en = 0; wire mem_req_rd_valid;
  reg  [63:0] mem_res_wr_dta = 0; reg mem_res_wr_en = 0; wire mem_res_wr_almost_full;
  wire [25:0] vbuf_wr_cnt; wire vbuf_wr_pulse;

  framestore framestore (
    .rst(rst), .clk(clk), .mem_clk(clk),
    .fwd_rd_addr_empty(1'b1), .fwd_rd_addr_en(), .fwd_rd_addr_valid(1'b0), .fwd_rd_addr(22'd0),
    .fwd_wr_dta_full(1'b0), .fwd_wr_dta_almost_full(1'b0), .fwd_wr_dta_en(), .fwd_wr_dta_ack(1'b0),
    .fwd_wr_dta(), .fwd_rd_dta_almost_empty(1'b1),
    .bwd_rd_addr_empty(1'b1), .bwd_rd_addr_en(), .bwd_rd_addr_valid(1'b0), .bwd_rd_addr(22'd0),
    .bwd_wr_dta_full(1'b0), .bwd_wr_dta_almost_full(1'b0), .bwd_wr_dta_en(), .bwd_wr_dta_ack(1'b0),
    .bwd_wr_dta(), .bwd_rd_dta_almost_empty(1'b1),
    .recon_rd_empty(1'b1), .recon_rd_almost_empty(1'b1), .recon_rd_en(), .recon_rd_valid(1'b0),
    .recon_rd_addr(22'd0), .recon_rd_dta(64'd0), .recon_wr_almost_full(1'b0),
    .disp_rd_addr_empty(1'b1), .disp_rd_addr_en(), .disp_rd_addr_valid(1'b0), .disp_rd_addr(22'd0),
    .disp_wr_dta_full(1'b0), .disp_wr_dta_almost_full(1'b0), .disp_wr_dta_en(), .disp_wr_dta_ack(1'b0),
    .disp_wr_dta(), .disp_rd_dta_almost_empty(1'b1),
    .osd_rd_empty(1'b1), .osd_rd_almost_empty(1'b1), .osd_rd_en(), .osd_rd_valid(1'b0),
    .osd_rd_addr(22'd0), .osd_rd_dta(64'd0), .osd_wr_almost_full(1'b0),
    .vbw_rd_empty(vbw_rd_empty), .vbw_rd_almost_empty(vbw_rd_almost_empty), .vbw_rd_en(vbw_rd_en),
    .vbw_rd_valid(vbw_rd_valid), .vbw_rd_dta(vbw_rd_dta), .vbw_wr_almost_full(vbw_wr_almost_full),
    .vb_flush(flush_lvl),
    .vbr_wr_full(vbr_wr_full), .vbr_wr_almost_full(vbr_wr_almost_full), .vbr_wr_dta(vbr_wr_dta),
    .vbr_wr_en(vbr_wr_en), .vbr_wr_ack(vbr_wr_ack), .vbr_rd_almost_empty(vbr_rd_almost_empty),
    .mem_req_wr_almost_full(), .mem_req_wr_full(), .mem_req_wr_overflow(),
    .mem_req_rd_cmd(mem_req_rd_cmd), .mem_req_rd_addr(mem_req_rd_addr), .mem_req_rd_dta(mem_req_rd_dta),
    .mem_req_rd_en(mem_req_rd_en), .mem_req_rd_valid(mem_req_rd_valid),
    .mem_res_wr_dta(mem_res_wr_dta), .mem_res_wr_en(mem_res_wr_en),
    .mem_res_wr_almost_full(mem_res_wr_almost_full), .mem_res_wr_full(), .mem_res_wr_overflow(),
    .tag_wr_almost_full(), .tag_wr_full(), .tag_wr_overflow(),
    .dbg_vbuf_fill(), .vbuf_wr_cnt(vbuf_wr_cnt), .vbuf_wr_pulse(vbuf_wr_pulse));

  // ------------------------------------------- memory model with latency
  // Reads are answered RD_LAT cycles after they are popped, in order; writes
  // land immediately. Responses are held while the response fifo is almost
  // full. Every read popped is logged with the epoch current at pop time, and
  // at delivery it is classed LIVE (same epoch) or STALE (a flush intervened).
  // [C3]: the framestore must hand the read fifo exactly the live ones.
  reg [63:0] mem [0:(1<<22)-1];
  reg [63:0] pipe_d  [0:255];
  reg        pipe_ep [0:255];
  integer    pipe_t  [0:255];
  integer    pipe_wp = 0, pipe_rp = 0, cyc = 0;
  wire       pipe_stall = mem_res_wr_almost_full;
  integer    reads_issued = 0, stale_resp = 0, live_resp = 0;
  reg        cur_epoch = 0;                 // toggles on the flush's rising edge, as framestore_request does
  reg        flush_seen_q = 0;
  integer    q;
  initial for (q = 0; q < 256; q = q + 1) begin pipe_d[q] = 0; pipe_ep[q] = 0; pipe_t[q] = 0; end

  always @(posedge clk) begin
    cyc <= cyc + 1;
    flush_seen_q <= flush_lvl;
    if (flush_lvl && !flush_seen_q) cur_epoch <= ~cur_epoch;
    mem_req_rd_en <= rst && !pipe_stall;
    if (mem_req_rd_valid) begin
      if (mem_req_rd_cmd == CMD_WRITE) mem[mem_req_rd_addr] <= mem_req_rd_dta;
      if (mem_req_rd_cmd == CMD_READ) begin
        pipe_d [pipe_wp & 255] <= mem[mem_req_rd_addr];
        pipe_ep[pipe_wp & 255] <= cur_epoch;
        pipe_t [pipe_wp & 255] <= cyc;
        pipe_wp <= pipe_wp + 1;
        reads_issued <= reads_issued + 1;
      end
    end
    mem_res_wr_en <= 1'b0;
    if (!pipe_stall && (pipe_rp < pipe_wp) && ((cyc - pipe_t[pipe_rp & 255]) >= RD_LAT)) begin
      mem_res_wr_en  <= 1'b1;
      mem_res_wr_dta <= pipe_d[pipe_rp & 255];
      if (pipe_ep[pipe_rp & 255] == cur_epoch) live_resp <= live_resp + 1;
      else                                      stale_resp <= stale_resp + 1;
      pipe_rp <= pipe_rp + 1;
    end
  end

  integer delivered_words = 0;
  always @(posedge clk) if (rst && vbr_wr_en) delivered_words <= delivered_words + 1;

  always @(posedge clk) if (stream_valid) feed_ptr <= feed_ptr + 1;

  // ---------------------------------------------------------- getbits + vld
  wire  [4:0] advance;  wire align, wait_state;  wire [23:0] getbits;  wire signbit, vld_en;
  wire [31:0] bitpos;
  getbits_fifo getbits_fifo (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .vid_in(vbr_rd_dta), .vid_in_rd_en(vbr_rd_en), .vid_in_rd_valid(vbr_rd_valid),
    .advance(advance), .align(align), .wait_state(wait_state),
    .rld_wr_almost_full(1'b0), .mvec_wr_almost_full(1'b0), .motcomp_busy(1'b0),
    .getbits(getbits), .signbit(signbit), .getbits_valid(), .vld_en(vld_en),
    .pos_clr(~vbuf_rst), .bitpos(bitpos));

  wire pic_hdr_pulse, pic_hdr_upd, pic_hdr_second; wire [31:0] pic_hdr_bitpos;
  vld vld (
    .clk(clk), .clk_en(vld_en), .rst(rst),
    .getbits(getbits), .signbit(signbit), .advance(advance), .align(align), .wait_state(wait_state),
    .quant_wr_data(), .quant_wr_addr(), .quant_rst(), .wr_intra_quant(), .wr_non_intra_quant(),
    .wr_chroma_intra_quant(), .wr_chroma_non_intra_quant(),
    .rld_wr_en(), .rld_cmd(), .dct_coeff_run(), .dct_coeff_signed_level(), .dct_coeff_end(),
    .alternate_scan(), .q_scale_type(), .quantiser_scale_code(), .macroblock_intra(),
    .intra_dc_precision(), .matrix_coefficients(), .horizontal_size(), .vertical_size(),
    .display_horizontal_size(), .display_vertical_size(), .aspect_ratio_information(),
    .frame_rate_code(), .frame_rate_extension_n(), .frame_rate_extension_d(),
    .picture_coding_type(), .picture_structure(), .motion_type(), .dct_type(), .macroblock_address(),
    .macroblock_motion_forward(), .macroblock_motion_backward(), .mb_width(), .mb_height(),
    .motion_vert_field_select_0_0(), .motion_vert_field_select_0_1(),
    .motion_vert_field_select_1_0(), .motion_vert_field_select_1_1(),
    .second_field(), .update_picture_buffers(), .last_frame(), .chroma_format(), .motion_vector_valid(),
    .pmv_0_0_0(), .pmv_0_0_1(), .pmv_1_0_0(), .pmv_1_0_1(), .pmv_0_1_0(), .pmv_0_1_1(), .pmv_1_1_0(), .pmv_1_1_1(),
    .dmv_0_0(), .dmv_0_1(), .dmv_1_0(), .dmv_1_1(),
    .progressive_sequence(), .progressive_frame(), .top_field_first(), .repeat_first_field(),
    .vld_err(), .drop_pic_req(1'b0), .drop_pic_ack(), .drop_pic_rff(), .drop_pic_field(), .dbg_drop_probe(),
    .flags_commit(), .pic_informative(), .informative_commit(), .cc_pair_valid(), .cc_pair(), .cc_pair_field(),
    .mpeg1(), .vbuf_flush(flush_lvl),
    .bitpos(bitpos), .pic_hdr_pulse(pic_hdr_pulse), .pic_hdr_bitpos(pic_hdr_bitpos),
    .pic_hdr_upd(pic_hdr_upd), .pic_hdr_second(pic_hdr_second));

  // -------------------------------------------------- write-side stamp (DUT)
  wire [28:0] stream_pos;
  vbuf_pos vbuf_pos (.clk(clk), .vbuf_rst(vbuf_rst), .vbw_wr_en(vbw_wr_en), .vbuf_wr_pulse(vbuf_wr_pulse),
                     .vbuf_wr_cnt(vbuf_wr_cnt), .phase(vbw_phase), .stream_pos(stream_pos));

  // ------------------------------------------- association (dvd/pts_assoc.sv)
  // [D] the stamp taken at the marked byte, through the REAL association FIFO,
  // must tag exactly the pictures the golden says, with the golden's PTS.
  reg         st_valid = 0; reg [32:0] st_pts = 0; reg [23:0] st_pos = 0;
  reg  [23:0] hdr_pos_r = 0; reg hdr_pulse_r = 0, hdr_second_r = 0;
  wire [31:0] hdr_sc_bits = pic_hdr_bitpos - 32'd32;
  always @(posedge clk) begin
    st_valid <= stream_mark;
    if (stream_mark) begin st_pts <= marks[mark_ptr][32:0]; st_pos <= stream_pos[23:0]; end
    hdr_pulse_r  <= rst && pic_hdr_pulse;
    hdr_pos_r    <= hdr_sc_bits[26:3];
    hdr_second_r <= pic_hdr_second;
  end
  wire        tag_valid, tag_second, tag_commit; wire [32:0] tag_pts;
  pts_assoc #(.DEPTH(16), .PW(24), .MIN_GAP_W(17)) pts_assoc (
    .clk(clk), .rst_n(rst), .flush(flush_lvl),
    .stamp_valid(st_valid), .stamp_pts(st_pts), .stamp_pos(st_pos),
    .hdr_pulse(hdr_pulse_r), .hdr_pos(hdr_pos_r), .hdr_second(hdr_second_r),
    .tag_valid(tag_valid), .tag_pts(tag_pts), .tag_second(tag_second), .tag_commit(tag_commit),
    .dbg_ovf());
  integer n_tagpic = 0, tag_err = 0, tags_seen = 0;
  reg [71:0] g;
  always @(posedge clk) if (tag_commit) begin
    g = (n_tagpic < n_golden) ? gold[n_tagpic] : 72'd0;
    if ((tag_valid !== g[39]) || (tag_valid && (tag_pts !== g[32:0]))) begin
      tag_err = tag_err + 1;
      if (tag_err < 8) $display("FAIL [D] pic %0d (seg%0d): tag valid=%0d pts=%0d, golden valid=%0d pts=%0d",
                                n_tagpic, seg, tag_valid, tag_pts, g[39], g[32:0]);
    end
    if (tag_valid) tags_seen = tags_seen + 1;
    n_tagpic = n_tagpic + 1;
  end

  // ------------------------------------------------------------- checkers
  integer n_pic = 0, n_mark = 0;            // per-segment counters
  integer const_w = 0, const_r = 0;         // post-flush constants
  reg     const_w_set = 0, const_r_set = 0;
  integer got, want, d;
  integer pre_pics = 0, post_pics = 0, pre_marks = 0, post_marks = 0;

  // write side: sample the DUT's stamp on the cycle the marked byte is accepted
  integer mgot, mwant, md;
  always @(posedge clk) if (stream_mark) begin
    mgot  = stream_pos;
    mwant = marks[mark_ptr][71:40];
    md    = mgot - mwant;
    if (seg == 0) begin
      pre_marks = pre_marks + 1;
      if (md != 0) begin errors = errors + 1; $display("FAIL [C1] mark %0d: stamp %0d, golden %0d", mark_ptr, mgot, mwant); end
    end else begin
      post_marks = post_marks + 1;
      if (!const_w_set) begin const_w = md; const_w_set = 1; end
      else if (md != const_w) begin errors = errors + 1; $display("FAIL [C2] mark %0d: stamp-golden %0d, expected the segment constant %0d", mark_ptr, md, const_w); end
    end
    if (verbose) $display("  seg%0d mark %0d @%0d stamp %0d (d=%0d)", seg, mark_ptr, mwant, mgot, md);
    mark_ptr <= mark_ptr + 1;   // nonblocking: the tag block samples marks[mark_ptr] in this same cycle
  end

  // read side: the vld's start-code position vs the golden picture offset
  always @(posedge clk) if (rst && pic_hdr_pulse) begin
    got = ($signed(pic_hdr_bitpos) - 32) >>> 3;
    if (n_pic < n_golden) want = gold[n_pic][71:40]; else want = -1;
    d = got - want;
    if (seg == 0) begin
      pre_pics = pre_pics + 1;
      if (d != 0) begin errors = errors + 1; if (pre_pics < 10) $display("FAIL [C1] pic %0d: pos %0d, golden %0d", n_pic, got, want); end
    end else begin
      post_pics = post_pics + 1;
      if (!const_r_set) begin const_r = d; const_r_set = 1; end
      else if (d != const_r) begin errors = errors + 1; if (post_pics < 10) $display("FAIL [C2] pic %0d: pos-golden %0d, expected %0d", n_pic, d, const_r); end
    end
    if (verbose && (n_pic < 6)) $display("  seg%0d pic %0d pos %0d golden %0d (d=%0d)", seg, n_pic, got, want, d);
    n_pic = n_pic + 1;
  end

  // ----------------------------------------------------------------- run
  integer i, guard;
  reg [1023:0] stem, fname;
  initial begin
    if (!$value$plusargs("STEM=%s", stem)) stem = "bench/dvd/test_vobs/pts_apollo";
    if ($test$plusargs("VERBOSE")) verbose = 1;
    for (i = 0; i < MAXW; i = i + 1) es[i] = 64'hx;
    for (i = 0; i < MAXP; i = i + 1) begin gold[i] = 72'hx; marks[i] = 72'hx; end
    $sformat(fname, "%0s.hex", stem);        $readmemh(fname, es);
    $sformat(fname, "%0s.golden.hex", stem); $readmemh(fname, gold);
    $sformat(fname, "%0s.marks.hex", stem);  $readmemh(fname, marks);
    i = 0; while (i < MAXW && es[i]    !== 64'hx) i = i + 1; es_words = i;
    i = 0; while (i < MAXP && gold[i]  !== 72'hx) i = i + 1; n_golden = i;
    i = 0; while (i < MAXP && marks[i] !== 72'hx) i = i + 1; n_marks  = i;
    if (es_words == 0 || n_golden == 0) begin
      $display("SKIP: pts_chain_tb — fixture %0s missing; run bench/dvd/run_pts_assoc.sh", stem);
      $finish;
    end
    if (es_words >= MAXW) begin $display("FAIL: raise MAXW"); $fatal(1); end
    $display("pts_chain_tb: %0s — %0d ES words, %0d pictures, %0d marks, RD_LAT %0d, flush after %0d pictures",
             stem, es_words, n_golden, n_marks, RD_LAT, PRE_PICS);

    #100 rst = 1;
    // wait for the framestore to finish its start-up CLEAR (it writes the whole map)
    guard = 0;
    while (framestore.framestore_request.state != 11'b00000000100 && guard < 3000000) begin @(posedge clk); guard = guard + 1; end
    $display("  framestore idle after %0d cycles", guard);

    // ---- segment 0: feed the whole fixture, flush after PRE_PICS pictures ----
    feed_end = es_words * 8;
    feed_on  = 1;
    guard = 0;
    // The framestore tops the read fifo up in bursts (it issues reads while the
    // fifo is at or below its almost-empty threshold), so a flush at an arbitrary
    // instant usually finds NO read in flight and proves nothing. Wait for the
    // picture count AND for a burst to be in the memory pipe: that is the hazard.
    while (!((n_pic >= PRE_PICS) && ((pipe_wp - pipe_rp) >= 8)) && (guard < 6000000)) begin @(posedge clk); guard = guard + 1; end
    if (n_pic < PRE_PICS) begin $display("FAIL: pre-flush watchdog (%0d pictures)", n_pic); errors = errors + 1; end
    if ((pipe_wp - pipe_rp) < 8) begin $display("FAIL: could not catch a read burst in flight before the flush"); errors = errors + 1; end
    // the flush lands while the write side is still streaming and reads are in flight
    $display("  flush at pic %0d: reads issued %0d, in flight %0d, vbuf_wr_cnt %0d", n_pic, reads_issued, pipe_wp - pipe_rp, vbuf_wr_cnt);
    feed_on = 0;
    seg = 1; n_pic = 0; n_tagpic = 0;
    @(posedge clk); flush_lvl = 1;
    repeat (192) @(posedge clk);
    flush_lvl = 0;
    repeat (8) @(posedge clk);
    // ---- segment 1: the "seek" lands at the fixture's origin again ----
    feed_ptr = 0; mark_ptr = 0;
    repeat (RD_LAT + 64) @(posedge clk);   // let every stale response land first (the hazard)
    feed_on = 1;
    guard = 0;
    while ((n_pic < n_golden) && (guard < 12000000)) begin @(posedge clk); guard = guard + 1; end
    repeat (200) @(posedge clk);

    if (post_pics != n_golden) begin
      $display("FAIL: post-flush saw %0d picture headers, golden has %0d", post_pics, n_golden);
      errors = errors + 1;
    end
    if (!const_w_set || !const_r_set) begin
      $display("FAIL [C2]: post-flush constants not established (w=%0d r=%0d)", const_w_set, const_r_set);
      errors = errors + 1;
    end else if (const_w != const_r) begin
      $display("FAIL [C2]: write side and read side disagree on the new stream's origin: stamps +%0d B, vld +%0d B",
               const_w, const_r);
      errors = errors + 1;
    end else if (const_r < 0 || const_r > 16) begin
      $display("FAIL [C2]: post-flush origin offset %0d B is not a stale in-flight WRITE word (expected 0..16)", const_r);
      errors = errors + 1;
    end
    // The model classes a response at DELIVERY into the response fifo; the
    // framestore routes it 2-3 cycles later against the epoch of THAT moment, so
    // a response delivered in the last cycles before the flush is live to the
    // model and (correctly) stale to the RTL. Allow that boundary window only:
    // the RED arm delivers every stale response and overshoots by all of them.
    if ((delivered_words > live_resp) || (delivered_words < live_resp - 4)) begin
      $display("FAIL [C3]: read fifo received %0d words; %0d responses were live, %0d stale crossed the flush",
               delivered_words, live_resp, stale_resp);
      errors = errors + 1;
    end
    if (stale_resp == 0) begin
      $display("FAIL [C3]: no read response crossed the flush -- the hazard was not exercised (raise RD_LAT)");
      errors = errors + 1;
    end
    if (tag_err != 0) begin
      $display("FAIL [D]: %0d picture tags disagree with the golden", tag_err);
      errors = errors + 1;
    end
    if (tags_seen == 0) begin
      $display("FAIL [D]: no picture was ever tagged -- the association is inert");
      errors = errors + 1;
    end
    if (pre_marks == 0 || post_marks == 0) begin
      $display("FAIL: no marks in a segment (pre %0d post %0d) — the fixture cannot test the stamp", pre_marks, post_marks);
      errors = errors + 1;
    end

    if (errors == 0)
      $display("PASS: pts_chain_tb — pre-flush %0d pictures + %0d marks exact; post-flush %0d pictures + %0d marks agree (origin +%0d B); %0d stale responses crossed the flush, none delivered; %0d tags all golden",
               pre_pics, pre_marks, post_pics, post_marks, const_r, stale_resp, tags_seen);
    else begin
      $display("FAIL: pts_chain_tb — %0d error(s)", errors);
      $fatal(1);
    end
    $finish;
  end

endmodule
