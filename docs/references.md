# References & Resources

## AC-3 decoder (in-fabric, `dvd/ac3/*`)

The AC-3 decoder was ported from the now-archived `MiSTer_AC3` repo. See
`docs/ac3_decoder.md` (scope/verification/decisions) and
`docs/ac3_decoder_architecture.md` (module/interface/fixed-point).

- **ATSC A/52** — *Digital Audio Compression (AC-3, E-AC-3)*: normative frame syntax
  and every per-stage algorithm (any A/52 rev. is fine for plain AC-3).
- **Han, Dapeng (2017)** — *FPGA Implementation of an AC3 Decoder*, MSc thesis,
  Linköping University (`ac3_fpga.pdf`): stage-by-stage pseudocode for exponent /
  bit-alloc / mantissa / IMDCT. NB: uses a PicoBlaze soft core for control — the
  fabric decoder does **not** (strict full-fabric); use it for the algorithms only.
- **liba52 0.8.0** — canonical small AC-3 decoder, the **golden reference** for the
  cosim (pass = bounded error ±2 LSB @ s16). Public API gives final float PCM; for
  intermediate-stage goldens, rebuild liba52 with taps via `a52_internal.h`.
- **ffmpeg `ac3dec.c` / `ac3_fixed`** — second reference / bit-exact fixed-point
  cross-check; ffmpeg's AC-3 encoder (for test streams) emits **long blocks only**.

## Core Repositories

| Repo | URL | Notes |
|------|-----|-------|
| MiSTer_MPEG2 (upstream) | https://github.com/mrchrisster/MiSTer_MPEG2 | Fork this. Do not modify rtl/ or sys/ |
| Template_MiSTer | https://github.com/MiSTer-devel/Template_MiSTer | Reference for emu.sv structure, hps_io usage |
| MiSTer Main | https://github.com/MiSTer-devel/Main_MiSTer | HPS-side C framework |

## MiSTer Documentation

| Doc | URL | Notes |
|-----|-----|-------|
| hps_io reference | https://mister-devel.github.io/MkDocs_MiSTer/developer/hps_io/ | Block device interface, sd_* signals |
| Core paths | https://mister-devel.github.io/MkDocs_MiSTer/cores/paths/ | SD card / USB storage layout |
| Compiling cores | https://mister-devel.github.io/MkDocs_MiSTer/developer/mistercompile/ | Quartus 17.0.2 requirement |
| MiSTer forum DVD thread | https://misterfpga.org/viewtopic.php?t=2146 | Original DVD player discussion (may 404 — archived) |

## DVD / MPEG-2 Specifications

| Spec | Notes |
|------|-------|
| ISO 13818-2 | MPEG-2 Video standard. Partially available free online. |
| ISO 13818-1 | MPEG-2 Systems / Program Stream. Defines pack and PES headers. |
| IEC 61937-3 | AC-3 over S/PDIF. Defines burst-info Pc=0x0001, 1536-sample frame. |
| IEC 61937-5 | DTS over S/PDIF. Defines burst-info Pc=0x000B, 512-sample frame. |
| IEC 60958-1 | S/PDIF channel status. Bit 1 = non-PCM flag (critical for bitstream). |
| DVD Demystified | Book by Jim Taylor. Best practical reference for VOB/IFO structure. |

## Key Libraries (HPS C side)

### libdvdcss
- **URL:** https://www.videolan.org/developers/libdvdcss.html
- **API docs:** https://www.videolan.org/developers/libdvdcss/doc/html/dvdcss_8h.html
- **License:** LGPL
- **Purpose:** CSS decryption. Transparent — works on ISO files and physical drives.
- **Key calls:**
  - `dvdcss_open(path)` — open ISO or device
  - `dvdcss_seek(handle, sector, DVDCSS_SEEK_KEY)` — seek + authenticate
  - `dvdcss_read(handle, buf, blocks, DVDCSS_READ_DECRYPT)` — read + decrypt VOB
  - `dvdcss_read(handle, buf, blocks, DVDCSS_NOFLAGS)` — read IFO unencrypted
- **Note:** Set `DVDCSS_READ_DECRYPT` for VOB sectors, `DVDCSS_NOFLAGS` for IFO sectors.

### libdvdread
- **URL:** https://www.videolan.org/developers/libdvdnav.html
- **License:** LGPL
- **Purpose:** UDF filesystem parsing + IFO file parsing. Built on top of libdvdcss.
- **Recommended:** Use instead of writing your own UDF parser (udf.c / ifo_parse.c).
- **Key headers:** `<dvdread/dvd_reader.h>`, `<dvdread/ifo_read.h>`

### libdvdnav (stretch goal — for menu support)
- **URL:** https://www.videolan.org/developers/libdvdnav.html
- **License:** LGPL
- **Purpose:** Full DVD navigation including menus, chapter selection, angle switching.
- Skip for v1, consider for post-launch.

