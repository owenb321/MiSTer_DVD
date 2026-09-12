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

## The playhead NAV-pack window (issue #81)

**Status: 🔧 built, host-tested + mutation-checked; the COLLECTOR is HW-measured on the
rig, the CHORD GESTURE is ⏳ HW-confirm pending.**

⚠ **The chord cannot be driven from the HIL harness, so that half needs the maintainer's
own gamepad.** `dvd_report_joy()` is called from `user_io_digital_joystick()`, and the
harness's uinput device is a KEYBOARD: its presses become joystick bits inside the FPGA
(`dvd/kbd_map.sv`) and never pass through Main's `map`. What WAS measured on the target is
everything the chord's child does — see the table below.

Issue #81 arrived as a menu-highlight bug whose bundle carried **no button data at all**,
and nothing in it said so. The diagnosis had to be made structurally from the IFO tables
instead. That was still the right diagnosis — the IFO's `subp_control` word was the
evidence — but the confirm was never in evidence, and the silence is the defect: a missing
capture produces a bundle that is written, self-checks, and looks complete.

★★ **THE OBVIOUS FIX WAS THE WRONG ONE, AND MEASURING SAID SO.** The chord had always
omitted `--nav-packs`, which the manual tells PC reporters to add for highlight bugs, so
"just pass it too" is the one-line answer. Two measurements kill it:

| | `--nav-packs` (menu-VOB scan) | `--nav-window` (this) |
|---|---|---|
| what it reads | every sector of `VIDEO_TS.VOB` + `VTS_nn_0.VOB`, capped at 512 MB | one **sequential** run forward from the served sector |
| MEN_IN_BLACK | 4.9 s, 2,810 NAV packs, **5.6 MB** of sectors (its 680 MB of menu VOBs hit the cap) | — |
| SCENEIT_HP | 0.8 s, 224 NAV packs | **0.28 s end to end, 16 NAV packs, a 38 KB bundle** |
| in-title menus | **cannot see them at all** | 13–20 of ~20 packs carry multi-button HLI |
| seeks | many | none |

★ **The second row of that table is the real finding, and it is structural, not a
tuning matter: `--nav-packs` scans MENU VOBs, so it cannot capture an in-title menu's
buttons on any route, PC included.** A DVD-game or motion-menu disc authors its menus as
TITLE-domain PGCs with the HLI in a title VOB's NAV packs — Scene It's game menus, and
issue #81's disc, whose boot menus live in `VTS_02_1.VOB`. So passing `--nav-packs` to the
chord would have cost minutes on an optical disc and still not answered this bug.

**What ships instead:** `tools/dvd_report.py --nav-window SECTORS` (with `--lba`) captures
every NAV pack in a short forward run from the playhead, and `dvd_report.cpp` passes
`--nav-window 2048` whenever it has one. A VOBU is at most 1 s of video, so 2048 sectors
(~4 MB) always spans several of them, and an HLI is re-sent every VOBU while a menu is up
(measured on The Matrix: the same unit 8 times, 1.001 s apart) — so forward-only is
enough. ★ It also captures **whatever the user was actually looking at**, in either
domain, which no offline scan can know.

Verified end to end on a real disc: a bundle built with `--lba 903500 --nav-window 2048`
against SCENEIT_HP reconstructs to a sparse ISO whose `nav_extract.py` walk decodes a
complete **7-button** in-title menu — rects, link graph, `btn_coli` colours and the VM
command per button. Audit and self-check both PASS.

**And measured ON THE MISTER ITSELF (2026-09-12), which is the number that decides
whether it belongs on a chord** — the local figures above are a dev workstation's:

| on the target | window (`--nav-window 2048`) | `--nav-packs` |
|---|---|---|
| SCENEIT_HP | **1.38 s**, 16 NAV packs, 37 KB bundle | — |
| (same, no capture at all) | 0.86 s, 34 KB | — |
| MEN_IN_BLACK | **1.98 s**, 14 NAV packs, 119 KB | **37.7 s**, 2,524 packs, 358 KB |

So the window costs about **half a second** over no capture at all, and `--nav-packs` is
**19× slower** than the window on this hardware — reading an ISO from local storage, with
the core not even running. On an optical disc the core is streaming from, with the CPU
contended, it is worse. That is the measurement that chose the design.

⚠ **The content guarantee is unchanged and still structural.** The window only appends
sectors that pass `is_nav_pack()`, and `audit()` re-checks the FINAL captured set and
refuses to write a bundle if any sector parses as a media pack carrying anything but a
system header, padding or `private_stream_2`. Nothing about this relaxes that.

⚠ **No `--nav-packs` on the chord, still** — and now for a better reason than cost: it
answers a different question, and the expensive one. The manual's on-player section says
so to users.

### How long the user waits, and why the NOTICE was the real risk

MEASURED on the rig (image media, core not running): the chord's child takes **1.38 s**
on SCENEIT_HP and **1.98 s** on MEN_IN_BLACK with the window, against 0.86 s for the nav
tables alone. So the window costs about **half a second** and the whole gesture is ~2 s.

