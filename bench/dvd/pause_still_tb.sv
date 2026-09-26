// pause_still_tb.sv — gate for the PAUSE FIELD STILL (2026-09-18,
// docs/field_parity.md "Pause shows one field").
//
// THE DEFECT: on the field path (Video Output = Interlaced — the CRT, and HDMI 480i
// under ascal Bob) a pause re-scans the held picture's own two fields forever,
// T,B,T,B… For a TRUE-INTERLACED picture (progressive_frame=0) those fields are two
// instants 1/59.94 s apart, so the paused picture flickered between them at 30 Hz.
// THE FIX: both raster slots show ONE source field — its own slot natively, the other
// slot as a half-line interpolation of it (resample_addrgen pins the field and emits
// H+1 lines with one end duplicated; disp_vscale's HALF mode averages each line with
// the one before).
//
// WHAT IS MEASURED (never a signal the fix names): the real chain — resample (addrgen
// + dta + bilinear) -> disp_vscale -> disp_hstretch -> pixel_queue -> mixer <- sync_gen
// (interlaced raster) — over a LINE-STAMPED framestore. The memory returns, for every
// read, a luma code derived from the SOURCE line the addrgen was on:
//     top-field line 2k      -> 8k
//     bottom-field line 2k+1 -> 8k + 1
// so every displayed line says which source line(s) it came from, and each output line
// is checked for EQUALITY against the value its source position and 2-tap weight give. The bench scores each SCAN the disp_hstretch
// stage emits (what the pixel queue, and so the screen, receives) against the exact
// sequence a field still must show, and counts lines and pixels per line so an H+1 or
// H-1 emission cannot pass.
//
// Arms (one run each; the runner sequences them):
//   default       true-interlaced picture (pfr=0): native before the pause, a steady
//                 STILL of the pinned field while paused (including across a frame
//                 STEP), native again after resume.
//   +pin=0/1      which field is on screen when the pause lands (0 top, 1 bottom) —
//                 the two interpolation shapes (repeat-last vs repeat-first) differ.
//   +lb=1         the same under Letterbox (Analog Aspect = Letterbox, or Auto on 16:9):
//                 disp_vscale's 3/4 blend, the interpolated slot's phase half a line on.
//   +pfr=1        CONTROL: a progressive/film picture keeps the woven still (both
//                 fields natively) — the feature must not touch it.
//   +still_en=0   RED: the feature disabled = the pre-fix addrgen behaviour. The
//                 still phase must FAIL (the paused scans alternate native T/B).
//
// Build/run: bench/dvd/run_pause_still.sh
`timescale 1ns/1ps
module pause_still_tb;

  // ---- geometry: 128x32, mb_height 2, H = 16 lines per field. 128 wide so ONE FIELD
  // (2048 px) overfills the 1024-deep pixel queue: the buffered path then really does back
  // up behind the raster, which is the only way a scan can arrive while the previous one is
  // still draining (the reorder hazard mutation M5 removes the guard for; at 64 wide the
  // field fit the queue exactly and M5 passed). Kept short on purpose:
  // lines are STEP = 8 codes apart, which is what lets every sixth-of-a-line weight land on
  // a distinct value (at 4 codes apart weights 43 and 85 both round to +1 and a wrong
  // weight table passed — mutation M8), and the codes stay below 128 (8*15+1), so
  // display = code+128 never wraps. ----
  localparam [7:0]  MB_WIDTH   = 8'd8;
  localparam [13:0] HSIZE      = 14'd128;
  localparam [7:0]  MB_HEIGHT  = 8'd2;
  localparam [13:0] VSIZE      = 14'd32;
  localparam integer H         = 16;       // field lines
  localparam integer STEP      = 8;        // codes between adjacent lines of a field
  localparam integer LINE_PX   = 128;

  reg [11:0] H_RES = 12'd128, H_SS = 12'd134, H_SE = 12'd142, H_LEN = 12'd148;
  reg [11:0] V_RES = 12'd72,  V_SS = 12'd80,  V_SE = 12'd83,  V_LEN = 12'd90;

  reg clk = 0;     always #5  clk = ~clk;
  reg dot_clk = 0; always #10 dot_clk = ~dot_clk;
  reg rst = 0;

  integer pfr = 0, pin = 0, still_en_i = 1, lb = 0;
  reg        progressive_frame = 1'b0;
  reg        top_field_first   = 1'b1;
  reg  [2:0] output_frame = 3'd2;
  reg        output_frame_valid = 1'b0;
  wire       output_frame_rd;
  reg        pause = 1'b0;
  reg        step_req = 1'b0;
  reg        still_en = 1'b1;

  wire        disp_wr_addr_full, disp_wr_addr_almost_full, disp_wr_addr_en, disp_wr_addr_ack;
  wire [21:0] disp_wr_addr;
  wire        disp_rd_dta_empty, disp_rd_dta_almost_empty, disp_rd_dta_en, disp_rd_dta_valid;
  wire [63:0] disp_rd_dta;
  wire [7:0]  px_y, px_u, px_v, px_osd;
  wire [2:0]  px_position;
  wire        px_wr_en, px_wr_almost_full;
  wire        scan_start, scan_half;

  resample resample (
    .clk(clk), .rst(rst),
    .output_frame(output_frame), .output_frame_valid(output_frame_valid),
    .output_frame_rd(output_frame_rd),
    .progressive_sequence(1'b0), .progressive_frame(progressive_frame), .informative(1'b1),
    .top_field_first(top_field_first), .repeat_first_field(1'b0),
    .mb_width(MB_WIDTH), .mb_height(MB_HEIGHT),
    .horizontal_size(HSIZE), .vertical_size(VSIZE),
    .resample_wr_overflow(),
    .disp_wr_addr_full(disp_wr_addr_full), .disp_wr_addr_almost_full(disp_wr_addr_almost_full),
    .disp_wr_addr_en(disp_wr_addr_en), .disp_wr_addr_ack(disp_wr_addr_ack), .disp_wr_addr(disp_wr_addr),
    .disp_rd_dta_empty(disp_rd_dta_empty), .disp_rd_dta_en(disp_rd_dta_en),
    .disp_rd_dta_valid(disp_rd_dta_valid), .disp_rd_dta(disp_rd_dta),
    .pixel_wr_almost_full(px_wr_almost_full),
    .interlaced(1'b1), .deinterlace(1'b0), .persistence(1'b1), .repeat_frame(5'd0),
    .y(px_y), .u(px_u), .v(px_v), .osd_out(px_osd),
    .position_out(px_position), .pixel_wr_en(px_wr_en),
    .video_live(), .pickup_hold(1'b0), .pause(pause), .step_req(step_req),
    .raster_par_err(1'b0), .vscale_mode(2'd0), .hcrop_en(1'b0),
    .sched_due(1'b1), .sched_next_due(1'b1),
    .still_en(still_en), .blend_en(1'b0), .bob_en(1'b0), .scan_start(scan_start), .scan_half(scan_half)
  );

  wire [7:0] vs_y, vs_u, vs_v, vs_osd;
  wire [2:0] vs_pos;
  wire       vs_wr, hs_in_almost_full;
  disp_vscale disp_vscale (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .vscale_en(lb != 0), .scan_start(scan_start), .scan_half(scan_half),
    .in_y(px_y), .in_u(px_u), .in_v(px_v), .in_osd(px_osd),
    .in_pos(px_position), .in_wr(px_wr_en), .in_almost_full(px_wr_almost_full),
    .out_y(vs_y), .out_u(vs_u), .out_v(vs_v), .out_osd(vs_osd),
    .out_pos(vs_pos), .out_wr(vs_wr), .out_almost_full(hs_in_almost_full)
  );

  wire [7:0] hs_y, hs_u, hs_v, hs_osd;
  wire [2:0] hs_pos;
  wire       hs_wr, pq_wr_almost_full;
  disp_hstretch disp_hstretch (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .hcrop_en(1'b0), .hsrc_width(12'd128), .hdst_width(12'd128),
    .in_y(vs_y), .in_u(vs_u), .in_v(vs_v), .in_osd(vs_osd),
    .in_pos(vs_pos), .in_wr(vs_wr), .in_almost_full(hs_in_almost_full),
    .out_y(hs_y), .out_u(hs_u), .out_v(hs_v), .out_osd(hs_osd),
    .out_pos(hs_pos), .out_wr(hs_wr), .out_almost_full(pq_wr_almost_full)
  );

  // ---- framestore reader + line-stamped behavioural memory ----
  wire        rd_addr_empty, rd_addr_valid;
  wire [21:0] rd_addr;
  reg         rd_addr_en;
  wire        wr_dta_full, wr_dta_almost_full, wr_dta_ack, wr_dta_overflow;
  reg         wr_dta_en;
  reg  [63:0] wr_dta;
  framestore_reader #(.fifo_addr_depth(9'd8), .fifo_dta_depth(9'd8),
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
    .wr_dta(wr_dta)
  );

  // side FIFO mirroring the in-order read stream: the source line PAIRED with each
  // request as the addrgen issues it (disp_delta_y at disp_valid_in — each request
  // becomes exactly one address, served in order). Sampling disp_y at the address FIFO
  // instead is late by the mem_addr pipeline and drifts across line boundaries.
  localparam SFD = 8192;
  reg  [11:0] sfifo [0:SFD-1];
  integer s_head = 0, s_tail = 0;
  reg  [11:0] popped_line = 12'd0;
  always @(posedge clk) if (rst) begin
    if (resample.resample_addrgen.disp_valid_in) begin
      sfifo[s_tail] <= resample.resample_addrgen.disp_delta_y[11:0];
      s_tail <= (s_tail == SFD-1) ? 0 : s_tail + 1;
    end
    if (rd_addr_en && ~rd_addr_empty) begin
      popped_line <= sfifo[s_head];
      s_head <= (s_head == SFD-1) ? 0 : s_head + 1;
    end
  end
  // code: top line 2k -> 8k, bottom line 2k+1 -> 8k+1
  wire [7:0] line_code = {1'b0, popped_line[4:1], 2'b00, popped_line[0]};   // 8k / 8k+1
  always @* rd_addr_en = ~rd_addr_empty && ~wr_dta_almost_full;
  always @(posedge clk)
    if (~rst) begin wr_dta_en <= 1'b0; wr_dta <= 64'h0; end
    else begin
      wr_dta_en <= rd_addr_valid;
      wr_dta    <= {8{line_code}};
    end

  // ---- pixel queue, raster, mixer (real pacing / backpressure) ----
  wire [7:0] mx_y, mx_u, mx_v, mx_osd;
  wire [2:0] mx_position;
  wire       mx_rd_en, mx_rd_empty, mx_rd_valid, mx_rd_underflow;
  wire [11:0] h_pos, v_pos;
  wire        h_sync, v_sync, pixel_en;
  pixel_queue pixel_queue (
    .clk_in(clk), .clk_in_en(1'b1), .rst(rst),
    .y_in(hs_y), .u_in(hs_u), .v_in(hs_v), .osd_in(hs_osd), .position_in(hs_pos),
    .pixel_wr_en(hs_wr), .pixel_wr_almost_full(pq_wr_almost_full),
    .pixel_wr_full(), .pixel_wr_overflow(),
    .clk_out(dot_clk), .clk_out_en(1'b1),
    .y_out(mx_y), .u_out(mx_u), .v_out(mx_v), .osd_out(mx_osd), .position_out(mx_position),
    .pixel_rd_en(mx_rd_en), .pixel_rd_empty(mx_rd_empty),
    .pixel_rd_valid(mx_rd_valid), .pixel_rd_underflow(mx_rd_underflow)
  );
  sync_gen sync_gen (
    .clk(dot_clk), .clk_en(1'b1), .rst(rst),
    .horizontal_size(HSIZE), .vertical_size(VSIZE),
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
    .clk(dot_clk), .clk_en(1'b1), .rst(rst), .hard_rst(rst),
    .pixel_repetition(1'b0),
    .y_in(mx_y), .u_in(mx_u), .v_in(mx_v), .osd_in(mx_osd), .position_in(mx_position),
    .pixel_rd_en(mx_rd_en), .pixel_rd_valid(mx_rd_valid), .pixel_rd_underflow(mx_rd_underflow),
    .h_pos(h_pos), .v_pos(v_pos), .h_sync_in(h_sync), .v_sync_in(v_sync), .pixel_en_in(pixel_en),
    .y_out(), .u_out(), .v_out(), .osd_out(),
    .h_sync_out(), .v_sync_out(), .pixel_en_out(),
    .disp_v_offset(12'd0)
  );

  // ====================================================================
  // Scan scoring at the disp_hstretch output (= what the pixel queue receives)
  // ====================================================================
  localparam [2:0] ROW_0_COL_0 = 3'b000, ROW_1_COL_0 = 3'b001, ROW_X_COL_0 = 3'b010;
  localparam integer P_IGNORE = 0, P_NATIVE = 1, P_STILL = 2;

  integer phase = P_IGNORE;
  integer skip  = 0;            // scans to ignore after a phase change (in flight)
  integer scans_total = 0;
  integer ph_scans = 0, ph_pass = 0;
  integer cur_slot = -1, cur_n = 0, cur_px = 0, cur_bad_px = 0;
  integer cur_line_y = 0;
  reg [7:0] vals [0:127];
  integer ok_scans_native_pre = 0, ok_scans_still = 0, ok_scans_step = 0, ok_scans_native_post = 0;
  integer errors = 0;
  integer verbose = 0;
  integer first_fail_reported = 0;

  function integer disp_of(input integer code); disp_of = (code + 128) & 255; endfunction
  function integer is_off(input integer ph, input integer slot);
    is_off = (ph == P_STILL) && (slot != pin);
  endfunction
  // The INPUT line sequence disp_vscale receives for a scan (display values).
  function integer in_val(input integer ph, input integer slot, input integer i);
    integer ii;
    begin
      if (is_off(ph, slot)) begin
        // the interpolated slot: the pinned field, one end duplicated (H+1 lines)
        if (pin == 0) in_val = disp_of(STEP * ((i > H-1) ? H-1 : i));
        else          in_val = disp_of(STEP * ((i < 1) ? 0 : i-1) + 1);
      end else begin
        ii = (i > H-1) ? H-1 : i;
        in_val = disp_of(STEP*ii + ((ph == P_STILL) ? pin : slot));
      end
    end
  endfunction
  // disp_vscale's 2-tap blend, as specified: a + ((b-a)*f + 128) >>> 8
  function integer blend(input integer a, input integer b, input integer f);
    integer d;
    begin d = (b - a) * f + 128; blend = a + ((d >= 0) ? (d / 256) : -((-d + 255) / 256)); end
  endfunction
  // Output line j sits at a source position, in SIXTHS of an input line:
  //   Fit: j (6j),  Letterbox: 4j/3 (8j);  the interpolated slot adds half a line (+3).
  function integer exp_line(input integer ph, input integer slot, input integer j);
    integer q6, k, r, f;
    begin
      q6 = (lb ? 8*j : 6*j) + (is_off(ph, slot) ? 3 : 0);
      k = q6 / 6; r = q6 % 6;
      f = (r == 0) ? 0 : (r == 1) ? 43 : (r == 2) ? 85 : (r == 3) ? 128 : (r == 4) ? 171 : 213;
      exp_line = (r == 0) ? in_val(ph, slot, k) : blend(in_val(ph, slot, k), in_val(ph, slot, k+1), f);
    end
  endfunction
  function integer exp_lines(input integer dummy); exp_lines = lb ? (3*H)/4 : H; endfunction

  task finish_scan;
    integer k, good;
    begin
      if (cur_slot >= 0) begin
        scans_total = scans_total + 1;
        if (cur_px != LINE_PX) cur_bad_px = cur_bad_px + 1;    // last line
        if (phase != P_IGNORE && skip > 0) skip = skip - 1;
        else if (phase != P_IGNORE) begin
          good = (cur_n == exp_lines(0)) && (cur_bad_px == 0);
          for (k = 0; k < exp_lines(0) && k < cur_n; k = k + 1)
            if (vals[k] != exp_line(phase, cur_slot, k)) good = 0;
          ph_scans = ph_scans + 1;
          if (good) ph_pass = ph_pass + 1;
          if (verbose || (!good && first_fail_reported < 3)) begin
            if (!good) first_fail_reported = first_fail_reported + 1;
            $display("  scan %0d slot=%s lines=%0d badpx=%0d  L0=%0d L1=%0d L2=%0d Llast=%0d  exp %0d %0d %0d %0d  %s",
                     scans_total, cur_slot ? "BOT" : "TOP", cur_n, cur_bad_px,
                     vals[0], vals[1], vals[2], vals[(cur_n > 0) ? cur_n-1 : 0],
                     exp_line(phase, cur_slot, 0), exp_line(phase, cur_slot, 1),
                     exp_line(phase, cur_slot, 2), exp_line(phase, cur_slot, exp_lines(0)-1),
                     good ? "ok" : "MISMATCH");
          end
        end
      end
    end
  endtask

  always @(posedge clk) if (rst && hs_wr) begin
    if (hs_pos == ROW_0_COL_0 || hs_pos == ROW_1_COL_0) begin
      finish_scan;
      cur_slot = (hs_pos == ROW_1_COL_0);
      cur_n = 0; cur_px = 0; cur_bad_px = 0;
    end
    if (hs_pos == ROW_0_COL_0 || hs_pos == ROW_1_COL_0 || hs_pos == ROW_X_COL_0) begin
      if (cur_n > 0 && cur_px != LINE_PX) cur_bad_px = cur_bad_px + 1;
      if (cur_n < 128) vals[cur_n] = hs_y;
      cur_n = cur_n + 1; cur_px = 0;
    end
    cur_px = cur_px + 1;
  end

  task run_phase(input integer ph, input integer nskip, input integer nscore, output integer npass);
    begin
      phase = ph; skip = nskip; ph_scans = 0; ph_pass = 0;
      wait (ph_scans >= nscore);
      npass = ph_pass;
      phase = P_IGNORE;
    end
  endtask

  integer pickups = 0;
  always @(posedge clk) if (rst && output_frame_rd) pickups = pickups + 1;

  // present one picture and withdraw it once it is consumed
  task present_one;
    integer p0;
    begin
      p0 = pickups;
      @(negedge clk) output_frame_valid = 1'b1;
      wait (pickups > p0);
      @(negedge clk) output_frame_valid = 1'b0;
    end
  endtask

  localparam integer NSCORE = 8;
  integer n_pre, n_still, n_step, n_post, want_still_pass;
  integer p_before_step;
  localparam [1:0] TOP_I = 2'd2, BOT_I = 2'd3;
  initial begin
    void'($value$plusargs("pfr=%d", pfr));
    void'($value$plusargs("pin=%d", pin));
    void'($value$plusargs("still_en=%d", still_en_i));
    void'($value$plusargs("verbose=%d", verbose));
    void'($value$plusargs("lb=%d", lb));
    progressive_frame = pfr[0];
    still_en = still_en_i[0];
    $display("==== pause_still_tb  pfr=%0d pin=%0d still_en=%0d lb=%0d ====", pfr, pin, still_en_i, lb);

    repeat (8) @(posedge clk); rst = 1; repeat (8) @(posedge clk);

    // prime: a few pictures, then hold (persistence alternates the held pair)
    repeat (3) present_one;
    run_phase(P_NATIVE, 3, NSCORE, n_pre);
    $display("  [pre]   native before pause      : %0d/%0d scans", n_pre, NSCORE);

    // pause while the addrgen is scanning the field we want on screen, so the pin
    // lands on it (the lock pins last_image at the next scan start)
    wait (resample.resample_addrgen.state == 4'h7 &&
          resample.resample_addrgen.image == (pin ? BOT_I : TOP_I));
    @(negedge clk) pause = 1'b1;
    // a film/progressive picture keeps its weave: expect NATIVE; else the still
    run_phase(pfr ? P_NATIVE : P_STILL, 3, NSCORE, n_still);
    $display("  [pause] %s        : %0d/%0d scans", pfr ? "woven still (control)" : "field still          ",
             n_still, NSCORE);

    // frame step while paused: one new picture, then the still again
    p_before_step = pickups;
    fork
      present_one;
      begin @(negedge clk) step_req = 1'b1; @(negedge clk) step_req = 1'b0; end
    join
    run_phase(pfr ? P_NATIVE : P_STILL, 3, NSCORE, n_step);
    $display("  [step]  after a frame step       : %0d/%0d scans (pickups +%0d)",
             n_step, NSCORE, pickups - p_before_step);
    if (pickups - p_before_step != 1) begin
      $display("  FAIL: the step took %0d pictures, want exactly 1", pickups - p_before_step);
      errors = errors + 1;
    end

    // resume
    @(negedge clk) pause = 1'b0;
    present_one;
    run_phase(P_NATIVE, 3, NSCORE, n_post);
    $display("  [post]  native after resume      : %0d/%0d scans", n_post, NSCORE);

    if (n_pre  != NSCORE) begin $display("  FAIL [pre]");   errors = errors + 1; end
    if (n_still != NSCORE) begin $display("  FAIL [pause]"); errors = errors + 1; end
    if (n_step != NSCORE) begin $display("  FAIL [step]");  errors = errors + 1; end
    if (n_post != NSCORE) begin $display("  FAIL [post]");  errors = errors + 1; end
    if (errors == 0) $display("RESULT: PASS");
    else begin $display("RESULT: FAIL (%0d)", errors); $fatal(1, "pause_still_tb failed"); end
    $finish;
  end

  initial begin
    #400_000_000;
    $display("RESULT: FAIL (timeout; scans_total=%0d phase=%0d ph_scans=%0d)", scans_total, phase, ph_scans);
    $fatal(1, "timeout");
  end
endmodule
