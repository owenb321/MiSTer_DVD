/* 
 * resample_addrgen.v
 * 
 * Copyright (c) 2007 Koen De Vleeschauwer. 
 * 
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND 
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
 * ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE 
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL 
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS 
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) 
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY 
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF 
 * SUCH DAMAGE.
 */

/*
 * resample_addrgen - chroma resampling: address generation
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

module resample_addrgen (
  clk, clk_en, rst,
  output_frame, output_frame_valid, output_frame_rd,
  progressive_sequence, progressive_frame, top_field_first, repeat_first_field, mb_width, mb_height, horizontal_size, vertical_size,
  informative,               // DVD-FORK (film evidence gate): this displayed picture carried real evidence
  output_pts, output_pts_valid, output_pts_2nd,     // DVD-FORK (PTS association): the waiting picture's tag (disp_sched reads it in mpeg2video)
  interlaced, deinterlace, persistence, repeat_frame,
  disp_wr_addr_full, disp_wr_addr_en, disp_wr_addr_ack, disp_wr_addr,
  resample_wr_dta, resample_wr_en,
  disp_wr_addr_almost_full, resample_wr_almost_full,
  busy,
  frame_late,                                       // DVD-FORK (frame-drop governor O[19])
  pickup_cnt,                                       // DVD-FORK (telemetry): content frames picked up for display
  video_live,                                       // DVD-FORK (av_sync STC reference)
  pickup_hold,                                      // DVD-FORK (STD mux-lead hold)
  pause,                                            // DVD-FORK (gamepad transport): freeze frame while paused
  step_req,                                         // DVD-FORK (frame step B18): advance exactly one picture while paused
  pickup_tick,                                      // DVD-FORK (PTS scheduling): one pulse per pickup, to disp_sched
  sched_due, sched_next_due,                        // DVD-FORK (PTS scheduling): from disp_sched
  film_det_ntsc, film_det_pal,                      // DVD-FORK (Film 24p auto-detect): cadence verdicts
  raster_par_err,                                   // DVD-FORK (field-parity corrector): mixer frame-top parity mismatch (synced level)
  par_heal,                                         // DVD-FORK (field start telemetry): one pulse per FEEDBACK insertion
  vscale_mode,                                      // DVD-FORK (CRT anamorphic vertical scaler)
  hcrop_en,                                        // DVD-FORK (CRT anamorphic horizontal crop / pan-scan)
  still_en, scan_start, scan_half,                 // DVD-FORK (pause field still): enable + per-scan sideband to disp_vscale
  blend_en, scan_blend,                            // DVD-FORK (field blend): enable + per-scan sideband to field_blend
  bob_en, scan_bob, scan_bob_bot                   // DVD-FORK (progressive bob): enable + per-scan kernel select
  );

  input              clk;                      // clock
  input              clk_en;                   // clock enable
  input              rst;                      // synchronous active low reset

  input        [2:0]output_frame;              /* frame to be displayed */
  input             output_frame_valid;        /* asserted when output_frame valid */
  output reg        output_frame_rd;
  /* DVD-FORK (telemetry, dvd/dvd_telem.sv): free-running count of frames actually
   * PICKED UP for display. Pure observation -- it is the same condition that sets
   * output_frame_rd, so it cannot change behaviour.
   *
   * Needed because refreshes alone cannot answer the question. The governor is
   * supposed to show each content frame for exactly show_next refreshes; a
   * measured ~450 ppm video-fast drift says the average may be slightly under.
   * refreshes/pickups is that average, measured rather than inferred from the
   * lates and drops ledger -- which is the thing under suspicion, so deriving it
   * from that ledger would assume the answer. */
  output reg [15:0] pickup_cnt;

  input             progressive_sequence;
  input             progressive_frame;
  input             informative;      // DVD-FORK (film evidence gate) — see the gate note at the detector
  /* DVD-FORK (PTS association, docs/av_sync.md "THE STC IS A CLOCK"): the PTS
   * tag of the picture waiting at picbuf's output, and -- pulsed at the pickup --
   * the tag of the picture the display just took. Stage 0 only reports it
   * (telemetry disp_lag = disp_pts - STC); the display scheduler is Stage 1. */
  input       [32:0]output_pts;
  input             output_pts_valid;
  input             output_pts_2nd;
  input             top_field_first;
  input             repeat_first_field;
  input         [7:0]mb_width;                 // par. 6.3.3. width of the encoded luminance component of pictures in macroblocks
  input         [7:0]mb_height;                // par. 6.3.3. height of the encoded luminance component of frame pictures in macroblocks
  input        [13:0]horizontal_size;          // par. 6.2.2.1, par. 6.3.3 
  input        [13:0]vertical_size;            // par. 6.2.2.1, par. 6.3.3

  input              interlaced;               // asserted if display modeline is interlaced
  input              deinterlace;              // asserted if video has to be deinterlaced
  input              persistence;              // asserted if last shown image persists
  input         [4:0]repeat_frame;             // repeat frame if non-zero

  /* reading reconstructed frame: writing address */
  input              disp_wr_addr_full;
  output             disp_wr_addr_en;
  input              disp_wr_addr_ack;
  output       [21:0]disp_wr_addr;

  output reg    [9:0]resample_wr_dta;          // DVD-FORK FIX (F2): [2:0] position code, [9:3] chroma reuse flags
  output reg         resample_wr_en;

  input              disp_wr_addr_almost_full;
  input              resample_wr_almost_full;
  output reg         busy;                     // asserted when generating addresses

  /* DVD-FORK (frame-drop governor, O[19]): 1-cycle pulse whenever the governor is
   * forced to re-scan (repeat) the last displayed image because a new source frame
   * was DUE (refresh_cnt >= SHOW_N) but the decoder had not produced one yet — i.e.
   * a decode deadline miss. Fed to dvd/frame_drop_ctl.sv, which banks it as a
   * "drop credit" and asks the VLD to drop the next B-frame so the decoder catches
   * up. Distinct from the normal within-cadence persistence hold (~frame_due), which
   * is NOT late. See docs/frame_rate_governor.md / docs/motcomp_throughput.md. */
  output reg         frame_late;

  /* DVD-FORK (av_sync STC reference): STICKY level, set the first time the governor
   * picks up a decoded frame for display (STATE_INIT && output_frame_valid). av_sync
   * freezes its STC at the anchor PTS until this goes high, so the STC starts
   * advancing when the first frame actually REACHES THE SCREEN, not when its PES was
   * parsed — the parse leads the display by the whole buffering window (audio_ring +
   * VBUF fill), which is content-dependent and, uncorrected, made the audio genlock
   * target wrong by that much. RE-ARMED per load: a pickup_hold rising edge (the STD
   * mux-lead hold, asserted from every load/seek flush) clears it again, so a clip
   * reload behaves like a cold start (the lip-sync v5 fix; see docs/av_sync.md). */
  output reg         video_live;

  /* DVD-FORK (STD mux-lead hold, 2026-07-02): while high AND no frame has been
   * picked up yet (video_live=0), the FIRST display pickup is deferred — the
   * decoded frame waits in the framestore. Why: DVD muxes audio ~0.5 s BEHIND
   * the video for the same presentation time (VBV lead), so a real player's
   * System Target Decoder displays video ~0.5 s behind the demux position.
   * Displaying the first frame as soon as it decodes put our video that far
   * AHEAD of the audio's arrival timeline — audio trailed by the per-disc mux
   * depth and no output-side scheduling could fix it (can't play data that
   * hasn't arrived). emu asserts this from the clip-load flush and releases it
   * when the audio side holds a dispatchable frame at the anchor PTS (or a
   * ~1.5 s fallback). A RISING edge also RE-ARMS video_live, so a clip reload
   * behaves exactly like a cold start (video_live was sticky-forever before).
   * Ignored once video_live is set — mid-play it can never stall the display. */
  input              pickup_hold;

  /* DVD-FORK (gamepad transport pause, 2-FF synced to clk in emu): while high the
   * governor keeps taking the persistence re-scan branch (the last image is re-scanned
   * every refresh, so the raster shows a steady freeze frame) and never picks up a NEW
   * frame (ofv_pickup/ofv_paced gated below); frame_late is suppressed so the drop
   * debt can't grow during the freeze. av_sync freezes the STC in clk_sys in parallel,
   * halting the PTS-scheduled audio dispatch. Unpause is instant — nothing is reset. */
  input              pause;
  /* DVD-FORK (frame step, B18): a one-cycle request to advance EXACTLY ONE
   * displayed picture while paused. It is armed here and cleared by the pickup
   * it permits, so "one press = one frame" is structural rather than a timed
   * release of `pause` -- releasing pause for a window would show one frame or
   * several depending on where the raster happened to be. Forward only: the
   * decoder is cell/GOP-granular (docs/roadmap.md records sub-cell seek as
   * deferred), so stepping backwards would mean re-decoding from the last
   * anchor, which is a different feature entirely. */
  input              step_req;

  /* DVD-FORK (film-aware drop reclaim): the display duration (refreshes) of the frame
   * currently on display — 3 for a repeat_first_field pulldown frame, else SHOW_N.
   * frame_drop_ctl debits THIS per dropped frame instead of a flat SHOW_N: a flat 2
   * against film's 2.5-refresh average made every drop advance the display ~0.5
   * refresh (~8 ms) ahead of the wall-clock STC the audio genlocks to — the growing
   * audio-late creep on droppy NTSC film (MiB). Sampling the on-display frame's
   * cur_show instead of the dropped B's own rff is statistically identical on
   * uniform-cadence film and exact on PAL (always 2). */
  /* DVD-FORK (PTS scheduling, docs/stc_freerun.md): the display no longer paces
   * itself by counting refreshes. dvd/disp_sched.sv (in mpeg2video) owns a
   * free-running STC and says, from the waiting picture's own PTS, whether it is
   * DUE (sched_due) and whether the timeline has already passed the NEXT picture
   * (sched_next_due -- a starved persistence visit while that holds is a late).
   * pickup_tick reports every pickup back to it. The refresh counter, cur_show,
   * show_next, the film24 one-refresh override, the cadence-slip corrector and
   * the vid_err instrument all lived here and are gone: with PTS as ground truth
   * a late is measured, not inferred, and a drop simply makes the decoder early
   * so later pictures WAIT. */
  output             pickup_tick;
  input              sched_due;
  input              sched_next_due;

  /* DVD-FORK (Film 24p Out — auto detect, issue #124 Phase 2): sticky cadence
   * verdicts, evaluated once per display pickup over the committed (flags_commit-
   * timed) progressive_frame + repeat_first_field. Two verdicts so emu can pick the
   * one matching the resolved standard (pal_eff) WITHOUT threading `pal` down here:
   *   film_det_ntsc = a sustained clean 3:2 soft-telecine run (progressive_frame with
   *                   an alternating rff) — distinguishes 23.976 fps film from 30 fps
   *                   progressive video (which has progressive_frame=1 but rff never
   *                   toggles) and from 60i video (progressive_frame=0).
   *   film_det_pal  = a sustained progressive_frame run — PAL film is native 25p (2:2,
   *                   no rff), so progressive alone is the signal; excludes 50i video.
   * Strong hysteresis (long confirming run to engage, shorter run to disengage). Both
   * bias hard toward NON-film: a false positive forces 24p/25p onto true video =
   * dropped-frame judder (a REGRESSION), a false negative just stays 60/50 Hz
   * (harmless). See docs/film_24p_plan.md §9a. */
  output             film_det_ntsc;
  output             film_det_pal;

  /* (The `det_video` true-interlaced-video verdict — the "Interlaced Out: Auto"
   * detector — lived here 2026-07-27..2026-09-02 and was removed with that option in
   * the Video Output consolidation; see docs/interlaced_auto.md's superseded header.) */

  /* DVD-FORK (field-parity corrector, 2026-09-02): 2-FF-synced level from the mixer —
   * 1 while the most recent displayed frame-top began on the WRONG raster field parity
   * (a TOP-field image scanned out during a bottom raster field or vice versa). Consumed
   * by the corrector at the pickup decision below; qualified there by `interlaced`, so
   * a progressive display never acts on it. Field-rate level, CDC-safe. */
  input              raster_par_err;
  /* DVD-FORK (field start telemetry, 2026-10-08): one clk pulse per FEEDBACK insertion --
   * the pickup arm's (par_slip && par_fb) or the hold arm's (par_hold_ins), the two events
   * that reset par_age. Each is a ~0.5 s misaligned stretch that was then healed. Counted
   * in mpeg2video.v on hard_rst, because this module resets on every soft reset and the
   * soft reset is exactly the start the count exists to measure (telemetry word 31,
   * docs/field_parity.md "Strict first field"). */
  output reg         par_heal;

  /* DVD-FORK (CRT anamorphic VERTICAL scaler, 2026-07-05): display-mode select for
   * the 4:3-CRT 16:9 handling. 0 = FIT (bypass — bit-identical to the pre-scaler
   * datapath: emit every source line 1:1, top-aligned), 1 = LETTERBOX (vertical
   * downscale by 3/4 so 16:9 anamorphic content shows with correct geometry + black
   * bars), anti-aliased by a 2-tap vertical blend of the two straddling source lines.
   * The scaler decouples the SOURCE line read for each emitted OUTPUT line from the
   * output-line index; bars are placed by the mixer's disp_v_offset (this module just
   * emits the scaled line count + the blend weight). Works on BOTH the progressive FRAME
   * path and the interlaced FIELD path (per-field, parity preserved). See
   * docs/crt_anamorphic.md. (Crop — the horizontal pan-scan mode — is hcrop_en below,
   * NOT a vscale_mode: it leaves the vertical at Fit/1:1.)
   * DVD-FORK FIX (SIF analog fill, 2026-08-24): 2 = SIF 2x LINE REPEAT (v_step=128,
   * v_outlines=2x source lines) so sub-D1 MPEG-1 fills the analog raster vertically;
   * see the walk comment below. Mode 1 stays dormant (emu never drives it). */
  input        [1:0] vscale_mode;

  /* DVD-FORK (CRT anamorphic horizontal crop / pan-scan): when high, the address
   * generator reads only the CENTRE ~3/4 of the macroblock columns (skips ~1/8 of the
   * width on each side); the mixer then stretches that cropped line back to the full
   * raster width. Net effect on the 4:3 CRT: 16:9 content shown at correct aspect with
   * full 480 lines of VERTICAL resolution (vertical stays 1:1 — Crop is horizontal-only),
   * sides cropped, no bars. Independent of vscale_mode (Crop uses Fit vertically). */
  input              hcrop_en;

  /* DVD-FORK (PAUSE FIELD STILL, 2026-09-18 — docs/field_parity.md "Pause shows one
   * field"). While paused on the field path, the persistence loop below re-scans the
   * held picture's own two fields forever (T,B,T,B…). For a TRUE-INTERLACED picture
   * (progressive_frame=0) those are two instants 1/59.94 s apart, so the pause flickered
   * between them at 30 Hz — on a CRT and under HDMI Bob alike. A set-top player shows a
   * FIELD STILL instead, and so does this: both raster slots show ONE source field (the
   * one on screen when the pause began), its own slot natively and the opposite slot as a
   * half-line INTERPOLATION of it, which dvd/disp_vscale.sv computes (HALF mode).
   *
   *   still_en   1 = the feature may engage (mpeg2video ties it 1). Benches tie it 0 =
   *              bit-identical to the pre-feature module. Letterbox needs nothing different
   *              HERE: the interpolated slot's read is the same, and disp_vscale applies
   *              the half-line phase inside its 3/4 blend (mode M_LBH).
   *   scan_start one pulse (under clk_en) per image scan that emits a frame-top code —
   *              exactly one per ROW_0_COL_0 / ROW_1_COL_0 that reaches the resample FIFO.
   *   scan_half  the scan being started is the INTERPOLATED slot: it reads the PINNED
   *              field and emits H+1 lines (one duplicated), which disp_vscale turns into H
   *              averaged lines. disp_vscale queues these bits and pops one per frame-top
   *              pixel it receives, so the flag stays aligned with its scan however deep
   *              the resample pipeline between the two modules is.
   *
   * ⚠ The frame-top TAG is untouched: disp_y_sat still follows image_0, so the mixer's
   * frame-top placement, raster_par_err, par_fb and par_hold_ins see exactly the stream
   * they saw before. Only the SOURCE LINES read for the off-parity slot change.
   * ⚠ Film/progressive pictures (progressive_frame=1) keep the woven still — both fields
   * are the same instant, so it is static already and full vertical resolution. */
  input              still_en;
  output             scan_start;
  output             scan_half;

  /* DVD-FORK (FIELD BLEND -- docs/field_blend.md). On the progressive raster a
   * true-interlaced picture is woven, and its two fields are two instants, so motion
   * combs. dvd/field_blend.sv filters every line of such a picture with a fixed
   * [1,2,1] vertical kernel; this module's part mirrors the pause still:
   *   blend_en    the feature is on (emu: the Progressive Deint OSD row, progressive raster)
   *   scan_blend  the scan being started (with scan_start) is a BLEND scan: it emits
   *               H+1 lines, the extra one being line H-2 again -- the bottom line's
   *               mirrored lookahead (field_blend needs one line ahead and the stream
   *               has no end-of-scan marker); field_blend emits H.
   * Engages only on the `deinterlace && ~interlaced` weave arm, only for a picture
   * cur_ilace says is true-interlaced (film keeps its weave, bit-identical), never under
   * the SIF walk or Letterbox. No anchor, no per-scan state: every scan of a picture is
   * marked the same, so a held picture renders identically on each re-scan.
   * The frame-top TAG (disp_y_sat) is untouched: only the line count changes, by one.
   *
   * DVD-FORK (PROGRESSIVE BOB -- docs/field_blend.md "Bob"). The same machinery, a
   * different kernel: field_blend keeps ONE field of the woven frame and rebuilds the
   * other's lines as the average of the kept field's lines above and below.
   *   bob_en        the feature is on (emu: Deinterlace = Bob, progressive raster, not
   *                 the film raster)
   *   scan_bob      the scan being started is a BOB scan (scan_blend is then also 1:
   *                 scan_blend means "a filtered scan, H+1 lines in", whichever kernel)
   *   scan_bob_bot  ... and keeps the BOTTOM field (else the TOP)
   * Which field: the pickup scan keeps the picture's FIRST field (top_field_first,
   * latched at the pickup like cur_ilace) and EVERY later re-scan keeps the SECOND. A
   * pf=0 picture may not carry rff, so on cadence that is exactly first, second = a
   * field-rate bob; a pause, a late re-scan or a held still keeps showing the second
   * field, byte-identical on every re-scan (no 30 Hz flip on a hold). */
  input              blend_en;
  output             scan_blend;
  input              bob_en;
  output             scan_bob;
  output             scan_bob_bot;

