# Physical DVD playback (custom Main + CSS)

Status: **🔧 in progress** (branch `feature/physical-disc-css`, started 2026-08-29).
Not yet built or HW-tested. Rebase onto `main` after the Film-24p branch merges.

This adds **physical DVD-Video playback** (and a planned encrypted-ISO path) to our
in-fabric DVD core, without changing the decode architecture. The core keeps decoding
in fabric; a small **custom MiSTer Main** (`MiSTer_DVDcss`, built under `main/`) reads
the optical drive, decrypts CSS with a user-supplied libdvdcss, and feeds plaintext
sectors to the core over the standard `sd_*` block interface.

## Why this shape

Our fabric core already ingests a DVD as random-access 2048-byte sectors: `sd_lba` is the
2048-byte LBA, 1:1 with the DVD RBN, and `dvd_iso_reader.sv` navigates VIDEO_TS in fabric
(the framework Main serves each `sd_lba` from a mounted image file). **A physical disc is
therefore just a different sector source** — decrypt-on-read from `/dev/srN` instead of
read-from-file — so the RTL is untouched. All the new logic is HPS-side, in the Main.

`main=` (name a custom Main per core in `MiSTer.ini`) is a **stock** MiSTer feature
(Sorgelig, Main_MiSTer commit `e61b111`, 2024-03), so this needs no forked primary Main.

## Handoff chain

```
Insert DVD → [optional] MiSTer Physical Disc fork → Auto Disc Discovery
                launches DVD.rbf (selected in MiSTer.ini)
                        │
DVD.rbf load → stock MiSTer re-execs  [DVD] main=MiSTer_DVDcss
                        │
MiSTer_DVDcss (our custom Main)
  ├─ dvd_phys : scan /dev/srN, probe DVD-Video, mount on insert / unmount on eject
  ├─ dvd_detect : READ(10) ISO9660 + VIDEO_TS probe (no mount needed to detect)
  ├─ dvd_css  : dlopen libdvdcss; region/CSS detect; per-VOB title keys; decrypt reads
  └─ user_io  : SD_TYPE_DVDCSS slot — serves each sd_lba CSS-decrypted
                        │  sd_* block interface (unchanged)
                        ▼
             dvd_iso_reader.sv → fabric decode → video / audio
```

The fork is **optional** and only provides cross-core auto-launch. With just
`MiSTer_DVDcss`, opening the DVD core with a disc present plays it, and inserting a disc
while the core is open plays it (`dvd_phys` polls for media change).

## Components (under `main/`)

| File | Role |
|---|---|
| `support/dvd/dvd_css.cpp/.h` | libdvdcss `dlopen` wrapper: find drive, RPC-region detect (SG_IO REPORT KEY), CSS detect (READ DVD STRUCTURE), per-VOB title keys, `dvd_css_read()` decrypted sectors, deferred "install libdvdcss" popup. Drive path lifted from the proven `feature/dvd-video-css` branch; `dvd_css_open_image()` (encrypted-ISO file source, reusing the same read/VOB-walk machinery) added here. |
| `support/dvd/dvd_detect.cpp/.h` | `READ(10)` ISO9660 PVD + root-dir walk for `VIDEO_TS` — recognises a DVD-Video without mounting. |
| `support/dvd/dvd_phys.cpp/.h` | **New, standalone.** Replaces the fork's launcher trigger: polls `/dev/srN`, mounts a DVD-Video via `user_io_file_mount(DVD_PHYS_SENTINEL)` on insert; on eject, unmounts **and** pulses `user_io_status_set("[0]", 1)` (the core's OSD-reset → unload + VM reset → idle logo) so a removed disc doesn't freeze the last frame. |
| `Scripts/install_dvdcss.sh` | User-run installer for a prebuilt armhf libdvdcss → `/media/fat/dvdcss/libdvdcss.so.2`. |
| `integration/` | `INTEGRATION.md` (the six `user_io.cpp` edits + `-ldl`) and `apply_integration.py` (anchored, idempotent patcher). |
| `build_main.sh` | Fetch pinned stock Main, apply overlay, patch, build `MiSTer_DVDcss`. |

