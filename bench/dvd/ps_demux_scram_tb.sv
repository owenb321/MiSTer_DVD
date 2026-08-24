// ps_demux_scram_tb.sv — CSS-scrambled PES detection (pes_scrambled pulse).
//
// A CSS-encrypted rip carries PES_scrambling_control != 0 (bits [5:4] of the
// first PES-flags byte — the byte itself is never scrambled). ps_demux must
// pulse pes_scrambled once per such PES (video 0xE0 AND private_stream_1 0xBD),
// and must NOT pulse for clean packets. Payload routing is unchanged either
// way (the payload passes through scrambled — emu mutes/warns downstream).
//
// Stream: pack + clean video PES (no pulse) + scrambled video PES (pulse) +
//         scrambled AC-3 audio PES (pulse) + clean audio PES (no pulse).
`timescale 1ns/1ps
`default_nettype none

module ps_demux_scram_tb;
    logic        clk = 0, rst_n = 0;
    logic  [7:0] in_byte;
    logic        in_valid;
    logic        in_ready;
    logic        scram;

    always #5 clk = ~clk;

    ps_demux dut (
        .clk(clk), .rst_n(rst_n),
        .in_byte(in_byte), .in_valid(in_valid), .in_ready(in_ready),
        .aud_track(3'd0),
        .vid_byte(), .vid_valid(), .vid_ready(1'b1),
        .aud_byte(), .aud_valid(), .aud_type(), .aud_frame_start(), .aud_ready(1'b1),
        .vid_pts(), .vid_pts_valid(), .aud_pts(), .aud_pts_valid(),
        .pes_scrambled(scram)
    );

    // pack header, then four PES packets:
    //  video clean     : flags1 0x80 (marker '10', sc=00)
    //  video scrambled : flags1 0xB0 (marker '10', sc=11)
    //  audio scrambled : flags1 0x90 (marker '10', sc=01), AC-3 sub-header
    //  audio clean     : flags1 0x80
    localparam int N = 14 + 13 + 13 + 15 + 15;
    logic [7:0] stim [0:N-1] = '{
        // pack header
        8'h00,8'h00,8'h01,8'hBA,
        8'h44,8'h44,8'h44,8'h44,8'h44,8'h44,8'h44,8'h44,8'h44,
        8'h00,
        // clean video PES, len 7: flags1 80, flags2 00, hdrlen 00, 4 payload
        8'h00,8'h00,8'h01,8'hE0, 8'h00,8'h07,
        8'h80,8'h00,8'h00, 8'hDE,8'hAD,8'hBE,8'hEF,
        // SCRAMBLED video PES (sc=11), len 7
        8'h00,8'h00,8'h01,8'hE0, 8'h00,8'h07,
        8'hB0,8'h00,8'h00, 8'h12,8'h34,8'h56,8'h78,
        // SCRAMBLED audio PES (sc=01), len 9: flags+hdrlen+substream 0x80+3 sub + 2 payload
        8'h00,8'h00,8'h01,8'hBD, 8'h00,8'h09,
        8'h90,8'h00,8'h00, 8'h80,8'h01,8'h00,8'h01, 8'h0B,8'h77,
        // clean audio PES, len 9
        8'h00,8'h00,8'h01,8'hBD, 8'h00,8'h09,
        8'h80,8'h00,8'h00, 8'h80,8'h01,8'h00,8'h01, 8'h0B,8'h77
    };

    int pulses = 0;
    always_ff @(posedge clk) if (rst_n && scram) pulses <= pulses + 1;

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

        $display("=== ps_demux CSS-scramble detection test ===");
        $display("pes_scrambled pulses = %0d (expected 2)", pulses);
        if (pulses !== 2) begin
            $display("FAIL: expected exactly 2 pulses (1 video + 1 audio scrambled PES)");
            $fatal(1);
        end
        $display("PASS: scrambled PES detected, clean PES silent");
        $finish;
    end
endmodule
`default_nettype wire
