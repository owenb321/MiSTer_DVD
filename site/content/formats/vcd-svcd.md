# Video CD and Super Video CD

VCD and SVCD rips play directly from the bin/cue rip — no conversion step. No CSS is ever
involved, so nothing beyond the bare `.rbf` is needed.

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
  directly.
- **No CD-DA audio tracks** — audio-only tracks on a mixed disc do not play.
- **No 2336-byte-sector images.** The common 2352-byte raw format is what is supported.
- **A 23.976-coded film VCD would play fast.** This is rare; almost all VCDs are 29.97 or
  25 fps.
- **The elapsed and total times are an estimate** *(unreleased; not in v0.3.0)* in linear playback modes, worked out
  from how fast the file is playing rather than read from a navigation structure. On a
  VCD it is exact; on a variable-bitrate file it can drift a little through the disc.
  Chapter numbers are still blank, since there are no chapters to count.
