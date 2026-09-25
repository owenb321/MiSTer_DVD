// angle_noagli_tb.sv - MULTI-ANGLE WITH NO sml_agli (dvd/dvd_iso_reader.sv).
//
// A multi-angle disc need NOT author the DSI sml_agli per-angle jump table.
// MEASURED on two real discs:
//   CASTLE_IN_THE_SKY   VTS_02 PGC1  (3 angle blocks, 2 angles)
//   DIEANOTHERDAY_D1_PS VTS_05 PGC1  (19 angle blocks, 2 angles)
// every VOBU of every angle block carries sml_agli ALL ZERO, while
// vobu_sri.next_vobu is populated and correct (Castle RBN 491 BLOCK|LAST ->
// +755 -> RBN 1246 = angle 1's next ILVU, stepping over angle 2's ILVU at
// 692..1245).  libdvdnav never has this problem because next_vobu is its BASE
// next-VOBU and sml_agli is only an OVERRIDE (dvdnav.c:434-468).  The reader
// made the override mandatory, so no jump ever armed and it streamed the
// interleaved range LINEARLY.
//
// TWO user-visible consequences, and this bench asserts BOTH:
//   VIDEO - the picture alternates between the two angles every ILVU
//           ("rapidly switches between the two angles ... 2 different versions
//            of the logo and text").
//   AUDIO - each angle's ILVU carries the SAME timespan of audio, so linear
//           streaming delivers every timespan TWICE and the PTS jumps BACKWARD
//           at every junction ("makes a pop noise").  MEASURED on Castle:
//           angle 1 ILVU 1 = PTS 0.243..2.387 s, angle 2 ILVU 1 = 0.243..2.259 s.
//
// Synthetic 2-angle block, ILVU = 1 nav + 1 body sector, physical round-robin
// exactly as the real discs lay it down:
//   RBN  0 nav(a1.i1)   1 body A1 pts=100    <- angle 1 ILVU 1
//   RBN  2 nav(a2.i1)   3 body A2 pts=100    <- angle 2 ILVU 1, SAME timespan
//   RBN  4 nav(a1.i2)   5 body A1 pts=200
//   RBN  6 nav(a2.i2)   7 body A2 pts=200
//   RBN  8 nav(a1.i3)   9 body A1 pts=300
//   RBN 10 nav(a2.i3)  11 body A2 pts=300
//   RBN 12 CC pts=400  13 CC pts=500         <- common continuation (NOT angle)
// Cells: 0 angle1 cat=0x56 first=0 last=9 ; 1 angle2 cat=0xD6 first=2 last=11 ;
//        2 common cat=0x00 first=12 last=13.
// cat 0x56/0xD6 are the REAL Castle cell-category bytes (bm=1/3, bt=1, il=1,
// stc=1, sa=0) - note sa (seamless_angle, bit 0) = 0, which is what the whole
// affected class has in common.  Every nav has sml_agli ZERO; the chain lives
// only in vobu_sri.next_vobu (DSI 0x13A -> sector 0x541).
//
// EXPECTED, angle 1: 0,1 -> jump +4 -> 4,5 -> jump +4 -> 8,9 -> (next target 12
// is past cell.last=9, rejected) -> cell ends -> sibling-angle cells skipped ->
// common 12,13.  Bodies A1=3 A2=0 CC=2, PTS 100,200,300,400,500 STRICTLY
// INCREASING.
// PRE-FIX: no jump arms, angle 1 streams 0..9 linearly -> bodies at 1,3,5,7,9 =
// A1=3 A2=2 (ALTERNATING) and PTS 100,100,200,200,300 (NOT increasing).
//
// The bench scores the DELIVERED BYTE STREAM and the PTS carried in it - never
// a signal the fix names.  Run: bench/dvd/run_angle.sh [--red]

