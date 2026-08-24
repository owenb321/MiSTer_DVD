// bench/dvd/pgc_palette_tb.sv — DVD PGC palette YCbCr->RGB LUT
//
//   iverilog -g2012 -o bench/dvd/pgc_palette_sim dvd/pgc_palette.sv bench/dvd/pgc_palette_tb.sv
//   vvp bench/dvd/pgc_palette_sim
//
// Writes 16 {0,Y,Cr,Cb} entries, lets the round-robin converter settle, then reads
// each index back and checks the RGB against a software reference of the same
// BT.601 studio-swing fixed-point math the RTL uses.
`timescale 1ns/1ps
`default_nettype none

module pgc_palette_tb;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0;

    logic        pal_we;
    logic [3:0]  pal_waddr;
    logic [31:0] pal_wdata;
    logic [3:0]  idx;
    wire  [7:0]  rgb_r, rgb_g, rgb_b;

    pgc_palette dut (
        .clk(clk), .rst_n(rst_n),
        .pal_we(pal_we), .pal_waddr(pal_waddr), .pal_wdata(pal_wdata),
        .idx(idx), .rgb_r(rgb_r), .rgb_g(rgb_g), .rgb_b(rgb_b)
    );

    // software reference (matches RTL: 298/409/100/208/516, >>>8, clamp 0..255)
    function automatic [7:0] clip8(input int v);
        begin
            if      (v < 0)   clip8 = 8'd0;
            else if (v > 255) clip8 = 8'd255;
            else              clip8 = v[7:0];
        end
    endfunction
    function automatic [7:0] ref_r(input int Y, Cr, Cb);
        int yt; begin yt = (Y<16)?0:(Y-16); ref_r = clip8((298*yt + 409*(Cr-128)) >>> 8); end
    endfunction
    function automatic [7:0] ref_g(input int Y, Cr, Cb);
        int yt; begin yt = (Y<16)?0:(Y-16); ref_g = clip8((298*yt - 100*(Cb-128) - 208*(Cr-128)) >>> 8); end
    endfunction
    function automatic [7:0] ref_b(input int Y, Cr, Cb);
        int yt; begin yt = (Y<16)?0:(Y-16); ref_b = clip8((298*yt + 516*(Cb-128)) >>> 8); end
    endfunction

    // test entries {Y,Cr,Cb}
    int Yv[0:15]; int Crv[0:15]; int Cbv[0:15];
    int errors = 0;
    integer i;

    task automatic wr(input [3:0] a, input int Y, Cr, Cb);
        begin
            @(negedge clk);
            pal_we = 1; pal_waddr = a; pal_wdata = {8'd0, Y[7:0], Cr[7:0], Cb[7:0]};
            @(negedge clk); pal_we = 0;
        end
    endtask

    initial begin
        pal_we = 0; pal_waddr = 0; pal_wdata = 0; idx = 0;
        // a spread of colours incl. the extremes (black/white) + mid chroma
        Yv[0]=16;  Crv[0]=128; Cbv[0]=128;   // black
        Yv[1]=235; Crv[1]=128; Cbv[1]=128;   // white
        Yv[2]=81;  Crv[2]=239; Cbv[2]=90;    // red-ish
        Yv[3]=145; Crv[3]=34;  Cbv[3]=54;    // green-ish
        Yv[4]=41;  Crv[4]=110; Cbv[4]=240;   // blue-ish
        Yv[5]=210; Crv[5]=146; Cbv[5]=16;    // yellow-ish
        for (i = 6; i < 16; i = i + 1) begin
            Yv[i]=16+i*13; Crv[i]=(i*20)&8'hFF; Cbv[i]=(255-i*15)&8'hFF;
        end

        repeat (3) @(posedge clk); rst_n = 1; @(posedge clk);

        for (i = 0; i < 16; i = i + 1) wr(i[3:0], Yv[i], Crv[i], Cbv[i]);

        // let the round-robin converter refresh all 16 entries
        repeat (40) @(posedge clk);

        for (i = 0; i < 16; i = i + 1) begin
            idx = i[3:0]; #1;
            if (rgb_r !== ref_r(Yv[i],Crv[i],Cbv[i]) ||
                rgb_g !== ref_g(Yv[i],Crv[i],Cbv[i]) ||
                rgb_b !== ref_b(Yv[i],Crv[i],Cbv[i])) begin
                $display("  FAIL idx=%0d Y=%0d Cr=%0d Cb=%0d -> got %02h,%02h,%02h exp %02h,%02h,%02h",
                         i,Yv[i],Crv[i],Cbv[i], rgb_r,rgb_g,rgb_b,
                         ref_r(Yv[i],Crv[i],Cbv[i]),ref_g(Yv[i],Crv[i],Cbv[i]),ref_b(Yv[i],Crv[i],Cbv[i]));
                errors++;
            end
        end

        // spot sanity: entry 0 = black (exact 0), entry 1 = near-white (studio-swing
        // Y=235 -> 1.164*219 = 254.9 -> 254 floored, NOT 255).
        idx = 0; #1; if (rgb_r!==8'd0 || rgb_g!==8'd0 || rgb_b!==8'd0) begin $display("  FAIL entry0 not black"); errors++; end
        idx = 1; #1; if (rgb_r < 8'd250 || rgb_g < 8'd250 || rgb_b < 8'd250) begin $display("  FAIL entry1 not near-white (%02h,%02h,%02h)",rgb_r,rgb_g,rgb_b); errors++; end

        if (errors == 0) $display("RESULT: PASS (pgc_palette YCbCr->RGB matches reference, 16 entries)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin #100000; $display("RESULT: FAIL timeout"); $finish; end
endmodule

`default_nettype wire
