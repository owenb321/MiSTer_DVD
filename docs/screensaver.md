# Stop and the screensaver — what the blank hides

**Status:** ✅ the layer policy below is the shipped behaviour (2026-09-15, branch
`fix/screensaver-overlay-gate`); sim-proven RED/GREEN, 13 mutations each caught by exactly
its own assertion, and ✅ **HW-CONFIRMED 2026-09-15 with the defect REPRODUCED FIRST on
the pre-fix core** (build `DVD_saveroverlay_20260916_0158.rbf`, SEED 7 first roll,
clk_dec 95.01/91.44 vs the 86.0 gate, 91 % ALM).

| | |
|---|---|
| Modules | `dvd/stop_ctl.sv` (the verdict), `dvd/emu.sv` (the composition), `dvd/subpic_blend.sv` (the compositor) |
| OSD | `O[48:47] Screensaver, 5min / Off / 2min / 10min`; `B14 Stop` |
| Gates | `bench/dvd/run_screensaver.sh --red`, `tools/check_saver_overlay_wiring.py` |
| Manual | `site/content/playback/settings.md`, `site/content/playback/controls.md` |

`dvd/stop_ctl.sv`'s header is the authority on the timer, the two Stop stages and the
⛔ **do not clear `media_seen`** trap (clearing it flips `VIDEO_ARX/ARY` and makes Main
re-init the scaler mid-film — a resolution popup in the middle of a picture). This file
owns the other half of the question, which had never been written down: given that the
screen is blanked, **which layers go dark with it.**

---

## The rule

> **A gate on the picture is not a gate on what is drawn over the picture.**
> Layers derived from the picture move with it. Player chrome does not.

`pic_blank` (`= stopped_w | saver_on_w`) is the "the picture is black" fact, and it is
consumed twice in `dvd/emu.sv`: as the `subpic_blend` **input** (so the decoded frame goes
black) and as the gate on the subpicture layer's two terms in the overlay register stage.

## The layer table

| Layer | emu signal | Blanked by | Why |
|---|---|---|---|
| Decoded picture | `core_r/g/b` | `pic_blank`, at the **blend input** | Not at the `vga_*_q` mux where `sw_blank` lives — that sits before `sub_r` and would take the HUD and the logo with it. Here the picture goes black *underneath* and the chrome survives. |
| Subtitle / menu-highlight subpicture | `sp_q_inside` → `sp_on_e`, `hl_use` → `hl_use_e` | `pic_blank`, at the **register stage** | **Picture content.** A menu highlight is a recolour of subpicture pixels, and it never expires on its own (below), so ungated it burns in for the whole screensaver. |
| Transport HUD | `hud_on_w` → `hud_on_e` | `saver_on_w`, and stage-2 Stop (`stop_full`) | A static status line burning into a phosphor is what the screensaver exists to prevent. Stage-1 Stop **keeps** it: the presence of a caption *is* the stage readout. |
| Seek bar | `bar_on_w` → `bar_on_e` | same | same |
| Idle logo | `logo_on_w` | **never** | It *is* the screensaver. ⛔ Gating it is the obvious wrong generalisation and would leave a blank screen showing nothing at all. |
| `O[2]` diagnostics | `sp_seen`, `hlvis_seen`, `dbg_*` | **never** | They answer "did it **fire**?", not "was it **shown**?" — see below. |

⚠ `pause_q` is **not** in `pic_blank`. An ordinary pause keeps its picture and its
subtitle; only Stop and an armed screensaver mask anything.

---

## Why a menu highlight never expires on its own

`dvd/spu_decode.sv`:

```systemverilog
wire visible = enable && c_valid &&
               (menu_mode || ((stc >= c_show) && (stc < c_hide)));
```

`menu_mode` **bypasses the STC show/hide window entirely** — a menu subpicture shows for as
long as the menu is up, which is correct and deliberate. It also means this is the one
context where "it will time out on its own" is false, and it is why the defect presented as
a highlight sitting on a black screen indefinitely rather than as a flicker.

On Stop it is worse than indefinite in practice: a stop has no timer at all, so with
`Screensaver = Off` a stopped menu would have burned in until the user came back.

## Why the layer is MASKED, not torn down

