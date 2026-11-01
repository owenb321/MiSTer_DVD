---
name: release-smoke
description: Smoke-test a DRAFT GitHub release of the DVD core on the real MiSTer before it is published — verify the draft's own assets, flash them, check every new feature in the release, and run the regression sweep (format matrix, audio, pacing, interactive-disc suite) against a control build. Produces a GO / NO-GO report. Use at step 6 of the release skill, or whenever asked to smoke-test, sanity-check or regression-test a release or release candidate.
---

# Release smoke test

The release skill's step 6 ("flash it, confirm it boots, mounts a disc and plays") is the
last gate before a build reaches every user, and it used to be done by eye. This skill makes
it a measurement: **what the draft ships, flashed from the draft, checked against a control
build, written down.**

The tools all exist already. This skill fixes **which** of them run, **on what**, and
**in what order**, so two releases are tested the same way. The operating manual for each
tool, and the traps that cost real hardware time, are in `.claude/skills/hil-testing/` —
**read it first**; this skill does not repeat it.

## Rules

- **Test the draft's assets, never the local build.** Download them from the draft. The
  point is to catch what CI packaged — a Main built from the wrong commit, an `.rbf` that
  is not the one the manifest names, a zip missing a file. A local `releases/*.rbf` that
  "is the same build" proves none of that.
- **Every check has a control.** Run the same check on the control build (below) whenever
  the result could be the disc or the harness rather than the core. A FAIL that the control
  shares is a pre-existing issue to note, not a release blocker; a FAIL the control does not
  share is a **regression** and blocks the release.
- **NODATA is not PASS.** A missing image, an absent capture card, a field the core does not
  carry: write NODATA with the reason. A check that silently did not run is how a broken
  release ships.
- **The rig belongs to the maintainer.** Ask before starting ("the smoke test takes the rig
  for ~90 min"), say which rig (`tools/.mister_rigs.json`; only the one with `capture: true`
  can run the audio and capture checks), and **`tools/mister.py restore` at the end**,
  whatever the outcome.
- **Never publish from this skill.** It ends with a report and a recommendation. Publishing
  (`gh release edit --draft=false`) is the maintainer's call, made after reading it.

## 0. Inputs

```bash
export GH_TOKEN=$(printf "host=github.com\nprotocol=https\n\n" | git credential fill | sed -n 's/^password=//p')
TAG=v<semver>                                   # the draft
PREV=$(gh release view --json tagName -q .tagName)   # the newest PUBLISHED release
OUT=tools/streams/smoke/$TAG                    # gitignored; never /tmp (captures are large)
mkdir -p $OUT/draft $OUT/prev
```

