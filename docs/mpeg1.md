# MPEG-1 video + MPEG-1 Layer II (MP2) audio — the missing DVD-spec codecs

**Status: ✅ HW-CONFIRMED (2026-08-24, branch `feature/mpeg1-codecs`, build
`DVD_mpeg1c`).** User-confirmed on the DE10-Nano: MPEG-1 NTSC (352x240) and PAL
(352x288) test clips (tools/make_mpeg1_test.sh) AND a converted real VCD
(tools/vcd_to_vob.sh) all play with correct video, good audio, A/V in sync.
★ THE HW-BRINGUP BUG (one round of silence): Quartus 17 mis-synthesizes
size-cast-of-expression forms — `signed'(27'(dq_p1 >>> 16))` became a ONE-BIT
operand in silicon while every Icarus sim was bit-exact. Found WITHOUT further
board cycles by simulating Quartus's own post-map functional netlist
(`quartus_eda --functional` + behavioral M10K/MAC models) — that netlist-cosim
flow reproduced the silence on the desk and pinpointed the mangled operand.
RULE: no `N'(expr)` size casts in RTL destined for Quartus 17; use explicit
part-selects / concats / $signed(). (Residual netlist-cosim deltas after the
fix were artifacts of the hand-written behavioral DSP/RAM sim models — real
hardware decodes correctly.) Fit (DVD_mpeg1 numbers; mpeg1c equivalent)
`releases/DVD_mpeg1_20260824_1150.rbf` (compressed 4.5 MB): clk_dec Restricted
Fmax **89.92 MHz @100C / 93.23 @-40C** (86 MHz gate PASS); **ALM 38,884/41,910
= 93 %** (+~3.0k vs the 86 % pre-feature baseline — inside the 2–3.5k estimate,
but now firmly in the seed-lottery zone: expect SEED sweeps on future growth);
DSP 100/112 (+3); **RAM blocks 504/553 = 91 %** (+96 vs baseline 408 — the MP2
PCM FIFO (PCM_AW=12), V ring, ROMs and the many small sync-read RAMs each cost
whole M10Ks; block RAM is now the second-tightest resource — shrink PCM_AW
first if a future feature needs blocks back). Per-piece status markers below. Companion docs: `docs/vcd_svcd_mpeg_reuse.md` (the earlier CDi_MiSTer
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
plan — user framing). ~~44.1 kHz (VCD) decodes correctly bit-wise but plays 8.8% fast
against the fixed 48 kHz NCO~~ — **✅ FIXED 2026-08-24** (`feature/vcd-svcd-playback`):
the output NCO now muxes on the MP2 header rate (44.1/48/32 kHz), see
`docs/vcd_svcd.md` §2c.

~~Out of scope (future VCD/SVCD)~~ — **✅ DELIVERED 2026-08-24**
(`feature/vcd-svcd-playback`, `docs/vcd_svcd.md`): MPEG-1 **system** stream parsing
(ps_demux auto-detects the pack flavour), .bin/.cue MODE2/2352 sector deblocking
(in-fabric, `dvd_iso_reader` raw mode), and the 44.1 kHz output rate all shipped.
Still out of scope: IEC 61937 MP2 passthrough (passthrough mode silences MP2).

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

**Status: ✅ IMPLEMENTED + SIM-VERIFIED (2026-08-24, this branch). ⏳ HW-confirm
pending; pixel-level TB (B.4 tier 2) still open.** All delta-list items below are
in; per-item notes record where the implementation deviated from this plan.

### B.1 Why the decoder refused MPEG-1 (fixed)

`rtl/mpeg2/vld.v` picture/slice decode required `sequence_extension_seen`, which
MPEG-1 never sets. The MPEG-1 picture-header motion fields (`full_pel_*`,
`forward/backward_f_code`) were parsed into wires but unconsumed. Both fixed —
all edits marked `// DVD-FORK FIX (mpeg1)`.

### B.2 The delta list (vld.v unless noted) — all ✅ done

1. ✅ **Mode flag** `mpeg1` (exported as a vld output): latched at every ACCEPTED
   picture start code as `~sequence_extension_seen`, cleared the moment any
   sequence extension parses. **Deviation from plan / robustness addition:**
   `sequence_extension_seen` is now also RE-ARMED (cleared) at every
   `STATE_SEQUENCE_HEADER` — 13818-2 sends the extension immediately after every
   sequence header, before any picture, so this is invisible to legal MPEG-2 but
   makes an MPEG-2→MPEG-1 splice with no intervening `sequence_end` re-detect
   correctly (the old clear-at-SEQUENCE_END-only left the flag stale). The
   picture-start gate is now just `sequence_header_seen`; the slice gate is
   `sequence_header_seen & (sequence_extension_seen | mpeg1)`.
