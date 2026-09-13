# Single-raster analog output — the interlaced main raster drives the CRT

**Status (2026-09-03, branch `feature/single-raster-analog`): ✅ HW-CONFIRMED on the
maintainer's rig — HDMI and the composite CRT both clean, no jumpy image, Main reporting a
steady `720x480i @ 59.9`. Shipping build after the round-6 fix:
`releases/DVD_analogfinal_20260903_0235.rbf`, SEED 5 first roll, clk_dec 96.44 @100C /
92.11 @-40C, 88 % ALM, RAM 494/553.**

★ **THE DEFECT WAS THE FIELD-PARITY CORRECTOR, NOT THE SYNC.** Five HW rounds chased sync
shape on a wrong hypothesis; §3.9 is the post-mortem and it is the part of this document
worth reading. The corrector (PR #37, `docs/field_parity.md`) was **DISABLED** here and is
now **repaired and re-enabled** (2026-09-03, issue #41): its feedback arm was chasing
pixel-queue STARVATION, and its cure is a repeated field, so on compute-bound content it
repeated one several times a second. It now only acts on a parity error that has HELD
(`PAR_CONFIRM`), with a hard budget on top (`PAR_HOLD`). `bench/dvd/field_phase_tb.sv` is
finished and is the gate — it reproduces the defect (scenario [6] starves the pixel queue
and counts the repeated fields) and measures field phase from LINE-STAMPED framestore
content, so it cannot agree with the RTL by construction. ✅ HW-CONFIRMED over two rounds:
round 1 gave the CRT its fields and exposed an inverted `VGA_F1` (HDMI Weave went from a
coin flip to consistently combed once the phase stopped being random), round 2 confirmed
that fix — `docs/field_parity.md` "HW ROUND 1".

**HW round 6 (2026-09-03) — the follow-up sweep, all on the maintainer's rig:**
line-21 captions ✅, overlays/subtitles/menus/HUD on the analog output ✅, sub-720 fill
(VCD/SVCD/MPEG-1) ✅, Analog Aspect Letterbox + Crop incl. subtitles ✅, PAL content ✅,
`720x480i @ 59.9` steady ✅. Two findings, one fixed here and one filed:

- **Film 24p on an analog-configured rig was over-suppressed** (fixed, §3.5): the
  `~analog_want` gate removed the only way to watch 24p over HDMI with the CRT switched
  off. It now applies to an **Auto** verdict only; `Film 24p Out = On` is an explicit
  choice and is honoured. (The gate never bit anything else — under Auto such a rig
  resolves to Interlaced, where `filmp_eff` is 0 anyway.)
- **A mid-title `Video Output` change can freeze the decoder** — ⚠ **PRE-EXISTING, not
  from this branch**: v0.3.0 does the same on an `Analog Out` mode change. First seen on
  PAL and filed as PAL-only; it reproduces on NTSC too (2026-09-03), which is what
  disproved the PAL hypothesis. **FIXED** in `fix/mode-switch-realign` (issue #42), ⏳
  HW-confirm pending. See §6.

⏳ Not yet gated: `direct_video=1` through an HDMI DAC. (The field-parity coin flip that
was open here is ✅ fixed and HW-confirmed — `docs/field_parity.md`. ✅ **PAL on an analog
CRT is HW-CONFIRMED as of 2026-09-12** — multiple user reports; see §3.12. The analog sync
modes incl. RGBHV have since been exercised by the maintainer on a RetroTINK.)

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

Reported but **not** gated at the time: with line-rate serrations the two fields necessarily
present different broad pulses (~50 µs and ~18 µs), because their vsyncs start half a line
apart while the serration grid does not move with them. 18 µs is at the threshold of a
width-based separator, which is a plausible mechanism for the RetroTINK "vsync length /
lines-per-frame toggling" report. Serrating at **2H** equalises it (27 µs / 27 µs, and the
integrator asymmetry drops from 0.13 line to 0.02) — that variant was built (`a2b72fb`) and
then reverted (`48c00cb`) because the composite CRT that is the reference display for this
path was worse with it.

⚠ **AMENDED 2026-09-05 — that verdict was confounded, and the amendment is §3.9's own lesson
running backwards.** The 2H A/B was run in HW rounds 1–3 of this branch, i.e. **while the
field-parity corrector was defective and repeating fields several times a second**, and the
2H code was deleted in the *same commit* that disabled the corrector. The CRT bounced with
2H and without it, so 2H was never the variable under test — it was removed at the exact
moment the real defect was identified, and has never been tried against a working corrector.
§3.10 makes it selectable and re-measurable instead of re-litigating it from memory.

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
   replacement: LINE-STAMPED framestore content, per-field measurement of what the mixer
   actually emitted, and the invariant that consecutive fields must DIFFER and repeat with
   period 2.
5. ★ **The perturbation the bench was missing was the mundane one.** Scenarios written
   from the field reports (seeks, cold start, cadence breaks) all passed with the
   corrector on — the defect only appeared once the bench STARVED the pixel queue, which
   is what this compute-bound core does several times a second on real content and what
   no scenario derived from a user's description would have contained. When a bench
   exonerates the code the hardware indicts, ask what the hardware is doing all the time
   that the bench never does.

### 3.10 Analog sync shape: the equalizing pulses we were never emitting

**Status (2026-09-05, PR #64): sim-proven RED/GREEN and ✅
HW-CONFIRMED 2026-09-07 on the maintainer's rig** (composite CRT and HDMI both correct,
build `DVD_smptesync4_20260907_2305.rbf`). ⏳ The two reporters whose sets found the
defect have not retested; that is what the next release is for. New `dvd/csync_smpte.sv`; `P1O[47:46] Analog CSync = SMPTE / 2H / Stock`,
**SMPTE is the default**, and after the 2026-09-07 option removal it is one of only two
arms. Rebased onto main after PR #63 (the free-running STC); shipping build
`DVD_smptesync4_20260907_2305.rbf`, SEED 5 first roll, clk_dec 93.45 @100C / 91.35 @-40C
(gate 86.0), 92 % ALM.

**The gap.** SMPTE 170M-2004 §13.3 / Table 3 / Fig 7 and ITU-R BT.470-6 Table 2 both
specify a vertical block of pre-equalizing pulses, serrated vertical sync, and
post-equalizing pulses. The standards say why: the serrations are *"provided to maintain
horizontal synchronization"*, and the block exists to *"properly position the vertical
sync"*. We emitted **neither the equalizing pulses nor 2H serration** — §3.8's measured
50 µs / 18 µs field asymmetry is the direct consequence, and 18 µs is at or below the
trigger threshold of a width-based sync separator. A set that reads the two fields
differently pairs or swaps them: line-pairing jitter, "sawtooth" edges, half the vertical
resolution it should resolve.

★ **The recorded blocker was false, and only for the module it was written about.**
`sys/sys_top.v` said equalizing pulses *"would need advance knowledge of vsync"*. True of
**that** module — it derives composite sync from a *finished* hsync/vsync pair, so it
structurally cannot emit a pulse before vsync starts. Not true of us: `v_pos` carries the
raster's own line index and field parity a full field ahead. The sync was being assembled
in the wrong place, not withheld for a good reason.

★ **Built in `dvd/`, not in `syncgen`, for three reasons that each contradicted the
obvious first design:**

1. The "dead `c_sync` port chain" is **not continuous** — `mpeg2video.v:1574` ties
   `syncgen_intf`'s `.c_sync()` open, and the port at `mpeg2video.v:110` (hence the unused
   one in `emu.sv`) is `yuv2rgb`'s recomputed XOR. Routing syncgen's out would mean new
   ports in three upstream files *and* a perturbed decoder netlist for the fitter.
2. syncgen's outputs **lead the emitted picture by ~15 dots** (the same lead `SP_QX_ADJ=13`
   compensates), so a syncgen-built csync would have to be re-delayed anyway.
