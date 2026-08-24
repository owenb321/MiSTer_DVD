// =============================================================================
// dvd/decoder_profile.sv — decoder pipeline-stage bottleneck profiler
// =============================================================================
// Localizes WHICH decode stage is the rate-limiter on high-motion content
// (Matrix/MIB stutter), the measure-first step before any decoder datapath
// rewrite. The miss-rate counter (dvd/mem_shim_burst.sv, overlay row 6) already
// proved the deficit is COMPUTE, not memory (cache copes at ~78% hit). This says
// which COMPUTE stage to attack.
//
// The MPEG-2 pipeline (rtl/mpeg2/mpeg2video.v) is a chain of stages joined by
// FIFOs:  vld -> rld_fifo -> rld -> idct -> idct_fifo -> motcomp -> framestore.
// The rate-limiting stage is identified by where backpressure piles up vs where
// starvation appears:
//
//   idct_fifo_almost_full  : IDCT output backs up because MOTCOMP won't drain the
//                            residual fast enough         => MOTCOMP-bound (recon side)
//   mvec_wr_almost_full    : motion-vector FIFO backs up because MOTCOMP won't
//                            consume MVs fast enough       => MOTCOMP-bound (MV/refread)
//   idct_rd_dta_empty      : MOTCOMP is STARVED of RESIDUAL data => the FRONT-END
//                            (vld entropy decode / rld / idct compute) is the neck
//   recon_ref_stall        : recon is STALLED waiting for PREDICTION pixels — it has
//                            work and output room but a wanted fwd/bwd reference row
//                            isn't valid yet (precise, DEMAND-GATED inside
//                            motcomp_recon.v; does NOT saturate on the unused
//                            direction of P/I frames the way a raw fifo-empty does).
//                            High => the reference-read FEED is the neck. This tests
//                            motcomp_recon.v's own claim that recon is "limited by
//                            how fast the memory subsystem can feed it with pixels"
//                            — recon arithmetic is already 8-pixel parallel.
//
// The *_almost_full signals are SELF-GATING: they only assert under genuine
// backpressure (a downstream stage is the neck), never during inter-frame idle.
// The *_empty signals are the complementary starvation indicators (which feed —
// residual or reference-pixel — recon is waiting on).
//
// Per 65536-cycle window (clk = clk_dec, the decode clock) each signal's DUTY is
// accumulated and latched as an 8-bit window fraction (count>>8, 0xFF=100%),
// packed into two 16-bit words for two overlay rows:
//   prof0 = {idct_fifo_af%, mvec_af%}   "MOTCOMP backpressure" (residual | MV side)
//   prof1 = {idct_empty%,  ref_stall%}   "recon starved: RESIDUAL | REFERENCE feed"
//
// READING THE VERDICT (compare Matrix vs BBB on hardware):
//   prof0 high (idct_fifo_af or mvec_af)        => MOTCOMP is the neck.
//   prof1 hi byte (idct_empty) high             => recon starved of RESIDUAL =>
//        FRONT-END (VLD/RLD/IDCT) is the neck => lever = entropy/IDCT datapath.
//   prof1 lo byte (ref_stall) high              => recon STALLED on REFERENCE pixels
//        => reference-read FEED is the neck => lever = ref prefetch / read overlap /
//        relax single-outstanding, NOT a recon-arithmetic rewrite.
//   prof1 lo LOW while prof0 (mvec_af) high      => recon has its refs but motcomp
//        still backs up => recon ARITHMETIC (2clk/row) is the limit => widen recon.
// =============================================================================
module decoder_profile (
    input        clk,        // clk_dec (decode clock domain)
    input        rst_n,

    // tapped directly from mpeg2video.v inter-stage handshake wires
    input        idct_fifo_almost_full,   // motcomp not draining IDCT residual   (motcomp recon-side)
    input        mvec_wr_almost_full,     // motcomp not draining motion vectors  (motcomp MV/refread)
    input        recon_ref_stall,         // recon stalled waiting for ref pixels  (reference-feed bound)
    input        idct_rd_dta_empty,       // motcomp starved of residual          (front-end bound)

    output [15:0] prof0,                  // {idct_fifo_af%, mvec_af%}
    output [15:0] prof1                   // {idct_empty%,   ref_stall%}
);
    // windowed duty accumulators (17-bit: detect the all-window saturated case)
    reg [15:0] win;
    reg [16:0] ifaf_acc, mvaf_acc, empt_acc, feed_acc;
    reg [7:0]  ifaf_pct, mvaf_pct, empt_pct, feed_pct;

    always @(posedge clk) begin
        if (!rst_n) begin
            win <= 0;
            ifaf_acc <= 0; mvaf_acc <= 0; empt_acc <= 0; feed_acc <= 0;
            ifaf_pct <= 0; mvaf_pct <= 0; empt_pct <= 0; feed_pct <= 0;
        end else if (&win) begin                       // 65535 -> window (65536 cyc) closed
            ifaf_pct <= ifaf_acc[16] ? 8'hFF : ifaf_acc[15:8];
            mvaf_pct <= mvaf_acc[16] ? 8'hFF : mvaf_acc[15:8];
            empt_pct <= empt_acc[16] ? 8'hFF : empt_acc[15:8];
            feed_pct <= feed_acc[16] ? 8'hFF : feed_acc[15:8];
            // seed the next window with this cycle's samples
            ifaf_acc <= {16'd0, idct_fifo_almost_full};
            mvaf_acc <= {16'd0, mvec_wr_almost_full};
            empt_acc <= {16'd0, idct_rd_dta_empty};
            feed_acc <= {16'd0, recon_ref_stall};
            win      <= 0;
        end else begin
            if (idct_fifo_almost_full && !ifaf_acc[16]) ifaf_acc <= ifaf_acc + 1'b1;
            if (mvec_wr_almost_full   && !mvaf_acc[16]) mvaf_acc <= mvaf_acc + 1'b1;
            if (idct_rd_dta_empty     && !empt_acc[16]) empt_acc <= empt_acc + 1'b1;
            if (recon_ref_stall       && !feed_acc[16]) feed_acc <= feed_acc + 1'b1;
            win <= win + 1'b1;
        end
    end

    assign prof0 = {ifaf_pct, mvaf_pct};
    assign prof1 = {empt_pct, feed_pct};
endmodule
