# AC-3 Decoder — Architecture & Interface Plan

> **Provenance:** ported verbatim from the standalone `MiSTer_AC3` repo (now
> archived) on 2026-06-27. The AC-3 decoder RTL lives here at `dvd/ac3/*`; this is
> its canonical module/interface/fixed-point reference. See `docs/ac3_decoder.md`
> for the supported-feature scope, `err_unsupported` triggers, golden-reference /
> verification setup, and durable design decisions, and `docs/fabric_audio.md` for
> how it's wired into the DVD core (`dvd/dvd_audio_decode.sv`).

Status: **complete + hardware-validated** (in the standalone core). This document is
the canonical module/interface contract for the full-fabric AC-3 decoder. RTL is
written against the port lists and handshake rules defined here.

---

## 1. Scope

> **HISTORICAL — the "Decision" column below was the original strict PoC scope.**
> The PoC is complete (see `CLAUDE.md` "Project status"); the table now records
> where each feature ended up. The **canonical, current** "supported / not-yet-
> supported" list lives in `CLAUDE.md` — consult that, not this column, for what
> the decoder handles today. The fail-loud principle still holds: anything a
> stage does not yet implement sets a sticky `err_unsupported` (hardware) /
> `$fatal` (sim), never decodes silently wrong.

| Feature | Original PoC decision | Status now |
|---|---|---|
| Codec | Plain AC-3 (ATSC A/52). **No E-AC-3.** | unchanged (no E-AC-3) |
| Sample rate | 48 kHz only (`fscod == 0b00`) | unchanged (48 kHz) |
| Channel mode | `acmod == 2` (L/R stereo) only | **acmod ∈ {2, 7}** (stereo + 5.1) — M14 |
| LFE | `lfeon == 0` only | **lfeon ∈ {0,1}** (parsed; off the downmix) — M14 |
| Coupling | **Not supported** (assert if `cplinu`) | **supported** — M12 |
| Rematrixing | **Not supported** (assert if any `rematflg` band active) | **supported** (stereo) — M12 |
| DRC / dynrng | **Not applied** (parse + discard) | **applied** — M17 (per-block gain at the IMDCT PRE read) |
| Downmix | **Not supported** | **5.1 → stereo Lo/Ro** — M14 |
| Exponent strategies | D15 / D25 / D45 **and reuse** | unchanged (all supported) |
| Block length | **Long blocks only** (512-pt IMDCT); short blocks detect + assert | **long + short** (256-pt short IMDCT) — M16 |
| Input | AC-3 elementary-stream bytes via FIFO | unchanged |
| Output | 16-bit signed PCM, L/R | unchanged |

> **Note (rematrixing).** A/52 sends a `rematstr` *strategy* bit; if set, the
> per-band `rematflg` bits follow (4 bands when uncoupled). ffmpeg's stereo AC-3
> commonly sets `rematstr==1` but leaves every `rematflg` band 0 — i.e. it
> signals the strategy yet applies no rematrixing. Such a block is decodable in
> scope, so `audblk_parse` asserts only on an **active** band (`rematflg!=0`),
> not on `rematstr` alone. This matches liba52's `state->rematflg`.

> **Note (real ffmpeg streams use coupling).** ffmpeg's AC-3 encoder enables
> **channel coupling** for stereo at typical bitrates (it was on at 192 kbps in
> our `tone`/`silence` streams), and **rematrixing** whenever L/R correlate —
> both out of PoC scope. Coupling turns off only at high bitrate (≈384 kbps+);
> rematrixing is avoided by decorrelated content. The in-scope co-sim stream is
> therefore **independent stereo white noise at 640 kbps** (no coupling, block-0
> `rematflg==0`). This matters for M5+: a real positive decode needs an in-scope
> stream, and a few *mid-frame* blocks may still rematrix even there.

---

## 2. Top-level dataflow

```
            byte stream (AC-3 ES)
                  │
            ┌─────▼──────┐
            │  bit_fifo  │  async FIFO, FWFT/show-ahead, byte-wide
            └─────┬──────┘
            ┌─────▼──────┐
            │ bit_reader │  barrel shifter; get_bits(n), bit position
            └─────┬──────┘
   ┌──────────────┼───────────────────────────────────────────┐
   │   CONTROL / PARSE plane (sequential, irregular syntax)     │
   │  ┌──────────┐  ┌──────────┐  ┌─────────────┐               │
   │  │ sync_crc │─▶│ bsi_parse│─▶│ audblk_parse│ (FSM heart)   │
   │  └──────────┘  └──────────┘  └──────┬──────┘               │
   └───────────────────────────────────-─┼──────────────────────┘
                                          │ side info + packed data → BRAMs
   ┌──────────────────────────────────────┼──────────────────────┐
   │   DSP / DATAPATH plane                ▼                       │
   │  ┌────────────────┐  ┌───────────────┐  ┌──────────────────┐ │
   │  │ exponent_decode│─▶│ bit_allocation│─▶│ mantissa_dequant │ │
   │  └────────────────┘  └───────────────┘  └────────┬─────────┘ │
   │                              ┌────────────────────▼─────────┐ │
   │                              │  imdct_512  (pre→IFFT128→post │ │
   │                              │             →window→overlap) │ │
   │                              └────────────────────┬─────────┘ │
   └───────────────────────────────────────────────────┼──────────┘
                                          ┌─────────────▼─────────┐
                                          │ pcm_out → AUDIO_L/R    │
                                          └────────────────────────┘
```

Because the PoC is **strict full-fabric RTL** (no soft core, no microcoded
sequencer), the control plane is a set of explicit hand-written FSMs. The
control FSMs walk the bitstream and write intermediate results into block RAMs;
the datapath FSMs consume those BRAMs. The two planes hand off per audio block.

### Block-level timing model (one audio block at a time)

```
parse(exp strat, packed exps, ba params) → exponent_decode → bit_allocation
   → parse(mantissas, using bap[]) → mantissa_dequant → imdct_512 → overlap → PCM
```

This mirrors the Han thesis Fig 6.1 timing: parse stalls while a datapath stage
runs, datapath stalls while parsing. No pipelining across blocks in the PoC —
correctness first, throughput later. (At 48 kHz, 6 blocks/frame × ~31 fps we have
millions of cycles of headroom at any plausible clk_sys, so a fully serial
block loop is fine.)

---

## 3. Handshake contract

Two contracts are used, picked per interface:

### 3a. Stream handshake (ready/valid) — between datapath stages

AXI-Stream-like, synchronous to a single clock:

- Producer drives `o_valid`, `o_data`; sees `i_ready`.
- Consumer drives `i_ready`; sees `o_valid`, `o_data`.
- A transfer happens on a cycle where `valid && ready`.
- `valid` must not depend combinationally on `ready` (no comb loops).
- Data is stable while `valid` is high and `ready` is low.

### 3b. Request/grant — for `bit_reader` and BRAM-backed stages

Single outstanding request, pulse-based:

- Consumer pulses `req` for one cycle with parameters (e.g. `nbits`).
- Producer asserts `ack` for one cycle when the result is on the output bus.
- Minimum latency is fixed and documented per module (deterministic for tests).
- Consumer must wait for `ack` before issuing the next `req`.

The control plane (sync_crc / bsi / audblk) talks to `bit_reader` over 3b. The
datapath stages talk to each other over 3a, with BRAMs (true dual-port) holding
the per-block arrays (exponents, bap[], coefficients) that several stages touch.

---

## 4. Module interfaces

Shared definitions live in [`rtl/ac3/ac3_defs.svh`](../rtl/ac3/ac3_defs.svh).

### 4.1 `bit_reader` (implemented first — see §6)

MSB-first barrel reader over a byte FIFO.

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `clk` | in | 1 | system clock |
| `rst` | in | 1 | synchronous, active-high |
| `fifo_dout` | in | 8 | head byte of source FIFO (**FWFT/show-ahead**) |
| `fifo_empty` | in | 1 | source FIFO empty |
| `fifo_rd` | out | 1 | 1-cycle pop strobe (advances FWFT FIFO) |
| `req` | in | 1 | request `nbits` (pulse, only when idle) |
| `nbits` | in | 6 | bits to read, 1..`MAXW` |
| `ack` | out | 1 | 1-cycle: `data` valid this cycle |
| `data` | out | `MAXW` | result, **right-justified**, zero-extended |
| `bitpos` | out | 32 | running count of bits consumed (for frame size / CRC / alignment) |

- Parameter `MAXW` (default 32). AC-3 fields are ≤ 16 bits in practice, but 32
  keeps the reader general.
