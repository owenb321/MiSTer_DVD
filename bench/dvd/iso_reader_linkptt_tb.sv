// iso_reader_linkptt_tb.sv - end-to-end repro + regression for the Tomb Raider
// "return to a previous choice freezes" ROOT cause: an in-content LinkPTTN whose
// part lives in a DIFFERENT PGC (cross-PGC). VTS5 PGC4 POST = LinkPTT 5, PGC11
// POST = LinkPTT 13; HW row-22 overlay confirmed the last jump was TT vts5
// pgc4/pgc11 (VM fix working) and both dead-ended on their LinkPTT POST.
//
// The VM used to route LinkPTTN through the LIGHT in-PGC program map (V_PMRD),
// which can only reach programs of the CURRENT PGC. A cross-PGC part overflowed
// (pg_tgt > nr_pgms) and the VM did a benign vm_adv -> dead-end -> S_DONE ->
// video freeze. Fix: on that overflow, fall back to the EXACT VTS_PTT_SRPT
// resolve (like JumpVTS_PTT), staying in the current title. Same-PGC LinkPTTN
// (every movie: part==program) still resolves in V_PMRD, unchanged/glitch-free.
//
// This tb: FP {JumpTT 1} -> VTS_01 PGC1 (1 program, 0xB0), POST = LinkPTT 3.
// VTS_PTT_SRPT maps title-1 part 3 -> {pgc2, pg1} (CROSS-PGC). PASS = the reader
// crosses to PGC2 and streams 0xB2 (before the fix: overflow -> dead-end, no 0xB2).
//
// Run: iverilog -g2012 -o /tmp/rlp dvd/dvd_iso_reader.sv dvd/dvd_vm.sv \
//        dvd/bcd_time_add.sv bench/dvd/iso_reader_linkptt_tb.sv && vvp /tmp/rlp

