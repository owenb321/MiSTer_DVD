// ps_demux_m1_tb.sv - MPEG-1 system-stream (VCD) path test for dvd/ps_demux.sv.
//
// TEST 1: a real VCD slice (bench/dvd/test_vobs/vcd_mid.golden.hex = 64
//   deblocked Form-2 sectors of a PAL VCD = a flat MPEG-1 system stream;
//   exercises 0xFF stuffing, the STD buffer field, PTS, PTS+DTS and the 0x0F
//   no-timestamp header forms, plus system headers 0xBB and padding 0xBE).
//   Video/audio ES outputs must be BYTE-IDENTICAL to the tools/mpeg1_ps_ref.py
//   goldens (vcd_mid.ves.hex / vcd_mid.aes.hex), the vid/aud PTS pulse
//   sequences must match vcd_mid.vpts.hex / vcd_mid.apts.hex, and
//   pes_scrambled must never pulse (CSS is a DVD concept; the MPEG-1 header
//   path must not touch it). Random video-output backpressure exercises the
//   held-byte handshake.
//
// TEST 2: synthetic flavour re-latch: an MPEG-1 pack + PES (PTS+DTS with STD)
//   followed by an MPEG-2 pack + PES (MPEG-2 flags/hdr_len shape) — both must
//   parse, proving mpeg1_ps re-latches per pack and the MPEG-2 path is
//   untouched. Regenerate fixtures with: VCD_TRACK_BIN=<track2.bin>
//   tools/vcd_fixtures.py
`timescale 1ns/1ps
`default_nettype none

