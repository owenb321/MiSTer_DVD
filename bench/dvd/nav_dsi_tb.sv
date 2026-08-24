// nav_dsi_tb.sv - Phase-7 DSI parse test for dvd/nav_dsi.sv.
//
// Drives the DSI byte stream sliced from a REAL NAV sector
// (bench/dvd/test_vobs/mib_menu_pci.hex - the same fixture ps_demux_ps2_tb
// uses; regenerate with:
//   python3 tools/nav_extract.py MEN_IN_BLACK.iso --vts 2 --sector 6836 \
//     --count 1 --hex bench/dvd/test_vobs/mib_menu_pci.hex --hex-count 1)
// and checks the parsed fields byte-exact against the golden decode from
// tools/nav_extract.py --dsi (validated on the same sector):
//   nv_pck_lbn=6836 vobu_ea=136 vob_idn=1 c_idn=2 c_eltm=00:00:00.c0
//   next_vobu=0x80000089 prev_vobu=0x3fffffff(END_OF_CELL)
//   fwda[0]=0x3fffffff fwda[2]=0x7fffffff fwda[3]=0xc0000ab8
//   bwda[0]=0x3fffffff
// The DSI DATA starts at byte 0x407 of the 2048-byte sector (the byte after the
// private_stream_2 0x01 substream id). Skipped with a warning if the (gitignored)
// fixture is absent.
`timescale 1ns/1ps
`default_nettype none

module nav_dsi_tb;
    logic        clk = 0, rst_n = 0;
    logic  [7:0] dsi_byte;
    logic        dsi_valid = 0, dsi_frame_start = 0;

    logic [31:0] nv_pck_lbn, vobu_ea, ref1_ea, c_eltm;
    logic [31:0] next_vobu, prev_vobu, next_video, prev_video;
    logic [15:0] vob_idn;
    logic [7:0]  c_idn;
    logic        commit;
    logic [5:0]  tbl_raddr = 0;
    logic [31:0] tbl_rdata;

    always #5 clk = ~clk;

    nav_dsi dut (
        .clk(clk), .rst_n(rst_n),
        .dsi_byte(dsi_byte), .dsi_valid(dsi_valid), .dsi_frame_start(dsi_frame_start),
        .dsi_nv_pck_lbn(nv_pck_lbn), .dsi_vobu_ea(vobu_ea), .dsi_1stref_ea(ref1_ea),
        .dsi_vob_idn(vob_idn), .dsi_c_idn(c_idn), .dsi_c_eltm(c_eltm),
        .dsi_next_vobu(next_vobu), .dsi_prev_vobu(prev_vobu),
        .dsi_next_video(next_video), .dsi_prev_video(prev_video),
        .dsi_commit(commit),
        .tbl_raddr(tbl_raddr), .tbl_rdata(tbl_rdata)
    );

    // whole 2048-byte NAV sector (only the DSI portion is driven)
    localparam DSI_OFF = 12'h407;
    localparam DSI_LEN = 512;               // enough to cover through vobu_sri
    logic [7:0] sec [0:4095];           // fixture holds 2 NAV sectors; use sector 0
    integer errors = 0;
    integer i;

    task automatic feed_dsi;
        begin
            @(posedge clk); dsi_frame_start <= 1'b1; dsi_valid <= 1'b1;
            dsi_byte <= sec[DSI_OFF];
            @(posedge clk); dsi_frame_start <= 1'b0;
            for (i = 1; i < DSI_LEN; i = i + 1) begin
                dsi_byte <= sec[DSI_OFF + i];
                @(posedge clk);
            end
            dsi_valid <= 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic ck32(input [127:0] name, input [31:0] got, input [31:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL %0s: got %08x exp %08x", name, got, exp);
                errors = errors + 1;
            end else
                $display("  ok  %0s = %08x", name, got);
        end
    endtask

    // read a dsi_tbl entry (sync read: address one cycle ahead)
    task automatic ck_tbl(input [127:0] name, input [5:0] a, input [31:0] exp);
        begin
            tbl_raddr <= a; @(posedge clk); @(posedge clk);
            ck32(name, tbl_rdata, exp);
        end
    endtask

    initial begin
        for (i = 0; i < 4096; i = i + 1) sec[i] = 8'h00;
        $readmemh("bench/dvd/test_vobs/mib_menu_pci.hex", sec);
        // fixture absent / not a NAV sector -> skip cleanly
        if (sec[0]!==8'h00 || sec[1]!==8'h00 || sec[2]!==8'h01 || sec[3]!==8'hBA
            || sec[DSI_OFF-1]!==8'h01) begin
            $display("nav_dsi_tb: fixture missing/not a NAV sector - SKIPPED");
            $finish;
        end

        repeat (3) @(posedge clk); rst_n <= 1'b1; repeat (2) @(posedge clk);

        feed_dsi();
        repeat (2) @(posedge clk);

        $display("nav_dsi_tb: scalar fields");
        ck32("nv_pck_lbn", nv_pck_lbn, 32'd6836);
        ck32("vobu_ea",    vobu_ea,    32'd136);
        ck32("ref1_ea",    ref1_ea,    32'd42);
        ck32("vob_idn",    {16'd0, vob_idn}, 32'd1);
        ck32("c_idn",      {24'd0, c_idn},   32'd2);
        ck32("c_eltm",     c_eltm,     32'h000000c0);
        ck32("next_video", next_video, 32'h80000089);
        ck32("next_vobu",  next_vobu,  32'h80000089);
        ck32("prev_vobu",  prev_vobu,  32'h3fffffff);
        ck32("prev_video", prev_video, 32'hbfffffff);

        $display("nav_dsi_tb: seek/angle table (dsi_tbl)");
        ck_tbl("fwda[0]",  6'd0,  32'h3fffffff);
        ck_tbl("fwda[2]",  6'd2,  32'h7fffffff);
        ck_tbl("fwda[3]",  6'd3,  32'hc0000ab8);
        ck_tbl("bwda[0]",  6'd19, 32'h3fffffff);

        // Phase-8 scrub target math: +10 s = fwda[3] (see tools/nav_extract.py
        // dsi_seek_map). target RBN = nv_pck_lbn + (entry & 0x3fffffff).
        // Golden (validated against the real MiB fixture): 6836 + 0xab8 = 9580.
        tbl_raddr <= 6'd3; @(posedge clk); @(posedge clk);
        begin
            reg [29:0] off; reg valid; reg [31:0] tgt;
            off   = tbl_rdata[29:0];
            valid = tbl_rdata[31] && (tbl_rdata[29:0] != 30'h3fffffff);
            tgt   = nv_pck_lbn + {2'd0, off};
            if (!valid)          begin $display("FAIL scrub +10s: fwda[3] not valid"); errors=errors+1; end
            else ck32("scrub +10s target RBN", tgt, 32'd9580);
        end
        // bwda[15] (-10 s) on this cell-start menu VOBU is END_OF_CELL (no prev).
        ck_tbl("bwda[15] (=addr34)", 6'd34, 32'h3fffffff);

        if (errors == 0) $display("nav_dsi_tb: PASS");
        else             $display("nav_dsi_tb: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
