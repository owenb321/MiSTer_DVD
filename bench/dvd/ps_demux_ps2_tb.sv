// ps_demux_ps2_tb.sv - Phase-3 PCI routing test for dvd/ps_demux.sv.
//
// With pci_enable=1 a private_stream_2 (0xBF) packet whose FIRST payload byte
// (PS2 has NO PES optional header) is 0x00 = PCI must forward its remaining
// payload on pci_byte/pci_valid (pci_frame_start on the first byte); substream
// 0x01 = DSI (and others) stay discarded by length. The PCI payload embeds a
// fake 00 00 01 E0 - the classic desync trap - which must reach the PCI output
// as DATA and never trigger a start code (video output stays clean).
//
// TEST 1: synthetic PS: pack + PCI-carrying 0xBF (with trap) + DSI 0xBF +
//         video PES. Video gets only the real payload; PCI gets exactly the
//         PCI payload; DSI contributes nothing.
// TEST 2: a REAL NAV sector (bench/dvd/test_vobs/mib_menu_pci.hex, regenerate
//         with: python3 tools/nav_extract.py MEN_IN_BLACK.iso --vts 2
//         --sector 6836 --count 1 --hex bench/dvd/test_vobs/mib_menu_pci.hex
//         --hex-count 1). The 980-byte PCI data (after the substream id) must
//         come out byte-exact; hli_ss/btn_ns spot-checked. Skipped with a
//         warning if the (gitignored) fixture is absent.
`timescale 1ns/1ps
`default_nettype none

