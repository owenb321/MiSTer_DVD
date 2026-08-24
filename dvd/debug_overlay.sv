// =============================================================================
// dvd/debug_overlay.sv — On-screen pipeline diagnostic overlay
// =============================================================================
// Paints the MPEG2/DVD pipeline's existing debug signals directly into the
// visible video frame, so the stalled stage can be identified WITHOUT a serial
// UART cable. We use this because live testing proved the failure mode is
// "valid sync, no pixel content" (the MiSTer overlay locks a correct
// 720x480/27MHz/59.94Hz signal but the picture is black) — i.e. the video sync
// path works, so an overlay displays even while the decoded image is blank.
//
// Layout (720x480, top-left origin), one row every 16 px starting at y=24,
// 16 cells per row every 16 px starting at x=48 (cell = 14 px wide, 12 tall):
//
//   row 0  wr_count   [15:0]  DDR3 write completions      (MSB..LSB block bits)
//   row 1  rd_count   [15:0]  DDR3 read completions
//   row 2  rsp_count  [15:0]  DDR3 readdatavalid pulses
//   row 3  frame_cnt  [15:0]  free-running frame counter
//   row 4  flags:  [0]streamer_active [1]has_data [2]sd_ack [3]sdram_busy
//                  [4]vld_err [5]watchdog_EXPIRED [6]core_busy [7]vbw_full
//                  (green = asserted this frame, red = not)
//   *** GOTCHA: watchdog_rst is ACTIVE-LOW (normally 1; pulses 0 for one cycle
//   on expiry). Cell [5] is fed the INVERTED, expiry sense (see wd_s sync
//   below) so GREEN here = the watchdog FIRED this frame (BAD), RED = healthy.
//   Do NOT read the raw watchdog_rst level as a flag — high is the NORMAL
//   state, so OR-accumulating it would make the cell permanently green. ***
//   row 5  shim_state [3:0]   mem_shim FSM state nibble
//   row 6  cache_missrate     burst-cache MISS RATE, windowed per 65536 clk_mem:
//          hi byte = miss%   (0xFF ~= 100% of read accesses missed the cache)
//          lo byte = read-intensity (top byte of reads/window; ~00 => near-idle
//                    window, so ignore that window's miss% as noise)
//          COMPARE Matrix vs BBB: Matrix miss% >> BBB => high-motion ref-read
//          SCATTER = MEMORY-bound (cache-geometry lever); Matrix ~= BBB => pure
//          motion-comp COMPUTE-bound (decoder-datapath lever). See
//          mem_shim_burst.sv "Cache HIT/MISS-RATE telemetry".
//   row 7  strm_count [15:0]  bytes mpg_streamer emits
//   row 8  demuxin_cnt[15:0]  bytes ps_demux consumes from the input FIFO
//   row 9  vidout_cnt [15:0]  video bytes ps_demux forwards to the decoder
//   row 10 prof0      DECODER STAGE PROFILER (clk_dec), windowed per 65536 cyc:
//          hi byte = idct_fifo_af%  (motcomp not draining IDCT residual)
//          lo byte = mvec_af%       (motcomp not draining motion vectors)
//          EITHER high => MOTCOMP is the bottleneck (motion-comp datapath lever).
//   row 11 prof1      DECODER STAGE PROFILER (clk_dec), windowed per 65536 cyc:
//          hi byte = idct_empty%     (recon STARVED of RESIDUAL => FRONT-END
//                    vld/rld/idct is the bottleneck, NOT motion comp)
//          lo byte = ref_stall%     (recon STALLED waiting for REFERENCE pixels —
//                    precise/demand-gated: in WAIT, has work + output room, but a
//                    wanted fwd/bwd prediction row isn't valid. High on Matrix vs
//                    BBB => reference-read FEED is the neck => prefetch/overlap
//                    lever; LOW while row10 mvec_af high => recon ARITH is the limit)
//          Compare Matrix vs BBB to localize the high-motion compute hotspot.
//   --- audio_ring status + AC-3 decoder self-heal ---------------------------
//   row 12 aud_frames  [15:0]  audio_ring completed frames queued (climbs on a
//                              multiplexed VOB; flat/0 = no audio PES captured)
//   row 13 aud_overflow[15:0]  audio_ring frames DROPPED on overflow (~0 in the
//                              STD backpressure era).
//   row 14 stall_cycles[15:0]  AC-3 decoder ERR-caused self-heal resets.
//   row 15 stall_info  [15:0]  AC-3 decoder TOTAL self-heal resets (err + stall
//                              watchdog). Both flat/low = healthy front end.
//   row 16 drop_costs  [15:0]  {drop acks debited 3 [15:8], debited 2 [7:0]},
//                              saturating. The frame-drop accounting check: on
//                              3:2 film the drops phase-lock to rff=0 B's so
//                              cost2 is the honest heavy byte. KEPT past the
//                              drift saga (PR #62) until a Matrix/PAL pass; the
//                              other drift instruments (play_err/gate_events/
//                              start_hold) are RETIRED.
//   row 17 vid_err     [15:0]  SIGNED wall-minus-content refreshes (mpeg2video's
//                              dbg_vid_err; 1 unit = 1 refresh = 16.7 ms).
//   row 18 nav_time    [15:0]  DVD current time = NAV-pack DSI cell-elapsed
//                              {mm,ss} BCD (Phase-7 nav foundation; MM:SS).
//   row 19 nav_total   [15:0]  DVD total time = PGC playback_time {mm,ss} BCD.
//                              Re-added 2026-07-05 for the CRT-480i field-path
//                              work: climbing = video slipping behind the wall
//                              clock (audio rides ahead); small ± flat = locked.
//
// Feed-chain verdict (rows are 0-indexed here; add 1 for the on-screen position):
//   row 7 frozen            -> mpg_streamer not emitting (SD/stream feed)
//   row 7 moves, 8 frozen   -> bytes not reaching ps_demux (input FIFO/handshake)
//   row 8 moves, 9 frozen   -> ps_demux consumes but forwards no video; then:
//       row 10 ~0           -> start codes not reaching demux (stream corrupted)
//       row 11 moves, 9 = 0 -> demux sees video PES but won't forward (demux bug)
//   row 9 moves, wr (row 0) frozen -> decoder fed but not decoding (decoder side)
//
// Counter rows: a *live* counter makes its low block-bits flicker frame to
// frame; a *frozen* counter shows a static pattern. That is the key
// "is data moving through this stage?" readout. Pulse-type flags are captured
// sticky-per-frame (asserted if they pulsed at all during the frame).
//
// All counter/flag inputs originate in the clk_mem (108 MHz) domain; this
// module runs in the clk (dot-clock, 27 MHz) domain and synchronizes them
// internally. Exact values don't matter here — only flickering vs frozen — so
// brief sampling tear is harmless.
// =============================================================================

