# Line-21 closed captions (EIA-608) on DVD — measurement + feasibility

**Status: ✅ HW-CONFIRMED 2026-08-26 (round 5, user report — C1 captions complete and
readable on MiB and The Matrix, real TV via the YC active encoder board over composite).**
Implemented as line-21 re-insertion on the analog raster. The core now strips the disc's EIA-608 caption bytes out of the
MPEG-2 video stream and re-modulates them onto **line 21 of the analog output**, exactly
as a real DVD player does, so the *television's* own caption decoder renders them. There
is deliberately **no on-screen character generator** (§4 explains why that option was
dropped on fit grounds; §5 records what it would have cost if it is ever wanted).

Shipping in this change:
- `tools/cc_scan.py` + `tools/dvd_census.py --captions` — the census half (§2, §3)
- `rtl/mpeg2/vld.v` user_data snoop — extraction (§4.1), sim-proven byte-exact on real
  disc bytes
- `dvd/cc_line21.sv` — field-rate pacing + the EIA-608 waveform (§4.2, §4.3)
- `dvd/re_interlace.sv` — line-21 injection into the analog raster (§4.4)
- `P1O[14] Line-21 CC` (On/Off, default On, debug page), NTSC + analog only

§6 is the five-round hardware history: one wiring bug in the analog chain (DE gate), one
diagnosis inverted and re-inverted (field mapping), one editing accident (undriven net),
and one spec gap (square edges → parity drops). All found by exactly the round order the
doc prescribed; the CC Test Line diagnostic and the measurement-first rule earned their
keep.

This supersedes the previous stance in `docs/test_disc_shopping_list.md` #15 ("normally
decoded by the TV, not the DVD core — likely out of scope"). That was half right: it *is*
normally decoded by the TV, which turns out to be an argument for one of the two designs
below, not an argument that the data is unreachable.

---

## 0. WHERE THIS STANDS — read first

**The feature is code-complete and sim-verified, rebased onto the post-0.1c main, and
waiting on a hardware round.** Round 1 on hardware found two real bugs, both fixed (§6).

### The build blocker that parked this is resolved

Captions were parked because the netlist change re-rolled the fitter seed lottery and the
build landed at **clk_dec 67 MHz against the 86 MHz gate** (which pixellates). The worst
paths were all pre-existing `framestore` / `mem_request_fifo` / `resample` infrastructure
with no caption logic in the top 20 — the documented congestion lottery
(`quartus-build-flaky-routing`, the `DVD.qsf` seed ledger), not anything captions caused.
The agreed fix was to let an area-reclaim pass land first, since any netlist change
re-rolls the seed and sweeping beforehand would mean sweeping twice.

That landed in PRs #9–#11 (dead mpeg2fpga OSD tie-off, `dvd_vm` shared `eval_reg` muxes).
Baseline when captions was parked vs. main today:

| | parked (2026-08-25) | main today |
|---|---|---|
| ALM | 40,973 (98 %) | **39,117 (93 %)** |
| RAM (M10K) | 504 (91 %) | **501 (91 %)** |
| DSP | 100 (89 %) | **92 (82 %)** |

**⚠ But do not read that as an easy fit.** The idle-logo rounds spent much of the ALM gain
back (its ROM grew to 256×64 = 4 M10K), M10K is unchanged at 91 %, and the `DVD.qsf` ledger
records the most recent netlist going badly: SEED 7 FAIL, SEED 9 fitter TIMEOUT, SEED 11
passing. **Expect to sweep.** Lead with SEED 11 — the seed currently pinned and passing on
main:

```
USE_DOCKER=1 SEEDS="11 7 5 2 12 3" tools/seed_sweep.sh DVD_cc21
```

**Never flash a `_MARGINAL_` build.** 67 MHz under-clocks the decode domain and the picture
pixellates heavily — that is the marker doing its job, and it has already cost one hardware
round.

### Next step

