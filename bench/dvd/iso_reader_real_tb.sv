// iso_reader_real_tb.sv - real-data navigation check for dvd/dvd_iso_reader.sv
//
// Loads the ACTUAL ISO9660 metadata sectors from MEN_IN_BLACK.iso (PVD @16,
// root dir @261, VIDEO_TS dir @266-268 - the only sectors navigation reads)
// and serves them at their true LBAs; every other sector reads as zero. Runs
// navigation and confirms the RTL selects the main feature VTS_21 on real bytes:
//   - iso_mode set, iso_error clear
//   - winner has 4 title-VOB extents
//   - winner's first extent starts at ISO LBA 1683616 (= sd_lba, 2048-sector units)
//
// Ground truth (tools/iso_nav_check.py on the real disc): WINNER VTS_21,
// 4 extents, first_lba=1683616.

`timescale 1ns/1ps

module iso_reader_real_tb;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [63:0] file_size = 64'd7396261888;   // real image size

    wire [31:0] sd_lba;
    wire        sd_rd;
    reg         sd_ack = 0;
    reg  [13:0] sd_buff_addr = 0;
    reg  [7:0]  sd_buff_dout = 0;
    reg         sd_buff_wr = 0;

    wire [7:0]  stream_data;
    wire        stream_valid;
    reg         busy = 1'b1;   // hold backpressure: we only care about navigation

    wire        debug_iso_mode, debug_iso_error;

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size), .title_sel(4'd0), .vbuf_empty(1'b0), .menu_snap(1'b0),
        // Phase-4 DVD-VM ports: legacy mode (vm_mode=0 keeps prior behaviour)
        .jump_ttn(7'd0), .jump_pgn(8'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .debug_active(), .debug_sd_rd(), .debug_sd_ack(), .debug_cache_has_data(),
        .debug_file_size(), .debug_total_sectors(), .debug_next_lba(),
        .debug_state(), .debug_iso_mode(debug_iso_mode), .debug_iso_error(debug_iso_error)
    );

    always #5 clk = ~clk;

    // fixture: 5 metadata sectors, in order 16,261,266,267,268
    reg [7:0] meta [0:5*2048-1];
    initial $readmemh("bench/dvd/test_vobs/mib_iso_meta.hex", meta);

    // map a 2048-logical-sector number to its fixture block index (-1 = zero)
    function integer meta_idx(input [31:0] s);
        begin
            case (s)
                32'd16:  meta_idx = 0;
                32'd261: meta_idx = 1;
                32'd266: meta_idx = 2;
                32'd267: meta_idx = 3;
                32'd268: meta_idx = 4;
                default: meta_idx = -1;
            endcase
        end
    endfunction

    // mock HPS: serve one 2048-byte block (sector) per sd_rd
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

    integer errors = 0;
    integer t;
    initial begin
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        // wait until navigation finishes (S_STREAM = 8) or S_ERROR = 10
        t = 0;
        while (dut.state != 6'd10 && dut.state != 6'd12 && t < 200000) begin
            @(posedge clk); t = t + 1;
        end

        // ext_start_q is the registered sync-read of ext_mem[strm_idx]; at S_STREAM
        // entry strm_idx = eff_base, so it holds the winning VTS's first extent LBA.
        // (Replaces the old whitebox tap dut.all_start[dut.best_base] after the
        //  extent table became a sync-read M10K — Phase-0 ALM reclaim.)
        $display("REAL: state=%0d iso_mode=%b iso_error=%b best_cnt=%0d first_lba(2048sec)=%0d",
                 dut.state, debug_iso_mode, debug_iso_error,
                 dut.best_cnt, dut.ext_start_q);

        if (dut.state !== 6'd10)        begin errors=errors+1; $display("  ERR navigation did not reach STREAM"); end
        if (debug_iso_mode !== 1'b1)    begin errors=errors+1; $display("  ERR iso_mode not set"); end
        if (debug_iso_error !== 1'b0)   begin errors=errors+1; $display("  ERR iso_error set"); end
        if (dut.best_cnt !== 7'd4)      begin errors=errors+1; $display("  ERR expected 4 extents (VTS_21)"); end
        if (dut.ext_start_q !== 32'd1683616)
                                        begin errors=errors+1; $display("  ERR wrong first extent LBA"); end

        if (errors == 0) $display("ISO_READER_REAL_TB: PASSED (main feature = VTS_21)");
        else             $display("ISO_READER_REAL_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin #5000000; $display("ISO_READER_REAL_TB: TIMEOUT"); $finish; end

endmodule
