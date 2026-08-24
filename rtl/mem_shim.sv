// mem_shim.sv
//
// Bridge between mpeg2fpga's 64-bit memory interface and MiSTer's 16-bit SDRAM.
//
// The mpeg2video core presents commands via a dual-clock FIFO:
//   - mem_req_rd_cmd/addr/dta are the FIFO data output (active when mem_req_rd_valid)
//   - mem_req_rd_en is the FIFO read-enable: assert HIGH continuously whenever
//     this shim is ready to accept commands. The FIFO pops one entry each cycle
//     that both mem_req_rd_en and mem_req_rd_valid are high.
//   - mem_res_wr_dta/en feed the response FIFO (read data back to the core).
//   - mem_res_wr_almost_full is backpressure from the response FIFO.
//
// Each 64-bit word is split into 4 sequential 16-bit SDRAM accesses.
//
// Address mapping:
//   Core address is a 22-bit index into 64-bit (8-byte) words.
//   SDRAM byte address = core_addr * 8 = {core_addr, 3'b000}
//   Each 16-bit SDRAM word is 2 bytes, so 4 accesses at offsets +0, +2, +4, +6.
//   SDRAM controller uses byte addressing with ADDR[24:0].

module mem_shim (
    input             clk,
    input             rst_n,

    // MPEG2 Core memory request FIFO (read side) — clocked on clk (mem_clk)
    input       [1:0] mem_req_rd_cmd,
    input      [21:0] mem_req_rd_addr,
    input      [63:0] mem_req_rd_dta,
    output            mem_req_rd_en,
    input             mem_req_rd_valid,

    // MPEG2 Core memory response FIFO (write side) — clocked on clk (mem_clk)
    output reg [63:0] mem_res_wr_dta,
    output reg        mem_res_wr_en,
    input             mem_res_wr_almost_full,

    // SDRAM Controller Interface (16-bit)
    output reg [24:0] sdram_addr,
    output reg        sdram_rd,
    output reg        sdram_wr,
    output reg [15:0] sdram_din,
    input      [15:0] sdram_dout,
    input             sdram_ack,
    input             sdram_busy
);

    // Command encoding (from mem_codes.v)
    localparam CMD_NOOP    = 2'd0;
    localparam CMD_REFRESH = 2'd1;
    localparam CMD_READ    = 2'd2;
    localparam CMD_WRITE   = 2'd3;

    // States
    localparam S_IDLE    = 4'd0;
    localparam S_READ_0  = 4'd1;
    localparam S_READ_1  = 4'd2;
    localparam S_READ_2  = 4'd3;
    localparam S_READ_3  = 4'd4;
    localparam S_WRITE_0 = 4'd5;
    localparam S_WRITE_1 = 4'd6;
    localparam S_WRITE_2 = 4'd7;
    localparam S_WRITE_3 = 4'd8;
    localparam S_RESP    = 4'd9;

    reg [3:0]  state;
    reg [63:0] read_buffer;
    reg [63:0] write_buffer;
    reg [24:0] base_addr;
    reg        req_issued;  // tracks whether we've issued RD/WR for current sub-word

    // =========================================================================
    // mem_req_rd_en: continuous flow-control signal
    // =========================================================================
    // Assert when we are idle and can accept a new command.
    // This matches the original mem_ctl.v behavior:
    //   mem_req_rd_en <= ~mem_res_wr_almost_full
    // but we also gate on being in IDLE state since we need multiple cycles
    // to process each command.
    assign mem_req_rd_en = (state == S_IDLE) && !mem_res_wr_almost_full;

    // =========================================================================
    // Main state machine
    // =========================================================================
    // Protocol with SDRAM controller:
    //   - Pulse sdram_rd or sdram_wr for exactly ONE cycle when !sdram_busy
    //   - Wait for sdram_ack (one-cycle pulse) indicating completion
    //   - For reads, capture sdram_dout on the cycle sdram_ack is asserted
    //
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            mem_res_wr_en <= 1'b0;
            mem_res_wr_dta <= 64'd0;
            sdram_rd     <= 1'b0;
            sdram_wr     <= 1'b0;
            sdram_addr   <= 25'd0;
            sdram_din    <= 16'd0;
            read_buffer  <= 64'd0;
            write_buffer <= 64'd0;
            base_addr    <= 25'd0;
            req_issued   <= 1'b0;
        end else begin
            // Defaults: deassert single-cycle strobes
            mem_res_wr_en <= 1'b0;
            sdram_rd      <= 1'b0;
            sdram_wr      <= 1'b0;

            case (state)
                // ---------------------------------------------------------
                // IDLE: accept command when FIFO has valid data
                // ---------------------------------------------------------
                S_IDLE: begin
                    req_issued <= 1'b0;
                    if (mem_req_rd_en && mem_req_rd_valid) begin
                        case (mem_req_rd_cmd)
                            CMD_READ: begin
                                base_addr  <= {mem_req_rd_addr, 3'b000};
                                sdram_addr <= {mem_req_rd_addr, 3'b000};
                                state      <= S_READ_0;
                                req_issued <= 1'b0;
                            end
                            CMD_WRITE: begin
                                base_addr    <= {mem_req_rd_addr, 3'b000};
                                write_buffer <= mem_req_rd_dta;
                                sdram_addr   <= {mem_req_rd_addr, 3'b000};
                                sdram_din    <= mem_req_rd_dta[63:48];
                                state        <= S_WRITE_0;
                                req_issued   <= 1'b0;
                            end
                            default: ;
                        endcase
                    end
                end

                // ---------------------------------------------------------
                // READ: 4 sequential 16-bit reads -> 64-bit word
                // ---------------------------------------------------------
                S_READ_0: begin
                    if (sdram_ack) begin
                        read_buffer[63:48] <= sdram_dout;
                        sdram_addr <= base_addr + 25'd2;
                        state      <= S_READ_1;
                        req_issued <= 1'b0;
                    end else if (!req_issued && !sdram_busy) begin
                        sdram_rd   <= 1'b1;
                        req_issued <= 1'b1;
                    end
                end

                S_READ_1: begin
                    if (sdram_ack) begin
                        read_buffer[47:32] <= sdram_dout;
                        sdram_addr <= base_addr + 25'd4;
                        state      <= S_READ_2;
                        req_issued <= 1'b0;
                    end else if (!req_issued && !sdram_busy) begin
                        sdram_rd   <= 1'b1;
                        req_issued <= 1'b1;
                    end
                end

                S_READ_2: begin
                    if (sdram_ack) begin
                        read_buffer[31:16] <= sdram_dout;
                        sdram_addr <= base_addr + 25'd6;
                        state      <= S_READ_3;
                        req_issued <= 1'b0;
                    end else if (!req_issued && !sdram_busy) begin
                        sdram_rd   <= 1'b1;
                        req_issued <= 1'b1;
                    end
                end

                S_READ_3: begin
                    if (sdram_ack) begin
                        mem_res_wr_dta <= {read_buffer[63:16], sdram_dout};
                        mem_res_wr_en  <= 1'b1;
                        state          <= S_IDLE;
                        req_issued     <= 1'b0;
                    end else if (!req_issued && !sdram_busy) begin
                        sdram_rd   <= 1'b1;
                        req_issued <= 1'b1;
                    end
                end

                // ---------------------------------------------------------
                // WRITE: 4 sequential 16-bit writes from 64-bit word
                // ---------------------------------------------------------
                S_WRITE_0: begin
                    if (sdram_ack) begin
                        sdram_addr <= base_addr + 25'd2;
                        sdram_din  <= write_buffer[47:32];
                        state      <= S_WRITE_1;
                        req_issued <= 1'b0;
                    end else if (!req_issued && !sdram_busy) begin
                        sdram_wr   <= 1'b1;
                        req_issued <= 1'b1;
                    end
                end

                S_WRITE_1: begin
                    if (sdram_ack) begin
                        sdram_addr <= base_addr + 25'd4;
                        sdram_din  <= write_buffer[31:16];
                        state      <= S_WRITE_2;
                        req_issued <= 1'b0;
                    end else if (!req_issued && !sdram_busy) begin
                        sdram_wr   <= 1'b1;
                        req_issued <= 1'b1;
                    end
                end

                S_WRITE_2: begin
                    if (sdram_ack) begin
                        sdram_addr <= base_addr + 25'd6;
                        sdram_din  <= write_buffer[15:0];
                        state      <= S_WRITE_3;
                        req_issued <= 1'b0;
                    end else if (!req_issued && !sdram_busy) begin
                        sdram_wr   <= 1'b1;
                        req_issued <= 1'b1;
                    end
                end

                S_WRITE_3: begin
                    if (sdram_ack) begin
                        state      <= S_IDLE;
                        req_issued <= 1'b0;
                    end else if (!req_issued && !sdram_busy) begin
                        sdram_wr   <= 1'b1;
                        req_issued <= 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
