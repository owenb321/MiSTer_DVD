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

Both corrections are the exact ×¾ (a 16:9 image in a 4:3 frame has scale factor
(4/3)/(16/9)=¾). Letterbox does it vertically (bars = ⅛ of the height each: 60 lines NTSC /
72 PAL). Crop does it horizontally (show the centre ¾ of the width, stretched back to full
width — full vertical resolution, sides ⅛ cropped each).

**Why Crop is HORIZONTAL, not vertical:** to keep *full vertical resolution* (all 480 source
lines, no vertical scaling ⇒ no vertical aliasing) while filling the 4:3 screen with 16:9
content, the only correct operation is a horizontal pan-scan (crop the sides). A vertical
crop+upscale would throw away vertical resolution and over-stretch the (already tall)
anamorphic image — the earlier "Zoom" attempt did exactly that and was wrong; it is replaced
by this horizontal Crop. Auto never selects Crop (it picks Letterbox for 16:9 / Fit for 4:3);
Crop is a manual choice.

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

**Planned:** make a 4:3 HDMI output honor the same Fit/Letterbox/Crop setting (roadmap item
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
subtitles sit inside the letterboxed picture at the right height; menu highlight boxes sit
ON their buttons (T2/Matrix menus); (b) Crop: highlight tracks the stretched buttons,
overlay clipped at the crop edges; (c) Fit + HDMI: unchanged (pass-through); (d) CRT Auto
on an anamorphic menu now letterboxes (matches HDMI). Release build gated green:
clk_dec 91.24/87.58 MHz, `releases/DVD_crtovalign_20260711_0009.rbf`.

## 10. Follow-ups

- ~~`disp_hstretch` 2-tap horizontal blend (Crop edge quality)~~ — **DONE, see §8b.**
- Native 240p (a ×2 vertical downscale + centre) — reuses the `disp_vscale` blend datapath with
  a step of 2 instead of 4/3.
- Optional: blend `osd` as nearest in **`disp_vscale`** (crisper debug overlay text under
  Letterbox) — currently the overlay is blended like the picture. `disp_hstretch` already does
  this (§8b), so it is a 3-line back-port.
- The Letterbox bar offset already tracks `vertical_size` (72 lines for PAL 576), so it comes
  for free once the PAL 576i CRT modeline exists (`docs/crt_480i.md` §9); `crt_ov_map`'s
  `v_bar`/`v_band` inputs are already PAL-parameterized in emu.