- Latency: when ≥ `nbits` bits are already buffered, `ack` is **2 cycles** after
  `req`; add 1 cycle per byte that must be fetched from the FIFO. Stalls
  (holding `req` latched, `ack` low) while `fifo_empty`.
- Bit order: AC-3 reads MSB-first; the first stream bit is bit 7 of byte 0.
- Future (not in first cut): `align` op (skip to next byte boundary, for AUX/CRC),
  `skip(n)` without returning data. The consumer can already byte-align using
  `bitpos[2:0]`.

### 4.2 `sync_crc` (implemented — M2)

- In: `bit_reader` (3b), reset/control + a `start` re-arm pulse.
- Finds `0x0B77`; reads `crc1`, `fscod`, `frmsizcod`; derives `frame_words`
  (from A/52 frame size table). CRC is **optional** for the PoC (compute + flag,
  do not gate). Asserts `err_unsupported` if `fscod != 0` (non-48 kHz) or
  `frmsizcod` invalid.
- On a parsed header it pulses `frame_hdr_valid` and **stops** (S_DONE),
  releasing the `bit_reader`. The frame-body skip/resync that used to live here
  **moved to `ac3_parse`** (M3) so that `bsi_parse` can run between the header
  and the skip. `start` re-arms a fresh sync search for the next frame.
- Out (regs): `fscod`, `frmsizcod`, `frame_words`, `frame_bytes`, `synced`,
  `crc1`, `sync_bitpos`, `err_unsupported`.

### 4.2a `ac3_parse` (implemented — M3): front-end parse sequencer

- Owns the single `bit_reader` request/grant port and time-shares it between
  three requesters, exactly one granted at a time: **sync_crc** (header) →
  **bsi_parse** (BSI) → an internal **skip FSM** (discard the rest of the frame
  body), then re-arms sync_crc for the next frame.
- `ack`/`data`/`bitpos` from `bit_reader` are broadcast to all requesters; each
  only acts while it has an outstanding request, and hand-offs happen on idle
  pulses (`frame_hdr_valid` / `bsi_valid` / skip-done) so no request is ever in
  flight across a grant change. The req/nbits lines are mux'd by the grant.
- **Body skip is computed from the frame length**, not from where BSI stopped:
  `target_bitpos = (sync_bitpos − 16) + frame_bytes·8`. Because sync is found on
  a byte boundary and the frame length is whole bytes, the target is always
  byte-aligned, so the next `0x0B77` search starts byte-aligned even though BSI
  consumed a variable, bit-granular number of bits. The skip discards
  `target − bitpos` bits in ≤24-bit chunks. (When M4 lands, `audblk_parse`
  replaces this discard with a real block-by-block parse.)
- Any `err_unsupported` from sync_crc or bsi_parse drives the sequencer to a
  halt state (`P_HALT`) — never decode out of scope.

### 4.3 `bsi_parse` (implemented — M3)

- Driven over 3b by `ac3_parse`; started by sync_crc's `frame_hdr_valid` pulse.
- Walks the full A/52 §5.3 `bsi()` syntax, **honouring every conditional field**
  (compre/compr, langcode/langcod, audprodie, timecod1/2, addbsi) so the bit
  position after BSI is exact — even though the body-skip doesn't depend on it,
  BSI must not over-read past the frame.
- Latches `bsid`, `bsmod`, `acmod`, `dsurmod`, `lfeon`, `dialnorm`; everything
  else is parsed and discarded.
- **Scope guards:** sets sticky `err_unsupported` and halts in `B_ERR` if
  `acmod != 2` or `lfeon != 0`. (For `acmod==2`: no cmixlev/surmixlev, `dsurmod`
  present, no dual-mono block — the decoded path is specialized to this case.)
- Out: `bsi_valid` (1-cycle pulse), the latched fields, `err_unsupported`.
- Verified: chain TB (synthetic frames with ffmpeg-identical BSI bytes
  `40 43 E1`) + Verilator/liba52 co-sim golden-checking acmod/lfe per frame.

### 4.4 `audblk_parse` (the conditional-syntax heart) — implemented (M4)

The big FSM. Walks one audio block's **side information** in bitstream order
(A/52 §5.4.2.2), honouring every conditional so the bit position stays exact,
and stages what later stages need. Driven over 3b by `ac3_parse`, started on
`bsi_valid`. Fixed to `acmod==2` (`nfchans=2`), `lfeon==0` (guaranteed by
`bsi_parse`).

Bitstream order parsed (acmod==2, no coupling, lfeon==0):

```
blksw[2] dithflag[2] dynrnge (dynrng8) cplstre (cplinu) rematstr (rematflg4)
chexpstr[2]  {chbwcod6}*nonreuse
{ exp0:4  {grp:7}*nchgrps  gainrng:2 }*nonreuse
baie (bai11)  snroffste (csnroffst6  {fsnr4+fgain3}*2)
deltbaie ({deltbae:2}*2  {deltnseg3 {seg:12}*(deltnseg+1)}*new)
skiple (skipl9 skipfld)
```

- **Geometry** (== liba52 `parse.c`): `endmant = chbwcod*3 + 73`;
  `grpsz = 3<<(chexpstr-1)` (D15/D25/D45 → 3/6/12); `nchgrps = (endmant + grpsz
  − 4)/grpsz`. `chbwcod` is a **separate per-channel loop** from the
  exps+gainrng loop — the order matters for bit-exactness. `gainrng` (2 bits) is
  read after each non-reuse channel's exponents.
- **Staged**: packed (grouped) exponents → `exp_mem` (128 slots/channel, idx 0 =
  4-bit absolute, idx 1..nchgrps = 7-bit group codes; read back by M5 over the
  combinational `exp_rd_addr/exp_rd_data` port — written one slot/cycle during
  parse, read out later while the bit_reader is idle, so they never collide);
  bit-alloc params + snr offsets + per-channel geometry (`chexpstr/chbwcod/
  endmant/nchgrps`) → regs. Emits `block_side_valid` + `blk_bits`.
- **Scope guards (fail loud)**: `blksw[ch]==1` (short block), `deltbae==3`
  (reserved), cpl `deltbae==DELTA_BIT_NEW` (M12 limit) → sticky `err_unsupported`,
  halt in `A_ERR`. **(M12 Stage A: the `cplinu` and active-`rematflg` guards are
  GONE — coupling + rematrixing side info is now parsed in full, see §4.4.1.)**
