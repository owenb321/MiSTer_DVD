// mp2_decode_tb.sv — BIT-EXACT cosim of dvd/mp2/mp2_decode.sv against the
// golden model tools/mp2_ref.py.
//
// Fixture (generated, gitignored — see bench/dvd/run_mp2.sh which builds it):
//   <dir>/frames.hex      one hex byte per line: the exact MP2 frame bytes
//   <dir>/pcm_golden.hex  one 32-bit hex word per line: {r[15:0], l[15:0]}
// produced by:  python3 tools/mp2_ref.py fixture <in.mp2> <dir> --frames N
//
// The TB streams frames.hex into the decoder (respecting `full`), pulses
// aud_ce every AUD_DIV cycles (faster than real time — an empty FIFO simply
// doesn't pop, so capture on aud_valid stays lossless and in order), and
// compares every captured pair word-for-word against pcm_golden.hex.
// Any mismatch or a sample-count shortfall is fatal.
//
// Run (from the repo root — the ROM $readmemh paths are root-relative):
//   iverilog -g2012 -I dvd/ac3 -o bench/dvd/mp2_decode_sim \
//       dvd/mp2/mp2_decode.sv dvd/ac3/bit_fifo.sv dvd/ac3/bit_reader.sv \
//       bench/dvd/mp2_decode_tb.sv
//   vvp bench/dvd/mp2_decode_sim +FIXDIR=bench/dvd/test_mp2/tone48

`timescale 1ns/1ps
`default_nettype none

module mp2_decode_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 1;

    logic       wr_en;
    logic [7:0] wr_data;
    wire        full;
    logic       aud_ce = 0;
    wire signed [15:0] audio_l, audio_r;
    wire        aud_valid, synced, err_unsupported;

    mp2_decode dut (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_data(wr_data), .full(full),
        .aud_ce(aud_ce),
        .audio_l(audio_l), .audio_r(audio_r), .aud_valid(aud_valid),
        .synced(synced), .err_unsupported(err_unsupported)
    );

    // fixture load
    localparam int MAXB = 1 << 16;
    localparam int MAXS = 1 << 16;
    logic [7:0]  fbytes [0:MAXB-1];
    logic [31:0] golden [0:MAXS-1];
    int nbytes, nsamp;

    string fixdir;
    initial begin
        if (!$value$plusargs("FIXDIR=%s", fixdir)) fixdir = "bench/dvd/test_mp2/tone48";
        $readmemh({fixdir, "/frames.hex"}, fbytes);
        $readmemh({fixdir, "/pcm_golden.hex"}, golden);
        nbytes = 0;
        while (nbytes < MAXB && !$isunknown(fbytes[nbytes])) nbytes++;
        nsamp = 0;
        while (nsamp < MAXS && !$isunknown(golden[nsamp])) nsamp++;
        if (nbytes == 0 || nsamp == 0)
            $fatal(1, "fixture missing/empty: %s (run bench/dvd/run_mp2.sh)", fixdir);
        $display("fixture: %0d bytes, %0d golden samples", nbytes, nsamp);
    end

    // aud_ce divider: faster than real time but slower than peak production
    localparam int AUD_DIV = 64;
    int ce_cnt = 0;
    always @(posedge clk) begin
        ce_cnt <= (ce_cnt == AUD_DIV-1) ? 0 : ce_cnt + 1;
        aud_ce <= (ce_cnt == AUD_DIV-1);
    end

    // byte feed — combinational valid, advance only on ACCEPTED writes (a
    // registered !full check races the FIFO filling and silently drops bytes)
    int fed = 0;
    always_comb begin
        wr_en   = (!rst && fed < nbytes);
        wr_data = fbytes[fed >= nbytes ? 0 : fed];
    end
    always @(posedge clk)
        if (!rst && wr_en && !full) fed <= fed + 1;

    // capture + compare
    int got = 0;
    int errs = 0;
    always @(posedge clk) begin
        if (aud_valid) begin
            if (got < nsamp) begin
                if ({audio_r, audio_l} !== golden[got]) begin
                    if (errs < 20)
                        $display("MISMATCH s%0d: dut {r,l}=%04x%04x golden=%08x",
                                 got, audio_r & 16'hffff, audio_l & 16'hffff, golden[got]);
                    errs++;
                end
            end
            got++;
        end
    end

    initial begin
        repeat (8) @(posedge clk);
        rst = 0;
        // wait until all golden samples captured or timeout watchdog fires
        wait (got >= nsamp);
        repeat (200) @(posedge clk);
        if (got > nsamp) begin
            $display("FAIL: extra samples: got %0d expected %0d", got, nsamp);
            errs++;
        end
        if (err_unsupported) begin
            $display("FAIL: err_unsupported asserted");
            errs++;
        end
        if (errs == 0) begin
            $display("PASS: mp2_decode_tb — %0d samples BIT-EXACT vs mp2_ref.py", got);
            $finish;
        end else begin
            $display("RESULT: %0d error(s)", errs);
            $fatal(1, "mp2_decode_tb failed");
        end
    end

    initial begin
        #400_000_000;   // 40M cycles
        $display("TIMEOUT: got %0d / %0d samples (synced=%0d err=%0d)",
                 got, nsamp, synced, err_unsupported);
        $fatal(1, "mp2_decode_tb timeout");
    end

endmodule

`default_nettype wire
