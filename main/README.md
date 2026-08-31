# MiSTer_DVDcss — custom Main for physical-disc + CSS playback

This directory builds **`MiSTer_DVDcss`**, an optional custom MiSTer *Main* binary that
lets the DVD core play **physical DVD-Video discs** (and, later, still-encrypted ISOs)
straight from the optical drive, decrypting CSS with a **user-supplied libdvdcss**.

It is **stock Main_MiSTer plus a small self-contained overlay** — it does not fork the
whole tree into this repo. `build_main.sh` fetches stock Main at a pinned commit, copies
the overlay in, patches `user_io.cpp`/`Makefile`, and builds the ARM binary.

## How it fits together

`main=` is a **stock** MiSTer feature (a core can name a custom Main binary in
`MiSTer.ini`). So this is purely opt-in and additive:

- **Do nothing** → stock Main runs the DVD core → decrypted-ISO playback works exactly
  as it does today. No regression.
- **Install `MiSTer_DVDcss` + set `[DVD] main=MiSTer_DVDcss`** → the core *also* plays
  physical discs and CSS-encrypted media. Plain decrypted ISOs still work through it too.
- **Also run [MiSTer Physical Disc](https://github.com/Anime0t4ku/Main_MiSTer_Physical_Disc)**
  → adds *auto-launching* the DVD core when you insert a disc from another core / the menu.
  That is the only thing the fork adds; playback itself needs only `MiSTer_DVDcss`.

Physical discs look exactly like a mounted ISO to the FPGA core: `MiSTer_DVDcss` serves
each 2048-byte sector CSS-decrypted over the generic `sd_*` block interface, so no RTL
change is needed. See [../docs/physical_disc.md](../docs/physical_disc.md) for the design.

## Build

```bash
# In Docker (no local toolchain needed) — like the Quartus USE_DOCKER build. The
# pinned image (main/docker/Dockerfile, gcc-arm 10.2 arm-none-linux-gnueabihf) is
# built automatically on first use:
USE_DOCKER=1 ./build_main.sh

# Or natively — put your MiSTer ARM toolchain on PATH (or set CROSS_COMPILE=):
./build_main.sh

# Either way, reuse an existing stock checkout instead of cloning:
MAIN_MISTER_SRC=/path/to/Main_MiSTer ./build_main.sh
```

The result is `main/.build/MiSTer_DVDcss`. The stock base commit is pinned in
`build_main.sh` (`MAIN_MISTER_REF`); the `user_io.cpp`/`Makefile` edits are applied by
`integration/apply_integration.py` and documented in
[integration/INTEGRATION.md](integration/INTEGRATION.md). A stock bump that moves an
anchor makes the patcher fail loudly, naming the step to fix.

## Install

1. Copy `MiSTer_DVDcss` to the SD-card root: `/media/fat/MiSTer_DVDcss`
   (**do not** overwrite stock `/media/fat/MiSTer`).
2. Add to `/media/fat/MiSTer.ini` (add, don't replace):
   ```
   [DVD]
   main=MiSTer_DVDcss
   ```
3. Open the DVD core with a disc in the drive — it plays. Insert a disc while the core is
   open and it plays. Eject to stop.

## libdvdcss (encrypted discs)

Most commercial DVDs use CSS encryption. **libdvdcss is not part of MiSTer and is not
included here** — it is loaded at runtime with `dlopen()` from a copy **you** provide.
Unencrypted discs and already-decrypted ISOs need nothing.

Install it with the bundled script from the MiSTer **Scripts** menu:

```
Scripts/install_dvdcss.sh
```

It fetches a prebuilt **glibc/armhf** `libdvdcss.so.2` and installs it to
`/media/fat/dvdcss/libdvdcss.so.2` (override the source with `DVDCSS_URL=...`). To place
it by hand, put a glibc/armhf `libdvdcss.so.2` at that path — the core also looks in
`/media/fat/linux/` and on the default library path.

If an encrypted disc is inserted without libdvdcss present, the core shows
`CSS ENCRYPTED` and mutes rather than playing loud static — your cue to run the script.

Cracking CSS may be regulated where you live; check the laws that apply to you. This
project neither distributes libdvdcss nor contains any CSS circumvention code.

## Drive region (physical discs start faster with one set)

A drive with **no region set** refuses the CSS title-key ioctl, so libdvdcss cracks every
key from the disc data — that is the wait shown on screen as `No drive region: cracking`.
Setting the drive's region removes it. The other bundled script reads the drive's region
and can set it, from the MiSTer, with a menu you can drive on a gamepad:

```
Scripts/set_dvd_region.sh
```

⚠️ A region change is close to permanent — a drive allows about five changes ever, there is
no un-set, and at zero it locks to the last region. The script shows the remaining count
and defaults every prompt to *don't*. Design notes and the ioctl details are in
[../docs/physical_disc.md](../docs/physical_disc.md).

## Status

**Builds (native + Docker); not yet hardware-tested.** The CSS/decrypt modules are
lifted from a proven branch; the standalone auto-mount trigger (`dvd_phys`) and the
stock integration are new. See [../docs/physical_disc.md](../docs/physical_disc.md) for
the open verification items.
