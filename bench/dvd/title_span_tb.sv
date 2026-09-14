// title_span_tb.sv - the title RBN span across the reader/scrub_ctrl SEAM.
//
// ★ WHY THIS IS AN INTEGRATION BENCH AND NOT A READER ARM.
// `title_last_rbn` reaches the reader's OWN behaviour in exactly one place --
// the `nav_cand > title_last_rbn` bail in S_NAV_SEEK, which only shortens the
// VOBU-align probe and then falls back to the raw target anyway. So a bench
// that drives `seek_rbn_pulse` directly (iso_reader_scrub_tb) lands at the same
// RBN with or without the fix and CANNOT see this defect. The defect lives at
// the seam: the reader PUBLISHES the span, scrub_ctrl CLAMPS to it, the reader
// then LANDS on the clamped value. Same shape as the A-B `jump_dir` miss
// (CLAUDE.md): assert against the CONSUMER's contract, across the seam.
//
// THE DEFECT. dvd_iso_reader's cell walk took `title_last_rbn` from the
// LAST-WRITTEN cell, with the comment "cells are captured in order, so after
// the walk this is the title's end RBN". Program order is NOT physical order.
// Measured on A_MILLION_WAYS_TO_DIE_IN_THE_WEST (VTS_07 PGCN 1, 22 cells,
// 1:55:54): cells 0..20 run RBN 4..3,359,267 ascending, and cell 21 -- the LAST
// PROGRAM -- is 4 sectors at RBN 0..3, physically at the FRONT of the VOBS. The
// reader published first=4, last=3. 45 of 958 library ISOs do this; 6 more
// publish a short span.
//
// THE FIXTURE mirrors that shape at 1:10000 scale. One VTS, 4 cells x 10
// sectors, sector RBN i filled with byte i so the captured stream names the
// exact landing sector, and cur_cell names the landing cell:
//
//     program cell 0 -> RBN 10..19        <- title_first_rbn = 10
//     program cell 1 -> RBN 20..29
//     program cell 2 -> RBN 30..39        <- the real end of the content
//     program cell 3 -> RBN  0.. 9        <- LAST PROGRAM, physically FIRST
//
//   pre-fix : title_last_rbn = 9   -> span = (9 > 10) ? .. : 1 = 1, and every
//             target clamps to 9, which S_RBN_SCAN resolves to CELL 3 = the
//             last program = "any seek jumps to the end of the movie".
//   post-fix: title_last_rbn = 39 (the MAX over the cells).
//
// Every arm measures the LANDING (first captured bytes + cur_cell), never a
// signal the fix names. The SHn ladder is left at its shipping values on
// purpose: span 29 >> 13 and span 1 >> 13 both floor to a 1-sector step, so the
// accumulate is identical pre- and post-fix and THE CLAMP IS THE ONLY VARIABLE.
//
// `cur_rbn` (the playhead) is TB stimulus, as it is emu stimulus from nav_dsi --
// it says where the user is, it is not derived from anything under test.
//
// THE MIRROR SHAPE (+TITLE_SPAN_LATE0=1) is BIG_TROUBLE_LITTLE_CHINA's, measured:
// cell[0] sits at the TOP of the disc (RBN 2,032,273 of 2,032,309) with the other
// 59 cells BELOW it, so title_first_rbn lands near the END and the playhead spends
// the whole film BELOW the span. Same degenerate span, opposite direction: the bar
// floors to EMPTY instead of saturating, 44 of 45 chapter notches pile up at column
// 0, and the LOW clamp fires on every seek -- reported from the board as "seeking
// always brings you back to the beginning of the title".
//     program cell 0 -> RBN 30..39   <- FIRST program, physically LAST
//     program cell 1 -> RBN  0.. 9
//     program cell 2 -> RBN 10..19
//     program cell 3 -> RBN 20..29   <- LAST program, physically in the middle
//
// Arms: A fixture sanity | B forward | C backward | D end clamp | E start clamp
//       F per-PGC re-seed | G gap landing (+TITLE_SPAN_GAP)
//       H/I/J the mirror shape (+TITLE_SPAN_LATE0)