**The control build.** Default: `$PREV`'s `.rbf` and `MiSTer_DVDcss`. But a control must be
*able to fail* each check: if `$PREV` predates an instrument (e.g. it has no nav event FIFO —
anything before PR #179 — so every `hil_suite` FIFO check reads NODATA on it), use for those
checks the newest dev build of `main` from **before the release commit** that carries it
(`releases/*.rbf.json` → `git.sha`, and `git merge-base --is-ancestor` that sha against the
release commit). Name which control each section used in the report.

**The smoke set** — `tools/.smoke_set.json` (gitignored; template in
`tools/smoke_set.example.json`): one image per category, paths relative to the rig's
`share_root`. Rig path = `share_root` + entry. If it does not exist, copy the template,
fill it from the library and tell the maintainer you did. Keep it stable between releases:
**a regression is only visible on the same input.**

## 1. Asset integrity (no rig, ~2 min)

```bash
gh release view $TAG --json isDraft,assets -q '.isDraft, (.assets[].name)'
gh release download $TAG -D $OUT/draft
gh release download $PREV -D $OUT/prev -p 'DVD_*.rbf' -p 'MiSTer_DVDcss'
(cd $OUT/draft && unzip -q MiSTer_DVD_$TAG.zip -d zip && find zip -type f | sort)
```

Check, and record each as a row:

| Check | Pass when |
|---|---|
| All five assets attached | zip, `DVD_YYYYMMDD.rbf`, `.rbf.json`, `MiSTer_DVDcss`, `dvd_report.py` (the set in the release skill; if it changed, follow `.github/workflows/package.yml`) |
| Loose `.rbf` = zip's `.rbf` | `sha256sum` equal (the zip carries it under `_Other/`) |
| Loose `MiSTer_DVDcss` = zip's | `sha256sum` equal |
| Manifest names this `.rbf` | `.rbf.json`: `rbf.sha256` = the file's, `rbf.marginal` false, `timing.pass` true, `git.sha` = the release commit, `git.dirty` false |
| Version | `.rbf.json` `core_version` = `$TAG` |
| `.rbf` compressed | ~4.2 MB. ~7 MB = uncompressed = no video on any output |
| Zip layout | `_Other/DVD_YYYYMMDD.rbf`, `MiSTer_DVDcss` and `DVD_INSTALL.txt` at the root, `Scripts/` with `install_dvdcss.sh`, `set_dvd_region.sh`, `dvd_report.py` (`tools/package_release.sh`) |

Any FAIL here stops the run: the draft is wrong, fix CI or the release commit first.

## 2. Flash the draft (~2 min)

```bash
tools/mister.py deploy --agent --rbf $OUT/draft/zip/_Other/DVD_*.rbf --main $OUT/draft/zip/MiSTer_DVDcss
tools/mister.py state          # main= is the hash-named copy of the DRAFT's Main
```

Flash the **zip's** copies (step 1 proved the loose ones equal). The OSD is not in a
screenshot (hil-testing: screenshots are upstream of the OSD), so the About line
`DVD v<semver> <yymmdd>` is a **maintainer item** (step 7), not something to claim.

## 3. New features in this release

Build this section fresh for every release, from the release notes and the PR list (the
release skill's step 1 already gathered them). For **each** PR in the release, write one
row: *what user-visible claim does the release note make, and which measurement shows it on
the board?* Prefer the PR's own HIL procedure (its test plan, or its `docs/status_log.md`
entry) — it was designed to see that change — re-run on the draft. A claim with no
measurement is a maintainer item, listed as such; never a silent PASS.

Re-running a PR's own HIL on the release is not redundant: features interact on `main`
after each was tested alone, and the release Main is a CI build none of them ran on.

### v0.10.0 (worked example; the mapping a future release copies)

| PR | Claim | Check |
|---|---|---|
| #181/#182 save states | 8 slots, exact landing, menus keep their button | `tools/sstate_stress.py <rig>/<sstate_menu> 30 1 $OUT/sstate_menu` and on `menu_disc` with a film walk (omit `NOFILM`). PASS = 0 `[verdict]`/`[where]`/`[sprm]`/`[gprm]`/`[land]` fails. Control: n/a (new feature) |
| #183 autosave | written at a mount change and a core exit; Load Slot on Autosave restores it | the sequence below |
| #179 cell commands with buttons up | Mad Dog shots land | `hil_suite` covers it (step 5): `mad_dog` rows must PASS on the build |
| #177 drive compatibility | stuck drives eject | needs a USB optical drive on the rig (`tools/mister.py shell ls /dev/sr*`). None → maintainer item: insert a disc, play, press the drive's button: tray opens, core returns to idle; `/tmp/dvd_report.log` has the drive identity line |
| #180 HIL harness | (internal) | none — it is the instrument |

**Autosave sequence** (the PR #183 rig procedure, `docs/nav_engine.md` §11i):

```bash
R=<share_root>; A=$R/<menu_disc>; B=$R/<film_ac3>
tools/mister.py launch "$A" --opt "Disc Menus=On"; sleep 15        # >10 s grace after a mount
tools/mister.py key select; sleep 20                                # into the film, so there is a position
tools/mister.py snap -o $OUT/auto_before.json
tools/mister.py launch "$B"                                         # mount change -> writes A's _auto.ss
tools/mister.py shell 'ls -l --time-style=+%s /media/fat/savestates/DVD/*_auto.ss'
tools/mister.py launch "$A"; sleep 15
tools/mister.py shell "echo 'osd [60:57] 8' > /tmp/dvd_ctl; sleep 0.25; echo 'osd [56] 1' > /tmp/dvd_ctl; sleep 0.3; echo 'osd [56] 0' > /tmp/dvd_ctl"
sleep 5; tools/mister.py log -n 30 | grep -i autosave               # "Loaded autosave"
tools/mister.py snap -o $OUT/auto_after.json                        # same domain/VTS/PGCN; time >= saved
tools/mister.py shell 'echo load_core /media/fat/menu.rbf > /dev/MiSTer_cmd'; sleep 5   # core exit -> rewrites the file
tools/mister.py shell 'ls -l --time-style=+%s /media/fat/savestates/DVD/*_auto.ss'   # mtime moved
```

PASS = file written at the mount change, `Loaded autosave` logged, the snap matches
(domain, VTS, PGCN; title time within [saved−2 s, saved+elapsed+2 s]), mtime moves at the
core exit. The press goes through `/tmp/dvd_ctl` because the harness cannot navigate the
OSD; the Slot row itself is a maintainer item.

## 4. Regression: format and output matrix (~20 min)

For **every** smoke-set entry, draft first, then control for any row that fails:

```bash
tools/mister.py launch "$R/<entry>" --telem-log $OUT/<cat>.jsonl --telem-seconds 60
tools/mister.py shot --decode -o $OUT/<cat>_a.png; sleep 5
tools/mister.py shot --decode -o $OUT/<cat>_b.png
tools/mister.py telem --from $OUT/<cat>.jsonl
```

PASS when:
- the picture is not one of `dvd_explore.py`'s failure colours (green = unwritten
  framestore, grey = misframed intra, all-black = reader wedged) and the two shots differ
  (motion), or telemetry says a menu/still is held (`flags.menu`/`flags.still`);
- `.wav` / CD-DA shows the idle logo with the HUD (not a picture): there, PASS = the HUD
  clock decodes and advances between the shots. It is ~97 % black by design;
- audio is playing: `aud_play` advances across the log;
- no failure popup (`LINK FAIL`, `CSS ENCRYPTED`, unsupported image/audio);
- telemetry: `drops` 0, `lates` ~0 outside a menu/still (`docs/decode_pacing.md` §2c: a
  held still counts one late per refresh).

⚠ **Score counter *increments* from the JSONL yourself; do not trust `telem --from`'s
summary on a `launch --telem-log` file.** Its first row can be a stale sample from before
the core loaded (seen 2026-10-31: `t` ~1000 s before the rest), which turns every rate in
the summary into garbage. Drop a first row more than 30 s before the second.
⚠ **Ignore the JSON's `vid_err`.** Word 5 was retired to `aud_disc` (`dvd/dvd_telem.sv`
header), but `dvd_ctl.cpp` still prints it under the old name; it reads 256, 768, 65280 on
healthy playback.

