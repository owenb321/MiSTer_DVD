# Building from source

## The core

Requires **Quartus 17.0.2 exactly** — newer versions break MiSTer project compatibility.
Either a native install or the pinned Docker image:

```bash
./build_release.sh --compile              # native Quartus
USE_DOCKER=1 ./build_release.sh --compile # pinned container
```

The Docker path needs no local Quartus install — it re-executes inside
`raetro/quartus:mister` (Quartus 17.0.2 Build 602 Lite), bind-mounting the repository and
running as your own user so build artifacts stay yours.

!!! danger "Always use `build_release.sh`, never `quartus_cpf` directly"
    MiSTer's FPGA loader needs a **compressed** `.rbf`, about 4.3 MB. A plain
    `quartus_cpf` produces an uncompressed one of about 7 MB that **silently fails to
    configure the FPGA** — the core appears to load but produces no video on any output,
    which looks like a completely different class of bug. The script always passes the
    compression flag and warns if the output looks too large.

Builds name themselves after the `dev-<slug>` in `CORE_VERSION` (`dvd/emu.sv`), with a date
and time suffix added automatically, so they can be told apart on the SD card **and** match
the version line the OSD shows. `--name` overrides it.

A development build's version is the feature it came from, never a version number — the OSD
reads `DVD dev-seekrealign 260903`. A bare semver appears in exactly one commit per release,
so a build advertising `v0.4.0` can only have come from the v0.4.0 release commit.
`build_release.sh` refuses to build if the two are mixed up.

## Simulation

Module testbenches run under Icarus Verilog:

```bash
iverilog -g2012 -o bench/dvd/ps_demux_sim dvd/ps_demux.sv bench/dvd/ps_demux_tb.sv
vvp bench/dvd/ps_demux_sim
```

There are suite runners for the larger subsystems — `bench/dvd/run_mp2.sh`,
`run_vcd.sh`, `run_mem_shim.sh`, `run_dpad_seek.sh`, `run_hdmi_bitstream.sh`,
`run_film_evidence.sh` among others.

## The physical-disc Main

`MiSTer_DVDcss` is a separate ARM binary — stock Main_MiSTer plus the small overlay under
`main/` — and is not part of the FPGA bitstream. It also supports a pinned Docker
toolchain, so no local ARM toolchain install is needed:

```bash
USE_DOCKER=1 ./main/build_main.sh   # pinned ARM-toolchain image, built on first use
./main/build_main.sh                # native — needs a MiSTer ARM toolchain on PATH
```

The result is `main/.build/MiSTer_DVDcss`. The script fetches stock Main_MiSTer at a pinned
commit, copies the `main/` overlay in, patches `user_io.cpp` and the Makefile, and
cross-compiles. The overlay and its integration points are documented in
[`main/README.md`](https://github.com/owenb321/MiSTer_DVD/blob/main/main/README.md).

## Packaging a release

Once you have a `.rbf` (`build_release.sh --release`) and `MiSTer_DVDcss`:

```bash
./tools/package_release.sh          # -> releases/MiSTer_DVD_v<version>.zip
```

It assembles the core, the Main and both `Scripts/` tools into a ready-to-extract zip and
prints the individual files to attach to a GitHub release alongside it.

## Timing

This baseline does not formally close timing. Large negative slack appears on Altera
PLL-reconfiguration and HPS-bridge paths — these are infrastructure paths every MiSTer core
reports, shared with known-working builds, and are not the functional video datapath.
Validate empirically rather than by chasing TimeQuest to zero.

`build_release.sh --release` does enforce a real gate on the decoder clock and refuses to
pack a timing-marginal netlist.

## Documentation

The manual you are reading is in `site/content/`, built with MkDocs Material:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r site/requirements.txt
mkdocs serve                        # http://127.0.0.1:8000
mkdocs build --strict               # what CI runs
python3 tools/docs_check.py         # OSD options <-> manual parity
```

`docs/` is something different — the engineering design notes recording *why* the RTL is
the way it is. See
[`site/README.md`](https://github.com/owenb321/MiSTer_DVD/blob/main/site/README.md) for the
authoring rules.

## Licensing

The project as a whole is **GPL-3.0-or-later** — see
[LICENSE](https://github.com/owenb321/MiSTer_DVD/blob/main/LICENSE), with the component
breakdown in [NOTICE](https://github.com/owenb321/MiSTer_DVD/blob/main/NOTICE).

| Component | Licence |
|---|---|
| `sys/` — MiSTer framework | GPL, mixed "v2 or later" and "v3 or later" |
| `rtl/` — MPEG-2 decoder, © 2007 Koen De Vleeschauwer | **BSD** ([mpeg2fpga](https://opencores.org/projects/mpeg2fpga)) |
| `dvd/`, `bench/dvd/`, `tools/`, `docs/`, `site/` | Original to this project — GPL-3.0-or-later |

**The MPEG-2 patents have expired.** `rtl/LICENSE-MPEG2` is a patent notice retained from
upstream, and its warning about needing an MPEG LA licence is now stale — the last US
patent in that portfolio expired in February 2018 and the programme was wound down. AC-3's
patents ran out in 2017, and MPEG-1/MP2's earlier still.
