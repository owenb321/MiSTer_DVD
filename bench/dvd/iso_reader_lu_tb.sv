// iso_reader_lu_tb.sv - spec-hardening Phase 4: PGCI_UT LANGUAGE-UNIT
// selection (libdvdnav get_MENU_PGCIT semantics).
//
// The reader used LU[0] unconditionally. Multi-LU UTs are now walked matching
// the player language (SPRM0 = 'en', a constant in dvd_vm) against each LU's
// lang_code; no match falls back to LU[0]. Single-LU UTs keep the exact
// pre-Phase-4 path. Evidence: 44/302 library discs author nr_of_lus > 1
// (42 with en at LU[0] = benign; both Hobbit discs author a wildcard-0xFFFF
// LU[0] with the real en unit at LU[1] - the repro shape tested here).
//
//   T1  VTS_01 VTSM Root jump: 3 LUs {fr, de, en} whose units point at
//       DIFFERENT PGCITs (menus 0xD0/0xD1/0xD2). The en unit (LU[2]) must be
//       picked -> streams 0xD2. (Old RTL streamed LU[0]'s 0xD0.)
//       This is also the Hobbit shape generalized: en NOT at LU[0].
//   T2  VMGM Title jump: 2 LUs {fr, es} - NO en -> LU[0] fallback (the
//       libdvdnav rule, warning-and-use-first) -> streams 0xC0.
//   T3  VTS_02 VTSM Root jump: SINGLE LU with wildcard lang 0xFFFF (the
//       Hobbit VMGM shape) -> LU[0] direct (bit-identical v1 path) ->
//       streams 0xE0.
//
// Layout (2048-byte sectors):
//   16 PVD   17 root   18 VIDEO_TS dir
//   19 VIDEO_TS.IFO s0 = VMGI (vmgm_pgci_ut@200=1 -> 20)
//   20 VIDEO_TS.IFO s1 = VMGM PGCI_UT: 2 LUs fr@+24 es@+324; entry 0x82
//       PGCs -> VIDEO_TS.VOB cells {0,0}=0xC0 / {1,1}=0xC1
//   21 VTS_01_0.IFO s0 = VTSI (vts_pgcit@204=1 -> 22; vtsm_pgci_ut@208=2 -> 23)
//   22 VTS_01_0.IFO s1 = title VTS_PGCIT (PGC1: 1 cell {0,0} = 0xB0)
//   23 VTS_01_0.IFO s2 = VTSM PGCI_UT: 3 LUs fr@+32 de@+632 en@+1232;
//       entry 0x83 PGCs -> VTS_01_0.VOB cells {0,0}/{1,1}/{2,2}
//   24 VTS_02_0.IFO s0 = VTSI (vts_pgcit@204=1 -> 25; vtsm_pgci_ut@208=2 -> 26)
//   25 VTS_02_0.IFO s1 = title VTS_PGCIT (PGC1: 1 cell {0,0} = 0xB1)
//   26 VTS_02_0.IFO s2 = VTSM PGCI_UT: 1 LU lang=0xFFFF -> cell {0,0} = 0xE0
//   27,28,29 VTS_01_0.VOB (0xD0 0xD1 0xD2)   30 VTS_01_1.VOB (0xB0)
//   31 VTS_02_0.VOB (0xE0)                   32 VTS_02_1.VOB (0xB1)
//   33,34 VIDEO_TS.VOB (0xC0 0xC1)
//
// Run: iverilog -g2012 -o /tmp/lu dvd/dvd_iso_reader.sv dvd/bcd_time_add.sv \
//        bench/dvd/iso_reader_lu_tb.sv && vvp /tmp/lu

