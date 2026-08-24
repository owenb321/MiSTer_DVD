// spu_col_tb.sv — feed a real SPU hex through spu_decode and report the captured
// SET_COLOR indices (col0..3). Reproduces the MiB "white subtitle" bug in sim.
//
//   iverilog -g2012 -o /tmp/spu_col_sim dvd/spu_decode.sv bench/dvd/spu_col_tb.sv
//   vvp /tmp/spu_col_sim +hex=/tmp/mib_spu.hex +exp=12,15,13,14
`timescale 1ns/1ps
`default_nettype none

module spu_col_tb;
    localparam int BMP_N = 720*576, STRIDE = 720, SPU_CAP = 8192;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0, enable=1;
    logic [7:0] sp_byte; logic sp_valid, sp_frame_start; logic [32:0] sp_pts; logic sp_pts_valid;
    logic [32:0] stc=0;
    logic [11:0] q_x=0, q_y=0;
    wire [1:0] q_idx; wire q_inside, sp_active;
    wire [3:0] alpha0,alpha1,alpha2,alpha3, col0,col1,col2,col3;

    spu_decode #(.BMP_N(BMP_N), .STRIDE(STRIDE), .SPU_CAP(SPU_CAP)) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable), .interlaced(1'b0),
        .sp_byte(sp_byte), .sp_valid(sp_valid), .sp_frame_start(sp_frame_start),
        .sp_pts(sp_pts), .sp_pts_valid(sp_pts_valid),
        .stc(stc), .q_x(q_x), .q_y(q_y), .q_idx(q_idx), .q_inside(q_inside),
        .alpha0(alpha0), .alpha1(alpha1), .alpha2(alpha2), .alpha3(alpha3),
        .col0(col0), .col1(col1), .col2(col2), .col3(col3),
        .sp_active(sp_active)
    );

    reg [7:0] spubytes [0:8191];
    integer n, i;
    string hexpath, expstr;
    logic [32:0] PTS = 33'd90000;

    task automatic feed_spu(input int cnt);
        for (i=0;i<cnt;i++) begin
            @(negedge clk);
            sp_byte = spubytes[i]; sp_valid = 1; sp_frame_start = (i==0);
            sp_pts = PTS; sp_pts_valid = (i==0);
        end
        @(negedge clk); sp_valid=0; sp_frame_start=0; sp_pts_valid=0;
    endtask

    initial begin
        sp_valid=0; sp_frame_start=0; sp_pts_valid=0; sp_byte=0; sp_pts=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        if (!$value$plusargs("hex=%s", hexpath)) begin
            $display("RESULT: FAIL no +hex="); $finish;
        end
        for (i=0;i<8192;i++) spubytes[i]=8'h00;
        $readmemh(hexpath, spubytes);
        // count non-trailing (SPDSZ from header)
        n = (spubytes[0]<<8) | spubytes[1];
        $display("=== spu_col: %0s  SPDSZ=%0d ===", hexpath, n);

        feed_spu(n);
        // let the DCSQ walk + RLE decode + COMMIT finish
        repeat(200000) @(posedge clk);

        $display("captured col = [%0d, %0d, %0d, %0d]  (c0,c1,c2,c3)", col0, col1, col2, col3);
        $display("captured alpha = [%0d, %0d, %0d, %0d]", alpha0, alpha1, alpha2, alpha3);
        if ($value$plusargs("exp=%s", expstr))
            $display("expected col = %0s", expstr);
        $display("RESULT: DONE");
        $finish;
    end

    initial begin #20000000; $display("RESULT: FAIL timeout"); $finish; end
endmodule

`default_nettype wire
