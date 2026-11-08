# Standard conversion by speed change

**Status:** 🔧 Phases 1 and 2 built and measured on the rig, on `feature/std-convert`
(`DVD_stdconvert_20261102_2317.rbf`). ⏳ Save state, subtitles by eye and a by-ear check are still open.
**Files:** `dvd/std_rate.sv`, `dvd/emu.sv`, `dvd/pal_detect.sv` (`valid`), `dvd/dvd_audio_decode.sv`
(`nco_fs_out`). **Gates:** `bench/dvd/run_std_rate.sh --red`, `tools/check_std_convert_wiring.py`.

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

## Phases 1 and 2 as built

**`pal_eff` stays the SOURCE's standard; only `pal_out` takes the target.** The plan expected to
split about 20 uses of `pal_eff`. Because the raster's active lines equal the source's on this
path, nearly every consumer already wants the source, and each comes out right with no new
constant:

- `half_scan` stays 1800 or 1877: under the scaled STC one film-raster refresh is still one source
  picture period in ticks.
- `disp_fps` stays 25 or 24, which keeps `cell_secs` in authored seconds.
- Overlays, `act_vres` and SPU `pal_mode` follow the active lines.

**Cross modes** use the raster's totals with the source's active lines: 875×1287 with 576 active
(exactly 24000/1001 Hz), 864×1250 with 480 active (exactly 25 Hz). Vsync is 581..586 on both,
because NTSC's 488..494 would land inside 576 active lines.

**Gates on `std_conv_active`:**

- `pal_val_s2`, from `pal_detect`'s new `valid`: `pal` keeps the previous file's value across a
  mount and reads 0 at power-on, so without this `To PAL` would convert the idle screen and a new
  disc would start on the last disc's verdict.
- `~interlaced_eff`, `~analog_want`: no analog display holds the film raster.
- `~sif_det_s2`, `~cdda_mode_w`: SIF has its own raster, and CD-DA/WAV has no picture.

**Accepted consequences:**

- Non-SIF is broader than "480 or 576 lines": `pal_detect` has no whitelist on purpose, so a flat
  `.mpg` at another height converts too, judged by whether it is over 480 lines. A 480-line file
  that isn't 23.976 fps also gets the fixed ratio. Neither is a DVD-Video case.
- A mount drops `valid`, so a convert user sees the raster walk at each disc change, and a
  passthrough user sees a PCM-to-bitstream switch if the new disc needs no conversion.
- `dec_duty`'s per-picture budget thresholds assume the source's true rate, so they are about 4 %
  off while converting. Instrument only.
- Timed stills use wall-clock seconds (`SEC_DIV`), so they don't scale. Nothing is synchronised to
  them, so a still is just 4 % long or short relative to the speed.

## Hardware results (2026-11-02, `.236`, against v0.10.0)

Rates come from telemetry counters: `refreshes` and `aud_play` over `t`, and STC from two `snap`s.
120 s of title playback with Disc Menus off, `vga_scaler=1` for this core:

| Arm | Raster Hz | Audio Hz | STC Hz | Lates/s | `av_drift` first → last quarter, ms |
|---|---|---|---|---|---|
| Control, BBB 25p | 24.997 | 47,999 | 89,997 | 0 | −75.9 → −84.4 |
| To NTSC, BBB | 23.981 | 46,033 | 86,315 | 0 | −82.2 → −84.9 |
| Control, The Office 25i | 49.999 | 47,999 | 89,998 | 0 | −1.6 → −1.0 |
| To NTSC, The Office | 23.972 | 46,034 | 86,312 | 0 | 3.3 → 2.8 |
| Control, MiB soft telecine | 23.974 | 48,000 | 90,000 | 0.016 | −31.5 → −32.6 |
| To PAL, MiB | 24.996 | 50,049 | 93,842 | 0.008 | −28.2 → −27.1 |

