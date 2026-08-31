# AC-3 decoder — scope, verification, durable decisions

The in-fabric AC-3 decoder (`dvd/ac3/*`) was developed in the standalone `MiSTer_AC3`
repo (now **archived**); AC-3 work continues in this repo. This file captures the
durable scope/decisions/verification knowledge from that repo so it isn't lost.

- **Module/interface/fixed-point detail:** `docs/ac3_decoder_architecture.md`.
- **How it's wired into the DVD core:** `docs/fabric_audio.md`
  (`dvd/dvd_audio_decode.sv`: `ac3_front` → `pcm_out`, 48 kHz, self-heal, downmix).

## Durable design decisions (don't silently overturn)

- **Strict full-fabric RTL.** No soft processor / microcoded sequencer — the
  irregular parse / bit-allocation path is hand-written FSMs. (The Han thesis uses a
  PicoBlaze for control; we use it for the *algorithms only*, not the architecture.)
- **Fail loud, never decode wrong.** Any syntax the datapath doesn't yet handle sets
  sticky **`err_unsupported`** (hardware) / `$fatal` (sim) rather than emitting
  garbage. As features land the fail-loud set *shrinks*, but an unhandled path always
  halts loudly until properly implemented and verified.
- **Golden reference = liba52 0.8.0.** Pass criterion = **bounded error** vs liba52's
  float PCM (fabric is fixed-point, so exact equality is impossible). Tolerance
  **±2 LSB @ s16**. Every coding tool gets a cosim/unit-TB check against liba52.

## Supported (decodes end-to-end; cosim + hardware verified)

- Plain AC-3 (not E-AC-3), **48 kHz**, **`acmod ∈ {1..7}`** — every channel mode
  except 1+1 — **`lfeon ∈ {0,1}`** (LFE parsed/dequantized but dropped from the
  stereo downmix, like liba52). All multichannel modes fold to stereo.

  **Downmix matrix**, MEASURED from liba52's own
  `a52_downmix_coeff(acmod, A52_STEREO, …)` rather than read off the spec:

  | acmod | bitstream order | Lo | Ro |
  |---|---|---|---|
  | 1 | C | C | C (duplicated by `pcm_out.mono`) |
  | 2 | L R | L | R |
  | 3 | L C R | L + clev·C | R + clev·C |
  | 4 | L R S | L + (slev·√½)·S | R + (slev·√½)·S |
  | 5 | L C R S | L + clev·C + (slev·√½)·S | R + clev·C + (slev·√½)·S |
  | 6 | L R Ls Rs | L + slev·Ls | R + slev·Rs |
  | 7 | L C R Ls Rs | L + clev·C + slev·Ls | R + clev·C + slev·Rs |

  ⚠ The easy thing to get wrong: a **mono** surround (acmod 4/5) is sent to BOTH
  outputs and takes an extra **−3 dB** (`slev·LEVEL_3DB`); a stereo surround
  **pair** takes `slev` unchanged. Confirmed by probing liba52 twice with
  different clev/slev to separate the dependence.

  Gates: `acmod{3,4,5,6}_*_640k.ac3` (generated) and `bbb_mono.ac3` (committed),
  all strictly checked at 2.0 LSB, plus real acmod-6 disc audio at 0.024 LSB.
