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

## Track C status (lip-sync) — VALIDATED, and it found something

`tools/sync_disc.py` + `tools/lipsync_measure.py` measure A/V sync end to end.

**Instrument validation, offline and on hardware:**

| check | result |
|---|---|
| injected +50 / -80 ms in the generated file | recovered to **0.1 ms**, std 0.00 |
| the generated file measured as-authored | flash interval **1.001000 s (0.0000%)** |
| commanded `A/V Offset` +200 ms on the board | measured **+199.2 ms** (0.4% error) |

That last row is the acceptance test: a known input producing a known change,
on real hardware. The instrument measures the core, not itself.

### ★ FINDING 1: video content runs ~430-570 ppm FAST against audio

On linear `.VOB` playback, measured against the authored 1.001000 s marker
interval:

| clip | video | audio | drift |
|---|---|---|---|
| demanding (6 Mbit/s, moving) | **-0.0566%** | +0.0007% | **+34 ms/min** |
| nearly static (2 Mbit/s) | **-0.0436%** | +0.0003% | **+26 ms/min** |

The audio timeline is right to within 7 ppm every time; the video is fast. That
is ~one content frame per minute, and after half an hour it is ~900 ms — the
same magnitude as the field complaint that drove the drift saga in
`docs/lipsync_pickup.md`, which closed on the basis that `vid_err` read flat.

**It survives every variable reachable from outside the core** (slope, ms/min):

| variable | values | result |
|---|---|---|
| container | flat `.VOB` / real DVD ISO, nav path | +32.0 / +31.3 |
| content | 29.97 progressive / **23.976 film + soft 3:2 pulldown** | +31 / +29 |
| decode load | demanding / nearly static | +34 / +26 |
| `Frame Drop` | On / Off | +30.2 / +30.8 |
| `Video Output` | Progressive / Interlaced | +28.7 / +28.6 |
| `Film 24p Out` | Off / On / Auto | +29.1 / +28.2 / +27.5 |

The film arm matters most: `tools/sync_disc.py --standard film` authors genuine
soft 3:2 pulldown via mjpegtools (ffmpeg cannot -- see the function comment),
and `tools/film_evidence_probe.py` confirms the core's own detector calls it
FILM+. That is the case real DVDs actually are, and it drifts like the rest.

**Four things it is NOT**, each measured rather than argued:

1. **Not the estimator or the 60 fps sampling grid.** Resampling the
   known-perfect source to 60.028 fps by frame duplication -- exactly what a
   sampling capture card does -- and measuring THAT gives **-2.2 ms/min**.
2. **Not the capture card's clocks.** Over a 150 s capture with no source at
   all, its video PTS and audio PTS spans agree to **7 ppm**, and audio sample
   count vs audio PTS to 16 ppm.
3. **Not decode load.** A nearly static 2 Mbit/s clip still drifts +26 ms/min.
4. **Not the frame-drop governor.** `Frame Drop` On vs Off: **+30.16 vs
   +30.77 ms/min**.

⚠ **Scope:** measured on synthetic marker clips. They are now DVD-authored
(dvdauthor + genisoimage) and cover both 29.97 progressive and 23.976 film with
soft pulldown, played through the real nav path -- so the earlier caveat about
linear-only playback is discharged. What remains untested is commercial content
with its own encoding quirks, which carries no markers; the `DEBUG_OVERLAY`
`vid_err` row is the instrument for that.

### ⚠ FINDING 2 (preliminary): negative A/V Offset applies only partially

Commanded `+200 ms` measured `+199.2 ms`; commanded `-100 ms` measured
`-44.6 ms`, with the same instrument in the same session. One measurement each,
so treat it as a lead rather than a result -- but the asymmetry is large and the
positive direction is exact.

### Capture recipe

Use `mister.py capture` -- it encodes the two non-obvious settings. Details and
the reasons are under "Facts that will bite".

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