`timescale 1ns/1ps

module title_span_tb;

    localparam IMG_BYTES = 112*2048;

    // scrub_ctrl timing, shrunk. The SHIFT ladder is NOT overridden.
    localparam TICK_TB   = 20;
    localparam LINGER_TB = 200;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [63:0] file_size = 0;
    reg  [6:0]  title_sel = 7'd0;

    // ---- reader <-> scrub_ctrl seam ----
    wire [31:0] title_first_rbn, title_last_rbn;
    wire [31:0] title_start_rbn, title_end_rbn;
    wire        sk_pulse;
    wire [31:0] sk_rbn;

    // ---- gesture + modelled playhead ----
    reg         held_right = 0, held_left = 0;
    reg  [31:0] play_rbn = 0;

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

    reg  [7:0]  img [0:IMG_BYTES-1];

    // ---- capture (rolling) ----
    integer cap_n = 0;
    reg [7:0] cap [0:65535];
    // ★ The LANDING cell is the one the FIRST delivered byte came from, not
    //   whatever cur_cell reads later: a target on a cell's last sector (arm D
    //   clamps to RBN 39, the final sector of program cell 2) is one sector of
    //   runway, so cur_cell has already advanced to the next program by the
    //   time the arm looks. Latch it with the first byte instead.
    reg [7:0] land_cell = 8'hFF;
    always @(posedge clk)
        if (stream_valid && cap_n < 65536) begin
            if (cap_n == 0) land_cell = cur_cell;
            cap[cap_n] = stream_data;
            cap_n = cap_n + 1;
        end

    // ---- what scrub_ctrl actually asked for (diagnostic, never an expectation) ----
    reg         ack_seen = 0;
    reg [31:0]  issued_rbn = 32'hFFFF_FFFF;
    always @(posedge clk) begin
        if (seek_ack)  ack_seen    <= 1'b1;
        if (sk_pulse) issued_rbn <= sk_rbn;
    end

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size),
        .title_sel(title_sel), .vbuf_empty(1'b0), .menu_snap(1'b0),
        .jump_ttn(7'd0), .jump_pgn(8'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_pulse(1'b0), .seek_natural(1'b0), .seek_cell(8'd0), .seek_ack(seek_ack),
        .seek_rbn_pulse(sk_pulse), .seek_rbn(sk_rbn),
        .title_first_rbn(title_first_rbn), .title_last_rbn(title_last_rbn),
        .title_start_rbn(title_start_rbn), .title_end_rbn(title_end_rbn),
        .keep_vbuf(),
        .cur_cell(cur_cell), .cell_ready(cell_ready),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(1'b0),
        .debug_active(), .debug_sd_rd(), .debug_sd_ack(), .debug_cache_has_data(),
        .debug_file_size(), .debug_total_sectors(), .debug_next_lba(),
        .debug_state(), .debug_iso_mode(), .debug_iso_error()
    );

    // The REAL consumer, with the REAL clamp. Only the time constants shrink.
    scrub_ctrl #(.TICK(TICK_TB), .LINGER(LINGER_TB)) sc (
        .clk(clk), .rst_n(rst_n),
        .held_right(held_right), .held_left(held_left),
        .in_title(cell_ready),
        .cur_rbn(play_rbn),
        .title_first_rbn(title_first_rbn), .title_last_rbn(title_last_rbn),
        .title_start_rbn(title_start_rbn), .title_end_rbn(title_end_rbn),
        .title_secs(16'd0), .lin_blk10(24'd0), .lin_rate_ok(1'b0),
        .jump_fire(1'b0), .jump_dir(1'b0), .jump_base(32'd0), .jump_off(32'd0),
        .seek_rbn_pulse(sk_pulse), .seek_rbn(sk_rbn),
        .hold_freeze(), .bar_active(), .bar_base_rbn(), .bar_tgt_rbn(),
        .hud_tier(), .hud_dir()
    );

    always #5 clk = ~clk;

    // ---- mock HPS: one 2048-byte sector per sd_rd ----
    integer m = 0;
    integer bc = 0;
    reg [31:0] rlba = 0;
    integer lat = 0;
    always @(posedge clk) begin
        sd_ack     <= sd_ack;
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

    // ---- image builders (shared skeleton with iso_reader_scrub_tb) ----
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

    // Two titles: title 1 -> VTS_01, title 2 -> VTS_02 (12-byte SRPs after an
    // 8-byte header; vtsn @+6, vts_ttn @+7 within each SRP).
    task put_tt_srpt2(input integer sec);
        integer base;
        begin
            base = sec*2048;
            img[base+0] = 8'h00; img[base+1] = 8'h02;       // nr_of_srpts = 2
            img[base+8+6]  = 8'd1; img[base+8+7]  = 8'd1;   // SRP0 -> VTS_01 ttn 1
            img[base+20+6] = 8'd2; img[base+20+7] = 8'd1;   // SRP1 -> VTS_02 ttn 1
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

    // ---- the disc ----------------------------------------------------------
    // VTS_01: 70-sector VOB at LBA 24, RBN i -> byte i.
    //         program order deliberately != physical order (see the header).
    // VTS_02: 10-sector VOB at LBA 100, RBN i -> byte 100+i. Two IN-ORDER cells,
    //         max last_sector = 9 -- a SMALLER span than VTS_01's, so arm F can
    //         see the previous title's span leak in if the cell-0 seed is gone.
    // ONE physical layout for both builds -- only the CELL TABLE differs, so the
    // gap arm cannot accidentally also move the extents. VTS_01's VOB is always
    // 70 sectors; in the default build cells simply never reference 40..69.
    localparam V1SEC = 70;
`ifdef TITLE_SPAN_GAP
    localparam V1CELLS = 8'd5;      // + a 5th cell at 60..69, leaving 40..59 unmapped