Expected: 23.976 Hz, 46,034 Hz and 86,314 Hz slowed; 25 Hz, 50,050 Hz and 93,844 Hz sped up.
Screenshots show the right geometry on both cross modes, and HDMI capture has audible audio.

**True 30i on To PAL drops exactly 1 in 5,** as the arithmetic says: MiB's animated menu reads
6.26 lates/s and 6.24 drops/s (31.25 pictures/s on a 25 Hz raster). That is the expected price, not
a fault, and it sits right at `DROP_COOL`'s limit of about 6/s, so `disp_lag` rides at −60 to −105 ms.

**Defect found and fixed: passthrough rising after a mount.** To PAL with Passthru selected read
`play_err` 241, 31 and 84 ms over three runs, against 31 ms on every run without Passthru. Cause: a
mount drops `valid`, conversion is off in the gap, and a passthrough session starts and is torn
down just as audio starts. `std_conv_wait` holds passthrough off until the verdict. Six repeats on the
fixed build read 30 to 34 ms, the same as without Passthru. An NTSC disc with To NTSC and Passthru
selected still gets a real bitstream session (`eng_frames` 0, as on the v0.10.0 control).

**Transport while converting, To PAL on MiB and To NTSC on The Office:** pause stops pictures and
audio and resumes at the scaled rates; next and previous chapter, audio and subtitle step and d-pad
seek all keep video and audio at those rates, with 0 lates and no re-anchor. These are rate
measurements: they don't prove a subtitle lands right on the picture.

**Unrelated pre-existing fault found: audio dies until a reboot.** After about 25 core loads in one
boot, `dts_copied`, `dts_ok` and `eng_frames` all read 0 and HDMI capture read −61 dB. The state
survived further core loads, and **v0.10.0 was equally dead when flashed onto the rig in that state**,
so this branch did not cause it. A reboot cleared it. Video was unaffected. Cause not established:
the codebook copy over `ram2` never finishing, with something outside the FPGA holding that state, is
a guess. See `docs/roadmap.md`. A run whose `dts_ok` reads 0 is void, and it is easy to misread as a
passthrough session, since `aud_play` also reads 0 there.

⚠ **Trap for the next measurement:** telemetry counters are zeroed by a flush, so a decrease is
usually not a 16-bit wrap. Treating it as one gave 3,167 pickups/s on The Office, which crosses two
transitions in the first 60 s. Measure rates with Disc Menus off, away from menus.

## Phase 3 plan: PAL→NTSC on direct analog (agreed 2026-11-07)

A 525-line raster has about 486 visible lines, so it can't carry 576 active lines. PAL→NTSC on
a CRT therefore needs a real vertical scale. Both standards put the same 4:3 picture on 720
samples over the same active line time, so the scale is purely vertical and keeps geometry
exact. The horizontal path (`disp_hstretch` Crop, SIF fill) is untouched.

**Decisions (maintainer accepted every recommendation):**

| Analog Aspect | Scale | Lines |
|---|---|---|
| Fit | 5/6 | 576 → 480, 288 → 240 per field |
| Letterbox (16:9 on 4:3) | 5/8, **one pass** rather than 5/6 then 3/4 | 576 → 360 |
| Crop | 5/6, plus the existing horizontal pan-scan | 576 → 480 |

- **Kernel: 2-tap bilinear per field,** as Letterbox already uses. Slightly soft, but it doesn't
  alias the way dropping every sixth line would.
- **Fields are scaled, not frames,** on the field path: `resample_addrgen` hands
  `disp_vscale` one field's lines contiguously, so neighbours are same-field and motion isn't
  combed. Both cadences keep every source field in its own parity slot (3:2 gives A: T B T,
  B: B T; 50i pair-repeat repeats whole pairs), so per-field scaling is safe.
- **Bottom-field phase done properly.** Output line `y` reads source frame position `y·S`, where
  S is source lines per output line. A bottom-field output line `2i+1` therefore lands at
  bottom-field line `i·S + (S−1)/2`, which is a phase of 1/10 at 5/6 and 3/10 at 5/8, not 0.
  Starting at 0 gives a faint bob on fine detail. The **existing 3/4 Letterbox has the same
  1/6-line error** and gets the fix in its own small change, so the 5/6 work lands bit-identical
  for 3/4.
