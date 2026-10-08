// iso_reader_fpnone_tb.sv -- two reader changes from the 2026-10-08 library sweep
// (docs/nav_engine.md 5a). Reader only; the tb issues the VM's jumps.
//
// FIRST PLAY WITH NO FIRST PLAY PGC (VMGI@0x84 = 0). libdvdnav's set_FP_PGC then plays
// VMGM PGC 1 in the First Play domain, and a First Play LinkPGCN n resolves through the
// same VMGM PGCIT (get_PGCIT). The reader errored, and the VM's FB_FP fallback booted
// the auto title (D050818_01, ISLAM_TRAILER).
//   A  First Play jump, pgcn 0  -> VMGM PGC 1 streams (C1), a menu, no pgc_error
//   B  First Play LinkPGCN 3    -> VMGM PGC 3 streams (C3), menu -> menu: keep_vbuf,
//                                  no jump_cross (fp_none counts First Play as a menu)
//   F  ... and VMGI@200 = 0 too -> pgc_error, as before
//
// SPRM7 FOLLOWS PLAYBACK: the reader publishes the playing cell's GLOBAL part (ptt_upd
// / ptt_cur) from its title's PTT table. A VM title jump that names a PGCN but no
// title (LinkPGCN, an RSM resume) used to load title 1's table regardless (1,139 of
// 1,531 library discs have a VTS with more than one title). ttn_pick reloads the
// SRP's owner unless title 1's table names the PGC (libdvdnav takes the lowest title).
//   C  title jump, PGC 2 (title 2 only) -> title 2's table: parts 1 then 2
//   D  title jump, PGC 3 (titles 1 AND 3) -> title 1's table kept: part 2
//   E  title jump, PGC 4 (no table, SRP owner 0) -> no part published
//
// Layout (2048-byte sectors; 16-sector cells, the cache-outrun artefact of
// iso_reader_ptt_tb):
//   16 PVD  17 root  18 VIDEO_TS dir
//   19 VIDEO_TS.IFO s0 = VMGI_MAT (fp@132 = 0; tt_srpt@196 = 0; vmgm_ut@200 = 2 -> 21)
//   21 VMGM PGCI_UT: PGC1..3, one cell each -> VIDEO_TS.VOB RBN 0/16/32 (C1/C2/C3)
//   22 VTS_01_0.IFO s0 = VTSI_MAT (ptt_srpt@200 = 1 -> 23; vts_pgcit@204 = 2 -> 24)
//   23 VTS_PTT_SRPT: t1 {pgc1 pg1, pgc3 pg1}; t2 {pgc2 pg1, pgc2 pg2}; t3 {pgc3 pg1}
//   24 VTS_PGCIT: SRP0 0x81 PGC1 (B1); SRP1 0x82 PGC2 (2 programs: B2, B3);
//                 SRP2 0x83 PGC3 (B4); SRP3 0x00 PGC4 (B5)
//   25..72  VIDEO_TS.VOB     73..152 VTS_01_1.VOB (RBN 0 B1, 16 B2, 32 B3, 48 B4, 64 B5)
`timescale 1ns/1ps

module iso_reader_fpnone_tb;

    localparam IMG_BYTES = 160*2048;

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

    reg         jump_pulse = 0;
    reg  [1:0]  jump_domain = 0;
    reg  [7:0]  jump_vts = 0;
    reg  [15:0] jump_pgcn = 0;
    reg  [3:0]  jump_entry = 0;
    reg  [6:0]  jump_ttn = 0;
    reg  [8:0]  jump_pgn = 0;
    reg  [9:0]  jump_ptt = 0;
    wire        jump_ack, pgc_loaded, pgc_error, menu_active, still_active;
    wire        seek_ack, nav_ready_w, keep_vbuf, jump_cross;
    wire [7:0]  cur_vts, best_menu_vts, auto_vts_w, cell_count_w;
    wire [6:0]  res_ttn_w;
    wire [15:0] cur_pgcn_w;
    wire [7:0]  cur_pgm_w;
    wire [10:0] nr_ptt_w;
    wire        ptt_upd_w;
    wire [10:0] ptt_cur_w;

    dvd_iso_reader dut (
        .agl_vm(4'd0), .agl_vm_en(1'b0), .vm_pre_done(1'b0),
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(7'd0),
        .aud_drained(1'b1), .vbuf_empty(1'b1),
        .jump_ttn(jump_ttn), .jump_pgn(jump_pgn[7:0]), .jump_ptt(jump_ptt),
        .still_off(1'b0), .vm_mode(1'b1), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(nav_ready_w),
        .auto_vts(auto_vts_w), .cell_count_o(cell_count_w), .res_ttn(res_ttn_w),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_pulse(1'b0), .seek_natural(1'b0), .seek_cell(8'd0), .seek_ack(seek_ack),
        .cur_cell(), .cell_ready(),
        .chap_pulse(1'b0), .chap_dir(1'b0), .chap_mag(5'd1),
        .chap_at_start(1'b1), .cur_pgm(cur_pgm_w), .nr_ptt_o(nr_ptt_w),
        .ptt_upd(ptt_upd_w), .ptt_cur(ptt_cur_w),
        .keep_vbuf(keep_vbuf), .jump_cross(jump_cross),
        .jump_pulse(jump_pulse), .jump_natural(1'b0), .jump_domain(jump_domain),
        .jump_vts(jump_vts), .jump_pgcn(jump_pgcn), .jump_entry(jump_entry),
        .jump_cell(8'd0),
        .jump_ack(jump_ack), .pgc_loaded(pgc_loaded), .pgc_error(pgc_error),
        .menu_active(menu_active), .still_active(still_active), .cur_vts(cur_vts),
        .cur_pgcn_o(cur_pgcn_w),
        .best_menu_vts(best_menu_vts),
        .menu_btns_armed(1'b0),
        .cmd_we(), .cmd_waddr(), .cmd_wdata(),
        .cmd_nr_pre(), .cmd_nr_post(), .cmd_nr_cell(),
        .next_pgcn(), .prev_pgcn(), .goup_pgcn(),
        .cur_cell_cmdnr(),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .pal_we(), .pal_waddr(), .pal_wdata(),
        .debug_active(), .debug_iso_mode()
    );

    always #5 clk = ~clk;

    // ---- observers ---------------------------------------------------------------
    reg       await_first = 0;
    reg [7:0] post_jump_byte = 0;
    reg       post_jump_v = 0;
    reg       saw_err = 0, saw_loaded = 0;
    reg       kv_at_ack = 0, jc_at_ack = 0;
    reg [7:0] seen [0:255];                      // seen[byte] = streamed since cleared
    integer   n_ptt = 0;                         // parts published since cleared
    reg [10:0] ptt_hist [0:7];
    integer   k;
    always @(posedge clk) begin
        if (jump_ack) begin
            await_first <= 1'b1; post_jump_v <= 1'b0;
            kv_at_ack <= keep_vbuf; jc_at_ack <= jump_cross;
        end
        if (pgc_error) saw_err <= 1'b1;
        if (pgc_loaded) saw_loaded <= 1'b1;
        if (stream_valid) begin
            seen[stream_data] <= 8'd1;
            if (await_first) begin
                post_jump_byte <= stream_data; post_jump_v <= 1'b1; await_first <= 1'b0;
            end
        end
        if (ptt_upd_w === 1'b1) begin
            if (n_ptt < 8) ptt_hist[n_ptt] <= ptt_cur_w;
            n_ptt <= n_ptt + 1;
        end
    end

    // mock HPS (iso_reader_ptt_tb's)
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

    integer i, cur, errors = 0;

    task fail(input [1023:0] msg);   // 128 characters: a longer message loses its START
    begin $display("FAIL: %0s", msg); errors = errors + 1; end
    endtask

    // ---- image ------------------------------------------------------------------
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
    // a PGC: npgms programs, ncells cells; program map @240 (program p -> cell p),
    // cell table @256
    task put_pgc(input integer pa, input [7:0] npgms, input [7:0] ncells);
        integer p; begin
            img[pa+2] = npgms; img[pa+3] = ncells;
            be16(pa+156, 0); be16(pa+158, 0); be16(pa+160, 0); img[pa+163] = 0;
            be16(pa+228, 0); be16(pa+230, (npgms != 0) ? 16'd240 : 16'd0); be16(pa+232, 16'd256);
            for (p = 0; p < npgms; p = p + 1) img[pa+240+p] = p + 1;
        end
    endtask
    task put_cell(input integer pa, input integer idx, input [31:0] first, input [31:0] last);
        integer c; begin c = pa + 256 + idx*24; be32(c+8, first); be32(c+20, last); end
    endtask
    task put_ut(input integer sec, input [15:0] nsrp);          // one LU, 'en'
        integer base; begin
            base = sec*2048;
            be16(base+0, 16'd1); be32(base+4, 32'd2047);
            be16(base+8, 16'h656E); img[base+10] = 0; img[base+11] = 8'h80;
            be32(base+12, 32'd16);
            be16(base+16, nsrp); be32(base+20, 32'd2047);
        end
    endtask
    task put_msrp(input integer sec, input integer idx, input [7:0] eid, input [31:0] at);
        integer a; begin a = sec*2048 + 16 + 8 + idx*8; img[a] = eid; be32(a+4, at); end
    endtask

    task build;
        integer j;
        begin
            for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = 8'h00;
            img[32768]=1; img[32769]="C"; img[32770]="D"; img[32771]="0";
            img[32772]="0"; img[32773]="1"; img[32774]=1;
            put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur);
            cur = 17*2048;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 18, 2048, 8'h02, "VIDEO_TS", 8, cur);
            cur = 18*2048;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 19, 6144, 8'h00, "VIDEO_TS.IFO;1", 14, cur);   // 19..21
            put_rec(cur, 25, 98304, 8'h00, "VIDEO_TS.VOB;1", 14, cur);  // 25..72
            put_rec(cur, 22, 6144, 8'h00, "VTS_01_0.IFO;1", 14, cur);   // 22..24
            put_rec(cur, 73, 163840, 8'h00, "VTS_01_1.VOB;1", 14, cur); // 73..152

            // VMGI_MAT: NO First Play PGC; no TT_SRPT; VMGM_PGCI_UT @+2 (21)
            be32(19*2048+132, 32'd0);
            be32(19*2048+196, 32'd0);
            be32(19*2048+200, 32'd2);

            // VMGM PGCI_UT @21: PGC1..3 (entry ids: Title menu, none, none)
            put_ut(21, 16'd3);
            put_msrp(21, 0, 8'h82, 32'd64);
            put_msrp(21, 1, 8'h00, 32'd600);
            put_msrp(21, 2, 8'h00, 32'd1100);
            put_pgc(21*2048+16+64, 8'd1, 8'd1);   put_cell(21*2048+16+64, 0, 0, 15);
            put_pgc(21*2048+16+600, 8'd1, 8'd1);  put_cell(21*2048+16+600, 0, 16, 31);
            put_pgc(21*2048+16+1100, 8'd1, 8'd1); put_cell(21*2048+16+1100, 0, 32, 47);

            // VTSI_MAT @22: vts_ptt_srpt = +1 (23), vts_pgcit = +2 (24)
            be32(22*2048+200, 32'd1);
            be32(22*2048+204, 32'd2);

            // VTS_PTT_SRPT @23: 3 titles
            be16(23*2048+0, 16'd3);
            be32(23*2048+4, 32'd47);                                  // last_byte
            be32(23*2048+8, 32'd20); be32(23*2048+12, 32'd28); be32(23*2048+16, 32'd36);
            be16(23*2048+20, 16'd1); be16(23*2048+22, 16'd1);         // t1 p1 -> pgc1 pg1
            be16(23*2048+24, 16'd3); be16(23*2048+26, 16'd1);         // t1 p2 -> pgc3 pg1
            be16(23*2048+28, 16'd2); be16(23*2048+30, 16'd1);         // t2 p1 -> pgc2 pg1
            be16(23*2048+32, 16'd2); be16(23*2048+34, 16'd2);         // t2 p2 -> pgc2 pg2
            be16(23*2048+36, 16'd3); be16(23*2048+38, 16'd1);         // t3 p1 -> pgc3 pg1

            // VTS_PGCIT @24: 4 SRPs; PGCs at 64 / 400 / 800 / 1200
            be16(24*2048+0, 16'd4);
            img[24*2048+8]  = 8'h81; be32(24*2048+8+4,  32'd64);
            img[24*2048+16] = 8'h82; be32(24*2048+16+4, 32'd400);
            img[24*2048+24] = 8'h83; be32(24*2048+24+4, 32'd800);
            img[24*2048+32] = 8'h00; be32(24*2048+32+4, 32'd1200);
            put_pgc(24*2048+64, 8'd1, 8'd1);   put_cell(24*2048+64, 0, 0, 15);
            put_pgc(24*2048+400, 8'd2, 8'd2);  put_cell(24*2048+400, 0, 16, 31);
                                               put_cell(24*2048+400, 1, 32, 47);
            put_pgc(24*2048+800, 8'd1, 8'd1);  put_cell(24*2048+800, 0, 48, 63);
            put_pgc(24*2048+1200, 8'd1, 8'd1); put_cell(24*2048+1200, 0, 64, 79);

            for (j = 0; j < 16*2048; j = j + 1) begin
                img[25*2048+j]       = 8'hC1;
                img[(25+16)*2048+j]  = 8'hC2;
                img[(25+32)*2048+j]  = 8'hC3;
                img[73*2048+j]       = 8'hB1;
                img[(73+16)*2048+j]  = 8'hB2;
                img[(73+32)*2048+j]  = 8'hB3;
                img[(73+48)*2048+j]  = 8'hB4;
                img[(73+64)*2048+j]  = 8'hB5;
            end
        end
    endtask

    // ---- stimulus -----------------------------------------------------------------
    task mount;
        integer t;
    begin
        @(negedge clk); start = 1; @(negedge clk); start = 0;
        t = 0;
        while (!nav_ready_w && t < 2000000) begin @(posedge clk); t = t + 1; end
        if (!nav_ready_w) fail("mount: no nav_ready");
        repeat (20) @(negedge clk);
    end
    endtask

    task jump(input [1:0] dom, input [7:0] vts, input [15:0] pgcn, input [6:0] ttn);
        integer b;
    begin
        for (b = 0; b < 256; b = b + 1) seen[b] = 8'd0;
        saw_err = 0; saw_loaded = 0; post_jump_v = 0; n_ptt = 0;
        @(negedge clk);
        jump_domain = dom; jump_vts = vts; jump_pgcn = pgcn; jump_entry = 0;
        jump_ttn = ttn; jump_pgn = 0; jump_ptt = 0; jump_pulse = 1;
        @(negedge clk); jump_pulse = 0;
    end
    endtask

    task wait_byte(input [7:0] b, input [255:0] label);
        integer t;
    begin
        t = 0;
        while (seen[b] !== 8'd1 && !saw_err && t < 3000000) begin @(posedge clk); t = t + 1; end
        repeat (4000) @(posedge clk);            // let the cell's part query land
        if (seen[b] !== 8'd1) begin
            $display("FAIL %0s: never streamed %02x (pgc_error=%0d)", label, b, saw_err);
            errors = errors + 1;
        end
    end
    endtask

    initial begin
        build; file_size = IMG_BYTES;
        repeat (5) @(negedge clk); rst_n = 1; repeat (5) @(negedge clk);
        mount;

        // A: First Play with no First Play PGC -> VMGM PGC 1
        jump(2'd0, 8'd0, 16'd0, 7'd0);
        wait_byte(8'hC1, "A");
        if (saw_err) fail("A: First Play errored (no FP PGC must play VMGM PGC 1)");
        if (post_jump_byte !== 8'hC1) begin fail("A: first byte is not VMGM PGC 1's"); $display("  byte=%02x", post_jump_byte); end
        if (!menu_active) fail("A: VMGM PGC 1 is not a menu to the reader");
        if (cur_pgcn_w !== 16'd1) begin fail("A: cur_pgcn != 1"); $display("  cur_pgcn=%0d", cur_pgcn_w); end
        if (errors == 0) $display("A: First Play, no FP PGC -> VMGM PGC 1 (C1)  PASS");

        // B: a First Play LinkPGCN 3 -> VMGM PGC 3, menu -> menu
        jump(2'd0, 8'd0, 16'd3, 7'd0);
        wait_byte(8'hC3, "B");
        if (saw_err) fail("B: First Play LinkPGCN 3 errored");
        if (post_jump_byte !== 8'hC3) begin fail("B: first byte is not VMGM PGC 3's"); $display("  byte=%02x", post_jump_byte); end
        if (cur_pgcn_w !== 16'd3) begin fail("B: cur_pgcn != 3"); $display("  cur_pgcn=%0d", cur_pgcn_w); end
        if (kv_at_ack !== 1'b1 || jc_at_ack !== 1'b0) begin
            fail("B: First Play -> First Play is not menu -> menu (keep_vbuf / jump_cross)");
            $display("  keep_vbuf=%0d jump_cross=%0d", kv_at_ack, jc_at_ack);
        end
        if (errors == 0) $display("B: First Play LinkPGCN 3 -> VMGM PGC 3, VBUF held  PASS");

        // C: title jump to PGC 2 (title 2 only): title 2's table, parts 1 then 2
        jump(2'd3, 8'd1, 16'd2, 7'd0);
        wait_byte(8'hB2, "C");
        wait_byte(8'hB3, "C");
        if (dut.cur_ttn !== 7'd2) begin fail("C: the PTT table is not title 2's"); $display("  cur_ttn=%0d nr_ptt=%0d", dut.cur_ttn, nr_ptt_w); end
        if (n_ptt < 2 || ptt_hist[0] !== 11'd1 || ptt_hist[n_ptt-1] !== 11'd2) begin
            fail("C: SPRM7 parts are not 1 then 2");
            $display("  n=%0d first=%0d last=%0d", n_ptt, ptt_hist[0], (n_ptt > 0) ? ptt_hist[n_ptt-1] : 11'h7FF);
        end
        if (errors == 0) $display("C: LinkPGCN into title 2 -> its table, parts 1, 2  PASS");

        // D: title jump to PGC 3 (named by titles 1 and 3): title 1's, part 2
        jump(2'd3, 8'd1, 16'd3, 7'd0);
        wait_byte(8'hB4, "D");
        if (dut.cur_ttn !== 7'd1) begin fail("D: title 1's table not kept (libdvdnav: lowest title)"); $display("  cur_ttn=%0d", dut.cur_ttn); end
        if (n_ptt < 1 || ptt_hist[n_ptt-1] !== 11'd2) begin
            fail("D: SPRM7 != title 1's part 2");
            $display("  n=%0d last=%0d", n_ptt, (n_ptt > 0) ? ptt_hist[n_ptt-1] : 11'h7FF);
        end
        if (errors == 0) $display("D: a PGC title 1 names keeps its table, part 2  PASS");

        // E: PGC 4, which no table names: nothing published (the VM keeps SPRM7)
        jump(2'd3, 8'd1, 16'd4, 7'd0);
        wait_byte(8'hB5, "E");
        if (n_ptt != 0) begin fail("E: a part was published for a PGC no table names"); $display("  n=%0d first=%0d", n_ptt, ptt_hist[0]); end
        if (errors == 0) $display("E: no PTT entry -> no SPRM7 update  PASS");

        // F: no First Play PGC AND no VMGM menu -> pgc_error, as before
        be32(19*2048+200, 32'd0);
        mount;
        jump(2'd0, 8'd0, 16'd0, 7'd0);
        begin : wf integer t; t = 0;
            while (!saw_err && !saw_loaded && t < 3000000) begin @(posedge clk); t = t + 1; end
        end
        if (!saw_err || saw_loaded) fail("F: no FP PGC and no VMGM must error");
        if (errors == 0) $display("F: no FP PGC and no VMGM -> pgc_error  PASS");

        if (errors == 0) $display("ISO_READER_FPNONE_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_FPNONE_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin #400000000; $display("GLOBAL TIMEOUT st=%0d", dut.state); $fatal(1); end

endmodule
