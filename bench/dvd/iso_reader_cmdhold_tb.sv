// iso_reader_cmdhold_tb.sv - a title cell command waits for the displayed cell end
// while buttons are up (issue #176, docs/dvd_nav.md "A cell command with buttons up").
//
// Mad Dog McCree scores a shot with a CELL COMMAND: the shootout cell's buttons set
// g[0], and the cell command `if (g[0] != 21) LinkPTT 5` sends a miss to the death
// scene. The reader used to run that command when it finished READING the cell, ~a
// VBUF (~1.2 s) before the display got there, so a shot in the window's last 1.2 s
// was scored as a miss. The fix: with buttons up (cc_btns) the reader holds the
// dispatch through the PGC-end drain (cache empty, vbuf_empty, DRAIN_WD bound).
//
// Reader + dvd_vm, wired as emu.sv wires them (natural seek/jump provenance, nat_wait
// -> wait_hold). The tb drives cc_btns, vbuf_empty and busy, and is the raster.
//   FP {JumpTT 1}
//   Title 1 (PGC@16): PRE g[0] = 0; POST Nop
//     cell 0 (0xB0) cmd 1 = if (g[0] != 21) LinkCN 3   <- the Mad Dog shape
//     cell 1 (0xB1) cmd 2 = g[2] = 1                   <- "the next shootout"
//     cell 2 (0xB2) plain, last                        <- "shot dead"
//   Title 2 (PGC@700): POST Nop
//     cell 0 (0xB4) cmd 1 = g[1] = 1
//     cell 1 (0xB5) cmd 2 = Nop
//     cell 2 (0xB6) cmd 3 = LinkTopC                   <- an in-title loop
//   Title 3 (PGC@1400): POST Nop
//     cell 0 (0xB7) cmd_nr 5 (past nr_cell: invalid)
//     cell 1 (0xB8) cmd 1 = LinkTailPGC
// Every cell is two sectors with last_vobu_start = first_sector and 1 s of playback:
// one sector, or last_vobu_start = last_sector, makes a libdvdnav HEURISTIC still,
// and 1 s is under RESID_MIN, so neither still path can take the cell end.
//
// Arms (each named in the PASS/FAIL lines; run_cmd_hold.sh mutates the reader and
// requires each mutation to fail exactly its own arms):
//   A1 buttons up, no press: the command does NOT run while the VBUF holds the
//      cell's tail; it runs once vbuf_empty rises, and the miss branch plays (B2).
//   A2 buttons up, a press DURING the hold (g[0] = 21): the command sees it, the
//      hit branch plays (B1 follows B0).
//   B  no buttons: a cell command dispatches at once, with the VBUF still full
//      (movies keep their seamless mid-title GPRM commands).
//   C  the hold also waits for the reader's own cache (busy holds it full) even
//      with vbuf_empty high.
//   D  a jump during the hold (button JumpTT 2) clears it: no stale latch.
//   E  a decoder that never drains: DRAIN_WD releases the hold (never a deadlock).
//   P1 a FIXED command (Nop) runs at once with buttons up and the VBUF full.
//   P2 a fixed loop (LinkTopC) replays with no hold: in-title loops stay gapless.
//   P3 LinkTailPGC is held: it lands in POST, which reads registers.
//   P4 a cmd_nr past the PGC's cell commands is not held (no stale fx_mem bit).
//   F  the audio ring runs low (cc_aud_low) during a hold with the VBUF still full:
//      the hold releases, so the reader resumes before the old audio runs dry
//      (Mad Dog's saloon: back-to-back short scoring cells lost the gunshot).
//
// Run: bench/dvd/run_cmd_hold.sh [--red]

