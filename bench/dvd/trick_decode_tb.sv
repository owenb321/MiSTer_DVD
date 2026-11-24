`timescale 1ns/1ps
//
// trick_decode_tb.sv -- the WHOLE video decoder (rtl/mpeg2/mpeg2video.v) on a real stream.
//
// The first full-decoder bench in this tree (2026-11-22). Every other video bench drives a
// slice of the pipeline (vld + getbits, rld + iquant, picbuf), which cannot see a desync that
// lands in motcomp or the framestore. This one runs the decoder exactly as dvd/emu.sv
// instantiates it, behind a memory model, and records every reconstructed-picture write so
// bench/dvd/trick_decode_score.py can rebuild each picture and compare it with ffmpeg's decode
// of the same elementary stream.
//
// Built for trick play (docs/trick_play.md): the claim it checks is "the decoder decodes a
// spliced I-frame stream (tools/trick_splice.py) to the same pictures ffmpeg does". It is
// written generally: any .m2v elementary stream works.
//
// What it records ($fwrite to +OUT=, default trick_decode.log):
//   W <addr> <data>   every framestore WRITE below the OSD (the four frame slots)
//   E <cycle> <what>  watchdog expiries and error flags, as they happen
//   D <writes> <bytes_fed> <cycles>   the summary line at the end
//
// Plusargs:
//   +M2V=<file.m2v>  the elementary stream, read as bytes
//   +PICS=<n>        stop after n pictures' worth of recon writes (default 8)
//   +OUT=<log>
//
// Every input of mpeg2video is tied explicitly: a new decoder input left off this list
// floats Z (CLAUDE.md "Cross-cutting lessons"). The values are emu.sv's for a plain
// free-running playback: sched_en = 0 is the A/V Sync Off arm, the PTS path is idle.
//
module trick_decode_tb;

  // clocks: the HW ratios are clk_dec 81 / mem 90 / dot 27 MHz. The dot clock runs fast
  // here (it only paces display reads, which free framestore slots); nothing scored depends
  // on the raster's real rate.
  reg clk = 0;      always #6.17 clk = ~clk;   // 81 MHz
  reg mem_clk = 0;  always #5.55 mem_clk = ~mem_clk;   // 90 MHz
  reg dot_clk = 0;  always #9.0  dot_clk = ~dot_clk;
  reg rst = 0;      // active low, as emu.sv's reset_n

  // ---- the stream -------------------------------------------------------------------
  // Read from the .m2v itself, one byte per accepted cycle. (A preloaded reg array with a
  // combinational read hung Icarus's compile for 18 h at 8 MB: @* goes sensitive to every
  // word.) `sd` always holds the byte at offset `fed`; `at_eof` is when the file runs out.
  integer   sfh, fed = 0, ch;
  reg       at_eof = 1;
  wire      busy;
  wire      sv = !at_eof && !busy && rst;
  reg [7:0] sd = 8'h00;
  always @(posedge clk) if (sv) begin
    fed <= fed + 1;
    ch = $fgetc(sfh);
    if (ch < 0) at_eof <= 1'b1; else sd <= ch[7:0];
  end

  // ---- memory model (behind mem_shim_burst's handshake) -----------------------------
  wire  [1:0] mq_cmd;
  wire [21:0] mq_addr;
  wire [63:0] mq_dta;
  wire        mq_valid;
  wire        mr_af;                           // the decoder's response-FIFO almost-full
  reg  [63:0] mr_dta = 0;
  reg         mr_en = 0;
  localparam [21:0] OSD_BASE = 22'h060000;     // dvd/mem_override/mem_codes.v (MP@ML)
  reg  [63:0] mem [0:22'h0bffff];
  // read pipeline: fixed latency, so the response order is the request order
  localparam integer LAT = 6;
  reg  [63:0] pipe_d [0:LAT-1];
  reg         pipe_v [0:LAT-1];
  // mem_req_prefetch is a standard (not first-word-fall-through) FIFO: rd_en pops, and the
  // word appears with valid on the NEXT cycle. So the model asks whenever the decoder's
  // response FIFO has room, and serves a request on valid (as mem_shim_burst does).
  wire        mq_en = !mr_af && rst;
  integer     fd, writes = 0, cycles = 0, pics_target = 8, k;
  integer     n_rd = 0, n_wr = 0, n_vbw = 0, n_vbr = 0, n_busy = 0, n_mv = 0, n_af = 0;
  always @(posedge mem_clk) begin
    for (k = LAT - 1; k > 0; k = k - 1) begin
      pipe_d[k] <= pipe_d[k-1];
      pipe_v[k] <= pipe_v[k-1];
    end
    pipe_v[0] <= 1'b0;
    if (mq_valid) begin
      case (mq_cmd)
        2'b11: begin                                  // CMD_WRITE
          mem[mq_addr] <= mq_dta;
          n_wr <= n_wr + 1;
          if (mq_addr >= 22'h080000) n_vbw <= n_vbw + 1;
          if (mq_addr < OSD_BASE) begin
            $fwrite(fd, "W %06h %016h\n", mq_addr, mq_dta);
            writes <= writes + 1;
          end
        end
        2'b10: begin                                  // CMD_READ
          n_rd <= n_rd + 1;
          if (mq_addr >= 22'h080000) n_vbr <= n_vbr + 1;
          pipe_v[0] <= 1'b1;
          pipe_d[0] <= (^mem[mq_addr] === 1'bx) ? 64'd0 : mem[mq_addr];
        end
        default: ;                                    // NOOP, REFRESH
      endcase
    end
    if (mq_valid) n_mv <= n_mv + 1;

    if (mr_af) n_af <= n_af + 1;
    mr_en  <= pipe_v[LAT-1];
    mr_dta <= pipe_d[LAT-1];
  end

  // ---- the decoder, as emu.sv instantiates it ---------------------------------------
  wire watchdog_rst, dec_error;
  mpeg2video dut (
    .clk(clk), .mem_clk(mem_clk), .dot_clk(dot_clk), .dot_ce(1'b1), .rst(rst),
    .stream_data(sd), .stream_valid(sv), .stream_mark(1'b0),
    .pts_in(33'd0), .pts_in_valid(1'b0),
    .stc_tick(1'b0), .sched_en(1'b0), .trick_cad(1'b0), .half_scan(16'd0),
    .stc(), .stc_anchored(), .disp_anchored(), .anchor_req(), .anchor_disc(),
    .cc_credit_valid(), .cc_credit(), .anchor_delta(), .disp_lag(), .disp_lag_valid(),
    .sched_dbg_flags(), .sched_dbg_dur(),
    .reg_addr(4'd0), .reg_wr_en(1'b0), .reg_dta_in(32'd0), .reg_rd_en(1'b0), .reg_dta_out(),
    .busy(busy), .error(dec_error), .interrupt(), .watchdog_rst(watchdog_rst),
    .r(), .g(), .b(), .y(), .u(), .v(), .pixel_en(), .h_sync(), .v_sync(), .c_sync(),
    .h_pos(), .v_pos(),
    .mem_req_rd_cmd(mq_cmd), .mem_req_rd_addr(mq_addr), .mem_req_rd_dta(mq_dta),
    .mem_req_rd_en(mq_en), .mem_req_rd_valid(mq_valid),
    .mem_res_wr_dta(mr_dta), .mem_res_wr_en(mr_en), .mem_res_wr_almost_full(mr_af),
    .testpoint_dip(4'd0), .testpoint_dip_en(1'b0), .testpoint(),
    .init_cnt_out(), .sync_rst_out(), .vbw_almost_full_out(),
    .dbg_lines_displayed(), .dbg_first_vpos(), .dbg_last_vpos(),
    .dbg_prof0(), .dbg_prof1(), .dbg_prof2(), .dbg_prof3(),
    .dbg_pic_max(), .dbg_pic_n(), .dbg_pic_over(),
    .dbg_fb_heals(), .dbg_strict_waits(),
    .cc_pair_valid(), .cc_pair(), .cc_pair_field(),
    .vertical_size_out(), .horizontal_size_out(), .aspect_ratio_out(),
    .ref_prefetch_en(1'b1), .frame_drop_en(1'b0),
    .dbg_frames_late(), .dbg_frames_dropped(), .dbg_pickups(), .dbg_drop_costs(),
    .dbg_vbuf_fill(), .video_live(),
    .pickup_hold(1'b0), .pause(1'b0), .step_req(1'b0), .freeze_wd(1'b0),
    .vbuf_flush(1'b0), .soft_flush(1'b0),
    .disp_vscale_mode(2'd0), .disp_vscale_en(1'b0), .disp_vscale_ratio(2'd0),
    .disp_hcrop_en(1'b0), .disp_hfill_en(1'b0), .film24(1'b0),
    .film_det_ntsc(), .film_det_pal(),
    .blend_en(1'b0), .blend_act(), .bob_en(1'b0), .bob_act(), .std_cad(1'b0)
  );

  // ---- events ------------------------------------------------------------------------
  reg wd_q = 1, er_q = 0;
  integer wd_n = 0, er_n = 0;
  always @(posedge clk) begin
    cycles <= cycles + 1;
    if (busy) n_busy <= n_busy + 1;

    wd_q <= watchdog_rst;
    er_q <= dec_error;
    if (rst && wd_q && !watchdog_rst) begin           // active LOW: a low pulse = expiry
      wd_n <= wd_n + 1;
      $fwrite(fd, "E %0d watchdog\n", cycles);
    end
    if (rst && !er_q && dec_error) begin
      er_n <= er_n + 1;
      $fwrite(fd, "E %0d error\n", cycles);
    end
  end

  // ---- run ---------------------------------------------------------------------------
  // one 720x480 4:2:0 picture = 43,200 luma + 2 x 10,800 chroma 8-pixel words
  localparam integer WORDS_PER_PIC = 64800;
  string m2v, outp;
  integer tmo, max_cyc, last_w, idle;
  initial begin
    if (!$value$plusargs("M2V=%s", m2v)) $fatal(1, "need +M2V=<stream.m2v>");
    if (!$value$plusargs("OUT=%s", outp)) outp = "trick_decode.log";
    if (!$value$plusargs("PICS=%d", pics_target)) pics_target = 8;
    if (!$value$plusargs("MAXCYC=%d", max_cyc)) max_cyc = 400_000_000;
    sfh = $fopen(m2v, "rb");
    if (sfh == 0) $fatal(1, "cannot open %s", m2v);
    ch = $fgetc(sfh);
    if (ch < 0) $fatal(1, "empty stream %s", m2v);
    sd = ch[7:0];
    at_eof = 0;
    fd = $fopen(outp, "w");
    $display("trick_decode_tb: %s, stop after %0d pictures", m2v, pics_target);
    repeat (40) @(posedge clk);
    rst = 1;
    tmo = 0;
    // Stop at the target, at the cycle cap, or when the stream has run out and nothing has
    // been written for 2M cycles. The decoder holds the LAST 8 words of a picture until the
    // next picture starts (measured 2026-11-23: 388,792 of 388,800 for 6), so the final
    // picture of a stream never completes; the runner splices one VOBU more than it scores.
    last_w = 0; idle = 0;
    while (writes < pics_target * WORDS_PER_PIC && tmo < max_cyc && idle < 2_000_000) begin
      @(posedge clk);
      tmo = tmo + 1;
      if (writes != last_w) begin last_w = writes; idle = 0; end
      else if (at_eof) idle = idle + 1;
      if (tmo % 200_000 == 0) begin
        $display("  %0d cycles: fed %0d bytes%s, %0d recon words (%0d pics), wd %0d err %0d",
                 tmo, fed, at_eof ? " (eof)" : "", writes, writes / WORDS_PER_PIC, wd_n, er_n);
        $display("    mem: rd %0d (vbuf %0d) wr %0d (vbuf %0d) valid %0d af %0d; busy %0d",
                 n_rd, n_vbr, n_wr, n_vbw, n_mv, n_af, n_busy);

        $fflush();
      end
    end
    $fwrite(fd, "D %0d %0d %0d %0d %0d\n", writes, fed, cycles, wd_n, er_n);
    $fclose(fd);
    $display("trick_decode_tb: DONE writes %0d (%0d pics) fed %0d cycles %0d watchdog %0d error %0d",
             writes, writes / WORDS_PER_PIC, fed, cycles, wd_n, er_n);
    $finish;
  end
endmodule
