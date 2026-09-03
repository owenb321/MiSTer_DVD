`timescale 1ns/1ps
//
// mode_realign_chain_tb.sv — THE PROOF for issue #42, measured in the delivered bytes.
//
// dvd/mode_realign.sv + dvd/flush_ctl.sv + the REAL dvd/dvd_iso_reader.sv over a
// synthetic DVD image (fixture skeleton shared with bench/dvd/iso_reader_seek_tb.sv).
//
// ★ WHAT IS MEASURED, AND WHY IT IS THIS. The bug was never visible in a signal: the
// trio fired correctly, on time, with the right levels. What was wrong was WHERE IN THE
// BYTE STREAM it landed -- mid-VOBU, so the decoder had no GOP boundary to re-lock on.
// So this bench fires one raster-mode change while the reader is mid-VOBU and then reads
// the FIRST BYTES DELIVERED AFTER THE FLUSH, checking them against the 12-byte NAV-pack
// signature (00 00 01 BA @0, 00 00 01 BB @14, 00 00 01 BF @38 -- the same bytes the
// reader's own VOBU-snap probe matches, and the definition of a VOBU boundary).
//
//   pre-fix (+realign=0): the reader never moves, so the stream continues from wherever
//                         it was -- the bytes after the flush are mid-sector payload.
//   fixed:                the re-align seeks to the current VOBU, so the bytes after the
//                         flush ARE a NAV pack.
//
// That criterion is external to the RTL: it is a property of the byte stream, not a
// re-statement of any expression inside the design. bench/dvd/field_parity_tb.sv is the
// cautionary tale (CLAUDE.md) -- its pass condition was the same expression as the RTL's,
// so it agreed with the defect by construction.
//
// ⚠ The playhead (dsi_nv_pck_lbn) is modelled HERE rather than by instantiating nav_dsi
// and ps_demux: it is an INPUT to the module under test, and modelling it keeps the
// fixture honest -- the bench knows which sector is streaming because it counts the bytes
// it received, so a wrong latched target shows up as a wrong seek.
//
// NAV packs sit at every 5th title sector (RBN 0,5,10,...), i.e. 5-sector VOBUs. Sectors
// in between are deliberately NOT NAV packs, or a mid-VOBU landing would look aligned and
// the pre-fix arm would pass.
//
// Build/run: bench/dvd/run_mode_realign.sh   (or, standalone)
//   iverilog -g2012 -o bench/dvd/mode_realign_chain_sim \
//       dvd/dvd_iso_reader.sv dvd/flush_ctl.sv dvd/mode_realign.sv \
//       bench/dvd/mode_realign_chain_tb.sv
//   vvp bench/dvd/mode_realign_chain_sim             # GREEN
//   vvp bench/dvd/mode_realign_chain_sim +realign=0  # RED — failure EXPECTED
//

module mode_realign_chain_tb;

    localparam CELLSEC   = 10;              // sectors per cell (> 16 KB cache)
    localparam VOBSEC    = 4*CELLSEC;       // 40 title sectors
    localparam IMG_BYTES = 64*2048;
    localparam SECBYTES  = 2048;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [63:0] file_size = 0;

    // Forward declarations: Icarus requires declaration before use, and the reader
    // instance below is fed by nets the chain further down drives.
    wire        rd_seek_pulse;
    wire [31:0] rd_seek_rbn;
    wire        mr_sp, mr_ms, mr_pend, mr_blank;
    wire [31:0] mr_srbn;
    wire        load_flush, aud_flush, aud_resync, seek_flush, mount_flush;
    wire        pipe_rst_n, aud_rst_n;

    // transport seek port
    reg         seek_pulse = 0;
    reg  [7:0]  seek_cell = 0;
    wire        seek_ack;
    wire [7:0]  cur_cell;
    wire        cell_ready;

    wire [31:0] sd_lba;
    wire        sd_rd;
    reg         sd_ack = 0;
    reg  [13:0] sd_buff_addr = 0;
    reg  [7:0]  sd_buff_dout = 0;
    reg         sd_buff_wr = 0;

    wire [7:0]  stream_data;
    wire        stream_valid;
    reg         busy = 0;

    wire        debug_iso_mode, debug_iso_error;
    wire [15:0] debug_state;

    reg  [7:0]  img [0:IMG_BYTES-1];

    // ---- capture (rolling) ----
    integer cap_n = 0;
    reg [7:0] cap [0:65535];
    always @(posedge clk)
        if (stream_valid) begin
            cap[cap_n] = stream_data;
            cap_n = cap_n + 1;
        end

    // ---- seek_ack sticky monitor (per-window) ----
    wire keep_vbuf;
    reg ack_seen = 0;
    reg kv_at_seek = 1'bx;   // keep_vbuf captured at the transport seek_ack
    always @(posedge clk) if (seek_ack) begin ack_seen <= 1'b1; kv_at_seek <= keep_vbuf; end

    // NAV_CAP(8): a small VOBU-align probe budget so TEST7 can exhaust it on this
    // 40-sector title (TEST8 exercises the title-end clamp before the budget runs).
    dvd_iso_reader #(.NAV_CAP(8)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(7'd0), .vbuf_empty(1'b0), .menu_snap(1'b0),
        // Phase-4 DVD-VM ports: legacy mode (vm_mode=0 keeps prior behaviour)
        .jump_ttn(7'd0), .jump_pgn(8'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_pulse(seek_pulse), .seek_natural(1'b0), .seek_cell(seek_cell), .seek_ack(seek_ack),
        .seek_rbn_pulse(rd_seek_pulse), .seek_rbn(rd_seek_rbn),
        .chap_pulse(1'b0), .chap_dir(1'b0), .chap_mag(5'd1),
        .keep_vbuf(keep_vbuf),
        .cur_cell(cur_cell), .cell_ready(cell_ready),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
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

    // ---- image builders (shared skeleton with iso_reader_pgc_tb) ----
    integer i;
    integer cur;

    task fill_sec(input integer sec, input [7:0] v);
        integer j;
        begin
            for (j = 0; j < 2048; j = j + 1) img[sec*2048 + j] = v;
        end
    endtask

    // Overlay a NAV-pack (VOBU-first) signature onto an already-marker-filled VOB
    // sector at title RBN `rbn` (= image sector 24+rbn). The reader's nav_sig_hit
    // matches on bytes 0-3=00 00 01 BA, 14-17=00 00 01 BB, 38-41=00 00 01 BF; the
    // rest of the sector keeps its cell marker. Extra fields (pack marker@4,
    // stuffing@13, system-header length@18) are cosmetic realism.
    task put_nav(input integer rbn);
        integer base;
        begin
            base = (24 + rbn) * 2048;
            img[base+0]  = 8'h00; img[base+1]  = 8'h00; img[base+2]  = 8'h01; img[base+3]  = 8'hBA;
            img[base+4]  = 8'h44;                        // MPEG-2 pack marker
            img[base+13] = 8'hF8;                        // stuffing_length = 0
            img[base+14] = 8'h00; img[base+15] = 8'h00; img[base+16] = 8'h01; img[base+17] = 8'hBB;
            img[base+18] = 8'h00; img[base+19] = 8'h12; // system_header length
            img[base+38] = 8'h00; img[base+39] = 8'h00; img[base+40] = 8'h01; img[base+41] = 8'hBF;
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

    task put_vmgi(input integer sec, input [31:0] tt_srpt_ptr);
        integer base;
        begin
            base = sec*2048;
            img[base+196] = tt_srpt_ptr[31:24]; img[base+197] = tt_srpt_ptr[23:16];
            img[base+198] = tt_srpt_ptr[15:8];  img[base+199] = tt_srpt_ptr[7:0];
        end
    endtask

    task put_tt_srpt(input integer sec, input [15:0] nsrpts, input [7:0] title1_vtsn);
        integer base;
        begin
            base = sec*2048;
            img[base+0] = nsrpts[15:8]; img[base+1] = nsrpts[7:0];
            img[base+8]  = 8'h00; img[base+9] = 8'h01;
            img[base+10] = 8'h00; img[base+11] = 8'h01;
            img[base+12] = 8'h00; img[base+13] = 8'h00;
            img[base+14] = title1_vtsn;
            img[base+15] = 8'h01;
        end
    endtask

    task put_vtsi_mat(input integer sec, input [31:0] vts_pgcit_ptr);
        integer base;
        begin
            base = sec*2048;
            img[base+204] = vts_pgcit_ptr[31:24]; img[base+205] = vts_pgcit_ptr[23:16];
            img[base+206] = vts_pgcit_ptr[15:8];  img[base+207] = vts_pgcit_ptr[7:0];
        end
    endtask

    task put_pgcit(input integer sec, input [31:0] pgc_start_byte,
                   input [7:0] nr_cells, input [15:0] cell_pb_off);
        integer base; integer pgc;
        begin
            base = sec*2048;
            img[base+0] = 8'h00; img[base+1] = 8'h01;    // nr_of_pgci_srp = 1
            img[base+12] = pgc_start_byte[31:24]; img[base+13] = pgc_start_byte[23:16];
            img[base+14] = pgc_start_byte[15:8];  img[base+15] = pgc_start_byte[7:0];
            pgc = base + pgc_start_byte;
            img[pgc+2] = 8'h01;                  // nr_of_programs
            img[pgc+3] = nr_cells;               // nr_of_cells
            img[pgc+232] = cell_pb_off[15:8];    // cell_playback_offset (BE u16)
            img[pgc+233] = cell_pb_off[7:0];
        end
    endtask

    task put_cell(input integer sec, input [31:0] pgc_start_byte,
                  input [15:0] cell_pb_off, input integer idx,
                  input [31:0] first_sector, input [31:0] last_sector);
        integer c;
        begin
            c = sec*2048 + pgc_start_byte + cell_pb_off + idx*24;
            img[c+8]  = first_sector[31:24]; img[c+9]  = first_sector[23:16];
            img[c+10] = first_sector[15:8];  img[c+11] = first_sector[7:0];
            img[c+20] = last_sector[31:24];  img[c+21] = last_sector[23:16];
            img[c+22] = last_sector[15:8];   img[c+23] = last_sector[7:0];
        end
    endtask

    // 4-cell disc, cells in physical order (cell k -> RBN k).
    task build_iso;
        begin
            for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = 8'h00;

            // PVD @16
            img[32768] = 8'd1;
            img[32769] = "C"; img[32770] = "D"; img[32771] = "0";
            img[32772] = "0"; img[32773] = "1"; img[32774] = 8'd1;
            put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur);

            // root dir @17
            cur = 34816;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 18, 2048, 8'h02, "VIDEO_TS", 8, cur);

            // VIDEO_TS dir @18
            cur = 36864;
            put_rec(cur, 17, 2048, 8'h02, 128'h00, 1, cur);
            put_rec(cur, 17, 2048, 8'h02, 128'h01, 1, cur);
            put_rec(cur, 19, 4096,        8'h00, "VIDEO_TS.IFO;1", 14, cur); // VMGI (2 sec)
            put_rec(cur, 21, 6144,        8'h00, "VTS_01_0.IFO;1", 14, cur); // VTSI (3 sec)
            put_rec(cur, 24, VOBSEC*2048, 8'h00, "VTS_01_1.VOB;1", 14, cur); // title (40 sec)

            put_vmgi(19, 32'd1);
            put_tt_srpt(20, 16'd1, 8'd1);

            put_vtsi_mat(21, 32'd1);                       // vts_pgcit at VTSI+1 = sec 22
            put_pgcit(22, 32'd16, 8'd4, 16'd256);          // 4 cells
            put_cell(22, 32'd16, 16'd256, 0, 32'd0,  32'd9);   // cell0 RBN 0..9
            put_cell(22, 32'd16, 16'd256, 1, 32'd10, 32'd19);  // cell1 RBN 10..19
            put_cell(22, 32'd16, 16'd256, 2, 32'd20, 32'd29);  // cell2 RBN 20..29
            put_cell(22, 32'd16, 16'd256, 3, 32'd30, 32'd39);  // cell3 RBN 30..39

            for (i = 0; i < VOBSEC; i = i + 1)
                fill_sec(24 + i, 8'hB0 + (i / CELLSEC));       // marker per cell

            // NAV packs (VOBU boundaries) for the VOBU-align scrub tests. Placed
            // mid-cell1 (14), at cell2's head (20), and mid-cell2 (26). Cells 0/3
            // stay NAV-free so the marker-run tests (TEST0-3, 7, 8) are unaffected.
            put_nav(14);
            put_nav(20);
            put_nav(26);
        end
    endtask

    // ---- helpers ----
    integer errors = 0;
    integer k;

    // Pulse a seek, wait for the jump to actually EXECUTE (seek_ack pulses at the
    // block-boundary jump cycle, after the outstanding read finishes), let the
    // target cell start streaming, then clear the capture so the next captured
    // bytes are strictly post-seek.
    task do_seek(input [7:0] tgt);
        integer tt;
        begin
            ack_seen = 1'b0;
            @(posedge clk); seek_pulse <= 1'b1; seek_cell <= tgt;
            @(posedge clk); seek_pulse <= 1'b0;
            tt = 0;
            while (!ack_seen && tt < 200000) begin @(posedge clk); tt = tt + 1; end
            repeat (200) @(posedge clk);    // target cell load + stream start
            cap_n = 0;
        end
    endtask

    // Wait until at least `n` fresh bytes have been captured (or timeout).
    task wait_bytes(input integer n);
        integer tt;
        begin
            tt = 0;
            while (cap_n < n && tt < 2000000) begin @(posedge clk); tt = tt + 1; end
        end
    endtask

    task expect_marker(input [7:0] want, input [255:0] label);
        integer mm;
        begin
            mm = 0;
            for (k = 0; k < 1024 && k < cap_n; k = k + 1)
                if (cap[k] !== want) mm = mm + 1;
            if (mm != 0) begin
                errors = errors + 1;
                $display("  FAIL: %0s - %0d/1024 bytes != %02x (first cap %02x)",
                         label, mm, want, cap[0]);
            end else
                $display("  ok: %0s - 1024 bytes all %02x", label, want);
        end
    endtask

    // Verify cap[0..] begins with the NAV-pack signature (a VOBU-aligned landing).
    task check_sig(input [255:0] label);
        begin
            if (cap[0]  !== 8'h00 || cap[1]  !== 8'h00 || cap[2]  !== 8'h01 || cap[3]  !== 8'hBA ||
                cap[14] !== 8'h00 || cap[15] !== 8'h00 || cap[16] !== 8'h01 || cap[17] !== 8'hBB ||
                cap[38] !== 8'h00 || cap[39] !== 8'h00 || cap[40] !== 8'h01 || cap[41] !== 8'hBF) begin
                errors = errors + 1;
                $display("  FAIL: %0s - landed sector is not a NAV pack (cap[0..3]=%02x %02x %02x %02x)",
                         label, cap[0], cap[1], cap[2], cap[3]);
            end
        end
    endtask

    // Index of the first captured byte equal to `want` (or cap_n if absent).
    function integer first_of(input [7:0] want);
        integer n;
        begin
            n = 0;
            while (n < cap_n && cap[n] !== want) n = n + 1;
            first_of = n;
        end
    endfunction



    // =====================================================================
    // THE CHAIN UNDER TEST
    // =====================================================================
    integer realign = 1;                  // 1 = the fix, 0 = the pre-fix path
    localparam VOBU = 5;                  // title sectors per VOBU in this fixture

    reg  mode_edge = 0;
    reg  legacy_ms = 0;                   // pre-fix: `wire mode_switch = il_switch;`
    always @(posedge clk) legacy_ms <= rst_n ? mode_edge : 1'b0;

    // ---- the playhead model: which VOBU's NAV pack is the demux front on? -----------
    // Bytes delivered since the stream last (re)started, and the title RBN that restart
    // began at. Only needs to be valid up to the mode edge -- after that the module has
    // latched, and the pass criterion below does not depend on it.
    integer strm_bytes = 0;
    integer base_rbn   = 0;
    reg     ph_track   = 1;               // stop tracking once the edge has been taken
    always @(posedge clk) if (stream_valid && ph_track) strm_bytes = strm_bytes + 1;

    wire integer cur_sec  = base_rbn + (strm_bytes / SECBYTES);
    wire integer cur_vobu = (cur_sec / VOBU) * VOBU;

    reg  [31:0] ph_lbn  = 32'd0;
    reg         ph_cmt  = 0;
    always @(posedge clk) begin
        ph_cmt <= 1'b0;
        if (ph_track && (cur_vobu != ph_lbn)) begin
            ph_lbn <= cur_vobu;
            ph_cmt <= 1'b1;               // a DSI finished parsing for this VOBU
        end
    end

    mode_realign #(.WDOG(24'd20000)) mr (
        .clk(clk), .rst_n(rst_n),
        .mode_edge(mode_edge),
        .in_title(cell_ready), .dvd_mode(cell_ready), .lin_mode(1'b0),
        .still_active(1'b0), .hold_freeze(1'b0),
        .nav_flush(load_flush), .dsi_commit(ph_cmt), .dsi_stream(1'b0),
        .dsi_nv_pck_lbn(ph_lbn), .lin_blk(32'd0),
        .seek_ack(seek_ack), .jump_ack(1'b0), .keep_vbuf(keep_vbuf),
        .start_streaming(start),
        // The switch blank is irrelevant here: this bench measures the DELIVERED BYTE
        // STREAM, which is upstream of emu's output mux. Held inert so it cannot perturb
        // the seek FSM.
        .video_live(1'b1), .blank_en(1'b0),
        .scrub_pulse(1'b0), .scrub_rbn(32'd0),
        .seek_rbn_pulse(mr_sp), .seek_rbn(mr_srbn),
        .mode_switch(mr_ms), .realign_pend(mr_pend), .sw_blank(mr_blank)
    );

    // +realign=0 removes the re-align entirely: the reader never sees an RBN seek, and
    // flush_ctl is driven straight off the mode edge, exactly as it was before the fix.
    assign rd_seek_pulse = realign[0] ? mr_sp   : 1'b0;
    assign rd_seek_rbn   = realign[0] ? mr_srbn : 32'd0;
    wire   fc_mode_sw    = realign[0] ? mr_ms   : legacy_ms;

    flush_ctl fc (
        .clk(clk), .rst_n(rst_n),
        .start_streaming(start), .seek_ack(seek_ack), .jump_ack(1'b0),
        .mode_switch(fc_mode_sw), .aud_switch(1'b0), .keep_vbuf(keep_vbuf),
        .load_flush(load_flush), .aud_flush(aud_flush), .aud_resync(aud_resync),
        .seek_flush(seek_flush), .mount_flush(mount_flush),
        .pipe_rst_n(pipe_rst_n), .aud_rst_n(aud_rst_n)
    );

    // ---- the measurement: capture from the first byte after the flush RISES ----------
    reg seek_flush_q = 0;
    reg armed_cap    = 0;
    integer n_trio   = 0;
    always @(posedge clk) begin
        if (seek_flush && !seek_flush_q) begin
            n_trio    = n_trio + 1;
            cap_n     = 0;                // the next captured byte is the first post-flush
            armed_cap = 1;
        end
        seek_flush_q <= seek_flush;
    end

    // NAV packs every VOBU. build_iso puts them at 14/20/26 for the scrub tests; put the
    // fixture back to plain markers there so "NAV pack" means exactly "VOBU boundary".
    task build_chain_iso;
        integer q;
        begin
            build_iso;
            fill_sec(24 + 14, 8'hB1);
            fill_sec(24 + 26, 8'hB2);
            for (q = 0; q < VOBSEC; q = q + VOBU) put_nav(q);
        end
    endtask

    initial begin
        if (!$value$plusargs("realign=%d", realign)) realign = 1;
        $display("mode_realign_chain_tb: %0s path", realign[0] ? "FIXED" : "PRE-FIX (+realign=0)");

        build_chain_iso;
        file_size = VOBSEC*2048;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);
        @(negedge clk) start = 1;
        @(negedge clk) start = 0;

        // Let the reader mount, parse the IFOs and start streaming cell 0 from RBN 0.
        k = 0;
        while (!cell_ready && k < 400000) begin @(posedge clk); k = k + 1; end
        if (!cell_ready) begin
            $display("FAIL: reader never reached cell mode");
            errors = errors + 1;
        end
        base_rbn   = 0;
        strm_bytes = 0;
        wait_bytes(1);
        strm_bytes = 0;                    // count from the first delivered byte

        // ---- park the demux front MID-VOBU -----------------------------------------
        // Half a sector into VOBU 1 (RBN 5..9): a landing here is not a VOBU boundary,
        // which is the whole point -- with no reader jump the flush lands right here.
        wait_bytes(6*SECBYTES + 700);
        if ((strm_bytes % SECBYTES) == 0) begin
            $display("FAIL: setup -- the front is on a sector boundary, nothing to prove");
            errors = errors + 1;
        end
        $display("  front: %0d bytes streamed (sector %0d, VOBU %0d), playhead RBN %0d",
                 strm_bytes, cur_sec, cur_vobu, ph_lbn);
        if (ph_lbn != 32'd5) begin
            $display("FAIL: setup -- playhead model says %0d, expected 5", ph_lbn);
            errors = errors + 1;
        end

        // ---- ONE raster-mode change -------------------------------------------------
        n_trio = 0;
        @(negedge clk) mode_edge = 1;
        @(negedge clk) mode_edge = 0;
        ph_track = 0;                      // freeze the model; the module has latched

        // Wait for the trio, then for the first bytes to arrive behind it.
        k = 0;
        while (n_trio == 0 && k < 400000) begin @(posedge clk); k = k + 1; end
        if (n_trio == 0) begin
            $display("FAIL: no flush ever fired for the mode change");
            errors = errors + 1;
        end
        k = 0;
        while (cap_n < 64 && k < 400000) begin @(posedge clk); k = k + 1; end

        // ---- THE CRITERION ----------------------------------------------------------
        if (cap_n < 64) begin
            $display("FAIL: fewer than 64 bytes delivered after the flush");
            errors = errors + 1;
        end else begin
            $display("  first bytes after the flush: %02x %02x %02x %02x  (@14: %02x %02x %02x %02x)",
                     cap[0], cap[1], cap[2], cap[3], cap[14], cap[15], cap[16], cap[17]);
            check_sig("flush must land on a NAV pack");
        end

        // Exactly one flush for one mode change, whichever path was taken.
        if (n_trio != 1) begin
            $display("  flushes=%0d, want 1", n_trio);
            errors = errors + 1;
            $display("FAIL: one mode change must cost exactly one flush");
        end

        // And it must have re-aligned to the VOBU the demux front was in -- not to the
        // start of the title (the stale-playhead trap) and not forward past content.
        if (realign[0] && mr_srbn != 32'd5) begin
            $display("  re-align target=%0d, want 5", mr_srbn);
            errors = errors + 1;
            $display("FAIL: the re-align must target the CURRENT VOBU");
        end

        if (errors == 0) $display("mode_realign_chain_tb: ALL TESTS PASSED");
        else begin
            $display("mode_realign_chain_tb: FAILED with %0d errors", errors);
            $fatal(1, "mode_realign_chain_tb FAILED");
        end
        $finish;
    end

    initial begin
        #400000000;
        $display("mode_realign_chain_tb: TIMEOUT");
        $finish;
    end

endmodule
