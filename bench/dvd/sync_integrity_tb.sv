`timescale 1ns/1ps
//
// sync_integrity_tb.sv -- a decoder SOFT RESET must not disturb the video sync at the pins.
//
// WHY THIS EXISTS.  reset.v folds the external soft-reset request (and a watchdog
// expiry) into comm_rst, which drives clk_rst, mem_rst AND dot_rst.  The 2026-09-03
// single-raster fix moved syncgen_intf onto dot_hard_rst so the RASTER GENERATOR
// survives those events -- but the pipeline that carries its sync to the pins
// (mixer -> mpeg2_osd -> yuv2rgb) stayed on dot_rst, and every stage of it zeroes its
// h_sync/v_sync/pixel_en registers on reset.  Those three outputs are the core's
// VGA_HS / VGA_VS / VGA_DE (dvd/emu.sv), so a soft reset DROPPED SYNC AT THE PINS for
// the duration of the flush level (~64 clk_sys, ~2.4 us).
//
// hps_io's video_calc counts active pixels and lines off DE (gated by CE_PIXEL) and
// re-arms its "new resolution" report on ANY change, reporting 15 frames later
// whether or not the value came back -- so each disturbance made Main run
// video_mode_adjust() and pop its resolution notice, naming the resolution that was
// already on screen.  MEASURED on hardware (Scooby-Doo 2, 2026-09-15): one spurious
// report per menu entry/exit and per title-domain jump on a core with the jump soft
// reset, zero on one without it, same disc and same landing PGCN.
//
// WHAT THIS MEASURES.  Not a signal the fix names -- the PINS.  Two identical display
// chains are driven from ONE syncgen, so they see the same raster cycle for cycle:
//
//   chain A (reference): never reset after bring-up
//   chain B (DUT):       takes a dot_rst pulse mid-frame, exactly as a soft reset gives it
//
// and every cycle B's {pixel_en, h_sync, v_sync} must equal A's.  A bench that instead
// asserted "hard_rst is connected" would agree with the RTL by construction; this one
// would still fail if the sync were disturbed by some other route.
//
// ⚠ The DATA path is deliberately NOT part of the contract.  The fix keeps mixer's
// pixel_rd_en handshake and the colour registers on dot_rst (pixel_queue is reset with
// them), so B's PIXELS legitimately go black across the pulse.  Sync is the invariant.
//
// RED arm: +tie_hard=1 drives chain B's hard_rst from the same net as its rst, which is
// what the pre-2026-09-15 RTL did.  It must FAIL.
//
// Build:
//   iverilog -g2012 -o bench/dvd/sync_integrity_sim \
//       rtl/mpeg2/syncgen.v rtl/mpeg2/syncgen_intf.v rtl/mpeg2/mixer.v \
//       rtl/mpeg2/osd.v rtl/mpeg2/yuv2rgb.v rtl/mpeg2/synchronizer.v \
//       bench/dvd/sync_integrity_tb.sv
//   vvp bench/dvd/sync_integrity_sim
//
module sync_integrity_tb;

  reg clk = 0;
  always #5 clk = ~clk;                       // 100 MHz-ish; only ratios matter

  reg  hard_rst = 0;                          // the reset that must survive nothing
  reg  soft_pulse = 0;                        // 1 = a decoder soft reset is in flight
  // ⚠ syncgen's counters are reset ONLY by syncgen_rst, which in the core is pulsed low
  // by the modeline walk's register writes (regfile.v:499). Leave it high and the
  // counters never leave X and every measurement reads 0 -- a bench that cannot fail.
  reg  syncgen_rst = 0;
  integer tie_hard = 0;                       // RED arm

  // chain A never sees the soft reset; chain B does, on its `rst` only.
  wire rst_a = hard_rst;
  wire rst_b = hard_rst & ~soft_pulse;
  // With the fix, B's sync line is on hard_rst. The RED arm ties it to rst_b instead.
  wire hard_b = tie_hard ? rst_b : hard_rst;

  // ---------------- one raster, shared by both chains ----------------
  // NTSC 480i as the rig runs it: 858 dots pixel-repeated to 1716, 525 lines.
  wire [11:0] h_pos, v_pos;
  wire        sg_pixel_en, sg_h_sync, sg_v_sync;

  syncgen_intf sg (
    .clk(clk), .clk_en(1'b1), .rst(hard_rst),
    .horizontal_size(14'd720), .vertical_size(14'd480),
    .display_horizontal_size(14'd720), .display_vertical_size(14'd480),
    .syncgen_rst(syncgen_rst),
    .horizontal_resolution(12'd720), .horizontal_sync_start(12'd736),
    .horizontal_sync_end(12'd798),   .horizontal_length(12'd857),
    .vertical_resolution(12'd480),   .vertical_sync_start(12'd244),
    .vertical_sync_end(12'd247),     .horizontal_halfline(12'd429),
    .vertical_length(12'd261),
    .interlaced(1'b1), .clip_display_size(1'b0), .pixel_repetition(1'b1),
    .h_pos(h_pos), .v_pos(v_pos), .pixel_en(sg_pixel_en),
    .h_sync(sg_h_sync), .v_sync(sg_v_sync), .c_sync(), .h_blank(), .v_blank()
  );

  // ---------------- two display chains ----------------
  // A synthetic pixel source: the queue always has a pixel, so both chains are fed
  // identically and any difference in their SYNC is the reset, not the data.
  wire [7:0] ya, ua, va, yb, ub, vb;
  wire pea, hsa, vsa, peb, hsb, vsb;

  `define CHAIN(SUF, RST, HRST)                                                   \
    wire [7:0] mx_y``SUF, mx_u``SUF, mx_v``SUF, mx_osd``SUF;                       \
    wire mx_pe``SUF, mx_hs``SUF, mx_vs``SUF;                                       \
    mixer mixer``SUF (                                                             \
      .clk(clk), .clk_en(1'b1), .rst(RST), .hard_rst(HRST),                        \
      .pixel_repetition(1'b1),                                                     \
      .y_in(8'd120), .u_in(8'd128), .v_in(8'd128), .osd_in(8'd0),                  \
      .position_in(3'd0),                                                          \
      .pixel_rd_en(), .pixel_rd_valid(1'b1), .pixel_rd_underflow(1'b0),            \
      .h_pos(h_pos), .v_pos(v_pos),                                                \
      .h_sync_in(sg_h_sync), .v_sync_in(sg_v_sync), .pixel_en_in(sg_pixel_en),     \
      .y_out(mx_y``SUF), .u_out(mx_u``SUF), .v_out(mx_v``SUF), .osd_out(mx_osd``SUF), \
      .h_sync_out(mx_hs``SUF), .v_sync_out(mx_vs``SUF), .pixel_en_out(mx_pe``SUF), \
      .dbg_lines_displayed(), .dbg_first_vpos(), .dbg_last_vpos(),                 \
      .disp_v_offset(12'd0), .frame_top_par_err()                                  \
    );                                                                             \
    wire [7:0] od_y``SUF, od_u``SUF, od_v``SUF;                                    \
    wire od_pe``SUF, od_hs``SUF, od_vs``SUF;                                       \
    mpeg2_osd osd``SUF (                                                           \
      .clk(clk), .clk_en(1'b1), .rst(RST), .hard_rst(HRST),                        \
      .y_in(mx_y``SUF), .u_in(mx_u``SUF), .v_in(mx_v``SUF),                        \
      .h_sync_in(mx_hs``SUF), .v_sync_in(mx_vs``SUF), .pixel_en_in(mx_pe``SUF),    \
      .osd_in(mx_osd``SUF),                                                        \
      .y_out(od_y``SUF), .u_out(od_u``SUF), .v_out(od_v``SUF),                     \
      .h_sync_out(od_hs``SUF), .v_sync_out(od_vs``SUF), .pixel_en_out(od_pe``SUF), \
      .osd_clt_rd_addr(), .osd_clt_rd_en(), .osd_clt_rd_dta(32'd0),                \
      .osd_enable(1'b0), .interlaced(1'b1)                                         \
    );

  `CHAIN(_a, rst_a, hard_rst)
  `CHAIN(_b, rst_b, hard_b)

  yuv2rgb yuv_a (
    .clk(clk), .clk_en(1'b1), .rst(rst_a), .hard_rst(hard_rst),
    .matrix_coefficients(8'd1),
    .y(od_y_a), .u(od_u_a), .v(od_v_a),
    .h_sync_in(od_hs_a), .v_sync_in(od_vs_a), .pixel_en_in(od_pe_a),
    .r(), .g(), .b(),
    .h_sync_out(hsa), .v_sync_out(vsa), .c_sync_out(), .pixel_en_out(pea)
  );
  yuv2rgb yuv_b (
    .clk(clk), .clk_en(1'b1), .rst(rst_b), .hard_rst(hard_b),
    .matrix_coefficients(8'd1),
    .y(od_y_b), .u(od_u_b), .v(od_v_b),
    .h_sync_in(od_hs_b), .v_sync_in(od_vs_b), .pixel_en_in(od_pe_b),
    .r(), .g(), .b(),
    .h_sync_out(hsb), .v_sync_out(vsb), .c_sync_out(), .pixel_en_out(peb)
  );

  // ---------------- the measurement ----------------
  integer errors = 0;
  integer cmp_en = 0;
  integer n_de_a = 0, n_de_b = 0;      // active dots seen on each chain
  integer n_hs_a = 0, n_hs_b = 0;      // hsync rising edges
  integer n_vs_a = 0, n_vs_b = 0;      // vsync rising edges
  integer n_diff = 0;                  // cycles where the two chains' sync disagrees
  reg hsa_q = 0, hsb_q = 0, vsa_q = 0, vsb_q = 0;

  always @(posedge clk) if (cmp_en) begin
    if (pea) n_de_a = n_de_a + 1;
    if (peb) n_de_b = n_de_b + 1;
    if (hsa & ~hsa_q) n_hs_a = n_hs_a + 1;
    if (hsb & ~hsb_q) n_hs_b = n_hs_b + 1;
    if (vsa & ~vsa_q) n_vs_a = n_vs_a + 1;
    if (vsb & ~vsb_q) n_vs_b = n_vs_b + 1;
    if ({pea,hsa,vsa} !== {peb,hsb,vsb}) n_diff = n_diff + 1;
    hsa_q <= hsa; hsb_q <= hsb; vsa_q <= vsa; vsb_q <= vsb;
  end

  initial begin
    if (!$value$plusargs("tie_hard=%d", tie_hard)) tie_hard = 0;

    hard_rst = 0;
    syncgen_rst = 0;                          // hold the raster in reset...
    repeat (20) @(posedge clk);
    hard_rst = 1;
    repeat (20) @(posedge clk);
    syncgen_rst = 1;                          // ...then let it run, as a modeline write does
    // let the raster settle and both chains fill their delay lines
    repeat (20000) @(posedge clk);

    cmp_en = 1;
    // one clean frame first: the two chains must already agree
    repeat (450000) @(posedge clk);
    if (n_diff != 0) begin
      $display("FAIL: chains disagree with NO soft reset (%0d cycles) -- bench is broken", n_diff);
      errors = errors + 1;
    end

    // now the event under test: a dot_rst pulse of the width a soft_flush gives
    // (64 clk_sys at 27 MHz ~= 2.4 us; at this clock, ~240 cycles)
    soft_pulse = 1;
    repeat (240) @(posedge clk);
    soft_pulse = 0;

    // and two more frames, so any lost/extra sync edge or DE dot is counted
    repeat (900000) @(posedge clk);

    $display("sync_integrity_tb: tie_hard=%0d", tie_hard);
    $display("  DE dots   A=%0d B=%0d   (delta %0d)", n_de_a, n_de_b, n_de_b - n_de_a);
    $display("  hsync rise A=%0d B=%0d  (delta %0d)", n_hs_a, n_hs_b, n_hs_b - n_hs_a);
    $display("  vsync rise A=%0d B=%0d  (delta %0d)", n_vs_a, n_vs_b, n_vs_b - n_vs_a);
    $display("  cycles where the emitted sync differs: %0d", n_diff);

    // ★ LIVENESS. This bench measures ABSENCE of a difference, so it passes trivially
    // if nothing is happening -- and it DID, on its first run: syncgen's counters are
    // reset only by syncgen_rst (a modeline write in the core), so leaving that high
    // left them at X and every counter read 0, "PASS". Refuse to pass without a raster.
    if (n_de_a < 100000) begin
      $display("FAIL: only %0d active dots -- the raster is not running, measurement is vacuous", n_de_a);
      errors = errors + 1;
    end
    if (n_hs_a < 100) begin
      $display("FAIL: only %0d hsync edges -- vacuous", n_hs_a); errors = errors + 1;
    end
    if (n_vs_a < 2) begin
      $display("FAIL: only %0d vsync edges -- vacuous (check vertical_sync_start vs vertical_length)", n_vs_a);
      errors = errors + 1;
    end

    if (n_de_b != n_de_a) begin
      $display("FAIL: a soft reset changed the ACTIVE-PIXEL count at the pins (%0d vs %0d)",
               n_de_b, n_de_a); errors = errors + 1;
    end
    if (n_hs_b != n_hs_a) begin
      $display("FAIL: a soft reset changed the HSYNC edge count (%0d vs %0d)",
               n_hs_b, n_hs_a); errors = errors + 1;
    end
    if (n_vs_b != n_vs_a) begin
      $display("FAIL: a soft reset changed the VSYNC edge count (%0d vs %0d)",
               n_vs_b, n_vs_a); errors = errors + 1;
    end
    if (n_diff != 0) begin
      $display("FAIL: emitted sync differed from the reference on %0d cycles", n_diff);
      errors = errors + 1;
    end

    if (errors == 0) $display("sync_integrity_tb: PASS -- a soft reset is invisible at the sync pins");
    else             $fatal(1, "sync_integrity_tb: %0d FAILURE(S)", errors);
    $finish;
  end

endmodule
