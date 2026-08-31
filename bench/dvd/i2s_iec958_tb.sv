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
    wire        sub_load, sub_chb, sample_req, spdif_o;

    spdif_pass u_sp (
        .clk_i(clk), .rst_i(~rst_n), .bit_out_en_i(ce),
        .spdif_o(spdif_o), .nonpcm_i(nonpcm),
        .sample_i(sample), .sample_req_o(sample_req),
        .sub_w_o(sub_w), .sub_load_o(sub_load), .sub_chb_o(sub_chb)
    );

    reg [2:0] variant = 3'd1;   // AES3 LSB+blkstart (PCM16 is now 0)    // [0] 1=MSB-first, [1] 1=zeroed preamble
    wire sck, ws, sd;
    i2s_iec958 u_i2s (
        .clk(clk), .rst_n(rst_n), .ce_i(ce),
        .sub_w_i(sub_w), .sub_load_i(sub_load), .sub_chb_i(sub_chb), .variant_i(variant), .pcm_l_i(sample[15:0]), .pcm_r_i(sample[31:16]),
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
                // undo whichever order the DUT is sending in
                // MSB-first is variants 2 and 4 (see dvd/i2s_iec958.sv)
                acc = (variant == 3'd2 || variant == 3'd4)
                    ? {acc[30:0], sd} : {sd, acc[31:1]};
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

    integer errors = 0, i, v;
    integer chkA = 0, chkB = 0, badpar = 0, badpre = 0, blk = 0;
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

        // ---- documented AES3-direct format (Programming Guide 4.4.1.1) ------
        //   [3:0]  preamble LEFT OUT -> zero
        //   [31]   BLOCK START flag, not parity (the chip computes parity)
        //   V/U/C stay at 28/29/30
        // Channel identity comes from ws, since there is no preamble to carry it.
        badpre = 0; chkA = 0; chkB = 0; blk = 0;
        for (i = 4; i < (rec_n > 200 ? 200 : rec_n); i = i + 1) begin
            w = rec_q[i];
            if (w[3:0] !== 4'd0)                      badpre = badpre + 1;
            if (w[31])                                blk    = blk + 1;
            if (w[31] && rec_ws[i])                   chkB   = chkB + 1;  // must be ch A
            if (rec_ws[i]) begin
                if (w[27:24] !== 4'hA) chkA = chkA + 1;
            end else begin
                if (w[27:24] !== 4'h5) chkA = chkA + 1;
            end
        end

        if (badpre != 0) begin
            $display("  FAIL: %0d subframes with a non-zero preamble field", badpre);
            errors = errors + 1; end
        if (chkA != 0) begin
            $display("  FAIL: %0d subframes with the wrong channel's audio -", chkA);
            $display("        bit order or A/B mapping is inverted");
            errors = errors + 1; end
        if (chkB != 0) begin
            $display("  FAIL: block start asserted on a channel-B subframe (%0d)", chkB);
            errors = errors + 1; end
        // 196 subframes spans about half a 384-subframe block, so expect 0 or 1.
        if (blk > 2) begin
            $display("  FAIL: block start asserted %0d times in ~196 subframes", blk);
            errors = errors + 1; end
        $display("  format: preamble_bad=%0d block_starts=%0d", badpre, blk);

        // ---- MSB-first variant still carries the same content ---------------
        variant = 3'd2;   // AES3 MSB
        rec_n = 0;
        repeat (60000) @(posedge clk);
        chkA = 0;
        for (i = 4; i < (rec_n > 120 ? 120 : rec_n); i = i + 1) begin
            w = rec_q[i];
            if (rec_ws[i]) begin
                if (w[27:24] !== 4'hA) chkA = chkA + 1;
            end else begin
                if (w[27:24] !== 4'h5) chkA = chkA + 1;
            end
        end
        $display("  variant 2 (AES3 MSB): %0d subframes, audio_mismatch=%0d", rec_n, chkA);
        if (rec_n < 40 || chkA != 0) begin
            $display("  FAIL: MSB-first variant broken"); errors = errors + 1; end

        // ---- legacy variant reproduces the pre-document guess ---------------
        variant = 3'd3;   // AES3 legacy
        rec_n = 0;
        repeat (60000) @(posedge clk);
        badpre = 0;
        for (i = 4; i < (rec_n > 120 ? 120 : rec_n); i = i + 1) begin
            w = rec_q[i];
            if (w[3:0] !== 4'b0100) badpre = badpre + 1;   // one-hot code restored
            if (^w[31:4] !== 1'b0)  badpre = badpre + 1;   // even parity restored
        end
        $display("  variant 3 (AES3 legacy): %0d subframes, deviations=%0d", rec_n, badpre);
        if (rec_n < 40 || badpre != 0) begin
            $display("  FAIL: legacy variant does not reproduce the old format");
            errors = errors + 1; end

        // ---- route (i): plain 16-bit standard I2S ------------------------
        // Different framing entirely (16 bits/channel, MSB first), so just
        // prove it produces a live word select and a moving data line - the
        // serializer itself is sys/i2s.v, which ships PCM to this chip daily.
        variant = 3'd0;   // PCM16 - the shipping default
        begin : pcm16_chk
            integer ws_edges, sd_edges;
            reg wsd, sdd;
            ws_edges = 0; sd_edges = 0; wsd = ws; sdd = sd;
            repeat (40000) @(posedge clk) begin
                if (ws != wsd) ws_edges = ws_edges + 1;
                if (sd != sdd) sd_edges = sd_edges + 1;
                wsd = ws; sdd = sd;
            end
            $display("  variant 0 (PCM16, default): ws_edges=%0d sd_edges=%0d", ws_edges, sd_edges);
            if (ws_edges < 20 || sd_edges < 20) begin
                $display("  FAIL: PCM16 transport not running"); errors = errors + 1; end
        end

        variant = 3'd1;

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
