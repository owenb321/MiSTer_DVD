# Lip-sync residuals — next-session pickup

## ⚡ START HERE (2026-07-04, rounds 7+8 — read BOTH: round 7 kills the reader
## artifact; round 8 below it has the MEASURED verdict + the round-9 work order)

**The "frame_late ×3" bug DOES NOT EXIST. Do not touch `resample_addrgen`'s
STATE_REPEAT path for it.** Round 6's numbers came from a mis-calibrated
`tools/osd_read.py` decode: the drift5c calibration used affine `sx=2.0`
against a true full-width capture scale of `2.667` (1920/720), so the reader's
16 probe columns walked a 3:4 pitch against the real cell lattice — displayed
bit k actually sampled true bit `k − ⌊k/4⌋` (true bits 3/6/9 read twice, bits
13–15 never read). On a binary counter that transform *looks like* a counter
whose nibbles carry twice per 16 — every counter row read a value-position-
dependent 4×–13× multiple of its true rate. Row 3 (the 59.94 Hz frame counter)
read 414/s; the "54 lates/s vs 18 real" ratio was pure artifact. The old
row-3 validation passed because it required only a MAJORITY of +1 deltas and
the low nibble still counts +1 (fixed: strict all-deltas + a measured-pitch
autocorrelation gate + a selftest alias trap; the fix re-calibrated and
re-decoded the same recording — `rec5.mkv` → `drift5d` — cleanly).
drift4b/drift5b (rounds 4–5) were decoded with *different* wrong grids (row 3
reads 364/s and 246/s): **every numeric conclusion from osd_read rounds 4–6
is void unless re-derived**; the qualitative audio exoneration SURVIVES the
clean re-decode (see below).

**TRUE drift5 telemetry (drift5d capture, MiB through the Shea/Unisphere crash):**

| window | lates/s | drops/s | lates/drops | vid_err slope |
|---|---|---|---|---|
| pre-crash [8–55 s] | 4.17 | 2.04 | 2.04 | −0.04 refr/s (flat) |
| post-crash [66–172 s] | 4.08 | 1.37 | 2.98 | **+1.26 refr/s** |

- `play_err` = **−496.7 ms constant to the LSB all run** (= the −500 A/V
  Offset); row 18 frozen at {0,0,34 load skips}; stc_excess +2 flat. The audio
  chain exoneration is CONFIRMED on clean data.
- The late rate barely changes across the crash — the governor's deadline miss
  detection is honest (also verified by RTL analysis: STATE_REPEAT is visited
  exactly once per image scan; one registered 1-clk pulse per late re-scan;
  same clock domain as frame_drop_ctl, clk_en=1 throughout).
- **The real post-crash phenomenon is a VBUF-starvation ratchet**: VBUF (row
  10 hi) drains monotonically 134→25 units (≈1 MB→200 KB) through pre-crash
  play, hits bottom (3–6 units ≈ 24–48 KB, right at the vbuf_healthy 4/8
  hysteresis) at the crush, and NEVER recovers; `vid_err` is flat until the
  moment VBUF bottoms (t≈62 s), then climbs linearly ≈ +1.26 refr/s (≈21 ms/s,
  ~2% slow-motion) forever. Mechanism: with zero bitstream cushion every
  delivery hiccup becomes a governor repeat = a PERMANENT one-refresh timeline
  slip (starvation lates are correctly excluded from drop-debt by the
  bitstream_ok guard — dropping while starved burns bytes); the audio ring sits
  pinned at almost_full (row 10 lo ≈ 203) so the STD backpressure holds the
  demux to exactly audio real-time and the stream can never run ahead to
  rebuild the cushion. The cushion geometry: max VBUF backlog ≈ ring window ×
  video bitrate ≈ 1.37 s × 5.5 Mb/s ≈ 940 KB ≈ the 134 units the clip started
  with. Once burned, permanently gone.

### ★ ROUND 8 (2026-07-04, same day): LIPS MEASURED FROM THE RECORDING — the engine
is a FRAME-DROP DEBIT LEAK (`drop_pic_rff` reads 0), not starvation per se

User answered the round-7 question: **audio is ~900 ms BEHIND video** (lips
move, speech follows). Then the recording itself was measured against the
source VOB (both on disk — no HW round needed):

- **Audio content position** (envelope cross-correlation, rec5 audio vs the
  VOB's 0x80 AC-3): offset **constant −3.53 s at wall 60/70/160 s** — audio
  never moved. The audio chain exoneration is now DIRECT (content-level).
- **Video content position** (per-frame template matching into the VOB, every
  4–6 s): a **RAMP** — offset climbs ~+3.3 % of real time from t=30 (already
  ramping at the start of play) to t≈62–66, gaining ~+1.2 s, **then freezes
  to the millisecond** (−0.951 s constant from t=80 to t=168). The freeze
  moment = exactly when VBUF bottoms out (row 10). So: video runs ~3 % FAST
  while the VBUF cushion funds it (the 134→0 unit drain IS the funding, rates
  match: drain ≈ 3.2 % of video bitrate); when the cushion exhausts at the
  first heavy scene (Shea), video clamps to delivery rate and the accumulated
  lead becomes the permanent audio-behind step. The "crash" is just where the
  cushion dies.
- **Cadence run-lengths in the recording** (60 fps capture = raster-exact):
  true 3:2 alternation plus the measured ~4/s late-repeats — the governor's
  per-frame PACING is honest. Scan-vs-raster free-run is also ruled out
  (resample_chain_tb SCANRATE instrument: ratio 1.000 baseline AND starved;
  plus static FSM analysis — the mixer's frame-top parking re-locks scans to
  the raster every frame).
- **The imbalance that remains**: drops run at 2.04/s injecting each dropped
  frame's TRUE duration of content (~2.5–3 refr, the droppable-B population
  is rff-mixed), while the banked lates reclaim only ~2.04 refr/drop — the
  measured lates/drops ratio says the debt controller paid **debit 2 on
  essentially every drop**. Neutrality requires the debit = the dropped
  frame's OWN duration (3 for rff): **`drop_pic_rff` is reading 0 on HW**, so
  the round-4 film-aware debit (`61b230c`) is inert and every dropped rff B
  leaks +1 unreclaimed refresh ≈ +2 refr/s ≈ the measured +3.3 %.
  (Same leak also explains post-crash vid_err +1.26/s: content credit 2/drop
  while true ≈ 3: 4.08 − 2×1.37 = +1.34 ✓.)
