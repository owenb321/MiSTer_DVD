# Hardware-in-the-loop harness

**Status: Track A (interactive remote) SHIPPED and HW-CONFIRMED 2026-09-05.**
Probes 0, 1 and 2 all pass on the maintainer's rig. Tracks C (lip-sync
measurement), D (analog capture via a RetroTINK) and E (exploratory soak) are
designed but not built — see "What is not here yet".

> This is an ENGINEERING note, not user documentation. The harness needs a repo
> checkout and ssh to your own MiSTer; it is not shipped in a release and has no
> page in `site/`.

Every hardware round in this project used to be human-scale: build a named
`.rbf`, send it over Discord, wait for someone to flash it, play a disc, record
video and send the file back, then decode it offline with `tools/osd_read.py`.
Five rounds went into single-raster analog, twelve into lip-sync drift. The
harness collapses that loop for anything visible on HDMI:

```bash
echo root@192.168.1.10 > tools/.mister_host     # gitignored; or $MISTER_HOST

tools/mister.py deploy --rbf releases/DVD_foo.rbf
tools/mister.py launch /media/fat/games/DVD/MEN_IN_BLACK.iso \
                --opt "Disc Menus=On" --opt "Debug Overlay=On"
tools/mister.py key menu down select
tools/mister.py shot --decode
```

`shot` returns a PNG *and* a decoded state line. `mister.py options` prints
every OSD option and key name, both derived from the RTL.

## Why this needs no change to the core or to Main

Four stock mechanisms, all verified on hardware before any code was written:

| | |
|---|---|
| **`load_core` an `.mgl`** | `/dev/MiSTer_cmd` is a FIFO Main polls (`input.cpp:5140`, dispatcher `:6228`). `load_core` accepts a `.mgl` (`user_io.cpp:1518`), which loads a core **and** mounts media in one command. |
| **`screenshot`** | The same FIFO writes a PNG of the **core's raw raster**, read from ascal's *input* VBUF (`scaler.h:31`, `sys_top.v:680`). A name ending in `.png` is used verbatim under `screenshots/` (`file_io.cpp:885`) — a deterministic path. |
| **`config/DVD_v2.CFG`** | The core's saved settings are a raw 16-byte dump of Main's 128-bit `cur_status` (`user_io.cpp:600`), loaded at core init *before* reset is released, and written only by two explicit menu actions (`menu.cpp:3058`, `:5789`). So the harness owns the file, and writing it sets any OSD option for the next launch. |
| **uinput** | Main enumerates new `/dev/input` devices via inotify (`input.cpp:5164`), skipping only its own, named `"MiSTer virtual input"` (`:41`, `:5207`). Classification is purely `ev->code < 256` (`:3601`) → `user_io_kbd()` (`:3894`) → `ps2_key` → `dvd/kbd_map.sv`. HDMI-CEC already uses this exact non-HID route (`hdmi_cec.cpp:331`). |

## Facts that will bite, and did

**★ The MiSTer OSD is NOT in a screenshot, and keys do not reach the core while
it is open.** The shot comes from ascal's *input*; the OSD is composited after
ascal (`sys_top.v:1149`). MEASURED under control: with the OSD open, a `D`
(Display) press did **not** toggle the HUD, while the identical press with the
OSD closed did — so `user_io.cpp:4339` diverting keys to `menu_key_set()` is
real, and the frame taken at that moment showed no OSD.
⚠ A first attempt at this "confirmed" the OSD claim from a menu-core shot that
was simply an OSD that had timed out — an invalid test that happened to give the
right answer. The controlled version is the one to trust.
⚠ A second attempt was *also* invalid: `display_edge` arms the 2.5 s auto-show
timer as well as toggling persistence, so a HUD visible shortly after `D` proves
nothing. The settle must exceed `SHOW_TICKS`.

**★ NEVER overwrite `/media/fat/MiSTer_DVDcss` while it is the running Main.**
`readlink /proc/self/exe` then returns `"… (deleted)"`, `execl` fails, and
`app_restart()` falls through to `reboot(1)` (`fpga_io.cpp:611-645`). Writing in
place fails with `ETXTBSY`. On this rig the stock `/media/fat/MiSTer` runs in the
menu core and re-execs into `MiSTer_DVDcss` only on DVD core load
(`user_io.cpp:1483`, driven by `[DVD] main=` in `MiSTer.ini`) — so swapping the
Main **while the menu core is loaded** is safe. Otherwise deploy under a unique
name and rewrite `main=`.

