# Controls

Playback is driven from a gamepad, a USB keyboard, or a TV or set-top remote — all three
work at once, and none of them needs setting up. The button numbers below are MiSTer's
standard numbering — whatever you mapped B1 to in the MiSTer menu is what "B1" means here.

| Button | Action | | Button | Action |
|---|---|---|---|---|
| B1 | Pause | | B8 | Subtitle (cycle) |
| B2 | Prev Chapter | | B9 | Display (toggle status line) |
| B3 | Next Chapter | | B10 | Fast Fwd (hold to scrub) |
| B4 | Select | | B11 | Rewind (hold to scrub) |
| B5 | Menu | | B12 | Title menu |
| B6 | Angle (cycle) | | B13 | Return (go up) |
| B7 | Audio (cycle) | | D-pad | Menu navigation |

Every one of those actions also has a **[keyboard or remote key](#keyboard-and-tv-remote)**.
A USB keyboard's **number keys select menu buttons directly**, which is often quicker than
walking a menu with the D-pad.

## Keyboard and TV remote

!!! info "Unreleased"
    Available in development builds; not in v0.3.0.

Nothing to configure — plug in a keyboard and these keys work. Anything that presents
itself to MiSTer as a keyboard counts, which is how a **remote** drives the player too.

| Key | Action | | Key | Action |
|---|---|---|---|---|
| ↑ ↓ ← → | Menu navigation | | ++"A"++ | Audio (cycle) |
| ++enter++ | Select | | ++"S"++ | Subtitle (cycle) |
| ++space++ | Pause | | ++"G"++ | Angle (cycle) |
| ++page-up++ / ++"P"++ | Prev Chapter | | ++"D"++ | Display (toggle status line) |
| ++page-down++ / ++"N"++ | Next Chapter | | ++tab++ / ++"F"++ | Fast Fwd (10 s per press) |
| ++"M"++ / ++"X"++ | Menu | | ++backspace++ / ++"R"++ | Rewind (10 s per press) |
| ++"T"++ | Title menu | | ++esc++ / ++"B"++ | Return (go up) |
| ++0++ – ++9++ | Select menu button by number | | | |

!!! warning "Fast Fwd and Rewind work differently here"
    On a gamepad you *hold* them to scrub. On a keyboard or remote each press jumps **10
    seconds**, and presses add up the same way [D-pad seek](#d-pad-seek) does — six quick
    taps is one minute, and one seek happens when you stop. That is deliberate: a remote's
    "hold" is really a rapid stream of taps, which a scrub would turn into dozens of
    separate seeks. This works whether or not D-Pad Seek is switched on. Files with no seek
    information — a bare `.m2v` — have no keyboard seek.

## Using a remote

!!! info "Unreleased"
    Needs the keyboard support above; not in v0.3.0.

The reliable way is an **infrared receiver that presents itself as a USB keyboard** — a
Flirc, a generic MCE-style USB IR dongle, or the receiver built into a console dock. It
learns whatever remote you already own, emits ordinary keystrokes, and needs no setting up
on the MiSTer side at all: the keys in the table above simply work.

That is also what a console dock does. A dock remote usually sends only a handful of keys —
on a SuperStation One SuperDock, the arrows plus **OK** (++enter++), **Exit** (++esc++),
**Cancel** (++"X"++) and one function key — which is enough to walk a disc's menus and start
a title. **Cancel** is mapped to Menu precisely because that remote's own Menu button
belongs to the MiSTer OSD.

### Using your TV's remote over HDMI-CEC

A TV remote can drive the player over CEC instead, with no extra hardware — **but whether
CEC works at all depends on your board**, so treat it as worth trying rather than as a
supported path.

Enable it under `[MiSTer]` in `MiSTer.ini`:

```ini
hdmi_cec=1
```

Then map the colour keys to the disc's own menus: **blue** = Menu, **red** = Title,
**green** = Audio, **yellow** = Subtitle. You need those because the remote's Menu / Exit
button belongs to the MiSTer OSD (see below).

!!! failure "If nothing happens, check the log before changing anything else"
    MiSTer throws its own log away by default. Add `debug=2` under `[MiSTer]`, reboot, and
    read `/tmp/debug.txt`:

    ```
    grep -i cec /tmp/debug.txt
    ```

    | What you see | What it means |
    |---|---|
    | `CEC: no clock detected` then `CEC: init failed.` | **Your board's CEC hardware is not usable.** Nothing in the ini changes this — see below. |
    | `CEC: main register setup failed` | The HDMI transmitter could not be reached at all. |
    | `CEC: no EDID and power-on disabled` | Set `hdmi_cec_power_on=1`. |
    | `CEC: logical=… physical=1.0.0.0` | CEC is working. If the remote still does nothing, the **TV** is not routing it — usually because MiSTer is not the selected input. |
    | *no `CEC:` lines at all* | `hdmi_cec=1` is not being read. It must be under `[MiSTer]`, not below another core's section heading. |

    To see whether the TV sends anything at all, press keys **from the MiSTer main menu**
    rather than inside the player — button codes are only logged there, as
    `CEC button: 0x09, pressed=1`.

!!! warning "`no clock detected` cannot be fixed in the ini"
    It means the HDMI transmitter's CEC engine never completed a transmission, which is a
    wiring or clock-source question on the board itself. In particular **`hdmi_cec_clock=`
    does not help**: that setting only chooses between clock rates *after* a successful
    probe, so it cannot revive an engine that is not running. Set `hdmi_cec=0` to skip the
    probe and its startup delay, and use a USB infrared receiver instead — it gives you the
    same remote control and does not involve the HDMI transmitter at all.

!!! note "Turning CEC off again"
    `hdmi_cec=0` disables the whole thing. To stop a TV remote controlling playback while
    keeping CEC's power-on and standby handling, set `hdmi_cec_input_mode=0` instead. There
    is no setting for either in the player's own menu, because a CEC keypress arrives as an
    ordinary keystroke — the core cannot tell it apart from a USB keyboard.

## Things MiSTer keeps for itself

- **++f12++ and a remote's Menu button open the MiSTer OSD**, always. They can never be
  given a disc function.
- While the OSD is open, **no key reaches the player**.
- On a **CEC remote, Menu / Exit is the MiSTer OSD button**, not the disc menu. It is a
  proper toggle: pressing it again steps back a level and closes the OSD at the top, so it
  is how you get in and out. **Stop** also closes the OSD from any level. Which physical
  button sends which code is up to the TV, not MiSTer — most sets send Exit for Back/Return
  and Root Menu for Home/Menu while a source is selected, and some pass only a few keys
  through CEC at all.
- The [support bundle chord](#support-bundle-chord) is **gamepad-only** — it is handled
  outside the core, so the keyboard's Audio and Subtitle keys cannot trigger it.

## Rebinding

Use MiSTer's own **Define buttons**, which maps any key onto any of the buttons in the first
table. A key you map there takes over completely, so it replaces whatever the built-in list
above gave it.

!!! note "++enter++ and ++esc++ cannot be rebound"
    MiSTer reserves both as its own confirm and cancel keys and will not assign them to a
    button — pressing ++enter++ during Define buttons *ends* the session rather than
    capturing it, which looks like it worked. That is exactly why the player reads them
    itself, and it is why a dock remote's **OK** and **Exit** buttons now work at all.

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
