# Field blend: a non-adaptive deinterlacer for the Progressive output

**Status:** 🔧 branch `feature/field-blend` (2026-09-24). Sim-proven, mutation-checked,
and built: `DVD_fieldblend_20260924_1713.rbf`, SEED 9 first roll, clk_dec 91.64 / 89.16
MHz against the 86.0 gate, `field_blend` = 254 ALM, 6 M10K, 0 DSP. ⏳ HW round and
maintainer's eye pending.
**Option:** `O[49] Progressive Deint = Off / Blend`, **default Off**.
**Files:** `dvd/field_blend.sv`, `dvd/resample_addrgen.v` (sideband and H+1 walk),
`rtl/mpeg2/resample.v` and `rtl/mpeg2/mpeg2video.v` (threading and instance), `dvd/emu.sv`
(option, gate, CDC, telemetry), `main/support/dvd/dvd_ctl.cpp` (`flags.blend`).
**Gates:** `bench/dvd/run_field_blend.sh --red`, `tools/check_field_blend_wiring.py`,
`tools/field_blend_model.py`.

## 1. Why this reopens deinterlacing, and why it is not Stage A again

`docs/hw_budget_and_lessons.md` §0 records the 2026-09-21 decision to stop deinterlacing
work. The shelved "Stage A" (`feature/deinterlace`, local only) was rejected for **edge
shimmer**. This feature exists because the mechanism of that shimmer is now understood,
and it can be removed without removing the benefit.

**Stage A's kernel was bob with an alternating anchor.**
- It kept one field ("the anchor") and rebuilt the other's combed pixels as
  `avg(y-1, y+1)`, with a per-pixel comb detector deciding which pixels.
- Round 2 flipped the anchor on the picture's first re-scan to recover 60 Hz motion.

A falsely flagged static edge was therefore native on one refresh and rebuilt on the next:
a sharp/soft flip at 30 Hz. The detector's threshold is what put static edges into that
set.

**This feature has no detector, no anchor and no per-refresh state.** Every line of a
marked picture is filtered, on every scan:

    out[y] = (a + 2b + d + 2) >> 2      a = y-1, b = y, d = y+1   (per channel, Y/U/V)

A held picture is therefore byte-identical on every re-scan, so it cannot shimmer. Bench
arm **C5** measures exactly that, against the previous scan rather than against a model,
and mutation **MC7** (a one-LSB flip per scan) proves the arm can fail.

**The trade is sharpness, not shimmer.** For an interior line, `a` and `d` come from the
other field, so each output line is exactly half of each field:
- comb becomes a soft ghost on motion;
- the kernel's response is zero at the vertical Nyquist frequency, so vertical detail is
  lost on still regions too.

## 2. Gate: what engages it

The gate is `blend_want = blend_en && deinterlace && ~interlaced && cur_ilace && ~vscale_en
&& ~sif2x` (in `resample_addrgen.v`), and the scan must be a `FRAME` image.

- **`cur_ilace`** is latched at the real pickup as `~progressive_frame &&
  ~progressive_sequence`. It is a bitstream-exact per-picture fact, so there is no
  threshold to dither over. Film (soft-telecine, `pf=1`) is bit-identical to Off, and
  bench arm C4 plus mutation MC3 pin that.
- **`blend_en = status[49] & ~interlaced_eff`** in `emu.sv`.
  - ⚠ The gate is **not `~fields_eff`**, which is what Stage A used. 240p is a sub-mode of
    the interlaced raster whose decoder emits FRAMES, so a `fields_eff` gate would blend
    on 240p.
  - `tools/check_field_blend_wiring.py` rejects `fields_eff`, `il_eff` and `p240_eff`.
- **`deinterlace && ~interlaced` is defence in depth.** On the fields arm every image is
  TOP/BOTTOM, so `image_0 == FRAME` already excludes it. No mutation of that term can be
  caught, so none is claimed; bench arm C8 is the structural confirmation.
- **Film 24p Out = On** over true-interlaced content does engage it. That raster is
  progressive and shows woven frames, so blending is the right outcome.

### The default is Off, because `progressive_frame = 0` over-selects

This was measured before any RTL was written (`tools/field_blend_model.py score`,
`video_cadence_census.py --per-window`).

**NTSC soft-telecine film is safe.**
- The 899 FILM discs in the 1,311-disc census are `pf=1` in every sampled window, so they
  never engage.
