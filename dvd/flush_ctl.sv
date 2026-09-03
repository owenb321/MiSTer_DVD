/*
 * flush_ctl.sv — flush/reset trigger matrix for the playback pipeline
 *
 * DVD-FORK (2026-08-28). Extracted verbatim from dvd/emu.sv so the trigger matrix
 * is testbenchable (bench/dvd/flush_ctl_tb.sv): the mid-play mount A/V-desync bug
 * (mount fired load_flush + aud_flush but NOT the seek/VBUF flush, so the decoder
 * played the OLD file's 0.5-2 MB buffered tail against the NEW file's STC anchor)
 * lived exactly in this glue, which had no sim coverage while it was inline.
 *
 * One module, five counters, clk_sys only. The event inputs are 1-cycle pulses
 * except keep_vbuf (a reader level, sampled by the same event pulses it qualifies).
 * Each flush output is a ~64-cycle level; the consumers treat it as a reset.
 * mount_flush (mount ONLY) additionally requests the decoder's watchdog-equivalent
 * soft reset — see its block comment at the bottom.
 *
 * THE FLUSH TRIO RULE (HW-proven, see the il_switch comment in emu.sv and
 * docs/interlaced_auto.md): a playback discontinuity needs ALL THREE of
 *   seek_flush (decoder VBUF discard) + load_flush (demux/av_sync/STC re-anchor)
 *   + aud_flush (audio chain cold start)
 * or audio ends up phased against the wrong video timeline:
 *   - vbuf-only  => video jumps ~1 s forward, audio keeps its backlog => audio LATE
 *     (the il_switch v1 lesson);
 *   - load+aud only => STC anchors on the new stream while the decoder still plays
 *     the old buffered tail => audio EARLY by the residual VBUF depth, permanently
 *     (the mid-play mount bug, fixed 2026-08-28 — a forward skew < ~15 s never
 *     re-anchors, av_sync FWD_REANCHOR_TICKS).
 * The deliberate exceptions are keep_vbuf menu->menu transitions (video tail plays
 * out, audio rides through — docs/dvd_menu_refinements.md §5d) and the audio-only
 * aud_resync (video is continuous, so only the audio side re-phases).
 *
 * Kept in emu.sv (not moved): the edge-detect that produces mode_switch (today
 * il_switch only — a filmp_eff edge was attempted and REVERTED 2026-08-28, see the
 * mode_switch comment in emu.sv for the T2 logo-chain post-mortem), aud_drop_pulse,
 * and the seek_flush 2-FF CDC into clk_dec (vbuf_flush_dec).
 */

