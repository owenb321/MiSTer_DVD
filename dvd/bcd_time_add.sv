// ============================================================================
// dvd/bcd_time_add.sv -- combinational BCD dvd_time adder (Phase 11)
// ============================================================================
// sum = a (+) b for IFO/DSI `dvd_time_t` values: {hh, mm, ss, ff|rate}, every
// field 2-digit BCD; the frame byte carries the rate in bits [7:6] (2'b01 =
// 25 fps PAL, 2'b11 = 30 fps NTSC) and BCD frames in [5:0]. The frame fields
// are summed with a RATE-AWARE carry into seconds (fps taken from b's rate
// bits, which also pass through to the sum) so per-cell truncation cannot
// accumulate: this is what the reader's per-cell start-time prefix sum and
// emu's cell_start (+) c_eltm display sum both ride on. Pure combinational --
// both users evaluate it at event rate (cell parse / formatter snapshot),
// never per-pixel.
//
// Bounds: fields are valid BCD (ff<=29, ss/mm<=59); hh saturates silently at
// the 99 wrap (a DVD title never gets there). Used by dvd_iso_reader.sv and
// dvd/emu.sv; vectors in bench/dvd/bcd_time_add_tb.sv.
// ============================================================================

module bcd_time_add (
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire [31:0] sum
);

    // 2-digit BCD add -> {hundreds, tens[3:0], ones[3:0]}
    function [8:0] bcd8_add(input [7:0] x, input [7:0] y, input cin);
        reg [4:0] o, t;
        reg       c1;
        begin
            o  = {1'b0, x[3:0]} + {1'b0, y[3:0]} + {4'd0, cin};
            c1 = (o > 5'd9);
            if (c1) o = o - 5'd10;
            t  = {1'b0, x[7:4]} + {1'b0, y[7:4]} + {4'd0, c1};
            if (t > 5'd9) bcd8_add = {1'b1, t[3:0] - 4'd10, o[3:0]};
            else          bcd8_add = {1'b0, t[3:0], o[3:0]};
        end
    endfunction

    // 2-digit BCD subtract (x >= y guaranteed by the callers)
    function [7:0] bcd8_sub(input [7:0] x, input [7:0] y);
        reg [4:0] o;
        reg       br;
        begin
            br = (x[3:0] < y[3:0]);
            o  = br ? ({1'b0, x[3:0]} + 5'd10 - {1'b0, y[3:0]})
                    : ({1'b0, x[3:0]} - {1'b0, y[3:0]});
            bcd8_sub = {x[7:4] - y[7:4] - {3'd0, br}, o[3:0]};
        end
    endfunction

    // reduce a 9-bit BCD add result mod a BCD modulus m -> {carry, field}.
    // The 100..1xx overflow case only occurs for m = 8'h60 (ss/mm: max
    // 59+59+1 = 119): subtracting 60 there = ADDING 40 to the BCD digits.
    function [8:0] bcd_mod(input [8:0] v, input [7:0] m);
        reg [8:0] t;
        begin
            if (v[8]) begin
                t = bcd8_add(v[7:0], 8'h40, 1'b0);
                bcd_mod = {1'b1, t[7:0]};
            end
            else if (v[7:0] >= m)    bcd_mod = {1'b1, bcd8_sub(v[7:0], m)};
            else                     bcd_mod = {1'b0, v[7:0]};
        end
    endfunction

    wire [1:0] rate = b[7:6];
    wire [7:0] fps  = (rate == 2'b01) ? 8'h25 : 8'h30;   // PAL 25 else NTSC 30

    wire [8:0] ff_s = bcd_mod(bcd8_add({2'b00, a[5:0]}, {2'b00, b[5:0]}, 1'b0), fps);
    wire [8:0] ss_s = bcd_mod(bcd8_add(a[15:8],  b[15:8],  ff_s[8]), 8'h60);
    wire [8:0] mm_s = bcd_mod(bcd8_add(a[23:16], b[23:16], ss_s[8]), 8'h60);
    wire [8:0] hh_s = bcd8_add(a[31:24], b[31:24], mm_s[8]);

    assign sum = {hh_s[7:0], mm_s[7:0], ss_s[7:0], rate, ff_s[5:0]};

endmodule
