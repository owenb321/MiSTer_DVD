// -----------------------------------------------------------------
// bench/dvd/i2s_iec958_tb.sv
// Proves the HDMI IEC958-direct path carries the same subframes the S/PDIF
// biphase encoder does.
//
// The check is a DEMODULATOR, not a register peek: it recovers 32-bit subframes
// off sck_o/ws_o/sd_o the way the ADV7513 would, then compares the audio field
// against the samples that were fed in. Bit order (LSB/timeslot first) and
// channel mapping are the two things that fail silently here - "receiver names
// the format but plays static" - so they have to be read back off the wire.
// -----------------------------------------------------------------
`timescale 1ns/1ps

module i2s_iec958_tb;

    reg  clk = 0, rst_n = 0;
    always #20.3 clk = ~clk;              // 24.576 MHz

    // 6.144 MHz enable, 1-in-4 - the same strobe spdif_pass runs on
    reg [1:0] ce_cnt = 0;
    always @(posedge clk) ce_cnt <= ce_cnt + 2'd1;
    wire ce = (ce_cnt == 2'd0);

    reg  [31:0] sample = 32'd0;           // {R, L}
    reg         nonpcm = 1'b1;
    wire [31:0] sub_w;
    wire        sub_load, sample_req, spdif_o;

    spdif_pass u_sp (
        .clk_i(clk), .rst_i(~rst_n), .bit_out_en_i(ce),
        .spdif_o(spdif_o), .nonpcm_i(nonpcm),
        .sample_i(sample), .sample_req_o(sample_req),
        .sub_w_o(sub_w), .sub_load_o(sub_load)
    );

    wire sck, ws, sd;
    i2s_iec958 u_i2s (
        .clk(clk), .rst_n(rst_n), .ce_i(ce),
        .sub_w_i(sub_w), .sub_load_i(sub_load),
        .sck_o(sck), .ws_o(ws), .sd_o(sd)
    );

    // feed a fresh known pair each time the encoder asks for one
    integer pair_n = 0;
    always @(posedge clk) if (sample_req) begin
        pair_n <= pair_n + 1;
        sample <= {16'hA000 + pair_n[15:0], 16'h5000 + pair_n[15:0]};
    end

    // ---- demodulator: recover subframes off the wire ------------------------
    reg  [31:0] acc;
    integer     nbits = 0;
    reg         sck_d = 0;
    reg  [31:0] rec_q  [0:255];
    reg         rec_ws [0:255];
    integer     rec_n = 0;

    // Frame on ws the way a receiver does, rather than free-running a bit count
    // from reset - otherwise a single hiccup slips the framing permanently and
    // every later subframe reads as garbage.
    reg ws_d = 0;
    always @(posedge clk) begin
        sck_d <= sck;
        ws_d  <= ws;
        if (!rst_n) begin
            nbits = 0; acc = 32'd0;
        end else begin
            if (ws != ws_d) begin                // subframe boundary: resync
                nbits = 0; acc = 32'd0;
            end
            if (sck && !sck_d) begin             // rising sck: sample the line
                acc = {sd, acc[31:1]};           // LSB-first fill
                nbits = nbits + 1;
                if (nbits == 32) begin
                    if (rec_n < 256) begin
                        rec_q[rec_n]  = acc;
                        rec_ws[rec_n] = ws;
                    end
                    rec_n = rec_n + 1;
                    nbits = 0;
                end
            end
        end
    end

    integer errors = 0, i;
    integer chkA = 0, chkB = 0, badpar = 0, badpre = 0;
    reg [31:0] w;

    initial begin
        repeat (8) @(posedge clk);
        rst_n = 1;

        // let a couple of channel-status blocks go by
        repeat (200000) @(posedge clk);

        $display("i2s_iec958_tb: recovered %0d subframes", rec_n);
        if (rec_n < 64) begin
            $display("  FAIL: serializer produced almost nothing (%0d)", rec_n);
            errors = errors + 1;
        end

        // Skip the first few (reset re-phase, and the demod locks mid-subframe
        // until the first full 32-bit window completes).
        for (i = 4; i < (rec_n > 200 ? 200 : rec_n); i = i + 1) begin
            w = rec_q[i];

            // preamble code must be one of the three one-hot values
            if (w[3:0] !== 4'b0001 && w[3:0] !== 4'b0010 && w[3:0] !== 4'b0100)
                badpre = badpre + 1;

            // even parity over timeslots 4..31
            if (^w[31:4] !== 1'b0) badpar = badpar + 1;

            // channel A carries the low (left) word, B the high (right) word
            if (w[3:0] == 4'b0010) chkB = chkB + 1; else chkA = chkA + 1;
        end

        if (badpre != 0) begin
            $display("  FAIL: %0d subframes with a bogus preamble code", badpre);
            errors = errors + 1; end
        if (badpar != 0) begin
            $display("  FAIL: %0d subframes with bad even parity", badpar);
            errors = errors + 1; end
        if (chkA == 0 || chkB == 0) begin
            $display("  FAIL: only one channel present (A=%0d B=%0d)", chkA, chkB);
            errors = errors + 1; end

        // The audio field of consecutive A/B subframes must be the 0x5000/0xA000
        // pattern that was fed in, proving LSB-first order and channel mapping.
        chkA = 0;
        for (i = 4; i < (rec_n > 200 ? 200 : rec_n); i = i + 1) begin
            w = rec_q[i];
            if (w[3:0] == 4'b0010) begin
                if (w[27:24] !== 4'hA) chkA = chkA + 1;   // channel B = right = 0xAxxx
            end else begin
                if (w[27:24] !== 4'h5) chkA = chkA + 1;   // channel A = left  = 0x5xxx
            end
        end
        if (chkA != 0) begin
            $display("  FAIL: %0d subframes with the wrong channel's audio -", chkA);
            $display("        bit order or A/B mapping is inverted");
            errors = errors + 1; end

        if (errors == 0) $display("\nPASS: i2s_iec958");
        else begin $display("\n%0d FAILURES", errors); $fatal(1, "i2s_iec958_tb failed"); end
        $finish;
    end

    initial begin
        #40_000_000;
        $display("TIMEOUT");
        $fatal(1, "i2s_iec958_tb timeout");
    end

endmodule
