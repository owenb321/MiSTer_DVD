// =============================================================================
// bench/dvd/spu_forced_tb.sv -- forced subtitles in dvd/spu_decode.sv
// =============================================================================
// docs/subpicture.md "Forced subtitles". A DVD marks a subtitle unit FORCED by
// starting it with display-control command 0x00 FSTA_DSP instead of 0x01
// STA_DSP. A set-top player with subtitles OFF still shows forced units (the
// usual case: one line of foreign-language dialogue in a film). spu_decode's
// forced_only input is that mode: decode and commit every unit, show only the
// forced ones.
//
// Fixture: the REAL Matrix subtitle unit (bench/dvd/test_vobs/matrix_spu0.bin,
// "You hear that, Mr. Anderson?", see spu_decode_tb.sv for how to regenerate).
// Its first DCSQ starts with 0x01 STA_DSP at byte DCSQ_CMD0. The FORCED variant
// is the same unit with that one byte set to 0x00 -- identical bitmap, colours
// and timing, so every difference the arms see is the forced flag alone.
//
// Arms (each FAIL line names its arm; bench/dvd/run_forced_subs.sh --red checks
// that each mutation trips exactly the arms it should):
//   [F1] forced_only=1 hides a committed NON-forced unit inside its window
//   [F2] dropping forced_only shows that same unit at once (it was decoded)
//   [F3] forced_only=1 SHOWS a forced unit inside its window, golden pixel
//   [F4] a forced unit still obeys its authored hide time under forced_only
//   [F5] the flag is per unit: a non-forced unit after a forced one is hidden
//   [F6] forced_only=0 shows a forced unit (FSTA_DSP is still a start display)
// =============================================================================
`timescale 1ns/1ps
module spu_forced_tb;
    localparam PTS  = 33'd14442072;
    localparam SHOW = 33'd14442072;
    localparam HIDE = 33'd14636632;
    localparam int DCSQ_CMD0 = 1322;   // DCSQT_SA 1318 + delay(2) + next(2)
    localparam int PX = 300, PY = 400; // a text pixel inside the DAREA
    localparam int SX = 161, SY = 384, W = 398;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [7:0]  sp_byte;
    logic        sp_valid, sp_frame_start, sp_pts_valid;
    logic [32:0] sp_pts, stc;
    logic        forced_only;
    logic [11:0] q_x, q_y;
    wire  [1:0]  q_idx;
    wire         q_inside, sp_active;
    wire  [3:0]  alpha0, alpha1, alpha2, alpha3, col0, col1, col2, col3;

    spu_decode dut (
        .clk(clk), .rst_n(rst_n), .enable(1'b1), .forced_only(forced_only),
        .interlaced(1'b0), .menu_mode(1'b0), .title_menu(1'b0), .new_cell(1'b0), .newcell_load(),
        .sp_byte(sp_byte), .sp_valid(sp_valid), .sp_frame_start(sp_frame_start),
        .sp_pts(sp_pts), .sp_pts_valid(sp_pts_valid),
        .stc(stc), .q_x(q_x), .q_y(q_y), .q_idx(q_idx), .q_inside(q_inside),
        .alpha0(alpha0), .alpha1(alpha1), .alpha2(alpha2), .alpha3(alpha3),
        .col0(col0), .col1(col1), .col2(col2), .col3(col3),
        .sp_active(sp_active)
    );

    reg [7:0] spubytes [0:8191];
    reg [1:0] refmem   [0:37*398-1];
    integer fd, n, errors = 0, t;
    int cur_y;

    // feed the fixture; `forced` patches the first DCSQ's start command to 0x00
    task automatic feed(input logic [32:0] ptsval, input bit forced);
        for (int i = 0; i < n; i++) begin
            @(negedge clk);
            sp_byte        = (i == DCSQ_CMD0) ? (forced ? 8'h00 : 8'h01) : spubytes[i];
            sp_valid       = 1;
            sp_frame_start = (i == 0);
            sp_pts         = ptsval;
            sp_pts_valid   = (i == 0);
        end
        @(negedge clk); sp_valid = 0; sp_frame_start = 0; sp_pts_valid = 0;
    endtask

    // wait for a unit with this PTS to commit
    task automatic wait_commit(input logic [32:0] ptsval, input string arm);
        t = 0;
        while (dut.c_pts !== ptsval && t < 300000) begin @(posedge clk); t++; end
        if (dut.c_pts !== ptsval) begin
            $display("  FAIL [%s] unit never committed (c_pts=%0d)", arm, dut.c_pts);
            errors++;
        end
    endtask

    // raster to (PX,PY) from the top so q_row_base walks like a real scan
    task automatic probe;
        @(negedge clk); q_x = 0; q_y = 0; @(posedge clk); cur_y = 0;
        while (cur_y < PY) begin
            cur_y++;
            @(negedge clk); q_y = cur_y[11:0]; q_x = 0;
            @(posedge clk);
        end
        @(negedge clk); q_x = PX[11:0];
        @(posedge clk); @(posedge clk); #1;
    endtask

    initial begin
        sp_valid = 0; sp_frame_start = 0; sp_pts_valid = 0; sp_byte = 0; sp_pts = 0;
        stc = 0; forced_only = 0; q_x = 0; q_y = 0;
        repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);

        fd = $fopen("bench/dvd/test_vobs/matrix_spu0.bin", "rb");
        if (fd == 0) $fatal(1, "RESULT: FAIL cannot open matrix_spu0.bin");
        n = $fread(spubytes, fd); $fclose(fd);
        $readmemh("bench/dvd/test_vobs/matrix_spu0.idx.hex", refmem);
        if (spubytes[DCSQ_CMD0] !== 8'h01)
            $fatal(1, "RESULT: FAIL fixture moved: byte %0d is %02h, not 01 STA_DSP",
                   DCSQ_CMD0, spubytes[DCSQ_CMD0]);
        $display("=== spu_forced test === (%0d SPU bytes)", n);

        // ---- [F1] non-forced unit, forced_only=1: decoded but hidden ----
        forced_only = 1;
        feed(PTS, 0);
        stc = SHOW;
        wait_commit(PTS, "F1");
        repeat (4) @(posedge clk);
        if (sp_active !== 1'b0) begin
            $display("  FAIL [F1] a non-forced unit is visible under forced_only"); errors++;
        end
        probe;
        if (q_inside !== 1'b0) begin
            $display("  FAIL [F1] q_inside=1 for a non-forced unit under forced_only"); errors++;
        end
        if (errors == 0) $display("  [F1] OK: non-forced unit hidden under forced_only");

        // ---- [F2] drop forced_only: the same unit shows immediately ----
        forced_only = 0;
        repeat (2) @(posedge clk);
        if (sp_active !== 1'b1) begin
            $display("  FAIL [F2] the decoded unit did not appear when forced_only dropped"); errors++;
        end else $display("  [F2] OK: decoded-but-hidden unit shows at once");

        // ---- [F3] forced unit, forced_only=1: shown, and the bitmap is right ----
        forced_only = 1;
        stc = 33'd0;
        feed(PTS + 33'd1, 1);
        stc = SHOW + 33'd1;
        wait_commit(PTS + 33'd1, "F3");
        repeat (4) @(posedge clk);
        if (sp_active !== 1'b1) begin
            $display("  FAIL [F3] a forced unit is hidden under forced_only"); errors++;
        end
        probe;
        if (q_inside !== 1'b1 || q_idx !== refmem[(PY-SY)*W + (PX-SX)]) begin
            $display("  FAIL [F3] forced unit pixel (%0d,%0d): inside=%b idx=%0d want 1,%0d",
                     PX, PY, q_inside, q_idx, refmem[(PY-SY)*W + (PX-SX)]); errors++;
        end else $display("  [F3] OK: forced unit shown under forced_only, golden pixel");

        // ---- [F4] the forced unit still hides at its authored time ----
        stc = HIDE + 33'd1;
        repeat (2) @(posedge clk);
        if (sp_active !== 1'b0) begin
            $display("  FAIL [F4] a forced unit outlived its hide time"); errors++;
        end else $display("  [F4] OK: forced unit obeys its window");

        // ---- [F5] per-unit flag: a following non-forced unit is hidden again ----
        stc = 33'd0;
        feed(PTS + 33'd2, 0);
        stc = SHOW + 33'd2;
        wait_commit(PTS + 33'd2, "F5");
        repeat (4) @(posedge clk);
        if (sp_active !== 1'b0) begin
            $display("  FAIL [F5] the forced flag stuck to the next (non-forced) unit"); errors++;
        end else $display("  [F5] OK: forced flag is per unit");

        // ---- [F6] forced_only=0: a forced unit is an ordinary start display ----
        forced_only = 0;
        stc = 33'd0;
        feed(PTS + 33'd3, 1);
        stc = SHOW + 33'd3;
        wait_commit(PTS + 33'd3, "F6");
        repeat (4) @(posedge clk);
        if (sp_active !== 1'b1) begin
            $display("  FAIL [F6] a forced unit is hidden with forced_only=0"); errors++;
        end else $display("  [F6] OK: FSTA_DSP still starts a display normally");

        if (errors == 0) $display("RESULT: PASS (forced subtitles)");
        else $fatal(1, "RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin #80_000_000; $fatal(1, "RESULT: FAIL timeout"); end
endmodule
