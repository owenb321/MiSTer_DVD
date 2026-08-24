// iso_reader_ifo_tb.sv - title-selection test for dvd/dvd_iso_reader.sv
//
// Builds a synthetic DVD-Video ISO with two title sets where the LARGEST VTS and
// the one the VMGI TT_SRPT names as title 1 DISAGREE, then checks:
//   - the OSD manual "DVD Title" pick (title_sel = VTS #) overrides, and
//   - Auto (title_sel = 0) plays the LARGEST VTS (the longest-title proxy; NOT
//     the VMGI TT_SRPT "title 1", which was retired from Auto).
//
// Layout (2048-byte logical sectors):
//   16 PVD (root dir @ 17)
//   17 root dir  -> VIDEO_TS dir @ 18, len 2048
//   18 VIDEO_TS dir: ".","..",VIDEO_TS.IFO,VTS_01_0,VTS_01_1,VTS_03_0,VTS_03_1
//   19 VIDEO_TS.IFO sec0 = VMGI_MAT (tt_srpt ptr @196, BE); extent=19 dlen=4096
//   20 VIDEO_TS.IFO sec1 = TT_SRPT (title 1 -> VTS_01, now ignored by Auto)
//   21 VTS_01_1.VOB  (title VTS1, 1 sec = 2048 B)   0xA1   <- SMALL
//   22 VTS_03_1.VOB  (title VTS3, 3 sec = 6144 B)   0xC1 0xC2 0xC3 (sec 22-24) <- LARGEST
//   25 menu part0 payloads (excluded)               0x00
//
//   TEST 1: title_sel=1 (manual VTS #1) -> stream VTS_01 (2048 B of 0xA1), sel_valid=1.
//   TEST 2: title_sel=0 (Auto = largest) -> stream VTS_03 (6144 B: 0xC1,0xC2,0xC3),
//           sel_valid=0.  (Auto ignores TT_SRPT title 1 -> VTS_01.)

