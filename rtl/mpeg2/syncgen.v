/* 
 * syncgen.v
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
 * sync_gen - Sync generator.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

/*
 * Generates horizontal and vertical synchronisation and timing.
 *
 * Inputs:
 *
 * horizontal_size, vertical_size, display_horizontal_size, and display_vertical_size
 * are parameters extracted from the MPEG2 bitstream. 
 * horizontal_size and vertical_size determine the size of the reconstructed bitmap in frame memory;
 * display_horizontal_size and display_vertical_size - if non-zero - are the displayable part of this bitmap.
 *
 * horizontal_resolution, horizontal_sync_start, horizontal_sync_end, horizontal_length,
 * vertical_resolution, vertical_sync_start, vertical_sync_end, horizontal_halfline and vertical_length determine video timing.
 *                                       
 * The timing parameters can be deduced from the X11 modeline for the display.
 * See "XFree86 Video Timings HOWTO".
 *
 * Note vertical_resolution, vertical_sync_start, vertical_sync_end and vertical_length refer to a frame if
 * progressive, and to a field if interlaced.
 *
 * For instance, vertical_resolution is number of visible lines per frame if progressive,
 * and number of visible lines per field if interlaced.
 *
 * If 'interlaced' is asserted, vertical sync is delayed one-half scan line at the end of odd frames.
 * This is similar to "interlace sync and video mode" of the mc6845 crtc.
 *
 * Outputs:
 * h_pos and v_pos are the coordinates of the current pixel.
 * pixel_en is not asserted if blanking is required.
 * h_sync and v_sync are horizontal and vertical synchronisation,
 * respectively.
 *
 */

