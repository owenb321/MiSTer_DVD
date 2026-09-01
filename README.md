# MiSTer DVD Player Core

A **DVD player core for the MiSTer FPGA platform** (DE10-Nano / Intel Cyclone V).

Put a decrypted DVD image on the SD card and it plays — with the disc's own menus,
button highlights, chapters, subtitles, and multi-channel audio. Everything runs in
FPGA fabric: there is no HPS-side daemon and no Linux helper process. The ARM only
serves SD blocks through the standard framework interface, exactly like any other core.

Built as a fork of [`mrchrisster/MiSTer_MPEG2`](https://github.com/mrchrisster/MiSTer_MPEG2),
itself a MiSTer port of **Koen De Vleeschauwer's `mpeg2fpga`** hardware MPEG-2 decoder
(2007). The video decode datapath is theirs and is largely unmodified; this project adds
everything needed to turn a decoder into a player.

> **Status: pre-release alpha.** Film and TV playback is the supported path and is
> exercised across a library of ~34 commercial discs. Interactive DVD *games* are
> known-incomplete — see [Known limitations](#known-limitations).


📖 **[Read the manual](https://owenb321.github.io/MiSTer_DVD)** — install, controls, every setting, CRT and
captions, physical discs, troubleshooting.

## How this was built

The RTL in this repository was written by an LLM working under human direction. The
human contribution was research, architecture direction, and hardware QA — reading the
DVD-Video specification and libdvdnav's source to establish correct behaviour, deciding
what to build and in what order, and then running each build on real hardware, finding
what broke, and narrowing it down to a root cause.

That last part is the bulk of the work: roughly 890 commits and 280 hardware builds since
development began in June 2026. The `docs/` directory records the reasoning behind most
non-trivial decisions, including the long diagnostic hunts (A/V drift, film cadence,
field-coded discs) where the root cause turned out to be several layers away from the
symptom.

This is stated up front because it is a fair thing for anyone evaluating the code to
know. It is not an endorsement of the approach — draw your own conclusions.

## What works

- **DVD-Video** from a decrypted `.iso` — the disc's own menus, First Play, button
  highlights, chapters, subtitles, multi-angle and still frames, driven by a real
  [DVD virtual machine](https://owenb321.github.io/MiSTer_DVD/reference/compatibility/#navigation)
  validated against libdvdnav.
- **Physical discs and CSS-encrypted images** with the optional
  [`MiSTer_DVDcss`](https://owenb321.github.io/MiSTer_DVD/formats/physical-discs/) add-on — no PC decrypt step, and
  encrypted images need no optical drive at all.
- **Video** — MPEG-2 and MPEG-1, NTSC and PAL auto-detected, progressive or native
  480i/576i, [3:2 pulldown for film](https://owenb321.github.io/MiSTer_DVD/video/film-24p/), PTS-driven A/V sync.
- **Audio** — AC-3 (every channel mode) and MP2 and LPCM decoded
  [entirely in fabric](https://owenb321.github.io/MiSTer_DVD/audio/formats/); AC-3 and DTS as
  [IEC 61937 bitstream](https://owenb321.github.io/MiSTer_DVD/audio/passthrough/) to a receiver — over optical S/PDIF,
  or over HDMI with the custom Main, so 5.1 needs no add-on board.
- **Analog / CRT** — a native 15 kHz 480i/576i raster alongside the progressive one, so
  [a CRT and HDMI work at once](https://owenb321.github.io/MiSTer_DVD/video/analog-crt/). Engages from `MiSTer.ini`
  like any other core.
- **[Closed captions](https://owenb321.github.io/MiSTer_DVD/video/closed-captions/)** re-modulated onto line 21 of the
  analog output for your television to decode, exactly as a real player does.
- **[Video CD / SVCD](https://owenb321.github.io/MiSTer_DVD/formats/vcd-svcd/)** — bin/cue rips play directly.

Everything runs in FPGA fabric: no HPS-side daemon, no Linux helper process. The ARM only
serves SD blocks through the standard framework interface.

## Known limitations

- **The bare `.rbf` plays decrypted images only.** Physical discs and CSS-encrypted images
  need `MiSTer_DVDcss` plus a user-supplied libdvdcss.
- **ISO9660 only** — UDF-only images report `UNSUPPORTED IMAGE`.
- **No DTS decode** — passthrough to a receiver only.
- **Bitstream passthrough over HDMI needs `MiSTer_DVDcss`**; over optical S/PDIF the
  bare `.rbf` is enough.
- **Closed captions are analog-only** and need a television that decodes them. Roughly
  1 disc in 6 carries any.
- **Interactive DVD games are incomplete.** Film and TV discs are the supported path.
- **PAL on an analog CRT is unconfirmed** — no PAL CRT was available to test it.

[Full list, with the reasoning →](https://owenb321.github.io/MiSTer_DVD/reference/compatibility/)

## Getting started

1. **Install** — download **`MiSTer_DVD_v<version>.zip`** from the
   [latest release](https://github.com/owenb321/MiSTer_DVD/releases/latest) and extract it
   to the root of your SD card (`/media/fat`).
2. **Add two lines** to `/media/fat/MiSTer.ini` (add the section, don't replace the file):

   ```ini
   [DVD]
   main=MiSTer_DVDcss
   ```

3. **Run `install_dvdcss`** once from the MiSTer Scripts menu — it fetches the library that
   decrypts CSS, which nearly every commercial DVD uses.

Then launch **DVD**, and load a disc or an image from `Load Video`.

Steps 2 and 3 are one-time — **updating later is just the new zip.**

> **If a network share gives you a black screen and no error, it is mounted read-only.**
> The framework opens images read-write regardless, so a read-only mount fails silently.

[Full installation guide →](https://owenb321.github.io/MiSTer_DVD/getting-started/install/)

## Documentation

- **[User manual](https://owenb321.github.io/MiSTer_DVD)** — everything above, properly. Source in [`site/content/`](site/content/).
- **[`docs/`](docs/)** — engineering design notes: the *why* behind the RTL, including the
  long diagnostic hunts and the theories that turned out wrong. **Not a manual.**
- Historical note: `fj#NN` references and quoted commit SHAs come from a pre-publication
  private repository and do not resolve here.

## Building from source

Requires **Quartus 17.0.2 exactly** — newer versions break MiSTer project compatibility.

```bash
./build_release.sh --compile --name DVD_myfeature              # native Quartus
USE_DOCKER=1 ./build_release.sh --compile --name DVD_myfeature # pinned container
```

Always use `build_release.sh` rather than `quartus_cpf` directly: MiSTer's loader needs a
*compressed* `.rbf` (~4.3 MB). An uncompressed one (~7 MB) silently fails to configure —
the core appears to load but produces no video on any output.

Module testbenches run under Icarus Verilog; see `bench/dvd/`.
[Full build docs, including `MiSTer_DVDcss` and packaging →](https://owenb321.github.io/MiSTer_DVD/about/building/)

## Licensing

The project as a whole is **GPL-3.0-or-later** — see [LICENSE](LICENSE), with the
component breakdown in [NOTICE](NOTICE).

That falls out of what it is built from rather than being a preference:

| Component | Licence |
|---|---|
| `sys/` — MiSTer framework | GPL, mixed "v2 or later" and "v3 or later" |
| `rtl/` — MPEG-2 decoder, © 2007 Koen De Vleeschauwer | **BSD** ([`mpeg2fpga`](https://opencores.org/projects/mpeg2fpga)) |
| `dvd/`, `bench/dvd/`, `tools/`, `docs/`, `site/` | Original to this project — GPL-3.0-or-later |

The `sys/` files that are "v2 or later" can be taken to v3, but the "v3 or later" ones
cannot go down to v2, so the combination resolves to GPLv3-or-later. BSD is
GPL-compatible, so `rtl/` folds in while remaining BSD in its own right; its copyright
headers must be retained.

> One wrinkle worth recording: the `rtl/` file headers as vendored carry only the BSD
> *warranty disclaimer* — the grant clauses are not reproduced in them, and no upstream
> distribution in the chain ships a LICENSE file. The licence is established by the
> author's own publication of `mpeg2fpga` on OpenCores, which states "License: BSD".

**Patents are separate, and the MPEG-2 ones have expired.** `rtl/LICENSE-MPEG2` is a
patent notice, not a copyright licence, and it is retained from upstream unchanged. It
warns that commercial use may require a licence from MPEG LA — that warning is now
**stale**: the last US patent in MPEG LA's MPEG-2 portfolio expired in February 2018 and
the licensing programme was wound down, so there is no longer an MPEG-2 pool licence to
take. The other formats this core decodes are in the same position — the AC-3 (Dolby
Digital) patents ran out in 2017, and MPEG-1/MP2 earlier still. None of this is affected
by, and does not affect, the copyright position above.

## Acknowledgements

This core is built on **Koen De Vleeschauwer's** [`mpeg2fpga`](https://opencores.org/projects/mpeg2fpga)
MPEG-2 decoder (2007), ported to MiSTer by **mrchrisster** as
[`MiSTer_MPEG2`](https://github.com/mrchrisster/MiSTer_MPEG2), on the **MiSTer-devel**
framework. Much of what looks like original engineering here is the result of having good
references — libdvdnav, libdvdread, liba52 and others — to check against.

[Full credits, specs and verification oracles →](https://owenb321.github.io/MiSTer_DVD/about/acknowledgements/)
