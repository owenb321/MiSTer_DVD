# Discs and images

There are three ways to get a film onto the core. Pick whichever suits what you own and
what you are willing to install.

## Physical DVD

With [`MiSTer_DVDcss` enabled](../formats/physical-discs.md) and a USB optical drive
attached, insert the disc and it plays. No rip, no PC, no preparation. CSS-encrypted discs
are decrypted on the fly.

This is the least setup per *disc* and the most setup once — you need all three pieces from
[What you need](what-you-need.md), plus a drive. Worth
[setting the drive's region](../formats/physical-discs.md#set-the-drive-region) so titles
start immediately rather than after a several-second key crack.

## DVD image (ISO)

Rip the disc to an image on a PC. Both encrypted and decrypted images play — the choice
affects how much you install, not what you can watch.

!!! warning "Keep the whole disc structure"
    A ripper set to extract a single title, or to transcode to MP4/MKV, throws away the
    menus, chapters, subtitle streams and angle data — everything this core exists to play
    back. Use a whole-disc mode.

### Decrypted (recommended)

Decrypt *during* the rip. The resulting image plays on the bare `.rbf` with no key step
ever, and loads fastest.

=== "MakeMKV"

    Windows, macOS and Linux. Use **Backup** mode — not title conversion — with
    "decrypt video files" enabled. It writes a ready-to-use image.

=== "dvdbackup (Linux)"

    ```bash
    dvdbackup -M -i /dev/sr0 -o /path/to/work
    genisoimage -dvd-video -o DISC.iso /path/to/work/DISC_LABEL
    ```

    `-M` is whole-disc mirror mode. The `genisoimage -dvd-video` step is what produces a
    correctly structured DVD-Video image from the extracted tree.

### Encrypted (raw whole-disc copy)

A plain sector-for-sector copy of a CSS disc works too, and is quicker and simpler to
produce — but it needs `MiSTer_DVDcss` **and** libdvdcss to play. There is no PC decrypt
step at all: the first play recovers the disc's keys and caches them under
`/media/fat/dvdcss/cache`, so only the first play of each disc is slow.

On the bare core an encrypted image shows [`CSS ENCRYPTED`](../playback/on-screen-messages.md)
and mutes rather than emitting static.

!!! tip "This path needs no optical drive on the MiSTer"
    Rip on a PC that has a drive, copy the image across, and play it. The MiSTer never
    needs a drive attached. See [What you need](what-you-need.md).

## Video CD / Super Video CD

No CSS is ever involved. Rip to bin/cue and select the **data-track `.bin`** — see
[Video CD / SVCD](../formats/vcd-svcd.md) for which track that is and what the format
supports.

## Bare video files

The core also accepts `.VOB`, `.mpg` and `.m2v` files directly, played linearly with no
navigation. Useful for testing and for clips you have already extracted.

## Where to keep them

DVD images are large, so **loading from a NAS share works and is often more practical than
filling the SD card**. USB storage works too. One requirement catches people out:

!!! danger "The share must be mounted read-write"
    The MiSTer framework opens disk images read-write (`O_RDWR|O_SYNC`) whether or not
    anything writes to them, so a read-only mount fails with `EACCES`. You get a **black
    screen with the core sitting idle and no error message**. The same file plays fine
    from the SD card, which makes it look like a size or filesystem problem. It is not —
    re-mount the share read-write.
