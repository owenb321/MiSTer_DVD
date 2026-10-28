# The AC-3 IMDCT on the shared audio engine (logic reclaim, `logic_reclaim.md` §10a)

**Status (2026-10-28):** I0 (the design), **I1 (the program and its emulator) ✅**, **I2
(the RTL, `dts_vec` op 25) ✅ in simulation**, **I3 (wired into `audio_engine`, `imdct_512`
out of the build) ✅ fitted: −2,137 ALUTs, −13 M10K, −7 DSP, timing PASS** (below); on `feature/logic-reclaim-f` (stacked on `feature/vm-snapshot`,
unpushed). I4 (by ear on the rig) ⏳. **Why now:** the save-states merge gate
(`roadmap.md` "Save states") needs ~370 ALM back; `mult22x16` gave 209 (§11a there), and
the maintainer chose this item to close the rest (2026-10-28).

## What moves, and what it must equal

`dvd/ac3/imdct_512.sv` is the last hardwired AC-3 stage: **2,053 ALM, 23 M10K, 9 DSP**
(the save-states fit, `_2214`). After the engine parses a block (`ac3.uasm`, op 25
`IMDCT`) it hands `imdct_512` the coefficients in X; `imdct_512` runs PRE (DRC and the
pre-twiddle), a 128-point IFFT as a flat schedule of 157 (long) or 134 (short)
butterflies, POST (post-twiddle, window, overlap with the delay line) per channel, then
the acmod-aware 5.1 → stereo fold, into `pcm_mem`, which `pcm_out` drains.

**Contract: bit-identical to `imdct_512`** (the maintainer's decision of 2026-10-05,
§10a): Q8.23 words that wrap at 32 bits, Q1.17 twiddles, every product
`(sample × tw) >>> 17` floored before it is added, the same operation order where it
matters. `tools/imdct_model.py` is that arithmetic in Python and is already proved equal
to the RTL on 360 blocks (`bench/ac3/run_imdct_xcheck.sh`). The engine version is scored
against the model and then against `imdct_512` itself, block for block, on what
`pcm_out` reads (slots 0 and 1).

## Design

### Execution: a term program, as DTS's half IMDCT

DTS's half IMDCT is already a ROM program of multiply-accumulate terms run one a cycle on
the engine's multiplier (`tools/dts_vecrom.py`). The IMDCT uses the same idea at a larger
scale, as §10a recommended: **templates, not a flattened program.** Flattening is ~6,100
terms a long block, ~15 M10K, ruled out. Instead:

- a **template ROM**: per element kind (PRE, the five butterfly ops `IFFT2`, `IFFT4`,
  `BZERO`, `BHALF`, `BFULL`, long POST, short POST, the fold), the sequence of terms that
  computes one element. A term names its operands **symbolically** (`c2.re`, `T.im`,
  `d0`, the element's `wr`), not by address;
- a small **sequencer** that walks the element list (PRE i = 0..127; the existing
  schedule tables `imdct_sched_*` / `imdct_s256_*`; POST i; the fold k) and resolves a
  symbol to an address with that element's indices.

Control costs ROM words; ALMs are the binding resource (`hw_budget_and_lessons.md`).

### A term

One cycle issues one term: read one RAM word (or none), optionally multiply it by a ROM
constant, and fold it into the accumulator:

- `acc (=|+=|-=) floor(sample × const >> 17)`: a product (each floored, as `imdct_512`).
  Subtraction must negate the floored product, not an operand: `floor(-x) ≠ -floor(x)`;
- `acc (=|+=|-=) sample`: an add;
- on the element's last term, write `acc` to its destination.

DRC is the one variable shift (`(c × mant) >>> (5 − e)`).

### Datapath changes in `dts_vec`

1. **The sample operand widens to 33 bits** (`ma`, today 27). A sample is a 32-bit word,
   or BHALF's pre-sum of two (33 bits, `imdct_model` `m0..m3`), and it must be multiplied
   exact: `imdct_model` shows legal input reaches 32-bit words, so §10a's "27 bits, split
   when wide" would have to split often on extreme streams; this removes the case. Cost:
   likely +1 DSP (33 × 27) and its adder; `imdct_512` frees 9.
2. **A product mode in stage Y**: the product is floored by 17 and optionally negated
   *before* it meets the accumulator. A fixed shift is wiring plus a mux.
3. **The ring widens 32 → 35 bits.** Free: a 2,048-deep M10K is 5 bits a block, so 32
   and 35 bits are both 7 blocks. Temporaries that feed a multiplier (`m0..m3`) are 33
   bits and must be stored exact; sums stored as 32 bits are exact because every value
   that reaches `pcm` or the buffer is reduced mod 2^32 anyway.

### Memory map (AC-3 never runs with DTS or MP2, so it takes their buffers)

| What | Where | Words |
|---|---|---|
| coefficients (in) | X, `{slot, bin}`, as today | — |
| the work buffer, 128 complex | ring | 256 |
| temporaries (T, U, tt5.., m0..m3, PRE/POST partials) | ring | ≤ 32 |
| the delay line, 5 channels × 128 | ring | 640 |
| PCM out, slots 0 and 1 × 256 | ring | 512 |
| templates, the schedules, the twiddle / window / order tables | ROM | ~3–4 M10K |

`pcm_out` reads the ring between the block's `done` and `pcm_done`; the engine touches
the ring only while it transforms, which waits for `pcm_done` (today's handshake). So the
ring's read port is muxed, not duplicated.

### The fold, accumulated

`imdct_512` writes six slots and then folds 5.1 → 2 (`S_DMX`). Here each channel adds its
share into the two output slots as its POST finishes: `Lo = L + p(C, clev) + p(LS, slev)`
mod 2^32, and addition mod 2^32 is order-free, so it is **exact** (each `p()` is formed as
before). The first contributor to a slot writes, the rest add. Two slots instead of six,
and no separate pass.

### `lvl_q`, `pcm_acmod`

`imdct_512`'s `lvl_q` is combinational in acmod and the mix levels; it moves to
`audio_engine.sv` with the latches that already hold them.

## ⚠ Deltas from `imdct_512` (maintainer to confirm)

1. **A channel's delay line reads 0 until that channel has been transformed since the
   engine's reset** (5 valid bits, not `imdct_512`'s one `first_blk`). The ring holds
   DTS/MP2 junk, so a channel a stream adds mid-play (2/0 → 3/2) must not overlap with it;
   `imdct_512` reads its never-written M10K, zero from power-up, so from power-up the two
   agree. They differ only after a program switch: the engine is reset on one and
   `imdct_512` is not, so today the first AC-3 block after a DTS interlude overlaps with
   the *previous AC-3 track's* tail. The new behaviour is the correct one (a fresh state).
2. Slots 2–5 no longer exist. Only `pcm_out`'s slots are kept; benches that read all six
   (`run_imdct_xcheck.sh`) stay on `imdct_512`'s copy until it is deleted.

## I1 result: the program and its emulator (2026-10-28)

`tools/imdct_isa.py` holds the templates (data: a term is `(mode, src, const, dst,
wrap)`, operands symbolic), the walk, and a cycle-accurate executor: one term a cycle,
a read presented the cycle before issue, a write landing two cycles after, and a read of
a word still in flight **stalls** (sequential semantics). The butterflies whose outputs
overwrite their own inputs (IFFT2, BZERO, BHALF) copy them to temps first: +216 terms a
long channel (~3.5 %), the price of a program that reads top to bottom.

- **Gate `tools/imdct_isa.py check`** (`--frames 24`, `--random N`), against
  `imdct_model` (itself `== imdct_512`, `run_imdct_xcheck.sh`, re-run after the model's
  IFFT + POST became a method, `ifft_post`):
  - **[strm]** all 31 AC-3 gate streams, 24 frames, every block: pcm slots 0/1 (slot 0
    for mono) and every channel's delay line. **Bit-identical**;
  - **[unit]** IFFT + POST from an INJECTED work buffer and delay line (any 32-bit
    words, clusters at the rails): the only arm whose BHALF pre-sums reach **33 bits**
    (no coefficient pattern through PRE did, max 32), and it fails as vacuous if they don't;
  - **[rand]** random and full-scale blocks with max DRC, 1–5 channels, every acmod,
    three blocks a case so the delay line carries; the ring powers up as JUNK (what DTS
    leaves).
- **`--red`: 7 mutations, all caught:** short-block delay sign, DRC shift, negating the
  operand instead of the floored product, no delay-line mask, a surround level, BHALF's
  pre-sums stored at 32 bits (caught only by [unit]), BFULL's `wi` as `wr`.
- **Cycles:** worst block 35,408 (5.1, `noise_5p1`), 24.6 % of a frame; **0 stalls** on
  every stream once an element forms all its fold words before adding any share (the
  first version stalled 768 cycles a 5.1 block). Stereo 13,344 a block.
- **The budget gate now charges it.** `tools/test_ac3_isa.py` [2] replaced `imdct_512`'s
  measured `IMDCT_BLOCK` with `imdct_isa.frame_cycles` for each frame's own blocks, at the
  same ×1.25 headroom as the other modelled charges. **Worst frame 58.8 %**
  (`noise_5p1`) against the 60 % bar: PASS, every stream.
- ⚠ **That needs elements back to back** (`ELEM_OVH = 0`): the sequencer fetches the next
  element's schedule entry while the current one issues. At one cycle an element the worst
  frame is 63.7 %, a FAIL. It is a requirement on I2, which its bench must prove by
  matching the emulator's cycles exactly; then the ×1.25 can drop (52.7 %).
- **Margin levers, if I2 comes in slower:** a second ring read port (a duplicated
  256-word buffer RAM, +1–2 M10K) makes an add of two words one term (IFFT −25 %, about
  4 points); the pipeline's three-cycle window lets IFFT2/BZERO/BHALF skip their copies
  (about 1 point).

## I2 result: the RTL (2026-10-28)

`dvd/dts/dts_vec.sv` op 25 runs the term program (`dvd/dts/imdct_tprog.mem`, 653 × 20,
and `dvd/dts/imdct_isa.svh`, both written by `tools/imdct_isa.py asm`, which `--check`s
them) on the shared datapath. Three stages ahead of it: **F** walks the element (phase,
channel, index, term) and prefetches the next element's `fftorder` / schedule entry, so
elements run back to back; **R** resolves the term's sample, constant and destination
symbols against the element's context (one mux, the same code for source and
destination), presents the ring / X / constant reads, and **stalls** while its ring word
has a write in flight in I or in stage Y (the term ROM's output register is held, so the
waiting word is not overwritten); **I** issues on the multiplier. `imdct_512`'s own table
file supplies the schedule, twiddles, window and order (`ac3_imdct_tables.svh`, its include
guard undefined on both sides so a bench that compiles both modules gets two copies).
- **Datapath:** `ma` 27 → 33 bits (two MP2 operands needed explicit sign extension:
  `{{11{a1[15]}}, a1}` and `ss[26:0]` would have zero-extended into the wider port);
  `x_prod` 54 → 56; a product mode in stage Y (`psh`: floor by 17 before the
  accumulator; `psub`: subtract the floored product); the ring 32 → 35 bits, written
  sign-extended from 32 or (`w35`) whole.
