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
- **The interlaced-frame branch of the `resample_addrgen.v` image build had no third-field arm,**
  so 3:2 on a `pf=0` picture needed more than synthetic `rff`. Step 3 (below) gave it one.

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
4. **No mixer change:** it places lines by their frame-top codes plus `disp_v_offset`.
   ⚠ **Corrected 2026-11-09:** "the display window is the smaller of the raster and the stream"
   was true at 480p only. On an interlaced raster `sync_gen` compared `vertical_resolution`
   unhalved, so the field window was the stream's alone, and DE ran through vsync (fixed in
   `syncgen.v`, see the CRT first-look entry under "Not done yet").

**Risks:**

- **Decode pacing** is the real unknown. The display reads 288 source lines per 16.7 ms field,
  about 20 % more line reads per second than PAL at 50 Hz, and display re-read contention is
  what caused lates before. Measure `dec_duty`, `pic_max` and lates on The Office and ROGER
  before adding anything else; stop and discuss if lates appear.
- **Before step 2,** a film picture on the 59.94 field raster got 2:2:2:4 (pair re-scan), not
  3:2. Progressive analog (480p) always got 3:2 from the due test, since 23.976 pictures meet
  59.94 frames at 2.5 refreshes each.

## Phase 4 plan: NTSC→PAL on direct analog (agreed 2026-11-09)

The mirror of Phase 3: an NTSC disc with `Standard Convert = To PAL` on an analog output plays
4.3 % fast on the plain PAL raster, 576i or 576p as `Video Output` says, with `disp_vscale`
scaling the picture up. Reused unchanged: `std_rate` mode 2 (1001/960) and its NCO trim, the
per-disc decision and `std_conv_wait`, conversion over passthrough, the native 576i/576p
modelines, composite sync, and Main's Y/C setup (it picks a PAL burst from the measured rate).

**Decisions (maintainer, 2026-11-09):**

- **Upscale with a second line buffer in `disp_vscale`** (one 1024 x 32 bank, 3 to 4 M10K; 33 free), not
  `resample_addrgen` sending every fifth line twice. The addrgen route costs no M10K but
  touches the module that has broken most often and adds display reads.
- **True 30i loses 1 picture in 5,** accepted, as on the scaler path. The drop ceiling
  (`DROP_COOL`, about 6/s) is raised only while converting, because the scaler path rides at
  that ceiling with the picture 60 to 105 ms behind the sound.
- **Both 576i and 576p.**
- **Every picture is film,** as for To NTSC: 2 fields a picture, the disc's `repeat_first_field`
  ignored. NTSC film (23.976 sped up to 25) then plays as PAL film does.

| Analog Aspect | Scale | Lines |
|---|---|---|
| Fit / Crop | 6/5 up | 480 → 576, 240 → 288 per field |
| Letterbox (16:9 on 4:3) | 9/10 down | 480 → 432 |

**Implementation:**

1. **`dvd/disp_vscale.sv`:** ratio 3 = 6/5 and ratio 4 = 9/10. The 9/10 step (10/9 of a source
   line) is not a whole number of sixtieths, so the remainder unit goes to **180ths** (every
   existing step and phase is a multiple of 3 there; the weight table must stay bit-identical
   for ratios 0 to 2). An upscale emits two output lines from one source pair about once in
   six. The second line buffer keeps the incoming line, so the second output reads both
   buffers with no input arriving; flow control must let the output side run ahead of the
   input, which today's "one output while receiving one input" design does not. Bottom-field
   phase: at S = 5/6 a bottom-field line lands at `i·S − 1/12`, and at 10/9 `+1/18`. The sign
   matters: a negative phase is clamped to source line 0, and that clamp needs a bench arm.
2. **The display window must grow to 576.** `sync_gen` bounds the field by the stream height,
   so a 480-line stream on 576i would show 240 lines a field and black below: the 2026-11-09
   bug in reverse. `mpeg2video`'s `eff_vertical_size` already doubles the height for the SIF
   fill; it reports 576 under the upscale (432 under Letterbox is inside 480, so no change).
