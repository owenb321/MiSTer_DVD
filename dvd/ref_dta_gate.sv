// ref_dta_gate.sv — DVD-FORK (reference-read run-ahead prefetch, O[18])
//
// Single-bitstream A/B gate for the deepened forward/backward motion-comp REFERENCE
// data fifos (see dvd/mem_override/fifo_size.v). Those fifos are physically deepened
// 256 -> 1024 so reference rows can pre-stage far ahead of motcomp_recon demand,
// keeping the f2sdram bridge busy instead of idle and collapsing the recon
// reference-feed stall (rtl/mpeg2/motcomp_recon.v dbg_ref_stall, ~91% on Matrix).
//
// This gate selects what framestore_request sees as "data fifo almost full":
//   prefetch_en = 1 (O[18]=On, default): pass the fifo's NATIVE prog_full
//                 (almost_full_deep) — asserts near fill ~960, i.e. deep run-ahead.
//   prefetch_en = 0 (O[18]=Off):         assert at the UPSTREAM baseline fill
//                 (depth 256 - threshold 64 = 192 rows), reproducing the original
//                 shallow run-ahead so a single bitstream A/B-tests the prefetch.
//
// Occupancy is tracked by counting successful writes (wr_ack, +1) and successful
// reads (rd_valid, -1); both may pulse the same cycle (net 0). The count only sets a
// flow-control threshold — the fifo's own full flag still guarantees no overflow — so
// exact tracking is not safety-critical. Purely combinational + one small counter:
// DSP-neutral, a handful of ALMs.

module ref_dta_gate #(
  parameter [10:0] BASELINE_FILL = 11'd192   // upstream default = data depth 256 - threshold 64
) (
  input  wire clk,
  input  wire rst_n,             // active-low sync reset (matches the fifo's sync_rst)
  input  wire wr_ack,            // successful data-fifo write  (occupancy +1)
  input  wire rd_valid,          // successful data-fifo read   (occupancy -1)
  input  wire almost_full_deep,  // native prog_full of the deepened 1024-deep fifo
  input  wire prefetch_en,       // 1 = deep run-ahead; 0 = baseline cap
  output wire almost_full        // gated almost-full -> framestore_request do_fwd/do_bwd
);

  reg [10:0] fill;

  always @(posedge clk)
    if (~rst_n) fill <= 11'd0;
    else        fill <= fill + {10'd0, wr_ack} - {10'd0, rd_valid};

  assign almost_full = prefetch_en ? almost_full_deep : (fill >= BASELINE_FILL);

endmodule
