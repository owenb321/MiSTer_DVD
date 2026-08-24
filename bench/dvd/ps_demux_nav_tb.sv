// ps_demux_nav_tb.sv — regression test for DVD nav-pack (private_stream_2)
// skip-by-length. A real VOB interleaves NV_PCK (stream_id 0xBF) packets whose
// PCI/DSI payload can contain a 00 00 01 byte pattern. The demuxer must consume
// the whole nav packet by its declared PES length so that embedded pattern can
// NOT false-trigger a start code and desync the stream. Here the nav payload
// deliberately embeds a fake "00 00 01 E0" (video start code); only the real
// video PES payload that follows may reach the video output.
`timescale 1ns/1ps
`default_nettype none

module ps_demux_nav_tb;
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

    // Program stream:
    //   pack header  : 00 00 01 BA + 9 fixed + stuffing-len 00
    //   nav pack     : 00 00 01 BF + len 00 08 + [00 00 01 E0 00 09 AA BB]  <-- TRAP
    //   video PES    : 00 00 01 E0 + len 00 07 + flags 00 00 + hdrlen 00 + DE AD BE EF
    localparam int N = 14 + 14 + 13;  // pack(14) + nav pack(14) + video PES(13)
    logic [7:0] stim [0:N-1] = '{
        // pack header
        8'h00,8'h00,8'h01,8'hBA,
        8'h44,8'h44,8'h44,8'h44,8'h44,8'h44,8'h44,8'h44,8'h44,  // 9 fixed
        8'h00,                                                  // stuffing length 0
        // nav pack (private_stream_2), length 8, payload embeds fake 00 00 01 E0
        8'h00,8'h00,8'h01,8'hBF, 8'h00,8'h08,
        8'h00,8'h00,8'h01,8'hE0, 8'h00,8'h09,8'hAA,8'hBB,
        // real video PES, length 7
        8'h00,8'h00,8'h01,8'hE0, 8'h00,8'h07,
        8'h00,8'h00,8'h00,                                      // flags1, flags2(no PTS), hdrlen 0
        8'hDE,8'hAD,8'hBE,8'hEF                                 // video payload
    };

    // Only these four bytes must reach the video output.
    localparam int EXP = 4;
    logic [7:0] exp [0:EXP-1] = '{ 8'hDE, 8'hAD, 8'hBE, 8'hEF };

    logic [7:0] got [0:63];
    int gi = 0;

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
        for (i = 0; i < N; i++) begin
            in_byte  <= stim[i];
            in_valid <= 1'b1;
            @(posedge clk);
            while (!in_ready) @(posedge clk);
        end
        in_valid <= 0;
        repeat (20) @(posedge clk);

        $display("=== ps_demux nav-pack skip test ===");
        $display("forwarded %0d video bytes (expected %0d)", gi, EXP);
        if (gi != EXP) begin
            $display("FAIL: nav-pack payload leaked into video (or video PES dropped)");
            for (i = 0; i < gi; i++) $display("  got[%0d] = %02h", i, got[i]);
            $finish;
        end
        for (i = 0; i < EXP; i++) begin
            if (got[i] !== exp[i]) begin
                $display("FAIL: video byte %0d = %02h, expected %02h", i, got[i], exp[i]);
                $finish;
            end
        end
        $display("PASS: nav pack skipped by length; real video PES intact");
        $finish;
    end
endmodule
`default_nettype wire