⚠ **The PHYSICAL-DISC case is NOT measured** — the rig's tray held an audio CD (TOC 1-12,
so raw ISO9660 reads give EIO) when this was written. The estimate is 4 MB sequential from
the playhead on a drive that is already spinning and already positioned there, which is
~3 s at DVD 1x and well under 1 s at 4x+; but that is arithmetic, not a measurement, and
the reporter of issue #81 was on a physical disc. Measure it when a DVD is in the tray.
⚠ There is also a second cost there that is not wait time: the collector reads the SAME
drive the core is streaming from. The child is forked so it cannot starve the poll loop
(the `dvd_phys` lesson), but the DRIVE is shared and a long read could still hiccup
playback.

★ **The thing that would actually annoy a user is not the duration — it is silence.**
`start()` posted "Generating support bundle..." for **2000 ms** and then nothing until
`reap()` posted the result. That looked fine only because the job also takes ~2 s: two
unrelated numbers that happened to match, not a design. Anything slower drops the notice
before the result arrives, and a user who sees a "generating" message vanish with nothing
after it concludes it failed and presses the chord again. The notice is **8 s** now; the
result message replaces it the moment it arrives, so nothing is lost in the fast case.

⚠ **And extending it forced honouring a rule this project already wrote down.**
`dvd_report_tick()` raises `InfoMessage` from a poll tick, which is the exact shape that
froze MGL launches (issue #48) — `INTEGRATION.md` says to check `dvd_launch_ui_busy()` and
defer, and this path never did. In practice the chord needs a deliberate 2 s human hold
and so cannot collide with a launch, but "cannot happen" is what the pumps that DID freeze
it were assumed to be. It defers now; the cost is one more press of a chord nobody is
plausibly holding during a launch.

### The installed script may predate the flag

⚠⚠ **MEASURED ON THE RIG, and it is why the flag is not passed unconditionally: an
older release-installed `dvd_report.py` given the new argv prints**

```
dvd_report.py: error: unrecognized arguments: --nav-window 2048
```

**and writes NO BUNDLE AT ALL** — strictly worse than the missing button data the flag
exists to add. The release zip ships `Scripts/dvd_report.py` beside the Main
(`tools/package_release.sh`, and `package.yml` attaches it as its own asset), so they
normally move together; a Main updated on its own must degrade, not break.

So the child ASKS THE SCRIPT: `dvd_report_script_supports()` reads the file and looks for
the flag's own name. argparse cannot accept a flag it does not name, so a substring search
is sound in both directions — no old tool mentions it, and no new tool can support it
silently. It runs in the CHILD, after the fork, because it is file I/O and
`user_io_poll()` is the core's data pump (the `dvd_phys` drive-probe lesson); it reads in
8 KB chunks with a `tlen-1` overlap so a token straddling a boundary is still found.

### The argv moved out of the fork

`dvd_report_build_argv()` (declared in `dvd_report.h`, `DVD_REPORT_ARGV_MAX`) is built
outside the `fork()` purely so it can be tested, the same move as
`cdda_toc`'s track-skip resolver. **The failure mode here is silence**, which is the whole
reason: a missing or misspelled flag still produces a plausible bundle.
`main/tests/dvd_report_test.cpp` pins six arms — the terminator/bound, the full case, no
playhead, playhead only, an old script, and the probe itself — with **6 RED mutations each
caught by its own assertion**: drop `--nav-window`; pass it unconditionally (with no
playhead the tool gets a base of 0 and captures the NAV packs at the START of the disc —
*confidently wrong data instead of none*, which is worse than the bug being fixed); reach
for `--nav-packs` instead; forget the NUL; ignore what the installed script accepts; and
drop the probe's chunk overlap (which silently reports a perfectly good tool as too old).

⚠ Two harness lessons, both cost a round: `red_case`'s `grep -q "$expect"` read an expect
string beginning `--` as an option (fixed with `-e`), and a test that walks `argv` until
its NUL cannot detect a missing NUL — the terminator arm now pre-fills the array with a
sentinel, runs FIRST, and bounds every scan by `DVD_REPORT_ARGV_MAX`, so a missing
terminator is reported by its own assertion instead of as noise in an unrelated arm.

⚠ `run_tests.sh` grew `osd.h` and `file_io.h` to its empty-stub list, and the test defines
`dvd_css_active()` / `dvd_phys_device()` (declared by the real headers the module includes,
so these are definitions rather than shadowing stubs).

## What is not done

- **The live status word is not captured.** `user_io_status_get()` reads at most
  two bytes of `cur_status[]`, so the full 128-bit word would need its own
  accessor. The saved `DVD*.CFG` is passed instead — the same settings, one save
  behind. Revisit only if a report ever turns on an unsaved toggle.
- **No HUD confirmation.** `InfoMessage()` is Main's overlay, not the core's, so
  the message is not part of the recorded video if someone films the screen. Good
  enough, and free.
- ~~Not hardware-confirmed.~~ Confirmed 2026-09-02 — see the status block above.
