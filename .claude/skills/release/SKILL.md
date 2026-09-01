---
name: release
description: Cut and publish a GitHub release of the MiSTer DVD core — build the timing-clean .rbf and the MiSTer_DVDcss Main, assemble the ready-to-extract zip, gather release notes from every PR merged since the previous release, publish with the right assets, and bump CORE_VERSION. Use when the user asks to cut, make, or publish a release.
---

# Cutting a DVD core release

Publishes a GitHub release for `owenb321/MiSTer_DVD`. Two build outputs (FPGA `.rbf` via
Quartus, `MiSTer_DVDcss` Main via the ARM toolchain) plus a packaged zip, with notes drawn
from the PRs merged since the last release.

## Versioning — semver, with one hard exception

- **`CORE_VERSION` in `dvd/emu.sv` = semver `MAJOR.MINOR.PATCH`** (e.g. `0.2.0`). Shown in
  the OSD as `` v`CORE_VERSION` `BUILD_DATE` ``. Bump it the **moment a release publishes**,
  so no dev build ever advertises a version that already exists on the releases page.
- **Release tag = `v<semver>`** (e.g. `v0.2.0`); title = `v<semver> — <headline>`.
  (This replaces the older `v<version>-<yyyymmdd>` tag format — pure semver now.)
- **Zip = `MiSTer_DVD_v<semver>.zip`** (produced by `tools/package_release.sh`).
- **★ The `.rbf` filename stays `DVD_YYYYMMDD.rbf` — date only, NEVER a version.** This is
  required, not stylistic: MiSTer's core browser and update scripts parse the `YYYYMMDD`
  out of the filename to decide which build is newest. A semver there breaks update
  detection. `build_release.sh --release` already produces this name. Date and semver never
  collide: date lives in the filename (for MiSTer), semver lives in the tag/zip/OSD (for
  humans).
- `BUILD_DATE` (`yymmdd`) is regenerated per compile; do not extend it — it is part of
  `CONF_STR`, so any change re-rolls the fitter seed lottery.

## Preconditions

