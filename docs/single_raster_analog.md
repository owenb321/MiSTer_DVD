# Single-raster analog output — the interlaced main raster drives the CRT

**Status (2026-09-03, branch `feature/single-raster-analog`): ✅ HW-CONFIRMED on the
maintainer's rig — HDMI and the composite CRT both clean, no jumpy image, Main reporting a
steady `720x480i @ 59.9` (build `releases/DVD_n64model_20260903_0148.rbf`, SEED 5,
clk_dec 93.01 @100C / 88.94 @-40C, 88 % ALM, RAM 494/553).**

★ **THE DEFECT WAS THE FIELD-PARITY CORRECTOR, NOT THE SYNC.** Five HW rounds chased sync
shape on a wrong hypothesis; §3.9 is the post-mortem and it is the part of this document
worth reading. The corrector (PR #37, `docs/field_parity.md`) is **DISABLED** pending a
real fix — `par_ins` is tied 0 in `dvd/resample_addrgen.v`. That re-opens the "super
aliased after a chapter skip" coin flip it was written for, so fixing it properly is the
next job; `bench/dvd/field_phase_tb.sv` is the gate that can tell a correct field phase
from an inverted one.

⏳ Still to gate on HW: line-21 captions (moved to `dvd/cc_vbi.sv`), the overlay/HUD and
subtitle geometry on the analog output, sub-720 fill (SIF/VCD/SVCD), Analog Aspect
Letterbox/Crop, PAL, and Progressive-mode film suppression. Checklist in §5.

## 1. The field reports that started it

Two users on the PR #37 prerelease / `v0.4.0 260902`, both on **composite sync**
connections (RGB SCART; YPbPr into a RetroTINK 4K):

- jitter + sawtooth edges in Interlaced/Auto that toggling the mode no longer clears;
- the RT4K seeing pixel clock / **vsync length** / **lines per frame** / frame rate toggle
  about once a second, with tearing/shake — present **at the idle logo** and in playback;
- MiSTer reporting `1441x478i` idle, `1440x480i` playing, frame rate "59.8 <-> 60.1";
- Progressive mode stable in the menus, **signal lost when the feature starts**;
- composite and S-video stable (S-video "blocky"); toggling `Video Output` can "crash".

Every previous HW confirmation of the fieldpass raster had been on the YC/composite path
or HDMI. The csync / sync-on-Y path had never been gated. gregSTORM (composite) saw none
of it.

## 2. What the code said (findings)

| Symptom | Mechanism (file:line at the time) | Fixed by |
|---|---|---|
| `1441x478i` idle | DE window = `min(modeline, stream size)`; with no sequence header the modeline fallback showed through, and it carried two off-by-ones: H resolution pixrep-doubled as `{720,1'b1}` = 1441 (`syncgen_intf.v`), interlaced VER_RES 479 → 239/field = 478 (`emu.sv` walk). Also flipped after every decoder soft reset ⇒ Main resolution popup + `video_mode_adjust`. | §3.6 |
| "59.8 <-> 60.1 Hz" | No half-line on the main raster ⇒ vsync-to-vsync alternated 262/263 lines; Main measures per vsync. With `vsync_adjust` the HDMI PLL was set 0.2 % off. | §3.1 |
| Progressive loses signal | `filmp_eff = film_want & ~interlaced_eff` wrote the 875×1287 @ 23.976 Hz / 30.9 kHz film modeline to the analog pins. | §3.5 |
| periodic sync events | `re_interlace` in HUNT emitted **no sync at all** (33–67 ms of dead CRT sync per drop). Triggers found: (1) `syncgen_intf`'s modeline copies were on `dot_rst`, which the **watchdog** and mount soft reset pulse — `sync_reg` zeroes them async, so the running `sync_gen` saw `horizontal_length=0 / interlaced=0` for a few dots and re-phased (cadence 0.41 s + 0.83 s holdoff ≈ 1.2 s at 81 MHz); (2) `pal_eff` live off the decoded `vertical_size` (0 after any reset); (3) `analog_want` combinational off Main's live `cfg` word (re-sent on every `video_mode_adjust`, OSD leave, `[video=…]` re-parse) while the comment claimed a latch. | §3.2–3.4, §3.7 |
| per-field toggling on csync | The framework `csync` serrates at **line rate** (an hsync-width pulse one hsync period ahead of each hsync, no equalizing pulses), so the two fields — whose vsyncs start half a line apart — present broad pulses of **~50 µs and ~18 µs**. 18 µs is at or below the threshold of a width-based sync separator: a set can lock a line late on one field or flip between the two readings field to field. **Measured** by `bench/dvd/csync_field_tb.sv`. | §3.8 |

And the design-level finding that made the rest simple:

**The "half-line on the main raster makes HDMI hunt" rule was stale.** It came from
`ff01ac8`, observed on the OLD upstream pulse-delay half-line (a mid-line vsync EDGE
inside two equal 262-line fields = 262.5/261.5 alternating spacing — which hunts on
anything and never locked 2:1 on a CRT either, `docs/crt_480i.md` §1). The N64-model
half-line (`rtl/mpeg2/syncgen.v`, alternating 262/263 totals + a shifted vsync COUNTER
reference) is exact, was HW-proven on the CRT, and already ran on the main raster with
HDMI alongside in the `O[14]` rounds without hunting. ascal reads `VGA_F1` and the vsync
edge and counts lines from DE; every other 480i core feeds it exactly this.

## 3. What changed

### 3.1 The half-line is on the main raster — the N64 model
`dvd/emu.sv`'s interlaced modeline writes `halfline = 429` (NTSC) / `432` (PAL), which
`syncgen_intf` doubles under pixel repetition as **2x** (not the upstream `2x+1`) to
858 / 864 = exactly half the line. With the alternating 262/263 field totals that puts
vsync edges exactly **262.5 lines apart every field**: the two fields interleave on a CRT,
and Main measures one constant 59.94 Hz instead of alternating 59.83 / 60.05.

This is what the N64 and PSX cores do — one raster carrying the half-line, feeding both
the framework scaler and the analog pins — and `rtl/mpeg2/syncgen.v`'s interlace model was
copied from `N64_MiSTer/rtl/VI_videoout_sync.vhd` in the first place. ⚠ Rounds 3–5 briefly
wrote `halfline = 0` here and synthesised the half-line downstream in `sys_top`'s `csync`
instead, on the theory that a half-line on the main raster combs ascal's weave. **That was
wrong** (§3.9); both detours are reverted and `csync` is the stock module again.

### 3.2 The second raster is gone
`dvd/re_interlace.sv` (383 lines, a 4096×24 line buffer ≈ 10 M10K, a second `sync_gen`
the fitter duplicated for routability, and the HUNT/ARM/RUN lock FSM that dropped sync
on any hiccup) is deleted with `bench/dvd/re_interlace_tb.sv`. `sys/sys_top.v` lost the
whole additive VGA2 block (ports, `sync_fix` ×2, second scanlines stage, the OSD-input
mux) — the analog chain is the stock wiring again. The pins take the main raster like
every other 480i core; the only waveform difference from before is 1440 pixel-repeated
dots at 27 MHz instead of 720 at a 13.5 MHz enable, which the 27 MHz DAC renders
identically. The second raster's one justification (progressive HDMI beside a CRT) was
already dropped by the Video Output consolidation.

### 3.3 Framework-facing pixel enable: Main reports 720x480i
Pixel repetition stays inside the mixer (each pair is identical) and the overlays already
draw per pair (`ov_h_gen`/`sp_qx` halve `h_pos` under `il_eff`). Only what the framework
sees changed: `CE_PIXEL = interlaced_eff ? ce_pix_q : 1` where `ce_pix_q` is high on the
first clock of each pair, registered with the `vga_*_q` output stage. `hps_io` counts 720
active dots, ascal samples 720 real pixels, the analog chain (which never used the enable
for data — `vga_out.sv` has no ce; only the scanlines stage does) is bit-identical.
`cc_e2e_tb` asserts 720 enables per 1440-clock DE line. NOT done: native 13.5 MHz dot
pacing (the old `O[14]` `dot_ce`) — every overlay query-lead constant (HUD, seek bar,
idle logo, subtitles) assumes one dot per clock; re-tuning six modules for no visible
gain. Recorded as a follow-up.

### 3.4 Line-21 captions ride the main raster's VBI
The ten lines of coordinate glue moved from `re_interlace` into **`dvd/cc_vbi.sv`**
(kept as a module so `bench/dvd/cc_e2e_tb.sv` drives the REAL wiring — the round-3
implicit-net lesson). Same derivations: enable on one clock of each pixrep pair with
`hpos = h_pos >> 1`; line 21 = `v_cntr == 261`; field 1 = `~v_pos[0]`. The `emu.sv`
output stage paints the caption level on R/G/B outside DE and black elsewhere, so the
stock `de_emu ? data : 0` gate on `sys_top.v`'s VGA scanlines stage could be dropped
(the same gate killed the feature once on the VGA2 path). ascal captures only inside DE
and never sees the VBI waveform.

### 3.5 Raster hardening (the "every second" triggers)
- **Watchdog decoupled from the raster** (`rtl/mpeg2/mpeg2video.v`): `syncgen_intf`'s
  modeline copies now reset on `dot_hard_rst` (hard reset re-synchronised to the dot
  clock), matching the regfile the watchdog already spares. `modeline_boot_tb` phase
  [4] pulses `watchdog_rst` mid-field: RED with the old wiring (2 of 7 spacings wrong),
  GREEN with the fix (0 of 7), regfile modeline intact both ways.
- **`pal_eff` holds** while `vertical_size == 0` (`emu.sv`): a PAL disc no longer reads
  NTSC through a watchdog/mount gap (which re-fired the walk twice and moved the STC
  tick rate). Cleared by `reset_n` only.
- **`analog_want` latched** (`emu.sv`, `sys/hps_io.sv` exports `cfg_seen`/`cfg_wr`):
  follows Main's cfg word while nothing is mounted (so a boot-time `[video=…]`
  re-parse is honoured), frozen while a disc plays. Auto is now genuinely boot/idle
  static; `il_switch` fires only on an OSD edit or a change made with nothing mounted.