module ps_demux_m1_tb;
    localparam int MAXB = 262144;

    logic        clk = 0, rst_n = 0;
    logic  [7:0] in_byte;
    logic        in_valid = 0;
    logic        in_ready;
    logic  [7:0] vid_byte;
    logic        vid_valid;
    logic        vid_ready = 1'b1;
    logic  [7:0] aud_byte;
    logic        aud_valid, aud_frame_start;
    logic  [1:0] aud_type;
    logic [32:0] vid_pts, aud_pts;
    logic        vid_pts_valid, aud_pts_valid;
    logic        pes_scrambled;

    always #5 clk = ~clk;

    ps_demux dut (
        .clk(clk), .rst_n(rst_n),
        .in_byte(in_byte), .in_valid(in_valid), .in_ready(in_ready),
        .aud_track(3'd0), .sp_track(3'd0), .sp_enable(1'b0),
        .vid_byte(vid_byte), .vid_valid(vid_valid), .vid_ready(vid_ready),
        .aud_byte(aud_byte), .aud_valid(aud_valid), .aud_type(aud_type),
        .aud_frame_start(aud_frame_start), .aud_ready(1'b1),
        .vid_pts(vid_pts), .vid_pts_valid(vid_pts_valid),
        .aud_pts(aud_pts), .aud_pts_valid(aud_pts_valid),
        .aud_frame_pts(), .aud_frame_pts_valid(),
        .sp_byte(), .sp_valid(), .sp_frame_start(), .sp_pts(), .sp_pts_valid(),
        .pci_enable(1'b0), .pci_byte(), .pci_valid(), .pci_frame_start(),
        .dsi_enable(1'b0), .dsi_byte(), .dsi_valid(), .dsi_frame_start(),
        .aud_lpcm_quant(), .pes_scrambled(pes_scrambled)
    );

    // ---- captures ----
    logic  [7:0] vgot [0:MAXB-1]; int vg = 0;
    logic  [7:0] agot [0:MAXB-1]; int ag = 0;
    logic [32:0] vpgot [0:255];   int vp = 0;
    logic [32:0] apgot [0:255];   int ap = 0;
    int scram = 0;
    always_ff @(posedge clk) if (rst_n) begin
        if (vid_valid && vid_ready) begin vgot[vg] <= vid_byte; vg <= vg + 1; end
        if (aud_valid)              begin agot[ag] <= aud_byte; ag <= ag + 1; end
        if (vid_pts_valid)          begin vpgot[vp] <= vid_pts; vp <= vp + 1; end
        if (aud_pts_valid)          begin apgot[ap] <= aud_pts; ap <= ap + 1; end
        if (pes_scrambled)          scram <= scram + 1;
    end

    // random video backpressure (about 25% stall)
    logic [15:0] lfsr = 16'hACE1;
    always_ff @(posedge clk) begin
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        vid_ready <= (lfsr[1:0] != 2'b00);
    end

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

    // ---- fixture loaders (line-counted, so regenerated sizes just work) ----
    logic [7:0] ps  [0:MAXB-1]; int ps_n  = 0;
    logic [7:0] ves [0:MAXB-1]; int ves_n = 0;
    logic [7:0] aes [0:MAXB-1]; int aes_n = 0;
    logic [32:0] vpts_g [0:255]; int vpts_n = 0;
    logic [32:0] apts_g [0:255]; int apts_n = 0;

    // Icarus has no ref ports: per-array loader tasks (line-counted).
    int fd, r;
    logic [39:0] v;

    task load_ps(input string path);
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin $display("FATAL: cannot open %s", path); $fatal(1); end
            ps_n = 0;
            while (!$feof(fd)) begin
                r = $fscanf(fd, "%h\n", v);
                if (r == 1) begin ps[ps_n] = v[7:0]; ps_n++; end
            end
            $fclose(fd);
        end
    endtask
    task load_ves(input string path);
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin $display("FATAL: cannot open %s", path); $fatal(1); end
            ves_n = 0;
            while (!$feof(fd)) begin
                r = $fscanf(fd, "%h\n", v);
                if (r == 1) begin ves[ves_n] = v[7:0]; ves_n++; end
            end
            $fclose(fd);
        end
    endtask
    task load_aes(input string path);
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin $display("FATAL: cannot open %s", path); $fatal(1); end
            aes_n = 0;
            while (!$feof(fd)) begin
                r = $fscanf(fd, "%h\n", v);
                if (r == 1) begin aes[aes_n] = v[7:0]; aes_n++; end
            end
            $fclose(fd);
        end
    endtask
    task load_vpts(input string path);
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin $display("FATAL: cannot open %s", path); $fatal(1); end
            vpts_n = 0;
            while (!$feof(fd)) begin
                r = $fscanf(fd, "%h\n", v);
                if (r == 1) begin vpts_g[vpts_n] = v[32:0]; vpts_n++; end
            end
            $fclose(fd);
        end
    endtask
    task load_apts(input string path);
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin $display("FATAL: cannot open %s", path); $fatal(1); end
            apts_n = 0;
            while (!$feof(fd)) begin
                r = $fscanf(fd, "%h\n", v);
                if (r == 1) begin apts_g[apts_n] = v[32:0]; apts_n++; end
            end
            $fclose(fd);
        end
    endtask

    int i;
    initial begin
        load_ps("bench/dvd/test_vobs/vcd_mid.golden.hex");
        load_ves("bench/dvd/test_vobs/vcd_mid.ves.hex");
        load_aes("bench/dvd/test_vobs/vcd_mid.aes.hex");
        load_vpts("bench/dvd/test_vobs/vcd_mid.vpts.hex");
        load_apts("bench/dvd/test_vobs/vcd_mid.apts.hex");
        $display("fixture: %0d PS bytes, golden v=%0d a=%0d vpts=%0d apts=%0d",
                 ps_n, ves_n, aes_n, vpts_n, apts_n);

        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);

        // ---------------- TEST 1: real VCD slice ----------------
        for (i = 0; i < ps_n; i++) feed(ps[i]);
        repeat (100) @(posedge clk);

        $display("TEST1: vid=%0d aud=%0d vpts=%0d apts=%0d scram=%0d",
                 vg, ag, vp, ap, scram);
        chk(vg == ves_n, "video ES byte count");
        chk(ag == aes_n, "audio ES byte count");
        chk(vp == vpts_n, "video PTS count");
        chk(ap == apts_n, "audio PTS count");
        chk(scram == 0, "pes_scrambled pulsed on MPEG-1 stream");
        for (i = 0; i < ves_n && i < vg; i++)
            if (vgot[i] !== ves[i]) begin
                errors++;
                if (errors < 10) $display("  VID MISMATCH @%0d: got %02x want %02x", i, vgot[i], ves[i]);
            end
        for (i = 0; i < aes_n && i < ag; i++)
            if (agot[i] !== aes[i]) begin
                errors++;
                if (errors < 10) $display("  AUD MISMATCH @%0d: got %02x want %02x", i, agot[i], aes[i]);
            end
        for (i = 0; i < vpts_n && i < vp; i++)
            chk(vpgot[i] === vpts_g[i], $sformatf("vid PTS[%0d]", i));
        for (i = 0; i < apts_n && i < ap; i++)
            chk(apgot[i] === apts_g[i], $sformatf("aud PTS[%0d]", i));
        chk(aud_type == 2'd3, "aud_type is T_MP2");

        // ---------------- TEST 2: MPEG-1 -> MPEG-2 flavour re-latch ----------------
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        vg = 0; ag = 0; vp = 0; ap = 0;

        // MPEG-1 pack (12 bytes: 00 00 01 BA + 0x2X marker + 7)
        feed(8'h00); feed(8'h00); feed(8'h01); feed(8'hBA);
        feed(8'h21); for (i = 0; i < 7; i++) feed(8'h11);
        // MPEG-1 video PES: len 16 = FF stuffing + STD(2) + PTS+DTS(10) + 3 payload
        feed(8'h00); feed(8'h00); feed(8'h01); feed(8'hE0);
        feed(8'h00); feed(8'h10);
        feed(8'hFF);                                  // stuffing
        feed(8'h60); feed(8'h2E);                     // STD buffer field
        feed(8'h31); feed(8'h00); feed(8'h05); feed(8'h57); feed(8'hF9); // PTS
        feed(8'h11); feed(8'h00); feed(8'h05); feed(8'h03); feed(8'h99); // DTS
        feed(8'hA1); feed(8'hA2); feed(8'hA3);        // payload
        // MPEG-2 pack (14 bytes: 00 00 01 BA + '01' marker + 8 + stuffing len 0)
        feed(8'h00); feed(8'h00); feed(8'h01); feed(8'hBA);
        feed(8'h44); for (i = 0; i < 8; i++) feed(8'h22);
        feed(8'h00);
        // MPEG-2 video PES: len 11 = flags(2) hdr_len 5 + PTS(5) + 1 payload
        feed(8'h00); feed(8'h00); feed(8'h01); feed(8'hE0);
        feed(8'h00); feed(8'h0B);
        feed(8'h80); feed(8'h80); feed(8'h05);
        feed(8'h21); feed(8'h00); feed(8'h05); feed(8'h57); feed(8'hFB); // PTS
        feed(8'hB1);
        repeat (60) @(posedge clk);

        $display("TEST2: vid=%0d vpts=%0d", vg, vp);
        chk(vg == 4, "flavour re-latch video byte count (3 M1 + 1 M2)");
        chk(vp == 2, "flavour re-latch PTS count");
        chk(vgot[0] === 8'hA1 && vgot[1] === 8'hA2 && vgot[2] === 8'hA3
            && vgot[3] === 8'hB1, "flavour re-latch payload bytes");
        // 0x31 00 05 57 F9 -> PTS 0x00012BFC; MPEG-2 0x21 00 05 57 FB -> 0x00012BFD
        chk(vpgot[0] === 33'h00012BFC, "MPEG-1 PTS value");
        chk(vpgot[1] === 33'h00012BFD, "MPEG-2 PTS value");

        if (errors == 0) $display("PS_DEMUX_M1_TB: ALL TESTS PASSED");
        else begin
            $display("PS_DEMUX_M1_TB: FAILED with %0d errors", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #400000000;
        $display("PS_DEMUX_M1_TB: TIMEOUT");
        $fatal(1);
    end

endmodule
`default_nettype wire