3. Everything the block needs is already on emu's side of the wall, on the same clock —
   `dot_clk = clk_sys = CLK_VIDEO = clk_vid`, so there is **no CDC anywhere in this
   feature**.

★ **Anchored on the output hsync, not on `h_pos`.** `hcnt` locks to the leading edge of the
emitted `h_sync`, so every pulse lands exactly where an hsync would, and **outside the
vertical block the module is a one-clock hsync delay — bit-identical to what the stock
module emits outside vsync**. That is what turns "did we disturb anything?" into a
clock-by-clock equality gate instead of a hand-tuned delay constant. `v_pos` only picks
*which line* the block starts on, so the 15-dot lead is irrelevant (far under half a line).

⚠ This places the analog vertical interval **245 dots (0.14 line) earlier** than the
raster's own vsync edge, because the raster raises vsync at `h_cntr` 0 while hsync sits at
1471. That is the standards-correct placement — the vertical interval begins at an H — it
is invisible as a vertical shift, and it happens **only on this analog composite-sync
bit**. `VGA_HS/VS/DE/F1` and `CE_PIXEL` are untouched, so **HDMI is bit-identical on every
arm**. That decoupling is exactly what HW round 2's raster-level re-anchoring experiment
lacked (§3.8): it moved the *raster*, and the CRT is the reference for that.

**Counting in half-lines** is what makes one generator serve both standards: SMPTE's
525-line block is 3H+3H+3H = 6/6/6 half-lines, BT.470's 625-line block is 2.5H each =
5/5/5 (its Table 2 `l`/`m`/`n` give it directly). Every width derives from modeline
registers the raster already carries — **no new constants** — and each lands inside
tolerance for both standards:

| | NTSC 480i | spec (sys M) | PAL 576i | spec (B/G/H/I) |
|---|---|---|---|---|
| line | 1716 = 63.556 µs | 63.556 | 1728 = 64.000 µs | 64 |
| half-line | 858 | 0.5H | 864 | 0.5H |
| serration `r` | 127 = 4.704 µs | 4.7 ± 0.1 ✓ | 127 = 4.704 µs | 4.7 ± 0.2 (I: ±0.1) ✓ |
| broad `q` = half − r | **731** = 27.074 µs | 27.1 nominal ✓ | **737** = 27.296 µs | 27.3 ± 0.1 ✓ |
| equalizing `p` | **62** = 2.296 µs | 2.3 ± 0.1 ✓ | **63** = 2.333 µs | 2.35 ± 0.1 ✓ |
| `l`/`m`/`n` | 6/6/6 = 9 lines | 3H each ✓ | 5/5/5 = 7.5 lines | 2.5H each ✓ |

NTSC field A: equalizing on lines 241–243, broad on 244–246 (exactly the lines the raster's
own vsync window covers), equalizing on 247–249 — inside the 22 blanked lines (active
0–239 of 262). PAL: 289.5–297 inside 24. **Line 21 (`v_cntr` 261) does not move**, so
`cc_vbi` is untouched.

★★ **MEASURED, and this is the table that settles the 2H question.** The RC integrator is
the mechanism an analog CRT actually uses, and its field-to-field trigger error is:

| arm | NTSC | PAL | field error |
|---|---|---|---|
| **Stock** | 450172 / 450728 | 539720 / 540280 | **±278 clk = 0.16 line**, 10 triggers out of tolerance |
| **2H** | 450484 / 450416 | 540034 / 539966 | ±34 clk = 0.020 line |
| **SMPTE** | **450450 / 450450** | 539998 / 540002 | **0 / ±2 clk = 0.001 line** |

★ **The equalizing pulses buy a further ~17× over 2H alone, and take NTSC to exact.** That
is the number nobody had when the 2H variant was built and reverted — the argument then was
"2H fixes the width asymmetry", which it does, and the question of whether the *rest* of the
block is worth having was never asked because it was believed impossible to build.

The width-based separator tells the same story more bluntly: on Stock it **misses field B's
first broad pulse entirely** (1347 vs **489** clk27 = 49.9 vs **18.1 µs**, under any 20 µs
threshold) and locks a line late — spacings 449837 / 451063, 11 per-field errors. On SMPTE
and 2H both fields present 731 clk27 (27.07 µs) and the spacings are exactly 450450 / 450450.


**Routing.** `dvd/emu.sv` gains `VGA_CS` / `VGA_CS_EN` (non-standard emu ports, like
`SPDIF_PASS`), emitted in the **same clock as `VGA_HS`**. `sys/sys_top.v` delays them by
`CS_PIPE` and muxes against the stock module's output.

⚠ **`CS_PIPE` is the whole integration risk, so it is measured, not counted.** `cs_emu` is
one clock behind the raster while the stock sync is built *after* `sync_fix`
(combinational) + `scanlines` (3) + `osd` (4) + `csync`'s own register (1). Get it wrong
and every analog sync edge moves 37 ns per clock — invisible in every other bench.
`bench/dvd/csync_pipe_tb.sv` drives the **real** `scanlines`/`osd`/`csync` and compares the
measured latency against the constant it greps out of `sys_top.v`: **measured 8, sys_top
uses 8**. The design note had hand-counted **7** — it forgot `csync`'s own register. The
bench caught it before a line of it reached hardware.

★ **`module csync` in `sys_top.v` is deliberately NOT modified**, and
`bench/dvd/csync_extract.sh` **checksums** it (`bench/dvd/csync_ref.sha256`). "Stock is
bit-identical" is a claim about the shipped escape hatch, and it can only be a claim about
the module the bench was given.

**Modes.** `P1O[46] Analog CSync` = `SMPTE` (index 0, default) / `2H` (serrations only —
§3.8's reverted variant, kept only until field reports say whether any display prefers it;
it measures ~17× worse than the full block).

⛔ **A third arm, `Stock`, was carried through bring-up and REMOVED before release**
(2026-09-07, user decision). It is a measurably broken signal — 0.857 line between the
fields instead of 0.500, and a mis-identified first field — not a fallback. Its only value
was as a comparison point, and it held that value **only while the field order was also
wrong**, because the two errors cancelled (§3.12). Shipping it would have meant shipping a
mode that makes a television read the fields backwards.

⚠ **The framework module is still the live path on a PROGRESSIVE raster** — `cs_en` follows
`en` (= `interlaced_eff`), because a nine-line vertical block is meaningless there. Gated in
RTL, not by user discipline, and it is the configuration `csync_field_tb`'s stock arm
exercises now that the OSD value is gone.

⚠ **A rig running `vga_scaler=1` or a framebuffer never sees any of this**: the pins then
take `vgas_cs` from `hdmi_cs_osd`, the *other* `csync` instance. Expect "the setting does
nothing" reports from those users. `vga_cs_osd` also feeds `yc_out`, so composite/S-video
users get the new sync too — a real CVBS signal *should* carry equalizing pulses, but that
is an unmeasured second consumer and it is on the HW checklist.

**Gate: `bench/dvd/run_csync_field.sh`** (six arms: three modes × NTSC/PAL) and `--red`,
plus `bench/dvd/run_csync_pipe.sh`.