**★ Main is started from `/etc/inittab` as `sysinit` with `&` — nothing respawns
it.** `killall MiSTer` is therefore NOT a recovery; it needs a reboot.

**★ MGL `<rbf>` resolution takes the lexicographically GREATEST match**
(`mra_loader.cpp:1288`), not the newest file. This rig has ~75 `DVD_*` builds in
`_Other/`, so a bare `DVD` selects a `MARGINAL` build from weeks ago. The
harness deploys under the fixed name `DVD_hil.rbf` and names it exactly. Free,
because the core name comes from `CONF_STR[0]`, not the filename — it is still
`DVD` and still uses `DVD_v2.CFG`.

**★ One command per FIFO write.** Main does a single `read()` then a single
if/else-if chain (`input.cpp:6230`); a second command in the same write is
silently discarded.

**★ `screenshots/` is not created on the verbatim path** (`file_io.cpp:885`
calls `make_fullpath` and discards it; only the datecode branch does `mkdir`).
`mister.py deploy` does the `mkdir -p`.

**★ The PNG is written asynchronously** to its final path with no temp-and-
rename (`scaler.cpp:617`), so poll for existence *and* a stable size.

**★★ The HUD and the O[2] blocks are drawn ~14 px LEFT of their nominal
coordinates on the shipped build.** This broke `hud_read.py` twice, both times
silently:

- The HUD's 16 px cell pitch means a grid one whole cell to the right *also*
  matches every glyph exactly. A search that stopped at the first zero-error fit
  read `'[PLAY]  0:01:24/0:09:59'` as `'  0:01:24/0:09:59'` — a perfect-looking
  decode that had dropped a field. The decoder now searches past one cell pitch
  and ranks by (fewest mismatches, **most content**, closest to nominal).
- The blocks are on a 20 px pitch, so nominal centres read each block one
  POSITION left of the one it names: `hl_btns_armed GREEN` when the truth was
  `video_live GREEN`. The lattice is now located from the pixels, taking the
  MIDDLE of the winning offset band.

Both are locked by fixtures cut from real screenshots
(`bench/dvd/hud_real_band.png`, `bench/dvd/hud_real_blocks.png`), each proven
RED/GREEN. The testbench-rendered golden frame `bench/dvd/hud_frame.ppm` draws
at the nominal geometry and **cannot** catch either.

**★ A gated-off O[2] block is "not shown", never "red".** Blocks 1-8 need
`menus_on`, 9-13 need `interlaced_eff` (`emu.sv:5153`, `:5211`).

**★ With no HUD on screen, bright picture content decodes as plausible glyphs**
— a real frame read as `[REV]` at maxerr 44. `hud_read` requires both an exact
fit and some non-space content before it reports a reading.

## Set `Debug Overlay=On` for anything that inspects state

`status[2]` drives `hud_dbg` (`emu.sv:1283`, `:4926`), which forces the status
line always-visible **and** repurposes the `CH n/N` field as
`{reader PGCN, VTS}` (`emu.sv:4953-4954`). So every screenshot carries decodable
playback state from frame one, with no keypress, **in a release build**. It also
enables the O[2] diagnostic blocks. This is why `tools/osd_read.py` is not the
primary reader: the numeric `DEBUG_OVERLAY` lattice it decodes is compiled out
(`DVD.qsf:382`) and re-enabling it re-rolls the pinned fitter seed.

## Rig facts (this maintainer's setup, 2026-09-05)

- `python3` 3.9.6 on the target — the key daemon needs nothing else.
- `/dev/uinput` present; Main opens it itself (`input.cpp:2045`).
- ISO library is a CIFS mount at `/media/fat/cifs/games/DVD` (919 entries), so
  **Track E can change discs unattended**. Local samples in
  `/media/fat/games/DVD`.
- `/media/fat` is 99% full — deploys reuse one fixed filename rather than
  accumulating.
- `log_file_entry=0` in `MiSTer.ini`, so `/tmp/OSD_VISIBLE` is not written.
  Setting it to 1 would give the harness OSD state, which it otherwise cannot
  see at all.

## Track C status (lip-sync)

