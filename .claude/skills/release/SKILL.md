---
name: release
description: Cut and publish a GitHub release of the MiSTer DVD core — gather release notes from every PR merged since the previous release, land the one release commit that sets CORE_VERSION and reconciles the manual, build the timing-clean .rbf, create the draft that CI packages (Main + install zip), smoke-test it, publish, and set the version back to dev-main. Use when the user asks to cut, make, or publish a release.
---

# Cutting a DVD core release

Publishes a GitHub release for `owenb321/MiSTer_DVD`. Two build outputs (FPGA `.rbf` via
Quartus, `MiSTer_DVDcss` Main via the ARM toolchain) plus a packaged zip, with notes drawn
from the PRs merged since the last release.

## Versioning — the one-commit invariant

> A bare semver lives in **exactly one commit per release** — the release commit. Any
> build whose OSD shows `v0.4.0` came from that commit and no other.

- **`CORE_VERSION` in `dvd/emu.sv`** carries `dev-<slug>` on a feature branch and
  `dev-main` on `main`. Step 0 below sets it to `v<semver>` for the release; the last step
  sets it back to `dev-main`. Shown in the OSD as `` `CORE_VERSION` `BUILD_DATE` ``.
  `build_release.sh` refuses a `dev-` string on a publishable `--release` build and refuses
  a bare semver on a dev build, so the invariant is mechanical rather than remembered.
- **Release tag = `v<semver>`** (e.g. `v0.4.0`); title = `v<semver> — <headline>`.
  (This replaces the older `v<version>-<yyyymmdd>` tag format — pure semver now.)
- **Zip = `MiSTer_DVD_v<semver>.zip`** (produced by `tools/package_release.sh`).
- **★ The `.rbf` filename stays `DVD_YYYYMMDD.rbf` — date only, NEVER a version.** This is
  required, not stylistic: MiSTer's core browser and update scripts parse the `YYYYMMDD`
  out of the filename to decide which build is newest. A semver there breaks update
  detection. `build_release.sh --release` already produces this name. Date and semver never
  collide: date lives in the filename (for MiSTer), semver lives in the tag/zip/OSD (for
  humans).
- `BUILD_DATE` (`yymmdd`) is regenerated per compile; do not extend it. Both it and
  `CORE_VERSION` are part of `CONF_STR` = part of the netlist, so either changing re-rolls
  the fitter seed lottery — which is why the version edit rides in ONE commit with the docs
  sweep, so the release needs exactly one compile.

## Preconditions