## Region / CSS edge cases handled (from the fork's dvd_css)

- **No drive region (RPC-II):** SG_IO REPORT KEY reports `region_mask == 0xff`; libdvdcss
  falls back to statistical cracking. Shown on screen as `No drive region: cracking`.
  ⚠ **An RPC-1 drive reports the same empty mask and means the opposite** — it enforces no
  region at all and answers the key exchange whatever the disc's region. `drive_region_set()`
  read only the mask until 2026-09-04, so a region-free drive (the best case there is) was
  labelled `No drive region: cracking` and logged as having no region set. The verdict now
  also passes on `rpc_scheme == 0` (REPORT KEY byte 6).
- **CSS-without-libdvdcss:** READ DVD STRUCTURE copyright byte detects CSS upfront; a
  deferred popup asks the user to run `install_dvdcss.sh` (immediate reads would black-screen
  on many drives). The fabric core's own `pes_scrambled` → `CSS ENCRYPTED` + mute is the
  backstop.
- **Title keys per VOB** at each VOB start sector (libdvdread's pattern), lazily so the
  mount does not freeze; filesystem/IFO sectors read NOFLAGS (raw), VOB payload DECRYPT.

## Relationship to MiSTer Physical Disc (Anime0t4ku)

Per PR discussion (2026-08-29), the split is: **Physical Disc Main = detect + launch the
user-selected DVD core; no core-specific DVD/CSS logic, no CSS in that repo.** Our core
owns its own physical-disc handling here. Anime0t4ku will add a `MiSTer.ini` option to
choose which DVD core Auto Disc Discovery launches (like his audio-CD selection), so our
core and dvd-core coexist. Our upstream contribution is limited to the detection-only
`READ(10)` probe (with his fixes: run before the CD TOC path; add ISO9660 bounds checks).
Our PR #10 (CSS in his Main) is superseded by this custom-Main approach.

## Encrypted ISOs (no drive needed)

Implemented. `dvd_css_open_image()` reuses the exact decrypt / VOB-walk machinery with a
**file** source instead of `/dev/srN`, so a CSS-encrypted `.iso` rip plays directly —
removing the "decrypt on PC first" step and, notably, **needing no optical drive at all**
(broadens the audience). On an `.iso` mount under the DVD core, `user_io_file_mount` opens
the image through libdvdcss and claims it (`SD_TYPE_DVDCSS`) **only if
`dvdcss_is_scrambled()`**; a decrypted ISO returns 0 and keeps the fast direct-file mount,
so clean rips pay nothing. With no drive to authenticate, title keys are cracked from the
data (same slow path as a no-region drive) and cached under `DVDCSS_CACHE`
(`/media/fat/dvdcss/cache`), so it is a one-time cost per disc.

libdvdcss reads image files directly (it is how VLC/mplayer play ISOs — no loop mount
needed). Note: `dvd_css` holds a single handle, so physical disc and encrypted ISO are
mutually exclusive (last mount wins) — a non-issue in normal use.

**★ Two real bugs found bringing encrypted ISOs up on HW (round 1, 2026-08-29):**
1. **Storage-relative mount path.** MiSTer passes `user_io_file_mount` a storage-relative
   name (`cifs/games/DVD/x.iso`), not an absolute path, so `stat()`/`dvdcss_open()` failed
   (`stat failed` in the log) and the mount fell through to `CSS ENCRYPTED`. Fix: resolve
   via `getFullPath()` (handles the CIFS/USB prefix) before touching the file. The
   framework's own `FileOpenEx` does this internally, which is why *decrypted* ISOs worked.
2. **Scramble detection — must read the BITSTREAM, not `dvdcss_is_scrambled()`.** The
   right question is "are the VOB *sectors* actually scrambled (need decrypting)?", which
   `dvdcss_is_scrambled()` does **not** answer — it reports the disc's CSS *structure*, so
   it reads 1 for a **decrypted rip of a CSS disc** too (structure says CSS, sectors are
   plaintext). Trusting it cracked keys for already-decrypted ISOs (Atlantis: `scrambled=1
   (lib=1 bitstream=0)`). Correct signal: `image_is_scrambled()` reads VOB payload sectors
   raw and checks the clear PES `scrambling_control` bits. Its own bug had to be fixed
   first — it returned on the *first* PES, so one unscrambled PES made it miss a genuinely
   encrypted disc (FAIRYTOPIA read `bitstream=0`); it now scans and only concludes
   "plaintext" after finding none scrambled (returns 1 found / 0 plaintext / -1
   inconclusive). Gate = bitstream primary, `dvdcss_is_scrambled()` only as the `-1`
   fallback. So: encrypted disc → crack; decrypted rip or never-CSS → fast direct path.

`/tmp/dvdcss.log` logs both verdicts per mount (`scrambled=N (bitstream=B lib=L)`).
Physical discs were unaffected by all of this. **HW-verify** a genuinely encrypted ISO
still reads `bitstream=1` and cracks + plays, and a decrypted/unencrypted ISO reads
`bitstream=0` and takes the direct path with no crack. (If an encrypted ISO ever claims
the mount but still shows `CSS ENCRYPTED`, that is the separate `DVDCSS_METHOD`-on-a-file
question — per-title cracking on a file may need `DVDCSS_METHOD=title`.)

**Why the probe tests two things, not one.** `dvd_video_probe()` requires an
ISO9660 primary volume descriptor (`CD001` at sector 16) **and** a `VIDEO_TS`
directory entry in the root. The second half is what makes it safe: `CD001` alone
matches most of the optical-console library, including several systems MiSTer runs.

| disc | ISO9660? | root `VIDEO_TS`? | mounted |
|---|---|---|---|
| PlayStation, Saturn, Sega CD, Neo Geo CD, CD32/CDTV, ao486 | yes | no (`SYSTEM.CNF`, `IP.BIN`, …) | no |
| PC Engine CD / TurboGrafx-CD | no (custom, CD-DA + data) | — | no |
| 3DO | no (Opera FS) | — | no |
| CD-i | yes (XA) | no | no |
| Video CD / SVCD | yes | no (`VCD/`, `MPEGAV/`) | no |
| GameCube, Wii, Xbox | no (proprietary; XDVDFS starts at sector 32) | — | no |
| audio CD | READ(10) fails outright | — | no |
| DVD-Video, incl. DVD games and home-burned `VIDEO_TS` | yes | yes | **yes** |
| DVD-Audio | yes | usually yes (the Video zone) | yes — and correctly: a real player plays that zone too |

So no console disc can be mistaken for a movie, and that is worth keeping in mind
before relaxing either half of the test.

⚠ The probe scans at most the **first 8 sectors** of the root directory (16 KB,
several hundred entries). A `VIDEO_TS` sorting past that would be missed — but that
is a false *negative*: the disc is simply not auto-mounted, which is the safe
direction. A rejection is now logged to `/tmp/dvd_report.log` once per insertion, so
"I put a disc in and nothing happened" has a record; without it, "we rejected it"
and "we never saw it" look identical from outside.

**⚠ The cache directory must be created two levels deep, and the result checked.**
`mkdir()` creates one level, and `/media/fat/dvdcss` only exists if libdvdcss was
installed by our own `Scripts/install_dvdcss.sh` — `css_lib_names` also finds the
library in `/media/fat/linux/` or on the system path, and then the parent is
missing, `mkdir("/media/fat/dvdcss/cache")` fails `ENOENT`, and the return was not
checked. libdvdcss then does its own single-level `mkdir` on the same path, fails
identically, and **disables caching silently** — so every play re-extracts the
keys, which on a no-region drive or an image file means the full crack every time.
`setup_cache()` now creates both levels, proves the directory is writable (a
removable card can be mounted read-only after an unclean shutdown, which looks
identical from `mkdir` alone), unsets `DVDCSS_CACHE` rather than leaving it
pointing somewhere unusable, and logs which of those happened. It also logs the
entry count either side of key extraction, so `/tmp/dvd_css.log` distinguishes
"the cache is not being written" from "it is being written but not read back".

**CSS key cache — legal guardrail.** Recovered keys are cached at
`/media/fat/dvdcss/cache` (device-local, runtime-generated). Caching adds no legal
exposure beyond the decryption itself — it is the standard `DVDCSS_CACHE` behaviour VLC
et al. use, the keys are disc-specific and re-derivable from media the user owns, and the
cache is never handed to anyone. The one hard rule: **a populated key cache must never be
committed to the repo, bundled in a release, or uploaded** — *distributing* CSS keys is
the genuinely fraught act (cf. the AACS "09 F9" case). The cache lives on the SD card,
nowhere near the repo, so this holds by construction; keep it that way.

## Drive region tool (`main/Scripts/set_dvd_region.sh`)

A drive with **no region set** refuses the CSS title-key ioctl, so libdvdcss cracks every
key from the data — the multi-second wait `dvd_css.cpp` surfaces as
`No drive region: cracking`. Setting the drive's region removes that wait for physical
discs (an encrypted *ISO* always cracks, so it is unaffected). The tool reads the state and
optionally sets it, from the MiSTer itself.

**Why a script and not part of the Main:** it is a once-per-drive administrative act, not
part of playback, and it must be usable *before* deciding to buy into the `[DVD] main=`
setup at all. The Scripts menu is where MiSTer puts exactly this kind of thing, and it is
already how `install_dvdcss.sh` ships.

**Mechanism.** One ioctl, `DVD_AUTH` (`0x5392`, `linux/cdrom.h`), which the kernel turns
into the SCSI REPORT KEY / SEND KEY commands for RPC state:

| | value | struct |
|---|---|---|
| read  | `DVD_LU_SEND_RPC_STATE` = **10** | `{type:2, vra:3, ucca:3, region_mask, rpc_scheme}` — 3 bytes, bitfields packed from the low end |
| write | `DVD_HOST_SEND_RPC_STATE` = **11** | `{type, pdrc}` — `pdrc` is the region, 1–8 |

`sizeof(dvd_authinfo)` is 16. `region_mask` has a **clear** bit per playable region, so
`0xff` = no region set (the same test `dvd_css.cpp:drive_region_set()` already makes over
SG_IO). The read also returns `ucca` (user changes remaining) and `vra` (vendor resets),
which is what lets the tool state the cost before spending it. `rpc_scheme == 0` means an
RPC-1 (region-free) drive — nothing to set.

No compiled helper is needed: `python3` is a stock MiSTer tool (`install_dvdcss.sh` already
depends on it) and `fcntl.ioctl` covers this.

**Why the UI is a cursor menu.** A Scripts-menu script is launched by handing its bare path
to `agetty` (`menu.cpp`, `MENU_SCRIPTS_FB`), so **it can never receive arguments** — an
argument interface only works over SSH. Input does work, though: the launcher calls
`video_fb_enable(1)` first, and MiSTer's `input.cpp` (`else if (video_fb_state())`) injects
real uinput **keyboard** events from a gamepad — D-pad → arrows, B1 → Enter, B2 → Esc,
B3 → Space, B4 → Tab, L/R → PgUp/PgDn. There are **no digits or letters** in that mapping,
which rules out any typed prompt; hence menus only. Consequences baked into the script:

- The python payload is written to a temp **file**, not fed to `python3` on stdin — stdin is
  the console the menu is read from, and a `python3 - <<EOF` heredoc would consume it.
- With `fb_terminal=0` in MiSTer.ini the Scripts menu uses the OSD runner instead
  (`popen(..., "r")`) — output only, **no stdin at all**. The script detects a non-tty stdin
  and degrades to printing status rather than blocking on input nobody can give.
- Esc needs a ~50 ms timeout to be told apart from the start of an arrow's CSI sequence.
- ★ **Every exit waits for a keypress, and it has to.** `MENU_SCRIPTS_FB2` ignores key
  events while the script's process lives, then tears the framebuffer terminal down on the
  first key **RELEASE** after it is reaped. A script that finishes inside the duration of
  the press that confirmed it therefore has its last screen erased *by that press* — which
  is issue #52's "spit out an error and exited faster than I could read it". Staying alive
  until a **fresh** press spends that release on the pause instead. The pause drains
  buffered input (auto-repeat included) for up to 2 s before waiting, or it dismisses
  itself. This applies to any Scripts tool that prints a verdict and returns, not just
  this one.

**Safety, because a region change is irreversible.** There is no un-set: MMC has no "clear
region" command, the code field is 1–8 with no none value, each set spends one of ~5 user
changes, and at zero the drive is locked to the last region. So the entry menu's cursor
starts on *Cancel*, selecting a region leads to a confirm screen whose cursor starts on
*No*, the last-change case gets an explicit "locked forever" warning, and a drive already at
`ucca == 0` is never offered the menu at all. Over SSH the same rules apply, with `--yes`
required to skip the confirm.

Only regions **1–6** are offered, in the menu and the argument form alike. 7 is unassigned
and 8 is international venues (aircraft, cruise ships), so no disc a user owns carries
either — offering them only creates a way to spend a permanent change for nothing. They
stay in the naming table so a drive that already reports one is still described correctly.

**More than one drive.** Only the first `/dev/srN` is ever touched. When others are
present the tool says so and lists every drive with its current region, marking the one it
will act on — reading the others is harmless, and "which drive am I about to change?" is
otherwise unanswerable for an act that cannot be undone. A picker was considered and not
built: the drives are told apart by device node, which says nothing about which physical
unit it is, so connecting only the target drive is the reliable habit and the warning
nudges toward it.

**Reporting a change, after issue #52 (2026-09-04).** The reporter's LG GS40N *took* the
region — Windows confirmed it afterwards — and the script called it an error. Two causes,
and the durable rule they share is that **a failure to read the region back is not a failure
to set it**: the SEND KEY either succeeded or it did not, and everything after it is
reporting.

- `apply_region()` re-read the drive with no `try` at all. A drive answers the command after
  SEND KEY with a unit attention (its RPC state just changed), so that read raising is
  *normal*, and it produced an uncaught Python traceback.
- Even when it answered, `region_mask` can lag the change, so the old code's
  `region == want` test printed "the drive did not take the change" about a drive that had.

Now: the change is issued once and only once; verification re-opens the device (cheapest way
to clear the unit attention) and retries 6 × 0.5 s, swallowing `OSError` between tries; a
confirmed read says "Done"; an unconfirmed one says the change was **accepted but not yet
reported**, tells the user not to repeat it, and exits **3** (distinct from the usage code 2
and the genuine rejection code 1). Only `set_region()` itself raising is reported as a
failure. A top-level handler turns any other exception into one line plus a logged
traceback, because a traceback on a television scrolls the useful part off the screen.

Also added for the next second-hand report: the status screen shows the **raw 3 RPC bytes**
and decodes `rpc_scheme`/`type` (`RPC state : b0 ff 01   (RPC-2, region not set)`), and every
printed line is appended to `/media/fat/DVD_reports/set_dvd_region.log` (or `/tmp` if that
directory does not exist). `type` is a second, independent "is a region set" signal that does
not depend on the mask having refreshed.

**Testing.** The ioctl itself cannot be tested without a drive; everything guarding it can,
and that is where the damage would be. `tools/test_set_dvd_region.py` fakes the drive
(`DVD_REGION_FAKE=<region>:<changes>:<resets>:<scheme>[:<fault>]`, honoured by the script)
and drives the menus through a pty using the exact key sequences MiSTer sends for a gamepad —
21 scenarios, including "a stray B1 on entry changes nothing" and "the confirm defaults to
No". The `<fault>` field reproduces what a real drive does around a change: `rbfail` (every
read after the change raises), `stale` (the mask keeps reporting the old region) and
`setfail` (the change itself refuses) — of which **only the last may be reported as a
failure**. `SET_DVD_REGION_SH=<path>` points the suite at another copy of the script, which
is how the issue-52 checks were proven RED against the pre-fix version. The suite is
**mutation-checked**: five targeted mutations (unguarded read-back, no pause, unconfirmed
called a failure, raw bytes dropped, RPC-1 treated as unset) are each caught by their own
scenario — these are string assertions on console output, exactly the shape that passes
without proving anything.

