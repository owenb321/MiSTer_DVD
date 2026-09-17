# Controls

Playback is driven from a gamepad, a USB keyboard, or a TV or set-top remote — all three
work at once, and none of them needs setting up. The button numbers below are MiSTer's
standard numbering — whatever you mapped B1 to in the MiSTer menu is what "B1" means here.

| Button | Action | | Button | Action |
|---|---|---|---|---|
| B1 | Pause — and Play, when stopped | | B10 | Fast Fwd (hold to scrub) |
| B2 | Prev Chapter | | B11 | Rewind (hold to scrub) |
| B3 | Next Chapter | | B12 | Title menu |
| B4 | Select | | B13 | Return (go up) |
| B5 | Menu | | B14 | Stop |
| B6 | Angle (cycle) | | B15 | Aspect (cycle) |
| B7 | Audio (cycle) | | B16 | Chapter Menu |
| B8 | Subtitle (cycle) | | B17 | A-B Repeat |
| B9 | Display (toggle status line) | | B18 | Frame Step (pause, then step) |
| | | | B19 | Eject |
| | | | B20 | Vol Up |
| | | | B21 | Vol Down |
| | | | D-pad | Menu navigation |

Every one of those actions also has a **[keyboard or remote key](#keyboard-and-tv-remote)**.
A USB keyboard's **number keys select menu buttons directly**, which is often quicker than
walking a menu with the D-pad.

## Keyboard and TV remote

Nothing to configure — plug in a keyboard and these keys work. Anything that presents
itself to MiSTer as a keyboard counts, which is how a **remote** drives the player too.

| Key | Action | | Key | Action |
|---|---|---|---|---|
| ↑ ↓ ← → | Menu navigation | | ++tab++ / ++"F"++ | Fast Fwd (10 s per press) |
| ++enter++ | Select | | ++backspace++ / ++"R"++ | Rewind (10 s per press) |
| ++space++ | Pause / Play | | ++esc++ / ++"B"++ | Return (go up) |
| ++page-up++ / ++"P"++ | Prev Chapter | | ++"Q"++ | Stop |
| ++page-down++ / ++"N"++ | Next Chapter | | ++"Z"++ | Aspect (cycle) |
| ++"M"++ / ++"X"++ / ++f1++ | Menu | | ++f5++ | Chapter Menu |
| ++"T"++ / ++f2++ | Title menu | | ++"L"++ | A-B Repeat |
| ++"A"++ / ++f3++ | Audio (cycle) | | ++"."++ | Frame Step |
| ++"S"++ / ++f4++ | Subtitle (cycle) | | ++"E"++ | Eject |
| ++"G"++ | Angle (cycle) | | Keypad ++"+"++ | Vol Up |
| ++"D"++ | Display (toggle status line) | | Keypad ++"-"++ | Vol Down |
| | | | ++0++ – ++9++ | Select menu button by number |

!!! warning "Fast Fwd and Rewind work differently here"
    On a gamepad you *hold* them to scrub. On a keyboard or remote each press jumps **10
    seconds**, and presses add up the same way [D-pad seek](#d-pad-seek) does — six quick
    taps is one minute, and one seek happens when you stop. That is deliberate: a remote's
    "hold" is really a rapid stream of taps, which a scrub would turn into dozens of
    separate seeks. This works whether or not D-Pad Seek is switched on. Files with no seek
    information — a bare `.m2v` — have no keyboard seek.

## Using a remote

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
**green** = Audio, **yellow** = Subtitle.

Your remote's **transport keys** work as you would expect:

| Remote key | Does |
|---|---|
| Play / Pause | Pause and resume |
| Stop | Stop (two-stage — see [Stopping a disc](#stopping-a-disc)) |
| Fast Fwd / Rewind | Seek ±10 s per press |
| Prev / Next | Chapter back and forward |
| Exit / Back | Return (up one menu level) |
| Eject | Eject |
| Info / Display | Toggle the status line |
| Contents / Title list | Chapter Menu |
| Volume, Mute | MiSTer's own volume — handled before the core sees it |

!!! note "Needs `MiSTer_DVDcss`"
    Those transport mappings come from the custom Main. On stock Main a remote's Stop
    key does **Return** instead, and Eject / Info / Contents do nothing.

!!! warning "Menu / Home still belongs to the MiSTer OSD"
    The remote's **Root Menu / Home** key opens the MiSTer OSD and always will — that is
    how you get in and out of it. Use the **blue** colour key for the disc's menu.

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
  is how you get in and out. A remote's **Stop** key also closes the OSD from any level —
  note this is MiSTer's own handling of that key while the OSD is up, and is not the
  player's [Stop button](#stopping-a-disc), which is what the same key does during
  playback. Which physical button sends which code is up to the TV, not MiSTer — most sets
  send Exit for Back/Return and Root Menu for Home/Menu while a source is selected, and
  some pass only a few keys through CEC at all.
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
[Frame step](#frame-step) also pauses, if you would rather stop on an exact frame.

**B2 / B3** step chapters. **B10 / B11** (`Fast Fwd` / `Rewind`) tapped step forward and back; **held**, they
scrub — a seek bar appears showing where you are and where you will land, and the seek
happens when you release. The target accelerates the longer you hold, so a brief hold nudges
you along and a long one crosses the whole disc.

**B9 (Display)** toggles the status line — the elapsed/total time and chapter readout along
the bottom. It also appears by itself for a couple of seconds whenever something changes.
Pressing it again hides the line straight away.

**B7 / B8 / B6** cycle audio track, subtitle track and camera angle. Each shows a popup
naming what you switched to, with the language where the disc provides one — `AUDIO 2/4 FR`,
`SUB OFF`, `ANGLE 2/3`. Angle only does anything on a multi-angle disc.

!!! note "Some discs choose the angle for you"
    A few discs use the camera-angle mechanism to hold two versions of the same scene —
    most often a title card or end credits in two languages. Those discs set the angle
    themselves, usually from whatever you pick in their own audio or setup menu, and the
    core now follows that choice. Press **Angle** if you want the other version anyway.

    On a disc of this kind the Angle button takes effect at the **start of the next such
    scene** rather than instantly, because the disc does not provide the information a
    player needs to switch mid-scene. A true multi-angle disc — a concert shot from
    several cameras, say — switches immediately as before.

!!! note "Track numbers are the disc's, not a count"
    A disc's audio and subtitle tracks are numbered by the disc itself, and the numbering
    is often sparse — a disc may have tracks 1, 3 and 8 with nothing between. The core
    cycles through the ones that exist and shows the disc's own number, which is why you
    may see `AUDIO 3/2`-looking combinations on unusual discs.

!!! warning "Changing audio track inside a menu"
    Switching the audio track while a disc menu is open silences the menu's own audio until
    you leave the menu. Menu audio otherwise plays normally on the default track.

### Stopping a disc

**B14 (Stop)** works the way a set-top player's does, in two stages.

- **Press once** and playback halts, the bouncing logo comes up, and `STOP` is shown.
  The picture is blanked, and any subtitle or disc menu highlight goes with it — only the
  logo and `STOP` are left. Your place is remembered — **Pause/Play picks up exactly
  where you left off**.
- **Press again** and the place is forgotten. The screen clears to just the logo, as if
  you had reset the core; the next Pause/Play starts the disc from the beginning.

The absence of the `STOP` message is how you tell the two apart: if it is on screen, a
resume is waiting for you.

The disc stays loaded either way. To unload it and return to the idle screen, use
**Reset** on the OSD's main page.

!!! note "Nothing is left standing still"
    A stopped or screensaving player deliberately shows nothing but the moving
    logo — no picture, no subtitle, no menu highlight. A still image left on a
    CRT burns in, which is what both features exist to prevent. Everything comes
    back the instant you press anything: nothing is torn down and nothing is
    reloaded, so a paused menu returns exactly as you left it.

    An ordinary **pause** is different — it keeps the picture and its subtitle on
    screen. Only Stop and the screensaver blank anything.

### Aspect

**B15 (Aspect)** cycles the aspect setting that applies to whatever you are watching on:
`Analog Aspect` when the analog/CRT raster is running, and `Aspect Ratio` otherwise. The
popup names which one moved — `ASPECT 16:9`, `ANALOG LETTERBOX` — so you can find it again
in the OSD. Changing the same setting in the OSD hands control back to the OSD.

Rapid presses settle before anything is applied, so holding down or mashing the button does
not make the display re-sync over and over.

### Chapter menu

**B16 (Chapter Menu)** jumps straight to the disc's own scene-selection page, rather than
stepping chapters one at a time with B2/B3. It needs **Disc Menus** switched on.

Roughly two discs in five author a chapter menu. On the rest the button falls back to the
disc's **main menu** instead — the same place B5 (Menu) goes — so it always lands somewhere
you can navigate out of.

### A-B repeat

**B17 (A-B Repeat)** loops a section. Press once at the start to mark **A**, again at the
end to mark **B**, and playback loops between them. A third press turns it off. The popup
tracks the state — `A-B  A SET`, `A-B  ON`, `A-B  OFF` — so a half-set loop is never a
mystery. Leaving the title or loading another disc clears it.

### Eject

**B19 (Eject)** unloads whatever is in the drive or the slot and returns you to the
idle screen. With a **physical disc** it also opens the tray. With a disc image it
simply unmounts it.

!!! note "Needs `MiSTer_DVDcss`"
    Eject and the volume buttons are serviced by the custom Main — the core cannot
    unmount a file or open a tray by itself. Without it, these three buttons do nothing.

### Volume

**B20 / B21 (Vol Up / Vol Down)** change **MiSTer's own** volume, the same one the OSD's
volume row sets. That is deliberate: it is a single control that covers HDMI, the analog
output *and* S/PDIF together, and it is the only one that can affect a bitstream being
passed through to a receiver. A press burst is applied in full, so tapping four times
moves four steps.

Your TV remote's own volume keys already work too, and always did — MiSTer handles those
itself, before the core ever sees them.

### Frame step

**B18 (Frame Step)** is the pause-and-nudge button. Press it while a disc is playing and
playback **pauses**; press it again and each press advances a single frame, staying paused.
It steps the same way from a pause you started with **B1**, and while the disc is stopped.

The first press only pauses — it does not also advance — so the frame you stop on is the one
that was on screen.

You can step as far into the film as you like, and pressing **Play** afterwards picks up in
sync however long you spent stepping. Audio is muted while you step, and the sound for the
frames you stepped past is discarded.

It is forward-only: the decoder works in groups of frames, so there is no way to step
backwards without re-decoding, which is a different feature.

## Support bundle chord

!!! note "Needs `MiSTer_DVDcss`"
    New in v0.4.0, and only with the custom Main installed.

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