3. **`dvd/emu.sv`:** `std_conv_an` also engages for an NTSC disc with To PAL. `ov_pal` must
   mean "the raster is PAL" in both directions (today it can only clear). `disp_fps` 47
   (47.95 refreshes per authored second; rounded down so a still can only under-hold),
   `half_scan` for a 50 Hz field in sped-up ticks, the mixer's `v_bar`/`v_band` and
   `disp_v_offset` for 432 between bars (72).
4. **Cadence in `resample_addrgen`:** a To PAL picture always gets two fields, top first, with
   `repeat_first_field` ignored; `disp_sched` keeps the true flags as for To NTSC.
5. **Overlays:** `crt_ov_map` gets the 6/5 and 9/10 inverses (with the bottom-field phase), and
   `sub_anchor` moves 1:1 subtitles by 6/5.
6. **Drops:** the drop rate limit is raised while converting, so 6.25 drops a second don't hold
   the picture behind the sound.

**Verification:**

- Benches with `--red` arms: 6/5 and 9/10 golden blends, field and frame, both field phases;
  a `crt_syncgen_tb` phase with a 480-line stream on the 576i window (288 lines a field, no DE
  in vsync); 2:2 cadence with `rff` set on alternate pictures; the drop limit while converting.
- Rig, against a control build: the RetroTINK through the capture card for 576i/50 Hz, colour
  on composite and the MiSTer OSD; a 720×576 screenshot; 0 lates on film, 2-field pickups from
  `--telem-fast-ms`, `pic_max`; MEN_IN_BLACK (soft telecine with a 30i menu), BBB_NTSC,
  ULTIMATE_T2 (DTS), ROGER (30i) once the library share is back.
- The maintainer's look on a CRT.

**As built (2026-11-09):**

- `dvd/disp_vscale.sv` ratios 3 and 4 as planned; the clamp and the tail are replay lines too. Its
  remainder weight `(r·91 + 32) >> 6` is exact at every reachable remainder of all five ratios
  (checked offline) and equal to the old formula at `r = 3·r60`.
- `crt_ov_map` needs no tail clamp: the last 6/5 position is N − 5/6 (top) or N − 11/12 (bottom),
  whose nearest tap is already the last line. A clamp written for it never fired, and its mutation
  survived, so it was removed.
- `resample_addrgen`'s `std_cad` is two bits: [0] on, [1] 2:2 (`rff_eff` forced 0). `disp_sched`'s
  `drop_fast` gives one catch-up drop per two pickups while either flavour converts, the scaler
  path included.
- Gates: `run_vscale_frame.sh` (arms `*_r3`, `*_r4`; mutations U1-U7), `crt_ov_map_tb` T10 (R8,
  R9), `run_sub_anchor.sh` (R6-R8), `field_phase_tb +stdcad=5` (C8, C9), the wiring checker (W25-W31).

**Timing:** the first fit read clk_dec 74.9 MHz (the 6/5 line bound was a multiply in front of a
compare in front of `next_k`); with the walk's decisions registered a cycle ahead it reads
88.0 / 86.38 MHz (SEED 7, gate 86). Cold-corner margin is 0.4 MHz, down from 3: watch it.

**HW, 2026-11-09** (`.236`, Video Output = Interlaced, To PAL, RetroTINK on composite through the
capture card): `big-buck-bunny-NTSC.iso` menu and feature, `BBB_NTSC.VOB`, `MEN_IN_BLACK.iso`.
- ascal captures 720×576 with the 16:9 menu in the 9/10 band between 72-line bars; colour on
  composite (PAL burst, picked by Main from the 50 Hz rate); the MiSTer OSD shows on the analog output.
- Film: 50.0 fields/s, 25.0 pickups/s, 0 lates, 0 drops over the menu, 20 s of feature and 30 s of
  the VOB. Fast telemetry (10 ms): gaps 2/1/3 = 427/140/140 (the 1s and 3s are one sampling slip,
  symmetric), pair sums 4/3/5 = 291/208/207 and no 6: 2:2, no third field.
