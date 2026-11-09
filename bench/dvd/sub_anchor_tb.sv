// sub_anchor_tb.sv -- dvd/sub_anchor.sv against its contract (docs/standard_convert.md).
// The contract is the CONSUMER's, checked directly rather than against a copy of the formula:
//   [even]   the offset is even (each field reads its own subtitle lines)
//   [screen] the box's last row lands on the 480-line raster: ey - off <= 479
//   [place]  when the natural place fits, the box's top lands within one raster row of where
//            the scaled picture shows source row sy (exact rational, below)
//   [none]   ratio 0 and 3 give 0
// Runner: bench/dvd/run_sub_anchor.sh (--red = mutations).
`timescale 1ns/1ps
module sub_anchor_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg  [1:0]  ratio = 0;
    reg  [11:0] sy = 0, ey = 0;
    wire signed [11:0] off;
    sub_anchor dut (.clk(clk), .rst_n(rst_n), .ratio(ratio), .sy(sy), .ey(ey), .off(off));

    // Every failing ARM is reported in a summary line, however many cases fail before it:
    // a runner that scores arms from printed lines must not lose one to a print limit.
    integer fails = 0, n = 0;
    integer f_x = 0, f_none = 0, f_even = 0, f_screen = 0, f_place = 0;
    task fail(input [8*8-1:0] arm, input [8*60-1:0] msg);
        begin
            if (fails < 12) $display("  case [%0s] ratio=%0d sy=%0d ey=%0d off=%0d: %0s", arm, ratio, sy, ey, off, msg);
            fails = fails + 1;
            if (arm == "x") f_x = f_x + 1;       if (arm == "none") f_none = f_none + 1;
            if (arm == "even") f_even = f_even + 1; if (arm == "screen") f_screen = f_screen + 1;
            if (arm == "place") f_place = f_place + 1;
        end
    endtask

    integer s, h, k, r, top_x2, raster_top, e;
    integer hs [0:4];
    initial begin
        hs[0] = 1; hs[1] = 24; hs[2] = 60; hs[3] = 120; hs[4] = 576;
        repeat (3) @(negedge clk); rst_n = 1;
        for (r = 0; r < 4; r = r + 1)
          for (s = 0; s < 576; s = s + 1)
            for (k = 0; k < 5; k = k + 1) begin
                h = hs[k];
                if (s + h - 1 > 575) e = 575; else e = s + h - 1;
                @(negedge clk); ratio = r[1:0]; sy = s[11:0]; ey = e[11:0];
                @(negedge clk); @(negedge clk);
                n = n + 1;
                if (^off === 1'bx) fail("x", "X on off");
                if (r == 0 || r == 3) begin
                    if (off !== 12'sd0) fail("none", "nonzero offset with no conversion");
                end else begin
                    if (off[0] !== 1'b0) fail("even", "odd offset");
                    if (e - off > 479) fail("screen", "box runs off the bottom of the raster");
                    // where the scaled picture shows source row s, times 2 (exact rational):
                    // 5/6 -> 5s/6, 5/8 -> 60 + 5s/8
                    top_x2 = (r == 1) ? (10 * s) / 6 : 120 + (10 * s) / 8;
                    raster_top = s - off;
                    if (e - (s - (top_x2 / 2)) <= 479) begin           // natural place fits
                        if (2 * raster_top < top_x2 - 4 || 2 * raster_top > top_x2 + 2)
                            fail("place", "top is not where the picture shows row sy");
                    end
                end
            end
        $display("  [sub_anchor] %0d cases", n);
        if (f_x)      $display("FAIL [x] %0d cases", f_x);
        if (f_none)   $display("FAIL [none] %0d cases", f_none);
        if (f_even)   $display("FAIL [even] %0d cases", f_even);
        if (f_screen) $display("FAIL [screen] %0d cases", f_screen);
        if (f_place)  $display("FAIL [place] %0d cases", f_place);
        if (fails) $fatal(1, "sub_anchor_tb: %0d failures", fails);
        $display("PASS sub_anchor_tb");
        $finish;
    end
endmodule
