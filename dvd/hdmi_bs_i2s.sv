// -----------------------------------------------------------------
// dvd/hdmi_bs_i2s.sv  —  the HDMI leg of IEC 61937 bitstream passthrough
// -----------------------------------------------------------------
// Clocks the raw IEC 61937 words onto the ADV7513's I2S input as plain 16-bit
// standard I2S, so the SAME data-burst that leaves over optical S/PDIF also
// leaves over HDMI and an AV receiver decodes DD/DTS 5.1 with no Digital I/O
// board. ✅ HW-CONFIRMED 2026-08-31 (DD and DTS both decode).
//
// The chip is what marks the stream as compressed: MiSTer_DVDcss sets channel
// status from the ADV7513 register map (0x0C[6]=1) with the non-PCM bit in
// 0x12[7] — "audio sample word", Programming Guide Table 84. The core never
// emits a bitstream without that ack, so a stock Main cannot be fed one.
//
// WHY THIS AND NOT THE CHIP'S "IEC958 direct" MODE: that route was built,
// documented from the Programming Guide, sim-correct, and never produced a
// decodable stream across four hardware rounds. It has been removed rather than
// carried as dead weight; the full finding — including the exact AES3 subframe
// format, the block-start flag and why the receiver never synced — is preserved
// in docs/hdmi_bitstream.md. Rebuild from there if a future sink ever needs it.
//
// CLOCKING (clk_audio = 24.576 MHz = 512 x Fs): sys/i2s.v wants ce = 2 x BCLK =
// 64 x Fs = 3.072 MHz, and ce_i here is the wrapper's 6.144 MHz bit strobe, so
// it is halved. The resulting frame is exactly 512 clk — the same period as the
// framework's own I2S frame, which is what lets sys_top swap sources on a pin
// with no rate change. MCLK is untouched either way.
//
// ⚠ These outputs only reach the pins while the HPS ack is set. A sink told to
// expect PCM would render a bitstream as full-scale noise.
// -----------------------------------------------------------------

`timescale 1ns/1ps

module hdmi_bs_i2s (
    input  wire        clk,        // clk_audio, 24.576 MHz
    input  wire        rst_n,      // async, active-low
    input  wire        ce_i,       // 6.144 MHz enable

    input  wire [15:0] pcm_l_i,    // raw 61937 words, low  (first) of the pair
    input  wire [15:0] pcm_r_i,    // ...              high (second)

    // Serial output to the ADV7513
    output wire        sck_o,      // bit clock
    output wire        ws_o,       // 48 kHz word select: 0 = left, 1 = right
    output wire        sd_o        // serial data
);

    reg ce_div;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)    ce_div <= 1'b0;
        else if (ce_i) ce_div <= ~ce_div;
    wire ce16 = ce_i & ce_div;

    // sys/i2s.v is the framework's own serializer — it already carries PCM to
    // this exact chip every day, which is why the words are handed to it rather
    // than to anything written here.
    i2s u_i2s (
        .reset(~rst_n), .clk(clk), .ce(ce16),
        .sclk(sck_o), .lrclk(ws_o), .sdata(sd_o),
        .left_chan(pcm_l_i), .right_chan(pcm_r_i)
    );

endmodule
