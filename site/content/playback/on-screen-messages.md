# On-screen messages

The core writes these over the picture when it needs to tell you something. Most clear
themselves; the ones that persist are describing a condition, not an event.

| Message | Meaning | What to do |
|---|---|---|
| `CSS ENCRYPTED` | The core is seeing scrambled sectors, so nothing available is decrypting this disc or image. Audio is muted to give you silence rather than static; video keeps playing so the disc stays identifiable. | Install libdvdcss, or use a decrypted rip — see [What you need](../getting-started/what-you-need.md). If the picture is perfect and only the sound is missing, the message is wrong — please [report it](../reference/reporting-a-bug.md). |
| `UNSUPPORTED IMAGE` | Not an ISO9660 DVD image — a UDF-only image, for instance — or not a playable stream at all. Also a `.wav` the core cannot play (mono, 24-bit, floating point, 96 kHz). | Check the file is a whole-disc DVD image, or a 16-bit stereo 44.1/48 kHz `.wav`. See [Compatibility](../reference/compatibility.md). |
| `Cannot play this CUE sheet` | A [`.cue` sheet](../getting-started/loading.md#playing-a-cue) could not be played; the next line says why (a missing file, an unsupported file type, a data-only disc). | See [Troubleshooting](../reference/troubleshooting.md#cannot-play-this-cue-sheet). |
| `AUDIO UNSUPPORTED` | The selected audio track is in a format the core cannot decode. | Change track with B7 (press it twice: once to show the track, again to change it), or use [passthrough](../audio/passthrough.md). On a DTS track it means the DTS decoder could not load its tables at start-up — please report it. On an LPCM track it means the track's header declares a rate or word length DVD-Video does not allow (44.1/32 kHz, or an undefined word length). |
| `TITLE VTS nn` | Which title was auto-selected. Only shown with **Disc Menus** off. | Informational. If it picked the wrong one, `Title VTS` on the Debug page forces a choice. |
| `LINK FAIL nn` | A menu button's jump failed and the core recovered by re-entering the last working menu. | Usually harmless. If a disc is consistently unnavigable, it is worth reporting. |
| `SEEK FWD 12:30` | How far the pending [D-pad seek](controls.md#d-pad-seek) will jump, while you are still tapping. | Informational — stop tapping and the jump happens. |
| `No drive region: cracking` | A physical disc is playing on a drive with no region set, so keys are being recovered from the disc data. | Playback starts in a few seconds. [Set the drive region](../formats/physical-discs.md#set-the-drive-region) to avoid the wait. |
| `Decrypting ISO` | An encrypted image's keys are being recovered on first play. | Wait. It is cached afterwards, so this happens once per disc. |

!!! note "`UNSUPPORTED IMAGE` is patient by design"
    It is only raised after about 20 seconds of *actual streaming* with no picture. The
    timer counts delivered data, not wall-clock time, so slow media — a NAS spinning up, a
    cold USB drive — does not trigger it, and it clears itself if a picture appears.

    A consequence worth knowing: a mount that fails outright delivers no data at all, so it
    produces **no message**. Silence means the core never got the file; `UNSUPPORTED IMAGE`
    means it read the file and could not play it. See
    [Troubleshooting](../reference/troubleshooting.md#nothing-plays).

    **One exception, and it is immediate:** a `.wav` whose format the core cannot play is
    rejected the moment its header is read, with no 20-second wait. The header states the
    format, so there is nothing to be patient about — and the alternative would be playing
    it as noise.

## Support bundle

!!! note "Needs `MiSTer_DVDcss`"
    New in v0.4.0, and only with the custom Main installed.

Shown when you hold **Audio + Subtitle** for two seconds to write a
[support bundle](../reference/reporting-a-bug.md#or-make-one-on-the-mister-itself).

| Message | Meaning |
|---|---|
| `Generating support bundle...` | Started. It runs in the background, so playback carries on. |
| `Support bundle written to DVD_reports/…` | Done — that is the file to attach to an issue. |
| `Nothing to bundle` | No image or disc was found. The lines beneath say what was seen; `mounted: (not captured)` with a disc playing is a bug worth reporting. |
| `Support bundle needs dvd_report.py` | Put `dvd_report.py` in `/media/fat/Scripts/` — the release zip does this for you. |
| `Support bundle FAILED` | The collector errored. `/tmp/dvd_report_run.log` says why; the usual cause is a missing or very old python3. |
| `Could not start bundle generation` | The player could not spawn the collector at all. |

## Transport popups

These appear briefly when you change something, or when you press Audio or Subtitle to
check the current track, and are not errors:

| Popup | Meaning |
|---|---|
| `AUDIO 2/4 FR` | Audio track 2 of 4, French |
| `SUB 1/3 EN` / `SUB OFF` | Subtitle track, or subtitles disabled |
| `ANGLE 2/3` | Camera angle on a multi-angle disc |
| `CH 12/23` | Chapter, on a chapter step |
| `TR 3/12` | Track, on an audio CD — it replaces `CH`, since a CD has no chapters |
| `►►►` | Scrub speed while fast-forwarding or rewinding — two to five arrows, more the longer you hold |


The status line along the bottom — `► 0:12:34/1:37:05 CH 12/23` — is toggled with **B9**
and also auto-shows for a couple of seconds on any of the above. `❚❚` replaces `►` when
paused.

In a pause, **B9 decides on its own**: a pause you start with **B1** brings the line and the
seek bar up, a pause you start with **Frame Step** leaves the picture clean, and B9 toggles
either of them as often as you like. See [Frame step](controls.md#frame-step).

**While a seek is pending the time shows where you are going, not where you are.** Hold
Fast Fwd or Rewind, step chapters, or tap out a D-pad seek and the elapsed time tracks the
seek bar's cursor, so the two always agree; it returns to the live position once the seek
lands. On a `.mpg`, `.VOB` or VCD/SVCD the whole clock is an estimate worked out from how
fast the file is playing — see [VCD & SVCD](../formats/vcd-svcd.md).

## Save states

These come from the MiSTer Main rather than the core, so they appear in the usual grey
notice box rather than over the picture.

| Message | Meaning |
|---|---|
| `Saved to slot N` | The state was written. |
| `Loaded slot N` | The state was restored; playback re-seeks. |
| `Slot N is empty` | Nothing has been saved there for this disc yet. |
| `That save is from a different disc` | The file was copied or renamed from another disc, and was refused. |
| `This disc has no save slots` | Nothing is loaded, or the loaded item is not a DVD-Video disc (VCD, SVCD, a video file). |
| `Save states need Disc Menus on` | Disc Menus is Off, so the disc's own program, which a save state holds, is not running. |
| `That save file is damaged` | The save file is truncated or corrupted, and was not loaded. |
| `That save is from another version of the core` | The save was made by a core whose internal state is laid out differently, and was refused. |
| `Could not save: the player stayed busy. Try again` / `Could not load: the player stayed busy. Try again` | The disc was mid-jump for the three seconds the player waited. |
| `Could not write the save file` / `Could not read the save file` | An SD card problem: full, read-only, or the file cannot be opened. |

With the stock Main none of these appear: nothing answers the Save State rows.

Full explanation: [Save states](save-states.md).