- ⚠ The census JSON's `pic_progressive_pct` field is **unreliable**: it reads about half
  the live value on many film discs (Coraline 47 % vs 100 % live, rff halved too). Use the
  `cadence_verdict` field or a live `--per-window` run.

**About 30 % of the library engages:** 319 NTSC VIDEO discs, 78 MIXED, and 5 of the 7 PAL
discs.

**Many of those never comb.** Their weave comb ratio stays about 0.6 in every sampled frame:
- Cowboy Bebop, The Office UK and Superman (PAL);
- 11 of 24 randomly sampled NTSC "VIDEO" discs, including Lucy Show, Always Sunny,
  Civil War and Black Stallion.

Some of these are progressive content with interlaced flags, and some are simply
low-motion video. The flag cannot tell them apart, and on these discs the blend only
softens.

**Where combing is real, it goes.** On Thayer VTS_01, JAMES_BOND, GIRL_NEXT_DOOR and
US_MARSHALS, the weave comb ratio of 1.1–2.1 drops to about 0.53.

**What it costs**, measured on temporally static pixels, where the woven frame is the
truth:
- MAE 0.1–1.5 code values;
- **vertical detail retained 43–90 %**.

So the maintainer chose **default Off** (2026-09-24). It is an opt-in for people watching
video-sourced discs on HDMI who prefer a soft ghost to comb.

⛔ **Not done: a coarser "does this picture actually comb" gate.** Any statistic with a
threshold reintroduces a decision that can flip picture to picture, which is exactly the
soft/sharp toggling this design exists to avoid. It was offered and declined.

## 3. Datapath

```
resample (addrgen + dta + bilinear) -> field_blend -> disp_vscale -> disp_hstretch -> pixel_queue
```

`field_blend` runs in the clk_dec domain. It is built from Stage A's `deint_comb.sv`
skeleton at `feature/deinterlace@a017ec4`.

**Kept from Stage A:**
- the input `fifo_sc` + `fwft_reader`;
- two M10K line delays written one column behind their read (`dbuf` 1024×32 is line y,
  `nbuf` 1024×24 is line y-1, and the live input is line y+1);
- the fabric re-register of the M10K outputs;
- the FRAME-scan row-code handling;
- PLAIN routing;
- the combinational bypass while idle.

**Dropped:**
- `deint_detect.sv`;
- the dilation stage;
- `mix8`, which was a 4-DSP multiply;
- the comb-density counter;
- all anchor state (in the module and in the addrgen).

**What's left:** the kernel is three adders into a 10-bit sum on stage-2 registers, and the
enable is applied at the output register (hw_budget §5), so it uses **0 DSP**.

**Sideband.** One bit per frame-top scan is pushed at `scan_start`, popped per frame-top
pixel, and stamped on every pixel of the scan in the FIFO word. The queue is 4 deep, the
same as `disp_vscale`'s pause-still sideband.

**H+1 lines and the edges.** The stream has no end-of-scan marker, so output line y goes
out while input line y+1 arrives. A marked scan therefore comes out of the addrgen as H+1
lines.

- ★ The extra line is **line H-2**: after the last frame line the addrgen steps `disp_y`
  **back** one. That makes the bottom `d := a` (a mirror). The module selects `a := d` at
  the top, so both edges keep the interior's 50/50 field balance.
- Stage A repeated line H-1, which is a replicate (75/25). Mutation MC2 reintroduces
  that and fails exactly C1B.

**Row codes.** A FRAME scan carries `ROW_0_COL_0` on line 0 and `ROW_1_COL_0` on line 1.
The second is not a frame top (`in_prev_row0` / `h_prev_row0`), and line 1 must be
re-emitted as `ROW_1_COL_0`, because the mixer places a FRAME's line 1 by it. Mutations
MC5 and MK6 cover these.

**OSD is never blended**, because it is a palette index. Overlays (subpictures, HUD,
highlights, logo) are composited after yuv2rgb in `emu.sv` and are unaffected.

## 4. Verification

`bench/dvd/run_field_blend.sh --red` runs everything below. It scores with `!==`
throughout, requires **exactly** the designed failing arms per mutation, and checks every
sed actually applied (cmp).

**`field_blend_tb` (module).** Bit-exact against `tools/field_blend_model.py`.
- Fixtures: a synthetic frame (pseudo-random with a saturating band, and OSD varying by
  line so an OSD-blend mutation is visible) and a real Thayer's Quest VTS_01 frame
  (re-cut from `$FBLEND_ISO` / `$DVD_ISO_DIR` every run).
