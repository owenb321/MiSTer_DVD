// hl_compose.sv -- which palette index and contrast a subpicture pixel is drawn
// with: the SPU's own (SET_COLOR / SET_CONTR), or the menu highlight's (HLI
// btn_coli) inside the selected button's rectangle.
//
// Extracted from dvd/emu.sv 2026-09-18 so it has a bench (emu.sv has none).
// Purely combinational: no register stage, so the display hotspot's timing is
// exactly what the inline expressions produced.
//
// ★ THE RULE (2026-09-18, Scooby-Doo 2 museum "flashlight"; docs/subpicture.md
// "Highlight colours replace every class").
//   Inside the rect, a LIVE coli (any contrast nibble nonzero) replaces the
//   colour AND contrast of ALL FOUR pixel classes -- including contrast 0,
//   which makes that class TRANSPARENT inside the rect. That is the DVD spec,
//   and what VLC's dvdnav ButtonUpdate does (each contrast nibble becomes the
//   class's alpha, zero included).
//   MEASURED on the disc that needed it: the museum screen's SPU dims the WHOLE
//   screen (class 0 and the exhibit circles, class 2, both black at contrast 12)
//   and the selected colour 0507000c keeps class 0 black at 12 while giving
//   class 2 contrast 0 -- the exhibit is cut out of the darkness. The rule this
//   replaces ("a contrast-0 class keeps its SUBPICTURE pixel") drew the circle
//   black inside the rect: a dark square where the flashlight should be.
//
// ⚠ AN ALL-ZERO coli IS A HOTSPOT, NOT A RECOLOUR -- a deliberate deviation.
//   T2's VTS_01 root menu authors its buttons with coli 0x44440000 (all four
//   contrasts zero) and draws the selected state in the subpicture itself; the
//   HW-confirmed look (docs/dvd_menu_refinements.md §1, PR fj#83) keeps the
//   subpicture pixel there. A spec renderer would erase it inside the hotspot.
//   Keyed on the WHOLE coli being zero-contrast, so no disc that uses a coli to
//   recolour is affected by the exception.
`default_nettype none
module hl_compose (
    input  wire [1:0]  idx,           // the pixel's class (spu_decode.q_idx)
    input  wire [3:0]  col0, col1, col2, col3,   // SPU SET_COLOR palette indices
    input  wire [3:0]  a0, a1, a2, a3,           // SPU SET_CONTR contrasts
    input  wire        hl_hit,        // this pixel is inside the selected button rect
    input  wire [31:0] coli,          // [Ci3..Ci0 | A3..A0]
    // The per-class candidates. emu.sv keeps the final 2-way muxes itself
    // (`hl_use ? hl_col : spu_col`, `hl_use_e ? hl_alpha : spu_alpha`) because
    // tools/check_saver_overlay_wiring.py pins those shapes -- the screensaver
    // gate (pic_blank) lives on the ALPHA mux and must not reach the palette
    // ADDRESS. The rule this module owns is `recolour`.
    output wire [3:0]  spu_col,       // the subpicture's own palette index
    output wire [3:0]  spu_alpha,     // ...and contrast
    output wire [3:0]  hl_col,        // the highlight's palette index for this class
    output wire [3:0]  hl_alpha,      // ...and contrast (0 = transparent inside the rect)
    output wire        recolour       // the highlight owns this pixel
);
    assign spu_col   = (idx == 2'd0) ? col0 : (idx == 2'd1) ? col1 :
                       (idx == 2'd2) ? col2 : col3;
    assign spu_alpha = (idx == 2'd0) ? a0   : (idx == 2'd1) ? a1   :
                       (idx == 2'd2) ? a2   : a3;
    assign hl_col    = (idx == 2'd0) ? coli[19:16] : (idx == 2'd1) ? coli[23:20] :
                       (idx == 2'd2) ? coli[27:24] : coli[31:28];
    assign hl_alpha  = (idx == 2'd0) ? coli[3:0]   : (idx == 2'd1) ? coli[7:4]   :
                       (idx == 2'd2) ? coli[11:8]  : coli[15:12];

    wire coli_live = |coli[15:0];     // any contrast nonzero: a real recolour

    assign recolour = hl_hit && coli_live;
endmodule
`default_nettype wire
