# On-player support bundles — the gamepad chord

**Status: 🔧 implemented (2026-09-01), sim/host-verified; ⏳ HW-confirm pending.**
Ships in `MiSTer_DVDcss`, so it needs a Main rebuild and a board test.
See [`bug_reports.md`](bug_reports.md) for the bundle format itself.

## Why put this in the Main at all

`tools/dvd_report.py` already lets a reporter package a disc's navigation tables
on a PC. That covers most cases. Two things it cannot do:

- **It does not know where playback was.** A report says "somewhere in the
  menus"; the Main knows the exact sector being served when the user hit the
  chord. That is the single most useful fact a nav report can carry, and the one
  a reporter can never supply from memory.
- **It needs a PC.** Plenty of users have a MiSTer, a disc and Discord, and
  nothing else.

So: hold a gamepad chord while the DVD core is running and the Main writes a
bundle to `/media/fat/DVD_reports/`, built from whatever is currently mounted —
an image file *or* the optical drive.

## The shape, and why

**The Main shells out to `tools/dvd_report.py`.** It does not reimplement the
collector in C++. python3 is on a stock MiSTer (`install_dvdcss.sh` already
depends on it), the tool is stdlib-only and needs 3.7+, and a second
implementation would drift from the first — the audit and self-check would have
to be duplicated too, and a divergence there is exactly the kind of thing nobody
notices until a bundle turns out to be wrong.

It also dissolves the constraint that killed the earlier Scripts-menu idea. "A
Scripts entry gets no arguments, and the gamepad injects only arrows and Enter"
stops mattering when **the Main already knows what is mounted** and passes it as
an argument. No cursor menu, no typing, no `dialog` dependency.

`dvd_report.py` ships in the release zip at `Scripts/dvd_report.py`
(`tools/package_release.sh`), which is also the first place
`dvd_report.cpp` looks for it.

## The trigger: a chord, not an OSD row

**An OSD row would have cost a fitter seed re-roll.** Adding a `CONF_STR` entry
changes the string, which changes the netlist, which invalidates the pinned SEED
— the thing the `DVD.qsf` ledger exists to track. A one-line menu addition is not
a one-line change in this project.

A chord costs nothing in fabric: **Audio (B7) + Subtitle (B8), held 2 seconds**,
detected in `user_io_digital_joystick()`.

⚠ **The chord's own buttons still do their normal thing** — one audio-track step
and one subtitle step. That is deliberate. Masking the two bits on their way to
the core was considered and rejected twice over: it would mean *editing* the map,
so a detection bug could stop buttons working entirely, and it would swallow a
legitimate fast double-press. `dvd_report_joy()` only reads `map`, so it cannot
break anything that works today. B7/B8 were chosen because both are
edge-triggered single steps with on-screen feedback and both are trivially undone
— a chord on the transport buttons could leave a stray seek or pause.

## Flow

```
chord held 2 s
  └─ dvd_report_tick()          (poll loop, self-gates on is_dvd())
       ├─ source: dvd_phys_device() if a disc is mounted, else get_image(0)->path
       ├─ playhead: user_io_last_lba(0)
       ├─ settings: newest /media/fat/config/DVD*.CFG
       ├─ fork + execvp python3 dvd_report.py <src> --lba N --cfg F
       │                          --generated-on mister -o DVD_reports/<ts>.zip
       └─ reap in a later tick -> InfoMessage("written to ...") or ("FAILED, see log")
```

⚠ **The work must not run inline.** `dvd_report_tick()` shares the poll loop with
SD block service; a bundle takes long enough that blocking there would starve the
core mid-playback. Hence fork, with the child reaped by a later tick and the
result surfaced through `InfoMessage()` — Main's own facility, so **no RTL change
is needed for feedback either**.

The child runs **without `--nav-packs`**: that scans menu VOBs, which is seconds
of I/O on SD media. Nav tables only, which is what almost every nav bug needs.

## Physical discs work, and no decryption is involved

The source may be `/dev/srN` directly. Every sector the tool reads is one CSS
never scrambles — proven on a real encrypted disc, see
[`bug_reports.md`](bug_reports.md) "An encrypted rip produces the same bundle" —
so no libdvdcss handle, no keys, and no circumvention. `dvd_phys.cpp` gained
`dvd_phys_device()` to export the mounted node.

## Integration steps 22–25

Four anchored edits in `main/integration/apply_integration.py`; all verified to
apply and re-apply idempotently against the current stock tree.

| # | File | What |
|---|---|---|
| 22 | `user_io.cpp` | include `dvd_report.h` |
| 23 | `user_io.cpp` | `dvd_report_tick()` at the step-7 tick site |
| 24 | `user_io.cpp` | `dvd_report_joy(map)` at the top of `user_io_digital_joystick()` |
| 25 | `user_io.cpp` + `.h` | `user_io_last_lba(int)` — `buffer_lba[]` is file-static |

Step 25 is anchored on the **end of the `buffer_lba[16]` initialiser**, not on the
following function, so the accessor lands beside the data it exposes and
`insert_after` controls the spacing exactly (`insert_before` strips a trailing
blank line and would have jammed it against the next function).

No `Makefile` change: `$(wildcard ./support/*/*.cpp)` already picks up the new
file.

## ⚠ Do not trust the clock on an on-player bundle

The DE10-Nano has **no battery-backed RTC**. A networked MiSTer gets the time by
NTP; one that has never been online does not, so both the bundle's filename
(`dvdreport-YYYYMMDD-HHMMSS.zip`) and the manifest's `created_utc` can be
arbitrarily wrong — an epoch date rather than today's.

They stay *unique* within a session either way, which is all the filename needs.
But when ordering two bundles from the same reporter, sequence them by what they
say, not by their timestamps. A bundle made on a PC has a real clock behind it;
`player.generated_on == "mister"` marks the ones that may not.

## What is not done

- **The live status word is not captured.** `user_io_status_get()` reads at most
  two bytes of `cur_status[]`, so the full 128-bit word would need its own
  accessor. The saved `DVD*.CFG` is passed instead — the same settings, one save
  behind. Revisit only if a report ever turns on an unsaved toggle.
- **No HUD confirmation.** `InfoMessage()` is Main's overlay, not the core's, so
  the message is not part of the recorded video if someone films the screen. Good
  enough, and free.
- **Not hardware-confirmed.** The chord timing, the `InfoMessage` behaviour during
  playback, fork-under-load, and reading `/dev/srN` while `dvd_css` holds the
  drive are all untested on a board. That last one is the likeliest to surprise:
  two readers seeking the same optical device.
