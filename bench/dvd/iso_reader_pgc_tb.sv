// iso_reader_pgc_tb.sv - PGC / cell-timeline playback test for
// dvd/dvd_iso_reader.sv (roadmap Phase 7).
//
// Builds a synthetic DVD-Video ISO with ONE title set (VTS_01) whose PGC has
// two CELLS deliberately OUT OF PHYSICAL ORDER, and checks the reader streams
// them in PROGRAM (cell-table) order - and skips the sector no cell references.
//
// Layout (2048-byte logical sectors):
//   16 PVD (root dir @17)
//   17 root dir  -> VIDEO_TS dir @18
//   18 VIDEO_TS dir: ".","..",VIDEO_TS.IFO(@19,2sec),VTS_01_0.IFO(@21,3sec),
//                    VTS_01_1.VOB(@24,3sec)
//   19 VIDEO_TS.IFO sec0 = VMGI_MAT (tt_srpt ptr@196 -> TT_SRPT@20)
//   20 VMGI TT_SRPT (title 1 -> VTS_01)
//   21 VTS_01_0.IFO sec0 = VTSI_MAT (vts_pgcit@204 -> PGCIT@22)
//   22 VTS_01_0.IFO sec1 = VTS_PGCIT + PGC + cell playback table
//        PGCIT: nr_srp=1, SRP[0].pgc_start_byte@12 = 16 -> PGC at off 16
//        PGC  : nr_programs@2=1, nr_of_cells@3=2, cell_playback_offset@232=256
//        cells: cell0 {first=2,last=2}  cell1 {first=0,last=0}  (24 B each)
//   23 VTS_01_0.IFO sec2 (unused)
//   24 VTS_01_1.VOB sec0 (RBN 0) = 0xB0
//   25 VTS_01_1.VOB sec1 (RBN 1) = 0xB1   <- referenced by NO cell (skipped)
//   26 VTS_01_1.VOB sec2 (RBN 2) = 0xB2
//
// Cell first/last are 2048-sector RBNs relative to VTSTT_VOBS (= VTS_01_1.VOB).
//   Program order: cell0 (RBN 2 = 0xB2) then cell1 (RBN 0 = 0xB0).
//   TEST 1: valid PGC -> stream 0xB2 x2048 then 0xB0 x2048 (reorder + skip 0xB1).
//   TEST 2: VTSI vts_pgcit=0 (malformed) -> linear fallback streams the whole
//           VTS_01_1.VOB = 0xB0,0xB1,0xB2 (6144 B) in physical order.

