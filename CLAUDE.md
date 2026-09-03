# MiSTer DVD Player Core — Claude Code Context

## Project Overview

This project is a **DVD player core for the MiSTer FPGA platform (DE10-Nano / Cyclone V)**,
built as a fork of [`mrchrisster/MiSTer_MPEG2`](https://github.com/mrchrisster/MiSTer_MPEG2).

The goal is to extend the existing working MPEG-2 video decoder into a full DVD player,
adding Program Stream demuxing, UDF/IFO navigation, AC-3 and DTS audio passthrough/decode,
and CSS decryption — all while keeping the proven FPGA video pipeline intact.

See `docs/` for detailed reference on architecture, audio, and implementation roadmap.

---

## Documentation Discipline (read before starting work)

Every non-trivial design decision **must** be written down — either in this `CLAUDE.md`
or in the `docs/` folder. Code without recorded rationale is treated as incomplete.

- **Where to put it:**
  - `CLAUDE.md` — durable, project-wide rules, conventions, and high-level decisions an
    agent needs *before* touching code (architecture choices, toolchain pins, workflow).
  - `docs/architecture.md`, `docs/audio.md`, `docs/roadmap.md`, `docs/references.md` —
    detailed, subject-specific design notes, data flows, FSM descriptions, and rationale.
  - Per-module status (e.g. the `ps_demux.sv` "Status & design decisions" block below) —
    a short summary lives in `CLAUDE.md`, full detail goes in `docs/architecture.md`.

- **When to write it:** at the same time as the code, not "later." Commit docs together
  with the change that motivated them.

- **What to record:** the *why* behind each decision, known limitations / TODOs, design
  alternatives that were rejected (and why), and anything that surprised you or wasn't
  obvious from reading the code.

### Leave a trail to resume work in a new session

Sessions are stateless — after a feature branch merges, the next session starts cold and
has only the committed markdown to go on. Before finishing any feature, ensure the docs
leave enough hints to pick up cleanly:

- Update the relevant **status block** (what's implemented, what's wired in, what isn't)
  and the ✅/❌ checklists in "What Already Works" / "Known Gaps".
- Record the **next concrete step** so the following session knows where to start
  (e.g. "Not yet wired into `emu.sv`" tells you the wiring is the next task).
- List **known limitations** explicitly (e.g. `length == 0` PES not handled) so they
  aren't rediscovered the hard way.
- Cross-reference: point from `CLAUDE.md` summaries to the detailed `docs/` section, and
  name the relevant files/modules/testbenches so they're easy to locate.
- Keep `docs/roadmap.md` current — it's the canonical "what's next" across sessions.

### ★ Keep the user-facing docs current (mandatory — README.md + `site/` are the contract)

There are now **three** documentation surfaces with three different jobs. Putting text in
the wrong one is itself a documentation bug:

- **`README.md`** — the landing page. What the core is, honest status, how this was built,
  a 3-step quick start, licensing, and where to read more. Deliberately short (~155 lines).
  **It is not the manual — do not grow it back.**
- **`site/content/`** — the **user manual**, published to
  <https://owenb321.github.io/MiSTer_DVD/> by `.github/workflows/docs.yml` on every push to
  `main` that touches `site/**`, `mkdocs.yml`, `tools/docs_check.py` or `dvd/emu.sv`.
  Every user-visible detail lives here: controls, every OSD setting, on-screen messages,
  analog/CRT modes, closed captions, audio passthrough, VCD/SVCD, physical discs,
  compatibility, troubleshooting.
- **`docs/`** — engineering design notes. **NOT published, NOT user documentation.** Never
  send a user from README or the manual into `docs/` as if it were a manual page. When a
  `docs/` note contains genuinely user-facing material, *harvest* those sentences into
  `site/content/` — the note keeps its own copy for the engineering context.

**Whenever a change invalidates or adds to a user-visible statement, update the manual page
in the SAME change** — and the README too if it touches something the README still states
(the feature list, the six headline limitations, the install steps). A page that lists a
shipped feature as a limitation, or vice versa, misleads every user and evaluator who reads
it: treat it exactly like a stale status marker — a documentation bug, fix on sight.

| Change | Update |
|---|---|
| New codec / format / resolution | `reference/compatibility.md`, `audio/formats.md`; README "What works" if headline |
| Limitation removed or discovered | `reference/compatibility.md`; README bullet if headline |
| New or changed OSD option | `playback/settings.md` — **enforced by `tools/docs_check.py`** |
| New gamepad button | `playback/controls.md` — **enforced** |
| New accepted file extension | `getting-started/loading.md` — **enforced** |
| New on-screen message string | `playback/on-screen-messages.md` **and** `reference/troubleshooting.md` |
| New user-facing tool in `tools/` or `main/Scripts/` | its owning page (e.g. `customising/idle-logo.md`, `formats/physical-discs.md`) |
| New install step or release asset | `getting-started/install.md`, `getting-started/what-you-need.md`, README quick start |
| New external reference worth crediting | `about/acknowledgements.md` |

**Two checks, run both before committing anything under `site/content/` or touching
`CONF_STR`:**

```bash
python3 tools/docs_check.py     # OSD options/buttons/extensions <-> manual parity
mkdocs build --strict           # broken cross-link = build failure
```

CI runs exactly these. `dvd/emu.sv` is in the workflow's `paths:` filter precisely so that
adding an OSD option without documenting it fails **even when no doc file was touched**.

⚠ `tools/docs_check.py` parses the `CONF_STR` block by walking to its matching brace and
stripping comments. Do **not** "simplify" it to a grep: `emu.sv` carries commented-out
CONF_STR history further down the file (a retired `Direct Video` row among others), and a
loose grep invents options that do not exist. That mistake was made by hand while writing
the manual and nearly shipped three fictional OSD settings.

**Mark unreleased features.** The site is built from `main`, so it documents the
development build while readers run a release. Anything not yet released gets an
`!!! info "Unreleased"` admonition, and `extra.released_version` in `mkdocs.yml` drives the
announcement bar. The release process bumps it and sweeps the stale admonitions.

**Authoring rules** (full set in `site/README.md`): keep `.md` extensions on cross-links so
pages resolve in MkDocs *and* natively on GitHub; links to repo files must be absolute
`https://github.com/owenb321/MiSTer_DVD/blob/main/…` URLs, because `strict` rejects
anything escaping `docs_dir`; prose must never depend on an image.

(Instituted 2026-08-24 after the MPEG-1/MP2 feature landed while the README still said
"MPEG-1 video is not supported". Extended 2026-09-01 when the manual moved to `site/` and
the parity check made the OSD surface mechanically enforced.)

### ★ Update status markers when a feature completes (mandatory — a stale marker is a bug)

The docs went stale once (2026-07-09 reconciliation, PR after fj#93) because status wording
was written at branch-creation time and never updated when the PR merged — so a whole batch
of shipped, HW-confirmed menu work (PR fj#84–fj#90) still read "sim-verified, HW gate pending"
and misdirected a "what's next?" session. To prevent recurrence:

- **When you complete or merge a feature, update its status markers in the SAME change** —
  both `docs/roadmap.md` and any per-feature status header in `docs/` (e.g. section headers
  in `docs/dvd_menu_refinements.md`, `docs/dvd_nav.md`, `docs/dvd_vm.md`).
- Flip the marker to reality: `🔧`/`❌`/`[ ]`/"sim-verified, HW gate pending" →
  `✅ MERGED (PR #NN)` and, once the board test passes, `✅ HW-CONFIRMED`. If merged but not
  yet hardware-tested, say exactly that (`⏳ HW-confirm pending`) — don't leave it reading "gate pending".
- **Retire dead branch names.** A merged feature must not still point at a live `feature/*`
  branch in prose — replace it with the PR number.
- Treat a lingering `🔧`/"HW gate pending"/`feature/*` reference on shipped work as a
  documentation bug: fix it on sight. When in doubt about true status, reconcile against
  `tea pr list --state closed` (what actually merged), not the branch name.

---

## Repository Structure

```
MiSTer_DVD/
├── CLAUDE.md                  ← you are here
├── docs/                      ← ENGINEERING NOTES — not published, NOT the manual
│   ├── README.md              ← says exactly that, for anyone who browses in
│   ├── architecture.md        ← full system design & data flow
│   ├── audio.md               ← AC-3, DTS, LPCM audio strategy
│   ├── roadmap.md             ← phased implementation plan
│   └── references.md          ← key repos, specs, libraries
├── mkdocs.yml                 ← docs_dir=site/content, site_dir=.site-build
├── site/                      ← USER MANUAL (source, not build output)
│   ├── content/               ← the manual's markdown — published to GitHub Pages
│   │   ├── getting-started/   ← install, what-you-need (tier matrix), images, loading
│   │   ├── playback/          ← controls, settings, on-screen messages
│   │   ├── video/             ← film 24p, analog/CRT, interlaced, closed captions
│   │   ├── audio/             ← formats, bitstream passthrough
│   │   ├── formats/           ← VCD/SVCD, physical discs
│   │   ├── customising/       ← idle logo (boot.rom)
│   │   ├── reference/         ← compatibility, troubleshooting
│   │   ├── about/             ← building from source, acknowledgements
│   │   └── assets/img/        ← screenshots (drop-in; pages carry placeholders)
│   ├── overrides/             ← Material partials: announce bar, 404
│   ├── requirements.txt       ← pinned mkdocs-material
│   └── README.md              ← local preview + authoring rules
├── .github/
│   └── workflows/docs.yml     ← build + deploy the manual on push to main
├── rtl/                       ← UPSTREAM: existing mpeg2fpga decoder (do not modify)
├── sys/                       ← UPSTREAM: MiSTer framework (do not modify)
├── dvd/                       ← YOUR NEW RTL MODULES go here
│   ├── ps_demux.sv            ← Program Stream demuxer (build this first)
│   ├── audio_ring.sv          ← Audio frame ring buffer to HPS
│   └── iec61937_wrap.sv       ← Future: IEC 61937 wrapper for S/PDIF
├── hps/                       ← RETIRED. The HPS audio daemon's C sources were deleted in
│                                 the pre-release cleanup; only two stale compiled ARM
│                                 binaries remain tracked (~1.7 MB). Nothing builds or
│                                 uses them — candidates for deletion.
├── main/                      ← MiSTer_DVDcss overlay (custom Main: physical disc + CSS)
│   ├── support/dvd/           ← drive probe, CSS via libdvdcss, encrypted-image source
│   ├── Scripts/               ← install_dvdcss.sh, set_dvd_region.sh (ship in releases)
│   └── build_main.sh          ← fetch stock Main, apply overlay, cross-compile
├── bench/
│   └── dvd/                   ← Simulation testbenches for new modules
│       ├── ps_demux_tb.sv
│       └── test_vobs/         ← Sample VOB hex extracts for sim
└── .vscode/
    └── settings.json
```

> **`docs/` and `site/` are not the same thing and must not be merged.** `docs/` is the
> engineering record and **keeps its name permanently** — it is referenced ~593 times across
> 109 files, 194 of those inside RTL and `.qsf` comments, so renaming it would smear a
> documentation move across the whole hardware tree. `site/` is the user manual. Note that
> MkDocs' *default* output directory is also called `site/`, which is why `mkdocs.yml` sets
> `site_dir: .site-build` — never let a build write into `site/`, and **never add a bare
> `site/` line to `.gitignore`** (the stock MkDocs snippet does exactly that, and it would
> silently untrack the manual).

**rtl/ may now be modified directly (rule relaxed 2026-06-24, by user decision).**
The earlier "never modify `rtl/`" rule was dropped: chasing the 256-line strobe needs
debug ports and fixes threaded through deep upstream modules (`resample_addrgen`,
`resample`, `mpeg2video`, `mixer`, `syncgen`), and `dvd/` copies of 1700-line files are a
worse maintenance burden than targeted in-place edits. So:
- Editing `rtl/mpeg2/*` is allowed. Mark debug-only additions clearly (e.g. `// DVD-FORK
  DEBUG`) and functional fixes with `// DVD-FORK FIX`, and write down the rationale (docs).
- `sys/` still edited only when unavoidable (see the SDRAM exception below); prefer additive.
- The `dvd/mem_override/` include-shadow mechanism and existing `dvd/` copies (e.g.
  `dvd/resample_addrgen.v`, swapped in the `.qsf`) remain valid and are fine to keep using.
- Mergeability with upstream `mrchrisster/MiSTer_MPEG2` is no longer a hard constraint.

> **Historical note (SDRAM-module port, restore + removal):** `sys/sys_top.v` and `sys/sys.tcl`
> were once edited to *restore* the SDRAM routing so the fork could drive the 128 MB add-on board
> via `dvd/sdram.sv`. That path is now RETIRED — the core's memory runs entirely on the HPS
> f2sdram (DDRAM) burst bridge (`dvd/mem_shim_burst.sv`). As of 2026-07-01
> (branch `feature/remove-diagnostic-cruft`) the SDRAM controller, its self-test, and all
> `SDRAM_*` ports/pin assignments were removed from `dvd/emu.sv`, `sys/sys_top.v`, `sys/sys.tcl`,
> and `DVD.qsf`, taking `sys/` back toward stock. See `docs/history.md`.

---

## Toolchain

- **Quartus:** 17.0.2 exactly — newer versions break MiSTer project compatibility.
  Can be a native install **or** the pinned Docker image `raetro/quartus:mister`
  (Quartus 17.0.2 Build 602 Lite — the exact pinned version). Prefix any build command
  with `USE_DOCKER=1` and it re-execs inside that container (`tools/docker_reexec.sh`,
  wired into `build_release.sh` + `tools/seed_sweep.sh`): repo bind-mounted at its real
  host path, host UID/GID (artifacts stay host-owned), memory unbounded. E.g.
  `USE_DOCKER=1 ./build_release.sh --compile`. Override the image with
  `QUARTUS_DOCKER_IMAGE=...`. NOTE: fitter SEEDs are tied to the EXACT synth/map netlist
  produced by a given Quartus version — the Docker image is the same 17.0.2 Build 602 as
  the canonical native install, so seeds/fmax reproduce; a *different* Quartus version
  would require a seed re-sweep.
- **Device:** Intel Cyclone V (5CSEBA6U23I7) — the DE10-Nano FPGA
- **HDL:** SystemVerilog (`.sv`) for new modules; upstream uses a mix of Verilog + VHDL
- **Simulation:** Icarus Verilog (`iverilog -g2012`) for module-level testbenches
- **HPS compiler:** ARM cross-compiler for the Cortex-A9 (or native compile on MiSTer)
- **IDE:** VS Code with `mshr-h.verilog` and `TerosHDL` extensions

---

## Hardware status (THIS fork, verified 2026-06-21)

- 🔧 **SINGLE-RASTER ANALOG OUTPUT — the second raster (`re_interlace`/VGA2) is
  RETIRED; the interlaced MAIN raster carries the N64 half-line and drives the CRT
  directly (2026-09-03, branch `feature/single-raster-analog`). ✅ HW-CONFIRMED on the
  maintainer's rig: HDMI and the composite CRT both clean, no jumpy image, steady
  `720x480i @ 59.9` (build `DVD_n64model_20260903_0148.rbf`, SEED 5, clk_dec 93.01/88.94).
  Design + post-mortem: `docs/single_raster_analog.md`.**
  ★★ **THE DEFECT USERS REPORTED WAS THE FIELD-PARITY CORRECTOR (PR #37), NOT SYNC.**
  MEASURED from screenshots by splitting each woven frame into its two fields and
  correlating: with the corrector on, consecutive fields carry the SAME source lines
  (offset **+0.00** frame lines; a correct interlaced still measures **+0.50**) — weave
  combs on a STILL and bob jumps a field line, on HDMI and the CRT alike. v0.3.0
  `Analog Out = Native Fields` (same authored-fields content path, no corrector) measures
  +0.50 and is clean. This branch tied `par_ins` 0; the corrector is now ✅ **REPAIRED,
  re-enabled and HW-CONFIRMED** — see the field-parity bullet below and
  `docs/field_parity.md`.
  ★ **FIVE HW ROUNDS WERE SPENT ON THE WRONG LAYER; the rules that earns are in
  `docs/single_raster_analog.md` §3.9 and worth reading before the next hunt:** (1) when
  a build changes X and the symptom persists, X is EXONERATED — round 4 had no half-line
  on the main raster and still combed, and that disproof sat unused for two more rounds;
  (2) the user's "does the old build do this?" A/B outranks any amount of RTL reading;
  (3) measure the artefact (the screenshot correlation took minutes and no hypothesis
  survived it). ⚠ **`bench/dvd/field_parity_tb.sv` COULD NOT SEE the defect**: its
  behavioural framestore returns a CONSTANT word (no displayed pixel carries evidence of
  which source line it came from) and its pass condition is the SAME EXPRESSION as the
  RTL's `frame_top_par_err` — a golden model that agrees with its RTL by construction
  (the POST-only PGC trap again). Replacement: `field_phase_tb` (LINE-STAMPED
  framestore, per-field measurement of what the mixer EMITTED, consecutive fields must
  differ and repeat with period 2). ★ **And the perturbation that finally exposed the
  corrector was the MUNDANE one:** every scenario written from the field reports (seeks,
  cold start, cadence breaks) passed with it on — the defect only appeared once the bench
  STARVED the pixel queue, which is what this compute-bound core does several times a
  second on real content. When a bench exonerates the code the hardware indicts, ask what
  the hardware does all the time that the bench never does.
  ★ **The raster is the N64 model, on ONE raster** — halfline 429/432 in the interlaced
  modeline, doubled 2x (not 2x+1) by `syncgen_intf` to 858/864 = exactly half the line,
  with the 262/263 alternation ⇒ vsync exactly 262.5 lines apart EVERY field, so Main
  reports a steady 59.94 and a CRT interleaves. This is what N64_MiSTer and PSX_MiSTer
  put on their single raster (and `syncgen.v`'s model was copied from N64's
  `VI_videoout_sync.vhd`). ⚠ Rounds 3–5 briefly wrote halfline 0 and synthesised the
  half-line in `sys_top`'s `csync` instead — both detours REVERTED; `csync` is stock.
  ⚠ 2H serrations were also tried (they equalise the two fields' broad pulses, 27/27 µs
  vs 50/18 µs — the measured shape behind the RetroTINK "vsync length toggling" report)
  and REVERTED: the composite CRT was worse with them. Two lines to re-add if a rig needs
  it — `docs/single_raster_analog.md` §3.8.
  Deleted with the second raster: `dvd/re_interlace.sv` (~10 M10K line buffer + a second
  `sync_gen` + a lock FSM that emitted NO sync at all while hunting), the `sys_top.v`
  VGA2 block, `re_interlace_tb`. Line-21 CC moved into **`dvd/cc_vbi.sv`** on the main
  raster's VBI (the `sys_top` VGA scanlines DE gate dropped — it killed the waveform once
  on VGA2; emu's output stage now blanks outside DE itself). ⏳ CC is sim-proven only on
  this path — HW gate.
  ★ **Also fixed en route (all mechanically real, from the field reports):** (1)
  `syncgen_intf`'s modeline copies were on `dot_rst`, which the WATCHDOG and mount soft
  reset pulse — `sync_reg` zeroes them async, so the running `sync_gen` saw
  `horizontal_length=0/interlaced=0` for a few dots and RE-PHASED (~1.2 s cadence at
  81 MHz); now on `dot_hard_rst` like the regfile (`modeline_boot_tb` [4]: RED 3/6 field
  pairs broken with the old wiring, GREEN 0/6). (2) `pal_eff` was live off the decoded
  `vertical_size` (0 after any reset ⇒ a PAL disc read NTSC ⇒ double walk) — held now.
  (3) `analog_want` was COMBINATIONAL off Main's live cfg word while its comment claimed
  a latch (Main re-sends cfg on every `video_mode_adjust`/OSD leave/`[video=]` re-parse ⇒
  a changed bit = a full `il_switch` mid-play, the likeliest "toggle = crash") — latched
  via new `hps_io.cfg_seen`, follows while nothing is mounted, frozen while a disc plays.
  (4) Progressive + analog-direct wrote the 875×1287 @ 23.976 Hz film modeline to the
  pins — `filmp_eff` also gated on `~analog_want` (HDMI-only rigs keep Film 24p); that is
  the reported "Progressive loses signal when playback starts". (5) Idle window
  off-by-ones (VER_RES 479→480, H 1441→1440 via the 2x doubling) — idle now reports
  `720x480i`, no load-time resolution popup (which itself made Main re-send cfg).
  (6) `CE_PIXEL` = one clock per pixrep pair in Interlaced (Main reports **720x480i**,
  ascal samples 720 real pixels; the analog waveform is bit-identical since the DAC never
  used the enable) — native 13.5 MHz dot pacing was NOT done (every overlay query-lead
  constant assumes one dot per clock). (7) idle_logo moves every FIELD in Interlaced
  (was half speed). `O[2]` gained a third-row trigger readout (watchdog / il_switch /
  pal edge / vsize 0 / cfg re-write) visible whenever Interlaced.
  ★ **HW round 6 sweep (all ✅):** line-21 CC on the new `cc_vbi` path, overlays /
  subtitles / menus / HUD on the analog output, sub-720 fill (VCD/SVCD/MPEG-1), Analog
  Aspect Letterbox+Crop, PAL content, steady `720x480i @ 59.9`. Two findings: (a) the
  `~analog_want` film gate was over-blunt — it removed the only way to watch 24p over
  HDMI with the CRT off, and it never bit anything else (Auto already resolves such a rig
  to Interlaced), so it now applies to the AUTO verdict only and `Film 24p Out = On`
  overrides it; (b) ⚠ **PAL + a mid-title `Video Output` change can FREEZE the decoder**
  (malformed frame, never self-recovers, a chapter seek clears it, either direction,
  intermittent) — **PRE-EXISTING: v0.3.0 does the same on an `Analog Out` change**, so it
  is NOT from this branch. Analysis + fix direction (re-align the reader to the next NAV
  pack instead of flushing in place — the same mid-stream-flush trap as the reverted
  film switch, `docs/film_24p_plan.md` §13): `docs/single_raster_analog.md` §6.
  ⏳ Not gated: PAL on an analog CRT, RGBHV, `direct_video=1` through an HDMI DAC, and
  the parity coin flip (the maintainer's late-model CRT has never shown it — the two
  Discord reporters' older sets do, so the corrector fix leans on `field_phase_tb`).
- ✅ **FIELD-PARITY CORRECTOR REPAIRED AND RE-ENABLED (2026-09-03, issue #41, branch
  `fix/field-parity-corrector`) — sim-proven RED/GREEN and ✅ HW-CONFIRMED: round 1 gave
  the CRT ("always gets the fields right on the TV" where PR #40 was a coin flip) and
  exposed an inverted `VGA_F1`; round 2 confirmed that fix
  (`DVD_parityf1_20260903_1253.rbf`).**
  ★★ **ROUND 1 ALSO EXPOSED AN INVERTED `VGA_F1`, and only determinism could:** with the
  phase now fixed, HDMI Weave went from a coin flip to CONSISTENTLY COMBED while the CRT
  became consistently right. Two outputs disagreeing by exactly one field pins it to the
  FLAG, not the corrector — the analog pins never read `VGA_F1` (the raster half-line
  carries the CRT's interleave). `sys/ascal.vhd` latches the flag at every DE rise and the
  write-placement decision reads it in the SAME clocked process on the field's first
  active pixel, so it uses the value from the PREVIOUS field's last line ⇒ the effective
  convention is **F1 = 0 on the TOP field**. `emu.sv` emitted `~core_v_pos[0]` (1 on top)
  ⇒ ascal stored the top field in the odd rows = a pairwise line swap = Weave combing on
  a STILL. Now `core_v_pos[0]`, ✅ HW-confirmed. ⚠ Unfalsifiable while the parity was random — HDMI was
  right half the time — and the line's own comment had said "polarity may need flipping on
  HW" since it was written. ⚠ **Not sim-gateable here**: ascal is VHDL, the benches are
  Icarus.
  ★ **Root cause of the withdrawal: the FEEDBACK arm was chasing STARVATION.** Its cure
  is a REPEATED field (re-showing `last_image` is the only insertion that lands the
  resumed stream aligned — see the XOR note below), and it was firing at field rate,
  because when the pixel queue runs dry the mixer displays nothing at that frame-top
  opportunity and every following content field lands one raster slot later. That IS a
  genuine parity error — but this core is compute-bound and does it repeatedly, so the
  error churns, and one repeated field per starve is a far worse picture than the
  half-line offset it removes. The old `par_armed` + **4-refresh** liveness re-arm
  permitted an insertion every five refreshes = exactly the measured +0.00.
  FIX = the feedback arm only acts on a **STABLE** error: `PAR_CONFIRM` (30 refreshes,
  ~0.5 s) of a continuously-asserted verdict, plus `PAR_HOLD` (120 refreshes, ~2 s) as a
  hard budget so a repeated field can never appear more often than that whatever the
  starvation rate is. `par_age` starts saturated so the cold-start landing is not
  delayed. The FEED-FORWARD arm (`alt_break`) is unchanged and ungated — it inserts the
  OPPOSITE field, can never repeat one, and it is the arm that handles the reported
  chapter-skip symptom. Gate: **`bench/dvd/field_phase_tb.sv`** (finished here; it was
  committed unfinished by PR #40) + `run_field_phase.sh`, 7 windows × 2 raster phases.
  Measured, not asserted: 4 starvation events cost **4** repeated fields with the shipped
  corrector, **0** with the gate and **0** with the corrector off. Detail:
  `docs/field_parity.md`.
- 🔧 **VIDEO OUTPUT CONSOLIDATION + FIELD-PARITY RE-ENGAGE FIX (2026-09-02, branch
  `feature/video-output-consolidation`) — sim-proven (RED/GREEN), ⏳ HW-confirm pending
  (gate = the two CRT field reports below reproduce clean).** Two CRT field reports
  (SuperStationOne→YPbPr→Sony CRT; a second user on The Shining) exposed (a) the weave
  analog path "extremely wobbly" = the known caveat-2 pairing defect, and (b) Native
  Fields going "super aliased" after chapter skip/FF/aspect changes, healed only by
  toggling the mode 3–4 times = a 50/50 parity roll. **(1) THE PARITY BUG — root-caused
  and FIXED (`docs/field_parity.md`):** the mixer's relaxed frame-top matcher (the
  3:2/drop black-fields fix) accepts either raster parity slot, and nothing carried
  raster parity back to `resample_addrgen`'s pickup — one odd perturbation (seek tff,
  raster restart, cold start) flipped content-field↔raster-field phase PERMANENTLY
  (invisible under HDMI Bob, glaring on fieldpass/Weave). Fix = feed-forward
  `alt_break` (schedule head would repeat the last field's parity) + feedback `par_fb`
  (new `mixer.frame_top_par_err` → sync_reg → addrgen), inserting ONE held-frame field
  and deferring the pickup one refresh (`pickup_go`), with a `frame_late` pulse so the
  drop ledger reclaims it. ★ **The triggers compose by XOR and the inserted field's
  TYPE depends on the trigger** (alt_break: OPPOSITE field; par_fb: SAME field; both at
  once: insert NOTHING — the break itself lands aligned): "insert opposite on either"
  livelocks — alt_break un-fixes every par_fb insertion. Suite
  `bench/dvd/run_field_parity.sh` — the checker reads the mixer's frame-top acceptance
  hierarchically (what the SCREEN gets); proven RED on pre-fix RTL (a break's
  misalignment persists 16/16 tops and survives a CLEAN seek = the toggle-ritual
  mechanism) and GREEN post-fix (feed-forward arms: zero wrong fields ever displayed;
  feedback arm: ≤2). ⚠ `gov_field_late_tb` needed a stimulus fix, not an expectation
  fix: real discs TOGGLE tff after an rff picture; holding it constant is an authored
  cadence break the corrector now rightly heals. **(2) SETTINGS CONSOLIDATED (user
  decision, reversing the 2026-08-23 "all four modes stay" review — see
  `docs/roadmap.md`):** `O[10:9] Interlaced Out` (+ its `det_video` Auto detector) and
  the 4-value `O[27:26] Analog Out` are REPLACED by ONE option **`O[10:9] Video Output
  = Auto/Interlaced/Progressive`** (`Interlaced` = the old Native Fields renamed —
  authored fields session-wide, fieldpass analog raster, HDMI 480i via ascal Bob/Weave;
  `Auto` = ini-driven `analog_want`, boot-static; `Progressive` keeps Film 24p and
  serves 480p-analog displays). `re_interlace.sv` is FIELDPASS-ONLY (weave/derive
  deleted — CRT-480i-plus-progressive-HDMI simultaneity deliberately dropped:
  pick-your-output); `analog_eff`/`il_eff` collapse into one `interlaced_eff`; config
  layout `"v,1"`→`"v,2"` (all saved settings reset once). O[27:26] left dead/reserved.
  Detail: `docs/field_parity.md`, superseded headers in `docs/interlaced_auto.md` +
  `docs/analog_dual_raster.md`.
  ★ **HW ROUND 1 (2026-09-02) found a LATENT BOOT RACE the consolidation was first to
  arm: Interlaced-at-boot showed "719x...i @ 31.48 kHz" + dead CRT — the modeline walk
  keys on RAW reset_n while the decoder synchronizes its resets INTERNALLY
  (reset.v cascaded 5-FF stages), so hard_rst (gating every regfile modeline register)
  deasserts ~5-10 clk_dec cycles later and the boot walk's writes were SILENTLY
  SWALLOWED — progressive raster + VGA_F1 toggling, and il_prev latched so nothing
  retried.** Invisible since the walk was built: il_eff was always 0 at boot (a
  swallowed walk wrote the reset defaults anyway) and every change came via OSD with
  the decoder alive — `Auto` from the ini bits is the first boot-time walk that
  matters. FIX = `dec_ready` gate (kicks wait for `core_sync_rst` = the decoder's own
  `sync_rst_out`, the LAST reset to deassert, observed high 8 cycles). Proven
  RED/GREEN by `bench/dvd/modeline_boot_tb.sv` over the REAL `reset.v` + `regfile.v`
  (RED reproduced BOTH failure shapes: total swallow = the exact HW symptom, and
  partial application; the OSD-toggle control passes un-fixed — why no prior HW round
  ever saw it). ⚠ Lesson: any emu-side logic writing decoder REGISTERS around reset
  must gate on `sync_rst_out`, not `reset_n` — the walk was the only such writer.
  ★ HW round 2 (`DVD_videoout2`, user report): a MID-TITLE switch to Interlaced now
  works cleanly — indirect HW evidence for the parity corrector (pre-fix that exact
  raster restart was a coin-flip perturbation, the source of the old "set it before
  loading" advice; the manual now says the switch works with a chapter-seek-style
  interruption).
- ✅ **MID-PLAY LOAD A/V DESYNC — FIXED IN FABRIC; ✅ HW-CONFIRMED 2026-08-28 (user
  report: mid-play loads across VOB/mpg/ISO/VCD cut to black, start clean, hold sync;
  T2 logo chain clean; seeks/menus/cold mount unregressed; build
  `DVD_mountflush2_20260828_1537.rbf`). The companion FILM-ENGAGE flush was
  attempted and ⛔ REVERTED after a T2 HW regression — that skew stays OPEN, owned by
  the planned early-film-detect feature.** The rule both bugs share: a playback
  discontinuity needs the FULL FLUSH TRIO (seek/vbuf + load + aud) or audio phases
  against the wrong video timeline. **Mount fix (kept):** loading a new file mid-play
  fired load_flush + aud_flush but NOT the VBUF flush — the old "Seek-only; clip-load
  path untouched" exclusion predated the lip-sync v5 video_live re-arm, which turned
  the surviving 0.5–2 MB old-file VBUF into a PERMANENT audio lead (STC anchors on the
  new file, governor displays old frames; forward skew < 15 s never re-anchors; only a
  core reload avoided it). `start_streaming` now fires the trio, keep_vbuf-ungated.
  **Film-switch attempt (reverted):** a bare `filmp_eff` XOR edge into `mode_switch`
  broke T2's menu→Play Dolby/THX logo chain — the logos flap the detector, each flap
  flushed at an arbitrary mid-stream position (no reader jump = no VOBU re-alignment),
  garbage seq headers (186-wide popups) flipped pal_eff (25 Hz) which feeds back into
  film_want = a self-feeding corruption/strobe loop. ⚠ il_switch's fire-on-edge
  pattern is only safe for ~once/title signals; a filmp edge oscillates and the flush
  perturbs the parse the detector feeds on. Full post-mortem + the reintroduction
  requirements (hold-suppression + holdoff, T2 logo chain as HW gate):
  `docs/film_24p_plan.md` §13. Also shipped: flush glue EXTRACTED to
  `dvd/flush_ctl.sv` + `bench/dvd/flush_ctl_tb.sv` locks the 11-row trigger matrix
  (proven RED against the pre-fix logic); `frame_drop_ctl` debt now clears on
  `flush_vbuf_eff` (carried-in stale debt could fire spurious B-drops post-seek/mount).
  **Mount decoder SOFT RESET (same branch, follow-up HW round):** the trio flushes
  BUFFERS only — the decode pipeline (vld in-flight picture, reference frames, picbuf)
  survives on sync_rst by upstream design, so a flat-file load showed MACROBLOCK
  GARBAGE (truncated picture + new file's open-GOP B-frames motion-compensated against
  the OLD file's references; DVD first cells are closed-GOP which is why ISOs looked
  better). Fix: `flush_ctl.mount_flush` (mount ONLY, never seeks — those need display
  continuity) → `mpeg2video.soft_flush` → new `reset.soft_rst_n` leg = the exact
  watchdog-expiry soft reset (regfile/modeline on hard_rst SURVIVE — the HW-proven
  recovery path); a warm load now cuts to black and starts as cold as a core reload.
  Post-mortem + deferred items (detector re-arm, vidfeed_cdc): `docs/av_sync.md`
  "Mid-play mount desync post-mortem".
- ✅ **FILM MODE FLAPPING — FIXED BY AN EVIDENCE GATE; ✅ HW-CONFIRMED 2026-08-30
  (build `DVD_filmevidence_20260830_1720`: APOLLO_13's credits no longer flap, T2 holds
  sync in Auto, and FERRIS_BUELLER follows its own mid-title film→video change IN SYNC).**
  ★ **The defect was never engage LATENCY — it was mode FLAPPING.** MEASURED on APOLLO_13
  in DISPLAY order (coded order hides it behind B-reordering): **9 engage/disengage flips
  in 46 s**, each re-walking the modeline and re-locking ascal. Near-black pictures are
  **100 % `progressive_frame==0`** (384 B against that title's own 17,704 B median).
  ★★ **THE FRAMING THAT SOLVED IT: `progressive_frame` is not a measurement — it is a bit
  the ENCODER wrote**, and on a near-black picture there is no field structure to describe,
  so the encoder takes the MPEG-2 default and marks it interlaced. The detector counted
  that meaningless claim at `DN_HARD=8`. VLC's IVTC survives the same content because it
  reads PIXELS and discards uninformative frames as evidence ("If no motion, the result
  from this algorithm cannot be reliable ... we do nothing"). **FIX = an informativeness
  gate on CODED PICTURE SIZE** measured in `vld.v`, carried to the display as a fourth
  per-picture attribute through `motcomp_picbuf`, where an uninformative pickup updates
  NOTHING in the detector — not the confidences, not `rff_q`.
  ⚠ **The threshold must be RELATIVE, per picture coding type, with a warm-up** — all three
  forced by measurement, not taste: HIGH_SCHOOL_MUSICAL codes a **318 B median** (its small
  pictures ARE its content; a fixed threshold discards 55 % of the disc and delays its video
  verdict 17 s), a black I-frame codes 7,580 B where a real one codes ~82,000 B (tiny for an
  I, above any threshold that does not also eat legitimate B-frames), and seeding the mean
  from whichever picture arrived first made two rips of near-identical content gate 0.0 %
  and 85.8 %. ⚠ **Ordering gotcha:** size is known only at picture END, so this CANNOT ride
  `flags_commit` (which fires at the coding extension near the START) — `informative_commit`
  pulses at the terminating start code, still strictly before picbuf rotates slots.
  ⚠ **Count `next_advance`/`next_align`, NOT the registered `advance`/`align`** — vld.v
  forces those to 0 whenever `clk_en` is low, so a clk_en-gated block reads 0 almost always;
  that made every picture measure 0 B, which is SILENTLY INERT (a zero mean compares equal,
  so everything reads "informative") and would have shipped as a no-op.
  ⛔ **A PER-TITLE LATCH WAS TRIED AND IS NOT THE ANSWER** (abandoned, unpushed): it works on
  APOLLO_13 but costs **12 s to leave film mode**, which FERRIS_BUELLER's film→video special
  feature makes unacceptable. ⛔ **`frame_pred_frame_dct` is NOT a usable substitute** — it
  looks perfect on APOLLO_13 and reads 0 for ~99 % of pictures INCLUDING progressive ones on
  FERRIS/AUSTIN_POWERS_2, so a detector keyed on it calls film VIDEO within two seconds. It
  is an encoder rate setting, not a content property. Library sweep: **15 better, 0 worse
  over 123 discs**. Golden model `tools/film_evidence_probe.py`; suite
  `bench/dvd/run_film_evidence.sh` (`film_evidence_tb` runs the REAL vld over REAL disc
  bytes and checks size AND verdict against the golden — a hand-driven vld model would only
  check one's reading of the FSM). Detail: `docs/film_24p_plan.md` §14.
  ⚠ **Separate, still OPEN:** APOLLO_13 plays **~800 ms audio-ahead**, established at the
  FIRST anchor of a playback and cleared by any re-anchor (chapter skip). NOT detection, NOT
  the raster switch (`Film 24p = On` shows it too), and NOT the VBUF cap (Shallow changed
  nothing). An imported "anchor the STC on the screen" fix made it WORSE (1800 ms + stream
  freezes) and is not merged — see `docs/av_sync.md` "HW round 3" before touching it.
- ✅ **MEM_SHIM_BURST TAG/LRU STORE → M10K — the ALM congestion reclaim (2026-08-27,
  PR #18) — ✅ HW-CONFIRMED 2026-08-28 (user soak: full-length MiB + menu/seek stress,
  no shear/artifacting; build `DVD_shimreclaim_20260828_0259.rbf`).**
  The designated congestion-relief project: post-PR#17 the design sat at 98% ALM and
  the last two branches each needed fit-rescue work. `dvd/mem_shim_burst.sv` (4,899
  ALMs — the tag/valid/LRU flop store + per-set 128:1 async muxes, the recurring
  LUT-RAM pattern) now keeps tags + LRU ranks in two sync-read M10Ks (by-set words);
  valid bits stay flops. The hit loop grew to 3 overlapped stages (still 1 word/cycle);
  misses/writes issue from the verdict cycle (fast entry — miss timing matches the flop
  version; TB pure-miss meter improved 26→25 cyc/resp). **Replacement policy is
  BIT-EXACT true LRU**, gated by the new A/B TB `bench/dvd/mem_shim_ab_tb.sv` (live
  module vs a FROZEN flop-tag copy on one trace, independently-stalled rigs, accepted-
  burst sequences must be identical — 4/4 combos, 1,351 identical misses). Suite:
  `bench/dvd/run_mem_shim.sh` (all green). Fit: module 4,899→~1,406 ALMs (regs
  6,546→1,028, +3 M10K), **design 41,202 ALMs (98%) → 36,341 (87%)**; pinned SEED 5
  held FIRST roll, clk_dec 93.73/90.33 (gate 86.0). The HW soak mattered because this
  is the shear-fix module (sim cannot prove hit-rate-under-real-traffic) — it PASSED:
  entire MiB movie + menu/seek actions, no video issues, no shearing, no artifacting.
  Detail: `docs/history.md` §11.

- 🔧 **PIXELATED MENU STILLS — root-caused + fixed in fabric (2026-08-26, branch
  `fix/picbuf-display-slot-alias`); ✅ HW-CONFIRMED 2026-08-27 (user report: Harry Potter
  artifacting GONE, no regressions on other discs; build `DVD_picbufalias`).** A menu/game still could come up
  **blocky, "like it hasn't finished loading"** because the decoder was writing the new picture
  **into the frame slot the display was scanning out**. `rtl/mpeg2/motcomp_picbuf.v` guards its
  `current_frame` (:268/:278) and `prev_i_p_frame` (:355) updates with `~vld_last_frame`, but the
  **fwd/bwd reference swap (:322/:327) was not guarded** — so at every `sequence_end_code` the
  slot pointers rotated one extra step, `STATE_LAST_FRAME` put that slot on screen while clearing
  `prev_i_p_frame_valid`, and the next sequence's first I both targeted the displayed slot AND
  took `STATE_IP_FRAME_0`'s `~output_frame_valid` shortcut (:164) past the anti-overwrite
  handshake. **Fix = add `~vld_last_frame` to the swap** (the alias becomes structurally
  impossible: `fwd`/`bwd` are always a distinct {0,1} pair and `output_frame == prev_i_p_frame
  == bwd` at a sequence end). This is an **upstream mpeg2fpga bug** — the file was untouched
  since import. Sim: new `bench/dvd/motcomp_picbuf_tb.sv` ([A] still→still fails pre-fix, passes
  post-fix; [B] video→still control; [C] boot-deadlock guard) + a `` `ifdef CHECK `` assertion now
  live in the module. ⛔ **Do NOT instead gate the `STATE_IP_FRAME_0` shortcut on slot
  inequality — it DEADLOCKS the core** (`dvd/resample_addrgen.v:543` gates pickup on
  `output_frame_valid`, which is 0 in exactly that scenario, so `output_frame_rd` never arrives).
  ⚠ **Scope is honest and narrower than the symptom:** measured over 70 real cells of the Harry
  Potter Interactive disc, every `still_time=255` still is `SEQ GOP PIC:I SEQ_END` (so a still
  arms the collision for whatever decodes next ⇒ still→still navigation collided every time)
  while every video/transition cell ends on a coded B (⇒ never armed). So this does **not**
  explain the reported jump-vs-natural asymmetry, nor a multi-second artifact — yet on HW the fix
  cleared ALL observed artifacting on the disc, so those observation-level discrepancies closed with it. Also learned: that disc's stills are **title-domain**, and the menu-still cold
  re-decode (`dvd_iso_reader.sv:4017`) is `menu_dom`-gated, so it never ran there at all — a
  separate, deliberately deferred item. Detail: `docs/dvd_menu_refinements.md` §5.
  A follow-up **audit of the rest of the upstream decoder found no further fix-now
  defects** — findings + the audited-clean list: `docs/decoder_audit.md`.

- ✅ **LAUNCH FEEDBACK TRIO — HW-CONFIRMED 2026-08-26 (5 HW rounds; PR #9 +
  the follow-up rounds PR); design + full history: `docs/idle_screen.md`.**
  Shipped as release v0.1c. HW rounds delivered on top of the original trio:
  bounce-box art trim, logo-behind-OSD, the QX query-lead SIGN fix (subtract
  like SP_QX_ADJ, not add like the HUD -- the centred boxes hide the shift),
  the PNG converter rewrite (background-aware, box-averaged --fit, refuses
  tiny results), the 256x64 logo ROM (4 M10K, per-logo 1x/2x scale, fmt-0
  back-compat), and OSD R0 Reset actually wired (status[0] consumed by
  nothing since the fork began -> now ORs into reset_n: unload + VM reset +
  back to the logo; boot.rom logo and the OSD one-shot survive by design). (1) **Config
  versioning**: CONF_STR `"v,1;"` → settings persist to `config/DVD_v1.CFG`;
  bump N on any incompatible O[..] relayout (resets ALL options — re-audit
  index-0 labels when bumping). (2) **Startup OSD popup**: `BUTTONS` was
  wrongly an INPUT since the fork began (canonical = output; b[0] = the
  virtual OSD button) — now a wait-then-pulse `osd_btn` pops the file picker
  ~1 s after a bare load (mount-suppressed, one-shot, NOT the console-core
  hold idiom: menu.cpp fires on the RELEASE edge so a mid-window MGL mount
  would pop it anyway — the pulse form cancels instead). (3) **Idle screen**:
  `dvd/idle_logo.sv` bouncing-logo screensaver while nothing is mounted
  (1 M10K two-bank ROM, user bitmap via `/media/fat/games/DVD/boot.rom` —
  `tools/idle_logo.py` converts PNGs; never-garbage is structural: writes
  are bank-1-gated + exact-length commit). Rode in with an area-reclaim
  pass: dead mpeg2fpga OSD tied off (~300 ALM + 7 DSP + 5 M10K) and
  `dvd_vm`'s 11 parallel `eval_reg` register-file muxes shared down to 3
  (~1k ALM; ⚠ the gprm[] reads must stay DIRECT array expressions — a
  function-mediated word read loses array sensitivity and broke type 4's
  compare-after-set; see the ⚠ note in dvd/dvd_vm.sv). Decoder >576-line
  support was investigated for removal and found NOT worth it (HD costs
  DDR3 + counter widths, not fabric — the big decoder M10Ks are
  latency-tuning FIFOs).

- ✅ **POST-ONLY PGC DISPATCH + FORCED-SELECT ON A NEW HLI — two nav bugs from
  user-submitted discs (2026-08-30, branch `feature/postonly-pgc-and-fosl`);
  ✅ HW-CONFIRMED 2026-08-31 (build `DVD_navfix_20260831_0029`) — fix (1) fully,
  fix (2) PARTIALLY (see below).** Reports: The Residents Commercial DVD *"doesn't allow you
  to enter the maze / picks Play All whatever you choose / LINK FAIL"*, Dinosaur
  *"LINK FAIL, navigation issues preventing progress"*, Scooby-Doo 2 *"floor maze
  starts the player in the wrong position"*.
  **(1) A 0-CELL PGC IS NOT A DEAD END — it runs its POST.** libdvdnav `play_PGC()`
  falls to `play_PGC_post()` when `nr_of_programs == 0`, and menu discs use exactly
  that as the **button dispatcher**: every button carries the SAME `LinkPGCN`, and the
  target PGC (0 cells, 0 pre) reads `HL_BTNN` in its POST to decide where the press
  goes — so **SPRM8 is the only carrier of the user's choice**. Killing that PGC
  collapsed every option onto one destination AND raised LINK FAIL. Fixed at the three
  `dvd_vm.sv` "0 cells ⇒ dead end" sites (enter `BLK_POST` when `nr_post != 0`;
  `nr_post == 0` keeps the TP_SW dead-end recovery) + the `dvd_iso_reader.sv`
  `S_PGC_CELLCHK` gate (`cmd_nr_pre || cmd_nr_post` — its LinkPGCN-follow scan walks
  PRE commands ONLY, so a POST-only stub fell to `pgc_error`).
  ⚠ **`tools/dvd_vm_ref.py` HELD THE SAME WRONG ASSUMPTION**, so the golden model could
  not have caught this — it was written from the RTL and agreed with it. **libdvdnav
  (`tools/bin/trace_*`) is the independent oracle; use it when a model and its RTL
  agree suspiciously well.** Scope (**505-disc sweep**; an earlier "15/122" in commit
  dbe5d57 used a NON-RECURSIVE glob that missed `interactive/` = the DVD games):
  **70 discs (14.3%)** have the strict 0-cell/0-pre/POST dispatcher, **178 (36.3%)** have
  a 0-cell PGC with any POST = the full affected population. Sweep: **499/505 landings
  unchanged, 6 changed — ALL SIX went from a HARD BOOT FAILURE to a healthy menu**
  (3 verified vs libdvdnav, one landing byte-exact; 3 ✅ HW-confirmed 2026-08-31; four had
  never been reported). **Zero regressions.** Corroborated by a TV box set outside the
  swept set (*"link failure on every menu option"*): 6 dispatchers per disc, boot landing
  unchanged, every button `pgc_error` pre-fix and resolving post-fix.
  ⚠ Library disc titles are deliberately NOT recorded here (maintainer preference); the
  per-disc rows are reproducible by re-running the sweep.
  Test `dvd_vm_tb` [S23] (real Residents PGCN 81 POST bytes; RED pre-fix).
  **(2) FORCED SELECT (`fosl`) applied only on a not-armed→armed edge** — `armed` reads
  its pre-assignment value, so `fosl` was dropped whenever one HLI replaced another
  while armed, which is what a title-domain game does VOBU to VOBU. Scooby's maze
  authors 4 auto-action compass buttons + an inert centre with `fosl=5`; losing it left
  the highlight on button 1 (= left), which **self-activated**. Now gated on
  `nxt_ss == 1` (NEW HLI), matching the `foac` commit; `ss=2/3` continuations stay
  excluded so it can't fight the player's D-pad. Tests `nav_pci_tb` T16 (RED pre-fix) /
  T17 (control). Detail: `docs/dvd_vm.md` "POST-only PGC dispatch", `docs/dvd_nav.md`
  "Forced select".
  ⚠ **fix (2) is PARTIAL — HW shows fresh maze entry now correct, but RE-ENTRY after a
  trap and the NEXT room still land on button 1 (auto-action = the player moves before
  any input).** Leading theory: those entries deliver the HLI as `hli_ss==2`
  (author marking "same button set"), which the fix deliberately excludes so `fosl`
  can't fight the D-pad mid-room; the rule likely needs to key on **the cell/PGC having
  changed**, not on `hli_ss` alone. NOT yet coded — verify against the byte sequence
  first (⚠ NAV packs carry a system header: PCI data starts at sector offset **0x2D**,
  not 0x15 — an early scan of mine silently found zero HLIs from that mistake).
  ⚠ **Still OPEN:** Scooby's **Whac-A-Mole** (not root-caused; NOT `foac` — reads 0
  disc-wide).
  ★ **RESIDENTS' MISSING AUDIO — ROOT-CAUSED, and it is NOT a nav bug: `dvd/ac3/`
  SUPPORTS ONLY acmod 2 (2/0) AND acmod 7 (3/2).** `bsi_parse.sv:167` sets sticky
  `err_unsupported` for anything else → `ac3_err` → ac3_front self-heal reset every
  frame → SILENCE. The Residents is **acmod 6 (2/2 quad)** on 310/314 frames; its maze
  rooms play because they are LPCM, which is exactly the split the user reported.
  ★★ **The same guard rejects acmod 1 (MONO)** — a much bigger catch, confirmed by HW
  (BBB-NTSC's special feature is silent) and an independent field report (*"Dolby Digital
  1.0 Mono … running without audio"*). 505-disc census: **26 discs** have an unsupported
  acmod on some track, **11 on a DEFAULT track** (9 mono + 2 quad), **2 AC-3-silent
  disc-wide**. Verified in-bitstream on four library discs (mono ×273, mono ×101,
  acmod 5 ×167, mono ×200). ⚠ Use the PES `first_access_unit_pointer` to locate
  the syncframe — a naive `0x0B77` search hits false syncs in payloads.
  ✅ **MONO SHIPPED (2026-08-31, branch `feature/ac3-mono`)** — `acmod 1` accepted;
  ⚠ its `B_MIXLFE` field is **lfeon ALONE = 1 bit** (no cmixlev/surmixlev/dsurmod
  for 1/0 — reading acmod 2's 3 bits would desync the rest of bsi); `nfchans = 1`
  in BOTH derivation sites (`ac3_parse` + `audblk_parse`); and new `pcm_out.mono`
  reads ch0 for L AND R because mono never writes pcm_mem ch1 (`ac3_front.acmod`
  had been left unconnected in `dvd_audio_decode` — it drives this now). Mono needs
  NO downmix (`dmx_en = nfchans > 2` is false), so its PCM path IS the stereo ch0
  path. Gate: `bench/ac3/vectors/bbb_mono.ac3` (Creative-Commons BBB extract)
  through the Verilator/liba52 cosim — exps/bap BIT-EXACT, PCM ≤0.5 LSB @ s16
  (tol 2.0); proven RED pre-fix (`acmod=-1 inscope=0 err=1`, zero frames produced).
  All 9 cosim vectors + 11 bench/ac3 suites + `dvd_audio_decode_tb` green.
  ✅ **HW-CONFIRMED 2026-08-31** (build `DVD_ac3fnfix_20260831_0452`): mono, 3/1 and
  2/2 discs all play; stereo and 5.1 unregressed.
  ★★ **THE BUG THAT COST THE MOST TIME HERE WAS NOT THE CODEC — IT WAS FIVE
  `function automatic` HELPERS THAT QUARTUS 17 MISCOMPILED SILENTLY.** acmod 1 and 5
  were SILENT on hardware while every sim gate stayed green (the cosim decoded real
  mono/acmod-5 disc streams BIT-EXACTLY for 400 frames). The helpers took only scalar
  args and read no arrays, and **Quartus emitted NO warning for any changed module**.
  ⚠ **The technique that cracked it, reuse it: A/B TWO OF OUR OWN BUILDS.** A real
  disc's mono track played on the earlier build (inline ternary) and was silent on the
  later one differing on that path ONLY by using functions — same RTL, different
  silicon. That is far cheaper than the post-map netlist cosim and was decisive.
  Fix = all five rewritten as plain wires/inline ternaries (`acmod_cmix`,
  `acmod_smix`, `acmod_mixbits`, and the two `nfchans` ternaries). Pre-existing
  functions elsewhere (`to_s16`, `bin2gray`, `bndtab`, `compute_mask`) ship fine —
  functions are not banned, but **when sim says correct and silicon says broken,
  suspect a recently-added function FIRST.** Memory: `verilog-function-hazards`.
  **Still unsupported (and "unsupported" means SILENCE, not distortion): acmod
  0/3/4/5/6** — only **2** library discs have such a DEFAULT track (both 2/2 quad)
  plus the Residents, whose entire AC-3 layer is acmod 6.
  Those need real multichannel downmix coefficients, unlike mono which needed none.
  All three bug ISOs are clean rips (`css_scan` 0 scrambled packs).
- 🔧 **FAILED MENU LINK RE-ENTERS THE MENU, NEVER THE MOVIE (2026-08-27, PR #17)
  — MERGED; HW no-regression pass 2026-08-27 (menus/boot unaffected); ⏳ the
  positive case (a disc whose menu link actually fails — the reporter's Blade
  Runner) is still the outstanding gate; sim fault-injection covers it
  meanwhile ([S22]).** Field report
  (Blade Runner): a language-menu "next page" arrow STARTED THE FEATURE — a failed
  menu-domain jump (`pgc_error`, e.g. a page-2 LinkPGCN out of the selected
  PGCI_UT language unit's range) fell through the VM's `fb == FB_NONE` chain to the
  auto-title. New arm in `dvd/dvd_vm.sv`: a failed MENU-destination link with a
  last-good menu **re-enters that menu** (`last_menu_*`, latched per menu-domain
  `pgc_loaded` — NOT the reader's live `cur_vts`, which has already moved to the
  failed target) + pulses `link_fail` → transport-HUD **`LINK FAIL nn`** popup
  (`pop_type 9`, menu-exempt). Second failure walks the existing FB_VTSM chain;
  boot/FP and title-destination failures keep the auto-title exactly as before.
  Also: `nav_pci` foac forced-ACTIVATE deleted (libdvdnav never implements it; it
  could start playback with no keypress), forced-SELECT hop kept one-shot; overlay
  **row 26 = reader `pgc_error` reason latch** (reason/nr_srp/want_pgcn — replaces
  the answered `dbg_promo` probe). Tests: `dvd_vm_tb` [S22], `transport_hud_tb`
  T21; golden `_jump()` in `dvd_vm_ref.py`. No local repro disc exists (431-ISO
  scan: zero out-of-range menu links; Goonies' unequal LUs check out) — validated
  by sim fault-injection; the reporter's disc is the HW gate. Detail:
  `docs/dvd_vm.md` "Failed-menu-link re-enter".
- ✅ **AUDIO LOGICAL→PHYSICAL STREAM MAPPING (2026-08-27, PR #17) —
  HW-CONFIRMED 2026-08-27 (user report: GET_SMART VTS 2 now has sound where it
  was silent — the decisive A/B; build `DVD_menulink_20260828_0153.rbf`,
  SEED 5, clk_dec 94.5/91.5, reached via the framestore mem-request-write
  RETIME, see the DVD.qsf ledger).** The track pick
  (SPRM1/SetSTN or the Audio button) is a LOGICAL stream number; the PGC's
  `audio_control[8]` table maps it to the PHYSICAL substream `ps_demux` filters on
  (libdvdnav `vm_get_audio_stream` + the first-available fallback). The old raw-index
  assumption silenced any disc with a non-identity map — the "language menu → movie
  plays with NO audio" field report (Blade Runner), and 31/431 library discs; local
  boot-silent repro = **GET_SMART VTS 2** (every logical → 0x83; HW A/B via the Debug
  Title VTS picker). Reader streams the table on the shared `pgc_ctl_*` bus (new
  `P_ACTL` phase, every domain — menus resolve logical 0 through it); new
  `dvd/aud_stream_map.sv` (32-FF store, identity when no PGC/table = legacy
  bit-identical); `aud_switch` gains a jump-window guard so PGC re-parses can't pulse
  `aud_resync` (menu audio continuity, §5d). Golden: `dvd_vm_ref.py aud_stream_map()`
  + `nav_extract.py --audio-map`; 2,026-vector bit-exact TB + reader/demux suites
  green. Detail: `docs/track_selection.md` "Logical→physical audio mapping".
- ✅ **IEC 61937 BITSTREAM NOW ALSO LEAVES OVER HDMI (2026-08-30, PR #25) —
  ✅ HW-CONFIRMED 2026-08-31 (DD + DTS decode on a real receiver over HDMI, route (i)).**
  ★ **The startup/track-change LOCK FLAP that shadowed it (pre-existing, both outputs)
  is ✅ FIXED + HW-CONFIRMED 2026-08-31 (branch `feature/bs-flap-probe`, build
  `DVD_bsflapfix2`): the ring drain watchdog read the wrapper's A/V-sync hold as a
  wedged consumer (it arms only on `frame_pop`), left the STD backpressure disengaged,
  and the ring dropped ~1130 frames in a title's first 46 s — each dropped span a
  forward PTS hole = a multi-second wire gap = the receiver flap.** MEASURED via
  DEBUG_OVERLAY captures + `tools/osd_read.py` (probe rows 23/24, muxed on Passthru).
  Fixes: `iec61937_wrap.hold_active_o` re-arms the watchdog (a deliberate hold is a
  live consumer), and the wrapper FREE-RUNS in the menu domain (`sync_armed &=
  ~menu_active` — a keep_vbuf menu hop's pre-anchor hold against the preserved
  old-timeline ring is a circular stall, measured wedged ~20 s; menus aren't
  lip-synced, same rule as the av_vid_hold menu exemption). HW: title start locks in
  seconds, track changes near-instant, T2/Matrix menu transitions smooth WITH audio
  (v0.2.0 dropped audio there), A/V sync good, optical + HDMI. Tried-negative worth
  keeping: NO hold fill (NonPCM/pause burst) holds this receiver's lock across
  authored menu silence even with clean streams — only real data bursts do ("digital
  black" canned silent AC-3 = possible future polish). `docs/iec61937.md` "FLAP ROOT
  CAUSE". `Audio Out = Passthru` used to be
  optical-only, so 5.1 needed the Digital I/O board. It doesn't: 61937 rides inside an
  ordinary 2-ch/48 kHz/16-bit IEC 60958 stream (1.536 Mbit/s — exactly AC-3's max), which
  is precisely what the DE10-Nano's single wired I2S line to the ADV7513 carries. (That one
  line is also why **multichannel LPCM is impossible** here — the board routes no other
  audio data pin; confirmed in its pin table.) `dvd/i2s_iec958.sv` serializes the SAME
  subframes `spdif_pass` biphase-encodes — one source, two link layers, so they cannot
  drift. ★ **Chosen route is IEC958-direct (`0x0C[1:0]=3`), NOT an I2C channel-status bit**:
  it is what mainline Linux uses for IEC958 subframes, and crucially it keeps the non-PCM
  flag **DYNAMIC**, preserving the fj#110 ROUND 2 fix (receivers cannot acquire across
  non-PCM null bursts) instead of pinning the flag high for a session. ★ **Stock Main is
  safe BY CONSTRUCTION**: the ADV7513's I2C is HPS-only, so a bitstream sent to a sink still
  expecting PCM is full-scale noise — the core therefore refuses to emit one without the
  `cfg[14]` ack that only MiSTer_DVDcss sets (after checking EDID Short Audio Descriptors,
  which stock Main never parses at all). ⚠ **The ack, not `pass_mode`, owns the HDMI audio
  format** — leaving Passthru is instant in fabric but the chip stays non-PCM until Main's
  next poll, so that window must be digital silence; Main sequences engage/release
  asymmetrically. ⚠ **MEASURED phase step:** the first pair interval after `rst_audio_n` is
  509 clk_audio, not 512 (`bit_ce` and `spdif_pass`'s counter re-align three cycles in), and
  that reset pulses on every audio-track switch and `aud_flush` — hence the ~100 ms hold-off.
  Tests: `bench/dvd/run_hdmi_bitstream.sh` — `iec61937_wrap_tb` TEST 9 (pacing exact over 513
  strobes) and `i2s_iec958_tb`, a **demodulator** that reads subframes back off the wire
  (it failed all four checks first run and the serializer was correct — the demod was
  free-running instead of framing on `ws`; a register-peek test would have proven nothing).
  ⚠ Open: the preamble nibble for IEC958-direct is an assumption (Z=1,Y=2,X=4) — first thing
  to change if HW round 1 mis-locks. Design: **`docs/hdmi_bitstream.md`**.
- 🔧 **AUDIO IS NOW DECODED IN FABRIC (2026-06-27, branch `feature/fabric-ac3-audio`).**
  AC-3 and LPCM are decoded entirely in the FPGA: `ps_demux` → `audio_ring` →
  `dvd/dvd_audio_decode.sv` (AC-3 via the ported `dvd/ac3/*` `ac3_front`+`pcm_out`,
  5.1→stereo downmix; LPCM via `dvd/lpcm_unpack.sv`) → `AUDIO_L/R` → framework I2S → HDMI.
  **No HPS daemon** — `hps/dvd_audio.c` and the DDR3 audio write chain
  (`audio_ddr_pack`/`cdc_req_ack`/`audio_ddr_issue`) are RETIRED (the `hps/` tree was
  deleted in the pre-release cleanup; `ddr_arb` audio master tied off). DTS is dropped for now (future:
  in-fabric IEC 61937 to the Digital I/O board). Toggle `O5 Audio` (default On). A/V sync
  still rides the **frame-rate governor** (`dvd/resample_addrgen.v`). Design in
  `docs/fabric_audio.md`; sim-verified (`bench/dvd/lpcm_unpack_tb.sv`,
  `bench/dvd/dvd_audio_decode_tb.sv`); **hardware confirmation pending.** Open follow-ups:
  HW confirm, LPCM 24-bit/96 kHz. DTS: no in-fabric decoder, but **IEC 61937 passthrough
  ✅ HW-CONFIRMED 2026-07-11 (PR fj#109)** — AC-3 + DTS both lock and play on a real
  receiver, A/V sync correct; see `docs/iec61937.md`. The earlier startup-lock / track-switch
  re-lock issue is **✅ FIXED + HW-CONFIRMED 2026-07-11 (PR fj#110)**: the receiver couldn't
  acquire across the Pc=0 non-PCM null bursts the producer emitted during A/V-sync holds, so
  the hold path now emits real **linear-PCM silence** (per-pair `nonpcm` flag → `spdif_pass`
  clears the non-PCM channel-status bit) — the receiver sees PCM then one clean PCM→DD/DTS
  switch, like a real player. Locks at startup + through track switching on all tracks.
  - **M19 AREA PASS (2026-07-11, branch `feature/ac3-area-reduction`).** The AC-3
    subtree had bloated to **9,378 ALMs — larger than the MPEG-2 video decoder
    (8,484)** — and the spdif branch FAILED to route at 91% ALMs. Cause: unconverted
    memory (the recurring LUT-RAM pattern): bit_allocation's `expc`/`dbc` register
    file + `baptab`/`latab`/`hthtab0` LUT ROMs (~3.0k ALMs), imdct_512's ~37 kbit of
    schedule/twiddle/window tables in LUTs (~3.3k ALMs), audblk_parse staging arrays.
    All converted to sync-read M10K (M19/M19b/M19c/M19d) + the downmix multipliers
    folded into the shared DSP bank (M19e, −6 DSPs). **Zero value changes** — gate at
    every stage = PCMDUMP byte-identical vs baseline + bit-exact bap cosim. Also
    fixed en route: `run_imdct/imdct256/drc` TBs had been silently FAILING since the
    M17 DRC fix (pre-M17 dynrng convention + vvp exit-0 masking; now `$fatal` on
    fail). Full detail: `docs/ac3_decoder_architecture.md` §4.11.
  - **AC-3 File Test (`O[12]`) — REMOVED 2026-07-01 (`feature/remove-diagnostic-cruft`).**
    This diagnostic loaded a raw `.ac3` elementary stream straight into `ac3_front`
    (bypassing ps_demux/audio_ring/av_sync, free-run NCO) to test the decoder decoupled
    from the pipeline. **Its finding stands: it HW-CONFIRMED (2026-06-28) that raw `.ac3`
    plays back clean, EXONERATING the in-fabric AC-3 decoder** — remaining VOB audio
    glitches are PIPELINE-side (ps_demux/audio_ring/av_sync/governor), not `dvd/ac3/*`.
    The toggle + `raw_mode` path + `.ac3` file handling were then removed as cruft
    (the decoder is proven; chase the pipeline).
  - **AC-3 reframer (static-pops fix, 2026-06-28, branch `feature/ac3-graceful-drop`):**
    new `dvd/ac3_reframer.sv` between `ps_demux` and `audio_ring` regenerates
    `aud_frame_start` on AC-3 `0x0B77` boundaries so the ring's drop unit is a WHOLE
    AC-3 frame — an overflow drop becomes a clean silent gap (`ac3_front` resyncs)
    instead of a non-aligned hole → self-heal reset → POP. Transparent passthrough
    (bytes reach `ac3_front` identical), no decoder change. Genlock-Off HW test
    (PR fj#40) proved the pop is INPUT-side overflow, not the output NCO — this targets
    that. Sim-verified (`bench/dvd/ac3_reframer_tb.sv` + `ac3_reframer_ring_tb.sv`:
    forced overflow, every committed frame starts `0B77`). **HW: v1 GREATLY REDUCED
    BBB pops but some remained (Matrix had none — just compute-bound stutter).** v2
    adds a `frmsizcod` FRAME-LENGTH LOCK so a coincidental in-payload `0x0B77` (~4% at
    640kb/s = the residual-pop cause) can't make a spurious boundary — only accepts a
    sync once a full frame is emitted. **✅ v2 HW-CONFIRMED 2026-06-28 (PR fj#41 merged):
    BBB pops GONE.** Static-pops saga closed; remaining BBB/Matrix artifact is
    compute-bound VIDEO stutter only ([[clock-lever-exhausted-matrix]]), not audio.
    See `docs/fabric_audio.md` §"AC-3 reframer".
- 🔧 **PTS-DRIVEN A/V SYNC (2026-06-28, branch `feature/av-sync-pts`).** Audio is now
  genlocked to the video presentation timeline instead of free-running. `dvd/av_sync.sv`
  builds a video-referenced System Time Clock (STC, anchored on `ps_demux.vid_pts`,
  advanced one `TICKS_PER_REFRESH` per displayed image — `refresh_tick` = `core_v_sync`
  edge in clk_sys) and soft-slews the 48 kHz audio NCO (`nco_trim`, ±0.5 %) so the
  dispatched audio PTS tracks the STC — like a DVD player slaving its audio DAC to the
  recovered STC. Per-frame PTS rides `ps_demux.aud_frame_pts → audio_ring descriptor →
  dvd_audio_decode.dispatch_pts → av_sync`. Seek (>0.7 s `vid_pts` jump) re-anchors
  cleanly. **Sim-verified** (`bench/dvd/av_sync_tb.sv` + extended `audio_ring_tb`,
  regressions incl. real-VOB `ps_chain` green); MERGED PR fj#36. **HW: runs; ships with a
  registered VGA output stage that HW-CONFIRMED fixed the placement-marginal output artifacts
  — column dots GONE and no green fringing (see memory `chroma-fringe-is-intermittent`, a
  recurring multi-session issue now likely cured).** Scope = pacing only: the PES-granular
  `audio_ring` drop (static-*pop*) and overlay surfacing of drift/trim are tracked
  follow-ups. Design: `docs/av_sync.md`.
  - **★ LIP-SYNC SAGA (2026-07-02/03, PR fj#60 MERGED — read `docs/av_sync.md`
    "WHERE THIS STANDS" + `docs/lipsync_pickup.md` before touching A/V sync).**
    Eleven HW rounds. SHIPPED + HW-PROVEN: STC references the SCREEN not the demux
    parse (`video_live` gate, one-sided re-anchor, per-load re-arm); playback phase
    set at the PCM-FIFO EXIT (drain gate + stale-skip + pre-anchor dispatch hold —
    drift telemetry went −455 ms → healthy +91 ms); **`P1O[23:21]` A/V Offset**
    (signed 18-bit, 0/−100..−500/+100/+200 ms, WORKS but binds at (re)start events
    only); STD mux-lead hold (DVD muxes audio 470–667 ms BEHIND video — measured
    on real VOBs by `bench/dvd/aud_pts_chain_tb.sv`); film-aware drop reclaim
    (`cur_show` debit, signed debt); VBUF 256 KB→2 MB; absolute `vbuf_healthy`
    (64/32 KB); NCO trim RETIRED (same-crystal rate lock — keep it retired).
    **PR fj#61 (`feature/lipsync-drift`, MERGED 2026-07-04) = six measurement
    rounds; `docs/lipsync_pickup.md` "START HERE" is the live work order.**
    AUDIO IS FULLY EXONERATED (re-confirmed 2026-07-04 on a CLEAN decode:
    play_err constant to the LSB all run). Three audio-side fixes shipped en
    route (stale-skip confined to the load window; arrival-gated mid-play
    catch-up; drop debit = dropped frame's own rff duration).
    **⛔ ROUND-7 RETRACTION (2026-07-04): the "frame_late ×3 post-crash" bug
    NEVER EXISTED — it was a `tools/osd_read.py` mis-calibration (affine
    sx=2.0 against a true 2.667 full-width capture = a 3:4 column-pitch alias:
    displayed bit k sampled true bit k−⌊k/4⌋, inflating every counter row
    4×–13× value-dependently; row 3 read 414/s instead of 59.94). Reader fixed
    (strict row-3 validation + measured-pitch autocorrelation gate + selftest
    alias trap); the same recording re-decoded cleanly (`rec5.mkv` →
    `drift5d.csv`, not retained). TRUE numbers: lates ~4.2/s pre and ~4.1/s post
    crash (honest governor — also verified by RTL analysis: one REPEAT visit
    per scan), drops 2.0→1.4/s, lates/drops 2.0→3.0 (the rff debit working).
    Rounds 4–6 numeric claims are ALL VOID; the qualitative mechanisms stand.
    **ROUND 8 (same day): lips MEASURED from rec5.mkv vs the source VOB
    (audio envelope xcorr + per-frame template matching — all local, no HW).
    Audio content offset CONSTANT all run (audio perfect, direct proof).
    Video content RAMPS ~+3.3% fast from the start of play — funded by the
    draining VBUF cushion (rates match) — until the cushion exhausts at the
    first heavy scene (t≈62, the "crash"), then video clamps to delivery
    rate and the accumulated ~+1.2 s lead freezes (measured constant to the
    ms, t=80→168) = the user's permanent "audio ~900 ms behind". ENGINE =
    FRAME-DROP DEBIT LEAK: drops (2.04/s) inject each dropped frame's TRUE
    duration (~2.5–3 refr; rff-mixed B population) while the debt controller
    reclaims only ~2.04/drop (the measured lates/drops ratio) ⇒
    `drop_pic_rff` READS 0 ON HW, the round-4 film-aware debit (61b230c) is
    inert; each dropped rff B leaks +1 refresh ≈ +3%. Governor pacing itself
    is HONEST (recording cadence run-lengths = true 3:2 + the honest lates;
    scan-vs-raster locked: resample_chain_tb SCANRATE instrument + mixer
    frame-top-parking analysis). Also ruled out: VOB PTS discontinuities
    (full-file scan clean), STC re-anchor, watchdog resets, scan free-run.
    ROUNDS 9–12 (same day): rounds 9–10 shipped the row-16 drop-debit
    instrument ({debited-3, debited-2}, replacing stc_excess) + sim-exonerated
    the vld drop path (vld_drop_rff_tb over a real MiB ES); round 11 found the
    TRUE ROOT CAUSE when drift7 read identical to drift6: **STALE DISPLAY
    FLAGS — picbuf captured rff/tff/progressive_frame at the picture-HEADER
    update pulse, but they parse in the coding EXTENSION (the vld freezes at
    the header), so every picture displayed with its coded PREDECESSOR's
    flags.** Invisible on clean 3:2 (alternation preserved); frame drops broke
    the pairing and leaked ~+1 refresh per drop = the ramp. FIX =
    `flags_commit` (vld pulses at ext-parsed, never for dropped pics; direct
    wire to picbuf which re-latches the three flags; ordering by the header
    freeze). **✅ ROUND 12 HW-CONFIRMED (drift9b capture, DVD_drift8, 7.5 min MiB
    through the Shea crash): vid_err FLAT ±3 all run, VBUF PARKED (~0.5–1.2 MB,
    rises through the crash), lates/drops 2.03–2.05 constant, play_err
    constant to the LSB, lips constant throughout (user-confirmed). THE DRIFT
    SAGA IS CLOSED.** Bonus: the old "−500 ms start constant" was mostly the
    ramp — the true residual start error is ~−100 ms (audio slightly early;
    user now runs A/V Offset +100). See docs/lipsync_pickup.md rounds 7–12.**
    Follow-ups 1 & 2 SHIPPED (`feature/lipsync-followups`): the **A/V Offset
    default is now +100 ms** (NTSC-film null), menu rebalanced around ±200 ms
    (-300/-400/-500 dropped); the overlay is cleaned up — rows 14/15 restored to
    the AC-3 self-heal reset view (14 ERR, 15 TOTAL, no O[12] mux), drift
    instrument rows retired (overlay NROW 21→17, `stc_excess` emu logic dropped),
    row 16 {drop3,drop2} kept until a Matrix/PAL pass; `tools/osd_read.py`
    ROW_LABELS updated. **+100 ms default ✅ HW-verified on Matrix/PAL too
    (2026-07-10) — treat it as universal.** Remaining: the secondary
    why-4-lates/s-churn curiosity.
    EXONERATED by measurement (do NOT re-chase): PTS chain, anchor value, NCO
    rate, mux geometry as drift, AC-3 self-heal resets, STC-vs-wall rate,
    live-flag cadence sampling, self-sustaining drop churn (both sim-cleared in
    `bench/dvd/cadence_phase_tb.sv`).
    FAILED (do NOT retry): entry-side dispatch scheduling, pre-anchor gate bypass,
    mid-play gate re-arm (full-FIFO deadlock), fractional vbuf thresholds, 16-bit
    offset constants.
  - **`O[13],Audio Genlock,On,Off`** (2026-06-28, branch
  `feature/vob-audio-freerun`): set Off to free-run the audio NCO (`nco_trim=0`)
  while a VOB plays through the full pipeline — a diagnostic to tell av_sync/governor
  PACING apart from `audio_ring` overflow / `ps_demux` filtering, now that AC-3 File
  Test has HW-exonerated the decoder. See `docs/fabric_audio.md` §"Audio Genlock toggle".
  - *(Prior HPS-decode path, retired: FPGA wrote compressed frames to a DDR3 ring at byte
    `0x30800000` for the standalone `hps/dvd_audio.c` daemon (liba52) to mmap/decode/ALSA.
    HW-confirmed 2026-06-25; see `docs/audio_ddr_path.md` for history.)*
- ✅ **Decoded, correct-color SD MPEG-2 video on real hardware** (DE10-Nano + 128 MB SDRAM
  add-on board). This is the first confirmed video; the inherited "✅ decode works" claims below
  were aspirational until now. The path: the HPS f2sdram read path can't sustain the core's
  108 MHz on this board, so the core's memory was ported to the SDRAM module (`dvd/sdram.sv` +
  `dvd/mem_sdram_shim.sv`, branch `feature/sdram-module`, PR fj#6).
- ✅ **Shear (sawtooth) is RESOLVED — NOT a current problem; do not chase it.** The earlier
  sawtooth bandwidth limit was fixed by the DDR3 burst-bridge work plus raising the decoder
  compute clock to 54 MHz (PR fj#10 / `DVD_dec54d` and the f2sdram burst path). 720×480 has not
  sheared for many build iterations. (Historical diagnosis condensed in `docs/history.md`
  §1–2; full logs in git history.)
- ✅ **The "256-line black-frame strobe" is RESOLVED for ≤480 content** (2026-06-24,
  branch `feature/strobe-offset-diagnosis`). It was a PICTURE SPLIT, not memory/black: the
  resample emitted the macroblock-padded height (`mb_height*16`) while the raster active
  region was the true `vertical_size`, so the surplus lines spilled into the next output
  frame. Fixed by (1) ending the emission at `disp_y == vertical_size-1`
  (`dvd/resample_addrgen.v`) and (2) `VERT_RES 479→480` (`modeline.v`, an active-region
  off-by-one). Progressive + 480 clips play clean. Full story in
  `docs/history.md`. **Still open (separate):** vert-res >480 content still spills
  (needs downscale). *(Interlaced ~half-speed field-cadence is addressed by native 480i/576i
  fields output — see the `Interlaced Out: Auto` note below.)*
- ✅ **Interlaced Out (Off/Auto/On) — native 480i/576i fields to ascal — HW-CONFIRMED +
  MERGED (PR fj#132, 2026-07-27). ⛔ OPTION RETIRED 2026-09-02 — the fields raster it
  built still ships as `Video Output = Interlaced`; the separate option and the
  `det_video` Auto detector are deleted (see the consolidation bullet at the top).**
  `O[10:9] Interlaced Out` is 3-way **Off/Auto/On**,
  **default Off** (reverted from Auto 2026-07-27 — see below). `On` gives native interlaced
  fields (NTSC 480i **and** the newly-added **PAL 576i**: `il_eff` no longer forced low under
  PAL; new `pal_prev & il_prev` modeline branch, 312 lines/field ≈ 50 Hz) and plays
  **A/V-synced on HW (confirmed)**. A standard-neutral `det_video` verdict in
  `dvd/resample_addrgen.v` (sustained `progressive_frame==0`, mutually exclusive with the
  film verdicts) drives **Auto**, which auto-engages interlaced for true video-sourced
  content via a mid-title **full seek-style flush** (`il_switch` → load_flush + aud_flush +
  vbuf flush). **⚠️ Auto is NOT the default: its mid-title switch still leaves audio
  SLIGHTLY OUT OF SYNC on HW** (round 1–2, 2026-07-26/27) even after the seek-style
  re-sync — kept as an opt-in to revisit. The **overlay/OSD horizontal squish** in
  interlaced mode is now **✅ FIXED (2026-08-22)** — `ov_h_gen`/`sp_qx` invert the pixrep
  ×2 in `dvd/emu.sv` and `spu_decode`/`crt_ov_map` `.interlaced` follow `il_eff` (their
  +2 field-line walk had never engaged); progressive is bit-identical. Bob/Weave still
  `O11`. PAL 576i on the analog pins is now covered by the dual-raster re-interlacer
  (see the Dual-Raster bullet below). **Dual-raster v1 note:** while the analog raster is
  engaged (`analog_eff`), Interlaced Out is FORCED OFF (the re-interlacer needs the
  standard progressive main raster; the CRT still gets true 480i via the weave frames).
  Sim: `bench/dvd/film_detect_tb.sv`. Design + follow-ups: **`docs/interlaced_auto.md`**.
- ✅ **LINE-21 CLOSED CAPTIONS (2026-08-25/26, branch `feature/closed-captions`) —
  ✅ HW-CONFIRMED 2026-08-26 (round 5, user report: C1 captions complete on MiB +
  Matrix, real TV, YC encoder board → composite).** NTSC discs carry EIA-608 captions in MPEG-2 **user_data**,
  not subpicture. The core now extracts them and re-modulates them onto **line 21 of
  the analog raster** so the TELEVISION's own decoder renders them — what a real
  player does. **No on-screen character generator** — originally dropped because a 32x15 char
  plane + a font ROM grown past 64 glyphs for lowercase (~2-3 M10K, several hundred
  ALMs) did not fit a 98% ALM / 91% RAM design. ★ That rationale EXPIRED with the
  PR #9-#11 area reclaim (now 93% ALM / 91% RAM); asked directly (2026-08-26) the user
  chose to KEEP the scope line-21-only, so it is a CHOICE not a constraint — do NOT
  re-derive "it doesn't fit". See `docs/closed_captions.md` §5.
  Three legs: (1) **extraction** = a PASSIVE SNOOP in `rtl/mpeg2/vld.v` — no new FSM
  state, because `STATE_NEXT_START_CODE` already walks user_data one byte at a time
  so the payload streams past in `getbits[23:16]` for free (**110 insertions, 0
  deletions**; the new block writes only its own regs, so the decode path is
  untouchable by construction). ★ In the VLD and NOT `ps_demux` — ps_demux is in
  FRONT of the ~1 s VBUF, so a demux-side sniff is the stale-display-flags bug
  (drift rounds 11-12) in a new hat; the VLD is where `flags_commit` had to move for
  the same reason. (2) **pacing** = one pair per displayed FIELD, no PTS/STC/NCO at
  all — MEASURED on real discs: the block sits on the GOP header and `cc_count`
  counts DISPLAY frames not coded pictures (15 vs 12 following pictures = 3:2 already
  expanded by the encoder), so the caption clock and the raster are the same clock
  and governor drops/repeats are absorbed for free. (3) **waveform**
  (`dvd/cc_line21.sv`) — exact by construction: 13.5 MHz = 858·fH and the bit rate is
  32·fH, so one bit is **858/32 = 26.8125 dots EXACTLY**; a 16-bit NCO at 2444/dot
  hits that to +0.0002% and its top 4 bits index the run-in sine LUT. Line number
  derived TWICE and agreeing (15th line after vsync end = last VBI line before active
  = `v_cntr` 261 = `p_vlen`), from `sg_vpos` alone — `syncgen.v` unchanged. Output mux
  gated on `~sg_pixel_en` so a wrong line can only cost a blanking line, never punch a
  hole in the picture. `P1O[14] Line-21 CC` (default On, debug page; reuses the bit freed by the
  O[14] CRT-mode retirement). Sim: `cc_extract_tb` (**180/180 pairs byte-exact**
  through the REAL vld+getbits over REAL MiB bytes vs a Python golden),
  `cc_line21_tb` (a **DEMODULATOR** — slices at 25 IRE, locks to the run-in, rebuilds
  the bytes; 5/5), `re_interlace_tb` unchanged 9/9. Census: **6/34 local discs**
  carry live captions, zero PAL, zero CEA-708, field 2 empty everywhere
  (`tools/cc_scan.py`, `dvd_census.py --captions`). **★ HW ROUND 1 (2026-08-25): no
  captions on MiB/Matrix, TV on C1 — ONE real bug + ONE misdiagnosis.** The bug:
  `sys/sys_top.v` fed the VGA2 scanlines stage `.din(vga2_de ? rgb : 24'd0)`, zeroing
  everything outside active video — line 21 is BY DEFINITION in the VBI, so the
  waveform died one module before the DAC (`scanlines`/`osd`/`yc_out`/`vga_out` all
  checked: none gate data on DE). ⚠ Lesson: a VBI side-channel travels a path every
  other feature uses only inside DE — trace it to the PIN. The misdiagnosis: cc_fld1
  was flipped to `sg_vpos[0]` on a content-based premise (TOP = field 1), inverting a
  CORRECT mapping — masked by the DE bug (everything looked identically dead).
  **★ HW ROUND 2 (2026-08-26, YC encoder board → composite): CC Test Line ✅ (dash
  band changes with dialogue = extraction/pacing/waveform/DE-fix/analog chain ALL
  HW-CONFIRMED), C1 empty → the symptom IS the diagnosis: C1/C2/T1/T2 are all
  FIELD-1 services, so the field mapping was wrong — the round-1 flip. FIXED back to
  `cc_fld1 = ~sg_vpos[0]` with the SYNC-SIGNATURE derivation (SMPTE 170M: field 1 =
  vsync line-aligned, field 2 = mid-line; in this raster that VBI has v_pos[0]==0 and
  its active is BOTTOM content — NTSC is bottom-field-first; picture-content parity
  NEVER identifies the broadcast field). `bench/dvd/cc_field_map_tb.sv` REWRITTEN to
  classify by vsync-edge alignment (what a TV measures) + mutation-checked, so the
  wrong premise can't be encoded again. `P1O[44] CC Test Line` = the diagnostic that
  cracked it (paints the waveform on a visible line — one glance separates "chain
  works, placement wrong" from everything upstream). Rebased onto post-0.1c main
  (clean); SEED 3 closed the pre-round-2 netlist (90.9/90.2). **HW gate (round 3 =
  C1 decode): `docs/closed_captions.md` §0 + §6.**
- ✅ **DUAL-RASTER ANALOG OUTPUT (2026-07-29, HW-CONFIRMED + MERGED PR fj#146,
  2026-07-30) — SUPERSEDES the O[14] whole-core CRT mode below. ⛔ FULLY RETIRED
  2026-09-03 (`feature/single-raster-analog`, top bullet): `re_interlace`, the VGA2
  plumbing and the fieldpass re-timer are DELETED — the interlaced main raster carries
  the half-line and drives the pins directly; the ini engagement rule (`analog_want`,
  now latched) and line-21 CC (now `dvd/cc_vbi.sv`) survive. History only below.**
  User-confirmed
  working on real hardware (analog engages from ini alone, HDMI stays progressive
  simultaneously). ⚠️ The exact PAL 576i timing numbers and the field-dominance
  caveat (see `docs/analog_dual_raster.md`) were not specifically re-verified by
  this confirmation and remain open sub-items.
  The analog CRT now works **from MiSTer.ini alone, like any other core**
  (`vga_scaler=0` + `composite_sync=1`/ypbpr/sog — nothing in the OSD): the core emits
  TWO simultaneous rasters — the unchanged progressive main raster for ascal/HDMI, and
  a native 15 kHz 480i/**576i (PAL now included)** second raster from
  `dvd/re_interlace.sv` (4-line sync-read BRAM + a second N64-model `sync_gen`
  instance, phase-locked by construction: 2 fields = exactly 2 main frames; arming
  skew window (1716,1994) clk27, proven by `bench/dvd/re_interlace_tb.sv`'s
  pixel-exact frame-tag checks). New additive `sys_top.v` `VGA2_*` input muxes the
  direct analog chain (incl. the direct_video tap → HDMI-DAC CRTs work too);
  `hps_io.sv` exports the ini bits (cfg[2]/[3]/[5]/[9]); **`VGA_SCALER=0` always**
  (the forced-1 that made ini `vga_scaler=0` unobservable is gone). `O[27:26] Analog
  Out` = Auto/Interlaced/Progressive override (default Auto). Retired: O[14], the
  13.5 MHz `dot_ce` main-raster pacing (CE_PIXEL≡1 now), the modeline-walk CRT
  branch, `crt_eff` (Analog Aspect + overlay gating now ride `analog_eff`; overlay
  taps are always progressive). Also fixed: the bogus `"O[10],Direct Video"` CONF_STR
  line that collided with `O[10:9] Interlaced Out`. Precedence: analog active ⇒ Film
  24p/25p raster suppressed (can't feed the re-interlacer) and Interlaced Out forced
  off (v1). VIDEO_ARX/ARY force 4:3 while Analog Letterbox/Crop is active (the
  rescale is upstream in the now-shared raster). ⚠ PAL 576i numbers are sim-derived —
  HW gate. Design + HW checklist: **`docs/analog_dual_raster.md`**.
  - **✅ `Analog Out = Native Fields` (field passthrough) — 2026-08-22, HW-CONFIRMED
    (core claim; PR fj#178).** A/B'd vs `Auto` on `ROGER_WATERS_IN_THE_FLESH` — MEASURED
    video-sourced by `tools/video_cadence_census.py`, not assumed — fields output
    **noticeably smoother**; 50-min MiB run held A/V sync (that run also covers the
    FIELD-path governor ledger under rff 3:2, and Letterbox — MiB's title is 16:9
    anamorphic so Auto had it active). Overlays full width in this mode ✅, other
    Analog Out modes unregressed ✅, and `Interlaced Out = On` on HDMI now renders
    overlays correctly ✅ (that half is the standalone fix). **Only PAL-analog is
    unverified** — no PAL CRT available; The Office plays right on HDMI, and PAL
    fieldpass is sim-proven, but PR fj#146's sim-derived PAL 576i raster numbers STAY OPEN. Fourth `O[27:26]` mode: forces `il_eff` for the session so
    the decoder emits **authored** TOP/BOTTOM fields and `re_interlace` re-times them
    1:1 (`fieldpass`: period 900900/1080000, write-port pixrep decimation, `SKEW_FP=858`).
    **This is the structural fix for the field-pairing defect**, and WHY the obvious cheap
    fix was rejected is worth remembering: a governor **late** re-scans one FRAME on the
    progressive path (**+1 refresh = ODD ⇒ the pairing parity FLIPS**) but a FIELD PAIR on
    the field path (+2 = even), and lates run **~4/s on healthy content** — so
    phase-aligning the re-interlacer would hold ~250 ms, and re-arming blanks the CRT's
    sync (`S_HUNT` drops `sg_rst_n`). Film barely cares (each field still lies wholly in
    one picture; only dominance alternates); **true 29.97i video is where combing shows**.
    ★ The main raster does NOT need a half-line — the local `sync_gen` supplies it and the
    source's field durations already alternate 262/263, so the rasters stay line-for-line
    locked (proven pixel-exactly, `re_interlace_tb` [6]/[7]); a half-line on the main
    raster would expose HDMI to the `ff01ac8` hunting issue for nothing. Opt-in: HDMI
    drops to 480i via ascal for the session (ascal isn't cadence-aware ⇒ film regresses
    there). Set it BEFORE loading a disc (a mid-title change fires the `il_switch` flush).
    Ships with the overlay pixrep fix as a hard prerequisite.
- ✅ **CRT 480i — native 15 kHz 2:1 interlace: HW-CONFIRMED 2026-07-05 (PR fj#65,
  `feature/crt-480i-native`) — ⛔ SUPERSEDED by the dual-raster bullet above (O[14]
  removed); the syncgen N64 model, pixel_queue CE-stretch, and field-path ledger
  fixes it delivered still ship.** Round 2 verdict on the real CRT: image CORRECT (true 2:1
  interlace, native width, field order right as shipped) and AUDIO STAYS IN SYNC (the
  field-path ledger fixes hold). Round 1 had confirmed the raster but showed BLACK video →
  root cause = a latent CE bug in `rtl/mpeg2/pixel_queue.v` (the dc-fifo's raw-clock
  `valid` pulse falls entirely inside the disabled 13.5 MHz-CE cycle, so the mixer never
  latches a pixel; audio/overlay kept flowing). Fixed with a CE-stretch shim (bit-identical
  at CE≡1); reproduced + proven end-to-end by `resample_chain_tb +crt=1`.
  **⚠️ Open follow-up: the HDMI chroma fringe REGRESSED on this build** — the known
  clk_dec-Fmax/fit-margin artifact, not the CRT logic (see docs/crt_480i.md status note +
  memories `chroma-edge-fringe-is-upsample-mode`, `quartus-build-flaky-routing`; builds ran
  with an uncommitted SEED 9). See docs/crt_480i.md §0/§8.** `O[14] CRT 480i Out`: native-width 480i for a real
  CRT on the analog board, built to the N64 model after the pulse-delay approach was
  HW-proven never to lock (memory `crt-interlace-odd-total-lines` — the old
  `feature/crt-composite` branch is dead; this is the fresh start). Three legs:
  (1) `rtl/mpeg2/syncgen.v` N64-model interlace, armed by `interlaced && halfline!=0`:
  alternating 262/263 field totals + vsync sampled at a half-line COUNTER reference ⇒
  vsync spacing exactly 262.5 lines every field (`bench/dvd/crt_syncgen_tb.sv`; legacy
  480p/HDMI-480i bit-identical). (2) `dvd/emu.sv`: 13.5 MHz `dot_ce`/`CE_PIXEL` (native
  720-wide, NOT pixel-repetition), a 4th modeline-walk branch (halfline=429, pixrep off),
  and `VGA_SCALER=0` in CRT mode (it was hardwired 1 = forcing the scaler onto the analog
  pins). (3) 480i field-path A/V-ledger fixes (the audio-drifts-ahead blocker from the old
  branch): 2-cycle `frame_late` on pair repeats (the ×2 late undercount — dominant),
  mode-aware `show_next` (rff film = 3 field scans in 480i), `~interlaced` drop-debit
  gates removed (`rtl/mpeg2/mpeg2video.v`), and `refresh_cnt` SATURATION (the 4-bit wrap
  silently ate ~12% of stall lateness in BOTH display modes;
  `bench/dvd/gov_field_late_tb.sv` proves 1:1 late:refresh accounting). Overlay row 17 =
  `vid_err` re-added (NROW 17→18, `tools/osd_read.py` updated + selftest green) — the HW
  verdict is that row staying FLAT through a compute crush in 480i. CRT needs `MiSTer.ini`
  `vga_scaler=0`, `composite_sync=1`. Full design + HW test plan + field-swap contingency:
  `docs/crt_480i.md`. (PAL 576i CRT: ✅ delivered by the dual-raster rework above;
  letterbox/240p vertical scaler still open.)
- 🧰 On-hardware diagnostics: `debug_overlay.sv` (multi-row block-bit counters — rows 0-17 +
  Phase-7 rows 18/19 nav current/total time). ⚠️ **STATUS (2026-07-09): this overlay is
  `` `ifdef DEBUG_OVERLAY `` and COMPILED OUT of the release build** (it shares the display
  hotspot with the subpicture blend; `ov_on` is hardwired 0 — see `emu.sv` ~L2088). In a
  **release `.rbf`, `O[2]` shows NOTHING from this overlay**; instead `O[2]` drives only the
  lightweight **menu-highlight diagnostic blocks** (`status[2] && menus_on`, `dbg_blk1..8`).
  To read the multi-row overlay / `tools/osd_read.py` rows on HW you must **define
  `DEBUG_OVERLAY` in `DVD.qsf` and rebuild** (that re-tightens the congested fit — verify it
  still closes + passes the clk_dec fringe gate). ⚠️ overlay
  watchdog cell polarity gotcha documented above. (The DRAM/SDRAM self-tests, DDR3 burst BIST,
  AC-3 File Test, and the SDRAM controller were removed 2026-07-01 in
  `feature/remove-diagnostic-cruft` to simplify the on-board logic; see `docs/history.md`.)

## What Already Works (Upstream MiSTer_MPEG2)

- ✅ Full hardware MPEG-2 video decode in FPGA fabric (IDCT, motion comp, VLC)
- ✅ High-bandwidth SD card sector streaming (`mpg_streamer.sv`) via `sd_*` block interface
- ✅ DDR3 frame buffer management (`mem_shim.sv`) — pipelined FSM with skid buffer
- ✅ TrustZone-compliant 15.5MB HD frame buffer within MiSTer's 24MB CMA window
- ✅ NTSC 480p/60Hz video output via MiSTer framework
- ✅ Simulation testbench (`bench/`) and debug tooling

## Known Gaps in Upstream (what this project adds)

- ✅ Framerate sync: PAL now supported via a runtime modeline switch — **HW-CONFIRMED**
  (2026-06-30, branch `feature/hres-offbyone-pal`, PR fj#50). The 27 MHz dot clock gives 50.0 Hz
  with PAL totals (864×625), so NO PLL reconfig is needed: `O[17:16] Video Standard`
  (Auto/NTSC/PAL) drives the runtime modeline-write walk (`dvd/emu.sv`) to 720×576p@50 +
  `av_sync`'s 50 Hz STC (`refresh_50hz`); governor `SHOW_N=2` already yields 25 fps at 50 Hz.
  **Auto** detects from the decoder's new `vertical_size_out` port (480=NTSC, 576=PAL). PAL
  progressive (25p) film via Film 25p; **PAL 576i interlaced now supported** (HDMI fields via
  `Interlaced Out`, PR fj#132; analog pins via the dual-raster re-interlacer — see the
  Dual-Raster bullet above, ⏳ HW-pending). Also
  fixed the horizontal off-by-one (`HORZ_RES 719→720`, recovers the 1-col right crop), the
  analogue of the earlier `VERT_RES 479→480`. **⚠️ PAL playback STUTTERS on high-motion (BBB
  PAL DVD):** same compute-bound decoder ceiling as the NTSC high-motion stutter, just exposed
  harder by the ~20% taller 576-line frame (1620 vs 1350 MB/frame) — NOT a PAL timing/pacing
  bug. Rides on the deferred motion-comp/IDCT rewrite. See docs/roadmap.md "PAL/NTSC Framerate
  Sync" and the `*compute-bound*` memories.
- ❌ HD modeline switching: fixed 27MHz SD clock, no dynamic PLL for 720p/1080p
- ❌ Audio: core is video-only, no audio output of any kind
- ✅ **DVD ISO playback (v1) — IN FABRIC, no HPS daemon — HW-CONFIRMED 2026-07-05**
  (PR fj#70, branch `feature/dvd-iso-navigator`, `DVD_isonav`). `dvd/dvd_iso_reader.sv`
  replaces `mpg_streamer`: select a **decrypted DVD-Video `.iso`** and it detects
  ISO9660, walks root → `VIDEO_TS`, and plays the **largest VTS = main feature**. The
  `sd_*` block interface is random-access (framework serves any `sd_lba`), so nav is all
  in fabric — nothing on the HPS. Non-ISO images fall back to linear whole-file streaming
  (`.VOB`/`.mpg`/`.m2v` unchanged, HW-confirmed). **CSS stays a PC-side rip step**
  (MakeMKV/dvdbackup); ISO9660 only (UDF-only images deferred); no IFO/PGC yet
  (chapters/seek/angles = Phases 7–9). **⚠️ The largest-VTS heuristic does NOT pick the
  right main title on every disc** (fix = IFO/PGC or a manual OSD title picker, deferred).
  **Fit gotcha (fixed):** `parse_buf` must be a SYNC-read BRAM — the first build hit 226%
  ALMs because it was read async at ~30 offsets (LUT-RAM explosion); now 81% ALMs, one
  M10K + a 45-byte `rbuf` record shadow. Tests: `bench/dvd/iso_reader_tb.sv` (synthetic) +
  `bench/dvd/iso_reader_real_tb.sv` (real MEN_IN_BLACK metadata → VTS_21). Predictor:
  `tools/iso_nav_check.py`. Design: **`docs/dvd_nav.md`**.
  - **🔧 SD DELIVERY 2048-BYTE BLOCKS (2026-08-03/04, branch `feature/sd-2048-blocks`,
    PR fj#159).** `hps_io BLKSZ=4` → one 2048-byte request per DVD sector (4× fewer HPS
    round-trips; sd_lba = sector LBA = RBN 1:1, the ×4 mapping deleted; NAV/DSI snoop
    offsets now sector-relative). Motivated by the **Thayer's Quest ~3 Hz audio
    skipping** + the disc being authored at the DVD mux ceiling (pack-SCR scan: VTS_02
    sustains 9.47–10.08 Mbps for minutes; clean discs average 5.2–5.5). **⚠ HW verdict
    (2026-08-04): the skip rate was UNCHANGED — delivery is EXONERATED for that symptom**
    (and "VBUF bar low" is NOT a starvation proof: STD backpressure parks it low in
    normal play). The rework stands on its own (headroom for mux-ceiling discs, simpler
    reader, larger CIFS reads); all 27 reader TBs green (chapter_tb cells grown to 16
    sectors — 1-sector cells let the 8-sector cache prefetch outrun the drain, a TB
    artifact). Further lever if needed: `sd_blk_cnt` up to 16 KB/request.
    **★ THAYER SAGA ULTIMATE ROOT CAUSE — ✅ FIXED + HW-CONFIRMED 2026-08-05 (audio
    solid AND in sync): THE DISC IS MOSTLY FIELD-CODED MPEG-2, and the frame-drop
    governor's documented punt on field-picture B's meant its ~10 % video-decode
    deficit (6–7 lates/s, drops=0 by design) could never be reclaimed** — video ran
    slow, audio didn't wait (vid_err +8 refr/s = the audio-early A/V drift), and the
    backed-up buffers entered the VBUF-hard-full jam (demux stalls mid-PES on video,
    the ring backpressure never engages, the audio ring bleeds to 0 with no restoring
    force = the menu/gameplay skipping). Deep `picture_structure` census: VMGM-past-
    head + VTS_02/05/07/11 = top/bottom FIELD pictures; only VTS_09 + VOB lead-ins
    frame-coded (every early ES sample had hit those by luck — census DEEP, not
    heads). **Fix = B FIELD-PAIR DROP (`rtl/mpeg2/vld.v`):** decide at the FIRST
    field (second_field reads 1 there = the update-pulse convention, so the pair's
    update suppresses like a frame-B), `drop_pair_arm` atomically drops the sibling,
    new `drop_pic_field` acks cost/credit **1 per field** (a pair debits exactly the
    2 refreshes it frees). Sim: field ES drops in clean atomic pairs; frame streams
    identical; `vld_drop_rff_tb +DRAIN` display-blocked mode added. Diagnosis
    instruments kept (DEBUG_OVERLAY builds): row 27 flow-control flags, row 16
    in-vld drop probe. ⛔ Two preserve/keep "netlist mangling" rounds en route were a
    GHOST (the probes disproved it; hardening kept as insurance). Flow-control work
    kept on merit: v2 stall grain 0x2C, v3 ring-floor escape, **v4 GLOBAL VBUF SOFT
    CEILING 0xE0/0xD8** (VBUF-hard-full is a death regime — never reach it), and the
    **menu cap halved 0x30→0x18**. Also measured: Thayer's audio mux lead ~33 ms
    (normal 470–667 ms); an inaudible ≤15-LSB AC-3 cpl-exponent divergence (open
    follow-up). See `docs/dvd_menu_refinements.md` §5d amendment + `docs/dvd_nav.md`
    "Block size".
  - **★ HIGHLIGHT PROMOTION MODEL v2 — ✅ HW-CONFIRMED 2026-08-06 (T2 + MiB + Thayer,
    4 probe rounds via overlay row 26).** The branch's sd-2048 speedup exposed that
    nav_pci's promotion paths trusted a parse-anchored clock: highlights painted over
    menu transitions (early) or starved (late). Final model, every path
    display-justified: **STC-scheduled** promotion requires a REAL crossing
    (`nxt_pre`: commit before the window start) AND a TRUSTED clock (`stc_fresh` =
    last load flushed, or `settled_seen` = a still park since load); **scheduled
    DISARMS require the trusted clock too** (stale per-VOBU ss=0 disarms on a
    keep_vbuf timeline starved promotions — off_due outranks nxt_due);
    **settle promotion** (`menu_settled` = reader `still_active` && VBUF ≤ ~24 KB —
    reader-park alone fired with ~0.5–1.5 s of transition still buffered) lands the
    highlight WITH the settled image on parking menus (T2 confirmed great); **timer
    fallback 1.0 s** serves only LOOPING motion menus (MiB pages/root — probes proved
    they never park, so no settle signal exists; sub-second transitions). Probe kept:
    overlay row 26 = {promo_cnt, src 1=sched/2=settle/3=timer, age ~4.85 ms units}.
    See `dvd/nav_pci.sv` header comments.
- ✅ **GAMEPAD TRANSPORT: cell-granular seek + pause (2026-07-06) — HW-PROVEN via the
  later transport stack (chapters/scrub/HUD/pause exercised on the board, PRs fj#96/#101/#103/#106).** The
  reusable **seek primitive** (later unlocks chapters/FF/skip/menu-jump — all reduce to "jump +
  re-sync"): `dvd_iso_reader` gains `seek_pulse`/`seek_cell` (+`seek_ack`/`cur_cell`/`cell_ready`)
  to jump to a PGC cell, **latched and executed at a block boundary** (`seek_jump = seek_pending
  && ~blk_inflight` — let the outstanding `sd` read finish or its beats leak as stale cache bytes)
  by reusing the existing `S_CELL_LOAD→…→S_STREAM` cell-load path. Gamepad (`joystick_0`, prev
  unused; `J1,Pause,Prev Chapter,Next Chapter`): B1=pause, B3/Right=next cell, B2/Left=prev cell.
  **★ HW ROUND-1 exposed two architectural gaps, both from the decoder's ~1 s VBUF cushion +
  audio continuity; fixed via NATIVE decoder trick-play hooks (not a decoder reset):**
  (1) **Seek video lagged ~1 s** (audio jumped immediately, old buffered video played on): `seek_ack`
  now also pulses `mpeg2video.vbuf_flush` (seek-only `seek_flush` level → clk_dec), ORed into the
  regfile's native `flush_vbuf`, discarding the buffered bitstream so video jumps with the audio.
  (2) **Pause → still frame went BLACK + res popup after ~1 s, and audio kept playing** (desync grew
  with pause length): the governor freeze stalled the decoder → the **watchdog** reset it (black
  screen) — now the watchdog is fed `repeat_frame=31` (native freeze-suppress) while paused; and
  **audio is held** by gating `dvd_audio_decode`'s play tick (`aud_ce_play &= ~pause`, reuses the
  drain-hold → silence, seamless resume) + freezing the ring drain watchdog (`aud_bp_wd`). Pause
  now = 4 coordinated holds: governor freeze + watchdog-suppress + STC freeze (`av_sync.pause`) +
  audio hold. Tests: `bench/dvd/iso_reader_seek_tb.sv`, `av_sync_tb.sv` [5]. Design:
  `docs/dvd_nav.md` "Transport". Cell-granular only (cells start on clean GOP boundaries → decoder
  re-locks); sub-cell/time-based seek deferred. **Watch on HW re-test:** rapid multi-seek
  robustness (round-1 "skipping record" + audio-stop) and any brief glitch frame at the VBUF flush.
  **A/V-sync-after-scrub ✅ HW-CONFIRMED (2026-07-10, PR fj#106, `DVD_scrubalign_20260710_2312.rbf`,
  SEED 13 clk_dec 94.36/90.19 MHz):** the hold-to-seek scrub's raw-RBN target landed mid-VOBU → decoder re-locked
  mid-GOP (pixelated) and av_sync anchored the STC on the *next* VOBU's video PTS → permanent
  sub-second audio lead (a chapter jump re-aligned it). The reader now snaps the scrub target
  forward to the first NAV pack (VOBU boundary) via a 1-block parse-probe (`S_NAV_SEEK*`,
  `NAV_CAP=1024`, raw fallback) so a scrub landing matches the chapter-seek contract. Scope:
  the `seek_is_rbn` title path only. See `docs/dvd_nav.md` §2a.
- ✅ **DISC MENUS Phase 2 — menu domain + VM jump interface (2026-07-07, PR fj#80) —
  HW-CONFIRMED via the menu-refinements rounds (PRs fj#84–fj#90; see
  `docs/dvd_menu_refinements.md` status roll-up).** `O[1] Disc Menus` (**default On** as of
  2026-08-23 — the end-user defaults pass; was Off through the phase work) +
  `J1,...,Select,Menu`: Menu jumps from the playing title to the disc's authored
  **VTS root menu** (VTSM PGCI_UT@208 → LU[0] → entry 0x83; fallback chain VTSM→VMGM→
  resume), Menu/Select again resumes the title at the saved cell. Reader gained the
  reusable **VM jump primitive** (`jump_pulse/{domain FP/VMGM/VTSM/TT, vts, pgcn, entry,
  cell}` → `jump_ack` on the seek flush contract + `pgc_loaded/pgc_error`), a
  **generalized PGCIT path** (one parser for title + menu PGCs, mount included), and a
  **sector-crossing byte walker** that parses PGC hdr@156-233 (still@163, palette@164 —
  the Phase-1 straddle-skip is GONE), streams the **full command table** out on `cmd_we`
  (Phase-4 VM BRAM format, frozen), and loads cells WITH `{still_time,cell_cmd_nr}` meta.
  Real-disc findings baked in: MiB's root entry PGC = 0-cell command stub → reader
  follows the last pre-command LinkPGCN (uncond preferred, depth ≤2); menu stills are
  CELL-level (0xFF) → **drain-then-`S_STILL`** with a watchdog-only hold
  (`mpeg2video.freeze_wd`), NOT the 4-hold pause set (the decoder must play out its
  buffered tail to reach the authored still frame — the seek-VBUF lesson in reverse).
  `tools/iso_nav_check.py decode_vmcmd` rewritten as a faithful libdvdnav vmcmd.c port
  (the old ad-hoc decoder had the jump op codes WRONG: op2=JumpTT read as JumpVTS_TT,
  op6=JumpSS as JumpTT) + menu PGCI_UT dumps, validated on MiB/Matrix/T2 (zero
  unknown-bit warnings). Tests: `bench/dvd/iso_reader_menu_tb.sv` (6 scenarios incl.
  straddling-PGC follow) + all existing reader tbs + real-VOB ps_chain green. Design:
  `docs/dvd_nav.md` "Menu domain". **HW ROUND 1 (2026-07-07): Matrix menu WORKS +
  resume works on both discs; MiB = silent black** — root cause from the IFO dump: MiB
  VTS_21's root entry is a 0-cell **JumpSS trampoline** (g14=0x3500 → VMGM dispatcher
  → JumpSS VTSM vts 2 = needs real VM execution); the old VTSM→VMGM fallback landed on
  VMGM PGC1's cells = authored BLACK FILLER. **Round-2 fix (re-test pending): fallback
  chain gained a hop — own VTSM → VTSM of the LARGEST-menu-VOB VTS (`best_menu_vts`;
  MiB: VTS_02_0.VOB 261 MB → its root LinkPGCNs to the real menu) → VMGM → resume.**
  Also HW-learned: menu 4:3 aspect = authored (Auto follows seq hdr, correct); menu
  subpictures invisible with O[15] On = authored contrast 0, visibility comes from HLI
  highlight colours (Phase 3), NOT a decode gap.
- ✅ **DISC MENUS Phase 3 — PCI/HLI button highlights + gamepad nav (2026-07-07) —
  HW-CONFIRMED (highlight render closed by PR fj#83/#84, `docs/dvd_menu_refinements.md` §1).** ps_demux routes
  private_stream_2 substream 0x00 (PCI; SYSTEM syntax, no PES opt header, off
  S_SYS_LEN_LO) → new `dvd/nav_pci.sv` (double-buffered HLI BRAM 0x60-0x315, hli_ss
  commit semantics, fosl/foac, STC arm window, button-record fetch → REGISTERS, D-pad
  link walk, activate = btn_cmd + ~0.6s ACT flash). Highlight render: inside the rect
  the sp pixel class takes the HLI coli nibbles ([Ci3..Ci0 A3..A0], on-disc verified)
  through the SAME pgc_palette→subpic_blend path; spu_decode force-enabled while a menu
  is up (O[15]-independent). Reader gained the CELL-LOOP heuristic (replay a
  button-armed cell with cell_cmd≠0 — MiB's interactive screen is mid-PGC cell 1; the
  authored loop is a cell command). emu micro-bridge: LinkPGCN → same-PGCIT menu jump
  (MiB submenus/Matrix menus WORK), LinkTailPGC → title resume; rest flash-only until
  the Phase-4 VM. Golden tools: `tools/nav_extract.py` (PCI/HLI decoder + NAV fixture
  writer, offsets vs libdvdread nav_types.h). Tests: nav_pci_tb + ps_demux_ps2_tb (real
  MiB NAV sectors, byte-exact), all reader/demux/subpic suites green. Design:
  docs/dvd_nav.md "Menu buttons". **HW gate:** MiB/Matrix menu → highlight visible,
  D-pad follows the authored link graph, Select opens MiB submenus (LinkPGCN) / flashes
  play buttons, menu loops instead of parking. Next: Phase 4 dvd_vm.sv interpreter.
- ✅ **DISC MENUS Phase 4 — DVD-VM interpreter (2026-07-07) — HW-CONFIRMED via the
  menu-refinements rounds (menus work on real discs; see `docs/dvd_menu_refinements.md`).** New `dvd/dvd_vm.sv` EXECUTES the disc's nav
  commands (faithful libdvdnav decoder.c eval; types 5/6 per vmcmd.c — decoder.c's
  own 5/6 is FIXME-wrong; type 4 compares AFTER its set, others before). GPRM×16 +
  SPRM subset, cmd BRAM 2048×8 + program-map BRAM (reader-streamed), serial ALU,
  LFSR16 rnd — all bit-exact vs `tools/dvd_vm_ref.py` (the new golden model,
  validated on MiB/BBB/Matrix: MiB's Menu key executes the FULL JumpSS trampoline
  to the real VTS_02 menu; BBB FP = JumpTT 4 — the old "JumpVTS_TT" reading was the
  pre-rewrite decoder bug). With `O[1]` On: mount boots the **First Play PGC** (no
  auto-play), buttons/menu keys run real commands (CallSS/RSM resume with skip_pre,
  LinkTailPGC→POST dispatch = MiB Play, SetSTN→SPRM1/2→demux track mux), POST runs
  at title end (drain-first), menu loops via vm_replay (gapless). Reader gained
  `vm_mode` S_VM_WAIT verdicts (+0.62s watchdog), JumpTT TT_SRPT resolve +
  title-entry scan, P_PMAP program-map walk; emu's Phase-2/3 proto-nav/micro-bridge
  glue is DELETED (VM owns jumps; nav_pci gained `sel_force` for SetHL_BTNN).
  Menus Off = Phase-3 behaviour exactly. Punted: angles, PTT exactness (Phase 6),
  GPRM counter tick, UOPs, parental.
  - **⚠ BOOT-CHAIN MENU SHORTCUT — the one deliberate deviation from libdvdnav
    (2026-08-25, user decision) — ✅ HW-CONFIRMED 2026-08-25 (user report).**
    Menu pressed over the First Play copyright screen used to hand the key to
    the PLAYING title's VTSM Root, which on a DVD-game disc is a DISPATCHER,
    not a menu: Atmosfear's sets
    `g[2]=7` → VMGM 6 → VTSM(1) Root → (g2≠0) PGCN 5 → 48 → `rnd 6; JumpTT 1` =
    a random ~35 s Gatekeeper clip. **libdvdnav does the same** (verified with its
    own `trace_menuearly` on the real ISO) and the disc sets **no UOP bits**, so a
    faithful VM cannot help — hence the deviation. While `menu_seen == 0` (no
    menu-domain PGC loaded since the mount) the Menu key targets `best_menu_vts`
    Root instead; `g[2]` stays 0 and Atmosfear lands on its real main menu.
    Self-limiting (that press latches `menu_seen`), inert when
    `best_menu_vts ∈ {0, cur_vts}`, and new `fb=FB_BOOTM` falls back to the SPEC
    path (own-VTS Root) before VMGM. **141-disc sweep: 135 unchanged, 6 changed —
    all from a TITLE landing to a MENU landing.** Tests `dvd_vm_tb` [S2]/[S21];
    golden model in lockstep. Full trace + table: `docs/dvd_vm.md` "Boot-chain
    menu shortcut". Tests: dvd_vm_tb (27 vectors + 9 scenarios),
  iso_reader_vm_tb (command-driven boot→menu→loop→resume→post), all reader/demux/
  nav suites green. Design: **`docs/dvd_vm.md`**. **HW gate: BBB boots FP→menu→
  correct feature; MiB trampoline/Play/resume; SetSTN switches streams.**
- ✅ **DISC MENUS Phase 5 — menu-transition VBUF hold (2026-07-08, PR fj#84) —
  HW round-2 ACCEPTED (see the ★ notes below + `docs/dvd_menu_refinements.md` §2).** Fixes the T2
  "offset highlight / freeze mid-transition" (and §3 "wrong timeline"): the
  highlight was correct but sat over a **stale/frozen menu image**. Root cause
  (decoded from the disc): a menu→menu transition fired `vbuf_flush`, cold-
  restarting the decoder so the persistence frame (old menu still) stayed while
  nav_pci armed the NEW menu's highlight. Reader now exports **`keep_vbuf`** (1 on
  a menu-internal seek / menu→menu jump / menu next_pgcn advance); emu gates
  `seek_flush_cnt` with `~keep_vbuf` so those transitions pulse **`load_flush`
  only, not `vbuf_flush`** → the decoder plays out the authored transition tail
  then decodes the new menu (no stale frame). Title seeks / menu→title (Play) /
  title→menu (Menu key) keep the flush (A/V-sync). Tests: `iso_reader_menu_tb`
  (T2/T4/T8 keep_vbuf table), `iso_reader_seek_tb` (title seek keeps it 0). Design:
  `docs/dvd_menu_refinements.md` §2, `docs/dvd_nav.md` "Menu-transition VBUF hold".
  **HW gate: T2/Matrix submenu enter + timeline select land on the correct menu
  with the highlight over the matching image; MiB/BBB unchanged; O[1] Off unaffected.**
  **★ HW ROUND 2 (2026-07-08): keep_vbuf ACCEPTED** — transitions + timeline switch
  work. Added **Phase 5b — nav_pci `video_live` fallback promotion**: deep menus
  (Mission Profiles, "Jump Into Timeline" scene-range menu + scene submenu) had
  **highlights that never armed** — nav_pci promotes at `STC >= hli_s_ptm` but av_sync's
  STC is anchored on the demux parse-front (not the screen) and a keep_vbuf hop doesn't
  re-anchor it, so the compare is permanently not-due. nav_pci now takes `video_live` +
  promotes a waiting armed HLI (visible coli `sel=444405ad`) after ~1 s of video-live so
  it ALWAYS appears; STC path kept for Matrix finite windows (`nav_pci_tb` T7). Residual
  keep_vbuf side effects deferred (documented in `docs/dvd_menu_refinements.md` §1/§2):
  1–2 black frames at the LinkPGCN junction (ps_demux reset + cache clear),
  content-appears-late (VBUF-lag: decoder plays the accumulated tail before the settled
  still), highlight-sometimes-early (STC-past-s_ptm).
  **Tail-drain amendment ✅ HW-CONFIRMED 2026-07-30 (user report, PR fj#149):** a NATURAL title-domain PGC end (FP logo chains, end-of-title → menu) used
  to lose its last ~1 s to the `keep_vbuf=0` jump flush; the reader now waits for
  `vbuf_empty` (~5 s `DRAIN_WD` watchdog) before dispatching `vm_pgc_end`, so the clip
  plays out fully. User jumps/seeks stay immediate; menu paths unchanged. See
  `docs/dvd_nav.md` "Natural-transition tail drain".
  **Tail-drain Phase B ✅ HW-CONFIRMED + MERGED 2026-07-31 (PR fj#150):** title-domain
  CELL-COMMAND jump/seek verdicts (Thayer's Quest FMV branch
  points) now tail-drain too. The VM exports `vm_from_wait` provenance
  (= `wait_verdict && nat_src` — `nat_src` tracks WHO STARTED the chain, set only by
  `ev_cellcmd`/`ev_pgcend`; ★ HW round 1 proved blk-only provenance wrong: Tomb
  Raider's Select skip = button `LinkTailPGC`→POST, whose jump read BLK_POST and got
  tail-drain-gated for seconds — `nat_src` keeps every user-started chain immediate;
  every V_IDLE event arm also forces `blk<=BLK_BTN`), the reader gates `jump_go`/`seek_jump` on
  `vbuf_empty`/`DRAIN_WD` for natural title requests (dispatch stays ungated —
  `vm_adv` cell commands never hitch), freezes `vmw_tmr` while gated, and feeds
  `nat_wait_o` back to `dvd_vm.wait_hold` to freeze the V_WAIT give-up timer
  (else `skip_pre`/`tt_resolve` corrupt mid-drain). HW: TR Select scene-skip
  immediate (the round-2 fix), Thayer unchanged — EXPECTED (its choice cells are
  timed stills = already drained; the gate covers no-still branch cells).
  Detail + a known pre-existing `JumpSS_VTSM vts=0` quirk: `docs/dvd_nav.md` "Phase B".
  **★★ HW ROUND 5 — ✅ HIGHLIGHTS FIXED + CONFIRMED (2026-07-08, PR fj#84 merged).** The real
  blocker (found by MEASURING SPU sizes, not guessing): `spu_decode`'s SPU buffer was **8 KB**
  (`SPU_CAP=8192`, 13-bit addrs), but menu subpictures are large (T2 root 2.8 KB=fit→worked;
  mission-profiles 8.6 KB, scene-range 23.9 KB=overflow). The DCSQ sits at the SPU's END, so a
  small cap dropped it and `rd_ptr<=dcsqt_sa[12:0]` truncated its offset → never committed →
  no subpicture → no highlight (which is why every downstream fix did nothing). Fix: SPU_CAP
  8 KB→32 KB + 15-bit addresses (RAM 69%→74%, fits). **Mission Profiles + scene-range
  highlights now render on HW.** Diagnostic that cracked it: O[2] on-screen blocks
  (armed/video_live/subpic-shown/SPU-arrival) + `tools/spu_ref.py` SPU→PNG dump. The round-4/5/6
  fixes (menu_mode visible-window bypass, `sp_track=0` for menus, `video_live` fallback) were
  correct-but-insufficient alone and remain in place. **★ OPEN follow-up = VBUF LAG (new
  session):** the decoder trails the parse by the buffered depth (keep_vbuf), so menus don't
  reach the settled still — scene-range NUMBERS (baked video, cell-0 I-frame) missing on the
  deep first-entry path, mission-profile slide-load flashes, Matrix/MiB scene-page images lag
  ~2–3 s behind the highlight. Fix direction: flush-and-re-decode the still cell on the
  menu-still park (or bound the menu VBUF lead). See `docs/dvd_menu_refinements.md` §5.
- ✅ **TRANSPORT HUD Phase 11 — HW-CONFIRMED 2026-07-10 (PR fj#103)** (release build
  gated green: clk_dec 91.07/88.12 MHz, ALM 90%, DSP unchanged 97/112;
  `releases/DVD_hud_20260710_1955.rbf`). The release-visible playback feedback layer (the multi-row debug
  overlay stays compiled out): `dvd/transport_hud.sv` renders a bottom **status line**
  (`► 0:12:34/1:37:05 CH 12/23`; ❚❚ pause; `►►×n` scrub with the PR-fj#101 span-relative
  tiers) + an **event popup line** (`AUDIO 2/4 FR` / `SUB OFF` / `ANGLE 2/3` / `CH n/N`,
  last-event-wins, Phase-10 `attr_*` languages) from a generated glyph ROM
  (`tools/hud_font.py` → `dvd/hud_font.mem`) + 2×32 text plane; **`dvd/seek_bar.sv`**
  gives the seek-on-release scrub its missing feedback (fill = hold start, amber cursor =
  release target vs the title RBN span) and pops on pause/seek/chapter with the live
  playhead + chapter-tick notches (stretch, severable). New **B9 "Display"** button
  toggles a persistent status line; auto-show 2.5 s on events; hidden in menus.
  Whole-title elapsed = the reader's per-cell BCD prefix sum (+ new `cur_pgm` query walk)
  (+) DSI `c_eltm` via `dvd/bcd_time_add.sv` (rate-aware frame carry, 508 vectors green).
  **Hotspot discipline:** all formatting/division at event rate; display path = (x,y)-pure
  registered pipelines priority-muxed into the ONE existing `subpic_blend` register stage
  (0 new DSP; field-order per-pixel identity proven in sim = CRT-480i safe; HDMI-480i O9
  half-width caveat = subtitle parity). Tests: transport_hud_tb (12 scenarios, text-plane
  ASCII decode), hud_frame_tb (PPM frame + interlace proof), seek_bar_tb (divider/ticks/
  popup), bcd_time_add_tb, extended iso_reader_chapter_tb; all reader/nav/demux/av_sync
  suites + real-VOB ps_chain green. Design + HW-gate checklist: **`docs/transport_hud.md`**.
- ✅ Multi-angle (Phase 9): HW-CONFIRMED 2026-07-10 (PR fj#98, MiB title 13 five-angle B6
  cycle). Timed/heuristic stills: HW-CONFIRMED 2026-07-10 (PR fj#90).
- ❌ DVD-specific remaining: chapters/PTT exactness (Phase 6: VTS_PTT_SRPT), menu audio,
  no UDF-only-image support. (Phase-8b TMAP absolute seek: RETIRED 2026-07-10 by user
  decision. The seek UX gained ONE opt-in layer since — `O[45]` D-Pad Seek, below — which
  rides the same `seek_rbn` primitive and does **not** reopen TMAP.)
- ✅ **D-PAD FIXED-TIME SEEK (`O[45]`, default Off) — HW-CONFIRMED 2026-08-27
  (PR #15; user report; SEED 7, clk_dec 90.97 @100C / 89.5 @-40C).** VLC-style jumps on the D-pad
  while a title plays: **Left/Right ∓10 s, Down/Up ∓60 s**. Presses inside ~400 ms coalesce
  into ONE seek and each tap RE-ARMS the window, so a burst builds an arbitrarily long jump
  (20 taps of Up = one 20-min jump), shown as **`SEEK FWD 12:30`**. HOLD-to-compound was
  built then REVERTED 2026-08-27 by user decision — taps only. `UNIT_CAP` (599 units =
  99:50) bounds only the MM:SS READOUT, not the seek; `scrub_ctrl`'s title-span clamp is the
  real limit. Never a jump PER VOBU — that is the rapid flush/re-lock regime HW rounds 1–2
  of the scrub proved fatal, hence one seek per gesture however long the burst. Targets come from the disc's OWN
  authored **DSI VOBU_SRI `fwda`/`bwda`** tables, which `nav_dsi` has parsed since Phase 7
  but **nothing ever consumed** — `emu.sv` tied `dsi_tbl_raddr` to 0, so Quartus
  dead-stripped the whole `dsi_tbl` RAM (the fit report showed `nav_dsi` at **16 ALMs / 0
  memory bits**); wiring the port back RESURRECTS ~1 M10K + ~100 ALMs, so check the map
  report after a fit. New `dvd/dpad_seek.sv` resolves the request by **greedy decomposition
  over the coarse ladder {120,60,30,10} s**, which makes the common gestures exact single
  lookups (1×R=`fwda[3]`, 3×R=`fwda[2]`, 1×U=`fwda[1]`, 2×U=`fwda[0]`) instead of
  compounding the 10 s entry; it hands the target to a new **jump mode in
  `dvd/scrub_ctrl.sv`**, reusing the title-span clamp, the seek bar and the one proven
  `seek_rbn` issue. Raw VCD/SVCD has no DSI and uses the exact CD geometry instead
  (75 sectors/s × 2352 B ÷ 2048 = **861 blocks per 10 s**); flat `.mpg`/`.VOB` is
  deliberately inert. **⚠ Default Off ON PURPOSE** — the 2026-07-28 decision to move
  seeking OFF the D-pad (game DVDs play seekable video while expecting directional input)
  becomes CONDITIONAL, not wrong; it is also suppressed by `menu_nav`/`in_title_menu`.
  ★ **THE STALE-TABLE TRAP** it had to guard is worth knowing beyond this feature:
  `nav_dsi.rst_n` is `pipe_rst_n`, so every seek clears `dsi_nv_pck_lbn` to 0, but
  `dsi_tbl`/`tbl_rdata` live in a **separate UNRESET always block** and keep the previous
  VOBU's offsets — resolving in that window computes `0 ± stale_offset` and the clamp turns
  it into **a jump to the start of the title**, which "tap, tap again 200 ms later"
  reproduces every time. Guarded by a `dsi_fresh` latch (set by `dsi_commit`, cleared by
  `load_flush`), a mid-resolve restart, a base latched ONCE and exported as `jump_base`, and
  a ~2 s give-up. The contract is now recorded in `nav_dsi.sv`'s header for the next
  consumer. HUD: popup type 8 `SEEK FWD 30S` (the `pop_type` field widened 3→4 bits; the
  sign is SPELLED so the glyph ROM and `dvd/hud_font.mem` stay untouched) + the tap count in
  the shared `►►×n` field. Golden `tools/nav_extract.py --dpad`; tests
  `bench/dvd/dpad_seek_tb.sv` (24 scenarios incl. the trap), `scrub_ctrl_tb` T9–T12,
  `transport_hud_tb` T18–T20, all under `bench/dvd/run_dpad_seek.sh`. Design:
  **`docs/dvd_nav.md` §2b**.

---

## Key Architectural Decisions

### Why FPGA for video, HPS for audio?
The HPS is an 800MHz dual-core ARM Cortex-A9. When a core runs, one CPU core is
at ~100% handling MiSTer framework I/O. The remaining core cannot do real-time
MPEG-2 video decode (too slow — even ARM chips in the DVD era needed hardware assist).
AC-3/DTS audio decode (liba52/libdca) uses ~3–5% of one core at 48kHz — totally fine.

### Audio output strategy (Option 3: dual-path)
- **HDMI:** Stereo PCM downmix decoded on HPS (liba52/libdca) → ALSA dummy device →
  auto-mixed into MiSTer's HDMI audio output. Works on any TV, no extra hardware.
- **S/PDIF (future):** IEC 61937 bitstream passthrough over optical S/PDIF.
  **Not exclusive to the Digital I/O board** — the framework drives its `spdif` net to
  both `AUDIO_SPDIF` (Digital board TOSLINK) *and* `SDCD_SPDIF` (`PIN_AH7`), the latter
  being the **Analog I/O board's combo 3.5mm mini-TOSLINK** optical out. The real blocker
  is format, not the connector: the framework's `audio_out` only emits **PCM** S/PDIF, so
  passthrough needs our own `iec61937_wrap.sv` framing the *undecoded* AC-3/DTS frames
  (already available pre-decode at `ps_demux → audio_ring`) + driving the S/PDIF pin
  directly with the IEC 60958 non-PCM bit set. Design `iec61937_wrap.sv` now; targets
  whichever board has a populated optical transmitter. See `docs/audio.md` "Path B".

### CSS encryption
Handled entirely on HPS using **libdvdcss**. Replace raw `open()`/`read()` sector calls
with `dvdcss_open()` / `dvdcss_read(DVDCSS_READ_DECRYPT)`. The FPGA never sees
encrypted data. Works on ISO files, not just physical drives.

**CSS-encrypted ISO detect + warn + audio mute — ✅ MERGED + HW-CONFIRMED
2026-08-06 (PR fj#160).** A raw (undecrypted) rip
green-screens with loud audio static (FAIRYTOPIA.iso was the motivating case —
~19% of packs still scrambled; VLC plays it only because libdvdcss decrypts on
the fly). The core now detects `PES_scrambling_control != 0` in `ps_demux`
(`pes_scrambled` pulse), latches sticky `css_scrambled` in emu (4-pulse
threshold; survives jumps — ps_demux resets per-jump via pipe_rst_n; clears on
fresh mount only), shows a **persistent `CSS ENCRYPTED` HUD popup** (visible in
menus too, yields to user popups then re-arms), and **mutes both audio paths**
(decode: `AUDIO_L/R`=0; passthrough: `iec61937_wrap.mute_i` = PCM-silence bursts
that still drain the ring — no STD wedge). Video keeps playing so the disc is
identifiable. Sim: `ps_demux_scram_tb`, `iec61937_wrap_tb` T8, `transport_hud_tb`
T13. Detail: `docs/fabric_audio.md` "CSS mute", `docs/transport_hud.md`.

**DVD drive region tool (`main/Scripts/set_dvd_region.sh`, 2026-08-30) — ✅ READ +
gamepad menu HW-CONFIRMED 2026-08-31 (Scripts menu, gamepad-driven, 1 and 2 drives);
⏳ the SET ioctl is the one remaining gate.**
A drive with no region set refuses the CSS title-key ioctl, so every physical disc pays a
multi-second crack (`No drive region: cracking`); the Scripts-menu tool reads the region
(and the remaining-change count) and can set it, via `DVD_AUTH` — no compiled helper, since
python3 is stock on MiSTer. Two durable facts it is built around, worth knowing before
writing ANY MiSTer Scripts tool: a Scripts-menu script is run by handing its bare path to
`agetty`, so it can **never take arguments** (SSH only); and MiSTer injects uinput KEYBOARD
events from the gamepad while a script runs (D-pad→arrows, B1→Enter, B2→Esc) but **no digits
or letters** — so interactive means a cursor menu, never a typed prompt. A region set is
**irreversible** (no un-set, ~5 changes ever), hence cursor-starts-on-Cancel/No throughout.
Tested by `tools/test_set_dvd_region.py` (fakes the drive, drives the menus through a pty);
the ioctl itself is the HW gate. Design + ioctl details: `docs/physical_disc.md`.

### User bug reports arrive as sparse-sector nav bundles, not ISOs

**`tools/dvd_report.py` (2026-08-31) — the answer to "the disc that breaks it is
one I don't own".** A nav bug needs the IFO tables and nothing else, and those are
~0.005% of an image (104 KB of a 4.47 GB rip), so a reporter builds a **36–100 KB
zip** from their own rip on their PC. The bundle stores `{LBA → sector}` pairs at
their **original disc addresses**; `unpack` writes them into a **sparse** image of
the original size (6.77 GB apparent, 480 KB on disk). ★ **That is why no tool
needed changing** — `IsoNav` asserts `CD001` at sector 16 and follows absolute
LBAs, so the reconstruction simply *is* an ISO; it is also the `*_meta.hex`
testbench idiom, so a submission is already shaped like a regression fixture.
Validated 23/23 discs across the library: `iso_nav_check.py` output byte-identical
between original and reconstruction (up to 9,143 lines), plus `dvd_vm_ref.py`
boot/menu, `dvd_census.py`, `nav_extract.py`. Every bundle **self-checks by
rebuilding itself** before it is handed over (a bundle that cannot be walked is
worse than none — the reporter is gone by the time anyone opens it).
★ **The bundle contains ONLY unencrypted navigation structures — no picture, no
sound, no keys — and that is ENFORCED, not promised.** `audit()` refuses to write
a bundle if any gathered sector parses as an MPEG-PS pack containing anything but
a system header, padding or `private_stream_2`; proven RED against a real title
sector (`0xE0`) and green on a real NAV pack. It cannot carry key material even in
principle (title keys live in scrambled sector headers, the disc key block in the
lead-in, which is not in an ISO image at all) — and the IFO/NAV data it DOES carry
is capturable precisely because CSS never scrambles it (our own
`main/support/dvd/dvd_css.cpp:341,393` says so). ⚠ **Never relax this to accept
VOB payload "just for one bug"** — the guarantee is why a stranger can hand a
bundle over without thinking, and it is the same line as
`css-key-cache-never-ship`. ⛔ A `--from-drive` mode was considered and REJECTED
(2026-08-31, user decision): it points users at their optical drive, and a
reporter who has already ripped their own ISO is a better reporter.
⚠ Two traps recorded in `docs/bug_reports.md`: NAV-pack detection is **not**
`0x000001BF` at offset 14 (a **system header** pushes PCI to `0x26`; the fixed
offset found ZERO packs and reported success), and the tool is **deliberately
self-contained** — a reporter downloads one file, not a checkout, so it duplicates
a small ISO9660 walk instead of importing `IsoNav`. Scope is nav only; video-side
bugs (subpicture, CC, cadence, lip-sync) report in prose. User-facing entry:
the MANUAL page `site/content/reference/reporting-a-bug.md` (Reference → Reporting a
bug) — NOT the README, which is a landing page. Design: **`docs/bug_reports.md`**.

**★ AND FROM THE PLAYER ITSELF — a gamepad chord (2026-09-01, `MiSTer_DVDcss`;
✅ HW-CONFIRMED 2026-09-02, and on the hardest case first — a PHYSICAL DISC:
77 KB off a 7.22 GB disc, audit clean, full nav walk + VM boot chain on the
reconstruction, and ★ the playhead landed 2,064 sectors into the feature, which is
the fact a reporter can never supply. ★★ Reading `/dev/srN` while `dvd_css` holds
the drive WORKS — the thing flagged as likeliest to misbehave.)** Hold
**Audio + Subtitle 2 s** and the Main writes a bundle
for whatever is mounted — image OR optical drive — to `/media/fat/DVD_reports/`.
★ **The Main SHELLS OUT to `tools/dvd_report.py`, it does not reimplement the
collector** (python3 is on stock MiSTer; a C++ copy would drift, audit and
self-check included) — and that is also what DISSOLVED the old Scripts-menu
blocker: "no arguments, gamepad gives only arrows/Enter" stops mattering when the
Main already knows what is mounted and passes it as an argument. ★★ **A chord, not
an OSD row, because a `CONF_STR` entry changes the netlist and RE-ROLLS THE PINNED
FITTER SEED** — a one-line menu addition is not a one-line change in this project.
⚠ `dvd_report_joy()` **observes `map` and never modifies it**: masking the chord
bits would mean a detection bug could stop buttons working, and would swallow a
fast double-press — the accepted cost is that the chord also steps audio/subtitle
once each (why B7/B8, not the transport buttons, where a stray seek would linger).
⚠ **The work FORKS** — `dvd_report_tick()` shares the poll loop with SD block
service, so inline work would starve the core mid-playback; feedback rides Main's
own `InfoMessage()`, so no RTL change was needed for it either. Uniquely captures
`buffer_lba` = **where playback actually was**, which a reporter can never state
from memory. ⚠ **The DE10-Nano has NO battery-backed RTC** — an on-player bundle
from a never-networked MiSTer carries an epoch date in its filename AND
`created_utc`; unique per session, not trustworthy as a sequence
(`player.generated_on == "mister"` marks them). Integration steps 22–25. The **core version needs no new plumbing**: `CONF_STR`'s
`V,` line is appended to the OSD core name at init, so `OsdCoreNameGet()` reads back
`"DVD v0.4.0 260901"` — everything after the first space (no space ⇒ record nothing,
never pass the bare core name off as a version).
⚠ **`main/build_main.sh` used to copy the overlay as a HAND-MAINTAINED FILE LIST**
and silently omitted the new module — it now globs `support/dvd/*`; the failure
surfaced far away as a missing-header error in `user_io.cpp`.
Design: **`docs/support_bundle_hps.md`**.

### No USB DVD-ROM drive support
MiSTer's custom Linux kernel almost certainly lacks `sr_mod` (`CONFIG_BLK_DEV_SR`).
Recompiling the kernel is out of scope. Workflow: rip disc to ISO on PC, copy to SD card,
play from ISO. libdvdcss handles CSS decryption transparently on ISO files.

### ISO-based workflow
User places `.iso` files on the SD card. HPS opens ISO with libdvdcss, parses UDF,
navigates IFO, reads VOB sectors, feeds decrypted data to FPGA ring buffer.

**Test ISOs live in `$DVD_ISO_DIR/`** (decrypted DVD-Video rips, on the dev
machine — used for `tools/nav_extract.py`, `tools/spu_dump_iso.py`, etc.). Current set:
`MEN_IN_BLACK.iso`, `THE_MATRIX_16X9LB_N_AMERICA.ISO`, `ULTIMATE_T2.iso`,
`PAW_PATROL_MEET_EVEREST.iso`, `SCENEIT_HP.iso`/`SCENEIT_JR.iso`/`Scene_It.iso`.

---

## Audio Codec Support Plan

| Codec | Substream ID (PES) | HPS decode library | HDMI out | S/PDIF (future) |
|-------|-------------------|--------------------|----------|-----------------|
| AC-3 (Dolby Digital) | 0x80–0x87 | liba52 | ✅ stereo PCM | IEC 61937-3, Pc=0x0001 |
| DTS | 0x88–0x8F | libdca | ✅ stereo PCM | IEC 61937-5, Pc=0x000B |
| LPCM | 0xA0–0xA7 | none (raw PCM) | ✅ direct | N/A |
| MP2 (MPEG-1 Layer II) | stream_id 0xC0–0xC7 (no substream byte) | none — in-fabric `dvd/mp2/mp2_decode.sv` | ✅ stereo PCM ✅ HW-CONFIRMED 2026-08-24 | IEC 61937, Pc=0x0004 (not implemented; passthrough mode silences MP2) |

DTS support is essentially free once AC-3 works — same IEC 61937 wrapper, different
preamble constant and library. Always detect substream ID before routing audio PES.

**MP2 + MPEG-1 video — ✅ HW-CONFIRMED 2026-08-24 (branch `feature/mpeg1-codecs`,
build `DVD_mpeg1c`): the missing DVD-spec codecs, both in fabric — see
`docs/mpeg1.md`.** NTSC+PAL MPEG-1 clips + a converted VCD play with A/V sync on
the board. ⚠ HW-bringup lesson recorded in docs/mpeg1.md: Quartus 17 mangles
`N'(expr)` size casts (sim-perfect, silent silicon); caught by the new
post-map-netlist cosim technique — use part-selects/$signed instead. MP2 rides PES stream_id
0xC0+n directly (track select = stream_id low 3 bits; type `T_MP2 = 2'd3` reuses
the old "unknown" sentinel), reframed by `dvd/mp2_reframer.sv`, decoded by
`dvd/mp2/mp2_decode.sv` — **BIT-EXACT in sim vs the golden model
`tools/mp2_ref.py`** (which is itself ≤1 LSB vs ffmpeg float decode) on synthetic
48 kHz fixtures AND real VCD content, plus a full-chain TB (real `-f dvd` VOB →
ps_demux → reframers → audio_ring → dvd_audio_decode). Suite:
`bench/dvd/run_mp2.sh`. ~~44.1 kHz (VCD) plays ~8.8 % fast~~ — ✅ FIXED by the
VCD/SVCD feature below (NCO muxes on the MP2 header rate).
**SIF ANALOG FILL — ✅ HW-CONFIRMED 2026-08-24 (PR #2):** SIF content used to
show in the upper-left quarter of the ANALOG output
(the syncgen DE window tracks the decoded size; `re_interlace` is hardcoded 720-wide).
Now an in-core 2× fill — `disp_hstretch` 352→720 + the addrgen vscale walk re-armed as
mode 2 (2× line repeat) + a syncgen-only effective-size mux in `mpeg2video.v` — gated
on `analog_eff` (HDMI keeps ascal's scale; also fixes direct-video + un-clips the HUD).
True 240p output was REJECTED: no exact-59.94 Hz 240p modeline exists at 1716
dots/line, so it would drift against the fixed 48 kHz audio NCO — line-doubled 480i
carries the same content. ~~Sub-D1 MPEG-2 (704/544) intentionally NOT filled~~ —
scope REVERSED 2026-08-24 by user decision: the predicate is now `< 720` (any sub-720
width fills; SVCD 480 = exact 2:3), shipped with the VCD/SVCD feature below. Design:
`docs/mpeg1.md` §B.3; overlay inverse contract: `docs/crt_anamorphic.md` §9b. Sim:
`resample_chain_tb +sif=1`/`+hfill=1` variants (`+sif` runs co-sim the addrgen walk
vs the 2× closed form; `+hgrad` blend, `+crt` fields, `+siftog` runtime toggle),
`crt_ov_map_tb` T1d/T6.
**VCD + SVCD playback (bin/cue direct) — ✅ HW-CONFIRMED 2026-08-24 (user report:
VCD/SVCD good on analog + HDMI, seeking works; branch
`feature/vcd-svcd-playback`) — see `docs/vcd_svcd.md` (design + remaining
sub-item checklist).** Select the rip's data-track `.bin`
(CONF_STR gained BIN/IMG/DAT): `dvd_iso_reader` detects raw MODE2/2352 by the
sector sync at byte 0 (new S_CHK_RAW; RIFF/CDXA .DAT handled) and deblocks
in-line — Form-2 payloads [24,2348) only, Form-1/ISO track skipped, counted
wr_ptr advance — golden-model byte-exact (`tools/cd_deblock_ref.py`). `ps_demux`
auto-detects MPEG-1 system streams per pack (12-byte packs; S_M1_HDR/S_M1_STD PES
path reusing the S_PTS assembler; golden `tools/mpeg1_ps_ref.py`). MP2 output NCO
muxes 44.1/48/32 kHz off the new `mp2_decode.fs_o`, latched only while the drain
gate is closed. Whole-file seek + seek bar + pause on linear playback: raw seeks
snap to a sector (= pack) boundary; flat `.mpg`/`.VOB` seeks re-sync via a
post-seek 00 00 01 BA pack hunt (gated on `ps_demux.saw_pack`; `.m2v` stays
linear-only). SVCD display: HDMI already correct (ascal + DAR latch, 16:9
anamorphic included). Suite: `bench/dvd/run_vcd.sh` (real-VCD fixtures committed,
`tools/vcd_fixtures.py`; full chain PCM bit-exact + NCO cadence proven). v1
limitations (no VCD menus/PBC, no CD-DA tracks, no 2336-byte images, 23.976 film
VCDs play fast, HUD time zero in linear modes): `docs/vcd_svcd.md` §5.

---

## First Task: ps_demux.sv

The Program Stream demuxer is the first new RTL module to write. It sits between
`mpg_streamer.sv` (which feeds raw VOB sectors) and the existing MPEG-2 decoder.

It must:
1. Parse MPEG-2 Program Stream pack headers (start code `0x000001BA`)
2. Parse PES packet headers, extract `stream_id` and `substream_id`
3. Route video PES (`stream_id = 0xE0`) to the existing MPEG-2 decoder input
4. Route audio PES (`stream_id = 0xBD`) to the audio ring buffer for HPS pickup
5. Extract and pass through PTS timestamps for A/V sync

Write a testbench (`bench/dvd/ps_demux_tb.sv`) using a real VOB hex extract before
testing on hardware. A VOB file can be hex-dumped with `xxd VIDEO_TS/VTS_01_1.VOB | head -200`.

### Status & design decisions (implemented)

The FSM in `dvd/ps_demux.sv` is implemented and passes `bench/dvd/ps_demux_tb.sv` in
Icarus Verilog. It is now wired into the pipeline via `dvd/emu.sv`
(`mpg_streamer → ps_stream_fifo → ps_demux → mpeg2video`); the `dvd/ps_stream_fifo.sv`
adapter bridges `mpg_streamer`'s pulse (valid+busy) interface to `ps_demux`'s held
(valid+ready) handshake without dropping the in-flight byte. Integration is covered by
`bench/dvd/ps_chain_tb.sv`. Decisions baked in (full detail in `docs/architecture.md`):

- **Pack header is variable length:** 9 fixed bytes after `0xBA`, then a stuffing-length
  byte (low 3 bits) and that many stuffing bytes — not a flat 14.
- **private_stream_1 sub-header is stripped:** drop `substream_id` + 3 bytes (AC-3/DTS) or
  + 6 bytes (LPCM) so the HPS gets raw frames; `aud_frame_start` strobes each frame's first
  byte.
- **`aud_type` is 2-bit:** 0=AC-3, 1=DTS, 2=LPCM, 3=unknown (the 4-bit width in early docs
  is superseded).
- **Backpressure-safe 1:1 passthrough:** `in_ready` follows the active output's ready;
  counters/shift-register advance only on `in_valid && in_ready`.
- **`PES_packet_length` is the master byte counter** for each packet. Known limitation:
  `length == 0` (unbounded video PES) is not yet handled — OK for DVD VOBs, fix later via
  start-code-hunt fallback.
- **Raw elementary streams are auto-detected and passed through.** If the first start code
  is a video-layer code (`<= 0xB8`, e.g. `0xB3` sequence header) rather than a `0xBA` pack,
  `ps_demux` reconstructs the `00 00 01 <code>` preamble and forwards every byte to video
  (`S_ES_EMIT`→`S_ES_PASS`). This was the black-screen bring-up fix — on hardware all test
  files (`tools/streams/*.mpg`, ffmpeg `.m2v` extracts) were bare elementary streams the
  original PS-only demuxer discarded, starving the decoder. Tested by
  `bench/dvd/ps_demux_es_tb.sv`.
- **DVD nav/system packs are skipped by length (real-VOB robustness).** Any `stream_id
  >= 0xBB` that isn't pack/video/audio — esp. `private_stream_2`/NV_PCK nav packs (`0xBF`)
  and padding (`0xBE`) — is consumed in full via its 2-byte `PES_packet_length`
  (`S_SYS_LEN_HI/LO`→`S_DISCARD`) instead of being hunted past, so a `00 00 01` byte pattern
  inside a nav payload can't false-trigger a start code and desync the stream. Also added
  `VOB` to the `CONF_STR` extension list so `.VOB` files are directly selectable. Tested by
  `bench/dvd/ps_demux_nav_tb.sv`; the real-Matrix-VOB `ps_chain_tb` still passes (50,395 B).
  ⚠️ Sim-verified only — not yet confirmed on a real multiplexed VOB on hardware.
- **On-screen debug overlay** (`dvd/debug_overlay.sv`, `O2,Debug Overlay` toggle, default
  off) renders pipeline counters as on-screen block-bit rows — used to diagnose the above
  with no UART cable. **⚠️ COMPILED OUT of the release build** (`` `ifdef DEBUG_OVERLAY ``,
  congestion — see the "On-hardware diagnostics" note above): `O[2]` only shows these rows in
  a `DEBUG_OVERLAY` rebuild. In a release `.rbf`, `O[2]` drives the menu-highlight blocks.

## audio_ring.sv — Status & design decisions (implemented, sim-verified)

`dvd/audio_ring.sv` is the consumer for `ps_demux`'s audio output — a buffer that
holds complete audio frames for the HPS to pull out later (decode AC-3/DTS via
liba52/libdca, or pass LPCM, → ALSA → HDMI). Passes `bench/dvd/audio_ring_tb.sv`
in Icarus. **Built but NOT yet wired into `emu.sv`** (the audio outputs there stay
parked with `aud_ready=1'b1`); wiring it in + the HPS read path are the next steps.

- **Single-clock (clk_sys), no CDC.** The chosen HPS read transport is the
  MiSTer `ioctl_upload` channel, which runs in the clk_sys (27 MHz) domain — the
  same domain as `ps_demux`. So this is a plain single-clock FIFO, *not* the
  dual-clock FIFO the early docs assumed for an f2sdram path.
- **FLOW CONTROL — watchdog-guarded demux backpressure (revised 2026-07-02; the
  old "never backpressure into video" HARD INVARIANT is relaxed).** `ps_demux`
  carries video AND audio on one byte stream. The ring's own `aud_ready` output
  stays tied HIGH (accept-always; on overflow it **drops a whole frame** —
  rewinds bytes, bumps `overflow_count` — keeping boundaries intact), but it now
  also exports **`almost_full`**, and `emu.sv` gates `ps_demux.aud_ready` with
  it: when the ring is nearly full the shared demux STREAM stalls until the
  audio decoder drains (the DVD System-Target-Decoder model). The video PICTURE
  is unaffected — the video decoder rides its multi-MB VBUF bitstream backlog
  through the stall. Why: an overflow drop is a whole AC-3 frame = an audible
  32 ms gap (the low-fps audio "stutter"); backpressure loses nothing. Guard: a
  ~1.2 s drain watchdog in `emu.sv` (armed by `frame_pop`) — audio muted (O5) /
  wedged decoder → backpressure released, reverting to drop-on-full, so the
  stream can never wedge video. ⚠ **The watchdog must also count a PASSTHROUGH
  A/V-sync hold as "consumer alive"** (`iec61937_wrap.hold_active_o` re-arms it,
  2026-08-31): a hold produces no `frame_pop`, and reading it as a wedge left
  backpressure disengaged at every title start — the ring dropped ~25 frames/s
  for ~46 s and the dropped spans' PTS holes were the measured IEC 61937
  receiver lock flap (`docs/iec61937.md` "FLAP ROOT CAUSE"). The 48 kHz audio
  NCO stays untouched (same
  crystal as the raster + exact governor cadence ⇒ no drift to correct).
- **Two coupled FIFOs:** a byte ring (`BYTE_DEPTH`, default 8192) + a
  frame-descriptor ring (`FRAME_DEPTH`, default 64) of `{length[15:0], type[1:0]}`,
  one per *completed* frame. HPS pops a descriptor, then reads `frame_len` bytes.
  Both depths must be powers of two (pointers wrap naturally).
- **Committed vs in-progress:** `avail` = readable committed bytes, `fill` = all
  physical bytes. In-progress (or dropped) frame bytes sit ahead of the readable
  region and can never leak to the HPS.
- **LENGTH-DEFERRED FINALIZE (known limitation):** a frame's length is only known
  at the *next* `aud_frame_start`, so frame N commits when frame N+1 starts. The
  trailing frame isn't finalized until another starts — fine for continuous
  playback; a future flush/timeout input can finalize a lone last frame.
- **`aud_pts` not stored yet** (A/V sync is a later phase) — `ps_demux` PTS
  outputs stay parked.

### ⚠️ Debug-overlay gotcha: `watchdog_rst` is ACTIVE-LOW

When reading the **flag row (row 4)**, the watchdog cell (`[5]`) is special: the decoder's
`watchdog_rst` (`rtl/mpeg2/watchdog.v`) is **active-LOW** — it sits HIGH in normal operation
and only pulses LOW for one cycle if the watchdog actually expires. So a raw "green = signal
high" reading is BACKWARDS: green-on-the-raw-signal = NORMAL, not "firing." (This has bitten
multiple sessions.) The overlay now feeds cell `[5]` the **inverted/expiry** sense (`~watchdog_rst`
captured sticky-per-frame), so **green on the watchdog cell = the watchdog FIRED this frame
(BAD), red = healthy.** If you ever see watchdog code/overlay, double-check the polarity before
concluding "the decoder is hanging." The same caution applies to any active-low signal shown as
a flag.

---

## VS Code Settings

```json
{
    "verilog.linting.linter": "iverilog",
    "verilog.linting.iverilog.arguments": "-g2012",
    "files.associations": {
        "*.v": "verilog",
        "*.sv": "systemverilog",
        "*.svh": "systemverilog"
    }
}
```

Recommended extensions: `mshr-h.verilog`, `teros-technology.teroshdl`, `ms-vscode.cpptools`, `eamodio.gitlens`

---

## Simulation Quick Reference

```bash
# Simulate ps_demux module
iverilog -g2012 -o bench/dvd/ps_demux_sim \
    dvd/ps_demux.sv bench/dvd/ps_demux_tb.sv
vvp bench/dvd/ps_demux_sim

# Simulate audio_ring module
iverilog -g2012 -o bench/dvd/audio_ring_sim \
    dvd/audio_ring.sv bench/dvd/audio_ring_tb.sv
vvp bench/dvd/audio_ring_sim

# Full Quartus compile (from project root). The Quartus revision is `DVD`,
# so the output is output_files/DVD.sof
quartus_sh --flow compile DVD
```

---

## Building a MiSTer-loadable core (`.sof` → `.rbf`)

**Use `./build_release.sh` — do not call `quartus_cpf` bare.** MiSTer's HPS FPGA
loader requires a **compressed** Raw Binary File. A plain
`quartus_cpf -c x.sof x.rbf` produces an **uncompressed** bitstream (~7 MB) that
silently fails to configure the FPGA: the core "loads" but gives **no video on
either HDMI or the analog board** (no signal at all, not garbled — a dead
giveaway for a bad pack). A correct compressed `.rbf` for this device is
*4.2 MB**.

```bash
./build_release.sh                 # pack existing .sof -> releases/<name>_<date>.rbf
./build_release.sh --compile       # run the full Quartus compile first, then pack
./build_release.sh --name DVD_foo  # override the release base name
```

**★ Always name builds uniquely (`--name`).** Every build MUST get a distinct,
descriptive `--name DVD_<feature>` tied to the feature/branch (e.g.
`--compile --name DVD_ilauto`) — never leave the generic default, which produces a
meaningless name like `DVD_ps_demux_<date>.rbf` that collides across features and can't be
told apart on the SD card. The date/time suffix is appended automatically.

The script always passes `-o bitstream_compression=on` and warns if the output
exceeds ~4 MB. Copy the resulting `releases/*.rbf` to the SD card to load it.

### Versioning and publishing releases

Two identifiers, deliberately at different granularities:

- **`` `CORE_VERSION `` in `dvd/emu.sv`** — the series (`0.1b`), shown in the OSD as
  ``v`CORE_VERSION` `BUILD_DATE` `` (e.g. `v0.1b 260825`). **Bump it the moment a release
  is PUBLISHED, not when the next one is cut**, so no dev build ever advertises a version
  that already exists on the releases page — that line is the only thing a bug report can
  quote. Keeping the next version open also means the latest `.rbf` already matches the
  tag when you decide to release, instead of forcing a rebuild (and a possible fitter
  re-sweep) at release time.
  **★ Corollary — check at the START of every feature branch (instituted 2026-08-26, by
  user decision):** before building a new feature, verify `` `CORE_VERSION `` is AHEAD of
  the latest published release (`gh release list`); if it still equals a published tag,
  bump it as the branch's first commit. The point is that ANY feature build must be
  publishable as-is as the next release — its version line already distinct from
  everything on the releases page. This costs nothing extra in the seed lottery: a
  feature branch changes the netlist anyway, and folding the bump into the branch means
  ONE re-roll instead of a second one at release time. (The saved-settings `"v,N;"`
  config version is a SEPARATE, coarser counter — bump that one only on an incompatible
  `O[..]` relayout, see `docs/idle_screen.md`.)
  **★ HOW FAR to bump (instituted 2026-08-31, by user decision — the rule existed only
  as precedent until someone had to ask):**
  - **patch** (`0.2.0` → `0.2.1`) — bug fixes, doc-only changes, internal rework with no
    change in what the user can do.
  - **minor** (`0.2.1` → `0.3.0`) — ANY new user-visible capability: a new format or
    output path, a new OSD option, or content that used to be silent/broken now working.
    If the release notes would lead with it, it is a minor bump.
  - **major** — reserved; nothing has warranted it yet (`1.0` would be a
    "this is finished" statement, not a size-of-change one).
  The failure this prevents is a release whose version says "fixes" while its own notes
  lead with a headline feature — the version line is what a user quotes in a bug report,
  so it should not understate what they are running. Precedent: `0.1d` → `0.2.0` for
  physical-disc playback; `0.2.1` → `0.3.0` for HDMI bitstream + multichannel AC-3.
  ⚠ Judge the bump against the WHOLE unreleased delta on `main`, not just the branch in
  hand — several patch-looking merges can add up to a minor release.
- **`BUILD_DATE`** — `yymmdd`, regenerated per compile by `sys/build_id.tcl`. ⚠ Do NOT
  extend it with a time or a git SHA to separate same-day builds: it is part of
  `CONF_STR`, hence part of the netlist, so every compile would become a new netlist and
  re-roll the fitter seed lottery (see `DVD.qsf`'s seed ledger). Same-day dev builds are
  told apart by their `build_release.sh --name` filename, which already carries
  `<date>_<time>`.

Publishing (GitHub, `gh`): tag `v<version>-<yyyymmdd>` (the first release was
`v0.1a-20260825`), title `<version> (<date>) — <headline>`, attach the **timing-clean**
`.rbf` only — never a `_MARGINAL_` one. Then bump `` `CORE_VERSION `` in the same session.

> **Always build after completing a requested feature.** When an RTL/feature change is
> finished (committed, PR opened), run `./build_release.sh --compile` to produce a fresh
> loadable `.rbf` so it's ready to flash and HW-test — don't leave the user to trigger the
> build. (Long-running Quartus compile: kick it off in the background and report the result.)

**Timing note:** this baseline does not formally close timing — large negative
slack appears on Altera PLL-reconfig / HPS-bridge paths (`~PLL_OUTPUT_COUNTER|divclk`,
`h2f_*`, `pll_audio`). These are infrastructure paths every MiSTer core reports
and are shared with the known-working `releases/*.rbf`; they are not the
functional video datapath. Validate empirically (does video play?), not by
chasing TimeQuest to zero.

---

## References

See `docs/references.md` for full list. Key links:
- Upstream repo: https://github.com/mrchrisster/MiSTer_MPEG2
- MiSTer Template: https://github.com/MiSTer-devel/Template_MiSTer
- MiSTer hps_io docs: https://mister-devel.github.io/MkDocs_MiSTer/developer/hps_io/
- libdvdcss API: https://www.videolan.org/developers/libdvdcss/doc/html/dvdcss_8h.html
- MiSTer forum DVD thread: https://misterfpga.org/viewtopic.php?t=2146

Audio (in-fabric AC-3 + LPCM): `docs/fabric_audio.md`. The AC-3 decoder (`dvd/ac3/*`,
ported from the now-archived `MiSTer_AC3` repo) has its own scope/verification/decisions
reference in `docs/ac3_decoder.md` and module/interface/fixed-point contract in
`docs/ac3_decoder_architecture.md`.


## Source control

**This repository is PUBLIC.** Everything pushed — code, comments, docs, commit messages,
PR titles and descriptions — is visible to anyone, permanently, and is not meaningfully
undone by a later commit. The publishing rules below exist because of that, and they
override the default instinct to push early and open a PR as soon as a branch exists.

- **Never commit directly to `main`.** If `main` is checked out when a feature is requested, automatically create a feature branch (e.g. `feature/<short-description>`) before writing any code.
- **Never push a branch or open a PR until explicitly asked to.** Work locally and commit
  freely; a feature branch is a private workspace until its author decides otherwise.
  Experimental and dead-end branches must not reach the public remote at all. Do not
  "helpfully" push at the end of a task, and do not treat finishing the work, a green
  build, or a passing test as permission. Say the branch is ready and stop.
- **If asked to merge a branch that has not been published, do the missing steps first**,
  in order: push the branch, open the PR, then merge it. A merge request is authorisation
  to publish that branch; it is not retroactive authorisation for anything else.
- Use PRs to merge feature branches into `main`.
- Commit often — after each logical, self-contained change (not just at the end of a task).
- Write clear, descriptive commit messages that explain *what* changed and *why*.

### ★ Never publish personal or workstation-specific information

Applies to **everything that lands in the repository or on the remote**: RTL, scripts,
docs, `.gitignore`, commit messages, and PR text alike.

Never write:

- **Absolute paths from a development machine** — `/home/<user>/...`, `C:\Users\...`,
  `/Users/...`, or any path that only resolves on one workstation.
- **Host, user, or account identifiers** — usernames, hostnames, e-mail addresses,
  self-hosted service URLs, VPN or LAN addresses, SMB/NFS share names, serial numbers.
- **Private infrastructure detail** — internal repo URLs, CI endpoints, home-network
  layout, or anything describing where a machine sits rather than how the code works.

Write instead:

- **Paths relative to the repository root** — `tools/css_scan.py`, `docs/dvd_nav.md`,
  `bench/dvd/test_vobs/`. Scripts resolve their own location rather than assuming a cwd
  (see `build_release.sh` and `tools/seed_sweep.sh` for the pattern).
- **Environment variables with generic fallbacks** for anything outside the repository —
  disc images, external checkouts, capture files. `${DVD_ISO_DIR:-~/dvd-isos}`, not one
  person's library path. Document the variable; do not hardcode a default that only works
  on one machine.
- **Generic placeholders** in examples — `/dev/sr0`, `<disc>.iso`, `<user>/<repo>`.

Two failure modes worth naming, because both happened here:

1. A hardcoded `cd` to one developer's checkout in `tools/seed_sweep.sh` made the script
   fail immediately for everyone else — a functional break, not cosmetic, and it sat in
   the one script a contributor reaches for when a fit comes in marginal.
2. Absolute media paths spread into ten files as *documentation*, where they read as
   authoritative and quietly told every reader to look somewhere that does not exist.

When a real local path is genuinely needed to reproduce a past result, describe it
generically ("the local ISO library") rather than reproducing it.

### Opening a PR after every feature branch

**Only when explicitly asked** (see the rule above — finishing the work is not a cue).
Push the branch first, then open the PR. The remote is **GitHub** — use the `gh` CLI
(authenticated):

```bash
gh pr create --title "<title>" --base main --head <branch> --body-file /tmp/pr_body.md
```

Include a short summary and a markdown test plan checklist in the body. Present the
returned PR URL to the user. Write the body to a file rather than passing `--body` inline —
long markdown with backticks and checklists does not survive shell quoting reliably.

### Merging a PR

```bash
gh pr merge <number> --merge        # or --squash / --rebase
```

### Updating a PR description

```bash
gh pr edit <number> --body-file /tmp/pr_body.md
```

To read a PR's current body back (e.g. to tick test-plan checkboxes):

```bash
gh pr view <number> --json body -q .body
```

### ⚠ Historical `fj#NN` references — do not "fix" them

This project developed in a private **Forgejo** repository before moving to GitHub, and
`docs/` cites those PRs heavily. GitHub numbering restarts at 1, so a bare
`#84` would eventually point at an unrelated GitHub PR — a reference that looks right and
is wrong, which is exactly the class of documentation bug the rules above exist to prevent.

Every historical reference is therefore written **`fj#NN`** (and `issue fj#NN`). These are
Forgejo numbers and have no GitHub equivalent. Leave them alone; do not renumber them, and
do not strip the prefix. New PRs opened on GitHub use plain `#NN` as normal — the two
namespaces are distinguishable on sight and that is the whole point.

The Forgejo history was not migrated: the public repository starts from an upstream-import
commit plus the accumulated work. Commit SHAs quoted in `docs/` likewise refer to the
pre-migration history and will not resolve here.
