# CRT 480i — native 15 kHz interlaced composite output (O[14])

> **⛔ SUPERSEDED (2026-07-29, branch `feature/analog-dual-raster`) by the DUAL-RASTER
> analog output — see `docs/analog_dual_raster.md`. ★ 2026-09-03: the dual raster is
> itself retired and THIS document's architecture is back in a different coat: the
> interlaced main raster carries the N64 half-line (§2) and drives the analog pins
> directly — with pixel repetition (1440 @ 27 MHz, CE_PIXEL one clock per pair) instead
> of §3's 13.5 MHz dot pacing, and vsync anchored on the hsync leading edge. See
> `docs/single_raster_analog.md`.** The whole-core CRT mode this
> document describes (O[14] toggle, 13.5 MHz `dot_ce` main-raster pacing, the CRT
> branch of the modeline walk, `VGA_SCALER=~crt_eff`) is REMOVED: the 15 kHz raster is
> now a second, simultaneous output (`dvd/re_interlace.sv` → `VGA2_*`) auto-engaged
> from MiSTer.ini alone (`vga_scaler=0` + `composite_sync=1`/ypbpr/sog), PAL 576i
> included, with HDMI keeping full progressive quality at the same time. Everything
> below is kept as HISTORY — and the load-bearing parts still ship: the N64-model
> half-line syncgen (§2, reused verbatim as the re-interlacer's raster generator, with
> these exact NTSC numbers), the pixel_queue CE-stretch fix (§0, in-tree, inert at
> CE≡1), and the 480i field-path A/V ledger fixes (§5, still active for O[10:9]).

**Status (2026-07-05, branch `feature/crt-480i-native`): ✅ HW-CONFIRMED (round 2,
`DVD_crt480i_v2_20260705_1149.rbf`): the CRT image is CORRECT — true 2:1 interlaced
480i, native width — and AUDIO STAYS IN SYNC (the field-path ledger fixes hold).
Round 1 found+fixed the pixel_queue CE bug (§0).**

