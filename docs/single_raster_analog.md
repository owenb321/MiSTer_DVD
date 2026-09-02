# Single-raster analog output — the interlaced main raster drives the CRT

**Status (2026-09-03, branch `feature/single-raster-analog`): sim-proven (every suite
below green, two RED reproductions); HW round 1 (composite CRT) on
`DVD_singleraster_20260902_1902`: resolution right, picture paired/bounced → §3.9 (2H
serrations); round-2 build `releases/DVD_singleraster2_20260902_1956.rbf`, SEED 5 first
roll, clk_dec 91.40 / 90.26 MHz, 88 % ALM, RAM 494/553 (12 M10K freed);
⏳ HW-confirm pending. Gate = the two RGBS / YPbPr
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
| per-field toggling on csync | The framework `csync` serrates at **line rate** (an hsync-width pulse one hsync period ahead of each hsync, no equalizing pulses). Our interlaced vsync began at **active dot 0**, ~9 µs after hsync, so field B's first broad pulse lasted only **~18 µs** against field A's ~50 µs — below or at the broad-pulse threshold of many sync separators, so a set could lock a line late on field B or flip between the two readings field to field. **Measured** by `bench/dvd/csync_field_tb.sv`. | §3.8 |

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

### 3.1 Half-line on the interlaced main modeline
`dvd/emu.sv` `REG_WR_VID_MODE` interlaced branch writes `halfline = 429` (NTSC) /
`432` (PAL); `rtl/mpeg2/syncgen_intf.v` doubles it as `2x` under pixel repetition
(429 → 858 = exactly half the 1716-dot line; the old `2x+1` gave 859). Vsync-to-vsync is
now 450450 clk27 = 262.5 lines **every field**. Main reports a steady 59.94, a
`vsync_adjust` PLL lands on the true rate, and the raster is a standard 480i/576i
signal.

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

### 3.8 Vsync anchored on the hsync leading edge (`rtl/mpeg2/syncgen.v`)
In the N64-model path the vertical-sync sample dot is now `horizontal_sync_start`
(field A) and `horizontal_sync_start + halfline` (field B, wrapping to the next line
with the vsync window shifted one line later so the B rise stays exactly 262.5 lines
after A's). This is the broadcast convention — vsync begins where an hsync leading edge
would be — and what every other MiSTer core does because their counters originate at
hsync; this sync generator's `h_cntr` originates at active video (upstream mpeg2fpga
convention), which is where the 9 µs offset came from. Measured by `csync_field_tb`:

| | before (dot-0 reference) | after (hsync-anchored) |
|---|---|---|
| vsync start after hsync edge, field A / B | 245 / 1103 clk27 | 0 / 858 clk27 |
| first broad pulse before the first serration, A / B | ~50 µs / **~18 µs** | ~59 µs / **27 µs** (standard 27.2) |
| broad-pulse width detector, trigger spacing | not measured | 450450 / 450450 exactly |
| RC integrator (τ 40 µs, Schmitt) spacing | 450171 / 450729 | 450246 / 450654 (informational) |

### 3.9 HW round 1 → serrations at 2H in the fork's `csync` (`sys/sys_top.v`)
The first board round (composite CRT, `DVD_singleraster_20260902_1902`): resolution
reported correctly, but the picture **paired and bounced more than the previous build**.
A tau sweep of the bench (`bench/dvd/run_csync_sweep.sh`, shipped vs main's `syncgen.v`)
explained it: the two separator models want opposite placements under **line-rate**
serrations —

| tau | old placement (dot-0), integrator | anchored, integrator | old, width detector | anchored, width detector |
|---|---|---|---|---|
| 20 µs | 450368 / 450532 | — | 449837 / 451063 | 450450 / 450450 |
| 40 µs | 450172 / 450728 | 450246 / 450654 | 449837 / 451063 | 450450 / 450450 |
| 80 µs | **450460 / 450440** | 450582 / 450318 | 449837 / 451063 | 450450 / 450450 |

The dot-0 placement happened to be near-perfect for an analog RC integrator (a classic
composite set) while breaking width detectors (the RT4K); anchoring fixed the width
detector and cost the integrator ~0.1 line — exactly the round-1 symptom. With line-rate
serrations no placement satisfies both, because the two fields' vsyncs start half a line
apart and the serrations do not. **Fix: the fork's `csync` module now serrates at twice
line rate during vsync** (an extra hsync-width pulse half a line before each stock one;
`half_len` measured like `line_len`). Both fields then see the same pattern:

| | first broad pulse A / B | width detector | RC integrator (40 µs) |
|---|---|---|---|
| 2H serrations | 27 µs / 27 µs | 450450 / 450450 | 450486 / 450414 (0.02 line) |

`csync_field_tb` now gates the integrator too (±0.05 line) and passes across tau 10–80 µs.
Equalizing pulses outside vsync are still not generated (they need advance knowledge of
vsync); every console core omits them as well.

Because "vsync starts on line N" now means "at line N−1's trailing hsync", the interlaced
walk's per-field vsync moved one line earlier (NTSC 243..246, PAL 291..294) so that line
21 (`v_cntr == 261`, the caption line) keeps its broadcast position 17 H after the vsync
leading edge. Field-A front porch ≈ 3.9 lines, 3-line sync, ≈ 15 lines to the next active
line = the standard 21-line VBI. Progressive and the legacy pulse-delay path (halfline=0)
are untouched.

## 4. Tests

| Bench | What it proves |
|---|---|
| `bench/dvd/crt_syncgen_tb.sv` PHASE 2c (new) | pixrep + half-line 858: vsync every 450450 clk27, rises 858 apart within the line, 3.0-line width, 240 lines/field; PHASES 1/2/2b/3/4/5 unchanged |
| `bench/dvd/csync_field_tb.sv` + `run_csync_field.sh` (new) | the REAL `sys_top.v` `csync` (extracted at run time) on the shipped modeline: first broad pulse ≥ standard in both fields, width-detector triggers exactly 262.5 lines apart, RC integrator within 0.05 line; `run_csync_sweep.sh [<older syncgen.v>]` sweeps tau and A/Bs placements |
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
- Native 13.5 MHz dot pacing (720-wide internally) — only if a reason appears; needs the
  overlay query-lead constants re-tuned (`HUD_QX_ADJ`, `BAR_QX_ADJ`, `LOGO_QX_LEAD`,
  `SP_QX_ADJ`, `crt_ov_map`, `cc_vbi`).
- Equalizing pulses outside vsync (needs the vsync position in advance — a 3-line video
  delay or a hint from the modeline walk) if a set still hunts with 2H serrations.
- Progressive 480p on the analog pins keeps the dot-0 vsync reference (no field
  ambiguity there); anchoring it too is a one-line follow-up if a 31 kHz display objects.