- **Deferred (not in M4)**:
  - *Mantissas* — their bit lengths depend on `bap[]` (after exponent_decode +
    bit_allocation), so this module stops at the end of the block side info; the
    mantissa parse is a later phase of the same heart.
  - *Blocks 1..5* — with no datapath there is nothing to advance past block 0's
    mantissas, so `ac3_parse` parses block 0 and then length-skips the rest of
    the frame body (unchanged frame accounting). Blocks 1..5 come online with
    the datapath.
  - *delta-ba segment values* — **now staged (M6)** into `deltba_mem` for
    DELTA_BIT_NEW channels (clear all 50 bands, then fill `deltlen` bands per
    segment from `deltoffst`/`deltlen`/`deltba`, with the liba52 `j+deltlen>=50`
    overflow → `err_unsupported`); read by `bit_allocation` over the
    combinational `deltba_rd_*` port. `deltbae` (per channel) is exposed so
    bit_allocation can gate on NEW (NONE/REUSE → zeros). `deltbae` defaults to
    DELTA_BIT_NONE at block start (matches liba52's per-frame reset).
- Verified: standalone TB (`audblk_parse_tb`, hand-built in-scope block — exact
  212-bit consumption + every staged field + packed exponents + the short-block
  assert) and the Verilator/liba52 co-sim (per-frame geometry + per-block
  exps/bap/PCM vs liba52).

#### 4.4.1 Coupling + rematrixing side-info parse (M12 Stage A — implemented)

`audblk_parse` now walks the full coupling/rematrixing syntax, bit-exact to
liba52 `parse.c` `a52_block()`. Bitstream order added (between `dynrng` and the
exponent strategy, acmod==2):

```
cplstre (cplinu  chincpl[2]  phsflginu  cplbegf4 cplendf4  cplbndstrc[ncplsubnd-1])
{ cplcoe ( mstrcplco2  {cplcoexp4 cplcomant4}*ncplbnd ) }*coupled-ch
{ phsflg }*ncplbnd                                      (if phsflginu & any cplcoe)
rematstr ( rematflg[nrematbnd] )                        (nrematbnd from cplstrtmant)
cplexpstr2 (if chincpl)  chexpstr[2]2
{ chbwcod6 }*non-reuse-uncoupled-ch                     (coupled ch: endmant=cplstrtmant)
cplabsexp4 {grp7}*ncplgrps   (if cplexpstr!=reuse, BEFORE the fbw exps)
... fbw exps ... baie ...
snroffste ( csnroffst6  cplba.bai7(if chincpl)  {fsnr+fgain}*2 )
cplleake ( cplfleak3 cplsleak3 )                        (if chincpl)
deltbaie ( cpl.deltbae2(if chincpl)  {deltbae2}*2  ... )
```

- **Geometry** (== liba52): `cplstrtmant = cplbegf*12+37`, `cplendmant =
  cplendf*12+73`, `ncplsubnd = cplendf+3−cplbegf`, `cplstrtbnd = bndtab[cplbegf]`.
  `cplbndstrc` reads `ncplsubnd−1` bits; each set bit merges a sub-band, so
  `ncplbnd ≤ ncplsubnd`. `ncplgrps = (cplendmant−cplstrtmant)/(3<<(cplexpstr−1))`.
  Rematrixing band count: read `rematflg` bits while `rematrix_band[i] < end`,
  `rematrix_band[]={25,37,61,253}`, `end = chincpl? cplstrtmant : 253` (so 2–4
  bands when coupled, always 4 uncoupled).
- **`cplco`**: per-band magnitude `(cplcomant) · scale_factor[cplcoexp+mstrcplco]`
  staged as signed **Q5.18** (see §5); `phsflg` negates ch1. Read over the
  combinational `cplco_rd_addr/cplco_rd_data` port (`{ch, bnd[4:0]}`).
- **State persistence (reuse semantics)**: `chincpl` updates only on `cplstre`,
  geometry only on `cplinu`, `cplco` only on `cplcoe`, `rematflg` only on
  `rematstr` — registers retain prior values otherwise (matches liba52, which
  keeps the state struct across blocks/frames). Reset only on `rst`.
- **Staged for Stages B/C/D**: coupling-channel grouped exps in `cpl_exp_mem`
  (consumed bit-exact now, decoded by B); `cplexpstr`/`cplfleak`/`cplsleak`/
  `cplba.bai`/`cpl deltbae` in internal regs (expose on the interface when B
  needs them). Coupled fbw channels get `endmant = cplstrtmant`.
- **Limit**: cpl `deltbae==DELTA_BIT_NEW` → `err_unsupported` (the cpl delta-BA
  segment parse is not yet wired; fbw delta-BA still works; none of the M12 test
  vectors use cpl delta-BA).
- **Verified** (`run_front_cosim.sh`): block-0 `chincpl`/`cplstrtmant`/
  `cplendmant`/`ncplbnd`/`cplstrtbnd`/`phsflginu`/`rematflg`/`cplco[][]` vs liba52
  on the coupled `tone_1k` (cplco=0.5, rematflg=0xf) and `silence` (cplco=1.0,
  rematflg=0x0) vectors — exact; uncoupled noise regression unchanged. Because
  the datapath downstream is still coupling-unaware, a coupled frame's later
  blocks desync and trip a loud guard, so only the first coupled frame's block-0
  geometry is checked (full decode + resync arrive with Stage C/D).

### 4.5 `exponent_decode` (implemented — M5)

First datapath stage. Reads the packed (grouped) exponents `audblk_parse` staged
in `exp_mem` and produces the per-channel array of absolute 5-bit exponents
(0..24) that bit_allocation (M6) and mantissa_dequant (M7) consume. Started by a
pulse (the sequencer drives it on `block_side_valid`); the bit_reader is idle
while it runs, so it consumes no bitstream.

- **Algorithm** (A/52 §7.1.3, == liba52 `parse.c` / ffmpeg `decode_exponents`):
  each channel sends one 4-bit absolute exponent `exp[0]` (DC) then `nchgrps`
  7-bit group codes. A code 0..124 ungroups into three mapped values
  `M0=code/25, M1=(code%25)/5, M2=code%5` (each 0..4); the differential is
  `M−2`. Absolute exponents accumulate: `prevexp += (M−2)`, and each result is
  emitted `group_size` times, where `group_size = 1/2/4` for D15/D25/D45. The
  j-th decoded coefficient lands at `dexp_mem[{ch, j}]`; `exp[0]` at index 0.
- **Reuse** (`chexpstr==0`): the channel keeps the previous block's exponents —
  this stage leaves that channel's `dexp_mem` untouched. (Block 0, the only
  block the M5 integration decodes, never reuses; A/52 forbids it.)
- **Clamp** [0,24]: dead on valid in-scope content (the encoder guarantees the
  range, and liba52 errors past 24), so the output matches liba52 bit-for-bit;
  the clamp only keeps hand-built torture vectors well-defined.
- **Memories / handshake**: reads `audblk_parse.exp_mem` over a combinational
  read port (`exp_rd_addr` registered → 1 wait cycle → `exp_rd_data`); writes
  one coefficient/cycle to `dexp_mem` (256 entries/channel — endmant ≤ 253 —
  addressed `{ch, idx[7:0]}`), with a combinational read port
  (`dexp_rd_addr/dexp_rd_data`) for the downstream stage and the co-sim.
- **Integration**: `ac3_parse` runs it in a new **P_EXP** state between block-0
  side info and the length-skip (`P_AUDBLK → P_EXP → P_CALC`); `exp_done` ends
  P_EXP. Geometry (`chexpstr`/`nchgrps`) comes straight from `audblk_parse`.
- **Verified**: standalone TB (`exponent_decode_tb` — D15/D25/D45 + reuse vs hand
  golden) and the Verilator/liba52 co-sim (per-frame block-0 exponents vs
  `fbw_expbap[ch].exp[0..endmant-1]`, bit-exact on the in-scope noise stream).
- **Deferred**: blocks 1..5 (no datapath past block 0 yet); a `>24` "fail loud"
  flag (currently clamped — never reached on valid streams). Algorithm also
  matches thesis §5.3.2.
- **M12 Stage B — coupling channel**: after the two fbw channels, an extra pass
  decodes the coupling-channel exps into `dexp_mem[{2,i}]` (ch==2,
  `i∈[cplstrtmant,cplendmant)`). Differences from fbw: the seed is `cplabsexp<<1`
  (liba52 doubles it), there is **no separate DC-exp store** (the first group's
  first diff writes directly at `cplstrtmant`), the packed codes come from
  `audblk_parse.cpl_exp_mem` (the `cpl_exp_rd` port), and the group count is
  `ncplgrps=(cplendmant−cplstrtmant)/grpsz`. Runs only when `cplexpstr≠REUSE`.
  Golden-checked vs liba52 `cpl_expbap.exp[]` (bit-exact, idx 133..216 on
  tone/silence). The `{ch,idx}` read addresses are now 10-bit; `mant_exp_rd_addr`
  stays 9-bit (mantissa is coupling-unaware until Stage C).

### 4.6 `bit_allocation` (implemented — M6)

Second datapath stage. Consumes the absolute exponents from `exponent_decode`
(`dexp_mem`) plus the bit-allocation parameters staged by `audblk_parse`, and
produces the per-coefficient bit-allocation pointers `bap[]` that
`mantissa_dequant` (M7) uses to size each mantissa. Started by a pulse
(`ac3_parse` drives it on `exp_done`); the bit_reader is idle while it runs.

