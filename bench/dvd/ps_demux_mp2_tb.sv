// ps_demux_mp2_tb.sv — MPEG audio (stream_id 0xC0-0xC7 = DVD MP2) routing tests
//
// Verifies the MP2 additions to ps_demux:
//   T1: 0xC0 PES with PTS -> payload on aud_byte, aud_type==3, aud_frame_start on
//       the first payload byte, aud_frame_pts == the PES PTS, pts_valid high.
//   T2: 0xC1 PES (non-selected track) is discarded entirely (skip-by-length), and
//       a 00 00 01 pattern inside its payload does NOT desync the demux (the
//       following video PES still routes).
//   T3: 0xC0 PES with NO optional header bytes (header_data_length == 0) routes.
//   T4: 0xC0 PES with optional header but no PTS (stuffing bytes) routes,
//       aud_frame_pts_valid low.
//   T5: 0xBD AC-3 substream 0x80 still routes as type 0 after an MP2 PES
//       (regression: the S_SUBSTREAM_ID path is untouched).
//   T6: aud_track=2 selects 0xC2 and discards 0xC0.
//
// Run:
//   iverilog -g2012 -o bench/dvd/ps_demux_mp2_sim dvd/ps_demux.sv bench/dvd/ps_demux_mp2_tb.sv
//   vvp bench/dvd/ps_demux_mp2_sim

`timescale 1ns/1ps
`default_nettype none

