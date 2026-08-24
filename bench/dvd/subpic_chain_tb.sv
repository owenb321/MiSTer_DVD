// =============================================================================
// bench/dvd/subpic_chain_tb.sv — FULL CHAIN: ps_demux -> spu_decode on a real VOB
// =============================================================================
// The two halves were unit-tested separately; this proves them together on a real
// multiplexed MATRIX.VOB slice (video + audio + the first 0x20 subpicture), the way
// the hardware sees it (bursty, interspersed delivery). Feeds the slice through
// ps_demux (sp_track=0, sp_enable=1), lets spu_decode assemble + decode the SPU, and
// checks it produces the SAME bitmap as the standalone golden fixture (matrix_spu0).
//
// Fixture: bench/dvd/test_vobs/matrix_subpic_slice.bin (2 MB from a pack boundary
// before the first 0x20 PES) + matrix_spu0.idx.hex/.params (golden decode).
// =============================================================================
`timescale 1ns/1ps
module subpic_chain_tb;
    localparam SX=161, EX=558, SY=384, EY=420, W=398;
    localparam SHOW = 33'd14442072;

    logic clk=0, rst_n=0;
    always #5 clk=~clk;

    // ps_demux I/O
    logic [7:0] in_byte; logic in_valid; wire in_ready;
    wire [7:0] vid_byte; wire vid_valid; logic vid_ready=1;
    wire [7:0] aud_byte; wire aud_valid; wire [1:0] aud_type; wire aud_frame_start; logic aud_ready=1;
    wire [32:0] vid_pts; wire vid_pts_valid; wire [32:0] aud_pts; wire aud_pts_valid;
    wire [32:0] aud_frame_pts; wire aud_frame_pts_valid;
    wire [7:0] sp_byte; wire sp_valid, sp_frame_start; wire [32:0] sp_pts; wire sp_pts_valid;

    ps_demux dmx (
        .clk(clk), .rst_n(rst_n),
        .in_byte(in_byte), .in_valid(in_valid), .in_ready(in_ready),
        .aud_track(3'd0), .sp_track(3'd0), .sp_enable(1'b1),
        .vid_byte(vid_byte), .vid_valid(vid_valid), .vid_ready(vid_ready),
        .aud_byte(aud_byte), .aud_valid(aud_valid), .aud_type(aud_type),
        .aud_frame_start(aud_frame_start), .aud_ready(aud_ready),
        .vid_pts(vid_pts), .vid_pts_valid(vid_pts_valid),
        .aud_pts(aud_pts), .aud_pts_valid(aud_pts_valid),
        .aud_frame_pts(aud_frame_pts), .aud_frame_pts_valid(aud_frame_pts_valid),
        .sp_byte(sp_byte), .sp_valid(sp_valid), .sp_frame_start(sp_frame_start),
        .sp_pts(sp_pts), .sp_pts_valid(sp_pts_valid)
    );

    logic [11:0] q_x, q_y; wire [1:0] q_idx; wire q_inside, sp_active;
    wire [3:0] a0,a1,a2,a3;
    logic [32:0] stc;
    spu_decode spu (
        .clk(clk), .rst_n(rst_n), .enable(1'b1), .interlaced(1'b0),
        .sp_byte(sp_byte), .sp_valid(sp_valid), .sp_frame_start(sp_frame_start),
        .sp_pts(sp_pts), .sp_pts_valid(sp_pts_valid),
        .stc(stc), .q_x(q_x), .q_y(q_y), .q_idx(q_idx), .q_inside(q_inside),
        .alpha0(a0), .alpha1(a1), .alpha2(a2), .alpha3(a3), .sp_active(sp_active)
    );

    reg [7:0] slice [0:2_100_000];
    reg [1:0] refmem [0:W*(EY-SY+1)-1];
    integer fd, n, i, errors=0, mism=0, cur_y;
    logic [1:0] got;

    task automatic step_y_to(input int ty);
        while (cur_y < ty) begin
            cur_y = cur_y + 1;
            @(negedge clk); q_y = cur_y[11:0]; q_x = 0;
            @(posedge clk);
        end
    endtask
    task automatic read_px(input int x);
        @(negedge clk); q_x = x[11:0];
        @(posedge clk); #1; got = q_idx;
    endtask

    initial begin
        in_byte=0; in_valid=0; stc=0; q_x=0; q_y=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        fd=$fopen("bench/dvd/test_vobs/matrix_subpic_slice.bin","rb");
        if (fd==0) begin $display("RESULT: FAIL cannot open slice"); $finish; end
        n=$fread(slice, fd); $fclose(fd);
        $readmemh("bench/dvd/test_vobs/matrix_spu0.idx.hex", refmem);
        $display("=== subpic chain test === (%0d slice bytes)", n);

        // feed bytes 1/clk (respecting in_ready) until the SPU decodes or slice ends
        i=0;
        while (i<n && !spu.c_valid) begin
            @(negedge clk); in_byte=slice[i]; in_valid=1;
            @(posedge clk); if (in_ready) i=i+1;
        end
        @(negedge clk); in_valid=0;
        if (!spu.c_valid) begin
            $display("  FAIL: SPU never decoded from the real VOB chain (fed %0d bytes)", i); errors++;
        end else begin
            $display("  SPU decoded from chain after %0d fed bytes; pts_latched=%0d", i, spu.pts_latched);
            if (spu.pts_latched !== SHOW) begin
                $display("  FAIL: pts_latched=%0d expected %0d", spu.pts_latched, SHOW); errors++;
            end
            // show it and raster-check the bitmap against the golden fixture
            stc = SHOW; repeat(2) @(posedge clk);   // let combinational `visible` settle
            if (!sp_active) begin $display("  FAIL: sp_active=0 with stc=show"); errors++; end
            @(negedge clk); q_x=0; q_y=0; @(posedge clk); cur_y=0;
            for (int y=SY; y<=EY; y++) begin
                step_y_to(y);
                for (int x=SX; x<=EX; x++) begin
                    read_px(x);
                    if (got !== refmem[(y-SY)*W + (x-SX)]) mism++;
                end
            end
            if (mism!=0) begin $display("  FAIL: %0d/%0d pixels differ from golden", mism, W*(EY-SY+1)); errors++; end
            else $display("  bitmap matches golden model (%0d pixels) through the FULL chain", W*(EY-SY+1));
        end

        if (errors==0) $display("RESULT: PASS (real VOB -> ps_demux -> spu_decode -> correct subtitle)");
        else           $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin #200_000_000; $display("RESULT: FAIL timeout"); $finish; end
endmodule
