# Save states

Interactive DVDs are real games. Wickles Manor in *Scooby-Doo 2*, the question decks in
*Scene It?*, the branching paths in *Atmosfear*: they all keep progress, and without save
states every load starts them from the beginning.

Save states let you keep that progress. You get **eight numbered slots per disc**, from the
OSD.

They also work as bookmarks on ordinary films: stop halfway through a long film, come back
tomorrow, and carry on.

!!! info "You need the DVD Main"
    Save states are written to your SD card, and only the MiSTer Main can do that. So
    this needs **MiSTer_DVDcss** installed, the same custom Main that physical discs, CSS
    decryption and HDMI bitstream audio already require. See
    [Install](../getting-started/install.md).

    With the stock Main the rows still appear, but nothing answers them: pressing
    **Save to Slot** or **Load Slot** does nothing and no message appears.

## Saving

1. Open the OSD and go to the **Save State** page. It is there only while a DVD-Video disc
   or image is loaded.
2. Pick a **Slot** from 1 to 8.
3. Choose **Save to Slot**. The OSD closes and the player confirms `Saved to slot N`.

## Loading

Go to the same page, pick the same slot and choose **Load Slot**. The player jumps
straight back to where you were and confirms `Loaded slot N`.

You can load at any time: during a film, in a menu, or while the disc is still playing its
opening logos.

## What gets saved

Everything the *disc's own program* is keeping track of, plus where you were:

- the disc's navigation state: which menu or title, which program chain and cell, and
  the variables the disc uses to remember your progress (scores, rooms visited, answers
  given)
- the disc's random-number state, so a game that rolls dice picks up where it left off
- where you were in a film, to about a second
- the button you had highlighted, even on a menu that normally starts on a particular
  button whenever you enter it
- your audio track, subtitle and camera-angle choices

## What does not

**The picture is not frozen and restored.** Loading a state re-seeks the disc, the way a
chapter skip does: there is a brief black moment, then playback resumes.

- **In a film** it lands within about a second of the picture that was on screen when you
  saved.
- **In a menu or a game** it lands back on that menu or at the start of that scene,
  with the disc's variables as they were. That is the natural place to resume, because
  interactive discs wait for your input there anyway.

## Slots are per disc

Each disc gets its own eight slots, and the player recognises a disc by reading it rather
than by its filename. That has two useful consequences:

- **Renaming your rip does not lose your saves.**
- **A disc and your rip of it share slots.** You can save on the physical disc and load
  from the ISO. This works whether the ISO is an exact image of the disc or was rebuilt
  from its `VIDEO_TS` folder: the player identifies the disc by its `VIDEO_TS.IFO`, which
  neither kind of rip changes.

Save files live in `savestates/DVD/` on your SD card. Each name is `DVD-` (or the disc's
publisher, when the disc records one), then a code that identifies the disc, then the slot
number.

!!! warning "A save belongs to the disc it came from"
    If you copy a save file to another disc's name, the player refuses it and says
    `That save is from a different disc`. A disc's navigation variables mean completely
    different things from one disc to the next, so loading one disc's save into another
    would jump somewhere arbitrary.

## Disc Menus must be on

Save states save and restore the disc's own program, which only runs with **Disc Menus**
set to On. With it set to Off the player skips the disc's menus and plays the main feature
by itself, so there is nothing to save or restore. The **Save State** page is then shown
greyed out. If a press does reach the player, it says `Save states need Disc Menus on`.

## Limitations

- **VCD, SVCD and plain video files get no slots.** They have no disc identity to key them
  to, and no navigation state worth keeping. The seek controls already cover them. The
  player says `This disc has no save slots`.
- **One state per slot.** Saving to a slot replaces what was there; there is no undo.
- **Loading is not frame-exact**, for the reasons above.
- **A core update can retire old saves.** A save records the layout of the player's
  internal state. If an update changes that layout, older saves are refused with
  `That save is from another version of the core` instead of being loaded wrongly. Most
  updates do not change it.

## If something goes wrong

| The player says | What it means |
|---|---|
| `Saved to slot N` | Done. |
| `Loaded slot N` | Done. |
| `Slot N is empty` | Nothing has been saved there yet for this disc. |
| `That save is from a different disc` | The file was copied or renamed from another disc. |
| `This disc has no save slots` | Nothing is loaded, or what is loaded is not a DVD-Video disc (a VCD, an SVCD, a video file). |
| `Save states need Disc Menus on` | Disc Menus is Off. See [Disc Menus must be on](#disc-menus-must-be-on). |
| `That save file is damaged` | The file on the SD card is truncated or corrupted, so it was not loaded. |
| `That save is from another version of the core` | The save was made by a core whose internal state is laid out differently. See [Limitations](#limitations). |
| `Could not save: the player stayed busy. Try again` / `Could not load: the player stayed busy. Try again` | The disc was in the middle of a jump for the whole three seconds the player waited. Try again a moment later. |
| `Could not write the save file` / `Could not read the save file` | A problem with the SD card: it is full or read-only, or the file cannot be opened. |
| *nothing at all* | The stock Main is installed. See the note at the top. |

See also [Troubleshooting](../reference/troubleshooting.md#save-states).
