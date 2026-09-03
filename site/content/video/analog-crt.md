# Analog and CRT output

!!! info "Unreleased"
    The `Analog Out` setting described here for releases up to v0.3.0 has been replaced
    by the single [`Video Output`](interlaced.md) option. This page describes the
    current development build.

The core drives a real CRT natively: with
[`Video Output = Interlaced`](interlaced.md) (or Auto with the ini below), the analog
pins carry a native 15 kHz 480i/576i raster of the disc's **authored fields** — the
same presentation a set-top player feeds a TV.

!!! info "Unreleased"
    The analog raster is now the core's main interlaced raster driven straight to the
    pins, like every other MiSTer 480i core — the separate re-timed second raster of
    v0.4.0 and the PR #37 prerelease is gone. Together with a set of timing fixes this
    addresses the RGB SCART / YPbPr / RetroTINK reports of a picture that shakes or
    tears about once a second, sawtooth edges, and MiSTer reporting `1441x478i` /
    `59.8 <-> 60.1 Hz`. MiSTer now reports **`720x480i @ 59.94 Hz`** (also on the idle
    logo). The composite and S-video paths are unchanged in substance.

## Turning it on

There is nothing to set in the OSD. It engages from `MiSTer.ini` exactly like any other
core:

```ini
vga_scaler=0        ; (the default) native video on the analog pins
composite_sync=1    ; or ypbpr=1, or vga_sog=1 — match your cable
```

**Composite or S-video** additionally needs the framework's Y/C encoder switched on —
without it the pins carry raw RGB and the picture arrives **black & white**:

```ini
vga_mode=svideo     ; or vga_mode=cvbs for composite
```

The chroma standard (PAL/NTSC subcarrier) follows the disc automatically — the framework
picks it from the video rate.

That is the whole setup — `Video Output = Auto` reads those bits and lands on Interlaced.
Set the mode explicitly only when the ini bits cannot describe your rig (a 15 kHz RGBHV
monitor: **Interlaced**) or when your analog display wants a progressive signal
(480p/576p component or VGA: **Progressive**). The mode table and the full description
live on the [Video Output](interlaced.md) page.

In Progressive mode the analog pins carry the plain progressive raster through the stock
path — a **31 kHz** signal a 15 kHz CRT cannot sync — and the analog-only extras
(line-21 captions, sub-720 fill, Analog Aspect) are off.

!!! info "Unreleased"
    On a progressive-analog rig (`vga_scaler=0` plus a sync mode in the ini)
    [Film 24p](film-24p.md) is now suppressed automatically, so a film disc no longer
    switches the pins to a 23.976/25 Hz raster the display drops when the feature
    starts. HDMI-only setups (`vga_scaler=1`, or no analog sync mode set) keep Film 24p
    exactly as before. On v0.4.0 and earlier set `Film 24p Out = Off` on such a rig.

!!! warning "HDMI shows 480i while a CRT is active"
    Interlaced mode puts the whole core in field mode, so HDMI drops to 480i via the
    framework scaler for the session. The earlier arrangement that kept HDMI
    progressive alongside the CRT was removed with its structurally unstable
    field-pairing (the "wobbly interlace" reports) — pick the output that matters and
    set `Video Output` for it.

Motion looks right on video-sourced discs by construction — every displayed refresh is
one genuine authored field — and film's 3:2 field cadence on a CRT is exactly what an
NTSC player output. Seeks and aspect changes land clean:
[field alignment is automatic](interlaced.md#field-alignment-is-automatic).

**Composite sync (RGB SCART, sync-on-green), S-video, composite and YPbPr** all carry
true 2:1 interlace: the core builds the analog sync with the half-line offset that
interleaves the two fields, and serrates it at twice line rate the way broadcast signals
do. A display wired for **separate H and V sync** (RGBHV) instead sees the two fields
line-paired. If a set or scaler shows a per-field wobble or reports the line count
toggling, that is worth [reporting](../reference/reporting-a-bug.md) with the connection
type — see
[troubleshooting](../reference/troubleshooting.md#the-picture-shakes-or-tears-about-once-a-second-on-a-crt-or-scaler).

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

!!! info "Unreleased"
    **Subtitles are no longer scaled by Letterbox or Crop.** Dialogue subtitles now draw
    at their authored position and full resolution, with clean edges — like a set-top
    player, they may reach into the black bars rather than being squeezed with the
    picture. (Previously they were repositioned by a nearest-line map, which gave
    diagonal subtitle edges a sawtooth look.) Menu button art and highlights still track
    the scaled picture so highlights land on their buttons, and sub-720 content
    (MPEG-1/SIF, SVCD) keeps its scaled subtitles — those are authored at the smaller
    picture size.

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
