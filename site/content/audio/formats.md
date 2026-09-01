# Audio formats and decoding

Audio is decoded **entirely in FPGA fabric**. There is no HPS-side decoder — the
same as the video path.

| Format | Decoded in core | Passthrough | Notes |
|---|:--:|:--:|---|
| **AC-3 (Dolby Digital)** | yes | yes | Every channel mode from 1.0 mono to 5.1, downmixed to stereo |
| **MPEG-1 Layer II (MP2)** | yes | no | Rare on DVD, universal on Video CD. 48/44.1/32 kHz |
| **LPCM** | yes | no | 48 kHz stereo. 20/24-bit tracks play, truncated to 16-bit |
| **DTS** | **no** | yes | Passthrough to a receiver only |

By default the core decodes to stereo and sends it over HDMI, which works on any display.
For multichannel you want [bitstream passthrough](passthrough.md) to an AV receiver.

## AC-3

All channel modes are supported and downmixed to stereo for the HDMI output: mono (1.0),
stereo (2.0), and the multichannel modes up to 5.1.

!!! note "One deliberate exception"
    AC-3 **1+1 dual mono** (`acmod 0`) carries two *independent* programmes rather than one
    two-channel programme, so there is no correct way to mix them together. It is refused
    and plays silent. In a survey of 491 discs this appeared on 4 frames of 1 disc.

If a track plays silent and shows `AUDIO UNSUPPORTED`, cycle to another with **B7**.

## MP2

MPEG-1 Layer II, at 32, 44.1 and 48 kHz.

It is a DVD-legal audio format and was used on some early PAL-region discs, but it is
**rare in practice** — a census of 124 discs in the development library found AC-3 on every
single one and MPEG audio on none. It is included because the DVD specification permits it
and a disc carrying it should not be silent, not because you are likely to meet one.

On **Video CD and SVCD** it is the opposite: MP2 is the only audio format those use, so
every VCD depends on it.

!!! warning "MP2 has no passthrough encoding"
    In `Passthru` mode an MP2 track is **silent on both outputs**. Use `Decode PCM` for MP2
    content.

The one gap is the MPEG-2 multichannel *extension* — a rare 5.1 variant. Its
backwards-compatible stereo core should play, but no disc carrying one was available to
verify, so such a track currently reports `AUDIO UNSUPPORTED`.

## LPCM

Uncompressed, so there is nothing to decode. **48 kHz stereo.**

DVD also permits 20-bit and 24-bit LPCM. Those tracks **play**, but the core takes the top
16 bits of each sample and discards the rest — the audio path out to HDMI is 16-bit, so the
extra resolution has nowhere to go.

!!! note "There is real fidelity loss on 20/24-bit tracks"
    Truncation, not rounding or dithering. On the sort of content that ships as high-bit-depth
    LPCM — concert recordings, audiophile music discs — this is the one place the core is
    audibly short of what the disc holds. A 16-bit LPCM track is unaffected and is exact.

**96 kHz and multichannel LPCM are not supported.** Multichannel is not a matter of effort:
the DE10-Nano wires a single audio data line to its HDMI transmitter, which carries two
channels, and the board routes no other pin for it. That is also why 5.1 has to leave as a
[compressed bitstream](passthrough.md) rather than as PCM.

## DTS

**There is no DTS decoder in the core.** A DTS track is silent in `Decode PCM` mode.

To hear DTS, switch `Audio Out` to [`Passthru`](passthrough.md) and send the bitstream to
an AV receiver. Most DTS discs also carry an AC-3 track — cycling audio with **B7** will
usually find one that decodes.

## Choosing a track

**B7** cycles audio tracks, showing a popup with the track number and the language the disc
declares — `AUDIO 2/4 FR`. The disc's own default is selected at start, influenced by the
**Player Language** setting, the way a set-top player's setup screen works.

A disc's tracks are mapped through its own numbering, which can be sparse, so the numbers
shown are the disc's rather than a simple count. See
[Controls](../playback/controls.md#during-playback).

!!! warning "Changing tracks inside a menu"
    Switching audio while a disc menu is open silences the menu's audio until you leave the
    menu. Menu audio otherwise plays normally on the default track.

## A/V sync

Audio is locked to the video presentation timeline — the core builds a system clock
referenced to what is actually on screen and paces audio against it, the way a real player
slaves its audio to the recovered clock.

**`A/V Offset`** (Debug page) trims the relationship, defaulting to **+100 ms**, which is
the measured null for NTSC film and also measures correctly on PAL. There should be no need
to change it. Note that it binds at start and re-start events only — a mid-title change
takes effect at the next seek or reload.

## Silence checklist

If a disc plays with no sound:

1. **`Audio` is On** and **`Audio Out` is `Decode PCM`** — Passthru is silent on a display
   that cannot decode bitstreams, and on LPCM and MP2 tracks.
2. **Try another track with B7** — the disc's default may be DTS, or a format the core
   cannot decode.
3. **`CSS ENCRYPTED` on screen** means audio is muted deliberately — see
   [What you need](../getting-started/what-you-need.md).

[Troubleshooting](../reference/troubleshooting.md) covers these in more detail.
