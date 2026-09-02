// hud_frame_tb.sv -- Phase 11 HUD frame render + interlace-safety proof.
//
// Rasters a full 720x480 frame through transport_hud + subpic_blend (the real
// compositor) over a mid-grey background and dumps a PPM for visual
// inspection (bench/dvd/hud_frame.ppm). Then re-scans the same frame in FIELD
// ORDER (all even lines, then all odd) and asserts per-pixel identity with the
// progressive pass -- the pixel pipeline must be a pure function of (x, y),
// which is what makes it CRT-480i safe.
//
// Checks: field-pass identity; text pixels present (white + outline + backing
// counts within sane bounds); nothing rendered outside the status-row box.
//
// DVD-FORK (narrow DE window, 2026-09-14): the frame buffer stays 720x480 while the
// DECLARED window (act_w_i/act_h_i) shrinks, so "nothing outside the box" becomes a real
// measurement of what a 352- or 480-wide picture would receive rather than an assumption
// that something downstream clips. Two further arms:
//   [narrow]  the box re-centres inside the declared window and the rows stay inside it
//   [double]  the 1x render IS the 2x render with each column PAIR collapsed -- which is
//             what makes "narrow just changes the pitch" a measurement and not a claim.
//             It compares two renders of the SAME text, so it cannot be satisfied by a
//             module that merely draws something narrow.
//
// Run: iverilog -g2012 -o /tmp/hudf_sim dvd/transport_hud.sv dvd/subpic_blend.sv \
//        bench/dvd/hud_frame_tb.sv && vvp /tmp/hudf_sim   (from the repo root)
`timescale 1ns/1ps

module hud_frame_tb;

    localparam W = 720, H = 480;
    localparam ADJ = 4;                    // = transport_hud HUD_QX_ADJ default

    reg clk = 0, rst_n = 0;
    always #18.5 clk = ~clk;

    reg  [11:0] h_pos = 0, v_pos = 0;
    reg         display_edge = 0;
    reg         aud_evt = 0;
    wire        hud_on;
    wire [7:0]  hud_r, hud_g, hud_b;
    wire [3:0]  hud_alpha;


    // DVD-FORK (native 240p, 2026-09-14): the raster's active height is now an INPUT.
    // Defaults to the standard so every pre-existing arm is bit-identical; +act_h=N
    // drives the 240p/288p arm, where the module must bottom-anchor to 240/288 instead.
    integer     act_h_arg = 0;
    initial     void'($value$plusargs("act_h=%d", act_h_arg));
    // DVD-FORK (narrow DE window, 2026-09-14): the declared window is DRIVEN, not tied, so
    // one run can render the same text at two widths and compare them ([double]).
    // +act_w=N / +act_h=N pick the window the run STARTS at (defaults 720x480 = every
    // pre-existing arm, bit-identical).
    integer     act_w_arg = 0;
    initial     void'($value$plusargs("act_w=%d", act_w_arg));
    reg  [11:0] act_w_tb, act_h_tb;
    initial begin
        act_w_tb = (act_w_arg != 0) ? act_w_arg[11:0] : 12'd720;
        act_h_tb = (act_h_arg != 0) ? act_h_arg[11:0] : 12'd480;
    end
    transport_hud #(.HUD_QX_ADJ(ADJ)) dut (
        .clk(clk), .rst_n(rst_n),
        .h_pos(h_pos), .v_pos(v_pos), .pal_mode(1'b0), .act_h_i(act_h_tb), .act_w_i(act_w_tb),
        .menu_active(1'b0), .pause_q(1'b0), .pause_seed(1'b1), .pause_show_o(), .bar_active(1'b0),
        .scrub_held(1'b0), .scrub_dir(1'b0), .scrub_tier(2'd0),
        .display_edge(display_edge), .load_evt(1'b0), .show_evt(1'b0),
        .force_show(1'b0),
        .cur_time({8'h00, 8'h12, 8'h34, 8'h00}),
        .total_time({8'h01, 8'h37, 8'h05, 8'hC0}),
        .cur_pgm(8'd12), .nr_pgm(8'd23),
        .aud_evt(aud_evt), .sub_evt(1'b0), .angle_evt(1'b0), .chap_evt(1'b0),
        .css_warn(1'b0),
        .aud_no(4'd2), .aud_cnt(4'd4), .aud_lang("fr"),
        .sub_enabled(1'b0), .sub_no(4'd0), .sub_cnt(4'd0), .sub_lang(16'd0),
        .ang_no(4'd0), .ang_cnt(4'd0),
        .hud_on(hud_on), .hud_r(hud_r), .hud_g(hud_g), .hud_b(hud_b),
        .hud_alpha(hud_alpha)
    );

    // the real compositor, over a mid-grey background
    wire [7:0] out_r, out_g, out_b;
    subpic_blend blend (
        .in_r(8'h60), .in_g(8'h60), .in_b(8'h60),
        .ov_on(hud_on), .ov_idx(2'd1),
        .ov_r(hud_r), .ov_g(hud_g), .ov_b(hud_b),
        .ov_alpha(hud_alpha), .ov_force(1'b1),
        .out_r(out_r), .out_g(out_g), .out_b(out_b)
    );

    reg [23:0] fb  [0:W*H-1];              // progressive pass
    reg [23:0] fb2 [0:W*H-1];              // field-order pass

    // scan one line into a buffer. A pixel driven as input h renders at screen
    // position h+4 (3 register stages + the HUD_QX_ADJ=4 lead); capture at the
    // NEGEDGE so NBAs + the combinational blend have settled (sampling right
    // after the posedge races the non-blocking updates). At the negedge after
    // the edge that sampled input x, the settled output is pixel(input x-3)
    // = screen x+1. Prime the pipe with blanking columns first.
    integer x, y, i;
    task scan_line(input integer yy, input integer pass);
        begin
            v_pos = yy[11:0];
            for (x = -5; x < W; x = x + 1) begin
                h_pos = (x < 0) ? 12'd850 : x[11:0];   // blanking primer
                @(posedge clk);
                @(negedge clk);
                if (x >= -1 && (x + 1) < W) begin
                    if (pass == 0) fb [yy*W + x+1] = {out_r, out_g, out_b};
                    else           fb2[yy*W + x+1] = {out_r, out_g, out_b};
                end
            end
        end
    endtask

    integer errors = 0;
    integer n_white, n_black, n_back, n_out;
    integer fh;

    // the module's own layout rule, restated here as the BENCH's expectation. It is the
    // one thing a bench of this kind must not read out of the DUT, so it is written from
    // the design (a centred box, 512 px above the 544 knee and 256 below it) and every
    // arm below is scored against it.
    function [11:0] box_w(input [11:0] aw); box_w = (aw >= 12'd544) ? 12'd512 : 12'd256; endfunction
    function [11:0] box_x0(input [11:0] aw); box_x0 = (aw - box_w(aw)) >> 1; endfunction

    // fb index == hq == h_pos + HUD_QX_ADJ, so the box occupies fb columns [x0, x0+w).
    reg [23:0] fbr [0:W*H-1];              // kept reference render (for [double])
    integer    ref_x0, ref_w;

    // render the current window into fb (progressive) + fb2 (field order) and check
    // field identity, the box bounds against the DECLARED window, and content counts.
    task render_and_check(input [8*10-1:0] tag);
        integer bx0, bw, by0, by0p, e0;
    begin
        bx0 = box_x0(act_w_tb); bw = box_w(act_w_tb);
        by0 = act_h_tb - 64;  by0p = act_h_tb - 112;
        e0 = errors;

        for (y = 0; y < H; y = y + 1) scan_line(y, 0);
        for (y = 0; y < H; y = y + 2) scan_line(y, 1);
        for (y = 1; y < H; y = y + 2) scan_line(y, 1);

        for (i = 0; i < W*H; i = i + 1)
            if (fb[i] !== fb2[i]) begin
                if (errors - e0 < 5)
                    $display("  FAIL [%0s] field mismatch at (%0d,%0d): %06x vs %06x",
                             tag, i % W, i / W, fb[i], fb2[i]);
                errors = errors + 1;
            end
        if (errors == e0) $display("  ok  [%0s] field-order pass identical (interlace-safe)", tag);

        n_white = 0; n_black = 0; n_back = 0; n_out = 0;
        for (y = 0; y < H; y = y + 1)
            for (x = 0; x < W; x = x + 1) begin
                i = y*W + x;
                if (!((y >= by0 && y < by0 + 32) || (y >= by0p && y < by0p + 32)) ||
                    x < bx0 || x >= bx0 + bw) begin
                    if (fb[i] !== 24'h606060) n_out = n_out + 1;
                end else begin
                    if (fb[i] == 24'hFFFFFF)      n_white = n_white + 1;
                    else if (fb[i] == 24'h000000) n_black = n_black + 1;
                    else if (fb[i] != 24'h606060) n_back  = n_back  + 1;
                end
            end
        // ★ The box is inside the DECLARED window, so this also proves nothing is drawn
        //   where a narrow picture has no pixels -- the reported VCD/SVCD defect exactly.
        if (n_out != 0) begin
            errors = errors + 1;
            $display("  FAIL [%0s] %0d pixels rendered OUTSIDE the box (x %0d..%0d, window %0dx%0d)",
                     tag, n_out, bx0, bx0 + bw - 1, act_w_tb, act_h_tb);
        end else $display("  ok  [%0s] nothing outside the box (x %0d..%0d in a %0dx%0d window)",
                          tag, bx0, bx0 + bw - 1, act_w_tb, act_h_tb);
        if (bx0 + bw > act_w_tb || by0 + 32 > act_h_tb) begin
            errors = errors + 1;
            $display("  FAIL [%0s] the box itself does not fit the window", tag);
        end
        // 29 active cells; the counts roughly halve at the 1x pitch, so the bounds are
        // loose on purpose -- the exact-pixel claim is [double], not this.
        if (n_white < 500 || n_white > 8000) begin
            errors = errors + 1;
            $display("  FAIL [%0s] white fill count %0d out of range", tag, n_white);
        end else $display("  ok  [%0s] fill=%0d outline=%0d backing=%0d", tag, n_white, n_black, n_back);
        if (n_black < 500) begin
            errors = errors + 1;
            $display("  FAIL [%0s] outline count %0d too low", tag, n_black);
        end
        if (n_back < 2000) begin
            errors = errors + 1;
            $display("  FAIL [%0s] backing count %0d too low", tag, n_back);
        end
    end
    endtask

    integer k, j, bad, yy, wsel;
    string dump_name;
    initial begin
        if (act_w_tb == 12'd720 && act_h_tb == 12'd480)
            dump_name = "bench/dvd/hud_frame.ppm";
        else
            dump_name = $sformatf("bench/dvd/hud_frame_%0dx%0d.ppm", act_w_tb, act_h_tb);
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);
        // persistent mode on + an audio popup (its 2.5 s outlasts the ~50 ms
        // of simulated raster time); let the formatter complete a pass
        display_edge = 1; aud_evt = 1; @(posedge clk);
        display_edge = 0; aud_evt = 0;
        repeat (100) @(posedge clk);

        render_and_check("window");

        // PPM dump for eyeball inspection, NAMED BY ITS WINDOW.
        // ⚠ bench/dvd/hud_frame.ppm is tools/hud_read.py's GOLDEN frame and its selftest
        // (run by bench/dvd/run_telem.sh) decodes it expecting the 720x480 layout. A run
        // at another window must therefore not overwrite it -- run_ov_geom.sh drives
        // three widths in a row, so without this the last one wins and a later
        // run_telem.sh fails on a frame it never asked for.
        fh = $fopen(dump_name, "w");
        $fwrite(fh, "P3\n%0d %0d\n255\n", W, H);
        for (i = 0; i < W*H; i = i + 1)
            $fwrite(fh, "%0d %0d %0d\n", fb[i][23:16], fb[i][15:8], fb[i][7:0]);
        $fclose(fh);
        $display("  wrote %0s", dump_name);

        // ---- [narrow] + [double] ------------------------------------------
        // Keep this render, then re-render the SAME text in each real narrow window and
        // require the narrow one to be the wide one with every column PAIR collapsed.
        // ★ This is the arm that separates "draws something narrow" from "draws the same
        //   line at half the pitch": a box that kept the 2x pitch shows only the first 16
        //   cells, and a box drawn at half scale but not re-mapped shows the left half of
        //   the text. Both sit entirely inside the window and pass every count check.
        // Skipped when the run already started narrow -- the wide reference does not exist.
        if (act_w_tb >= 12'd544) begin
            for (i = 0; i < W*H; i = i + 1) fbr[i] = fb[i];
            ref_x0 = box_x0(act_w_tb);

            for (wsel = 0; wsel < 2; wsel = wsel + 1) begin
                act_w_tb = (wsel == 0) ? 12'd352 : 12'd480;   // VCD, then SVCD
                repeat (4) @(posedge clk);
                render_and_check(wsel == 0 ? "vcd 352" : "svcd 480");

                bad = 0;
                for (j = 0; j < 2; j = j + 1)
                    for (yy = 0; yy < 32; yy = yy + 1)
                        for (k = 0; k < 256; k = k + 1) begin
                            y = (j == 0 ? (act_h_tb - 64) : (act_h_tb - 112)) + yy;
                            if (fb [y*W + box_x0(act_w_tb) + k] !== fbr[y*W + ref_x0 + 2*k] ||
                                fb [y*W + box_x0(act_w_tb) + k] !== fbr[y*W + ref_x0 + 2*k + 1]) begin
                                if (bad == 0)
                                    $display("  first doubling mismatch (window %0d) row %0d y=%0d k=%0d: 1x %06x vs 2x %06x/%06x",
                                             act_w_tb, j, y, k, fb[y*W + box_x0(act_w_tb) + k],
                                             fbr[y*W + ref_x0 + 2*k], fbr[y*W + ref_x0 + 2*k + 1]);
                                bad = bad + 1;
                            end
                        end
                if (bad != 0) begin
                    errors = errors + 1;
                    $display("  FAIL [double %0d] %0d of 16384 columns differ between the 1x render and the collapsed 2x render",
                             act_w_tb, bad);
                end else
                    $display("  ok  [double %0d] the 1x render is the 2x render with each column pair collapsed",
                             act_w_tb);
            end
        end

        // ⚠ $fatal, NOT $finish: vvp exits 0 on $finish, so a runner that scores the
        // exit code sees a FAILING bench as a passing one -- which is exactly how the
        // bench/ac3 suites went silently red for weeks (docs/ac3_decoder_architecture.md
        // §4.11), and it makes every RED arm in bench/dvd/run_ov_geom.sh vacuous.
        if (errors == 0) begin
            $display("HUD_FRAME_TB: ALL TESTS PASSED");
            $finish;
        end else
            $fatal(1, "HUD_FRAME_TB: FAILED (%0d errors)", errors);
    end
endmodule
