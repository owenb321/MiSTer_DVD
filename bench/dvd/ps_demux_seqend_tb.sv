// ps_demux_seqend_tb.sv — a video PES ending in a sequence_end_code (00 00 01 B7),
// followed by a nav pack this demuxer drops, must emit trailing filler on the
// video output so the decoder's VLD can flush the still's last slice
// (docs/dvd_menu_refinements.md §6 — the ad/menu "black/gray bottom" fix).
`timescale 1ns/1ps
`default_nettype none

module ps_demux_seqend_tb;
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

    // pack header + a video PES whose payload ENDS in 00 00 01 B7 + a nav pack.
    localparam int N = 50;
    logic [7:0] stim [0:N-1] = '{
        // pack header (14 bytes: BA + 9 + stuffing len 0)
        8'h00,8'h00,8'h01,8'hBA, 8'h44,8'h00,8'h04,8'h00,8'h04,8'h01,8'h00,8'h1B,8'hA3,8'hF8,
        // video PES: 00 00 01 E0, len=0x14(20), flags 80 80, hdrlen 05, 5 PTS bytes,
        //            payload (12): 00 00 01 B3 00 11 22 33 00 00 01 B7
        8'h00,8'h00,8'h01,8'hE0, 8'h00,8'h14, 8'h80,8'h80,8'h05,
        8'h21,8'h00,8'h01,8'h00,8'h01,
        8'h00,8'h00,8'h01,8'hB3, 8'h00,8'h11,8'h22,8'h33, 8'h00,8'h00,8'h01,8'hB7,
        // nav pack (private_stream_2 0xBF, len 4) — DROPPED
        8'h00,8'h00,8'h01,8'hBF, 8'h00,8'h04, 8'hAA,8'hBB,8'hCC,8'hDD
    };
    // expected video payload (12) then 24 filler zeros
    localparam int PAY = 12, FILL = 24;
    logic [7:0] exp_pay [0:PAY-1] = '{
        8'h00,8'h00,8'h01,8'hB3, 8'h00,8'h11,8'h22,8'h33, 8'h00,8'h00,8'h01,8'hB7 };

    logic [7:0] got [0:255];
    int gi = 0;
    always_ff @(posedge clk)
        if (rst_n && vid_valid && vid_ready) begin got[gi] <= vid_byte; gi <= gi + 1; end

    int i, errs = 0;
    initial begin
        in_valid = 0; in_byte = 0;
        repeat (4) @(posedge clk);
        rst_n = 1; @(posedge clk);
        for (i = 0; i < N; i++) begin
            in_byte <= stim[i]; in_valid <= 1'b1;
            @(posedge clk);
            while (!in_ready) @(posedge clk);
        end
        in_valid <= 0;
        repeat (60) @(posedge clk);

        $display("=== ps_demux sequence_end flush test ===");
        $display("forwarded %0d video bytes (expect %0d payload + %0d filler)", gi, PAY, FILL);
        if (gi != PAY + FILL) begin
            $display("FAIL: byte count %0d != %0d", gi, PAY + FILL); errs++;
        end
        for (i = 0; i < PAY; i++)
            if (got[i] !== exp_pay[i]) begin
                $display("FAIL: payload byte %0d = %02h exp %02h", i, got[i], exp_pay[i]); errs++;
            end
        for (i = PAY; i < PAY + FILL && i < gi; i++)
            if (got[i] !== 8'h00) begin
                $display("FAIL: filler byte %0d = %02h exp 00", i, got[i]); errs++;
            end
        if (errs == 0) $display("PASS: SEQ_END flush emits %0d trailing zeros, nav dropped", FILL);
        else           $display("FAILED with %0d errors", errs);
        $finish;
    end
endmodule
`default_nettype wire
