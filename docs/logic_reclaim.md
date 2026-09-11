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

## 3. Branch A — `feature/alm-reclaim-ac3` (✅ built, ✅ HW-CONFIRMED 2026-09-11)

**HW round (maintainer's rig, `DVD_almreclaim_20260911_0138.rbf`):** `audio_check` on Men
in Black — all four AC-3 tracks audible (5.1 main −26.2 dBFS RMS, the others −31 to −42,
gate −80, digital silence reads −999); a controlled single capture of an LPCM VOB
(−51.9 dBFS RMS, −35 peak) and of an MP2 VCD (−44.3 / −20.3 at 44.1 kHz); Passthru with
steady telemetry (ring parked at 34 frames, video 2.497 refreshes/frame, no drain-gate
closures — no AC-3 receiver on the rig, so the bitstream itself is not decodable there, as
always); video pacing on the feature 2.49955 refreshes per picked-up frame, 23.973 fps,
audio 47,997.6 Hz, zero lates, zero drops over 46 s.

Detail in `docs/ac3_decoder_architecture.md` §4.12 and the DVD.qsf ledger. Every commit
gated by `bench/ac3/run_front_cosim.sh` (bap bit-exact vs liba52 on 13 streams) **and PCM
dumps of blocks 0–5 byte-identical** to a pre-change baseline, plus each unit suite.
Synthesis result **−2,544 ALUTs**; fit SEED 7 first roll, clk_dec 93.66 / 90.86.

Found en route: `bench/ac3/run_balloc.sh` had been failing silently since M19d (stale
combinational delta-BA model, vvp exit 0). Fixed and `$fatal`ed before the refactor.

## 4. Branch B — `feature/alm-reclaim-nav` (✅ built, ✅ HW-CONFIRMED 2026-09-11, rebased onto A)

**Re-fit on top of Branch A (SEED 7, first roll):** clk_dec **96.76 / 92.13**, "needed"
36,833 (88 %), placed 40,059, ALUTs 60,642 → **57,723** and registers 52,238 → **50,328**
against v0.5.0 — the IMDCT cliff is gone (3,148 ALUTs) and the two branches' savings add.
Build `DVD_almreclaimnav_20260911_2010.rbf`. The two paragraphs below record the earlier
`main`-based fits and remain true of them.

**HW round (maintainer's rig, `DVD_almreclaimnav_20260911_0244.rbf`):** Men in Black
navigation diffed against libdvdnav (FP → 1 → 2, no differences); the `O[2]` blocks decode
exactly as before (highlight armed, subpicture shown, recolour fired — the 2-bit colour code
expands to the same four colours); the palette convert-on-write renders the MiB menu's
button/text colours correctly by eye; the rewritten telemetry sampler reads 47,999.5 Hz
audio (−11 ppm) and 2.496 refreshes per frame on the feature — identical to Branch A —
and a direct three-sample delta of `aud_play` gave exactly 3,000 counts/s; Scene It boots
to its main menu (PGC 14, armed) with the serialised counter tick and button 1 starts the
game. ⚠ A 30 s `telem --watch` over the MiB MENU read 69.5 kHz: that is the harness's
16-bit unwrap being fooled by the counter reset at a menu-loop restart, not the sampler
(the same window on the feature reads 48 kHz).
⚠ **Pre-existing, NOT this branch:** `nav_diff` on ULTIMATE_T2 (`--script "1 2"`) reports
button 1 landing in PGC 5 / VTS 4 on the board where libdvdnav lands in VTSM PGC 1 — the
v0.5.0 build on the same rig gives the identical result. libdvdnav presses 1 at a
two-button VTSM menu; the board parks on a title-domain still first (trajectory 3 3 1 1 1*),
so the same digit is pressed at different menus. Worth its own issue.

**Fit (SEED 7, first roll, cut from `main`):** clk_dec 89.73 / 89.42, "needed" 38,768,
placed 40,823 (unchanged), registers 51,954 → 50,578 (**−1,376**), ALUTs +774 — **of
which +799 is the IMDCT mapping cliff on RTL this branch does not touch** (3,228 on
`main`, 4,027 here). Own modules: pts_assoc −732 regs, pgc_palette −359 regs / −55
ALUTs, dvd_telem −264 regs, dvd_vm −148 ALUTs. ⚠ Read no ALM figure off this fit until
the branch is re-fit on top of Branch A, whose regular operand-mux form held the IMDCT
at 3,147–3,254 across two netlists. Build `DVD_almreclaimnav_20260911_0214.rbf`.
**Rebuilt with `MISTER_DISABLE_ALSA` (SEED 7, first roll):** clk_dec 92.64 / 91.97,
registers **52,238 → 50,167**, placed ALMs 40,821 → 40,615, the `alsa` entity gone; ALUTs
+551 of which the IMDCT cliff is +782. Build `DVD_almreclaimnav_20260911_0244.rbf`.

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

## 5. Branch C — `feature/alm-reclaim-reader` (✅ built, ✅ HW-CONFIRMED 2026-09-11, rebased onto A+B)

**Re-fit on top of A and B (SEED 7, first roll):** clk_dec **96.06 / 91.84**, "needed"
36,636 (87 %), placed 39,890 (95 %), ALUTs 57,465, registers 50,497; the extent table
infers as two `altsyncram`s. Build `DVD_almreclaimrdr_20260911_2046.rbf`.

**All three branches together against the v0.5.0 baseline fit on the same seed:** ALUTs
60,642 → **57,465 (−3,177, −5.2 %)**, registers 52,238 → **50,497 (−1,741)**, placed ALMs
40,821 → 39,890, "ALMs needed" 38,802 → 36,636 (93 % → 87 %), clk_dec hot corner 89.94
(the v0.5.0 release fit) → 96.06.

**HW round (maintainer's rig, `DVD_almreclaimrdr_20260911_0335.rbf`):** Men in Black
navigation diffed against libdvdnav (FP → button 1 → button 2: no differences); the feature
with chapter skips 1→3, a D-pad +10 s seek and prev-chapter restarting the chapter, all read
off the pinned HUD; a flat `.VOB` mount through the consolidated `S_FLAT_INIT` (HUD clock
live, D-pad seek advancing it); a VCD `.bin` mount and seek (44.1 kHz, 2.00 refreshes per
frame). Telemetry after every seek: 2.496–2.498 refreshes per picked-up frame, 48 kHz,
zero lates, zero drops, zero drain-gate closures.

Shipped: shared PGC-window walk adder (7 sites → 1 mux + 1 adder pair), the unreachable
`S_IFO_MAT/_PARSE/_TSRPT` states deleted, one `S_FLAT_INIT` state for the three flat
fallbacks, one base+offset adder for `sd_lba`. Reader 6,680 → **6,421 ALUTs**; fit SEED 7
first roll, clk_dec 88.75 / 88.62. Gate: every `iso_reader_*_tb` (verdict set identical to
`main`, which has four pre-existing non-passes: `atmos`/`attr` fixtures absent,
`tpsw_boot` fails on `main`, `mount_tb` only trips a grep), plus `run_vcd`, `run_mgl`,
`run_mode_realign`, `run_dpad_seek`, `run_seamless_audio`. Build
`DVD_almreclaimrdr_20260911_0335.rbf`.

⚠ **The first build did not fit and Quartus said nothing:** consolidating the `ext_mem`
write sites made it stop inferring the extent table as RAM (+5,373 registers, four M10Ks
gone, `ext_mem[n][b]` listed as plain registers). An explicit registered write port with
one address expression restored the `altsyncram`. After any edit near a memory's write
sites, check `DVD.map.rpt` for its "Inferred altsyncram" line before spending a fit.

Not done (deferred, medium risk): serialising the VCD seek arithmetic, dropping the BCD
prefix sum, the 34-source `sec_lba` mux factoring.

### Originally planned

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