`else
    localparam V1CELLS = 8'd4;
`endif

    task build_iso;
        begin
            for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = 8'h00;

            img[32768] = 8'd1;
            img[32769] = "C"; img[32770] = "D"; img[32771] = "0";
            img[32772] = "0"; img[32773] = "1"; img[32774] = 8'd1;
            put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur);

            cur = 34816;                                    // sector 17: root
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 18, 2048, 8'h02, "VIDEO_TS", 8, cur);

            cur = 36864;                                    // sector 18: VIDEO_TS
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 19, 4096,         8'h00, "VIDEO_TS.IFO;1", 14, cur);
            put_rec(cur, 21, 6144,         8'h00, "VTS_01_0.IFO;1", 14, cur);
            put_rec(cur, 24, V1SEC*2048,   8'h00, "VTS_01_1.VOB;1", 14, cur);
            put_rec(cur, 96, 4096,         8'h00, "VTS_02_0.IFO;1", 14, cur);
            put_rec(cur, 100, 10*2048,     8'h00, "VTS_02_1.VOB;1", 14, cur);

            put_vmgi(19, 32'd1);
            put_tt_srpt2(20);

            // ---- VTS_01 ----
            put_vtsi_mat(21, 32'd1);
            put_pgcit(22, 32'd16, V1CELLS, 16'd256);
`ifdef TITLE_SPAN_LATE0
            // BIG_TROUBLE's shape: the FIRST program is physically LAST.
            put_cell(22, 32'd16, 16'd256, 0, 32'd30, 32'd39);  // FIRST program, LAST on disc
            put_cell(22, 32'd16, 16'd256, 1, 32'd0,  32'd9);
            put_cell(22, 32'd16, 16'd256, 2, 32'd10, 32'd19);
            put_cell(22, 32'd16, 16'd256, 3, 32'd20, 32'd29);  // LAST program
`else
            put_cell(22, 32'd16, 16'd256, 0, 32'd10, 32'd19);
            put_cell(22, 32'd16, 16'd256, 1, 32'd20, 32'd29);
            put_cell(22, 32'd16, 16'd256, 2, 32'd30, 32'd39);
            put_cell(22, 32'd16, 16'd256, 3, 32'd0,  32'd9);   // LAST program, FIRST on disc
`endif
`ifdef TITLE_SPAN_GAP
            put_cell(22, 32'd16, 16'd256, 4, 32'd60, 32'd69);  // 40..59 belongs to no cell
`endif
            for (i = 0; i < V1SEC; i = i + 1)
                fill_sec(24 + i, i[7:0]);                      // RBN i -> byte i

            // ---- VTS_02 ----
            put_vtsi_mat(96, 32'd1);
            put_pgcit(97, 32'd16, 8'd2, 16'd256);
            put_cell(97, 32'd16, 16'd256, 0, 32'd0, 32'd4);
            put_cell(97, 32'd16, 16'd256, 1, 32'd5, 32'd9);
            for (i = 0; i < 10; i = i + 1)
                fill_sec(100 + i, 8'd100 + i[7:0]);             // RBN i -> byte 100+i
        end
    endtask

    // ---- helpers -----------------------------------------------------------
    integer errors = 0;
    integer k;

    // Hold a direction for n accumulate ticks, then release. tick_cnt is loaded
    // with TICK at want_rise and counts down, so a tick costs TICK+1 cycles.
    task hold(input dir_fwd, input integer nticks);
        begin
            ack_seen   = 1'b0;
            issued_rbn = 32'hFFFF_FFFF;
            @(posedge clk);
            if (dir_fwd) held_right <= 1'b1; else held_left <= 1'b1;
            repeat (nticks*(TICK_TB+1) + 4) @(posedge clk);
            held_right <= 1'b0; held_left <= 1'b0;
            @(posedge clk);
        end
    endtask

    // Settle generously: after the seek_ack the reader still runs the VOBU-align
    // probe (one sector read per candidate) before the containing-cell scan.
    task settle;
        integer tt;
        begin
            tt = 0;
            while (!ack_seen && tt < 200000) begin @(posedge clk); tt = tt + 1; end
            @(negedge clk); cap_n = 0;
        end
    endtask

    // DIAGNOSTIC: run-length dump of what actually arrived.
    task dump_runs(input integer maxruns);
        integer a, runs; reg [7:0] v; integer n;
        begin
            a = 0; runs = 0;
            while (a < cap_n && runs < maxruns) begin
                v = cap[a]; n = 0;
                while (a < cap_n && cap[a] === v) begin a = a + 1; n = n + 1; end
                $display("        run %0d: byte %0d x%0d", runs, v, n);
                runs = runs + 1;
            end
            $display("        (cap_n=%0d)", cap_n);
        end
    endtask

    task wait_bytes(input integer n);
        integer tt;
        begin
            tt = 0;
            while (cap_n < n && tt < 2000000) begin @(posedge clk); tt = tt + 1; end
        end
    endtask

    // want_cell == 8'hFF -> do not assert the cell. Only arm D needs that: its
    // target IS the title's final sector, so there is one sector of runway and
    // the reader's prefetch has already advanced cell_i by the time the byte
    // reaches the output. The BYTE still identifies the sector uniquely (cell 3
    // holds RBN 0..9, whose sectors can never contain byte 39), so the landing
    // is fully pinned without it.
    task expect_rbn(input [7:0] want, input [7:0] want_cell, input [511:0] label);
        integer mm;
        begin
            mm = 0;
            for (k = 0; k < 1024 && k < cap_n; k = k + 1)
                if (cap[k] !== want) mm = mm + 1;
            if (cap_n < 1024) begin
                errors = errors + 1;
                $display("  FAIL: %0s - only %0d bytes captured", label, cap_n);
            end else if (mm != 0) begin
                errors = errors + 1;
                $display("  FAIL: %0s - %0d/1024 bytes != %0d (first cap %0d, cell %0d, seek asked %0d)",
                         label, mm, want, cap[0], land_cell, issued_rbn);
                if (land_cell === (dut.cell_count - 8'd1))
                    $display("        ^ landed in cell %0d = the LAST PROGRAM = the end of the movie",
                             land_cell);
                dump_runs(4);
            end else if (want_cell !== 8'hFF && land_cell !== want_cell) begin
                errors = errors + 1;
                $display("  FAIL: %0s - landed in cell %0d, expected %0d (bytes ok, seek asked %0d)",
                         label, land_cell, want_cell, issued_rbn);
            end else
                $display("  ok: %0s - RBN %0d, cell %0d (seek asked %0d)",
                         label, want, land_cell, issued_rbn);
        end
    endtask

    task mount(input [6:0] sel);
        begin
            title_sel = sel;
            @(posedge clk);
            start = 1; @(posedge clk); start = 0;
            @(negedge clk); cap_n = 0;      // else wait_bytes sees the PREVIOUS arm's bytes
            wait_bytes(1024);
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        build_iso;
        file_size = IMG_BYTES;
        mount(7'd0);

        // ---- A: fixture sanity (NOT a gate) --------------------------------
        if (dut.cell_mode !== 1'b1) begin
            errors = errors + 1; $display("  FAIL: cell_mode not set");
        end
        $display("A: cell_mode=%b cell_count=%0d cur_cell=%0d  span=[%0d..%0d]",
                 dut.cell_mode, dut.cell_count, cur_cell,
                 title_first_rbn, title_last_rbn);
        $display("   program ends: start=%0d end=%0d", title_start_rbn, title_end_rbn);
`ifdef TITLE_SPAN_LATE0
        expect_rbn(8'd30, 8'd0, "A baseline - program cell 0 at RBN 30 (mirror)");
`else
        expect_rbn(8'd10, 8'd0, "A baseline - program cell 0 at RBN 10");
`endif

`ifdef TITLE_SPAN_GAP
        // ---- G: a target in a GAP must not land on the last program --------
        // Cells cover 0..39 and 60..69; 40..59 belongs to no cell. Seeking to
        // 50 exhausts the containing-cell scan. The old fallback played
        // cell_count-1 (= cell 4, RBN 60) -- "jump to the end" by a second
        // route. The new one lands on the cell that STARTS nearest below.
        play_rbn = 32'd35;
        hold(1'b1, 15);                      // 35 + 15 = 50, inside the gap
        settle; wait_bytes(1024);
        expect_rbn(8'd30, 8'd2, "G gap 50 -> nearest cell below (cell 2 @30)");
`elsif TITLE_SPAN_LATE0
        // ---- H: an ordinary forward seek must MOVE, not snap to the start ---
        // Pre-fix: title_first_rbn = 30 (cell[0] is at the top), the playhead is
        // at 15 which is BELOW it, so the low clamp fires and the target becomes
        // 30 = cell 0 = the FIRST program = "back to the beginning of the title".
        play_rbn = 32'd15;
        hold(1'b1, 8);                       // 15 + 8 = 23 -> cell 3 (20..29)
        settle; wait_bytes(1024);
        expect_rbn(8'd23, 8'd3, "H forward 15 -> 23 (not back to the start)");

        // ---- I: forward PAST the last program stops at the last program -----
        // ★ The hard clamp alone would send it to max = 39, which on this shape
        //   is inside cell 0 -- the FIRST program. Seeking forward off the end
        //   must not land at the beginning.
        play_rbn = 32'd25;
        hold(1'b1, 20);                      // 25 + 20 = 45, past the last program
        settle; wait_bytes(1024);
        expect_rbn(8'd29, 8'hFF, "I forward past the last program -> 29, not 39");

        // ---- J: backward inside the low group stays there --------------------
        play_rbn = 32'd5;
        hold(1'b0, 3);                       // 5 - 3 = 2 -> cell 1 (0..9)
        settle; wait_bytes(1024);
        expect_rbn(8'd2, 8'd1, "J backward 5 -> 2");
`else
        // ---- B: forward, well inside the title -----------------------------
        play_rbn = 32'd15;
        hold(1'b1, 8);                       // 15 + 8 = 23  (cell 1)
        settle; wait_bytes(1024);
        expect_rbn(8'd23, 8'd1, "B forward 15 -> 23");

        // ---- C: backward, well inside the title ----------------------------
        play_rbn = 32'd35;
        hold(1'b0, 8);                       // 35 - 8 = 27  (cell 1)
        settle; wait_bytes(1024);
        expect_rbn(8'd27, 8'd1, "C backward 35 -> 27");

        // ---- D: forward past the end still clamps, but to the REAL end -----
        play_rbn = 32'd35;
        hold(1'b1, 29);                      // 35 + 29 > 39 -> clamp 39 (cell 2)
        settle; wait_bytes(1024);
        expect_rbn(8'd39, 8'hFF, "D forward clamp -> 39 (real end, was 9)");

        // ---- E: backward underflow clamps to title_first_rbn ---------------
        // ★ The executable form of "title_first_rbn is cell 0's first_sector,
        //   deliberately NOT min(first_sector)". As the minimum it would be 0,
        //   which is INSIDE cell 3 -- the last program -- so a rewind past the
        //   start would jump to the END. That is what this arm refuses.
        play_rbn = 32'd15;
        hold(1'b0, 8);                       // 15 - 8 = 7 < 10 -> clamp 10 (cell 0)
        settle; wait_bytes(1024);
        expect_rbn(8'd10, 8'd0, "E backward underflow -> 10");

        // ---- F: the span must RE-SEED per PGC ------------------------------
        // Remount to VTS_02 WITHOUT a reset. Nothing clears title_last_rbn
        // between PGCs (the start re-init does not touch it), so without the
        // cell-0 seed VTS_01's 39 survives into a title whose real max is 9.
        mount(7'd2);
        $display("F: remounted VTS_02  span=[%0d..%0d] cell_count=%0d",
                 title_first_rbn, title_last_rbn, dut.cell_count);
        play_rbn = 32'd2;
        hold(1'b1, 8);                       // 2 + 8 = 10 > 9 -> stop at 9 (cell 1)
        settle; wait_bytes(1024);
        expect_rbn(8'd109, 8'd1, "F re-seed - VTS_02 stops at its OWN program end");
        // ⚠ The LANDING above stopped gating the seed once the program-end
        //   crossing rule landed: cross_hi bounds the target at end=9 whatever
        //   title_last_rbn holds, so a leaked span from the previous title no
        //   longer moves where this gesture goes. It still corrupts the BAR, and
        //   nothing about a landing can see that -- so assert the published span
        //   too. ★ Not a restatement of the RTL: no expression in the reader says
        //   "the previous PGC must not leak into this one".
        if (title_last_rbn !== 32'd9) begin
            errors = errors + 1;
            $display("  FAIL: F re-seed - VTS_02 published last=%0d, expected 9 (the previous title's span leaked)",
                     title_last_rbn);
        end else
            $display("  ok: F re-seed - published span is VTS_02's own [%0d..%0d]",
                     title_first_rbn, title_last_rbn);
`endif

        if (errors == 0) $display("TITLE_SPAN_TB: ALL TESTS PASSED");
        else             $display("TITLE_SPAN_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin
        #900000000;
        $display("TITLE_SPAN_TB: TIMEOUT");
        $finish;
    end

endmodule
