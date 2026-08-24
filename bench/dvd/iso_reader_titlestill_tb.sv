// iso_reader_titlestill_tb.sv - TITLE-DOMAIN finite-still hold (vm_mode).
//
// FMV-game discs (Thayer's Quest) author a TIMED CHOICE as a TITLE-domain cell
// that carries an explicit still_time (4/5/10 s) AND a cell_cmd_nr: the cell
// plays its "approach" video, FREEZES the last frame for still_time while the
// forever-HLI buttons stay armed, and on TIMEOUT runs the cell command (the
// "too slow / lose a life" branch). A left/right press during the hold fires
// its LinkTailPGC and exits early.
//
// Before the fix the reader's timed-still branch was menu_dom-only, so a title
// choice cell fell straight through to the `vm_mode && cell_cmd_nr` branch and
// ran the timeout command INSTANTLY (no window; the door subpicture was
// overwritten = a 1-frame flash). This tb pins the fix: with Disc Menus on
// (vm_mode=1) a title cell with a finite still_time HOLDS (still_active,
// still_timed) after streaming, then on the timer runs its cell command.
//
// Boots exactly like iso_reader_vm_tb (reader + dvd_vm, no tb-issued jumps):
//   FP {g14=0x35; JumpTT 1} -> TT_SRPT -> title SRP entry 0x81 -> PGC@16:
//     cell 0: still_time=3 s, cell_cmd_nr=1  (0xB0)  <-- the timed choice
//     cell 1: plain                          (0xB1)
//     cell cmd 1 = Nop (VM answers vm_adv -> advance to cell 1 on timeout)
//     POST = Nop
// SEC_DIV(1000) so the 3 s hold is 3000 clk in sim.
//
// Run: iverilog -g2012 -o /tmp/rts dvd/dvd_iso_reader.sv dvd/dvd_vm.sv \
//        bench/dvd/iso_reader_titlestill_tb.sv && vvp /tmp/rts

