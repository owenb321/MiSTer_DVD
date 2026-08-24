/*
 * crt_ov_map.sv — DVD-FORK (CRT anamorphic overlay alignment)
 *
 * Inverse raster→source coordinate mapper for the subpicture / HLI-highlight overlay
 * layer under the CRT anamorphic display modes (O[4:3] Letterbox / Crop).
 *
 * WHY: the subpicture bitmap query (spu_decode.q_x/q_y) and the menu-highlight button
 * rect compare both run in RASTER coordinates at the display tap in emu.sv — but the
 * CRT Letterbox/Crop modes rescale the VIDEO upstream of that tap (dvd/disp_vscale.sv
 * vertical 3/4 + mixer bars; dvd/disp_hstretch.sv horizontal 528→720 stretch of the
 * addrgen's centre-crop). On HDMI the blend happens before ascal so overlay and video
 * scale together; on the CRT they didn't — subtitles and menu highlights landed offset
 * from the picture. This module maps the raster position BACK to the source pixel the
 * video path is showing there, so the overlay layer queries source space and stays
 * glued to the picture in all three CRT aspect modes.
 *
 * EXACTNESS: both inverse walks replicate the forward scalers' Bresenham decisions
 * step-for-step (see the co-sim testbench bench/dvd/crt_ov_map_tb.sv, which drives the
 * REAL disp_hstretch with a source-index-tagged line and checks this inverse against
 * it column-for-column):
 *   - Letterbox (vertical): disp_vscale emits output line i from source base k_i with
 *     weight f_i = r_i/3, k advancing 0,1,2,4,5,6,8,… (k+=2 when r wraps). The inverse
 *     tracks (k,r) per displayed line and reports the NEAREST tap k + (r==2), i.e.
 *     round(i*4/3). Content sits between the mixer bars (disp_v_offset = v_bar); bar
 *     lines map to 0xFFF (outside any DAREA / button rect → overlay hidden).
 *     Field path (CRT 480i): core_v_pos is the absolute frame line stepping by 2 within
 *     a field; each field re-arms at v_bar/v_bar+1 (disp_vscale re-arms per field top),
 *     so the walk is per-field in field-line units scaled ×2, parity preserved.
 *   - Crop (horizontal): disp_hstretch is a 2-TAP resampler — display column j shows
 *     src[k]*(1-f) + src[k+1]*f with k + f = j*hsrc/hdst, and its weight is FLOORed to
 *     Q0.8 (f8 = floor(256*f)) precisely so that floor(256*f) >= 128 <=> f >= 1/2. The
 *     NEAREST tap it displays at column j is therefore exactly
 *         k + (f8 >= 128)  ==  floor((j*hsrc + hdst/2)/hdst)
 *     which this inverse reproduces with a plain ROUNDING Bresenham (seed the error term
 *     at hdst/2, add hsrc per display column, advance the source column on each wrap) —
 *     no divider, no approximation. Output = hcrop_x0 + column (the addrgen crop window
 *     origin), clamped at the window's last column (a blanking guard; inside the active
 *     line the walk lands on hsrc-1 exactly at the last column).
 *   - SIF fill (DVD-FORK FIX 2026-08-24): the horizontal 352->720 stretch reuses the SAME
 *     crop inverse with hcrop_x0=0 / hsrc=352 / hextra=368 (the identity above holds at
 *     any upscale ratio). The vertical 2x line repeat (addrgen vscale_mode==2, v_step=128)
 *     is inverted by a closed-form post-map on the letterbox mux's candidate:
 *     progressive y -> min(floor((y+1)/2), v_src_max); interlaced field line i parity p ->
 *     min(p + 2*floor((i+1)/2), v_src_max) — exactly the forward walk's rounded map,
 *     0xFFF bar sentinel preserved. See the v2x_en port comment.
 *
 * TIMING: mapped outputs register one clk_sys after a position change. Vertical changes
 * at line rate (irrelevant); horizontal means the mapped x lags the raw query by one
 * clk_sys = HALF a CRT pixel (13.5 MHz CE, 2 clk_sys per pixel — Crop is CRT-only), a
 * sub-pixel shift absorbed by the SP_QX_ADJ calibration.
 *
 * PASS-THROUGH: with letterbox_en/crop_en low the outputs are combinational copies of
 * the inputs — bit-identical to the pre-mapper wiring (HDMI and CRT-Fit unaffected).
 */

