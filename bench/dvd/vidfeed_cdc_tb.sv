// =============================================================================
// bench/dvd/vidfeed_cdc_tb.sv — verify dvd/vidfeed_cdc.sv is byte-exact across the
// clock-domain crossing (no drop / dup / reorder) under backpressure on both sides.
// =============================================================================
// This is the regression that catches the bug that garbled the first 54 MHz build:
// the read adapter must never drop a byte when rd_ready toggles mid-flight.
// =============================================================================
`timescale 1ns/1ps
module vidfeed_cdc_tb;
    // Two asynchronous clocks: write ~27 MHz (period 37 ns), read ~54 MHz (18.5 ns).
    // (Exact ratio doesn't matter; mutually async exercises the CDC.)
    reg wr_clk = 0; always #18.5 wr_clk = ~wr_clk;
    reg rd_clk = 0; always #9.25 rd_clk = ~rd_clk;
    reg rst_n = 0;

    localparam N = 4000;
    reg  [7:0] src   [0:N-1];     // bytes to send
    integer    wr_idx = 0;        // next byte to write
    integer    rd_idx = 0;        // next byte expected on read side
    integer    errors = 0;

    reg  [7:0] wr_data;
    reg        wr_valid;
    wire       wr_ready;
    wire [7:0] rd_data;
    wire       rd_valid;
    reg        rd_ready;

    vidfeed_cdc dut (
        .rst_n(rst_n),
        .wr_clk(wr_clk), .wr_data(wr_data), .wr_valid(wr_valid), .wr_ready(wr_ready),
        .rd_clk(rd_clk), .rd_data(rd_data), .rd_valid(rd_valid), .rd_ready(rd_ready)
    );

    // ---- write side: present bytes in order, advance only on valid&ready ----
    integer wseed = 32'h1234_5678;
    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_valid <= 1'b0; wr_data <= 8'd0; wr_idx <= 0;
        end else begin
            // accepted last cycle?
            if (wr_valid && wr_ready) wr_idx <= wr_idx + 1;
            // drive next byte with random gaps (valid not always asserted)
            if ((wr_valid && wr_ready) || !wr_valid) begin
                if (wr_idx + ((wr_valid && wr_ready) ? 1 : 0) < N) begin
                    wr_data  <= src[wr_idx + ((wr_valid && wr_ready) ? 1 : 0)];
                    wr_valid <= (($random(wseed) % 3) != 0);   // ~67% duty
                end else begin
                    wr_valid <= 1'b0;
                end
            end
        end
    end

    // ---- read side: random ready; check every accepted byte in order ----
    integer rseed = 32'h0BADF00D;
    always @(posedge rd_clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ready <= 1'b0; rd_idx <= 0;
        end else begin
            rd_ready <= (($random(rseed) % 4) != 0);          // ~75% duty
            if (rd_valid) begin   // rd_valid == byte consumed this cycle (take)
                if (rd_idx >= N) begin
                    $display("  ERROR: extra byte %02h at idx %0d (overrun)", rd_data, rd_idx);
                    errors = errors + 1;
                end else if (rd_data !== src[rd_idx]) begin
                    $display("  ERROR idx %0d: got %02h exp %02h", rd_idx, rd_data, src[rd_idx]);
                    errors = errors + 1;
                end
                rd_idx <= rd_idx + 1;
            end
        end
    end

    integer i;
    initial begin
        for (i = 0; i < N; i = i + 1) src[i] = (i*7 + (i>>3)*131 + 17) & 8'hFF; // varied
        wr_data = 0; wr_valid = 0; rd_ready = 0;
        repeat (8) @(posedge rd_clk); rst_n = 1;

        // run until all bytes received or timeout
        for (i = 0; i < 2_000_000; i = i + 1) begin
            @(posedge rd_clk);
            if (rd_idx >= N) i = 2_000_000;
        end

        repeat (20) @(posedge rd_clk);
        $display("=================================================");
        $display("vidfeed_cdc_tb: sent(idx)=%0d received=%0d of %0d", wr_idx, rd_idx, N);
        if (errors == 0 && rd_idx == N)
            $display("  RESULT: PASS (byte-exact, in order, no drop/dup)");
        else
            $display("  RESULT: FAIL (%0d errors, %0d/%0d received)", errors, rd_idx, N);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("  RESULT: FAIL — global timeout. received %0d/%0d", rd_idx, N);
        $finish;
    end
endmodule
