/*
 * field_phase_tb.sv — do the two displayed fields actually carry DIFFERENT lines?
 *
 * WHY THIS EXISTS (2026-09-03, HW rounds 1-5). The field-parity corrector shipped with
 * a bench (bench/dvd/field_parity_tb.sv) that could not see the defect it introduced,
 * for two reasons worth remembering:
 *
 *   1. its behavioural framestore returns a CONSTANT word, so no displayed pixel
 *      carries any information about WHICH source line it came from — a content-phase
 *      error is invisible by construction;
 *   2. its pass condition (`ft_aligned`) is the same expression as the RTL's own
 *      `frame_top_par_err`. It restates the design's convention instead of checking an
 *      external one, so it agrees with the code whether or not the code is right.
 *      (CLAUDE.md already warns about golden models that agree suspiciously well with
 *      their RTL — the POST-only PGC case. Same trap, different corner.)
 *
 * On hardware the corrector produced two fields sampling the picture at the SAME
 * vertical phase: a still measured +0.00 frame lines of offset between the fields where
 * a correct interlaced still measures +0.50, which is a weave comb and a bob that jumps
 * a field line.
 *
 * ★ HOW THIS BENCH MEASURES THAT, WITH NO REFERENCE TO ANY RTL CONVENTION.
 * The behavioural framestore returns a word whose every byte is a code derived from the
 * source line number — the memory is LINE-STAMPED, so every displayed pixel names the
 * source line it came from (verified: the emitted luma is constant along a displayed line
 * and steps by 2 down a field, because a field image walks source lines y, y+2, y+4 ...).
 * For each displayed field the bench records, off the mixer's OWN output pins:
 *
 *   - `code`  — the stamp of the field's FIRST picture line  => its source line;
 *   - `vpar`  — the raster field it landed in (v_pos parity at that line: even = the
 *               raster's top field, odd = the bottom field);
 *   - `hash`  — an FNV-1a hash of every luma sample the mixer emitted in the field.
 *
 * and checks three things:
 *
 *   INVARIANT A (the HW defect): consecutive fields must carry DIFFERENT source lines.
 *     `line(n) - line(n-1)` must be +/-1 — the RTL equivalent of the screenshot's
 *     +0.50 frame-line field offset. The shipped corrector made it 0.
 *   INVARIANT B: over a steady window the emitted content must repeat with period 2
 *     (hash(n) == hash(n-2)) — the display alternates cleanly rather than wandering.
 *   INVARIANT C (what the corrector is FOR, checked externally): an EVEN source line
 *     must be displayed in an EVEN (top) raster field. `base_code` — the smallest
 *     first-line stamp seen in the whole run — is source line 0 by construction, so
 *     the line parity is derived from the DATA, not from the mixer's ROW_0/ROW_1
 *     labelling that field_parity_tb (and the corrector's own feedback) both use.
 *
 * A field that is a deliberate REPEAT of its predecessor (the corrector inserting one
 * field to re-align a cadence break, or the governor holding a frame) legitimately
 * violates A once, and a field or two may land misaligned before the feedback arm
 * reacts. So each scenario is windowed: a SETTLE window absorbs the correction (its
 * violations are counted and reported, bounded), and the CHECK window that follows must
 * be clean on all three invariants.
 *
 * ★ SCENARIO [6] IS THE ONE THAT FOUND THE HW DEFECT, and it is the mundane one: it
 * STARVES the pixel queue. Every scenario written from the field reports (seeks, cold
 * start, cadence breaks) passed with the withdrawn corrector enabled. A starved raster
 * field displays nothing and shifts every following content field one slot, so the parity
 * error it raises is REAL — but this core is compute-bound and does that several times a
 * second, and the feedback arm's cure is a REPEATED field. [6] budgets those repeats:
 * shipped corrector 4 per 4 starves, corrector disabled 0, corrector with the stability
 * gate 0.
 *
 * ⚠ FAILS BY DESIGN ON A BUILD WITH THE CORRECTOR DISABLED — invariant C is exactly the
 * "super aliased after a chapter skip" coin flip (docs/field_parity.md). A silent run is
 * not a pass: every window prints a verdict line and the run prints a summary.
 *
 * Scenarios mirror field_parity_tb's so the two can be compared directly.
 *
 * Build:
 *   iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/field_phase_sim \
 *     rtl/mpeg2/resample.v dvd/resample_addrgen.v rtl/mpeg2/resample_dta.v \
 *     rtl/mpeg2/resample_bilinear.v rtl/mpeg2/mem_addr.v rtl/mpeg2/mixer.v \
 *     rtl/mpeg2/pixel_queue.v rtl/mpeg2/syncgen.v rtl/mpeg2/read_write.v \
 *     rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v rtl/mpeg2/xilinx_fifo_dc.v \
 *     rtl/mpeg2/xfifo_sc.v bench/dvd/field_phase_tb.sv
 *   vvp bench/dvd/field_phase_sim +phase=0 [+dbg]
 * Or: bash bench/dvd/run_field_phase.sh
 */
