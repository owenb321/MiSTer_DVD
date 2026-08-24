// iso_reader_tpsw_tb.sv - REAL-DATA reproduction of the Trivial Pursuit Star Wars
// symptom-1 dead-end. HW DEBUG_OVERLAY row 24 read {deadend_vts, deadend_pgcn} =
// {1, 1} (sticky, latched at BOOT): the VM dead-ended on a menu-domain PGCN 1 that
// arrived with nr_pre == 0. Ground truth (tools/dvd_vm_ref.py / this fixture) says
// VTSM_01 PGC1 (entry 0x83 Root, in-sector off 248, cmd_tbl_off 236, MID-SECTOR =
// NOT a straddle) genuinely has nr_pre = 13. So the reader is DROPPING nr_pre for a
// PGC that has PRE commands. This TB feeds the real TP_SW IFO sectors to the reader
// and drives a VTSM Root jump (as the boot VM would), asserting the reader delivers
// cmd_nr_pre = 13 (a PASS = reader OK, the drop is elsewhere; a FAIL = reader
// reproduces the bug and the captured state shows the failing FSM path).
//
// Fixture bench/dvd/test_vobs/tpsw_vtsm_meta.hex (10 real 2048-byte sectors):
//   16     PVD                 259   root dir            261   VIDEO_TS dir
//   280    VMGI (VIDEO_TS.IFO)  92501 VTS_01_0.IFO VTSI_MAT (@208 VTSM_PGCI_UT=+51)
//   92552..92556  VTS_01 VTSM PGCI_UT + PGCIT (28 PGCs; PGC1 @ off 248, nr_pre 13)
`timescale 1ns/1ps

module iso_reader_tpsw_tb;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [63:0] file_size = 64'd4392404992;   // real image size

    wire [31:0] sd_lba;
    wire        sd_rd;
    reg         sd_ack = 0;
    reg  [13:0] sd_buff_addr = 0;
    reg  [7:0]  sd_buff_dout = 0;
    reg         sd_buff_wr = 0;

    reg         jump_pulse = 0;
    reg  [1:0]  jump_domain = 0;
    reg  [7:0]  jump_vts = 0, jump_pgcn = 0, jump_cell = 0, jump_pgn = 0;
    reg  [3:0]  jump_entry = 0;
    reg  [6:0]  jump_ttn = 0;
    reg  [9:0]  jump_ptt = 0;

    reg         busy = 1'b1;                    // nav only, no streaming
    wire        pgc_loaded, pgc_error, menu_active;
    wire [7:0]  cmd_nr_pre, cmd_nr_post, cmd_nr_cell;
    wire        cmd_we;
    localparam DOM_VTSM = 2'd2;

    integer cmd_bytes = 0;
    always @(posedge clk) if (cmd_we) cmd_bytes = cmd_bytes + 1;

    integer n_error = 0, n_loaded = 0;
    always @(posedge clk) begin
        if (pgc_error)  n_error  = n_error + 1;
        if (pgc_loaded) n_loaded = n_loaded + 1;
    end

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
        .cmd_we(cmd_we), .cmd_waddr(), .cmd_wdata(),
        .cmd_nr_pre(cmd_nr_pre), .cmd_nr_post(cmd_nr_post), .cmd_nr_cell(cmd_nr_cell),
        .jump_ack(), .pgc_loaded(pgc_loaded), .pgc_error(pgc_error),
        .menu_active(menu_active),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(), .stream_valid(), .busy(busy),
        .debug_active(), .debug_sd_rd(), .debug_sd_ack(), .debug_cache_has_data(),
        .debug_file_size(), .debug_total_sectors(), .debug_next_lba(),
        .debug_state(), .debug_iso_mode(), .debug_iso_error()
    );

    always #5 clk = ~clk;

    reg [7:0] meta [0:10*2048-1];
    initial $readmemh("bench/dvd/test_vobs/tpsw_vtsm_meta.hex", meta);

    function integer meta_idx(input [31:0] s);
        begin
            case (s)
                32'd16:     meta_idx = 0;
                32'd259:    meta_idx = 1;
                32'd261:    meta_idx = 2;
                32'd280:    meta_idx = 3;
                32'd92501:  meta_idx = 4;
                32'd92552:  meta_idx = 5;
                32'd92553:  meta_idx = 6;
                32'd92554:  meta_idx = 7;
                32'd92555:  meta_idx = 8;
                32'd92556:  meta_idx = 9;
                default:    meta_idx = -1;
            endcase
        end
    endfunction

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

    // probe: latch PGC1's parsed command counts at the cell-check state (32).
    reg        probe_on = 0;
    reg [7:0]  seen_npre = 8'hFF, seen_ncells = 8'hFF, seen_pgcoff = 8'hFF;
    reg [10:0] seen_off = 11'h7FF;
    reg        seen = 0;
    always @(posedge clk)
        if (probe_on && dut.state == 6'd32 && dut.cur_pgcn == 8'd1 && !seen) begin
            seen <= 1'b1;
            seen_npre   <= cmd_nr_pre;
            seen_ncells <= dut.nr_cells;
            seen_off    <= dut.pgc_off;
        end

    integer errors = 0, t, e0;

    initial begin
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        // vm_mode: mount walks VIDEO_TS then IDLES at S_DONE (nav_ready=1).
        t = 0;
        while (dut.nav_ready !== 1'b1 && t < 800000) begin @(posedge clk); t = t+1; end
        $display("MOUNT: nav_ready=%b iso_mode=%b iso_error=%b grp_count=%0d best_vtsn=%0d state=%0d",
                 dut.nav_ready, dut.iso_mode, dut.iso_error, dut.grp_count, dut.best_vtsn, dut.state);
        if (dut.nav_ready !== 1'b1) begin errors=errors+1; $display("  ERR mount never reached nav_ready"); end
        repeat (50) @(posedge clk);

        // Drive the VTSM Root jump the boot VM issues (domain VTSM, entry 0x83 Root).
        probe_on = 1; e0 = n_error;
        @(posedge clk);
        jump_domain = DOM_VTSM; jump_vts = 8'd1; jump_pgcn = 8'd0; jump_entry = 4'd3;
        jump_ttn = 0; jump_cell = 0; jump_pgn = 0; jump_ptt = 0;
        jump_pulse = 1; @(posedge clk); jump_pulse = 0;

        t = 0;
        while (!seen && n_error == e0 && t < 400000) begin @(posedge clk); t = t+1; end
        repeat (30) @(posedge clk);
        probe_on = 0;
        $display("VTSM ROOT: pgc_error(d)=%0d cur_pgcn=%0d pgc_off=%0d nr_cells=%0d cmd_nr_pre=%0d cmd_bytes=%0d loaded=%0d",
                 n_error - e0, dut.cur_pgcn, seen_off, seen_ncells, seen_npre, cmd_bytes, n_loaded);

        // GROUND TRUTH: VTSM_01 PGC1 = Root, off 248, nr_cells 0, nr_pre 13.
        if (seen_off !== 11'd248) begin errors=errors+1;
            $display("  ERR PGC1 positioned at off=%0d, expected 248", seen_off); end
        if (seen_ncells !== 8'd0) begin errors=errors+1;
            $display("  ERR PGC1 nr_cells=%0d, expected 0", seen_ncells); end
        if (seen_npre !== 8'd13) begin errors=errors+1;
            $display("  *** REPRODUCED: PGC1 cmd_nr_pre=%0d, expected 13 -> the reader DROPS nr_pre (row 24 = 01 01)", seen_npre); end
        else
            $display("  PGC1 cmd_nr_pre=13 delivered correctly -> the reader is NOT the drop point (look at emu/VM integration or the nav path to PGC1)");

        if (errors == 0) $display("ISO_READER_TPSW_TB: PASSED (reader delivers PGC1 nr_pre=13)");
        else             $display("ISO_READER_TPSW_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin #30000000; $display("ISO_READER_TPSW_TB: TIMEOUT (state=%0d)", dut.state); $finish; end

endmodule
