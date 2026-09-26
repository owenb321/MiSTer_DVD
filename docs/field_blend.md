# Field blend: a non-adaptive deinterlacer for the Progressive output

**Status:** ✅ HW-CONFIRMED 2026-09-24, branch `feature/field-blend`. Sim-proven, mutation-checked,
and built: `DVD_fieldblend_20260924_1713.rbf`, SEED 9 first roll, clk_dec 91.64 / 89.16
MHz against the 86.0 gate, `field_blend` = 254 ALM, 6 M10K, 0 DSP. ✅ HW-measured on the
rig 2026-09-24 (§5) and ✅ confirmed by the maintainer's eye the same day.
**Option:** was `O[49] Progressive Deint = Off / Blend`, default Off. **Since 2026-09-25 it
is `Deinterlace = Blend`** on the merged `O[51:50] Deinterlace = Weave / Bob / Blend`
(default Weave = the old Off), which also carries a progressive **Bob** built on this
module — see §6 and §7.
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

**Wiring (`tools/check_field_blend_wiring.py`).** (As first shipped; §6 lists what it
pins since the Deinterlace merge.) It checks:
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

## 5. Status and verification record

- ✅ **Build (2026-09-24):** `releases/DVD_fieldblend_20260924_1713.rbf`, SEED 9 first
  roll, clk_dec 91.64 @100C / 89.16 @−40C, non-marginal. `field_blend` = 254 ALM,
  377 registers, 6 M10K (`dbuf` 4 + `nbuf` 1 + the input FIFO), 0 DSP.
  - The headline "ALMs needed" reads 98 % against v0.7.0's 93 %. That is the fitter's
    packing estimate swinging, not 1,862 ALMs of growth (ledger entry in `DVD.qsf`).
  - The Main (telemetry `flags.blend`) cross-compiles under `USE_DOCKER=1
    main/build_main.sh`.
- ✅ **HW round measured on the rig (2026-09-24, harness, `DVD_fieldblend_20260924_1713.rbf`
  + the matching Main).** Each claim below was checked against a control that could fail:
  | check | result |
  |---|---|
  | Thayer VTS_01, one paused picture: Off vs Blend | comb ratio **1.751 → 0.588**, 83 % of pixels changed |
  | Same picture, Blend, two shots 3 s apart (no shimmer) | **0 px differ** |
  | MEN_IN_BLACK (film, `pf=1`), paused: Off vs Blend | `flags.blend=0`, **0 px differ** |
  | ROGER_WATERS (NTSC video): engagement | `flags.blend=1` |
  | ROGER_WATERS pacing, interleaved 25 s windows | lates 9.78 vs 9.76/s on the same scene (Blend vs Off); `vid_err` 0 |
  | INTERSTELLA 5555 (PAL 576) | `flags.blend=1`, geometry 720x576 intact |
  | Blend selected, `Video Output = Interlaced` | `flags.blend=0`; back on in Progressive |
  | Thayer: paused frame steps | each step a new picture (96–98 % change), all blended (comb 0.54) |
  | Thayer: seek fwd/back, then playing | picture advancing, blended (comb 0.56), `blend=1` |
  ★ The 0-px film diff is not vacuous: the same procedure on Thayer changes 83 % of pixels.
  ⚠ Not exercised: 240p (only MPEG-1 SIF uses it, and MPEG-1 is `progressive_sequence`,
  so `cur_ilace` is 0 there anyway; the gate is pinned by the wiring checker), and a
  film↔video transition inside one title (bench C6 covers the ordering).
- ✅ **The maintainer's eye (2026-09-24):** Thayer's Quest looks good with Blend, and a
  title that changes from film to video mid-stream switches the blend correctly — the
  in-title film↔video case the harness round did not reach (bench C6 covered the ordering).
  That closes the one judgement no metric here can make (the comb ratio is blind to the
  ghost).
- **Known limits:**
  - hard-telecine film (`pf=0`) is blended, which the census could not size;
  - a menu still flagged interlaced is softened;
  - the blend applies to the whole picture, not only where it combs (by design, §1).

