`timescale 1ns/1ps
//
// pal_detect_tb.sv — the PAL/NTSC verdict must not follow a garbage sequence header
// (dvd/pal_detect.sv; issue #42 leg 2, docs/single_raster_analog.md §6).
//
// WHY THIS BENCH EXISTS. pal_eff kicks the runtime modeline walk, and unlike an il_eff
// change that walk carries NO pipeline flush — so one wrong verdict restarts the raster
// mid-drain, and through film_det (= pal_eff ? det_pal : det_ntsc) it can restart it
// again. The pre-fix rule flipped on a SINGLE non-zero header of any value.
//
// ⚠ THE TRAP THIS BENCH IS BUILT TO AVOID (CLAUDE.md: bench-that-cannot-fail).
// bench/dvd/field_parity_tb.sv could not see its defect because its pass condition was
// the same expression as the RTL's. So:
//   - every expectation here is a HAND-WRITTEN constant or a hand-written case table,
//     never a call to the DUT's vs_pal / pal_detect_raw expression;
//   - the stimulus models the REAL register semantics (vertical_size is a register that
//     holds between sequence headers and only changes when a header writes a different
//     value — NOT an event stream), because a rule that counts header events instead of
//     elapsed time passes a naive bench and freezes the verdict forever on real content;
//   - the pre-fix rule is instantiated verbatim alongside the DUT and selected by
//     +hyst=0, and it MUST FAIL scenarios [4] and [5b].
//
// Build/run: bench/dvd/run_mode_realign.sh   (or, standalone)
//   iverilog -g2012 -o bench/dvd/pal_detect_sim dvd/pal_detect.sv bench/dvd/pal_detect_tb.sv
//   vvp bench/dvd/pal_detect_sim            # GREEN (the fixed rule)
//   vvp bench/dvd/pal_detect_sim +hyst=0    # RED   (the pre-fix rule) — failures EXPECTED
//
module pal_detect_tb;

  localparam [26:0] HOLD = 27'd200;      // sim-scale confirmation window
  localparam integer GOP = 60;           // cycles a real header holds before the next one

  reg         clk = 0;
  reg         rst_n = 0;
  reg         mount_arm = 0;
  reg  [13:0] vsize = 14'd0;

  wire        dut_pal;
  integer     hyst = 1;                  // 1 = the fixed rule, 0 = the pre-fix rule

  pal_detect #(.HOLD_CYC(HOLD)) dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .mount_arm (mount_arm),
    .vsize     (vsize),
    .pal       (dut_pal)
  );

  // ---- the PRE-FIX rule, verbatim from dvd/emu.sv before this change ----------------
  reg legacy_pal;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)               legacy_pal <= 1'b0;
    else if (vsize != 14'd0)  legacy_pal <= (vsize > 14'd480) || (vsize == 14'd288);
  end

  wire verdict = hyst[0] ? dut_pal : legacy_pal;

  always #5 clk = ~clk;

  integer errors = 0;

  // ★ THE LOAD-BEARING MEASUREMENT: how many times the verdict CHANGED. A verdict that
  // flips and flips back looks correct at the end of the window and is exactly the
  // defect -- every change kicks the modeline walk, which restarts the raster with no
  // pipeline flush. Counting edges, not end states, is what makes this bench able to
  // fail; the first version of it checked end states and the pre-fix rule PASSED
  // scenarios [3] and [4] by self-healing on the next real header.
  reg     verdict_q;
  integer edges = 0;
  always @(posedge clk) begin
    if (verdict !== verdict_q) edges = edges + 1;
    verdict_q <= verdict;
  end

  task fail(input [8*72-1:0] msg);
    begin
      errors = errors + 1;
      $display("FAIL: %0s  (verdict=%0b, t=%0t)", msg, verdict, $time);
    end
  endtask

  task chk(input want, input [8*72-1:0] msg);
    begin if (verdict !== want) fail(msg); end
  endtask

  task edges_clr;   begin @(posedge clk); edges = 0; end   endtask

  task chk_edges(input integer want, input [8*72-1:0] msg);
    begin
      if (edges !== want) begin
        $display("  verdict changed %0d time(s), want %0d", edges, want);
        fail(msg);
      end
    end
  endtask

  // Drive one parsed height for `n` cycles. This is the real register behaviour: the
  // value simply STAYS until another header writes a different one.
  task hdr(input [13:0] v, input integer n);
    begin
      vsize = v;
      repeat (n) @(posedge clk);
    end
  endtask

  task cold_reset;
    begin
      rst_n = 0; mount_arm = 0; vsize = 14'd0;
      repeat (4) @(posedge clk);
      rst_n = 1;
      repeat (2) @(posedge clk);
    end
  endtask

  task mount;                            // a new file: re-arm the immediate latch
    begin
      vsize = 14'd0;                     // the mount soft reset zeroes vertical_size
      mount_arm = 1; repeat (8) @(posedge clk);
      mount_arm = 0; repeat (2) @(posedge clk);
    end
  endtask

  // Hand-written meaning table — NOT derived from the RTL.
  function want_pal(input [13:0] v);
    case (v)
      14'd240:  want_pal = 1'b0;         // VCD / MPEG-1 SIF NTSC
      14'd288:  want_pal = 1'b1;         // VCD / MPEG-1 SIF PAL
      14'd480:  want_pal = 1'b0;         // DVD / SVCD NTSC
      14'd576:  want_pal = 1'b1;         // DVD / SVCD PAL
      14'd720:  want_pal = 1'b1;         // flat-file 720p: pre-existing ">480" reading
      14'd1080: want_pal = 1'b1;         // flat-file 1080
      14'd1088: want_pal = 1'b1;
      default:  want_pal = 1'bx;
    endcase
  endfunction

  integer i;
  reg [13:0] tbl [0:6];

  initial begin
    if (!$value$plusargs("hyst=%d", hyst)) hyst = 1;
    $display("pal_detect_tb: %0s rule", hyst[0] ? "FIXED" : "PRE-FIX (+hyst=0)");

    tbl[0]=14'd240; tbl[1]=14'd288; tbl[2]=14'd480; tbl[3]=14'd576;
    tbl[4]=14'd720; tbl[5]=14'd1080; tbl[6]=14'd1088;

    // ================================================================= [1]
    // First plausible header after a cold reset latches IMMEDIATELY. A PAL disc must
    // not pay a detection delay at load (that would fire a spurious NTSC->PAL walk).
    cold_reset;
    hdr(14'd576, 3);
    chk(1'b1, "[1] first header 576 must latch PAL at once");

    // ================================================================= [2]
    // vsize == 0 (watchdog expiry / mount soft reset cleared the VLD register) must
    // HOLD the verdict. This locks the 2026-09-03 fix that this module subsumes.
    hdr(14'd0, 10000);
    chk(1'b1, "[2] vsize=0 must hold the established verdict");
    hdr(14'd576, GOP);
    chk(1'b1, "[2b] verdict must survive the gap");

    // ================================================================= [3]
    // ONE stray disagreeing header, overwritten by the next real one a GOP later.
    edges_clr;
    hdr(14'd480, 20);
    hdr(14'd576, GOP);
    chk(1'b1, "[3] a single stray 480 must not flip an established verdict");
    chk_edges(0, "[3] a single stray 480 must not even momentarily flip it");

    // ================================================================= [4]  ** RED **
    // The real garbage signature: a burst of DIFFERENT implausible-and-plausible
    // heights, each overwritten within a GOP. Nothing here is sustained, so nothing
    // here is a verdict. The pre-fix rule flips on the first 480 and never comes back.
    edges_clr;
    hdr(14'd480, 15); hdr(14'd576, 25);
    hdr(14'd240, 15); hdr(14'd576, 25);
    hdr(14'd480, 15); hdr(14'd576, 25);
    hdr(14'd208, 15); hdr(14'd576, 25);
    hdr(14'd480, 15); hdr(14'd576, 25);
    hdr(14'd186, 15); hdr(14'd576, GOP);
    chk(1'b1, "[4] churning garbage headers must never flip the verdict");
    chk_edges(0, "[4] churning garbage must not kick the modeline walk even once");

    // ================================================================= [5]
    // A SUSTAINED disagreement is a real standard change and must be followed --
    // but only after the confirmation window, not before.
    edges_clr;
    hdr(14'd480, HOLD/2);
    chk(1'b1, "[5a] must not flip before the confirmation window elapses");
    hdr(14'd480, HOLD + 40);
    chk(1'b0, "[5b] a sustained 480 must flip the verdict to NTSC");
    chk_edges(1, "[5c] a real standard change costs exactly ONE walk kick");

    // ================================================================= [6]
    // Implausible heights are parse errors, not verdicts -- even when sustained.
    edges_clr;
    hdr(14'd7, HOLD*3);
    chk(1'b0, "[6a] a sustained height of 7 must not arm a verdict");
    hdr(14'd3000, HOLD*3);
    chk(1'b0, "[6b] a sustained height of 3000 must not arm a verdict");
    hdr(14'd480, GOP);
    chk(1'b0, "[6c] verdict must be unchanged after implausible input");
    chk_edges(0, "[6d] implausible heights must not kick the walk");

    // ================================================================= [7]
    // A MOUNT is the one event that may legitimately change the standard, so the
    // first header of the new file latches at once -- no confirmation window.
    mount;
    hdr(14'd576, 3);
    chk(1'b1, "[7] first header after a mount must latch at once");

    // ================================================================= [8]
    // Meaning table, from the hand-written function above. Both rules must agree
    // here: leg 2 changes WHEN a verdict may take effect, never WHAT a height means.
    for (i = 0; i < 7; i = i + 1) begin
      mount;
      hdr(tbl[i], 3);
      if (verdict !== want_pal(tbl[i])) begin
        $display("  vsize=%0d -> %0b, want %0b", tbl[i], verdict, want_pal(tbl[i]));
        fail("[8] meaning table mismatch");
      end
    end

    if (errors == 0) $display("pal_detect_tb: ALL TESTS PASSED (8 scenarios)");
    else begin
      $display("pal_detect_tb: %0d FAILURE(S)", errors);
      $fatal(1, "pal_detect_tb FAILED");
    end
    $finish;
  end

endmodule
