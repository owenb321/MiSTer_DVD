# Physical discs and encrypted ISOs

Playing a **physical DVD** from a USB optical drive, or a **CSS-encrypted image** with no
PC decrypt step, uses two pieces alongside the core: a small custom MiSTer *Main* called
**`MiSTer_DVDcss`**, and **libdvdcss**. The
[install guide](../getting-started/install.md) covers setting both up in two short steps;
this page is the detail, plus the drive region tool.

Both feed decrypted sectors to the core over the same path a mounted image already uses, so
the FPGA side is unchanged — and a decrypted image still takes the fast direct path, so
having them installed costs nothing.

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

Most USB DVD drives ship with **no region set**. In that state the drive refuses the CSS key
exchange, so libdvdcss has to crack every key out of the disc data — that is the
several-second wait before a title starts, shown on screen as `No drive region: cracking`.
Set the drive's region to match your discs and it hands the keys over directly, so playback
starts almost immediately.

Some drives are **region-free** (the "RPC-1" drives, usually sold that way or reflashed to
be). Those need nothing: they answer for any disc whatever region it is from, which is the
best case. The script recognises one and tells you there is nothing to set.

An encrypted *image* is always cracked from the data, so this only affects physical discs.

!!! info "Unreleased"
    The region tool was substantially fixed in the development build. **In v0.3.0 the change
    is refused by some drives** — it sends the request in a form stricter drives reject — and
    when it does work the script can still report it as an error and close before you can
    read it. Everything below describes the fixed version; take the newer
    `set_dvd_region.sh` if you intend to set a region.

### Put a disc in the drive first

!!! warning "The disc in the drive usually has to allow the region you are setting"
    Many drives take their new region **from the disc in the tray**, the same way Windows
    offers to switch a drive when you insert a disc from elsewhere. On such a drive the
    change is refused outright unless a disc is loaded *and* that disc allows the region you
    asked for. Plenty of discs allow several regions at once, so this is usually easier than
    it sounds — but if nothing you own allows the region you want, that drive will not switch
    to it.

    Not every drive behaves this way. Some accept the change with an empty tray. The tool
    cannot tell which kind yours is in advance, so it warns rather than refusing.

**From the MiSTer:** run **set_dvd_region** from the **Scripts** menu (it is in the release
zip; otherwise grab the `set_dvd_region.sh` asset and drop it in `/media/fat/Scripts/`).
Setting a region is a menu you drive with the **D-pad and B1** — no keyboard needed. Nothing
changes until you confirm, and the cursor starts on *Cancel*.

The first screen tells you where you stand:

```
  DVD drive region                    /dev/sr0

  Current region : 1  (US, Canada)
  Changes left   : 3       (vendor resets: 4)
  RPC state      : 71 fe 01   (RPC-2, region set)
  Disc in drive  : regions 1-6,8
```

**`Disc in drive`** is the loaded disc's own region — `regions 1-6,8` above means that disc
allows every region except 7, so it would satisfy a switch to any of them. If you pick a
region the loaded disc bars, the confirm screen says so before you commit.

#### If the drive refuses

The tool prints what the drive actually said. The two common ones are about the disc, not
about the drive being broken:

| It says | What to do |
|---|---|
| `no disc in the drive` | Put in a disc that allows the region you want, and try again |
| `the disc in the drive is from a different region` | Swap it for one that allows that region — `Disc in drive` on the first screen tells you what the current one allows |
| `the drive will not accept another region change` | The drive is out of changes; nothing can be done |

Every screen waits for a button before it closes, and everything it prints is also written
to `DVD_reports/set_dvd_region.log` on the SD card (or `/tmp` if the SD card is not
writable) — so if something goes wrong you can read what happened afterwards, and paste it
into a bug report. The script names the file on its last line.

!!! danger "A region change is close to permanent"
    Drives allow only a handful of user changes — typically five — and when the counter runs
    out the region is **locked to whatever was set last**. The counter lives in the drive's
    own firmware, so it is not reset by a different PC, a reformat, or a different operating
    system. Pick the region matching the discs you own and set it once.

!!! success "Reading and setting are both confirmed on real hardware"
    Reading a drive's region has long been confirmed; **setting one now is too**, on two
    different drives. The first user to try it had it work on theirs but saw an error
    afterwards and reported it — thank you, because that report is what uncovered the rest.

    The script used to treat a drive that was slow to answer as a failure, and it closed
    before its last screen could be read. It now retries, says plainly whether it could
    confirm the new region, tells you what the drive actually said when it refuses, and
    **waits for a keypress before it closes**. It also sends the change in the form stricter
    drives require — some drives accept either form, some reject one of them.

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
