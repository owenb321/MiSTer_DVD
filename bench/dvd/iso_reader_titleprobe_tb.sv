// ============================================================================
// bench/dvd/iso_reader_titleprobe_tb.sv -- the mount's VMGM Title-entry probe
// (audit 10b; docs/dvd_vm.md "Title key on a disc with no Title menu").
//
// With Disc Menus on, the reader walks the VMGM PGCI_UT once at mount, BEFORE
// nav_ready rises (the VM boots on that rise), and records whether an entry-2
// (Title) PGC exists. emu.sv drops the Title key without one. The probe is the
// DOM_VMGM jump's own walk with `probe` set: same LU pick, same match rule, but
// no PGC taken, no SRP[0] fallback, no pgc_error, no menu aspect write, and dom
// left at DOM_TT so menu_active never rises.
//
// Layout (2048-byte sectors):
//   16 PVD  17 root  18 VIDEO_TS dir
//   19 VIDEO_TS.IFO s0 = VMGI (magic; @200 VMGM_PGCI_UT = +1; V_ATR@0x100 = 16:9)
//   20 VIDEO_TS.IFO s1 = VMGM PGCI_UT (per arm)
//   21 VTS_01_0.IFO s0 = VTSI (magic; @204 title PGCIT = +1)
//   22 VTS_01_0.IFO s1 = title PGCIT: PGC 1, cell {0,0} = 0xB0
//   23 VTS_01_1.VOB (0xB0)
//   24..26 VIDEO_TS.VOB (0xC0, 0xC1, 0xC2) -- VMGM PGC i plays cell {i,i}
//   30..31 VIDEO_TS.BUP (a copy of 19..20)
//
// Arms (all scored with !==; every arm: no pgc_error, ifo_nogood 0, and in a
// vm-mode arm menu_active 0 and menu_ar_wide 0 through the mount, nothing
// streamed before nav_ready, and nav_ready never high before vmgm_probed):
//   A  SRPs {0x00, 0x82}                    probed 1, ok 1; then a VMGM entry-2
//                                           jump plays the Title PGC (0xC1)
//   B  SRPs {0x00, 0x00} (Sony-style ids)   probed 1, ok 0; then a VMGM entry-2
//                                           jump (a disc's own command) still
//                                           falls back to SRP[0] (0xC0)
//   C  VMGI @200 = 0 (no PGCI_UT)           probed 1, ok 0
//   C2 PGCI_UT with nr_of_lus = 0           probed 1, ok 0
//   C3 en unit's PGCIT with 0 SRPs          probed 1, ok 0 (S_DONE, never the
//                                           linear-title fallback)
//   D  LUs fr {0x82} / en {0x00}            probed 1, ok 0 (the en unit decides)
//   D2 LUs fr {0x00} / en {0x82}            probed 1, ok 1
//   E  shape A, Disc Menus OFF              probed 0, ok 0; Auto plays 0xB0
//   F  shape A, VMGI s0 zeroed, good BUP    probed 1, ok 1, ifo_bup_vmg 1
//   H  SRPs {0x00, 0x82 malformed start}    probed 1, ok 1 (the entry decides)
// ============================================================================
`timescale 1ns/1ps

module iso_reader_titleprobe_tb;

    localparam NSEC      = 40;
    localparam IMG_BYTES = NSEC*2048;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [63:0] file_size = 0;
    reg         vm_mode = 0;

    reg         jump_pulse = 0;
    reg  [1:0]  jump_domain = 0;
    reg  [3:0]  jump_entry = 0;
    wire        jump_ack, pgc_loaded, pgc_error, nav_ready_w, menu_active;
    wire        menu_ar_wide;
    wire        ifo_bup_vmg, ifo_bup_vts, ifo_nogood;
    wire        vmgm_probed, vmgm_title_ok;

    wire [31:0] sd_lba;
    wire        sd_rd;
    reg         sd_ack = 0;
    reg  [13:0] sd_buff_addr = 0;
    reg  [7:0]  sd_buff_dout = 0;
    reg         sd_buff_wr = 0;
    wire [7:0]  stream_data;
    wire        stream_valid;

    reg  [7:0]  img [0:IMG_BYTES-1];

    dvd_iso_reader #(.NAV_CAP(1)) dut (
        // every input driven: a floating input is X, and `!=` against X passes
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size),
        .lu_lang_pref(16'h656E), .title_sel(7'd0),
        .vbuf_empty(1'b0), .aud_drained(1'b1), .disp_tick(1'b0), .disp_fps(6'd30),
        .seek_pulse(1'b0), .seek_cell(8'd0), .seek_natural(1'b0),
        .seek_rbn_pulse(1'b0), .seek_rbn(32'd0), .seek_tm_req(1'b0), .seek_tm_secs(17'd0),
        .chap_pulse(1'b0), .chap_dir(1'b0), .chap_mag(5'd0), .chap_at_start(1'b0),
        .still_off(1'b0), .angle_pulse(1'b0), .agl_vm(4'd0), .agl_vm_en(1'b0),
        .vm_pre_done(1'b0),
        .jump_pulse(jump_pulse), .jump_domain(jump_domain), .jump_vts(8'd0),
        .jump_pgcn(16'd0), .jump_entry(jump_entry), .jump_cell(8'd0),
        .jump_ttn(7'd0), .jump_pgn(8'd0), .jump_ptt(10'd0), .jump_natural(1'b0),
        .menu_btns_armed(1'b0),
        .vm_mode(vm_mode), .vm_adv(1'b0), .vm_replay(1'b0),
        .attr_a_sel(3'd0), .attr_s_sel(5'd0),
        .sd_ack(sd_ack), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
        .sd_buff_wr(sd_buff_wr), .busy(1'b0), .flat_seek_en(1'b0),
        // observed
        .sd_lba(sd_lba), .sd_rd(sd_rd),
        .stream_data(stream_data), .stream_valid(stream_valid),
        .jump_ack(jump_ack), .pgc_loaded(pgc_loaded), .pgc_error(pgc_error),
        .nav_ready_o(nav_ready_w), .menu_active(menu_active), .menu_ar_wide(menu_ar_wide),
        .ifo_bup_vmg(ifo_bup_vmg), .ifo_bup_vts(ifo_bup_vts), .ifo_nogood(ifo_nogood),
        .vmgm_probed(vmgm_probed), .vmgm_title_ok(vmgm_title_ok)
    );

    always #5 clk = ~clk;

    // ---- mock HPS ----
    integer m = 0, bc = 0, lat = 0;
    reg [31:0] rlba = 0;
    always @(posedge clk) begin
        sd_buff_wr <= 1'b0;
        case (m)
        0: begin sd_ack <= 1'b0; if (sd_rd) begin rlba <= sd_lba; lat <= 3; m <= 1; end end
        1: if (lat != 0) lat <= lat - 1; else begin sd_ack <= 1'b1; bc <= 0; m <= 2; end
        2: begin
            sd_ack <= 1'b1; sd_buff_wr <= 1'b1; sd_buff_addr <= bc[13:0];
            sd_buff_dout <= (rlba < NSEC) ? img[rlba*2048 + bc] : 8'h00;
            bc <= bc + 1; if (bc == 2047) m <= 3;
        end
        3: begin sd_ack <= 1'b0; sd_buff_wr <= 1'b0; m <= 0; end
        endcase
    end

    // ---- monitors (cleared at each mount) ----
    integer n_pgc_error = 0;
    reg     ma_seen = 0, wide_seen = 0, nav_early = 0, strm_early = 0;
    reg     await_first = 0, post_v = 0;
    reg [7:0] post_byte = 0;
    always @(posedge clk) begin
        if (start) begin
            n_pgc_error = 0; ma_seen <= 0; wide_seen <= 0; nav_early <= 0;
            strm_early <= 0;
        end else begin
            if (pgc_error) n_pgc_error = n_pgc_error + 1;
            if (menu_active === 1'b1) ma_seen <= 1'b1;
            if (menu_ar_wide === 1'b1) wide_seen <= 1'b1;
            if (vm_mode && nav_ready_w === 1'b1 && vmgm_probed !== 1'b1 &&
                dut.vmgi_found) nav_early <= 1'b1;
            // with Disc Menus on, nothing streams before the VM's first jump
            if (vm_mode && nav_ready_w !== 1'b1 && stream_valid) strm_early <= 1'b1;
        end
        if (jump_ack || start) begin await_first <= 1'b1; post_v <= 1'b0; end
        else if (stream_valid && await_first) begin
            post_byte <= stream_data; post_v <= 1'b1; await_first <= 1'b0;
        end
    end

    // ---- fixture ----
    integer cur, errors = 0;

    task put_rec(input integer off, input [31:0] ext, input [31:0] dlen,
                 input [7:0] flags, input [127:0] nm, input integer nlen,
                 output integer next_off);
        integer j; integer rl;
        begin
            rl = 33 + nlen; if (rl[0]) rl = rl + 1;
            img[off+0] = rl[7:0]; img[off+1] = 0;
            img[off+2] = ext[7:0]; img[off+3] = ext[15:8];
            img[off+4] = ext[23:16]; img[off+5] = ext[31:24];
            img[off+10] = dlen[7:0]; img[off+11] = dlen[15:8];
            img[off+12] = dlen[23:16]; img[off+13] = dlen[31:24];
            img[off+25] = flags;
            img[off+32] = nlen[7:0];
            for (j = 0; j < nlen; j = j + 1) img[off+33+j] = nm[8*(nlen-1-j) +: 8];
            next_off = off + rl;
        end
    endtask
    task be16(input integer a, input [15:0] v); begin img[a]=v[15:8]; img[a+1]=v[7:0]; end endtask
    task be32(input integer a, input [31:0] v);
        begin img[a]=v[31:24]; img[a+1]=v[23:16]; img[a+2]=v[15:8]; img[a+3]=v[7:0]; end endtask
    task magic(input integer sec, input vmg);
        integer j; reg [95:0] s;
        begin
            s = vmg ? "DVDVIDEO-VMG" : "DVDVIDEO-VTS";
            for (j = 0; j < 12; j = j + 1) img[sec*2048+j] = s[8*(11-j)+:8];
        end
    endtask
    // one-cell, command-less PGC at byte address pa, cell {c,c}
    task put_pgc(input integer pa, input [31:0] c);
        begin
            img[pa+2] = 8'd1; img[pa+3] = 8'd1;
            be16(pa+228, 16'd0);
            be16(pa+230, 16'd236); img[pa+236] = 8'd1;
            be16(pa+232, 16'd240);
            be32(pa+240+8, c); be32(pa+240+20, c);
        end
    endtask
    // a 2-SRP PGCIT at UT byte offset `off` in sector `sec`: SRP i plays cell {i,i};
    // bad1 gives SRP 1 a pgc_start past 2 MB (malformed)
    task put_unit(input integer sec, input integer off,
                  input [7:0] id0, input [7:0] id1, input bad1);
        integer base;
        begin
            base = sec*2048 + off;
            be16(base+0, 16'd2);
            img[base+8]  = id0; be32(base+8+4,  32'd32);
            img[base+16] = id1; be32(base+16+4, bad1 ? 32'hFF000000 : 32'd320);
            put_pgc(base+32, 32'd0);
            put_pgc(base+320, 32'd1);
        end
    endtask
    task put_ut(input integer sec, input [15:0] nlus);
        begin be16(sec*2048+0, nlus); be32(sec*2048+4, 32'd2047); end
    endtask
    task put_lu(input integer sec, input integer idx, input [15:0] lang, input [31:0] st);
        integer a;
        begin
            a = sec*2048 + 8 + idx*8;
            be16(a, lang); img[a+3] = 8'h80; be32(a+4, st);
        end
    endtask

    // shape: 0=A 1=B 2=C 3=D 4=D2 5=F 6=H 7=C2 8=C3
    task build(input integer shape);
        integer i, j;
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
            put_rec(cur, 19, 2*2048, 8'h00, "VIDEO_TS.IFO;1", 14, cur);
            put_rec(cur, 24, 3*2048, 8'h00, "VIDEO_TS.VOB;1", 14, cur);
            put_rec(cur, 30, 2*2048, 8'h00, "VIDEO_TS.BUP;1", 14, cur);
            put_rec(cur, 21, 2*2048, 8'h00, "VTS_01_0.IFO;1", 14, cur);
            put_rec(cur, 23, 2048,   8'h00, "VTS_01_1.VOB;1", 14, cur);

            // VMGI
            magic(19, 1);
            if (shape != 2) be32(19*2048+200, 32'd1);   // VMGM_PGCI_UT @ +1
            img[19*2048+256] = 8'h0C;                    // VMGM_V_ATR: 16:9

            // VMGM PGCI_UT @20
            case (shape)
            3, 4: begin
                put_ut(20, 16'd2);
                put_lu(20, 0, 16'h6672, 32'd24);          // 'fr' @ +24
                put_lu(20, 1, 16'h656E, 32'd1024);        // 'en' @ +1024
                put_unit(20, 24,   8'h00, (shape == 3) ? 8'h82 : 8'h00, 1'b0);
                put_unit(20, 1024, 8'h00, (shape == 4) ? 8'h82 : 8'h00, 1'b0);
            end
            default: begin
                put_ut(20, 16'd1);
                put_lu(20, 0, 16'h656E, 32'd16);
                put_unit(20, 16, 8'h00, (shape == 1) ? 8'h00 : 8'h82, shape == 6);
            end
            endcase
            if (shape == 7) be16(20*2048+0, 16'd0);          // nr_of_lus = 0
            if (shape == 8) be16(20*2048+16, 16'd0);         // nr_of_pgci_srp = 0

            // VTSI + title PGCIT
            magic(21, 0);
            be32(21*2048+204, 32'd1);
            be16(22*2048+0, 16'd1);
            img[22*2048+8] = 8'h81; be32(22*2048+8+4, 32'd32);
            put_pgc(22*2048+32, 32'd0);

            for (j = 0; j < 2048; j = j + 1) begin
                img[23*2048+j] = 8'hB0;
                img[24*2048+j] = 8'hC0;
                img[25*2048+j] = 8'hC1;
                img[26*2048+j] = 8'hC2;
            end

            // the BUP: a copy of the VMGI; F then zeroes the IFO's sector 0
            for (j = 0; j < 2*2048; j = j + 1) img[30*2048+j] = img[19*2048+j];
            if (shape == 5) for (j = 0; j < 2048; j = j + 1) img[19*2048+j] = 8'h00;
        end
    endtask

    task mount(input [127:0] arm, input integer shape, input vmm);
        integer t;
        begin
            build(shape);
            vm_mode = vmm;
            // menu_ar_wide is not reset by a mount (a menu jump sets it and it
            // holds), so clear it here: any 1 during this mount is then the
            // probe's own write (S_MENU_VATR, which the probe must skip).
            @(negedge clk); dut.menu_ar_wide = 1'b0;
            @(negedge clk); start = 1; @(negedge clk); start = 0;
            t = 0;
            while (nav_ready_w !== 1'b1 && t < 2000000) begin @(posedge clk); t = t + 1; end
            if (nav_ready_w !== 1'b1) begin
                $display("FAIL %0s: nav_ready never rose (st=%0d)", arm, dut.state);
                errors = errors + 1;
            end
            repeat (50) @(posedge clk);
        end
    endtask

    task expect_flags(input [127:0] arm, input exp_probed, input exp_ok,
                      input exp_bupvmg);
        begin
            if (vmgm_probed !== exp_probed || vmgm_title_ok !== exp_ok) begin
                $display("FAIL %0s: probed=%b ok=%b, want %b %b", arm,
                         vmgm_probed, vmgm_title_ok, exp_probed, exp_ok);
                errors = errors + 1;
            end
            if (ifo_bup_vmg !== exp_bupvmg || ifo_nogood !== 1'b0) begin
                $display("FAIL %0s: bup_vmg=%b nogood=%b, want %b 0", arm,
                         ifo_bup_vmg, ifo_nogood, exp_bupvmg);
                errors = errors + 1;
            end
            if (n_pgc_error !== 0) begin
                $display("FAIL %0s: %0d pgc_error pulses during the mount", arm, n_pgc_error);
                errors = errors + 1;
            end
            if (vm_mode && (ma_seen !== 1'b0 || wide_seen !== 1'b0)) begin
                $display("FAIL %0s: the probe touched live outputs (menu_active seen %b, "
                         , arm, ma_seen, "menu_ar_wide seen %b)", wide_seen);
                errors = errors + 1;
            end
            if (nav_early !== 1'b0) begin
                $display("FAIL %0s: nav_ready rose before the probe finished", arm);
                errors = errors + 1;
            end
            if (strm_early !== 1'b0) begin
                $display("FAIL %0s: the reader streamed before nav_ready", arm);
                errors = errors + 1;
            end
        end
    endtask

    task expect_stream(input [127:0] arm, input [7:0] want);
        integer t;
        begin
            t = 0;
            while (post_v !== 1'b1 && t < 2000000) begin @(posedge clk); t = t + 1; end
            if (post_v !== 1'b1) begin
                $display("FAIL %0s: nothing streamed", arm); errors = errors + 1;
            end else if (post_byte !== want) begin
                $display("FAIL %0s: streamed %02x, want %02x", arm, post_byte, want);
                errors = errors + 1;
            end
        end
    endtask

    task jump_title_menu;
        begin
            @(negedge clk);
            jump_domain = 2'd1; jump_entry = 4'd2; jump_pulse = 1;
            @(negedge clk); jump_pulse = 0;
        end
    endtask

    integer e0;
    initial begin
        repeat (5) @(negedge clk); rst_n = 1;
        file_size = IMG_BYTES;
        repeat (5) @(negedge clk);

        e0 = errors; mount("A", 0, 1); expect_flags("A", 1, 1, 0);
        jump_title_menu; expect_stream("A jump", 8'hC1);
        if (errors == e0) $display("A  entry 2 present -> ok, then the jump plays it  PASS");

        e0 = errors; mount("B", 1, 1); expect_flags("B", 1, 0, 0);
        if (errors == e0) $display("B  no entry 2 -> ok 0, no pgc_error  PASS");
        e0 = errors; jump_title_menu; expect_stream("G", 8'hC0);
        if (errors == e0) $display("G  a command jump to entry 2 still takes SRP[0]  PASS");

        e0 = errors; mount("C", 2, 1); expect_flags("C", 1, 0, 0);
        if (errors == e0) $display("C  no PGCI_UT -> ok 0, no pgc_error  PASS");

        e0 = errors; mount("C2", 7, 1); expect_flags("C2", 1, 0, 0);
        if (errors == e0) $display("C2 a bad PGCI_UT -> ok 0, no pgc_error  PASS");

        e0 = errors; mount("C3", 8, 1); expect_flags("C3", 1, 0, 0);
        if (errors == e0) $display("C3 an empty PGCIT -> ok 0, no pgc_error  PASS");

        e0 = errors; mount("D", 3, 1); expect_flags("D", 1, 0, 0);
        if (errors == e0) $display("D  entry 2 only in the fr unit -> ok 0  PASS");

        e0 = errors; mount("D2", 4, 1); expect_flags("D2", 1, 1, 0);
        if (errors == e0) $display("D2 entry 2 in the en unit -> ok 1  PASS");

        e0 = errors; mount("E", 0, 0); expect_flags("E", 0, 0, 0);
        expect_stream("E auto", 8'hB0);
        if (errors == e0) $display("E  Disc Menus off -> no probe, Auto plays  PASS");

        e0 = errors; mount("F", 5, 1); expect_flags("F", 1, 1, 1);
        if (errors == e0) $display("F  zeroed VMGI -> the probe reads the BUP  PASS");

        e0 = errors; mount("H", 6, 1); expect_flags("H", 1, 1, 0);
        if (errors == e0) $display("H  entry 2 with a malformed start -> ok 1  PASS");

        if (errors == 0) $display("ISO_READER_TITLEPROBE_TB: ALL TESTS PASSED");
        else             $fatal(1, "ISO_READER_TITLEPROBE_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin
        #400000000;
        $fatal(1, "GLOBAL TIMEOUT st=%0d", dut.state);
    end

endmodule
