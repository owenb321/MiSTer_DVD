// =============================================================================
// bench/dvd/spu_decode_480i_tb.sv — SPU render in CRT 480i (interlaced) mode
// =============================================================================
// Same real Matrix SPU + golden model as spu_decode_tb.sv, but drives the DUT with
// interlaced=1 and raster-scans in INTERLACED order:
//   * top (even) field:    q_y = 0,2,4,..  -> absolute even lines
//   * bottom (odd) field:   q_y = 1,3,5,..  -> absolute odd lines
// In 480i syncgen sets core_v_pos = {v_cntr, ~odd_field} = the ABSOLUTE frame line,
// advancing by 2 within a field (bit0 = constant field parity). This test asserts the
// interlaced render addressing lands each field's pixels on the correct absolute bitmap
// line, i.e. the two fields REASSEMBLE the identical golden progressive bitmap that
// spu_decode_tb.sv matches (top=even / bottom=odd, DAREA sy=384..420).
//
// Fixture: bench/dvd/test_vobs/matrix_spu0.{bin,idx.hex,params} (see spu_decode_tb.sv).
// =============================================================================
`timescale 1ns/1ps
module spu_decode_480i_tb;
    localparam SX=161, EX=558, SY=384, EY=420, W=398, H=37;
    localparam PTS  = 33'd14442072;
    localparam SHOW = 33'd14442072;
    localparam HIDE = 33'd14636632;

    logic clk=0, rst_n=0;
    always #5 clk=~clk;

    logic [7:0]  sp_byte;
    logic        sp_valid, sp_frame_start, sp_pts_valid;
    logic [32:0] sp_pts;
    logic [32:0] stc;
    logic        enable;
    logic [11:0] q_x, q_y;
    wire  [1:0]  q_idx;
    wire         q_inside, sp_active;
    wire [3:0]   alpha0, alpha1, alpha2, alpha3;

    spu_decode dut (
        .clk(clk), .rst_n(rst_n), .enable(enable), .interlaced(1'b1),
        .sp_byte(sp_byte), .sp_valid(sp_valid), .sp_frame_start(sp_frame_start),
        .sp_pts(sp_pts), .sp_pts_valid(sp_pts_valid),
        .stc(stc), .q_x(q_x), .q_y(q_y), .q_idx(q_idx), .q_inside(q_inside),
        .alpha0(alpha0), .alpha1(alpha1), .alpha2(alpha2), .alpha3(alpha3),
        .sp_active(sp_active)
    );

    reg [7:0] spubytes [0:8191];
    reg [1:0] refmem [0:H*W-1];
    integer fd, n, errors=0, mism=0, t;
    logic [1:0] got;

    task automatic feed_spu(input int cnt);
        for (int i=0;i<cnt;i++) begin
            @(negedge clk);
            sp_byte = spubytes[i];
            sp_valid = 1;
            sp_frame_start = (i==0);
            sp_pts = PTS; sp_pts_valid = (i==0);
        end
        @(negedge clk); sp_valid=0; sp_frame_start=0; sp_pts_valid=0;
    endtask

    // Interlaced raster: q_y advances by 2 within a field. Walk it one field-line at a
    // time (matching the +2*STRIDE accumulator step) so q_row_base builds correctly from
    // the field top, exactly as the real 480i scan drives core_v_pos.
    int cur_y;
    task automatic field_top(input int parity);  // 0=even/top field, 1=odd/bottom field
        @(negedge clk); q_y = parity[11:0]; q_x = 0;   // q_y<=1 re-bases to parity offset
        @(posedge clk); cur_y = parity;
    endtask
    task automatic step_y_to(input int ty);       // ty must have the field parity
        while (cur_y < ty) begin
            cur_y = cur_y + 2;
            @(negedge clk); q_y = cur_y[11:0]; q_x = 0;
            @(posedge clk);
        end
    endtask
    task automatic read_px(input int x);
        @(negedge clk); q_x = x[11:0];
        @(posedge clk); #1;
        got = q_idx;
    endtask

    // Scan one field (all abs lines of the given parity within [SY,EY]) and compare.
    task automatic scan_field(input int parity);
        field_top(parity);
        for (int y=SY; y<=EY; y++) begin
            if ((y & 1) != parity) continue;   // this field only carries this parity
            step_y_to(y);
            for (int x=SX; x<=EX; x++) begin
                read_px(x);
                if (got !== refmem[(y-SY)*W + (x-SX)]) begin
                    if (mism<10) $display("  pixel FAIL field%0d (%0d,%0d) got %0d exp %0d",
                                          parity,x,y,got,refmem[(y-SY)*W+(x-SX)]);
                    mism++;
                end
            end
        end
    endtask

    initial begin
        sp_valid=0; sp_frame_start=0; sp_pts_valid=0; sp_byte=0; sp_pts=0;
        stc=0; enable=1; q_x=0; q_y=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        fd=$fopen("bench/dvd/test_vobs/matrix_spu0.bin","rb");
        if (fd==0) begin $display("RESULT: FAIL cannot open matrix_spu0.bin"); $finish; end
        n=$fread(spubytes, fd); $fclose(fd);
        $display("=== spu_decode 480i (interlaced) test === (%0d SPU bytes)", n);
        $readmemh("bench/dvd/test_vobs/matrix_spu0.idx.hex", refmem);

        // feed the SPU and let it decode (write side is mode-independent)
        feed_spu(n);
        stc = SHOW;
        t=0; while (!sp_active && t<200000) begin @(posedge clk); t=t+1; end
        if (!sp_active) begin $display("  FAIL: decode never completed / sp_active=0"); errors++; end
        else $display("  decode complete after ~%0d cycles", t);

        // ---- bitmap check, INTERLACED scan: two fields reassemble the golden bitmap ----
        stc = SHOW;
        scan_field(0);   // top field: even absolute lines (384,386,..,420)
        scan_field(1);   // bottom field: odd absolute lines (385,387,..,419)
        if (mism!=0) begin $display("  FAIL: %0d/%0d pixels mismatch", mism, W*H); errors++; end
        else $display("  bitmap OK (both fields reassemble %0d golden pixels)", W*H);

        // ---- q_inside gating spot check inside DAREA (bottom field, odd line 401) ----
        field_top(1); step_y_to(401);
        @(negedge clk); q_x=300; @(posedge clk); @(posedge clk);
        if (!q_inside) begin $display("  FAIL: q_inside=0 inside DAREA/in-window (480i)"); errors++; end
        stc = HIDE;  @(posedge clk); @(posedge clk);
        if (q_inside) begin $display("  FAIL: q_inside=1 while hidden (480i)"); errors++; end
        if (errors==0) $display("  q_inside gating OK (480i)");

        if (errors==0) $display("RESULT: PASS (480i interlaced render matches golden model)");
        else           $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin #50_000_000; $display("RESULT: FAIL timeout"); $finish; end
endmodule
