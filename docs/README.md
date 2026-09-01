# Engineering design notes

**These are not user documentation.** They are the development record of the core: the
reasoning behind non-trivial design decisions, the hardware bring-up histories, the
measurements behind each choice, and the theories that turned out to be wrong.

📖 **The user manual is at <https://owenb321.github.io/MiSTer_DVD/>** — install, controls,
every OSD setting, output modes, formats, troubleshooting. Its source is in `site/content/`.

If you are trying to *use* the core, go there. Nothing in this directory is written for
that purpose, and following a design note as though it were instructions will mislead you —
several describe approaches that were tried and abandoned.

## What this is for

These notes exist so that work can resume cold. They record *why*, not *what* — the code
says what it does; these say what else was tried, what the hardware actually measured, and
which assumptions turned out to be false. Entry points:

| File | Covers |
|---|---|
| `architecture.md` | System data flow, the FPGA/ARM split |
| `roadmap.md` | Phased plan and current status — the canonical "what's next" |
| `dvd_nav.md`, `dvd_vm.md` | In-fabric ISO/IFO navigation and the DVD virtual machine |
| `fabric_audio.md`, `ac3_decoder_architecture.md` | Audio decode in fabric |
| `av_sync.md`, `lipsync_pickup.md` | A/V sync design and the drift investigation |
| `analog_dual_raster.md`, `crt_anamorphic.md` | Analog CRT output |
| `conformance.md` | DVD-Video specification coverage |
| `history.md` | Condensed record of solved problems |

## Two caveats when reading these

This core was developed in a private repository before being published, and the public
history begins with an upstream import plus the accumulated work rather than the full
commit-by-commit trail. So:

- References written **`fj#NN`** (and `issue fj#NN`) are **pre-migration** pull requests
  and issues. They have no equivalent here. They carry that prefix precisely so they can
  never be confused with this repository's own `#NN`, which start from 1.
- **Commit SHAs quoted in these notes** refer to that earlier history and will not resolve
  in this repository.

Neither affects the design rationale these notes exist to record, which is the part worth
reading.

## If you are editing them

A `docs/` note that contains genuinely user-facing material has it in the wrong place —
**harvest those sentences into `site/content/`**, and keep the engineering context here.
See [`site/README.md`](../site/README.md) for the manual's authoring rules.
