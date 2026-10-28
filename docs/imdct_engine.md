# The AC-3 IMDCT on the shared audio engine (logic reclaim, `logic_reclaim.md` §10a)

**Status (2026-10-28):** I0, the design, on `feature/logic-reclaim-f` (stacked on
`feature/vm-snapshot`, unpushed). Nothing built yet. **Why now:** the save-states merge gate
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

1. **The delay line starts from zero after a DTS/MP2 ↔ AC-3 program switch.** The engine
   is reset on a program switch; `imdct_512` is not, so today the first AC-3 block after a
   DTS interlude overlaps with the *previous AC-3 track's* tail. The new behaviour is the
   correct one (a fresh decoder state) and costs nothing; `imdct_512`'s is unreachable in
   a bit-exact A/B without a switch, so the A/B gates run without one.
2. Slots 2–5 no longer exist. Only `pcm_out`'s slots are kept; benches that read all six
   (`run_imdct_xcheck.sh`) stay on `imdct_512`'s copy until it is deleted.

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
