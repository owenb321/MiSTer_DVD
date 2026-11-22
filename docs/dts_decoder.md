# In-fabric DTS core decoder (`dvd/dts/`)

**Status (2026-10-03): ✅ P2 + P3 MERGED (PR #149; P0/P1 PR #148) AND PLAYING ON THE RIG**:
*Ultimate T2*'s DTS track decodes, correlating 0.922 with the disc's AC-3 track over the same
passage, and is clean by ear (the maintainer). ⏳ Open: a by-ear pass on more DTS discs. The
codebooks ride in three FIFOs' power-up contents and are copied once to DDR3 over `ram2`
(P2); the `T_DTS` arm sends DTS frames to the shared audio engine, which also runs AC-3
since `docs/ac3_engine.md` W1 (P3). See "P2 + P3 result" below. Earlier status, kept:
**✅ P1 BUILT (2026-10-02): the engine's RTL is bit-exact against the
emulator on all 34 gate streams. Standalone fit: 2,227 ALM, 31 M10K, 1 DSP,
35.8 MHz at the binding −40 °C corner. Worst frame 39.8 % of real time over 61,678 census
frames. Not wired into the core.** (Was branch `feature/dts-decode`, now PR #148.) ⏳ **Next: a maintainer decision.** The engine does not fit the core's
~1,125 spare ALMs on its own (§10 "P1b result"), so the order of P2 (codebook residency),
P3 (wiring) and the P4 reclaims comes first.

Today a DTS track is silent in `Decode PCM` mode: `dvd_audio_decode.sv` routes
`frame_type == 1` to a discard (`// DTS: discard`), and DTS is audible only through IEC 61937
passthrough to a receiver (`iec61937.md`, `hdmi_bitstream.md`). This note is the plan to
decode the DTS **core** to stereo PCM in the fabric, so a plain TV plays it.

## 1. Scope

- **In:** the DTS Coherent Acoustics **core** as DVD-Video carries it: 48 kHz, 16-bit
  big-endian frames (`dts_reframer.sv` already frames them), 768 / 1536 kbit/s, up to 5.1.
  Out: s16 stereo at 48 kHz on `AUDIO_L/R`, through the existing gate, PTS scheduling and
  re-time machinery.
- **Ignored (decoded as core only):** every extension — XCh (DTS-ES 6.1), X96, XXCH, XBR,
  and the EXSS substream. The core is backward compatible by design, so ignoring them
  is correct, not a fallback. A frame that carries one is **counted** (telemetry), never
  silently treated differently.
- **Unchanged:** `Audio Out = Passthru` still bitstreams DTS to a receiver.
- **Stock Main:** works. No file, no HPS process (D1, D4).

## 2. Decisions

### D1 — In fabric, not on the HPS (2026-10-02, maintainer)

An HPS route was costed first: the fabric sends DTS frames to a Main thread through a DDR3
ring, the thread decodes them with libdca or FFmpeg, and the PCM returns through a second
ring into a fifth codec arm. **Rejected.** It breaks the roadmap's first guiding principle
("self-contained `.rbf` — no HPS-side daemon", `roadmap.md`). It would work only with the
custom Main. And it adds a round trip that the dispatcher's in-band re-time (PR #141) and
hard-flush realign (PR #143) would have to cover with per-record epochs, which is exactly
where the stale-PTS class of bug lives. Kept here so the comparison is not re-derived.

### D2 — A microcoded sequencer plus hardwired vector ops on one multiplier

- **Sequencer:** a small register file and ALU, `GET n` from a bit-serial reader, a
  canonical-Huffman `VLC table` instruction, loads and stores to a parse record, constant
  ROM reads, branches, call and return, and `ERR code`. The whole parse is a ROM program.
- **Vector ops:** the heavy inner loops are hardwired and share one 27×27 DSP multiplier,
  one wide accumulator and one rounding, saturating shifter. They cover dequantisation,
  ADPCM prediction, VQ expansion, joint intensity, the subband-domain downmix and the
  32-band QMF synthesis.
- **Clock:** `clk_sys`, 27 MHz, the same domain as `audio_ring`, the 48 kHz NCO and the
  gate, so there is no CDC.

**Why microcode.** The DTS side info has many conditional fields: per-channel subband
counts, VQ start, joint intensity, transient modes, scale-factor and bit-allocation
codebook selectors, adjustment indices and per-subband prediction. As a hardwired FSM that
becomes a large mux tree (compare the AC-3 parse: `audblk_parse` + `bit_allocation` +
`mantissa_dequant` + `exponent_decode` ≈ 2,300 ALM). As microcode it is ROM words that can
be debugged in Python before any RTL runs. The cost is interpretive cycles (§4).

**Rejected: an FSM per stage**, the house style of `dvd/ac3/` and `dvd/mp2/`. The reason is
area (§4).

**Huffman unit: a binary-tree walk, not canonical decoding (measured 2026-10-02).** The
DTS core has **2,709 symbols** in 62 codebooks (FFmpeg `dcahuff.c`, excluding the LBR
tables), and the longest code is 16 bits. `tools/gen_dts_tables.py` assigns the codes
exactly as FFmpeg does and tests each book. **53 of the 62 are not canonical**: 50 have no
canonical structure in either bit sense and do not keep each length's codes contiguous
(`quant_index_9_0` alone has 49 runs of equal length in code order). So the cheap walk
(`code - first < count[len]`) cannot decode them. Instead, one node table serves every
book. Each internal node holds two entries {leaf, symbol or child index}, so there are
2,709 − 62 = 2,647 nodes of about 26 bits, about 7–9 M10K (it was estimated at 4). The
walk takes one code bit per step, two cycles with a synchronous M10K read, still
consuming bits as it goes. A code that matches no codebook can
only occur in a corrupt stream. It refuses the frame (silence, counted) rather than
un-reading bits.

### D3 — Stereo via a subband-domain downmix before synthesis

The 32-band synthesis filter is linear and identical for every channel within a frame
(`FILTS` is a per-frame flag). So `Σ g_c · QMF(x_c) = QMF(Σ g_c · x_c)`: downmix the
dequantised subband samples to L/R first, then run **two** synthesis filters, not up to
five. That turns the synthesis cost into the cost of MP2 stereo. Verified in FFmpeg:
`filter_perfect` is a frame-header field (`ff_dca_parse_core_frame_header`), and
`filter_frame_fixed` picks one prototype for every channel. The subband count is **per
channel** (`nsubbands[ch]`), so the downmix sums each band only over the channels that
code it; a band above a channel's count is zero for that channel.

**Caveats, accepted and recorded:**
- **Gain changes leave a transient.** The identity holds only while the gains are
  constant. If AMODE or the downmix coefficients change between frames, the QMF history
  was filtered under the old gains. The result is a bounded transient, a known deviation
  from mixing after synthesis.
- **Two-tier validation.** The RTL is bit-exact against our own fixed-point model. That
  model is within an LSB bound of FFmpeg's `BITEXACT` core path (`filter_frame_fixed`)
  mixed *after* synthesis (§6).
- ✅ **Measured (2026-10-02, `tools/dts_fixed.py verify`, `tools/test_dts_fixed.py`).**
  Mixing before synthesis is at most **1 LSB** at s16 from mixing after, with the same Q15
  gains. Terminator 2 (300 frames): RMS 0.11 LSB, 98.8 % of samples identical. A 1536 kbit/s
  5.1 window from *A.I.*: RMS 0.11. The seven synthetic fixtures: RMS ≤ 0.19. Stereo and
  mono are exact, because their gain is 1. The gate's bound is 1 LSB.
- ⚠ **RTL rule: after the sum/difference butterfly, both channels of the pair are mixed up
  to the LARGER of their two active band counts.** The downmix loop is bounded per
  channel to save cycles. But `L+R` carries R's content in bands above L's own count, so
  bounding L by its own count drops them. `tools/dts_fixed.py` did this at first and
  lost 3,459 LSB on `written_amode3`. FFmpeg's encoder always codes 32 bands on every
  channel, so the encoder-made sum/difference fixtures could not show it. The
  writer's uneven counts did. RED arm: `mix_own_bound`.
- ✅ **LFE is left out of the stereo downmix (decided by the maintainer, 2026-10-02).**
  This is the usual stereo-downmix practice, and the AC-3 path does the same. LFE is
  not subband-coded but decimated samples with their own interpolation FIR. The decoder
  still parses the LFE samples to advance through the frame, but never interpolates
  them, so the LFE FIR and its 256-tap table are not built.
- ✅ **The mix rule follows the AC-3 path exactly (decided by the maintainer, 2026-10-02).**
  These are `dvd/ac3/imdct_512.sv`'s effective levels at the A/52 defaults, because DTS has
  no mix-level fields:
  - clev = slev = 0.7071, zeroed for a role the layout does not carry.
  - A **mono** surround (2/1, 3/1) goes to both outputs, pre-scaled by another 0.7071.
    That pre-scaled value is also the one the normalisation uses.
  - `Lo = k(L + clev·C + slev·Ls)` with `k = 1/(1 + clev_eff + slev_eff)` (liba52
    `A52_ADJUST_LEVEL`). It cannot clip, and DTS and AC-3 play at the same level:
    3/2 gives 0.414, 3/1 gives 0.453, 2/1 gives 0.667, and 3/0 and 2/2 give 0.586.
  - Mono, stereo, sum/difference stereo and Lt/Rt pass through at unity. Dual mono
    (AMODE 1) maps A to L and B to R, as FFmpeg does (AC-3 rejects its dual mono).
  - ⚠ The first model got the mono surround wrong: it normalised by the full slev, so
    2/1 and 3/1 came out quieter than AC-3. Fixed in `default_gains()`.
  - **A stream's embedded coefficients are ignored and counted.** They sit in the core
    frame's aux data (`AUX` sync `0x9A1105A0`, 9-bit codes into `DMIXTABLE`), and FFmpeg
    itself uses them only when a stereo layout is requested. *Cinderella III* is the one
    library stream that carries them, in every frame; `tools/dts_fixed.py` counts them
    (`dmix_ignored`), and the RTL needs the same counter in telemetry.

### D4 — Codebooks: shipped in the bitstream as the starting contents of write-first RAMs, copied once to DDR3 (2026-10-02, maintainer)

Two trained codebooks, measured from FFmpeg `dcadata.c`. Real discs use both: the
Terminator 2 DTS sample predicts 36,377 bands with ADPCM and codes 168,750 bands with
high-frequency VQ over 5,625 frames (`tools/dts_ref.py info`).

| Table | Shape | Range | Bits | Size |
|---|---|---|---|---|
| `ff_dca_adpcm_vb` (ADPCM predictor VQ) | 4096 × 4 | −21806 … 21657 | 16 | 256 Kbit |
| `ff_dca_high_freq_vq` (high-frequency VQ) | 1024 × 32 | −87 … 89 | 8 | 256 Kbit |

All 4,096 ADPCM vectors are distinct, and there is no negation or half-table symmetry in
either table. No structure lets them be generated or shrunk. At about 52 M10K they exceed
the 41 free (§4).

**Alternatives rejected:**
- **A `boot1.rom` file pushed by stock Main** at ioctl index `0x40`. It would work, but it
  adds an install step, and a missing file silently disables DTS.
- **Paying the ~52 M10K.** Even after the PCM-FIFO merge, that leaves the device about 10
  short with nothing spare.

**Chosen.** An M10K can be given initial contents in the bitstream and still be an
ordinary RAM afterwards. FIFOs never read a word before writing it, so their power-up
contents are unused today. Three of them match the tables exactly:

| Host RAM | Size | Carries |
|---|---|---|
| `audio_ring` byte memory (`BYTE_DEPTH(32768)`) | 32,768 B | `high_freq_vq`, 32,768 int8 |
| `lpcm_unpack` PCM FIFO (`FIFO_AW(12)`, 4096 × 32) | 16 KB | `adpcm_vb`, first half |
| `mp2_decode` PCM FIFO (`PCM_AW(12)`, 4096 × 32) | 16 KB | `adpcm_vb`, second half |

After configuration, a copier (estimated 50–100 ALM) streams the 64 KB into a reserved
DDR3 region. That takes about a millisecond, and the audio path is held in reset until it
finishes. From then on the hosts are ordinary FIFOs, and the DTS engine fetches vectors
from DDR3.

**Rules the RTL must honour:**
1. **Copy once per configuration, never per reset.** The "copied" flag has **no reset
   term**, so only configuration initialises it. After the first audio the hosts hold
   PCM, so a second copy would write garbage over the tables. Quartus 17 can mangle such a
   register silently (CLAUDE.md, cross-cutting lessons), so **confirm its power-up value in
   the netlist**, not just in sim.
2. **Never silent.** Keep a sticky `dts_tables_ok` bit and a checksum of what was copied,
   readable from telemetry. A bad copy must show as a flag, not as plausible garbage
   audio. While the flag is low, DTS is refused with a counted error.
3. **Bench:** the copy is checked byte for byte against the `.mem` sources, with a
   mutation (for example, one host's init file swapped) that must fail exactly that arm.
4. **Inference check:** after any edit near a host's write sites, grep `DVD.map.rpt` for
   that RAM's "Inferred altsyncram" line *and* its init file. A host that silently falls
   back to registers or loses its init is the failure to catch.
5. **Reserved region:** no other master may write it, neither the decoder's framestore
   nor VBUF, nor anything Main touches. ⏳ Choose the address against the existing DDR3
   map before P2.

**Conflict to resolve before P2: merging the PCM FIFOs.** Merging the three per-codec PCM
FIFOs into one (a planned reclaim, about 20 M10K) would remove a host. If the merge lands
first, the second half of `adpcm_vb` needs a different write-first RAM: one of the AC-3 or
MP2 working buffers (`imdct_512` holds 23 M10K). **Order: wire the copy path first (P2),
then do the merge (P4) and move the half-table in the same change.**

**Port:** `ram2`, idle by construction (`hw_budget_and_lessons.md` §2), which needs the
`sysmem_lite` / `sys_top.v` plumbing that note lists, a `sys/` edit. The fetch traffic is
about 0.5 MB/s, so clocking `ram2` on `clk_sys` avoids a CDC; the `clk_mem` suggestion
there was for a line pump. ⏳ Confirm that `sysmem_lite` accepts a `clk_sys` `ram2_clk`.
`ram1` is the decoder's port and is not used: occupancy, not bandwidth, is what hurt it
before.

### D5 — Overflowed block codes are decoded leniently and counted (✅ decided by the maintainer, 2026-10-02)

A block code packs four samples as base-`levels` digits. A code of `levels⁴` or more is out
of range. **FFmpeg refuses the whole frame**; **libdca keeps the four low digits** and
prints an error. One library disc, *Shadoan* (`SHADOAN_1_2.iso`), carries 428 such codes
in 240 of 482 frames of one window, across six title sets. FFmpeg refuses exactly those
240 frames. Decoded leniently, every frame parses cleanly through its DSYNC words, so the
frames are valid and only those codes overflow (an encoder quirk). Refusing them would
silence that disc about half the time.

**Is the audio viable? Measured 2026-10-02 on the *Shadoan* window (482 frames):**
- **The frames are real audio, and the bad codes are rare encoder slips.** Overflow
  rates per allocation level are 0.02–0.79 %. If those fields were garbage, the rate
  would be (2ⁿ − L⁴)/2ⁿ, 13–41 %. The valid codes' samples have the small-value statistics
  of the Terminator 2 control (mean |sample| 1.93 at L = 17, against 1.71 on T2 and 4.24
  if uniform).
- **The intended value cannot be recovered.** A one-step carry past the quantiser's edge
  would leave the top digit at 0. The top digits are spread across the range instead,
  and the overflow digit is always 1. So no decoder can know what the encoder meant;
  what matters is that the error is bounded.
- **It is bounded, and inaudible by these measures.** A lenient decode keeps all four
  samples inside the quantiser's legal range, so the error is confined to four subband
  samples of one band per bad code. Decoding leniently and zeroing those four samples
  differ by **1.0 LSB RMS against a 750 LSB RMS signal (−58 dB)**. Frames with a bad
  code are indistinguishable from clean ones in click measure (second-difference p95: 894
  against 1,925 on clean frames) and in level continuity against their neighbours (p95:
  2.26 dB against 2.03 dB).
- **FFmpeg's refusal is the audible option.** It silences 240 of the 482 frames: 10.7 ms
  dropouts about every other frame, level jumps of about 60 dB, a stutter.

**Decision (maintainer, 2026-10-02): decode leniently**, as libdca does: keep the four low
digits and count every overflowed code in telemetry (never silent, CLAUDE.md). A hardware decoder that derives
the digits by divide-and-remainder without a range check behaves identically; the
counter is the only addition. `tools/dts_fixed.py`, the
hardware's model, does this. `tools/dts_ref.py` matches FFmpeg by default and takes
`OPT={'lenient_block'}`. Bit-exact comparison against FFmpeg is impossible on such frames
(FFmpeg outputs none), so `tools/test_dts_ref.py` reports the stream as REFUSED, and
`tools/test_dts_fixed.py` gates the lenient decode (both of its decoders run lenient).

## 3. The stream forces a streaming decode (design rule)

A frame at the spec maximum does not fit in a frame buffer. `npcmblocks` is a 7-bit field
plus 1, a multiple of 8, so a frame can carry up to 128 subband samples per band (4,096
PCM samples). DVD's usual value is 16. Buffering a whole frame of subband samples at the
maximum would take 32 bands × 128 × 6 channels ≈ 24K entries, about 58 M10K at 24 bits:
the codebook problem a second time.

The bitstream order avoids it (verified in FFmpeg `dca_core.c`, `parse_frame_data`). Each
subframe is `parse_subframe_header` (the side info for **all** channels, including every
ADPCM VQ index), then `parse_subframe_audio`. The audio data opens with every
high-frequency VQ index and the LFE samples, then loops over subsubframes (each 8 samples
× bands × channels).

**Rule: decode per subsubframe as it is parsed.** Dequantise, predict, expand VQ, downmix
and synthesise each 8-sample subsubframe before parsing the next. Never hold a frame.

✅ **Proven equivalent (2026-10-02).** FFmpeg runs its inverse ADPCM, VQ expansion and
joint intensity once per *subframe*, after all of that subframe's sample codes. Each is
causal within a band, so doing them per subsubframe must give the same samples.
`tools/dts_fixed.py` decodes in the streaming order, and its subband samples are
**bit-identical** to `tools/dts_ref.py`'s FFmpeg-order ones. This holds on Terminator 2,
on a 1536 kbit/s *A.I.* window with transients, and on all seven synthetic fixtures
(`tools/test_dts_fixed.py` [1]; its `stale_history` RED arm proves the check can fail).

**Persistent state** is small and sized to the maximum:
- ADPCM history: 4 samples × 32 bands × channels.
- The parse record for one subframe.
- Two QMF histories (L/R, 512 taps each).

**Codebook prefetch.** Every codebook index comes before any sample code that needs it:
the ADPCM indices are in the subframe header, and the VQ indices open the subframe's
audio data. So the microcode issues the DDR3 reads **as each index is parsed**, and
the vectors are local before dequantisation needs them. At the maximum that is about 200
fetches per subframe; serialised after the header, that would be about 1 ms of a 10.7 ms
frame, which is why issue-as-parsed matters. A small local vector buffer (one subframe's
worth) holds them.

## 4. Budget

**Fabric (last fit, the menu-panscan build, 2026-10-01):** 40,785 / 41,910 ALM (97 %,
**~1,125 spare**), 512 / 553 M10K (41 spare), 95 / 112 DSP (17 spare).

**Today's audio path, for reference:**

| Module | ALM | M10K | DSP |
|---|---|---|---|
| `dvd_audio_decode` total | 6,371 | 107 | 20 |
| `ac3_front` | 4,754 | 47 | 13 |
| `imdct_512` (inside `ac3_front`) | 2,062 | 23 | 9 |
| `mp2_decode` | 878 | 37 | 5 |
| `audio_ring` | 229 | 34 | 0 |
| `lpcm_unpack` | 107 | 16 | 0 |

**DTS estimate:** about **1,500–2,500 ALM**, about **18–25 M10K** without the codebooks
(microcode 5–10, Huffman tree 7–9, QMF prototypes 2–3, persistent state), and 1 DSP. It is an
estimate until P1's standalone fit replaces it. It exceeds the ALM spare, so **a reclaim
must land before or with the wiring** (P4 lists them; the net-by-scenario table below
shows which).

**Net ALM by scenario (2026-10-02; estimates except where the fit report measured a
module).** Each scenario builds on the one above it. Module figures move ±5–10 % with
packing.

| Change | ALM | Basis |
|---|---|---|
| DTS engine: sequencer ~800 + vector ops ~700–1,000 + codebook fetch and vector buffer ~100–150 | +1,600 … +2,000 | estimate |
| Codebook copier | +50 … +100 | estimate |
| `ram2` live: our master + the port's terminator (17 → ~52, as `ram1`'s) | +100 … +200 | estimate; terminators measured |
| `T_DTS` arm, telemetry words | +50 … +150 | estimate |
| **A. DTS alone** | **+1,800 … +2,450** | |
| One bit reader (MP2's `bit_reader` + `bit_fifo` = 189, measured) | −150 | net of the source mux |
| One PCM FIFO (`pcm_out` 117, `lpcm_unpack` 107, MP2's FIFO control) | −100 … −200 | the DTS output shares it too |
| **B. DTS + the cheap merges** | **+1,450 … +2,200** (central ~+1,800) | |
| MP2 onto the engine (`mp2_decode` 878, measured, minus its bit reader already counted, plus a microcode program and a grouping op) | −550 … −650 | estimate |
| **C. B + MP2 on the engine** | **+800 … +1,650** (central ~+1,200) | |
| AC-3 parse onto the engine (`ac3_parse` 4,483 − `imdct_512` 2,062 = ~2,420 measured; keeps the IMDCT; adds bit-allocation vector ops ~300–600 for the cycle budget) | −1,300 … −2,000 | estimate, the least certain row |
| **D. C + the AC-3 parse on the engine** | **−1,200 … +350** (central ~−450) | |

Against ~1,125 spare at 97 %, only **D** fits with margin. **C** lands at about 100 % and
would not be expected to fit or close timing. **A** and **B** do not fit. So the AC-3 parse
migration is on the critical path, not optional, unless P1's standalone fit comes in near
the bottom of its range. P1's fit replaces the engine rows. A migration is counted only
when its own fit measures it. (P1b measured the engine at ~2,070 ALM in-core, the top of
its row: §10 "P1b result".)

**Scenario E: the engine for MP2 and AC-3 only, no DTS (estimated 2026-10-02, at the
maintainer's request).** ⏩ The AC-3 half is now measured by an emulator
(`docs/ac3_engine.md`, A1), and the engine RTL now decodes it (A2c). ⏩ **Fitted (A2d): the
engine running both is 2,921 ALM standalone; AC-3 adds +688 against −2,687 removed, so
scenario D (DTS plus the AC-3 migration) measures about +200 … +300 ALM net.** The whole parse
runs on the engine, bit-exact against the RTL on 30 streams. The worst frame needs
37 % of real time with the IMDCT in series, now counting the built units at their RTL
cycles. Its microcode is 779 words (1,279 with DTS's program, so a 2K-deep ROM of 8
M10K, where the table below assumed less). The ALM rows stay estimates until RTL and a
fit. Does the engine concept save area over v0.8.0 on its own merits?
The baseline is the per-entity fit of the menu-panscan build (2026-10-01, one feature
after v0.8.0, with the same audio path). The removed rows are measured; the added rows
are estimates.

| Change | ALM | Basis |
|---|---|---|
| `mp2_decode`, its bit reader included | −878 | measured |
| AC-3 parse without `imdct_512`: `audblk_parse` 713, `mantissa_dequant` 762, `bit_allocation` 591, `exponent_decode` 207, `bsi_parse` + `sync_crc` + glue 148 | −2,421 | measured |
| AC-3's `bit_reader` + `bit_fifo` | −266 | measured |
| **Removed** | **−3,565** | |
| Sequencer: P1b's design, the Huffman walker dropped; its block-code divider serves AC-3's grouped mantissas (÷3, ÷5, ÷11) and exponents, and MP2's grouped samples | +800 … +850 | P1b measured 853 with DTS's features |
| Vector engine: the datapath; MP2 synthesis on the program-ROM IMDCT executor and the window loop; AC-3's dequantisation, exponent and bit-allocation ops (bit allocation alone +300 … +600, §4) | +1,200 … +1,500 | estimate, the least certain row: P1b's 1,120 is not split between datapath and ops |
| Glue into `imdct_512`'s coefficient input, telemetry | +100 … +200 | estimate |
| **Added** | **+2,100 … +2,550** | |
| **E. Net, against today** | **−1,000 … −1,450** (central ~−1,200) | |

- **Cross-check:** scenario D (DTS plus both migrations) is about −450. Removing
  DTS's own share (its ops, the codebook copier, the `ram2` plumbing: ~700–900) gives
  −1,150 … −1,350, which agrees with the bottom-up figure.
- **M10K: about −40.** MP2's 37 blocks and the AC-3 parse's ~24 are freed; the engine
  needs about 15–20 (no Huffman tree, no codebooks).
- **The one-PCM-FIFO merge** (−100 … −200, §4 row B) is independent of this and
  available in every scenario.
- **Cycles: feasible, not proven.** AC-3 5.1 at 448 kbit/s gives about 864K cycles a
  frame. With bit allocation as a vector op, the guess is 200–300K, with `imdct_512`
  running alongside. Interpreted, bit allocation alone would be about 550K, over half
  the budget, so it must be a vector op.
- **Cost and risk.** This is the expensive migration:
  - the AC-3 path must stay bit-exact against `bench/ac3` and trace-identical
    (`logic_reclaim.md` method);
  - MP2's synthesis on the factorised transform needs its own LSB-bounded golden,
    because it does not round like today's direct matrixing.

  The cheap first step is a P1a-style emulator for the AC-3 parse, which would measure
  its ops and cycles before any RTL. Like every row here, E counts only once a fit
  measures it.

**Cycles (27 MHz, about 27M a second). Measured by `tools/dts_fixed.py`'s operation
counters (2026-10-02) on the heaviest stream type found, a 1536 kbit/s 5.1 window from
*A.I.*:**
- **Synthesis:** FFmpeg's factorised half IMDCT costs 288 multiplies per 32-sample block,
  plus 512 window taps: about 800 MACs a block, against about 2,560 for MP2-style direct
  matrixing. Stereo after the downmix is 32 blocks a frame, about **25.6K MACs a frame,
  about 2.4M a second**. ⏳ **P1 decision:** keep the factorised IMDCT as the synthesis
  vector op. It is also what makes the reference bit-exact. A direct matrix would cost
  about three times the cycles and need its own LSB-bounded golden.
- **Front end (dequantisation, ADPCM, VQ, joint, downmix):** **5,246 MACs a frame, about
  0.5M a second.**
- **Parse:** 16,104 bits a frame at 1536 kbit/s, about 1.5M bits a second, in about
  2,240 subband samples a frame (210K a second). Most DVD streams code them as block
  codes (2 codes per 8 samples) or raw 8–23-bit fields, not Huffman. **The risk** is an
  interpreter that pays per *bit*: at 13–19 cycles a bit that is 20M+ a second. If P1
  measures that, the sample-extraction loop becomes a vector op.
- **Total target:** under 60 % of the budget. The arithmetic is about 3M MACs a second;
  the parse is the cost to watch.

## 5. Spec maxima (CLAUDE.md "design to the DVD spec maximum")

The field widths are from FFmpeg's parser. ⏳ **Confirm each against ETSI TS 102 114
before sizing.**

| Field | Width | Max the field allows | What FFmpeg accepts | Size to |
|---|---|---|---|---|
| `nsubframes` | 4 + 1 | 16 | 16 | 16 |
| `nsubsubframes` | 2 + 1 | 4 | 4 | 4 |
| `npcmblocks` | 7 + 1, multiple of 8 | 128 | 128 | 128 (streaming, §3) |
| `frame_size` | 14 + 1 | 16,384 B | ≥ 96 | 16,384: streaming parse, the byte counter sized to it |
| primary channels | 3 + 1 | 8 | must equal the AMODE table: ≤ 5 (AMODE < 10) | ⏳ 5 + LFE if TS 102 114 confirms AMODE 10–15 are user-defined; else refuse, counted |
| `nsubbands` | 5 + 2 | 33 | ≤ 32 | 32; above that, refuse, counted |
| `subband_vq_start` | 5 + 1 | 32 | — | 32 |
| codebook indices | 12 / 10 | 4,096 / 1,024 | — | full tables (D4) |

A hard limit that is hit must be **visible**: a refusal counter and the last error code
in telemetry, never wrong audio.

## 6. Verification chain

1. **Tables** come from a pinned FFmpeg source via `tools/gen_dts_tables.py`, with a
   `--check` that regenerates and compares. Format facts are transcribed with credit:
   FFmpeg is LGPL-2.1-or-later, which may be carried under GPL. Add NOTICE and
   `site/content/about/acknowledgements.md` entries when this ships.
2. **A float reference model** (`tools/dts_ref.py`, written from the spec and FFmpeg's
   logic, not copied) is checked against the FFmpeg binary's output across the library's
   DTS tracks.
3. **A fixed-point model** (`tools/dts_fixed.py`) is the bit-exact golden for the RTL.
   It is within an LSB bound of FFmpeg's `BITEXACT` core path, with FFmpeg mixed after
   synthesis (D3). Round half up at every shift; every stage boundary saturates and counts.
   On a legal stream nothing but the PCM output may saturate.
4. **An assembler plus instruction-level emulator** (`tools/dts_isa.py`): its parse record
   is scored field by field against the reference model, and its PCM bit-exact against the
   fixed model.
5. **RTL:**
   - The sequencer is scored against the emulator by trace: every register write and
     every store, in program order.
   - The whole decoder is scored after every vector op by checksums of the engine
     buffers, and on every PCM pair. The first engine that differs is named.
   - Every check has a RED mutation (`--red`) that must fail exactly its own arm. Score
     with `!==`.

## 7. Phases

- **P0 — tools and measurement (✅ done; D3 and D5 decided 2026-10-02).**
  - The pinned table generator.
  - The reference, bit-exact against FFmpeg.
  - The hardware-order model: front end bit-exact, downmix within 1 LSB.
  - The fixtures: encoded, derived and written. The bitstream writer
    (`tools/dts_writer.py`) also supplies P1's spec-maximum test streams.
  - The two gates, and the census (§9).
  - `gen_dts_tables.py`.
  - **A library sweep, `tools/dts_scan.py`**, modelled on `tools/acmod_scan.py` (PES
    first-access-unit pointer, not a sync-word search). For every DTS track in
    `$DVD_ISO_DIR` it records: AMODE, LFE, bitrate, `npcmblocks`, `nsubframes`, the
    extensions present, and the fraction of frames using ADPCM prediction (PMODE) and
    high-frequency VQ.
    ⚠ Unlike acmod, PMODE and VQ change **per frame**, so the sweep must not stop at the
    first frames.
    The sweep sets priorities and test fixtures. It does not set limits: §5 does.
  - `dts_ref.py`, `dts_fixed.py`, and the LFE and downmix decisions (D3 ⏳).
- **P1 — the engine, standalone.** ✅ (P1a 2026-10-02: ISA, assembler, emulator and
  microcode, bit-exact on all 34 streams. P1b 2026-10-02: the RTL bit-exact against the
  emulator, the standalone fit 2,227 ALM / 31 M10K / 1 DSP / 35.8 MHz, §10 "P1b
  result".)
  ISA, assembler, emulator, microcode, RTL, benches, then
  a standalone fit with every port a virtual pin. **This is the go/no-go on ALM and
  cycles.** A previously built microcoded decoder of this kind is the template for the
  ISA and the verification method; ⚠ port it under new file names, and strip header
  comments that reference anything outside this repository.
- **P2 — codebook residency** (🔧 built 2026-10-03, "P2 + P3 result"). Initialised hosts, the copier, the `ram2` plumbing
  (`sys/`), the reserved region, `dts_tables_ok` plus checksum, the bench and its
  mutation, and the map-report inference check.
- **P3 — wiring** (🔧 built 2026-10-03, "P2 + P3 result"). The `T_DTS` arm in `dvd_audio_decode` drives the engine instead of
  discarding. Then a `tools/check_dts_wiring.py`, telemetry words, HIL on DTS discs, and
  the manual: `audio/formats.md`, `audio/passthrough.md` (three statements that DTS has
  no fallback), `reference/compatibility.md`, possibly a README headline limitation.
  A minor version bump.
- **P4 — reclaim.** One bit reader, one PCM FIFO (moving the `adpcm_vb` half per D4), and
  moving MP2 and then the AC-3 parse onto the engine. §4's scenario table shows the AC-3
  parse move is needed for DTS to fit, so it is not optional. AC-3's IMDCT stays
  hardwired: a direct-form transform for 5.1 needs 61–74M multiply-accumulates a second,
  2.3–2.7× one multiplier at 27 MHz. ⚠ (2026-10-05) That is the direct form; `imdct_512`
  runs the FFT form, measured at 24.7 % of real time for 5.1 on one multiplier
  (`tools/imdct_model.py`), so this reason does not hold. See `logic_reclaim.md` §10a. Each move is gated trace-identical
  (`logic_reclaim.md` method) and the AC-3 path bit-exact against `bench/ac3`.

## 8. Open questions

- ✅ D3, decided: LFE is out, the mix follows the AC-3 path, and embedded coefficients
  are ignored but counted.
- ⏳ The DDR3 address for the codebooks, and `ram2` on `clk_sys` (D4).
- ⏳ AMODE 10–15 (user-defined, 6–8 channels): refuse or map (§5).
- ✅ Dynamic range compression (`DYNF`), decided 2026-11-12 (issue #189): ignored but
  **counted**. `dts.uasm` issues `CNT 1` per frame whose header sets it, so telemetry word 26
  bit 3 shows a disc that uses it. The OSD's Dynamic Range acts on AC-3 only. Applying the
  coefficient stays open until a disc that sets it turns up. `status_log.md` "Dynamic Range".
- ⏳ The core's CRC (`CPF`): check and refuse, or ignore as `mp2_decode` does. No library
  stream sets it (§9).
- ✅ D5: overflowed block codes are decoded leniently and counted (decided).
- ⏳ The default downmix rule (D3): the AC-3 path's liba52 Lo/Ro is proposed. *Cinderella
  III* is the one library stream with embedded coefficients, so it is the test case for
  honouring them.
- ✅ A joint-intensity test stream: `tools/dts_writer.py` (§9).

## 9. Library census (2026-10-02, `tools/dts_scan.py`)

**Method.** Every image under the library root was opened. Each title set declaring a DTS
stream had 8 windows of 500 sectors sampled evenly across its title VOBS (`0xC4` to
the title set's end), and every frame in them was parsed with `tools/dts_ref.py`'s front
end. That covered **147 streams on 90 discs, 145,786 frames**. 23 images could not be
read (not ISO9660, or not DVD-Video: no `VIDEO_TS`). Raw rows are in
`.sim/dts/scan.jsonl` (gitignored).

| Feature | Streams | Frames |
|---|---|---|
| ADPCM prediction | **147 (all)** | 85 % |
| High-frequency VQ | **118** | 77 % |
| Transients (two scale factors) | 66 | 30 % |
| Huffman sample codes | 0 | 0 % |
| Joint intensity | 0 | 0 % |
| Front / surround sum/difference | 0 / 0 | 0 % |
| Embedded downmix (aux data) | 1 (*Cinderella III*, every frame) | 0.5 % |
| Dynamic range, header CRC | 0 | 0 % |
| XCh extension (DTS-ES discrete 6.1) | 8 | — |
| `es_format` (ES matrixed) | 15 | — |

**Uniform across the library:**
- AMODE 9 (3/2) with LFE flag 2 (64× interpolation).
- `npcmblocks` 16, one subframe per frame.
- The non-perfect filter.
- Frames of 1,006 or 2,013 bytes (768 kbit/s on 105 streams, 1536 kbit/s on 42).
- Subband counts up to 32.
- Predictor history on.

**Errors:** only the *Shadoan* overflowed block codes (D5).

**What this means.** Both trained codebooks are needed on real discs: ADPCM in every
stream, VQ in four of five (confirming D4). Huffman sample codes, joint intensity and
sum/difference never appear on these discs. They are in the format, so they are built
and tested anyway (§5): the tests come from synthetic and derived fixtures, below. A
sweep says what is common, not what is possible.

### Test coverage of the reference (`tools/test_dts_ref.py`)

The gate set (`~/dts-streams/gate`, local, never committed), 34 streams:
- **Twelve from `tools/gen_dts_fixtures.py`**, made from generated signals only:
  - Eight encoded by FFmpeg's DTS encoder: mono to 5.1, 192k–1536k. These supply the
    **Huffman sample codes**, and one near-full-scale stream drives the half IMDCT's
    **pre-shift**.
  - Four derived by rewriting fixed-width fields the encoder never sets:
    `filter_perfect`, `sumdiff_front` and `sumdiff_surround`, and the coding header's
    2-bit **Huffman scale-adjustment** indices (set to ×1.4375).
  - The sum/difference streams are encoded in sum/difference form, `(a+b)/2` and
    `(a−b)/2`, so the decoder's butterflies rebuild in-range signals as a real stream's
    would. ⚠ The first version flagged ordinary L/R content instead. Its `L+R` passed full
    scale, FFmpeg clipped each speaker, and the downmix model (which scales before it
    could clip) differed by 3,583 LSB. That was an artefact of the fixture, not a decoder
    fault.
- **Fifteen from `tools/dts_writer.py`**, our own syntax-level DTS core encoder. It writes
  frames field by field from a description, fills that description with a seeded
  generator of legal, moderate-level values, and parses every frame back to compare.
  It makes what nothing else does:
  - **joint intensity** (three shapes at once);
  - the **frame-shape spec maxima**: `npcmblocks` 128 (4,096 PCM samples a frame), as
    16 subframes of 1 and as 4 subframes of 4 subsubframes with `sync_ssf`. Measured on
    the streams: 32 subbands, frames of 9.0–14.6 KB;
  - **front and surround sum/difference with uneven band counts per pair**
    (`sumdiff51`, and `amode3` for stereo): the pair-bound rule's two test streams;
  - **all ten channel arrangements** (AMODE 0–9; FFmpeg's encoder covers four);
  - every bit-allocation, scale-factor, transient and quantiser-index codebook
    selector, and bit allocations up to 26;
  - header CRC words, DRC, time code, aux data with downmix coefficients and a valid
    CRC, predictor history off, and the lossless step table.

  ⚠ The comparison passes `-f dts`: FFmpeg's raw-DTS probe rejects some legal streams,
  such as a small mono frame whose bit-rate field disagreed with it. The writer now also
  sets the bit-rate field from the real frame size.
- **Seven disc windows:** Terminator 2, plus windows for XCh, embedded downmix, 1536k
  with transients, 768k with VQ and transients, ES, and the *Shadoan* overflow.
  ⚠ The comparison runs FFmpeg with `-core_only 1`. Without it FFmpeg decodes XCh, and a
  DTS-ES disc returns 7 channels to our 6.

**Every stage now has a stream that exercises it** and a RED arm that bites on it,
joint intensity included: `tools/test_dts_ref.py` reports no coverage gaps. The writer's
streams are bit-exact through `tools/dts_ref.py` against FFmpeg, spec-maximum frames
included. Every stream passes `tools/test_dts_fixed.py`: the streaming front end is
bit-exact and the downmix is within 1 LSB.

## 10. The engine: ISA, memory map and datapath (P1a, 2026-10-02)

**Machine.** A microcoded sequencer with 40-bit instruction words and sixteen 16-bit
registers (`r0` reads 0; `r8`–`r15` carry vector-op arguments). Its instructions: ALU
operations (with immediate forms), loads and stores, `get n` (up to 16 bits, MSB first),
`vlc` (a Huffman symbol), compare-and-branch, call and return, `err`, and `vop` (run a
hardwired loop, with the sequencer stalled until it finishes). `tools/dts_isa.py` is
the executable definition: the assembler, plus an instruction-level emulator that the
RTL must match instruction by instruction. The program is `dvd/dts/dts.uasm`.

**ISA decisions, each with the alternative rejected:**
1. **Sample codes wider than 16 bits** (raw fields of up to 23 bits) **are never read
   by the sequencer.** One vector op, `XQ`, reads a band's 8 codes itself (Huffman,
   block or raw), dequantises them, and writes the subband buffer. The sequencer
   passes `XQ` only indices and selectors (abits, quantiser selector, scale index,
   adjustment index), which all fit 16 bits. `XQ` and the sequencer share one bit
   reader; that is safe because a vector op runs with the sequencer stalled.
   *Rejected:* 24-bit registers. That widens every ALU path, the register file and the
   record RAM for a few fields, and leaves the per-sample loop interpreted, which is the
   §4 cycle risk.
2. **Block-code division** happens inside `XQ`: dividing a code of up to 19 bits into
   four digits by one of seven levels (3–25). The emulator charges ~6 cycles a digit
   (multiply by a reciprocal, one correction); restoring division would be ~19. P1b
   picks the method against the measured cycle budget, below.
3. **The codebook port** is a request/response memory with a latency parameter. In P1
   the emulator reads the tables directly and charges the latency; `ram2` arrives in P2.
   **Both codebooks have 64-bit rows:** an ADPCM vector is 4 × int16, and one
   subsubframe's slice of a VQ vector is 8 × int8. So one DDR3 beat serves one band,
   and the local buffers hold one slice per band. An ADPCM vector is fetched when its
   index is parsed (subframe side info); a VQ slice at the start of each subsubframe,
   while `XQ` is still reading that subsubframe's sample codes.
   *Rejected:* buffering whole 32-byte VQ vectors per subframe: 4–5 M10K instead of 1–2.
4. **Datapath: one 27×27 multiplier and a 56-bit accumulator.** Measured operand
   widths, all signed:
   - subband samples, scale factors, steps and window coefficients: 24 bits;
   - IMDCT constants: 24–27 bits. The single exception, `mod_a`'s −85,479,984, needs
     28 bits; it is even, so it is stored halved with the rounding shift cut from 23
     to 22, which is exact.

   Largest sums: the window's eight taps plus the carried partial sum, 2^48.8; `dct_a`,
   2^49.0; `step × scale`, 2^45.7. So 50 bits plus sign suffice, and 56 leaves margin.

**Vector ops**, one hardwired loop each. Each calls the matching `tools/dts_fixed.py`
function, so the emulator is anchored to the model and not to itself:

| op | what | model function |
|---|---|---|
| `XCLR` | zero the subsubframe's subband buffer | — |
| `XQ` | read 8 codes (Huffman / block / raw, lenient per D5), dequantise one band | `R.extract_audio`, `dequant_band`, `huff_scale` |
| `XVQ` | 8 VQ values × scale, one band | `vq_band` |
| `ADPCM` | 4-tap prediction over 8 samples, or the plain history update | `adpcm_band` |
| `JOINT` | a joint-intensity band from its source | `joint_band` |
| `BFLY` | sum/difference of a channel pair, every band | `butterfly_band` |
| `MIXSYN` | sample j: mix both sides (AC-3 gains by AMODE, pair-bounded), half IMDCT, window, 32 PCM pairs out | `mix_column`, `SynthFixed.run`, `to_s16` |
| `HCLR` | clear one channel's ADPCM history from a band up | — |
| `CNT` | count an event in telemetry (`dmix_ignored`) | — |

**Memory map and M10K estimate** (spec maximum: 5 primary channels, 32 bands; codebooks
off-chip per D4):

| Memory | Size | M10K |
|---|---|---|
| Subband buffer, one subsubframe | 5 × 32 × 8 × 24 bit | 5 |
| ADPCM history | 5 × 32 × 4 × 24 bit | 3 |
| Record RAM (side info: abits/tmode/pmode, two scale indices, VQ index, joint scale; coding header) | ~1K × 16 | 2 |
| Codebook buffers: an ADPCM vector per band, a VQ slice per band | 2 × 160 × 64 bit | 2–4 |
| Synthesis rings and carried partial sums, ×2 sides | 2 × (512 + 32) × 24 bit | 3 |
| Window prototypes, perfect and non-perfect | 2 × 512 × 24 bit | 3 |
| IMDCT constants, scale / step / joint / adjustment tables, AC-3 gains | ~600 words | 1–2 |
| Huffman tree, every core book | 2,647 nodes × ~26 bit | 9 |
| Microcode | 521 × 40 bit (measured, P1a) | 2–3 |
| **Total** | | **~30–34** |

⚠ **This is above §4's 18–25 estimate.** The Huffman tree (9, not 4) and the
per-subsubframe buffers were under-counted there. It still fits the 41 free M10K with
the codebooks off-chip, but not with much to spare. The planned PCM-FIFO merge (~20,
P4) is what restores margin, and P1b's standalone fit replaces these numbers.

### P1a result (2026-10-02): the emulator is bit-exact; 31 % of real time at the spec maximum

- `dvd/dts/dts.uasm` is **521 instruction words**. It follows `StreamDecoder.decode` step
  for step and makes every check FFmpeg makes, plus a 48 kHz-only check (the core's
  output rate).
- Generated images, checked current by `--check`: `dvd/dts/dts_ucode.mem`, the 92-word
  constant ROM `dts_const.mem`, and the 2,647-node Huffman tree `dts_huff.mem`.
- **`tools/test_dts_isa.py` passes on all 34 gate streams:**
  - [1] the emulator's PCM is **bit-identical** to `tools/dts_fixed.py`, with no engine
    error. That covers both spec-maximum frame shapes, joint intensity, 5.1
    sum/difference, all ten AMODEs, *Shadoan*'s lenient block codes, and non-unity
    Huffman adjustments;
  - [2] every frame within 60 % of real time;
  - [3] the `.mem` images match the source.
  - Its five microcode RED arms (`;MUT` lines) each bite on every stream that exercises
    them: transient 19 streams, VQ slice 19, ADPCM 26, joint 1, pair bound 2. A gap is
    reported only where the stream cannot show the stage: one subsubframe per subframe,
    or *Shadoan*'s VQ bands, which all decode to zero.
- **Cycles (P1a's model, `dts_isa.CYC`; P1b's RTL measures the real ones):**
  - **Worst frame: 30.9 % of real time** (`written_max_subframes`: 712K cycles for
    4,096 samples).
  - **A typical disc frame: 24 %** (Terminator 2: 69K cycles for 512 samples, against
    288K available).
  - Split: sequencer 28–33 %, `MIXSYN` 34–42 %, `XQ` 25–30 %, `ADPCM` 3–4 %.
  - §4's per-bit risk does not arise: the interpreter never touches a sample code's bits,
    and `XQ` reads them at about one cycle per bit.
- **Bugs found on the way:**
  - An assembler bug put `vop`'s op number in the immediate field, so every vector op
    ran as `XCLR` and every frame failed DSYNC. Bit-position tracing against `dts_ref`
    found it.
  - Two RED-arm preconditions were too loose, and the gate's BLIND report caught both.

**Next, P1b (a fresh session):** the RTL, `dvd/dts/dts_seq.sv` (sequencer, bit reader,
tree walker) and `dvd/dts/dts_vec.sv` (the nine vector ops on one 27×27 multiplier).
Then trace-scored benches against `Machine.trace`, and a standalone fit with every port
a virtual pin: **the go/no-go on ALM, M10K and fmax**. Port the template's verification
method, not its files: new names, nothing referencing outside this repository.


### P1b handoff (written 2026-10-02 for a cold start)

**Rebuild the working set and confirm it is green before writing any RTL:**

```bash
FFMPEG_SRC_DIR=<ffmpeg n9.0.x source> python3 tools/gen_dts_tables.py --check   # tables pinned
python3 tools/dts_isa.py --asm --check                                           # .mem current
DVD_ISO_DIR=<library> DTS_T2_SAMPLE=<raw t2 .dts> \
    python3 tools/gen_dts_fixtures.py --discs      # all 34 gate streams -> ~/dts-streams/gate
python3 tools/test_dts_ref.py     # reference vs the FFmpeg binary (slow: ~5 min)
python3 tools/test_dts_fixed.py   # the hardware-order model vs the reference
python3 tools/test_dts_isa.py     # the emulator vs the model: the RTL's golden
```

`gen_dts_fixtures.py --discs` reproduces the disc windows byte for byte (checked
2026-10-02). It needs only the library images it names and the Terminator 2 sample.

**The engine's contract, which the RTL must keep:**
- **Input:** one DTS frame at a time, as `ps_demux` → `dts_reframer` → `audio_ring` deliver
  them, with the frame's byte length. The microcode's `frame` instruction waits for the
  next one, and bits past the frame read as 0 (counted as overrun).
- **Output:** s16 stereo pairs, 32 per `MIXSYN`, into the PCM FIFO the codec arms share
  (`mp2_decode`'s contract: full backpressure, `aud_ce` pops a pair). `MIXSYN` stalls when
  the FIFO lacks room for 32 pairs. That is the pacing, as `mp2_decode` stalls before each
  synthesis slot.
- **Codebook port:** a request/response read of one 64-bit row (an ADPCM vector, or a VQ
  vector's 8-byte slice for subsubframe `ssf`), with latency as a parameter. In P1b's
  standalone build it is a top-level port answered by the bench. The fit must measure the
  engine **without** the codebooks, which are off-chip per D4.
- **Telemetry counters:** frames decoded; errors by code (the `E_*` list in
  `dts.uasm`); overflowed block codes (D5); `dmix_ignored` (D3); bit overrun.

**Vector-op arguments** (`dts_isa.Machine.vop`; the microcode sets them):

| op | r8 | r9 | r10 | r11 | r12 | r13 | r14 | r15 |
|---|---|---|---|---|---|---|---|---|
| `XQ` | ch | band | abits | quantiser selector | scale index (bit 8: the 7-bit table) | adjustment index | lossless | — |
| `XVQ` | ch | band | VQ index | ssf | scale index | — | — | — |
| `ADPCM` | ch | band | pvq index | predicted? | — | — | — | — |
| `JOINT` | ch | band | source ch | joint scale index (coded + 64) | — | — | — | — |
| `BFLY` | ch p | ch q | — | — | — | — | — | — |
| `MIXSYN` | j (0–7) | AMODE | nmix[0] | nmix[1] | nmix[2] | nmix[3] | nmix[4] | filter perfect |
| `HCLR` | ch | from band | — | — | — | — | — | — |
| `CNT` | counter id | — | — | — | — | — | — | — |

`XCLR` takes no arguments.

**ROM formats:**
- `dts_ucode.mem`: 40-bit words, `op[39:34] rd rs rt imm[21:6] aux[5:0]`; `vop` carries
  its op in `aux`.
- `dts_const.mem`: 16-bit words.
- `dts_huff.mem`: 26-bit nodes `{right[25:13], left[12:0]}`, where an entry is
  `{leaf, value[11:0]}`. A leaf's value is the signed symbol; otherwise it is the child's
  node index. Each book's root comes from `dts_isa.HUFF_ROOTS`, a 62-entry table the RTL
  needs as a small ROM.

**The bench's trace:** `Machine.trace` (set it to a list) receives `(pc, rd, value)` for
every register write and `('st', addr, value)` for every store, in program order. Score
the sequencer RTL against it. Then score the whole engine by checksums of the subband
buffer and the history after every vector op, plus every PCM pair, so the first
divergence names its engine. The emulator does not emit per-op checksums yet: add them
in P1b.

**Decisions P1b still has to make, with what is known:**
- **Block-code division:** reciprocal multiply (the emulator charges ~6 cycles a digit)
  or restoring division (~19). Measure on the RTL: `XQ` is 25–30 % of cycles at the
  first figure.
- **`mod_a`'s −85,479,984:** store it halved with the rounding shift cut from 23 to 22
  (exact; §10 item 4).
- **A refused frame's output:** emit `npcmblocks × 32` silent pairs, to keep A/V timing,
  or nothing. Some `MIXSYN` output may already be in the FIFO when an error is found
  mid-frame. Decide this with P3's wiring into `dvd_audio_decode`'s PTS gate.
- **The cycle model** (`dts_isa.CYC`) is an estimate. Replace it with the RTL's measured
  per-op cycles, and re-check the 60 % bound in `test_dts_isa.py` [2].
- **A standalone-fit script:** this repo has none. Build a Quartus 17 project for the
  engine alone, every port a virtual pin, `clk_sys` 27 MHz. Report ALM, M10K and DSP
  against §10's table, and fmax at both slow corners (CLAUDE.md: the cold corner often
  binds).

**Quartus 17 rules that apply** (CLAUDE.md cross-cutting lessons): no `N'(expr)` size casts
and no recently added `function`s in the synthesised RTL; every new `dvd/*.sv` named in
`DVD.qsf`; benches score with `!==` and tie every input off; grep `DVD.map.rpt` for each
RAM's "Inferred altsyncram" line.

### P1b progress (2026-10-02)

**The sequencer RTL is bit-exact against the emulator: `dvd/dts/dts_seq.sv`, gate
`bench/dvd/run_dts_seq.sh` (`--red`).**

- **What it is.** The sequencer, the bit-serial reader, the tree walker (one code bit a
  cycle) and **XQ's code reader**. XQ's reader sits here because it shares the bit
  reader, and that keeps the sequencer's trace independent of the vector engine.
  On `vop XQ` the sequencer starts the engine and streams it the band's 8 codes
  (`xq_code` / `xq_valid` / `xq_ready`).
- **Input contract.** A frame is a descriptor (`fr_len`, taken by `frame`) followed by
  exactly that many bytes. Bits past the end read 0 and pulse `overrun_bit`; they never
  come from the next frame. `fend` and `err` drain the untaken bytes. `err` then restarts
  at `FRAME`; its path in `dts.uasm` has no `fend`, so the RTL drains.
- ✅ **Decided: block-code division is restoring, one quotient bit a cycle.** The first
  digit's division runs while the code's bits arrive, because restoring division takes
  the dividend MSB first, which is the bitstream's order. Each later digit divides the
  quotient in place. A code costs 4 × nb cycles (nb = 7–19). The emulator's model
  charged 24, but the whole-engine bench measures the real cost (below). It costs no
  multiplier and no reciprocal table.
- **Record map compacted (decided 2026-10-02).** The `P_*` tables use 160 of their 256
  words (5 channels × 32 bands). Packed at a stride of 160 (`.equ` values only, the
  microcode unchanged), the record ends at `REC_END` = 0x600 and fits **2K × 16, 4 M10K**.
  The old map ended at 0x8A0 and needed 4K × 16, 8 M10K. §10's "~1K × 16 → 2" was low
  either way. `REC_WORDS` in the emulator is now 0x800, so a store past the RAM raises.
- **Trace format** (`Machine.trace`): `(kind, pc, addr, value)`. Kind 0 is a register
  write, 1 a store (it now carries its pc), and 2 one of XQ's extracted codes (24 bits).
  Kind 2 puts a code-reader bug in the sequencer's bench, before any dequantisation:
  a wrong digit with the right bit count would otherwise show up only in the
  whole-engine bench.
- **Goldens:** `tools/dts_golden.py` runs the emulator on a stream window. It first
  checks the emulator frame by frame against `tools/dts_fixed.py`, and writes nothing if
  they disagree. Two constructed arms: `--refuse K` corrupts frame K's **last** DSYNC, so
  the refusal lands after half the frame's PCM is out (T2 sets `sync_ssf`, so its first
  DSYNC precedes all output). `--truncate K:N` delivers frame K short: the engine
  zero-fills and refuses, the model refuses it as an over-read, and the next frame proves
  no byte leaked across. The goldens also record overrun bits, lenient codes and `CNT`
  ops, and the bench scores all three.
- **Gate result.** All 34 streams (4 frames each) pass, plus R1 (mid-frame refusal with
  input and XQ stalls), R2 (truncation: 2,319 zero-filled bits) and R3 (*Shadoan* with
  stalls, 8 lenient codes). **All 17 RED mutations are caught, each by its own arm.**
  - ⚠ **Not observable: signed versus unsigned `lt`/`ge`.** The microcode's only
    negative comparands are error checks that refuse either way (a scale index below 0
    is also ≥ 64 unsigned). Q2 tests the 10-bit branch constant's sign extension
    instead. A microcode change that depends on a signed compare of a negative value
    needs its own arm.
  - Only `tools/dts_writer.py`'s streams code a **negative** VLC symbol (a scale
    delta). No disc and no FFmpeg-encoded stream does, so Q17 runs on `written_amode9`.
- **Sequencer cycles with a stub engine** (this bench): T2 43K a frame (512 samples,
  15 % of 288K); `written_max_subframes` 333K (4,096 samples, 14 % of 2.3M).
- **Not yet wired** into `DVD.qsf` or `emu.sv` (P3). P1b's fit builds the engine on its
  own. ⚠ Because `DVD.qsf` does not name `dvd/dts/*.sv`, `tools/lint_undriven.sh` has
  **not** seen them yet (CLAUDE.md cross-cutting lessons); P3 adds them and runs it.

**The whole engine is bit-exact too: `dvd/dts/dts_vec.sv` + `dts_top.sv`, gate
`bench/dvd/run_dts.sh` (`--red`).** After every vector op the bench reads X, the history,
the IMDCT rings and the window's carried sums out of the RTL. It checks their checksums
against `Machine.checksums` (same address order), and every PCM pair bit-exact.
- **Arms.** All 34 streams (2 frames each), the refusal, the truncation, *Shadoan*
  with stalls and back-pressure, and a codebook-latency sweep. **All 41 arms pass and
  all 18 RED mutations are caught**, each naming the op and the buffer that went wrong.
  One real bug was found this way: a lost address line made JOINT read the band's
  scale instead of the joint scale (`written_joint`, op 242).
- **Widths, sized to the arithmetic bound, not the gate's measured range:** X is 25 bits
  (a butterflied band is the sum of two clipped 24-bit values; the gate reaches 22) and
  `buf2` is 29 (eight 24×24 products shifted 21; the gate reaches 24).
- ✅ **The half IMDCT is a ROM program, not hardwired addressing (decided 2026-10-02).**
  `tools/dts_vecrom.py` writes FFmpeg's factorised transform as **597
  multiply-accumulate terms** (113 coefficients), in seven stages over a 64-word
  scratch. Each term is `{shl, neg, rsh, add, last, coef, src}`, 20 bits. The RTL runs one
  term a cycle through a fetch / read / issue pipeline. A stage's first term waits two
  cycles for the previous stage's last write. `run_prog`, the Python executor, equals
  `imdct_half_32` on 7,140 columns, 2,040 of them pre-shifted and the real gate columns
  among them; field mutations (neg, addend, shl, rsh 22, pre-shift) each make it differ.
  Two exactness traps decided the encoding:
  - `x − norm(c·y, 23)` is **not** `norm(2^23·x − c·y, 23)`, because half-up rounding is
    not odd-symmetric. So `mod_b`'s second half needs an addend term and a negate.
  - `mod_a`'s −85,479,984 is stored halved, with shift 22.

  *Rejected:* hardwiring seven stages of addressing. ALMs are the scarce resource;
  the program costs about 2 M10K.
- ✅ **The mix is not bounded by `nmix` (decided 2026-10-02).** X above a channel's
  mixed count is zero by construction:
  - XCLR clears X every subsubframe;
  - every op writes only below the channel's active count;
  - the butterfly's sums stay below the pair's larger count, which is what `nmix` is.

  So the bound only saved the model's cycles. Without it, D3's pair-bound bug cannot
  happen in hardware. The microcode still computes `nmix` (the emulator's
  `mix_own_bound` arm needs it), and the RTL ignores `a2`–`a6`. A RED arm that dropped
  the bound survived, which is how this was found; it was replaced by a gain-side swap.
- **Codebooks: fetched on demand (P1b decision; §3 and §10 planned prefetch).**
  ADPCM fetches a row when a predicted band's op starts, XVQ at each subsubframe's slice.
  The latency sweep on T2 gives the worst frame as **32.0 / 32.5 / 33.5 / 35.8 % of
  real time at latency 1 / 20 / 60 / 150 cycles**. Prefetch is not needed unless `ram2`'s
  latency turns out far above 150 cycles; P2 measures it. On-demand fetch also drops the
  2–4 M10K of local vector buffers §10's table carried.
- **Measured cycles (RTL, latency 20, worst frame of each 2-frame window):** disc
  streams 30–37 % of real time (*Shadoan* 36.8 %, T2 32.5 %), the spec-maximum frame
  shapes 33.6 % (`written_max_subframes`) and 29.3 %; the worst arm overall is 36.8 %,
  under the 60 % budget the runner enforces. The emulator's `CYC` model said 31 % worst
  and 24 % typical. The RTL's synthesis is costlier than modelled: the IMDCT program
  is about 620 cycles, against `CYC`'s 300.
- **Telemetry** (`dts_top`): frames, refused + last code + a sticky mask of codes,
  overrun bits, lenient codes (D5), ignored downmixes (D3). The bench scores each against
  the golden.
- ⏳ **Option, if M10K is short at the fit:** each window prototype mirrors itself,
  `w[511−i] = ±w[i]`, negated where bit 4 ≠ bit 5. That allows half a ROM (−1 M10K) for an
  add/subtract in the accumulator.

### P2 + P3 result: DTS wired into the core (2026-10-03, PR #149)

The AC-3 migration (`docs/ac3_engine.md` W1) made room, so P2 and P3 followed on the same
branch. One engine now runs both programs.

**P2: the codebooks (D4).**
- **The hosts.** `audio_ring`'s byte memory carries the VQ codebook (32 KB, row r's byte
  k at 8r + k). `lpcm_unpack`'s and `mp2_decode`'s PCM FIFOs carry the ADPCM codebook's
  halves (rows 0–2047 and 2048–4095, low word first).
  - Each module takes a `CB_INIT` parameter, `""` by default, so every bench is
    unaffected. Quartus gives the core's instances a MIF. A conditional `$readmemh` on a
    string parameter was tested first: Quartus rejects a *default port value*, error
    10231, so every new port is tied in every instantiation instead.
  - ⚠ **Do not name such a parameter `INIT_FILE`.** That is `altsyncram`'s own parameter
    name, and Quartus passed the module's `INIT_FILE` to ANOTHER inferred RAM in the same
    module (`mp2_decode`'s `alloc_ram`, which has no init), then read the `.mem` as a MIF:
    error 113025, "Missing syntax END". `CB_INIT` infers cleanly, re-tested with two RAMs
    in one module.
  - The images and their checksum are generated by `tools/dts_isa.py --asm` (`cb_host_*.mem`,
    `dts_cb.svh`), so `--check` covers them.
- **The copy, `dvd/dts/dts_cb_mem.sv`.**
  - It reads each host through its OWN read path: `cp_step` advances the host's read
    pointer, and the copier takes the host's existing read output (`audio_ring`'s
    `out_byte`, `lpcm_unpack`'s output register in a `cp_mode`, `mp2_decode`'s
    `pcm_head`). No host gains a read port, which would have duplicated its M10K.
  - Rows go to DDR3 at **byte 0x30800000**: the retired HPS-audio mailbox, proven readable
    and writable on hardware, above the decoder (which ends at 6 MiB), and below the
    14 MiB that reads never returned from. ADPCM rows at +0, VQ at +4096 words. 8,192 rows
    in ~225K cycles, 8.3 ms.
  - The `copied` flag has no reset term (rule 1). A Fletcher pair against `CB_SUM` gates
    `tables_ok` (rule 2), shown in telemetry words 26–28 and as `AUDIO UNSUPPORTED` on a
    DTS track if it ever fails.
  - The copy advances only while the hosts are out of reset (`hosts_ready = aud_rst_n`),
    and restarts if they are reset mid-copy.
  - ⚠ **The copy moves the hosts' read pointers, so it ends with a one-shot `host_rst`.**
    Without it the first audio after power-up would be read from the wrong place
    (mutation M9).
  - While it copies (`busy`) `emu` holds the audio path idle: no ring writes, the decoder
    parked.
- **`ram2`** (`sys/sys_top.v`, the `hw_budget_and_lessons.md` §1 recipe). `ddr_svc` stays
  on `svc_*` nets with its inputs tied off, because its `ram_bcnt` still feeds `pal_a`.
  `ram2_*` go to emu's new `DDRAM2_*` port on `clk_sys`. ⚠ `ram2` is no longer free.
- **The fetch.** `cb_req` / `cb_sel` / `cb_addr` → one 64-bit read → `cb_valid`. The
  engine waits for each row, at about 0.5 MB/s.
- **Gate `bench/dvd/run_cb_copy.sh`.** The real hosts with the core's images and a DDR3
  model that stalls 30–70 % of cycles.
  - It checks every row and that each is written exactly once, 2,000 random fetches, that
    the pointers are back at 0 after the copy, that a reset does not copy again, and that
    a swapped image is refused.
  - `--red`: 9 mutations, each caught by its own arm.

**P3: the `T_DTS` arm.**
- **Routing.** A DTS frame goes to `audio_engine` like AC-3 once `dts_tables_ok`;
  otherwise it is discarded, as before.
- **Changing program.** `audio_engine` switches only when the engine is idle at FRAME,
  holding it in reset with the new `codec` for a few cycles, and gates the descriptor
  while a change is pending (`codec_busy`).
- **The output.** DTS's stereo pairs play out of **`lpcm_unpack`'s 4,096-pair FIFO**,
  which is idle while DTS plays, so this costs no M10K. They are fed as the 4 big-endian
  bytes of a 16-bit pair, with `quant` forced to 16-bit and `cur_codec` set to LPCM for
  the output mux.
- **The stall watchdog** counts the engine's DTS frames as progress.
- **Telemetry words 25–30** (marker 0xDD03): the copy's verdict and checksum, the engine's
  frames, refusals and last refusal code. `dvd_ctl.cpp` reads 31 words.
- **Gate `bench/dvd/run_dts_dec.sh`.** DTS through `dvd_audio_decode` with a codebook
  responder; every pair the LPCM FIFO plays is checked bit-exact against `dts_golden`,
  and so is the module's own output.
  - Arms: T2; codebook latency 150; Shadoan (lenient codes); a refusal mid-frame; AC-3
    then DTS (a change of program, every AC-3 block decoded); and tables off (DTS
    discarded).
  - `--red`: 5 mutations caught, and 2 recorded as equivalent, with the reason, in the
    runner.
- **Gate `tools/check_dts_wiring.py`** reads every `emu.sv` / `sys_top.v` seam out of the
  files (`ram2`, the copy, the hold, the DTS port, telemetry). Each of three spot
  mutations fails its own claim.
- **In core** (SEED 1, `releases/DVD_ac3engine_20261003_1513.rbf`): 40,848 / 41,910 ALM,
  527 M10K (unchanged: DTS reuses the LPCM FIFO and the hosts), 92 DSP, clk_dec
  89.98 / 91.19 MHz.
  - By entity, P2 + P3 cost ~550 ALM. `audio_engine` grew 4,407 → 4,627 because DTS's
    output and codebook paths, pruned while unconnected in W1, are now live.
    `dts_cb_mem` is 172; the serialiser, the program change and telemetry ~150.
  - ~1,060 ALM remain.
- **HIL (2026-10-03):**
  - *Ultimate T2* in `Decode PCM`: **the DTS track (track 2) plays at −32 dBFS RMS**
    (`audio_check`: all 4 tracks audible). The control build measured it at −93 dBFS,
    digitally silent.
  - Telemetry: `dts_copied 1, dts_ok 1, dts_sum 6e6f7b8d` (= `CB_SUM`), 362 frames, 0
    refused.
  - **Correctness:** the title was started twice, once on the DTS track and once on the
    AC-3 track. A 6 s window of the DTS capture correlates **0.922** with the AC-3
    capture at the matching offset, and the levels agree to 0.2 dB (−39.7 / −39.5 dBFS).
    That is two independent encodes of one mix, decoded by the same engine running two
    programs (`.sim`-local script; the method is the record).
- **⏳ Still to do:** a by-ear pass on more DTS discs (the census's 147 streams pass in
  the emulator). The manual is updated, and the release bump is a minor one.

### P1b result: the standalone fit, the go/no-go (2026-10-02)

`USE_DOCKER=1 tools/fit_unit.sh dts_top "clk=27" dvd/dts/dts_seq.sv dvd/dts/dts_vec.sv
dvd/dts/dts_top.sv`: Quartus 17.0.2, every port a virtual pin, SEED 1, both slow corners.

| | First fit | **Final fit** (after the packing below) | §4 / §10 estimate | In the core |
|---|---|---|---|---|
| ALM | 2,176 | **2,227**: sequencer 853, vector engine 1,120, top 254 (about 100 of telemetry; the rest is virtual-pin packing) | engine 1,600–2,000 | ~1,125 spare at 97 % |
| M10K | 43 | **31** | 30–34 | 41 free |
| DSP | 1 | **1** | 1 | 17 free |
| Fmax, −40 °C (binding) | 37.7 MHz | **35.8 MHz** (1.33× the clock); 37.7 at 100 °C | — | 27 MHz |

In the core, expect **about 2,070 ALM** for the engine and its telemetry. The standalone
2,227 includes ~150 of the fitter's "unavailable" packing beside the virtual pins, which
will not carry over as is. Packing beside the decoder will differ, not vanish.

**Cycles** (the calibrated emulator, `tools/dts_cycles.py --dir "$DTS_CENSUS_DIR"`, default `~/dts-streams/census`):
**every frame of all 327 census windows (61,678 frames, 147 streams on 90 discs) within
39.8 % of real time**, the worst on *Shadoan*. None was refused. On the RTL bench the
gate set's worst frame is 37.1 % (`tools/test_dts_isa.py`, 8 frames a stream).

**Verdict.**
- **Cycles, timing, M10K, DSP: go.** ⚠ The Fmax flatters: alone on an empty device
  the placer has room it will not have beside the decoder. A 33 % margin is a good start,
  not a promise.
- **ALM: DTS alone does not fit.** About 2,100 for the engine and its telemetry, against
  ~1,125 spare. §4's scenario table holds: A (DTS alone) and B do not fit, and the
  **AC-3 parse migration (D) stays on the critical path**. This is the maintainer's
  decision, and it orders P2, P3 and P4. No P4 work is started.

**The M10K packing (43 → 31).** Most of the 43 was packing, not capacity. Each change
was re-proved by both gates (`run_dts_seq.sh --red`, `run_dts.sh --red`) before the refit:
- **Huffman tree 13 → 6** (decided). Quartus put 2,647 × 26-bit absolute nodes in
  4K × 2 mode. Two changes fixed it:
  - **A child is stored as an offset forward from its node.** The build order keeps
    every child after its parent (1–118 measured), and the symbols are −64…64. So an
    entry is `{leaf, 8 bits}` and a node 18 bits.
  - **The tree is split into two ROMs**, 2,048 words (2K × 5, 4 blocks) and 1,024 (2),
    with a 2:1 mux. A single ROM sliced 512 deep (`max_depth`) also gave 6 blocks, but
    a 6:1 mux of 40 ALMs.

  The generator decodes its image back and checks every code. RED Q18 (the offset
  taken from the root) is caught.
- **Microcode 4 → 2** (decided). The program was 9 words over 512. A taken branch to
  an error vector (`ERR_BASE` + code, pc 992–1023) now acts as `err code`, so the 21
  one-word `err` stubs are gone. The program is 500 words. The assembler refuses
  `jmp`/`call` to a vector and a program that reaches the vectors. RED Q19 (a vector that
  is not an error) is caught.
- **Four tiny RAMs 4 → 1** (decided). The IMDCT scratch, the window's carried sums and
  the PCM pairs share one 256 × 29 M10K: their phases never overlap. A simulation-only
  check `$fatal`s on a same-cycle write collision. The emit reads L and R one after the
  other, which adds 32 cycles to each MIXSYN.
- Cost of all three: about +50 ALMs (the child adder, the vector decode, the shared RAM's
  muxes), and Fmax 37.7 → 35.8 MHz.
- ⏳ **Recorded, not taken: the window half.** Each prototype mirrors itself,
  `w[511−i] = ±w[i]`, negated where bit 4 ≠ bit 5. That saves one M10K for an
  add/subtract in the accumulator. With ALMs binding and M10K at 31, it was not worth it.
- ⏳ **ALM options, recorded, not taken (not measured one by one; ~200–300 together,
  which does not change the verdict):**
  - The constant ROM (92 × 16), the IMDCT coefficients (113 × 27) and the book roots
    (62 × 12) went to logic. In M10K (10 spare) they would cost 1–2 blocks and return
    perhaps 100–150 ALM.
  - `dts_vec` latches r8–r15 into its own 128 flip-flops. The sequencer's registers hold
    still while an op runs, so the engine could read them directly (perhaps 60).
  - The 56-bit accumulator and rounding shifter: the measured sums need about 51 bits.

**The handoff's open decisions, closed:**
- ✅ Block-code division: restoring, the first digit divided as its bits arrive (above).
- ✅ `mod_a`'s −85,479,984: stored halved, shift 22, inside the IMDCT program.
- ✅ The cycle model: `dts_isa.CYC` was rebuilt from the RTL's structure. It is within
  −0.22 / +0.04 % of the RTL bench on every timed arm, so `tools/dts_cycles.py` and
  `test_dts_isa.py` [2] give RTL-accurate real-time margins cheaply.
- ✅ A standalone-fit script: `tools/fit_unit.sh`.
- ⏳ **A refused frame's output: deferred to P3**, with the PTS gate. Today the engine
  emits the PCM it produced before the error and nothing after it (a refusal at the last
  DSYNC leaves half the frame's pairs). The benches pin that behaviour (R1).
- ⏳ `ram2`'s latency (P2): the cycles are reported as a function of it, 32 % → 36 % of
  real time from 1 to 150 cycles. Prefetch is needed only far above that.

**Gates for this engine:** `bench/dvd/run_dts_seq.sh --red` (37 arms, 19 mutations),
`bench/dvd/run_dts.sh --red` (41 arms, 18 mutations), `python3 tools/test_dts_isa.py`,
`python3 tools/dts_vecrom.py`, `python3 tools/dts_isa.py --asm --check`. Streams come
from `DTS_GATE_DIR` (default `~/dts-streams/gate`, rebuilt by
`tools/gen_dts_fixtures.py --discs`).
