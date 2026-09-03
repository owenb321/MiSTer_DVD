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

⏳ Not yet gated: PAL on an analog CRT (no PAL CRT available), RGBHV, and
`direct_video=1` through an HDMI DAC. (The field-parity coin flip that was open here is
✅ fixed and HW-confirmed — `docs/field_parity.md`.)

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

**What the residual most likely is, for whoever picks it up.** `flush_ctl`'s trio discards
*buffered* data but deliberately leaves the decode pipeline's state — `vld`/`getbits`/
`motcomp`/`picbuf` are all on `sync_rst`, and `mount_flush` (the decoder soft reset) is
MOUNT-ONLY, "NEVER on seeks/jumps/mode switches ... where the display must hold the last
frame and the reference frames are same-file valid". So across any seek the in-flight
picture still "completes" on the new stream's first start code (one truncated frame), and
the previous references stay flagged valid — an open-GOP VOBU then motion-compensates its
first B-frames against frames from the *old* position. Same mechanism as the mid-play mount
garbage (`docs/av_sync.md`), just bounded, because within one title the references are at
least same-file.

★ **And the switch blank changes the cost/benefit for the mode-switch case specifically.**
The stated reason not to soft-reset on a seek is *display continuity* — the screen must
hold the last frame while the decoder re-locks. During a blanked mode switch there is no
display continuity to protect: the screen is black by design. So adding `mode_switch` (the
fallback leg) **and** the re-align's `seek_ack` to `mount_flush` is now arguable for this
path alone, and would remove the truncated frame and the stale references. ⚠ Two things to
design against before trying it: the soft reset asserts `sync_rst`, which drops `dec_ready`
and gates the modeline walk (§3.2's boot race) — the regfile is on `hard_rst` so the walk's
writes survive, but the interaction wants a `modeline_boot_tb` phase before a build; and
chapter skips would still be untouched, so it fixes the symptom on one path while leaving
the class open. Not attempted; recorded so the next session starts from here.

## 7. Follow-ups
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
- Equalizing pulses outside vsync (needs the vsync position in advance — a 3-line video
  delay or a hint from the modeline walk), if a set ever needs them.
- **Re-test the 2H serration question with instrumentation.** The maintainer has a
  RetroTINK HDMI scaler on order that reports pixel clock, vsync length, lines/frame and
  frame rate for analog inputs. That is exactly the readout the two Discord reports were
  quoting, and it makes the §3.8 trade measurable on a bench rather than inferred:
  line-rate serrations (what ships) vs 2H, against both a CRT and a width-based
  separator.
- Progressive 480p on the analog pins keeps the dot-0 vsync reference (no field
  ambiguity there); anchoring it too is a one-line follow-up if a 31 kHz display objects.
