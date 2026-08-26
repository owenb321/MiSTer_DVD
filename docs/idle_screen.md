# Idle Screen — Bouncing Logo (+ startup OSD, config versioning)

**Status: ✅ MERGED (PR #9, 2026-08-26); ⏳ HW-confirm pending.** The three post-release feedback items land together:
config versioning (`v,1;`), the startup OSD popup (`BUTTONS[0]`), and this
idle screen.

## What it does

While no disc image has been mounted, the core renders a bouncing logo
(the DVD-screensaver trope) over the black idle raster: a 1-bpp mask drawn at
2× (up to 256×64 on screen), clamp-bouncing inside the active area, cycling
an 8-colour palette on every wall hit, flashing white for ~0.75 s on a true
corner hit. Users can replace the artwork by dropping a `boot.rom` file in
`/media/fat/games/DVD/`.

## Module map

| Piece | Where |
|---|---|
| RTL | `dvd/idle_logo.sv` (~210 ALM / 1 M10K / 0 DSP) |
| Default art + converter | `tools/idle_logo.py` → `dvd/idle_logo.mem`, `tools/idle_logo_preview.png` |
| emu glue | `dvd/emu.sv`: `idle_logo_inst`, `logo_vis`, widened overlay priority mux |
| Tests | `bench/dvd/idle_logo_tb.sv` (16 scenarios), `bench/dvd/idle_frame_tb.sv` (pixel-exact frames), fixture `bench/dvd/idle_logo_user.hex` |

## Design decisions

### ROM: one M10K, two banks — the never-garbage guarantee is structural

512 × 16-bit (= exactly one M10K in ×16 mode). Bank 0 (words 0-255) is the
built-in default, 128×32 px; bank 1 (words 256-511) is the user bitmap.
Word address = `{bank, row[4:0], col[6:4]}`, bit = `word[15 - col[3:0]]` —
pure concatenation + a 16:1 mux, zero arithmetic in the display hotspot
(the ×10/×20 M10K modes would use all 10,240 bits but force a ÷10 into the
pixel path — rejected).

The file length is unknowable until a download ends (hps_io carries no size
up front), so a truncated good-header file *will* leave bank 1 part-written.
Robustness is therefore structural, not procedural: the ioctl write port is
hard-gated to `{1'b1, addr}` — bank 0 is physically unreachable — and the
commit rule demands an exact length match (`16 + 16·height`), so any failed
download just leaves `logo_valid=0` and bank 0 renders bit-identically to a
fresh boot. A bad-magic file produces **zero** writes (header validity
resolves at byte 6, ten bytes before the first pixel), so a stray
`boot.rom` can never brick an already-good user logo either.

`tools/idle_logo.py` initialises bank 1 as a copy of bank 0, so even a
stuck bank-select bit shows the default.

### 1 bpp, not 2 bpp

The HUD font needs outline/backing classes because it draws over arbitrary
video. The idle logo draws over guaranteed black (`!media_seen` ⇒ nothing
decoded), so the second bit would only halve the mask to no benefit. If a
future pause-screensaver ever draws it over live video, synthesise a halo
from a second ROM read at `x-1` — do not go to 2 bpp.

### ⚠ Traps (also in the RTL header — keep them in sync)

1. **`$readmemh` contents reload at FPGA configuration, not at core reset.**
   Every register describing ROM contents (`logo_valid`, `u_w/u_h`, colour,
   speed) has **no reset term** — power-up init only. An OSD Reset must not
   desync geometry from bitmap.
2. **`(* ramstyle = "M10K, no_rw_check" *)` is load-bearing** — without it
   Quartus 17 can infer MLAB for a 512-deep memory and silently drop the
   init (`dvd/spu_decode.sv` precedent).
3. **`ioctl_addr` races the falling edge of `ioctl_download`** (hps_io
   updates both in one cycle) — the module tracks its own `last_addr`.
4. **`av_refresh_tick` is per-FIELD when interlaced** — the `fld_tog`
   divider halves it under `il_eff` or the two fields of a frame sample the
   logo `spy/16` px apart (edge combing on CRTs). It also runs at 23.976/25 Hz
   in the Film output modes; idle ⇒ no stream ⇒ film detect off, so that
   cannot fire in practice (documented, not compensated).
5. **`LOGO_QX_ADJ` needs no HW calibration** (unlike `SP_QX_ADJ`): the logo
   is free-floating; ±2 px is unobservable. Don't burn a hardware round on it.
6. **A CONF_STR entry would re-roll the fitter seed** — the logo ships with
   *no* OSD option; the `boot.rom` convention costs zero CONF_STR bytes.

### Verilog scheduling trap found during the reclaim pass (dvd_vm, relevant here)

A continuous assignment (and, in Icarus, even an `always @*`) that reads a
memory **word through a called function** is sensitive to the function's
arguments only — not the array. Any live re-read of a just-written array
word must be a **direct** `arr[idx]` expression. (`dvd/dvd_vm.sv`'s shared
operand reads document the full story.)

## User bitmap: `boot.rom`

Delivery is the framework's zero-CONF_STR **boot.rom convention**: Main
sends `/media/fat/games/DVD/boot.rom` (fallbacks `<rbf_dir>/DVD.ROM`,
`DVD.ROM`, `bootrom/DVD.ROM`) over `ioctl_download` with `ioctl_index==0`
at every core load. Caveat: Main skips boot.rom when the core is launched
with a direct file path (file association / MGL with a file element) — the
default logo shows in that session's brief idle moments instead.

Format (max 528 bytes) — `tools/idle_logo.py` is the reference
implementation:

| Off | Size | Field |
|---|---|---|
| 0 | 4 | magic `"MDL1"` |
| 4 | 1 | width 1..128 |
| 5 | 1 | height 1..32 |
| 6 | 1 | format 0x00 (1 bpp packed, MSB-first, fixed 16-byte stride) |
| 7 | 1 | flags: bit0 = fixed colour (else palette cycling) |
| 8 | 3 | R, G, B |
| 11 | 1 | speed: [3:0] x, [7:4] y, 1/16 px per frame; 0 = defaults |
| 12 | 4 | reserved (0) |
| 16 | 16·h | pixel rows, row 0 = top |

Convert a PNG: `tools/idle_logo.py --png art.png --out boot.rom`
(`--fit` nearest-neighbour downscale, `--invert`, `--colour RRGGBB`,
`--speed SX,SY`; `--verify boot.rom` round-trips + ASCII-previews).
A user-pinned speed disables the bounce re-roll.

Default artwork policy: **original only** — the oval-with-"DVD" mark is the
DVD Format/Logo Licensing Corp.'s trademark. Plain "DVD" letterforms are
descriptive and fine.

## Startup OSD popup (same branch)

`BUTTONS` was declared `input` since the fork's inception — the canonical
MiSTer direction is **output** (core→HPS virtual buttons; b[0] = OSD), so
the core could never pop the OSD at load. Now: wait-then-pulse — arm on the
falling edge of `status[0]` (end of `user_io_init`, i.e. after every
init-time auto-load), wait ~0.9 s watching for a mount, then a 100 ms pulse
(menu.cpp synthesises `KEY_F12|UPSTROKE` on the **release** edge — which is
why the console-core "hold for the window" idiom is wrong here: a mid-window
MGL mount would deassert = release = pop the OSD anyway; here it cancels).
One-shot per FPGA configuration; well under the 3 s Bluetooth-pairing hold.
Keyed on `img_mounted`, NOT `ioctl_download` — boot.rom is the *logo*, and
keying on ioctl would suppress the popup for exactly the users who
installed one.

## Config versioning (same branch)

`"v,1;"` in CONF_STR → settings persist to `config/DVD_v1.CFG`. On the
first boot after this change every option falls back to its index-0 label
(the old `DVD.CFG` is orphaned on disk, not migrated). Bump to `v,2;` on
any future incompatible O[..] relayout; range 1-99. This retires the
"delete DVD.cfg after updating" release-note workaround.

## HW gate

1. Bare core load → OSD opens by itself after ~1 s; logo bounces behind it;
   dismissing the OSD leaves the logo running; colours cycle on bounces.
2. Launch WITH a file (association/MGL) → no popup, no logo flash, playback
   normal.
3. Mount from the browser → logo gone at mount, never reappears mid-title;
   HUD/seek-bar/subtitles/menu highlights unregressed.
4. First boot after upgrade → defaults active, `DVD_v1.CFG` written on OSD
   exit, old `DVD.CFG` still on the card.
5. `boot.rom` present → custom logo, right size/colour; corrupt/truncated/
   absent → built-in logo, never garbage. `--verify` output matches screen.
6. Analog CRT 480i + PAL 576i: no inter-field combing on the logo edges;
   logo stays inside the active area under Analog Letterbox/Crop.
7. R0 Reset mid-session: no second OSD popup; user logo survives.