- MiB's 30i menu: exactly 6.23 drops/s and 12.5 lates/s on 25.0 pickups/s; the picture rides 60 to
  85 ms behind the sound against −31 ms on the native control. **`drop_fast` did not change that,
  and could not:** the steady state needs exactly 6.25 drops/s whatever the ceiling, and a drop is
  only requested past `LATE_DROP` (~50 ms), so the lag saw-tooths just above the threshold either
  way. The faster ceiling only shortens a catch-up after a jump. Lowering the threshold while
  converting is the lever if the 30–50 ms extra on 30i menus matters (not done; a film stream's
  lateness under To PAL is at most ~8 ms, so a lower threshold should not drop film).

**Risks:**

- **Decode pacing:** 31.25 decodes a second, 4 % above native NTSC. Display reads are 240 source
  lines a field, below native PAL's 288, so the display side should be lighter than a PAL disc.
- **Flow control in `disp_vscale`** is the one piece with no precedent in the tree.

## Phase 4b: field-accurate NTSC video on To PAL (agreed 2026-11-09)

**The choice.** True NTSC video sped up is 62.5 fields/s on a 50-field raster. Phase 4 dropped one
picture in five (a 32 ms jump 6.25 times a second). The smoothest result without motion estimation
shows, on every raster field, the newest source field: one field in five skipped, a 16 ms jump
12.5 times a second. The maintainer chose that, with every field equally soft rather than half of
them softened (the alternative pulses sharp and soft at about 6 Hz on still detail).

**Why "equally soft" costs nothing here.** A field skip leaves the next source field on the other
raster parity, so half the fields are drawn half a line shifted. On the To PAL path every field is
already resampled by `disp_vscale` (6/5 or 9/10), so a shifted field uses the same set of blend
fractions as a native one, in a different order: at 6/5 both are {0, 1/6, ..., 5/6}; at 9/10 the
mean softness (the mean of f(1-f)) is 0.165 against 0.168. No extra filter is needed.

**Which field.** From the picture's lateness L at pickup, in ticks of the sped-up STC (a source
field is 1501.5, an output field 1876.875): L < 1126 both fields; 1126 to 1501 the first only; 1502
and over the second only. `disp_sched` computes it (`fa_cls`) from `d_stc_want`. A free-running
counter would also give 2, 2, 1, 2, 1, but out of phase with the timeline it shows pictures early
and the scheduler holds them; lateness keeps it locked. The walk stays in [0, 1877) ticks, below
`LATE_DROP`, so no catch-up drops are requested.

**Film is never taken here.** It applies only to `progressive_frame = 0` pictures. MPEG-2 allows
`repeat_first_field` (soft telecine) only on progressive frames, so NTSC film is always flagged as
film, unlike the PAL direction (Phase 0). Hard-telecined film is interlaced on the disc and gets the
video treatment, which is no worse than dropping pictures.

**As built.**
- `resample_addrgen`: `xp_0`/`xp_1` ride the image list ("read the other parity"); the read start
  and the field's last-line test (`last_y_native`, which tested the SLOT and would never have ended
  a top field read into a bottom slot) follow the read parity; `scan_xpar` goes to `disp_vscale`.
  The slot tag is untouched, so the mixer and the parity corrector are unaffected.
- `disp_vscale`: a field of parity sp in a slot of parity op starts at i*S + (op*S - sp)/2: S/2
  (5/12, 5/9) for a top field in a bottom slot, -1/2 (clamped, then 1/3 or 11/18) for a bottom
  field in a top slot. 9/10 is now bounded too (the 5/9 start runs out one line early: tail).
- Overlays need nothing: `crt_ov_map` maps raster lines to source FRAME positions, which a shifted
  field is resampled to.
- Gates: `run_vscale_frame.sh` (`field_x3/4`, X1-X4), `field_phase_tb +stdcad=6` (reads follow
  T B T B B T B T, 1.6 fields a pickup, `scan_xpar` on the off-slot fields; F1-F4, and arm 5 now
  drives `fa_cls` so film must ignore it).
- Not changed: the scaler (HDMI) path still drops one picture in five; it shows woven frames.

**Timing.** The first fit (SEED 7) read clk_dec 85.79/83.67 MHz: the replay mux sat in front of
the blend multiply. Choosing the replay's `b` one stage earlier (`s3_b*`) moved it off that path;
SEED 7 then rolled worse on both clocks (placement), and a sweep found SEED 8: clk_dec
89.02/86.81, clk_mem 95.96/98.17 MHz (38,501 ALMs, 92 %; 523 M10K; 90 DSP).

