// iso_reader_menudrain_tb.sv - a NATURAL MENU verdict must execute on a
// DELIVERED stream (docs/dvd_menu_refinements.md, the T2 Mission-Profiles
// first-slide defect).
//
// THE DEFECT.  A menu cell whose cell command links to another menu PGC
// (T2: the Mission-Profiles transition clip, cell_cmd LinkTailPGC -> POST
// LinkPGCN 20 -> the first slide) used to have its jump execute the moment the
// VM answered.  The reader leaves S_STREAM for S_VM_WAIT at the last block
// READ, and its output pipeline only ran while S_STREAM - so whatever was left
// in the 16 KB stream cache was never delivered, and jump_ack then reset
// wr_ptr and threw it away.  keep_vbuf holds the DECODER's buffer, so the
// decoder was left ending on a picture cut mid-slice with the landing still's
// sequence header right behind it: it eats the header and decodes the landing
// with the source's quantiser matrix.  (bench/dvd/run_menu_junction.sh measures
// that decoder half on the real disc bytes; this bench measures the delivery
// half that causes it.)
//
// WHAT THIS MEASURES.  The real reader -> ps_stream_fifo -> ps_demux chain,
// scoring the VIDEO ELEMENTARY BYTES ps_demux emits - what the decoder would
// actually receive.  Never jnat_l, nat_drained or any other signal the fix
// names: the fix could be renamed entirely and these arms would not move.
//
// ★ The chain (not just the reader's own output port) is the point.  Bytes that
// have left the reader but are still in ps_stream_fifo or inside ps_demux at
// jump_ack are ALSO lost - load_flush resets both - so this is what proves the
// settle window in nat_drained is long enough, rather than asserting it.
//
//   [A] DELIVERY  every byte of the transition cell reaches the decoder before
//                 the jump, and the first bytes after it are the LANDING's.
//                 Run with vbuf_empty=1 throughout, so the decoder's low-water
//                 mark cannot be what gates: only the reader's own path can.
//                 Includes a LONG sink stall mid-cell (the menu VBUF cap on
//                 hardware), which is the only state that can tell "the pipe is
//                 quiet" apart from "there is nothing left to send".
//                 RED (pre-fix): the tail is missing.
//   [B] keep_vbuf is still 1 on that menu->menu jump (Phase 5 preserved) and
//                 the jump is a jump, not a flush-bearing seek.
//   [C] HOLD      with vbuf_empty=0 the verdict waits even once every byte is
//                 delivered, and releases when it rises.
//   [D] USER      a button jump mid-cell with vbuf_empty=0 executes AT ONCE
//                 (user actions never gate) and emits no stale byte afterwards.
//   [F] WATCHDOG  vbuf_empty never rises -> the jump still lands, at DRAIN_WD.
//   [G] SEEK      a natural cell-command SEEK verdict waits the same way.
//
// Disc layout (2048-byte sectors).  Menu VOB sectors are REAL Program-Stream
// packs (pack header + one video PES) whose payload bytes are a per-cell tag,
// so a byte count at ps_demux's video output is a per-cell delivery count.
//   16 PVD  17 root  18 VIDEO_TS dir
//   19 VIDEO_TS.IFO s0 (VMGI_MAT: fp@132=400, tt_srpt@196=1, vmgm_ut@200=2)
//   20 TT_SRPT (1 title -> VTS_01)      21 VMGM PGCI_UT (PGCN1 entry 0x82)
//   22 VTSI_MAT (vts_pgcit=+1, vtsm=+2) 23 title VTS_PGCIT (PGC1, 2 cells)
//   24 VTSM PGCI_UT:
//        PGCN1 entry 0x83 @64  = THE MENU: 3 cells, pm {1,2,3}
//              cell 0 still=255 (1 sector, tag D0)
//              cell 1 motion   (12 sectors, tag D1) cmd_nr 1 = LinkTailPGC
//              cell 2 motion   ( 6 sectors, tag D2) cmd_nr 2 = LinkPGN 1
//              POST = LinkPGCN 2
//        PGCN2 @600 = THE LANDING: 1 still cell (2 sectors, tag E5)
//   25       menu cell 0        26..37 menu cell 1     38..43 menu cell 2
//   44,45    landing still      46,47  title VOB (tag B0)
//
// Run: iverilog -g2012 -o /tmp/rmd dvd/dvd_iso_reader.sv dvd/dvd_vm.sv \
//        dvd/bcd_time_add.sv dvd/ps_stream_fifo.sv dvd/ps_demux.sv \
//        dvd/flush_ctl.sv bench/dvd/iso_reader_menudrain_tb.sv && vvp /tmp/rmd

