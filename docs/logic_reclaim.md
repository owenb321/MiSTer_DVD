# Logic reclaim — the 2026-09-10 area audit and its branches

**Status:** Branches A (AC-3), B (nav/VM/glue) and C (reader) ✅ merged and
HW-confirmed 2026-09-11. Branch D (`feature/reader-slim`, the reader again, plus the
retirement of the numeric debug overlay) is bit-identical in simulation and
✅ HW-confirmed by the maintainer on 2026-09-26, §8. The block-RAM packing pass (§6) is still planned.
§10 (2026-10-05) surveys where else the audio engine's microcode pattern would reclaim
logic, including the MPEG-2 decoder. It is analysis only; nothing is built.

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

## 9. Branch E — PR #135: the VM's 16 GPRMs in an M10K (✅ HW-CONFIRMED 2026-09-26)

**Origin.** Built 2026-09-26 on the save-state branch (`docs/save_states.md` §5e), where it
made that feature fit. Save states were then shelved; this branch carries the register move
alone, because its reclaim never depended on them.

**What it is.** As flops, the VM read its GPRMs combinationally at about eight sites (the
two compare operands, the set source, the destination for add/sub/and/or/xor/swap and the
ALU, and SetSTN's and SetHL_BTNN's register operands). Each is a 16:1 × 16-bit mux. Now:

- `gprm` is a single-port M10K (`(* ramstyle = "M10K, no_rw_check" *)`).
- **`V_OPRD`**: after the command fetch, 7 cycles load six operand registers
  (`opA`/`opB`/`opS`/`opD`/`opY`/`opZ`) that every former `gprm[]` read now uses.
- Every write is ONE registered request (`g_we`/`g_wa`/`g_wd`). `opA`/`opB` are
  **forwarded** on a write, so type 4's compare-after-set still sees its own set.
- Swap is two writes through the one port (`sw_pend`, a cycle apart).
- The 1 Hz counter-mode tick is a read-modify-write walk; non-counter GPRMs are still
  skipped in one cycle.
- The array cannot be async-reset and stay a RAM, so reset and mount clear it with a
  16-cycle walk (`clr_busy`), and dispatch waits for it.
- `dbg_g3`/`dbg_g14_9` are tied off: nothing in `emu.sv` consumes them, and a read there
  would rebuild the array from LUTs.

**Measured** — `DVD_gprmram_20260927_0055.rbf` (SEED 9 first roll, clk_dec 89.02 / 87.42
against the 86.0 gate) vs `main` at PR #134 (`DVD_autoptt_20260926_1603`, 89.88 / 88.92):

| `dvd_vm` (full fit) | ALMs | ALUTs | regs | M10K |
|---|---|---|---|---|
| `main` (flops) | 1,965 | 3,397 | 1,150 | 5 |
| save-state branch (RAM + a snapshot port) | 1,618 | 2,622 | 1,171 | 6 |
| **this branch (single-port RAM)** | **1,340** | **2,281** | **1,045** | 6 |

| whole design | `main` | this branch | Δ |
|---|---|---|---|
| Combinational ALUTs | 62,557 | 61,428 | **−1,129** |
| Map estimate, ALMs needed | 40,920 | 40,203 | −717 |
| ALMs placed | 40,981 | 40,790 | −191 |
| Headline "ALMs needed" | 39,189 (94 %) | 38,735 (92 %) | −454 |
| RAM blocks | 507 | 508 | +1 |

The module saves **625 ALMs / 1,116 ALUTs**; the second port was costing the save-state
build about 280 ALMs of that. Placed ALMs move less than the module does because the fitter
packs the freed space loosely (LABs used stay 4,189 / 4,191); the ALUT count is the honest
reclaim figure (§1). ⚠ clk_dec is ~1 MHz thinner than `main`'s on both corners, still
passing; sweep the seed if a later branch lands near the gate.

**Behaviour change, deliberately small:** each command takes ~7 more cycles, the tick walks
the registers, and a mount clears them with a walk. The VM runs at nav-event rate, so none
of it is time-critical, but it is a timing change in every disc's navigation. The
reader-regression gate agrees: every bench's verdict and log are identical to `main`, and
the trace differs only in the six benches that include the VM (`iso_reader_vm`,
`_zerocell`, `_celldur`, `_menudrain`, `_auddrain`, `_auddrain_noaudio`), by a handful of
cycles.

