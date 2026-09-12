// cdda_viz_tb.sv -- dvd/cdda_viz.sv, the audio-CD copper-bar visualizer.
//
// Every check reads RENDERED PIXELS from a rastered frame, not the module's
// internal state, so a visualizer that computes the right numbers but draws
// nothing (or draws them in the wrong place) still fails. Each arm is written
// so the obvious broken implementation FAILS it:
//
//  [2] COPPER  loud music:
//        a  the whole active area is drawn
//        b  every line is ONE colour                         (per-pixel drift)
//        c  white bar cores exist                            (no bars fails)
//        d  the cores MOVE between frames                    (frozen solver fails)
//        e  exactly THREE bars, counted as white-core runs, MAXIMISED over
//           several frames                                   (a 5-bar regression
//                                                             reaches 5)
//  [4] GATES   vis = 0 and mode = 0 (the logo, and the default) each draw
//              nothing at all
//
// ⚠ [2e] counts runs of the 3-line WHITE CORE, not of the 31-line bar body, and
// takes the MAXIMUM over frames at different phases. Both parts are load-bearing
// and were learned by getting it wrong: bar BODIES overlap (two adjacent bars
// merge into one run and the count reads 2), and with a TRIANGLE oscillator two
// bars can land on the same row outright at particular phases. A single-frame
// exact count is therefore flaky by construction; the max over several phases is
// stable and still fails if the bar count changes.
//
// ⛔ The [1] SCOPE arms went with the scope (2026-09-11) and the [3] XOR arms
// with the XOR pattern (2026-09-12). The scope arms left a lesson kept in
// docs/cdda.md: their continuity check first counted lit COLUMNS, which a dotted
// plot also lights, so it passed a trace drawn as dots; only a PIXEL count could
// fail it. Reach for that if anything here ever draws a line again.
//
// ★ [4b] is now a SINGLE-guard test. While two visualizers existed, logo-blank
// was protected by the mode gate AND the case default in series, so no single
// mutation could fail the arm. With one visualizer the gate is the only guard,
// and mutating it alone must fail [4b].
//
// Run: iverilog -g2012 -o /tmp/viz_sim dvd/cdda_viz.sv bench/dvd/cdda_viz_tb.sv
`timescale 1ns/1ps

module cdda_viz_tb;
    localparam LEAD = 12;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  [11:0] h_pos = 0, v_pos = 0;
    reg         frame_tick = 0, vis = 1;
    reg  [1:0]  mode = 2'd1;          // 1 = copper; 0 is the logo (the default)
    reg  [15:0] audio_l = 0, audio_r = 0;
    wire        viz_on;
    wire [7:0]  viz_r, viz_g, viz_b;

    // SDIV_W 8: a sample tick every 256 clocks, so the envelope attacks in a
    // reasonable number of simulated clocks.
    cdda_viz #(.VIZ_QX_LEAD(LEAD), .SDIV_W(8)) dut (
        .clk(clk), .rst_n(rst_n), .h_pos(h_pos), .v_pos(v_pos), .pal_mode(1'b0),
        .frame_tick(frame_tick), .vis(vis), .mode(mode),
        .audio_l(audio_l), .audio_r(audio_r),
        .viz_on(viz_on), .viz_r(viz_r), .viz_g(viz_g), .viz_b(viz_b));

    integer errors = 0;
    task chk(input [8*72-1:0] what, input ok);
        if (!ok) begin errors = errors + 1; $display("  FAIL %0s", what); end
        else $display("  ok   %0s", what);
    endtask

    // ---- audio: a tone whose period is exactly 64 sample ticks -------------
    integer cyc = 0;
    real    amp_l = 0.0, amp_r = 0.0;
    always @(negedge clk) begin
        cyc = cyc + 1;
        audio_l = $rtoi(amp_l * $sin(6.283185307 * cyc / 16384.0));
        audio_r = $rtoi(amp_r * $sin(6.283185307 * cyc / 16384.0));
    end

    // ---- per-frame accumulators, filled by render() -------------------------
    integer on_px, px_n, line_mismatch, white_lines, core_groups, max_cores;
    reg [479:0] white_row, white_prev;
    reg [23:0]  line_c10;

    // pipeline copies of the raster inputs, aligned with the 3-clock output
    reg [11:0] hp1, hp2, hp3, vp1, vp2, vp3;

    task render(input integer hmax);
        integer vv, h, hq, vq;
        begin
            on_px = 0; px_n = 0; line_mismatch = 0; white_lines = 0;
            white_row = 0; line_c10 = 0;
            for (vv = 0; vv < 525; vv = vv + 1)
                for (h = 0; h < hmax; h = h + 1) begin
                    @(negedge clk);
                    // outputs now reflect the inputs applied 3 negedges ago
                    hq = hp3 - LEAD; vq = vp3;
                    if (hp3 >= LEAD && hq < 720 && vq < 480) begin
                        px_n = px_n + 1;
                        if (viz_on) on_px = on_px + 1;
                        if (hq == 10) line_c10 = {viz_r, viz_g, viz_b};
                        if (hq == 300 && {viz_r, viz_g, viz_b} !== line_c10)
                            line_mismatch = line_mismatch + 1;
                        if (hq == 300 && viz_r >= 8'hEE && viz_g >= 8'hEE && viz_b >= 8'hEE)
                            white_row[vq] = 1'b1;
                    end
                    hp3 = hp2; hp2 = hp1; hp1 = h;
                    vp3 = vp2; vp2 = vp1; vp1 = vv;
                    h_pos = h; v_pos = vv;
                end
            white_lines = 0; core_groups = 0;
            for (vv = 0; vv < 480; vv = vv + 1) begin
                if (white_row[vv]) white_lines = white_lines + 1;
                // a new core run starts on a lit line whose predecessor was dark
                if (white_row[vv] && (vv == 0 || !white_row[vv-1]))
                    core_groups = core_groups + 1;
            end
            if (core_groups > max_cores) max_cores = core_groups;
            @(negedge clk) frame_tick = 1; @(negedge clk) frame_tick = 0;
        end
    endtask

    task ticks(input integer n);        // advance frame state without rastering
        integer i;
        for (i = 0; i < n; i = i + 1) begin
            @(negedge clk) frame_tick = 1; @(negedge clk) frame_tick = 0;
            repeat (20) @(negedge clk);
        end
    endtask

    integer f;
    initial begin
        hp1 = 0; hp2 = 0; hp3 = 0; vp1 = 0; vp2 = 0; vp3 = 0;
        max_cores = 0;
        repeat (5) @(negedge clk); rst_n = 1;

        // ================= [2] COPPER =================
        $display("=== [2] copper bars, loud ===");
        mode = 2'd1; amp_l = 30000.0; amp_r = 30000.0;
        repeat (20000) @(negedge clk);              // envelope attacks
        ticks(4);
        render(320);
        white_prev = white_row;
        $display("  lit %0d/%0d  mismatched lines %0d  white-core lines %0d  core runs %0d  env %0d",
                 on_px, px_n, line_mismatch, white_lines, core_groups, dut.env);
        chk("[2a] whole active area drawn", on_px == px_n && px_n > 0);
        chk("[2b] every line is one colour", line_mismatch == 0);
        chk("[2c] white bar cores present (>= 3 lines)", white_lines >= 3);
        ticks(40);
        render(320);
        chk("[2d] bar cores moved between frames", white_row !== white_prev && white_lines >= 3);

        // sample several more phases; bars that coincide in one frame separate
        // in another, so the MAXIMUM run count is the stable bar-count measure
        for (f = 0; f < 4; f = f + 1) begin
            ticks(23);
            render(320);
        end
        $display("  max white-core runs over 6 frames: %0d", max_cores);
        chk("[2e] exactly three bars (max core runs over 6 frames)", max_cores == 3);

        // ================= [4] GATES =================
        $display("=== [4] gates ===");
        mode = 2'd1; vis = 0;
        render(760);
        chk("[4a] vis = 0 draws nothing", on_px == 0 && px_n > 0);
        vis = 1; mode = 2'd0;
        render(760);
        chk("[4b] mode 0 (logo) draws nothing", on_px == 0 && px_n > 0);

        if (errors == 0) $display("CDDA_VIZ_TB: ALL TESTS PASSED");
        else begin
            $display("CDDA_VIZ_TB: FAILED (%0d errors)", errors);
            $fatal(1);
        end
        $finish;
    end
endmodule
