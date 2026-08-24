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
  interlaced, deinterlace, persistence, repeat_frame,
  disp_wr_addr_full, disp_wr_addr_en, disp_wr_addr_ack, disp_wr_addr,
  resample_wr_dta, resample_wr_en,
  disp_wr_addr_almost_full, resample_wr_almost_full,
  busy,
  frame_late,                                       // DVD-FORK (frame-drop governor O[19])
  video_live,                                       // DVD-FORK (av_sync STC reference)
  pickup_hold,                                      // DVD-FORK (STD mux-lead hold)
  pause,                                            // DVD-FORK (gamepad transport): freeze frame while paused
  cur_show_out,                                     // DVD-FORK (film-aware drop reclaim)
  pickup_tick, pickup_show, refresh_tick_dbg,       // DVD-FORK (vid_err instrument)
  film_det_ntsc, film_det_pal,                      // DVD-FORK (Film 24p auto-detect): cadence verdicts
  det_video,                                        // DVD-FORK (Interlaced Out auto): sustained true-interlaced-video verdict
  vscale_mode,                                      // DVD-FORK (CRT anamorphic vertical scaler)
  hcrop_en,                                         // DVD-FORK (CRT anamorphic horizontal crop / pan-scan)
  menu_ff,                                          // DVD-FORK (menu VBUF-lag §5): fast-drain a deeply-buffered menu
  film24                                            // DVD-FORK (Film 24p Out): 1 frame/refresh, ascal does the 3:2
  );

  input              clk;                      // clock
  input              clk_en;                   // clock enable
  input              rst;                      // synchronous active low reset

  input        [2:0]output_frame;              /* frame to be displayed */
  input             output_frame_valid;        /* asserted when output_frame valid */
  output reg        output_frame_rd;

  input             progressive_sequence;
  input             progressive_frame;
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

  output reg    [2:0]resample_wr_dta;
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
   * target wrong by that much. Cleared only by rst (not by a clip reload — known
   * limitation, see docs/av_sync.md). */
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

  /* DVD-FORK (film-aware drop reclaim): the display duration (refreshes) of the frame
   * currently on display — 3 for a repeat_first_field pulldown frame, else SHOW_N.
   * frame_drop_ctl debits THIS per dropped frame instead of a flat SHOW_N: a flat 2
   * against film's 2.5-refresh average made every drop advance the display ~0.5
   * refresh (~8 ms) ahead of the wall-clock STC the audio genlocks to — the growing
   * audio-late creep on droppy NTSC film (MiB). Sampling the on-display frame's
   * cur_show instead of the dropped B's own rff is statistically identical on
   * uniform-cadence film and exact on PAL (always 2). */
  output      [3:0]  cur_show_out;
  /* DVD-FORK (vid_err instrument, 2026-07-03): the last unmeasured lip-sync
   * leg is the VIDEO CONTENT timeline vs wall clock (audio is instrumented
   * five ways and provably schedule-locked; the -900 ms crash step survives).
   * pickup_tick pulses once per frame entering display with pickup_show = its
   * display duration (show_next); refresh_tick_dbg pulses once per completed
   * display scan while video_live. mpeg2video sums content (pickups + dropped
   * frames' durations) against wall refreshes -> dbg_vid_err. */
  output             pickup_tick;
  output      [3:0]  pickup_show;
  output             refresh_tick_dbg;

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

  /* DVD-FORK (Interlaced Out — auto detect): sustained TRUE-INTERLACED-VIDEO verdict,
   * evaluated on the same per-display-pickup committed flags as the film detectors.
   * det_video = a sustained run of interlaced-coded frames (progressive_frame==0). This
   * is the signal to switch the framework scaler to a NATIVE fields path (480i/576i +
   * VGA_F1, ascal deinterlaces) so 60-field (NTSC 29.97i) / 50-field (PAL 25i) motion is
   * preserved instead of being weaved to 30/25 unique progressive frames. Standard-
   * neutral: keys only on progressive_frame, so it covers both NTSC and PAL. Mutually
   * exclusive with film_det_ntsc/pal by construction (film needs progressive_frame==1).
   * Same strong hysteresis as the film verdicts, biased toward NON-interlaced (a false
   * positive Bob-deinterlaces progressive content = a soft resolution loss; a false
   * negative just stays the current progressive weave = harmless). Known edge case:
   * HARD-telecine film (progressive_frame==0, no rff) reads as video and gets Bob'd at
   * field rate — acceptable, no inverse-telecine attempted. See docs/interlaced_auto.md. */
  output             det_video;

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
  /* DVD-FORK (menu VBUF-lag §5): when high, FAST-DRAIN the display — pick up a new
   * decoded frame every refresh (frame_due at refresh_cnt>=1) instead of the normal
   * cur_show cadence, so a deeply-buffered menu transition PLAYS OUT at up to display
   * rate (~2-2.5x) and the settled still (baked menu numbers / first slide) is reached
   * promptly WITHOUT cutting the transition. emu asserts it only while a menu is up AND
   * the compressed VBUF is deeply backed up (hysteresis), and drops it as the backlog
   * drains, so it self-limits: over-triggering just plays a transition slightly faster.
   * Menus aren't lip-synced (no audio to desync), so overriding the pacing is safe; the
   * gate is menu-only so title A/V sync is untouched. */
  input              menu_ff;
  /* DVD-FORK (Film 24p Out, issue #124): the core raster is already the 23.976 Hz film
   * rate (emu's modeline 24p branch), so there is NO in-core 3:2 pulldown — advance ONE
   * decoded frame per refresh and let the framework scaler (ascal) do the 3:2 to 59.94 Hz
   * HDMI. Forces cur_show=1 (via show_next below), which collapses the rff-based display
   * target and the drop-debit to 1 refresh/frame — the deadline becomes "produce a frame
   * every ~41.7 ms" (huge slack vs 60 Hz), so the decoder stops missing it. HDMI-NTSC-film
   * only (emu gates it ~pal & ~crt & progressive). See docs/film_24p_plan.md §3b. */
  input              film24;

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
  wire              last_y = vscale_en ? (oline >= (v_outlines - 12'd1)) : last_y_native;

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

  /* ---------------------------------------------------------------------------
   * DVD-FORK FIX: frame-rate governor (A/V sync / playback speed) — DISPLAY-LOCKED.
   *
   * The upstream decoder has no rate control — it releases each decoded frame as
   * soon as it is scanned out, calibrated for the old ~27 MHz clock. At 54 MHz,
   * easily-decoded content out-runs real time, so video plays FAST and (now that we
   * have correct-rate HPS audio) audio progressively lags.
   *
   * A first attempt used a free-running 54 MHz cycle counter (PACE_N). But a frame
   * can only be RELEASED at the end of a display scan, so the period quantized to
   * scan boundaries -> ~75% speed + jitter, and interlaced (2 field-scans/frame)
   * ran ~half speed. The correct method is to lock to the DISPLAY REFRESH: count
   * completed image scans (each = one refresh: a progressive frame OR an interlaced
   * field) and release a new source frame every SHOW_N refreshes.
   *
   * On a 59.94 Hz display SHOW_N=2 gives exactly 29.97 fps for BOTH:
   *   progressive: frame scan + 1 persistence re-scan          = 2 refreshes
   *   interlaced : top field scan + bottom field scan          = 2 refreshes
   * so progressive and interlaced run at the same correct rate, no beat/jitter.
   *
   * No-regression: still only ever SLOWS over-fast content — if the next frame is
   * not decoded when due (output_frame_valid=0) the persistence path keeps holding.
   *
   * PAL: SHOW_N=2 ALSO works unchanged — on a 50 Hz display it releases at 50/2 =
   * 25 fps, exactly the PAL DVD source rate (progressive frame + 1 re-scan, or 2
   * fields). The 50 Hz display itself is selected via the PAL modeline (O[16],
   * emu.sv) + av_sync's 50 Hz STC tick; the governor needs no PAL-specific constant.
   * (A future film/3:2 or PAL-speedup-25-from-24 path would still want SHOW_N work.)
   * See docs/frame_rate_governor.md.
   * --------------------------------------------------------------------------- */
  localparam [3:0]  SHOW_N = 4'd2;            // baseline refreshes/source frame: 29.97@59.94 (NTSC), 25@50 (PAL)
  reg        [3:0]  refresh_cnt;

  /*
   * DVD-FORK FIX (film 3:2 pulldown cadence): the per-frame display target. Baseline is
   * SHOW_N (2), but a soft-telecined frame with repeat_first_field must occupy 3 refreshes
   * so 24 fps film displays with the correct 3:2 cadence (3,2,3,2 = 2.5 avg = 60/24) instead
   * of a flat 2 refreshes (= 30 fps, ~25 % too fast).
   *
   * IMPORTANT: our default 480p output runs the decoder with deinterlace=1, interlaced=0
   * (regfile default; see emu.sv), and DVDs are coded interlaced (progressive_sequence=0)
   * with film carried on progressive_frame + repeat_first_field. That path takes the
   * `deinterlace && ~interlaced` image-build branch, which emits a single FRAME image and
   * ignores rff entirely — so EVERY frame showed 2 refreshes (30 fps) and film ran fast.
   * (Upstream only honoured rff on the progressive_sequence / interlaced-output branches,
   * and there gated the 3rd refresh on rff && top_field_first — tff is a field-order flag,
   * irrelevant for progressive frame display.) So the gate is simply `~interlaced && rff`:
   * on ANY progressive-display path, an rff frame is held one extra refresh via the
   * persistence re-scan (paces to `cur_show`), independent of the image-build. Interlaced
   * OUTPUT (interlaced=1, the 480i mode) is untouched (stays SHOW_N) — no 480i regression.
   * `cur_show` is latched per frame at pickup.
   */
  /* DVD-FORK FIX (480i field-path timeline accounting, 2026-07-05): the interlaced arm
   * of show_next must be the TRUE image count the pickup loads, not a flat SHOW_N —
   * the image builds below emit one refresh per FIELD image:
   *   progressive_sequence on interlaced display: 2 fields, 4 with rff, 6 with rff+tff
   *   progressive_frame (soft-telecine film):     2 fields, 3 with rff (the 3:2 cadence)
   *   interlaced frame:                           2 fields
   * With the old flat 2, an rff film frame occupied 3 field scans while cur_show said 2:
   * frame_due/late decisions and (via cur_show_out/pickup_show) the drop debit and the
   * vid_err content credit were all one refresh short PER RFF FRAME in 480i — a large
   * slice of the HW-measured "480i drops reclaim ~1.1 refreshes instead of 2" A/V drift
   * (the other slice is the pair-repeat late undercount, fixed below). The progressive
   * arm is untouched (the HW-proven film-3:2 behavior, incl. its deliberate 3 for the
   * rare progressive_sequence rff+~tff 2-image case). */
  wire       [3:0]  show_next_prog  = repeat_first_field ? 4'd3 : SHOW_N;
  wire       [3:0]  show_next_ilace = progressive_sequence
                                        ? (repeat_first_field ? (top_field_first ? 4'd6 : 4'd4) : 4'd2)
                                        : ((progressive_frame && repeat_first_field) ? 4'd3 : 4'd2);
  /* DVD-FORK (Film 24p Out): raster == film rate => exactly 1 refresh per frame, no in-core
   * 3:2 (ascal owns the pulldown). Overrides the rff cadence AND the interlaced arm.
   *
   * DVD-FORK FIX (2026-08-02, CADENCE-SLIP corrector — the Film-24p A/V drift root
   * cause): a flat 1 refresh/picture is only timeline-exact if the disc's telecine
   * cadence is PERFECT (rff alternating 1,0,1,0 => avg picture duration 2.5 fields =
   * 1/23.976 s). Real discs break cadence at shot edits: MEN_IN_BLACK measures rff
   * density 0.499158 over 63,531 pictures (~107 anomalies, one per ~25 s), and each
   * "missing" rff=1 is a 2-field (33.4 ms) picture displayed for a full 41.7 ms
   * refresh = +8.34 ms of video retard. Content-level measurement of a 48-min HW
   * capture: predicted +0.893 s, measured +0.884 s (audio xcorr + motion-envelope
   * matching vs the source VOB) — audio plays exactly real time, video content
   * retards, audio ends ~1 s AHEAD. At 60 Hz this cannot happen: cur_show honours
   * each picture's OWN rff (2 or 3 refreshes), exact for ANY cadence. Invisible to
   * vid_err (pickups stay on schedule — the error is in the flat ASSUMED duration),
   * to the raster (measured exact), and to the audio counters (all zero).
   *
   * FIX: accumulate the per-picture duration error in 0.5-field units
   * (rff=1 -> +1, rff=0 -> -1; a perfect cadence oscillates 0,±1) and correct with
   * WHOLE refreshes when it reaches ±2.5 fields (±5 units):
   *   deficit (acc <= -5, the common direction): pulse ONE frame_late into the
   *     frame-drop ledger -> frame_drop_ctl banks 1 refresh of debt -> the VLD drops
   *     one B (drop_cost = 1 in film24) -> content advances 1 picture in 0 refreshes.
   *     Reuses the whole HW-proven drop path; a ~42 ms skip once per ~2 min on MiB.
   *   surplus (acc >= +5): show THIS picture 2 refreshes (cur_show = 2) once.
   * GATE = film24 && det_ntsc: the detector's own NTSC-telecine verdict. PAL 25p film
   * (rff = 0 every picture, exact 2 fields = one 25p refresh) never raises det_ntsc,
   * so the corrector is inert there (a step model of 2.5 fields/refresh would be
   * wrong); same for true 30p video mistakenly left in 24p. Bounded by construction:
   * |acc| < 5 => the residual A/V error can never exceed ~1 refresh (42 ms).
   * NOTE: the deficit correction rides the B-drop path, so it needs O[12] Frame Drop
   * ON (the default) — with dropping off, imperfect-cadence discs still drift.
   * Measurement + design: docs/film_24p_plan.md §12. */
  reg               det_ntsc, det_pal;      // film detector verdicts (logic below; hoisted for the corrector)
  reg signed [3:0]  cad_acc;                  // cadence phase error, 0.5-field units
  wire              cad_gate   = film24 && det_ntsc;
  wire signed [4:0] cad_next   = cad_acc + (repeat_first_field ? 5'sd1 : -5'sd1);
  wire              cad_hold_w = cad_gate && (cad_next >= 5'sd5);   // surplus: 2-refresh show
  wire       [3:0]  show_next = film24 ? (cad_hold_w ? 4'd2 : 4'd1)
                              : interlaced ? show_next_ilace : show_next_prog;
  reg        [3:0]  cur_show;                 // display target (refreshes) of the frame on display
  /* DVD-FORK (menu VBUF-lag §5): fast-drain override. Only once video is live (never
   * during the cold-start hold). Lowers the per-frame display target to 1 refresh so the
   * governor advances through the buffered menu transition at up to display rate. */
  wire              menu_ff_go = menu_ff && video_live;
  wire              frame_due = menu_ff_go ? (refresh_cnt >= 4'd1)
                                           : (refresh_cnt >= cur_show);
  assign cur_show_out = cur_show;               // DVD-FORK (film-aware drop reclaim)
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
  wire              ofv_paced = output_frame_valid & frame_due & ~pause & ~hold_freeze;

  /* DVD-FORK (STD mux-lead hold): qualified pickup. The FIRST pickup (video_live
   * still 0) is deferred while pickup_hold is asserted; once video_live is set the
   * hold can never stall the display. Every pickup-conditioned block below uses
   * this wire so the hold is atomic (no half-taken pickups). */
  wire ofv_pickup = output_frame_valid && ~hold_freeze && ~pause;

  /* next state logic */
  always @*
    case (state)
      STATE_INIT:         if (ofv_pickup) next = STATE_NEXT_IMG; // scan whenever a frame exists (bootstrap); pacing is the STATE_REPEAT hold below
                          else next = STATE_INIT;

      STATE_NEXT_IMG:     if ((image_0 == NO_OUTPUT) && (image_1 == NO_OUTPUT) && (image_2 == NO_OUTPUT) &&
                              (image_3 == NO_OUTPUT) && (image_4 == NO_OUTPUT) && (image_5 == NO_OUTPUT)) next = STATE_REPEAT; 
                          else next = STATE_WR_OSD_MSB; 

      STATE_REPEAT:       if (repeat_cnt != 5'd0) next = STATE_NEXT_IMG; // repeat frame 
                          else if (~ofv_paced && persistence && (last_image != NO_OUTPUT)) next = STATE_NEXT_IMG; // DVD-FORK: repeat last image while next frame not due (or none yet)
                          else next = STATE_INIT;

      STATE_NEXT_MB:      if (last_mb && last_y) next = STATE_NEXT_IMG;
                          else next = STATE_WAIT;

      STATE_WAIT:         if (disp_wr_addr_almost_full || resample_wr_almost_full) next = STATE_WAIT;
                          else next = STATE_WR_OSD_MSB;

      STATE_WR_OSD_MSB:   next = STATE_WR_OSD_LSB; // output osd read requests - 16 pixels

      STATE_WR_OSD_LSB:   next = STATE_WR_Y_MSB;

      STATE_WR_Y_MSB:     next = STATE_WR_Y_LSB; // output luminance read requests - 16 pixels

      STATE_WR_Y_LSB:     next = STATE_WR_U_UPPER; 

      STATE_WR_U_UPPER:   next = STATE_WR_U_LOWER; // output chroma read requests - 2 rows of 8 

      STATE_WR_U_LOWER:   next = STATE_WR_V_UPPER;

      STATE_WR_V_UPPER:   next = STATE_WR_V_LOWER; // output chroma read requests - 2 rows of 8

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
    else if (clk_en) output_frame_rd <= (state == STATE_INIT) && ofv_pickup; // INIT is reached at hold release (the held frame re-scans in STATE_REPEAT), or during a cold start with nothing to hold
    else output_frame_rd <= output_frame_rd;

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
                           frame_due && ~output_frame_valid && ~pause &&  // DVD-FORK: no debt while paused
                           ~hold_freeze &&  // DVD-FORK (hold-frame transitions): hold-window lateness is mux-lead policy, not decode debt — without this, lates bank drop debt once the refilling VBUF passes vbuf_healthy but before the new clip's first frame decodes, dropping B-frames right at clip start
                           ~menu_ff_go;  // DVD-FORK (menu §5): fast-drain waits aren't real A/V deadline misses

  /* latch the display target (refreshes) of the frame at pickup: 3 for rff pulldown
   * frames (progressive display), else SHOW_N. Paces the 3:2 cadence via persistence. */
  always @(posedge clk)
    if (~rst) cur_show <= SHOW_N;
    else if (clk_en && (state == STATE_INIT) && ofv_pickup) cur_show <= show_next;
    else cur_show <= cur_show;

  /* DVD-FORK FIX (cadence-slip corrector, see the show_next comment): step the
   * accumulator once per pickup with the PICKED picture's rff (the same instant
   * show_next/cur_show sample it — flags_commit-correct). On a deficit crossing
   * (acc would reach -2.5 fields) pulse cad_late_r for one clk_en cycle and refund
   * one refresh (+5); on a surplus crossing the refund is the 2-refresh show that
   * cad_hold_w already granted combinationally to THIS pickup (-5). Gate off (and
   * hold at 0) when not in NTSC film24 — a seek's cadence-phase jump is bounded by
   * |acc|<5 (< 1 refresh) and self-corrects, so no flush plumbing is needed. */
  reg cad_late_r;
  always @(posedge clk)
    if (~rst) begin
      cad_acc    <= 4'sd0;
      cad_late_r <= 1'b0;
    end else if (clk_en) begin
      cad_late_r <= 1'b0;
      if ((state == STATE_INIT) && ofv_pickup) begin
        if (!cad_gate)                  cad_acc <= 4'sd0;
        else if (cad_next <= -5'sd5) begin
                                        cad_acc <= cad_next[3:0] + 4'sd5;
                                        cad_late_r <= 1'b1;   // -> frame-drop ledger: drop one B
        end
        else if (cad_next >=  5'sd5)    cad_acc <= cad_next[3:0] - 4'sd5;  // 2-refresh show granted
        else                            cad_acc <= cad_next[3:0];
      end
    end

  /* DVD-FORK (vid_err instrument): registered one-clk pulses (clk_en is 1 in
   * this instantiation; registering keeps them clean single-cycle strobes). */
  reg       pickup_tick_r, refresh_tick_r;
  reg [3:0] pickup_show_r;
  always @(posedge clk)
    if (~rst) begin
      pickup_tick_r  <= 1'b0;
      pickup_show_r  <= 4'd0;
      refresh_tick_r <= 1'b0;
    end else if (clk_en) begin
      pickup_tick_r  <= (state == STATE_INIT) && ofv_pickup;
      if ((state == STATE_INIT) && ofv_pickup) pickup_show_r <= show_next;
      refresh_tick_r <= (state == STATE_NEXT_MB) && last_mb && last_y && video_live;
    end else begin
      pickup_tick_r  <= 1'b0;
      refresh_tick_r <= 1'b0;
    end
  assign pickup_tick      = pickup_tick_r;
  assign pickup_show      = pickup_show_r;
  assign refresh_tick_dbg = refresh_tick_r;

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
  // (det_ntsc/det_pal are DECLARED EARLIER, above the cadence-slip corrector that
  //  consumes det_ntsc — iverilog rejects declaration-after-use.)
  reg  [7:0] conf_video;                   // DVD-FORK (Interlaced Out auto): true-interlaced confidence
  reg        det_v;
  wire       film_pickup = (state == STATE_INIT) && ofv_pickup;
  wire       rff_toggled = (repeat_first_field != rff_q);
  wire       good_ntsc   = progressive_frame && rff_toggled;   // clean 3:2 telecine frame
  always @(posedge clk)
    if (~rst) begin
      rff_q     <= 1'b0;
      conf_ntsc <= 8'd0; conf_pal <= 8'd0;
      det_ntsc  <= 1'b0; det_pal  <= 1'b0;
      conf_video <= 8'd0; det_v   <= 1'b0;
    end else if (clk_en && film_pickup) begin
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
      // ---- TRUE-INTERLACED-VIDEO confidence (progressive_frame==0; standard-neutral) ----
      // Mirror of PAL 25p: rises on interlaced-coded frames, falls hard on any progressive
      // frame. Soft-telecine (NTSC) and 25p (PAL) film are progressive_frame==1 => this
      // only ever decays on them, so it can never engage on film. NTSC 29.97i and PAL 25i
      // video are progressive_frame==0 => it locks. Same up/down as the film hard step.
      begin : video_conf
        reg [7:0] cv;
        if (!progressive_frame)
          cv = (conf_video > (CONF_MAX - UP_STEP)) ? CONF_MAX : conf_video + UP_STEP;
        else
          cv = (conf_video < DN_HARD) ? 8'd0 : conf_video - DN_HARD;
        conf_video <= cv;
        if      (cv >= ENGAGE_TH)    det_v <= 1'b1;
        else if (cv <= DISENGAGE_TH) det_v <= 1'b0;
      end
    end
  assign film_det_ntsc = det_ntsc;
  assign film_det_pal  = det_pal;
  assign det_video     = det_v;

  /*
   * Emit frame_late in units of REFRESHES of hold, for frame_drop_ctl's debt ledger
   * (debt += 1 per clk frame_late is high).
   *
   * DVD-FORK FIX (480i field-path late undercount, 2026-07-05): on a progressive
   * display a late repeat re-scans one FRAME image = ONE refresh of timeline slip, and
   * late_raw fires once per repeat — 1:1. But on an interlaced display the repeat
   * branch below re-scans a FIELD PAIR (last_image TOP -> {BOTTOM, TOP}) = TWO
   * refreshes of slip per single STATE_REPEAT visit, so a 1-cycle pulse banks only
   * HALF the accrued lateness. That was the dominant term in the HW-measured 480i
   * A/V drift (audio rode ahead ~1.3 s over 43 s with the SAME lates/drops rates as
   * the drift-free progressive run — each drop's reclaim was honest, the LATES were
   * undercounted 2x). Fix: stretch frame_late to two cycles when the late repeat is
   * a field pair, so debt (and frames_late_cnt, and the overlay lates/s row) count
   * refreshes in both modes. late_raw cannot re-fire on the extension cycle (the FSM
   * has left STATE_REPEAT and won't return until the pair finishes scanning).
   */
  wire late_pair = (last_image == TOP) || (last_image == BOTTOM);
  reg  late_ext;
  always @(posedge clk)
    if (~rst) late_ext <= 1'b0;
    else if (clk_en) late_ext <= late_raw && late_pair;
    else late_ext <= late_ext;

  always @(posedge clk)
    if (~rst) frame_late <= 1'b0;
    else if (clk_en) frame_late <= late_raw | late_ext | cad_late_r;  // DVD-FORK: cadence-slip deficit correction (film24; can't collide with late_raw — pickup vs REPEAT cycles)
    else frame_late <= frame_late;

  /* DVD-FORK (av_sync STC reference): sticky "display has shown a decoded frame".
   * Same pickup condition as cur_show above — the first real frame entering the
   * image build is, one scan later, on the screen. */
  reg pickup_hold_d;
  always @(posedge clk) pickup_hold_d <= pickup_hold;

  always @(posedge clk)
    if (~rst) video_live <= 1'b0;
    else if (pickup_hold && ~pickup_hold_d) video_live <= 1'b0;  // clip load: re-arm
    else if (clk_en && (state == STATE_INIT) && ofv_pickup) video_live <= 1'b1;
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

  /*
   * DVD-FORK FIX: display-refresh counter. Increments once per completed image scan
   * (one display refresh: a progressive frame or an interlaced field), detected at
   * the last macroblock of the image. Reset on each source-frame release. frame_due
   * asserts after SHOW_N refreshes, pacing releases to (display rate / SHOW_N).
   */
  /* DVD-FORK FIX (2026-07-05, found by gov_field_late_tb): SATURATE refresh_cnt
   * instead of letting the 4-bit counter wrap. During a sustained decode stall the
   * count passes 15 -> wrapped to 0 -> frame_due went FALSE for the next cur_show
   * refreshes, so those repeat scans were misclassified as within-cadence holds and
   * banked NO lateness (a ~12% debt undercount every 16 refreshes of stall, both
   * display modes). Saturating keeps an overdue frame permanently "due". */
  always @(posedge clk)
    if (~rst) refresh_cnt <= 4'd0;
    else if (clk_en) begin
      if ((state == STATE_INIT) && ofv_pickup)                refresh_cnt <= 4'd0;             // new frame picked up -> restart count
      else if ((state == STATE_NEXT_MB) && last_mb && last_y)
        refresh_cnt <= (refresh_cnt == 4'd15) ? 4'd15 : refresh_cnt + 4'd1; // one refresh (image scan) done; saturate (see above)
    end

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
    else if (clk_en && (state == STATE_NEXT_IMG)) disp_y <= vscale_en ? v_base_comb : ((image_0 == BOTTOM) ? 12'd1 : 12'd0);
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
    else if (clk_en && (state == STATE_INIT) && ofv_pickup) // build image sequence on pickup (INIT is reached paced)
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
              image_0 <= BOTTOM;
              image_1 <= TOP;
            end
          BOTTOM:
            begin
              image_0 <= TOP;
              image_1 <= BOTTOM;
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
    else if (clk_en && (state == STATE_INIT) && ofv_pickup) output_frame_sav <= output_frame;
    else output_frame_sav <= output_frame_sav;

  /* determine frame, top, bottom sequence */
  always @(posedge clk)
    if (~rst) encoder_bug_workaround <= 1'b0;
    else if (clk_en && (state == STATE_INIT) && ofv_pickup) encoder_bug_workaround <= progressive_frame && repeat_first_field;
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
  wire signed [12:0]disp_mv_y_minus_4 =  (disp_y[11:2] == 10'b0)                                            ? 13'sd0 : -13'sd4;
  wire signed [12:0]disp_mv_y_minus_2 =  (disp_y[11:1] == 11'b0)                                            ? 13'sd0 : -13'sd2;
  wire signed [12:0]disp_mv_y_plus_2  =  ((disp_y[11:4] == mb_height_minus_one) && (disp_y[3:1] == 3'b111)) ? 13'sd0 : 13'sd2;
  wire signed [12:0]disp_mv_y_plus_4  =  ((disp_y[11:4] == mb_height_minus_one) && (disp_y[3:2] == 2'b11))  ? 13'sd0 : 13'sd4;

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
        STATE_WR_V_LOWER: if (progressive_upscaling) disp_mv_y <= disp_y[0] ? disp_mv_y_plus_2 : disp_mv_y_minus_2;
                          else disp_mv_y <= disp_y[1] ? disp_mv_y_plus_4 : disp_mv_y_minus_4;
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

  always @(posedge clk)
    if (~rst) resample_wr_dta <= 2'b0;
    /* DVD-FORK FIX: use the 2-bit saturating disp_y_sat (cannot wrap at 256) instead of
     * the wide disp_y==0/==1 compares, so no SPURIOUS frame-top (ROW_0_COL_0) can be
     * emitted at line 256. This is the 256-line strobe fix (see disp_y_sat above). */
    else if (clk_en && (state == STATE_WR_OSD_MSB) && (disp_mb == mb_first_c) && (disp_y_sat == 2'd0)) resample_wr_dta <= ROW_0_COL_0;
    else if (clk_en && (state == STATE_WR_OSD_MSB) && (disp_mb == mb_first_c) && (disp_y_sat == 2'd1)) resample_wr_dta <= ROW_1_COL_0;
    else if (clk_en && (state == STATE_WR_OSD_MSB) && (disp_mb == mb_first_c)) resample_wr_dta <= ROW_X_COL_0;
    else if (clk_en && (state == STATE_WR_OSD_MSB) && (disp_mb == mb_last_c)) resample_wr_dta <= ROW_X_COL_LAST;
    else if (clk_en && (state == STATE_WR_OSD_MSB)) resample_wr_dta <= ROW_X_COL_X;
    else resample_wr_dta <= resample_wr_dta;

  always @(posedge clk)
    if (~rst) resample_wr_en <= 1'b0;
    else if (clk_en) resample_wr_en <= (state == STATE_WR_OSD_MSB);
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
