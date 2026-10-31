# Audio formats and decoding

Audio is decoded **entirely in FPGA fabric**. There is no HPS-side decoder — the
same as the video path.

| Format | Decoded in core | Passthrough | Notes |
|---|:--:|:--:|---|
| **AC-3 (Dolby Digital)** | yes | yes | Every channel mode from 1.0 mono to 5.1, downmixed to stereo; 1+1 dual mono as left/right |
| **MPEG-1 Layer II (MP2)** | yes | no | Rare on DVD, universal on Video CD. 48/44.1/32 kHz |
| **LPCM** | yes | no | Every DVD-Video form: 48 or 96 kHz, 16/20/24-bit, 1–8 channels. Multichannel is downmixed to stereo; output is 16-bit |
| **DTS** | yes | yes | The DTS core, up to 5.1, downmixed to stereo |
| **WAV (PCM file)** | yes | no | 16-bit stereo, 44.1/48 kHz — a plain audio file, not a disc |

By default the core decodes to stereo and sends it over HDMI, which works on any display.
For multichannel you want [bitstream passthrough](passthrough.md) to an AV receiver.

## AC-3

All channel modes are supported and downmixed to stereo for the HDMI output: mono (1.0),
stereo (2.0), and the multichannel modes up to 5.1.

**1+1 dual mono** carries two *independent* mono programmes rather than one stereo
programme, for example the same dialogue in two languages. The first plays on the left
and the second on the right, unmixed, so a listener can pick one with the TV's balance
control. It is rare. In a survey of 491 discs it appeared on 4 frames of 1 disc.

If a track plays silent and shows `AUDIO UNSUPPORTED`, cycle to another with **B7**.

## WAV files