A scorer that does all of this is the next thing to commit (`tools/smoke_matrix.py`); until
then write it inline, and keep its rules equal to the list above.

**Then the output modes**, on `film_pacing`: `tools/mister.py osd "Video Output=Progressive"`,
`telem --watch 60`; repeat for `Interlaced`. Lates/drops must be ≤ the control's
(census reference: 0, bar one accepted ROGER late on Progressive). Then the transport on
`menu_disc`: chapter next/prev, a d-pad seek, pause/resume, Audio and Subtitle popups
(`subs_many` must step to its last declared stream), Title key, Menu key — each with a
`shot --decode` showing the expected HUD/popup state. Key names: `tools/mister.py options`.

## 5. Regression: interactive discs, audio, navigation (~60–70 min, mostly unattended)

```bash
tools/hil_suite.py run --rbf $OUT/draft/zip/_Other/DVD_*.rbf --control <control.rbf> --out $OUT/hil_suite
for c in film_ac3 film_dts film_lpcm; do tools/audio_check.py "$R/$(jq -r .$c tools/.smoke_set.json)" --secs 6; done
DVD_ISO_DIR=<library> tools/nav_offline.py --library --limit 100 --jobs 8   # no rig; ~40 min
```

- `hil_suite`: 0 REGRESSION rows. It flashes cores only, on the Main deployed in step 2,
  which is the draft's — correct here. ⚠ It leaves the rig on whichever build `--leave`
  names; check `state` afterwards. It runs both builds, so this is where the time goes.
