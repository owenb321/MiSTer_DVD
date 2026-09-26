// iso_reader_branch_tb.sv - a raw-RBN SEEK into a SEAMLESS-BRANCH interleaved
// block must land on the branch being played, not on whichever branch's ILVU the
// target happened to fall in.  (issue #49)
//
// A seamless-branch block (Matrix "Follow the White Rabbit", T2 Ultimate extended
// scenes, ALIEN_VS_PREDATOR_SE theatrical/extended) is an interleaved cell -
// category byte0 bit 2, block_type 0 - whose [first..last] range physically
// interleaves THIS branch's ILVUs with the sibling branch's.  Playback follows
// vobu_sri.next_vobu and is HW-CONFIRMED (PR fj#112).  SEEKING was never covered:
// the VOBU-align snap moves the target FORWARD to the next NAV pack, which belongs
// to whichever branch owns that ILVU, and next_vobu then follows the chain you are
// standing in - so the rest of the block plays the other cut and never converges.
//
// MEASURED sibling share of a cell's span (how often a scrub lands wrong):
//   Matrix VTS_02 cell 36  ~50 %      AVP VTS_03 cell 23  73 %
//   T2 VTS_01 cell 16      85 %
// MEASURED escape distance (how far forward the next same-branch VOBU is):
//   Matrix <= 877 sectors / 4 VOBUs      T2 <= 4543 / 20      AVP <= 8298 / 37
// so a walk that steps ONE SECTOR at a time cannot reach it inside NAV_CAP=1024
// on two of the three discs.  sml_pbi.ilvu_ea (DSI 0x22 -> sector 0x429) is
// authored on every VOBU of all four discs checked and names the END of the ILVU
// you are standing in, so ilvu_ea+1 is the next ILVU's first VOBU: 1-3 hops.
//
// MEASURED premise the filter rests on - every branch of a block is its own VOB:
//   AVP    VTS_03 cell 1   played vob 2,  sibling vob 3
//   Matrix VTS_02 cell 4   played vob 4,  sibling vob 5
//   T2     VTS_01 cell 10  played vob 4,  sibling vob 3   <- LOWER
//   T2     VTS_01 cell 33  played vob 16, siblings 15 AND 17
// and dsi_gi.vobu_c_idn does NOT discriminate (measured identical on both
// branches), so a rule keyed on the cell id, or on an index step from the cell's
// own id, is wrong on a real disc.  The fixtures below use those shapes.
//
// Every arm scores the DELIVERED MARKER BYTES - which branch's sectors actually
// reached the decoder - never a signal the fix names.
//
//   ARM 1  target inside a sibling ILVU's BODY (the snap must walk, then filter)
//   ARM 2  target ON the sibling's NAV pack, NAV_CAP=4: only an ILVU-sized hop
//          fits the budget; a sector walk exhausts it and streams the sibling
//   ARM 3  THREE branches (15/16/17, playing 16) - two hops, and no index rule
//   ARM 4  ilvu_ea zeroed: the +1-sector degrade must still land and terminate
//   ARM 5  NO seek at all - pure playback, with a read-count ceiling.  This is
//          the arm that catches a probe firing on the mid-block ILVU hop, whose
//          contract is time-continuity; the outcome stays correct there, so the
//          read count is the only tell (the angle round's TEST D `A1` lesson).
//   ARM 6  a TRAILING sibling ILVU at the cell end, with the NEXT cell opening on
//          a NAV pack that carries the played branch's VOB_ID: the walk must stop
//          at the cell end rather than retarget outside the cell it is filtering.
//
// Select with  -Piso_reader_branch_tb.ARM=n .

