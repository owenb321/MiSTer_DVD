// ps_demux_tb.sv — Testbench for Program Stream Demuxer
// 
// Usage:
//   iverilog -g2012 -o bench/dvd/ps_demux_sim dvd/ps_demux.sv bench/dvd/ps_demux_tb.sv
//   vvp bench/dvd/ps_demux_sim
//
// To generate test data from a real VOB:
//   dd if=VIDEO_TS/VTS_01_1.VOB bs=2048 count=20 | xxd -p > bench/dvd/test_vobs/sample.hex

`timescale 1ns/1ps
`default_nettype none

module ps_demux_tb;

// DUT signals
logic        clk, rst_n;
logic  [7:0] in_byte;
logic        in_valid;
wire         in_ready;
wire   [7:0] vid_byte;
wire         vid_valid;
logic        vid_ready;
wire   [7:0] aud_byte;
wire         aud_valid;
wire   [1:0] aud_type;
wire         aud_frame_start;
logic        aud_ready;
wire  [32:0] vid_pts;
wire         vid_pts_valid;
wire  [32:0] aud_pts;
wire         aud_pts_valid;

// Instantiate DUT
ps_demux dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .in_byte        (in_byte),
    .in_valid       (in_valid),
    .in_ready       (in_ready),
    .aud_track      (3'd0),
    .vid_byte       (vid_byte),
    .vid_valid      (vid_valid),
    .vid_ready      (vid_ready),
    .aud_byte       (aud_byte),
    .aud_valid      (aud_valid),
    .aud_type       (aud_type),
    .aud_frame_start(aud_frame_start),
    .aud_ready      (aud_ready),
    .vid_pts        (vid_pts),
    .vid_pts_valid  (vid_pts_valid),
    .aud_pts        (aud_pts),
    .aud_pts_valid  (aud_pts_valid)
);

// Clock: 54MHz (matches MiSTer MPEG-2 core clock domain)
always #9.26 clk = ~clk;

// Counters for checking output
int vid_bytes_count = 0;
int aud_bytes_count = 0;
int aud_frames_count = 0;

// Monitor video output
always_ff @(posedge clk) begin
    if (vid_valid && vid_ready) begin
        vid_bytes_count++;
    end
    if (aud_valid && aud_ready) begin
        aud_bytes_count++;
        if (aud_frame_start) begin
            aud_frames_count++;
            $display("[%0t] Audio frame %0d detected, type=%0d (0=AC3,1=DTS,2=LPCM)",
                     $time, aud_frames_count, aud_type);
        end
    end
    if (vid_pts_valid)
        $display("[%0t] Video PTS = %0d (90kHz ticks = %0.3f sec)",
                 $time, vid_pts, real'(vid_pts) / 90000.0);
    if (aud_pts_valid)
        $display("[%0t] Audio PTS = %0d (90kHz ticks = %0.3f sec)",
                 $time, aud_pts, real'(aud_pts) / 90000.0);
end

// Task: send a byte
task send_byte(input [7:0] b);
    @(posedge clk);
    in_byte  = b;
    in_valid = 1;
    @(posedge clk);
    while (!in_ready) @(posedge clk);
    in_valid = 0;
endtask

// Task: send an array of bytes
task send_bytes(input [7:0] data[], input int len);
    for (int i = 0; i < len; i++) send_byte(data[i]);
endtask

// ============================================================================
// Test vectors
// These are minimal synthetic Program Stream packets.
// Replace / supplement with real VOB data once DUT is partially working.
// ============================================================================

// Minimal AC-3 PES packet (private stream 1, substream 0x80)
// Pack header + one audio PES packet
localparam int AC3_PKT_LEN = 28;
logic [7:0] ac3_test_pkt [] = '{
    // Pack header (simplified — 14 bytes)
    8'h00, 8'h00, 8'h01, 8'hBA,  // pack start code
    8'h44, 8'h00, 8'h04, 8'h00,  // SCR (fake)
    8'h04, 8'h01, 8'h01, 8'hBE,  // SCR ext + mux rate
    8'hFF, 8'hF8,                  // stuffing length=0, pack data

    // PES header (private stream 1 = audio)
    8'h00, 8'h00, 8'h01, 8'hBD,  // PES start code, stream_id=0xBD
    8'h00, 8'h08,                  // PES packet length = 8 bytes
    8'h80, 8'h00, 8'h00,          // flags: no PTS, header data len=0
    // PES data (5 bytes payload)
    8'h80,                         // substream_id = 0x80 (AC-3 stream 0)
    8'h01,                         // number of audio frames
    8'h00, 8'h00,                  // first access unit offset
    8'hAB                          // first byte of AC-3 frame (fake sync byte)
};

// Minimal video PES packet
localparam int VID_PKT_LEN = 19;
logic [7:0] vid_test_pkt [] = '{
    // PES header (video)
    8'h00, 8'h00, 8'h01, 8'hE0,  // PES start code, stream_id=0xE0
    8'h00, 8'h0D,                  // PES packet length = 13 (3 hdr + 5 PTS + 5 payload)
    8'h80, 8'h80, 8'h05,          // flags: PTS present, header data len=5
    // PTS (5 bytes, fake value = 0x123456789)
    8'h21, 8'h00, 8'h91, 8'hAB, 8'h03,
    // video data (5 bytes payload, inside the PES packet)
    8'h00, 8'h00, 8'h01,          // MPEG-2 video start code prefix
    8'hB3, 8'h00                  // sequence header start (fake)
};

// ============================================================================
// Main test
// ============================================================================
initial begin
    $display("=== ps_demux testbench starting ===");

    // Init
    clk      = 0;
    rst_n    = 0;
    in_byte  = 0;
    in_valid = 0;
    vid_ready = 1;
    aud_ready = 1;

    repeat(4) @(posedge clk);
    rst_n = 1;
    repeat(2) @(posedge clk);

    // Test 1: AC-3 audio packet
    $display("\n--- Test 1: AC-3 audio PES packet ---");
    send_bytes(ac3_test_pkt, AC3_PKT_LEN);
    repeat(10) @(posedge clk);

    // Test 2: Video PES packet with PTS
    $display("\n--- Test 2: Video PES with PTS ---");
    send_bytes(vid_test_pkt, VID_PKT_LEN);
    repeat(10) @(posedge clk);

    // Test 3: Back-to-back packets (stress test routing)
    $display("\n--- Test 3: Back-to-back AC-3 then video ---");
    send_bytes(ac3_test_pkt, AC3_PKT_LEN);
    send_bytes(vid_test_pkt, VID_PKT_LEN);
    repeat(10) @(posedge clk);

    // TODO: Add test with real VOB hex data when available
    // Read from bench/dvd/test_vobs/sample.hex and feed byte by byte

    $display("\n=== Results ===");
    $display("Video bytes forwarded: %0d", vid_bytes_count);
    $display("Audio bytes forwarded: %0d", aud_bytes_count);
    $display("Audio frames detected: %0d", aud_frames_count);

    // Basic pass/fail
    if (aud_frames_count > 0)
        $display("PASS: Audio frames detected");
    else
        $display("FAIL: No audio frames detected");

    $display("=== ps_demux testbench done ===");
    $finish;
end

// Timeout watchdog
initial begin
    #1_000_000;
    $display("TIMEOUT: simulation exceeded limit");
    $finish;
end

endmodule

`default_nettype wire
