# MiSTer DVD Player

This is a DVD player for the MiSTer. Put a DVD image on the SD card and it plays the way a
set-top player would: the disc's own menus, chapters, subtitles and surround sound, on an
HDMI TV or a CRT.

All the decoding happens in the FPGA. The MiSTer's Linux side only reads the disc for it,
as it would for any other core. Add the optional [`MiSTer_DVDcss`](formats/physical-discs.md) Main and it also plays
encrypted images and real discs from a USB drive, and sends surround sound to a receiver
over HDMI.

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
and native 480i/576i output, 3:2 pulldown handling for film,
[Weave, Bob or Blend](video/interlaced.md#deinterlace) for video-sourced material, and
[Standard Convert](video/film-24p.md#standard-convert) to play a PAL disc on a 60 Hz-only
display. Picture, sound,
subtitles and captions are all presented against one clock, so lip sync holds across
seeks, menus and mode changes.

**DVD navigation** — the core reads an ISO directly, parses the IFOs, and runs a real
**DVD virtual machine** validated command-by-command against libdvdnav's behaviour. The
disc's authored menus work: First Play, root and title menus, PCI/HLI button highlights,
D-pad navigation following the authored link graph, subpictures, chapters via the PTT
tables, multi-angle, seamless-branch interleaved cells, still frames, and
audio/subtitle/angle/language selection. Transport runs from a gamepad, a USB keyboard or an
infrared remote, with an on-screen HUD and seek bar, chapter skip, fast forward and rewind
at up to 480×, frame step and A-B repeat — see [Controls](playback/controls.md).
[Save states](playback/save-states.md) keep a game disc's progress, or your place in a film.

**Audio** — AC-3, DTS and MPEG-1 Layer II decoded entirely in fabric (every AC-3 channel
mode and the DTS core up to 5.1, downmixed to stereo) to HDMI; LPCM in every DVD form, up to
96 kHz and 8 channels (downmixed); a [Night mode](playback/settings.md#dynamic-range) for
Dolby Digital; AC-3 and DTS as
[IEC 61937 bitstream](audio/passthrough.md) to a receiver — over optical S/PDIF, or over
HDMI itself with the custom Main, so 5.1 needs no add-on board. Tracks with no bitstream
format — LPCM and MP2 — still play as PCM in that mode.

**Physical discs and encrypted ISOs** — with the optional
[`MiSTer_DVDcss`](formats/physical-discs.md) add-on, the core plays a **physical DVD**
straight from a USB optical drive, and **CSS-encrypted ISOs** directly, decrypting on the
fly with a user-supplied libdvdcss. No PC decrypt step. The bare `.rbf` plays decrypted
ISOs on its own; the add-on is opt-in and additive.

**Video CD / Super Video CD** — [bin/cue rips play directly](formats/vcd-svcd.md): select
the `.cue` (or the data-track `.bin`) and the core strips the raw CD sectors in fabric,
demuxes the MPEG-1 (VCD) or MPEG-2 (SVCD) stream, and plays it with correct 44.1 kHz audio
pitch, seek and pause.

**Analog / CRT** — a native 15 kHz 480i/576i raster on the analog pins, built from the
disc's [authored fields](video/analog-crt.md), with broadcast-standard composite sync — the
presentation a set-top player feeds a TV. VCD and MPEG-1 SIF content gets a genuine
[240p/288p](video/analog-crt.md#native-240p-for-vcds-and-mpeg-1) raster of its own. It engages from `MiSTer.ini` alone, like any
other core.

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

That last part is the bulk of the work, and there has been a great deal of it since
development began in June 2026. The
[`docs/` directory](https://github.com/owenb321/MiSTer_DVD/tree/main/docs) records the
reasoning behind most non-trivial decisions, including the long diagnostic hunts (A/V
drift, film cadence, field-coded discs) where the root cause turned out to be several
layers away from the symptom.

This is stated up front because it is a fair thing for anyone evaluating the code to know.
It is not an endorsement of the approach — draw your own conclusions.
