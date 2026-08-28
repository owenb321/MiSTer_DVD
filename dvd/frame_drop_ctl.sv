/*
 * frame_drop_ctl.sv — Graceful frame-drop governor: timeline-debt catch-up controller
 *
 * DVD-FORK (frame-drop governor, O[19]).
 *
 * The MPEG-2 decoder is compute-bound on high-motion / PAL content: it misses the
 * per-frame display deadline, and the frame-rate governor (dvd/resample_addrgen.v)
 * papers over the miss by re-scanning (repeating) the last displayed image. That
 * turns a decode-load overrun into visible judder.
 *
 * The standard DVD-player answer is to DROP a B-frame when behind: a B-frame is
 * never used as a reference, so skipping its decode is free (no corruption) and
 * removes the single most expensive picture (bidirectional motion comp) from the
 * decoder's workload, letting it catch up.
 *
 * ---------------------------------------------------------------------------------
 * WHY TIMELINE ACCOUNTING (not a naive "1 drop per late frame") — HW lesson:
 *
 * The display shows every frame for exactly SHOW_N refreshes regardless of dropping.
 * So DROPPING one frame reclaims SHOW_N refreshes of the presentation timeline: the
 * remaining frames march through the fixed-rate display faster. A drop is therefore
 * only "free" (timeline-neutral) if it CANCELS an equal amount of slow-motion the
 * governor already accrued by repeating late frames.
 *
 * The first version dropped one B-frame per `frame_late` pulse. But each `frame_late`
 * is only ONE refresh of lateness, while each drop reclaims SHOW_N (=2) refreshes — a
 * 2x over-correction. On chronically-behind content (BBB-PAL) the huge decode deficit
 * hid this. On mostly-keeping-up content (Matrix/MiB) the small per-hiccup over-drops
 * ACCUMULATED into a dramatic speed-up — and because av_sync slaves the audio clock
 * to the video presentation timeline (STC advances per displayed refresh), the AUDIO
 * sped up too. (Observed on hardware, 2026-06-30.)
 *
 * Fix: accumulate lateness as a debt counter in units of display refreshes
 *   - `frame_late`  -> debt += 1        (one refresh of slow-motion accrued)
 *   - a dropped B   -> debt -= SHOW_N   (reclaimed one frame == SHOW_N refreshes)
 * and only request a drop when `debt >= SHOW_N`. Because we never subtract more than
 * the accrued debt, `debt` can never go negative, so playback can NEVER overshoot into
 * a speed-up — the worst case is staying a fraction of a frame behind real time
 * (imperceptible, and absorbed by av_sync). MiB's isolated 1-refresh hiccups no longer
 * reach the SHOW_N threshold, so they no longer drop; BBB-PAL's sustained deficit still
 * crosses it and drops as needed. `debt` saturates at DEBT_MAX so a decoder that can't
 * keep up even while dropping every B just pins the drop request high (best effort)
 * instead of wrapping.
 * ---------------------------------------------------------------------------------
 *
 *   - `frame_late`  (1-cycle pulse, from the governor) — the display re-scanned the
 *                    last image because a new frame was DUE but not yet decoded: one
 *                    refresh of lateness.
 *   - `drop_ack`    (1-cycle pulse, from the VLD) — a B-frame was actually dropped;
 *                    reclaims SHOW_N refreshes of timeline.
 *   - `drop_req`    (level, to the VLD) — asserted while `enable` and debt >= SHOW_N,
 *                    telling the VLD to skip the next droppable B-frame.
 *
 * Single clock (mpeg2video's `clk` = clk_dec): the VLD and the governor
 * (resample_addrgen) both run on this clock inside mpeg2video, so no CDC is needed.
 *
 * `enable` gates the whole mechanism (O[19], default off) for a clean on-hardware
 * A/B: with enable=0, drop_req is always 0 and the decoder behaves exactly as before.
 */

