// iso_reader_autoptt_tb.sv - Disc Menus Off: the chapter table must belong to
// the PGC Auto actually plays (issue #132).
//
// Auto (vm_mode=0) loads VTS_PTT_SRPT at mount, BEFORE the PGC parse, and used
// to load title 1's table unconditionally. Its duration scan then picks the
// LONGEST PGC, which is often another title's PGC (X-Men: Apocalypse: title 1
// = PGCN 1, a 1 s stub with 1 chapter; the feature is PGCN 2 = title 2, 29
// chapters). The HUD read "CH n/1" and the seek bar had no notches.
//
// The fix reloads the table for the title the winner's SRP entry_id names
// (low 7 bits = VTS_TTN on EVERY title PGC, entry flag or not) and checks that
// the winner is actually in it; if not, nr_ptt = 0 and the HUD falls back to
// the PGC's own program count. Each arm is a fresh image + reset:
//
//   A  X-Men shape: PGCN2 eid 0x82, title 2 = 3 PTTs      -> ttn 2, nr_ptt 3
//   B  eid 0x82 but title 2's table lacks PGCN 2          -> ttn 2, nr_ptt 0
//   C  eid 0x01 (no entry flag), PGCN 2 inside title 1's
//      multi-PGC table (3 PTTs)                            -> ttn 1, nr_ptt 3
//   D  eid 0x02 (no entry flag), PGCN 2 in title 2 (2 PTTs) -> ttn 2, nr_ptt 2
//   F  OZ shape: PGCN1 is the 2 h scan winner but UNUSABLE (cells declared,
//      cell_playback_offset 0), so the reader falls through to PGCN2, eid 0x82,
//      title 2 = 3 PTTs                                      -> ttn 2, nr_ptt 3
//   E  C's shape, then prev-chapter from ch3 (PGCN 2) to ch2 = {pgc1, pg2}:
//      the cross-PGC chapter jump resolves to PGCN 1, which must NOT re-arm
//      the duration scan (it would land back on PGCN 2).
//
// Every table count differs from the one the pre-fix reader would publish, so
// no arm can pass on the old behaviour.
//
// Layout (2048-byte sectors):
//   16 PVD   17 root   18 VIDEO_TS dir   19 VIDEO_TS.IFO (no TT_SRPT)
//   20 VTSI_MAT (vts_ptt_srpt@200=+1 -> 21, vts_pgcit@204=+4 -> 24)
//   21 VTS_PTT_SRPT (2 titles, ttu_offset[0]=@16, title 2 right after title 1)
//   24 VTS_PGCIT: SRP0 -> PGC@64 (5 s, 2 programs/2 cells, RBN0-15 0xB0,
//      RBN16-31 0xB1); SRP1 -> PGC@600 (1 h, 1 cell, RBN32-47 0xB2)
//   25..72 VTS_01_1.VOB

