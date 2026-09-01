# What you need

The core ships as three pieces, and the
[install guide](install.md) sets up all three. This page explains what each one does — so
that when something does not play, you can tell which piece is missing.

| | bare `.rbf` | `+ MiSTer_DVDcss` | `+ libdvdcss` |
|---|:--:|:--:|:--:|
| Decrypted DVD-Video ISO | ✓ | ✓ | ✓ |
| Flat `.VOB` / `.mpg` / `.m2v` stream | ✓ | ✓ | ✓ |
| Video CD / SVCD (bin/cue) | ✓ | ✓ | ✓ |
| Disc menus, navigation, subtitles, chapters, angles | ✓ | ✓ | ✓ |
| Audio decode to stereo (AC-3, MP2, LPCM) | ✓ | ✓ | ✓ |
| **Bitstream passthrough over optical S/PDIF** | ✓ | ✓ | ✓ |
| **Bitstream passthrough over HDMI** — *DD/DTS 5.1, no I/O board* | — | ✓ | ✓ |
| Analog/CRT output, closed captions, HUD, seeking | ✓ | ✓ | ✓ |
| **Physical disc — unencrypted** | — | ✓ | ✓ |
| **Physical disc — CSS-encrypted** *(most commercial discs)* | — | — | ✓ |
| **CSS-encrypted ISO** — *no optical drive needed* | — | — | ✓ |
| Recovered-key caching (slow only on first play) | — | — | ✓ |

## The three pieces

**The core (`DVD_YYYYMMDD.rbf`)** is the FPGA bitstream and does all the actual work —
decoding, navigation, menus, audio, video output. On its own it plays decrypted images of
every kind. Most people never need anything else.

**`MiSTer_DVDcss`** is a small custom MiSTer *Main* binary: stock Main_MiSTer plus an
overlay that can read a USB optical drive and open encrypted image files. It is not part
of the `.rbf`. You enable it per-core with two lines in `MiSTer.ini`, and removing those
lines reverts to the stock Main with nothing else changed.

**libdvdcss** is the library that actually decrypts CSS. It is **not shipped here** and is
not part of MiSTer — it is loaded at runtime from a copy you provide, which the bundled
`install_dvdcss` script fetches for you.

## Three things worth knowing

!!! warning "`MiSTer_DVDcss` without libdvdcss plays almost no commercial disc"
    Nearly every commercial DVD is CSS-encrypted. Stopping after the custom Main leaves you
    with only *unencrypted* discs — in practice, home-burned ones and a handful of older
    releases. If a disc mounts and then shows `CSS ENCRYPTED`, this is why: run
    **install_dvdcss** and it will play.

!!! tip "5.1 over HDMI needs `MiSTer_DVDcss` but **not** libdvdcss"
    The mirror image of the case above. IEC 61937 bitstream rides inside an ordinary
    2-channel/48 kHz stream, which is exactly what the DE10-Nano's single wired audio line
    to the HDMI transmitter carries — so **Dolby Digital and DTS 5.1 reach a receiver over
    HDMI with no Digital I/O board at all**.

    It needs the custom Main because the HDMI transmitter's configuration is only reachable
    from the ARM side: the core will not emit a bitstream over HDMI without an
    acknowledgement that only `MiSTer_DVDcss` sets, after checking the display's EDID. That
    is a safety interlock, not a licensing one — a bitstream sent to a sink still expecting
    PCM is full-scale noise.

    **Optical S/PDIF passthrough needs none of this** and works on the bare `.rbf`. See
    [Bitstream passthrough](../audio/passthrough.md).

!!! info "What happens without libdvdcss"
    An encrypted disc or image shows **`CSS ENCRYPTED`** on screen and mutes the audio.
    Video keeps playing, so the disc is still identifiable — it does not green-screen with
    static, which is what a raw undecrypted rip would otherwise produce. Treat the message
    as a prompt to run the installer.

## Getting them installed

**Install all three.** They come in one release zip, the extra steps take a minute, and
nothing is lost by having them — a decrypted image still takes the fast direct path, and
the custom Main is inert on every core except this one.

[Install the core](install.md) is the three-step guide.
[Physical discs and encrypted ISOs](../formats/physical-discs.md) covers the rest,
including the drive region tool.

The table above is here so you can work out what is wrong when something does not play —
not so you can decide what to leave out.

!!! tip "Upgrading later is just the zip"
    The `MiSTer.ini` section and libdvdcss are **one-time setup**. To update the core,
    extract the new release zip and that is all — your ini stays as it is, and libdvdcss
    (and any cached disc keys) are untouched.

!!! note "Legal note"
    Cracking CSS may be regulated where you live; check the laws that apply to you. This
    project neither distributes libdvdcss nor contains any CSS circumvention code.