`timescale 1ns/1ps

module iso_reader_linkptt_tb;

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
    wire        vm_cell_cmd_w, vm_pgc_end_w, vm_adv_w, vm_replay_w;
    wire        vm_jump_pulse;
    wire [1:0]  vm_jump_domain;
    wire [7:0]  vm_jump_vts, vm_jump_pgcn, vm_jump_cell, vm_jump_pgn;
    wire [9:0]  vm_jump_ptt;
    wire [3:0]  vm_jump_entry;
    wire [6:0]  vm_jump_ttn;
    wire        vm_seek_pulse;
    wire [7:0]  vm_seek_cell;
    wire        cmd_we_w, pm_we_w;
    wire [11:0] cmd_waddr_w;
    wire [7:0]  cmd_wdata_w, nr_pre_w, nr_post_w, nr_cell_w, nr_pgm_w;
    wire [6:0]  pm_waddr_w;
    wire [7:0]  pm_wdata_w;
    wire [7:0]  sprm_astn_w, sprm_spstn_w;
    wire [7:0]  vm_dbg;

    reg         key_menu = 0, key_resume = 0;

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(4'd0), .vbuf_empty(1'b1), .menu_snap(1'b0),   // always-drained: tail-drain wait bypassed (bit-exact pre-drain timing)
        .jump_ttn(vm_jump_ttn), .jump_pgn(vm_jump_pgn), .jump_ptt(vm_jump_ptt),
        .vm_mode(1'b1), .vm_adv(vm_adv_w), .vm_replay(vm_replay_w),
        .vm_cell_cmd(vm_cell_cmd_w), .vm_pgc_end(vm_pgc_end_w),
        .nav_ready_o(nav_ready_w), .auto_vts(auto_vts_w),
        .cell_count_o(cell_count_w), .res_ttn(res_ttn_w),
        .pm_we(pm_we_w), .pm_waddr(pm_waddr_w), .pm_wdata(pm_wdata_w),
        .cmd_nr_pgm(nr_pgm_w),
        .seek_pulse(vm_seek_pulse), .seek_natural(1'b0), .seek_cell(vm_seek_cell), .seek_ack(seek_ack),
        .cur_cell(cur_cell), .cell_ready(cell_ready),
        .jump_pulse(vm_jump_pulse), .jump_natural(1'b0), .jump_domain(vm_jump_domain),
        .jump_vts(vm_jump_vts), .jump_pgcn(vm_jump_pgcn),
        .jump_entry(vm_jump_entry), .jump_cell(vm_jump_cell),
        .jump_ack(jump_ack), .pgc_loaded(pgc_loaded), .pgc_error(pgc_error),
        .menu_active(menu_active), .still_active(still_active), .cur_vts(cur_vts),
        .cur_pgcn_o(cur_pgcn_rd),
        .best_menu_vts(best_menu_vts),
        .menu_btns_armed(1'b0),
        .cmd_we(cmd_we_w), .cmd_waddr(cmd_waddr_w), .cmd_wdata(cmd_wdata_w),
        .cmd_nr_pre(nr_pre_w), .cmd_nr_post(nr_post_w), .cmd_nr_cell(nr_cell_w),
        .cell_end_pulse(), .pgc_end_pulse(),
        .pgc_still_time(), .next_pgcn(rd_next), .prev_pgcn(rd_prev),
        .goup_pgcn(rd_goup),
        .cur_cell_still(), .cur_cell_cmdnr(cur_cell_cmdnr_w),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .pal_we(), .pal_waddr(), .pal_wdata(),
        .debug_active(), .debug_sd_rd(), .debug_sd_ack(), .debug_cache_has_data(),
        .debug_file_size(), .debug_total_sectors(), .debug_next_lba(),
        .debug_state(), .debug_iso_mode(), .debug_iso_error()
    );

    dvd_vm vm (
        .clk(clk), .rst_n(rst_n), .enable(1'b1), .start(start),
        .rnd_seed(16'hACE1), .sec_tick(1'b0),
        .entropy_stir(1'b0), .entropy_val(16'd0),
        .nav_ready(nav_ready_w), .auto_vts(auto_vts_w),
        .best_menu_vts(best_menu_vts), .res_ttn(res_ttn_w),
        .cmd_we(cmd_we_w), .cmd_waddr(cmd_waddr_w), .cmd_wdata(cmd_wdata_w),
        .nr_pre(nr_pre_w), .nr_post(nr_post_w), .nr_cell(nr_cell_w),
        .pm_we(pm_we_w), .pm_waddr(pm_waddr_w), .pm_wdata(pm_wdata_w),
        .nr_pgms(nr_pgm_w),
        .pgc_loaded(pgc_loaded), .pgc_error(pgc_error),
        .vm_cell_cmd(vm_cell_cmd_w), .cell_cmd_nr(cur_cell_cmdnr_w),
        .vm_pgc_end(vm_pgc_end_w), .menu_active(menu_active),
        .cur_vts(cur_vts), .cur_pgcn(cur_pgcn_rd), .cur_cell(cur_cell),
        .cell_count(cell_count_w),
        .next_pgcn(rd_next), .prev_pgcn(rd_prev), .goup_pgcn(rd_goup),
        .key_menu(key_menu), .key_resume(key_resume), .key_title(1'b0), .key_return(1'b0),
        .btn_cmd(64'd0), .btn_cmd_valid(1'b0), .btn_sel(6'd1), .btns_armed(1'b0),
        .btn_force(), .btn_force_val(),
        .jump_pulse(vm_jump_pulse), .jump_domain(vm_jump_domain),
        .jump_vts(vm_jump_vts), .jump_pgcn(vm_jump_pgcn),
        .jump_entry(vm_jump_entry), .jump_ttn(vm_jump_ttn),
        .jump_pgn(vm_jump_pgn), .jump_cell(vm_jump_cell), .jump_ptt(vm_jump_ptt),
        .seek_pulse(vm_seek_pulse), .seek_cell(vm_seek_cell),
        .vm_replay(vm_replay_w), .vm_adv(vm_adv_w), .wait_hold(1'b0),
        .sprm_astn(sprm_astn_w), .sprm_spstn(sprm_spstn_w),
        .dbg_state(vm_dbg)
    );

    always #5 clk = ~clk;

    integer cap_n = 0;
    reg [7:0] cap [0:131071];
    always @(posedge clk) if (stream_valid) begin cap[cap_n] = stream_data; cap_n = cap_n + 1; end

    reg trace_on = 0;
    always @(posedge clk) if (trace_on) begin
        if (vm_jump_pulse)
            $display("  [%0t] jump dom=%0d vts=%0d ttn=%0d ptt=%0d pgcn=%0d", $time,
                     vm_jump_domain, vm_jump_vts, vm_jump_ttn, vm_jump_ptt, vm_jump_pgcn);
        if (pgc_loaded)
            $display("  [%0t] pgc_loaded cur_vts=%0d cur_pgcn=%0d nr_pgm=%0d nr_post=%0d", $time,
                     cur_vts, cur_pgcn_rd, nr_pgm_w, nr_post_w);
        if (vm_pgc_end_w) $display("  [%0t] vm_pgc_end (vm.state=%0d link_ptt=%0d)", $time, vm.state, vm.link_ptt);
        if (vm_adv_w)     $display("  [%0t] vm_adv", $time);
    end

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
            put_rec(cur,27,4096,8'h00,"VTS_01_1.VOB;1",14,cur);   // title 27..28

            // VMGI_MAT @19: FP@400; TT_SRPT@+1 (20)
            be32(19*2048+132,32'd400); be32(19*2048+196,32'd1);
            put_pgc(19*2048+400,8'd0,8'd0,16'd0,8'd0,16'd236,16'd0,16'd0);
            put_cmdtbl(19*2048+400,16'd236,1,0,0,64'h3002000000010000,64'd0,64'd0); // JumpTT 1
            // TT_SRPT @20: title 1 -> VTS_01, vts_ttn 1
            be16(20*2048+0,16'd1); img[20*2048+14]=8'd1; img[20*2048+15]=8'd1;

            // VTSI_MAT @22: vts_ptt_srpt=+1 (23), vts_pgcit=+2 (24)
            be32(22*2048+200,32'd1); be32(22*2048+204,32'd2);

            // VTS_PTT_SRPT @23: 1 title, 3 PTTs. ttu_offset[0]=@100.
            //   part1 -> {pgc1,pg1}, part2 -> {pgc1,pg1}, part3 -> {pgc2,pg1} (CROSS-PGC)
            be16(23*2048+0,16'd1);            // nr_of_srpts
            be32(23*2048+4,32'd111);          // last_byte
            be32(23*2048+8,32'd100);          // ttu_offset[0]
            be16(23*2048+100,16'd1); be16(23*2048+102,16'd1);   // part1 -> pgc1 pg1
            be16(23*2048+104,16'd1); be16(23*2048+106,16'd1);   // part2 -> pgc1 pg1
            be16(23*2048+108,16'd2); be16(23*2048+110,16'd1);   // part3 -> pgc2 pg1 (cross-PGC)

            // VTS_PGCIT @24: 2 SRPs. SRP[0] entry 0x81 (title 1) -> PGC1@32,
            // SRP[1] entry 0x01 -> PGC2@640. PGC1 has 1 program (so LinkPTT 3
            // OVERFLOWS -> cross-PGC fallback). PGC1 POST = LinkPTT 3.
            be16(24*2048+0,16'd2);
            img[24*2048+8]=8'h81;  be32(24*2048+8+4, 32'd32);
            img[24*2048+16]=8'h01; be32(24*2048+16+4, 32'd640);
            put_pgc(24*2048+32, 8'd1, 8'd1, 16'd0, 8'd0, 16'd320, 16'd240, 16'd256);
            img[24*2048+32+240]=8'd1;                                  // pm[0]=cell1
            put_cell(24*2048+32, 16'd256, 0, 8'd0, 8'd0, 32'd0, 32'd0); // 0xB0 @27
            put_cmdtbl(24*2048+32, 16'd320, 0, 1, 0,
                       64'h2005000000000003, 64'd0, 64'd0);            // POST LinkPTT 3
            put_pgc(24*2048+640, 8'd1, 8'd1, 16'd0, 8'd0, 16'd320, 16'd240, 16'd256);
            img[24*2048+640+240]=8'd1;
            put_cell(24*2048+640, 16'd256, 0, 8'd0, 8'd1, 32'd1, 32'd1); // 0xB2 @28
            put_cmdtbl(24*2048+640, 16'd320, 0, 0, 1,
                       64'h2007000000000001, 64'd0, 64'd0);            // cell cmd LinkCN 1 (loop)

            for (j=0;j<2048;j=j+1) begin img[27*2048+j]=8'hB0; img[28*2048+j]=8'hB2; end
        end
    endtask

    task fail(input [511:0] msg); begin $display("FAIL: %0s", msg); errors=errors+1; end endtask
    task wait_bytes(input integer target); integer t; begin
        t=0; while (cap_n<target && t<8000000) begin @(posedge clk); t=t+1; end
        if (cap_n<target) fail("wait_bytes timeout");
    end endtask

    integer t1_end;
    initial begin
        build_iso; file_size=IMG_BYTES;
        repeat (5) @(negedge clk); rst_n=1;
        repeat (5) @(negedge clk); start=1; @(negedge clk); start=0;

        // BOOT: FP -> JumpTT 1 -> VTS1 PGC1 (0xB0)
        wait_bytes(2048);
        if (cap[0]!==8'hB0) fail("BOOT: first byte != B0");
        if (cur_vts!==8'd1) fail("BOOT: cur_vts != 1");
        t1_end=cap_n;
        $display("BOOT: VTS1 PGC1 0xB0 cur_vts=%0d SPRM5=%0d (cap=%0d)", cur_vts, vm.sprm5, t1_end);
        trace_on=1;

        // PGC1 POST = LinkPTT 3 -> part 3 is CROSS-PGC -> must reach PGC2 (0xB2).
        begin : wb integer t; integer s2;
            t=0; s2=0;
            while (t<10000000 && s2==0) begin
                @(posedge clk);
                if (stream_valid && stream_data==8'hB2) s2=s2+1;
                t=t+1;
            end
            $display("  after LinkPTT 3: reader state=%0d vm_state=%0d cur_vts=%0d cur_pgcn=%0d 0xB2=%0d",
                     dut.state, vm.state, cur_vts, cur_pgcn_rd, s2);
            if (s2==0)
                fail("FREEZE REPRO: cross-PGC LinkPTT 3 did not reach PGC2 (0xB2) -- dead-ended");
            if (cur_vts!==8'd1)
                fail("cross-PGC LinkPTT dropped the VTS (cur_vts != 1)");
            if (cur_pgcn_rd!==8'd2)
                fail("cross-PGC LinkPTT did not land on PGC2 (cur_pgcn != 2)");
        end

        if (errors==0) $display("ISO_READER_LINKPTT_TB: ALL TESTS PASSED");
        else           $display("ISO_READER_LINKPTT_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin
        #600000000;
        $display("GLOBAL TIMEOUT state=%0d vm_state=%0d cap_n=%0d cur_vts=%0d cur_pgcn=%0d",
                 dut.state, vm.state, cap_n, cur_vts, cur_pgcn_rd);
        $finish;
    end

endmodule