`timescale 1ns/1ps

module iso_reader_cmdhold_tb;

    localparam IMG_BYTES = 46*2048;
    localparam [30:0] DRAIN_WD_TB = 31'd200000;

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
    reg         cc_btns = 0;
    reg         vbuf_empty = 1;
    reg         cc_aud_low = 0;

    reg  [7:0]  img [0:IMG_BYTES-1];

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
    wire        vm_from_wait_w, nat_wait_w;
    wire        ptt_upd_w;
    wire [10:0] ptt_cur_w;

    dvd_iso_reader #(.SEC_DIV(1000), .DRAIN_WD(DRAIN_WD_TB)) dut (
        .cc_btns(cc_btns), .cc_aud_low(cc_aud_low),
        .ptt_upd(ptt_upd_w), .ptt_cur(ptt_cur_w),
        .agl_vm(4'd0), .agl_vm_en(1'b0), .vm_pre_done(1'b0),
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(7'd0),
        .aud_drained(1'b1), .vbuf_empty(vbuf_empty),
        .disp_tick(1'b0), .disp_fps(6'd4),
        .jump_ttn(vm_jump_ttn), .jump_pgn(vm_jump_pgn), .jump_ptt(vm_jump_ptt),
        .still_off(1'b0), .vm_mode(1'b1), .vm_adv(vm_adv_w), .vm_replay(vm_replay_w),
        .vm_cell_cmd(vm_cell_cmd_w), .vm_pgc_end(vm_pgc_end_w), .nat_wait_o(nat_wait_w),
        .nav_ready_o(nav_ready_w), .auto_vts(auto_vts_w),
        .cell_count_o(cell_count_w), .res_ttn(res_ttn_w),
        .pm_we(pm_we_w), .pm_waddr(pm_waddr_w), .pm_wdata(pm_wdata_w),
        .cmd_nr_pgm(nr_pgm_w),
        .seek_pulse(vm_seek_pulse), .seek_natural(vm_seek_pulse & vm_from_wait_w),
        .seek_cell(vm_seek_cell), .seek_ack(seek_ack),
        .cur_cell(cur_cell), .cell_ready(cell_ready),
        .jump_pulse(vm_jump_pulse), .jump_natural(vm_from_wait_w), .jump_domain(vm_jump_domain),
        .jump_vts(vm_jump_vts), .jump_pgcn(vm_jump_pgcn),
        .jump_entry(vm_jump_entry), .jump_cell(vm_jump_cell),
        .jump_ack(jump_ack), .pgc_loaded(pgc_loaded), .pgc_error(pgc_error),
        .menu_active(menu_active), .still_active(still_active), .cur_vts(cur_vts),
        .cur_pgcn_o(cur_pgcn_rd),
        .best_menu_vts(best_menu_vts),
        .menu_btns_armed(1'b0),
        .cmd_we(cmd_we_w), .cmd_waddr(cmd_waddr_w), .cmd_wdata(cmd_wdata_w),
        .cmd_nr_pre(nr_pre_w), .cmd_nr_post(nr_post_w), .cmd_nr_cell(nr_cell_w),
        .next_pgcn(rd_next), .prev_pgcn(rd_prev),
        .goup_pgcn(rd_goup),
        .cur_cell_cmdnr(cur_cell_cmdnr_w),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .pal_we(), .pal_waddr(), .pal_wdata(),
        .debug_active(),
        .debug_iso_mode()
    );

    dvd_vm vm (
        .cfg_lang(16'h656E), .cfg_sprm14(16'h0100), .cfg_sprm15(16'h7CFC), .cfg_sprm20(16'h0001),
        .agl_set(1'b0), .agl_set_val(4'd1),
        .ptt_upd(ptt_upd_w), .ptt_val(ptt_cur_w),
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
        .key_menu(1'b0), .key_title(1'b0), .key_return(1'b0), .key_cmenu(1'b0),
        .key_chedge(1'b0), .key_chedge_dir(1'b0),
        .btn_cmd(btn_cmd), .btn_cmd_valid(btn_cmd_valid), .btn_sel(6'd1), .btns_armed(1'b0),
        .btn_force(), .btn_force_val(),
        .jump_pulse(vm_jump_pulse), .jump_domain(vm_jump_domain),
        .jump_vts(vm_jump_vts), .jump_pgcn(vm_jump_pgcn),
        .jump_entry(vm_jump_entry), .jump_ttn(vm_jump_ttn),
        .jump_pgn(vm_jump_pgn), .jump_cell(vm_jump_cell), .jump_ptt(vm_jump_ptt),
        .seek_pulse(vm_seek_pulse), .seek_cell(vm_seek_cell),
        .vm_replay(vm_replay_w), .vm_adv(vm_adv_w), .wait_hold(nat_wait_w),
        .vm_from_wait(vm_from_wait_w),
        .sprm_astn(sprm_astn_w), .sprm_spstn(sprm_spstn_w),
        .dbg_state(vm_dbg)
    );

    always #5 clk = ~clk;

    // ---- stream capture: the ORDER of the payload cells is the verdict ----
    // seq[] records each new payload byte value as it starts (B0, B1, ...).
    integer cap_n = 0;
    reg [7:0] last_b = 8'h00;
    reg [7:0] seq [0:63];
    integer seq_n = 0;
    always @(posedge clk) begin
        if (stream_valid) begin
            cap_n = cap_n + 1;
            if (stream_data != last_b) begin
                seq[seq_n] = stream_data;
                seq_n = seq_n + 1;
                last_b = stream_data;
            end
        end
    end

    integer n_cc = 0, n_pe = 0, n_rep = 0;
    reg pend_seen = 0;                      // the hold latched since the arm cleared it
    always @(posedge clk) begin
        if (vm_cell_cmd_w) n_cc = n_cc + 1;
        if (vm_pgc_end_w)  n_pe = n_pe + 1;
        if (vm_replay_w)   n_rep = n_rep + 1;
        if (dut.vmw_cmd_pend) pend_seen = 1;
    end

    // ---- mock HPS: one 2048-byte block per sd_rd ----
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

    // ---- image builders (iso_reader_celldur_tb pattern) ----
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
                 input [15:0] cmd_off, input [15:0] pm_off, input [15:0] cpo);
        begin
            img[pa+2] = npgms;
            img[pa+3] = ncells;
            be16(pa+156, 16'd0);
            be16(pa+158, 16'd0);
            be16(pa+160, 16'd0);
            img[pa+162] = 8'h00;
            img[pa+163] = 8'h00;
            be16(pa+228, cmd_off);
            be16(pa+230, pm_off);
            be16(pa+232, cpo);
        end
    endtask

    // a two-sector cell at title-VOB sector `sec`: last_vobu_start = first_sector
    task put_cell(input integer pa, input [15:0] cpo, input integer idx,
                  input [7:0] cmdnr, input [31:0] sec);
        integer c;
        begin
            c = pa + cpo + idx*24;
            img[c+2] = 8'd0;                       // no still
            img[c+3] = cmdnr;
            be32(c+4, 32'h000001C0);               // 0:00:01 @30 fps: under RESID_MIN
            be32(c+8,  sec);
            be32(c+16, sec);                       // last VOBU starts at the first sector
            be32(c+20, sec + 32'd1);
        end
    endtask

    // command table: up to 4 commands, laid out pre, post, cell in order
    task put_cmdtbl(input integer pa, input [15:0] off,
                    input integer npre, input integer npost, input integer ncell,
                    input [63:0] c0, input [63:0] c1, input [63:0] c2, input [63:0] c3);
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
            if (n > 3) for (i = 0; i < 8; i = i + 1) img[a+32+i] = c3[8*(7-i) +: 8];
        end
    endtask

    localparam [63:0] C_NOP      = 64'h0000000000000000;
    localparam [63:0] C_G0_0     = 64'h7100000000000000;   // g[0] = 0
    localparam [63:0] C_G0_21    = 64'h7100000000150000;   // g[0] = 21 (the shot)
    localparam [63:0] C_SCORE    = 64'h20B7000000150003;   // if (g[0] != 21) LinkCN 3
    localparam [63:0] C_JUMPTT1  = 64'h3002000000010000;
    localparam [63:0] C_JUMPTT2  = 64'h3002000000020000;
    localparam [63:0] C_JUMPTT3  = 64'h3002000000030000;
    localparam [63:0] C_G1_1     = 64'h7100000100010000;   // g[1] = 1
    localparam [63:0] C_G2_1     = 64'h7100000200010000;   // g[2] = 1
    localparam [63:0] C_TOPC     = 64'h2001000000000001;   // LinkTopC
    localparam [63:0] C_TAILPGC  = 64'h200100000000000D;   // LinkTailPGC

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
            put_rec(cur, 44, 2048, 8'h00, "VIDEO_TS.VOB;1", 14, cur);
            put_rec(cur, 22, 6144, 8'h00, "VTS_01_0.IFO;1", 14, cur);
            put_rec(cur, 25, 4096, 8'h00, "VTS_01_0.VOB;1", 14, cur);
            put_rec(cur, 27, 32768, 8'h00, "VTS_01_1.VOB;1", 14, cur); // 27..42

            // VMGI_MAT @19: FP @400; TT_SRPT @+1 (20); VMGM_PGCI_UT @+2 (21)
            be32(19*2048+132, 32'd400);
            be32(19*2048+196, 32'd1);
            be32(19*2048+200, 32'd2);
            put_pgc(19*2048+400, 8'd0, 8'd0, 16'd236, 16'd0, 16'd0);
            put_cmdtbl(19*2048+400, 16'd236, 1, 0, 0, C_JUMPTT1, C_NOP, C_NOP, C_NOP);

            // TT_SRPT @20: 2 titles, both VTS_01
            be16(20*2048+0, 16'd3);
            img[20*2048+14] = 8'd1; img[20*2048+15] = 8'd1;
            img[20*2048+26] = 8'd1; img[20*2048+27] = 8'd2;
            img[20*2048+38] = 8'd1; img[20*2048+39] = 8'd3;

            // VMGM PGCI_UT @21 (unused)
            be16(21*2048+0, 16'd1);
            be32(21*2048+4, 32'd1000);
            be16(21*2048+8, 16'h656E);
            img[21*2048+11] = 8'h80;
            be32(21*2048+12, 32'd16);
            be16(21*2048+16, 16'd1);
            be32(21*2048+20, 32'd2000);
            img[21*2048+16+8] = 8'h82;
            be32(21*2048+16+8+4, 32'd64);
            put_pgc(21*2048+16+64, 8'd1, 8'd1, 16'd0, 16'd0, 16'd300);
            put_cell(21*2048+16+64, 16'd300, 0, 8'd0, 32'd0);

            // VTSI_MAT @22: vts_ptt_srpt=+1, vts_pgcit=+1 (23)
            be32(22*2048+204, 32'd1);
            be32(22*2048+208, 32'd2);

            // VTS_PGCIT @23: titles 1/2/3 -> PGC@16 / @700 / @1400
            be16(23*2048+0, 16'd3);
            img[23*2048+8]  = 8'h81; be32(23*2048+8+4,  32'd16);
            img[23*2048+16] = 8'h82; be32(23*2048+16+4, 32'd700);
            img[23*2048+24] = 8'h83; be32(23*2048+24+4, 32'd1400);

            // title 1: PRE g[0]=0; POST Nop; cell cmds {score, g[2]=1}
            put_pgc(23*2048+16, 8'd3, 8'd3, 16'd400, 16'd240, 16'd256);
            img[23*2048+16+240] = 8'd1;
            img[23*2048+16+241] = 8'd2;
            img[23*2048+16+242] = 8'd3;
            put_cell(23*2048+16, 16'd256, 0, 8'd1, 32'd0);    // B0: the shootout
            put_cell(23*2048+16, 16'd256, 1, 8'd2, 32'd2);    // B1: the hit branch
            put_cell(23*2048+16, 16'd256, 2, 8'd0, 32'd4);    // B2: shot dead (last)
            put_cmdtbl(23*2048+16, 16'd400, 1, 1, 2, C_G0_0, C_NOP, C_SCORE, C_G2_1);

            // title 2: POST Nop; cell cmds {g[1]=1, Nop, LinkTopC}
            put_pgc(23*2048+700, 8'd3, 8'd3, 16'd400, 16'd236, 16'd256);
            img[23*2048+700+236] = 8'd1;
            img[23*2048+700+237] = 8'd2;
            img[23*2048+700+238] = 8'd3;
            put_cell(23*2048+700, 16'd256, 0, 8'd1, 32'd6);   // B4: a Set
            put_cell(23*2048+700, 16'd256, 1, 8'd2, 32'd8);   // B5: Nop
            put_cell(23*2048+700, 16'd256, 2, 8'd3, 32'd10);  // B6: LinkTopC (loops)
            put_cmdtbl(23*2048+700, 16'd400, 0, 1, 3, C_NOP, C_G1_1, C_NOP, C_TOPC);

            // title 3: POST Nop; one cell cmd {LinkTailPGC}; cell 0 names cmd 5
            put_pgc(23*2048+1400, 8'd2, 8'd2, 16'd400, 16'd236, 16'd256);
            img[23*2048+1400+236] = 8'd1;
            img[23*2048+1400+237] = 8'd2;
            put_cell(23*2048+1400, 16'd256, 0, 8'd5, 32'd12); // B7: invalid cmd_nr
            put_cell(23*2048+1400, 16'd256, 1, 8'd1, 32'd14); // B8: LinkTailPGC
            put_cmdtbl(23*2048+1400, 16'd400, 0, 1, 1, C_NOP, C_TAILPGC, C_NOP, C_NOP);

            for (j = 0; j < 2048; j = j + 1) begin
                img[25*2048+j] = 8'hD0;
                img[26*2048+j] = 8'hD1;
                img[44*2048+j] = 8'hC0;
            end
            for (j = 0; j < 4096; j = j + 1) begin
                img[27*2048+j] = 8'hB0;
                img[29*2048+j] = 8'hB1;
                img[31*2048+j] = 8'hB2;
                img[33*2048+j] = 8'hB4;
                img[35*2048+j] = 8'hB5;
                img[37*2048+j] = 8'hB6;
                img[39*2048+j] = 8'hB7;
                img[41*2048+j] = 8'hB8;
            end
        end
    endtask

    task fail(input [1023:0] msg);
    begin
        $display("FAIL: %0s", msg);
        errors = errors + 1;
    end
    endtask

    task press(input [63:0] c);
    begin
        @(negedge clk); btn_cmd = c; btn_cmd_valid = 1;
        @(negedge clk); btn_cmd_valid = 0;
    end
    endtask

    // wait up to n cycles for a condition sampled each posedge
    integer t;
    task wait_hold(input integer n);
    begin
        t = 0;
        while (dut.vmw_cmd_pend !== 1'b1 && t < n) begin @(posedge clk); t = t + 1; end
    end
    endtask
    task wait_seq(input integer k, input integer n);
    begin
        t = 0;
        while (seq_n < k && t < n) begin @(posedge clk); t = t + 1; end
    end
    endtask
    task wait_pe(input integer k, input integer n);
    begin
        t = 0;
        while (n_pe < k && t < n) begin @(posedge clk); t = t + 1; end
    end
    endtask

    // does seq[] hold v at any index >= from?
    function automatic integer seq_find(input integer from, input [7:0] v);
        integer k;
        begin
            seq_find = -1;
            for (k = seq_n - 1; k >= from; k = k - 1) if (seq[k] == v) seq_find = k;
        end
    endfunction

    integer s0, c0, e0, p0, r0;
    integer a1_ok, a2_ok, b_ok, c_ok, d_ok, e_ok, f_ok, p1_ok, p2_ok, p3_ok, p4_ok;

    initial begin
        a1_ok = 1; a2_ok = 1; b_ok = 1; c_ok = 1; d_ok = 1; e_ok = 1;
        p1_ok = 1; p2_ok = 1; p3_ok = 1; p4_ok = 1; f_ok = 1;
        build_iso;
        file_size = IMG_BYTES;

        // ---------- A1: buttons up, no press -> the miss, but only at the end ----------
        cc_btns = 1; vbuf_empty = 0;
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (5) @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;

        s0 = seq_n; c0 = n_cc; p0 = n_pe;
        wait_hold(4000000);
        if (dut.vmw_cmd_pend !== 1'b1) begin fail("A1: no hold at the B0 cell end"); a1_ok = 0; end
        repeat (30000) @(posedge clk);
        if (n_cc != c0) begin fail("A1: the cell command ran while the VBUF still held the cell"); a1_ok = 0; end
        vbuf_empty = 1;                     // the display reaches the cell end
        t = 0; while (n_cc == c0 && t < 100000) begin @(posedge clk); t = t + 1; end
        if (n_cc != c0 + 1) begin fail("A1: the command did not run once the VBUF drained"); a1_ok = 0; end
        wait_pe(p0 + 1, 4000000);
        if (n_pe < p0 + 1) begin fail("A1: title 1 never reached its PGC end"); a1_ok = 0; end
        if (seq_find(s0, 8'hB0) < 0 || seq_find(s0, 8'hB2) < 0 || seq_find(s0, 8'hB1) >= 0) begin
            fail("A1: no press must take the miss branch (B0 -> B2, no B1)"); a1_ok = 0;
        end
        $display("A1 %s: buttons up -> the command waits for the drain (miss without a press)",
                 a1_ok ? "PASS" : "FAIL");

        // ---------- A2: a press during the hold counts (the hit) ----------
        repeat (2000) @(posedge clk);
        cc_btns = 1; vbuf_empty = 0;
        s0 = seq_n; c0 = n_cc; p0 = n_pe;
        press(C_JUMPTT1);
        wait_hold(4000000);
        if (dut.vmw_cmd_pend !== 1'b1) begin fail("A2: no hold at the B0 cell end"); a2_ok = 0; end
        // Press only once the reader's own pipeline is empty: a hold that waited for
        // the cache alone (and not the VBUF) would have run the command by now.
        t = 0; while ((dut.cache_has_data || stream_valid) && t < 100000) begin @(posedge clk); t = t + 1; end
        repeat (5000) @(posedge clk);
        press(C_G0_21);                     // the shot, inside the displayed window
        repeat (2000) @(posedge clk);
        // ---------- B (inside A2): cell 1 has no buttons -> immediate dispatch ----------
        cc_btns = 0;
        vbuf_empty = 1;
        t = 0; while (n_cc == c0 && t < 100000) begin @(posedge clk); t = t + 1; end
        vbuf_empty = 0;                     // B1 arrives into a "full" VBUF
        if (n_cc != c0 + 1) begin fail("A2: the command did not run once the VBUF drained"); a2_ok = 0; end
        // well inside DRAIN_WD_TB: a wrongly held command must not be rescued by the watchdog
        t = 0; while (n_cc < c0 + 2 && t < 100000) begin @(posedge clk); t = t + 1; end
        if (n_cc < c0 + 2) begin
            fail("B: with no buttons, cell 1's command (a Set) waited for the VBUF to drain"); b_ok = 0;
        end
        if (seq_find(s0, 8'hB1) < 0) begin fail("A2: the shot during the hold was not seen (no B1)"); a2_ok = 0; end
        vbuf_empty = 1;
        wait_pe(p0 + 1, 4000000);
        if (n_pe < p0 + 1) begin fail("A2: title 1 never reached its PGC end"); a2_ok = 0; end
        $display("A2 %s: a press during the hold is scored (B0 -> B1)", a2_ok ? "PASS" : "FAIL");
        $display("B %s: no buttons -> the cell command runs at once, VBUF full", b_ok ? "PASS" : "FAIL");

        // ---------- C: the hold waits for the reader's own cache too ----------
        repeat (2000) @(posedge clk);
        cc_btns = 1; vbuf_empty = 1; busy = 1;
        s0 = seq_n; c0 = n_cc;
        press(C_JUMPTT2);
        wait_hold(4000000);
        if (dut.vmw_cmd_pend !== 1'b1) begin fail("C: no hold at the B4 cell end"); c_ok = 0; end
        repeat (30000) @(posedge clk);
        if (n_cc != c0) begin fail("C: the command ran with the reader's cache still full"); c_ok = 0; end
        busy = 0;
        t = 0; while (n_cc == c0 && t < 100000) begin @(posedge clk); t = t + 1; end
        if (n_cc != c0 + 1) begin fail("C: the command did not run once the cache drained"); c_ok = 0; end
        $display("C %s: the hold also waits for the reader's cache", c_ok ? "PASS" : "FAIL");

        // ---------- P1: a FIXED command (Nop) is not held, buttons up or not ----------
        vbuf_empty = 0;                     // the VBUF "full" from here on
        @(posedge clk); pend_seen = 0;
        t = 0; while (n_cc < c0 + 2 && t < 100000) begin @(posedge clk); t = t + 1; end
        if (n_cc < c0 + 2) begin fail("P1: the Nop cell command never ran with the VBUF full"); p1_ok = 0; end
        if (pend_seen)     begin fail("P1: a Nop cell command was held"); p1_ok = 0; end
        $display("P1 %s: a fixed command (Nop) runs at once with buttons up", p1_ok ? "PASS" : "FAIL");

        // ---------- P2: a fixed loop (LinkTopC) replays gaplessly, buttons up ----------
        r0 = n_rep;
        @(posedge clk); pend_seen = 0;
        t = 0; while (n_rep < r0 + 2 && t < 150000) begin @(posedge clk); t = t + 1; end
        if (n_rep < r0 + 2) begin fail("P2: the LinkTopC loop did not replay with the VBUF full"); p2_ok = 0; end
        if (pend_seen)      begin fail("P2: a LinkTopC loop was held"); p2_ok = 0; end
        $display("P2 %s: a fixed loop (LinkTopC) replays without a hold", p2_ok ? "PASS" : "FAIL");

        // ---------- D: a jump during the hold clears it ----------
        repeat (20000) @(posedge clk);
        cc_btns = 1; vbuf_empty = 0;
        p0 = n_pe;
        press(C_JUMPTT1);
        wait_hold(4000000);
        if (dut.vmw_cmd_pend !== 1'b1) begin fail("D: no hold at the B0 cell end"); d_ok = 0; end
        cc_btns = 0;
        press(C_JUMPTT3);                   // a button's jump leaves the cell
        t = 0; while (!jump_ack && t < 100000) begin @(posedge clk); t = t + 1; end
        repeat (4) @(posedge clk);
        if (dut.vmw_cmd_pend !== 1'b0) begin fail("D: the jump left the hold latched"); d_ok = 0; end
        vbuf_empty = 1;
        wait_pe(p0 + 1, 4000000);
        if (n_pe < p0 + 1) begin fail("D: title 3 never reached its PGC end"); d_ok = 0; end
        repeat (2000) @(posedge clk);
        if (dut.vmw_cmd_pend !== 1'b0) begin fail("D: a stale hold survived to title 3's end"); d_ok = 0; end
        $display("D %s: a jump during the hold clears it", d_ok ? "PASS" : "FAIL");

        // ---------- P4 / P3: title 3, buttons up, VBUF full ----------
        repeat (2000) @(posedge clk);
        cc_btns = 1; vbuf_empty = 0;
        c0 = n_cc; p0 = n_pe;
        @(posedge clk); pend_seen = 0;
        press(C_JUMPTT3);
        // P4: cell 0 names cmd 5 of 1 (invalid): never held, the VM advances
        t = 0; while (n_cc == c0 && t < 100000) begin @(posedge clk); t = t + 1; end
        if (n_cc != c0 + 1) begin fail("P4: the invalid cell command never dispatched"); p4_ok = 0; end
        if (pend_seen)      begin fail("P4: an invalid cmd_nr was held"); p4_ok = 0; end
        $display("P4 %s: a cmd_nr past this PGC's cell commands is not held", p4_ok ? "PASS" : "FAIL");
        // P3: cell 1 LinkTailPGC reaches POST, which reads registers: held
        wait_hold(400000);
        if (dut.vmw_cmd_pend !== 1'b1) begin fail("P3: LinkTailPGC was not held"); p3_ok = 0; end
        repeat (20000) @(posedge clk);
        if (n_cc != c0 + 1) begin fail("P3: LinkTailPGC ran with the VBUF full"); p3_ok = 0; end
        vbuf_empty = 1;
        t = 0; while (n_cc == c0 + 1 && t < 100000) begin @(posedge clk); t = t + 1; end
        if (n_cc != c0 + 2) begin fail("P3: LinkTailPGC did not run once the VBUF drained"); p3_ok = 0; end
        $display("P3 %s: LinkTailPGC (POST reads registers) is held", p3_ok ? "PASS" : "FAIL");

        // ---------- F: the audio runs low first -> the hold releases ----------
        repeat (2000) @(posedge clk);
        cc_btns = 1; vbuf_empty = 0; cc_aud_low = 0;
        c0 = n_cc;
        press(C_JUMPTT1);
        wait_hold(4000000);
        if (dut.vmw_cmd_pend !== 1'b1) begin fail("F: no hold at the B0 cell end"); f_ok = 0; end
        repeat (20000) @(posedge clk);
        if (n_cc != c0) begin fail("F: the command ran before the audio ran low"); f_ok = 0; end
        cc_aud_low = 1;
        t = 0; while (n_cc == c0 && t < 5000) begin @(posedge clk); t = t + 1; end
        if (n_cc != c0 + 1) begin fail("F: audio low did not release the hold"); f_ok = 0; end
        cc_aud_low = 0;
        vbuf_empty = 1;                     // let the miss branch finish
        t = 0; while (n_pe == p0 && t < 4000000) begin @(posedge clk); t = t + 1; end
        $display("F %s: the audio running low releases the hold", f_ok ? "PASS" : "FAIL");

        // ---------- E: a VBUF that never drains -> DRAIN_WD releases ----------
        repeat (2000) @(posedge clk);
        cc_btns = 1; vbuf_empty = 0;
        c0 = n_cc;
        press(C_JUMPTT1);
        wait_hold(4000000);
        if (dut.vmw_cmd_pend !== 1'b1) begin fail("E: no hold at the B0 cell end"); e_ok = 0; end
        e0 = 0;
        while (n_cc == c0 && e0 < 3 * DRAIN_WD_TB) begin @(posedge clk); e0 = e0 + 1; end
        $display("E: released after %0d cycles (DRAIN_WD %0d)", e0, DRAIN_WD_TB);
        if (n_cc == c0)          begin fail("E: the hold never released (deadlock)"); e_ok = 0; end
        else if (e0 < DRAIN_WD_TB - 1000)
                                 begin fail("E: released before DRAIN_WD with the VBUF full"); e_ok = 0; end
        $display("E %s: DRAIN_WD bounds the hold", e_ok ? "PASS" : "FAIL");

        if (errors == 0) $display("ISO_READER_CMDHOLD_TB: ALL TESTS PASSED");
        else             $fatal(1, "ISO_READER_CMDHOLD_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin
        #900000000;
        $fatal(1, "ISO_READER_CMDHOLD_TB: TIMEOUT");
    end

endmodule
