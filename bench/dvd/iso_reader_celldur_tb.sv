// iso_reader_celldur_tb.sv - AUTHORED CELL DURATION (real-player cell timing).
//
// A DVD cell's presentation lasts its authored playback time (C_PBTM) and ends
// when that time has elapsed ON THE DISPLAY TIMELINE - not when its sectors
// have been delivered. The motivating disc: Weakest Link VTS 8 PGC 51 cell 0,
// the quiz answer window - 311 sectors, pbtime = 17 s, still_time = 0, and the
// video ES holds exactly ONE I-frame. The reader delivered it in ~0.2 s, called
// the cell done and ran the cell command ("Too Late!") 1.5 s after the question
// appeared. See docs/dvd_nav.md "authored cell duration" + docs/disc_sweep.md
// "Round-6" (raising DRAIN_WD can NOT fix this: vbuf_empty is genuinely true).
//
// The fix under test: at a title-domain (vm_mode) cell end that dispatches to
// the VM (cell command / PGC end), unspent authored seconds (measured against
// the DISPLAY clock disp_tick/disp_fps since the cell loaded) are served as a
// TIMED STILL (the HW-proven Thayer machinery) before the dispatch. The plain
// mid-PGC advance stays seamless.
//
// Boots exactly like iso_reader_titlestill_tb (reader + dvd_vm, no tb jumps):
//   FP {g14=0x35; JumpTT 1} -> TT_SRPT -> title SRP entry 0x81 -> PGC@16:
//     cell 0: pbtime=17 s, still=0, cell_cmd_nr=1 (0xB0)  <-- the WL shape
//     cell 1: pbtime= 9 s, plain                  (0xB1)  <-- must NOT hold
//     cell 2: pbtime=10 s, still=0, cell_cmd_nr=2 (0xB2)  <-- elapsed credit
//     cell 3: pbtime= 6 s, plain, LAST            (0xB3)  <-- PGC-end hold
//     cell cmds 1/2 = Nop (VM answers vm_adv), POST = Nop
//
// T1: cell 0 delivers instantly (no display ticks elapsed) -> HOLDS as a timed
//     still with still_secs == 17 and the cell command does NOT run early.
// T2: on the timer the cell command runs, cell 1 then cell 2 stream; the
//     cell1 -> cell2 plain advance never raises still_active (no hitch).
// T3: cell 2's sector delivery is STALLED while 6 display-seconds tick by ->
//     the hold gets only the RESIDUAL: still_secs == 10 - 6 = 4.
// T4: cell 3 (last) ends with 6 s unspent -> PGC-end hold (STILL_PGEND), then
//     vm_pgc_end dispatches POST.
//
// T8-T10 (2026-08-25): the C_PBTM FRAME FIELD. Interactive discs author their
// short screens as "N s + (fps-1) frames" - Weakest Link's correct/wrong answer
// reveal and its money-banked screen are 1 s + 24 f @25 fps = 1.96 s. Dropping
// the frames stored 1 s, whose residual (1) sits under RESID_MIN, so those
// screens took NO hold at all and flashed by in ~0.2 s. Title 3 vectors it:
//     cell 0: pbtime 1 s + 24 f @25 fps, cmd 1  (0xB0) -> rounds to 2 s: HOLDS
//     cell 1: pbtime 1 s +  2 f @25 fps, cmd 2  (0xB1) -> stays 1 s: NO hold
//                                                         (sub-second cells on
//                                                          other discs unchanged)
//     cell 2: pbtime 3 s + 23 f @25 fps, last   (0xB2) -> rounds to 4 s: PGC-end
//
// SEC_DIV(1000): 1 hold-second = 1000 clk. disp_fps=4: 4 disp_ticks = 1
// display-second (the tb is the "raster").
//
// Run: iverilog -g2012 -o /tmp/rcd dvd/dvd_iso_reader.sv dvd/dvd_vm.sv \
//        dvd/bcd_time_add.sv bench/dvd/iso_reader_celldur_tb.sv && vvp /tmp/rcd

