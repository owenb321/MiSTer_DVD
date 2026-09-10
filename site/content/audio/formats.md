# Audio formats and decoding

Audio is decoded **entirely in FPGA fabric**. There is no HPS-side decoder — the
same as the video path.

| Format | Decoded in core | Passthrough | Notes |
|---|:--:|:--:|---|
| **AC-3 (Dolby Digital)** | yes | yes | Every channel mode from 1.0 mono to 5.1, downmixed to stereo |
| **MPEG-1 Layer II (MP2)** | yes | no | Rare on DVD, universal on Video CD. 48/44.1/32 kHz |
| **LPCM** | yes | no | 48 kHz stereo. 20/24-bit tracks play, truncated to 16-bit |
| **DTS** | **no** | yes | Passthrough to a receiver only — the one format with no fallback |

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

It is a DVD-legal audio format and was used on some early PAL-region discs. It is included because the DVD specification permits it.

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

## Output level

!!! info "Changed in v0.5.0 — Dolby Digital levels were wrong, and are corrected"
    Dolby Digital tracks were decoded **6 dB quieter than they should have been**
    on stereo and mono soundtracks. 5.1 soundtracks were slightly *loud* for a
    separate reason, and the two faults partly cancelled — which is why the
    problem showed up as "stereo sounds weak" rather than as an obvious fault.

    Both are fixed. After updating, expect **stereo and mono Dolby Digital to be
    noticeably louder**, and **5.1 to be a little quieter** (about 1.5 dB). All
    of them now match what a set-top DVD player or VLC produces from the same
    disc, so levels are consistent between tracks and between discs. LPCM and MP2
    were always correct and are unchanged.


DVD soundtracks are mastered a long way below full scale. Dialogue commonly sits 20 dB or
more beneath the peaks so that loud scenes have headroom, which is why a film disc sounds
quieter than a console core at the same TV volume — those emit chip audio near full scale
almost continuously. The core reproduces what the disc holds rather than turning it up.

MiSTer's **Core Volume** control (in the MiSTer OSD's system menu, not this core's own OSD)
can compensate. Press **right** past the top of the bar and it begins adding boost, displayed
as `+` then `++`. Each step is roughly +6 dB. It is a compressor rather than a plain gain:
quiet material comes up while peaks are curved to land just under full scale, so pushing it
does not clip. The level is stored per core, so setting it here does not affect anything else.

!!! info "Requirements"
    Boost requires **MiSTer Main 20260603 or newer** together with core support added in
    **v0.5.0**. On an older Main, or a core older than that, the boost steps do not appear
    and the control behaves as a plain attenuator.

Two limits worth knowing:

- **It does not apply in `Passthru`.** The core sends an untouched bitstream, so level is
  entirely your receiver's business — see [Bitstream passthrough](passthrough.md).
- **It is a playback control, not a repair.** It sits at the very end of the chain, after
  decoding and after the audio filter.

The same change also enables MiSTer's **audio filter** for this core, which had never been
advertised to the firmware and so never appeared.

## A/V sync

Audio is locked to the video presentation timeline — the core builds a system clock
referenced to what is actually on screen and paces audio against it, the way a real player
slaves its audio to the recovered clock.

**`A/V Offset`** (Debug page) trims the relationship, defaulting to **0 ms**. There should
be no need to change it. Note that it binds at start and re-start events only — a mid-title change
takes effect at the next seek or reload.

## Silence checklist

If a disc plays with no sound:

1. **`Audio` is On** and **`Audio Out` is `Decode PCM`** — Passthru is silent on a display
   that cannot decode bitstreams, and on LPCM and MP2 tracks.
2. **Try another track with B7** — the disc's default may be DTS, or a format the core
   cannot decode.
3. **`CSS ENCRYPTED` on screen** means audio is muted deliberately — see
   [What you need](../getting-started/what-you-need.md).

If sound is present but simply too quiet, that is normal for DVD and is covered under
[Output level](#output-level) above.

[Troubleshooting](../reference/troubleshooting.md) covers these in more detail.
