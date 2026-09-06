/*
 * csync_pipe_tb.sv — how many clocks does the framework put between emu's VGA_HS pin
 * and the composite sync that reaches the analog output stage?
 *
 * WHY THIS BENCH EXISTS.  dvd/csync_smpte.sv generates composite sync from the core's
 * own raster and hands it to sys_top on VGA_CS, which is emitted in the SAME clock as
 * VGA_HS. The stock composite sync it replaces is built much later — after
 * sync_fix, scanlines and osd have each delayed hsync — so sys_top has to delay our
 * bit by exactly that much before the two can be muxed. Get that number wrong and
 * every sync edge on the analog pins moves by 37 ns per clock: hsync stops landing
 * where the equalizing pulses were placed relative to it, and the whole point of the
 * change is lost in a way that is invisible in every other bench and expensive to
 * find on hardware.
 *
 * ★ So the number is MEASURED here through the REAL modules — sys/scanlines.v,
 * sys/osd.v and the `csync` extracted from sys/sys_top.v — and checked against the
 * value sys_top actually uses, which run_csync_pipe.sh greps out of sys_top.v. A
 * hand-counted constant in a comment is exactly the kind of thing that goes stale
 * when an upstream module gains a pipeline stage; this fails the build instead.
 *
 * Chain under test (sys/sys_top.v around :1350-1400):
 *   VGA_HS -> sync_fix (combinational, `sync_out = sync_in ^ pol`)
 *          -> scanlines (hs_in -> hs1 -> hs2 -> hs_out = 3)
 *          -> osd       (hs_in -> hs1 -> hs2 -> hs3 -> hs_out = 4)
 *          -> csync     (csync_hs registered = 1)
 * Outside vsync the stock module emits `0 ^ csync_hs`, i.e. hsync delayed, so the
 * total is directly measurable as an edge-to-edge latency on a plain raster.
 *
 * ⚠ sync_fix is NOT modelled: its `pol` settles to 0 for the active-high pulses emu
 * emits and it adds no register, so it contributes zero. If it ever gains a stage,
 * this bench will not see it — but sys_top's CS_PIPE and this measurement would then
 * both be wrong in the same direction, which is why the mux equality gate in
 * csync_field_tb.sv (the stock arm) is the backstop.
 *
 * Build/run: bash bench/dvd/run_csync_pipe.sh
 */
`include "timescale.v"
`include "csync_pipe_gen.vh"   // GENERATED: `define CS_PIPE_EXPECT <sys_top's value>

module csync_pipe_tb;

  localparam integer LINE   = 1716;
  localparam integer HS_W   = 125;
  localparam integer FIELD  = 262;

  reg clk = 0; always #18.5 clk = ~clk;      // 27 MHz

  // ---- a plain interlace-free raster: hsync every LINE dots, vsync 3 lines --------
  integer dot = 0, line = 0;
  reg     hs = 0, vs = 0;
  always @(posedge clk) begin
    dot <= (dot == LINE-1) ? 0 : dot + 1;
    if (dot == LINE-1) line <= (line == FIELD-1) ? 0 : line + 1;
    hs <= (dot < HS_W);
    vs <= (line >= 244) && (line < 247);
  end

  // ---- the real framework chain --------------------------------------------------
  wire [23:0] sl_d, osd_d;
  wire        sl_hs, sl_vs, sl_de, sl_ce;
  wire        osd_hs, osd_vs, osd_de;
  wire        cs;

  scanlines #(0) sl (
    .clk(clk), .scanlines(2'd0), .din(24'd0),
    .hs_in(hs), .vs_in(vs), .de_in(1'b0), .ce_in(1'b1),
    .dout(sl_d), .hs_out(sl_hs), .vs_out(sl_vs), .de_out(sl_de), .ce_out(sl_ce));

  osd osd_i (
    .clk_sys(clk), .io_osd(1'b0), .io_strobe(1'b0), .io_din(16'd0),
    .clk_video(clk), .din(sl_d),
    .hs_in(sl_hs), .vs_in(sl_vs), .de_in(sl_de),
    .dout(osd_d), .hs_out(osd_hs), .vs_out(osd_vs), .de_out(osd_de),
    .osd_status());

  csync_ref csync_i (.clk(clk), .hsync(osd_hs), .vsync(osd_vs), .csync(cs));

  // ---- measure the latency, on lines that are nowhere near vsync ------------------
  // Both edges are sampled on plain picture lines, where the stock module is a pure
  // hsync delay. Every measurement must agree, so a jittering chain fails too.
  integer t = 0;
  integer hs_rise = -1;
  integer meas = -1, n_meas = 0, bad = 0;
  reg     hs_q = 0, cs_q = 0;

  always @(posedge clk) begin
    t <= t + 1;
    hs_q <= hs;
    cs_q <= cs;
    if (line > 4 && line < 200) begin           // well clear of the vertical interval
      if (hs && !hs_q) hs_rise <= t;
      if (cs && !cs_q && hs_rise >= 0) begin
        n_meas = n_meas + 1;
        if (meas < 0) meas = t - hs_rise;
        else if ((t - hs_rise) != meas) bad = bad + 1;
      end
    end
  end

  initial begin
    repeat (4 * FIELD * LINE) @(posedge clk);
    $display("csync_pipe_tb: measured VGA_HS -> stock csync latency = %0d clk27 over %0d edges (%0d inconsistent)",
             meas, n_meas, bad);
    $display("csync_pipe_tb: sys/sys_top.v CS_PIPE = %0d", `CS_PIPE_EXPECT);
    if (meas == `CS_PIPE_EXPECT && bad == 0 && n_meas >= 200)
      $display("PASS: csync_pipe_tb — sys_top delays VGA_CS by exactly the framework's own hsync latency");
    else begin
      $display("FAIL: csync_pipe_tb — measured %0d, sys_top uses %0d, %0d inconsistent of %0d edges",
               meas, `CS_PIPE_EXPECT, bad, n_meas);
      $fatal(1);
    end
    $finish;
  end

endmodule
