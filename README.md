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

**Video** — MPEG-2 decode at full rate, plus MPEG-1 (the DVD spec's other permitted
video format, 352×240/352×288); NTSC and PAL auto-detected from the stream; progressive
and native 480i/576i output; 3:2 pulldown handling for film; PTS-driven A/V sync with a
display-refresh-locked frame-rate governor.

**Video CD / Super Video CD** — bin/cue rips play directly: select the data-track
`.bin` and the core strips the raw CD sectors in fabric, demuxes the MPEG-1 (VCD) or
MPEG-2 (SVCD) system stream, and plays it with correct 44.1 kHz audio pitch, seek and
pause. SVCD's 480-wide picture fills both HDMI and the analog CRT output. No menus/PBC.

**Analog / CRT** — two simultaneous rasters: the progressive one for HDMI, plus a native
15 kHz 480i/576i raster on the analog pins. It engages from `MiSTer.ini` alone, like any
other core. A field-passthrough mode hands the CRT the disc's authored fields 1:1.

**Audio** — AC-3 and MPEG-1 Layer II (MP2) decoded entirely in fabric (AC-3 5.1
downmixed to stereo) to HDMI; LPCM at 16/20/24-bit; AC-3 and DTS as IEC 61937 bitstream
over S/PDIF to a receiver.

**DVD navigation** — the core reads an ISO directly, parses the IFOs, and runs a real
**DVD virtual machine** validated command-by-command against libdvdnav's behaviour. The
disc's authored menus work: First Play, root and title menus, PCI/HLI button highlights,
D-pad navigation following the authored link graph, subpictures, chapters via the PTT
tables, multi-angle, seamless-branch interleaved cells, still frames, and
audio/subtitle/angle/language selection. Transport is on the gamepad with an on-screen
HUD and seek bar.

## Known limitations

