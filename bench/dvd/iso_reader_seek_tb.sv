// iso_reader_seek_tb.sv - transport SEEK test for dvd/dvd_iso_reader.sv.
//
// The gamepad transport (emu.sv) can jump playback to an arbitrary PGC cell by
// pulsing seek_pulse with seek_cell. This tb drives that port directly and
// proves the reader re-streams from the target cell (forward + backward),
// no-ops an out-of-range target, and reports cur_cell / seek_ack correctly.
//
// Disc: ONE title set (VTS_01), a 4-cell PGC in physical order. Each cell spans
// CELLSEC=10 sectors (20 KB) of a single distinct marker byte, so the captured
// stream identifies which cell is playing:
//   cell0 -> RBN  0..9  = 0xB0    cell1 -> RBN 10..19 = 0xB1
//   cell2 -> RBN 20..29 = 0xB2    cell3 -> RBN 30..39 = 0xB3
// (reorder is already covered by iso_reader_pgc_tb; here order is physical so
//  the ONLY thing that changes the marker mid-stream is a seek.)
//
// Cells are deliberately LARGER than the reader's 16 KB read-ahead cache so the
// fetch pointer (cur_cell = cell_i) can't race whole cells ahead of the display
// - which mirrors real DVDs (multi-MB cells) and keeps cur_cell == displayed
// cell within the sub-cell cache lead.
//
// Layout (2048-byte logical sectors), same skeleton as iso_reader_pgc_tb:
//   16 PVD  17 root  18 VIDEO_TS dir
//   19 VMGI sec0 (VMGI_MAT tt_srpt@196 -> 20)   20 VMGI TT_SRPT
//   21 VTSI sec0 (VTSI_MAT vts_pgcit@204 -> 22) 22 VTS_PGCIT+PGC+cells
//   24..63 VTS_01_1.VOB RBN 0..39 (four 10-sector cells)