## 6. One option: `Deinterlace = Weave / Bob / Blend` (2026-09-25, branch `feature/deint-merge`)

✅ **Sim-proven, mutation-checked, built and HW-CONFIRMED 2026-09-26 (§7).** Build
`releases/DVD_deintmerge_20260926_0049.rbf`: SEED 9 first roll, clk_dec 88.92 @100C / 89.88
@−40C (gate 86.0), not marginal, 98 % ALM. `field_blend` = 261 ALM (254 before Bob, so the
second kernel cost 7 ALM), 6 M10K, 0 DSP. The matching Main cross-compiles
(`USE_DOCKER=1 main/build_main.sh`).
**Rebased onto PR #129 (`.cue` sheets) and rebuilt:** `releases/DVD_deintmerge_20260926_0154.rbf`,
SEED 9 first roll, clk_dec 90.95 @100C / 89.09 @−40C, 98 % ALM, from a clean tree at
`2a79dd7`. The rebase changed only the file-picker list and `` `CORE_VERSION ``, so the
HW round above (run on the pre-rebase build) stands. `run_field_blend.sh --red` is green
again, 53 arms; the Main rebuilds too.

Two options used to cover one question, one per raster:
- `OB 480i Deint = Bob / Weave` (bit 11) chose ascal's deinterlace for HDMI while the
  Interlaced raster was up (`HDMI_BOB_DEINT`);
- `O[49] Progressive Deint = Off / Blend` was this module.

They are now **one** field, `O[51:50] Deinterlace`: **0 = Weave (default), 1 = Bob,
2 = Blend**. "Off" was dropped (user decision) because it is identical to Weave on both
rasters: Progressive Off already showed the woven frame, and ascal's non-bob mode is a
weave.

**Two rows on one bit field, swapped by the menu mask.**
- `H0O[51:50],Deinterlace,Weave,Bob,Blend` is hidden while mask bit 0 is set;
  `h0O[51:50],Deinterlace,Weave,Bob` is hidden while it is clear.
- Mask bit 0 = `interlaced_eff`, on `hps_io.status_menumask` (connected for the first
  time; the port and command 0x2E were always there).
- Main reads the mask on every menu draw (`menu.cpp`, `UIO_GET_OSDMASK`), so the rows
  swap live when Video Output changes.
- Syntax, from `menu.cpp`: `H`/`D` hide/disable on a SET bit and `h`/`d` on a CLEAR one.
  The mask index is one base-32 character. The prefixes stack and come BEFORE the page
  prefix (`H1P1O...`).
- The Interlaced row lists no Blend. Main renders an out-of-range value as index 0
  without writing it back (`menu.cpp`, "option's index is outside of available values"),
  so a saved Blend **shows as Weave there, and the core weaves**: `HDMI_BOB_DEINT` is
  `(deint_mode == 1)`, not `!= 0`. Back on Progressive the saved 2 is Blend again.

**Why Weave is index 0** (user decision). The Progressive default stays the measured one
(§2: `pf=0` over-selects, so any filter by default softens ~half of the discs it
engages). The cost is that HDMI on the Interlaced raster moves from Bob to Weave by
default. The manual says so in a note.

**Why new bits, not a relayout.** Bits 50/51 had never been allocated, so no `"v,N"` bump
and no mass settings reset; only these two options' choices reset, once. Bits 11 and 49
are left reserved and are read by NOTHING (the wiring checker pins that), so a stale
saved value cannot re-arm anything.

**What the tools had to learn.**
- `tools/docs_check.py` (`parse()` and `parse_bits()`) matched only rows beginning `P`/`O`.
  A mask-prefixed row was SILENTLY skipped: not checked against the manual, and not
  settable by `tools/mister.py`. `MASK_PREFIX` fixes that.
- `parse_bits()` MERGES rows with one label and one bit field, keeping the longer value
  list. That is only sound when the shorter list is a prefix of the longer one, and a
  pair that disagrees raises (`tools/tests/test_status_bits.py`).

## 7. Bob on the Progressive raster

`Deinterlace = Bob` on Progressive is field_blend's **second kernel**. It keeps ONE field of
the woven frame (the top field is the even lines) and rebuilds each line of the other as
the average of the kept lines above and below:

    kept line  (y % 2 == keep_bot):  out = b
    other line                   :  out = (a + d + 1) >> 1

This is an interpolating bob, the user's choice over line repeat. It needs no new memory:
the `dbuf`/`nbuf` line delays already hold `a` and `b`. The edges fall out of the existing
mirroring:
- top: `a := d`, so keeping the bottom field, line 0 = line 1;
- bottom: the addrgen's (H+1)th line is H-2, so keeping the top field with H even, line
  H-1 = line H-2.

**Gate: the same as Blend's** (`filt_ok` in `resample_addrgen.v`). That is `cur_ilace`, the
weave arm, a FRAME image, and no SIF walk or Letterbox. So film and `pf=1` pictures are
never touched. emu adds `~filmp_eff`, because the Film 24p/25p raster scans a picture
about once and a bob there would drop a field; a true-interlaced picture on that raster
stays woven (Blend still engages there).

**Which field, and why it is not Stage A.** The kept field is picked per scan by the
addrgen:
- the pickup scan (`STATE_INIT`) keeps the picture's **first** field (`cur_tff`, latched
  at the pickup like `cur_ilace`);
- **every** later re-scan (`STATE_REPEAT`) keeps the **second**.

MPEG-2 forbids `rff` on a `pf=0` picture, so on cadence a bob picture gets exactly two
refreshes: first field, then second, a true 59.94/50 Hz bob.

A pause, a late re-scan, or a held still keeps showing the second field,
**byte-identical on every re-scan**. That is the point, and the lesson from Stage A:
- Stage A alternated its anchor on every refresh of a held picture, which is a 30 Hz
  flip on anything held.
- Here the only alternation is the one the content itself has (two fields, two refreshes).
- Mutation MB4 (alternate on every re-scan) is caught by C5.

Bob still has its native character: during playback, fine static horizontal edges
twitter by half a line, exactly as ascal's bob does on 480i. It is opt-in.

**Scans stay FRAME images**, so the governor's pair ledger (`late_pair`/`late_ext`) is
untouched: a bob scan is a woven-frame scan whose lines are rebuilt downstream.

**Sideband.** `scan_blend` now means "a filtered scan, H+1 lines in, either kernel".
Beside it, `scan_bob` selects the kernel and `scan_bob_bot` the kept field. The 4-deep
queue entries grew from 1 bit to 3, and the input FIFO word from 36 bits to 38.

**Telemetry.** `bob_act` goes to word 14 bit 8 as `flags.bob` in `/tmp/dvd_telem.json`.
Word 7's eight flag bits are all taken.

**Gates.**
- `bench/dvd/run_field_blend.sh --red`:
  - module arms `+bob=1|2` are bit-exact against `tools/field_blend_model.py`'s
    `bob_keep()` for both kept fields, with backpressure and on the real Thayer frame;
  - chain `+bob=1` covers pickup scans keeping the first field [C9], held re-scans
    keeping the second and identical [C1 C5], film [C4], the fields arm [C8], `+tff=0`,
    a paused step, a film switch, and vacuity [C10].

  | mutation | caught by |
  |---|---|
  | MB1 no +1 rounding | K1 |
  | MB2 wrong line parity | K1 |
  | MB3 kept field inverted | C1 C1B C1T C9 |
  | MB4 alternates per re-scan | C1 C1B C1T C5 |
  | MB5 `tff` ignored (+tff=0) | C1 C1B C1T C9 |
  | MB6 `cur_ilace` gate removed (+pfr=1) | C4 |

  The wiring REDs grew to W0–W11: menumask inverted or unwired, a Blend label on the
  Interlaced row, HDMI still reading bit 11, bob without `~interlaced_eff`, bob without
  `~filmp_eff`.
- `tools/check_field_blend_wiring.py` pins everything in §6/§7 (rows, mask, `deint_mode`,
  both gates, `HDMI_BOB_DEINT`, retired bits unread, CDCs, instruments, one sideband).

⚠ **Three harness traps found writing this, worth keeping:**
- **The wiring checker CRASHED on two RED arms** (a `%` format error), and `wred` read the
  non-zero exit as RED. It now demands the named `check_field_blend_wiring: FAIL` line.
- **`$value$plusargs` takes the FIRST match.** `mod_args` used to bake in the blend
  `+exp`, so a bob arm appending its own `+exp` was silently scored against the blend
  expectation. There is now exactly one `+exp` per arm.
- **This shell is zsh, which does not word-split `$a`.** A loop over "`+bob=1 +exp=...`"
  handed vvp ONE argument and every arm read X. Drive such loops through `bash -c`.

**✅ HW-MEASURED on the rig (2026-09-26, harness).** Build `DVD_deintmerge_20260926_0049.rbf`
plus a Main built from this branch merged with `main` (PR #129), so the cue work rides along.

| check | result |
|---|---|
| Thayer VTS_01 at 0:00:00, one paused picture: the 40 most-combed 16x16 blocks in Weave | comb **1.05 (Weave) → 0.31 (Bob) → 0.18 (Blend)** |
| Same held picture, two shots per mode | **0 px differ** in Weave, Bob and Blend; Weave identical before and after the tour |
| Bob kernel, on the silicon | kept rows = the odd (bottom) field, **max \|Bob − Weave\| = 0**, the second field of a held `tff=1` picture as designed; rebuilt rows vs the average of their neighbours: mean 0.9, p99 7.5 (YUV-domain average vs RGB) |
| Engagement, live `osd` changes on Progressive | `flags.bob` = 1 only on Bob, `flags.blend` = 1 only on Blend |
| MEN_IN_BLACK (film, `pf=1`), paused: Weave vs Bob | `flags.bob = 0`, **0 px differ** on a non-black picture |
| Pacing, Thayer, interleaved 15 s windows | lates 7.38 / 7.71 / 7.32 / 7.44 per s (W/B/W/B), `vid_err` 0, 59.95 Hz |
| `Video Output = Interlaced`, each setting | `blend = 0`, `bob = 0` (the fabric filters stay off) |
| `Film 24p Out = On` (23.96 Hz raster) | Bob: `bob = 0`; Blend: `blend = 1` |

⚠ Harness lessons from this round:
- **A pause pressed straight after a launch is dropped.** It lands before playback is
  live, and every later shot is then of a PLAYING picture: all modes "differed" by ~287,000
  px. Check `flags.pause` and a frozen `pickups` before reading any held-picture result.
- `pickups` is cumulative across an MGL relaunch of the same core until the core reset
  lands, so wait for `refreshes` to drop before counting a new launch's pictures.
- The HDMI side of Interlaced (ascal's bob) cannot be captured: screenshots are ascal's
  input, and the capture card was held by another process.

**✅ HW-CONFIRMED by the maintainer's eye (2026-09-26)** on the three checks the harness
cannot make:
- the OSD row shows 3 values on Progressive and 2 on Interlaced, and swaps live;
- HDMI on Interlaced follows Bob/Weave;
- Bob motion on true-interlaced video looks right.
- Thayer's Quest on Progressive + Bob: comb ≈ 0 while playing, and a paused picture 0 px
  different between shots;
- a film disc: 0 px Bob vs Weave, `flags.bob = 0`;
- Blend unregressed;
- Interlaced: HDMI follows Bob/Weave, and the CRT is unaffected;
- the OSD row shows 3 values on Progressive and 2 on Interlaced, and swaps live (the
  maintainer's eye; screenshots do not carry the OSD);
- Bob motion judged by eye.