`include "vld_codes.v"
`include "mem_codes.v"
`include "resample_codes.v"

  /* 
    progressive_sequence == 1: progressive video, no interlacing. use progressive chroma upsampling.
      repeat_first_field == 0: show frame once.
      repeat_first_field == 1: 
        top_field_first == 0: show frame twice.
        top_field_first == 1: show frame three times.
     
    progressive_sequence == 0: interlacing.
      progressive_frame == 0: use interlaced chroma upsampling.
        top_field_first == 1: show top field, then show bottom field.
        top_field_first == 0: show bottom field, then show top field.
      progressive_frame == 1: use progressive chroma upsampling.
        repeat_first_field == 0: 
          top_field_first == 1: show top field, then show bottom field.
          top_field_first == 0: show bottom field, then show top field.
        repeat_first_field == 1: 
          top_field_first == 1: show top field, then show bottom field, then show top field.
          top_field_first == 0: show bottom field, then show top field, then show bottom field.

    See par. 7.12, Output of the decoding process 

    A slight complication: as a workaround for popular mpeg2 encoder bug,
    if the current frame's progressive_frame flag is "true"
      use progressive chroma upsampling
    else
      if the previous frame's progressive_frame AND repeat_first_field flags are "true"
        use progressive chroma upsampling
       else
        use interlaced chroma upsampling
    ( From: http://www.hometheaterhifi.com/volume_8_2/dvd-benchmark-special-report-chroma-bug-4-2001.html )
  */

  parameter [1:0] 
    NO_OUTPUT         = 3'h0,      // No output
    FRAME             = 3'h1,      // Output frame, progressive chroma upsampling.
    TOP               = 3'h2,      // Output top field, progressive or interlaced chroma upsampling.
    BOTTOM            = 3'h3;      // Output bottom field, progressive or interlaced chroma upsampling.ç

  reg               encoder_bug_workaround;
  reg          [1:0]last_image;
  reg          [1:0]image;
  reg          [1:0]image_0;
  reg          [1:0]image_1;
  reg          [1:0]image_2;
  reg          [1:0]image_3;
  reg          [1:0]image_4;
  reg          [1:0]image_5;
  reg          [4:0]repeat_cnt;

  wire          [7:0]mb_height_minus_one = mb_height - 8'd1;
  wire          [7:0]mb_width_minus_one = mb_width - 8'd1;

  /* DVD-FORK (CRT anamorphic horizontal crop / pan-scan): the centre macroblock-column
   * window actually read when hcrop_en. Crop ~1/8 of the width on each side
   * ((mb_width+4)>>3 rounds 45 -> 6, so 33 of 45 MBs = the centre 528 of 720 px are read
   * and the mixer stretches them to full width). hcrop_mb=0 => full width (Fit/Letterbox),
   * bit-identical. mb_first_c/mb_last_c replace 0/mb_width_minus_one in the disp_mb walk
   * and the COL_0/COL_LAST position codes so the cropped line still carries a clean
   * first/last-column marker for the resample chroma edge handling and the mixer. */
  wire          [7:0]hcrop_mb   = hcrop_en ? ((mb_width + 8'd4) >> 3) : 8'd0;
  wire          [7:0]mb_first_c = hcrop_mb;
  wire          [7:0]mb_last_c  = mb_width_minus_one - hcrop_mb;

  reg          [2:0]output_frame_sav;        /* saved 'output_frame' value */
  reg          [2:0]disp_frame;              /* frame to be fetched from memory. May be OSD_FRAME */
  reg          [1:0]disp_comp;               /* Component to be fetched from memory. If frame, has value COMP_Y, COMP_CR or COMP_CB. If osd, has value COMP_Y */
 /*
  disp_mb counts left to right, one macroblock at a time. 
  disp_y counts top to bottom, one (frame) or two (field) lines at a time.
  */
  reg          [7:0]disp_mb;                 /* horizontal macroblock counter */
  wire        [11:0]disp_x = {disp_mb, 4'b0};/* horizontal coordinate */
  reg         [11:0]disp_y;                  /* vertical line counter */
  /* DVD-FORK FIX (256-line strobe): 2-bit SATURATING mirror of disp_y used ONLY for the
   * frame-top / second-line position-code tests below. The upstream tests compare the
   * full 12-bit disp_y to 0 and 1 to emit ROW_0_COL_0 / ROW_1_COL_0 (the mixer's ONLY
   * frame-top reference). On hardware that wide compare ALSO fired at disp_y==256 (bit 8
   * dropped post-synthesis), emitting a SPURIOUS frame-top at line 256 -> the mixer split
   * the picture across two output frames (the "black frame above 256 lines" strobe; the
   * off-frame is the V-256 bottom slice, not black). A 2-bit register cannot wrap at 256,
   * so it can only ever be 0/1 at the genuine first/second line of the frame.
   * Values: 0 => ROW_0 (frame top), 1 => ROW_1 (second line), >=2 => ROW_X (all the rest).
   * Mirrors disp_y's reset/increment so field parity (TOP starts 0, BOTTOM starts 1,
   * fields step +2 => second line is ROW_X not ROW_1) is preserved exactly. */
  reg          [1:0]disp_y_sat;              /* saturating {0,1,>=2} line index for ROW_0/1/X */
  reg signed  [12:0]disp_delta_x;            /* address generator input */
  reg signed  [12:0]disp_delta_y;            /* address generator input */
  reg signed  [12:0]disp_mv_x;               /* address generator input */
  reg signed  [12:0]disp_mv_y;               /* address generator input */
  reg               disp_valid_in;

  reg               progressive_upscaling;   /* asserted if progressive upscaling, low if interlaced upscaling */
  wire        [11:0]disp_height = {mb_height, 4'b0}; // height in lines
  wire              last_mb = (disp_mb == mb_last_c); // rightmost macroblock of the (possibly cropped) line
  /* DVD-FORK FIX (256-line strobe / picture split): the macroblock-padded emission
   * height (mb_height*16) exceeds the true content height (vertical_size) whenever
   * vertical_size is not a multiple of 16. Those padding lines fall outside the raster
   * active region (= vertical_size) so the mixer cannot start them in their home frame;
   * they WAIT and spill into the next output frame (showing as a sliver at the top),
   * consuming the frame that should have been the persistence repeat => the strobe.
   * Fix: also end the frame once disp_y reaches vertical_size-1, so the emission is
   * exactly the visible height and nothing spills. (For FRAME display disp_y counts
   * every line; the original mb-row test still bounds the field-display paths.) */
  /* --------------------------------------------------------------------------
   * DVD-FORK (CRT anamorphic vertical scaler) — see the vscale_mode port comment.
   *
   * FIT (vscale_mode==0): every wire/register below is BYPASSED; disp_y, last_y and
   * the emission all use the original expressions => bit-identical to the pre-scaler
   * datapath (verified by resample_chain_tb fit bit-identity).
   *
   * When active the scaler keeps disp_y as the SOURCE frame line to read (so the whole
   * fetch / chroma-bilinear datapath below is untouched — it addresses whatever source
   * line disp_y holds), but ADVANCES disp_y by a fractional step and emits v_outlines
   * OUTPUT lines instead of the native line count:
   *   source line for output line i = v_base + stride * round(i * step)
   *     stride = 2 on the field path (stay on the field's parity), 1 progressive
   *     step (Q8.8): LETTERBOX 341 (=4/3, downscale 480->360 / field 240->180)
   *                  SIF 2x   128 (=1/2, upscale 240->480 / 288->576 — line repeat)
   *     v_base = crop offset (+ field parity)
   * Line-index (oline) drives termination and the ROW_0/1/X position codes (via the
   * existing output-index disp_y_sat), so the mixer frame-top pairing is unchanged; the
   * emission height (v_outlines) is <= the raster active region in every mode so nothing
   * spills into the next frame (the 256-line strobe class — docs/history.md).
   *
   * DVD-FORK FIX (SIF analog fill, 2026-08-24) — vscale_mode==2: the SAME walk with
   * v_step=128 and v_outlines = 2*source-lines gives an exact nearest-neighbour 2x line
   * repeat so sub-D1 MPEG-1 (352x240/352x288) fills the analog raster vertically. The
   * rounded walk maps output line i -> source line min(floor((i+1)/2), vertical_size-1):
   * source 0 appears once, N-1 three times — a half-line shift, invisible on a CRT, and
   * replicated EXACTLY by crt_ov_map's inverse (keep them in step). The field path
   * (analog Native Fields) doubles each 120/144-line field to 240/288 parity-preserved
   * lines; its final line clamps to vertical_size-1, which can cross field parity for
   * one bottom line — accepted (see docs/mpeg1.md). Mode 1 (letterbox NN) stays dormant
   * (emu never drives it) and prunes. */
  wire              sif2x       = (vscale_mode == 2'd2);                    // 2 = SIF 2x line repeat (DVD-FORK FIX)
  wire              vscale_en   = (vscale_mode == 2'd1) | sif2x;            // 1 = LETTERBOX (dormant)
  /* per-scan geometry, computed from the INCOMING image (image_0 at STATE_NEXT_IMG) */
  wire              vs_field0   = (image_0 != FRAME);                       // TOP/BOTTOM => field path
  wire       [11:0] vs_H0       = vs_field0 ? vertical_size[11:1] : vertical_size[11:0]; // source lines this scan
  wire       [11:0] vs_par0     = (image_0 == BOTTOM) ? 12'd1 : 12'd0;      // field parity (bottom field = odd lines)
  wire       [11:0] v_base_comb = vs_field0 ? vs_par0 : 12'd0;             // first source line (parity on the field path)
  wire       [11:0] vs_outlines_comb = sif2x ? {vs_H0[10:0], 1'b0}         // SIF 2x: H*2 (240->480 / field 120->240)
                                             : (((vs_H0 << 1) + vs_H0) >> 2); // letterbox: H*3/4 (480->360 / 240->180)

  reg        [11:0] v_base;      // latched source line of output line 0
  reg        [11:0] v_outlines;  // latched number of output lines (termination bound)
  reg               v_stride2;   // latched 1 = field path (source step 2), 0 = progressive
  reg        [8:0]  v_step;      // latched Q8.8 source-index step per output line (341 = 4/3)
  reg        [11:0] oline;       // OUTPUT line index within the current image scan
  reg        [19:0] vacc;        // Q8.8 fractional source-index accumulator

  wire       [19:0] vacc_next    = vacc + {11'd0, v_step};
  wire       [11:0] vsrc_idx     = (vacc_next + 20'd128) >> 8;              // rounded source-index for the NEXT line
  wire       [11:0] v_src_raw    = v_base + (v_stride2 ? {vsrc_idx[10:0], 1'b0} : vsrc_idx);
  wire       [11:0] v_src_max    = (vertical_size == 14'd0) ? 12'hfff : (vertical_size[11:0] - 12'd1);
  wire       [11:0] disp_y_scaled_next = (v_src_raw > v_src_max) ? v_src_max : v_src_raw;

  wire              last_y_native = ((disp_y[11:4] == mb_height_minus_one) && (disp_y[3:0] == ((image == TOP) ? 4'd14 : 4'd15)))
                                 || ((vertical_size != 14'd0) && (disp_y >= (vertical_size[11:0] - 12'd1)));
  /* DVD-FORK (pause field still): the interpolated slot emits H+1 lines (H = field lines),
   * one of them a duplicate, so disp_vscale's HALF blend (which emits on every line but the
   * first) produces exactly H. See the half_scan walk at disp_y below. */
  wire       [11:0] fld_H        = vertical_size[12:1];
  reg               half_scan;   // this scan is the interpolated slot (latched at STATE_NEXT_IMG)
  reg               half_rf;     // pinned BOTTOM in a top slot: repeat the FIRST line, else the last
  /* DVD-FORK (field blend): a BLEND scan emits H+1 frame lines, the last one line H-2
   * (the mirrored bottom edge), so field_blend (one line of lookahead) produces H. */
  wire       [11:0] frm_H        = vertical_size[11:0];
  reg               blend_scan;  // this scan is a blend scan (latched at STATE_NEXT_IMG)
  wire              last_y = half_scan ? (oline >= fld_H)
                           : blend_scan ? (oline >= frm_H)
                           : vscale_en ? (oline >= (v_outlines - 12'd1)) : last_y_native;

  parameter [3:0] 
    STATE_INIT        = 4'h0,      
    STATE_NEXT_IMG    = 4'h1,
    STATE_REPEAT      = 4'h2,
    STATE_NEXT_MB     = 4'h3,
    STATE_WAIT        = 4'h4,
    STATE_WR_OSD_MSB  = 4'h5,
    STATE_WR_OSD_LSB  = 4'h6,
    STATE_WR_Y_MSB    = 4'h7,
    STATE_WR_Y_LSB    = 4'h8,
    STATE_WR_U_UPPER  = 4'h9,
    STATE_WR_U_LOWER  = 4'ha,
    STATE_WR_V_UPPER  = 4'hb,
    STATE_WR_V_LOWER  = 4'hc;

  reg         [3:0]state;
  reg         [3:0]next;

  /* DVD-FORK FIX (F1, docs/decode_pacing.md §7): NO OSD READS. Every macroblock-line used
   * to open with two read requests for the upstream OSD frame (STATE_WR_OSD_MSB/LSB) --
   * 2 of its 8 words, a quarter of ALL display reads -- but this fork ties the OSD layer
   * off (mpeg2video.v dot_osd_enable = 1'b0), so osd.v never shows an OSD pixel and the
   * data was fetched for nothing. On the Progressive raster those dead reads alone are
   * ~21 MB/s of top-priority traffic on the decoder's DDR3 port, and display reads are
   * what raise motion-comp's reference-fetch wait 30-50 % there (MEASURED, decode_pacing).
   * OSD_READS = 0 starts each macroblock at STATE_WR_Y_MSB instead; resample_dta skips
   * its OSD word in step (resample.v passes ONE parameter to both, so they cannot
   * disagree -- a mismatch would shift every word by one and scramble the picture).
   * FIRST_RQ carries the duties that were keyed on the OSD state: scan_begin and the
   * per-macroblock position code written to the resample fifo.
   * OSD_READS = 1 rebuilds the original structure exactly; bench/dvd/run_osd_read.sh
   * builds both and requires bit-identical pixels. */
  parameter OSD_READS = 0;
  localparam [3:0] FIRST_RQ = OSD_READS ? STATE_WR_OSD_MSB : STATE_WR_Y_MSB;

  /* DVD-FORK FIX (F2, docs/decode_pacing.md §7): CHROMA ROW REUSE. Every macroblock-line
   * requested two chroma rows ("upper", "lower") for each of U and V, although one chroma
   * row serves several luma lines. With CHROMA_REUSE = 1 resample_dta keeps the last two
   * rows of each parity of each plane in a small RAM (2 banks x 2 slots x 64 columns),
   * and this module skips the request for any row a slot already holds. Per line it
   * decides, for each of the two rows, fetch (and into which slot) or reuse (from which
   * slot), and sends that decision to resample_dta with every position code
   * (resample_wr_dta[9:3], below), so the two halves cannot disagree about which words exist. Progressive raster: 6 -> 3 words per
   * macroblock-line. Pixels are bit-identical (bench/dvd/run_chroma_reuse.sh).
   * CHROMA_REUSE = 0 rebuilds the F1 structure exactly (the bench baseline). It requires
   * OSD_READS = 0: resample_dta's reuse path has no OSD read. */
  parameter CHROMA_REUSE = 1;
  /* This macroblock's flags, as written to the resample fifo at FIRST_RQ (logic below). */
  wire              cr_fu = resample_wr_dta[3];   // fetch the upper row
  wire              cr_fl = resample_wr_dta[6];   // fetch the lower row

  /* DVD-FORK (PTS scheduling): the deadline is the picture's own PTS against the
   * free-running STC, decided in dvd/disp_sched.sv. */
  reg               det_ntsc, det_pal;      // film detector verdicts (logic below)
  wire              frame_due = sched_due;
  /* DVD-FORK (STD mux-lead hold): the hold window — asserted from every load/seek/
   * jump until the audio catches the new STC anchor (emu.sv av_vid_hold), re-armed
   * per load by the video_live clear below. Shared by ofv_paced AND ofv_pickup so
   * the hold behaves like pause: STATE_REPEAT keeps taking the persistence re-scan
   * branch (last frame held on screen) instead of falling into a parked STATE_INIT
   * (zero scans -> pixel_queue drains -> mixer black). The held frame is safe in
   * DDR3 — no flush touches the frame slots or last_image. */
  wire              hold_freeze = pickup_hold && ~video_live;

  /* DVD-FORK (gamepad pause): force ~ofv_paced while paused so STATE_REPEAT keeps
   * taking the persistence re-scan branch (freeze frame) and never advances to a new
   * frame. Paired with the ofv_pickup gate below (never pick a new frame up) so the
   * display holds the current image indefinitely with the raster still refreshing.
   * hold_freeze gets the same treatment (hold the last clip's frame through a
   * transition, not black — the FSM previously parked in STATE_INIT here). */
  /* DVD-FORK (frame step): armed by step_req, cleared by the pickup it allows.
   * Nothing else clears it, so a press while the decoder has no picture ready
   * waits for one instead of being swallowed. Declared ahead of both gate
   * expressions below -- this file is plain Verilog and Icarus refuses a
   * declaration after use. */
  reg               step_arm;

  /* DVD-FORK (frame step B18): step_arm opens BOTH gates, and bypasses
   * frame_due as well. Two reasons, each of which alone breaks the feature:
   *   - ofv_paced: while paused STATE_REPEAT loops back to STATE_NEXT_IMG
   *     forever (the persistence re-scan), so STATE_INIT -- the only state that
   *     consumes ofv_pickup -- is unreachable. Opening only the pickup gate
   *     therefore advances nothing.
   *   - frame_due: disp_sched freezes the STC under pause, so the next picture
   *     is never scheduled to be due and a step would wait for a clock that is
   *     not running. A step is an explicit "show the next one NOW". */
  wire              ofv_paced = output_frame_valid & (frame_due | step_arm) &
                                (~pause | step_arm) & ~hold_freeze;

  /* DVD-FORK (STD mux-lead hold): qualified pickup. The FIRST pickup (video_live
   * still 0) is deferred while pickup_hold is asserted; once video_live is set the
   * hold can never stall the display. Every pickup-conditioned block below uses
   * this wire so the hold is atomic (no half-taken pickups). */
  wire ofv_pickup = output_frame_valid && ~hold_freeze && (~pause || step_arm);

  /* ================= DVD-FORK (field-parity corrector, 2026-09-02) =================
   * On an interlaced display the mixer maps each emitted field image onto the next
   * raster field, and its frame-top matcher deliberately accepts EITHER parity slot
   * (mixer.v display_first_pixel — the 3:2/drop "black fields" fix). The emitted field
   * sequence normally alternates TOP/BOTTOM (authored cadence keeps strict alternation,
   * and the STATE_REPEAT persistence re-scan below alternates too), so content parity
   * and raster parity stay locked — but ONE odd perturbation flips the phase
   * PERMANENTLY: every TOP image then scans out during a bottom raster field and vice
   * versa, i.e. the whole picture sits one scan-line set off = the field-report "super
   * aliased" CRT image (invisible under HDMI Bob, which is why it shipped unseen;
   * visible on the analog fieldpass raster and ascal Weave). Observed phase breaks: a
   * seek/flush released on an arbitrary first tff, the il_switch raster restart, an
   * Analog Aspect walk's syncgen restart, a mixer underflow, cold-start lock. Toggling
   * the output mode merely re-rolled the coin (the users' "toggle 3-4 times to fix").
   *
   * Correction = insert exactly ONE extra field (an odd insertion flips the slot
   * phase back into alignment) by deferring a due pickup one refresh and re-scanning
   * one field of the HELD frame — persistence-style, so the screen shows real content;
   * cost one refresh (16.7 ms) per event, and a frame_late pulse hands that refresh to
   * the frame-drop ledger (a B-drop removes an EVEN field count on video content, so
   * the reclaim can never re-break parity). Two triggers, both evaluated at the pickup
   * instant, both qualified by `interlaced` (the progressive display path is
   * bit-identical by construction — par_ins can never assert there):
   *  - FEED-FORWARD (alt_break): the pending picture's first field would repeat the
   *    parity of the last displayed field (schedule head == last_image). Catches a
   *    seek-released tff break BEFORE a single wrong field displays.
   *  - FEEDBACK (par_fb): the mixer reports the on-screen frame-top landed on the
   *    wrong raster parity (raster_par_err, 2-FF synced level). Catches what the
   *    schedule cannot see: cold start, raster restarts, underflow slips. Gated by
   *    PAR_CONFIRM (see below) so it only acts on an error that has HELD — its cure
   *    costs a repeated field, and chasing a churning error at field rate is worse
   *    than the error.
   * Design + RED-testbench evidence: docs/field_parity.md. */
  wire       nxt_first_top = progressive_sequence ? 1'b1 : top_field_first; // first field the pending pickup would emit (mirrors the image-build branches)
  wire       alt_break = interlaced &&
                         (((last_image == TOP)    &&  nxt_first_top) ||
                          ((last_image == BOTTOM) && ~nxt_first_top));
  /* ★ THE FEEDBACK ARM ONLY ACTS ON A *STABLE* ERROR (2026-09-03, issue #41 — this is
   * the fix that let the corrector be re-enabled). Its cure costs a REPEATED FIELD:
   * re-showing last_image is the only insertion that lands the resumed stream aligned
   * (inserting the opposite field keeps the misalignment and manufactures an alternation
   * break for alt_break to un-fix — the livelock noted above). One repeated field per
   * genuine phase flip is a fair price; several a second is NOT — that is a still
   * measuring +0.00 field offset where a correct interlaced still measures +0.50, which
   * is exactly what shipped in PR #37 and had to be withdrawn.
   * The trigger it must not chase is a STARVED raster field: when the pixel queue runs
   * dry at a frame-top opportunity the mixer displays nothing there and every following
   * content field lands one slot late, so the parity error is REAL — but this core is
   * compute-bound on heavy content and does that repeatedly, and each starve flips the
   * phase back and forth. Correcting churn at field rate is worse than the churn.
   * So: require the error level to hold across PAR_CONFIRM completed refreshes before
   * inserting. A genuine phase flip (cold start, an il_switch/aspect raster restart, an
   * underflow slip that is not part of a burst) is a STEP — it persists until corrected,
   * so it heals ~0.5 s in and stays healed. Churn resets the count and is ignored.
   * This also subsumes the old par_armed/par_tmo hysteresis: after an insertion the count
   * restarts, so the feedback latency (~1-2 refreshes + CDC) can never double-insert, and
   * insertions are inherently >= PAR_CONFIRM refreshes apart.
   * The FEED-FORWARD arm below is deliberately NOT gated this way: it inserts the
   * OPPOSITE field, so it can never repeat one, and it must act before a wrong field
   * displays. */
  localparam [5:0] PAR_CONFIRM = 6'd30;   // refreshes (~0.5 s at 59.94) the error must hold
  localparam [7:0] PAR_HOLD    = 8'd120;  // refreshes (~2 s) between feedback insertions
  reg  [5:0] par_cnt;                     // consecutive completed refreshes with the error asserted
  reg  [7:0] par_age;                     // refreshes since the last FEEDBACK insertion (saturating)
  wire       par_stable = (par_cnt == PAR_CONFIRM);
  /* Second guard, belt to PAR_CONFIRM's braces: whatever the starvation rate turns out
   * to be on a given disc, a repeated field can never appear more often than once per
   * PAR_HOLD refreshes. PAR_CONFIRM alone bounds it at one per 30 refreshes (2/s), which
   * is still inside the range that reads as judder. Feed-forward insertions do NOT spend
   * this budget — they never repeat a field. */
  wire       par_fb   = interlaced && raster_par_err && par_stable && (par_age == PAR_HOLD) &&
                        ((last_image == TOP) || (last_image == BOTTOM));
  /* XOR, not OR — the triggers CANCEL when simultaneous. Slot arithmetic (fields land
   * on strictly alternating raster slots; a frame-top is accepted at whichever slot
   * comes next): a content alternation break on an ALIGNED stream would land the new
   * head one slot early (alt_break: insert the OPPOSITE field to fill that slot
   * aligned); an intact stream on a MISALIGNED raster needs a one-slot delay (par_fb:
   * re-show the SAME field — it lands aligned on the next slot, and the resumed
   * stream continues consistently); but a content break arriving while ALREADY
   * misaligned lands the new head aligned by itself — two wrongs make a right,
   * insert nothing. Inserting "opposite" on a par_fb would keep the misalignment AND
   * manufacture a new alternation break for alt_break to un-fix — a livelock. */
  /* Re-enabled 2026-09-03 with the PAR_CONFIRM gate above (issue #41). It was tied 0
   * between PR #40 and that fix because the ungated feedback arm repeated a field
   * several times a second on real content; bench/dvd/field_phase_tb.sv scenario [6]
   * is the regression guard (it starves the pixel queue and budgets the repeats). */
  wire       par_ins  = alt_break ^ par_fb;                       // insert one field instead of picking up
  wire       par_slip = (state == STATE_INIT) && ofv_pickup && par_ins;  // the insertion event
  /* Qualified pickup: every pickup-conditioned latch below consumes THIS instead of
   * ofv_pickup, so on an insertion cycle the pending frame stays unconsumed (picked up
   * one refresh later, schedule intact). The FSM's STATE_INIT arc keeps raw ofv_pickup —
   * it must still advance to scan the inserted field. */
  wire       pickup_go = ofv_pickup && ~par_ins;

  /* DVD-FORK (frame step B18): one press = exactly one displayed picture.
   * ⚠ The SET is deliberately outside clk_en: step_req is a one-cycle pulse
   * crossed from clk_sys, and clk_en is low most cycles, so gating the set
   * would swallow most presses. The CLEAR rides pickup_go, which only happens
   * under clk_en -- so the arm survives until a picture is actually taken.
   * If a press coincides with a pickup the set wins and the arm stays, i.e.
   * the press still buys its own frame rather than being absorbed. */
  always @(posedge clk)
    if (~rst) step_arm <= 1'b0;
    else if (step_req)                                        step_arm <= 1'b1;
    /* ⚠ Cleared by the ACTUAL consumption, not by pickup_go. pickup_go is a
     * combinational "a frame could be taken", true for many cycles while the
     * FSM is mid-scan somewhere other than STATE_INIT -- clearing on it
     * disarmed the step one cycle after the press, before any frame was taken,
     * and nothing advanced. STATE_INIT && pickup_go is the same term that
     * drives output_frame_rd, i.e. the cycle the frame is really consumed. */
    else if (clk_en && (state == STATE_INIT) && pickup_go)    step_arm <= 1'b0;

  /* ★ THE FEEDBACK ARM, INSIDE A PERSISTENCE HOLD (2026-09-04).
   * Everything above cures a phase error by DEFERRING A PICKUP. While a frame is being
   * HELD there is no pickup to defer: STATE_REPEAT goes straight back to STATE_NEXT_IMG
   * (the next-state arc below), so STATE_INIT — and with it par_slip — is unreachable
   * for the whole hold, and the repeat branch re-scans an EVEN field pair, which
   * PRESERVES whatever phase the hold started in. A hold entered misaligned therefore
   * stayed misaligned for every held field: 360/360 measured over a 6-second hold,
   * against 0/360 for a hold entered aligned. (The committed gate,
   * bench/dvd/field_phase_tb scenario [8], is the shorter form of the same experiment —
   * pre-fix it burns its whole settle cap and then reports 16/16.)
   * That is the whole of a DVD menu STILL — and a disc whose first content after a mount
   * is a 7 s warning card (one I-frame, then the reader parks) shows the mount's
   * coin-flip landing, combed under Weave and jittering a line on a CRT, for the whole
   * card. A still is also the WORST case for it: frozen dense text is where a one-line
   * error is most visible, which is why it reads as a disc-specific bug.
   * ⚠ For a menu still this is not merely un-entered but unreachable BY CONSTRUCTION:
   * mpeg2video.v's freeze_wd comment records that a still is an end-of-stream hold, so
   * output_frame_valid is 0 — there is no frame to pick up, ever.
   * Cure: emit the held pair in the OTHER order for one visit (see the STATE_REPEAT
   * image-build branch). That repeats one field at the junction — an ODD shift of the
   * content-to-slot mapping, i.e. the re-alignment — while keeping the visit two fields
   * long. On a frozen picture a repeated field is invisible, which is why this arm can
   * be cheap where the pickup-time one is not.
   * Same par_fb budget as the pickup arm, and the counters are SHARED, so the two arms
   * can never double-correct one verdict. */
  wire       par_hold_ins = (state == STATE_REPEAT) && (next == STATE_NEXT_IMG) &&
                            (repeat_cnt == 5'd0) && ~hold_freeze && par_fb;
  /* No combinational loop: next's cone is {state, repeat_cnt, ofv_paced, persistence,
   * last_image, image_0..5} and par_fb's is {interlaced, raster_par_err, par_cnt,
   * par_age, last_image} — all registers and inputs, none of them fed by this wire.
   * (It is also the same qualifier the repeat branch itself already uses.)
   * ~hold_freeze: a clip-load hold belongs to the OUTGOING clip, and spending the
   * PAR_HOLD budget on it could delay the incoming clip's correction by up to 2 s —
   * exactly the latency par_age's saturated reset exists to avoid.
   * repeat_cnt == 0 keeps the decoder's native freeze/slow-motion path bit-identical.
   * `pause` is deliberately NOT excluded: a paused still is precisely when someone is
   * staring at the comb, and av_sync freezes the STC under pause anyway.
   * ⛔ Rejected, so they are not re-proposed: (1) routing the hold through STATE_INIT —
   * there is no valid frame, so it parks there, the pixel queue drains and the mixer
   * goes BLACK, which is the failure hold_freeze was written to prevent; (2) re-picking
   * up the held frame to synthesise a STATE_INIT visit — it would re-latch cur_show and
   * fire the pickup into vid_content_refr for a frame that never advanced, corrupting
   * vid_err and the drop reclaim to fix a cosmetic phase; (3) an emu-side "a still is
   * starting" hint — the error is only observable AFTER the first field displays, by
   * which time the reader has already parked. */

  /* PAR_CONFIRM stability counter: one tick per completed image scan (the same refresh
   * event the governor counts), cleared whenever the mixer's verdict clears — so the
   * count only reaches PAR_CONFIRM for an error that held that whole time — and cleared
   * by an insertion, so the next one is at least PAR_CONFIRM refreshes away. */
  wire       refresh_done = (state == STATE_NEXT_MB) && last_mb && last_y;
  always @(posedge clk)
    if (~rst) par_cnt <= 6'd0;
    else if (clk_en) begin
      if (par_slip || par_hold_ins || ~raster_par_err) par_cnt <= 6'd0;
      else if (refresh_done && ~par_stable)        par_cnt <= par_cnt + 6'd1;
    end

  /* par_age starts SATURATED so the first correction of a session (the cold-start
   * landing, the one case the schedule cannot see at all) is not delayed by the budget.
   * ★ BOTH counters must clear on par_hold_ins too, and that is the anti-double-
   * correction mechanism rather than bookkeeping hygiene: the mixer's verdict is 1-2
   * refreshes + a CDC stale, so if only par_cnt cleared, the first STATE_INIT after the
   * hold would fire par_fb again on the SAME error and re-break the phase it just fixed.
   * The three events cannot collide — refresh_done is STATE_NEXT_MB, par_hold_ins is
   * STATE_REPEAT, par_slip is STATE_INIT — so the if/else ordering hides no priority. */
  always @(posedge clk)
    if (~rst) par_age <= PAR_HOLD;
    else if (clk_en) begin
      if ((par_slip && par_fb) || par_hold_ins)    par_age <= 8'd0;
      else if (refresh_done && (par_age != PAR_HOLD)) par_age <= par_age + 8'd1;
    end

  always @(posedge clk)
    if (~rst) par_heal <= 1'b0;
    else      par_heal <= clk_en && ((par_slip && par_fb) || par_hold_ins);

  reg par_late_r;                      // hand the inserted refresh to the frame-drop ledger (cad_late_r pattern)
  /* ⚠ par_slip ONLY — a hold insertion must NOT pulse frame_late. The addrgen free-runs
   * against the raster, so re-ordering a held pair adds no raster field, no STC tick
   * (emu.sv derives av_refresh_tick from core_v_sync, not from this schedule) and no
   * image scan: nothing was retarded, unlike a deferred pickup, which genuinely diverts
   * one refresh away from a pending frame. Pulsing it here would also land one clk after
   * a STATE_REPEAT cycle — exactly where late_ext asserts — and since frame_late is an OR
   * of pulses the two would merge into one high cycle and UNDER-bank a real late. */
  always @(posedge clk)
    if (~rst) par_late_r <= 1'b0;
    else if (clk_en) par_late_r <= par_slip;
    else par_late_r <= par_late_r;

  /* ================= DVD-FORK (PAUSE FIELD STILL) — see the port comment =================
   * cur_ilace: the DISPLAYED picture is true-interlaced. Latched at the real pickup,
   * because the progressive_frame input describes the picture WAITING at picbuf's output,
   * not the one being held. progressive_sequence pictures are progressive by definition. */
  reg        cur_ilace;
  always @(posedge clk)
    if (~rst) cur_ilace <= 1'b0;
    else if (clk_en && (state == STATE_INIT) && pickup_go) cur_ilace <= ~progressive_frame && ~progressive_sequence;

  /* still_want: evaluated per scan at STATE_NEXT_IMG. ~step_arm: a pending frame step is
   * about to show new content, and the stepped picture's first scan then locks again at
   * the next image (the pin carries across a step, so a run of steps shows one field of
   * each picture, steady). ~sif2x: the SIF walk owns the vertical path (MPEG-1 is
   * progressive anyway). */
  wire       img0_field = (image_0 == TOP) || (image_0 == BOTTOM);
  wire       still_want = still_en && pause && ~step_arm && interlaced && ~deinterlace &&
                          cur_ilace && img0_field && ~sif2x;
  /* pin_bot: the field held on screen — the one scanned LAST when the lock engages, so
   * the pause shows what was on screen rather than jumping back half a frame. Held for
   * as long as the lock is wanted; re-pinned on the next engage.
   * ⚠ At STATE_NEXT_IMG the scan that just finished is in `image`, NOT last_image:
   * last_image is only updated in this same cycle, so it still names the scan BEFORE.
   * `image` is NO_OUTPUT only when the scan came through STATE_REPEAT, and there
   * last_image has already caught up. (The first cut pinned last_image and held the
   * other field — pause_still_tb caught it as a correct still of the wrong parity.) */
  reg        pin_valid, pin_bot;
  wire [1:0] just_shown  = ((image == TOP) || (image == BOTTOM)) ? image : last_image;
  wire       pin_bot_now = pin_valid ? pin_bot
                         : ((just_shown == TOP) || (just_shown == BOTTOM)) ? (just_shown == BOTTOM)
                         : (image_0 == BOTTOM);
  wire       scan_begin  = (state == STATE_NEXT_IMG) && (next == FIRST_RQ);   // DVD-FORK FIX (F1): the first request state, OSD or Y
  /* The scan being started is the OFF-parity slot of a locked still. */
  wire       half_now    = still_want && ((image_0 == BOTTOM) != pin_bot_now);
  always @(posedge clk)
    if (~rst) begin pin_valid <= 1'b0; pin_bot <= 1'b0; end
    else if (clk_en && scan_begin) begin
      pin_valid <= still_want;
      pin_bot   <= pin_bot_now;
    end

  /* Per-scan latches for the walk (read-parity pin, repeat-first vs repeat-last). */
  /* half_scan / half_rf are declared with the walk (above) -- plain Verilog, no use before declaration. */
  always @(posedge clk)
    if (~rst) begin half_scan <= 1'b0; half_rf <= 1'b0; end
    else if (clk_en && (state == STATE_NEXT_IMG)) begin
      half_scan <= half_now;
      half_rf   <= pin_bot_now;
    end

  assign scan_start = clk_en && scan_begin;
  assign scan_half  = half_now;

  /* ================= DVD-FORK (FIELD BLEND) -- see the port comment =================
   * blend_want: the weave arm (progressive raster), a true-interlaced DISPLAYED picture
   * (cur_ilace, latched at the real pickup), and neither Letterbox nor the SIF walk owning
   * the vertical path. Evaluated per scan at STATE_NEXT_IMG. */
  wire       filt_ok    = deinterlace && ~interlaced && cur_ilace && ~vscale_en && ~sif2x &&
                          (image_0 == FRAME);
  wire       blend_now  = blend_en && filt_ok;
  /* DVD-FORK (progressive bob): same gate, the bob kernel. Blend wins if both are ever
   * set (emu decodes one 2-bit option, so they cannot be). */
  wire       bob_now    = bob_en && ~blend_en && filt_ok;
  /* cur_tff: the DISPLAYED picture's first field, latched at the real pickup for the
   * same reason as cur_ilace. pic_scanned: a scan of the displayed picture has already
   * begun, so this one is a re-scan (STATE_REPEAT) and keeps the SECOND field. */
  reg        cur_tff, pic_scanned;
  always @(posedge clk)
    if (~rst) begin cur_tff <= 1'b1; pic_scanned <= 1'b0; end
    else if (clk_en && (state == STATE_INIT) && pickup_go) begin
      cur_tff     <= top_field_first;
      pic_scanned <= 1'b0;
    end
    else if (clk_en && scan_begin) pic_scanned <= 1'b1;
  wire       bob_bot_now = pic_scanned ? cur_tff : ~cur_tff;   // keep BOTTOM
  always @(posedge clk)
    if (~rst) blend_scan <= 1'b0;
    else if (clk_en && (state == STATE_NEXT_IMG)) blend_scan <= blend_now | bob_now;
  assign scan_blend   = blend_now | bob_now;
  assign scan_bob     = bob_now;
  assign scan_bob_bot = bob_bot_now;

  /* next state logic */
  always @*
    case (state)
      STATE_INIT:         if (ofv_pickup) next = STATE_NEXT_IMG; // scan whenever a frame exists (bootstrap); pacing is the STATE_REPEAT hold below
                          else next = STATE_INIT;

      STATE_NEXT_IMG:     if ((image_0 == NO_OUTPUT) && (image_1 == NO_OUTPUT) && (image_2 == NO_OUTPUT) &&
                              (image_3 == NO_OUTPUT) && (image_4 == NO_OUTPUT) && (image_5 == NO_OUTPUT)) next = STATE_REPEAT; 
                          else next = FIRST_RQ;  // DVD-FORK FIX (F1): Y when OSD_READS = 0

      STATE_REPEAT:       if (repeat_cnt != 5'd0) next = STATE_NEXT_IMG; // repeat frame 
                          else if (~ofv_paced && persistence && (last_image != NO_OUTPUT)) next = STATE_NEXT_IMG; // DVD-FORK: repeat last image while next frame not due (or none yet)
                          else next = STATE_INIT;

      STATE_NEXT_MB:      if (last_mb && last_y) next = STATE_NEXT_IMG;
                          else next = STATE_WAIT;

      STATE_WAIT:         if (disp_wr_addr_almost_full || resample_wr_almost_full) next = STATE_WAIT;
                          else next = FIRST_RQ;  // DVD-FORK FIX (F1): Y when OSD_READS = 0

      STATE_WR_OSD_MSB:   next = STATE_WR_OSD_LSB; // output osd read requests - 16 pixels

      STATE_WR_OSD_LSB:   next = STATE_WR_Y_MSB;

      STATE_WR_Y_MSB:     next = STATE_WR_Y_LSB; // output luminance read requests - 16 pixels

      /* DVD-FORK FIX (F2): with CHROMA_REUSE a chroma request is issued only for a row
       * that is fetched (cr_fu / cr_fl, this macroblock's flags, written at FIRST_RQ). */
      STATE_WR_Y_LSB:     if ((CHROMA_REUSE == 0) || cr_fu) next = STATE_WR_U_UPPER;
                          else if (cr_fl) next = STATE_WR_U_LOWER;
                          else next = STATE_NEXT_MB;

      STATE_WR_U_UPPER:   if ((CHROMA_REUSE == 0) || cr_fl) next = STATE_WR_U_LOWER; // output chroma read requests - 2 rows of 8
                          else next = STATE_WR_V_UPPER;

      STATE_WR_U_LOWER:   if ((CHROMA_REUSE == 0) || cr_fu) next = STATE_WR_V_UPPER;
                          else next = STATE_WR_V_LOWER;

      STATE_WR_V_UPPER:   if ((CHROMA_REUSE == 0) || cr_fl) next = STATE_WR_V_LOWER; // output chroma read requests - 2 rows of 8
                          else next = STATE_NEXT_MB;

      STATE_WR_V_LOWER:   next = STATE_NEXT_MB;

      default             next = STATE_INIT;

    endcase

  /* state */
  always @(posedge clk)
    if(~rst) state <= STATE_INIT;
    else if (clk_en) state <= next;
    else state <= state;

  always @(posedge clk)
    if (~rst) busy <= 1'd0;
    else if (clk_en) busy <= (next != STATE_INIT);
    else busy <= busy;

  always @(posedge clk)
    if (~rst) output_frame_rd <= 1'd0;
    else if (clk_en) output_frame_rd <= (state == STATE_INIT) && pickup_go; // INIT is reached at hold release (the held frame re-scans in STATE_REPEAT), or during a cold start with nothing to hold; parity insertion defers the read one refresh
    else output_frame_rd <= output_frame_rd;

  /* DVD-FORK (telemetry): count the same event, in the same clk_en domain. */
  always @(posedge clk)
    if (~rst) pickup_cnt <= 16'd0;
    else if (clk_en && (state == STATE_INIT) && pickup_go) pickup_cnt <= pickup_cnt + 16'd1;

  /*
   * DVD-FORK (frame-drop governor, O[19]/O[12]): deadline-miss detector. STATE_REPEAT is a
   * single-cycle decision state; when it takes the persistence re-scan branch
   * (line "repeat last image") the miss is "late" only if the frame was already DUE
   * (frame_due) yet not valid — otherwise it's the normal within-SHOW_N hold.
   *
   * DVD-FORK FIX (film 3:2 cadence): with the cadence-aware pacing above, every frame's
   * deadline is its TRUE display duration (cur_show = 3 or 2 refreshes), so ANY deadline
   * miss is a REAL decoder miss — there are no "structural" false lates anymore. (Those
   * only existed under the old flat SHOW_N=2 deadline, which wrongly demanded a new frame
   * every 2 refreshes even mid-pulldown; a `film_slack` credit scheme that forgave one
   * miss per pulldown frame was tried here and REMOVED: on compute-marginal film clips
   * the decoder misses exactly the short 33 ms windows, the slack silently forgave every
   * one of them, the cadence collapsed to 3,3,3,3 ≈ 20 fps — video looked smooth but ran
   * ~17 % slow, starving the shared-stream audio delivery (the constant audio dropouts),
   * and frame_late never fired so O[12] Frame Drop couldn't catch the timeline up. HW-
   * diagnosed 2026-07-02.) Report every real miss: with O[12] on, the governor drops a
   * B-frame and holds the timeline — video stays at content rate, audio stays fed.
   */
  wire       late_raw    = (state == STATE_REPEAT) && (repeat_cnt == 5'd0) &&
                           persistence && (last_image != NO_OUTPUT) &&
                           sched_next_due && ~output_frame_valid && ~pause &&  // DVD-FORK (PTS scheduling): the timeline has passed the next picture and there is none -- a real decode miss
                           ~hold_freeze;  // DVD-FORK (hold-frame transitions): hold-window lateness is mux-lead policy, not decode debt — without this, lates bank drop debt once the refilling VBUF passes vbuf_healthy but before the new clip's first frame decodes, dropping B-frames right at clip start

  /* ⚠⚠ frame_late's DRIVER WAS DELETED BY THE STAGE-1 GOVERNOR SURGERY AND RESTORED
   * 2026-09-07. The cut that removed refresh_cnt/cur_show/cad_acc took this
   * always block with it, leaving `output reg frame_late` declared and never
   * assigned -- so Quartus tied it low and the ENTIRE lateness->drop ledger was
   * dead. frame_drop_ctl saw only the scheduler's catch-up request, O[12] Frame
   * Drop could not act on a real decode miss, and late_raw (computed above, and
   * correct) drove nothing at all. Found by `verilator --lint-only -Wwarn-UNDRIVEN`
   * over the .qsf's own file list, in the audit that followed the missing pts_cdc.
   * ⚠ late_ext is KEPT. On the field path a REPEAT visit re-scans a PAIR, so one
   * miss costs TWO refreshes and the ledger must count two; the plan listed the
   * stretch as retired, but nothing measured said it should be, and an
   * under-counting ledger still starves the drops that PTS scheduling needs to
   * catch a late display up. cad_late_r is genuinely gone with the cadence
   * corrector; par_late_r stays, because the field-parity corrector stays. */
  wire late_pair = (last_image == TOP) || (last_image == BOTTOM);
  reg  late_ext;
  always @(posedge clk)
    if (~rst) late_ext <= 1'b0;
    else if (clk_en) late_ext <= late_raw && late_pair;
    else late_ext <= late_ext;
  always @(posedge clk)
    if (~rst) frame_late <= 1'b0;
    else if (clk_en) frame_late <= late_raw | late_ext | par_late_r;
    else frame_late <= frame_late;

  /* DVD-FORK (PTS scheduling): one registered pulse per pickup, for disp_sched. */
  reg       pickup_tick_r;
  always @(posedge clk)
    if (~rst) pickup_tick_r <= 1'b0;
    else pickup_tick_r <= clk_en && (state == STATE_INIT) && pickup_go;
  assign pickup_tick = pickup_tick_r;

  /* ================= DVD-FORK (Film 24p Out — auto film detector) =================
   * Recognise soft-telecined film from the per-frame display flags — no pixel
   * analysis. Evaluated once per display pickup (the same strobe that latches
   * cur_show/pickup_show), so it sees the flags_commit-correct per-picture values.
   *
   * NTSC 23.976 fps film is coded as progressive_frame=1 with repeat_first_field
   * ALTERNATING 1,0,1,0 (the 3:2 / 5-fields-per-2-frames cadence). 30 fps progressive
   * video is progressive_frame=1 but rff NEVER toggles; 60i video is progressive_
   * frame=0. So "progressive AND rff toggled vs the previous frame" is the specific
   * telecine signature (film_det_ntsc). PAL 25p film is native 2:2 (progressive_frame
   * =1, rff=0), indistinguishable from 25 fps progressive video by flags — and both
   * WANT 25p — so a sustained progressive run alone is the PAL signal (film_det_pal);
   * only 50i video (progressive_frame=0) is excluded.
   *
   * Hysteresis via a SATURATING CONFIDENCE accumulator (NOT a strict consecutive-run
   * counter). Each pickup nudges the confidence: +UP for a confirming frame, -DN for a
   * non-confirming one, clamped to [0, CONF_MAX]. `det` sets at ENGAGE_TH, clears at
   * DISENGAGE_TH. Why confidence, not a consecutive run (2026-07-25 HW fix): a strict
   * "reset the run to 0 on any break" detector engaged fine on a clean menus-OFF stream
   * but NOT when the film title was reached through the disc MENU/VM — the nav layer
   * (NAV packs, cell/PGC boundaries, VM POST, brief stills) injects periodic cadence
   * hiccups during title playback that kept zeroing the run before it reached lock. A
   * confidence that DECAYS on a hiccup (instead of resetting) rides through them and
   * still locks, while the FALSE-POSITIVE GUARD is preserved: 30 fps progressive video
   * produces ZERO confirming frames (rff never toggles), so its confidence only ever
   * decays — it can never reach ENGAGE_TH. The NTSC non-confirming step is split:
   * DN_HARD for an interlaced frame (definitely not film) vs the gentler DN_SOFT for a
   * progressive-but-not-toggling frame (a telecine hiccup OR 30p video — the duration,
   * via the accumulator, tells them apart). Bias stays toward NON-film. */
  localparam [7:0] CONF_MAX     = 8'd127;
  localparam [7:0] ENGAGE_TH    = 8'd120;  // ~40 clean film frames from 0 (~1.7 s) to lock
  localparam [7:0] DISENGAGE_TH = 8'd24;   // deep hysteresis: ~50 non-film frames from full to release
  localparam [7:0] UP_STEP      = 8'd3;
  localparam [7:0] DN_SOFT      = 8'd2;    // progressive but rff didn't toggle (hiccup / 30p video)
  localparam [7:0] DN_HARD      = 8'd8;    // interlaced frame (progressive_frame=0)
  reg        rff_q;                        // previous frame's rff (for the toggle test)
  reg  [7:0] conf_ntsc, conf_pal;
  // (det_ntsc/det_pal are DECLARED EARLIER, beside the PTS-scheduling note —
  //  iverilog rejects declaration-after-use.)
  wire       film_pickup = (state == STATE_INIT) && pickup_go;
  wire       rff_toggled = (repeat_first_field != rff_q);
  wire       good_ntsc   = progressive_frame && rff_toggled;   // clean 3:2 telecine frame
  always @(posedge clk)
    if (~rst) begin
      rff_q     <= 1'b0;
      conf_ntsc <= 8'd0; conf_pal <= 8'd0;
      det_ntsc  <= 1'b0; det_pal  <= 1'b0;
    /* ★ DVD-FORK (film evidence gate, 2026-08-30) — the `informative` term.
     *
     * progressive_frame is the ENCODER's claim, not a measurement, and on a
     * near-black picture there is nothing to measure: the encoder takes the
     * MPEG-2 default and marks it interlaced. Counting that claim is what made
     * APOLLO_13's fading credits knock this detector out of film lock NINE
     * times in the first 46 s of the title, re-walking the raster each time.
     *
     * VLC's IVTC hits the same content and rides through it, because it reads
     * pixels and refuses to score a frame it cannot trust — "If no motion, the
     * result from this algorithm cannot be reliable ... we do nothing, as it's
     * not a good idea to act on unreliable data". `informative` is that rule
     * with coded picture size standing in for motion (measured in the vld; see
     * rtl/mpeg2/vld.v). An uninformative pickup updates NOTHING — not the
     * confidences and not rff_q, so the 3:2 toggle test resumes across the gap
     * rather than seeing a false edge.
     *
     * Measured effect (tools/film_evidence_probe.py, real discs, this exact
     * arithmetic): APOLLO_13 credits 9 raster changes -> 1. FERRIS_BUELLER's
     * special feature, which really does turn from film to video mid-title,
     * keeps BOTH of its transitions at the same timestamps as before — so the
     * detector still follows genuine changes in about a second, and none of
     * this needs the per-title latch that cost 12 s to leave film mode.
     * Library sweep, 123 discs: 15 better, 0 worse. */
    end else if (clk_en && film_pickup && informative) begin
      rff_q <= repeat_first_field;
      // ---- NTSC telecine confidence ----
      begin : ntsc_conf
        reg [7:0] cn;
        if (good_ntsc)
          cn = (conf_ntsc > (CONF_MAX - UP_STEP)) ? CONF_MAX : conf_ntsc + UP_STEP;
        else if (!progressive_frame)
          cn = (conf_ntsc < DN_HARD) ? 8'd0 : conf_ntsc - DN_HARD;
        else
          cn = (conf_ntsc < DN_SOFT) ? 8'd0 : conf_ntsc - DN_SOFT;
        conf_ntsc <= cn;
        if      (cn >= ENGAGE_TH)    det_ntsc <= 1'b1;
        else if (cn <= DISENGAGE_TH) det_ntsc <= 1'b0;
      end
      // ---- PAL 25p confidence (progressive alone; rff irrelevant for 2:2) ----
      begin : pal_conf
        reg [7:0] cp;
        if (progressive_frame)
          cp = (conf_pal > (CONF_MAX - UP_STEP)) ? CONF_MAX : conf_pal + UP_STEP;
        else
          cp = (conf_pal < DN_HARD) ? 8'd0 : conf_pal - DN_HARD;
        conf_pal <= cp;
        if      (cp >= ENGAGE_TH)    det_pal <= 1'b1;
        else if (cp <= DISENGAGE_TH) det_pal <= 1'b0;
      end
    end
  assign film_det_ntsc = det_ntsc;
  assign film_det_pal  = det_pal;

  /* DVD-FORK (av_sync STC reference): sticky "display has shown a decoded frame".
   * Same pickup condition as cur_show above — the first real frame entering the
   * image build is, one scan later, on the screen. */
  reg pickup_hold_d;
  always @(posedge clk) pickup_hold_d <= pickup_hold;

  always @(posedge clk)
    if (~rst) video_live <= 1'b0;
    else if (pickup_hold && ~pickup_hold_d) video_live <= 1'b0;  // clip load: re-arm
    else if (clk_en && (state == STATE_INIT) && pickup_go) video_live <= 1'b1;
    else video_live <= video_live;

  /*
   * repeat frame counter
   */

  always @(posedge clk)
    if (~rst) repeat_cnt <= 5'd0;
    else if (clk_en && (state == STATE_INIT)) repeat_cnt <= repeat_frame;
    else if (clk_en && (state == STATE_REPEAT) && (repeat_cnt == 5'd31)) repeat_cnt <= repeat_frame;
    else if (clk_en && (state == STATE_REPEAT) && (repeat_cnt != 5'd0)) repeat_cnt <= repeat_cnt - 5'd1;
    else repeat_cnt <= repeat_cnt;

  /* counters */

  /* DVD-FORK (CRT anamorphic horizontal crop): the macroblock walk starts at mb_first_c
   * (the left crop edge) and ends at mb_last_c; hcrop_mb=0 => 0..mb_width_minus_one as
   * before (bit-identical). */
  always @(posedge clk)
    if (~rst) disp_mb <= 8'd0;
    else if (clk_en && (state == STATE_NEXT_IMG)) disp_mb <= mb_first_c;
    else if (clk_en && (state == STATE_NEXT_MB) && last_mb) disp_mb <= mb_first_c;
    else if (clk_en && (state == STATE_NEXT_MB)) disp_mb <= disp_mb + 8'd1;
    else disp_mb <= disp_mb;

  /* DVD-FORK (CRT anamorphic vscale): when vscale_en, disp_y is driven from the
   * fractional source-index accumulator (v_base + stride*round(step*i)); otherwise the
   * original 1:1 (frame +1) / field (+2) stepping — bit-identical in FIT. */
  always @(posedge clk)
    if (~rst) disp_y <= 12'd0;
    /* DVD-FORK (pause field still): the interpolated slot reads the PINNED field's lines
     * (parity = pin, not image_0) and duplicates one end so H+1 lines go out:
     *   pinned TOP, bottom slot:  T0 T1 … T(H-1) T(H-1)   (hold at the last line)
     *   pinned BOT, top slot:     B0 B0 B1 … B(H-1)       (hold after the first line)
     * disp_vscale averages each line with the one before, so raster line 2k+1 gets
     * (T_k+T_k+1)/2 and raster line 2k gets (B_k-1+B_k)/2 — each at its true half-line
     * position. oline is the index of the line just finished. */
    else if (clk_en && (state == STATE_NEXT_IMG)) disp_y <= half_now ? (pin_bot_now ? 12'd1 : 12'd0)
                                                           : vscale_en ? v_base_comb : ((image_0 == BOTTOM) ? 12'd1 : 12'd0);
    else if (clk_en && (state == STATE_NEXT_MB) && last_mb && half_scan)
      disp_y <= (half_rf ? (oline == 12'd0) : (oline >= (fld_H - 12'd1))) ? disp_y : disp_y + 12'd2;
    /* DVD-FORK (field blend): after the last frame line a BLEND scan steps BACK one line,
     * so its extra (H+1th) line is line H-2 -- field_blend's `d` for the bottom line, which
     * makes the bottom edge a mirror (d := a) like the top. */
    else if (clk_en && (state == STATE_NEXT_MB) && last_mb && blend_scan)
      disp_y <= (oline == (frm_H - 12'd1)) ? disp_y - 12'd1 : disp_y + 12'd1;
    else if (clk_en && (state == STATE_NEXT_MB) && last_mb) disp_y <= vscale_en ? disp_y_scaled_next : ((image == FRAME) ? disp_y + 12'd1 : disp_y + 12'd2);
    else disp_y <= disp_y;

  /* DVD-FORK (CRT anamorphic vscale): per-scan geometry latched at pickup of each image
   * (STATE_NEXT_IMG, from the incoming image_0), plus the source-index accumulator and
   * the output-line counter. Inert in FIT (disp_y ignores them). */
  always @(posedge clk)
    if (~rst) begin
      v_base <= 12'd0; v_outlines <= 12'd1; v_stride2 <= 1'b0; v_step <= 9'd0;
    end else if (clk_en && (state == STATE_NEXT_IMG)) begin
      v_base     <= v_base_comb;
      v_outlines <= vs_outlines_comb;
      v_stride2  <= vs_field0;
      v_step     <= sif2x ? 9'd128 : 9'd341;           // Q8.8: 1/2 SIF 2x repeat / 4/3 letterbox downscale
    end

  always @(posedge clk)
    if (~rst) vacc <= 20'd0;
    else if (clk_en && (state == STATE_NEXT_IMG)) vacc <= 20'd0;
    else if (clk_en && (state == STATE_NEXT_MB) && last_mb) vacc <= vacc_next;

  always @(posedge clk)
    if (~rst) oline <= 12'd0;
    else if (clk_en && (state == STATE_NEXT_IMG)) oline <= 12'd0;
    else if (clk_en && (state == STATE_NEXT_MB) && last_mb) oline <= oline + 12'd1;

  /* DVD-FORK FIX: saturating mirror of disp_y for the ROW_0/ROW_1/ROW_X tests.
   * Reset to match disp_y's start (1 for BOTTOM field, else 0). On each line:
   *  - FRAME: +1, saturating at 2  => 0,1,2,2,... matching disp_y==0/1 then ROW_X.
   *  - field (+2 in disp_y): jump straight to 2 after the first line, so only the
   *    very first line (disp_y 0 or 1) is ROW_0/ROW_1 and the rest are ROW_X --
   *    exactly as the upstream disp_y==0/disp_y==1 tests behave for fields. */
  always @(posedge clk)
    if (~rst) disp_y_sat <= 2'd0;
    else if (clk_en && (state == STATE_NEXT_IMG)) disp_y_sat <= (image_0 == BOTTOM) ? 2'd1 : 2'd0;
    else if (clk_en && (state == STATE_NEXT_MB) && last_mb)
      disp_y_sat <= (image == FRAME) ? ((disp_y_sat == 2'd2) ? 2'd2 : disp_y_sat + 2'd1) : 2'd2;
    else disp_y_sat <= disp_y_sat;

  /* one output frame may have to be shown up to three times (par. 7.12) */
  always @(posedge clk)
    if (~rst)
      begin
        image   <= NO_OUTPUT;
        image_0 <= NO_OUTPUT;
        image_1 <= NO_OUTPUT;
        image_2 <= NO_OUTPUT;
        image_3 <= NO_OUTPUT;
        image_4 <= NO_OUTPUT;
        image_5 <= NO_OUTPUT;
        progressive_upscaling <= 1'b0;
      end
    else if (clk_en && par_slip) // DVD-FORK (field-parity corrector): insert ONE field of the HELD frame; the pending pickup waits one refresh
      begin
        image   <= NO_OUTPUT;
        // par_fb (raster misaligned, content intact): re-show the SAME field — it lands
        // aligned on the next slot. alt_break (content break, raster aligned): show the
        // OPPOSITE field — it fills the slot the break would have skipped. par_ins
        // guarantees last_image is TOP or BOTTOM. See the XOR note above.
        image_0 <= par_fb ? last_image
                          : ((last_image == TOP) ? BOTTOM : TOP);
        image_1 <= NO_OUTPUT;
        image_2 <= NO_OUTPUT;
        image_3 <= NO_OUTPUT;
        image_4 <= NO_OUTPUT;
        image_5 <= NO_OUTPUT;
        progressive_upscaling <= progressive_upscaling;
      end
    else if (clk_en && (state == STATE_INIT) && pickup_go) // build image sequence on pickup (INIT is reached paced)
      begin
        /*
         * display progressive sequence on progressive display. Display frames.
         */
        if (progressive_sequence && ~interlaced)
          begin
            image   <= NO_OUTPUT;
            image_0 <= FRAME;
            image_1 <= (repeat_first_field) ? FRAME : NO_OUTPUT;
            image_2 <= (repeat_first_field && top_field_first) ? FRAME : NO_OUTPUT;
            image_3 <= NO_OUTPUT;
            image_4 <= NO_OUTPUT;
            image_5 <= NO_OUTPUT;
            progressive_upscaling <= 1'b1;
          end
        /*
         * Interlacing: display progressive sequence on interlaced display. Display fields.
         */
        else if (progressive_sequence && interlaced)
          begin
            image   <= NO_OUTPUT;
            image_0 <= TOP;
            image_1 <= BOTTOM;
            image_2 <= (repeat_first_field) ? TOP : NO_OUTPUT;
            image_3 <= (repeat_first_field) ? BOTTOM : NO_OUTPUT;
            image_4 <= (repeat_first_field && top_field_first) ? TOP : NO_OUTPUT;
            image_5 <= (repeat_first_field && top_field_first) ? BOTTOM : NO_OUTPUT;
            progressive_upscaling <= 1'b1;
          end
        /*
         * XXX Deinterlacing: display is progressive and deinterlacing is requested. Display frame.
         */
        else if (deinterlace && ~interlaced) 
          begin
            image   <= NO_OUTPUT;
            image_0 <= FRAME;
            image_1 <= NO_OUTPUT;
            image_2 <= NO_OUTPUT;
            image_3 <= NO_OUTPUT;
            image_4 <= NO_OUTPUT;
            image_5 <= NO_OUTPUT;
            progressive_upscaling <= (progressive_frame || encoder_bug_workaround);
          end
         /*
          * Interlaced display, progressive frame.
          */
        else if (progressive_frame)
          begin
            image   <= NO_OUTPUT;
            image_0 <= (top_field_first) ? TOP : BOTTOM;
            image_1 <= (top_field_first) ? BOTTOM : TOP;
            image_2 <= (repeat_first_field) ? ((top_field_first) ? TOP : BOTTOM) : NO_OUTPUT;
            image_3 <= NO_OUTPUT;
            image_4 <= NO_OUTPUT;
            image_5 <= NO_OUTPUT;
            progressive_upscaling <= 1'b1;
          end
        else
         /*
          * Interlaced display, interlaced frame.
          */
          begin
            image   <= NO_OUTPUT;
            image_0 <= (top_field_first) ? TOP : BOTTOM;
            image_1 <= (top_field_first) ? BOTTOM : TOP;
            image_2 <= NO_OUTPUT;
            image_3 <= NO_OUTPUT;
            image_4 <= NO_OUTPUT;
            image_5 <= NO_OUTPUT;
            progressive_upscaling <= encoder_bug_workaround;
          end
      end
    else if (clk_en && (state == STATE_REPEAT) && (next == STATE_NEXT_IMG))
      /*
       * Repeat last shown image.
       * If last shown image was a frame, show frame.
       * If last shown image was a field image, show both fields.
       *
       * DVD-FORK (field-parity corrector, hold arm, 2026-09-04): on par_hold_ins the
       * pair is emitted in the OTHER ORDER for this one visit. The junction then repeats
       * a field (…T | T…), which is an ODD shift of the content-to-slot mapping = the
       * re-alignment, and the tail parity flips so the stream stays strictly alternating
       * from there. See the par_hold_ins comment above for why this arm exists.
       * ⛔ NOT the obvious "image_0 <= last_image; image_1 <= NO_OUTPUT" one-field form.
       * It emits the identical stream, but it makes the visit ONE field long, and
       * late_pair/late_ext below stretch frame_late to two cycles precisely BECAUSE a
       * repeat visit is a field PAIR — so a plain decode-stall hold would bank one
       * refresh of phantom drop debt per correction (an unearned B-drop, ~33 ms). It
       * also leaves the tail on the same parity, so a tff=1 resume re-fires alt_break
       * for a phase already fixed. Swapping the pair costs nothing in either ledger.
       */
      begin
        image   <= NO_OUTPUT;
        case (last_image)
          FRAME:
            begin
              image_0 <= FRAME;
              image_1 <= NO_OUTPUT;
            end
          TOP:
            begin
              image_0 <= par_hold_ins ? TOP    : BOTTOM;
              image_1 <= par_hold_ins ? BOTTOM : TOP;
            end
          BOTTOM:
            begin
              image_0 <= par_hold_ins ? BOTTOM : TOP;
              image_1 <= par_hold_ins ? TOP    : BOTTOM;
            end
          NO_OUTPUT:
            begin
              image_0 <= NO_OUTPUT;
              image_1 <= NO_OUTPUT;
            end
          default
            begin
              image_0 <= NO_OUTPUT;
              image_1 <= NO_OUTPUT;
            end
        endcase
        image_2 <= NO_OUTPUT;
        image_3 <= NO_OUTPUT;
        image_4 <= NO_OUTPUT;
        image_5 <= NO_OUTPUT;
        progressive_upscaling <= progressive_upscaling;
      end
    else if (clk_en && (state == STATE_NEXT_IMG))
      begin
        image   <= image_0;
        image_0 <= image_1;
        image_1 <= image_2;
        image_2 <= image_3;
        image_3 <= image_4;
        image_4 <= image_5;
        image_5 <= NO_OUTPUT;
        progressive_upscaling <= progressive_upscaling;
      end
    else
      begin
        image   <= image;
        image_0 <= image_0;
        image_1 <= image_1;
        image_2 <= image_2;
        image_3 <= image_3;
        image_4 <= image_4;
        image_5 <= image_5;
        progressive_upscaling <= progressive_upscaling;
      end

  always @(posedge clk)
    if (~rst) last_image <= NO_OUTPUT;
    else if (clk_en && (state == STATE_INIT) && ~persistence) last_image <= NO_OUTPUT;
    else if (clk_en && (state == STATE_NEXT_IMG)) last_image <= image;
    else last_image <= last_image;

  /* registers */
  /* save output_frame */
  always @(posedge clk)
    if (~rst) output_frame_sav <= 3'b0;
    else if (clk_en && (state == STATE_INIT) && pickup_go) output_frame_sav <= output_frame;
    else output_frame_sav <= output_frame_sav;

  /* determine frame, top, bottom sequence */
  always @(posedge clk)
    if (~rst) encoder_bug_workaround <= 1'b0;
    else if (clk_en && (state == STATE_INIT) && pickup_go) encoder_bug_workaround <= progressive_frame && repeat_first_field;
    else encoder_bug_workaround <= encoder_bug_workaround;

  always @(posedge clk)
    if (~rst) disp_frame <= 3'b0;
    else if (clk_en)
      case (state)
        STATE_INIT,
        STATE_NEXT_IMG,
        STATE_REPEAT,
        STATE_NEXT_MB,
        STATE_WAIT:       disp_frame <= output_frame_sav;
        STATE_WR_OSD_MSB,
        STATE_WR_OSD_LSB: disp_frame <= OSD_FRAME; /* osd frame */
        STATE_WR_Y_MSB,
        STATE_WR_Y_LSB,
        STATE_WR_U_UPPER,
        STATE_WR_U_LOWER,
        STATE_WR_V_UPPER,
        STATE_WR_V_LOWER: disp_frame <= output_frame_sav;
        default           disp_frame <= output_frame_sav;
      endcase
    else disp_frame <= disp_frame;

  always @(posedge clk)
    if (~rst) disp_comp <= 2'b0;
    else if (clk_en)
      case (state)
        STATE_INIT,
        STATE_NEXT_IMG,
        STATE_REPEAT,
        STATE_NEXT_MB,
        STATE_WAIT,
        STATE_WR_OSD_MSB,
        STATE_WR_OSD_LSB,
        STATE_WR_Y_MSB,
        STATE_WR_Y_LSB:   disp_comp <= COMP_Y;
        STATE_WR_U_UPPER,
        STATE_WR_U_LOWER: disp_comp <= COMP_CR;
        STATE_WR_V_UPPER,
        STATE_WR_V_LOWER: disp_comp <= COMP_CB;
        default           disp_comp <= COMP_Y;
      endcase
    else disp_comp <= disp_comp;

  always @(posedge clk)
    if (~rst) disp_delta_x <= 13'sd0;
    else if (clk_en)
      case (state)
        STATE_INIT,
        STATE_NEXT_IMG,
        STATE_REPEAT,
        STATE_NEXT_MB,
        STATE_WAIT,
        STATE_WR_OSD_MSB,
        STATE_WR_OSD_LSB,
        STATE_WR_Y_MSB,
        STATE_WR_Y_LSB:   disp_delta_x <= {1'b0, disp_x};
        STATE_WR_U_UPPER,
        STATE_WR_U_LOWER,
        STATE_WR_V_UPPER,
        STATE_WR_V_LOWER: disp_delta_x <= {2'b0, disp_x[11:1]};
        default           disp_delta_x <= 13'sd0;
      endcase
    else disp_delta_x <= disp_delta_x;

  always @(posedge clk)
    if (~rst) disp_delta_y <= 13'sd0;
    else if (clk_en)
      case (state)
        STATE_INIT,
        STATE_NEXT_IMG,
        STATE_REPEAT,
        STATE_NEXT_MB,
        STATE_WAIT,
        STATE_WR_OSD_MSB,
        STATE_WR_OSD_LSB,
        STATE_WR_Y_MSB,
        STATE_WR_Y_LSB:   disp_delta_y <= {1'b0, disp_y};
        STATE_WR_U_UPPER,
        STATE_WR_U_LOWER,
        STATE_WR_V_UPPER,
        STATE_WR_V_LOWER: if (progressive_upscaling) disp_delta_y <= {2'b0, disp_y[11:1]};
                          else disp_delta_y <= {2'b0, disp_y[11:2], disp_y[0]};
        default           disp_delta_y <= 13'sd0;
      endcase
    else disp_delta_y <= disp_delta_y;

  always @(posedge clk)
    if (~rst) disp_mv_x <= 2'b0;
    else if (clk_en)
      case (state)
        STATE_INIT,
        STATE_NEXT_IMG,
        STATE_REPEAT,
        STATE_NEXT_MB,
        STATE_WAIT,
        STATE_WR_OSD_MSB: disp_mv_x <= 13'sd0;
        STATE_WR_OSD_LSB: disp_mv_x <= 13'sd16; // 16 halfpixels
        STATE_WR_Y_MSB:   disp_mv_x <= 13'sd0;
        STATE_WR_Y_LSB:   disp_mv_x <= 13'sd16; // 16 halfpixels
        STATE_WR_U_UPPER,
        STATE_WR_U_LOWER,
        STATE_WR_V_UPPER,
        STATE_WR_V_LOWER: disp_mv_x <= 13'sd0;
        default           disp_mv_x <= 13'sd0;
      endcase
    else disp_mv_x <= disp_mv_x;

  /* border cases */
  /* DVD-FORK FIX (chroma rows, docs/decode_pacing.md §7 "F2 follow-up"): mv_y is in LUMA
   * halfpixels and memory_address halves it again for chroma (mem_addr.v: "mv_y ... will be
   * scaled by 2 if chrominance addresses are computed"), so one chroma row is mv 4, not 2.
   * Upstream used +-2 (progressive) and +-4 (interlaced), which landed the "lower" row on
   * +0/-1 (odd lines got no vertical interpolation) and on +-1 (the OPPOSITE field's chroma
   * row). The rows resample_bilinear's 0.75/0.25 weights are written for are +-1 chroma
   * row (progressive) and +-2 frame chroma rows = +-1 row of the same field (interlaced),
   * so the offsets are +-4 and +-8. The top clamps are unchanged. The bottom clamps now
   * read vertical_size (the chroma rows memory_address clips to, vertical_size / 2)
   * instead of mb_height, which differ when the height is not a multiple of 16: there the
   * same-field row two below the field's last one does not exist and memory_address would
   * clip it onto the OTHER field's last row; and a progressive line would file a key past
   * the last row (a missed reuse). Edge rows replicate: the lower row becomes the upper. */
  wire       [12:0]disp_c_rows        = {1'b0, vertical_size[13:1]};                        // chroma rows in the frame
  wire       [12:0]disp_c_up_pr       = {2'b0, disp_y[11:1]};                               // progressive upper row (as disp_delta_y)
  wire       [12:0]disp_c_up_il       = {1'b0, disp_y[11:2], disp_y[0]};                    // interlaced upper row (as disp_delta_y)
  wire signed [12:0]disp_mv_y_minus_8 =  (disp_y[11:2] == 10'b0)                   ? 13'sd0 : -13'sd8;
  wire signed [12:0]disp_mv_y_minus_4 =  (disp_y[11:1] == 11'b0)                   ? 13'sd0 : -13'sd4;
  wire signed [12:0]disp_mv_y_plus_4  =  ((disp_c_up_pr + 13'd1) >= disp_c_rows)   ? 13'sd0 : 13'sd4;
  wire signed [12:0]disp_mv_y_plus_8  =  ((disp_c_up_il + 13'd2) >= disp_c_rows)   ? 13'sd0 : 13'sd8;

  /* bilinear chroma upsampling; see text file 'bilinear.txt' */
  always @(posedge clk)
    if (~rst) disp_mv_y <= 2'b0;
    else if (clk_en)
      case (state)
        STATE_INIT,
        STATE_NEXT_IMG,
        STATE_REPEAT,
        STATE_NEXT_MB,
        STATE_WAIT:       disp_mv_y <= 13'sd0;
        STATE_WR_OSD_MSB,
        STATE_WR_OSD_LSB,
        STATE_WR_Y_MSB,
        STATE_WR_Y_LSB,
        STATE_WR_U_UPPER,
        STATE_WR_V_UPPER: disp_mv_y <= 13'sd0;
        STATE_WR_U_LOWER,
        STATE_WR_V_LOWER: if (progressive_upscaling) disp_mv_y <= disp_y[0] ? disp_mv_y_plus_4 : disp_mv_y_minus_4;
                          else disp_mv_y <= disp_y[1] ? disp_mv_y_plus_8 : disp_mv_y_minus_8;
        default           disp_mv_y <= 13'sd0;
      endcase
    else disp_mv_y <= disp_mv_y;

  always @(posedge clk)
    if (~rst) disp_valid_in <= 1'b0;
    else if (clk_en)
      case (state)
        STATE_INIT,
        STATE_NEXT_IMG,
        STATE_REPEAT,
        STATE_NEXT_MB,
        STATE_WAIT:       disp_valid_in <= 1'b0;
        STATE_WR_OSD_MSB,
        STATE_WR_OSD_LSB,
        STATE_WR_Y_MSB,
        STATE_WR_Y_LSB,
        STATE_WR_U_UPPER,
        STATE_WR_U_LOWER,
        STATE_WR_V_UPPER,
        STATE_WR_V_LOWER: disp_valid_in <= 1'b1;
        default           disp_valid_in <= 1'b0;
      endcase
    else disp_valid_in <= disp_valid_in;

  /* 
   Write to resample fifo.
   */

  /* ================= DVD-FORK FIX (F2): CHROMA ROW REUSE -- see the parameter =========
   *
   * KEY. A slot is tagged with the chroma row it holds, computed EXACTLY as
   * memory_address (mem_addr.v) computes the row it fetches: delta_y plus the chroma-scaled
   * integer part of mv_y, ((mv + sign) >>> 1) >>> 1, before the clip to the picture
   * height. The address of a word is a function of (frame, component, column, this key,
   * mb_width, horizontal_size, vertical_size), so an equal key under an equal signature
   * (cr_sig) is an equal word. Two keys that clip to the same row are merely a missed
   * reuse, never a wrong one.
   *   With the chroma-row fix (border cases above) the lower row is the neighbouring row
   *   (progressive upsampling) or the same field's neighbour, two frame rows away
   *   (interlaced upsampling). Before it, the upstream offsets were half that; F2 shipped
   *   with them, bit for bit (docs/decode_pacing.md §7 F2).
   * BANKS (chroma-row fix). The slots are banked by the parity of the row, key[0]: two
   * slots per bank, four per plane. A key of bank b always has key[0] == b, so a key
   * compare against all four slots can only hit in the row's own bank. Why banks:
   * interlaced upsampling reads only rows of the line's own field, and a FRAME scan of it
   * (weave: interlaced content on the progressive raster, the case F2 exists for)
   * alternates fields line by line, so consecutive lines share NO row -- 4m {2m, 2m-2},
   * 4m+1 {2m+1, 2m-1}, 4m+2 {2m, 2m+2}, 4m+3 {2m+1, 2m+3}. Two unbanked slots would miss on
   * every line (back to 6 words per macroblock-line); a pair per parity keeps each field's
   * last two rows. Progressive upsampling reads one even and one odd row per line, so each
   * bank serves one row per line and holds the previous row of its parity.
   * DECISION, once per line, at the line's first FIRST_RQ: each of the two rows is either
   * in a slot of its bank (reuse) or fetched into a slot of its bank. When both rows fall
   * in one bank the two-slot rule applies inside it (a miss never evicts the slot the
   * other row uses); when they fall in different banks each bank decides alone (a miss
   * replaces the slot not allocated last). U and V share it. Every distinct row is then
   * fetched once per scan in every walk measured (frame, field, weave, blend/bob, still)
   * -- plus the two fetches of the scan's first line, which skips (TIMING, below).
   * INVALIDATION: at every STATE_NEXT_IMG (a new scan may show a rewritten frame slot), and
   * whenever the signature changes. A change is sticky until the next line start and
   * forces every remaining macroblock of the line to fetch both rows; the next line then
   * starts from empty slots. A line wider than 64 macroblocks (the cache's column range;
   * DVD maxes out at 45) fetches everything, as before F2.
   * TIMING (the first build missed clk_dec at -40C by 4 MHz, every top path ending here):
   * the keys, c_same and cr_ok are REGISTERED every cycle and the decision reads the
   * registers. disp_y moves at STATE_NEXT_MB and STATE_WAIT always follows, so at a line's
   * FIRST_RQ the registers already hold that line -- except straight after STATE_NEXT_IMG,
   * which enters FIRST_RQ directly (ck_stale), and after a signature change (their inputs
   * may have moved in the last cycle). Such a line SKIPS: it fetches both rows and stores
   * nothing, so a stale key can never be filed. Cost: two row fetches per scan.
   * FLAGS to resample_dta, resample_wr_dta[9:3] = {lcp, sl[1:0], fl, su[1:0], fu}, a slot
   * id being {bank, slot}:
   *   fu/fl  fetch the upper/lower row (and store it in slot su/sl); else read slot su/sl
   *   lcp    the lower row IS the upper row (top/bottom clamp) and is being fetched this
   *          macroblock: copy the fetched word, with no RAM read-after-write. */
  wire signed [12:0] ck_up     = progressive_upscaling ? {2'b0, disp_y[11:1]} : {2'b0, disp_y[11:2], disp_y[0]};
  wire signed [12:0] ck_mv     = progressive_upscaling ? (disp_y[0] ? disp_mv_y_plus_4 : disp_mv_y_minus_4)
                                                       : (disp_y[1] ? disp_mv_y_plus_8 : disp_mv_y_minus_8);
  wire signed [12:0] ck_mv_sgn = {12'b0, ck_mv[12]};
  wire signed [12:0] ck_mv_c   = (ck_mv + ck_mv_sgn) >>> 1;      // memory_address stage 1 (chroma)
  wire signed [12:0] ck_mv_p   = ck_mv_c >>> 1;                  // memory_address stage 2 (integer part)
  wire signed [12:0] ck_lo     = ck_up + ck_mv_p;
  wire         [7:0] cr_span   = mb_last_c - mb_first_c;
  wire               cr_ok     = (cr_span[7:6] == 2'b00);          // <= 64 macroblocks (6-bit column)

  reg signed  [12:0] ck_up_q, ck_lo_q;        // the registered key (see TIMING)
  reg                ck_same_q, cr_ok_q, ck_stale;
  always @(posedge clk)
    if (~rst) begin
      ck_up_q <= 13'sd0; ck_lo_q <= 13'sd0; ck_same_q <= 1'b0; cr_ok_q <= 1'b0; ck_stale <= 1'b1;
    end else if (clk_en) begin
      ck_up_q   <= ck_up;
      ck_lo_q   <= ck_lo;
      ck_same_q <= (ck_up == ck_lo);
      cr_ok_q   <= cr_ok;
      ck_stale  <= (state == STATE_NEXT_IMG);  // disp_y moved at this edge; FIRST_RQ may be next
    end

  /* everything the address of a word depends on besides the key, plus mb_height (the key's
   * bottom clamp read it until the chroma-row fix moved it to vertical_size; kept) */
  wire        [47:0] cr_sig    = {output_frame_sav, hcrop_en, mb_width, mb_height, horizontal_size, vertical_size};
  reg         [47:0] cr_sig_q;
  reg                cr_chg;                  // the signature changed since this line's start (sticky)
  wire               cr_chg_now = cr_chg | (cr_sig != cr_sig_q);
  wire               cr_skip   = ~cr_ok_q | ck_stale | cr_chg_now;   // fetch both, file nothing

  reg                cr_line_first;           // the next FIRST_RQ opens a line
  reg          [3:0] ct_v;                    // slot valid, indexed {bank, slot}
  reg signed  [12:0] ct_k0, ct_k1, ct_k2, ct_k3;   // slot keys, indexed {bank, slot}
  reg          [1:0] ct_la;                   // per bank: the slot allocated last (a lone miss replaces the other)
  reg          [6:0] cr_ln;                   // this line's flags {lcp, sl[1:0], fl, su[1:0], fu}

  /* a line that is not skipped has no pending change. A key only ever sits in its own bank
   * (key[0] == bank), so hu0 / hu1 are "hit in slot 0 / 1 of the row's bank". */
  wire               bu    = ck_up_q[0];      // the upper row's bank
  wire               bl    = ck_lo_q[0];      // the lower row's bank
  wire               sb    = (bu == bl);      // both rows in one bank
  wire               hu0   = (ct_v[0] & (ct_k0 == ck_up_q)) | (ct_v[2] & (ct_k2 == ck_up_q));
  wire               hu1   = (ct_v[1] & (ct_k1 == ck_up_q)) | (ct_v[3] & (ct_k3 == ck_up_q));
  wire               hl0   = (ct_v[0] & (ct_k0 == ck_lo_q)) | (ct_v[2] & (ct_k2 == ck_lo_q));
  wire               hl1   = (ct_v[1] & (ct_k1 == ck_lo_q)) | (ct_v[3] & (ct_k3 == ck_lo_q));
  wire               lau   = bu ? ct_la[1] : ct_la[0];
  wire               lal   = bl ? ct_la[1] : ct_la[0];
  wire               c_same = ck_same_q;
  wire               c_hu  = hu0 | hu1;
  wire               c_hl  = hl0 | hl1;
  wire               c_su  = c_hu ? hu1 : (sb & c_hl & ~c_same) ? ~hl1 : ~lau;
  wire               c_sl  = c_hl ? hl1 : c_same ? c_su : sb ? ~c_su : ~lal;
  wire               c_fu  = ~c_hu;
  wire               c_fl  = ~c_hl & ~c_same;
  wire               c_lcp = c_same & ~c_hu;
  wire         [3:0] c_wu  = c_fu ? (4'b0001 << {bu, c_su}) : 4'b0000;   // slot the upper row is filed in
  wire         [3:0] c_wl  = c_fl ? (4'b0001 << {bl, c_sl}) : 4'b0000;   // slot the lower row is filed in
  wire         [6:0] cr_dec   = cr_skip ? 7'b0011001                                   // skip: fetch both (slots 0/1 of bank 0)
                                        : {c_lcp, bl, c_sl, c_fl, bu, c_su, c_fu};
  wire         [6:0] cr_force = {1'b0, cr_ln[5:4], 1'b1, cr_ln[2:1], 1'b1};           // fetch both, same slots
  wire         [6:0] cr_flags = (CHROMA_REUSE == 0) ? 7'b0
                              : cr_line_first ? cr_dec
                              : cr_chg_now    ? cr_force : cr_ln;

  always @(posedge clk)
    if (~rst) cr_line_first <= 1'b1;
    else if (clk_en && (state == STATE_NEXT_IMG)) cr_line_first <= 1'b1;
    else if (clk_en && (state == STATE_NEXT_MB) && last_mb) cr_line_first <= 1'b1;
    else if (clk_en && (state == FIRST_RQ)) cr_line_first <= 1'b0;

  wire               cr_decide = clk_en && (state == FIRST_RQ) && cr_line_first;
  always @(posedge clk)
    if (~rst) begin
      cr_sig_q <= 48'd0; cr_chg <= 1'b1; cr_ln <= 7'd0;
      ct_v <= 4'b0000; ct_k0 <= 13'sd0; ct_k1 <= 13'sd0; ct_k2 <= 13'sd0; ct_k3 <= 13'sd0; ct_la <= 2'b11;
    end else if (clk_en && (state == STATE_NEXT_IMG)) begin
      ct_v <= 4'b0000;                                 // a new scan starts from empty slots
    end else if (cr_decide) begin
      cr_sig_q <= cr_sig;
      cr_chg   <= 1'b0;
      cr_ln    <= cr_dec;
      if (cr_skip) ct_v <= 4'b0000;
      else begin
        ct_v <= ct_v | c_wu | c_wl;
        /* c_wu and c_wl never name one slot: that needs equal keys, where c_fl = 0 */
        if (c_wu[0]) ct_k0 <= ck_up_q;
        if (c_wu[1]) ct_k1 <= ck_up_q;
        if (c_wu[2]) ct_k2 <= ck_up_q;
        if (c_wu[3]) ct_k3 <= ck_up_q;
        if (c_wl[0]) ct_k0 <= ck_lo_q;
        if (c_wl[1]) ct_k1 <= ck_lo_q;
        if (c_wl[2]) ct_k2 <= ck_lo_q;
        if (c_wl[3]) ct_k3 <= ck_lo_q;
        if (c_fl & ~bl) ct_la[0] <= c_sl;
        else if (c_fu & ~bu) ct_la[0] <= c_su;
        if (c_fl & bl) ct_la[1] <= c_sl;
        else if (c_fu & bu) ct_la[1] <= c_su;
      end
    end else if (clk_en && (cr_sig != cr_sig_q)) cr_chg <= 1'b1;

  always @(posedge clk)
    if (~rst) resample_wr_dta <= 10'b0;
    /* DVD-FORK FIX: use the 2-bit saturating disp_y_sat (cannot wrap at 256) instead of
     * the wide disp_y==0/==1 compares, so no SPURIOUS frame-top (ROW_0_COL_0) can be
     * emitted at line 256. This is the 256-line strobe fix (see disp_y_sat above). */
    else if (clk_en && (state == FIRST_RQ) && (disp_mb == mb_first_c) && (disp_y_sat == 2'd0)) resample_wr_dta <= {cr_flags, ROW_0_COL_0};
    else if (clk_en && (state == FIRST_RQ) && (disp_mb == mb_first_c) && (disp_y_sat == 2'd1)) resample_wr_dta <= {cr_flags, ROW_1_COL_0};
    else if (clk_en && (state == FIRST_RQ) && (disp_mb == mb_first_c)) resample_wr_dta <= {cr_flags, ROW_X_COL_0};
    else if (clk_en && (state == FIRST_RQ) && (disp_mb == mb_last_c)) resample_wr_dta <= {cr_flags, ROW_X_COL_LAST};
    else if (clk_en && (state == FIRST_RQ)) resample_wr_dta <= {cr_flags, ROW_X_COL_X};   // DVD-FORK FIX (F1): FIRST_RQ, not the OSD state
    else resample_wr_dta <= resample_wr_dta;

  always @(posedge clk)
    if (~rst) resample_wr_en <= 1'b0;
    else if (clk_en) resample_wr_en <= (state == FIRST_RQ);   // DVD-FORK FIX (F1): one position code per macroblock, whichever state opens it
    else resample_wr_en <= resample_wr_en;

  /* display address generator */
  memory_address
    #(.dta_width(1))
    disp_mem_addr (
    .clk(clk), 
    .clk_en(clk_en), 
    .rst(rst), 
    /* in */
    .frame(disp_frame), 
    .frame_picture(1'b1), 
    .field_in_frame(1'b0), 
    .field(1'b0), 
    .component(disp_comp), 
    .mb_width(mb_width), 
    .horizontal_size(horizontal_size),
    .vertical_size(vertical_size),
    .macroblock_address(13'd0), 
    .delta_x(disp_delta_x), 
    .delta_y(disp_delta_y), 
    .mv_x(disp_mv_x), 
    .mv_y(disp_mv_y), 
    .dta_in(1'b0), 
    .valid_in(disp_valid_in), 
    /* out */
    .address(disp_wr_addr), 
    .offset_x(), 
    .halfpixel_x(), 
    .halfpixel_y(), 
    .dta_out(), 
    .valid_out(disp_wr_addr_en)
    );

`ifdef DEBUG
  always @(posedge clk)
    if (clk_en)
      case (state)
        STATE_INIT:                               #0 $display("%m         STATE_INIT");
        STATE_NEXT_IMG:                           #0 $display("%m         STATE_NEXT_IMG");
        STATE_REPEAT:                             #0 $display("%m         STATE_REPEAT");
        STATE_NEXT_MB:                            #0 $display("%m         STATE_NEXT_MB");
        STATE_WAIT:                               #0 $display("%m         STATE_WAIT");
        STATE_WR_OSD_MSB:                         #0 $display("%m         STATE_WR_OSD_MSB");
        STATE_WR_OSD_LSB:                         #0 $display("%m         STATE_WR_OSD_LSB");
        STATE_WR_Y_MSB:                           #0 $display("%m         STATE_WR_Y_MSB");
        STATE_WR_Y_LSB:                           #0 $display("%m         STATE_WR_Y_LSB");
        STATE_WR_U_UPPER:                         #0 $display("%m         STATE_WR_U_UPPER");
        STATE_WR_U_LOWER:                         #0 $display("%m         STATE_WR_U_LOWER");
        STATE_WR_V_UPPER:                         #0 $display("%m         STATE_WR_V_UPPER");
        STATE_WR_V_LOWER:                         #0 $display("%m         STATE_WR_V_LOWER");
        default                                   #0 $display("%m         *** Error: unknown state %d", state);
      endcase

  always @(posedge clk)
    if (clk_en && (state == STATE_INIT))
      $strobe("%m\toutput_frame: %d output_frame_valid: %d progressive_sequence: %d progressive_frame: %d top_field_first: %d repeat_first_field: %d mb_width: %d mb_height: %d", output_frame, output_frame_valid, progressive_sequence, progressive_frame, top_field_first, repeat_first_field, mb_width, mb_height);

  always @(posedge clk)
    if (clk_en && (state == STATE_NEXT_IMG))
      $strobe("%m\timage: %d image_0: %d image_1: %d image_2: %d image_3: %d image_4: %d image_5: %d", image, image_0, image_1, image_2, image_3, image_4, image_5);

  always @(posedge clk)
    if (clk_en) 
      $strobe("%m\tstate: %d image: %d disp_frame: %d disp_comp: %d disp_mb: %d disp_x: %d disp_y: %d disp_delta_x: %d disp_delta_y: %d disp_mv_x: %d disp_mv_y: %d disp_valid_in: %d resample_wr_dta: %d resample_wr_en: %d",
                   state, image, disp_frame, disp_comp, disp_mb, disp_x, disp_y, disp_delta_x, disp_delta_y, disp_mv_x, disp_mv_y, disp_valid_in, resample_wr_dta, resample_wr_en);
`endif
endmodule
/* not truncated */