`timescale 1ns/1ps

module iso_reader_pgc_tb;

    localparam IMG_BYTES = 28*2048;

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

    wire        debug_iso_mode, debug_iso_error;
    wire [15:0] debug_state;

    reg  [7:0]  img [0:IMG_BYTES-1];

    // ---- capture ----
    integer cap_n = 0;
    reg [7:0] cap [0:65535];
    always @(posedge clk)
        if (stream_valid) begin
            cap[cap_n] = stream_data;
            cap_n = cap_n + 1;
        end

    // ---- PGC palette stream capture (pal_we/pal_waddr/pal_wdata) ----
    wire        pal_we;
    wire [3:0]  pal_waddr;
    wire [31:0] pal_wdata;
    integer     pal_writes = 0;
    reg [31:0]  pal_cap [0:15];
    always @(posedge clk)
        if (pal_we) begin
            pal_cap[pal_waddr] = pal_wdata;
            pal_writes = pal_writes + 1;
        end

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(4'd0), .vbuf_empty(1'b0), .menu_snap(1'b0),
        // Phase-4 DVD-VM ports: legacy mode (vm_mode=0 keeps prior behaviour)
        .jump_ttn(7'd0), .jump_pgn(8'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .pal_we(pal_we), .pal_waddr(pal_waddr), .pal_wdata(pal_wdata),
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

    // ---- image builders ----
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

    // VMGI_MAT: tt_srpt sector pointer (BE u32 @196).
    task put_vmgi(input integer sec, input [31:0] tt_srpt_ptr);
        integer base;
        begin
            base = sec*2048;
            img[base+196] = tt_srpt_ptr[31:24]; img[base+197] = tt_srpt_ptr[23:16];
            img[base+198] = tt_srpt_ptr[15:8];  img[base+199] = tt_srpt_ptr[7:0];
        end
    endtask

    // VMGI TT_SRPT: single title 1 -> title_set_nr (BE u16 nr_of_srpts @0).
    task put_tt_srpt(input integer sec, input [15:0] nsrpts, input [7:0] title1_vtsn);
        integer base;
        begin
            base = sec*2048;
            img[base+0] = nsrpts[15:8]; img[base+1] = nsrpts[7:0];
            img[base+8]  = 8'h00; img[base+9] = 8'h01;
            img[base+10] = 8'h00; img[base+11] = 8'h01;
            img[base+12] = 8'h00; img[base+13] = 8'h00;
            img[base+14] = title1_vtsn;   // TT_SRP[0].title_set_nr @14
            img[base+15] = 8'h01;
        end
    endtask

    // VTSI_MAT: vts_pgcit sector pointer (BE u32 @204), rel. to VTSI start.
    task put_vtsi_mat(input integer sec, input [31:0] vts_pgcit_ptr);
        integer base;
        begin
            base = sec*2048;
            img[base+204] = vts_pgcit_ptr[31:24]; img[base+205] = vts_pgcit_ptr[23:16];
            img[base+206] = vts_pgcit_ptr[15:8];  img[base+207] = vts_pgcit_ptr[7:0];
        end
    endtask

    // VTS_PGCIT (nr_srp BE u16 @0, SRP[0].pgc_start_byte BE u32 @12) + PGC
    // (nr_programs@2, nr_of_cells@3, cell_playback_offset BE u16 @232) + a cell
    // playback table (24 B/cell, first_sector BE u32 @+8, last_sector BE u32 @+20).
    // Everything is laid inside one sector for the test (no straddle).
    task put_pgcit(input integer sec, input [31:0] pgc_start_byte,
                   input [7:0] nr_cells, input [15:0] cell_pb_off);
        integer base; integer pgc; integer ctbl;
        begin
            base = sec*2048;
            // VTS_PGCIT header
            img[base+0] = 8'h00; img[base+1] = 8'h01;    // nr_of_pgci_srp = 1
            img[base+12] = pgc_start_byte[31:24]; img[base+13] = pgc_start_byte[23:16];
            img[base+14] = pgc_start_byte[15:8];  img[base+15] = pgc_start_byte[7:0];
            // PGC
            pgc = base + pgc_start_byte;
            img[pgc+2] = 8'h01;              // nr_of_programs
            img[pgc+3] = nr_cells;           // nr_of_cells
            img[pgc+232] = cell_pb_off[15:8];// cell_playback_offset (BE u16)
            img[pgc+233] = cell_pb_off[7:0];
            // PGC palette @164: 16 entries x {reserved, Y, Cr, Cb}. Use a known,
            // per-entry-distinct pattern so the reader's palette stream can be checked.
            for (i = 0; i < 16; i = i + 1) begin
                img[pgc+164+i*4+0] = 8'h00;                 // reserved
                img[pgc+164+i*4+1] = 8'h10 + i[7:0];        // Y
                img[pgc+164+i*4+2] = 8'h80 + i[7:0];        // Cr
                img[pgc+164+i*4+3] = 8'h40 + i[7:0];        // Cb
            end
            // cell table base
            ctbl = pgc + cell_pb_off;
            // (individual cells written by put_cell below)
        end
    endtask

    // Reference of the palette the reader must stream (matches put_pgcit above).
    function automatic [31:0] ref_pal(input integer e);
        ref_pal = {8'h00, 8'h10 + e[7:0], 8'h80 + e[7:0], 8'h40 + e[7:0]};
    endfunction

    // Write one cell entry (24 B) into the cell playback table.
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

    // Build the disc. vts_pgcit_ptr=0 => malformed PGC (linear fallback path).
    reg [7:0]  tb_ncells = 8'd2;   // nr_of_cells put into the PGC (TEST 3 overrides)
    reg [15:0] tb_cpo    = 16'd256; // cell_playback_offset (TEST 3 sets 0 = fallback)

    task build_iso(input [31:0] vts_pgcit_ptr);
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

            // VIDEO_TS dir @18 (name-sorted)
            cur = 36864;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 19, 4096, 8'h00, "VIDEO_TS.IFO;1", 14, cur); // VMGI (2 sec)
            put_rec(cur, 21, 6144, 8'h00, "VTS_01_0.IFO;1", 14, cur); // VTSI (3 sec)
            put_rec(cur, 24, 6144, 8'h00, "VTS_01_1.VOB;1", 14, cur); // title (3 sec)

            // VMGI (@19) + TT_SRPT (@20)
            put_vmgi(19, 32'd1);
            put_tt_srpt(20, 16'd1, 8'd1);

            // VTSI_MAT (@21) + VTS_PGCIT/PGC/cells (@22)
            put_vtsi_mat(21, vts_pgcit_ptr);
            if (vts_pgcit_ptr != 0) begin
                // pgc_start_byte=16, nr_cells=tb_ncells, cell_playback_offset=256
                put_pgcit(22, 32'd16, tb_ncells, tb_cpo);
                put_cell(22, 32'd16, 16'd256, 0, 32'd2, 32'd2);  // cell0 -> RBN 2 (0xB2)
                put_cell(22, 32'd16, 16'd256, 1, 32'd0, 32'd0);  // cell1 -> RBN 0 (0xB0)
            end

            // Title VOB payloads
            fill_sec(24, 8'hB0);   // RBN 0
            fill_sec(25, 8'hB1);   // RBN 1 (skipped by both cells)
            fill_sec(26, 8'hB2);   // RBN 2
        end
    endtask

    // ---- checks ----
    integer errors = 0;
    task expect_byte(input integer idx, input [7:0] got, input [7:0] want);
        begin
            if (got !== want) begin
                errors = errors + 1;
                if (errors < 20)
                    $display("  MISMATCH @%0d: got %02x want %02x", idx, got, want);
            end
        end
    endtask

    integer t;

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // =============================================================
        // TEST 1 - valid PGC: program order = cell0 (0xB2) then cell1 (0xB0)
        // =============================================================
        build_iso(32'd1);              // vts_pgcit at VTSI +1 = sector 22
        cap_n = 0;
        file_size = 28*2048;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        t = 0;
        while (cap_n < 4096 && t < 4000000) begin @(posedge clk); t = t + 1; end
        repeat (400) @(posedge clk);

        $display("TEST1: iso_mode=%b iso_error=%b cell_mode=%b cell_count=%0d cap_n=%0d (expect 1 0 1 2 4096)",
                 debug_iso_mode, debug_iso_error, dut.cell_mode, dut.cell_count, cap_n);
        if (debug_iso_mode !== 1'b1) begin errors=errors+1; $display("  ERR iso_mode not set"); end
        if (dut.cell_mode !== 1'b1)  begin errors=errors+1; $display("  ERR cell_mode not taken"); end
        if (dut.cell_count !== 8'd2) begin errors=errors+1; $display("  ERR cell_count != 2"); end
        if (cap_n !== 4096)          begin errors=errors+1; $display("  ERR wrong byte count (want 2 cells x 2048)"); end
        for (i = 0; i < 2048 && i < cap_n; i = i + 1)
            expect_byte(i, cap[i], 8'hB2);              // cell0 = RBN 2
        for (i = 0; i < 2048 && (2048+i) < cap_n; i = i + 1)
            expect_byte(2048+i, cap[2048+i], 8'hB0);    // cell1 = RBN 0

        // PGC palette: the reader must have streamed all 16 entries (@164) to
        // pgc_palette, in order, byte-exact (Phase-1 disc menus).
        $display("TEST1 palette: pal_writes=%0d (expect 16)", pal_writes);
        if (pal_writes !== 16) begin errors=errors+1; $display("  ERR pal_writes != 16"); end
        for (i = 0; i < 16; i = i + 1)
            if (pal_cap[i] !== ref_pal(i)) begin
                errors=errors+1;
                $display("  ERR palette[%0d] = %08h expected %08h", i, pal_cap[i], ref_pal(i));
            end

        // =============================================================
        // TEST 2 - malformed PGC (vts_pgcit=0): linear fallback streams the
        //          whole VTS_01_1.VOB in physical order (0xB0,0xB1,0xB2).
        // =============================================================
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        m = 0;
        build_iso(32'd0);
        cap_n = 0;
        file_size = 28*2048;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        t = 0;
        while (cap_n < 6144 && t < 4000000) begin @(posedge clk); t = t + 1; end
        repeat (400) @(posedge clk);

        $display("TEST2: iso_mode=%b cell_mode=%b cap_n=%0d (expect 1 0 6144)",
                 debug_iso_mode, dut.cell_mode, cap_n);
        if (debug_iso_mode !== 1'b1) begin errors=errors+1; $display("  ERR iso_mode not set"); end
        if (dut.cell_mode !== 1'b0)  begin errors=errors+1; $display("  ERR fallback should leave cell_mode=0"); end
        if (cap_n !== 6144)          begin errors=errors+1; $display("  ERR wrong fallback byte count (want 6144)"); end
        for (i = 0; i < 2048 && i < cap_n; i = i + 1)
            expect_byte(i, cap[i], 8'hB0);
        for (i = 0; i < 2048 && (2048+i) < cap_n; i = i + 1)
            expect_byte(2048+i, cap[2048+i], 8'hB1);
        for (i = 0; i < 2048 && (4096+i) < cap_n; i = i + 1)
            expect_byte(4096+i, cap[4096+i], 8'hB2);

        // =============================================================
        // TEST 3 - PGC that FALLS BACK TO LINEAR must STILL STREAM THE PALETTE
        //          (pal_writes=16). This is the MiB "white subtitles" regression:
        //          the palette load used to be gated behind the cell bail, so a
        //          fallback title got the grayscale default.
        //          NOTE: MAXCELL is now 255 (= the 1-byte nr_of_cells max), so a
        //          high cell COUNT no longer triggers the fallback (a >128-cell
        //          movie like MiB now gets proper cell-mode). We trigger the
        //          fallback via cell_playback_offset==0 (cells declared, no cell
        //          table) instead, which still exercises the palette-on-fallback
        //          path this test guards.
        // =============================================================
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        m = 0;
        pal_writes = 0;
        tb_ncells = 8'd200;           // has cells...
        tb_cpo    = 16'd0;            // ...but no cell table -> linear fallback
        build_iso(32'd1);
        tb_ncells = 8'd2;            // restore defaults for any later use
        tb_cpo    = 16'd256;
        cap_n = 0;
        file_size = 28*2048;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        t = 0;
        while (cap_n < 6144 && t < 4000000) begin @(posedge clk); t = t + 1; end
        repeat (400) @(posedge clk);

        $display("TEST3: cell_mode=%b pal_writes=%0d (expect 0 16)  [movie >MAXCELL: linear + palette]",
                 dut.cell_mode, pal_writes);
        if (dut.cell_mode !== 1'b0) begin errors=errors+1; $display("  ERR >MAXCELL should fall back to linear"); end
        if (pal_writes !== 16)      begin errors=errors+1; $display("  ERR palette NOT streamed on the linear-fallback path (the MiB bug)"); end
        for (i = 0; i < 16; i = i + 1)
            if (pal_cap[i] !== ref_pal(i)) begin
                errors=errors+1;
                $display("  ERR TEST3 palette[%0d] = %08h expected %08h", i, pal_cap[i], ref_pal(i));
            end

        // =============================================================
        if (errors == 0) $display("ISO_READER_PGC_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_PGC_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin
        #300000000;
        $display("ISO_READER_PGC_TB: TIMEOUT");
        $finish;
    end

endmodule