`timescale 1ns/1ps

module iso_reader_seek_tb;

    localparam CELLSEC   = 10;              // sectors per cell (> 16 KB cache)
    localparam VOBSEC    = 4*CELLSEC;       // 40 title sectors
    localparam IMG_BYTES = 64*2048;
    localparam SECBYTES  = 2048;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [63:0] file_size = 0;

    // transport seek port
    reg         seek_pulse = 0;
    reg  [7:0]  seek_cell = 0;
    reg         seek_rbn_pulse = 0;    // Phase-8 sub-cell scrub
    reg  [31:0] seek_rbn = 0;
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

    // ---- seek_ack sticky monitor (per-window) ----
    wire keep_vbuf;
    reg ack_seen = 0;
    reg kv_at_seek = 1'bx;   // keep_vbuf captured at the transport seek_ack
    always @(posedge clk) if (seek_ack) begin ack_seen <= 1'b1; kv_at_seek <= keep_vbuf; end

    // NAV_CAP(8): a small VOBU-align probe budget so TEST7 can exhaust it on this
    // 40-sector title (TEST8 exercises the title-end clamp before the budget runs).
    dvd_iso_reader #(.NAV_CAP(8)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(4'd0), .vbuf_empty(1'b0), .menu_snap(1'b0),
        // Phase-4 DVD-VM ports: legacy mode (vm_mode=0 keeps prior behaviour)
        .jump_ttn(7'd0), .jump_pgn(8'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_pulse(seek_pulse), .seek_natural(1'b0), .seek_cell(seek_cell), .seek_ack(seek_ack),
        .seek_rbn_pulse(seek_rbn_pulse), .seek_rbn(seek_rbn),
        .chap_pulse(1'b0), .chap_dir(1'b0), .chap_mag(5'd1),
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

    // ---- image builders (shared skeleton with iso_reader_pgc_tb) ----
    integer i;
    integer cur;

    task fill_sec(input integer sec, input [7:0] v);
        integer j;
        begin
            for (j = 0; j < 2048; j = j + 1) img[sec*2048 + j] = v;
        end
    endtask

    // Overlay a NAV-pack (VOBU-first) signature onto an already-marker-filled VOB
    // sector at title RBN `rbn` (= image sector 24+rbn). The reader's nav_sig_hit
    // matches on bytes 0-3=00 00 01 BA, 14-17=00 00 01 BB, 38-41=00 00 01 BF; the
    // rest of the sector keeps its cell marker. Extra fields (pack marker@4,
    // stuffing@13, system-header length@18) are cosmetic realism.
    task put_nav(input integer rbn);
        integer base;
        begin
            base = (24 + rbn) * 2048;
            img[base+0]  = 8'h00; img[base+1]  = 8'h00; img[base+2]  = 8'h01; img[base+3]  = 8'hBA;
            img[base+4]  = 8'h44;                        // MPEG-2 pack marker
            img[base+13] = 8'hF8;                        // stuffing_length = 0
            img[base+14] = 8'h00; img[base+15] = 8'h00; img[base+16] = 8'h01; img[base+17] = 8'hBB;
            img[base+18] = 8'h00; img[base+19] = 8'h12; // system_header length
            img[base+38] = 8'h00; img[base+39] = 8'h00; img[base+40] = 8'h01; img[base+41] = 8'hBF;
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
            img[base+0] = 8'h00; img[base+1] = 8'h01;    // nr_of_pgci_srp = 1
            img[base+12] = pgc_start_byte[31:24]; img[base+13] = pgc_start_byte[23:16];
            img[base+14] = pgc_start_byte[15:8];  img[base+15] = pgc_start_byte[7:0];
            pgc = base + pgc_start_byte;
            img[pgc+2] = 8'h01;                  // nr_of_programs
            img[pgc+3] = nr_cells;               // nr_of_cells
            img[pgc+232] = cell_pb_off[15:8];    // cell_playback_offset (BE u16)
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

    // 4-cell disc, cells in physical order (cell k -> RBN k).
    task build_iso;
        begin
            for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = 8'h00;

            // PVD @16
            img[32768] = 8'd1;
            img[32769] = "C"; img[32770] = "D"; img[32771] = "0";
            img[32772] = "0"; img[32773] = "1"; img[32774] = 8'd1;
            put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur);

            // root dir @17
            cur = 34816;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 18, 2048, 8'h02, "VIDEO_TS", 8, cur);

            // VIDEO_TS dir @18
            cur = 36864;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 19, 4096,        8'h00, "VIDEO_TS.IFO;1", 14, cur); // VMGI (2 sec)
            put_rec(cur, 21, 6144,        8'h00, "VTS_01_0.IFO;1", 14, cur); // VTSI (3 sec)
            put_rec(cur, 24, VOBSEC*2048, 8'h00, "VTS_01_1.VOB;1", 14, cur); // title (40 sec)

            put_vmgi(19, 32'd1);
            put_tt_srpt(20, 16'd1, 8'd1);

            put_vtsi_mat(21, 32'd1);                       // vts_pgcit at VTSI+1 = sec 22
            put_pgcit(22, 32'd16, 8'd4, 16'd256);          // 4 cells
            put_cell(22, 32'd16, 16'd256, 0, 32'd0,  32'd9);   // cell0 RBN 0..9
            put_cell(22, 32'd16, 16'd256, 1, 32'd10, 32'd19);  // cell1 RBN 10..19
            put_cell(22, 32'd16, 16'd256, 2, 32'd20, 32'd29);  // cell2 RBN 20..29
            put_cell(22, 32'd16, 16'd256, 3, 32'd30, 32'd39);  // cell3 RBN 30..39

            for (i = 0; i < VOBSEC; i = i + 1)
                fill_sec(24 + i, 8'hB0 + (i / CELLSEC));       // marker per cell

            // NAV packs (VOBU boundaries) for the VOBU-align scrub tests. Placed
            // mid-cell1 (14), at cell2's head (20), and mid-cell2 (26). Cells 0/3
            // stay NAV-free so the marker-run tests (TEST0-3, 7, 8) are unaffected.
            put_nav(14);
            put_nav(20);
            put_nav(26);
        end
    endtask

    // ---- helpers ----
    integer errors = 0;
    integer k;

    // Pulse a seek, wait for the jump to actually EXECUTE (seek_ack pulses at the
    // block-boundary jump cycle, after the outstanding read finishes), let the
    // target cell start streaming, then clear the capture so the next captured
    // bytes are strictly post-seek.
    task do_seek(input [7:0] tgt);
        integer tt;
        begin
            ack_seen = 1'b0;
            @(posedge clk); seek_pulse <= 1'b1; seek_cell <= tgt;
            @(posedge clk); seek_pulse <= 1'b0;
            tt = 0;
            while (!ack_seen && tt < 200000) begin @(posedge clk); tt = tt + 1; end
            repeat (200) @(posedge clk);    // target cell load + stream start
            cap_n = 0;
        end
    endtask

    // Wait until at least `n` fresh bytes have been captured (or timeout).
    task wait_bytes(input integer n);
        integer tt;
        begin
            tt = 0;
            while (cap_n < n && tt < 2000000) begin @(posedge clk); tt = tt + 1; end
        end
    endtask

    task expect_marker(input [7:0] want, input [255:0] label);
        integer mm;
        begin
            mm = 0;
            for (k = 0; k < 1024 && k < cap_n; k = k + 1)
                if (cap[k] !== want) mm = mm + 1;
            if (mm != 0) begin
                errors = errors + 1;
                $display("  FAIL: %0s - %0d/1024 bytes != %02x (first cap %02x)",
                         label, mm, want, cap[0]);
            end else
                $display("  ok: %0s - 1024 bytes all %02x", label, want);
        end
    endtask

    // Verify cap[0..] begins with the NAV-pack signature (a VOBU-aligned landing).
    task check_sig(input [255:0] label);
        begin
            if (cap[0]  !== 8'h00 || cap[1]  !== 8'h00 || cap[2]  !== 8'h01 || cap[3]  !== 8'hBA ||
                cap[14] !== 8'h00 || cap[15] !== 8'h00 || cap[16] !== 8'h01 || cap[17] !== 8'hBB ||
                cap[38] !== 8'h00 || cap[39] !== 8'h00 || cap[40] !== 8'h01 || cap[41] !== 8'hBF) begin
                errors = errors + 1;
                $display("  FAIL: %0s - landed sector is not a NAV pack (cap[0..3]=%02x %02x %02x %02x)",
                         label, cap[0], cap[1], cap[2], cap[3]);
            end
        end
    endtask

    // Index of the first captured byte equal to `want` (or cap_n if absent).
    function integer first_of(input [7:0] want);
        integer n;
        begin
            n = 0;
            while (n < cap_n && cap[n] !== want) n = n + 1;
            first_of = n;
        end
    endfunction

    // Drive a raw-RBN scrub, wait for the jump to execute, capture from byte 0.
    task do_scrub(input [31:0] rbn);
        begin
            ack_seen = 1'b0;
            @(posedge clk); seek_rbn_pulse <= 1'b1; seek_rbn <= rbn;
            @(posedge clk); seek_rbn_pulse <= 1'b0;
            k = 0; while (!ack_seen && k < 200000) begin @(posedge clk); k = k + 1; end
            cap_n = 0;                          // capture the landed stream from byte 0
            k = 0; while (cap_n < 1 && k < 200000) begin @(posedge clk); k = k + 1; end
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        build_iso;
        file_size = IMG_BYTES;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        // ---- baseline: playback begins at cell 0 (marker B0) ----
        wait_bytes(1024);
        if (dut.cell_mode !== 1'b1) begin errors=errors+1; $display("  FAIL: cell_mode not set"); end
        if (!cell_ready)            begin errors=errors+1; $display("  FAIL: cell_ready low"); end
        if (cur_cell !== 8'd0)      begin errors=errors+1; $display("  FAIL: cur_cell!=0 at start (%0d)", cur_cell); end
        expect_marker(8'hB0, "baseline cell0");
        $display("TEST0: cell_mode=%b cell_count=%0d cur_cell=%0d",
                 dut.cell_mode, dut.cell_count, cur_cell);

        // ---- TEST 1: forward seek cell0 -> cell3 (marker B3) ----
        do_seek(8'd3);
        if (!ack_seen)         begin errors=errors+1; $display("  FAIL: no seek_ack on forward seek"); end
        if (cur_cell !== 8'd3) begin errors=errors+1; $display("  FAIL: cur_cell!=3 after fwd seek (%0d)", cur_cell); end
        // Phase-5: a TITLE transport seek is NOT a menu transition -> keep_vbuf=0
        // (the VBUF must flush so the picture jumps with the audio).
        if (kv_at_seek !== 1'b0) begin errors=errors+1; $display("  FAIL: keep_vbuf!=0 on a title transport seek (%b)", kv_at_seek); end
        wait_bytes(1024);
        expect_marker(8'hB3, "TEST1 forward seek -> cell3");

        // ---- TEST 2: backward seek cell3 -> cell1 (marker B1) ----
        do_seek(8'd1);
        if (!ack_seen)         begin errors=errors+1; $display("  FAIL: no seek_ack on backward seek"); end
        if (cur_cell !== 8'd1) begin errors=errors+1; $display("  FAIL: cur_cell!=1 after bwd seek (%0d)", cur_cell); end
        wait_bytes(1024);
        expect_marker(8'hB1, "TEST2 backward seek -> cell1");

        // ---- TEST 3: out-of-range seek (cell 10 >= cell_count 4) = no-op ----
        // Must not ack and must not jump the cell cursor. Playback keeps running
        // from where it was, so we only assert: no ack, cur_cell < cell_count.
        ack_seen = 1'b0;
        @(posedge clk); seek_pulse <= 1'b1; seek_cell <= 8'd10;
        @(posedge clk); seek_pulse <= 1'b0;
        repeat (40) @(posedge clk);
        if (ack_seen)                    begin errors=errors+1; $display("  FAIL: out-of-range seek acked"); end
        if (cur_cell >= dut.cell_count)  begin errors=errors+1; $display("  FAIL: cur_cell ran out of range (%0d)", cur_cell); end
        else $display("  ok: TEST3 out-of-range seek ignored (no ack, cur_cell=%0d)", cur_cell);

        // ---- TEST 4: scrub to RBN 25 (mid cell2) SNAPS forward to the NAV @26 ----
        // A raw mid-VOBU target would leave the decoder mid-GOP and mis-anchor the
        // STC; the reader now walks forward to the first NAV pack (RBN 26) so the
        // landing is VOBU-aligned. cur_cell stays 2; the stream begins with the NAV
        // signature; RBN 26..29 (4 sectors) precede cell3's B3.
        do_scrub(32'd25);
        if (!ack_seen)         begin errors=errors+1; $display("  FAIL: no seek_ack on RBN scrub"); end
        if (cur_cell !== 8'd2) begin errors=errors+1; $display("  FAIL: TEST4 cur_cell!=2 (%0d)", cur_cell); end
        wait_bytes(20000);
        check_sig("TEST4");
        if (first_of(8'hB3) !== 4*2048)
            begin errors=errors+1;
                $display("  FAIL: TEST4 snapped to wrong RBN - first B3 at %0d (want %0d = RBN 26..29)",
                         first_of(8'hB3), 4*2048); end
        else
            $display("  ok: TEST4 scrub RBN 25 -> NAV-aligned RBN 26 (cell2, 4 sectors then B3)");

        // ---- TEST 5: scrub to RBN 20 (already a NAV = cell2 head) = NO shift ----
        do_scrub(32'd20);
        if (cur_cell !== 8'd2) begin errors=errors+1; $display("  FAIL: TEST5 cur_cell!=2 (%0d)", cur_cell); end
        wait_bytes(30000);
        check_sig("TEST5");
        if (first_of(8'hB3) !== 10*2048)
            begin errors=errors+1;
                $display("  FAIL: TEST5 shifted off an on-NAV target - first B3 at %0d (want %0d)",
                         first_of(8'hB3), 10*2048); end
        else
            $display("  ok: TEST5 scrub RBN 20 (on NAV) -> no shift (RBN 20..29 then B3)");

        // ---- TEST 6: scrub to RBN 17 (cell1, next NAV @20) CROSSES into cell2 ----
        // The align target (20) is in the NEXT cell, so the containing-cell scan
        // re-selects cell2 -> proves the cross-cell path.
        do_scrub(32'd17);
        if (cur_cell !== 8'd2) begin errors=errors+1; $display("  FAIL: TEST6 cur_cell!=2 cross-cell (%0d)", cur_cell); end
        wait_bytes(30000);
        check_sig("TEST6");
        if (first_of(8'hB3) !== 10*2048)
            begin errors=errors+1;
                $display("  FAIL: TEST6 cross-cell align wrong - first B3 at %0d (want %0d)",
                         first_of(8'hB3), 10*2048); end
        else
            $display("  ok: TEST6 scrub RBN 17 -> NAV @20 (cross-cell to cell2)");

        // ---- TEST 7: scrub into NAV-free cell3 (RBN 31); budget exhausts -> raw ----
        // cell3 (RBN 30..39) has no NAV; with NAV_CAP=8 the probe checks 31..38 then
        // falls back to the RAW target 31 (pre-fix behaviour = no regression).
        do_scrub(32'd31);
        if (!ack_seen)         begin errors=errors+1; $display("  FAIL: no seek_ack on TEST7 scrub"); end
        if (cur_cell !== 8'd3) begin errors=errors+1; $display("  FAIL: TEST7 cur_cell!=3 (%0d)", cur_cell); end
        if (cap[0] !== 8'hB3)  begin errors=errors+1; $display("  FAIL: TEST7 fallback did not land raw (cap[0]=%02x)", cap[0]); end
        wait_bytes(18432);
        begin : t7count
            integer b3run;
            b3run = 0;
            while (b3run < cap_n && cap[b3run] === 8'hB3) b3run = b3run + 1;
            if (b3run !== 9*2048)
                begin errors=errors+1;
                    $display("  FAIL: TEST7 raw fallback wrong RBN - %0d B3 bytes (want %0d = RBN 31..39)", b3run, 9*2048); end
            else
                $display("  ok: TEST7 budget-exhausted fallback -> raw RBN 31 (%0d B3 bytes)", b3run);
        end

        // ---- TEST 8: scrub to RBN 36; probe hits the title-end clamp -> raw ----
        do_scrub(32'd36);
        if (cur_cell !== 8'd3) begin errors=errors+1; $display("  FAIL: TEST8 cur_cell!=3 (%0d)", cur_cell); end
        if (cap[0] !== 8'hB3)  begin errors=errors+1; $display("  FAIL: TEST8 fallback did not land raw (cap[0]=%02x)", cap[0]); end
        wait_bytes(8192);
        begin : t8count
            integer b3run;
            b3run = 0;
            while (b3run < cap_n && cap[b3run] === 8'hB3) b3run = b3run + 1;
            if (b3run !== 4*2048)
                begin errors=errors+1;
                    $display("  FAIL: TEST8 title-end fallback wrong - %0d B3 bytes (want %0d = RBN 36..39)", b3run, 4*2048); end
            else
                $display("  ok: TEST8 title-end-clamp fallback -> raw RBN 36 (%0d B3 bytes)", b3run);
        end

        if (errors == 0) $display("ISO_READER_SEEK_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_SEEK_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin
        #400000000;
        $display("ISO_READER_SEEK_TB: TIMEOUT");
        $finish;
    end

endmodule
