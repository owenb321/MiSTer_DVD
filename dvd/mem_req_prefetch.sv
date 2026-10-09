// =============================================================================
// dvd/mem_req_prefetch.sv — read-side retime of the decoder's memory request FIFO
// =============================================================================
// Sits between framestore's mem_request_fifo (xilinx_fifo_dc, standard mode) and
// the DDR3 bridge (dvd/mem_shim_burst.sv), in the clk_mem domain. It exists for
// TIMING ONLY (clk_mem retime, 2026-10-09; docs/status_log.md "clk_mem retime").
//
// Why: the bridge's pop, mem_req_rd_en, is combinational from its stage-A cache
// verdict (tag M10K out -> 4-way compare -> sA_slow). Straight into the FIFO it
// drove do_read: the read pointer, `empty`, an 88-bit dout enable and the FIFO
// M10K's address stall, a die crossing from one M10K to another. Those endpoints
// were a third of the worst clk_mem paths on the v0.9.0 fit. Through this queue
// the pop ends at 4 local flops (count, rptr, pptr, dn_valid), and nothing the
// bridge drives reaches the FIFO.
//
// CONTRACT, both sides: the xilinx_fifo_dc standard read mode, unchanged for the
// bridge, which relies on it (its speculative pop + skid):
//   - dn_valid(t+1) = dn_rd_en(t) && (the queue held a word at t); never eager.
//   - dn_dout during a dn_valid cycle is the next word in order. Words are never
//     dropped or duplicated.
//   - Nothing else (dn_dout outside a dn_valid cycle is don't-care, as with the
//     FIFO — the bridge reads it only when valid).
//
// UPSTREAM POP (credit, from registers only): up_rd_en = count + up_valid <= D-1.
// A pop at t lands at t+1 (up_valid) and is counted at t+2, so with no
// consumption the worst case is count(t) + up_valid(t) + 1 words; the credit keeps
// that <= D. Invariant: count + up_valid <= D, so an arriving word always has a
// free slot, and the slot being presented is never the one written.
// D >= 3 sustains one word per cycle on a hit stream (steady state: count 1,
// one word in flight, one popped per cycle); D = 4 for power-of-two pointers.
//
// OUTPUT: a mux, slot[pptr], with pptr latched at the pop. Not a re-registered
// dout: that would put an 88-bit enable back on the bridge's critical pop.
//
// RESET: the FIFO's own reset (framestore `rst`, active low, applied
// asynchronously exactly as xilinx_fifo_dc's read side applies it), so a watchdog
// or soft (mount) reset flushes the queue together with the FIFO. On emu's
// reset_n it would survive a soft reset and replay stale requests — writes
// included — into the cleared frame store. The data slots have no reset (they are
// read only behind count/valid), which keeps the reset fanout off them.
//
// LATENCY: when the queue runs dry, a request reaches the bridge 2 clk_mem cycles
// later than straight from the FIFO (FIFO -> slot -> pop -> valid). Against a DDR
// miss (tens of cycles) it is negligible; it never limits throughput.
//
// Gate: bench/dvd/run_mem_prefetch.sh --red (contract, throughput, reset, and a
// mutation per claim), plus bench/dvd/run_mem_shim.sh's -DMSB_PREFETCH /
// -DMSAB_PREFETCH arms (the bridge's own suites through this queue).
// =============================================================================
`default_nettype none
module mem_req_prefetch #(
    parameter integer W = 88,   // {cmd[1:0], addr[21:0], dta[63:0]}
    parameter integer D = 4     // slots, a power of two, >= 3 for full throughput
)(
    input  wire         clk,
    input  wire         rst,        // active LOW, asynchronous (the FIFO's reset)

    // upstream: the request FIFO's read port (standard mode)
    output wire         up_rd_en,
    input  wire         up_valid,
    input  wire [W-1:0] up_dout,

    // downstream: the same contract, to the bridge
    input  wire         dn_rd_en,
    output reg          dn_valid,
    output wire [W-1:0] dn_dout
);
    localparam integer AW = $clog2(D);

    reg [W-1:0]  slot [0:D-1];
    reg [AW-1:0] wptr, rptr, pptr;
    reg [AW:0]   count;             // 0..D

    wire do_read = dn_rd_en && (count != {(AW+1){1'b0}});

    // credit: room for this pop's word even if nothing is consumed meanwhile
    wire [AW+1:0] committed = {1'b0, count} + {{(AW+1){1'b0}}, up_valid};
    assign up_rd_en = (committed <= D-1);

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            wptr     <= {AW{1'b0}};
            rptr     <= {AW{1'b0}};
            pptr     <= {AW{1'b0}};
            count    <= {(AW+1){1'b0}};
            dn_valid <= 1'b0;
        end else begin
            if (up_valid) wptr <= wptr + 1'b1;
            if (do_read) begin
                pptr <= rptr;
                rptr <= rptr + 1'b1;
            end
            count    <= count + {{AW{1'b0}}, up_valid} - {{AW{1'b0}}, do_read};
            dn_valid <= do_read;
        end
    end

    always @(posedge clk)
        if (up_valid) slot[wptr] <= up_dout;

    assign dn_dout = slot[pptr];

    // ---- sim-only guard: the credit invariant ----
    // synthesis translate_off
    always @(posedge clk) if (rst) begin
        if (up_valid && (count == D[AW:0]))
            $fatal(1, "mem_req_prefetch: a word arrived with all %0d slots full", D);
        if ((count + up_valid) > D)
            $fatal(1, "mem_req_prefetch: credit invariant broken (count %0d + arriving %0d > %0d)",
                   count, up_valid, D);
    end
    // synthesis translate_on
endmodule
`default_nettype wire
