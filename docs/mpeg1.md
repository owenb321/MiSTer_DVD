# MPEG-1 video + MPEG-1 Layer II (MP2) audio — the missing DVD-spec codecs

**Status: IN PROGRESS (2026-08-23, branch `feature/mpeg1-codecs`).** Per-piece status
markers below. Companion docs: `docs/vcd_svcd_mpeg_reuse.md` (the earlier CDi_MiSTer
eval — note its framing is superseded, see "Scope decision" below), `docs/experiments.md`
"VCD / SVCD playback" (the original delta list).

## Scope decision (supersedes the VCD-only framing)

MPEG-1 video and MP2 audio are **DVD-Video-legal codecs**, not just VCD codecs: a DVD
title set may carry MPEG-1 video (352×240/352×288, ≤1.856 Mbps) and MPEG audio
(Layer II, 48 kHz) — MP2 was the mandatory-ish PAL-region codec of the early DVD era.
So this support goes **into the DVD core itself, always compiled** — the
`` `ifdef MPEG1 ``/zero-ALM-delta criterion in `docs/vcd_svcd_mpeg_reuse.md` §3 was
written for a hypothetical VCD spin-off and does not apply to this work (user decision,
2026-08-23: "implement the missing DVD spec codecs"). What *does* still apply from that
doc: the fabric-fit risk management (measure, gate with `tools/fmax_check.sh`), the
pure-HDL rule (no soft CPU — don't import CDi's RISC-V), and pl_mpeg/CDi as reference
material only.

In scope: DVD-compliant MPEG-1 video (both resolutions, D-pictures excluded — DVD
forbids them), MP2 **stereo/mono/intensity-stereo at 48 kHz** decode to the existing
stereo output (MP2 5.1-surround multichannel extension = format 3 stays unsupported;
it is backwards compatible so the core stereo stream decodes fine and that IS the
plan — user framing). 44.1 kHz (VCD) decodes correctly bit-wise but plays 8.8% fast
against the fixed 48 kHz NCO — a future-VCD item, see §6.

Out of scope (future VCD/SVCD): MPEG-1 **system** stream parsing (VCD pack/PES headers
differ from DVD's MPEG-2 PS; ps_demux is MPEG-2-PS-only), .bin/.cue Mode2 sector
deblocking, 44.1 kHz output rate, IEC 61937 MP2 passthrough.

## Test material

- **Real VCD rips** (bin/cue, MODE2/2352 track 2) in the user's local video library
  (`~/Videos/vcd/` on the dev machine — not committed): MPEG-1 352×240 @29.97
  + MP2 44.1 kHz 224 kbps stereo. Extract the MPEG PS with a 24-byte-header strip per
  sector (form2 = 2324 data bytes), then `ffmpeg -c copy` per-ES. These are the
  real-world decoder vectors.
- **Synthetic DVD-spec VOB** (the compliance case — VCD is *not* DVD-compliant: 44.1 kHz
  audio + MPEG-1 system mux):
  `ffmpeg -f lavfi -i testsrc2=size=352x240:rate=30000/1001 -f lavfi -i sine=sample_rate=48000
  -c:v mpeg1video -b:v 1150k -c:a mp2 -ar 48000 -ac 2 -b:a 224k -f dvd out.vob`
  → MPEG-2 PS with MP2 on stream_id 0xC0, playable end-to-end through ps_demux.

---

## Part A — MP2 audio

### A.1 Golden reference model — ✅ DONE (tools/mp2_ref.py)

Bit-exact integer-only Layer II decoder defining the RTL fixed-point contract
(see the file header for the exact Q formats: dequant Q2.24, scf Q1.20, matrix
N Q1.14, window Q2.16, PCM `(acc + 2^24) >> 25` → s16). Validated vs ffmpeg float
decode: **max_err = 1 LSB** on real VCD audio (200 frames) and synthetic 48 kHz
(417 frames). `compare` subcommand is the gate (±2 LSB budget, same as AC-3 cosim);
`fixture` writes `frames.hex` + `pcm_golden.hex` for the RTL TB (bit-exact compare).
Window table `tools/mp2_window.py` = ISO Table 3-B.3 × 2^16 exact, provenance pl_mpeg
(MIT) via CDi_MiSTer.

### A.2 ps_demux routing (0xC0–0xC7) — ✅ DONE (sim-verified)

Implemented exactly as below; `bench/dvd/ps_demux_mp2_tb.sv` (6 scenarios) + all
existing demux TBs green. Original plan follows.

DVD MP2 rides PES stream_id 0xC0–0xC7 directly (NOT private_stream_1; no substream
byte, no sub-header — payload starts after the PES optional header). Today those IDs
fall into the `>= 0xBB` skip-by-length arm and are discarded. Edits (agent-verified
sites):

1. `S_HUNT` default arm: intercept `in_byte[7:3] == 5'b11000` **before** the `>= 0xBB`
   skip; track select = `in_byte[2:0] == aud_track` (stream_id low 3 bits — the 0xBD
   path compares substream_id low 3 bits instead); match → `aud_type_r <= T_MP2`,
   `S_PES_LEN_HI`; no match → existing skip.