2. ✅ **Extension defaults**: every affected loadreg renamed to a private `*_ld`
   net; the visible signal (module output and all internal consumers) is an
   `assign ... = mpeg1 ? <const> : *_ld` mux. Constants as planned
   (progressive_sequence=1, chroma_format=4:2:0, picture_structure=FRAME,
   frame_pred_frame_dct=1, intra_dc_precision=8-bit, cmv=0, q_scale_type=0,
   intra_vlc_format=0, alternate_scan=0, tff=0, rff=0, progressive_frame=1,
   `f_code_00/01={0,forward_f_code}`, `f_code_10/11={0,backward_f_code}`).
3. ✅ **size MSBs** [13:12]: muxed to 0 under `mpeg1` (same `*_ld` mechanism).
4. ✅ **macroblock_stuffing**: `vlc_tables.v` entry returns `{len=11, value=0,
   escape=0}` — a combination no real increment produces — and
   `STATE_NEXT_MACROBLOCK` consumes-and-stays on it when `mpeg1`
   (`macroblock_addr_inc_stuffing` wire). MPEG-2 keeps the old error behaviour
   via the unchanged `value==0` check (it now advances 11 bits before
   STATE_ERROR's start-code hunt — immaterial to error recovery).
5. ✅ **DCT escape coding**: `STATE_DCT_ESCAPE_B14` in mpeg1 mode advances 8 and
   treats getbits[23:16] as the signed 8-bit level; first byte 0x00/0x80 routes
   to new `STATE_DCT_ESCAPE_M1` (8'h7d) which forms +b / b−256 from the second
   byte (`dct_m1_neg` remembers which). `dct_coeff_valid_0` is suppressed at
   ESCAPE_B14 when the extension byte follows, so rld_wr_en still pulses exactly
   once per coefficient. **Note:** only the B14 path — B15 is unreachable in
   MPEG-1 (intra_vlc_format forced 0), so `STATE_DCT_ESCAPE_B15` stays
   MPEG-2-only.
6. ✅ **full_pel motion**: `full_pel_rd` (keyed on `motion_vector[2]` = the s
   index, against the per-picture header flags) halves the predictor at the
   stage-1 read; `full_pel_wr` (keyed on `motion_vector_5[2]`) doubles at every
   stage-6 write-back including the pmv_update0/1 copy arms. Wrap unchanged
   (stage-3 sign truncation on the full-pel value = MSSG's ±16<<r_size). The >>1
   is exact (stored PMVs are vec<<1, always even). ORed with `shift_pmv`, which
   is mutually exclusive with mpeg1 (FRAME + fpfd=1 ⇒ MV_FRAME). ⚠ Verified at
   parse level only: encoders (ffmpeg, the real VCD rip) never emit full_pel=1,
   so value-level verification waits for the B.4 pixel TB.
7. ✅ **D-pictures**: `skip_d_picture` (latched at STATE_PICTURE_HEADER0 from
   picture_coding_type) routes slice start codes to STATE_NEXT_START_CODE like
   drop_this_picture. **Addition beyond plan:** `update_picture_buffers` is also
   suppressed for a D header (`hdr_is_d_m1`, combinational off getbits like the
   drop test) so picbuf never rotates for a picture that delivers no data — the
   previous frame repeats.
8. ✅ **Mismatch control** (`rtl/mpeg2/rld.v`): mode-gated at the stage-4→5
   register — MPEG-1 oddifies every even nonzero coefficient toward zero, with
   the **intra DC exempt** (11172-2 2.4.4.1; `iquant_intra_dc` pipeline extended
   to stage 4). The mpeg1 flag rides the rld_fifo like its aux neighbours —
   **fifo word widened 31→32 bits** (`mpeg1` at the top of both the dct and
   quant layouts), new `mpeg1_wr/_rd` ports, threaded vld → rld_fifo → rld in
   `mpeg2video.v` (`mpeg1_es`/`mpeg1_es_rd`). Dequant/saturation shared,
   unchanged, as predicted. **Clarification recorded while writing the golden:**
   the MPEG-2 toggle hits coefficient 63 (the LAST of the block, par. 7.4.4
   note 1), not the last *nonzero* one — with an all-zero tail it materialises
   an extra ±1 at index 63.
9. ✅ **Slices spanning MB rows**: confirmed OK as-is (no change needed).
10. ✅ **PAL detect** (`dvd/emu.sv`): now `(vertical_size > 480) ||
    (vertical_size == 288)` — MPEG-1 PAL SIF is 352×288.

### B.3 Display path — mostly free (agent-verified)

The syncgen active window tracks the decoded size (`h_size<=horizontal_size`,
`v_size<=vertical_size`), so 352×240 yields a 352×240 DE window that **ascal
upscales full-screen on HDMI** — no in-core scaling needed for v1. Known non-HDMI
gaps at v1 (now closed, see below): analog dual-raster `re_interlace` hardcodes
720×480 (sub-D1 → quarter picture + garbage right/below), HUD/overlay geometry is
720-authored (clipped at 352), direct-video top-left quarter.

**✅ SIF ANALOG FILL — the mapped-out v2, ✅ HW-CONFIRMED 2026-08-24 (PR #2):
NTSC + PAL SIF fill the CRT cleanly, normal DVDs unregressed.** In-core 2× fill, gated on
`analog_eff` (HDMI-only rigs keep ascal's polyphase scale — HW-proven for MPEG-1):

- **Detect** (`dvd/emu.sv`): two independent 1-bit flags off the clk_dec size taps,
  2-FF synced (the `pal_det` pattern): `sif_h` = width ≤360, `sif_v` = height ≤288.
  `sif_hfill_eff / sif_v2x_eff = analog_eff & flag`. Independence means 352×480
  half-D1 gets horizontal-only fill, correctly. ~~Scope decision (user): SIF widths
  only~~ — **REVERSED 2026-08-24** (`feature/vcd-svcd-playback`): the width
  predicate is now `< 720`, so SVCD 480-wide and DVD sub-D1 704/544 all fill on
  analog (see `docs/vcd_svcd.md` §2d).
- **Horizontal** — `disp_hstretch` retarget: `disp_hdst_w = 720` and
  `hcrop_en |= disp_hfill_en` in `mpeg2video.v`; 352→720 (qstep 125) and Crop+SIF
  256→720 (qstep 91) both satisfy the module's upscale RATIO CONTRACT — zero
  changes inside the stretcher.
- **Vertical** — the dormant addrgen vscale walk armed as **mode 2**
  (`dvd/resample_addrgen.v`): `v_step=128`, `v_outlines = 2×source-lines` = an
  exact NN 2× line repeat (240→480 / 288→576; field path 120→240 per field). The
  rounded walk maps output line i → source `min(floor((i+1)/2), vsz-1)` (src 0
  once, src N−1 thrice — a half-line shift, invisible on a CRT). Mode 1
  (letterbox-NN) stays dormant and prunes.
- **Raster** — `mpeg2video.v` muxes ONLY the `syncgen_intf` size legs to the
  effective values (720 / doubled height); motcomp / resample / regfile keep the
  true decoded size (addrgen bounds + motcomp clipping depend on it). The 720×480
  modeline is untouched — no rate change, the A/V architecture never notices.
- **Overlay** — `crt_ov_map` reuses the crop inverse for the stretch (x0=0,
  hsrc=352, hextra=368; identity holds at any upscale ratio) and gains a closed-form
  `v2x_en` post-map for the line repeat (progressive `min((y+1)>>1, v_src_max)`,
  interlaced parity-preserving; 0xFFF bar sentinel preserved). The HUD un-clips as
  a side effect (full 720-wide DE window).
- **Sim**: `resample_chain_tb +sif=1` (every `+sif` run co-sims the addrgen
  `disp_y` walk against the 2× closed form — the `+linetag` memory-tag path was
  measured too elastic for an exact map check, see the TB's sif-walk comment;
  `+hgrad` 352→720 blend proof, `+crt` field path, `+vsmode=1` letterbox
  compose, `+siftog` mid-run enable toggle) and `crt_ov_map_tb` T1d/T6.
- **Accepted quirks**: the field path's final line clamps to vsz−1 and can cross
  field parity for one bottom line; hstretch stretches the mb-padded width (all
  real SIF widths are multiples of 16); one ascal re-init popup on HDMI when the
  fill engages (Letterbox-engage class); while analog is engaged HDMI sees the
  in-core 2× instead of ascal (Letterbox/Crop trade-off class).

### B.4 Verification

**Tier 1 (parse + value level) — ✅ DONE (2026-08-24), all green:**

- **`bench/dvd/vld_mpeg1_tb.sv`** (real vld + getbits_fifo + motcomp_picbuf with
  the freeze interlock; fixture-regen recipe in its header; `$fatal` on any check):
  - synthetic ffmpeg ES (`m1v_test.hex`, 352×240, `-bf 2`): 115 pictures
    (10 I / 30 P / 76 B), 0 vld_err, 961k DCT writes, every picbuf emission
    reads pf=1/rff=0/tff=0, size 352×240, mpeg1 latched — and the stream
    NATURALLY covers the escape paths (13,123 8-bit escapes, 60 double-byte);
  - same ES with `+REQ=1`: **76/76 B pictures dropped** (the drop_ps_lat trap
    fix verified — without it acks would be 0), every ack rff=0/field=0;
  - real VCD rip ES (`qg_video`, 352×240@25): long-run parse gate;
  - `+HAND=1`: embedded hand-assembled stream (bytes in the TB) with a
    BYTE-EXACT golden coefficient list covering macroblock_stuffing ×2 and all
    three escape-level forms (−1 direct, +133 via 0x00, −129 via 0x80).
- **`bench/dvd/rld_mpeg1_tb.sv`** (real rld_fifo + rld): hand-computed dequant
  goldens in BOTH modes over the same blocks — MPEG-2 coeff-63 parity toggle
  preserved ({10,14,1}/{128,20,1}), MPEG-1 per-coefficient oddification with
  intra-DC exemption ({9,13}/{128,19}); also proves the widened-fifo mpeg1 bit.
- **MPEG-2 regression**: `vld_drop_rff_tb` over an ffmpeg 720×480 MPEG-2 ES
  (`m2v_test.hex`), REQ=1 and REQ=0, output DIFFED against the same runs on the
  pre-change RTL — byte-identical. Full-`mpeg2video` iverilog elaboration error
  list also diffed vs pre-change: identical (15 pre-existing iverilog
  strictness errors, line numbers shifted only). `ps_chain_tb` green.
- **TB gotcha worth keeping:** `getbits_fifo` starves ~2 words before true EOS
  (it can't expose the tail bits without a refill) — hand vectors need trailing
  zero-word padding, and file runs stop at `+MAXPIC` a few pictures short of
  the stream end.

**Tier 2 (pixel level) — ❌ still open:** new `bench/dvd/mpeg1_decode_tb.sv`
(full `mpeg2video` + behavioural framestore + PPM dump) vs ffmpeg golden frames
(`-f rawvideo -pix_fmt yuv420p`), bounded-error compare (IDCT precision) via a
new `tools/frame_cmp.py`. New infrastructure (no full-decoder pixel TB exists in
the repo). This is also where **full_pel motion gets value-level verification**
(no encoder emits full_pel=1, so tier 1 can only prove the parse) and where the
in-loop effect of the mismatch-control difference is visible.

---

## §6 Known limitations / follow-ups

- ~~44.1 kHz MP2 (VCD) plays 8.8% fast (fixed 48 kHz NCO)~~ — **✅ FIXED
  2026-08-24** (`feature/vcd-svcd-playback`): the NCO muxes on the MP2 header rate
  (44.1/48/32 kHz), glitch-free at drain re-arm; see `docs/vcd_svcd.md` §2c.
- MP2 passthrough (IEC 61937 Pc=0x0004) not implemented; passthrough mode silences
  MP2 (correct fallback).
- MPEG-2 multichannel extension (attr format 3) stays unsupported (HUD notice).
- Analog CRT with SIF sources: ✅ fixed by the in-core 2× fill (B.3,
  ✅ HW-CONFIRMED 2026-08-24, PR #2). ~~Wider sub-D1 MPEG-2 (704/544) still shows
  thin stale re-interlacer columns~~ — **✅ FIXED 2026-08-24**: the fill predicate
  widened to `< 720` (`feature/vcd-svcd-playback`, `docs/vcd_svcd.md` §2d).
- MPEG-1 aspect_ratio_information is a pixel-AR table (differs from MPEG-2 DAR
  codes) — v1 maps to 4:3 (DVD MPEG-1 is 4:3 by spec).
