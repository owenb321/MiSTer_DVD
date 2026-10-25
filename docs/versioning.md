# Versioning, release identity and tester builds

**What this is:** the full text of `CLAUDE.md`'s "Versioning and publishing releases" and
"Sending a build to testers" sections, moved here verbatim on 2026-10-24 to bring `CLAUDE.md`
back under its ~60 KB budget. `CLAUDE.md` keeps the rules as a short list and points here; this
file keeps the reasoning and the history of rules that were retired (which is why they must not
be reinstated).

---

## Versioning and publishing releases

Two identifiers, deliberately at different granularities:

- **`` `CORE_VERSION `` in `dvd/emu.sv`** — shown in the OSD as
  `` `CORE_VERSION` `BUILD_DATE` `` (e.g. `v0.4.0 260910`). **★ THE INVARIANT (revised
  2026-09-04, by user decision):**

  > A bare semver lives in **exactly one commit per release** — the release commit. Any
  > build whose OSD shows `v0.4.0` came from that commit and no other.

  | Where | `` `CORE_VERSION `` | OSD line |
  |---|---|---|
  | feature branch | `dev-<slug>` | `DVD dev-seekrealign 260903` |
  | `main` between releases | whatever the last merge left — no reset | `DVD dev-seekrealign 260903` |
  | `main` after a release | the release semver — no reset | `DVD v0.4.0 260903` |
  | the release commit, only | `v0.4.0` | `DVD v0.4.0 260903` |

  **★ SET `dev-<slug>` AS THE FIRST COMMIT OF EVERY FEATURE BRANCH, named after the
  feature. This is mandatory, not conventional.** Nothing resets `` `CORE_VERSION `` any
  more — not after a merge, and not after a release (both resets retired 2026-09-08, by
  user decision) — so `main` carries whatever the last feature or release left, and setting
  the slug on the branch is the ONLY thing that keeps a build labelled correctly.
  It is also what UNBLOCKS the build: after a release `main` carries a bare semver, and
  `build_release.sh` **refuses** a bare semver on a dev build, so the first build on a
  branch that skipped this step fails immediately with a message naming the fix. That is
  the intended failure — fast and self-explanatory, rather than a build that quietly
  advertises a released version.
  `build_release.sh` **gates this mechanically** before the compile (so a wrong value costs
  a second, not 40 minutes): a bare semver on a dev build and a `dev-` string on a
  publishable `--release` build are both refused. It additionally WARNS when the slug does
  not resemble the branch name — the "left over from another branch" mistake.
  **⛔ This REPLACES the retired 2026-08-26 rule ("bump `` `CORE_VERSION `` to the
  speculated next semver at the start of every feature branch").** That rule made every
  pre-release test build advertise a version that did not exist yet: a build sent out for
  testing showed `v0.4.0`, testers and the sessions reading their reports called it 0.4.0,
  and the real 0.4.0 shipped far ahead of it. **Its stated payoff was illusory** — "the
  latest `.rbf` already matches the tag, avoiding a rebuild and re-sweep at release time"
  is only true if a release is cut from one branch's exact tree, and it never is: a release
  is cut from `main` after N branches merge, so the release build is a fresh netlist and a
  fresh seed decision regardless. Do not reinstate it.
  **Two hard limits on the string**, both measured against stock Main and both enforced by
  `build_release.sh`:
  - **≤ 18 characters.** `menu.cpp`'s About screen (`MENU_ABOUT2`) truncates the whole
    `"DVD <ver> <date>"` line at 30, and `"DVD "` + `" "` + `"260903"` already uses 12.
  - **No `,` `;` `"`.** `CONF_STR` delimits entries on `;`, and `user_io.cpp`'s `p[0]=='V'`
    arm calls `substrcpy(...,1)`, which splits on commas — either character **silently
    truncates** the version rather than failing.

  (The saved-settings `"v,N;"` config version is a SEPARATE, coarser counter — bump that
  one only on an incompatible `O[..]` relayout, see `docs/idle_screen.md`.)
  **★ HOW FAR to bump (instituted 2026-08-31, by user decision — the rule existed only
  as precedent until someone had to ask):**
  - **patch** (`0.2.0` → `0.2.1`) — bug fixes, doc-only changes, internal rework with no
    change in what the user can do.
  - **minor** (`0.2.1` → `0.3.0`) — ANY new user-visible capability: a new format or
    output path, a new OSD option, or content that used to be silent/broken now working.
    If the release notes would lead with it, it is a minor bump.
  - **major** — reserved; nothing has warranted it yet (`1.0` would be a
    "this is finished" statement, not a size-of-change one).
  The failure this prevents is a release whose version says "fixes" while its own notes
  lead with a headline feature — the version line is what a user quotes in a bug report,
  so it should not understate what they are running. Precedent: `0.1d` → `0.2.0` for
  physical-disc playback; `0.2.1` → `0.3.0` for HDMI bitstream + multichannel AC-3.
  ⚠ Judge the bump against the WHOLE unreleased delta on `main`, not just the branch in
  hand — several patch-looking merges can add up to a minor release.
