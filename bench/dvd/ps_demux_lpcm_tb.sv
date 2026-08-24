// ps_demux_lpcm_tb.sv — LPCM sub-header format capture + payload framing
//
//   iverilog -g2012 -o bench/dvd/ps_demux_lpcm_sim dvd/ps_demux.sv bench/dvd/ps_demux_lpcm_tb.sv
//   vvp bench/dvd/ps_demux_lpcm_sim
//
// Feeds a minimal LPCM PES (private_stream_1, substream 0xA1) whose 6-byte
// sub-header declares 20-bit / 48 kHz / stereo in byte +5, and checks:
//   - aud_type == 2 (LPCM),
//   - aud_lpcm_quant == 1 (20-bit) is captured from sub-header byte +5,
//   - the 7-byte header (substream_id + 6) is fully stripped: the first
//     forwarded audio byte is the first real sample byte (0x11), and exactly
//     the 4 payload bytes reach the audio output.
`timescale 1ns/1ps
`default_nettype none

module ps_demux_lpcm_tb;

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
wire   [1:0] aud_lpcm_quant;
wire         aud_frame_start;
logic        aud_ready;

ps_demux dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .in_byte        (in_byte),
    .in_valid       (in_valid),
    .in_ready       (in_ready),
    .aud_track      (3'd1),          // select LPCM track 1 (substream 0xA1)
    .sp_track       (3'd0),
    .sp_enable      (1'b0),
    .vid_byte       (vid_byte),
    .vid_valid      (vid_valid),
    .vid_ready      (vid_ready),
    .aud_byte       (aud_byte),
    .aud_valid      (aud_valid),
    .aud_type       (aud_type),
    .aud_frame_start(aud_frame_start),
    .aud_ready      (aud_ready),
    .vid_pts        (),
    .vid_pts_valid  (),
    .aud_pts        (),
    .aud_pts_valid  (),
    .aud_frame_pts       (),
    .aud_frame_pts_valid (),
    .sp_byte        (),
    .sp_valid       (),
    .sp_frame_start (),
    .sp_pts         (),
    .sp_pts_valid   (),
    .pci_enable     (1'b0),
    .pci_byte       (),
    .pci_valid      (),
    .pci_frame_start(),
    .dsi_enable     (1'b0),
    .dsi_byte       (),
    .dsi_valid      (),
    .dsi_frame_start(),
    .aud_lpcm_quant (aud_lpcm_quant)
);

always #9.26 clk = ~clk;

int  aud_bytes_count = 0;
int  errs = 0;
logic [7:0] first_aud_byte_val;
logic       saw_frame_start = 0;

always_ff @(posedge clk) begin
    if (aud_valid && aud_ready) begin
        if (aud_frame_start) begin
            saw_frame_start   <= 1'b1;
            first_aud_byte_val <= aud_byte;
            if (aud_type !== 2'd2) begin
                $display("FAIL: aud_type=%0d, expected 2 (LPCM)", aud_type); errs++;
            end
            if (aud_lpcm_quant !== 2'd1) begin
                $display("FAIL: aud_lpcm_quant=%0d, expected 1 (20-bit)", aud_lpcm_quant); errs++;
            end
        end
        aud_bytes_count++;
    end
end

task send_byte(input [7:0] b);
    @(posedge clk);
    in_byte  = b;
    in_valid = 1;
    @(posedge clk);
    while (!in_ready) @(posedge clk);
    in_valid = 0;
endtask

// LPCM PES: pack header + private_stream_1 substream 0xA1, 20-bit sub-header.
// PES length = 3 (flags) + 1 (substream) + 6 (sub-header) + 4 (data) = 0x0E.
localparam int LPCM_PKT_LEN = 34;
logic [7:0] lpcm_pkt [] = '{
    // Pack header (14 bytes)
    8'h00, 8'h00, 8'h01, 8'hBA,
    8'h44, 8'h00, 8'h04, 8'h00,
    8'h04, 8'h01, 8'h01, 8'hBE,
    8'hFF, 8'hF8,
    // PES header (private stream 1)
    8'h00, 8'h00, 8'h01, 8'hBD,
    8'h00, 8'h0E,                 // PES packet length = 14
    8'h80, 8'h00, 8'h00,          // flags: no PTS, header data len = 0
    // PES data
    8'hA1,                        // substream_id = 0xA1 (LPCM track 1)
    8'h01,                        // +1 number of frame headers
    8'h00, 8'h04,                 // +2/+3 first access unit pointer
    8'h00,                        // +4 emphasis/mute/frame number
    8'h41,                        // +5 quant=01(20b) freq=00(48k) chan=001(2ch)
    8'h80,                        // +6 dynamic range control
    // 4 real payload bytes (first LPCM samples)
    8'h11, 8'h22, 8'h33, 8'h44
};

initial begin
    clk = 0; rst_n = 0; in_valid = 0; in_byte = 0;
    vid_ready = 1; aud_ready = 1;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    for (int i = 0; i < LPCM_PKT_LEN; i++) send_byte(lpcm_pkt[i]);

    repeat (20) @(posedge clk);

    if (!saw_frame_start)       begin $display("FAIL: no audio frame detected"); errs++; end
    if (first_aud_byte_val !== 8'h11) begin
        $display("FAIL: first audio byte=%02x, expected 11 (header not fully stripped)",
                 first_aud_byte_val); errs++;
    end
    if (aud_bytes_count !== 4)  begin
        $display("FAIL: forwarded %0d audio bytes, expected 4", aud_bytes_count); errs++;
    end

    if (errs == 0) $display("PASS: ps_demux LPCM quant capture + framing");
    else           $display("FAIL: %0d error(s)", errs);
    $finish;
end

initial begin #200000 $display("FAIL: timeout"); $finish; end
endmodule
