// iso_reader_tb.sv - testbench for dvd/dvd_iso_reader.sv
//
// Builds a synthetic DVD-Video ISO9660 image in memory and a mock HPS that
// answers the sd_* block interface (2048-byte blocks = one sector) out of that image.
//
// Layout (2048-byte logical sectors):
//   16 PVD (root dir @ 17)
//   17 root dir  -> VIDEO_TS dir @ 18, len 4096 (spans sectors 18-19)
//   18 VIDEO_TS dir sector 0: ".","..",VIDEO_TS.VOB, VTS_01_0, VTS_01_1
//   19 VIDEO_TS dir sector 1: VTS_02_0, VTS_02_1, VTS_02_2
//   20 VIDEO_TS.VOB   (VMG menu, excluded)          0x90
//   21 VTS_01_0.VOB   (menu part0, excluded)        0x91
//   22 VTS_01_1.VOB   (title VTS1, 1 sec)           0xA1
//   23 VTS_02_0.VOB   (menu part0, excluded)        0x92
//   24 VTS_02_1.VOB   (title VTS2 part1, 2 sec)     0xB1 0xB2  (sec 24,25)
//   26 gap                                          0x00
//   27 VTS_02_2.VOB   (title VTS2 part2, 1 sec)     0xC1
//
// VTS2 total (4096+2048=6144) > VTS1 (2048) -> main feature = VTS_02.
// Expected stream = VTS_02_1 (sec24,25) then VTS_02_2 (sec27) = a NON-contiguous
// concat = 0xB1x2048, 0xB2x2048, 0xC1x2048.
//
// Test 2 reuses the image memory as a non-ISO9660 flat file (no CD001) and
// checks the fallback streams the whole file linearly.

`timescale 1ns/1ps

module iso_reader_tb;

    localparam IMG_BYTES = 28*2048;   // 57344

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

    // ---------------------------------------------------------------
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
            sd_ack     <= 1'b0;   // falling edge -> block done
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

    // Write one ISO9660 directory record; return the offset of the next record.
    task put_rec(input integer off, input [31:0] ext, input [31:0] dlen,
                 input [7:0] flags, input [127:0] nm, input integer nlen,
                 output integer next_off);
        integer j; integer rl;
        begin
            rl = 33 + nlen;
            if (rl[0]) rl = rl + 1;              // pad to even
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

    task build_iso;
        begin
            for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = 8'h00;

            // PVD @ sector 16
            img[32768] = 8'd1;
            img[32769] = "C"; img[32770] = "D"; img[32771] = "0";
            img[32772] = "0"; img[32773] = "1"; img[32774] = 8'd1;
            put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur);  // root dir record

            // root dir @ sector 17
            cur = 34816;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);       // "."
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);       // ".."
            put_rec(cur, 18, 4096, 8'h02, "VIDEO_TS", 8, cur);    // VIDEO_TS dir (2 sec)

            // VIDEO_TS dir sector 0 @ sector 18
            cur = 36864;
            put_rec(cur, 17, 4096, 8'h02, 128'h00, 1, cur);       // "."
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);       // ".."
            put_rec(cur, 20, 2048, 8'h00, "VIDEO_TS.VOB;1", 14, cur); // VMG menu (excl)
            put_rec(cur, 21, 2048, 8'h00, "VTS_01_0.VOB;1", 14, cur); // menu p0  (excl)
            put_rec(cur, 22, 2048, 8'h00, "VTS_01_1.VOB;1", 14, cur); // VTS1 title

            // VIDEO_TS dir sector 1 @ sector 19
            cur = 38912;
            put_rec(cur, 23, 2048, 8'h00, "VTS_02_0.VOB;1", 14, cur); // menu p0  (excl)
            put_rec(cur, 24, 4096, 8'h00, "VTS_02_1.VOB;1", 14, cur); // VTS2 p1 (2 sec)
            put_rec(cur, 27, 2048, 8'h00, "VTS_02_2.VOB;1", 14, cur); // VTS2 p2

            // VOB payloads
            fill_sec(20, 8'h90);
            fill_sec(21, 8'h91);
            fill_sec(22, 8'hA1);
            fill_sec(23, 8'h92);
            fill_sec(24, 8'hB1);
            fill_sec(25, 8'hB2);
            fill_sec(26, 8'h00);
            fill_sec(27, 8'hC1);
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
        // TEST 1 - ISO navigation
        // =============================================================
        build_iso;
        cap_n = 0;
        file_size = 28*2048;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        // wait for the 6144 expected bytes (with a safety timeout)
        t = 0;
        while (cap_n < 6144 && t < 2000000) begin @(posedge clk); t = t + 1; end
        repeat (200) @(posedge clk);   // ensure no extra bytes trickle out

        $display("TEST1: iso_mode=%b iso_error=%b cap_n=%0d (expect 1 0 6144)",
                 debug_iso_mode, debug_iso_error, cap_n);
        if (debug_iso_mode !== 1'b1) begin errors=errors+1; $display("  ERR iso_mode not set"); end
        if (debug_iso_error !== 1'b0) begin errors=errors+1; $display("  ERR iso_error set"); end
        if (cap_n !== 6144)          begin errors=errors+1; $display("  ERR wrong byte count"); end

        for (i = 0; i < 2048 && i < cap_n; i = i + 1)
            expect_byte(i, cap[i], img[24*2048 + i]);           // VTS_02_1 sec24
        for (i = 0; i < 2048 && (2048+i) < cap_n; i = i + 1)
            expect_byte(2048+i, cap[2048+i], img[25*2048 + i]); // VTS_02_1 sec25
        for (i = 0; i < 2048 && (4096+i) < cap_n; i = i + 1)
            expect_byte(4096+i, cap[4096+i], img[27*2048 + i]); // VTS_02_2 sec27

        // =============================================================
        // TEST 2 - flat-file fallback (no CD001), whole file linear
        // =============================================================
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        m = 0;
        for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = i[7:0];   // ramp, sec16 != CD001
        cap_n = 0;
        file_size = 20*2048;                                     // 20 sectors (>=17)
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        t = 0;
        while (cap_n < 20*2048 && t < 4000000) begin @(posedge clk); t = t + 1; end
        repeat (200) @(posedge clk);

        $display("TEST2: iso_mode=%b cap_n=%0d (expect 0 %0d)",
                 debug_iso_mode, cap_n, 20*2048);
        if (debug_iso_mode !== 1'b0) begin errors=errors+1; $display("  ERR iso_mode set on flat file"); end
        if (cap_n !== 20*2048)       begin errors=errors+1; $display("  ERR wrong fallback byte count"); end
        for (i = 0; i < 20*2048 && i < cap_n; i = i + 1)
            expect_byte(i, cap[i], img[i]);

        // =============================================================
        if (errors == 0) $display("ISO_READER_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_TB: FAILED with %0d errors", errors);
        $finish;
    end

    // global watchdog
    initial begin
        #200000000;
        $display("ISO_READER_TB: TIMEOUT");
        $finish;
    end

endmodule
