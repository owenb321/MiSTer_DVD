// cdda_viz_tb.sv -- dvd/cdda_viz.sv, the audio-CD visualizers.
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
//  [3] XOR     colour varies along x AND the pattern scrolls between frames
//  [4] GATES   vis = 0 and mode = 2 (the logo) each draw nothing at all
//
// ⛔ The [1] SCOPE arms went with the scope itself (2026-09-11). Their durable
// lesson is kept in docs/cdda.md and is worth re-reading before anything here
// draws a line again: the continuity check first counted lit COLUMNS, which a
// dotted plot also lights, so it passed a trace drawn as dots; only counting
// PIXELS (~4,700 continuous vs ~720 dotted) could fail it.
//
// Run: iverilog -g2012 -o /tmp/viz_sim dvd/cdda_viz.sv bench/dvd/cdda_viz_tb.sv
`timescale 1ns/1ps

module cdda_viz_tb;
    localparam LEAD = 12;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  [11:0] h_pos = 0, v_pos = 0;
    reg         frame_tick = 0, vis = 1;
    reg  [1:0]  mode = 2'd0;
    reg  [15:0] audio_l = 0, audio_r = 0;
    wire        viz_on;
    wire [7:0]  viz_r, viz_g, viz_b;

    // SDIV_W 8: a sample tick every 256 clocks instead of 4096, so the envelope
    // attacks in a reasonable number of simulated clocks.
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
    integer on_px, px_n, line_mismatch, white_lines;
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
            on_px = 0; px_n = 0; line_mismatch = 0; white_lines = 0;
            white_row = 0; r_seen = 0; line_c10 = 0;
            for (v = 0; v < 525; v = v + 1)
                for (h = 0; h < hmax; h = h + 1) begin
                    @(negedge clk);
                    // outputs now reflect the inputs applied 3 negedges ago
                    hq = hp3 - LEAD; vq = vp3;
                    if (hp3 >= LEAD && hq < 720 && vq < 480) begin
                        px_n = px_n + 1;
                        if (viz_on) on_px = on_px + 1;
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
        vis = 1; mode = 2'd2;
        render(760);
        chk("[4b] mode 2 (logo) draws nothing", on_px == 0 && px_n > 0);

        if (errors == 0) $display("CDDA_VIZ_TB: ALL TESTS PASSED");
        else begin
            $display("CDDA_VIZ_TB: FAILED (%0d errors)", errors);
            $fatal(1);
        end
        $finish;
    end
endmodule