`timescale 1ns/1ps

module angle_noagli_tb;

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

    reg  [7:0]  img [0:IMG_BYTES-1];

    // ---------------- capture: markers + a real PES/PTS decoder --------------
    integer cap_n = 0;
    integer n_a1 = 0, n_a2 = 0, n_cc = 0;
    reg [3:0] max_ac = 0;

    // PTS extraction from the delivered stream (00 00 01 E0 ... PTS).
    reg  [31:0] sig = 32'd0;
    integer     pk = -1;              // byte index since the 0xE0, -1 = idle
    reg  [32:0] pts_acc = 0;
    integer     n_pts = 0;
    integer     pts_log [0:63];
    integer     pts_back = 0;         // BACKWARD-or-equal PTS steps seen

    always @(posedge clk) begin
        if (angle_count > max_ac) max_ac <= angle_count;
        if (stream_valid) begin
            cap_n = cap_n + 1;
            case (stream_data)
                8'hA1: n_a1 = n_a1 + 1;
                8'hA2: n_a2 = n_a2 + 1;
                8'hCC: n_cc = n_cc + 1;
            endcase
            sig = {sig[23:0], stream_data};
            if (pk >= 0) pk = pk + 1;
            if (sig == 32'h000001E0 && pk < 0) pk = 0;
            // k=1 lenhi 2 lenlo 3 flags1 4 flags2 5 hdrlen 6..10 PTS
            if (pk == 6)  pts_acc[32:30] = stream_data[3:1];
            if (pk == 7)  pts_acc[29:22] = stream_data;
            if (pk == 8)  pts_acc[21:15] = stream_data[7:1];
            if (pk == 9)  pts_acc[14:7]  = stream_data;
            if (pk == 10) begin
                pts_acc[6:0] = stream_data[7:1];
                if (n_pts < 64) pts_log[n_pts] = pts_acc;
                if (n_pts > 0 && pts_acc <= pts_log[n_pts-1]) pts_back = pts_back + 1;
                n_pts = n_pts + 1;
                pk = -1;
            end
        end
    end

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size),
        .title_sel(7'd0), .aud_drained(1'b1), .vbuf_empty(1'b0), .menu_snap(1'b0),
        .jump_ttn(7'd0), .jump_pgn(8'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_pulse(1'b0), .seek_natural(1'b0), .seek_cell(8'd0), .seek_ack(),
        .seek_rbn_pulse(1'b0), .seek_rbn(32'd0), .seek_tm_req(1'b0), .seek_tm_secs(17'd0),
        .chap_pulse(1'b0), .chap_dir(1'b0), .chap_mag(5'd1), .chap_at_start(1'b0),
        .angle_pulse(angle_pulse), .cur_angle(cur_angle), .angle_count(angle_count),
        .agl_vm(4'd0), .agl_vm_en(1'b0), .vm_pre_done(1'b0),
        .keep_vbuf(),
        .cur_cell(), .cell_ready(),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .debug_active(), .debug_sd_rd(), .debug_sd_ack(), .debug_cache_has_data(),
        .debug_file_size(), .debug_total_sectors(), .debug_next_lba(),
        .debug_state(), .debug_iso_mode(), .debug_iso_error()
    );

    always #5 clk = ~clk;

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
            img[c+0]  = cat;
            img[c+8]  = first_sector[31:24]; img[c+9]  = first_sector[23:16];
            img[c+10] = first_sector[15:8];  img[c+11] = first_sector[7:0];
            img[c+20] = last_sector[31:24];  img[c+21] = last_sector[23:16];
            img[c+22] = last_sector[15:8];   img[c+23] = last_sector[7:0]; end
    endtask

    // NAV sector with sml_agli ZERO and the chain in vobu_sri.next_vobu
    // (DSI 0x13A -> sector 0x541).  bit31 is the SRI VALID flag, not a sign.
    task put_nav_nv(input integer rbn, input [15:0] category,
                    input [31:0] vobu_ea, input [31:0] next_vobu);
        integer b; begin
            b = (24 + rbn) * 2048;
            fill_sec(24 + rbn, 8'h00);
            img[b+16'h400]=8'h00; img[b+16'h401]=8'h00; img[b+16'h402]=8'h01; img[b+16'h403]=8'hBF;
            img[b+16'h406]=8'h01;
            img[b+16'h40F]=vobu_ea[31:24]; img[b+16'h410]=vobu_ea[23:16];
            img[b+16'h411]=vobu_ea[15:8];  img[b+16'h412]=vobu_ea[7:0];
            img[b+16'h427]=category[15:8]; img[b+16'h428]=category[7:0];
            // sml_agli[0..8] left ZERO on purpose - that is the disc class.
            img[b+16'h541]=next_vobu[31:24]; img[b+16'h542]=next_vobu[23:16];
            img[b+16'h543]=next_vobu[15:8];  img[b+16'h544]=next_vobu[7:0];
        end
    endtask

    // Body sector: a video PES carrying a PTS, then the angle's marker byte.
    task put_body(input integer rbn, input [7:0] marker, input [32:0] pts);
        integer b, j; begin
            b = (24 + rbn) * 2048;
            for (j=0;j<2048;j=j+1) img[b+j] = marker;
            img[b+0]=8'h00; img[b+1]=8'h00; img[b+2]=8'h01; img[b+3]=8'hE0;
            img[b+4]=8'h07; img[b+5]=8'hEC;          // PES length
            img[b+6]=8'h80; img[b+7]=8'h80; img[b+8]=8'h05;
            img[b+9]  = {4'b0010, pts[32:30], 1'b1};
            img[b+10] = pts[29:22];
            img[b+11] = {pts[21:15], 1'b1};
            img[b+12] = pts[14:7];
            img[b+13] = {pts[6:0], 1'b1};
        end
    endtask

    localparam [15:0] ILVU_LAST = 16'h5000;   // BLOCK|LAST
    // Marker bytes per body sector: 2048 minus the 14-byte PES header that
    // carries the PTS (the header bytes are not the marker value).
    localparam integer BODY = 2048 - 14;

    task build_iso;
        begin
            for (i=0;i<IMG_BYTES;i=i+1) img[i]=8'h00;
            img[32768]=8'd1; img[32769]="C"; img[32770]="D"; img[32771]="0";
            img[32772]="0"; img[32773]="1"; img[32774]=8'd1;
            put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur);
            cur=34816;
            put_rec(cur,17,2048,8'h02,128'h00,1,cur);
            put_rec(cur,17,2048,8'h02,128'h01,1,cur);
            put_rec(cur,18,2048,8'h02,"VIDEO_TS",8,cur);
            cur=36864;
            put_rec(cur,17,2048,8'h02,128'h00,1,cur);
            put_rec(cur,17,2048,8'h02,128'h01,1,cur);
            put_rec(cur,19,4096,       8'h00,"VIDEO_TS.IFO;1",14,cur);
            put_rec(cur,21,6144,       8'h00,"VTS_01_0.IFO;1",14,cur);
            put_rec(cur,24,14*2048,    8'h00,"VTS_01_1.VOB;1",14,cur);

            put_vmgi(19, 32'd1);
            put_tt_srpt(20, 16'd1, 8'd1);
            put_vtsi_mat(21, 32'd1);
            put_pgcit(22, 32'd16, 8'd3, 16'd256);
            // REAL Castle category bytes: bm=1/3, bt=1(angle), il=1, stc=1, sa=0
            put_cell(22, 32'd16, 16'd256, 0, 8'h56, 32'd0,  32'd9);   // angle 1
            put_cell(22, 32'd16, 16'd256, 1, 8'hD6, 32'd2,  32'd11);  // angle 2
            put_cell(22, 32'd16, 16'd256, 2, 8'h00, 32'd12, 32'd13);  // common

            // angle 1 chain: 0 -> 4 -> 8 ; angle 2 chain: 2 -> 6 -> 10
            put_nav_nv(0,  ILVU_LAST, 32'd1, 32'h80000004);
            put_body  (1,  8'hA1, 33'd100);
            put_nav_nv(2,  ILVU_LAST, 32'd1, 32'h80000004);
            put_body  (3,  8'hA2, 33'd100);     // SAME timespan as a1.i1
            put_nav_nv(4,  ILVU_LAST, 32'd1, 32'h80000004);
            put_body  (5,  8'hA1, 33'd200);
            put_nav_nv(6,  ILVU_LAST, 32'd1, 32'h80000004);
            put_body  (7,  8'hA2, 33'd200);
            // ADVERSARIAL LAST HOP: angle 1's final ILVU points at RBN 11 --
            // inside the block but PAST this cell's last_sector (9).  A real
            // disc ends the chain with END_OF_CELL, so this models a malformed
            // or mis-parsed pointer, which is exactly what the `target <= cl_rd`
            // bound exists to reject.  Accepting it streams the SIBLING angle's
            // body and then runs off the end of the cell, so arm [A] sees it.
            put_nav_nv(8,  ILVU_LAST, 32'd1, 32'h80000003);
            put_body  (9,  8'hA1, 33'd300);
            put_nav_nv(10, ILVU_LAST, 32'd1, 32'h80000004);
            put_body  (11, 8'hA2, 33'd300);
            put_body  (12, 8'hCC, 33'd400);
            put_body  (13, 8'hCC, 33'd500);
        end
    endtask

    task run_until_done(input integer maxb);
        integer tt; begin
            tt = 0;
            while (cap_n < maxb && tt < 3000000) begin @(posedge clk); tt = tt + 1; end
            repeat (400) @(posedge clk);
        end
    endtask

    task reset_counts;
        begin cap_n=0; n_a1=0; n_a2=0; n_cc=0; max_ac=0;
              n_pts=0; pts_back=0; pk=-1; sig=0; end
    endtask

    integer errors = 0;
    integer k;

    initial begin
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);

        // ============ [A] VIDEO: follow angle 1 with no sml_agli ============
        build_iso;
        file_size = IMG_BYTES;
        @(posedge clk); start = 1; @(posedge clk); start = 0;
        run_until_done(40000);
        $display("[A] angle 1, no sml_agli: angle_count=%0d A1=%0d A2=%0d CC=%0d",
                 max_ac, n_a1, n_a2, n_cc);
        if (max_ac !== 4'd2)
            begin errors=errors+1; $display("  FAIL [A]: angle_count!=2 (%0d)", max_ac); end
        if (n_a2 !== 0)
            begin errors=errors+1; $display("  FAIL [A]: angle-2 bytes delivered while playing angle 1 (%0d) -- the angles are ALTERNATING", n_a2); end
        if (n_a1 !== 3*BODY)
            begin errors=errors+1; $display("  FAIL [A]: angle-1 body != 3 sectors (%0d, want %0d)", n_a1, 3*BODY); end
        if (n_cc !== 2*BODY)
            begin errors=errors+1; $display("  FAIL [A]: common cell != 2 sectors (%0d, want %0d)", n_cc, 2*BODY); end

        // ============ [B] AUDIO: delivered PTS must be monotonic ============
        $write("[B] delivered PTS:");
        for (k=0;k<n_pts && k<16;k=k+1) $write(" %0d", pts_log[k]);
        $display("   (backward-or-equal steps=%0d)", pts_back);
        if (pts_back !== 0)
            begin errors=errors+1; $display("  FAIL [B]: %0d BACKWARD PTS step(s) -- a timespan is delivered twice (the pop)", pts_back); end
        if (n_pts !== 5)
            begin errors=errors+1; $display("  FAIL [B]: expected 5 PES timestamps, got %0d", n_pts); end

        // ==== [C] a mid-block B6 press must not corrupt the angle-1 chain ====
        // With no sml_agli there is no per-angle table to retarget, so the
        // switch takes effect at the NEXT block (documented limitation).  What
        // must NOT happen is the stream breaking: assert it still plays ONE
        // clean angle to the end of the block.
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        reset_counts;
        @(posedge clk); start = 1; @(posedge clk); start = 0;
        fork
            begin : sw
                integer tt; tt = 0;
                while (angle_count != 4'd2 && tt < 2000000) begin @(posedge clk); tt=tt+1; end
                @(posedge clk); angle_pulse <= 1'b1;
                @(posedge clk); angle_pulse <= 1'b0;
            end
        join_none
        run_until_done(40000);
        $display("[C] mid-block B6 press: cur_angle=%0d A1=%0d A2=%0d CC=%0d back=%0d",
                 cur_angle, n_a1, n_a2, n_cc, pts_back);
        if (n_a2 !== 0)
            begin errors=errors+1; $display("  FAIL [C]: press corrupted the chain -- angle-2 bytes leaked (%0d)", n_a2); end
        if (n_a1 !== 3*BODY)
            begin errors=errors+1; $display("  FAIL [C]: angle-1 body != 3 sectors after the press (%0d, want %0d)", n_a1, 3*BODY); end
        if (pts_back !== 0)
            begin errors=errors+1; $display("  FAIL [C]: press introduced %0d backward PTS step(s)", pts_back); end

        if (errors == 0) $display("ANGLE_NOAGLI_TB: ALL TESTS PASSED");
        else begin
            $display("ANGLE_NOAGLI_TB: %0d FAILURE(S)", errors);
            $fatal(1);
        end
        $finish;
    end

endmodule
