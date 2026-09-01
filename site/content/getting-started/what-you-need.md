# What you need

The core ships as three separate pieces, and which ones you need depends entirely on what
you want to play. This page is the map. Everything beyond the first column is **opt-in and
additive** — adding it never changes how anything already working behaves.

| | bare `.rbf` | `+ MiSTer_DVDcss` | `+ libdvdcss` |
|---|:--:|:--:|:--:|
| Decrypted DVD-Video ISO | &#10003; | &#10003; | &#10003; |
| Flat `.VOB` / `.mpg` / `.m2v` stream | &#10003; | &#10003; | &#10003; |
| Video CD / SVCD (bin/cue) | &#10003; | &#10003; | &#10003; |
| Disc menus, navigation, subtitles, chapters, angles | &#10003; | &#10003; | &#10003; |
| Audio decode + IEC 61937 passthrough | &#10003; | &#10003; | &#10003; |
| Analog/CRT output, closed captions, HUD, seeking | &#10003; | &#10003; | &#10003; |
| **Physical disc — unencrypted** | no | &#10003; | &#10003; |
| **Physical disc — CSS-encrypted** *(most commercial discs)* | no | no | &#10003; |
| **CSS-encrypted ISO** — *no optical drive needed* | no | no | &#10003; |
| Recovered-key caching (slow only on first play) | — | — | &#10003; |
| `set_dvd_region.sh` does anything useful | — | — | physical discs only |

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

## Three things worth knowing before you choose

!!! warning "`MiSTer_DVDcss` on its own is a stepping stone, not a destination"
    Nearly every commercial DVD is CSS-encrypted. Without libdvdcss, the custom Main plays
    only *unencrypted* discs — which in practice means home-burned discs and a handful of
    older releases. If your goal is playing the films on your shelf, you need all three
    pieces. Installing the Main alone and concluding the feature is broken is an easy and
    entirely understandable mistake.

!!! tip "An encrypted ISO needs libdvdcss but **no optical drive**"
    This is the non-obvious combination, and for most people it is the best path. A plain
    whole-disc rip of a CSS disc — no decryption at rip time, which is the fastest and
    simplest thing a ripper can do — plays directly. There is no PC decrypt step and no
    drive attached to the MiSTer at all. You still need `MiSTer_DVDcss` and libdvdcss,
    because that is where the decryption happens.

    The first play recovers the disc's keys, which takes a few seconds, and caches them
    under `/media/fat/dvdcss/cache` — so it is slow exactly once per disc. Cracking from a
    disk image is markedly faster than from a physical drive, because the process is
    seek-heavy and random reads from a file beat optical seek latency.

!!! info "What happens without libdvdcss"
    An encrypted disc or image shows **`CSS ENCRYPTED`** on screen and mutes the audio.
    Video keeps playing, so the disc is still identifiable — it does not green-screen with
    static, which is what a raw undecrypted rip would otherwise produce. Treat the message
    as a prompt to run the installer.

## Which should I install?

**Decrypted ISOs, VCD/SVCD, or bare video files** — the `.rbf` alone. Skip the rest of
this page.

**Films from your own shelf, ripped on a PC** — you can go either way. Decrypting *during*
the rip gives you an image that plays on the bare core with no key step ever; leaving it
encrypted needs all three pieces but makes ripping quicker and simpler.
[Discs and images](discs-and-images.md) walks through both.

**Playing the physical disc itself** — all three pieces, plus a USB optical drive. Also
consider [setting the drive's region](../formats/physical-discs.md#set-the-drive-region),
which is what makes discs start quickly rather than after a several-second key crack.

## Getting them installed

The release zip contains all three and puts each in the right place — see
[Install the core](install.md). Then [Physical discs and encrypted
ISOs](../formats/physical-discs.md) covers switching the optional pieces on: the two
`MiSTer.ini` lines, running the libdvdcss installer, and the drive region tool.

!!! note "Legal note"
    Cracking CSS may be regulated where you live; check the laws that apply to you. This
    project neither distributes libdvdcss nor contains any CSS circumvention code.
