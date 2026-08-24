// ps_demux_es_tb.sv — regression test for raw elementary-stream passthrough.
// Feeds a bare MPEG-2 elementary stream (starts with 00 00 01 B3 sequence
// header, no pack/PES wrapper) and checks ps_demux forwards EVERY byte to the
// video output, including the reconstructed 00 00 01 B3 preamble.
`timescale 1ns/1ps
`default_nettype none

module ps_demux_es_tb;
    logic        clk = 0, rst_n = 0;
    logic  [7:0] in_byte;
    logic        in_valid;
    logic        in_ready;
    logic  [7:0] vid_byte;
    logic        vid_valid;
    logic        vid_ready = 1'b1;

    always #5 clk = ~clk;

    ps_demux dut (
        .clk(clk), .rst_n(rst_n),
        .in_byte(in_byte), .in_valid(in_valid), .in_ready(in_ready),
        .aud_track(3'd0),
        .vid_byte(vid_byte), .vid_valid(vid_valid), .vid_ready(vid_ready),
        .aud_byte(), .aud_valid(), .aud_type(), .aud_frame_start(), .aud_ready(1'b1),
        .vid_pts(), .vid_pts_valid(), .aud_pts(), .aud_pts_valid()
    );

    // A short raw elementary stream: sequence header + a little payload + a
    // second start code, then arbitrary bytes.
    localparam int N = 14;
    logic [7:0] stim [0:N-1] = '{
        8'h00,8'h00,8'h01,8'hB3, 8'h2D,8'h01,8'hE0, 8'h34,
        8'h00,8'h00,8'h01,8'hB5, 8'hAA,8'hBB
    };

    logic [7:0] got [0:63];
    int gi = 0;

    // Collect forwarded video bytes
    always_ff @(posedge clk)
        if (rst_n && vid_valid && vid_ready) begin
            got[gi] <= vid_byte;
            gi <= gi + 1;
        end

    int i;
    initial begin
        in_valid = 0; in_byte = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        // Drive the stream with a held valid/ready handshake.
        for (i = 0; i < N; i++) begin
            in_byte  <= stim[i];
            in_valid <= 1'b1;
            @(posedge clk);
            while (!in_ready) @(posedge clk);  // wait until consumed
        end
        in_valid <= 0;
        repeat (20) @(posedge clk);

        // Expect EVERY input byte forwarded, in order, unchanged.
        $display("=== ps_demux ES passthrough test ===");
        $display("forwarded %0d bytes (expected %0d)", gi, N);
        if (gi != N) begin
            $display("FAIL: byte count mismatch");
            $finish;
        end
        for (i = 0; i < N; i++) begin
            if (got[i] !== stim[i]) begin
                $display("FAIL: byte %0d = %02h, expected %02h", i, got[i], stim[i]);
                $finish;
            end
        end
        $display("PASS: raw elementary stream forwarded byte-for-byte");
        $finish;
    end
endmodule
`default_nettype wire
