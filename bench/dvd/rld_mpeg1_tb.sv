/*
 * rld_mpeg1_tb.sv — value-level gate for the MPEG-1 mismatch control in rld.v
 * (docs/mpeg1.md B.2 item 8) and for the mpeg1 flag riding the rld_fifo.
 *
 * Drives the REAL rld_fifo + rld with hand-computed coefficient blocks and
 * checks the inverse-quantised outputs against hand-computed golden values in
 * BOTH modes over the same input:
 *
 *   Quant matrix tied flat W=16 (both intra/non-intra reads), q_scale_type=0,
 *   quantiser_scale_code=2 -> quantiser_scale=4 -> factor = 64.
 *
 *   Block A (non-intra): run0/level2, run0/level3, EOB
 *     dequant: (2L+sign)*64 >> 5 = {10, 14}
 *     MPEG-2: oddness sum (10+14) even -> toggle LSB of coeff 63 (0->1) -> {10, 14, 1}
 *     MPEG-1: oddify every even nonzero coeff (none is intra DC)  -> { 9, 13}
 *
 *   Block B (intra, intra_dc_precision=0): DC level16, run0/level5, EOB
 *     dequant: DC = 16<<3 = 128 ; AC = (2*5)*64 >> 5 = 20
 *     MPEG-2: sum (128+20) even -> toggle coeff 63 (0->1) -> {128, 20, 1}
 *     MPEG-1: DC EXEMPT (11172-2 2.4.4.1), AC 20 -> 19 -> {128, 19}
 *
 * The same two blocks are pushed with mpeg1_wr=0 then mpeg1_wr=1; outputs are
 * collected per block (64 values each) and the nonzero multiset is compared.
 * $fatal on any mismatch.
 *
 * Build:
 *   iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/rld_mpeg1_sim \
 *       rtl/mpeg2/rld.v rtl/mpeg2/wrappers.v bench/dvd/rld_mpeg1_tb.sv
 *   vvp bench/dvd/rld_mpeg1_sim
 */