### liba52 (AC-3 decode)
- **URL:** http://liba52.sourceforge.net/
- **Also:** https://github.com/dtschump/liba52
- **License:** LGPL
- **Purpose:** AC-3 / Dolby Digital audio decode to PCM.
- **Key calls:** `a52_init()`, `a52_syncinfo()`, `a52_frame()`, `a52_block()`, `a52_samples()`
- **Output:** 6 blocks × 256 samples per AC-3 frame = 1536 samples total.

### libdca (DTS decode)
- **URL:** https://www.videolan.org/developers/libdca.html
- **License:** LGPL
- **Purpose:** DTS audio decode to PCM. Same role as liba52 for DTS.
- **Key calls:** `dca_init()`, `dca_syncinfo()`, `dca_frame()`, `dca_block()`, `dca_samples()`

## FPGA / RTL References

### mpeg2fpga (Koen De Vleeschauwer)
- **OpenCores:** https://opencores.org/projects/mpeg2fpga
- The MPEG-2 decoder engine that MiSTer_MPEG2 is built on.
- BSD licensed. Original 2007, ported to MiSTer by mrchrisster.
- Do not modify. Study it to understand the video input interface.

### MiSTer CD-i core (audio path reference)
- MiSTer CD-i handles VCD (MPEG-1 + MP2 audio) — useful reference for how
  another core wires up MPEG-based audio alongside the video decoder.
- https://github.com/MiSTer-devel/CDi_MiSTer (if available)

### MiSTer CD cores — HPS audio/disc handoff precedent
- Prior art for *this* core's "HPS decodes audio, FPGA mixes PCM" partition. The
  CD cores (PCE-CD, MegaCD, Saturn, …) decompress CHD/FLAC CD-DA on the ARM via
  libchdr and stream raw PCM sectors to the FPGA. Verified source walkthrough +
  the contrast with our DDR3 transport in [hps_handoff_cd_precedent.md](hps_handoff_cd_precedent.md).
- Key files (`MiSTer-devel/Main_MiSTer`): `lib/libchdr/libchdr_flac.c`,
  `support/chd/mister_chd.cpp`, `support/pcecd/pcecdd.cpp`, `support/pcecd/pcecd.cpp`.

## Tools

| Tool | Purpose |
|------|---------|
| Quartus 17.0.2 | FPGA synthesis and place-and-route. Mandatory version. |
| Icarus Verilog | SystemVerilog simulation. `iverilog -g2012` |
| Verilator | Faster simulation for large modules. Cannot simulate VHDL. |
| xxd | Hex dump VOB files for testbench input: `xxd VTS_01_1.VOB \| head -400` |
| dvdbackup | Rip DVD to ISO on Linux: `dvdbackup -M -i /dev/sr0 -o ~/` |
| makemkvcon | Rip DVD to ISO on Windows/Mac (GUI available) |
| USB Blaster | Quartus programmer for loading bitstreams to DE10-Nano |

## VS Code Extensions

| Extension ID | Purpose |
|-------------|---------|
| `mshr-h.verilog` | SystemVerilog syntax highlighting + iverilog linting |
| `teros-technology.teroshdl` | FSM diagrams, schematic viewer, module hierarchy |
| `ms-vscode.cpptools` | C/C++ for HPS code (liba52, libdvdcss integration) |
| `eamodio.gitlens` | Track changes vs upstream fork |
| `ms-vscode.hexeditor` | Inline hex viewer for VOB debugging |

## Community

| Resource | URL |
|----------|-----|
| MiSTer FPGA Forum | https://misterfpga.org |
| MiSTer Discord | Active development community |
| DVD thread (forum) | https://misterfpga.org/viewtopic.php?t=2146 |
| RetroRGB MiSTer info | https://retrorgb.com/mister.html |

## Key Forum Insights (from t=2146 thread)

- DVD uses **AC-3 (Dolby Digital)** as primary audio — NOT MPEG-1 Layer 2 like VCD/CD-i.
  Don't reuse the CD-i audio path for DVD.
- The CD-i core handles VCD (MPEG-1 + MP2) — good reference for audio routing but
  different codec.
- The MPEG-2 core could eventually benefit Saturn, CD32, and other cores with
  FMV/MPEG accessories — keep modules clean and reusable.
- The Nuon question was raised in the same thread. Consensus: Nuon would require
  implementing 4× custom VLIW CPU cores (Aries 3 chip) — completely separate project,
  years of expert work. DVD core first, Nuon possibly built on top.

## Nuon (for future reference)

Nuon is **not** a current target, but it shares the DVD video pipeline.
- **Chip:** Aries 3 — 4× VLIW MPE cores @ 108MHz, 5 function units each
- **Games:** Only ~7 Western releases. Notable: Tempest 3000 (Jeff Minter).
- **Only emulator:** Nuance (software, incomplete accuracy)
- **FPGA complexity:** Extremely high. No existing soft-core for Aries ISA.
- **Strategy if attempted:** Build DVD video pipeline first (identical to Nuon's),
  then add the 4× MPE VLIW cores on top.
- **Feasibility on DE10-Nano:** Unknown — Aries 3 is an exotic multi-core VLIW
  architecture with no FPGA precedent. Resource-wise it would be extremely tight.