`timescale 1ns/1ps
module field_phase_tb;

`include "resample_codes.v"

  // ---- narrow/fast interlaced geometry (field_parity_tb's, halved vertically:
  //      content 64x128 -> 64-line fields) ----
  // 128 source lines rather than that bench's 256 for two reasons: it halves a
  // 5-window run's wall time, and it keeps the line stamp below (7 bits) unique for
  // every source line, so a displayed pixel names its line with no ambiguity.
  localparam [7:0]  MB_WIDTH        = 8'd4;
  localparam [7:0]  MB_HEIGHT       = 8'd8;
  localparam [13:0] HORIZONTAL_SIZE = 14'd64;
  localparam [13:0] VERTICAL_SIZE   = 14'd128;
  localparam [11:0] H_RES = 12'd64,  H_SS = 12'd70,  H_SE = 12'd78,  H_LEN = 12'd84;
  // Vertical raster = content-woven 128 lines + small blanking.
  localparam [11:0] V_RES = 12'd132, V_SS = 12'd140, V_SE = 12'd143, V_LEN = 12'd152;

  // ---- clocks (2:1 like HW clk_dec 54 / dot_clk 27) ----
  reg clk = 0;      always #5  clk = ~clk;
  reg dot_clk = 0;  always #10 dot_clk = ~dot_clk;
  reg rst = 0;

  // ---- stimulus ----
  reg  [2:0] output_frame = 3'd2;
  reg        output_frame_valid = 0;
  wire       output_frame_rd;
  reg        progressive_sequence = 0;       // DVD coding: interlaced sequence
  reg        progressive_frame = 0;          // [1]-[4]: true video; [5]: film
  reg        top_field_first = 1;
  reg        repeat_first_field = 0;
  reg        film_mode = 0;                  // [5]: tff toggles per consumed picture
  always @(posedge clk)
    if (rst && film_mode && output_frame_rd) top_field_first <= ~top_field_first;

  // ---- resample <-> framestore_reader ----
  wire        disp_wr_addr_full, disp_wr_addr_almost_full;
  wire        disp_wr_addr_en, disp_wr_addr_ack;
  wire [21:0] disp_wr_addr;
  wire        disp_rd_dta_empty, disp_rd_dta_almost_empty;
  wire        disp_rd_dta_en, disp_rd_dta_valid;
  wire [63:0] disp_rd_dta;
  wire        resample_wr_overflow;

  // ---- resample -> pixel_queue -> mixer ----
  wire [7:0]  px_y, px_u, px_v, px_osd;
  wire [2:0]  px_position;
  wire        px_wr_en, pq_wr_almost_full;
  wire [7:0]  mx_y, mx_u, mx_v, mx_osd;
  wire [2:0]  mx_position;
  wire        mx_rd_en, mx_rd_empty, mx_rd_valid, mx_rd_underflow;

  // ---- sync_gen -> mixer ----
  wire [11:0] h_pos, v_pos;
  wire        h_sync, v_sync, pixel_en;
  wire [7:0]  y_out, u_out, v_out, osd_out;
  wire        h_sync_out, v_sync_out, pixel_en_out;

  // ---- the parity feedback loop (mpeg2video's sync_reg CDC, replicated) ----