- `audio_check`: every declared track audible (> −80 dBFS) on each disc; DTS needs
  **Decode PCM**. A silent track whose siblings are audible is a decode failure.
- `nav_offline`: 0 `DIFF` / `nolanding` (both are leads); `oracle-err`, `rnd`, `cap-edge`,
  `udf-only` are not findings. ⚠ The whole library (~1,600 images) takes ~11 h at 8 jobs
  (measured 2026-10-31: 125 discs in 50 min), so a smoke test runs `--limit 100`; run it
  alongside `hil_suite`, it needs no rig. A full sweep is for an overnight run, not a gate.

If the rig has no capture card, `hil_suite` capture checks and `audio_check` are NODATA:
say so, and either borrow the capture rig (ask) or list "by ear" as a maintainer item.

## 6. Analog

The capture path is HDMI. Analog (CRT, 15 kHz, composite sync, Analog Dither) cannot be
measured here; if any PR in the release touches `single_raster_analog`, `re_interlace`,
modelines, csync or the dither, it is a maintainer item with the specific thing to look at.

## 7. Maintainer items

List only what the board cannot measure, each with the exact action and what "good" looks
like. Always present:

- OSD About line reads `DVD v<semver> <yymmdd>` (System page).
- The release's new OSD rows look right and do what they say (for v0.10.0: the Save State
  page — appears only with a DVD-Video disc, Slot shows 1–8 + Autosave; PR #182's unchecked
  "OSD page layout eyeballed on hardware").
- By ear: a few minutes of AC-3, DTS and LPCM.
- Anything from steps 3/6 that had no measurement.

## 8. Report and restore

Write `$OUT/report.md` (gitignored), and show it to the maintainer:

```
# Smoke test <TAG> — GO | NO-GO
Draft: <rbf sha256[:16]>, Main <sha256[:8]>, commit <sha>.  Control(s): <which, per section>.  Rig: <name>.
| Section | Check | Draft | Control | Verdict |     (PASS / FAIL / NODATA / pre-existing / REGRESSION)
## Regressions        (blocks publishing)
## Pre-existing       (control shares it; note in the release notes if user-visible)
## NODATA             (why, and what would measure it)
## Maintainer items   (checklist)
```

**GO** = no FAIL in step 1, no REGRESSION anywhere, every new-feature row PASS or an
explicit maintainer item. Anything else is **NO-GO** with the reason in the first line.

Then:

```bash
tools/mister.py restore
tools/mister.py state        # core=MENU? reboot the rig if a harness Main is still running (hil-testing)
```

If the maintainer wants the rig left on the release, `deploy` its `.rbf` and Main
*instead of* restoring, and say so.

## Keeping this skill current

When a release adds a feature with its own HIL procedure, add its row to the step 3 table
pattern (as a new "vX.Y.Z" example only if the mapping is non-obvious), and if it adds a
format or output path, add a smoke-set category to `tools/smoke_set.example.json` **and**
this file's step 4. A regression a smoke test should have caught but did not is a bug in
this skill: write down which step would have seen it.