`timescale 1ns/1ps

module iso_reader_autoptt_tb;

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

    reg         chap_pulse = 0;
    reg         chap_dir = 0;
    reg  [4:0]  chap_mag = 5'd1;
    reg         chap_at_start = 1;
    wire [7:0]  cur_pgm_w;
    wire [10:0] nr_ptt_w;
    wire [6:0]  res_ttn_w;
    wire        seek_ack, jump_ack;

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size),
        .lu_lang_pref(16'd0), .title_sel(7'd0),
        .vbuf_empty(1'b0), .aud_drained(1'b1), .disp_tick(1'b0), .disp_fps(6'd0),
        .seek_pulse(1'b0), .seek_cell(8'd0), .seek_natural(1'b0),
        .seek_rbn_pulse(1'b0), .seek_rbn(32'd0), .seek_tm_req(1'b0), .seek_tm_secs(17'd0),
        .chap_pulse(chap_pulse), .chap_dir(chap_dir), .chap_mag(chap_mag),
        .chap_at_start(chap_at_start), .angle_pulse(1'b0),
        .agl_vm(4'd0), .agl_vm_en(1'b0), .vm_pre_done(1'b0),
        .jump_pulse(1'b0), .jump_domain(2'd0), .jump_vts(8'd0), .jump_pgcn(16'd0),
        .jump_entry(4'd0), .jump_cell(8'd0), .jump_ttn(7'd0), .jump_pgn(8'd0),
        .jump_ptt(10'd0), .jump_natural(1'b0), .menu_btns_armed(1'b0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .attr_a_sel(3'd0), .attr_s_sel(3'd0),
        .cur_pgm(cur_pgm_w), .nr_ptt_o(nr_ptt_w), .res_ttn(res_ttn_w),
        .seek_ack(seek_ack), .jump_ack(jump_ack),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy)
    );

    always #5 clk = ~clk;

    // first streamed byte of the mount, and of each seek/jump landing
    integer   cap_n = 0;
    reg [7:0] first_byte = 0;
    reg       await_first = 0;
    reg [7:0] post_jump_byte = 0;
    reg       post_jump_v = 0;
    reg       saw_seek_ack = 0, saw_jump_ack = 0;
    always @(posedge clk) begin
        if (jump_ack || seek_ack) begin await_first <= 1'b1; post_jump_v <= 1'b0; end
        if (seek_ack) saw_seek_ack <= 1'b1;
        if (jump_ack) saw_jump_ack <= 1'b1;
        if (stream_valid) begin
            if (cap_n == 0) first_byte <= stream_data;
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

    task put_pgc(input integer pa, input [7:0] nprog, input [7:0] ncells, input [15:0] cpo);
        begin
            img[pa+2] = nprog; img[pa+3] = ncells;
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

    // PTT tables: t1 = n1 entries at @16, t2 = n2 entries at @64. Each entry
    // is {pgcn, pgn}, supplied through the ptt1/ptt2 arrays.
    reg [15:0] ptt1_pgcn [0:7], ptt1_pgn [0:7];
    reg [15:0] ptt2_pgcn [0:7], ptt2_pgn [0:7];
    reg        tb_decoy = 1'b0;   // arm F: PGCN1 is a 2 h decoy with no cell table

    task build(input [7:0] eid1, input [7:0] eid2, input integer n1, input integer n2);
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

            be32(19*2048+196, 32'd0);          // no TT_SRPT

            be32(20*2048+200, 32'd1);          // vts_ptt_srpt -> 21
            be32(20*2048+204, 32'd4);          // vts_pgcit    -> 24

            // VTS_PTT_SRPT @21. A title's chapter count is the SPAN between its
            // ttu_offset and the next one, so title 2 starts right after title 1.
            be16(21*2048+0, 16'd2);
            be32(21*2048+4, 32'd16 + 4*(n1+n2) - 1);   // last_byte
            be32(21*2048+8,  32'd16);                  // ttu_offset[0]
            be32(21*2048+12, 32'd16 + 4*n1);           // ttu_offset[1]
            for (j = 0; j < n1; j = j + 1) begin
                be16(21*2048+16+4*j, ptt1_pgcn[j]); be16(21*2048+18+4*j, ptt1_pgn[j]);
            end
            for (j = 0; j < n2; j = j + 1) begin
                be16(21*2048+16+4*n1+4*j, ptt2_pgcn[j]);
                be16(21*2048+18+4*n1+4*j, ptt2_pgn[j]);
            end

            // VTS_PGCIT @24: SRP0 -> PGC@64, SRP1 -> PGC@600. PGC 1 must not sit at @16:
            // with 2 SRPs the SRP table runs to byte 23 and PGC 1's header would
            // overwrite SRP[1] (the same trap iso_reader_pgc_tb TEST 4 records).
            be16(24*2048+0, 16'd2);
            img[24*2048+8]  = eid1; be32(24*2048+8+4, 32'd64);
            img[24*2048+16] = eid2; be32(24*2048+16+4, 32'd600);
            // PGC1: 00:00:05, 2 programs / 2 cells
            put_pgc(24*2048+64, 8'd2, 8'd2, tb_decoy ? 16'd0 : 16'd256);
            img[24*2048+64+6] = 8'h05;
            if (tb_decoy) img[24*2048+64+4] = 8'h02;   // 02:00:05 -> wins the scan
            be16(24*2048+64+230, 16'd240);
            img[24*2048+64+240] = 8'd1;
            img[24*2048+64+241] = 8'd2;
            put_cell(24*2048+64, 16'd256, 0, 32'd0, 32'd15);
            put_cell(24*2048+64, 16'd256, 1, 32'd16, 32'd31);
            // PGC2: 01:00:00, 1 program / 1 cell
            put_pgc(24*2048+600, 8'd1, 8'd1, 16'd256);
            img[24*2048+600+4] = 8'h01;
            be16(24*2048+600+230, 16'd240);
            img[24*2048+600+240] = 8'd1;
            put_cell(24*2048+600, 16'd256, 0, 32'd32, 32'd47);

            for (j = 0; j < 16*2048; j = j + 1) begin
                img[25*2048+j]      = 8'hB0;   // RBN 0-15  (PGC1 cell0)
                img[(25+16)*2048+j] = 8'hB1;   // RBN 16-31 (PGC1 cell1)
                img[(25+32)*2048+j] = 8'hB2;   // RBN 32-47 (PGC2 cell0)
            end
        end
    endtask

    // reset + mount; wait for the first streamed byte, then let the PTT state
    // settle (it is final before streaming starts).
    task mount;
        integer t;
        begin
            rst_n = 0; busy = 0; m = 0; cap_n = 0;
            repeat (5) @(negedge clk); rst_n = 1; repeat (5) @(negedge clk);
            start = 1; @(negedge clk); start = 0;
            t = 0;
            while (cap_n == 0 && t < 3000000) begin @(posedge clk); t = t + 1; end
            busy = 1;                          // pin the fetch cursor in the cell
            repeat (40) @(negedge clk);
        end
    endtask

    task check_mount(input [7:0] want_byte, input [6:0] want_ttn, input [10:0] want_nr,
                     input [511:0] label);
        begin
            $display("  [%0s] cell_mode=%b cell_count=%0d cur_pgcn=%0d iso_mode=%b", label,
                     dut.cell_mode, dut.cell_count, dut.cur_pgcn, dut.iso_mode);
            if (cap_n == 0) begin
                $display("FAIL %0s: nothing streamed", label); errors = errors + 1;
            end else if (first_byte !== want_byte) begin
                $display("FAIL %0s: streamed %02x, expected %02x", label, first_byte, want_byte);
                errors = errors + 1;
            end else if (dut.cur_ttn !== want_ttn) begin
                $display("FAIL %0s: cur_ttn=%0d, expected %0d", label, dut.cur_ttn, want_ttn);
                errors = errors + 1;
            end else if (nr_ptt_w !== want_nr) begin
                $display("FAIL %0s: nr_ptt=%0d, expected %0d", label, nr_ptt_w, want_nr);
                errors = errors + 1;
            end else if (res_ttn_w !== want_ttn) begin
                $display("FAIL %0s: res_ttn=%0d, expected %0d", label, res_ttn_w, want_ttn);
                errors = errors + 1;
            end else
                $display("%0s -> %02x ttn %0d nr_ptt %0d  PASS", label, want_byte, want_ttn, want_nr);
        end
    endtask

    initial begin
        file_size = IMG_BYTES;

        // ---- A: the X-Men: Apocalypse shape --------------------------------
        ptt1_pgcn[0] = 1; ptt1_pgn[0] = 1;
        ptt2_pgcn[0] = 2; ptt2_pgn[0] = 1;
        ptt2_pgcn[1] = 2; ptt2_pgn[1] = 1;
        ptt2_pgcn[2] = 2; ptt2_pgn[2] = 1;
        build(8'h81, 8'h82, 1, 3);
        mount;
        check_mount(8'hB2, 7'd2, 11'd3, "A: winner is title 2's entry PGC");

        // ---- B: entry_id names title 2, whose table lacks PGCN 2 -----------
        ptt1_pgcn[0] = 1; ptt1_pgn[0] = 1;
        ptt2_pgcn[0] = 1; ptt2_pgn[0] = 1;
        ptt2_pgcn[1] = 1; ptt2_pgn[1] = 2;
        build(8'h81, 8'h82, 1, 2);
        mount;
        check_mount(8'hB2, 7'd2, 11'd0, "B: winner not in its title's table");

        // ---- C: no entry flag, PGCN 2 inside title 1's multi-PGC table -----
        ptt1_pgcn[0] = 1; ptt1_pgn[0] = 1;
        ptt1_pgcn[1] = 1; ptt1_pgn[1] = 2;
        ptt1_pgcn[2] = 2; ptt1_pgn[2] = 1;
        ptt2_pgcn[0] = 1; ptt2_pgn[0] = 1;
        build(8'h81, 8'h01, 3, 1);
        mount;
        check_mount(8'hB2, 7'd1, 11'd3, "C: non-entry PGC in title 1's table");

        // ---- D: no entry flag, PGCN 2 in title 2's table -------------------
        ptt1_pgcn[0] = 1; ptt1_pgn[0] = 1;
        ptt2_pgcn[0] = 2; ptt2_pgn[0] = 1;
        ptt2_pgcn[1] = 2; ptt2_pgn[1] = 1;
        build(8'h81, 8'h02, 1, 2);
        mount;
        check_mount(8'hB2, 7'd2, 11'd2, "D: non-entry PGC names title 2");

        // ---- F: the scan's winner is unusable; the next PGC takes over ------
        ptt1_pgcn[0] = 1; ptt1_pgn[0] = 1;
        ptt2_pgcn[0] = 2; ptt2_pgn[0] = 1;
        ptt2_pgcn[1] = 2; ptt2_pgn[1] = 1;
        ptt2_pgcn[2] = 2; ptt2_pgn[2] = 1;
        tb_decoy = 1'b1;
        build(8'h81, 8'h82, 1, 3);
        tb_decoy = 1'b0;
        mount;
        check_mount(8'hB2, 7'd2, 11'd3, "F: unusable winner falls through to title 2");

        // ---- E: C's shape, prev-chapter across into PGCN 1 -----------------
        ptt1_pgcn[0] = 1; ptt1_pgn[0] = 1;
        ptt1_pgcn[1] = 1; ptt1_pgn[1] = 2;
        ptt1_pgcn[2] = 2; ptt1_pgn[2] = 1;
        ptt2_pgcn[0] = 1; ptt2_pgn[0] = 1;
        build(8'h81, 8'h01, 3, 1);
        mount;
        begin : e_arm
            integer t;
            t = 0;
            while (cur_pgm_w !== 8'd3 && t < 3000000) begin @(posedge clk); t = t + 1; end
            if (cur_pgm_w !== 8'd3) begin
                $display("FAIL E0: cur_pgm=%0d at mount, expected 3", cur_pgm_w);
                errors = errors + 1;
            end
            saw_seek_ack = 0; saw_jump_ack = 0; post_jump_v = 0;
            chap_at_start = 1;
            @(negedge clk); chap_dir = 1'b0; chap_mag = 5'd1; chap_pulse = 1;
            @(negedge clk); chap_pulse = 0;
            t = 0;
            while (!saw_jump_ack && !saw_seek_ack && t < 3000000) begin @(posedge clk); t = t + 1; end
            if (!saw_jump_ack) begin
                $display("FAIL E: prev ch3->ch2 did not resolve as a cross-PGC jump (seek=%0d)",
                         saw_seek_ack);
                errors = errors + 1;
            end
            busy = 0;
            t = 0;
            while (!post_jump_v && t < 3000000) begin @(posedge clk); t = t + 1; end
            if (post_jump_byte !== 8'hB1) begin
                $display("FAIL E: prev ch3->ch2 streamed %02x, expected B1 ({pgc1,pg2})",
                         post_jump_byte);
                errors = errors + 1;
            end else if (dut.cur_pgcn !== 16'd1) begin
                $display("FAIL E: cur_pgcn=%0d after the chapter jump, expected 1", dut.cur_pgcn);
                errors = errors + 1;
            end else
                $display("E: prev ch3->ch2 lands on PGCN 1 program 2 (B1)  PASS");
        end

        if (errors == 0) $display("ISO_READER_AUTOPTT_TB: ALL TESTS PASSED");
        else begin
            $display("ISO_READER_AUTOPTT_TB: FAILED with %0d errors", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin #400000000; $display("GLOBAL TIMEOUT st=%0d cap=%0d", dut.state, cap_n); $fatal(1); end

endmodule
