// iso_reader_auddrain_tb.sv - a NATURAL title transition must not discard audio
// the cell still has to PRESENT (Scooby-Doo 2, "Shaggy's commentary is cut
// off", 2026-09-18; dvd/aud_drain.sv, docs/dvd_nav.md).
//
// THE DEFECT.  A natural jump/seek (a cell command, never a user press) waited
// in the reader for nat_drained - cache, demux pipe and VBUF empty - which is a
// statement about VIDEO. It then pulsed seek_ack/jump_ack, and flush_ctl fires
// aud_flush on every title-domain ack, discarding what the audio ring and
// decoder still held. Scooby-Doo 2 VTS_02 PGCN 26 authors its voice clips as
// cells with ONE picture and 4-30 s of audio: the picture drains the VBUF at
// once, the ring backpressures the demux, and the reader finishes delivering
// while a whole ring (~1.3 s of AC-3) is still to be heard.
//
// WHAT THIS MEASURES.  The real reader -> ps_stream_fifo -> ps_demux ->
// audio_ring chain, with dvd_vm, flush_ctl and aud_drain wired as emu wires
// them, and a CONSUMER that plays one ring frame every PLAY_CYC cycles. The
// score is the clip's audio bytes the consumer has FINISHED PLAYING when the
// transition's aud_flush lands: what the listener heard. Never nat_done,
// aud_drained or any signal the fix names.
//
//   [A] CLIP     natural LinkCN out of a one-picture clip: every committed
//                frame is heard before the flush. RED: ~a ring of it is lost.
//   [B] USER     a button seek mid-clip executes AT ONCE: a user press must
//                never wait for audio (the disc's own buttons cut commentary
//                on a real player too).
//   [C] DEAD     the consumer stops (audio Off / wedged decoder): the natural
//                transition still lands promptly, on the consumer watchdog,
//                not at DRAIN_WD.
//
// ⚠ The clip's LAST frame is never committed - audio_ring finalizes a frame's
// length at the NEXT frame start - so it is lost at any flush, before and after
// this fix. [A] expects (NA-1) frames, not NA.
//
// Disc layout (2048-byte sectors):
//   16 PVD  17 root  18 VIDEO_TS dir
//   19 VIDEO_TS.IFO (fp@132=400 -> JumpTT 1; tt_srpt@196=1)  20 TT_SRPT
//   22 VTSI_MAT (vts_pgcit=+1)  23 VTS_PGCIT: PGC1 (entry 0x81), 2 cells:
//        cell 0 = the CLIP  RBN 0..NA   (1 video pack + NA audio packs),
//                 cell cmd 1 = LinkCN 2
//        cell 1 = the LANDING RBN NA+1..NA+2, still=255
//   25..  VTS_01_1.VOB
//
// Run: bench/dvd/run_auddrain.sh