`include "timescale.v"

module frame_drop_ctl #(
  // Refreshes of accrued lateness reclaimed by one dropped frame == the governor's
  // SHOW_N (resample_addrgen.v). Drop only once this much debt has accrued, so a drop
  // is timeline-neutral (never overshoots into a speed-up).
  parameter DROP_THRESHOLD = 2,
  parameter DEBT_MAX       = 15   // saturating ceiling on outstanding debt (refreshes)
) (
  input  wire        clk,
  input  wire        clk_en,
  input  wire        rst,        // synchronous active-low reset

  input  wire        enable,     // O[19] Frame Drop (level; already clk_dec-synced)
  // STARVATION GUARD (2026-07-02): dropping only helps COMPUTE lateness (a dropped B
  // frees decode time). When the decoder is BITSTREAM-STARVED (VBUF cushion low),
  // lateness comes from waiting on bytes — a drop then burns a whole frame's bytes at
  // zero wall-time, draining the cushion further: the HW-observed runaway where drops
  // cascaded into a 16-drops/s slideshow with VBUF pinned at 0. While bitstream_ok is
  // low we neither accrue debt (starvation lates aren't compute debt) nor drop; the
  // governor just holds (brief slow-motion), consumption falls below delivery, and the
  // cushion refills — self-healing.
  input  wire        bitstream_ok, // level: VBUF cushion healthy (hysteretic, clk-domain)
  // DVD-FORK FIX (2026-08-28, mid-play load/seek debt carry-over): clear the ledger
  // whenever the decoder's VBUF is flushed (flush_vbuf_eff level, same clk domain).
  // The debt survived every discontinuity — reset only by sync_rst — so a warm file
  // mount or a seek carried up to DEBT_MAX (15) refreshes of stale lateness into the
  // new position and could fire spurious B-drops (~0.25 s of stutter) the moment
  // vbuf_healthy re-armed. Post-flush the governor's timeline restarts anyway, so the
  // old debt refers to display history that no longer exists. Telemetry counters are
  // deliberately NOT cleared (free-running totals).
  input  wire        flush,      // level: VBUF flushed (seek/jump/mount/mode switch)
  input  wire        frame_late, // 1-cycle pulse: governor held a late refresh (+1 debt)
  input  wire        drop_ack,   // 1-cycle pulse: VLD dropped a B-frame (-drop_cost debt)
  // FILM-AWARE RECLAIM (2026-07-03): display duration (refreshes) of the frame
  // currently on display, from the governor (cur_show: 3 for a pulldown frame, else
  // SHOW_N). Debited per drop instead of a flat DROP_THRESHOLD: film frames average
  // 2.5 refreshes, so a flat 2 made every drop advance the display timeline +0.5
  // refresh (~8 ms) against the wall-clock STC the audio genlocks to — a GROWING
  // audio-late creep on droppy film (MiB worst, PAL neutral). Debiting the live
  // cur_show is zero-mean on uniform film and exact on PAL. Debt is SIGNED with a
  // small negative floor so the ±0.5 quantization CARRIES instead of accumulating.
  input  wire  [3:0] drop_cost,

  output wire        drop_req,   // level: request the VLD drop the next B-frame

  output reg  [15:0] frames_late_cnt,     // debug: total deadline misses (refreshes late)
  output reg  [15:0] frames_dropped_cnt,  // debug: total B-frames dropped
  output wire  [4:0] debt_out             // debug: current outstanding debt (refreshes)
);

  localparam DW = 6;   // signed debt width (DEBT_MAX and the -4 floor must fit)

  // SIGNED debt (film-aware reclaim): a drop may debit up to 1 refresh more than the
  // banked lates (cost 3 against threshold 2); letting the balance carry to a small
  // NEGATIVE value (floor -4) instead of flooring at 0 keeps the long-run average
  // timeline-neutral (the next lates repay the credit before new drops fire).
  reg signed [DW-1:0] debt;

  localparam signed [DW-1:0] DEBT_FLOOR = -6'sd4;

  assign drop_req = enable && bitstream_ok && (debt >= $signed(DROP_THRESHOLD));
  // debug view: clamp the carried negative credit to 0 (overlay readability)
  assign debt_out = (debt < 0) ? 5'd0 : debt[4:0];

  // Timeline-debt accounting (see header). frame_late adds one refresh (saturating at
  // DEBT_MAX); a committed drop debits the live drop_cost (cur_show of the on-display
  // frame), floored at DEBT_FLOOR. Coincident late+drop nets (+1 - cost). When disabled
  // we hold debt at zero so re-enabling starts clean.
  wire signed [DW-1:0] cost_s = $signed({2'b00, drop_cost});
  reg  signed [DW-1:0] debt_n;
  always @* begin
    debt_n = debt;
    case ({frame_late && bitstream_ok, drop_ack})
      2'b10: debt_n = debt + 6'sd1;
      2'b01: debt_n = debt - cost_s;
      2'b11: debt_n = debt + 6'sd1 - cost_s;
      default: debt_n = debt;
    endcase
    if (debt_n > $signed(DEBT_MAX))  debt_n = $signed(DEBT_MAX);
    if (debt_n < DEBT_FLOOR)         debt_n = DEBT_FLOOR;
  end
  always @(posedge clk)
    if (~rst)
      debt <= {DW{1'b0}};
    else if (clk_en) begin
      if (~enable || flush)
        debt <= {DW{1'b0}};
      else
        debt <= debt_n;
    end

  // Debug counters (free-running totals; wrap harmlessly). frames_late is counted
  // regardless of `enable` so the overlay can size how often the decoder is behind even
  // with dropping off.
  always @(posedge clk)
    if (~rst)
      frames_late_cnt <= 16'd0;
    else if (clk_en && frame_late)
      frames_late_cnt <= frames_late_cnt + 16'd1;

  always @(posedge clk)
    if (~rst)
      frames_dropped_cnt <= 16'd0;
    else if (clk_en && drop_ack)
      frames_dropped_cnt <= frames_dropped_cnt + 16'd1;

endmodule

/* not truncated */
