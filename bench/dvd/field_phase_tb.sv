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
 * a field line. This bench measures exactly that, in RTL, with no reference to the
 * corrector's own idea of correctness:
 *
 *   - the framestore returns ADDRESS-DERIVED data, so every displayed pixel identifies
 *     the memory word it came from;
 *   - each displayed field is reduced to a hash of the data the mixer actually emitted;
 *   - INVARIANT A: consecutive displayed fields must DIFFER (they must not sample the
 *     same source lines) — this is what the HW defect violates;
 *   - INVARIANT B: over a steady window the hashes must repeat with period 2 (field N
 *     and field N+2 show the same lines), i.e. the display alternates cleanly.
 *
 * A field that is a deliberate REPEAT of its predecessor (the corrector inserting one
 * field to re-align a cadence break, or the governor holding a frame) legitimately
 * violates A once. So the check is windowed: at most ONE repeat may occur inside a
 * settle window, and NONE inside the check window that follows.
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
 *   vvp bench/dvd/field_phase_sim
 * Or: bash bench/dvd/run_field_phase.sh
 */
module field_phase_tb;

`include "resample_codes.v"

  // ---- narrow/fast interlaced geometry (resample_chain_tb's narrow modeline,
  //      il variant: content 64x256 -> 128-line fields) ----
  localparam [7:0]  MB_WIDTH        = 8'd4;
  localparam [7:0]  MB_HEIGHT       = 8'd16;
  localparam [13:0] HORIZONTAL_SIZE = 14'd64;
  localparam [13:0] VERTICAL_SIZE   = 14'd256;
  localparam [11:0] H_RES = 12'd64,  H_SS = 12'd70,  H_SE = 12'd78,  H_LEN = 12'd84;
  // Shortened vertical raster (content-woven 256 lines + small blanking) — the
  // resample_chain_tb narrow modeline's 505-line vertical made a full 5-window run
  // take ~10 min of wall time for no extra coverage; v_sync verified toggling and
  // all windows behave identically at this height.
  localparam [11:0] V_RES = 12'd260, V_SS = 12'd268, V_SE = 12'd271, V_LEN = 12'd280;

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

  // framestore_reader + full-rate behavioural memory (constant non-black word)
  wire        rd_addr_empty, rd_addr_valid;
  wire [21:0] rd_addr;
  wire        wr_dta_full, wr_dta_almost_full, wr_dta_ack, wr_dta_overflow;
  reg         wr_dta_en;
  wire        rd_addr_en = ~rd_addr_empty && ~wr_dta_almost_full;
  reg [21:0] rd_addr_q;
  always @(posedge clk) rd_addr_q <= rd_addr;
  wire [7:0] addr_code = rd_addr_q[7:0] ^ rd_addr_q[15:8] ^ {2'b0, rd_addr_q[21:16]};
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
    // ADDRESS-DERIVED content: every returned word identifies the memory word it came
    // from, so a displayed pixel says which source line produced it. (field_parity_tb
    // returns a constant here, which is why it cannot see a content-phase error.)
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
  // CONTENT-PHASE CHECK. Hash what the mixer actually emitted for each displayed
  // field, then compare consecutive fields. No reference to the corrector's own
  // notion of parity — this is the RTL equivalent of measuring a screenshot.
  // ====================================================================
  wire ft_evt     = (mixer.state == mixer.STATE_WAIT) &&
                    (mixer.next  == mixer.STATE_FIRST_PIXEL) &&
                    mixer.is_frame_top;

  integer ft_seen = 0;
  always @(posedge dot_clk) if (rst && ft_evt) ft_seen = ft_seen + 1;

  // Per-field hash of the emitted luma, closed at each vsync (one field per vsync).
  reg  [31:0] fld_hash = 0;
  reg  [31:0] h_prev = 32'hFFFF_FFFF, h_prev2 = 32'hFFFF_FFFF;
  reg         vs_q = 0;
  integer     fld_n = 0;
  integer     same_run = 0;      // consecutive-field repeats seen in the active window
  integer     alt_bad  = 0;      // period-2 violations seen in the active window
  reg         checking = 0, settling = 0;
  integer     settle_same = 0;

  always @(posedge dot_clk) if (rst) begin
    vs_q <= v_sync;
    if (pixel_en_out) fld_hash <= {fld_hash[30:0], fld_hash[31]} ^ {24'd0, y_out};
    if (v_sync && !vs_q) begin                       // field boundary
      if (fld_hash != 32'd0) begin                   // a field with content
        fld_n = fld_n + 1;
        if (fld_n > 1) begin
          if (fld_hash == h_prev) begin              // INVARIANT A
            if (checking) begin
              same_run = same_run + 1;
              $display("  [%0t] field %0d REPEATS field %0d (hash %08x) - both fields carry the same source lines",
                       $time, fld_n, fld_n-1, fld_hash);
            end
            if (settling) settle_same = settle_same + 1;
          end
          if (fld_n > 2 && checking && (fld_hash != h_prev2) && (fld_hash != h_prev))
            alt_bad = alt_bad + 1;                   // INVARIANT B (period 2)
        end
        h_prev2 <= h_prev;
        h_prev  <= fld_hash;
      end
      fld_hash <= 0;
    end
  end

  task wait_flds(input integer n);
    integer t0;
    begin t0 = fld_n; wait (fld_n >= t0 + n); @(posedge dot_clk); end
  endtask

  task wait_fts(input integer n);
    integer t0;
    begin t0 = ft_seen; wait (ft_seen >= t0 + n); @(posedge dot_clk); end
  endtask

  localparam SETTLE = 8;       // fields allowed for any correction/insertion to land
  localparam NCHK   = 16;      // fields that must all carry alternating content after it
  integer errors = 0;
  integer settle_worst = 0;

  task check_window(input [8*40-1:0] name);
    begin
      settling = 1; settle_same = 0;
      wait_flds(SETTLE);
      settling = 0;
      if (settle_same > settle_worst) settle_worst = settle_same;
      checking = 1; same_run = 0; alt_bad = 0;
      wait_flds(NCHK);
      checking = 0;
      if (same_run == 0 && alt_bad == 0)
        $display("[%0s] PASS: %0d fields, every one carries different lines from its neighbour (period-2 clean; settle saw %0d repeat(s))",
                 name, NCHK, settle_same);
      else begin
        errors = errors + 1;
        $display("[%0s] FAIL: %0d consecutive-field REPEAT(s) and %0d period-2 break(s) in %0d fields (settle saw %0d)",
                 name, same_run, alt_bad, NCHK, settle_same);
      end
    end
  endtask

  integer phase = 0;

  initial begin
    void'($value$plusargs("phase=%d", phase));
    $display("\n==== field_phase_tb  +phase=%0d ====", phase);

    rst = 0; output_frame_valid = 0;
    repeat (8) @(posedge clk);
    rst = 1;

    // [1] COLD START at the +phase-selected raster field parity (feedback case)
    repeat (2) @(negedge v_sync);
    repeat (phase) @(negedge v_sync);          // one field period shifts landing parity
    output_frame_valid = 1;
    check_window("1-cold-start");

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

    if (errors == 0) begin
      $display("\n==== PASS (+phase=%0d): every window alternates content field to field; worst settle window saw %0d repeat(s) ====",
               phase, settle_worst);
      $finish;
    end else
      $fatal(1, "==== FAIL (+phase=%0d): %0d window(s) where consecutive fields carry the SAME lines ====",
             phase, errors);
  end

  // global watchdog: the raster must keep producing frame-tops
  initial begin
    #400_000_000;  // 400 ms sim time
    $fatal(1, "TIMEOUT: field flow stalled (fields=%0d, frame-tops=%0d)", fld_n, ft_seen);
  end

endmodule
