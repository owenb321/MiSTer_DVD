// iso_reader_montage_tb.sv - END-TO-END repro of the MiB root-menu MONTAGE loop:
// dvd_iso_reader + dvd_vm over a synthetic disc whose menu PGC has the MiB shape
// (cell0 -> cell1 LinkPGN 3 -> cell2 LinkTopPG loop -> cell3 still255, program map
// [1..4]). The reader must LOOP cell 2 (vm_replay), never advancing to the still.
// Regression guard for the V_PGSCAN program-map off-by-one (dvd_vm.sv) that made
// LinkTopPG seek to cell3 -> park on the still -> black on HW.
//
// (was: iso_reader_vm_tb - Phase-4 END-TO-END test: dvd_iso_reader + dvd_vm)
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
// Disc layout (2048-byte sectors):
//   16 PVD    17 root    18 VIDEO_TS dir
//   19 VIDEO_TS.IFO s0 = VMGI_MAT (fp@132=400 -> FP PGC; tt_srpt@196=1 -> 20;
//                                  vmgm_pgci_ut@200=2 -> 21)
//   20 VIDEO_TS.IFO s1 = TT_SRPT (1 title -> VTS_01, vts_ttn 1)
//   21 VIDEO_TS.IFO s2 = VMGM PGCI_UT (PGCN1 entry 0x82, 1 cell {0,0})
//   22 VTS_01_0.IFO s0 = VTSI_MAT (vts_pgcit@204=1 -> 23; vtsm@208=2 -> 24)
//   23 VTS_01_0.IFO s1 = title VTS_PGCIT (SRP[0] entry 0x81 -> PGC@16:
//                        2 cells {0,0},{1,1}, pm {1,2}, POST = JumpSS VTSM)
//   24 VTS_01_0.IFO s2 = VTSM PGCI_UT (PGCN1 entry 0x83 @64 = 0-cell stub,
//                        pre {g13=0xAB; LinkPGCN 2}; PGCN2 @600: 2 cells
//                        {0,0},{1,1}, cell[1].cmd=1, cell cmd = LinkCN 2)
//   25,26 VTS_01_0.VOB (menu: 0xD0, 0xD1)    27,28 VTS_01_1.VOB (0xB0, 0xB1)
//   29 VIDEO_TS.VOB (0xC0)
//
// Run: iverilog -g2012 -o /tmp/rvm dvd/dvd_iso_reader.sv dvd/dvd_vm.sv \
//        bench/dvd/iso_reader_vm_tb.sv && vvp /tmp/rvm

