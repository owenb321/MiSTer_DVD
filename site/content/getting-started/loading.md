# Loading a movie

Put your images in the core's folder on the SD card:

```
/media/fat/games/DVD/
```

That is where the OSD file picker opens when you choose **`Load Video`** — create the
folder if it does not exist yet. Anywhere else the MiSTer file browser can reach works
too — USB storage or a network share — see
[Where to keep them](discs-and-images.md#where-to-keep-them).

Accepted file types:

| Extension | What it is |
|---|---|
| `.iso` | DVD-Video image, decrypted or (with the add-ons) encrypted |
| `.cue` | Cue sheet for a CD rip — an **audio CD** or a **Video CD / SVCD**. Needs [`MiSTer_DVDcss`](what-you-need.md); see [Playing a `.cue`](#playing-a-cue) |
| `.bin` `.img` `.dat` | Video CD / SVCD raw-sector rips — see [Video CD / SVCD](../formats/vcd-svcd.md) |
| `.vob` | A single DVD program stream, played linearly |
| `.mpg` | MPEG program stream (MPEG-1 or MPEG-2) |
| `.m2v` | Bare MPEG-2 elementary video stream, no audio |
| `.wav` | PCM audio file — 16-bit stereo, 44.1 or 48 kHz. Audio only, no picture |

An `.iso` gives you disc menus and chapters, and a `.cue` gives you tracks. A `.vob`,
`.mpg` or `.m2v` is played straight through with no menus, no chapters, and — for `.m2v` —
no sound, because the format carries none.

## Playing a `.cue`

A `.cue` sheet is the small text file a CD ripper writes next to the `.bin` (or `.wav`)
files, describing where each track starts. Select the **`.cue`** and the player reads it
and works out what the disc is:

- **An audio CD** plays exactly as a [music CD in the drive](../formats/physical-discs.md#audio-cds)
  does: the bouncing logo, `TR 3/12` with the time *within* the track, a per-track
  progress bar, and **Next / Previous Chapter** skipping tracks. Data tracks on an enhanced
  or mixed-mode disc are skipped.
- **A Video CD or SVCD** plays as described on [Video CD / SVCD](../formats/vcd-svcd.md) —
  but you no longer need to know which `.bin` holds the movie, and any audio tracks on the
  disc are left out cleanly.

The sheet's files can be one `.bin` for the whole disc or one per track, and audio rips
with one `.wav` per track (the way EAC writes them) work too. The `.wav` files must be
CD audio: 16-bit stereo at 44.1 kHz. A sheet written on Windows is fine — the drive-letter
paths and the letter case are sorted out for you. Keep the sheet in the same folder as its
files.

A `.cue` needs the [`MiSTer_DVDcss`](what-you-need.md) add-on, because it is the MiSTer's
own software, not the FPGA, that reads the sheet. On the bare core a `.cue` still shows up
in the file picker, but nothing plays; select the `.bin` instead.

If the sheet cannot be played, the reason pops up — `Cannot play this CUE sheet`, followed
by the problem, such as a missing file. See
[Troubleshooting](../reference/troubleshooting.md#cannot-play-this-cue-sheet).

## Playing a `.wav`

A `.wav` plays as **audio only**: the bouncing logo fills the screen. The status line
and a progress bar show where you are in the file, like a CD player's front panel;
they start out shown, and **Display** hides or shows them. Pause, the seek bar and
the D-pad time jumps all work as they do for video; there are no chapters.

The core plays **16-bit stereo PCM at 44.1 or 48 kHz** — the CD and DVD sample rates.
Anything else (mono, 24-bit, floating point, 96 kHz) is refused with `UNSUPPORTED IMAGE`
rather than played as noise. Compressed formats — MP3, FLAC, AAC, Ogg — are **not**
supported; there is no decoder for them in the core.

`Audio Out` can be left on either setting. A `.wav` is PCM, so it plays as PCM on both
outputs even in `Passthru` — the same way an LPCM or MP2 track does.

## The idle screen

When the core is loaded without a disc it **opens the OSD file picker by itself** after
about a second, the way the console cores do, and a **bouncing logo screensaver** plays
behind it until something is mounted. A bare launch is never just a black screen.

You can replace the logo with your own artwork — see [Idle logo](../customising/idle-logo.md).

## Starting playback

With **Disc Menus** on (the default), a DVD boots the way a set-top player does: the
disc's First Play chain runs — copyright screens, studio idents — and then its main menu
appears. Navigate with the D-pad and press **B4** to select. See
[Controls](../playback/controls.md).

With **Disc Menus** off, navigation is skipped entirely and the main feature auto-plays:
the player picks the disc's largest title set, and within it the longest programme. On a
TV disc that is usually the "play all" chain rather than the first episode.
The core shows `TITLE VTS nn` to say which title it picked. This is the escape hatch for a
disc whose menus misbehave.

!!! tip "Skipping the opening chain"
    Pressing **Menu** (B5) over a copyright or warning screen goes straight to the disc's
    main menu, before the disc has shown you one. Some discs — DVD games especially — use this boot chain to perform set up steps and may behave incorrectly if skipped. See
    [Menu during the opening chain](../playback/controls.md#menu-during-the-discs-opening-chain).

## Launching from an MGL shortcut

An **MGL** is MiSTer's shortcut file: put one in the SD root or in a `_` menu folder and
it appears in the MiSTer menu, loads the core and starts a movie in one step. The DVD core
supports them.

```xml title="The Terminator (1984).mgl"
<mistergamedescription>
  <rbf>_Other/DVD</rbf>
  <file delay="5" type="s" index="0" path="Movies/The Terminator (1984).mpg"/>
</mistergamedescription>
```

- `rbf` — where the core lives on the SD card, without the date and `.rbf`.
- `type="s"` and `index="0"` — the core's one file slot, **Load Video**. These do not
  change; any file type from the table above goes in the same slot.
- `path` — relative to `/media/fat/games/DVD/`, or an absolute path starting with `/` if
  the file lives somewhere else (a network share, for example).
- `delay` — seconds to wait after the core loads before mounting. 1 is usually enough;
  raise it if the file lives on a slow share.

The name of the `.mgl` file is what shows in the menu, so it can differ from the movie's
filename.

## Loading something else

**`Reset`** in the OSD stops playback, unloads the current image, resets the navigation
VM, and returns to the idle screen, where you can pick a new file. A custom idle logo
survives the reset.

You can also load a new file directly from `Load Video` while something is playing — the
core cuts to black and starts the new one cleanly.

## If nothing happens

A black screen with the core sitting idle and **no message at all** is almost always a
**read-only network share** — see the warning in
[Discs and images](discs-and-images.md#where-to-keep-them). No message means the core never
received the file; it is not the same as `UNSUPPORTED IMAGE`, which means the file was read
and could not be played.

Anything else, the core will usually tell you: check
[On-screen messages](../playback/on-screen-messages.md) and
[Troubleshooting](../reference/troubleshooting.md).