- Also ruled out this round: VOB PTS discontinuities (full-file scan: video
  and 0x8x audio PTS are continuous; the +0.5 s video PES spacing is GOP
  cadence, the 0x2x "jumps" are subpicture streams), STC re-anchor (row 16
  flat), watchdog resets (rows 14/15 monotonic).

### ROUND 9 (2026-07-04, same session): RTL drop path SIM-EXONERATED — HW
discriminator shipped (row 16 = drop-debit split), build DVD_drift6

- **`bench/dvd/vld_drop_rff_tb.sv`** (new): the REAL `vld` + `getbits_fifo`
  over a real 6 s MiB ES extract (147 coded pictures; ground truth from an
  independent Python bitstream parse: B population exactly 49/49 rff — so a
  faithful debit would average 2.5, the measured 2.04 can't be selection
  noise). With `drop_pic_req` held high, **43/43 dropped B's acked with
  `drop_pic_rff` exactly equal to the dropped picture's own flag, both
  phases, zero ground-truth mismatches.** The RTL export/debit path is clean;
  the req-level timing can't corrupt it either (the decision samples req only
  at the picture header; the ack latches rff after this picture's extension).
- Also closed: the reader's row-4 flag decode bug (green test gated on
  luma>60; captured green is (3,141,6)=luma 50 — now keys on the green
  channel). Re-decode of rec5 t=5–80 s: flags = {sa,hd,ack} steady, **no
  vld_err, no watchdog, ever** — decoder error-skips ruled out as the
  content-jump mechanism (consistent with round 8's ramp-not-step).
- **Shipped: overlay row 16 REPURPOSED** (stc_excess is exonerated & retired)
  = `{drop acks debited 3 [15:8], debited 2 [7:0]}` — counts the exact
  expression frame_drop_ctl's `drop_cost` sees, at the same ack pulse
  (`mpeg2video.dbg_drop_costs`). One HW read on MiB (Frame Drop On) decides:
  * both bytes climb ~50/50 → debit healthy on HW → round-8's inference has
    a hole (re-derive: then the +3.3% needs a different engine);
  * cost2-only while drops fire → the film-aware debit is inert in the BUILD
    (physical synthesis is on; same class as the historical synth-narrowed
    disp_y compare) → fix = harden the RTL formulation (e.g. register the
    cost at the ack, export the registered value) and/or a build A/B;
  * rff-phase-locked selection would ALSO show cost2-only — distinguished by
    round 8's algebra (true dropped duration ≈ 3.02 ⇒ the dropped frames ARE
    rff; selection lock is excluded by the same measurement).
- **HW round (rbf DVD_drift6):** play MiB from load through the Shea crash,
  record; read rows 16 (debit split), 14/15 (lates/drops), 10 (VBUF), 20
  (vid_err) via osd_read; VLC/ear check lips at 1 min and at the tail.
  Expected if the leak is confirmed: row 16 ≈ {0, N}. Then fix the debit and
  re-test — prediction: VBUF stops draining, no audio-behind step at the
  heavy scene, lates/drops ratio rises to ~2.5–3.

### ★ ROUND 10 (2026-07-04, drift6a capture): LEAK CONFIRMED ON THE DIRECT
INSTRUMENT — hardened export shipped (DVD_drift7)

The DVD_drift6 read (`drift6a`): row 16 reached only **{16, 224} — 6.7 %
of drops debited 3** against a 49/49-rff droppable population, and the
cost-3 counter **froze entirely post-crash** while cost-2 kept climbing. The
timeline cross-check pins it: post-crash, lates (3.9/s) vs drops (1.3/s)
with the video offset frozen (round-8 template measurement) forces the
dropped frames' TRUE durations to ≈3.04 — they ARE rff — while the debit
instrument says every one was paid 2. Same regime otherwise (VBUF 80→~5 by
t≈60; vid_err flat then +1.35/s; play_err −496.5 ms constant; flags clean).

**Verdict: `drop_pic_rff` reads 0 for genuinely-rff pictures on hardware
(~90 % pre-crash, 100 % post-crash) while the identical RTL is 43/43
faithful in simulation ⇒ the BUILD mangles the path.** The shared
`repeat_first_field` loadreg fans out to picbuf/resample (where it provably
works — the 3:2 cadence is HW-confirmed) and physical synthesis is enabled:
a retimed/duplicated private copy feeding the export is the same failure
class as the synth-narrowed `disp_y==0` compare (docs/history.md).

**Fix (round 10, rbf DVD_drift7):** `vld.v` now captures the rff bit into a
dedicated `(* preserve *)` register (`drop_rff_lat`, sampling the SAME
`getbits[13]` at STATE_PICTURE_CODING_EXT0 the loadreg samples) that is
private to the drop path — the fitter may not retime/merge/duplicate it —
and the ack exports that. Sim-verified equivalent (vld_drop_rff_tb 33/33
faithful).

**Next HW round (DVD_drift7, the make-or-break read):** same MiB flow,
−500 offset, Frame Drop On. PREDICTIONS if fixed: row 16 climbs ~50/50;
lates/drops ratio ≈ 2.5–3 from the start; **VBUF (row 10 hi) stops its
monotone drain** (parks at the mux-lead constant); NO audio-behind step at
the Shea sequence — lips hold at the knob offset all run. If row 16 is
STILL cost2-heavy: the preserve didn't take (check the fitter report for
the register; escalate to `(* keep *)` wires / a syn_keep LCELL or move the
cost computation entirely into a registered export inside vld).

### ★★ ROUND 11 (2026-07-04, drift7a capture): drift7 IDENTICAL to drift6 ⇒ ROW 16
IS TRUTHFUL — and that exposed the REAL root cause: STALE DISPLAY FLAGS

