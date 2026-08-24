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

    transport_hud #(.HUD_QX_ADJ(ADJ)) dut (
        .clk(clk), .rst_n(rst_n),
        .h_pos(h_pos), .v_pos(v_pos), .pal_mode(1'b0),
        .menu_active(1'b0), .pause_q(1'b0), .bar_active(1'b0),
        .scrub_held(1'b0), .scrub_dir(1'b0), .scrub_tier(2'd0),
        .display_edge(display_edge), .load_evt(1'b0), .show_evt(1'b0),
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

    initial begin
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);
        // persistent mode on + an audio popup (its 2.5 s outlasts the ~13 ms
        // of simulated raster time); let the formatter complete a pass
        display_edge = 1; aud_evt = 1; @(posedge clk);
        display_edge = 0; aud_evt = 0;
        repeat (100) @(posedge clk);

        // pass 0: progressive scan
        for (y = 0; y < H; y = y + 1) scan_line(y, 0);

        // pass 1: field order (even lines then odd lines)
        for (y = 0; y < H; y = y + 2) scan_line(y, 1);
        for (y = 1; y < H; y = y + 2) scan_line(y, 1);

        // identity check
        for (i = 0; i < W*H; i = i + 1)
            if (fb[i] !== fb2[i]) begin
                if (errors < 5)
                    $display("  FAIL field mismatch at (%0d,%0d): %06x vs %06x",
                             i % W, i / W, fb[i], fb2[i]);
                errors = errors + 1;
            end
        if (errors == 0) $display("  ok  field-order pass identical (interlace-safe)");

        // content sanity: count pixel classes inside/outside the two rows
        // (status y 416..447, popup y 368..399; both x 104..615)
        n_white = 0; n_black = 0; n_back = 0; n_out = 0;
        for (y = 0; y < H; y = y + 1)
            for (x = 0; x < W; x = x + 1) begin
                i = y*W + x;
                if (!((y >= 416 && y < 448) || (y >= 368 && y < 400)) ||
                    x < 104 || x >= 616) begin
                    if (fb[i] !== 24'h606060) n_out = n_out + 1;
                end else begin
                    if (fb[i] == 24'hFFFFFF)      n_white = n_white + 1;
                    else if (fb[i] == 24'h000000) n_black = n_black + 1;
                    else if (fb[i] != 24'h606060) n_back  = n_back  + 1;
                end
            end
        if (n_out != 0) begin
            errors = errors + 1;
            $display("  FAIL %0d pixels rendered OUTSIDE the status box", n_out);
        end else $display("  ok  nothing outside the status box");
        // 29 active cells * 16x32 = 14848 px; text fill is a modest fraction
        if (n_white < 500 || n_white > 8000) begin
            errors = errors + 1;
            $display("  FAIL white fill count %0d out of range", n_white);
        end else $display("  ok  fill=%0d outline=%0d backing=%0d", n_white, n_black, n_back);
        if (n_black < 500) begin
            errors = errors + 1;
            $display("  FAIL outline count %0d too low", n_black);
        end
        if (n_back < 2000) begin
            errors = errors + 1;
            $display("  FAIL backing count %0d too low", n_back);
        end

        // PPM dump for eyeball inspection
        fh = $fopen("bench/dvd/hud_frame.ppm", "w");
        $fwrite(fh, "P3\n%0d %0d\n255\n", W, H);
        for (i = 0; i < W*H; i = i + 1)
            $fwrite(fh, "%0d %0d %0d\n", fb[i][23:16], fb[i][15:8], fb[i][7:0]);
        $fclose(fh);
        $display("  wrote bench/dvd/hud_frame.ppm");

        if (errors == 0) $display("HUD_FRAME_TB: ALL TESTS PASSED");
        else             $display("HUD_FRAME_TB: FAILED (%0d errors)", errors);
        $finish;
    end
endmodule
