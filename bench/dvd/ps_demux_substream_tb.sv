// =============================================================================
// bench/dvd/ps_demux_substream_tb.sv — AUDIO SUBSTREAM / TRACK SELECT
// =============================================================================
// A DVD can carry several audio substreams of the same type interleaved in one
// program (e.g. Matrix: AC-3 0x80 5.1 + 0x81 stereo + 0x82 stereo). ps_demux must
// forward ONLY the substream whose track == aud_track; the rest must be dropped,
// or they interleave into the one in-fabric AC-3 decoder and the audio is garbage.
//
// This TB feeds three back-to-back AC-3 PES packets on substreams 0x80/0x81/0x82
// with distinguishable payloads (0xA0.. / 0xB1.. / 0xC2..) and checks that, for
// each aud_track in {0,1,2}, exactly the matching substream's payload is emitted
// and the other two are dropped.
// =============================================================================
`timescale 1ns/1ps
module ps_demux_substream_tb;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [7:0] in_byte;
    logic       in_valid;
    wire        in_ready;
    logic [2:0] aud_track;

    wire [7:0]  vid_byte;  wire vid_valid;  logic vid_ready = 1;
    wire [7:0]  aud_byte;  wire aud_valid;  wire [1:0] aud_type;
    wire        aud_frame_start; logic aud_ready = 1;
    wire [32:0] vid_pts; wire vid_pts_valid; wire [32:0] aud_pts; wire aud_pts_valid;

    ps_demux dut (
        .clk(clk), .rst_n(rst_n),
        .in_byte(in_byte), .in_valid(in_valid), .in_ready(in_ready),
        .aud_track(aud_track),
        .vid_byte(vid_byte), .vid_valid(vid_valid), .vid_ready(vid_ready),
        .aud_byte(aud_byte), .aud_valid(aud_valid), .aud_type(aud_type),
        .aud_frame_start(aud_frame_start), .aud_ready(aud_ready),
        .vid_pts(vid_pts), .vid_pts_valid(vid_pts_valid),
        .aud_pts(aud_pts), .aud_pts_valid(aud_pts_valid)
    );

    // collect forwarded audio bytes
    byte unsigned aud_log[$];
    always @(posedge clk) if (rst_n && aud_valid && aud_ready) aud_log.push_back(aud_byte);

    task send_byte(input [7:0] b);
        @(posedge clk); in_byte = b; in_valid = 1;
        @(posedge clk); while (!in_ready) @(posedge clk); in_valid = 0;
    endtask
    task send_bytes(input byte unsigned d[], input int n);
        for (int i=0;i<n;i++) send_byte(d[i]);
    endtask

    // one AC-3 PES on a given substream with a 4-byte payload (all = pay)
    // layout: 00 00 01 BD | len_hi len_lo | 80 00 00 | subid | 01 00 00 | pay x4
    // PES_packet_length covers: flags(3) + subid(1) + subhdr(3) + payload(4) = 11
    task automatic send_ac3(input [7:0] subid, input [7:0] pay);
        byte unsigned p[] = '{ 8'h00,8'h00,8'h01,8'hBD, 8'h00,8'h0B,
                               8'h80,8'h00,8'h00, subid, 8'h01,8'h00,8'h00,
                               pay,pay,pay,pay };
        send_bytes(p, p.size());
    endtask

    task automatic send_pack();   // a pack header to start the stream
        byte unsigned p[] = '{ 8'h00,8'h00,8'h01,8'hBA, 8'h44,8'h00,8'h04,8'h00,
                               8'h04,8'h01,8'h01,8'hBE, 8'hFF,8'hF8 };
        send_bytes(p, p.size());
    endtask

    int errors = 0;
    task automatic run_case(input [2:0] trk, input [7:0] want_pay);
        aud_log.delete();
        aud_track = trk;
        send_pack();
        send_ac3(8'h80, 8'hA0);   // track 0
        send_ac3(8'h81, 8'hB1);   // track 1
        send_ac3(8'h82, 8'hC2);   // track 2
        repeat (40) @(posedge clk);   // drain
        // expect exactly 4 bytes, all == want_pay
        if (aud_log.size() != 4) begin
            $display("  FAIL track=%0d: got %0d audio bytes, expected 4", trk, aud_log.size());
            errors++;
        end else begin
            for (int i=0;i<4;i++) if (aud_log[i] !== want_pay) begin
                $display("  FAIL track=%0d: byte%0d=%02h expected %02h", trk, i, aud_log[i], want_pay);
                errors++;
            end
            if (errors == 0 || aud_log[0] === want_pay)
                $display("  track=%0d -> %0d bytes, payload %02h (other substreams dropped) OK",
                         trk, aud_log.size(), want_pay);
        end
    endtask

    initial begin
        in_byte=0; in_valid=0; aud_track=0;
        repeat (5) @(posedge clk); rst_n = 1; @(posedge clk);
        $display("=== ps_demux audio substream-select test ===");
        run_case(3'd0, 8'hA0);   // select 0x80
        run_case(3'd1, 8'hB1);   // select 0x81
        run_case(3'd2, 8'hC2);   // select 0x82
        if (errors == 0) $display("RESULT: PASS (track select forwards only the chosen substream)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin #2_000_000; $display("RESULT: FAIL timeout"); $finish; end
endmodule
