---
name: field-report
description: Turn a field report pasted from Discord (or anywhere else) into a tracked GitHub issue on owenb321/MiSTer_DVD, plus a ready-to-paste reply asking for whatever is missing. Use when the user pastes a user's bug report and wants it filed, tracked, or turned into an issue.
---

# Filing a field report as an issue

Most users report on Discord and will never open an issue. That is fine — but nothing gets
tracked, and there is no link to point them at for status. This turns a pasted report into
an issue that matches what the issue forms produce, so triage is uniform whichever route a
report arrived by.

**The output is three things**, in this order:

1. A drafted issue, shown for approval before anything is created.
2. A short **reply to paste back into Discord** asking for what is missing.
3. After creation, the issue URL and a one-line message to send the reporter.

## Rules — these are the point of the skill

**Never invent a detail.** A Discord report is two sentences and a shrug. Everything not
stated goes under **Not stated** in the issue body — never guessed, never inferred from
what would be typical, never silently filled with a default. If the report says "the menu
doesn't work", the version is *unknown*, not "presumably latest". A fabricated version line
or output path sends the maintainer chasing the wrong thing, and unlike a missing field it
will not be noticed.

**Strip personal information — the repository is public.** Remove Discord handles, display
names, real names, server and channel names, DM references, invite links, avatar URLs, and
any filesystem paths from the reporter's machine. The default attribution is exactly:

> _Reported via Discord, YYYY-MM-DD._

Include a handle **only** if the user explicitly asks for it in this conversation. Do not
offer to add one.

**Confirm before creating.** Filing a public issue is outward-facing and awkward to undo.
Show the full drafted body and wait for a clear go-ahead. Never create on your own judgment
that the draft looks good.

**Check for duplicates first.** Discord reports repeat, and the same disc surfaces
repeatedly. Search before drafting, and if something matches, propose commenting on the
existing issue instead of opening a new one.

## Step 1 — classify

Pick the one category that fits best. These mirror `.github/ISSUE_TEMPLATE/`, and the
labels must match so both routes land in the same buckets.

| The report is about | Label | Bundle helps? |
|---|---|---|
| Menus, buttons, `LINK FAIL`, wrong title, chapters | `area:navigation` | **Yes** |
| A silent track, wrong language, `AUDIO UNSUPPORTED` | `area:audio` | **Yes** |
| Nothing loads, black screen, `CSS ENCRYPTED`, `UNSUPPORTED IMAGE` | `area:loading` | Sometimes |
| Stutter, artefacts, lip sync, subtitles, captions | `area:playback` | No |
| Analog / CRT picture, sync, geometry | `area:analog` | No |
| Physical drive, `MiSTer_DVDcss`, libdvdcss, region | `area:physical-disc` | No |

Always add `bug`. If the report is a request rather than a defect, use `enhancement` and
drop `bug`.

⚠ **A silent or wrong-language audio track is `area:navigation`-shaped even though it
sounds like audio** — track-to-soundtrack mapping lives in the IFO tables, so a bundle
reproduces it. Label it `area:audio`, but ask for a bundle.

If the paste plainly contains **several unrelated problems**, do not merge them into one
issue. Say so and ask which to file, or offer one issue each.

## Step 2 — draft the body

```markdown
_Reported via Discord, 2026-09-01._

### What was reported

<the report in the reporter's own terms, tidied for spelling and line breaks only —
do not paraphrase away specifics, and do not add any>

### Details given

| | |
|---|---|
| Core version | `v0.3.0 260901` |
| Disc | <title>, region 1 |
| Playing from | decrypted image |
| On-screen message | `LINK FAIL 12` |

### Not stated

- Core version
- Whether Disc Menus is on
- Whether it worked in an earlier version

### Next step

Asked on Discord for a repro bundle (`tools/dvd_report.py`) and the version line.
```

Keep **Details given** to fields the report actually supports; drop the row otherwise. The
**Not stated** list is not padding — it is what stops a thin report being mistaken for a
complete one later.

## Step 3 — write the Discord reply

A short, friendly message the user can paste straight back into the thread. Ask only for
what is genuinely missing and genuinely useful — three items at most, or people don't
answer. Lead with the version line, since it is cheap and always needed.

For a navigation- or audio-shaped report, include the bundle ask:

> Thanks — tracking this at <URL>.
>
> Two things that would help a lot: the version line at the top of the OSD (like
> `v0.3.0 260901`), and — if you have the disc ripped on a PC — a repro bundle. It is a
> ~60 KB file with just the disc's menu tables in it, no video or audio:
> download `dvd_report.py` from the repo and run `python3 dvd_report.py YOUR_DISC.iso`,
> then drop the zip it makes in here.

Adjust the tone to the thread. Do not paste a wall of instructions at someone who wrote one
line.

## Step 4 — search, confirm, create

`gh` is **not authenticated** on this machine; pull the token from the git credential store
and keep it in a subshell. Run every `gh` call inside one `bash -c` (the login shell is
fish):

```bash
bash -c 'TOK=$(printf "protocol=https\nhost=github.com\n\n" | git credential fill \
  | sed -n "s/^password=//p"); GH_TOKEN="$TOK" gh issue list --repo owenb321/MiSTer_DVD \
  --search "<disc> menu" --state all --limit 10'
```

Then, only after the user approves the draft:

```bash
bash -c 'TOK=$(printf "protocol=https\nhost=github.com\n\n" | git credential fill \
  | sed -n "s/^password=//p"); GH_TOKEN="$TOK" gh issue create \
  --repo owenb321/MiSTer_DVD --title "<title>" --label bug --label area:navigation \
  --body-file /tmp/issue_body.md'
```

Write the body to a file — long markdown with backticks and tables does not survive shell
quoting reliably.

**Titles:** `<Disc or area>: <symptom>`, concrete and searchable. `<Disc>: language menu
"next page" starts the feature` beats `Menu bug`. If the disc is unknown, lead with the
area: `Analog CRT: no picture with composite_sync=1`.

⚠ The `area:*` labels may not exist yet. If `gh issue create` rejects a label, create them
once:

```bash
bash -c 'TOK=$(printf "protocol=https\nhost=github.com\n\n" | git credential fill \
  | sed -n "s/^password=//p"); for a in navigation audio loading playback analog \
  physical-disc; do GH_TOKEN="$TOK" gh label create "area:$a" \
  --repo owenb321/MiSTer_DVD --color BFD4F2 --force; done'
```

## Step 5 — hand back

Give the user the issue URL and the Discord reply, ready to copy. Nothing else.

## When a follow-up arrives

The reporter answers in the thread days later. Paste the follow-up and this skill should
**comment on the existing issue** rather than open a second one, and strike items off the
**Not stated** list by editing the body:

```bash
gh issue comment <n> --repo owenb321/MiSTer_DVD --body-file /tmp/comment.md
gh issue view <n> --repo owenb321/MiSTer_DVD --json body -q .body   # read before editing
```

If the follow-up includes a repro bundle the user has saved locally, verify it before
trusting it — `python3 tools/dvd_report.py info <zip>` prints the manifest, and
`unpack` turns it into something the nav tools read. See
[`docs/bug_reports.md`](../../../docs/bug_reports.md).