- **Channel coupling** and **rematrixing** (stereo) — real DVD/broadcast stereo all
  use coupling. Per-block coupling-strategy changes including **ch0 uncoupled** (the
  first coupled channel isn't always ch0) are handled.
- **5.1 → stereo (Lo/Ro) downmix**, `cmixlev`/`surmixlev` honoured.
- Exponent strategies **D15/D25/D45 + reuse**; full bit-allocation; all mantissa bap
  classes.
- **Bit allocation** runs a per-bin masking loop; `bap_lookup` is **pipelined** off
  `compute_mask` (2026-06-28, `feature/ac3-drc-fix`). The single-cycle phases C_P1–C_P4
  used to do `compute_mask` (hthtab0 ROM + arith) **and** `bap_lookup` (baptab ROM + arith)
  in one cycle — two serial ROMs failing setup at the 27 MHz `clk_sys` by ~1.3 ns, which
  glitched audio ("static blips" on Matrix *and* BBB). A shared 1-deep `pend_*` stage now
  registers the mask+exponent and does `bap_lookup` the next cycle (phase 5 already used
  this split); terminal `done` waits in `C_FLUSH` for the lagged write to commit. Cosim
  bap/PCM byte-identical; all regression streams pass.
- **DRC (`dynrng`)** applied per block; **short blocks** (`blksw==1`, 256-pt IMDCT).
  > **Fixed 2026-06-28 (`feature/ac3-drc-fix`):** the `dynrng` *exponent* (`[7:5]`) is a
  > 3-bit **two's-complement** value (−4…+3), not a magnitude. The original code used
  > `shift = 9 − exp` (monotonic in the byte), which **inverts the exponent fold**:
  > attenuation codes (`exp ≥ 4`, the common case on dynamic DVD audio) were decoded as
  > **boosts**, scaling the output up to **16× → hard clipping**. On *The Matrix* 5.1
  > (substream 0x82, which carries `dynrng` on nearly every block) this clipped almost
  > continuously → "audio cuts out / front channels drop." Correct mapping:
  > `gain = (0x20|mant)/32 · 2^signed3(exp)`, i.e. `shift = 5 − signed3(exp)` ∈ [2,9];
  > **unity is `dynrng == 0x00`** (the parser's no-DRC default was corrected from `0x80`).
  > Verified by the liba52 co-sim on the real Matrix stream (gross 16× failures → only
  > sub-perceptual ≤11-LSB rounding residuals); all synthetic regression streams still
  > pass. Bug reproduced on the standalone `MiSTer_AC3` core too (same shared RTL), which
  > confirmed it was a decoder bug, **not** video-starvation. See `dvd/ac3/imdct_512.sv`
  > (`drc_shr`) and `dvd/ac3/audblk_parse.sv` (`dynrng` default).
- Fits Cyclone V comfortably: ~**40 % ALMs** standalone (post resource-minimization;
  ALMs are the scarce shared resource — trade ALMs→M10K aggressively).

## NOT supported — each currently **fails loud** (`err_unsupported`)

- **`acmod 0` (1+1 dual mono)** — deliberately still refused. It carries a
  SECOND `dialnorm/compr/langcod/audprodi` block in `bsi()` that the FSM does not
  walk, so accepting it would desync `bsi` and emit garbage rather than silence,
  which is strictly worse. Census: 4 frames on 1 disc out of 491.
- Non-48 kHz sample rates, E-AC-3, and a true multichannel (vs downmixed-stereo)
  output path. ⚠ Failing loud here means SILENCE: `err_unsupported` → `ac3_err` →
  an `ac3_front` self-heal reset every frame.

> **Debugging note (relevant to the 2026-06-27 choppy-AC-3 bring-up):** the **full
> Big Buck Bunny NTSC DVD AC-3 track is hardware-validated** in the standalone core
> (it's the `bbb_short_5p1.ac3` cosim vector — 5.1 / 448 kb/s, short blocks +
> ch0-uncoupled coupling). So BBB is fully in-scope: if `err_unsupported` /
> self-heal resets fire while playing BBB **in the DVD core**, suspect **`ps_demux`
> AC-3 extraction feeding corrupted/misaligned bytes**, not a decoder limitation
> (the old HPS liba52 path was very tolerant and masked feeding quirks a strict
> fabric decoder won't). Overlay rows 14/15 (reset/underrun counts) localize this.

## Verification suite (now in this repo — `bench/ac3/` + `tools/`)

The decoder's full regression harness was ported here from `MiSTer_AC3` (paths
rewritten `rtl/ac3` → `dvd/ac3`). All scripts verified working in this repo
2026-06-27.

- `bench/ac3/run_*.sh` — Icarus unit TBs: `run_bit_reader / run_audblk /
  run_exponent / run_balloc / run_mantissa / run_imdct / run_imdct256 / run_drc /
  run_pcm_out / run_sync_crc.sh`.
- `bench/ac3/run_front_cosim.sh` — **Verilator + liba52 full-chain cosim**
  (`Makefile.cosim`, `cosim_main.cpp`): same AC-3 frame into liba52 and the Verilated
  RTL, golden-checks geometry / exponents / bap bit-exact + bounded-error PCM, on
  ffmpeg-generated streams **and** the committed `vectors/bbb_short_5p1.ac3`.
- `tools/gen_test_stream.sh` — ffmpeg AC-3 stream recipes → `tools/streams/`
  (gitignored). ffmpeg emits **long blocks only**; short-block coverage comes from the
  committed BBB vector.
- `bench/ac3/vectors/bbb_short_5p1.ac3` — real-DVD vector (BBB 5.1, the exact content
  in the hardware bring-up), CC-BY 3.0 © Blender Foundation.

Requires **liba52 0.8.0** (golden) and **Verilator** for the cosim; Icarus alone
covers the unit TBs and the `dvd/`-side integration TBs (`bench/dvd/*`). `obj/`,
`obj_cosim/`, and `tools/streams/` are gitignored build artifacts. NOTE: `run_imdct.sh`
(and the cosim) *regenerate* the committed ROM `dvd/ac3/ac3_imdct_tables.svh` — it
regenerates identically today; re-run and re-commit it only when deliberately changing
twiddle/window widths.

> **Cross-check for the choppy-AC-3 bug:** `run_front_cosim.sh` PASSES bit-exact on the
> BBB vector here, i.e. the decoder is correct on that exact content. So the hardware
> choppiness is on the **feeding** side (`ps_demux` AC-3 extraction), not the decoder.

## Key references

- **ATSC A/52** — *Digital Audio Compression (AC-3, E-AC-3)*: normative frame syntax
  and every per-stage algorithm.
- **Han, Dapeng (2017)**, *FPGA Implementation of an AC3 Decoder* (MSc, Linköping):
  stage-by-stage pseudocode. (Uses a PicoBlaze for control — we don't.)
- **liba52 0.8.0** golden decoder; **ffmpeg `ac3dec.c` / `ac3_fixed`** as a
  second/cross-check. See `docs/references.md`.

## Coupled multichannel accuracy — a PRE-EXISTING gap, found 2026-08-31

While gating the new acmods it emerged that **coupled multichannel content
diverges from liba52 by ~40–210 LSB @ s16 on RAW per-channel output** (i.e.
before any downmix — the mismatch shows on ch2/ch3 as well as ch0/ch1), even
though exponents, bap and the coupling geometry/`cplco` are all bit-exact.

This is **not** introduced by the multichannel work and is **not** specific to
the new acmods: a coupled 5.1 (acmod 7) stream — the shipped, hardware-validated
path — shows it worse than acmod 6 does. It had gone unnoticed because the only
committed coupled-multichannel vector (`bbb_short_5p1`) has its PCM marked
informational for IMDCT-precision reasons, so nothing ever gated it strictly.
Coupled *stereo* (`sweep_192k`) passes strictly, so the gap is specific to
coupling with more than two channels.

Practically it is ~0.6 % of full scale and the 5.1 path has always sounded
correct on hardware, so this is an accuracy question rather than an audible
defect — but it is a real, measurable divergence and it is written down here
rather than left as a surprise. The new acmod vectors are therefore generated
at 640 kb/s (coupling off) so they gate the downmix rather than this.

Reproduce: encode any ≥3-channel stream at 448 kb/s with distinct per-channel
content (`tools/gen_test_stream.sh` has the `join=` recipe) and run the cosim.

## ⚠ Silent-silicon trap: SV functions in this decoder (2026-08-31)

The acmod 1..7 work shipped correct RTL that **simulated perfectly and produced silent
hardware**. Five `function automatic` helpers (`acmod_has_cmix`, `acmod_has_smix`,
`mixlfe_bits` — which called the other two — and `ac3_nfchans` in `ac3_parse` and
`audblk_parse`) are miscompiled by Quartus 17 here. Result: **acmod 1 and 5 were silent
on real discs while acmod 2, 6 and 7 played**, with no clean rule behind which survived.

What makes this worth writing down:

- **Every simulation gate was green**, including the Verilator/liba52 cosim decoding
  real mono and acmod-5 streams off real discs bit-exactly for 400 frames. Simulation
  could not have caught it and cannot prove the fix.
- **Quartus emitted no warning** for any changed module. A clean build log is not
  evidence here.
- The helpers took **only scalar arguments and read no arrays**, so this is broader
  than the previously recorded function-mediated-array-read hazard.

**The cheap technique that found it:** A/B two of our own builds. The mono track of a
real disc played on the build whose mono path was an inline ternary and was silent on
the build differing on that path *only* by using functions. One flash, decisive — reach
for this before the post-map netlist cosim.

All five are now plain wires / inline ternaries. Functions are **not** banned: `to_s16`,
`bin2gray`, `bndtab` and `compute_mask` ship and work. The rule is narrower — when
simulation says correct and silicon says broken, suspect a recently-added function
first.
