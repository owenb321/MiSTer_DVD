# Interlaced output (HDMI)

`Interlaced Out` controls whether the core sends **native 480i/576i fields** to HDMI
instead of a progressive picture. Default **Off**.

This is separate from [Analog and CRT output](analog-crt.md), which has its own raster and
its own setting.

| Mode | Behaviour |
|---|---|
| **Off** *(default)* | Weave both fields into a progressive frame. |
| **Auto** | Engage native fields when the content is detected as true-interlaced video. |
| **On** | Always send native fields. |

`480i Deint` (Bob / Weave) then picks how the framework scaler deinterlaces what it
receives.

## What it is for

DVD content shot on video — television, concerts, documentaries — is genuinely interlaced
at 59.94 (or 50) fields per second. Weaving those fields into 29.97 progressive frames
throws away half the motion information, which reads as juddery movement.

Sending native fields preserves it. On film content it makes no real difference, because
film has only 24 distinct images per second regardless.

## Off by default, and Auto is opt-in

**`On` plays correctly with A/V sync** — the mode is fixed at load time, so nothing changes
mid-title.

**`Auto` still has a known problem.** The detector's verdict lands about 1.7 seconds into
playback, so the switch is inherently mid-title, and even with the full seek-style re-sync
that follows it, **audio ends up slightly out of sync**. It is kept as an opt-in to revisit
rather than being the default.

So: if you know a disc is video-sourced and you want native fields on HDMI, set **On**
before loading it. Leave the default alone otherwise.

!!! tip "On a CRT, use Native Fields instead"
    If your target is an analog CRT rather than HDMI,
    [`Analog Out = Native Fields`](analog-crt.md#native-fields) is the better route — it is
    hardware-confirmed, has no mid-title switch, and gives the CRT the disc's authored
    fields directly.

## Interactions

- While the analog raster is engaged in `Auto` or `Interlaced` mode, `Interlaced Out` is
  **forced off** — the re-interlacer needs the progressive main raster to derive from.
- `Analog Out = Native Fields` does the opposite: it forces field mode on for the whole
  session, which is what makes HDMI drop to 480i in that mode.
- Overlays — subtitles, menu highlights, the transport HUD and seek bar — render correctly
  in interlaced mode. They previously appeared squashed into the left half of the screen;
  that is fixed.