- **The ring's read port** is `pcm_out`'s (`{2'b11, slot, idx}`) unless an op reads the
  ring (DTS's and MP2's windows, the IMDCT), so V_WIN now states its address.
- **Five valid bits**, one a channel, mask a delay line until its channel is transformed.
- **The stalls are real:** the DRC → PRE seam stalls 1–2 cycles a channel (PRE's first
  element reads `D[255]` / `D[254]`, DRC's last writes). All 270 configurations (acmod ×
  per-channel short × surround level, two blocks each) stall 3,186 cycles in all,
  data-independent. The I1 figures that showed none were taken while phase barriers
  hid them.
- **ISKIP (`a7[0]`, benches only)** starts the walker at the IFFT, so a bench can write an
  injected buffer: no coefficient block reaches a 33-bit pre-sum through PRE (400
  full-scale, max-DRC blocks searched: 32 bits at most), and this is the only way to test
  the 33-bit path and the 35-bit store in RTL.

**Gate `bench/dvd/run_imdct_eng.sh --red`** (`imdct_eng_tb.sv`, `dts_vec` alone, one
continuous run from a junk ring: one frame each of 5.1, 3/0, 2/1, 3/1, 2/2, dual mono,
mono, short-block 5.1 and a DRC stream, 16 random and full-scale blocks, 8 ISKIP items):
after every item **all 2,048 ring words** equal the emulator's, temporaries included,
and **go → `imdct_fin` equals the emulator's cycles**, so `test_ac3_isa.py`'s budget
charges the RTL's own count. 78 items PASS. 11 mutations, each failing exactly its arm
(the bench scores the ring before the cycles, so a mutation that breaks both names
[ring]): subtraction, the stall, the 35-bit store, the delay mask, short POST's window,
short PRE's pairing, R-after-C, the DRC shift, ISKIP's schedule read, a write to the
source's address → [ring]; a stall on every write in flight (values right) → [cycles].