`ifndef NO_PARITY_FIX
  wire mixer_par_err;
  reg  pe_s1 = 0, pe_s2 = 0;
  always @(posedge clk) begin pe_s1 <= mixer_par_err; pe_s2 <= pe_s1; end
  wire par_err_sync = pe_s2;
`endif

  resample resample (
    .clk(clk), .rst(rst),
    .output_frame(output_frame), .output_frame_valid(output_frame_valid),
    .output_frame_rd(output_frame_rd),
    .progressive_sequence(progressive_sequence), .progressive_frame(progressive_frame),
    .informative(1'b1),
    .top_field_first(top_field_first), .repeat_first_field(repeat_first_field),
    .mb_width(MB_WIDTH), .mb_height(MB_HEIGHT),
    .horizontal_size(HORIZONTAL_SIZE), .vertical_size(VERTICAL_SIZE),
    .resample_wr_overflow(resample_wr_overflow),
    .disp_wr_addr_full(disp_wr_addr_full), .disp_wr_addr_almost_full(disp_wr_addr_almost_full),
    .disp_wr_addr_en(disp_wr_addr_en), .disp_wr_addr_ack(disp_wr_addr_ack), .disp_wr_addr(disp_wr_addr),
    .disp_rd_dta_empty(disp_rd_dta_empty), .disp_rd_dta_en(disp_rd_dta_en),
    .disp_rd_dta_valid(disp_rd_dta_valid), .disp_rd_dta(disp_rd_dta),
    .pixel_wr_almost_full(pq_wr_almost_full),
    .interlaced(1'b1), .deinterlace(1'b0),       // native fields display path
    .persistence(1'b1), .repeat_frame(5'd0),
    .y(px_y), .u(px_u), .v(px_v), .osd_out(px_osd),
    .position_out(px_position), .pixel_wr_en(px_wr_en),
    .video_live(), .pickup_hold(1'b0), .pause(1'b0),
`ifndef NO_PARITY_FIX
    .raster_par_err(par_err_sync),
`endif
    .vscale_mode(2'd0), .hcrop_en(1'b0), .menu_ff(1'b0), .film24(1'b0)
  );

  // framestore_reader + full-rate behavioural memory, LINE-STAMPED.
  wire        rd_addr_empty, rd_addr_valid;
  wire [21:0] rd_addr;
  wire        wr_dta_full, wr_dta_almost_full, wr_dta_ack, wr_dta_overflow;
  reg         wr_dta_en;
  /* Scenario [6] stalls the framestore to starve the pixel queue — the "mixer underflow
   * slip" docs/field_parity.md lists as a phase-flip trigger, and the one the real core
   * hits several times a second when it is compute-bound. */
  reg         mem_stall = 1'b0;
  wire        rd_addr_en = ~rd_addr_empty && ~wr_dta_almost_full && ~mem_stall;
  reg [21:0] rd_addr_q;
  always @(posedge clk) rd_addr_q <= rd_addr;
  /* A 64-pixel luma line is 8 memory words, so rd_addr[2:0] is the column and the bits
   * above it are the source line number: the stamp is constant ALONG a displayed line
   * (verified at three columns) and identifies WHICH line it is.
   * ⚠ The display path adds a MEASURED +128 to the luma between here and the mixer's
   * pins, so a 7-bit stamp comes out as 128..255 — deliberately chosen: that band can
   * never collide with the mixer's black level (16) and never wraps, so "this pixel is
   * picture, not blanking" is a >= 128 test. Nothing below assumes a particular
   * absolute value: `base_code` is measured, and the self-check after the run asserts
   * that exactly two first-line stamps appeared and that they differ by 1. */
  wire [7:0] addr_code = {1'b0, rd_addr_q[9:3]};
  wire [63:0] mem_word = {8{addr_code}};

  framestore_reader #(
    .fifo_addr_depth(9'd8), .fifo_dta_depth(9'd8),
    .fifo_addr_threshold(9'd32), .fifo_dta_threshold(9'd64))
  disp_reader (
    .rst(rst), .clk(clk),
    .wr_addr_clk_en(1'b1),
    .wr_addr_full(disp_wr_addr_full), .wr_addr_almost_full(disp_wr_addr_almost_full),
    .wr_addr_en(disp_wr_addr_en), .wr_addr_ack(disp_wr_addr_ack),
    .wr_addr_overflow(), .wr_addr(disp_wr_addr),
    .rd_dta_clk_en(1'b1),
    .rd_dta_almost_empty(disp_rd_dta_almost_empty), .rd_dta_empty(disp_rd_dta_empty),
    .rd_dta_en(disp_rd_dta_en), .rd_dta_valid(disp_rd_dta_valid), .rd_dta(disp_rd_dta),
    .rd_addr_empty(rd_addr_empty), .rd_addr_en(rd_addr_en),
    .rd_addr(rd_addr), .rd_addr_valid(rd_addr_valid),
    .wr_dta_full(wr_dta_full), .wr_dta_almost_full(wr_dta_almost_full),
    .wr_dta_en(wr_dta_en), .wr_dta_ack(wr_dta_ack), .wr_dta_overflow(wr_dta_overflow),
    .wr_dta(mem_word)
  );
  always @(posedge clk)
    if (~rst) wr_dta_en <= 1'b0;
    else      wr_dta_en <= rd_addr_valid;

  pixel_queue pixel_queue (
    .clk_in(clk), .clk_in_en(1'b1), .rst(rst),
    .y_in(px_y), .u_in(px_u), .v_in(px_v), .osd_in(px_osd), .position_in(px_position),
    .pixel_wr_en(px_wr_en), .pixel_wr_almost_full(pq_wr_almost_full),
    .pixel_wr_full(), .pixel_wr_overflow(),
    .clk_out(dot_clk), .clk_out_en(1'b1),
    .y_out(mx_y), .u_out(mx_u), .v_out(mx_v), .osd_out(mx_osd), .position_out(mx_position),
    .pixel_rd_en(mx_rd_en), .pixel_rd_empty(mx_rd_empty),
    .pixel_rd_valid(mx_rd_valid), .pixel_rd_underflow(mx_rd_underflow)
  );

  sync_gen sync_gen (
    .clk(dot_clk), .clk_en(1'b1), .rst(rst),
    .horizontal_size(HORIZONTAL_SIZE), .vertical_size(VERTICAL_SIZE),
    .display_horizontal_size(14'd0), .display_vertical_size(14'd0),
    .horizontal_resolution(H_RES), .horizontal_sync_start(H_SS),
    .horizontal_sync_end(H_SE), .horizontal_length(H_LEN),
    .vertical_resolution(V_RES), .vertical_sync_start(V_SS),
    .vertical_sync_end(V_SE), .horizontal_halfline(12'd0), .vertical_length(V_LEN),
    .interlaced(1'b1), .clip_display_size(1'b0),
    .h_pos(h_pos), .v_pos(v_pos), .pixel_en(pixel_en),
    .h_sync(h_sync), .v_sync(v_sync), .c_sync(), .h_blank(), .v_blank()
  );

  mixer mixer (
    .clk(dot_clk), .clk_en(1'b1), .rst(rst),
    .pixel_repetition(1'b0),
    .y_in(mx_y), .u_in(mx_u), .v_in(mx_v), .osd_in(mx_osd), .position_in(mx_position),
    .pixel_rd_en(mx_rd_en), .pixel_rd_valid(mx_rd_valid), .pixel_rd_underflow(mx_rd_underflow),
    .h_pos(h_pos), .v_pos(v_pos), .h_sync_in(h_sync), .v_sync_in(v_sync), .pixel_en_in(pixel_en),
    .y_out(y_out), .u_out(u_out), .v_out(v_out), .osd_out(osd_out),
    .h_sync_out(h_sync_out), .v_sync_out(v_sync_out), .pixel_en_out(pixel_en_out),
`ifndef NO_PARITY_FIX
    .frame_top_par_err(mixer_par_err),
`endif
    .disp_v_offset(12'd0)
  );

  // ====================================================================
  // CONTENT-PHASE MEASUREMENT — off the mixer's output pins only.
  // ====================================================================
  localparam [7:0] CODE_LO = 8'd128;      // luma at/above this is picture, below is blanking
  localparam [31:0] FNV_OFF = 32'h811C_9DC5, FNV_PRM = 32'h0100_0193;
  localparam integer MAXFLD = 600;

  // one sample per displayed line, at a fixed column safely inside the 64-pixel picture
  wire       pix_probe = pixel_en_out && (h_pos == 12'd4);
  wire       is_code   = (y_out >= CODE_LO);

  reg  [7:0]  rec_code [0:MAXFLD-1];   // source-line stamp of the field's first line
  reg         rec_vpar [0:MAXFLD-1];   // raster field it landed in (v_pos parity)
  reg  [31:0] rec_hash [0:MAXFLD-1];   // FNV-1a over every emitted luma sample

  integer     fld_n = 0;               // displayed fields WITH picture content so far
  reg  [7:0]  base_code = 8'hFF;       // smallest first-line stamp = source line 0
  reg  [7:0]  peak_code = 8'h00;       // largest  first-line stamp (must be base_code + 1)
  reg         stamp_track = 1'b1;      // 0 while starvation can resume a field mid-picture
  reg  [31:0] acc_hash  = FNV_OFF;
  reg         got_first = 1'b0;
  reg  [7:0]  f_code    = 8'd0;
  reg         f_vpar    = 1'b0;
  integer     f_lines   = 0;
  reg         vs_q      = 1'b0;
  integer     dbg = 0;

  always @(posedge dot_clk) if (rst) begin
    vs_q <= v_sync;
    if (pixel_en_out) acc_hash <= (acc_hash ^ {24'd0, y_out}) * FNV_PRM;
    if (pix_probe && is_code) begin
      f_lines = f_lines + 1;
      if (!got_first) begin
        got_first <= 1'b1;
        f_code    <= y_out;
        f_vpar    <= v_pos[0];
      end
    end
    if (v_sync && !vs_q) begin                       // field boundary: close the field
      if (got_first && fld_n < MAXFLD) begin
        rec_code[fld_n] = f_code;
        rec_vpar[fld_n] = f_vpar;
        rec_hash[fld_n] = acc_hash;
        if (stamp_track && f_code < base_code) base_code <= f_code;
        if (stamp_track && f_code > peak_code) peak_code <= f_code;
        if (dbg)   // stamp, not line: base_code is only known once both stamps are in
          $display("    field %0d: stamp %0d in the %s raster field, %0d lines, hash %08x",
                   fld_n, f_code, f_vpar ? "BOTTOM" : "TOP", f_lines, acc_hash);
        fld_n = fld_n + 1;
      end
      acc_hash  <= FNV_OFF;
      got_first <= 1'b0;
      f_lines   = 0;
    end
  end

  task wait_flds(input integer n);
    integer t0;
    begin t0 = fld_n; wait (fld_n >= t0 + n); @(posedge dot_clk); end
  endtask

  localparam SETTLE    = 8;    // fields allowed for a feed-forward correction to land
  localparam SETTLE_FB = 40;   // ... and for a feedback one (PAR_CONFIRM refreshes + slack)
  localparam NCHK      = 16;   // fields that must all carry alternating content after it
  localparam SETTLE_MAX_SAME = 2;   // bounded: at most one inserted field per trigger arm
  localparam SETTLE_MAX_MIS  = 3;   // bounded: the feed-forward arm acts at the pickup
  /* [6] budget. A starved field is a REAL phase flip, but the cure costs a repeated
   * field, so a corrector that chases every one of them at field rate is worse than the
   * error: that is the shipped-corrector HW failure (a still measured +0.00). Four
   * starvation events may cost at most this many repeated fields in total. */
  localparam STUTTER_MAX_SAME = 2;

  integer errors = 0;
  integer settle_worst_same = 0, settle_worst_mis = 0;

  // count invariant violations over recorded fields [a,b)
  //
  // A field STARVED mid-picture is resumed by the mixer at whatever line was next in the
  // queue, so its head is neither source line 0 nor 1. Such a field is the starvation
  // artefact itself, not a scheduling decision, so it is skipped (and counted): judging
  // it would manufacture verdicts out of the perturbation rather than out of the
  // corrector's behaviour.
  integer v_same, v_alt, v_mis, v_part;
  function clean_head(input integer i);
    clean_head = (rec_code[i] == base_code) || (rec_code[i] == base_code + 8'd1);
  endfunction

  /* Invariant C for ONE field, usable live on the last closed field rather than only
   * over a window. Same external criterion tally() uses: the source line's parity
   * (derived from the measured base_code, not from any RTL label) must match the raster
   * field it landed in. */
  function mis_now(input integer i);
    mis_now = clean_head(i) && (((rec_code[i] - base_code) & 1) != rec_vpar[i]);
  endfunction
  task tally(input integer a, input integer b, input reg verbose);
    integer i;
    begin
      v_same = 0; v_alt = 0; v_mis = 0; v_part = 0;
      for (i = (a < 2) ? 2 : a; i < b; i = i + 1) begin
        if (!clean_head(i)) begin
          v_part = v_part + 1;
        end else if (!clean_head(i-1)) begin
          // neighbour was resumed mid-picture: nothing to compare against, but the
          // alignment of THIS field still is a verdict.
          if (((rec_code[i] - base_code) & 1) != rec_vpar[i]) v_mis = v_mis + 1;
        end else begin
        if (rec_code[i] == rec_code[i-1]) begin
          v_same = v_same + 1;
          if (verbose)
            $display("  field %0d REPEATS field %0d: both carry source line %0d (field offset +0.00 - the fields do not interleave)",
                     i, i-1, rec_code[i] - base_code);
        end
        if (clean_head(i-2) && (rec_hash[i] != rec_hash[i-2])) begin
          v_alt = v_alt + 1;
          if (verbose)
            $display("  field %0d breaks period 2: hash %08x != field %0d's %08x",
                     i, rec_hash[i], i-2, rec_hash[i-2]);
        end
        if (((rec_code[i] - base_code) & 1) != rec_vpar[i]) begin
          v_mis = v_mis + 1;
          if (verbose)
            $display("  field %0d MISALIGNED: %s source line %0d displayed in the %s raster field",
                     i, ((rec_code[i]-base_code) & 1) ? "odd (bottom)" : "even (top)",
                     rec_code[i] - base_code, rec_vpar[i] ? "BOTTOM" : "TOP");
        end
        end
      end
    end
  endtask

  /* `settle` is the number of fields a scenario is allowed for its correction to land.
   * The feed-forward arm acts at the pickup, so SETTLE is plenty; the FEEDBACK arm only
   * fires once the mixer's verdict has HELD for PAR_CONFIRM refreshes (see
   * dvd/resample_addrgen.v — the fix for issue #41), so the windows that exercise it get
   * SETTLE_FB instead. */
  task check_window_s(input [8*40-1:0] name, input integer settle, input integer max_mis);
    integer s0, c0, s_same, s_mis;
    begin
      s0 = fld_n;  wait_flds(settle);          // settle region [s0, s0+settle)
      tally(s0, s0 + settle, 1'b0);
      s_same = v_same;  s_mis = v_mis;
      if (s_same > settle_worst_same) settle_worst_same = s_same;
      if (s_mis  > settle_worst_mis)  settle_worst_mis  = s_mis;

      c0 = fld_n;  wait_flds(NCHK);            // check region [c0, c0+NCHK)
      tally(c0, c0 + NCHK, 1'b1);

      if (v_same == 0 && v_alt == 0 && v_mis == 0 &&
          s_same <= SETTLE_MAX_SAME && s_mis <= max_mis)
        $display("[%0s] PASS: %0d fields, every one carries the OTHER field's lines (offset +/-1) on the matching raster parity; settle saw %0d repeat(s), %0d misaligned",
                 name, NCHK, s_same, s_mis);
      else begin
        errors = errors + 1;
        $display("[%0s] FAIL: %0d repeat(s), %0d period-2 break(s), %0d misaligned in %0d fields (settle saw %0d repeat(s) [max %0d], %0d misaligned [max %0d])",
                 name, v_same, v_alt, v_mis, NCHK, s_same, SETTLE_MAX_SAME, s_mis, max_mis);
      end
    end
  endtask

  task check_window(input [8*40-1:0] name);
    begin check_window_s(name, SETTLE, SETTLE_MAX_MIS); end
  endtask

  /* Stutter the display: n short framestore stalls, spread out. Counts the repeated
   * fields the corrector spent on them. */
  task stutter(input integer n);
    integer i, s0;
    begin
      s0 = fld_n;
      stamp_track = 1'b0;              // a resumed field's head line is arbitrary
      for (i = 0; i < n; i = i + 1) begin
        wait_flds(5);
        mem_stall = 1'b1;
        /* ...and no new frame is ready either. A framestore stall ALONE parks the FSM in
         * STATE_WAIT, which never reaches the persistence branch, so it did not exercise
         * the hold arm of the corrector at all; a compute-bound core starves the queue
         * and misses the frame together. Dropping the frame here puts the churn where
         * BOTH arms live, so this budget guards both. */
        output_frame_valid = 1'b0;
        repeat (2) @(negedge v_sync);
        mem_stall = 1'b0;
        output_frame_valid = 1'b1;
      end
      wait_flds(3);
      stamp_track = 1'b1;
      tally(s0, fld_n, 1'b0);
      if (v_same <= STUTTER_MAX_SAME)
        $display("[6-stutter] PASS: %0d starvation event(s) cost %0d repeated field(s) over %0d fields (%0d resumed mid-picture)",
                 n, v_same, fld_n - s0, v_part);
      else begin
        errors = errors + 1;
        $display("[6-stutter] FAIL: %0d starvation event(s) cost %0d repeated field(s) over %0d fields (budget %0d, %0d resumed mid-picture) - the corrector is chasing starvation at field rate",
                 n, v_same, fld_n - s0, STUTTER_MAX_SAME, v_part);
      end
    end
  endtask

  /* Break the raster phase ON PURPOSE, whatever +phase started it at: one starved raster
   * field displays nothing and shifts every following content field one slot. A stall can
   * eat one field or two, so the break is NOT guaranteed — measure it and retry, and
   * $fatal rather than run a window that proves nothing. Without this, a hold scenario
   * keyed on the cold-start landing would be vacuous on whichever arm happens to start
   * aligned, which is exactly why [7-post-stutter] passes on both arms today. */
  task force_misaligned;
    integer k;
    begin
      k = 0;
      while ((k < 4) && !mis_now(fld_n - 1)) begin
        stamp_track = 1'b0;            // a resumed field's head line is arbitrary
        mem_stall = 1'b1;
        repeat (2) @(negedge v_sync);
        mem_stall = 1'b0;
        wait_flds(3);
        stamp_track = 1'b1;
        k = k + 1;
      end
      if (!mis_now(fld_n - 1))
        $fatal(1, "[8] SCENARIO VACUOUS: the raster phase would not break in %0d starvation event(s)", k);
      $display("[8-setup] raster phase broken after %0d starvation event(s) - the hold below starts MISALIGNED", k);
    end
  endtask

  /* Hold-heal window: the frame is HELD (no pickups at all), so a correction here can
   * only have come from the persistence branch. Settle until the phase has been right for
   * four consecutive fields (bounded by `cap`), then require NCHK clean HELD fields.
   * Adaptive so the normal cost is PAR_CONFIRM-sized; pre-fix it burns the cap, which is
   * the RED. The settle may spend at most ONE repeated field — that is the churn budget
   * for this arm, the same thing STUTTER_MAX_SAME does for the pickup arm. */
  task hold_heal(input [8*40-1:0] name, input integer cap);
    integer s0, c0, run, s_same;
    begin
      s0 = fld_n;  run = 0;
      while (((fld_n - s0) < cap) && (run < 4)) begin
        wait_flds(1);
        if (clean_head(fld_n - 1) && !mis_now(fld_n - 1)) run = run + 1;
        else                                              run = 0;
      end
      tally(s0, fld_n, 1'b0);  s_same = v_same;
      c0 = fld_n;  wait_flds(NCHK);  tally(c0, c0 + NCHK, 1'b1);
      if (v_same == 0 && v_alt == 0 && v_mis == 0 && s_same <= 1)
        $display("[%0s] PASS: healed %0d held field(s) in, at a cost of %0d repeated field(s); %0d held fields clean after",
                 name, c0 - s0, s_same, NCHK);
      else begin
        errors = errors + 1;
        $display("[%0s] FAIL: %0d misaligned, %0d repeat(s), %0d period-2 break(s) over %0d HELD fields after a %0d-field settle (settle cost %0d repeat(s), budget 1)",
                 name, v_mis, v_same, v_alt, NCHK, c0 - s0, s_same);
      end
    end
  endtask

  integer phase = 0;

  initial begin
    void'($value$plusargs("phase=%d", phase));
    if ($test$plusargs("dbg")) dbg = 1;
    $display("\n==== field_phase_tb  +phase=%0d ====", phase);

    rst = 0; output_frame_valid = 0;
    repeat (8) @(posedge clk);
    rst = 1;

    // [1] COLD START at the +phase-selected raster field parity (feedback case)
    repeat (2) @(negedge v_sync);
    repeat (phase) @(negedge v_sync);          // one field period shifts landing parity
    output_frame_valid = 1;
    // the feedback arm's window: misaligned fields are expected while its verdict is
    // still being confirmed, so only the repeat budget is enforced across the settle.
    check_window_s("1-cold-start", SETTLE_FB, SETTLE_FB);

    // [2] SEEK released on a SAME-parity tff (alternation break; the chapter skip)
    output_frame_valid = 0;
    repeat (5) @(negedge v_sync);              // persistence re-scans the held frame
    top_field_first = 0;                       // last shown field was BOTTOM (tff=1 tail);
                                               // tff=0 heads BOTTOM again = the break
    output_frame_valid = 1;
    check_window("2-seek-break");

    // [3] SEEK released on the clean tff (control: alternation intact, no insertion)
    output_frame_valid = 0;
    repeat (4) @(negedge v_sync);
    // tff stays 0: held tail is TOP, new head is BOTTOM — clean junction
    output_frame_valid = 1;
    check_window("3-seek-clean");

    // [4] second alternation-break seek (flip back to tff=1)
    output_frame_valid = 0;
    repeat (3) @(negedge v_sync);
    top_field_first = 1;                       // held tail TOP, head TOP = break again
    output_frame_valid = 1;
    check_window("4-seek-break-2");

    // [5] soft-telecine film: rff=1, tff toggling per picture (authored T,B,T|B,T,B
    // cadence keeps strict alternation) — the corrector must stay silent
    progressive_frame = 1; repeat_first_field = 1; film_mode = 1;
    check_window("5-film-3:2");

    // [8] PERSISTENCE HOLD entered MISALIGNED — a disc-menu STILL (one I-frame, then the
    // reader parks), a pause, or a long decode stall. STATE_REPEAT never returns to
    // STATE_INIT while a frame is held, so the pickup-time corrector is unreachable and a
    // hold that STARTS misaligned stayed misaligned for every held field (measured
    // 360/360 against 0/360 for a hold entered aligned). Real symptom: a disc whose first
    // content after the mount is a 7 s FOX/FBI warning card displays the mount's
    // coin-flip landing — combed under Weave, jittering a line on a CRT — for the whole
    // card, then plays clean, which reads as a disc bug and is not one.
    // ⚠ PLACEMENT IS LOAD-BEARING: the feedback arm needs par_age == PAR_HOLD (120
    // refreshes) and [1] is the only earlier window that spends it, so [1]'s check region
    // plus [2]-[5] (~90 fields) put us past the budget by here. Moved earlier, [8] would
    // sit waiting the budget out instead of measuring, and its runtime would triple.
    progressive_frame = 0; repeat_first_field = 0; film_mode = 0; top_field_first = 1;
    force_misaligned();                   // non-vacuous on BOTH arms, by measurement
    output_frame_valid = 0;               // the reader parks: persistence re-scan only
    hold_heal("8-hold-heal", 170);

    // [9] the hold ends and content resumes — the no-regression guard on the insertion:
    // the schedule and last_image must survive it, and alt_break must not thrash on the
    // resume (which is why the correction swaps the held PAIR rather than emitting one
    // field: the tail parity flips, so a tff=1 head lands aligned by itself).
    // ⚠ [9] PASSES PRE-FIX — the error has held all through the hold, so the pickup arm
    // heals it at the first pickup. [8] is the RED; do not mistake this window for it.
    output_frame_valid = 1;
    check_window("9-post-hold");

    // self-check the measurement itself: a field can only ever head on source line 0
    // or 1, so exactly two stamps may appear and they must be adjacent. Anything else
    // means the line stamp is not identifying lines and no verdict above is meaningful.
    // [6] STUTTER: brief framestore stalls. Each starved raster field displays nothing
    // and shifts every following content field one slot, so the raster phase flips for
    // real — but the corrector must not chase that at field rate, because its cure is a
    // repeated field and several of those a second is a far worse picture than the
    // half-line offset it removes. This is the shipped corrector's HW failure mode.
    progressive_frame = 0; repeat_first_field = 0; film_mode = 0; top_field_first = 1;
    stutter(4);
    check_window_s("7-post-stutter", SETTLE_FB, SETTLE_FB); // the feedback arm heals the rest

    $display("(source line 0 stamps %0d, line 1 stamps %0d; %0d fields measured)",
             base_code, peak_code, fld_n);
    if (fld_n < 4*(SETTLE+NCHK) || peak_code != base_code + 8'd1)
      $fatal(1, "==== BENCH BROKEN (+phase=%0d): %0d fields, stamps %0d/%0d (expected two adjacent) ====",
             phase, fld_n, base_code, peak_code);
    if (errors == 0) begin
      $display("==== PASS (+phase=%0d): every window interleaves field to field and lands on the matching raster parity; worst settle window %0d repeat(s), %0d misaligned ====",
               phase, settle_worst_same, settle_worst_mis);
      $finish;
    end else
      $fatal(1, "==== FAIL (+phase=%0d): %0d window(s) violated the field-phase invariants ====",
             phase, errors);
  end

  // global watchdog: the raster must keep producing fields
  initial begin
    #400_000_000;  // 400 ms sim time
    $fatal(1, "TIMEOUT: field flow stalled (fields=%0d)", fld_n);
  end

endmodule
