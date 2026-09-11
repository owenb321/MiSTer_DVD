// cdda_viz_tb.sv -- dvd/cdda_viz.sv, the audio-CD visualizers.
//
// Every check reads RENDERED PIXELS from a rastered frame, not the module's
// internal state, so a visualizer that computes the right numbers but draws
// nothing (or draws them in the wrong place) still fails. Each arm is written
// so the obvious broken implementation FAILS it:
//
//  [1] SCOPE   L = full-scale tone, R = silence:
//        a  the L trace spans most of its +/-96-row window  (dead capture = 0)
//        b  the R trace is flat on its centre row           (L/R swap fails)
//        c  the trace is continuous: its pixel count is ~the vertical travel
//           (a dotted plot lights every column too, so COLUMNS alone prove nothing)
//        d  it starts on L's RISING zero crossing            (free-run fails)
//        e  nothing below the traces                         (stray fill fails)
//  [2] COPPER  loud music:
//        a  the whole active area is drawn
//        b  every line is ONE colour                         (per-pixel drift)
//        c  white bar cores exist                            (no bars fails)
//        d  the cores MOVE between frames                    (frozen solver fails)
//  [3] XOR     colour varies along x AND the pattern scrolls between frames
//  [4] GATES   vis = 0 and mode = 3 each draw nothing at all
//
// Run: iverilog -g2012 -o /tmp/viz_sim dvd/cdda_viz.sv bench/dvd/cdda_viz_tb.sv
`timescale 1ns/1ps

module cdda_viz_tb;
    localparam LEAD = 12;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  [11:0] h_pos = 0, v_pos = 0;
    reg         frame_tick = 0, vis = 1;
    reg  [1:0]  mode = 2'd2;
    reg  [15:0] audio_l = 0, audio_r = 0;
    wire        viz_on;
    wire [7:0]  viz_r, viz_g, viz_b;

    // SDIV_W 8: a sample tick every 256 clocks, so a 360-sample capture takes
    // ~92k clocks instead of 1.5M. Nothing else depends on the tick rate.
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
    integer l_min, l_max, r_min, r_max, below, lit_cols, on_px, px_n, l_px;
    integer col0_row, col10_hi, line_mismatch, white_lines;
    reg [359:0] col_hit;
    reg [479:0] white_row, white_prev;
    reg [255:0] r_seen;
    reg [7:0]   xor_r100 [0:719], xor_prev [0:719];
    reg [23:0]  line_c10;
    integer xor_diff;

    // pipeline copies of the raster inputs, aligned with the 3-clock output
    reg [11:0] hp1, hp2, hp3, vp1, vp2, vp3;

    task render(input integer hmax);
        integer v, h, hq, vq;
        begin
            l_min = 9999; l_max = -1; r_min = 9999; r_max = -1;
            below = 0; lit_cols = 0; on_px = 0; px_n = 0; l_px = 0;
            col0_row = -1; col10_hi = -1; line_mismatch = 0; white_lines = 0;
            col_hit = 0; white_row = 0; r_seen = 0; line_c10 = 0;
            for (v = 0; v < 525; v = v + 1)
                for (h = 0; h < hmax; h = h + 1) begin
                    @(negedge clk);
                    // outputs now reflect the inputs applied 3 negedges ago
                    hq = hp3 - LEAD; vq = vp3;
                    if (hp3 >= LEAD && hq < 720 && vq < 480) begin
                        px_n = px_n + 1;
                        if (viz_on) on_px = on_px + 1;
                        // scope traces
                        if (viz_on && viz_r == 8'h40 && viz_g == 8'hFF) begin
                            if (vq < l_min) l_min = vq;
                            if (vq > l_max) l_max = vq;
                            col_hit[hq/2] = 1'b1;
                            l_px = l_px + 1;
                            if (hq == 0 && col0_row < 0) col0_row = vq;
                            if (hq == 20 && vq > col10_hi) col10_hi = vq;
                        end
                        if (viz_on && viz_r == 8'hFF && viz_g == 8'hB0) begin
                            if (vq < r_min) r_min = vq;
                            if (vq > r_max) r_max = vq;
                        end
                        if (viz_on && vq >= 380 && vq < 470) below = below + 1;
                        // copper: one colour per line; white cores
                        if (hq == 10) line_c10 = {viz_r, viz_g, viz_b};
                        if (hq == 300 && {viz_r, viz_g, viz_b} !== line_c10)
                            line_mismatch = line_mismatch + 1;
                        if (hq == 300 && viz_r >= 8'hEE && viz_g >= 8'hEE && viz_b >= 8'hEE)
                            white_row[vq] = 1'b1;
                        // xor: row 100
                        if (vq == 100) begin
                            r_seen[viz_r] = 1'b1;
                            xor_r100[hq] = viz_r;
                        end
                    end
                    hp3 = hp2; hp2 = hp1; hp1 = h;
                    vp3 = vp2; vp2 = vp1; vp1 = v;
                    h_pos = h; v_pos = v;
                end
            for (v = 0; v < 360; v = v + 1) if (col_hit[v]) lit_cols = lit_cols + 1;
            for (v = 0; v < 480; v = v + 1) if (white_row[v]) white_lines = white_lines + 1;
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

    integer i, n;
    initial begin
        hp1 = 0; hp2 = 0; hp3 = 0; vp1 = 0; vp2 = 0; vp3 = 0;
        repeat (5) @(negedge clk); rst_n = 1;

        // ================= [1] SCOPE =================
        $display("=== [1] scope: L tone, R silent ===");
        mode = 2'd2; amp_l = 30000.0; amp_r = 0.0;
        repeat (300000) @(negedge clk);            // several triggered captures
        render(760);
        $display("  L rows %0d..%0d  R rows %0d..%0d  cols lit %0d  L px %0d  col0 %0d  col10hi %0d  below %0d",
                 l_min, l_max, r_min, r_max, lit_cols, l_px, col0_row, col10_hi, below);
        chk("[1a] L trace spans >= 150 rows of its +/-96 window", (l_max - l_min) >= 150);
        chk("[1a] ...and stays inside it (112 +/- 97)", l_min >= 15 && l_max <= 209);
        chk("[1b] R trace is flat on row 262", r_min == 262 && r_max == 262);
        chk("[1c] trace continuous: >= 350 columns lit AND >= 2000 L px (dotted ~720)",
            lit_cols >= 350 && l_px >= 2000);
        chk("[1d] starts at L's zero crossing (col 0 within 112 +/- 12)",
            col0_row >= 100 && col0_row <= 124);
        chk("[1d] ...on the RISING side (col 10 well below col 0)", col10_hi > col0_row + 40);
        chk("[1e] nothing drawn below the traces", below == 0);

        // ================= [2] COPPER =================
        $display("=== [2] copper bars, loud ===");
        mode = 2'd0; amp_l = 30000.0; amp_r = 30000.0;
        repeat (20000) @(negedge clk);              // envelope attacks
        ticks(4);
        render(320);
        white_prev = white_row;
        $display("  lit %0d/%0d  mismatched lines %0d  white-core lines %0d  env %0d",
                 on_px, px_n, line_mismatch, white_lines, dut.env);
        chk("[2a] whole active area drawn", on_px == px_n && px_n > 0);
        chk("[2b] every line is one colour", line_mismatch == 0);
        chk("[2c] white bar cores present (>= 3 lines)", white_lines >= 3);
        ticks(40);
        render(320);
        chk("[2d] bar cores moved between frames", white_row !== white_prev && white_lines >= 3);

        // ================= [3] XOR =================
        $display("=== [3] xor pattern ===");
        mode = 2'd1;
        render(760);
        n = 0; for (i = 0; i < 256; i = i + 1) if (r_seen[i]) n = n + 1;
        for (i = 0; i < 720; i = i + 1) xor_prev[i] = xor_r100[i];
        $display("  distinct red values on row 100: %0d  lit %0d/%0d", n, on_px, px_n);
        chk("[3a] whole active area drawn", on_px == px_n && px_n > 0);
        chk("[3b] colour varies along x (>= 32 distinct values)", n >= 32);
        ticks(10);
        render(760);
        xor_diff = 0;
        for (i = 0; i < 720; i = i + 1) if (xor_r100[i] !== xor_prev[i]) xor_diff = xor_diff + 1;
        chk("[3c] pattern scrolls between frames (>= 100 px changed)", xor_diff >= 100);

        // ================= [4] GATES =================
        $display("=== [4] gates ===");
        mode = 2'd0; vis = 0;
        render(760);
        chk("[4a] vis = 0 draws nothing", on_px == 0 && px_n > 0);
        vis = 1; mode = 2'd3;
        render(760);
        chk("[4b] mode 3 (logo) draws nothing", on_px == 0 && px_n > 0);

        if (errors == 0) $display("CDDA_VIZ_TB: ALL TESTS PASSED");
        else begin
            $display("CDDA_VIZ_TB: FAILED (%0d errors)", errors);
            $fatal(1);
        end
        $finish;
    end
endmodule
