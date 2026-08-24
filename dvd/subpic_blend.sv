// subpic_blend.sv — reusable RGB alpha compositor for the DVD overlay layer
// Part of MiSTer DVD Player Core
//
// Alpha-composites a 2-bpp (4-colour) overlay pixel over the underlying video
// pixel. This is the LOAD-BEARING reusable block: DVD subtitles use it now; the
// transport UI popups and (later) disc-menu highlights reuse it by supplying
// their own {ov_on, ov_idx, ov_alpha}. It is purely combinational and holds no
// memory or timing state — the caller aligns ov_* to in_* (same pixel).
//
// Overlay colour (see docs/subpicture.md): the caller supplies the already-resolved
// 24-bit RGB for this pixel (ov_r/g/b) — for DVD subtitles/menus that is the SET_COLOR
// palette index looked up in the PGC palette (dvd/pgc_palette.sv). Per-index alpha comes
// from the SPU's SET_CONTR (0 = transparent, 15 = opaque). idx 0 stays the transparent
// key. This keeps the block a tiny combinational compositor with no palette knowledge.

`default_nettype none

module subpic_blend (
    // Underlying video pixel (this cycle)
    input  wire [7:0] in_r,
    input  wire [7:0] in_g,
    input  wire [7:0] in_b,

    // Overlay pixel, already aligned to in_* by the caller
    input  wire       ov_on,       // this pixel lies inside a visible overlay region
    input  wire [1:0] ov_idx,      // 2-bpp colour index (0..3); idx0 = transparent key
    input  wire [7:0] ov_r,        // overlay colour (already looked up from the palette)
    input  wire [7:0] ov_g,
    input  wire [7:0] ov_b,
    input  wire [3:0] ov_alpha,    // 0 = transparent .. 15 = opaque (SET_CONTR)
    // Highlight override: when high, blend on alpha alone and DO NOT force idx 0
    // transparent. A DVD button-highlight coli recolours all four subpicture classes
    // including the BACKGROUND class (idx 0); with the idx0-key that fill can never
    // show. The idx0 key stays correct for subtitles (ov_force low). See docs/subpicture.md.
    input  wire       ov_force,

    output wire [7:0] out_r,
    output wire [7:0] out_g,
    output wire [7:0] out_b
);
    // idx0 is transparent by convention (subtitles); alpha 0 is transparent; ov_off is
    // passthrough. ov_force (menu highlight) blends on alpha alone, keeping the idx0 fill.
    wire blend = ov_on && (ov_alpha != 4'd0) && (ov_force || (ov_idx != 2'd0));

    // Blend weight: alpha/16, but map 15 -> 16 so full contrast is fully opaque
    // (out = ov exactly). weight in [0..16].
    wire [4:0] w = (ov_alpha == 4'hF) ? 5'd16 : {1'b0, ov_alpha};

    // out = (c*wt + in*(16-wt)) / 16   (unsigned linear interp; wt in [0..16], so the
    // sum never exceeds max(c,in)*16 = 4080 -> fits 13 bits, >>4 back to 8 bits).
    // c/wt are explicit args so the continuous assigns below stay sensitive to them.
    function automatic [7:0] mix(input [7:0] v_in, input [7:0] c, input [4:0] wt);
        logic [12:0] acc;
        begin
            acc = c * wt + v_in * (5'd16 - wt);
            mix = acc[11:4];
        end
    endfunction

    assign out_r = blend ? mix(in_r, ov_r, w) : in_r;
    assign out_g = blend ? mix(in_g, ov_g, w) : in_g;
    assign out_b = blend ? mix(in_b, ov_b, w) : in_b;

endmodule

`default_nettype wire
