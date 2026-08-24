// iso_reader_attr_tb.sv - Phase-10 track-attribute parse check for
// dvd/dvd_iso_reader.sv (the S_ATTR sweep).
//
// Serves the REAL MEN_IN_BLACK.iso ISO9660 metadata (PVD @16, root @261,
// VIDEO_TS @266-268) so navigation selects the main feature VTS_21, AND the
// REAL VTS_21_0.IFO VTSI_MAT sector at its true LBA (1683520) so the
// attribute sweep reads genuine audio/subpicture stream-attribute bytes.
// Confirms the parsed counts + per-track codec/channels/language match the
// disc byte-for-byte:
//   audio_ntracks=4  A0 AC3 2ch en / A1 AC3 6ch en / A2 AC3 2ch fr / A3 AC3 2ch en
//   subp_ntracks =4  S0 en / S1 fr / S2 es / S3 en
//
// Ground truth: tools/nav_extract.py --vts-attr --vts 21 (comment header of
// bench/dvd/test_vobs/mib_vts21_vtsi_mat.hex).

`timescale 1ns/1ps

module iso_reader_attr_tb;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [63:0] file_size = 64'd7396261888;

    wire [31:0] sd_lba;
    wire        sd_rd;
    reg         sd_ack = 0;
    reg  [13:0] sd_buff_addr = 0;
    reg  [7:0]  sd_buff_dout = 0;
    reg         sd_buff_wr = 0;

    wire [7:0]  stream_data;
    wire        stream_valid;
    reg         busy = 1'b1;

    wire        debug_iso_mode, debug_iso_error;

    // Phase-10 enumeration outputs under test
    wire [3:0]  audio_ntracks, subp_ntracks;
    reg  [2:0]  attr_a_sel = 0, attr_s_sel = 0;
    wire [2:0]  attr_a_fmt;
    wire [3:0]  attr_a_ch;
    wire [15:0] attr_a_lang, attr_s_lang;

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size),
        .title_sel(4'd0), .vbuf_empty(1'b0), .menu_snap(1'b0),
        .jump_ttn(7'd0), .jump_pgn(8'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        // Phase-10 ports
        .audio_ntracks(audio_ntracks), .subp_ntracks(subp_ntracks),
        .attr_a_sel(attr_a_sel), .attr_a_fmt(attr_a_fmt), .attr_a_ch(attr_a_ch),
        .attr_a_lang(attr_a_lang), .attr_s_sel(attr_s_sel), .attr_s_lang(attr_s_lang),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(busy),
        .debug_active(), .debug_sd_rd(), .debug_sd_ack(), .debug_cache_has_data(),
        .debug_file_size(), .debug_total_sectors(), .debug_next_lba(),
        .debug_state(), .debug_iso_mode(debug_iso_mode), .debug_iso_error(debug_iso_error)
    );

    always #5 clk = ~clk;

    // ISO9660 metadata: 5 sectors, order 16,261,266,267,268
    reg [7:0] meta [0:5*2048-1];
    initial $readmemh("bench/dvd/test_vobs/mib_iso_meta.hex", meta);
    // Real VTS_21_0.IFO VTSI_MAT sector (ISO LBA 1683520)
    reg [7:0] vtsimat [0:2047];
    initial $readmemh("bench/dvd/test_vobs/mib_vts21_vtsi_mat.hex", vtsimat);

    localparam VTSI_LBA = 32'd1683520;

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

    // mock HPS: one 512-byte block per sd_rd, from the metadata fixtures
    integer m = 0, bc = 0, lat = 0, mi;
    reg [31:0] rlba = 0;
    reg [31:0] slog = 0;   // 2048-logical sector of this read
    always @(posedge clk) begin
        sd_buff_wr <= 1'b0;
        case (m)
        0: begin sd_ack <= 1'b0; if (sd_rd) begin rlba <= sd_lba; lat <= 3; m <= 1; end end
        1: begin if (lat!=0) lat<=lat-1; else begin sd_ack<=1'b1; bc<=0; m<=2; end end
        2: begin
            sd_ack <= 1'b1; sd_buff_wr <= 1'b1; sd_buff_addr <= bc[13:0];
            slog = rlba;
            mi = meta_idx(slog);
            if (mi >= 0)             sd_buff_dout <= meta[mi*2048 + bc];
            else if (slog==VTSI_LBA) sd_buff_dout <= vtsimat[bc];
            else                     sd_buff_dout <= 8'h00;
            bc <= bc + 1;
            if (bc == 2047) m <= 3;
        end
        3: begin sd_ack <= 1'b0; sd_buff_wr <= 1'b0; m <= 0; end
        endcase
    end

    integer errors = 0;
    integer t, i;

    task chk_a(input [2:0] trk, input [2:0] fmt, input [3:0] ch, input [15:0] lang);
        begin
            attr_a_sel = trk; #1;
            if (attr_a_fmt !== fmt || attr_a_ch !== ch || attr_a_lang !== lang) begin
                errors = errors + 1;
                $display("  ERR audio[%0d]: fmt=%0d ch=%0d lang=%04x (want fmt=%0d ch=%0d lang=%04x)",
                         trk, attr_a_fmt, attr_a_ch, attr_a_lang, fmt, ch, lang);
            end
        end
    endtask

    task chk_s(input [2:0] trk, input [15:0] lang);
        begin
            attr_s_sel = trk; #1;
            if (attr_s_lang !== lang) begin
                errors = errors + 1;
                $display("  ERR subp[%0d]: lang=%04x (want %04x)", trk, attr_s_lang, lang);
            end
        end
    endtask

    initial begin
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        // Run until both counts are set (subp count is set at the START of the
        // subp phase, its per-track langs during the table sweep that follows),
        // then settle to let the full subpicture table sweep complete.
        t = 0;
        while (!(audio_ntracks != 4'd8 && subp_ntracks != 4'd8) && t < 400000) begin
            @(posedge clk); t = t + 1;
        end
        repeat (200) @(posedge clk);   // let the subp attribute sweep finish

        $display("ATTR: iso_mode=%b iso_error=%b audio_ntracks=%0d subp_ntracks=%0d",
                 debug_iso_mode, debug_iso_error, audio_ntracks, subp_ntracks);

        if (audio_ntracks !== 4'd4) begin errors=errors+1; $display("  ERR audio_ntracks (want 4)"); end
        if (subp_ntracks  !== 4'd4) begin errors=errors+1; $display("  ERR subp_ntracks (want 4)"); end

        // Per-track: en=0x656e, fr=0x6672, es=0x6573, AC3=fmt 0
        chk_a(3'd0, 3'd0, 4'd2, 16'h656e);   // English 2.0
        chk_a(3'd1, 3'd0, 4'd6, 16'h656e);   // English 5.1
        chk_a(3'd2, 3'd0, 4'd2, 16'h6672);   // French 2.0
        chk_a(3'd3, 3'd0, 4'd2, 16'h656e);   // English commentary 2.0
        chk_s(3'd0, 16'h656e);               // English subs
        chk_s(3'd1, 16'h6672);               // French subs
        chk_s(3'd2, 16'h6573);               // Spanish subs
        chk_s(3'd3, 16'h656e);               // English subs

        if (errors == 0) $display("ISO_READER_ATTR_TB: PASSED (MiB VTS_21 4 audio / 4 subp, codec+ch+lang exact)");
        else             $display("ISO_READER_ATTR_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin #6000000; $display("ISO_READER_ATTR_TB: TIMEOUT"); $finish; end

endmodule
