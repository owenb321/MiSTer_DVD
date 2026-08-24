// iso_reader_angle_tb.sv - MULTI-ANGLE (Phase 9) test for dvd/dvd_iso_reader.sv.
//
// A multi-angle segment is an interleaved block: the PGC holds one CELL per
// angle (cell category byte@0 block_type==1), all sharing the physical VOB, cut
// into interleaved units (ILVUs) laid down round-robin. The reader plays ONLY
// the selected angle by following the DSI sml_agli chain, jumping past the other
// angles' ILVUs at each ILVU boundary (no VBUF flush - the timeline is shared).
//
// Synthetic 2-angle block (ILVU = 1 nav sector + 1 body sector), physical order:
//   RBN 0 nav(a1.i1)  1 A1        <- angle 1, ILVU 1   (0xA1 body)
//   RBN 2 nav(a2.i1)  3 A2        <- angle 2, ILVU 1   (0xA2 body)
//   RBN 4 nav(a2.i2)  5 A2        <- angle 2, ILVU 2
//   RBN 6 nav(a1.i2)  7 A1        <- angle 1, ILVU 2
//   RBN 8 CC  9 CC                <- common continuation cell (0xCC, NOT angle)
// Cells: 0 angle1 cat=0x50 first=0 last=7 ; 1 angle2 cat=0xD0 first=2 last=5 ;
//        2 common cat=0x00 first=8 last=9.  angle_count=2, block_last=cell1.
// Each nav DSI: category (0x427), vobu_ea (0x40F), sml_agli[0/1] (0x4BB/0x4C1).
// nav bodies are filled 0x00 (no 0xA1/0xA2/0xCC), so counting marker bytes in
// the captured stream tells exactly which angle's sectors were streamed.
//
// TEST A: play angle 1 -> only 0xA1 + 0xCC bytes stream, NO 0xA2 (the reader's
//         real snoop -> ILVU-jump path, driven by synthetic DSI bytes).
// TEST B: switch to angle 2 at block entry -> the ILVU chain follows angle 2
//         (one initial 0xA1 ILVU before the switch takes effect, then 0xA2).
// (Byte-exact validation of the DSI decode against the REAL MiB VTS_14 NAV
//  sector lives in bench/dvd/nav_angle_tb.sv, which drives the same fixture
//  through nav_dsi and checks category + the golden angle target RBN 971.)