- On `main`, clean tree, and every feature branch intended for this release is already
  merged (use the `merge` command for any that aren't).
- **The manual matches what is shipping.** `python3 tools/docs_check.py` and
  `mkdocs build --strict` both pass. If a release note would claim something the manual
  does not say, fix the manual first — it is the published contract.
- `CORE_VERSION` currently reads `dev-main` (it is set to the semver by step 0, not
  before). Decide the number against the **whole** unreleased delta on `main`, not the last
  branch merged — several patch-looking merges can add up to a minor release. The
  patch/minor/major rules are in `CLAUDE.md` "Versioning and publishing releases".

## gh auth

`gh` is not authenticated by default here — pull the token from git credential (see the
`gh-cli-not-authenticated` memory):

```bash
export GH_TOKEN=$(printf "host=github.com\nprotocol=https\n\n" | git credential fill | sed -n 's/^password=//p')
```

## Steps

In execution order. Steps 1-2 come before any build because the version number depends on
what the notes say, and because `CORE_VERSION` is part of the netlist — deciding it late
would cost a second compile.

1. **Gather the notes.** Every PR merged since the last release (recipe in "Release notes"
   below), grouped into human sentences. Then run the `docs-sweep` skill over
   `<prev_tag>..HEAD`: you have just read every PR, so asking of each one "does this change
   controls, an OSD option, an on-screen message, install steps, or compatibility?" is
   nearly free. Fix the owning page in `site/content/` for anything stale.
   The headline you write here decides the version (patch / minor / major — see `CLAUDE.md`).

2. **Land ONE release commit** on `main`, containing the docs-sweep edits **and**:
   - `CORE_VERSION` in `dvd/emu.sv` → `"v<semver>"` (from `"dev-main"`).
   - `extra.released_version` in `mkdocs.yml` → `<semver>` (no `v`). The release workflow
     **refuses to package** if this disagrees with the tag: it drives the "latest release is
     vX.Y.Z" banner on every manual page.
   - the "Current as of **vX.Y.Z**" line in `site/content/reference/compatibility.md`.
   - sweep out `!!! info "Unreleased"` admonitions for anything this release ships.

   **One commit, one netlist, one compile.** `CORE_VERSION` lives in `CONF_STR`, so
   splitting the bump from the docs commit buys a second netlist and a second seed decision
   for nothing. Push it — the workflow checks out this exact commit, so anything uncommitted
   would silently not be in the released Main, Scripts or `DVD_INSTALL.txt`.
   Verify locally first: `python3 tools/docs_check.py && mkdocs build --strict`.

3. **Build the core (timing-clean).** Quartus, in the pinned container:
   ```bash
   USE_DOCKER=1 ./build_release.sh --release --compile   # -> releases/DVD_YYYYMMDD.rbf + .rbf.json
   ```
   `--release` refuses to pack a timing-marginal netlist, and now also refuses to build at
   all unless `CORE_VERSION` is the release semver. **Never ship a `_MARGINAL_` .rbf** — if
   it comes back marginal, re-roll with `tools/seed_sweep.sh` until clean. (Long compile —
   run it in the background and report the result.) It writes a provenance manifest beside
   the `.rbf`; the workflow needs both files.

4. **Record the fit in `DVD.qsf`'s seed ledger.** `jq . releases/DVD_YYYYMMDD.rbf.json` has
   every number the entry quotes (seed, both clk_dec corners, ALM/RAM/DSP), and the workflow
   reprints them as a table in its run summary.

5. **Create the draft and package it:**
   ```bash
   ./tools/publish_draft.sh v<semver> --notes /tmp/relnotes.md --title "v<semver> — <headline>"
   ```
   It pre-flights locally (version matches the tag, tree clean and pushed, core
   non-marginal, manifest matches the `.rbf`), creates the **draft** with the `.rbf` +
   manifest attached, and dispatches `.github/workflows/package.yml`. CI validates the core,
   builds `MiSTer_DVDcss`, re-runs `docs_check.py` + `mkdocs --strict`, packages the zip and
   attaches the four assets it owns.

   ⚠ **A draft cannot trigger a workflow** (GitHub does not fire `release:created` for
   drafts) and **has no git tag** — hence the explicit dispatch, and hence the workflow
   checking out the SHA from the manifest rather than `refs/tags/`. Do not "simplify" it to
   `on: release`.

6. **Smoke-test the draft, then publish.** This is the point of drafting: download the zip
   CI attached, flash the `.rbf`, confirm the core boots, mounts a disc and plays, and that
   the OSD About line reads `DVD v<semver> <yymmdd>`.
   ```bash
   gh release view v<semver> --web        # confirm all five assets are attached
   gh release edit v<semver> --draft=false
   ```
   Publishing creates the tag. The `/releases/latest` URL the README links to updates
   automatically — no README edit per release.

7. **Set `CORE_VERSION` back to `"dev-main"`** in `dvd/emu.sv` and commit. This is what
   preserves the invariant: the semver now exists in exactly one commit, so no later dev
   build can advertise a released version.

## Release assets (attach all six)

| Asset | For |
|---|---|
| `MiSTer_DVD_v<semver>.zip` | Complete install — extracts to SD root, drops the installer into the Scripts menu |
| `DVD_YYYYMMDD.rbf` | Core only — ISO-only users (physical disc is opt-in); most people want just this |
| `MiSTer_DVDcss` | Custom Main only — physical discs + encrypted ISOs; needs `[DVD] main=MiSTer_DVDcss` |
| `install_dvdcss.sh` | libdvdcss installer (also inside the zip's `Scripts/`) |
| `set_dvd_region.sh` | DVD drive-region tool — physical-disc users (also inside the zip's `Scripts/`). Documented in `site/content/formats/physical-discs.md`; keep it that way — it shipped as an asset for a release before it appeared in any prose. |
| `dvd_report.py` | Repro-bundle collector (also inside the zip's `Scripts/`). Ships standalone because `MiSTer_DVDcss` **shells out to it**: anyone taking the Main alone gets the Audio+Subtitle chord and nothing for it to run, and it fails silently. |

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
