/*
 * crt_ov_map_tb.sv — CRT anamorphic overlay inverse-mapper verification
 *
 * Proves dvd/crt_ov_map.sv inverts the CRT Letterbox/Crop video scalers exactly:
 *
 *   T1a Crop co-sim at a SMALL geometry (128 -> 192): drive the REAL dvd/disp_hstretch.sv
 *       with a line tagged y = source column. disp_hstretch is a 2-tap blender, so a tag
 *       that WRAPS (the old {u,y} = index scheme at 528 px) would decode to garbage — but
 *       an AFFINE tag collapses the blend exactly: with b-a = 1,
 *         out = a + ((1*f8 + 128) >> 8) = k + (f8 >= 128) = the NEAREST tap.
 *       So the recorded forward stream IS the tap sequence, and the inverse mapper is
 *       required to reproduce it column for column. Two lines prove the per-line restart.
 *   T1b Crop at the real 528 -> 720 geometry, closed form: the forward stream must be
 *       EXACTLY hdst pixels with ROW_0_COL_0 first, ROW_X_COL_LAST last and no interior
 *       line-boundary codes (the old duplicating stage emitted hdst-1); the inverse must
 *       equal round(j*hsrc/hdst), be monotone, and hit 0 and hsrc-1 at the ends.
 *   T1c Crop blend proof: a period-2 square wave source (20/220) must produce outputs
 *       STRICTLY BETWEEN the two levels on ~14/15 of the line. Nearest-neighbour
 *       duplication can only ever emit the two levels themselves, so this fails loudly
 *       if disp_hstretch ever regresses to replication.
 *   T2  Letterbox forward co-sim: drive the REAL dvd/disp_vscale.sv (field path) with
 *       source lines tagged y = 3*j, and check output line i decodes to 3*k_i + r_i of
 *       the closed form k_i = i + i/3, r_i = i mod 3 (the blend of 3k and 3k+3 with
 *       f = r/3 lands exactly on 3k + r). This pins the forward walk to the closed form.
 *   T3  Letterbox inverse vs the same closed form: walk the mapper through two full
 *       480i fields (bars, band, blanking) and a progressive frame; in-band lines must
 *       map to the nearest-tap source line 2*(k_j + (r_j==2)) + parity (field) /
 *       k_j + (r_j==2) (progressive), bar/blank lines to 0xFFF. A second frame re-run
 *       proves the per-field re-arm.
 *   T1d SIF fill (DVD-FORK FIX 2026-08-24): the same crop inverse at the SIF-fill
 *       geometries 352 -> 720 (x0=0) and 256 -> 720 (Crop+SIF, x0=48). Forward geometry
 *       (exactly hdst px, clean codes) + closed-form inverse with the right-edge clamp
 *       (cr_near hits hsrc at the very last column at these ratios; both the forward
 *       stage and the inverse clamp to hsrc-1). The T1a affine-tag exact co-sim is
 *       ratio-independent and the 8-bit tag wraps at 352 sources, so the value check
 *       here is the closed form.
 *   T4  Pass-through: both enables low => q_x_out/q_y_out combinationally equal the
 *       inputs (bit-identical wiring for HDMI / CRT-Fit).
 *   T5  spu_decode row-base adder under the mapped walks: the letterbox inverse map
 *       makes q_y SKIP every 4th source line (steps +1/+2 progressive, +2/+4 field) —
 *       the generalized q_row_base per-line adder must still land q_idx on
 *       bmp[q_y*STRIDE + q_x]. Drives a REAL spu_decode (bitmap seeded hierarchically)
 *       with both mapped sequences plus the plain +1/+2 raster walks (regression) and
 *       compares every read against the golden array.
 *   T6  SIF vertical 2x inverse (DVD-FORK FIX 2026-08-24): the v2x_en post-map vs a
 *       behavioral model of the addrgen mode-2 walk (v_step=128, rounded):
 *       progressive y -> min(floor((y+1)/2), v_src_max); interlaced field line i,
 *       parity p -> min(p + 2*floor((i+1)/2), v_src_max). Four walks: progressive,
 *       480i both fields, letterbox+v2x compose (progressive + 480i) with the 0xFFF
 *       bar sentinel preserved.
 *
 * Build:
 *   iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/crt_ov_map_sim \
 *     dvd/crt_ov_map.sv dvd/disp_hstretch.sv dvd/disp_vscale.sv \
 *     dvd/spu_decode.sv rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v rtl/mpeg2/xfifo_sc.v \
 *     rtl/mpeg2/xilinx_fifo_dc.v bench/dvd/crt_ov_map_tb.sv
 *   vvp bench/dvd/crt_ov_map_sim
 */

