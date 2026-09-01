# Physical discs and encrypted ISOs

Two optional pieces — a small custom MiSTer *Main* called **`MiSTer_DVDcss`**, and
**libdvdcss** — unlock playing physical DVDs from a USB optical drive, and playing
CSS-encrypted images directly without a PC decrypt step.

Read [What you need](../getting-started/what-you-need.md) first if you have not: it lays
out which of these you actually need for the discs you own. This page is the *how*.

Both feed decrypted sectors to the core over the same path a mounted image already uses, so
the FPGA side is unchanged. It is entirely optional and additive — without them, the core
plays decrypted images exactly as before.

## 1. Install the binary

If you extracted the release zip, `MiSTer_DVDcss` is already at your SD-card root — skip to
step 2. Otherwise download the `MiSTer_DVDcss` release asset and put it at:

```
/media/fat/MiSTer_DVDcss
```

!!! danger "Do not overwrite the stock `/media/fat/MiSTer`"
    Both files live side by side. `MiSTer_DVDcss` is an *additional* Main used only by this
    core, not a replacement for the one that boots your MiSTer.

## 2. Point the DVD core at it

Add this to `/media/fat/MiSTer.ini` — add the section, do not replace the file:

```ini
[DVD]
main=MiSTer_DVDcss
```

`main=` is a stock MiSTer feature: whenever the DVD core is loaded, MiSTer runs
`MiSTer_DVDcss` instead of the stock Main. Every other core is unaffected.

With that in place: open the core with a disc in the drive and it plays; insert a disc while
the core is open and it plays; eject to stop. Remove the `[DVD]` section, or the binary, and
the core reverts to image-only playback with the stock Main — nothing else changes.

## 3. libdvdcss

Most commercial discs — and raw image rips of them — are CSS-encrypted. Decrypting them
needs **libdvdcss**, which is **not part of MiSTer and is not shipped here**. It is loaded
at runtime from a copy you provide. Unencrypted discs and already-decrypted images need
nothing.

The release zip puts the installer in your MiSTer **Scripts** menu — run **install_dvdcss**
there. If you did not use the zip, download the `install_dvdcss.sh` asset and drop it in
`/media/fat/Scripts/`.

It fetches a prebuilt glibc/armhf `libdvdcss.so.2` and installs it to
`/media/fat/dvdcss/libdvdcss.so.2`. Override the download source with `DVDCSS_URL=...`, or
place a glibc/armhf `libdvdcss.so.2` there by hand.

If an encrypted disc or image is loaded without libdvdcss present, the core shows
[`CSS ENCRYPTED`](../playback/on-screen-messages.md) and mutes rather than playing static —
that is your cue to run the script.

### Key recovery and caching

The first time an encrypted disc's keys are needed they may take a few seconds to recover.
Recovered keys are cached under `/media/fat/dvdcss/cache`, so the same disc is instant next
time.

For a **physical disc**, how long that first recovery takes depends on whether the drive has
a region set — see below. For an **image**, keys are always cracked from the data, so the
region makes no difference; images also crack noticeably faster than physical discs, because
the process is seek-heavy and random reads from a file beat optical seek latency.

!!! note "Legal note"
    Cracking CSS may be regulated where you live; check the laws that apply to you. This
    project neither distributes libdvdcss nor contains any CSS circumvention code.

## Set the drive region

*Physical discs only — this makes them start faster.*

A USB DVD drive ships with **no region set**. In that state the drive refuses the CSS key
exchange, so libdvdcss has to crack every key out of the disc data — that is the
several-second wait before a title starts, shown on screen as `No drive region: cracking`.
Set the drive's region to match your discs and it hands the keys over directly, so playback
starts almost immediately.

An encrypted *image* is always cracked from the data, so this only affects physical discs.

**From the MiSTer:** run **set_dvd_region** from the **Scripts** menu (it is in the release
zip; otherwise grab the `set_dvd_region.sh` asset and drop it in `/media/fat/Scripts/`). It
shows the drive's current region and how many changes it has left. Setting one is a menu you
drive with the **D-pad and B1** — no keyboard needed. Nothing changes until you confirm, and
the cursor starts on *Cancel*.

Run it with no disc playing, since the core holds the drive open while one is mounted.

!!! danger "A region change is close to permanent"
    Drives allow only a handful of user changes — typically five — and when the counter runs
    out the region is **locked to whatever was set last**. The counter lives in the drive's
    own firmware, so it is not reset by a different PC, a reformat, or a different operating
    system. Pick the region matching the discs you own and set it once.

!!! warning "Reading is proven; setting is not"
    Identifying a drive's region and its remaining changes has been confirmed on real
    hardware, with one drive connected and with two. **Nobody has yet used the script to
    actually set a region** — it does the right thing in testing, but the write has never
    touched a real drive, because proving it costs one of a drive's permanent changes.

    Reading is safe to try freely. Setting is a step into the unknown. If you take it,
    please [open an issue](https://github.com/owenb321/MiSTer_DVD/issues) saying whether it
    worked — you will be the first, and thank you for it.

**Region codes:** **1** US/Canada · **2** Europe/Japan/Middle East/South Africa ·
**3** SE Asia · **4** Latin America/Australia/NZ · **5** Africa/Russia/South Asia ·
**6** China.

**On a PC instead:** the same setting is reachable there, and the region travels with the
drive, so a drive set on a PC arrives at the MiSTer ready.

- **Linux** — `sudo regionset /dev/sr0`, which prints the current region and remaining
  changes, then prompts.
- **Windows** — Device Manager → DVD/CD-ROM drives → the drive → Properties → DVD Region,
  which shows the remaining count before you commit.

!!! note "Region mismatch still cracks"
    A drive set to one region asked to play a disc from *another* falls back to cracking.
    Matching the drive to your library is what makes discs start quickly.

## Playing an encrypted image without a drive

This needs no optical drive attached to the MiSTer at all. Install `MiSTer_DVDcss` and
libdvdcss as above, then select the encrypted `.iso` from `Load Video` like any other image.
It is opened through libdvdcss and decrypted as it plays.

A decrypted image takes the fast direct-file path instead, so clean rips pay nothing for
having the add-ons installed.

!!! note
    A physical disc and an encrypted image are mutually exclusive — the last one mounted
    wins. This is not a limitation you are likely to notice in normal use.
