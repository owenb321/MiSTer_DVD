# Single-raster analog output — the interlaced main raster drives the CRT

**Status (2026-09-03, branch `feature/single-raster-analog`): sim-proven (every suite
below green). **HW rounds 1–3 found and fixed the real defect: a half-line on the MAIN
raster combs the scaler's weave (§3.9) — the `ff01ac8` note was right and this branch had
overturned it.** Round 4 keeps the main raster line-aligned for ascal and applies the 2:1
half-line to the ANALOG composite sync only, in `sys_top`'s `csync`. One raster, one
picture, two sync flavours. ⏳ HW-confirm pending. Gate = the two RGBS / YPbPr
field reports below reproduce clean (idle logo AND playback), gregSTORM's composite CRT
and the HDMI 480i path unregressed, Main reporting `720x480i @ 59.94` steady.**

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

### 3.1 Where the 2:1 half-line lives
An interlaced CRT needs the second field's vertical sync half a line later than the
first's — that is what interleaves the fields. **It must not be on the main raster**
(§3.9): ascal registers the two fields against each other wrongly when it is. So:

- the **main raster** keeps `halfline = 0` in the modeline (`syncgen_intf`'s upstream
  `2x+1` pixrep doubling makes it 1, a one-dot reference shift = line-aligned both
  fields), exactly as v0.3.0 Native Fields and v0.4.0 shipped it;
- the **analog composite sync** gets the true half-line in `sys/sys_top.v`'s `csync`,
  which delays the vsync edge by an exact half-line countdown on the field `VGA_F1`
  marks as lower. New `emu` output `VGA_ILACE` enables it.

Measured at the pin (`csync_field_tb`): the raster's vsyncs are a whole 262/263 lines
apart, while the analog sync events are 450451/450449 clk27 = 262.5 lines apart. One
raster and one picture serve the scaler and a CRT with the sync each needs.

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

### 3.8 Serrations at 2H in the fork's `csync` (`sys/sys_top.v`)
The framework `csync` serrates at LINE rate and has no equalizing pulses. On an
interlaced raster one field's vsync begins at an hsync and the other's begins mid-line,
but the serrations sit on the same line grid either way — so the two fields present
**different broad pulses**: ~50 µs and ~18 µs measured. 18 µs is at or below the
threshold of a width-based sync separator, which is the shape of the RetroTINK report
(vsync length and lines-per-frame toggling). The fork's `csync` now adds a serration
half a line before each stock one, so both fields present the standard ~27 µs broad
pulse:

| | first broad pulse A / B | width detector | RC integrator (40 µs) |
|---|---|---|---|
| stock 1H serrations | 50 µs / 18 µs | 449837 / 451063 (±0.36 line) | 450172 / 450728 |
| **2H serrations** | 27 µs / 27 µs | 450451 / 450449 | 450384 / 450516 |

⚠ `half_len` is `(h_cnt + hs_len) >> 1`: `h_cnt` resets on BOTH hsync edges, so at the
rising edge it holds `line − hs_len`. Using `h_cnt >> 1` puts the extra serration 63
clocks early and re-breaks the per-field symmetry — the bench catches it (measured
20 µs / 29 µs broad pulses when that was tried).

`csync_field_tb` gates both separator models. Equalizing pulses outside vsync are still
not generated (they need the vsync position in advance); no console core has them.

### 3.9 HW rounds 1–3 — the half-line belongs on the analog sync, not the raster
Round 1 put the half-line on the main raster (and, separately, anchored the vsync on the
hsync edge). On the maintainer's composite CRT the picture **bounced at field rate and
looked blockier**; round 2 (2H serrations) changed nothing; round 3 (vsync anchoring
reverted) changed nothing. Then the decisive evidence arrived — **HDMI showed it too**:

- **Weave on a still combed**, lines visible through the tops of letters;
- consecutive **bob** frames of a still differed by **3.5 px at 1080p** (one 480i field
  line is 4.5 px, one frame line 2.25 px). On a still, correct bob renders both fields at
  the same apparent position, so any visible shift means the fields are misregistered.
- **v0.3.0 `Analog Out = Native Fields` — the same authored-fields content path, on a
  line-aligned raster — is CLEAN on the same disc.**

The content path is byte-identical between those builds (`VGA_F1`,
`dvd/resample_addrgen.v` and `rtl/mpeg2/mixer.v` are untouched by this branch), so the
only interlace-relevant difference was the main raster's half-line. **`ff01ac8` was
recording a real effect** — its note says "scanline comb", which is exactly the weave
screenshot — and this branch had dismissed it as an artefact of the old pulse-delay
implementation. It is not: ascal weaves and bobs from `VGA_F1` and counts lines from DE,
and a genuine half-line on its input breaks that registration whatever the sync
generator's internal model is.

Fix: §3.1. The scaler gets the raster it wants; the CRT gets its half-line in the
composite sync. ⚠ **Do not put a half-line on the main raster again.** If a future change
needs one, it needs a second raster, which is what the retired `re_interlace` was.

⚠ Consequence for RGBHV rigs that use separate H and V sync rather than composite sync or
sync-on-Y: the V pin carries the line-aligned vsync, so those displays see field-paired
480i. Every csync/SoY/composite/S-video path gets true interlace. No such rig has been
reported; the fix is to apply the same delay to `VGA_VS` when `csync_en` is low.

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