The **read** ioctl and the gamepad-driven console were ✅ **HW-CONFIRMED 2026-08-31**; the
**set** ioctl is ✅ **FIELD-CONFIRMED 2026-09-04** by issue #52 — the change reached the drive
and stuck, which is the one part of this tool nobody could gate locally without spending a
permanent change.

## HW status / open items

**HW CONFIRMED (2026-08-29):** on the DE10-Nano — physical disc (no-region-drive cracking +
progress, cached keys, unencrypted playback) **and encrypted ISOs** (crack + play; keys
cached). Two bugs were fixed between first test and success: the storage-relative mount
path (`getFullPath`) and the scramble gate (trust `dvdcss_is_scrambled`) — see above.
Note: an encrypted **ISO** cracks noticeably FASTER than a no-region physical disc — CSS
cracking is seek-heavy and an image's random I/O beats optical seek latency — so the ISO
message is "Decrypting ISO" (no "slow"; the drive path keeps "No drive region: cracking").

Remaining:

1. **Region-mismatch cracking message (Q2):** a regioned drive playing a disc from a
   *different* region cracks (the drive refuses the title-key ioctl, libdvdcss falls back)
   — but the message still says "Preparing disc" because a region *is* set. To warn
   correctly, compare the disc's region-management byte (`READ DVD STRUCTURE` copyright RMI)
   against the drive's set region (`REPORT KEY` RPC state) and show the cracking text on a
   mismatch. Needs a region-mismatched disc to verify — a second drive set to a region the
   local library does **not** match is the practical rig (see item 2).
