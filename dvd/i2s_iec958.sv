// -----------------------------------------------------------------
// dvd/i2s_iec958.sv  —  IEC 60958 subframes over the ADV7513's I2S input
// -----------------------------------------------------------------
// Clocks the parallel IEC 60958 subframes produced by dvd/spdif_pass.sv onto a
// serial data line in the ADV7513's "IEC958 direct" I2S format (register
// 0x0C[1:0] = 3), so the SAME IEC 61937 data-burst that leaves over optical
// S/PDIF also leaves over HDMI and an AV receiver decodes DD/DTS 5.1 with no
// Digital I/O board. See docs/hdmi_bitstream.md.
//
// WHY THIS FORMAT rather than plain 16-bit I2S plus an I2C "non-PCM" register:
// in IEC958-direct the channel status travels INSIDE the subframe, so the
// non-PCM bit stays DYNAMIC exactly as it is on S/PDIF. That is the fj#110
// ROUND 2 behaviour (receivers could not acquire across non-PCM null bursts, so
// holds present real linear-PCM silence and there is one clean PCM->non-PCM
// switch when the burst starts). Pinning the flag high for a whole session -
// which is all an I2C channel-status register can do - would put us back in the
// regime that fix exists to avoid. The mainline Linux ADV7511 driver reaches for
// this same mode for IEC958 subframe data.
//
// FORMAT (per IEC 60958):
//   64 bits per frame = two 32-bit subframes, channel A (left) then channel B.
//   Bits leave in TIMESLOT order, i.e. LSB (timeslot 0) FIRST - the opposite of
//   sys/i2s.v, which is MSB-first PCM. Getting this backwards is silent garbage,
//   so bench/dvd/i2s_iec958_tb.sv demodulates the wire rather than trusting it.
//
// CLOCKING (clk_audio = 24.576 MHz = 512 x 48 kHz):
//   ce_i     6.144 MHz (1-in-4)  — same strobe spdif_pass runs on
//   sck_o    3.072 MHz = 64 x Fs — one ce toggles it, so 2 ce per bit
//   ws_o     48.000 kHz          — 64 bits per frame = 512 clk_audio
// The frame period is therefore EXACTLY the framework's I2S frame period, which
// is what lets sys_top swap the two sources on a pin without a rate change.
// MCLK is untouched (clk_audio = 512.Fs either way).
//
// ⚠ The data line is only ever muxed onto the pin while the HPS has put the
// ADV7513 into IEC958-direct mode (the cfg[14] ack). A sink told to expect PCM
// would render this as full-scale noise.
// -----------------------------------------------------------------