- Both run with `+stall`, plus `+plain` for the bypass.
- Arms: K1 values, K2 counts, K3 codes, K4 `blend_act`.

**`field_blend_chain_tb` (real chain).** The real display chain on a progressive raster,
over a framestore stamped by (line, macroblock). The stamp is **non-linear in y**, because
on a linear ramp `[1,2,1]` and bob both return the centre value and the bob mutation
would be invisible.

| Arm | Checks |
|---|---|
| C1 / C1T / C1B | the kernel on interior, top and bottom lines |
| C2 | structure: H lines of LINE_PX, slot 0 |
| C3 | `ROW_1_COL_0` on line 1 |
| C4 | film control is the weave, exactly |
| C5 | a held picture's consecutive scans are identical |
| C6 | order across a blend→film switch |
| C7 | a paused frame step is blended |
| C8 | the fields arm is never marked |

Luma only; the module bench covers chroma bit-exactly.

**RED and mutations.**
- **Weave:** RED-K fails K1, and RED-C fails C1 C1B C1T.
- **Module (MK):** MK1–5 each fail K1 (bob, no +2, 9-bit sum, top replicate, OSD blended),
  and MK6 fails K3 (line-1 code).
- **Chain (MC):**

  | Mutation | Fails |
  |---|---|
  | MC1: no H+1 line | C2 |
  | MC2: H-1 replicate | C1B |
  | MC3: `cur_ilace` gate removed | C4 |
  | MC4: PLAIN routing dropped | C2 |
  | MC5: `in_prev_row0` removed | C1 C1B C1T C2 C3 |
  | MC7: per-scan toggle | C1 C1B C1T C5 |

⚠ **Measured surviving, and deliberately NOT gated:**
- `p2_valid` in the idle term: `r_wr` follows it a cycle later and the idle counter holds
  7 cycles.
- The addrgen's `deinterlace && ~interlaced` term (§2).

Both are defence in depth, and no bench can fail on their removal.

**Wiring (`tools/check_field_blend_wiring.py`).** It checks:
- the CONF_STR row, including that **Off is index 0**;
- the gate polarity;
- the `~interlaced_eff` term, with `fields_eff`/`il_eff`/`p240_eff` rejected;
- the 2-FF CDC;
- the instrument;
- that resample → field_blend → disp_vscale is one sideband and not a bypass.

It is RED on the real pre-feature files out of git (W0) and on 5 single-seam regressions
(W1–W5).

**Unchanged suites re-run green:** `run_pause_still`, `run_field_parity`,
`run_film_evidence`, `run_stc_freerun`, `run_frame_step`, `run_prefetch_chain`,
`run_field_phase`, plus `tools/lint_undriven.sh` and `tools/docs_check.py`. Eight benches
that instantiate the addrgen or `resample` gained a `.blend_en(1'b0)` tie-off.

## 5. Open, and the next step

- ✅ **Build (2026-09-24):** `releases/DVD_fieldblend_20260924_1713.rbf`, SEED 9 first
  roll, clk_dec 91.64 @100C / 89.16 @−40C, non-marginal. `field_blend` = 254 ALM,
  377 registers, 6 M10K (`dbuf` 4 + `nbuf` 1 + the input FIFO), 0 DSP.
  - The headline "ALMs needed" reads 98 % against v0.7.0's 93 %. That is the fitter's
    packing estimate swinging, not 1,862 ALMs of growth (ledger entry in `DVD.qsf`).
  - The Main (telemetry `flags.blend`) cross-compiles under `USE_DOCKER=1
    main/build_main.sh`.
- ⏳ **HW round**, control arm first:
  - `flags.blend` = 1 on Thayer VTS_01 / ROGER_WATERS / a PAL video disc, and 0 on film,
    on `Video Output = Interlaced` and on 240p;
  - film paused On vs Off → 0 px diff;
  - Thayer paused, two shots → 0 px;
  - chapter skips across a film↔video transition;
  - the maintainer's eye on static text and on the motion ghost.
- **Known limits:**
  - hard-telecine film (`pf=0`) is blended, which the census could not size;
  - a menu still flagged interlaced is softened;
  - the blend applies to the whole picture, not only where it combs (by design, §1).
