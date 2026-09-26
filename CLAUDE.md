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
  - `docs/status_log.md` — the per-feature engineering record (field report, root cause,
    measurements, refuted theories, HW evidence), newest first. `CLAUDE.md` holds only a
    **one-row index** per feature ("Feature status index").

- **★ Size budget: keep `CLAUDE.md` under ~60 KB** (~53 KB after the 2026-09-25
  cleanup). It is loaded into EVERY session, and by 2026-09-25 it had grown to 512 KB
  (~125K tokens) because each feature pasted a 50–200 line write-up into it. Anything longer than about three lines about one feature belongs
  in `docs/`. A lesson that changes how *every* change is made goes in "Cross-cutting
  lessons" as one line. A lesson specific to one feature stays with that feature's entry.

- **When to write it:** at the same time as the code, not "later." Commit docs together
  with the change that motivated them.

- **What to record:** the *why* behind each decision, known limitations / TODOs, design
  alternatives that were rejected (and why), and anything that surprised you or wasn't
  obvious from reading the code.

### Leave a trail to resume work in a new session

Sessions are stateless — after a feature branch merges, the next session starts cold and
has only the committed markdown to go on. Before finishing any feature, ensure the docs
leave enough hints to pick up cleanly:

- Add or update the feature's **entry at the top of `docs/status_log.md`** (what's
  implemented, what's wired in, what isn't) and its **one row** in `CLAUDE.md`'s
  "Feature status index" (or its "Known gaps" list).
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
  <https://owenb321.github.io/MiSTer_DVD/> by `.github/workflows/docs.yml`, **only when a
  release is published**, and built from that release's own tagged commit. A push to `main`
  or a PR touching `site/**`, `mkdocs.yml`, `tools/docs_check.py` or `dvd/emu.sv` still
  *builds* the manual as a CI check — it just does not deploy it. ⚠ **So a doc fix merged
  to `main` does not reach users until the next release**; to push one out sooner, dispatch
  the workflow **with the release tag as the ref** (`gh workflow run docs.yml --ref
  v0.4.0`), never from `main`. Every user-visible detail lives here: controls, every OSD setting, on-screen messages,
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

**Unreleased features no longer need marking** (changed 2026-09-09, by user decision).
The `!!! info "Unreleased"` admonition existed because the site was deployed from `main`, so
the published manual described a development build nobody could download — a reader had no
way to tell which half applied to them, and remembering the admonition was the writer's
burden. Deploying only on a release publish removes the divergence at the source: what is
published is the tagged commit's manual for the core released beside it. Write manual pages
in the present tense as the feature lands. Existing admonitions are harmless and the release
process still sweeps them; `extra.released_version` in `mkdocs.yml` stays — it names the
version on the announcement bar and `package.yml` refuses to package a release whose tag
disagrees with it.

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

- **When you complete or merge a feature, update its status markers in the SAME change**:
  its row in `CLAUDE.md`'s index, its `docs/status_log.md` entry, `docs/roadmap.md`, and
  any per-feature status header in `docs/` (e.g. section headers in
  `docs/dvd_menu_refinements.md`, `docs/dvd_nav.md`, `docs/dvd_vm.md`).
- Flip the marker to reality: `🔧`/`❌`/`[ ]`/"sim-verified, HW gate pending" →
  `✅ MERGED (PR #NN)` and, once the board test passes, `✅ HW-CONFIRMED`. If merged but not
  yet hardware-tested, say exactly that (`⏳ HW-confirm pending`) — don't leave it reading "gate pending".
- **Retire dead branch names.** A merged feature must not still point at a live `feature/*`
  branch in prose — replace it with the PR number.
- Treat a lingering `🔧`/"HW gate pending"/`feature/*` reference on shipped work as a
  documentation bug: fix it on sight. When in doubt about true status, reconcile against
  `gh pr list --state merged` (what actually merged), not the branch name.

---

## ★ Before adding a feature: read `docs/hw_budget_and_lessons.md`

A post-mortem of the abandoned Stage B deinterlacer (2026-09-21), kept because almost
none of what it taught is about deinterlacing. Three things in it change how the next
feature should be designed:

- ★ **A whole idle 64-bit DDR3 port (`ram2`) is available**, proven idle in this fork
  (ALSA compiled out, no `MISTER_FB`). ⛔ NOT ascal's `vbuf`, which is the busiest port.
- ★★ **The scarce memory resource is ARBITRATION OCCUPANCY, not bandwidth.** Measured
  three ways, most sharply: the same traffic cost 2.7 dropped frames/s sharing `ram1`
  with the decoder and **exactly zero** on its own port. So when a new master hurts the
  decoder, give it a port before shrinking its data.
