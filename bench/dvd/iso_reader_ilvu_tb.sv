// iso_reader_ilvu_tb.sv - SEAMLESS-BRANCH interleaved-block test for
// dvd/dvd_iso_reader.sv.
//
// A seamless-branch segment (Matrix "Follow the White Rabbit" chapters, T2
// Ultimate extended scenes) is an interleaved block authored with the cell
// category `interleaved` bit (byte0 bit 2) set and block_mode=0/block_type=0
// (NOT the multi-angle block_type==1 encoding). This branch's ILVUs are laid
// down physically INTERLEAVED with sibling-branch (other-title) ILVUs inside
// the cell's [first..last] range. Reading it linearly plays main/sibling/main
// = the "skipping". The reader must follow vobu_sri.next_vobu, which at each
// BLOCK|LAST VOBU jumps PAST the sibling ILVU to this branch's next ILVU
// (libdvdnav's default vobu_next path; NO sml_agli, NO VBUF flush).
//
// Synthetic interleaved block (ILVU = 1 nav sector + 1 body sector):
//   RBN 0 nav(A.i1 LAST, next=+4)  1 A1     <- branch A, ILVU 1  (0xA1 body)
//   RBN 2 nav(B.i1 LAST)           3 BB     <- SIBLING branch    (0xBB, MUST skip)
//   RBN 4 nav(A.i2 LAST, next=+4)  5 A1     <- branch A, ILVU 2
//   RBN 6 nav(B.i2 LAST)           7 BB     <- SIBLING branch    (0xBB, MUST skip)
//   RBN 8 nav(A.i3 END_OF_CELL)    9 A1     <- branch A, ILVU 3 (last, no jump)
//   RBN 10 CC  11 CC                        <- common continuation cell (0xCC)
// Cells: 0 interleaved cat=0x04 first=0 last=9 ; 1 common cat=0x00 first=10 last=11.
// Each nav DSI carries category (0x427), vobu_ea (0x40F), next_vobu (0x541).
// nav bodies are 0x00, so counting marker bytes tells exactly which branch's
// sectors were streamed.
//
// TEST: play cell 0 -> only 0xA1 (branch A, 3 ILVUs) + 0xCC (common) stream,
//       NO 0xBB (sibling ILVUs skipped) - driven by the reader's real snoop ->
//       next_vobu ILVU-jump path.

`timescale 1ns/1ps

module iso_reader_ilvu_tb;

    localparam IMG_BYTES = 64*2048;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [63:0] file_size = 0;

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
    integer n_a1 = 0, n_bb = 0, n_cc = 0;
    reg         seam_seen = 0;                   // did seamless_active ever assert?
    always @(posedge clk) begin
        if (dut.seamless_active) seam_seen <= 1'b1;
        if (stream_valid) begin
            cap_n = cap_n + 1;
            case (stream_data)
                8'hA1: n_a1 = n_a1 + 1;
                8'hBB: n_bb = n_bb + 1;
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
        .angle_pulse(1'b0), .cur_angle(cur_angle), .angle_count(angle_count),
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

    // ---- image builders (shared skeleton with iso_reader_angle_tb) ----
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

    // Write the DSI fields of a NAV sector for the SEAMLESS-BRANCH path:
    // category (0x427), vobu_ea (0x40F), vobu_sri.next_vobu (0x541).
    task put_nav_seam(input integer rbn, input [15:0] category,
                      input [31:0] vobu_ea, input [31:0] next_vobu);
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
            // vobu_sri.next_vobu @ DSI 0x13A -> 0x541
            img[b+16'h541]=next_vobu[31:24]; img[b+16'h542]=next_vobu[23:16];
            img[b+16'h543]=next_vobu[15:8];  img[b+16'h544]=next_vobu[7:0];
        end
    endtask

    localparam [15:0] ILVU_LAST = 16'h5000;                 // BLOCK|LAST
    localparam [31:0] SRI_END   = 32'h3fffffff;             // END_OF_CELL
    localparam [31:0] SRI_VALID = 32'h80000000;             // SRI "valid" flag (fwd)

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
            put_rec(cur,24,12*2048,    8'h00,"VTS_01_1.VOB;1",14,cur);

            put_vmgi(19, 32'd1);
            put_tt_srpt(20, 16'd1, 8'd1);
            put_vtsi_mat(21, 32'd1);
            put_pgcit(22, 32'd16, 8'd2, 16'd256);
            // cells: 0 interleaved (seamless branch) first=0 last=9 ; 1 common
            put_cell(22, 32'd16, 16'd256, 0, 8'h04, 32'd0, 32'd9);    // interleaved bit
            put_cell(22, 32'd16, 16'd256, 1, 8'h00, 32'd10, 32'd11);  // common

            // interleaved VOB: branch A ILVUs + sibling B ILVUs, round-robin.
            // next_vobu is FORWARD-only (bit31 = SRI valid). Branch A skips past
            // each sibling ILVU by pointing 4 sectors ahead (past B's nav+body).
            put_nav_seam(0, ILVU_LAST, 32'd1, SRI_VALID | 32'd4);   // A.i1 -> RBN4 (skip B.i1)
            fill_sec(24+1, 8'hA1);
            put_nav_seam(2, ILVU_LAST, 32'd1, SRI_VALID | 32'd4);   // B.i1 (SIBLING - never reached)
            fill_sec(24+3, 8'hBB);
            put_nav_seam(4, ILVU_LAST, 32'd1, SRI_VALID | 32'd4);   // A.i2 -> RBN8 (skip B.i2)
            fill_sec(24+5, 8'hA1);
            put_nav_seam(6, ILVU_LAST, 32'd1, SRI_VALID | 32'd4);   // B.i2 (SIBLING - never reached)
            fill_sec(24+7, 8'hBB);
            put_nav_seam(8, ILVU_LAST, 32'd1, SRI_END);             // A.i3 (last, END_OF_CELL)
            fill_sec(24+9, 8'hA1);
            fill_sec(24+10, 8'hCC);
            fill_sec(24+11, 8'hCC);
        end
    endtask

    // Wait until at least n bytes captured, or the reader parks.
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

        build_iso;
        file_size = IMG_BYTES;
        @(posedge clk); start = 1; @(posedge clk); start = 0;
        run_until_done(30000);
        $display("ILVU seamless-branch: seamless_active=%0d  A1=%0d BB=%0d CC=%0d",
                 seam_seen, n_a1, n_bb, n_cc);
        if (!seam_seen)          begin errors=errors+1; $display("  FAIL: seamless_active never asserted"); end
        if (n_bb !== 0)          begin errors=errors+1; $display("  FAIL: sibling ILVU bytes leaked (0xBB=%0d) - NOT skipping!", n_bb); end
        if (n_a1 !== 3*2048)     begin errors=errors+1; $display("  FAIL: branch-A body != 3 ILVUs (%0d)", n_a1); end
        if (n_cc !== 2*2048)     begin errors=errors+1; $display("  FAIL: common cell != 2 sectors (%0d)", n_cc); end
        if (errors == 0) $display("  ok: branch A followed via next_vobu, sibling ILVUs skipped");

        if (errors == 0) $display("ISO_READER_ILVU_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_ILVU_TB: %0d FAILURE(S)", errors);
        $finish;
    end

    initial begin #200000000; $display("TIMEOUT"); $finish; end

endmodule
