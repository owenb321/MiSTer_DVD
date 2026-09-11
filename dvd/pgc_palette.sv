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
// AREA/HOTSPOT NOTE: the conversion is NOT done per-pixel. Each entry is
// converted ONCE, the cycle after the reader writes it (convert-on-write), by
// ONE small constant-coefficient multiply datapath. The per-pixel side is just
// `rgb[idx]`, 16 registers -> a 16:1 mux the caller pipelines. This keeps the
// display-path (X33_Y11..X44_Y22) cost to a plain mux, not a colour-space
// converter. (Area pass 2026-09-10: this used to be a free-running round-robin
// over a raw {Y,Cr,Cb} shadow of the table -- 384 flops plus three 16:1 read
// muxes whose only purpose was to feed that walk. Converting the entry being
// written removes the shadow outright; the reset defaults are now written
// pre-converted.)
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
    // Converted RGB (the display-path lookup table).
    reg [7:0] r_mem [0:15];
    reg [7:0] g_mem [0:15];
    reg [7:0] b_mem [0:15];

    assign rgb_r = r_mem[idx];
    assign rgb_g = g_mem[idx];
    assign rgb_b = b_mem[idx];

    // Convert-on-write pipeline: the entry the reader wrote last cycle.
    reg        cv_we;
    reg [3:0]  cv_addr;
    reg [7:0]  cv_y, cv_cr, cv_cb;

    // Signed differences for the entry being converted.
    wire signed [9:0] yt  = $signed({2'b00, cv_y })  - 10'sd16;   // Y-16  (>=0 clamp below)
    wire signed [9:0] crm = $signed({2'b00, cv_cr})  - 10'sd128;  // Cr-128
    wire signed [9:0] cbm = $signed({2'b00, cv_cb})  - 10'sd128;  // Cb-128
    wire signed [9:0] ycl = (yt < 0) ? 10'sd0 : yt;               // clamp Y-16 at 0

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

    // Reset default, PRE-CONVERTED: entry 0 black, then the chroma-neutral
    // grayscale ramp Y = 16 + 15k that the old raw defaults converted to --
    // R = G = B = clip8(298 * 15k) (crm = cbm = 0), i.e. entries 1..15 =
    // 17 34 52 69 87 104 122 139 157 174 192 209 226 244 255. Same table the
    // round-robin used to produce, just present from the first cycle instead
    // of the 16th. A literal, not a function: Quartus 17 has miscompiled small
    // functions in this project before.
    localparam [127:0] RAMP_TBL = {8'd255, 8'd244, 8'd226, 8'd209, 8'd192, 8'd174, 8'd157, 8'd139, 8'd122, 8'd104, 8'd87, 8'd69, 8'd52, 8'd34, 8'd17, 8'd0};   // entry 15 .. entry 0

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cv_we   <= 1'b0;
            cv_addr <= 4'd0;
            cv_y    <= 8'd0; cv_cr <= 8'd128; cv_cb <= 8'd128;
            // Default (see RAMP_TBL): a SPU shown before/without a PGC palette load
            // (rare: palette straddles the PGC sector) still renders legibly
            // with the spu_decode identity col map, rather than black-on-black.
            for (k = 0; k < 16; k = k + 1) begin
                r_mem[k] <= RAMP_TBL[k*8 +: 8];
                g_mem[k] <= RAMP_TBL[k*8 +: 8];
                b_mem[k] <= RAMP_TBL[k*8 +: 8];
            end
        end else begin
            // Stage 1: capture the written entry.
            cv_we   <= pal_we;
            cv_addr <= pal_waddr;
            cv_y    <= pal_wdata[23:16];
            cv_cr   <= pal_wdata[15:8];
            cv_cb   <= pal_wdata[7:0];
            // Stage 2: convert it into the lookup table.
            if (cv_we) begin
                r_mem[cv_addr] <= clip8(r_acc);
                g_mem[cv_addr] <= clip8(g_acc);
                b_mem[cv_addr] <= clip8(b_acc);
            end
        end
    end

endmodule

`default_nettype wire
