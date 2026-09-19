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
// from the SPU's SET_CONTR (0 = transparent, 15 = opaque) -- and that is the ONLY thing
// that decides transparency. This keeps the block a tiny combinational compositor with
// no palette knowledge.
//
// ⛔ THERE IS NO idx-0 TRANSPARENT KEY ANY MORE (2026-09-18). It was a Phase-1 relic from
// before SET_CONTR and the PGC palette were parsed ("idx0 transparent / idx1 white"), and
// the DVD spec has no such rule: class 0 is drawn with its contrast like any other.
// MEASURED over 1215 discs / 16124 SPUs: 11 discs give class 0 a nonzero contrast, and in
// the ones inspected it was DOING something -- Last Ounce of Courage and Die Another Day
// put visible pixels in class 0 (contrast 15, background on class 3; on HW Die Another
// Day looked right on v0.6.1 too, so that cost is unconfirmed); Scooby-Doo 2's museum
// dims the whole screen
// with class 0 at contrast 12 (the "flashlight" darkness). Silent Steel 2 authors a
// full-screen class 0 at contrast 3 and now shows that tint, as a real player does.

`default_nettype none

module subpic_blend (
    // Underlying video pixel (this cycle)
    input  wire [7:0] in_r,
    input  wire [7:0] in_g,
    input  wire [7:0] in_b,

    // Overlay pixel, already aligned to in_* by the caller
    input  wire       ov_on,       // this pixel lies inside a visible overlay region
    input  wire [1:0] ov_idx,      // 2-bpp colour index (0..3); informational only
    input  wire [7:0] ov_r,        // overlay colour (already looked up from the palette)
    input  wire [7:0] ov_g,
    input  wire [7:0] ov_b,
    input  wire [3:0] ov_alpha,    // 0 = transparent .. 15 = opaque (SET_CONTR)
    // ⚠ INERT since the idx-0 key was removed (2026-09-18): it only ever bypassed that
    // key. Kept so emu's register stage and tools/check_saver_overlay_wiring.py (which
    // pins sp_force_q's gating) need no churn; it MUST NOT be read as "force it on" --
    // ov_on low is passthrough whatever it says (subpic_blend_tb pins that corner).
    input  wire       ov_force,

    output wire [7:0] out_r,
    output wire [7:0] out_g,
    output wire [7:0] out_b
);
    // alpha 0 is transparent; ov_off is passthrough. Nothing else.
    wire blend = ov_on && (ov_alpha != 4'd0);

    // Blend weight: alpha/16, but map 15 -> 16 so full contrast is fully opaque
    // (out = ov exactly). weight in [0..16].
    wire [4:0] w = (ov_alpha == 4'hF) ? 5'd16 : {1'b0, ov_alpha};

    // out = (c*wt + in*(16-wt)) / 16   (unsigned linear interp; wt in [0..16], so the
    // sum never exceeds max(c,in)*16 = 4080 -> fits 13 bits, >>4 back to 8 bits).
    // Computed as in*16 + wt*(c - in), which is the same integer (expand the
    // product), so ONE multiply per channel instead of two -- area pass
    // 2026-09-10.  (c - in) is a signed 9-bit difference; the sum is provably
    // in [0, 4080] because it equals the original non-negative expression.
    // c/wt are explicit args so the continuous assigns below stay sensitive to them.
    function automatic [7:0] mix(input [7:0] v_in, input [7:0] c, input [4:0] wt);
        logic signed [9:0]  d;
        logic signed [15:0] prod;
        logic signed [13:0] acc;
        begin
            d    = $signed({2'b00, c}) - $signed({2'b00, v_in});   // -255..255
            prod = d * $signed({1'b0, wt});                          // x 0..16
            acc  = $signed({1'b0, v_in, 4'b0000}) + prod;            // in*16 + wt*(c-in)
            mix  = acc[11:4];
        end
    endfunction

    assign out_r = blend ? mix(in_r, ov_r, w) : in_r;
    assign out_g = blend ? mix(in_g, ov_g, w) : in_g;
    assign out_b = blend ? mix(in_b, ov_b, w) : in_b;

endmodule

`default_nettype wire
