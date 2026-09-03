`timescale 1ns/1ps
//
// field_parity_tb.sv — prove (and then guard) the FIELD-PARITY RE-ENGAGE defect
// and its corrector (docs/field_parity.md).
//
// THE DEFECT (field reports, 2026-09-02: "super aliased after chapter skip /
// FF / aspect change, fix by toggling the output mode 3-4 times"): on an
// interlaced display the mixer consumes one field image per raster field, and
// its frame-top matcher deliberately accepts EITHER parity slot (mixer.v
// display_first_pixel — the 3:2/drop "black fields" fix). The emitted field
// sequence normally alternates TOP/BOTTOM, so content parity and raster parity
// stay locked — but ONE odd perturbation (a seek released on an arbitrary tff,
// a raster restart, cold-start luck) flips the phase PERMANENTLY: every TOP
// image scans out during a bottom raster field and vice versa. Toggling the
// output mode merely re-rolls the coin.
//
// THE CHAIN UNDER TEST is the real display path: resample (addrgen + dta +
// bilinear) -> framestore_reader + behavioural memory -> pixel_queue ->
// mixer <- sync_gen (interlaced raster). disp_vscale/disp_hstretch are
// bypassed pass-throughs in this scenario and are left out of the build.
//
// THE CHECK reads the wire the defect lives on, hierarchically into the
// UNMODIFIED mixer: at every accepted frame-top (STATE_WAIT ->
// STATE_FIRST_PIXEL with a ROW_0/ROW_1 head) the content field type
// (position_in_0) must match the raster field parity (v_pos 0 = top field
// line 0, v_pos 1 = bottom field line 1). A register-peek of the corrector
// would prove nothing — this asserts what the SCREEN gets.
//
// SCENARIOS (one run; +phase=0 / +phase=1 shifts the cold-start supply by one
// field period so BOTH landing parities are exercised across the two runs):
//   [1] cold start          — feedback-path case: nothing schedule-visible is
//                             wrong, but one +phase arm lands misaligned.
//   [2] seek released on a SAME-parity tff (alternation break) — feed-forward
//                             case; the classic chapter-skip coin flip.
//   [3] seek released on the OPPOSITE (clean) tff — control, must not insert.
//   [4] second alternation-break seek (flip back).
//   [5] soft-telecine film (rff=1, tff toggling per picture, the authored
//                             T,B,T | B,T,B cadence) — alternation is intact
//                             by authoring; the corrector must stay silent.
// After each perturbation a settle window of SETTLE frame-tops absorbs the
// (bounded) correction latency; the CHECK window after it requires EVERY
// frame-top aligned. PRE-FIX EXPECTATION (build with -DNO_PARITY_FIX against
// the pre-fix RTL): each +phase arm fails at least one window — a
// misalignment, once entered, PERSISTS (that is the proven coin flip).
// POST-FIX: all windows pass in both arms, and the settle windows observe at
// most 2 misaligned tops each (the feedback latency bound).
//
// Build (GREEN, current RTL):
//   iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/field_parity_sim \
//     rtl/mpeg2/resample.v dvd/resample_addrgen.v rtl/mpeg2/resample_dta.v \
//     rtl/mpeg2/resample_bilinear.v rtl/mpeg2/mem_addr.v rtl/mpeg2/mixer.v \
//     rtl/mpeg2/pixel_queue.v rtl/mpeg2/syncgen.v rtl/mpeg2/read_write.v \
//     rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v rtl/mpeg2/xilinx_fifo_dc.v \
//     rtl/mpeg2/xfifo_sc.v bench/dvd/field_parity_tb.sv
//   vvp bench/dvd/field_parity_sim +phase=0
//   vvp bench/dvd/field_parity_sim +phase=1
// Or: bash bench/dvd/run_field_parity.sh
// (RED capture: same build with -DNO_PARITY_FIX against the pre-fix
//  resample.v/resample_addrgen.v/mixer.v — see run_field_parity.sh --red.)
//
module field_parity_tb;

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
    .wr_dta(64'h4040_4040_4040_4040)
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
  // The parity check — hierarchical into the (unmodified) mixer: every
  // accepted frame-top's content field type vs the raster field parity.
  // ====================================================================
  wire ft_evt     = (mixer.state == mixer.STATE_WAIT) &&
                    (mixer.next  == mixer.STATE_FIRST_PIXEL) &&
                    mixer.is_frame_top;
  wire ft_aligned = (mixer.position_in_0 == ROW_0_COL_0) ? (v_pos == 12'd0)
                                                         : (v_pos == 12'd1);

  integer ft_seen = 0;
  integer mis_seen = 0;        // misaligned tops inside the current CHECK window
  integer settle_mis = 0;      // misaligned tops inside the current SETTLE window
  reg     checking = 0, settling = 0;
  always @(posedge dot_clk)
    if (rst && ft_evt) begin
      ft_seen = ft_seen + 1;
      if (!ft_aligned) begin
        if (checking) begin
          mis_seen = mis_seen + 1;
          $display("  [%0t] MISALIGNED frame-top in CHECK window: %s field at v_pos=%0d",
                   $time, (mixer.position_in_0 == ROW_0_COL_0) ? "TOP" : "BOTTOM", v_pos);
        end
        if (settling) settle_mis = settle_mis + 1;
      end
    end

  task wait_fts(input integer n);
    integer t0;
    begin t0 = ft_seen; wait (ft_seen >= t0 + n); @(posedge dot_clk); end
  endtask

  localparam SETTLE    = 6;    // frame-tops allowed for a FEED-FORWARD correction to land
  /* The FEEDBACK arm waits for the mixer's verdict to hold across PAR_CONFIRM refreshes
   * before it inserts (dvd/resample_addrgen.v — the issue #41 fix: its cure costs a
   * repeated field, so it must not chase a churning error). The windows that exercise it
   * therefore need a settle window that long. */
  localparam SETTLE_FB = 40;
  localparam NCHK      = 16;   // frame-tops that must ALL be aligned after it
  integer errors = 0;
  integer settle_worst = 0;

  task check_window_s(input [8*40-1:0] name, input integer settle);
    begin
      settling = 1; settle_mis = 0;
      wait_fts(settle);
      settling = 0;
      if (settle_mis > settle_worst) settle_worst = settle_mis;
      checking = 1; mis_seen = 0;
      wait_fts(NCHK);
      checking = 0;
      if (mis_seen == 0)
        $display("[%0s] PASS: %0d/%0d frame-tops aligned (settle saw %0d misaligned)",
                 name, NCHK, NCHK, settle_mis);
      else begin
        errors = errors + 1;
        $display("[%0s] FAIL: %0d of %0d frame-tops MISALIGNED (settle saw %0d)",
                 name, mis_seen, NCHK, settle_mis);
      end
    end
  endtask

  task check_window(input [8*40-1:0] name);
    begin check_window_s(name, SETTLE); end
  endtask

  integer phase = 0;

  initial begin
    void'($value$plusargs("phase=%d", phase));
    $display("\n==== field_parity_tb  +phase=%0d ====", phase);

    rst = 0; output_frame_valid = 0;
    repeat (8) @(posedge clk);
    rst = 1;

    // [1] COLD START at the +phase-selected raster field parity (feedback case)
    repeat (2) @(negedge v_sync);
    repeat (phase) @(negedge v_sync);          // one field period shifts landing parity
    output_frame_valid = 1;
    check_window_s("1-cold-start", SETTLE_FB);   // the feedback arm's window

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
      $display("\n==== PASS (+phase=%0d): all windows aligned; worst settle window saw %0d misaligned top(s) ====",
               phase, settle_worst);
      $finish;
    end else
      $fatal(1, "==== FAIL (+phase=%0d): %0d window(s) with persistent misalignment ====",
             phase, errors);
  end

  // global watchdog: the raster must keep producing frame-tops
  initial begin
    #400_000_000;  // 400 ms sim time
    $fatal(1, "TIMEOUT: frame-top flow stalled (ft_seen=%0d)", ft_seen);
  end

endmodule
