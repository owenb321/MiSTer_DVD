module uart_debug_v2 (
    input clk,          // 27 MHz
    input rst_n,
    
    // UART Pins
    output tx_pin,
    input  rx_pin,

    // --- Inputs from System ---
    input locked,
    input active,
    input [12:0] arx,
    input [12:0] ary,
    input        busy,
    input        valid,
    // Additional debug signals
    input [8:0]  init_cnt,
    input        sync_rst,
    input        vbw_almost_full,
    input        mem_req_en,
    input        mem_req_valid,
    input        mem_res_almost_full,  // Response FIFO backpressure
    input [3:0]  shim_state,           // Memory shim state machine
    input        sdram_busy,           // SDRAM controller busy signal
    input        sdram_ack,            // SDRAM controller ack signal
    // MPG streamer debug
    input        streamer_active,      // File streaming active
    input        streamer_sd_rd,       // SD read request
    input        streamer_sd_ack,      // SD acknowledge
    input        streamer_has_data,    // Cache has data
    input [15:0] streamer_file_size,   // File size (lower 16 bits)
    input [15:0] streamer_total_sectors, // Total sectors
    input [15:0] streamer_next_lba,    // Next LBA to read
    // Memory read/write counters
    input [15:0] mem_rd_count,         // 64-bit read completions
    input [15:0] mem_wr_count          // 64-bit write completions
);

    // =========================================================================
    // UART Core
    // =========================================================================
    wire tx_ready;
    reg [7:0] tx_data;
    reg tx_valid;
    
    wire [7:0] rx_data;
    wire rx_ready;

    uart_tx #(
        .CLK_FRE(27),
        .BAUD_RATE(115200)
    ) uart_tx_inst (
        .clk(clk),
        .rst_n(rst_n),
        .tx_data(tx_data),
        .tx_data_valid(tx_valid),
        .tx_data_ready(tx_ready),
        .tx_pin(tx_pin)
    );

    uart_rx #(
        .CLK_FRE(27),
        .BAUD_RATE(115200)
    ) uart_rx_inst (
        .clk(clk),
        .rst_n(rst_n),
        .rx_pin(rx_pin),
        .rx_data(rx_data),
        .rx_data_ready(rx_ready)
    );

    // =========================================================================
    // Command Parser
    // =========================================================================
    localparam CMD_SUMMARY  = "1";
    localparam CMD_STREAMER = "2";
    localparam CMD_MEMORY   = "3";
    localparam CMD_PAUSE    = " ";
    
    reg [2:0] cur_mode; // 0=Summary, 1=Streamer, 2=Memory
    reg paused;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_mode <= 0;
            paused <= 0;
        end else if (rx_ready) begin
            case (rx_data)
                CMD_SUMMARY:  cur_mode <= 0;
                CMD_STREAMER: cur_mode <= 1;
                CMD_MEMORY:   cur_mode <= 2;
                CMD_PAUSE:    paused <= !paused;
            endcase
        end
    end

    // =========================================================================
    // Data Capture
    // =========================================================================
    // Update timer: every ~0.5 second (13,500,000 cycles)
    reg [24:0] timer;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) timer <= 0;
        else if (timer == 13500000) timer <= 0;
        else timer <= timer + 1;
    end

    // Snapshot registers
    reg locked_r, active_r;
    reg [3:0] shim_state_r;
    reg streamer_active_r, streamer_sd_rd_r, streamer_sd_ack_r, streamer_has_data_r;
    reg [15:0] streamer_next_lba_r;
    reg [15:0] mem_rd_count_r, mem_wr_count_r;

    // Helper function
    function [7:0] to_hex;
        input [3:0] val;
        begin
            to_hex = (val < 10) ? ("0" + val) : ("A" + val - 10);
        end
    endfunction

    // =========================================================================
    // Transmit State Machine
    // =========================================================================
    localparam S_IDLE = 0;
    localparam S_CAPTURE = 1;
    localparam S_PRINT_HDR = 2; // " [MODE] "
    localparam S_PRINT_DATA = 3;
    localparam S_WAIT_TX = 4;
    
    reg [3:0] state = S_IDLE;
    reg [7:0] char_idx = 0;
    reg [7:0] next_char;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            tx_valid <= 0;
            char_idx <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    tx_valid <= 0;
                    if (timer == 0 && !paused) begin
                        state <= S_CAPTURE;
                    end
                end

                S_CAPTURE: begin
                    locked_r <= locked;
                    active_r <= active;
                    shim_state_r <= shim_state;
                    streamer_active_r <= streamer_active;
                    streamer_sd_rd_r <= streamer_sd_rd;
                    streamer_sd_ack_r <= streamer_sd_ack;
                    streamer_has_data_r <= streamer_has_data;
                    streamer_next_lba_r <= streamer_next_lba;
                    mem_rd_count_r <= mem_rd_count;
                    mem_wr_count_r <= mem_wr_count;
                    char_idx <= 0;
                    state <= S_PRINT_DATA;
                end

                S_PRINT_DATA: begin
                    if (tx_ready) begin
                        // Select Data based on Mode
                        case (cur_mode)
                            0: begin // SUMMARY
                                case (char_idx)
                                    0: tx_data <= "S"; 1: tx_data <= "U"; 2: tx_data <= "M"; 3: tx_data <= ":"; 
                                    4: tx_data <= " ";
                                    5: tx_data <= "L"; 6: tx_data <= locked_r ? "1" : "0"; 7: tx_data <= " ";
                                    8: tx_data <= "A"; 9: tx_data <= active_r ? "1" : "0"; 10: tx_data <= " ";
                                    11: tx_data <= "M"; 12: tx_data <= "e"; 13: tx_data <= "m"; 14: tx_data <= ":";
                                    15: tx_data <= to_hex(shim_state_r); 16: tx_data <= " ";
                                    17: tx_data <= "S"; 18: tx_data <= "t"; 19: tx_data <= "r"; 20: tx_data <= ":";
                                    21: tx_data <= streamer_active_r ? "1" : "0"; 22: tx_data <= " ";
                                    23: tx_data <= "\r"; 24: tx_data <= "\n";
                                    default: begin state <= S_IDLE; tx_valid <= 0; end
                                endcase
                                if (char_idx <= 24) begin
                                    tx_valid <= 1;
                                    state <= S_WAIT_TX;
                                end
                            end
                            1: begin // STREAMER
                                case (char_idx)
                                    0: tx_data <= "S"; 1: tx_data <= "T"; 2: tx_data <= "R"; 3: tx_data <= ":";
                                    4: tx_data <= " ";
                                    5: tx_data <= "L"; 6: tx_data <= "B"; 7: tx_data <= "A"; 8: tx_data <= "=";
                                    9: tx_data <= to_hex(streamer_next_lba_r[15:12]);
                                    10: tx_data <= to_hex(streamer_next_lba_r[11:8]);
                                    11: tx_data <= to_hex(streamer_next_lba_r[7:4]);
                                    12: tx_data <= to_hex(streamer_next_lba_r[3:0]);
                                    13: tx_data <= " ";
                                    14: tx_data <= "R"; 15: tx_data <= "D"; 16: tx_data <= "="; 17: tx_data <= streamer_sd_rd_r ? "1" : "0";
                                    18: tx_data <= " ";
                                    19: tx_data <= "A"; 20: tx_data <= "C"; 21: tx_data <= "K"; 22: tx_data <= "="; 23: tx_data <= streamer_sd_ack_r ? "1" : "0";
                                    24: tx_data <= " ";
                                    25: tx_data <= "C"; 26: tx_data <= "a"; 27: tx_data <= "c"; 28: tx_data <= "h"; 29: tx_data <= "e"; 30: tx_data <= "="; 31: tx_data <= streamer_has_data_r ? "1" : "0";
                                    32: tx_data <= "\r"; 33: tx_data <= "\n";
                                    default: begin state <= S_IDLE; tx_valid <= 0; end
                                endcase
                                if (char_idx <= 33) begin
                                    tx_valid <= 1;
                                    state <= S_WAIT_TX;
                                end
                            end
                            2: begin // MEMORY
                                case (char_idx)
                                    0: tx_data <= "M"; 1: tx_data <= "E"; 2: tx_data <= "M"; 3: tx_data <= ":";
                                    4: tx_data <= " ";
                                    5: tx_data <= "R"; 6: tx_data <= "D"; 7: tx_data <= "=";
                                    8: tx_data <= to_hex(mem_rd_count_r[15:12]);
                                    9: tx_data <= to_hex(mem_rd_count_r[11:8]);
                                    10: tx_data <= to_hex(mem_rd_count_r[7:4]);
                                    11: tx_data <= to_hex(mem_rd_count_r[3:0]);
                                    12: tx_data <= " ";
                                    13: tx_data <= "W"; 14: tx_data <= "R"; 15: tx_data <= "=";
                                    16: tx_data <= to_hex(mem_wr_count_r[15:12]);
                                    17: tx_data <= to_hex(mem_wr_count_r[11:8]);
                                    18: tx_data <= to_hex(mem_wr_count_r[7:4]);
                                    19: tx_data <= to_hex(mem_wr_count_r[3:0]);
                                    20: tx_data <= " ";
                                    21: tx_data <= "S"; 22: tx_data <= "t"; 23: tx_data <= "="; 24: tx_data <= to_hex(shim_state_r);
                                    25: tx_data <= "\r"; 26: tx_data <= "\n";
                                    default: begin state <= S_IDLE; tx_valid <= 0; end
                                endcase
                                if (char_idx <= 26) begin
                                    tx_valid <= 1;
                                    state <= S_WAIT_TX;
                                end
                            end
                        endcase
                    end
                end

                S_WAIT_TX: begin
                    tx_valid <= 0;
                    state <= S_PRINT_DATA; 
                    char_idx <= char_idx + 1;
                end
            endcase
        end
    end

endmodule
