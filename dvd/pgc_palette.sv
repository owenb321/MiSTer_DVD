// pgc_palette.sv — DVD PGC colour lookup table (YCbCr -> RGB), Phase-1 disc menus
// Part of MiSTer DVD Player Core
//
// A DVD subpicture (and menu button highlight) references colours by 4-bit index
// into the 16-entry palette carried in the PGC header (IFO byte @164, 16 x 4B).
// Each raw entry is {reserved[7:0], Y[7:0], Cr[7:0], Cb[7:0]} (BIG-ENDIAN in the
// IFO; dvd_iso_reader streams it here as a 32-bit word {0,Y,Cr,Cb}). This module
// captures the 16 raw entries and converts them to 24-bit RGB so the display path
// only does a flat 16:1 lookup.
//
// AREA/HOTSPOT NOTE: the conversion is NOT done per-pixel. A single round-robin
// converter walks one entry per clk_sys cycle (cvt_i 0..15), so the whole table
// re-derives within 16 cycles of a palette load — long before any pixel query that
// matters — using ONE small constant-coefficient multiply datapath (shared across
// all 16 entries). The per-pixel side is just `rgb[idx]`, 16 registers -> a 16:1
// mux the caller pipelines. This keeps the display-path (X33_Y11..X44_Y22) cost to
// a plain mux, not a colour-space converter.
//
// Conversion: BT.601 studio-swing (DVD is limited-range Y in [16,235]):
//   R = 1.164(Y-16) + 1.596(Cr-128)
//   G = 1.164(Y-16) - 0.392(Cb-128) - 0.813(Cr-128)
//   B = 1.164(Y-16) + 2.017(Cb-128)
// fixed-point (x256): 1.164->298, 1.596->409, 0.392->100, 0.813->208, 2.017->516.

`default_nettype none

module pgc_palette (
    input  wire        clk,
    input  wire        rst_n,

    // Palette write port from dvd_iso_reader (streamed at PGC load, 16 words).
    input  wire        pal_we,
    input  wire [3:0]  pal_waddr,       // entry 0..15
    input  wire [31:0] pal_wdata,       // {reserved[31:24], Y[23:16], Cr[15:8], Cb[7:0]}

    // Per-index RGB lookup (combinational; caller registers/pipelines it).
    input  wire [3:0]  idx,
    output wire [7:0]  rgb_r,
    output wire [7:0]  rgb_g,
    output wire [7:0]  rgb_b
);
    // Raw {Y, Cr, Cb} store (written 1 entry/cycle by the reader).
    reg [7:0] raw_y  [0:15];
    reg [7:0] raw_cr [0:15];
    reg [7:0] raw_cb [0:15];

    // Converted RGB (the display-path lookup table).
    reg [7:0] r_mem [0:15];
    reg [7:0] g_mem [0:15];
    reg [7:0] b_mem [0:15];

    assign rgb_r = r_mem[idx];
    assign rgb_g = g_mem[idx];
    assign rgb_b = b_mem[idx];

    // Round-robin converter cursor.
    reg [3:0] cvt_i;

    // Signed differences for the current entry.
    wire signed [9:0] yt  = $signed({2'b00, raw_y [cvt_i]}) - 10'sd16;   // Y-16  (>=0 clamp below)
    wire signed [9:0] crm = $signed({2'b00, raw_cr[cvt_i]}) - 10'sd128;  // Cr-128
    wire signed [9:0] cbm = $signed({2'b00, raw_cb[cvt_i]}) - 10'sd128;  // Cb-128
    wire signed [9:0] ycl = (yt < 0) ? 10'sd0 : yt;                      // clamp Y-16 at 0

    wire signed [31:0] r_acc = 298*ycl + 409*crm;
    wire signed [31:0] g_acc = 298*ycl - 100*cbm - 208*crm;
    wire signed [31:0] b_acc = 298*ycl + 516*cbm;

    // Arithmetic shift back down by 8, then clamp to [0,255].
    function automatic [7:0] clip8(input signed [31:0] v);
        logic signed [23:0] s;
        begin
            s = v >>> 8;
            if      (s < 0)         clip8 = 8'd0;
            else if (s > 24'sd255) clip8 = 8'd255;
            else                    clip8 = s[7:0];
        end
    endfunction

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cvt_i <= 4'd0;
            // Default: entry 0 black, entry 1 white, 2..15 a neutral grayscale ramp
            // (all chroma-neutral). So a SPU shown before/without a PGC palette load
            // (rare: palette straddles the PGC sector) still renders legibly with the
            // spu_decode identity col map, rather than black-on-black. Round-robin
            // conversion below keeps r/g/b in sync with these raws.
            for (k = 0; k < 16; k = k + 1) begin
                raw_cr[k] <= 8'd128; raw_cb[k] <= 8'd128;   // neutral chroma
                raw_y [k] <= (k == 0) ? 8'd16 : (8'd16 + k[3:0] * 8'd15);
                r_mem [k] <= 8'd0;  g_mem [k] <= 8'd0;   b_mem [k] <= 8'd0;
            end
        end else begin
            if (pal_we) begin
                raw_y [pal_waddr] <= pal_wdata[23:16];
                raw_cr[pal_waddr] <= pal_wdata[15:8];
                raw_cb[pal_waddr] <= pal_wdata[7:0];
            end
            // Convert one entry per cycle (round-robin, continuous).
            r_mem[cvt_i] <= clip8(r_acc);
            g_mem[cvt_i] <= clip8(g_acc);
            b_mem[cvt_i] <= clip8(b_acc);
            cvt_i        <= cvt_i + 4'd1;
        end
    end

endmodule

`default_nettype wire
