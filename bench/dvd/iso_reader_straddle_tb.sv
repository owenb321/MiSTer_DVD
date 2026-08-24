// iso_reader_straddle_tb.sv - sector-straddle regression for dvd/dvd_iso_reader.sv.
//
// The reader parses IFO structures from a SINGLE 2048-byte parse_buf. Multi-byte
// fields read through the 45-byte rbuf SHADOW (fetch_base-relative) used to WRAP a
// straddling byte to parse_buf[0] (garbage). The straddle audit made the shadow
// fetch SECTOR-CROSSING (fetch_xw), so a field that spans offset 2047 now reads the
// correct next-sector bytes. This TB proves it on the two shadow reads that were
// unguarded (and drove real dead-ends on game discs):
//
//   A) SRP-ENTRY straddle. The PGCIT SRP table is at LU[0].lang_start_byte, an
//      ARBITRARY (not necessarily 8-aligned) offset. When an SRP entry's
//      pgc_start_byte (@+4..+7) straddles 2047, the OLD code read parse_buf[0] for
//      the wrapped bytes -> a bogus pgc_start -> the PGC is positioned at the wrong
//      sector/offset -> wrong nr_cells / pgc_error. Here LU[0].lang_start_byte=2033
//      so SRP[0].pgc_start lands at in-sector bytes 2045..2048 (straddles into the
//      next sector). The reader must still position PGC-A correctly (pgc_off=100,
//      nr_cells=2).
//
//   B) PGC-HEADER pre-walk straddle (the retired give-up guard). nr_of_programs
//      (rbuf[2]) / nr_of_cells (rbuf[3]) / playback_time (rbuf[4..7]) are read from
//      the shadow at fetch_base=pgc_off. A PGC whose header starts at pgc_off in
//      2045..2047 pushes those bytes into the next sector. The OLD code bailed
//      (pgc_off>2044 -> pgc_error / linear fallback); the crossing shadow now reads
//      them. Here PGC-B starts at pgc_off=2046 and must load with nr_cells=3.
//
// Both jumps hold busy=1 (no streaming); the check is the PARSE OUTCOME latched at
// the cell-check state (S_PGC_CELLCHK=32), mirroring iso_reader_atmos_tb Phase-A.
// On the pre-fix RTL both cases FAIL (Test A: wrong pgc_off/pgc_error; Test B:
// pgc_error from the give-up guard).

