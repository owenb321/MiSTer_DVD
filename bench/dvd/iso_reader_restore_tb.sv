// iso_reader_restore_tb.sv -- a save-state restore's title jump must land where the state was
// (2026-10-31, Mad Dog's hideout shootout: a load always started the scene again).
//
// The restore (dvd_vm E_RST) jumps to the saved PGC and cell with jump_ttn = VTS_TTN and the
// hint flag, so SPRM5 comes back and the title keeps its chapter map (jump_ttn_hint,
// docs/nav_engine.md 9). The hint was meant to leave want_pgcn alone, but the PTT resolve it
// triggers (S_PTT_MAT/OFF/PGC) read title 1's FIRST part {pgcn, pgn} and overwrote both:
// want_pgcn := that part's PGC, jpgn_l := its start program, and P_PMAP then replaced the
// saved start cell with the program's entry cell. Right only when the saved state was in the
// title's entry PGC at its first program; a state in PGC 2+ (or a later cell) restored to the
// wrong place.
//
// Image: the LinkPTT bench's title (VTS_PTT_SRPT part 1 -> PGC 1) with PGC 1 = one cell (0xB0)
// and PGC 2 = two cells (0xB2, then 0xB3), 2 programs. Driven straight at the reader:
//   A  hinted jump, PGC 2 cell 1  -> streams 0xB3, cur_pgcn 2      (the bug: 0xB0 / PGC 1)
//   B  hinted jump, PGC 2 cell 0  -> streams 0xB2, cur_pgcn 2      (the bug: 0xB0 / PGC 1)
//   C  hinted jump, PGC 1 cell 0  -> streams 0xB0, cur_pgcn 1      (the control: unchanged)
//   D  UNHINTED jump, ttn 1 ptt 3  -> PGC 2 program 1 (0xB2): a real chapter resolve still works
`timescale 1ns/1ps

module iso_reader_restore_tb;

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

    reg  [7:0]  img [0:IMG_BYTES-1];

    wire        jump_ack, pgc_loaded, pgc_error, menu_active, still_active;
    wire        seek_ack;
    wire [7:0]  cur_vts, best_menu_vts, cur_pgcn_rd, cur_cell, cell_count_w;
    wire [7:0]  auto_vts_w, cur_cell_cmdnr_w;
    wire        cell_ready, nav_ready_w;
    wire [6:0]  res_ttn_w;
    wire [7:0]  rd_next, rd_prev, rd_goup;
    wire        vm_cell_cmd_w, vm_pgc_end_w;
    wire        cmd_we_w, pm_we_w;
    wire [11:0] cmd_waddr_w;
    wire [7:0]  cmd_wdata_w, nr_pre_w, nr_post_w, nr_cell_w, nr_pgm_w;
    wire [6:0]  pm_waddr_w;
    wire [7:0]  pm_wdata_w;

    reg         j_pulse = 0, j_hint = 0;
    reg  [1:0]  j_dom = 2'd3;
    reg  [7:0]  j_vts = 0, j_pgcn = 0, j_cell = 0, j_pgn = 0;
    reg  [9:0]  j_ptt = 0;
    reg  [3:0]  j_entry = 0;
    reg  [6:0]  j_ttn = 0;

    // SPRM7: the reader's part of the playing cell -> the VM (as emu.sv wires it)
    wire        ptt_upd_w;
    wire [10:0] ptt_cur_w;
    dvd_iso_reader dut (
        .cc_btns(1'b0),   // issue #176 hold off: a new input floats Z unless tied
        .ptt_upd(ptt_upd_w), .ptt_cur(ptt_cur_w),
        // new reader inputs tied off: a floating input is X, and X on
        // agl_vm_en would poison the angle resolve (see the port comments).
        .agl_vm(4'd0), .agl_vm_en(1'b0), .vm_pre_done(1'b0),
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(4'd0), .aud_drained(1'b1), .vbuf_empty(1'b1),    // always-drained: tail-drain wait bypassed (bit-exact pre-drain timing)
        .jump_ttn(j_ttn), .jump_pgn(j_pgn), .jump_ptt(j_ptt),
        .still_off(1'b0), .vm_mode(1'b1), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(vm_cell_cmd_w), .vm_pgc_end(vm_pgc_end_w),
        .nav_ready_o(nav_ready_w), .auto_vts(auto_vts_w),
        .cell_count_o(cell_count_w), .res_ttn(res_ttn_w),
        .pm_we(pm_we_w), .pm_waddr(pm_waddr_w), .pm_wdata(pm_wdata_w),
        .cmd_nr_pgm(nr_pgm_w),
        .seek_pulse(1'b0), .seek_natural(1'b0), .seek_cell(8'd0), .seek_ack(seek_ack),
        .cur_cell(cur_cell), .cell_ready(cell_ready),
        .jump_pulse(j_pulse), .jump_natural(1'b0), .jump_ttn_hint(j_hint), .jump_domain(j_dom),
        .jump_vts(j_vts), .jump_pgcn(j_pgcn),
        .jump_entry(j_entry), .jump_cell(j_cell),
        .jump_ack(jump_ack), .pgc_loaded(pgc_loaded), .pgc_error(pgc_error),
        .menu_active(menu_active), .still_active(still_active), .cur_vts(cur_vts),
        .cur_pgcn_o(cur_pgcn_rd),
        .best_menu_vts(best_menu_vts),
        .menu_btns_armed(1'b0),
        .cmd_we(cmd_we_w), .cmd_waddr(cmd_waddr_w), .cmd_wdata(cmd_wdata_w),
        .cmd_nr_pre(nr_pre_w), .cmd_nr_post(nr_post_w), .cmd_nr_cell(nr_cell_w),
         .next_pgcn(rd_next), .prev_pgcn(rd_prev),
        .goup_pgcn(rd_goup),
         .cur_cell_cmdnr(cur_cell_cmdnr_w),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .pal_we(), .pal_waddr(), .pal_wdata(),
        .debug_active(),   
         .debug_iso_mode() 
    );


    always #5 clk = ~clk;

    integer cap_n = 0;
    reg [7:0] cap [0:131071];
    always @(posedge clk) if (stream_valid) begin cap[cap_n] = stream_data; cap_n = cap_n + 1; end

    integer m = 0, bc = 0, lat = 0;
    reg [31:0] rlba = 0;
    always @(posedge clk) begin
        sd_buff_wr <= 1'b0;
        case (m)
        0: begin sd_ack <= 1'b0; if (sd_rd) begin rlba <= sd_lba; lat <= 3; m <= 1; end end
        1: begin if (lat != 0) lat <= lat - 1; else begin sd_ack <= 1'b1; bc <= 0; m <= 2; end end
        2: begin sd_ack <= 1'b1; sd_buff_wr <= 1'b1; sd_buff_addr <= bc[13:0];
                 sd_buff_dout <= img[rlba*2048 + bc]; bc <= bc + 1; if (bc == 2047) m <= 3; end
        3: begin sd_ack <= 1'b0; sd_buff_wr <= 1'b0; m <= 0; end
        endcase
    end

    integer i, cur, errors = 0;

    task put_rec(input integer off, input [31:0] ext, input [31:0] dlen, input [7:0] flags,
                 input [127:0] nm, input integer nlen, output integer next_off);
        integer j, rl; begin
            rl = 33 + nlen; if (rl[0]) rl = rl + 1;
            img[off+0]=rl[7:0]; img[off+1]=0;
            img[off+2]=ext[7:0]; img[off+3]=ext[15:8]; img[off+4]=ext[23:16]; img[off+5]=ext[31:24];
            for (j=6;j<10;j=j+1) img[off+j]=0;
            img[off+10]=dlen[7:0]; img[off+11]=dlen[15:8]; img[off+12]=dlen[23:16]; img[off+13]=dlen[31:24];
            for (j=14;j<25;j=j+1) img[off+j]=0;
            img[off+25]=flags; img[off+26]=0; img[off+27]=0;
            for (j=28;j<32;j=j+1) img[off+j]=0;
            img[off+32]=nlen[7:0];
            for (j=0;j<nlen;j=j+1) img[off+33+j]=nm[8*(nlen-1-j)+:8];
            if ((33+nlen)&1) img[off+33+nlen]=0;
            next_off = off + rl;
        end
    endtask
    task be16(input integer a, input [15:0] v); begin img[a]=v[15:8]; img[a+1]=v[7:0]; end endtask
    task be32(input integer a, input [31:0] v); begin img[a]=v[31:24]; img[a+1]=v[23:16]; img[a+2]=v[15:8]; img[a+3]=v[7:0]; end endtask
    task put_pgc(input integer pa, input [7:0] npgms, input [7:0] ncells, input [15:0] nxt,
                 input [7:0] still, input [15:0] cmd_off, input [15:0] pm_off, input [15:0] cpo);
        begin
            img[pa+2]=npgms; img[pa+3]=ncells;
            be16(pa+156,nxt); be16(pa+158,16'd0); be16(pa+160,16'd0);
            img[pa+162]=8'h00; img[pa+163]=still;
            be16(pa+228,cmd_off); be16(pa+230,pm_off); be16(pa+232,cpo);
        end
    endtask
    task put_cell(input integer pa, input [15:0] cpo, input integer idx, input [7:0] still,
                  input [7:0] cmdnr, input [31:0] first, input [31:0] last);
        integer c; begin c=pa+cpo+idx*24; img[c+2]=still; img[c+3]=cmdnr; be32(c+8,first); be32(c+20,last); end
    endtask
    task put_cmdtbl(input integer pa, input [15:0] off, input integer npre, input integer npost,
                    input integer ncell, input [63:0] c0, input [63:0] c1, input [63:0] c2);
        integer a, n; begin
            a=pa+off; be16(a+0,npre[15:0]); be16(a+2,npost[15:0]); be16(a+4,ncell[15:0]); be16(a+6,16'd0);
            n=npre+npost+ncell;
            for (i=0;i<8;i=i+1) img[a+8+i]=c0[8*(7-i)+:8];
            if (n>1) for (i=0;i<8;i=i+1) img[a+16+i]=c1[8*(7-i)+:8];
            if (n>2) for (i=0;i<8;i=i+1) img[a+24+i]=c2[8*(7-i)+:8];
        end
    endtask


    task build_iso;
        integer j;
        begin
            for (i=0;i<IMG_BYTES;i=i+1) img[i]=8'h00;
            img[32768]=8'd1; img[32769]="C"; img[32770]="D"; img[32771]="0"; img[32772]="0"; img[32773]="1"; img[32774]=8'd1;
            put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur);
            cur=17*2048;
            put_rec(cur,17,2048,8'h02,128'h00,1,cur); put_rec(cur,17,2048,8'h02,128'h01,1,cur);
            put_rec(cur,18,2048,8'h02,"VIDEO_TS",8,cur);
            cur=18*2048;
            put_rec(cur,17,2048,8'h02,128'h00,1,cur); put_rec(cur,17,2048,8'h02,128'h01,1,cur);
            put_rec(cur,19,4096,8'h00,"VIDEO_TS.IFO;1",14,cur);   // 19..20
            put_rec(cur,22,6144,8'h00,"VTS_01_0.IFO;1",14,cur);   // 22..24
            put_rec(cur,27,6144,8'h00,"VTS_01_1.VOB;1",14,cur);   // title 27..29

            // VMGI_MAT @19: FP@400; TT_SRPT@+1 (20)
            be32(19*2048+132,32'd400); be32(19*2048+196,32'd1);
            put_pgc(19*2048+400,8'd0,8'd0,16'd0,8'd0,16'd236,16'd0,16'd0);
            put_cmdtbl(19*2048+400,16'd236,1,0,0,64'h3002000000010000,64'd0,64'd0); // JumpTT 1
            be16(20*2048+0,16'd1); img[20*2048+14]=8'd1; img[20*2048+15]=8'd1;

            // VTSI_MAT @22: vts_ptt_srpt=+1 (23), vts_pgcit=+2 (24)
            be32(22*2048+200,32'd1); be32(22*2048+204,32'd2);

            // VTS_PTT_SRPT @23: 1 title, 3 PTTs: part1 -> {pgc1,pg1}, part2 -> {pgc1,pg1},
            // part3 -> {pgc2,pg1}. The restore's hint reads part 1 = PGC 1 program 1.
            be16(23*2048+0,16'd1); be32(23*2048+4,32'd111); be32(23*2048+8,32'd100);
            be16(23*2048+100,16'd1); be16(23*2048+102,16'd1);
            be16(23*2048+104,16'd1); be16(23*2048+106,16'd1);
            be16(23*2048+108,16'd2); be16(23*2048+110,16'd1);

            // VTS_PGCIT @24: SRP[0] entry 0x81 (title 1) -> PGC1@32, SRP[1] entry 0x01 -> PGC2@640
            be16(24*2048+0,16'd2);
            img[24*2048+8]=8'h81;  be32(24*2048+8+4, 32'd32);
            img[24*2048+16]=8'h01; be32(24*2048+16+4, 32'd640);
            // PGC1: 1 program, 1 cell (0xB0 @27)
            put_pgc(24*2048+32, 8'd1, 8'd1, 16'd0, 8'd0, 16'd320, 16'd240, 16'd256);
            img[24*2048+32+240]=8'd1;
            put_cell(24*2048+32, 16'd256, 0, 8'd0, 8'd0, 32'd0, 32'd0);
            // PGC2: 2 programs, 2 cells (0xB2 @28, then 0xB3 @29), no commands
            put_pgc(24*2048+640, 8'd2, 8'd2, 16'd0, 8'd0, 16'd320, 16'd240, 16'd256);
            img[24*2048+640+240]=8'd1; img[24*2048+640+241]=8'd2;
            put_cell(24*2048+640, 16'd256, 0, 8'd0, 8'd0, 32'd1, 32'd1);
            put_cell(24*2048+640, 16'd256, 1, 8'd0, 8'd0, 32'd2, 32'd2);

            for (j=0;j<2048;j=j+1) begin img[27*2048+j]=8'hB0; img[28*2048+j]=8'hB2; img[29*2048+j]=8'hB3; end
        end
    endtask

    task fail(input [511:0] msg); begin $display("FAIL: %0s", msg); errors=errors+1; end endtask

    // one jump, then what streams first and which PGC is playing
    task jump_and_check(input [127:0] arm, input hint, input [6:0] ttn, input [9:0] ptt,
                        input [7:0] pgcn, input [7:0] scell, input [7:0] want_byte,
                        input [7:0] want_pgcn);
        integer mark, t, idle; begin
            // the previous arm's PGC may still be streaming its later cells: let it finish
            idle = 0;
            while (idle < 3000) begin @(posedge clk); if (stream_valid) idle = 0; else idle = idle + 1; end
            mark = cap_n;
            @(negedge clk);
            j_dom = 2'd3; j_vts = 8'd1; j_pgcn = pgcn; j_cell = scell; j_ttn = ttn; j_ptt = ptt;
            j_hint = hint; j_pulse = 1'b1;
            @(negedge clk); j_pulse = 1'b0;
            t = 0;
            while (cap_n < mark + 2048 && t < 4000000) begin @(posedge clk); t = t + 1; end
            repeat (200) @(posedge clk);
            $display("  %0s: first byte %02x, cur_pgcn %0d (want %02x, PGC %0d)", arm,
                     cap[mark], cur_pgcn_rd, want_byte, want_pgcn);
            if (cap_n < mark + 2048) fail("jump streamed nothing");
            else begin
                if (cap[mark] !== want_byte) $display("FAIL %0s: first byte %02x, want %02x", arm, cap[mark], want_byte);
                if (cap[mark] !== want_byte) errors = errors + 1;
                if (cur_pgcn_rd !== want_pgcn) $display("FAIL %0s: cur_pgcn %0d, want %0d", arm, cur_pgcn_rd, want_pgcn);
                if (cur_pgcn_rd !== want_pgcn) errors = errors + 1;
            end
        end
    endtask

    integer tw;
    initial begin
        build_iso; file_size=IMG_BYTES;
        repeat (5) @(negedge clk); rst_n=1;
        repeat (5) @(negedge clk); start=1; @(negedge clk); start=0;
        tw = 0; while (nav_ready_w !== 1'b1 && tw < 4000000) begin @(posedge clk); tw = tw + 1; end
        if (nav_ready_w !== 1'b1) fail("nav_ready never rose");
        repeat (100) @(posedge clk);
        // A/B: the restore's shape (TTN hint, exact PGCN, saved cell)
        jump_and_check("A hint PGC2 c1  ", 1'b1, 7'd1, 10'd0, 8'd2, 8'd1, 8'hB3, 8'd2);
        jump_and_check("B hint PGC2 c0  ", 1'b1, 7'd1, 10'd0, 8'd2, 8'd0, 8'hB2, 8'd2);
        // C: the control, the title's entry PGC
        jump_and_check("C hint PGC1 c0  ", 1'b1, 7'd1, 10'd0, 8'd1, 8'd0, 8'hB0, 8'd1);
        // D: a real chapter resolve (no hint) still takes the PTT table's part
        jump_and_check("D chapter 3     ", 1'b0, 7'd1, 10'd3, 8'd0, 8'd0, 8'hB2, 8'd2);
        if (errors==0) $display("ISO_READER_RESTORE_TB: ALL TESTS PASSED");
        else           $fatal(1, "ISO_READER_RESTORE_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin
        #400000000;
        $fatal(1, "GLOBAL TIMEOUT state=%0d cap_n=%0d", dut.state, cap_n);
    end

endmodule
