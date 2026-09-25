// ============================================================================
// bench/dvd/iso_reader_tmap_tb.sv -- TIME seek through the VTS time map
// (Phase 8b reopened, issue #127; dvd/dvd_iso_reader.sv S_TMAP)
// ============================================================================
// The iso_reader_scrub_tb disc (4 cells x 10 sectors, every sector filled with a
// byte == its own RBN, so the delivered stream names the landing sector exactly)
// plus a VTS_TMAPT in the IFO. NAV_CAP=1: the fixture has no NAV packs, so the
// snap probe gives up after one read and the landing IS the resolved sector.
// Scored against the landing sector read out of the delivered bytes, never a
// signal the lookup names.
//   A  tmu=1 map, deliberately NOT linear in RBN:
//      A1 t=3  -> entry 2 = RBN 20 (the fallback 7 must NOT be used)
//      A2 t=0  -> the title's first sector (libdvdnav's "entry -1")
//      A3 t=99 -> past the map: the last entry, RBN 38
//      A4 a repeat seek re-uses the cached header: ONE IFO read, not five
//      (entry 2 carries the discontinuity bit, which must be masked)
//   B  tmu=2 map after a REMOUNT (the cache must not survive it):
//      B1 t=5 -> between entries 1 (14) and 2 (30): 14 + 16*1/2 = RBN 22
//      B2 t=3 -> between the title start... entries 0 (10) and 1 (14): RBN 12
//   C  no TMAPT            -> the caller's fallback RBN, tmap_fell
//   D  entry past the title -> fallback (a map that is not this title's)
//   E  an empty map         -> fallback
//   F  a plain sector scrub (seek_tm_req = 0) is unchanged
// ============================================================================
`timescale 1ns/1ps

module iso_reader_tmap_tb;

    localparam CELLSEC   = 10;              // sectors per cell (> 16 KB cache)
    localparam VOBSEC    = 4*CELLSEC;       // 40 title sectors
    localparam IMG_BYTES = 64*2048;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [63:0] file_size = 0;

    // transport seek + scrub ports
    reg         seek_pulse = 0;
    reg  [7:0]  seek_cell = 0;
    reg         seek_rbn_pulse = 0;
    reg  [31:0] seek_rbn = 0;
    reg         seek_tm_req = 0;
    reg  [16:0] seek_tm_secs = 0;
    wire        tmap_used, tmap_fell;
    wire        seek_ack;
    wire [7:0]  cur_cell;
    wire        cell_ready;

    wire [31:0] sd_lba;
    wire        sd_rd;
    reg         sd_ack = 0;
    reg  [13:0] sd_buff_addr = 0;
    reg  [7:0]  sd_buff_dout = 0;
    reg         sd_buff_wr = 0;

    wire [7:0]  stream_data;
    wire        stream_valid;
    reg         busy = 0;

    wire        debug_iso_mode, debug_iso_error;
    wire [15:0] debug_state;

    reg  [7:0]  img [0:IMG_BYTES-1];

    // ---- capture (rolling) ----
    integer cap_n = 0;
    reg [7:0] cap [0:65535];
    always @(posedge clk)
        if (stream_valid) begin
            cap[cap_n] = stream_data;
            cap_n = cap_n + 1;
        end

    // ---- seek_ack sticky monitor ----
    wire keep_vbuf;
    reg ack_seen = 0;
    always @(posedge clk) if (seek_ack) ack_seen <= 1'b1;

    dvd_iso_reader #(.NAV_CAP(1)) dut (
        // new reader inputs tied off: a floating input is X, and X on
        // agl_vm_en would poison the angle resolve (see the port comments).
        .agl_vm(4'd0), .agl_vm_en(1'b0), .vm_pre_done(1'b0),
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(4'd0), .aud_drained(1'b1), .vbuf_empty(1'b0), .menu_snap(1'b0),
        .jump_ttn(7'd0), .jump_pgn(8'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_pulse(seek_pulse), .seek_natural(1'b0), .seek_cell(seek_cell), .seek_ack(seek_ack),
        .seek_rbn_pulse(seek_rbn_pulse), .seek_rbn(seek_rbn), .seek_tm_req(seek_tm_req), .seek_tm_secs(seek_tm_secs),
        .tmap_used(tmap_used), .tmap_fell(tmap_fell),
        .keep_vbuf(keep_vbuf),
        .cur_cell(cur_cell), .cell_ready(cell_ready),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .debug_active(), .debug_sd_rd(), .debug_sd_ack(), .debug_cache_has_data(),
        .debug_file_size(), .debug_total_sectors(), .debug_next_lba(),
        .debug_state(debug_state), .debug_iso_mode(debug_iso_mode),
        .debug_iso_error(debug_iso_error)
    );

    always #5 clk = ~clk;

    // ---- mock HPS: serve one 2048-byte block (sector) per sd_rd ----
    integer m = 0;
    integer ifo_reads = 0;                   // reads of VTS_01_0.IFO (sectors 21..23)
    always @(posedge clk) if (sd_rd && m == 0 && sd_lba >= 21 && sd_lba <= 23) ifo_reads = ifo_reads + 1;
    integer bc = 0;
    reg [31:0] rlba = 0;
    integer lat = 0;
    always @(posedge clk) begin
        sd_ack       <= sd_ack;
        sd_buff_wr   <= 1'b0;
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

    // ---- image builders (shared skeleton with iso_reader_seek_tb) ----
    integer i;
    integer cur;

    task fill_sec(input integer sec, input [7:0] v);
        integer j;
        begin
            for (j = 0; j < 2048; j = j + 1) img[sec*2048 + j] = v;
        end
    endtask

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

    task put_vmgi(input integer sec, input [31:0] tt_srpt_ptr);
        integer base;
        begin
            base = sec*2048;
            img[base+196] = tt_srpt_ptr[31:24]; img[base+197] = tt_srpt_ptr[23:16];
            img[base+198] = tt_srpt_ptr[15:8];  img[base+199] = tt_srpt_ptr[7:0];
        end
    endtask

    task put_tt_srpt(input integer sec, input [15:0] nsrpts, input [7:0] title1_vtsn);
        integer base;
        begin
            base = sec*2048;
            img[base+0] = nsrpts[15:8]; img[base+1] = nsrpts[7:0];
            img[base+8]  = 8'h00; img[base+9] = 8'h01;
            img[base+10] = 8'h00; img[base+11] = 8'h01;
            img[base+12] = 8'h00; img[base+13] = 8'h00;
            img[base+14] = title1_vtsn;
            img[base+15] = 8'h01;
        end
    endtask

    task put_vtsi_mat(input integer sec, input [31:0] vts_pgcit_ptr);
        integer base;
        begin
            base = sec*2048;
            img[base+204] = vts_pgcit_ptr[31:24]; img[base+205] = vts_pgcit_ptr[23:16];
            img[base+206] = vts_pgcit_ptr[15:8];  img[base+207] = vts_pgcit_ptr[7:0];
        end
    endtask

    task put_pgcit(input integer sec, input [31:0] pgc_start_byte,
                   input [7:0] nr_cells, input [15:0] cell_pb_off);
        integer base; integer pgc;
        begin
            base = sec*2048;
            img[base+0] = 8'h00; img[base+1] = 8'h01;
            img[base+12] = pgc_start_byte[31:24]; img[base+13] = pgc_start_byte[23:16];
            img[base+14] = pgc_start_byte[15:8];  img[base+15] = pgc_start_byte[7:0];
            pgc = base + pgc_start_byte;
            img[pgc+2] = 8'h01;
            img[pgc+3] = nr_cells;
            img[pgc+232] = cell_pb_off[15:8];
            img[pgc+233] = cell_pb_off[7:0];
        end
    endtask

    task put_cell(input integer sec, input [31:0] pgc_start_byte,
                  input [15:0] cell_pb_off, input integer idx,
                  input [31:0] first_sector, input [31:0] last_sector);
        integer c;
        begin
            c = sec*2048 + pgc_start_byte + cell_pb_off + idx*24;
            img[c+8]  = first_sector[31:24]; img[c+9]  = first_sector[23:16];
            img[c+10] = first_sector[15:8];  img[c+11] = first_sector[7:0];
            img[c+20] = last_sector[31:24];  img[c+21] = last_sector[23:16];
            img[c+22] = last_sector[15:8];   img[c+23] = last_sector[7:0];
        end
    endtask

    // VTS_TMAPT at IFO-relative sector 2 (absolute 23): one map, at TMAPT+12.
    reg [31:0] tment [0:15];
    task put_tmap(input [31:0] tmapt_ptr, input [7:0] tmu, input [15:0] nent);
        integer b, j;
        begin
            b = 21*2048;
            img[b+212] = tmapt_ptr[31:24]; img[b+213] = tmapt_ptr[23:16];
            img[b+214] = tmapt_ptr[15:8];  img[b+215] = tmapt_ptr[7:0];
            b = 23*2048;
            for (j = 0; j < 2048; j = j + 1) img[b+j] = 8'h00;
            img[b+0] = 8'h00; img[b+1] = 8'h01;            // nr_of_tmaps = 1
            img[b+8] = 8'h00; img[b+9] = 8'h00; img[b+10] = 8'h00; img[b+11] = 8'd12;
            img[b+12] = tmu; img[b+13] = 8'h00;
            img[b+14] = nent[15:8]; img[b+15] = nent[7:0];
            for (j = 0; j < nent; j = j + 1) begin
                img[b+16+4*j]   = tment[j][31:24]; img[b+16+4*j+1] = tment[j][23:16];
                img[b+16+4*j+2] = tment[j][15:8];  img[b+16+4*j+3] = tment[j][7:0];
            end
        end
    endtask

    // 4-cell disc, cells in physical order (cell k -> RBN 10k..10k+9). Each
    // sector is filled with a byte == its own RBN so the captured stream
    // reveals the exact target sector.
    task build_iso;
        begin
            for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = 8'h00;

            img[32768] = 8'd1;
            img[32769] = "C"; img[32770] = "D"; img[32771] = "0";
            img[32772] = "0"; img[32773] = "1"; img[32774] = 8'd1;
            put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur);

            cur = 34816;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 18, 2048, 8'h02, "VIDEO_TS", 8, cur);

            cur = 36864;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 19, 4096,        8'h00, "VIDEO_TS.IFO;1", 14, cur);
            put_rec(cur, 21, 6144,        8'h00, "VTS_01_0.IFO;1", 14, cur);
            put_rec(cur, 24, VOBSEC*2048, 8'h00, "VTS_01_1.VOB;1", 14, cur);

            put_vmgi(19, 32'd1);
            put_tt_srpt(20, 16'd1, 8'd1);

            put_vtsi_mat(21, 32'd1);
            put_pgcit(22, 32'd16, 8'd4, 16'd256);
            put_cell(22, 32'd16, 16'd256, 0, 32'd0,  32'd9);
            put_cell(22, 32'd16, 16'd256, 1, 32'd10, 32'd19);
            put_cell(22, 32'd16, 16'd256, 2, 32'd20, 32'd29);
            put_cell(22, 32'd16, 16'd256, 3, 32'd30, 32'd39);

            for (i = 0; i < VOBSEC; i = i + 1)
                fill_sec(24 + i, i[7:0]);       // sector RBN i -> byte i
        end
    endtask

    // ---- helpers ----
    integer errors = 0;
    integer k;
    integer reads_at;

    task mount;
        begin
            file_size = IMG_BYTES;
            cap_n = 0;                       // or a stale count ends the wait at once
            @(posedge clk); start = 1; @(posedge clk); start = 0;
            wait_bytes(1024);
            if (dut.cell_mode !== 1'b1) begin
                errors = errors + 1; $display("  FAIL: remount never reached cell mode");
            end
            cap_n = 0;
        end
    endtask

    task do_seek(input tm, input [16:0] secs, input [31:0] fb_rbn);
        integer tt;
        begin
            ack_seen = 1'b0; reads_at = ifo_reads;
            @(posedge clk); seek_rbn_pulse <= 1'b1; seek_rbn <= fb_rbn;
                            seek_tm_req <= tm; seek_tm_secs <= secs;
            @(posedge clk); seek_rbn_pulse <= 1'b0; seek_tm_req <= 1'b0;
            tt = 0;
            while (!ack_seen && tt < 200000) begin @(posedge clk); tt = tt + 1; end
            // let the lookup + snap + cell load finish, then capture fresh bytes
            tt = 0;
            while (dut.state != 6'd10 && tt < 2000000) begin @(posedge clk); tt = tt + 1; end
            repeat (50) @(posedge clk);
            cap_n = 0;
        end
    endtask

    task wait_bytes(input integer n);
        integer tt;
        begin
            tt = 0;
            while (cap_n < n && tt < 4000000) begin @(posedge clk); tt = tt + 1; end
        end
    endtask

    task expect_rbn(input [7:0] want, input used, input [8*64-1:0] label);
        integer mm;
        begin
            wait_bytes(1024);
            mm = 0;
            for (k = 0; k < 1024 && k < cap_n; k = k + 1)
                if (cap[k] !== want) mm = mm + 1;
            if (mm != 0 || cap_n < 1024) begin
                errors = errors + 1;
                $display("  FAIL: %0s - landed on RBN %0d, want %0d (%0d/1024 wrong)",
                         label, cap[0], want, mm);
            end else if (tmap_used !== used || tmap_fell !== !used) begin
                errors = errors + 1;
                $display("  FAIL: %0s - RBN %0d ok but tmap_used=%b tmap_fell=%b (want used=%b)",
                         label, want, tmap_used, tmap_fell, used);
            end else
                $display("  ok: %0s - RBN %0d, %0s", label, want, used ? "through the map" : "fallback");
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ---- A: tmu = 1, a map deliberately NOT linear in RBN ----------------
        build_iso;
        tment[0] = 32'd3;  tment[1] = 32'd5;  tment[2] = 32'h8000_0014; // disc bit + RBN 20
        tment[3] = 32'd22; tment[4] = 32'd30; tment[5] = 32'd34; tment[6] = 32'd38;
        put_tmap(32'd2, 8'd1, 16'd7);
        mount;
        do_seek(1'b1, 17'd3, 32'd7);   expect_rbn(8'd20, 1'b1, "A1 t=3 -> entry 2 (masked disc bit)");
        if (ifo_reads - reads_at < 4) begin
            errors = errors + 1; $display("  FAIL: A1 made %0d IFO reads; a cold lookup needs >= 4", ifo_reads - reads_at);
        end
        do_seek(1'b1, 17'd0, 32'd7);   expect_rbn(8'd0,  1'b1, "A2 t=0 -> the title's first sector");
        if (ifo_reads - reads_at != 1) begin
            errors = errors + 1; $display("  FAIL: A4 cached lookup made %0d IFO reads, want 1", ifo_reads - reads_at);
        end else $display("  ok: A4 the cached header costs one IFO read");
        do_seek(1'b1, 17'd99, 32'd7);  expect_rbn(8'd38, 1'b1, "A3 t=99 -> past the map: the last entry");

        // ---- B: tmu = 2 after a remount: interpolation, and no stale cache ---
        build_iso;
        tment[0] = 32'd10; tment[1] = 32'd14; tment[2] = 32'd30; tment[3] = 32'd36;
        put_tmap(32'd2, 8'd2, 16'd4);
        mount;
        do_seek(1'b1, 17'd5, 32'd7);   expect_rbn(8'd22, 1'b1, "B1 t=5 -> 14 + (30-14)*1/2");
        do_seek(1'b1, 17'd3, 32'd7);   expect_rbn(8'd12, 1'b1, "B2 t=3 -> 10 + (14-10)*1/2");

        // ---- C: no time map ---------------------------------------------------
        build_iso; put_tmap(32'd0, 8'd1, 16'd0); mount;
        do_seek(1'b1, 17'd3, 32'd17);  expect_rbn(8'd17, 1'b0, "C no TMAPT -> the fallback");

        // ---- D: an entry past this title's sectors ----------------------------
        build_iso;
        tment[0] = 32'd3; tment[1] = 32'd500; tment[2] = 32'd501;
        put_tmap(32'd2, 8'd1, 16'd3); mount;
        do_seek(1'b1, 17'd1, 32'd17);  expect_rbn(8'd17, 1'b0, "D implausible entry -> the fallback");

        // ---- E: an empty map --------------------------------------------------
        build_iso; put_tmap(32'd2, 8'd0, 16'd0); mount;
        do_seek(1'b1, 17'd3, 32'd17);  expect_rbn(8'd17, 1'b0, "E empty map -> the fallback");

        // ---- F: a plain sector scrub is unchanged ----------------------------
        do_seek(1'b0, 17'd3, 32'd25);  wait_bytes(1024);
        if (cap[0] !== 8'd25) begin errors = errors + 1; $display("  FAIL: F plain scrub landed on %0d, want 25", cap[0]); end
        else $display("  ok: F plain sector scrub -> RBN 25");

        if (errors == 0) $display("ISO_READER_TMAP_TB: ALL TESTS PASSED");
        else begin $display("ISO_READER_TMAP_TB: FAILED with %0d errors", errors); $fatal(1); end
        $finish;
    end

    initial begin
        #400000000;
        $display("ISO_READER_TMAP_TB: TIMEOUT");
        $fatal(1);
    end

endmodule
