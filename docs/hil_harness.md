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

## Track C status (lip-sync) — instrument built, NOT yet validated

`tools/sync_disc.py` and `tools/lipsync_measure.py` work end to end: a real HDMI
capture of the core playing the sync clip yields every flash and every click,
and the measurer reports a per-marker error curve.

**Offline the instrument is exact.** On the generated file itself, injected
errors of +50 ms and -80 ms come back as themselves to 0.1 ms with std 0.00
(`lipsync_measure.py selftest`).

**On the capture chain it is not yet good enough to trust**, and the numbers say
so:

| | |
|---|---|
| run-to-run repeatability (same setting, 45 s) | **~10 ms** (-89.6 vs -100.1) |
| commanded `A/V Offset` 0 -> -100 ms | measured **-75 ms** |
| commanded `A/V Offset` +100 -> 0 ms | measured **-109 ms** |

Directionally right and roughly the right size, but the scatter is larger than
the repeatability, so the plan's acceptance test ("a known input produces a
known change") is **not passed**. Do not quote absolute lip-sync figures from
this chain yet.

### What the capture chain does, measured

- **★ The card emits ~1 s of BLACK while it locks, at every resolution.** A
  grab taken inside that window is indistinguishable from "no signal" and cost
  a round of blaming the cable here. `ffplay` appears to work where an
  equivalent `ffmpeg -frames:v N` does not, purely because it keeps running
  past the lock — that difference is the tell. `mister.py capture` discards a
  warm-up by default. (An earlier version of this note claimed the card was
  blank at 1920x1080 and fine at 720x480; that was the same warm-up bug, and
  the mode had nothing to do with it.)
- **1080p is not worth capturing.** Detection is a whole-region luma step, so
  resolution buys nothing; 60 fps is the binding constraint at either size; and
  1080p60 MJPEG is ~4x the USB bandwidth, so it jitters and drops more — and
  delivery jitter is precisely what limits timing precision. The core's raster
  is 720x480, so 1080p only means ascal upscales and the measurer downscales
  again. For pixel-exact frames use `mister.py shot`, not the capture card.
- **Video timestamps are real**, not synthesised: dt varies 8-25 ms (USB
  delivery jitter), mean 60.046 fps over a 60 s span.
- **Do NOT derive video time from frame_index / nominal_fps.** A 60 fps capture
  of this core's 59.94 Hz output drifts by exactly
  `(1/59.94 - 1/60) x 60 = 1.0 ms per second` against an index clock, and the
  card duplicates a frame every ~17 s to make up the difference. That produced
  a textbook +1 ms/s ramp with periodic 16.7 ms steps — which, unrecognised,
  would have been reported as core drift. `lipsync_measure` uses the
  container's per-frame timestamps.
- **A residual sawtooth remains** after that fix: the card's audio clock drifts
  against the host video clock at ~1.5 ms/s, resetting every ~16 ms. It is
  BOUNDED and self-resetting, so the median over a long window is stable while
  instantaneous values wander — hence median, not mean, and hence the ~10 ms
  repeatability floor.

### To finish Track C

1. **Longer captures** (3-5 min rather than 45 s) to beat the sawtooth down,
   and several repeats per setting, before re-running the acceptance test.
2. **Fix the audio timeline properly**: take the click time from the audio
   stream's own packet timestamps rather than counting samples from the start,
   so both streams sit on the host clock. This is the principled cure for the
   residual drift and should collapse the noise floor.
3. **Probe 3 proper** — the chain's absolute A/V skew still needs a
   known-synchronous reference (this PC's HDMI into the card), which is a cable
   swap. Until then `capture` refuses to print an absolute figure, by design;
   relative comparisons between modes are already usable.

⚠ The historical bug this replaces was ~1200 ms of accumulated skew
(docs/lipsync_pickup.md), so the chain is already good enough to catch a
regression of that class. It is not good enough to certify a 10 ms claim.

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