Nothing in `spu_decode` or `nav_pci` is reset. The committed SPU bitmap, `c_valid`, the
button rect and `hl_coli` all survive, so when `saver_on` clears on `any_input`
(`dvd/stop_ctl.sv`, fed emu's `vm_entropy_stir`) the highlight is back **one `clk_sys`
later** with no re-decode and no re-arm.

That preserves the property the screensaver was HW-measured against when it shipped —
dismissing it restored the bit-identical paused frame, 0 px different. A teardown-based fix
would have destroyed exactly that.

⚠ There is a one-pixel skew on dismiss: the picture un-blanks combinationally at the blend
input while the overlay returns registered. It is the same skew `hud_on_e` already has, and
the same 1-px shift the subtitle tolerates by design.

## Why the base wires stay ungated

`sp_on_e` and `hl_use_e` are **new wires consumed only in the register stage**. The base
`sp_q_inside` and `hl_use` are left exactly as they were, because the release-visible `O[2]`
diagnostics read them directly:

- `sp_seen` → `dbg_blk3` — "a subpicture pixel decoded this frame"
- `hl_use_q` → `hlvis_seen` → `dbg_blk8` — "the highlight recolour fired this frame"

Gate those and a screensaving board reports RED for a subpicture pipeline that is working
perfectly, and sends the next debugger after a phantom. **`dbg_blk8` was already fixed once
for this exact class of mistake** (2026-08-17: it watched the composited `sp_force_q`, so a
HUD auto-popup alone turned it green — useless for the question it exists to answer).

Two more deliberate non-gates:

- **`sp_sel_col` → `pgc_palette`.** The palette *address*. With `sp_on_e` low the colour
  cannot reach the pins, so gating it changes no pixel — while adding a term to a BRAM
  address path in the display hotspot and creating a second, subtly different definition of
  "the highlight is active" for the next reader to pick the wrong one of.
- **`sp_r_q`/`sp_g_q`/`sp_b_q`.** Unobservable with `ov_on` low.

## ⚠ `logo_vis` and `pic_blank` are siblings

They are two separate expressions over the same facts (`saver_on_w`, `stopped_w`):

```systemverilog
wire logo_vis  = (saver_on_w || stopped_w || (!media_seen && ...)) && ...;
wire pic_blank =  stopped_w |  saver_on_w;
```

Nothing ties them together. Add a condition to one and not the other and the logo can be up
with the picture live, or the picture blanked with no logo on it. A future change to either
must move both.

---

## Verification

`dvd/emu.sv` has **no testbench**, and every module in this story is individually correct
and individually benched — the defect was one missing term in the expression composing
them. A bench that replicated emu's glue would carry whichever gate its author believed in,
which is the defect's own failure mode (`[[bench-that-cannot-fail]]`).

**`tools/check_saver_overlay_wiring.py`** reads the composition out of `dvd/emu.sv`. It
pins the *whole* policy — the pre-existing `hud_on_e`/`bar_on_e`/blend-input gates as well
as the new ones — and pins **by rejection** the wires that must stay ungated. Three parsing
traps are recorded in its docstring, each of which silently inverts a result:

- ⛔ `strip_comments()` is mandatory. The `dbg_blk8` comment *in this very region* contains
  the literal pre-fix expression `hud_on_w | bar_on_w | hl_use`, so a grep-based checker
  passes on a fully reverted file on the strength of that comment alone.
- ⛔ `hl_use_e` **contains `hl_use` as a substring**. Every test is over a token set, never
  a substring `in` — a tidy-up to `'hl_use' in rhs` inverts two assertions at once.
- ⚠ `terms()` does not strip Verilog literals (`4'd15` → the token `d15`), so use
  membership on any expression containing one and reserve equality for the gate wires.

**`bench/dvd/run_screensaver.sh`** runs three arms and, with `--red`, 13 mutations. Measured
rather than assumed: every emu mutation fails in exactly **one** named assertion group.
R3/R4/R5 all mutate `sp_on_e`, so each is matched on the message that distinguishes it
(absent / wrong terms / missing `~`) — a mutation caught by everything says nothing about
which assertion is load-bearing.

### Two pre-existing bench defects came out with it

- ⛔ **`subpic_blend_tb` never tested `ov_on=0` with `ov_force=1`**, so the entire premise
  of this fix — clearing `ov_on` alone removes the pixel — was ungated. `ov_force`'s name
  actively invites the wrong reading ("force it on"). MEASURED: mutate the module to
  `blend = (ov_on || ov_force) && …` and the **pre-change bench reports `RESULT: PASS` and
  exits 0**; with the on/off sweep it reports 962 errors and exits 1. `ref_out()` already
  modelled `if (!on) ref_out = vin` from the module's contract header, so the off half is a
  real check and not a restatement of the RTL.
- ⛔ **`stop_ctl_tb` and `subpic_blend_tb` both called `$finish` on the failure path**, so
  `vvp` exits 0 and a runner scoring the exit code reads a failing bench as a passing one —
  the `bench/ac3` and `run_p240.sh` `seek_bar_tb (240)` trap. `stop_ctl_tb` had **no runner
  at all** until `run_screensaver.sh`, so its copy had never been sprung; it was waiting for
  one. Both now `$fatal`. `bench/dvd/run_subpic.sh` had the same class of hole from the
  other end — five arms scored with `| grep RESULT`, which matches `RESULT: FAIL` exactly as
  happily as `RESULT: PASS` while `set -e` never trips.

### ✅ The HW round (2026-09-15) — control arm first, and the arithmetic is exact

Measured on MEN_IN_BLACK's main menu with **PLAY MOVIE** highlighted, both cores through
the **identical script**. `lit` = non-black pixels in one frame; `static` = pixels lit in
BOTH frames at the same position, i.e. what is parked on the blanked screen.

| arm | control `lit` | control `static` | fix `lit` | fix `static` |
|---|---|---|---|---|
| **Screensaver** (the report) | 5875 | **1189** | 4686 | **0** |
| Stop stage 1 | 5710 | **1024** | 4686 | **0** |
| Stop stage 2 | 5710 | **1024** | 4686 | **0** |

★★ **The fixed core's `lit` equals the control's `lit` MINUS EXACTLY ITS `static`, to the
pixel, on all three arms** (5875−1189 = 5710−1024 = 4686). So the fix removed the highlight
and **nothing else** — the logo is untouched. That is a far stronger statement than "the
count went to zero", which a fix that blanked too much would also satisfy.

The control's static bbox was **x 273..453, y 280..303** — the PLAY MOVIE button rect.

✅ **The round trip, which rules out the trivial wrong fix (delete the highlight):** paused
menu → highlight present; screensaver up → gone; one `up` press → **back, and on the next
button up**, so the menu is live and responding, not merely repainted.

✅ **The diagnostics stayed honest**, which is the claim only hardware can settle:
`hl_btns_armed`, `subpic_shown`, `hl_on` and `hl_recolour_fired` all read **GREEN under the
screensaver on BOTH cores**. Had they gone red on the fix core, the gate would have landed
on the base wires instead of the register stage and blinded `dbg_blk3`/`dbg_blk8`.

⚠ **Dismiss with `up`, NEVER `select`** — `select` ACTIVATES the highlighted button, which
on this menu is PLAY MOVIE, so it starts the film instead of returning to the menu.

⚠⚠ **THE FIRST CONTROL ARM DID NOT REPRODUCE, AND THAT WAS THE HARNESS.** It returned to
the menu on a fixed 20 s settle and PAUSED ON THE TRANSITION CLIP, where nothing is armed —
so there was no highlight to leak and the screensaver arm measured **0 static px on a core
that definitely has the bug**, while its own Stop arm, taken seconds earlier from the
genuinely armed menu, measured 1189. Same core, same run: one arm reproducing, the other
silently measuring nothing. **A step that never reached the state was not measured**, and it
reads exactly like a pass. The arm now waits for the board's own `hl_btns_armed` and then
pauses IMMEDIATELY, because pausing freezes the state — MiB's root is a LOOPING motion menu
and cycles back through its transition and disarms on its own.

★ Toggling `Debug Overlay` via `mister.py osd` does **not** dismiss the screensaver
(measured), so the armed check and the diagnostics check can both be taken without
disturbing what is being measured. But the `O[2]` blocks draw ABOVE `sub_r`, so the overlay
must be **off** for the pixel count or the blocks become the static pixels being counted.

⏳ Not exercised on hardware, covered structurally and by bench: a subtitle during a
*stopped* title (same `sp_q_inside` term, and `run_subpic.sh` covers the module), and an
ordinary pause keeping its subtitle (`pause_q` is not in `pic_blank`).

### The recipe

Control arm first — flash the **pre-fix** core and capture the defect, so the fix has a
number to beat. Set `Screensaver = 2min`, load a disc, open a menu with a button
highlighted, pause.

★ The instrument is **non-black pixels outside the logo's bounding box, across two
frames**: the logo moves and the highlight does not, which separates them without having to
locate the HLI rect. Expect a stable count pre-fix and ~0 after.

Then: press a key and confirm the highlight is back and the menu unchanged; repeat on Stop
(both stages) and on a stopped title mid-subtitle. Unregression: menu highlights and
subtitles during normal playback, an **ordinary pause** (the subtitle must **stay**), the
HUD auto-popup, and `O[2]` `blk3`/`blk8` still reading GREEN on a menu while the screensaver
is up — that last one is the diagnostics-stay-honest claim, and only hardware can show it.

---

## See also

- `dvd/stop_ctl.sv` header — the timer, the two Stop stages, the `media_seen` trap
- `docs/idle_screen.md` — the logo itself (ROM, bounce box, `boot.rom`)
- `docs/transport_hud.md` — the HUD and seek-bar geometry, and the overlay window
- `docs/subpicture.md` — the SPU decode and `subpic_blend` contract