**⚠️ Known regression (open follow-up): the HDMI output shows the CHROMA FRINGE again
on this build.** Almost certainly the fit/timing margin, not the CRT logic: the fringe
is the known clk_dec-over-Fmax artifact (see memory `chroma-edge-fringe-is-upsample-mode`
— fixed once via Quartus physical synthesis lifting Fmax 80→92 MHz; also
`chroma-fringe-is-intermittent`, the placement-sensitive output-path flavor cured by the
registered VGA stage). The CRT branch added logic and both its builds ran with the
uncommitted `SEED 9` working-tree edit (main's committed seed is 7), so the fit moved.
Next session: check TimeQuest clk_dec Fmax in `output_files/DVD.sta.rpt`, try seeds /
FITTER_AGGRESSIVE_ROUTABILITY (memory `quartus-build-flaky-routing`), and consider
LogicLock on the decode chroma path if seed-lottery persists.
Fresh start from `main` — the earlier `feature/crt-composite` /
`feature/analog-crt-output` branches are abandoned dead ends (do not revive them;
their durable findings are honored below and in the `crt-interlace-odd-total-lines`
memory).

---

## 0. HW round 1 (2026-07-05) — raster GOOD, video BLACK; root cause fixed

First flash (`DVD_crt480i_20260705_1043.rbf`): with O[14] on, the **MiSTer menu
rendered correctly on the CRT** — the 15 kHz N64-model raster, the framework csync
path, and the analog routing all work. But playing a clip gave **black video on both
CRT and HDMI** while audio played and the debug overlay showed the pipeline flowing;
forcing Video Standard = PAL (which disables CRT mode) brought video back.

Localization: the framework menu and our debug overlay are injected downstream of the
mixer, so a visible overlay over black video = the MIXER emitting its black default
while the pipeline drains normally. Root cause — a latent CE bug in the pixel queue:

- `xilinx_fifo_dc` registers `valid <= do_read` (and `underflow`) on the **raw**
  `rd_clk` every cycle; the pop is correctly gated (`rd_en && clk_out_en`), so the
  1-cycle valid pulse occupies exactly the cycle after the enabled edge — which with
  the 13.5 MHz CE is **always a disabled cycle**. The CE'd mixer never samples
  `valid=1`, never latches a pixel or position code, and hunts in `STATE_INIT`
  forever — which continuously *drains* the queue, keeping the whole pipeline (and
  audio) flowing while the screen stays black. Latent in every prior mode because
  `clk_out_en` had always been constant 1.
- **Fix (`rtl/mpeg2/pixel_queue.v`):** stretch the read-side `valid`/`underflow`
  pulses across DISABLED cycles only (set on a disabled edge, cleared on any enabled
  edge). When CE≡1 the stretch registers can never set — legacy modes bit-identical
  by construction. `dout` pairs safely with the stretched valid (it only changes on
  pops, which only happen on enabled edges).
- **Proof:** `resample_chain_tb` gained a `+crt=1` mode running the real O[14]
  configuration end-to-end (dot side at CE=½, halfline=429, per-field 262/263,
  field-path emission). With the fix: every field displays its video lines with
  alternating TOP/BOTTOM parity, 0 BLACK. Without it: reproduces the HW black screen.
  The CE≡1 baseline run is unchanged.
- Audited the rest of the dot domain for the same class: `pixel_queue` was the only
  CE'd-read-side FIFO (framestore/vidfeed `fifo_dc`s live in CE≡1 domains); the other
  dot-domain interfaces are levels (resets, CLT BRAM data) or CE'd registers.

Goal: true 2:1-interlaced 480i on a real CRT via the MiSTer analog I/O board
(composite/YC/RGB), with BOTH film (24 fps soft-telecine) and true-interlaced
(30 fps / 60-field) DVDs displaying correctly and staying in A/V sync.

---

## 1. Why the previous attempt failed (HW-proven, do not repeat)

The stock `rtl/mpeg2/syncgen.v` "interlace" only **pulse-delays the vsync edge**
(`v_sync_h_pos = horizontal_halfline` on odd fields) inside fixed, equal-length
fields — the vertical counter reference never moves and the frame total stays even.
On the real CRT that never locked 2:1:

- half-line ON + equal 262/262 → vertical buzz/jitter, no lock
- half-line ON + alternating 262/263 → WORSE (~1.5-line jump: the pulse delay and the
  +1 line ADD instead of composing)
- half-line OFF → stable but 240p-equivalent (both fields on the same scan positions)

The known-good reference on this exact CRT is the N64 core
(`MiSTer-devel/N64_MiSTer/rtl/VI_videoout_sync.vhd`). Its recipe — all three parts
required:

1. **native-width output paced by a gated CE** (not pixel_repetition / 1440-wide);
2. **per-field vtotal alternating 262/263** (odd 525 frame total);
3. **a half-line that shifts the vertical COUNTER reference** (its `vsyncCount`
   samples at `htotal/2` on one field), not just the vsync pulse edge.

## 2. The new timing model (rtl/mpeg2/syncgen.v, DVD-FORK FIX)

Armed by `crt_ilace = interlaced && (horizontal_halfline != 0)`. Every existing mode
writes `halfline=0` when interlaced (the HDMI-480i walk), so legacy behavior is
bit-identical; only the new CRT modeline takes the path. No regfile changes.

- `eff_vertical_length = vertical_length + (crt_ilace && ~odd_field)` — the B field
  is one line longer: 262 + 263 = 525 (odd).
- A per-line **vsync sampler**: the window
  `[vertical_sync_start, vertical_sync_end)` is sampled at dot
  `vs_ref_dot = odd_field ? 0 : halfline`. So vsync is exactly
  `(end−start)` = 3.0 full lines in both fields, and the B field's vsync begins
  mid-line.
- Field mapping derivation: with field A (`odd_field=1`, v_pos even = TOP content,
  262 lines, vsync at dot 0) and B (263 lines, vsync at dot 429), vsync spacing is
  `262 + 0.5 = 262.5` and `263 − 0.5 = 262.5` lines — constant every field, which is
  the whole 2:1 lock. (LA=263/LB=262 would give 263.5/261.5 — wrong; the LONGER field
  must carry the mid-line vsync.) If HW shows the two fields spatially swapped
  (1-line comb), flip BOTH terms (`~odd_field` ↔ `odd_field`) together.
- The old pulse-delay expression remains the non-CRT behavior (bit-identical).

**Sim proof** (`bench/dvd/crt_syncgen_tb.sv`): consecutive vsync rising edges exactly
**225225 dots = 262.5 × 858** apart every field — 225225 is not a multiple of 858, so
constant spacing is only possible with mid-line vsync every other field; this one
invariant proves the half-line, alternating totals, and odd frame total at once.
Also: constant 858-dot hsync, 3.0-line vsync width both fields, 240 active
lines/field with alternating v_pos parity, and the two legacy modes (480p, HDMI-480i
halfline=0) unchanged.

## 3. Native width via CE (emu.sv)

HDMI-480i reaches 15.7 kHz by `pixel_repetition` (1440 dots @ 27 MHz) — non-standard
for a CRT and it squishes the overlay. CRT mode instead paces the whole dot-clock
pipeline with `dot_ce` at **13.5 MHz** (÷2 of clk_sys): 858 native dots/line
@ 13.5 MHz = 63.6 µs = 15.734 kHz. `mpeg2video.dot_ce` was designed for this
(syncgen_intf/mixer/pixel_queue/osd/yuv2rgb are all clk_en'd on it). `CE_PIXEL`
carries the same enable to the framework (2-stage delayed to the registered
`vga_*_q` output stage). Bonus: display fetch bandwidth halves, and the debug
overlay renders un-squished (plain `osd_read.py calibrate` works again).

## 4. Modeline walk (emu.sv) — 4th branch

`O[14] CRT 480i Out` → `crt_eff = status[14] & ~pal_eff` (NTSC-only for now;
PAL 576i CRT = 312/313 totals is a follow-up). `il_eff` now includes `status[14]`
(CRT implies the interlaced field path). Walk branches: PAL / **CRT** / HDMI-il /
progressive. Steps 0–3 are IDENTICAL for CRT and HDMI-480i (720/857 horizontal,
479/261 vertical, 244/247 vsync — the values proven by the HDMI-480i mode); only
step 4 differs: `halfline=429, {clip,pixrep,interlaced}=001` (no pixrep). Trick write
still forces `deinterlace=0`.

## 5. Analog path routing (framework facts, verified)

- `VGA_SCALER` output **forces the scaler onto the VGA connector**
  (`sys_top.v: vga_force_scaler`). It was hardwired 1; CRT mode drives it 0 so the
  analog pins carry the core's native raster. Direct path:
  `core VGA_* → scanlines(ce) → vga_osd → csync_vga / yc_out → VGA pins`.
- `csync_vga` (sys_top) **preserves the core's vsync verbatim** (`csync_vs <= vsync`)
  and adds hsync-rate serration during vsync — it carries the half-line offset fine.
- `VGA_F1` reaches only ascal/HDMI (never the analog path) — kept toggling in CRT
  mode so the HDMI side still bob/weaves a watchable picture simultaneously.
- User side: `MiSTer.ini` `vga_scaler=0`, `forced_scandoubler=0`, `composite_sync=1`
  (+ YC/CVBS options for the specific CRT cable).

## 6. Field-path A/V-sync accounting fixes (the audio-drift blocker)

HW (abandoned branch): in 480i audio drifted AHEAD ~1.3 s over 43 s with the SAME
lates=4/s drops=2/s as the drift-free progressive run → "each drop reclaims ~1.1
refreshes instead of 2". Root cause was never nailed there. This branch identifies
and fixes FOUR ledger errors (all sim-verified by `bench/dvd/gov_field_late_tb.sv`):

1. **Late undercount ×2 (dominant)** — an interlaced late repeat re-scans a FIELD
   PAIR (`last_image TOP → {BOTTOM, TOP}`) = 2 refreshes of slip, but `late_raw`
   fires once per `STATE_REPEAT` visit. `frame_late` is now stretched to 2 cycles on
   pair repeats (`late_ext`), so debt/lates count REFRESHES in both modes (the
   progressive 1:1 contract).
2. **`show_next` flat 2 on the interlaced arm** — an rff soft-telecine frame occupies
   3 field scans (TOP,BOTTOM,TOP) but `cur_show`/`pickup_show` said 2, shorting
   `frame_due`, the vid_err content credit, and telemetry by 1 refresh per rff frame.
   Now mode-aware: interlaced = prog_seq ? (rff? tff?6:4 :2) : (pf&&rff ? 3 : 2);
   the progressive arm is untouched (HW-proven film-3:2 behavior).
3. **`~interlaced` gates on the rff drop debit** (`mpeg2video.v`: frame_drop_ctl
   `drop_cost`, the vid_err drop credit, the row-16 debit discriminator) — dropped:
   an rff frame is 3 refreshes on the field path too (rff=1 implies
   progressive_frame=1, par. 6.3.10, so `rff ? 3 : 2` is mode-independent). A prior
   session removed this gate ALONE and saw no fix — correct but insufficient without
   (1); the ledger needs both sides honest. (Known approximation: a dropped
   progressive_sequence B would be 4/6 fields; DVDs are prog_seq=0.)
4. **`refresh_cnt` wrap (found by the new TB, affects BOTH modes)** — the 4-bit
   counter wrapped at 16 during sustained stalls, making `frame_due` false for
   `cur_show` refreshes after each wrap → ~12% of stall lateness silently
   misclassified as within-cadence holds. Now saturates at 15.

Expected HW signature after the fix: overlay row 17 `vid_err` FLAT (±few) through a
compute crush in 480i, with lates/s ≈ 2×(the old reading) during holds and
drops ≈ lates/cur_show.

## 7. Instruments (measure, don't guess)

- **Row 17 `vid_err` re-added** to `debug_overlay.sv` (NROW 17→18): signed
  wall-minus-content refreshes from `mpeg2video.dbg_vid_err`. Flat = timeline locked;
  climbing = video slipping (audio ahead). `tools/osd_read.py` updated (ROW_LABELS,
  NROW=18, signed-ms rendering at 16.68 ms/unit); `selftest` passes.
- Rows 10 (VBUF|ring), 11 (lates|drops per s), 16 ({drop3,drop2} debit split) carry
  the rest of the diagnosis set from the drift saga.

## 8. HW test plan — ✅ rounds 1–2 done (2026-07-05)

Round 2 user verdict on `DVD_crt480i_v2`: **image on the CRT correct, audio stays in
sync.** Field order was correct as shipped (no `odd_field` flip needed). Remaining
from the list below: the instrumented vid_err-through-a-crush recording (nice-to-have
now that lips are confirmed stable by ear) and the PAL/scaler follow-ups in §9.
Original plan kept for reference:

1. Flash `releases/DVD_crt480i_*.rbf`. HDMI-only sanity first: 480p clip unchanged;
   O9 HDMI-480i unchanged (legacy paths are bit-identical in sim).
2. CRT: `vga_scaler=0`, `composite_sync=1`, O[14] On, true-interlaced clip.
   - Lock check: stable full-height picture, no vertical buzz, scanlines of the two
     fields visibly interleaved (fine raster detail, no line-pairing).
   - If fields spatially swapped (1-px comb on static detail): flip the two
     `odd_field` terms in syncgen.v (see §2) — one candidate polarity, by design.
3. Film clip on CRT: 3:2 field cadence correct (no stutter beat), lips steady.
4. Compute crush (MiB spaceship crash / Matrix lobby) in 480i with overlay on:
   record, `osd_read.py csv`, assert row 17 vid_err FLAT through the crush (the old
   failure ramped 0→0x4D over 43 s), play_err-equivalent = lips constant.
5. A/B O[12] Frame Drop off: vid_err should ramp during crushes (lates hold the
   display) but return flat after — confirms the ledger, isolates the drop path.

## 9. Known limitations / follow-ups

- PAL 576i CRT (312/313 + 50 Hz) — same mechanism, needs its own walk branch + PAL
  vsync line numbers.
- ~~No vertical downscale exists: 4:3 letterbox of 16:9 content and any 240p mode
  would need a new vertical scaler (build once, unlocks both).~~ **DONE for
  Fit/Letterbox/Zoom** — the vertical scaler now exists (`O[4:3] CRT Aspect`,
  `docs/crt_anamorphic.md`, branch `feature/crt-anamorphic-vscale`); 240p is the
  remaining unlock of the same scaler.
- Equalization pulses are not generated (only the framework's hsync-rate serration
  during vsync). The N64 core locks consumer CRTs without them; if a picky set
  hunts, pre/post-eq at 2× line rate inside `csync` would be the next step.
- The syncgen's unused static interlaced modelines (SIF_INTERL/PAL_INTERL/HDTV)
  declare nonzero HALFLINE and would now take the new model if ever enabled —
  intended (the new model is the correct one), noted for completeness.
