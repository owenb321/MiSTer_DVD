// =============================================================================
// bench/dvd/ps_demux_subpic_tb.sv — SUBPICTURE (subtitle) SUBSTREAM ROUTING
// =============================================================================
// DVD subpicture (subtitle) streams ride in private_stream_1 (stream_id 0xBD)
// with substream_id 0x20-0x3F. Unlike audio, subpicture has NO sub-header: the
// SPU payload begins with the byte right after the substream_id.
//
// This TB feeds:
//   - a pack header
//   - a subpicture PES on substream 0x20 (with a PTS) carrying payload D0..D3
//   - a subpicture PES on substream 0x21 carrying payload E0..E3
//   - an AC-3 audio PES on substream 0x80 carrying payload A0..A3
// and checks, for sp_track=0 / sp_enable=1:
//   * sp_valid forwards EXACTLY the 0x20 payload (0x21 and audio dropped from sp)
//   * sp_frame_start pulses on the first SPU byte
//   * sp_pts matches the PES PTS (assembled from the 5 PTS bytes)
//   * audio (0x80) is still routed to the audio port unaffected
// and, for sp_enable=0, that the subpicture PES is dropped entirely.
// =============================================================================
`timescale 1ns/1ps
module ps_demux_subpic_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [7:0] in_byte;
    logic       in_valid;
    wire        in_ready;
    logic [2:0] aud_track;
    logic [2:0] sp_track;
    logic       sp_enable;

    wire [7:0]  vid_byte;  wire vid_valid;  logic vid_ready = 1;
    wire [7:0]  aud_byte;  wire aud_valid;  wire [1:0] aud_type;
    wire        aud_frame_start; logic aud_ready = 1;
    wire [32:0] vid_pts; wire vid_pts_valid; wire [32:0] aud_pts; wire aud_pts_valid;
    wire [32:0] aud_frame_pts; wire aud_frame_pts_valid;
    wire [7:0]  sp_byte;  wire sp_valid;  wire sp_frame_start;
    wire [32:0] sp_pts;   wire sp_pts_valid;

    ps_demux dut (
        .clk(clk), .rst_n(rst_n),
        .in_byte(in_byte), .in_valid(in_valid), .in_ready(in_ready),
        .aud_track(aud_track),
        .sp_track(sp_track), .sp_enable(sp_enable),
        .vid_byte(vid_byte), .vid_valid(vid_valid), .vid_ready(vid_ready),
        .aud_byte(aud_byte), .aud_valid(aud_valid), .aud_type(aud_type),
        .aud_frame_start(aud_frame_start), .aud_ready(aud_ready),
        .vid_pts(vid_pts), .vid_pts_valid(vid_pts_valid),
        .aud_pts(aud_pts), .aud_pts_valid(aud_pts_valid),
        .aud_frame_pts(aud_frame_pts), .aud_frame_pts_valid(aud_frame_pts_valid),
        .sp_byte(sp_byte), .sp_valid(sp_valid), .sp_frame_start(sp_frame_start),
        .sp_pts(sp_pts), .sp_pts_valid(sp_pts_valid)
    );

    // collectors
    byte unsigned sp_log[$];
    byte unsigned aud_log[$];
    int   sp_frame_starts = 0;
    logic [32:0] captured_sp_pts;
    always @(posedge clk) if (rst_n && sp_valid) begin
        sp_log.push_back(sp_byte);
        if (sp_frame_start) begin sp_frame_starts++; captured_sp_pts = sp_pts; end
    end
    always @(posedge clk) if (rst_n && aud_valid && aud_ready) aud_log.push_back(aud_byte);

    task send_byte(input [7:0] b);
        @(posedge clk); in_byte = b; in_valid = 1;
        @(posedge clk); while (!in_ready) @(posedge clk); in_valid = 0;
    endtask
    task send_bytes(input byte unsigned d[], input int n);
        for (int i=0;i<n;i++) send_byte(d[i]);
    endtask

    task automatic send_pack();
        byte unsigned p[] = '{ 8'h00,8'h00,8'h01,8'hBA, 8'h44,8'h00,8'h04,8'h00,
                               8'h04,8'h01,8'h01,8'hBE, 8'hFF,8'hF8 };
        send_bytes(p, p.size());
    endtask

    // PTS bytes we will use for the subpicture PES (with marker bits).
    // b0=0x21 b1=0x00 b2=0x03 b3=0x00 b4=0x03
    localparam byte unsigned PB0 = 8'h21, PB1 = 8'h00, PB2 = 8'h03, PB3 = 8'h00, PB4 = 8'h03;
    // Expected assembled PTS per the RTL bit-extraction:
    //   [32]=b0[3] [31:30]=b0[2:1] [29:22]=b1 [21:15]=b2[7:1] [14:7]=b3 [6:0]=b4[7:1]
    wire [32:0] exp_pts = {PB0[3], PB0[2:1], PB1, PB2[7:1], PB3, PB4[7:1]};

    // subpicture PES with a PTS.  layout:
    //   00 00 01 BD | len_hi len_lo | 80 80 05 | PTS(5) | subid | payload(4)
    //   flags1=0x80 flags2=0x80(PTS present) hdr_len=0x05
    //   PES_packet_length = flags1+flags2+hdrlenbyte(3) + PTS(5) + subid(1) + payload(4) = 13
    task automatic send_subpic(input [7:0] subid, input [7:0] pay);
        byte unsigned p[] = '{ 8'h00,8'h00,8'h01,8'hBD, 8'h00,8'h0D,
                               8'h80,8'h80,8'h05, PB0,PB1,PB2,PB3,PB4,
                               subid, pay, pay+8'h01, pay+8'h02, pay+8'h03 };
        send_bytes(p, p.size());
    endtask

    // AC-3 audio PES (no PTS), substream 0x80, 4-byte payload
    //   00 00 01 BD | len_hi len_lo | 80 00 00 | 80 | 01 00 00 | pay x4
    //   PES len = flags(3) + subid(1) + subhdr(3) + payload(4) = 11
    task automatic send_ac3(input [7:0] pay);
        byte unsigned p[] = '{ 8'h00,8'h00,8'h01,8'hBD, 8'h00,8'h0B,
                               8'h80,8'h00,8'h00, 8'h80, 8'h01,8'h00,8'h00,
                               pay,pay,pay,pay };
        send_bytes(p, p.size());
    endtask

    int errors = 0;
    initial begin
        in_byte=0; in_valid=0; aud_track=0; sp_track=0; sp_enable=0;
        repeat (5) @(posedge clk); rst_n = 1; @(posedge clk);
        $display("=== ps_demux subpicture routing test ===");

        // ---- Case 1: sp_enable=1, sp_track=0 -> only 0x20 forwarded ----
        sp_enable = 1; sp_track = 0;
        sp_log.delete(); aud_log.delete(); sp_frame_starts = 0;
        send_pack();
        send_subpic(8'h20, 8'hD0);   // selected subpicture
        send_subpic(8'h21, 8'hE0);   // other subpicture -> dropped
        send_ac3(8'hA0);             // audio -> audio port
        repeat (60) @(posedge clk);

        if (sp_log.size() != 4) begin
            $display("  FAIL: sp got %0d bytes, expected 4", sp_log.size()); errors++;
        end else begin
            byte unsigned wp[] = '{8'hD0,8'hD1,8'hD2,8'hD3};
            for (int i=0;i<4;i++) if (sp_log[i] !== wp[i]) begin
                $display("  FAIL: sp byte%0d=%02h expected %02h", i, sp_log[i], wp[i]); errors++;
            end
        end
        if (sp_frame_starts != 1) begin
            $display("  FAIL: sp_frame_start pulsed %0d times, expected 1", sp_frame_starts); errors++;
        end
        if (captured_sp_pts !== exp_pts) begin
            $display("  FAIL: sp_pts=%h expected %h", captured_sp_pts, exp_pts); errors++;
        end
        if (aud_log.size() != 4) begin
            $display("  FAIL: audio got %0d bytes, expected 4 (audio unaffected)", aud_log.size()); errors++;
        end else if (aud_log[0] !== 8'hA0) begin
            $display("  FAIL: audio payload %02h expected A0", aud_log[0]); errors++;
        end
        if (errors == 0)
            $display("  case1 OK: sp=4 bytes (D0..D3), 1 frame_start, sp_pts=%h, audio 4 bytes", captured_sp_pts);

        // ---- Case 2: sp_enable=0 -> subpicture dropped entirely ----
        sp_enable = 0;
        sp_log.delete(); sp_frame_starts = 0;
        send_pack();
        send_subpic(8'h20, 8'hD0);
        repeat (40) @(posedge clk);
        if (sp_log.size() != 0) begin
            $display("  FAIL: sp_enable=0 but sp got %0d bytes", sp_log.size()); errors++;
        end else $display("  case2 OK: sp_enable=0 drops subpicture (0 bytes)");

        // ---- Case 3: sp_track=1 -> only 0x21 forwarded ----
        sp_enable = 1; sp_track = 1;
        sp_log.delete(); sp_frame_starts = 0;
        send_pack();
        send_subpic(8'h20, 8'hD0);   // dropped
        send_subpic(8'h21, 8'hE0);   // selected
        repeat (60) @(posedge clk);
        if (sp_log.size() != 4 || sp_log[0] !== 8'hE0) begin
            $display("  FAIL: sp_track=1 got %0d bytes first=%02h (expected 4, E0)",
                     sp_log.size(), sp_log.size()?sp_log[0]:8'hxx); errors++;
        end else $display("  case3 OK: sp_track=1 forwards 0x21 (E0..E3)");

        if (errors == 0) $display("RESULT: PASS (subpicture routing correct)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin #3_000_000; $display("RESULT: FAIL timeout"); $finish; end
endmodule