2. The three header-exit branches (`S_PES_HDR_LEN`, `S_PTS`, `S_PES_HDR_SKIP`):
   third arm for MP2 → `first_aud_byte <= 1'b1; state <= S_AUDIO_DATA` (bypassing
   `S_SUBSTREAM_ID`/`S_AUD_SUBHDR`).
3. PTS, scramble-detect, pes_length bookkeeping: no change needed (already
   stream-id-agnostic).

**Type code: `T_MP2 = 2'd3`** (Option A). Code 3 ("unknown") never reaches the ring
with payload today, so it is free; no descriptor widening, no reframer/iec61937/ring
edits (`iec61937_wrap.is_codec` already excludes 3 → MP2 frames in passthrough mode
are popped + silenced, correct). A future distinct passthrough code would need the
3-bit widening (edit-site list in the 2026-08-23 session notes / audio agent report).

### A.3 mp2_reframer — ✅ DONE (sim-verified, `bench/dvd/mp2_reframer_tb.sv` 5 scenarios)

Mirror of `ac3_reframer`/`dts_reframer`, chained after dts_reframer in emu.sv:
regenerate `aud_frame_start` on the 11-bit 0xFFE syncword, with a **frame-length
lock** (11-bit sync is weaker than AC-3's 16-bit, so the lock is more necessary):
at header byte 2 parse `{bitrate_index, sampling_frequency, padding}` →
`frame_len = 144*bitrate/samplerate + padding` (Layer II; table ROM per rate).
Passes foreign types through untouched. Reset on `pipe_rst_n` like the others.

### A.4 MP2 decoder core — ✅ DONE (dvd/mp2/mp2_decode.sv, BIT-EXACT sim-verified)

Shipped as planned below, verified by `bench/dvd/run_mp2.sh`: PCM bit-exact vs
the golden model on 5 synthetic fixtures (48k stereo/noise/mono/44.1k/low-rate
table-c) AND 30 frames of real VCD content — every sample identical. Notable
implementation deltas vs the plan: one 10-cycle restoring divider extracts
grouped triplets (no DSP); the sync-read one-cycle-wait discipline matters
(two bugs the bit-exact TB caught: RAM outputs consumed a cycle early in the
scfsi/scf/sample walks, and a window-ROM index scaled 32x instead of 64x).
MP2 self-heal reset dumps the decoder's internal PCM FIFO (unlike AC-3 where
pcm_out survives) — acceptable, resets should be rare. Original plan follows.

Pure-HDL FSM in the AC-3 house style, single clk_sys 27 MHz domain, **all tables in
sync-read M10K** (the recurring LUT-RAM lesson), serialized MACs on shared DSPs (the
CDi/pl_mpeg serial-MAC pattern). Budget: 1152 samples/frame @48 kHz = 24 ms = 648k
cycles; synthesis filterbank ≈ 92k MAC/frame/ch (matrixing 64×32 + window 512 per
32-sample slot × 36 slots) → ~28% of one serial MAC's budget for 2ch. Structure:

- `mp2_front.sv` — reuses `dvd/ac3/bit_fifo.sv` + `bit_reader.sv` (codec-agnostic);
  parse FSM: header → alloc (table select by (fs, bitrate/ch)) → scfsi → scalefactors
  → 12 granules × (triplet read, dequant `C*(s'''+D)` + scf multiply) → synthesis.
