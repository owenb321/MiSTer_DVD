// field_blend_tb.sv -- golden-model cosim of dvd/field_blend.sv over a fixture
// written by tools/field_blend_model.py (the RTL must be BIT-EXACT against a model
// written from the spec, never against itself). Adapted from Stage A's
// deint_comb_tb (feature/deinterlace@a017ec4).
//
//   +in=<stem>.in.hex +exp=<stem>.exp.hex +meta=<stem>.meta.hex
//       in:   H+1 input lines x W words {y,u,v,osd} (the last one = line H-2, the
//             bottom edge's mirrored d, which the addrgen emits on a blend scan);
//       exp:  the H output lines the model says the RTL must produce;
//       meta: W, H, ft_code.
//   +plain=1  the scan is NOT marked: H lines in, output must equal the input byte
//             for byte with its position codes untouched (the bypass).
//   +stall=N  1-in-N chance per cycle of out_almost_full and of a producer gap.
//   +bob=1|2  the scan is marked BOB keeping the TOP (1) / BOTTOM (2) field; pass the
//             model's <stem>.bobt.exp.hex / .bobb.exp.hex as +exp (docs/field_blend.md
//             "Bob"). [K4] then wants blend_act LOW, [K5] wants bob_act HIGH.
//   -Pfield_blend_tb.BLEND=0  RED: the scan is marked but not blended (the weave).
//             The comparison against the model must then FAIL -- reported with the
//             count, so a fixture the kernel does not change is visible as vacuous.
//
// Arms print FAIL: [Kn] so the runner can match a mutation to its arm:
//   [K1] pixel values (y,u,v AND osd)  [K2] line/pixel counts
//   [K3] position codes                [K4] blend_act instrument
//   [K5] bob_act instrument
// Scoring uses !== throughout (docs/hw_budget_and_lessons.md §4.2).
`timescale 1ns/1ps
module field_blend_tb;
  parameter BLEND = 1;
  localparam [2:0] ROW_0_COL_0 = 3'b000, ROW_1_COL_0 = 3'b001, ROW_X_COL_0 = 3'b010,
                   ROW_X_COL_X = 3'b011, ROW_X_COL_LAST = 3'b100;

  reg clk = 0; always #5 clk = ~clk;
  reg rst = 0;

  reg        scan_start = 0, scan_blend = 0, scan_bob = 0, scan_bob_bot = 0;
  reg  [7:0] in_y = 0, in_u = 0, in_v = 0, in_osd = 0;
  reg  [2:0] in_pos = ROW_X_COL_X;
  reg        in_wr = 0;
  wire       in_almost_full;
  wire [7:0] out_y, out_u, out_v, out_osd;
  wire [2:0] out_pos;
  wire       out_wr;
  reg        out_almost_full = 0;
  wire       blend_act, bob_act;

  reg [31:0] meta [0:7];
  integer W, H, ft_code;

  field_blend dut (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .scan_start(scan_start), .scan_blend(scan_blend),
    .scan_bob(scan_bob), .scan_bob_bot(scan_bob_bot),
    .in_y(in_y), .in_u(in_u), .in_v(in_v), .in_osd(in_osd), .in_pos(in_pos), .in_wr(in_wr),
    .in_almost_full(in_almost_full),
    .out_y(out_y), .out_u(out_u), .out_v(out_v), .out_osd(out_osd), .out_pos(out_pos),
    .out_wr(out_wr), .out_almost_full(out_almost_full),
    .blend_act(blend_act), .bob_act(bob_act));

  localparam MAXPX = 720 * 128;   // up to 127 lines (Icarus: size arrays to the data)
  reg [31:0] src [0:MAXPX-1];
  reg [31:0] exp [0:MAXPX-1];
  reg [31:0] got [0:MAXPX-1];
  reg  [2:0] got_pos [0:MAXPX-1];
  integer n_got = 0;
  always @(posedge clk) if (rst && out_wr) begin
    if (n_got < MAXPX) begin
      got[n_got] = {out_y, out_u, out_v, out_osd};
      got_pos[n_got] = out_pos;
    end
    n_got = n_got + 1;
  end

  integer stall = 0, plain = 0, bobm = 0;
  integer errors = 0;
  integer nlines_in, i, y, c, want_n, bad_px, bad_pos, first_bad, tmp;
  reg     act_seen = 0, bact_seen = 0;
  string in_f, exp_f, meta_f;

  always @(posedge clk) if (blend_act === 1'b1) act_seen <= 1'b1;
  always @(posedge clk) if (bob_act === 1'b1) bact_seen <= 1'b1;

  task push(input integer idx, input [2:0] pos);
    begin
      @(negedge clk);
      in_y = src[idx][31:24]; in_u = src[idx][23:16]; in_v = src[idx][15:8]; in_osd = src[idx][7:0];
      in_pos = pos; in_wr = 1;
      @(negedge clk); in_wr = 0;
    end
  endtask

  always @(negedge clk) if (stall != 0) out_almost_full = (($urandom % stall) == 0);

  function [2:0] pos_of(input integer yy, input integer cc);
    pos_of = (cc == 0) ? ((yy == 0) ? ft_code[2:0] : (yy == 1 && ft_code == 0) ? ROW_1_COL_0 : ROW_X_COL_0)
           : (cc == W - 1) ? ROW_X_COL_LAST : ROW_X_COL_X;
  endfunction

  initial begin
    void'($value$plusargs("in=%s", in_f));
    void'($value$plusargs("exp=%s", exp_f));
    void'($value$plusargs("meta=%s", meta_f));
    void'($value$plusargs("stall=%d", stall));
    void'($value$plusargs("plain=%d", plain));
    void'($value$plusargs("bob=%d", bobm));
    $readmemh(meta_f, meta);
    W = meta[0]; H = meta[1]; ft_code = meta[2];
    $readmemh(in_f, src);
    if (!plain) $readmemh(exp_f, exp);
    nlines_in = plain ? H : H + 1;
    $display("==== field_blend_tb BLEND=%0d plain=%0d bob=%0d stall=%0d  %0dx%0d ft=%0d ====",
             BLEND, plain, bobm, stall, W, H, ft_code);

    repeat (4) @(posedge clk); rst = 1; repeat (4) @(posedge clk);

    @(negedge clk); scan_start = 1; scan_blend = (plain == 0) ? BLEND[0] : 1'b0;
    scan_bob = (plain == 0) && (bobm != 0); scan_bob_bot = (bobm == 2);
    @(negedge clk); scan_start = 0;
    for (y = 0; y < nlines_in; y = y + 1) begin
      for (c = 0; c < W; c = c + 1) begin
        if ((c % 16) == 0) begin
          while (in_almost_full) @(negedge clk);
          if (stall != 0 && (($urandom % stall) == 0)) repeat (20) @(negedge clk);
        end
        push(y * W + c, pos_of(y, c));
      end
    end
    out_almost_full = 0; stall = 0;
    repeat (400) @(posedge clk);

    // ---- score ----
    want_n = (plain || BLEND) ? H * W : (H + 1) * W;
    if (n_got != want_n) begin
      $display("FAIL: [K2] %0d output pixels, want %0d (%0d lines x %0d)", n_got, want_n, want_n / W, W);
      errors = errors + 1;
    end
    bad_px = 0; bad_pos = 0; first_bad = -1;
    for (i = 0; i < want_n && i < n_got; i = i + 1) begin
      y = i / W; c = i % W;
      if (y >= H) begin                     // RED only: the extra line, not in the model
        tmp = (c == 0) ? ROW_X_COL_0 : (c == W - 1) ? ROW_X_COL_LAST : ROW_X_COL_X;
        if (got_pos[i] !== tmp[2:0]) bad_pos = bad_pos + 1;
        continue;
      end
      if (got[i] !== (plain ? src[i] : exp[i])) begin bad_px = bad_px + 1; if (first_bad < 0) first_bad = i; end
      if (got_pos[i] !== pos_of(y, c)) bad_pos = bad_pos + 1;
    end
    if (bad_pos != 0) begin
      $display("FAIL: [K3] %0d pixels with a wrong position code", bad_pos); errors = errors + 1;
    end
    if (BLEND || plain) begin
      if (bad_px != 0) begin
        $display("FAIL: [K1] %0d pixels differ from the model; first at line %0d col %0d: got %08x want %08x",
                 bad_px, first_bad / W, first_bad % W, got[first_bad], plain ? src[first_bad] : exp[first_bad]);
        errors = errors + 1;
      end
      if (act_seen !== ((plain || bobm) ? 1'b0 : 1'b1)) begin
        $display("FAIL: [K4] blend_act seen=%0d, want %0d", act_seen, (plain || bobm) ? 0 : 1); errors = errors + 1;
      end
      if (bact_seen !== ((!plain && bobm) ? 1'b1 : 1'b0)) begin
        $display("FAIL: [K5] bob_act seen=%0d, want %0d", bact_seen, (!plain && bobm) ? 1 : 0); errors = errors + 1;
      end
    end else begin
      if (bad_px != 0)
        $display("FAIL: [K1] the weave differs from the model on %0d pixels (%0.2f %%) -- what the blend changes",
                 bad_px, 100.0 * bad_px / (H * W));
      else
        $display("FAIL: [K1] the weave equals the model -- the fixture is vacuous");
      errors = errors + 1;
    end
    if (errors == 0) $display("RESULT: PASS");
    else begin $display("RESULT: FAIL (%0d)", errors); $fatal(1, "field_blend_tb failed"); end
    $finish;
  end

  initial begin
    #200_000_000;
    $display("RESULT: FAIL (timeout, n_got=%0d)", n_got); $fatal(1, "timeout");
  end
endmodule
