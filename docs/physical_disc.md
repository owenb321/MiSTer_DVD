# Physical DVD playback (custom Main + CSS)

Status: **✅ SHIPPED in v0.2.0** (PR #20, 2026-08-30) — physical disc and encrypted ISO
both HW-confirmed on the DE10-Nano. Later fixes are recorded in their own sections below;
the most recent is the VOB-start title-key seek (PR #104, HW-confirmed 2026-09-17).

*(This header read "🔧 in progress ... not yet built or HW-tested", naming the long-merged
`feature/physical-disc-css` branch, until 2026-09-17 — a stale marker on shipped work, the
exact class CLAUDE.md says to fix on sight.)*

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
| `support/dvd/dvd_vcd_detect.cpp/.h` | Same `READ(10)` PVD + root-dir walk, looking for `MPEGAV/`/`MPEG2/` instead of `VIDEO_TS` — recognises a Video CD / Super Video CD. |
| `support/dvd/dvd_vcd.cpp/.h` | Physical VCD/SVCD source: own TOC read (`CDROMREADTOC*`) to find the data track, `SCSI READ CD (0xBE)` for raw 2352-byte sectors, `dvd_vcd_read()` — no decryption, no libdvdcss dependency. See "Video CD / Super Video CD" below. |
| `support/dvd/dvd_phys.cpp/.h` | **New, standalone.** Replaces the fork's launcher trigger: polls `/dev/srN`, mounts a DVD-Video via `user_io_file_mount(DVD_PHYS_SENTINEL)` (or a VCD/SVCD via `DVD_PHYS_VCD_SENTINEL`) on insert; on eject, unmounts **and** pulses `user_io_status_set("[0]", 1)` (the core's OSD-reset → unload + VM reset → idle logo) so a removed disc doesn't freeze the last frame. |
| `Scripts/install_dvdcss.sh` | User-run installer for a prebuilt armhf libdvdcss → `/media/fat/dvdcss/libdvdcss.so.2`. |
| `integration/` | `INTEGRATION.md` (the `user_io.cpp` edits + `-ldl`) and `apply_integration.py` (anchored, idempotent patcher). |
| `build_main.sh` | Fetch pinned stock Main, apply overlay, patch, build `MiSTer_DVDcss`. |

## Region / CSS edge cases handled (from the fork's dvd_css)

- **No drive region (RPC-II):** SG_IO REPORT KEY reports `region_mask == 0xff`; libdvdcss
  falls back to statistical cracking. Shown on screen as `No drive region: cracking`.
  ⚠ **An RPC-1 drive reports the same empty mask and means the opposite** — it enforces no
  region at all and answers the key exchange whatever the disc's region. `drive_region_set()`
  read only the mask until 2026-09-04, so a region-free drive (the best case there is) was
  labelled `No drive region: cracking` and logged as having no region set. The verdict now
  also passes on `rpc_scheme == 0` (REPORT KEY byte 6).
  ⏳ **The RPC-1 arm is UNGATED and cannot be gated here — every local drive reports RPC-2**
  (the new arm is unreachable on them by construction). What WAS re-checked on hardware
  2026-09-04 is the arm that could regress: an RPC-2 drive with no region set still cracks
  and still says `No drive region: cracking`. The blast radius is one message: `region_set`
  feeds the progress text and the log, never a code path, and a degenerate REPORT KEY reply
  (status 0, buffer left zeroed) already read as "set" under the mask-only test, so the new
  term adds no new way to be wrong. To gate it, a region-free drive is needed — the updated
  `set_dvd_region.sh` names one on sight (`RPC state` third byte `00`), so a user can say so
  without owning any of this.
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

## Video CD / Super Video CD

Status: **sim/host-proven, ⏳ HW-confirm pending** (branch `feature/vcd-svcd-physical`).
Extends physical-disc playback to VCD/SVCD, on the exact same optical drive
`dvd_phys.cpp` already scans for DVD-Video.

**This needed zero RTL changes.** The rip-image VCD/SVCD feature
(`docs/vcd_svcd.md`) already made `dvd_iso_reader.sv` auto-detect a raw
MODE2/2352 CD image purely by content — the 12-byte CD sync pattern at file
byte 0 — with no dependence on how those bytes got there. A physical VCD/SVCD
source just has to hand the FPGA that same raw byte stream, sync pattern
intact, starting at the disc's data track. Everything new is HPS-side:

- **`dvd_vcd_detect.cpp`** — the same `READ(10)` PVD + root-directory walk as
  `dvd_video_probe()`, checked SECOND (after DVD-Video is ruled out), looking
  for `MPEGAV/` (VCD 2.0) or `MPEG2/` (SVCD) instead of `VIDEO_TS` — the
  directories that actually hold playable MPEG streams, as opposed to `VCD/`/
  `SVCD/` (metadata only) or `SEGMENT/` (still menus, not played).
- **`dvd_vcd.cpp`** — finds the disc's first DATA track via `CDROMREADTOCHDR`/
  `CDROMREADTOCENTRY` (a hybrid disc's later CD-DA audio tracks, or a
  multi-movie VCD's later data tracks, are not played — the same one-track
  limitation a rip-image mount already has, since that requires picking one
  `.bin` file), then reads raw sectors with SCSI **READ CD (`0xBE`)**.

**No decryption, no region, no libdvdcss dependency at all** — VCD/SVCD carry
no protection of any kind, so this module never touches `dvd_css.*`. It keeps
its own persistent drive handle (`dvd_vcd_open()`/`dvd_vcd_close()`, mirroring
`dvd_css_open()`/`dvd_css_close()`'s shape exactly, including the "closed on
remount" rule at `sd_type[index] == SD_TYPE_VCD`) and mounts through its own
sentinel, `DVD_PHYS_VCD_SENTINEL`, dispatched from `dvd_phys.cpp`'s existing
probe/mount state machine — the same `mounted`/`foreign`/`probed_unrecognized`
flags, the same insertion-edge and MGL-busy gating, the same eject teardown
(now closing whichever of `dvd_css`/`dvd_vcd` is actually open).

★ **`READ CD`'s flag byte is the one thing that had to differ from the
CD-DA precedent** (the shelved `feature/cdda-physical` branch's
`dvd_cdda.cpp`, whose `scsi_read_cd()` this module's is adapted from). CD-DA
requests `cdb[9]=0x10` ("user data only"), which for a CD-DA sector IS the
whole 2352 bytes — there is no header structure to a Red Book audio frame. A
VCD/SVCD data track is Mode 2, where "user data" is a SUBSET of the raw
sector: `dvd_iso_reader.sv`'s detector reads the sync pattern (bytes 0-11)
and the mode/submode bytes (offsets 15/18), all of which sit in the sync/
header/subheader region, not user data. So this module requests
`cdb[9]=0xF8` (Sync + full header, meaning header AND subheader + user data +
EDC/ECC) — the complete 2352-byte raw sector, byte-for-byte what a `.bin` rip
already contains — and `cdb[1]=0x00` ("expected sector type: any"), since a
VCD/SVCD data track mixes Mode 2 Form 1 (filesystem) and Form 2 (MPEG
payload) sectors, unlike CD-DA's single uniform type.

⚠ **The exact `READ CD` byte values are the one thing sim/host tests cannot
verify** — `dvd_vcd_test.cpp`'s synthetic-disc byte-assembly checks exercise
the surrounding arithmetic (burst sizing, the track-boundary clamp, the
EOF zero-fill) against a fake `read_frames()` that never issues the real
SCSI command; whether a real drive answers `0xBE`/`0x00`/`0xF8` the way the
MMC spec says is necessarily an HW-only gate. Watch this line first if a
real disc plays back scrambled/misdetected.

Host tests: `main/tests/dvd_vcd_test.cpp` (ISO9660 probe, TOC track
selection, and `dvd_vcd_read()`'s byte assembly against a synthetic disc
where every byte is a pure function of disc LBA/offset — the same
byte-traceable-disc instrument `dvd_cdda_test.cpp` used) plus new dispatch
arms in `dvd_phys_test.cpp`. 6 RED mutations, each caught by its own arm.
Full cross-compile proven: `USE_DOCKER=1 main/build_main.sh` links cleanly
(catching, among other things, a missing `<limits.h>` for `CDSL_CURRENT`'s
`INT_MAX` — the same gotcha `dvd_phys.cpp` already carries a comment about,
invisible to a host `g++` smoke test since glibc pulls it in transitively
there). Integration: `main/integration/INTEGRATION.md` "Steps 43-47".

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
| Video CD / SVCD | yes | no (`VCD/`, `MPEGAV/`) | **yes — via `dvd_vcd_probe()`, a second module; see below** |
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

## A title key is asked for at a VOB START, never at the read position

**Field report 2026-09-17:** on a physical *Land Before Time* DVD, Prev/Next Chapter
froze the whole machine for a few minutes and then played the chapter. **Reproduced by
the maintainer on their own copy**, on a drive with no region set — the mount is slow
(the pre-crack), each chapter seek ~10 s, **and new key files appear in the dvdcss cache
as the seeks happen**. That last observation is the decisive one: it was cracking a title
key at every skip.

**Cause.** `dvd_css_read()` fired `DVDCSS_SEEK_KEY` on *any* discontinuity, at the
**arbitrary target LBA**:

```c
if (vi != cur_vob || (int)lba != css_pos) p_seek(css, (int)lba, DVDCSS_SEEK_KEY);
```

and its comment claimed that was "a fast cached lookup now". It is not.

★★ **libdvdcss matches its title cache on the EXACT start LBA — MEASURED, not recalled.**
In the shipped `libdvdcss.so.2` (1.6.0) `_dvdcss_title` is inlined into `dvdcss_seek`; the
lookup is a list walk followed by an **equality** test, not a range test:

```asm
8298:  mov  0x48(%r13),%rax   ; rax = dvdcss->p_titles
82b0:  cmp  (%rax),%ebx       ; p_next->i_startlba  vs  i_block
82b4:  mov  %rax,%rdx
82b7:  mov  0x10(%rax),%rax   ; p_title = p_title->p_next
82c0:  cmp  (%rdx),%ebx       ; p_title->i_startlba vs i_block
82c2:  je   8822              ; EQUAL -> hit: copy the 5-byte key, skip acquisition
82c8:  ...                    ; otherwise the file cache ("%.10x" of the block), then acquire
```

The struct offsets match `dvd_title_t` (`i_startlba` at 0, `p_next` at 0x10), and the
on-disk cache agrees — one file per block, **named `"%.10x"` of the block number**, which
is why the maintainer could watch it grow one entry per seek.

`crack_title_keys()` only ever primes `g_vobs[i].start`, so **every chapter start missed
and re-acquired**. With no drive region that is the full statistical crack, on the thread
that also serves the core's SD blocks — hence the machine freezing, not just the picture.
⚠ Linear playback never tripped it (`lba == css_pos` every sector), which is exactly why
it only ever showed on a seek and why it survived every hardware round until now.

**libdvdread is the oracle, and we were the deviation** (`dvd_repos/libdvdread`):
`initAllCSSKeys()` primes one key per VOB **file**, at the file's start — structurally
identical to `crack_title_keys()` — and `DVDReadBlocks()` re-keys **only when the file
changes**, always at `dvd_file->lb_start`, **never at the read offset**:

```c
  /* Hack, and it will still fail for multiple opens in a threaded app ! */
  if( dvd->css_title != dvd_file->css_title ) {
      dvd->css_title = dvd_file->css_title;
    if( dvd->isImageFile ) dvdinput_title( dvd->dev, (int)dvd_file->lb_start );
  }
```

★ So one key per VOB file is the whole stack's model, not something this fix introduces —
and it is already what uninterrupted linear playback here relied on. libdvdread is in fact
*coarser*: its loop only primes `VTS_NN_0.VOB` and `VTS_NN_1.VOB` before breaking, so it
uses one key for all five parts of a 4.7 GB VTS where we key each part.

**Fix.** `if (vi != cur_vob)` → `SEEK_KEY` at `g_vobs[vi].start`, then a plain `NOFLAGS`
seek to the target. Any seek anywhere in a VOB is now free.

⛔ **Pre-cracking more blocks is the WRONG lever and was considered and rejected.** The
cache is keyed by exact block, so it would mean enumerating every block anyone might seek
to — chapter starts are knowable from the IFO, but scrub-release, D-pad seek, A-B repeat
loop-back, menu → resume jumps and the `S_NAV_SEEK` probe landing all go to arbitrary
blocks. It would fix B2/B3, *look* fixed, and leave the scrub bar exactly as broken. It
would also multiply mount time by the number of blocks primed.

⛔ **Deriving title keys from the disc key does not help either, and this is worth
recording because it sounds like it should.** That *is* libdvdcss's default method
(`DVDCSS_METHOD_KEY`: authenticate → `ReadDiscKey` → per title `ReadTitleKey` →
decrypt with the disc key), and when it works every key is instant. But the input it
needs — the *encrypted* title key — lives in the physical sector's CPR_MAI header, which
a normal `READ(10)` does not return; the only way to get it is the `ReadTitleKey` ioctl,
**which is precisely what an RPC-II drive with no region set refuses** (libdvdcss:
`ioctl ReadTitleKey failed (region mismatch?)` → `failed to decrypt the disc key, faulty
drive/kernel? cracking title keys instead`). So on the affected drives the disc key is
not the missing piece, and on unaffected drives there is nothing to fix. Setting the
drive region is what buys the fast path — see the tool below; this fix reduces **how
often** the slow path is taken, from every seek to once per VOB per disc, ever.

★ **Second, pre-existing defect found en route.** On a failed key seek the old code set a
*local* `decrypt = 0` for that read while still advancing `cur_vob`, so the **next**
sequential read re-entered with `decrypt = 1`, skipped the seek block entirely
(`lba == css_pos`), and decrypted with a key that had never been obtained — garbage for
the rest of the VOB instead of the intended raw-read fallback. The verdict is latched in
`key_ok` now.

**Gate: `main/tests/run_tests.sh --red`**, arms `[1]`–`[8]` of `dvd_css_test.cpp` plus
four mutations, each caught by its own assertion — `css-rekey-every-seek` (restores the
shipped behaviour: 17 keys acquired over 17 chapter skips), `css-key-at-read-lba`,
`css-key-verdict-not-latched`, and `css-never-keys`, the control that stops the fix
over-reaching into "never ask for a key at all". ★ The fake `p_seek` models libdvdcss's
cache the way it actually behaves — a `SEEK_KEY` at a block never asked for before *costs
an acquisition and is then cached* — so the test measures what the user experiences (keys
cracked), never a signal the fix names. ⚠ The test cannot be compiled against the true
pre-fix file (it resets `key_ok`, which did not exist), so the RED arm restores the
behaviour by mutation rather than checking the old file out of git; that is weaker than
the usual R0 arm and is called out in the test header.

✅ **HW-CONFIRMED 2026-09-17 on the reported disc** (maintainer, region-less drive):
*"no additional keys cached and the seeks are quick now"* — both halves of the claim, and
the first of them is a COUNT rather than an impression, which is what makes it evidence.

★ **The instrument is the cache directory, not a stopwatch.** After the mount's pre-crack
the count must not change again, however far you skip: `crack_title_keys()` primes all 23
of this disc's VOBs, and a key is now only ever requested at one of those blocks. Stronger
still, the filenames ARE the block number in hex, so every entry can be checked against
the VOB start list — an entry outside it is a key we should not have asked for.

⚠⚠ **The cache is PERSISTENT AND PER-DISC, so it must be cleared before each arm.** Every
chapter already visited is already cached, so a *pre-fix* build measures as fixed and the
test passes on both — the "step that never reached the state" failure, in a form that
looks like success. Remove only that disc's subdirectory (`rm -rf
/media/fat/dvdcss/cache/<disc>`), and expect the next mount to be slow on BOTH builds:
that is the 23-VOB pre-crack, not the bug.

⚠ **Not chapter 1.** Its cell starts at RBN 0, which IS `VTS_01_1.VOB`'s own start LBA
(614926), so it is primed at mount and even the broken build never cracks there. Chapters
2 and up are the test.

## Every VOB must be in the table (issue #112)

✅ **FIXED and HW-CONFIRMED 2026-09-19** (branch `fix/css-vob-table`). **Field report:**
the physical *OZ: The Great and Powerful* DVD (Blu-ray combo pack) showed green garbage
and `CSS ENCRYPTED` right after the language menu. The MakeMKV ISO of the same disc
played cleanly.

**Cause.** `g_vobs[]` held **64** entries, and `collect_vobs()` dropped the rest silently.
A VOB missing from the table makes `vob_index()` return −1, so `dvd_css_read()` treats its
sectors as filesystem data and reads them **raw**. The core then really does receive
scrambled sectors, which makes the banner a true positive. The disc lists **91** `.VOB`
entries because it files **one 7-part feature extent under 11 title sets** (VTS_08..18
all point at the same LBAs, which is also why `dvdbackup` "copies more than the disc
holds" on it). The sneak peeks in VTS_20, played right after the language menu, sorted
past entry 64. `/tmp/dvdcss.log` read `64 VOBs, 64 title keys`.

**Fix.**
- Collapse identical `{start, nsec}` entries: an alias is the same sectors under the same
  key, so it adds nothing. 91 entries become 21 on this disc.
- Size the table for a spec-maximum disc: 99 title sets × (menu + 9 parts) + VMG = 991
  VOBs, so `MAX_VOBS 1024` (8 KB).
- Log any drop, never truncate silently.

Gate: `main/tests/run_tests.sh --red`, arms [9]–[11]. Arm [9] is the disc's real 91-entry
layout. The shipped table (`css-vob-table-shipped`) fails it on VTS_20 and nowhere
earlier.

⛔ **Ruled out by measurement; do not re-derive.** The first theory was that the title
key was taken inside the protection zone at the feature VOB's start, giving a zero key
(libdvdcss's cracker gives up on unencrypted or non-pack blocks and reports an
"unencrypted title"). But the cached feature key is non-zero (`c1:62:e1:44:3e`), and it
came out identical from all 7 part starts. And sectors decrypted through libdvdcss with a
key taken **at the VOB start** are **byte-identical** to the MakeMKV ISO, at cell 0 and
mid-film. Keying at the VOB start is correct here.

★ **The measurement recipe (reusable).**
1. Compare `/tmp/dvdcss.log`'s VOB count with the disc's `.VOB` entry count.
2. Read the per-disc key files under `/media/fat/dvdcss/cache/<disc>/` (file name = the
   key block in hex; content `00:00:00:00:00` = a zero key).
3. Decrypt a few hundred sectors on the MiSTer with python `ctypes` against the installed
   `libdvdcss.so.2`, pointing `DVDCSS_CACHE` at that cache, and `cmp` them against a
   known-good rip.

✅ **FIXED 2026-09-19, HW-CONFIRMED: the protection zone is never read.** On this disc, sectors from
about RBN 2000 of `VTS_08_1.VOB` are deliberately unreadable: each read returns
`03/11/00` after roughly 30 s of drive retries, with the Main blocked in state D. MakeMKV
fills them with `0xEF`, so an ISO never hangs. No real PGC cell starts before RBN 4112.
VTS_08's PGCN 1 is malformed: 72 cells, `cell_playback_offset = 0`, and 12 pre / 9 post
commands.
- **Disc Menus off:** Auto picks VTS_08 PGCN 1, and `S_PGC_CELLCHK` sends a cell-less
  title PGC to the `S_FINAL2` linear whole-VTS fallback, which streams from RBN 0 into the
  zone.
- **Disc Menus on:** the stub's own PRE bounces to a menu (`CallSS VMGM pgc 2`), yet it
  was still seen once (2026-09-19) by a road not yet identified.

**Fix (reader, not the Main):** Auto no longer falls to the linear whole-VTS stream
while another PGC exists, and it now plays the LONGEST PGC rather than PGCN 1. See
`docs/dvd_nav.md`. HW: the seek log goes straight from the IFO to RBN 4112, with zero
drive I/O errors.

★ **The diagnostic that traced it is kept:** `/tmp/dvd_seek.log`, every non-sequential
read logged BEFORE it is issued, armed by the HIL flag file (`/media/fat/dvd_hil`). When
the Main blocks in state D, screenshots and telemetry freeze with it, so this is the only
record of how the core got there.

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
| write | `DVD_HOST_SEND_RPC_STATE` = **11** | `{type, pdrc}` — ⚠ `pdrc` is a region **MASK with one bit CLEAR**, not the region number: region 1 is `0xfe`, region 2 `0xfd`. Same polarity as the `region_mask` the read returns |

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

**Issue #52 (2026-09-04): the change command itself was malformed.** ★★ **`pdrc` is a
region MASK with one bit CLEAR, not the region number.** We sent the number, and as a mask
`0x01` claims *seven* playable regions — so a conforming drive rejects it. MEASURED on the
maintainer's RPC-2 drive with `sg_raw` sending the byte-identical command the kernel builds:

```
sudo sg_raw -v -s 8 -i /tmp/rpc.bin /dev/sr0 a3 00 00 00 00 00 00 00 00 08 06 00
  Sense key: Illegal Request / Additional sense: Invalid field in PARAMETER LIST  (05/26/00)
```

★ **The sense code is what localised it in one shot**: *parameter list*, not *CDB*, so the
command reached the drive and parsed — only byte 4 of the 8-byte payload was wrong. And
`regionset`, which has worked on Linux for twenty years, has always sent the mask:
`regionset.c` computes `~(1 << (n-1))` and `dvd_udf.c:UDFRPCSet()` assigns it straight to
`ai.hrpcs.pdrc`. `region_pdrc()` now does the same.

✅ **The corrected encoding is HW-PROVEN (2026-09-04):** the same `sg_raw` command with byte
4 = `0xfe` returned **Good status** on the drive that had just rejected `0x01`, and set it to
region 1 — one permanent change spent to learn it. ⏳ What that does NOT gate is the
script's own path: it reaches the drive through the `DVD_AUTH` ioctl rather than raw SG_IO,
and the kernel building the identical CDB from it is read from `cdrom.c` (`setup_send_key`
→ `cmd[10] = type | agid<<6`, `cmd[8:9] = buflen = 8`, `buf[1] = 6`, `buf[4] = pdrc`), not
measured. ⚠ **Do not spend the unset drive to close that gap** — it is the only local rig
for the `No drive region: cracking` path, and a set destroys it forever.

★ **Drives differ in what they accept here, which is why this survived so long.** Issue
#52's LG GS40N **took** the plain number — the reporter's change succeeded and a PC confirmed
the drive was regioned; what failed on that drive was only the read-back afterwards (below).
The TSSTcorp rejects the same byte outright. So the number worked by luck on tolerant
firmware, and the mask is the encoding that is actually correct — it is what `regionset` has
always sent, and what a strict drive demands.

**The write goes out over SG_IO, with `DVD_AUTH` as the fallback (2026-09-04).** Both
routes carry byte-identical commands — the kernel builds this exact one from the ioctl
(`cdrom.c`: `setup_send_key`, then `buf[1] = 6`, `buf[4] = pdrc`) — so this is not a
correctness change but an **observability** one: `sr_do_ioctl` funnels every drive refusal
into a bare **`EIO`** (Illegal Request *and* most Not Ready conditions alike), which is
useless when the operation is one-way and the user needs to know why. SG_IO hands the sense
data back, so a refusal now reads `sense 05/26/00 (invalid field in parameter list)` instead
of `Input/output error`. The ioctl remains the fallback for a python without `ctypes` or a
device that refuses SG_IO, so this can only add outcomes, never remove the one that worked.
A `SenseError` is never retried on the other route — the drive explained itself, and a
second send could spend a change.

★★ **AND IT PAID FOR ITSELF IN TWO RUNS. THE DRIVE TAKES ITS NEW REGION FROM THE DISC IN
THE TRAY.** Measured on a TSSTcorp TS-L633C, drive at region 1:

| tray | asked for | answer |
|---|---|---|
| region-1 disc | region 1 | **Good** (this was the PC success) |
| region-1 disc | region 2 | `05/6f/04` media region code is mismatched to logical unit region |
| empty | region 2 | `02/3a/01` medium not present, tray closed |
| disc with RMI `40` (allows 1-6, 8) | region 2 | **Good** — ✅ and this is the end-to-end gate |

That is the Windows model — insert a foreign disc and the OS offers to switch the drive to
match. ★ **The exact rule is that the loaded disc must ALLOW the target region, not that it
name exactly that region**: the fourth row is a multi-region disc (`RMI 40` = every region
but 7) and it satisfied a switch to region 2. Neither "with a disc" nor "without a disc" is
the rule, and neither is "a disc of that region" — *allows* is.

★ **The diagnostic lesson is bigger than the bug, and it bit twice.** The evidence was
"accepted on a PC over SG_IO, refused on the MiSTer over the ioctl", and both variables that
framing offers — route and machine — were **wrong**; the real one was a third nobody had
written down, the disc in the tray. Then the first correction was wrong TOO ("take the disc
out"), because a single new data point (`6f/04`) was read as the whole rule when it was one
row of a table that needed three. ⚠ When a comparison has two obvious differences, the cause
can still be a third — and one measurement that refutes a hypothesis does not establish its
opposite. Everything before the sense data was inference from `EIO`, which is all the ioctl
route can ever give you.

The script now reads the loaded disc's own region (`READ DVD STRUCTURE` format 1, byte 5 =
Region Management Information, a clear bit per allowed region), shows it beside the drive's
(`Disc in drive  : region 2`), says on the menu that the drive follows the disc, and warns on
the confirm screen when the chosen region is one the loaded disc cannot support — a warning,
not a block, since other drives may not care. `6f/04`, `3a/00`, `3a/01` and `3a/02` are all
named sense codes, so a refusal names which of the two mistakes it was.

⚠⚠ **`DRIVER_SENSE` (0x08) is in the LOW nibble of `driver_status` and means the drive
ANSWERED — sense attached — not that the transport failed.** Reading it as a transport error
cost a hardware round: the board logged `SG_IO status 02 host 00 driver 08 sb_len 18`, i.e.
a Check Condition with 18 bytes of sense sitting right there, and the guard threw it away
and fell back to the ioctl, which could then only say `EIO` — the exact information the
SG_IO route existed to recover. Classification now lives in a pure `sg_check()` precisely so
it can be tested: a synthetic `(status 02, host 00, driver 08, sense 05/26/00)` must decode,
and the mutation that reinstates the bug is caught by it.

`sg_io_hdr` is built with `ctypes`, so it lays itself out for whatever ABI it runs on (88
bytes on x86-64, 64 on the MiSTer's armv7). Both were checked against the C ABI rather than
assumed — the field list reproduces `sizeof`/`offsetof` exactly on x86-64, and the armv7
sizes come from a `_Static_assert` compiled with the MiSTer toolchain's own headers.

**Reporting a change — the defect issue #52 actually hit.** On a drive that accepts the
change, these two are what turn a success into an apparent failure. Both share one durable
rule — **a failure to read the region back is not a failure to set it**: the SEND KEY
either succeeded or it did not, and everything after it is reporting.

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

✅ **THE WHOLE TOOL IS NOW HW-CONFIRMED (2026-09-04), READ AND WRITE.** The read ioctl and
the gamepad-driven console were confirmed 2026-08-31 and again on the rewritten script; the
**write** closed the same day on a TSSTcorp TS-L633C — `route: SG_IO, accepted`,
`verify 0: 51 fd 01`, `Done. The drive is now region 2, with 2 changes left`, `ucca` 3 → 2.
★ Two details worth keeping from that log: the drive answered the read-back **on the first
attempt** (`verify 0`), so the 6 × 0.5 s retry is insurance rather than a routine need; and
`disc_regions()` ran on real iron for the first time, reading `RMI 40` correctly.

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
2. **`set_dvd_region.sh` on hardware — ✅ READ HW-CONFIRMED, ⏳ SET STILL UNGATED.** Read:
   run from the Scripts menu and driven with a **gamepad**, with one drive connected and
   with two — regions read correctly (an unset drive and a region-1 drive each identified),
   the multi-drive warning listed both, and (2026-09-04) the rewritten script reads and
   pauses correctly on the board. That confirms the `DVD_AUTH` read, drive enumeration, and
   the uinput key injection on tty2, which was the design's riskiest assumption.
   **Write: ✅ HW-CONFIRMED 2026-09-04** — the script set a TSSTcorp TS-L633C from region 1
   to region 2 with a disc loaded that allowed region 2, read the new region back on the
   first attempt, and the change counter went 3 → 2. Issue #52's LG GS40N had already set its
   region successfully on the pre-fix script (tolerant firmware, plain number accepted); the
   corrected encoding is what makes strict drives work too.
   A **set is one-way and spends one of the drive's ~5 permanent changes**. Bench plan for
   the Q2 rig is still three drives — one left unset (keeps the `No drive region: cracking`
   path testable, which a set would destroy forever), one matching the local library, one
   deliberately mismatched. `DVDCSS_METHOD=title` forces the crack path on any drive if the
   physical unset state is not available.
3. **RPC-1 message arm ungated (2026-09-04):** `drive_region_set()` now treats
   `rpc_scheme == 0` as "no region needed", but no local drive is RPC-1, so the arm has never
   run. Needs a region-free drive — or a user's report, since `set_dvd_region.sh` now prints
   the scheme byte. Expected on such a drive: `Preparing disc` instead of
   `No drive region: cracking`, no "RPC-II with NO region set" line in `/tmp/dvdcss.log`, and
   — the falsifiable part — keys actually arriving fast with the cache cleared. If it still
   crawls VOB by VOB, key the message on measured key-fetch behaviour rather than the RPC
   bits.
4. **Eject → idle reset (just added):** confirm the `status[0]` pulse returns to the idle
   logo cleanly and a subsequent insert plays.
5. **Drive lifecycle across re-exec:** confirm `/dev/srN` is free for our Main to re-open.
6. **libdvdcss-absent fallback:** confirm `CSS ENCRYPTED` still triggers (disc **and** ISO)
   when libdvdcss is missing.
7. **Then** fold physical-disc + encrypted-ISO + libdvdcss into the top-level `README.md`
   "What works" and drop the "CSS is not handled in-core" limitation — only once HW-confirmed.
