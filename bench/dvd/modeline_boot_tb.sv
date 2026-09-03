`timescale 1ns/1ps
//
// modeline_boot_tb.sv — the BOOT-TIME MODELINE WALK RESET RACE (2026-09-02 HW
// report: `Video Output = Auto` with analog ini bits shows 719x...i @ 31.48 kHz
// and a dead CRT — il_eff asserted, raster still progressive).
//
// THE RACE: emu.sv's modeline-walk sequencer keys on RAW reset_n and fires its
// six regfile writes starting the very next clk_dec cycle, but the decoder's
// resets are SYNCHRONIZED INSIDE mpeg2video (reset.v: 5-FF sync_reset stages,
// cascaded) — hard_rst, which gates every modeline register in regfile.v,
// deasserts ~5-10 clk cycles AFTER reset_n rises. Writes landing inside that
// window are silently discarded while the registers re-default to the
// PROGRESSIVE modeline; the walk latches il_prev anyway, so no edge remains to
// retry, and the core runs a progressive raster with VGA_F1 toggling forever.
//
// The race existed since the walk was built, but was INVISIBLE: il_eff was 0
// at boot (the swallowed init walk wrote the progressive values the registers
// were resetting to anyway), and every mode change arrived later via OSD with
// the decoder long out of reset. `Video Output = Auto` from the MiSTer.ini
// bits is the first time the boot-time walk writes something DIFFERENT from
// the reset defaults.
//
// This bench instantiates the REAL reset.v + regfile.v (wired exactly as
// mpeg2video wires them) and drives them with a VERBATIM
// copy of emu.sv's walk sequencer, il_out=1 from t0 (the Auto-with-analog-ini
// boot). It then reads the regfile modeline hierarchically:
//   RED  (+holdoff=0): some/all interlaced-mode registers still hold their
//                      progressive reset defaults — the swallowed walk.
//   GREEN(+holdoff=1): the fix — kicks gated on sync_rst_out having been
//                      deasserted for a few cycles — lands every register.
// A control phase toggles il_out with the decoder long alive (the historical
// OSD path) and must apply in both variants.
//
// PHASE [4] (single-raster analog, 2026-09-03 — the RGBS/YPbPr "raster shakes
// every second" field reports): a WATCHDOG expiry must not touch the running
// raster. The bench attaches the REAL syncgen_intf + sync_gen to the regfile,
// wired as mpeg2video wires them, pulses watchdog_rst mid-field and measures the
// vsync spacing across it. syncgen_intf's modeline copies used to sit on dot_rst
// (which the watchdog pulses); sync_reg zeroes them asynchronously, so the running
// sync_gen saw horizontal_length=0 / interlaced=0 for a few dots and re-phased —
// a full raster restart on the analog pins at every expiry (+ the VLD sizes going
// to 0 = the "1441x478i" resolution popup). The fix puts the copies on the hard
// reset like the regfile itself (mpeg2video.dot_hard_rst).
//   +wdraster=0 : RED  — copies on dot_rst (the old wiring): spacing breaks
//   +wdraster=1 : GREEN — copies on the dot-domain hard reset: 450450 every field
//
// Build:
//   iverilog -g2012 -I rtl/mpeg2 -o bench/dvd/modeline_boot_sim \
//     rtl/mpeg2/reset.v rtl/mpeg2/synchronizer.v rtl/mpeg2/regfile.v \
//     rtl/mpeg2/mem_addr.v rtl/mpeg2/syncgen_intf.v rtl/mpeg2/syncgen.v \
//     bench/dvd/modeline_boot_tb.sv
//   vvp bench/dvd/modeline_boot_sim +holdoff=0 +wdraster=1   (RED: boot race)
//   vvp bench/dvd/modeline_boot_sim +holdoff=1 +wdraster=0   (RED: watchdog raster)
//   vvp bench/dvd/modeline_boot_sim +holdoff=1 +wdraster=1   (GREEN)
// Or: bash bench/dvd/run_modeline_boot.sh
//
module modeline_boot_tb;

  // clocks (ratios roughly like HW: clk_dec 81 / mem 90 / dot 27)
  reg clk = 0;      always #6  clk = ~clk;
  reg mem_clk = 0;  always #5  mem_clk = ~mem_clk;
  reg dot_clk = 0;  always #18 dot_clk = ~dot_clk;

  reg rst = 0;      // emu reset_n equivalent (raw, as the walk sees it)

  // ---- walk -> decoder register bus ----
  localparam [3:0] REG_WR_HOR      = 4'h1;
  localparam [3:0] REG_WR_HOR_SYNC = 4'h2;
  localparam [3:0] REG_WR_VER      = 4'h3;
  localparam [3:0] REG_WR_VER_SYNC = 4'h4;
  localparam [3:0] REG_WR_VID_MODE = 4'h5;
  localparam [3:0] REG_WR_TRICK    = 4'hb;

  reg  il_out = 1'b1;               // Video Output = Auto + analog ini: fields from boot
  wire pal_out = 1'b0, filmp_out = 1'b0;

  reg  il_s1, il_s2, il_prev, il_init;
  reg  pal_s1, pal_s2, pal_prev;
  reg  filmp_s1, filmp_s2, filmp_prev;
  reg  seq_run;
  reg  [2:0] seq_step;

  wire sync_rst_out;
  integer holdoff = 0;
  integer wdraster = 1;
  reg  watchdog_rst = 1'b1;          // active-LOW expiry pulse (watchdog.v)

  // ---- the FIX under test: only allow kicks once the decoder's synchronized
  // reset has been observed deasserted for a few cycles (regfile writable) ----
  reg [2:0] dec_rdy_cnt;
  always @(posedge clk)
    if (!rst || !sync_rst_out) dec_rdy_cnt <= 3'd0;
    else if (dec_rdy_cnt != 3'd7) dec_rdy_cnt <= dec_rdy_cnt + 3'd1;
  wire dec_ready = (holdoff == 0) || (dec_rdy_cnt == 3'd7);

  // ---- VERBATIM emu.sv walk sequencer (modulo the dec_ready gate) ----
  always @(posedge clk) begin
    if (!rst) begin
        il_s1 <= 1'b0; il_s2 <= 1'b0; il_prev <= 1'b0;
        pal_s1 <= 1'b0; pal_s2 <= 1'b0; pal_prev <= 1'b0;
        filmp_s1 <= 1'b0; filmp_s2 <= 1'b0; filmp_prev <= 1'b0;
        il_init <= 1'b0; seq_run <= 1'b0; seq_step <= 3'd0;
    end else begin
        il_s1  <= il_out;
        il_s2  <= il_s1;
        pal_s1 <= pal_out;
        pal_s2 <= pal_s1;
        filmp_s1 <= filmp_out;
        filmp_s2 <= filmp_s1;
        if (seq_run) begin
            if (seq_step == 3'd5) seq_run <= 1'b0;
            seq_step <= seq_step + 3'd1;
        end else if (dec_ready &&
                     (!il_init || (il_s2 != il_prev) || (pal_s2 != pal_prev) || (filmp_s2 != filmp_prev))) begin
            il_prev  <= il_s2;
            pal_prev <= pal_s2;
            filmp_prev <= filmp_s2;
            il_init  <= 1'b1;
            seq_run  <= 1'b1;
            seq_step <= 3'd0;
        end
    end
  end

  wire [10:0] trick_w = { il_prev ? 1'b0 : 1'b1, 5'b00000, 1'b1, 3'b000, 1'b0 };
  reg  [3:0]  wr_addr;
  reg  [31:0] wr_data;
  always @(*) begin
    case (seq_step)
        3'd0: begin wr_addr = REG_WR_HOR;
                    wr_data = pal_prev ? {4'b0, 12'd720, 4'b0, 12'd863}
                                       : {4'b0, 12'd720, 4'b0, 12'd857}; end
        3'd1: begin wr_addr = REG_WR_HOR_SYNC;
                    wr_data = {4'b0, 12'd735, 4'b0, 12'd797}; end
        3'd2: begin wr_addr = REG_WR_VER;
                    wr_data = il_prev ? {4'b0, 12'd480, 4'b0, 12'd261}
                                      : {4'b0, 12'd480, 4'b0, 12'd524}; end
        3'd3: begin wr_addr = REG_WR_VER_SYNC;
                    wr_data = il_prev ? {4'b0, 12'd244, 4'b0, 12'd247}
                                      : {4'b0, 12'd488, 4'b0, 12'd494}; end
        3'd4: begin wr_addr = REG_WR_VID_MODE;
                    wr_data = il_prev ? {4'b0, 12'd0, 13'b0, 3'b011}     // pixrep + interlaced
                                      : {4'b0, 12'd0, 13'b0, 3'b000}; end
        default: begin wr_addr = REG_WR_TRICK;
                    wr_data = {21'b0, trick_w}; end
    endcase
  end

  // ---- the real reset synchronizer + register file, wired EXACTLY as
  //      mpeg2video wires them (reset.v -> clk_rst/hard_rst; regfile on
  //      hard_rst + rst=sync_rst). The whole race lives in these two modules
  //      plus the walk above; the rest of the decoder is irrelevant to it
  //      (and mpeg2video.v's declaration ordering trips iverilog anyway). ----
  wire sync_rst_w, mem_rst_w, dot_rst_w, hard_rst_w;
  reset u_reset (
    .clk(clk), .mem_clk(mem_clk), .dot_clk(dot_clk),
    .async_rst(rst),
    .watchdog_rst(watchdog_rst),   // pulsed low in phase [4]
    .soft_rst_n(1'b1),
    .clk_rst(sync_rst_w), .mem_rst(mem_rst_w), .dot_rst(dot_rst_w),
    .hard_rst(hard_rst_w)
  );
  assign sync_rst_out = sync_rst_w;   // what emu's core_sync_rst tap reads

  wire [11:0] rf_hres, rf_hss, rf_hse, rf_hlen, rf_vres, rf_vss, rf_vse, rf_half, rf_vlen;
  wire        rf_clip, rf_ilace, rf_pixrep, rf_sgrst;
  regfile regfile (
    .clk(clk), .clk_en(1'b1),
    .hard_rst(hard_rst_w),
    .rst(sync_rst_w),
    .reg_addr(seq_run ? wr_addr : 4'b0),
    .reg_wr_en(seq_run),
    .reg_dta_in(wr_data),
    .reg_rd_en(1'b0),
    .horizontal_resolution(rf_hres), .horizontal_sync_start(rf_hss),
    .horizontal_sync_end(rf_hse), .horizontal_length(rf_hlen),
    .vertical_resolution(rf_vres), .vertical_sync_start(rf_vss),
    .vertical_sync_end(rf_vse), .horizontal_halfline(rf_half),
    .vertical_length(rf_vlen), .clip_display_size(rf_clip),
    .interlaced(rf_ilace), .pixel_repetition(rf_pixrep), .syncgen_rst(rf_sgrst),
    .vld_err(1'b0), .v_sync(1'b0),
    .progressive_sequence(1'b0),
    .horizontal_size(14'd0), .vertical_size(14'd0),
    .display_horizontal_size(14'd0), .display_vertical_size(14'd0),
    .frame_rate_code(4'd0), .frame_rate_extension_n(2'd0), .frame_rate_extension_d(5'd0),
    .aspect_ratio_information(4'd0), .mb_width(8'd0),
    .update_picture_buffers(1'b0),
    .watchdog_status(1'b1),
    .osd_wr_full(1'b0), .osd_wr_ack(1'b0),
    .testpoint(34'd0)
  );

  // ---- the REAL raster generator on the regfile, wired as mpeg2video wires it.
  //      sgi_rst = what the modeline COPIES inside syncgen_intf reset on:
  //      the old dot_rst (watchdog pulses it) or the fix's dot-domain hard reset.
  wire dot_hard_rst_w;
  sync_reset u_dot_hard (.clk(dot_clk), .asyncrst(hard_rst_w), .syncrst(dot_hard_rst_w));
  wire sgi_rst = (wdraster != 0) ? dot_hard_rst_w : dot_rst_w;
  wire [11:0] sg_hpos, sg_vpos;
  wire        sg_pe, sg_hs, sg_vs, sg_cs, sg_hb, sg_vb;
  syncgen_intf u_sgi (
    .clk(dot_clk), .clk_en(1'b1), .rst(sgi_rst),
    .horizontal_size(14'd720), .vertical_size(14'd480),
    .display_horizontal_size(14'd0), .display_vertical_size(14'd0),
    .syncgen_rst(rf_sgrst),
    .horizontal_resolution(rf_hres), .horizontal_sync_start(rf_hss),
    .horizontal_sync_end(rf_hse), .horizontal_length(rf_hlen),
    .vertical_resolution(rf_vres), .vertical_sync_start(rf_vss),
    .vertical_sync_end(rf_vse), .horizontal_halfline(rf_half),
    .vertical_length(rf_vlen), .interlaced(rf_ilace),
    .clip_display_size(rf_clip), .pixel_repetition(rf_pixrep),
    .h_pos(sg_hpos), .v_pos(sg_vpos), .pixel_en(sg_pe),
    .h_sync(sg_hs), .v_sync(sg_vs), .c_sync(sg_cs), .h_blank(sg_hb), .v_blank(sg_vb));

  // vsync-to-vsync spacing tracker (dot clocks). 450450 = 262.5 lines of 1716.
  localparam integer FIELD_DOTS = 450450;
  integer dot = 0, last_vs = -1, vs_n = 0, bad_sp = 0, sp_measured = 0;
  reg     vs_q = 0, track = 0;
  always @(posedge dot_clk) if (rst) begin
    dot <= dot + 1;
    vs_q <= sg_vs;
    if (sg_vs && !vs_q) begin
      if (track && last_vs >= 0) begin
        sp_measured = sp_measured + 1;
        if ((dot - last_vs) != FIELD_DOTS) begin
          bad_sp = bad_sp + 1;
          if (bad_sp <= 6) $display("  vsync spacing %0d dots (expect %0d) at dot %0d", dot - last_vs, FIELD_DOTS, dot);
        end
      end
      last_vs = dot;
      vs_n = vs_n + 1;
    end
  end

  integer errors = 0;
  task chk(input cond, input [8*64-1:0] msg);
    if (!cond) begin errors = errors + 1; $display("  FAIL: %0s", msg); end
  endtask

  task check_interlaced_modeline(input [8*16-1:0] phase);
    begin
      $display("[%0s] regfile: hlen=%0d vres=%0d vlen=%0d vss=%0d ilace=%b pixrep=%b deint=%b",
               phase,
               regfile.horizontal_length, regfile.vertical_resolution,
               regfile.vertical_length, regfile.vertical_sync_start,
               regfile.interlaced, regfile.pixel_repetition, regfile.deinterlace);
      chk(regfile.horizontal_length    == 12'd857, "horizontal_length not applied");
      chk(regfile.vertical_resolution  == 12'd480, "vertical_resolution not applied (per-field)");
      chk(regfile.horizontal_halfline  == 12'd0,   "VID_MODE halfline not 0 (the analog half-line lives in sys_top's csync)");
      chk(regfile.vertical_length      == 12'd261, "vertical_length not applied (per-field)");
      chk(regfile.vertical_sync_start  == 12'd244, "vertical_sync_start not applied (per-field)");
      chk(regfile.interlaced           == 1'b1,    "VID_MODE interlaced not applied");
      chk(regfile.pixel_repetition     == 1'b1,    "VID_MODE pixel_repetition not applied");
      chk(regfile.deinterlace          == 1'b0,    "TRICK deinterlace=0 not applied");
    end
  endtask

  initial begin
    void'($value$plusargs("holdoff=%d", holdoff));
    void'($value$plusargs("wdraster=%d", wdraster));
    $display("\n==== modeline_boot_tb  holdoff=%0d wdraster=%0d ====", holdoff, wdraster);
    rst = 0;
    repeat (20) @(posedge clk);
    rst = 1;                                  // reset_n release; il_out already 1 (the Auto boot)

    // [1] BOOT: give it far longer than any synchronizer + walk needs
    repeat (2000) @(posedge clk);
    check_interlaced_modeline("1-boot");

    // [2] control: the historical OSD path — flip to progressive and back with
    // the decoder long alive; must apply in BOTH variants.
    il_out = 0;
    repeat (500) @(posedge clk);
    chk(regfile.interlaced == 1'b0, "control: progressive OSD toggle not applied");
    il_out = 1;
    repeat (500) @(posedge clk);
    check_interlaced_modeline("2-osd-toggle");

    // [3] a SECOND reset pulse with il_out still 1 (core reload with the ini
    // bits set) — the same boot race again.
    rst = 0;
    repeat (20) @(posedge clk);
    rst = 1;
    repeat (2000) @(posedge clk);
    check_interlaced_modeline("3-reload");

    // [4] WATCHDOG vs the running raster: let the fields raster settle, start
    // tracking vsync spacing, pulse the watchdog mid-field, keep tracking.
    // Every spacing must stay 450450 dot clocks; the regfile must keep its modeline.
    @(posedge sg_vs); @(posedge sg_vs); @(posedge sg_vs);    // settle after the reload walk
    track = 1;
    @(posedge sg_vs); @(posedge sg_vs);                      // two clean spacings
    repeat (FIELD_DOTS / 3) @(posedge dot_clk);              // mid-field
    $display("[4-watchdog] pulsing watchdog_rst at dot %0d", dot);
    @(posedge clk); watchdog_rst = 1'b0;
    @(posedge clk); @(posedge clk); watchdog_rst = 1'b1;
    @(posedge sg_vs); @(posedge sg_vs); @(posedge sg_vs); @(posedge sg_vs); @(posedge sg_vs);
    track = 0;
    $display("[4-watchdog] %0d spacings measured across the expiry, %0d wrong", sp_measured, bad_sp);
    chk(sp_measured >= 6, "watchdog phase: too few vsync spacings measured");
    chk(bad_sp == 0, "watchdog expiry re-phased the raster (vsync spacing broke)");
    check_interlaced_modeline("4-watchdog");

    if (errors == 0) begin
      $display("\n==== PASS (holdoff=%0d wdraster=%0d) ====", holdoff, wdraster);
      $finish;
    end else
      $fatal(1, "==== FAIL (holdoff=%0d wdraster=%0d): %0d error(s) ====", holdoff, wdraster, errors);
  end

  initial begin
    #400_000_000;
    $fatal(1, "TIMEOUT");
  end

endmodule