`timescale 1ns/1ps

module i2s_iec958 (
    input  wire        clk,        // clk_audio, 24.576 MHz
    input  wire        rst_n,      // async, active-low
    input  wire        ce_i,       // 6.144 MHz enable (2 per sck period)

    // Parallel subframe source (dvd/spdif_pass.sv exports)
    input  wire [31:0] sub_w_i,    // timeslot order: [3:0] preamble code .. [31] parity
    input  wire        sub_load_i, // 1 clk pulse: sub_w_i is the new subframe
    input  wire        sub_chb_i,  // 0 = channel A (left), 1 = channel B

    // ⚠ HW A/B for the two things the Programming Guide would have told us.
    // [0] bit order : 0 = LSB/timeslot first (IEC 60958 on the wire), 1 = MSB first
    //                 (what plain I2S does, which the chip may expect instead)
    // [1] legacy    : 0 = documented format (block-start flag in [31], preamble
    //                 slots zeroed - Programming Guide §4.4.1.1), 1 = the old
    //                 pre-document guess (parity in [31], one-hot preamble code),
    //                 kept only so the fix can be A/B'd against what failed.
    // [2] transport: 0 = AES3-direct 32-bit subframes (this module's own
    //                serializer), 1 = PLAIN 16-BIT STANDARD I2S carrying the raw
    //                61937 words, with the ADV7513 supplying channel status from
    //                its I2C registers (0x0C[6]=1, non-PCM in 0x12[7]). That
    //                route needs none of the subframe machinery and reuses the
    //                framework's proven serializer - see docs/hdmi_bitstream.md.
    input  wire [2:0]  variant_i,
    input  wire [15:0] pcm_l_i,     // raw 61937 words for the 16-bit route
    input  wire [15:0] pcm_r_i,

    // Serial output to the ADV7513
    output wire        sck_o,      // bit clock
    output wire        ws_o,       // 48 kHz word select: 0 = channel A, 1 = B
    output wire        sd_o        // serial data
);

    // ---- route (i): plain 16-bit standard I2S -------------------------------
    // sys/i2s.v is the framework's own serializer, already carrying PCM to this
    // exact chip every day, so it is the least risky way to present the words.
    // It needs ce = 2 x BCLK = 64 x Fs = 3.072 MHz; bit_ce here is 6.144 MHz.
    reg  ce_div;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)   ce_div <= 1'b0;
        else if (ce_i) ce_div <= ~ce_div;
    wire ce16 = ce_i & ce_div;

    wire pcm_sck, pcm_ws, pcm_sd;
    i2s u_pcm16 (
        .reset(~rst_n), .clk(clk), .ce(ce16),
        .sclk(pcm_sck), .lrclk(pcm_ws), .sdata(pcm_sd),
        .left_chan(pcm_l_i), .right_chan(pcm_r_i)
    );

    reg  aes_sck, aes_ws, aes_sd;
    assign sck_o = variant_i[2] ? pcm_sck : aes_sck;
    assign ws_o  = variant_i[2] ? pcm_ws  : aes_ws;
    assign sd_o  = variant_i[2] ? pcm_sd  : aes_sd;

    // Shift register and bit counter. spdif_pass emits one subframe per 64 of
    // its bit strobes; we emit one per 32 sck = 64 ce, so the two stay in
    // lockstep off the same load pulse with no handshake.
    reg [31:0] shift_q;
    reg [5:0]  bit_cnt;   // 0..31 within the subframe
    reg        msck;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_q <= 32'd0;
            bit_cnt <= 6'd0;
            msck    <= 1'b0;
            aes_sck <= 1'b0;
            aes_ws  <= 1'b0;
            aes_sd  <= 1'b0;
        end else begin
            // sck follows msck one clk later, so sd_o changes on the FALLING
            // sck edge and the receiver samples it on the rising edge - the
            // same convention sys/i2s.v uses.
            aes_sck <= msck;

            if (sub_load_i) begin
                // Re-arm on the producer's boundary. This is what keeps the two
                // serializers frame-aligned across a reset re-phase instead of
                // free-running into a slip.
                // sub_w_i already carries the documented format. The legacy
                // option reconstructs the pre-document guess for comparison:
                // even parity over 4..31 back into [31], one-hot code into [3:0].
                shift_q <= variant_i[1]
                         ? {^sub_w_i[30:4], sub_w_i[30:4], 4'b0100}
                         : sub_w_i;
                bit_cnt <= 6'd0;
                msck    <= 1'b0;
                // ⚠ ws MUST come from spdif_pass, not from the word. The
                // documented AES3-direct format has no preamble, so the word no
                // longer identifies the channel - deriving ws from it left ws
                // stuck at 0 (no word select at all), which is a silent and
                // total failure.
                aes_ws  <= sub_chb_i;
            end else if (ce_i) begin
                msck <= ~msck;
                // Advance on the rising half so the bit is presented for a full
                // sck period.
                if (msck) begin
                    shift_q <= variant_i[0] ? {shift_q[30:0], 1'b0}   // MSB first
                                            : {1'b0, shift_q[31:1]};  // LSB first
                    bit_cnt <= bit_cnt + 6'd1;
                end else begin
                    aes_sd <= variant_i[0] ? shift_q[31] : shift_q[0];
                end
            end
        end
    end

endmodule