- **Algorithm** — a *literal* transcription of liba52 0.8.0 `a52_bit_allocate()`
  (A/52 §7.2), not the A/52 reference routine (liba52 has its own tables, and
  the co-sim golden is liba52's `bap[]`). The whole stage is **integer**, so
  unlike the float DSP stages it is **bit-exact** to liba52. Per channel, with
  the in-scope call shape `bndstart=0, start=0, end=endmant, fastleak=slowleak=0`:
  - constants from the BAI sub-codes: `fdecay,fgain,sdecay,sgain,dbknee,floor,
    snroffset` (`fgain`/`snroffset` are per-channel via `fgaincod`/`fsnroffst`);
  - **phase 1** bins 0..2 (and up to 6 while the exponent rises), lowcomp seed
    384; **phase 2** to bin 6, the leaky integrator engages; **phase 3** bins
    7..19, lowcomp seed 320; **phase 4** the ≤2-bin lowcomp tail;
  - **phase 5** the banded loop: integrate each band's PSD with the log-add
    table `latab` (the `delta>>9` switch), then one `mask` per band;
  - every bin/band: `mask` via the `COMPUTE_MASK` macro (hth clamp, dbknee knee,
    `snroffset + 128*deltba`, floor), then `bap[k]=(baptab+156)[mask+4*exp[k]]`.
- **Tables** (`rtl/ac3/ac3_tables.svh`, ROM-inferred via an `initial` block —
  the one array-init style both iverilog `-g2012` and the verilated build
  accept): `baptab[305]` (indexed with the +156 bias; negative entries are
  liba52's grouped-quantizer flag), `latab[256]`, `hthtab0[50]` (fscod==0 row
  only — 48 kHz is the sole in-scope rate), `bndtab[30]`, and the small
  `slowgain/dbpbtab/floortab` parameter tables.
- **Delta bit allocation**: `DELTA_BIT_NEW` is honoured — read from
  `audblk_parse.deltba_mem` over a combinational port and copied into a local
  per-channel array, gated by `deltbae==NEW`; `DELTA_BIT_NONE` → zeros (matches
  liba52). `zero_snr_offsets` (csnroffst==0 and both fsnroffst==0 ⇒ all bap 0)
  has a `C_ZERO` fast path.
- **Memories / handshake**: a 2nd combinational read port on
  `exponent_decode.dexp_mem` (`ba_exp_rd_*`) feeds the exponents; the delta-ba
  port reads `audblk_parse.deltba_mem`; output `bap_mem` (512 entries, signed,
  `{ch, idx[7:0]}`) has a single write port (one bap/cycle) and a combinational
  read port (`bap_rd_*`) for M7 + the co-sim. Both inputs are *copied locally* at
  channel start so the masking math can index `exp[i]`, `exp[i+1]`, `exp[j]`
  freely without read-latency juggling.
- **Integration**: `ac3_parse` runs it in a new **P_BITALLOC** state between
  P_EXP and the length-skip (`P_EXP → P_BITALLOC → P_CALC`); `ba_done` ends it.
- **Verified**: standalone TB (`bit_allocation_tb` — `gen_balloc_vec.c` builds a
  2-channel problem incl. a DELTA_BIT_NEW channel and calls liba52's exported
  `a52_bit_allocate()` for the golden; every bap bit-exact) and the
  Verilator/liba52 co-sim (per-frame block-0 bap vs `fbw_expbap[ch].bap[]`,
  bit-exact on the in-scope noise stream).
- **Deferred / PoC notes**: halfrate==0 (48 kHz) so every `>>halfrate` is a
  no-op; no lfe channel; DELTA_BIT_REUSE across blocks is out of scope for the
  block-0-only integration.
- **M12 Stage B — coupling channel**: after the two fbw channels (when
  `chincpl≠0`), a coupling pass computes `bap_mem[{2,i}]`. liba52 calls
  `a52_bit_allocate(cplba, cplstrtbnd, cplstrtmant, cplendmant, cplfleak<<8,
  cplsleak<<8, cpl_expbap)` — `start≠0`, so the **phase 1–4 lowcomp region is
  skipped** (it only runs for `start==0`); the coupling pass jumps straight into
  the existing banded **phase-5** loop (`C_CCHINIT → C_CCOPY → C_P5SETUP…`) with
  `i=cplstrtbnd`, `j=cplstrtmant`, `fastleak/slowleak = cplfleak/cplsleak << 8`.
  `fgain`/`snroffset` use `cplba.bai` (`{fsnroffst[6:3], fgaincod[2:0]}`); the
  other consts are channel-independent; `deltba=0` (cpl delta-BA fails loud in
  `audblk_parse`). `zero_snr_offsets` now also weighs the cpl `fsnroffst` (and
  `C_ZERO` clears the ch-2 region when coupled). `bap_mem` is 1024 entries (ch
  0/1/2); `bap_rd_addr`/`ba_exp_rd_addr` are 10-bit; `mant_bap_rd_addr` stays
  9-bit (Stage C). Golden-checked vs liba52 `cpl_expbap.bap[]` (bit-exact).

### 4.7 `mantissa_dequant` (implemented — M7)

Third datapath stage, and the **first fixed-point** one (so the first not
bit-exact to liba52 — error bounded, see §5). It is also the **first datapath
stage to drive the `bit_reader`**: exps and bap[] are already in BRAM, but the
mantissas live in the bitstream, so `ac3_parse` grants the reader to this stage
in a new **P_MANT** state. The datapath stages between BSI and P_MANT (P_EXP,
P_BITALLOC) leave the reader idle, so when P_MANT starts the stream is
positioned exactly at the first mantissa (immediately after the block's `skiple`
field that `audblk_parse` consumed). Started on `bit_allocation`'s `done`.

- **Algorithm** — a literal transcription of liba52 0.8.0 `coeff_get()` (A/52
  §7.3.1). liba52's bap[] is *remapped* (see §4.6 / `ac3_tables.svh`): the
  grouped quantizers carry a negative tag, the rest are positive, and for the
  direct quantizers the value **is** the mantissa bit width:
  - `bap 0`  → zero, or **dither** noise if `dithflag[ch]`;
  - `bap -1` → 3-level grouped, 5-bit code, group of 3 (`q1lev`);
  - `bap -2` → 5-level grouped, 7-bit code, group of 3 (`q2lev`);
  - `bap -3` → 11-level grouped, 7-bit code, group of 2 (`q4lev`);
  - `bap 3`  → 7-level direct, 3-bit code (`q3lev`);
  - `bap 4`  → 15-level direct, 4-bit code (`q5lev`);
  - `bap 5..16` → direct, `bap` bits, signed: `m16 = sext(bits) << (16-bap)`.
- **Grouped quantizer cache** (liba52 `quantizer_t`): for the grouped
  quantizers liba52 reads **one** code and decodes 2–3 sub-mantissas, using the
  first now and caching the rest; later same-class coefficients consume the
  cache with no further bitstream read. The cache **persists across both fbw
  channels** within a block (liba52 resets it once, before the channel loop) —
  so a grouped run can straddle the ch0→ch1 boundary. This FSM mirrors that:
  `q{1,2,4}_ptr` reset only at `start`, carried from ch0 into ch1. (Ungrouping
  uses the small per-quantizer level LUTs + arithmetic sub-indices in
  `ac3_mant_tables.svh`, the same small-constant divides exponent_decode uses,
  rather than liba52's full per-code tables.)
- **Dequant / fixed-point** (§5): every quantizer yields a signed 16-bit
  mantissa `m16`; `coeff = ($signed(m16) <<< 8) >>> exp` → **Q1.23, 24-bit,
  truncating**. Grouped/direct-table levels are round-to-nearest 16-bit ROMs, so
  this stage is *not* bit-exact to liba52's float — the error is bounded (≤ 0.1
  LSB @ s16, measured).
- **Dither**: `bap==0` with `dithflag[ch]` → liba52 fills
  `dither_gen()·LEVEL_3DB·factor[exp]`. We replicate the LFSR (`dither_lut` ROM,
  seed 1, advanced once per dithered `bap==0` bin in coefficient order across
  channels) and use `m16 = (nstate·23170)>>15` (`23170/32768 ≈ LEVEL_3DB`).
  `dithflag==0` → coeff 0. (`dithflag` now flows from `audblk_parse` through
  `ac3_parse` — it was parsed-and-discarded before M7.)
- **HF tail**: coefficients `endmant..255` are zero-filled per channel (liba52
  zeroes the HF tail) so the IMDCT (M8) gets a clean 256-length array.
- **Memories / handshake**: a **3rd** combinational read port on
  `exponent_decode.dexp_mem` (`mant_exp_rd_*`) and a **2nd** on
  `bit_allocation.bap_mem` (`mant_bap_rd_*`), both addressed by the live
  `{ch,idx}` so the current coefficient's exp/bap are always present; output
  `coeff_mem` (512 × signed Q1.23, `{ch, idx[7:0]}`) with a single write port
  and a combinational read port (`coeff_rd_*`) for the IMDCT (M8) + the TB.
  Drives the `bit_reader` over 3b (one read per code; no read for zero / dither
  / cached-grouped / HF bins). `mant_done` ends P_MANT.
- **Verified**: standalone TB (`mantissa_dequant_tb` — `gen_mant_vec.c` walks the
  coefficients exactly as the RTL reads them, emitting the mantissa bitstream +
  two goldens: an exact Q1.23 target checked **bit-for-bit** to prove the
  ungroup/cache/scale/dither control, and liba52's float reconstruction to bound
  the quantization error; covers every bap class + a cross-channel grouped run)
  and the Verilator/liba52 co-sim (P_MANT now consumes block-0 mantissa bits on
  the in-scope noise stream and the frames still resync — exps/bap stay
  bit-exact; out-of-scope streams still fail loud). `bench/ac3/run_mantissa.sh`.
- **Deferred**: lfe coeff path (out of scope); DRC/`dynrng` is
  parsed-and-discarded, so on real streams the coeff *values* differ from liba52
  by the per-channel dynrng factor — which is why the co-sim does not compare
  coeff values directly (liba52 also IMDCTs them in place; the chain is compared
  in the PCM domain, dynrng-normalized). The standalone TB (level=1, no dynrng)
  is the value check.
- **M12 Stage C/D — coupling recombine + rematrixing**: after a coupled channel's
  fbw coeffs (`endmant=cplstrtmant`), `mantissa_dequant` reads the **shared**
  coupling mantissas ONCE (liba52 `coeff_get_coupling`, between ch0's and ch1's
  fbw reads — the bit order that must stay exact), keeping the grouped-quantizer
  cache (q1/q2/q4) shared with the fbw reads. Each coupling coeff (exp/bap from
  ch 2) is dequantized and scattered into both coupled channels as
  `recombine(cc, co) = (cc·co)>>>18` (Q1.23 × Q5.18 `cplco` → Q1.23, **saturating**
  — liba52 folds the per-channel downmix coeff into `cplco`, normalized out by the
  PCM-domain comparison). Coupling band widths come from `cplbndstrc` (12 mantissas
  per sub-band, replayed). `bap==0` coupling coeffs get per-channel **dither**
  (liba52 advances the shared LFSR once per coupled dithered channel — getting the
  advance count right keeps later fbw/blocks' dither synced). Then, for `acmod==2`
  with active `rematflg`, the low bands (`j∈[13, min(endmant0,endmant1))`) are
  sum/diff **rematrixed** (`samples[0]=L+R`, `samples[1]=L−R`, saturating to Q1.23)
  before IMDCT (`rematrix_band={25,37,61,253}`). The coupling reads/recombine
  serialize the two channel writes to keep `coeff_mem` single-write-port.
  **Verified** end-to-end in `run_front_cosim.sh`: coupled vectors decode all 6
  blocks/7 frames, PCM ≤0.43 LSB @ s16.

### 4.8 `imdct_512` (implemented — M8)

Fourth datapath stage, and the second fixed-point one. Consumes the per-channel
transform coefficients (`mantissa_dequant.coeff_mem`, Q1.23, 256/ch, HF tail
already zero-filled) and produces 256 windowed, overlap-added time-domain PCM
samples per channel into `pcm_mem`, maintaining a per-channel 256-sample
delay/overlap line across blocks. Started by a pulse (`ac3_parse` drives it on
`mantissa_dequant`'s `done` in the new **P_IMDCT** state); it touches **no
bitstream** (all inputs are already in BRAM).

- **Algorithm** — a literal transcription of liba52 0.8.0 `a52_imdct_512()`
  (`imdct.c`): pre-twiddle (`pre1[]` complex multiply) → 128-pt complex
  split-radix IFFT → post-twiddle (`post1[]`) + Kaiser-Bessel-derived window
  (α=5.0) → overlap/add. liba52's IFFT is a *recursion* (`ifft2/4/8/…` +
  `ifft_pass` butterflies); transcribing that control flow into fabric is
  awkward, so `bench/ac3/gen_imdct_tables.c` **traces the `ifft128_c` recursion
  once into a flat 157-op butterfly schedule** (each entry: an op type ∈
  {IFFT2, IFFT4, BFLY_ZERO, BFLY_HALF, BFLY_FULL}, the four complex-buffer
  indices it touches, and its twiddle(s)). The RTL just steps a tiny FSM through
  that schedule — same butterflies, same order, same arithmetic as liba52, only
  fixed-point rounding differs. The generator **self-checks** the schedule (run
  in double) against the *real* exported `a52_imdct_512()` to 2.6e-6 before
  emitting anything, so the schedule + the RTL's per-op butterfly semantics are
  proven independent of the RTL.
- **The `ifft_pass` index algebra.** `ifft_pass(buf, roots−N, N)` (liba52) emits
  one `BUTTERFLY_ZERO` on indices `(o, o+N, o+2N, o+3N)` then, for `k=0..N−2`, a
  full butterfly on `(o+1+k, o+1+N+k, o+1+2N+k, o+1+3N+k)` with `wr=roots[k]`,
  `wi=roots[N−2−k]` — the `−N` pointer bias collapses the original
  `weight[n+k]`/`weight[2n−2−k]` accesses to these (all in-range for the
  `roots16/32/64/128` arrays). `ifft8` additionally uses a `BFLY_HALF` with
  `w=roots16[1]` (the `wr==wi` case). See `gen_imdct_tables.c`.
- **Tables** (`rtl/ac3/ac3_imdct_tables.svh`, **GENERATED** — do not hand-edit;
  re-run `bench/ac3/run_imdct.sh`): `fftorder[128]` (the pre/post permutation),
  `pre1` (128 complex), `post1` (64 complex), `window[256]`, and the schedule
  ROMs (`sched_op/a/b/c/d/wr/wi[157]`). Twiddles + window are signed **Q1.17**
  in 18-bit words.
- **Datapath / fixed point** (§5): complex samples are **Q8.23** in 32-bit words;
  each multiply is `(sample · twiddle) >>> 17` (arithmetic, truncating). One
  shared bank of **4 signed multipliers** (≈8 Cyclone V DSPs) is time-shared
  across the pre/IFFT/post phases by the FSM — correctness first; the serial
  block loop has millions of cycles of headroom at 48 kHz. This is fixed-point,
  so it is **not** bit-exact to liba52's float — error bounded (see §5).
- **Memories / handshake**: `coeff_rd_addr/data` is a combinational read port
  into the coefficient store (`mantissa_dequant.coeff_mem`'s 2nd port in the
  integrated design; a TB array standalone). `delay_mem` (512 × Q8.23,
  `{ch,idx}`) is the overlap state — reset only on `rst`, so block 0 starts from
  silence (matching a fresh `a52_state` delay line). `pcm_mem` (512 × Q8.23,
  `{ch,idx}`) has a single write port and a combinational read port
  (`pcm_rd_addr/data`) for `pcm_out` (M9) + the TB.
- **Integration**: `ac3_parse` runs it in **P_IMDCT** (`P_MANT → P_IMDCT →
  P_CALC`), started by `mant_done`, ended by `imdct_done`; the bit_reader is idle
  throughout. Surfaced through `ac3_front` (`imdct_done` + `pcm_rd` port).
- **Verified**: standalone TB (`imdct_512_tb`, `gen_imdct_vec.c` — two channels
  of random full-scale Q1.23 coeffs through the real `a52_imdct_512` for the
  golden; every Q8.23 output sample checked, **max error 1648 Q8.23 LSB ≈ 2.0e-4
  abs ≈ 0.4 LSB @ s16**, `run_imdct.sh`) and the Verilator/liba52 co-sim (P_IMDCT
  now runs on the in-scope noise stream; 7/7 frames still resync with exps/bap
  bit-exact; out-of-scope frames still fail loud). Coeff/PCM *values* aren't
  golden-checked on real streams (liba52 applies `dynrng` + IMDCTs in place,
  leaving no clean tap — same reasoning as M7; the standalone TB is the value
  check).
- **Deferred**: blocks 1..5 (the integration still decodes block 0 then
  length-skips the rest; the delay line is wired to carry across blocks for when
  they come online); short-block 256-pt IMDCT (`a52_imdct_256`, out of scope —
  short blocks already fail loud at `audblk_parse`); the `pre2`/`post2` tables
  for that path are intentionally not generated.
- ✅ **NOW FITS (M11 area reduction).** The M8 implementation did *not* fit: the
  butterfly working buffers `buf_re/buf_im [0:127]` were read at 4 arbitrary
  indices and written at 4 arbitrary indices in the same cycle (the radix-4
  step), which cannot map to ≤2-port M10K, so Quartus realized them as 256
  flip-flops × 32 bits behind 4× 128:1 read crossbars + write decoders =
  **82,836 ALUTs + 37,652 registers** and the Fitter failed (whole design needed
  103,693 vs the 83,820 cap). **M11 fix (implemented):** the complex working
  buffer is now a single **true-dual-port M10K** `bufmem [0:127]` (64-bit,
  `{re[63:32], im[31:0]}`, `(* ramstyle = "M10K, no_rw_check" *)`, inferred as
  `altsyncram`), and every butterfly is **multi-cycled** by a 6-step `ph`
  micro-FSM (read ≤4 operands two-per-cycle on ports A+B → capture into `c0..c3`
  regs → compute, BFULL latching `tt5/tt6` → write ≤4 results two-per-cycle).
  POST got the same read→capture front-end (`buf[i]`/`buf[127-i]` in one cycle,
  captured next, then the old post-twiddle/window/OLA). The arithmetic is
  byte-for-byte the M8 math — only *when* each read/write happens changed — so
  the bounded error is **unchanged** (`run_imdct.sh` still 1648 Q8.23 LSB,
  `run_front_cosim.sh` still 7/7 ≤0.46 LSB @ s16). **Result:** `imdct_512`
  dropped from 82,836 ALUTs to **~22,412 combinational ALUTs / 19,348 ALMs**
  (`bufmem` = 4 M10K, 0 ALMs); the whole core fits at **33,176 / 41,910 ALMs =
  79%** (75/553 RAM blocks, 43/112 DSP), all setup slacks positive (worst +0.130
  ns on the HDMI-PLL infra path, decoder `clk_sys` +9.17 ns), and
  `build_release.sh` emits a **3.10 MB compressed `.rbf`** — the first loadable
  core. `delay_mem`/`pcm_mem` stay inferred logic (512 × 32 bits each; they fit
  with room — trimming them is an optional future cleanup, not required).

### 4.9 `pcm_out` (implemented — M9)

Final output stage. Drains one block of time-domain PCM (`imdct_512.pcm_mem`,
Q8.23, 256 samples/channel, `{ch,idx}`) into a 16-bit signed L/R stream and
presents it at the audio sample rate to `AUDIO_L`/`AUDIO_R` (MiSTer wires
`AUDIO_S=1` for signed). Two clock domains, decoupled by an **asynchronous
(Gray-pointer) FIFO** so the bursty fixed-point datapath runs on the decode clock
while the DAC side is paced by a ~48 kHz clock-enable on `clk_sys`.

- **Format** (§5 — pinned at M9): `s16 = sat( round_half_up(raw / 2^8) )` =
  `((raw + 128) >>> 8)` clamped to `[-32768, 32767]`. `raw = +2^23` (`+1.0`) →
  `+32768` → saturates to `+32767` (the only saturation a well-formed in-scope
  decode reaches; further out-of-range only from accumulation head-room).
- **Drain FSM** (decode domain `clk`): a `start` pulse (driven by
  `imdct_512.done`) walks `idx` 0..255, reading `L=pcm_mem[{0,idx}]` then
  `R=pcm_mem[{1,idx}]` over the combinational `pcm_rd_addr/data` port, formatting
  each to s16 and pushing `{L,R}` into the FIFO. `busy` is high while draining;
  the FSM **stalls** (never drops a sample) if the FIFO ever backs up. When the
  last pair is pushed it pulses **`done`** — the metering handshake `ac3_parse`
  waits on before the next block's IMDCT overwrites `pcm_mem` (§4.10). Because
  the drain stalls on a full FIFO, `done` is delayed under back-pressure, which
  paces the whole parser to the output rate.
- **Async FIFO**: standard dual-pointer design — binary+Gray pointers per domain,
  2-FF synchronizers, combinational read. Depth defaults to 512 pairs
  (`FIFO_AW=9`) ≥ one block, since a whole block is produced in a burst then read
  out one pair per `aud_ce` over ~5.3 ms. Tie `aud_clk=clk`/`aud_rst=rst` for a
  single-clock system (the CDC degenerates harmlessly).
- **Audio domain** (`aud_clk`, `aud_ce`): on each `aud_ce` tick, if non-empty a
  pair is popped to `{audio_l,audio_r}` and `aud_valid` pulses; on underflow the
  last sample is held and `aud_valid` stays low.
- **Verified**: standalone TB (`pcm_out_tb`, `run_pcm_out.sh`) drives the two
  clocks asynchronously, forces a FIFO overrun (small `FIFO_AW`) to exercise the
  stall + pointer wrap, and checks format/saturation against an independent
  real-arithmetic reference plus L/R ordering and underflow-hold. The **full
  chain** to PCM is checked in the Verilator/liba52 co-sim: for every in-scope
  block-0 frame, `imdct_512.pcm_mem` (the IMDCT output `pcm_out` consumes) is
  within **≤0.46 LSB @ s16** of liba52's `a52_samples()` normalized by the
  per-block `dynrng` (see §5 / `run_front_cosim.sh`).
- **Wired into `emu.sv` (`ac3fpga.sv`) at M10** — see §4.10.

### 4.10 `emu` wiring (M10 — `ac3fpga.sv`)

Top-level integration of the decoder into the MiSTer framework. Everything runs
on `clk_sys` (20 MHz from `rtl/pll`); the audio output is paced by a clock-enable.

- **Byte source — HPS file loader.** The OSD `F1,AC3BIN,Load AC-3` entry makes the
  HPS stream the AC-3 elementary stream over `ioctl` (`hps_io`): one byte per
  `ioctl_wr` while `ioctl_download` is high. Fed straight into `ac3_front`
  (`wr_en = ioctl_download & ioctl_wr`, `wr_data = ioctl_dout`). `sync_crc`
  resyncs on `0x0B77`, so partial bytes are harmless; the front-end FIFO is also
  flushed on each new download (`ac3_rst`).
- **Backpressure.** `ioctl_wait` is driven by the front-end FIFO `full` so the HPS
  pauses rather than overrunning the FIFO (a dropped ES byte would corrupt the
  stream — `bit_fifo` silently ignores writes when full).
- **Audio rate.** `aud_ce` is a 1-cycle enable every `AUD_DIV=417` clocks
  (20 MHz / 417 = 47.96 kHz, ~0.08 % slow). `pcm_out` runs single-clock
  (`aud_clk = clk_sys`), reads its CDC FIFO on `aud_ce`. `AUDIO_S=1` (signed);
  `AUDIO_L/R` take `pcm_out.audio_l/r`, muted to 0 by the `O[5],AC-3 Audio` toggle.
- **`start`.** `pcm_out.start = ac3_front.imdct_done` — each finished block's
  `pcm_mem` kicks the drain.
- **`done` / metering.** `pcm_out.done` (1-cycle pulse when a block is fully
  pushed to the CDC FIFO) feeds back to `ac3_front.pcm_done` → `ac3_parse`'s
  `P_DRAIN` wait. See "block loop + metering" below.
- **LED.** `LED_USER` = solid when `synced` & error-free, ~1 Hz blink on
  `err_unsupported`, off while unsynced.

#### Block loop + real-time metering (M10 — resolved)

The two former bring-up gaps are now closed in RTL and verified in the co-sim
(all 6 blocks of all 7 in-scope frames, exps/bap bit-exact + PCM ≤0.71 LSB @ s16):

1. **Full 6-block decode.** `ac3_parse` runs the per-block datapath
   (`P_AUDBLK → P_EXP → P_BITALLOC → P_MANT → P_IMDCT → P_DRAIN`) six times per
   frame, re-arming `audblk_parse` each block via `audblk_start`, then length-
   skips the frame tail (auxbits + CRC2) and resyncs. The bit_reader advances
   continuously through the blocks; the `imdct_512` `delay_mem` overlap line and
   the exponent-reuse / mantissa-dither LFSR state all persist across blocks
   (every stage was already block-loop-ready — only the sequencer length-skipped
   after block 0 before). 1536 samples/ch/frame, no gaps.
2. **Real-time metering.** After each block's IMDCT, `P_DRAIN` waits for
   `pcm_done` before starting the next block — the next IMDCT overwrites the
   shared `pcm_mem`, so it must not begin until `pcm_out` has read this block
   out. `pcm_out` stalls its drain FSM when its CDC FIFO is full (it only pops on
   `aud_ce` ≈ 48 kHz), so `pcm_done` is delayed exactly long enough to pace the
   *whole* parser to the output sample rate. No more free-running / dropped
   blocks; the `FIFO_AW=9` (512-pair = 2-block) depth gives a little slack but
   steady-state the parser tracks 48 kHz. (On the bench there is no DAC, so the
   co-sim/iverilog TBs tie `pcm_done`=1 and read `pcm_mem` combinationally on
   `imdct_done`, before any overwrite — no metering stall needed there.)

The per-stage decode math is verified (standalone TBs + co-sim, §4.1–4.9); the
remaining M10 item is the **empirical audio check on real DE10-Nano hardware**.

### 4.11 M19 area pass (2026-07-11, branch `feature/ac3-area-reduction`)

**Motivation:** the `feature/iec61937-spdif-passthrough` build FAILED to route
(Fitter congestion at 91% ALMs / 87% DSP), and the fit report showed the AC-3
subtree (`dvd_audio_decode` = **9,378 ALMs**) had grown LARGER than the whole
MPEG-2 video decoder (8,484). The bloat was all unconverted memory — the same
LUT-RAM/LUT-ROM pattern M11/M13/M15 fixed elsewhere — so this pass converts
every remaining async-read array/table to sync-read M10K. **Zero arithmetic
changes: only the cycle a value is READ moves** (the pipeline is strictly
serial in `ac3_parse`, and the cycle budget is ~106k clk/block vs ~1k used, so
added latency is free). Five sub-stages, one commit each:

- **M19 (`bit_allocation` `expc`/`dbc`):** the 256×5 + 64×4 *register files*
  (multi-tap combinational reads `expc[i]`+`expc[i+1]`, `expc[j]`, `expc[jw]`,
  plus 256-way write decoders — the bulk of the module's 2,993 ALMs) became
  1W1R sync RAMs on the proven bap_mem/M13 same-block template; `expc` is
  duplicated into two identically-written copies to serve both same-cycle read
  taps. Every compute state (C_P1..C_P4, C_P5*) runs a `ph0`-fetch /
  `ph1`-execute micro-cycle.
- **M19b (`bit_allocation` ROMs):** `baptab`/`latab`/`hthtab0` → registered
  M10K ROMs. The bap-write pipeline gained a stage (`pend_*` → `p2_*` → `bm_*`;
  `C_FLUSH` terminal 2→3); `C_P5ACC` is 3 micro-phases (latab); `compute_mask`
  takes the hth value as an argument (one registered read indexed by `i` —
  every call site uses band==i). All bit-alloc cones got SHORTER (this module
  once failed 27 MHz setup on the serial hthtab0→baptab read — nothing here
  adds depth).
- **M19c (`imdct_512` tables):** all ~37 kbit of GENERATED tables (butterfly
  schedules, pre/post twiddles, window, fftorder) were combinational LUT ROMs.
  `gen_imdct_tables.c` now also emits packed literal images (`imdct_sched_pk`
  71-bit with the short schedule at +IMDCT_NSCHED — kills the 7 long/short
  muxes; `imdct_pre_pk`/`imdct_post_pk` 36-bit {re,im}) plus `ramstyle` on
  window/fftorder, all read registered: the schedule is addressed with `s_next`
  during the ph5 advance (parks on entry 0 outside S_IFFT), twiddles/fftorder
  are indexed by the element-stable `i` (S_PRE gained one phase so `fo_q` lands
  before the dk address issue), and the window has two sync read ports whose
  addresses issue one ph ahead of the consuming mult phase.
- **M19d (`audblk_parse` staging):** `exp_mem`/`cpl_exp_mem`/`deltba_mem` →
  registered M10K reads. `exponent_decode`'s `*_RD` states gained a
  wait-then-capture toggle (`rdw`); `bit_allocation`'s `deltba_q` realignment
  register was DELETED (the registered read lands on exactly the cycle it used
  to provide). `lfe_exp_mem` (4 entries) stays combinational.
- **M19e (downmix DSP fold):** the three dedicated 32×18 downmix multipliers
  (6 DSPs, live only in S_DMX) folded into the shared 4-mult bank — S_DMX never
  overlaps PRE/IFFT/POST. `(a*b)>>>17` through the wider bank keeps identical
  low 32 bits. Do NOT serialize the 4-mult bank itself (operand-mux growth
  negates the win).

**Verification gate (every stage):** full `bench/ac3` unit suite green with
IDENTICAL max-error numbers (imdct 1648 / imdct256 879 / drc 1116 Q8.23 LSB);
`run_front_cosim.sh` PASS on all 8 streams (bap bit-exact); **PCMDUMP blocks
0–5 of every stream byte-identical** to the pre-change baseline;
`dvd_audio_decode_tb` green.

**Result (fit, 2026-07-11):** with the DTS passthrough chain re-enabled
(revert of the 35cac73 deferral), the design ROUTES: whole design 37,952 →
**35,844 ALMs (91% → 86%)**, DSP **97 → 91 (81%)**, block-RAM bits 53%
(+40 kbit of new M10K/MLAB — every converted array confirmed `altsyncram` in
the fit report, `dbc_mem` = MLAB `altdpram`).  Subtree: `dvd_audio_decode`
9,378 → **7,160 ALMs** (`bit_allocation` 2,993 → 1,466; `imdct_512` 3,314 →
2,509; `mantissa_dequant`/`audblk_parse` ~flat — the remaining reserve is the
mantissa shared-scaler idea, unneeded).  The old pinned SEED 13 no longer
routed (per-netlist seed lottery); the sweep found **SEED 7: clk_dec
86.07 MHz @100C / 88.32 MHz @-40C** — both slow corners above the 81 MHz
fringe gate.  `releases/DVD_ac3area_20260711_1759.rbf` (4,247 KB, in line
with recent releases).

**⚠️ Latent-TB discovery (fixed en route):** `run_imdct.sh`, `run_imdct256.sh`
and `run_drc.sh` had been FAILING since the M17 DRC fix — they still encoded
the pre-M17 dynrng convention (exponent unsigned, "unity" at 0x80, which is
actually the −24 dB max cut), and `vvp` exits 0 on a `$display("FAIL")` +
`$finish`, so run-script exit codes read as pass. Fixed: TBs drive dynrng 0x00
(true unity), `gen_drc_vec.c` uses the signed-exponent gain, and all three TBs
now `$fatal(1)` on tolerance failure. The RTL was always correct (max errors
landed exactly on the documented 1648 LSB once the convention was fixed).

---

## 5. Fixed-point convention (pin BEFORE datapath RTL)

liba52's reference path is float; our fabric path is fixed-point, so we **cannot**
be bit-exact to liba52 — the pass criterion is bounded error (see roadmap). To
keep divergence controlled and located, we pin formats up front and test the
quantization in isolation:

- **Bit allocation** (M6): pure **integer**, no fixed-point — `bit_allocation`
  is a literal liba52 transcription and matches `bap[]` bit-for-bit. Nothing to
  pin here; the first fixed-point choice is the transform-coefficient format
  below, at M7.
- **Transform coefficients** (mantissa_dequant output, IMDCT input): **signed
  `Q1.23` in a 24-bit word** (1 sign bit + 23 fractional bits; value range
  `[-1, +1)`). Pinned at M7. Rationale: liba52 reconstructs each coefficient as
  `coeff = m16 · 2^-(15+exp)` where `m16` is a signed mantissa with `|m16| ≤
  2^15` and `exp ≥ 0`, so `|coeff| < 1` — a sign + fraction suffices, no integer
  bits beyond the sign. 23 fractional bits give a quantization step of `2^-23 ≈
  1.2e-7`, far below the ±2-LSB-@-s16 budget (`6.1e-5`), leaving headroom for
  IMDCT accumulation; 24 bits is DSP-friendly (top 18 bits → an 18×18 Cyclone V
  multiplier at M8). **Computation:** `coeff = ($signed(m16) <<< 8) >>> exp`
  (`8 = 23 − 15`; arithmetic right shift, **truncating** toward −∞). The widest
  product `−2^15 · 2^8 = −2^23` lands exactly at the 24-bit signed floor
  (`−1.0`), so there is no overflow.
  - **Rounding mode: truncation** (not round-half-to-even). Measured error vs
    liba52's exact float reconstruction (mantissa_dequant_tb, two hand-built
    channels covering every bap class incl. dither, with grouped mantissas at
    `exp==0` to hit the worst case): **max abs error = 51 LSB @ Q1.23**
    (`≈ 6.1e-6`, ≈ **0.1 LSB @ s16**). The error is dominated by the ≤0.5-LSB
    *m16* rounding of the grouped-quantizer level ROMs — which, at `exp==0`,
    scales up to `0.5·2^8 = 128` Q1.23 LSB — plus the ≤1-LSB `>>exp` truncation;
    direct quantizers carry only the truncation term. An order of magnitude
    under the ±2-LSB-@-s16 budget, so truncation suffices and we do not round.
    (See `bench/ac3/run_mantissa.sh`; the TB prints the measured max each run.)
  - The grouped/table quantizer mantissa levels (`q1/q2/q3/q4/q5`) are stored as
    **round-to-nearest 16-bit integers** of liba52's exact `(k<<15)/N` float
    values in `rtl/ac3/ac3_mant_tables.svh`; that rounding is the main error
    term above. Dither (`bap==0` with `dithflag`) replicates liba52's LFSR
    (`dither_lut` ROM) and scales by `LEVEL_3DB ≈ 23170/32768`.
- **IMDCT internal** (M8): twiddle + window coefficients are signed **Q1.17** in
  18-bit ROMs (`value/131072`, DSP-18×18-friendly; all |coeff| < 1 so no
  saturation). Complex working samples are **Q8.23** in 32-bit words (range
  ±256; the peak |IFFT output| is ≈ 17 for unit input, ample headroom, and the
  butterfly add/sub intermediates use 34-bit temporaries). Each multiply is
  `(sample · twiddle) >>> 17`, **truncating** (toward −∞). Rounding convention:
  truncation, not round-half-to-even — measured: adding the half-LSB round
  changed the max error by < 2 LSB (1648 → 1666 Q8.23 LSB), i.e. the error is
  dominated by the Q1.17 twiddle *quantization* random-walked across the FFT, not
  by per-multiply truncation bias, so truncation suffices and we keep the simpler
  datapath. **Measured error** vs liba52's float `a52_imdct_512` (the standalone
  `imdct_512_tb`, a full-scale torture vector — all 256 bins random Q1.23, peak
  |sample| ≈ 17): **max 1648 Q8.23 LSB ≈ 2.0e-4 abs ≈ 1.2e-5 relative ≈ 0.4 LSB
  @ s16** — an order under the ±2-LSB-@-s16 budget. (Real content is sparse and
  low-level, so its absolute error is far smaller.)
- **PCM output** (M9): round/saturate Q8.23 → `s16`. **Pinned**: `s16 =
  sat( (raw + 128) >>> 8 )` — round half toward +∞, clamp to `[-32768, 32767]`.
  `raw/2^8` because Q8.23 → s16 drops 8 fractional bits (`2^23 → 2^15`); the
  `+128` is the half-LSB round, the only DC term and a negligible `2^-16` of full
  scale. The whole **chain** (sync → … → IMDCT → PCM) is bounded vs liba52 in the
  co-sim: every in-scope block-0 sample of `imdct_512.pcm_mem` is within
  **≤0.46 LSB @ s16** of liba52's `a52_samples()/dynrng` (the dut parses-and-
  discards `dynrng`; the IMDCT is linear so the whole sample stream scales by that
  single per-block scalar, normalized out for the comparison). That measured chain
  error ≈ the `imdct_512` standalone bound (the dominant term), confirming the s16
  packaging adds nothing material. `run_front_cosim.sh` / `run_pcm_out.sh`.

