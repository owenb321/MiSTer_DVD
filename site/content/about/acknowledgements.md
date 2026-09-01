# Acknowledgements

This project is assembled on other people's work, and much of what looks like original
engineering here is really the result of having good references to check against. Listed
in full — not only where attribution is legally required, but everywhere something was
genuinely leaned on.

## Code this is built from

- **Koen De Vleeschauwer** — [`mpeg2fpga`](https://opencores.org/projects/mpeg2fpga)
  (2007), the hardware MPEG-2 decoder at the centre of this core. Nearly the entire
  video datapath is his.
- **mrchrisster** — [`MiSTer_MPEG2`](https://github.com/mrchrisster/MiSTer_MPEG2), the
  MiSTer port this forks: the framework integration, SD streaming, and DDR3 frame buffer
  that made a working starting point.
- **The MiSTer project** (`MiSTer-devel`) — the framework in `sys/`, `hps_io`, and the
  `ascal` scaler. The **N64 core** additionally supplied the interlaced sync model that
  the native 15 kHz CRT raster is built on, after a from-scratch approach failed to lock.

## Design guidance

- **[Anime0t4ku](https://github.com/Anime0t4ku)** — the custom-MiSTer-Main approach for
  physical-disc cores (a core-specific `main=` binary that reads and serves the disc's own
  sectors). That guidance shaped `MiSTer_DVDcss` and is what unlocked physical-disc support
  here. The CSS and reader code is our own, developed independently.

## Specifications

- **ATSC A/52** — *Digital Audio Compression (AC-3)*: normative frame syntax and the
  per-stage algorithms for the in-fabric decoder.
- **ISO/IEC 13818-1 and 13818-2** — MPEG-2 Systems (Program Stream, pack and PES
  headers) and MPEG-2 Video.
- **ISO/IEC 11172-2 and 11172-3** — MPEG-1 Video (the decoder's MPEG-1 mode) and MPEG-1
  Audio (the Layer II decoder's tables and algorithms).
- **IEC 61937-3 / 61937-5 / 60958-1** — AC-3 and DTS over S/PDIF and HDMI, and the
  channel-status non-PCM flag that makes receivers lock onto a bitstream.
- ***DVD Demystified*, Jim Taylor** — the practical DVD-Video reference for VOB/IFO
  structure. Repeatedly the fastest route to understanding how discs are actually
  authored, as opposed to how the spec says they could be.
- **mpucoder's DVD documentation** — the long-standing public reference for DVD sector,
  NAV pack and IFO layout.

## Behavioural references and verification oracles

Much of this core was built by checking its behaviour against known-good implementations
rather than by reading specs alone.

- **libdvdnav** — the reference the DVD virtual machine was validated against
  command-by-command (`decoder.c`, `vmcmd.c`). Where this core and libdvdnav disagreed,
  libdvdnav was usually right; where it wasn't, the disagreement itself was informative.
- **libdvdread** — `ifo_types.h` and `nav_types.h` were the authority for every IFO and
  NAV pack offset the in-fabric parsers use.
- **liba52 0.8.0** — the golden reference for the AC-3 decoder's co-simulation. Every
  coding tool is checked against it to a bounded error, and it caught bugs
  (a mis-decoded dynamic-range exponent among them) that listening tests did not.
- **ffmpeg** (`ac3dec.c`, `ac3_fixed`) — second opinion and fixed-point cross-check for
  AC-3, and the float reference the MP2 golden model is gated against.
- **pl_mpeg** (Dominic Szablewski, MIT) — compact C reference for MPEG-1/MP2; the Layer
  II synthesis-window table (`tools/mp2_window.py` in the repository) is extracted from it, as vendored by
  **MiSTer-devel/CDi_MiSTer**, whose serial-MAC filterbank was the reference spec for the
  fabric MP2 decoder's architecture.
- **Han, Dapeng (2017)**, *FPGA Implementation of an AC3 Decoder*, MSc thesis,
  Linköping University — stage-by-stage pseudocode for exponent decode, bit allocation,
  mantissa and IMDCT.
- **libdvdcss** — not used in the core, but it is what makes the PC-side rip step work,
  and the reason a decrypted image can be produced at all.
- **The MiSTer CD cores** (PCE-CD, MegaCD, Saturn) — prior art for partitioning work
  between the ARM and the fabric, studied while designing the audio path.

## Test material

The DVD-Video discs used for hardware verification are commercial releases, ripped from
owned copies for testing. No disc content appears in this repository.
