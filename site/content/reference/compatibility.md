# Compatibility

What plays, what does not, and what is untested. Current as of **v0.9.0**.

## Formats

| | Status |
|---|---|
| **DVD-Video, ISO9660 image** | Full support — menus, navigation, chapters, subtitles, angles |
| **DVD-Video, physical disc** | Full support, with [`MiSTer_DVDcss`](../formats/physical-discs.md) |
| **DVD-Video, CSS-encrypted** | Full support, with `MiSTer_DVDcss` + libdvdcss |
| **UDF-only image** | **Not supported** — reports `UNSUPPORTED IMAGE` |
| **Video CD / SVCD** | [Basic playback](../formats/vcd-svcd.md) — no menus/PBC; image or [physical disc](../formats/physical-discs.md#video-cd-super-video-cd-from-the-drive) |
| **`.VOB` / `.mpg` / `.m2v`** | Linear playback, no navigation |
| **`.wav` audio file** | 16-bit stereo PCM at 44.1/48 kHz only — audio, no picture |
| **Audio CD (physical)** | Plays with track skip and a progress bar, needs [`MiSTer_DVDcss`](../formats/physical-discs.md#audio-cds) |
| **Audio CD image (`.cue` + `.bin` or `.wav`)** | Plays exactly as the physical disc does, needs `MiSTer_DVDcss` — see [Playing a `.cue`](../getting-started/loading.md#playing-a-cue). `.wav` tracks must be 16-bit stereo 44.1 kHz; MP3/FLAC sheets are refused |
| **VCD/SVCD image via `.cue`** | Same playback as the `.bin`, without having to pick the track; also plays `MODE2/2336` rips. Needs `MiSTer_DVDcss` |
| **CHD images** | **Not supported** |

!!! note "ISO9660 only"
    Practically every DVD-Video image is ISO9660 (usually with a UDF structure alongside
    it, which is fine). A **UDF-only** image will not load. If your ripper offers the
    choice, take the default.

## Video

| | Status |
|---|---|
| MPEG-2, 720×480 (NTSC) and 720×576 (PAL) | Well tested — the main path |
| MPEG-1 SIF, 352×240 and 352×288 | Well tested |
| SVCD, 480 wide | Well tested |
| Other DVD-legal sizes — 704×480, 352×480 half-D1 | Accepted, **little or no testing** |
| NTSC / PAL detection | Automatic from the stream |
| Progressive and native 480i/576i output | Supported |
| Native 240p / 288p for VCD and MPEG-1 SIF | Supported, automatic on the analog raster |
| PAL 576i on an analog CRT | Confirmed working on real PAL sets |
| 3:2 pulldown / film cadence | [Supported](../video/film-24p.md), automatic |

**Sub-720 content is scaled to fill the analog output** in fabric — SVCD, sub-D1 DVD
(704, 544) and any other sub-720 width get a horizontal stretch. **SIF-height content
(352×240 / 352×288) instead gets a native 240p/288p raster** when the analog output is
running, so it is sent at its own height with no line doubling at all — on a CRT that is
the usual console-style 240p, and over HDMI the framework scaler receives the original
frame rather than a doubled one.
See [Analog and CRT output](../video/analog-crt.md#native-240p-for-vcds-and-mpeg-1).

**Busy video keeps up on both Video Output settings.** Earlier builds dropped a frame or
two a second in the busiest concert and TV discs on **Progressive** output, because the
display's memory reads competed with the decoder. The display now reads about a third as
much per line, and every disc measured keeps up on Progressive and on Interlaced,
including its busiest scenes. The one exception is by design: **Film 24p Out = On** with
29.97 fps video (see [Troubleshooting](troubleshooting.md#video-skips-frames)).

**Colours use the standard-definition (BT.601) conversion**, the one DVD-Video specifies.
Most discs do not label their colour encoding. Earlier builds converted those discs with
the high-definition (BT.709) formula, which tinted skin slightly green and put subtitles
in a different colour space from the picture. Video that does carry a colour label, such
as an `.mpg` encoded for BT.709, is converted the way its label says.

## Audio

Covered in full on [Audio formats](../audio/formats.md). In short: AC-3 (all channel modes)
and DTS (its core stream, up to 5.1, to stereo) and MP2 and LPCM decode in the core; DTS
extensions (DTS-ES, 96/24) reach a receiver only through Passthru; AC-3 1+1 dual mono plays
its two programmes on the left and right; the MPEG-2 multichannel MP2 extension is
unverified.

**WAV files** play through the same PCM path (16-bit stereo, 44.1/48 kHz); unsupported
shapes are refused rather than played as noise, and they play as PCM on both outputs
whichever way `Audio Out` is set.

**LPCM** plays in every form DVD-Video allows: 48 or 96 kHz, 16/20/24-bit, 1 to 8
channels. Two limits are worth knowing. The output is **stereo**: multichannel LPCM is
downmixed, because the board wires a single two-channel audio line to the HDMI transmitter
(which is also why 5.1 must leave as a compressed bitstream). It is also **16-bit**: 20/24-bit
tracks are truncated, so there is real fidelity loss on high-bit-depth music discs. 96 kHz
is filtered down to 48 kHz unless `hdmi_audio_96k=1` runs the HDMI link at 96 kHz.

## Navigation

Working: First Play, root and title menus, PCI/HLI button highlights, D-pad navigation
following the authored link graph, subpictures, chapters via the PTT tables, multi-angle,
seamless-branch interleaved cells, still frames, and audio/subtitle/angle/language
selection. Discs that pick the camera angle themselves — typically to show a title card
or credits in your chosen language — are followed rather than overridden.

A disc's own checks get honest answers about the player:

- **Region.** The core reports a region the disc allows, so a disc from any region passes
  its own region check, rather than showing its "wrong region" screen.
- **TV shape.** Discs are told the shape of your TV from your output settings: whatever
  **Analog Aspect** describes on the interlaced analog output, and widescreen on
  Progressive and HDMI unless you set Analog Aspect to Letterbox or Crop there. Discs that carry
  both a 4:3 and a 16:9 copy of an intro or menu therefore play the 16:9 one on a
  widescreen setup.
- **Audio.** Discs are told which audio formats the core can actually play (Dolby Digital,
  MPEG audio, and DTS).
- **Where you are.** Discs are told the chapter and the part of the title that is playing,
  so a scene-selection or main menu opened mid-film can open on the chapter you were
  watching.

Discs authored without a First Play program start where other players start them: at the
first program of the disc's top-level menu.

**Damaged navigation files.** Every DVD carries a backup copy of each navigation file
(`.BUP`). When a disc's main copy can't be read, the core uses the backup, as set-top
players do. See [Troubleshooting](troubleshooting.md#a-scratched-disc-has-no-menus-or-chapters).

Not implemented: **parental-control enforcement** and **UOP enforcement** (the flags a disc
uses to forbid skipping something). In practice this means the core lets you skip things a
set-top player would not.

## Known limitations

**Interactive DVD games are incomplete.** Some game discs mis-navigate their dispatcher
logic, and individual minigames can misbehave. Film and TV discs are the supported path.

**Some discs offer no subtitles in an alternate viewing mode.** A few titles build a second
version of the film as its own program chain — The Matrix's "Follow the White Rabbit" is the
best-known — and that version can declare a different subpicture stream from the main one, or
none at all. Where the disc offers no subtitle stream for the mode you are in, the subtitle
button will not produce subtitles. This matches a set-top player.

!!! info "Changed in v0.5.0"
    Before this change the player would show such a stream anyway, using a colour palette
    that was never meant for it — the text came out as flat grey with no black outline and
    was very hard to read. It is now simply not shown.

**Audio played by the MiSTer's Linux side is not heard while this core is loaded.** The
framework path that mixes Linux-side audio (a background-music script, for example) into
a core's output is left out of this core to free logic for the player itself. Every
disc, file and audio CD the core plays is decoded in the FPGA, so nothing the player does
depends on it.

**Some discs are not laid out in the order you watch them.** A small number of discs —
ordinary films among them, not just box sets — store one part of the feature at the far end
of the disc from where it plays. Playback, chapter skip, seeking and the time readout are
all unaffected. The only sign is cosmetic: one chapter notch on the seek bar can sit at the
opposite end of the track from where that chapter falls in the film, because the bar shows
position on the *disc* rather than position in the *story*. A seek can also land slightly
earlier than the bar showed if the target falls in a gap between two parts.

!!! tip "A game disc that repeats the same question"
    Some game discs put their randomisation setup in the boot sequence, and pressing
    **Menu** to skip the intro jumps past it — so the game repeats one question. That is
    how the disc is authored; a real player and libdvdnav do the same thing. Let the intro
    play.

**Closed captions are analog-only** and need a television that decodes them — see
[Closed captions](../video/closed-captions.md). Roughly 1 disc in 6 carries them.

**Changing the audio track inside a disc menu** silences the menu's audio until you leave
the menu.

!!! info "Fixed after v0.6.1"
    **Some copy-protected physical discs could stall for a long time.** A few discs, such
    as the DVD in the *OZ: The Great and Powerful* Blu-ray combo pack, contain
    deliberately unreadable sectors that a real player never reads. With **Disc Menus**
    off the player could be sent into them, and the drive then spends about 30 seconds
    retrying each one while the MiSTer stops responding. **Ejecting the disc** recovers
    straight away. The player no longer reads those sectors. A decrypted image of the
    same disc was never affected.

## Reporting a disc that does not work

[Open an issue](https://github.com/owenb321/MiSTer_DVD/issues) with the core version from
the OSD, the disc title and region, what happens and where, and any
[on-screen message](../playback/on-screen-messages.md).

If the trouble is with **menus, titles or audio tracks**, you can also send the disc's
navigation tables as a sub-100 KB file, which makes the problem reproducible without the
disc — see [Reporting a bug](reporting-a-bug.md).

Interactive/game discs are known-incomplete, so those reports are useful but expected. A
**film or TV disc** that does not play properly is the more surprising case and worth
reporting in detail.
