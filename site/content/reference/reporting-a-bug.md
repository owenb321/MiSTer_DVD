# Reporting a bug

Most problems are disc-specific, and the disc is usually one nobody else has. What makes a
report actionable is saying **which build**, **which disc**, and **what happened** — and,
for anything to do with menus or audio tracks, attaching a small file that lets the
problem be reproduced without the disc.

[Open an issue →](https://github.com/owenb321/MiSTer_DVD/issues)

## Always include

- The **core version** from the OSD — the `v0.3.0 260901` line. It is the only thing that
  identifies a build. On a test build handed out before a release it names the feature
  instead, like `dev-seekrealign 260903`; quote whichever you see, exactly.
- The **disc title and region**.
- **What happens, and where** — does it boot, reach a menu, start the feature?
- Any [on-screen message](../playback/on-screen-messages.md).
- Whether it is a **physical disc, a decrypted image, or an encrypted image**.
- If it used to work, **which version it last worked in**.

## Menus, titles and audio tracks: send a repro bundle

A DVD keeps its navigation — every menu, button, title, chapter and audio-track
assignment — in a handful of small `.IFO` files, separate from the film itself. On a
typical disc they come to well under 100 KB, and they are all that is needed to reproduce:

- menus that do nothing, jump somewhere wrong, or show `LINK FAIL nn`
- the wrong title playing, or the disc not reaching the feature
- **a track that is silent, or the wrong language playing** — which track maps to which
  soundtrack is decided in those same tables, so this is a navigation question even though
  it sounds like an audio one
- chapters that are missing or in the wrong place

Download **[`dvd_report.py`](https://github.com/owenb321/MiSTer_DVD/blob/main/tools/dvd_report.py)**
and run it on a PC against your own rip of the disc. It needs Python 3 and nothing else,
and it works on an **encrypted rip too** — the navigation tables are never encrypted, so
no decryption step is involved:

```bash
python3 dvd_report.py MY_DISC.iso
```

It asks a few optional questions, writes a `dvdreport-*.zip` of around 40–100 KB, and
verifies the bundle actually reproduces before telling you it is done. Attach that zip to
the issue.

If the problem is specifically about **menu buttons or highlights** — the wrong button
lit, the highlight in the wrong place, a press doing nothing — add `--nav-packs` so the
button positions are captured too:

```bash
python3 dvd_report.py MY_DISC.iso --nav-packs
```

!!! note "What is in the bundle, and what is not"
    Only the disc's **unencrypted navigation structures**: the directory records, the
    `.IFO` navigation tables, optionally the data describing menu buttons, and your
    answers. **No video, no audio, and no decryption keys.** It is not a copy of the film
    and cannot be used to watch anything.

    That is enforced, not just intended — the tool checks every sector it has gathered and
    refuses to write a bundle if any of them carries picture or sound, reporting
    `content audit: PASS` when it finishes. It stores your image's filename but no other
    path from your computer. `python3 dvd_report.py info <zip>` prints back everything a
    bundle holds, any time.

This route needs a rip on a PC — encrypted or decrypted, either works. If you only ever
play physical discs, the next section is for you.

### Or make one on the MiSTer itself

!!! info "Unreleased"
    Available in development builds; not in v0.3.0. Needs `MiSTer_DVDcss`.

While a disc is playing, **hold Audio + Subtitle together for two seconds**. The player
writes a bundle to `/media/fat/DVD_reports/` and tells you the filename on screen. Copy it
off the SD card and attach it to the issue.

This works for **physical discs** as well as images, and it needs no PC. It also records
something the PC route cannot: the exact point on the disc you were at when you pressed it,
which for a menu problem is usually the whole answer.

Holding those two buttons also steps the audio track and the subtitle track once each —
that is expected, and pressing them again puts things back.

The bundle it writes also records two things the PC route cannot: the **core version**,
so you never have to read it off the OSD, and the **exact point on the disc** you were at
when you pressed the chord.


## Everything else: describe it

Picture and sound problems live in the video stream itself, which is far too large to
share, so words are the right tool. What helps most:

| Problem | Worth saying |
|---|---|
| Stutter or judder | Whether it is a busy scene, and whether it is [film or video content](../video/film-24p.md) |
| Lip sync out | Whether it is wrong from the start or drifts; whether a **chapter skip fixes it**; your `A/V Offset` setting |
| Artefacts or wrong colours | Whether it is constant or occasional, and which output — HDMI, analog, CRT |
| Analog or CRT trouble | Your `MiSTer.ini` video lines, `Analog Out` mode, and what the display is |
| Passthrough or receiver trouble | The receiver model, the codec, and whether optical or HDMI |

Two questions are worth answering for almost any playback problem, because they separate
whole classes of cause: **does it happen from a cold load, or only after playing a while?**
And **does a chapter skip clear it?**

For lip sync in particular, a **phone video with sound** is genuinely useful — the offset
can be measured from it directly.

## What is expected to be broken

Interactive DVD **games** are known-incomplete, so reports about them are welcome but
unsurprising. A **film or TV disc** that misbehaves is the more valuable report. See
[Compatibility](compatibility.md) for what is known not to work.
