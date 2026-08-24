// ps_stream_fifo.sv — Input handshake adapter for ps_demux
// Part of MiSTer DVD Player Core
//
// Bridges the impedance mismatch between mpg_streamer and ps_demux:
//
//   - mpg_streamer uses a VALID + BUSY interface. It pulses stream_valid for a
//     single cycle and does NOT hold the byte until accepted; it only gates new
//     reads on a registered `busy`. Because of its internal read_valid_pipe
//     stage, one byte is still in flight the cycle after busy asserts.
//   - ps_demux uses a held VALID + READY interface: it expects in_byte/in_valid
//     to persist until in_ready is high, and it stalls in_ready during payload
//     forwarding.
//
// A direct `busy = !in_ready` would drop the in-flight byte. This small
// first-word-fall-through (FWFT) FIFO absorbs the pulses and presents a proper
// held handshake to ps_demux. `almost_full` asserts with >=2 free slots so the
// in-flight byte always has room after busy raises.

`default_nettype none

module ps_stream_fifo #(
    parameter int DEPTH  = 16,
    parameter int AWIDTH = 4    // must satisfy 2**AWIDTH >= DEPTH
) (
    input  wire        clk,
    input  wire        rst_n,

    // Write side — driven by mpg_streamer's pulse interface
    input  wire  [7:0] wr_data,
    input  wire        wr_en,        // = stream_valid (one-cycle pulse)
    output logic       almost_full,  // -> mpg_streamer.busy

    // Read side — held FWFT handshake to ps_demux
    output logic [7:0] out_byte,
    output logic       out_valid,    // = !empty
    input  wire        out_ready     // ps_demux in_ready; pop on out_valid && out_ready
);

    logic [7:0]        mem [0:DEPTH-1];
    logic [AWIDTH-1:0] wr_ptr;
    logic [AWIDTH-1:0] rd_ptr;
    logic [AWIDTH:0]   count;        // 0..DEPTH, needs one extra bit

    wire do_pop = out_valid && out_ready;
    // wr_en may be presented while almost_full is asserted (the in-flight byte);
    // only block if the FIFO is genuinely full to avoid corrupting it.
    wire do_push = wr_en && (count != DEPTH[AWIDTH:0]);

    assign out_valid   = (count != 0);
    assign out_byte    = mem[rd_ptr];
    assign almost_full = (count >= (DEPTH-2));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
        end else begin
            if (do_push) begin
                mem[wr_ptr] <= wr_data;
                wr_ptr <= (wr_ptr == DEPTH[AWIDTH-1:0]-1) ? '0 : wr_ptr + 1'b1;
            end
            if (do_pop) begin
                rd_ptr <= (rd_ptr == DEPTH[AWIDTH-1:0]-1) ? '0 : rd_ptr + 1'b1;
            end
            case ({do_push, do_pop})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;   // 00 or 11: no net change
            endcase
        end
    end

endmodule

`default_nettype wire
