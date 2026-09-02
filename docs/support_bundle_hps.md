# On-player support bundles — the gamepad chord

**Status: ✅ HW-CONFIRMED 2026-09-02 — and on the hardest case first, a PHYSICAL
DISC.** See [`bug_reports.md`](bug_reports.md) for the bundle format itself.

The confirming artifact (`dvdreport-20260902-030608.zip`, NCIS_S1_D4 on `sr0`,
7.22 GB disc): 76 sectors → **77 KB**, content audit clean (76 nav-table sectors,
0 carrying A/V), reconstructs to a 7.22 GB sparse image occupying 160 KB, and
`iso_nav_check.py` walks it fully — 5 titles, TT_SRPT, the First Play PGC and its
13 pre-commands — while `dvd_vm_ref.py boot` executes the boot chain to
`JumpTT 5` → VTS 2 PGCN 1.

★ **The playhead is the part that justifies building this into the Main at all.**
It recorded sector **52673**; VTS_01's title VOB starts at **50609**, so it caught
the user 2,064 sectors (4.2 MB) into the feature. That is the one fact a reporter
can never supply from memory.

**Both source routes confirmed.** A second bundle, from a *mounted ISO*
(`dvdreport-20260902-035310.zip`, THE_MATRIX, 8.39 GB): 131 sectors → 99 KB, audit
clean, `core version v0.4.0 260901` captured automatically, playhead at sector
619898 — and `iso_nav_check.py` output is **byte-identical (526 lines) to the
original ISO** held locally, which is the strongest form this check takes.

★★ **Reading `/dev/srN` while `dvd_css` holds the drive WORKS** — this was flagged
as the likeliest thing to misbehave (two readers seeking one optical device) and it
did not.

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
       ├─ source: dvd_phys_device() if a disc is mounted, else mounted_path
       │           (captured at mount time -- see below; NOT get_image()->path)
       ├─ playhead: user_io_last_lba(0)
       ├─ settings: newest /media/fat/config/DVD*.CFG
       ├─ core version: OsdCoreNameGet() after the first space
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

## The core version comes for free

The first hardware bundle read `core version (not stated)`, which matters more on
this route than on the PC one: there is no reporter in the loop to type it, and
CLAUDE.md is emphatic that the OSD version line is the only thing that identifies
a build.

No new plumbing was needed. `CONF_STR`'s `V,v0.4.0 260901` line is appended to the
OSD core name at init (`user_io.cpp`, the `p[0] == 'V'` arm), so
`OsdCoreNameGet()` reads back `"DVD v0.4.0 260901"` and everything after the first
space is the version. ⚠ If there is no space the core published no `V` line, and
the bundle records nothing rather than passing the bare core name off as a
version.

## ⚠ Where the mounted image's path comes from

Nothing in stock Main keeps it. `fileTYPE::name` is the **basename only**
(`FileOpenEx` stores `p + 1`), and `fileTYPE::path` is populated **solely** in the
pre-create branch of `user_io_file_mount()` (`if (!ret && pre)`). So a normally
mounted ISO has neither, and the first version of `find_source()` — which tested
`f->path[0]` — reported **"Load a disc or image first" with a disc plainly
loaded**. A physical disc worked throughout, because that path resolves through
`dvd_phys_device()` instead, which is exactly why the bug survived the first
hardware round.

Fixed by capturing the path at mount time (step 26) rather than trying to recover
it afterwards.

⚠ **And it must be made absolute.** Mount paths are relative to `getRootDir()`
unless they begin with `/` — `make_fullpath()` does that expansion, and every
in-Main consumer goes through it. This one does not: it is handed to a separate
process with its own working directory, so a relative path would simply not be
found. The `*DVD_PHYS*` sentinel is filtered out too; it is not a file.

## Integration steps 22–26

Five anchored edits in `main/integration/apply_integration.py`; all verified to
apply and re-apply idempotently against the current stock tree.

| # | File | What |
|---|---|---|
| 22 | `user_io.cpp` | include `dvd_report.h` |
| 23 | `user_io.cpp` | `dvd_report_tick()` at the step-7 tick site |
| 24 | `user_io.cpp` | `dvd_report_joy(map)` at the top of `user_io_digital_joystick()` |
| 25 | `user_io.cpp` + `.h` | `user_io_last_lba(int)` — `buffer_lba[]` is file-static |
| 26 | `user_io.cpp` | `dvd_report_note_mount(name)` in `user_io_file_mount()` |

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
- ~~Not hardware-confirmed.~~ Confirmed 2026-09-02 — see the status block above.