- **Progressive + analog-direct suppresses the film raster**:
  `filmp_eff = film_want & ~interlaced_eff & ~analog_want`. An HDMI-only rig
  (`vga_scaler=1` or no analog ini bits) keeps Film 24p exactly as before. Replaces the
  manual's "set Film 24p Off" gotcha.

### 3.6 Idle window off-by-ones
Interlaced VER_RES 479 → 480 (PAL 575 → 576) in the walk; `horizontal_resolution`
pixrep doubling `{x,1'b1}` → `{x,1'b0}`. DE-window only. Idle now reports `720x480i`
like playback, and the load-time resolution popup (which also re-sends `cfg`) is gone.

### 3.7 Release-visible diagnostic (no CONF_STR change)
The `O[2]` diagnostic blocks gained a THIRD ROW (v 62..78) shown whenever `O[2]` is On
and the fields raster is up — menus or not — so a reporter on a CRT can read it. GREEN =
the event has fired since the diagnostic was switched on (or the last load/seek flush):
blk9 decoder watchdog expiry · blk10 `il_switch` · blk11 `pal_eff` changed · blk12
`vertical_size` read 0 · blk13 Main re-wrote `cfg` after its first write (informational:
OSD leave, `video_mode_adjust`, video-section re-parse). None of the first four should
ever fire during steady playback.

