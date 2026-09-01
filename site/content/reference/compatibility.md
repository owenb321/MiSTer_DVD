# Compatibility

What plays, what does not, and what is untested. Current as of **v0.3.0**.

## Formats

| | Status |
|---|---|
| **DVD-Video, ISO9660 image** | Full support — menus, navigation, chapters, subtitles, angles |
| **DVD-Video, physical disc** | Full support, with [`MiSTer_DVDcss`](../formats/physical-discs.md) |
| **DVD-Video, CSS-encrypted** | Full support, with `MiSTer_DVDcss` + libdvdcss |
| **UDF-only image** | **Not supported** — reports `UNSUPPORTED IMAGE` |
| **Video CD / SVCD** | [Basic playback](../formats/vcd-svcd.md) — no menus/PBC |
| **`.VOB` / `.mpg` / `.m2v`** | Linear playback, no navigation |

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
| 3:2 pulldown / film cadence | [Supported](../video/film-24p.md), automatic |

**Sub-720 content is scaled to fill the analog output** in fabric — SIF gets a 2× line
repeat plus a 352→720 stretch; SVCD, sub-D1 DVD (704, 544) and any other sub-720 width get
the horizontal fill. HDMI is unaffected and keeps the framework scaler's cleaner upscale.
See [Analog and CRT output](../video/analog-crt.md#sub-720-content-on-a-crt).

## Audio

Covered in full on [Audio formats](../audio/formats.md). In short: AC-3 (all channel modes)
and MP2 and LPCM decode in the core; **DTS is passthrough-only**; AC-3 1+1 dual mono is
deliberately refused; the MPEG-2 multichannel MP2 extension is unverified.

## Navigation

Working: First Play, root and title menus, PCI/HLI button highlights, D-pad navigation
following the authored link graph, subpictures, chapters via the PTT tables, multi-angle,
seamless-branch interleaved cells, still frames, and audio/subtitle/angle/language
selection.

Not implemented: **parental-control enforcement** and **UOP enforcement** (the flags a disc
uses to forbid skipping something). In practice this means the core lets you skip things a
set-top player would not.

## Known limitations

**Interactive DVD games are incomplete.** Some game discs mis-navigate their dispatcher
logic, and individual minigames can misbehave. Film and TV discs are the supported path.

!!! success "One large class of this was fixed in 0.2.1"
    Many discs — interactive ones especially — build menus so that every button sends the
    same instruction, and a small hidden program on the disc decides where you actually go
    based on *which* button you pressed. The core did not run that program, so every option
    led to the same place, or the menu showed `LINK FAIL` and went nowhere.

    Six discs in a 505-disc library went from failing at startup to reaching their menus
    normally, four of which nobody had ever reported. If you tried a disc before 0.2.1 and
    it misbehaved this way, it is worth trying again.

!!! tip "A game disc that repeats the same question"
    Some game discs put their randomisation setup in the boot sequence, and pressing
    **Menu** to skip the intro jumps past it — so the game repeats one question. That is
    how the disc is authored; a real player and libdvdnav do the same thing. Let the intro
    play.

**Very demanding scenes may drop a frame.** The inherited decoder has a motion-compensation
and IDCT throughput ceiling and can fall behind on the heaviest content. The frame-rate
governor drops a B-frame to stay in step. B-frames are never used as references, so the
picture cannot be corrupted, and in practice this is not something you notice. PAL has less
headroom because the frames are taller.

**Closed captions are analog-only** and need a television that decodes them — see
[Closed captions](../video/closed-captions.md). Roughly 1 disc in 6 carries them.

**PAL on an analog CRT is implemented but unconfirmed** — the 576i timings are derived by
analogy with the hardware-proven NTSC ones and no PAL CRT was available to test them. PAL
over HDMI is confirmed working.

**Changing the audio track inside a disc menu** silences the menu's audio until you leave
the menu.

**In Passthru, menus with no background audio drop to PCM** — the receiver may show
"decoder off" until the next menu with sound. Authored silence has no bitstream to carry;
the receiver re-acquires in under a second when audio returns.

## Reporting a disc that does not work

[Open an issue](https://github.com/owenb321/MiSTer_DVD/issues) with:

- The **core version** from the OSD — the `v0.3.0 260901` line
- The disc title and region
- What happens, and where — does it boot, reach a menu, start the feature?
- Any [on-screen message](../playback/on-screen-messages.md)
- Whether it is a physical disc, a decrypted image, or an encrypted image

Interactive/game discs are known-incomplete, so those reports are useful but expected. A
**film or TV disc** that does not play properly is the more surprising case and worth
reporting in detail.
