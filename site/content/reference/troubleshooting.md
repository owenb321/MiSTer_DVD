# Troubleshooting

Symptoms and what causes them. If the core has put a message on screen,
[On-screen messages](../playback/on-screen-messages.md) decodes it.

## Nothing plays

### Black screen, core sits idle, no error message

**Almost always a read-only network share.** The MiSTer framework opens disk images
read-write (`O_RDWR|O_SYNC`) whether or not anything writes to them, so a read-only mount
fails and you get silence with no diagnostic. The same file plays fine from the SD card,
which makes it look like a size or filesystem problem.

**Fix:** re-mount the share read-write.

!!! note "Why there is no message"
    The absence of one is the clue. `UNSUPPORTED IMAGE` is raised only after the core has
    *actually received sector data* for a while without producing a picture — a mount that
    fails outright delivers nothing, so that timer never starts. If you get no message at
    all, the core never got the file; if you get `UNSUPPORTED IMAGE`, it read the file and
    could not play it. Those are different problems.

### `UNSUPPORTED IMAGE`

Either the image is not ISO9660 — a **UDF-only** image will not load — or the file is not a
playable stream at all. Check you ripped a whole-disc DVD-Video image rather than a
transcode. See [Compatibility](compatibility.md).

Note this message is only raised after about 20 seconds of actual streaming, so it is not
what you will see from slow media.

### `CSS ENCRYPTED`

The image or disc is encrypted and nothing available can decrypt it. Audio is muted
deliberately so you get silence rather than static; video keeps playing so you can still
identify the disc.

**Fix:** install `MiSTer_DVDcss` and libdvdcss, or use a decrypted rip. See
[What you need](../getting-started/what-you-need.md).

### The core loads but a physical disc does nothing

Check, in order:

1. `MiSTer_DVDcss` is at `/media/fat/MiSTer_DVDcss` — **not** overwriting `/media/fat/MiSTer`
2. `MiSTer.ini` has a `[DVD]` section with `main=MiSTer_DVDcss`
3. The core was reloaded after adding that — the Main is chosen at core load
4. The drive is a USB optical drive that enumerates on the MiSTer

See [Physical discs](../formats/physical-discs.md).

## No sound

### Silent on every track

- **`Audio Out` is on `Passthru`** and your display cannot decode bitstreams. Passthru is
  silent on an ordinary television. Switch to **Decode PCM**.
- **`Audio` is Off** on the main OSD page.

### Silent on one track only

Press **B7** to cycle audio tracks. The disc's default may be:

- **DTS** — there is no DTS decoder in the core. Use
  [Passthru](../audio/passthrough.md) to a receiver, or pick the disc's AC-3 track.
- **LPCM or MP2 while in Passthru** — those have no bitstream form and are silent in that
  mode. Use Decode PCM.
- **AC-3 1+1 dual mono** — deliberately refused, since it carries two independent
  programmes with no correct way to combine them.

`AUDIO UNSUPPORTED` on screen means exactly this.

If none of those fit — a track is silent with no message, or cycling lands on the wrong
language — the fault is likely in how the disc maps tracks to soundtracks, which lives in
its navigation tables. A [repro bundle](reporting-a-bug.md) captures those, so that report
can be reproduced without the disc.

### Sound is out of sync after changing `Video Output` mid-title

**Skip a chapter.** That re-anchors the audio to the picture and clears it.

Changing the output mode under a playing disc restarts the raster and the A/V timing
together, and the audio does not always come back on the picture's timeline. It is
long-standing behaviour on every release. Setting `Video Output` before loading the disc
avoids it entirely. See [Video Output](../video/interlaced.md).

If sound drifts out of sync **without** a mode change, that is a different problem — try
`A/V Offset` on the debug page first, and [report it](reporting-a-bug.md) with the disc and
roughly how far into the title it started.

### Menu audio went silent

You changed the audio track while the menu was open. It comes back when you leave the menu.
Known limitation.

### The receiver names the format but plays static

Toggle **`SPDIF Byte Order`** (Normal / Swap). The receiver is reading the stream header
correctly but the payload byte order is wrong for it. This is the classic passthrough
failure and is a runtime toggle for that reason.

