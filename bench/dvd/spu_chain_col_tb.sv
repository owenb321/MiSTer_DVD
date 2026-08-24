// spu_chain_col_tb.sv — FULL CHAIN ps_demux -> spu_decode on a real VOB slice,
// reporting the captured SET_COLOR (col0..3). Reproduces exactly what the hardware
// sees (bursty PES delivery, sp_frame_start framing) for the MiB white-subtitle bug.
//
//   iverilog -g2012 -o /tmp/scc dvd/ps_demux.sv dvd/spu_decode.sv bench/dvd/spu_chain_col_tb.sv
//   vvp /tmp/scc +slice=bench/dvd/test_vobs/mib_subpic_slice.bin +exp=12,15,13,14
`timescale 1ns/1ps
`default_nettype none

module spu_chain_col_tb;
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic [7:0] in_byte; logic in_valid; wire in_ready;
    wire [7:0] vid_byte; wire vid_valid; logic vid_ready=1;
    wire [7:0] aud_byte; wire aud_valid; wire [1:0] aud_type; wire aud_frame_start; logic aud_ready=1;
    wire [32:0] vid_pts; wire vid_pts_valid; wire [32:0] aud_pts; wire aud_pts_valid;
    wire [32:0] aud_frame_pts; wire aud_frame_pts_valid;
    wire [7:0] sp_byte; wire sp_valid, sp_frame_start; wire [32:0] sp_pts; wire sp_pts_valid;

    // sp_track selectable via +track (default 0 -> substream 0x20)
    reg [2:0] sp_track = 3'd0;

    ps_demux dmx (
        .clk(clk), .rst_n(rst_n),
        .in_byte(in_byte), .in_valid(in_valid), .in_ready(in_ready),
        .aud_track(3'd0), .sp_track(sp_track), .sp_enable(1'b1),
        .vid_byte(vid_byte), .vid_valid(vid_valid), .vid_ready(vid_ready),
        .aud_byte(aud_byte), .aud_valid(aud_valid), .aud_type(aud_type),
        .aud_frame_start(aud_frame_start), .aud_ready(aud_ready),
        .vid_pts(vid_pts), .vid_pts_valid(vid_pts_valid),
        .aud_pts(aud_pts), .aud_pts_valid(aud_pts_valid),
        .aud_frame_pts(aud_frame_pts), .aud_frame_pts_valid(aud_frame_pts_valid),
        .sp_byte(sp_byte), .sp_valid(sp_valid), .sp_frame_start(sp_frame_start),
        .sp_pts(sp_pts), .sp_pts_valid(sp_pts_valid)
    );

    logic [11:0] q_x=0, q_y=0; wire [1:0] q_idx; wire q_inside, sp_active;
    wire [3:0] a0,a1,a2,a3, col0,col1,col2,col3;
    logic [32:0] stc=0;
    spu_decode spu (
        .clk(clk), .rst_n(rst_n), .enable(1'b1), .interlaced(1'b0),
        .sp_byte(sp_byte), .sp_valid(sp_valid), .sp_frame_start(sp_frame_start),
        .sp_pts(sp_pts), .sp_pts_valid(sp_pts_valid),
        .stc(stc), .q_x(q_x), .q_y(q_y), .q_idx(q_idx), .q_inside(q_inside),
        .alpha0(a0), .alpha1(a1), .alpha2(a2), .alpha3(a3),
        .col0(col0), .col1(col1), .col2(col2), .col3(col3), .sp_active(sp_active)
    );

    reg [7:0] slice [0:2_100_000];
    integer fd, n, i;
    string slicepath, expstr;
    integer tr;

    initial begin
        in_byte=0; in_valid=0;
        if ($value$plusargs("track=%d", tr)) sp_track = tr[2:0];
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        if (!$value$plusargs("slice=%s", slicepath)) begin $display("RESULT: FAIL no +slice="); $finish; end
        fd=$fopen(slicepath,"rb");
        if (fd==0) begin $display("RESULT: FAIL cannot open slice"); $finish; end
        n=$fread(slice, fd); $fclose(fd);
        $display("=== chain col: %0s (%0d bytes, sp_track=%0d) ===", slicepath, n, sp_track);

        // feed bytes 1/clk (respecting in_ready) until the SPU decodes or slice ends
        i=0;
        while (i<n && !spu.c_valid) begin
            @(negedge clk); in_byte=slice[i]; in_valid=1;
            @(posedge clk); if (in_ready) i=i+1;
        end
        @(negedge clk); in_valid=0;

        if (!spu.c_valid) begin
            $display("  SPU never decoded from the chain (fed %0d bytes)", i);
            $display("RESULT: FAIL");
        end else begin
            $display("  SPU decoded after %0d fed bytes", i);
            $display("captured col = [%0d, %0d, %0d, %0d]  (c0,c1,c2,c3)", col0, col1, col2, col3);
            $display("captured alpha = [%0d, %0d, %0d, %0d]", a0, a1, a2, a3);
            if ($value$plusargs("exp=%s", expstr)) $display("expected col = %0s", expstr);
            $display("RESULT: DONE");
        end
        $finish;
    end

    initial begin #200000000; $display("RESULT: FAIL timeout"); $finish; end
endmodule

`default_nettype wire
