# MP2 on the shared audio engine (the rest of scenario E)

**Status (2026-10-03): ✅ M0 done (the model is the RTL's contract on all 89 gate streams); ✅ M1 done (the program and its emulator, bit-exact on all 89, every op's decomposition proved); ✅ M2 done (the RTL, bit-exact op for op and pair for pair on all 89; A/B against `mp2_decode`); ✅ M3 wired in; ✅ M4 fit (−825 ALM by entity) and HIL (the VCD and two DVD MP2 tracks play, correlation ≥ 0.9986 with `mp2_decode`'s). ✅ MERGED (PR #150, stacked on PR #149 and PR #148).**

**Why.** The engine built for DTS already runs AC-3 (`docs/ac3_engine.md` W1) and DTS
(`docs/dts_decoder.md` P2/P3). `dvd/mp2/mp2_decode.sv` is the last hardwired decoder:
839 ALM, 37 M10K, 5 DSP in core (the DTS build's fit, 2026-10-03). Moving it onto the
engine is estimated at **−400 … −600 ALM, about −15 M10K, −5 DSP**. There is no fit
pressure (~1,060 ALM spare with DTS in), so this is headroom for later features, not a
need.

**The risk is VCD.** Video CD and SVCD audio is MP2, at 44.1 kHz too, so a regression
reaches every VCD. Hence the same discipline as AC-3: the new path must be
**bit-identical to `mp2_decode`**, scored A/B on the same streams, not "close to a
reference".

## The contract

`mp2_decode` is bit-exact against `tools/mp2_ref.py` (`bench/dvd/run_mp2.sh`), an
integer-only model whose header states the fixed-point contract. The engine reproduces
it exactly:

| Step | Arithmetic | On the engine |
|---|---|---|
| dequantise | `s = (x << (25 − nb)) + (1 << (24 − dsh))`, `(s × C_q16) >> 16` → Q2.24 | one multiply |
| scale | `sat27((s × SCF_q20) >> 20)` | one multiply; S needs **27 bits** (X is 25 today: widen, +1 M10K) |
| matrix | `V[i] = sat32((Σ_k N_q14[i][k] × S[k]) >> 14)` | 2,048 MACs per channel per 32 samples (N 16-bit × S 27-bit fits) |
| window | `pcm = sat16((Σ_16 D_q16 × V + 2^24) >> 25)` | **V is 31 bits**, over the 27×27 multiplier: two passes, low halves then high halves, joined through DTS's carried-sum buffer. No product shift is needed (M1 below) — 1,024 MACs |

- Grouped samples (3/5/9-level) come out of the sequencer's divider. The model takes the
  LOW digit first (`code % nlevels`, then `//=`), which is the divider's own order.
- Mono: `mp2_decode` synthesises channel 0 only and duplicates it (bit-identical to the
  model, which synthesises a duplicated channel 1). The engine does the same.
- Dual channel, joint (intensity) stereo: as the model.

**Cycles:** ~3,100 MACs per 32 output samples per channel. At 48 kHz stereo that is 36 ×
2 × 3,100 ≈ 221K per 24 ms frame of 648K cycles, about 34 % + the parse, ~40 %. Lower
at 44.1 and 32 kHz. The factorised transform (DTS's half IMDCT) would be ~3× cheaper
but rounds differently: rejected, because bit identity is the VCD safety net.

## New engine resources (estimate)

- **Datapath:** nothing new. Both saturations are provably dead (M1), and the window's
  split needs no product shift (M1). What is new is control: the MDQ, MSYN and RCLR
  states, their address generators, and the operand muxes.
- **V ring:** 2 channels × 1,024 × 32 bits. DTS's IMDCT ring (1,024 × 24) widens to
  2,048 × 32 and is shared (+4 M10K).
- **ROMs:** N (2,048 × 16, 4 M10K; symmetry could halve it), D (512 × 18), SCF (63),
  C / D-shift by class, the allocation tables (B.2a–d).
- **Microcode:** header, table select, allocation, scfsi, scalefactors, 12 granules.
  The program ROM holds 1,292 of 2,048 words today, so it may need 4K (+8 M10K).
- **Freed:** `mp2_decode` (839 ALM, 37 M10K, 5 DSP), minus its PCM FIFO, which STAYS:
  it carries half the DTS ADPCM codebook at power-up (D4), and it becomes the MP2 output
  FIFO.

## Plan

- **M0 — the model and the corpus.** `mp2_ref.py` is the model (already bit-exact
  against the RTL). Build the gate set, local and never committed (`~/mp2-streams/gate`,
  `$MP2_TEST_DIR`): real VCD windows, DVD MPEG-audio tracks from the library, and
  synthetic streams for every rate, mode and allocation table. Then a census of what
  the real material uses.
- **M1 — the program and its emulator.** `dvd/dts/mp2.uasm`, `tools/mp2_isa.py`,
  bit-exact against `mp2_ref.py` on every stream; the cycle budget.
- **M2 — the RTL.** The vector ops (dequantise and scale, matrix, window with the split
  MAC), the sequencer's parts, and a gate `run_mp2_seq.sh`. Then **an A/B bench against
  `mp2_decode`**, every PCM pair, as `run_ac3_ab.sh` did for AC-3.
- **M3 — wire in.** `mp2_decode` out of `dvd_audio_decode`. Its PCM FIFO stays as a plain
  FIFO module (MP2 output + the codebook host). The output rate (`fs_o` → the NCO) comes
  from the program. Then `run_mp2`, `run_vcd`, `run_wav` and the chain benches.
- **M4 — fit and HIL:** VCD rips (44.1 kHz), a DVD MP2 track, and the rig's VCD path.

## M0 result (2026-10-03)

**The corpus** (`$MP2_TEST_DIR`, default `~/mp2-streams/gate`; local, never committed):

- `tools/mp2_scan.py --extract DIR`: three windows of every MPEG-audio stream in the DVD
  library (`$DVD_ISO_DIR`, title sets declaring audio coding mode 2) and of every VCD
  rip's `*Track 2*.bin` (`$VCD_DIR`). 17 streams from 3 DVDs and 3 VCDs.
- `tools/gen_mp2_streams.sh`: 72 synthetic `twolame` streams in `synth/`, covering
  32 / 44.1 / 48 kHz × stereo / joint / dual / mono × 32–384 kbit/s, with CRC variants.

**The census** (what real material uses): VCD is 44.1 kHz 224k, stereo and joint
(mode_ext 1–3), table B.2b. The DVDs are 48 kHz, 256k stereo (two discs) and 384k with
CRC (one disc). No real stream uses 32 kHz, dual channel, mono, or tables B.2c/d. Those
come from the synthetic set alone, so it is what keeps the engine honest there.
(2026-11-12: a real mono stream exists now, the ~10 s intro of the Philips CD-i Digital
Video discs, 192k 44.1 kHz, followed by a stereo movie on the same stream; issue #188,
`docs/vcd_svcd.md` §3b. It is not in the gate corpus. The same issue added `mp2_fs_ok`:
the output gate waits for the engine's first rate report after a reset.)

**The gate:** `bench/dvd/run_mp2_model.sh` writes a `mp2_ref.py` fixture of 24 frames
for each stream and runs `mp2_decode_tb` on it. **89 of 89 bit-exact**, 27,648 samples
each. Corrupting one golden word fails the bench, so it can fail. This makes the model the
contract on the whole set, so M1's emulator is scored against `mp2_ref.py`, and M2's RTL is
scored both against the model and A/B against `mp2_decode`.

## M1 result (2026-10-03)

`dvd/dts/mp2.uasm` (236 words, assembled after DTS's and AC-3's programs: 1,528 of the
ROM's 2,016 words) and `tools/mp2_isa.py`. The gate is `tools/test_mp2_isa.py`.

- **[1]** 89 of 89 gate streams are bit-exact against `mp2_ref.py`: every PCM pair, 24
  frames each, no refusals. Every MDQ and MSYN is computed twice: once the way the RTL
  will (below), and once through the model's own `requantize` and `synth`. The emulator
  raises on any difference, so the decomposition is proved on every op of every stream.
- **[2]** The worst frame is 53.6 % of real time (48 kHz dual-channel 384k: 295K cycles
  of 648K). That includes `CYC_HEADROOM` 1.25 on the three new ops, which are modelled
  until M2. The synthesis is about 226K cycles a frame; the parse and the codes are about
  56K.
- **[3]** The generated images match (`tools/dts_isa.py --asm --check` covers all three
  programs).
- **[4]** Six refusals are checked: a descriptor length that is not the header's
  (`E_LEN`), a bad sync, Layer I/III, free format, the reserved rate, and a good frame
  decoding after a refused one.
- **RED:** 9 microcode mutations, each tied to the stream feature it needs (CRC, mono,
  B.2b, B.2d, joint ×2, scfsi 3, an allocation that drops between frames, the
  grouped-digit order). All 9 bite.

### Decisions

- **No new sequencer unit.** The codes are read in microcode. A grouped code splits by
  subtraction: d2 = code / n² first, then d1 and d0. That is at most 8 + 8 iterations
  for a valid code, and up to 12 for an invalid one, which is decoded as the model and
  `mp2_decode` decode it. AC-3's divider is reachable only from its own units, and it
  was not needed.
- **MDQ** (`a0` X address {k, ch, sb}, `a1` x16, `a2` d16, `a3` class, `a4` scalefactor
  index): `S = floor(floor((x16 + d16)·C / 2^7)·SCF / 2^20)`, where
  `x16 = (q << (16 − nb)) ^ 0x8000` and `d16 = 2^(15 − dsh)`. `(x16 + d16)·2^9` is the
  model's `s` exactly. The engine issues `x16·C` and `d16·C` into one accumulator, so
  there is no 17-bit adder. C (17 bits) and SCF (22 bits) cannot be passed in a 16-bit
  register. M2 puts them in `icoef`, whose 113 words sit in a block that holds 256 at no
  extra M10K.
- **Both saturations are dead, by proof.** |S| ≤ 33,553,920 < 2^25, and |V| ≤ 2^30:
  row 48 is the extreme, all ±16384, so Σ|N| = 2^19. The emulator asserts both bounds on
  every op. So the RTL omits `sat27` and `sat32`, but V needs **31 bits**. The ring
  becomes 2,048 × 32 (7 M10K; DTS keeps its 1,024 × 24 view in the low half).
- **The window without a product shift.** First the low pass,
  `L = Σ D·(V & 0xFFFF)`, carried as `floor(L / 2^16)` in DTS's `b2` buffer. Then the
  high pass, `H = Σ D·(V >> 16)`, with that as an unshifted `init`, floored by 1,
  clipped to 24 bits, and sent through DTS's existing PCM stage,
  `sat16((p + 128) >> 8)`. This equals the model's `sat16((T + 2^24) >> 25)` because
  `floor((H·2^16 + L) / 2^17) = floor((H + floor(L / 2^16)) / 2)` and
  `floor((floor(T / 2^17) + 2^7) / 2^8) = floor((T + 2^24) / 2^25)`. Both identities
  are checked on every slot, and on 2M random cases offline. The cost is no new
  shifter and no PCM-stage mode.
- **Zero state.** `RCLR` at MP2's RESET zeroes the ring and the carried sums, as
  `mp2_decode` clears V after every reset. `XCLR` once a frame zeroes the sample
  region: a frame's allocation holds for all 12 granules, so an unallocated subband
  reads 0 in every slot, and the `noclr` arm proves that a stale one leaks.
- **fs** goes out on MSYN's `a2`. The engine latches it with the pairs it plays, so the
  NCO change and the PCM arrive together, and M3 needs no ISA change.
- **E_LEN:** a frame whose descriptor length is not `144000·br/fs + padding` is refused.
  `mp2_reframer.sv` locks the same formula; M3 checks that seam.
- **The constant ROM is full:** 997 of 1,024 words. The per-class tables are packed
  three words a class.

### M2 must do (recorded so it is not rediscovered)

- **`codec` becomes 2 bits** (DTS / AC-3 / MP2) through `dts_seq`, `dts_top` and
  `audio_engine` (its codec request and busy handshake), and `dvd_audio_decode`.
  `UC_MP2_RESET` / `UC_MP2_FRAME` are already in `dts_ucode.svh`. Every new or widened
  port gets a tie-off in every bench.
- **DTS's RESET must also run RCLR.** MP2 now writes the ring and `b2`, so without it a
  DTS track after an MP2 track plays about 512 samples of stale V. The extra DTS word
  shifts every DTS pc; the generated images follow, and `run_dts_seq` and `run_dts`
  re-score it.
- **X widens to 27 bits** (S is 26 bits signed, with margin). DTS and AC-3 keep reading
  `[24:0]`. Check the benches' X checksums, which mask at 25 bits.
- N ROM: 2,048 × 16 (4 M10K). It could be halved: `N[16−j] = −N[16+j]` and
  `N[48−j] = N[48+j]` hold exactly in the integer table, at the cost of a negate
  (about 17 ALM). The D ROM is 512 × 18 (1 M10K).

### M3 heads-up

- `check_dts_wiring.py` `[copy]` and `cb_copy_tb` name `mp2_decode` / `mp2_decode_inst`
  as the D4 codebook host. The host FIFO must survive `mp2_decode`'s removal, and both
  gates need re-pointing.
- Known divergence, model vs `mp2_decode` (not the engine): a stream that switches from
  mono to stereo mid-stream. The model advances channel 1's ring in mono, while
  `mp2_decode` and the engine do not. No gate stream does this.
- Error recovery differs by design. `mp2_decode` hunts byte-wise and resets itself
  (clearing V) on a bad header after sync. The engine refuses the frame and keeps its
  state. Identity is claimed on valid streams only.

## M2 result (2026-10-03)

The RTL is in `dvd/dts/dts_vec.sv` (MDQ, MSYN and RCLR; X widened to 27 bits, the ring
to 2,048 × 32, the offsets to 10 bits, `icoef` to 256 deep with C at 128 and SCF at 160,
and two new ROMs, N 2,048 × 16 and D 512 × 18). `dts_seq` and `dts_top` take a 2-bit
`codec` (0 DTS, 1 AC-3, 2 MP2), and `dts_top` exports `mp2_fs`.

- **`bench/dvd/run_mp2_eng.sh`:** for all 89 gate streams, 2 frames each, the sequencer
  trace (`dts_seq_tb +codec=2`: every register write and store) and the whole engine
  (`dts_top_tb +codec=2`: after every vector op, X, the ring and the carried sums by
  checksum at MP2's widths, plus every pair and the counts) match the emulator. The
  worst timed frame is **45.5 %** of real time. Further arms: stalls with
  back-pressure, mono under heavy back-pressure, a refused short frame, and RAMs that
  start as garbage (`+dirty`). **18 mutations, each caught by its own arm.** One more was
  examined and recorded as equivalent on this corpus: synthesising channel 1 in mono,
  which leaves its zero ring unchanged.
- **`bench/dvd/run_mp2_ab.sh`:** `mp2_decode` and the engine run on the same bytes, and
  every pair is compared directly, with no model in between. Two mutations must fail it.
- **The other programs:** DTS's RESET now runs RCLR. A DTS track after an MP2 one
  would otherwise start on MP2's ring; `run_dts.sh` arm D1 (`+dirty`) and mutation V19
  prove the clear. Every DTS and AC-3 gate (`run_dts`, `run_dts_seq`, `run_ac3`,
  `run_ac3_seq`, `run_ac3_ab`, `run_dts_dec`, `test_dts_isa`, `test_ac3_isa`) and
  `run_mp2` stay green with the widened RAMs.
- **An aside:** mutation V8 in `run_dts.sh` had silently stopped running when AC-3's
  REMAT (A2c) duplicated its anchor line. A same-line comment makes the anchor unique
  again.
- **MDQ's floor by 7 bites only when nb ≥ 10.** `x16 + d16` is a multiple of
  2^(16 − nb), so for nb ≤ 9 the floor is exact. Mutation M2 therefore runs on a stream
  that uses a 1,023-level class or finer; on others it survives harmlessly.

## M3: wired in (2026-10-03)

- **`dvd_audio_decode`:** an MP2 frame is an engine frame (`eng_frame`). `eng_codec_req`
  is now 2 bits (1 AC-3, 0 DTS, 2 MP2), and `audio_engine` carries them through. The
  engine's pairs go through DTS's serialiser into `lpcm_unpack`'s FIFO (`cur_codec` ←
  T_LPCM, `quant` forced to 16-bit while `eng_pcm`). The stall watchdog watches MP2 as
  it watches DTS. `mp2_decode` is gone, with its own FIFO, byte FIFO, bit reader and
  self-heal. A frame the engine cannot decode is refused and drained, with no reset.
- **D4:** the half of the DTS ADPCM codebook that `mp2_decode`'s PCM FIFO carried at
  power-up now lives in `dvd/dts/cb_host_ram.sv`. That is the same 4096 × 32 words,
  read-only, with the copier's host contract unchanged. `check_dts_wiring.py` and
  `cb_copy_tb` point at it, and `run_cb_copy.sh` M3 mutates its step.
- **The rate:** a new op, **MFS** (29), carries the header's sampling frequency as soon
  as the header is accepted. That is before any of the frame's PCM, so the drain gate
  never opens on a stale rate, which it could have done had the rate waited for the
  first MSYN, ~5K cycles later. `dts_top` latches it (`mp2_fs`), and `nco_fs` takes it
  while `mp2_active`.
- **The frame contract, revised:** `mp2_reframer` cuts at a sync only once the header's
  length has passed. So junk after a frame (no sync follows) is appended to that frame,
  and `mp2_decode` plays such a frame and hunts past the junk. The program now refuses
  only a frame **shorter** than its header (`E_LEN`). A longer one is decoded, the rest
  is drained, and CNT counter 0 counts it, so the drop is visible. `test_mp2_isa.py` [4]
  checks both, and the RED `lenexact` arm shows an exact-length check would refuse it.
  `run_mp2_eng.sh` L1 runs it in RTL.
- **Benches:** every audio-chain compile list names `cb_host_ram.sv` in place of
  `mp2_decode.sv`. `mp2_chain_tb` and `vcd_chain_tb` snoop `lpcm_aud_valid`. `DVD.qsf`
  drops `mp2_decode`, `bit_fifo` and `bit_reader` and adds `cb_host_ram`.
- **Results so far:** `run_mp2.sh`, including the full chain (VOB → `ps_demux` →
  reframers → ring → `dvd_audio_decode`: 13,824 pairs bit-exact against the model),
  `run_vcd.sh` and `run_wav.sh` pass, as do `check_dts_wiring.py` and
  `test_mp2_isa.py`. **The whole regression set is green** on `d349c56` plus the anchor
  fix (`64f3b55`): `run_stc_freerun`, `run_aud_retime`, `run_dts_dec --red` (D1 and D6's
  anchors re-pointed at M3's rewritten lines), `run_cb_copy --red`, `run_mp2_eng --red`,
  `run_mp2_ab --red` (all 89 streams, 12 frames each, pair for pair against
  `mp2_decode`), `run_dts_seq`, `run_ac3_seq`, `run_ac3_ab`, `run_dts`, `test_mp2_isa`,
  `check_dts_wiring` and `lint_undriven`.

## M4: fit and HIL (2026-10-03)

**Fit** (`releases/DVD_mp2engine_20261003_2332.rbf`, SEED 1, clean tree at `d349c56`):

| | v0.8.0 (re-cut, SEED 7) | the last `ac3engine` build | `dev-mp2engine` |
|---|---|---|---|
| ALM | 40,793 (97 %) | 40,848 | **38,791 (93 %)** |
| M10K | 512 | 527 | 517 |
| DSP | 95 | 92 | 87 |
| clk_dec 100 °C / −40 °C | 90.87 / 90.44 | 89.98 / 91.19 | 91.46 / 88.40 MHz (gate 86) |

- **By entity, MP2's move is about −825 ALM.** `mp2_decode` (878, including its bit
  reader) is gone. `audio_engine` grew only 4,627 → 4,674, and `cb_host_ram` is 6.
  The estimate was −400 … −600. It came in better because the window's split and MDQ's
  decomposition reuse the datapath as it was, and the sequencer gained no unit.
- **The whole fit falls 2,057** against the previous build. The extra ~1,200 is packing:
  Quartus reports a 93 %-full design differently from a 97 %-full one, so count the
  entity figure.
- **Against v0.8.0 the whole fit is −2,002 ALM.** That span also contains PRs #144 and
  #145, the AC-3 front end's move (W1, about −290) and the DTS decoder (P2 + P3, about
  +550).
- **M10K:** −10 against the previous build. `mp2_decode`'s 37 are gone. Its 16-block PCM
  FIFO stays as the codebook host, and N, D, the widened ring and X are new.

**HIL** (the HIL rig; a `.sim`-local script, three clips cut from the local media).
Each clip ran through the old build first, the `ac3engine` build with `mp2_decode`, as
the control, then the new build. Each capture was then cross-correlated with the
other build's.

| Clip | Old | New | Correlation | Engine frames / refused |
|---|---|---|---|---|
| VCD, 44.1 kHz 224k joint stereo (MPEG-1 `.mpg`) | −15.8 dBFS | −16.4 dBFS | **0.9994** | 1,077 / 0 |
| DVD VTS, 48 kHz 256k stereo (`.VOB` slice) | −18.9 | −18.9 | **0.9986** | 430 / 0 |
| DVD VTS, 48 kHz 384k with CRC (`.VOB` slice) | −26.3 | −26.3 | **0.9998** | 305 / 0 |

- On the control arm `eng_frames` stays 0 (it is `mp2_decode`), and on the new one the
  engine counts every frame and refuses none.
- **The rate is right.** A 44.1 kHz stream played on a 48 kHz NCO would be stretched by
  8.8 % and could not correlate at 0.9994. So MFS reaches the NCO in time.
- The VCD pair's 0.6 dB level difference and its large lag are the two captures'
  different windows of a 75 s clip, not a level change. The DVD clips, captured whole,
  agree to 0.0 dB.

**By ear (2026-10-03, the maintainer, on the rig):** every codec on this build.

- MP2: the full *ew-dino* VCD at 44.1 kHz, and the three MP2 clips.
- AC-3: *Men in Black*, a 5.1 downmix.
- DTS and AC-3: *Ultimate T2*, tracks 1 ↔ 2 switched repeatedly.
- The MP2 → DTS handoff, a VCD and then T2 on its DTS track.
- LPCM and WAV.

**No issues with audio.** That is ✅ HW-CONFIRMED.

Merged as PR #150, stacked on PR #149 (AC-3 + DTS P2/P3) and PR #148 (DTS P0/P1).
