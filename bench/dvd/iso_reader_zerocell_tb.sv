// iso_reader_zerocell_tb.sv - THE_HOBBIT_UNEXPECTED_JOURNEY boot chain,
// end-to-end (dvd_iso_reader + dvd_vm wired as emu.sv wires them), with the
// disc's REAL command blocks and its defining pathology: ZERO-BACKED CELLS.
//
// The pressing authors cells whose sectors are literal zero-fill (bootleg
// padding; see docs/spec_hardening.md "Hobbit"). The authored boot chain
// routes THROUGH two of them:
//
//   FP pre {JumpTT 4}                                        (real bytes)
//     -> VTS_03 PGC1: cell0 REAL warning + cell1 ZERO,
//        pre {SetSTN; LinkCN 1}, POST {CallSS_VMGM_PGC 1}    (real bytes)
//     -> VMGM PGC1: 0-cell stub, pre {JumpSS_VTSM 1,1,3}     (real bytes)
//     -> VTS_01 VTSM PGC1 (Root): 11-cmd pre - round 1 (g6=0) dispatches
//        JumpVTS_TT 3                                        (real bytes)
//     -> VTS_01 TT PGC3: ONE ALL-ZERO cell, then the 34-command POST
//        settings trampoline: ...g[6]=1... CallSS_VMGM_PGC 1 (real bytes)
//     -> VMGM stub -> VTSM PGC1 pre round 2 (g6=1): LinkCN 1 = the menu
//        FINALLY plays, then loops on its last cell via POST LinkCN 3.
//
// A divergence anywhere loops the boot forever (the HW black screen) or
// wedges a state machine. The tb asserts each stage lands, the g6 flag is
// set, the menu bytes stream, and the jump count SETTLES (no infinite loop).
//
// Disc layout (2048-byte sectors):
//   16 PVD   17 root   18 VIDEO_TS dir
//   19 VIDEO_TS.IFO s0 = VMGI (fp@132=400 {JumpTT 4}; tt_srpt=+1; vmgm_ut=+2)
//   20 TT_SRPT: 4 titles (1,2,3)->VTS_01 ttn1..3, 4->VTS_03 ttn1
//   21 VMGM PGCI_UT: PGCN1 entry 0x82, 0-cell stub {JumpSS_VTSM 1,1,3}
//   22 VTS_01_0.IFO s0 = VTSI (@200=+1 PTT, @204=+2 PGCIT, @208=+3 VTSM UT)
//   23   VTS_PTT_SRPT: ttn1->{pgc1,pg1} ttn2->{pgc2,pg1} ttn3->{pgc3,pg1}
//   24   title PGCIT: PGC1 (movie, cell {0,0}=0xB0); PGC2 (cell {1,1}=0xB1);
//          PGC3: cell {2,2} = ZEROS + the real 34-cmd POST trampoline
//   25   VTSM PGCI_UT (LU[0] lang=0xFFFF wildcard, like the disc): PGCN1
//          entry 0x83, 3 cells {0,0}{1,1}{2,2}, real 11-cmd pre,
//          post {LinkCN 3}
//   26,27,28 VTS_01_0.VOB (menu: 0xD0 0xD1 0xD2)
//   30,31,32 VTS_01_1.VOB (movie 0xB0, 0xB1, RBN2 = ZEROS)
//   33 VTS_03_0.IFO s0 = VTSI (@200=+1 PTT, @204=+2 PGCIT)
//   34   VTS_PTT_SRPT: ttn1->{pgc1,pg1}
//   35   PGCIT: PGC1 2 cells {0,0} real + {1,1} ZERO,
//          pre {SetSTN SPSTN=0; LinkCN 1}, POST {CallSS_VMGM_PGC 1}
//   36,37 VTS_03_1.VOB (warning 0xE0, RBN1 = ZEROS)
//
// Run: iverilog -g2012 -o /tmp/zc dvd/dvd_iso_reader.sv dvd/dvd_vm.sv \
//        bench/dvd/iso_reader_zerocell_tb.sv && vvp /tmp/zc

