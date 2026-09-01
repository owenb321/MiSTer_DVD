# Install the core

Download the latest build from the
[**Releases page**](https://github.com/owenb321/MiSTer_DVD/releases/latest) and extract
the zip to the **root of your MiSTer SD card** — that is **`/media/fat`** if you copy it
over the network (SSH/SFTP) rather than pulling the card out. Then launch **DVD** from
the MiSTer menu.

That is the whole installation for decrypted images. What the zip puts where:

```
/media/fat/
├── _Other/DVD_YYYYMMDD.rbf     the core itself — move it elsewhere if you prefer
├── MiSTer_DVDcss               optional custom Main (physical discs, encrypted ISOs)
├── Scripts/
│   ├── install_dvdcss.sh       fetches libdvdcss
│   └── set_dvd_region.sh       reads/sets a USB drive's region
└── DVD_INSTALL.txt             the same instructions, on the card
```

The core goes in **`_Other`** because a DVD player is not a console or computer
category. Nothing depends on that location — move the `.rbf` wherever you keep your
cores. `MiSTer_DVDcss` is the one file that must stay at the SD-card root.

Extracting the zip **does not switch anything on**. `MiSTer_DVDcss` sits on the card
inert until you name it in `MiSTer.ini`, and the two scripts do nothing until you run
them from the Scripts menu. If you only ever play decrypted images, you can ignore all
three. See [What you need](what-you-need.md) to work out which apply to you.

## The release assets

The zip is the easy path, but every piece is also attached to the release individually if
you would rather place things by hand:

| Asset | What it is |
|---|---|
| `MiSTer_DVD_v<version>.zip` | Everything below, laid out ready to extract to the SD root |
| `DVD_YYYYMMDD.rbf` | The core only — enough for decrypted ISOs, VCD/SVCD and video files |
| `MiSTer_DVDcss` | The custom Main only — physical discs and encrypted ISOs |
| `install_dvdcss.sh` | The libdvdcss installer (also inside the zip's `Scripts/`) |
| `set_dvd_region.sh` | Drive-region tool (also inside the zip's `Scripts/`) |

!!! note "Why the `.rbf` filename has a date and not a version"
    MiSTer's core browser and update scripts parse the `YYYYMMDD` out of the filename to
    decide which build is newest, so the core file is always `DVD_YYYYMMDD.rbf`. The
    version number lives in the release tag, the zip name, and the OSD — never in the
    `.rbf` name. If you keep several builds on the card, MiSTer offers the newest by date.

## Checking what you are running

The core's version is shown in the OSD as `v0.3.0 260901` — the semantic version followed
by the build date. Quote that line in any bug report; it is the only thing that
identifies a build unambiguously.

## Updating

Extract a newer zip over the top. The `.rbf` filenames differ by date, so old builds are
not overwritten — delete them by hand if you want them gone.

!!! warning "Your settings may reset after an update"
    Saved settings live in `/media/fat/config/DVD_v1.CFG`, and the `v1` is a layout
    version. When a release changes the option layout incompatibly, that number is bumped
    and your options fall back to their defaults rather than being misread. This is
    deliberate — it replaces the older "please delete your config file" release note. Your
    previous file is left on the card and simply ignored; it can be deleted.

## Uninstalling

Delete `DVD_*.rbf`, `MiSTer_DVDcss`, the two scripts, and `config/DVD_v1.CFG`. If you
added a `[DVD]` section to `MiSTer.ini`, remove that too. Nothing else on the card is
touched — the core does not write outside its own config, except for the libdvdcss key
cache at `/media/fat/dvdcss/` if you used encrypted media.
