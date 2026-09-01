# Idle logo

When the core is loaded with nothing mounted, a **bouncing logo screensaver** plays behind
the file picker. You can replace it with your own artwork.

## Where the file goes

Drop a `boot.rom` at:

```
/media/fat/games/DVD/boot.rom
```

**Create the `games/DVD` folder if it does not exist** — this core does not make it for you.

The framework also accepts the file as `DVD.ROM` — that exact name, uppercase — next to the
core's `.rbf`, in `/media/fat/`, or in `/media/fat/bootrom/`.

!!! warning "Reload the core after placing it"
    The file is read once at core load. Placing it while the core is already running does
    nothing until you reload.

## Making one

Convert any PNG with the repository's tool:

```bash
tools/idle_logo.py --png mylogo.png --out boot.rom     # add --fit to downscale
tools/idle_logo.py --verify boot.rom                   # preview what will render
```

| Flag | Effect |
|---|---|
| `--fit` | Box-average downscale to fit the maximum size |
| `--colour RRGGBB` | Pin a fixed colour (otherwise the logo cycles a palette on each bounce) |
| `--speed SX,SY` | Pin the drift speed (also disables the random re-roll on each bounce) |
| `--invert` | Invert which pixels are lit |
| `--verify FILE` | Round-trip an existing file and print an ASCII preview |

**Always eyeball the `--verify` output.** What it prints is what will bounce.

## Size

Up to **256×64 pixels** shown 1:1, or up to a 512×128 on-screen footprint at 2× scale. The
converter picks sensibly based on the source size.

The image is one-bit — a pixel is either lit or not. Colour comes from the palette cycling
or from `--colour`, not from the source artwork.

!!! tip "How the converter decides what is 'on'"
    A pixel is lit if it **differs from the background** — using the alpha channel when the
    PNG has transparency, otherwise colour distance from the median corner colour. This
    matters for coloured logos on dark backgrounds: an earlier version thresholded on
    brightness and turned such images completely blank.

    `--fit` box-averages each cell and lights it at 30% coverage, so thin strokes survive
    the downscale. Results smaller than 8×4 are refused with a diagnostic rather than
    written, since a "valid" 1×1 file would bounce an invisible dot.

## If it does not show

- **Reload the core** — the file is only read at load time.
- **Run `--verify`** on the file. If the preview is blank, the conversion is the problem.
- **The core was launched with a file** — via file association or an MGL — in which case
  MiSTer skips `boot.rom` entirely and the built-in logo shows in that session.
- A corrupt or truncated file is ignored and the built-in logo is used instead, so a
  malformed file fails safe.

## Artwork

Use your own artwork. The oval-with-"DVD" mark is a trademark of the DVD Format/Logo
Licensing Corporation. Plain "DVD" letterforms are descriptive and fine.

<!-- SCREENSHOT idle-logo.png — the bouncing logo on the idle screen, custom artwork.
     Save to site/content/assets/img/idle-logo.png. Replace this comment with:
     <figure markdown="span">
       ![A custom logo on the idle screen](../assets/img/idle-logo.png){ width="640" }
       <figcaption>A custom boot.rom bouncing on the idle screen.</figcaption>
     </figure>
-->

## Related

`Reset` in the OSD returns to the idle screen, and a custom logo survives it. See
[Loading a movie](../getting-started/loading.md#the-idle-screen).
