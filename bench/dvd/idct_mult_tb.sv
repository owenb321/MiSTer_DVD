// bench/dvd/idct_mult_tb.sv -- logic reclaim F (docs/logic_reclaim.md §11): the fork's
// one-DSP mult22x16 is bit-identical to upstream's split multiplier, cycle for cycle.
//
// Arms (+arm=<name>), each scored with !== on every cycle:
//   data   mult22x16 vs bench/dvd/ref/mult22x16_ref.v on random full-range operands, with
//          the corner values mixed in and a random clk_en.
//   reset  the same, plus reset pulses of 1..5 cycles at random. A 1-cycle pulse with a
//          non-zero product in flight is the case the p_clr flag exists for; the arm
//          counts them and fails if too few happened.
//   idct   the whole idct (rtl/mpeg2/idct.v) vs idct_old: a copy of the same file that
//          bench/dvd/run_idct_mult.sh renames to *_old and wires to mult22x16_ref. Random
//          coefficient blocks (sparse, dense, full-range, saturating), random input gaps.
//          Counts output coefficients, non-zero, clipped and in-range ones, so the comparison
//          cannot pass on a pipeline that never produced anything.
// Exit: $fatal on any mismatch or vacuous run; prints "IDCT_MULT PASS <arm>" otherwise.