### No audio over HDMI in Passthru, but optical works

**HDMI bitstream needs `MiSTer_DVDcss`.** On the stock Main the core deliberately will not
emit a bitstream over HDMI — see [What you need](../getting-started/what-you-need.md).

If the custom Main *is* installed and HDMI is still silent, the core is probably not
engaging because your receiver's EDID does not advertise AC-3/DTS. Receivers reached over
**ARC** frequently misreport this. Force it in `MiSTer.ini`:

```ini
[DVD]
main=MiSTer_DVDcss
dvd_hdmi_bitstream=2      ; 0=auto (default), 1=off, 2=force
```

Read `/tmp/dvd_hdmi_audio.log` to see what it decided and why — it records the EDID result
and each stage of the handoff.

### The receiver shows "decoder off" during silent menus or gaps

Expected, with no current fix: authored silence carries no bitstream, and a receiver holds
lock only on real data. It re-acquires in under a second when audio returns. See
[Limitations](../audio/passthrough.md#limitations).

Dropouts at a **title start** or on a **track change** are a different, already-fixed bug —
update to a newer build.

## Picture problems

### 16:9 content looks tall and thin on a CRT

Set **`Analog Aspect`** to `Letterbox` (or `Crop`). Anamorphic content is stored squeezed
into a 4:3 raster and needs unsqueezing. See
[Analog Aspect](../video/analog-crt.md#analog-aspect).

### Motion looks juddery or wobbly on a CRT

Make sure **`Video Output`** is `Interlaced` (or `Auto` with the
[analog ini bits](../video/analog-crt.md#turning-it-on) set) —
the CRT then gets the disc's authored fields. See [Video Output](../video/interlaced.md).
On builds up to v0.3.0 the equivalent setting is `Analog Out = Native Fields`; those
builds' other analog modes have a known field-pairing wobble on video-sourced content.

### The picture shakes or tears about once a second on a CRT or scaler

Seen on RGB SCART and YPbPr connections (composite sync / sync-on-Y) with v0.4.0 and the
PR #37 prerelease, including at the idle logo, often with a RetroTINK reporting the
vertical sync length or line count toggling and MiSTer reading `1441x478i` or
`59.8 <-> 60.1 Hz`. The current development build reworks the analog path — the main
interlaced raster carries the half-line that interleaves the fields and drives the pins
directly, and several internal events that could restart the raster are fixed — and
reports a steady `720x480i @ 59.94 Hz`. If it still happens on a current build, turn on
`Debug Overlay` (`O[2]`): a third row of small blocks appears in the top-left while
Interlaced — green means an internal raster event fired. Please
[report](reporting-a-bug.md) which blocks are green, your connection type and the
`MiSTer.ini` video lines.

### The picture goes aliased / screen-door after a chapter skip on a CRT

Toggle `Video Output` away and back to re-roll the field phase — sometimes it takes a few
attempts. On builds up to v0.3.0 the same trick works on `Analog Out`. Many televisions
never show this; it depends on the set.

!!! info "Unreleased"
    The current development build corrects the field phase automatically — confirmed on
    hardware, and the toggle is no longer needed. (v0.4.0's first attempt at that
    corrector was switched off again: it was making both fields carry the same picture
    lines, which combed still images on every output including HDMI.) The same fix run
    also corrected HDMI `480i Deint` = `Weave`, which used to comb on a still about half
    the time. Televisions differ, so if either symptom survives on a current build,
    please [report it](reporting-a-bug.md). See
    [Field alignment](../video/interlaced.md#field-alignment).

### The picture blocks up briefly right after a chapter skip or seek

!!! info "Unreleased"
    Fixed in the development build; not in v0.3.0. On a release build you will still see
    the artifact described below.

On v0.3.0, for roughly six frames — about a tenth of a second — the new scene decodes and
moves correctly but the old one shows through it as a blocky residual, then it clears on
its own. It happens on every disc and on every way of jumping: chapter skip, Fast Fwd /
Rewind, D-Pad Seek, and entering or leaving a menu.

It is a decoder artifact, not a disc or a setting: the player was still predicting each new
picture from the scene it had just left ([issue
#45](https://github.com/owenb321/MiSTer_DVD/issues/45)). The development build discards
those pictures instead of showing them, so the last frame simply holds until the new scene
is ready.

**What remains on the development build** is much shorter, and confirmed on hardware: the
picture freezes on the last frame, then cuts to the new position with about **one**
misaligned frame in between. Report it if you see the old scene *moving* through the new
one, if the blocking lasts appreciably longer than a frame, or if the picture does not
recover on its own.

Changing `Video Output` mid-title goes through the same landing sequence — see
[Switching mid-title](../video/interlaced.md).

### A film disc keeps changing resolution, or judders

Set **`Film 24p Out` = `On`**. The disc is probably **hard-telecined**, meaning the pulldown
was baked in at authoring time and carries no flags for Auto to detect. See
[Film (24p)](../video/film-24p.md).

Also confirm **`Frame Drop` is On** — the cadence corrector runs on that path.

### MiSTer reports 1441x478i, or the resolution changes when a disc loads

An off-by-one in the idle raster window on v0.4.0 and the PR #37 prerelease. Fixed in
the current development build: the idle logo and playback both report `720x480i`.

### The idle logo bounces in a small box on a widescreen display

Fixed in current builds. Update the core.

### Black & white picture over composite or S-video

`MiSTer.ini` is missing `vga_mode=svideo` (or `vga_mode=cvbs` for composite). Without it
the framework's Y/C encoder is off, the pins carry raw RGB, and the luma line shows a
stable colorless picture. The chroma standard (PAL/NTSC) is picked automatically once the
encoder is on. See [Analog and CRT output](../video/analog-crt.md#turning-it-on).

If `vga_mode` is set and other cores show color on the same cable but the DVD core does
not — or an NTSC disc shows color while a PAL disc is B&W — that is worth
[reporting](reporting-a-bug.md), along with the OSD's reported resolution line.

### Nothing on the analog output at all

Check `MiSTer.ini` has `vga_scaler=0` and a sync mode matching your cable
(`composite_sync=1`, `ypbpr=1` or `vga_sog=1`). The analog raster engages from the ini, not
from the OSD. See [Analog and CRT output](../video/analog-crt.md#turning-it-on).

## Captions and subtitles

### No captions on my TV

Work through it in this order — the middle step is the one that resolves the ambiguity:

1. Does the disc have captions? Only about **1 disc in 6** does, and **no PAL disc** does.
2. Turn on **`CC Test Line`** (Debug page). A band of dashes that changes with dialogue
   means the core side is entirely working and the problem is TV-side. Nothing at all means
   the analog raster is not engaged, or this disc has no captions.
3. Your TV must be set to **`C1`** — not the disc's subtitle menu. `C2`, `T1` and `T2` will
   show nothing on any real disc.
4. Captions are **analog only**, and the connection matters: composite and S-video always
   carry them, component does on many sets, and consumer sets generally **do not** slice
   them from RGB.

See [Closed captions](../video/closed-captions.md).

### Subtitles do not appear

Subtitles are separate from captions and are drawn by the core, so they work on HDMI. Press
**B8** to cycle them; `SUB OFF` means they are disabled. Some discs author menu subpictures
with zero contrast, which is intentional on their part.

### Subtitle edges look jagged on a CRT

!!! info "Unreleased"
    Fixed in the development build: with `Analog Aspect` on Auto or Letterbox for a 16:9
    disc, subtitle edges used to stair-step (the subtitle layer was repositioned by a
    nearest-line map while the picture got a proper blend). Subtitles now draw unscaled
    at full resolution and may reach into the black bars — see
    [Analog and CRT output](../video/analog-crt.md#analog-aspect).

## Controls

### My keyboard does nothing

!!! info "Unreleased"
    Keyboard control arrived after v0.3.0; on that release only the number keys work, and
    only inside a menu.

Check the [key list](../playback/controls.md#keyboard-and-tv-remote) — the keys are fixed,
not derived from your gamepad mapping. Two things reasonably often explain it:

- **A key you mapped in MiSTer's *Define buttons* takes over**, and is doing whatever you
  mapped it to instead. That is how you rebind, but it can surprise you if you forgot.
- **The MiSTer OSD is open.** No key reaches the player while it is up.

### My TV remote does nothing over HDMI-CEC

CEC has to be switched on (`hdmi_cec=1` under `[MiSTer]` in `MiSTer.ini`), and **it does not
work on every board**. Before changing anything else, get the log — MiSTer discards its own
output unless you ask for it. Add `debug=2` under `[MiSTer]`, reboot, and read it:

```
grep -i cec /tmp/debug.txt
```

If that says `CEC: no clock detected` followed by `CEC: init failed.`, your board's CEC
hardware is not usable and **no `MiSTer.ini` setting will change it** — including
`hdmi_cec_clock`, which only chooses between clock rates once CEC is already working. Set
`hdmi_cec=0` and use an infrared receiver that presents itself as a USB keyboard instead
(a Flirc or a generic MCE dongle); that path does not involve CEC at all and gives you the
same control.

The full table of log lines and what each one means is on the
[controls page](../playback/controls.md#using-your-tvs-remote-over-hdmi-cec).

### My remote's Menu button opens the MiSTer menu instead of the disc menu

That is MiSTer claiming it, and it cannot be reassigned. Use the **blue** colour key for the
disc's menu, **red** for its title menu. The Menu button is still useful — it is a toggle, so
it also closes the OSD again.

## Navigation

### A menu option does the wrong thing, or `LINK FAIL`

`LINK FAIL nn` means a menu jump failed and the core recovered by re-entering the last
working menu. Occasional occurrences are harmless.

If a disc is consistently unnavigable, it is worth
[reporting](reporting-a-bug.md) — especially a film or TV disc, since interactive games are
known-incomplete. A menu problem can be reproduced from the disc's navigation tables
alone, so a [repro bundle](reporting-a-bug.md#menus-titles-and-audio-tracks-send-a-repro-bundle)
makes that report actionable without the disc.

**Workaround:** set **`Disc Menus` = `Off`** to skip navigation and auto-play the main
feature.

### A game disc repeats the same question

You pressed **Menu** to skip the intro, and that disc puts its randomisation setup in the
boot sequence. Let the intro play. A real player behaves the same way.

### The wrong title plays with Disc Menus off

The auto-selection picks the largest title set, which is not always right. `Title VTS Tens`
and `Title VTS Units` on the Debug page force a specific one. The core shows `TITLE VTS nn`
to say what it picked.

### The elapsed time is wrong after seeking

On most discs the time readout follows the disc's own timing tables and is accurate. On a
**seamless-branch disc** — a special edition that stores two cuts of the film woven together
in the same sectors — a seek can land in the wrong cut, and the clock then reports a
position that does not match what you are watching. Use chapter skip (B2/B3) instead of the
scrub or D-pad seek on those discs. Tracked as
[issue #49](https://github.com/owenb321/MiSTer_DVD/issues/49).

On a `.mpg`, `.VOB` or VCD/SVCD the clock is an **estimate** derived from how fast the file
plays, not a timecode read from the disc, so on a very variable-bitrate file it can drift by
a few seconds through the title. That is expected, not a fault.

## Support bundles

### The chord does nothing

Hold **Audio + Subtitle together** for a full two seconds. Both buttons must be down at
once, and the timer only starts when the second one goes down. It also needs
`MiSTer_DVDcss` — on the stock Main nothing is listening, and there is no message.

### `Nothing to bundle` with a disc playing

The message lists what the player could see. `mounted: (not captured)` means it did not
record the mount, which should not happen — that one is worth
[reporting](reporting-a-bug.md). `css active: 0` with `drive: (none)` while a physical
disc is playing points the same way.

### `Support bundle FAILED`

Read `/tmp/dvd_report_run.log`. Most often python3 is missing or too old — the collector
needs 3.7 or newer.

## After an update

### All my settings reset

Expected when a release changes the OSD option layout — see
[Settings](../playback/settings.md#settings-that-reset-after-an-update). It happens once per
layout change, by design, rather than silently misreading an old file.

### A feature in the documentation is not in my build

This manual documents the **development build**. The banner at the top of every page names
the latest release, and anything newer is marked *Unreleased*. Check the version line in the
OSD against it.
