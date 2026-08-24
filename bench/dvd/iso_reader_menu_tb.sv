// iso_reader_menu_tb.sv - Phase-2 disc-menu (menu domain + VM jump) test for
// dvd/dvd_iso_reader.sv.
//
// Builds a synthetic DVD-Video ISO with one title set (VTS_01), a VMGM menu
// and a VTSM menu, and drives the VM jump interface the way emu.sv's
// proto-nav glue will:
//
//   TEST 1  mount (Auto)        -> title cell timeline (0xB2 then 0xB0), as
//                                  iso_reader_pgc_tb (regression of the mount
//                                  path through the generalized PGCIT walk).
//   TEST 2  VTSM jump (Root)    -> entry PGC (0x83) has 0 CELLS and ends in
//                                  an unconditional LinkPGCN 2 (the MiB root
//                                  stub shape) -> the reader FOLLOWS it. PGCN 2
//                                  deliberately STRADDLES a sector boundary
//                                  (in-sector off 1916; hdr/palette/cells cross
//                                  into the next sector = the Matrix/T2 shape)
//                                  -> menu VOB cells 0xD0,0xD1 stream, the
//                                  MENU palette loads, then cell still=255
//                                  parks in S_STILL. Command bytes of both
//                                  PGCs arrive on cmd_we.
//   TEST 3  TT resume jump      -> domain TT, jump_cell=1: title cell 1 only
//                                  (0xB0), menu_active drops, use_jcell path.
//   TEST 4  VMGM jump (Title)   -> entry 0x82 PGCN 1 plays VIDEO_TS.VOB RBN 0
//                                  (0xC0); its PGC has still=0/next_pgcn=2 ->
//                                  the reader FOLLOWS next_pgcn (flush pulse)
//                                  into PGCN 2 (0xC1, cell still=255 -> still).
//   TEST 5  FP jump             -> First Play PGC (VMGI@132): commands stream
//                                  on cmd_we, NO video bytes, ends in S_DONE
//                                  with pgc_loaded.
//   TEST 6  VTSM jump to VTS 2  -> no such VTS -> pgc_error pulse, no stream.
//
// Layout (2048-byte logical sectors):
//   16 PVD          17 root dir       18 VIDEO_TS dir
//   19 VIDEO_TS.IFO sec0 = VMGI_MAT (fp_pgc@132=400 -> FP PGC in this sector;
//                                    vmgm_pgci_ut@200=1 -> sector 20)
//   20 VIDEO_TS.IFO sec1 = VMGM PGCI_UT (LU[0]@16 -> PGCIT: PGCN1 entry=0x82
//                                    1 cell {0,0} next_pgcn=2; PGCN2 1 cell
//                                    {1,1} still=255)
//   21 VTS_01_0.IFO sec0 = VTSI_MAT (vts_pgcit@204=1 -> 22; vtsm_pgci_ut@208=2 -> 23)
//   22 VTS_01_0.IFO sec1 = title VTS_PGCIT (PGCN1: 2 cells {2,2},{0,0} + palette)
//   23 VTS_01_0.IFO sec2 = VTSM PGCI_UT (LU[0]@16 -> PGCIT: PGCN1 entry=0x83
//                                    0 cells + LinkPGCN 2; PGCN2 @1900 =
//                                    STRADDLES into sec 24: 2 cells {0,0} st0,
//                                    {1,1} st255 + distinct palette)
//   24 VTS_01_0.IFO sec3 = straddle tail of menu PGCN2
//   25..27 VTS_01_1.VOB  = title VOB (0xB0,0xB1,0xB2)
//   28..29 VTS_01_0.VOB  = VTS menu VOB (0xD0,0xD1)
//   30..31 VIDEO_TS.VOB  = VMG menu VOB (0xC0,0xC1)

