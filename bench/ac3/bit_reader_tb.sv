//============================================================================
//  bit_reader_tb.sv — self-checking testbench for dvd/ac3/bit_reader.sv
//
//  Golden vectors are synthetic (no liba52 needed): a hand-crafted 8-byte
//  stream and a fixed sequence of get_bits() requests with expected results
//  and expected running bit positions, all computed by hand below.
//
//  Stream bytes (MSB-first):
//    0x0B 0x77 0x35 0xAA 0xF0 0x0F 0xC3 0x96
//  Concatenated bits (idx 0 = MSB of byte 0):
//    00001011 01110111 00110101 10101010 11110000 00001111 11000011 10010110
//
//  Requests / expected (right-justified) / expected bitpos-after:
//    n=16 -> 0x0B77  (16)   ; the AC-3 syncword, spans bytes 0..1
//    n= 4 -> 0x3     (20)
//    n= 4 -> 0x5     (24)
//    n= 1 -> 0x1     (25)
//    n= 7 -> 0x2A    (32)
//    n=12 -> 0xF00   (44)   ; straddles bytes 4..5
//    n= 8 -> 0xFC    (52)
//    n= 5 -> 0x07    (57)
//    n= 7 -> 0x16    (64)   ; consumes the stream exactly
//
//  Run: see bench/ac3/run_bit_reader.sh
//============================================================================

`timescale 1ns/1ps

module bit_reader_tb;

    localparam int MAXW = 32;
    localparam int NBYTES = 8;

    logic              clk = 0;
    logic              rst = 1;
    logic [7:0]        fifo_dout;
    logic              fifo_empty;
    logic              fifo_rd;
    logic              req = 0;
    logic [5:0]        nbits = 0;
    logic              ack;
    logic [MAXW-1:0]   data;
    logic [31:0]       bitpos;

    // 100 MHz clock
    always #5 clk = ~clk;

    //------------------------------------------------------------------
    // FWFT (show-ahead) byte FIFO model
    //------------------------------------------------------------------
    logic [7:0] mem [0:NBYTES-1];
    logic [4:0] rp;   // read pointer

    assign fifo_dout  = (rp < NBYTES) ? mem[rp] : 8'h00;
    assign fifo_empty = (rp >= NBYTES);

    always_ff @(posedge clk) begin
        if (rst)
            rp <= '0;
        else if (fifo_rd && !fifo_empty)
            rp <= rp + 1'b1;
    end

    //------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------
    bit_reader #(.MAXW(MAXW)) dut (
        .clk(clk), .rst(rst),
        .fifo_dout(fifo_dout), .fifo_empty(fifo_empty), .fifo_rd(fifo_rd),
        .req(req), .nbits(nbits), .ack(ack), .data(data), .bitpos(bitpos)
    );

    //------------------------------------------------------------------
    // Test
    //------------------------------------------------------------------
    int errors = 0;
    int ntests = 0;

    // Issue one get_bits(n), wait for ack, check value and running bitpos.
    task automatic get_field(input [5:0] n,
                             input [31:0] expv,
                             input [31:0] exp_bitpos);
        @(negedge clk);
        req   = 1'b1;
        nbits = n;
        @(negedge clk);
        req   = 1'b0;
        nbits = 6'd0;
        // wait for the ack pulse
        while (!ack) @(negedge clk);

        ntests++;
        if (data !== expv) begin
            errors++;
            $display("  FAIL  get(%0d): data=0x%0h expected=0x%0h", n, data, expv);
        end else if (bitpos !== exp_bitpos) begin
            errors++;
            $display("  FAIL  get(%0d): bitpos=%0d expected=%0d (data ok=0x%0h)",
                     n, bitpos, exp_bitpos, data);
        end else begin
            $display("  ok    get(%0d) = 0x%0h, bitpos=%0d", n, data, bitpos);
        end
    endtask

    initial begin
        // Optional waveform dump: iverilog +DUMP, verilator --trace, etc.
        if ($test$plusargs("dump")) begin
            $dumpfile("bit_reader_tb.vcd");
            $dumpvars(0, bit_reader_tb);
        end

        // Load the golden stream.
        mem[0]=8'h0B; mem[1]=8'h77; mem[2]=8'h35; mem[3]=8'hAA;
        mem[4]=8'hF0; mem[5]=8'h0F; mem[6]=8'hC3; mem[7]=8'h96;

        // Reset
        rst = 1'b1;
        repeat (4) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        $display("bit_reader_tb: starting");

        get_field(6'd16, 32'h0000_0B77, 32'd16);
        get_field(6'd4,  32'h0000_0003, 32'd20);
        get_field(6'd4,  32'h0000_0005, 32'd24);
        get_field(6'd1,  32'h0000_0001, 32'd25);
        get_field(6'd7,  32'h0000_002A, 32'd32);
        get_field(6'd12, 32'h0000_0F00, 32'd44);
        get_field(6'd8,  32'h0000_00FC, 32'd52);
        get_field(6'd5,  32'h0000_0007, 32'd57);
        get_field(6'd7,  32'h0000_0016, 32'd64);

        repeat (4) @(negedge clk);

        $display("bit_reader_tb: %0d tests, %0d errors", ntests, errors);
        if (errors == 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");

        if (errors != 0) $fatal(1, "bit_reader_tb FAILED");
        $finish;
    end

    // Watchdog: never hang the regression.
    initial begin
        #200000;
        $display("RESULT: FAIL (timeout)");
        $fatal(1, "bit_reader_tb timeout");
    end

endmodule
