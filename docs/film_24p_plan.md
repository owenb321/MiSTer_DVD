# Film 24p Out — implementation handoff (issue fj#124)

> **Status:** ✅ **Phase 0 + Phase 1 SHIPPED + HW-CONFIRMED (2026-07-25, PR #TBD).** The
> `P1O[24],Film 24p Out` manual toggle works on real hardware: NTSC film plays at correct
> speed, in sync, and **the ~1 s cadence pulse is GONE** (user-confirmed on the T2 tilt).
> The core outputs a 23.976 Hz progressive raster (**875 × 1287 — see §10; v1 shipped
> 858 × 1313, which was 0.038 % slow and caused a slow A/V drift**) and ascal does the 3:2 to
> 59.94 Hz HDMI; the governor advances one frame per refresh (`SHOW_N=1`) and av_sync ticks
> the STC at 23.976 Hz. **v1 = manual toggle.** **Phase 2 (automatic `Off/On/Auto` detection
> + PAL 25p) is ✅ HW-CONFIRMED (2026-07-25, PR fj#126) — see §9 below.**
>
> **★ THE 24p A/V-DRIFT SAGA (2026-08-02/03) — ✅ CLOSED, HW-CONFIRMED (PR fj#158): three
> stacked bugs, all fixed.** §10 exact raster (was 23.96689 Hz — real but not the driver),
> §11 frame-drop ledger leak (drop_cost blind to film24 — removed ~0.7 s/hour), §12
> cadence-slip corrector (imperfect telecine cadence vs the flat-1-refresh display — the
> dominant term, predicted from the disc's own rff flags to 1 % of the measured drift).
> HW verdict on the §12 build: **45-minute clip, A/V locked, no drift** (the same
> title/span previously measured +884 ms). Read §10-§12 before touching 24p timing.
>
> **Fit note:** this ~86–90% ALM design is a seed lottery — the film24 logic reshuffled
> placement so SEED 9 no longer works for this netlist (overlay build routed but came out
> HW-green = broken framebuffer writes; release build wouldn't route). **Shipped on SEED 13**
> (release/no-overlay netlist, clk_dec 84.21 @100C / 88.03 @-40C). DEBUG_OVERLAY is OFF in the
> ship build (re-add + re-sweep for the numeric row-11 lates readout).
>
> **Phase 2 status (2026-07-25, branch `feature/film-24p-auto`, PR fj#126):** ✅ **HW-CONFIRMED.**
> Automatic frame-rate switching works on real hardware — Auto engages 24p on NTSC film
> (menus ON and OFF, after the menu-path confidence-accumulator fix), and does not engage on
> non-film content. PAL 25p confirmed in sync (the earlier "PAL out of sync" was a capture-
> setup artifact, not a bug). Toggle is `P1O[25:24],Film 24p Out,Auto,Off,On` — **Auto is now
> the power-on default** (enum reordered so index 0 = Auto; the detector is HW-confirmed clean,
> so the "flip to Auto-default in a follow-up" note below is DONE). Off/On remain for override.
> **Bonus HW finding:** in 24p mode the high-motion audio stutter is gone **even with Frame
> Drop OFF** — the 60/s→~24/s framebuffer-re-read cut relieves the motion-comp starvation that
> caused the deadline misses in the first place, so there is nothing left to drop (keep Frame
> Drop On as a safety net for pathological scenes). See §9 for the design.
>
> This doc is a self-contained work order for a cold session. Full investigation history is
> on Forgejo **issue fj#124** and memory `hdmi-progressive-film-cadence-judder`.

## 1. What we're building and why

**Problem (issue fj#124):** film on the **progressive HDMI** output has a ~1 s "pulsing" —
motion ramps up and down instead of a clean 3:2 cadence. It is NOT judder-sensitivity: HW
measurement (via a DEBUG_OVERLAY build) showed the decoder misses **4 frame deadlines/s +
2 B-drops/s** on high-motion film (the T2 tilt scene), which breaks the 3:2 into an irregular
`3:3:2:3:2:4:3:2…`. Interlaced (O9) is smooth because it reads **half** the display lines.

**Root cause (PROVEN on HW):** the mpeg2 framestore arbiter (`rtl/mpeg2/framestore_request.v`)
serves the **display read at higher priority than the motion-comp reference reads**, and the
whole decoder funnels through one DDR3 port (`mem_shim_burst → ddr_arb → DDRAM`). Progressive
re-reads the framebuffer **60×/s** (every refresh, including the 2–3× re-reads for each held
3:2 frame); that read bandwidth is FIXED by the pixel rate and **saturates the port during
active scan**, starving motion-comp. **Arbiter scheduling cannot fix it** — we tried (a) fully
demoting display → motcomp hit 0 lates but display starved → tearing + audio desync; (b) an
urgency-gated balanced arbiter at two thresholds → no change (display's demand is irreducible
by scheduling). It's a genuine throughput contention. SDRAM would be WORSE (16-bit board =
less bandwidth than the DDR3 burst path). **Do not re-attempt arbiter tuning.**

**The fix (this project):** make the **core output a 23.976 Hz progressive raster** (one
decoded film frame per refresh — NO in-core 3:2) and let the **framework scaler (ascal) do the
3:2 pulldown** to the 59.94 Hz HDMI output. This cuts the core's framebuffer re-reads from
60/s to ~24/s (reads clustered into a 15 ms active window, then a ~26 ms vblank that hands
motion-comp a big contiguous port window), so **motion-comp stops missing deadlines** — and
because 23.976 : 59.94 is exactly **2:5** and MiSTer's clocks are locked, ascal's frame-repeat
produces a **mathematically perfect, non-slipping 3,2,3,2**. The irregular pulse goes away.

**Honest endpoint:** this removes the *irregular pulse* and gives clean/normal 3:2. It does
NOT make film judder-free (ascal is a frame-doubler, not a motion-interpolating FRC). That's
the user's actual complaint (irregular cadence), so it's the right fix; base 3:2 judder would
need a true 24/48/72 Hz HDMI output mode (separate, bigger feature).

## 2. Why it works architecturally (verified this session)

- **ascal already frame-buffers and can repeat frames.** `sys/ascal.vhd` runs triple-buffer by
  default (`lowlat=0`; see `sys/sys_top.v:755` `.mode({~lowlat,…})`). The swap rule
  (`ascal.vhd:1920-1936`): at each **output (HDMI) vsync**, latch the newest completed **input**
  frame; if none arrived since the last output vsync, **repeat** the current one. That IS a
  24→60 frame-rate converter. **No ascal change needed.**
- **Input and output timings are decoupled.** `dvd/emu.sv`'s modeline walk sets the **core
  raster** = the VGA_* timing ascal AUTO-DETECTS as its input (`iauto=1`). ascal's OUTPUT
  timing (HDMI) is the framework's `video_mode`, independent. So "24 Hz in / 60 Hz out" is a
  valid ascal config; ascal scales+FRCs between them.
- **The decode-relief link is already evidenced:** interlaced (half the reads) → 0 lates →
  smooth. 24 Hz (40% of the reads, clustered) relieves it at least as much.

## 3. The changes (by file)

### 3a. `dvd/emu.sv` — modeline walk (the core 24 Hz raster)
The 6-register modeline write walk is around **L2085–2150** (`case (seq_step)`, writing
`REG_WR_HOR/HOR_SYNC/VER/VER_SYNC/VID_MODE/TRICK` into `mpeg2video`→`syncgen`). Refresh rate =
`27 MHz / (htotal × vtotal)`. NTSC today: `858 × 525 = 450450` → 59.94 Hz.

- **New 24p branch on `REG_WR_VER` (`seq_step 3'd2`)**: keep **480 active lines**, set
  **vtotal ≈ 1313** (`27e6 / (858 × 23.976) = 1312.7`). Active scan timing is unchanged
  (15.25 ms); the extra ~832 lines are vblank. Also set `REG_WR_VER_SYNC` vsync window inside
  the new vtotal (keep the sync pulse a few lines after active, e.g. `481..487`).
  ⚠️ **SUPERSEDED by §10** — rounding 1312.5 up to 1313 is exactly the drift bug. The
  shipped numbers are **htotal 874 (=875 dots) / vtotal 1286 (=1287 lines)**.
- ~~**Leave `REG_WR_HOR*` at the NTSC 858-dot values**~~ ⚠️ **SUPERSEDED by §10**: the dot
  clock does stay 27 MHz (no PLL reconfig), but NTSC film **must** override `REG_WR_HOR` to
  875 dots/line — an even htotal can never divide the required odd 1,126,125 dots/frame.
- Introduce a resolved wire, e.g. `wire film24_out = status[<bit>] & ~pal_eff & ~crt_eff;`
  2-FF-synced like `il_s2/pal_s2/crt_s2` (there's an existing sync block ~L2118+ — add
  `film24_s1/s2/prev`), fold `film24_prev` into the walk's re-trigger condition, and branch the
  `REG_WR_VER`/`REG_WR_VER_SYNC`/`REG_WR_VID_MODE` data on it. `VID_MODE` = progressive (halfline
  0, no pixrep, non-interlaced) — same as the current HDMI-progressive branch.

### 3b. `dvd/resample_addrgen.v` — governor: one frame per refresh
Today the governor paces 3:2 in-core via `SHOW_N` / `cur_show` / `repeat_first_field` (search
`SHOW_N`, `cur_show`, `refresh_cnt >= SHOW_N`, `show_next`). In 24p the raster **is** the film
rate, so:
- Force **`SHOW_N = 1`** (advance one decoded frame per refresh; no in-core pulldown — ascal
  owns it). Thread a `film24` input into the module and select `SHOW_N` from it (it's currently
  a parameter/constant — make it a mode-selected value).
- `cur_show`/rff-based drop-debit logic collapses to 1 refresh/frame; the frame-drop deadline
  becomes "produce a frame every 41.7 ms" (huge slack). Keep `frame_late`/`frame_drop_ctl`
  wired (should read ~0 lates in this mode — that's the success signal).
- `refresh_tick` now fires 24/s (it's `core_v_sync` edge — automatic once the raster is 24 Hz).

### 3c. `dvd/av_sync.sv` — STC tick rate
`TICKS_PER_REFRESH` is a Q16 increment `90000/refresh_rate` (`av_sync.sv:116-122`), currently
NTSC (59.94) and PAL (50) precomputed and selected by `refresh_50hz`.
- Add a **23.976 Hz** constant: `90000/23.976 ≈ 3754` (Q16). Add a `refresh_24hz` mode input and
  extend the selection mux (mirror `refresh_50hz` plumbing from `emu.sv`).
- Re-validate lip-sync at the new tick — the drift saga (`docs/av_sync.md`,
  `docs/lipsync_pickup.md`) was all at 60 Hz. Expect this to be *easier* (1 frame/refresh, no
  3:2 phase). Measure `vid_err` flat + lips constant on a real film disc.

### 3d. `dvd/emu.sv` — CONF_STR toggle + gating
- New `"P1O[<free bit>],Film 24p Out,Off,On;"`. **Free bits: 24/25/26/27** (24 was used by the
  abandoned diagnostic on the *other* branch — on THIS branch off main it's free again; pick
  one, e.g. **P1O[24]** or 25). Verify `grep -c "status\[N\]" dvd/emu.sv` == 0 first.
- Gating: `film24_out = status[bit] & ~pal_eff & ~crt_eff` (HDMI-NTSC-film only for v1).
  Mutually exclusive with O9 Interlaced Out (if both set, 24p wins or is disabled — pick one and
  document). Analog output is invalid at 24 Hz → HDMI-only (optionally blank the analog pins in
  this mode; at minimum document it).

### 3e. ascal / framework — NO CHANGE
`iauto=1` auto-detects the 24 Hz input; triple-buffer FRC is already active.

## 4. Phasing (do the risky part first)

**Phase 0 — ascal-input PROBE (cheapest, de-risks the #1 unknown). ✅ DONE + HW-CONFIRMED
(2026-07-25):** ascal locks cleanly onto the 480-active / 1313-total 23.976 Hz input — one
resolution popup, then stable HDMI (video was slow-mo as expected with SHOW_N still 2). The
whole approach is de-risked.
Just 3a + 3d (modeline 24p branch + toggle). Do **NOT** touch the governor/av_sync yet — with
`SHOW_N` still 2 the picture will be wrong/paced oddly, but the point is only: **does ascal
lock onto a 480-active / ~1313-total 24 Hz input and produce stable HDMI?** Watch for a
resolution-change popup, no-signal, or mis-scale. If ascal rejects the long-vblank input, the
whole approach needs rethinking (fallback: lower the dot clock via PLL reconfig instead of
extending vtotal — bigger change). Build with DEBUG_OVERLAY on; O[2] overlay should still be
readable. **If ascal locks cleanly, proceed.**

**Phase 1 — make-or-break. ✅ DONE + HW-CONFIRMED (2026-07-25):** SHOW_N=1 + av_sync 23.976 Hz
tick. NTSC film plays at **correct speed, in sync, and the ~1 s pulse is GONE** (user-confirmed
on the T2 tilt). Shipped as the manual `P1O[24]` toggle. (The numeric row-11 lates readout was
NOT captured — the DEBUG_OVERLAY build fit flaky/green; the pulse-gone visual result is the
deliverable. Re-enable DEBUG_OVERLAY + re-sweep if a numeric lates confirmation is wanted.)
- 3b (`dvd/resample_addrgen.v` `film24` → `show_next=1`, threaded via `resample.v`/`mpeg2video.v`)
- 3c (`dvd/av_sync.sv` `REFRESH_MHZ_FILM=23976` + `refresh_24hz`)
- Wiring in `dvd/emu.sv` (`film24_eff`, `film24_dec` 2-FF sync, av_sync `refresh_24hz`).

**Phase 2 — automatic detection + PAL 25p (NEXT SESSION). See §9 for the full work order.**
Analog blanking in 24p; OSD/HUD behavior at 24 Hz are minor polish items also deferred here.

## 5. Build & test

```bash
# DEBUG_OVERLAY is needed to read the lates during bring-up. Add to DVD.qsf near the
# QUARTUS=1 macro (it is NOT in DVD.qsf on main — this is the one-line re-enable):
#   set_global_assignment -name VERILOG_MACRO "DEBUG_OVERLAY=1"
# Remove it for the final ship build.

USE_DOCKER=1 ./build_release.sh --compile --name DVD_film24_dbgovl   # full compile (re-synth!)
# If fit FAILS to route on the pinned SEED (this design is ~90% ALM = a seed lottery; adding
# DEBUG_OVERLAY + any logic often needs a re-sweep), run the fitter-only sweep on the
# already-synthesized netlist:
USE_DOCKER=1 NAME=DVD_film24_dbgovl tools/seed_sweep.sh
# Verify the overlay actually compiled in (must be > 0):
grep -c debug_overlay_inst output_files/DVD.fit.rpt
```

Reading the overlay off a phone/capture recording (the user provides `tools/streams/*.mp4`):
```bash
python3 tools/osd_read.py calibrate tools/streams/<clip>.mp4 --time 6 --cal /tmp/cal.json
python3 tools/osd_read.py csv tools/streams/<clip>.mp4 --every 1.0 --start 1 --end 20 \
    --cal /tmp/cal.json --out /tmp/out.csv
# row 11 = {lates/s [15:8], drops/s [7:0]};  row 10 = {VBUF fill, audio_ring fill};
# row 17 = vid_err (signed, 1 unit = 1 refresh). See tools/osd_read.py ROW_LABELS.
```

## 6. Gotchas (learned the hard way this session)

- **`tools/seed_sweep.sh` is FITTER-ONLY** — it reuses the existing synthesis netlist. Any
  RTL change or `ifdef`/`VERILOG_MACRO` change (e.g. DEBUG_OVERLAY) must go through a FULL
  `build_release.sh --compile` first (runs `quartus_map`). A sweep after only editing the macro
  will silently ship the OLD netlist. Verify with `grep -c debug_overlay_inst output_files/DVD.fit.rpt`.
  (Memory: `seed-sweep-is-fit-only-no-ifdef`.)
- **DEBUG_OVERLAY is compiled OUT of release** (`ifdef DEBUG_OVERLAY`, not in DVD.qsf on main).
  Re-enable it (one QSF line) for bring-up; the multi-row overlay is what `osd_read.py` decodes.
  In a release build O[2] shows only the menu-highlight blocks. (Memory:
  `debug-overlay-compiled-out-of-release`.)
- **osd_read interlaced clips need a hand calibration** (sx≈1.28 vs progressive 2.667) — but 24p
  is progressive so the normal auto-calibrate works. Always confirm row-3 (`59.94/s`) validates
  before trusting numbers (pitch-alias trap; memory `osd-read-pitch-alias`).
- **The fit is congestion-marginal** (~90% ALM). Expect seed sweeps; the pinned SEED in DVD.qsf
  is for the release (non-overlay) netlist — the overlay/24p netlist may want a different seed.
  Don't pin a diagnostic seed into DVD.qsf for the release netlist.
- **Do NOT re-attempt the arbiter fix** (framestore_request display-priority demote / urgency
  gate / disp FIFO threshold). Proven ineffective on HW — it's throughput-bound, not
  schedulable. That work lives on the abandoned `feature/debug-overlay-cadence-diagnostic`
  branch.

## 7. Success criteria

1. Phase 0: ascal locks onto the 24 Hz core raster → stable HDMI, no popup/no-signal.
2. Phase 1: DEBUG_OVERLAY row 11 **lates ≈ 0** on the T2 tilt in 24p mode (vs 4 at 60 Hz),
   VBUF healthy, `vid_err` flat.
3. Cadence: record-vs-source shows a clean/regular 3:2 — **no ~1 s pulse** (user-confirmed).
4. Lip-sync holds on a real film disc.
5. 60 Hz and O9 paths unchanged when the toggle is Off; analog/CRT/PAL unaffected.

## 8. References
- Forgejo **issue fj#124** — full investigation + this plan (search "Implementation plan").
- Memory `hdmi-progressive-film-cadence-judder` — root cause + this proposed fix.
- Key files: `dvd/emu.sv` (modeline walk ~L2085), `dvd/resample_addrgen.v` (governor/SHOW_N),
  `dvd/av_sync.sv` (STC tick ~L116), `sys/ascal.vhd` (swap logic L1920-1936),
  `rtl/mpeg2/syncgen.v` (raster from modeline), `rtl/mpeg2/modeline.v` (modeline regs).
- Related memory: `pal-support-and-hres-offbyone` (the runtime modeline-write precedent this
  extends), `crt-interlace-odd-total-lines` (syncgen timing precedent), `pts-av-sync-implemented`.

## 9. Phase 2 work order — automatic film detection (Off/On/Auto) + PAL 25p

> Written 2026-07-25 after v1 (manual NTSC 24p) shipped + HW-confirmed. Build on the
> `film24` machinery already in the tree (do NOT rebuild it). Everything below is additive.

> **★ IMPLEMENTED 2026-07-25 (branch `feature/film-24p-auto`) — where the code landed:**
> - **PAL 25p:** `dvd/av_sync.sv` `REFRESH_MHZ_25=25000` + `refresh_25hz` (priority above
>   `refresh_50hz`, since PAL film asserts both); `dvd/emu.sv` modeline VER branch
>   `(pal_prev && filmp_prev) -> {576, 1249}` (vtotal 1250 @ 864 dots = 25.000 Hz exact),
>   `av_sync.refresh_25hz(film25_eff)`. Governor untouched.
> - **Detector:** `dvd/resample_addrgen.v` — a per-pickup FSM over the committed
>   `progressive_frame`/`repeat_first_field`, two hysteretic verdicts `film_det_ntsc`
>   (progressive + ALTERNATING rff) / `film_det_pal` (sustained progressive). The verdicts
>   route up `resample.v -> mpeg2video.v -> emu.sv` and 2-FF sync clk_dec->clk_sys.
>   **★ HW-fix (2026-07-25): SATURATING CONFIDENCE, not a consecutive-run counter.** The
>   first cut reset a consecutive-run counter to 0 on any cadence break — it locked on a
>   clean menus-OFF stream but NOT when the film title was reached via the disc MENU/VM,
>   because the nav layer (NAV packs, cell/PGC boundaries, VM POST, brief stills) injects
>   periodic hiccups that kept zeroing the run. Replaced with a confidence accumulator
>   (+3 confirming / -2 progressive-not-toggling / -8 interlaced, clamp [0,127]; engage 120,
>   disengage 24) that DECAYS on a hiccup instead of resetting — rides the menu-path breaks
>   and still locks, while the false-positive guard holds (30p video = zero confirming
>   frames → only decays → never engages). Deep hysteresis = a genuine film→video transition
>   backs off in ~2 s.
> - **Mode:** `dvd/emu.sv` `P1O[25:24],Film 24p Out,Auto,Off,On` (**default Auto**);
>   `film_want = On | (Auto & (pal_eff ? film_det_pal_sync : film_det_ntsc_sync))`;
>   `filmp_eff = film_want & ~crt_eff` splits into `film24_eff`/`film25_eff`. Internal
>   `film24_*` wires generalised to `filmp_*` (the governor's deep `film24` port kept its
>   name — it just means "1 frame/refresh"). **Enum reordered so index 0 = Auto** →
>   the power-on default film-detects (the detector is HW-confirmed clean, so the earlier
>   "default Off for first bring-up, flip later" plan is now DONE). `film_mode` decode
>   updated to `0=Auto/1=Off/2=On`.
> - **Tests:** `bench/dvd/film_detect_tb.sv` (NEW), `av_sync_tb` Film-25p instance.
> **HW GATE (the two §9a watch-items): startup 60→24 re-lock glitch is tolerable; Auto must
> NOT engage 24p on a true-30fps-NTSC-video disc (the regression).** Flip §3/§9 markers +
> `docs/roadmap.md` + the `hdmi-progressive-film-cadence-judder` memory to ✅ HW-CONFIRMED
> once the board passes.

### 9a. Automatic NTSC film detection (the headline ask)

**The signal is already parsed — no pixel analysis needed.** DVD film is *soft-telecined*:
23.976 fps film is coded as progressive frames with `progressive_frame=1` and an alternating
`repeat_first_field` (rff) pattern (frame A = 3 fields, frame B = 2 fields → the 3:2 / 5-fields-
per-2-frames cadence). True 30 fps video is `progressive_frame=0`, `rff=0`, 2 real fields/frame.
The governor (`dvd/resample_addrgen.v`) *already* reads `progressive_frame`/`repeat_first_field`
every frame (it's how `show_next_prog = rff ? 3 : SHOW_N` works), and the lip-sync `flags_commit`
fix (`rtl/mpeg2/motcomp_picbuf.v` / mpeg2video) exposes them correctly-timed. So the detector is
just a small FSM over flags we already have.

**Detector:** watch `progressive_frame` + the alternating-rff 3:2 pattern over a window (~½–1 s
of frames). Assert `film_detected` after a *sustained* clean 3:2 run; deassert after a sustained
non-film run. **Strong hysteresis** (e.g. require N consecutive confirming frames each way) so it
cannot flip-flop.

**★ THE ASYMMETRY THAT DICTATES THE DESIGN — be conservative:**
- Film missed → stays 60 Hz = just loses the enhancement (HARMLESS, == today).
- Video mistaken for film → forced to 24p = **dropped frames / judder = a REGRESSION.**
So bias toward video: only flip to 24p on a *confident, sustained* 3:2 cadence. False negatives
are free; false positives hurt. Tune for precision on film, not recall.

**UX = three-way `Off / On / Auto`** (mirrors Video Standard / Aspect Auto menus). Auto = the
detector drives it (the "just works" default). **On** = force (needed for hard-telecined discs
that carry no rff flags — they look like video to the detector; rare on DVD). **Off** = force off
(escape hatch if a disc ever fools it). Change `"P1O[24],Film 24p Out,Off,On;"` →
`"P1O[25:24],Film 24p Out,Off,On,Auto;"` (2 bits; verify the new bit is free:
`grep -c "status\[25\]" dvd/emu.sv` == 0).

**Signal routing note (domain flip):** today `film24_eff` originates in clk_sys (from `status`).
With Auto, the detector output originates in **clk_dec** (where the picture flags live). So:
modeline walk (clk_dec) + governor (clk_dec) can consume it directly; **av_sync (clk_sys) now
needs the detected level 2-FF-synced INTO clk_sys** (reverse of today's `refresh_24hz` feed).
Resolve `film24_eff = (mode==On) | (mode==Auto & film_detected_sync) ` and keep the `~pal & ~crt`
(NTSC) / progressive gating.

**Caveats to document + watch on HW:**
- **Startup switch glitch:** detection needs a window, so a film movie may START at 60 Hz and
  switch to 24p ~1–2 s in → the modeline walk re-runs → ascal re-locks (brief pop, same mechanism
  as the runtime NTSC↔PAL switch, which works). Often hidden by the studio-logo/FBI intro but
  disc-dependent.
- **Mixed-cadence discs** (film feature + video extras/credits) switch modes at boundaries;
  hysteresis bounds the thrash but there's a re-lock at genuine transitions.
- Same **fit/seed lottery** — the detector adds logic to this ~90% design; expect a re-sweep
  (`tools/seed_sweep.sh`), and remember the overlay build fits worse than release.

### 9b. PAL 25p (pairs naturally with the detector — CLEANER than NTSC 24p)

PAL film is a clean 2:2 already (no NTSC-style pulse), so 25p's payoff is **throughput, not
cadence**: it halves the display framebuffer re-reads (**50/s → 25/s**), relieving the known
high-motion PAL stutter (worse on PAL: 576 lines = 1620 MB/frame). Two reasons it's cleaner:
- **Exact 1:2** (25 → 50) — ascal repeats each frame exactly twice, zero beat (vs NTSC's 2:5 with
  a 23.966-vs-23.976 ~0.04% residual).
- **Exact 25.000 Hz is hittable:** keep htotal 864, set **vtotal 1250** → `864 × 1250 @ 27 MHz =
  25.000` exactly. Modeline branch = PAL geometry with `VER = {576, 1249}` (mirror the NTSC-24p
  `VER = {480, 1312}` branch; VER_SYNC/VID_MODE reuse the PAL progressive values).

**Changes (all additive, reuse the machinery):**
- Modeline (`dvd/emu.sv`): add the PAL-25p branch (the walk already keys on `pal_prev`).
- `dvd/av_sync.sv`: add `REFRESH_MHZ_25 = 25000` (90000/25 = 3600 ticks/refresh exactly) + a
  `refresh_25hz` input; select it when `filmp & pal`.
- Governor: **nothing new** — `film24` (SHOW_N=1) is rate-agnostic ("one frame per refresh").
- Generalize the gate: `filmp_eff = <mode/detect> & ~crt_eff`; under PAL take the 25p path, under
  NTSC the 24p path (instead of today's "forced off under PAL"). Consider renaming the internal
  `film24_*` wires to `filmp_*` since they now serve both rates (the CONF_STR label can stay
  "Film 24p Out" or become "Film 24p/25p Out").
- **Same film-only caveat as NTSC:** true 50-field interlaced PAL video (sport/soaps) must NOT
  use 25p (weaving two time instants = combing + half temporal res) — the detector's
  progressive_frame/rff test gates PAL too, so a single detector serves both standards.

### 9c. Suggested order
1. PAL 25p first (mechanical, low-risk, exact-ratio, reuses everything) — validate on a PAL film
   disc (high-motion PAL stutter should ease).
2. Then the Auto detector (the risk item — needs film / true-video / mixed-cadence test content;
   the false-positive-video→24p regression is what to guard + verify).
3. Re-sweep, HW-confirm each, then update this doc's status + `docs/roadmap.md` + the
   `hdmi-progressive-film-cadence-judder` memory.

### 9d. Test content needed
NTSC film disc (T2 — the proven case), a **true 30 fps NTSC-video** disc (concert/TV-sourced) to
prove Auto does NOT engage 24p on it, a **PAL film** disc (25p throughput win), and ideally a
**mixed-cadence** disc (film feature + video extras) for the hysteresis. Test ISOs live in
`$DVD_ISO_DIR/`.

---

## 10. ★ EXACT-RATE FIX — the 24p raster was not 23.976 Hz (2026-08-02, ✅ HW-CONFIRMED as part of the PR fj#158 stack — real bug, but NOT the drift driver; see §11/§12)

**Symptom (user report, 2026-08-02):** in Film 24p mode a movie starts in sync and drifts —
after an hour the **audio is ~1.6 s AHEAD of the video**. Linear over time; **a chapter change
re-syncs it** (the seek re-anchors the STC and flushes). It does **not** happen in interlaced /
analog-out mode.

### 10.1 Root cause — an inexact modeline, nothing to do with the A/V-sync logic

The three symptom facts pin it down before any code is read: linear accumulation = a **rate**
error, not a phase/offset error; reset-by-seek = the drift is re-zeroed at every re-anchor; and
24p-only = it lives in whatever 24p changes. The only thing 24p changes about the *rate* is the
raster.

`nco_trim` is **retired** ([[docs/av_sync.md]], the lip-sync saga): the 48 kHz audio NCO free-runs
off the same 27 MHz crystal as the raster, deliberately, because same-crystal means same rate.
That makes one thing load-bearing:

> **INVARIANT: `htotal × vtotal` must equal the content's exact frame period in 27 MHz dots.**
> Nothing downstream corrects a raster-rate error — not the STC (it *counts* refreshes, so a
> slow raster just makes the STC slow too), not the governor, not ascal (frame repetition
> doesn't move the average). A wrong raster rate is a permanent, linear A/V drift.

Every other mode satisfies it exactly. NTSC 24p did not:

| mode | htotal × vtotal | dots/frame | rate | exact? |
|---|---|---|---|---|
| NTSC 480p | 858 × 525 | 450,450 | 59.94006 | ✅ = 60000/1001 |
| PAL 576p | 864 × 625 | 540,000 | 50.00000 | ✅ |
| PAL 25p (film) | 864 × 1250 | 1,080,000 | 25.00000 | ✅ |
| **NTSC 24p (v1)** | **858 × 1313** | **1,126,554** | **23.96689** | ❌ **429 dots long** |
| **NTSC 24p (fix)** | **875 × 1287** | **1,126,125** | **23.976024** | ✅ = 24000/1001 |

429 / 1,126,125 = **0.03810 % slow** ⇒ video falls behind by **1.371 s per hour** ⇒ audio is
heard that far ahead. (The user measured ~1.6 s by eye — same magnitude, same sign.) The v1
plan (§3a) explicitly chose `vtotal ≈ 1313` from `27e6/(858 × 23.976) = 1312.7` and left
`REG_WR_HOR` at 858; §9b even noted the "~0.04 % residual" but treated it as an ascal *beat*
rather than as cumulative A/V drift. It is both — and the drift is the part that matters.

The surplus frames do **not** show up as drops or stutter: they pile into the 2 MB VBUF
(1.37 s of 23.976 fps ≈ 33 frames ≈ well under a megabyte of ES), which is why the drift is
smooth and linear for the whole title instead of self-limiting.

### 10.2 Why 875 × 1287 (and why 858 could never work)

Required: `27e6 × 1001/24000 = 1,126,125` dots/frame. With the standard line,
`1,126,125 / 858 = 1312.5` — a **half-line**, not representable in a progressive modeline
(the half-line mechanism in `syncgen.v` exists only for interlace).

`1,126,125 = 3² × 5³ × 7 × 11 × 13` is **odd**, so *any* even htotal (858, 864, …) is
arithmetically impossible. Odd divisors near 858: 819, 825, **875**, 1001, 1125. **875** is the
closest to the standard line and leaves the sync pulse untouched:

```
REG_WR_HOR      720 active, horizontal_length 874   -> 875 dots/line  (was 857 -> 858)
REG_WR_HOR_SYNC 735..797                            -> unchanged
REG_WR_VER      480 active, vertical_length 1286    -> 1287 lines     (was 1312 -> 1313)
REG_WR_VER_SYNC 488..494                            -> unchanged (progressive 480p values)
```

Active scan (720 × 480 at 27 MHz) is bit-for-bit unchanged; only blanking moves (back porch
60 → 77 dots, vblank 833 → 807 lines). hsync goes 31.47 → 30.86 kHz. Nothing downstream cares:
ascal takes DE/HS/VS + `CE_PIXEL≡1` and rescales the active window, the HDMI output modeline is
the framework's own, and the 858-assuming `dvd/re_interlace.sv` is unreachable here (film is
force-disabled under `analog_eff`). PAL 25p is already exact and is untouched.

`dvd/av_sync.sv` needs **no change**: `REFRESH_MHZ_FILM = 23976` was always the *correct*
constant — it was the raster that didn't match it. Now they agree.

### 10.3 Verification

`bench/dvd/crt_syncgen_tb.sv` **PHASE 4 (Film 24p) + PHASE 5 (PAL 25p)** drive `sync_gen` with
the shipped modelines and assert vsync-to-vsync spacing **to the dot**:

```bash
iverilog -g2012 -I rtl/mpeg2 -o bench/dvd/crt_syncgen_sim rtl/mpeg2/syncgen.v bench/dvd/crt_syncgen_tb.sv
vvp bench/dvd/crt_syncgen_sim
# [Film 24p ] PASS: frame period 1126125 dots = 27 MHz * 1001/24000 = 23.976024 Hz EXACT
# [Film 25p ] PASS: frame period 1080000 dots = 27 MHz / 25 = 25.000000 Hz EXACT
```

Negative control (confirmed): with the v1 numbers the phase reports
`vsync spacing 1126554 dots (expect 1126125)` and the TB now exits **non-zero** (`$fatal` —
plain `$finish` let vvp mask failures, the trap that hid three broken TBs during the M17 work).

### 10.4 HW gate

- [ ] NTSC film title (T2) in Film 24p: play **≥ 1 hour without touching transport**; lips stay
      locked end-to-end (v1 = audio ~1.4 s ahead by then).
- [ ] Still no cadence pulse; ascal locks to the new 875 × 1287 raster (one resolution popup,
      then stable — the 858 × 1313 raster already locked, this is a milder geometry).
- [ ] `Auto` still engages/disengages correctly; PAL 25p unchanged; 60 Hz / interlaced /
      analog paths unchanged (they never touched these registers).

---

## 11. ★ Film-24p A/V drift, round 2 — the FRAME-DROP LEDGER leak (2026-08-02, ✅ HW-CONFIRMED: cut the drift 1.6 → 0.9 s/hour; the residual was §12)

**§10's exact-raster fix did NOT cure the drift** (HW: "no change, same A/V drift as before
after 1 hour"). The raster error was real and worth fixing, but it was not the driver. This
is the second, larger 24p-only mechanism.

### 11.1 Why the raster fix couldn't have been the whole story

In Film 24p the video content rate is `min(refresh rate, delivery rate)` — the governor
advances one decoded frame per refresh, but only *if a frame is ready*. When it isn't, the
display HOLDS (`frame_late`) and content advances more slowly than the raster. So the
raster sets an upper bound on the content rate; anything that makes the decoder miss the
deadline moves the real rate below it, and no modeline change can recover that.

### 11.2 Root cause: `drop_cost` is not film24-aware

The frame-drop governor is built on a **timeline-debt ledger** (`dvd/frame_drop_ctl.sv`): a
late costs one refresh of slow-motion (`debt += 1`), and a dropped frame reclaims its own
display duration (`debt -= drop_cost`). Neutrality — the entire point of the ledger — holds
only if `drop_cost` equals the dropped picture's TRUE display duration.

In **Film 24p the governor gives every frame exactly ONE refresh**
(`show_next = film24 ? 4'd1 : ...` — the 3:2 is done downstream by ascal). But
`mpeg2video.v` hardcoded:

```verilog
.drop_cost(drop_pic_rff ? 4'd3 : 4'd2),   // true duration in film24 is 1
```

so every drop was credited 2–3 refreshes for a frame that only ever occupied 1. The
controller then needs ~2.5 lates to fund one drop, and the difference leaks straight out of
the presentation timeline:

> **drift (in refreshes) = lates − drops**

Video falls behind wall-clock; audio — free-running at a fixed 48 kHz, `nco_trim` retired —
drifts AHEAD. It is **24p-only**: at 59.94/50 Hz `rff?3:2` IS the true duration, so the
ledger stays neutral (which is why 60 Hz and the analog interlaced path are clean), and it
resets on any seek/chapter re-anchor.

### 11.3 Measured (`bench/dvd/film_drift_tb.sv`, new `+FILM24=1`)

Real `frame_drop_ctl`, same compute-bound content model, 24p timing (`refresh_p = 50` clk so
a 24p refresh spans the same wall time as 2.5 refreshes at 59.94 — identical per-frame
decode budget, so late statistics are comparable):

| config | lates | drops | ratio | leak | drift |
|---|---|---|---|---|---|
| 24p, `drop_cost = rff?3:2` (shipped) | 451 | 168 | 2.68 : 1 | 283 | **−286 refreshes** |
| 24p, `drop_cost = 1` (fixed) | 283 | 279 | 1.01 : 1 | 4 | −7 refreshes |
| 59.94 Hz, either debit | 681 | 279 | — | — | −16 (IDENTICAL — control) |

The 59.94 row is the control that proves the ledger is already neutral there: the two debit
expressions give bit-identical results because they are the same number at 60 Hz.

Scaling to the reported symptom: 1.6 s/hour = 38 refreshes/hour of leak; at the measured
2.68:1 ratio that needs only **~60 lates/hour (about one per minute)** — far too rare to
appear in the 25-second DEBUG_OVERLAY captures that previously read "lates ≈ 0" in 24p.

### 11.4 The instrument was masking it

`vid_err`'s content credit (`mpeg2video.v`, `vid_content_refr`) had the SAME hardcoded
`rff?3:2` for a dropped picture. In 24p it therefore over-credited content by 1–2 refreshes
per drop, so **`vid_err` read video AHEAD while video was really falling behind** — the one
instrument that exists to detect this drift was cancelling it out. Fixed alongside
`drop_cost`; treat any future 24p `vid_err` reading from an older build as void.

### 11.5 HW gate + the discriminating A/B

- [ ] NTSC film in Film 24p, **≥ 1 hour untouched** — lips stay locked.
- [x] **✅ DISCRIMINATOR PASSED ON HW (2026-08-02, previous build, Frame Drop OFF):**
      audio ahead **~400 ms after 10 min = 2.4 s/hour**, vs ~1.6 s/hour with Frame Drop On.
      The drift is confirmed LATE-DRIVEN. (Note the prediction quoted to the user beforehand,
      "~2.5× worse", was arithmetically wrong — it reused the 2.68:1 lates-per-drop ratio as
      the drift ratio. The model's actual prediction is 1/(1 − 1/2.5) ≈ **1.6×**; measured
      1.5×.) The decisive part is that ONE free parameter — a late rate of ~58/hour, which
      had been estimated from the original 1.6 s/hour BEFORE this test — reproduces both
      measurements:

      | config | mechanism | predicted | measured |
      |---|---|---|---|
      | Frame Drop Off | every late leaks, no reclaim | 58 × 41.71 ms = 2.4 s/hr | **2.4 s/hr** |
      | Frame Drop On, buggy debit | ~60 % leaks (1 drop per ~2.5 lates) | 1.45 s/hr | ~1.6 s/hr |
      | Frame Drop On, fixed debit | 1:1 reclaim (sim 279/283) | ~0.03 s/hr | ⏳ |

- [ ] ⚠️ **The fix only works with `P1O[12] Frame Drop` ON** (the default). With drops
      disabled there is no catch-up mechanism at all, so the full late rate leaks
      (2.4 s/hour) no matter what the debit says. Frame Drop Off is a diagnostic, not a
      playback setting, in 24p.
- [ ] Second discriminator: late-driven drift scales with content difficulty — a visually
      easy title should drift measurably less than a high-motion one. A pure rate error
      would not care.
- [ ] 59.94 Hz / PAL / interlaced / analog paths unchanged (the debit is identical there).

---

## 12. ★★ THE ACTUAL ROOT CAUSE — imperfect telecine cadence vs the flat-1-refresh
## display (2026-08-02/03, cadence-slip corrector, ✅ HW-CONFIRMED 2026-08-03: 45-min clip, A/V LOCKED, no drift)

§10 (exact raster) and §11 (drop-ledger leak) were both real bugs and both fixes stand —
but the HW test on the §11 build STILL drifted (~0.9 s/hour). The remaining and dominant
mechanism was found by measuring CONTENT, not counters, and it closes to 1 %.

### 12.1 The measurement chain (all local, from one 48-min HW capture + the source ISO)

The DEBUG_OVERLAY capture (`DVD_film24_dbgovl2`) showed EVERY core instrument flat for
48 minutes — `vid_err` 0 (the §11 fix made it trustworthy), lates ≈ 0, ring/self-heal 0,
raster rate regressed from overlay row 3 = correct to 13 ppm — while the user heard
~800 ms. So the capture itself was measured against the source VOB (sliced straight out
of the ISO by extent — the title is one contiguous 3.95 GB run):

- **Audio content position** (envelope + waveform xcorr, track 0x80): advanced
  2649.973 s over 2650.000 s of capture — **audio plays real time to 10 ppm**.
- **Video content position** (motion-envelope xcorr — 1-D frame-difference energy at
  12 Hz, immune to geometry/color; single-frame NCC was useless on dark scenes):
  audio−video = **+152 ms at t=40 s, +1036 ms at t=2690 s → +884 ms drift**, q≈1.0.
- **Per-picture disc scan** (mux-aware: 2048-byte pack walk → 0xE0 PES reassembly →
  picture-coding-extension parse, so no sector-straddle losses; a raw byte scan
  mis-counted): **N = 63,531 pictures, R = 31,712 rff, density 0.499158.** The 50
  apparent PTS jumps are ±83 ms B-reorder pairs summing to 0.000 — no real gaps.

> **Predicted retard = (N/2 − R)/59.94 = +0.893 s. Measured = +0.884 s.** 1 %.

### 12.2 The mechanism

Film 24p displays EVERY picture for exactly one 1/23.976 s refresh — correct only if
the disc's 3:2 cadence is perfect (rff alternating ⇒ 2.5 fields average). Real discs
break cadence at shot edits (MiB: ~107 anomalies in 63.5k pictures, one per ~25 s).
Each missing rff=1 is a 2-field (33.4 ms) picture shown for 41.7 ms = +8.34 ms video
retard; audio free-runs at real time ⇒ audio walks ahead. At 60 Hz `cur_show` honours
each picture's OWN rff (2 or 3 refreshes) — timeline-exact for ANY cadence — which is
why every other mode is clean. Invisible to `vid_err` by construction (pickups stay on
schedule; the error is the flat ASSUMED duration), to the raster (exact), and to every
audio counter (no skips). The detector never disengages (isolated breaks only dent its
confidence) — matching the observed single popup at start and none after.

### 12.3 The fix — cadence-slip corrector (`dvd/resample_addrgen.v`, no new ports)

Accumulate the per-picture duration error in 0.5-field units at each pickup
(rff=1 → +1, rff=0 → −1; perfect cadence oscillates 0/±1) and correct with whole
refreshes at ±5 units (±2.5 fields):

- **deficit** (the MiB direction): pulse one `frame_late` into the frame-drop ledger →
  `frame_drop_ctl` banks 1 refresh → the VLD drops one B (`drop_cost = 1` in film24,
  the §11 fix) → content advances one picture in zero refreshes. Entirely the
  HW-proven drop path; on MiB ≈ one ~42 ms skip per ~2 min.
- **surplus**: grant that pickup `cur_show = 2` (one 2-refresh show).
- **Gate = `film24 && det_ntsc`** — the detector's own NTSC-telecine verdict, already
  inside this module (no port threading). PAL 25p film (rff≡0, exactly one 25p refresh
  per picture — no cadence freedom) never raises `det_ntsc`, so the corrector is inert
  there, as it is for true 30p video and at 60 Hz. Bounded by construction: |acc| < 5
  ⇒ residual A/V error can never exceed ~1 refresh (42 ms). Seeks at worst leave a
  <1-refresh stale phase that self-corrects; no flush plumbing.

⚠️ **The deficit correction rides the B-drop path ⇒ requires `O[12] Frame Drop` ON
(the default).** With dropping off, imperfect-cadence discs still drift in 24p (and
additionally lose the §11 reclaim) — Frame Drop Off is a diagnostic, not a playback
setting, in 24p.

Sim: **`bench/dvd/cadence_slip_tb.sv`** — perfect cadence quiet; MiB-like deficit
corrects at the predicted rate (29 vs ~28 over 3000 pickups); surplus holds likewise;
inert at 60 Hz and behind the 30p gate. Two TB traps found en route, documented in the
TB: an even-period "forced rff=0" anomaly is a parity NO-OP (a dead corrector read as
pass), and busy-fall counting sees pickups, not scans (holds invisible) — scans must
be counted via `refresh_tick_dbg`.

### 12.4 HW gate

- [x] **✅ HW-CONFIRMED 2026-08-03 (user):** MiB in Film 24p, Frame Drop ON, 45-minute
      clip — **A/V locked, no drift** (this exact title/span previously measured
      +0.884 s / 44 min on the pre-fix build).
- [ ] Overlay build: row 11 lates ≈ 0.5/min (the corrector's injected debt), row 16
      drops tracking them 1:1, `vid_err` flat, no visible artifact at corrections
      (a lone B-drop ≈ the HW-proven governor drop).
- [ ] A second NTSC film disc (different mastering = different cadence-break rate)
      stays locked too.
- [ ] 60 Hz / PAL / analog / menus unchanged (corrector inert outside NTSC film24).

---

## 13. Engage/disengage now fires the full seek-equivalent flush (2026-08-28, `fix/mount-avsync-flush`)

**Symptom (user report, 2026-08-27):** entering the main film from a menu introduced a
small constant A/V skew once Auto engaged the 24p raster; a chapter skip fixed it. The
menu→title jump establishes audio sync at 59.94/50 Hz, then ~2 s later the detector
locks and the raster + `TPR_Q16` switch — with **no flush on that edge** (`il_switch`
watches only `il_eff`), so the raster hand-off left a constant phase error the one-sided
re-anchor can never catch (forward, < 15 s) and the locked rate never grinds out. The
chapter-skip workaround was exactly the missing flush trio.

**Fix (emu.sv):** `film_switch = (filmp_eff ^ filmp_eff_q) & ~menu_active`, ORed with
`il_switch` into `mode_switch`, which drives all three flush triggers (load + aud +
seek/vbuf) in `dvd/flush_ctl.sv`. Both edges covered (engage AND a mid-title film→video
disengage — the mirror skew). The `~menu_active` gate keeps a detector-confidence decay
during a menu from glitching the keep_vbuf menu machinery; the next menu→title jump
flushes anyway. Trade (same as Interlaced Auto): a brief seek-like re-lock at the
switch, ~once per title entry — README's Film 24p section now tells users the hiccup is
normal and that discs which flip content types constantly may prefer `Off`. Trigger
matrix locked by `bench/dvd/flush_ctl_tb.sv`; post-mortem in `docs/av_sync.md`.
⏳ HW-confirm pending.
