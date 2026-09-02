# Interlaced Out: Auto — native 480i/576i fields for true-interlaced video

**Status: ⛔ SUPERSEDED (2026-09-02, branch `feature/video-output-consolidation`) — the
`O[10:9] Interlaced Out` option and its `det_video` auto-detector are REMOVED.** The
settings surface collapsed to one `O[10:9] Video Output = Auto/Interlaced/Progressive`
control: `Interlaced` is the old "Native Fields" behavior (authored fields session-wide;
HDMI 480i via ascal — the same picture Interlaced Out=On gave an HDMI rig), `Auto` is
ini-driven and boot-static, and the mid-title `Auto` content detector died with its known
audio-skew problem. The fields RASTER this doc designed (the il_eff modeline branch,
syncgen behavior, VGA_F1/ascal handling, the mid-stream `il_switch` flush) **still ships
unchanged** and is what Video Output=Interlaced engages — only the option surface and the
detector are gone. Rationale + field reports: `docs/field_parity.md`,
`docs/analog_dual_raster.md` status, roadmap "Video Output consolidation". The body below
is kept as the engineering history of the raster design.

*(Historical status at supersession:)* ✅ HW-CONFIRMED + MERGED (PR fj#132, 2026-07-27) — `On`/`Off` shipped; `Auto` parked opt-in.
Sim-verified: `bench/dvd/film_detect_tb.sv` (extended with `det_video` cases). HW round 1–2
(2026-07-26/27): interlaced detection + mode switching work, and **`On`/`Off` both play with
correct A/V sync (HW-confirmed)** — but **`Auto`'s mid-title switch still leaves audio
slightly out of sync** even after the full seek-style re-sync flush (§4), so the **default is
`Off`** and **`Auto` is kept as an opt-in to revisit later**. Two known issues remain open:
the residual Auto-switch audio skew, and the overlay/OSD horizontal squish in interlaced mode
(see "Open follow-ups").

## Problem

Interlaced DVD content (NTSC 29.97i, PAL 25i) was played back as a **progressive**
signal. The decoder's reset defaults (`deinterlace=1, interlaced=0`) **weave** both fields
of an interlaced frame into one progressive image, so only 30 (NTSC) / 25 (PAL) distinct
frames per second reach the display — the 60/50-field motion is thrown away, giving
juddery motion on true video-sourced content.

The manual `O9 Interlaced Out = On` already fixed NTSC (native 480i fields + `VGA_F1`,
ascal deinterlaces via `O11` Bob/Weave), but:

1. it was **manual** — the user had to know to set it;
2. it only took effect if set **before** loading the ISO — flipping it live during
   playback left the raster progressive (see "Mid-stream switch" below);
3. **PAL was hard-gated to progressive** — no 576i fields path existed at all.

## What ships

- **`O[10:9] Interlaced Out` — 3-way `Off / Auto / On`** (index 0 = **Off = power-on
  default**).
  - **Off (default):** force progressive weave (the original behaviour).
  - **Auto (opt-in, revisit):** engage native interlaced fields when the content is detected
    as true-interlaced video; otherwise progressive. **Currently leaves audio slightly out
    of sync at the mid-title switch — not the default until that's resolved.**
  - **On:** force native interlaced always (plays A/V-synced, since the mode is fixed at
    load with no mid-title switch).
- **NTSC 480i and PAL 576i**, both to HDMI via ascal (fields + `VGA_F1`; `O11` picks
  Bob/Weave). PAL 576i on the **analog CRT** pins is now handled by the dual-raster
  re-interlacer (`docs/analog_dual_raster.md`, 2026-07-29) — no longer a follow-up here.
  **NOTE (dual raster):** while the analog raster is engaged in a DERIVE mode
  (`Analog Out = Auto/Interlaced`), Interlaced Out is FORCED OFF — the re-interlacer
  needs the standard progressive main raster. **`Analog Out = Native Fields`
  (2026-08-22) is the field-passthrough follow-up** and does the opposite: it forces
  `il_eff` on for the session so the re-interlacer re-times authored fields 1:1.
  That is the supported way to get native fields with an analog TV configured, and
  it is the structural fix for the field-pairing defect (the weave frames do carry
  both fields, but only the PAIRING decides whether the viewer sees a coherent
  picture, and governor lates re-randomise it ~4x/s). See docs/analog_dual_raster.md.
- **Live mid-stream switching works** — the Auto verdict lands ~1.7 s into playback, so
  the switch is inherently mid-title; it re-locks the decoder cleanly.

## Design

### 1. Detector — `det_video` (standard-neutral true-interlaced verdict)

`dvd/resample_addrgen.v` already runs a per-display-pickup confidence FSM that produces
the film verdicts `det_ntsc` / `det_pal` (for Film 24p/25p Auto). We add a third counter,
`det_video`, symmetric to the PAL film counter but keyed on the **opposite** sense of the
progressive flag:

- **up** (`UP_STEP`) on `!progressive_frame` (an interlaced-coded frame = true video);
- **down hard** (`DN_HARD`) on any `progressive_frame` frame;
- same hysteresis as the film verdicts (`ENGAGE_TH=120` ≈ 40 confirming frames ≈ 1.7 s;
  `DISENGAGE_TH=24`, deep).

It is **standard-neutral** — it keys only on `progressive_frame`, so one verdict covers
both NTSC 480i and PAL 576i. It is **mutually exclusive** with `det_ntsc`/`det_pal` by
construction: film needs `progressive_frame==1`, video needs `progressive_frame==0`, so
they can never co-assert (guarded continuously in the testbench).

The verdict is plumbed up `resample_addrgen → resample.v → mpeg2video.v` (output port),
then 2-FF synced clk_dec→clk_sys in `emu.sv` as `il_det_sync` (same pattern as
`film_det_*_sync`).

**Known edge case:** *hard-telecine* film (3:2 baked into a 29.97i stream —
`progressive_frame==0`, no rff) reads as video and gets Bob-deinterlaced at field rate.
This is acceptable and watchable; no inverse-telecine is attempted (the same content the
film detector already admits it can't see — see `docs/film_24p_plan.md` §9a).

### 2. Mode resolve (`emu.sv`)

```
wire [1:0] il_mode = status[10:9];                                  // 0=Auto 1=Off 2=On
wire       il_want = (il_mode==2) | ((il_mode==0) & il_det_sync);   // On, or Auto+detected
wire       il_eff  = (il_want | crt_eff) & ~filmp_eff;              // film still wins
```

> ⚠ **Stale snippet (kept for the design history).** `crt_eff` — the O[14] whole-core
> CRT mode — was retired by the dual-raster rework (PR fj#146). The shipping expression
> is now `il_eff = analog_fields | (il_want & ~filmp_eff & ~analog_eff)`: an analog TV
> in a DERIVE mode forces it off, and `Analog Out = Native Fields` forces it on.
> See `dvd/emu.sv` and `docs/analog_dual_raster.md`.

The old `& ~pal_eff` gate is **removed** — PAL can now go interlaced. `crt_eff` already
excludes PAL, so a PAL CRT request doesn't force HDMI-576i; PAL interlaced comes only from
`il_want`. Film (soft-telecine/25p → `filmp_eff`) still wins (a frame can't be both a
progressive-film raster and interlaced).

`VGA_F1`, `HDMI_BOB_DEINT`, and the modeline walk all key off `il_eff`, so they follow
automatically.

### 3. PAL 576i modeline branch

Only two steps of the runtime modeline walk change (`emu.sv`), adding a `pal_prev &&
il_prev` case; everything else is shared with the existing PAL/NTSC branches:

- **VER** (`REG_WR_VER`): `vertical_resolution=575` (syncgen halves → 287 active
  lines/field, mirroring NTSC's 479→239), `vertical_length=311` → **312 lines/field**.
  With HOR 863 pixel-repetition-doubled to 1728 dots/line: 27 MHz / (1728 × 312) =
  **50.06 fields/s** (~50 Hz; 312.5 would be exact — 312 is the closer integer).
- **VER_SYNC** (`REG_WR_VER_SYNC`): per-field vsync `292..295` (≈4-line front porch after
  288 active, 3-line sync, inside the 288..311 field blanking — analogous to NTSC 480i's
  244..247 inside 240..261).
- **HOR / HOR_SYNC / VID_MODE / TRICK** need **no** PAL-specific case: HOR already writes
  the PAL 863 total for any `pal_prev`; `VID_MODE` reuses the `il_prev` branch (halfline 0,
  `pixrep+interlaced`), and TRICK reuses `il_prev` (deinterlace 0). pixel_repetition doubles
  863→1728 → 15.625 kHz PAL line rate.

> ⚠️ The PAL 576i vertical totals (312 lines/field, vsync 292..295) are derived by
> analogy to the NTSC 480i branch and **need HW confirmation** — verify the field rate
> locks on a receiver and the active region isn't cropped/spilled (the codebase has a
> history of interlaced off-by-one strobe/spill bugs; see `docs/history.md`).

### 4. ★ Mid-stream switch (the key HW fix)

**Symptom:** flipping `O9` live during playback left the output progressive; setting it
before load worked. The modeline walk *does* re-kick on a live change, but the
decoder/ascal keep running in the old raster — "set before load" works because the whole
pipeline cold-starts into the mode.

**Fix:** on any `il_eff` edge (`il_switch`), fire the **full seek-equivalent flush** — the
same three coordinated resets a chapter seek uses:

- `seek_flush` → `vbuf_flush` : the decoder discards its buffered bitstream and re-locks on
  the next sequence header, picking up the new `interlaced`/`deinterlace` registers (the
  raster actually changes).
- `load_flush` → `pipe_rst_n` : resets `ps_demux`/`ac3_reframer` **and av_sync (a fresh STC
  anchor)**, and re-arms the STD mux-lead hold so the first post-switch frame is deferred
  until audio catches up.
- `aud_flush` → `aud_rst_n` : resets `audio_ring` + `dvd_audio_decode`, discarding the
  queued audio backlog so it re-phases to the new video position.

Because the detector hysteresis is deep, Auto fires this ~once per title, so the brief
(~1 s) re-lock glitch is acceptable. This also fixes the live manual On/Off toggle.
`il_switch` bypasses `keep_vbuf` (a mode switch always needs the flush).

**Why the VBUF flush alone was not enough (2026-07-26 HW round 1):** the first version
pulsed only `seek_flush`. That jumped video ~1 s **forward** (discarded the decode-ahead
buffer) while audio kept its backlog and av_sync kept its old anchor — av_sync only
re-anchors on a **demux** `vid_pts` jump, and the demux front is *continuous* through a
VBUF flush, so no re-anchor fired. Result: **audio ran ~1 s late under Auto**, while On/Off
(which never flush mid-stream) stayed synced. Adding `load_flush` (fresh STC anchor + STD
mux-lead hold) and `aud_flush` (discard the audio backlog) makes the switch a true
seek-style re-sync — the exact HW-confirmed-synced path a chapter seek takes. The only
difference from a real seek is that the reader doesn't jump, so `ps_demux` re-hunts to the
next pack boundary inside the VBUF re-lock glitch (recovered by the vbuf flush — the
round-1 green-frame caveat in the audio-only-switch path does not apply because we DO
re-lock the decoder here).

## A/V sync / governor

No governor changes needed. Both NTSC (480p 60 / 480i 60-field) and PAL (576p 50 /
576i 50-field) present ~60 / ~50 refresh ticks per second regardless of progressive-vs-
interlaced, so the existing `refresh_60hz`/`refresh_50hz` STC rates and the HW-confirmed
480i field-path ledger fixes (PR fj#65) apply to 576i unchanged (they key on `interlaced`,
not on NTSC-specific values).

## Files

- `dvd/resample_addrgen.v` — `det_video` port + confidence FSM.
- `rtl/mpeg2/resample.v`, `rtl/mpeg2/mpeg2video.v` — thread `det_video` up.
- `dvd/emu.sv` — `O[10:9]` menu, `il_mode`/`il_want`/`il_eff` resolve (drop `~pal_eff`),
  `il_det_sync` CDC, PAL 576i modeline branch, `il_switch` re-lock flush.
- `bench/dvd/film_detect_tb.sv` — extended: `det_video` engages only on interlaced,
  never co-asserts with a film verdict.

## Open follow-ups

### ✅ FIXED 2026-08-22 — Overlay/OSD horizontal squish in interlaced mode (was: HW round 1, 2026-07-26)

**Fixed** along with `Analog Out = Native Fields`, which made it a hard requirement
(a CRT user's menus and subtitles are the point). `dvd/emu.sv` now derives `ov_h_gen`
(and, exactly, `sp_qx`) as `il_eff ? h_pos>>1 : h_pos` and feeds every overlay
consumer from it; `spu_decode.interlaced` and `crt_ov_map.interlaced` follow `il_eff`
instead of being tied `1'b0`, so their +2 field-line row-base walk finally engages.
Progressive output is bit-identical. The framework's own OSD on the analog chain was
never affected (sys_top draws it AFTER re-interlacing, where the line is 858 dots
again); an HDMI-side framework OSD in this mode would still need a `sys/` change.
Original analysis below.


**Symptom:** with interlaced output enabled (Auto-engaged or On), the OSD, subtitles, and
menu-button highlights are **squished into the left half** of the screen.

**Cause:** the interlaced modeline uses **pixel_repetition** (`VID_MODE` bit), which doubles
the horizontal raster — NTSC 858→1716, PAL 864→1728 dots/line, active region ~1440 (720
source pixels × 2). But every overlay layer queries its position in **raster** coordinates
(`h_pos`) at the display tap in `emu.sv`, and their rects/offsets are authored in **720-wide
source space**: `subpic_blend` (subpicture bitmap query + HLI button-rect compare) and
`transport_hud` (`X0`/`hx` glyph placement, [transport_hud.sv:361](dvd/transport_hud.sv#L361)).
So in pixrep mode each source column spans 2 raster dots and a 720-based x lands at raster
x/2 → the overlay occupies only the left half. Progressive mode is unaffected (no pixrep).

**Fix direction:** map the overlay's horizontal coordinate raster→source when pixrep is
active — i.e. feed the overlay `h_pos >> 1` (uniform ×2, so a shift suffices) instead of a
Bresenham inverse. There is a precedent to extend rather than reinvent:
[`dvd/crt_ov_map.sv`](dvd/crt_ov_map.sv) already inverse-maps raster→source for the CRT
anamorphic Letterbox/Crop modes (see memory `crt-overlay-aspect-align`). The clean approach
is a single mode-aware horizontal map (`pixrep ? h_pos>>1 : h_pos`, composed with the
existing CRT map where both apply) feeding the shared overlay coordinate. Must keep
**progressive byte-identical** and verify the CRT-480i path (also pixrep-free — native
13.5 MHz dot CE, not pixel repetition — so its overlay is already 1:1 and must stay so).
Note the HDMI-480i O9 half-width subtitle caveat already mentioned for the HUD
(`docs/transport_hud.md`) is the same root issue.

**Vertical:** interlaced halves the display to fields; confirm the overlay's `v_pos` handling
(field parity) still lands rows correctly — the HUD/subpic pipelines were proven field-order
identical for CRT-480i, so this is likely fine, but re-check on HDMI-480i/576i.

## HW gate

- [ ] An **NTSC** video-sourced DVD boots progressive, then flips to smooth 60-field 480i
  within ~2 s with one brief re-lock (Auto).
- [ ] A **PAL** video-sourced DVD does the same into 576i @ ~50 fields; the receiver locks
  and the active region is uncropped.
- [ ] NTSC-film and PAL-film DVDs **never** engage the interlaced path (stay on
  progressive / Film 24p-25p).
- [ ] Live manual `O9 On`/`Off` mid-play now takes effect.
- [ ] `Off` reproduces the previous progressive-weave behaviour exactly.