module ps_demux_ps2_tb;
    logic        clk = 0, rst_n = 0;
    logic  [7:0] in_byte;
    logic        in_valid = 0;
    logic        in_ready;
    logic  [7:0] vid_byte;
    logic        vid_valid;
    logic        vid_ready = 1'b1;
    logic  [7:0] pci_byte;
    logic        pci_valid, pci_frame_start;
    logic  [7:0] dsi_byte;
    logic        dsi_valid, dsi_frame_start;

    always #5 clk = ~clk;

    ps_demux dut (
        .clk(clk), .rst_n(rst_n),
        .in_byte(in_byte), .in_valid(in_valid), .in_ready(in_ready),
        .aud_track(3'd0), .sp_track(3'd0), .sp_enable(1'b0),
        .vid_byte(vid_byte), .vid_valid(vid_valid), .vid_ready(vid_ready),
        .aud_byte(), .aud_valid(), .aud_type(), .aud_frame_start(), .aud_ready(1'b1),
        .vid_pts(), .vid_pts_valid(), .aud_pts(), .aud_pts_valid(),
        .aud_frame_pts(), .aud_frame_pts_valid(),
        .sp_byte(), .sp_valid(), .sp_frame_start(), .sp_pts(), .sp_pts_valid(),
        .pci_enable(1'b1),
        .pci_byte(pci_byte), .pci_valid(pci_valid), .pci_frame_start(pci_frame_start),
        .dsi_enable(1'b1),
        .dsi_byte(dsi_byte), .dsi_valid(dsi_valid), .dsi_frame_start(dsi_frame_start)
    );

    // captures
    logic [7:0] vgot [0:63];   int vg = 0;
    logic [7:0] pgot [0:2047]; int pg = 0;
    logic [7:0] dgot [0:2047]; int dg = 0;
    int fs_count = 0;
    int ds_count = 0;
    always_ff @(posedge clk) if (rst_n) begin
        if (vid_valid && vid_ready) begin vgot[vg] <= vid_byte; vg <= vg + 1; end
        if (pci_valid) begin
            pgot[pg] <= pci_byte; pg <= pg + 1;
            if (pci_frame_start) fs_count <= fs_count + 1;
        end
        if (dsi_valid) begin
            dgot[dg] <= dsi_byte; dg <= dg + 1;
            if (dsi_frame_start) ds_count <= ds_count + 1;
        end
    end

    // NONBLOCKING drive (like ps_demux_nav_tb): a blocking assign right after
    // @(posedge clk) races the same-edge always_ff capture in Icarus.
    task feed(input [7:0] b);
        begin
            in_byte  <= b;
            in_valid <= 1;
            @(posedge clk);
            while (!in_ready) @(posedge clk);
            in_valid <= 0;
        end
    endtask

    int errors = 0;
    task chk(input bit cond, input string msg);
        if (!cond) begin errors++; $display("  ERR %s", msg); end
    endtask

    // TEST 1 stimulus
    localparam int PCIN = 11;   // PCI payload bytes (after the substream id)
    logic [7:0] pci_pay [0:PCIN-1] =
        '{8'h60, 8'h00, 8'h00, 8'h01, 8'hE0, 8'h00, 8'h09, 8'hAA, 8'h5A, 8'hA5, 8'h3C};

    // real NAV sector fixture (2 sectors in the file; we use the first)
    logic [7:0] nav [0:4095];

    int i;
    initial begin
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);

        // ---------------- TEST 1: synthetic ----------------
        // pack header
        feed(8'h00); feed(8'h00); feed(8'h01); feed(8'hBA);
        for (i = 0; i < 9; i++) feed(8'h44);
        feed(8'h00);
        // PCI: 0xBF len 12 = substream 0x00 + 11 payload (with the trap)
        feed(8'h00); feed(8'h00); feed(8'h01); feed(8'hBF);
        feed(8'h00); feed(8'h0C);
        feed(8'h00);                       // substream id = PCI
        for (i = 0; i < PCIN; i++) feed(pci_pay[i]);
        // DSI: 0xBF len 5 = substream 0x01 + 4 bytes (discarded)
        feed(8'h00); feed(8'h00); feed(8'h01); feed(8'hBF);
        feed(8'h00); feed(8'h05);
        feed(8'h01); feed(8'hDD); feed(8'hDD); feed(8'hDD); feed(8'hDD);
        // real video PES, length 7
        feed(8'h00); feed(8'h00); feed(8'h01); feed(8'hE0);
        feed(8'h00); feed(8'h07);
        feed(8'h00); feed(8'h00); feed(8'h00);
        feed(8'hDE); feed(8'hAD); feed(8'hBE); feed(8'hEF);
        repeat (10) @(posedge clk);

        $display("TEST1: vid=%0d pci=%0d fs=%0d (expect 4 %0d 1)", vg, pg, fs_count, PCIN);
        chk(vg == 4, "T1 video byte count (desync trap leaked?)");
        chk(vgot[0]==8'hDE && vgot[1]==8'hAD && vgot[2]==8'hBE && vgot[3]==8'hEF,
            "T1 video payload");
        chk(pg == PCIN, "T1 PCI byte count");
        chk(fs_count == 1, "T1 exactly one pci_frame_start");
        for (i = 0; i < PCIN; i++)
            chk(pgot[i] === pci_pay[i], $sformatf("T1 PCI byte %0d", i));
        // DSI (substream 0x01) now reaches the dsi sink (4 x 0xDD), one frame_start
        $display("TEST1: dsi=%0d ds=%0d (expect 4 1)", dg, ds_count);
        chk(dg == 4, "T1 DSI byte count");
        chk(ds_count == 1, "T1 exactly one dsi_frame_start");
        for (i = 0; i < 4; i++)
            chk(dgot[i] === 8'hDD, $sformatf("T1 DSI byte %0d", i));

        // ---------------- TEST 2: real NAV sector ----------------
        for (i = 0; i < 4096; i++) nav[i] = 8'hXX;
        $readmemh("bench/dvd/test_vobs/mib_menu_pci.hex", nav);
        if (nav[0] !== 8'h00 || nav[3] !== 8'hBA) begin
            $display("TEST2: fixture absent/unreadable -> SKIPPED (regenerate with tools/nav_extract.py)");
        end else begin
            pg = 0; fs_count = 0; vg = 0; dg = 0; ds_count = 0;
            for (i = 0; i < 2048; i++) feed(nav[i]);
            repeat (10) @(posedge clk);
            $display("TEST2: pci=%0d fs=%0d (expect 979 1)  hli_ss=%02x%02x btn_ns=%0d",
                     pg, fs_count, pgot[16'h60], pgot[16'h61], pgot[16'h71] & 8'h3F);
            // PCI PES length is 0x3D4 = 980 incl. the substream id -> 979 data bytes
            chk(pg == 979, "T2 PCI data byte count");
            chk(fs_count == 1, "T2 one pci_frame_start");
            // byte-exact vs the raw sector (PCI data starts at 0x2D)
            for (i = 0; i < 979; i++)
                chk(pgot[i] === nav['h2D + i], $sformatf("T2 PCI byte %0d", i));
            chk((({pgot['h60], pgot['h61]}) & 16'h3) != 0, "T2 hli_ss set (menu NAV)");
            chk((pgot['h71] & 8'h3F) == 8'd7, "T2 btn_ns = 7 (MiB menu)");
            // DSI (substream 0x01): PES @0x400 len 0x3FA=1018 -> 1017 data bytes
            // starting at 0x407, must reach the dsi sink byte-exact.
            $display("TEST2: dsi=%0d ds=%0d (expect 1017 1)  nv_pck_lbn=%02x%02x%02x%02x",
                     dg, ds_count, dgot['h4], dgot['h5], dgot['h6], dgot['h7]);
            chk(dg == 1017, "T2 DSI data byte count");
            chk(ds_count == 1, "T2 one dsi_frame_start");
            for (i = 0; i < 1017; i++)
                chk(dgot[i] === nav['h407 + i], $sformatf("T2 DSI byte %0d", i));
            // nv_pck_lbn @DSI+0x04 == 6836 (0x00001AB4)
            chk({dgot['h4],dgot['h5],dgot['h6],dgot['h7]} == 32'h00001AB4,
                "T2 DSI nv_pck_lbn = 6836");
        end

        if (errors == 0) $display("PS_DEMUX_PS2_TB: ALL TESTS PASSED");
        else             $display("PS_DEMUX_PS2_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin #40000000; $display("PS_DEMUX_PS2_TB: TIMEOUT"); $finish; end
endmodule
`default_nettype wire