`timescale 1ns/1ps

module iso_reader_angle_tb;

    localparam IMG_BYTES = 64*2048;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [63:0] file_size = 0;

    reg         angle_pulse = 0;
    wire [3:0]  cur_angle;
    wire [3:0]  angle_count;

    wire [31:0] sd_lba;
    wire        sd_rd;
    reg         sd_ack = 0;
    reg  [13:0] sd_buff_addr = 0;
    reg  [7:0]  sd_buff_dout = 0;
    reg         sd_buff_wr = 0;

    wire [7:0]  stream_data;
    wire        stream_valid;
    reg         busy = 0;

    wire [15:0] debug_state;
    reg  [7:0]  img [0:IMG_BYTES-1];

    // ---- capture + per-marker counters ----
    integer cap_n = 0;
    integer n_a1 = 0, n_a2 = 0, n_cc = 0;
    reg [3:0] max_ac = 0;                        // peak angle_count seen (cleared at block end)
    always @(posedge clk) begin
        if (angle_count > max_ac) max_ac <= angle_count;
        if (stream_valid) begin
            cap_n = cap_n + 1;
            case (stream_data)
                8'hA1: n_a1 = n_a1 + 1;
                8'hA2: n_a2 = n_a2 + 1;
                8'hCC: n_cc = n_cc + 1;
            endcase
        end
    end

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size),
        .title_sel(4'd0), .vbuf_empty(1'b0), .menu_snap(1'b0),
        .jump_ttn(7'd0), .jump_pgn(8'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_pulse(1'b0), .seek_natural(1'b0), .seek_cell(8'd0), .seek_ack(),
        .seek_rbn_pulse(1'b0), .seek_rbn(32'd0),
        .chap_pulse(1'b0), .chap_dir(1'b0), .chap_mag(5'd1), .chap_at_start(1'b0),
        .angle_pulse(angle_pulse), .cur_angle(cur_angle), .angle_count(angle_count),
        .keep_vbuf(),
        .cur_cell(), .cell_ready(),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .debug_active(), .debug_sd_rd(), .debug_sd_ack(), .debug_cache_has_data(),
        .debug_file_size(), .debug_total_sectors(), .debug_next_lba(),
        .debug_state(debug_state), .debug_iso_mode(), .debug_iso_error()
    );

    always #5 clk = ~clk;

    // ---- mock HPS: one 512-byte block per sd_rd ----
    integer m = 0, bc = 0, lat = 0;
    reg [31:0] rlba = 0;
    always @(posedge clk) begin
        sd_buff_wr <= 1'b0;
        case (m)
        0: begin sd_ack <= 1'b0; if (sd_rd) begin rlba <= sd_lba; lat <= 3; m <= 1; end end
        1: begin if (lat != 0) lat <= lat - 1; else begin sd_ack <= 1'b1; bc <= 0; m <= 2; end end
        2: begin
            sd_ack <= 1'b1; sd_buff_wr <= 1'b1;
            sd_buff_addr <= bc[13:0];
            sd_buff_dout <= img[rlba*2048 + bc];
            bc <= bc + 1;
            if (bc == 2047) m <= 3;
        end
        3: begin sd_ack <= 1'b0; sd_buff_wr <= 1'b0; m <= 0; end
        endcase
    end

    // ---- image builders (shared skeleton with iso_reader_seek_tb) ----
    integer i, cur;

    task fill_sec(input integer sec, input [7:0] v);
        integer j; begin for (j=0;j<2048;j=j+1) img[sec*2048+j]=v; end
    endtask

    task put_rec(input integer off, input [31:0] ext, input [31:0] dlen,
                 input [7:0] flags, input [127:0] nm, input integer nlen,
                 output integer next_off);
        integer j; integer rl;
        begin
            rl = 33 + nlen; if (rl[0]) rl = rl + 1;
            img[off+0]=rl[7:0]; img[off+1]=0;
            img[off+2]=ext[7:0]; img[off+3]=ext[15:8]; img[off+4]=ext[23:16]; img[off+5]=ext[31:24];
            for (j=6;j<10;j=j+1) img[off+j]=0;
            img[off+10]=dlen[7:0]; img[off+11]=dlen[15:8]; img[off+12]=dlen[23:16]; img[off+13]=dlen[31:24];
            for (j=14;j<25;j=j+1) img[off+j]=0;
            img[off+25]=flags; img[off+26]=0; img[off+27]=0;
            for (j=28;j<32;j=j+1) img[off+j]=0;
            img[off+32]=nlen[7:0];
            for (j=0;j<nlen;j=j+1) img[off+33+j]=nm[8*(nlen-1-j) +: 8];
            if ((33+nlen)&1) img[off+33+nlen]=0;
            next_off = off + rl;
        end
    endtask

    task put_vmgi(input integer sec, input [31:0] p);
        begin img[sec*2048+196]=p[31:24]; img[sec*2048+197]=p[23:16];
              img[sec*2048+198]=p[15:8]; img[sec*2048+199]=p[7:0]; end
    endtask
    task put_tt_srpt(input integer sec, input [15:0] n, input [7:0] v1);
        integer b; begin b=sec*2048;
            img[b+0]=n[15:8]; img[b+1]=n[7:0];
            img[b+8]=0; img[b+9]=1; img[b+10]=0; img[b+11]=1;
            img[b+12]=0; img[b+13]=0; img[b+14]=v1; img[b+15]=1; end
    endtask
    task put_vtsi_mat(input integer sec, input [31:0] p);
        begin img[sec*2048+204]=p[31:24]; img[sec*2048+205]=p[23:16];
              img[sec*2048+206]=p[15:8]; img[sec*2048+207]=p[7:0]; end
    endtask
    task put_pgcit(input integer sec, input [31:0] pgc_sb,
                   input [7:0] nr_cells, input [15:0] cell_pb_off);
        integer b, pgc; begin b=sec*2048;
            img[b+0]=0; img[b+1]=1;
            img[b+12]=pgc_sb[31:24]; img[b+13]=pgc_sb[23:16];
            img[b+14]=pgc_sb[15:8]; img[b+15]=pgc_sb[7:0];
            pgc=b+pgc_sb;
            img[pgc+2]=8'd1; img[pgc+3]=nr_cells;
            img[pgc+232]=cell_pb_off[15:8]; img[pgc+233]=cell_pb_off[7:0]; end
    endtask
    task put_cell(input integer sec, input [31:0] pgc_sb, input [15:0] cell_pb_off,
                  input integer idx, input [7:0] cat,
                  input [31:0] first_sector, input [31:0] last_sector);
        integer c; begin
            c = sec*2048 + pgc_sb + cell_pb_off + idx*24;
            img[c+0]  = cat;                                          // category@0
            img[c+8]  = first_sector[31:24]; img[c+9]  = first_sector[23:16];
            img[c+10] = first_sector[15:8];  img[c+11] = first_sector[7:0];
            img[c+20] = last_sector[31:24];  img[c+21] = last_sector[23:16];
            img[c+22] = last_sector[15:8];   img[c+23] = last_sector[7:0]; end
    endtask

    // Write the DSI fields of a NAV sector (relative to sector start; DSI@0x407).
    task put_nav(input integer rbn, input [15:0] category, input [31:0] vobu_ea,
                 input [31:0] agli0, input [31:0] agli1);
        integer b; begin
            b = (24 + rbn) * 2048;
            fill_sec(24 + rbn, 8'h00);
            // DSI PES header + substream id
            img[b+16'h400]=8'h00; img[b+16'h401]=8'h00; img[b+16'h402]=8'h01; img[b+16'h403]=8'hBF;
            img[b+16'h406]=8'h01;
            // vobu_ea @ DSI 0x08 -> 0x40F
            img[b+16'h40F]=vobu_ea[31:24]; img[b+16'h410]=vobu_ea[23:16];
            img[b+16'h411]=vobu_ea[15:8];  img[b+16'h412]=vobu_ea[7:0];
            // category @ DSI 0x20 -> 0x427
            img[b+16'h427]=category[15:8]; img[b+16'h428]=category[7:0];
            // sml_agli[0].address @ DSI 0xB4 -> 0x4BB ; [1] @ 0x4C1
            img[b+16'h4BB]=agli0[31:24]; img[b+16'h4BC]=agli0[23:16];
            img[b+16'h4BD]=agli0[15:8];  img[b+16'h4BE]=agli0[7:0];
            img[b+16'h4C1]=agli1[31:24]; img[b+16'h4C2]=agli1[23:16];
            img[b+16'h4C3]=agli1[15:8];  img[b+16'h4C4]=agli1[7:0];
        end
    endtask

    localparam [15:0] ILVU_LAST = 16'h5000;   // BLOCK|LAST

    task build_iso;
        begin
            for (i=0;i<IMG_BYTES;i=i+1) img[i]=8'h00;
            // PVD @16
            img[32768]=8'd1; img[32769]="C"; img[32770]="D"; img[32771]="0";
            img[32772]="0"; img[32773]="1"; img[32774]=8'd1;
            put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur);
            // root @17
            cur=34816;
            put_rec(cur,17,2048,8'h02,128'h00,1,cur);
            put_rec(cur,17,2048,8'h02,128'h01,1,cur);
            put_rec(cur,18,2048,8'h02,"VIDEO_TS",8,cur);
            // VIDEO_TS @18
            cur=36864;
            put_rec(cur,17,2048,8'h02,128'h00,1,cur);
            put_rec(cur,17,2048,8'h02,128'h01,1,cur);
            put_rec(cur,19,4096,       8'h00,"VIDEO_TS.IFO;1",14,cur);
            put_rec(cur,21,6144,       8'h00,"VTS_01_0.IFO;1",14,cur);
            put_rec(cur,24,10*2048,    8'h00,"VTS_01_1.VOB;1",14,cur);

            put_vmgi(19, 32'd1);
            put_tt_srpt(20, 16'd1, 8'd1);
            put_vtsi_mat(21, 32'd1);
            put_pgcit(22, 32'd16, 8'd3, 16'd256);
            // cells: 0 angle1 (block first), 1 angle2 (block last), 2 common
            put_cell(22, 32'd16, 16'd256, 0, 8'h50, 32'd0, 32'd7);   // angle 1
            put_cell(22, 32'd16, 16'd256, 1, 8'hD0, 32'd2, 32'd5);   // angle 2
            put_cell(22, 32'd16, 16'd256, 2, 8'h00, 32'd8, 32'd9);   // common

            // interleaved VOB: nav+body per ILVU, per-angle marker bodies
            put_nav(0, ILVU_LAST, 32'd1, 32'd6, 32'd2);   // a1.i1: a1->6  a2->2
            fill_sec(24+1, 8'hA1);
            put_nav(2, ILVU_LAST, 32'd1, 32'd4, 32'd2);   // a2.i1: a1->6  a2->4
            fill_sec(24+3, 8'hA2);
            put_nav(4, ILVU_LAST, 32'd1, 32'd2, 32'd4);   // a2.i2: a1->6  a2->8(reject>5)
            fill_sec(24+5, 8'hA2);
            put_nav(6, ILVU_LAST, 32'd1, 32'd2, 32'd2);   // a1.i2: a1->8(reject>7)
            fill_sec(24+7, 8'hA1);
            fill_sec(24+8, 8'hCC);
            fill_sec(24+9, 8'hCC);
        end
    endtask

    // Wait until at least n bytes captured, or the reader parks in S_DONE/idle.
    task run_until_done(input integer maxb);
        integer tt; begin
            tt = 0;
            while (cap_n < maxb && tt < 3000000) begin @(posedge clk); tt = tt + 1; end
            repeat (400) @(posedge clk);        // let the tail drain
        end
    endtask

    integer errors = 0;

    initial begin
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);

        // ================= TEST A: angle 1 (no switch) =================
        build_iso;
        file_size = IMG_BYTES;
        @(posedge clk); start = 1; @(posedge clk); start = 0;
        run_until_done(30000);
        $display("TEST A (angle 1): peak angle_count=%0d cur_angle=%0d  A1=%0d A2=%0d CC=%0d",
                 max_ac, cur_angle, n_a1, n_a2, n_cc);
        if (max_ac !== 4'd2)      begin errors=errors+1; $display("  FAIL: peak angle_count!=2 (%0d)", max_ac); end
        if (n_a2 !== 0)           begin errors=errors+1; $display("  FAIL: angle-2 bytes leaked into angle 1 (%0d)", n_a2); end
        if (n_a1 !== 2*2048)      begin errors=errors+1; $display("  FAIL: angle-1 body != 2 sectors (%0d)", n_a1); end
        if (n_cc !== 2*2048)      begin errors=errors+1; $display("  FAIL: common cell != 2 sectors (%0d)", n_cc); end
        if (errors == 0) $display("  ok: angle 1 streamed cleanly, angle 2 ILVUs skipped");

        // ================= TEST B: switch to angle 2 =================
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        cap_n = 0; n_a1 = 0; n_a2 = 0; n_cc = 0; max_ac = 0;
        @(posedge clk); start = 1; @(posedge clk); start = 0;
        // switch as soon as the angle block is scanned (angle_count known),
        // before the first ILVU boundary is reached
        fork
            begin : sw
                integer tt; tt = 0;
                while (angle_count != 4'd2 && tt < 2000000) begin @(posedge clk); tt=tt+1; end
                @(posedge clk); angle_pulse <= 1'b1;
                @(posedge clk); angle_pulse <= 1'b0;
            end
        join_none
        run_until_done(30000);
        $display("TEST B (switch->angle 2): cur_angle=%0d  A1=%0d A2=%0d CC=%0d",
                 cur_angle, n_a1, n_a2, n_cc);
        if (cur_angle !== 4'd2) begin errors=errors+1; $display("  FAIL: cur_angle!=2 after switch"); end
        if (n_a2 !== 2*2048)    begin errors=errors+1; $display("  FAIL: angle-2 body != 2 sectors (%0d)", n_a2); end
        if (n_a1 !== 1*2048)    begin errors=errors+1; $display("  FAIL: expected 1 pre-switch A1 ILVU (%0d)", n_a1); end
        if (n_cc !== 2*2048)    begin errors=errors+1; $display("  FAIL: common cell != 2 sectors (%0d)", n_cc); end
        if (errors == 0) $display("  ok: switch followed angle 2's ILVU chain");

        if (errors == 0) $display("ISO_READER_ANGLE_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_ANGLE_TB: %0d FAILURE(S)", errors);
        $finish;
    end

    initial begin #200000000; $display("TIMEOUT"); $finish; end

endmodule