- **5.1 → stereo downmix `clev`/`slev`** (M14 Stage F): signed **Q1.17 in 18-bit
  words** (`value/131072`, same format as the IMDCT twiddles). The 5 fbw channels
  L C R Ls Rs are folded to stereo IN PLACE after the IMDCT (a final `S_DMX` pass
  in `imdct_512`, written back over pcm slots 0/1) so `pcm_out` drains a plain
  2-channel `Lo`/`Ro`: `Lo = L + clev·C + slev·Ls`, `Ro = R + clev·C + slev·Rs`
  (A/52 `A52_STEREO`, `downmix.c CONVERT(3F2R,STEREO)`). `clev`/`slev` are the
  SAME `LEVEL` constants liba52 uses (`a52_frame` `clev[]`/`slev[]`), selected by
  `cmixlev`/`surmixlev`: `clev ∈ {0.7071→92682, 0.5946→77933, 0.5→65536}`,
  `slev ∈ {0.7071→92682, 0.5→65536, 0(reserved)→0}`. Each product is
  `(sample Q8.23 · level Q1.17) >>> 17`, **truncating**; the 8 integer bits of
  Q8.23 absorb the `|Lo| < ~2.4` headroom (sum of three ≤1 terms) so no
  saturation is possible. Only `nfchans==5` (acmod==7) downmixes; stereo
  (`nfchans==2`) leaves slots 0/1 = L/R untouched (degenerate passthrough).
  **Verified** in `run_front_cosim.sh`: the dut's downmixed `Lo`/`Ro` (pcm slots
  0/1) vs the stereo downmix of liba52's per-channel goldens (`gpcm[L] +
  clev·gpcm[C] + slev·gpcm[Ls]`, etc. — clev/slev = liba52's `state->clev/slev`;
  valid by linearity since the per-channel PCM is already golden-checked) — on the
  coupled `tone_5p1` vector **≤0.82 LSB @ s16** across all 6 blocks.
- **IMDCT high-frequency precision (M14 diagnosis).** The IMDCT `Q1.17` twiddle
  quantization (above) is frequency-dependent: its error grows toward Nyquist.
  The standalone TB's torture vector (random Q1.23, spread spectrum) sees ≈0.4 LSB
  @ s16, but content with energy CONCENTRATED near Nyquist is far worse — the
  band-split `noise_5p1` 5.1 vector (whose high channels are 12–15 kHz bandpass)
  reaches ≈40 LSB, and flat full-band white noise ≈100 LSB. This is *not* a decode
  bug — the dut's transform COEFFICIENTS are bit-accurate to liba52 (~1e-5) in
  every vector (verified by the `COEFFDUTDUMP` coeff tap vs a coeff-dumping liba52
  probe); it is the inherent fixed-point IMDCT residual. Real DVD content (HF
  rolled off, like the already-shipped stereo vectors at ≤0.71 LSB) stays in
  budget; the band-split vector is therefore a GEOMETRY/exps/bap gate only (its
  PCM is informational in `run_front_cosim.sh`). Widening the twiddles
  (`Q1.17`→wider) would reduce it but costs DSP/area — deferred (the same IMDCT
  already ships hardware-validated for stereo, M11–M13).
- **Coupling coordinates `cplco[ch][bnd]`** (M12 Stage A): signed **Q5.18 in a
  24-bit word** (1 sign + 5 integer + 18 fractional; range `[-32, +32)`, step
  `2^-18 ≈ 3.8e-6`). liba52 reconstructs each as `cplco = cplcomant ·
  scale_factor[cplcoexp + mstrcplco]`, where `scale_factor[i] = 2^-(15+i)`, the
  exponent index `cplcoexp+mstrcplco ∈ [0,24]`, and `cplcomant` is an integer of
  up to 18 bits (`(m|0x10)<<13` or, for `cplcoexp==15`, `m<<14`). So `cplco =
  cplcomant · 2^-(15+idx)`; in Q5.18 that is `cplco_q = cplcomant << (3 − idx)`
  (left when `idx ≤ 3`, arithmetic right otherwise — tiny values truncate to 0,
  matching liba52's negligible magnitude there). 5 integer bits because the
  coordinate can exceed 1 (worst case `idx=0` gives `cplco ≈ 7.7`); the largest
  intermediate is `cplcomant(18b) << 3 = 21 bits`, inside the 24-bit signed
  range. The phase flag (`phsflg`) negates `cplco[1][bnd]` (a sign flip). Chosen
  to mesh with the Stage-C recombine `coeff_hf = (cpl_coeff · cplco) >>> 18`
  (Q1.23 × Q5.18 → Q1.23). **Verified** in `run_front_cosim.sh`: dut `cplco` (read
  back as `raw/2^18`) vs liba52's float `st->cplco[5][18]` within `1e-3` — on the
  coupled vectors it is **exact** (tone `0.5`, silence `1.0` both representable).

Every place a width or rounding mode is chosen, note it in this section with the
measured error-vs-liba52 it produced. This section is the single source of truth
for "why does sample N differ by 1 LSB."

Resolved at M7: transform coefficients are `Q1.23` / 24-bit, truncating, max
measured error 51 LSB @ Q1.23 (≈ 0.1 LSB @ s16) vs liba52 float (see above).
Resolved at M8: IMDCT-internal samples `Q8.23` / 32-bit, twiddle+window `Q1.17`
/ 18-bit, truncating, max measured error 1648 Q8.23 LSB (≈ 0.4 LSB @ s16) vs
liba52 float (see above).
Resolved at M9: PCM output `s16 = sat((raw + 128) >>> 8)` (round half toward +∞,
clamp). Full-chain measured error ≤0.46 LSB @ s16 vs liba52 (dynrng-normalized)
across all 7 in-scope frames — the chain is now closed end-to-end within budget.
Resolved at M14: 5.1→stereo downmix `clev`/`slev` `Q1.17` / 18-bit, truncating,
folded in place over pcm slots 0/1 by `imdct_512.S_DMX`; coupled `tone_5p1` Lo/Ro
≤0.82 LSB @ s16 vs liba52 stereo downmix. The IMDCT twiddle precision is
frequency-dependent (≈0.4 LSB spread-spectrum → tens of LSB near Nyquist);
HF-concentrated test vectors (band-split `noise_5p1`) are geometry-only gates,
real full-band content stays in budget (decode is bit-accurate either way).

---

## 6. Bring-up order & first module

See [`roadmap.md`](roadmap.md). First RTL is `bit_reader` because every other
stage depends on it and it is testable in complete isolation with synthetic
golden vectors (no liba52 needed). Implemented in portable SystemVerilog so it
runs under **iverilog** today and **Verilator** once installed.
