// iso_reader_ptt_tb.sv - VTS_PTT_SRPT title resolve (Phase-4 round 2).
//
// A JumpVTS_TT n / JumpTT must land on the title's ACTUAL PGC, resolved via
// VTS_PTT_SRPT (vts_ttn -> pgcn), NOT the entry-scan heuristic's SRP[0] (= the
// main feature). This is what made Matrix's special-feature buttons all play
// the movie. Here VTS_01 has two title PGCs whose SRP entry_ids are BOTH 0
// (no title-entry markers - the exact Matrix shape), and the map is:
//   VTS_PTT_SRPT: title 1 -> PGC 1 (cell 0xB0), title 2 -> PGC 2 (cell 0xB2)
// The entry scan alone would send both to SRP[0] = PGC 1. The tb drives:
//   TEST A  JumpVTS_TT 2 (vts 1) -> must stream 0xB2 (PGC 2 via PTT map)
//   TEST B  JumpVTS_TT 1 (vts 1) -> must stream 0xB0 (PGC 1)
//
// Layout (2048-byte sectors):
//   16 PVD   17 root   18 VIDEO_TS dir
//   19 VIDEO_TS.IFO (VMGI_MAT; tt_srpt unused)
//   20 VTS_01_0.IFO s0 = VTSI_MAT (vts_ptt_srpt@200=1 -> 21; vts_pgcit@204=4 -> 24)
//   21..23 VTS_01_0.IFO s1-s3 = VTS_PTT_SRPT (4 titles; t3 = 400 PTTs and
//        t4 = 1100 PTTs span sector boundaries -- the spec-hardening Phase-5
//        >256 load + >1024 graceful-clamp fixtures)
//   24 VTS_01_0.IFO s4 = VTS_PGCIT (SRP[0]->PGC@16 cell RBN0; SRP[1]->PGC@600 RBN2)
//   25..72 VTS_01_1.VOB = title VOB, 16-sector cells (the 1-sector-cell cache-
//        outrun TB artifact — see the chapter_tb note in CLAUDE.md):
//        RBN 0-15=0xB0 (PGC1 cell0), 16-31=0xB1 (PGC1 cell1), 32-47=0xB2 (PGC2)
//
// Cross-PGC chapter skip (spec-hardening Phase-5 follow-up): title 1's 3-PTT
// map {pgc1,pg1},{pgc1,pg2},{pgc2,pg1} doubles as the skip fixture — chapter
// 2->3 and 3->2 cross the PGC1/PGC2 boundary (internal JumpVTS_PTT-shaped
// jump), chapter 1->2 stays within PGC1 (legacy program-map seek path).

