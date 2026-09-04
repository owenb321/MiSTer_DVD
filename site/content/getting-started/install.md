# Install the core

Three steps: extract the zip, add two lines to `MiSTer.ini`, run one script. Do all three
and the core plays everything it can play — DVD images, physical discs, encrypted discs,
Video CDs — with 5.1 audio to a receiver over HDMI or optical.

Details for every step are [further down](#what-the-zip-puts-where).

## 1. Extract the zip

From the [**Releases page**](https://github.com/owenb321/MiSTer_DVD/releases/latest),
download **`MiSTer_DVD_v<version>.zip`** — the one zip, not the individual files listed
beside it.

Extract it to the **root of your MiSTer SD card** — `/media/fat` if you copy over the
network (SSH/SFTP) rather than pulling the card out.

## 2. Add two lines to `MiSTer.ini`

Add this to `/media/fat/MiSTer.ini`. **Add the section, do not replace the file:**

```ini
[DVD]
main=MiSTer_DVDcss
```

This is what enables physical discs, encrypted images, and bitstream audio over HDMI.

## 3. Run `install_dvdcss`

From the MiSTer **Scripts** menu, run **install_dvdcss**, once. It fetches libdvdcss, the
library that decrypts CSS — which nearly every commercial DVD uses, and which is not
shipped with this project.

---

Now launch **DVD** from the MiSTer menu and load a disc or an image. Images go in
**`/media/fat/games/DVD/`** — the folder the file picker opens in. See
[Loading a movie](loading.md).

!!! tip "Steps 2 and 3 are one-time"
    **To update later, just extract the new release zip.** The `MiSTer.ini` section and
    libdvdcss stay where they are — you never repeat them.

Everything below is detail — read it if something did not work, or if you want to know
what each piece does.

## What the zip puts where

```
/media/fat/
├── _Other/DVD_YYYYMMDD.rbf     the core itself — move it elsewhere if you prefer
├── MiSTer_DVDcss               optional custom Main (physical discs, encrypted ISOs)
├── Scripts/
│   ├── install_dvdcss.sh       fetches libdvdcss
│   ├── set_dvd_region.sh       reads/sets a USB drive's region
│   └── dvd_report.py           builds a bug-report bundle
└── DVD_INSTALL.txt             the same instructions, on the card
```

The core goes in **`_Other`** because a DVD player is not a console or computer category.
Nothing depends on that location — move the `.rbf` wherever you keep your cores.
**`MiSTer_DVDcss` is the one file that must stay at the SD-card root.**

Extracting the zip **does not switch anything on**. `MiSTer_DVDcss` sits inert until you
name it in `MiSTer.ini`, and the two scripts do nothing until you run them.

## About step 2 — the `MiSTer.ini` section

!!! warning "If you skip step 2, the symptom is silence"
    Without those two lines the core behaves **exactly as if `MiSTer_DVDcss` were not
    installed**. Decrypted images still play, so nothing looks broken — but physical discs
    do nothing, encrypted images show `CSS ENCRYPTED`, and HDMI bitstream never engages.
    There is no message pointing at the ini file, so this is worth double-checking if
    something is not working.

`main=` is a stock MiSTer feature: whenever the DVD core is loaded, MiSTer runs
`MiSTer_DVDcss` instead of the stock Main. Every other core is unaffected. Delete the
section, or the binary, and the core reverts to image-only playback with nothing else
changed.

**Reload the core after editing.** The Main is chosen at core load, so an already-running
core will not pick up the change.

!!! danger "Do not overwrite the stock `/media/fat/MiSTer`"
    `MiSTer_DVDcss` is an *additional* Main used only by this core. Both files live side
    by side.

There is one optional key for the HDMI bitstream path, if your receiver misreports what it
supports — see [Bitstream passthrough](../audio/passthrough.md#controlling-the-hdmi-path-from-misterini).

## About step 3 — libdvdcss

**libdvdcss is not part of MiSTer and is not shipped here.** It is loaded at runtime from a
copy you provide, and `install_dvdcss` fetches a prebuilt one to
`/media/fat/dvdcss/libdvdcss.so.2`. Override the source with `DVDCSS_URL=...`, or put a
glibc/armhf `libdvdcss.so.2` there by hand.

If encrypted media is loaded without libdvdcss, the core shows `CSS ENCRYPTED` and mutes
rather than playing static — that is your cue to run the script. (Unencrypted discs and
already-decrypted images play without it, so nothing breaks if you have not got to this
step yet.)

Didn't use the zip? Download the `install_dvdcss.sh` asset and drop it in
`/media/fat/Scripts/`.

!!! note "Legal note"
    Cracking CSS may be regulated where you live; check the laws that apply to you. This
    project neither distributes libdvdcss nor contains any CSS circumvention code.

## Optionally: set the drive region

*Physical discs only.* A drive with no region set makes every disc slow to start, because
the CSS keys have to be cracked from the data instead of read from the drive. Run
**set_dvd_region** from the Scripts menu to see the region and, if you want, set it.

**Read its warnings first** — a drive allows only about five region changes ever, and a
region cannot be un-set. Full detail:
[Set the drive region](../formats/physical-discs.md#set-the-drive-region).

## The release assets

`MiSTer_DVD_v<version>.zip` is the one to download — it contains everything below, laid
out ready to extract. The individual files are attached as well, for placing things by hand
or grabbing a single piece:

| Asset | What it is |
|---|---|
| `MiSTer_DVD_v<version>.zip` | Everything below, laid out ready to extract to the SD root |
| `DVD_YYYYMMDD.rbf` | The core only — enough for decrypted ISOs, VCD/SVCD and video files |
| `MiSTer_DVDcss` | The custom Main only — physical discs and encrypted ISOs |
| `install_dvdcss.sh` | The libdvdcss installer (also inside the zip's `Scripts/`) |
| `set_dvd_region.sh` | Drive-region tool (also inside the zip's `Scripts/`) |
| `dvd_report.py` | [Repro-bundle](../reference/reporting-a-bug.md) collector (also inside the zip's `Scripts/`) |

!!! warning "Taking `MiSTer_DVDcss` on its own? Take `dvd_report.py` too"
    The on-player bundle chord (**Audio + Subtitle**, held) runs `dvd_report.py` rather
    than reimplementing it, and looks for it at `/media/fat/Scripts/dvd_report.py`. The zip
    puts it there for you; if you are placing files by hand, the chord does nothing without
    it.

!!! note "Why the `.rbf` filename has a date and not a version"
    MiSTer's core browser and update scripts parse the `YYYYMMDD` out of the filename to
    decide which build is newest, so the core file is always `DVD_YYYYMMDD.rbf`. The
    version number lives in the release tag, the zip name, and the OSD — never in the
    `.rbf` name. If you keep several builds on the card, MiSTer offers the newest by date.

## Checking what you are running

The core's version is shown in the OSD as `v0.3.0 260901` — the version followed by the
build date. Quote that line in any bug report; it is the only thing that identifies a
build unambiguously.

If you are running a **test build** — one handed out for feedback before a release — the
line names the feature instead of a version, like `dev-seekrealign 260903`. That is
correct, not a fault: a test build is not a release and deliberately cannot be mistaken
for one. Quote it the same way.

## Updating

**Extract the newer zip over the top. That is the whole update.**

Steps 2 and 3 are one-time setup and never need repeating: your `MiSTer.ini` section stays
as you wrote it, and libdvdcss — along with any disc keys it has cached — is left alone.

The `.rbf` filenames differ by date, so old builds are not overwritten; delete them by hand
if you want them gone. MiSTer offers the newest by date either way.

!!! warning "Your settings may reset after an update"
    Saved settings live in `/media/fat/config/DVD_v1.CFG`, and the `v1` is a layout
    version. When a release changes the option layout incompatibly, that number is bumped
    and your options fall back to their defaults rather than being misread. This is
    deliberate — it replaces the older "please delete your config file" release note. Your
    previous file is left on the card and simply ignored; it can be deleted.

## Uninstalling

Delete `DVD_*.rbf`, `MiSTer_DVDcss`, the two scripts, and `config/DVD_v1.CFG`. If you added
a `[DVD]` section to `MiSTer.ini`, remove that too. Nothing else on the card is touched —
the core does not write outside its own config, except for the libdvdcss key cache at
`/media/fat/dvdcss/` if you used encrypted media.
