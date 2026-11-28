---
name: docs-sweep
description: Audit README.md and the site/ user manual against the changes in a diff range, update whatever went stale, and report what changed. Use before merging a feature branch, before cutting a release, or whenever asked to check whether the docs match the code.
---

# Sweeping the user docs against a change

The manual deploys **only when a release is published**, built from that release's tagged
commit, and the README is the repository's front page the moment a branch merges. So a stale
README is visible at once, and a stale manual page ships with the next release. This sweep
stops both.

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

Then check the context budget. `CLAUDE.md` is loaded into every session:

```bash
wc -c CLAUDE.md                 # over ~60 KB = a feature write-up landed in the wrong file
```

If it is over budget, move the offending write-up to the top of `docs/status_log.md` and
leave one row in `CLAUDE.md`'s "Feature status index".

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
| A new user-visible capability (anything that would make the next release a **minor** bump), a headline limitation removed or added, a change in what class of disc is supported (e.g. game discs) | **README currency pass** (step 4) |
| A feature landed or changed status | its row in `CLAUDE.md`'s status index + its `docs/status_log.md` entry |
| `docs/*.md` changed | harvest check: did user-facing material land in an engineering note instead of the manual? |

## 3. Semantic pass

Read the range's commit messages and PR body. For each user-visible claim, ask **which page
currently states the old truth**.

The highest-value case is a **removed limitation**: `reference/compatibility.md` and the
README's headline bullets both assert things a branch may have just fixed. Grep the manual
for the feature's keywords and read every hit — a limitation that is no longer true is the
same class of bug as a stale status marker.

Also check:

- Is a page written in the present tense? Unreleased features are **not** marked
  (retired 2026-09-09: the manual deploys from the release tag, so every page describes
  the release it ships with). Don't add `!!! info "Unreleased"` admonitions.
- Does a new on-screen message string need a row in **both** `on-screen-messages.md` and
  `troubleshooting.md`?
- Did a default change? Defaults are stated on the settings page and often repeated in the
  page that explains the feature.

## 4. README currency pass (big changes, and every release sweep)

The README drifts differently from the manual. Nothing parses it, and a feature is
documented in full on its manual page, so nobody goes back to add the one-line summary.
By v0.11.0 it lacked save states, trick play and deinterlacing, and still called every
game disc "known-incomplete" a release after the games work landed. Run this pass whenever
the range has a signal from the table above, and **always** on a release sweep
(`<prev_tag>..HEAD`):

1. List the range's user-visible capabilities: merged PR titles
   (`gh pr list --state merged --search "merged:>=<date of prev tag>"`), or the draft
   release notes on a release sweep.
2. For each one, ask whether a reader of the README alone would know it exists. A headline
   feature (a format, an output path, a transport mode, a new class of disc that now
   plays) gets a clause or a bullet in **"What works"**, linking its manual page. A fix or
   a setting tweak does not.
3. Re-read **"Known limitations"** against the range. A
   limitation the range removed is deleted or reworded. A new headline limitation is
   added. Keep the list short: the full list lives in `reference/compatibility.md`.
4. Mirror the same changes into **`site/content/index.md`**. Its "What works" makes the same claims as the README in longer form, and they go stale together.
   The two must not contradict each other.
5. On a release sweep, the release commit also bumps `reference/compatibility.md`'s
   "Current as of **vX.Y.Z**" line (the `release` skill, step 2). Check that the page
   below that line really is current to that version.

Keep the README short (~160 lines). It is the landing page, not the manual. Add clauses
and links rather than paragraphs. There is deliberately no status/maturity callout (dropped
2026-11-27, by user decision); don't add one back.

## 5. Apply, verify, report

Make the edits, then re-run both checks from step 1.

Report a table of page / signal / verdict — `current`, `updated`, or `needs a decision`.
Apply what is unambiguous. **Stop and ask** on anything that turns on a judgement about
user-facing behaviour rather than editing on a guess.

If the sweep runs as part of a merge and finds unresolved items, say so and stop rather
than merging stale documentation.
