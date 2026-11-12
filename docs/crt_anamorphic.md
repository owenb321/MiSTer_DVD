# CRT anamorphic 16:9 handling — Fit / Letterbox / Crop

**Status (2026-07-05): Fit + Letterbox + Crop implemented and sim-verified
(`bench/dvd/resample_chain_tb.sv` +vsmode, progressive AND +crt field paths). Letterbox is now
ANTI-ALIASED — a true 2-tap vertical bilinear blend via the downstream `dvd/disp_vscale.sv`
(branch `feature/crt-letterbox-aa`); the old nearest-neighbour decimation is retired (§8). The
Fit/Letterbox/Crop geometry + the blend-is-real proof are green in sim; **✅ HW-CONFIRMED
2026-07-10 on the CRT.** Builds on
the HW-confirmed CRT 480i output (O[14], `docs/crt_480i.md`, PR fj#65) and the first-cut anamorphic
scaler (PR fj#66).

Anamorphic 16:9 DVDs are stored as 720×480 with the picture horizontally squeezed into the
4:3 raster, so on a 4:3 CRT (which we can't stretch horizontally) everything looks
tall/thin. Two independent axes fix it — a **vertical downscale** (Letterbox) or a
**horizontal crop** (Crop) — selected by **`O[4:3] CRT Aspect` (Auto / Fit / Letterbox / Crop)**.

## 1. The three modes

| Mode | Operation | Result on the 4:3 CRT |
|------|-----------|------------------------|
| **Fit** (baseline) | 1:1 passthrough (bypass) | 4:3 content correct (no-op); 16:9 shows squished tall/thin. **Bit-identical to the pre-scaler output.** |
| **Letterbox** | VERTICAL downscale ×3/4 (480→360 / field 240→180), centred + black bars | correct 16:9 geometry, full width, black bars |
| **Crop** (pan-scan) | HORIZONTAL: read the centre ¾ of the columns, stretch to full width; vertical stays 1:1 | correct 16:9 geometry, **FULL 480-line vertical resolution**, sides cropped, no bars |

Both corrections are nominally ×¾ (a 16:9 image in a 4:3 frame has scale factor
(4/3)/(16/9)=¾). Letterbox does it vertically and exactly (bars = ⅛ of the height each: 60
lines NTSC / 72 PAL). Crop does it horizontally but only to the nearest macroblock: it reads
33 of 45 macroblocks = the centre **528** px (not 540), stretched to 720 — ×0.733, so the
picture is ~2.3 % over-stretched and 6 px per side narrower than an authored 540-px pan
window (§2, §12).

**Why Crop is HORIZONTAL, not vertical:** to keep *full vertical resolution* (all 480 source
lines, no vertical scaling ⇒ no vertical aliasing) while filling the 4:3 screen with 16:9
content, the only correct operation is a horizontal pan-scan (crop the sides). A vertical
crop+upscale would throw away vertical resolution and over-stretch the (already tall)
anamorphic image — the earlier "Zoom" attempt did exactly that and was wrong; it is replaced
by this horizontal Crop. Auto never selects Crop on its own (it picks Letterbox for 16:9 /
Fit for 4:3) — **except on a 16:9 menu that forbids letterbox, which a set-top player also
pan&scans; see §12** (and a Crop choice is letterboxed on a menu that forbids pan&scan).

## 2. Where it lives

- **`dvd/disp_vscale.sv`** (NEW, the anti-aliased Letterbox — §8) — a small CLK-DOMAIN vertical
  resampler in the pixel path (`resample_bilinear → disp_vscale → disp_hstretch → pixel_queue`).
  When `vscale_en` it downscales the picture vertically by exactly ¾ (480→360 progressive /
  240→180 per field) with a TRUE 2-tap bilinear blend of the two straddling SOURCE lines
  (`out = src[k]·(1−f) + src[k+1]·f`), buffering one source line in a small M10K ping-pong
  buffer while the next streams in. A drift-free Bresenham phase machine over the 4/3 step gives
  `f ∈ {0, ⅓, ⅔}` and picks the base line `k` (0,1,2,4,5,6,8,… — every 4th source line is used
  only as the upper tap). Because the addrgen emits FIT vertically for Letterbox (all source
  lines), the blend needs NO extra display read bandwidth. FIELD path (**only when the decoder is
  in native-fields mode** — see the ⚠ correction below): the addrgen emits a whole field's lines
  contiguously (one parity), so blending adjacent stream lines = blending adjacent
  SAME-FIELD lines — parity-safe (no comb/twitter) for both film (rff 3:2) and true-interlaced
  content. Output-line 0 carries the scan's frame-top code (ROW_0/ROW_1) so the mixer's parity
  placement is preserved. Pure combinational wire pass-through when `~vscale_en` (Fit/Crop
  bit-identical). Runs at 1 pixel/clk (a 2-cycle machine underruns the raster during the content
  band). Mirrors the `disp_hstretch` flow-control pattern (input `fifo_sc` + `fwft_reader`).

- **`dvd/resample_addrgen.v`** — the HORIZONTAL crop (`hcrop_en`). *(The addrgen VERTICAL scaler
  `vscale_mode` — the old nearest-neighbour ¾ line-drop decimation — is RETIRED: Letterbox now
  uses `disp_vscale` above, so emu drives `disp_vscale_mode = 0` always and the addrgen emits FIT
  vertically. The `vscale_mode` port + its datapath remain but are dormant, pruned under the
  constant; kept only so the six addrgen governor testbenches keep their `.vscale_mode(0)` tie.)*
  - *Horizontal (Crop):* the macroblock walk runs `mb_first_c..mb_last_c` instead of
    `0..mb_width-1`, where `hcrop_mb = round(mb_width/8)` (6 of 45 ⇒ read 33 MBs = the centre
    528 of 720 px). The COL_0/COL_LAST position codes move with the window so the cropped
    line still carries clean first/last-column markers.
  - **FIT (`~vscale_en && ~hcrop_en`) bypasses both scaler stages — bit-identical** to
    upstream (verified by the tb Fit case + the six addrgen governor tbs still passing).

- **`dvd/disp_hstretch.sv`** — the Crop horizontal stretch, a tiny CLK-DOMAIN streaming pixel
  repeater between `disp_vscale` and `pixel_queue` (it now sits downstream of `disp_vscale`;
  in Letterbox `disp_vscale` is active and `disp_hstretch` passes through, in Crop vice-versa —
  they are mutually exclusive). It duplicates the
  `(hdst_width−hsrc_width)` extra pixels evenly across each line via a Bresenham error term,
  turning the cropped 528-px line back into a full 720-px line. The mixer then displays it
  1:1 — so the **HW-proven dot-domain mixer/pixel_queue FSMs are completely untouched** (no
  risky timing surgery). When `hcrop_en=0` it is a pure combinational wire pass-through
  (Fit/Letterbox bit-identical). The COL_LAST pixel is never duplicated (stays the line's
  last pixel so the mixer's line-end detection is unchanged); the first output keeps the
  source's ROW_{0,1,X}_COL_0 marker, duplicates carry ROW_X_COL_X.

- **`rtl/mpeg2/mixer.v`** — the Letterbox bars (`disp_v_offset`), unchanged from the first
  cut: hold the picture frame-top in STATE_WAIT until `v_pos` reaches the offset (top bar =
  mixer black default; bottom bar automatic). `v_pos` is the woven frame-line number in both
  progressive (`v_cntr`) and interlaced (`2·v_cntr+parity`) modes, so one value
  (`vertical_size/8`) serves both. Offset 0 (Fit/Crop) reduces to the original compares
  (bit-identical).

- **`dvd/emu.sv`** — `O[4:3] CRT Aspect` (status[4:3]) resolves to `disp_vscale_en` (Letterbox,
  drives the downstream 2-tap blender + the mixer bar offset) and `disp_hcrop_en` (Crop),
  CRT-mode only (HDMI keeps ascal's `VIDEO_ARX/ARY` — no double letterbox). `disp_vscale_mode`
  is tied to 0 (addrgen fit; the NN path is retired). Auto = Letterbox for 16:9 / Fit for 4:3
  (from the latched sequence-header aspect).

## 3. A/V-sync & governor: unaffected (verified)

Display duration is counted in image **scans** (one refresh per frame/field), NOT lines or
columns, so changing the per-scan line/column count does not touch
`cur_show`/`show_next`/`refresh_tick` or the frame-drop ledger. `gov_field_late_tb` still
passes (1:1 late:refresh) — re-verified with the AA change (the governor is in `resample_addrgen`,
which the downstream `disp_vscale` doesn't touch; the addrgen emits FIT so its scan cadence is
identical to Fit). The 256-line strobe class is avoided by construction (Letterbox emission =
360/180 ≤ active; Crop emission = full width via hstretch). On HW, confirm overlay row 17
`vid_err` stays flat in Letterbox/Crop.

## 4. HDMI coexistence

One raster feeds both outputs. Letterbox/Crop are baked only when O[14] CRT mode is on
(`crt_eff`); HDMI keeps using `VIDEO_ARX/ARY` via ascal, so there is no double letterbox. In
CRT-off mode all three menu choices collapse to today's Fit output.

**Partly built (2026-10, §13):** an EXPLICIT Letterbox or Crop now applies on the
Progressive raster too, so a 4:3 HDMI display (and a 31 kHz analog one) can have Crop. Auto
and Fit on Progressive are unchanged. The text below is the original 2026-07 plan, kept for
its reasoning: make a 4:3 HDMI output honor the same Fit/Letterbox/Crop setting (roadmap item
"HDMI 4:3 output follows the same … setting as the analog CRT"). Fit/Letterbox are already
reachable on HDMI via ascal `ARX/ARY`; only **Crop** needs the core `disp_hstretch` path
un-gated from `crt_eff`. Different framing per output at once is the separate decoupled-framing
idea (`docs/experiments.md`).

## 5. Simulation (`bench/dvd/resample_chain_tb.sv` `+vsmode=N`)

`+vsmode` (0 Fit / 1 Letterbox / 2 Crop) drives `disp_vscale.vscale_en` (Letterbox) +
`disp_hstretch.hcrop_en` (Crop) + the mixer bar offset, end-to-end through
resample → disp_vscale → disp_hstretch → pixel_queue → mixer. `report_frame` asserts, per good
frame:
- picture top/bottom `v_pos` via the mixer's `dbg_first_vpos`/`dbg_last_vpos` (coordinate-
  clean vs the tb's back-porch-offset out_line), the emitted line count, and no black hole
  inside the band (spill/starve);
- **horizontal fill**: the non-black picture must span the whole active region
  (`hnb_min..hnb_max` ≈ `hact_min..hact_max`) — a Crop that failed to stretch would pillarbox.

**`+vgrad=S` (BLEND PROOF)**: forces `+linetag` and scales the source-line tag by `S` (a
divisor of 256, e.g. 8) so adjacent source lines differ by `S`. A real 2-tap blend then lands
on INTERMEDIATE values (not multiples of `S`) on the `f∈{⅓,⅔}` output lines, whereas
nearest-neighbour would only ever emit multiples of `S`. The tb counts output lines whose luma
is not a multiple of `S`; `BLENDPROOF … PASS` needs ≥40 (well below the ~⅔ of the output lines
that carry a non-zero weight). This distinguishes the true 2-tap from decimation — a plain
line-index gradient (step 1) can't, since blending two adjacent integers rounds back to an
integer.

**`+hgrad=1` (BLEND PROOF, horizontal — the §8b twin)**: makes every 64-bit memory word the
same **period-2 column square wave** (40/200). No address side-fifo is needed (every word is
identical, so no decode) and the phase is continuous across word (8 px), macroblock (16 px) and
crop-origin (`hcrop_x0 = 96`) boundaries — all even. Luma passes through `resample_bilinear`
unchanged, so the wave reaches `disp_hstretch` intact. A real 2-tap resample lands strictly
BETWEEN the two levels on every column with a non-zero weight (~14/15 at 528→720); nearest-
neighbour duplication can only ever emit the two levels themselves, scoring **exactly 0**.
The tb counts picture pixels strictly inside the band; `BLENDPROOF-H … PASS` needs more than
half. Note the same reasoning as `+vgrad`: a plain *column-index ramp* cannot prove this either.
**Run `+vsmode=0 +hgrad=1` as the CONTROL** — Fit does no horizontal resampling, so it must
score 0, which is what proves the `~hcrop_en` pass-through really is a bypass (the tb inverts
the assertion automatically for non-Crop modes).

> ⚠ **Gotcha the control caught.** `resample_bilinear` treats the stored luma byte as **signed**
> and adds 128 on the way out (`y <= y_pixel_5 + 8'd128`), so the MEMORY bytes and the DISPLAYED
> levels differ by an XOR-0x80. The first cut wrote `0x28`/`0xC8` expecting 40/200 and got
> 168/72 — *both inside* the "interpolated" band, so the proof read **100% in every mode,
> including Fit**. A blend proof that passes in the bypass mode is measuring nothing. The tb now
> keeps `HG_MEM_*` (what the memory returns) and `HG_*` (what the display shows) as separate
> explicit constants. This is the general lesson: **an always-passes control is a broken test,
> so make the control's expected value the OPPOSITE of the main assertion's**, not merely a
> smaller number.

Verified green (this branch): progressive Fit (256 test / 480 real @ v_pos 0.., full width),
Letterbox (¾ lines @ vertical_size/8 .. + bars, hole≈0), Crop (full vertical + full width fill
after the 528→720 stretch); the +crt field path for all three (Letterbox 7/7 frames pass, 96
lines/field, correct parity, hole=0); and the blend proof — progressive `127/256` and +crt
field `~60/128` output lines interpolated (`vgrad=8`) ⇒ the 2-tap is real, not NN.

## 6. HW test plan

1. HDMI-only sanity: 480p / HDMI-480i unchanged (Fit is bit-identical; CRT Aspect ignored off CRT).
2. CRT + O[14] + a 16:9 anamorphic DVD:
   - Auto/Letterbox: correct proportions, ~60-line black bars top+bottom, no picture split,
     and SMOOTH vertical detail (the 2-tap AA — no line-drop banding/twitter on fine texture,
     esp. on the 480i field path). See §8.
   - Fit: full-height, tall/thin (confirms passthrough).
   - Crop: full-height picture, sides cropped, no bars, correct proportions, FULL vertical
     resolution (no scaling artefacts vertically).
3. Overlay on, compute crush (MiB/Matrix) in Letterbox/Crop: row 17 `vid_err` FLAT.

## 7. Menu / bit map

`O[4:3] CRT Aspect` = status[4:3]: 0 Auto, 1 Fit, 2 Letterbox, 3 Crop.

## 8. Letterbox anti-aliasing — DONE (`dvd/disp_vscale.sv`)

Letterbox is a vertical **downscale**; the first cut (PR fj#66) did it as nearest-neighbour line
selection in `resample_addrgen` (`vscale_mode==1`), which drops one source line in four and, on
the 480i field path, reads as banding / reduced vertical resolution on fine detail. This is now
fixed by a **true 2-tap vertical bilinear blend** in the downstream `dvd/disp_vscale.sv`
(`out = src[k]·(1−f) + src[k+1]·f`).

**Why the downstream module, not the in-place 3-module surgery.** The "obvious" fix — thread a
SECOND luma-line fetch through `resample_addrgen → resample_dta → resample_bilinear` so the
blend has two lines — touches three fragile core modules AND adds ~25% display read bandwidth
(the luma path is single-line today; only 4:2:0 chroma is vertically interpolated). Instead
`disp_vscale` sits in the pixel path (`resample_bilinear → disp_vscale → disp_hstretch →
pixel_queue`), the addrgen emits FIT vertically (all source lines — **no extra read bandwidth**),
and the module buffers ONE source line (~720 px of {y,u,v,osd} in a small M10K ping-pong) while
the next streams in, blending them pixel-by-pixel. This isolates the risk from the resample
internals and gives true source-space bilinear. Cost ≈ 1–5 M10K + four 9-bit blend multiplies.

**Design points** (full detail in the module header):
- Drift-free exact ¾ via a Bresenham phase (`r` cycles 0,1,2 with a `+1` k-skip on wrap):
  `f ∈ {0, 85, 171}` (Q0.8), base line `k = 0,1,2,4,5,6,8,…`. Output line `i` is produced while
  RECEIVING source line `k_i+1` (its `k_i` line is buffered).
- **1 pixel/clk** pipeline (consume-gated on `out_almost_full`, one in-flight skid into the
  queue's prog_full margin). A 2-cycle machine was tried first and UNDERRAN: it produces
  ~0.375 px/clk, below the ~0.42 px/clk the mixer drains per content line, so the pixel_queue
  emptied mid-band and the picture came out with scattered black holes. 1 px/clk gives ~0.75
  px/clk during the content band — ample.
- **Field-safe — ⚠ only on the native-fields path (corrected 2026-08-22)**: the claim below was
  written for the RETIRED O[14] whole-core CRT mode and stopped applying to the DEFAULT analog
  path when dual-raster landed. It holds whenever the decoder emits fields (`interlaced=1`:
  O[10:9] Interlaced Out, or Analog Out = Native Fields) — the addrgen emits a whole field's
  lines contiguously (one parity), so blending adjacent stream lines = adjacent same-field
  lines, no inter-field comb/twitter, and each field re-arms on its ROW_0/ROW_1 frame-top.
  Under the default dual-raster analog path `il_eff` is forced OFF, the addrgen emits a WOVEN
  progressive frame, and "adjacent stream lines" are OPPOSITE parity: the blend cross-fades the
  two source fields. Harmless for film (both halves of a weave frame are the same instant),
  real but mild on true-interlaced content (softening, not combing). Reaches only Letterbox;
  Fit and Crop never blend vertically. See `docs/analog_dual_raster.md`.
- **Bars unchanged**: the module emits only the 360/180 content lines carrying the scan's
  frame-top code on line 0; the mixer's `disp_v_offset` still places them + the bars.
- **Pass-through**: `~vscale_en` ⇒ pure combinational wire (Fit/Crop bit-identical).
- Flow control mirrors `disp_hstretch` (input `fifo_sc` 128-deep + `fwft_reader`; downscale ⇒
  back-pressures resample via prog_full).

Retired: the addrgen NN `vscale_mode==1` path (emu drives `disp_vscale_mode=0`; dormant/pruned).

**Note:** Crop remains the alias-free full-vertical-resolution mode (no vertical scaling); it's
still the sharpest for detail-critical 16:9, but Letterbox is now the clean whole-frame option
(no side crop). Crop's horizontal 528→720 stretch is now a true 2-tap resample too — see §8b.

## 8b. Crop horizontal anti-aliasing — DONE (`dvd/disp_hstretch.sv`)

**Status: ✅ HW-CONFIRMED 2026-08-01 (PR fj#155).** The user reported that Crop looked
aliased next to Letterbox. It was: Letterbox had done a true 2-tap vertical blend since §8, but
`disp_hstretch` was still pure pixel **duplication** — a Bresenham picked ~192 of the 528 source
pixels per line and emitted each one twice, verbatim, leaving a ~1.36× stair-step on
near-vertical edges. (This was the first §10 follow-up; it is now retired.)

`disp_hstretch` is now an **output-driven phase walk**, the horizontal twin of `disp_vscale`:

```
out[j] = src[k]*(1-f) + src[k+1]*f      where   k + f = j*hsrc/hdst
```

so display pixel `j` samples the exact source position and blends the two straddling pixels.

**Design points** (full detail in the module header):
- **No per-pixel divide, no comparator tree.** The Q0.8 step `256·hsrc/hdst` is decomposed
  ONCE — by an 8-step restoring divider on the quasi-static geometry — into
  `qstep = floor(256·hsrc/hdst)` and `rstep = 256·hsrc − qstep·hdst` (187 / 528 for 528→720).
  The pixel path is then a plain 13-bit add/compare plus a 9-bit add.
- **★ Load-bearing contract with `crt_ov_map` (§9).** `f8` is **FLOORed**, never rounded,
  because `floor(256·f) ≥ 128 ⟺ f ≥ ½` *exactly*. That makes the nearest tap provably
  `k + (f8≥128) == floor((j·hsrc + hdst/2)/hdst)`, so the overlay inverse mapper reproduces it
  with a plain **rounding Bresenham** — no divider, no approximation, and the tb co-sims the
  two column-for-column. Rounding `f8` would break the identity on a 1/512-wide sliver.
- **Throughput unchanged.** Crop is always an upscale ⇒ `qstep ≤ 255` ⇒ `f8 + qstep + carry ≤ 511`,
  so at most ONE source pixel is consumed per output: still ≤1 in / 1 out per `clk_en`.
- **Exactly `hdst` outputs per line** — the same count a Fit line emits. The old duplicator's
  documented `hdst−1` off-by-one is retired; `mixer.v`'s line end is purely position-code
  driven (`ROW_X_COL_LAST`), with no length assumption, so this is safe and more correct.
- **Right-edge clamp** `b = a`, triggered both when the low tap was the line's `COL_LAST` and
  when the fifo head has already become the NEXT line's `COL_0` (which would otherwise blend
  across the line boundary). A short source line self-heals: the prime step drains to the next
  `COL_0`.
- **`osd` is NEAREST-picked, not blended** (`f8 ≥ 128 ? b : a`). It is a colour-lookup *index*
  (`mpeg2_osd` → `osd_clt`), so interpolating it is semantically wrong — and it drops the
  multiplier count 4 → 3. (This closes the §10 "blend osd as nearest" item **for Crop**; it is
  still open for `disp_vscale`.)
- **3-stage pipeline** (taps+weight → `(b−a)` difference → multiply+round+add), with both taps
  from **fabric registers** rather than an M10K output. This is the `disp_vscale` `a_q` lesson
  (`docs/history.md` §8): that blend's memory-read → 4-channel-multiply → output-register cycle
  was 11.0 ns of 12.3, *set* the clk_dec Fmax, and produced the HDMI chroma-fringe placement
  lottery. Adding a second blend at ~89% ALM is exactly the situation the fringe playbook warns
  about, so this one is kept strictly shorter (subtract split off the multiply's path).
- **Pass-through unchanged**: `~hcrop_en` ⇒ pure combinational wire, so Fit / Letterbox / HDMI
  are bit-identical.

## 9. Overlay alignment — subpicture + menu highlight under Letterbox/Crop (`dvd/crt_ov_map.sv`)

**Status: ✅ HW-CONFIRMED 2026-07-11 (PR fj#108, tested on the real CRT).** Closes the "CRT 4:3
experience must match HDMI" gap the user reported: the menu highlight (and the whole
subpicture layer) did not account for the Letterbox/Crop transforms.
**⚠ Amended 2026-09-02 (subtitle sawtooth fix, §9a): the mapped query now serves the
MENU/HIGHLIGHT context only — plain dialogue subtitles bypass the Letterbox/Crop inverses
and render at raw raster coordinates.** Everything below stays accurate for the mapped
context; §9a records the split and its rationale.

**The bug.** The overlay layer — `spu_decode`'s per-pixel bitmap query, the HLI button-rect
compare (`hl_hit_q`), and the O[2] rect border — runs at the display tap in `emu.sv` in
**raster** coordinates. On HDMI that's correct: the blend happens *before* ascal, so overlay
and video scale together. On the CRT, Letterbox/Crop rescale the video *upstream*
(`disp_vscale` vertical ¾ + mixer bars; addrgen centre-crop + `disp_hstretch` 528→720
resample) while the overlay stayed unscaled — subtitles and menu highlights landed offset
from the picture (vertically squeezed content under an unmoved highlight in Letterbox;
horizontally stretched content under an unstretched one in Crop).

**The fix — inverse-map the query, not the artwork.** `dvd/crt_ov_map.sv` converts the
raster position back to the SOURCE pixel the video path is displaying there, and the whole
overlay layer (subpicture query + highlight rect + O[2] border) queries source space:

- **Letterbox (vertical):** replicates `disp_vscale`'s Bresenham walk (output line *i* ←
  base `k_i = i + ⌊i/3⌋`, weight `r_i/3`) and reports the **nearest tap** `k + (r==2)` =
  `round(i·4/3)`; per-field re-arm at the bar edge (`v_bar`/`v_bar+1`) mirrors the
  blender's per-field restart, parity preserved. Bar/blank lines map to 0xFFF (outside any
  DAREA/rect ⇒ overlay hidden — the overlay lives *inside* the picture, like HDMI).
  *(Since 2026-09-02 the sentinel clips the menu/highlight context only — raw-path
  subtitles may render into the bars by design, see §9a.)*
- **Crop (horizontal):** replicates `disp_hstretch`'s duplicate-insertion error term
  column-for-column (fresh advances the source column, a duplicate repeats it; COL_0/last
  never duplicated; right-edge clamp = the forward stage's documented 1-px shortfall).
  Output = `hcrop_x0 + column`, so overlay content in the cropped side bands clips exactly
  with the video.
- **Pass-through:** both enables low ⇒ combinational wires (bit-identical for HDMI /
  CRT-Fit — zero risk to the shipped paths).

Supporting changes:
- **`spu_decode` row-base adder generalized:** the mapped `q_y` *skips* every 4th source
  line (steps +1/+2 progressive, +2/+4 field), so the per-line `q_row_base` adder gained
  the `+2·STRIDE` (progressive) and `+4·STRIDE` (field) branches. Plain rasters unchanged.
- **`mpeg2video.horizontal_size_out`** (new tap, `// DVD-FORK`): emu derives the crop
  geometry (`hcrop_mb = (mb_width+4)>>3` etc.) with the exact addrgen/hstretch formula
  instead of assuming 720 (2-FF registered, quasi-static).
- **CRT Auto is now menu-aware:** `crt_letterbox` Auto follows `ar_wide_auto_eff` (IFO
  V_ATR while a menu is up, PR fj#86) instead of the raw stream aspect — an anamorphic menu
  letterboxes on the CRT under Auto exactly as it corrects on HDMI (menus author lying
  4:3 sequence headers; see memory/docs on PR fj#86).
- The transport HUD / seek bar stay raster-anchored on purpose (screen furniture, not
  picture content).

**Verification (`bench/dvd/crt_ov_map_tb.sv`, in `run_subpic.sh`):** **T1a** drives the REAL
`disp_hstretch` at a small geometry (128→192) with an AFFINE source tag — which collapses the
2-tap blend onto the nearest tap exactly (`b−a = 1` ⇒ `out = k + (f8≥128)`) — and requires the
inverse to match it column-for-column (two lines = restart proof); **T1b** repeats at the real
528→720 against the closed form `round(j·hsrc/hdst)`, and pins the forward line geometry
(exactly `hdst` pixels, `ROW_0_COL_0` first, `ROW_X_COL_LAST` last, no interior boundary codes);
**T1c** is the blend proof — a period-2 square wave must land strictly between the two levels on
most columns (671/720 measured; NN scores 0), so a regression to duplication fails loudly.
T2 pins the REAL `disp_vscale` field walk
to the closed form (tags `3j` decode to `3k+r` exactly); T3 checks the inverse against
that closed form across full 480i frames (bars/band/blanking, both fields, two frames =
re-arm proof) + progressive; T4 pass-through bit-identity; T5 drives a real `spu_decode`
(bitmap seeded) with the mapped walks and checks every read against `bmp[y·STRIDE+x]`.
All existing subpic/HUD/nav_pci suites green.

**✅ HW-CONFIRMED (2026-07-11, PR fj#108)** on the CRT with a 16:9 disc — (a) Letterbox:
subtitles sit inside the letterboxed picture at the right height *(superseded 2026-09-02:
subtitles now render RAW, at their authored height — see §9a)*; menu highlight boxes sit
ON their buttons (T2/Matrix menus); (b) Crop: highlight tracks the stretched buttons,
overlay clipped at the crop edges; (c) Fit + HDMI: unchanged (pass-through); (d) CRT Auto
on an anamorphic menu now letterboxes (matches HDMI). Release build gated green:
clk_dec 91.24/87.58 MHz, `releases/DVD_crtovalign_20260711_0009.rbf`.

## 9a. Context split — subtitles raw, menus/highlights mapped (2026-09-02, ⏳ HW-confirm pending)

**The report:** subtitles on the analog output show **sawtooth/aliased edges** under
Letterbox (the Auto default for 16:9 discs). Root cause is §9's own design point: the
inverse map is **NEAREST-tap** — under Letterbox it drops every 4th subtitle line with no
blending (and per-field on the consolidated fields raster, so the stair-steps also shimmer
between fields), while the video underneath goes through `disp_vscale`'s 2-tap blend and
stays smooth. The mismatch is the artifact. On HDMI-Fit both layers scale together through
ascal, which is why the report is aspect-mode-only.

**The fix — split by context, not by layer.** The mapped coordinates only ever *matter*
when the HLI rect can draw or the SPU is picture-composed art; a dialogue subtitle does not
need to track the rescaled picture (a set-top player doesn't scale subtitles either). It
CANNOT be split per-layer: the highlight recolour reads the queried pixel's class
(`hl_use`/`hl_ci` mux on `sp_q_idx`) and only draws where `sp_q_inside`=1, and `spu_decode`
has one `q_x/q_y` port pair — rect compare and bitmap query must share one coordinate
space whenever a highlight can draw. So `emu.sv` computes a **context select**:

```
sp_ctx_mapped_w = hl_btns_armed | (menus_on && menu_active) | sp_menu_early
                | vm_owns_route | force_43_subp
```

- `hl_btns_armed`, not `hl_on_w`: the strict superset covers the arm→fetch window AND is
  the O[2] `dbg_rectb` gate — whenever ANY rect can draw, the space is mapped, by
  construction. (`in_title_hli` — the white rabbit — is subsumed: it is defined as
  `menus_on && !menu_active && hl_btns_armed`.)
- `vm_owns_route` / `force_43_subp`: SetSTN-forced art and the MiB flipbook are picture
  content and keep tracking the rescaled picture. Known residual: a disc whose VM
  SetSTN-forces a genuine dialogue-subtitle stream keeps the nearest-tap path — revisit
  if ever reported.
- Pure `sub_on` playback is the only raw context — that is the fix.

**Why not map the rect alone (asked and answered, 2026-09-02).** Mechanically it would be
easy — the rect is four quasi-static numbers, so one could forward-map `hl_x1..y2` once
per HLI instead of inverse-mapping the per-pixel query. But the highlight has NO pixels of
its own: it draws only by recolouring the SPU pixels the query fetches (`hl_ci`/`hl_a`
select on `sp_q_idx`, nothing renders where `sp_q_inside`=0), and the rect is authored ON
the button art — they are one object on the disc. A mapped rect over a raw-queried bitmap
recolours whichever art pixels happen to sit under the displaced rect: the wrong part of
the button, or nothing (a background-class pixel with HLI alpha 0). So the switchable unit
is always **(art + rect) together**, and the only real question is what space the ART
needs — menu button art composes with imagery baked into the video frame, so it must
track the rescaled picture; a dialogue subtitle composes with nothing. That is why the
split is per-CONTEXT.

**Can a highlight and dialogue subtitles coexist?** Spatially never — one `spu_decode`,
one committed SPU frame, one stream (`sp_track_eff` mux); a highlight is a recolour of
whatever is displayed. On every known disc pattern the highlightable art DISPLACES the
subtitle stream for its window (menus/`sp_menu_early` force track 0; the white
rabbit / MiB prompts force theirs via SetSTN = `vm_owns_route`), so the "sawtooth returns
while an HLI is armed" edge affects the button art, not dialogue subs. The theoretical
residue: a disc arming an in-title HLI WITHOUT forcing a stream would leave the user's
subtitle displayed, mapped (sawtooth) and recolourable under the rect for that window —
pre-existing behaviour, not a regression. If such a disc ever surfaces, the consistent
refinement is raw art + raw rect for that case (prompt text doesn't align to video
imagery): drop the bare `hl_btns_armed` term and let `vm_owns_route` catch forced-stream
prompts — deliberately NOT done now, since it trades a proven-safe superset for an
assumption about discs never seen.
**⚠ Done 2026-11-11 (§9c):** the term is now `hl_btns_armed & ~sp_user_path`.

The select is **committed on `av_refresh_tick` (frame top) only**: `spu_decode`'s
`q_row_base` walker accepts only {reset,+1,+2}/{reset≤1,+2,+4} q_y steps, so a mid-frame
raw↔mapped flip would leave it stale for the rest of the field (`crt_ov_map_tb` T8b proves
exactly that). The split is implemented by gating the instance enables
(`letterbox_en = analog_letterbox & sp_map_en`, `crop_en = (analog_crop & sp_map_en) |
sif_hfill_eff`) — safe because `crt_ov_map`'s Bresenham walkers run **unconditionally**
and the enables sit only in its output mux, so enable-gating IS an output mux: toggling
between fields is glitch-free and the mapped walk is exact the instant it is re-selected
(T8a). Two deliberate consequences:

- **The SIF fill stays FULLY mapped in every context** (`sp_map_en = sp_ctx_mapped_q |
  sif_hfill_eff | sif_v2x_eff`): sub-720 SPU bitmaps are authored in SIF source space
  (`spu_decode` stores at absolute authored coordinates, 720-stride), so raw raster
  coordinates would draw them unscaled in the top-left quadrant. Both SIF terms force the
  whole map so manual Letterbox on SIF content keeps the composed inverse intact.
- **Raw subtitles may render into the letterbox bars** — they lose the 0xFFF bar
  sentinel, so a DAREA authored low in the frame draws over the bottom bar. User-accepted
  (standalone-player behaviour, arguably an upgrade: full authored resolution, no clip).

Sub-pixel note: with crop/SIF mapping active the mapped x lags the raw x by one clk_sys
(§9 TIMING); the context mux therefore carries a ~0.5-pixel horizontal differential
between contexts against the single `SP_QX_ADJ` calibration — invisible, recorded here so
nobody re-derives it as a bug.

**Verification:** `crt_ov_map_tb` **T7** (raw subtitle path: mapper is a wire for every
raster line INCLUDING the bar band, no sentinel; raw 480i field walk through the real
`spu_decode` across the band edge into the bars, both fields) and **T8** (toggle
semantics: mapped→raw→mapped fields with inter-field toggles all bit-correct; a
mid-field coordinate jump demonstrably stales the row base and recovers at field top).
The emu-side select itself is ~8 lines of glue with no emu-level TB (none exists) —
verified by review. All `run_subpic.sh` suites green.

**HW gate:** subtitle edges clean under Letterbox/Crop on the CRT (and HDMI-480i — the
letterboxed raster is shared); T2/Matrix menu highlights still land on buttons; white
rabbit aligned; MiB flipbook still tracks the picture; SIF disc subtitles unchanged.

## 9c. The user's subtitle drawn mapped since v0.10.0 (the SPRM2 write-back); raw under an HLI (2026-11-11, ✅ HW-CONFIRMED, branch `feature/subpic-vscale`)

**The report (maintainer):** subtitles look rough on a CRT under Letterbox (The Matrix, English
switched on with the Subtitle button), and smaller in Letterbox than in Crop.

**What it was: a v0.10.0 regression, measured on the board.** A button-chosen subtitle is meant
to be §9a's RAW context, 1:1. It was in the MAPPED one. Its glyphs were the disc bitmap
**squeezed to ¾ vertically under Letterbox** (a capital T 12 rows tall with a 1-row crossbar;
the bitmap's capitals are 17 rows, decoded with `tools/spu_ref.py`) and **stretched 1.36×
horizontally under Crop** (a line 346 px wide with 4 px stems, against 254 px and 3 px). Those
are exactly §9's two inverse maps, nearest-tap, so Letterbox dropped every 4th line.

**Why:** since 2026-10-27 (save states, in v0.10.0) a Subtitle step writes the user's choice
back to SPRM2 (`spst_wb`, `docs/nav_engine.md` §11). That write moves `vm_spstn`, and the
`vm_owns_sp` claim read it as a disc SetSTN, so the VM re-claimed the stream one cycle after
the press released it. The write-back's comment said "with the same value, so nothing audible
changes": true of the stream, false of the overlay, because `vm_owns_route` is also a
mapped-context term (§9a).

**Fix 0 (the fix for the report):** the write-back does not claim. `spst_wb_mask` marks the
write in flight; a `vm_spstn` change that lands as `spst_wb_val` (`spst_wb_landing`) is ours.
Any other change is the disc's and claims as before. A disc SetSTN of exactly the value the
user chose is not claimed either: harmless, it is the same stream and it stays the user's,
raw. Audio's write-back still re-claims, harmlessly (`vm_owns_aud` picks the track only).

**Fix 1:** the §9a residue refinement, `hl_btns_armed & ~sp_user_path`. `sp_user_path` is the
complement of `sp_track_eff`'s select (`menu_sp_ctx | vm_owns_route | force_43_subp |
fs_route`), so an armed in-title HLI no longer flips the user's own stream to the mapped
space. Menus, Scene It, SetSTN-forced art, the MiB flipbook and an armed HLI over the forced
route (subtitles off, where the white rabbit is drawn) stay mapped.

**Refuted on the way (each cost a HIL round; kept so they are not re-derived):**
- "English goes nearest-tap at every white-rabbit window". The 9 rabbit windows (~9 s,
  single-button HLI) are interleaved cells whose only subpicture streams are `0x22`/`0x23`;
  English is not in them, and PLAY MOVIE does not play them. (Fix 1 is still right for the
  residue; it was not this report.)
- "interlace twitter on the raw path". It came from reading the Debug Overlay's block 1
  (`hl_btns_armed`) red as "raw"; no block shows `vm_owns_sp`. The glyph measurement settled it.
- "a disc-made letterbox variant": on The Matrix `0x21` is `0x20`'s bitmap byte for byte,
  placed 20 lines lower.

**Rejected (by the maintainer, after a prototype was built, fitted and HIL-compared):** a 2-tap
vertical filter for every mapped overlay (the bitmap banked ×4 by row so two rows read per
pixel, a second `hl_compose` and palette port, a two-tap compositor), plus an interlace
flicker filter for unscaled overlays on the same hardware. Cost +236 ALM, +2 M10K, +6 DSP for a
barely visible change on menu highlights, and the flicker filter answered the refuted twitter
theory. Not worth ~7 % of the ALM headroom. If it is ever wanted, the design is: two taps
named by `crt_ov_map` (disp_vscale's pair and weight), four row banks so taps k/k+1 and k/k+2
never share one, compose both taps and blend the composites with disp_vscale's blend8.

**Known residual:** a subtitle turned on from the disc's OWN menu is a real SetSTN, so it is
VM-owned and mapped: ¾ tall and nearest-line under Letterbox, as before v0.10.0. So is one
restored by a save-state load (SPRM2 comes back through the VM). Telling a dialogue stream
from disc art at SetSTN time would fix both; nothing does that yet.

**Verification:** `tools/check_subp_ctx_wiring.py` arms 1–4 (FAIL on `main` in 1, 2 and 4);
`run_subpic.sh --red` X-R1 (the write-back claims again → arm 4 only) and X-R2 (a bare
`hl_btns_armed` → arm 2 only). `check_subp32_wiring.py` arm 6 now reads the claim's condition
rather than its exact text.

**HW gate:** ✅ on the rig, 2026-11-12, with the prototype build carrying Fix 0 (the RTL of
Fix 0/1 is the same here): The Matrix, English via the button, Interlaced. Letterbox 0:04:47,
T 12 → 16 rows, drawn at its authored place low in the bottom bar; Crop 0:06:29, the same line
346 → 254 px wide. ✅ This branch's build too (`DVD_subvscale4`, SEED 7: 38,206 ALM / 520
M10K / 87 DSP, = `main`'s 38,207 / 520 / 87; timing PASS, clk_mem 90.19 MHz at 100 °C, thin):
Letterbox 0:05:24, each line 15 → 20–21 rows tall, widths unchanged; Crop 0:06:30, 254 px wide.
✅ The maintainer's look on a CRT (2026-11-12): good in every aspect mode.

## 9b. SIF analog fill reuse (✅ HW-CONFIRMED 2026-08-24, PR #2)

The MPEG-1 SIF fill (`docs/mpeg1.md` §B.3) reuses this machinery wholesale:
`disp_hstretch` runs at 352→720 (or 256→720 with Crop stacked; both inside the §8b
RATIO CONTRACT, no module change), and `crt_ov_map`'s crop inverse serves the stretch
with `hcrop_x0=0` (emu now gates `ov_hcrop_mb` on `analog_crop` and derives
`ov_hextra = ov_hdst_w − ov_hsrc_w`). New in `crt_ov_map`: a `v2x_en` closed-form
post-map inverting the addrgen 2× line repeat (mode-2 vscale walk) —
progressive `min((y+1)>>1, v_src_max)`, interlaced parity-preserving, 0xFFF bar
sentinel preserved; it composes AFTER the letterbox inverse (the doubling happens
upstream of `disp_vscale`). Co-sim: `crt_ov_map_tb` T1d (352→720, 256→720) + T6
(v2x progressive / 480i / letterbox-composed). The mode-2 inverse formula is part of
the §9 EXACTNESS contract — change the addrgen walk and this map together.
**Note (2026-09-02): the §9a subtitle-context raw path deliberately EXEMPTS the SIF
fill** — `sp_map_en` ORs in `sif_hfill_eff | sif_v2x_eff`, so sub-720 discs keep the
full mapped query in every context (their SPU bitmaps are authored in SIF source
space; raw coordinates would render them quarter-screen).

## 10. Follow-ups

- ~~`disp_hstretch` 2-tap horizontal blend (Crop edge quality)~~ — **DONE, see §8b.**
- ✅ **Native 240p SHIPPED for SIF content (2026-09-14, `feature/native-240p`) — but NOT via
  this datapath, and the distinction matters.** SIF is *already* 240 lines, so it needed no
  downscale at all: the fix is to stop the 2× line repeat (`sif_v2x_eff & ~p240_eff`) and
  give it a 262/312-line progressive raster. `crt_ov_map`'s v2x inverse is gated by the same
  signal and returns to pass-through, so the §9 EXACTNESS contract is untouched — there is no
  new inverse to keep in step. See `docs/mpeg1.md` §B.3b.
  **What is still unbuilt is the line below: 240p for FULL-HEIGHT content**, which is the
  case that genuinely wants a ×2 vertical downscale + centre —
- Native 240p for 480-line content (a ×2 vertical downscale + centre) — reuses the `disp_vscale` blend datapath with
  a step of 2 instead of 4/3. ★ This is only the CONTENT half. The sync/rate half was rejected
  in 2026-08 on a premise that **expired with PR #63**, and the current position — what 240p
  actually needs, why 262 lines rather than an impossible exact-59.94 modeline, and what still
  wants verifying — is written up in `docs/mpeg1.md` §B.3a. Read that before re-deriving the
  old "no".
- Optional: blend `osd` as nearest in **`disp_vscale`** (crisper debug overlay text under
  Letterbox) — currently the overlay is blended like the picture. `disp_hstretch` already does
  this (§8b), so it is a 3-line back-port.
- The Letterbox bar offset already tracks `vertical_size` (72 lines for PAL 576), so it comes
  for free once the PAL 576i CRT modeline exists (`docs/crt_480i.md` §9); `crt_ov_map`'s
  `v_bar`/`v_band` inputs are already PAL-parameterized in emu.

## 11. The "half-line at the picture edge" report — NOT a core defect (2026-09-12)

Field report: in `Analog Aspect = Letterbox`, *"the bottom line only goes halfway across the
screen"*. Reported on several PAL discs, in **all three** aspect modes, on **HDMI as well as
analog**, and — decisively — **in VLC**.

**Verdict: the half-line is encoded on the disc.** Nothing in this fork produces it, and our
output matches a set-top player. Documented for users in
`site/content/reference/troubleshooting.md` ("A thin partial line across the top or bottom of
the picture"), `site/content/reference/compatibility.md` and `site/content/video/analog-crt.md`.

### What the content contains

12-bucket row averages of decoded frames, THE_OFFICE_UK_DISC1_PAL (720x576):

```
row0     0   0   0   0   0   1 188 187 183 130  41  80   <- black LEFT half, picture right
row1   204 214 209 144  68 145 148 147 143 121  15   8   <- normal
row574 171 116  83  73  36 138 148 131 144 125 113  99   <- normal
row575 162 106  78  69  14   0   0   0   0   0   0   0   <- picture LEFT, black right
```

A genuine half-line **at both ends of the same disc**: one field's first active line begins
part-way across, the other field's last active line ends part-way across — the two halves of
one line. Other measured examples: `LastBountyHunter` row 1 black across the left 427 px (with
row 0 fully black above it), `SpacePirates` row 1 across 553 px, `COWBOY_BEBOP` row 575 black
across the right ~499 px, `Walt Disney World Promo` row 575 black across the right ~58 % but
dim. Clean controls: `SUPERMAN_LAST_SON_OF_KRYPTON_PAL`, `big-buck-bunny-PAL`, `MEN_IN_BLACK`.

A television's overscan (a few percent per edge) normally swallows it. It became visible
because HDMI at 1:1 has none, and because **Letterbox lifts the picture's bottom edge 72 lines
up out of a CRT's overscan** — but a real player letterboxing 16:9 for a 4:3 set puts that line
at ~raster line 504 of 576, equally in view, and its scaler dilutes it to a 2/3-weight blend,
which is exactly what `disp_vscale` computes (`f = 171`) on the final line.

**Prevalence: a minority of discs, deliberately NOT quantified.** A library scan suggested
~4 % of decidable discs, but the detector went through four revisions and still disagreed with
itself on low-contrast material. The number is not trustworthy enough to publish and the manual
entry is qualitative.

### Disproved — do not re-derive these

- **Not a pipeline defect.** A displayed line can only end early via `pixel_rd_underflow`
  (`rtl/mpeg2/mixer.v:186-193`) or a DE overrun caused by the same starvation. Everything else
  is structurally incapable: a scan can only end on `last_mb && last_y`
  (`dvd/resample_addrgen.v:627`), so the addrgen cannot stop mid-line; line end is code-driven
  (`ROW_X_COL_LAST`), not counted; `disp_vscale` blends each output line in per-pixel lockstep
  with its incoming source line. The mixer's own note that *"underflow was confirmed ZERO on
  HW"* (`mixer.v:80-88`) is **corroborated** by this finding, not contradicted.
- **Not stream parameters.** SUPERMAN (clean) matches three affected discs on every measured
  one: 720x576, frame-coded pictures, `progressive_frame=0`, `rff=0`, `progressive_sequence=0`.
  The IFO `V_ATTR` is identical across all six discs compared — the "that is what the authoring
  tool wrote" trap (cf. `docs/film_24p_plan.md` §14).
- **Not bitrate or decode load.** Measured mux rate from pack SCR deltas: `big-buck-bunny-PAL`
  is the **highest** of the six at 8.4 Mbps and is clean; `COWBOY_BEBOP` shows it at 4.4. This
  also kills the tempting "PAL film decodes 25 % more macroblocks/s than NTSC film" framing.
- **Not PAL-specific.** `LastBountyHunter` and `SpacePirates` are NTSC 720x480.

### Measurement recipe, and four traps that cost real time

Demux the video PES from a title VOB, decode with
`ffmpeg -f mpeg -i - -pix_fmt gray -f rawvideo`, and compare each edge row against a reference
row further into the picture. The traps:

1. **The anomalous row is not always the outermost one.** `LastBountyHunter` has row 0 fully
   black and the half-line at row **1**. Using the adjacent row as the reference makes the
   defect invisible — the reference *was* the defect.
2. **Both orientations occur.** A top half-line is black-then-picture; a bottom one is
   picture-then-black. A test written for one misses the other.
3. **The reference row can itself be black at the extreme edge** (a few columns of picture
   margin), which terminates an edge-run walk at x=0. Skip columns where the reference carries
   no picture.
4. **Black is not always <= 16.** THE_OFFICE's suppressed region sits near 18-24; an absolute
   threshold produced a false negative on a disc known to be affected.

And an informativeness gate is mandatory: if the reference row is itself inside a black
letterbox bar the frame proves nothing. Without one, a concert disc with two black rows at the
bottom was flagged from three outlier frames — a false positive the maintainer caught by simply
opening it in VLC. Same shape as the film-evidence gate (`docs/film_24p_plan.md` §14).

### Unrelated latent bug found en route — ✅ FIXED 2026-10 (it became reachable with §13)

`disp_vscale` treats `ROW_1_COL_0` as a scan re-arm (`dvd/disp_vscale.sv:128`), but on the
**progressive FRAME** path the addrgen tags *both* of the first two lines as frame-tops
(`dvd/resample_addrgen.v:1274-1276`, via the `disp_y_sat` 0 -> 1 -> 2 walk). There it would
re-arm the Bresenham at source line 1: source line 0 discarded, **359** output lines instead of
360, and output line 1 carrying `ROW_X_COL_0` at `v_pos == disp_v_offset+1`, which `mixer.v:169`
explicitly excludes — one black line just under the top bar.

Not reachable from the Analog Aspect menu today: `disp_vscale_en = analog_letterbox` requires
`interlaced_eff`, which puts the addrgen on the FIELD path where exactly one frame-top code
exists per field. It **is** exercised by `bench/dvd/resample_chain_tb.sv`'s default progressive
`+vsmode=1` arm, where `TOL = 6` hides it (`hole = 1`, `nb_cnt = 359` vs `exp 360`). It becomes
live the moment `disp_vscale_en` is un-gated from `interlaced_eff` — i.e. the §4 roadmap item
"make a 4:3 HDMI output honor the same Fit/Letterbox/Crop setting". Fix at that point: ignore a
`ROW_1_COL_0` that arrives when the scan armed on the immediately preceding line.

**Fixed with §13, and the fix above was incomplete.** Ignoring the second code alone gives 360
lines but still tags output line 1 `ROW_X_COL_0`, and `mixer.v` refuses a `ROW_X_COL_0` line
start at `disp_v_offset+1` as well, so the black line stays. The fix copies
`dvd/field_blend.sv`'s convention, which already had to solve this:
- a `ROW_1_COL_0` directly after a `ROW_0_COL_0` line is the frame's line 1, not a scan start,
  on BOTH sides of the module: the input side (`in_prev_row0`, so route, mode and the sideband
  are decided once per scan) and the head side (`h_prev_row0`, so the Bresenham arms once);
- output line 1 of such a FRAME scan carries `ROW_1_COL_0`, as the source frame's did.

A field scan never pairs, so the field path is bit-identical: the output streams of
`disp_vscale_frame_tb` (field, Fit) and of `resample_chain_tb` (+crt / +il, vsmode 0/1/2)
were diffed against `main`'s module, byte for byte. Gate: `bench/dvd/run_vscale_frame.sh
--red` (golden blend values + position codes, NTSC/PAL, back-pressure, and a Letterbox toggle
landing between a frame's line 0 and line 1 — the case that tears without the INPUT-side half;
a Letterbox→Fit toggle cannot see it, Fit→Letterbox can). `resample_chain_tb +exact=1` now
scores the progressive band with no tolerance and per-line pixel counts; on `main`'s module
it reports the defect.

⚠ Also worth knowing before trusting that bench on edge behaviour: its geometry check is
`TOL = 6` on the line count, `hole` counts only **fully** black lines, and `hfill_ok` is a
frame-wide min/max. **A single partially drawn line is invisible to it.**

## 12. Menu permitted display mode — a 16:9 menu overrides Letterbox/Crop (2026-10-01, ✅ HW-CONFIRMED)

**Field request (maintainer):** a 16:9 disc menu shown on a 4:3 TV should be pan&scanned
even when the player is set to letterbox — the way a set-top box does it — so the menu
fills the screen instead of sitting small between bars.

**What a set-top player actually does.** Each domain's video attribute word (VMGM_V_ATR /
VTSM_V_ATR at IFO `0x100`, VTS_V_ATR at `0x200`) carries a *permitted display mode*
(libdvdread `video_attr_t.permitted_df`, bits 9:8 of the BE u16 = bits 1:0 of the high
byte). `dvdnav.h`: *"bit0 set = deny letterboxing, bit1 set = deny pan&scan"* — so 0 = both,
1 = pan&scan only, 2 = letterbox only, 3 = neither (wide only; libdvdread prints "not
specified"). Wide (a 16:9 TV) is always permitted. A 4:3 player set to Letterbox shows a
16:9 picture pan&scanned when letterbox is denied, and vice versa. The request was right
*conditionally*: the flag, not the player setting, decides — and it decides in both
directions. (libdvdnav itself ignores the field: SPRM14 is a constant `0x100` and its own
SPU selection always takes the wide byte. VLC's dvdread access does branch on it, for the
subpicture variant only.) Bit polarity is corroborated two ways: libdvdread's printer, and
the stream measurement below — df=1 menus carry a 540-px display window, df=2 menus mostly
do not.

**Measured (2026-10-01, 1,520 ISOs in the local library):**

| Domain, 16:9 | P&S only (df 1) | LB only (df 2) | both (df 0) |
|---|---|---|---|
| VMGM | **605** discs | 157 | 65 |
| VTSM | **952** discs (2,653 menus) | 372 discs (883) | 34 discs (56) |
| VTS (all) | 504 discs (1,082) | 1,101 discs (4,862) | 10 discs (37) |
| VTS (largest = main feature) | 1 | **935** | 4 |

So menus are overwhelmingly authored "pan&scan only" — and main features overwhelmingly
"letterbox only", which is why pan&scan "was not used for video playback": studios forbade
it and shipped separate 4:3 encodes instead.

**Refuted: dynamic pan vectors.** The request assumed the menus carry per-picture pan&scan
metadata. A scan of 133 16:9 menu VOBs (120 random discs) found the *static* part of the
mechanism and not the dynamic one: 100/102 df=1 menus carry `sequence_display_extension`
with `display_horizontal_size = 540` (the ¾ window), but every `picture_display_extension`
`frame_centre_horizontal_offset` is 0. The three non-zero hits (13056, −6127, 14723 in
1/16 px = 380–920 px) are impossible for a 720-wide frame and are false matches of the
raw-byte scan. **It is a centre crop**; the decoder still skips `picture_display_extension`
(`rtl/mpeg2/vld.v`, `EXT_PICTURE_DISPLAY`) and nothing here needs it.

**Decision (user, 2026-10-01): MENUS only, BOTH directions.**
- While a 16:9 menu is up (`menus_on & menu_active & menu_ar_wide_w`): df=1 turns a
  Letterbox (or Auto-on-16:9) choice into **Crop**; df=2 turns a Crop choice into
  **Letterbox** (157 VMGMs / 372 discs' VTSMs are letterbox-only, and cropping them can cut
  off edge buttons).
- Fit (the user has a 16:9 TV), df 0 and df 3 are never touched.
- Titles are **not** overridden: 935/940 main features deny pan&scan, so honouring the title
  flag would only turn a deliberate Crop into Letterbox on almost every film. A title
  resolves bit-identically to v0.8.0 (the gate checks it).

**Mechanism — one capture, one resolve, everything else follows.**
- `dvd/dvd_iso_reader.sv` `S_MENU_VATR` captures `menu_ar_df <= rbuf[0][1:0]` beside
  `menu_ar_wide`, for both the VMGM and VTSM arms, during the menu load (before
  `menu_active` asserts).
- `dvd/emu.sv` `analog_letterbox` / `analog_crop` gain the two swap terms
  (`menu_lb_to_crop`, `menu_crop_to_lb`) inside the existing `interlaced_eff & ~p240_eff`
  gate.
- Free from there: `disp_vscale_en` / `disp_hcrop_en` drive the decoder, `VIDEO_ARX/ARY`
  are 4:3 in **both** modes (so a title↔menu swap between Letterbox and Crop never re-inits
  the scaler), and `crt_ov_map` (§9) follows the same two enables, so the highlight tracks
  the cropped buttons.
- **Subpicture/highlight variant: deliberately unchanged.** Menus keep the WIDE
  `subp_control` byte and button group 1 and are composited in source space through the §9
  inverse map — geometrically the same as compositing the disc's pan&scan variant after the
  crop. Do not "fix" this by selecting the pan&scan byte/group for a cropped menu: that
  applies the transform twice (the fj#168 hardware lesson, `docs/dvd_nav.md`).

**Known limitations.**
- **Wherever Analog Aspect is in force** (`aa_live`): the interlaced raster, and since §13 an
  explicit Letterbox/Crop on Progressive (user decision 2026-10-04: the swap applies there
  too). Auto/Fit on Progressive leave menus alone, as before. HDMI shows the one raster, so
  it shows the crop too.
- The Crop window is 528 px, not the authored 540 (§1): a button drawn flush to the pan
  window's edge loses its outer ~6 px. Fixing it needs a non-macroblock column window in
  `resample_addrgen` — not done.
- The swap follows `menu_active`, so the picture straddling a title↔menu crossing could in
  principle show for a frame in the other geometry (as pressing Aspect live can). Watched
  live on the CRT (maintainer, 2026-10-01): the cropped menu → letterboxed movie switch on
  *28 Days Later* looked seamless.
- In-title menus (HLI in the title domain) are titles here and are not overridden.
- ~~SPRM14 is still the constant `0x0100`~~ — superseded by PR #154: SPRM14 follows
  Analog Aspect through `aa_live` (`docs/dvd_vm.md` "Player parameters").
- The override is silent: no OSD/HUD message says the menu forced Crop or Letterbox.

**Gate:** `bench/dvd/run_menu_panscan.sh [--red]` — `tools/check_menu_panscan_wiring.py`
evaluates the resolve's whole comb-definition closure out of `emu.sv` over all 1,024 input
points against a reference model (+ titles identical to v0.8.0, + the port and the
downstream seams), and `iso_reader_menu_tb` T2/T4 pin the capture (VTSM `0x4D` → 1, then
VMGM `0x4E` → 2). 8 mutation arms, each caught by its own assertion.

**HW (2026-10-01, rig, Interlaced, control arm = v0.8.0 through the same script):** *28 Days Later* (VTSM df=1) under Letterbox — v0.8.0 letterboxes the menu, the new build shows it full-height cropped, highlight on its button after a down-press (same authored position as the control), and Play Movie (VTS df=2) returns to letterbox. *MythBusters 2008-03* (df=2) under Crop — v0.8.0 crops off the episode list's left edge, the MYTHBUSTERS logo and the PLAY ALL box; the new build letterboxes it with everything visible.
Not separately exercised on HW: Auto (same `analog_want_lb` term as Letterbox, gated in sim), Fit and Progressive (resolve unchanged there; the gate proves it).

## 13. Explicit Letterbox/Crop on the Progressive raster (2026-10, ✅ HW-CONFIRMED, MERGED PR #155)

**Field need (maintainer, 2026-10-04).** Analog Aspect did nothing on Progressive: the gate was
`interlaced_eff`. Two kinds of user were stuck:
- a **31 kHz analog display** (`vga_scaler=0`: VGA CRT, 480p component on a 4:3 set) showed
  16:9 discs squeezed horizontally, with no fix at all;
- a **4:3 HDMI display** got ascal's letterbox for 16:9 content, but no Crop.

**Decisions (user):**
- **Auto on Progressive does NOT change** (2026-10-05): no in-raster correction, ascal
  follows `VIDEO_ARX/ARY`. Only an EXPLICIT Letterbox or Crop corrects. Fit on Progressive
  was already "no correction" and stays so. (The 2026-10-04 roadmap sketch had Auto
  letterboxing on `analog_want` rigs; rejected — Auto keeps meaning "the scaler decides" on
  Progressive.)
- **The interlaced raster is bit-for-bit unchanged.**
- **The B15 Aspect button is unchanged** (2026-10-04): it keeps cycling Aspect Ratio on
  Progressive, which is what an HDMI-only user needs; Letterbox/Crop are set in the OSD.
  (Gating the button on `aa_live` would also be circular — `aa_live` depends on the value
  the button would cycle.)
- **The 16:9 menu `permitted_df` swap (§12) applies on Progressive too** (2026-10-04),
  whenever Letterbox/Crop is chosen — one predicate for both rasters.
- **No option rename.** `Analog Aspect` keeps its name and its CONF_STR row (a CONF_STR edit
  re-rolls the seed for no functional gain); the manual explains that on Progressive only
  Letterbox and Crop act.

**Mechanism — one net (`dvd/emu.sv`):**
```verilog
wire aa_live = interlaced_eff | (aa_osd_sel == 2'd2) | (aa_osd_sel == 2'd3);
assign analog_letterbox = aa_live & ~sif_det_s2 & ( ...menu-swapped want_lb... );
assign analog_crop      = aa_live & ~sif_det_s2 & ( ...menu-swapped want_crop... );
player_regs_inst .aa_live (aa_live)
```
- Under Auto (sel 0) or Fit (sel 1) with `interlaced_eff = 0`, `aa_live = 0`: neither enable can
  rise, so Auto-on-16:9 (`analog_want_lb`'s sel-0 term) never reaches Progressive.
- With `interlaced_eff = 1`, `aa_live = 1` and `~sif_det_s2` is exactly the old `~p240_eff`
  (`p240_eff = interlaced_eff & sif_det_s2`), so the interlaced resolve is unchanged.
- **SPRM14 follows the same net** (`player_regs`, PR #154), so the TV shape a disc reads
  matches the picture: Progressive Auto/Fit → `0x0C00` (16:9), Letterbox → `0x0200` (4:3
  letterbox), Crop → `0x0100` (4:3 pan&scan). An MGM-style disc (HARTSWAR_169) therefore
  picks its 4:3 intro under Progressive + Letterbox.
- **Everything downstream follows the two enables unchanged:** `disp_vscale_en` /
  `disp_hcrop_en` (decoder), `VIDEO_ARX/ARY` forced 4:3 (HDMI geometry), `ov_hcrop_mb` and
  `crt_ov_map`'s `letterbox_en`/`crop_en` (overlay inverse, §9).
- **`sp_disp_mode` was already ungated** (it reads `aa_osd_sel`), so a saved Letterbox/Crop
  on Progressive already picked the letterbox/pan&scan subtitle variant over an uncorrected
  wide picture. The picture now matches it.

**The SIF guard (`~sif_det_s2`, not `~p240_eff`).** `crt_ov_map`'s bar geometry is handed
literals authored for a full-height frame (`v_bar` 60/72, `v_band` 360/432). On Progressive a
VCD is a 352×240 window, so Letterbox there would draw a 180-line band but map subtitles and
highlights into 360-line geometry. SIF content is 4:3 anyway, so it is never corrected, on
either raster — the guard names the CONTENT it protects rather than the raster. SVCD (480
lines) is not SIF-height and keeps Letterbox/Crop. Making the bars `vsz_eff`-derived would
lift the guard (and fix forced-PAL over 480-line content); not done, `docs/roadmap.md`.
⚠ SPRM14 still follows `aa_live` on a SIF title (a disc reading SPRM14 on a VCD is not a case
that exists; pre-existing on the interlaced raster).

**What un-gating made reachable, and how each was settled:**
- **`disp_vscale` on the progressive FRAME path** — the §11 latent defect (359 lines, a black
  line under the top bar). Fixed; §11.
- **Deinterlace = Bob/Blend followed by Letterbox.** `field_blend` runs ahead of `disp_vscale`
  (`mpeg2video.v`), and emits exactly the ROW_0/ROW_1/ROW_X convention the fixed module
  expects. The emu comment "Blend is inert on Letterbox" was only true because the two gates
  excluded each other; corrected. Accepted as an explicit user choice on both settings.
- **The pause field still** cannot reach Progressive: `still_want` requires the addrgen's
  `interlaced` (field) input, so `scan_half` is always 0 there.
- **Film 24p** is fine by construction: `disp_vscale` has no raster-timing input, the bars are
  the mixer holding the frame top until `disp_v_offset`.
- **`crt_ov_map` horizontal lag.** At `CE_PIXEL = 1` the mapper's one-clock lag is a whole
  pixel, not the half pixel its header assumed — a possible ~1 px offset of mapped menu
  highlights under Crop on Progressive. Checked on HW (below).
- **Display read rate.** Letterbox reads all 480 source lines in ~420 raster line-times, so
  during the band the display re-reads DDR3 at ~4/3 of Fit's rate — the decode-pacing
  contention of `docs/decode_pacing.md`. Interlaced Letterbox has the same ratio per field.
  Measured on HW (below); confined to users who pick Letterbox.
- **Scaler re-init.** Choosing Letterbox/Crop flips `VIDEO_ARX/ARY` to 4:3 — one scaler
  re-init on an explicit change. Nothing flips it unprompted: `aa_osd_sel` moves only on an
  OSD edit or B15 (which does not touch Analog Aspect on Progressive), and the menu swap moves
  only between the two 4:3 modes.
- ⚠ **A 16:9 HDMI display under explicit Letterbox** gets bars on all four sides (the raster is
  4:3-true and ascal pillarboxes it). That is what Letterbox means; the manual says to leave a
  widescreen display on Auto.

**Gates:**
- `bench/dvd/run_prog_aspect.sh --red` — `tools/check_prog_aspect_wiring.py` evaluates the
  resolve over all 1,024 input points: [1] interlaced identical to `main` @ 4da0adc (frozen),
  [2] Auto/Fit never correct on Progressive, [3] explicit Letterbox/Crop on Progressive =
  the interlaced resolve, [4] SIF never corrected, [5] `aa_live`'s definition/declaration/
  truth table and that `player_regs` reads it, [6] B15 unchanged, [7] ARX/ARY follow. Plus
  `player_regs_tb` [P5] (the Progressive SPRM14 profiles) and `run_vscale_frame.sh`. Ten
  mutations, each caught by its own arm (M1 = "Auto now corrects on Progressive"; M2 = Fit
  added to `aa_live`, output-equivalent today and so caught only by [5]'s truth table).
- RED on `main` (shown once, by hand — a `git show main:` arm rots at merge): `[3] Letterbox/
  Crop do nothing on Progressive (128 points)` plus the `[5]` lockstep checks.
- Re-anchored: `check_p240_wiring.py` / `run_p240.sh` M9, `check_menu_panscan_wiring.py`
  (FREE gains `sif_det_s2`; the title check covers the interlaced raster; new M7),
  `check_player_regs_wiring.py`'s mutation anchor.

**HW (round 1, 2026-10-05, against the playerregs control; detail in `docs/status_log.md`):**
- **Progressive Letterbox:** 360 lines at rows 60–419, no black line under the bar.
- **Progressive Crop:** a real centre crop (correlation 0.994 against the stretched Fit
  centre).
- **Progressive Auto and Fit:** unchanged.
- **Interlaced:** unchanged.
- **HARTSWAR_169:** VTS 4 under Progressive Letterbox/Crop, VTS 3 under Auto/Fit.

**HW round 2 (2026-10-05):**
- **Film 24p On + Letterbox:** exactly ¾, centred, no hole.
- **Bob or Blend + Letterbox:** 360 lines, no hole.
- **A VCD:** uncorrected (frames identical to Fit).
- **Menus:** the permitted_df swap works on Progressive in both directions, and the
  highlights sit on their buttons. Under Crop they measure **+1.3 px** right of the crop
  mapping: the predicted `CE_PIXEL = 1` lag, invisible on a 41-px icon, and accepted.
  Fixing it would mean a progressive-only `SP_QX_ADJ`-style trim for the mapped context.
- **Subtitles under Letterbox:** drawn crisp at their authored position.

- **PAL 576 Letterbox:** 430 lines under the 72-line bar.
- **Decode pacing:** 0 lates and 0 drops in every Letterbox and Crop cell on ROGER,
  THE_OFFICE_UK and Thayer's Quest (`pacing_matrix.py --aspect`), so the ~4/3 display
  read rate costs nothing measurable.

- **The real analog path** (Progressive 480p on the pins → a RetroTINK → capture), one
  paused frame:
  - Fit shows the anamorphic squeeze.
  - Letterbox is 540/720 lines with bars (0.898 against the ¾-scaled Fit).
  - Crop is full-height and stretched.

Numbers are in `docs/status_log.md`.