`timescale 1ns/1ps

module iso_reader_straddle_tb;

    localparam IMG_BYTES = 34*2048;

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
    reg         busy = 1'b1;                // hold streaming: nav/parse only

    reg         jump_pulse = 0;
    reg  [1:0]  jump_domain = 0;
    reg  [7:0]  jump_vts = 0, jump_pgcn = 0, jump_cell = 0;
    reg  [3:0]  jump_entry = 0;
    wire        jump_ack, pgc_loaded, pgc_error, menu_active;

    reg  [7:0]  img [0:IMG_BYTES-1];

    localparam DOM_VTSM = 2'd2;

    integer n_pgc_error = 0, n_pgc_loaded = 0;
    always @(posedge clk) begin
        if (pgc_error)  n_pgc_error  = n_pgc_error + 1;
        if (pgc_loaded) n_pgc_loaded = n_pgc_loaded + 1;
    end

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(4'd0),
        .vbuf_empty(1'b0), .menu_snap(1'b0),
        .jump_ttn(7'd0), .jump_pgn(8'd0), .jump_ptt(10'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_pulse(1'b0), .seek_natural(1'b0), .seek_cell(8'd0), .seek_ack(),
        .cur_cell(), .cell_ready(),
        .jump_pulse(jump_pulse), .jump_natural(1'b0), .jump_domain(jump_domain), .jump_vts(jump_vts),
        .jump_pgcn(jump_pgcn), .jump_entry(jump_entry), .jump_cell(jump_cell),
        .jump_ack(jump_ack), .keep_vbuf(), .pgc_loaded(pgc_loaded), .pgc_error(pgc_error),
        .menu_active(menu_active), .still_active(), .cur_vts(), .best_menu_vts(),
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

    // ---- mock HPS: serve one 2048-byte block (sector) per sd_rd ----
    integer m = 0, bc = 0, lat = 0;
    reg [31:0] rlba = 0;
    always @(posedge clk) begin
        sd_buff_wr <= 1'b0;
        case (m)
        0: begin sd_ack <= 1'b0; if (sd_rd) begin rlba <= sd_lba; lat <= 3; m <= 1; end end
        1: begin if (lat!=0) lat<=lat-1; else begin sd_ack<=1'b1; bc<=0; m<=2; end end
        2: begin
            sd_ack <= 1'b1; sd_buff_wr <= 1'b1; sd_buff_addr <= bc[13:0];
            sd_buff_dout <= img[rlba*2048 + bc];
            bc <= bc + 1;
            if (bc == 2047) m <= 3;
        end
        3: begin sd_ack <= 1'b0; sd_buff_wr <= 1'b0; m <= 0; end
        endcase
    end

    // ---- image builders (subset of iso_reader_menu_tb) ----
    integer i;
    integer cur;

    task put_rec(input integer off, input [31:0] ext, input [31:0] dlen,
                 input [7:0] flags, input [127:0] nm, input integer nlen,
                 output integer next_off);
        integer j; integer rl;
        begin
            rl = 33 + nlen; if (rl[0]) rl = rl + 1;
            img[off+0] = rl[7:0]; img[off+1] = 0;
            img[off+2] = ext[7:0];   img[off+3] = ext[15:8];
            img[off+4] = ext[23:16]; img[off+5] = ext[31:24];
            for (j = 6;  j < 10; j = j + 1) img[off+j] = 0;
            img[off+10] = dlen[7:0];   img[off+11] = dlen[15:8];
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

    // PGC at absolute byte pa: nr_cells (=nr_programs), still, palette base,
    // command_tbl_offset, cell_playback_offset.
    task put_pgc(input integer pa, input [7:0] ncells, input [7:0] still,
                 input [7:0] pal, input [15:0] cmd_off, input [15:0] cpo);
        begin
            img[pa+2] = ncells; img[pa+3] = ncells;
            be16(pa+156, 16'd0); be16(pa+158, 16'd0); be16(pa+160, 16'd0);
            img[pa+162] = 8'h00; img[pa+163] = still;
            if (pal != 0)
                for (i = 0; i < 16; i = i + 1) begin
                    img[pa+164+i*4+0] = 8'h00;      img[pa+164+i*4+1] = pal + i[7:0];
                    img[pa+164+i*4+2] = 8'h80+i[7:0]; img[pa+164+i*4+3] = 8'h40+i[7:0];
                end
            be16(pa+228, cmd_off); be16(pa+230, 16'd0); be16(pa+232, cpo);
        end
    endtask

    task put_cell(input integer pa, input [15:0] cpo, input integer idx,
                  input [7:0] still, input [31:0] first, input [31:0] last);
        integer c;
        begin
            c = pa + cpo + idx*24;
            img[c+2] = still; img[c+3] = 0;
            be32(c+8, first); be32(c+20, last);
        end
    endtask

    // PGCI_UT at sector `sec`: 1 LU -> PGCIT at UT + lang_start (arbitrary), with
    // nr_srp SRPs. Straddle knob: lang_start places the PGCIT (and its SRP table)
    // at any in-sector offset.
    task put_ut_at(input integer sec, input [31:0] lang_start, input [15:0] nsrp);
        integer base;
        begin
            base = sec*2048;
            be16(base+0, 16'd1);                 // nr_of_lus
            be32(base+4, 32'd4000);              // last_byte (loose)
            be16(base+8, 16'h656E);              // LU[0].lang "en"
            img[base+10] = 0; img[base+11] = 8'h80;
            be32(base+12, lang_start);           // LU[0].lang_start_byte
            be16(base+lang_start+0, nsrp);       // PGCIT.nr_of_pgci_srp
            be32(base+lang_start+4, 32'd3000);   // PGCIT.last_byte (loose)
        end
    endtask

    // SRP[idx] at sector-relative (lang_start + 8 + 8*idx): entry_id + pgc_start.
    task put_srp_at(input integer sec, input [31:0] lang_start, input integer idx,
                    input [7:0] entry_id, input [31:0] pgc_start);
        integer a;
        begin
            a = sec*2048 + lang_start + 8 + idx*8;
            img[a] = entry_id;
            be32(a+4, pgc_start);
        end
    endtask

    task build_iso;
        integer L;
        begin
            for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = 8'h00;

            // PVD @16
            img[32768]=8'd1; img[32769]="C"; img[32770]="D"; img[32771]="0";
            img[32772]="0"; img[32773]="1"; img[32774]=8'd1;
            put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur);

            // root dir @17 -> VIDEO_TS @18
            cur = 17*2048;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 18, 2048, 8'h02, "VIDEO_TS", 8, cur);

            // VIDEO_TS dir @18
            cur = 18*2048;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 19, 4096, 8'h00, "VIDEO_TS.IFO;1", 14, cur);  // VMGI (2 sec)
            put_rec(cur, 30, 4096, 8'h00, "VIDEO_TS.VOB;1", 14, cur);  // VMGM VOB
            put_rec(cur, 21, 8192, 8'h00, "VTS_01_0.IFO;1", 14, cur);  // VTSI (4 sec)
            put_rec(cur, 28, 4096, 8'h00, "VTS_01_0.VOB;1", 14, cur);  // VTSM VOB
            put_rec(cur, 25, 6144, 8'h00, "VTS_01_1.VOB;1", 14, cur);  // title (3 sec)

            // VMGI_MAT @19 (tt_srpt unused; VMGM PGCI_UT -> sector 20)
            be32(19*2048+196, 32'd0);
            be32(19*2048+200, 32'd1);
            put_ut_at(20, 32'd16, 16'd1);
            put_srp_at(20, 32'd16, 0, 8'h82, 32'd64);
            put_pgc(20*2048+16+64, 8'd1, 8'd0, 8'h00, 16'd0, 16'd300);
            put_cell(20*2048+16+64, 16'd300, 0, 8'd0, 32'd0, 32'd0);

            // VTSI_MAT @21: vts_pgcit=+1 (22), vtsm_pgci_ut=+2 (23)
            be32(21*2048+204, 32'd1);
            be32(21*2048+208, 32'd2);

            // title VTS_PGCIT @22: 1 SRP, PGC @16, 1 cell -> a clean mount.
            be16(22*2048+0, 16'd1);
            be32(22*2048+8+4, 32'd16);
            put_pgc(22*2048+16, 8'd1, 8'd0, 8'h10, 16'd0, 16'd256);
            put_cell(22*2048+16, 16'd256, 0, 8'd0, 32'd0, 32'd0);

            // ===== VTSM PGCI_UT @23 with a STRADDLING SRP table =====
            // L=2033 -> PGCIT header @off2033; SRP[0].pgc_start bytes at in-sector
            // 2045..2048 (STRADDLE into sector 24). SRP[1] @off2049 (fully sec24).
            L = 2033;
            put_ut_at(23, L, 16'd2);
            //  SRP[0] -> PGC-A. pgc_start=115: pgc_off=(2033+115)&0x7FF=100, sector
            //  =23+((2033+115)>>11)=24. (A) proves srp_pgc_start read across 2047.
            put_srp_at(23, L, 0, 8'h83, 32'd115);
            //  SRP[1] -> PGC-B at pgc_off=2046. pgc_start=2061:
            //  (2033+2061)&0x7FF=2046, sector=23+(4094>>11)=24. (B) the header
            //  pre-walk bytes @2/@3/@4-7 straddle sector 24/25 (give-up-guard zone).
            put_srp_at(23, L, 1, 8'h00, 32'd2061);

            // PGC-A @ sector24 off100: 2 cells (distinctive), cmd tbl @236, cells @300.
            put_pgc(24*2048+100, 8'd2, 8'd0, 8'h20, 16'd236, 16'd300);
            be16(24*2048+100+236+0, 16'd1);            // nr_pre=1
            img[24*2048+100+236+8]  = 8'h20;           // a benign command
            put_cell(24*2048+100, 16'd300, 0, 8'd0,   32'd0, 32'd0);
            put_cell(24*2048+100, 16'd300, 1, 8'd255, 32'd1, 32'd1);

            // PGC-B @ sector24 off2046 (header straddles 24/25): 3 cells, cells @300
            // -> in sector 25. cmd tbl @236 (nr_pre=2).
            put_pgc(24*2048+2046, 8'd3, 8'd0, 8'h30, 16'd236, 16'd300);
            be16(24*2048+2046+236+0, 16'd2);           // nr_pre=2
            img[24*2048+2046+236+8]  = 8'h20;
            img[24*2048+2046+236+16] = 8'h20;
            put_cell(24*2048+2046, 16'd300, 0, 8'd0,   32'd0, 32'd0);
            put_cell(24*2048+2046, 16'd300, 1, 8'd0,   32'd1, 32'd1);
            put_cell(24*2048+2046, 16'd300, 2, 8'd255, 32'd2, 32'd2);
        end
    endtask

    integer errors = 0;
    task chk(input cond, input [255:0] msg);
        begin if (!cond) begin errors = errors + 1; $display("  ERR %0s", msg); end end
    endtask

    // Latch the parse outcome at S_PGC_CELLCHK (state 32) for a given PGCN.
    reg        probe_on = 0;
    reg [7:0]  probe_pgcn = 0;
    reg [7:0]  seen_ncells = 8'hFF;
    reg [10:0] seen_pgcoff = 11'h7FF;
    reg        seen = 0;
    always @(posedge clk)
        if (probe_on && dut.state == 6'd32 && dut.cur_pgcn == probe_pgcn && !seen) begin
            seen        <= 1'b1;
            seen_ncells <= dut.nr_cells;
            seen_pgcoff <= dut.pgc_off;
        end

    integer t;

    task do_jump(input [7:0] pgcn);
        begin
            @(posedge clk);
            jump_domain <= DOM_VTSM; jump_vts <= 8'd1; jump_pgcn <= pgcn;
            jump_entry <= 4'd0; jump_cell <= 8'd0;
            jump_pulse <= 1'b1; @(posedge clk); jump_pulse <= 1'b0;
        end
    endtask

    integer e0;

    initial begin
        build_iso();
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        file_size = IMG_BYTES;
        @(posedge clk); start = 1; @(posedge clk); start = 0;

        // wait for mount to fully settle into streaming (S_STREAM=10) so the
        // title PGC's own cell-check (cur_pgcn=1) can't be mistaken for a jump's.
        t = 0;
        while (dut.nav_ready !== 1'b1 && t < 400000) begin @(posedge clk); t = t+1; end
        chk(dut.nav_ready === 1'b1, "mount reached nav_ready");
        t = 0;
        while (dut.state !== 6'd10 && t < 400000) begin @(posedge clk); t = t+1; end
        chk(dut.state === 6'd10, "mount reached S_STREAM");
        repeat (50) @(posedge clk);

        // ---- Test A: SRP[0].pgc_start straddles 2047 -> PGC-A positioned right ----
        probe_pgcn = 8'd1; seen = 0; seen_ncells = 8'hFF; seen_pgcoff = 11'h7FF;
        probe_on = 1; e0 = n_pgc_error;
        do_jump(8'd1);
        t = 0;
        while (!seen && n_pgc_error == e0 && t < 200000) begin @(posedge clk); t = t+1; end
        probe_on = 0;
        $display("TEST A (SRP straddle): pgc_error(d)=%0d cur_pgcn=%0d pgc_off=%0d nr_cells=%0d",
                 n_pgc_error - e0, dut.cur_pgcn, seen_pgcoff, seen_ncells);
        chk(n_pgc_error == e0, "A: no pgc_error (srp_pgc_start read across the boundary)");
        chk(seen_pgcoff == 11'd100, "A: PGC-A positioned at pgc_off=100 (not a wrapped garbage offset)");
        chk(seen_ncells == 8'd2, "A: PGC-A nr_cells=2");
        repeat (40) @(posedge clk);

        // ---- Test B: PGC-B header at pgc_off=2046 (give-up-guard zone) ----
        probe_pgcn = 8'd2; seen = 0; seen_ncells = 8'hFF; seen_pgcoff = 11'h7FF;
        probe_on = 1; e0 = n_pgc_error;
        do_jump(8'd2);
        t = 0;
        while (!seen && n_pgc_error == e0 && t < 200000) begin @(posedge clk); t = t+1; end
        probe_on = 0;
        $display("TEST B (hdr pre-walk straddle): pgc_error(d)=%0d cur_pgcn=%0d pgc_off=%0d nr_cells=%0d",
                 n_pgc_error - e0, dut.cur_pgcn, seen_pgcoff, seen_ncells);
        chk(n_pgc_error == e0, "B: no pgc_error (header pre-walk bytes read across the boundary)");
        chk(seen_pgcoff == 11'd2046, "B: PGC-B header at pgc_off=2046");
        chk(seen_ncells == 8'd3, "B: PGC-B nr_cells=3 (read from the next sector, not zeroed/bailed)");

        if (errors == 0) $display("ISO_READER_STRADDLE_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_STRADDLE_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin #40000000; $display("ISO_READER_STRADDLE_TB: TIMEOUT (state=%0d)", dut.state); $finish; end

endmodule
