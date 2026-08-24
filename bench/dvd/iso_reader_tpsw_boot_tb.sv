// iso_reader_tpsw_boot_tb.sv - reader-side check of the TP_SW BOOT-chain menu PGCs.
// The golden VM (tools/dvd_vm_ref.py runboot) takes the boot path FP -> JumpTT 1 ->
// title -> CallSS_VMGM PGC 7 -> VMGM PGC7 -> LinkPGCN 2 -> VMGM PGC2 (the question
// menu), never a PGCN-1 dead-end. HW row 24 says our RTL DOES dead-end on menu
// {vts1, pgcn1}. This TB feeds the real TP_SW IFO sectors and drives each menu PGC
// the boot chain touches (VMGM 7, 2, entry-Title=1; VTSM Root=1) STRAIGHT at the
// reader, asserting cmd_nr_pre matches ground truth. If the reader delivers every
// one correctly, the nr_pre=0 drop is NOT the reader parse -> it is the VM's nav
// decision (which PGC it jumps to), traced separately.
//
// Ground truth (real disc): VMGM PGC7 nr_pre=16 (3 cells, sector 283), VMGM PGC2
// nr_pre=16 (1 cell), VMGM PGC1 nr_pre=4 (0 cells, entry 0x82 Title), VTSM_01 PGC1
// nr_pre=13 (0 cells, entry 0x83 Root).
`timescale 1ns/1ps

module iso_reader_tpsw_boot_tb;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [63:0] file_size = 64'd4392404992;

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

    reg         busy = 1'b1;
    wire        pgc_loaded, pgc_error;
    wire [7:0]  cmd_nr_pre;
    wire        cmd_we;
    localparam DOM_VMGM = 2'd1, DOM_VTSM = 2'd2;

    integer n_error = 0;
    always @(posedge clk) if (pgc_error) n_error = n_error + 1;

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
        .cmd_nr_pre(cmd_nr_pre), .cmd_nr_post(), .cmd_nr_cell(),
        .jump_ack(), .pgc_loaded(pgc_loaded), .pgc_error(pgc_error),
        .menu_active(),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(), .stream_valid(), .busy(busy),
        .debug_active(), .debug_sd_rd(), .debug_sd_ack(), .debug_cache_has_data(),
        .debug_file_size(), .debug_total_sectors(), .debug_next_lba(),
        .debug_state(), .debug_iso_mode(), .debug_iso_error()
    );

    always #5 clk = ~clk;

    reg [7:0] meta [0:12*2048-1];
    initial $readmemh("bench/dvd/test_vobs/tpsw_boot_meta.hex", meta);

    function integer midx(input [31:0] s);
        begin
            case (s)
                32'd16:    midx = 0;   32'd259:   midx = 1;   32'd261:   midx = 2;
                32'd280:   midx = 3;   32'd282:   midx = 4;   32'd283:   midx = 5;
                32'd92501: midx = 6;   32'd92552: midx = 7;   32'd92553: midx = 8;
                32'd92554: midx = 9;   32'd92555: midx = 10;  32'd92556: midx = 11;
                default:   midx = -1;
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
            mi = midx(rlba);
            if (mi >= 0) sd_buff_dout <= meta[mi*2048 + bc];
            else         sd_buff_dout <= 8'h00;
            bc <= bc + 1;
            if (bc == 2047) m <= 3;
        end
        3: begin sd_ack <= 1'b0; sd_buff_wr <= 1'b0; m <= 0; end
        endcase
    end

    // probe latch
    reg        probe_on = 0;
    reg [7:0]  want_pgcn = 0;
    reg [7:0]  seen_npre = 8'hFF, seen_ncells = 8'hFF;
    reg [10:0] seen_off = 11'h7FF;
    reg        seen = 0;
    always @(posedge clk)
        if (probe_on && dut.state == 6'd32 && dut.cur_pgcn == want_pgcn && !seen) begin
            seen <= 1'b1; seen_npre <= cmd_nr_pre;
            seen_ncells <= dut.nr_cells; seen_off <= dut.pgc_off;
        end

    integer errors = 0, t, e0;

    task do_probe(input [1:0] dom, input [7:0] vts, input [7:0] pgcn,
                  input [3:0] entry, input [7:0] exp_pgcn, input [7:0] exp_npre,
                  input [255:0] label);
        begin
            want_pgcn = exp_pgcn; seen = 0; seen_npre = 8'hFF;
            seen_ncells = 8'hFF; seen_off = 11'h7FF;
            probe_on = 1; e0 = n_error;
            @(posedge clk);
            jump_domain = dom; jump_vts = vts; jump_pgcn = pgcn; jump_entry = entry;
            jump_ttn = 0; jump_cell = 0; jump_pgn = 0; jump_ptt = 0;
            jump_pulse = 1; @(posedge clk); jump_pulse = 0;
            t = 0;
            while (!seen && n_error == e0 && t < 400000) begin @(posedge clk); t = t+1; end
            repeat (20) @(posedge clk);
            probe_on = 0;
            $display("%0s: pgc_error(d)=%0d cur_pgcn=%0d off=%0d nr_cells=%0d cmd_nr_pre=%0d (expect nr_pre=%0d)",
                     label, n_error - e0, dut.cur_pgcn, seen_off, seen_ncells, seen_npre, exp_npre);
            if (n_error != e0) begin errors=errors+1; $display("  ERR %0s pulsed pgc_error", label); end
            else if (seen_npre !== exp_npre) begin errors=errors+1;
                $display("  *** %0s DROPS nr_pre: got %0d expected %0d", label, seen_npre, exp_npre); end
            repeat (30) @(posedge clk);
        end
    endtask

    initial begin
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        start = 1; @(posedge clk); start = 0;
        t = 0;
        while (dut.nav_ready !== 1'b1 && t < 800000) begin @(posedge clk); t = t+1; end
        $display("MOUNT: nav_ready=%b grp_count=%0d best_vtsn=%0d", dut.nav_ready, dut.grp_count, dut.best_vtsn);
        if (dut.nav_ready !== 1'b1) begin errors=errors+1; $display("  ERR no nav_ready"); end
        repeat (50) @(posedge clk);

        // The boot chain's menu PGCs, driven straight at the reader:
        do_probe(DOM_VMGM, 8'd0, 8'd7, 4'd0, 8'd7, 8'd16, "VMGM PGC7 (CallSS target)");
        do_probe(DOM_VMGM, 8'd0, 8'd2, 4'd0, 8'd2, 8'd16, "VMGM PGC2 (question menu)");
        do_probe(DOM_VMGM, 8'd0, 8'd0, 4'd2, 8'd1, 8'd4,  "VMGM PGC1 (entry Title)");
        do_probe(DOM_VTSM, 8'd1, 8'd0, 4'd3, 8'd1, 8'd13, "VTSM PGC1 (entry Root)");

        if (errors == 0)
            $display("ISO_READER_TPSW_BOOT_TB: PASSED (reader delivers every boot-chain menu PGC's nr_pre) -> the drop is VM-side");
        else
            $display("ISO_READER_TPSW_BOOT_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin #40000000; $display("ISO_READER_TPSW_BOOT_TB: TIMEOUT (state=%0d)", dut.state); $finish; end

endmodule