`timescale 1ns/1ps

module iso_reader_montage_tb;

    localparam IMG_BYTES = 40*2048;

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
    wire [10:0] cmd_waddr_w;
    wire [7:0]  cmd_wdata_w, nr_pre_w, nr_post_w, nr_cell_w, nr_pgm_w;
    wire [6:0]  pm_waddr_w;
    wire [7:0]  pm_wdata_w;
    wire [7:0]  sprm_astn_w, sprm_spstn_w;
    wire [7:0]  vm_dbg;

    reg         key_menu = 0, key_resume = 0;
    // highest menu cell the reader ever loaded (must stay <= 2 = the loop cell;
    // reaching cell 3 = the still255 park = the V_PGSCAN off-by-one bug)
    integer dbg_maxcell = 0;
    always @(posedge clk) if (menu_active && dut.cell_i > dbg_maxcell) dbg_maxcell = dut.cell_i;

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(4'd0), .vbuf_empty(1'b0), .menu_snap(1'b0),
        .jump_ttn(vm_jump_ttn), .jump_pgn(vm_jump_pgn), .jump_ptt(vm_jump_ptt),
        .vm_mode(1'b1), .vm_adv(vm_adv_w), .vm_replay(vm_replay_w),
        .vm_cell_cmd(vm_cell_cmd_w), .vm_pgc_end(vm_pgc_end_w),
        .nav_ready_o(nav_ready_w), .auto_vts(auto_vts_w),
        .cell_count_o(cell_count_w), .res_ttn(res_ttn_w),
        .pm_we(pm_we_w), .pm_waddr(pm_waddr_w), .pm_wdata(pm_wdata_w),
        .cmd_nr_pgm(nr_pgm_w),
        .seek_pulse(vm_seek_pulse), .seek_natural(1'b0), .seek_cell(vm_seek_cell), .seek_ack(seek_ack),
        .cur_cell(cur_cell), .cell_ready(cell_ready),
        .jump_pulse(vm_jump_pulse), .jump_natural(1'b0), .jump_domain(vm_jump_domain),
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
        .clk(clk), .rst_n(rst_n), .enable(1'b1), .start(start),
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
        .btn_cmd(64'd0), .btn_cmd_valid(1'b0), .btn_sel(6'd1), .btns_armed(1'b0),
        .btn_force(), .btn_force_val(),
        .jump_pulse(vm_jump_pulse), .jump_domain(vm_jump_domain),
        .jump_vts(vm_jump_vts), .jump_pgcn(vm_jump_pgcn),
        .jump_entry(vm_jump_entry), .jump_ttn(vm_jump_ttn),
        .jump_pgn(vm_jump_pgn), .jump_cell(vm_jump_cell), .jump_ptt(vm_jump_ptt),
        .seek_pulse(vm_seek_pulse), .seek_cell(vm_seek_cell),
        .vm_replay(vm_replay_w), .vm_adv(vm_adv_w), .wait_hold(1'b0),
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
    integer n_jump_ack = 0, n_seek_ack = 0;
    always @(posedge clk) begin
        if (jump_ack) n_jump_ack = n_jump_ack + 1;
        if (seek_ack) n_seek_ack = n_seek_ack + 1;
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
            put_rec(cur, 34, 2048, 8'h00, "VIDEO_TS.VOB;1", 14, cur); // VMGM VOB
            put_rec(cur, 22, 6144, 8'h00, "VTS_01_0.IFO;1", 14, cur); // 22..24
            put_rec(cur, 25, 8192, 8'h00, "VTS_01_0.VOB;1", 14, cur); // menu VOB 25..28 (4 cells)
            put_rec(cur, 32, 4096, 8'h00, "VTS_01_1.VOB;1", 14, cur); // title 32..33

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

            // title VTS_PGCIT @23: SRP[0] entry 0x81 (TITLE 1) -> PGC @16:
            // 2 pgms/cells {0,0},{1,1}, pm {1,2}, POST = JumpSS VTSM(t1,menu3)
            be16(23*2048+0, 16'd1);
            img[23*2048+8] = 8'h81;               // SRP[0].entry_id (title 1)
            be32(23*2048+8+4, 32'd16);
            put_pgc(23*2048+16, 8'd2, 8'd2, 16'd0, 8'd0, 16'd320, 16'd240, 16'd256);
            img[23*2048+16+240] = 8'd1;           // pm[0] = cell 1
            img[23*2048+16+241] = 8'd2;           // pm[1] = cell 2
            put_cell(23*2048+16, 16'd256, 0, 8'd0, 8'd0, 32'd0, 32'd0);
            put_cell(23*2048+16, 16'd256, 1, 8'd0, 8'd0, 32'd1, 32'd1);
            // POST = JumpSS VTSM (vts 0 = current, title 1, menu 3):
            //   30 06 00 01 00 83 00 00
            put_cmdtbl(23*2048+16, 16'd320, 0, 1, 0,
                       64'h3006000100830000, 64'd0, 64'd0);

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
            // MONTAGE (MiB root PGCN5 shape): 4 cells, program map [1,2,3,4].
            //  cell0 cmd0 -> cell1 cmd2=LinkPGN 3 (->seek program3=cell2) ->
            //  cell2 cmd1=LinkTopPG (->replay cell2 = the loop). cell3 still255=park.
            //  Cells map to menu-VOB RBN 0..3 = disc sectors 25..28 (0xD0..0xD3).
            put_pgc(24*2048+16+600, 8'd4, 8'd4, 16'd0, 8'd0, 16'd320, 16'd400, 16'd256);
            img[24*2048+16+600+400]=8'd1; img[24*2048+16+600+401]=8'd2;
            img[24*2048+16+600+402]=8'd3; img[24*2048+16+600+403]=8'd4;
            put_cell(24*2048+16+600, 16'd256, 0, 8'd0,   8'd0, 32'd0, 32'd0);
            put_cell(24*2048+16+600, 16'd256, 1, 8'd0,   8'd2, 32'd1, 32'd1);
            put_cell(24*2048+16+600, 16'd256, 2, 8'd0,   8'd1, 32'd2, 32'd2);
            put_cell(24*2048+16+600, 16'd256, 3, 8'd255, 8'd0, 32'd3, 32'd3);
            put_cmdtbl(24*2048+16+600, 16'd320, 0, 0, 2,
                       64'h2001000000000005,      // CELL[1] LinkTopPG
                       64'h2006000000000003,      // CELL[2] LinkPGN 3
                       64'd0);

            // payload sectors
            for (j = 0; j < 2048; j = j + 1) begin
                img[25*2048+j] = 8'hD0;           // menu cell 1
                img[26*2048+j] = 8'hD1;           // menu cell 2
                img[27*2048+j] = 8'hD2;           // menu cell 2 (the loop cell)
                img[28*2048+j] = 8'hD3;           // menu cell 3 (still255 park)
                img[32*2048+j] = 8'hB0;           // title cell 1
                img[33*2048+j] = 8'hB1;           // title cell 2
                img[34*2048+j] = 8'hC0;           // VMGM cell
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

    task press_menu;
    begin
        @(negedge clk); key_menu = 1;
        @(negedge clk); key_menu = 0;
    end
    endtask

    integer t1_end, t2_end, t3_end, t4_end;
    integer j0, ja0, sa0;

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
        wait_bytes(4096);                 // both title sectors
        if (cap[0]    !== 8'hB0) fail("T1: first title byte != B0");
        if (cap[2048] !== 8'hB1) fail("T1: second title cell != B1");
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

        // ---------------- MONTAGE loop: cell 2 must REPLAY, not park ------
        // cell1 (LinkPGN 3) seeks to cell2; cell2 (LinkTopPG) must vm_replay and
        // loop cell2 (stream 0xD2 forever). The BUG advanced to cell3 (still255)
        // and parked (still_active) => black on HW. Assert: never parks, loops D2,
        // vm_replay fired, no jump/seek flush during the loop.
        ja0 = n_jump_ack; sa0 = n_seek_ack;
        begin : montage
            integer t; integer d2; integer replays;
            t=0; replays=0;
            for (t=0; t<300000; t=t+1) begin
                @(posedge clk);
                if (still_active) fail("MONTAGE: reader PARKED on a still (cell 2 LinkTopPG did not loop)");
                if (dbg_maxcell >= 3) fail("MONTAGE: reader advanced to cell 3 (LinkTopPG off-by-one)");
                if (vm_replay_w) replays = replays + 1;
            end
            d2=0;
            begin integer k;
              for (k=t2_end; k<cap_n; k=k+1) if (cap[k]==8'hD2) d2=d2+1;
            end
            if (dbg_maxcell != 2) fail("MONTAGE: reader did not settle on the loop cell 2");
            if (d2 < 4096)        fail("MONTAGE: loop cell 2 (0xD2) not replayed enough");
            if (replays < 2)      fail("MONTAGE: vm_replay did not fire (LinkTopPG not looping)");
            $display("MONTAGE loop: cell1 LinkPGN 3 -> cell2 LinkTopPG replay (x%0d), maxcell=%0d, no park  PASS (D2=%0d)",
                     replays, dbg_maxcell, d2);
        end
        if (n_jump_ack != ja0) fail("MONTAGE: loop caused a jump flush");

        if (errors == 0) $display("ISO_READER_MONTAGE_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_MONTAGE_TB: FAILED with %0d errors", errors);
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
