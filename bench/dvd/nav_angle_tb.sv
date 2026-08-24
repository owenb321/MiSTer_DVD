// nav_angle_tb.sv - Phase-9 multi-angle DSI decode, byte-exact vs a REAL disc.
//
// Drives the DSI byte stream of the real MiB VTS_14 (title 13, a 5-angle FX
// breakdown) NAV sector at RBN 37 (a BLOCK|LAST VOBU = an ILVU jump point)
// through dvd/nav_dsi.sv and checks the parsed sml_pbi.category + the golden
// per-angle next-ILVU target against tools/nav_extract.py --angles:
//   category = 0x5000 (BLOCK|LAST)   nv_pck_lbn = 37   vobu_ea = 160
//   sml_agli angle 1 = 0x000003a6 (+934)  -> RBN 971
//   sml_agli angle 2 = 0x000004f7 (+1271) -> RBN 1308
// Fixture: bench/dvd/test_vobs/mib_angle_dsi.hex holds RBNs 0/20/37 (sector 2 =
// RBN 37). Regenerate with:
//   python3 tools/nav_extract.py MEN_IN_BLACK.iso --vts 14 --title-vob 1 \
//     --angles --count 40 --hex bench/dvd/test_vobs/mib_angle_dsi.hex --hex-count 3
// The reader (dvd_iso_reader) snoops these same DSI offsets (0x407-relative) off
// the sd stream; nav_dsi is the golden-tested parser they share. Skipped with a
// warning if the (gitignored) fixture is absent.

`timescale 1ns/1ps
`default_nettype none

module nav_angle_tb;
    logic        clk = 0, rst_n = 0;
    logic  [7:0] dsi_byte;
    logic        dsi_valid = 0, dsi_frame_start = 0;

    logic [31:0] nv_pck_lbn, vobu_ea, ref1_ea, c_eltm;
    logic [31:0] next_vobu, prev_vobu, next_video, prev_video;
    logic [15:0] vob_idn, category;
    logic [7:0]  c_idn;
    logic        commit, ilvu_block, ilvu_last;
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
        .dsi_category(category), .dsi_ilvu_block(ilvu_block), .dsi_ilvu_last(ilvu_last),
        .dsi_commit(commit),
        .tbl_raddr(tbl_raddr), .tbl_rdata(tbl_rdata)
    );

    localparam DSI_OFF = 12'h407;
    localparam DSI_LEN = 512;
    logic [7:0] sec [0:6143];               // fixture holds 3 NAV sectors
    localparam integer RBN37 = 2*2048;      // sector index 2 = RBN 37
    integer errors = 0;
    integer i;

    // golden per-angle target: nv_pck_lbn +/- (addr & 0x3fffffff)
    function [31:0] angle_target(input [31:0] lbn, input [31:0] addr);
        logic [29:0] off; logic neg;
        begin
            off = addr[29:0];
            neg = addr[31] && (addr != 32'h7fffffff);
            angle_target = neg ? (lbn - {2'b0, off}) : (lbn + {2'b0, off});
        end
    endfunction

    task automatic feed_dsi;
        begin
            @(posedge clk); dsi_frame_start <= 1'b1; dsi_valid <= 1'b1;
            dsi_byte <= sec[RBN37 + DSI_OFF];
            @(posedge clk); dsi_frame_start <= 1'b0;
            for (i = 1; i < DSI_LEN; i = i + 1) begin
                dsi_byte <= sec[RBN37 + DSI_OFF + i];
                @(posedge clk);
            end
            dsi_valid <= 1'b0;
            @(posedge clk);
        end
    endtask

    task check32(input [31:0] got, input [31:0] want, input [127:0] nm);
        begin
            if (got !== want) begin
                errors = errors + 1;
                $display("  FAIL %0s = %08x (want %08x)", nm, got, want);
            end else $display("  ok  %0s = %08x", nm, got);
        end
    endtask

    initial begin
        for (i = 0; i < 6144; i = i + 1) sec[i] = 8'hxx;
        $readmemh("bench/dvd/test_vobs/mib_angle_dsi.hex", sec);
        if (sec[RBN37] === 8'hxx) begin
            $display("nav_angle_tb: SKIP (fixture mib_angle_dsi.hex absent)");
            $finish;
        end

        rst_n = 0; repeat (3) @(posedge clk); rst_n = 1; @(posedge clk);
        feed_dsi;
        repeat (2) @(posedge clk);

        $display("nav_angle_tb: MiB VTS_14 RBN 37 (BLOCK|LAST)");
        check32({16'd0, category}, 32'h00005000, "category");
        if (ilvu_block !== 1'b1) begin errors=errors+1; $display("  FAIL ilvu_block!=1"); end
        if (ilvu_last  !== 1'b1) begin errors=errors+1; $display("  FAIL ilvu_last!=1");  end
        check32(nv_pck_lbn, 32'd37,  "nv_pck_lbn");
        check32(vobu_ea,    32'd160, "vobu_ea");

        // sml_agli angle 1 (dsi_tbl addr 38) and angle 2 (39) -> golden targets
        tbl_raddr = 6'd38; repeat (2) @(posedge clk);
        check32(tbl_rdata, 32'h000003a6, "sml_agli[angle1]");
        check32(angle_target(nv_pck_lbn, tbl_rdata), 32'd971,  "angle1 target RBN");
        tbl_raddr = 6'd39; repeat (2) @(posedge clk);
        check32(angle_target(nv_pck_lbn, tbl_rdata), 32'd1308, "angle2 target RBN");

        if (errors == 0) $display("nav_angle_tb: PASS");
        else             $display("nav_angle_tb: %0d FAILURE(S)", errors);
        $finish;
    end
endmodule
`default_nettype wire