**HW, 2026-11-10** (`.236`, `dev-stdconvert4`, Video Output = Interlaced, To PAL; RetroTINK on
composite through the capture card).
- MiB's 30i menu: 30.77 pictures/s on 50.0 fields (ideal 31.25), 1.1 lates/s and 0.49 drops/s,
  against 25.0 pictures/s, 12.5 lates/s and 6.23 drops/s on `dev-stdconvert3`. `disp_lag` sits at
  −2 to −21 ms (−60 to −85 before). The 10 ms trace shows the lateness walk as designed: lag steps
  −2.1, −10.7, −19.0, −6.4, −14.8 ms, i.e. +751 ticks after a two-field picture and −1126 after a
  one-field one, never past 19 ms.
- **The residual drops are the decoder, not the walk.** Every drop is 2 lates + 1 drop from the
  frame-drop governor (decoder starvation), each just after a ONE-field pickup, with the decoder
  pipe-stalled (`dec_back` high, `dec_disp` 0) across it. A one-field picture gives the decoder one
  field (20 ms) to have the next picture ready, where native 30i gives it 33 ms; about 1 in 25 of
  those misses. Control, same disc and build, conversion Off: 29.98 pictures/s, 0 lates, 0 drops.
  Not chased further (the fix would be letting the decoder run a picture further ahead, an
  architectural change); the walk itself never asks for a drop.
- Film unchanged: BBB_NTSC.VOB 50.0 fields/s, 25.0 pictures/s, 0 lates, 0 drops.
- 576i at 50 Hz, colour, and the MiSTer OSD over the picture on composite (RetroTINK capture).
- ⏳ By eye on a CRT: the field-skip motion and the even softness.

## Not done yet

