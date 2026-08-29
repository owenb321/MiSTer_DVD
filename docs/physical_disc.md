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
| `support/dvd/dvd_phys.cpp/.h` | **New, standalone.** Replaces the fork's launcher trigger: polls `/dev/srN`, mounts a DVD-Video via `user_io_file_mount(DVD_PHYS_SENTINEL)` on insert, unmounts on eject. |
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
needed), so the earlier "does `dvdcss_open()` accept a bare image path" question is
resolved in principle; **HW-verify crack timing/robustness on real encrypted rips**.
Note: `dvd_css` holds a single handle, so physical disc and encrypted ISO are mutually
exclusive (last mount wins) — a non-issue in normal use.

## Open items before HW test

1. **Build** `MiSTer_DVDcss` with the ARM toolchain — **done** (native + Docker; the
   `apply_integration.py` anchors validated against fork `master`, and the encrypted-ISO
   branch confirmed in the patched tree).
2. **Drive lifecycle across re-exec:** confirm `/dev/srN` is free for our Main to re-open
   after any detector (fork or ours) released it.
3. **img_mount signalling from a custom Main:** confirm the mount index/size the core
   expects, matching how ISOs mount today (covers both physical and encrypted-ISO mounts).
4. **Media-change robustness:** eject / swap while playing (`dvd_phys` re-probe/re-key).
5. **Encrypted ISO on HW:** confirm `dvdcss_open()` cracks and plays a real encrypted
   `.iso`; check first-play crack timing and that decrypted ISOs still take the fast path.
6. **libdvdcss path:** code + installer agree on `/media/fat/dvdcss/` — confirm the core's
   `CSS ENCRYPTED` fallback still triggers (disc **and** ISO) when it is absent.
7. **Then** fold physical-disc + encrypted-ISO + libdvdcss into the top-level `README.md`
   "What works" and drop the "CSS is not handled in-core" limitation — only once HW-confirmed.