module debug_overlay (
    input             clk,        // dot clock (clk_sys, 27 MHz) — same domain as h_pos/v_pos
    input             rst_n,
    input             en,         // overlay enable (CONF_STR toggle)

    // Video position (dot-clock domain)
    input      [11:0] h_pos,
    input      [11:0] v_pos,
    input             de,         // active-video (core_pixel_en)

    // Debug signals (clk_mem domain — synchronized inside)
    input      [15:0] wr_count,
    input      [15:0] rd_count,
    input      [15:0] rsp_count,
    input      [15:0] frame_cnt,
    input             streamer_active,
    input             streamer_has_data,
    input             streamer_sd_ack,
    input             sdram_busy,
    input             vld_err,
    input             watchdog_rst,
    input      [3:0]  shim_state,
    // Burst-cache miss-rate telemetry (clk_mem domain): {miss%, read-intensity}
    // per 65536-cycle window. Compute-vs-memory disambiguator (row 6).
    input      [15:0] cache_missrate,   // {miss_pct[15:8], reads_hi[7:0]}
    // Feed-chain byte counters (clk_sys): where do stream bytes stop flowing?
    input      [15:0] strm_count,    // bytes mpg_streamer emits
    input      [15:0] demuxin_count, // bytes ps_demux consumes from the input FIFO
    input      [15:0] vidout_count,  // video bytes ps_demux forwards to the decoder
    input      [15:0] prof0,         // row 10: decoder stage profiler {idct_fifo_af%, mvec_af%}
    input      [15:0] prof1,         // row 11: decoder stage profiler {idct_empty%, ref_stall%}
    // AC-3 decoder self-heal reset counters (clk_sys domain), rows 14/15.
    input      [15:0] stall_cycles,  // row 14: AC-3 ERR-caused self-heal resets
    input      [15:0] stall_info,    // row 15: AC-3 TOTAL self-heal resets
    input             core_busy,     // decoder cannot accept input (busy = input FIFO risks overflow)
    input             vbw_full,      // video-buffer-write side almost full

    input      [15:0] aud_frames,    // audio_ring completed frames queued (row 12)
    input      [15:0] aud_overflow,  // row 13: audio_ring frames dropped on overflow

    // Frame-drop accounting (2026-07-03; clk_sys domain). NOT muxed by O[12].
    // KEPT past the drift saga (PR #62) until a Matrix/PAL confirmation pass.
    input      [15:0] drop_costs,    // row 16: {drop acks debited 3 [15:8], debited 2 [7:0]}, saturating

    // Row 17 (re-added 2026-07-05 for the CRT-480i field-path work): vid_err —
    // SIGNED wall-vs-content refreshes from mpeg2video (clk_dec, eyeball-grade CDC
    // like rows 10/11). 1 unit = 1 refresh (16.7 ms); climbing = video content
    // falling behind the wall clock (audio rides ahead). THE instrument that
    // redirected every 480i drift diagnosis — read via tools/osd_read.py.
    input      [15:0] vid_err,

    // Row 18 (Phase-7 DVD nav foundation): current VOBU's cell-elapsed time
    // from the NAV-pack DSI (nav_dsi), packed {mm_bcd[7:0], ss_bcd[7:0]} - i.e.
    // the on-screen time readout is 4 BCD nibbles (MM:SS), osd_read-decodable.
    input      [15:0] nav_time,
    // Row 19: the TITLE's total playback time (PGC playback_time), same
    // {mm_bcd, ss_bcd} packing - the "total" half of the current/total readout.
    input      [15:0] nav_total,
    // Row 20: multi-angle (Phase 9), packed {angle_count[7:0], cur_angle[7:0]};
    // both 0 outside an interleaved (angle) block.
    input      [15:0] angle_info,

    // DVD-FORK DEBUG (Atmosfear wrong-title diagnosis) rows 21..26. Same-domain
    // (clk_sys) nav taps, synced like the rest for uniformity.
    input      [15:0] dbg21,   // LIVE reader debug_state: rd_state[5:0], S_STILL[6], menu_dom[7]
    input      [15:0] dbg22,   // {cur_vts[15:8], cur_pgcn[7:0]} currently-loaded PGC
    input      [15:0] dbg23,   // {rsm_vts[15:8], rsm_pgcn[7:0]} (01/01 = FP intro)
    input      [15:0] dbg24,   // {deadend_vts[15:8], deadend_pgcn[7:0]} (0 = none)
    input      [15:0] dbg25,   // {pgc_err_cnt[7:0], vm_dbg_state[7:0]=came_via[7]/fb[6:4]/state[3:0]}
    input      [15:0] dbg26,   // reader debug_state AT first pgc_error (0 = none)
    // Row 27 (Thayer menu-audio flow-control): {vbuf_fill[15:8], stall/guard flags[7:0]}
    // = {vbuf_fill, thr_sticky, fifo_sticky, aud_bp_sticky, aud_bp_armed,
    //    aud_ring_low, menu_aud_live, menu_vbuf_over, menu_active}. The three
    // *_sticky bits are OR-accumulated per frame in emu (a brief stall still shows).
    input      [15:0] flowctl,

    // Overlay output (dot-clock domain)
    output reg        ov_on,
    output reg [7:0]  ov_r,
    output reg [7:0]  ov_g,
    output reg [7:0]  ov_b
);

    // ---- Layout constants -------------------------------------------------
    localparam [11:0] X0    = 12'd48;   // first cell left edge
    localparam [11:0] Y0    = 12'd24;   // first row top edge
    localparam        CELLW = 4'd14;    // visible cell width  (pitch 16)
    localparam        CELLH = 4'd12;    // visible cell height (pitch 16)
    localparam        NCELL = 16;
    localparam        NROW  = 28;                      // 0..20 base + 21..26 Atmosfear nav diagnosis
                                                       // + row 17 vid_err (re-added for CRT-480i)
                                                       // + rows 18/19 nav current/total MM:SS (Phase 7)
                                                       // + row 20 angle {count, current} (Phase 9)
                                                       // + row 27 flow-control flags (Thayer menu audio)
    localparam [11:0] BOXX0 = 12'd40;
    localparam [11:0] BOXX1 = X0 + NCELL*16 + 12'd8;   // 312
    localparam [11:0] BOXY0 = 12'd16;
    localparam [11:0] BOXY1 = Y0 + NROW*16 + 12'd4;    // 332 (fits 480-line active)

    // ---- CDC: synchronize clk_mem signals into this (clk) domain ----------
    reg [15:0] wr_s, rd_s, rsp_s, fc_s, missrate_s, strm_s, demuxin_s, vidout_s, p0_s, p1_s;
    reg [15:0] stallc_s, stalli_s;
    reg [15:0] audf_s, audo_s;
    reg [15:0] dropc_s;
    reg [15:0] viderr_s;
    reg [15:0] navtime_s, navtot_s, angle_s;
    reg [15:0] dbg21_s, dbg22_s, dbg23_s, dbg24_s, dbg25_s, dbg26_s;
    reg [15:0] flowctl_s;
    reg [1:0]  sa_s, hd_s, ack_s, busy_s, err_s, wd_s, cbusy_s, vbw_s;
    reg [3:0]  st_s;

    always @(posedge clk) begin
        wr_s      <= wr_count;
        rd_s      <= rd_count;
        rsp_s     <= rsp_count;
        fc_s      <= frame_cnt;
        missrate_s <= cache_missrate;
        strm_s    <= strm_count;
        demuxin_s <= demuxin_count;
        vidout_s  <= vidout_count;
        p0_s      <= prof0;
        p1_s      <= prof1;
        stallc_s  <= stall_cycles;
        stalli_s  <= stall_info;
        audf_s    <= aud_frames;
        audo_s    <= aud_overflow;
        dropc_s   <= drop_costs;
        viderr_s  <= vid_err;
        navtime_s <= nav_time;
        navtot_s  <= nav_total;
        angle_s   <= angle_info;
        dbg21_s <= dbg21; dbg22_s <= dbg22; dbg23_s <= dbg23;
        dbg24_s <= dbg24; dbg25_s <= dbg25; dbg26_s <= dbg26;
        flowctl_s <= flowctl;
        st_s  <= shim_state;
        sa_s    <= {sa_s[0],    streamer_active};
        hd_s    <= {hd_s[0],    streamer_has_data};
        ack_s   <= {ack_s[0],   streamer_sd_ack};
        busy_s  <= {busy_s[0],  sdram_busy};
        err_s   <= {err_s[0],   vld_err};
        wd_s    <= {wd_s[0],    ~watchdog_rst};  // ACTIVE-LOW: invert -> expiry sense (1=fired)
        cbusy_s <= {cbusy_s[0], core_busy};
        vbw_s   <= {vbw_s[0],   vbw_full};
    end

    // ---- Per-frame snapshot (stable display, frame-to-frame flicker) ------
    // Counters latched at top of frame; pulse-type flags OR-accumulated over
    // the frame and latched at the top, so a brief pulse is still seen.
    reg [11:0] vpos_d;
    reg        sa_acc, hd_acc, ack_acc, busy_acc, err_acc, wd_acc, cbusy_acc, vbw_acc;
    reg [15:0] wr_d, rd_d, rsp_d, fc_d, missrate_d, strm_d, demuxin_d, vidout_d, p0_d, p1_d;
    reg [15:0] stallc_d, stalli_d;
    reg [15:0] audf_d, audo_d;
    reg [15:0] dropc_d;
    reg [15:0] viderr_d;
    reg [15:0] navtime_d, navtot_d, angle_d;
    reg [15:0] dbg21_d, dbg22_d, dbg23_d, dbg24_d, dbg25_d, dbg26_d;
    reg [15:0] flowctl_d;
    reg [7:0]  flags_d;   // {vbw,cbusy,wd,err,busy,ack,hd,sa}
    reg [3:0]  st_d;

    wire frame_top = (v_pos == 12'd0) && (vpos_d != 12'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vpos_d <= 12'd0;
            {sa_acc,hd_acc,ack_acc,busy_acc,err_acc,wd_acc,cbusy_acc,vbw_acc} <= 8'd0;
            wr_d <= 0; rd_d <= 0; rsp_d <= 0; fc_d <= 0; missrate_d <= 0;
            strm_d <= 0; demuxin_d <= 0; vidout_d <= 0; p0_d <= 0; p1_d <= 0;
            stallc_d <= 0; stalli_d <= 0; flags_d <= 0; st_d <= 0;
            audf_d <= 0; audo_d <= 0; dropc_d <= 0; viderr_d <= 0;
            navtime_d <= 0; navtot_d <= 0; angle_d <= 0;
            dbg21_d <= 0; dbg22_d <= 0; dbg23_d <= 0;
            dbg24_d <= 0; dbg25_d <= 0; dbg26_d <= 0;
            flowctl_d <= 0;
        end else begin
            vpos_d <= v_pos;
            // accumulate "seen asserted this frame"
            sa_acc    <= sa_acc    | sa_s[1];
            hd_acc    <= hd_acc    | hd_s[1];
            ack_acc   <= ack_acc   | ack_s[1];
            busy_acc  <= busy_acc  | busy_s[1];
            err_acc   <= err_acc   | err_s[1];
            wd_acc    <= wd_acc    | wd_s[1];
            cbusy_acc <= cbusy_acc | cbusy_s[1];
            vbw_acc   <= vbw_acc   | vbw_s[1];

            if (frame_top) begin
                wr_d    <= wr_s;
                rd_d    <= rd_s;
                rsp_d   <= rsp_s;
                fc_d    <= fc_s;
                missrate_d <= missrate_s;
                strm_d    <= strm_s;
                demuxin_d <= demuxin_s;
                vidout_d  <= vidout_s;
                p0_d      <= p0_s;
                p1_d      <= p1_s;
                stallc_d  <= stallc_s;
                stalli_d  <= stalli_s;
                audf_d    <= audf_s;
                audo_d    <= audo_s;
                dropc_d   <= dropc_s;
                viderr_d  <= viderr_s;
                navtime_d <= navtime_s;
                navtot_d  <= navtot_s;
                angle_d   <= angle_s;
                dbg21_d <= dbg21_s; dbg22_d <= dbg22_s; dbg23_d <= dbg23_s;
                dbg24_d <= dbg24_s; dbg25_d <= dbg25_s; dbg26_d <= dbg26_s;
                flowctl_d <= flowctl_s;
                st_d    <= st_s;
                flags_d <= {vbw_acc, cbusy_acc, wd_acc, err_acc, busy_acc, ack_acc, hd_acc, sa_acc};
                // restart accumulation from this frame's instantaneous values
                {sa_acc,hd_acc,ack_acc,busy_acc,err_acc,wd_acc,cbusy_acc,vbw_acc} <=
                    {sa_s[1], hd_s[1], ack_s[1], busy_s[1], err_s[1], wd_s[1], cbusy_s[1], vbw_s[1]};
            end
        end
    end

    // ---- Pixel position decode -------------------------------------------
    wire in_box = de &&
                  (h_pos >= BOXX0) && (h_pos < BOXX1) &&
                  (v_pos >= BOXY0) && (v_pos < BOXY1);

    wire [11:0] rel_x = h_pos - X0;
    wire [11:0] rel_y = v_pos - Y0;
    wire [3:0]  col   = rel_x[7:4];        // 0..15
    wire [4:0]  row   = rel_y[8:4];        // 0..NROW-1 (5 bits: NROW=17 > 16)

    wire in_cells_x = (h_pos >= X0) && (rel_x < (NCELL*16)) && (rel_x[3:0] < CELLW);
    wire in_cells_y = (v_pos >= Y0) && (rel_y < (NROW*16))  && (rel_y[3:0] < CELLH);
    wire in_cell    = in_cells_x && in_cells_y;

    // Bit selected within a 16-bit counter row (display MSB on the left).
    wire [3:0] bitsel = 4'd15 - col;

    // ---- Render -----------------------------------------------------------
    reg        cell_lit;     // for block-bit (white/dim) rows
    reg        is_flag;      // this cell is a green/red flag cell
    reg        flag_val;
    reg        flag_valid;   // flag cell index in range

    always @(*) begin
        ov_on = 1'b0;
        ov_r  = 8'h00; ov_g = 8'h00; ov_b = 8'h00;
        cell_lit   = 1'b0;
        is_flag    = 1'b0;
        flag_val   = 1'b0;
        flag_valid = 1'b0;

        if (en && in_box) begin
            ov_on = 1'b1;
            // dim background panel
            ov_r = 8'h10; ov_g = 8'h10; ov_b = 8'h18;

            if (in_cell) begin
                case (row)
                    5'd0: cell_lit = wr_d [bitsel];
                    5'd1: cell_lit = rd_d [bitsel];
                    5'd2: cell_lit = rsp_d[bitsel];
                    5'd3: cell_lit = fc_d [bitsel];
                    5'd4: begin
                        is_flag    = 1'b1;
                        flag_valid = (col < 4'd8);
                        flag_val   = flags_d[col[2:0]];
                    end
                    5'd5: begin
                        // shim_state nibble: 4 cells, MSB..LSB
                        if (col < 4'd4) cell_lit = st_d[3 - col[1:0]];
                    end
                    5'd6: cell_lit = missrate_d[bitsel]; // {miss%, read-intensity} per window
                    5'd7: cell_lit = strm_d   [bitsel]; // mpg_streamer bytes out
                    5'd8: cell_lit = demuxin_d[bitsel]; // ps_demux bytes consumed
                    5'd9: cell_lit = vidout_d [bitsel]; // ps_demux video bytes out
                    5'd10: cell_lit = p0_d    [bitsel]; // {VBUF fill, audio_ring fill}
                    5'd11: cell_lit = p1_d    [bitsel]; // {lates/sec, drops/sec}
                    5'd12: cell_lit = audf_d[bitsel];       // audio_ring frames queued
                    5'd13: cell_lit = audo_d[bitsel];       // audio_ring frames dropped on overflow
                    5'd14: cell_lit = stallc_d[bitsel];     // AC-3 ERR-caused self-heal resets
                    5'd15: cell_lit = stalli_d[bitsel];     // AC-3 TOTAL self-heal resets
                    5'd16: cell_lit = dropc_d[bitsel];      // {drop acks debited 3, debited 2}
                    5'd17: cell_lit = viderr_d[bitsel];     // vid_err: signed wall - content refreshes
                    5'd18: cell_lit = navtime_d[bitsel];    // DSI cell-elapsed MM:SS (current, BCD)
                    5'd19: cell_lit = navtot_d[bitsel];     // PGC playback_time MM:SS (total, BCD)
                    5'd20: cell_lit = angle_d[bitsel];      // {angle_count[15:8], cur_angle[7:0]}
                    5'd21: cell_lit = dbg21_d[bitsel];      // LIVE reader rd_state[5:0]/S_STILL[6]/menu_dom[7]
                    5'd22: cell_lit = dbg22_d[bitsel];      // {cur_vts[15:8], cur_pgcn[7:0]}
                    5'd23: cell_lit = dbg23_d[bitsel];      // {rsm_vts[15:8], rsm_pgcn[7:0]} (0101=FP intro)
                    5'd24: cell_lit = dbg24_d[bitsel];      // {deadend_vts[15:8], deadend_pgcn[7:0]} (0=none)
                    5'd25: cell_lit = dbg25_d[bitsel];      // {pgc_err_cnt[15:8], came_via[7]/fb[6:4]/state[3:0]}
                    5'd26: cell_lit = dbg26_d[bitsel];      // reader debug_state AT first pgc_error
                    5'd27: cell_lit = flowctl_d[bitsel];    // {vbuf_fill, flow-control flags}
                    default: ;
                endcase

                if (is_flag) begin
                    if (flag_valid) begin
                        // green = asserted, red = deasserted
                        ov_r = flag_val ? 8'h00 : 8'hC0;
                        ov_g = flag_val ? 8'hC0 : 8'h00;
                        ov_b = 8'h00;
                    end
                    // else: leave background (cell index 6..15 on flag row)
                end else if (cell_lit) begin
                    ov_r = 8'hFF; ov_g = 8'hFF; ov_b = 8'hFF; // bit = 1 → white
                end else begin
                    ov_r = 8'h2A; ov_g = 8'h2A; ov_b = 8'h2A; // bit = 0 → dim
                end
            end
        end
    end

endmodule
