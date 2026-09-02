# Closed captions (line 21)

NTSC DVDs can carry **EIA-608 closed captions** hidden inside the MPEG-2 video stream. These
are not the same thing as subtitles, and a disc can have either, both or neither.

The core extracts them and re-modulates them onto **line 21 of the analog output**, exactly
as a real DVD player does — so your **television's own caption decoder** renders them.

## Captions are not subtitles

| | Subtitles | Closed captions |
|---|---|---|
| Stored as | Subpicture streams — bitmap overlays | Data bytes inside the MPEG-2 video |
| Rendered by | The core, drawn onto the picture | Your television |
| Output | HDMI and analog | **Analog only** |
| Selected with | B8, or the disc's menu | Your TV's caption setting |
| Typical content | Dialogue, often multiple languages | Dialogue plus sound descriptions, `[DOOR SLAMS]` |

If you want text on HDMI, you want subtitles. There is no on-screen caption renderer in the
core.

## What you need

1. **An NTSC disc that actually has captions.** Only about **1 disc in 6** does. Every PAL
   disc scanned has none — line 21 is an NTSC construct, and PAL discs use subtitles instead.
2. **The analog output engaged** — `Video Output = Interlaced`, or Auto with the analog
   ini bits set; see [Analog and CRT output](analog-crt.md).
3. **A connection that carries line 21.** Composite and S-video always do. Component does
   on many sets. **Consumer sets generally do not slice captions from RGB**, so an RGB
   SCART path often will not work even though the waveform is present on all three channels.
4. **`Line-21 CC` on** — Debug page, default On.
5. **Your television set to `C1`.** Not the DVD's own subtitle menu — the TV's caption
   setting. `C1` is the correct choice: CC1 and CC2 both ride field 1, and field 2 is empty
   on every disc surveyed, so `C2`, `T1` and `T2` will show nothing on any real disc.

Every US television 13 inches and larger sold since 1993 has a caption decoder.

## Is it working? The test line

Captions normally travel in the vertical blanking interval, where they are invisible unless
something decodes them. That makes failure ambiguous: you cannot tell "my TV is not
decoding" from "no caption data is reaching the output".

**`CC Test Line`** (Debug page, default Off) resolves it. Turn it on and the same waveform
is painted on a *visible* line near the top of the picture:

- **A band of dashes that changes as dialogue changes** — everything on the core's side
  works. Extraction, pacing, waveform and the analog chain are all fine, and only the
  TV-side setup is left. Turn the test line back off and work on the television.
- **Nothing at all** — either the analog raster is not engaged, or this disc has no
  captions. Try a disc known to carry them.

This diagnostic is what separates a caption problem into "core" and "television" halves in
one glance, which is why it exists as a user-facing setting rather than a developer tool.

## Turning it off

`Line-21 CC` defaults to On because correct behaviour is simply on — an idle line 21 costs
nothing. The Off position is an escape hatch for **capture devices and upscalers that
display VBI lines**, where the caption waveform would otherwise show up as a flickering
dashed line at the top of the captured image.

## Limitations

- **Analog output only.** Nothing appears on HDMI.
- **NTSC only.**
- **CC1 only in practice.** Field 2 is empty on every disc surveyed, so there is no CC3/CC4
  second-language stream and no XDS program metadata to display.
- A disc can emit well-formed but **empty** caption blocks — one concert disc in the survey
  sends a caption block on every GOP in which every byte pair is null padding. A disc like
  that will correctly show nothing.