`timescale 1ns/1ps

module iso_reader_auddrain_tb;

    parameter integer NO_AUDIO_TERM = 0;   // 1 = the pre-fix reader wiring

    localparam integer NA        = 40;          // audio packs in the clip
    localparam integer PAYA      = 2021;        // audio payload bytes per pack
    localparam integer PAYV      = 2025;        // video payload bytes per pack
    localparam integer PLAY_CYC  = 3000;        // "playback" time of one frame
    localparam integer SETTLE_TB = 4*PLAY_CYC;  // aud_drain settle: 4 frame-times, as on HW
    localparam integer ALIVE_WD  = 40000;       // emu aud_bp_wd, scaled
    localparam [30:0]  DRAIN_WD_TB = 31'd4000000;
    localparam integer VOB0      = 25;
    localparam integer NSEC      = VOB0 + NA + 3 + 2;
    localparam integer IMG_BYTES = NSEC*2048;

    localparam [7:0] TAG_V1 = 8'hC1;   // clip video
    localparam [7:0] TAG_A1 = 8'hA1;   // clip audio
    localparam [7:0] TAG_LD = 8'hE5;   // landing video

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [63:0] file_size = 0;
    always #5 clk = ~clk;

    wire [31:0] sd_lba;
    wire        sd_rd;
    reg         sd_ack = 0;
    reg  [13:0] sd_buff_addr = 0;
    reg  [7:0]  sd_buff_dout = 0;
    reg         sd_buff_wr = 0;
    wire [7:0]  stream_data;
    wire        stream_valid;
    wire        busy;
    reg  [7:0]  img [0:IMG_BYTES-1];

    wire        jump_ack, pgc_loaded, pgc_error, menu_active, still_active;
    wire        seek_ack;
    wire [7:0]  cur_vts, best_menu_vts, cur_pgcn_rd, cur_cell, cell_count_w;
    wire [7:0]  auto_vts_w, cur_cell_cmdnr_w;
    wire        cell_ready, nav_ready_w;
    wire [6:0]  res_ttn_w;
    wire [7:0]  rd_next, rd_prev, rd_goup;
    wire        vm_cell_cmd_w, vm_pgc_end_w, vm_adv_w, vm_replay_w;
    wire        vm_jump_pulse;
    wire [1:0]  vm_jump_domain;
    wire [7:0]  vm_jump_vts, vm_jump_pgcn, vm_jump_cell, vm_jump_pgn;
    wire [9:0]  vm_jump_ptt;
    wire [3:0]  vm_jump_entry;
    wire [6:0]  vm_jump_ttn;
    wire        vm_seek_pulse;
    wire [7:0]  vm_seek_cell;
    wire        cmd_we_w, pm_we_w;
    wire [11:0] cmd_waddr_w;
    wire [7:0]  cmd_wdata_w, nr_pre_w, nr_post_w, nr_cell_w, nr_pgm_w;
    wire [6:0]  pm_waddr_w;
    wire [7:0]  pm_wdata_w;
    wire [7:0]  sprm_astn_w, sprm_spstn_w;
    wire [7:0]  vm_dbg;
    wire        keep_vbuf_w, jump_cross_w, vm_from_wait_w, nat_wait_w;
    wire        aud_drained_w;

    reg  [63:0] btn_cmd = 64'd0;
    reg         btn_cmd_valid = 0;

    dvd_iso_reader #(.DRAIN_WD(DRAIN_WD_TB)) dut (
        .agl_vm(4'd0), .agl_vm_en(1'b0), .vm_pre_done(1'b0),
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size),
        .title_sel(4'd0), .lu_lang_pref(16'h656E),
        .aud_drained(NO_AUDIO_TERM ? 1'b1 : aud_drained_w),
        .vbuf_empty(1'b1), .menu_snap(1'b0),
        .keep_vbuf(keep_vbuf_w), .jump_cross(jump_cross_w),
        .jump_ttn(vm_jump_ttn), .jump_pgn(vm_jump_pgn), .jump_ptt(vm_jump_ptt),
        .vm_mode(1'b1), .vm_adv(vm_adv_w), .vm_replay(vm_replay_w),
        .vm_cell_cmd(vm_cell_cmd_w), .vm_pgc_end(vm_pgc_end_w),
        .nav_ready_o(nav_ready_w), .auto_vts(auto_vts_w),
        .cell_count_o(cell_count_w), .res_ttn(res_ttn_w),
        .pm_we(pm_we_w), .pm_waddr(pm_waddr_w), .pm_wdata(pm_wdata_w),
        .cmd_nr_pgm(nr_pgm_w),
        .seek_pulse(vm_seek_pulse), .seek_cell(vm_seek_cell), .seek_ack(seek_ack),
        .seek_natural(vm_seek_pulse & vm_from_wait_w),
        .jump_natural(vm_from_wait_w),
        .nat_wait_o(nat_wait_w),
        .cur_cell(cur_cell), .cell_ready(cell_ready),
        .jump_pulse(vm_jump_pulse), .jump_domain(vm_jump_domain),
        .jump_vts(vm_jump_vts), .jump_pgcn(vm_jump_pgcn),
        .jump_entry(vm_jump_entry), .jump_cell(vm_jump_cell),
        .jump_ack(jump_ack), .pgc_loaded(pgc_loaded), .pgc_error(pgc_error),
        .menu_active(menu_active), .still_active(still_active), .cur_vts(cur_vts),
        .cur_pgcn_o(cur_pgcn_rd), .best_menu_vts(best_menu_vts),
        .menu_btns_armed(1'b0),
        .cmd_we(cmd_we_w), .cmd_waddr(cmd_waddr_w), .cmd_wdata(cmd_wdata_w),
        .cmd_nr_pre(nr_pre_w), .cmd_nr_post(nr_post_w), .cmd_nr_cell(nr_cell_w),
        .cell_end_pulse(), .pgc_end_pulse(),
        .pgc_still_time(), .next_pgcn(rd_next), .prev_pgcn(rd_prev),
        .goup_pgcn(rd_goup),
        .cur_cell_still(), .cur_cell_cmdnr(cur_cell_cmdnr_w),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
        .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .pal_we(), .pal_waddr(), .pal_wdata(),
        .debug_active(), .debug_sd_rd(), .debug_sd_ack(), .debug_cache_has_data(),
        .debug_file_size(), .debug_total_sectors(), .debug_next_lba(),
        .debug_state(), .debug_iso_mode(), .debug_iso_error()
    );

    dvd_vm vm (
        .agl_set(1'b0), .agl_set_val(4'd1),
        .clk(clk), .rst_n(rst_n), .enable(1'b1), .start(start), .cfg_lang(16'h656E),
        .rnd_seed(16'hACE1), .sec_tick(1'b0),
        .entropy_stir(1'b0), .entropy_val(16'd0),
        .nav_ready(nav_ready_w), .auto_vts(auto_vts_w),
        .best_menu_vts(best_menu_vts), .res_ttn(res_ttn_w),
        .cmd_we(cmd_we_w), .cmd_waddr(cmd_waddr_w), .cmd_wdata(cmd_wdata_w),
        .nr_pre(nr_pre_w), .nr_post(nr_post_w), .nr_cell(nr_cell_w),
        .pm_we(pm_we_w), .pm_waddr(pm_waddr_w), .pm_wdata(pm_wdata_w),
        .nr_pgms(nr_pgm_w),
        .pgc_loaded(pgc_loaded), .pgc_error(pgc_error),
        .vm_cell_cmd(vm_cell_cmd_w), .cell_cmd_nr(cur_cell_cmdnr_w),
        .vm_pgc_end(vm_pgc_end_w), .menu_active(menu_active),
        .cur_vts(cur_vts), .cur_pgcn(cur_pgcn_rd), .cur_cell(cur_cell),
        .cell_count(cell_count_w),
        .next_pgcn(rd_next), .prev_pgcn(rd_prev), .goup_pgcn(rd_goup),
        .key_menu(1'b0), .key_title(1'b0), .key_return(1'b0),
        .btn_cmd(btn_cmd), .btn_cmd_valid(btn_cmd_valid), .btn_sel(6'd1),
        .btns_armed(1'b0), .btn_force(), .btn_force_val(),
        .jump_pulse(vm_jump_pulse), .jump_domain(vm_jump_domain),
        .jump_vts(vm_jump_vts), .jump_pgcn(vm_jump_pgcn),
        .jump_entry(vm_jump_entry), .jump_ttn(vm_jump_ttn),
        .jump_pgn(vm_jump_pgn), .jump_cell(vm_jump_cell), .jump_ptt(vm_jump_ptt),
        .seek_pulse(vm_seek_pulse), .seek_cell(vm_seek_cell),
        .vm_replay(vm_replay_w), .vm_adv(vm_adv_w),
        .vm_from_wait(vm_from_wait_w), .wait_hold(nat_wait_w),
        .sprm_astn(sprm_astn_w), .sprm_spstn(sprm_spstn_w),
        .dbg_state(vm_dbg)
    );

    // ---- flush_ctl and the audio chain, wired as emu wires them -------------
    wire load_flush_w, pipe_rst_n_w, aud_flush_w, aud_resync_w;
    flush_ctl flush (
        .clk(clk), .rst_n(rst_n),
        .start_streaming(start), .seek_ack(seek_ack), .jump_ack(jump_ack),
        .keep_vbuf(keep_vbuf_w), .jump_cross(jump_cross_w), .mode_switch(1'b0),
        .aud_switch(1'b0), .disc_rephase(1'b0), .cell_seamless(1'b0),
        .load_flush(load_flush_w), .pipe_rst_n(pipe_rst_n_w),
        .aud_flush(aud_flush_w), .aud_resync(aud_resync_w),
        .seek_flush(), .soft_flush(), .mount_flush()
    );
    wire aud_rst_n = rst_n & ~aud_flush_w & ~aud_resync_w;

    wire [7:0] fifo_byte;
    wire       fifo_valid, demux_in_ready;
    ps_stream_fifo fifo (
        .clk(clk), .rst_n(pipe_rst_n_w),
        .wr_data(stream_data), .wr_en(stream_valid), .almost_full(busy),
        .out_byte(fifo_byte), .out_valid(fifo_valid), .out_ready(demux_in_ready)
    );

    wire [7:0]  vid_byte, aud_byte;
    wire        vid_valid, aud_valid, aud_fs, aud_pts_valid;
    wire [1:0]  aud_type;
    wire [32:0] aud_pts;
    wire        ring_almost_full;
    reg  [31:0] alive_wd = 0;                       // emu aud_bp_wd
    wire        consumer_alive = (alive_wd != 0);
    wire        aud_rdy = ~(ring_almost_full && consumer_alive);   // emu ps_aud_ready
    ps_demux demux (
        .clk(clk), .rst_n(pipe_rst_n_w),
        .in_byte(fifo_byte), .in_valid(fifo_valid), .in_ready(demux_in_ready),
        .aud_track(3'd0),
        .vid_byte(vid_byte), .vid_valid(vid_valid), .vid_ready(1'b1),
        .aud_byte(aud_byte), .aud_valid(aud_valid), .aud_type(aud_type),
        .aud_frame_start(aud_fs), .aud_ready(aud_rdy),
        .vid_pts(), .vid_pts_valid(), .aud_pts(aud_pts), .aud_pts_valid(aud_pts_valid)
    );

    wire [7:0]  r_byte;
    wire        r_valid, f_valid;
    wire [15:0] f_len, frames_avail;
    reg         r_ready = 0, f_pop = 0;
    audio_ring #(.BYTE_DEPTH(32768), .FRAME_DEPTH(128)) ring (
        .clk(clk), .rst_n(aud_rst_n),
        .aud_byte(aud_byte), .aud_valid(aud_valid & aud_rdy), .aud_type(aud_type),
        .aud_frame_start(aud_fs & aud_rdy), .drop_pulse(1'b0),
        .aud_frame_pts(aud_pts), .aud_frame_pts_valid(aud_pts_valid),
        .aud_ready(),
        .out_byte(r_byte), .out_valid(r_valid), .out_ready(r_ready),
        .frame_valid(f_valid), .frame_len(f_len), .frame_type(), .frame_pts(),
        .frame_pts_valid(), .frame_pop(f_pop),
        .frames_available(frames_avail), .bytes_available(), .overflow_count(),
        .almost_full(ring_almost_full)
    );

    aud_drain #(.SETTLE(SETTLE_TB)) drain (
        .clk(clk), .rst_n(rst_n),
        .frames_avail(frames_avail), .consumer_alive(consumer_alive),
        .dec_holding(1'b0), .drained(aud_drained_w)
    );

    // ---- the CONSUMER: pop a frame, read it, "play" it for PLAY_CYC ---------
    // Bytes count as HEARD only when a frame's play time completes, so a frame
    // cut off mid-play by the flush is not heard - which is what makes the
    // settle window in aud_drain load-bearing (M3 in the runner).
    reg        consumer_en = 1'b1;
    integer    cst = 0, cleft = 0, cplay = 0, cframe_a1 = 0;
    integer    heard_a1 = 0;
    always @(posedge clk) begin
        f_pop   <= 1'b0;
        r_ready <= 1'b0;
        if (!aud_rst_n) begin
            cst <= 0; cframe_a1 <= 0;
        end else case (cst)
        0: if (consumer_en && f_valid) begin
               f_pop <= 1'b1; cleft <= f_len; cframe_a1 <= 0; cst <= 1;
               alive_wd <= ALIVE_WD;
           end
        1: if (cleft == 0) begin cplay <= PLAY_CYC; cst <= 2; end
           else if (r_valid) begin                 // FWFT: r_byte IS the head
               r_ready <= 1'b1; cst <= 3;
               if (r_byte == TAG_A1) cframe_a1 <= cframe_a1 + 1;
           end
        3: begin cleft <= cleft - 1; cst <= 1; end // one byte per two cycles
        2: if (cplay == 0) begin heard_a1 <= heard_a1 + cframe_a1; cst <= 0; end
           else cplay <= cplay - 1;
        endcase
        if (!(cst == 0 && consumer_en && f_valid && aud_rst_n) && alive_wd != 0)
            alive_wd <= alive_wd - 1;
    end

    // ---- snapshots at the acks ----------------------------------------------
    integer n_seek = 0, n_jump = 0;
    integer heard_at_seek = -1;
    integer t_seek_ack = 0;
    integer cyc = 0;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (jump_ack) n_jump = n_jump + 1;
        if (seek_ack) begin
            n_seek = n_seek + 1;
            heard_at_seek = heard_a1;
            t_seek_ack = cyc;
        end
    end

    // ---- mock HPS ------------------------------------------------------------
    integer m = 0, bc = 0, lat = 0;
    reg [31:0] rlba = 0;
    always @(posedge clk) begin
        sd_buff_wr <= 1'b0;
        case (m)
        0: begin sd_ack <= 1'b0; if (sd_rd) begin rlba <= sd_lba; lat <= 3; m <= 1; end end
        1: if (lat != 0) lat <= lat - 1; else begin sd_ack <= 1'b1; bc <= 0; m <= 2; end
        2: begin
               sd_ack <= 1'b1; sd_buff_wr <= 1'b1;
               sd_buff_addr <= bc[13:0];
               sd_buff_dout <= img[rlba*2048 + bc];
               bc <= bc + 1;
               if (bc == 2047) m <= 3;
           end
        3: begin sd_ack <= 1'b0; sd_buff_wr <= 1'b0; m <= 0; end
        endcase
    end

    // ---- image builders ------------------------------------------------------
    integer i, cur, errors = 0;

    task put_rec(input integer off, input [31:0] ext, input [31:0] dlen,
                 input [7:0] flags, input [127:0] nm, input integer nlen,
                 output integer next_off);
        integer j; integer rl;
        begin
            rl = 33 + nlen; if (rl[0]) rl = rl + 1;
            img[off+0] = rl[7:0]; img[off+1] = 0;
            img[off+2] = ext[7:0];   img[off+3] = ext[15:8];
            img[off+4] = ext[23:16]; img[off+5] = ext[31:24];
            for (j = 6;  j < 10; j = j + 1) img[off+j] = 0;
            img[off+10] = dlen[7:0];   img[off+11] = dlen[15:8];
            img[off+12] = dlen[23:16]; img[off+13] = dlen[31:24];
            for (j = 14; j < 25; j = j + 1) img[off+j] = 0;
            img[off+25] = flags;
            for (j = 26; j < 32; j = j + 1) img[off+j] = 0;
            img[off+32] = nlen[7:0];
            for (j = 0; j < nlen; j = j + 1) img[off+33+j] = nm[8*(nlen-1-j) +: 8];
            if ((33+nlen) & 1) img[off+33+nlen] = 0;
            next_off = off + rl;
        end
    endtask
    task be16(input integer a, input [15:0] v); begin img[a] = v[15:8]; img[a+1] = v[7:0]; end endtask
    task be32(input integer a, input [31:0] v);
        begin img[a] = v[31:24]; img[a+1] = v[23:16]; img[a+2] = v[15:8]; img[a+3] = v[7:0]; end
    endtask
    task put_pgc(input integer pa, input [7:0] npgms, input [7:0] ncells,
                 input [15:0] cmd_off, input [15:0] pm_off, input [15:0] cpo);
        begin
            img[pa+2] = npgms; img[pa+3] = ncells;
            be16(pa+228, cmd_off); be16(pa+230, pm_off); be16(pa+232, cpo);
        end
    endtask
    task put_cell(input integer pa, input [15:0] cpo, input integer idx,
                  input [7:0] still, input [7:0] cmdnr, input [31:0] first, input [31:0] last);
        integer c;
        begin
            c = pa + cpo + idx*24;
            img[c+2] = still; img[c+3] = cmdnr;
            be32(c+8, first); be32(c+20, last);
        end
    endtask
    task put_cmd1(input integer a, input integer npre, input integer npost,
                  input integer ncell, input [63:0] c0);
        begin
            be16(a+0, npre[15:0]); be16(a+2, npost[15:0]); be16(a+4, ncell[15:0]);
            be16(a+6, 16'd0);
            for (i = 0; i < 8; i = i + 1) img[a+8+i] = c0[8*(7-i) +: 8];
        end
    endtask
    task pack_hdr(input integer b);
        integer j;
        begin
            img[b+0] = 8'h00; img[b+1] = 8'h00; img[b+2] = 8'h01; img[b+3] = 8'hBA;
            img[b+4] = 8'h44;
            for (j = 5; j < 13; j = j + 1) img[b+j] = 8'h00;
            img[b+13] = 8'hF8;
        end
    endtask
    task put_vpack(input integer sec, input [7:0] tag);
        integer b; integer j;
        begin
            b = sec*2048; pack_hdr(b);
            img[b+14] = 8'h00; img[b+15] = 8'h00; img[b+16] = 8'h01; img[b+17] = 8'hE0;
            be16(b+18, PAYV + 3);
            img[b+20] = 8'h80; img[b+21] = 8'h00; img[b+22] = 8'h00;
            for (j = 0; j < PAYV; j = j + 1) img[b+23+j] = tag;
        end
    endtask
    // private_stream_1 AC-3 substream 0x80: PES header, then the 4-byte
    // DVD sub-header ps_demux strips (substream, frames, first-AU pointer).
    task put_apack(input integer sec, input [7:0] tag);
        integer b; integer j;
        begin
            b = sec*2048; pack_hdr(b);
            img[b+14] = 8'h00; img[b+15] = 8'h00; img[b+16] = 8'h01; img[b+17] = 8'hBD;
            be16(b+18, PAYA + 3 + 4);
            img[b+20] = 8'h80; img[b+21] = 8'h00; img[b+22] = 8'h00;
            img[b+23] = 8'h80; img[b+24] = 8'h01; img[b+25] = 8'h00; img[b+26] = 8'h01;
            for (j = 0; j < PAYA; j = j + 1) img[b+27+j] = tag;
        end
    endtask

    task build_iso;
        integer j;
        begin
            for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = 8'h00;
            img[32768] = 8'd1;
            img[32769] = "C"; img[32770] = "D"; img[32771] = "0";
            img[32772] = "0"; img[32773] = "1"; img[32774] = 8'd1;
            put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur);
            cur = 17*2048;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 18, 2048, 8'h02, "VIDEO_TS", 8, cur);
            cur = 18*2048;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 19, 6144, 8'h00, "VIDEO_TS.IFO;1", 14, cur);
            put_rec(cur, 22, 6144, 8'h00, "VTS_01_0.IFO;1", 14, cur);
            put_rec(cur, VOB0, (NA+3)*2048, 8'h00, "VTS_01_1.VOB;1", 14, cur);

            // VMGI_MAT: FP PGC @400 = JumpTT 1; TT_SRPT @+1
            be32(19*2048+132, 32'd400);
            be32(19*2048+196, 32'd1);
            put_pgc(19*2048+400, 8'd0, 8'd0, 16'd236, 16'd0, 16'd0);
            put_cmd1(19*2048+400+236, 1, 0, 0, 64'h3002000000010000);
            be16(20*2048+0, 16'd1);
            img[20*2048+14] = 8'd1;
            img[20*2048+15] = 8'd1;

            // VTSI_MAT: vts_pgcit @+1 (23), no menus
            be32(22*2048+204, 32'd1);

            // VTS_PGCIT @23: PGC1 @32, 2 pgms / 2 cells, pm {1,2}
            be16(23*2048+0, 16'd1);
            img[23*2048+8] = 8'h81;
            be32(23*2048+8+4, 32'd32);
            put_pgc(23*2048+32, 8'd2, 8'd2, 16'd320, 16'd240, 16'd256);
            img[23*2048+32+240] = 8'd1;
            img[23*2048+32+241] = 8'd2;
            put_cell(23*2048+32, 16'd256, 0, 8'd0,   8'd1, 32'd0,    NA);
            put_cell(23*2048+32, 16'd256, 1, 8'd255, 8'd0, NA+1,     NA+2);
            put_cmd1(23*2048+32+320, 0, 0, 1, 64'h2007000000000002);  // LinkCN 2

            // the clip: 1 picture, then NA audio packs; the landing: 2 pictures
            put_vpack(VOB0, TAG_V1);
            for (j = 1; j <= NA; j = j + 1) put_apack(VOB0 + j, TAG_A1);
            put_vpack(VOB0 + NA + 1, TAG_LD);
            put_vpack(VOB0 + NA + 2, TAG_LD);
        end
    endtask

    task fail(input [511:0] msg);
        begin $display("FAIL: %0s", msg); errors = errors + 1; end
    endtask
    task press_btn(input [63:0] cmd);
        begin
            @(posedge clk); btn_cmd <= cmd; btn_cmd_valid <= 1'b1;
            @(posedge clk); btn_cmd_valid <= 1'b0;
        end
    endtask
    // wait for the next seek_ack; returns the cycles waited (or -1)
    task wait_seek(input integer bound, output integer waited);
        integer t0, s0;
        begin
            s0 = n_seek; t0 = 0;
            while (n_seek == s0 && t0 < bound) begin @(posedge clk); t0 = t0 + 1; end
            waited = (n_seek == s0) ? -1 : t0;
        end
    endtask
    // replay the clip: a USER LinkPGN 1 seek back into cell 0
    task replay_clip;
        integer w;
        begin
            press_btn(64'h2006000000000001);
            wait_seek(600000, w);
            if (w < 0) fail("could not seek back into the clip");
            heard_a1 = 0;
        end
    endtask

    localparam integer WANT = (NA-1)*PAYA;
    integer w, t_nat;

    initial begin
        build_iso;
        file_size = NSEC*2048;
        #40 rst_n = 1;
        #40 start = 1;
        #20 start = 0;

        // ================= [A] CLIP ============================================
        // FP -> JumpTT 1 lands on the clip; its cell command is the natural
        // LinkCN 2 whose seek_ack fires the aud_flush under measurement.
        wait_seek(8000000, w);
        if (w < 0) fail("[A] the clip's LinkCN never executed");
        else if (heard_at_seek < WANT) begin
            $display("   [A] heard %0d/%0d clip audio bytes before the flush (%0d frames lost)",
                     heard_at_seek, WANT, (WANT - heard_at_seek + PAYA - 1) / PAYA);
            fail("[A] the clip's audio was CUT OFF by the natural transition");
        end else
            $display("   [A] heard %0d/%0d clip audio bytes before the flush  ok",
                     heard_at_seek, WANT);
        if (cur_cell !== 8'd1) fail("[A] did not land on the landing cell");

        // ================= [B] USER ============================================
        replay_clip;
        w = 0;
        while (heard_a1 < 5*PAYA && w < 2000000) begin @(posedge clk); w = w + 1; end
        press_btn(64'h2007000000000002);      // the same LinkCN, from a USER
        wait_seek(20000, w);
        if (w < 0) begin
            fail("[B] a USER seek waited for the audio (it must never)");
            // let the late seek land before [C], or [C]'s own press meets a
            // reader that is still pending and a B defect reads as a C one
            wait_seek(DRAIN_WD_TB, w);
        end else $display("   [B] user seek executed after %0d cycles  ok", w);

        // ================= [C] DEAD CONSUMER ===================================
        consumer_en = 1'b0;
        replay_clip;
        wait_seek(DRAIN_WD_TB, w);
        t_nat = w;
        if (w < 0) fail("[C] the natural transition never executed");
        else if (w > DRAIN_WD_TB/4) begin
            $display("   [C] released after %0d cycles (DRAIN_WD %0d)", w, DRAIN_WD_TB);
            fail("[C] a dead consumer held the transition to the watchdog");
        end else
            $display("   [C] dead consumer: natural transition after %0d cycles  ok", w);
        consumer_en = 1'b1;

        $display("");
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        if (errors != 0) $fatal(1, "iso_reader_auddrain_tb failed");
        $finish;
    end

    initial begin
        #400000000;
        $display("RESULT: TIMEOUT");
        $fatal(1, "iso_reader_auddrain_tb timeout");
    end
endmodule
