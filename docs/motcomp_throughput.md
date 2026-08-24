# Motion-comp throughput — high-motion / PAL stutter

Status: **Stage 1 (reference-read run-ahead prefetch, O[18], now baked in always-on)
HW-validated at depth 512 — fixed the MiB high-motion stutter; no blackouts/fringing.** The
BBB-PAL stutter is a **separate, decode-LOAD-bound problem** (confirmed: lower-bitrate
re-encode ≈ smooth) — NOT a PAL timing/pacing bug and NOT recon-rate. The fix, the
**graceful frame-drop governor** (**`O[12] Frame Drop`** on/off, branch
`feature/frame-drop-reland`), is **HW-VALIDATED for its purpose: PAL stutter fixed, playback
speed correct.** It is an **opt-in PAL/heavy-content tool** — leave Off for NTSC (which
over-drops otherwise). A debt-decay knob to auto-separate NTSC film from PAL was tried and
HW-removed (structural film-cadence lates overlap PAL's real lates — see "HW results" below);
the durable fix for auto-safety is the film-3:2 governor cadence work (roadmap). The
recon-pipeline /
128-bit ideas further down were investigated and shelved.

## Problem

> **⚠️ Correction (2026-07-09, USER-CONFIRMED): the Matrix stutter is a SOURCE-FILE / rip
> defect, not our decoder** — it reproduces identically in **VLC on a PC**. So the `dbg_ref_stall`
> ~91 % measured on Matrix (below) is a CONFOUNDED datapoint and Matrix should not be read as
> evidence of a decoder throughput deficit. The real, HW-confirmed wins in this doc stand on
> their own content: **Stage-1 prefetch fixed MiB act 3**, and the **frame-drop governor fixed
> PAL BBB**. No remaining high-motion stutter is demonstrated on a known-good source, so the
> deeper recon/128-bit rewrite has no live motivating case (parked).

High-motion NTSC clips (MiB, BBB) and the taller PAL 576-line frame stutter. Every
*memory* and *clock* lever is exhausted (see memories `clock-lever-exhausted-matrix`,
`current-clocks-levers-spent`, `highmotion-rootcause-reffeed-latency`): `clk_dec` is at its
81 MHz ceiling (108 wedges f2sdram), `clk_mem` at 90 MHz, the 32 KB L2 cache copes at ~78 %
hit, and the f2sdram bridge is *periodically idle* during high motion — the decoder is not
keeping reads in flight. So the residual stutter is compute/feed bound, not bandwidth bound.

### Mechanism (from the RTL)

- `rtl/mpeg2/motcomp_recon.v` reconstructs **one block-row per two cycles**
  (`STATE_WAIT`→`STATE_RUN`→`STATE_WAIT`) and, on high motion, sits in `STATE_WAIT`
  *starved of reference pixels*. Its own precise probe `dbg_ref_stall` (lines 224-226) reads
  **~91 % on Matrix vs ~77 % on BBB**, and its comment names the fix: a
  **"prefetch/overlap lever"** on the reference feed — *not* recon arithmetic.
- `rtl/mpeg2/motcomp_addrgen.v` issues reference addresses serially (~112 per macroblock,
  one per cycle) and its `STATE_INIT` stalls on the shallowest of
  `{fwd_addr, bwd_addr, dst, dct_block}` almost-full.
- **The reference run-ahead was never deepened.** The shipped N64-style line-prefetch
  (`dvd/mem_override/fifo_size.v`) deepened only the *display* path. The *reference* fifos
  used the upstream defaults (256-deep, data threshold 64), so `framestore_request` stopped
  issuing forward/backward reads after only ~192 buffered rows — too small to hide f2sdram
  miss latency + display-read contention (display is *higher* priority than fwd/bwd), and the
  bridge idled while recon slowly drained.

## Stage 1 — reference-read run-ahead prefetch (O[18])

Reference-side twin of the display prefetch: let `motcomp_addrgen` issue fwd/bwd reference
reads far ahead of recon demand so reference rows pre-stage in BRAM and the bridge stays busy.

**Changes**

- `dvd/mem_override/fifo_size.v` — deepen the coupled reference run-ahead set 256→1024
  (`addr_width` 8→10): `FWD/BWD_ADDR_DEPTH`, `FWD/BWD_DTA_DEPTH`, `DST_DEPTH` (the `dct_block`
  fifo is `DST_DEPTH-3` and scales with it). All five must be deepened in lockstep because
  `addrgen` stalls on the shallowest. Thresholds are unchanged (the free-slot reservation:
  data 64 > `2**MEMTAG_DEPTH`=32 so in-flight reads can't overflow; addr 144), so `prog_full`
  now asserts near fill 960 instead of 192. **(Depth revised 1024→512 — see the blackout note
  below — so shipped `prog_full` ≈ 448, cost ≈ 13 M10K, still 2× the 256 baseline.)** Capped at
  1024 max (a 2048 *display* build placed but failed to route).
- `dvd/ref_dta_gate.sv` (new) — single-bitstream A/B gate. Tracks data-fifo occupancy
  (`+wr_ack`/`−rd_valid`) and outputs the almost-full that `framestore_request` sees:
  `prefetch_en=1` → the fifo's native deep `prog_full` (~960); `prefetch_en=0` → assert at the
  upstream baseline fill (192). So one bitstream toggles deep vs baseline run-ahead. Counting
  only sets a flow-control threshold; the fifo's own full flag still guarantees no overflow.
- `rtl/mpeg2/mpeg2video.v` — new `ref_prefetch_en` input; the fwd/bwd `framestore_reader`
  data `wr_dta_almost_full` is renamed `*_deep` and routed through a `ref_dta_gate` instance
  (one per direction) before reaching `framestore`.
- `dvd/emu.sv` — `"O[18],Ref Prefetch,On,Off;"` (default On), 2-FF synced into `clk_dec` and
  wired to `mpeg2video.ref_prefetch_en`.

**Why gating only the data fifo reproduces baseline:** with reads throttled at a shallow data
fill, the (always-deep) addr/dst fifos just hold a backlog of un-issued addresses; the
recon-feed latency-hiding equals the data-buffer depth. So `Off` faithfully emulates the
upstream shallow run-ahead while `On` enables deep prefetch — a valid A/B on one build.

**Verification (sim)** — `bench/dvd/ref_prefetch_tb.sv`:
- `ref_dta_gate` logic: baseline cap asserts exactly at fill 192 and releases below; deep mode
  follows native `prog_full` and ignores the baseline; coincident wr+rd is net-zero. ✅
- Deepened `framestore_reader` closed loop (addrgen→24-cycle memory latency→recon 1-row/2cyc):
  **DEEP buffers 971 rows** (deep run-ahead), **BASELINE caps at 204** (192 + in-flight), and
  **neither overflows or fills** the 1024-deep fifo — confirming the overflow-safety invariant
  with the maximum 32 in-flight reads. ✅
- Regression: `ps_chain_tb` real-VOB demux identical (50,395 bytes). ✅

**HW result (2026-06-30, `releases/DVD_refpf_20260630_1503.rbf`, depth 1024):** ✅ **MiB
high-motion stutter GONE in the problem area — Stage 1 validated.** Routed clean: **DSP 83/112
unchanged** (DSP-neutral confirmed), ALM 77 % (+72), RAM +17 M10K.

⚠️ **Blackout waves are the OUTPUT PATH, not the cable (corrected):** an earlier report that a
flaky HDMI cable fixed the 1-px shift + full blackout (incl. OSD/menu) was WRONG. Re-test shows
blackouts still occur on **all clips including NTSC MiB** (worse on high motion, in *waves*),
plus chroma fringing on all clips. Both are the **shared output path going marginal**,
activity-correlated — aggravated by this build's extra congestion (~25 M10K) + extra reference
bridge traffic under heavy motion. Independent of the O[18] toggle (the deep fifos are physically
present either way). **CONFIRMED Stage-1-caused (2026-06-30):** both pre-Stage-1 builds
(`DVD_reffeed`, `DVD_pal`) are blackout-free; only the depth-1024 `DVD_refpf` shows it ⇒ the
deep-fifo congestion is the cause. **FIX HW-CONFIRMED: reference depth 1024→512** (`DVD_refpf9`,
RAM 250→240 M10K): **blackouts gone, chroma fringing gone, and the MiB high-motion stutter
improvement retained** at 2× baseline run-ahead. This is the shipped Stage 1 configuration.

## PAL (BBB) stutter — DECODE-LOAD bound (root cause found 2026-06-30)

Fully diagnosed. The BBB-PAL "stutters throughout" is the **decoder missing the per-frame
deadline on heavy frames** → the governor repeats the late frame → judder. **Confirmed by
bitrate test:** re-encoding BBB-PAL to a lower bitrate makes it *nearly smooth* (only occasional
hitches on the hardest frames). It is NOT a timing/pacing bug.

Ruled out along the way (don't re-chase):
- **Not pulldown / film cadence:** `ffprobe` shows `repeat_pict=0`, `interlaced_frame=0`, native
  25.000 fps progressive — the §7.12 3× repeat logic in `resample_addrgen` never fires.
- **Not ascal 50→60 Hz conversion:** `vsync_adjust=1`/`2` and forcing 576p50 output changed
  nothing.
- **Not a 60 Hz-hardcoded constant:** the video path is PAL-aware (av_sync `refresh_50hz`,
  modeline walk, governor `refresh_cnt`, frame buffers `WIDTH_Y=18` fit 576). The governor even
  lands on the identical `FRAME` branch for NTSC-480p and PAL-576p.
- **Not cache-thrash:** BBB-PAL row 6 ≈ 12.5 % miss, *lower* than smooth BBB-NTSC's ~15 %.

**Why PAL and not NTSC at similar bitrate:** PAL's per-frame work is higher on both axes —
**bits/frame** 7.8 Mbit÷25 ≈ 312 Kbit vs NTSC ~234 Kbit (~30 % more DCT coefficients → more VLD
work), and **MBs/frame** 1620 vs 1350 (+20 %) — while the time budget is only +21 % (40 vs
33 ms). So heavy frames overrun. Note this makes it partly **VLD/coefficient-bound** (a bitrate
axis), not just the motion-comp "MB/s" axis.

**Fix = graceful frame-drop governor (IMPLEMENTED, `O[19] Frame Drop`, branch
`feature/frame-drop-governor`).** The standard DVD-player answer to a compute-bound decoder:
when it falls behind, **skip decoding a B-frame** (never a reference, so free to drop) to catch
up, instead of irregularly repeating frames. Trades a rare dropped frame for a steady cadence;
works whether the neck is VLD or motion-comp; it's control logic, not datapath surgery. Helps
all heavy content (high-bitrate NTSC too).

## Graceful frame-drop governor (`O[19]`) — implementation

Three small pieces, all in the single `clk_dec` domain (the VLD and the frame-rate governor
`resample_addrgen` share `mpeg2video.clk`, so **no CDC** is needed), gated behind
`O[19] Frame Drop` (default **Off** = exact baseline, for a clean HW A/B):

1. **"Behind" detection** — `dvd/resample_addrgen.v` gains a registered `frame_late` output:
   a 1-cycle pulse whenever the governor is forced to re-scan (repeat) the last displayed
   image because a new source frame was **due** (`refresh_cnt >= SHOW_N`) but the decoder had
   not produced one — a decode deadline miss. This is distinct from the normal within-`SHOW_N`
   persistence hold (`~frame_due`), which is *not* late. Threaded out through
   `rtl/mpeg2/resample.v`.

2. **Timeline-debt catch-up controller** — `dvd/frame_drop_ctl.sv` (new; sim-verified by
   `bench/dvd/frame_drop_ctl_tb.sv`). Accumulates lateness as a **debt counter in display
   refreshes**: each `frame_late` adds 1 (one refresh of slow-motion accrued); each B-frame
   dropped (`drop_ack`) subtracts `DROP_THRESHOLD` (= governor `SHOW_N` = 2, the refreshes a
   dropped frame reclaims); `drop_req` asserts while enabled and `debt ≥ DROP_THRESHOLD`.
   `debt` is guarded so it can never go negative and saturates at `DEBT_MAX`. Instantiated in
   `rtl/mpeg2/mpeg2video.v`.

   > **Why debt-in-refreshes, not "1 drop per late frame" (HW lesson, 2026-06-30).** The
   > display shows every frame for `SHOW_N` refreshes regardless of dropping, so a drop
   > reclaims `SHOW_N` refreshes of the *presentation timeline* — the remaining frames march
   > through the fixed-rate display faster. A drop is timeline-neutral only if it cancels an
   > equal amount of slow-motion already accrued by late repeats. The first version dropped one
   > B per `frame_late`, but each `frame_late` is only *one* refresh late while each drop
   > reclaims *two* — a 2× over-correction. On chronically-behind **BBB-PAL** the large decode
   > deficit hid it (it just restored ~real-time). On mostly-keeping-up **MiB (Matrix)** the
   > small per-hiccup over-drops **accumulated into a dramatic speed-up — and since `av_sync`
   > slaves the audio clock to the video STC (advanced per displayed refresh), the AUDIO sped
   > up with it.** Requiring `debt ≥ SHOW_N` before dropping (and never subtracting more than
   > the accrued debt) makes drops timeline-neutral: `debt` can't go negative → playback can
   > never overshoot into a speed-up. MiB's isolated 1-refresh hiccups stay below the threshold
   > and no longer drop; BBB-PAL's sustained deficit still crosses it. See
   > `dvd/frame_drop_ctl.sv` header for the full derivation.

3. **The drop itself (VLD)** — `rtl/mpeg2/vld.v`. When `drop_pic_req` is asserted and a
   **FRAME_PICTURE B**-frame header arrives (coding type read combinationally from
   `getbits[13:11]` before it registers), the VLD:
   - **suppresses that picture's `update_picture_buffers`** so motcomp/`motcomp_picbuf` never
     freeze the VLD for it, never rotate reference frames for it (a B never rotates refs
     anyway), and never set it up to be reconstructed or emitted — the dropped B is fully
     invisible downstream, and the I/P reorder chain (`prev_i_p_frame`) is untouched;
   - **skips its slices** by routing every slice start code straight to `STATE_NEXT_START_CODE`
     (a cheap byte-aligned start-code hunt) instead of `STATE_SLICE`, so the expensive
     VLC + IDCT + motion-comp work is never done. `drop_this_picture` latches the decision at
     the picture header and is re-armed at the next header.
   The governor simply repeats the previous frame in the dropped B's display slot.

   Only **frame-picture** B's are dropped (`picture_structure == FRAME_PICTURE`), so interlaced
   field-picture B's are left alone — matching the current PAL-progressive-only support.

**Safety invariant:** the decoder *only ever* drops B-frames, and the reference rotation +
I/P reorder logic change only on non-B `update_picture_buffers` events, which are never
suppressed. So a drop can never corrupt a reference or the picture — the worst case (with the
toggle **On**) is a display glitch/judder, never garbage. This is why it ships behind a
default-off O-bit for on-hardware A/B rather than gated on a full-decoder sim (no such sim
harness exists; the project validates decoder internals on HW via the overlay).

**Verification:** `frame_drop_ctl` sim ✅ (`bench/dvd/frame_drop_ctl_tb.sv`); the governor's
`frame_late` path compiles + `resample_persist` regression green; the full decoder elaborates
clean in iverilog; `ps_chain` real-VOB regression identical (50,395 bytes). **HW pending:** the
real test is BBB-PAL / high-motion NTSC with `O[19]` Off vs On — does the stutter give way to a
steadier cadence with only occasional dropped frames? The `dbg_frames_late` / `dbg_frames_dropped`
counters (from `frame_drop_ctl`, wired out of `mpeg2video`) confirm it is actually dropping;
surfacing them on the (full) debug overlay is a deferred follow-up.

**Open follow-ups / tuning knobs (for HW):**
- Picbuf reorder interaction is reasoned-correct (a dropped B = one fewer picbuf tick = one
  fewer emit, ref chain untouched) but only confirmable on HW — watch for any frame-ordering
  hiccup at drop boundaries when enabled.

## HW results (2026-07-01, `feature/frame-drop-reland`) + the debt-decay knob

The reland (now `O[12] Frame Drop`; overlay **row 14 = frames_late, row 15 = frames_dropped**
when it's on) was HW-tested across three builds:

| Build | Decay | PAL BBB | NTSC MiB/Matrix |
|---|---|---|---|
| `DVD_framedrop_…1739` | none | **smooth ✅** (drops ≈ ½ late rate) | over-drops ~1/7 on already-smooth clips ❌ |
| `DVD_framedrop_…1930` | full (−1 per clean) | stutters again, **row 15 = 0** ❌ | good ✅ |

Playback speed is CORRECT in both (the timeline-debt fix holds; the earlier "dramatic
speed-up" was a stale pre-fix build). A ~1 kbps re-encode shows zero lates/drops (mechanism
quiescent when the decoder keeps up).

**Refined mechanism (from the four HW data points + RTL reading):**
1. **NTSC film's row-14 lates are largely structural 3:2-cadence false alarms.** MiB/Matrix
   are soft-telecined: `repeat_first_field` gives frames alternating 2-refresh (33 ms) and
   3-refresh (50 ms) windows while the decoder produces uniformly at ~41.7 ms — the 33 ms
   deadlines miss structurally even when keeping up on average, and a 2-frame stretched to 3
   refreshes is invisible inside film's inherent pulldown judder. No-decay banked these false
   alarms into the needless ~1/7 drops.
2. **PAL's true fractional deficit SELF-PACES as isolated single holds** — each hold grants a
   full refresh of slack so the following frames release cleanly; holds recur every few
   frames and are clearly visible against PAL's perfectly regular 2-2-2 cadence. Full decay
   cancels each +1 with the following clean −1, so debt never reaches `DROP_THRESHOLD`=2 →
   row 15 = 0 → stutter returns. (This zero also *empirically disproves* depth-gating —
   "only count ≥2-consecutive holds" is behaviorally what full decay does.)
3. A real defect in the first decay build: `frame_ontime` fired only at
   `refresh_cnt == SHOW_N`, denying clean **3-refresh pulldown releases** their decay credit
   → film got only ~half its intended decay.

**A rate-limited debt-decay knob (`P1 O[4:3] Drop Decay: Off/1/4/1/2/Full`) was tried to
auto-separate the two — and HW-REMOVED.** The idea: decay 1 debt per N clean (un-held)
releases so debt tracks late-density vs clean-density; sim (`frame_drop_sys_tb` with a clean
PAL self-pacing model) showed 1/4 separating them (PAL drops, NTSC 0). **On real hardware it
over-dropped MiB at EVERY setting (Off/1/4/1/2/Full).** The densities overlap too much: NTSC
film's structural 3:2-cadence lates are frequent enough that any decay weak enough to still
drop PAL also lets NTSC accumulate to the drop threshold. A late-density discriminator can't
separate them on real content — my sim's synthetic PAL was too clean. The decay/`frame_ontime`
machinery was reverted (kept the congestion cuts).

**Final state: plain `O[12] Frame Drop` on/off (no-decay timeline-debt controller).** It's an
**opt-in PAL / heavy-content tool** — leave Off for NTSC (which decodes fine and would
otherwise over-drop ~1/7), turn On for PAL where it fixes the compute-bound stutter at correct
speed. The proper path to "safe to leave always on" is the **film-3:2 governor cadence work**
(roadmap): make the governor honour `repeat_first_field` so soft-telecined frames don't
register as late in the first place — killing NTSC's false lates at the SOURCE rather than
trying to filter them downstream in the debt controller.

### ✅ Film-3:2 governor cadence fix (2026-07-02, `feature/film-32-governor-cadence`) — SIM-VERIFIED

**v1 (frame_late-only) was inert on HW — the real root cause was the display PACING.** HW showed
NTSC film still dropping at the same rate AND **playing ~30 fps instead of 24** (sped up ~25 %).
That speed-up is the key: the governor was **not giving film frames their 3-refresh windows at
all**, so (a) 24 fps film ran fast, and (b) the v1 slack-banking never triggered (it only banks
when a frame occupies *more* than `SHOW_N` refreshes, which these never did).

**Root cause (v2 was ALSO inert on HW — the display branch matters):** our default 480p output
runs the decoder with **`deinterlace=1, interlaced=0`** (regfile default; emu.sv), and DVDs are
coded **interlaced (`progressive_sequence=0`)** with film on `progressive_frame` +
`repeat_first_field`. That combination takes the **`deinterlace && ~interlaced`** image-build
branch, which emits a single `FRAME` image and **ignores `rff` entirely** — so every frame showed
2 refreshes (30 fps) regardless of pulldown. v2 gated `show_next` on `progressive_sequence` (=0
for DVD), so it never fired — and the v2 testbench used `progressive_sequence=1`, the wrong
branch, so it passed while HW didn't. (Upstream only honoured `rff` on the progressive_sequence /
interlaced-output branches, and there gated the 3rd refresh on `rff && top_field_first` — `tff`
is a field-order flag, irrelevant for progressive frame display.)

**Fix — cadence-aware pacing (`cur_show`)**, replacing the fixed `SHOW_N` deadline:
- `show_next = (~interlaced && repeat_first_field) ? 3 : SHOW_N` — on ANY progressive-display
  path (incl. the deinterlace branch), an `rff` frame is held one extra refresh. Latched per
  frame into `cur_show` at pickup. `frame_due = refresh_cnt >= cur_show`. The tb now uses the
  real HW config (`deinterlace=1, interlaced=0, progressive_sequence=0`) and fails with the old
  condition, passes with the new — so it actually exercises the shipped path.
- An `rff` frame is now held for **3 refreshes** (the extra one via the existing persistence
  re-scan path — independent of the image-build, so **both `tff` cases display identically**).
  → 3,2,3,2 = 2.5 avg = 60/24 = **correct 24 fps**. Only the progressive-display path changes;
  interlaced/field modes stay at `SHOW_N` (no regression to the HW-confirmed 480i path).
- **`film_slack`** (saturating, cap 4): the `rff` frame banks `cur_gain = cur_show − SHOW_N` = 1
  credit at its release; the following short frame's structural miss **spends** it, so
  `frame_late` fires **only when `film_slack == 0`**. Persistence holds bank nothing (`cur_gain`
  is per-frame, not derived from `refresh_cnt`), so a genuine stall still flags late.

Why this now works where v1 didn't: the pacing fix both **corrects film speed to 24 fps** and
**creates the real 3-refresh window that banks the slack** which absorbs the following short
frame's structural miss. PAL 25 fps / high-motion NTSC carry no pulldown → `cur_show` stays
`SHOW_N` → never bank → every real late still fires → **frame-drop unchanged** for the cases
that need it. Unconditional (only improves governor cadence + `frame_late` quality; the latter
is ignored unless `O[12]` is on).

Sim: `bench/dvd/resample_cadence_tb.sv` — an `rff` (`tff=0`) frame is held **3 refreshes**, its
structural miss is SUPPRESSED, and a PAL frame's real miss FIRES — PASS. `frame_drop_ctl_tb`
green; `resample_chain_tb` byte-identical to main (default and `+rff=1`/`+tff=1`). **HW test:
NTSC soft-telecined film (MiB/Matrix) should now play at correct 24 fps (no speed-up); with
`O[12]` On, overlay row15 (frames_dropped) should stay ~0 where it climbed ~1/7. PAL BBB still
drops + smooths. If confirmed, `O[12]` becomes a candidate for default-On.**

## Stage 2 — recon rewrite: SHELVED (investigated, not worth it)

The original plan ("collapse the `STATE_WAIT`/`STATE_RUN` ping-pong so recon does 1 row/cycle")
is **insufficient**, and the deeper fix isn't worth it — both established by reading the code:

- **The recon 2-cycle cadence is matched to the 64-bit reference data width, not FSM overhead.**
  Each reconstructed row is 8 output pixels but needs **16 input reference pixels** (horizontal
  half-pel); the fwd/bwd reference data fifo is **64-bit single-port** (`read_write.v`
  `reader_dta_fifo`, 1 word/cycle) and `fwft2_reader` needs **2 words/row**. So a motion-comp row
  can only arrive every 2 cycles. The recon datapath is already a feed-forward pipeline — a pure
  FSM rewrite would just stall on that fifo. **Zero gain for motion-comp blocks.**
- **The real lever (128-bit reference data path) is bounded and not worth the risk.** To deliver
  a full row/cycle you must serve reference reads 128-bit from the **cache** (`mem_shim_burst`,
  re-laid 128-bit-wide) — f2sdram itself is 64-bit @ 90 MHz (board ceiling), so only cache hits
  can go faster. And the col0/col1 word address is arbitrary parity → a naive 128-bit array only
  serves ~50 % (`A` even) in one cycle; the aligned-any-`A` fix needs a 2-bank interleaved cache
  with a cache-line-boundary fallback (~1/8 of rows span two lines). Net best case ≈ 1.3–1.6×
  recon on the hit fraction — a large, high-risk rework of the load-bearing cache for a sub-2×
  gain that likely still wouldn't fix BBB-PAL. **Shelved.**

Moot anyway: BBB-PAL is a **PAL display-path problem, not a recon/throughput one** (see the PAL
stutter section). Chase that, not recon.

## Resource note (the original DSP-headroom question)

Both stages are **DSP-neutral**. Jun 30 PAL build free budget: ~9,558 ALMs (23 %), 29 DSP
(26 %), 320 M10K (58 %). Stage 1 spends M10K only; Stage 2 spends ALMs. The gating risk is
routing/timing closure at high ALM occupancy, not DSP or LUT exhaustion. Validate empirically
(does it play smoothly?), not by chasing TimeQuest to zero on the infra paths.

### ⚠️ film_slack REMOVED (2026-07-02) — it masked real lates and starved audio

HW diagnosis of the "NTSC film audio drops out constantly" symptom (ring parks at 0; rows
13/14/15 all 0; genlock/track/action-independent; PAL fine with O[12] on): every component
was individually exonerated by measurement — governor cadence sim-exact (2.500
refreshes/frame on the real alternating-rff pattern, `resample_cadence_rate_tb`), `ps_demux`
audio yield **byte-perfect vs ffmpeg over 8 MB of the real VOB** (633,024/633,024,
`ps_demux_yield_tb`), reframer+ring byte-exact under stalls (`aud_backpressure_tb`), zero
decoder resets. By elimination: on compute-marginal film clips (Matrix/MiB) the decoder
misses exactly the SHORT (33 ms) 3:2 windows; `film_slack` forgave one miss per pulldown
frame — precisely the miss pattern — so the cadence silently collapsed to 3,3,3,3 ≈ 20 fps.
Video *looked* smooth (uniform holds), `frame_late` never fired (rows 14/15 = 0), O[12]
never saw the lates so it couldn't catch the timeline up, and the shared-stream audio
delivery ran ~17 % slow → constant ring-underrun dropouts.

**Resolution: `film_slack` is obsolete and removed.** It was designed to forgive the
*structural* false lates of the old flat `SHOW_N=2` deadline — but `cur_show` per-frame
pacing made every deadline the TRUE display duration, so any miss is a REAL miss and must
reach the frame-drop governor. With O[12] on, heavy NTSC film now behaves exactly like PAL:
a late fires, a B-frame drops, the timeline holds, audio stays fed. (PTS-scheduled
presentation — "play each stream by its timestamp" — governs *phase* only; when the video
decoder underruns real time, frame dropping is the only mechanism that preserves the shared
timeline. The two compose; hiding lates broke that composition.)
