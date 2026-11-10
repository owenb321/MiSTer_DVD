# Film (24p) content

Nearly all commercial film DVDs store 24 fps material and mark it for **3:2 pulldown**
rather than storing 60 fields per second. The core handles that two ways, and
**`Film 24p Out`** (Video page, default **Auto**) picks between them.

**Default path** — the core performs the 3:2 pulldown itself, following the flags in the
stream, and outputs at the display's native 59.94 Hz (50 Hz for PAL).

**Film 24p path** — the core instead outputs a true **23.976 Hz progressive** raster
(25.000 Hz for PAL) and lets the framework scaler do the pulldown. Because 23.976:59.94 is
exactly 2:5 and the clocks are locked, that conversion is exact.

This second path also cuts framebuffer re-reads from 60 per second to 24, which hands the
decoder a much larger uninterrupted memory window each frame.

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

- **`Frame Drop` must stay On.** Advancing past a frame is how the player recovers time
  it has lost. With it off, the picture runs progressively later and lip sync goes with it. See
  [Settings](../playback/settings.md#frame-drop).
- **`A/V Offset` defaults to 0 ms.** There should be no need to change it. (It was
  +100 ms in v0.4.0 and earlier, nulling an offset the current clock no longer has.)

## Known limitations

!!! info "Fixed in v0.5.0"
    The offset that used to appear when Auto engaged a couple of seconds into a title,
    and cleared on the next seek, is **gone**. It was not a film-detection problem: the
    player's clock counted displayed frames from a point in the *demux*, so everything
    buffered between there and the screen turned into an audio offset, and engaging the
    24p raster was simply where it became audible. The clock now runs on its own and both
    picture and sound are presented against it, so there is nothing for a seek to fix.
- **Film 24p needs `Video Output = Progressive`** (or Auto on an HDMI rig) — a 23.976 Hz
  raster cannot carry interlaced fields, so it is unavailable while
  [Interlaced mode](interlaced.md) is active. Film on a CRT plays with its normal 3:2
  field cadence instead.

## Standard Convert

**`Standard Convert`** (Video page, default **Off**) plays a disc made for the other TV
standard by changing its speed slightly, the way film has long been moved between the two.

| Setting | Disc | Speed |
|---|---|---|
| **To NTSC** | PAL (576 lines) | 4.1 % slower, 25 → 23.976 frames per second |
| **To PAL** | NTSC (480 lines) | 4.3 % faster, 23.976 → 25 frames per second |

A disc already in the chosen standard plays normally, so you can leave this set.

**How the picture gets to the other standard depends on your output:**

- **HDMI, or analog through the scaler (`vga_scaler=1`):** the core outputs 23.976 Hz (To NTSC)
  or 25 Hz (To PAL) and the MiSTer scaler does the rest. Set the HDMI `video_mode` in
  `MiSTer.ini` to the target rate, 59.94 Hz for To NTSC or 50 Hz for To PAL, or the cadence
  is uneven.
- **Direct analog (a CRT):** the core outputs a real signal of the other standard, interlaced or
  progressive as `Video Output` says, and scales the picture itself: To NTSC takes a PAL picture's
  576 lines to 480, To PAL takes an NTSC picture's 480 lines up to 576. `Analog Aspect` works as
  usual, and Letterbox scales a 16:9 picture between bars in one step (360 lines on NTSC, 432 on
  PAL). Your TV must accept the other standard: a 50 Hz PAL signal for To PAL, 60 Hz NTSC for
  To NTSC.

**What changes while it is converting:**

- **The speed applies to the whole disc,** including menus and logos, and it never changes
  partway through. Running times are about 4 % longer or shorter than the clock on screen, which
  keeps showing the disc's own time.
- **Pitch shifts with the speed,** about 0.7 of a semitone. Many PAL discs were sped up without
  correcting their pitch, so slowing one can restore its original sound. A disc that was
  pitch-corrected when it was mastered sounds slightly low, and nothing on the disc says which
  you have.
- **Passthrough is off.** Compressed audio cannot change speed, so the core decodes it to stereo
  PCM even with `Audio Out` set to Passthru. Your setting returns when conversion stops.
- **`Video Standard` is overridden** for that disc, and on the scaler path `Film 24p Out` too:
  the 23.976 or 25 Hz output stays on from start to finish.
- **Dialogue subtitles on a CRT are drawn at full sharpness** and moved to where the scaled
  picture puts them, so relative to the picture they look about 20 % larger with To NTSC and
  about 17 % smaller with To PAL. A subtitle near the bottom is kept on screen. Menu buttons and highlights are
  scaled with the picture so they stay on their artwork.

**Limits:**

- On the scaler path, true interlaced video is shown as woven frames, so motion combs.
  `Deinterlace = Blend` softens that; Bob has no effect there. Logos and video-shot extras are
  where you are most likely to see it.
- On a CRT, every picture plays with 3:2 pulldown like an NTSC film disc, including pictures the
  disc labels as interlaced (on PAL discs these are usually film too). True interlaced video,
  such as sport, concerts and some logos, judders at 480i: the extra field 3:2 adds repeats an
  earlier moment, so motion briefly steps backward. 480p is unaffected.
- On a CRT with **To PAL**, every picture gets exactly two fields, the way PAL film plays. NTSC film
  becomes clean 25 fps film.
- With **To PAL**, true 30i video (often animated menus and extras) loses one picture in five, because
  31 pictures a second cannot fit a 25-picture output. Motion there looks less smooth.
- Hard-telecined NTSC discs keep their baked-in pulldown, so they do not become clean 25 fps film.
- VCD and other SIF-height discs, audio CDs and WAV files always play at their true speed.
