# Line-21 closed captions (EIA-608) on DVD — measurement + feasibility

**Status (2026-08-25): MEASURED, NOT IMPLEMENTED.** No RTL exists. What ships as of this
document is the *census* half: `tools/cc_scan.py` and `tools/dvd_census.py --captions` can
now tell you which discs carry captions and how dense they are. The decode/render half is
assessed below with a concrete design and an honest cost — it is **not** started, and the
fit headroom section explains why it should not be started casually.

This supersedes the previous stance in `docs/test_disc_shopping_list.md` #15 ("normally
decoded by the TV, not the DVD core — likely out of scope"). That was half right: it *is*
normally decoded by the TV, which turns out to be an argument for one of the two designs
below, not an argument that the data is unreachable.

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

## 4. Could we decode them as subtitles? — design assessment

**Yes, and the timing model is unusually easy.** Three legs, of which only the third is
expensive.

### Leg 1 — extraction (the only RTL that both options need)

`rtl/mpeg2/vld.v:679` currently throws the data away:

```verilog
CODE_USER_DATA_START:  next = STATE_NEXT_START_CODE;
```

which hunts straight to the next start code. The bytes are *already* flowing through
`ps_demux` into the decoder; nothing upstream has to change. Adding a `STATE_USER_DATA`
that shifts bytes out into a small FIFO until `00 00 01` is on the order of 20 lines.

**Extract in the vld, not in `ps_demux`.** This is the same lesson the project already
paid for twice:

- `ps_demux` sits *in front* of the VBUF, which runs up to ~1 s ahead of the screen. A
  demux-side sniff is the **stale-display-flags** bug (CLAUDE.md, drift saga rounds 11–12)
  in a new costume: data captured at parse time, presented against a different picture.
- The vld sits *behind* the VBUF and is at most a reorder-depth ahead of display, which is
  exactly where `flags_commit` had to move the `rff`/`tff`/`progressive_frame` capture to
  fix the drift ramp. Put captions on the same footing.

### Leg 2 — pacing (nearly free, per §1 finding 3)

One byte-pair per **displayed field**. Buffer a GOP's worth (max `cc_count=31` × 2 = 62
pairs = 124 bytes; a single small FIFO) at the GOP header, drain one pair per field tick.
No PTS, no STC compare, no NCO — the encoder pre-expanded the stream over the 3:2 cadence,
and draining per *displayed* field means governor frame drops and repeats are absorbed
automatically, because the caption clock and the raster are then the same clock.

Flush on the existing contract: whatever pulses `load_flush` / `vbuf_flush` must clear the
caption FIFO and reset the 608 decoder state, or a seek will paint the pre-seek sentence.

### Leg 3 — the 608 decoder and the glyph plane (the expensive leg)

An EIA-608 decoder is a modest FSM — control-code pairs (PACs, mid-row codes, pop-on /
roll-up / paint-on modes, backspace, EOC/EDM/ERM), doubled control pairs to de-duplicate,
a 32×15 character grid, double-buffered for pop-on. Call it 32×15×7 bits ×2 ≈ 6.7 kbit,
so **one M10K** for the character RAM.

Rendering has a ready-made home: `dvd/transport_hud.sv` already runs a text plane through
a generated glyph ROM (`tools/hud_font.py` → `dvd/hud_font.mem`), (x,y)-pure and
priority-muxed into the **one existing `subpic_blend` register stage** — the hotspot
discipline documented in `docs/transport_hud.md`. A caption plane is 15 rows of the same
machinery instead of 2.

One catch: **the HUD font is uppercase-only** — `GLYPH_ORDER` is 45 glyphs (digits, six
punctuation, `A`–`Z`, three transport icons) in a 64-entry ROM. Captions are mixed case
(see the MiB sample above). Adding lowercase pushes past 64 glyphs, so the ROM goes to 128
entries / 7-bit index — 2 M10K instead of 1. Rendering captions in all-caps to dodge this
is defensible (period caption decoders often were) but it is a visible quality choice, not
a free one.

### The real blocker: fit headroom

Current release fit:

```
Logic utilization (ALMs) : 40,973 / 41,910  (98 %)
Total RAM Blocks         :    504 /    553  (91 %)
Total DSP Blocks         :    100 /    112  (89 %)
```

That is **~937 ALMs and 49 M10K free**, on a design whose history includes a branch that
**failed to route at 91% ALMs** and needed the M19 area pass to recover (CLAUDE.md,
`docs/ac3_decoder_architecture.md` §4.11). Leg 3 plausibly fits *on paper* — a few hundred
ALMs and 2–3 M10K — but it lands on a fit that is already marginal and seed-sensitive
(memory `quartus-build-flaky-routing`). **Realistically this feature needs an area pass to
pay for itself first**, and the known-productive lever is the recurring one: find
unconverted LUT-RAM and move it to M10K.

### Option B — inject a real line-21 waveform on the analog output

Worth taking seriously precisely *because* of the fit numbers. This core has a native
15 kHz interlaced analog raster (`dvd/re_interlace.sv`, `docs/analog_dual_raster.md`) with
true field parity — which is exactly what a real DVD player uses to hand captions to the
TV. Instead of decoding 608, modulate the byte pairs onto **line 21 of the matching field**
as the standard waveform (7 cycles run-in at 32×fH ≈ 503.5 kHz, 3 start bits, 16 data bits,
50 IRE) and let the television's built-in decoder do the work.

- **Cost: a phase accumulator and a shift register.** No 608 FSM, no character RAM, no font
  ROM growth, no glyph plane, no new blend path. Tens of ALMs against Leg 3's hundreds —
  which on a 98%-ALM fit is the difference between "needs an area pass first" and "try it".
- It is what the hardware being emulated actually did, and every US television 13" and
  larger since 1993 has the decoder.
- **Limits:** analog output only (nothing on HDMI), and it depends on the viewer's TV. It
  still needs Legs 1 and 2 — extraction and field-rate pacing are shared with Option A.

Legs 1+2 are the shared prerequisite either way, and they are the small, structurally
interesting part. A sensible order is: extraction + pacing first (provable in sim against
`cc_scan.py`'s decode of the same disc, which is a ready-made golden model), then Option B
as the cheap payoff, then Option A when an area pass has bought the room.

---

## 5. Known limitations of the census (not of DVDs)

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