| | GREEN |
|---|---|
| [G1] | **Stock arm**: the mux output equals the real framework module's on *every clock*, and the arm still exhibits the 50/18 µs asymmetry — a bench that passed on both waveforms would not be distinguishing them |
| [G3] | SMPTE / 2H: away from the vertical interval, generated == stock clock for clock |
| [G4] | Pulse census against SMPTE Table 3 / BT.470 Table 2: counts, widths, half-line grid, both fields, both standards |
| [G5] | **Field congruence** — each field's block pulses, anchored on **its own first broad pulse** (a *measured* feature, not one of the module's constants), must be identical to the other's. This is what "equalised" means, and the anchor choice is what stops the gate degenerating into a restatement of the RTL |
| [G6] | Both separator models trigger 262.5 lines apart **every field**, not merely in pairs (the old bench gated only the pair, which is true under stock too) |
| [G7] | Raster sanity: hsync cadence, 3.0-line raster vsync, one frame per field pair |

⚠ **[G5]'s window stops at the block on purpose, and the reason is worth keeping.** The
last ordinary hsync before the block is a full line ahead of it in the line-aligned field
and only **half a line** ahead in the other (measured: 1716 vs 858 clk27). That difference
*is* interlace — the whole vertical interval is offset half a line — not an asymmetry any
standard removes. The bench reports it and does not gate it. What the equalizing pulses
guarantee, and what a separator integrates over, is that the **block itself** is identical.

**RED arms**, each required to fail — three are sed-mutated copies of the generator, since
a bench cannot mutate a module it merely instantiates:

| arm | mutation | measured failure |
|---|---|---|
| `grid` | block not offset by a half-line on field B (the stock defect, reintroduced) | **G6**: 11 per-field width-detector errors, 10 integrator |
| `eqwide` | equalizing pulses emitted at broad width | **G4** census |
| `nopre` | pre-equalizing segment dropped (2H presented as SMPTE) | **G4** census |
| `lag` | generated sync one clock late | **G1/G3**: 5174 mismatches / 4439292 clocks |
| `CS_PIPE` | wrong value in `sys_top.v` | `csync_pipe_tb` |

★ **`grid` is caught by G6 and NOT by G5, and that is the two gates being genuinely
complementary rather than one being weak.** G5 anchors each field on its own first broad
pulse, so it measures the block's **shape**; `grid` leaves the shape identical in both
fields and moves its **placement** relative to the raster, which is what G6's absolute
262.5-line spacing measures. (The design note predicted "G5 and G6" for this arm. Wrong,
and worth correcting rather than quietly widening a gate to match the prediction: shape and
placement are separate properties and it takes both gates to cover them.)

⚠ **`eqwide` and `nopre` fail through the same route and print nearly identical output**,
because both move the width detector's anchor: with the equalizing pulses widened to broad
width, or absent, the first pulse the detector locks onto is no longer the first *broad*
one, so the census then reads ordinary hsyncs (125 clk27) where it expects equalizing
pulses. The detection is real — a separator that cannot find where the vertical sync begins
is exactly the failure — but the two arms are not distinguished from each other by the log.

★ **The bench earned its keep on the first run.** A registered counter reset by the hsync
edge does not read zero until the cycle *after* the edge, so the block's pulses that start
at a **line** boundary rose one clock early and measured one clock wide — while the
**half-line** ones did not. The two fields then disagreed by exactly one clock and the
block's first spacing read 859 instead of 858. [G4]'s half-line-grid check and [G5]'s
congruence both caught it; a pulse-width-only census would have passed. The module now
computes position combinationally for the cycle in progress (`pos`, `line_now`,
`fpar_now`).

### 3.11 Field order: a knob, because the convention was asserted and never measured

**Status: `P1O[48] Field Order` was added 2026-09-05 and REMOVED 2026-09-07 (user decision)
once it had done its job. This section is kept for the reasoning, not the knob.**

★ **Why it could never ship:** field order is a correctness constant with exactly one right
value, not a per-display preference, and the knob moves HDMI and analog *together* — so it
can never reconcile a disagreement between them, only relocate it. A user reaching for it to
fix a CRT would silently break their HDMI, which is exactly what the hardware round
demonstrated. Its diagnostic value was spent the moment it isolated the fault to the analog
side; the polarity now lives in `rtl/mpeg2/field_polarity.vh` and is gated by
`csync_field_tb` [G8] and `cc_field_map_tb`.

⛔ **AMENDED 2026-09-06 — the central claim of this section is WRONG and §3.12 is the
correction.** The RASTER's field assignment was the fault, and `syncgen.v`'s "flip both
terms" advice was right. The knob itself stays and earned its keep: it is what ISOLATED the
fault, because a control that moves both outputs together cannot fix a disagreement between
them — when `Swap` fixed the CRT and broke HDMI, the fault had to be on the analog side
alone. It remains a diagnostic and must not be shipped flipped. The reasoning below is kept
because the error is the instructive part.

`rtl/mpeg2/syncgen.v`'s derivation ends *"(If HW shows the fields spatially swapped, flip
both terms.)"*, meaning `vs_ref_dot` and `eff_vertical_length`. **We flip the content
mapping instead**, and the reason is in the surrounding comment: the raster model is
inherited — *"this is how the known-good N64 core does it (N64_MiSTer
rtl/VI_videoout_sync.vhd: vtotal 262/263 by field + vsyncCount sampled at htotal/2 on one
field)"* — and the block closes with *"the CRT is the reference for the analog path: do not
re-anchor without one to test on."* The raster is the one part we did **not** invent.

What we *did* invent is the very next sentence: *"odd_field=1 scans v_pos even lines (TOP
content, the upper field)."* **N64 has no "TOP content"** — it scans a framebuffer, so the
line displayed is fixed by the raster line being scanned. That sentence is a bare assertion
about *our* content, and it is the untested bit.

