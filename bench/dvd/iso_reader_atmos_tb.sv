// iso_reader_atmos_tb.sv - real-data JumpTT resolution check for the Atmosfear
// game disc (ATMOSFEAR_NTSC.ISO, 75 VTS). Reproduces the wrong-title bug in sim:
// after the player-setup the disc's VM issues `JumpTT 66` (VTS 66 = the 49:00
// game); on hardware our core plays best_vts=52 (green 24:31). This TB serves the
// REAL ISO9660 + IFO metadata sectors and drives the reader's vm-mode jump port
// directly with a JumpTT 66, asserting the reader resolves to VTS 66 (not 52).
//
// Serves 16 real sectors (fixture bench/dvd/test_vobs/atmos_iso_meta.hex):
//   16,17          PVD (+terminator)
//   259            root directory
//   261..269       VIDEO_TS directory (9 sectors, enumerates all 75 VTS)
//   590            VMGI (VIDEO_TS.IFO) VMGI_MAT (tt_srpt_ptr@196 = 1)
//   591            VMGI TT_SRPT (75 titles; entry[66] title_set_nr=66 vts_ttn=1)
//   3784404        VTS_66_0.IFO VTSI_MAT (vts_pgcit_ptr@204 = 2)
//   3784406        VTS_66 VTS_PGCIT
// every other sector reads as zero.
//
// Ground truth (tools/dvd_vm_ref.py + tools/bin/trace_nav on the real disc):
//   all 75 VTS enumerate; JumpTT 66 -> title_set_nr 66 -> VTS 66 in gmem.
`timescale 1ns/1ps

module iso_reader_atmos_tb;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [63:0] file_size = 64'd8263182336;   // real image size

    wire [31:0] sd_lba;
    wire        sd_rd;
    reg         sd_ack = 0;
    reg  [13:0] sd_buff_addr = 0;
    reg  [7:0]  sd_buff_dout = 0;
    reg         sd_buff_wr = 0;

    // vm-mode jump port (we act as the VM)
    reg         jump_pulse = 0;
    reg  [1:0]  jump_domain = 0;
    reg  [7:0]  jump_vts = 0, jump_pgcn = 0, jump_cell = 0, jump_pgn = 0;
    reg  [3:0]  jump_entry = 0;
    reg  [6:0]  jump_ttn = 0;
    reg  [9:0]  jump_ptt = 0;

    reg         busy = 1'b1;   // hold streaming backpressure; we only test nav

    wire        pgc_loaded, pgc_error;
    localparam DOM_TT = 2'd3, DOM_VMGM = 2'd1;

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size),
        .title_sel(4'd0), .vbuf_empty(1'b0), .menu_snap(1'b0),
        .jump_pulse(jump_pulse), .jump_natural(1'b0), .jump_domain(jump_domain),
        .jump_vts(jump_vts), .jump_pgcn(jump_pgcn), .jump_entry(jump_entry),
        .jump_cell(jump_cell), .jump_ttn(jump_ttn), .jump_pgn(jump_pgn),
        .jump_ptt(jump_ptt),
        .vm_mode(1'b1), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .jump_ack(), .pgc_loaded(pgc_loaded), .pgc_error(pgc_error),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(), .stream_valid(), .busy(busy),
        .debug_active(), .debug_sd_rd(), .debug_sd_ack(), .debug_cache_has_data(),
        .debug_file_size(), .debug_total_sectors(), .debug_next_lba(),
        .debug_state(), .debug_iso_mode(), .debug_iso_error()
    );

    always #5 clk = ~clk;

    // fixture: 22 metadata sectors, in the fixed order below
    reg [7:0] meta [0:22*2048-1];
    initial $readmemh("bench/dvd/test_vobs/atmos_iso_meta.hex", meta);

    function integer meta_idx(input [31:0] s);
        begin
            case (s)
                32'd16:      meta_idx = 0;
                32'd17:      meta_idx = 1;
                32'd259:     meta_idx = 2;
                32'd261:     meta_idx = 3;
                32'd262:     meta_idx = 4;
                32'd263:     meta_idx = 5;
                32'd264:     meta_idx = 6;
                32'd265:     meta_idx = 7;
                32'd266:     meta_idx = 8;
                32'd267:     meta_idx = 9;
                32'd268:     meta_idx = 10;
                32'd269:     meta_idx = 11;
                32'd590:     meta_idx = 12;
                32'd591:     meta_idx = 13;
                32'd592:     meta_idx = 14;   // VMGM PGCI_UT + PGC2 (jump table)
                32'd593:     meta_idx = 15;
                32'd3784404: meta_idx = 16;
                32'd3784406: meta_idx = 17;
                32'd725:     meta_idx = 18;   // VTS_01_0.IFO VTSI_MAT (@208 VTSM_PGCI_UT)
                32'd728:     meta_idx = 19;   // VTS_01 VTSM PGCI_UT + PGCIT (84 PGCs)
                32'd730:     meta_idx = 20;   // PGC13 start (off 2044 = straddles 730/731)
                32'd731:     meta_idx = 21;   // PGC13 header continuation
                default:     meta_idx = -1;
            endcase
        end
    endfunction

    // mock HPS: serve one 2048-byte block (sector) per sd_rd (sd_lba is a 512-block address;
    // sd_lba IS the ISO 2048-sector; bc = byte offset within it)
    integer m = 0, bc = 0, lat = 0, mi;
    reg [31:0] rlba = 0;
    always @(posedge clk) begin
        sd_buff_wr <= 1'b0;
        case (m)
        0: begin sd_ack <= 1'b0; if (sd_rd) begin rlba <= sd_lba; lat <= 3; m <= 1; end end
        1: begin if (lat!=0) lat<=lat-1; else begin sd_ack<=1'b1; bc<=0; m<=2; end end
        2: begin
            sd_ack <= 1'b1; sd_buff_wr <= 1'b1; sd_buff_addr <= bc[13:0];
            mi = meta_idx(rlba);
            if (mi >= 0) sd_buff_dout <= meta[mi*2048 + bc];
            else         sd_buff_dout <= 8'h00;
            bc <= bc + 1;
            if (bc == 2047) m <= 3;
        end
        3: begin sd_ack <= 1'b0; sd_buff_wr <= 1'b0; m <= 0; end
        endcase
    end

    // latch the resolution decision the first time the reader enters S_PGC_BEGIN
    // (state 17): target_vtsn + sel_valid are valid there and decide play_vtsn.
    reg        captured = 0;
    reg [7:0]  cap_target, cap_play;
    reg        cap_sel;
    reg        jump_started = 0;
    always @(posedge clk) begin
        if (jump_pulse) jump_started <= 0;
        if (dut.state == 6'd17 && !captured) begin
            captured   <= 1'b1;
            cap_target <= dut.target_vtsn;
            cap_sel    <= dut.sel_valid;
            cap_play   <= dut.sel_valid ? dut.target_vtsn : dut.best_vtsn;
        end
    end

    // probe: latch PGC13's parsed nr_cells at the cell-check state (23), where it
    // is stable. 1 = correct 1-cell menu still; 0 = the shadow-wrap mis-read that
    // sent PGC13 down the wrong (0-cell stub) path -> best_vts=52.
    reg probe_on = 0;
    reg [7:0] pgc13_ncells = 8'hFF;
    always @(posedge clk) if (probe_on && dut.state == 6'd23 && dut.cur_pgcn == 8'd13)
        pgc13_ncells <= dut.nr_cells;

    integer n_loaded = 0, n_error = 0;
    always @(posedge clk) begin
        if (pgc_loaded) n_loaded <= n_loaded + 1;
        if (pgc_error)  n_error  <= n_error + 1;
    end

    integer errors = 0;
    integer t, i, found66, e0;

    // GMEM field layout: {vts[8], base[7], cnt[7], ifo_lba[32], menu_lba[32], menu_blk[32]}
    // width 118, so vts = bits [117:110].
    task dump_gmem;
        integer k;
        reg [7:0] v;
        begin
            found66 = 0;
            for (k = 0; k < dut.grp_count; k = k + 1) begin
                v = dut.gmem[k][117:110];
                if (v == 8'd66) found66 = 1;
            end
        end
    endtask

    initial begin
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        // --- Phase 1: wait for mount (nav_ready). S_FINALIZE sets nav_ready=1. ---
        t = 0;
        while (dut.nav_ready !== 1'b1 && t < 400000) begin @(posedge clk); t = t + 1; end
        if (dut.nav_ready !== 1'b1) begin
            $display("ATMOS_TB: mount never reached nav_ready (t=%0d state=%0d)", t, dut.state);
            errors = errors + 1;
        end
        dump_gmem;
        $display("MOUNT: grp_count=%0d best_vtsn=%0d VTS66_in_gmem=%0d (iso_mode=%b iso_error=%b)",
                 dut.grp_count, dut.best_vtsn, found66, dut.iso_mode, dut.iso_error);
        if (dut.grp_count < 7'd66) begin errors=errors+1; $display("  ERR grp_count<66: VTS 66 not enumerated"); end
        if (!found66)              begin errors=errors+1; $display("  ERR VTS 66 has no gmem entry"); end
        if (dut.best_vtsn !== 8'd52) $display("  NOTE best_vtsn=%0d (expected 52)", dut.best_vtsn);

        // let the reader settle after mount
        repeat (50) @(posedge clk);

        // --- Phase A: VTSM menu jump to PGC13 (the 6th character screen) from
        //     the idle S_DONE state. PGC13's header starts at pgc_off=2044
        //     (straddles the sector boundary). BUG: S_PGC_HDR gives up for
        //     pgc_off>2043 -> pgc_error (matches HW: rd_state=S_DONE, menu_dom=1,
        //     g9 stuck at 5). FIX: nr_of_cells (rbuf[3]=byte 2047) is readable at
        //     pgc_off=2044; only the cosmetic playback-time wraps. ---
        $display("MENU: issuing VTSM jump to PGC13 (VTS 1, the 6th character screen)");
        probe_on = 1;
        e0 = n_error;
        @(posedge clk);
        jump_domain = 2'd2 /*DOM_VTSM*/; jump_vts = 8'd1; jump_pgcn = 8'd13;
        jump_ttn = 7'd0; jump_entry = 4'd0; jump_cell = 8'd0; jump_pgn = 8'd0; jump_ptt = 10'd0;
        jump_pulse = 1; @(posedge clk); jump_pulse = 0;
        // wait until it parses PGC13's header (nr_cells settles) or errors. The
        // reader then loops in the cell-load states (no menu VOB served here);
        // the decisive checks are: no pgc_error, cur_pgcn=13, and nr_cells=1 (a
        // 1-cell menu still, NOT a mis-read 0-cell stub that took the wrong path).
        // wait until PGC13's nr_cells is latched at the cell-check state, or error
        t = 0;
        while (n_error == e0 && pgc13_ncells == 8'hFF && t < 200000) begin
            @(posedge clk); t = t + 1;
        end
        probe_on = 0;
        $display("MENU RESULT: n_error(delta)=%0d cur_pgcn=%0d PGC13.nr_cells=%0d (t=%0d)",
                 n_error - e0, dut.cur_pgcn, pgc13_ncells, t);
        if (n_error != e0) begin errors=errors+1;
            $display("  ERR PGC13 (pgc_off=2044, straddling header) pulsed pgc_error -> the 6th character screen fails"); end
        else if (dut.cur_pgcn != 8'd13) begin errors=errors+1;
            $display("  ERR PGC13 not loaded (cur_pgcn=%0d, expected 13)", dut.cur_pgcn); end
        else if (pgc13_ncells != 8'd1) begin errors=errors+1;
            $display("  ERR PGC13 nr_cells=%0d (expected 1) -> header mis-read (shadow-wrap bug) -> wrong path -> best_vts=52", pgc13_ncells); end
        else
            $display("  OK  PGC13 loaded (cur_pgcn=13, nr_cells=1) — the 6th char screen holds as a still");

        // --- Phase 1.5: JumpSS VMGM PGC2 (the real predecessor of JumpTT 66:
        //     the scenario dispatch does JumpSS VMGM(pgc 2) -> jump table ->
        //     JumpTT 66). If this MENU jump fails (pgc_error), the VM fallback
        //     chain ends at auto-title=best_vts=52 -> the exact bug symptom. ---
        e0 = n_error;
        $display("JUMPSS: issuing JumpSS VMGM PGC2 (state=%0d)", dut.state);
        @(posedge clk);
        jump_domain = DOM_VMGM; jump_pgcn = 8'd2; jump_ttn = 7'd0; jump_vts = 8'd0;
        jump_entry = 4'd0; jump_cell = 8'd0; jump_pgn = 8'd0; jump_ptt = 10'd0;
        jump_pulse = 1; @(posedge clk); jump_pulse = 0;
        // wait for pgc_loaded (menu PGC parsed -> VM would run its PRE) or pgc_error
        t = 0;
        while (n_loaded == 0 && n_error == e0 && t < 200000) begin @(posedge clk); t = t + 1; end
        $display("JUMPSS RESULT: n_loaded=%0d n_error(delta)=%0d state=%0d (t=%0d)",
                 n_loaded, n_error - e0, dut.state, t);
        if (n_error != e0) begin errors=errors+1;
            $display("  ERR JumpSS VMGM PGC2 pulsed pgc_error -> VM would fall back to auto-title=best_vts=%0d (THE BUG)", dut.best_vtsn); end
        else if (n_loaded == 0) begin errors=errors+1;
            $display("  ERR JumpSS VMGM PGC2 never loaded (state=%0d)", dut.state); end
        else $display("  OK JumpSS VMGM PGC2 loaded cleanly (VM would run its jump table -> JumpTT 66)");
        repeat (30) @(posedge clk);

        // --- Phase 2: drive JumpTT 66 directly (as the VM would) ---
        $display("JUMP: issuing JumpTT 66 (state before=%0d sel_valid=%b)", dut.state, dut.sel_valid);
        @(posedge clk);
        jump_domain = DOM_TT; jump_ttn = 7'd66; jump_vts = 8'd0;
        jump_pgcn = 0; jump_entry = 0; jump_cell = 0; jump_pgn = 0; jump_ptt = 0;
        jump_pulse = 1; @(posedge clk); jump_pulse = 0;

        // wait until the reader captures the resolution at S_PGC_BEGIN (or gives up)
        t = 0;
        while (!captured && dut.state != 6'd12 && t < 200000) begin
            @(posedge clk); t = t + 1;
        end
        $display("JUMP RESULT: captured=%0d state=%0d cap_target=%0d cap_sel=%b cap_play=%0d (t=%0d)",
                 captured, dut.state, cap_target, cap_sel, cap_play, t);

        if (!captured) begin errors=errors+1;
            $display("  ERR reader never reached S_PGC_BEGIN after JumpTT 66 (state=%0d)", dut.state); end
        if (captured && cap_target !== 8'd66) begin errors=errors+1;
            $display("  ERR target_vtsn=%0d, expected 66 (S_TT_RES resolution)", cap_target); end
        if (captured && cap_sel !== 1'b1) begin errors=errors+1;
            $display("  ERR sel_valid=0: S_SELECT did NOT find VTS 66 in gmem -> falls back to best_vts=%0d", dut.best_vtsn); end
        if (captured && cap_play !== 8'd66) begin errors=errors+1;
            $display("  ERR play_vtsn=%0d, expected 66 (THE BUG: plays this instead of 66)", cap_play); end

        if (errors == 0) $display("ISO_READER_ATMOS_TB: PASSED (JumpTT 66 -> VTS 66; PGC13 menu load OK)");
        else             $display("ISO_READER_ATMOS_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin #20000000; $display("ISO_READER_ATMOS_TB: TIMEOUT (state=%0d)", dut.state); $finish; end

endmodule
