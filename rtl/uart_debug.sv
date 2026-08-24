
module uart_debug (
    input clk,          // 27 MHz
    input rst_n,
    input locked,
    input active,
    input [12:0] arx,
    input [12:0] ary,
    input        busy,
    input        valid,
    output tx_pin
);

    wire tx_ready;
    reg [7:0] tx_data;
    reg tx_valid;

    uart_tx #(
        .CLK_FRE(27),
        .BAUD_RATE(115200)
    ) uart_inst (
        .clk(clk),
        .rst_n(rst_n),
        .tx_data(tx_data),
        .tx_data_valid(tx_valid),
        .tx_data_ready(tx_ready),
        .tx_pin(tx_pin)
    );

    // Update timer: every ~1 second (27,000,000 cycles)
    reg [24:0] timer;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) timer <= 0;
        else if (timer == 27000000) timer <= 0;
        else timer <= timer + 1;
    end

    // Capture values when timer hits 0 to ensure stable output during transmission
    reg locked_r, active_r, busy_r, valid_r;
    reg [12:0] arx_r, ary_r;
    
    // State machine
    localparam S_IDLE = 0;
    localparam S_PRINT = 1;
    localparam S_WAIT_TX = 2; // Wait for ready to go low (ack) then high (done)
    
    reg [3:0] state = S_IDLE;
    reg [5:0] char_idx = 0;
    
    // Message Format: "L:x A:x AR:xxxx:xxxx\r\n" (approx 24 chars)
    
    function [7:0] to_hex;
        input [3:0] val;
        begin
            to_hex = (val < 10) ? ("0" + val) : ("A" + val - 10);
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            tx_valid <= 0;
            char_idx <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    tx_valid <= 0;
                    if (timer == 0) begin
                        locked_r <= locked;
                        active_r <= active;
                        busy_r <= busy;
                        valid_r <= valid;
                        arx_r <= arx;
                        ary_r <= ary;
                        char_idx <= 0;
                        state <= S_PRINT;
                    end
                end

                S_PRINT: begin
                    if (tx_ready) begin
                        state <= S_WAIT_TX;
                        tx_valid <= 1;
                        case (char_idx)
                            0: tx_data <= "L";
                            1: tx_data <= ":";
                            2: tx_data <= locked_r ? "1" : "0";
                            3: tx_data <= " ";
                            4: tx_data <= "A";
                            5: tx_data <= ":";
                            6: tx_data <= active_r ? "1" : "0";
                            7: tx_data <= " ";
                            8: tx_data <= "B";
                            9: tx_data <= ":";
                            10: tx_data <= busy_r ? "1" : "0";
                            11: tx_data <= " ";
                            12: tx_data <= "V";
                            13: tx_data <= ":";
                            14: tx_data <= valid_r ? "1" : "0";
                            15: tx_data <= " ";
                            16: tx_data <= "X";
                            17: tx_data <= ":";
                            18: tx_data <= to_hex(arx_r[11:8]);
                            19: tx_data <= to_hex(arx_r[7:4]);
                            20: tx_data <= to_hex(arx_r[3:0]);
                            21: tx_data <= " ";
                            22: tx_data <= "Y";
                            23: tx_data <= ":";
                            24: tx_data <= to_hex(ary_r[11:8]);
                            25: tx_data <= to_hex(ary_r[7:4]);
                            26: tx_data <= to_hex(ary_r[3:0]);
                            27: tx_data <= "\r";
                            28: tx_data <= "\n";
                            default: begin
                                state <= S_IDLE;
                                tx_valid <= 0;
                            end
                        endcase
                    end
                end

                S_WAIT_TX: begin
                    // Wait for one clock cycle to ensure valid is registered? 
                    // uart_tx logic: IDLE -> START if valid=1.
                    // We assert valid=1. Next cycle, state in uart_tx goes START. ready goes LOW.
                    // We should wait until ready goes HIGH again?
                    // Optimized uart_tx might be ready immediately if buffer is empty or latching.
                    // The one we copied latches input.
                    // Let's just hold valid for 1 cycle and wait.
                    tx_valid <= 0;
                    // Actually, let's keep it simple. The uart_tx will drop ready when it starts.
                    // But we are running at same clock.
                    // Let's just go to next char. The UART_TX module might not be ready immediately for next char?
                    // S_STOP sets ready high.
                    // So we stay in S_PRINT checking tx_ready.
                    // But we need to increment char_idx after sending.
                    
                    state <= S_PRINT; 
                    char_idx <= char_idx + 1;
                    
                    // Actually, if we jump back to S_PRINT immediately, tx_ready might still be high from previous completion 
                    // if the UART internal state hasn't updated yet?
                    // The uart_tx code: 
                    // always @(posedge clk...) 
                    // if (state == S_IDLE) if (tx_data_valid) tx_data_ready <= 0;
                    
                    // So if we assert valid, next cycle ready goes low.
                    // So we must wait for ready to go low? Or just wait 1 cycle?
                    // Let's add a small wait state or rely on ready being low.
                end
            endcase
        end
    end

endmodule