- Table ROMs: alloc tables (3-B.2a–d), C/D constants, scf (63×21), matrix N (64×32×16b
  = 2 M10K), window D (512×18 ≥1 M10K).
- V ring: 1024 × 2ch × 32b = 2 M10K per ch.
- Output: `pcm_out`-style FIFO; contract = the dvd_audio_decode third-decoder contract
  (byte in + full backpressure; `aud_ce_play` pop; held `audio_l/r` s16; `aud_valid`
  one cycle after `aud_ce`; `err` output for the self-heal watchdog wrap).
- `` `ifdef MP2_COSIM `` async read taps on stage memories (alloc/scf/subband/pcm) for
  the Verilator cosim, mirroring `AC3_COSIM`.

Verification tiers (mirroring AC-3): (1) Icarus TB `bench/dvd/mp2_decode_tb.sv` over
`tools/mp2_ref.py fixture` output, **bit-exact PCM**; (2) later, optional Verilator
cosim vs a C reference (pl_mpeg) per the bench/ac3 pattern. Real-stream vectors from
the VCD rips + `tools/gen_test_stream.sh` MP2 recipes.

### A.5 dvd_audio_decode integration — ✅ DONE (sim-verified)

As planned: `cur_codec` (2-bit, replacing `cur_is_lpcm`), MP2 sink/write arms,
MP2 self-heal watchdog (progress = mp2_aud_valid), emu reframer chain +
DVD.qsf entries, HUD notice narrowed to format 3 (a format-3 track's
backwards-compatible MP2 core on 0xC0+n likely plays stereo now — notice kept
until HW-verified on a real MC disc). `dvd_audio_decode_tb` still green;
`bench/dvd/mp2_chain_tb.sv` runs a real `-f dvd` VOB through
ps_demux → all three reframers → audio_ring → dvd_audio_decode bit-exact.
NOT yet fixed here: the pre-existing `attr_a_sel` wiring quirk (emu drives it
with `aud_cur` not `aud_track_eff`) — separate follow-up.

`T_MP2 = 2'd3`; `sink_ready` third arm (`~mp2_full`); widen the 1-bit `cur_is_lpcm`
selector to a 2-bit `cur_codec` (5 consumer sites: audio mux, active_avalid, 2×
watchdog gating, discard); `mp2_wr` write enable; MP2 self-heal watchdog sharing the
AC-3 pattern. emu.sv: chain the reframer, and narrow the "unsupported audio format"
HUD notice (`attr_a_fmt == 2|3`) to **format 3 only** once MP2 decode lands — plus fix
the pre-existing `attr_a_sel` wiring bug (driven by `aud_cur`, should be
`aud_track_eff`) noted in the audio agent report.

Free staging win: MP2 frames landing in the ring with no decoder are popped+discarded
at full speed (sink_ready=1 for unknown), so the ps_demux routing can ship and be
HW-validated before the decoder exists — no wedge risk.

---

## Part B — MPEG-1 video

### B.1 Why the decoder refuses MPEG-1 today

`rtl/mpeg2/vld.v:641/674`: picture/slice decode requires `sequence_extension_seen`,
which MPEG-1 never sets. The MPEG-1 picture-header motion fields (`full_pel_*`,
`forward/backward_f_code`) are parsed into wires but unconsumed.

### B.2 The delta list (vld.v unless noted)

1. **Mode flag**: `mpeg1` = at picture-header time, `sequence_header_seen &&
   ~sequence_extension_seen`. Relax the two gates to accept it.
2. **Extension defaults** (output-side muxes on the loadreg nets when `mpeg1`):
   progressive_sequence=1, chroma_format=4:2:0, picture_structure=FRAME,
   frame_pred_frame_dct=1, intra_dc_precision=8-bit, concealment_motion_vectors=0,
   q_scale_type=0, intra_vlc_format=0, alternate_scan=0, tff=0, rff=0,
   progressive_frame=1, `f_code_00/01 = {1'b0, forward_f_code}`,
   `f_code_10/11 = {1'b0, backward_f_code}`.
3. **horizontal/vertical_size MSBs**: bits [13:12] load only in STATE_SEQUENCE_EXT —
   zero them when an MPEG-1 sequence header arrives (stale-value hazard after an
   MPEG-2 → MPEG-1 stream switch).
