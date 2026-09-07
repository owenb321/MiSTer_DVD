//============================================================================
//  pts_cdc.sv — carry a W-bit value with a one-cycle valid across clock domains.
//
//  Toggle handshake: the source latches the value and flips a toggle; the
//  destination synchronises the toggle (3 FF) and re-issues a one-cycle valid
//  with the latched value on every flip. Used for PTS-shaped traffic — a PTS
//  arrives at most once per PES (thousands of source cycles apart), a display
//  anchor at most once per picture — so the hold register is always stable for
//  far longer than the synchroniser latency and no back-pressure is needed.
//
//  ⚠ NOT a FIFO: two src_valid pulses inside ~4 destination clocks lose the
//  first one. Give traffic that can burst its own instance or its own queue.
//============================================================================

`default_nettype none

module pts_cdc #(
    parameter int W = 33
) (
    input  wire         src_clk,
    input  wire         src_rst_n,
    input  wire [W-1:0] src_data,
    input  wire         src_valid,

    input  wire         dst_clk,
    input  wire         dst_rst_n,
    output logic [W-1:0] dst_data,
    output logic        dst_valid
);

    logic [W-1:0] hold;
    logic         tog;
    always_ff @(posedge src_clk or negedge src_rst_n)
        if (!src_rst_n) begin
            hold <= '0;
            tog  <= 1'b0;
        end else if (src_valid) begin
            hold <= src_data;
            tog  <= ~tog;
        end

    logic t1, t2, t3;
    always_ff @(posedge dst_clk or negedge dst_rst_n)
        if (!dst_rst_n) begin
            t1 <= 1'b0; t2 <= 1'b0; t3 <= 1'b0;
            dst_valid <= 1'b0;
            dst_data  <= '0;
        end else begin
            t1 <= tog;
            t2 <= t1;
            t3 <= t2;
            dst_valid <= t2 ^ t3;
            if (t2 ^ t3) dst_data <= hold;
        end

endmodule

`default_nettype wire
