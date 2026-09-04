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
| `.bin` `.img` `.dat` | Video CD / SVCD raw-sector rips — see [Video CD / SVCD](../formats/vcd-svcd.md) |
| `.vob` | A single DVD program stream, played linearly |
| `.mpg` | MPEG program stream (MPEG-1 or MPEG-2) |
| `.m2v` | Bare MPEG-2 elementary video stream, no audio |

Only the first two give you navigation. A `.vob`, `.mpg` or `.m2v` is played straight
through with no menus, no chapters, and — for `.m2v` — no sound, because the format
carries none.

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

With **Disc Menus** off, navigation is skipped entirely and the main feature auto-plays.
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

!!! note "Fixed in v0.4.0"
    MGL launching did not work on v0.3.0: the core could come up blank and stop responding
    to the gamepad, needing a restart. If that is what you saw, update.

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