4. **macroblock_stuffing** (VLC 0000_0001_111, MPEG-1 only): currently decodes as
   error in `vlc_tables.v` `macroblock_address_increment_dec`. Add the entry +
   consume-and-stay in STATE_NEXT_MACROBLOCK.
5. **DCT escape coding**: MPEG-1 escape = 6-bit run + 8-bit level, with double-byte
   extension when the first 8 bits are 0x00 (level=+next8) or 0x80 (level=next8−256);
   total 14 or 22 bits vs MPEG-2's fixed 18 (run6+level12). New handling in the
   ESCAPE states (advance mux + level extraction), sign-extended 8-bit fits the
   existing 12-bit signed level path (max |level| 255 < 2047).
6. **full_pel motion**: per MSSG semantics — PMV kept in half-pel units; when
   `mpeg1 && full_pel_x`: `vec = (pred>>1) + delta`, wrap on `16<<r_size`, store
   `pred = vec<<1`. r_size muxing falls out of the f_code defaults in (2).
7. **D-pictures** (picture_coding_type==4): DVD/VCD-illegal; guard = treat like
   drop_this_picture (skip slices) rather than mis-decoding.
8. **Mismatch control** (`rtl/mpeg2/rld.v:415`): MPEG-2 sum-parity LSB toggle at
   EOB → MPEG-1 per-coefficient oddification (`if even, subtract sign`). The mpeg1
   flag rides the existing rld aux-variable path (alongside q_scale_type etc.).
   **Dequant formula needs NO change**: MPEG-2 with q_scale_type=0 computes
   `(2QF+k)·W·(2·code)/32` ≡ MPEG-1's `(2QF+k)·W·code/16`; intra DC via
   intra_dc_precision=8 ≡ MPEG-1's `8·QF`. Saturation ±2048 identical.
9. **Slices spanning MB rows**: OK as-is — `macroblock_address` is a linear
   frame-wide counter; skip runs crossing rows work naturally.
10. **PAL detect** (`dvd/emu.sv:3045`): `vertical_size > 480` misses 352×**288** —
    key on height 288/576 (or frame_rate_code).

### B.3 Display path — mostly free (agent-verified)

The syncgen active window tracks the decoded size (`h_size<=horizontal_size`,
`v_size<=vertical_size`), so 352×240 yields a 352×240 DE window that **ascal
upscales full-screen on HDMI** — no in-core scaling needed for v1. Known non-HDMI
gaps (deferred, documented): analog dual-raster `re_interlace` hardcodes 720×480
(sub-D1 → garbage right/below picture; v1 = force `analog_eff` off for sub-D1 or
document), HUD/overlay geometry is 720-authored (clipped at 352 — cosmetic),
direct-video top-left quarter. In-core 2× repeat via `disp_hstretch` retarget +
addrgen line-repeat is the mapped-out v2 if scaler softness disappoints.

### B.4 Verification

- Parse level: `vld_drop_rff_tb`-style run over a real VCD MPEG-1 ES (`qg_video.m1v`
  extract) — pictures must parse (today: stall after sequence header).
- Pixel level: new `bench/dvd/mpeg1_decode_tb.sv` (full `mpeg2video` + behavioural
  framestore + PPM dump) vs ffmpeg golden frames (`-f rawvideo -pix_fmt yuv420p`),
  bounded-error compare (IDCT precision) via a new `tools/frame_cmp.py`. This TB is
  new infrastructure (no full-decoder pixel TB exists in the repo).
- MPEG-2 regression: the same TB over an MPEG-2 ES + the existing suites must be
  unchanged; rld mismatch edit is mode-gated.

---

## §6 Known limitations / follow-ups

- 44.1 kHz MP2 (VCD) plays 8.8% fast (fixed 48 kHz NCO); future: NCO reparam per
  frame-header rate + av_sync AUD_HZ consistency (locations mapped in the audio
  agent report / `docs/fabric_audio.md`).
- MP2 passthrough (IEC 61937 Pc=0x0004) not implemented; passthrough mode silences
  MP2 (correct fallback).
- MPEG-2 multichannel extension (attr format 3) stays unsupported (HUD notice).
- Analog CRT with sub-D1 sources: see B.3.
- MPEG-1 aspect_ratio_information is a pixel-AR table (differs from MPEG-2 DAR
  codes) — v1 maps to 4:3 (DVD MPEG-1 is 4:3 by spec).