`include "timescale.v"

module crt_ov_map (
    input  wire        clk,            // clk_sys
    input  wire        rst_n,

    input  wire        letterbox_en,   // CRT Letterbox active (disp_vscale_en)
    input  wire        crop_en,        // CRT Crop OR SIF fill active (analog_crop | sif_hfill_eff)
    input  wire        interlaced,     // CRT 480i: v_pos = absolute frame line, +2 per field line

    /* DVD-FORK FIX (SIF analog fill): invert the addrgen 2x line repeat (vscale_mode==2).
     * The forward walk (resample_addrgen, v_step=128, rounded) maps output line i to
     * source line min(floor((i+1)/2), v_src_max) on the progressive path; on the
     * interlaced (Native Fields) path each field walks its own parity:
     * field line i, parity p -> min(p + 2*floor((i+1)/2), v_src_max). This stage
     * post-maps the letterbox mux's candidate (letterbox output is a line in DOUBLED
     * space — the 2x repeat happens upstream of disp_vscale — so the two inverses
     * compose in that order), preserving the 0xFFF bar/blanking sentinel. */
    input  wire        v2x_en,         // SIF vertical 2x active (sif_v2x_eff)
    input  wire [11:0] v_src_max,      // decoded vertical_size - 1 (239/287): the forward walk's clamp

    /* letterbox geometry (quasi-static): mixer bar offset + content band, frame lines */
    input  wire [11:0] v_bar,          // disp_v_offset (60 NTSC / 72 PAL)
    input  wire [11:0] v_band,         // letterboxed content height (360 NTSC / 432 PAL)

    /* crop geometry (quasi-static, from the decoder's mb_width — same formula as
     * resample_addrgen/disp_hstretch): window origin, width, and stretch surplus */
    input  wire [11:0] hcrop_x0,       // hcrop_mb*16 (96 for 720-wide)
    input  wire [11:0] hsrc_w,         // cropped line width (528 for 720-wide)
    input  wire [11:0] hextra,         // hdst - hsrc (192 for 720-wide)

    /* raster-space query position (x already SP_QX_ADJ lead-compensated) */
    input  wire [11:0] h_pos_in,
    input  wire [11:0] v_pos_in,

    /* source-space query position for spu_decode / the HLI rect compare */
    output wire [11:0] q_x_out,
    output wire [11:0] q_y_out
);

    /* ---------------- vertical: inverse letterbox (per displayed line) ---------------- */
    wire [11:0] vstep = interlaced ? 12'd2 : 12'd1;

    reg  [11:0] v_q;        // last seen v_pos (change detector)
    reg  [11:0] ly;         // Bresenham base line k (absolute source frame line)
    reg  [1:0]  lr;         // Bresenham remainder 0..2 (blend weight numerator)
    reg         ly_valid;   // inside the content band with a valid walk

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_q <= 12'hFFF; ly <= 12'd0; lr <= 2'd0; ly_valid <= 1'b0;
        end else begin
            v_q <= v_pos_in;
            if (v_pos_in != v_q) begin
                if ((v_pos_in == v_bar) || (interlaced && (v_pos_in == v_bar + 12'd1))) begin
                    /* band start (per-field in 480i: each parity re-arms at its first line) */
                    ly       <= v_pos_in - v_bar;   // source line 0 (or 1 = odd field)
                    lr       <= 2'd0;
                    ly_valid <= 1'b1;
                end else if (ly_valid && (v_pos_in == v_q + vstep) &&
                             ((v_pos_in - v_bar) < v_band)) begin
                    /* next line of the same scan: advance (k,r) as disp_vscale does */
                    if (lr == 2'd2) begin lr <= 2'd0; ly <= ly + (vstep << 1); end
                    else            begin lr <= lr + 2'd1; ly <= ly + vstep;   end
                end else begin
                    /* left the band (bottom bar / blanking / field jump): invalidate until
                     * the next band start so a stale walk can never be queried */
                    ly_valid <= 1'b0;
                end
            end
        end
    end

    /* nearest tap: k when f∈{0,1/3}, k+1 when f=2/3 */
    wire [11:0] ly_eff = ly + ((lr == 2'd2) ? vstep : 12'd0);

    /* ---------------- horizontal: inverse crop resample (per displayed column) ----------------
     * Rounding Bresenham: cx after j columns = floor((j*hsrc_w + hdst_w/2)/hdst_w) = the
     * nearest source tap disp_hstretch shows at column j (see the header). hdst_w is derived
     * here rather than added as a port, so emu.sv's geometry wiring is unchanged. */
    wire [12:0] hdst_w = {1'b0, hsrc_w} + {1'b0, hextra};    // 720 for the 528+192 case

    reg  [11:0] h_q;        // last seen h_pos (change detector)
    reg  [11:0] cx;         // source column (0-based inside the crop window)
    reg  [12:0] cacc;       // rounding Bresenham error term (units of display columns)

    wire [12:0] cacc_plus = cacc + {1'b0, hsrc_w};
    wire        cstep     = (cacc_plus >= hdst_w);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_q <= 12'hFFF; cx <= 12'd0; cacc <= 13'd0;
        end else begin
            h_q <= h_pos_in;
            if (h_pos_in != h_q) begin
                if (h_pos_in == 12'd0) begin
                    /* line start: column 0 shows source column 0; seed the error term at
                     * half a display column so the walk rounds rather than truncates */
                    cx <= 12'd0; cacc <= {1'b0, hdst_w[12:1]};
                end else begin
                    cacc <= cstep ? (cacc_plus - hdst_w) : cacc_plus;
                    /* clamp at the window's last column (blanking / right-edge guard; the
                     * active line lands on hsrc_w-1 exactly at the last display column) */
                    if (cstep && ((cx + 12'd1) < hsrc_w)) cx <= cx + 12'd1;
                end
            end
        end
    end

    /* ---------------- output mux (pure pass-through when inactive) ---------------- */
    wire [11:0] q_y_pre = letterbox_en ? (ly_valid ? ly_eff : 12'hFFF) : v_pos_in;

    /* DVD-FORK FIX (SIF analog fill): post-map the vertical candidate through the exact
     * inverse of the addrgen 2x line-repeat walk (see the v2x_en port comment). The
     * 0xFFF letterbox-bar sentinel passes through untouched (it must stay outside every
     * DAREA / button rect). Combinational — v changes at line rate. */
    wire [11:0] v2x_i    = {1'b0, q_y_pre[11:1]};                    // field-line index i (interlaced)
    wire [11:0] v2x_prog = (q_y_pre + 12'd1) >> 1;                   // floor((y+1)/2)
    wire [11:0] v2x_half = (v2x_i + 12'd1) >> 1;                     // floor((i+1)/2)
    wire [11:0] v2x_il   = {11'd0, q_y_pre[0]} + {v2x_half[10:0], 1'b0}; // p + 2*floor((i+1)/2)
    wire [11:0] v2x_raw  = interlaced ? v2x_il : v2x_prog;
    wire [11:0] v2x_clmp = (v2x_raw > v_src_max) ? v_src_max : v2x_raw;
    wire [11:0] q_y_v2x  = (q_y_pre == 12'hFFF) ? 12'hFFF : v2x_clmp;

    assign q_y_out = v2x_en ? q_y_v2x : q_y_pre;
    assign q_x_out = crop_en ? (hcrop_x0 + cx) : h_pos_in;

endmodule
/* not truncated */
