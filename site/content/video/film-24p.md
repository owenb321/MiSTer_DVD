# Film (24p) content

Nearly all commercial film DVDs store 24 fps material and mark it for **3:2 pulldown**
rather than storing 60 fields per second. The core handles that two ways, and
**`Film 24p Out`** (Debug page, default **Auto**) picks between them.

**Default path** — the core performs the 3:2 pulldown itself, following the flags in the
stream, and outputs at the display's native 59.94 Hz (50 Hz for PAL).

**Film 24p path** — the core instead outputs a true **23.976 Hz progressive** raster
(25.000 Hz for PAL) and lets the framework scaler do the pulldown. Because 23.976:59.94 is
exactly 2:5 and the clocks are locked, that conversion is exact.

This second path also cuts framebuffer re-reads from 60 per second to 24, which hands the
decoder a much larger uninterrupted memory window each frame — so it helps throughput on
demanding discs as well as cadence.

## When to change it

Leave it on **Auto**. The one case that needs `On` is a **hard-telecined** disc, where the
pulldown was baked in at authoring time rather than flagged. Such a disc carries no
pulldown flags, so Auto genuinely cannot see that it is film. If a disc looks like film and
Auto is not engaging, set `Film 24p Out = On`.

## Fades to black no longer break detection

Worth knowing, because it used to be a visible fault and reports of it may still be around.

MPEG-2's `progressive_frame` is a flag the *encoder* writes, not a measurement. On a
near-black picture there is no field structure to describe, so encoders mark those frames
interlaced by default. The detector used to believe them — Apollo 13's fading opening
credits made it change output mode **nine times in the first 46 seconds**, each one
re-locking the display.

The detector now ignores pictures that carry no evidence, judged against the disc's own
bitrate so it works equally on a heavily compressed disc, while still following a genuine
film-to-video change within about a second. Fifteen of the 123 discs surveyed flapped at
the title head before this change and no longer do.

## Related settings

- **`Frame Drop` must stay On.** The cadence-slip corrector, which keeps imperfect
  real-world telecine in step with the display, runs on the frame-drop governor's path and
  does nothing without it. See [Settings](../playback/settings.md#frame-drop).
- **`A/V Offset` defaults to +100 ms**, the correct null for NTSC film, which also measures
  correctly on PAL. There should be no need to change it.

## Known limitations

- **When Auto engages a couple of seconds into a title, audio can end up slightly offset**
  until the next seek re-syncs it. A chapter jump or a D-pad seek clears it. Detecting film
  before the first frame is shown is the proper fix and is planned.
- **If the analog CRT raster is active, the film raster is suppressed** — the re-interlacer
  needs the standard progressive raster to work from. See
  [Analog and CRT output](analog-crt.md).