- ★★★ **How a feature with 42 green arms and a favourable offline model still shipped as
  a visible regression** — the bit-exact cosim never exercised it, and a bench scored
  `!=` on X so a third of its pixels passed vacuously. The rules earned are in §4 and
  apply to every bench in this tree.

Also: current fabric headroom (~7 % ALM / 7 % M10K / 10 % DSP), what a DDR3 line pump
costs (~190 ALM + 6 M10K), and the retime trick that took a build from two failed seed
sweeps to a first-fit pass.

---

## ★ Design to the DVD spec maximum (mandatory, instituted 2026-09-19)

Every table, counter, index width and loop bound that holds a DVD-Video structure must be
sized for **the maximum the format allows**, not for what a measured sample of discs
happened to contain. Size to the spec unless there is a **hard limitation**, such as
M10K/ALM budget, timing, or a register the hardware cannot widen. When that happens,
**discuss the pros and cons with the user before deciding**, and record the decision, the
limit chosen and what breaks past it beside the code and in `docs/`. A smaller bound
must never be picked silently.

**Why.** This mistake has shipped twice, and both times the smaller number looked safe
when it was written:
- **issue #112 (2026-09-19):** `dvd_css.cpp` held 64 VOBs. "OZ: The Great and Powerful"
  lists 91, because it files one feature extent under 11 title sets. The VOBs past entry
  64 were silently read without decryption, so the disc showed green garbage and
  `CSS ENCRYPTED`.
- **the >128-cell seek alias (2026-09-17):** 7-bit cell indices in the seek tables, which
  a "measured unreachable" note justified. The measurement had sampled the wrong
  population, and 47 PGCs across 12 discs exceeded it.

A library sweep says what is *common*. It cannot say what is *possible*: authoring tools
and copy-protection schemes deliberately produce structures no sample predicts.

**And never truncate silently.** If a bound is ever hit, whether a hard-limited one or
input that violates the spec, make it visible: a log line in the Main, or a counter/flag
in the RTL that a bench or telemetry can see. Whatever falls past the bound must not
quietly turn into wrong output.

Reference maxima (DVD-Video; confirm the field width in the IFO parse before relying on
one):

| Structure | Max |
|---|---|
| Video title sets (VTS) | 99 |
| Titles (`TT_SRPT`) | 99 |
| Title VOB parts per VTS | 9 (plus one menu VOB) → 991 `.VOB` files per disc |
| Cells per PGC | 255 (`nr_of_cells` is one byte) |
| Programs (chapters) per PGC | 99 |
| Angles | 9 |
| Audio / subpicture streams | 8 / 32 |
| Buttons per HLI | 36 |
| GPRM / SPRM | 16 / 24 |

---

## Repository Structure

