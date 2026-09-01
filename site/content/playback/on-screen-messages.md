# On-screen messages

The core writes these over the picture when it needs to tell you something. Most clear
themselves; the ones that persist are describing a condition, not an event.

| Message | Meaning | What to do |
|---|---|---|
| `CSS ENCRYPTED` | The image or disc is CSS-encrypted and nothing available can decrypt it. Audio is muted so you get silence rather than static; video keeps playing so the disc stays identifiable. | Install libdvdcss, or use a decrypted rip — see [What you need](../getting-started/what-you-need.md). |
| `UNSUPPORTED IMAGE` | Not an ISO9660 DVD image — a UDF-only image, for instance — or not a playable stream at all. | Check the file is a whole-disc DVD image. See [Compatibility](../reference/compatibility.md). |
| `AUDIO UNSUPPORTED` | The selected audio track is in a format the core cannot decode. | Cycle to another track with B7, or use [passthrough](../audio/passthrough.md) if it is DTS. |
| `TITLE VTS nn` | Which title was auto-selected. Only shown with **Disc Menus** off. | Informational. If it picked the wrong one, `Title VTS` on the Debug page forces a choice. |
| `LINK FAIL nn` | A menu button's jump failed and the core recovered by re-entering the last working menu. | Usually harmless. If a disc is consistently unnavigable, it is worth reporting. |
| `SEEK FWD 12:30` | How far the pending [D-pad seek](controls.md#d-pad-seek) will jump, while you are still tapping. | Informational — stop tapping and the jump happens. |
| `No drive region: cracking` | A physical disc is playing on a drive with no region set, so keys are being recovered from the disc data. | Playback starts in a few seconds. [Set the drive region](../formats/physical-discs.md#set-the-drive-region) to avoid the wait. |
| `Decrypting ISO` | An encrypted image's keys are being recovered on first play. | Wait. It is cached afterwards, so this happens once per disc. |

!!! note "`UNSUPPORTED IMAGE` is patient by design"
    It is only raised after about 20 seconds of *actual streaming* with no picture, so slow
    media — a NAS spinning up, a cold USB drive — does not trigger it. It also clears itself
    if a picture does appear.

## Transport popups

These appear briefly when you change something, and are not errors:

| Popup | Meaning |
|---|---|
| `AUDIO 2/4 FR` | Audio track 2 of 4, French |
| `SUB 1/3 EN` / `SUB OFF` | Subtitle track, or subtitles disabled |
| `ANGLE 2/3` | Camera angle on a multi-angle disc |
| `CH 12/23` | Chapter, on a chapter step |
| `►► ×3` | Scrub speed while fast-forwarding or rewinding |

The status line along the bottom — `► 0:12:34/1:37:05 CH 12/23` — is toggled with **B9**
and also auto-shows for a couple of seconds on any of the above. `❚❚` replaces `►` when
paused.
