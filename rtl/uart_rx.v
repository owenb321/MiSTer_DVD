module uart_rx #(
    parameter CLK_FRE   = 50,      // clock frequency(Mhz)
    parameter BAUD_RATE = 115200   // serial baud rate
) (
    input            clk,          // clock input
    input            rst_n,        // asynchronous reset input, low active 
    input            rx_pin,       // serial data input
    output reg [7:0] rx_data,      // received data
    output reg       rx_data_ready // data ready pulse
);
    // calculates the clock cycle for baud rate 
    localparam CYCLE = CLK_FRE * 1000000 / BAUD_RATE;

    localparam S_IDLE      = 1;
    localparam S_START     = 2;
    localparam S_REC_BYTE  = 3;
    localparam S_STOP      = 4;
    localparam S_DATA      = 5;

    reg [2:0] state;
    reg [2:0] next_state;
    reg [15:0] cycle_cnt;
    reg [2:0] bit_cnt;
    reg [7:0] rx_data_latch;

    // Synchronize RX input
    reg rx_d0, rx_d1;
    wire rx_negedge = rx_d1 && !rx_d0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_d0 <= 1'b1;
            rx_d1 <= 1'b1;
        end else begin
            rx_d0 <= rx_pin;
            rx_d1 <= rx_d0;
        end
    end

    // FSM
    always @(*) begin
        case (state)
            S_IDLE:
                if (rx_negedge) next_state = S_START;
                else next_state = S_IDLE;
            S_START:
                if (cycle_cnt == CYCLE - 1) next_state = S_REC_BYTE;
                else next_state = S_START;
            S_REC_BYTE:
                if (cycle_cnt == CYCLE - 1 && bit_cnt == 3'd7) next_state = S_STOP;
                else next_state = S_REC_BYTE;
            S_STOP:
                if (cycle_cnt == CYCLE/2 - 1) next_state = S_DATA;
                else next_state = S_STOP;
            S_DATA:
                next_state = S_IDLE;
            default:
                next_state = S_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else state <= next_state;
    end

    // Cycle counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cycle_cnt <= 16'd0;
        else if (next_state != state) cycle_cnt <= 16'd0;
        else if (state == S_START || state == S_REC_BYTE || state == S_STOP)
            cycle_cnt <= cycle_cnt + 16'd1;
        else cycle_cnt <= 16'd0;
    end

    // Bit counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) bit_cnt <= 3'd0;
        else if (state == S_REC_BYTE && cycle_cnt == CYCLE - 1)
            bit_cnt <= bit_cnt + 3'd1;
    end

    // Data Latch
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_data_latch <= 8'd0;
        else if (state == S_REC_BYTE && cycle_cnt == CYCLE/2 - 1)
            rx_data_latch[bit_cnt] <= rx_d1;
    end

    // Output
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_data <= 8'd0;
            rx_data_ready <= 1'b0;
        end else if (state == S_DATA) begin
            rx_data <= rx_data_latch;
            rx_data_ready <= 1'b1;
        end else begin
            rx_data_ready <= 1'b0;
        end
    end

endmodule