`tools/sync_disc.py` generates DVD-authored marker clips (29.97 progressive,
23.976 with genuine soft 3:2 pulldown, PAL, AC-3/LPCM/MP2) and
`tools/lipsync_measure.py` measures A/V from a capture of them.

**What it is validated for: OFFSETS.**

| check | result |
|---|---|
| injected +50 / -80 ms in the generated file | recovered to **0.1 ms**, std 0.00 |
| the generated clip measured as-authored | flash interval **1.001000 s (0.0000%)** |
| commanded `A/V Offset +200 ms` on the board | measured **+199.2 ms** (0.4% error) |

**What it is NOT valid for: RATES / drift.** See the retraction below -- a
sampled capture card cannot measure a clock rate, and the tool now suppresses
the drift figure for captures. For anything rate-shaped use `mister.py telem`.

An earlier version of this section reported a ~30 ms/min core A/V drift as a
confirmed finding, with tables of per-mode figures. All of it was the capture
chain. The numbers have been removed rather than struck through, so they cannot
be quoted by accident.

### Capture recipe

Use `mister.py capture` -- it encodes the two non-obvious settings. Details and
the reasons are under "Facts that will bite".

## ★★ RETRACTED: there is no A/V drift. The core is locked; my instrument was not.

**Findings 1 and 2 as originally written are WRONG and are withdrawn.** The
~30 ms/min drift measured through the capture card is an artefact of the capture
chain. What follows is what actually holds, and how the error was made, because
the second part is the more useful half.

### What is true

Measured by the telemetry bridge -- ratios of counters in ONE clock domain, so
no external reference and no assumption about which clock is right -- with a
least-squares fit over 240 samples across ~124 s:

| quantity | measured | ideal | error |
|---|---|---|---|
| refreshes per pickup | 2.00001 | 2.00000 | **+7 ppm** |
| audio samples per content frame | 1601.6202 | 1601.6000 | **+13 ppm** |
| audio samples per raster refresh | 800.8042 | 800.8000 | **+5 ppm** |

with **0 lates, 0 drops, 0 drain-gate closures** over the whole window. Implied
A/V drift: **+0.8 ms/min**, i.e. nothing. The 23.976 film clip is equally clean
(2.50017 refreshes per pickup).

**The core's A/V pacing is correct.** The frame-drop governor, the drain gate
and the audio NCO are all doing exactly what they should.

### How I got it wrong

1. **I validated the instrument for OFFSETS and then used it for RATES.** The
   acceptance test -- commanded `A/V Offset +200 ms`, measured +199.2 ms -- is a
   genuine validation of a constant offset and says nothing whatever about
   whether the chain measures a *rate* correctly. Every drift figure rested on
   an unvalidated capability.

2. **My control for the capture chain was VACUOUS.** I compared the card's video
   PTS span against its audio PTS span over a 150 s recording, got 7 ppm, and
   concluded its clocks agreed. But ffmpeg recorded both streams for the same
   wall-clock duration *by construction*, so their spans agree trivially. The
   test could not have failed. That is the same shape as the benches
   `docs/field_parity.md` warns about, and I walked straight into it while
   quoting the lesson elsewhere in this very file.

**The test that settles it:** capture the SAME playback at a different capture
frame rate. 60 fps gives +31.4 ms/min; 50 fps gives +40.2 ms/min. A knob with no
connection to the core moves the answer by 30%, so the answer is about the knob.

### The rule this earns

⚠ **A sampled capture card measures OFFSETS, not RATES.** It holds the last
complete frame rather than integrating, and its sampling beats against the
source; that is fine for "how far apart are these two events" and unusable for
"how fast is this clock". For rate questions use the core's own counters, which
is why the telemetry bridge exists. `lipsync_measure.py` now refuses to print a
drift figure from a capture unless `--allow-drift` is passed.

⚠ **The internal ratios need a least-squares fit, not endpoint differencing.**
Endpoint deltas carry +/-1 count on each counter, which over 3709 pickups is
+/-270 ppm -- larger than anything worth measuring. The fit over 240 samples
brings that to single-digit ppm and is what turned "audio vs raster +46 ppm"
(endpoints, meaningless) into +5 ppm (fit, real).

## Telemetry bridge (core -> HPS)