module sync_gen    (clk, clk_en, rst,
                   horizontal_size, vertical_size, display_horizontal_size, display_vertical_size,
                   horizontal_resolution, horizontal_sync_start, horizontal_sync_end, horizontal_length,
                   vertical_resolution, vertical_sync_start, vertical_sync_end, horizontal_halfline, vertical_length,
                   interlaced, clip_display_size,
                   h_pos, v_pos, pixel_en, h_sync, v_sync, c_sync, h_blank, v_blank);

  input            clk;
  input            clk_en;
  input            rst;

  input      [13:0]horizontal_size;               /* par. 6.2.2.1, par. 6.3.3 */
  input      [13:0]vertical_size;                 /* par. 6.2.2.1, par. 6.3.3 */
  input      [13:0]display_horizontal_size;       /* par. 6.2.2.4, par. 6.3.6 */
  input      [13:0]display_vertical_size;         /* par. 6.2.2.4, par. 6.3.6 */

  input      [11:0]horizontal_resolution;         /* horizontal resolution. number of dots per line */
  input      [11:0]horizontal_sync_start;         /* the dot the horizontal sync pulse begins. */
  input      [11:0]horizontal_sync_end;           /* the dot the horizontal sync pulse ends. */
  input      [11:0]horizontal_length;             /* total horizontal length */
  input      [11:0]vertical_resolution;           /* vertical resolution. number of visible lines per frame (progressive) or field (interlaced) */
  input      [11:0]vertical_sync_start;           /* the line number within the frame (progressive) or field (interlaced) the vertical sync pulse begins. */
  input      [11:0]vertical_sync_end;             /* the line number within the frame (progressive) or field (interlaced) the vertical sync pulse ends. */
  input      [11:0]horizontal_halfline;           /* the dot the vertical sync begins on odd frames of interlaced video. Not used in progressive mode. */
  input      [11:0]vertical_length;               /* total number of lines of a vertical frame (progressive) or field (interlaced) */
  input            interlaced;                    /* asserted if interlaced output required. */
  input            clip_display_size;             /* assert to clip image to (display_horizontal_size, display_vertical_size) */

  output reg [11:0]h_pos;                         /* horizontal position */
  output reg [11:0]v_pos;                         /* vertical position */
  output reg       pixel_en;                      /* pixel enable, asserted when pixel drawn */
  output reg       h_sync;                        /* horizontal sync */
  output reg       v_sync;                        /* vertical sync */
  output reg       c_sync;                        /* complex sync */
  output reg       h_blank;                       /* horizontal blanking */
  output reg       v_blank;                       /* vertical blanking */

  /* 
   * general registers 
   */

  reg        [11:0]h_size;
  reg        [11:0]h_display_size;
  reg        [11:0]v_size;
  reg        [11:0]v_display_size;
  reg        [11:0]v_sync_h_pos;
  reg              odd_field;

  /*
   * v_sync_h_pos: horizontal position of vertical sync.
   * In progressive video,  the vertical sync begins at horizontal position 0,
   * In interlaced video:
   *  - in even fields, vertical sync begins at horizontal position 0
   *  - in odd fields,  vertical sync is delayed horizontal_halfline dots.
   *  A common value for horizontal_halfline is horizontal_length/2.
   */

  always @(posedge clk)
    if (~rst) v_sync_h_pos <= 12'd0;
    else if (clk_en) v_sync_h_pos <= (interlaced && odd_field) ? horizontal_halfline : 12'd0;
    else v_sync_h_pos <= v_sync_h_pos;

  /* DVD-FORK FIX (CRT 2:1 interlace, N64 model): the upstream half-line mechanism above
   * only PULSE-DELAYS the vsync edge within an unchanged, fixed-length field — the
   * vertical counter reference never moves, and the total frame stays EVEN (2x
   * vertical_length+1 lines). On a real CRT that never locks 2:1 (HW-verified: vertical
   * buzz/jitter, or a stable 240p-equivalent with the half-line off). Broadcast 480i
   * needs an ODD total (525 = 262.5 x 2), i.e. BOTH of:
   *   - per-field total alternating 262/263 full lines, and
   *   - the vertical COUNTER REFERENCE (the point in the line where "line N of the
   *     field" begins for sync purposes) shifted by half a line on one field,
   * so vsync-to-vsync spacing is exactly 262.5 lines every field. This is how the
   * known-good N64 core does it (MiSTer-devel/N64_MiSTer rtl/VI_videoout_sync.vhd:
   * vtotal 262/263 by field + vsyncCount sampled at htotal/2 on one field).
   *
   * crt_ilace selects the new model: interlaced with a NONZERO horizontal_halfline.
   * All existing consumers write halfline=0 when interlaced (the HDMI-480i modeline
   * walk in dvd/emu.sv), so their pulse-delay behavior is bit-identical; only the new
   * CRT modeline (halfline = horizontal_length/2 = 429) takes this path.
   *
   * Field mapping (derivation): let field A have LA full lines with vsync sampled at
   * dot 0, field B LB lines with vsync sampled at dot `halfline`. Spacing A->B =
   * LA + 0.5 lines, B->A = LB - 0.5 lines; both equal 262.5 iff LA=262, LB=263.
   * odd_field=1 scans v_pos even lines (TOP content, the upper field), so it is the
   * reference field A; odd_field=0 (BOTTOM content) is B: one extra line and the
   * mid-line vsync. (If HW shows the fields spatially swapped, flip both terms.) */
  wire        crt_ilace   = interlaced && (horizontal_halfline != 12'd0);
  /* DVD-FORK (single-raster analog): the vertical-sync sample dot. Dot 0 on the
   * reference field, mid-line (halfline) on the other — the upstream N64-model
   * placement, HW-proven on a composite CRT both in the O[14] mode and through the
   * retired re_interlace second raster.
   * ⚠ HW ROUND 2 (2026-09-03) REVERTED an experiment that anchored these on the
   * HSYNC LEADING EDGE (horizontal_sync_start, +halfline wrapping to the next line)
   * because the framework's csync serrates on a line grid and dot-0 gives the two
   * fields different broad-pulse widths (~50 us / ~18 us, bench/dvd/csync_field_tb.sv).
   * On the maintainer's composite CRT that anchoring made the picture BOUNCE at field
   * rate and look blockier, and the bench's separator models never reproduced it —
   * they now show both placements within a clock of each other once the serrations
   * run at 2H (the real asymmetry fix, sys/sys_top.v csync). The CRT is the reference
   * for the analog path: do not re-anchor without one to test on. */
  wire [11:0] vs_ref_dot  = odd_field ? 12'd0 : horizontal_halfline;   /* vertical-event sample dot */
  /* (the half-line-referenced vsync sampler itself lives below, after the h/v
   *  counters it samples — see "CRT vsync sampler") */

  /*
   * for h_display_size and v_display_size:
   * display_horizontal_size and display_vertical_size are optional mpeg2 parameters.
   * If display_horizontal_size and display_vertical_size are  zero, the whole frame is displayable; use horizontal_size and vertical_size instead.
   * If display_horizontal_size and display_vertical_size are non-zero, only display_horizontal_size by display_vertical_size of the frame is displayable.
   */

  always @(posedge clk)
    if (~rst) h_display_size <= 12'd0;
    else if (clk_en) h_display_size <= ((display_horizontal_size != 0) && clip_display_size) ? display_horizontal_size[11:0] : ((horizontal_size != 0) ? horizontal_size[11:0] : horizontal_resolution); 
    else h_display_size <= h_display_size;

  always @(posedge clk)
    if (~rst) v_display_size <= 12'd0;
    else if (clk_en && interlaced) v_display_size <= ((display_vertical_size != 0) && clip_display_size) ? display_vertical_size[11:1] : ((vertical_size != 0) ? vertical_size[11:1] : vertical_resolution[11:1]); // interlacing; one field contains half the visible lines.
    else if (clk_en) v_display_size <= ((display_vertical_size != 0) && clip_display_size) ? display_vertical_size[11:0] : ((vertical_size != 0) ? vertical_size[11:0] : vertical_resolution); // no interlacing; one frame contains all visible lines.
    else v_display_size <= v_display_size;

  always @(posedge clk)
    if (~rst) h_size <= 12'd0;
    else if (clk_en) h_size <= (horizontal_size != 0) ? horizontal_size[11:0] : horizontal_resolution;
    else h_size <= h_size;

  always @(posedge clk)
    if (~rst) v_size <= 12'd0;
    else if (clk_en && interlaced) v_size <= (vertical_size != 0) ? vertical_size[11:1] : vertical_resolution[11:1];
    else if (clk_en) v_size <= (vertical_size != 0) ? vertical_size[11:0] : vertical_resolution;
    else v_size <= v_size;
 
  /* 
   * Stage 0
   */

  reg        [11:0]h_cntr;
  reg        [11:0]v_cntr;

  /* horizontal counter */
  always @(posedge clk)
    if (~rst) h_cntr <= 12'd0;
    else if (clk_en) h_cntr <= (h_cntr >= horizontal_length) ? 12'd0 : (h_cntr + 1);
    else h_cntr <= h_cntr;

  /* vertical counter */
  /* DVD-FORK FIX (CRT 2:1 interlace): in interlaced mode the field totals ALTERNATE —
   * the B field (odd_field=0) is one full line longer, giving the odd frame total
   * (2*(vertical_length+1)+1 lines, e.g. 262+263=525). vertical_length still holds the
   * SHORT field's last line index (261 for NTSC, 311 for PAL). odd_field toggles at the
   * field's first dot, so the bound is stable across each whole field.
   *
   * DVD-FORK HARDENING (2026-08-02) — arming widened crt_ilace -> interlaced.
   * BEHAVIOURAL NO-OP TODAY (verified: the whole TB gives identical results against
   * the pre-change file); it removes an ACCIDENTAL dependency, so read this before
   * "tidying" syncgen_intf.
   *
   * The alternating field total is what makes an interlaced frame land on an EXACT
   * rate: 262+263 = 525 lines x 1716 dots = 900,900 clk27 = 29.97 fps, and
   * 312+313 = 625 x 1728 = 1,080,000 = 25.000 fps. Since nco_trim is retired (audio
   * free-runs at a fixed 48 kHz off the same crystal), an inexact raster is a
   * permanent linear A/V drift — see docs/av_sync.md "raster-rate invariant" and the
   * Film-24p 858x1313 case (docs/film_24p_plan.md §10). With EQUAL 262-line fields
   * NTSC 480i would be 899,184 clk27 = 0.19 % fast = ~6.9 s/hour of drift.
   *
   * The trap: this alternation used to be armed by `crt_ilace` = interlaced &&
   * halfline != 0, and dvd/emu.sv's HDMI Interlaced Out modeline writes halfline = 0
   * (deliberately — a half-line vsync offset makes an HDMI receiver hunt for lock).
   * It nevertheless got the alternation, because syncgen_intf doubles EVERY horizontal
   * parameter under pixel repetition as `{x[10:0],1'b1}` = 2x+1 — and 2*0+1 = **1**,
   * which is nonzero. So HDMI-480i/576i have always been exact, but only by accident
   * of that doubling; anyone "fixing" 0 -> 0 there would have silently made both
   * rasters 0.19 %/0.16 % fast. Arming on `interlaced` alone makes the exactness
   * explicit and independent of it. (2026-09-03: the interlaced modeline now writes
   * halfline 429/432 — doubled 2x to 858/864 by syncgen_intf — so HDMI and the analog
   * pins share ONE half-line raster, docs/single_raster_analog.md.) Nothing else asserts `interlaced` —
   * modeline.v's default is VID_MODE 3'b000.
   * Pinned by bench/dvd/crt_syncgen_tb.sv PHASE 2 (480i) and PHASE 2b (576i). */
  wire [11:0] eff_vertical_length = vertical_length + {11'd0, interlaced & ~odd_field};
  always @(posedge clk)
    if (~rst) v_cntr <= 12'd0;
    else if (clk_en && (h_cntr >= horizontal_length)) v_cntr <= (v_cntr >= eff_vertical_length) ? 12'd0 : (v_cntr + 1);
    else v_cntr <= v_cntr;

  /* DVD-FORK FIX (CRT 2:1 interlace): the CRT vsync sampler (see the crt_ilace note
   * above). The vsync window [vertical_sync_start, vertical_sync_end) is sampled once
   * per line at the field's reference dot vs_ref_dot (dot 0 on the reference field,
   * mid-line on the other) => exactly (end-start) FULL lines of vsync in both fields,
   * the B field's shifted half a line. With the alternating field totals this puts
   * vsync rising edges exactly 262.5 lines apart every field — the 2:1 lock. */
  wire        vsync_window   = (v_cntr >= vertical_sync_start) && (v_cntr < vertical_sync_end);
  reg         vsync_crt;
  wire        vsync_crt_nxt  = (h_cntr == vs_ref_dot) ? vsync_window : vsync_crt;
  always @(posedge clk)
    if (~rst) vsync_crt <= 1'b0;
    else if (clk_en) vsync_crt <= vsync_crt_nxt;
    else vsync_crt <= vsync_crt;

  /* 
   * Stage 1
   */
 
  reg        [11:0]h_cntr_1;
  reg        [11:0]v_cntr_1;
  reg              h_blank_1;
  reg              v_blank_1;
  reg              h_sync_1;
  reg              v_sync_1;

  always @(posedge clk)
    if (~rst) h_cntr_1 <= 12'd0;
    else if (clk_en) h_cntr_1 <= h_cntr;
    else h_cntr_1 <= h_cntr_1;

  always @(posedge clk)
    if (~rst) v_cntr_1 <= 12'd0;
    else if (clk_en) v_cntr_1 <= v_cntr;
    else v_cntr_1 <= v_cntr_1;

  /* horizontal synchronisation */
  always @(posedge clk)
    if (~rst) h_sync_1 <= 1'b0;
    else if (clk_en) h_sync_1 <= (h_cntr >= horizontal_sync_start) && (h_cntr <= horizontal_sync_end);
    else h_sync_1 <= h_sync_1;

  /* DVD-FORK NOTE — KNOWN OFF-BY-ONE in the active-region blanking below.
   * These blank when the counter is `>= resolution`, which makes the active region exactly
   * `resolution` pixels/lines. But the modeline params (modeline.v) and the regfile doc treat
   * horizontal_resolution / vertical_resolution as "active count MINUS ONE" (e.g. NTSC stores
   * HORZ_RES=719 for 720, VERT_RES was 479 for 480). So `>=` lands the active region ONE short
   * of the intended count. The clean root fix is `>=` -> `>` here (and in the matching h_sync/
   * v_sync/length compares as needed) for BOTH axes and ALL modelines at once — but that
   * touches every mode and was deemed risky. Instead each axis was fixed TARGETALLY in the
   * active modeline: VERT_RES 479->480 (vertical active = 480 = standard 480p) and HORZ_RES
   * 719->720 (horizontal active = 720 = standard 720 SD), both in modeline.v AND the runtime
   * register-write walk in dvd/emu.sv (the walk's values override the static params at boot).
   * If you ever switch the compares here to `>`, REVERT BOTH back to the -1 values (479/719,
   * and re-check all other modelines) or you'll over-extend by one. See docs/history.md
   * (256-line strobe). */

  /* horizontal blanking */
  always @(posedge clk)
    if (~rst) h_blank_1 <= 1'b1;
    else if (clk_en) h_blank_1 <= (h_cntr >= horizontal_resolution) || (h_cntr >= h_size) || (h_cntr >= h_display_size);
    else h_blank_1 <= h_blank_1;

  /* vertical synchronisation */
  /* DVD-FORK FIX (CRT 2:1 interlace): in crt_ilace mode vsync comes from the
   * half-line-referenced sampler above (vsync_crt_nxt), not the pulse-delay
   * expression. Non-CRT modes (halfline==0) are bit-identical to upstream. */
  always @(posedge clk)
    if (~rst) v_sync_1 <= 1'b0;
    else if (clk_en) v_sync_1 <= crt_ilace ? vsync_crt_nxt
                              : (((v_cntr == vertical_sync_start) && (h_cntr >= v_sync_h_pos))
                              || ((v_cntr > vertical_sync_start) && (v_cntr < vertical_sync_end))
                              || ((v_cntr == vertical_sync_end) && (h_cntr < v_sync_h_pos)));
    else v_sync_1 <= v_sync_1;

  /* vertical blanking */
  always @(posedge clk)
    if (~rst) v_blank_1 <= 1'b1;
    else if (clk_en) v_blank_1 <= (v_cntr >= vertical_resolution) || (v_cntr >= v_size) || (v_cntr >= v_display_size);
    else v_blank_1 <= v_blank_1;

  /* 
   * odd_field is asserted during odd fields of interlaced pictures.
   * odd_field is not asserted when video is not interlaced.
   */

  always @(posedge clk)
    if (~rst) odd_field <= 1'b0;
    else if (clk_en && ~interlaced) odd_field <= 1'b0;
    else if (clk_en && interlaced && (h_cntr == 12'b0) && (v_cntr == 12'b0)) odd_field <= ~odd_field; // when interlaced, toggle 
    else odd_field <= odd_field;

  /* 
   * Stage 2
   */

  reg        [11:0]h_cntr_2;
  reg        [11:0]v_cntr_2;
  reg              h_blank_2;
  reg              v_blank_2;
  reg              h_sync_2;
  reg              v_sync_2;

  always @(posedge clk)
    if (~rst) h_cntr_2 <= 12'd0;
    else if (clk_en) h_cntr_2 <= h_cntr_1;
    else h_cntr_2 <= h_cntr_2;

  always @(posedge clk)
    if (~rst) v_cntr_2 <= 12'd0;
    else if (clk_en) v_cntr_2 <= v_cntr_1;
    else v_cntr_2 <= v_cntr_2;

  always @(posedge clk)
    if (~rst) h_blank_2 <= 1'b1;
    else if (clk_en) h_blank_2 <= h_blank_1;
    else h_blank_2 <= h_blank_2;

  always @(posedge clk)
    if (~rst) v_blank_2 <= 1'b1;
    else if (clk_en) v_blank_2 <= v_blank_1;
    else v_blank_2 <= v_blank_2;

  always @(posedge clk)
    if (~rst) h_sync_2 <= 1'b0;
    else if (clk_en) h_sync_2 <= h_sync_1;
    else h_sync_2 <= h_sync_2;

  always @(posedge clk)
    if (~rst) v_sync_2 <= 1'b0;
    else if (clk_en) v_sync_2 <= v_sync_1;
    else v_sync_2 <= v_sync_2;

  /*
   * horizontal coordinate
   */

  always @(posedge clk)
    if (~rst) h_pos <= 12'd0;
    else if (clk_en) h_pos <= h_cntr_2;
    else h_pos <= h_pos;

  /*
   * vertical coordinate: line number.
   * If progressive, v_pos sequences through the line number 0, 1, 2, 3, 4, 5, ...
   * If interlaced, v_pos sequences through even numbers on odd fields 0, 2, 4, ...
   * and through odd numbers on even fields 1, 3, 5, ...
   * (This is because tv people start counting from 1, not 0.)
   */

  always @(posedge clk)
    if (~rst) v_pos <= 12'd0;
    else if (clk_en) v_pos <= interlaced ? { v_cntr_2[10:0], ~odd_field } : v_cntr_2;
    else v_pos <= v_pos;

  always @(posedge clk)
    if (~rst) h_sync <= 1'b0;
    else if (clk_en) h_sync <= h_sync_2;
    else h_sync <= h_sync;

  always @(posedge clk)
    if (~rst) v_sync <= 1'b0;
    else if (clk_en) v_sync <= v_sync_2;
    else v_sync <= v_sync;

  always @(posedge clk)
    if (~rst) h_blank <= 1'b1;
    else if (clk_en) h_blank <= h_blank_2;
    else h_blank <= h_blank;

  always @(posedge clk)
    if (~rst) v_blank <= 1'b1;
    else if (clk_en) v_blank <= v_blank_2;
    else v_blank <= v_blank;

  /*
   * pixel enable
   */

  always @(posedge clk)
    if (~rst) pixel_en <= 1'd0;
    else if (clk_en) pixel_en <= ~h_blank_2 && ~v_blank_2;
    else pixel_en <= pixel_en;

  /*
   * composite sync
   */

  always @(posedge clk)
    if (~rst) c_sync <= 1'b0;
    else if (clk_en) c_sync <= ~(h_sync_2 ^ v_sync_2);
    else c_sync <= c_sync;

`ifdef DEBUG
  always @(posedge clk)
      begin
            $strobe("%m\th_pos: %4d v_pos: %4d h_cntr: %4d v_cntr: %4d h_sync: %d v_sync: %d h_blank: %d v_blank: %d pixel_en: %d odd_field: %d v_sync_h_pos: %d h_display_size: %d v_display_size: %d h_size: %d v_size: %d",
                          h_pos, v_pos, h_cntr, v_cntr, h_sync, v_sync, h_blank, v_blank, pixel_en, odd_field, v_sync_h_pos, h_display_size, v_display_size, h_size, v_size);

            $strobe("%m\thorizontal_size: %d vertical_size: %d display_horizontal_size: %d display_vertical_size: %d horizontal_resolution: %d horizontal_sync_start: %d horizontal_sync_end: %d horizontal_length: %d",
                         horizontal_size, vertical_size, display_horizontal_size, display_vertical_size, horizontal_resolution, horizontal_sync_start, horizontal_sync_end, horizontal_length);

            $strobe("%m\tvertical_resolution: %d vertical_sync_start: %d vertical_sync_end: %d horizontal_halfline: %d vertical_length: %d interlaced: %d",
                        vertical_resolution, vertical_sync_start, vertical_sync_end, horizontal_halfline, vertical_length, interlaced);

            $strobe("%m\t%4d.%4d h_sync: %0d v_sync: %0d h_blank: %0d v_blank: %0d pixel_en: %0d", h_pos, v_pos, h_sync, v_sync, h_blank, v_blank, pixel_en);

            $strobe("sync2graph %0d %0d %d %d %d", h_pos, v_pos, h_sync, v_sync, pixel_en); // for sync2graph testbench
      end
`endif
endmodule
/* not truncated */
