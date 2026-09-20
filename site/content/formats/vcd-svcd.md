# Video CD and Super Video CD

VCD and SVCD rips play directly from the bin/cue rip — no conversion step. No CSS is ever
involved, so nothing beyond the bare `.rbf` is needed.

A **physical VCD or SVCD disc** plays the same way straight from a USB optical drive — see
[Physical discs](physical-discs.md#video-cd-super-video-cd-from-the-drive). Everything on
this page (what to select does not apply there; everything else — playback, seeking, the
limitations below) is identical either way, since the disc and a `.bin` rip present the
core with the same bytes.

## Which file to select

Select the rip's **data-track `.bin`** from `Load Video` — usually the one labelled
**"Track 2"**. The small Track 1 is the ISO filesystem and does not contain the movie.

Also accepted:

- **Single-file whole-disc `.bin`** images
- Raw **`.img`** files
- Extracted **`.DAT`** files (the `MPEGAV/AVSEQ01.DAT` from a mounted VCD)

`.cue` sheets themselves are **not selectable** — they are text descriptions of the layout,
not the data. Pick the `.bin` the cue refers to.

## What happens

The core detects the raw CD sector format by content, strips the sector framing in fabric,
and demuxes the MPEG-1 (VCD) or MPEG-2 (SVCD) system stream inside. Audio plays at the
correct 44.1 kHz pitch, and seeking, pause and A/V sync all work.

SVCD's 480-wide picture fills the screen on both HDMI and the analog CRT output.

A **VCD is 352×240 (352×288 on PAL)**, so with the analog output running the core gives it a
[native 240p raster](../video/analog-crt.md#native-240p-for-vcds-and-mpeg-1) rather than
doubling every line to reach 480i. It happens automatically and there is nothing to set.

The [status line and seek bar](../playback/controls.md) follow the picture: because a VCD or
SVCD picture is narrower than a DVD's, they are drawn to fit it, with the text at its native
size rather than the double-height size a DVD gets. Everything they show is the same.

## Limitations

VCD support is deliberately basic playback, the reason being: **it came
almost free.** MPEG-1 video and MP2 audio are both DVD-Video-legal formats, so they were
implemented to meet the DVD specification rather than for VCDs. Once they existed, playing a
VCD needed only the CD sector deblocking and an MPEG-1 system-stream demux on top — so it
was added. Nothing beyond that was built:

- **No VCD menus or PBC** (playback control). The movie track plays; interactive VCD
  navigation is not implemented.
- **No segment stills.**
- **One `.bin` per movie track** — a multi-track rip needs the movie track selected
  directly. A physical disc plays its first data track only, the same limitation made
  once by the disc instead of by you.
- **No CD-DA audio tracks** — audio-only tracks on a mixed disc do not play.
- **No 2336-byte-sector images.** The common 2352-byte raw format is what is supported.
- **A 23.976-coded film VCD would play fast.** This is rare; almost all VCDs are 29.97 or
  25 fps.
- **The elapsed and total times are an estimate** in linear playback modes, worked out
  from how fast the file is playing rather than read from a navigation structure. On a
  VCD it is exact; on a variable-bitrate file it can drift a little through the disc.
  Chapter numbers are still blank, since there are no chapters to count.
