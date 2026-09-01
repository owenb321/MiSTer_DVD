# Analog and CRT output

The core drives a real CRT natively. It emits **two rasters at the same time**: the normal
progressive one for HDMI, and a native 15 kHz 480i/576i raster on the analog pins. The two
are independent, so **HDMI quality is never reduced by having the CRT connected**.

## Turning it on

There is nothing to set in the OSD. It engages from `MiSTer.ini` exactly like any other
core:

```ini
vga_scaler=0        ; (the default) native video on the analog pins
composite_sync=1    ; or ypbpr=1, or vga_sog=1 — match your cable
```

That is the whole setup. `Analog Out` in the OSD is an override for cases where the ini
bits alone do not describe your rig.

## Analog Out modes

`Auto` follows `MiSTer.ini` and is right for most setups.

| Your setup | Mode |
|---|---|
| CRT only, video-sourced content (TV, concerts, live recordings) | **Native Fields** — smoothest motion |
| CRT only, film | **Native Fields** or **Auto** — little difference |
| CRT **and** HDMI at the same time | **Auto** or **Interlaced** |
| A 15 kHz RGBHV rig the ini bits cannot identify | **Interlaced** |
| A display that wants 480p/576p on the analog pins | **Progressive** |

An explicit choice always overrides `MiSTer.ini` and persists across reloads.

### Native Fields

The other modes build the CRT's fields by taking a woven progressive frame apart again.
**Native Fields** instead puts the decoder itself into field mode, so the CRT receives the
disc's **authored** fields, re-timed 1:1.

On true-interlaced content — television, concert footage, anything shot on video rather
than film — this is visibly smoother. It is the correct answer for a CRT-only setup.

!!! warning "It puts the whole core in field mode"
    HDMI drops to 480i for the session and is deinterlaced by the framework scaler, which
    is not cadence-aware — so **film content regresses on HDMI** while this mode is active.
    That is why it is opt-in rather than automatic.

!!! danger "Set it before loading a disc"
    Changing `Analog Out` mid-title fires a full seek-equivalent flush. Pick the mode
    first, then load.

Why this exists rather than a cheaper fix: on the derived-field path, whether you see a
coherent picture depends on which field of the pair lands on which raster field, and the
frame-rate governor re-randomises that several times a second under normal load. There is
no phase adjustment that holds. Feeding the decoder's own fields removes the pairing
question entirely — every displayed refresh is one genuine field of exactly one picture.

Film content barely notices the difference, because each field still lies wholly within one
picture either way. **True 29.97i video is where it shows.**

## Analog Aspect

An anamorphic 16:9 DVD is stored as 720×480 with the picture horizontally squeezed into a
4:3 raster. A widescreen TV unsqueezes it; a 4:3 CRT cannot, so everything looks tall and
thin. `Analog Aspect` picks the correction.

| Mode | What it does | Result |
|---|---|---|
| **Auto** | Letterbox for 16:9 content, Fit for 4:3 | Correct for most people |
| **Fit** | No correction at all | 4:3 content correct; 16:9 shows tall and thin |
| **Letterbox** | Scales the picture down vertically by ¾, centred, with black bars | Correct geometry, full width, bars top and bottom |
| **Crop** | Shows the centre ¾ of the width, stretched back to full width | Correct geometry, **full vertical resolution**, sides cut off, no bars |

Both corrections are the same exact ×¾ factor — a 16:9 image inside a 4:3 frame has scale
factor (4∕3)∕(16∕9) = ¾. Letterbox applies it vertically, costing resolution but keeping
the whole frame. Crop applies it horizontally, keeping every one of the 480 source lines
but losing ⅛ of the picture from each side. This is the pan-and-scan trade-off, and which
you prefer is a matter of taste.

Letterbox uses a true two-tap vertical blend rather than dropping lines, so the scaled
image is smooth rather than aliased.

**Auto never selects Crop** — it chooses between Letterbox and Fit. Crop is a deliberate
manual choice.

## Sub-720 content on a CRT

MPEG-1 SIF (352×240 / 352×288), SVCD (480 wide) and the sub-D1 DVD sizes (704, 544) are
narrower than the 720-pixel raster. On the analog output the core fills the screen in
fabric — SIF gets a 2× line repeat and a 352→720 horizontal stretch; the other sub-720
widths get the horizontal fill. HDMI is unaffected and keeps the framework scaler's cleaner
upscale.

!!! note "Why there is no true 240p output"
    A 240p raster would be the natural home for SIF content, but the core's A/V sync
    requires the raster to run at exactly the content rate against a fixed audio clock, and
    no exact-rate 240p modeline exists at the 27 MHz dot clock. Line-doubled 480i carries
    the same content to a CRT — which is what actual DVD players do with sub-D1 material.

## Known limitations

- **PAL on an analog CRT is implemented but unconfirmed.** The 576i timings are derived by
  analogy with the hardware-proven NTSC ones, and no PAL CRT was available to test them.
  PAL over HDMI is confirmed working.
- While the analog raster is active, [Film 24p](film-24p.md) output is suppressed — the
  re-interlacer needs the standard progressive raster to work from.
- In the derive modes (`Auto`, `Interlaced`), [Interlaced Out](interlaced.md) is forced
  off for the same reason.