`timescale 1ns/1ps

module iso_reader_menudrain_tb;

    localparam IMG_BYTES = 64*2048;
    // ⚠ Must comfortably exceed the time arm [A]'s deliberately slow sink takes
    // to drain a whole cell (~194k cycles at 64 bytes per 512), or the WATCHDOG
    // becomes the thing that releases the verdict and the arm measures the
    // bench's own bound instead of the gate. On hardware DRAIN_WD is 60 s and a
    // menu cell drains in a fraction of that.
    localparam DRAIN_WD_TB = 31'd600000;

    // sector payload tags
    localparam [7:0] TAG_C0 = 8'hD0;   // menu cell 0 (the still we enter on)
    localparam [7:0] TAG_C1 = 8'hD1;   // menu cell 1 (the transition clip)
    localparam [7:0] TAG_C2 = 8'hD2;   // menu cell 2 (the seek vehicle)
    localparam [7:0] TAG_LD = 8'hE5;   // the landing still
    localparam [7:0] TAG_TT = 8'hB0;   // title
    localparam integer PAY  = 2025;    // payload bytes per sector pack
    localparam integer C1_SECTORS = 12;
    localparam integer C2_SECTORS = 6;
    localparam integer C1_BYTES = C1_SECTORS * PAY;
    localparam integer C2_BYTES = C2_SECTORS * PAY;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [63:0] file_size = 0;

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
    wire        keep_vbuf_w;
    wire        jump_cross_w;   // reader: this jump crosses menu<->title
    wire        vm_from_wait_w;
    wire        nat_wait_w;

    reg         key_menu = 0;
    reg         vbuf_empty = 1;
    reg  [63:0] btn_cmd = 64'd0;
    reg         btn_cmd_valid = 0;

    dvd_iso_reader #(.DRAIN_WD(DRAIN_WD_TB)) dut (
        // new reader inputs tied off: a floating input is X, and X on
        // agl_vm_en would poison the angle resolve (see the port comments).
        .agl_vm(4'd0), .agl_vm_en(1'b0), .vm_pre_done(1'b0),
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size),
        .title_sel(4'd0), .lu_lang_pref(16'h656E),
        .aud_drained(1'b1), .vbuf_empty(vbuf_empty), .menu_snap(1'b0),
        .keep_vbuf(keep_vbuf_w),
        .jump_cross(jump_cross_w),
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
        .cur_pgcn_o(cur_pgcn_rd),
        .best_menu_vts(best_menu_vts),
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
        // new VM ports tied off (a floating input is X).
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
        .key_menu(key_menu), .key_title(1'b0), .key_return(1'b0),
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

    // ---- the real downstream chain, wired as emu.sv wires it ---------------
    // pipe_rst_n: emu holds ps_stream_fifo and ps_demux in reset for the
    // load_flush level, which EVERY seek/jump pulses (keep_vbuf or not). That
    // is what makes bytes still in flight at the ack unrecoverable, and why
    // this bench measures after ps_demux rather than at the reader's port.
    wire        load_flush_w, pipe_rst_n_w;
    flush_ctl flush (
        .clk(clk), .rst_n(rst_n),
        .start_streaming(start), .seek_ack(seek_ack), .jump_ack(jump_ack),
        .keep_vbuf(keep_vbuf_w), .jump_cross(jump_cross_w), .mode_switch(1'b0),
        .aud_switch(1'b0), .disc_rephase(1'b0), .cell_seamless(1'b0),
        .load_flush(load_flush_w), .pipe_rst_n(pipe_rst_n_w),
        .aud_flush(), .aud_resync(), .seek_flush(), .soft_flush(), .mount_flush()
    );

    wire [7:0]  fifo_byte;
    wire        fifo_valid, demux_in_ready;
    ps_stream_fifo fifo (
        .clk(clk), .rst_n(pipe_rst_n_w),
        .wr_data(stream_data), .wr_en(stream_valid), .almost_full(busy),
        .out_byte(fifo_byte), .out_valid(fifo_valid), .out_ready(demux_in_ready)
    );

    wire [7:0]  vid_byte;
    wire        vid_valid;
    reg         vid_ready = 1'b1;
    ps_demux demux (
        .clk(clk), .rst_n(pipe_rst_n_w),
        .in_byte(fifo_byte), .in_valid(fifo_valid), .in_ready(demux_in_ready),
        .aud_track(3'd0), .aud_realign(1'b0),
        .vid_byte(vid_byte), .vid_valid(vid_valid), .vid_ready(vid_ready),
        .aud_byte(), .aud_valid(), .aud_type(), .aud_frame_start(),
        .aud_ready(1'b1),
        .vid_pts(), .vid_pts_valid(), .aud_pts(), .aud_pts_valid()
    );

    always #5 clk = ~clk;

    // ---- THE MEASUREMENT: video elementary bytes per cell tag --------------
    // A tag count at ps_demux's video output is "what the decoder received",
    // which is the only thing the defect changes.
    integer got [0:255];
    integer got_total = 0;
    reg [7:0] first_after_ack = 8'h00;
    integer   n_after_ack = 0;
    reg       watch_after = 1'b0;
    integer   k;
    always @(posedge clk) begin
        if (vid_valid && vid_ready) begin
            got[vid_byte] = got[vid_byte] + 1;
            got_total     = got_total + 1;
            if (watch_after) begin
                if (n_after_ack == 0) first_after_ack = vid_byte;
                n_after_ack = n_after_ack + 1;
            end
        end
    end

    // ---- snapshots taken AT the acks --------------------------------------
    integer c1_at_jump = -1, c2_at_seek = -1;
    integer n_jump_ack = 0, n_seek_ack = 0, n_pgc_end = 0;
    reg     kv_at_jump = 1'bx, kv_at_seek = 1'bx;
    always @(posedge clk) begin
        if (jump_ack) begin
            n_jump_ack = n_jump_ack + 1;
            kv_at_jump = keep_vbuf_w;
            if (c1_at_jump < 0 && got[TAG_C1] > 0) c1_at_jump = got[TAG_C1];
        end
        if (seek_ack) begin
            n_seek_ack = n_seek_ack + 1;
            kv_at_seek = keep_vbuf_w;
            if (c2_at_seek < 0 && got[TAG_C2] > 0) c2_at_seek = got[TAG_C2];
        end
        if (vm_pgc_end_w) n_pgc_end = n_pgc_end + 1;
    end

    // ---- mock HPS: one 2048-byte sector per sd_rd --------------------------
    integer m = 0;
    integer bc = 0;
    reg [31:0] rlba = 0;
    integer lat = 0;
    always @(posedge clk) begin
        sd_buff_wr <= 1'b0;
        case (m)
        0: begin
            sd_ack <= 1'b0;
            if (sd_rd) begin rlba <= sd_lba; lat <= 3; m <= 1; end
        end
        1: begin
            if (lat != 0) lat <= lat - 1;
            else begin sd_ack <= 1'b1; bc <= 0; m <= 2; end
        end
        2: begin
            sd_ack       <= 1'b1;
            sd_buff_wr   <= 1'b1;
            sd_buff_addr <= bc[13:0];
            sd_buff_dout <= img[rlba*2048 + bc];
            bc           <= bc + 1;
            if (bc == 2047) m <= 3;
        end
        3: begin
            sd_ack     <= 1'b0;
            sd_buff_wr <= 1'b0;
            m          <= 0;
        end
        endcase
    end

    // ---- SINK THROTTLE -----------------------------------------------------
    // The decoder backpressures a menu transition on hardware (emu's menu VBUF
    // cap), which is what leaves the reader's cache full at the cell end - the
    // state the defect needs. Accepting 1 byte in 4 reproduces it: without any
    // throttle the cache never builds a backlog and every arm passes for the
    // wrong reason.
    // stall_n > 0 holds the sink OFF entirely: the LONG stall the decoder
    // applies on hardware when the menu VBUF cap throttles the reader (emu's
    // MENU_CAP_ON, ~40-50 ms = far longer than the settle window). During it
    // the reader's output pipeline goes quiet with its cache still FULL, which
    // is the one state where ~cache_has_data is the only term keeping the gate
    // shut. Without an arm that reproduces it, dropping that term is invisible.
    // `slow` is the shape that matters: 64 accepting cycles in every 512, so the
    // sink is idle for ~448 at a stretch - LONGER THAN THE SETTLE WINDOW - while
    // the reader's cache is still full. That is the state in which "the pipe has
    // been quiet for a while" and "there is nothing left to send" differ, and it
    // is what the menu VBUF cap produces on hardware. A short duty cycle cannot
    // tell them apart, so with one the cache term looks redundant and dropping
    // it is invisible (measured: M3 caught by nothing until this arm existed).
    reg throttle = 1'b0;
    reg slow = 1'b0;
    integer tcnt = 0;
    always @(posedge clk) begin
        tcnt <= tcnt + 1;
        if (slow)          vid_ready <= (tcnt % 512) < 64;
        else if (throttle) vid_ready <= (tcnt[1:0] == 2'd0);
        else               vid_ready <= 1'b1;
    end

    // ---- image builders (iso_reader_vm_tb pattern) -------------------------
    integer i;
    integer cur;
    integer errors = 0;

    task put_rec(input integer off, input [31:0] ext, input [31:0] dlen,
                 input [7:0] flags, input [127:0] nm, input integer nlen,
                 output integer next_off);
        integer j; integer rl;
        begin
            rl = 33 + nlen;
            if (rl[0]) rl = rl + 1;
            img[off+0] = rl[7:0];
            img[off+1] = 0;
            img[off+2] = ext[7:0];   img[off+3] = ext[15:8];
            img[off+4] = ext[23:16]; img[off+5] = ext[31:24];
            for (j = 6;  j < 10; j = j + 1) img[off+j] = 0;
            img[off+10] = dlen[7:0];   img[off+11] = dlen[15:8];
            img[off+12] = dlen[23:16]; img[off+13] = dlen[31:24];
            for (j = 14; j < 25; j = j + 1) img[off+j] = 0;
            img[off+25] = flags;
            img[off+26] = 0; img[off+27] = 0;
            for (j = 28; j < 32; j = j + 1) img[off+j] = 0;
            img[off+32] = nlen[7:0];
            for (j = 0; j < nlen; j = j + 1)
                img[off+33+j] = nm[8*(nlen-1-j) +: 8];
            if ((33+nlen) & 1) img[off+33+nlen] = 0;
            next_off = off + rl;
        end
    endtask

    task be16(input integer a, input [15:0] v);
        begin img[a] = v[15:8]; img[a+1] = v[7:0]; end
    endtask
    task be32(input integer a, input [31:0] v);
        begin
            img[a]   = v[31:24]; img[a+1] = v[23:16];
            img[a+2] = v[15:8];  img[a+3] = v[7:0];
        end
    endtask

    task put_pgc(input integer pa, input [7:0] npgms, input [7:0] ncells,
                 input [15:0] nxt, input [7:0] still,
                 input [15:0] cmd_off, input [15:0] pm_off, input [15:0] cpo);
        begin
            img[pa+2] = npgms;
            img[pa+3] = ncells;
            be16(pa+156, nxt);
            be16(pa+158, 16'd0);
            be16(pa+160, 16'd0);
            img[pa+162] = 8'h00;
            img[pa+163] = still;
            be16(pa+228, cmd_off);
            be16(pa+230, pm_off);
            be16(pa+232, cpo);
        end
    endtask

    task put_cell(input integer pa, input [15:0] cpo, input integer idx,
                  input [7:0] still, input [7:0] cmdnr,
                  input [31:0] first, input [31:0] last);
        integer c;
        begin
            c = pa + cpo + idx*24;
            img[c+2] = still;
            img[c+3] = cmdnr;
            be32(c+8,  first);
            be32(c+20, last);
        end
    endtask

    task put_cmdtbl(input integer pa, input [15:0] off,
                    input integer npre, input integer npost, input integer ncell,
                    input [63:0] c0, input [63:0] c1, input [63:0] c2);
        integer a; integer n;
        begin
            a = pa + off;
            be16(a+0, npre[15:0]);
            be16(a+2, npost[15:0]);
            be16(a+4, ncell[15:0]);
            be16(a+6, 16'd0);
            n = npre + npost + ncell;
            for (i = 0; i < 8; i = i + 1) img[a+8+i]  = c0[8*(7-i) +: 8];
            if (n > 1) for (i = 0; i < 8; i = i + 1) img[a+16+i] = c1[8*(7-i) +: 8];
            if (n > 2) for (i = 0; i < 8; i = i + 1) img[a+24+i] = c2[8*(7-i) +: 8];
        end
    endtask

    task put_ut(input integer sec, input [15:0] nsrp);
        integer base;
        begin
            base = sec*2048;
            be16(base+0, 16'd1);
            be32(base+4, 32'd1000);
            be16(base+8, 16'h656E);
            img[base+10] = 0; img[base+11] = 8'h80;
            be32(base+12, 32'd16);
            be16(base+16, nsrp);
            be32(base+20, 32'd2000);
        end
    endtask

    task put_srp(input integer sec, input integer idx,
                 input [7:0] entry_id, input [31:0] pgc_start);
        integer a;
        begin
            a = sec*2048 + 16 + 8 + idx*8;
            img[a] = entry_id;
            be32(a+4, pgc_start);
        end
    endtask

    // One sector = one REAL Program-Stream pack: 14-byte pack header (no
    // stuffing) + a video PES whose 2025 payload bytes all carry `tag`. Built
    // so ps_demux really demuxes instead of falling into raw-ES passthrough,
    // and so a tag count at its video output is a delivery count.
    task put_pack(input integer sec, input [7:0] tag);
        integer b; integer j;
        begin
            b = sec*2048;
            img[b+0] = 8'h00; img[b+1] = 8'h00; img[b+2] = 8'h01; img[b+3] = 8'hBA;
            img[b+4] = 8'h44;                       // '01' + SCR bits
            for (j = 5; j < 13; j = j + 1) img[b+j] = 8'h00;
            img[b+13] = 8'hF8;                      // reserved 11111, stuffing 0
            img[b+14] = 8'h00; img[b+15] = 8'h00; img[b+16] = 8'h01; img[b+17] = 8'hE0;
            be16(b+18, 16'(PAY + 3));               // PES_packet_length
            img[b+20] = 8'h80;                      // '10' marker
            img[b+21] = 8'h00;                      // no PTS/DTS
            img[b+22] = 8'h00;                      // PES_header_data_length
            for (j = 0; j < PAY; j = j + 1) img[b+23+j] = tag;
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
            put_rec(cur, 19, 6144, 8'h00, "VIDEO_TS.IFO;1", 14, cur);  // 19..21
            put_rec(cur, 22, 6144, 8'h00, "VTS_01_0.IFO;1", 14, cur);  // 22..24
            // menu VOB: sectors 25..45 (cell0, cell1 x12, cell2 x6, landing x2)
            put_rec(cur, 25, 21*2048, 8'h00, "VTS_01_0.VOB;1", 14, cur);
            put_rec(cur, 46, 2*2048,  8'h00, "VTS_01_1.VOB;1", 14, cur);

            // VMGI_MAT @19
            be32(19*2048+132, 32'd400);
            be32(19*2048+196, 32'd1);
            be32(19*2048+200, 32'd2);
            put_pgc(19*2048+400, 8'd0, 8'd0, 16'd0, 8'd0, 16'd236, 16'd0, 16'd0);
            put_cmdtbl(19*2048+400, 16'd236, 1, 0, 0,
                       64'h3002000000010000,        // JumpTT 1
                       64'd0, 64'd0);

            be16(20*2048+0, 16'd1);
            img[20*2048+14] = 8'd1;
            img[20*2048+15] = 8'd1;

            put_ut(21, 16'd1);
            put_srp(21, 0, 8'h82, 32'd64);
            put_pgc(21*2048+16+64, 8'd1, 8'd1, 16'd0, 8'd0, 16'd0, 16'd0, 16'd300);
            put_cell(21*2048+16+64, 16'd300, 0, 8'd0, 8'd0, 32'd0, 32'd0);

            be32(22*2048+204, 32'd1);
            be32(22*2048+208, 32'd2);

            // title VTS_PGCIT @23 (one 2-sector title cell; only a place to be
            // before the Menu key)
            be16(23*2048+0, 16'd1);
            img[23*2048+8] = 8'h81;
            be32(23*2048+8+4, 32'd32);
            put_pgc(23*2048+32, 8'd1, 8'd1, 16'd0, 8'd0, 16'd0, 16'd240, 16'd256);
            img[23*2048+32+240] = 8'd1;
            put_cell(23*2048+32, 16'd256, 0, 8'd0, 8'd0, 32'd0, 32'd1);

            // ---- VTSM PGCI_UT @24: the menu under test ----------------------
            put_ut(24, 16'd2);
            put_srp(24, 0, 8'h83, 32'd64);     // PGCN1 = the menu
            put_srp(24, 1, 8'h00, 32'd600);    // PGCN2 = the landing still
            // PGCN1: 3 pgms / 3 cells, pm {1,2,3}, POST = LinkPGCN 2,
            //        cell cmd 1 = LinkTailPGC, cell cmd 2 = LinkPGN 1
            // cells occupy cpo 256..327 (3 x 24), so the program map goes at
            // 240 and the command table at 336 - overlapping them silently
            // corrupts the cell table and the PGC simply loops.
            put_pgc(24*2048+16+64, 8'd3, 8'd3, 16'd0, 8'd0, 16'd336, 16'd240, 16'd256);
            img[24*2048+16+64+240] = 8'd1;
            img[24*2048+16+64+241] = 8'd2;
            img[24*2048+16+64+242] = 8'd3;
            put_cell(24*2048+16+64, 16'd256, 0, 8'd255, 8'd0, 32'd0,  32'd0);
            put_cell(24*2048+16+64, 16'd256, 1, 8'd0,   8'd1, 32'd1,  32'd12);
            put_cell(24*2048+16+64, 16'd256, 2, 8'd0,   8'd2, 32'd13, 32'd18);
            put_cmdtbl(24*2048+16+64, 16'd336, 0, 1, 2,
                       64'h2004000000000002,        // POST: LinkPGCN 2
                       64'h200100000000000D,        // cell cmd 1: LinkTailPGC
                       64'h2006000000000001);       // cell cmd 2: LinkPGN 1
            // PGCN2 @600: the landing still (2 sectors)
            put_pgc(24*2048+16+600, 8'd1, 8'd1, 16'd0, 8'd0, 16'd0, 16'd240, 16'd256);
            img[24*2048+16+600+240] = 8'd1;
            put_cell(24*2048+16+600, 16'd256, 0, 8'd255, 8'd0, 32'd19, 32'd20);

            // ---- payload packs ---------------------------------------------
            put_pack(25, TAG_C0);
            for (j = 0; j < C1_SECTORS; j = j + 1) put_pack(26 + j, TAG_C1);
            for (j = 0; j < C2_SECTORS; j = j + 1) put_pack(38 + j, TAG_C2);
            put_pack(44, TAG_LD);
            put_pack(45, TAG_LD);
            put_pack(46, TAG_TT);
            put_pack(47, TAG_TT);
        end
    endtask

    task fail(input [511:0] msg);
    begin
        $display("FAIL: %0s", msg);
        errors = errors + 1;
    end
    endtask

    task press_menu;
    begin
        @(posedge clk); key_menu <= 1'b1;
        @(posedge clk); key_menu <= 1'b0;
    end
    endtask

    // Re-enter the menu PGC for the next arm. A Menu KEY press from inside a
    // menu resumes the title (the menu<->title toggle), so the way back into
    // the menu domain is a user LinkPGCN 1 - which also parks us on cell 0,
    // the still, exactly as a real menu entry does.
    // Re-enter the menu for the next arm the way a user does: Menu resumes the
    // title (the menu<->title toggle), Menu again re-enters the VTSM Root - so
    // every arm starts from the same place, parked on the menu's first still.
    // ⚠ Waiting for "a menu still is up" alone is not enough: we are ALREADY
    // parked on one when this is called, so it would return instantly and the
    // next press would land while the reader is still parsing (cell_mode=0),
    // where it is dropped.
    task reenter_menu(input integer bound);
        integer t; integer tt0;
    begin
        tt0 = got[TAG_TT];
        press_menu;                               // menu -> title (LinkRSM)
        t = 0;
        while (got[TAG_TT] <= tt0 + 200 && t < bound) begin
            @(posedge clk); t = t + 1;
        end
        if (t >= bound) fail("could not resume the title");
        press_menu;                               // title -> VTSM Root
        t = 0;
        while (!(menu_active && still_active && cur_pgcn_rd == 8'd1) && t < bound)
        begin @(posedge clk); t = t + 1; end
        if (t >= bound) begin
            $display("   [dbg] reenter: menu=%0b still=%0b pgcn=%0d cell=%0d dstate=%0h",
                     menu_active, still_active, cur_pgcn_rd, cur_cell, dut.state);
            fail("could not re-enter the menu PGC");
        end
    end
    endtask

    task press_btn(input [63:0] cmd);
    begin
        @(posedge clk); btn_cmd <= cmd; btn_cmd_valid <= 1'b1;
        @(posedge clk); btn_cmd_valid <= 1'b0;
    end
    endtask

    // Wait until the title is streaming (the boot chain has landed).
    task wait_title(input integer bound);
        integer t; integer last;
    begin
        t = 0;
        while (got[TAG_TT] < 200 && t < bound) begin @(posedge clk); t = t + 1; end
        if (t >= bound) fail("the title never streamed");
    end
    endtask

    // Wait for the menu to be up and parked on its first (still) cell.
    task wait_menu(input integer bound);
        integer t;
    begin
        t = 0;
        while (!(menu_active && still_active) && t < bound) begin
            @(posedge clk); t = t + 1;
        end
        if (t >= bound) fail("menu never came up");
    end
    endtask

    // Wait until `tag` has stopped arriving for `quiet` cycles (the cell has
    // been fully delivered as far as the chain is concerned).
    task wait_tag_quiet(input [7:0] tag, input integer quiet, input integer bound);
        integer t; integer last; integer q;
    begin
        t = 0; q = 0; last = got[tag];
        while (q < quiet && t < bound) begin
            @(posedge clk); t = t + 1;
            if (got[tag] != last) begin last = got[tag]; q = 0; end
            else q = q + 1;
        end
    end
    endtask

    integer t;
    integer c1_before, jumps_before, seeks_before;

    initial begin
        for (k = 0; k < 256; k = k + 1) got[k] = 0;
        build_iso;
        file_size = 64*2048;
        #40 rst_n = 1;
        #40 start = 1;
        #20 start = 0;

        // ================= [A] DELIVERY =====================================
        // vbuf_empty stays 1 the whole way: the decoder's low-water mark can
        // never be what holds the gate, so anything the gate waits for is the
        // reader's own path. That is also the arm that kills "just use
        // vbuf_empty" - it passes only if the cache/pipe are in the condition.
        vbuf_empty = 1;
        throttle   = 1'b1;
        slow       = 1'b1;
        wait_title(600000);                 // boot: FP -> JumpTT 1 -> the title
        press_menu;                         // title -> VTSM Root (the menu)
        wait_menu(600000);
        if (cur_pgcn_rd !== 8'd1) fail("[A] did not land on the menu PGC");

        // the hub press: LinkPGN 2 = program 2 = cell 1, the transition clip
        jumps_before = n_jump_ack;
        press_btn(64'h2006000000000002);
        // cell 1 streams under the long-stall sink, ends, and its cell command
        // runs (LinkTailPGC -> POST -> LinkPGCN 2): the natural jump verdict,
        // which becomes pending while the cache is still draining in bursts.
        t = 0;
        while (n_jump_ack == jumps_before && t < 3000000) begin
            @(posedge clk); t = t + 1;
        end
        if (n_jump_ack == jumps_before) fail("[A] the natural jump never executed");
        watch_after = 1'b1;

        if (c1_at_jump !== C1_BYTES) begin
            $display("   [A] transition cell delivered %0d/%0d bytes before the jump",
                     c1_at_jump, C1_BYTES);
            fail("[A] the transition cell was CUT SHORT at the natural jump");
        end else
            $display("   [A] transition cell delivered %0d/%0d bytes before the jump  ok",
                     c1_at_jump, C1_BYTES);

        // ================= [B] keep_vbuf preserved ==========================
        if (kv_at_jump !== 1'b1)
            fail("[B] keep_vbuf was not held on the menu->menu jump");
        else
            $display("   [B] keep_vbuf=1 at the jump  ok");

        // the landing must be what arrives next, with no stale source byte
        t = 0;
        while (n_after_ack == 0 && t < 400000) begin @(posedge clk); t = t + 1; end
        if (first_after_ack !== TAG_LD) begin
            $display("   [A] first byte after the jump = %02h (want %02h)",
                     first_after_ack, TAG_LD);
            fail("[A] a stale byte reached the decoder after the jump");
        end else
            $display("   [A] first byte after the jump is the landing's  ok");
        watch_after = 1'b0;

        slow = 1'b0;

        // ================= [C] HOLD then RELEASE ============================
        // Re-enter the menu and run the same chain with the decoder NOT drained:
        // every byte reaches the chain and the verdict must still wait.
        vbuf_empty = 0;
        reenter_menu(600000);
        jumps_before = n_jump_ack;
        press_btn(64'h2006000000000002);
        wait_tag_quiet(TAG_C1, 20000, 3000000);
        if (n_jump_ack != jumps_before)
            fail("[C] the verdict executed while the decoder was not drained");
        else
            $display("   [C] verdict held with vbuf_empty=0  ok");
        if (!nat_wait_w) fail("[C] nat_wait_o was not asserted during the hold");
        vbuf_empty = 1;
        t = 0;
        while (n_jump_ack == jumps_before && t < 400000) begin
            @(posedge clk); t = t + 1;
        end
        if (n_jump_ack == jumps_before) fail("[C] raising vbuf_empty did not release");
        else $display("   [C] released when vbuf_empty rose  ok");

        // ================= [D] USER PREEMPTION ==============================
        // A button jump mid-cell must execute at once even with vbuf_empty=0 -
        // user actions never gate, and the gate must not have made them.
        vbuf_empty = 0;
        reenter_menu(600000);
        jumps_before = n_jump_ack;
        press_btn(64'h2006000000000002);    // into the transition cell
        c1_before = got[TAG_C1];
        t = 0;                              // let it get properly under way
        while (got[TAG_C1] < c1_before + 4000 && t < 2000000) begin
            @(posedge clk); t = t + 1;
        end
        press_btn(64'h2004000000000002);    // LinkPGCN 2 = a USER jump
        t = 0;
        while (n_jump_ack == jumps_before && t < 200000) begin
            @(posedge clk); t = t + 1;
        end
        if (n_jump_ack == jumps_before)
            fail("[D] a USER jump was gated (it must never be)");
        else
            $display("   [D] user jump executed immediately, %0d cycles  ok", t);

        // ================= [G] NATURAL SEEK =================================
        // Cell 2's command is LinkPGN 1 - a natural SEEK verdict. It must wait
        // for its own cell to be delivered exactly as the jump did.
        vbuf_empty = 1;
        reenter_menu(600000);
        seeks_before = n_seek_ack;
        press_btn(64'h2006000000000003);    // LinkPGN 3 = cell 2 (a USER seek)
        t = 0;                              // ...which is itself a seek_ack
        while (n_seek_ack == seeks_before && t < 600000) begin
            @(posedge clk); t = t + 1;
        end
        seeks_before = n_seek_ack;          // now wait for the CELL COMMAND's
        t = 0;
        while (n_seek_ack == seeks_before && t < 3000000) begin
            @(posedge clk); t = t + 1;
        end
        if (n_seek_ack == seeks_before) fail("[G] the natural seek never executed");
        else if (c2_at_seek !== C2_BYTES) begin
            $display("   [G] seek cell delivered %0d/%0d bytes before the seek",
                     c2_at_seek, C2_BYTES);
            fail("[G] the cell was CUT SHORT at the natural seek");
        end else
            $display("   [G] seek cell delivered %0d/%0d bytes before the seek  ok",
                     c2_at_seek, C2_BYTES);

        // ================= [F] WATCHDOG =====================================
        // vbuf_empty never rises: the verdict must still land, at DRAIN_WD.
        vbuf_empty = 0;
        reenter_menu(600000);
        jumps_before = n_jump_ack;
        press_btn(64'h2006000000000002);
        t = 0;
        while (n_jump_ack == jumps_before && t < 8*DRAIN_WD_TB) begin
            @(posedge clk); t = t + 1;
        end
        if (n_jump_ack == jumps_before)
            fail("[F] the watchdog never released the verdict");
        else
            $display("   [F] watchdog released the verdict  ok");

        $display("");
        $display("menudrain: got C0=%0d C1=%0d C2=%0d LD=%0d total=%0d",
                 got[TAG_C0], got[TAG_C1], got[TAG_C2], got[TAG_LD], got_total);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        if (errors != 0) $fatal(1, "iso_reader_menudrain_tb failed");
        $finish;
    end

    initial begin
        #900000000;
        $display("RESULT: TIMEOUT");
        $fatal(1, "iso_reader_menudrain_tb timeout");
    end

endmodule
