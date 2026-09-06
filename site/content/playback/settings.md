# Settings

Everything here is in the core's OSD. The **default is shown in bold**, and the
defaults are chosen to be correct for most setups — on a normal HDMI installation you
should not need to change anything.

Settings are saved to `/media/fat/config/DVD_v3.CFG` and persist across core reloads.

## Main page

| Setting | Options | What it does |
|---|---|---|
| **Aspect Ratio** | **Auto** / 4:3 / 16:9 | Auto reads the MPEG-2 sequence header, which is what the disc says it is. Override only if a disc is authored wrongly. |
| **Disc Menus** | **On** / Off | On boots the disc's authored First Play chain and runs its menus, like a set-top player. Off skips navigation entirely and auto-plays the main feature. |
| **D-Pad Seek** | **Off** / On | Puts fixed-time seeking on the D-pad — see [Controls](controls.md#d-pad-seek). |
| **Audio** | **On** / Off | Master audio enable. |
| **Audio Out** | **Decode PCM** / Passthru (SPDIF+HDMI) | Decode PCM decodes in fabric and sends stereo. Passthru sends the undecoded bitstream to an AV receiver — see [Bitstream passthrough](../audio/passthrough.md). |
| **SPDIF Byte Order** | **Normal** / Swap | Applies to *both* bitstream outputs despite the name. If a receiver names the format but plays static, toggle this. |
| **Player Language** | **English** / 15 others | The player's language preference for menus, audio and subtitles, like a set-top player's setup screen. Discs use it to pick a default track. |
| **Video Output** | **Auto** / Interlaced / Progressive | The core's one output-mode choice: authored interlaced fields (CRTs, true-video content) or progressive (HDMI, film) — see [Video Output](../video/interlaced.md). Auto follows `MiSTer.ini`. |
| **480i Deint** | **Bob** / Weave | How the framework scaler deinterlaces when receiving 480i (HDMI, while Video Output is Interlaced). |
| **Analog Aspect** | **Auto** / Fit / Letterbox / Crop | How anamorphic content fits a 4:3 analog TV — see [Analog Aspect](../video/analog-crt.md#analog-aspect). |
| **Video Standard** | **Auto** / NTSC / PAL | Auto detects from the stream's vertical size (480 = NTSC, 576 = PAL). |

!!! warning "New in v0.4.0 — your settings reset once"
    **Video Output** replaces the previous `Interlaced Out` and `Analog Out` settings
    (which overlapped confusingly), and this relayout bumps the saved-settings file to
    `DVD_v2.CFG` — [settings reset once](#settings-that-reset-after-an-update) the first
    time you run v0.4.0. Releases up to and including v0.3.0 still have the old pair.

!!! info "Unreleased — they reset once more"
    **A/V Offset** now defaults to **0 ms** instead of +100 ms. Re-ordering the values so
    0 ms comes first remaps every saved setting, so the file bumps again to `DVD_v3.CFG`
    and settings reset one further time.

### Reset

**`Reset`** stops playback, unloads the current image, resets the DVD navigation VM, and
drops back to the bouncing-logo idle screen. Pick a new image from `Load Video` to play
again. A custom `boot.rom` logo survives the reset.

## Debug page

The second OSD page. These are tuning and diagnostic levers — two of them affect normal
playback and are documented properly below; the rest exist for narrowing down problems.

| Setting | Options | What it does |
|---|---|---|
| **Debug Overlay** | **Off** / On | In a release build this shows the menu-highlight diagnostic blocks. |
| **Title VTS Tens** / **Title VTS Units** | **0** / **Auto** | Forces a specific title set instead of the auto-selected one. Diagnostic, for discs where the wrong title is picked with Disc Menus off. |
| **Frame Drop** | **On** / Off | **Leave this on.** See below. |
| **Audio Genlock** | **On** / Off | Off free-runs the audio clock instead of slaving it to the video timeline. Diagnostic only. |
| **Force 4:3 Subpics** | **Off** / On | Forces subpicture geometry to 4:3 for discs that author it inconsistently. |
| **Line-21 CC** | **On** / Off | Re-inserts closed captions on line 21 of the analog output — see [Closed captions](../video/closed-captions.md). |
| **CC Test Line** | **Off** / On | Paints the caption waveform on a *visible* line to prove the chain works — see [the CC diagnostic](../video/closed-captions.md#is-it-working-the-test-line). |
| **Analog CSync** | **SMPTE** / 2H / Stock | The shape of the composite sync on the analog output. **SMPTE** is the default and is what a broadcast signal carries. Change it only if your television or scaler is unhappy — see [Analog / CRT output](../video/analog-crt.md#analog-csync-if-your-set-jitters-or-shows-sawtooth-edges). |
| **Field Order** | **Normal** / Swap | Which decoded field lands in which raster field. Try **Swap** if an interlaced picture looks out of order — see [Analog / CRT output](../video/analog-crt.md#field-order). |
| **Film 24p Out** | **Auto** / Off / On | 23.976 Hz output for film content — see [Film (24p)](../video/film-24p.md). |
| **A/V Offset** | **0 ms** / −200 / −100 / −50 / +50 / +100 / +150 / +200 | Lip-sync trim. |

### Frame Drop

Default **On**, and it should stay on.

The inherited MPEG-2 decoder has a motion-compensation and IDCT throughput ceiling, and on
the heaviest content it can fall behind the display cadence. The frame-rate governor
absorbs this by dropping a B-frame to stay in step. B-frames are never used as references,
so the picture cannot be corrupted by this, and in practice it is not something you notice.

More importantly, the **cadence-slip corrector runs on the same path**. That is what keeps
imperfect real-world telecine — discs where the 3:2 pattern is not clean — in step with the
display. Turning Frame Drop off disables it, so film content drifts. The Off position
exists to isolate the governor when diagnosing a pacing problem, not as a quality setting.

### A/V Offset

Default **0 ms**. There should be no need to change it.

!!! info "Unreleased"
    This default was **+100 ms** in v0.4.0 and earlier. That was the correct null for a
    player whose clock was anchored on the demux front, which left audio about 100 ms
    early; the clock is now anchored on the picture actually being displayed, so the
    correction is no longer needed and would over-correct by the same amount.

It shifts audio relative to video, positive meaning audio later. If you genuinely need it,
the thing to know is that **it binds at start and re-start events only** — changing it
mid-title does nothing until the next seek, chapter jump or reload.

If lip sync is wrong in a way this does not fix, that is a bug rather than a setting;
[Troubleshooting](../reference/troubleshooting.md) has the cases that are known.

## Settings that reset after an update

Saved settings live in `/media/fat/config/DVD_v3.CFG`, where `v3` is a **layout version**.

When a release changes the OSD option layout incompatibly, that number is bumped, and your
settings fall back to the defaults rather than being silently misread — an old file's bits
would otherwise land on different options. Your previous file is left on the card, ignored,
and can be deleted.

This replaces the older "please delete your config file" release note. If your settings
reset after an update, that is why, and it happens once per layout change.
