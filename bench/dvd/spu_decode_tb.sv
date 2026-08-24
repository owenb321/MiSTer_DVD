// =============================================================================
// bench/dvd/spu_decode_tb.sv — SPU decode + render, real Matrix subtitle
// =============================================================================
// Feeds a REAL extracted SPU (bench/dvd/test_vobs/matrix_spu0.bin, the Matrix
// subtitle "You hear that, Mr. Anderson?") into dvd/spu_decode.sv and checks:
//   * show/hide timing vs the STC (sp_active crosses show_tick / hide_tick)
//   * the decoded 2-bpp bitmap matches the golden model (tools/spu_ref.py, dumped
//     to matrix_spu0.idx.hex) across the whole DAREA
//   * q_inside gates correctly (inside DAREA + visible)
//
// Golden params (from matrix_spu0.params):
//   DAREA sx=161 ex=558 sy=384 ey=420  width=398 height=37
//   pts=14442072  show=14442072  hide=14636632
// Regenerate the fixture with:
//   tools/spu_ref.py extract tools/streams/MATRIX.VOB --out bench/dvd/test_vobs/matrix_spu0
//   tools/spu_ref.py decode  bench/dvd/test_vobs/matrix_spu0.bin --pts 14442072 \
//       --memh bench/dvd/test_vobs/matrix_spu0.idx.hex --params bench/dvd/test_vobs/matrix_spu0.params
// =============================================================================
`timescale 1ns/1ps
module spu_decode_tb;
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
    wire [3:0]   col0, col1, col2, col3;

    logic        menu_mode = 1'b0;
    spu_decode dut (
        .clk(clk), .rst_n(rst_n), .enable(enable), .interlaced(1'b0),
        .menu_mode(menu_mode),
        .sp_byte(sp_byte), .sp_valid(sp_valid), .sp_frame_start(sp_frame_start),
        .sp_pts(sp_pts), .sp_pts_valid(sp_pts_valid),
        .stc(stc), .q_x(q_x), .q_y(q_y), .q_idx(q_idx), .q_inside(q_inside),
        .alpha0(alpha0), .alpha1(alpha1), .alpha2(alpha2), .alpha3(alpha3),
        .col0(col0), .col1(col1), .col2(col2), .col3(col3),
        .sp_active(sp_active)
    );

    reg [7:0] spubytes [0:8191];
    reg [7:0] bigspu   [0:65535];   // Phase-2 spec-max / over-spec synthetic units
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

    // feed the fixture with an explicit PTS (menu re-send discriminator test)
    task automatic feed_spu_pts(input int cnt, input logic [32:0] ptsval);
        for (int i=0;i<cnt;i++) begin
            @(negedge clk);
            sp_byte = spubytes[i];
            sp_valid = 1;
            sp_frame_start = (i==0);
            sp_pts = ptsval; sp_pts_valid = (i==0);
        end
        @(negedge clk); sp_valid=0; sp_frame_start=0; sp_pts_valid=0;
    endtask

    // feed the Phase-2 synthetic unit from bigspu with an explicit PTS
    task automatic feed_big(input int cnt, input logic [32:0] ptsval);
        for (int i=0;i<cnt;i++) begin
            @(negedge clk);
            sp_byte = bigspu[i];
            sp_valid = 1;
            sp_frame_start = (i==0);
            sp_pts = ptsval; sp_pts_valid = (i==0);
        end
        @(negedge clk); sp_valid=0; sp_frame_start=0; sp_pts_valid=0;
    endtask

    // Raster helpers — drive q_x/q_y on the NEGEDGE so they are stable at the posedge
    // the DUT samples (avoids delta races). q_row_base accumulates on q_y +1 steps, so
    // step_y_to() walks q_y one line at a time from its current value.
    int cur_y;
    task automatic step_y_to(input int ty);
        while (cur_y < ty) begin
            cur_y = cur_y + 1;
            @(negedge clk); q_y = cur_y[11:0]; q_x = 0;
            @(posedge clk);
        end
    endtask
    task automatic read_px(input int x);
        @(negedge clk); q_x = x[11:0];
        @(posedge clk); #1;
        got = q_idx;
    endtask

    initial begin
        sp_valid=0; sp_frame_start=0; sp_pts_valid=0; sp_byte=0; sp_pts=0;
        stc=0; enable=1; q_x=0; q_y=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        // load fixture
        fd=$fopen("bench/dvd/test_vobs/matrix_spu0.bin","rb");
        if (fd==0) begin $display("RESULT: FAIL cannot open matrix_spu0.bin"); $finish; end
        n=$fread(spubytes, fd); $fclose(fd);
        $display("=== spu_decode test === (%0d SPU bytes)", n);
        $readmemh("bench/dvd/test_vobs/matrix_spu0.idx.hex", refmem);

        // feed the SPU and let it decode
        feed_spu(n);
        // wait for decode to finish: put STC in-window and poll sp_active
        stc = SHOW;
        t=0; while (!sp_active && t<200000) begin @(posedge clk); t=t+1; end
        if (!sp_active) begin $display("  FAIL: decode never completed / sp_active=0"); errors++; end
        else $display("  decode complete after ~%0d cycles", t);

        // ---- timing checks ----
        stc = SHOW-1;   repeat(2) @(posedge clk);
        if (sp_active) begin $display("  FAIL: visible before show_tick"); errors++; end
        stc = SHOW;     repeat(2) @(posedge clk);
        if (!sp_active) begin $display("  FAIL: not visible at show_tick"); errors++; end
        stc = HIDE-1;   repeat(2) @(posedge clk);
        if (!sp_active) begin $display("  FAIL: not visible just before hide"); errors++; end
        stc = HIDE;     repeat(2) @(posedge clk);
        if (sp_active) begin $display("  FAIL: still visible at hide_tick"); errors++; end
        if (errors==0) $display("  timing OK (show=%0d hide=%0d)", SHOW, HIDE);

        // ---- MENU MODE: the STC show/hide window is IGNORED (menus show their
        // subpicture the whole time they're up; the STC leads the display so the
        // window would wrongly expire it). At stc=HIDE (past the window) and even
        // far beyond, a committed SPU must stay visible while menu_mode=1. ----
        menu_mode = 1'b1;
        stc = HIDE;         repeat(2) @(posedge clk);
        if (!sp_active) begin $display("  FAIL: menu SPU not visible at hide (window not bypassed)"); errors++; end
        stc = HIDE + 33'd9000000; repeat(2) @(posedge clk);   // ~100 s later
        if (!sp_active) begin $display("  FAIL: menu SPU expired long past hide"); errors++; end
        stc = SHOW - 33'd1; repeat(2) @(posedge clk);         // even before c_show
        if (!sp_active) begin $display("  FAIL: menu SPU not visible (c_show lower bound not bypassed)"); errors++; end
        else $display("  menu_mode visibility OK (STC window bypassed)");
        menu_mode = 1'b0;

        // check alpha (SET_CONTR: a0=0,a1=15,a2=15,a3=15 for this SPU)
        if (alpha0!==4'd0 || alpha1!==4'd15 || alpha2!==4'd15 || alpha3!==4'd15) begin
            $display("  FAIL: alpha=%0d,%0d,%0d,%0d expected 0,15,15,15",
                     alpha0,alpha1,alpha2,alpha3); errors++;
        end else $display("  alpha OK (0,15,15,15)");

        // check SET_COLOR (Matrix SPU carries "03 08 90": c3=0,c2=8,c1=9,c0=0 -> PGC
        // palette indices per 2-bpp colour). Phase-1 disc menus.
        if (col0!==4'd0 || col1!==4'd9 || col2!==4'd8 || col3!==4'd0) begin
            $display("  FAIL: col=%0d,%0d,%0d,%0d expected 0,9,8,0",
                     col0,col1,col2,col3); errors++;
        end else $display("  col OK (0,9,8,0)");

        // ---- bitmap check: raster-scan so q_row_base tracks q_y ----
        stc = SHOW;                    // in-window for q_inside spot checks
        @(negedge clk); q_x=0; q_y=0; @(posedge clk); cur_y=0;
        for (int y=SY; y<=EY; y++) begin
            step_y_to(y);
            for (int x=SX; x<=EX; x++) begin
                read_px(x);
                if (got !== refmem[(y-SY)*W + (x-SX)]) begin
                    if (mism<10) $display("  pixel FAIL (%0d,%0d) got %0d exp %0d",
                                          x,y,got,refmem[(y-SY)*W+(x-SX)]);
                    mism++;
                end
            end
        end
        if (mism!=0) begin $display("  FAIL: %0d/%0d pixels mismatch", mism, W*H); errors++; end
        else $display("  bitmap OK (%0d pixels match golden model)", W*H);

        // ---- q_inside gating spot check: a known text pixel vs outside DAREA ----
        step_y_to(400);
        @(negedge clk); q_x=300; @(posedge clk); @(posedge clk);
        if (!q_inside) begin $display("  FAIL: q_inside=0 inside DAREA/in-window"); errors++; end
        stc = HIDE;  @(posedge clk); @(posedge clk);
        if (q_inside) begin $display("  FAIL: q_inside=1 while hidden"); errors++; end
        if (errors==0) $display("  q_inside gating OK");

        // ---- MENU re-send discriminator (return-highlight fix, dvd_menu_refinements §7) ----
        // A menu loop re-sends its subpicture(s); Matrix's root cell sends a DUMMY then the
        // REAL overlay with a LATER PTS. The skip guard must ACCEPT a genuinely newer unit
        // (pts > committed) even when stc has not reached it, and SKIP a re-send (pts <=
        // committed). stc is held LOW so the OLD `stc < sp_pts` guard would skip BOTH.
        menu_mode = 1'b1;
        stc = 33'd0;                          // below every PTS -> old guard would skip all
        feed_spu_pts(n, PTS);                 // commit unit "A" at PTS
        t=0; while (dut.c_pts !== PTS && t<200000) begin @(posedge clk); t=t+1; end
        if (dut.c_pts !== PTS) begin $display("  FAIL: menu unit A did not commit (c_pts=%0d)", dut.c_pts); errors++; end
        // (a) NEWER unit "B" (pts = PTS+90000) must be ACCEPTED despite stc=0 < its pts
        feed_spu_pts(n, PTS + 33'd90000);
        t=0; while (dut.c_pts !== (PTS + 33'd90000) && t<200000) begin @(posedge clk); t=t+1; end
        if (dut.c_pts !== (PTS + 33'd90000)) begin
            $display("  FAIL: newer menu unit B was SKIPPED (c_pts=%0d, want %0d) -- the 2nd-loop bug",
                     dut.c_pts, PTS + 33'd90000); errors++;
        end else $display("  menu re-send OK: newer unit accepted (c_pts advanced to B)");
        // (b) a RE-SEND of the older unit A (pts <= committed) must be SKIPPED (c_pts stays B)
        feed_spu_pts(n, PTS);
        repeat (2000) @(posedge clk);
        if (dut.c_pts !== (PTS + 33'd90000)) begin
            $display("  FAIL: an older re-send replaced the committed unit (c_pts=%0d)", dut.c_pts); errors++;
        end else $display("  menu re-send OK: older re-send skipped (committed unit held)");
        menu_mode = 1'b0;

        // =====================================================================
        // Spec-hardening Phase 2: SPU_CAP at the spec maximum (53,220 B)
        // =====================================================================
        // ---- synthetic SPEC-MAX SPU: SPDSZ = 53,220 exactly, tiny bitmap at the
        // head, dead padding, DCSQ table at the tail (the authored shape whose
        // tail a small cap silently dropped — the PR #84 twice-bitten class).
        // DAREA x100..115 y50..53, fill colour 1, SET_COLOR 0,1,2,3, alpha 0,15,15,15.
        begin
            int off;
            for (int i=0;i<65536;i++) bigspu[i] = 8'h00;
            bigspu[0]=8'hCF; bigspu[1]=8'hE4;              // SPDSZ = 53220
            bigspu[2]=8'hCF; bigspu[3]=8'hCC;              // DCSQT_SA = 53196
            // pixel data: 2 B/line "fill to EOL colour 1" (nibbles 0,0,0,1)
            bigspu[4]=8'h00; bigspu[5]=8'h01;              // top field line 0 (abs y50)
            bigspu[6]=8'h00; bigspu[7]=8'h01;              // top field line 1 (abs y52)
            bigspu[8]=8'h00; bigspu[9]=8'h01;              // bottom field (abs y51)
            bigspu[10]=8'h00; bigspu[11]=8'h01;            // bottom field (abs y53)
            off = 53196;                                   // DCSQ: delay=0, next=self
            bigspu[off+0]=8'h00; bigspu[off+1]=8'h00;
            bigspu[off+2]=8'hCF; bigspu[off+3]=8'hCC;
            bigspu[off+4]=8'h03; bigspu[off+5]=8'h32; bigspu[off+6]=8'h10;   // SET_COLOR c3..c0=3,2,1,0
            bigspu[off+7]=8'h04; bigspu[off+8]=8'hFF; bigspu[off+9]=8'hF0;   // SET_CONTR a3..a0=15,15,15,0
            bigspu[off+10]=8'h05;                                            // SET_DAREA
            bigspu[off+11]=8'h06; bigspu[off+12]=8'h40; bigspu[off+13]=8'h73; // sx=100 ex=115
            bigspu[off+14]=8'h03; bigspu[off+15]=8'h20; bigspu[off+16]=8'h35; // sy=50 ey=53
            bigspu[off+17]=8'h06;                                            // SET_DSPXA
            bigspu[off+18]=8'h00; bigspu[off+19]=8'h04;                      // top = 4
            bigspu[off+20]=8'h00; bigspu[off+21]=8'h08;                      // bottom = 8
            bigspu[off+22]=8'h01;                                            // STA_DSP
            bigspu[off+23]=8'hFF;                                            // CMD_END
        end
        feed_big(53220, 33'd1000);
        stc = 33'd2000;                    // past show (= pts, delay 0)
        t=0; while (dut.c_pts !== 33'd1000 && t<400000) begin @(posedge clk); t=t+1; end
        if (dut.c_pts !== 33'd1000 || !sp_active) begin
            $display("  FAIL: spec-max 53,220 B SPU did not decode/commit (c_pts=%0d active=%b)",
                     dut.c_pts, sp_active); errors++;
        end else $display("  spec-max SPU OK: decoded + committed (~%0d cycles)", t);
        if (col0!==4'd0 || col1!==4'd1 || col2!==4'd2 || col3!==4'd3 ||
            alpha0!==4'd0 || alpha1!==4'd15) begin
            $display("  FAIL: spec-max SPU tail DCSQ params wrong (col=%0d,%0d,%0d,%0d)",
                     col0,col1,col2,col3); errors++;
        end else $display("  spec-max SPU tail DCSQ params OK (the twice-bitten class)");
        // spot-check the bitmap: inside the DAREA -> colour 1, row above -> untouched
        @(negedge clk); q_x=0; q_y=0; @(posedge clk); cur_y=0;
        step_y_to(52);
        read_px(108);
        if (got !== 2'd1 || !q_inside) begin
            $display("  FAIL: spec-max SPU pixel (108,52) got %0d inside=%b (want 1,1)",
                     got, q_inside); errors++;
        end else $display("  spec-max SPU bitmap OK");

        // ---- OVER-SPEC unit (SPDSZ 60,000 > SPU_CAP): must DROP cleanly --
        // keeping the committed spec-max SPU intact -- and the tail bytes must
        // NOT be misread as a new unit (drain until the next PTS-carrying
        // packet). Then a normal unit must still decode.
        begin
            bigspu[0]=8'hEA; bigspu[1]=8'h60;              // SPDSZ = 60000
            bigspu[2]=8'hEA; bigspu[3]=8'h48;              // DCSQT_SA = 59976 (> cap)
        end
        feed_big(60000, 33'd5000);
        repeat (2000) @(posedge clk);
        if (dut.c_pts !== 33'd1000) begin
            $display("  FAIL: over-spec SPU corrupted the committed unit (c_pts=%0d)",
                     dut.c_pts); errors++;
        end else $display("  over-spec SPU dropped cleanly (committed unit held)");
        // normal unit still decodes after the drain (matrix fixture, subtitle path)
        stc = 33'd0;
        feed_spu(n);
        stc = SHOW;
        t=0; while (dut.c_pts !== PTS && t<200000) begin @(posedge clk); t=t+1; end
        if (dut.c_pts !== PTS || !sp_active) begin
            $display("  FAIL: normal SPU did not decode after the over-spec drain"); errors++;
        end else $display("  post-drain decode OK (drain releases on a PTS packet)");

        if (errors==0) $display("RESULT: PASS (SPU decode matches golden model)");
        else           $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin #50_000_000; $display("RESULT: FAIL timeout"); $finish; end
endmodule