```
MiSTer_DVD/
├── CLAUDE.md                  ← you are here
├── docs/                      ← ENGINEERING NOTES — not published, NOT the manual
│   ├── README.md              ← says exactly that, for anyone who browses in
│   ├── status_log.md          ← per-feature record behind CLAUDE.md's status index
│   ├── architecture.md        ← full system design & data flow
│   ├── audio.md               ← AC-3, DTS, LPCM audio strategy
│   ├── roadmap.md             ← phased implementation plan
│   ├── references.md          ← key repos, specs, libraries
│   └── hw_budget_and_lessons.md  ← ★ READ BEFORE ANY DDR3 OR NEW-FEATURE WORK:
│                                   the FREE ram2 port, fabric headroom, and the
│                                   verification rules a failed feature earned
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
│   └── workflows/docs.yml     ← check the manual on push/PR; deploy it on a release
├── rtl/                       ← UPSTREAM mpeg2fpga decoder (fork edits allowed, see below)
├── sys/                       ← UPSTREAM: MiSTer framework (edit only when unavoidable)
├── dvd/                       ← this fork's RTL: emu.sv (top), reader, demux, audio,
│                                 nav/VM, HUD, overlays, ac3/, mp2/
├── hps/                       ← RETIRED. The HPS audio daemon's C sources were deleted in
│                                 the pre-release cleanup; only two stale compiled ARM
│                                 binaries remain tracked (~1.7 MB). Nothing builds or
│                                 uses them — candidates for deletion.
├── main/                      ← MiSTer_DVDcss overlay (custom Main: physical disc + CSS)
│   ├── support/dvd/           ← drive probe, CSS via libdvdcss, encrypted-image source
│   ├── Scripts/               ← install_dvdcss.sh, set_dvd_region.sh (ship in releases)
│   └── build_main.sh          ← fetch stock Main, apply overlay, cross-compile
├── tools/                     ← golden models, disc sweeps, wiring checkers, HIL harness
├── bench/
│   ├── ac3/                   ← AC-3 decoder unit + cosim suites
│   └── dvd/                   ← testbenches and run_*.sh gates (`--red` = mutation arms)
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

## Feature status index

**One row per shipped or in-flight feature. The full write-up of each one — the field
report, the root cause, the measurements, what was refuted, the HW-round evidence — is in
[`docs/status_log.md`](docs/status_log.md)** (newest first, moved there verbatim on
2026-09-25 when this file had grown to 512 KB). Read the log entry before touching a
feature: most of them record a wrong theory that cost a hardware round, so it doesn't get
re-derived.

**Code comments across `dvd/`, `bench/`, `tools/` and `DVD.qsf` that say "see CLAUDE.md"
for a story or measurement usually mean that story's entry in `docs/status_log.md`**
(they were written before the move). The rules they cite, such as versioning and the spec
maximum, are still here.

Markers: ✅ = HW-confirmed · 🔧 = merged/sim-proven, HW partial · ⏳ = named open item.
`docs/` is the design note, and "gate" is the regression runner (`bench/dvd/` unless it says
otherwise; `--red` runs its mutation arms).

### Discs, navigation and menus

| Feature | Status | Detail | Gate |
|---|---|---|---|
| In-fabric ISO9660/IFO navigation, largest-VTS/longest-PGC pick | ✅ | `dvd_nav.md` | `iso_reader_*_tb` |
| Disc menus: VM interpreter, HLI highlights, menu domain, VBUF hold (Phases 2–5) | ✅ | `dvd_vm.md`, `dvd_nav.md`, `dvd_menu_refinements.md` | `dvd_vm_tb`, `nav_pci_tb` |
| Boot-chain menu shortcut (the one deliberate libdvdnav deviation) | ✅ | `dvd_vm.md` | `dvd_vm_tb` [S21] |
| POST-only PGC dispatch; forced select on a new HLI | ✅ | `dvd_vm.md`, `dvd_nav.md` | `dvd_vm_tb` [S23] |
| Link-button field survives the flush (`hl_btnn`) | ✅ | `dvd_nav.md` | `run_link_button.sh`, `check_hl_btnn_wiring.py` |
| HLI window sequence (Scooby whac-a-mole) | ✅ ⏳ first-window fallback timing | `dvd_nav.md` | `run_hli_window.sh` |
| Failed menu link re-enters the menu | 🔧 ⏳ positive case (Blade Runner) | `dvd_vm.md` | `dvd_vm_tb` [S22] |
| Select during a menu transition is a no-op | ✅ | `dvd_nav.md`, `dvd_vm.md` | `run_select_noop.sh`, `check_select_noop.py` |
| Menu slideshow first slide (natural drain in every domain) | ✅ | `dvd_menu_refinements.md` §9 | `run_menudrain.sh`, `run_menu_junction.sh` |
| Quantiser matrix across flushes: soft reset on domain crossing, `es_stuff` zeros | ✅ | `quant_matrix.md` | `run_quant_matrix.sh`, `run_es_stuff.sh`, `check_es_stuff_wiring.py` |
| Soft reset keeps sync at the pins (`hard_rst` on the sync delay line) | ✅ | `quant_matrix.md` | `run_sync_integrity.sh` |
| Picbuf display-slot alias (pixelated stills) | ✅ | `dvd_menu_refinements.md` §5, `decoder_audit.md` | `motcomp_picbuf_tb` |
| Natural transition waits for audio (`aud_drain`) | ✅ | `dvd_nav.md` | `run_auddrain.sh` |
| Seek anchor: pre-flush picture untagged | ✅ | `dvd_nav.md` | `picbuf_tag_flush_tb`, `disp_sched_tb` [14e] |
| Auto mode: skip unusable PGCs, longest-duration PGC | ✅ | `dvd_nav.md`, `physical_disc.md` | `iso_reader_pgc_tb` |
| Auto mode: chapter table of the PGC it plays (issue #132) | ✅ (HIL) | `dvd_nav.md` | `run_auto_ptt.sh` |
| Angles: `next_vobu` without `sml_agli`, SPRM3 from the VM, PRE before resolve | ✅ | `dvd_nav.md`, `track_selection.md` | `run_angle.sh`, `check_angle_wiring.py` |
| Adjacent angle blocks (count stops at the block edge) | ✅ | `dvd_nav.md` | `iso_reader_angle_tb` C |
| Seeking inside an angle block (timeline, arm, VOB_ID snap) | ✅ | `dvd_nav.md` | `iso_reader_angle_tb` D/E/G |
| Seamless-branch seek (issue #49) | ✅ | `dvd_nav.md` §2e | `run_branch_seek.sh` |
| >128-cell PGCs (8-bit cell index end to end) | ✅ | `dvd_nav.md` §2g | `seek_time_tb` T12 |
| Program order ≠ physical order (title span, notches, preview) | ✅ | `dvd_nav.md` §2f | `run_title_span.sh` |
| Time-map (TMAP) seek (issue #127) | ✅ | `dvd_nav.md` §2h | `run_tmap_seek.sh`, `check_tmap_seek_wiring.py` |
| Subpicture logical→physical map, domain gate (issue #81) | 🔧 ⏳ HW | `track_selection.md` | `run_subpic.sh`, `check_subp_map_wiring.py` |
| Audio logical→physical stream map | ✅ | `track_selection.md` | `aud_stream_map_tb` |
| Seamless-junction audio, SPU display-order window, undeclared-stream guard | ✅ | `stc_freerun.md` §12 | `run_seamless_audio.sh`, `run_spu_window.sh` |
| SPU re-send guard per cell, `hl_mask` | ✅ | `subpicture.md` | `run_spu_newcell.sh` |
| Highlight colours replace every class (flashlight) | ✅ | `subpicture.md` | `run_flashlight.sh` |
| Highlight promotion model v2 | ✅ | `dvd/nav_pci.sv` header | `nav_pci_tb` |

### Transport, HUD and input

| Feature | Status | Detail | Gate |
|---|---|---|---|
| Cell seek, pause, hold-to-scrub (VOBU-snapped) | ✅ | `dvd_nav.md` §2a | `iso_reader_seek_tb`, `scrub_ctrl_tb` |
| Scrub tiers: content-rate ladder shared by DVD and linear | ✅ | `dvd_nav.md`, `transport_hud.md` | `run_scrub_tiers.sh` |
| D-pad fixed-time seek (`O[45]`), linear-file rate from PTS | ✅ | `dvd_nav.md` §2b, `vcd_svcd.md` §3a | `run_dpad_seek.sh` |
| Transport HUD + seek bar + seek-preview clock | ✅ | `transport_hud.md` | `transport_hud_tb`, `seek_bar_tb`, `seek_time_tb` |
| HUD authored for the DE window, not the raster | ✅ | `transport_hud.md` | `run_ov_geom.sh`, `check_ov_geom_wiring.py` |
| Keyboard / CEC / IR-receiver transport (`kbd_map`) | ✅ ⏳ CEC unsupported on the rig | `dvd_nav.md` | `run_kbd.sh` |
| Remote buttons: Stop, Aspect, Chapter Menu, A-B, Frame Step, Eject, Volume | ✅ | `dvd_nav.md`, `screensaver.md` | `run_frame_step.sh`, `check_frame_step_wiring.py` |
| Frame step as a pause route; unbounded steps; clock follows the step | ✅ | `dvd_nav.md` | `run_frame_step.sh` |
| Screensaver, and overlays blanked with the picture | ✅ | `screensaver.md` | `run_screensaver.sh`, `check_saver_overlay_wiring.py` |
| Launch feedback: config versioning, startup OSD, idle logo | ✅ | `idle_screen.md` | — |
| MGL launch (issue #48) and the drive's slot ownership | 🔧 mostly ✅ | `mgl_launch.md` | `run_mgl.sh`, `main/tests/run_tests.sh` |

### Video and output

| Feature | Status | Detail | Gate |
|---|---|---|---|
| Single-raster analog output (N64 half-line model) | ✅ | `single_raster_analog.md` | `modeline_boot_tb` |
| SMPTE 170M / BT.470 composite sync, `FIELD1_VPOS` | ✅ ⏳ original reporters' sets | `single_raster_analog.md` §3.10–3.12 | `run_csync_field.sh`, `run_csync_pipe.sh` |
| Video Output = Auto/Interlaced/Progressive | ✅ | `field_parity.md` | `run_field_parity.sh` |
| Field-parity corrector (stable-error gate, hold arm), `VGA_F1` polarity | ✅ | `field_parity.md` | `run_field_phase.sh` |
| Field-coded MPEG-2 display order (`first_field_top`) | ✅ | `field_parity.md` | `run_field_order.sh`, `check_field_order_wiring.py` |
| Pause holds one field (field still) | ✅ | `field_parity.md` | `run_pause_still.sh` |
| Deinterlace = Weave/Bob/Blend (`O[51:50]`) | ✅ | `field_blend.md` | `run_field_blend.sh`, `check_field_blend_wiring.py` |
| Mode-switch re-align + switch blank; `pal_detect` hardening | ✅ | `single_raster_analog.md` §6 | `run_mode_realign.sh` |
| Post-seek reference re-align (issue #45) | ✅ | `seek_realign.md` | `run_seek_realign.sh` |
| Film 24p evidence gate (no flapping) | ✅ | `film_24p_plan.md` §14 | `run_film_evidence.sh` |
| PAL/NTSC runtime modeline | ✅ | `roadmap.md` | — |
| Native 240p/288p for SIF, 352→720 horizontal fill | ✅ ⏳ PAL 288p, long VCD | `mpeg1.md` §B.3b | `run_p240.sh`, `check_p240_wiring.py` |
| Line-21 closed captions (`cc_vbi`, pickup-paced) | ✅ | `closed_captions.md` | `cc_extract_tb`, `cc_line21_tb` |
| mem_shim tag/LRU store in M10K | ✅ | `history.md` §11 | `run_mem_shim.sh` |
| Logic reclaim (AC-3, nav/VM, reader ×2; debug overlay retired) | ✅ (D HW-confirmed 2026-09-26) | `logic_reclaim.md` §8 | `bench/ac3` suites, `run_reader_regress.sh` |

### Audio and A/V sync

| Feature | Status | Detail | Gate |
|---|---|---|---|
| In-fabric AC-3 (acmod 1–7) + LPCM decode | ✅ | `fabric_audio.md`, `ac3_decoder_architecture.md` | `bench/ac3/*`, `dvd_audio_decode_tb` |
| MP2 + MPEG-1 video | ✅ | `mpeg1.md` | `run_mp2.sh` |
| Free-running STC + PTS-scheduled display (PR #63) | ✅ | `stc_freerun.md` | `run_stc_freerun.sh`, `run_pts_assoc.sh`, `disp_sched_tb` |
| A/V Sync toggle (`O[13]`, diagnostic arm) | ✅ | `fabric_audio.md` | — |
| Audio-track switch realign + output de-click | ✅ ⏳ MiB menu loop burst | `fabric_audio.md` | `run_aud_switch.sh` |
| AC-3 reframer (whole-frame drops) | ✅ | `fabric_audio.md` | `ac3_reframer_tb` |
| IEC 61937 passthrough: optical and HDMI, lock-flap fix | ✅ | `iec61937.md`, `hdmi_bitstream.md` | `run_hdmi_bitstream.sh` |
| Optical passthrough follows the HDMI post-reset hold | ✅ | `iec61937.md` | `check_spdif_bs_hold_wiring.py` |
| HDMI passthrough teardown (ADV7513 back to PCM) | ✅ | `hdmi_bitstream.md` §5a | `run_passthru_pcm.sh`, `main/tests` |
| Mid-play load: full flush trio + decoder soft reset | ✅ | `av_sync.md` | `flush_ctl_tb` |
| CSS-encrypted detect/warn/mute, density bucket (issue #59) | ✅ | `fabric_audio.md` | `run_css.sh` |

### Formats and physical media (mostly the custom Main, `main/`)

| Feature | Status | Detail | Gate |
|---|---|---|---|
| Physical DVD + CSS (libdvdcss) in `MiSTer_DVDcss` | ✅ | `physical_disc.md` | `main/tests/run_tests.sh` |
| Title key per VOB start; one key per title set; heal (issue #122) | ✅ on the rig | `physical_disc.md` | `main/tests/run_tests.sh --red` |
| VOB table sized to the spec (issue #112) | ✅ | `physical_disc.md` | `main/tests` |
| Read-ahead ring; full read windows at VOB ends; eject EBUSY | ✅ ⏳ audio underrun is phase 3 | `physical_disc.md` | `main/tests` |
| VCD/SVCD from `.bin`, and from a physical disc | ✅ | `vcd_svcd.md`, `physical_disc.md` | `run_vcd.sh`, `main/tests` |
| WAV / CD-DA raw PCM; physical audio CD; visualizer | ✅ ⏳ next on last track | `cdda.md` | `run_wav.sh`, `cdda_toc_tb` |
| `.cue` sheets (audio CD and VCD) | ✅ | `cdda.md` | `main/tests/run_tests.sh --red` |
| Drive region tool (`set_dvd_region.sh`) | ✅ ⏳ RPC-1 arm | `physical_disc.md` | `tools/test_set_dvd_region.py` |
| Support bundle: `dvd_report.py` + the Audio+Subtitle chord | ✅ | `bug_reports.md`, `support_bundle_hps.md` | `main/tests` |

### Known gaps

- ❌ HD output (720p/1080p): fixed 27 MHz SD dot clock.
- ❌ Chapters/PTT exactness (Phase 6, `VTS_PTT_SRPT`), UDF-only images, parental control,
  GPRM counter mode, dual-mono AC-3 (acmod 0, rejected deliberately).
- ❌ Trick play (continuous 2×/4×): needs a flush-free I-frame splice (`docs/dvd_nav.md` §2d).
- ⚠ Compute-bound stutter on high-motion content (worse on PAL 576): the decoder ceiling,
  not pacing. Rides on the deferred motion-comp/IDCT rewrite.

`docs/roadmap.md` is the canonical "what's next".

---

## Cross-cutting lessons (apply to every change)

Each of these cost at least one hardware round. The story is in `docs/status_log.md`.

- **A new RTL input floats Z in every bench that doesn't connect it**, and `!=` against X
  passes silently. Sweep the tie-offs and score with `!==`. **A new `dvd/*.sv` is invisible
  to Quartus and to `tools/lint_undriven.sh` until `DVD.qsf` names it.**
- **`dvd/emu.sv` has no bench.** Any seam between modules there is gated by a
  `tools/check_*_wiring.py` that reads the connection out of the file. `strip_comments()` is
  mandatory, because comments quote the pre-fix code. A module bench is handed the value and
  cannot see a wrong wire.
- **Quartus 17 can miscompile silently:** `N'(expr)` size casts and recently added
  `function`s. When sim says correct and silicon says broken, A/B against an older build of
  our own. After any edit near a memory's write sites, grep `DVD.map.rpt` for its
  "Inferred altsyncram" line.
- **Benches:** `$fatal`, not `$finish` (vvp exits 0 otherwise); runners require the PASS
  marker; assert against the *consumer's* contract, not the producer's belief; every claim
  gets a mutation that must fail *exactly* its own arm.
- **An instrument derived from its subject reports health when the subject is absent.**
  Prefer counters that can say "nothing real happened".
- **A disc field is a claim an authoring tool wrote, not a measurement**
  (`progressive_frame`, IFO channel counts, declared tables). Measure the bitstream, and
  sweep the library (`$DVD_ISO_DIR`) before sizing or scoping, including every VTS/PGC and
  not just the default one.
- **`user_io_poll()` is the core's data pump.** Blocking I/O there is a video artefact.
  Never raise `InfoMessage` while `mgl_get()->done == 0`.
- **One-cycle pulses ANDed with a level that settles later never fire.** Latch the event.
- **Derive a predicate from what it selects, not from the case it was written for**
  (`~keep_vbuf` vs a domain crossing; a menu context vs a menu domain).
- **HIL:** run the control arm (old build) first; ssh latency is part of the instrument;
  one behavioural change per flash; a build is not testable until its artefact is on the
  board. See `.claude/skills/hil-testing/`.
- **`watchdog_rst` is active-LOW** (high = healthy, a one-cycle low = expired). Check
  the polarity before concluding a decoder is hanging.
- **Stale premises in comments ship bugs.** When a feature changes what a mechanism
  guards, re-read the comments that justified the old behaviour.

---

## Architecture in brief

- **Video:** SD card sectors → `dvd/dvd_iso_reader.sv` (ISO/IFO nav, raw CD deblock, WAV) →
  `ps_stream_fifo` → `dvd/ps_demux.sv` (PS/PES, MPEG-1 packs, raw-ES passthrough) →
  upstream `rtl/mpeg2` decoder (fork-edited, marked `DVD-FORK`) → DDR3 via
  `dvd/mem_shim_burst.sv` → `resample_addrgen` / mixer → one raster that serves HDMI (via
  ascal) and the analog pins.
- **Audio:** `ps_demux` → reframers → `dvd/audio_ring.sv` (backpressure with a drain
  watchdog) → `dvd/dvd_audio_decode.sv` (AC-3, LPCM, MP2 in fabric) → `AUDIO_L/R`, or
  `iec61937_wrap` for passthrough. **There is no HPS audio daemon** (`hps/` is retired).
- **Clock:** a free-running 90 kHz STC (`dvd/disp_sched.sv`) off the same crystal as the
  raster and the audio NCO; video and audio are presented at their PTS.
- **HPS side:** the custom Main `MiSTer_DVDcss` (`main/`) provides physical discs, CSS
  (libdvdcss), CD-DA, `.cue`, read-ahead, telemetry and the support bundle. The core
  still plays decrypted `.iso`/`.VOB`/`.mpg`/`.bin`/`.wav` on stock Main.
- **HIL:** a real MiSTer is reachable. Use `.claude/skills/hil-testing/` rather than asking
  the maintainer to test (`docs/hil_harness.md`).
- **Bug reports:** sparse-sector nav bundles from `tools/dvd_report.py`, never payload. Its
  `audit()` must never be relaxed to accept VOB content (`docs/bug_reports.md`).
- **Test ISOs:** `$DVD_ISO_DIR` (decrypted rips); never hardcode a local path.

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

# Refactoring dvd/dvd_iso_reader.sv? Prove it bit-identical: baseline from a worktree of
# main, then compare (traces every kept port of all 41 reader benches; docs/logic_reclaim.md §8)
bench/dvd/run_reader_regress.sh --baseline <dir-from-a-main-worktree-run>

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

**★ Builds name themselves (`--name` is now optional).** A dev build's name defaults to
the `dev-<slug>` in `` `CORE_VERSION `` — `dev-seekrealign` gives
`releases/DVD_seekrealign_<date>_<time>.rbf` — so the OSD line, the `.rbf` and the zip all
name the same thing without anyone remembering a flag. (This replaces the old "always pass
`--name`" rule and the meaningless `DVD_ps_demux` default it existed to work around.) Pass
`--name` only to override.

The script always passes `-o bitstream_compression=on` and warns if the output
exceeds ~4 MB. Copy the resulting `releases/*.rbf` to the SD card to load it.

### Versioning and publishing releases

Two identifiers, deliberately at different granularities:

- **`` `CORE_VERSION `` in `dvd/emu.sv`** — shown in the OSD as
  `` `CORE_VERSION` `BUILD_DATE` `` (e.g. `v0.4.0 260910`). **★ THE INVARIANT (revised
  2026-09-04, by user decision):**

  > A bare semver lives in **exactly one commit per release** — the release commit. Any
  > build whose OSD shows `v0.4.0` came from that commit and no other.

  | Where | `` `CORE_VERSION `` | OSD line |
  |---|---|---|
  | feature branch | `dev-<slug>` | `DVD dev-seekrealign 260903` |
  | `main` between releases | whatever the last merge left — no reset | `DVD dev-seekrealign 260903` |
  | `main` after a release | the release semver — no reset | `DVD v0.4.0 260903` |
  | the release commit, only | `v0.4.0` | `DVD v0.4.0 260903` |

  **★ SET `dev-<slug>` AS THE FIRST COMMIT OF EVERY FEATURE BRANCH, named after the
  feature. This is mandatory, not conventional.** Nothing resets `` `CORE_VERSION `` any
  more — not after a merge, and not after a release (both resets retired 2026-09-08, by
  user decision) — so `main` carries whatever the last feature or release left, and setting
  the slug on the branch is the ONLY thing that keeps a build labelled correctly.
  It is also what UNBLOCKS the build: after a release `main` carries a bare semver, and
  `build_release.sh` **refuses** a bare semver on a dev build, so the first build on a
  branch that skipped this step fails immediately with a message naming the fix. That is
  the intended failure — fast and self-explanatory, rather than a build that quietly
  advertises a released version.
  `build_release.sh` **gates this mechanically** before the compile (so a wrong value costs
  a second, not 40 minutes): a bare semver on a dev build and a `dev-` string on a
  publishable `--release` build are both refused. It additionally WARNS when the slug does
  not resemble the branch name — the "left over from another branch" mistake.
  **⛔ This REPLACES the retired 2026-08-26 rule ("bump `` `CORE_VERSION `` to the
  speculated next semver at the start of every feature branch").** That rule made every
  pre-release test build advertise a version that did not exist yet: a build sent out for
  testing showed `v0.4.0`, testers and the sessions reading their reports called it 0.4.0,
  and the real 0.4.0 shipped far ahead of it. **Its stated payoff was illusory** — "the
  latest `.rbf` already matches the tag, avoiding a rebuild and re-sweep at release time"
  is only true if a release is cut from one branch's exact tree, and it never is: a release
  is cut from `main` after N branches merge, so the release build is a fresh netlist and a
  fresh seed decision regardless. Do not reinstate it.
  **Two hard limits on the string**, both measured against stock Main and both enforced by
  `build_release.sh`:
  - **≤ 18 characters.** `menu.cpp`'s About screen (`MENU_ABOUT2`) truncates the whole
    `"DVD <ver> <date>"` line at 30, and `"DVD "` + `" "` + `"260903"` already uses 12.
  - **No `,` `;` `"`.** `CONF_STR` delimits entries on `;`, and `user_io.cpp`'s `p[0]=='V'`
    arm calls `substrcpy(...,1)`, which splits on commas — either character **silently
    truncates** the version rather than failing.

  (The saved-settings `"v,N;"` config version is a SEPARATE, coarser counter — bump that
  one only on an incompatible `O[..]` relayout, see `docs/idle_screen.md`.)
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
  extend it with a time or a git SHA to separate same-day builds. Same-day dev builds are
  told apart by their `build_release.sh --name` filename (which carries `<date>_<time>`),
  and a second build sent to testers on one day appends a digit to the slug
  (`dev-seekrealign2`).
  ⚠ `BUILD_DATE` is generated **inside the Quartus container, in UTC**, while the `.rbf`
  filename comes from `date` wherever the pack ran. They agree when both run under
  `USE_DOCKER=1`; a native pack of a container-built `.sof` can straddle UTC midnight and
  disagree by a day. That is why the release workflow warns rather than fails on it.

**⚠ BOTH `` `CORE_VERSION `` AND `BUILD_DATE` ARE INSIDE `CONF_STR` = INSIDE THE NETLIST.**
Either one changing re-rolls `DVD.qsf`'s pinned fitter `SEED` — measured, not theoretical:
the ledger records `"0.1a"`→`"0.1b"` alone dropping SEED 8 below the hot-corner gate. So
`` `CORE_VERSION `` may change **once per branch** (free — the branch changes the netlist
anyway) and **never per commit**. Never derive either from a git SHA, a branch name read at
build time, or a timestamp: every compile would become a new netlist, and the seed ledger's
hand-written measurements would stop describing the thing that was built.

**Publishing** — see `.claude/skills/release/SKILL.md`. It is the single source of truth
for the tag format, the asset list and the draft→smoke-test→publish flow; this file
deliberately does not restate it, because the copy that used to live here went stale (it
still described the retired `v<version>-<yyyymmdd>` tag scheme long after v0.2.0 moved to
plain semver). In outline: build the core locally, `tools/publish_draft.sh v<semver>`
creates the draft and dispatches `.github/workflows/package.yml`, which validates the core
and attaches the Main + install zip; flash and smoke-test the draft; then publish.

### Sending a build to testers

Pre-release builds go out to testers directly (Discord); they are deliberately **not**
GitHub releases, so the releases page shows only real releases. Traceability comes from the
version string instead — two commands, no flags:

```bash
USE_DOCKER=1 ./build_release.sh --compile     # --name defaults to the dev-<slug>
USE_DOCKER=1 ./main/build_main.sh             # only if the Main also changed
./tools/package_release.sh                    # -> MiSTer_DVD_dev-<slug>_<date>.zip
```

The OSD line, the `.rbf` name and the zip name all carry the same slug and date, so a report
saying *"I'm on dev-seekrealign 260903"* names exactly one build:

| | |
|---|---|
| OSD | `DVD dev-seekrealign 260903` |
| `.rbf` (inside the zip, name unchanged for MiSTer's core browser) | `DVD_20260903.rbf` |
| zip | `MiSTer_DVD_dev-seekrealign_20260903.zip` |
| `dvd_report` bundle manifest | `core_version: "dev-seekrealign 260903"` |

Sending a **second** build from the same branch on the same day: append a digit to the slug
(`dev-seekrealign2`), or the two are indistinguishable in the OSD. The `.rbf.json` beside
each pack records the exact commit, seed and timing if a build ever needs identifying later.

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
- **Set `` `CORE_VERSION `` to `dev-<slug>` in that branch's FIRST commit** (`dvd/emu.sv`),
  named after the feature. Nothing resets it any more, so `main` carries the last feature's
  slug or the last release's semver — and after a release `build_release.sh` will REFUSE to
  build until the branch sets its own slug. Details and the reasoning: "Versioning and
  publishing releases".
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

**⛔ Do NOT open a follow-up commit or PR to reset `` `CORE_VERSION `` after a merge**
(rule retired 2026-09-08, by user decision — it used to say "reset it to `dev-main` on
`main`"). The post-release reset is retired too, so `main` simply keeps whatever the last
merged feature **or release** left there, and the next feature branch overwrites it with
its own `dev-<slug>` in its first commit — which is now mandatory, see "Versioning and
publishing releases".
Accepted consequence: a dev build cut from `main` between features advertises the
last-merged slug while containing more than that feature — which is why a build for testing
should come from a named feature branch, not from `main`. The release invariant is
unaffected: a bare semver still lives in exactly one commit per release, and
`build_release.sh` still refuses a `dev-` string on a `--release` build.

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
