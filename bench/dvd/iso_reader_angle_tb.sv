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
// TEST D (2026-09-15) covers a raw-RBN SCRUB that lands INSIDE an angle block.
// The angle-block entry used to be gated `... && !rbn_override`, so a seek never
// ran the angle scan: angle_count stayed 0, angle_active with it, and
// seamless_active needs !cc_is_angle -- neither arm set, no ILVU follow, and the
// interleaved range streamed LINEARLY. Field report on "Grave of the Fireflies":
// seeking "starts alternating the 2 available angles at 1hz".
//
// TEST C (2026-09-15) covers ADJACENT BLOCKS: a second 2-angle block follows the
// first with NO normal cell between them, which is how "Grave of the Fireflies"
// VTS_01 PGC1 authors the entire film (13 back-to-back pairs, one per chapter;
// Beauty and the Beast has 54, TimeTraveler 463). The angle-count scan used to
// count the run of block_type==1 cells without re-checking block_mode, so it ran
// straight across the block boundary -- reporting NINE angles (its cap) for a
// 2-angle disc, and deriving block_last from that count so the end-of-block skip
// landed ~22 minutes further into the film, on a cell that is neither
// angle_active nor seamless_active.
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
    reg         seek_rbn_pulse = 0;      // TEST D: raw-RBN scrub into a block
    reg  [31:0] seek_rbn = 32'd0;
    wire [15:0] title_secs;                // TEST E: the title's own running time
    // TEST F: the per-cell START times, captured off the cellf_* stretch port
    // that feeds dvd/seek_time.sv. The TOTAL being right does not make the
    // constituents right -- that is exactly how the first cut of the timeline
    // fix shipped a preview clock frozen at one chapter's length.
    wire        cellf_we;
    wire [6:0]  cellf_idx;
    wire [15:0] cellf_secs;
    integer     cstart [0:15];
    integer     ci;
    initial for (ci = 0; ci < 16; ci = ci + 1) cstart[ci] = -1;
    always @(posedge clk)
        if (cellf_we && cellf_idx < 7'd16) cstart[cellf_idx] = cellf_secs;
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
    integer n_b1 = 0, n_b2 = 0;          // TEST C: the SECOND adjacent block
    reg [3:0] max_ac = 0;                        // peak angle_count seen (cleared at block end)
    always @(posedge clk) begin
        if (angle_count > max_ac) max_ac <= angle_count;
        if (stream_valid) begin
            cap_n = cap_n + 1;
            case (stream_data)
                8'hA1: n_a1 = n_a1 + 1;
                8'hA2: n_a2 = n_a2 + 1;
                8'hB1: n_b1 = n_b1 + 1;
                8'hB2: n_b2 = n_b2 + 1;
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
        .seek_rbn_pulse(seek_rbn_pulse), .seek_rbn(seek_rbn),
        .chap_pulse(1'b0), .chap_dir(1'b0), .chap_mag(5'd1), .chap_at_start(1'b0),
        .angle_pulse(angle_pulse), .cur_angle(cur_angle), .angle_count(angle_count),
        .agl_vm(4'd0), .agl_vm_en(1'b0), .vm_pre_done(1'b0),
        .keep_vbuf(),
        .title_secs_o(title_secs),
        .cellf_we(cellf_we), .cellf_idx(cellf_idx), .cellf_secs(cellf_secs),
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
    // secs = the cell's playback_time as BCD seconds (< 60 here), written to
    // bytes 4..7 as dvd_time_t {hh, mm, ss, rate|frames}. Rate 3 = 30 fps in the
    // top two bits of byte 7, which is what bcd_time_add and pb_dur_w expect.
    task put_cell(input integer sec, input [31:0] pgc_sb, input [15:0] cell_pb_off,
                  input integer idx, input [7:0] cat,
                  input [31:0] first_sector, input [31:0] last_sector,
                  input integer secs);
        integer c; begin
            c = sec*2048 + pgc_sb + cell_pb_off + idx*24;
            img[c+0]  = cat;                                          // category@0
            img[c+4]  = 8'h00;                                        // hh (BCD)
            img[c+5]  = 8'h00;                                        // mm (BCD)
            img[c+6]  = {4'(secs/10), 4'(secs%10)};                   // ss (BCD)
            img[c+7]  = 8'hC0;                                        // rate 3, 0 frames
            img[c+8]  = first_sector[31:24]; img[c+9]  = first_sector[23:16];
            img[c+10] = first_sector[15:8];  img[c+11] = first_sector[7:0];
            img[c+20] = last_sector[31:24];  img[c+21] = last_sector[23:16];
            img[c+22] = last_sector[15:8];   img[c+23] = last_sector[7:0]; end
    endtask

    // Write the DSI fields of a NAV sector (relative to sector start; DSI@0x407).
    // next_vobu is the SAME-ANGLE successor, which is what a real disc writes:
    // MEASURED on MiB VTS_14 RBN 37 (angle 1's BLOCK|LAST), next_vobu = +934 =
    // RBN 971 = sml_agli[angle 1]. It therefore AGREES with sml_agli for the
    // angle you are already playing and DISAGREES for every other one -- which
    // is exactly why sml_agli must be PREFERRED: only it can retarget a
    // mid-block angle switch. (Added 2026-09-15; before this the fixture left
    // the field zero, and a mutation that preferred next_vobu was uncatchable.)
    // vob_id = dsi_gi.vobu_vob_idn, which is what says WHICH ANGLE a VOBU belongs
    // to. Measured on the real discs: every angle cell of a block has a distinct
    // VOB_ID and every VOBU inside that angle's ILVUs carries it.
    task put_nav(input integer rbn, input [15:0] category, input [31:0] vobu_ea,
                 input [31:0] agli0, input [31:0] agli1, input [31:0] next_vobu,
                 input [15:0] vob_id);
        integer b; begin
            b = (24 + rbn) * 2048;
            fill_sec(24 + rbn, 8'h00);
            // DSI PES header + substream id
            // THE NAV-PACK SIGNATURE the reader's VOBU-align probe tests
            // (dvd_iso_reader nav_sig_hit): pack start @0, PS system header @14,
            // PCI PES @38 (0x26). Without these the probe never recognises the
            // sector, exhausts NAV_CAP and falls back to the raw target -- so the
            // snap was never exercised by this bench at all, and TEST D passed
            // for the wrong reason. Offsets verified vs libdvdnav
            // dvdnav_decode_packet.
            img[b+0]  = 8'h00; img[b+1]  = 8'h00; img[b+2]  = 8'h01; img[b+3]  = 8'hBA;
            img[b+14] = 8'h00; img[b+15] = 8'h00; img[b+16] = 8'h01; img[b+17] = 8'hBB;
            img[b+38] = 8'h00; img[b+39] = 8'h00; img[b+40] = 8'h01; img[b+41] = 8'hBF;
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
            // vobu_sri.next_vobu @ DSI 0x13A -> 0x541
            img[b+16'h541]=next_vobu[31:24]; img[b+16'h542]=next_vobu[23:16];
            img[b+16'h543]=next_vobu[15:8];  img[b+16'h544]=next_vobu[7:0];
            // dsi_gi.vobu_vob_idn @ DSI 0x18 -> 0x41F
            img[b+16'h41F]=vob_id[15:8];     img[b+16'h420]=vob_id[7:0];
            // dsi_gi.vobu_c_idn @ DSI 0x1B -> 0x422.  The SAME on every angle, which
            // is what a real disc does -- measured identical on both branches of
            // ALIEN_VS_PREDATOR_SE and The Matrix -- so a filter keyed on the cell
            // id cannot tell the angles apart and TEST G must fail for it.
            img[b+16'h422]=8'd1;
            // sml_pbi.ilvu_ea @ DSI 0x22 -> 0x429: the END of this ILVU, relative to
            // this NAV pack.  Every ILVU here is one nav + one body sector, so it is
            // 1.  ⚠ WITHOUT IT the reader's filtered re-snap falls back to stepping
            // one sector at a time and the ILVU hop this fixture is meant to exercise
            // is never taken -- the landing is the same either way, so nothing fails
            // and the coverage is silently absent.  MEASURED longest sibling run on a
            // real disc: 772 sectors on MiB's 5-angle block, 8298 on
            // ALIEN_VS_PREDATOR_SE, i.e. past NAV_CAP.
            img[b+16'h429]=8'd0; img[b+16'h42A]=8'd0;
            img[b+16'h42B]=8'd0; img[b+16'h42C]=8'd1;
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
            put_rec(cur,24,18*2048,    8'h00,"VTS_01_1.VOB;1",14,cur);

            put_vmgi(19, 32'd1);
            put_tt_srpt(20, 16'd1, 8'd1);
            put_vtsi_mat(21, 32'd1);
            put_pgcit(22, 32'd16, 8'd5, 16'd256);
            // BLOCK 1: cells 0 angle1 (bm=1 FIRST), 1 angle2 (bm=3 LAST).
            // The two angles are the SAME span of film, so they carry the SAME
            // playback_time -- which is exactly how Grave of the Fireflies is
            // authored, and why summing both doubles the title's length.
            put_cell(22, 32'd16, 16'd256, 0, 8'h50, 32'd0,  32'd7,  10);
            put_cell(22, 32'd16, 16'd256, 1, 8'hD0, 32'd2,  32'd5,  10);
            // BLOCK 2: immediately adjacent, no normal cell between (the Grave
            // of the Fireflies shape). The old scan counted straight through
            // these and reported 4 angles for two 2-angle blocks.
            put_cell(22, 32'd16, 16'd256, 2, 8'h50, 32'd8,  32'd15, 20);
            put_cell(22, 32'd16, 16'd256, 3, 8'hD0, 32'd10, 32'd13, 20);
            // common continuation
            put_cell(22, 32'd16, 16'd256, 4, 8'h00, 32'd16, 32'd17, 5);

            // interleaved VOB: nav+body per ILVU, per-angle marker bodies
            // next_vobu (last arg) = this VOBU's OWN angle's next ILVU, or
            // END_OF_CELL where the angle has none left.
            // last arg = vob_idn: block 1 is VOB 1 (angle 1) / VOB 2 (angle 2).
            // The ILVUs round-robin, exactly as the real discs lay them down:
            //   RBN 0-1 a1.i1 | 2-3 a2.i1 | 4-5 a2.i2 | 6-7 a1.i2
            put_nav(0, ILVU_LAST, 32'd1, 32'd6, 32'd2, 32'h80000006, 16'd1);
            fill_sec(24+1, 8'hA1);
            put_nav(2, ILVU_LAST, 32'd1, 32'd4, 32'd2, 32'h80000002, 16'd2);
            fill_sec(24+3, 8'hA2);
            put_nav(4, ILVU_LAST, 32'd1, 32'd2, 32'd4, 32'h3fffffff, 16'd2);
            fill_sec(24+5, 8'hA2);
            put_nav(6, ILVU_LAST, 32'd1, 32'd2, 32'd2, 32'h3fffffff, 16'd1);
            fill_sec(24+7, 8'hA1);
            // ---- BLOCK 2, same layout shifted by 8, VOB 3 / VOB 4 ----
            // ⚠ NOT 1/2 again, and not consecutive with block 1's -- CASTLE_IN_THE_SKY
            // uses 1/2, 4/5, 8/9, so the cell's own VOB_ID must be read rather
            // than derived from the angle index.
            put_nav(8,  ILVU_LAST, 32'd1, 32'd6, 32'd2, 32'h80000006, 16'd3);
            fill_sec(24+9,  8'hB1);
            put_nav(10, ILVU_LAST, 32'd1, 32'd4, 32'd2, 32'h80000002, 16'd4);
            fill_sec(24+11, 8'hB2);
            put_nav(12, ILVU_LAST, 32'd1, 32'd2, 32'd4, 32'h3fffffff, 16'd4);
            fill_sec(24+13, 8'hB2);
            put_nav(14, ILVU_LAST, 32'd1, 32'd2, 32'd2, 32'h3fffffff, 16'd3);
            fill_sec(24+15, 8'hB1);
            fill_sec(24+16, 8'hCC);
            fill_sec(24+17, 8'hCC);
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

        // ============ TEST C: two ADJACENT blocks (Grave of the Fireflies) ======
        // The scan must stop at each block's own bm==3 cell. Pre-fix it counted
        // the whole run of block_type==1 cells: angle_count=4 here (and 9 on the
        // real disc, its cap), and block_last followed, so the end-of-block skip
        // jumped over block 2's angle-1 cell entirely.
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        cap_n = 0; n_a1 = 0; n_a2 = 0; n_b1 = 0; n_b2 = 0; n_cc = 0; max_ac = 0;
        @(posedge clk); start = 1; @(posedge clk); start = 0;
        run_until_done(40000);
        $display("TEST C (adjacent blocks): peak angle_count=%0d  A1=%0d A2=%0d B1=%0d B2=%0d CC=%0d",
                 max_ac, n_a1, n_a2, n_b1, n_b2, n_cc);
        if (max_ac !== 4'd2) begin
            errors=errors+1;
            $display("  FAIL: angle_count=%0d -- the scan ran across the block boundary (want 2)", max_ac);
        end
        if (n_a2 !== 0 || n_b2 !== 0) begin
            errors=errors+1;
            $display("  FAIL: sibling-angle bytes delivered (A2=%0d B2=%0d)", n_a2, n_b2);
        end
        if (n_a1 !== 2*2048) begin
            errors=errors+1; $display("  FAIL: block 1 angle-1 body != 2 sectors (%0d)", n_a1);
        end
        if (n_b1 !== 2*2048) begin
            errors=errors+1;
            $display("  FAIL: block 2 angle-1 body != 2 sectors (%0d) -- block 2 was skipped", n_b1);
        end
        if (n_cc !== 2*2048) begin
            errors=errors+1; $display("  FAIL: common cell != 2 sectors (%0d)", n_cc);
        end

        // ============ TEST D: raw-RBN scrub INTO an angle block ================
        // Land at RBN 6 -- mid-cell inside block 1's angle-1 cell (0..7), on the
        // NAV sector of its second ILVU. NAV-aligned on purpose: the reader's own
        // VOBU-align snap (S_NAV_SEEK, the fj#106 scrub fix) moves a raw scrub
        // target forward to the next NAV pack before it streams, so a nav-aligned
        // landing is what a real disc actually produces. A target landing PAST a
        // nav pack has no DSI to snoop and cannot arm the follow for the ILVU it
        // lands in -- that is a property of ILVU navigation, not of this fix.
        //
        // Expect: the scan runs (angle_count=2), block 1 streams only 0xA1, the
        // end-of-block skip reaches block 2 (0xB1) and then the common cell.
        // Pre-fix the scan was skipped on an rbn_override landing, so
        // angle_active was 0, no follow armed, and cell advance fell through to
        // the SIBLING cell -- 0xA2 bytes, the 1 Hz alternation.
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        cap_n = 0; n_a1 = 0; n_a2 = 0; n_b1 = 0; n_b2 = 0; n_cc = 0; max_ac = 0;
        @(posedge clk); start = 1; @(posedge clk); start = 0;
        // let the mount settle and streaming begin, then scrub
        repeat (40000) @(posedge clk);
        cap_n = 0; n_a1 = 0; n_a2 = 0; n_b1 = 0; n_b2 = 0; n_cc = 0; max_ac = 0;
        @(negedge clk); seek_rbn <= 32'd6; seek_rbn_pulse <= 1'b1;
        @(negedge clk); seek_rbn_pulse <= 1'b0;
        run_until_done(40000);
        $display("TEST D (scrub into a block): angle_count=%0d  A1=%0d A2=%0d B1=%0d B2=%0d CC=%0d",
                 max_ac, n_a1, n_a2, n_b1, n_b2, n_cc);
        // NOTE: max_ac is deliberately NOT asserted here. It is a PEAK, and the
        // block was already scanned during the settling play before the scrub, so
        // it reads 2 on the pre-fix reader too -- an assertion that cannot fail
        // for this defect. The delivered bytes are the property; they read
        // A2=4096 pre-fix and 0 post-fix.
        if (n_a2 !== 0) begin
            errors=errors+1;
            $display("  FAIL: angle-2 bytes after the scrub (%0d) -- no ILVU follow, the angles are ALTERNATING", n_a2);
        end
        if (n_a1 === 0) begin
            errors=errors+1; $display("  FAIL: no angle-1 body delivered after the scrub");
        end
        if (n_b2 !== 0) begin
            errors=errors+1; $display("  FAIL: block-2 sibling bytes delivered (%0d)", n_b2);
        end
        if (n_b1 !== 2*2048) begin
            errors=errors+1;
            $display("  FAIL: block 2 angle-1 body != 2 sectors (%0d) -- the end-of-block skip went wrong", n_b1);
        end

        // ====== TEST G: the scrub lands on the WRONG angle's ILVU ==============
        // Seek to RBN 2 -- a NAV pack, but ANGLE 2's -- while angle 1 is selected.
        // The reader must learn angle 1's VOB_ID from its own cell (cf_rd = RBN 0)
        // and re-snap forward to RBN 6, the next VOBU carrying that VOB_ID. It
        // must deliver NO 0xA2.
        // Pre-fix it streamed from RBN 2: the sibling's ILVU (0xA2) played until
        // the ILVU end, then the sml_agli follow converged. That is the reported
        // "quick glance of the storyboard angle before it settles on the film" --
        // and on a disc with no sml_agli it never converges at all.
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        cap_n = 0; n_a1 = 0; n_a2 = 0; n_b1 = 0; n_b2 = 0; n_cc = 0; max_ac = 0;
        @(posedge clk); start = 1; @(posedge clk); start = 0;
        repeat (40000) @(posedge clk);
        cap_n = 0; n_a1 = 0; n_a2 = 0; n_b1 = 0; n_b2 = 0; n_cc = 0; max_ac = 0;
        @(negedge clk); seek_rbn <= 32'd2; seek_rbn_pulse <= 1'b1;
        @(negedge clk); seek_rbn_pulse <= 1'b0;
        run_until_done(40000);
        $display("TEST G (scrub onto the wrong angle): A1=%0d A2=%0d B1=%0d B2=%0d CC=%0d",
                 n_a1, n_a2, n_b1, n_b2, n_cc);
        if (n_a2 !== 0) begin
            errors=errors+1;
            $display("  FAIL: %0d sibling-angle bytes -- the scrub stayed on the wrong angle", n_a2);
        end
        if (n_a1 === 0) begin
            errors=errors+1; $display("  FAIL: no angle-1 body after the re-snap");
        end

        // ============ TEST E: a block occupies ONE slot on the timeline =========
        // Durations: block 1 = 10 s (both its cells), block 2 = 20 s (both), the
        // common cell 5 s. A viewer sees ONE angle of each block, so the title
        // runs 10 + 20 + 5 = 35 s. Summing every cell gives 65 -- and that is
        // what shipped: MEASURED on Grave of the Fireflies, whose elapsed
        // readout reaches 2:58:45 on a 1:30:03 title, and whose overlapping
        // sibling cells made seek_time publish the SIBLING's start (+8:00 during
        // chapter 1, its own length) for any target past the sibling's first
        // sector.
        $display("TEST E (timeline): title_secs=%0d (want 35; summing siblings gives 65)",
                 title_secs);
        if (title_secs !== 16'd35) begin
            errors=errors+1;
            $display("  FAIL: a multi-angle block counted more than once on the timeline");
        end

        // ============ TEST F: each cell's START, not just the total ============
        // Durations 10/10 (block 1), 20/20 (block 2), 5 (common). A block is one
        // slot, so the starts are 0, 0, 10, 10, 30 -- the SIBLING inherits the
        // block-first cell's start.
        // ⚠ This arm exists because TEST E did not catch a real defect: summing
        // correctly (35) while handing every sibling the start of the NEXT block
        // (0, 10, 10, 30, 30). seek_time picks the sibling by its
        // nearest-at-or-below rule, so the preview read 8:00 on Grave of the
        // Fireflies and never moved, because it interpolated between two
        // identical values. A total can be right while every constituent is
        // wrong.
        $display("TEST F (cell starts): %0d %0d %0d %0d %0d  (want 0 0 10 10 30)",
                 cstart[0], cstart[1], cstart[2], cstart[3], cstart[4]);
        if (cstart[0] !== 0 || cstart[1] !== 0)
            begin errors=errors+1; $display("  FAIL: block 1's sibling does not share its start"); end
        if (cstart[2] !== 10 || cstart[3] !== 10)
            begin errors=errors+1; $display("  FAIL: block 2's start/sibling wrong"); end
        if (cstart[4] !== 30)
            begin errors=errors+1; $display("  FAIL: the common cell starts at the wrong time"); end

        if (errors == 0) $display("ISO_READER_ANGLE_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_ANGLE_TB: %0d FAILURE(S)", errors);
        $finish;
    end

    initial begin #200000000; $display("TIMEOUT"); $finish; end

endmodule