DVD_drift7 (preserve-hardened export) read bit-for-bit like drift6 (row 16
again {16,224}; same VBUF drain; same vid_err slope; user: −900 ms persists).
Two different netlists behaving identically = deterministic = **the export was
never broken — the drops genuinely select ~90 % own-rff=0 B-frames** (cadence-
phase-locked selection: debt crosses threshold at fixed cadence phases, the
parse front sits a fixed queue-depth ahead). So debit 2 is correct per-frame…
which reopened "where does the +3.3 % come from" — and the answer was hiding
in the one flag consumer nobody had audited:

**`motcomp_picbuf` captures the per-picture display flags at
`update_picture_buffers`, which the VLD fires at the picture HEADER — but
`repeat_first_field`/`top_field_first`/`progressive_frame` parse ~10 states
later in the picture CODING EXTENSION. The VLD then freezes at the header
until picbuf processes the update (the mvec-fifo interlock), so the flags
picbuf saves are ALWAYS the PREVIOUS coded picture's.** Consequences:
- On clean 3:2 film the display-order flag sequence is merely phase-shifted —
  still alternating 3,2 — so the cadence looked perfect through every HW
  round (film-3:2 was "confirmed"); the per-frame ±1 refresh error is
  zero-mean. INVISIBLE.
- FRAME DROPS break the pairing: the drop debit reclaims the dropped
  frame's OWN duration (the ack path samples post-extension — ironically the
  only fresh consumer), while the display timeline actually freed the STALE
  (predecessor's) duration. With the observed rff0-locked drop selection
  (predecessor flag = 1), each drop leaks ~+1 refresh of video lead.
  Behavioral sim of exactly this bookkeeping reproduces lates/drops = 2.00
  and video-ahead at ~+0.7 refr per drop — the measured +3.3 % ramp, the
  VBUF burn, and the frozen ~0.9 s audio-behind lead after exhaustion.

**Fix (round 11, rbf DVD_drift8): `flags_commit`.** The VLD pulses a new
signal when THIS picture's coding extension has parsed (never for a dropped
picture — its extension parses too but it owns no picbuf slot); it threads
vld → mpeg2video → motcomp → motcomp_addrgen → motcomp_picbuf as a DIRECT
wire (ordering guaranteed by the header freeze: STATE_UPDATE for picture N
strictly precedes the VLD reaching N's extension), and picbuf RE-LATCHES the
three per-picture flags into the current slot. Emission reads them at the
NEXT picture's update — long after the commit.

**Sim-verified** (extended `vld_drop_rff_tb`, now with the REAL
motcomp_picbuf + the motcomp freeze interlock + a resample-style pickup
stub): no-drop run = 33/33 emissions carry their OWN picture's rff
(display-order ground truth); all-B-dropped run = 14/14 anchor emissions
correct + 30/30 acks correct. (TB note: the pickup stub must issue a clean
1-cycle `output_frame_rd` pulse — a toggling rd bounces picbuf's WAIT_1
handshake and double-logs emissions.)

**DVD_drift8 predictions (MiB, Frame Drop On, −500):** VBUF (row 10 hi)
stops the monotone drain and parks; vid_err (row 20) stays flat through and
after the crash; row 16 STAYS rff0-heavy (that's the honest drop-selection
phase — now harmless); lates/drops stays ≈2 (correct debit for rff0 drops);
**no audio-behind step at Shea — lips hold at the knob offset all run.**
The 3:2 cadence should also be marginally SMOOTHER (each frame now holds
its own true duration instead of its predecessor's).

### ✅ ROUND 12 (2026-07-04, drift9b capture): HW-CONFIRMED — THE DRIFT SAGA IS
CLOSED

DVD_drift8, MiB, Frame Drop On, 7.5-minute run through the Shea crash.
Every prediction landed (user: "delay is now constant throughout"):
- **vid_err FLAT the whole run**: ±3 refr around zero, slope −0.02/s both
  pre- and post-crash (was +1.26/s post-crash on drift5/6/7).
- **VBUF PARKED**: hovers 52–148 fill units (~0.5–1.2 MB) for 450 s; it even
  RISES through the crash window (76→116 at t=60). The cushion survives
  heavy scenes; the starvation guard has real margin again.
- **lates/drops = 2.03–2.05 constant** (the correct debit for the
  rff0-phase-locked drops); row 16 rff0-heavy as expected (cost2 counter
  saturates at 0xFF — it's an 8-bit saturating diagnostic).
- **play_err +157.0 ms constant to the LSB for 450 s.**
- **THE START "CONSTANT" FLIPPED AND SHRANK**: the run was recorded at
  A/V Offset **+100 ms** (audio was now slightly AHEAD at −500 and even at
  0) — i.e. the old "−500 ms start constant" was mostly the stale-flag RAMP
  eating ~400 ms of lead within the first minute, misread as a start offset.
  The true residual start error is ~−100 ms (audio early) — small, knob'd.

**Remaining follow-ups (all small, none blocking):**
1. ✅ SHIPPED (`feature/lipsync-followups`): the **A/V Offset default is now
   +100 ms** (index 0, the NTSC-film residual null), the menu rebalanced around
   ±200 ms (+100/-200/-100/-50/0/+50/+150/+200; the -300/-400/-500 entries that
   chased the now-fixed ramp are dropped). Still verify Matrix + PAL before
   treating +100 as universal (mux depth varies per disc).
2. ✅ SHIPPED (`feature/lipsync-followups`): overlay cleanup — rows 14/15 back
   to the AC-3 reset view (14 ERR, 15 TOTAL; no O[12] mux); drift instrument
   rows retired (13-hi armed-time, 17 play_err, 18 gate_events, 19 start_hold,
   20 vid_err; overlay NROW 21→17); row 16 {drop3, drop2} kept until a
   Matrix/PAL pass; `stc_excess` emu logic dropped; osd_read ROW_LABELS updated.
3. Secondary curiosity (not a bug): ~4 lates/s + 2 drops/s churn on healthy
   film — the reclaim loop handles it correctly now, but the decoder missing
   ~17 % of deadlines on easy content with a full VBUF may still hide a
   small compute/pacing inefficiency.
- Still open behind this: WHY 4 lates/s + 2 drops/s churn on healthy film at
  all (secondary for A/V sync — with a correct debit the churn is
  timeline-neutral — but **NOT cosmetic elsewhere**: each late is an ODD +1
  refresh, which flips the analog re-interlacer's field-pairing parity, so this
  churn is exactly what destroys CRT field pairing ~4x/s. See
  `docs/analog_dual_raster.md` caveat 2; it is why that path needed field
  passthrough rather than phase alignment.); the
  ~500 ms START constant (row 19 = {1F 14} says the STD hold defers ⇒
  constant downstream); overlay cleanup debt (restore rows 14/15 AC-3 view,
  prune instrument rows, set shipping default A/V Offset). The round-7
  ring-enlargement candidate is PARKED (a neutral loop stops draining the
  cushion; re-evaluate only if the fixed debit still starves).

**Measurement recipes (reusable, all local):** audio content offset = envelope
xcorr of recording audio vs `ffmpeg -map`-extracted VOB substream; video
content offset = grayscale template match of recording frames (crop the
non-OSD region) into a decoded VOB window; cadence = run-lengths of frame
diffs on the 60 fps capture. See PR fj#62 discussion / session notes.

**Tools:** `tools/osd_read.py` decodes the debug overlay from capture
recordings into CSV telemetry — after the 2026-07-04 fix, `calibrate` rejects
pitch aliases (measured-pitch gate + strict row-3 validation; `selftest`
includes the alias trap). Re-calibrate once per capture setup and re-run `csv`
on any recording whose numbers matter. Overlay row map (post-PR#62 cleanup,
`feature/lipsync-followups`, NROW=17): 10 {VBUF|ring}, 11 {lates/s|drops/s},
12 aud_frames, 13 ring_ovfl, 14 AC-3 ERR resets, 15 AC-3 TOTAL resets, 16
{drop3|drop2} debit split. The drift instrument rows (17-20) and the O[12]
row-14/15 mux are RETIRED (the drift saga is closed). Clean reference decode:
`drift5d` (capture not retained; note it predated the row-map change, so its rows
14-20 carry the old drift-instrument view).

The sections below are the earlier measurement rounds in order. **Numeric
claims in rounds 4–6 are UNRELIABLE (broken reader decode)**; the qualitative
mechanisms (treadmill fix, arrival-gated catch-up, drop-cost fix) still stand
on their sim testbenches and audible behavior changes. Read "WHERE THIS
STANDS" in `docs/av_sync.md` for the broader A/V-sync state.

## State at handoff

- PR fj#60 (branch `feature/lipsync-lead-vbuf`) is MERGED: the whole scheduling
  machinery (STC screen-referencing, drain gate at the PCM exit, stale-skip,
  pre-anchor dispatch hold, STD mux-lead hold, film-aware drop reclaim, A/V Offset
  knob O[23:21] ±500 ms @18-bit, VBUF 2 MB, absolute vbuf_healthy) is on main.
- HW behavior on `DVD_avlead13` (= merged main + row-14 reset counter):
  NTSC film plays with audio trailing by a **~500 ms START constant** (nulled at
  `A/V Offset = −500`) plus a **RATE DRIFT** of ~8 ms/s (MiB, 192 kb/s audio) /
  ~4 ms/s (Matrix, ~384 kb/s audio) — video pulls ahead. PAL is clean.
- **2026-07-03 (`feature/lipsync-drift`):** the DVD_avlead13 readings came in and
  EXONERATED the AC-3 reset suspect (see §1 below — the whole section is
  rewritten around the verdict). The drift-instrument overlay rows (16/17/18 +
  row 13 high byte) shipped on this branch; the next HW round runs §1's read
  protocol.

## The two open problems

### 1. RATE DRIFT (attack first)

**★ VERDICT READ TAKEN 2026-07-03 (DVD_avlead13, MiB, O12 Off): the AC-3
self-heal reset theory is DEAD.** Row 14 low byte (`dbg_ac3_resets` — counts
BOTH err-caused and stall-watchdog resets, so this is a genuine exoneration)
read **0 after load and 0 at ~2 min**, while row 15 confirmed the drift on the
meter: +0x0300 (+137 ms) at load → ~0xF800 (−365 ms) at ~2 min ≈ **−4.2 ms/s,
smooth, "hovering" at the end, no snap-backs**. Row 13 overflow 0 throughout
(note: the STD backpressure makes overflow 0 BY DESIGN — it says nothing about
ring comfort). Do NOT touch the stall watchdog / FIFO-preserve fix direction;
it was aimed at a mechanism that is not firing.

**What static analysis then pins (2026-07-03, feature/lipsync-drift):**
- Playback consumes exactly one sample per 48 kHz NCO tick (`dec_nco_trim` is
  hard-wired 0), and any tick that finds the PCM FIFO empty re-arms the drain
  gate (`pcm_out` drops `aud_valid` on empty) — playback cannot silently
  stretch.
- The NTSC progressive raster is exactly 858×525 @ 27 MHz = 59.9401 Hz = the
  STC's TICKS_PER_REFRESH assumption; `core_v_sync` is same-domain
  (`dot_clk = clk_sys`, emu.sv:1052), so the refresh edge detect is glitch-free.
  (The 480i modeline is 262 lines/field = 60.055 Hz ≈ +0.19% — a real error but
  wrong size, and film plays progressive.)
- The reframer's PES→frame PTS carry has bounded (one-frame) error; it cannot
  accumulate.
- BUT the drift meter is `dispatch_pts − STC`, and dispatch sits only ~213 ms of
  decode-side FIFO (AC-3 4 KB + PCM 2K pairs) ahead of playback. **A 502 ms
  meter swing is impossible with playback phase-locked to the STC** — so either
  playback got RE-PHASED late by gate events, or the STC runs fast vs wall.

**The two hypotheses the instrument round separates:**
1. **Arrival-limited re-phase loop** (leading): the decoder runs net-slow on
   MiB (compute-marginal film; the meter run had Frame Drop OFF) → VBUF fills
   and backpressures the shared demux → audio ARRIVES slower than 48 kHz
   consumes → the audio pipe drains (~1.6 s deep at 192 kb/s: ring 32 KB
   ≈ 1.37 s + AC-3 4 KB + PCM) → underrun → re-arm → stale-skip discards
   everything (all arrivals now > 50 ms late) → `play_pts` never latches →
   **2.5 s fallback release parks playback D-late**, where D = accumulated
   video lateness. Predicts: row 18 re-arm/fallback/discard counters climb,
   row 13 armed-time steps ~150 refreshes per event, row 17 `play_err` steps
   late at each event, row 10 low byte (ring fill) sags, row 11 lates > 0,
   row 16 ≈ 0. Also predicts the drift largely disappears with Frame Drop ON.
   Note the inverse-bitrate signature re-reads naturally here: the pipe depth
   in SECONDS is ∝ 1/bitrate (the drift-rate-∝-1/bitrate claim rests on
   eyeball lip estimates; treat it as unconfirmed).
2. **STC fast vs wall clock**: predicts row 16 `stc_excess` climbing at the
   drift rate (~24 units/s at 4.2 ms/s) with rows 13/17/18 quiet and ring
   pinned near full. No known mechanism survives static analysis, but the
   meter says one of the "exact" legs is wrong — this row is the direct test.

**The instruments (this branch — overlay rows 13/16/17/18, all OUTSIDE the
O[12] row-14/15 view mux so a Frame Drop A/B keeps every read live):**
- row 16 = `stc_excess[19:4]` (signed, 178 µs/unit; + = STC fast vs a true
  27 MHz/300 = 90 kHz wall counter started at `video_live`)
- row 17 = `play_err[19:4]` (signed, 178 µs/unit; + = playback late vs STC;
  starts ≈ av_ofs at each release — the SLOPE/steps are the read)
- row 18 = {underrun re-arms[15:12], fallback releases[11:8], stale-skip
  discards[7:0]} (saturating)
- row 13 = {armed-time after first release, 16.7 ms units[15:8], ring
  overflow[7:0]}

**Read protocol (MiB, Debug Overlay On, A/V Offset 0):**
1. O12 **Off**, note at 0 / 1 / 2 / 4 min: rows 15 (drift), 16, 17, 18,
   13 high byte, 10 (VBUF|ring fill), 11 (lates|drops).
2. Same with O12 **On** (rows 14/15 switch to lates/drops; 13/16/17/18/10/11
   stay live). Hypothesis 1 predicts the drift slope shrinks or vanishes.
3. One pass on Matrix (O12 Off) for the cross-disc rate ratio — hypothesis 2
   predicts both discs drift at the SAME meter rate.

**Decision table:** row 16 climbs → chase the STC leg (raster/TPR/tick — and
re-verify with a stopwatch that HDMI vsync is really 59.94). Row 18/13/17
active with row 16 flat → the re-phase loop is real; the fix is delivery-side
(keep the decoder at pace / catch-up policy), NOT the audio chain. Everything
flat while row 15 still decays → the meter itself lies; next probe is the
dispatch/PTS values.

### ★ VERDICT of the instrument round (2026-07-03, DVD_drift1 readings) + FIX

The user ran the full protocol (MiB O12 On, MiB O12 Off, Matrix O12 Off; each
at 0/1/2/4 min). Outcome:

- **Row 16 (stc_excess) flat ≈0 in EVERY run** (worst +82 units transient,
  back to −3) → **the STC leg is exonerated for good.**
- **The healthy run (MiB O12 Off) shows NO real rate drift:** row 17
  (play_err) sat at +0x70..0x72 ≈ **+20 ms CONSTANT** for 4 minutes; row 18
  froze at {1 rearm, 0 fbrel, 17 skips} after the load transient; ring fill
  steady ~0xCC. Row 15's slow positive growth (+0.7 → +64 ms) minus flat
  play_err = decode-FIFO fill creeping — cosmetic. In this regime lip-sync is
  ~solved.
- **The perceived "rate drift" is a COLLAPSE MODE** that two runs latched
  (MiB O12 **On** from load; Matrix O12 Off from ~1 min): ring pinned EMPTY,
  VBUF pinned FULL, armed-time saturated (FF), rearm/fbrel/skip racing to
  saturation (Matrix logged 12 fallback releases), drift bouncing to −1.4 s.
  Mechanism (the discard treadmill): delivery falls behind real time → every
  arriving frame is >50 ms stale → the ARMED stale-skip discards audio as
  fast as it arrives (that's why the ring reads empty) → `play_pts` never
  latches → the 2.5 s fallback releases into a thin pipe → underrun → re-arm
  → repeat. The discarding also removes the ring's STD backpressure, so the
  demux races the VBUF full and arrivals stay stale FOREVER — the loop is a
  stable attractor. Audio re-enters later/later or mutes in bursts = what was
  perceived as "video pulls ahead ~8/4 ms/s". The inverse-bitrate "rate" was
  an artifact of episodic re-phasing, not a bytes-per-event loss.

**FIX (shipped same branch, commit `0ad0297`): `head_stale` now requires
`!video_live`** — the stale-skip is confined to the load window (the v4
mid-title-cut backlog it was built for, where it lets `play_pts` latch a
current frame so `aud_caught` releases the STD hold). Mid-play it never
fires: the dominant starvation cause is the SHARED stream stalling, which
makes video equally late, so playing the late head as it arrives keeps lips
in sync (the gate's rule: only delay EARLY audio, never add lateness);
skipping to "STC-current" would align audio ahead of the late video AND latch
the treadmill. TB: C5 re-sequenced into the load window (regression green),
new C8 = lone stale head mid-play must PLAY, not discard.

**Next HW round (DVD_drift2): re-run the same protocol.** Expect: no
ring-empty/VBUF-full latch; row 18 skips frozen at the load count; fbrel ~0;
armed-time small; play_err flat; under a sustained compute deficit audio
plays LATE-but-lip-synced instead of muting/churning. Watch specifically the
two runs that collapsed (MiB O12 On from load, Matrix O12 Off). If the MiB
O12-On LOAD still starts with ring 0 + rearms saturating in seconds, that's a
separate start-path issue — read row 19 (start-hold word) with it.

### ★★ DVD_drift2 round (2026-07-03 later): the runs sort by DROPS-FIRING, not by label

User re-ran: "MiB O12 On" drifted audio-late 500–1000 ms/2 min (start OK at
−500); "Matrix O12 Off" out of sync, offset knob inert; "PAL O12 Off" smoother
than with drop on but out of sync. Row 19: MiB {1F 14} (hold 31 refr ≈ 520 ms =
the STD hold IS deferring ≈ the mux lead — not trivially-early, not fallback),
Matrix {0C 03}, PAL {01 01}.

Reconciling with row 11 ({lates/s, drops/s}) across both rounds exposes the
real split — **RTL-provable from `drops/sec`, whatever the menu said**
(`drop_ack` cannot pulse with the controller disabled; polarity/CONF_STR
verified correct, no bit collision):

- **Every run with drops FIRING (row 11 lo ≥ 1) is HEALTHY.** The DVD_drift2
  "MiB O12 Off" run had drops 1–3/s quietly reclaiming its 4–5 lates/s —
  timeline held (VBUF steady), `play_err` flat +20 ms for 4 minutes, no drift.
  That is the whole system working end-to-end.
- **Every desync/collapse run had drops NOT firing (row 11 lo = 00 despite
  lates 3–7/s):** DVD_drift1 "MiB O12 On", both rounds' "Matrix O12 Off",
  "PAL off". Without reclaim, every late is a PERMANENT timeline slip
  (`refresh_cnt` resets at pickup — no cadence self-heal), video runs slow /
  the delivery geometry inverts, and audio diverges. With drops off on
  compute-marginal content, desync is BY CONSTRUCTION (video slower than real
  time, audio exactly 48 kHz, knob can't fix a ramp and every arrival-limited
  release is already past-due = knob inert). The treadmill fix changed the
  failure mode from silence-churn to played-but-late — that's why PAL now
  sounds smoother with drops off — but the divergence itself is inherent to
  drops-off.

So at least one "O12 On" run behaved provably drops-OFF and one "O12 Off" run
provably drops-ON — toggle state and labels got crossed somewhere in the
session (the O12 flip is also used to switch overlay views, easy to lose
track of).

**10-second polarity check (do this first):** play MiB, watch row 11 LOW byte,
flip Frame Drop. The position where it reads 1–3 (not 00) is drops-ON. Then:

1. MiB, drops-ON (verified by row 11), A/V Offset 0, fresh load: check lips at
   0 and 4 min; row 17 should sit ≈ +0x70 flat; rows 16/17/18 are not muxed so
   they stay readable with drop on.
2. Matrix and PAL BBB with drops-ON (verified): expect in sync, drops 1–5/s.
3. If a VERIFIED drops-ON MiB run still drifts audio-late, THAT is a real bug
   (over-drop creep — the film_drift_tb model-vs-HW gap becomes the suspect);
   bring row 11/15(drop view)/17/18 from that run.

Operating guidance meanwhile: Frame Drop ON is the supported mode; drops-off +
compute-marginal content cannot hold sync and is a diagnostic mode only.

### ★★★ Round 3 (2026-07-03, DVD_drift2 readings): THE RATCHET — root-caused by user recording

Corrections from the user: the full protocol dataset was DVD_drift1 (not
drift2); Frame Drop On = drops firing (row 11 lo 1–3, polarity verified on
HW); and the PAL remark meant PAL drop-off audio is smoother than it was
before the frame-drop feature era (that's the treadmill fix converting churn
to played-late) while Frame Drop is still needed for smooth video — all
consistent. (The DVD_drift1 "O12 On" run showing drops/sec=00 with lates 3–7/s
remains an unexplained anomaly of that pre-fix collapsed run.)

**The decisive observation (drops VERIFIED firing):** MiB is in sync (at −500)
until the Shea-Stadium/Unisphere crash sequence — a heavy-drop compute crush —
then audio is ~1000 ms behind and STAYS there (verified by recording + VLC
resync). Audio-late accumulates in STEPS proportional to drop bursts. That is
the RATCHET the treadmill fix created: during a crush the shared stream
stalls, audio can only play late (data not arrived — correct and unavoidable);
afterwards VIDEO catches back up via the drop governor, but the treadmill fix
had removed audio's only catch-up path (the mid-play skip). One permanent
audio-late step per hard sequence.

**Fix (commit `eff0bc7`, rbf DVD_drift3): ARRIVAL-GATED MID-PLAY CATCH-UP.**
`dvd_audio_decode` now latches the ps_demux parse-front audio PTS (`arr_pts`);
while PLAYING, a head more than ~300 ms past due is discarded down to ~50 ms —
but ONLY while the arrival front is current (`arr_current`). The arrival gate
is the piece that separates the two regimes the previous rounds fought over:
- sustained deficit (drops off / mid-crush): nothing current ever arrives →
  no skipping → audio plays late, tracking delivery (no treadmill);
- post-crush recovery: the demux races ahead, the front crosses current, the
  stale backlog is skipped → ONE audible forward jump back into lip-sync
  (a real player's post-starvation resync).
Enter threshold 300 ms can't false-fire in healthy play (the dispatch lead
keeps `head_delta` negative). Load-window armed skip (v4) unchanged. TB C9
covers the catch-up; C8 remains the no-current-arrival guard.

**Next HW round (DVD_drift3):** MiB, Frame Drop ON, A/V Offset −500, play
through the Shea-Stadium sequence. Expect: late audio DURING the crush, then a
single forward resync within ~a second of the scene ending, back in sync
after. Row 18 low byte (skips) should step up at each catch-up; row 17
snaps back toward ~+0x70. Then the start constant (row 19 = {1F 14} showed the
STD hold genuinely deferring ~520 ms, so the residual −500 constant is
DOWNSTREAM of the hold — hypothesis 3) is the remaining open item.

### ★★★★ Round 4 (DVD_drift3 OSD recording): AUDIO EXONERATED — it's a VIDEO-AHEAD leak. FIXED.

DVD_drift3 still showed −900 ms after the crash — and the OSD recording gave a
clean one-read verdict at three scrub points (pre-crash / post / +30 s):
- row 17 `play_err` **flat to the LSB** (0xF517 = the −500 offset) — audio
  playback never deviated from schedule;
- row 18 frozen (0 re-arms, 0 fallbacks, skips at the load value) — audio
  never paused; the catch-up correctly had nothing to do;
- rows 14/15: the crash produced **+268 lates, +103 drops**.
So the −900 ms is **video ending AHEAD of the STC**. The arithmetic pins the
leak: the ledger balanced at debit ≈ 268/103 ≈ 2.6 per drop, but video
advanced ~45 refreshes beyond neutral ⇒ the dropped frames' true durations
averaged ≈ 3.0 — a crush drops a run of rff (3-refresh) B-frames while the
ledger debits the ON-DISPLAY frame's `cur_show`. The "statistically identical
on uniform film" proxy assumption breaks exactly when drops burst
(~+0.5 refresh unaccounted per drop; ~100 drops ≈ 900 ms).

**Fix (commit `61b230c`, rbf DVD_drift4):** the VLD's `drop_pic_ack` moves to
the FIRST SKIPPED SLICE (this picture's coding extension is parsed by then)
and exports the dropped picture's own `repeat_first_field`;
`frame_drop_ctl.drop_cost = (~interlaced && drop_pic_rff) ? 3 : 2` — a drop
now debits exactly the content-time it skips. `film_drift_tb +BCORR=1`
(rff correlated with droppable B's = the crush pattern) reproduces the leak
(curshow +47 refreshes AHEAD / exact −12 / flat2 +212) and shows why the
original uncorrelated run wrongly exonerated the proxy.

**Next HW round (DVD_drift4):** same Shea-Stadium test. Expect in-sync
through AND after the crash (audio may lag briefly DURING the crush and
resync via the round-3 catch-up if delivery gapped — row 18 skips would step;
row 17 stays flat). If clean: the drift saga closes; remaining open item =
the ~500 ms START constant (downstream of the STD hold per row 19).

### ★★★★★ Round 5 (DVD_drift4 full-run CSV via tools/osd_read.py): audio innocent FIVE ways — video-side instrument shipped

The osd_read CSV over the whole 4-minute DVD_drift4 recording (crash included):
`play_err` constant to ~±2 ms ALL RUN, row 18 frozen (0 re-arms / 0 fallbacks /
0 mid-play skips), ring/VBUF healthy, armed-time ~0, stc_excess flat — and
**drops steady at ~1.6/s with NO burst at the crash** (~370 total). Yet lips
still step **−900 ms** across the crash (user VLC check). Every instrumented
quantity is innocent; the ONLY leg without an instrument is the **video content
timeline vs wall clock** (governor/display path).

**Shipped (rbf DVD_drift5): overlay row 20 = `vid_err`** — wall refreshes
(video_live-gated) minus content presented (each pickup's `show_next` + each
VLD-dropped frame's own duration), signed, 1 unit = 1 refresh = 16.7 ms.
Steady state = small pipeline-offset constant; **negative going more negative
= video content running AHEAD** (the lips-"audio delayed" direction).

**Next read:** same recording flow on DVD_drift5 (`osd_read csv`), lips
VLC-checked. If row 20 steps ~−54 across the crash → video-side confirmed;
its correlation with rows 14/15 (lates vs drops) pins the mechanism (e.g.
governor presenting frames early / cadence mis-pacing under crush, vs
something in the reorder). If row 20 stays FLAT while lips step → the error
is between the resample pickup and the glass (framestore/scaler), or in the
recording chain itself — then compare against an ear-only check.

### ★★★★★★ Round 6 (drift5c) — ⛔ VERDICT RETRACTED 2026-07-04 (round 7): the "clean read" was decoded with a 3:4 pitch-aliased calibration; every number below is a reader artifact. See START HERE. Kept for the record only.

Three reader iterations (affine → multi-point → per-column profile segmentation)
finally produced an exact CSV, and the ledger identity delivers the verdict:

- PRE-crash [8–55 s]: lates 19.15/s, drops 9.53/s, vid_err FLAT (−0.04/s);
  lates/drop = 2.009, implied debit 2.013 — the ledger balances to three
  digits. Every frame_late pulse = a real repeated refresh; drops reclaim
  exactly; lips hold. (Also: MiB baseline churn is heavy — ~40 % of frames
  dropped with lips fine — the reclaim design working.)
- POST-crash [66–172 s]: frame_late counter = 54.0/s, but REAL repeated
  refreshes (wall − pickup credits = vid_err + drop credits) = ~18/s.
  **Ratio 2.97 ≈ 3.00: frame_late fires ~3 pulses per actual late refresh.**
  vid_err (+5.04/s) is the visible leak of the same accounting.

Causal chain to the user-visible bug: frame_late is frame_drop_ctl's debt
currency → 3× inflated debt → drop_req far beyond real lateness → drops with
no lateness to reclaim = pure content skips → video walks AHEAD (+900 ms built
during the crush recovery, held forever after). The drift5b finding that the
dropped frames' rff phase flips at the crash (true dropped duration 2.0 pre →
3.1 post) plus the exact ×3 (= an rff frame's cur_show) point at the
governor's repeat/late path multi-counting lateness for cur_show=3 frames in
the post-crash regime.

NEXT (local, no HW needed): find the STATE_REPEAT/late_raw branch in
dvd/resample_addrgen.v that can emit >1 frame_late per missed refresh when
3-refresh frames are on display (candidates: the NEXT_IMG↔REPEAT no-scan
bounce when image slots are momentarily NO_OUTPUT; the frame_late register
being a held LEVEL over multi-cycle REPEAT visits — frame_drop_ctl counts it
per CLOCK). Extend cadence_phase_tb or a dedicated resample-level TB to
reproduce 3-pulses-per-late, fix, verify ledger identity in sim, then
DVD_drift6. The fix should collapse the churn AND the crash step; re-test
Shea-Stadium end-to-end afterwards.

(Tooling note: osd_read calibration now refines+de-aliases EVERY geometry
hypothesis with cached frames — a capture shifted whole cells off a standard
scaler geometry self-corrects; re-run `calibrate` once after pulling.)

### 2. START CONSTANT ≈ 500 ms (audio-late at clip start, both discs)

Persists WITH the v5 STD mux-lead hold — that's the suspicious part. The hold was
designed to defer the first display until the audio caught the anchor, which
should have left ≈0 start error. Either:
- the hold isn't actually deferring on HW (check: is there a visible ~0.5 s black
  hold at clip start? The user never reported one — instrument
  `av_vid_hold`-release-to-`video_live` latency, or count refreshes between anchor
  and first pickup and surface on the overlay), or
- the release condition fires trivially early (e.g. `aud_caught` satisfied by an
  unexpected `play_pts`), or
- a second ~500 ms constant sits between the STC and the true screen (framestore/
  reorder/scaler path?).

Measure before fixing: one overlay word = {refreshes stc-frozen-at-anchor,
refreshes hold-was-asserted} would discriminate all three. **That word SHIPPED
with the drift instruments (2026-07-03, `feature/lipsync-drift`): overlay
row 19 = {pickup-hold refreshes[15:8], STC-anchored-but-frozen refreshes[7:0]},
latched per clip load.** Expected readings: hold ≈ 30–40 (0.5–0.7 s) = the STD
hold really defers display (then the ~500 ms constant is DOWNSTREAM of the
STC — hypothesis 3); hold ≈ 0–2 = it releases trivially early (hypothesis 2);
hold ≈ 74 = the 1.24 s fallback expired, `aud_caught` never fired (hypothesis
1). Grab this row in the same session as the drift protocol — it's free. Note
that if the drift fix (problem 1) lands first, re-measure the start constant —
the drift mechanism losing a burst during the startup transient could BE part
of the constant.

## Tools that made this tractable (reuse them)

- `bench/dvd/aud_pts_chain_tb.sv` — feeds MB of a REAL VOB (`+VOB=<path> +MB=<n>`)
  through ps_demux+reframer: PTS yield, mux offset (`first vid_pts − first
  aud_pts`), seq-header anchor check. Real VOBs: `tools/streams/MATRIX.VOB`
  (470 ms mux lead), `$DVD_ISO_DIR/VIDEO_TS/VTS_21_4.VOB` = the MiB test
  clip (667 ms; 192 kb/s audio). ⚠️ `~/Downloads/VTS_04_2.VOB` is Pink Floyd PAL,
  NOT MiB.
- `bench/dvd/film_drift_tb.sv` — real `frame_drop_ctl` + 3:2 governor model,
  measures timeline drift under drops (`+MODE=flat2|curshow|exact`). This is what
  exonerated the drop accounting.
- Overlay (Debug Overlay On): with Frame Drop OFF → row 14 = {gate flags[15:8],
  ac3_resets[7:0]}, row 15 = av_drift[19:4] (signed, ~178 µs/unit; healthy ≈
  +0x0200). With Frame Drop ON → rows 14/15 = {lates, drops}. Row 13 = ring
  overflow (always). These displaced the AC-3 counters — restore the original
  rows 14/15 AC-3-reset view before merging the next PR (cleanup debt).
- `dvd_audio_decode_tb` phases C1–C6 cover the whole gate contract; extend, don't
  bypass. `pickup_hold_tb` covers the STD hold + per-load re-arm.
- **`tools/osd_read.py` (2026-07-03)** — decodes the debug overlay from a
  capture-card recording (the user records HW tests), turning it into logged
  telemetry instead of eyeball reads. `calibrate` auto-finds the overlay panel
  and validates against row 3 (the frame counter must increment); `read` prints
  labeled hex (+signed/ms for rows 15/16/17) at timestamps; `csv --every 0.5`
  emits the full 20-row timeline for plotting — one pass over a recording now
  answers what previously took a whole HW round of manual scrubbing.
  `selftest` renders a synthetic capture from the RTL geometry and round-trips
  it (run it after any debug_overlay.sv geometry change). Needs python3 +
  numpy + ffmpeg. Typical flow:
  `python3 tools/osd_read.py calibrate rec.mkv --time 10` (once per capture
  setup) then `python3 tools/osd_read.py csv rec.mkv --every 0.5 --out run.csv`.

## Hard-won rules (violations cost whole HW rounds)

1. Knob/gate semantics bind at (RE)START events only; never re-arm the drain gate
   mid-flow (full FIFOs deadlock it — v3.0 and v5.2 both died of this).
2. Any PTS from ps_demux is a PARSE-time value — it leads the display by the whole
   buffering window. Never compare it to a display-referenced clock with a tight
   threshold.
3. The NCO needs no rate trim (same crystal as the raster) — the retired PI must
   stay retired; phase mechanisms only.
4. 90 kHz tick constants are big: 500 ms = 45000 — check signal widths (16-bit
   signed wrapped the −400/−500 knob entries once already).
5. Measure before building: the two real-VOB TBs and one overlay read repeatedly
   beat theory. When two builds behave identically, the mechanism isn't executing —
   instrument, don't iterate.

## Suggested opening moves for the new session

1. ~~Take the user's DVD_avlead13 readings~~ DONE 2026-07-03: resets 0/0,
   overflow 0, drift +0x0300 → ~0xF800 — suspect EXONERATED (see §1).
2. ~~Branch `feature/lipsync-drift`~~ DONE — carries the drift instruments
   (rows 13/16/17/18) and TB phase C7.
3. Run §1's read protocol on the new build (O12 Off AND On on MiB, one Matrix
   pass); apply the decision table. Do NOT build a fix before this read.
4. Re-measure the start constant after the drift mechanism is understood/fixed;
   instrument the hold timing if it persists (a one-word {refreshes
   stc-frozen-at-anchor, refreshes hold-asserted} still discriminates the three
   start-constant hypotheses); only then decide between fixing the hold and
   shipping a calibrated default offset.
5. Cleanup debt for the eventual FIX PR: restore rows 14/15 AC-3 diagnostics,
   drop the temporary gate-flag byte and the drift-instrument rows 16-18, and
   set the shipping default `A/V Offset` (0 if the start constant is fixed).