**Gates:** `bench/dvd/run_gprm_ram.sh --red` (one mutation per mechanism: forwarding, the
swap's second write, the tick write, the mount clear, the operand-capture slot; each caught
by the arm written for it, two of them new — T6s, the first vector ever to execute a swap,
and T7c, a mount clears the GPRMs) and `tools/check_gprm_ram.py` (the array is touched only
in its port block and keeps its ramstyle; RED on four re-regressions). A stray read
silently rebuilds the array from LUTs and a stray write silently stops it inferring;
neither shows in simulation.

**HW round 1 (2026-09-26, rig, `tools/nav_diff.py` against libdvdnav, same Main both arms,
control = `main` at PR #134):** six discs, one fixed button script each, derived from the
oracle. **The branch reproduced the control's table exactly on every compared step:** MiB
4/4, Matrix 3/3, Harry Potter Interactive 3/3 (its 4th step was voided by another session
loading a core mid-run), Scooby-Doo 2 1/1, Scene It HP never parked on either build, and
T2's first button lands on PGCN 5 where libdvdnav says PGCN 1 **on both builds** — a
pre-existing difference on `main`, not this branch.
⚠ What that does NOT cover: steps that never reached an armed park on either build (T2
after its first button, the Scooby maze itself, Scene It's game), and counter-mode GPRMs.
Those need a hand check.
✅ **HW-CONFIRMED 2026-09-26 by the maintainer, by hand on the same build:** Scooby-Doo 2
(minigame and maze), T2 (Mission Profiles and a slideshow), Harry Potter Interactive
(Player Mode) and Scene It HP (a game started and a question answered) all behave as on
`main`.

## 10. Where else the engine pattern fits (2026-10-05 survey, nothing built)

**Status:** analysis only. No branch, no fit, and every saving below is an estimate
unless it says "measured". Source: the 2026-10-05 fit of `main` at PR #159
(`output_files/DVD.fit.rpt` §20): 38,699 / 41,910 ALMs needed (92 %), 519 / 553 M10K
(**34 free**), 87 / 112 DSP.

**The question.** Moving DTS, the AC-3 parse and MP2 onto one microcoded engine
(`ac3_engine.md`, `mp2_engine.md`, `dts_decoder.md` D2) reclaimed more logic than DTS cost.
Where else does the same move pay off? It worked because the replaced logic met three
conditions:
1. **Rate.** The work happens at most a few hundred thousand operations per frame, so a
   sequencer issuing about one operation a cycle keeps up.
2. **Shape.** The area was control: many conditional fields and per-state datapath copies
   that Quartus muxes across mutually exclusive FSM states (§2's diagnosis). Microcode
   turns that into ROM words.
3. **Exclusivity.** The jobs never run at the same time, so they can share one datapath.

The M10K count binds any new ROM: the audio engine's shared 2K-word ROM cost 8 blocks.

### 10a. The AC-3 IMDCT onto the audio engine (★ first candidate)

`imdct_512` is the last hardwired AC-3 stage: **2,013 ALMs, 23 M10K, 9 DSP (measured)**,
outside `audio_engine`. `ac3_engine.md` ("The contract") and `dts_decoder.md` P4 keep it
hardwired because "a direct-form transform for 5.1 needs 61–74M multiply-accumulates a
second, 2.3–2.7× one multiplier". ⚠ **That premise describes an algorithm we do not run.**
`imdct_512` is liba52's FFT form (pre-twiddle, 128-point split-radix IFFT, post-twiddle and
window, overlap-add), driven by a flat butterfly schedule in `dvd/ac3/ac3_imdct_tables.svh`.

**Cost on the engine, measured on the model (2026-10-05, below):** a 5.1 frame of IMDCT
is **24.7 % of real time** (213K cycles) in one pass, not the 8–16 % first estimated
here. That estimate counted multiplies; the FFT's adds outnumber them (3,584 of a long
block's 6,120 terms per channel only add). It is still far from the direct form's
2.3–2.7× of one multiplier, so the premise above stays wrong, but the margin is thinner
than first claimed. Worst frame, parse included: **52.8 % raw, 59.0 % under the budget
gate's ×1.25 convention**, against the 60 % bar.

Why it fits the pattern: the engine already runs a transform as a ROM program
(`tools/dts_vecrom.py`, the half IMDCT). It also runs MP2's synthesis. AC-3 and DTS are never
decoded together, so the IMDCT's `bufmem`, `delay_mem` and `pcm_mem` could share DTS's rings.

- **Estimate:** −1,200 … −1,600 ALMs, about −10 M10K, up to −9 DSP. The ROM cost depends on
  the encoding. Executing `imdct_sched_pk`'s butterflies as one vector op (reading the
  existing 291-entry table) is much smaller than flattening them into per-multiply terms.
- **✅ Decided (maintainer, 2026-10-05): bit-identical to `imdct_512`.** The engine
  reproduces `imdct_512`'s arithmetic exactly: Q8.23 samples, the existing Q1.17 twiddles
  and window, a **truncating** `>>> 17` after each product, and the same operation order.
  `run_ac3_ab.sh` keeps requiring identical PCM for every block.
  - **Why:** the identical A/B is what made the AC-3 parse and MP2 moves safe, and it
    names the first wrong block. The alternative was a new IMDCT with half-up rounding and
    wider coefficients, gated LSB-bounded against liba52 and within about 1 s16 LSB of
    `ac3_front`. It would have bought cycle margin and an inaudible accuracy gain, at the
    cost of that gate and a tolerance bench of the kind that has passed vacuously before.
    MP2 made the same choice (`mp2_engine.md`: "bit identity is the VCD safety net").
  - **What is already there:** `dts_vec.sv` has a floor mode (`trunc`). MP2's window
    (`V_MWIN`, `vlo27`/`vhi27`) already multiplies a 32-bit operand as two 16-bit halves
    into the 56-bit accumulator and stays bit-identical to `mp2_decode`.
  - ⚠ The cycle figures given when this was decided (44 % for either option) rested on
    the same undercount. Option B's IMDCT has the same FFT add structure, so it would
    also land near 53 %: its cycle advantage was illusory, and the decision stands.

**The cycle count (2026-10-05): `tools/imdct_model.py` + `bench/ac3/run_imdct_xcheck.sh`.**
- **The model is `imdct_512`, bit for bit.** `run_imdct_xcheck.sh` runs one `imdct_512`
  through 24 consecutive blocks of each of 15 streams (2/0, 1/0, 3/0, 2/1, 3/1, 2/2, 3/2,
  short blocks, live DRC; 360 blocks) and compares all six `pcm_mem` slots with `!==`
  after every block: identical. `--red` (one product rounded instead of floored) is
  caught on **all 15**. A window with fewer than 256 nonzero words fails as vacuous, and
  a silent one is SKIPped by name (The Residents' gate window is silent for 20 frames).
  ⚠ The bench zeroes `pcm_mem`/`delay_mem` first, as the M10K does at power-up: a 3/0
  fold multiplies an unwritten surround slot by `slev = 0`, and x × 0 = x in simulation.
- **The program it costs** (`imdct_model.py cost`): every product its own term (imdct_512
  floors each product before adding), one RAM operand read per term, temporaries written
  once and re-read, 2 bubble cycles per butterfly and per PRE/POST element. A long block
  is 6,120 terms a channel, a short one 5,440. **This is a program shape, not RTL**: the
  parse side of the budget is the RTL-calibrated `ac3_isa` emulator, the IMDCT side is
  this count.
- **Results, all 29 gate streams that decode (24 frames each):**

  | worst frame (`noise_5p1_48k_640k`) | raw | gate convention (×1.25 on the IMDCT) |
  |---|---|---|
  | parse alone | 28.1 % | — |
  | + IMDCT, one pass | **52.8 %** | **59.0 %** |
  | + IMDCT, split only wide operands | 52.8 % | 59.0 % |
  | + IMDCT, every product split | 61.4 % | 69.8 % |

  Stall sensitivity, one pass: 0 bubbles 50.4 %, 4 bubbles 55.2 %. The real discs sit
  lower (MATRIX RELOADED 50.1 %, DARK PASSENGERS 49.8 % raw).
- **Operand widths.** Of 15.4M products on the gate streams, **none is wider than 27
  bits**; the widest is 24 (POST). ⚠ **That is a sweep, not a bound.** Legal extreme
  input, full-scale coefficients in every bin, reaches 28–32 bits with no DRC, and with
  the maximum DRC boost (`dynrng = 0x7F`, ×15.75) about 90 % of products are wider than 27
  bits (32 = `imdct_512`'s own words wrapping, which an exact copy must reproduce). So a
  27-bit multiplier with no split is **ruled out**: it would silently differ on legal
  input.
- **What separates the two remaining options is only the pathological case.** On every
  measured stream, "split only when wide" costs exactly what a widened multiplier costs.
  - **Split when wide (recommended):** the operand's top bits decide per product whether
    MP2's two-pass split runs. Exact for every value, no new DSP, real streams at one-pass
    speed; worst case bounded by "every product split", 61.4 % raw, still inside real time
    (100 %) though over the 60 % design bar. Per the spec-maximum rule it must count its
    wide products in telemetry, so a stream that pays the slow path is visible.
    `--mul-bits 20` exercises the path: one 52.8 < split-when-wide 54.3 < every 61.4 %.
  - **Widen the multiplier:** 52.8 % flat for any input, at a DSP and an adder in the
    engine's 27×27 datapath, which DTS shares.
- **The margin lever, if 59.0 % is too close:** 3,584 of a long block's 6,120 terms only
  add two words. A term that reads two operands through the scratch's second port
  (`imdct_512`'s `bufmem` is already true dual-port) saves about 1,800 terms a channel-block,
  about 6 points raw on the worst frame.
- **Program size rules out unrolling.** 6,120 terms × ~24 bits per block type is ~15 M10K,
  and 34 are free. The program must be PRE/POST loops plus a butterfly op that walks the
  existing 291-entry `imdct_sched_pk` with a fixed term template per op code.
- **★ Next step:** replace `tools/test_ac3_isa.py`'s measured `IMDCT_BLOCK` constant with
  the engine IMDCT charge (this model's per-frame terms), so the budget gate scores the
  real plan, then design the executor (`dts_vec` states, the width check, the counter).
  `imdct_512`'s error against liba52 (1,666 Q8.23 LSB, `run_imdct.sh`) is unchanged, since
  the arithmetic is.
- **Gates that exist:** `run_ac3_ab.sh` (block for block against the hardwired path),
  `bench/ac3/run_imdct.sh`, `run_ac3.sh --red`, then a by-ear HIL round on 5.1 and
  short-block material (`bbb_short_5p1`).

### 10b. A navigation sequencer for the reader, the VM and `nav_pci` (biggest, riskiest)

> **🔧 The VM pilot is built (2026-10-07, branch `feature/nav-ucode`): `docs/nav_engine.md`.**
> - **Cost:** `dvd_vm` 1,350 → 853 ALM in the core (−498), +4 M10K; timing passes.
> - **Equivalence:** transaction-equal to the old FSM (a three-way A/B with the FSM kept
>   as the oracle), and every VM gate is green with its `--red` arms re-expressed.
> - **Offline diff:** the same microcode runs offline against libdvdnav over the ISO
>   library (`tools/nav_offline.py`), which is the "largest practical win" below.
> - **Rig:** HIL `nav_diff` = the control on every compared step.
> - **Pending:** the maintainer's hand check.

| entity | ALMs | M10K |
|---|---|---|
| `dvd_iso_reader` | 4,352 | 32 |
| `dvd_vm` | 1,384 | 6 |
| `nav_pci` | 498 | 4 |
| **total** | **6,234** | 42 |

All three run on `clk_sys`, the audio engine's clock. The reader is the textbook case for
condition 2: §2 traced its area to next-state muxes and per-state adders, and §8 records its
state space at 63 of 64 codes before Branch D freed six. Every navigation feature since
v0.5.0 has grown it (§8: 6,421 → 7,869 ALUTs in two weeks). As microcode, a new parse
would cost ROM words, not ALMs. The VM is already an interpreter: DVD VM commands are an
instruction set that `dvd_vm` decodes with hardwired muxes.

- **⛔ Not the audio engine's silicon.** The audio engine is 28–45 % busy during playback,
  which is when cell changes and NV_PCKs arrive. Sharing it would tie audio glitches to
  navigation. What carries over is the method: the ISA, `uasm` assembler, Python model,
  trace-equal emulator and RED microcode arms (`tools/test_dts_isa.py` pattern).
- **What stays hardwired:** the sector pump, the read-ahead ring, straddle refills and
  seamless junctions. These are a real-time data path, not parsing.
- **★ First step (measurement only):** classify every reader `S_*` state as either
  "drives `sd_*` or the stream FIFO" or "only parses the sector buffer", and attribute
  ALUTs to each side (`DVD.map.rpt` per entity, after splitting the module if needed).
  The saving is unknown until that split exists. The audio engine's sequencer, without
  its vector ops, is about 860 ALMs (A2a, `ac3_engine.md`). If parsing is most of the
  reader, a guess is −2,000 … −3,000 ALMs.
- **Gate change:** `run_reader_regress.sh` requires bit-identical traces, and a sequencer
  shifts every operation by cycles. (Branch E's GPRM move changed the traces too.)
  Acceptance would be bench verdicts plus `tools/nav_diff.py` against libdvdnav on HIL,
  as Branch E was.

**Would it make navigation changes easier? (2026-10-05, from the last 40 merged PRs.)**
Twelve of them changed the reader, the VM or `nav_pci`, and **all twelve also changed
`emu.sv`**. Lines changed:

| PR | reader / VM / `nav_pci` | `emu.sv` | other `dvd/` |
|---|---|---|---|
| #159 Still off | 140 | 32 | 0 |
| #158 chapter skip at the title's edges | 196 | 14 | 0 |
| #134 Auto-mode chapter table | 93 | 2 | 0 |
| #115 protection-zone hang | 87 | 2 | 0 |
| #128 TMAP seek | 231 | 92 | 60 |
| #154 player parameters | 55 | 42 | 85 |
| #152 32 subtitle tracks | 97 | 173 | 77 |
| #113 SPU re-send per cell | 9 | 50 | 79 |

The first four are navigation decisions (which PGC next, what a button means at an edge,
which chapter table): those would become microcode edits. The last rows are wiring and
other modules, which stay hardware.

- **Easier:**
  - a change costs ROM words, not ALMs or state codes, so headroom stops gating
    navigation work;
  - a Python emulator of the program (the DTS/AC-3 method) could be diffed against
    libdvdnav over the whole ISO library before any build. Today `tools/nav_diff.py`
    needs the HIL rig, one disc at a time. ★ This is probably the largest practical win;
  - a microcode-only change might not need a refit: Quartus can usually replace an
    M10K's initial contents without re-placing (the update-MIF flow; ⏳ unverified on
    17.0), which would avoid the seed and timing churn (#159 needed a SEED 7 pin). A
    program loaded at startup, like the idle logo's `boot.rom`, would let a fix ship as a
    file, at the risk of a file and core that do not match;
  - the VM is already an interpreter: semantics fixes such as #158's Next → POST and
    Prev → `prev_pgcn` become small program changes.
- **Not easier:**
  - the seams stay in RTL (buttons, the HUD, flushes, the subpicture path), with their
    `check_*_wiring.py` gates;
  - the costliest bugs are races between a decision and the real-time path (§8's
    `fetch_cross` that `seek_jump` never clears; the stale audio PTS of PR #143).
    Microcode does not remove them, it adds a boundary (sequencer ↔ sector pump) where
    they can occur, and a Python emulator does not model that timing;
  - one sequencer serialises three blocks that run in parallel today, so it needs a
    scheduling rule (an NV_PCK arriving mid VM command chain). Event rates are low, about
    two a second.
- **Cost:** a rewrite of about 9,300 lines (reader ~6,000, VM ~2,400, `nav_pci` ~960), each
  carrying fixes recorded in `status_log.md`. The risk is reintroducing a fixed bug; with
  no bit-identical trace gate, libdvdnav diffs over the library are the main net.
- **★ Smallest step that answers the question: microcode the VM alone first.** 1,384
  ALMs, self-contained, its semantics fully specified by libdvdnav's `vm.c`, with
  `dvd_vm_tb`, `nav_diff` and Branch E's gate pattern (`run_gprm_ram.sh`) already in
  place. It measures whether the workflow is really easier, and what it costs in ALMs and
  M10K, before the reader is touched. The reader's parse would follow; its sector pump
  stays hardwired.

### 10c. The transport cluster: share one arithmetic unit (resource sharing, not microcode)

`seek_bar` 1,015 · `scrub_ctrl` 678 · `transport_hud` 409 · `lin_rate` 350 · `seek_time`
312 · `dpad_seek` 248 · `cdda_toc` 208 · `secs_bcd` 101, about **3,300 ALMs**. All on
`clk_sys`, all doing event-rate or refresh-rate position and time math, and several carry
their own serial divider or multiplier (`seek_bar`'s header: "ONE serial restoring
divider"; `lin_rate`'s ratio divide; `seek_time`'s divider FSM).

- **Without 10b:** one shared divide/multiply unit behind an arbiter. That is lower risk
  and needs no toolchain. `seek_bar` already shares its divider between fill, cursor and
  tick conversion.
- **With 10b:** these become routines on the navigation sequencer.
- ⛔ `scrub_ctrl`'s note against dividing in the rate path still applies. It is about
  correctness on seamless-branch discs, not area.
- **Estimate:** not attempted; it depends on how much of each module is the arithmetic.

### 10d. The MPEG-2 decoder (`mpeg2video`, 10,723 ALMs)

Most of it fails condition 1. `motcomp` (3,109), `resample` (1,553), `idct` (812) and about
20 FIFOs and readers move pixels or coefficients every cycle, and decode pacing (0 lates on
the census since F1 + F2, `decode_pacing.md`) is the hardest-won property in the core.

- **★ `mult22x16` (cheapest item in this section, not microcode).** The six instances in
  `idct1d_col` (`rtl/mpeg2/idct.v:1380`) are a Virtex-II workaround: a 22×16 multiply split
  into an 18×16 DSP product, a 4-bit shift-add partial product in LUTs and a 38-bit
  adder. That is 41–51 ALMs each, **277 ALMs in all (measured)**, and **each already
  occupies a whole DSP block** (measured), so Cyclone V's 27×27 mode would take the full
  product with no extra DSP. The split is exact (`multiplier = msb·16 + lsb`, lsb
  unsigned), so `product <= multiplier * multiplicand` with the same two-cycle latency is
  bit-identical. Estimate −150 … −250 ALMs; the pipeline registers partly move into the
  DSP. Gate: the IDCT bench, then the conformance streams (`docs/conformance.md`).
- **`vld` header parsing (1,015 own ALMs, 71 states).** About 30 states parse the
  sequence, GOP, picture and extension headers and load the quantiser matrices, once per
  picture. That part fits microcode; the macroblock and coefficient path must stay
  hardwired. The header fields must remain registers that feed the rest of the decoder.
  `vld` is on `clk_dec`, so it would need its own sequencer. A guess is −200 … −400 ALMs.
  Low priority.
- **`memory_address` ×4 (872 ALMs, measured; one DSP each).** Deep per-request pipelines:
  `bwd` 336, `disp` 250, `fwd` 171, `recon` 115. Sharing one between forward, backward
  and reconstruction first needs a measurement of how often each issues requests, because
  this is motion compensation's critical path.

### 10e. Not candidates

- **`ascal`, both `osd`s, `audio_out`:** `sys/`, edited only when unavoidable.
- **`mem_shim_burst`:** a cache, already slimmed (§3, `history.md` §11).
- **`spu_decode`, `disp_sched`, the display stages:** pixel-rate.
- The block-RAM items stay in §6.

### 10f. Suggested order

1. **`mult22x16`** (10d): small, exact, an afternoon plus a fit.
2. **The IMDCT on the engine** (10a): exactness decided, cycles measured; next, the
   budget gate's `IMDCT_BLOCK` and the executor design.
3. **The VM as a microcode pilot** (10b), or the reader state split first if the area
   question matters more than the workflow one. Either decides whether the rest of 10b
   and 10c are worth a branch. **Built (2026-10-07, `docs/nav_engine.md`): the pilot
   says yes on area (−498 ALM in the core for +4 M10K).** Next is the reader state split.