### 3.8 Sync shape: what was measured, and what ships
`bench/dvd/csync_field_tb.sv` drives the REAL `sys_top.v` `csync` (extracted at run time)
from the shipped modeline and reads the pin with two sync-separator models — an RC
integrator and a broad-pulse width detector.

What ships is the **stock** module: line-rate serrations, no equalizing pulses, the
half-line coming from the raster. Measured at the pin: sync events one frame apart to the
dot (449837 + 451063 = 900900), i.e. 262.5 lines per field — the interlace contract, which
is what the bench gates.

Reported but **not** gated: with line-rate serrations the two fields necessarily present
different broad pulses (~50 µs and ~18 µs), because their vsyncs start half a line apart
while the serration grid does not move with them. 18 µs is at the threshold of a
width-based separator, which is a plausible mechanism for the RetroTINK "vsync length /
lines-per-frame toggling" report. Serrating at **2H** equalises it (27 µs / 27 µs, and the
integrator asymmetry drops from 0.13 line to 0.02) — that variant was built and then
reverted because the composite CRT that is the reference display for this path was worse
with it. It is two lines in `csync` if a rig that needs it turns up:
set `csync_hs` at `line_len - half_len` and clear it `hs_len` later, with
`half_len = (h_cnt + hs_len) >> 1` (⚠ `h_cnt` resets on BOTH hsync edges, so at the rising
edge it holds `line − hs_len`; `h_cnt >> 1` is 63 clocks early and re-breaks the symmetry —
the bench catches that).