2. **`set_dvd_region.sh` on hardware — ✅ READ HW-CONFIRMED 2026-08-31, ✅ SET
   FIELD-CONFIRMED 2026-09-04 (issue #52).** Read: run from the Scripts menu and driven with
   a **gamepad**, with one drive connected and with two — regions read correctly (an unset
   drive and a region-1 drive each identified), and the multi-drive warning listed both.
   That confirmed the `DVD_AUTH` read, drive enumeration, and the uinput key injection on
   tty2, which was the design's riskiest assumption. Write: a user set region on an LG GS40N
   from the Scripts menu and a PC confirmed the drive was locked to it — so
   `DVD_HOST_SEND_RPC_STATE` reaches the drive and sticks. The *reporting* around it was
   wrong and is fixed above; what remains ungated is only the **happy read-back path** (a
   drive that answers immediately with the new region), which cannot be gated without
   spending another permanent change and is not worth one.
   A **set is one-way and spends one of the drive's ~5 permanent changes**. Bench plan for
   the Q2 rig is still three drives — one left unset (keeps the `No drive region: cracking`
   path testable, which a set would destroy forever), one matching the local library, one
   deliberately mismatched. `DVDCSS_METHOD=title` forces the crack path on any drive if the
   physical unset state is not available.
3. **Eject → idle reset (just added):** confirm the `status[0]` pulse returns to the idle
   logo cleanly and a subsequent insert plays.
4. **Drive lifecycle across re-exec:** confirm `/dev/srN` is free for our Main to re-open.
5. **libdvdcss-absent fallback:** confirm `CSS ENCRYPTED` still triggers (disc **and** ISO)
   when libdvdcss is missing.
6. **Then** fold physical-disc + encrypted-ISO + libdvdcss into the top-level `README.md`
   "What works" and drop the "CSS is not handled in-core" limitation — only once HW-confirmed.
