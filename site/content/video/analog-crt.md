# Analog and CRT output

!!! info "Unreleased"
    The `Analog Out` setting described here for releases up to v0.3.0 has been replaced
    by the single [`Video Output`](interlaced.md) option. This page describes the
    current development build.

The core drives a real CRT natively: with
[`Video Output = Interlaced`](interlaced.md) (or Auto with the ini below), the analog
pins carry a native 15 kHz 480i/576i raster built from the disc's **authored fields**,
re-timed 1:1 — the same presentation a set-top player feeds a TV.

## Turning it on

There is nothing to set in the OSD. It engages from `MiSTer.ini` exactly like any other
core:

```ini
vga_scaler=0        ; (the default) native video on the analog pins
composite_sync=1    ; or ypbpr=1, or vga_sog=1 — match your cable
```

That is the whole setup — `Video Output = Auto` reads those bits and lands on Interlaced.
Set the mode explicitly only when the ini bits cannot describe your rig (a 15 kHz RGBHV
monitor: **Interlaced**) or when your analog display wants a progressive signal
(480p/576p component or VGA: **Progressive**). The mode table and the full description
live on the [Video Output](interlaced.md) page.

!!! warning "HDMI shows 480i while a CRT is active"
    Interlaced mode puts the whole core in field mode, so HDMI drops to 480i via the
    framework scaler for the session. The earlier dual-raster arrangement that kept HDMI
    progressive alongside the CRT was removed with its structurally unstable
    field-pairing (the "wobbly interlace" reports) — pick the output that matters and
    set `Video Output` for it.

Motion looks right on video-sourced discs by construction — every displayed refresh is
one genuine authored field — and film's 3:2 field cadence on a CRT is exactly what an
NTSC player output. Seeks and aspect changes land clean:
[field alignment is automatic](interlaced.md#field-alignment-is-automatic).

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
- While `Video Output = Interlaced`, [Film 24p](film-24p.md) output is unavailable — a
  23.976 Hz raster cannot carry fields. Film on the CRT plays with its normal 3:2 field
  cadence instead, which is what an NTSC player always did.
