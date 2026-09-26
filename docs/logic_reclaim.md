# Logic reclaim — the 2026-09-10 area audit and its branches

**Status:** Branches A (AC-3), B (nav/VM/glue) and C (reader) ✅ merged and
HW-confirmed 2026-09-11. Branch D (`feature/reader-slim`, the reader again, plus the
retirement of the numeric debug overlay) is bit-identical in simulation and
✅ HW-confirmed by the maintainer on 2026-09-26, §8. The block-RAM packing pass (§6) is still planned.

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
prefix sum, the 34-source `sec_lba` mux factoring. (The `sec_lba` factoring was done in
Branch D, §8; the other two are still open.)

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

## 8. Branch D — `feature/reader-slim` (bit-identical in sim; ✅ HW-CONFIRMED 2026-09-26)

**Why again.** Between Branch C and 2026-09-25 the reader grew from 6,421 to **7,869
ALUTs** (seamless-branch seek, four angle fixes, the duration scan, WAV/CD-DA, the title
span, TMAP), the design sat at **98 % ALMs needed**, and the reader's 6-bit state space was
at **63 of 64 codes**: the TMAP time seek (PR #128) had to squeeze ten phases into one
state code because codes were scarce. Scope, by user decision: **bit-identical only** (no
timer, cache or BCD-path change), and retire the compiled-out numeric debug overlay.

**The gate: `bench/dvd/run_reader_regress.sh` + `bench/dvd/reader_trace.sv`.** Every bench
that instantiates the reader (41 benches, 50 arms including the red arms) runs with a second
root module that `$fmonitor`s all 82 kept output ports (741 bits) of the reader. Run once in a
worktree of `main` for a baseline, then `--baseline` after each commit: any difference in a
verdict, a run log or a trace fails. `$fmonitor` prints settled end-of-timestep values, so the
trace cannot race the edge a bench drives on. ★ **Negative control:** routing `S_CELL_LOAD`
through one extra cycle changed the traces of all three arms it was tried on **while all three
benches still passed**, so a verdict-only gate would have missed it. Baseline non-passes on
`main`, all expected: `iso_reader_atmos` and `iso_reader_tpsw_boot` (pre-existing failures)
and the two red arms (`auddrain` with `NO_AUDIO_TERM=1`, `mode_realign_chain +realign=0`).
⚠ Gitignored fixtures (e.g. `mib_vts21_vtsi_mat.hex`) must be copied into the `main`
worktree before its baseline run, or the baseline differs for the wrong reason.

**Baseline numbers** are the 2026-09-26 SEED 9 fit of `main` (build
`DVD_deintmerge_20260926_0154`, commit `2a79dd7`, no RTL difference from `e8f790d`); Branch C
compared on SEED 7. Reader row from `DVD.map.rpt` (ALUTs total (own), registers, DSP):

| step | change | ALUTs | regs | DSP | gate |
|---|---|---|---|---|---|
| — | `main` | 7,869 (7,799) | 4,435 | 3 | baseline |
| 3 | stale comments | — | — | — | comment-stripped source identical |
| 4 | 27 redundant `fi`/`fi_cap_v` resets before `S_SECREAD`; write-only `chap_tp`, `ptt_base_off`, `ttsrp0_vtsn`; constant `attr_resume`; 1-bit `ptt_res_tt`; dead `nr_cells > MAXCELL` and `cur_angle == 0` guards | | | | trace identical |
| 5 | DEBUG_OVERLAY retired (below) | | | | lint, preprocess-identical |
| 6 | the reader's 16 dead ports | **7,586 (7,516)** | 4,493 | 3 | trace identical |
| 7 | `jump_ctx`, `menu_dom` (now a wire of `dom`), `cf_c`, an unreachable empty-cell arm | | | | trace identical |
| 8 | `ext_cum` folded into `seek_cum` | | | | trace identical |
| 9 | one BCD→seconds converter for `dur_scan` and the cell walk | | | | trace identical; exhaustive 2²⁴-input check, 0 mismatches |
| 10 | one subtractor for the `sml_agli` byte snoop | | | | trace identical |
| 11 | **one shared sector-address adder** for all 37 parse reads | **7,018 (6,948)** | 4,451 | **2** | trace identical |
| 12 | six pure wait states folded into `S_LAT` | **7,065 (6,995)** | 4,453 | 2 | trace identical |

Net: **−804 ALUTs (−10.2 %), +18 registers, −1 DSP, 0 M10K** (all 12 reader `altsyncram`s
still inferred after every step). The design's map total moved by the same amount
(63,038 → 62,232), so the emu/overlay edits were exactly area-neutral. ⚠ Step 12 **costs**
47 ALUTs over step 11: `state <= lat_ret` has to decode a register into the one-hot state.
It is there for the six state codes, not for area.

**Final fit** (commit `6a443ab`, build `DVD_readerslim_20260926_0404.rbf`, SEED 9 **first
roll**): clk_dec **90.03 MHz @100C / 89.45 MHz @-40C** (gate 86.0; `main` was 90.95 / 89.09),
**40,654 / 41,910 ALMs needed (97 %)** against `main`'s 41,221 (98 %), reader **4,449 ALMs**
against 4,895, 94 / 112 DSP (was 95), M10K unchanged (507), registers 52,932 (+23).
`lint_undriven`, `netlist_canary` and `fmax_check` pass. Both builds were made in a detached
worktree pinned at their commit, so their `.rbf.json` records `branch: HEAD`; the SHA is the
real identity. A mid-branch fit of step 6
(`DVD_readerslim_20260926_0329.rbf`, SEED 9 first roll) read 93.07 / 90.69 MHz and 41,039
ALMs.

**✅ HW-CONFIRMED by the maintainer (2026-09-26)** on the final build, running the targeted list:
a physical disc with menus on, the menu-heavy discs (T2 Mission Profiles, Scooby-Doo 2's maze
and whac-a-mole, Harry Potter / Scene It in-title menus), a language-page menu and back,
Chapter Menu and a scene jump, gamepad hold-to-scrub, seeks inside T2's branches, a seek
pre-empting a seek, Auto mode on stub and TV discs, timed stills, and the `O[2]` blocks, all
good. One pre-existing defect surfaced on X-Men Apocalypse (the chapter total, see the Auto
Auto-mode note in `docs/dvd_nav.md`); it is identical on v0.7.0 and is not from this branch.

**Harness smoke pass (2026-09-26, final build + the current Main), run before it:**
- `nav_diff` on Men in Black, `--script "1 2"`: no differences from libdvdnav (boot parks at
  PGC 5, both buttons land in PGC 9).
- Men in Black with Disc Menus Off: Auto picks the feature (1:37:52, PGCN 1 of VTS 21);
  30 s of telemetry read 2.498 refreshes per frame, 47,999.5 Hz, 0 lates, 0 drops, 0
  drain-gate closures (Branch C's round read 2.496–2.498 and −11 ppm).
- Chapter skips 1 → 2 → 3 of 27. A keyboard Fast Fwd and three Rewind taps: `flags.tmap=1`,
  `tmap_fb=0`, landings consistent with +10 s and −30 s.
- VTS 14's five-angle block via the Debug title picker: `ANGLE 2/5` then `3/5`, clock running.
- `WAVTEST_48.wav`: total `0:02:59`, 47,999.9 Hz. A VCD `.bin`: 44.1 kHz, 2.00 refreshes per
  frame, seek works. A flat `.VOB`: seek works; a settled 20 s window read 2.350 refreshes per
  frame against 2.373 for `main`'s build through the identical script (the file's cadence
  varies with content). Its total estimate moving 3:16 → 2:16 after a seek is pre-existing
  (`main` does the same).

★ **Two things the numbers do not say at first sight:**
- **The +58 registers at step 6 are Quartus extracting the reader's main FSM.** `debug_state`
  exported the raw `state` register, which blocked state-machine extraction; with the port
  gone, `DVD.map.rpt` lists `dvd_iso_reader_inst|state` as a state machine for the first time
  and re-encodes it one-hot (about 55 more flip-flops, less decode logic). Functionally
  identical, but it is a real netlist change from a "dead port" removal.
- **"Area-neutral" steps were not all neutral.** Steps 3–6 were expected to cost nothing in
  silicon (Quartus prunes dead ports and write-only registers), yet the reader lost 283 ALUTs
  by step 6: the 27 deleted resets and the constant `attr_resume` simplified next-state muxes,
  and the FSM re-encoding simplified decode.

**Step 11, the sector-address unit** (the "34-source `sec_lba` mux" deferred in §5). Each of
the 37 read sites now writes `sec_base`/`sec_off`, and `S_SECREAD` issues
`sd_lba <= sec_base + sec_off` on its first cycle, the cycle it always issued on. Two details
carry the identity:
- the `S_FETCH` straddle cross reads **`pb_sec + 1`, not `sd_lba + 1`**: a resident fetch can
  cross after `S_STREAM` has moved `sd_lba`, and `pb_sec` is the resident sector by definition;
- eleven sites also loaded `pit_sec`/`pgc_sec`/`ptt_srpt_lba`/`tm_sec` with the same sum. They
  set a flag, and the flagged register takes the sum on the next cycle **at the top of the
  clocked block, whichever branch runs**. `seek_jump` is not state-gated and can pre-empt
  `S_SECREAD`'s first cycle; loading inside the `S_SECREAD` arm would then have skipped the
  load the old code made at the site. Nothing reads those registers on that cycle.

**Step 12** frees codes 14, 29, 30, 45, 47 and 51. `S_CELL_LOAD`, `S_ATTR_RD` and
`S_EXT_LOAD` are not pure and stay.

**The DEBUG_OVERLAY retirement (step 5).** `dvd/debug_overlay.sv`, emu's 207-line
`ifdef DEBUG_OVERLAY` block and ~40 emu nets that only fed it, `ps_demux`'s seen-mask block,
and `tools/osd_read.py` are deleted; `DVD.qsf` keeps a one-line note. The overlay had been
compiled out of every release since 2026-07-09, its last real use was the 2026-08-31 IEC 61937
flap probe, and `dvd_telem` has carried every hardware round since 2026-09-05. The debug
**ports** on `mem_shim_burst`, `dvd_vm`, `dvd_audio_decode`, `iec61937_wrap`, `audio_ring`,
`av_sync` and `mpeg2video` stay, connected `()` in emu, because their own benches read them
(`cache_missrate_tb` exists to test one). The release-visible `O[2]` mode (menu-highlight
blocks, HUD `{PGCN,VTS}`) is a different mechanism and is untouched. If a `pgc_error` reason
readout is ever wanted again, it is one more `dvd_telem` word; the reason codes were: 1 empty
PGCIT, 2 PGCN out of range, 3 bad `pgc_start_byte`, 4 JumpTT resolve, 5 no PGCI_UT, 6 bad UT
header, 7 VTS or menu VOB not found. Older `docs/` mentions of overlay rows are measurement
history and are left as they are.

**Considered and skipped:**
- **`gmem` single write port:** a cycle-identical shape exists but costs **+126 registers**
  (the `S_WALK_VTS` site reassigns `grp_*` in the cycle it writes). Two write sites have
  always inferred fine.
- **The textual duplicates** (move-to-next-PGC, next-cell, timed-still arming, VM dispatch,
  angle clear, pmap launch, `CH_R`/`CH_GR`): Quartus already collapses identical
  assignments, and a pulse register acted on by another arm would add a cycle.
- **A muxed extent-walk comparator:** the 32-bit mux costs more than the comparator it saves.
- **Merging `nav_cand` into `seek_target`:** the lifetime proof predates TMAP's rewrite of the
  seek path; 32 registers were not worth re-proving it.
- **Deferred, by user decision:** the BCD/binary twin prefix sum (`run_eltm` +
  `bcd_time_add` + the 255×32 `cell_start_mem` + `cur_cell_start`; needs emu's HUD clock to
  take binary seconds, own branch and HW round), the 16 KB → 8 KB stream cache (−8 M10K, but
  it is the hot delivery path), and sharing a timer prescaler (moves expiries by ≤ 1 ms).

**Pre-existing defects found on the way, NOT fixed here (the branch is bit-identical by rule):**
- **`seek_jump` and `jump_go` never clear `fetch_cross` or `pb_skip`** (only reset does).
  `seek_jump` is not state-gated, so a seek landing on the first cycle of a straddle refill's
  `S_SECREAD` leaves `fetch_cross` set, and the next unrelated read then resumes the
  abandoned fetch (`fi <= fi_save`, `fetch_xw` set). TMAP's fetches can straddle, and its own
  comment says a newer seek can pre-empt it between reads. The likely outcome is a garbled
  probe that falls back, not a hang, but it is wrong. One-line fix: clear both in the
  `seek_jump` branch.
- **`run_telem.sh`'s `test_key_table` fails on `main`:** its `PS2_TO_LINUX` table lacks
  PS/2 `0x55`/`0x4e`, the `-`/`=` volume keys added in PR #106.
