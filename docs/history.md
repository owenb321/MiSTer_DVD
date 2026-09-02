# Solved-problem history (condensed)

This file replaces five long debug diaries that documented problems now **resolved and
merged**. Each is condensed to *what was wrong* and *how it was fixed*. The full
blow-by-blow investigation logs are preserved in git history (they were removed from the
tree in the repo-cleanup commit) — `git log --follow` the old paths if you need the detail:
`docs/blackscreen_underflow.md`, `docs/ddr3_burst_plan.md`, `docs/disp_line_prefetch.md`,
`docs/interlaced_cadence.md`, `docs/sdram_module_port.md`.

---

## 1. SDRAM-module port — first correct-color video (MERGED, PR fj#6)

**Problem:** The HPS f2sdram read path couldn't sustain the core's memory clock on the
user's board, so no decoded video ever appeared.

**Fix:** Ported the core's framebuffer onto the 128 MB SDRAM add-on board
(`dvd/sdram.sv` + `dvd/mem_sdram_shim.sv`). This produced the **first confirmed
correct-color SD MPEG-2 video on real hardware** (720×480, Matrix clip, proper
luma+chroma; BIST `0200/0200/0200/8000`).

**Left a scar (later resolved separately):** the shipped controller was open-page, BL=1
single-access (~30 MB/s), which sheared 720×480 scanlines. A burst-length-4 controller hit
~130 MB/s but corrupted chroma (green picture) — the back-to-back read data eye is ~1 clock
wide on this board. That shear is **resolved** — see §2.

## 2. 720×480 sawtooth shear — DDR3 burst datapath (MERGED, PR fj#9/#10)

**Problem:** 720×480 sheared and played at half speed. Initially blamed on memory
bandwidth (cache hit-rate / burst throughput).

**Diagnosis turn:** on-hardware bottleneck telemetry showed the DDR3 bridge sitting
**idle ~100%** during 720×480 while the decoder core was saturated — the wall was
**decoder compute-bound, not memory-bound**. The decoder was pinned at clk_sys = 27 MHz.

**Fix:** raise `mpeg2video.clk` 27→54 MHz (new PLL output + an ES-feed dual-clock CDC
FIFO; dot_clk stays 27, mem_clk 90). 720×480 then played **full-speed, shear-free,
un-garbled**. 81 MHz was tried and **rejected** (green chroma fringe, no further gain).
**Do not chase shear — it is resolved.**

## 3. Display line-prefetch — N64-style BRAM run-ahead (diagnostic dead-end)

**What it was:** an N64_MiSTer-style deep BRAM line-prefetch on the framestore read path
(a FIFO-depth override, modelled on `VI_linefetch.vhd` / `DDR3Mux.vhd`).

**Result:** it did **not** fix the 256-line strobe, and shear was already gone by then.
Its only lasting value was *diagnostic elimination*: it ruled out display-read
starvation / f2sdram latency / contention as the strobe cause, which redirected the hunt
to the emission side (§4). Kept here as a record of a ruled-out hypothesis.

## 4. 256-line black-frame strobe — macroblock-padded emission (MERGED, PR fj#19)

**Problem:** a recurring black-frame "strobe" above line 256; long suspected to be memory
returning zeros.

**True root cause:** it was a **picture split**, not memory. The resample emitted the
macroblock-padded height (`mb_height*16`) while the raster active region was the true
`vertical_size`; the surplus lines spilled into the next output frame.

**Fix (two parts):** (1) end emission at `disp_y == vertical_size-1`
(`dvd/resample_addrgen.v`); (2) `VERT_RES 479→480` in `modeline.v` (an active-region
off-by-one). Progressive and ≤480 clips then played clean. **Still open (separate):**
content with vertical res > 480 spills a sliver and needs a real vertical downscale/crop.

## 5. Interlaced DVD cadence — native 480i output (MERGED, PR fj#21)

**Problem:** after the strobe fix, interlaced 480i60 NTSC clips looked like "half speed."

**Disambiguation:** wall-clock was only ~8% long (not 2×) — so it was **judder / lost
field motion**, not a pacing bug. The default `deinterlace=1` weaves both fields into one
30 fps progressive frame, discarding 60-field motion.