`timescale 1ns/1ps

module iso_reader_titlestill_tb;

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

    // reader <-> VM wires (the emu.sv wiring)
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

    dvd_iso_reader #(.SEC_DIV(1000)) dut (
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

    // ---- event counters ----
    integer n_vm_cell_cmd = 0;
    always @(posedge clk)
        if (vm_cell_cmd_w) n_vm_cell_cmd = n_vm_cell_cmd + 1;

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

    // ---- image builders (iso_reader_vm_tb pattern) ----
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
            put_rec(cur, 29, 2048, 8'h00, "VIDEO_TS.VOB;1", 14, cur); // VMGM VOB
            put_rec(cur, 22, 6144, 8'h00, "VTS_01_0.IFO;1", 14, cur); // 22..24
            put_rec(cur, 25, 4096, 8'h00, "VTS_01_0.VOB;1", 14, cur); // menu VOB
            put_rec(cur, 27, 4096, 8'h00, "VTS_01_1.VOB;1", 14, cur); // title

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

            // VMGM PGCI_UT @21: PGCN1 entry 0x82, 1 cell (unused here)
            put_ut(21, 16'd1);
            put_srp(21, 0, 8'h82, 32'd64);
            put_pgc(21*2048+16+64, 8'd1, 8'd1, 16'd0, 8'd0, 16'd0, 16'd0, 16'd300);
            put_cell(21*2048+16+64, 16'd300, 0, 8'd0, 8'd0, 32'd0, 32'd0);

            // VTSI_MAT @22: vts_pgcit=+1 (23)
            be32(22*2048+204, 32'd1);
            be32(22*2048+208, 32'd2);

            // title VTS_PGCIT @23: SRP[0] entry 0x81 -> PGC @16:
            //   cell 0: still_time=3 s, cell_cmd_nr=1  (0xB0)  <-- timed choice
            //   cell 1: plain                          (0xB1)
            //   cmd tbl: post=1 (Nop), cell=1 (Nop); pm {1,2}
            be16(23*2048+0, 16'd1);
            img[23*2048+8] = 8'h81;               // SRP[0].entry_id (title 1)
            be32(23*2048+8+4, 32'd16);
            put_pgc(23*2048+16, 8'd2, 8'd2, 16'd0, 8'd0, 16'd320, 16'd240, 16'd256);
            img[23*2048+16+240] = 8'd1;           // pm[0] = cell 1
            img[23*2048+16+241] = 8'd2;           // pm[1] = cell 2
            put_cell(23*2048+16, 16'd256, 0, 8'd3, 8'd1, 32'd0, 32'd0);   // still 3s + cmd 1
            put_cell(23*2048+16, 16'd256, 1, 8'd0, 8'd0, 32'd1, 32'd1);
            // post cmd (Nop) then cell cmd 1 (Nop): timeout -> vm_adv -> cell 1
            put_cmdtbl(23*2048+16, 16'd320, 0, 1, 1,
                       64'd0, 64'd0, 64'd0);

            // payload sectors
            for (j = 0; j < 2048; j = j + 1) begin
                img[25*2048+j] = 8'hD0;           // menu cell 1
                img[26*2048+j] = 8'hD1;           // menu cell 2
                img[27*2048+j] = 8'hB0;           // title cell 0 (the timed choice)
                img[28*2048+j] = 8'hB1;           // title cell 1
                img[29*2048+j] = 8'hC0;           // VMGM cell
            end
        end
    endtask

    task fail(input [511:0] msg);
    begin
        $display("FAIL: %0s", msg);
        errors = errors + 1;
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

        // ---------------- T1: boot -> title cell0 streams then HOLDS ------
        // Wait for the title choice cell (0xB0) to stream, then the reader must
        // PARK on the timed still (still_active, still_timed) rather than
        // advancing / running the cell command right away.
        t = 0;
        while (cap_n < 2048 && t < 4000000) begin @(posedge clk); t = t + 1; end
        if (cap_n < 2048) fail("T1: title cell0 (0xB0) never streamed");
        if (cap[0] !== 8'hB0) fail("T1: first title byte != B0");

        // let the cell-end decision settle (drain -> S_STILL)
        t = 0;
        while (!still_active && t < 200000) begin @(posedge clk); t = t + 1; end
        $display("T1 hold: still_active=%b still_timed=%b secs=%0d next=%0d cell=%0d vm_cell_cmds=%0d cap=%0d",
                 still_active, dut.still_timed, dut.still_secs, dut.still_next,
                 cur_cell, n_vm_cell_cmd, cap_n);
        if (!still_active)            fail("T1: title finite-still did NOT hold (advanced instead)");
        if (dut.still_timed !== 1'b1) fail("T1: hold is not a TIMED still");
        if (n_vm_cell_cmd != 0)       fail("T1: cell command ran BEFORE the timer (premature)");
        if (cur_cell != 8'd0)         fail("T1: parked off cell 0");
        // only cell0 (0xB0) has streamed so far - cell1 (0xB1) not yet
        begin : chk_only_b0
            integer k; integer nb1;
            nb1 = 0;
            for (k = 0; k < cap_n; k = k + 1) if (cap[k] == 8'hB1) nb1 = nb1 + 1;
            if (nb1 != 0) fail("T1: cell1 (0xB1) streamed during the hold");
        end
        $display("T1 PASS: title timed choice HOLDS (still_active, timed, no premature cmd)");

        // ---------------- T2: timer expires -> cell command runs ----------
        // After ~3 s (SEC_DIV=1000 -> ~3000 clk) the STILL_CMD fires: vm_cell_cmd
        // pulses, the VM (Nop) answers vm_adv, and cell 1 (0xB1) streams.
        cmark = cap_n;
        t = 0;
        while (n_vm_cell_cmd == 0 && t < 200000) begin @(posedge clk); t = t + 1; end
        if (n_vm_cell_cmd == 0) fail("T2: timer never ran the cell command");
        t = 0;
        while (cap_n < cmark + 2048 && t < 4000000) begin @(posedge clk); t = t + 1; end
        begin : chk_b1
            integer k; integer nb1;
            nb1 = 0;
            for (k = cmark; k < cap_n; k = k + 1) if (cap[k] == 8'hB1) nb1 = nb1 + 1;
            if (nb1 < 2048) fail("T2: cell1 (0xB1) did not stream after the timeout");
        end
        $display("T2 PASS: timeout -> cell command -> advanced to cell1 (0xB1)");

        if (errors == 0) $display("ISO_READER_TITLESTILL_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_TITLESTILL_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin
        #400000000;
        $display("ISO_READER_TITLESTILL_TB: TIMEOUT");
        $finish;
    end

endmodule
