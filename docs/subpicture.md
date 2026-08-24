# DVD Subpicture (subtitles) — design notes & format reference

**Status: v1 ✅ HW-CONFIRMED 2026-07-06 (PR fj#71, `DVD_subpic_rel`).** Subtitles decode and
composite over the video on real hardware; playback is stable. The decode + alpha-blend
overlay layer is the reusable base for transport popups / disc menus. Read alongside
`docs/roadmap.md` ("UX / interface strategy" before Phase 7, and Phase 10 subtitle half),
`docs/architecture.md` (ps_demux), and the memory `dvd-iso-navigator`.

## ⚠️ Bring-up gotchas that cost several HW rounds (read before touching this)

1. **CONF_STR bit form:** `"O15,..."` parses as the RANGE `O[1:5]` (two base-36 chars), NOT
   bit 15 — subtitles never enabled AND it stomped Audio/CRT-Aspect/Debug-Overlay. Use the
   bracket form `"O[15]"`. (Bit ≥10 without brackets is always wrong.)
2. **Congestion:** the subpicture renderer lands in the routing-marginal display hotspot and
   pushed the fit over the edge → playback wedged / constant resync (a fit/timing failure, not
   a logic bug — a good placement existed but the pinned seed was tied to the old netlist). Two
   fixes made it stable: (a) the blend is **combinational before the existing output register**
   (no added pipeline stage / no CE_PIXEL change → video/sync timing byte-identical to the
   proven pre-subpicture core; subtitle ends up 1px-shifted, invisible); (b) **`debug_overlay`
   is compiled out** for the release build (`` `ifdef DEBUG_OVERLAY ``, default off) to free the
   corner. **The shipped release build has NO O2 overlay** — define `DEBUG_OVERLAY` in DVD.qsf
   to bring it back (may re-tighten the fit / need a seed re-sweep).

## v1 — what shipped (sim-verified)

| Piece | File | Notes |
|---|---|---|
| Transport | `dvd/ps_demux.sv` | New `sp_track`/`sp_enable` in, `sp_byte/valid/frame_start/pts` out. Subpicture (0x20–0x3F) is intercepted in `S_SUBSTREAM_ID` BEFORE the audio-track filter → `S_SP_DATA` (no sub-header). `sp_pts` reuses the existing `aud_pts` assembler. |
| Decode + render | `dvd/spu_decode.sv` | Sync-BRAM SPU buffer + DCSQ parser + nibble-RLE decoder → full-frame **720×576 2-bpp** bitmap BRAM. Show/hide vs `av_sync.stc`. Per-pixel `q_idx`/`q_inside` query (1-cyc registered read). |
| Blend | `dvd/subpic_blend.sv` | Standalone reusable RGB alpha compositor. Caller supplies the resolved 24-bit overlay colour (`ov_r/g/b`) + SET_CONTR alpha; the block just alpha-mixes. **This is the layer transport UI / disc menus reuse.** `ov_force` (menu-highlight, 2026-07-08): blend on alpha alone, bypassing the idx0 transparent key, so a button-highlight coli can light the **background class (idx 0)** — the idx0 key stays right for subtitles (`ov_force` low). |
| Palette | `dvd/pgc_palette.sv` | **Phase-1 disc menus.** Captures the 16-entry PGC palette (IFO @164, `{0,Y,Cr,Cb}`) streamed by `dvd_iso_reader` at PGC load and converts YCbCr→RGB (BT.601 studio-swing, sequential round-robin — one small shared datapath, not per-pixel). `spu_decode.col0..3` (SET_COLOR) index it; the lookup is registered one stage before the blend to keep the output-hotspot path a flat mux. |
| OSD | `dvd/emu.sv` CONF_STR | `O15,Subtitle,Off,On` + `O[26:24],Subtitle Track,0..7`. |
| Wiring | `dvd/emu.sv` | `spu_decode` fed by `core_h_pos/core_v_pos/av_stc`; `subpic_blend` at the debug-overlay tap (overlay on top). One alignment register matches the 1-cyc read latency; `CE_PIXEL` delay bumped 2→3 to keep the CRT gated CE aligned. |
| Golden model | `tools/spu_ref.py` | VOB→SPU extractor + reference RLE/DCSQ decoder (PGM + memh + params). |
| Sim | `bench/dvd/{ps_demux_subpic,subpic_blend,spu_decode}_tb.sv`, `run_subpic.sh` | `spu_decode_tb` matches all 14726 DAREA pixels of the real Matrix subtitle plus timing/gating. Fixture `bench/dvd/test_vobs/matrix_spu0.{bin,idx.hex,params}`. |

**Corrections to the original notes below:** the full-frame bitmap is **~68 M10K (720×480) /
~81 M10K (720×576)**, NOT the ~9 M10K estimate that appears further down — still within the
259/553-block budget, but budget the real figure. Also: the "bake in settled A/B toggles"
congestion lever in `docs/roadmap.md` was already spent (O14/O15/O18 baked in; O14 repurposed
to CRT 480i).

**v1 decisions (write-down):**
- ~~**HDMI progressive render only.**~~ **CRT-480i field-aware render — DONE**
  (branch `feature/subpic-crt480i`, sim-verified; see "CRT 480i render" below). HDMI
  progressive was v1; CRT 480i now renders correctly too.
- **✅ REAL IFO COLOURS (2026-07-06, Phase-1 disc menus, `feature/spu-palette`).** SET_COLOR is
  now captured (`spu_decode.col0..3`) and looked up in the PGC palette (`dvd/pgc_palette.sv`, fed
  the IFO @164 palette by `dvd_iso_reader`). `dvd_iso_reader` streams the 16 `{0,Y,Cr,Cb}` entries
  at PGC load (two rbuf windows out of the already-resident PGC sector — no extra sd reads; skipped
  only if the palette straddles the sector, `pgc_off>1820`, in which case the ramp default shows).
  YCbCr→RGB is BT.601 studio-swing. Subtitles now render in their authored colours. Sim:
  `pgc_palette_tb`, `subpic_blend_tb` (full-RGB iface), `spu_decode_tb` (SET_COLOR `08 90`→col
  `0,9,8,0`), `iso_reader_pgc_tb` (16 palette words streamed byte-exact). `tools/iso_nav_check.py`
  prints PGCN-1's palette as `#RRGGBB` (HW colour predictor). The paragraph below is HISTORICAL:
- **(HISTORICAL) Fixed palette, IFO colours deferred.** SET_COLOR is ignored (needs the IFO PGC palette we
  don't parse yet); the fixed mapping is idx0 transparent / idx1 white / idx2,3 black, with
  SET_CONTR alpha honoured. Real colours are a follow-up coupled to the deferred nav/IFO work.
- **Single decode buffer / one SPU on screen** (correct for DVD subtitles). A new SPU overwrites
  the previous once its SPDSZ completes; params commit atomically at end of RLE.
- **PAL bitmap sized in (720×576)** — PAL subtitles render without a follow-up.
- **Out of scope:** CHG_COLCON (karaoke wipes), FSTA_DSP menu highlights, IFO palette, CRT-480i.

**Follow-ups:** ~~CRT-480i field render~~ (DONE) · HDMI-480i (O9) subtitle (needs the pixrep
`q_x` halving, see below) · IFO PGC palette (real colours) · CHG_COLCON · a per-disc
subtitle-track enumeration (needs IFO) · optional 2-tap render AA.

## CRT 480i render (branch `feature/subpic-crt480i`, PR fj#73 — ✅ HW-CONFIRMED 2026-07-06)

The full-frame bitmap and DAREA are **already** in absolute frame-line coordinates
(the RLE decoder writes top field → even abs lines, bottom → odd; the `in_y` check uses
absolute `q_y`), so 480i needed only a render **addressing** fix, not a decode change.

- **Why it broke:** in interlaced output `rtl/mpeg2/syncgen.v` sets
  `v_pos = {v_cntr, ~odd_field}`, so `core_v_pos` **already IS the absolute frame line**
  (`field_line*2 + parity`, with `odd_field=1` → even `v_pos` → TOP content, matching the
  bitmap's top=even convention). But within a field `core_v_pos` advances by **2** (bit 0 =
  constant field parity). `spu_decode`'s render row-base accumulator assumed a progressive
  `+1` raster: its `q_y==0` reset never fired on the odd field (which starts at 1) and the
  `+1` increment never fired at all → `q_row_base` mis-addressed the bitmap.
- **The fix (`dvd/spu_decode.sv`, `input interlaced`):** when high, the accumulator re-bases
  at the field top (`q_y<=1` → `q_y[0] ? STRIDE : 0`, uniquely picking each field's first
  line + its parity offset) and steps by `2*STRIDE` on `q_y == q_y_d + 2`. Progressive path
  byte-identical. No write-side / DAREA / blend change → no CE_PIXEL or pipeline change
  (fit unaffected).
- **Wiring:** `dvd/emu.sv` drives `.interlaced(crt_eff)` — **CRT-480i only**. CRT is
  native-width (720, `dot_ce` 13.5 MHz) so `q_x = core_h_pos` maps 1:1. **HDMI-480i (O9)**
  also interlaces `core_v_pos` but pixel-repeats `core_h_pos` to **1440 wide**, so its
  subtitle would additionally need a `q_x` halving (or 1440-wide read) — deferred as a
  separate follow-up; O9 subtitle is unchanged (still v1-progressive-broken there).
- **Sim:** `bench/dvd/spu_decode_480i_tb.sv` feeds the golden Matrix SPU with `interlaced=1`
  and raster-scans in interlaced order (even field 0,2,..; odd field 1,3,..), asserting the
  two fields **reassemble the identical golden bitmap** the progressive test matches. In
  `run_subpic.sh`; progressive tbs tie `.interlaced(1'b0)`.
- **HW test:** O[14] CRT 480i Out + O[15] Subtitle on, `MiSTer.ini` `vga_scaler=0`,
  `composite_sync=1`, on a subtitle disc/VOB on the analog board. Sanity-check HDMI
  progressive subtitle still correct.

Subpicture is the **load-bearing visual feature**: the alpha-blend layer it introduces is
reused by transport popups and (later) disc-menu highlights. Audio-track selection is
already done (`O68 Audio Track` → `ps_demux.aud_track`); subpicture is genuinely new RTL.

---

## Where it sits in the pipeline

```
mpg_streamer/iso_reader → ps_stream_fifo → ps_demux ─┬─ video → mpeg2video → display path ──┐
                                                     ├─ audio (0xBD 0x80–0x8F,0xA0–0xA7)     │
                                                     └─ SUBPICTURE (0xBD 0x20–0x3F) ──► SPU  │
                                                        (NEW: route selected substream)      │
                                                                                             ▼
   SPU decode (RLE + DCSQ) ──► overlay bitmap + timing ──► ALPHA BLEND over video ──► mixer/out
```

Two clean parts, split deliberately:
1. **Decode** — reassemble the SPU, parse it, produce a 2-bit-per-pixel overlay bitmap +
   palette/alpha + on-screen rectangle + show/hide times.
2. **Blend** — alpha-composite that overlay onto the decoded frame in the display path.
   **This blend is the reusable piece** (transport UI, disc menus). Keep it a standalone
   module. `dvd/debug_overlay.sv` shows how an overlay currently taps the video/raster path
   — a reference for pipeline position, not the final renderer.

---

## Transport: getting subpicture out of ps_demux

- DVD subpicture rides in **`private_stream_1`** (PES `stream_id = 0xBD`), **substream IDs
  `0x20–0x3F`** (up to 32 subpicture streams). ps_demux already inspects the
  private_stream_1 sub-header to route audio (0x80–0x8F AC-3/DTS, 0xA0–0xA7 LPCM) and
  strips it. **First task: confirm exactly what ps_demux does with 0x20–0x3F today**
  (almost certainly skipped) and add a *selected-subpicture* output, mirroring the
  `aud_track` filter pattern (`dvd/ps_demux.sv` ~line 361) with a new `sp_track` /
  `sp_enable` select.
- An **SPU spans multiple PES packets** — concatenate substream payloads until you have a
  complete unit (length is the first field of the SPU header, below).
- Subpicture PES carries a **PTS** → the SPU's presentation time. Route it out like the
  audio frame PTS so display timing can sync to the video STC (`dvd/av_sync.sv`).

---

## SPU (Sub-Picture Unit) format

All multi-byte fields are big-endian. Offsets are from the start of the SPU.

**Header (4 bytes):**
| off | size | field | meaning |
|----|----|----|----|
| 0 | 2 | `SPDSZ`       | total SPU size in bytes (use to know when the unit is complete) |
| 2 | 2 | `SP_DCSQT_SA` | offset to the first DCSQ (start of the display-control table) |

Between the header and `SP_DCSQT_SA` is the **RLE pixel data** (two fields, top & bottom,
whose start offsets come from `SET_DSPXA` in the DCSQ).

**Pixel data — 2 bits/pixel (4 colours), nibble-based RLE**, decoded per line:
- Read 4-bit nibbles (MSB first). For a run value:
  - 1 nibble `n`: if `n >= 0x4` → `count = n >> 2` (1–3), `colour = n & 3`.
  - else read another nibble → value `v` (0x04–0x0F): `count = v >> 2` (4–15), `colour = v & 3`.
  - else 3-nibble (count 16–63), else 4-nibble (count 64–255).
  - a 4-nibble code with `count == 0` = "**fill to end of line**" with `colour`.
- Byte-align (to a nibble boundary) at the **end of each line**.
- **Interlaced:** top field = even lines, bottom field = odd lines; `SET_DSPXA` gives both
  field data offsets. Rebuild the progressive 2-bpp bitmap from the two fields.

**Colours are indices 0–3**, mapped by the DCSQ (below) to a 16-entry palette. Colour 0 is
conventionally the transparent background; the others are pattern / outline / anti-alias.

---

## DCSQT — Display Control Sequence Table

A linked list of **DCSQ**s. Each DCSQ:
| off | size | field |
|----|----|----|
| 0 | 2 | `delay` — start time relative to the SPU PTS, in units of `delay * 1024 / 90000` s |
| 2 | 2 | offset to the **next** DCSQ (if it equals this DCSQ's own offset → last one) |
| 4 | … | commands, each 1 opcode byte + params, terminated by `0xFF` |

**Commands:**
| opcode | name | params | meaning |
|----|----|----|----|
| `0x00` | FSTA_DSP | — | forced start display (menu highlights) |
| `0x01` | STA_DSP  | — | **start** display |
| `0x02` | STP_DSP  | — | **stop** display |
| `0x03` | SET_COLOR | 2 B | 4× 4-bit palette indices for the 4 subpicture colours |
| `0x04` | SET_CONTR | 2 B | 4× 4-bit **contrast/alpha** (0 = transparent, 15 = opaque) |
| `0x05` | SET_DAREA | 6 B | display rect: start_x, end_x, start_y, end_y (12 bits each) |
| `0x06` | SET_DSPXA | 4 B | offsets to top-field & bottom-field RLE data (from SPU start) |
| `0x07` | CHG_COLCON | var | change colour/contrast mid-display (karaoke wipes) — skip in v1 |
| `0xFF` | END | — | end of this DCSQ's commands |

A typical subtitle = **one SPU with two DCSQs**: DCSQ0 (delay ≈ 0) issues STA_DSP +
SET_COLOR/CONTR/DAREA/DSPXA (show it); DCSQ1 (delay = duration) issues STP_DSP (hide it).
**Sync the delays to the video STC** (`av_sync`), the same clock the governor/audio use.

---

## v1 scope & decisions to make (write them down as you go)

- **Palette (the main deferral):** the real 4 colours + alpha come from the **IFO PGC
  palette** (16 YCbCr entries) which we do NOT parse yet. For v1 pick a **fixed default /
  high-contrast palette** (e.g. transparent bg + white fill + black outline) and honor
  SET_CONTR alpha; note IFO-driven colours as a follow-up (couples to the deferred nav
  work). Do NOT block subpicture on IFO parsing.
- **Bitmap storage (DECIDED — full-frame):** a full 720×480 2-bpp buffer is **~68 M10K**
  (720×576 for PAL is **~81 M10K**) — the "~9 M10K" here was a mis-estimate; the real figure
  is ~68/81, still within the 259/553-block budget. Full-frame (not DAREA-bounded) was chosen
  so the render read address is a plain add (a per-line row-base accumulator, **no multiplier
  in the hot path**) — trading plentiful M10K for scarce ALMs/routing in the congested region.
- **Blend location & the routing hotspot:** the blend lands in the **congested
  decoder→overlay display region** (design is ~81% ALMs, routing-marginal). Keep the
  renderer minimal; consult `docs/roadmap.md` "FPGA congestion / resource cleanup" and be
  ready to bake in a settled A/B toggle or two to make room. Validate empirically (does it
  route? does the chroma fringe stay gone?).
- **OSD control:** add `CONF_STR` options — subtitle **on/off** + **track select** (static
  list like `O68 Audio Track`; smart per-disc enumeration needs IFO → follow-up).
- **CHG_COLCON** (karaoke wipes) and **forced/menu highlights** (FSTA_DSP): out of v1 scope.

## Verification discipline (repo rule)

1. **Sim first.** Extract a real subpicture SPU from a VOB (a disc with subtitles; e.g. via
   the `tools/iso_nav_check.py`-selected VTS, or ffmpeg `-map 0:s`), feed it to a testbench,
   and verify the RLE decode + DCSQ parse + blend in iverilog before building.
2. `./build_release.sh --compile` → confirm it **fits/routes** (watch the ALM % and the
   fringe — the ISO navigator's first build failed at 226% ALMs from a bad memory inference;
   see `dvd-iso-navigator` memory for the "sync-BRAM, shadow the window" lesson).
3. Branch (`feature/subpicture`), Forgejo PR via `tea`, keep this doc + roadmap Phase 10
   updated. HW-test on a subtitle disc.

## References
- DVD-Video subpicture: the SPU/DCSQ format above (public docs: dvddecrypter/dvdsub specs,
  the ffmpeg `dvdsubdec.c` and VLC `spudec` are good cross-checks for the RLE + DCSQ).
- `dvd/ps_demux.sv` (substream routing), `dvd/av_sync.sv` (STC for show/hide timing),
  `dvd/debug_overlay.sv` (existing video-path overlay tap), `dvd/mixer`/display path
  (where the blend composites).