- **Order:** scaler and overlay mapping first, measured on a progressive-flagged disc. Then the
  synthetic 3:2 field cadence, and last the `progressive_frame=0` cadence question.
- **NTSC→PAL on direct analog stays deferred:** 480 → 576 is an upscale, which `disp_vscale`'s
  flow control can't do as built (output would outrun input).

**Implementation:**

1. **`dvd/disp_vscale.sv`:** the Bresenham remainder moves from sixths to **sixtieths** of a
   source line, which covers every step (4/3 = 80/60, 6/5 = 72/60, 8/5 = 96/60) and every phase
   (1/6 = 10, 1/10 = 6, 3/10 = 18, the pause still's 1/2 = 30). The weight is
   `(r·273 + 32) >> 6`, equal to `round(256·r/60)` at every remainder reachable (multiples of
   6) and identical to the old sixths table, so 3/4 stays bit-identical. A per-scan ratio
   (0 = 3/4, 1 = 5/6, 2 = 5/8) rides the input FIFO beside the mode, as the mode does, so a
   ratio change can't tear a scan. A bottom field is a frame-top of `ROW_1_COL_0` (a frame
   scan's top is always `ROW_0_COL_0`).
2. **`dvd/emu.sv`:** conversion splits into two flavours. The **scaler path** is Phase 2
   unchanged (film cross-mode raster, ascal scales). The **analog path** applies when
   `interlaced_eff | analog_want`: the plain raster of the target standard (480i, or 480p at
   31 kHz), with `disp_vscale` doing 5/6 or 5/8. `disp_fps` on that raster is 62 (62.5 exact;
   62 can only under-hold, see `cell_secs`). `half_scan` is 720 (one 59.94 Hz field is 1440
   scaled ticks).
3. **Overlays after the scaler follow the raster, not the source**, on the analog path only.
   Phase 2 kept `pal_eff` = source everywhere because the active lines were the source's; that
   stops being true here. HUD, seek bar, idle logo and the mixer's `v_bar`/`v_band` take the
   raster standard. Subtitles and highlights keep querying source coordinates through
   `dvd/crt_ov_map.sv`, which gains the 5/6 and 5/8 inverses with the bottom-field phase.
   `tools/check_std_convert_wiring.py` pins both sides.
4. **No mixer change:** it places lines by their frame-top codes plus `disp_v_offset`, and the
   display window is the smaller of the raster and the stream, so 480 scaled lines on a 480-line
   raster just fit.

**Risks:**

- **Decode pacing** is the real unknown. The display reads 288 source lines per 16.7 ms field,
  about 20 % more line reads per second than PAL at 50 Hz, and display re-read contention is
  what caused lates before. Measure `dec_duty`, `pic_max` and lates on The Office and ROGER
  before adding anything else; stop and discuss if lates appear.
- **Until step 2 lands,** a film picture on the 59.94 field raster gets 2:2:2:4 (pair re-scan),
  not 3:2. Progressive analog (480p) already gets 3:2 from the due test, since 23.976 pictures
  meet 59.94 frames at 2.5 refreshes each, so it's the first thing to judge by eye.

## Not done yet

- ⏳ **Next step:** Phase 3 step 1, the `disp_vscale` ratios (plan above). Hardware testing waits for
  the analog path, by the maintainer's choice (2026-11-07).
- ⏳ `tools/hil_suite.py` with conversion Off against v0.10.0 has not run; Off matched the control on
  rates only.
- Phase 3's cadence for `pf=0` pictures: decided at Phase 3 (maintainer, 2026-11-02), when real CRT
  output can show how bad the wrong one looks.
- The census scripts are still scratch files. Add them to `tools/` before this note's numbers are
  relied on elsewhere.