`timescale 1ns/1ps

module iso_reader_celldur_tb;

    localparam IMG_BYTES = 38*2048;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [63:0] file_size = 0;
    reg  [63:0] btn_cmd = 64'd0;
    reg         btn_cmd_valid = 0;

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

    // display clock model (the tb is the raster)
    reg         disp_tick = 0;

    // reader <-> VM wires (the emu.sv wiring)
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

    dvd_iso_reader #(.SEC_DIV(1000)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(4'd0),
        .vbuf_empty(1'b1), .menu_snap(1'b0),
        .disp_tick(disp_tick), .disp_fps(6'd4),
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
        .key_menu(1'b0), .key_resume(1'b0), .key_title(1'b0), .key_return(1'b0),
        .btn_cmd(btn_cmd), .btn_cmd_valid(btn_cmd_valid), .btn_sel(6'd1), .btns_armed(1'b0),
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

    // ---- stream capture + plain-advance hold monitor ----
    integer cap_n = 0;
    reg [7:0] cap [0:131071];
    reg saw_b1 = 0, saw_b2 = 0;
    reg plain_hold_viol = 0;
    reg frac_hold_viol = 0;      // T9: title-3 cell 1 must never hold
    always @(posedge clk) begin
        if (stream_valid) begin
            cap[cap_n] = stream_data;
            cap_n = cap_n + 1;
            if (stream_data == 8'hB1) saw_b1 = 1;
            if (stream_data == 8'hB2) saw_b2 = 1;
        end
        // the cell1 (plain, 9 s unspent) -> cell2 advance must never hold
        if (still_active && saw_b1 && !saw_b2) plain_hold_viol = 1;
        // T9: title 3's cell 1 (1 s + 2 f = 1.08 s, rounds DOWN to 1 s) must
        // stay under RESID_MIN - sub-second cells keep their no-hold behaviour.
        if (still_active && dut.cur_pgcn == 16'd3 && cur_cell == 8'd1)
            frac_hold_viol = 1;
    end

    // ---- event counters ----
    integer n_vm_cell_cmd = 0, n_vm_pgc_end = 0;
    always @(posedge clk) begin
        if (vm_cell_cmd_w) n_vm_cell_cmd = n_vm_cell_cmd + 1;
        if (vm_pgc_end_w)  n_vm_pgc_end  = n_vm_pgc_end + 1;
    end

    // ---- mock HPS: serve one 2048-byte block per sd_rd; a designated LBA
    //      can be STALLED (delivery parked) while display time ticks by ----
    reg         stall_en = 0;
    reg  [31:0] stall_lba = 32'hFFFFFFFF;
    integer m = 0;
    integer bc = 0;
    reg [31:0] rlba = 0;
    integer lat = 0;
    always @(posedge clk) begin
        sd_buff_wr <= 1'b0;
        case (m)
        0: begin
            sd_ack <= 1'b0;
            if (sd_rd && !(stall_en && sd_lba == stall_lba)) begin
                rlba <= sd_lba; lat <= 3; m <= 1;
            end
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

    // ---- image builders (iso_reader_titlestill_tb pattern) ----
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

    // pt = C_PBTM playback_time {hh, mm, ss, rate|frames}, BCD (@4..7)
    task put_cell(input integer pa, input [15:0] cpo, input integer idx,
                  input [7:0] still, input [7:0] cmdnr, input [31:0] pt,
                  input [31:0] first, input [31:0] last);
        integer c;
        begin
            c = pa + cpo + idx*24;
            img[c+2] = still;
            img[c+3] = cmdnr;
            img[c+4] = pt[31:24]; img[c+5] = pt[23:16];
            img[c+6] = pt[15:8];  img[c+7] = pt[7:0];
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

            // VIDEO_TS dir @18
            cur = 18*2048;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 19, 6144, 8'h00, "VIDEO_TS.IFO;1", 14, cur); // 19..21
            put_rec(cur, 34, 2048, 8'h00, "VIDEO_TS.VOB;1", 14, cur); // VMGM VOB
            put_rec(cur, 22, 6144, 8'h00, "VTS_01_0.IFO;1", 14, cur); // 22..24
            put_rec(cur, 25, 4096, 8'h00, "VTS_01_0.VOB;1", 14, cur); // menu VOB
            put_rec(cur, 27, 14336, 8'h00, "VTS_01_1.VOB;1", 14, cur); // title 27..33

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

            // TT_SRPT @20: 2 titles -> VTS_01 ttn 1 / ttn 2 (t2 = Phase-6
            // spec-max-duration vectors)
            be16(20*2048+0, 16'd3);
            img[20*2048+14] = 8'd1;               // TT_SRP[0].title_set_nr
            img[20*2048+15] = 8'd1;               // TT_SRP[0].vts_ttn
            img[20*2048+26] = 8'd1;               // TT_SRP[1].title_set_nr
            img[20*2048+27] = 8'd2;               // TT_SRP[1].vts_ttn
            img[20*2048+38] = 8'd1;               // TT_SRP[2].title_set_nr
            img[20*2048+39] = 8'd3;               // TT_SRP[2].vts_ttn (frame-field)

            // VMGM PGCI_UT @21: PGCN1 entry 0x82, 1 cell (unused here)
            put_ut(21, 16'd1);
            put_srp(21, 0, 8'h82, 32'd64);
            put_pgc(21*2048+16+64, 8'd1, 8'd1, 16'd0, 8'd0, 16'd0, 16'd0, 16'd300);
            put_cell(21*2048+16+64, 16'd300, 0, 8'd0, 8'd0, 32'd0, 32'd0, 32'd0);

            // VTSI_MAT @22: vts_pgcit=+1 (23)
            be32(22*2048+204, 32'd1);
            be32(22*2048+208, 32'd2);

            // title VTS_PGCIT @23: SRP[0] entry 0x81 -> PGC @16 (4 cells):
            //   cell 0: pbtime 17s, cmd 1  (0xB0)   the WL answer-window shape
            //   cell 1: pbtime  9s, plain  (0xB1)   plain advance: NO hold
            //   cell 2: pbtime 10s, cmd 2  (0xB2)   elapsed-credit case
            //   cell 3: pbtime  6s, plain  (0xB3)   last cell: PGC-end hold
            //   cmd tbl: post=1 (Nop), cell 1/2 (Nop); pm {1,2,3,4}
            be16(23*2048+0, 16'd3);
            img[23*2048+8] = 8'h81;               // SRP[0].entry_id (title 1)
            be32(23*2048+8+4, 32'd16);
            img[23*2048+16] = 8'h82;              // SRP[1].entry_id (title 2)
            be32(23*2048+16+4, 32'd700);
            img[23*2048+24] = 8'h83;              // SRP[2].entry_id (title 3)
            be32(23*2048+24+4, 32'd1100);
            put_pgc(23*2048+16, 8'd4, 8'd4, 16'd0, 8'd0, 16'd400, 16'd240, 16'd256);
            img[23*2048+16+240] = 8'd1;           // pm[0] = cell 1
            img[23*2048+16+241] = 8'd2;           // pm[1] = cell 2
            img[23*2048+16+242] = 8'd3;           // pm[2] = cell 3
            img[23*2048+16+243] = 8'd4;           // pm[3] = cell 4
            // BCD dvd_time = {hh, mm, ss, rate|frames}: 32'h000017C0 = 0:00:17
            put_cell(23*2048+16, 16'd256, 0, 8'd0, 8'd1, 32'h000017C0, 32'd0, 32'd0);
            put_cell(23*2048+16, 16'd256, 1, 8'd0, 8'd0, 32'h000009C0, 32'd1, 32'd1);
            put_cell(23*2048+16, 16'd256, 2, 8'd0, 8'd2, 32'h000010C0, 32'd2, 32'd2);
            put_cell(23*2048+16, 16'd256, 3, 8'd0, 8'd0, 32'h000006C0, 32'd3, 32'd3);
            put_cmdtbl(23*2048+16, 16'd400, 0, 1, 2,
                       64'd0, 64'd0, 64'd0);

            // title 2 PGC @700 - the Phase-6 >255 s vectors:
            //   cell 0: HEUR-shaped 10-MINUTE still (1 sector, lv==last,
            //           still=0, pbtime 0:10:00) -> the timed still must hold
            //           the FULL 600 s via the heur flag (byte clamps at 254)
            //   cell 1: plain, pbtime 9:59:59 = the C_PBTM SPEC MAX -> meta
            //           must store 35,999 s (plain advance never holds)
            //   cell 2: last, pbtime 2 s -> PGC-end residual hold (16-bit path)
            put_pgc(23*2048+700, 8'd3, 8'd3, 16'd0, 8'd0, 16'd400, 16'd236, 16'd256);
            img[23*2048+700+236] = 8'd1;          // pm {1,2,3}
            img[23*2048+700+237] = 8'd2;
            img[23*2048+700+238] = 8'd3;
            put_cell(23*2048+700, 16'd256, 0, 8'd0, 8'd0, 32'h001000C0, 32'd4, 32'd4);
            be32(23*2048+700+256+16, 32'd4);      // cell0 last_vobu_start = last (heur)
            put_cell(23*2048+700, 16'd256, 1, 8'd0, 8'd0, 32'h095959C0, 32'd5, 32'd5);
            put_cell(23*2048+700, 16'd256, 2, 8'd0, 8'd0, 32'h000002C0, 32'd6, 32'd6);
            put_cmdtbl(23*2048+700, 16'd400, 0, 1, 0,
                       64'd0, 64'd0, 64'd0);

            // title 3 PGC @1100 - the C_PBTM FRAME-FIELD vectors (T8-T10).
            // rate|frames byte: 2'b01 = 25 fps, so 0x64 = 24 frames (0.96 s),
            // 0x42 = 2 frames (0.08 s), 0x63 = 23 frames (0.92 s).
            //   cell 0: 1 s + 24 f = 1.96 s, cmd 1 -> stored 2 s -> HOLDS 2 s
            //   cell 1: 1 s +  2 f = 1.08 s, cmd 2 -> stored 1 s -> NO hold
            //   cell 2: 3 s + 23 f = 3.92 s, last  -> stored 4 s -> PGC-end 4 s
            put_pgc(23*2048+1100, 8'd3, 8'd3, 16'd0, 8'd0, 16'd400, 16'd236, 16'd256);
            img[23*2048+1100+236] = 8'd1;         // pm {1,2,3}
            img[23*2048+1100+237] = 8'd2;
            img[23*2048+1100+238] = 8'd3;
            put_cell(23*2048+1100, 16'd256, 0, 8'd0, 8'd1, 32'h00000164, 32'd0, 32'd0);
            put_cell(23*2048+1100, 16'd256, 1, 8'd0, 8'd2, 32'h00000142, 32'd1, 32'd1);
            put_cell(23*2048+1100, 16'd256, 2, 8'd0, 8'd0, 32'h00000363, 32'd2, 32'd2);
            put_cmdtbl(23*2048+1100, 16'd400, 0, 1, 2,
                       64'd0, 64'd0, 64'd0);

            // payload sectors
            for (j = 0; j < 2048; j = j + 1) begin
                img[25*2048+j] = 8'hD0;           // menu cell 1
                img[26*2048+j] = 8'hD1;           // menu cell 2
                img[27*2048+j] = 8'hB0;           // title cell 0 (17 s / cmd 1)
                img[28*2048+j] = 8'hB1;           // title cell 1 (plain)
                img[29*2048+j] = 8'hB2;           // title cell 2 (10 s / cmd 2)
                img[30*2048+j] = 8'hB3;           // title cell 3 (last, 6 s)
                img[31*2048+j] = 8'hB4;           // t2 cell 0 (heur 600 s)
                img[32*2048+j] = 8'hB5;           // t2 cell 1 (spec-max 9:59:59)
                img[33*2048+j] = 8'hB6;           // t2 cell 2 (last, 2 s)
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

    // pulse N display refreshes (disp_fps=4 -> 4 ticks = 1 display-second)
    task tick_disp(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(negedge clk); disp_tick = 1;
                @(negedge clk); disp_tick = 0;
                repeat (3) @(negedge clk);
            end
        end
    endtask

    integer t;
    integer cmark;

    initial begin
        build_iso;
        file_size = IMG_BYTES;

        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (5) @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;

        // ------------- T1: WL shape - data done, authored time not ---------
        // Cell 0 (17 s authored) delivers its single sector instantly with no
        // display ticks elapsed -> the reader must HOLD as a timed still with
        // the FULL residual (17 s) and must NOT run the cell command early.
        t = 0;
        while (cap_n < 2048 && t < 4000000) begin @(posedge clk); t = t + 1; end
        if (cap_n < 2048) fail("T1: title cell0 (0xB0) never streamed");
        if (cap[0] !== 8'hB0) fail("T1: first title byte != B0");

        t = 0;
        while (!still_active && t < 200000) begin @(posedge clk); t = t + 1; end
        $display("T1 hold: still_active=%b still_timed=%b secs=%0d next=%0d cell=%0d vm_cell_cmds=%0d",
                 still_active, dut.still_timed, dut.still_secs, dut.still_next,
                 cur_cell, n_vm_cell_cmd);
        if (!still_active)             fail("T1: WL-shape cell did NOT hold (cmd ran at data end)");
        if (dut.still_timed !== 1'b1)  fail("T1: hold is not a TIMED still");
        if (dut.still_secs !== 8'd17)  fail("T1: hold != full authored 17 s residual");
        if (dut.still_next !== 2'd1)   fail("T1: hold action != STILL_CMD");
        if (n_vm_cell_cmd != 0)        fail("T1: cell command ran BEFORE the authored end");
        if (cur_cell != 8'd0)          fail("T1: parked off cell 0");
        $display("T1 PASS: authored-duration hold (17 s residual, cmd deferred)");

        // ------------- T2: authored end -> cmd runs; plain advance seamless -
        // Arm the T3 stall BEFORE releasing: cell 2's sector (lba 29) parks
        // until 6 display-seconds have ticked.
        stall_lba = 32'd29;
        stall_en  = 1;
        cmark = cap_n;
        t = 0;
        while (n_vm_cell_cmd == 0 && t < 400000) begin @(posedge clk); t = t + 1; end
        if (n_vm_cell_cmd == 0) fail("T2: timer never ran the cell command");
        // cell 1 (0xB1) streams (plain, must not hold - monitored above)
        t = 0;
        while (cap_n < cmark + 2048 && t < 4000000) begin @(posedge clk); t = t + 1; end
        begin : chk_b1
            integer k; integer nb1;
            nb1 = 0;
            for (k = cmark; k < cap_n; k = k + 1) if (cap[k] == 8'hB1) nb1 = nb1 + 1;
            if (nb1 < 2048) fail("T2: cell1 (0xB1) did not stream after the timeout");
        end
        $display("T2 PASS: authored end -> cell command -> advanced to cell1");

        // ------------- T3: elapsed display time credits the hold -----------
        // Cell 2 (10 s authored) is loaded but its delivery is stalled; tick
        // 6 display-seconds (24 ticks @ disp_fps=4), then release. At cell end
        // the hold must be the RESIDUAL 10-6 = 4 s only.
        t = 0;
        while (!(sd_rd && sd_lba == 32'd29) && t < 400000) begin @(posedge clk); t = t + 1; end
        if (!(sd_rd && sd_lba == 32'd29)) fail("T3: cell2 request never parked on the stall");
        tick_disp(24);                       // 6 display-seconds
        stall_en = 0;                        // release delivery
        t = 0;
        while (!still_active && t < 4000000) begin @(posedge clk); t = t + 1; end
        $display("T3 hold: still_active=%b secs=%0d next=%0d cell=%0d",
                 still_active, dut.still_secs, dut.still_next, cur_cell);
        if (!still_active)             fail("T3: elapsed-credit cell did not hold");
        if (dut.still_secs !== 8'd4)   fail("T3: hold != residual 4 s (10 authored - 6 displayed)");
        if (dut.still_next !== 2'd1)   fail("T3: hold action != STILL_CMD");
        if (cur_cell != 8'd2)          fail("T3: parked off cell 2");
        $display("T3 PASS: display-elapsed time credited (4 s residual)");

        // ------------- T4: PGC-end hold then POST --------------------------
        // Cell 3 (last, 6 s authored, no cmd) ends with all 6 s unspent ->
        // PGC-end hold (STILL_PGEND), THEN vm_pgc_end dispatches POST.
        t = 0;
        while (!(still_active && cur_cell == 8'd3) && t < 4000000) begin @(posedge clk); t = t + 1; end
        $display("T4 hold: still_active=%b secs=%0d next=%0d pgc_ends=%0d",
                 still_active, dut.still_secs, dut.still_next, n_vm_pgc_end);
        if (!(still_active && cur_cell == 8'd3)) fail("T4: last cell did not hold at PGC end");
        if (dut.still_secs !== 8'd6)   fail("T4: hold != authored 6 s residual");
        if (dut.still_next !== 2'd2)   fail("T4: hold action != STILL_PGEND");
        if (n_vm_pgc_end != 0)         fail("T4: POST dispatched BEFORE the authored end");
        t = 0;
        while (n_vm_pgc_end == 0 && t < 400000) begin @(posedge clk); t = t + 1; end
        if (n_vm_pgc_end == 0) fail("T4: vm_pgc_end never dispatched after the hold");
        $display("T4 PASS: PGC-end hold then POST dispatch");

        if (plain_hold_viol) fail("cell1->cell2 plain advance raised still_active (hitch)");

        // ------------- T5-T7: Phase-6 spec-max duration widening ------------
        // Jump to title 2 (a button JumpTT 2 - the VM is idle after T4's POST).
        @(negedge clk); btn_cmd = 64'h3002000000020000; btn_cmd_valid = 1;
        @(negedge clk); btn_cmd_valid = 0;

        // T5: heuristic-shaped 10-MINUTE still cell: the hold must be the FULL
        // 600 s (the still BYTE clamps at 254; the stored heur flag routes the
        // 16-bit duration into still_secs).
        t = 0;
        while (!(still_active && cur_cell == 8'd0 && dut.menu_dom == 1'b0 &&
                 dut.cur_pgcn == 16'd2) && t < 4000000) begin
            @(posedge clk); t = t + 1;
        end
        $display("T5 hold: still_active=%b secs=%0d heur=%b dur=%0d",
                 still_active, dut.still_secs,
                 dut.cell_meta_mem[0][32], dut.cell_meta_mem[0][31:16]);
        if (!still_active)                        fail("T5: 600 s heuristic still never held");
        if (dut.still_secs !== 16'd600)           fail("T5: hold != full 600 s (byte-clamp leaked through)");
        if (dut.cell_meta_mem[0][32] !== 1'b1)    fail("T5: heur flag not stored");
        if (dut.cell_meta_mem[0][31:16] !== 16'd600) fail("T5: meta duration != 600");
        if (dut.cell_meta_mem[0][15:8] !== 8'd254)   fail("T5: heur still byte != 254 clamp");
        $display("T5 PASS: heuristic still holds the full 600 s (>255)");

        // T6: the SPEC-MAX cell (9:59:59): meta stores 35,999 s exactly, and
        // its plain advance never holds (the hold would blow the T7 wait).
        if (dut.cell_meta_mem[1][31:16] !== 16'd35999) fail("T6: spec-max C_PBTM != 35999 in meta");
        if (dut.cell_meta_mem[1][32] !== 1'b0)         fail("T6: plain cell wrongly heur-flagged");
        $display("T6 PASS: C_PBTM 9:59:59 captured as 35,999 s");

        // let the 600 s hold expire (600 hold-seconds x SEC_DIV) -> cells 1..2
        // stream -> T7: PGC-end residual hold (2 s) then POST.
        t = 0;
        while (!(still_active && cur_cell == 8'd2 && dut.still_next == 2'd2) &&
               t < 4000000) begin @(posedge clk); t = t + 1; end
        $display("T7 hold: still_active=%b secs=%0d next=%0d cell=%0d",
                 still_active, dut.still_secs, dut.still_next, cur_cell);
        if (!(still_active && cur_cell == 8'd2)) fail("T7: last t2 cell did not PGC-end hold");
        if (dut.still_secs !== 16'd2)            fail("T7: residual != 2 s");
        t = 0;
        while (n_vm_pgc_end < 2 && t < 400000) begin @(posedge clk); t = t + 1; end
        if (n_vm_pgc_end < 2) fail("T7: vm_pgc_end never dispatched after the hold");
        $display("T7 PASS: 16-bit residual machinery end-to-end (600 s hold -> spec-max meta -> PGC end)");

        // ------------- T8-T10: the C_PBTM FRAME FIELD ----------------------
        // Jump to title 3 (button JumpTT 3 - the VM is idle after T7's POST).
        @(negedge clk); btn_cmd = 64'h3002000000030000; btn_cmd_valid = 1;
        @(negedge clk); btn_cmd_valid = 0;

        // T8: the Weakest Link reveal shape - 1 s + 24 f @25 fps = 1.96 s. The
        // frames must round INTO the stored duration (2 s), or the residual (1)
        // sits under RESID_MIN and the screen flashes past with no hold at all.
        t = 0;
        while (!(still_active && dut.cur_pgcn == 16'd3 && cur_cell == 8'd0) &&
               t < 4000000) begin @(posedge clk); t = t + 1; end
        $display("T8 hold: still_active=%b secs=%0d next=%0d dur=%0d",
                 still_active, dut.still_secs, dut.still_next,
                 dut.cell_meta_mem[0][31:16]);
        if (!still_active)                        fail("T8: 1 s + 24 f cell did NOT hold (frames dropped)");
        if (dut.cell_meta_mem[0][31:16] !== 16'd2) fail("T8: meta duration != 2 s (frames not rounded in)");
        if (dut.still_secs !== 16'd2)             fail("T8: hold != 2 s");
        if (dut.still_next !== 2'd1)              fail("T8: hold action != STILL_CMD");
        $display("T8 PASS: 1 s + 24 f (1.96 s) holds 2 s - the WL answer-reveal shape");

        // T9: 1 s + 2 f = 1.08 s rounds DOWN -> stored 1 s -> no hold (checked
        // continuously by frac_hold_viol; the meta value is the direct proof).
        t = 0;
        while (!(dut.cur_pgcn == 16'd3 && cur_cell == 8'd1) && t < 4000000) begin
            @(posedge clk); t = t + 1;
        end
        if (dut.cell_meta_mem[1][31:16] !== 16'd1) fail("T9: 1 s + 2 f wrongly rounded UP");
        $display("T9 PASS: 1 s + 2 f stays 1 s (sub-second cells keep no-hold)");

        // T10: 3 s + 23 f = 3.92 s on the LAST cell -> 4 s PGC-end hold.
        t = 0;
        while (!(still_active && dut.cur_pgcn == 16'd3 && cur_cell == 8'd2) &&
               t < 4000000) begin @(posedge clk); t = t + 1; end
        $display("T10 hold: still_active=%b secs=%0d next=%0d dur=%0d",
                 still_active, dut.still_secs, dut.still_next,
                 dut.cell_meta_mem[2][31:16]);
        if (!still_active)                         fail("T10: last cell did not PGC-end hold");
        if (dut.cell_meta_mem[2][31:16] !== 16'd4) fail("T10: meta duration != 4 s");
        if (dut.still_secs !== 16'd4)              fail("T10: PGC-end hold != 4 s");
        if (dut.still_next !== 2'd2)               fail("T10: hold action != STILL_PGEND");
        if (frac_hold_viol) fail("T9: title-3 cell 1 (1.08 s) raised a hold");
        $display("T10 PASS: 3 s + 23 f (3.92 s) holds 4 s at PGC end");

        if (errors == 0) $display("ISO_READER_CELLDUR_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_CELLDUR_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin
        #400000000;
        $display("ISO_READER_CELLDUR_TB: TIMEOUT");
        $finish;
    end

endmodule