**Fix:** OSD toggles **`O9 Interlaced Out`** (Off = progressive 480p default; On = native
480i, deinterlace off, interlaced modeline, VGA_F1 — ascal deinterlaces 60 fields/s) and
**`OB 480i Deint`** (Bob vs Weave). The real root cause of the residual black/missing
fields was **3:2-pulldown field parity** in `mixer.v` (a parity-tolerant frame-top fix),
**not** memory. Both Bob and Weave are HW-clean. The residual ~8% slowness was later
addressed by the frame-rate governor — see [frame_rate_governor.md](frame_rate_governor.md).

## 6. SDRAM controller + diagnostics removed (2026-07-01, `feature/remove-diagnostic-cruft`)

**Context:** the core's memory has run entirely on the HPS f2sdram (DDRAM) burst bridge
(`dvd/mem_shim_burst.sv`) since §2. The SDRAM add-on controller from §1 (`dvd/sdram.sv` +
`dvd/mem_sdram_shim.sv`) was still instantiated but with its decoder adapter tied idle —
its only remaining client was the `O3` SDRAM self-test. Several other bring-up diagnostics
had likewise outlived their purpose.

**Removed** (to shrink/simplify the synthesized design): the `O3` DRAM Self-Test
(`dvd/sdram_selftest.sv`), the `O4` DDR3 Burst BIST (`dvd/dram_burst_selftest.sv`), the
retired `dvd/dram_selftest.sv`, the `O12` AC-3 File Test (`raw_mode` path in
`dvd_audio_decode.sv` + `.ac3` file handling — the decoder was already HW-exonerated; see
`fabric_audio.md`), and the now-dead DDR3 read-response watchdog probe + `stuck_addr`
overlay plumbing in `emu.sv`. With the self-test gone, the **entire SDRAM controller and
all `SDRAM_*` ports/pin assignments** were deleted from `dvd/emu.sv`, `sys/sys_top.v`,
`sys/sys.tcl`, and `DVD.qsf` — reverting the §1 sys/ SDRAM restore back toward stock. Also
deleted the already-retired HPS-daemon audio files (`hps/dvd_audio.c`,
`dvd/audio_ddr_{pack,issue}.sv`, `dvd/cdc_req_ack.sv`) and their sim companions.

**Kept:** the `O2` debug overlay (rows 0-15 still useful — memory counters, flags, cache
miss-rate, feed-chain, decoder stage profiler, audio_ring status on rows 12/13, AC-3
self-heal counters on rows 14/15) and the `O13` Audio Genlock free-run diagnostic. All
recoverable from git if any removed path is needed again.

## 7. Green chroma fringe — decode-clock over-Fmax, fixed by physical synthesis (2026-07-01)

**Problem:** an intermittent GREEN (>red>blue) chroma fringe that follows content edges,
appearing on ~every other build regardless of the change. Historically misattributed to the
shared HDMI output stage / placement (see the `chroma-fringe-is-intermittent` memory), and
briefly (this session) to the 4:2:0 chroma-upsample mode — both wrong.

**Root cause (STA-confirmed):** the decoder compute clock `clk_dec` was 81 MHz, but the
decode domain's raw Fmax is only ~80 MHz (worst path: the high-fanout `mem_req_wr_almost_full`
FIFO flag fanning out to all 8 `do_*` scheduling conditions → the framestore_request 8-way
priority mux → `STATE_RECON`). Running ~0.7 MHz *over* Fmax means the worst path fails setup
on unlucky placements → the "every other build" lottery; green corrupts first because the
marginal value is the interpolated chroma (U/V) and green depends on both. `yuv2rgb` is on
the 27 MHz dot clock, so it and the OSD are unaffected (OSD stays crisp — the discriminator).

**Why not just lower the clock:** 54 MHz is fringe-free but brings back high-motion stutter
(81 is needed even for NTSC); and clocks in between (73.64, 77.14) *won't route* — the design
is congestion-marginal in the HPS-bridge region and the clock perturbs placement into a
routing failure. (81 and 54 happen to land routable placements.)

