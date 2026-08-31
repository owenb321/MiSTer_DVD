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

    // ⚠ HW A/B for the two things the Programming Guide would have told us.
    // [0] bit order : 0 = LSB/timeslot first (IEC 60958 on the wire), 1 = MSB first
    //                 (what plain I2S does, which the chip may expect instead)
    // [1] preamble  : 0 = one-hot code in [3:0], 1 = zeroed, letting the chip
    //                 derive framing from ws + its own 192-frame counter
    // HW round 1 got "decoder off" from the receiver: the chip HAD switched to
    // IEC958-direct (it stopped reporting PCM) but could not find 61937 sync, so
    // one of these two is wrong. Four combinations, one build.
    input  wire [1:0]  variant_i,

    // Serial output to the ADV7513
    output reg         sck_o,      // 3.072 MHz bit clock
    output reg         ws_o,       // 48 kHz word select: 0 = channel A, 1 = B
    output reg         sd_o        // serial data, LSB (timeslot 0) first
);

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
            sck_o   <= 1'b0;
            ws_o    <= 1'b0;
            sd_o    <= 1'b0;
        end else begin
            // sck follows msck one clk later, so sd_o changes on the FALLING
            // sck edge and the receiver samples it on the rising edge - the
            // same convention sys/i2s.v uses.
            sck_o <= msck;

            if (sub_load_i) begin
                // Re-arm on the producer's boundary. This is what keeps the two
                // serializers frame-aligned across a reset re-phase instead of
                // free-running into a slip.
                shift_q <= variant_i[1] ? {sub_w_i[31:4], 4'd0} : sub_w_i;
                bit_cnt <= 6'd0;
                msck    <= 1'b0;
                // spdif_pass loads channel A on even subframe counts; its
                // preamble code distinguishes them, and ws follows the same
                // parity so the ADV7513 sees a conventional word select.
                ws_o    <= (sub_w_i[3:0] == 4'b0010);   // Y(W) = channel B
            end else if (ce_i) begin
                msck <= ~msck;
                // Advance on the rising half so the bit is presented for a full
                // sck period.
                if (msck) begin
                    shift_q <= variant_i[0] ? {shift_q[30:0], 1'b0}   // MSB first
                                            : {1'b0, shift_q[31:1]};  // LSB first
                    bit_cnt <= bit_cnt + 6'd1;
                end else begin
                    sd_o <= variant_i[0] ? shift_q[31] : shift_q[0];
                end
            end
        end
    end

endmodule