Built 2026-09-05, when every OSD-reachable variable had been exhausted and the
drift still would not move. `dvd/dvd_telem.sv` answers over the hps_io EXT_BUS
extension (command `0x7A`); `main/support/dvd/dvd_ctl.cpp` publishes
`/tmp/dvd_telem.json` at 4 Hz and serves a command FIFO; `mister.py telem` and
`mister.py osd` are the host end.

```bash
tools/mister.py telem --watch 120      # rates, incl. refreshes-per-pickup in ppm
tools/mister.py osd "A/V Offset=+50ms" # set an option LIVE, no relaunch
```

**The number it exists for is refreshes / pickups.** The governor is supposed to
show each content frame for exactly `show_next` refreshes, so for 29.97 content
on a 59.94 Hz raster that ratio must be 2.000. If it reads low by ~450 ppm the
drift is the display governor; if it is exactly 2.000 the raster itself is fast,
and since audio measures correct the suspicion moves to the audio NCO divider.

Things worth knowing before touching it:

- **`status_in` is NOT the channel.** It looks like the obvious one and is not:
  stock Main polls `UIO_GET_STATUS` every frame and writes the result straight
  into `cur_status` (`user_io.cpp:2640`), so a core driving it would overwrite
  the user's OSD settings. EXT_BUS is the sanctioned core-specific extension.
- **The snapshot is atomic and the CDC is a stability filter, not a 2-FF sync.**
  These are multi-bit binary counters in three clock domains: sampled
  mid-increment, 0x00FF reads as 0x01FF, and one bad sample ruins a rate.
- **`mpeg2video` does not instantiate `resample_addrgen` directly** -- `resample`
  wraps it, and the `resample` instance ALSO has a `.frame_late` port, so
  anchoring an edit on that name lands one level too high. Quartus caught it
  ("Port pickup_cnt does not exist in macrofunction resample") where an iverilog
  elaboration check did not, because that module had not resolved.
- **Not behind an `ifdef`.** Gating it would mean a rebuild and a fitter-seed
  re-roll every time telemetry is wanted, which is the cost it exists to remove.

## Track E: exploratory soak (`tools/dvd_explore.py`)

Drives a disc unattended and watches for anything wrong. Seeded and fully
logged, so a finding replays exactly; state-aware, so it spends its time where
bugs are rather than mashing buttons at a paused screen.

```bash
tools/dvd_explore.py /media/fat/games/DVD/SOME.iso --minutes 30 --seed 1234
tools/dvd_explore.py selftest      # proves every oracle can fire
```

Oracles: the three MEASURED failure colours (black = reader wedged, green =
framestore slot never written, grey = intra picture from mis-framed bytes),
self-reporting popups (LINK FAIL, CSS ENCRYPTED, unsupported), the HUD clock,
and the telemetry counters (drain-gate closures, vid_err slope, drop bursts).
A finding captures the frame, the last 30 actions, the decoded HUD and the
telemetry, and notifies via `tools/notify.sh`.

⚠ **Two lessons from building it, both about the oracles rather than the core:**

- **An oracle must know what the harness just pressed.** The first version
  reported 15 faults in 24 steps, every one of them its own doing: `vid_err`
  measures video against the STC, so a menu, still or pause legitimately stalls
  video while the clock runs on, and a seek re-arms the audio drain gate by
  design. The checks are now gated on steady playback AND on the harness not
  having just perturbed anything, and `vid_err` is judged by SLOPE, not
  magnitude -- its magnitude carries whatever the last menu left behind.
- **Then check the gated oracles can still fire.** `dvd_explore.py selftest`
  gives every oracle a fault arm and a control arm, and it immediately caught a
  real bug: flatness was computed as `std` over all three channels at once, so a
  uniform GREEN frame measured std 64 (its channels are 0/136/0) and never
  registered as flat. The single most diagnostic signature would have been dead
  in production, and no amount of soaking would have revealed it.

Suite: `bench/dvd/run_telem.sh` (the telemetry bench plus all three host-tool
selftests; no hardware needed).

### First unattended hour (2026-09-05)

Six discs x 10 min, ~475 steps: Akira (NTSC film), The Office UK (PAL), Atmosfear
(NTSC interactive), Paw Patrol (TV), Batman Begins (film), Cluedo (PAL
interactive).

**No core defects found.** Five discs clean; Cluedo produced 11 findings that
were all one false-positive class, now fixed:

⚠ **A FROZEN PICTURE IS A STILL, NOT A STALLED TIMELINE.** On a still the
governor misses its deadline every refresh -- there is no new picture to show --
so `vid_err` climbs at exactly the refresh rate. Cluedo's interactive board
screen produced a textbook 50.0/s on PAL, with `vbuf_fill` 0 and 63% lates,
which reads alarmingly and is entirely normal. The flags cannot settle it: a
TITLE-DOMAIN interactive still (Cluedo, Scooby's maze -- see
`docs/dvd_menu_refinements.md`) sets neither `menu` nor `still`. The picture
itself is the reliable witness, so the telemetry oracles are now gated on the
frame actually having changed.

That makes three false-positive classes found and fixed by running the thing:
harness-perturbation, the green-frame flatness bug (found by the selftest, not
by soaking), and title-domain stills. The oracles fire on synthetic faults and
stay quiet across six real discs -- which is the balance worth having before a
finding from this tool is worth believing.

## Deploying a new Main, and putting the rig back

```bash
tools/mister.py deploy --main main/.build/MiSTer_DVDcss   # safe swap, no reboot
tools/mister.py restore                                   # back to stock Main
```

`deploy --main` installs under a name derived from the binary's own hash and
repoints `[DVD] main=`, because **the running Main must never be overwritten**
(see "Facts that will bite"). It also refuses to copy when the hash-derived name
IS the running binary -- deploying the same build twice would otherwise walk
straight into the landmine the function exists to avoid -- and garbage-collects
older `MiSTer_DVDcss_hil_*` that are neither the target nor running, since
`/media/fat` is nearly full.

`restore` puts `main=MiSTer_DVDcss` back, stops the key daemon and removes the
harness core, MGL and spare Mains. It does NOT revert `config/DVD_v2.CFG`, which
still holds whatever options the harness last set, and the running Main stays
until the next core load.

## Tests

```bash
bench/dvd/run_telem.sh     # everything below, plus the RTL bench
tools/tests/run_tests.sh   # host-side only
```

`tools/tests/` covers the two tables `mister.py` DERIVES rather than
transcribes, because a wrong value there produces a symptom that looks like a
core bug:

- `test_status_bits.py` -- every OSD option's bit span against positions
  documented independently in CLAUDE.md, plus the CONF_STR forms the live
  string does not contain (two base-32 chars, lowercase `o` +32, a page prefix
  with `X`, and `[hi:lo]`, whose sscanf reads END first). A wrong span sets the
  wrong option on the hardware.
- `test_key_table.py` -- every `hit[]` bit in `kbd_map.sv` is reachable by name,
  every PS/2 code in the RTL has a Linux keycode, and spot checks against Main's
  `ev2ps2[]`. An unreachable binding presents as "the core ignored my keypress".

## What is not here yet

- **Track C, lip-sync**: a generated sync clip (per-frame flash carrying a
  binary frame counter, audio click on the same PTS) plus capture and
  measurement across a mode matrix. Two calibrations are mandatory: run the same
  detector over the source file to cancel encoder delay, and measure the capture
  chain's own v4l2-vs-ALSA skew — without the second the harness measures the
  capture card and reports it as a core defect.
- **Track D, analog**: the RetroTINK-6X CE as the analog path's capture adapter.
  ⚠ The 6X CE has **no USB serial** (removed versus the 4K CE/Pro), so there is
  no scripted control or telemetry; its diagnostics page would have to be read
  from its HDMI output via the capture card.
- **Track E, exploratory soak**: walk menus and titles watching for anomalies,
  with the strongest oracle being a differential against `tools/dvd_vm_ref.py`
  and `tools/bin/trace_nav` using the HUD's `{PGCN, VTS}` readout.
- **Track B, `dvd_ctl` in the Main overlay**: only worth it for the four things
  Track A structurally cannot do — changing an OSD option without relaunching,
  mounting without relaunching, reporting state no screenshot carries (the OSD,
  the mounted path, `user_io_last_lba`), and injecting keys via `send_keycode()`
  to bypass the OSD gate.
- **No emu-level regression**: `mister.py`'s derived tables are checked only by
  `hud_read.py selftest` and by use. A `tools/tests/` runner asserting
  `parse_bits()` against `user_io_status_bits()` semantics, and every
  `kbd_map.sv` `hit[]` bit being reachable, is the obvious next gate.