**Fix:** keep `clk_dec` at 81 MHz and enable Quartus **physical synthesis** in `DVD.qsf`
(`PHYSICAL_SYNTHESIS_REGISTER_RETIMING`/`REGISTER_DUPLICATION`/`COMBO_LOGIC = ON`). This
rebalances the limiting path and lifts `clk_dec` Fmax from 80.27 → **92.42 MHz (100 °C) /
96.33 (−40 °C)** — ~14% margin over 81 — so the domain is no longer over-clocked. Zero RTL
change, +~137 ALMs, routes clean. **HW-confirmed 2026-07-01** (`DVD_dec81_physyn`): fringe
gone across all test files, full-compute smooth motion. Reusable lesson: when a clock domain
sits a hair over Fmax (intermittent placement-lottery timing artifact), try physical synthesis
*before* lowering clocks or hand-retiming — it can buy ~15% Fmax with negligible area/risk.
(Physical synthesis later had to be turned OFF to route the congestion-marginal frame-drop
build — see §8 — which put the lottery back; the durable replacements are the targeted
retimes + the per-build Fmax gate below.)

## 8. Chroma fringe, round 2 — Fmax measurement was broken; per-build gate + disp_vscale retime (2026-07-09)

**Why it came back:** with physical synthesis off (frame-drop routability, commit `aedb7d4`)
the fringe protection was PR fj#58's manual `almost_full` retime — believed to give 91–110 MHz
across seeds. **That belief was junk data.** The seed sweep's extraction,
`grep -A2 '<clk_dec divclk>' DVD.sta.rpt | grep -oE '.. MHz' | tail -1`, reads a
**neighboring clock's row**: the Fmax Summary tables are sorted by Fmax *value*, so the rows
after clk_dec belong to whichever clocks happen to sort above it — different every fit.
Proof: the fit the sweep logged as "99.89 MHz" (seed 12) truly closes at **81.13 @100 °C /
77.38 @−40 °C**. The "SEED 7 = 110.24 MHz" pin was equally fictional; re-measured, that
shipped netlist is **81.41 / 78.0 MHz** — marginal, the lottery live.

**Lessons (all now enforced in tooling):**
- **Row-anchored STA parsing only** (`tools/fmax_check.sh`): match the row that *contains*
  the clock name, take its Restricted Fmax; never positional grep around it.
- **Keep the `.sof` and its `.sta.rpt` as a pair**: the sweep had packed a seed-7 sof while
  seed 12's report sat in `output_files/` (fmax_check warns when the rpt is older than the sof).
- **Verify timing per build**: `build_release.sh` now runs the check on every pack —
  `--release` refuses a marginal fit; default (testing) builds pack with a `_MARGINAL` name
  tag + the numbers in the notification. `tools/seed_sweep.sh` only accepts a seed that
  routes AND closes 81 at both slow corners, and keeps the best by worst-corner Fmax.