**Round 5 is the current build: `releases/DVD_cc21r4_20260827_0004.rbf`** (SEED 9,
clk_dec 86.47/87.92 — above the gate at both corners; its `_MARGINAL_` sibling from SEED 3
is not to be flashed). Round 4 confirmed **captions decode on C1 on a real television**;
round 5 chases the residual scattered-dropped-characters symptom with ~500 ns shaped data
edges (the spec's transition, vs the 74 ns square steps that make a marginal slicer fail
parity — and 608 decoders *drop* bad-parity bytes, which reads as missing letters) plus a
skid-hold de-interleave that can no longer drop a bunched-parity pair (measured harmless on
MiB/Matrix, deleted on principle). See §6. The round-3 rbf
(`DVD_cc21r2_20260826_2022.rbf`) shipped with an UNDRIVEN `cc_line` net (an edit had
deleted the wire declaration; Quartus grounded it) — the whole caption chain was dead, so
it tested nothing about the field fix. Superseded, along with `DVD_cc21_20260826_2006.rbf`
(round 2 — its CC1 rides the wrong field). The round-4 build carries the restored wiring +
the round-2 field fix, now pinned end-to-end by `bench/dvd/cc_e2e_tb.sv` (a TV model
demodulating re_interlace's own output pins). Test: captioned disc (§3), TV captions on
**C1**, analog output, scanlines off; `P1O[44]` CC Test Line remains the first check if
nothing appears.

Checked and needing no action: the idle screen cannot interact (it draws in the active
region while nothing is mounted; captions live in the VBI of the second raster), and OSD
Reset pulses `reset_n`, which async-clears the caption FIFO — so no stale pair can fire onto
the logo screen.

---

## 1. What line-21 captions actually are on a DVD

They are **not** subpicture. Subtitles on a DVD are SPU bitmaps (`dvd/spu_decode.sv`);
closed captions are a completely separate channel that rides in the **MPEG-2 video
elementary stream as user data**, and a real player's job is to strip them out and
re-inject them onto line 21 of its *analog* output for the TV to decode.

```
00 00 01 B2      user_data_start_code
43 43            user_identifier "CC"
01               user_data_type_code
F8               caption_block_size
     bit7 odd_field_first | bit6 filler | bit5:1 cc_count | bit0 extra_field
then 2 * cc_count caption_field_blocks of 3 bytes each:
     bit7:1 filler 0x7F | bit0 field_odd ,  cc_byte_1 , cc_byte_2
```

Layout per ffmpeg's `mpeg12dec.c`. **This was verified, not assumed** — `cc_scan.py`
checks every filler bit and the EIA-608 odd parity of every data byte and reports the
pass rate. On all six captioned discs in the local library: `bad_marker=0`,
`parity_ok(nonnull)=100.0%`. The decoder also emits readable English text (§3), which is
the end-to-end proof that the field layout above is right.

### The three findings that decide the RTL design

Measured on MEN_IN_BLACK / THE_MATRIX / PAW_PATROL by walking the ES directly:

1. **The block sits immediately after the GOP header (`00 00 01 B8`)**, not after a
   picture header — 100% of blocks on all three discs. Captions arrive **batched per
   GOP**, not attached to individual pictures.
2. **`cc_count` counts DISPLAY frames, not coded pictures.** Every block reads
   `cc_count = 15` while only **12** pictures follow before the next GOP. That is 3:2
   pulldown: 12 coded film frames = 15 display frame periods at 29.97. The encoder has
   already expanded the caption stream over the repeat-field cadence for us.
3. Therefore **one caption byte-pair belongs to one displayed FIELD**, `2 * cc_count`
   pairs = the GOP's field count, interleaved field-1 / field-2.

Point 3 is the useful one: the caption stream is natively paced at the 59.94 Hz **field
rate**, which is a clock this core already owns and trusts (`refresh_tick`, the governor's
displayed-field cadence). Captions do not need a PTS, an STC compare, or an A/V-sync
scheme of their own — see §4.

---

## 2. The census tools

### `tools/cc_scan.py`

Mirrors `tools/video_cadence_census.py`: same validated sector demux (`video_payload`),
same **deep-window sampling** (the Thayer's-Quest trap — captions stop and start within a
title, so a heads-only sample is worthless), same first-party-oracle rule of reusing our
own parsers.

```bash
tools/cc_scan.py <iso> [<iso> ...]
tools/cc_scan.py --text <iso>            # decode a sample of CC1 text
tools/cc_scan.py --per-window <iso>      # the anti-"heads" spread
tools/cc_scan.py --vts 3 --windows 40 --win-sectors 2000 <iso>
```

Two self-checks worth knowing about, both added after they caught something real:

- **`pics=` (picture start codes seen).** A disc with no captions and a disc where the
  demux silently found no video look identical otherwise. Any `NO CAPTIONS` verdict with
  `pics=0` is reported as `NO VIDEO SAMPLED` instead and is not a caption result.
- **Parity is measured over non-null pairs only.** Most discs pad the unused field-2 slots
  with `0x80 0x80` (valid odd parity); some pad with `0x00 0x00`, which fails parity by
  construction and pegged the naive rate at a flat, meaningless 50% on three discs. The
  padding convention is not corruption.

### `tools/dvd_census.py --captions`

Captions are the one DVD feature that is **completely invisible in the IFO** — no nav
table mentions them, and libdvdread cannot see them either — so the IFO-only census had a
blind spot here by construction. The flag delegates to `cc_scan.py` and adds three
prevalence rows (`cc_present`, `cc_carrier`, `cc_708`) plus a per-disc
`CC608(nonnull/pairs)` flag. It is opt-in because it opens the video ES.

---

## 3. Measured prevalence (local library, 34 discs, 2026-08-25)

**6 of 34 discs carry live captions.** All six are NTSC; every PAL disc scanned clean, as
expected (line 21 is an NTSC construct).

| Disc | pairs | non-null | note |
|---|---|---|---|
| MEN_IN_BLACK | 2460 | 311 (12.6%) | |
| THE_MATRIX_16X9LB_N_AMERICA | 2430 | 230 (9.5%) | field-2 padded `00 00` |
| CASTLE_IN_THE_SKY | 2072 | 277 (13.4%) | `extra_field=23` (3-field frames) |
| CLUE | 2706 | 288 (10.6%) | + 1100 non-caption encoder user_data blocks |
| ELMOPALOOZA | 1470 | 122 (8.3%) | |
| PAW_PATROL_MEET_EVEREST | 1446 | 294 (20.3%) | densest in the library |
| ROGER_WATERS_IN_THE_FLESH | 2310 | **0** | **carrier only** — see below |

Notes that matter:

- **"Carrier only" is a distinct outcome and the census reports it as one.** Roger Waters
  emits a perfectly well-formed CC block on every GOP in which every single byte pair is
  null padding. A presence-only probe would have scored it as captioned. It is not.
- **Field 2 is empty on every disc in the library** (`f2=0` throughout): no CC3/CC4 second
  language, and **no XDS** (`xds=0`), so no program-name metadata to harvest. Only the
  CC1 stream carries anything. A v1 decoder can implement CC1 alone and lose nothing
  measurable here.
- **No CEA-708 anywhere** (`ga94_cc=0` on all 34). The GA94/A/53 path is a broadcast-era
  format; these discs predate it or ignore it. 708 can be dropped from scope with evidence.
- Confirmed real negatives, not sampling misses: ULTIMATE_T2 (5082 pictures scanned,
  zero user_data blocks), Akira, FAIRYTOPIA all re-scanned at `--windows 40
  --win-sectors 2000`.
- CLUE carries ~1100 *non-caption* user_data blocks (signatures `050b092c`, `050b0448`,
  …) — an authoring-tool watermark. Any implementation must match the `"CC" 0x01 0xF8`
  signature and not merely the presence of `0x000001B2`.

Text decoded from MEN_IN_BLACK's CC1 stream, as proof the parse is correct:

> `[ Grunting ] Come on, Edwards. What you see is what I got. [ Door Opens ] … You know
> what I mean ? … Where is Ivan ? [ Edgar ] Gave him a break. … - Shut up !`

---

## 4. How it works, as built

Four legs. Only the first two contain anything subtle.

### 4.1 Extraction — a passive snoop in the VLD

`rtl/mpeg2/vld.v` used to throw the data away:

```verilog
CODE_USER_DATA_START:  next = STATE_NEXT_START_CODE;
```

The key realisation is that this line already does most of the work. `STATE_NEXT_START_CODE`
walks the stream **one byte at a time** (`next_advance = 0`, `align = 1`) looking for the
next start code, so the whole user_data payload streams past in `getbits[23:16]` for free.
The snoop therefore adds **no FSM state, no advance/align change, and no new bitstream
consumer** — it is one `always` block that watches bytes go by, armed by the `0xB2` start
code and disarmed the moment the walk ends. The diff to `vld.v` is **110 insertions and
zero deletions**, and the new block assigns only to its own registers, so the decode path
cannot be affected by construction.

A non-caption user_data block (CLUE carries ~1100 of them) simply fails the
`"CC" 0x01 0xF8` signature match and is ignored.

**Why the VLD and not `ps_demux`,** where the sniff would have been trivially easy:
`ps_demux` sits *in front* of the VBUF, which runs up to ~1 s ahead of the screen. A
demux-side sniff is the **stale-display-flags** bug (drift saga rounds 11–12) wearing a
new hat — data captured at parse time, presented against a different picture. The VLD sits
*behind* the VBUF, which is precisely why `flags_commit` had to move there.

### 4.2 Pacing — one pair per displayed field, and nothing else

This is where the §1 measurements pay off. Because `cc_count` counts **display frames** and
the encoder has already expanded the stream over the 3:2 cadence, one byte pair belongs to
one displayed **field**. So `dvd/cc_line21.sv` consumes exactly one pair per field at line
21 and captions track the picture with **no PTS, no STC compare, and no rate correction** —
governor drops and repeats included, because the caption clock and the raster are then
literally the same clock.

Pairs carry their own field bit, so they are de-interleaved into one slot per field parity.
A disc that only ever emits field 1 (every disc in §3) leaves the field-2 slot empty and
field 2 transmits nothing. An empty slot **blanks** line 21 rather than inventing a null
pair: we transmit exactly the fields the disc provides.

Crossing `clk_dec` → `clk_sys` is a `fifo_dc` inside the inserter, 128 entries against a
worst case of 62 pairs per GOP block. `load_flush` — the same event that resets `ps_demux`
and re-anchors `av_sync` — drops the backlog, so a seek cannot paint the pre-seek sentence
onto the new scene.

### 4.3 The waveform

```
7 cycles clock run-in | 3 start bits (0,0,1) | 16 data bits  =  26 bit periods
```

The dot clock makes the timing exact rather than approximate: 13.5 MHz = 858 × fH and the
bit rate is 32 × fH, so **one bit is 858/32 = 26.8125 dots exactly**. A 16-bit NCO stepping
2444 per dot realises that to +0.0002 %, and its top 4 bits index the run-in sine LUT for
free. Levels are 50 IRE for logic 1 and blanking for logic 0; the run-in is
`25 − 25·cos(2πφ)` IRE, which puts its positive peaks at the bit centres — the alignment
the standard defines between the recovered clock and the data eyes.

Placement: hsync leads at dot 735 of 858, so 10.5 µs later is dot 18.75 of the next line's
active region. The waveform is 26 × 26.8125 = 697 dots, ending at dot ~716 — inside the
720-dot active window with 4 dots to spare, which is not luck: line 21 is specified to fit
an active line. The module arms at dot 16 so that after three registers of pipeline the
emitted run-in lands on ~19, keeping the ±0.25 µs (±3.4 dot) window centred rather than
spending it on pipeline delay.

Levels are driven equally on R, G and B — luma-only, zero colour difference — so the data
lands on Y for a YPbPr or composite chain and carries no chroma.

### 4.4 Injection — finding line 21 without touching `syncgen`

`sync_gen` already publishes everything needed, so nothing in `syncgen.v` changes: in
interlaced mode `v_pos = {v_cntr[10:0], ~odd_field}`, which makes `sg_vpos[11:1]` the
field-relative line counter and `sg_vpos[0]` the field parity, both already aligned to
`sg_hpos` through the same output pipeline.

**The line number derives two independent ways and they agree**, which is the reason to
ship it without a set in front of us:

- **By count** — NTSC line 21 is the 15th line after vertical sync ends. Our vsync window
  is `[244, 247)`, so lines 247–261 are that back porch and 261 is its 15th.
- **By position** — line 21 is the last VBI line before active video. `v_cntr` 261 is the
  last line before the counter wraps to 0 = the first active line.

Both give `v_cntr == 261`, which is exactly `p_vlen`, the short field's last line index.
The long field carries its extra line at the end, so 261 is the 15th line after vsync in
**both** fields and one constant covers both. `odd_field = 1` is field A = TOP content =
NTSC field 1, the field that carries CC1/CC2.

The output mux is written caption-first but gated on `~sg_pixel_en`, so a mis-derived line
number can only ever cost one blanking line — it can never punch a hole in the picture.

### 4.5 Verification

| Bench | What it proves |
|---|---|
| `bench/dvd/cc_extract_tb.sv` | **180/180 caption pairs recovered byte-exact** by the real `vld` + `getbits_fifo` over real MEN_IN_BLACK bytes, against a golden list from the independent Python parse. This is the leg with a real assumption in it — that the payload streams past in `getbits[23:16]` — so it is tested against the real getbits pipeline, not a model. |
| `bench/dvd/cc_line21_tb.sv` | A **demodulator**, not a register-toggle check: slices the emitted luma at 25 IRE, locks to the run-in the way a television does, samples at the bit centres and reassembles the byte pair. Plus field-parity routing, one-pair-per-field pacing, empty-slot blanking, flush, and disabled. 5/5 green. |
| `bench/dvd/re_interlace_tb.sv` | Unchanged and still green (9/9, pixel-exact content checks) with `cc_enable` held low — which is itself the assertion that captions cannot touch active video. |

Fixtures come from `tools/cc_scan.py --fixture`, which carves real GOP-header + user_data
runs out of a disc (712 bytes, small enough to commit) together with the golden pair list.

### 4.6 What this cost

Sub-1 % of the device: a 17-bit × 128 `fifo_dc`, a 16-bit NCO, a 19-bit shift register, a
16-entry sine LUT and the VLD snoop's ~40 flip-flops. That was the whole point of choosing
this over an on-screen character generator — see §5.

## 5. The option not taken: an on-screen character generator

Rendering 608 ourselves — decoding the control codes and painting a 32×15 character grid —
was the obvious reading of "decode them as subtitles", and it was dropped on **fit
grounds**, not on principle. Recorded here so the trade-off is not re-litigated from
scratch:

- A 608 decoder is a modest FSM (PACs, mid-row codes, pop-on / roll-up / paint-on, doubled
  control pairs) plus a 32×15×7-bit character RAM, double-buffered for pop-on ≈ one M10K.
- Rendering had a ready home: `dvd/transport_hud.sv` already runs a text plane through a
  generated glyph ROM, (x,y)-pure and priority-muxed into the one existing `subpic_blend`
  register stage.
- But the **HUD font is uppercase-only** — 45 glyphs in a 64-entry ROM — and captions are
  mixed case, so the ROM goes to 128 entries / 7-bit index, 2 M10K instead of 1.
- The fit it was weighed against was **40,973 / 41,910 ALMs (98 %), 504 / 553 RAM blocks
  (91 %), 100 / 112 DSP (89 %)** — a design where a branch had already failed to route at
  91 % ALMs and needed the M19 area pass to recover. It plausibly fit on paper and landed
  on a fit that could not absorb it.

**★ That rationale has since expired — the conclusion is now a CHOICE, not a constraint
(2026-08-26).** The PR #9–#11 area reclaim moved the baseline to **39,117 ALMs (93 %),
501 RAM blocks (91 %), 92 DSP (82 %)**, which is enough for the renderer's few hundred ALMs
and 2–3 M10K. Asked directly, the user chose to **keep the scope at line-21 only** and
revisit separately if ever wanted. So do not re-derive "it does not fit" from this section:
it does fit, it is simply not in scope.

If it is ever picked up: the extraction and pacing legs (§4.1, §4.2) are already built and
would be reused unchanged — only the renderer is missing. Two cautions survive the reclaim.
RAM is **still 91 %**, so the 2–3 M10K is a real bite; and "ALMs needed" still peaks near
97 % under packing variance, with the fitter temperamental enough that the most recent
netlist needed three seeds to find one that closes. Affordable, not free.

The honest limitation of the shipped approach, stated plainly: **it does nothing on HDMI**,
and on analog it depends on the viewer's television having a caption decoder. Line-21 data
reaches a decoder over composite and S-video, and over component on many sets; an RGB SCART
path carries the waveform on all three channels but consumer sets generally do not slice
captions from RGB. Every US television 13 inches and larger has had a decoder since 1993.

---

## 6. HW gate — what only a television can settle

### Round 1 (2026-08-25): no captions on MiB or The Matrix, TV set to C1

C1 was the correct choice — CC1 and CC2 both ride field 1, and field 2 is empty on every
disc measured. **One real bug** was found (and one misdiagnosis was introduced on top of
it — see round 2):

1. **The analog chain blanked the data one module before the DAC.** `sys/sys_top.v` fed the
   VGA2 scanlines stage `.din(vga2_de ? {vga2_r,vga2_g,vga2_b} : 24'd0)` — everything
   outside active video forced to zero, and line 21 is *by definition* in the blanking
   interval. The waveform was generated correctly, reached `sys_top`, and was zeroed. Gate
   dropped; it is a no-op for every other line because `re_interlace` already emits 0
   outside its own active region. (`scanlines`, `osd`, `yc_out` and `vga_out` were all
   checked — none gate data on DE, they only pipeline it. This was the only one.)

   **Lesson worth keeping:** a VBI side-channel travels a path that every other feature
   uses only inside DE. Anything that writes outside active video has to be traced to the
   pin, not just to the module boundary.

2. **A second "fix" made in this round was itself a bug.** Reasoning from picture content
   (TOP field = "field 1"), `cc_fld1` was flipped from `~sg_vpos[0]` to `sg_vpos[0]` —
   inverting a mapping that had been correct. The DE-gate bug masked it: with everything
   blanked, both parities looked identically dead, and a bench was written that "pinned"
   the wrong premise. Kept here as a caution: **round 1 had one bug in the code and one in
   the diagnosis.**

### Round 2 (2026-08-26, YC active encoder board → composite): CC Test Line ✅, C1 empty

The test line showed the dash band changing with dialogue — **hardware confirmation for
extraction, pacing, the waveform, the DE-gate fix, and the whole analog path through the
external encoder**. With the test line off, C1/C2/T1/T2 all showed nothing.

That symptom is itself the diagnosis: **C1, C2, T1 and T2 are all FIELD-1 services**, so
"every option empty while the data provably flows" points at the field mapping — and the
round-1 flip was wrong. The correct derivation, by what the television actually measures:

- **SMPTE 170M: broadcast field 1's vertical sync begins coincident with a line boundary;
  field 2's begins mid-line.** Sync phase is the *only* thing a TV uses to name fields —
  picture content never enters into it.
- In `sync_gen`, `vs_ref_dot = odd_field ? 0 : halfline` — the line-aligned vsync is
  emitted during `odd_field==1`, in the blanking *after* the TOP-content lines. The 15 VBI
  lines after it carry `v_pos[0]==0`, and the active field that follows is BOTTOM content.
- So broadcast field 1 = { line-aligned vsync, VBI with `v_pos[0]==0`, BOTTOM active } —
  consistent with NTSC being **bottom-field-first** (field 1 displays the bottom lines).
  The DVD decoder-side "TOP = field 1" labeling is about picture geometry, not sync phase;
  in this raster TOP content displays inside *sync* field 2.

**Fix: `cc_fld1 = ~sg_vpos[0]`** (the original mapping, restored). The bench was rewritten
to assert by the TV's definition — it classifies each vsync leading edge by the `h_pos` it
rises at (line-aligned vs mid-line) and requires CC1 on the line-aligned-vsync field's VBI
— and mutation-checked (flipping the formula fails on every field). The premise can no
longer be encoded wrongly, because the bench measures sync phase, not content.

### Round 3 (2026-08-26): no captions AND no test line — the build, not the logic

The test line dying was the tell: it sits upstream of everything field-related, so the
whole chain was dead and **the field fix was never actually exercised**. Root cause: the
edit that rewrote the field-mapping comment had **deleted the `cc_vline`/`cc_line` wire
declarations** along with the old text. Verilog silently created an undriven implicit net,
Quartus tied it to ground (Warning 10236 — in the build log, missed by error-only greps),
and the transmitter never armed. Every bench still passed, because none ran `re_interlace`
with captions *enabled* — the wiring **between** the proven pieces was the only untested
thing, and it was the thing that broke.

Three guards now exist so this class cannot recur:

1. **`bench/dvd/cc_e2e_tb.sv`** — captions end-to-end at `re_interlace`'s output pins,
   checked by a television model (vsync-alignment field classification, run-in-anchored
   demodulation, line-position check, active-video-untouched check). Written first and run
   against the broken tree: it fails there with the exact hardware symptom.
2. **`` `default_nettype none``** guards in `dvd/re_interlace.sv` and `dvd/cc_line21.sv` —
   an undeclared identifier is now a compile error in both iverilog and Quartus.
3. **`build_release.sh` fails on any Warning 10236** in the map report, listing the nets.
   (A pre-existing benign one — `vld_err` in `emu.sv`, driven and consumed under the same
   implicit name — was declared properly so the gate can be zero-tolerance.)

### Round 5 (2026-08-26): ✅ HW-CONFIRMED — shaped edges fixed the dropped characters

User report: C1 captions complete and readable on MiB and The Matrix. The scattered
missing-letter symptom is gone with the ~500 ns shaped transitions, confirming the
parity-drop-at-the-slicer diagnosis below.

### Round 4 (2026-08-26): ✅ CAPTIONS DECODE ON C1 — residual: scattered dropped characters

With the round-3 wiring restored and the round-2 field fix finally reaching the pins,
**a real television decodes CC1 through the YC active encoder board over composite**. The
feature works end to end. Residual symptom: letters missing mid-word and occasional words
run together (a vanished space).

Diagnosed measurement-first (round 5):

- **The de-interleave was exonerated by replaying it over the real pair streams** (~13 min
  each): Matrix alternates field parity perfectly (0 drops) and MiB's 7 bunching events
  would have dropped null padding only — zero data-carrying pairs. So the pacing logic was
  not eating the letters on these discs.
- That leaves the analog domain, with a real spec gap on our side: **EIA-608 data
  transitions are specified shaped; we transmitted square edges with 74 ns steps.** Edges
  that sharp ring after the encoder's filtering, and a 608 decoder **drops any byte whose
  parity check fails** — which displays exactly as missing letters and eaten spaces, never
  as garbage on screen.

Round-5 changes: data-bit transitions shaped through the shared half-cosine over ~500 ns
(max per-dot step 48 vs the old 128 cliff; >1.3 µs plateau preserved per bit; a virtual
forced-zero tail bit ramps the final logic-1 down). And the drop-on-mismatch became a
1-entry **skid hold** — measured harmless here, deleted on principle; `cc_line21_tb` [6]
(slope bound) and [7] (bunched parity in order) pin both. ⚠ The television itself is still
unexonerated — there is no second line-21 source to A/B against — but shaped edges are
correct regardless of which side the marginality lives on.

### `P1O[44] CC Test Line` — the diagnostic that was missing

Line-21 data is invisible by construction, so round 1 could not distinguish "the TV is not
decoding" from "no data is reaching the output" — which is what made it guesswork. Round 2
proved the diagnostic's worth: one glance separated "chain works, placement wrong" from
every upstream possibility. With
**CC Test Line = On** the same waveform is painted on a *visible* line near the top of the
picture instead of line 21. Same data, same rate, same levels.

- **A band of dashes that changes as dialogue changes** ⇒ extraction, pacing, the waveform
  and the whole analog path are all working, and only the TV-side placement is left.
- **Nothing at all** ⇒ the problem is upstream: check the analog raster is actually engaged
  (`Analog Out`, `vga_scaler=0`), and that the disc is one of the captioned six in §3.
- **A band that never changes** ⇒ data is flowing but stuck — pacing or flush.

### Still unconfirmed, in rough order of likelihood-to-be-wrong

*(Round 2's test line moved items 2–4 from "unproven" to "unlikely": the same NCO, levels
and shaping were slice-visible on screen through the real encoder chain. They stay listed
because a visible-line check is not a caption-decoder lock.)*

1. **The line number.** Derived twice, agreeing (§4.4), but both derivations rest on the
   modeline's relationship to broadcast line numbering. If captions do not appear, this is
   the first thing to move: `cc_line` in `dvd/re_interlace.sv`, ±1 or 2 lines. Most decoders
   slice a window around line 21 rather than exactly one line, which is the reason for
   optimism.
2. **The start dot.** `CC_START = 16` in `dvd/cc_line21.sv` targets 10.5 µs ±0.25 µs after
   the hsync leading edge, after three registers of pipeline. The pipeline depth is counted,
   not measured.
3. **Waveform shaping.** The run-in is a 16-entry sine; the data bits are hard square edges
   with no raised-cosine shaping. Decoders slice at 25 IRE and lock to the run-in
   fundamental, so this is the normal simplification — but it is a simplification, and a
   marginal decoder is where it would show.
4. **Amplitude.** 50 IRE is taken as 128/255 on the RGB output. Correct if the analog chain
   maps 0–255 to 0–700 mV; worth a scope check if a decoder half-locks.
5. ~~**Which field is field 1.**~~ **SETTLED in round 2** — the round-1 "fix" had inverted
   a correct mapping; restored to `~sg_vpos[0]` with the sync-signature derivation, and
   pinned by the rewritten `bench/dvd/cc_field_map_tb.sv`, which now measures vsync
   alignment (what a TV measures) instead of content parity (what round 1 wrongly assumed).

Also worth knowing: **turn scanlines off while testing.** The analog scanlines effect
attenuates alternate lines by 25–75 %, and it is applied before the caption line reaches
the DAC, which would halve the waveform amplitude on one field.

### Connection matters

Line-21 data reaches a television's decoder over **composite and S-video**, and over
**component** on many sets. An **RGB SCART** path carries the waveform on all three
channels, but consumer sets generally do not slice captions from RGB. And none of this
does anything on **HDMI** — there is no on-screen renderer (§5).

Test discs are already in hand and measured: MEN_IN_BLACK, THE_MATRIX, CASTLE_IN_THE_SKY,
CLUE, ELMOPALOOZA, PAW_PATROL (§3). ROGER_WATERS is the negative control — well-formed
blocks, all-null payload, so line 21 should stay blank on it.

---

## 7. Known limitations of the census (not of DVDs)

- **Main-feature VTS only.** `scan_iso` defaults to `nav.best_vts`; captioned bonus
  features or a second title in another VTS are not sampled. `--vts N` overrides.
- **Sampled, not exhaustive.** Default 12 windows × 1200 sectors ≈ 29 MB per disc. A disc
  captioned only in one short stretch could read as clean. Raise `--windows` when a
  negative matters.
- **Field-2 / XDS handling is counted, not decoded.** No disc in the library exercises it,
  so the path is unproven; `--text` decodes CC1 only.
- **`decode_608_text` is deliberately light** — printable characters with control pairs as
  separators, no roll-up/pop-on state machine. It exists to prove the bytes are real text,
  not to be a reference renderer. If Leg 3 is ever built, this is the natural place to grow
  a proper golden model to cosim against (the `tools/mp2_ref.py` / `tools/dvd_vm_ref.py`
  pattern).
