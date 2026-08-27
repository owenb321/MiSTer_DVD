/*
 * cc_extract_tb.sv — does the VLD's user_data snoop recover the disc's EIA-608
 * caption pairs, byte-for-byte and in order?
 *
 * This is the leg with a real assumption behind it. The snoop (rtl/mpeg2/vld.v,
 * "user_data byte snoop") adds no FSM state: it relies on STATE_NEXT_START_CODE
 * already walking user_data ONE BYTE AT A TIME (next_advance=0, align=1) so the
 * payload streams past in getbits[23:16]. That is a claim about the getbits
 * pipeline's timing, not about the format — so it is tested against the REAL
 * getbits_fifo + vld over REAL disc bytes rather than a hand-driven model.
 *
 * Fixture (tools/cc_scan.py --fixture, from MEN_IN_BLACK):
 *   cc_es.hex     — real GOP-header + user_data runs, 64-bit BE words
 *   cc_golden.hex — the pairs an independent Python parse found in those blocks
 * The golden side is the same code path that decodes readable English from the
 * disc (docs/closed_captions.md §3), so agreement here is agreement with the disc.
 *
 * Build:
 *   iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/cc_extract_sim \
 *       rtl/mpeg2/vld.v rtl/mpeg2/getbits.v bench/dvd/cc_extract_tb.sv
 *   vvp bench/dvd/cc_extract_sim
 */
`timescale 1ns/1ps

module cc_extract_tb;

  reg clk = 0; always #5 clk = ~clk;
  reg rst = 0;

  localparam MAXW = 4096;
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

  // ---- golden pairs ----
  localparam MAXP = 4096;
  reg [1:0]  g_fld [0:MAXP-1];        // stored 0/1 (readmemh-friendly widths)
  reg [7:0]  g_b1  [0:MAXP-1];
  reg [7:0]  g_b2  [0:MAXP-1];
  integer    n_golden = 0;
  integer    n_seen   = 0;
  integer    errors   = 0;

  // ---- DUT ----
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

  wire        cc_pair_valid, cc_pair_field;
  wire [15:0] cc_pair;

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
    .cc_pair_valid(cc_pair_valid), .cc_pair(cc_pair), .cc_pair_field(cc_pair_field),
    .mpeg1()
  );

  // ---- check every emitted pair against the golden stream, in order ----
  always @(posedge clk) if (rst && cc_pair_valid) begin
    if (n_seen >= n_golden) begin
      $display("FAIL: extra pair #%0d emitted (%0d expected): fld=%0d %02x %02x",
               n_seen, n_golden, cc_pair_field, cc_pair[15:8], cc_pair[7:0]);
      errors = errors + 1;
    end else begin
      if ((cc_pair_field !== g_fld[n_seen][0]) ||
          (cc_pair[15:8]  !== g_b1[n_seen])    ||
          (cc_pair[7:0]   !== g_b2[n_seen])) begin
        $display("FAIL: pair #%0d  got fld=%0d %02x %02x  want fld=%0d %02x %02x",
                 n_seen, cc_pair_field, cc_pair[15:8], cc_pair[7:0],
                 g_fld[n_seen][0], g_b1[n_seen], g_b2[n_seen]);
        errors = errors + 1;
      end
    end
    n_seen = n_seen + 1;
  end

  integer i, fh, code;
  reg [7:0] tb1, tb2;
  integer   tfld;

  initial begin
    for (i = 0; i < MAXW; i = i + 1) es[i] = 64'hx;
    $readmemh("bench/dvd/test_vobs/cc_es.hex", es);
    i = 0;
    while (i < MAXW && es[i] !== 64'hx) i = i + 1;
    es_words = i;

    // golden list is "<fld> <b1> <b2>" per line -- read it with $fscanf so the
    // three columns stay legible in the file rather than being packed for $readmemh
    fh = $fopen("bench/dvd/test_vobs/cc_golden.hex", "r");
    if (fh == 0) begin
      $display("FAIL: cannot open cc_golden.hex");
      $fatal(1);
    end
    n_golden = 0;
    code = $fscanf(fh, "%d %h %h\n", tfld, tb1, tb2);
    while (code == 3) begin
      g_fld[n_golden] = tfld[1:0];
      g_b1[n_golden]  = tb1;
      g_b2[n_golden]  = tb2;
      n_golden = n_golden + 1;
      code = $fscanf(fh, "%d %h %h\n", tfld, tb1, tb2);
    end
    $fclose(fh);
    $display("cc_extract_tb: %0d ES words, %0d golden pairs", es_words, n_golden);

    #100 rst = 1;
    #200000;

    if (n_seen != n_golden) begin
      $display("FAIL: extracted %0d pairs, expected %0d", n_seen, n_golden);
      errors = errors + 1;
    end
    if (errors == 0)
      $display("PASS: cc_extract_tb — %0d/%0d caption pairs recovered byte-exact",
               n_seen, n_golden);
    else begin
      $display("FAIL: cc_extract_tb — %0d error(s)", errors);
      $fatal(1);
    end
    $finish;
  end

endmodule