`timescale 1ns/1ps

module iso_reader_ifo_tb;

    localparam IMG_BYTES = 28*2048;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [63:0] file_size = 0;
    reg  [3:0]  title_sel = 0;

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

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(title_sel), .vbuf_empty(1'b0), .menu_snap(1'b0),
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

    // Write VMGI_MAT identifier + tt_srpt sector pointer (BIG-ENDIAN @196).
    task put_vmgi(input integer sec, input [31:0] tt_srpt_ptr);
        integer base; integer j;
        begin
            base = sec*2048;
            // "DVDVIDEO-VMG" identifier (informational; not checked by RTL)
            img[base+0]="D"; img[base+1]="V"; img[base+2]="D"; img[base+3]="V";
            img[base+4]="I"; img[base+5]="D"; img[base+6]="E"; img[base+7]="O";
            img[base+8]="-"; img[base+9]="V"; img[base+10]="M"; img[base+11]="G";
            // tt_srpt @196, BIG-ENDIAN u32
            img[base+196] = tt_srpt_ptr[31:24];
            img[base+197] = tt_srpt_ptr[23:16];
            img[base+198] = tt_srpt_ptr[15:8];
            img[base+199] = tt_srpt_ptr[7:0];
        end
    endtask

    // Write a TT_SRPT with a single title 1 pointing at title_set_nr (VTSN).
    task put_tt_srpt(input integer sec, input [15:0] nsrpts, input [7:0] title1_vtsn);
        integer base;
        begin
            base = sec*2048;
            // nr_of_srpts @0, BIG-ENDIAN u16
            img[base+0] = nsrpts[15:8];
            img[base+1] = nsrpts[7:0];
            // TT_SRP[0] @8; title_set_nr @ +6 => absolute offset 14
            img[base+8]  = 8'h00;   // playback_type
            img[base+9]  = 8'h01;   // nr_of_angles
            img[base+10] = 8'h00; img[base+11] = 8'h01; // nr_of_ptts (BE)
            img[base+12] = 8'h00; img[base+13] = 8'h00; // parental_id
            img[base+14] = title1_vtsn;                 // title_set_nr (VTSN)
            img[base+15] = 8'h01;                       // vts_ttn
        end
    endtask

    // Build the disc; tt_srpt_ptr=0 => malformed IFO (fallback path).
    task build_iso(input [31:0] tt_srpt_ptr);
        begin
            for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = 8'h00;

            // PVD @ sector 16
            img[32768] = 8'd1;
            img[32769] = "C"; img[32770] = "D"; img[32771] = "0";
            img[32772] = "0"; img[32773] = "1"; img[32774] = 8'd1;
            put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur); // root dir record

            // root dir @ sector 17
            cur = 34816;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);       // "."
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);       // ".."
            put_rec(cur, 18, 2048, 8'h02, "VIDEO_TS", 8, cur);    // VIDEO_TS dir

            // VIDEO_TS dir @ sector 18 (name-sorted)
            cur = 36864;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);              // "."
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);              // ".."
            put_rec(cur, 19, 4096, 8'h00, "VIDEO_TS.IFO;1", 14, cur);    // VMGI (2 sec)
            put_rec(cur, 25, 2048, 8'h00, "VTS_01_0.VOB;1", 14, cur);    // menu (excl)
            put_rec(cur, 21, 2048, 8'h00, "VTS_01_1.VOB;1", 14, cur);    // VTS1 title (small)
            put_rec(cur, 25, 2048, 8'h00, "VTS_03_0.VOB;1", 14, cur);    // menu (excl)
            put_rec(cur, 22, 6144, 8'h00, "VTS_03_1.VOB;1", 14, cur);    // VTS3 title (large)

            // VMGI + TT_SRPT (VIDEO_TS.IFO extent = sector 19, TT_SRPT @ +ptr)
            put_vmgi(19, tt_srpt_ptr);
            if (tt_srpt_ptr != 0)
                put_tt_srpt(19 + tt_srpt_ptr, 16'd1, 8'd1);  // title 1 -> VTS_01

            // VOB payloads
            fill_sec(21, 8'hA1);           // VTS_01_1 (feature per IFO)
            fill_sec(22, 8'hC1);           // VTS_03_1 sec0
            fill_sec(23, 8'hC2);           // VTS_03_1 sec1
            fill_sec(24, 8'hC3);           // VTS_03_1 sec2
            fill_sec(25, 8'h00);           // menu part0 (excluded)
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
        // TEST 1 - manual OSD pick: title_sel=1 -> VTS_01 (NOT the largest)
        // =============================================================
        build_iso(32'd1);              // valid VMGI (now ignored by Auto)
        title_sel = 4'd1;              // OSD "DVD Title" = VTS #1
        cap_n = 0;
        file_size = 28*2048;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        t = 0;
        while (cap_n < 2048 && t < 2000000) begin @(posedge clk); t = t + 1; end
        repeat (300) @(posedge clk);   // ensure no extra bytes trickle out

        $display("TEST1: iso_mode=%b iso_error=%b sel_valid=%b cap_n=%0d (expect 1 0 1 2048)",
                 debug_iso_mode, debug_iso_error, dut.sel_valid, cap_n);
        if (debug_iso_mode !== 1'b1) begin errors=errors+1; $display("  ERR iso_mode not set"); end
        if (debug_iso_error !== 1'b0) begin errors=errors+1; $display("  ERR iso_error set"); end
        if (dut.sel_valid !== 1'b1)   begin errors=errors+1; $display("  ERR manual selection not taken"); end
        if (dut.target_vtsn !== 8'd1) begin errors=errors+1; $display("  ERR target VTSN != 1"); end
        if (cap_n !== 2048)           begin errors=errors+1; $display("  ERR wrong byte count (want VTS_01=2048)"); end
        for (i = 0; i < 2048 && i < cap_n; i = i + 1)
            expect_byte(i, cap[i], 8'hA1);   // VTS_01_1

        // =============================================================
        // TEST 2 - Auto (title_sel=0): largest VTS_03 (ignores TT_SRPT title 1)
        // =============================================================
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        m = 0;
        build_iso(32'd1);              // valid VMGI title 1 -> VTS_01, but Auto ignores it
        title_sel = 4'd0;              // Auto
        cap_n = 0;
        file_size = 28*2048;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        t = 0;
        while (cap_n < 6144 && t < 4000000) begin @(posedge clk); t = t + 1; end
        repeat (300) @(posedge clk);

        $display("TEST2: iso_mode=%b sel_valid=%b cap_n=%0d (expect 1 0 6144)",
                 debug_iso_mode, dut.sel_valid, cap_n);
        if (debug_iso_mode !== 1'b1) begin errors=errors+1; $display("  ERR iso_mode not set"); end
        if (dut.sel_valid !== 1'b0)  begin errors=errors+1; $display("  ERR Auto should leave sel_valid=0 (largest)"); end
        if (cap_n !== 6144)          begin errors=errors+1; $display("  ERR wrong Auto byte count (want largest VTS_03=6144)"); end
        for (i = 0; i < 2048 && i < cap_n; i = i + 1)
            expect_byte(i, cap[i], 8'hC1);
        for (i = 0; i < 2048 && (2048+i) < cap_n; i = i + 1)
            expect_byte(2048+i, cap[2048+i], 8'hC2);
        for (i = 0; i < 2048 && (4096+i) < cap_n; i = i + 1)
            expect_byte(4096+i, cap[4096+i], 8'hC3);

        // =============================================================
        if (errors == 0) $display("ISO_READER_IFO_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_IFO_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin
        #200000000;
        $display("ISO_READER_IFO_TB: TIMEOUT");
        $finish;
    end

endmodule
