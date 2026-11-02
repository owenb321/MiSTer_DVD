# Standard conversion by speed change

**Status:** 🔧 design and Phase 0 measurements only; no RTL yet. Branch `feature/std-convert`.

PAL film slowed by 960/1001 plays at 23.976 frames/s and maps onto 3:2 at 59.94 Hz. NTSC film
sped up by 1001/960 plays at 25 frames/s and maps onto 2:2 at 50 Hz. Both ratios are exact from
the existing 27 MHz clock.

**Decisions (maintainer, 2026-11-01):**
- One fixed speed per disc, including menus and logos. Cadence is chosen separately, so a wrong
  call costs judder on that clip and never changes pitch, speed or raster.
- Order: clock and HDMI/`vga_scaler` in both directions, then PAL→NTSC on direct analog. NTSC→PAL
  on direct analog is deferred (6/5 upscale, 1-in-5 frame drop on 60i).
- Conversion overrides passthrough: audio is decoded in the core while converting.

**Rejected:**
- Per-content speed switching: the film detector needs about 1.6 s to engage, and each switch is
  an audible pitch jump.
- Time-stretch: no fabric budget to justify it, and slowing often restores the original pitch.
- Passthrough at a false 48 kHz: the payload's timing wouldn't match its declared rate.

## Phase 0: how PAL content is really flagged (2026-11-02)

Everything below is a read-only sweep of the local library, with a decoded-pixel check in `ffmpeg`.

**The sample is small and skewed:** 1,594 images scanned, of which 25 are PAL by measured sequence
header height, 1,557 NTSC, and 12 unclassified (11 had no sequence header in the three windows
sampled, 1 is a deliberately bad image). The PAL set is heavy on interactive and game discs, with
few commercial films. Treat the percentages as direction, not as a population estimate.

**`progressive_frame` is asymmetric.** Title windows of 1000 sectors, with `idet` needing at least
15 determined frames (windows without a verdict are excluded):

| Flag | Pixels look progressive | Pixels look interlaced | Unclear |
|---|---|---|---|
| `pf=1` (255 windows) | 251 | 3 | 1 |
| `pf=0` (563 windows) | 240 | 311 | 12 |

`idet` can call low-motion true 50i progressive, so the `pf=0` windows were re-measured on moving
frames only. On a moving pixel, interlaced motion makes a line differ more from its neighbour (the
other field) than from the line two below (the same field).

| `pf=0` windows, up to the 4 first of each of a disc's 8 largest segments | Count |
|---|---|
| Film-like (≤ 15 % of moving frames comb) | 140 |
| Mixed | 38 |
| Video-like (≥ 50 %) | 56 |
| Too static to judge | 183 |

**Control for that metric** on `pf=1` windows of four discs: all 35 windows with enough motion
scored film, and the same windows re-woven from consecutive frames scored 32 video, 2 mixed, 1 film.
⚠ That weave has a 40 ms field offset, twice real 50i, so the control is easier than real content
and true 50i may be under-called. The ratio is not exact, but the conclusion doesn't depend on it.

**Conclusions:**
- `pf=1` can be trusted as film.
- `pf=0` cannot be trusted as video: most moving `pf=0` windows look like film, including
  INTERSTELLA 5555's main feature (19 film, 4 video, 2 mixed). Choosing cadence from the flag alone
  would give such a feature the 2:2:2:4 pair-repeat on a CRT.
- Mixing within a disc is real. COWBOY_BEBOP scores 10 film, 11 video, 7 mixed.
- This only affects Phase 3. On the HDMI path every picture gets one refresh of the film raster and
  ascal makes the 3:2, so no per-picture cadence choice exists there.

**NTSC:**
- Library sidecars: 1,041 FILM, 339 VIDEO, 85 MIXED, 17 FILM/PROGRESSIVE.
- In a seeded sample of 80 of the 336 VIDEO-verdict discs that have a sidecar, `idet`'s repeated
  field share on the main title suggests 1 hard-telecined, 21 partial, 58 true video.
- ⚠ That repeated-field metric has no control yet, so it is a rough guide only.

## Desk results that change the implementation

- **`nav_trace` keeps the true 90 kHz tick.** Its `free` counter maps entries onto the HPS's
  `CLOCK_MONOTONIC` (`dvd/nav_trace.sv`, "WHY TWO TIMESTAMPS"). So `stc_div` stays as it is and a
  rational tick is added beside it, driving only the STC. A scaled `stc` beside a true `free` in a
  trace is correct and expected.
- **`cell_secs` stays in authored time if `disp_fps` follows the source, not the raster.** A
  23.976 Hz tick then counts 25 per authored second, and NTSC on 25 Hz counts 24. PAL on a 59.94
  field raster would need 62.5; use 62, which overcounts and so can only under-hold. 63 would add a
  false still on long cells (`dur_hold_w`, `dvd/dvd_iso_reader.sv`).
- **The interlaced-frame branch of the `resample_addrgen.v` image build has no third-field arm,**
  so 3:2 on a `pf=0` picture needs more than synthetic `rff`.

## Not done yet

- The ascal lock check at 875×1287 with 576 active and 864×1250 with 480 active needs a build, so
  it moves to the start of Phase 2.
- ⏳ **Next step:** the maintainer's call on how Phase 3 picks a cadence for `pf=0` pictures. Phases
  1 and 2 don't depend on it.
- The census scripts are still scratch files. Add them to `tools/` before this note's numbers are
  relied on elsewhere.
