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
pulldown was baked in when the disc was authored — Auto genuinely cannot see those, for the
reason in [What it cannot see](#what-it-cannot-see) below. If a disc looks like film and
Auto is not engaging after a few seconds, set `Film 24p Out = On`.

## How Auto detects film

A DVD does not label itself as film. What it carries instead are two flags the encoder
writes into every coded picture, and the detector reads the pattern they make.

`progressive_frame`
:   The encoder's claim that this picture is a whole progressive frame rather than two
    interlaced fields.

`repeat_first_field`
:   Show one of this picture's fields a second time. This is how 24 fps becomes 60 fields
    per second — alternate frames get an extra field, giving the 3:2 pattern.

**NTSC film** shows up as `progressive_frame` set *and* `repeat_first_field` **toggling**
from the previous picture. That toggle is the signature: it is what alternates the 2-field
and 3-field pictures. **PAL film** is simpler — 25 fps needs no pulldown, so progressive
alone is enough. **True interlaced video** is the opposite: `progressive_frame` clear,
sustained.

### It builds confidence rather than counting a run

Each picture nudges a confidence score — up for a confirming picture, down for a
contradicting one, with a hard drop for a definitely-not-film picture and a gentle one for
an ambiguous case. Film mode engages at the top of that range, roughly **40 clean film
frames, about 1.7 seconds** into a title, and disengages only after a long run of
contradictions.

The reason it is a score and not a consecutive run: a strict run gets reset to zero by
anything that interrupts the cadence, and reaching a title *through the disc's menus* does
exactly that — nav packs, cell and PGC boundaries, and brief still frames all inject
hiccups. A run-based detector locked fine on a disc played straight through and never
locked at all through a menu. A score decays through a hiccup and recovers.

It also cannot be fooled into engaging by accident. **30 fps progressive video never
toggles `repeat_first_field`**, so it produces no confirming pictures at all — its score
only ever falls. The bias is deliberately toward *not* film.

### Pictures that carry no evidence are ignored

`progressive_frame` is a claim the encoder wrote, not a measurement — and on a near-black
picture there is no field structure to describe, so encoders fall back to the MPEG-2 default
and mark it interlaced. Believing that is what used to make fading credits knock the
detector out of film lock: Apollo 13's opening changed output mode **nine times in the first
46 seconds**, re-locking the display each time.

So the detector now scores a picture only if it carries real evidence, using **how many
bytes the picture took to code** as a stand-in for how much is happening in it, judged
against what is typical *for that disc* — so it works the same on a heavily compressed
disc as on a lavish one. A picture that fails the test updates nothing at all, not even the
`repeat_first_field` history, so the 3:2 toggle test picks up across the gap instead of
seeing a false edge.

### What it cannot see

**Hard-telecined discs.** If the pulldown was baked in when the disc was authored, the
frames really are interlaced and there are no flags saying otherwise — there is no pattern
left to detect. Nothing can infer it from the stream, which is why the manual **On** exists.

## Related settings

- **`Frame Drop` must stay On.** The cadence-slip corrector, which keeps imperfect
  real-world telecine in step with the display, runs on the frame-drop governor's path and
  does nothing without it. See [Settings](../playback/settings.md#frame-drop).
- **`A/V Offset` defaults to +100 ms**, the correct null for NTSC film, which also measures
  correctly on PAL. There should be no need to change it.

## Known limitations

- **When Auto engages a couple of seconds into a title, audio can end up slightly offset**
  until the next seek re-syncs it. A chapter jump or a D-pad seek clears it.
- **If the analog CRT raster is active, the film raster is suppressed** — the re-interlacer
  needs the standard progressive raster to work from. See
  [Analog and CRT output](analog-crt.md).
