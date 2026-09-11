# Logic reclaim — the 2026-09-10 area audit and its branches

**Status:** Branch A (AC-3) built and sim-gated, ⏳ HW-confirm pending; Branch B
(nav/VM/glue) in progress; Branch C (reader) and the block-RAM packing pass planned.

## 0. Why

Two consecutive speculative branches (`feature/wav-audio`, `feature/cdda-physical`) each
landed the core at **98 % ALM**, the regime where the DVD.qsf seed ledger measures the
fitter seed as worth more than 18 MHz on clk_dec. The question was where the ALMs go and
what could be reclaimed with zero behaviour change.

## 1. What the numbers actually said

Ground truth came from the fit report's per-entity table (`output_files/DVD.fit.rpt`
§20), a map-vs-fit per-entity diff, the RAM summary, and a **fresh fit of v0.5.0 `main`**
in a worktree (same seed).

| | v0.5.0 `main` | cdda branch | 
|---|---|---|
| ALMs needed (headline %) | 38,802 (93 %) | 41,273 (98 %) |
| **[A] ALMs used in final placement** | **40,821 (97 %)** | 41,207 (98 %) |
| [B] "recoverable by dense packing" | 2,703 | 637 |
| LABs used | 4,188 / 4,191 | 4,191 / 4,191 |
| combinational ALUTs | 60,642 | 62,227 |
| registers | 52,238 | 52,785 |

Three conclusions, each of which changed the plan:

1. **The release build was already physically full.** The headline "93 %" was the
   fitter's dense-packing estimate subtracted from a device with three LABs free. The two
   branches placed ~400 more ALMs and the estimate collapsed; that is the whole 93→98 %
   story. **Measure reclaim in synthesis ALUTs (`DVD.map.rpt` per entity) and placed
   ALMs, never the headline percentage.**
2. **The fitter adds only ~418 ALUTs over synthesis.** The 62k ALUTs are real RTL logic,
   not congestion duplication, so reclaim has to come from the RTL.
3. **Cutting the CD player would have recovered ~300 ALMs.** The WAV + CD-DA branches
   are ~660 ALUTs of their own logic; the largest per-entity delta between the two
   netlists (+786) was inside the AC-3 IMDCT, which neither branch touched — a Quartus
   17 mapping cliff on identical RTL (same memories, registers, DSPs). Declined.

Block RAM: 131 memories on 508 blocks hold 71 % of the bit capacity. The M10K's ×1 and
×2 modes store only 8 Kbit per block, so the subpicture bitmap (414,720 × 2-bit, 102
blocks) would fit in 82 if pixels were packed five to a 10-bit word.

## 2. Where the area is (own ALMs, cdda fit)

`dvd_iso_reader` 4,340 (FSM next-state muxes and duplicated adders — its tables are ALL
already in M10K, the "tables in flops" theory was false there) · `imdct_512` 2,610 ·
`ascal` 2,255 · `dvd_vm` 2,078 · `bit_allocation` 1,307 · `mem_shim_burst` 1,291 (already
reclaimed once) · emu glue 1,077 · `vld` 986 · `mantissa_dequant` 963 · `audblk_parse` 653 ·
`spu_decode` 616 · `pts_assoc` 563 (912 flops of shift-FIFO) · transport cluster ≈ 2,370 ·
`pgc_palette` 340 (a 384-flop raw shadow) · `dvd_telem` 306 (19 × 3-flop filters).

The recurring pattern this time was not memory but **Quartus muxing RESULTS across
mutually exclusive FSM states**: every inlined function call, every per-state copy of an
adder, is its own datapath.

## 3. Branch A — `feature/alm-reclaim-ac3` (✅ built, ⏳ HW gate)

Detail in `docs/ac3_decoder_architecture.md` §4.12 and the DVD.qsf ledger. Every commit
gated by `bench/ac3/run_front_cosim.sh` (bap bit-exact vs liba52 on 13 streams) **and PCM
dumps of blocks 0–5 byte-identical** to a pre-change baseline, plus each unit suite.
Synthesis result **−2,544 ALUTs**; fit SEED 7 first roll, clk_dec 93.66 / 90.86.

