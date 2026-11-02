# Settings

Everything here is in the core's OSD. The **default is shown in bold**, and the
defaults are chosen to be correct for most setups — on a normal HDMI installation you
should not need to change anything.

Settings are saved to `/media/fat/config/DVD_v3.CFG` and persist across core reloads.

!!! info "Settings are grouped into pages"
    The OSD is grouped into pages by topic: Video, Analog / CRT, Audio, Subtitles &
    CC, Playback, Save State and Debug. Only where each setting sits changed; every
    setting keeps its saved value, so nothing resets.

## Main page

The first screen of the OSD: what you need to start a disc, and the pages below.

| Setting | Options | What it does |
|---|---|---|
| **Disc Menus** | **On** / Off | On boots the disc's authored First Play chain and runs its menus, like a set-top player. Off skips navigation entirely and auto-plays the main feature. |
| **Player Language** | **English** / 15 others | The player's language preference for menus, audio and subtitles, like a set-top player's setup screen. Discs use it to pick a default track. |

### Reset

**`Reset`** stops playback, unloads the current image, resets the DVD navigation VM, and
drops back to the bouncing-logo idle screen. Pick a new image from `Load Video` to play
again. A custom `boot.rom` logo survives the reset.

## Video page

| Setting | Options | What it does |
|---|---|---|
| **Aspect Ratio** | **Auto** / 4:3 / 16:9 | Auto reads the MPEG-2 sequence header, which is what the disc says it is. Override only if a disc is authored wrongly. |
| **Video Output** | **Auto** / Interlaced / Progressive | The core's one output-mode choice: authored interlaced fields (CRTs, true-video content) or progressive (HDMI, film) — see [Video Output](../video/interlaced.md). Auto follows `MiSTer.ini`. |
| **Deinterlace** | **Weave** / Bob / Blend | How the two fields of a true-interlaced picture (video-sourced 29.97i/25i, laserdisc-style FMV) are shown. **Weave** shows both at once: full detail, but combing on motion. **Bob** shows one field at a time with the missing lines filled in: smooth motion, half the vertical detail. **Blend** mixes each line with its neighbours, turning the comb into a soft ghost at the cost of some sharpness. The choices follow `Video Output`: **Progressive** offers all three; **Interlaced** offers Weave and Bob, and there they only change how HDMI shows the 480i/576i signal (a CRT always gets the real fields). Film and progressive content are never touched. See [Deinterlace](../video/interlaced.md#deinterlace). |
| **Video Standard** | **Auto** / NTSC / PAL | Auto detects from the stream's vertical size (480 = NTSC, 576 = PAL). |
| **Film 24p Out** | **Auto** / Off / On | 23.976 Hz output for film content — see [Film (24p)](../video/film-24p.md). |
| **Standard Convert** | **Off** / To NTSC / To PAL | Plays a disc of the other standard by changing its speed about 4 %, which also shifts its pitch and turns passthrough off. HDMI and `vga_scaler` only. See [Standard Convert](../video/film-24p.md#standard-convert). |

!!! note "Deinterlace replaces `480i Deint` (v0.8.0)"
    **Deinterlace** replaces the `480i Deint` setting and adds Bob and Blend for the
    Progressive output. Your other settings are kept, but whatever you had chosen for
    `480i Deint` returns to the default, **Weave**, once. If you watch the **Interlaced**
    output over HDMI and liked the old default (Bob), set `Deinterlace = Bob`.

!!! warning "New in v0.4.0 — your settings reset once"
    **Video Output** replaces the previous `Interlaced Out` and `Analog Out` settings
    (which overlapped confusingly), and this relayout bumps the saved-settings file to
    `DVD_v2.CFG` — [settings reset once](#settings-that-reset-after-an-update) the first
    time you run v0.4.0. Releases up to and including v0.3.0 still have the old pair.

## Analog / CRT page

Settings for the analog output (the I/O board's VGA, component and composite path), and
for showing widescreen content on a 4:3 display.

| Setting | Options | What it does |
|---|---|---|
| **Analog Aspect** | **Auto** / Fit / Letterbox / Crop | How anamorphic content fits a 4:3 TV — see [Analog Aspect](../video/analog-crt.md#analog-aspect). On `Video Output = Progressive` only Letterbox and Crop act (for a 4:3 VGA, 480p or HDMI display); Auto and Fit leave the aspect to the scaler — see [On Progressive](../video/analog-crt.md#analog-aspect-on-progressive). A widescreen disc menu can override it, as a set-top player does — see [Widescreen disc menus](../video/analog-crt.md#widescreen-disc-menus). |
| **Analog Dither** | **Off** / On | Smooths the banding a 6-bit analog DAC (the standard DE10-Nano I/O board) puts on dark gradients — see [Analog Dither](../video/analog-crt.md#analog-dither-if-dark-scenes-show-bands). Analog output only; HDMI is untouched. Leave it Off on a board with an 8-bit analog DAC. |
| **Analog CSync** | **SMPTE** / 2H | The shape of the composite sync on the analog output. **SMPTE** is the default and is what a broadcast signal carries. Change it only if your television or scaler is unhappy — see [Analog / CRT output](../video/analog-crt.md#analog-csync-if-your-set-jitters-or-shows-sawtooth-edges). |

## Audio page

| Setting | Options | What it does |
|---|---|---|
| **Audio** | **On** / Off | Master audio enable. |
| **Audio Out** | **Decode PCM** / Passthru (SPDIF+HDMI) | Decode PCM decodes in fabric and sends stereo. Passthru sends the undecoded bitstream to an AV receiver — see [Bitstream passthrough](../audio/passthrough.md). |
| **SPDIF Byte Order** | **Normal** / Swap | Applies to *both* bitstream outputs despite the name. If a receiver names the format but plays static, toggle this. |
| **A/V Offset** | **0 ms** / −200 / −100 / −50 / +50 / +100 / +150 / +200 | Lip-sync trim. |

!!! warning "New in v0.5.0 — they reset once more"
    **A/V Offset** now defaults to **0 ms** instead of +100 ms. Re-ordering the values so
    0 ms comes first remaps every saved setting, so the file bumps again to `DVD_v3.CFG`
    and settings reset one further time.

### A/V Offset

Default **0 ms**. There should be no need to change it.

!!! info "Changed in v0.5.0"
    This default was **+100 ms** in v0.4.0 and earlier. That was the correct null for a
    player whose clock was anchored on the demux front, which left audio about 100 ms
    early; the clock is now anchored on the picture actually being displayed, so the
    correction is no longer needed and would over-correct by the same amount.

It shifts audio relative to video, positive meaning audio later. If you genuinely need it,
the thing to know is that **it binds at start and re-start events only** — changing it
mid-title does nothing until the next seek, chapter jump or reload.

If lip sync is wrong in a way this does not fix, that is a bug rather than a setting;
[Troubleshooting](../reference/troubleshooting.md) has the cases that are known.

## Subtitles & CC page

| Setting | Options | What it does |
|---|---|---|
| **Line-21 CC** | **On** / Off | Re-inserts closed captions on line 21 of the analog output — see [Closed captions](../video/closed-captions.md). |
| **Force 4:3 Subpics** | **Off** / On | Forces subpicture geometry to 4:3 for discs that author it inconsistently. |

## Playback page

| Setting | Options | What it does |
|---|---|---|
| **D-Pad Seek** | **Off** / On | Puts fixed-time seeking on the D-pad — see [Controls](controls.md#d-pad-seek). |
| **Screensaver** | **5min** / Off / 2min / 10min | How long a paused or stopped disc sits still before the bouncing idle logo takes over. The picture goes with it, and so do the status line, the seek bar and any subtitle or disc menu highlight — nothing is left standing still, which is the whole point. Any button or key brings it all straight back, exactly as it was. It protects CRTs from burn-in and changes nothing about playback — your place is kept. |

## Save State page

Eight numbered save slots per disc, plus an automatic one. The full explanation, including what is and is not
kept, is on [Save states](save-states.md).

The page appears only while a DVD-Video disc or image is loaded: a VCD, a video file, a
WAV or an empty drive has nothing to save. With **Disc Menus** set to Off it is shown
greyed out, because save states need the disc's menus running.

| Setting | Options | What it does |
|---|---|---|
| **Slot** | **1** / 2 / 3 / 4 / 5 / 6 / 7 / 8 / Autosave | Picks which slot **Save to Slot** and **Load Slot** act on. It is only a selector: moving it does nothing on its own. **Autosave** is the place the player kept by itself when you changed disc or left the core; only **Load Slot** works on it. |
| **Save to Slot** | (action) | Saves the disc's navigation state and your position to that slot, then closes the OSD. |
| **Load Slot** | (action) | Restores them. Playback re-seeks, the way a chapter skip does, so there is a brief black moment before it resumes. |

These need the **MiSTer_DVDcss** Main, because the save file is written to your SD card,
and **Disc Menus** set to On. With the stock Main the rows do nothing.

## Debug page

Tuning and diagnostic levers. The two with sections below are the ones worth understanding
before you touch them; the rest exist for narrowing down problems.

| Setting | Options | What it does |
|---|---|---|
| **Debug Overlay** | **Off** / On | In a release build this shows the menu-highlight diagnostic blocks. |
| **Title VTS Tens** / **Title VTS Units** | **0** / **Auto** | Forces a specific title set instead of the auto-selected one. Diagnostic, for discs where the wrong title is picked with Disc Menus off. |
| **Frame Drop** | **On** / Off | **Leave this on.** See below. |
| **A/V Sync** | **On** / Off | Off stops scheduling *both* picture and sound against the disc's timestamps. Diagnostic only — see below. |
| **CC Test Line** | **Off** / On | Paints the caption waveform on a *visible* line to prove the chain works — see [the CC diagnostic](../video/closed-captions.md#is-it-working-the-test-line). |

### Frame Drop

Default **On**, and it should stay on.

If the decoder ever falls behind the display cadence (for example with **Film 24p Out =
On** over 29.97 fps video, which a 23.976 Hz raster cannot show), the frame-rate governor
absorbs it by dropping a B-frame to stay in step. B-frames are never used as references,
so the picture cannot be corrupted by this. On every disc measured the decoder keeps up
on both Video Output settings (see
[Compatibility](../reference/compatibility.md#video)).

It is also how the player catches up when it has fallen behind the disc's own timeline:
advancing past a frame is the only way to recover time that has already been lost. With
Frame Drop off there is no such mechanism, so if the picture ever falls behind it simply
runs progressively later and lip sync drifts with it. The Off position exists to isolate the
governor when diagnosing a pacing problem, not as a quality setting.

### A/V Sync

Default **On**, and it should stay on.

!!! info "Renamed in v0.5.0"
    This setting was called **Audio Genlock** in v0.4.0 and earlier. It was renamed
    because the old name described only half of what it does — and the half it named
    had not been true for some time.

With it on, everything the player shows you — picture, sound, subtitles, menu highlights,
captions and bitstream passthrough — is presented at the time the disc asks for, measured
against one clock. That is what lip sync *is* on this core.

Off switches that scheduling off wholesale, for video as well as audio: pictures are shown
as soon as they are decoded rather than when they are due, and sound plays as soon as it
is available. The result is a player with no lip sync at all. It is not a fallback for
sync problems and it will not improve one.

What it is for is answering one question quickly: if a disc misbehaves and it behaves
differently with A/V Sync off, the problem is in the player's timing rather than in
reading or decoding the disc. That is worth a great deal when a bug can only be
reproduced on someone else's disc, which is why the setting still has a row.

## Settings that reset after an update

Saved settings live in `/media/fat/config/DVD_v3.CFG`, where `v3` is a **layout version**.

When a release changes the OSD option layout incompatibly, that number is bumped, and your
settings fall back to the defaults rather than being silently misread — an old file's bits
would otherwise land on different options. Your previous file is left on the card, ignored,
and can be deleted.

This replaces the older "please delete your config file" release note. If your settings
reset after an update, that is why, and it happens once per layout change.