`timescale 1ns/1ps

module iso_reader_ptt_tb;

    localparam IMG_BYTES = 80*2048;

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
    reg  [7:0]  jump_pgcn = 0;
    reg  [3:0]  jump_entry = 0;
    reg  [6:0]  jump_ttn = 0;
    reg  [8:0]  jump_pgn = 0;
    reg  [9:0]  jump_ptt = 0;
    wire        jump_ack, pgc_loaded, pgc_error, menu_active, still_active;
    wire        seek_ack, nav_ready_w;
    wire [7:0]  cur_vts, best_menu_vts, auto_vts_w, cell_count_w;
    wire [6:0]  res_ttn_w;
    // Cross-PGC chapter skip
    reg         chap_pulse = 0;
    reg         chap_dir = 0;
    reg  [4:0]  chap_mag = 5'd1;
    reg         chap_at_start = 1;
    wire [7:0]  cur_pgm_w;
    wire [10:0] nr_ptt_w;

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(4'd0), .vbuf_empty(1'b0), .menu_snap(1'b0),
        .jump_ttn(jump_ttn), .jump_pgn(jump_pgn[7:0]), .jump_ptt(jump_ptt),
        .vm_mode(1'b1), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(nav_ready_w),
        .auto_vts(auto_vts_w), .cell_count_o(cell_count_w), .res_ttn(res_ttn_w),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_pulse(1'b0), .seek_natural(1'b0), .seek_cell(8'd0), .seek_ack(seek_ack),
        .cur_cell(), .cell_ready(),
        .chap_pulse(chap_pulse), .chap_dir(chap_dir), .chap_mag(chap_mag),
        .chap_at_start(chap_at_start), .cur_pgm(cur_pgm_w), .nr_ptt_o(nr_ptt_w),
        .jump_pulse(jump_pulse), .jump_natural(1'b0), .jump_domain(jump_domain), .jump_vts(jump_vts),
        .jump_pgcn(jump_pgcn), .jump_entry(jump_entry), .jump_cell(8'd0),
        .jump_ack(jump_ack), .pgc_loaded(pgc_loaded), .pgc_error(pgc_error),
        .menu_active(menu_active), .still_active(still_active), .cur_vts(cur_vts),
        .cur_pgcn_o(),
        .best_menu_vts(best_menu_vts),
        .menu_btns_armed(1'b0),
        .cmd_we(), .cmd_waddr(), .cmd_wdata(),
        .cmd_nr_pre(), .cmd_nr_post(), .cmd_nr_cell(),
        .cell_end_pulse(), .pgc_end_pulse(),
        .pgc_still_time(), .next_pgcn(), .prev_pgcn(), .goup_pgcn(),
        .cur_cell_still(), .cur_cell_cmdnr(),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .pal_we(), .pal_waddr(), .pal_wdata(),
        .debug_active(), .debug_sd_rd(), .debug_sd_ack(), .debug_cache_has_data(),
        .debug_file_size(), .debug_total_sectors(), .debug_next_lba(),
        .debug_state(), .debug_iso_mode(), .debug_iso_error()
    );

    always #5 clk = ~clk;

    integer cap_n = 0;
    reg [7:0] cap [0:262143];
    // first stream byte AFTER a jump/seek flush (the ack resets the output
    // pipe; the next stream_valid is the new position's first byte - avoids
    // sampling the previous stream's drain tail)
    reg       await_first = 0;
    reg [7:0] post_jump_byte = 0;
    reg       post_jump_v = 0;
    // sticky ack trackers (cleared by the chap_skip task) so the tests can
    // assert WHICH path a skip resolved through: within-PGC = seek_ack
    // (program-map fast path), cross-PGC = jump_ack (internal VM-style jump)
    reg       saw_seek_ack = 0, saw_jump_ack = 0;
    always @(posedge clk) begin
        if (jump_ack || seek_ack) begin await_first <= 1'b1; post_jump_v <= 1'b0; end
        if (seek_ack) saw_seek_ack <= 1'b1;
        if (jump_ack) saw_jump_ack <= 1'b1;
        if (stream_valid) begin
            if (cap_n < 262144) cap[cap_n] = stream_data;
            cap_n = cap_n + 1;
            if (await_first) begin
                post_jump_byte <= stream_data;
                post_jump_v    <= 1'b1;
                await_first    <= 1'b0;
            end
        end
    end

    // mock HPS
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

    task put_pgc(input integer pa, input [7:0] ncells, input [15:0] cpo);
        begin
            img[pa+2] = ncells; img[pa+3] = ncells;
            be16(pa+156,0); be16(pa+158,0); be16(pa+160,0);
            img[pa+163] = 0;
            be16(pa+228,0); be16(pa+230,0); be16(pa+232, cpo);
        end
    endtask
    task put_cell(input integer pa, input [15:0] cpo, input integer idx,
                  input [31:0] first, input [31:0] last);
        integer c; begin
            c = pa + cpo + idx*24; be32(c+8, first); be32(c+20, last);
        end
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
            put_rec(cur, 19, 2048, 8'h00, "VIDEO_TS.IFO;1", 14, cur);
            put_rec(cur, 20, 10240, 8'h00, "VTS_01_0.IFO;1", 14, cur); // 20..24
            put_rec(cur, 25, 98304, 8'h00, "VTS_01_1.VOB;1", 14, cur); // 25..72

            be32(19*2048+196, 32'd0);          // no TT_SRPT (JumpVTS_TT path)

            // VTSI_MAT @20: vts_ptt_srpt=+1 (21), vts_pgcit=+4 (24)
            be32(20*2048+200, 32'd1);
            be32(20*2048+204, 32'd4);

            // VTS_PTT_SRPT @21: nr_of_srpts=2; ttu_offset[0]=@100 (title 1, 3
            // PTTs), [1]=@112 (title 2, 1 PTT). Phase-6 exact-part map:
            //   t1 part1 -> {pgc1, pg1}  (PGC1 cell0 = 0xB0)
            //   t1 part2 -> {pgc1, pg2}  (PGC1 program 2 = cell1 = 0xB1)  <- start-pgn
            //   t1 part3 -> {pgc2, pg1}  (PGC2 cell0 = 0xB2)              <- cross-PGC
            //   t2 part1 -> {pgc2, pg1}
            // Phase-5 fixtures: t3 = 400 PTTs @116 (1600 B, crosses into
            // sector 22), t4 = 1100 PTTs @1716 (4400 B, crosses two sector
            // boundaries; loader must clamp at PTT_CAP=1024). Entry 0 of each
            // is {pgc1,pg1} so the mount lands on RBN0; entries i>=1 carry a
            // distinctive pattern for the ptt_mem spot checks.
            be16(21*2048+0, 16'd4);
            be32(21*2048+4, 32'd6115);         // last_byte (t4 ends at 6116)
            be32(21*2048+8,  32'd100);         // ttu_offset[0]
            be32(21*2048+12, 32'd112);         // ttu_offset[1]
            be32(21*2048+16, 32'd116);         // ttu_offset[2] (t3, 400 PTTs)
            be32(21*2048+20, 32'd1716);        // ttu_offset[3] (t4, 1100 PTTs)
            be16(21*2048+100, 16'd1); be16(21*2048+102, 16'd1);  // t1 p1 -> pgc1 pg1
            be16(21*2048+104, 16'd1); be16(21*2048+106, 16'd2);  // t1 p2 -> pgc1 pg2
            be16(21*2048+108, 16'd2); be16(21*2048+110, 16'd1);  // t1 p3 -> pgc2 pg1
            be16(21*2048+112, 16'd2); be16(21*2048+114, 16'd1);  // t2 p1 -> pgc2 pg1
            for (j = 0; j < 400; j = j + 1) begin                // t3 entries
                be16(21*2048+116+4*j, (j == 0) ? 16'd1 : (16'h1000 + j[15:0]));
                be16(21*2048+118+4*j, 16'd1);
            end
            for (j = 0; j < 1100; j = j + 1) begin               // t4 entries
                be16(21*2048+1716+4*j, (j == 0) ? 16'd1 : (16'h2000 + j[15:0]));
                be16(21*2048+1718+4*j, 16'd1);
            end

            // VTS_PGCIT @22: 2 SRPs, entry_id 0 (NO title markers); SRP0->PGC@16,
            // SRP1->PGC@600. PGC1 = 2 programs / 2 cells (RBN0=0xB0, RBN1=0xB1)
            // with a program_map @240 {1,2}; PGC2 = 1 cell (RBN2=0xB2).
            be16(24*2048+0, 16'd2);
            img[24*2048+8]  = 8'h00; be32(24*2048+8+4, 32'd16);   // SRP[0]
            img[24*2048+16] = 8'h00; be32(24*2048+16+4, 32'd600); // SRP[1]
            put_pgc(24*2048+16,  8'd2, 16'd256);                   // 2 programs/2 cells
            be16(24*2048+16+230, 16'd240);                         // program_map_offset
            img[24*2048+16+240] = 8'd1;                            // program 1 -> cell 1
            img[24*2048+16+241] = 8'd2;                            // program 2 -> cell 2
            put_cell(24*2048+16, 16'd256, 0, 32'd0, 32'd15);       // PGC1 cell0 -> RBN0-15
            put_cell(24*2048+16, 16'd256, 1, 32'd16, 32'd31);      // PGC1 cell1 -> RBN16-31
            put_pgc(24*2048+600, 8'd1, 16'd256);
            be16(24*2048+600+230, 16'd240);                        // program_map_offset
            img[24*2048+600+240] = 8'd1;                           // program 1 -> cell 1
            put_cell(24*2048+600, 16'd256, 0, 32'd32, 32'd47);     // PGC2 -> RBN32-47

            for (j = 0; j < 16*2048; j = j + 1) begin
                img[25*2048+j]         = 8'hB0;    // RBN 0-15  (PGC1 cell0)
                img[(25+16)*2048+j]    = 8'hB1;    // RBN 16-31 (PGC1 cell1)
                img[(25+32)*2048+j]    = 8'hB2;    // RBN 32-47 (PGC2 cell0)
            end
        end
    endtask

    task do_jump(input [7:0] vts, input [6:0] ttn);
    begin
        @(negedge clk);
        jump_domain = 2'd3; jump_vts = vts; jump_pgcn = 0; jump_entry = 0;
        jump_ttn = ttn; jump_pgn = 0; jump_pulse = 1;
        @(negedge clk); jump_pulse = 0;
    end
    endtask

    // JumpVTS_PTT vts:ttn part -> exercises the exact PTT[part-1] resolve.
    task do_jump_ptt(input [7:0] vts, input [6:0] ttn, input [9:0] part);
    begin
        @(negedge clk);
        jump_domain = 2'd3; jump_vts = vts; jump_pgcn = 0; jump_entry = 0;
        jump_ttn = ttn; jump_pgn = 0; jump_ptt = part; jump_pulse = 1;
        @(negedge clk); jump_pulse = 0; jump_ptt = 0;
    end
    endtask

    task check_jump(input [7:0] want, input [255:0] label);
    begin
        post_jump_v = 0;
        begin : wj integer t; t = 0;
            while (!post_jump_v && t < 3000000) begin @(posedge clk); t = t + 1; end
        end
        if (post_jump_byte !== want) begin
            $display("FAIL %0s: streamed %02x, expected %02x", label, post_jump_byte, want);
            errors = errors + 1;
        end else $display("%0s -> %02x  PASS", label, want);
    end
    endtask

    task wait_bytes(input integer target);
        integer t; begin
            t = 0;
            while (cap_n < target && t < 3000000) begin @(posedge clk); t = t + 1; end
            if (cap_n < target) begin $display("FAIL: wait_bytes timeout"); errors = errors + 1; end
        end
    endtask

    // ---- Cross-PGC chapter-skip helpers -------------------------------------
    // A skip is pulsed while busy=1 (the 16-sector cell + full cache pin the
    // fetch cursor), then check_skip verifies WHICH path resolved it (seek_ack
    // = within-PGC program-map fast path, jump_ack = cross-PGC internal jump),
    // releases busy to sample the first streamed byte of the landing, and
    // re-freezes before polling cur_pgm (the GLOBAL chapter for the HUD).
    task chap_skip(input dir, input [4:0] mag);
    begin
        saw_seek_ack = 0; saw_jump_ack = 0; post_jump_v = 0;
        @(negedge clk);
        chap_dir = dir; chap_mag = mag; chap_pulse = 1;
        @(negedge clk); chap_pulse = 0;
    end
    endtask

    task check_skip(input [7:0] want, input expect_jump, input [7:0] want_ch,
                    input [255:0] label);
        integer t;
    begin
        t = 0;
        while (!saw_seek_ack && !saw_jump_ack && t < 3000000) begin
            @(posedge clk); t = t + 1;
        end
        if (!saw_seek_ack && !saw_jump_ack) begin
            $display("FAIL %0s: skip produced no seek/jump ack", label);
            errors = errors + 1;
        end else if (expect_jump && !saw_jump_ack) begin
            $display("FAIL %0s: resolved via SEEK, expected cross-PGC JUMP", label);
            errors = errors + 1;
        end else if (!expect_jump && !saw_seek_ack) begin
            $display("FAIL %0s: resolved via JUMP, expected within-PGC SEEK", label);
            errors = errors + 1;
        end
        busy = 0;
        t = 0;
        while (!post_jump_v && t < 3000000) begin @(posedge clk); t = t + 1; end
        if (post_jump_byte !== want) begin
            $display("FAIL %0s: streamed %02x, expected %02x", label, post_jump_byte, want);
            errors = errors + 1;
        end
        busy = 1;
        t = 0;
        while (cur_pgm_w !== want_ch && t < 3000000) begin @(posedge clk); t = t + 1; end
        if (cur_pgm_w !== want_ch) begin
            $display("FAIL %0s: cur_pgm=%0d, expected %0d (global chapter)",
                     label, cur_pgm_w, want_ch);
            errors = errors + 1;
        end else
            $display("%0s -> %02x ch%0d via %0s  PASS", label, want, want_ch,
                     expect_jump ? "jump" : "seek");
    end
    endtask

    task check_noop(input [7:0] want_ch, input [255:0] label);
        integer t;
    begin
        for (t = 0; t < 4000; t = t + 1) @(posedge clk);
        if (saw_seek_ack || saw_jump_ack) begin
            $display("FAIL %0s: expected NO move (seek=%0d jump=%0d)",
                     label, saw_seek_ack, saw_jump_ack);
            errors = errors + 1;
        end else if (cur_pgm_w !== want_ch) begin
            $display("FAIL %0s: cur_pgm=%0d, expected %0d", label, cur_pgm_w, want_ch);
            errors = errors + 1;
        end else
            $display("%0s -> no move, ch%0d  PASS", label, want_ch);
    end
    endtask

    integer a0;
    initial begin
        build; file_size = IMG_BYTES;
        repeat (5) @(negedge clk); rst_n = 1; repeat (5) @(negedge clk);
        start = 1; @(negedge clk); start = 0;
        // wait for nav_ready (mount idles in vm_mode)
        begin : wnr
            integer t; t = 0;
            while (!nav_ready_w && t < 2000000) begin @(posedge clk); t = t + 1; end
        end
        repeat (20) @(negedge clk);

        // TEST A: JumpVTS_TT 2 -> PGC 2 -> 0xB2
        post_jump_v = 0;
        do_jump(8'd1, 7'd2);
        begin : wa
            integer t; t = 0;
            while (!post_jump_v && t < 3000000) begin @(posedge clk); t = t + 1; end
        end
        if (post_jump_byte !== 8'hB2) begin
            $display("FAIL A: JumpVTS_TT 2 streamed %02x, expected B2 (PGC2)", post_jump_byte);
            errors = errors + 1;
        end else $display("TEST A: JumpVTS_TT 2 -> PGC 2 (0xB2)  PASS");

        // TEST B: JumpVTS_TT 1 -> PGC 1 -> 0xB0
        post_jump_v = 0;
        do_jump(8'd1, 7'd1);
        begin : wb
            integer t; t = 0;
            while (!post_jump_v && t < 3000000) begin @(posedge clk); t = t + 1; end
        end
        if (post_jump_byte !== 8'hB0) begin
            $display("FAIL B: JumpVTS_TT 1 streamed %02x, expected B0 (PGC1)", post_jump_byte);
            errors = errors + 1;
        end else $display("TEST B: JumpVTS_TT 1 -> PGC 1 (0xB0)  PASS");

        // ---- Phase-6 exact PTT part resolution (JumpVTS_PTT ttn:part) ----
        // TEST C: part 3 -> {pgc2, pg1} -> cross-PGC -> 0xB2
        do_jump_ptt(8'd1, 7'd1, 10'd3);
        check_jump(8'hB2, "TEST C: JumpVTS_PTT 1:3 (cross-PGC pgc2)");

        // TEST D: part 1 -> {pgc1, pg1} -> 0xB0 (PTT[0], unchanged behaviour)
        do_jump_ptt(8'd1, 7'd1, 10'd1);
        check_jump(8'hB0, "TEST D: JumpVTS_PTT 1:1 (pgc1 pg1)");

        // TEST E: part 2 -> {pgc1, pg2} -> start at program 2 = cell1 -> 0xB1
        do_jump_ptt(8'd1, 7'd1, 10'd2);
        check_jump(8'hB1, "TEST E: JumpVTS_PTT 1:2 (exact start-pgn program 2)");

        // ---- Stage B: resident ptt_mem load (title 1 = 3 PTTs) ----
        // TEST D above mounted title 1 (cur_ttn=1). ptt_mem should hold its TTU:
        //   [0]={pgc1,pg1}=0x0101 [1]={pgc1,pg2}=0x0102 [2]={pgc2,pg1}=0x0201
        do_jump_ptt(8'd1, 7'd1, 10'd1);  // mount title 1 fresh
        check_jump(8'hB0, "TEST F: (re)mount title 1 for ptt_mem check");
        repeat (40) @(negedge clk);
        if (dut.nr_ptt !== 11'd3) begin
            $display("FAIL: nr_ptt=%0d expected 3", dut.nr_ptt); errors = errors + 1;
        end else $display("ptt_mem: nr_ptt=3  PASS");
        if (dut.ptt_mem[0] !== 16'h0101 || dut.ptt_mem[1] !== 16'h0102 ||
            dut.ptt_mem[2] !== 16'h0201) begin
            $display("FAIL: ptt_mem[0..2]=%04x %04x %04x expected 0101 0102 0201",
                     dut.ptt_mem[0], dut.ptt_mem[1], dut.ptt_mem[2]);
            errors = errors + 1;
        end else $display("ptt_mem[0..2] = 0101 0102 0201  PASS");

        // ---- Phase-5 spec-hardening: >256-PTT load + >1024 graceful clamp ----
        // TEST G: title 3 authors 400 PTTs (the Scene_It class, 798/369 on real
        // discs) -- the whole TTU must load (old PTT_CAP=256 clamped it).
        do_jump_ptt(8'd1, 7'd3, 10'd1);
        check_jump(8'hB0, "TEST G: mount title 3 (400 PTTs)");
        repeat (40) @(negedge clk);
        if (dut.nr_ptt !== 11'd400) begin
            $display("FAIL G: nr_ptt=%0d expected 400 (>256 load)", dut.nr_ptt);
            errors = errors + 1;
        end else $display("ptt_mem: nr_ptt=400 (past the old 256 cap)  PASS");
        if (dut.ptt_mem[257] !== {16'h1000+16'd257, 8'h01} ||
            dut.ptt_mem[399] !== {16'h1000+16'd399, 8'h01}) begin
            $display("FAIL G: ptt_mem[257]=%06x [399]=%06x expected %06x %06x",
                     dut.ptt_mem[257], dut.ptt_mem[399],
                     {16'h1000+16'd257, 8'h01}, {16'h1000+16'd399, 8'h01});
            errors = errors + 1;
        end else $display("ptt_mem[257]/[399] pattern OK (sector-crossing load)  PASS");

        // TEST H: title 4 authors 1100 PTTs -> loads the first 1024 and clamps
        // gracefully (the beyond-spec-shelf guard now sits at 1024, not 256).
        do_jump_ptt(8'd1, 7'd4, 10'd1);
        check_jump(8'hB0, "TEST H: mount title 4 (1100 PTTs)");
        repeat (40) @(negedge clk);
        if (dut.nr_ptt !== 11'd1024) begin
            $display("FAIL H: nr_ptt=%0d expected 1024 (graceful clamp)", dut.nr_ptt);
            errors = errors + 1;
        end else $display("ptt_mem: nr_ptt=1024 (1100 clamped)  PASS");
        if (dut.ptt_mem[1023] !== {16'h2000+16'd1023, 8'h01}) begin
            $display("FAIL H: ptt_mem[1023]=%06x expected %06x",
                     dut.ptt_mem[1023], {16'h2000+16'd1023, 8'h01});
            errors = errors + 1;
        end else $display("ptt_mem[1023] pattern OK  PASS");

        // ---- Cross-PGC chapter skip (the ptt_mem read side, spec-hardening
        // Phase-5 follow-up). Title 1: ch1={pgc1,pg1} ch2={pgc1,pg2}
        // ch3={pgc2,pg1}; PGC2 has ONE program, so ch3 is only reachable/
        // leavable through the global PTT map. --------------------------------
        do_jump_ptt(8'd1, 7'd1, 10'd1);
        check_jump(8'hB0, "T-I0: re-mount title 1 ch1");
        busy = 1;
        begin : wq0 integer t; t = 0;
            while (cur_pgm_w !== 8'd1 && t < 3000000) begin @(posedge clk); t = t+1; end
            if (cur_pgm_w !== 8'd1) begin
                $display("FAIL T-I0: cur_pgm=%0d expected 1", cur_pgm_w); errors = errors+1;
            end
        end

        // T-I: next within PGC1 (ch1->ch2) = legacy program-map SEEK path
        chap_at_start = 1;
        chap_skip(1'b1, 5'd1);
        check_skip(8'hB1, 1'b0, 8'd2, "T-I: next ch1->ch2 (within-PGC)");

        // T-J: next crosses PGC1->PGC2 (ch2->ch3) = internal JumpVTS_PTT jump.
        // Landing in a 1-program PGC, cur_pgm must read the GLOBAL chapter 3.
        chap_skip(1'b1, 5'd1);
        check_skip(8'hB2, 1'b1, 8'd3, "T-J: next ch2->ch3 (cross-PGC)");

        // T-M: next at the last chapter = no move (legacy clamp rule)
        chap_skip(1'b1, 5'd1);
        check_noop(8'd3, "T-M: next at last chapter");

        // T-K: prev at ch3's start crosses back to ch2 = {pgc1,pg2}. Also
        // proves the arm relaxation: PGC2 has 1 program (the old
        // cmd_nr_pgm>1 guard would never have fired here).
        chap_at_start = 1;
        chap_skip(1'b0, 5'd1);
        check_skip(8'hB1, 1'b1, 8'd2, "T-K: prev ch3->ch2 (cross-PGC back)");

        // T-L: prev MID-chapter restarts the current chapter (legacy seek)
        chap_at_start = 0;
        chap_skip(1'b0, 5'd1);
        check_skip(8'hB1, 1'b0, 8'd2, "T-L: prev mid-chapter restarts ch2");

        // prev at ch2's start steps to ch1 (legacy within-PGC)
        chap_at_start = 1;
        chap_skip(1'b0, 5'd1);
        check_skip(8'hB0, 1'b0, 8'd1, "T-L2: prev ch2->ch1 (within-PGC)");

        // T-N: prev at the FIRST chapter clamps (restart ch1, stays ch1)
        chap_skip(1'b0, 5'd1);
        check_skip(8'hB0, 1'b0, 8'd1, "T-N: prev at first chapter clamps");

        // T-O: multi-chapter magnitude across the boundary: next x5 from ch1
        // clamps to ch3 (global clamp) and crosses in ONE jump
        chap_skip(1'b1, 5'd5);
        check_skip(8'hB2, 1'b1, 8'd3, "T-O: next x5 ch1->ch3 (clamped cross)");

        // T-P: single-chapter title (title 2: 1 PTT, 1 program) never arms
        busy = 0;
        do_jump(8'd1, 7'd2);
        check_jump(8'hB2, "T-P0: mount title 2 (single chapter)");
        busy = 1;
        repeat (100) @(negedge clk);
        saw_seek_ack = 0; saw_jump_ack = 0;
        chap_skip(1'b1, 5'd1);
        check_noop(8'd1, "T-P: single-chapter title skip is a no-op");
        busy = 0;

        if (errors == 0) $display("ISO_READER_PTT_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_PTT_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin #200000000; $display("GLOBAL TIMEOUT st=%0d cap=%0d", dut.state, cap_n); $finish; end

endmodule