`timescale 1ns/1ps

module iso_reader_menu_tb;

    localparam IMG_BYTES = 32*2048;

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

    // jump interface
    reg         jump_pulse = 0;
    reg  [1:0]  jump_domain = 0;
    reg  [7:0]  jump_vts = 0;
    reg  [7:0]  jump_pgcn = 0;
    reg  [3:0]  jump_entry = 0;
    reg  [7:0]  jump_cell = 0;
    reg         vbuf_empty = 0;   // §5 menu still cold re-decode trigger (VBUF drained)
    reg         menu_snap = 0;    // §5c Snappy: cold re-decode the still immediately
    wire        jump_ack, pgc_loaded, pgc_error, menu_active, still_active;
    wire        keep_vbuf;
    wire [7:0]  cur_vts, best_menu_vts;

    wire        cmd_we;
    wire [10:0] cmd_waddr;
    wire [7:0]  cmd_wdata;
    wire [7:0]  cmd_nr_pre, cmd_nr_post, cmd_nr_cell;

    wire        seek_ack;
    wire        debug_iso_mode, debug_iso_error;
    wire [15:0] debug_state;

    reg  [7:0]  img [0:IMG_BYTES-1];

    // ---- stream capture ----
    integer cap_n = 0;
    reg [7:0] cap [0:65535];
    always @(posedge clk)
        if (stream_valid) begin
            cap[cap_n] = stream_data;
            cap_n = cap_n + 1;
        end

    // ---- palette capture ----
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

    // ---- command stream capture ----
    integer cmd_n = 0;
    reg [7:0] cmd_cap [0:2047];
    always @(posedge clk)
        if (cmd_we) begin
            cmd_cap[cmd_waddr] = cmd_wdata;
            cmd_n = cmd_n + 1;
        end

    // ---- event counters ----
    integer n_jump_ack = 0, n_pgc_loaded = 0, n_pgc_error = 0, n_seek_ack = 0;
    // keep_vbuf captured at each jump/seek pulse (Phase-5 menu-transition VBUF hold)
    reg     kv_last_jump = 1'bx, kv_last_seek = 1'bx;
    always @(posedge clk) begin
        if (jump_ack)   begin n_jump_ack   = n_jump_ack + 1; kv_last_jump <= keep_vbuf; end
        if (pgc_loaded) n_pgc_loaded = n_pgc_loaded + 1;
        if (pgc_error)  n_pgc_error  = n_pgc_error + 1;
        if (seek_ack)   begin n_seek_ack   = n_seek_ack + 1; kv_last_seek <= keep_vbuf; end
    end

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(4'd0),
        .vbuf_empty(vbuf_empty), .menu_snap(menu_snap),
        // Phase-4 DVD-VM ports: legacy mode (vm_mode=0 keeps prior behaviour)
        .jump_ttn(7'd0), .jump_pgn(8'd0), .jump_ptt(10'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_pulse(1'b0), .seek_natural(1'b0), .seek_cell(8'd0), .seek_ack(seek_ack),
        .cur_cell(), .cell_ready(),
        .jump_pulse(jump_pulse), .jump_natural(1'b0), .jump_domain(jump_domain), .jump_vts(jump_vts),
        .jump_pgcn(jump_pgcn), .jump_entry(jump_entry), .jump_cell(jump_cell),
        .jump_ack(jump_ack), .keep_vbuf(keep_vbuf), .pgc_loaded(pgc_loaded), .pgc_error(pgc_error),
        .menu_active(menu_active), .still_active(still_active), .cur_vts(cur_vts),
        .best_menu_vts(best_menu_vts),
        .cmd_we(cmd_we), .cmd_waddr(cmd_waddr), .cmd_wdata(cmd_wdata),
        .cmd_nr_pre(cmd_nr_pre), .cmd_nr_post(cmd_nr_post), .cmd_nr_cell(cmd_nr_cell),
        .cell_end_pulse(), .pgc_end_pulse(),
        .pgc_still_time(), .next_pgcn(), .prev_pgcn(), .goup_pgcn(),
        .cur_cell_still(), .cur_cell_cmdnr(),
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

    task be16(input integer a, input [15:0] v);
        begin img[a] = v[15:8]; img[a+1] = v[7:0]; end
    endtask
    task be32(input integer a, input [31:0] v);
        begin
            img[a]   = v[31:24]; img[a+1] = v[23:16];
            img[a+2] = v[15:8];  img[a+3] = v[7:0];
        end
    endtask

    // Write a PGC at absolute byte `pa`: nr_cells, next_pgcn, still_time,
    // palette base value (entry i = {00, pal+i, 80+i, 40+i}; pal=0 -> zeros),
    // command_tbl_offset (0 = none), cell_playback_offset.
    task put_pgc(input integer pa, input [7:0] ncells, input [15:0] nxt,
                 input [7:0] still, input [7:0] pal, input [15:0] cmd_off,
                 input [15:0] cpo);
        begin
            img[pa+2] = ncells;            // nr_of_programs (same for the test)
            img[pa+3] = ncells;
            be16(pa+156, nxt);             // next_pgc_nr
            be16(pa+158, 16'd0);           // prev
            be16(pa+160, 16'd0);           // goup
            img[pa+162] = 8'h00;           // pg_playback_mode
            img[pa+163] = still;           // still_time
            if (pal != 0)
                for (i = 0; i < 16; i = i + 1) begin
                    img[pa+164+i*4+0] = 8'h00;
                    img[pa+164+i*4+1] = pal + i[7:0];
                    img[pa+164+i*4+2] = 8'h80 + i[7:0];
                    img[pa+164+i*4+3] = 8'h40 + i[7:0];
                end
            be16(pa+228, cmd_off);
            be16(pa+230, 16'd0);           // program map (unused)
            be16(pa+232, cpo);
        end
    endtask

    // One cell entry (24 B) at PGC byte pa + cpo + idx*24.
    task put_cell(input integer pa, input [15:0] cpo, input integer idx,
                  input [7:0] still, input [7:0] cmdnr,
                  input [31:0] first, input [31:0] last);
        integer c;
        begin
            c = pa + cpo + idx*24;
            img[c+2] = still;
            img[c+3] = cmdnr;
            be32(c+8,  first);
            be32(c+20, last);
        end
    endtask

    // Command table at PGC byte pa + off: counts + pre commands from cmds[]
    // (each 64 bits, packed high-first).
    task put_cmdtbl2(input integer pa, input [15:0] off,
                     input [63:0] c0, input [63:0] c1, input integer npre);
        integer a;
        begin
            a = pa + off;
            be16(a+0, npre[15:0]);
            be16(a+2, 16'd0);
            be16(a+4, 16'd0);
            be16(a+6, 16'd0);
            for (i = 0; i < 8; i = i + 1) img[a+8+i]  = c0[8*(7-i) +: 8];
            if (npre > 1)
                for (i = 0; i < 8; i = i + 1) img[a+16+i] = c1[8*(7-i) +: 8];
        end
    endtask

    // PGCI_UT at sector `sec`: 1 LU -> PGCIT at UT+16 with nr_srp SRPs; the
    // SRP entry ids / starts are filled by the caller afterwards.
    task put_ut(input integer sec, input [15:0] nsrp);
        integer base;
        begin
            base = sec*2048;
            be16(base+0, 16'd1);           // nr_of_lus
            be32(base+4, 32'd1000);        // last_byte (loose)
            be16(base+8, 16'h656E);        // LU[0].lang "en"
            img[base+10] = 0; img[base+11] = 8'h80;
            be32(base+12, 32'd16);         // LU[0].lang_start_byte
            be16(base+16, nsrp);           // PGCIT.nr_of_pgci_srp
            be32(base+20, 32'd2000);       // PGCIT.last_byte (loose)
        end
    endtask

    task put_srp(input integer sec, input integer idx,
                 input [7:0] entry_id, input [31:0] pgc_start);
        integer a;
        begin
            a = sec*2048 + 16 + 8 + idx*8;
            img[a] = entry_id;
            be32(a+4, pgc_start);
        end
    endtask

    // build the whole disc image
    task build_iso;
        begin
            for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = 8'h00;

            // PVD @16
            img[32768] = 8'd1;
            img[32769] = "C"; img[32770] = "D"; img[32771] = "0";
            img[32772] = "0"; img[32773] = "1"; img[32774] = 8'd1;
            put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur);

            // root dir @17
            cur = 17*2048;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 18, 2048, 8'h02, "VIDEO_TS", 8, cur);

            // VIDEO_TS dir @18 (name-sorted)
            cur = 18*2048;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 19, 4096,  8'h00, "VIDEO_TS.IFO;1", 14, cur); // VMGI (2 sec)
            put_rec(cur, 30, 4096,  8'h00, "VIDEO_TS.VOB;1", 14, cur); // VMGM VOB (2 sec)
            put_rec(cur, 21, 8192,  8'h00, "VTS_01_0.IFO;1", 14, cur); // VTSI (4 sec)
            put_rec(cur, 28, 4096,  8'h00, "VTS_01_0.VOB;1", 14, cur); // VTSM VOB (2 sec)
            put_rec(cur, 25, 6144,  8'h00, "VTS_01_1.VOB;1", 14, cur); // title (3 sec)

            // VMGI_MAT @19: FP PGC @byte 400 (commands only), VMGM_PGCI_UT @200 = +1
            be32(19*2048+132, 32'd400);
            be32(19*2048+196, 32'd0);          // tt_srpt unused (Auto = largest)
            be32(19*2048+200, 32'd1);          // VMGM PGCI_UT -> sector 20
            // FP PGC: 0 cells, cmd tbl @236: pre = {g0=0, JumpTT 1}
            put_pgc(19*2048+400, 8'd0, 16'd0, 8'd0, 8'h00, 16'd236, 16'd0);
            put_cmdtbl2(19*2048+400, 16'd236,
                        64'h7100000000000000,   // g[0] = 0
                        64'h3002000000010000,   // JumpTT 1
                        2);

            // VMGM PGCI_UT @20: PGCN1 entry 0x82 (Title) @64: 1 cell {0,0}
            // still=0 next_pgcn=2 -> follows to PGCN2 @600: 1 cell {1,1} still=255
            put_ut(20, 16'd2);
            put_srp(20, 0, 8'h82, 32'd64);
            put_srp(20, 1, 8'h00, 32'd600);
            put_pgc(20*2048+16+64,  8'd1, 16'd2, 8'd0, 8'h00, 16'd0, 16'd300);
            put_cell(20*2048+16+64, 16'd300, 0, 8'd0, 8'd0, 32'd0, 32'd0);
            put_pgc(20*2048+16+600, 8'd1, 16'd0, 8'd0, 8'h00, 16'd0, 16'd300);
            put_cell(20*2048+16+600, 16'd300, 0, 8'd255, 8'd0, 32'd1, 32'd1);

            // VTSI_MAT @21: vts_pgcit=+1 (22), vtsm_pgci_ut=+2 (23)
            be32(21*2048+204, 32'd1);
            be32(21*2048+208, 32'd2);
            // VTSM_V_ATR @0x100 = 0x4D00 (mpeg2, NTSC, display aspect 16:9) so the
            // reader's menu aspect capture (S_MENU_VATR) sets menu_ar_wide=1.
            img[21*2048+16'h100] = 8'h4D;
            img[21*2048+16'h101] = 8'h00;

            // title VTS_PGCIT @22: 1 SRP, PGC @16: 2 cells {2,2},{0,0} + palette 0x10
            be16(22*2048+0, 16'd1);
            be32(22*2048+8+4, 32'd16);         // SRP[0].pgc_start_byte @+4
            put_pgc(22*2048+16, 8'd2, 16'd0, 8'd0, 8'h10, 16'd0, 16'd256);
            put_cell(22*2048+16, 16'd256, 0, 8'd0, 8'd0, 32'd2, 32'd2);
            put_cell(22*2048+16, 16'd256, 1, 8'd0, 8'd0, 32'd0, 32'd0);

            // VTSM PGCI_UT @23: PGCN1 entry 0x83 Root @64 = 0-cell stub with
            // pre = {conditional LinkPGCN 3, unconditional LinkPGCN 2};
            // PGCN2 @1900 (STRADDLES into sector 24): 2 cells + palette 0x20;
            // PGCN3 @700 (decoy, never followed).
            put_ut(23, 16'd3);
            put_srp(23, 0, 8'h83, 32'd64);
            put_srp(23, 1, 8'h00, 32'd1900);
            put_srp(23, 2, 8'h00, 32'd700);
            put_pgc(23*2048+16+64, 8'd0, 16'd0, 8'd0, 8'h00, 16'd236, 16'd0);
            put_cmdtbl2(23*2048+16+64, 16'd236,
                        64'h20A4000100010003,   // if (g1==1) LinkPGCN 3  (conditional)
                        64'h2004000000000002,   // LinkPGCN 2             (unconditional)
                        2);
            // PGCN3 = a MiB-style TRAMPOLINE stub: 0 cells, one JumpSS VMGM
            // pre-command, NO LinkPGCN -> nothing to follow -> pgc_error.
            put_pgc(23*2048+16+700, 8'd0, 16'd0, 8'd0, 8'h00, 16'd236, 16'd0);
            put_cmdtbl2(23*2048+16+700, 16'd236,
                        64'h3006000100C00000,   // JumpSS VMGM (pgc 1)
                        64'h0, 1);
            // the straddler: PGC byte base = 23*2048+16+1900 (in-sector off 1916)
            put_pgc(23*2048+16+1900, 8'd2, 16'd0, 8'd0, 8'h20, 16'd0, 16'd300);
            put_cell(23*2048+16+1900, 16'd300, 0, 8'd0,   8'd0, 32'd0, 32'd0);
            put_cell(23*2048+16+1900, 16'd300, 1, 8'd255, 8'd0, 32'd1, 32'd1);

            // payloads
            fill_sec(25, 8'hB0);   // title RBN 0
            fill_sec(26, 8'hB1);   // title RBN 1 (never referenced)
            fill_sec(27, 8'hB2);   // title RBN 2
            fill_sec(28, 8'hD0);   // VTS menu RBN 0
            fill_sec(29, 8'hD1);   // VTS menu RBN 1
            fill_sec(30, 8'hC0);   // VMG menu RBN 0
            fill_sec(31, 8'hC1);   // VMG menu RBN 1
        end
    endtask

    // ---- checks ----
    integer errors = 0;
    task chk(input cond, input [255:0] msg);
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("  ERR %0s", msg);
            end
        end
    endtask

    task expect_range(input integer base, input integer len, input [7:0] want);
        integer j;
        begin
            for (j = 0; j < len; j = j + 1)
                if (cap[base+j] !== want) begin
                    errors = errors + 1;
                    if (errors < 20)
                        $display("  MISMATCH @%0d: got %02x want %02x",
                                 base+j, cap[base+j], want);
                end
        end
    endtask

    task do_jump(input [1:0] d, input [7:0] v, input [7:0] p,
                 input [3:0] e, input [7:0] c);
        begin
            @(posedge clk);
            jump_domain <= d; jump_vts <= v; jump_pgcn <= p;
            jump_entry <= e;  jump_cell <= c;
            jump_pulse  <= 1'b1;
            @(posedge clk);
            jump_pulse  <= 1'b0;
        end
    endtask

    integer t;
    integer cap_mark;

    initial begin
        build_iso();
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // =============================================================
        // TEST 1 - mount: title plays cell0 (0xB2) then cell1 (0xB0)
        // =============================================================
        file_size = IMG_BYTES;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;
        t = 0;
        while (cap_n < 4096 && t < 4000000) begin @(posedge clk); t = t + 1; end
        repeat (400) @(posedge clk);
        $display("TEST1 mount: cap_n=%0d cell_mode=%b menu=%b cur_vts=%0d (expect 4096 1 0 1)",
                 cap_n, dut.cell_mode, menu_active, cur_vts);
        chk(cap_n == 4096, "T1 byte count");
        chk(dut.cell_mode === 1'b1, "T1 cell_mode");
        chk(menu_active === 1'b0, "T1 menu_active");
        chk(cur_vts == 8'd1, "T1 cur_vts");
        expect_range(0, 2048, 8'hB2);
        expect_range(2048, 2048, 8'hB0);
        chk(pal_writes == 16 && pal_cap[3] === 32'h0013_8343, "T1 title palette");
        chk(best_menu_vts == 8'd1, "T1 best_menu_vts (largest menu VOB = VTS_01)");

        // =============================================================
        // TEST 2 - VTSM Root jump: 0-cell stub -> LinkPGCN 2 (straddler)
        // =============================================================
        cap_mark = cap_n; pal_writes = 0; cmd_n = 0;
        do_jump(2'd2, 8'd1, 8'd0, 4'd3, 8'd0);
        t = 0;
        while (!still_active && t < 4000000) begin @(posedge clk); t = t + 1; end
        repeat (400) @(posedge clk);
        $display("TEST2 VTSM: bytes=%0d still=%b menu=%b pal=%0d cmds=%0d pgcn=%0d",
                 cap_n - cap_mark, still_active, menu_active, pal_writes,
                 cmd_n, dut.cur_pgcn);
        chk(still_active === 1'b1, "T2 still_active");
        chk(menu_active === 1'b1, "T2 menu_active");
        chk(cap_n - cap_mark == 4096, "T2 menu byte count (2 cells x 2048)");
        expect_range(cap_mark, 2048, 8'hD0);
        expect_range(cap_mark+2048, 2048, 8'hD1);
        chk(dut.cur_pgcn == 8'd2, "T2 followed LinkPGCN to PGCN 2");
        chk(dut.menu_ar_wide === 1'b1, "T2 menu aspect 16:9 from VTSM_V_ATR@0x100");
        // the STRADDLING menu PGC's palette must have loaded (walker crossing).
        // 32 writes = the root stub's palette (zeros) then the followed PGC's -
        // the last-loaded PGC's palette wins, which is the displayed menu's.
        chk(pal_writes == 32, "T2 menu palette streamed (stub + followed PGC)");
        chk(pal_cap[5] === 32'h0025_8545, "T2 menu palette value (0x20 base)");
        // root stub's 2 pre commands streamed (16 bytes) before the follow
        chk(cmd_cap[8] === 8'h20 && cmd_cap[15] === 8'h02, "T2 root cmd bytes");
        // Phase-5: this jump is title->menu -> keep_vbuf=0 (VBUF must flush so
        // the feature's ~1 s cushion doesn't play over the menu).
        chk(kv_last_jump === 1'b0, "T2 keep_vbuf=0 on title->menu jump");

        // =============================================================
        // TEST 3 - TT resume jump to cell 1: only 0xB0 streams
        // =============================================================
        cap_mark = cap_n;
        do_jump(2'd3, 8'd1, 8'd0, 4'd0, 8'd1);
        t = 0;
        while (cap_n < cap_mark + 2048 && t < 4000000) begin @(posedge clk); t = t + 1; end
        repeat (400) @(posedge clk);
        $display("TEST3 TT resume: bytes=%0d menu=%b state=%0d",
                 cap_n - cap_mark, menu_active, debug_state[5:0]);
        chk(cap_n - cap_mark == 2048, "T3 resume byte count (cell 1 only)");
        chk(menu_active === 1'b0, "T3 menu_active dropped");
        expect_range(cap_mark, 2048, 8'hB0);

        // =============================================================
        // TEST 4 - VMGM jump: PGCN1 (0xC0) -> next_pgcn=2 (0xC1) -> still
        // =============================================================
        cap_mark = cap_n;
        do_jump(2'd1, 8'd0, 8'd0, 4'd2, 8'd0);
        t = 0;
        while (!still_active && t < 4000000) begin @(posedge clk); t = t + 1; end
        repeat (400) @(posedge clk);
        $display("TEST4 VMGM: bytes=%0d still=%b menu=%b pgcn=%0d",
                 cap_n - cap_mark, still_active, menu_active, dut.cur_pgcn);
        chk(cap_n - cap_mark == 4096, "T4 byte count (PGC1 cell + PGC2 cell)");
        expect_range(cap_mark, 2048, 8'hC0);
        expect_range(cap_mark+2048, 2048, 8'hC1);
        chk(still_active === 1'b1, "T4 still");
        chk(dut.cur_pgcn == 8'd2, "T4 followed next_pgcn to PGCN 2");
        // Phase-5: the VMGM ENTRY jump is title->menu (keep_vbuf=0) but the
        // authored next_pgcn=2 ADVANCE is menu->menu -> the seek_ack that drives
        // it must hold the VBUF (keep_vbuf=1) so the PGC1->PGC2 transition tail
        // plays out instead of cold-restarting.
        chk(kv_last_jump === 1'b0, "T4 keep_vbuf=0 on title->menu VMGM jump");
        chk(kv_last_seek === 1'b1, "T4 keep_vbuf=1 on menu next_pgcn advance");

        // =============================================================
        // TEST 5 - FP jump: commands only, no video, pgc_loaded, S_DONE
        // =============================================================
        cap_mark = cap_n; cmd_n = 0;
        do_jump(2'd0, 8'd0, 8'd0, 4'd0, 8'd0);
        t = 0;
        while (debug_state[5:0] != 6'd11 && t < 4000000) begin @(posedge clk); t = t + 1; end
        repeat (100) @(posedge clk);
        $display("TEST5 FP: state=%0d bytes=%0d cmds=%0d nr_pre=%0d",
                 debug_state[5:0], cap_n - cap_mark, cmd_n, cmd_nr_pre);
        chk(debug_state[5:0] == 6'd11, "T5 landed in S_DONE");
        chk(cap_n - cap_mark == 0, "T5 no video bytes");
        chk(cmd_n == 16 && cmd_nr_pre == 8'd2, "T5 FP command stream (2 cmds)");
        chk(cmd_cap[8] === 8'h30 && cmd_cap[9] === 8'h02, "T5 FP JumpTT bytes");

        // =============================================================
        // TEST 6 - VTSM jump to a nonexistent VTS -> pgc_error
        // =============================================================
        cap_mark = cap_n; n_pgc_error = 0;
        do_jump(2'd2, 8'd2, 8'd0, 4'd3, 8'd0);
        t = 0;
        while (n_pgc_error == 0 && t < 400000) begin @(posedge clk); t = t + 1; end
        repeat (100) @(posedge clk);
        $display("TEST6 bad VTS: pgc_error=%0d bytes=%0d", n_pgc_error, cap_n - cap_mark);
        chk(n_pgc_error == 1, "T6 pgc_error pulsed");
        chk(cap_n - cap_mark == 0, "T6 no stream on a failed jump");

        // =============================================================
        // TEST 7 - VTSM jump straight at the TRAMPOLINE stub (PGCN 3: 0 cells,
        // JumpSS, no LinkPGCN = the MiB VTS_21 root shape) -> pgc_error and
        // NO stream (emu's fallback chain then tries best_menu_vts / VMGM).
        // =============================================================
        cap_mark = cap_n; n_pgc_error = 0;
        do_jump(2'd2, 8'd1, 8'd3, 4'd0, 8'd0);
        t = 0;
        while (n_pgc_error == 0 && t < 400000) begin @(posedge clk); t = t + 1; end
        repeat (100) @(posedge clk);
        $display("TEST7 trampoline stub: pgc_error=%0d bytes=%0d",
                 n_pgc_error, cap_n - cap_mark);
        chk(n_pgc_error == 1, "T7 pgc_error on a no-LinkPGCN stub");
        chk(cap_n - cap_mark == 0, "T7 no stream");

        // =============================================================
        // TEST 8 - Phase-5 menu->menu JUMP holds the VBUF. Land on a menu still
        // (VTSM Root -> follows to PGCN 2, parks), THEN jump VTSM again: this
        // second jump is menu->menu, so keep_vbuf must be 1 (the decoder plays
        // out its buffered transition tail rather than cold-restarting -> no
        // stale/frozen frame under the freshly-armed highlight).
        // =============================================================
        do_jump(2'd2, 8'd1, 8'd0, 4'd3, 8'd0);           // establish a menu still
        t = 0;
        while (!still_active && t < 4000000) begin @(posedge clk); t = t + 1; end
        repeat (200) @(posedge clk);
        chk(menu_active === 1'b1, "T8 in a menu before the second jump");
        do_jump(2'd2, 8'd1, 8'd0, 4'd3, 8'd0);           // menu -> menu jump (kv_last_jump = this)
        t = 0;
        while (!still_active && t < 4000000) begin @(posedge clk); t = t + 1; end
        repeat (200) @(posedge clk);
        $display("TEST8 menu->menu jump: keep_vbuf=%b still=%b", kv_last_jump, still_active);
        chk(kv_last_jump === 1'b1, "T8 keep_vbuf=1 on menu->menu jump");

        // =============================================================
        // TEST 9 - §5 MENU STILL COLD RE-DECODE. A menu still whose frame was decoded
        // mid-stream shows pixelated unless re-decoded cleanly, so on a still the reader
        // flushes + re-streams the still cell (a seek_ack with keep_vbuf=0), ONCE per
        // entry (still_flushed). Trigger = menu_snap (Snappy: immediate) OR vbuf_empty
        // (Smooth: after the transition drains). Land on the VTSM Root still (PGCN 2 cell
        // 1 = 0xD1), then:
        //   (a) menu_snap=0, vbuf_empty=0 -> stays parked, no flush, no re-stream.
        //   (b) vbuf_empty=1              -> one seek_ack keep_vbuf=0, 0xD1 re-streams.
        // =============================================================
        menu_snap = 1'b0; vbuf_empty = 1'b0;
        do_jump(2'd2, 8'd1, 8'd0, 4'd3, 8'd0);
        t = 0; while (still_active && t < 200000) begin @(posedge clk); t = t + 1; end
        t = 0; while (!still_active && t < 4000000) begin @(posedge clk); t = t + 1; end
        // (a) neither trigger armed: no cold re-decode
        cap_mark = cap_n; n_seek_ack = 0;
        repeat (2000) @(posedge clk);
        $display("TEST9a idle: bytes=%0d seek_acks=%0d still=%b",
                 cap_n - cap_mark, n_seek_ack, still_active);
        chk(still_active === 1'b1, "T9a stays parked while neither trigger is armed");
        chk(n_seek_ack == 0, "T9a no cold re-decode before vbuf_empty / menu_snap");
        chk(cap_n - cap_mark <= 2, "T9a no re-stream before the trigger (only pipeline drain)");
        // (b) vbuf_empty (Smooth) -> cold re-decode fires once
        cap_mark = cap_n; n_seek_ack = 0; kv_last_seek = 1'bx;
        vbuf_empty = 1'b1;
        t = 0; while (still_active && t < 200000) begin @(posedge clk); t = t + 1; end  // leaves S_STILL to re-decode
        t = 0; while (!still_active && t < 4000000) begin @(posedge clk); t = t + 1; end // re-parks
        repeat (400) @(posedge clk);
        $display("TEST9b vbuf_empty=1: bytes=%0d seek_acks=%0d kv_seek=%b still=%b",
                 cap_n - cap_mark, n_seek_ack, kv_last_seek, still_active);
        chk(n_seek_ack == 1, "T9b exactly one cold re-decode (still_flushed stops a loop)");
        chk(kv_last_seek === 1'b0, "T9b cold re-decode forces vbuf_flush (keep_vbuf=0)");
        chk(cap_n - cap_mark == 2048, "T9b re-streamed the still cell (2048 B of 0xD1)");
        expect_range(cap_mark, 2048, 8'hD1);
        chk(still_active === 1'b1, "T9b re-parked on the still after the cold re-decode");
        vbuf_empty = 1'b0;

        // (c) menu_snap (Snappy) fires the cold re-decode IMMEDIATELY (vbuf_empty stays 0).
        //     Park first with the triggers OFF (still_flushed re-armed by the fresh jump),
        //     THEN raise menu_snap - so the only seek_ack we count is the snap re-decode.
        //     Key behaviour: keep_vbuf=0 without waiting for vbuf_empty (re-park itself is
        //     covered by (b), identical code path).
        vbuf_empty = 1'b0; menu_snap = 1'b0;
        do_jump(2'd2, 8'd1, 8'd0, 4'd3, 8'd0);      // fresh entry re-arms still_flushed
        t = 0; while (!still_active && t < 4000000) begin @(posedge clk); t = t + 1; end
        repeat (50) @(posedge clk);
        n_seek_ack = 0;
        menu_snap = 1'b1;                            // now fire the snap
        t = 0; while (n_seek_ack == 0 && t < 4000000) begin @(posedge clk); t = t + 1; end
        $display("TEST9c menu_snap=1 (vbuf_empty=0): seek_acks=%0d", n_seek_ack);
        // keep_vbuf=0 on this re-decode is proven by (b) - identical S_STILL code path.
        chk(n_seek_ack >= 1, "T9c Snappy re-decodes the still immediately (no vbuf_empty)");
        menu_snap = 1'b0;

        // =============================================================
        if (errors == 0) $display("ISO_READER_MENU_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_MENU_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin
        #400000000;
        $display("ISO_READER_MENU_TB: TIMEOUT");
        $finish;
    end

endmodule
