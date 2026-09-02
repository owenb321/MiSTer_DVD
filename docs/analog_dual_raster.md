# Dual-Raster Analog Output — CRT 480i/576i from MiSTer.ini alone

**★ STATUS UPDATE 2026-09-02 (branch `feature/video-output-consolidation`): the DERIVE
(weave) modes are REMOVED — fieldpass is now the ONLY analog delivery, under the single
`O[10:9] Video Output = Auto/Interlaced/Progressive` control (`Interlaced` = the old
Native Fields; `Auto` = the ini rule below resolving to Interlaced/Progressive; the old
4-value `O[27:26] Analog Out` enum and `O[10:9] Interlaced Out` are gone, config layout
bumped to `v,2`).** Why reversed (this doc's caveat 2 was the decisive evidence): two
field reports — the derive path's pairing wobble seen in the wild ("extremely wobbly,
not how interlace normally looks"), and the Native Fields post-seek "super aliased /
toggle 3-4 times" defect, root-caused as a separate field-parity re-engage coin flip and
FIXED (`docs/field_parity.md`). With fieldpass immune to caveat 2 by construction and the
parity corrector closing the re-engage hole, the derive machinery's only remaining value
was CRT-480i-plus-progressive-HDMI simultaneity, which the maintainer chose to drop
(pick-your-output). `re_interlace.sv` keeps only the fieldpass timing (PERIOD_FP_*/
SKEW_FP); the `fieldpass` port, the derive PERIOD/SKEW constants and the derive arming
are deleted; `analog_eff`/`il_eff` collapsed into one `interlaced_eff`. The raster
generator, phase lock, BRAM, CC injection and `VGA2_*` plumbing below all still ship.
The rest of this doc is kept as design history; "caveat 2" is CLOSED.

*(Historical status:)* ✅ HW-CONFIRMED + MERGED (PR fj#146, 2026-07-30). User-confirmed working on real
hardware: the analog output engages from MiSTer.ini alone (no OSD step) with HDMI staying
simultaneously progressive. Sim-verified: `bench/dvd/re_interlace_tb.sv` green (NTSC + PAL +
re-lock + film-reject), all display-path regressions green. Supersedes the O[14] whole-core
CRT mode (`docs/crt_480i.md`, kept as history — the syncgen N64 model it documents still
ships and is what this feature reuses).

**Open sub-items not specifically re-verified by the HW confirmation above** (see "Known
caveats" below and the checklist): the exact PAL 576i timing numbers (312/313, halfline 432,
vsync 292..295) are still sim-derived by analogy rather than HW-measured.

**★ UPDATE 2026-08-22 — `Analog Out = Native Fields` (field passthrough) SHIPPED,
✅ HW-CONFIRMED (core claim).** User A/B'd `Auto` (derive) vs `Native Fields` on
`ROGER_WATERS_IN_THE_FLESH` — a disc MEASURED video-sourced (`progressive_frame = 0.0 %`,
`tools/video_cadence_census.py`) rather than assumed — and the fields output is
**noticeably smoother**. A 50-minute MiB run held A/V sync. That is the feature's actual
claim: it was tested on content where the derive path is *supposed* to be worse, against
the derive path, not in isolation. Still open on HW (see the checklist): overlay width in
this mode, Letterbox, PAL 576i, and the other-mode regressions. The field-pairing caveat turned out to be materially worse than documented (it is
re-randomised several times a SECOND, not "until the next slip" — see caveat 2 below), which
also rules out the obvious phase-alignment fix. The parked field-passthrough follow-up is now
implemented as a fourth `Analog Out` mode and is the structural fix. See §"Native Fields".

## What the user gets

The analog CRT output now works **exactly like any other MiSTer core**: set the
standard `MiSTer.ini` options and play —

```ini
vga_scaler=0        ; (the default) native video on the analog pins
composite_sync=1    ; (or ypbpr=1 / vga_sog=1, per cable)
```

Nothing to set in the OSD. HDMI works **simultaneously at full progressive
quality** — the two outputs are independent rasters.

## Architecture

The core emits TWO rasters at once:

1. **Main raster** (unchanged): progressive 720×480p/576p @ 27 MHz CE=1 (or the
   Film-24p 23.976/25 Hz raster, or the O[10:9] HDMI-fields raster). Feeds
   ascal → HDMI, and the scaler-VGA path (`vga_scaler=1`). HDMI quality never
   changes because a CRT is connected.
2. **Analog raster** (new): native 15 kHz 2:1 interlaced — NTSC 858×262/263
   (half-line 429), PAL 864×312/313 (half-line 432) — derived from the main
   raster by `dvd/re_interlace.sv` and presented on new `emu` ports `VGA2_*`.
   `sys/sys_top.v` muxes the **direct analog chain** (scanlines → vga_osd →
   csync → yc → vga_out → pins, including the `direct_video` tap) onto it when
   `VGA2_EN=1`. The framework's existing `vga_scaler` ini mux then picks
   scaler-vs-native on the physical pins — stock behavior.

`VGA_SCALER` is driven **0 always** (it used to be forced `~crt_eff`, which ORed
into `sys_top`'s `vga_scaler = cfg[2] | vga_force_scaler` and made
`vga_scaler=0` in the ini unobservable — the whole reason the old CRT mode
needed an OSD step).

### Engagement rule (dvd/emu.sv)

```
analog_want = ((ini_csync | ini_ypbpr | ini_sog) & ~ini_vga_scaler & ~forced_scandoubler)
            | direct_video
analog_eff  = (analog_mode == Interlaced) | ((analog_mode == Auto) & analog_want)
```

- The `ini_*` bits are new **additive exports from `sys/hps_io.sv`**
  (cfg[2]/[3]/[5]/[9], latched from the HPS cmd-0x01 word at core boot — they are
  session-static, so `analog_eff` never flips mid-title on its own).
- `direct_video` (cfg[10], already exported) is included because the
  direct-video output taps the muxed analog chain in sys_top — an HDMI-DAC→CRT
  user gets the true half-line 480i for free. (DACs are not HDMI receivers; the
  old ff01ac8 "receiver hunts on the half-line" issue doesn't apply, and normal
  HDMI never sees the half-line because ascal re-times.)
- `O[27:26] Analog Out` (default **Auto**): `Interlaced` forces the raster on
  (15 kHz RGBHV rigs that set none of the ini bits); `Progressive` forces it off
  (component/VGA displays that want 480p/576p, and the dev A/B switch — the
  analog pins then carry the main progressive raster through the stock
  bit-identical path).

### The re-interlacer (dvd/re_interlace.sv)

Full derivation in the module header. Summary:

- **Phase lock by construction**: one interlaced line = 858 dots @ 13.5 MHz =
  1716 clk27 = exactly 2 progressive lines; two fields (262+263 / 312+313) =
  exactly 2 main frames (900 900 / 1 080 000 clk27). Locked once at a main frame
  top, it never drifts. Field A (even source lines) shows frame N, field B (odd
  lines) frame N+1.
- **Arming skew**: field B's content scan starts one main line EARLY relative to
  its source frame top, so the release skew must sit in **(1716, 1994) clk27**;
  `SKEW = 1848` centers it. The TB's pixel-exact content check (per-field source
  frame tags) fails outside the window — that's the proof.
- **4-line sync-read BRAM** (4096×24, 1024 stride). A 2-line ping-pong is NOT
  enough: the reader's 2-line-time window spans two writer lines.
- **Raster generator = a second `sync_gen` instance** (rtl/mpeg2/syncgen.v) with
  the HW-proven N64-model half-line machinery (PR fj#65), fed the byte-identical
  NTSC values of the retired CRT modeline branch; PAL 576i (312/313, halfline
  432, vsync 292..295) is derived by analogy — **⚠ needs HW confirmation**.
- **Health check by PERIOD, not coordinates**: consecutive main-frame tops must
  be exactly 450450 (NTSC) / 540000 (PAL) clk27 apart. Film-24p (1313-line
  frames), the HDMI-fields pixrep raster, or a mid-walk transient all fail the
  check → the module blanks and re-locks (<2 frames) when the standard raster
  returns. `pal`/`enable` changes and a frame-top timeout also drop the lock.
- Taps the **registered `vga_*_q` output stage** — subtitles, menus, HLI
  highlights, and the transport HUD are all composed upstream, so they appear on
  both outputs automatically, and the overlay layer now always composes against
  a progressive raster (`spu_decode`/`crt_ov_map` `.interlaced` are tied 0).

### Precedence with the other raster modes

- **Film 24p/25p** (`P1O[25:24]`): the 23.976/25 Hz raster cannot feed the
  re-interlacer (a 59.94-fields output from a 23.976 source needs a frame store,
  not a line buffer). `filmp_eff = film_want & ~analog_eff` — an analog TV in
  the ini suppresses the film raster; HDMI falls back to the in-core 3:2 at
  59.94p (today's default quality).
- **Interlaced Out** (`O[10:9]`, HDMI native fields): the derive modes force it
  off while analog is active (`il_eff = analog_fields | (il_want & ~filmp_eff &
  ~analog_eff)`). The weave frames do contain both fields, so the CRT gets true
  480i *content* — but only the field PAIRING decides whether the viewer sees a
  coherent picture, and that pairing is not guaranteed (caveat 2). `Analog Out =
  Native Fields` inverts the relationship: it forces `il_eff` ON and the
  re-interlacer re-times authored fields 1:1. See §"Native Fields".
- **Analog Aspect** (`O[4:3]`, was "CRT Aspect"): Letterbox/Crop rescale the
  video **upstream in the shared raster** (disp_vscale/disp_hstretch), so under
  dual raster HDMI shows the letterbox too. Accepted trade-off; `VIDEO_ARX/ARY`
  are forced 4:3 while active so ascal doesn't re-stretch the letterboxed image.

## Native Fields (`Analog Out = Native Fields`, 2026-08-22)

The structural fix for caveat 2. Instead of deriving fields from a woven
progressive frame, put the decoder in **native-fields mode** and let the
re-interlacer re-time the disc's **authored** fields 1:1.

```
il_eff = analog_fields | (il_want & ~filmp_eff & ~analog_eff)
```

**Why it is immune.** `resample_addrgen` emits `TOP`/`BOTTOM` field images ordered
by `top_field_first`, with the true rff 3:2 field cadence (`show_next_ilace`). Every
displayed refresh is then one genuine field of exactly one picture — there is no
"pairing" left to get wrong — and a late re-scans a field pair (+2 refreshes, even),
so governor churn is parity-neutral by construction.

**The re-interlacer degenerates to a re-timer** (`fieldpass`):

- **Period check** `900900` (NTSC) / `1080000` (PAL) clk27 — the *same* total dots
  per frame as the progressive raster, redistributed as two pixel-repeated fields.
  `frame_top` still pulses once per frame (`v_pos = {v_cntr, ~odd_field}` is 0 only
  when `v_cntr==0` **and** `odd_field==1`).
- **Write decimation**: the source carries each pixel twice (pixel repetition), so
  the write port keeps the even dot and indexes `in_hpos>>1`. The line buffer holds
  720 native pixels per line in both modes; the read port is untouched.
- **`SKEW_FP = 858`**. Source and local rasters have **identical** line and field
  structure (both alternate 262/263 lines × 1716 clk27), so every source pixel is
  read a *constant* 858 clk27 after it is written. Window is (0, 1994); 858 centres
  it. Bounds and derivation are in the module header.

**★ The main raster does NOT need a half-line.** It was not obvious a priori — the
source samples vsync at dot 0 in both fields (no half-line; HDMI uses `VGA_F1`
instead), so one might expect the CRT to inherit a line-paired, 240p-looking raster.
It does not: our **local** `sync_gen` supplies the half-line, and because the source's
field durations already alternate 262/263 the two rasters stay line-for-line locked.
This matters because putting a half-line on the main raster would expose HDMI to the
`ff01ac8` receiver-hunting issue for no gain. Proven pixel-exactly in sim
(`re_interlace_tb` [6]/[7]), not assumed.

**Overlay prerequisite (shipped with it).** The interlaced modeline uses pixel
repetition, so the raster is ~1440 active while every overlay authors its geometry
720-wide — subtitles, menu button art, HLI highlights, the HUD and the seek bar all
rendered into the **left half**. Vertically, `spu_decode`/`crt_ov_map` had
`.interlaced` tied to `1'b0`, so their (already-implemented) +2 field-line walk never
engaged. Both fixed; progressive stays bit-identical. This also closes the
long-standing HDMI-480i overlay follow-up in `docs/interlaced_auto.md`.

**Trade-off (why it is opt-in).** The *main* raster becomes interlaced, so HDMI drops
to 480i via ascal bob/weave for the session — and ascal is not cadence-aware, so film
regresses on HDMI. Every other `Analog Out` mode is bit-identical to before.
`Analog Out` is an OSD bit, so changing it mid-title toggles `il_eff` and fires the
full seek-equivalent `il_switch` flush: **set it before loading a disc.**

Bonus: because the decoder is back on the field path, `disp_vscale`'s Letterbox blend
regains its same-parity premise in this mode (see the ⚠ note in `dvd/disp_vscale.sv`).

## Known caveats / follow-ups

1. **PAL 576i numbers are sim-derived** (312/313, halfline 432, vsync 292..295 —
   by analogy with the HW-proven NTSC set). HW gate: PAL disc → CRT locks 576i
   @ 50 Hz, active region uncropped.
2. **Field pairing on true-interlaced content — ✅ FIXED by `Native Fields`
   (2026-08-22); still applies to the Auto/Interlaced derive modes.** The
   original wording ("a governor drop/late can land the pairing swapped *until
   the next slip*") understated it. Measured mechanism:
   - a governor **late** holds the picture one extra refresh. On the progressive
     path that re-scans one `FRAME` image = **+1 refresh, ODD ⇒ the pairing
     parity FLIPS**; on the field path it re-scans a FIELD PAIR = +2, even
     (`dvd/resample_addrgen.v`, the `late_pair`/`late_ext` block);
   - **drops are parity-neutral** (a dropped picture is never displayed);
   - lates run at **~4/s on healthy film** — "the decoder missing ~17 % of
     deadlines on easy content" (`docs/lipsync_pickup.md`).

   So the pairing is scrambled ~4×/s. **This is why phase-aligning the
   re-interlacer to the decoder's picture flip was rejected**: an alignment would
   survive ~250 ms, and re-arming drops `sg_rst_n`, which resets the second
   `sync_gen` and blanks the CRT's H/V sync — doing that 4×/s is far worse than
   the combing. Effect by content: **film barely cares** (each emitted field
   still lies wholly within one picture either way; only dominance alternates),
   **true 29.97i video is where it shows** as combing on motion.
3. **Interlaced Out while analog active**: the derive modes still force it off
   (the re-interlacer needs the progressive raster). `Native Fields` is the
   supported way to get native fields with an analog TV configured.
4. **No equalization pulses** (unchanged from the old CRT mode): the framework
   `csync` module XORs H/V with hsync-rate serration only. Fine on the tested
   sets; a picky CRT may hunt — the fix would be pre/post-eq at 2× line rate in
   `csync`.
5. `status[14]` (the old `O[14] CRT 480i Out`) is left **dead/reserved for one
   release** so stale per-core saved status can't re-arm anything.
6. **Sub-D1 sources (2026-08-24 update).** `re_interlace` is a 720-wide re-timer:
   its 4-line BRAM is only written inside the main raster's DE window, so a
   narrower/shorter DE window leaves stale columns right of the picture and a
   4-line smear below it. **MPEG-1 SIF (352×240/352×288) is now FIXED by the
   in-core SIF analog fill** (`docs/mpeg1.md` §B.3, ✅ HW-CONFIRMED 2026-08-24,
   PR #2): while
   `analog_eff` is high the decoder's display path stretches 352→720
   (`disp_hstretch`) and line-doubles 240→480 / 288→576 (addrgen vscale mode 2),
   and the syncgen opens the full active region — the re-interlacer then needs no
   change. HDMI trade-off while analog is engaged: ascal sees the in-core-scaled
   720×480 frame instead of the raw 352×240 (same class as Letterbox/Crop).
   Wider sub-D1 MPEG-2 (704/544) is NOT filled (user scope decision) — thin
   stale columns remain there; extending is one predicate away.

## HW test checklist

- [ ] HDMI-only rig (no analog ini config): everything bit-identical to the
      previous release (VGA2_EN=0 → stock path; CE_PIXEL now constant 1).
- [ ] `vga_scaler=0` + `composite_sync=1`, OSD untouched: CRT locks 480i (movie
      + menus + subtitles + HUD visible), HDMI shows the same content
      progressively at the same time.
- [ ] Film disc (MiB / T2): film raster suppressed (HDMI stays 59.94p), lips in
      sync on both outputs.
- [ ] PAL disc: CRT locks 576i @ 50 Hz (⚠ sim-derived numbers).
- [ ] Analog Aspect Letterbox with a 16:9 disc: correct on CRT; HDMI shows the
      letterbox at 4:3 ARX/ARY (no double-squeeze).
- [ ] `Analog Out = Progressive` on a 31 kHz VGA monitor: stock 480p picture.
- [x] **`Analog Out = Native Fields`** (set before loading), NTSC **video-sourced**
      disc: smooth 60-field motion, no combing on motion, and it stays clean through a
      high-motion / heavy-decode scene (the derive modes visibly come and go there as
      the pairing parity flips). **Use `ROGER_WATERS_IN_THE_FLESH.iso`** — measured
      `progressive_frame = 0.0 %` across all 12 sample windows by
      `tools/video_cadence_census.py`, so `det_video` sits engaged, and a concert has
      the sustained motion that makes the artifact visible. `DMDC8200_THREE_TENORS.iso`
      is an equally clean second NTSC candidate.
      ⛔ Do **not** gate on a film disc (MiB / Matrix / T2 / Akira all measure
      `progressive_frame = 100 %`) — on film the derive path is nearly as good, so a
      pass there proves nothing about this feature.
- [x] Native Fields, film disc: correct 3:2 field cadence, lips in sync — **50-minute MiB
      run held sync**. This is the field-path governor ledger under the rff 3:2 cadence
      (3 field-scans per rff picture, a late costing an even +2 refreshes), i.e. the
      highest-consequence risk given the lip-sync history.
- [x] Native Fields: subtitles, disc-menu highlights, transport HUD and seek bar are
      **full width**, not squished into the left half — confirmed on MiB.
- [~] Native Fields, PAL — **PARTIALLY covered.** `THE_OFFICE_UK_DISC1_PAL.iso` (the only
      PAL disc in the library measured video-sourced, `progressive_frame = 0.0 %`) was run
      **in Native Fields mode** and plays correctly on **HDMI** — so the PAL *decoder*
      field path (addrgen emitting PAL TOP/BOTTOM field images, the 50 Hz field cadence)
      and the overlay geometry under a PAL pixrep raster are both confirmed.
      The **analog PAL 576i raster itself is still unverified** — no PAL CRT available.
      `re_interlace`'s PAL fieldpass leg is sim-proven (`re_interlace_tb` [7]: period
      1,080,000 clk27, 288 active lines/field, pixel-exact content), but the ⚠ sim-derived
      PAL timing numbers (312/313, halfline 432, vsync 292..295) are inherited from
      PR fj#146 and **STAY OPEN** — this does not close that caveat.
- [x] **Native Fields + Analog Aspect Letterbox on a 16:9 disc** — covered implicitly by
      the 50-minute MiB run: MiB's title VTS is 16:9 anamorphic (`V_ATR=0x4e80`,
      aspect_ratio=3), so the default `Analog Aspect = Auto` had `analog_letterbox`
      ACTIVE throughout (assumes the aspect setting was left at Auto). Sim agrees:
      `resample_chain_tb +crt=1 +vsmode=1` is 12/12 with zero geometry failures, and
      `crt_ov_map_tb` T2/T3/T5 guard the module level (real `disp_vscale` field path,
      letterbox inverse across two 480i fields with per-field re-arm, `spu_decode`
      row-base under the field-mapped walk). Note this mode should be BETTER than the
      derive modes, not worse: under derive the Letterbox blend mixes adjacent lines of a
      WOVEN frame (cross-fading two time instants); on the field path the addrgen emits
      contiguous same-parity lines, restoring the premise the module was designed around.
- [x] `Analog Out = Auto / Interlaced / Progressive` reproduce previous behaviour —
      confirmed. Worth having checked: `analog_eff`/`il_eff` were re-expressed, so every
      analog mode was touched, not only the new one.
- [ ] HDMI in Native Fields: expected regression to 480i via ascal (`O11` Bob/Weave).
- [x] `Interlaced Out = On` on HDMI (no analog rig): overlays now full width — confirmed.
      Closes the long-standing follow-up in `docs/interlaced_auto.md`; this is the
      standalone half of the change (valuable with no CRT attached).
- [ ] `Analog Out = Interlaced` with no csync/ypbpr/sog set (RGBHV force case).
- [ ] `direct_video=1` through an HDMI DAC: 15 kHz 480i on the DAC output.
- [ ] `vga_scaler=1`: scaler output on the VGA pins (ini finally respected).

---

## Line-21 closed captions on this raster

`dvd/re_interlace.sv` also instantiates `dvd/cc_line21.sv`, which writes the disc's
EIA-608 caption bytes into **line 21** of this raster's vertical blanking interval so a
television's own decoder can render them (NTSC only). The line number and field parity are
read straight out of `sg_vpos` — in interlaced mode `v_pos = {v_cntr[10:0], ~odd_field}` —
so `syncgen.v` needed no change, and the injection is gated on `~sg_pixel_en` so it can
never reach active video.

Why it lives here rather than in `emu.sv`: line 21's position is a property of *this*
modeline (15th line after vsync end = `v_cntr` 261 = `p_vlen`), and nothing outside should
have to re-derive it. Full design, measurements and the HW gate: `docs/closed_captions.md`.
