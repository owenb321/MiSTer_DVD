// iso_reader_scrub_tb.sv - sub-cell time SCRUB (raw-RBN seek) test for
// dvd/dvd_iso_reader.sv (Phase 8).
//
// The gamepad time scrub (emu.sv) jumps to an absolute VTSTT_VOBS RBN
// (current-VOBU LBN +/- a DSI fwda/bwda offset). This tb drives the reader's
// seek_rbn_pulse/seek_rbn port directly and proves:
//   - the containing-cell scan sets cur_cell to the cell whose RBN range holds
//     the target,
//   - streaming actually starts AT the target RBN (not the cell's first_sector),
//   - an out-of-range RBN clamps to the last cell (playback still resumes).
//
// Disc: ONE title set (VTS_01), a 4-cell PGC in physical order, each cell 10
// sectors. To verify SUB-CELL precision every sector is filled with a byte =
// its own RBN (0..39), so the first captured byte identifies the exact target
// sector, and cur_cell identifies the containing cell:
//   cell0 -> RBN  0..9   cell1 -> RBN 10..19
//   cell2 -> RBN 20..29  cell3 -> RBN 30..39
//
// Layout mirrors iso_reader_seek_tb (same IFO/PGC skeleton).

`timescale 1ns/1ps

module iso_reader_scrub_tb;

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

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(4'd0), .vbuf_empty(1'b0), .menu_snap(1'b0),
        .jump_ttn(7'd0), .jump_pgn(8'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_pulse(seek_pulse), .seek_natural(1'b0), .seek_cell(seek_cell), .seek_ack(seek_ack),
        .seek_rbn_pulse(seek_rbn_pulse), .seek_rbn(seek_rbn),
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

    task do_scrub(input [31:0] tgt_rbn);
        integer tt;
        begin
            ack_seen = 1'b0;
            @(posedge clk); seek_rbn_pulse <= 1'b1; seek_rbn <= tgt_rbn;
            @(posedge clk); seek_rbn_pulse <= 1'b0;
            tt = 0;
            while (!ack_seen && tt < 200000) begin @(posedge clk); tt = tt + 1; end
            repeat (300) @(posedge clk);    // containing-cell scan + load + stream
            cap_n = 0;
        end
    endtask

    task wait_bytes(input integer n);
        integer tt;
        begin
            tt = 0;
            while (cap_n < n && tt < 2000000) begin @(posedge clk); tt = tt + 1; end
        end
    endtask

    // expect the first 1024 captured bytes to all equal `want` (the target sector)
    task expect_rbn(input [7:0] want, input [7:0] want_cell, input [255:0] label);
        integer mm;
        begin
            mm = 0;
            for (k = 0; k < 1024 && k < cap_n; k = k + 1)
                if (cap[k] !== want) mm = mm + 1;
            if (mm != 0) begin
                errors = errors + 1;
                $display("  FAIL: %0s - %0d/1024 bytes != %0d (first cap %0d)",
                         label, mm, want, cap[0]);
            end else if (cur_cell !== want_cell) begin
                errors = errors + 1;
                $display("  FAIL: %0s - cur_cell=%0d expected %0d (bytes ok)",
                         label, cur_cell, want_cell);
            end else
                $display("  ok: %0s - starts at RBN %0d, cur_cell=%0d", label, want, cur_cell);
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

        wait_bytes(1024);
        if (dut.cell_mode !== 1'b1) begin errors=errors+1; $display("  FAIL: cell_mode not set"); end
        expect_rbn(8'd0, 8'd0, "baseline cell0 RBN0");
        $display("TEST0: cell_mode=%b cell_count=%0d cur_cell=%0d",
                 dut.cell_mode, dut.cell_count, cur_cell);

        // ---- TEST 1: forward scrub to RBN 25 (mid cell2) ----
        do_scrub(32'd25);
        if (!ack_seen) begin errors=errors+1; $display("  FAIL: no seek_ack on fwd scrub"); end
        wait_bytes(1024);
        expect_rbn(8'd25, 8'd2, "TEST1 fwd scrub -> RBN 25 / cell2");

        // ---- TEST 2: backward scrub to RBN 12 (mid cell1) ----
        do_scrub(32'd12);
        if (!ack_seen) begin errors=errors+1; $display("  FAIL: no seek_ack on bwd scrub"); end
        wait_bytes(1024);
        expect_rbn(8'd12, 8'd1, "TEST2 bwd scrub -> RBN 12 / cell1");

        // ---- TEST 3: scrub back into cell0 (RBN 5) ----
        do_scrub(32'd5);
        wait_bytes(1024);
        expect_rbn(8'd5, 8'd0, "TEST3 scrub -> RBN 5 / cell0");

        // ---- TEST 4: out-of-range RBN 100 -> clamp to last cell (cell3, RBN30) ----
        do_scrub(32'd100);
        if (!ack_seen) begin errors=errors+1; $display("  FAIL: no seek_ack on clamp scrub"); end
        wait_bytes(1024);
        expect_rbn(8'd30, 8'd3, "TEST4 out-of-range -> clamp cell3 RBN30");

        if (errors == 0) $display("ISO_READER_SCRUB_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_SCRUB_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin
        #400000000;
        $display("ISO_READER_SCRUB_TB: TIMEOUT");
        $finish;
    end

endmodule
