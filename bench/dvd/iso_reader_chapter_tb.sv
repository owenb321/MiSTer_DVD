// iso_reader_chapter_tb.sv - Phase-8 CHAPTER SKIP test for dvd/dvd_iso_reader.sv.
//
// Builds a synthetic DVD-Video ISO with ONE title set whose PGC has 4 CELLS and
// a 3-entry program_map (chapters). Chapter -> entry cell (1-based):
//   chapter 1 -> cell 1 (0-based 0)
//   chapter 2 -> cell 2 (0-based 1)
//   chapter 3 -> cell 4 (0-based 3)
// So chapter 2 = cells {1,2}, chapters 1 and 3 are one cell each. The reader
// resolves chap_pulse/chap_dir through its program_map BRAM against the current
// cell and drives the cell-seek primitive. Cells map RBN n -> VOB sector n,
// filled 0xC0+n, so the streamed byte after a skip identifies the landed cell.
//
// Checks (golden = tools/iso_nav_check.py chapter map logic):
//   T1: mount plays chapter 1 = cell0 (0xC0), cell_count=4.
//   T2: NEXT  -> chapter 2 = cell1 (0xC1).
//   T3: NEXT  -> chapter 3 = cell3 (0xC3).
//   T4: NEXT at last chapter -> no seek (no seek_ack).
//   T5: PREV  (at chapter-3 start) -> chapter 2 = cell1 (0xC1).
//   T6: PREV  -> chapter 1 = cell0 (0xC0).
//   T8-T11: MULTI-CHAPTER BURST (chap_mag > 1, from the emu debounce): next/prev
//     by 2 jumps straight over the intermediate chapter, and an oversized burst
//     (mag 9) clamps at the first/last chapter instead of overshooting.
`timescale 1ns/1ps

module iso_reader_chapter_tb;

    // Cells are 16 sectors each (BLKSZ=4 rework): with 2048-byte sd blocks the
    // reader prefetches a full 16 KB cache (8 sectors) ahead of the drained
    // output, so 1-sector cells let cur_cell/cur_pgm race a whole cell ahead
    // of what the checks observe. 16-sector cells (2x the cache) keep the
    // fetch cursor inside the cell being drained, like a real title.
    localparam IMG_BYTES = 88*2048;   // 24 header sectors + 64 title sectors

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

    // transport
    reg         chap_pulse = 0;
    reg         chap_dir = 0;
    reg  [4:0]  chap_mag = 5'd1;        // # chapters per burst (>=1)
    reg         chap_at_start = 1;      // 1 = near chapter start (prev steps back)
    wire        seek_ack;
    wire [7:0]  cur_cell;
    wire        cell_ready;
    wire [7:0]  cur_pgm;                // Phase 11: current chapter (1-based)
    wire [31:0] cur_cell_start;         // Phase 11: BCD start of the playing cell

    reg  [7:0]  img [0:IMG_BYTES-1];

    // ---- streamed-byte capture ----
    integer cap_n = 0;
    reg [7:0] cap [0:65535];
    always @(posedge clk)
        if (stream_valid) begin cap[cap_n] = stream_data; cap_n = cap_n + 1; end

    // ---- seek_ack monitor ----
    integer ack_n = 0;
    always @(posedge clk) if (seek_ack) ack_n = ack_n + 1;

    // ---- program_map stream capture (pm_we): pmap[p] = entry cell (1-based) ----
    wire       pm_we;
    wire [6:0] pm_waddr;
    wire [7:0] pm_wdata, nr_pgm;
    integer    pmap_n = 0;
    reg [7:0]  pmap_cap [0:127];
    always @(posedge clk) if (pm_we) begin pmap_cap[pm_waddr] = pm_wdata; pmap_n = pmap_n + 1; end

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size),
        .title_sel(4'd0), .vbuf_empty(1'b0), .menu_snap(1'b0),
        .seek_pulse(1'b0), .seek_natural(1'b0), .seek_cell(8'd0),
        .seek_rbn_pulse(1'b0), .seek_rbn(32'd0),
        .chap_pulse(chap_pulse), .chap_dir(chap_dir), .chap_mag(chap_mag), .chap_at_start(chap_at_start),
        .seek_ack(seek_ack), .cur_cell(cur_cell), .cell_ready(cell_ready),
        .jump_ttn(7'd0), .jump_pgn(8'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(pm_we), .pm_waddr(pm_waddr), .pm_wdata(pm_wdata), .cmd_nr_pgm(nr_pgm),
        .cur_pgm(cur_pgm), .cur_cell_start(cur_cell_start),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .pal_we(), .pal_waddr(), .pal_wdata(),
        .debug_active(), .debug_sd_rd(), .debug_sd_ack(), .debug_cache_has_data(),
        .debug_file_size(), .debug_total_sectors(), .debug_next_lba(),
        .debug_state(), .debug_iso_mode(), .debug_iso_error()
    );

    always #5 clk = ~clk;

    // ---- SD block server: 512-byte blocks, 3-cycle latency ----
    integer m = 0, bc = 0, lat = 0;
    reg [31:0] rlba = 0;
    always @(posedge clk) begin
        sd_buff_wr <= 1'b0;
        case (m)
        0: begin sd_ack <= 1'b0; if (sd_rd) begin rlba <= sd_lba; lat <= 3; m <= 1; end end
        1: begin if (lat != 0) lat <= lat - 1; else begin sd_ack <= 1'b1; bc <= 0; m <= 2; end end
        2: begin
            sd_ack <= 1'b1; sd_buff_wr <= 1'b1; sd_buff_addr <= bc[13:0];
            sd_buff_dout <= img[rlba*2048 + bc]; bc <= bc + 1;
            if (bc == 2047) m <= 3;
        end
        3: begin sd_ack <= 1'b0; sd_buff_wr <= 1'b0; m <= 0; end
        endcase
    end

    // ---- image builders ----
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

    task fill_sec(input integer sec, input [7:0] v);
        integer j; begin for (j = 0; j < 2048; j = j + 1) img[sec*2048 + j] = v; end
    endtask

    task put_vmgi(input integer sec, input [31:0] p);
        integer b; begin b = sec*2048;
            img[b+196]=p[31:24]; img[b+197]=p[23:16]; img[b+198]=p[15:8]; img[b+199]=p[7:0];
        end
    endtask
    task put_tt_srpt(input integer sec, input [7:0] vtsn);
        integer b; begin b = sec*2048;
            img[b+0]=0; img[b+1]=1; img[b+8]=0; img[b+9]=1; img[b+10]=0; img[b+11]=1;
            img[b+12]=0; img[b+13]=0; img[b+14]=vtsn; img[b+15]=1;
        end
    endtask
    task put_vtsi_mat(input integer sec, input [31:0] p);
        integer b; begin b = sec*2048;
            img[b+204]=p[31:24]; img[b+205]=p[23:16]; img[b+206]=p[15:8]; img[b+207]=p[7:0];
        end
    endtask

    // VTS_PGCIT + PGC with program_map (chapters). pgc_start_byte=16.
    //   nr_programs @2, nr_of_cells @3, program_map_offset @230, cell_pb_off @232.
    task put_pgcit_ch(input integer sec, input [7:0] nprog, input [7:0] ncells,
                      input [15:0] pm_off, input [15:0] cell_off);
        integer b, pgc; begin
            b = sec*2048;
            img[b+0]=0; img[b+1]=1;                       // nr_of_pgci_srp=1
            img[b+12]=0; img[b+13]=0; img[b+14]=0; img[b+15]=16;  // pgc_start_byte=16
            pgc = b + 16;
            img[pgc+2] = nprog;                            // nr_of_programs
            img[pgc+3] = ncells;                           // nr_of_cells
            img[pgc+228]=0; img[pgc+229]=0;                // command_tbl_offset=0
            img[pgc+230]=pm_off[15:8]; img[pgc+231]=pm_off[7:0];    // program_map_offset
            img[pgc+232]=cell_off[15:8]; img[pgc+233]=cell_off[7:0];// cell_playback_offset
        end
    endtask
    // program_map entry: program p (0-based) -> entry cell (1-based)
    task put_pm(input integer sec, input [15:0] pm_off, input integer p, input [7:0] entry_cell);
        begin img[sec*2048 + 16 + pm_off + p] = entry_cell; end
    endtask
    task put_cell(input integer sec, input [15:0] cell_off, input integer idx,
                  input [31:0] first_s, input [31:0] last_s);
        integer c; begin
            c = sec*2048 + 16 + cell_off + idx*24;
            img[c+8]=first_s[31:24]; img[c+9]=first_s[23:16]; img[c+10]=first_s[15:8]; img[c+11]=first_s[7:0];
            img[c+20]=last_s[31:24]; img[c+21]=last_s[23:16]; img[c+22]=last_s[15:8]; img[c+23]=last_s[7:0];
        end
    endtask
    // Phase 11: cell playback_time @4..7 (BCD dvd_time {hh,mm,ss,rate|ff})
    task put_ct(input integer sec, input [15:0] cell_off, input integer idx,
                input [31:0] tm);
        integer c; begin
            c = sec*2048 + 16 + cell_off + idx*24;
            img[c+4]=tm[31:24]; img[c+5]=tm[23:16]; img[c+6]=tm[15:8]; img[c+7]=tm[7:0];
        end
    endtask

    task build_iso;
        begin
            for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = 8'h00;
            // PVD @16
            img[32768]=1; img[32769]="C"; img[32770]="D"; img[32771]="0";
            img[32772]="0"; img[32773]="1"; img[32774]=1;
            put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur);
            // root @17
            cur = 34816;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 18, 2048, 8'h02, "VIDEO_TS", 8, cur);
            // VIDEO_TS @18
            cur = 36864;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 19, 4096, 8'h00, "VIDEO_TS.IFO;1", 14, cur); // VMGI (2 sec)
            put_rec(cur, 21, 6144, 8'h00, "VTS_01_0.IFO;1", 14, cur); // VTSI (3 sec)
            put_rec(cur, 24, 131072, 8'h00, "VTS_01_1.VOB;1", 14, cur);// title (64 sec)
            // VMGI/TT_SRPT
            put_vmgi(19, 32'd1);
            put_tt_srpt(20, 8'd1);
            // VTSI_MAT (@21) + PGCIT/PGC (@22): pm_off=240, cell_off=256
            put_vtsi_mat(21, 32'd1);
            put_pgcit_ch(22, 8'd3, 8'd4, 16'd240, 16'd256);
            put_pm(22, 16'd240, 0, 8'd1);   // chapter 1 -> cell 1 (idx 0)
            put_pm(22, 16'd240, 1, 8'd2);   // chapter 2 -> cell 2 (idx 1)
            put_pm(22, 16'd240, 2, 8'd4);   // chapter 3 -> cell 4 (idx 3)
            put_cell(22, 16'd256, 0, 32'd0,  32'd15); // cell0 -> RBN 0..15
            put_cell(22, 16'd256, 1, 32'd16, 32'd31); // cell1 -> RBN 16..31
            put_cell(22, 16'd256, 2, 32'd32, 32'd47); // cell2 -> RBN 32..47
            put_cell(22, 16'd256, 3, 32'd48, 32'd63); // cell3 -> RBN 48..63
            // Phase 11: per-cell durations (BCD, rate=2'b11 NTSC 30 fps; frame
            // byte = rate|BCD frames) chosen so the prefix sum exercises frame
            // AND second carries:
            //   cell0 0:05:30.15  cell1 0:10:00.20  cell2 0:02:45.25  cell3 1:00:59.00
            // -> starts: 0 / 0:05:30.15 / 0:15:31.05 / 0:18:17.00
            put_ct(22, 16'd256, 0, 32'h000530D5);     // 0xC0|BCD15
            put_ct(22, 16'd256, 1, 32'h001000E0);     // 0xC0|BCD20
            put_ct(22, 16'd256, 2, 32'h000245E5);     // 0xC0|BCD25
            put_ct(22, 16'd256, 3, 32'h010059C0);     // 0xC0|BCD00
            // VOB payloads: RBN n at sector 24+n; every sector of cell c is
            // filled with 0xC0+c so the landing-byte checks stay per-cell.
            for (i = 0; i < 64; i = i + 1) fill_sec(24+i, 8'hC0 + i[7:0]/16);
        end
    endtask

    // ---- checks ----
    integer errors = 0;
    integer t;

    // do a chapter skip and confirm the first freshly-streamed byte = want
    task chap_skip_check(input [127:0] label, input dir, input [7:0] want, input exp_ack);
        begin
            chap_skip_mag(label, dir, 5'd1, want, exp_ack);
        end
    endtask

    // multi-chapter burst: skip `mag` chapters in a single debounced pulse
    task chap_skip_mag(input [127:0] label, input dir, input [4:0] mag,
                       input [7:0] want, input exp_ack);
        integer a0;
        begin
            a0 = ack_n;
            // emu holds chap_dir/chap_mag registered until the next burst, so hold
            // them here across chap_go too (only chap_pulse is a 1-cycle strobe).
            @(posedge clk); chap_dir = dir; chap_mag = mag; chap_pulse = 1'b1;
            @(posedge clk); chap_pulse = 1'b0;
            // give the resolve + block-boundary seek time
            t = 0; while (ack_n == a0 && t < 200000) begin @(posedge clk); t = t + 1; end
            if (exp_ack && ack_n == a0) begin
                errors = errors + 1; $display("  FAIL %0s: expected a seek but none happened", label);
            end else if (!exp_ack) begin
                repeat (2000) @(posedge clk);
                if (ack_n != a0) begin errors = errors + 1;
                    $display("  FAIL %0s: expected NO seek but one happened", label); end
                else $display("  ok  %0s: no-op (as expected)", label);
            end else begin
                cap_n = 0;                       // capture the landed cell
                t = 0; while (cap_n < 256 && t < 200000) begin @(posedge clk); t = t + 1; end
                if (cap[0] !== want) begin errors = errors + 1;
                    $display("  FAIL %0s: landed byte %02x want %02x (cur_cell=%0d)", label, cap[0], want, cur_cell);
                end else
                    $display("  ok  %0s: landed cell byte %02x (cur_cell=%0d)", label, cap[0], cur_cell);
            end
        end
    endtask

    // Phase 11: the query-only walk resolves cur_pgm shortly after any cell
    // change (a few hundred cycles); poll with a generous timeout.
    task check_pgm(input [127:0] label, input [7:0] want);
        begin
            t = 0; while (cur_pgm !== want && t < 20000) begin @(posedge clk); t = t + 1; end
            if (cur_pgm !== want) begin errors = errors + 1;
                $display("  FAIL %0s: cur_pgm=%0d want %0d", label, cur_pgm, want);
            end else
                $display("  ok  %0s: cur_pgm=%0d", label, cur_pgm);
        end
    endtask

    // Phase 11: whole-title prefix sum — cur_cell_start (2-cycle read lag)
    task check_start(input [127:0] label, input [31:0] want);
        begin
            t = 0; while (cur_cell_start !== want && t < 20000) begin @(posedge clk); t = t + 1; end
            if (cur_cell_start !== want) begin errors = errors + 1;
                $display("  FAIL %0s: cur_cell_start=%08x want %08x", label, cur_cell_start, want);
            end else
                $display("  ok  %0s: cur_cell_start=%08x", label, cur_cell_start);
        end
    endtask

    initial begin
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        build_iso; file_size = 88*2048;
        @(posedge clk); start = 1; @(posedge clk); start = 0;

        // wait for cell-mode + first cell to stream
        t = 0; while (cap_n < 512 && t < 4000000) begin @(posedge clk); t = t + 1; end
        $display("T1: cell_mode=%b cell_count=%0d cur_cell=%0d first=%02x (expect 1 4 0 C0)",
                 dut.cell_mode, dut.cell_count, cur_cell, cap[0]);
        if (dut.cell_mode !== 1'b1) begin errors=errors+1; $display("  ERR cell_mode not set"); end
        if (dut.cell_count !== 8'd4) begin errors=errors+1; $display("  ERR cell_count != 4"); end
        if (cap[0] !== 8'hC0)        begin errors=errors+1; $display("  ERR first cell != C0"); end
        // program_map streamed byte-exact (chapter entry cells, 1-based) = [1,2,4]
        if (nr_pgm !== 8'd3) begin errors=errors+1; $display("  ERR nr_pgm != 3 (%0d)", nr_pgm); end
        if (pmap_n < 3)      begin errors=errors+1; $display("  ERR program_map not streamed (%0d)", pmap_n); end
        else if (pmap_cap[0]!==8'd1 || pmap_cap[1]!==8'd2 || pmap_cap[2]!==8'd4) begin
            errors=errors+1; $display("  ERR program_map = [%0d,%0d,%0d] exp [1,2,4]",
                                      pmap_cap[0], pmap_cap[1], pmap_cap[2]);
        end else $display("  ok  program_map streamed = [1,2,4]");
        check_pgm("T1b cur_pgm@play", 8'd1);                  // playing cell0 = chapter 1
        // Phase 11: prefix-sum table (frame carry 15+20->35>=30 at start2,
        // frame->second ripple 05+25 + ss 31+45 at start3)
        if (dut.cell_start_mem[0] !== 32'h00000000 ||
            dut.cell_start_mem[1] !== 32'h000530D5 ||
            dut.cell_start_mem[2] !== 32'h001531C5 ||
            dut.cell_start_mem[3] !== 32'h001817C0) begin
            errors = errors + 1;
            $display("  FAIL T1c cell_start_mem = %08x %08x %08x %08x",
                     dut.cell_start_mem[0], dut.cell_start_mem[1],
                     dut.cell_start_mem[2], dut.cell_start_mem[3]);
        end else $display("  ok  T1c cell_start_mem prefix sum (carries exact)");
        check_start("T1d start@cell0", 32'h00000000);

        chap_skip_check("T2 next->ch2", 1'b1, 8'hC1, 1'b1);   // cell1
        check_pgm("T2b cur_pgm", 8'd2);
        check_start("T2c start@cell1", 32'h000530D5);
        chap_skip_check("T3 next->ch3", 1'b1, 8'hC3, 1'b1);   // cell3
        check_pgm("T3b cur_pgm", 8'd3);
        check_start("T3c start@cell3", 32'h001817C0);
        chap_skip_check("T4 next@last", 1'b1, 8'h00, 1'b0);   // no-op
        // prev when NOT near the start (>5 s into the chapter) = RESTART current ch3
        chap_at_start = 1'b0;
        chap_skip_check("T5 prev-restart ch3", 1'b0, 8'hC3, 1'b1);   // back to cell3 start
        check_pgm("T5b cur_pgm", 8'd3);
        // prev when near the start = step back to the PREVIOUS chapter
        chap_at_start = 1'b1;
        chap_skip_check("T6 prev->ch2", 1'b0, 8'hC1, 1'b1);   // cell1
        check_pgm("T6b cur_pgm", 8'd2);
        chap_skip_check("T7 prev->ch1", 1'b0, 8'hC0, 1'b1);   // cell0
        check_pgm("T7b cur_pgm", 8'd1);

        // ---- multi-chapter burst (debounced multi-press) ----
        // from ch1 (cell0), next x2 = jump straight to ch3 (cell3), no ch2 stop
        chap_skip_mag("T8 next x2 ->ch3", 1'b1, 5'd2, 8'hC3, 1'b1);
        check_pgm("T8b cur_pgm", 8'd3);
        // from ch3, prev x2 near-start = back two chapters to ch1 (cell0)
        chap_at_start = 1'b1;
        chap_skip_mag("T9 prev x2 ->ch1", 1'b0, 5'd2, 8'hC0, 1'b1);
        check_pgm("T9b cur_pgm", 8'd1);
        // burst larger than the title clamps at the ends (next x9 from ch1 -> last ch3)
        chap_skip_mag("T10 nx9 ->ch3", 1'b1, 5'd9, 8'hC3, 1'b1);
        check_pgm("T10b cur_pgm", 8'd3);
        // prev x9 near-start from ch3 clamps at ch1 (cell0)
        chap_skip_mag("T11 pv9 ->ch1", 1'b0, 5'd9, 8'hC0, 1'b1);
        check_pgm("T11b cur_pgm", 8'd1);

        if (errors == 0) $display("ISO_READER_CHAPTER_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_CHAPTER_TB: FAILED (%0d errors)", errors);
        $finish;
    end
endmodule