- On `main`, clean tree, and every feature branch intended for this release is already
  merged (use the `merge` command for any that aren't).
- **The manual matches what is shipping.** `python3 tools/docs_check.py` and
  `mkdocs build --strict` both pass. If a release note would claim something the manual
  does not say, fix the manual first — it is the published contract.
- `CORE_VERSION` is AHEAD of the latest published tag (`gh release list`). If it still
  equals a published version, bump it first and commit.

## gh auth

`gh` is not authenticated by default here — pull the token from git credential (see the
`gh-cli-not-authenticated` memory):

```bash
export GH_TOKEN=$(printf "host=github.com\nprotocol=https\n\n" | git credential fill | sed -n 's/^password=//p')
```

## Steps

1. **Build the core (timing-clean).** Quartus, in the pinned container:
   ```bash
   USE_DOCKER=1 ./build_release.sh --release --compile   # -> releases/DVD_YYYYMMDD.rbf
   ```
   The `--release` gate refuses to pack a timing-marginal netlist. **Never ship a
   `_MARGINAL_` .rbf.** If it comes back marginal, re-roll the seed (`tools/seed_sweep.sh`)
   until clean. (Long compile — run in the background and report the result.)

2. **Build the Main:**
   ```bash
   USE_DOCKER=1 ./main/build_main.sh                      # -> main/.build/MiSTer_DVDcss
   ```

3. **Assemble the package:**
   ```bash
   ./tools/package_release.sh                             # -> releases/MiSTer_DVD_v<ver>.zip
   ```
   It picks the newest non-MARGINAL `DVD_*.rbf` (or pass `--rbf`), bundles the Main and
   both `Scripts/` tools (`install_dvdcss.sh`, `set_dvd_region.sh`), and **prints the exact
   files to attach**.

4. **Draft release notes from the PRs since the last release** (see the section below).

4b. **Reconcile the manual against the notes.** You have just read every PR in the range,
   so this is nearly free. Invoke the `docs-sweep` skill over `<prev_tag>..HEAD`. For each
   PR ask: does it change controls, an OSD option, an on-screen message, install steps, or
   compatibility? Confirm the owning page in `site/content/` is current.

   Then, in the same commit:
   - Update `extra.released_version` in `mkdocs.yml` to the version being cut — it drives
     the "latest release is vX.Y.Z" banner on every page.
   - Update the "Current as of **vX.Y.Z**" line in `site/content/reference/compatibility.md`.
   - Sweep out `!!! info "Unreleased"` admonitions for anything this release ships.

   **Commit these to `main` BEFORE tagging.** The Pages deploy is triggered by that push,
   so the manual goes live as the release is announced rather than after it.

5. **Publish** (attach the zip AND the bare components — most users want only the `.rbf`):
   ```bash
   gh release create v<semver> \
     --title "v<semver> — <headline>" \
     --notes-file /tmp/relnotes.md \
     releases/MiSTer_DVD_v<semver>.zip \
     releases/DVD_YYYYMMDD.rbf \
     main/.build/MiSTer_DVDcss \
     main/Scripts/install_dvdcss.sh \
     main/Scripts/set_dvd_region.sh
   ```
   The `/releases/latest` URL the README links to updates automatically — no README edit
   needed per release.

6. **Bump `CORE_VERSION`** in `dvd/emu.sv` to the next planned version and commit (so the
   next dev build's OSD line is already distinct from what you just shipped).

## Release assets (attach all five)

| Asset | For |
|---|---|
| `MiSTer_DVD_v<semver>.zip` | Complete install — extracts to SD root, drops the installer into the Scripts menu |
| `DVD_YYYYMMDD.rbf` | Core only — ISO-only users (physical disc is opt-in); most people want just this |
| `MiSTer_DVDcss` | Custom Main only — physical discs + encrypted ISOs; needs `[DVD] main=MiSTer_DVDcss` |
| `install_dvdcss.sh` | libdvdcss installer (also inside the zip's `Scripts/`) |
| `set_dvd_region.sh` | DVD drive-region tool — physical-disc users (also inside the zip's `Scripts/`). Documented in `site/content/formats/physical-discs.md`; keep it that way — it shipped as an asset for a release before it appeared in any prose. |

## Release notes from every PR since the previous release

Gather them mechanically so nothing is missed, then organize into human notes:

```bash
# publish time of the current latest release
PREV=$(gh release view --json publishedAt -q .publishedAt)
# every PR merged into main since then, oldest first
gh pr list --state merged --base main --limit 300 \
  --json number,title,mergedAt,author \
  --jq "[.[] | select(.mergedAt > \"$PREV\")] | sort_by(.mergedAt) | .[] | \"- #\(.number) \(.title)\""
```

If a PR spans branches or the boundary is fuzzy, cross-check against merge commits:
`git log <prev_tag>..HEAD --merges --format='%h %s'`.

Turn that list into notes: a one-line **headline** for the title, then group the PRs by
area (e.g. Playback / Navigation / Physical disc / Analog-CRT / Build) with a short
human sentence each — not just the raw PR titles. Call out anything user-visible (new
formats, new OSD options, new controls, fixed limitations) and anything that changes
install steps. Write to `/tmp/relnotes.md` for `--notes-file`.

## Notes

- Physical-disc/encrypted-ISO support ships as part of the release now (the `MiSTer_DVDcss`
  Main + the installer), but stays **opt-in** — the bare `.rbf` alone plays decrypted ISOs.
- Historical `fj#NN` PR references are Forgejo numbers with no GitHub equivalent — leave
  them; new PRs use plain `#NN`.
- Link the manual in the release notes footer:
  <https://owenb321.github.io/MiSTer_DVD/>. It is the place to send anyone whose report
  turns out to be a setup question.