Found en route: `bench/ac3/run_balloc.sh` had been failing silently since M19d (stale
combinational delta-BA model, vvp exit 0). Fixed and `$fatal`ed before the refactor.

## 4. Branch B — `feature/alm-reclaim-nav` (✅ built, ⏳ HW gate)

**Fit (SEED 7, first roll, cut from `main`):** clk_dec 89.73 / 89.42, "needed" 38,768,
placed 40,823 (unchanged), registers 51,954 → 50,578 (**−1,376**), ALUTs +774 — **of
which +799 is the IMDCT mapping cliff on RTL this branch does not touch** (3,228 on
`main`, 4,027 here). Own modules: pts_assoc −732 regs, pgc_palette −359 regs / −55
ALUTs, dvd_telem −264 regs, dvd_vm −148 ALUTs. ⚠ Read no ALM figure off this fit until
the branch is re-fit on top of Branch A, whose regular operand-mux form held the IMDCT
at 3,147–3,254 across two netlists. Build `DVD_almreclaimnav_20260911_0214.rbf`.

| item | change | gate |
|---|---|---|
| `pts_assoc` | 16×57-bit shift FIFO → sync-read ring + 2-entry registered window with a same-cycle write bypass (back-to-back pops stay legal) | `run_pts_assoc.sh` (+RED arm); `tools/netlist_canary.sh` row moved from `pts_q` to `head_pts` in the same commit |
| `pgc_palette` | convert-on-write; the 384-flop raw YCbCr shadow and its three 16:1 muxes deleted; reset defaults pre-converted (literal table) | `pgc_palette_tb`, `run_subpic.sh` |
| `dvd_vm` | 1 Hz counter tick: 16 parallel incrementers → one-GPRM-per-cycle walk, dispatch held during the walk | `dvd_vm_tb` (do_ticks widened to >16 cycles), `dvd_vm_atmos_tb`, `iso_reader_vm/vmgm/zerocell_tb` |
| `emu` O[2] | 52 window comparators → 5 x-windows × 3 y-bands; 24-bit colour chain → 2-bit code expanded at the output mux | no bench (eyeball O[2] On on HW) |
| `dvd_telem` | 19 × `telem_sync` (s1/s2/q) → one round-robin two-agree sampler, 57-cycle rotation | `run_telem.sh` (waits widened to 64 cycles) |
| `nav_pci` | `f_eptm` (32 b, only ever tested for all-ones) → 1-bit `f_forever`; write-only `h_sptm` deleted | `nav_pci_tb` |
| `emu` | `entropy_ctr` 32 → 16 bits | — |

Considered and skipped after reading: `spu_decode`'s "per-line multiplier" is a constant
STRIDE (already shift-adds); `nav_pci`'s duplicate subtracts are CSE'd by Quartus; the
SetSTN triple read (~60 ALMs, needs a latched condition) and the seek_time/seek_bar table
sharing (~4 M10K, cross-module ports) are deferred.

## 5. Branch C — reader (planned)

Low-risk first: gate/serialise the VCD/WAV-only seek math, delete the unreachable
`S_IFO_MAT/_PARSE/_TSRPT` states, factor the 4× flat-fallback init, remove dead ports;
then share the 7 PGC-window adder pairs and the `sd_lba` generation; then drop the BCD
prefix sum (also fixes the `cell_start_mem[cell_i[6:0]]` index-width bug). The
34-source `sec_lba` mux factoring is the big one and the riskiest.

## 6. Block RAM (planned)

spu bitmap 5 px / 10-bit word (−20 M10K); seek_time + seek_bar share one
pmap/cellf/clast set (−3…−4); `lpcm_unpack` FIFO_AW 12 → 11 (−11) only with an LPCM disc
on the HW gate.

## 7. Framework macros (user decision 2026-09-10)

`MISTER_DISABLE_ALSA` — yes (unused HPS→core audio, ~290 ALMs). `MISTER_DISABLE_ADAPTIVE`
and `MISTER_DOWNSCALE_NN` — declined (scaler filters vanish from the OSD; NN downscale
would alias a 720×576 source on 640×480 / 480-line-PAL outputs, the CRT users).
