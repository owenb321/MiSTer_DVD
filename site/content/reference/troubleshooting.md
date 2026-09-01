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

**Expected, and there is currently no fix.** Where the disc authors silence there is no
bitstream to send, and a receiver holds its lock only on real data — both possible fillers
were tested on a real receiver and neither works. It re-acquires in under a second when
audio returns, and many set-top players behave the same way. See
[Authored silence](../audio/passthrough.md#authored-silence-drops-the-receiver-out-of-dolbydts).

If instead the dropouts happen at a **title start** or on a **track change**, that is a
different, already-fixed bug — update to a newer build.

## Picture problems

### 16:9 content looks tall and thin on a CRT

Set **`Analog Aspect`** to `Letterbox` (or `Crop`). Anamorphic content is stored squeezed
into a 4:3 raster and needs unsqueezing. See
[Analog Aspect](../video/analog-crt.md#analog-aspect).

### Motion looks juddery on a CRT

If the content is video-sourced — television, concert footage — set
**`Analog Out` = `Native Fields`** *before loading the disc*. See
[Native Fields](../video/analog-crt.md#native-fields).

### A film disc keeps changing resolution, or judders

Set **`Film 24p Out` = `On`**. The disc is probably **hard-telecined**, meaning the pulldown
was baked in at authoring time and carries no flags for Auto to detect. See
[Film (24p)](../video/film-24p.md).

Also confirm **`Frame Drop` is On** — the cadence corrector runs on that path.

### The idle logo bounces in a small box on a widescreen display

Fixed in current builds. Update the core.

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

## Navigation

### A menu option does the wrong thing, or `LINK FAIL`

`LINK FAIL nn` means a menu jump failed and the core recovered by re-entering the last
working menu. Occasional occurrences are harmless.

If a disc is consistently unnavigable, it is worth
[reporting](compatibility.md#reporting-a-disc-that-does-not-work) — especially a film or TV
disc, since interactive games are known-incomplete.

**Workaround:** set **`Disc Menus` = `Off`** to skip navigation and auto-play the main
feature.

### A game disc repeats the same question

You pressed **Menu** to skip the intro, and that disc puts its randomisation setup in the
boot sequence. Let the intro play. A real player behaves the same way.

### The wrong title plays with Disc Menus off

The auto-selection picks the largest title set, which is not always right. `Title VTS Tens`
and `Title VTS Units` on the Debug page force a specific one. The core shows `TITLE VTS nn`
to say what it picked.

## After an update

### All my settings reset

Expected when a release changes the OSD option layout — see
[Settings](../playback/settings.md#settings-that-reset-after-an-update). It happens once per
layout change, by design, rather than silently misreading an old file.

### A feature in the documentation is not in my build

This manual documents the **development build**. The banner at the top of every page names
the latest release, and anything newer is marked *Unreleased*. Check the version line in the
OSD against it.