`default_nettype none

module flush_ctl (
    input  wire clk,              // clk_sys (27 MHz)
    input  wire rst_n,            // core reset (emu reset_n)

    input  wire start_streaming,  // 1-cycle pulse: new file mounted
    input  wire seek_ack,         // 1-cycle pulse: reader executed a transport seek
    input  wire jump_ack,         // 1-cycle pulse: reader executed a VM jump
    input  wire mode_switch,      // 1-cycle pulse: live raster-regime change (interlace/film)
    input  wire aud_switch,       // 1-cycle pulse: audio track switch
    input  wire keep_vbuf,        // level (reader): menu->menu transition keeps the VBUF

    output wire load_flush,       // ~64-cycle level -> pipe_rst_n scope (demux/av_sync/nav)
    output wire aud_flush,        // ~64-cycle level -> audio chain reset (with aud_resync)
    output wire aud_resync,       // ~64-cycle level -> audio-only re-phase
    output wire seek_flush,       // ~64-cycle level -> 2-FF into clk_dec = mpeg2video.vbuf_flush
    output wire mount_flush,      // ~64-cycle level, MOUNT ONLY -> mpeg2video.soft_flush (decoder soft reset)
    output wire pipe_rst_n,       // reset_n & ~load_flush
    output wire aud_rst_n         // reset_n & ~aud_flush & ~aud_resync
);

// =========================================================================
// CLIP-LOAD FLUSH (2026-07-02): pulse a short reset through the DEMUX/AUDIO
// chain on every file mount, so a new clip never inherits the previous one's
// state. Without this: the audio_ring is still full of the OLD clip's audio
// (which would play into the new clip) and, worse, its almost_full backpressure
// is already engaged at t=0 — strangling the new clip's stream before it can
// flood-fill VBUF, so the decoder starts bitstream-starved (HW: reload of a
// clip started as a slideshow; only a core reload played smoothly). Scope:
// ps_stream_fifo, ps_demux, ac3_reframer, audio_ring, dvd_audio_decode, av_sync
// (fresh STC anchor). NOT the streamer (it must catch this same mount event)
// and NOT mpeg2video (a full decoder reset would clear the regfile/modeline;
// the decoder already re-syncs on the next sequence header). The pulse is 64
// clk_sys cycles (~2.4 us) — over long before the first sector arrives.
reg [6:0] load_flush_cnt = 7'd0;
assign    load_flush = load_flush_cnt != 7'd0;
always @(posedge clk) begin
    if (~rst_n)                            load_flush_cnt <= 7'd0;
    else if (start_streaming || seek_ack || jump_ack || mode_switch)
                                           load_flush_cnt <= 7'd64;   // load, seek, menu jump OR raster-regime (interlace/film) switch
    else if (load_flush)                   load_flush_cnt <= load_flush_cnt - 7'd1;
end
assign pipe_rst_n = rst_n & ~load_flush;

// AUDIO-ONLY RE-SYNC (Phase-10 round 3): on an audio-track switch, re-phase the
// audio WITHOUT touching ps_stream_fifo / ps_demux (which carry the video bitstream
// on the same byte stream; resetting them mid-PES corrupts the picture — the round-1
// green-frame regression). Scope is DELIBERATELY MINIMAL — just `audio_ring` +
// `dvd_audio_decode` (via `aud_rst_n` = pipe_rst_n AND NOT aud_resync):
//   - the ring reset DISCARDS the old track's queued frames, so the first frame the
//     decoder sees post-switch is a NEW-track frame with the correct PTS (a decoder
//     reset alone would re-phase to the stale old-track PTS still in the ring = no fix);
//   - the decoder reset drains the PCM FIFO so its drain-gate re-establishes the
//     playback phase against the (video-continuous, still-correct) av_sync STC.
// av_sync is NOT reset — its STC never drifts across the switch (video is continuous)
// and nco_trim is retired, so it's telemetry-only here. ac3_reframer is NOT reset —
// it self-heals on the next 0x0B77 AC-3 boundary (the ring discards its transient
// output during the reset window anyway). Keeping the new high-fanout reset net down
// to 2 modules matters: this design is fit-congestion-marginal (~87% ALM) and a
// 4-module aud_rst_n net FAILED to route (Error 11802) twice. load / seek / menu jump
// still reset both via pipe_rst_n. 64 clk_sys cycles; brief silent gap is expected.
reg [6:0] aud_resync_cnt = 7'd0;
assign    aud_resync = aud_resync_cnt != 7'd0;
always @(posedge clk) begin
    if (~rst_n)              aud_resync_cnt <= 7'd0;
    else if (aud_switch)     aud_resync_cnt <= 7'd64;
    else if (aud_resync)     aud_resync_cnt <= aud_resync_cnt - 7'd1;
end

// AUDIO-CONTINUITY ACROSS A KEEP_VBUF MENU TRANSITION (docs/dvd_menu_refinements.md §5d).
// pipe_rst_n resets the whole demux/audio chain on EVERY jump (load_flush). For the VIDEO
// that's fine - ps_demux re-parses the new stream into the KEPT decoder buffer (keep_vbuf),
// whose ~1 s of buffered frames bridge the re-parse gap, so video rides smoothly through a
// menu->menu transition. But audio_ring + dvd_audio_decode were ALSO reset, wiping the
// queued menu audio - so audio DROPPED OUT at the transition while video played on (the T2
// "next clip's audio missing at the junction"). Fix: gate the AUDIO reset with keep_vbuf,
// symmetrically with the video vbuf_flush - on a keep_vbuf menu->menu transition the audio
// ring is NOT reset, so its queued audio keeps draining while ps_demux/reframer (still reset
// via pipe_rst_n) re-sync and refill it behind the old audio. A REAL flush (clip load, title
// seek, menu->title Play, Snappy deep-flush = keep_vbuf 0) still resets audio to stay aligned
// with the video flush.
reg [6:0] aud_flush_cnt = 7'd0;
assign    aud_flush = aud_flush_cnt != 7'd0;
always @(posedge clk) begin
    if (~rst_n)                                            aud_flush_cnt <= 7'd0;
    else if (start_streaming || ((seek_ack || jump_ack) && ~keep_vbuf) || mode_switch)
                                                           aud_flush_cnt <= 7'd64;   // mode_switch: full re-sync (see the mode_switch comment in emu.sv)
    else if (aud_flush)                                    aud_flush_cnt <= aud_flush_cnt - 7'd1;
end
assign aud_rst_n = rst_n & ~aud_flush & ~aud_resync;

// SEEK VBUF FLUSH: on a transport seek, a raster-regime switch, OR a new file
// mount, also discard the decoder's ~1 s compressed video cushion (VBUF) so the
// picture jumps with the audio instead of playing the old buffered stream for
// ~1 s. The level is 2-FF synced into clk_dec (in emu.sv) to drive
// mpeg2video.vbuf_flush.
//
// MOUNT FLUSH (2026-08-28): start_streaming fires this too, completing the full
// flush trio for a mid-play file load (see the module header). The original
// "Seek-only (the known-good clip-load path is left untouched)" exclusion
// predated the lip-sync v5 pickup_hold->video_live re-arm (PR fj#60): back then
// a warm reload kept the old STC advancing and the un-flushed VBUF was a small
// bounded offset. After v5, a reload re-anchors like a cold start, so the
// surviving OLD-file VBUF made audio lead video by the whole residual depth,
// permanently. The mount term is deliberately UNGATED by keep_vbuf: a stale
// keep_vbuf=1 level from a previous menu hop must not suppress a mount flush
// (mirrors the ungated start_streaming term in aud_flush_cnt above).
//
// PHASE-5 MENU TRANSITION: a menu->menu seek/jump (keep_vbuf) suppresses the
// VBUF flush so the buffered transition-animation tail plays out (no cold
// re-lock on a stale/black frame). Title seeks and menu->title jumps still
// flush (A/V-sync critical). See docs/dvd_menu_refinements.md sec.2.
//
// UNIVERSAL menu behaviour (§5d, 2026-07-13): the old Snappy/Smooth toggle (P1O[18],
// which OVERRODE keep_vbuf to flush a deep menu buffer) is REMOVED - HW confirmed the
// keep_vbuf + menu-VBUF-cap + audio-continuity path works on every disc, so menu->menu
// transitions now ALWAYS keep the buffer (no flush), and the cap handles the lag. So
// the flush is back to the pure keep_vbuf rule: flush a title transport seek /
// menu->title Play (keep_vbuf=0), never a menu->menu transition.
wire jump_flush     = jump_ack && ~keep_vbuf;
wire seek_flush_now = seek_ack && ~keep_vbuf;
reg [6:0] seek_flush_cnt = 7'd0;
assign    seek_flush = seek_flush_cnt != 7'd0;
always @(posedge clk) begin
    if (~rst_n)                                            seek_flush_cnt <= 7'd0;
    else if (seek_flush_now || jump_flush || mode_switch || start_streaming)
                                                           seek_flush_cnt <= 7'd64;   // seek / menu->title jump / raster-regime switch / file mount
    else if (seek_flush)                                   seek_flush_cnt <= seek_flush_cnt - 7'd1;
end

// MOUNT SOFT RESET (2026-08-28): on a file MOUNT ONLY, also request the decoder's
// watchdog-equivalent soft reset (mpeg2video.soft_flush -> reset.soft_rst_n). The
// flush trio above discards BUFFERED data but deliberately leaves the decode
// pipeline's state (the upstream "trick play" flush resets only the VBUF FIFOs;
// vld/getbits/motcomp/picbuf are all on sync_rst).
// A NEW FILE must not inherit any of it: the in-flight picture "completes" on the
// new file's first start code (one truncated garbage frame), and the old file's
// reference frames stay flagged valid, so an open-GOP-leading new file (common for
// flat .mpg/.VOB clips; MPEG-1/VCD too) motion-compensates its first B-frames
// against the PREVIOUS file = macroblock garbage at load. The soft reset clears
// all of it while the regfile/modeline (hard_rst) survive — the exact recovery
// path a watchdog expiry exercises routinely on HW — so a warm load starts as
// black and clean as a core reload. NEVER on seeks/jumps/mode switches.
//
// ⚠ CORRECTED 2026-09-03 (issue #45). This comment used to justify the
// mount-only rule as "right for seeks, where the display must hold the last
// frame and the reference frames are same-file valid". BOTH halves were wrong,
// and the conflation IS the bug: same-FILE is not same-POSITION, and MPEG
// prediction cares about position, so a seek's surviving references are exactly
// as stale as a mount's; and the display was NOT holding — output_frame_valid
// stays high straight through a flush, so ~6 frames of the landing GOP's
// leading B-pictures were displayed motion-compensated against the scene we
// just left. THE RULE ITSELF STANDS, unchanged: a seek still must not soft-reset
// (sync_rst drops dec_ready and gates the modeline walk, and a black cut on
// every chapter skip is worse than a held frame). The reference staleness is
// fixed one layer down instead — rtl/mpeg2/vld.v drops the landing GOP's
// leading predicted pictures until two post-flush anchors have re-established
// the references, so the display holds the last frame for real.
// See docs/seek_realign.md.
reg [6:0] mount_flush_cnt = 7'd0;
assign    mount_flush = mount_flush_cnt != 7'd0;
always @(posedge clk) begin
    if (~rst_n)                  mount_flush_cnt <= 7'd0;
    else if (start_streaming)    mount_flush_cnt <= 7'd64;   // mount ONLY
    else if (mount_flush)        mount_flush_cnt <= mount_flush_cnt - 7'd1;
end

endmodule

`default_nettype wire