### 3.9 Post-mortem: five rounds spent on the wrong layer
**Symptom.** Interlaced output jumped at field rate and looked blockier than the previous
release; HDMI Weave combed on a **still**, and consecutive bob frames of a still differed
by 3.5 px at 1080p (one field line = 4.5 px; a still should show zero).

**What it actually was.** The field-parity corrector was making both displayed fields
carry the **same source lines**. Measured from screenshots by splitting each woven frame
into its two fields and correlating them:

| build | field-to-field offset |
|---|---|
| v0.3.0 `Analog Out = Native Fields` (no corrector) | **+0.50** frame lines — correct interleave |
| round 1 (half-line on raster, corrector on) | **+0.00** |
| round 4 (half-line on csync, corrector on) | **+0.00** |
| corrector disabled | clean on HW, both outputs |

**How five rounds went by without seeing it.** The `ff01ac8` note ("a half-line on the main
raster makes an HDMI receiver hunt — brightness pulse + scanline comb") fit the weave
screenshot exactly, so the half-line became the suspect and stayed the suspect. The
disproof was already in hand after round 4 — that build had **no** half-line on the main
raster and still combed — and it was not acted on. The variable that actually moved
between every combed capture and every clean one was the corrector.

★ **Rules this earns.**
1. When a build changes X and the symptom persists, X is exonerated — say so out loud and
   move the suspect list, rather than refining the theory around X.
2. A user's "does the old build do this?" A/B is worth more than any amount of RTL
   reading: v0.3.0 Native Fields (same content path, no corrector) settled it in one shot.
3. Prefer measuring the artefact to reasoning about it. Splitting the screenshots into
   fields and correlating them took minutes and gave a number that no hypothesis survived.
4. ⚠ **`bench/dvd/field_parity_tb.sv` could not see this defect**, for two reasons worth
   knowing before trusting any bench: its behavioural framestore returns a **constant
   word**, so no displayed pixel carries evidence of which source line it came from; and
   its pass condition is the **same expression** as the RTL's own `frame_top_par_err`, so
   it restates the design's convention instead of checking an external one. CLAUDE.md
   already warns about golden models that agree suspiciously well with their RTL (the
   POST-only PGC case) — same trap, different corner. `bench/dvd/field_phase_tb.sv` is the
   replacement: address-derived framestore content, per-field hashes of what the mixer
   actually emitted, and the invariant that consecutive fields must DIFFER and repeat with
   period 2.

## 4. Tests

| Bench | What it proves |
|---|---|
| `bench/dvd/crt_syncgen_tb.sv` PHASE 2c (new) | the shipped raster (pixrep, halfline 0→1): field pair exactly 900900 clk27, line-aligned vsync in both fields, 3.0-line width, 240 lines/field with alternating parity; PHASES 1/2/2b/3/4/5 unchanged |
| `bench/dvd/csync_field_tb.sv` + `run_csync_field.sh` (new) | the REAL `sys_top.v` `csync` (extracted at run time) fed the shipped LINE-ALIGNED raster: it must synthesise a 262.5-line analog sync, with a ≥ standard first broad pulse in both fields and both separator models in tolerance — i.e. this bench is the proof that the pins get true 2:1 interlace; `run_csync_sweep.sh` sweeps tau (`+tau_us`) |
| `bench/dvd/modeline_boot_tb.sv` [4] (new) + `run_modeline_boot.sh --red` | REAL `reset.v` + `regfile.v` + `syncgen_intf` + `sync_gen`: a watchdog pulse leaves vsync spacing at 450450 (GREEN) / breaks it with the old `dot_rst` wiring (RED); the boot-race phases updated to the new walk values |
| `bench/dvd/cc_e2e_tb.sv` (rewritten) | REAL `sync_gen` + REAL `cc_vbi` + a copy of the output stage: captions demodulated at the pins, line 21 (17 H after the vsync edge), correct field slots, 720 enables per 1440-clock DE line |
| `cc_line21_tb`, `cc_field_map_tb` | unchanged, green |
| `bench/dvd/run_field_parity.sh` | unchanged, green (the corrector never touched the raster) |
| `resample_chain_tb +crt=1 / +sif=1 / +hfill=1 / +il=1 +wide=1` | display chain over the changed `syncgen.v` |

## 5. HW checklist

- [ ] HDMI, Interlaced: stable 480i, Main reports `720x480i @ 59.94` steady, no hunting,
      with and without `vsync_adjust`; OB Bob/Weave both fine.
- [ ] Composite CRT (gregSTORM's rig): unregressed; CC Test Line and real captions decode.
- [ ] RGBS SCART + YPbPr + RetroTINK 4K (the reporters): no periodic shake at the idle logo
      or in play; no sawtooth; RT4K readouts steady; `O[2]` third row stays red.
- [ ] Progressive with the analog ini bits: stays 480p when a film title starts.
- [ ] PAL disc over HDMI 576i unregressed (analog PAL still unconfirmed — no PAL CRT).
- [ ] Idle logo reports `720x480i`; no resolution popup on disc load.
- [ ] Toggling `Video Output` mid-title: the chapter-seek-style interruption, then clean.

## 6. Follow-ups
- Done in round 2 (user decision): the idle logo moves on every FIELD tick in Interlaced
  (`dvd/idle_logo.sv`; the old every-other-field divider made it half speed on the CRT).
- Native 13.5 MHz dot pacing (720-wide internally) — only if a reason appears; needs the
  overlay query-lead constants re-tuned (`HUD_QX_ADJ`, `BAR_QX_ADJ`, `LOGO_QX_LEAD`,
  `SP_QX_ADJ`, `crt_ov_map`, `cc_vbi`).
- Apply the analog half-line to `VGA_VS` as well when `csync_en` is low, for RGBHV rigs
  (§3.9) — nobody has reported one, so it is unbuilt.
- Equalizing pulses outside vsync (needs the vsync position in advance — a 3-line video
  delay or a hint from the modeline walk) if a set still hunts with 2H serrations.
- Progressive 480p on the analog pins keeps the dot-0 vsync reference (no field
  ambiguity there); anchoring it too is a one-line follow-up if a 31 kHz display objects.
