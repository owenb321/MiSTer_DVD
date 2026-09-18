// flashlight_tb.sv -- what a subpicture pixel LOOKS like after composition, for the
// real Scooby-Doo 2 museum screen, T2's hotspot-only root menu and an ordinary
// subtitle (2026-09-18; dvd/hl_compose.sv, docs/subpicture.md).
//
// THE DEFECT.  Scooby-Doo 2's museum "flashlight": the SPU dims the WHOLE screen
// (class 0 background and class 2 exhibit circles, both palette 7 = black at
// contrast 12), and the selected coli 0x0507000c keeps class 0 black at 12 while
// giving class 2 contrast 0 -- the exhibit is cut out of the darkness. We drew
// dark circles on an undimmed screen and a dark square on the selection:
//   - subpic_blend keyed class 0 out as "transparent by convention" (a Phase-1
//     relic from before SET_CONTR), so the dimming never drew;
//   - a contrast-0 class inside the rect kept its SUBPICTURE pixel (black 12),
//     so the lit circle drew dark.
//
// WHAT THIS MEASURES.  The composited RGB out of the REAL hl_compose -> palette ->
// subpic_blend chain for one pixel of each class, inside and outside the rect,
// against a mid-grey video pixel. It scores LIT (== video) / DIMMED (< video) /
// what a real player draws, never a signal the fix names.
//
//   [S1] museum, outside the rect, background (class 0): DIMMED
//   [S2] museum, outside the rect, exhibit (class 2):    DIMMED
//   [S3] museum, INSIDE the rect, exhibit (class 2):     LIT  (the flashlight)
//   [S4] museum, inside the rect, background (class 0):  DIMMED
//   [T1] T2 hotspot coli 0x44440000: every class inside the rect draws exactly
//        as it does outside (the subpicture keeps its selected-state graphic)
//   [R1] a recolouring coli: the recoloured class takes the HLI colour + contrast
//   [U1] a subtitle whose background has contrast 0 draws no box
//
// Run: bench/dvd/run_flashlight.sh
`timescale 1ns/1ps
`default_nettype none
module flashlight_tb;
    // the real museum PGC palette (VTS_02 PGCN 11), as the RGB the core draws
    localparam [7:0] VID = 8'd160;          // underlying video pixel, mid grey

    reg  [1:0]  idx;
    reg  [3:0]  col0, col1, col2, col3, a0, a1, a2, a3;
    reg         hl_hit;
    reg  [31:0] coli;
    wire [3:0]  spu_col, spu_alpha, hl_col, hl_alpha;
    wire        recolour;
    hl_compose hc (
        .idx(idx), .col0(col0), .col1(col1), .col2(col2), .col3(col3),
        .a0(a0), .a1(a1), .a2(a2), .a3(a3), .hl_hit(hl_hit), .coli(coli),
        .spu_col(spu_col), .spu_alpha(spu_alpha), .hl_col(hl_col), .hl_alpha(hl_alpha),
        .recolour(recolour)
    );
    // emu.sv's two muxes, verbatim in shape (sp_sel_col / sp_alpha_q with pic_blank low)
    wire [3:0]  sel_col = recolour ? hl_col   : spu_col;
    wire [3:0]  alpha   = recolour ? hl_alpha : spu_alpha;
    // palette: 7 = black (Y 0x10), 5 = a mid colour, 8 = white, else grey
    wire [7:0] pr = (sel_col == 4'd7) ? 8'd0 : (sel_col == 4'd8) ? 8'd255 :
                    (sel_col == 4'd5) ? 8'd200 : 8'd128;
    wire [7:0] out_r, out_g, out_b;
    subpic_blend sb (
        .in_r(VID), .in_g(VID), .in_b(VID),
        .ov_on(1'b1), .ov_idx(idx), .ov_r(pr), .ov_g(pr), .ov_b(pr),
        .ov_alpha(alpha), .ov_force(recolour),
        .out_r(out_r), .out_g(out_g), .out_b(out_b)
    );

    integer errors = 0;
    task fail(input [639:0] m); begin $display("FAIL: %0s", m); errors = errors + 1; end endtask
    task museum_spu;   // SET_COLOR [7,0,7,0], SET_CONTR [12,0,12,0]  (measured)
        begin col0=7; col1=0; col2=7; col3=0; a0=12; a1=0; a2=12; a3=0; end
    endtask
    task px(input [1:0] c, input h); begin idx = c; hl_hit = h; #1; end endtask

    reg [7:0] outside [0:3];
    integer k;
    initial begin
        // ---------------- the museum, selected coli 0x0507000c ----------------
        museum_spu; coli = 32'h0507000c;
        px(0, 0);
        if (out_r >= VID) fail("[S1] museum background outside the rect is not dimmed");
        else $display("   [S1] background outside: %0d (video %0d) dimmed  ok", out_r, VID);
        px(2, 0);
        if (out_r >= VID) fail("[S2] museum exhibit outside the rect is not dimmed");
        else $display("   [S2] exhibit outside:    %0d dimmed  ok", out_r);
        px(2, 1);
        if (out_r != VID) fail("[S3] the selected exhibit is not LIT (flashlight drew dark)");
        else $display("   [S3] exhibit INSIDE the rect: %0d = video, lit  ok", out_r);
        px(0, 1);
        if (out_r >= VID) fail("[S4] museum background inside the rect is not dimmed");
        else $display("   [S4] background inside:  %0d dimmed  ok", out_r);

        // ---------------- T2: an all-zero-contrast coli is a hotspot ----------
        col0=0; col1=6; col2=9; col3=4; a0=0; a1=15; a2=8; a3=4; coli = 32'h44440000;
        for (k = 0; k < 4; k = k + 1) begin px(k[1:0], 0); outside[k] = out_r; end
        for (k = 0; k < 4; k = k + 1) begin
            px(k[1:0], 1);
            if (out_r != outside[k]) begin
                $display("   [T1] class %0d: inside %0d, outside %0d", k, out_r, outside[k]);
                fail("[T1] a hotspot coli changed the subpicture inside the rect (T2)");
            end
        end
        $display("   [T1] T2 hotspot coli 44440000: subpicture unchanged inside the rect  ok");

        // ---------------- a recolouring coli (the Matrix/MiB shape) -----------
        col0=0; col1=0; col2=0; col3=0; a0=0; a1=0; a2=0; a3=0; coli = 32'h008000f0;
        px(1, 1);   // class 1 -> colour 8 (white) at contrast 15
        if (out_r != 8'd255) fail("[R1] the recoloured class did not take the HLI colour + contrast");
        else $display("   [R1] recoloured class drawn white, opaque  ok");

        // ---------------- a subtitle: background contrast 0 draws no box -----
        col0=0; col1=8; col2=7; col3=7; a0=0; a1=15; a2=15; a3=15; coli = 32'h0;
        px(0, 0);
        if (out_r != VID) fail("[U1] a subtitle background with contrast 0 drew a box");
        else $display("   [U1] subtitle background contrast 0: no box  ok");

        if (errors == 0) $display("RESULT: PASS");
        else begin $display("RESULT: FAIL (%0d)", errors); $fatal(1, "flashlight_tb failed"); end
        $finish;
    end
endmodule
`default_nettype wire