A `.wav` file selected from `Load Video` plays as audio with the bouncing logo on screen —
see [Loading a movie](../getting-started/loading.md#playing-a-wav). WAV files are
narrower than disc LPCM: **16-bit stereo only, at 44.1 or 48 kHz**. Other shapes are refused with `UNSUPPORTED IMAGE` instead of being
played as noise, and compressed formats (MP3, FLAC, AAC) have no decoder in the core.

44.1 kHz content is converted to the framework's fixed 48 kHz output by sample repetition
— the pitch and duration are exact, but it is not a resampler. This is the same treatment
Video CD audio has always had.

In `Passthru` a `.wav` plays as ordinary PCM on both outputs, because that is what it is.
There is no bitstream to pass through, so the setting makes no difference to it.

## CD audio images (`.cue`)

A ripped audio CD selected by its `.cue` sheet plays on the same PCM path, with track
numbers and track skip like a disc in the drive — see
[Playing a `.cue`](../getting-started/loading.md#playing-a-cue). CD audio is always 16-bit
stereo at 44.1 kHz, so a sheet whose tracks are `.wav` files needs them in exactly that
format; MP3 and FLAC sheets are refused. It needs the `MiSTer_DVDcss` add-on.

## MP2

MPEG-1 Layer II, at 32, 44.1 and 48 kHz.

It is a DVD-legal audio format and was used on some early PAL-region discs. It is included because the DVD specification permits it.

On **Video CD and SVCD** it is the opposite: MP2 is the only audio format those use, so
every VCD depends on it.

!!! note "MP2 has no bitstream encoding, but it is not silent"
    There is no IEC 61937 bitstream format for MP2 in this core, so in `Passthru` an MP2
    track is **decoded and sent as ordinary PCM** instead — the same audio `Decode PCM`
    produces. Nothing to change, and a VCD needs no trip back to `Decode PCM`.
    (Before v0.5.0 it really was silent.)

The one gap is the MPEG-2 multichannel *extension* — a rare 5.1 variant. Its
backwards-compatible stereo core should play, but no disc carrying one was available to
verify, so such a track currently reports `AUDIO UNSUPPORTED`.

## LPCM

Uncompressed, so there is nothing to decode. Every form DVD-Video allows plays:

| | |
|---|---|
| Sample rate | 48 or 96 kHz |
| Word length | 16, 20 or 24 bit |
| Channels | 1 to 8 |

The disc's bit rate caps the combinations (no more than two channels at 96 kHz/24-bit, for
example), so the most demanding tracks are 96 kHz stereo and 48 kHz multichannel. Both are
rare. They mostly turn up on audiophile "96/24" music discs and on some concert discs.

**Multichannel LPCM is downmixed to stereo**, the same way Dolby Digital and DTS are: the
centre and surrounds are folded in at −3 dB and the LFE channel is left out. The board cannot
send more than two PCM channels out (see below), so stereo is what reaches the TV. A disc
does not label its LPCM channels, so the core assumes front left, front right, centre, LFE,
then the surrounds for 5.1, the order FFmpeg-based players such as mpv and Kodi assume. Not
every player agrees: VLC, for one, reads 5.1 LPCM in a different order.

**96 kHz LPCM** is converted to 48 kHz with a proper low-pass filter, which is also what most
set-top players do. If you have set `hdmi_audio_96k=1` in `MiSTer.ini`, the HDMI link runs at
96 kHz and a 96 kHz track plays at its own rate instead. The core reads that setting
directly, so there is nothing to change in its own menu.

**20-bit and 24-bit tracks** play, but the core takes the top 16 bits of each sample and
discards the rest. The audio path out to HDMI is 16-bit, so the extra resolution has nowhere
to go.

!!! note "There is real fidelity loss on 20/24-bit tracks"
    Truncation, not rounding or dithering. On the sort of content that ships as high-bit-depth
    LPCM — concert recordings, audiophile music discs — this is the one place the core is
    audibly short of what the disc holds. A 16-bit LPCM track is unaffected and is exact.

**Why the output is stereo:** the DE10-Nano wires a single audio data line to its HDMI
transmitter, which carries two channels, and the board routes no other pin for it. Decoding
multichannel LPCM is not the problem; sending more than two PCM channels out is. That is also
why 5.1 has to leave as a [compressed bitstream](passthrough.md) rather than as PCM, and
LPCM, which has no bitstream form, always leaves as the stereo downmix.

A track whose header holds a value DVD-Video does not allow (a 44.1 or 32 kHz rate, or an
undefined word length) is muted and shows `AUDIO UNSUPPORTED`, rather than playing as noise.

## DTS

DTS tracks decode in the core and play as stereo in `Decode PCM`, like AC-3. Every channel
layout up to 5.1 is downmixed to stereo; the LFE channel is left out of the downmix, as
other stereo players do.

The core decodes the DTS **core** stream, which is what DVD-Video carries: 48 kHz, at
768 or 1536 kbit/s. Extensions layered on top of it — DTS-ES 6.1 and 96/24 among them —
are ignored, and the core underneath plays normally. Those extensions exist for a
receiver to use, so for full 5.1 or 6.1, switch `Audio Out` to
[`Passthru`](passthrough.md) and send the bitstream to an AV receiver.

A DTS frame the core cannot decode is skipped rather than played as noise.

## Choosing a track

**B7** first shows the current audio track in a popup, with the track number and the
language the disc declares — `AUDIO 2/4 FR`. Press it again while the popup is up to change
to the next track. The disc's own default is selected at start, influenced by the
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

**`A/V Offset`** (Audio page) trims the relationship, defaulting to **0 ms**. There should
be no need to change it. Note that it binds at start and re-start events only — a mid-title change
takes effect at the next seek or reload.

## Silence checklist

If a disc plays with no sound:

1. **`Audio` is On**, and if the track is Dolby Digital or DTS, **`Audio Out` is
   `Decode PCM`** unless you have a receiver — Passthru sends those two as a bitstream,
   which an ordinary television cannot decode. LPCM and MP2 come out as PCM in either
   mode, so they are never silenced by this setting.
2. **Try another track with B7** — the disc's default may be a format the core cannot
   decode.
3. **`CSS ENCRYPTED` on screen** means audio is muted deliberately — see
   [What you need](../getting-started/what-you-need.md).

If sound is present but simply too quiet, that is normal for DVD and is covered under
[Output level](#output-level) above.

[Troubleshooting](../reference/troubleshooting.md) covers these in more detail.