`timescale 1ns/1ps

module iso_reader_branch_tb;

    parameter ARM = 1;

    // ARM 2 is the budget arm: an ILVU hop costs ONE probe, a sector walk costs 8.
    localparam NAVCAP = (ARM == 2) ? 4 : 1024;

    localparam IMG_BYTES = 96*2048;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [63:0] file_size = 0;

    reg         seek_rbn_pulse = 0;
    reg  [31:0] seek_rbn = 32'd0;

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

    // ---- marker counters: which branch's sectors were delivered ----
    // 0xA1 = the branch being played.  0x5B / 0xB5 / 0xC7 = siblings, which must
    // not reach the decoder.  0xEE = the common continuation cell.  0xDD = the
    // NEXT cell (ARM 6 only), reachable legitimately by cell advance.
    // ⚠ NO marker may be 0x00, 0x01, 0xBA, 0xBB or 0xBF: put_nav writes those
    // into every NAV sector as the pack / system-header / PCI signature, and a
    // marker that collides with one is counted out of the reader's own fixture.
    // 0xBB did, and it read as 5 leaked sibling bytes in plain playback.
    integer cap_n = 0;
    integer n_a1 = 0, n_bb = 0, n_b5 = 0, n_c7 = 0, n_ee = 0, n_dd = 0;
    integer n_reads = 0;
    reg     seam_seen = 0;

    always @(posedge clk) begin
        if (dut.seamless_active) seam_seen <= 1'b1;
        if (stream_valid) begin
            cap_n = cap_n + 1;
            case (stream_data)
                8'hA1: n_a1 = n_a1 + 1;
                8'h5B: n_bb = n_bb + 1;
                8'hB5: n_b5 = n_b5 + 1;
                8'hC7: n_c7 = n_c7 + 1;
                8'hEE: n_ee = n_ee + 1;
                8'hDD: n_dd = n_dd + 1;
            endcase
        end
    end

    dvd_iso_reader #(.NAV_CAP(NAVCAP)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size),
        .title_sel(7'd0), .aud_drained(1'b1), .vbuf_empty(1'b0), 
        .jump_ttn(7'd0), .jump_pgn(8'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_pulse(1'b0), .seek_natural(1'b0), .seek_cell(8'd0), .seek_ack(),
        .seek_rbn_pulse(seek_rbn_pulse), .seek_rbn(seek_rbn), .seek_tm_req(1'b0), .seek_tm_secs(17'd0),
        .chap_pulse(1'b0), .chap_dir(1'b0), .chap_mag(5'd1), .chap_at_start(1'b0),
        .angle_pulse(1'b0), .cur_angle(), .angle_count(),
        .agl_vm(4'd0), .agl_vm_en(1'b0), .vm_pre_done(1'b0),
        .keep_vbuf(),
        .cur_cell(), .cell_ready(), .cell_seamless(),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .debug_active(),   
         .debug_iso_mode() 
    );

    always #5 clk = ~clk;

    // ---- mock HPS: one 2048-byte sector per sd_rd ----
    integer m = 0, bc = 0, lat = 0;
    reg [31:0] rlba = 0;
    always @(posedge clk) begin
        sd_buff_wr <= 1'b0;
        case (m)
        0: begin sd_ack <= 1'b0;
              if (sd_rd) begin rlba <= sd_lba; lat <= 3; n_reads = n_reads + 1; m <= 1; end end
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

    // ---- image builders (shared skeleton with iso_reader_ilvu_tb) ----
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

    // A full NAV pack for the seek path.
    // ⚠⚠ THE SIGNATURE BYTES ARE LOAD-BEARING and are what iso_reader_ilvu_tb's
    // own put_nav_seam still omits: the reader's VOBU-align probe tests pack start
    // 00 00 01 BA @0, PS system header 00 00 01 BB @14 and PCI PES 00 00 01 BF @38
    // (nav_sig_hit).  Without them nav_sig_hit is false for every sector, the probe
    // exhausts NAV_CAP on every scrub and falls back to the raw target - so the snap
    // is never exercised and the arm passes for the wrong reason.  That is exactly
    // how iso_reader_angle_tb TEST G failed on the FIXED reader.
    // Offsets verified against libdvdnav dvdnav_decode_packet.
    task put_nav(input integer rbn, input [15:0] category,
                 input [31:0] vobu_ea, input [31:0] ilvu_ea,
                 input [31:0] next_vobu, input [15:0] vob_id);
        integer b; begin
            b = (24 + rbn) * 2048;
            fill_sec(24 + rbn, 8'h00);
            img[b+0]  = 8'h00; img[b+1]  = 8'h00; img[b+2]  = 8'h01; img[b+3]  = 8'hBA;
            img[b+14] = 8'h00; img[b+15] = 8'h00; img[b+16] = 8'h01; img[b+17] = 8'hBB;
            img[b+38] = 8'h00; img[b+39] = 8'h00; img[b+40] = 8'h01; img[b+41] = 8'hBF;
            // DSI PES header + substream id
            img[b+16'h400]=8'h00; img[b+16'h401]=8'h00; img[b+16'h402]=8'h01; img[b+16'h403]=8'hBF;
            img[b+16'h406]=8'h01;
            // dsi_gi.vobu_ea @ DSI 0x08 -> 0x40F
            img[b+16'h40F]=vobu_ea[31:24]; img[b+16'h410]=vobu_ea[23:16];
            img[b+16'h411]=vobu_ea[15:8];  img[b+16'h412]=vobu_ea[7:0];
            // dsi_gi.vobu_vob_idn @ DSI 0x18 -> 0x41F
            img[b+16'h41F]=vob_id[15:8];   img[b+16'h420]=vob_id[7:0];
            // dsi_gi.vobu_c_idn @ DSI 0x1B -> 0x422.  DELIBERATELY THE SAME on every
            // branch: measured identical on both branches of AVP and Matrix, so a
            // filter keyed on the cell id must fail these arms.
            img[b+16'h422]=8'd1;
            // sml_pbi.category @ DSI 0x20 -> 0x427
            img[b+16'h427]=category[15:8]; img[b+16'h428]=category[7:0];
            // sml_pbi.ilvu_ea @ DSI 0x22 -> 0x429
            img[b+16'h429]=ilvu_ea[31:24]; img[b+16'h42A]=ilvu_ea[23:16];
            img[b+16'h42B]=ilvu_ea[15:8];  img[b+16'h42C]=ilvu_ea[7:0];
            // vobu_sri.next_vobu @ DSI 0x13A -> 0x541
            img[b+16'h541]=next_vobu[31:24]; img[b+16'h542]=next_vobu[23:16];
            img[b+16'h543]=next_vobu[15:8];  img[b+16'h544]=next_vobu[7:0];
        end
    endtask

    localparam [15:0] ILVU_FIRST = 16'h6000;                // BLOCK|FIRST
    localparam [15:0] ILVU_LAST  = 16'h5000;                // BLOCK|LAST
    localparam [31:0] SRI_END    = 32'h3fffffff;            // END_OF_CELL
    localparam [31:0] SRI_VALID  = 32'h80000000;            // SRI "valid" flag (fwd)

    // One ILVU = 2 VOBUs x 4 sectors (1 nav + 3 body).  `ie` selects whether the
    // fixture authors ilvu_ea at all (ARM 4 zeroes it to exercise the degrade).
    task put_ilvu(input integer rbn, input [15:0] vob, input [7:0] marker,
                  input [31:0] next_after, input integer ie);
        integer k; begin
            // VOBU 1: BLOCK|FIRST, next_vobu -> VOBU 2 (contiguous)
            put_nav(rbn, ILVU_FIRST, 32'd3, ie ? 32'd7 : 32'd0,
                    SRI_VALID | 32'd4, vob);
            for (k=1;k<4;k=k+1) fill_sec(24+rbn+k, marker);
            // VOBU 2: BLOCK|LAST, next_vobu -> this branch's NEXT ILVU
            put_nav(rbn+4, ILVU_LAST, 32'd3, ie ? 32'd3 : 32'd0, next_after, vob);
            for (k=1;k<4;k=k+1) fill_sec(24+rbn+4+k, marker);
        end
    endtask

    // ISO skeleton + PGC, shared by every arm.  vob_sectors sizes VTS_01_1.VOB.
    task put_skeleton(input integer vob_sectors, input [7:0] nr_cells);
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
            put_rec(cur,19,4096,              8'h00,"VIDEO_TS.IFO;1",14,cur);
            put_rec(cur,21,6144,              8'h00,"VTS_01_0.IFO;1",14,cur);
            put_rec(cur,24,vob_sectors*2048,  8'h00,"VTS_01_1.VOB;1",14,cur);
            put_vmgi(19, 32'd1);
            put_tt_srpt(20, 16'd1, 8'd1);
            put_vtsi_mat(21, 32'd1);
            put_pgcit(22, 32'd16, nr_cells, 16'd256);
        end
    endtask

    // 0x0E = seamless_play | interleaved | stc_discontinuity -- the exact category
    // byte measured on every Matrix white-rabbit cell and on AVP's 0x0e cells.
    localparam [7:0] CAT_ILVU  = 8'h0E;
    localparam [7:0] CAT_PLAIN = 8'h00;

    integer tgt;

    // MEASURED on the fixed reader with ARM 5's fixture: 35 sector reads.  The
    // ceiling is 36, not a round 40: a LEARN+FILT probe fired on the mid-block ILVU
    // hop costs +2 reads per hop and this fixture has 2 hops, so a ceiling of 40
    // would sit ABOVE the defect and catch nothing.
    localparam READ_MAX = 36;

    task build_iso;
        begin
            case (ARM)
            // ---- ARMS 1, 2, 4: two branches, played vob 4, sibling vob 3 -------
            // The sibling id is LOWER than the played branch's, which is the
            // measured T2 VTS_01 cell-10 shape and kills any "+1" index rule.
            //   0..7  A.i1   8..15 B.i1   16..23 A.i2   24..31 B.i2   32..39 A.i3
            //   40,41 common cell
            1, 2, 4: begin
                put_skeleton(44, 8'd2);
                put_cell(22, 32'd16, 16'd256, 0, CAT_ILVU,  32'd0,  32'd39);
                put_cell(22, 32'd16, 16'd256, 1, CAT_PLAIN, 32'd40, 32'd41);
                put_ilvu( 0, 16'd4, 8'hA1, SRI_VALID | 32'd12, (ARM == 4) ? 0 : 1);
                put_ilvu( 8, 16'd3, 8'h5B, SRI_VALID | 32'd12, (ARM == 4) ? 0 : 1);
                put_ilvu(16, 16'd4, 8'hA1, SRI_VALID | 32'd12, (ARM == 4) ? 0 : 1);
                put_ilvu(24, 16'd3, 8'h5B, SRI_END,            (ARM == 4) ? 0 : 1);
                put_ilvu(32, 16'd4, 8'hA1, SRI_END,            (ARM == 4) ? 0 : 1);
                fill_sec(24+40, 8'hEE);
                fill_sec(24+41, 8'hEE);
                // ARM 1 lands in the sibling's BODY (the snap must walk to RBN 12
                // first, which is the sibling's own NAV pack).  ARM 2 lands ON the
                // sibling's NAV pack, so the snap accepts at once and the whole
                // budget is left to the filter.
                tgt = (ARM == 2) ? 8 : 9;
            end
            // ---- ARM 3: THREE branches, playing vob 16, siblings 15 and 17 -----
            // The measured T2 VTS_01 cell-33 shape.  The target sits in the
            // FARTHEST sibling, so the walk must hop TWICE.
            //   0..7 A.i1(16)  8..15 C.i1(17)  16..23 B.i1(15)
            //  24..31 A.i2(16) 32..39 C.i2(17) 40..47 B.i2(15)
            //  48..55 A.i3(16) 56,57 common
            3: begin
                put_skeleton(60, 8'd2);
                put_cell(22, 32'd16, 16'd256, 0, CAT_ILVU,  32'd0,  32'd55);
                put_cell(22, 32'd16, 16'd256, 1, CAT_PLAIN, 32'd56, 32'd57);
                put_ilvu( 0, 16'd16, 8'hA1, SRI_VALID | 32'd20, 1);
                put_ilvu( 8, 16'd17, 8'hC7, SRI_VALID | 32'd20, 1);
                put_ilvu(16, 16'd15, 8'hB5, SRI_VALID | 32'd20, 1);
                put_ilvu(24, 16'd16, 8'hA1, SRI_VALID | 32'd20, 1);
                put_ilvu(32, 16'd17, 8'hC7, SRI_END,            1);
                put_ilvu(40, 16'd15, 8'hB5, SRI_END,            1);
                put_ilvu(48, 16'd16, 8'hA1, SRI_END,            1);
                fill_sec(24+56, 8'hEE);
                fill_sec(24+57, 8'hEE);
                tgt = 8;                       // inside C.i1: hop C -> B -> A
            end
            // ---- ARM 5: no seek.  Pure playback + a read-count ceiling. --------
            5: begin
                put_skeleton(44, 8'd2);
                put_cell(22, 32'd16, 16'd256, 0, CAT_ILVU,  32'd0,  32'd39);
                put_cell(22, 32'd16, 16'd256, 1, CAT_PLAIN, 32'd40, 32'd41);
                put_ilvu( 0, 16'd4, 8'hA1, SRI_VALID | 32'd12, 1);
                put_ilvu( 8, 16'd3, 8'h5B, SRI_VALID | 32'd12, 1);
                put_ilvu(16, 16'd4, 8'hA1, SRI_VALID | 32'd12, 1);
                put_ilvu(24, 16'd3, 8'h5B, SRI_END,            1);
                put_ilvu(32, 16'd4, 8'hA1, SRI_END,            1);
                fill_sec(24+40, 8'hEE);
                fill_sec(24+41, 8'hEE);
                tgt = -1;                      // no seek
            end
            // ---- ARM 6: a TRAILING sibling ILVU at the cell end ----------------
            // The next cell opens on a NAV pack carrying the PLAYED branch's
            // VOB_ID, so a filter walk that does not stop at the cell end will
            // happily accept a sector belonging to another cell while cell_i and
            // play_end still describe this one.
            //   0..7 A.i1  8..15 B.i1  16..23 A.i2(END)  24..31 B.i2 (trailing)
            //   cell 1: 32..39, opening on a vob-4 NAV pack, bodies 0xDD
            6: begin
                put_skeleton(44, 8'd2);
                put_cell(22, 32'd16, 16'd256, 0, CAT_ILVU,  32'd0,  32'd31);
                put_cell(22, 32'd16, 16'd256, 1, CAT_PLAIN, 32'd32, 32'd39);
                put_ilvu( 0, 16'd4, 8'hA1, SRI_VALID | 32'd16, 1);
                put_ilvu( 8, 16'd3, 8'h5B, SRI_VALID | 32'd16, 1);
                put_ilvu(16, 16'd4, 8'hA1, SRI_END,            1);
                put_ilvu(24, 16'd3, 8'h5B, SRI_END,            1);
                put_ilvu(32, 16'd4, 8'hDD, SRI_END,            1);
                tgt = 24;                      // inside the trailing sibling
            end
            endcase
        end
    endtask

    // Run until the byte stream has been QUIET for `idle` cycles, or the global cap
    // expires.  WARNING: `idle` must exceed the longest SILENCE the reader can
    // properly produce, and a probe sequence is exactly that -- the mock HPS serves
    // one byte per cycle, so every probe sector read is ~2100 quiet cycles and a
    // filter walk of a dozen reads is ~25k.  At idle=20000 the degrade arm gave up
    // mid-walk and reported nothing delivered, which is indistinguishable from a
    // wedged reader.  ⚠ NOT a byte-count target: the arms deliver different totals, and a
    // target set below an arm's total truncates playback part-way -- which presents
    // as a missing common cell and reads exactly like a real failure.
    task run_until_idle(input integer idle);
        integer tt, quiet, last; begin
            // ⚠ Wait for the FIRST byte before arming the idle test: the ISO mount
            // parse takes tens of thousands of cycles with nothing streaming, and an
            // idle test armed at t=0 exits before playback has begun -- which reads
            // as "nothing was delivered" rather than "the bench gave up".
            tt = 0;
            while (cap_n == 0 && tt < 4000000) begin @(posedge clk); tt = tt + 1; end
            quiet = 0; last = cap_n;
            while (tt < 4000000 && quiet < idle) begin
                @(posedge clk); tt = tt + 1;
                if (cap_n != last) begin last = cap_n; quiet = 0; end
                else quiet = quiet + 1;
            end
        end
    endtask

    integer errors = 0;

    initial begin
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);

        build_iso;
        file_size = IMG_BYTES;
        @(posedge clk); start = 1; @(posedge clk); start = 0;

        if (tgt >= 0) begin
            // Let the mount settle and streaming begin, then scrub -- the same
            // shape a real gesture has.
            repeat (40000) @(posedge clk);
            cap_n = 0; n_a1 = 0; n_bb = 0; n_b5 = 0; n_c7 = 0; n_ee = 0; n_dd = 0;
            n_reads = 0;
            @(negedge clk); seek_rbn <= tgt; seek_rbn_pulse <= 1'b1;
            @(negedge clk); seek_rbn_pulse <= 1'b0;
        end
        run_until_idle(100000);

        $display("ARM %0d (NAV_CAP=%0d, target=%0d): seamless=%0d A1=%0d BB=%0d B5=%0d C7=%0d EE=%0d DD=%0d reads=%0d",
                 ARM, NAVCAP, tgt, seam_seen, n_a1, n_bb, n_b5, n_c7, n_ee, n_dd, n_reads);

        if (!seam_seen) begin
            errors=errors+1; $display("  FAIL: seamless_active never asserted");
        end

        case (ARM)
        1, 2, 4: begin
            if (n_bb !== 0) begin
                errors=errors+1;
                $display("  FAIL: %0d sibling-branch bytes after the scrub -- the seek landed in the OTHER CUT and stayed there", n_bb);
            end
            if (n_a1 === 0) begin
                errors=errors+1; $display("  FAIL: no played-branch body after the scrub");
            end
            if (n_ee !== 2*2048) begin
                errors=errors+1;
                $display("  FAIL: common cell != 2 sectors (%0d)", n_ee);
            end
        end
        3: begin
            if (n_c7 !== 0 || n_b5 !== 0) begin
                errors=errors+1;
                $display("  FAIL: sibling bytes after the scrub (vob17=%0d vob15=%0d) -- landed on the wrong branch of a 3-branch block", n_c7, n_b5);
            end
            if (n_a1 === 0) begin
                errors=errors+1; $display("  FAIL: no played-branch body after the scrub");
            end
            if (n_ee !== 2*2048) begin
                errors=errors+1;
                $display("  FAIL: common cell != 2 sectors (%0d)", n_ee);
            end
        end
        5: begin
            // Pure playback: the ILVU follow delivers 3 ILVUs x 6 body sectors.
            if (n_bb !== 0) begin
                errors=errors+1; $display("  FAIL: sibling bytes in plain playback (%0d)", n_bb);
            end
            if (n_a1 !== 18*2048) begin
                errors=errors+1;
                $display("  FAIL: played-branch body != 18 sectors (%0d)", n_a1);
            end
            if (n_ee !== 2*2048) begin
                errors=errors+1; $display("  FAIL: common cell != 2 sectors (%0d)", n_ee);
            end
            // ⚠ THE READ CEILING IS THE ONLY TELL for a probe that fires on the
            // mid-block ILVU hop.  That hop's contract is time-continuity -- no
            // flush, no seek_ack, no A/V re-anchor -- and a probe there still
            // produces the CORRECT bytes, just with an extra read and mid-stream
            // latency.  It would reach hardware as a stutter at an ILVU boundary
            // and be blamed on something else.  READ_MAX is measured on the fixed
            // reader; a hop-fired probe adds 2 reads per hop.
            if (n_reads > READ_MAX) begin
                errors=errors+1;
                $display("  FAIL: %0d sector reads for plain playback (ceiling %0d) -- a seek probe is firing on the mid-block ILVU hop",
                         n_reads, READ_MAX);
            end
        end
        6: begin
            // The walk must stop at the cell's own last sector.  Falling back to
            // the unfiltered landing is the ACCEPTED, DOCUMENTED residual for a
            // target in a block's final sibling ILVU -- so sibling bytes here are
            // the correct outcome, and their ABSENCE means the filter walked out
            // of the cell it was filtering and retargeted into the next one.
            if (n_bb === 0) begin
                errors=errors+1;
                $display("  FAIL: the filter walked PAST the cell end -- it accepted a NAV pack belonging to the next cell while cell_i/play_end still describe this one");
            end
        end
        endcase

        if (errors == 0) $display("ISO_READER_BRANCH_TB: ALL TESTS PASSED");
        else             $display("ISO_READER_BRANCH_TB: %0d FAILURE(S)", errors);
        $finish;
    end

    initial begin #300000000; $display("TIMEOUT"); $finish; end

endmodule