- **`BUILD_DATE`** — `yymmdd`, regenerated per compile by `sys/build_id.tcl`. ⚠ Do NOT
  extend it with a time or a git SHA to separate same-day builds. Same-day dev builds are
  told apart by their `build_release.sh --name` filename (which carries `<date>_<time>`),
  and a second build sent to testers on one day appends a digit to the slug
  (`dev-seekrealign2`).
  ⚠ `BUILD_DATE` is generated **inside the Quartus container, in UTC**, while the `.rbf`
  filename comes from `date` wherever the pack ran. They agree when both run under
  `USE_DOCKER=1`; a native pack of a container-built `.sof` can straddle UTC midnight and
  disagree by a day. That is why the release workflow warns rather than fails on it.

**⚠ BOTH `` `CORE_VERSION `` AND `BUILD_DATE` ARE INSIDE `CONF_STR` = INSIDE THE NETLIST.**
Either one changing re-rolls `DVD.qsf`'s pinned fitter `SEED` — measured, not theoretical:
the ledger records `"0.1a"`→`"0.1b"` alone dropping SEED 8 below the hot-corner gate. So
`` `CORE_VERSION `` may change **once per branch** (free — the branch changes the netlist
anyway) and **never per commit**. Never derive either from a git SHA, a branch name read at
build time, or a timestamp: every compile would become a new netlist, and the seed ledger's
hand-written measurements would stop describing the thing that was built.

**Publishing** — see `.claude/skills/release/SKILL.md`. It is the single source of truth
for the tag format, the asset list and the draft→smoke-test→publish flow; this file
deliberately does not restate it, because the copy that used to live here went stale (it
still described the retired `v<version>-<yyyymmdd>` tag scheme long after v0.2.0 moved to
plain semver). In outline: build the core locally, `tools/publish_draft.sh v<semver>`
creates the draft and dispatches `.github/workflows/package.yml`, which validates the core
and attaches the Main + install zip; flash and smoke-test the draft; then publish.

## Sending a build to testers

Pre-release builds go out to testers directly (Discord); they are deliberately **not**
GitHub releases, so the releases page shows only real releases. Traceability comes from the
version string instead — two commands, no flags:

```bash
USE_DOCKER=1 ./build_release.sh --compile     # --name defaults to the dev-<slug>
USE_DOCKER=1 ./main/build_main.sh             # only if the Main also changed
./tools/package_release.sh                    # -> MiSTer_DVD_dev-<slug>_<date>.zip
```

The OSD line, the `.rbf` name and the zip name all carry the same slug and date, so a report
saying *"I'm on dev-seekrealign 260903"* names exactly one build:

| | |
|---|---|
| OSD | `DVD dev-seekrealign 260903` |
| `.rbf` (inside the zip, name unchanged for MiSTer's core browser) | `DVD_20260903.rbf` |
| zip | `MiSTer_DVD_dev-seekrealign_20260903.zip` |
| `dvd_report` bundle manifest | `core_version: "dev-seekrealign 260903"` |

Sending a **second** build from the same branch on the same day: append a digit to the slug
(`dev-seekrealign2`), or the two are indistinguishable in the OSD.
★ **`main/build_main.sh` writes the same kind of record for the Main:
`MiSTer_DVDcss.json` beside the binary**, carrying the commit, the BRANCH, a
**dirty flag with the offending file list**, the stock ref and the binary's
sha256. ⚠ The dirty flag is the load-bearing field, not the commit: a Main is
routinely built from a dirty tree and deployed before the commit that captures
it, so a bare HEAD would name a commit whose content is not what shipped. ★ The
sha256's first 8 hex are the `MiSTer_DVDcss_hil_<...>` name `tools/mister.py`
deploys under, so the sidecar ties a file on the SD card back to a commit —
⚠ that deploy name is a CONTENT hash, not a VCS one. The `.rbf.json` beside
each pack records the exact commit, seed and timing if a build ever needs identifying later.