**In the engine** (`audio_engine.sv`, I3's wiring; the parse gates unchanged):
- `bench/dvd/run_ac3.sh`: all 36 arms GREEN, the transform now the engine's own. **Worst
  frame 53.5 % of real time** (`noise_5p1`, B1), measured on the RTL.
- **`bench/dvd/run_ac3_ab.sh`: PCM identical to `ac3_front` + `imdct_512`, block for
  block, on every stream** (5.1, short blocks, DRC, refusal windows, dual mono). One fix
  to the bench: it now zeroes the old side's `pcm_mem` / `delay_mem` at time 0 as
  `imdct_xcheck_tb.sv` does, because a 3/0 fold multiplies a never-written surround slot
  by `slev = 0` (0 on silicon, X × 0 = X in simulation); before, both sides carried the
  same X and the compare passed on it.

## I3 result: the fit (2026-10-28)

`DVD_reclaim_20261028_0538.rbf` (SEED 7, commit `06d9e5e`), per entity against the
save-states build `_2214` (`feature/vm-snapshot`) and the F fit (`_0049`, `mult22x16` only):

| | `_2214` (save states) | F | **I3** |
|---|---|---|---|
| Device ALUTs | 61,776 | 61,211 | **59,074** |
| Device "ALMs needed" (packing-noisy) | 41,100 (98 %) | 41,075 | **37,976 (91 %)** |
| M10K | 533 | 533 | **520** |
| DSP | 91 | 91 | **84** |

- **`dvd_audio_decode`: −1,546 ALM, −2,503 ALUTs, −13 M10K, −7 DSP.** `u_imdct` goes
  (−2,053 ALM / −3,196 ALUTs / −23 M10K / −9 DSP); `dts_vec` grows +419 ALM / +605 ALUTs /
  +10 M10K / +2 DSP (the walker, the template and table ROMs, the 35-bit ring, the 33×27
  product), `dts_seq` +67 ALM. The estimate was −1,400 … −1,700 ALM, ~−20 M10K, −8 DSP: the
  M10K came in 7 better than feared and 7 worse than hoped (each new table its own block).
- Every new memory infers as `altsyncram` (`DVD.map.rpt`: `tprog`, `ring`, `imdct_window`,
  `imdct_pre_pk`, `imdct_post_pk`, `imdct_sched_pk`, `imdct_fftorder`).
- Timing: `clk_dec` 90.75 / 87.84 MHz (target 86), `clk_mem` 92.41 / 94.93 MHz (target 90),
  `lint_undriven`, `netlist_canary`: PASS.
- Unrelated entities moved by ±50–190 ALM (`mem_shim_burst` +187, `motcomp` −375): fitter
  packing, with ALUTs flat (±60). The ALUT column is the measure.

## Plan and gates

- **I1, the program and its emulator** (`tools/imdct_isa.py`): the templates, the
  sequencer's walk and the term executor in Python, shaped like the RTL (one term a cycle,
  the ring's one read and one write, stage Y's two-cycle write latency and the bubbles it
  forces). Gate: bit-identical to `imdct_model.Imdct512` on slots 0/1 and the delay line,
  every block of the AC-3 gate streams, plus random and extreme (full-scale, max DRC)
  blocks. Its cycle count replaces `test_ac3_isa.py`'s `IMDCT_BLOCK`, so the 60 % budget
  gate scores the real plan. **Go/no-go on cycles.**
- **I2, the RTL** (`dts_vec` op 25 executes; ROM images generated by I1): bench against
  the I1 emulator per block, then `run_ac3_ab.sh`-style against `imdct_512` (both in one
  bench), on every gate stream; mutation arms per template class.
- **I3, the wiring and fit**: `audio_engine` loses `imdct_512`; `pcm_out` reads the ring;
  `lvl_q` moves. Fit by entity against `_2214` and the F fit; timing; M10K must fall.
- **I4, HW**: by ear on 5.1, short-block (`bbb_short_5p1`) and stereo material, against
  `main` on the rig; `audio_check.py` across a disc's tracks.

**Estimate** (to be replaced by I3's fit): −2,053 ALM / −23 M10K / −9 DSP for
`imdct_512`; + the sequencer, the template walk and the datapath changes (+300 … +600
ALM, +3–4 M10K, +1 DSP). Net **−1,400 … −1,700 ALM**, about −20 M10K, −8 DSP.
