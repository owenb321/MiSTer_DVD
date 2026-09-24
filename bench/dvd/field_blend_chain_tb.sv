// field_blend_chain_tb.sv -- the FIELD BLEND in the real display chain
// (docs/field_blend.md). Adapted from Stage A's deint_chain_tb.sv
// (feature/deinterlace@a017ec4), which was cloned from pause_still_tb.sv.
//
// WHAT IS MEASURED (never a signal the feature names): the real chain -- resample
// (addrgen + dta + bilinear) -> field_blend -> disp_vscale -> disp_hstretch ->
// pixel_queue -> mixer <- sync_gen (PROGRESSIVE raster) -- over a framestore that
// returns, for every read, a luma code derived from the SOURCE LINE and MACROBLOCK
// the addrgen asked for. The stamp is deliberately NON-LINEAR in the line: on a
// linear ramp [1,2,1] and bob both return the centre value and a kernel mutation
// would go unseen. Every displayed luma pixel is checked for EQUALITY against the
// kernel over the stamps, with the edges mirrored.
//
// This is what proves the addrgen's H+1 emission (and that its extra line is H-2),
// the sideband alignment and the frame-top codes -- none of which a module bench
// can see. Luma only: chroma is addressed from its own plane; the module bench
// (field_blend_tb) is bit-exact on all channels.
//
// Arms (FAIL: [Cn] ids, matched EXACTLY by run_field_blend.sh):
//   [C1]  interior lines equal the kernel       [C1T] top line (a := d)
//   [C1B] bottom line (d := a, the addrgen's H-2 line)
//   [C2]  structure: every scan after warm-up is H lines of LINE_PX, slot 0
//   [C3]  line 1 carries ROW_1_COL_0 (the mixer places a FRAME's line 1 by it)
//   [C4]  +pfr=1 film control: the weave, exactly
//   [C5]  a HELD picture's consecutive scans are byte-identical -- the no-shimmer
//         claim, measured against the previous scan, not against the model
//   [C6]  +mix=1: film scans arriving while a blend scan drains keep order and weave
//   [C7]  +pause=1: a frame step while paused shows the stepped picture blended
//   [C8]  +ilace=1: on the interlaced (fields) arm no scan is ever marked
//   +tff=0  must pass unchanged (nothing here depends on field order)
//   +blend_en=0  RED: the option off = the weave; C1 must fail
`timescale 1ns/1ps
module field_blend_chain_tb;
  localparam [7:0]  MB_WIDTH   = 8'd8;
  localparam [13:0] HSIZE      = 14'd128;
  localparam [7:0]  MB_HEIGHT  = 8'd2;
  localparam [13:0] VSIZE      = 14'd32;
  localparam integer H         = 32;       // frame lines
  localparam integer LINE_PX   = 128;

  reg [11:0] H_RES = 12'd128, H_SS = 12'd134, H_SE = 12'd142, H_LEN = 12'd148;
  reg [11:0] V_RES = 12'd72,  V_SS = 12'd80,  V_SE = 12'd83,  V_LEN = 12'd90;

  reg clk = 0;     always #5  clk = ~clk;
  reg dot_clk = 0; always #10 dot_clk = ~dot_clk;
  reg rst = 0;

  integer pfr = 0, tff = 1, blend_en_i = 1, mix = 0, pause_i = 0, ilace = 0;
  reg        pause = 1'b0;
  reg        step_req = 1'b0;
  reg        progressive_frame = 1'b0;
  reg        top_field_first   = 1'b1;
  reg  [2:0] output_frame = 3'd2;
  reg        output_frame_valid = 1'b0;
  wire       output_frame_rd;
  reg        blend_en = 1'b1;
  reg        ilace_r = 1'b0;

  wire        disp_wr_addr_full, disp_wr_addr_almost_full, disp_wr_addr_en, disp_wr_addr_ack;
  wire [21:0] disp_wr_addr;
  wire        disp_rd_dta_empty, disp_rd_dta_almost_empty, disp_rd_dta_en, disp_rd_dta_valid;
  wire [63:0] disp_rd_dta;
  wire [7:0]  px_y, px_u, px_v, px_osd;
  wire [2:0]  px_position;
  wire        px_wr_en, px_wr_almost_full;
  wire        scan_start, scan_half, scan_blend;

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
    .interlaced(ilace_r), .deinterlace(~ilace_r), .persistence(1'b1), .repeat_frame(5'd0),
    .y(px_y), .u(px_u), .v(px_v), .osd_out(px_osd),
    .position_out(px_position), .pixel_wr_en(px_wr_en),
    .video_live(), .pickup_hold(1'b0), .pause(pause), .step_req(step_req),
    .raster_par_err(1'b0), .vscale_mode(2'd0), .hcrop_en(1'b0),
    .sched_due(1'b1), .sched_next_due(1'b1),
    .still_en(1'b0), .scan_start(scan_start), .scan_half(scan_half),
    .blend_en(blend_en), .scan_blend(scan_blend)
  );

  wire [7:0] fb_y, fb_u, fb_v, fb_osd;
  wire [2:0] fb_pos;
  wire       fb_wr, vs_in_almost_full;
  wire       blend_act;
  field_blend field_blend (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .scan_start(scan_start), .scan_blend(scan_blend),
    .in_y(px_y), .in_u(px_u), .in_v(px_v), .in_osd(px_osd),
    .in_pos(px_position), .in_wr(px_wr_en), .in_almost_full(px_wr_almost_full),
    .out_y(fb_y), .out_u(fb_u), .out_v(fb_v), .out_osd(fb_osd),
    .out_pos(fb_pos), .out_wr(fb_wr), .out_almost_full(vs_in_almost_full),
    .blend_act(blend_act)
  );

  wire [7:0] vs_y, vs_u, vs_v, vs_osd;
  wire [2:0] vs_pos;
  wire       vs_wr, hs_in_almost_full;
  disp_vscale disp_vscale (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .vscale_en(1'b0), .scan_start(scan_start), .scan_half(scan_half),
    .in_y(fb_y), .in_u(fb_u), .in_v(fb_v), .in_osd(fb_osd),
    .in_pos(fb_pos), .in_wr(fb_wr), .in_almost_full(vs_in_almost_full),
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

  // ---- framestore reader + (line, macroblock)-stamped behavioural memory ----
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

  // side FIFO mirroring the in-order read stream: {macroblock, source line} paired
  // with each request as the addrgen issues it
  localparam SFD = 8192;
  reg  [19:0] sfifo [0:SFD-1];
  integer s_head = 0, s_tail = 0;
  reg  [19:0] popped = 20'd0;
  always @(posedge clk) if (rst) begin
    if (resample.resample_addrgen.disp_valid_in) begin
      sfifo[s_tail] <= {resample.resample_addrgen.disp_mb, resample.resample_addrgen.disp_delta_y[11:0]};
      s_tail <= (s_tail == SFD-1) ? 0 : s_tail + 1;
    end
    if (rd_addr_en && ~rd_addr_empty) begin
      popped <= sfifo[s_head];
      s_head <= (s_head == SFD-1) ? 0 : s_head + 1;
    end
  end
  // the stamp: non-linear in the line, varies by macroblock, < 128 so the luma path's
  // +128 never wraps
  function integer stamp(input integer y, input integer m);
    stamp = (3 * y * y + 11 * m + ((y % 2) ? 37 : 0)) % 128;
  endfunction
  wire [7:0] code = stamp(popped[11:0], popped[19:12]);
  always @* rd_addr_en = ~rd_addr_empty && ~wr_dta_almost_full;
  always @(posedge clk)
    if (~rst) begin wr_dta_en <= 1'b0; wr_dta <= 64'h0; end
    else begin
      wr_dta_en <= rd_addr_valid;
      wr_dta    <= {8{code}};
    end

  // ---- pixel queue, PROGRESSIVE raster, mixer (real pacing / backpressure) ----
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
    .interlaced(1'b0), .clip_display_size(1'b0),
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
  localparam integer P_IGNORE = 0, P_WEAVE = 1, P_BLEND = 2;

  integer phase = P_IGNORE;
  integer skip  = 0;
  integer scans_total = 0;
  integer ph_scans = 0, ph_pass = 0;
  integer cur_slot = -1, cur_n = 0, cur_px = 0, cur_bad_px = 0, cur_bad_row1 = 0;
  reg [7:0] vals [0:H*LINE_PX-1];
  reg [7:0] prev [0:H*LINE_PX-1];
  integer prev_ok = 0;
  integer errors = 0;
  integer verbose = 0;
  integer first_fail_reported = 0;
  // mismatch totals per line class, over every scored scan
  integer bad_int = 0, bad_top = 0, bad_bot = 0, bad_struct = 0, bad_row1 = 0, bad_held = 0;
  integer held_check = 0;                // C5 armed: consecutive scans are one held picture

  function integer disp_of(input integer code); disp_of = (code + 128) & 255; endfunction
  // the kernel over the displayed values, mirrored at both edges
  function integer exp_px(input integer ph, input integer y, input integer c);
    integer a, b, d;
    begin
      b = disp_of(stamp(y, c / 16));
      if (ph == P_WEAVE) exp_px = b;
      else begin
        d = (y + 1 < H) ? disp_of(stamp(y + 1, c / 16)) : disp_of(stamp(y - 1, c / 16));
        a = (y > 0)     ? disp_of(stamp(y - 1, c / 16)) : d;
        exp_px = (a + 2 * b + d + 2) / 4;
      end
    end
  endfunction

  task finish_scan;
    integer k, good, nb, y;
    begin
      if (cur_slot >= 0) begin
        scans_total = scans_total + 1;
        if (cur_px != LINE_PX) cur_bad_px = cur_bad_px + 1;    // last line
        if (scans_total > 4 && !ilace && (cur_n != H || cur_bad_px != 0 || cur_slot != 0)) begin
          bad_struct = bad_struct + 1;
          if (bad_struct <= 3)
            $display("  scan %0d STRUCTURE: slot=%0d lines=%0d badpx=%0d", scans_total, cur_slot, cur_n, cur_bad_px);
        end
        if (scans_total > 4 && cur_bad_row1) bad_row1 = bad_row1 + 1;
        if (phase != P_IGNORE && skip > 0) skip = skip - 1;
        else if (phase != P_IGNORE) begin
          good = (cur_n == H) && (cur_bad_px == 0) && (cur_slot == 0);
          nb = 0;
          for (k = 0; k < H * LINE_PX && k < cur_n * LINE_PX; k = k + 1) begin
            y = k / LINE_PX;
            if (vals[k] !== exp_px(phase, y, k % LINE_PX)) begin
              nb = nb + 1;
              if (y == 0) bad_top = bad_top + 1;
              else if (y == H - 1) bad_bot = bad_bot + 1;
              else bad_int = bad_int + 1;
            end
          end
          // C5: against the previous scored scan of the same held picture
          if (held_check && prev_ok)
            for (k = 0; k < H * LINE_PX; k = k + 1)
              if (vals[k] !== prev[k]) bad_held = bad_held + 1;
          for (k = 0; k < H * LINE_PX; k = k + 1) prev[k] = vals[k];
          prev_ok = 1;
          if (nb != 0) good = 0;
          ph_scans = ph_scans + 1;
          if (good) ph_pass = ph_pass + 1;
          if (verbose || (!good && first_fail_reported < 3)) begin
            if (!good) first_fail_reported = first_fail_reported + 1;
            $display("  scan %0d slot=%0d lines=%0d badpx=%0d wrong=%0d  L0c0=%0d/%0d L1c0=%0d/%0d L%0dc0=%0d/%0d  %s",
                     scans_total, cur_slot, cur_n, cur_bad_px, nb,
                     vals[0], exp_px(phase, 0, 0), vals[LINE_PX], exp_px(phase, 1, 0),
                     H - 1, vals[(H - 1) * LINE_PX], exp_px(phase, H - 1, 0), good ? "ok" : "MISMATCH");
          end
        end
      end
    end
  endtask

  integer prev_row0 = 0;
  always @(posedge clk) if (rst && hs_wr) begin
    if (hs_pos == ROW_0_COL_0 || (hs_pos == ROW_1_COL_0 && !prev_row0)) begin
      finish_scan;
      cur_slot = (hs_pos == ROW_1_COL_0);
      cur_n = 0; cur_px = 0; cur_bad_px = 0; cur_bad_row1 = 0;
    end
    if (hs_pos == ROW_0_COL_0 || hs_pos == ROW_1_COL_0 || hs_pos == ROW_X_COL_0) begin
      if (cur_n > 0 && cur_px != LINE_PX) cur_bad_px = cur_bad_px + 1;
      if (cur_n == 1 && hs_pos != ROW_1_COL_0 && !ilace) cur_bad_row1 = 1;   // line 1 must carry ROW_1_COL_0
      prev_row0 = (hs_pos == ROW_0_COL_0);
      cur_n = cur_n + 1; cur_px = 0;
    end
    if (cur_n >= 1 && cur_n <= H && cur_px < LINE_PX) vals[(cur_n - 1) * LINE_PX + cur_px] = hs_y;
    cur_px = cur_px + 1;
  end

  task run_phase(input integer ph, input integer nskip, input integer nscore, output integer npass);
    begin
      phase = ph; skip = nskip; ph_scans = 0; ph_pass = 0; prev_ok = 0;
      wait (ph_scans >= nscore);
      npass = ph_pass;
      phase = P_IGNORE;
    end
  endtask

  integer pickups = 0;
  integer scan_begins = 0, marked = 0;
  always @(posedge clk) if (rst) begin
    if (resample.resample_addrgen.scan_start) begin
      scan_begins = scan_begins + 1;
      if (scan_blend) marked = marked + 1;
    end
    if (output_frame_rd) pickups = pickups + 1;
  end

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
  integer n_a, n_b, sb0;
  initial begin
    void'($value$plusargs("pfr=%d", pfr));
    void'($value$plusargs("tff=%d", tff));
    void'($value$plusargs("blend_en=%d", blend_en_i));
    void'($value$plusargs("mix=%d", mix));
    void'($value$plusargs("pause=%d", pause_i));
    void'($value$plusargs("ilace=%d", ilace));
    void'($value$plusargs("verbose=%d", verbose));
    progressive_frame = pfr[0];
    top_field_first = tff[0];
    blend_en = blend_en_i[0];
    ilace_r = ilace[0];
    $display("==== field_blend_chain_tb  pfr=%0d tff=%0d blend_en=%0d mix=%0d pause=%0d ilace=%0d ====",
             pfr, tff, blend_en_i, mix, pause_i, ilace);

    repeat (8) @(posedge clk); rst = 1; repeat (8) @(posedge clk);

    if (ilace) begin
      // the fields arm: the addrgen emits TOP/BOTTOM scans; none may be marked
      repeat (3) present_one;
      sb0 = scan_begins;
      wait (scan_begins >= sb0 + 12);
      $display("  [I] fields arm: %0d scans, %0d marked", scan_begins - sb0, marked);
      if (marked != 0) begin $display("FAIL: [C8] %0d scans marked on the interlaced arm", marked); errors = errors + 1; end
    end else begin
      // a few pictures, then hold (persistence re-scans the held frame)
      repeat (3) present_one;
      held_check = 1;
      run_phase(pfr ? P_WEAVE : P_BLEND, 3, NSCORE, n_a);
      held_check = 0;
      $display("  [A] %s : %0d/%0d scans  (blend_act=%0d)",
               pfr ? "film control, weave" : "blended (kernel)   ", n_a, NSCORE, blend_act);

      if (pause_i) begin
        // a frame step while paused: the stepped picture is blended from its first scan
        @(negedge clk) pause = 1'b1;
        repeat (4) @(posedge clk);
        fork
          present_one;
          begin @(negedge clk) step_req = 1'b1; @(negedge clk) step_req = 1'b0; end
        join
        run_phase(P_BLEND, 1, NSCORE, n_b);
        $display("  [P] after a paused step: %0d/%0d scans", n_b, NSCORE);
        if (n_b != NSCORE) begin $display("FAIL: [C7] a stepped picture was not blended"); errors = errors + 1; end
        @(negedge clk) pause = 1'b0;
      end

      if (mix) begin
        // film pictures now: their scans arrive while the blend scan drains
        @(negedge clk) progressive_frame = 1'b1;
        repeat (3) present_one;
        run_phase(P_WEAVE, 3, NSCORE, n_b);
        $display("  [B] film after blend (order kept): %0d/%0d scans", n_b, NSCORE);
        if (n_b != NSCORE) begin $display("FAIL: [C6] phase B"); errors = errors + 1; end
      end
    end

    if (!ilace) begin
      if (pfr) begin
        if (bad_int + bad_top + bad_bot != 0) begin
          $display("FAIL: [C4] film control: %0d pixels differ from the weave", bad_int + bad_top + bad_bot); errors = errors + 1;
        end
      end else begin
        if (bad_int != 0) begin $display("FAIL: [C1] %0d interior pixels differ from the kernel", bad_int); errors = errors + 1; end
        if (bad_top != 0) begin $display("FAIL: [C1T] %0d top-line pixels differ (mirror a := d)", bad_top); errors = errors + 1; end
        if (bad_bot != 0) begin $display("FAIL: [C1B] %0d bottom-line pixels differ (mirror d := a)", bad_bot); errors = errors + 1; end
      end
      if (bad_held != 0) begin $display("FAIL: [C5] a held picture's consecutive scans differ on %0d pixels", bad_held); errors = errors + 1; end
      if (bad_struct != 0) begin $display("FAIL: [C2] %0d scans structurally damaged (lines / pixels / slot)", bad_struct); errors = errors + 1; end
      if (bad_row1 != 0) begin $display("FAIL: [C3] %0d scans without ROW_1_COL_0 on line 1", bad_row1); errors = errors + 1; end
      if (!pfr && n_a != NSCORE && errors == 0) begin $display("FAIL: [C2] phase A %0d/%0d scans", n_a, NSCORE); errors = errors + 1; end
    end
    if (errors == 0) $display("RESULT: PASS");
    else begin $display("RESULT: FAIL (%0d)", errors); $fatal(1, "field_blend_chain_tb failed"); end
    $finish;
  end

  initial begin
    #400_000_000;
    $display("RESULT: FAIL (timeout; scans_total=%0d phase=%0d ph_scans=%0d)", scans_total, phase, ph_scans);
    $fatal(1, "timeout");
  end
endmodule
