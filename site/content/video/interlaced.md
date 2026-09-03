# Video Output

!!! info "Unreleased"
    `Video Output` replaces the previous `Interlaced Out` and `Analog Out` settings.
    Releases up to and including v0.3.0 still have the old pair — this page describes
    the current development build.

`Video Output` is the core's one output-mode choice:

| Mode | Behaviour |
|---|---|
| **Auto** *(default)* | Follows `MiSTer.ini`: an analog TV configured there means **Interlaced**, otherwise **Progressive**. |
| **Interlaced** | The decoder emits the disc's **authored fields** as a native 15 kHz 480i/576i raster. The analog pins carry it directly for a CRT; HDMI shows it as 480i through the framework scaler. MiSTer reports `720x480i @ 59.94 Hz`. |
| **Progressive** | The progressive picture, as before. HDMI at full quality, [Film 24p](film-24p.md) available, and the analog pins carry the progressive raster for displays that take 480p/576p. |

An explicit choice always overrides `MiSTer.ini` and persists across reloads.

## Which one you want

| Your setup | Mode |
|---|---|
| HDMI | **Auto** (lands on Progressive) |
| A 15 kHz CRT — composite, s-video, YPbPr, RGB SCART | **Auto** with the ini set up as below (lands on Interlaced) |
| A 15 kHz RGBHV rig the ini bits cannot identify | **Interlaced**, explicitly |
| A display that wants 480p/576p on the analog pins | **Progressive**, explicitly |
| HDMI, but a disc of true-interlaced video (TV, concerts) and you want native fields | **Interlaced**, explicitly |

For a CRT there is nothing to set in the OSD — it engages from `MiSTer.ini` exactly like
any other core:

```ini
vga_scaler=0        ; (the default) native video on the analog pins
composite_sync=1    ; or ypbpr=1, or vga_sog=1 — match your cable
```

## What Interlaced mode does

DVD content shot on video — television, concerts, documentaries — is genuinely interlaced
at 59.94 (or 50) fields per second. Weaving those fields into progressive frames throws
away half the motion information, which reads as juddery movement. In Interlaced mode
every displayed refresh is one genuine authored field of exactly one picture, which is
what a CRT is built to show.

While it is active:

- The **CRT** gets the fields re-timed 1:1 on a native 15 kHz raster — the smoothest
  presentation for video-sourced discs, and the same thing a set-top player outputs.
- **HDMI** drops to 480i for the session, deinterlaced by the framework scaler.
  `480i Deint` picks Bob (smooth motion, half vertical resolution) or Weave (full
  resolution, combing on motion). The scaler is not cadence-aware, so **film content
  looks better in Progressive mode on HDMI** — which is why Interlaced is not forced
  whenever a CRT is merely present, only chosen.
- [Film 24p](film-24p.md) output is unavailable (a 23.976 Hz raster cannot carry fields).

Film on a **CRT** in Interlaced mode is fine — 3:2 fields at 60 Hz is exactly what an NTSC
player fed a TV — so a CRT-only setup can simply stay in Interlaced (or Auto) for
everything.

!!! note "Switching mid-title works, with a brief interruption"
    Changing `Video Output` during playback interrupts playback briefly — a short cut to
    black while the raster and A/V sync re-anchor, like a chapter jump — and then plays on
    cleanly. Setting the mode before loading just avoids the interruption; it is not
    required. `Auto` reads the ini bits at boot and while nothing is mounted; it does not
    change the output mode under a playing disc.

    On v0.4.0 and earlier this could occasionally **freeze the picture** on a malformed
    frame instead, on any disc; skipping a chapter recovered it. The same thing happens on
    older releases when changing `Analog Out`.

!!! info "Unreleased"
    The current development build fixes that freeze. A mid-title switch now steps playback
    back to the start of the chunk it was reading — up to about a second — and resumes
    from there, so the picture always restarts from a clean point. On a VCD or SVCD the
    step back can be a little longer.

    The screen also **goes black for the changeover** instead of showing the picture
    breaking up while the display re-locks — about a second, and the OSD stays visible
    over it. Sound continues throughout. If the black lasts noticeably longer than that,
    or a mid-title switch still freezes,
    [please report it](../reference/reporting-a-bug.md).

## Field alignment

On some televisions the picture could come back from a chapter skip, fast-forward or
aspect change looking **aliased, like a screen door**. It is a field-parity coin flip in
the display pipeline: the two interlaced fields land the wrong way round after an
interruption. On older releases the workaround is to **toggle `Video Output` away and
back**, sometimes taking a few attempts. Not every set shows it — a television with a
tolerant sync separator may never see it at all.

!!! info "Unreleased"
    The current development build corrects this automatically — the toggle is no longer
    needed. (v0.4.0's first attempt at the corrector had to be switched off again: it made
    both interlaced fields carry the same picture lines, which showed as a combed still
    image and a picture that jumped a line at field rate on every set, HDMI included. The
    repaired version only steps in for a misalignment that persists, so it cannot do
    that.) The same coin flip decided whether **HDMI with `480i Deint` = `Weave`** came up
    combed on a still; that is fixed too, by a separate correction to the field flag the
    core hands the framework scaler. Both are confirmed on hardware. Televisions differ,
    so if a skip still leaves the picture aliased, or a still combs under Weave,
    [please report it](../reference/reporting-a-bug.md).

## What changed from the old settings

- The old `Analog Out = Native Fields` **is** the new Interlaced mode, renamed — it was
  the mode worth keeping.
- The old derive modes (`Analog Out = Auto/Interlaced`), which rebuilt CRT fields from a
  woven progressive frame, are gone: field pairing on that path was structurally unstable
  (the "wobbly interlace" field reports) and Interlaced mode is immune by construction.
  This also means the old "CRT 480i and full-quality progressive HDMI at the same time"
  combination no longer exists — with a CRT active, HDMI shows 480i. Pick the output that
  matters and set the mode for it.
- The old `Interlaced Out` (HDMI fields) is subsumed: `Video Output = Interlaced` gives
  HDMI the same 480i-via-scaler picture. Its `Auto` content detector is retired — it
  switched mid-title, which never worked cleanly with audio.
