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

**CSS key cache — legal guardrail.** Recovered keys are cached at
`/media/fat/dvdcss/cache` (device-local, runtime-generated). Caching adds no legal
exposure beyond the decryption itself — it is the standard `DVDCSS_CACHE` behaviour VLC
et al. use, the keys are disc-specific and re-derivable from media the user owns, and the
cache is never handed to anyone. The one hard rule: **a populated key cache must never be
committed to the repo, bundled in a release, or uploaded** — *distributing* CSS keys is
the genuinely fraught act (cf. the AACS "09 F9" case). The cache lives on the SD card,
nowhere near the repo, so this holds by construction; keep it that way.

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
   mismatch. Needs a region-mismatched disc to verify (easiest: `regionset` the drive to a
   region that mismatches an existing disc, rather than authoring one).
3. **Eject → idle reset (just added):** confirm the `status[0]` pulse returns to the idle
   logo cleanly and a subsequent insert plays.
4. **Drive lifecycle across re-exec:** confirm `/dev/srN` is free for our Main to re-open.
5. **libdvdcss-absent fallback:** confirm `CSS ENCRYPTED` still triggers (disc **and** ISO)
   when libdvdcss is missing.
6. **Then** fold physical-disc + encrypted-ISO + libdvdcss into the top-level `README.md`
   "What works" and drop the "CSS is not handled in-core" limitation — only once HW-confirmed.
