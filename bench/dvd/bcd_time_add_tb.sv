// bcd_time_add_tb.sv -- vectors for the combinational BCD dvd_time adder.
// Reference model in plain integers; covers second/minute/hour carries, the
// 119-second overflow case, and both frame rates (25 fps rate=01, 30 fps
// rate=11) including the frame->second carry.
// Run: iverilog -g2012 -o /tmp/bta_sim dvd/bcd_time_add.sv bench/dvd/bcd_time_add_tb.sv
`timescale 1ns/1ps

module bcd_time_add_tb;

    reg  [31:0] a, b;
    wire [31:0] sum;
    bcd_time_add dut (.a(a), .b(b), .sum(sum));

    integer errors = 0;

    function [7:0] to_bcd(input integer v);
        begin to_bcd = ((v / 10) << 4) | (v % 10); end
    endfunction
    function integer fr_bcd(input [7:0] v);
        begin fr_bcd = v[7:4] * 10 + v[3:0]; end
    endfunction

    task check(input integer ah, am, as, af,
               input integer bh, bm, bs, bf,
               input [1:0] rate);
        integer fps, tot_a, tot_b, tot, wh, wm, ws, wf;
        reg [7:0] faf, fbf;
        begin
            fps = (rate == 2'b01) ? 25 : 30;
            faf = to_bcd(af); fbf = to_bcd(bf);
            a = {to_bcd(ah), to_bcd(am), to_bcd(as), 2'b00, faf[5:0]};
            b = {to_bcd(bh), to_bcd(bm), to_bcd(bs), rate,  fbf[5:0]};
            #1;
            tot_a = ((ah*60 + am)*60 + as)*fps + af;
            tot_b = ((bh*60 + bm)*60 + bs)*fps + bf;
            tot = tot_a + tot_b;
            wf = tot % fps; tot = tot / fps;
            ws = tot % 60;  tot = tot / 60;
            wm = tot % 60;  wh = tot / 60;
            if (fr_bcd(sum[31:24]) !== wh || fr_bcd(sum[23:16]) !== wm ||
                fr_bcd(sum[15:8])  !== ws || fr_bcd({2'b00, sum[5:0]}) !== wf ||
                sum[7:6] !== rate)
            begin
                errors = errors + 1;
                $display("  FAIL %0d:%0d:%0d.%0d + %0d:%0d:%0d.%0d @%0dfps -> %h (want %0d:%0d:%0d.%0d)",
                         ah,am,as,af, bh,bm,bs,bf, fps, sum, wh,wm,ws,wf);
            end
        end
    endtask

    integer i;
    integer s1, s2, f1, f2;
    initial begin
        check(0,0,0,0,   0,0,0,0,   2'b11);
        check(0,12,34,0, 0,5,10,0,  2'b11);   // plain
        check(0,0,59,0,  0,0,1,0,   2'b11);   // second -> minute carry
        check(0,59,59,29, 0,0,0,1,  2'b11);   // full ripple -> hour
        check(1,59,59,0, 2,0,1,0,   2'b11);   // hour add
        check(0,30,45,15, 0,29,14,15, 2'b11); // frame carry at 30 fps
        check(0,30,45,15, 0,29,14,10, 2'b01); // frame carry at 25 fps
        check(0,0,59,0,  0,0,60-1,0, 2'b11);  // 59+59 = 118 s (the +40 path)
        // randomized sweep
        for (i = 0; i < 500; i = i + 1) begin
            s1 = $urandom % 60; s2 = $urandom % 60;
            f1 = $urandom % 25; f2 = $urandom % 25;
            check($urandom % 10, $urandom % 60, s1, f1,
                  $urandom % 10, $urandom % 60, s2, f2,
                  ($urandom & 1) ? 2'b01 : 2'b11);
        end
        if (errors == 0) $display("BCD_TIME_ADD_TB: ALL TESTS PASSED");
        else             $display("BCD_TIME_ADD_TB: FAILED (%0d errors)", errors);
        $finish;
    end
endmodule