module idct_mult_tb;
  reg clk = 0;
  always #5 clk = ~clk;

  reg [8*8-1:0] arm;
  integer seed = 1;
  integer cycles = 0, errors = 0;

  // ---------------------------------------------------------------- unit arms
  reg               u_rst = 1'b0;       // active low
  reg               u_en  = 1'b1;
  reg signed [21:0] u_mr  = 0;
  reg signed [15:0] u_md  = 0;
  wire signed [37:0] u_new, u_ref;

  mult22x16     dut_u (clk, u_en, u_rst, u_new, u_md, u_mr);
  mult22x16_ref ref_u (clk, u_en, u_rst, u_ref, u_md, u_mr);

  function automatic [21:0] pick22(input integer r);
    case (r % 8)
      0: pick22 = 22'h200000;           // most negative
      1: pick22 = 22'h1FFFFF;           // most positive
      2: pick22 = 22'h3FFFFF;           // -1
      3: pick22 = 22'h00000F;           // lsb nibble only
      default: pick22 = $random(seed);
    endcase
  endfunction
  function automatic [15:0] pick16(input integer r);
    case (r % 8)
      0: pick16 = 16'h8000;
      1: pick16 = 16'h7FFF;
      2: pick16 = 16'hFFFF;
      default: pick16 = $random(seed);
    endcase
  endfunction

  // ---------------------------------------------------------------- idct arm
  reg               i_rst = 1'b0;
  reg signed [11:0] i_lvl = 0;
  reg               i_eob = 0, i_val = 0;
  wire signed [8:0] n_dta, o_dta;
  wire              n_val, n_eob, o_val, o_eob;

  idct     dut_i (.clk(clk), .clk_en(1'b1), .rst(i_rst),
                  .iquant_level(i_lvl), .iquant_eob(i_eob), .iquant_valid(i_val),
                  .idct_data(n_dta), .idct_valid(n_val), .idct_eob(n_eob));
  idct_old ref_i (.clk(clk), .clk_en(1'b1), .rst(i_rst),
                  .iquant_level(i_lvl), .iquant_eob(i_eob), .iquant_valid(i_val),
                  .idct_data(o_dta), .idct_valid(o_val), .idct_eob(o_eob));

  integer n_out = 0, n_nz = 0, n_clip = 0, n_mid = 0, n_short = 0;
  reg     cmp_u = 0, cmp_i = 0;

  always @(posedge clk) begin
    if (cmp_u && (u_new !== u_ref)) begin
      errors = errors + 1;
      if (errors < 8) $display("MISMATCH unit cyc %0d rst %b en %b: new %h ref %h", cycles, u_rst, u_en, u_new, u_ref);
    end
    if (cmp_i && ({n_val, n_eob, n_dta} !== {o_val, o_eob, o_dta})) begin
      errors = errors + 1;
      if (errors < 8) $display("MISMATCH idct cyc %0d: new %b%b %0d ref %b%b %0d", cycles, n_val, n_eob, n_dta, o_val, o_eob, o_dta);
    end
    if (cmp_i && o_val) begin
      n_out = n_out + 1;
      if (o_dta != 0) n_nz = n_nz + 1;
      if (o_dta == 9'sd255 || o_dta == -9'sd256) n_clip = n_clip + 1;
      else if (o_dta != 0) n_mid = n_mid + 1;
    end
    cycles = cycles + 1;
  end

  task automatic unit_run(input integer n, input integer with_reset);
    integer k, len, j;
    begin
      for (k = 0; k < n; k = k + 1) begin
        @(negedge clk);
        u_mr = pick22($random(seed) & 32'h7fffffff);
        u_md = pick16($random(seed) & 32'h7fffffff);
        u_en = (($random(seed) & 7) != 0);
        if (with_reset && (($random(seed) & 31) == 0)) begin
          len = (($random(seed) & 1) ? 1 : 1 + (($random(seed) & 32'h7fffffff) % 5));
          if (len == 1 && u_ref != 0) n_short = n_short + 1;
          u_rst = 1'b0;
          for (j = 0; j < len; j = j + 1) begin
            @(negedge clk);
            u_mr = $random(seed); u_md = $random(seed); u_en = (($random(seed) & 3) != 0);
          end
          u_rst = 1'b1;
        end
      end
    end
  endtask

  task automatic send_block(input integer kind);
    integer c, r;
    reg signed [11:0] v;
    begin
      for (c = 0; c < 64; c = c + 1) begin
        @(negedge clk);
        while (($random(seed) & 3) == 0) begin   // input gaps
          i_val = 0; i_eob = 0;
          @(negedge clk);
        end
        r = $random(seed) & 32'h7fffffff;
        case (kind)
          0: v = (r % 6 == 0) ? $random(seed) : 12'sd0;              // sparse
          1: v = $random(seed);                                        // dense full range
          2: v = (c == 0) ? ((r & 1) ? 12'sh7FF : 12'sh800) : 12'sd0;  // DC only, extreme
          3: v = (r & 1) ? 12'sh7FF : 12'sh800;                        // every one extreme
          default: v = ($random(seed) % 64);                            // small
        endcase
        i_lvl = v; i_val = 1; i_eob = (c == 63);
      end
      @(negedge clk); i_val = 0; i_eob = 0;
    end
  endtask

  integer b;
  initial begin
    if (!$value$plusargs("arm=%s", arm)) arm = "data";
    void'($value$plusargs("seed=%d", seed));
    // a long initial reset for every arm: both sides start defined
    u_rst = 0; i_rst = 0;
    repeat (8) @(negedge clk);
    u_rst = 1; i_rst = 1;
    if (arm == "data") begin
      cmp_u = 1;
      unit_run(400000, 0);
    end else if (arm == "reset") begin
      cmp_u = 1;
      unit_run(400000, 1);
      $display("reset arm: %0d one-cycle resets with a product in flight", n_short);
      if (n_short < 500) $fatal(1, "IDCT_MULT FAIL reset: too few one-cycle resets (%0d)", n_short);
    end else if (arm == "idct") begin
      cmp_i = 1;
      for (b = 0; b < 4000; b = b + 1) send_block(b % 5);
      repeat (400) @(negedge clk);
      $display("idct arm: %0d coefficients out, %0d non-zero, %0d clipped, %0d in range", n_out, n_nz, n_clip, n_mid);
      if (n_out != 4000 * 64) $fatal(1, "IDCT_MULT FAIL idct: %0d coefficients out, expected %0d", n_out, 4000 * 64);
      if (n_nz < n_out / 4 || n_clip < 1000 || n_mid < n_out / 10) $fatal(1, "IDCT_MULT FAIL idct: vacuous (nz %0d clip %0d in range %0d)", n_nz, n_clip, n_mid);
    end else
      $fatal(1, "unknown arm");
    if (errors != 0) $fatal(1, "IDCT_MULT FAIL %0s: %0d mismatches", arm, errors);
    $display("IDCT_MULT PASS %0s", arm);
    $finish;
  end
endmodule