**The actual limiter had MOVED (measure, don't assume):** `report_timing` intra-clk_dec on
the current netlist put the top **400** paths all in one cluster — `dvd/disp_vscale.sv`
(the PR fj#66 CRT letterbox vertical scaler): line-buffer M10K read → 4-channel multiply
blend → `r_*` output registers, 11.0 ns of the 12.3 ns budget in one cycle (M10K Tco +
long routing + −1.1 ns clock skew + DSP blend). The 2026-07-01 limiters (framestore —
fixed by PR fj#58 — and `getbits→vld_en`) were no longer on top. **Fix:** fabric pipeline
register `a_q` on the RAM read + a stage-3 payload carry (`s3_*`) — splits the path into
two short hops. +1 cycle of display-path latency, absorbed by the pixel_queue's 32-slot
prog_full margin; blend arithmetic unchanged (`resample_chain_tb` geometry/blend-proof/
pass-through suites green). Note the marginal cluster sat in a module that is *inactive*
outside CRT Letterbox — a domain-wide Fmax deficit surfaces as whichever *functional*
near-critical path (chroma interp on HDMI) fails on a given placement, so the fix target
comes from STA, not from where the artifact appears.

**Result:** clk_dec Fmax **92.38 MHz @100 °C / 88.64 @−40 °C** at the pinned SEED 7
(worst corner +9.4% over 81) — the physsynth-era margin, without physsynth. Routes at
86% ALMs. The domain's worst path is now the blend multiply itself (`a_q → r_*`) at a
comfortable +1.5 ns slack; every other cluster has more. Release build
`DVD_fmaxgate_20260709_1749.rbf` packed through the hard gate. When the fringe next
reappears on a gate-green build class, re-run `report_timing` intra-clk_dec and retime
the NEW top cluster (this is the third one: framestore → PR fj#58, disp_vscale → this).

## 9. Crop pan-scan aliasing — the horizontal stretch was still nearest-neighbour (2026-07-31)

**Symptom (user report):** "the crop mode on analog output looks aliased — is it using nearest
neighbour instead of the scaling method the letterboxed output is using?" Yes, exactly that.

**Why it was still NN.** PR fj#66 shipped both anamorphic corrections at once, both
nearest-neighbour; §8 then made *Letterbox* a true 2-tap vertical bilinear (`dvd/disp_vscale.sv`)
and left *Crop* alone, because Crop's error is smaller: it is a 1.36× **upscale** (528→720), so
each source pixel is emitted once or twice and the artifact is a mild stair-step rather than the
dropped-line banding that made Letterbox unacceptable. `docs/crt_anamorphic.md` §8/§10 recorded
it as "an easy future refinement" — which is a fine judgement call, but "smaller" is not
"invisible", and on a real CRT with real 16:9 content the user could see it.

**The fix** (`docs/crt_anamorphic.md` §8b): `disp_hstretch` becomes an output-driven phase walk,
`out[j] = src[k]·(1−f) + src[k+1]·f` with `k + f = j·hsrc/hdst`. Two things made it cheap:

1. **The step is quasi-static.** `256·hsrc/hdst` only changes at a sequence header or a mode
   toggle, so an 8-step restoring divider computes `qstep`/`rstep` once and the pixel path is a
   plain add/compare. The instinct to reach for a per-pixel divider (or the 15-way threshold
   tree that avoids one) was the wrong altitude — the expensive operation wasn't in the loop.
2. **The quantisation direction was load-bearing.** `f8` is FLOORed, never rounded, so
   `floor(256·f) ≥ 128 ⟺ f ≥ ½` *exactly*, which makes the nearest tap provably
   `k + (f8≥128) == floor((j·hsrc + hdst/2)/hdst)`. That let `crt_ov_map`'s inverse (§9) stay a
   plain rounding Bresenham — no divider, no approximation, and the co-sim stays EXACT rather
   than tolerance-based. Rounding `f8` instead would have broken the identity on a 1/512-wide
   sliver and forced a fuzzy test.

**Fmax discipline, applied pre-emptively.** §8 is the cautionary tale: `disp_vscale`'s
memory-read → 4-channel-multiply → output-register cycle was 11.0 of 12.3 ns, *set* the clk_dec
Fmax, and produced the chroma-fringe placement lottery. Adding a SECOND blend to the same domain
at ~89% ALM is precisely that situation, so this one was built short from the start: a 3-stage
split (taps+weight → `(b−a)` difference → multiply+round+add) with both taps in fabric registers
rather than an M10K output (no Tco), and the `osd` channel nearest-picked instead of blended —
semantically right anyway (it is a colour-lookup index, not a colour) and 3 multipliers instead
of 4. Escalation ladder if a future placement bites: add a 4th stage (register `d*f + 128`
alone), truncate `f` to 5 bits (position stays exact, only the weight quantises to 1/32), or
blend luma only.

**Fixed en route:** the stage now emits exactly `hdst` pixels per line — the same count a Fit
line emits. The duplicator's `hdst−1` off-by-one had been documented as "invisible inside CRT
overscan", and it was, but the output-driven walk makes the correct count fall out for free and
`mixer.v`'s line end is purely position-code driven, so there was no reason to keep it.

**Testing lesson (the same trap, one axis over).** `+linetag` couldn't prove the vertical blend
because blending two adjacent integers rounds back to an integer — §5 records that, and the fix
was `+vgrad`'s scaled tag. The horizontal axis has the identical trap, so a column-index ramp
would have been just as useless; the new `+hgrad` uses a period-2 square wave instead, where a
2-tap lands strictly between the levels (~14/15 of columns) and NN scores exactly 0. The same
reasoning forced restructuring `crt_ov_map_tb` T1: its old `{u,y} = index` tag decodes to garbage
through a real blend, so T1a moved to a small geometry where an AFFINE tag collapses the blend
onto the nearest tap exactly (`b−a = 1` ⇒ `out = k + (f8≥128)`), keeping the co-sim exact.
Running Fit with `+hgrad` is the CONTROL that proves the `~hcrop_en` pass-through is still a
real bypass — the tb inverts the assertion automatically for non-Crop modes.

**And the control immediately earned its keep.** The first `+hgrad` cut scored 184064/184064 —
*100%* interpolated, suspiciously above the ~14/15 the walk predicts. Cause:
`resample_bilinear` treats the stored luma byte as **signed** and adds 128 on the way out
(`y <= y_pixel_5 + 8'd128`), so the memory bytes `0x28`/`0xC8` display as 168/72 rather than the
intended 40/200 — *both inside* the band being counted as "interpolated". The main assertion
sailed through on wrong data; only the Fit control, which demands the OPPOSITE result, could
expose it (it would have scored 100% too, in a mode that provably does no horizontal resampling
at all). Two durable rules: **a passing test on a mode that cannot exhibit the effect is a
broken test**, so pair every "the feature works" assertion with a control whose expected value
is inverted, not merely smaller; and **memory-plane values ≠ displayed values** in this pipeline
— the tb now carries `HG_MEM_*` and `HG_*` as separate explicit constants.

**Result:** ✅ **HW-CONFIRMED 2026-08-01 (PR fj#155)** — Crop looks correct on the real CRT, no
fringing. Build: SEED 11, clk_dec **82.82 MHz @100 °C / 87.34 @−40 °C**, ALM 37,147 (89%, a
touch BELOW the pre-change baseline), DSP 91→94, `releases/DVD_cropblend_20260801_0437.rbf`.

**Seed note worth keeping.** The pinned SEED 9 and then SEED 7 both FAILED TO ROUTE on a
netlist only +65 ALMs bigger — placement succeeded, the router quit on congestion. 82.82 is the
lowest passing worst-corner value in the QSF ledger, so rather than assume it was a lucky first
hit, a full margin sweep was run over every remaining seed: 13 no-route, 5 → 77.57, 8 → 74.47,
17 → 81.73. **SEED 11's 82.82 is the BEST of all seven seeds tried** — this netlist simply sits
lower than its predecessors, and 82.82 is the TOP of the distribution rather than a marginal
outlier. That distinction matters for the next session: there is no better seed to go find, so a
future fringe report on this netlist needs a different lever (the §9 escalation ladder — a 4th
pipeline stage, a 5-bit weight, or luma-only blending), not another sweep.

**Process trap, logged:** `tools/seed_sweep.sh` writes each seed it tries into `DVD.qsf` and
does NOT restore the previous value when the sweep finds nothing — it left `SEED 17` pinned. Any
sweep that EXHAUSTS must be followed by re-pinning the intended seed by hand, or the repo ships
a seed nobody validated.

## 10. Chroma fringe, round 3 — the SDC clock groups never matched this fork's PLL (2026-08-01)

**The discovery.** While hunting a durable fix for the recurring clk_dec Fmax placement
lottery (the chroma fringe, §7–§8), a read of the STA "Setup Transfers" table showed the
fitter timing tens of thousands of paths stock MiSTer cuts: `h2f_user0_clk ↔ sys_pll`
(~26k paths), `FPGA_CLK2_50 → clk_sys` (~8.8k), `pll_audio → clk_mem` (~5.9k). Root
cause: `sys/sys_top.sdc`'s `set_clock_groups -exclusive` matches core PLLs by the stock
pattern `*|pll|pll_inst|altera_pll_i|*[*].*|divclk`, but this fork's PLL is
`dvd/sys_pll.sv` instantiated as `emu|sys_pll` with `altera_pll_i` directly inside (no
`pll_inst` wrapper level) — **so the core's four PLL clocks matched NO group, and every
asynchronous framework crossing was fully timed, for the fork's entire history.** The
unclosable CDC noise came to −68k/−72k ns TNS vs clk_dec's real −278 ns: timing-driven
placement was optimizing garbage ~250× larger than the paths that actually fringe. The
SDC's own comment says the groups exist "to simplify routing" — this design's chronic
congestion and Fmax marginality are exactly what that cut is for.

**The fix** (PR fj#156): add the fork's pattern
`*|sys_pll|altera_pll_i|*[*].*|divclk` to the SAME `-group` as the stock pattern, so
intra-sys_pll transfers (clk_sys↔clk_dec etc.) stay timed — identical semantics to every
stock core — and only the cross-group async crossings are cut. Fork CDC audited before
cutting: `iec61937_wrap` crosses clk_sys→CLK_AUDIO through a gray-code dual-clock FIFO +
reset synchronizer; AUDIO_L/R ride the stock framework interface. Post-fix STA confirms
29 false-path transfer rows (was 12, none of them sys_pll).

**Tooling shipped alongside** (the measure-first doctrine from §8 made one-command):
`tools/timing_paths.sh` → `timing_paths.tcl` dumps the top-N intra-clk_dec setup paths
from the existing fit db (no refit) to `output_files/clk_dec_paths.txt`. Baseline on the
pre-fix SEED-17 fit: 98 of the top 100 paths are the `disp_vscale` `a_q → r_u/r_v` blend
(~10.2 ns — the cluster PR fj#92's read-register fix left behind); the single worst is
`framestore_request` `mem_req_wr_dta` → mem_request_fifo M10K write port (11.76 ns,
slack 0.11 — mostly routing, the classic lottery victim). Also: `fmax_check.sh`'s
sof/rpt mismatched-pair warning is now bidirectional (the Aug 1 exhausted sweep left a
seed-17 rpt NEWER than the shipped seed-11 sof, which the old `-ot`-only check missed).

**Numbers.** Same netlist, same SEED 11, only the SDC changed: clk_dec went 82.82 @100C /
87.34 @−40C → **85.90 @100C / 82.93 @−40C** — the hot corner (historically the binding
one) gained +3.1 MHz, and the placement visibly reshuffled (the corner profile flipped),
which reset the seed distribution. ALM 37,138 (89%), RAM 80%, DSP 94 — unchanged.

**Seed sweep on the new landscape — the lottery is dead.** Full sweep (SWEEP_ALL=1,
seeds 7 9 13 5 8 17 23 1 29 42): **ALL TEN routed AND passed**, worst-corner spread
86.87 → 92.46 MHz. On the byte-identical pre-fix netlist, seeds 7/9/13 were NO-ROUTES
and the best of seven was 82.82. Per-seed (100C/−40C): 7=95.96/92.07, 9=91.25/88.90,
13=96.15/91.56, 5=90.91/88.86, 8=92.69/88.52, 17=91.14/86.87, 23=90.67/88.21,
1=94.48/90.29, **29=95.35/92.46 (pinned)**, 42=95.23/91.02. Second payoff: fits dropped
from ~30 min to **~12 min each** — the fitter stopped iterating on impossible CDC TNS —
so sweeps and future feature builds get ~2.5× cheaper.

**Consequences shipped:** SEED 29 pinned (+14% hot-corner margin); release gate
`FMAX_MIN` raised 81.0 → **86.0** (below the entire healthy distribution so good fits
pass without sweeps, above the 81–83 class that historically fringed on HW — a sub-86
fit now means the netlist degraded: measure with `tools/timing_paths.sh` and retime the
top cluster). Stage-4/5 contingencies from the plan (clk_dec over-constraint uncertainty,
disp_vscale/framestore retimes) were NOT needed and remain on the shelf; the §9
escalation ladder stays documented for a future netlist that outgrows this margin.
`releases/DVD_sdcgroups_sweep_20260801_1449.rbf` = the SEED-29 build. ✅ **HW-CONFIRMED
2026-08-01 (PR fj#156, user report: "looks great")** — fringe gone, playback clean, S/PDIF
unaffected (the pll_audio crossing false-pathed = stock framework semantics, as audited).

## 11. mem_shim_burst tag/LRU store to M10K — the ALM congestion reclaim (MERGED, PR #18; ✅ HW-CONFIRMED 2026-08-28)

**The motive.** After PR #17 the design sat at **98% ALM (41,202/41,910)** and the fit
lottery was back despite §10's SDC fix: the D-pad branch needed a seed re-sweep, and the
menu-link branch burned eleven failed seeds before a measured retime of framestore's
mem_request_fifo write closed it (see the DVD.qsf seed ledger). The 2026-08-27
per-entity fit report named the fish: `dvd/mem_shim_burst.sv` = **4,899 ALMs / 6,546
registers**, third-largest block in the design, bigger than all of dvd_vm. The 32 KB
cache DATA array was already M10K, but the tag/valid/LRU store was not: 12b × 128 sets ×
4 ways of tag flops read through four parallel 128:1 async muxes, plus 2b × 512 LRU
rank flops — the project's recurring LUT-RAM pattern (M19, parse_buf, iso-navigator)
one more time. RAM headroom existed (503/553 M10K), and the whole tag+LRU store is
under 8 kbit.

**The design.** Tags and LRU ranks moved to two sync-read simple-dual-port M10Ks
addressed BY SET (one read = all four ways' context); the valid bits stayed in flops
(512 FFs — S_INIT invalidation and victim-invalidate-before-fill keep their
reset-friendly semantics, since BRAM has no reset). The 1-cycle RAM latency is absorbed
by growing the `S_STREAM` hit loop from two to **three overlapped stages** (present
set → compare + present data address → emit): still 1 word/cycle, with command N+1's
tag read overlapping command N's data read. Misses and writes issue their DDR
transaction **directly from the compare-stage verdict cycle** (fast entry), so the
miss/write path costs the same cycle count as the flop version (the TB's pure-miss
meter actually improved, 26.0 → 25.0 cyc/resp). Geometry and policy untouched:
NSETS=128 / ASSOC=4 / LINEW=8, true LRU.

**Why it stays bit-exact** (the §-level invariant: hit rate IS the product — the
direct-mapped predecessor sheared on real hardware):
- Back-to-back same-set hits see current ranks through a **2-deep bypass** — the
  stage-B touch being written that cycle, plus a last-write register covering the
  M10K's undefined mixed-port read-during-write edge. Any colliding write is bypassed
  by construction, so the undefined RAM value is never consumed.
- Fills **read-modify-write whole set words from snapshots** captured at the miss
  lookup — legal because nothing else writes that set in between (the stream is
  drained; a paired slot B is a different set by rule). No byte-enables needed.
- The dual peek costs 2 cycles now (`S_PEEK` latches + presents, new `S_PEEK2`
  decides), and pairing is suppressed when the skid holds a command at fill entry (the
  stream's pops are speculative now, and peeking the FIFO past a parked older command
  would reorder). The un-paired miss lands later with an identical LRU view.

**The gate.** New `bench/dvd/mem_shim_ab_tb.sv` runs the live module against a FROZEN
copy of the flop-tag implementation (`bench/dvd/mem_shim_burst_ref.sv`, main @c223041)
on one trace through two independently-random-stalled rigs, and requires the
accepted-burst-address sequences to be **identical** (same misses ⇔ same victims ⇔ same
LRU state). All four {cwf,dual} combos: 1,351 identical misses, every response checked
against a reference memory. `mem_shim_burst_tb` unchanged across five config sweeps
(pure-hit throughput still 1.0 cyc/resp). `bench/dvd/run_mem_shim.sh` bundles the
ladder, PASS-grepped (the M19 vvp-exit-0 lesson).

**Numbers** (build `DVD_shimreclaim_20260828_0259.rbf`, pinned SEED 5, FIRST roll):
- Module: 4,899 ALMs / 6,546 registers → **~1,406 ALMs / 1,028 registers** (−3.5k
  ALMs, −5.5k FFs in-module); +3 M10K (2× tag 128×48, 1× LRU 128×8), all three
  stores altsyncram-inferred (checked in the fit report — the resurrected-RAM
  lesson from D-pad seek cuts both ways).
- Design: **41,202 ALMs (98%) → 36,341 (87%)** = −4,861 ALMs of placement pressure
  (beats the −3–4k target); RAM 503 → 506 / 553 M10K; DSPs unchanged.
- Timing: clk_dec **93.73 MHz @100C / 90.33 @−40C** (gate 86.0) — the pinned SEED 5
  passed on the first roll, no sweep needed, margin comparable to the menu-link
  ledger entry (94.5/91.5) despite the whole-module rework. The reclaim's point —
  seed sweeps become rare again — holds on its first data point.

**HW soak — ✅ PASSED 2026-08-28 (user report), merge gate cleared.** Required because
this is the shear-fix module and sim cannot prove hit-rate-under-real-traffic. Soak on
`releases/DVD_shimreclaim_20260828_0259.rbf`: the entire MiB movie played through plus
menu/seek actions — no video issues, no shearing, no artifacting. Merged as PR #18
(no release cut yet — rides with the next one; `` `CORE_VERSION `` 0.1e stays open).

## 12. The video-output settings consolidation + the field-parity coin flip (2026-09-02)

Two CRT field reports arrived within days of each other: the derive/weave analog path
looked "extremely wobbly — not how an interlaced signal normally looks on a CRT" (the
long-documented caveat-2 pairing defect, now seen in the wild), and `Analog Out = Native
Fields` came back from any chapter skip / fast-forward / Analog Aspect change "super
aliased", healed only by toggling the mode away and back "3 or 4 times". The
repeat-until-fixed ritual was the tell: a 50/50 parity roll.

The parity bug was root-caused to the junction of two individually-correct decisions: the
mixer's relaxed frame-top matcher (the 3:2/drop black-fields fix) accepts a field at
either raster parity slot, and nothing carried the raster's field parity back to
`resample_addrgen`'s pickup — so one odd perturbation flipped content-field↔raster-field
phase permanently (invisible under HDMI Bob, which is why it shipped unseen). Fixed with
a feed-forward alternation guard plus a mixer→addrgen parity feedback loop that inserts
exactly one held-frame field; the two triggers compose by XOR and the inserted field's
type depends on which fired. Full design, the livelock the first draft had, and the
RED/GREEN testbench evidence: `docs/field_parity.md`.

With fieldpass immune to the wobble by construction and the re-engage hole closed, the
user reversed the 2026-08-23 "all four Analog Out modes stay" decision and collapsed the
surface to one option: `O[10:9] Video Output = Auto/Interlaced/Progressive` (Interlaced =
Native Fields renamed; the derive modes, `Interlaced Out`, and the `det_video` detector
deleted; `re_interlace` fieldpass-only; config layout `v,2`). The deliberate cost: the
dual-raster headline — CRT 480i with simultaneously-progressive HDMI — no longer exists;
with a CRT active, HDMI shows 480i. Reversal rationale recorded at the (retained)
original decision block in `docs/roadmap.md`; superseded headers in
`docs/interlaced_auto.md` and `docs/analog_dual_raster.md`.

### §12 addendum — HW round 1: the boot-time modeline-walk reset race (2026-09-02)

The first hardware round of the consolidation build (`DVD_videoout_20260902_1146`)
failed immediately: with the analog ini bits set, the core booted reporting
"719x5i", a disc load showed "719x1035123i @ 31.48 kHz", and the composite CRT was
dead — while the Progressive path was fine. The reading: 31.48 kHz is the
PROGRESSIVE line rate and the "i" flag means `VGA_F1` was toggling, so `il_eff`
was asserted but the modeline never switched (Main's geometry measurement returns
garbage line counts when F1 toggles against a progressive raster), and
`re_interlace`'s period check therefore correctly refused to lock — dead analog.

Root cause: a latent race the consolidation was the first to arm. The emu modeline
walk keys on RAW `reset_n` and fires its six regfile writes starting the next
clk_dec cycle, but `mpeg2video` synchronizes its resets internally (`reset.v`,
cascaded 5-FF `sync_reset` stages) — `hard_rst`, which gates every modeline
register in `regfile.v`, deasserts ~5–10 cycles AFTER `reset_n` rises. Writes in
that window are silently discarded while the registers re-default to the
progressive modeline, and the walk latches `il_prev` anyway, so no edge remains to
retry. Invisible since the walk was built (2026-07): `il_eff` was always 0 at boot,
so a swallowed init walk wrote the values the registers were resetting to anyway,
and every later mode change came from the OSD with the decoder long alive.
`Video Output = Auto` driving `il_eff` from the ini bits is the first boot-time
walk that ever wrote something different from the reset defaults.

Fix: a `dec_ready` gate — walk kicks wait until `core_sync_rst` (the decoder's own
`sync_rst_out`, the last reset in the cascade to deassert, same clk_dec domain)
has been observed high for 8 consecutive cycles. Proven by
`bench/dvd/modeline_boot_tb.sv` (`run_modeline_boot.sh`), which drives the REAL
`reset.v` + `regfile.v` with a verbatim copy of the walk: pre-fix it reproduces
both failure shapes (total swallow — the exact HW symptom — and partial
application, timing-dependent, matching "very broken"), while the OSD-toggle
control passes even un-fixed, which is why no earlier HW round could have caught
it. The walk is the only emu-side writer of decoder registers; any future one must
gate on `sync_rst_out`, not `reset_n`.
