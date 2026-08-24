// iso_reader_vm_tb.sv - Phase-4 END-TO-END test: dvd_iso_reader + dvd_vm
// wired together exactly as emu.sv wires them (vm_mode=1), over a synthetic
// DVD-Video ISO whose NAV COMMANDS drive all navigation - the tb presses
// keys but never issues a jump itself.
//
//   T1  BOOT: mount -> the reader IDLES (no auto-play) -> the VM runs the
//       First Play PGC pre {g14=0x35; JumpTT 1} -> TT_SRPT resolve (title 1
//       -> VTS_01 vts_ttn 1) -> TITLE-entry scan (SRP entry 0x81) -> the
//       title streams (0xB0 then 0xB1). SPRM4=1, SPRM5=1, g14=0x35.
//   T2  MENU key during the title -> synthesized CallSS VTSM Root -> the
//       0-cell root stub's pre {g13=0xAB; LinkPGCN 2} EXECUTES (no reader
//       heuristic: vm_mode routes the stub through the VM) -> menu PGCN 2
//       streams (0xD0, 0xD1). RSM saved.
//   T3  MENU LOOP: menu cell 2 ends with cell_cmd 1 = LinkCN 2 -> the VM
//       answers vm_replay -> cell 2 (0xD1) streams AGAIN with NO flush
//       (no seek_ack/jump_ack during the loop).
//   T4  MENU key in the menu -> LinkRSM -> the title resumes at the saved
//       cell (menu_active drops, title bytes stream).
//   T5  TITLE END: the title plays out, the cache drains, vm_pgc_end ->
//       the POST block {JumpSS VTSM (title 1, menu 3)} runs -> back to the
//       menu with no key pressed.
//
// NATURAL-TRANSITION TAIL DRAIN (title-domain PGC end waits for vbuf_empty
// before dispatching vm_pgc_end, so the POST's keep_vbuf=0 jump can't flush
// the clip's buffered tail; DRAIN_WD bounds the wait). vbuf_empty is a
// driven reg, init 1 = "decoder always drained" (T1-T5 keep their exact
// pre-drain timing); DRAIN_WD is overridden small (20000 cycles).
//   T6  WAIT + RELEASE: resume the title, drop vbuf_empty. The title plays
//       out and the reader HOLDS (no vm_pgc_end, no menu). Raising
//       vbuf_empty releases the dispatch -> POST -> menu, keep_vbuf=0 on
//       the jump (flush semantics preserved against an empty buffer).
//   T7  USER PREEMPTION: same hold, then the MENU key mid-wait -> the jump
//       executes IMMEDIATELY (vbuf_empty still 0), vmw_pgc_pend cleared,
//       and the POST never ran (n_pgc_end unchanged) - user actions stay
//       snappy by construction.
//   T8  WATCHDOG: same hold, no key, vbuf_empty never rises -> dispatch
//       fires at the DRAIN_WD bound (old dispatch-with-flush behaviour,
//       never a deadlock) -> POST -> menu. (With the Phase-B wiring the
//       POST's own jump is ALSO natural-gated, so this exercises the
//       chained 2x-DRAIN_WD worst case: dispatch releases at the bound,
//       then the jump releases at the bound again.)
//
// PHASE B (cell-command tail drain): vm_from_wait / jump_natural /
// seek_natural / nat_wait_o are wired exactly as emu.sv wires them, so the
// title POST jumps of T5/T6/T8 now run through the natural-jump gate too
// (vbuf_empty=1 keeps T1-T5 bit-identical; T8 doubles its bound, see above).
//   T9  CELL-COMMAND JUMP GATED: button JumpVTS_TT 2 (title PGC2) executes
//       IMMEDIATELY with vbuf_empty=0 (user jumps never gate). PGC2 cell 1
//       ends with cell cmd LinkPGCN 1 -> the VM's jump verdict is NATURAL ->
//       the reader parks in S_VM_WAIT with the jump latched and gated
//       (nat_wait_o high), vmw_tmr AND the VM's V_WAIT wait_tmr frozen (no
//       spurious vm_adv: cell 2 must not stream). Raising vbuf_empty
//       executes the jump -> PGC1 replays -> POST -> menu.
//
// Disc layout (2048-byte sectors):
//   16 PVD    17 root    18 VIDEO_TS dir
//   19 VIDEO_TS.IFO s0 = VMGI_MAT (fp@132=400 -> FP PGC; tt_srpt@196=1 -> 20;
//                                  vmgm_pgci_ut@200=2 -> 21)
//   20 VIDEO_TS.IFO s1 = TT_SRPT (1 title -> VTS_01, vts_ttn 1)
//   21 VIDEO_TS.IFO s2 = VMGM PGCI_UT (PGCN1 entry 0x82, 1 cell {0,0})
//   22 VTS_01_0.IFO s0 = VTSI_MAT (vts_pgcit@204=1 -> 23; vtsm@208=2 -> 24)
//   23 VTS_01_0.IFO s1 = title VTS_PGCIT (SRP[0] entry 0x81 -> PGC1@32:
//                        2 cells {0,0},{1,1}, pm {1,2}, POST = JumpSS VTSM;
//                        SRP[1] entry 0x82 -> PGC2@400: 2 cells {0,0},{1,1},
//                        cell[0].cmd=1, cell cmd = LinkPGCN 1 - the Phase-B
//                        natural-jump vehicle, T9)
//   24 VTS_01_0.IFO s2 = VTSM PGCI_UT (PGCN1 entry 0x83 @64 = 0-cell stub,
//                        pre {g13=0xAB; LinkPGCN 2}; PGCN2 @600: 2 cells
//                        {0,0},{1,1}, cell[1].cmd=1, cell cmd = LinkCN 2)
//   25,26 VTS_01_0.VOB (menu: 0xD0, 0xD1)    27,28 VTS_01_1.VOB (0xB0, 0xB1)
//   29 VIDEO_TS.VOB (0xC0)
//
// Run: iverilog -g2012 -o /tmp/rvm dvd/dvd_iso_reader.sv dvd/dvd_vm.sv \
//        bench/dvd/iso_reader_vm_tb.sv && vvp /tmp/rvm