`timescale 1ns/100ps

module crt_ov_map_tb;

`include "resample_codes.v"

    localparam VBAR = 60, VBAND = 360;
    // sized copies for port hookup / 12-bit compares (avoid N'(expr) signed-cast
    // pitfalls: a size cast of a signed integer yields a signed value that
    // sign-extends in !== compares — 12'(4095) reads back as -1)
    localparam [11:0] P_VBAR = VBAR, P_VBAND = VBAND;

    // Crop geometry is RECONFIGURED between T1a (small, exact-tag) and T1b/T1c (the real
    // 528->720), so these are regs, not localparams; set_geom() pulses rst_n so both the
    // stretcher's phase divider and the mapper's walk re-arm on the new numbers.
    reg [11:0] P_HSRC = 12'd528, P_HDST = 12'd720, P_HX0 = 12'd96, P_HEXTRA = 12'd192;
    integer    HSRC = 528, HDST = 720, HX0 = 96;
    localparam FWD_CAP = 1024;         // forward-capture depth (>= any hdst used here)

    reg clk = 0;
    always #5 clk = ~clk;

    integer errors = 0;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    reg         rst_n = 0;
    reg         letterbox_en = 0, crop_en = 0, interlaced = 0;
    reg         v2x_en = 0;                    // DVD-FORK FIX (SIF analog fill)
    reg  [11:0] v_src_max = 12'd479;           // decoded vertical_size - 1
    reg  [11:0] h_pos_in = 12'hFFF, v_pos_in = 12'hFFF;
    wire [11:0] q_x_out, q_y_out;

    crt_ov_map dut (
        .clk(clk), .rst_n(rst_n),
        .letterbox_en(letterbox_en), .crop_en(crop_en), .interlaced(interlaced),
        .v2x_en(v2x_en), .v_src_max(v_src_max),
        .v_bar(P_VBAR), .v_band(P_VBAND),
        .hcrop_x0(P_HX0), .hsrc_w(P_HSRC), .hextra(P_HEXTRA),
        .h_pos_in(h_pos_in), .v_pos_in(v_pos_in),
        .q_x_out(q_x_out), .q_y_out(q_y_out)
    );

    // ------------------------------------------------------------------
    // Forward reference 1: the real Crop stretcher
    // ------------------------------------------------------------------
    reg         hs_in_wr = 0;
    reg  [7:0]  hs_in_y = 0, hs_in_u = 0;
    reg  [2:0]  hs_in_pos = 0;
    wire [7:0]  hs_out_y, hs_out_u;
    wire [2:0]  hs_out_pos;
    wire        hs_out_wr, hs_in_af;

    disp_hstretch hstretch (
        .clk(clk), .clk_en(1'b1), .rst(rst_n),
        .hcrop_en(1'b1),
        .hsrc_width(P_HSRC), .hdst_width(P_HDST),
        .in_y(hs_in_y), .in_u(hs_in_u), .in_v(8'd0), .in_osd(8'd0),
        .in_pos(hs_in_pos), .in_wr(hs_in_wr), .in_almost_full(hs_in_af),
        .out_y(hs_out_y), .out_u(hs_out_u), .out_v(), .out_osd(),
        .out_pos(hs_out_pos), .out_wr(hs_out_wr), .out_almost_full(1'b0)
    );

    // capture the forward stream: the luma tag and the position code of each display column
    integer fwd_n = 0;
    integer fwd_map [0:FWD_CAP-1];
    integer fwd_pos [0:FWD_CAP-1];
    always @(posedge clk)
        if (hs_out_wr && fwd_n < FWD_CAP) begin
            fwd_map[fwd_n] = hs_out_y;
            fwd_pos[fwd_n] = hs_out_pos;
            fwd_n = fwd_n + 1;
        end

    // ------------------------------------------------------------------
    // Forward reference 2: the real Letterbox blender (field path, tagged lines)
    // ------------------------------------------------------------------
    localparam VS_LINES = 84;          // source field lines fed (tags 3*j stay < 256)
    localparam VS_WIDTH = 8;
    reg         vs_in_wr = 0;
    reg  [7:0]  vs_in_y = 0;
    reg  [2:0]  vs_in_pos = 0;
    wire [7:0]  vs_out_y;
    wire [2:0]  vs_out_pos;
    wire        vs_out_wr, vs_in_af;

    disp_vscale vscale (
        .clk(clk), .clk_en(1'b1), .rst(rst_n),
        .vscale_en(1'b1),
        .in_y(vs_in_y), .in_u(8'd0), .in_v(8'd0), .in_osd(8'd0),
        .in_pos(vs_in_pos), .in_wr(vs_in_wr), .in_almost_full(vs_in_af),
        .out_y(vs_out_y), .out_u(), .out_v(), .out_osd(),
        .out_pos(vs_out_pos), .out_wr(vs_out_wr), .out_almost_full(1'b0)
    );

    integer vs_line = -1;              // output line index (col0 increments)
    integer vs_tag [0:255];
    always @(posedge clk)
        if (vs_out_wr) begin
            if (vs_out_pos == ROW_0_COL_0 || vs_out_pos == ROW_1_COL_0 || vs_out_pos == ROW_X_COL_0)
                vs_line = vs_line + 1;
            vs_tag[vs_line] = vs_out_y;
        end

    // ------------------------------------------------------------------
    // spu_decode under test for the T5 row-base adder walks. Only the display
    // query path is exercised: the bitmap is seeded hierarchically and q_idx
    // (= the raw bmp read, independent of SPU/commit state) is compared.
    // ------------------------------------------------------------------
    localparam SP_STRIDE = 720;
    reg         sp_interlaced = 0;
    reg  [11:0] sp_q_x = 0, sp_q_y = 12'hFFF;
    wire [1:0]  sp_q_idx;

    spu_decode #(.BMP_N(414720), .STRIDE(SP_STRIDE)) spu (
        .clk(clk), .rst_n(rst_n), .enable(1'b0), .menu_mode(1'b0),
        .interlaced(sp_interlaced),
        .sp_byte(8'd0), .sp_valid(1'b0), .sp_frame_start(1'b0),
        .sp_pts(33'd0), .sp_pts_valid(1'b0), .stc(33'd0),
        .q_x(sp_q_x), .q_y(sp_q_y),
        .q_idx(sp_q_idx), .q_inside(),
        .alpha0(), .alpha1(), .alpha2(), .alpha3(),
        .col0(), .col1(), .col2(), .col3(),
        .sp_active()
    );

    // golden pixel: deterministic 2-bit function of the bitmap address
    function automatic [1:0] gold_px(input integer addr);
        gold_px = (addr[1:0] ^ addr[9:8] ^ addr[17:16]);
    endfunction

    // one mapped "line": settle q_y, then sample a few columns
    task automatic t5_line(input [11:0] y);
        integer x;
        begin
            @(negedge clk) sp_q_y = y;
            repeat (3) @(negedge clk);            // q_row_base settles (1 cycle + margin)
            for (x = 200; x < 206; x = x + 1) begin
                @(negedge clk) sp_q_x = x[11:0];
                @(negedge clk);                    // bmp_rd registers
                @(negedge clk);
                if (sp_q_idx !== gold_px(y * SP_STRIDE + x)) begin
                    errors = errors + 1;
                    if (errors < 80)
                        $display("T5 FAIL: q(%0d,%0d) idx %0d expected %0d",
                                 x, y, sp_q_idx, gold_px(y * SP_STRIDE + x));
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    // walk one display pixel: hold h for 2 clks (CRT 13.5 MHz CE pacing), sample after
    task automatic step_h(input [11:0] h);
        begin
            @(negedge clk) h_pos_in = h;
            @(negedge clk);            // mapper registers the change here
        end
    endtask

    task automatic step_v(input [11:0] v);
        begin
            @(negedge clk) v_pos_in = v;
            repeat (3) @(negedge clk);
        end
    endtask

    // closed-form letterbox walk: output line j -> base k, remainder r
    function automatic integer lb_k(input integer j); lb_k = j + j/3; endfunction
    function automatic integer lb_r(input integer j); lb_r = j % 3;   endfunction

    // closed-form crop walk: the NEAREST source tap disp_hstretch shows at display column j
    // (= its k + (f8 >= 128); see dvd/disp_hstretch.sv's load-bearing contract note)
    function automatic integer cr_near(input integer j);
        cr_near = (j * HSRC + HDST / 2) / HDST;
    endfunction

    // DVD-FORK FIX (SIF analog fill): behavioral model of the addrgen mode-2 2x walk
    // (v_step=128, rounded) — output line y -> the source line it repeats.
    function automatic integer v2x_src(input integer y, input integer il, input integer vmax);
        integer fi, s;
        begin
            if (il) begin fi = y / 2; s = (y % 2) + 2 * ((fi + 1) / 2); end
            else    s = (y + 1) / 2;
            v2x_src = (s > vmax) ? vmax : s;
        end
    endfunction

    // reconfigure the crop geometry; rst_n pulse re-arms the stretcher's phase divider
    task automatic set_geom(input integer s, input integer d, input integer x0);
        begin
            HSRC = s; HDST = d; HX0 = x0;
            P_HSRC = s[11:0]; P_HDST = d[11:0]; P_HX0 = x0[11:0]; P_HEXTRA = (d - s);
            @(negedge clk) rst_n = 0;
            repeat (4) @(negedge clk);
            rst_n = 1;
            repeat (20) @(negedge clk);      // 8-step divider + margin
        end
    endtask

    // feed one source line into the real disp_hstretch. tag: 0 = affine (y = i),
    // 1 = period-2 square wave (the blend proof), then drain the pipeline.
    task automatic send_hs_line(input integer tag);
        integer i;
        begin
            fwd_n = 0;
            for (i = 0; i < HSRC; i = i + 1) begin
                @(negedge clk);
                hs_in_wr = 0;
                while (hs_in_af) @(negedge clk);
                hs_in_y   = tag ? ((i & 1) ? 8'd220 : 8'd20) : i[7:0];
                hs_in_u   = 8'd0;
                hs_in_pos = (i == 0)        ? ROW_0_COL_0 :
                            (i == HSRC - 1) ? ROW_X_COL_LAST : ROW_X_COL_X;
                hs_in_wr  = 1;
            end
            @(negedge clk) hs_in_wr = 0;
            repeat (400) @(negedge clk);      // drain
        end
    endtask

    integer i, j, f, v, expv, got, src, g;
    integer err0;

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (4) @(negedge clk);

        // ==============================================================
        // T1a — Crop co-sim at a small geometry (128 -> 192, MB_WIDTH 12):
        //       the affine tag collapses the 2-tap blend onto the nearest
        //       tap exactly, so this stays an EXACT column-for-column check.
        //       Two lines prove the per-line restart.
        // ==============================================================
        err0 = errors;
        set_geom(128, 192, 32);
        for (j = 0; j < 2; j = j + 1) begin
            send_hs_line(0);

            if (fwd_n !== HDST) begin
                errors = errors + 1;
                $display("T1a FAIL: forward resample emitted %0d px (expected exactly %0d)",
                         fwd_n, HDST);
            end

            crop_en = 1;
            for (i = 0; i < HDST; i = i + 1) begin
                step_h(i[11:0]);
                if (i < fwd_n) expv = HX0 + fwd_map[i];
                else           expv = HX0 + HSRC - 1;          // right-edge clamp
                if (q_x_out !== expv[11:0]) begin
                    errors = errors + 1;
                    if (errors < 20)
                        $display("T1a FAIL line %0d: display x=%0d mapped to %0d, forward shows %0d",
                                 j, i, q_x_out, expv);
                end
                // the forward tap must itself be the closed form
                if (i < fwd_n && fwd_map[i] !== cr_near(i)) begin
                    errors = errors + 1;
                    if (errors < 20)
                        $display("T1a FAIL line %0d: forward tap at x=%0d is %0d, round(j*hsrc/hdst)=%0d",
                                 j, i, fwd_map[i], cr_near(i));
                end
            end
            // inter-line gap (blanking): h walks on past the active width
            for (i = HDST; i < HDST + 40; i = i + 1) step_h(i[11:0]);
            crop_en = 0;
        end
        $display("T1a crop co-sim (128->192, exact): %s", (errors != err0) ? "FAIL" : "PASS");
        err0 = errors;

        // ==============================================================
        // T1b — Crop at the real 528 -> 720: line geometry + closed-form
        //       inverse. fwd_n must be EXACTLY hdst (the duplicating stage
        //       emitted hdst-1; that off-by-one is retired).
        // ==============================================================
        set_geom(528, 720, 96);
        send_hs_line(0);

        if (fwd_n !== HDST) begin
            errors = errors + 1;
            $display("T1b FAIL: forward resample emitted %0d px (expected exactly %0d)", fwd_n, HDST);
        end
        if (fwd_n > 0 && fwd_pos[0] !== ROW_0_COL_0) begin
            errors = errors + 1;
            $display("T1b FAIL: first output pos %0d (expected ROW_0_COL_0)", fwd_pos[0]);
        end
        if (fwd_n > 0 && fwd_pos[fwd_n-1] !== ROW_X_COL_LAST) begin
            errors = errors + 1;
            $display("T1b FAIL: last output pos %0d (expected ROW_X_COL_LAST)", fwd_pos[fwd_n-1]);
        end
        for (i = 1; i < fwd_n - 1; i = i + 1)
            if (fwd_pos[i] === ROW_0_COL_0 || fwd_pos[i] === ROW_1_COL_0 ||
                fwd_pos[i] === ROW_X_COL_0 || fwd_pos[i] === ROW_X_COL_LAST) begin
                errors = errors + 1;
                if (errors < 20)
                    $display("T1b FAIL: interior line-boundary code %0d at x=%0d", fwd_pos[i], i);
            end

        crop_en = 1;
        h_pos_in = 12'hFFF; repeat (4) @(negedge clk);
        src = HX0;      // first mapped column is HX0 + 0 (integer, not -1: q_x_out is unsigned)
        for (i = 0; i < HDST; i = i + 1) begin
            step_h(i[11:0]);
            expv = HX0 + cr_near(i);
            if (q_x_out !== expv[11:0]) begin
                errors = errors + 1;
                if (errors < 20)
                    $display("T1b FAIL: display x=%0d mapped %0d, round form %0d", i, q_x_out, expv);
            end
            if (q_x_out < src) begin                       // monotone non-decreasing
                errors = errors + 1;
                $display("T1b FAIL: mapper went backwards at x=%0d (%0d after %0d)", i, q_x_out, src);
            end
            src = q_x_out;
        end
        if (cr_near(0) !== 0 || cr_near(HDST-1) !== HSRC-1) begin
            errors = errors + 1;
            $display("T1b FAIL: endpoints round(0)=%0d round(%0d)=%0d (expected 0 / %0d)",
                     cr_near(0), HDST-1, cr_near(HDST-1), HSRC-1);
        end
        for (i = HDST; i < HDST + 40; i = i + 1) step_h(i[11:0]);
        crop_en = 0;
        $display("T1b crop closed form (528->720): %s", (errors != err0) ? "FAIL" : "PASS");
        err0 = errors;

        // ==============================================================
        // T1c — blend proof: a period-2 square wave must land STRICTLY
        //       between the two levels on most columns. Nearest-neighbour
        //       duplication scores exactly 0 here.
        // ==============================================================
        send_hs_line(1);
        got = 0;
        for (i = 0; i < fwd_n; i = i + 1)
            if (fwd_map[i] > 20 && fwd_map[i] < 220) got = got + 1;
        $display("T1c blend proof: %0d/%0d columns strictly interpolated (NN would give 0)", got, fwd_n);
        if (got < 600) begin
            errors = errors + 1;
            $display("T1c FAIL: only %0d interpolated columns — disp_hstretch looks like nearest-neighbour", got);
        end
        $display("T1c crop blend proof: %s", (errors != err0) ? "FAIL" : "PASS");
        err0 = errors;

        // ==============================================================
        // T1d — sub-720 fill geometries (DVD-FORK FIX): 352->720 (x0=0),
        //       256->720 (Crop+SIF, x0=48), and the <720 predicate widening
        //       (2026-08-24): 480->720 (SVCD, exact 2:3), 544->720 and
        //       704->720 (DVD sub-D1). Forward geometry + closed-form
        //       inverse with the right-edge clamp (cr_near reaches hsrc at
        //       these ratios; both sides clamp hsrc-1).
        // ==============================================================
        for (g = 0; g < 5; g = g + 1) begin
            case (g)
                0: set_geom(352, 720, 0);       // SIF-only fill
                1: set_geom(256, 720, 48);      // Crop + SIF compose
                2: set_geom(480, 720, 0);       // SVCD 2/3-D1 (exact 2:3)
                3: set_geom(544, 720, 0);       // DVD sub-D1
                default: set_geom(704, 720, 0); // DVD sub-D1
            endcase

            send_hs_line(0);
            if (fwd_n !== HDST) begin
                errors = errors + 1;
                $display("T1d FAIL (g%0d): forward resample emitted %0d px (expected exactly %0d)",
                         g, fwd_n, HDST);
            end
            if (fwd_n > 0 && fwd_pos[0] !== ROW_0_COL_0) begin
                errors = errors + 1;
                $display("T1d FAIL (g%0d): first output pos %0d (expected ROW_0_COL_0)", g, fwd_pos[0]);
            end
            if (fwd_n > 0 && fwd_pos[fwd_n-1] !== ROW_X_COL_LAST) begin
                errors = errors + 1;
                $display("T1d FAIL (g%0d): last output pos %0d (expected ROW_X_COL_LAST)", g, fwd_pos[fwd_n-1]);
            end

            crop_en = 1;
            h_pos_in = 12'hFFF; repeat (4) @(negedge clk);
            src = HX0;
            for (i = 0; i < HDST; i = i + 1) begin
                step_h(i[11:0]);
                expv = cr_near(i);
                if (expv > HSRC - 1) expv = HSRC - 1;   // right-edge clamp (matches the fwd b-tap clamp)
                expv = HX0 + expv;
                if (q_x_out !== expv[11:0]) begin
                    errors = errors + 1;
                    if (errors < 20)
                        $display("T1d FAIL (g%0d): display x=%0d mapped %0d, closed form %0d",
                                 g, i, q_x_out, expv);
                end
                if (q_x_out < src) begin
                    errors = errors + 1;
                    $display("T1d FAIL (g%0d): mapper went backwards at x=%0d (%0d after %0d)",
                             g, i, q_x_out, src);
                end
                src = q_x_out;
            end
            for (i = HDST; i < HDST + 40; i = i + 1) step_h(i[11:0]);
            crop_en = 0;
        end
        $display("T1d sub-720 fill crop inverse (352/256/480/544/704 ->720): %s", (errors != err0) ? "FAIL" : "PASS");
        err0 = errors;

        // restore the T1b geometry so later sections see the classic Crop numbers
        set_geom(528, 720, 96);

        // ==============================================================
        // T2 — Letterbox forward co-sim: disp_vscale output line i carries
        //      tag 3*k_i + r_i (field path)
        // ==============================================================
        vs_line = -1;
        for (j = 0; j < VS_LINES; j = j + 1) begin
            for (i = 0; i < VS_WIDTH; i = i + 1) begin
                @(negedge clk);
                vs_in_wr = 0;
                while (vs_in_af) @(negedge clk);
                vs_in_y   = 3 * j;
                vs_in_pos = (i == 0) ? ((j == 0) ? ROW_0_COL_0 : ROW_X_COL_0) :
                            (i == VS_WIDTH - 1) ? ROW_X_COL_LAST : ROW_X_COL_X;
                vs_in_wr  = 1;
            end
            @(negedge clk) vs_in_wr = 0;
            repeat (30) @(negedge clk);
        end
        repeat (100) @(negedge clk);

        if (vs_line + 1 != (VS_LINES * 3) / 4) begin
            errors = errors + 1;
            $display("T2 FAIL: %0d output lines (expected %0d)", vs_line + 1, (VS_LINES*3)/4);
        end
        for (i = 0; i <= vs_line; i = i + 1) begin
            expv = 3 * lb_k(i) + lb_r(i);
            if (vs_tag[i] !== expv) begin
                errors = errors + 1;
                $display("T2 FAIL: output line %0d tag %0d, closed form %0d", i, vs_tag[i], expv);
            end
        end
        $display("T2 letterbox forward co-sim: %s", (errors != err0) ? "FAIL" : "PASS");
        err0 = errors;

        // ==============================================================
        // T3 — Letterbox inverse vs the closed form: two 480i frames
        //      (bars + band + blanking, both fields), then progressive
        // ==============================================================
        crop_en = 0; letterbox_en = 1; interlaced = 1;
        for (f = 0; f < 4; f = f + 1) begin                 // 2 frames x 2 fields
            for (v = (f % 2); v < 525; v = v + 2) begin     // parity walk incl. bars+blank
                step_v(v[11:0]);
                if (v >= VBAR && v < VBAR + VBAND) begin
                    j    = (v - VBAR) >> 1;                 // field line
                    expv = 2 * (lb_k(j) + ((lb_r(j) == 2) ? 1 : 0)) + (v & 1);
                end else expv = 'hFFF;
                if (q_y_out !== expv[11:0]) begin
                    errors = errors + 1;
                    if (errors < 40)
                        $display("T3 FAIL (480i f%0d): raster v=%0d mapped %0d expected %0d",
                                 f, v, q_y_out, expv);
                end
            end
        end
        interlaced = 0;
        v_pos_in = 12'hFFF; repeat (4) @(negedge clk);
        for (v = 0; v < 525; v = v + 1) begin
            step_v(v[11:0]);
            if (v >= VBAR && v < VBAR + VBAND)
                expv = lb_k(v - VBAR) + ((lb_r(v - VBAR) == 2) ? 1 : 0);
            else expv = 'hFFF;
            if (q_y_out !== expv[11:0]) begin
                errors = errors + 1;
                if (errors < 60)
                    $display("T3 FAIL (prog): raster v=%0d mapped %0d expected %0d",
                             v, q_y_out, expv);
            end
        end
        $display("T3 letterbox inverse: %s", (errors != err0) ? "FAIL" : "PASS");
        err0 = errors;

        // ==============================================================
        // T4 — pass-through (bit-identical when disabled)
        // ==============================================================
        letterbox_en = 0; crop_en = 0;
        for (i = 0; i < 100; i = i + 1) begin
            h_pos_in = $urandom_range(0, 4095);
            v_pos_in = $urandom_range(0, 4095);
            #1;
            if (q_x_out !== h_pos_in || q_y_out !== v_pos_in) begin
                errors = errors + 1;
                $display("T4 FAIL: pass-through x %0d->%0d y %0d->%0d",
                         h_pos_in, q_x_out, v_pos_in, q_y_out);
            end
            @(negedge clk);
        end
        $display("T4 pass-through: %s", (errors != err0) ? "FAIL" : "PASS");
        err0 = errors;

        // ==============================================================
        // T5 — spu_decode q_row_base adder vs the mapped line sequences
        // ==============================================================
        for (i = 0; i < 414720; i = i + 1) spu.bmp[i] = gold_px(i);

        // (a) plain progressive raster 0..29 (+1 steps — regression)
        sp_interlaced = 0; sp_q_y = 12'hFFF; repeat (4) @(negedge clk);
        for (j = 0; j < 30; j = j + 1) t5_line(j[11:0]);
        // (b) progressive letterbox-mapped walk (+1/+2 steps, skips every 4th line)
        sp_q_y = 12'hFFF; repeat (4) @(negedge clk);
        for (j = 0; j < 60; j = j + 1) begin
            expv = lb_k(j) + ((lb_r(j) == 2) ? 1 : 0);
            t5_line(expv[11:0]);
        end
        // (c) plain 480i raster, both fields (+2 steps — regression)
        sp_interlaced = 1;
        for (f = 0; f < 2; f = f + 1) begin
            sp_q_y = 12'hFFF; repeat (4) @(negedge clk);
            for (j = 0; j < 30; j = j + 1) begin
                expv = 2 * j + f;
                t5_line(expv[11:0]);
            end
        end
        // (d) 480i letterbox-mapped walk (+2/+4 steps), both fields
        for (f = 0; f < 2; f = f + 1) begin
            sp_q_y = 12'hFFF; repeat (4) @(negedge clk);
            for (j = 0; j < 60; j = j + 1) begin
                expv = 2 * (lb_k(j) + ((lb_r(j) == 2) ? 1 : 0)) + f;
                t5_line(expv[11:0]);
            end
        end
        $display("T5 spu_decode row-base adder (mapped walks): %s",
                 (errors != err0) ? "FAIL" : "PASS");
        err0 = errors;

        // ==============================================================
        // T6 — SIF vertical 2x inverse (DVD-FORK FIX) vs the behavioral
        //      model of the addrgen mode-2 walk. v_src_max = 239 (NTSC SIF).
        // ==============================================================
        v2x_en = 1; v_src_max = 12'd239;

        // (a) progressive, no letterbox: every raster line maps to
        //     min(floor((v+1)/2), 239) — incl. the clamp rows 480..524
        letterbox_en = 0; crop_en = 0; interlaced = 0;
        v_pos_in = 12'hFFF; repeat (4) @(negedge clk);
        for (v = 0; v < 525; v = v + 1) begin
            step_v(v[11:0]);
            expv = v2x_src(v, 0, 239);
            if (q_y_out !== expv[11:0]) begin
                errors = errors + 1;
                if (errors < 40)
                    $display("T6a FAIL: raster v=%0d mapped %0d expected %0d", v, q_y_out, expv);
            end
        end

        // (b) 480i (the Video Output = Interlaced fields raster), both fields: parity-preserving inverse
        interlaced = 1;
        for (f = 0; f < 2; f = f + 1) begin
            v_pos_in = 12'hFFF; repeat (4) @(negedge clk);
            for (v = f; v < 525; v = v + 2) begin
                step_v(v[11:0]);
                expv = v2x_src(v, 1, 239);
                if (q_y_out !== expv[11:0]) begin
                    errors = errors + 1;
                    if (errors < 40)
                        $display("T6b FAIL (f%0d): raster v=%0d mapped %0d expected %0d",
                                 f, v, q_y_out, expv);
                end
            end
        end

        // (c) letterbox + v2x compose (progressive): the letterbox inverse yields a
        //     DOUBLED-space line, the v2x post-map halves it; bars stay 0xFFF
        interlaced = 0; letterbox_en = 1;
        v_pos_in = 12'hFFF; repeat (4) @(negedge clk);
        for (v = 0; v < 525; v = v + 1) begin
            step_v(v[11:0]);
            if (v >= VBAR && v < VBAR + VBAND) begin
                expv = lb_k(v - VBAR) + ((lb_r(v - VBAR) == 2) ? 1 : 0);
                expv = v2x_src(expv, 0, 239);
            end else expv = 'hFFF;
            if (q_y_out !== expv[11:0]) begin
                errors = errors + 1;
                if (errors < 40)
                    $display("T6c FAIL: raster v=%0d mapped %0d expected %0d", v, q_y_out, expv);
            end
        end

        // (d) letterbox + v2x, 480i: doubled-space field walk through both inverses
        interlaced = 1;
        for (f = 0; f < 2; f = f + 1) begin
            v_pos_in = 12'hFFF; repeat (4) @(negedge clk);
            for (v = f; v < 525; v = v + 2) begin
                step_v(v[11:0]);
                if (v >= VBAR && v < VBAR + VBAND) begin
                    j    = (v - VBAR) >> 1;
                    expv = 2 * (lb_k(j) + ((lb_r(j) == 2) ? 1 : 0)) + (v & 1);
                    expv = v2x_src(expv, 1, 239);
                end else expv = 'hFFF;
                if (q_y_out !== expv[11:0]) begin
                    errors = errors + 1;
                    if (errors < 40)
                        $display("T6d FAIL (f%0d): raster v=%0d mapped %0d expected %0d",
                                 f, v, q_y_out, expv);
                end
            end
        end
        v2x_en = 0; letterbox_en = 0; interlaced = 0;
        $display("T6 SIF vertical 2x inverse: %s", (errors != err0) ? "FAIL" : "PASS");

        if (errors) begin $display("crt_ov_map_tb: FAIL (%0d errors)", errors); $finish; end
        $display("crt_ov_map_tb: ALL TESTS PASS");
        $finish;
    end

    initial begin
        #8_000_000;
        $display("crt_ov_map_tb: TIMEOUT"); $finish;
    end

endmodule
/* not truncated */
