// =============================================================================
// bench/dvd/spu_newcell_tb.sv -- the menu re-send guard across a PTS RESTART
// (2026-09-18, Harry Potter Interactive's Player Mode highlight;
// docs/subpicture.md "The re-send guard is per cell").
// =============================================================================
// THE DEFECT.  spu_decode's menu re-send guard skips a unit whose PTS is <= the
// committed one's -- a looping menu re-sends the same unit every VOBU, and the
// Matrix root cell sends a transparent dummy (PTS A) before the real overlay
// (PTS B > A), so "older" must not replace "newer". But PTS order only means
// anything within one timeline. MEASURED on the disc: Player Mode is VTS_05
// PGCN 14, five cells, one VOB each, and EVERY cell's subpicture unit has PTS
// 0.333 s. Cell 1's unit is empty; cells 2 and 3 carry the buttons' 460-pixel
// graphic. The guard skipped them as re-sends of cell 1's, so the highlight
// recoloured nothing (measured on the board: 0 pixels change between Single and
// Multi selected; reproduced here with the real units before this bench).
//
// WHAT THIS MEASURES.  The real spu_decode in menu_mode, scanned in raster
// order: how many NON-BACKGROUND pixels the committed unit puts on screen --
// what the highlight has to recolour. Never guard_open or any signal the fix
// names.
//
//   [N1] EMPTY unit at PTS P, then a new-cell pulse, then a GRAPHIC unit at the
//        same PTS P: the graphic must be on screen.       RED: 0 pixels.
//   [N2] CONTROL: the same two units with NO new-cell pulse -- a same-PTS unit
//        within one cell is a re-send and stays skipped (the looping-menu rule).
//   [N3] after the new cell's unit commits, an OLDER-PTS unit with no pulse is
//        still skipped (the Matrix dummy/overlay order, within the new cell).
//   [N4] newcell_load pulses BEFORE the new unit's first bitmap write. HW round 2:
//        pulsed at COMMIT, the previous cell's highlight lit the graphic for the
//        whole decode ("a blip where both highlight options are visible").
// =============================================================================
`timescale 1ns/1ps
module spu_newcell_tb;
    logic clk=0, rst_n=0;
    always #5 clk=~clk;

    logic [7:0]  sp_byte = 8'd0;
    logic        sp_valid=0, sp_frame_start=0, sp_pts_valid=0, new_cell=0;
    wire         nl;
    // [N4] ordering: the cycle newcell_load pulses vs the first bitmap write after it
    // was armed. bmp_we is the write that changes the SCREEN (one bitmap buffer).
    int  cyc = 0, t_nl = -1, t_bw = -1; bit watch4 = 0;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (watch4 && nl && t_nl < 0) t_nl <= cyc;
        if (watch4 && dut.bmp_we && t_bw < 0) t_bw <= cyc;
    end
    logic [32:0] sp_pts = 0, stc = 33'd100000;
    logic [11:0] q_x=0, q_y=0;
    wire  [1:0]  q_idx;  wire q_inside, sp_active;
    wire [3:0]   a0,a1,a2,a3,c0,c1,c2,c3;

    spu_decode #(.HOLD_CYCLES(63000)) dut (
        .clk(clk), .rst_n(rst_n), .enable(1'b1), .interlaced(1'b0),
        .menu_mode(1'b1), .new_cell(new_cell), .newcell_load(nl),
        .sp_byte(sp_byte), .sp_valid(sp_valid), .sp_frame_start(sp_frame_start),
        .sp_pts(sp_pts), .sp_pts_valid(sp_pts_valid),
        .stc(stc), .q_x(q_x), .q_y(q_y), .q_idx(q_idx), .q_inside(q_inside),
        .alpha0(a0), .alpha1(a1), .alpha2(a2), .alpha3(a3),
        .col0(c0), .col1(c1), .col2(c2), .col3(c3),
        .sp_active(sp_active)
    );
    always @(posedge clk) stc <= stc + 33'd1;

    // ---- a format-real SPU: 16x2 DAREA, each line "fill to end" with `fill`
    byte unsigned spu [0:63];
    int spu_len;
    task automatic mk_spu(input logic [1:0] fill);
        int p;
        begin
            spu[4]=8'h00; spu[5]={6'd0, fill};     // top line: fill with colour `fill`
            spu[6]=8'h00; spu[7]={6'd0, fill};     // bottom line
            spu[2]=8'h00; spu[3]=8'd8;             // DCSQT at 8
            spu[8]=8'h00; spu[9]=8'h00; spu[10]=8'h00; spu[11]=8'd8;   // delay 0, next = self
            p = 12;
            spu[p]=8'h00; p++;                                     // FSTA_DSP
            spu[p]=8'h04; p++; spu[p]=8'hFF; p++; spu[p]=8'hFF; p++;   // SET_CONTR all 15
            spu[p]=8'h05; p++;                                     // SET_DAREA 0..15 x 0..1
            spu[p]=8'h00; p++; spu[p]=8'h00; p++; spu[p]=8'h0F; p++;
            spu[p]=8'h00; p++; spu[p]=8'h00; p++; spu[p]=8'h01; p++;
            spu[p]=8'h06; p++;                                     // SET_DSPXA top=4 bot=6
            spu[p]=8'h00; p++; spu[p]=8'h04; p++; spu[p]=8'h00; p++; spu[p]=8'h06; p++;
            spu[p]=8'hFF; p++;
            spu_len = p;
            spu[0]=spu_len[15:8]; spu[1]=spu_len[7:0];
        end
    endtask
    task automatic feed(input logic [1:0] fill, input logic [32:0] pts);
        mk_spu(fill);
        for (int i=0;i<spu_len;i++) begin
            @(negedge clk);
            sp_byte = spu[i]; sp_valid = 1'b1; sp_frame_start = (i==0);
            sp_pts = pts; sp_pts_valid = (i==0);
        end
        @(negedge clk); sp_valid=0; sp_frame_start=0; sp_pts_valid=0;
        repeat (400) @(posedge clk);                                 // decode + commit
    endtask
    task pulse_new_cell; begin @(negedge clk); new_cell = 1; @(negedge clk); new_cell = 0; end endtask

    // count non-background pixels over the DAREA, in raster order
    function automatic int dummy(); return 0; endfunction
    int nz;
    task automatic scan();
        nz = 0;
        for (int y = 0; y < 2; y++)
            for (int x = 0; x < 20; x++) begin
                @(negedge clk); q_x = x; q_y = y;
                @(posedge clk); #1;
                if (q_inside && q_idx !== 2'd0 && q_idx !== 2'bxx) nz++;
            end
    endtask

    int errors = 0;
    task fail(input string m); begin $display("FAIL: %s", m); errors++; end endtask
    task reset_dut; begin rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk); end endtask

    localparam logic [32:0] P = 33'd30000;    // 0.333 s, the disc's per-cell PTS

    initial begin
        // ---- [N1] a new cell's unit at the SAME PTS must replace the old ----
        reset_dut;
        feed(2'd0, P);            // cell 1: empty unit
        pulse_new_cell;           // the delivered stream enters cell 2
        feed(2'd3, P);            // cell 2: the graphic, same PTS
        scan();
        if (nz == 0) fail("[N1] the new cell's graphic unit was skipped (same PTS as the old cell's)");
        else $display("   [N1] new cell's graphic on screen: %0d px  ok", nz);

        // ---- [N2] control: no pulse = a same-PTS re-send, still skipped -----
        reset_dut;
        feed(2'd0, P);
        feed(2'd3, P);            // same cell: a re-send by PTS rule
        scan();
        if (nz != 0) fail("[N2] a same-PTS unit with NO cell change replaced the committed one");
        else $display("   [N2] same cell, same PTS: still skipped  ok");

        // ---- [N3] after the new cell's unit commits, older re-sends are skipped
        reset_dut;
        feed(2'd0, P);
        pulse_new_cell;
        feed(2'd3, P + 33'd9000); // new cell's real overlay (PTS B)
        feed(2'd0, P);            // a DUMMY re-send, older PTS A, no pulse
        scan();
        if (nz == 0) fail("[N3] an older-PTS re-send replaced the new cell's overlay (guard left open)");
        else $display("   [N3] older re-send after the commit: skipped, overlay kept  ok");

        // ---- [N4] the load pulse precedes the first pixel of the new unit ----
        reset_dut;
        feed(2'd0, P);
        pulse_new_cell;
        watch4 = 1; t_nl = -1; t_bw = -1;
        feed(2'd3, P);
        watch4 = 0;
        // Judged only when the new unit actually wrote pixels: a unit that was never
        // accepted is [N1]'s failure, and scoring it here too would double-report it.
        if (t_bw >= 0 && t_nl < 0) fail("[N4] the new unit wrote pixels and newcell_load never pulsed");
        else if (t_bw >= 0 && t_nl > t_bw) begin
            $display("   [N4] load pulse at %0d, first bitmap write at %0d", t_nl, t_bw);
            fail("[N4] the new unit wrote pixels before newcell_load (the highlight blip)");
        end else $display("   [N4] load pulse %0d cycles before the first bitmap write  ok", t_bw - t_nl);

        if (errors == 0) $display("RESULT: PASS");
        else begin $display("RESULT: FAIL (%0d)", errors); $fatal(1, "spu_newcell_tb failed"); end
        $finish;
    end
endmodule