module ps_demux_mp2_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0;

    logic [7:0] in_byte;
    logic       in_valid;
    wire        in_ready;
    logic [2:0] aud_track = 3'd0;

    wire [7:0]  vid_byte;
    wire        vid_valid;
    wire [7:0]  aud_byte;
    wire        aud_valid;
    wire [1:0]  aud_type;
    wire        aud_frame_start;
    wire [32:0] aud_frame_pts;
    wire        aud_frame_pts_valid;

    ps_demux dut (
        .clk(clk), .rst_n(rst_n),
        .in_byte(in_byte), .in_valid(in_valid), .in_ready(in_ready),
        .aud_track(aud_track),
        .sp_track(3'd0), .sp_enable(1'b0),
        .vid_byte(vid_byte), .vid_valid(vid_valid), .vid_ready(1'b1),
        .aud_byte(aud_byte), .aud_valid(aud_valid), .aud_type(aud_type),
        .aud_frame_start(aud_frame_start), .aud_ready(1'b1),
        .vid_pts(), .vid_pts_valid(), .aud_pts(), .aud_pts_valid(),
        .aud_frame_pts(aud_frame_pts), .aud_frame_pts_valid(aud_frame_pts_valid),
        .sp_byte(), .sp_valid(), .sp_frame_start(), .sp_pts(), .sp_pts_valid(),
        .pci_enable(1'b0), .pci_byte(), .pci_valid(), .pci_frame_start(),
        .dsi_enable(1'b0), .dsi_byte(), .dsi_valid(), .dsi_frame_start(),
        .aud_lpcm_quant(), .pes_scrambled()
    );

    int errs = 0;

    // Capture audio output
    byte aud_cap[$];
    int  start_marks[$];        // indices in aud_cap where frame_start pulsed
    logic [32:0] pts_at_start;
    logic        ptsv_at_start;
    logic [1:0]  type_at_start;

    always @(posedge clk) begin
        if (aud_valid && in_ready && in_valid) begin
            if (aud_frame_start) begin
                start_marks.push_back(aud_cap.size());
                pts_at_start  <= aud_frame_pts;
                ptsv_at_start <= aud_frame_pts_valid;
                type_at_start <= aud_type;
            end
            aud_cap.push_back(aud_byte);
        end
    end

    byte vid_cap[$];
    always @(posedge clk)
        if (vid_valid && in_ready && in_valid) vid_cap.push_back(vid_byte);

    // Drive with nonblocking assignments so same-edge observers (the capture
    // monitor, the DUT) sample consistent values — blocking drives at a posedge
    // race the always blocks (Icarus scheduling order).
    task feed(input byte b);
        begin
            in_byte  <= b;
            in_valid <= 1'b1;
            do @(posedge clk); while (!in_ready);
            in_valid <= 1'b0;
        end
    endtask

    task feed_bytes(input byte arr[]);
        foreach (arr[i]) feed(arr[i]);
    endtask

    // Build an MP2 PES: stream_id sid, payload pl[], with/without PTS.
    // hdr_mode: 0 = no optional bytes, 1 = 5-byte PTS, 2 = 3 stuffing bytes (no PTS)
    task send_mp2_pes(input byte sid, input byte pl[], input int hdr_mode,
                      input logic [32:0] pts);
        int hlen;
        int plen;
        begin
            hlen = (hdr_mode == 1) ? 5 : (hdr_mode == 2) ? 3 : 0;
            plen = 3 + hlen + pl.size();   // flags1+flags2+hdr_len + opt + payload
            feed(8'h00); feed(8'h00); feed(8'h01); feed(sid);
            feed(byte'(plen >> 8)); feed(byte'(plen & 8'hFF));
            feed(8'h80);                                  // flags1: '10', not scrambled
            feed((hdr_mode == 1) ? 8'h80 : 8'h00);        // flags2: PTS flag
            feed(byte'(hlen));
            if (hdr_mode == 1) begin
                // PTS '0010' + pts[32:30] + marker, etc.
                feed({4'b0010, pts[32], pts[31:30], 1'b1});
                feed(pts[29:22]);
                feed({pts[21:15], 1'b1});
                feed(pts[14:7]);
                feed({pts[6:0], 1'b1});
            end else begin
                repeat (hlen) feed(8'hFF);                // stuffing
            end
            feed_bytes(pl);
        end
    endtask

    task check(input bit cond, input string msg);
        if (!cond) begin errs++; $display("FAIL: %s", msg); end
    endtask

    byte pl1[] = '{8'hFF, 8'hFD, 8'h84, 8'h11, 8'h22, 8'h33};
    byte pl_trap[] = '{8'h00, 8'h00, 8'h01, 8'hE0, 8'hAA};   // start-code pattern inside payload
    byte pl3[] = '{8'h55, 8'h66};
    byte pl4[] = '{8'h77, 8'h88, 8'h99};
    byte plv[] = '{8'hDE, 8'hAD};
    byte ac3pl[] = '{8'h0B, 8'h77, 8'h10, 8'h20};
    int  base;
    int  plen5;

    initial begin
        in_valid = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // Prime PS mode with a pack header (9 fixed + stuffing_len byte = 0)
        feed(8'h00); feed(8'h00); feed(8'h01); feed(8'hBA);
        repeat (9) feed(8'h44);
        feed(8'h00);   // stuffing length 0

        // T1: 0xC0 with PTS
        send_mp2_pes(8'hC0, pl1, 1, 33'h1_2345_6789);
        repeat (4) @(posedge clk);
        check(aud_cap.size() == 6, "T1 payload byte count");
        check(start_marks.size() == 1 && start_marks[0] == 0, "T1 frame_start on first byte");
        check(type_at_start == 2'd3, "T1 aud_type == 3 (MP2)");
        check(ptsv_at_start === 1'b1, "T1 pts_valid");
        check(pts_at_start === 33'h1_2345_6789, "T1 PTS value");
        foreach (pl1[i]) check(aud_cap[i] == pl1[i], "T1 payload bytes");

        // T2: 0xC1 (wrong track) with an embedded start-code trap, then a video PES
        base = aud_cap.size();
        send_mp2_pes(8'hC1, pl_trap, 1, 33'h0);
        // video PES: 0xE0, no optional bytes, payload plv
        feed(8'h00); feed(8'h00); feed(8'h01); feed(8'hE0);
        feed(8'h00); feed(byte'(3 + plv.size()));
        feed(8'h80); feed(8'h00); feed(8'h00);
        feed_bytes(plv);
        repeat (4) @(posedge clk);
        check(aud_cap.size() == base, "T2 wrong-track MP2 discarded");
        check(vid_cap.size() == 2 && vid_cap[0] == 8'hDE && vid_cap[1] == 8'hAD,
              "T2 video PES after trap routed intact");

        // T3: no optional header bytes
        base = aud_cap.size();
        send_mp2_pes(8'hC0, pl3, 0, 33'h0);
        repeat (4) @(posedge clk);
        check(aud_cap.size() == base + 2, "T3 payload routed (hdr_len=0)");
        check(start_marks.size() == 2 && start_marks[1] == base, "T3 frame_start");
        check(ptsv_at_start === 1'b0, "T3 pts_valid low (no PTS)");

        // T4: optional header, stuffing only (no PTS)
        base = aud_cap.size();
        send_mp2_pes(8'hC0, pl4, 2, 33'h0);
        repeat (4) @(posedge clk);
        check(aud_cap.size() == base + 3, "T4 payload routed (stuffing hdr)");
        check(ptsv_at_start === 1'b0, "T4 pts_valid low");

        // T5: 0xBD AC-3 substream 0x80 regression
        base = aud_cap.size();
        plen5 = 3 + 0 + 1 + 3 + ac3pl.size(); // hdr + substream + subhdr(3) + payload
        feed(8'h00); feed(8'h00); feed(8'h01); feed(8'hBD);
        feed(byte'(plen5 >> 8)); feed(byte'(plen5 & 8'hFF));
        feed(8'h80); feed(8'h00); feed(8'h00);   // no optional bytes
        feed(8'h80);                             // substream_id: AC-3 track 0
        feed(8'h01); feed(8'h00); feed(8'h01);   // sub-header (frame count/ptr)
        feed_bytes(ac3pl);
        repeat (4) @(posedge clk);
        check(aud_cap.size() == base + 4, "T5 AC-3 payload routed");
        check(type_at_start == 2'd0, "T5 aud_type == 0 (AC-3)");

        // T6: aud_track=2 -> 0xC2 selected, 0xC0 discarded
        aud_track = 3'd2;
        base = aud_cap.size();
        send_mp2_pes(8'hC0, pl3, 0, 33'h0);
        send_mp2_pes(8'hC2, pl4, 0, 33'h0);
        repeat (4) @(posedge clk);
        check(aud_cap.size() == base + 3, "T6 only 0xC2 routed");
        check(type_at_start == 2'd3, "T6 aud_type == 3");

        if (errs == 0) begin
            $display("PASS: ps_demux_mp2_tb (6 scenarios)");
            $finish;
        end else begin
            $display("RESULT: %0d error(s)", errs);
            $fatal(1, "ps_demux_mp2_tb failed");
        end
    end

    initial begin
        #2_000_000;
        $display("TIMEOUT");
        $fatal(1, "ps_demux_mp2_tb timeout");
    end

endmodule

`default_nettype wire
