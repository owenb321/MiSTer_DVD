---
name: docs-sweep
description: Audit README.md and the site/ user manual against the changes in a diff range, update whatever went stale, and report what changed. Use before merging a feature branch, before cutting a release, or whenever asked to check whether the docs match the code.
---

# Sweeping the user docs against a change

The manual is published from `main` and deploys on merge, so **a stale page goes live the
moment a branch lands**. This sweep is what stops that.

Default range is `main...HEAD` (the current branch's changes). A release sweep passes
`<prev_tag>..HEAD` instead.

## 1. Mechanical checks first

```bash
python3 tools/docs_check.py     # OSD options/buttons/extensions <-> manual parity
mkdocs build --strict           # broken cross-link = failure
```

Both must pass. `docs_check.py` failing means an OSD option, gamepad button or file
extension changed without the manual following — fix that before anything else.

These do **not** cover README.md. Check its self-anchors by hand, because nothing else
does:

```bash
grep -on "](#[a-z0-9-]*)" README.md   # every anchor must match a heading that still exists
```

## 2. Signal pass

```bash
git diff --stat <range>
```

Map what changed to what must be reviewed:

| Changed | Review |
|---|---|
| `dvd/emu.sv` CONF_STR literal | `playback/settings.md` (normative), `controls.md`, `getting-started/loading.md` |
| `dvd/transport_hud.sv` `pop_type`, `dvd/hud_font.mem` | `playback/on-screen-messages.md` **and** `reference/troubleshooting.md` |
| `tools/*.py`, `tools/*.sh`, `main/Scripts/*` | the owning page — `customising/idle-logo.md`, `formats/physical-discs.md`, `about/building.md` |
| A new codec/format module in `dvd/` | `reference/compatibility.md`, `audio/formats.md` |
| `main/support/dvd/*`, release-asset list | `getting-started/what-you-need.md` — the tier matrix is a claim about what each piece buys, and a change there can falsify a row |
| `main/`, `build_release.sh`, `tools/package_release.sh` | `about/building.md`, `getting-started/install.md` |
| Video output paths (`re_interlace`, `syncgen`, modeline) | `video/analog-crt.md`, `video/interlaced.md`, `video/film-24p.md` |
| `README.md` changed but `site/content/` did not, or the reverse | **drift flag** — check the two still agree |
| `docs/*.md` changed | harvest check: did user-facing material land in an engineering note instead of the manual? |

## 3. Semantic pass

Read the range's commit messages and PR body. For each user-visible claim, ask **which page
currently states the old truth**.

The highest-value case is a **removed limitation**: `reference/compatibility.md` and the
README's headline bullets both assert things a branch may have just fixed. Grep the manual
for the feature's keywords and read every hit — a limitation that is no longer true is the
same class of bug as a stale status marker.

Also check:

- Does anything need an `!!! info "Unreleased"` admonition? The site documents `main`; a
  feature not in the newest release must say so.
- Does a new on-screen message string need a row in **both** `on-screen-messages.md` and
  `troubleshooting.md`?
- Did a default change? Defaults are stated on the settings page and often repeated in the
  page that explains the feature.

## 4. Apply, verify, report

Make the edits, then re-run both checks from step 1.

Report a table of page / signal / verdict — `current`, `updated`, or `needs a decision`.
Apply what is unambiguous. **Stop and ask** on anything that turns on a judgement about
user-facing behaviour rather than editing on a guess.

If the sweep runs as part of a merge and finds unresolved items, say so and stop rather
than merging stale documentation.