- **CSS is not handled in-core.** Rip to a *decrypted* ISO on a PC first — see
  [Getting started](#getting-started). The core detects an undecrypted rip, says
  `CSS ENCRYPTED` on screen, and mutes rather than emitting loud static.
- **ISO9660 only.** UDF-only images will not load; the core reports
  `UNSUPPORTED IMAGE`.
- **Only 720×480, 720×576 and the MPEG-1 SIF sizes (352×240, 352×288) are well
  tested.** Other DVD-compliant MPEG-2 resolutions (704×480, 352×480 half-D1) are
  accepted by the spec but have had little or no testing here.
- **Sub-720 content is scaled to fill the analog CRT output in-core** (MPEG-1 SIF
  gets a 2× line repeat + 352→720 stretch; SVCD 480-wide, DVD 704/544 sub-D1 and any
  other sub-720 width get the horizontal fill; engaged only while the analog output
  is active — HDMI keeps the framework scaler's cleaner upscale). A true 240p output
  raster is deliberately not offered: the core's A/V sync requires the raster to run
  at the exact content rate against the fixed audio clock, and no exact-rate 240p
  modeline exists at the 27 MHz dot clock — line-doubled 480i carries the same
  content to a CRT, which is what DVD players do.
- **VCD/SVCD is basic playback**: no VCD menus/PBC or segment stills, one `.bin` per
  movie track, no CD-DA audio tracks, no 2336-byte-sector images, and a (rare)
  23.976-coded film VCD would play fast — see `docs/vcd_svcd.md`.
- **Very demanding scenes may drop a frame.** The inherited decoder has a motion-comp /
  IDCT throughput ceiling, and on the heaviest content it can fall behind the display
  cadence. The frame-rate governor absorbs this by dropping a B-frame to stay in step —
  B-frames are never used as references, so the picture cannot be corrupted, and in
  practice this is not something you notice. PAL has less headroom because the frames are
  taller.
- **Interactive DVD games are incomplete.** Several game discs mis-navigate their
  dispatcher logic. Film and TV discs are the supported path.
- **No DTS decode** — S/PDIF passthrough to a receiver only.
- **Audio formats:** AC-3, MPEG-1 Layer II (MP2), LPCM, and DTS (passthrough only).
  The one gap left is the MPEG-2 multichannel *extension* (a rare 5.1 variant of MP2):
  its backwards-compatible stereo core should play, but no disc was available to verify,
  so such a track still reports `AUDIO UNSUPPORTED`. MP2 has no S/PDIF passthrough —
  in Passthru mode an MP2 track is silent.
- **Changing the audio track while a disc menu is open silences the menu audio** until
  you leave the menu. Menu audio otherwise plays normally on the default track.
- No parental-control enforcement, no UOP enforcement.
- PAL on an analog CRT is implemented but **unconfirmed** — no PAL CRT was available to
  test it.

## Getting started

### 1. Rip the disc

The core needs a **decrypted** DVD-Video image. Most commercial discs are CSS-encrypted,
so a plain `dd` or disc-image copy will not work — it produces a green-screening picture
with loud static. (The core detects this and shows `CSS ENCRYPTED` rather than letting it
through.)

Two known-good methods:

**`dvdbackup` (Linux)** — mirror the disc, decrypting as it reads, then wrap the result
as an ISO:

```bash
dvdbackup -M -i /dev/sr0 -o /path/to/work
genisoimage -dvd-video -o DISC.iso /path/to/work/DISC_LABEL
```

**MakeMKV (Windows / macOS / Linux)** — use its **Backup** mode, not title conversion.
It decrypts and writes an `.iso` directly, ready to use.

Either way the point is the same: keep the whole disc structure and decrypt during the
rip. A ripper that transcodes to a single title will lose the menus.

### 2. Load it

Put the `.iso` anywhere the MiSTer file browser can reach it and select it from the
core's `Load Video` entry. The core also accepts bare `.VOB`, `.mpg` and `.m2v` streams,
which it plays linearly without navigation.

**Video CDs and Super Video CDs play directly from the rip** — select the bin/cue
rip's **data-track `.bin`** (usually "Track 2"; the small Track 1 is the ISO
filesystem) from `Load Video`. The core detects the raw CD sectors by content, strips
them in fabric, and plays the contained MPEG-1 (VCD) or MPEG-2 (SVCD) stream with
correct 44.1 kHz audio pitch, A/V sync, seek and pause. Single-file whole-disc `.bin`
images and raw `.img`/extracted `.DAT` files work too; `.cue` sheets themselves are
not selectable (text). VCDs have no CSS, so no decryption step is ever needed.
Limitations: no VCD menus/PBC, one `.bin` per movie track, and audio-CD tracks don't
play — see `docs/vcd_svcd.md`. (`tools/vcd_to_vob.sh`, the previous PC-side
conversion route, still works but is no longer needed; `tools/make_mpeg1_test.sh`
transcodes any video file into a DVD-spec MPEG-1/MP2 `.vob`.)

DVD images are large, so **loading from a NAS share works and is often more practical
than filling the SD card**. One requirement catches people out:

> **The share must be mounted read-write.** The MiSTer framework opens disk images
> read-write (`O_RDWR|O_SYNC`) regardless of whether anything writes to them, so a
> read-only mount fails with `EACCES` and you get a black screen with the core sitting
> idle — no error message. The same file plays fine from the SD card, which makes it
> look like a size or filesystem problem. It isn't; re-mount the share read-write.

## Film (24p) content

Nearly all commercial film DVDs store 24 fps material and mark it for 3:2 pulldown
rather than storing 60 fields per second. This core handles that in two ways, and
`Film 24p Out` (Debug page, default **Auto**) picks between them.

**Default path** — the core performs the 3:2 pulldown itself, following the flags in
the stream, and outputs at the display's native 59.94 Hz (50 Hz for PAL).

**Film 24p path** — the core instead outputs a true **23.976 Hz progressive** raster
(25.000 Hz for PAL) and lets the framework scaler do the pulldown. Because 23.976:59.94
is exactly 2:5 and the clocks are locked, that conversion is exact. This also cuts
framebuffer re-reads from 60/s to 24/s, which hands the decoder a much larger
uninterrupted memory window each frame — so it helps throughput on demanding discs as
well as cadence.

Notes:

- **Auto** detects film from the stream's pulldown flags. **Hard-telecined** discs — where
  the pulldown was baked in at authoring time — carry no such flags, so Auto cannot see
  them. If a disc looks like film but Auto isn't engaging, set it to **On**.
- **`Frame Drop` must stay On.** The cadence-slip corrector, which keeps imperfect
  real-world telecine in step with the display, runs on the frame-drop governor's path
  and does nothing without it.
- **`A/V Offset` defaults to +100 ms**, which is the correct null for NTSC film and also
  measures correctly on PAL. There should be no need to change it.
- If the analog CRT raster is active, the film raster is suppressed — the re-interlacer
  needs the standard progressive raster to work from.

## Controls

| Button | Action | | Button | Action |
|---|---|---|---|---|
| B1 | Pause | | B8 | Subtitle (cycle) |
| B2 / Left | Previous chapter | | B9 | Display (toggle status line) |
| B3 / Right | Next chapter | | B10 | Fast forward (hold to scrub) |
| B4 | Select | | B11 | Rewind (hold to scrub) |
| B5 | Menu | | B12 | Title menu |
| B6 | Angle (cycle) | | B13 | Return (go up) |
| B7 | Audio (cycle) | | | |

A USB keyboard's number keys select menu buttons directly.

## Settings

Defaults are chosen to be correct for most users; the first value listed is the default.

### Main page

| Setting | Options | Notes |
|---|---|---|
| **Disc Menus** | **On** / Off | On boots the disc's authored First Play and runs its menus. Off skips navigation entirely and auto-plays the main feature — useful if a disc's menus misbehave. |
| **Aspect Ratio** | **Auto** / 4:3 / 16:9 | Auto reads the MPEG-2 sequence header. |
| **Audio** | **On** / Off | |
| **Audio Out** | **Decode HDMI** / Passthru SPDIF | Passthru sends undecoded AC-3/DTS to a receiver and mutes HDMI. Required for DTS. |
| **SPDIF Byte Order** | **Normal** / Swap | If the receiver names the format but plays static, toggle this. |
| **Player Language** | **English** / … | Sets the player's menu/audio/subtitle language preference, like a set-top player's setup screen. |
| **Video Standard** | **Auto** / NTSC / PAL | Auto detects from the stream's vertical size. |
| **Interlaced Out** | **Off** / Auto / On | Native 480i/576i to HDMI. Auto switches mid-title and still has a slight A/V skew — opt-in. |
| **480i Deint** | **Bob** / Weave | |
| **Analog Out** | **Auto** / Interlaced / Progressive / Native Fields | See below. |
| **Analog Aspect** | **Auto** / Fit / Letterbox / Crop | How anamorphic content fits a 4:3 analog TV. |

### Choosing an Analog Out mode

`Auto` follows `MiSTer.ini` and is right for most setups. The others are overrides:

| Your setup | Mode |
|---|---|
| CRT only, video-sourced content (TV, concerts) | **Native Fields** — smoothest motion |
| CRT only, film | Native Fields or Auto — little difference |
| CRT **and** HDMI at the same time | **Auto** or **Interlaced** |
| A 15 kHz RGBHV rig the ini bits can't identify | **Interlaced** |
| A display that wants 480p/576p on the analog pins | **Progressive** |

**Native Fields** gives the best CRT motion on true-interlaced content, but it puts the
whole core in field mode — so HDMI drops to 480i for the session and film content
regresses there. Set it *before* loading a disc. An explicit choice here always
overrides `MiSTer.ini` and persists across reloads.

### Debug page

`Frame Drop` (default **On**) should be left on — the film cadence corrector runs on
that path. The rest (`Debug Overlay`, `Title VTS`, `Audio Genlock`, `Force 4:3 Subpics`,
`Film 24p Out`, `A/V Offset`) are tuning and diagnostic levers; `A/V Offset` defaults to
+100 ms, which is the correct null for both NTSC film and PAL.

## On-screen messages

| Message | Meaning |
|---|---|
| `CSS ENCRYPTED` | The image is an undecrypted rip. Audio is muted; re-rip the disc. |
| `UNSUPPORTED IMAGE` | Not an ISO9660 DVD image (e.g. UDF-only), or not a playable stream. |
| `AUDIO UNSUPPORTED` | The selected audio track is in a format the core cannot decode. |
| `TITLE VTS nn` | Which title was auto-selected (shown only with Disc Menus Off). |

## Building from source

Requires **Quartus 17.0.2 exactly** — newer versions break MiSTer project compatibility.
Either a native install or the pinned Docker image:

```bash
./build_release.sh --compile --name DVD_myfeature              # native Quartus
USE_DOCKER=1 ./build_release.sh --compile --name DVD_myfeature # pinned container
```

Always use `build_release.sh` rather than calling `quartus_cpf` directly: MiSTer's
loader needs a *compressed* `.rbf` (~4.3 MB). An uncompressed one (~7 MB) silently fails
to configure — the core appears to load but produces no video on any output.

Module testbenches run under Icarus Verilog (`iverilog -g2012`); see `bench/dvd/`.

## Licensing

The project as a whole is **GPL-3.0-or-later** — see [LICENSE](LICENSE), with the
component breakdown in [NOTICE](NOTICE).

That falls out of what it is built from rather than being a preference:

| Component | Licence |
|---|---|
| `sys/` — MiSTer framework | GPL, mixed "v2 or later" and "v3 or later" |
| `rtl/` — MPEG-2 decoder, © 2007 Koen De Vleeschauwer | **BSD** ([`mpeg2fpga`](https://opencores.org/projects/mpeg2fpga)) |
| `dvd/`, `bench/dvd/`, `tools/`, `docs/` | Original to this project — GPL-3.0-or-later |

The `sys/` files that are "v2 or later" can be taken to v3, but the "v3 or later" ones
cannot go down to v2, so the combination resolves to GPLv3-or-later. BSD is
GPL-compatible, so `rtl/` folds in while remaining BSD in its own right; its copyright
headers must be retained.

> One wrinkle worth recording: the `rtl/` file headers as vendored carry only the BSD
> *warranty disclaimer* — the grant clauses are not reproduced in them, and no upstream
> distribution in the chain ships a LICENSE file. The licence is established by the
> author's own publication of `mpeg2fpga` on OpenCores, which states "License: BSD".

**Patents are separate.** `rtl/LICENSE-MPEG2` is a patent notice, not a copyright
licence. MPEG-2 is patent-encumbered and commercial use may require a licence from
MPEG LA. That is unaffected by the copyright position above.

## About this repository's history

This core was developed in a private repository before being published here, and the
public history begins with an upstream import plus the accumulated work rather than the
full commit-by-commit trail.

The `docs/` directory is the record of that development, and it is unusually detailed —
it documents the reasoning behind most non-trivial decisions, including the long
diagnostic hunts and the theories that turned out to be wrong. Two things follow from the
move:

- References written **`fj#NN`** (and `issue fj#NN`) are pre-migration pull requests and
  issues. They have no equivalent here. They are prefixed precisely so they can never be
  confused with this repository's own `#NN`, which start from 1.
- Commit SHAs quoted in `docs/` refer to that earlier history and will not resolve here.

Neither affects the design rationale the docs exist to record, which is the part worth
reading.

## Documentation

`docs/` holds the design notes. Useful entry points: `architecture.md` (system data
flow), `dvd_nav.md` and `dvd_vm.md` (navigation and the DVD virtual machine),
`fabric_audio.md` (audio), `av_sync.md` (A/V sync), `analog_dual_raster.md` (CRT
output), `roadmap.md` (what's next), `conformance.md` (DVD-spec coverage).

## Acknowledgements

This project is assembled on other people's work, and much of what looks like original
engineering here is really the result of having good references to check against. Listed
in full — not only where attribution is legally required, but everywhere something was
genuinely leaned on.

### Code this is built from

- **Koen De Vleeschauwer** — [`mpeg2fpga`](https://opencores.org/projects/mpeg2fpga)
  (2007), the hardware MPEG-2 decoder at the centre of this core. Nearly the entire
  video datapath is his.
- **mrchrisster** — [`MiSTer_MPEG2`](https://github.com/mrchrisster/MiSTer_MPEG2), the
  MiSTer port this forks: the framework integration, SD streaming, and DDR3 frame buffer
  that made a working starting point.
- **The MiSTer project** (`MiSTer-devel`) — the framework in `sys/`, `hps_io`, and the
  `ascal` scaler. The **N64 core** additionally supplied the interlaced sync model that
  the native 15 kHz CRT raster is built on, after a from-scratch approach failed to lock.

### Specifications

- **ATSC A/52** — *Digital Audio Compression (AC-3)*: normative frame syntax and the
  per-stage algorithms for the in-fabric decoder.
- **ISO/IEC 13818-1 and 13818-2** — MPEG-2 Systems (Program Stream, pack and PES
  headers) and MPEG-2 Video.
- **ISO/IEC 11172-2 and 11172-3** — MPEG-1 Video (the decoder's MPEG-1 mode) and MPEG-1
  Audio (the Layer II decoder's tables and algorithms).
- **IEC 61937-3 / 61937-5 / 60958-1** — AC-3 and DTS over S/PDIF, and the channel-status
  non-PCM flag that makes receivers lock onto a bitstream.
- ***DVD Demystified*, Jim Taylor** — the practical DVD-Video reference for VOB/IFO
  structure. Repeatedly the fastest route to understanding how discs are actually
  authored, as opposed to how the spec says they could be.
- **mpucoder's DVD documentation** — the long-standing public reference for DVD sector,
  NAV pack and IFO layout.

### Behavioural references and verification oracles

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
  II synthesis-window table (`tools/mp2_window.py`) is extracted from it, as vendored by
  **MiSTer-devel/CDi_MiSTer**, whose serial-MAC filterbank was the reference spec for the
  fabric MP2 decoder's architecture.
- **Han, Dapeng (2017)**, *FPGA Implementation of an AC3 Decoder*, MSc thesis,
  Linköping University — stage-by-stage pseudocode for exponent decode, bit allocation,
  mantissa and IMDCT.
- **libdvdcss** — not used in the core, but it is what makes the PC-side rip step work,
  and the reason a decrypted image can be produced at all.
- **The MiSTer CD cores** (PCE-CD, MegaCD, Saturn) — prior art for partitioning work
  between the ARM and the fabric, studied while designing the audio path.

### Test material

The DVD-Video discs used for hardware verification are commercial releases, ripped from
owned copies for testing. No disc content appears in this repository.
