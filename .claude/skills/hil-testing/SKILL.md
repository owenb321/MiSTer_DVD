---
name: hil-testing
description: Drive the maintainer's real MiSTer over ssh to test the DVD core — flash a build, launch a disc, press transport keys, pull back a decoded screenshot, read the decoder's live pacing counters, soak a disc unattended, or diff the core's navigation against libdvdnav. Use whenever a question would otherwise be answered by asking the user to test something on hardware, or when a change needs confirming on the board.
---

# Hardware-in-the-loop testing

The rig is reachable over ssh and can be driven end to end from here: flash, launch a
disc, press buttons, screenshot, read the decoder's own counters. **Prefer this to asking
the user to test something.** It turns "please try this and tell me what you see" into a
measurement you make yourself.

Design notes and the full evidence trail live in **`docs/hil_harness.md`** — this skill is
the operating manual.

## Setup (once per session)

```bash
cat tools/.mister_host          # e.g. root@192.168.1.x  (gitignored, never commit it)
tools/mister.py state           # core, running Main, key daemon, recent log
```

`tools/mister.py deploy --agent` starts the key daemon and arms telemetry.
Add `--rbf releases/DVD_x.rbf` to flash a core, `--main main/.build/MiSTer_DVDcss` for a
custom Main.

**Put the rig back when you are done** — the maintainer uses it:

```bash
tools/mister.py restore         # stock Main, harness files gone, saved settings restored
```

## The tools

| Command | What it does |
|---|---|
| `mister.py launch <iso> --opt "Name=Value"` | write settings, mount, load core (via MGL) |
| `mister.py key menu down select` | press transport keys (names derived from `kbd_map.sv`) |
| `mister.py shot --decode` | screenshot + decode the HUD to structured state |
| `mister.py telem --watch 120` | the decoder's pacing counters, as rates |
| `mister.py osd "A/V Offset=+50ms"` | change a setting LIVE, no relaunch |
| `mister.py options` | every OSD option and key name, derived from the RTL |
| `hud_read.py read/blocks <png>` | decode a screenshot's HUD / `O[2]` diagnostic blocks |
| `dvd_explore.py <iso> --minutes 30` | unattended soak with self-tested oracles |
| `nav_diff.py <disc> --script "1 2"` | diff the core's navigation against libdvdnav |
| `lipsync_measure.py` + `sync_disc.py` | A/V **offset** measurement (see the warning below) |

Gates, all hardware-free: `bench/dvd/run_telem.sh`.

## Traps that have cost real time

**★ Telemetry field names come from `main/support/dvd/dvd_ctl.cpp`'s `fprintf`, never from
the RTL port names.** Word 11 is `disp_lag` in `dvd_telem.sv` and `disp_lag_ms` in the JSON
— renamed AND pre-scaled to ms. `.get('disp_lag', 0)` returns a constant zero and produces
a **dead oracle that no selftest can see**, because selftests feed synthetic dicts. This
has happened twice.

**★ Signals get RETIRED. Check a telemetry field is alive before believing it.** PR #63
tied word 5 (`vid_err`) to a literal `16'd0`; an oracle reading it was silently dead for
months. `dvd_explore` now prints a liveness report naming any field that never changed.

**★ Screenshots are the CORE's raw raster, taken upstream of the MiSTer OSD** (ascal's
input buffer). So a shot never contains the OSD, popups or scaling — and **you cannot see
the OSD at all**, which is why options are set by writing the settings file, not by
navigating menus.

**★ A sampled capture card measures OFFSETS, not RATES.** It holds the last complete frame
rather than integrating, so its "drift" figure changes with the capture frame rate (60 fps
gave +31 ms/min, 50 fps +40 ms/min on the same playback). `lipsync_measure` suppresses
drift figures from captures for this reason. For anything rate-shaped use `mister.py
telem`, whose ratios are counters in one clock domain.

**★ Never overwrite the running `MiSTer_DVDcss`.** It reboots the box (`execl` on a
deleted exe → `app_restart` → `reboot(1)`). `deploy --main` handles this; it installs under
a hash-derived name and repoints `[DVD] main=`.

**★ `launch` overwrites the user's saved OSD settings** (it writes `config/DVD_v<N>.CFG`).
It backs them up once; `restore` puts them back. Do not leave a session without restoring.

**★ Ask "is the PICTURE frozen or is the MACHINE frozen?"** That one question separates an
HPS-side stall from a core-side one before any code is read.

## Reading the board's navigation state

With `--opt "Debug Overlay=On"` the HUD's `CH n/N` field becomes `{reader PGCN, VTS}`, and
the `O[2]` blocks appear (block 1 = `hl_btns_armed`). That is how `nav_diff` knows where
the core landed and whether it is waiting for input.

## Diffing navigation (nav_diff)

```bash
tools/nav_diff.py interactive/SOME.iso --script "1 2" --settle 3
tools/nav_diff.py <disc> --script "1" --red 2      # prove the comparison can fail
tools/nav_diff.py <disc> --no-board                # oracle only, no hardware
```

- **libdvdnav is the oracle, not `dvd_vm_ref.py`.** The golden model was written from the
  RTL and shares its assumptions; it agreed with the hardware all through the POST-only PGC
  bug. Use `dvd_vm_ref` only as a third opinion when the two disagree.
- **A park is where the disc waits for INPUT** — `buttons=N` in libdvdnav,
  `hl_btns_armed` on the board. Not a fixed sleep, not a still picture, not a settled PGCN
  (a First Play logo holds one PGCN for many seconds).
- **libdvdnav runs at CPU speed; the board plays every cell in real time.** Boot chains
  that cost the oracle milliseconds cost the board minutes.
- **Only well-defined inputs are comparable.** Pressing a button that does not exist at
  that park is undefined, not a difference.

## Before believing a finding

1. Does it **reproduce**?
2. Would it change if you changed something **unrelated to the core** (capture rate, settle
   time, disc)? If so it is the harness.
3. Is the instrument **validated for the thing being claimed**? An offset validation says
   nothing about rates.
4. Is the control arm **capable of failing**? Prove it with a deliberate mutation.

Every one of those caught a wrong conclusion of mine that was already written down as fact.