- Phase 3 step 1 is wired (2026-11-08): `std_conv_an` (PAL→NTSC with `interlaced_eff | analog_want`)
  runs the plain NTSC raster with `disp_vscale` at 5/6 or 5/8; `ov_pal` puts the HUD, seek bar,
  idle logo, active window, line-21 captions and composite sync on the raster. Dialogue subtitles
  are 1:1 and moved by `dvd/sub_anchor.sv` (maintainer's choice, 2026-11-08), anchored at the
  scaled position of their box's top but never off the bottom.
- Phase 3 step 2 (2026-11-09): `resample_addrgen`'s `std_cad` gives a `progressive_frame=1`
  picture on the field raster 3, 2, 3, 2 fields per pickup (`cad_rff`), and starts each one on
  the field opposite the last displayed (`last_image`), so the corrector's feed-forward arm has
  nothing to fix and no phase can drift across a pause, seek or insertion. **Refuted on the way:**
  the plan's 1440-tick field period for `disp_sched`. The scheduler keeps the TRUE flags and so
  every picture's true 3600-tick period; a 3-field sequence (4320) just ends 720 ticks after the
  next picture is due and the 2-field one lands back on time, so 3:2 falls out of the pickup
  timing. Overriding the period would have made a `progressive_frame=0` picture's extrapolated
  duration 2880 against its real 3600.
- Phase 3 step 3 (2026-11-09): **every picture is film.** Conversion is a manual OSD choice, so
  the maintainer chose (2026-11-09) to treat every picture as film rather than build a motion
  detector, which would only be worth it if conversion were automatic. `cad_on` no longer looks
  at `progressive_frame`, and the interlaced-frame branch of the image build takes the same
  `tff_eff` and, under `cad_on` only, the third field. Phase 0 is why this is the right default:
  most moving `pf=0` windows on PAL discs measured film-like. **Accepted cost:** a true 50i
  picture's third field repeats its FIRST field, which is a one-field step back in time, so
  motion in true video (logos, sport, concerts) judders at 480i. 480p is unaffected. The disc's
  own `repeat_first_field` on an interlaced frame is still ignored when not converting, exactly
  as before. Gate: `field_phase_tb +stdcad` (data-derived parity, distinct lines, pickup gaps
  alternating 3/2 on arms 1, 3 and 4, all-2 on control 2) with seven mutations: C1 no
  alternation, C2 the stream's `tff`, C3 film-only `cad_on` (the old rule), C4 no third field
  on an interlaced frame, C5-C7 the `progressive_sequence` terms below.
- **HW, 2026-11-09** (rig, Video Output = Interlaced, To NTSC, v0.10.0 control first; the share
  was down, so the SD card's own samples): `VTS_04_2.VOB` (PAL film flagged `pf=0`) and
  `BBB_PAL.VOB` (`progressive_sequence=1`). Raster 59.944 Hz, 23.965 pictures/s, audio
  46,033 Hz (= 48,000 × 960/1001), 2.501 fields per picture, 0 lates, 0 drops, longest picture
  22.5 ms against 41.7 (control 21.7 against 40); Off matched the control. The cadence itself
  came from 10 ms fast telemetry (`launch --telem-fast-ms 10`): the field count at each pickup,
  scored as sums of two consecutive gaps because a 10 ms sample moves one field between
  neighbours. `VTS_04_2`: sums 4/5/6 = 76/367/75, i.e. 3:2. **`BBB_PAL`: 130/138/136 with tails
  at 3 and 7, i.e. 2-2-2-4.** `cad_on` excluded `progressive_sequence`, and the published Big
  Buck Bunny PAL DVD is coded `progressive_sequence=1` (out of DVD-Video spec, real all the same).
  Fixed: `cad_on` drops the term, and under it a ps=1 picture skips the always-TOP-first
  progressive-sequence branch (and `nxt_first_top`'s matching rule) for the `progressive_frame`
  one, which ps=1 implies. Bench arm `+stdcad=4`, mutations C5 (term back), C6 (branch not
  gated), C7 (`nxt_first_top` not gated). Rig re-check on the rebuilt core (`86c56fe`, SEED 7):
  `BBB_PAL` pair sums 4/5/6 = 60/394/61 (was 130/138/136), `VTS_04_2` 84/351/82, 0 lates, 0 drops.
- **First look on a CRT, 2026-11-09 (maintainer, The Incredible Hulk PAL, 480i): broken.** HDMI
  reported `290x519i` with a skewed picture, the CRT kept its geometry but lost colour on S-Video
  and composite (RGBS through a RetroTINK had colour), and the MiSTer OSD showed on HDMI but not
  on the analog output. One cause: `sync_gen` bounds an interlaced field's active window by
  `vertical_size/2` and by `vertical_resolution` **unhalved**, and the walk writes the frame
  count (480) for 480i. Every native mode is bounded by the stream (240 = 240, 288 = 288), so the
  unhalved compare never mattered; a 576-line stream on the 262-line NTSC field gives 288 > 262,
  and DE never fell: it ran through vblank and vsync. That breaks ascal's measurement (519 DE
  lines a frame), Main's Y/C burst setup and burst placement (no colour on Y/C), and the analog
  OSD. RGB has no burst, hence its colour. 480p was never affected (its compare is not halved),
  and the telemetry runs above measured rates and cadence, not the picture: **nothing looked at
  the 480i output until the maintainer did.** Fixed in `rtl/mpeg2/syncgen.v`: the interlaced bound
  is `vertical_resolution` halved, rounded up (a legacy 479 still gives 240), identical wherever
  the stream fits. The same fault would have hit `Video Standard = NTSC` forced on a PAL disc at
  480i. Gate: `crt_syncgen_tb` PHASE 8 (576-line stream on the shipped 480i raster: 240 lines a
  field, no DE inside vsync), mutation R2 in `run_p240.sh --red`.
- ⏳ **Next step:** by eye on a CRT: a PAL film, a filmised drama, and a sport or concert 50i
  disc to judge the accepted judder (library share needed).
- ⏳ `tools/hil_suite.py` with conversion Off against v0.10.0 has not run; Off matched the control on
  rates only.
- A field-accurate "video" cadence (pair re-scan for true 50i) would need a per-picture classifier
  or a second OSD choice. Only if the CRT test shows the 50i judder matters.
- The census scripts are still scratch files. Add them to `tools/` before this note's numbers are
  relied on elsewhere.
