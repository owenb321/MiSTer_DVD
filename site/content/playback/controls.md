# Controls

Playback is driven from the gamepad. The button numbers below are MiSTer's standard
numbering — whatever you mapped B1 to in the MiSTer menu is what "B1" means here.

| Button | Action | | Button | Action |
|---|---|---|---|---|
| B1 | Pause | | B8 | Subtitle (cycle) |
| B2 | Prev Chapter | | B9 | Display (toggle status line) |
| B3 | Next Chapter | | B10 | Fast Fwd (hold to scrub) |
| B4 | Select | | B11 | Rewind (hold to scrub) |
| B5 | Menu | | B12 | Title menu |
| B6 | Angle (cycle) | | B13 | Return (go up) |
| B7 | Audio (cycle) | | D-pad | Menu navigation |

A USB keyboard's **number keys select menu buttons directly**, which is often quicker than
walking a menu with the D-pad.

## In a menu

The **D-pad** walks the buttons of whatever menu is on screen, following the link graph the
disc's author defined — so it moves the way the disc intends, not in reading order.
**B4 (Select)** activates the highlighted button. **B13 (Return)** goes up a level where
the disc provides one.

**B5 (Menu)** and **B12 (Title)** are the two menu keys a set-top remote has. Menu goes to
the disc's root menu; Title goes to the title menu. Many discs make them the same thing.

### Menu during the disc's opening chain

Pressing **Menu** over a copyright or warning screen — before the disc has shown you any
menu — goes straight to the disc's main menu.

This is a deliberate deviation from what the DVD specification says should happen. Some
discs, DVD games especially, author their per-title Root "menu" as a *dispatcher* that
routes based on where you pressed Menu from. Followed literally during the opening chain,
that drops you into a random clip rather than a menu. Once you have been to a menu at least
once, Menu behaves exactly as the disc specifies.

## During playback

**B1 (Pause)** freezes on the current frame. Audio stops cleanly and resumes in sync.

**B2 / B3** step chapters. **B10 / B11** (`Fast Fwd` / `Rewind`) tapped step forward and back; **held**, they
scrub — a seek bar appears showing where you are and where you will land, and the seek
happens when you release. The target accelerates the longer you hold, so a brief hold nudges
you along and a long one crosses the whole disc.

**B9 (Display)** toggles the status line — the elapsed/total time and chapter readout along
the bottom. It also appears by itself for a couple of seconds whenever something changes.

**B7 / B8 / B6** cycle audio track, subtitle track and camera angle. Each shows a popup
naming what you switched to, with the language where the disc provides one — `AUDIO 2/4 FR`,
`SUB OFF`, `ANGLE 2/3`. Angle only does anything on a multi-angle disc.

!!! note "Track numbers are the disc's, not a count"
    A disc's audio and subtitle tracks are numbered by the disc itself, and the numbering
    is often sparse — a disc may have tracks 1, 3 and 8 with nothing between. The core
    cycles through the ones that exist and shows the disc's own number, which is why you
    may see `AUDIO 3/2`-looking combinations on unusual discs.

!!! warning "Changing audio track inside a menu"
    Switching the audio track while a disc menu is open silences the menu's own audio until
    you leave the menu. Menu audio otherwise plays normally on the default track.

## Support bundle chord

!!! info "Unreleased"
    Available in development builds; not in v0.3.0. Needs `MiSTer_DVDcss`.

**Audio + Subtitle held together for two seconds** writes a navigation support bundle for
the disc you are playing to `/media/fat/DVD_reports/` — a small file that makes a menu or
navigation bug reproducible without the disc. See
[Reporting a bug](../reference/reporting-a-bug.md). It also steps the audio and subtitle
tracks once each, which you can simply step back.

## D-pad seek

During plain playback the D-pad does nothing unless you turn on
**[D-Pad Seek](settings.md#main-page)**, which puts VLC-style jumps on it:

| Direction | Jump |
|---|---|
| Left / Right | ∓10 seconds |
| Down / Up | ∓1 minute |

**Taps add up, and each one restarts a short window.** Three quick taps of Right is one
30-second skip rather than three separate seeks, and you can keep tapping to build a jump
of any length — tap Up twenty times for a 20-minute skip. The on-screen `SEEK FWD 12:30`
readout shows the running total as you tap, and the jump happens once you stop.

That coalescing is the whole design: one seek per gesture, however long. Seeking once per
tap would mean a flush and re-lock per press, which is a regime that does not survive
rapid input.

!!! info "Unreleased"
    Seeking on flat `.mpg`/`.VOB` files, and the gentler acceleration curve on the
    Fast Fwd/Rewind scrub, are in development builds; not in v0.3.0.

On a DVD the targets come from the **disc's own seek tables**, so they land on real frame
boundaries rather than approximate byte offsets. On a VCD/SVCD, exact CD geometry is used
instead. On a flat `.mpg` or `.VOB` there is neither, so the player measures how fast the
file is playing and jumps by that — accurate on a steady-bitrate file, and on a very
variable one a ten-second jump may land a second or two out. It needs about half a second
of playback to take that measurement, so a jump attempted the instant a file starts does
nothing; tap again.

Bare `.m2v` files are the exception: they carry no timing information at all, so neither
the D-pad nor Fast Fwd/Rewind can seek in them.

!!! info "Why it is off by default"
    Some interactive and game DVDs play seekable video while expecting the D-pad as game
    input. Seeking would fight the disc. D-Pad Seek is also automatically suppressed while
    a disc menu is up, so turning it on never costs you menu navigation — but the default
    stays Off because a game disc's *gameplay* is not a menu.