`timescale 1ns/1ps

module iso_reader_zerocell_tb;

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
    wire [7:0]  cur_vts, best_menu_vts, cur_cell, cell_count_w;
    wire [15:0] cur_pgcn_rd;
    wire [7:0]  auto_vts_w, cur_cell_cmdnr_w;
    wire        cell_ready, nav_ready_w;
    wire [6:0]  res_ttn_w;
    wire [15:0] rd_next, rd_prev, rd_goup;
    wire        vm_cell_cmd_w, vm_pgc_end_w, vm_adv_w, vm_replay_w;
    wire        vm_jump_pulse;
    wire [1:0]  vm_jump_domain;
    wire [7:0]  vm_jump_vts, vm_jump_cell, vm_jump_pgn;
    wire [15:0] vm_jump_pgcn;
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
    wire        keep_vbuf_w, vm_from_wait_w, nat_wait_w;

    dvd_iso_reader #(.DRAIN_WD(31'd20000)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(4'd0), .lu_lang_pref(16'h656E), .vbuf_empty(1'b1), .menu_snap(1'b0),
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
        .key_menu(1'b0), .key_resume(1'b0), .key_title(1'b0), .key_return(1'b0),
        .btn_cmd(64'd0), .btn_cmd_valid(1'b0), .btn_sel(6'd1), .btns_armed(1'b0),
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

    // ---- stream capture + per-value tally ----
    integer cap_n = 0;
    integer n_e0 = 0, n_d0 = 0, n_d2 = 0, n_b0 = 0, n_zero = 0;
    always @(posedge clk)
        if (stream_valid) begin
            cap_n = cap_n + 1;
            case (stream_data)
            8'hE0: n_e0 = n_e0 + 1;
            8'hD0: n_d0 = n_d0 + 1;
            8'hD2: n_d2 = n_d2 + 1;
            8'hB0: n_b0 = n_b0 + 1;
            8'h00: n_zero = n_zero + 1;
            default: ;
            endcase
        end

    integer n_jump_ack = 0, n_pgc_end = 0;
    always @(posedge clk) begin
        if (jump_ack)     n_jump_ack = n_jump_ack + 1;
        if (vm_pgc_end_w) n_pgc_end  = n_pgc_end + 1;
    end

    // diagnostics (plusarg +TRACE): every VM dispatch + reader load event
    reg trace = 0;
    initial if ($test$plusargs("TRACE")) trace = 1;
    always @(posedge clk) if (trace) begin
        if (vm_jump_pulse)
            $display("[%0t] VM JUMP dom=%0d vts=%0d pgcn=%0d entry=%0d ttn=%0d ptt=%0d cell=%0d (g6=%0d g10=%0d)",
                     $time, vm_jump_domain, vm_jump_vts, vm_jump_pgcn,
                     vm_jump_entry, vm_jump_ttn, vm_jump_ptt, vm_jump_cell,
                     vm.gprm[6], vm.gprm[10]);
        if (vm_seek_pulse)
            $display("[%0t] VM SEEK cell=%0d", $time, vm_seek_cell);
        if (vm_replay_w)
            $display("[%0t] VM REPLAY", $time);
        if (vm_pgc_end_w)
            $display("[%0t] RD pgc_end (cur_vts=%0d cur_pgcn=%0d nr_post=%0d)",
                     $time, cur_vts, cur_pgcn_rd, nr_post_w);
        if (vm_cell_cmd_w)
            $display("[%0t] RD cell_cmd", $time);
        if (pgc_loaded)
            $display("[%0t] RD pgc_loaded vts=%0d pgcn=%0d cells=%0d nr_pre=%0d nr_post=%0d menu=%0d",
                     $time, cur_vts, cur_pgcn_rd, cell_count_w, nr_pre_w,
                     nr_post_w, menu_active);
        if (pgc_error)
            $display("[%0t] RD pgc_error", $time);
        if (jump_ack)
            $display("[%0t] RD jump_ack #%0d", $time, n_jump_ack);
    end

    // ---- mock HPS ----
    integer m = 0, bc = 0, lat = 0;
    reg [31:0] rlba = 0;
    always @(posedge clk) begin
        sd_buff_wr <= 1'b0;
        case (m)
        0: begin sd_ack <= 1'b0; if (sd_rd) begin rlba <= sd_lba; lat <= 3; m <= 1; end end
        1: begin if (lat != 0) lat <= lat-1; else begin sd_ack <= 1'b1; bc <= 0; m <= 2; end end
        2: begin sd_ack <= 1'b1; sd_buff_wr <= 1'b1; sd_buff_addr <= bc[13:0];
                 sd_buff_dout <= img[rlba*2048 + bc]; bc <= bc+1; if (bc==2047) m <= 3; end
        3: begin sd_ack <= 1'b0; sd_buff_wr <= 1'b0; m <= 0; end
        endcase
    end

    // ---- builders ----
    integer i, cur, errors = 0;

    task put_rec(input integer off, input [31:0] ext, input [31:0] dlen,
                 input [7:0] flags, input [127:0] nm, input integer nlen,
                 output integer next_off);
        integer j; integer rl;
        begin
            rl = 33 + nlen; if (rl[0]) rl = rl + 1;
            img[off+0] = rl[7:0]; img[off+1] = 0;
            img[off+2] = ext[7:0]; img[off+3] = ext[15:8];
            img[off+4] = ext[23:16]; img[off+5] = ext[31:24];
            for (j = 6; j < 10; j = j + 1) img[off+j] = 0;
            img[off+10] = dlen[7:0]; img[off+11] = dlen[15:8];
            img[off+12] = dlen[23:16]; img[off+13] = dlen[31:24];
            for (j = 14; j < 25; j = j + 1) img[off+j] = 0;
            img[off+25] = flags; img[off+26] = 0; img[off+27] = 0;
            for (j = 28; j < 32; j = j + 1) img[off+j] = 0;
            img[off+32] = nlen[7:0];
            for (j = 0; j < nlen; j = j + 1) img[off+33+j] = nm[8*(nlen-1-j) +: 8];
            if ((33+nlen) & 1) img[off+33+nlen] = 0;
            next_off = off + rl;
        end
    endtask

    task be16(input integer a, input [15:0] v);
        begin img[a] = v[15:8]; img[a+1] = v[7:0]; end
    endtask
    task be32(input integer a, input [31:0] v);
        begin img[a]=v[31:24]; img[a+1]=v[23:16]; img[a+2]=v[15:8]; img[a+3]=v[7:0]; end
    endtask

    task put_pgc(input integer pa, input [7:0] npgms, input [7:0] ncells,
                 input [15:0] cmd_off, input [15:0] pm_off, input [15:0] cpo);
        begin
            img[pa+2] = npgms; img[pa+3] = ncells;
            be16(pa+156, 16'd0); be16(pa+158, 16'd0); be16(pa+160, 16'd0);
            img[pa+163] = 8'd0;
            be16(pa+228, cmd_off); be16(pa+230, pm_off); be16(pa+232, cpo);
        end
    endtask

    task put_cell(input integer pa, input [15:0] cpo, input integer idx,
                  input [31:0] first, input [31:0] last);
        integer c;
        begin
            c = pa + cpo + idx*24;
            be32(c+8, first); be32(c+20, last);
        end
    endtask

    // command-table header + one command slot (arbitrary count)
    task put_cmdhdr(input integer pa, input [15:0] off,
                    input integer npre, input integer npost, input integer ncell);
        begin
            be16(pa+off+0, npre[15:0]);
            be16(pa+off+2, npost[15:0]);
            be16(pa+off+4, ncell[15:0]);
            be16(pa+off+6, 16'd0);
        end
    endtask
    task put_cmd(input integer pa, input [15:0] off, input integer idx,
                 input [63:0] c);
        integer j;
        begin
            for (j = 0; j < 8; j = j + 1)
                img[pa+off+8+idx*8+j] = c[8*(7-j) +: 8];
        end
    endtask

    task put_ut(input integer sec, input [15:0] lang, input [15:0] nsrp);
        integer base;
        begin
            base = sec*2048;
            be16(base+0, 16'd1);                 // nr_of_lus
            be32(base+4, 32'd1000);              // last_byte
            be16(base+8, lang);                  // LU[0] language code
            img[base+10] = 0; img[base+11] = 8'h80;
            be32(base+12, 32'd16);               // LU[0] start byte
            be16(base+16, nsrp);                 // PGCIT nr_of_pgci_srp
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

    // The real 34-command PGCN3 POST trampoline (see dvd_vm_tb S19).
    task put_trampoline_post(input integer pa, input [15:0] off);
        begin
            put_cmdhdr(pa, off, 0, 34, 0);
            put_cmd(pa, off, 0,  64'h00a1000600010009);
            put_cmd(pa, off, 1,  64'h00a100050001000d);
            put_cmd(pa, off, 2,  64'h6100000300920000);
            put_cmd(pa, off, 3,  64'h7100000500000000);
            put_cmd(pa, off, 4,  64'h71a0030500016672);
            put_cmd(pa, off, 5,  64'h71a0030500026573);
            put_cmd(pa, off, 6,  64'h4100000085000000);
            put_cmd(pa, off, 7,  64'h000100000000000d);
            put_cmd(pa, off, 8,  64'h00a100040001001a);
            put_cmd(pa, off, 9,  64'h00b1000b0001001a);
            put_cmd(pa, off, 10, 64'h4100008d00000000);
            put_cmd(pa, off, 11, 64'h000100000000001a);
            put_cmd(pa, off, 12, 64'h00a100040001001a);
            put_cmd(pa, off, 13, 64'h6100000300900000);
            put_cmd(pa, off, 14, 64'h7100000400000000);
            put_cmd(pa, off, 15, 64'h00a1000366720014);
            put_cmd(pa, off, 16, 64'h00a1000365730017);
            put_cmd(pa, off, 17, 64'h4100008400000000);
            put_cmd(pa, off, 18, 64'h000100000000001a);
            put_cmd(pa, off, 19, 64'h5100008100000000);
            put_cmd(pa, off, 20, 64'h51000000c3000000);
            put_cmd(pa, off, 21, 64'h000100000000001a);
            put_cmd(pa, off, 22, 64'h5100008200000000);
            put_cmd(pa, off, 23, 64'h51000000c4000000);
            put_cmd(pa, off, 24, 64'h000100000000001a);
            put_cmd(pa, off, 25, 64'h7100000300000000);
            put_cmd(pa, off, 26, 64'h7100000400000000);
            put_cmd(pa, off, 27, 64'h7100000500000000);
            put_cmd(pa, off, 28, 64'h7100000600010000);   // ★ g6 = 1
            put_cmd(pa, off, 29, 64'h7100000800000000);
            put_cmd(pa, off, 30, 64'h7100000b00000000);
            put_cmd(pa, off, 31, 64'h7100000e00000000);
            put_cmd(pa, off, 32, 64'h7100000700000000);
            put_cmd(pa, off, 33, 64'h3008000101c00000);   // CallSS_VMGM_PGC 1
        end
    endtask

    task build_iso;
        integer j;
        begin
            for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = 8'h00;

            // PVD @16
            img[32768] = 8'd1;
            img[32769]="C"; img[32770]="D"; img[32771]="0";
            img[32772]="0"; img[32773]="1"; img[32774]=8'd1;
            put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur);

            // root @17
            cur = 17*2048;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 18, 2048, 8'h02, "VIDEO_TS", 8, cur);

            // VIDEO_TS dir @18
            cur = 18*2048;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 19, 6144, 8'h00, "VIDEO_TS.IFO;1", 14, cur); // 19..21
            put_rec(cur, 22, 8192, 8'h00, "VTS_01_0.IFO;1", 14, cur); // 22..25
            put_rec(cur, 26, 6144, 8'h00, "VTS_01_0.VOB;1", 14, cur); // menu
            put_rec(cur, 30, 6144, 8'h00, "VTS_01_1.VOB;1", 14, cur); // movie
            put_rec(cur, 33, 6144, 8'h00, "VTS_03_0.IFO;1", 14, cur); // 33..35
            put_rec(cur, 36, 4096, 8'h00, "VTS_03_1.VOB;1", 14, cur); // warning

            // VMGI @19: FP @400 {JumpTT 4}; TT_SRPT=+1; VMGM_PGCI_UT=+2
            be32(19*2048+132, 32'd400);
            be32(19*2048+196, 32'd1);
            be32(19*2048+200, 32'd2);
            put_pgc(19*2048+400, 8'd0, 8'd0, 16'd236, 16'd0, 16'd0);
            put_cmdhdr(19*2048+400, 16'd236, 1, 0, 0);
            put_cmd(19*2048+400, 16'd236, 0, 64'h3002000000040000); // JumpTT 4

            // TT_SRPT @20: 4 titles
            be16(20*2048+0, 16'd4);
            img[20*2048+ 8+6] = 8'd1; img[20*2048+ 8+7] = 8'd1; // t1 -> VTS1 ttn1
            img[20*2048+20+6] = 8'd1; img[20*2048+20+7] = 8'd2; // t2 -> VTS1 ttn2
            img[20*2048+32+6] = 8'd1; img[20*2048+32+7] = 8'd3; // t3 -> VTS1 ttn3
            img[20*2048+44+6] = 8'd3; img[20*2048+44+7] = 8'd1; // t4 -> VTS3 ttn1

            // VMGM PGCI_UT @21: PGCN1 = 0-cell stub {JumpSS_VTSM vts1 t1 menu3}
            put_ut(21, 16'h656E, 16'd1);
            put_srp(21, 0, 8'h82, 32'd64);
            put_pgc(21*2048+16+64, 8'd0, 8'd0, 16'd236, 16'd0, 16'd0);
            put_cmdhdr(21*2048+16+64, 16'd236, 1, 0, 0);
            put_cmd(21*2048+16+64, 16'd236, 0, 64'h3006000101830000);

            // VTS_01 VTSI @22
            be32(22*2048+200, 32'd1);            // VTS_PTT_SRPT @23
            be32(22*2048+204, 32'd2);            // title PGCIT  @24
            be32(22*2048+208, 32'd3);            // VTSM PGCI_UT @25

            // VTS_01 PTT_SRPT @23: 3 titles, 1 PTT each
            be16(23*2048+0, 16'd3);
            be32(23*2048+4, 32'd31);             // last_byte
            be32(23*2048+8,  32'd20);            // ttu_offset[0]
            be32(23*2048+12, 32'd24);            // ttu_offset[1]
            be32(23*2048+16, 32'd28);            // ttu_offset[2]
            be16(23*2048+20, 16'd1); be16(23*2048+22, 16'd1);  // t1 -> pgc1 pg1
            be16(23*2048+24, 16'd2); be16(23*2048+26, 16'd1);  // t2 -> pgc2 pg1
            be16(23*2048+28, 16'd3); be16(23*2048+30, 16'd1);  // t3 -> pgc3 pg1

            // VTS_01 title PGCIT @24: PGC1@40 PGC2@400 PGC3@700
            be16(24*2048+0, 16'd3);
            img[24*2048+ 8] = 8'h81; be32(24*2048+ 8+4, 32'd40);
            img[24*2048+16] = 8'h82; be32(24*2048+16+4, 32'd400);
            img[24*2048+24] = 8'h83; be32(24*2048+24+4, 32'd700);
            // PGC1 = the movie head: 1 cell {0,0} = 0xB0
            put_pgc(24*2048+40, 8'd1, 8'd1, 16'd0, 16'd236, 16'd260);
            img[24*2048+40+236] = 8'd1;
            put_cell(24*2048+40, 16'd260, 0, 32'd0, 32'd0);
            // PGC2: 1 cell {1,1} = 0xB1
            put_pgc(24*2048+400, 8'd1, 8'd1, 16'd0, 16'd236, 16'd260);
            img[24*2048+400+236] = 8'd1;
            put_cell(24*2048+400, 16'd260, 0, 32'd1, 32'd1);
            // PGC3: the trampoline - ONE ALL-ZERO cell {2,2} + 34-cmd POST
            put_pgc(24*2048+700, 8'd1, 8'd1, 16'd240, 16'd236, 16'd528);
            img[24*2048+700+236] = 8'd1;
            put_trampoline_post(24*2048+700, 16'd240);
            put_cell(24*2048+700, 16'd528, 0, 32'd2, 32'd2);

            // VTSM PGCI_UT @25: LU[0] lang = 0xFFFF WILDCARD (the real disc)
            put_ut(25, 16'hFFFF, 16'd1);
            put_srp(25, 0, 8'h83, 32'd64);
            // PGCN1 (Root): 3 pgms/3 cells + real 11-cmd pre + post LinkCN 3
            put_pgc(25*2048+16+64, 8'd3, 8'd3, 16'd240, 16'd236, 16'd352);
            img[25*2048+16+64+236] = 8'd1;
            img[25*2048+16+64+237] = 8'd2;
            img[25*2048+16+64+238] = 8'd3;
            put_cmdhdr(25*2048+16+64, 16'd240, 11, 1, 0);
            put_cmd(25*2048+16+64, 16'd240, 0,  64'h00a100060000000b); // if g6==0 Goto 11
            put_cmd(25*2048+16+64, 16'd240, 1,  64'h00a1000b00000006); // if g11==0 Goto 6
            put_cmd(25*2048+16+64, 16'd240, 2,  64'h00a1000a0001000a); // if g10==1 Goto 10
            put_cmd(25*2048+16+64, 16'd240, 3,  64'h7100000a00010000); // g10 = 1
            put_cmd(25*2048+16+64, 16'd240, 4,  64'h2007000000000401); // LinkCN 1 (btn 1)
            put_cmd(25*2048+16+64, 16'd240, 5,  64'h6100000d00810000); // g13 = ASTN
            put_cmd(25*2048+16+64, 16'd240, 6,  64'h00a1000a0001000a); // if g10==1 Goto 10
            put_cmd(25*2048+16+64, 16'd240, 7,  64'h7100000a00010000); // g10 = 1
            put_cmd(25*2048+16+64, 16'd240, 8,  64'h2007000000000401); // LinkCN 1 (btn 1)
            put_cmd(25*2048+16+64, 16'd240, 9,  64'h2007000000000403); // LinkCN 3 (btn 1)
            put_cmd(25*2048+16+64, 16'd240, 10, 64'h3003000000030000); // JumpVTS_TT 3
            put_cmd(25*2048+16+64, 16'd240, 11, 64'h2007000000000003); // post: LinkCN 3
            put_cell(25*2048+16+64, 16'd352, 0, 32'd0, 32'd0);
            put_cell(25*2048+16+64, 16'd352, 1, 32'd1, 32'd1);
            put_cell(25*2048+16+64, 16'd352, 2, 32'd2, 32'd2);

            // VTS_03 VTSI @33
            be32(33*2048+200, 32'd1);            // PTT_SRPT @34
            be32(33*2048+204, 32'd2);            // PGCIT    @35

            // VTS_03 PTT_SRPT @34: 1 title, 1 PTT
            be16(34*2048+0, 16'd1);
            be32(34*2048+4, 32'd15);
            be32(34*2048+8, 32'd12);
            be16(34*2048+12, 16'd1); be16(34*2048+14, 16'd1);

            // VTS_03 PGCIT @35: PGC1 @32: 2 cells {0,0} real + {1,1} ZERO,
            // real pre {SetSTN SPSTN=0; LinkCN 1}, POST {CallSS_VMGM_PGC 1}
            be16(35*2048+0, 16'd1);
            img[35*2048+8] = 8'h81; be32(35*2048+8+4, 32'd32);
            put_pgc(35*2048+32, 8'd2, 8'd2, 16'd240, 16'd236, 16'd280);
            img[35*2048+32+236] = 8'd1;
            img[35*2048+32+237] = 8'd2;
            put_cmdhdr(35*2048+32, 16'd240, 2, 1, 0);
            put_cmd(35*2048+32, 16'd240, 0, 64'h5100000080000000); // SetSTN SPSTN=0
            put_cmd(35*2048+32, 16'd240, 1, 64'h2007000000000001); // LinkCN 1
            put_cmd(35*2048+32, 16'd240, 2, 64'h3008000101c00000); // post CallSS_VMGM
            put_cell(35*2048+32, 16'd280, 0, 32'd0, 32'd0);
            put_cell(35*2048+32, 16'd280, 1, 32'd1, 32'd1);

            // payload: menu 0xD0-0xD2; movie 0xB0/0xB1 (RBN2 = ZEROS);
            // warning 0xE0 (RBN1 = ZEROS)
            for (j = 0; j < 2048; j = j + 1) begin
                img[26*2048+j] = 8'hD0;
                img[27*2048+j] = 8'hD1;
                img[28*2048+j] = 8'hD2;
                img[30*2048+j] = 8'hB0;
                img[31*2048+j] = 8'hB1;
                img[36*2048+j] = 8'hE0;
            end
            // sectors 32 (movie RBN2) and 37 (warning RBN1) stay ZERO-FILLED
        end
    endtask

    task fail(input [511:0] msg);
    begin
        $display("FAIL: %0s", msg);
        errors = errors + 1;
    end
    endtask

    // wait for a condition-count with timeout
    task wait_jumps(input integer target, input [511:0] what);
        integer t;
    begin
        t = 0;
        while (n_jump_ack < target && t < 4000000) begin @(posedge clk); t = t+1; end
        if (n_jump_ack < target) fail(what);
    end
    endtask

    integer t, settle_jumps;
    initial begin
        build_iso; file_size = IMG_BYTES;
        repeat (5) @(negedge clk); rst_n = 1; repeat (5) @(negedge clk);
        start = 1; @(negedge clk); start = 0;

        // Stage 1: FP JumpTT 4 -> VTS_03 warning streams (0xE0)
        wait_jumps(1, "stage 1: FP JumpTT 4 never dispatched");
        t = 0;
        while (n_e0 == 0 && t < 4000000) begin @(posedge clk); t = t+1; end
        if (n_e0 == 0) fail("stage 1: VTS_03 warning cell (0xE0) never streamed");
        else $display("stage 1: FP -> VTS_03 warning streams  PASS (jumps=%0d)", n_jump_ack);

        // Stage 2: zero cell -> POST CallSS -> VMGM stub -> JumpSS ->
        // VTSM round 1 -> JumpVTS_TT 3 (jump #4)
        wait_jumps(4, "stage 2: chain stalled before JumpVTS_TT 3 (zero warning cell wedged?)");
        $display("stage 2: CallSS -> VMGM -> VTSM -> JumpVTS_TT 3  PASS (jumps=%0d)", n_jump_ack);

        // Stage 3: all-zero trampoline title -> 34-cmd POST -> g6=1 -> CallSS
        // -> VMGM -> JumpSS -> VTSM round 2 (jump #6)
        wait_jumps(6, "stage 3: chain stalled in the ALL-ZERO trampoline title");
        $display("stage 3: zero-cell trampoline -> POST -> back to VTSM  PASS (jumps=%0d)", n_jump_ack);

        // Stage 4: round-2 pre -> LinkCN 1 -> the menu plays (0xD0)
        t = 0;
        while (n_d0 == 0 && t < 4000000) begin @(posedge clk); t = t+1; end
        if (n_d0 == 0) fail("stage 4: menu (0xD0) never streamed after the trampoline");
        else $display("stage 4: menu streams after round-2 pre  PASS");
        if (vm.gprm[6] !== 16'd1) fail("stage 4: g6 != 1 after the trampoline POST");
        if (!menu_active) fail("stage 4: menu_active low while the menu streams");

        // Stage 5: menu parks looping (POST LinkCN 3 replays cell 2 = 0xD2)
        t = 0;
        while (n_d2 == 0 && t < 4000000) begin @(posedge clk); t = t+1; end
        if (n_d2 == 0) fail("stage 5: menu loop cell (0xD2) never streamed");
        // the jump count must SETTLE - no infinite boot loop
        settle_jumps = n_jump_ack;
        repeat (300000) @(posedge clk);
        if (n_jump_ack > settle_jumps + 1)
            fail("stage 5: jump count still rising - INFINITE BOOT LOOP");
        else $display("stage 5: menu parked looping, jumps settled at %0d  PASS", n_jump_ack);

        if (errors == 0) $display("ISO_READER_ZEROCELL_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_ZEROCELL_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin
        #400000000;
        $display("GLOBAL TIMEOUT: rd_state=%0d vm_state=%0d jumps=%0d pgc_ends=%0d cap=%0d e0=%0d d0=%0d zero=%0d",
                 dut.state, vm.state, n_jump_ack, n_pgc_end, cap_n, n_e0, n_d0, n_zero);
        $finish;
    end

endmodule