So `field_swap` XORs `mpeg2video.v`'s `sync_raster_par_err` input, which is exactly
equivalent to inverting `mixer.v`'s comparison (the verdict is a held level) while leaving
`mixer.v` untouched. Strictly safer than the raster flip: the **sync waveform stays
bit-identical** (so §3.10's gates are unaffected), **`cc_vbi` needs no change** — avoiding
the CC round-1/2 failure, where a field-mapping flip made every field-1 caption service go
dark — and the N64-inherited raster is untouched, keeping the two knobs orthogonal.

★★ **Why this is worth a knob at all: the current convention's one HW validation was
unfalsifiable when it was made.** `docs/crt_480i.md` ("field order was correct as shipped,
no `odd_field` flip needed", 2026-07-05) predates the field-parity corrector — the content
phase was a 50/50 coin flip then, so a wrong convention was right half the time and could
not be seen. **This is the `VGA_F1` story on the analog side**: on HDMI, once the phase
stopped being random, Weave went from a coin flip to *consistently* combed, which pinned
the fault to the flag — and `VGA_F1` had been inverted since it was written, its own
comment saying the polarity might need flipping. The analog pins never read `VGA_F1`; their
equivalent is `vs_ref_dot`, and it has never been checked against a measuring device.

⚠ **The two knobs are not independent, which is why they ship together.** A device can only
tell field 1 from field 2 *from the sync*, and equalizing pulses are the mechanism the
standard provides for doing so — so §3.10's asymmetry is a plausible **cause** of a
field-order misidentification. One build carrying both settles it:

| | `Field Order = Normal` | `= Swap` |
|---|---|---|
| `CSync = Stock` | today (reporters broken) | convention inverted, sync irrelevant |
| `CSync = SMPTE` | sync was the whole fault | both real — fix sync, flip the default |

⚠ **Not instant**: the corrector's feedback arm needs `PAR_CONFIRM` (~0.5 s) and spends a
`PAR_HOLD` budget, so allow ~2 s before judging an A/B.

**Gate: `bench/dvd/run_field_phase.sh` gains a `+swap=1` arm.** It replicates the XOR in
the same CDC the bench already models and inverts **check C's** expectation with it, while
leaving checks A and B (consecutive fields carry different source lines; the emitted
content repeats with period 2) untouched. So it proves two things at once: the knob really
does move content to the other raster slot, and **alternation survives** — a swap that
broke the interleave would be a regression, not a diagnostic.

★ It is not a vacuous pass, and the numbers show why. Inverting both the stimulus and the
expectation would pass regardless *if the corrector ignored the verdict*; instead the arm
measures **1 repeat / 28 misaligned in its worst settle window** — identical to the
`+phase=1` arm, and quite different from `+phase=0`'s 0/0, because a swap at phase 0 gives
the corrector exactly the same amount of work to do as no swap at phase 1. The check
windows are clean in all three. A corrector that did not follow the inverted verdict would
leave content in the original slot and fail check C outright.

⚠⚠ **A rig can be genuinely insensitive to this, so an uninformative "looks the same"
result must not be read as "the knob does nothing".** Film-sourced content barely cares —
3:2 material is progressive frames *split* into fields, so both fields of a frame are the
same instant and swapping them costs the line assignment but **no temporal error**
(CLAUDE.md records the same thing from the Native Fields work: *"film barely cares… true
29.97i video is where combing shows"*). Almost every movie DVD is film-sourced. **Test on
video-sourced 29.97i content** — `tools/video_cadence_census.py` says which a disc is —
with fast horizontal motion, in **Weave or CRT Simulation, never Bob** (Bob hides it; the
RT4K reporter demonstrated exactly that himself).

★ **Who decides the default.** Not the maintainer's set, for this one knob: for the sync
arms he owns the reference display that must not regress, but for field order an instrument
that *reports* the answer outranks any number of impressions, so the **RT4K reading is the
deciding vote** and the CRT is the regression check.

⚠ **Count the evidence honestly before flipping the default.** One *unambiguous*
field-order report (the RT4K: *"the fields are out of order by default… Bob plus field
offset −2 lines them up"*), one *ambiguous* (the Trinitron "sawtooth", at least as
consistent with §3.10's pairing error), and older reports (SuperStationOne/YPbPr, "toggle
3–4 times") that **predate the deterministic corrector** and describe the coin flip — those
cannot speak to today's default at all. Enough to suspect strongly; not enough to flip
blind.

⚠ **One thing neither hypothesis explains yet, and it must not be absorbed into "field
order":** a pure field swap is a **one**-unit correction, and the RT4K reporter needs
**−2**. If −2 survives both the SMPTE arm and `Field Order = Swap`, there is a third
thing — a line-position offset in the vertical block or the DE window — and it gets chased
separately.

### 3.12 The field order was wrong, and the broken sync had been hiding it

**Status (2026-09-06, same branch): found by HARDWARE, fixed, sim-gated, and ✅
HW-CONFIRMED 2026-09-07** — `Field Order = Normal` (now the only behaviour) is correct on
HDMI **and** the CRT at once, which is the single observation the whole diagnosis reduced
to. `rtl/mpeg2/field_polarity.vh` `FIELD1_VPOS` 0 → 1.

**The field report that found it**, on the §3.10 build, on the reference CRT:

| `Analog CSync` | `Field Order` | CRT | HDMI |
|---|---|---|---|
| Stock | Normal | correct (= v0.4.0) | correct |
| SMPTE / 2H | Normal | **wrong** | correct |
| SMPTE / 2H | Swap | correct | **combed** |

★ **Two outputs wanting opposite settings is the whole diagnosis.** `Field Order` moves the
CONTENT mapping, which feeds both outputs, so it can never reconcile a disagreement
*between* them — it can only move both. So something had moved the ANALOG field assignment
relative to HDMI's, and that something was §3.10.

**Measured** (`csync_field_tb`, the new `EMITTED vertical interval` and `[G8]` lines):

| arm | field separation a separator sees | which field it calls first |
|---|---|---|
| Stock | **0.857 line** | the **opposite** one from the raster's |
| SMPTE | **0.500 line** ✓ | the raster's own |

Stock's width detector misses one field's 18 µs broad pulse and locks onto the next one a
line later, which lands right at an H — so a television reading stock sync concludes the
*other* field is field 1. **With that misreading in place, a content mapping that is off by
one field looked correct.** Fixing the sync removed the misreading and exposed the error.
HDMI never reads composite sync, so it was never mis-corrected — which is exactly why it
stayed right while the CRT flipped.

★★ **So `syncgen.v`'s original advice — "if HW shows the fields spatially swapped, flip both
terms" — was RIGHT, and §3.11's "DO NOT" was wrong.** The reasoning behind the DO NOT was
that the raster is inherited from the known-good N64 core. What is inherited is the
262/263 + mid-line-vsync **mechanism**; the assignment of *our* two fields to it is ours,
and it had never been tested, because until §3.10 no display could read it.

★★★ **And the durable lesson, which cost a wrong "correction" in the previous change:**
`bench/dvd/cc_field_map_tb.sv`'s header said *"TOP content displays inside SYNC field 2
(NTSC is bottom-field-first: field 1 shows the bottom lines)"*. On 2026-09-05 that was
deleted as an inverted stale comment, because **three other sites agreed against it**
(`mixer.v:216`, `cc_vbi.sv:60`, `syncgen.v`). It was right. All three had been calibrated
against a composite sync no display could read correctly, so **their agreement was not
evidence** — it was three readings of one untested reference. Under `FIELD1_VPOS = 1` the
raster puts TOP content (v_pos-even, per `mixer.v` and `VGA_F1`) in sync field 2, which is
what that sentence always said. It is restored, with the history.

**The fix is ONE constant, three consumers** — `rtl/mpeg2/field_polarity.vh`:

| consumer | what it decides |
|---|---|
| `rtl/mpeg2/syncgen.v` | which field gets the line-aligned vsync and the SHORT total (the longer field must carry the mid-line vsync, or spacing becomes 263.5/261.5) |
| `dvd/csync_smpte.sv` | which field's block opens on a line boundary rather than half a line in |
| `dvd/cc_vbi.sv` | which field carries the line-21 field-1 services |

⛔ **Not `mixer.v` and not `VGA_F1`** — those move HDMI and analog *together*, so they
cannot fix a disagreement *between* them. `P1O[48] Field Order` remains a diagnostic; it is
not the fix and must not be shipped flipped.

**Gates.** New **[G8]** in `csync_field_tb`: the raster's line-aligned field and the emitted
block's must be the same `v_pos` parity — **both measured, neither reading the constant**
(the raster's is whichever vsync sits nearer an hsync; the block's likewise), so a consumer
flipped in isolation fails. `cc_field_map_tb` and `cc_e2e_tb` now read the constant instead
of hardcoding a polarity, so they check the *relationship* rather than pinning whatever was
true when they were written; `cc_field_map_tb` is mutation-checked (invert `syncgen`'s
`field1` alone → 8 errors). `crt_syncgen_tb` passes **unchanged**, which is the evidence
that the flip preserves every timing invariant — 262.5-line spacing, 3.0-line widths, exact
field-pair totals — and swaps only *which* field is which.

⚠⚠ **LINE-21 CC IS NOT A TEST OF FIELD ORDER, and it was proposed as one.** Our census finds
**field 2 empty on every disc**, so nothing competes for the slot and a consumer decoder
shows C1 whichever field the data lands in. Captions decoded correctly in all six
combinations of sync arm × field order on hardware — which says the chain works and says
**nothing** about the mapping. A prediction whose failure mode is unobservable is not a
prediction.

⚠⚠ **OPEN: `FIELD1_VPOS` is ONE constant for both standards, derived from an NTSC
measurement.** Neither it nor its three consumers has a `pal` term. The block **shape** is
standards-correct on both (BT.470's 5/5/5 half-lines and its widths, gated by the PAL arms)
— that part is not in question. But *which* raster field is field 1 is a separate question,
and 525- and 625-line systems are not obliged to answer it the same way. ⚠ **[G8] cannot
catch this**: it gates that the raster and the emitted block AGREE, and on PAL they would be
wrong together.

✅ **ANSWERED 2026-09-12: PAL on an analog CRT is HW-CONFIRMED by multiple user reports**,
which also closes the raster numbers that had been sim-derived since PR fj#146. The shared
constant is therefore correct on BOTH standards and does **not** need to be made
per-standard. ⚠ The paragraph above stood for months as "untested rather than
known-good" — that was the honest status, and it is worth noting the resolution came from
users with the hardware, not from any amount of further reasoning here.

★ Kept as the contingency if a future PAL report ever does say the fields are swapped: make
the constant **per-standard** (`pal ? … : …` in all three consumers) — do not flip it
globally, which would break the NTSC case it was measured on.

✅ **The HW test was a single observation and it passed (2026-09-07):** the picture is
correct on **both** HDMI and the CRT at once, with nothing to set. Both knobs the diagnosis
used are gone — `Field Order` entirely, and `Analog CSync`'s `Stock` arm — so there was no
combination left to get wrong.

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
- [x] PAL disc over HDMI 576i unregressed. (Analog PAL 576i on a CRT: ✅ HW-confirmed
      2026-09-12 by multiple user reports — see §3.12.)
- [ ] Idle logo reports `720x480i`; no resolution popup on disc load.
- [ ] Toggling `Video Output` mid-title: the chapter-seek-style interruption, then clean.

**§3.10 / §3.12 (SMPTE composite sync + the field-order fix).** ★ The build ships with
`Analog CSync = SMPTE` and the corrected `FIELD1_VPOS`, replacing a path that was
HW-confirmed good, so the maintainer's CRT is the **regression gate and goes first**.
⚠ There is no longer an OSD escape hatch — `Stock` and `Field Order` were both removed
(§3.10, §3.11) — so a regression here means a rebuild, not a menu change. That is the
accepted cost of not shipping a measurably broken mode.

- [ ] **Maintainer's composite CRT, `Analog CSync = SMPTE`:** stable, no pairing or bounce,
      `720x480i @ 59.9` steady, line-21 CC still decoding, overlays / HUD / menus intact.
- [ ] A/B both `Analog CSync` arms from the OSD (no reload needed) on the same set.
- [ ] **Composite / S-video on the SMPTE arm** — `vga_cs_osd` also feeds `yc_out`, an
      unmeasured second consumer. A real CVBS signal *should* carry equalizing pulses, but
      that is a prediction, not a measurement.
- [ ] Progressive (480p) unaffected — `cs_en` is gated on `interlaced_eff`, so it must take
      the stock path; confirm no change at all.
- [ ] **RT4K reporter, in CRT Simulation** (Bob masks the fault — his workaround is the
      wrong mode to measure in): both `Analog CSync` arms. ★ The field-order question he
      raised is fixed in RTL (§3.12) with **no setting**, so what is wanted from him is
      whether the fields read in order *at all*, not which knob position achieves it.
- [ ] **RT4K readouts per arm** — pixel clock, vsync length, lines/frame, frame rate. The
      earlier report was "vsync length toggling about once a second"; that readout directly
      measures the 50/18 µs asymmetry, so the SMPTE arm should stop it toggling. This is
      the measurement that turns the bench's separator models into a field result.
- [ ] **Ask the RT4K reporter what field offset each arm needs, and whether ±1 alone ever
      suffices.** A pure field swap is a ONE-unit correction; he needs −2. If −2 survives
      the SMPTE arm and the corrected `FIELD1_VPOS`, there is a third thing (a line-position
      offset) — chase it separately, do not absorb it into "field order".
- [ ] **Trinitron reporter:** does the sawtooth appear on the **idle logo with no disc**? A
      yes exonerates the decoder, the governor and the parity corrector outright. Still vs
      motion? Does N64/PSX 480i do it on the same set (same `csync`, same raster model)?
      And his `MiSTer.ini` — `vga_scaler=1` would mean none of this reaches his pins.
- [ ] **Field order, on video-sourced 29.97i content** (`tools/video_cadence_census.py`),
      fast horizontal motion, Weave or CRT Simulation — never Bob, and never a film disc
      (both fields of a 3:2 frame are the same instant, so a film title cannot show it).
      There is no setting to try: the picture is either in order or it is not, on **both**
      outputs at once.
- [ ] ⚠ **PAL on a CRT, if anyone has one.** `FIELD1_VPOS` is one constant for both
      standards and was measured on NTSC; the block *shape* is BT.470-correct and gated,
      but which field is first on 625 lines is untested. See the open note in §3.12.

## 6. A mid-title `Video Output` change froze the decoder — FIXED (issue #42)

**Status: sim-proven RED/GREEN on branch `fix/mode-switch-realign`, ⏳ HW-confirm
pending.** Gate: a PAL disc **and** an NTSC disc, `Video Output` toggled mid-title in both
directions ×20 each (it is intermittent, so a small N proves nothing), plus the T2
menu→Play Dolby/THX logo chain — `docs/film_24p_plan.md` §13 names that chain as the gate
for anything touching this glue.

Also on the HW list, and **not coverable in sim**: the field-parity corrector (§ issue #41)
names an "`il_switch`/aspect raster restart" as a genuine phase-flip step its feedback arm
heals ~0.5 s in, so a mode switch is one of its expected triggers. Nothing in this change
touches the corrector's RTL — `run_field_parity.sh` and `run_field_phase.sh` compile
`resample_addrgen`/`mixer`/`syncgen` and never see `emu.sv`, so they pass unchanged **by
construction, which is not evidence about the interaction**. What changed is the *timing*
of the flush relative to the raster restart, and only a rig can say whether the corrector
still lands the phase after a mode switch. Check it in the same round.

### 6.1 The symptom, and the constraint that was wrong

With a disc playing, changing `Video Output` mid-title could freeze the decoder: the
picture stopped on a malformed image and never recovered by itself. A chapter seek cleared
it. Either switch direction, not every time. **Not from this branch** — v0.3.0 does the
same on an `Analog Out` change.

It was reported on a PAL disc, and this section, `CLAUDE.md`, the GitHub issue and the user
manual all recorded "NTSC is unaffected". That pointed the first analysis straight at the
**PAL-only** `pal_eff` feedback path. The maintainer then saw the freeze on an **NTSC**
disc (2026-09-03).

⚠ **The lesson is worth more than the bug.** A symptom reported as specific to one
configuration is a *hypothesis*, not a measurement — and here the wrongly-narrow
constraint was the thing making the diagnosis hard, because it excluded the actual cause
(which is standard-neutral) and made a secondary amplifier look like the mechanism. The
same shape as §3.9's five rounds on the wrong layer.

### 6.2 The cause was already written down, and had been read as harmless

`dvd/emu.sv`'s `il_switch` block explained the whole thing and dismissed it:

> The full flush is exactly what a chapter seek does (HW-confirmed synced); the only
> difference is the reader doesn't jump, so ps_demux re-hunts to the next pack boundary
> within the vbuf re-lock glitch.

That difference **is** the defect. A mode switch fired the trio (`load_flush` +
`aud_flush` + `seek_flush`) but did not move the reader, so the decoder resumed **mid-VOBU
with no GOP boundary to re-lock on**. And the reason a chapter seek cured it is that a seek
is the same trio **plus a reader jump to a boundary** — the workaround was naming the
missing ingredient the entire time. It is also exactly the trap the reverted film-engage
flush hit (`docs/film_24p_plan.md` §13).

### 6.3 What ships — `dvd/mode_realign.sv`

`il_switch` no longer drives `flush_ctl` directly. The new module turns it into a **seek to
the playhead's own VOBU** and lets the resulting `seek_ack` drive the trio, which makes a
mode switch byte-identical to a chapter jump. `flush_ctl.mode_switch` survives as the
**in-place fallback** — a disc menu, a raw `.m2v`, no trustworthy playhead, or a seek the
reader never acknowledges within ~0.5 s — so a mode change can never silently lose its
flush. **`flush_ctl.sv` itself is unchanged**; rows [7]–[9] of `flush_ctl_tb` now describe
the fallback leg.

Three points that are not obvious from the code:

- **Why the CURRENT VOBU, not the next one.** `dsi_nv_pck_lbn` already *is* the RBN of a
  NAV pack, in the same VTSTT_VOBS space `seek_rbn` uses, so the reader arms its snap probe
  at the target and **hits on candidate #1**: one 2048-byte sector read, no movement.
  Targeting `+1` would walk forward one sector at a time up to `NAV_CAP = 1024` reads.
  `bench/dvd/iso_reader_seek_tb.sv` TEST9 **measures** this over three points — on-NAV 3
  reads, one-short 4, five-short 8 — so the walk is proven at one read per sector and the
  cost model is measured rather than asserted. Re-reading the VOBU being parsed also
  re-supplies roughly what the VBUF flush discards, so no content is skipped.
- **Edges are coalesced, and that is a correctness property.** `il_eff` is a LEVEL: the
  modeline walk always converges on its final value, so N toggles need exactly ONE
  re-align. Absorbing further edges while an arm is open makes the
  repeated-mid-parse-flush loop class — the thing that killed the film edge — structurally
  unreachable from this path. That is why a future `filmp_eff` edge belongs **here** and
  must never go straight into `flush_ctl`.
- **The stale-playhead trap, inherited.** `nav_dsi` is on `pipe_rst_n`, so *any*
  `load_flush` — including the one this module's own seek causes — clears
  `dsi_nv_pck_lbn` to 0, and the reader's clamp turns that into a jump to the start of the
  title. Hence `dsi_fresh`, and hence `tgt_rbn` is latched exactly **once**, on the
  issuing cycle. `dvd/dpad_seek.sv` hit this first; its header is the long version.

Two smaller things: `hud_user_evt` now watches the **scrub's** pulse rather than the
arbitrated one (a re-align rides the same reader port and must not pop the transport HUD),
and a `keep_vbuf` ack is **not** a completion — a menu→menu hop fires `load_flush` only, so
such an ack leaves the arm open and the watchdog fires the fallback, which is right,
because by then we are in a menu where a re-align is not possible anyway.

### 6.4 Leg 2 — a garbage sequence header must not flip a raster verdict

`pal_detect_dec` latched a new verdict on **any non-zero** `core_vertical_size`. The
2026-09-03 hold fix (§3.3) only masked the `== 0` case, so a garbage height — the 186-wide
popups a mid-VOBU flush produces — still flipped `pal_eff` from a single header. That
matters because the modeline walk keys on `il_eff | pal_eff | filmp_eff` but **only
`il_eff` carries a flush**: a flipped verdict restarts the raster mid-drain, and through
`film_det = pal_eff ? det_pal : det_ntsc` → `filmp_eff` it can restart it again. That is
the self-feeding loop, and `filmp_eff` flips on **either** standard — which is the NTSC
path, and the reason `pal_eff` is an amplifier here rather than the cause.

`dvd/pal_detect.sv` adds a **plausibility bound** (64…1152 lines — a bound, not a whitelist
of {240,288,480,576}: the core plays flat `.mpg` files too, and 1080 is not a multiple of
16) and a **sustained-disagreement** requirement to CHANGE an established verdict. The
first plausible header after a mount still latches immediately, so PAL detection is not
delayed at load. The `!= 0` hold is subsumed, not dropped.

⚠ **The confirmation is a TIMER, not a count of sequence headers.** That design was
written first and is wrong: `vertical_size` is a **register**, not an event stream — a real
disc re-parses a sequence header every GOP but writes the *same* value, so the register
does not change and there is no observable header event to count. A transition-counting
rule can never reach N for a genuine change and would freeze the verdict forever. Counting
time against the value actually in force has neither problem and is the right shape anyway:
garbage is transient, a standard is persistent.

### 6.5 The deferral window, and the pre-planned round-2 lever

`il_eff` is combinational off the OSD bits, so at the moment the user commits, the raster
(and `VGA_F1`, `CE_PIXEL`, the pixrep overlay inverses) still changes with zero delay,
**exactly as before**. Only the *flush* moves — to `seek_ack`, which is one outstanding
block completion plus one probe read (tens of µs to a few ms; an RBN seek forces
`snat_l = 0`, so there is no `vbuf_empty` drain wait), worst case the 0.5 s watchdog. For
that window the new raster shows the old timeline's already-decoded frames. Nothing needs
holding: the overlay is briefly squashed and `VGA_F1` briefly toggles on a progressive
raster, both sub-frame, neither able to wedge the decoder.

⚠ **No `modeline_boot_tb` phase was added, deliberately.** The walk is *not* gated on
`realign_pend`, so this change does not touch it; the existing bench passing unchanged is
the evidence for that, and a new phase would test behaviour nothing altered.

**If a hardware round still shows the freeze**, the flush is exonerated and the remaining
suspect is the **raster restart**. The next step is then to gate `il_out` on
`~realign_pend` so the walk and the flush land together on the VOBU boundary — one hold
register and one mux. It is deliberately **not** in v1: one behavioural delta per round is
what makes a round diagnostic (§3.9).

### 6.6 Residual, stated plainly

On a **raw** MODE2/2352 `.bin` (VCD/SVCD) the seek target round-trips through
`ls_sec = r − r/8 − r/256 − r/1024` (`dvd_iso_reader.sv`), which biases ≈ **−0.07 %**, so a
re-align lands slightly early — up to ~2–3 s of rewind at the end of a 74-minute image. It
is the same landing every VCD scrub already produces. Accepted and documented rather than
corrected: a 32-bit inverse-bias adder is not worth the area on an 88 % fit. Flat
`.mpg`/`.VOB` is exact (`strm_blk <= ls_tgt`) *and* arms the `00 00 01 BA` pack hunt — a
perfect re-align. A raw `.m2v` elementary stream is not seekable at all and takes the
fallback.

### 6.7 Gates

`bash bench/dvd/run_mode_realign.sh` (`--red` runs the pre-fix arms first, failures
expected):

| bench | what it proves | RED evidence |
|---|---|---|
| `mode_realign_chain_tb` | the real reader over a synthetic disc: one mode edge fired mid-VOBU, then **the first bytes delivered after the flush** | pre-fix `b0 b0 b0 b0` (mid-sector cell payload); fixed `00 00 01 BA / BB / BF` |
| `mode_realign_tb` | 11 scenarios: the seek, the target, the fallbacks, the stale table, coalescing, the scrub arbitration, the mount cancel, the held scrub | 15 checks fail on `+realign=0`; **both "no re-align possible" controls pass in BOTH arms** |
| `pal_detect_tb` | 8 scenarios, counting **verdict EDGES** | `+hyst=0`: 12 walk kicks in a garbage burst, 2 for one stray header |
| `iso_reader_seek_tb` TEST9 | the probe walk is 1 read/sector, so an on-NAV target is a single-probe snap | measured 3 / 4 / 8 reads |

⚠ Two bench-construction notes worth carrying forward. `pal_detect_tb` originally checked
**end states** and the pre-fix rule PASSED the stray-header and churn scenarios, because it
self-heals on the next real header — the harm is the *transient*, since every verdict change
kicks the walk. And `mode_realign_tb`'s first version failed all 11 scenarios against
correct RTL: blocking stimulus assignments landed **on** the clock edge and raced the DUT,
so every count read 0. Stimulus is driven from the negedge now, sampling from the posedge.

### 6.8 The switch blank (2026-09-03) — ✅ HW-CONFIRMED

Fixing the freeze left the transient visible, and the maintainer's HW round named it
exactly: switching **to Interlaced** gives *"a full screen rolling image flashing between
black frames"*; switching **to Progressive** *"squishes the image into the top half of the
screen"*. The first is the display losing vertical lock across the raster change; the
second is field-height content in a frame-height DE window. Both are inherent to changing
the raster under in-flight content — you cannot make the frames already in the pipe correct
for the new mode — so the fix is cosmetic by construction: hold the picture **black** until
the first frame of the new mode is on screen.

**The window needed no new measurement.** `video_live` already is that signal: the
re-align's own `load_flush` re-arms it (through `pickup_hold` in `resample_addrgen`), so it
goes LOW at the flush and HIGH again when the governor picks up the first frame for
display. `dvd/mode_realign.sv` owns the window because it already knows both endpoints.

⚠ **The rule is "clear on the first HIGH *after* a LOW", and the ordering is the whole
trick.** At the edge itself `video_live` is still HIGH — it belongs to the OLD content, and
the flush only lands a few ms later. A naive "clear when `video_live`" would clear
immediately and blank nothing at all. `mode_realign_tb` [13] is that exact trap, and
mutating the RTL to drop the requirement fails six checks.

**`BLANK_MAX` (~1.5 s) is load-bearing twice.** In the **menu domain** `video_live` never
drops — emu forces the STD mux-lead hold off while `menu_active` (menus aren't lip-synced),
so `pickup_hold` never rises and nothing re-arms it; the ceiling is the only exit there.
And it bounds the cosmetic fix so it can only ever hide a **transient**: if the roll or the
squish ever outlived the window the artifact must come back into view rather than be masked
forever.

**Three placement decisions, all in the `emu.sv` output-mux priority chain:**

- **After `cc_on`** — the line-21 caption waveform still goes out. It lives in the VBI,
  outside DE, and blanking it would kill captions for a second on every switch.
- **After `ov_on` / `dbg_px_q`** — the `DEBUG_OVERLAY` rows and the release-visible `O[2]`
  diagnostic blocks stay readable. `blk10` of the `O[2]` third row *is* the "il_switch
  fired" readout; hiding it exactly when a switch happens would blind the one instrument
  pointed at this event.
- **Before `sub_r`** — picture, subtitles, HUD and idle logo go dark together, which is the
  intent: everything content-derived at once.

⚠ **RGB only. Sync is untouched.** Dropping sync across a raster change is the
`re_interlace` `S_HUNT` defect (§3.2): it emitted no sync at all while hunting, costing
33–67 ms of dead CRT sync per event, and it lengthens the display's lock-up instead of
hiding it.

★ **The MiSTer OSD is composited DOWNSTREAM** (`sys_top`: `emu` → `scanlines` → `osd` →
pins), so the menu the user is standing in when they flip the setting stays fully visible
over the black. That is what makes a full-screen blank acceptable rather than alarming.

⚠ **`blank_en` (= `media_seen`) keeps it off until the first mount.** `il_eff_q` resets to
0, so an Interlaced/Auto-analog rig pulses one `il_switch` at reset release — without the
gate that would black the idle screen for the whole ceiling, and "nothing on screen after
the core loads" is precisely what the launch-feedback work exists to prevent
(`docs/idle_screen.md`).

★ **A second edge mid-blank RESTARTS the window** — the opposite of the seek arm, which
coalesces. Riding the old window would uncover the transient the second toggle just caused.

⛔ **"Repeat the last good frame" was the other candidate and lost**, despite the machinery
already existing (the governor's persistence re-scan, `repeat_frame=31`, as used by pause
and `hold_freeze`). Three reasons: the Interlaced symptom is a **roll**, i.e. the display
has lost lock, so a held frame rolls too — a rolling still is no better than a rolling
picture, whereas rolling *black* is invisible; the re-scan goes back through the same
mode-dependent scan path that produces the Progressive squish, and the held image was built
for the OLD mode, so it is not obviously immune to the artifact it is meant to hide; and it
needs the coordinated hold set (watchdog suppression et al.), where freezing video without
audio for ~1 s diverges the timelines the flush just re-anchored. Blanking acts at the
**pin**, after every mode-dependent path, so it is immune by construction.

**Gate:** `mode_realign_tb` [12]–[17], and — because these are cheap assertions about a
level, exactly the shape that passes without proving anything — **mutation-checked**: five
targeted RTL mutations (clear without requiring the drop, no ceiling, no `blank_en` gate,
coalesce instead of restart, no mount clear) are each caught by the scenario written for
them.

**HW round (2026-09-03, `DVD_swblank_20260903_1638.rbf`): ✅ better — the roll and the
top-half squish are gone.** The maintainer's verdict on what remains is the useful part:

> *"there are still some visible glitches but I think these are more decoder issues than
> mode switch since it looks similar to when a chapter skip is performed"*

★ **That observation is the fix's own success criterion being met, and it should be read as
a result rather than as a leftover.** §6.3's whole design was to make a mode switch
*byte-identical to a chapter jump* — same trio, same VOBU-boundary landing, same reader
contract. Once it is, a mode switch cannot have a class of artifact that a chapter seek
does not: anything still visible is generic **seek re-lock**, i.e. a pre-existing item that
belongs to the transport, not to `Video Output`. The symptom matching a chapter skip is the
observation that relocates the remaining work. (It is an observation of appearance, not a
measurement — but it is the right shape, and it is the same reasoning that closed §3.9:
when a build changes X and the symptom persists unchanged, X is exonerated.)

**The residual was tracked as [issue #45](https://github.com/owenb321/MiSTer_DVD/issues/45)**
— *"Macroblocking for ~6 frames after any seek: reference frames survive the VBUF flush"* —
and is **✅ FIXED and HW-CONFIRMED 2026-09-03 (branch `fix/seek-reference-realign`, build
`DVD_seekrealign_20260903_1901.rbf`): `docs/seek_realign.md`.** What remains at a landing
is a freeze followed by ~1 misaligned frame — the truncated in-flight picture, which was
predicted before the build and is a different defect class from the stale prediction this
fixed. Measured there from a 60 Hz HDMI
recording: ~6 frames (~100 ms), on all four transport paths and every disc tried, with the
target chapter decoding and in motion while the old scene bleeds through as residual. That
last detail is what identifies it — motion compensation against stale references, not a
corrupt picture.

⚠ **This note originally named `motcomp_picbuf`'s `prev_i_p_frame_valid` as the root
cause. That is only the DISPLAY half, and it is the smaller one.** The slots themselves
carry **no valid bit at all** — `forward_reference_frame` / `backward_reference_frame` are
pure pointers that `motcomp_addrgen` reads unconditionally — so what produced the reported
*moving* residual is the landing GOP's leading B-pictures predicting from the surviving
slot, which clearing a display flag does nothing about. The fix is one layer up, in
`rtl/mpeg2/vld.v`: drop the landing GOP's leading predicted pictures until two post-flush
anchors have re-established the references. Why *two*, and why the picbuf-side clear cannot
be made to work from outside the mvec FIFO, are both in `docs/seek_realign.md`.

**The original note, kept because it is the reasoning that got there:** `flush_ctl`'s trio discards
*buffered* data but deliberately leaves the decode pipeline's state — `vld`/`getbits`/
`motcomp`/`picbuf` are all on `sync_rst`, and `mount_flush` (the decoder soft reset) is
MOUNT-ONLY, "NEVER on seeks/jumps/mode switches ... where the display must hold the last
frame and the reference frames are same-file valid". So across any seek the in-flight
picture still "completes" on the new stream's first start code (one truncated frame), and
the previous references stay flagged valid — an open-GOP VOBU then motion-compensates its
first B-frames against frames from the *old* position. Same mechanism as the mid-play mount
garbage (`docs/av_sync.md`), just bounded, because within one title the references are at
least same-file.

⛔ **SUPERSEDED (2026-09-03) — the proposal below was to extend `mount_flush` to the mode
switch. Issue #45 was fixed in the vld instead, which covers all four transport paths
rather than this one. Retained as the FALLBACK if the re-align proves insufficient on
hardware.** ★ *The switch blank changes the cost/benefit for the mode-switch case
specifically.* The stated reason not to soft-reset on a seek is *display continuity* — the
screen must hold the last frame while the decoder re-locks. During a blanked mode switch
there is no display continuity to protect: the screen is black by design. So adding
`mode_switch` (the fallback leg) **and** the re-align's `seek_ack` to `mount_flush` is
arguable for this path alone, and would remove the truncated frame as well as the stale
references. ⚠ Two things to design against before trying it: the soft reset asserts
`sync_rst`, which drops `dec_ready` and gates the modeline walk (§3.2's boot race) — the
regfile is on `hard_rst` so the walk's writes survive, but the interaction wants a
`modeline_boot_tb` phase before a build; and chapter skips would still be untouched, so it
fixes the symptom on one path while leaving the class open. **That last objection is
exactly what sent the fix to the vld:** the class is shared, so the fix should be too.

## 7. Follow-ups
- ✅ **A/V SYNC after a `Video Output` change — FIXED BY PR #63, confirmed by the
  maintainer 2026-09-10.** A mode change no longer costs lip sync and a chapter skip is
  not needed. The manual's "skip a chapter to clear it" advice was retired with the
  v0.5.0 release (`reference/troubleshooting.md`, `video/interlaced.md`).
  ⚠⚠ **THIS MARKER READ "OPEN" FOR THREE DAYS AFTER THE FIX MERGED, AND IT MISLED A
  RELEASE.** `docs/stc_freerun.md`'s own defect table lists *"Video Output change skews,
  cured by a chapter skip"* as one of the things the free-running STC was built to
  fix — so the two notes contradicted each other, and the release doc sweep found the
  contradiction, could not resolve it from the repo, and shipped the stale user-facing
  advice rather than guess. **The fix and the marker were in different files, and only
  the fix moved.** Exactly the failure `CLAUDE.md` "Update status markers when a feature
  completes" exists to prevent: update the marker in the SAME change, including markers
  in OTHER notes that the change falsifies.
  ★ **The original diagnosis recorded here was right, and is worth keeping** — the
  "cured by a chapter skip" detail pointed at `av_sync` rather than the raster, since a
  skip re-anchors the STC; the suspect named was the refresh-rate change itself
  (`TICKS_PER_REFRESH` / `refresh_50hz` picked from the mode). PR #63 deleted the
  refresh-counted STC and `TPR_Q16` outright, which is that mechanism removed rather
  than repaired. The layer was identified correctly and the rewrite reached it first.

- **✅ Blank the video during a `Video Output` switch — IMPLEMENTED 2026-09-03 (user
  request after the issue #42 HW round; ⏳ HW-confirm pending).** See §6.8. The proposal
  that was recorded here is now the shipped design; the reasoning that survived is in §6.8
  including why "repeat the last good frame" lost.
- The same ugliness on an **Analog Aspect** change is NOT covered: per `docs/field_parity.md`
  that walk issues no flush at all, so there is no `video_live` re-arm to key on and the
  blank would have to invent its own trigger. Nobody has reported it; left alone.
- **`pal_detect_raw` reads `> 480` as PAL, so a 720p or 1080i flat `.mpg` already reads
  PAL** and gets a 50 Hz STC tick rate plus the PAL modeline. That predates issue #42 and
  is unchanged by it — `dvd/pal_detect.sv` altered *when* a verdict may take effect, never
  *what* a height means, so those files behave bit-identically. Tightening to
  `(v == 576) || (v == 288)` would change the raster for content that currently works and
  nobody has reported, so it is deliberately not bundled.
- **`sif_h_dec` / `sif_v_dec` are the same class as the old `pal_detect_dec`**: raw
  `core_horizontal_size` / `core_vertical_size` behind only a `!= 0` guard, driving the
  2× fill. A garbage 288 mid-title flips the fill. Issue #42 left them alone to keep one
  variable per hardware round; the plausibility bound from `dvd/pal_detect.sv` is the
  ready-made fix if a report ever points here.
- **The `vsz_s2` / `hsz_s2` overlay-crop geometry** reads the same raw sizes. Lower risk
  (a wrong value is a misplaced overlay, not a raster restart), same remedy.
- Done in round 2 (user decision): the idle logo moves on every FIELD tick in Interlaced
  (`dvd/idle_logo.sv`; the old every-other-field divider made it half speed on the CRT).
- Native 13.5 MHz dot pacing (720-wide internally) — only if a reason appears; needs the
  overlay query-lead constants re-tuned (`HUD_QX_ADJ`, `BAR_QX_ADJ`, `LOGO_QX_LEAD`,
  `SP_QX_ADJ`, `crt_ov_map`, `cc_vbi`).
- Apply the analog half-line to `VGA_VS` as well when `csync_en` is low, for RGBHV rigs
  (§3.9) — nobody has reported one, so it is unbuilt.
- ~~Equalizing pulses outside vsync (needs the vsync position in advance)~~ — **DONE,
  §3.10.** The premise was wrong: it needs the vsync position in advance *of the framework
  csync module*, which the core has had all along.
- ~~Re-test the 2H serration question with instrumentation~~ — **superseded by §3.10.**
  It is now a selectable arm (`P1O[47:46] Analog CSync`) rather than a rebuild, and the
  §3.8 trade is measured in `csync_field_tb` rather than inferred. ⏳ **Still wanted from
  hardware:** the RetroTINK 4K's pixel clock / vsync length / lines-per-frame / frame-rate
  readout on each arm — that readout is exactly what the Discord reports were quoting, and
  it is the one number that turns the bench's separator models into a field measurement.
- Progressive 480p on the analog pins keeps the dot-0 vsync reference (no field
  ambiguity there); anchoring it too is a one-line follow-up if a 31 kHz display objects.
