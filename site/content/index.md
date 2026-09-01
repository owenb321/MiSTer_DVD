# MiSTer DVD Player

A **DVD player core for the MiSTer FPGA platform** (DE10-Nano / Intel Cyclone V).

Put a decrypted DVD image on the SD card and it plays — with the disc's own menus, button
highlights, chapters, subtitles, and multi-channel audio. Everything runs in FPGA fabric:
there is no HPS-side daemon and no Linux helper process. The ARM only serves SD blocks
through the standard framework interface, exactly like any other core.

!!! warning "Status: pre-release alpha"
    Film and TV playback is the supported path and is exercised across a library of
    hundreds of commercial discs. Interactive DVD *games* are known-incomplete — see
    [Compatibility](reference/compatibility.md).

<!-- SCREENSHOT hero.png — the core playing a film with the transport HUD visible.
     Save to site/content/assets/img/hero.png. Replace this comment with:
     <figure markdown="span">
       ![The core playing a DVD, with the transport status line visible](assets/img/hero.png){ width="720" }
     </figure>
-->

## Start here

**New to the core?** [Install it](getting-started/install.md), then work out
[what you need](getting-started/what-you-need.md) for the discs you own.

**Already installed?** [Get a movie onto it](getting-started/discs-and-images.md) and
[load it](getting-started/loading.md).

**Something not working?** [Troubleshooting](reference/troubleshooting.md) covers the traps
people actually hit, and [On-screen messages](playback/on-screen-messages.md) decodes
anything the core tells you.

**Wondering if your disc will play?** [Compatibility](reference/compatibility.md) is the
honest list of what works and what does not.

## What works

**Video** — MPEG-2 decode at full rate, plus MPEG-1 (the DVD spec's other permitted video
format, 352×240 / 352×288). NTSC and PAL are auto-detected from the stream. Progressive
and native 480i/576i output, 3:2 pulldown handling for film, and PTS-driven A/V sync with
a display-refresh-locked frame-rate governor.

**DVD navigation** — the core reads an ISO directly, parses the IFOs, and runs a real
**DVD virtual machine** validated command-by-command against libdvdnav's behaviour. The
disc's authored menus work: First Play, root and title menus, PCI/HLI button highlights,
D-pad navigation following the authored link graph, subpictures, chapters via the PTT
tables, multi-angle, seamless-branch interleaved cells, still frames, and
audio/subtitle/angle/language selection. Transport is on the gamepad with an on-screen HUD
and seek bar.

**Audio** — AC-3 and MPEG-1 Layer II decoded entirely in fabric (every AC-3 channel mode,
downmixed to stereo) to HDMI; LPCM at 16/20/24-bit; AC-3 and DTS as
[IEC 61937 bitstream](audio/passthrough.md) to a receiver — over optical S/PDIF, or over
HDMI itself with the custom Main, so 5.1 needs no add-on board.

**Physical discs and encrypted ISOs** — with the optional
[`MiSTer_DVDcss`](formats/physical-discs.md) add-on, the core plays a **physical DVD**
straight from a USB optical drive, and **CSS-encrypted ISOs** directly, decrypting on the
fly with a user-supplied libdvdcss. No PC decrypt step. The bare `.rbf` plays decrypted
ISOs on its own; the add-on is opt-in and additive.

**Video CD / Super Video CD** — [bin/cue rips play directly](formats/vcd-svcd.md): select
the data-track `.bin` and the core strips the raw CD sectors in fabric, demuxes the MPEG-1
(VCD) or MPEG-2 (SVCD) stream, and plays it with correct 44.1 kHz audio pitch, seek and
pause.

**Analog / CRT** — two simultaneous rasters: the progressive one for HDMI, plus a native
15 kHz 480i/576i raster on the analog pins. It engages from `MiSTer.ini` alone, like any
other core. A [field-passthrough mode](video/analog-crt.md) hands the CRT the disc's
authored fields 1:1.

**Closed captions** — NTSC discs carry EIA-608 captions hidden in the MPEG-2 video stream,
separately from subtitles. The core extracts them and re-modulates them onto
[line 21 of the analog output](video/closed-captions.md), exactly as a real DVD player
does, so your television's own caption decoder displays them.

## How this was built

The RTL in this repository was written by an LLM working under human direction. The human
contribution was research, architecture direction, and hardware QA — reading the DVD-Video
specification and libdvdnav's source to establish correct behaviour, deciding what to build
and in what order, and then running each build on real hardware, finding what broke, and
narrowing it down to a root cause.

That last part is the bulk of the work: roughly 890 commits and 280 hardware builds since
development began in June 2026. The
[`docs/` directory](https://github.com/owenb321/MiSTer_DVD/tree/main/docs) records the
reasoning behind most non-trivial decisions, including the long diagnostic hunts (A/V
drift, film cadence, field-coded discs) where the root cause turned out to be several
layers away from the symptom.

This is stated up front because it is a fair thing for anyone evaluating the code to know.
It is not an endorsement of the approach — draw your own conclusions.
