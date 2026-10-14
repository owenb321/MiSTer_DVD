// ============================================================================
// bench/dvd/iso_reader_bup_tb.sv -- the IFO header gate and .BUP fallback
// (audit item 8; dvd/dvd_iso_reader.sv "IFO header gate", docs/dvd_nav.md)
// ============================================================================
// An IFO whose sector 0 lacks its "DVDVIDEO-VMG"/"DVDVIDEO-VTS" magic is re-read
// from its .BUP (libdvdnav ifoOpenVMGI/ifoOpenVTSI). The Main zero-fills a sector
// it cannot read, so "unreadable" reaches the fabric as zeros.
//
// Disc (sectors): 16 PVD, 17 root, 18 VIDEO_TS, then
//   VIDEO_TS.IFO 19..21   VIDEO_TS.BUP 30..32   (s0 MAT, s1 TT_SRPT, s2 VMGM UT)
//   VTS_01_0.IFO 22..25   VTS_01_0.BUP 40..43   (s0 MAT, s1 PGCIT, s2 VTSM UT,
//                                                s3 TMAPT)
//   VTS_02_0.IFO 26..27   (NO BUP)              (s0 MAT, s1 PGCIT)
//   VTS_01_1.VOB 50..89 (4 cells x 10, sector RBN r filled with byte r)
//   VTS_02_1.VOB 90..109 (2 cells x 10, byte 100+r)
// Every arm rebuilds the disc, damages it, and remounts. Scored on what the
// HPS was asked for (the per-LBA read counts), on what the reader then did
// (cell mode, landing bytes, the commands it streamed, the attribute counts)
// and on the three sticky flags. Never on the gate's own registers.
//
//   A  all good                       BUPs never read; flags 000
//   B  VTS_01 IFO zeroed, Auto        cells + attributes from the BUP; a time
//                                     seek reads the BUP's TMAPT; vts flag
//   C  VIDEO_TS.IFO zeroed, VM        FP, VMGM and JumpTT all resolve from the
//                                     BUP; the VMGI is gated ONCE (sticky); vmg
//   D  VTS_01 IFO zeroed, VTSM jump   menu UT read at BUP+ptr; its command runs
//   E  VTS_02 IFO zeroed (no BUP)     today's behaviour: linear, never a read of
//                                     another BUP or of LBA 0; nogood
//   F  VTS_01 IFO byte 11 wrong, BUP zeroed
//                                     revert: the IFO's own tables are parsed
//                                     (3 cells, the BUP's would be 4); nogood
//   G  VTS_01 IFO byte 10 wrong       swap (the full 12 bytes are compared)
//   H  VTS_01 IFO carries the VMG magic
//                                     swap (the kind is compared)
//   I  VM: TT jump to damaged VTS_01, to good VTS_02, back to VTS_01
//                                     the gate re-runs on every jump
// ============================================================================
`timescale 1ns/1ps

module iso_reader_bup_tb;

    localparam NSEC      = 112;
    localparam IMG_BYTES = NSEC*2048;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [63:0] file_size = 0;
    reg         vm_mode = 0;

    reg         jump_pulse = 0;
    reg  [1:0]  jump_domain = 0;
    reg  [7:0]  jump_vts = 0;
    reg  [15:0] jump_pgcn = 0;
    reg  [6:0]  jump_ttn = 0;
    wire        jump_ack, pgc_loaded, pgc_error, nav_ready_w;

    reg         seek_rbn_pulse = 0;
    reg  [31:0] seek_rbn = 0;
    reg         seek_tm_req = 0;
    reg  [16:0] seek_tm_secs = 0;
    wire        tmap_used, tmap_fell, seek_ack;

    wire        ifo_bup_vmg, ifo_bup_vts, ifo_nogood;

    wire        cmd_we;
    wire [11:0] cmd_waddr;
    wire [7:0]  cmd_wdata;

    wire [31:0] sd_lba;
    wire        sd_rd;
    reg         sd_ack = 0;
    reg  [13:0] sd_buff_addr = 0;
    reg  [7:0]  sd_buff_dout = 0;
    reg         sd_buff_wr = 0;
    wire [7:0]  stream_data;
    wire        stream_valid;
    reg         busy = 0;

    reg  [7:0]  img [0:IMG_BYTES-1];

    dvd_iso_reader #(.NAV_CAP(1)) dut (
        .cc_btns(1'b0),   // issue #176 hold off: a new input floats Z unless tied
        .cc_aud_low(1'b0), // issue #176 audio-low release off: tie the new input
        // new reader inputs tied off: a floating input is X (see the port comments)
        .agl_vm(4'd0), .agl_vm_en(1'b0), .vm_pre_done(1'b0),
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(7'd0),
        .aud_drained(1'b1), .vbuf_empty(1'b0),
        .jump_ttn(jump_ttn), .jump_pgn(8'd0), .jump_ptt(10'd0),
        .still_off(1'b0), .vm_mode(vm_mode), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(nav_ready_w),
        .auto_vts(), .cell_count_o(), .res_ttn(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_pulse(1'b0), .seek_natural(1'b0), .seek_cell(8'd0), .seek_ack(seek_ack),
        .seek_rbn_pulse(seek_rbn_pulse), .seek_rbn(seek_rbn),
        .seek_tm_req(seek_tm_req), .seek_tm_secs(seek_tm_secs),
        .tmap_used(tmap_used), .tmap_fell(tmap_fell),
        .ifo_bup_vmg(ifo_bup_vmg), .ifo_bup_vts(ifo_bup_vts), .ifo_nogood(ifo_nogood),
        .cur_cell(), .cell_ready(),
        .jump_pulse(jump_pulse), .jump_natural(1'b0), .jump_domain(jump_domain),
        .jump_vts(jump_vts), .jump_pgcn(jump_pgcn), .jump_entry(4'd0), .jump_cell(8'd0),
        .jump_ack(jump_ack), .pgc_loaded(pgc_loaded), .pgc_error(pgc_error),
        .menu_active(), .still_active(), .cur_vts(),
        .cur_pgcn_o(), .best_menu_vts(), .menu_btns_armed(1'b0),
        .cmd_we(cmd_we), .cmd_waddr(cmd_waddr), .cmd_wdata(cmd_wdata),
        .cmd_nr_pre(), .cmd_nr_post(), .cmd_nr_cell(),
        .next_pgcn(), .prev_pgcn(), .goup_pgcn(), .cur_cell_cmdnr(),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .pal_we(), .pal_waddr(), .pal_wdata(),
        .debug_active(), .debug_iso_mode()
    );

    always #5 clk = ~clk;

    // ---- mock HPS, counting every sector it is asked for ----
    integer m = 0, bc = 0, lat = 0;
    reg [31:0] rlba = 0;
    integer rd_cnt [0:NSEC-1];
    integer rd_oob = 0;                // reads past the image (a wild LBA)
    integer rd_lba0 = 0;               // reads of LBA 0 after nav_ready
    integer k;
    always @(posedge clk) begin
        sd_buff_wr <= 1'b0;
        case (m)
        0: begin
            sd_ack <= 1'b0;
            if (sd_rd) begin
                rlba <= sd_lba; lat <= 3; m <= 1;
                if (sd_lba < NSEC) rd_cnt[sd_lba] = rd_cnt[sd_lba] + 1;
                else               rd_oob = rd_oob + 1;
                if (sd_lba == 0 && nav_ready_w) rd_lba0 = rd_lba0 + 1;
            end
        end
        1: if (lat != 0) lat <= lat - 1; else begin sd_ack <= 1'b1; bc <= 0; m <= 2; end
        2: begin
            sd_ack <= 1'b1; sd_buff_wr <= 1'b1; sd_buff_addr <= bc[13:0];
            sd_buff_dout <= (rlba < NSEC) ? img[rlba*2048 + bc] : 8'h00;
            bc <= bc + 1; if (bc == 2047) m <= 3;
        end
        3: begin sd_ack <= 1'b0; sd_buff_wr <= 1'b0; m <= 0; end
        endcase
    end

    // ---- stream capture + streamed commands + verdict pulses ----
    integer cap_n = 0;
    reg [7:0] cap [0:4095];
    always @(posedge clk) if (stream_valid) begin
        if (cap_n < 4096) cap[cap_n] = stream_data;
        cap_n = cap_n + 1;
    end
    reg [7:0] cmd_cap [0:4095];
    always @(posedge clk) if (cmd_we) cmd_cap[cmd_waddr] = cmd_wdata;
    integer n_loaded = 0, n_error = 0;
    always @(posedge clk) begin
        if (pgc_loaded) n_loaded = n_loaded + 1;
        if (pgc_error)  n_error  = n_error + 1;
    end

    // ---- image builders ----
    integer i, cur;
    task put_rec(input integer off, input [31:0] ext, input [31:0] dlen,
                 input [7:0] flags, input [127:0] nm, input integer nlen,
                 output integer next_off);
        integer j; integer rl;
        begin
            rl = 33 + nlen; if (rl[0]) rl = rl + 1;
            img[off+0]=rl[7:0]; img[off+1]=0;
            img[off+2]=ext[7:0]; img[off+3]=ext[15:8];
            img[off+4]=ext[23:16]; img[off+5]=ext[31:24];
            for (j=6;j<10;j=j+1) img[off+j]=0;
            img[off+10]=dlen[7:0]; img[off+11]=dlen[15:8];
            img[off+12]=dlen[23:16]; img[off+13]=dlen[31:24];
            for (j=14;j<32;j=j+1) img[off+j]=0;
            img[off+25]=flags;
            img[off+32]=nlen[7:0];
            for (j=0;j<nlen;j=j+1) img[off+33+j]=nm[8*(nlen-1-j)+:8];
            if ((33+nlen)&1) img[off+33+nlen]=0;
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
            for (j=0;j<12;j=j+1) img[sec*2048+j] = s[8*(11-j)+:8];
        end
    endtask
    task fill_sec(input integer sec, input [7:0] v);
        integer j; begin for (j=0;j<2048;j=j+1) img[sec*2048+j] = v; end endtask
    task zero_secs(input integer sec, input integer n);
        integer j; begin for (j=0;j<n*2048;j=j+1) img[sec*2048+j] = 8'h00; end endtask
    task copy_secs(input integer dst, input integer src, input integer n);
        integer j; begin for (j=0;j<n*2048;j=j+1) img[dst*2048+j] = img[src*2048+j]; end endtask
    // one-command PGC (a pre command), ncells cells at cpo
    task put_pgc(input integer pa, input [7:0] ncells, input [15:0] cpo, input [63:0] c);
        integer j; begin
            img[pa+2]=ncells; img[pa+3]=ncells;
            be16(pa+228,16'd236); be16(pa+232,cpo);
            be16(pa+236,16'd1);                        // 1 pre command
            be16(pa+238,16'd0); be16(pa+240,16'd0); be16(pa+242,16'd15);
            for (j=0;j<8;j=j+1) img[pa+244+j]=c[8*(7-j)+:8];
        end
    endtask
    task put_cell(input integer pa, input [15:0] cpo, input integer idx,
                  input [31:0] fs, input [31:0] ls);
        integer c; begin
            c = pa + cpo + idx*24; be32(c+8, fs); be32(c+20, ls);
        end
    endtask
    // PGCIT (title) at sector `sec`: 1 SRP (entry 0x81 = title 1), the PGC at +16
    task put_pgcit(input integer sec, input [7:0] ncells, input integer vts);
        integer b, pa; begin
            b = sec*2048; be16(b+0,16'd1); be32(b+4,32'd1500);
            img[b+8] = 8'h81; be32(b+12, 32'd16);
            pa = b + 16;
            put_pgc(pa, ncells, 16'd300, 64'd0);
            img[pa+2]=8'd1;                             // 1 program
            be16(pa+228,16'd0);                         // no command table
            for (i=0;i<ncells;i=i+1)
                put_cell(pa, 16'd300, i, i*10, i*10+9);
        end
    endtask
    // a PGCI_UT (menu) at sector `sec`: one LU, PGCN1 = 0-cell command PGC
    task put_ut(input integer sec, input [63:0] c);
        integer b; begin
            b = sec*2048; be16(b+0,1); be32(b+4,1000);
            be16(b+8,16'h656E); img[b+10]=0; img[b+11]=8'h80;
            be32(b+12,16); be16(b+16,1); be32(b+20,1000);
            img[b+16+8]=8'h00; be32(b+16+8+4, 32'd64);
            put_pgc(b+16+64, 8'd0, 16'd0, c);
        end
    endtask

    localparam [63:0] CMD_FP   = 64'h7100000500110000;   // g5 = 0x11
    localparam [63:0] CMD_VMGM = 64'h7100000500420000;   // g5 = 0x42
    localparam [63:0] CMD_VTSM = 64'h7100000500330000;   // g5 = 0x33

    task build;
        begin
            for (i=0;i<IMG_BYTES;i=i+1) img[i]=0;
            for (i=0;i<NSEC;i=i+1) rd_cnt[i]=0;
            rd_oob = 0; rd_lba0 = 0;
            img[32768]=1; img[32769]="C"; img[32770]="D"; img[32771]="0";
            img[32772]="0"; img[32773]="1"; img[32774]=1;
            put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur);
            cur=17*2048;
            put_rec(cur,17,2048,8'h02,128'h00,1,cur);
            put_rec(cur,17,2048,8'h02,128'h01,1,cur);
            put_rec(cur,18,2048,8'h02,"VIDEO_TS",8,cur);
            cur=18*2048;                                      // ISO9660 sort order
            put_rec(cur,18,2048,8'h02,128'h00,1,cur);
            put_rec(cur,17,2048,8'h02,128'h01,1,cur);
            put_rec(cur,30,3*2048, 8'h00,"VIDEO_TS.BUP;1",14,cur);
            put_rec(cur,19,3*2048, 8'h00,"VIDEO_TS.IFO;1",14,cur);
            put_rec(cur,40,4*2048, 8'h00,"VTS_01_0.BUP;1",14,cur);
            put_rec(cur,22,4*2048, 8'h00,"VTS_01_0.IFO;1",14,cur);
            put_rec(cur,50,40*2048,8'h00,"VTS_01_1.VOB;1",14,cur);
            put_rec(cur,26,2*2048, 8'h00,"VTS_02_0.IFO;1",14,cur);
            put_rec(cur,90,20*2048,8'h00,"VTS_02_1.VOB;1",14,cur);

            // VMGI 19..21: FP PGC in sector 0 @1024; TT_SRPT s1; VMGM UT s2
            magic(19, 1);
            be32(19*2048+132, 32'd1024);
            be32(19*2048+196, 32'd1);
            be32(19*2048+200, 32'd2);
            put_pgc(19*2048+1024, 8'd0, 16'd0, CMD_FP);
            be16(20*2048+0, 16'd1);                           // TT_SRPT: 1 title
            be32(20*2048+4, 32'd19);
            img[20*2048+8]=8'h3C; img[20*2048+9]=8'd1; be16(20*2048+10,16'd1);
            img[20*2048+14]=8'd1; img[20*2048+15]=8'd1;      // title 1 -> VTS 1 ttn 1
            put_ut(21, CMD_VMGM);

            // VTS_01 IFO 22..25
            magic(22, 0);
            be32(22*2048+204, 32'd1);                         // PGCIT  s1
            be32(22*2048+208, 32'd2);                         // VTSM UT s2
            be32(22*2048+212, 32'd3);                         // TMAPT s3
            img[22*2048+515] = 8'd2;                          // 2 audio streams
            img[22*2048+597] = 8'd3;                          // 3 subpicture streams
            put_pgcit(23, 8'd4, 1);
            put_ut(24, CMD_VTSM);
            be16(25*2048+0, 16'd1); be32(25*2048+8, 32'd12);  // TMAPT: one map @12
            img[25*2048+12] = 8'd1; be16(25*2048+14, 16'd4);  // tmu 1 s, 4 entries
            be32(25*2048+16, 32'd10); be32(25*2048+20, 32'd20);
            be32(25*2048+24, 32'd30); be32(25*2048+28, 32'd35);

            // VTS_02 IFO 26..27 (no BUP)
            magic(26, 0);
            be32(26*2048+204, 32'd1);
            img[26*2048+515] = 8'd1;
            put_pgcit(27, 8'd2, 2);

            copy_secs(30, 19, 3);                              // the backups
            copy_secs(40, 22, 4);
            for (i=0;i<40;i=i+1) fill_sec(50+i, i[7:0]);
            for (i=0;i<20;i=i+1) fill_sec(90+i, 8'd100 + i[7:0]);
        end
    endtask

    // ---- drivers ----
    integer errors = 0, arm_err = 0;
    reg [8*8-1:0] arm;

    task fail(input [8*96-1:0] msg);
        begin
            $display("FAIL %0s: %0s", arm, msg);
            errors = errors + 1; arm_err = arm_err + 1;
        end
    endtask

    task wait_bytes(input integer n);
        integer tt; begin
            tt = 0;
            while (cap_n < n && tt < 4000000) begin @(posedge clk); tt = tt + 1; end
        end
    endtask

    task mount(input vm);
        integer tt; begin
            vm_mode = vm; file_size = IMG_BYTES; cap_n = 0;
            @(posedge clk); start = 1; @(posedge clk); start = 0;
            tt = 0;
            while (!nav_ready_w && tt < 2000000) begin @(posedge clk); tt = tt + 1; end
            if (!nav_ready_w) fail("mount: no nav_ready");
            repeat (20) @(posedge clk);
        end
    endtask

    // VM jump; waits for pgc_loaded / pgc_error, or a settled title stream
    task jump(input [1:0] dom, input [7:0] vts, input [15:0] pgcn, input [6:0] ttn);
        integer tt, v0; begin
            v0 = n_loaded + n_error; cap_n = 0;
            @(negedge clk); jump_domain = dom; jump_vts = vts; jump_pgcn = pgcn;
                            jump_ttn = ttn; jump_pulse = 1;
            @(negedge clk); jump_pulse = 0;
            // the old stream runs on until the jump executes: capture from its ack
            tt = 0;
            while (!jump_ack && tt < 3000000) begin @(posedge clk); tt = tt + 1; end
            if (!jump_ack) fail("jump never acknowledged");
            cap_n = 0;
            tt = 0;
            while (n_loaded + n_error == v0 && cap_n < 1024 && tt < 3000000) begin
                @(posedge clk); tt = tt + 1;
            end
            repeat (400) @(posedge clk);
        end
    endtask

    task tseek(input [16:0] secs, input [31:0] fb_rbn);
        integer tt; begin
            @(posedge clk); seek_rbn_pulse <= 1'b1; seek_rbn <= fb_rbn;
                            seek_tm_req <= 1'b1; seek_tm_secs <= secs;
            @(posedge clk); seek_rbn_pulse <= 1'b0; seek_tm_req <= 1'b0;
            tt = 0;
            while (!seek_ack && tt < 400000) begin @(posedge clk); tt = tt + 1; end
            tt = 0;
            while (dut.state != 6'd10 && tt < 2000000) begin @(posedge clk); tt = tt + 1; end
            repeat (50) @(posedge clk);
            cap_n = 0;
            wait_bytes(1024);
        end
    endtask

    function integer reads(input integer lo, input integer n);
        integer j, s; begin s = 0; for (j=lo;j<lo+n;j=j+1) s = s + rd_cnt[j]; reads = s; end
    endfunction

    task flags(input v, input t, input g);
        begin
            if (ifo_bup_vmg !== v || ifo_bup_vts !== t || ifo_nogood !== g) begin
                $display("FAIL %0s: flags vmg/vts/nogood = %b%b%b, want %b%b%b",
                         arm, ifo_bup_vmg, ifo_bup_vts, ifo_nogood, v, t, g);
                errors = errors + 1; arm_err = arm_err + 1;
            end
        end
    endtask

    // The first 1024 bytes after the landing must all be `want`. A jump's flush
    // races the capture by a few bytes, so the landing may start up to 63 bytes
    // in; anything else is a wrong landing.
    task landed(input [7:0] want);
        integer mm, h; begin
            wait_bytes(1088); mm = 0; h = 0;
            while (h < 64 && cap[h] !== want) h = h + 1;
            for (k=h;k<h+1024 && k<cap_n;k=k+1) if (cap[k] !== want) mm = mm + 1;
            if (cap_n < h+1024 || h == 64 || mm != 0) begin
                $display("FAIL %0s: stream byte %0d (%0d/1024 off), want %0d", arm, cap[0], mm, want);
                errors = errors + 1; arm_err = arm_err + 1;
            end
        end
    endtask

    // per-arm state: the verdict counters and the command capture start clean,
    // or one arm's pgc_error / streamed command would be scored in the next
    task begin_arm(input [8*8-1:0] a);
        begin
            arm = a; arm_err = 0; build;
            n_loaded = 0; n_error = 0;
            for (k=0;k<4096;k=k+1) cmd_cap[k] = 8'h00;
        end
    endtask
    task end_arm(input [8*80-1:0] what);
        begin
            if (rd_oob != 0) fail("a read past the image (wild LBA)");
            if (arm_err == 0) $display("ok %0s: %0s  PASS", arm, what);
        end
    endtask

    // ---- the arms ----
    initial begin
        repeat (4) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);

        // A -- all good: the BUPs are never read, nothing flags
        begin_arm("A");
        mount(0);
        landed(8'd0);
        if (dut.cell_mode !== 1'b1) fail("not in cell mode");
        if (dut.audio_ntracks !== 4'd2 || dut.subp_ntracks !== 6'd3) fail("attributes");
        tseek(17'd2, 32'd7);
        landed(8'd20);
        if (reads(30,3) + reads(40,4) != 0) fail("a BUP was read on a good disc");
        flags(0,0,0);
        end_arm("good disc never touches a BUP");

        // B -- VTS_01 IFO zeroed (Auto): everything comes from the BUP
        begin_arm("B");
        zero_secs(22, 4);
        mount(0);
        landed(8'd0);
        if (dut.cell_mode !== 1'b1) fail("not in cell mode (BUP tables unused)");
        if (dut.audio_ntracks !== 4'd2 || dut.subp_ntracks !== 6'd3) fail("attributes not from the BUP");
        tseek(17'd2, 32'd7);
        landed(8'd20);
        if (tmap_used !== 1'b1) fail("time seek did not use the BUP's map");
        if (reads(22,1) != 1) fail("VTSI sector 0 not read exactly once");
        if (reads(23,3) != 0) fail("a zeroed IFO table sector was read after the swap");
        if (reads(41,3) == 0) fail("the BUP's tables were never read");
        flags(0,1,0);
        end_arm("zeroed VTSI -> cells, attributes and TMAP from VTS_01_0.BUP");

        // C -- VIDEO_TS.IFO zeroed (VM): FP, VMGM, JumpTT from the BUP, gated once
        begin_arm("C");
        zero_secs(19, 3);
        mount(1);
        jump(2'd0, 8'd0, 8'd0, 7'd0);                       // First Play
        if (n_error != 0) fail("First Play pgc_error");
        if (cmd_cap[5] !== 8'h11) fail("FP command not streamed from the BUP");
        jump(2'd1, 8'd0, 8'd1, 7'd0);                       // VMGM PGCN 1
        if (n_error != 0) fail("VMGM pgc_error");
        if (cmd_cap[5] !== 8'h42) fail("VMGM command not streamed from the BUP");
        jump(2'd3, 8'd0, 8'd0, 7'd1);                       // JumpTT title 1
        landed(8'd0);
        if (dut.cell_mode !== 1'b1) fail("JumpTT did not reach VTS_01 cell mode");
        if (reads(19,3) != 1) fail("VIDEO_TS.IFO read more than once (swap not sticky)");
        if (reads(30,3) < 3) fail("VIDEO_TS.BUP not used for FP+VMGM+TT_SRPT");
        flags(1,0,0);
        end_arm("zeroed VMGI -> First Play, VMGM and JumpTT through VIDEO_TS.BUP");

        // D -- VTS_01 IFO zeroed, VTSM jump: the UT is read at BUP+ptr
        begin_arm("D");
        zero_secs(22, 4);
        mount(1);
        jump(2'd2, 8'd1, 8'd1, 7'd0);                       // VTSM vts 1 pgcn 1
        if (n_error != 0) fail("VTSM jump pgc_error");
        if (cmd_cap[5] !== 8'h33) fail("VTSM command not streamed from the BUP");
        if (reads(42,1) == 0) fail("VTSM UT not read from the BUP");
        if (reads(24,1) != 0) fail("VTSM UT read from the zeroed IFO");
        flags(0,1,0);
        end_arm("zeroed VTSI -> VTSM menu through VTS_01_0.BUP");

        // E -- VTS_02 IFO zeroed and it has NO BUP: exactly today's behaviour
        begin_arm("E");
        zero_secs(26, 2);
        mount(1);
        jump(2'd3, 8'd2, 8'd1, 7'd0);                       // TT vts 2 pgcn 1
        landed(8'd100);                                     // linear from its VOB
        if (dut.cell_mode !== 1'b0) fail("cell mode from a zeroed IFO?");
        if (reads(30,3) + reads(40,4) != 0) fail("another set's BUP was read");
        if (rd_lba0 != 0) fail("LBA 0 read as a 'BUP'");
        if (reads(26,1) == 0) fail("VTSI sector 0 never read");
        flags(0,0,1);
        end_arm("zeroed VTSI with no BUP -> linear, as before; nogood");

        // F -- IFO byte 11 wrong (tables fine, 3 cells), BUP zeroed: revert
        begin_arm("F");
        put_pgcit(23, 8'd3, 1);                             // IFO: 3 cells
        copy_secs(40, 22, 4);                               // (the BUP said 4) ...
        zero_secs(40, 4);                                   // ... and is destroyed
        img[22*2048+11] = "X";
        mount(0);
        landed(8'd0);
        if (dut.cell_mode !== 1'b1) fail("revert did not parse the IFO's tables");
        if (dut.cell_count !== 8'd3) fail("cell count is not the IFO's (3)");
        if (reads(22,1) < 2) fail("IFO sector 0 not re-read after the bad BUP");
        if (reads(40,1) != 1) fail("BUP sector 0 not tried exactly once");
        flags(0,0,1);
        end_arm("bad IFO magic + bad BUP -> the IFO is parsed as before; nogood");

        // G -- only byte 10 wrong: still a swap (all 12 bytes compared)
        begin_arm("G");
        img[22*2048+10] = "X";
        mount(0);
        landed(8'd0);
        if (reads(41,1) == 0) fail("BUP tables not used");
        flags(0,1,0);
        end_arm("one wrong magic byte (10) -> swap");

        // H -- a VTS IFO carrying the VMG magic: the kind is part of the check
        begin_arm("H");
        magic(22, 1);
        mount(0);
        landed(8'd0);
        if (reads(41,1) == 0) fail("BUP tables not used");
        flags(0,1,0);
        end_arm("VTSI with the VMG magic -> swap");

        // I -- VM: the gate re-runs on every jump to the damaged VTS
        begin_arm("I");
        zero_secs(22, 4);
        mount(1);
        jump(2'd3, 8'd1, 8'd1, 7'd0); landed(8'd0);
        jump(2'd3, 8'd2, 8'd1, 7'd0); landed(8'd100);
        jump(2'd3, 8'd1, 8'd1, 7'd0); landed(8'd0);
        if (dut.cell_mode !== 1'b1) fail("not in cell mode after the return");
        if (reads(22,1) != 2) fail("damaged VTSI sector 0 not gated on each jump");
        if (reads(40,1) < 2) fail("BUP sector 0 not re-read on each jump");
        if (reads(23,3) != 0) fail("a zeroed IFO table sector was read");
        flags(0,1,0);
        end_arm("jump damaged -> good -> damaged: swap each time");

        if (errors == 0) begin
            $display("ISO_READER_BUP_TB: ALL TESTS PASSED");
            $finish;
        end
        $fatal(1, "ISO_READER_BUP_TB: FAILED with %0d errors", errors);
    end

    initial begin #400000000; $fatal(1, "GLOBAL TIMEOUT arm=%0s st=%0d", arm, dut.state); end

endmodule
