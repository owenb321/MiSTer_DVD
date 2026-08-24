//============================================================================
//  bit_fifo.sv — simple synchronous FIRST-WORD-FALL-THROUGH (show-ahead) FIFO.
//
//  Byte-wide source buffer feeding `bit_reader`.  Single clock for now; the
//  async/CDC version (clk_sys <-> input clock) is deferred to M9 wiring — the
//  decoder front-end only needs the FWFT read contract, which this satisfies.
//
//  FWFT contract: `rd_data` always presents the head element; pulse `rd_en`
//  for one cycle to pop it (next element appears next clock).  `empty` means no
//  valid head.
//============================================================================

`timescale 1ns/1ps

module bit_fifo #(
    parameter int DW    = 8,
    parameter int DEPTH = 4096           // must be a power of two
) (
    input  logic           clk,
    input  logic           rst,          // synchronous, active-high

    // write side
    input  logic           wr_en,
    input  logic [DW-1:0]  wr_data,
    output logic           full,

    // read side (FWFT)
    output logic [DW-1:0]  rd_data,
    output logic           empty,
    input  logic           rd_en
);

    localparam int AW = $clog2(DEPTH);

    logic [DW-1:0] mem [0:DEPTH-1];
    logic [AW-1:0] wp, rp;
    logic [AW:0]   count;                 // 0..DEPTH

    assign full    = (count == DEPTH[AW:0]);
    assign empty   = (count == 0);
    assign rd_data = mem[rp];             // show-ahead

    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    always_ff @(posedge clk) begin
        if (rst) begin
            wp    <= '0;
            rp    <= '0;
            count <= '0;
        end else begin
            if (do_wr) begin
                mem[wp] <= wr_data;
                wp      <= wp + 1'b1;
            end
            if (do_rd)
                rp <= rp + 1'b1;

            case ({do_wr, do_rd})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;     // both or neither
            endcase
        end
    end

endmodule