`timescale 1ns/1ps

module iso_reader_vm_tb;

    localparam IMG_BYTES = 32*2048;

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
    reg         busy = 0;

    reg  [7:0]  img [0:IMG_BYTES-1];

    // reader <-> VM wires (exactly the emu.sv wiring)
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

    reg         key_menu = 0, key_resume = 0;
    // Tail-drain: driven (init 1 = always-drained, T1-T5 unchanged); T6-T8
    // drop it to exercise the title-domain PGC-end wait.
    reg         vbuf_empty = 1;
    wire        keep_vbuf_w;
    // Phase-B provenance/gate wires (exactly the emu.sv wiring)
    wire        vm_from_wait_w;
    wire        nat_wait_w;
    // T6-T8 re-enter the title via an injected button command (JumpTT 1) -
    // the POST-entered menu has no RSM to resume from (JumpSS saves none).
    reg  [63:0] btn_cmd = 64'd0;
    reg         btn_cmd_valid = 0;

    dvd_iso_reader #(.DRAIN_WD(31'd20000)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(4'd0), .lu_lang_pref(16'h656E), .vbuf_empty(vbuf_empty), .menu_snap(1'b0),
        .keep_vbuf(keep_vbuf_w),
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
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .pal_we(), .pal_waddr(), .pal_wdata(),
        .debug_active(), .debug_sd_rd(), .debug_sd_ack(), .debug_cache_has_data(),
        .debug_file_size(), .debug_total_sectors(), .debug_next_lba(),
        .debug_state(), .debug_iso_mode(), .debug_iso_error()
    );

    dvd_vm vm (
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
        .key_menu(key_menu), .key_resume(key_resume), .key_title(1'b0), .key_return(1'b0),
        .btn_cmd(btn_cmd), .btn_cmd_valid(btn_cmd_valid), .btn_sel(6'd1), .btns_armed(1'b0),
        .btn_force(), .btn_force_val(),
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

    always #5 clk = ~clk;

    // ---- stream capture ----
    integer cap_n = 0;
    reg [7:0] cap [0:131071];
    always @(posedge clk)
        if (stream_valid) begin
            cap[cap_n] = stream_data;
            cap_n = cap_n + 1;
        end

    // ---- flush counters ----
    integer n_jump_ack = 0, n_seek_ack = 0, n_pgc_end = 0, n_adv = 0;
    reg kv_last = 1'bx;             // keep_vbuf sampled at the last jump_ack
    always @(posedge clk) begin
        if (jump_ack) begin
            n_jump_ack = n_jump_ack + 1;
            kv_last    = keep_vbuf_w;
        end
        if (seek_ack)      n_seek_ack = n_seek_ack + 1;
        if (vm_pgc_end_w)  n_pgc_end  = n_pgc_end + 1;
        if (vm_adv_w)      n_adv      = n_adv + 1;
    end

    // ---- mock HPS: serve one 2048-byte block (sector) per sd_rd ----
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

    // ---- image builders (iso_reader_menu_tb pattern) ----
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

    // PGC header (menu_tb's put_pgc + a program-map offset)
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

    // Command table: up to 3 commands laid out pre|post|cell contiguously.
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

    task build_iso;
        integer j;
        begin
            for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = 8'h00;

            // PVD @16
            img[32768] = 8'd1;
            img[32769] = "C"; img[32770] = "D"; img[32771] = "0";
            img[32772] = "0"; img[32773] = "1"; img[32774] = 8'd1;
            put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur);

            // root dir @17
            cur = 17*2048;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 18, 2048, 8'h02, "VIDEO_TS", 8, cur);

            // VIDEO_TS dir @18 (name-sorted)
            cur = 18*2048;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 19, 6144, 8'h00, "VIDEO_TS.IFO;1", 14, cur); // 19..21
            put_rec(cur, 31, 2048, 8'h00, "VIDEO_TS.VOB;1", 14, cur); // VMGM VOB
            put_rec(cur, 22, 6144, 8'h00, "VTS_01_0.IFO;1", 14, cur); // 22..24
            put_rec(cur, 25, 4096, 8'h00, "VTS_01_0.VOB;1", 14, cur); // menu VOB
            put_rec(cur, 27, 8192, 8'h00, "VTS_01_1.VOB;1", 14, cur); // title 27..30

            // VMGI_MAT @19: FP @400; TT_SRPT @+1 (20); VMGM_PGCI_UT @+2 (21)
            be32(19*2048+132, 32'd400);
            be32(19*2048+196, 32'd1);
            be32(19*2048+200, 32'd2);
            // FP PGC: 0 cells; pre = {g14 = 0x35, JumpTT 1}
            put_pgc(19*2048+400, 8'd0, 8'd0, 16'd0, 8'd0, 16'd236, 16'd0, 16'd0);
            put_cmdtbl(19*2048+400, 16'd236, 2, 0, 0,
                       64'h7100000E00350000,      // g[14] = 0x35
                       64'h3002000000010000,      // JumpTT 1
                       64'd0);

            // TT_SRPT @20: 1 title -> VTS_01, vts_ttn 1
            be16(20*2048+0, 16'd1);
            img[20*2048+14] = 8'd1;               // TT_SRP[0].title_set_nr
            img[20*2048+15] = 8'd1;               // TT_SRP[0].vts_ttn

            // VMGM PGCI_UT @21: PGCN1 entry 0x82, 1 cell {0,0} (0xC0)
            put_ut(21, 16'd1);
            put_srp(21, 0, 8'h82, 32'd64);
            put_pgc(21*2048+16+64, 8'd1, 8'd1, 16'd0, 8'd0, 16'd0, 16'd0, 16'd300);
            put_cell(21*2048+16+64, 16'd300, 0, 8'd0, 8'd0, 32'd0, 32'd0);

            // VTSI_MAT @22: vts_pgcit=+1 (23), vtsm_pgci_ut=+2 (24)
            be32(22*2048+204, 32'd1);
            be32(22*2048+208, 32'd2);

            // title VTS_PGCIT @23: SRP[0] entry 0x81 (TITLE 1) -> PGC1 @32:
            // 2 pgms/cells {0,0},{1,1}, pm {1,2}, POST = JumpSS VTSM(t1,menu3).
            // SRP[1] entry 0x82 (TITLE 2) -> PGC2 @400: 2 cells, cell[0] has
            // cell cmd 1 = LinkPGCN 1 (the Phase-B natural-jump vehicle, T9).
            // (PGC1 sits at 32, past SRP[1]'s bytes 16..23.)
            be16(23*2048+0, 16'd2);
            img[23*2048+8] = 8'h81;               // SRP[0].entry_id (title 1)
            be32(23*2048+8+4, 32'd32);
            img[23*2048+16] = 8'h82;              // SRP[1].entry_id (title 2)
            be32(23*2048+16+4, 32'd400);
            put_pgc(23*2048+32, 8'd2, 8'd2, 16'd0, 8'd0, 16'd320, 16'd240, 16'd256);
            img[23*2048+32+240] = 8'd1;           // pm[0] = cell 1
            img[23*2048+32+241] = 8'd2;           // pm[1] = cell 2
            put_cell(23*2048+32, 16'd256, 0, 8'd0, 8'd0, 32'd0, 32'd1);
            put_cell(23*2048+32, 16'd256, 1, 8'd0, 8'd0, 32'd2, 32'd3);
            // POST = JumpSS VTSM (vts 0 = current, title 1, menu 3):
            //   30 06 00 01 00 83 00 00
            put_cmdtbl(23*2048+32, 16'd320, 0, 1, 0,
                       64'h3006000100830000, 64'd0, 64'd0);
            // PGC2 @400: same two title cells; cell 1 carries cell cmd 1 =
            // LinkPGCN 1 -> a NATURAL title-domain jump verdict (BLK_CELL).
            put_pgc(23*2048+400, 8'd2, 8'd2, 16'd0, 8'd0, 16'd320, 16'd240, 16'd256);
            img[23*2048+400+240] = 8'd1;          // pm[0] = cell 1
            img[23*2048+400+241] = 8'd2;          // pm[1] = cell 2
            put_cell(23*2048+400, 16'd256, 0, 8'd0, 8'd1, 32'd0, 32'd1);
            put_cell(23*2048+400, 16'd256, 1, 8'd0, 8'd0, 32'd2, 32'd3);
            put_cmdtbl(23*2048+400, 16'd320, 0, 0, 1,
                       64'h2004000000000001,      // cell cmd 1: LinkPGCN 1
                       64'd0, 64'd0);

            // VTSM PGCI_UT @24: PGCN1 entry 0x83 @64 = 0-cell stub with pre
            // {g13=0xAB; LinkPGCN 2}; PGCN2 @600: 2 cells, cell[1].cmd = 1,
            // cell cmd 1 = LinkCN 2 (replay cell 2 = the menu loop)
            put_ut(24, 16'd2);
            put_srp(24, 0, 8'h83, 32'd64);
            put_srp(24, 1, 8'h00, 32'd600);
            put_pgc(24*2048+16+64, 8'd0, 8'd0, 16'd0, 8'd0, 16'd236, 16'd0, 16'd0);
            put_cmdtbl(24*2048+16+64, 16'd236, 2, 0, 0,
                       64'h7100000D00AB0000,      // g[13] = 0xAB
                       64'h2004000000000002,      // LinkPGCN 2
                       64'd0);
            put_pgc(24*2048+16+600, 8'd2, 8'd2, 16'd0, 8'd0, 16'd320, 16'd0, 16'd256);
            put_cell(24*2048+16+600, 16'd256, 0, 8'd0, 8'd0, 32'd0, 32'd0);
            put_cell(24*2048+16+600, 16'd256, 1, 8'd0, 8'd1, 32'd1, 32'd1);
            put_cmdtbl(24*2048+16+600, 16'd320, 0, 0, 1,
                       64'h2007000000000002,      // LinkCN 2
                       64'd0, 64'd0);

            // payload sectors
            for (j = 0; j < 2048; j = j + 1) begin
                img[25*2048+j] = 8'hD0;           // menu cell 1
                img[26*2048+j] = 8'hD1;           // menu cell 2
                img[27*2048+j] = 8'hB0;           // title cell 1 (2 sectors)
                img[28*2048+j] = 8'hB0;
                img[29*2048+j] = 8'hB1;           // title cell 2 (2 sectors)
                img[30*2048+j] = 8'hB1;
                img[31*2048+j] = 8'hC0;           // VMGM cell
            end
        end
    endtask

    task fail(input [511:0] msg);
    begin
        $display("FAIL: %0s", msg);
        errors = errors + 1;
    end
    endtask

    // wait until cap_n grows past `target` bytes (with a timeout)
    task wait_bytes(input integer target);
        integer t;
    begin
        t = 0;
        while (cap_n < target && t < 4000000) begin
            @(posedge clk);
            t = t + 1;
        end
        if (cap_n < target) fail("wait_bytes timeout");
    end
    endtask

    // wait for menu_active to rise (bounded)
    task wait_menu_up(input integer bound);
        integer t;
    begin
        t = 0;
        while (!menu_active && t < bound) begin
            @(posedge clk);
            t = t + 1;
        end
        if (!menu_active) fail("wait_menu_up timeout");
    end
    endtask

    task press_menu;
    begin
        @(negedge clk); key_menu = 1;
        @(negedge clk); key_menu = 0;
    end
    endtask

    task press_btn(input [63:0] cmd);
    begin
        @(negedge clk); btn_cmd = cmd; btn_cmd_valid = 1;
        @(negedge clk); btn_cmd_valid = 0;
    end
    endtask

    integer t1_end, t2_end, t3_end, t4_end;
    integer j0, ja0, sa0, pe0, c0;

    initial begin
        build_iso;
        file_size = IMG_BYTES;

        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (5) @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;

        // ---------------- T1: BOOT chain --------------------------------
        // The title is 8192 bytes (2 cells x 2 sectors) so it is still
        // MID-FLIGHT when T2 presses the menu key. (The old 2-sector title
        // had already played out by then; T2 only worked because the POST's
        // JumpSS_VTSM vts=0 ERRORED on the stale-vm_vts quirk and the
        // fallback replayed the title - the quirk is fixed now, so the POST
        // lands in the menu directly and the fixture must keep the title
        // honest instead.)
        wait_bytes(6144);                 // cell 1 + first sector of cell 2
        if (cap[0]    !== 8'hB0) fail("T1: first title byte != B0");
        if (cap[4096] !== 8'hB1) fail("T1: second title cell != B1");
        if (vm.gprm[14] !== 16'h0035) fail("T1: FP pre g14 != 0x35");
        if (vm.sprm4 !== 16'd1) fail("T1: SPRM4 (TTN) != 1");
        if (vm.sprm5 !== 16'd1) fail("T1: SPRM5 (VTS_TTN) != 1");
        if (menu_active) fail("T1: menu_active during the title");
        t1_end = cap_n;
        $display("T1 boot: FP -> JumpTT 1 -> TT_SRPT -> title streaming  PASS (cap=%0d)", t1_end);

        // ---------------- T2: MENU key -> stub -> menu ------------------
        press_menu;
        wait_bytes(t1_end + 4096);        // menu cells 0xD0 + 0xD1
        if (!menu_active) fail("T2: menu_active low");
        if (cap[t1_end]      !== 8'hD0 && cap[t1_end] !== 8'hB0 && cap[t1_end] !== 8'hB1)
            fail("T2: unexpected first byte after menu key");
        // find the first 0xD0 after t1_end (a few title bytes may still drain)
        begin : find_d0
            integer k;
            for (k = t1_end; k < cap_n; k = k + 1)
                if (cap[k] == 8'hD0) disable find_d0;
        end
        if (vm.gprm[13] !== 16'h00AB) fail("T2: stub pre g13 != 0xAB");
        if (vm.rsm_vts !== 8'd1) fail("T2: RSM not saved");
        t2_end = cap_n;
        $display("T2 menu key: CallSS -> stub pre LinkPGCN 2 -> menu  PASS (cap=%0d)", t2_end);

        // ---------------- T3: menu cell-command loop (vm_replay) --------
        ja0 = n_jump_ack; sa0 = n_seek_ack;
        wait_bytes(t2_end + 4096);        // two more loops of cell 2 (0xD1)
        begin : chk_loop
            integer k; integer d1s;
            d1s = 0;
            for (k = t2_end; k < cap_n; k = k + 1)
                if (cap[k] == 8'hD1) d1s = d1s + 1;
            if (d1s < 2048) fail("T3: menu loop did not replay 0xD1");
        end
        if (n_jump_ack != ja0) fail("T3: menu loop caused a jump flush");
        if (n_seek_ack != sa0) fail("T3: menu loop caused a seek flush");
        t3_end = cap_n;
        $display("T3 menu loop: LinkCN 2 -> vm_replay, no flush  PASS (cap=%0d)", t3_end);

        // ---------------- T4: MENU key in the menu -> RSM ---------------
        press_menu;
        wait_bytes(t3_end + 2048);
        begin : chk_resume
            integer k; integer bts;
            bts = 0;
            for (k = t3_end; k < cap_n; k = k + 1)
                if (cap[k] == 8'hB0 || cap[k] == 8'hB1) bts = bts + 1;
            if (bts < 1024) fail("T4: title did not resume");
        end
        if (menu_active) fail("T4: menu_active still high after resume");
        t4_end = cap_n;
        $display("T4 resume: LinkRSM -> title  PASS (cap=%0d)", t4_end);

        // ---------------- T5: title end -> POST -> menu -----------------
        // let the title play out; the POST JumpSS VTSM must bring the menu
        // back with NO key press
        begin : wait_menu
            integer t;
            t = 0;
            while (!menu_active && t < 6000000) begin
                @(posedge clk);
                t = t + 1;
            end
            if (!menu_active) fail("T5: POST did not re-enter the menu");
        end
        begin : chk_menu2
            integer k; integer ds; integer m0;
            m0 = cap_n;                    // count menu bytes from HERE (the
            wait_bytes(m0 + 1500);         // resume tail precedes the jump)
            ds = 0;
            for (k = m0; k < cap_n; k = k + 1)
                if (cap[k] == 8'hD0 || cap[k] == 8'hD1) ds = ds + 1;
            if (ds < 1024) fail("T5: menu bytes missing after POST jump");
        end
        if (vm.sprm5 !== 16'd1) fail("T5: SPRM5 != 1 after JumpSS VTSM");
        $display("T5 title end: drained -> POST JumpSS VTSM -> menu  PASS (cap=%0d)", cap_n);

        // The menu loop streams 0xD1 continuously, so byte counts are the
        // reliable sync: each JumpTT replay adds exactly 4096 title bytes
        // (0xB0 + 0xB1), after which the PGC end has dispatched its pend
        // (the parse precedes the byte delivery) and the cache is empty.
        wait_bytes(cap_n + 2048);          // menu loop live -> VM settled in V_IDLE

        // ---------------- T6: tail-drain WAIT + RELEASE -----------------
        // Replay the title with vbuf_empty=0: the title plays out, the
        // reader must HOLD the vm_pgc_end dispatch (POST would jump with
        // keep_vbuf=0 and flush the tail). Raising vbuf_empty releases it.
        vbuf_empty = 0;
        pe0 = n_pgc_end;
        c0  = cap_n;
        press_btn(64'h3002000000010000);   // button JumpTT 1 -> title replays
        wait_bytes(c0 + 8192);             // full title delivered = cache drained
        repeat (100) @(posedge clk);       // let the drain gate settle
        if (dut.tail_wait !== 1'b1) fail("T6: tail_wait not holding after the title played out");
        ja0 = dut.drain_tmr;
        begin : t6_hold
            integer t;
            for (t = 0; t < 4000; t = t + 1) begin
                @(posedge clk);
                if (menu_active)          fail("T6: menu appeared during the tail-drain hold");
                if (n_pgc_end != pe0)     fail("T6: vm_pgc_end dispatched during the hold");
            end
        end
        if (dut.drain_tmr <= ja0) fail("T6: drain_tmr not running during the hold");
        vbuf_empty = 1;                    // decoder tail displayed -> release
        wait_menu_up(2000000);
        if (n_pgc_end != pe0 + 1) fail("T6: release did not dispatch exactly one vm_pgc_end");
        if (kv_last !== 1'b0)     fail("T6: POST jump keep_vbuf != 0 (flush semantics changed)");
        $display("T6 tail drain: hold while !vbuf_empty -> release -> POST -> menu  PASS (cap=%0d)", cap_n);
        wait_bytes(cap_n + 2048);          // menu loop live -> VM settled

        // ---------------- T7: USER PREEMPTION mid-wait ------------------
        // Same hold; the MENU key must execute its jump IMMEDIATELY
        // (vbuf_empty still 0) and the POST must never run.
        vbuf_empty = 0;
        pe0 = n_pgc_end;
        c0  = cap_n;
        press_btn(64'h3002000000010000);   // button JumpTT 1 -> title replays
        wait_bytes(c0 + 8192);
        repeat (100) @(posedge clk);
        if (dut.tail_wait !== 1'b1) fail("T7: tail_wait not holding before the key press");
        if (menu_active) fail("T7: menu appeared before the key press");
        press_menu;                        // CallSS mid-wait -> immediate jump
        wait_menu_up(2000000);
        if (n_pgc_end != pe0)      fail("T7: POST ran despite the user preemption");
        repeat (5) @(posedge clk);         // timer clears 1 cycle after jump_go
        if (dut.drain_tmr != 0)    fail("T7: drain_tmr not cleared by the preempting jump");
        $display("T7 preemption: MENU key mid-hold -> immediate jump, POST skipped  PASS (cap=%0d)", cap_n);
        wait_bytes(cap_n + 2048);          // menu loop live -> VM settled

        // ---------------- T8: WATCHDOG bound ----------------------------
        // Same hold, no key, vbuf_empty never rises: dispatch must fire at
        // the DRAIN_WD bound (degrades to the old flush behaviour, never a
        // deadlock).
        vbuf_empty = 0;
        pe0 = n_pgc_end;
        c0  = cap_n;
        press_btn(64'h3002000000010000);   // button JumpTT 1 -> title replays
        wait_bytes(c0 + 8192);
        repeat (100) @(posedge clk);
        if (dut.tail_wait !== 1'b1) fail("T8: tail_wait not holding after the title played out");
        wait_menu_up(4000000);             // watchdog (2x 20000 cycles: dispatch
                                           // bound + the POST jump's own natural
                                           // gate re-arming the bound) must release
        if (n_pgc_end != pe0 + 1) fail("T8: watchdog did not dispatch vm_pgc_end");
        $display("T8 watchdog: DRAIN_WD bound releases dispatch + gated jump -> menu  PASS (cap=%0d)", cap_n);
        vbuf_empty = 1;
        // Settle to the menu LOOP by content class, not a raw byte count.
        // (The old stale-vm_vts quirk - title POST JumpSS_VTSM vts=0 erroring
        // after a JumpTT and fallback-replaying the title - is FIXED: the
        // vts=0 fallback now resolves through link_jump_vts, so the POST
        // lands on the menu directly. Content-class settling stays robust
        // either way.)
        begin : t9_settle
            integer seen; integer p; integer t;
            seen = 0; p = cap_n; t = 0;
            while (seen < 2048 && t < 6000000) begin
                @(posedge clk);
                while (p < cap_n) begin
                    if (cap[p] == 8'hD0 || cap[p] == 8'hD1) seen = seen + 1;
                    p = p + 1;
                end
                t = t + 1;
            end
            if (seen < 2048) fail("T9: menu loop never re-established after T8");
        end

        // ---------------- T9: Phase B - cell-command jump gated ---------
        // Button JumpVTS_TT 2 -> title PGC2. The BUTTON jump executes
        // immediately despite vbuf_empty=0 (user jumps never gate). PGC2
        // cell 1 ends with cell cmd LinkPGCN 1 -> the VM's jump verdict is
        // NATURAL -> latched + gated: reader parks in S_VM_WAIT, nat_wait_o
        // high, vmw_tmr and the VM's V_WAIT timer frozen, cell 2 (0xB1)
        // must NOT stream (no spurious advance). Raising vbuf_empty
        // executes the jump -> PGC1 replays -> POST -> menu.
        vbuf_empty = 0;
        pe0 = n_pgc_end;
        ja0 = n_jump_ack;
        sa0 = n_adv;
        press_btn(64'h3003000000020000);   // button JumpVTS_TT 2 -> PGC2
        begin : t9_btn_imm
            integer t;
            t = 0;                          // button jump must ack with vbuf_empty=0
            while (n_jump_ack == ja0 && t < 200000) begin
                @(posedge clk); t = t + 1;
            end
            if (n_jump_ack == ja0) fail("T9: button jump did not execute with vbuf_empty=0");
        end
        c0 = cap_n;   // jump_go cleared the cache: bytes from here = PGC2 cell 1
        begin : t9_wait_gate                // PGC2 cell 1 ends -> natural jump gated
            integer t;
            t = 0;
            while (!nat_wait_w && t < 2000000) begin
                @(posedge clk); t = t + 1;
            end
            if (!nat_wait_w) fail("T9: natural cell-cmd jump gate never armed");
        end
        j0 = dut.vmw_tmr; t4_end = vm.wait_tmr;
        begin : t9_hold
            integer t; integer k;
            for (t = 0; t < 4000; t = t + 1) begin
                @(posedge clk);
                if (n_jump_ack != ja0 + 1) fail("T9: gated jump executed during the hold");
                if (n_adv != sa0)          fail("T9: spurious vm_adv during the hold");
            end
            for (k = c0; k < cap_n; k = k + 1)
                if (cap[k] == 8'hB1) fail("T9: cell 2 streamed during the hold (spurious advance)");
        end
        if (dut.vmw_tmr != j0)    fail("T9: reader vmw_tmr not frozen during the gate");
        if (vm.wait_tmr != t4_end) fail("T9: VM wait_tmr not frozen during the gate (wait_hold)");
        vbuf_empty = 1;                    // tail displayed -> release the jump
        wait_menu_up(2000000);             // PGC1 replay -> POST -> menu
        if (n_jump_ack < ja0 + 2) fail("T9: released jump did not execute");
        begin : t9_title
            integer k; integer bts;
            bts = 0;
            for (k = c0; k < cap_n; k = k + 1)
                if (cap[k] == 8'hB0 || cap[k] == 8'hB1) bts = bts + 1;
            if (bts < 4096) fail("T9: PGC2 cell 1 + PGC1 replay bytes missing");
        end
        $display("T9 Phase B: cell-cmd jump gated on vbuf_empty, timers frozen, button immediate  PASS (cap=%0d)", cap_n);

        if (errors == 0) $display("ISO_READER_VM_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_VM_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin
        #400000000;
        $display("GLOBAL TIMEOUT");
        $display("  state=%0d vm_state=%0d cap_n=%0d menu=%b", dut.state,
                 vm.state, cap_n, menu_active);
        $finish;
    end

endmodule