`timescale 1ns/1ps

module iso_reader_lu_tb;

    localparam IMG_BYTES = 36*2048;

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

    reg         jump_pulse = 0;
    reg  [1:0]  jump_domain = 0;
    reg  [7:0]  jump_vts = 0;
    reg  [7:0]  jump_pgcn = 0;
    reg  [3:0]  jump_entry = 0;
    reg  [7:0]  jump_cell = 0;
    wire        jump_ack, pgc_loaded, pgc_error, menu_active, still_active;
    wire        seek_ack;
    wire [7:0]  cur_vts, best_menu_vts;

    reg  [7:0]  img [0:IMG_BYTES-1];

    // OSD "Player Language" (T4 switches it live to prove a non-en user pref
    // - e.g. a Japanese speaker wanting the ja unit - picks that LU)
    reg  [15:0] lang_pref = 16'h656E;

    integer cap_n = 0;
    reg       await_first = 0;
    reg [7:0] post_jump_byte = 0;
    reg       post_jump_v = 0;
    always @(posedge clk) begin
        if (jump_ack) begin await_first <= 1'b1; post_jump_v <= 1'b0; end
        if (stream_valid) begin
            cap_n = cap_n + 1;
            if (await_first) begin
                post_jump_byte <= stream_data;
                post_jump_v    <= 1'b1;
                await_first    <= 1'b0;
            end
        end
    end

    integer n_pgc_error = 0;
    always @(posedge clk) if (pgc_error) n_pgc_error = n_pgc_error + 1;

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(7'd0),
        .lu_lang_pref(lang_pref),
        .vbuf_empty(1'b0), .menu_snap(1'b0),
        .jump_ttn(7'd0), .jump_pgn(8'd0), .jump_ptt(10'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_pulse(1'b0), .seek_natural(1'b0), .seek_cell(8'd0), .seek_ack(seek_ack),
        .cur_cell(), .cell_ready(),
        .jump_pulse(jump_pulse), .jump_natural(1'b0), .jump_domain(jump_domain), .jump_vts(jump_vts),
        .jump_pgcn({8'd0, jump_pgcn}), .jump_entry(jump_entry), .jump_cell(jump_cell),
        .jump_ack(jump_ack), .keep_vbuf(), .pgc_loaded(pgc_loaded), .pgc_error(pgc_error),
        .menu_active(menu_active), .still_active(still_active), .cur_vts(cur_vts),
        .best_menu_vts(best_menu_vts),
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

    // PGCI_UT with n LUs: header {nr_of_lus u16@0, last_byte u32@4}, LU
    // descriptors @8+8*i {lang u16, ext u8, exists u8, start u32}.
    task put_ut_hdr(input integer sec, input [15:0] nlus);
        begin
            be16(sec*2048+0, nlus);
            be32(sec*2048+4, 32'd2047);
        end
    endtask
    task put_lu(input integer sec, input integer idx,
                input [15:0] lang, input [31:0] start_byte);
        integer a;
        begin
            a = sec*2048 + 8 + idx*8;
            be16(a, lang);
            img[a+2] = 8'd0; img[a+3] = 8'h80;
            be32(a+4, start_byte);
        end
    endtask

    // A minimal LU unit (PGCIT) at UT byte offset `off`: 1 SRP with entry_id,
    // one PGC with a single cell {first,last}.
    task put_lu_unit(input integer sec, input integer off,
                     input [7:0] entry_id, input [31:0] first, input [31:0] last);
        integer base;
        begin
            base = sec*2048 + off;
            be16(base+0, 16'd1);                       // nr_of_pgci_srp
            img[base+8] = entry_id;
            be32(base+8+4, 32'd32);                    // pgc @ +32
            img[base+32+2] = 8'd1;                     // nr_of_programs
            img[base+32+3] = 8'd1;                     // nr_of_cells
            be16(base+32+228, 16'd0);                  // no commands
            be16(base+32+230, 16'd236);                // program map @236
            img[base+32+236] = 8'd1;
            be16(base+32+232, 16'd240);                // cell playback @240
            be32(base+32+240+8, first);
            be32(base+32+240+20, last);
        end
    endtask

    task build_iso;
        integer j;
        begin
            for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = 8'h00;

            img[32768] = 8'd1;
            img[32769]="C"; img[32770]="D"; img[32771]="0";
            img[32772]="0"; img[32773]="1"; img[32774]=8'd1;
            put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur);

            cur = 17*2048;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 18, 2048, 8'h02, "VIDEO_TS", 8, cur);

            cur = 18*2048;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 19, 4096, 8'h00, "VIDEO_TS.IFO;1", 14, cur); // 19..20
            put_rec(cur, 33, 4096, 8'h00, "VIDEO_TS.VOB;1", 14, cur); // 33..34
            put_rec(cur, 21, 6144, 8'h00, "VTS_01_0.IFO;1", 14, cur); // 21..23
            put_rec(cur, 27, 6144, 8'h00, "VTS_01_0.VOB;1", 14, cur); // 27..29
            put_rec(cur, 30, 2048, 8'h00, "VTS_01_1.VOB;1", 14, cur); // 30
            put_rec(cur, 24, 6144, 8'h00, "VTS_02_0.IFO;1", 14, cur); // 24..26
            put_rec(cur, 31, 2048, 8'h00, "VTS_02_0.VOB;1", 14, cur); // 31
            put_rec(cur, 32, 2048, 8'h00, "VTS_02_1.VOB;1", 14, cur); // 32

            // VMGI @19: vmgm_pgci_ut@200 = +1 (sector 20)
            be32(19*2048+200, 32'd1);

            // VMGM PGCI_UT @20: 2 LUs {fr, es} - NO en -> LU[0] fallback (T2)
            put_ut_hdr(20, 16'd2);
            put_lu(20, 0, 16'h6672, 32'd24);           // 'fr' -> unit @+24
            put_lu(20, 1, 16'h6573, 32'd324);          // 'es' -> unit @+324
            put_lu_unit(20, 24,  8'h82, 32'd0, 32'd0); // fr: VIDEO_TS.VOB {0,0}=C0
            put_lu_unit(20, 324, 8'h82, 32'd1, 32'd1); // es: {1,1}=C1

            // VTS_01 VTSI @21
            be32(21*2048+204, 32'd1);                  // title PGCIT @22
            be32(21*2048+208, 32'd2);                  // VTSM UT @23

            // VTS_01 title PGCIT @22: PGC1, 1 cell {0,0} = 0xB0
            be16(22*2048+0, 16'd1);
            img[22*2048+8] = 8'h81;
            be32(22*2048+8+4, 32'd32);
            img[22*2048+32+2] = 8'd1;
            img[22*2048+32+3] = 8'd1;
            be16(22*2048+32+228, 16'd0);
            be16(22*2048+32+230, 16'd236);
            img[22*2048+32+236] = 8'd1;
            be16(22*2048+32+232, 16'd240);
            be32(22*2048+32+240+8,  32'd0);
            be32(22*2048+32+240+20, 32'd0);

            // VTS_01 VTSM PGCI_UT @23: 3 LUs {fr, de, en}, en at LU[2] (T1 -
            // the Hobbit shape generalized: en NOT at LU[0], units DIFFER)
            put_ut_hdr(23, 16'd3);
            put_lu(23, 0, 16'h6672, 32'd32);           // 'fr' -> unit @+32
            put_lu(23, 1, 16'h6465, 32'd632);          // 'de' -> unit @+632
            put_lu(23, 2, 16'h656E, 32'd1232);         // 'en' -> unit @+1232
            put_lu_unit(23, 32,   8'h83, 32'd0, 32'd0); // fr: menu {0,0}=D0
            put_lu_unit(23, 632,  8'h83, 32'd1, 32'd1); // de: {1,1}=D1
            put_lu_unit(23, 1232, 8'h83, 32'd2, 32'd2); // en: {2,2}=D2

            // VTS_02 VTSI @24
            be32(24*2048+204, 32'd1);                  // title PGCIT @25
            be32(24*2048+208, 32'd2);                  // VTSM UT @26

            // VTS_02 title PGCIT @25: PGC1, 1 cell {0,0} = 0xB1
            be16(25*2048+0, 16'd1);
            img[25*2048+8] = 8'h81;
            be32(25*2048+8+4, 32'd32);
            img[25*2048+32+2] = 8'd1;
            img[25*2048+32+3] = 8'd1;
            be16(25*2048+32+228, 16'd0);
            be16(25*2048+32+230, 16'd236);
            img[25*2048+32+236] = 8'd1;
            be16(25*2048+32+232, 16'd240);
            be32(25*2048+32+240+8,  32'd0);
            be32(25*2048+32+240+20, 32'd0);

            // VTS_02 VTSM PGCI_UT @26: SINGLE wildcard LU (Hobbit VMGM shape,
            // T3 - must take the bit-identical single-LU path)
            put_ut_hdr(26, 16'd1);
            put_lu(26, 0, 16'hFFFF, 32'd24);
            put_lu_unit(26, 24, 8'h83, 32'd0, 32'd0);  // {0,0}=E0

            for (j = 0; j < 2048; j = j + 1) begin
                img[27*2048+j] = 8'hD0;
                img[28*2048+j] = 8'hD1;
                img[29*2048+j] = 8'hD2;
                img[30*2048+j] = 8'hB0;
                img[31*2048+j] = 8'hE0;
                img[32*2048+j] = 8'hB1;
                img[33*2048+j] = 8'hC0;
                img[34*2048+j] = 8'hC1;
            end
        end
    endtask

    task do_jump(input [1:0] d, input [7:0] v, input [3:0] e);
    begin
        @(negedge clk);
        jump_domain = d; jump_vts = v; jump_pgcn = 0; jump_entry = e;
        jump_cell = 0; jump_pulse = 1;
        @(negedge clk); jump_pulse = 0;
    end
    endtask

    task check_jump(input [7:0] want, input [255:0] label);
        integer t;
    begin
        post_jump_v = 0;
        t = 0;
        while (!post_jump_v && t < 3000000) begin @(posedge clk); t = t + 1; end
        if (!post_jump_v) begin
            $display("FAIL %0s: no stream after jump (errors=%0d)", label, n_pgc_error);
            errors = errors + 1;
        end else if (post_jump_byte !== want) begin
            $display("FAIL %0s: streamed %02x, expected %02x", label, post_jump_byte, want);
            errors = errors + 1;
        end else
            $display("%0s -> %02x  PASS", label, want);
    end
    endtask

    initial begin
        build_iso; file_size = IMG_BYTES;
        repeat (5) @(negedge clk); rst_n = 1; repeat (5) @(negedge clk);
        start = 1; @(negedge clk); start = 0;

        // mount settles on the auto title (VTS_01, 0xB0) first
        begin : wmount
            integer t; t = 0;
            while (cap_n < 100 && t < 3000000) begin @(posedge clk); t = t + 1; end
            if (cap_n < 100) begin $display("FAIL: mount never streamed"); errors = errors + 1; end
        end

        // T1: VTSM Root, 3 LUs, en at LU[2] -> the en unit's menu (0xD2)
        do_jump(2'd2, 8'd1, 4'd3);
        check_jump(8'hD2, "T1: VTSM 3-LU walk picks the en unit (LU[2])");

        // T2: VMGM Title, 2 LUs {fr,es}, no en -> LU[0] fallback (0xC0)
        do_jump(2'd1, 8'd0, 4'd2);
        check_jump(8'hC0, "T2: VMGM no-en falls back to LU[0]");

        // T3: VTS_02 VTSM, single wildcard LU -> direct LU[0] path (0xE0)
        do_jump(2'd2, 8'd2, 4'd3);
        check_jump(8'hE0, "T3: single wildcard LU takes the v1 path");

        // T4: a NON-English player preference is honored - set Player
        // Language = 'de' and re-enter VTS_01's menu: the de unit (LU[1],
        // 0xD1) must be picked over both fr (LU[0]) and en (LU[2]).
        lang_pref = "de";
        do_jump(2'd2, 8'd1, 4'd3);
        check_jump(8'hD1, "T4: Player Language 'de' picks the de unit (LU[1])");
        lang_pref = 16'h656E;

        if (n_pgc_error != 0) begin
            $display("FAIL: %0d unexpected pgc_error pulses", n_pgc_error);
            errors = errors + 1;
        end

        if (errors == 0) $display("ISO_READER_LU_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_LU_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin
        #200000000;
        $display("GLOBAL TIMEOUT st=%0d cap=%0d", dut.state, cap_n);
        $finish;
    end

endmodule