`timescale 1ns/1ps

module rld_mpeg1_tb;

  reg clk = 0; always #5 clk = ~clk;
  reg rst = 0;

  // ---- write side ----
  reg  [5:0]        wr_run = 0;
  reg signed [11:0] wr_lvl = 0;
  reg               wr_end = 0;
  reg               wr_intra = 0;
  reg               wr_mpeg1 = 0;
  reg               wr_en = 0;

  wire [5:0]        rd_run;
  wire signed [11:0]rd_lvl;
  wire              rd_end;
  wire              alt_rd, qst_rd, intra_rd, mpeg1_rd;
  wire [1:0]        idc_rd, cmd_rd;
  wire [4:0]        qsc_rd;
  wire [7:0]        qwd_rd; wire [5:0] qwa_rd;
  wire qrst_rd, qwi_rd, qwn_rd, qwci_rd, qwcn_rd;
  wire rld_rd_en, rld_rd_valid;

  rld_fifo fifo (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .dct_coeff_wr_run(wr_run), .dct_coeff_wr_signed_level(wr_lvl), .dct_coeff_wr_end(wr_end),
    .alternate_scan_wr(1'b0), .macroblock_intra_wr(wr_intra), .intra_dc_precision_wr(2'd0),
    .q_scale_type_wr(1'b0), .quantiser_scale_code_wr(5'd2),
    .mpeg1_wr(wr_mpeg1),
    .quant_wr_data_wr(8'd0), .quant_wr_addr_wr(6'd0),
    .quant_rst_wr(1'b0), .quant_wr_intra_wr(1'b0), .quant_wr_non_intra_wr(1'b0),
    .quant_wr_chroma_intra_wr(1'b0), .quant_wr_chroma_non_intra_wr(1'b0),
    .rld_cmd_wr(2'd0 /* RLD_DCT */), .rld_wr_en(wr_en),
    .rld_wr_almost_full(), .rld_wr_overflow(),
    .dct_coeff_rd_run(rd_run), .dct_coeff_rd_signed_level(rd_lvl), .dct_coeff_rd_end(rd_end),
    .alternate_scan_rd(alt_rd), .macroblock_intra_rd(intra_rd), .intra_dc_precision_rd(idc_rd),
    .q_scale_type_rd(qst_rd), .quantiser_scale_code_rd(qsc_rd),
    .mpeg1_rd(mpeg1_rd),
    .quant_wr_data_rd(qwd_rd), .quant_wr_addr_rd(qwa_rd),
    .quant_rst_rd(qrst_rd), .quant_wr_intra_rd(qwi_rd), .quant_wr_non_intra_rd(qwn_rd),
    .quant_wr_chroma_intra_rd(qwci_rd), .quant_wr_chroma_non_intra_rd(qwcn_rd),
    .rld_cmd_rd(cmd_rd), .rld_rd_en(rld_rd_en), .rld_rd_valid(rld_rd_valid)
  );

  wire signed [11:0] iquant_level;
  wire iquant_eob, iquant_valid;

  rld rld (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .idct_fifo_almost_full(1'b0),
    .dct_coeff_rd_run(rd_run), .dct_coeff_rd_signed_level(rd_lvl), .dct_coeff_rd_end(rd_end),
    .alternate_scan_rd(alt_rd), .q_scale_type_rd(qst_rd), .macroblock_intra_rd(intra_rd),
    .intra_dc_precision_rd(idc_rd), .quantiser_scale_code_rd(qsc_rd),
    .mpeg1_rd(mpeg1_rd),
    .quant_wr_data_rd(qwd_rd), .quant_wr_addr_rd(qwa_rd), .quant_rst_rd(qrst_rd),
    .quant_wr_intra_rd(qwi_rd), .quant_wr_non_intra_rd(qwn_rd),
    .quant_wr_chroma_intra_rd(qwci_rd), .quant_wr_chroma_non_intra_rd(qwcn_rd),
    .rld_cmd_rd(cmd_rd),
    .rld_rd_valid(rld_rd_valid), .rld_rd_en(rld_rd_en),
    .quant_rst(), .quant_rd_addr(),
    .quant_rd_intra_data(8'd16), .quant_rd_non_intra_data(8'd16),  // flat matrix W=16
    .quant_wr_data(), .quant_wr_addr(), .quant_wr_en_intra(), .quant_wr_en_non_intra(),
    .quant_wr_en_chroma_intra(), .quant_wr_en_chroma_non_intra(), .quant_alternate_scan(),
    .iquant_level(iquant_level), .iquant_eob(iquant_eob), .iquant_valid(iquant_valid)
  );

  // ---- output collection: per emitted block, the sorted nonzero values ----
  integer nz [0:15];
  integer nz_cnt = 0;
  integer blocks_done = 0;

  task clear_nz; integer i; begin nz_cnt = 0; for (i=0;i<16;i=i+1) nz[i] = 0; end endtask

  always @(posedge clk) if (rst) begin
    if (iquant_valid) begin
      if (iquant_level != 0) begin nz[nz_cnt] = iquant_level; nz_cnt = nz_cnt + 1; end
      if (iquant_eob) blocks_done = blocks_done + 1;
    end
  end

  task push(input [5:0] r, input signed [11:0] l, input e, input intra, input m1);
    begin
      @(negedge clk);
      wr_run = r; wr_lvl = l; wr_end = e; wr_intra = intra; wr_mpeg1 = m1; wr_en = 1;
      @(negedge clk);
      wr_en = 0;
    end
  endtask

  integer wait_done;
  // expected nonzero multiset (nexp entries; exp2 ignored when nexp==2).
  // NB: the MPEG-2 mismatch toggle hits coefficient 63 (the LAST of the block,
  // par. 7.4.4 note 1) — with all-zero tail that materialises an extra "1".
  task check_block(input integer nexp, input integer exp0, input integer exp1, input integer exp2, input [255:0] name);
    integer i, j, found;
    integer exp [0:2];
    reg     used [0:15];
    begin
      wait_done = blocks_done;
      while (blocks_done == wait_done) @(posedge clk);
      repeat (4) @(posedge clk);
      exp[0] = exp0; exp[1] = exp1; exp[2] = exp2;
      if (nz_cnt != nexp)
        $fatal(1, "FAIL %0s: %0d nonzero coeffs (want %0d): %0d %0d %0d %0d", name, nz_cnt, nexp, nz[0], nz[1], nz[2], nz[3]);
      for (i=0;i<16;i=i+1) used[i] = 0;
      for (i=0;i<nexp;i=i+1) begin
        found = 0;
        for (j=0;j<nz_cnt;j=j+1)
          if (!found && !used[j] && (nz[j] == exp[i])) begin used[j] = 1; found = 1; end
        if (!found)
          $fatal(1, "FAIL %0s: expected value %0d not found (got %0d %0d %0d)", name, exp[i], nz[0], nz[1], nz[2]);
      end
      $display("PASS %0s: {%0d %0d %0d}[%0d]", name, nz[0], nz[1], nz[2], nz_cnt);
      clear_nz;
    end
  endtask

  initial begin
    clear_nz;
    rst = 0; repeat (8) @(posedge clk); rst = 1; repeat (8) @(posedge clk);

    // MPEG-2 mode
    push(6'd0, 12'sd2, 1'b0, 1'b0, 1'b0);
    push(6'd0, 12'sd3, 1'b0, 1'b0, 1'b0);
    push(6'd0, 12'sd0, 1'b1, 1'b0, 1'b0);
    check_block(3, 10, 14, 1, "MPEG-2 non-intra (coeff-63 toggle)");

    push(6'd0, 12'sd16, 1'b0, 1'b1, 1'b0);   // intra DC (cnt==0 && intra)
    push(6'd0, 12'sd5,  1'b0, 1'b1, 1'b0);
    push(6'd0, 12'sd0,  1'b1, 1'b1, 1'b0);
    check_block(3, 128, 20, 1, "MPEG-2 intra+DC (coeff-63 toggle)");

    // MPEG-1 mode — same input coefficients
    push(6'd0, 12'sd2, 1'b0, 1'b0, 1'b1);
    push(6'd0, 12'sd3, 1'b0, 1'b0, 1'b1);
    push(6'd0, 12'sd0, 1'b1, 1'b0, 1'b1);
    check_block(2, 9, 13, 0, "MPEG-1 non-intra (per-coeff oddify, no coeff-63 toggle)");

    push(6'd0, 12'sd16, 1'b0, 1'b1, 1'b1);
    push(6'd0, 12'sd5,  1'b0, 1'b1, 1'b1);
    push(6'd0, 12'sd0,  1'b1, 1'b1, 1'b1);
    check_block(2, 128, 19, 0, "MPEG-1 intra (DC exempt, AC oddified)");

    $display("PASS");
    $finish;
  end

  initial begin
    #10_000_000;
    $fatal(1, "TIMEOUT: blocks_done=%0d nz_cnt=%0d", blocks_done, nz_cnt);
  end
endmodule
