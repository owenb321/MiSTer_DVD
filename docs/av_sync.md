# PTS-driven A/V sync — design & status

> ## ✅ WHERE THIS STANDS (2026-07-04, end of the PR fj#62 drift saga — READ THIS FIRST)
>
> **THE LIP-SYNC DRIFT SAGA IS CLOSED — HW-CONFIRMED (rounds 7–12,
> `docs/lipsync_pickup.md`).** The update-chain below is a long debugging log;
> this is the accurate net state.
>
> **THE ROOT CAUSE (round 11, fixed by `flags_commit`, HW-confirmed round 12):**
> the upstream decoder captured each picture's display flags
> (`repeat_first_field`/`top_field_first`/`progressive_frame`) on the
> `update_picture_buffers` pulse — fired at the picture HEADER — but those
> fields parse ~10 FSM states later in the picture CODING EXTENSION (and the
> VLD freezes at the header until picbuf processes the update), so **every
> picture displayed with its coded PREDECESSOR's flags**. On clean 3:2 film
> that is an invisible phase shift (the alternation is preserved — the cadence
> looked perfect through every earlier HW round). FRAME DROPS broke the
> pairing: the drop debit reclaims the dropped frame's OWN duration (the ack
> path samples post-extension) while the display timeline actually freed the
> STALE one; the drop selection is cadence-phase-locked (~90 % own-rff=0 B's
> whose stale predecessor flag is 1), so each drop leaked ~+1 refresh of video
> lead → video ran ~+3.3 % fast, funded by the draining VBUF cushion, until
> the cushion exhausted at the first heavy scene — then the accumulated
> ~+1.2 s lead froze as the permanent "audio ~900 ms behind". FIX: the VLD
> pulses `flags_commit` when the current picture's extension has parsed (never
> for dropped pictures); picbuf re-latches the three flags into the current
> slot. HW verdict (drift9b capture, 7.5 min MiB through the Shea crash): vid_err
> flat ±3 refr all run, VBUF parked ~0.5–1.2 MB (rises through the crash),
> lates/drops 2.03–2.05 constant, play_err constant to the LSB — "delay is
> now constant throughout".
>
> **HW-CONFIRMED WORKING (do not re-litigate):**
> - The full scheduling chain sequences correctly on HW: audio locks to the
>   STC; play_err constant to the LSB over 7.5-minute runs.
> - The **A/V Offset knob works** (binds at (re)start events; mid-play phase is
>   locked by sample continuity BY DESIGN).
> - Pre-anchor dispatch hold, per-load `video_live` re-arm (reload == cold start),
>   absolute `vbuf_healthy` thresholds (frame drop works on VOBs), no deadlocks/freezes.
> - Frame-drop loop is timeline-neutral: lates/drops ≈ 2 is the CORRECT
>   equilibrium (drops phase-lock to rff=0 B's; debit 2 is their true duration).
> - PAL is in sync throughout and unaffected by any of it.
>
> **OPEN (small follow-ups, none blocking — details in lipsync_pickup.md round 12):**
> 1. **Start offset — SHIPPED (`feature/lipsync-followups`).** The old "≈500 ms
>    audio-late start constant" was mostly the stale-flag ramp in disguise; the
>    TRUE residual is ≈100 ms audio-EARLY (nulled at `A/V Offset = +100` on MiB).
>    The **`A/V Offset` default is now +100 ms** (index 0), the recommended
>    NTSC-film setting, and the menu is rebalanced around ±200 ms
>    (+100/-200/-100/-50/0/+50/+150/+200) — the retired deep-negative
>    -300/-400/-500 entries chased the now-fixed ramp. Still verify Matrix + PAL
>    before treating +100 as universal (mux depth varies per disc).
> 2. **Overlay cleanup debt — SHIPPED (`feature/lipsync-followups`).** Rows 14/15
>    are back to the AC-3 self-heal reset view (row 14 ERR resets, row 15 TOTAL
>    resets), no O[12] mux; the drift instrument rows (13-hi armed-time, 17
>    play_err, 18 gate_events, 19 start_hold, 20 vid_err) are retired (overlay
>    NROW 21→17); row 16 keeps the {drop debits 3, 2} split until a Matrix/PAL
>    pass. The `stc_excess` emu logic is dropped. `tools/osd_read.py` ROW_LABELS
>    updated to match.
> 3. **Secondary curiosity (not a bug)**: healthy film still generates ~4
>    lates/s + 2 drops/s with a full VBUF — correctly reclaimed now, but the
>    decoder missing ~17 % of deadlines on easy content may hide a small
>    compute/pacing inefficiency.
>
> **History of the earlier (audio-side) closure — rounds 1–6 context:**
>    Two measurement rounds — (i) the
>    DVD_avlead13 read exonerated the AC-3 self-heal resets (counter 0 while
>    the meter drifted); (ii) the DVD_drift1 instrument read (stc_excess /
>    play_err / gate-event counters, MiB+Matrix, 0-4 min) exonerated the STC
>    (row 16 flat everywhere) and showed the healthy regime has **NO real
>    drift** (play_err +20 ms CONSTANT over 4 min) — the perceived drift was a
>    **collapse mode**: the ARMED stale-skip, when delivery runs behind real
>    time, discards audio as fast as it arrives (ring pinned empty), kills the
>    ring's STD backpressure (demux races the VBUF full, arrivals stay stale
>    forever), never latches `play_pts`, and churns 2.5 s fallback releases —
>    a stable silence/re-phase attractor. FIX: `head_stale` requires
>    `!video_live` — the skip is confined to the load-window backlog (its v4
>    purpose); mid-play the late head PLAYS (shared-stream stalls make video
>    equally late, so lips stay synced). Full verdict data + re-test protocol:
>    `docs/lipsync_pickup.md` §1 "VERDICT".
>
> **EXONERATED (measured — do NOT re-chase):**
> - The PTS chain: byte-/frame-exact on real VOBs (`aud_pts_chain_tb`: 154/154 PES,
>   202/202 reframed frames tagged, correct values).
> - The STC anchor value: = the first sequence-header picture's PTS, 0 ms error on
>   BOTH discs (mid-GOP-cut theory was wrong for these full-title VOBs).
> - The frame-drop reclaim accounting: `film_drift_tb` (real controller, 3:2 governor
>   model, 280 drops/166 s) shows ≤ 18 ms/min drift, WRONG SIGN — 30× too small to be
>   the observed drift, in all debit modes. (The film-aware `cur_show` debit shipped
>   anyway as correctness polish.)
> - The audio NCO rate (same 27 MHz crystal as the raster — locked by construction;
>   the retired PI trim must STAY retired).
> - DVD mux geometry as a *steady-state* cause: audio is muxed 470 ms (Matrix) /
>   667 ms (MiB) behind video — this forced the STD hold design, but with the ring
>   buffering it, it cannot explain a RATE drift.
>
> **FAILED APPROACHES (kept in the log below; do not retry):** entry-side dispatch
> scheduling (v2 — elastic buffers absorb it), pre-anchor gate bypass (v3.0 — mid-flow
> arm deadlock), fractional `vbuf_healthy` thresholds, live mid-play re-arm on knob
> change (v5.2 — full-FIFO deadlock), 16-bit `av_ofs` (−400/−500 ms wrap positive).
>
> Pickup instructions for the next session: `docs/lipsync_pickup.md`.

> **Status (2026-06-28, MERGED PR fj#36):** implemented + sim-verified
> (`bench/dvd/av_sync_tb.sv`, extended `audio_ring_tb`, regressions green incl. real-VOB
> `ps_chain`). **HW: runs on hardware; the registered VGA output stage that shipped with it
> is confirmed clean (column dots GONE, no green fringing — see memory
> `chroma-fringe-is-intermittent`).** Audio AV-sync quality (lip-sync / lead tuning)
> still needs a dedicated HW pass — see Open follow-ups. Overlay surfacing of
> drift/trim deferred.
>
> **Update (2026-07-02, `feature/lipsync-lead-vbuf`):** the lip-sync pair landed —
> (1) `LEAD_TARGET` is now the **runtime `lead_target` port**, driven from the OSD
> (`P1O[23:21] A/V Lead`, 0–400 ms, default 150 ms) so lip-sync is dialled live on HW;
> (2) **PTS-scheduled dispatch** in `dvd_audio_decode` holds an early frame in the ring
> until `STC >= pts - lead_target`, making the dispatch phase correct BY CONSTRUCTION at
> start/seek instead of the ±0.5 % slew grinding it out over ~30 s. Sim-verified
> (`av_sync_tb` + `dvd_audio_decode_tb` Phase C); **HW confirm pending.**
>
> **Update 2 (2026-07-02, same branch — STC REFERENCE FIX after first HW test):** the
> first HW pass showed the A/V Lead knob INERT (0 ms ≡ 400 ms) and content-dependent skew
> (Matrix near, MiB far). Root cause: the STC referenced the **demux parse position, not
> the screen** — see "STC reference (v2)" below. Fixed with the `video_live` advance gate
> + one-sided re-anchor; the starvation-guard fractional-threshold regression from the
> VBUF enlargement is fixed alongside.
>
> **Update 3 (2026-07-02, same branch — PLAYBACK-REFERENCED PHASE, the v3 mechanism):**
> the second HW pass CONFIRMED the v2 STC fixes (audio starts with the image; frame drop
> works on VOBs again) but the knob was STILL inert and skew still content-dependent
> (Matrix ~50-100 ms, MiB ~500 ms). That killed the dispatch-side gate design itself:
> **scheduling the ENTRY to an elastic buffer cannot set its EXIT time** — see
> "Playback-referenced phase (v3)" below, which moves the schedule to the PCM-FIFO exit
> and retires the NCO trim.
>
> **Update 4 (2026-07-02, v3.1):** third HW round found v3.0's pre-anchor bypass armed
> the gate mid-flow with full FIFOs — a release deadlock (Matrix silence + ~1 s video
> freeze) or an instant-release free-run (MiB unchanged). v3.1 arms from reset (FIFOs
> provably empty at latch) + a ~2.5 s fallback release + AC-3 stall-watchdog exemption
> while held.
>
> **Update 5 (2026-07-02, v4 — STALE-SKIP):** fourth HW round: Matrix un-wedged ✓ but
> knob still inert, skews unchanged. Cause: mid-title VOB cuts put several hundred ms
> of audio with PTS *before* the first displayable video frame at the FIFO head — the
> release saw the head past-due for every offset. v4 discards past-due frames while
> armed (see "v4 — stale-skip"), which also turns the underrun re-arm into true
> catch-up.
>
> **Update 6 (2026-07-02, v5 — THE STD MUX-LEAD HOLD; measured root cause):** round 5
> unchanged; the overlay instrumentation + a real-VOB sim finally MEASURED it:
> `first vid_pts − first aud_pts = +470 ms` on Matrix — **DVD muxes audio ~0.5 s BEHIND
> the video for the same presentation time** (VBV lead). Our governor displayed the
> first frame as soon as it decoded, so video ran a mux-depth AHEAD of the audio's
> arrival timeline: audio trailed by the per-disc mux depth, no output-side schedule
> could fix it (the data hadn't arrived), and the stale-skip in that arrival-limited
> regime discarded endlessly (the silence cycling). v5 implements the real STD: **hold
> the video's first display until the audio side has caught the anchor** — see "v5 —
> STD mux-lead hold". Sim green (new `pickup_hold_tb`, TB C1-C5, cadence TBs);
> **HW re-test pending.**

## Why

DVD audio played from a **free-running 48 kHz NCO** (`dvd/dvd_audio_decode.sv`), consuming
bytes that arrived at *video rate* through the shared, video-back-pressured demux stream
(`ps_demux`). Audio had **no real-time clock of its own** — it rode video's bursty delivery.
Video is locked to the HDMI refresh (frame-rate governor, `dvd/resample_addrgen.v`); audio to
`clk_sys`. Two crystals → slow drift, and the audio buffer over-/under-flowed when the governor
un-throttled the demux during compute-bound video catch-up bursts. This is the root cause
behind the audio stutter / static-pop work (PRs fj#34/#35): the pops were a *symptom* of audio
lacking its own clock (see `static-pops-root-cause` memory).

## Model: a commercial DVD player

A real player recovers one **System Time Clock (STC)** from the stream and genlocks *both* the
video display and the audio DAC to it — PTS sets the **phase**, the shared clock holds the
**rate**, so they never drift. We can't share one crystal (video is hard-locked to the HDMI
refresh), so the faithful equivalent is:

- **Video is the master timebase** (immovable, HDMI-locked, and what the user watches).
- Build an **STC that tracks the video presentation timeline**, and **soft-slew the audio NCO**
  to genlock to it — exactly like a player slewing its audio DAC PLL. No hard audio gaps for
  normal drift/transients; a gross PTS jump (chapter seek) triggers a clean re-anchor.
- The one case a real player never hits — **sustained compute-bound video (BBB)** — remains a
  video-throughput limit. PTS sync degrades it *gracefully* (audio slows/under-runs with the
  picture) instead of popping, but does **not** "fix" it. The real BBB fix is video throughput
  (separate effort — see `f2sdram-90mhz-ceiling`, `pipelined-hits-memory-done`).

## Data flow

```
ps_demux ──vid_pts──────────────────────────────┐
         └─aud bytes +aud_frame_pts──► audio_ring│ (per-frame PTS in descriptor)
                                          │ frame_pts                 │
                                          ▼                           ▼
                                 dvd_audio_decode ──dispatch_pts──► av_sync
                                   ▲  nco_trim  ◄────────────────────┘   ▲
                                   │                                     │ refresh_tick
                                 48 kHz NCO (slewed)         (core_v_sync edge, clk_sys)
```

All of `ps_demux` / `audio_ring` / `dvd_audio_decode` / `av_sync` run in **clk_sys (27 MHz)**,
so there is no clock-domain crossing. `core_v_sync` is produced on `dot_clk = clk_sys`
(`mpeg2video .dot_clk(clk_sys)`), so the refresh edge needs no CDC.

## STC (no decoder surgery)

Threading PTS through the MPEG-2 decoder (B-frame reorder + framestore) is invasive and
deliberately avoided. Instead the STC is synthesized in clk_sys:

- **Anchor** `stc = vid_pts` on the first video PTS after reset/seek.
- **Advance** by `TICKS_PER_REFRESH` per `refresh_tick`, where each refresh = one displayed
  image (a progressive frame OR an interlaced field) = 1/refresh_rate of real time.
  `TICKS_PER_REFRESH = 90000/refresh_rate`, carried as a **Q16 fixed-point** accumulator
  (≈ 1501.5 ticks @ 59.94 Hz, so the half-tick doesn't accumulate error).
- `refresh_tick` = rising edge of `core_v_sync` in clk_sys (emu derives it).

**Why this is correct despite decoder latency:** both `vid_pts` and the audio frame PTS are
sampled at the *same* point (ps_demux parse), so comparing them yields the authoring-intended
A/V skew regardless of how long each takes to reach the screen/speaker. The STC leads true
display by the (fixed) video pipeline delay; `LEAD_TARGET` (below) absorbs the matching audio
delay so lip-sync is correct.

NTSC-only first cut (`REFRESH_MHZ = 59940`, governor `SHOW_N = 2`). **PAL TODO:** drive
`REFRESH_MHZ` (and the governor `SHOW_N`) from `frame_rate_code`.

## Regulator (`dvd/av_sync.sv`)

```
error = dispatched_aud_pts - STC - LEAD_TARGET          (90 kHz ticks)
trim  = -(error >> KP_SHIFT) - (integ >> KI_SHIFT)      (PI, clamped ±0.5% of NCO_INC)
```

- `error > 0` → audio ahead of video → `trim < 0` (slow the NCO).
- `error < 0` → audio behind → `trim > 0` (speed up).
- The **integral** term winds up to cancel the steady crystal-rate bias, driving the residual
  rate error to ~0 (P-only would leave a standing offset). Anti-windup clamps the integrator.
- **`lead_target`** (default 13500 ticks ≈ 150 ms) is the knob that matches the audio
  buffer+pipeline delay to the video pipeline delay for correct lip-sync. Since 2026-07-02
  it is a **runtime input** driven from the OSD **`P1O[23:21] A/V Lead`** menu
  (150/200/250/300/400/0/50/100 ms; index 0 = the 150 ms power-on default), so it is tuned
  live on hardware, no rebuild. It sets both the PI set-point and the dispatch schedule
  (below). **Tuning direction:** audio heard LATE vs video → RAISE the lead (dispatches
  audio earlier); heard EARLY → LOWER it.
- **Trim clamp = ±0.5 % of `NCO_INC`**, so any steady-state pitch shift is inaudible. A
  *sustained* mismatch larger than 0.5 % (e.g. compute-bound BBB running the video well below
  real time) cannot be tracked by slew alone — audio buffer drains and under-runs gracefully;
  that is the video-throughput limit, not a sync bug.
- **Seek/discontinuity:** a `vid_pts` that differs from the STC by more than `REANCHOR_TICKS`
  (~0.7 s) snaps the STC to it, clears the integrator and zeroes the trim, and bumps
  `reanchor_count` — a clean phase reset on a chapter change instead of slewing for minutes.

`av_sync` is gated by the same `O5 Audio` enable; disabled → `nco_trim = 0` and the NCO
free-runs (prior behaviour, exact regression).

## Playback-referenced phase (v3, 2026-07-02) — drain-start scheduling

> Supersedes the "PTS-scheduled dispatch" section below (kept for the record).

**Why dispatch-side scheduling failed on HW (knob inert both passes):** playback phase =
dispatch phase − downstream buffer occupancy (AC-3 input FIFO + PCM FIFO, ~120 ms), and
the occupancy is a **free variable set by history**. Raise the lead → the gate releases a
burst → the buffers absorb it → phase unchanged. Lower it → the gate delays → the buffers
drain by the same amount → phase unchanged. The exit phase of a gaplessly-flowing 48 kHz
stream is set ONLY at buffer-empty→flowing transitions (start, underrun recovery); every
disc's phase was the accident of its startup transient — Matrix's small (~50-100 ms),
MiB's large (~500 ms, compute-marginal start with underruns re-pinning it randomly).

**v3 mechanism — schedule the exit, free-run the rate:**

- **Drain gate** (`dvd_audio_decode`): the 48 kHz tick is withheld from the codec output
  FIFOs while ARMED; dispatch/decode fill them freely (entry is un-gated again). The
  first PTS-tagged frame dispatched while armed latches `play_pts` (FIFOs were empty at
  arm, so it is ≈ the FIFO head). When `STC >= play_pts + av_ofs`, the drain releases —
  the head sample exits when the display timeline reads its PTS. **Lip-sync by
  construction, immediately, per clip.**
- **Underrun re-arm:** a tick that finds the active FIFO empty re-arms the gate, so audio
  re-enters *at phase* after any starvation gap instead of wherever data resumed — the
  mechanism that previously randomized MiB's phase now self-heals it.
- **`O[23:21]` is now `A/V Offset`** (signed, 0 default, +50/+100/+150/−200…−50 ms;
  positive = audio later): a trim around nominal, applied at the release compare.
- **★ COROLLARY OF THE RETIRED TRIM — THE RASTER-RATE INVARIANT (learn this before adding
  any video mode):** because nothing slews the audio rate any more, **the core raster period
  must equal the content's true frame period EXACTLY, in 27 MHz dots** (`htotal × vtotal`).
  Nothing downstream fixes an error there: the STC *counts refreshes*, so a slow raster just
  makes the STC slow with it; the governor paces to refreshes; ascal repeats frames, which
  doesn't move the average. A raster-rate error is therefore a **permanent linear A/V drift**,
  invisible at the start and reset by every seek/chapter re-anchor. This bit us once: **Film
  24p v1 shipped `858 × 1313` = 23.96689 Hz instead of 23.976024 — 0.038 % slow = audio
  ~1.37 s/hour ahead** (fixed 2026-08-02 to `875 × 1287`; see `docs/film_24p_plan.md` §10).
  When adding a mode, factor `27e6 × <frame period>` and check the modeline divides it
  exactly — an odd dot count needs an ODD htotal, so the standard 858/864 line may not be
  usable. **All six shipped rasters are now asserted to the dot in
  `bench/dvd/crt_syncgen_tb.sv`** (480p, HDMI 480i, HDMI 576i, CRT 480i, Film 24p, Film
  25p) — add a phase there for any new mode. Audited 2026-08-02; only Film 24p was wrong:

  | raster | dots/frame | rate |
  |---|---|---|
  | NTSC 480p `858 × 525` | 450,450 | 59.94006 ✅ |
  | PAL 576p `864 × 625` | 540,000 | 50.000 ✅ |
  | HDMI 480i `(262+263) × 1716` | 900,900 | 29.97003 ✅ |
  | HDMI 576i `(312+313) × 1728` | 1,080,000 | 25.000 ✅ |
  | Film 24p `875 × 1287` | 1,126,125 | 23.976024 ✅ (was `858 × 1313` ❌) |
  | Film 25p `864 × 1250` | 1,080,000 | 25.000 ✅ |

  ★ SECOND COROLLARY (2026-08-03, the Film-24p cadence-slip saga): an exact raster is
  NECESSARY but not SUFFICIENT — the governor must also honour each picture's TRUE
  duration. Film 24p's flat 1-refresh-per-picture assumed a perfect 3:2 cadence; real
  discs break cadence at shot edits (MiB rff density 0.499158, not 0.5) and the error
  accumulated ~0.9 s/hour, invisible to vid_err/raster/audio counters, caught only by
  content-level measurement (audio xcorr + motion-envelope vs the source VOB — predicted
  from the disc's flags to 1 %). Fixed by the cadence-slip corrector in
  dvd/resample_addrgen.v (✅ HW-CONFIRMED, PR fj#158); see docs/film_24p_plan.md §12.

  ⚠️ The two interlaced rows are exact only because the field totals ALTERNATE
  (262/263, 312/313) — and until 2026-08-02 that alternation was armed by
  `interlaced && halfline != 0` while the HDMI modeline writes `halfline = 0`. It worked
  purely because `syncgen_intf` doubles horizontal params as `2x+1` under pixel
  repetition, so `0 → 1` (nonzero). Equal-length fields would make 480i 0.19 % fast
  (~6.9 s/hour). `syncgen.v` now arms the alternation on `interlaced` alone so that
  cannot silently regress.
- **NCO trim RETIRED** (`dec_nco_trim = 0` in emu): the audio NCO and the display raster
  share one 27 MHz crystal and the governor plays exact cadence ratios, so the RATE
  matches by construction — there is nothing for a PI slew to correct, and leaving it
  active would be harmful: its entry-side set-point differs from the drain-set phase by
  the (variable) buffer occupancy, so the integrator would grind the correct phase away
  at ±0.5 %. `av_sync` remains as the STC generator + re-anchor + drift telemetry
  (`lead_target` fed 0 so drift reads 0 = in sync); `O[13]` Genlock Off now bypasses the
  drain gate (free-run, the legacy behaviour).
- **Bypasses / liveness:** gate inactive when `sched_en` low or STC un-anchored (raw ES).
  A held start always releases (STC advances every refresh once `video_live`); the ring
  drain-watchdog remains the outer guard.
- **Known accuracy limits:** the head-vs-`play_pts` match is approximate by up to one
  in-flight or PTS-less frame (~32-64 ms) — refine with sample counting only if HW shows
  it matters.

### v3.1 — arm-from-reset + fallback (the Matrix silence/freeze fix)

Third HW round: MiB unchanged (~500 ms late, knob inert) and **Matrix regressed** — a
split second of audio at load then silence, video freezing ~1 s near the start. All one
flaw: v3.0 **bypassed** the gate until the STC anchored, so the gate armed **mid-flow
with the decode FIFOs already full**. Releasing needed `play_pts` from a *new* dispatch;
dispatch was stalled on the full FIFOs; the FIFOs could only drain if released —
**deadlock** (Matrix: the split second = pre-anchor bypass audio; the stalled ring then
backpressured the shared stream for the ~1.2 s drain-watchdog window = the video freeze).
On MiB the race went the other way: a PTS frame latched just before the FIFOs filled,
the STC was already past it, the gate released instantly ⇒ permanent free-run ⇒ v2
behaviour exactly (phase = startup accident, knob inert). PAL just won the race.

Fixes (v3.1):
- **Held from reset — no pre-anchor bypass.** The FIFOs are guaranteed EMPTY when the
  phase reference latches; the mid-flow arm transition cannot exist. Audio start is
  gated to video start (kills the split-second leak too).
- **Fallback release timer** (`ARM_TIMEOUT_W`, ~2.5 s): armed with data but no
  schedulable reference (no PTS ever / STC never anchors) → free-run the stretch rather
  than wedge silent; the next underrun re-arms and tries the schedule again.
- **AC-3 stall watchdog exempted while held** (`!drain_en` clears it): an output-blocked
  decoder waiting on the scheduled start is not stuck, and a self-heal reset would dump
  the very bytes queued for that start.

Verified: `dvd_audio_decode_tb` Phase C v3.1 — `[C1]` held while STC un-anchored AND
while early, releases exactly at `stc = play_pts` with the correct head sample; `[C2]`
underrun re-arm + scheduled re-entry; `[C3]` `sched_en=0` free-runs; `[C4]` the fallback
releases an unschedulable stretch instead of wedging.

### v4 — stale-skip (the mid-title-cut backlog; last knob-inert cause)

Fourth HW round: Matrix un-wedged (v3.1 confirmed) but still out of sync, the knob still
inert, MiB still ~500 ms. Final cause: **stale audio at the FIFO head.** These test VOBs
are mid-title cuts — at the cut, audio PES parse immediately, but video cannot display
until the next sequence header + I-frame, so the first several hundred ms of parsed
audio carry PTS *earlier* than the first displayable video frame. That backlog became
the FIFO head: the release compare saw the head past-due for EVERY offset value (−200
through +150 all released instantly ⇒ knob inert), and playback ran late by the backlog
length (the per-disc constant: MiB's cut has ~500 ms of pre-I-frame audio, Matrix's
less). A real player *skips* late audio.

v4: **stale-skip while armed** — at descriptor pop, a frame whose
`STC − pts − av_ofs > STALE_TICKS` (~50 ms) is routed to the null sink (never decoded,
never the phase reference, `dispatch_pts_valid` suppressed); `skip_run` extends the
discard across following PTS-less frames until a fresh PTS frame ends the region and
becomes `play_pts`. Armed-state only — mid-play continuity is never broken; the underrun
re-arm is the catch-up path, and with stale-skip it now *skips the missed backlog* and
re-enters on time instead of playing it late. Verified: TB `[C5]` (stale frame fully
discarded, fresh frame plays first and exactly on schedule).

### v5 — the STD mux-lead hold (measured root cause; the fix that makes the rest work)

> ⚠️ 2026-07-03 CAVEAT: the mux-lead measurement below is real and the hold logic is
> sim-verified and live on HW — but the ~500 ms START constant it was built to remove
> **still shows on HW** (nulled only by A/V Offset −500). Treat the hold's on-hardware
> effectiveness as UNVERIFIED: either it isn't deferring the display as designed, or a
> second constant of similar size exists. See "WHERE THIS STANDS" at the top.

Round-5 HW was unchanged, so we finally **measured** instead of iterating:
`bench/dvd/aud_pts_chain_tb.sv` runs ps_demux+reframer over megabytes of the real
`MATRIX.VOB` and reports `first vid_pts − first aud_pts = +470 ms`; the overlay flags
showed the gate scheduled-releasing correctly with drift parked at ~−500 ms.

**The root cause was never the audio side: DVD muxes audio ~0.5 s BEHIND the video for
the same presentation time** (the video needs VBV lead, so the disc interleaves
video-for-X next to audio-for-X−0.5s). A real player's System Target Decoder therefore
displays video ~0.5 s *behind* the demux position, absorbing the lead in the video
buffer. Our governor displayed each frame as soon as it decoded → video ran a
mux-depth ahead of the audio's *arrival* timeline → audio trailed by the per-disc mux
depth (Matrix 470 ms, MiB ~500 ms, PAL discs muxed tighter → looked fine), the knob was
powerless (audio literally hadn't arrived), and in that arrival-limited regime every
frame looked stale to the v4 skip on re-arm → the discard/underrun silence cycling.

**v5 = hold the video's first display until the audio has caught the anchor:**

- `emu.sv` **STD hold controller** (clk_sys): asserted from every clip-load flush,
  released when the audio side has LATCHED a dispatchable frame at/past the STC anchor
  (`play_pts ≥ stc − 50 ms` — by then the stale-skip has discarded the pre-anchor
  backlog, so this is precisely "the audio for the first displayable frame has
  arrived"), or a ~1.24 s fallback (audio-less / PTS-less clips can't hold video
  forever — raw-ES bring-up files start video ~1.24 s late, acceptable). 2-FF into
  clk_dec.
- `resample_addrgen` **`pickup_hold`**: defers the governor's FIRST pickup
  (`ofv_pickup = output_frame_valid && !(pickup_hold && !video_live)`, applied
  atomically to every pickup-conditioned block). Once `video_live` is set the hold can
  never stall mid-play. The deferred frame parks in the framestore; the VBUF flood
  cushion buffers the stream lead — which is exactly the STD steady state: the demux
  front stays ~a mux-depth ahead of the display from then on, so audio for the
  on-screen moment is always already delivered.
- **A rising edge of `pickup_hold` re-arms `video_live`** — a clip reload now behaves
  exactly like a cold start (video_live was sticky-forever; the user measured warm
  loads much worse).
- `dvd_audio_decode`'s scheduled release now also waits for **`video_live`**, so audio
  playback begins together with the (held) video start, against the just-unfrozen STC.
  Not circular: the video hold releases on audio *arrival*, the audio release on video
  *display*.

Verified: new `bench/dvd/pickup_hold_tb.sv` (held/parked → release/pickup →
reload re-arm → resume); `dvd_audio_decode_tb` C1 extended with the video_live hold;
C1-C5 + cadence TBs green.

#### v5.2 — hold-frame transitions: the hold now HOLDS the frame, not black (2026-07-30, ✅ HW-CONFIRMED, PR fj#148)

The v5 hold gated only `ofv_pickup`, not `ofv_paced` — so on every title-domain
jump/seek (the hold re-arms per load) the governor's `STATE_REPEAT` saw a due frame,
fell into `STATE_INIT`, and PARKED there with the pickup gated: **zero image scans →
pixel_queue drains → mixer default black**. That was the "few black frames between
clips" on interactive/game discs (menus never showed it because emu forces the hold
off while `menu_active` — which is why menu→menu was already seamless). The display
has always had the right primitive — the persistence re-scan re-emits `last_image`
from DDR3 every refresh (no flush touches the frame slots) — the hold just knocked
the FSM out of it.

Fix (mirrors the HW-proven `pause` freeze-frame treatment, 4 lines):

- `resample_addrgen`: shared `hold_freeze = pickup_hold && ~video_live` now gates
  **both** `ofv_paced` and `ofv_pickup` → `STATE_REPEAT` keeps taking the persistence
  branch for the whole hold: the last clip's final frame stays on screen until the
  audio catches the new anchor, then one clean pickup of the new clip. Cold start is
  unchanged by construction (persistence needs `last_image != NO_OUTPUT` → parks
  black until the first-ever frame, as before). Release timing, `video_live`
  sequencing, and A/V alignment are untouched — only what's on screen during the
  hold changes.
- `resample_addrgen` `late_raw` gains `~hold_freeze`: hold-window lateness is
  mux-lead policy, not decode debt — without this, lates banked drop debt once the
  refilling VBUF passed `vbuf_healthy` but before the new clip's first frame decoded,
  dropping B-frames right at clip start.
- `mpeg2video.v` watchdog mux: `(pause | freeze_wd | (pickup_hold & ~video_live))
  ? 31 : repeat_frame` — the frozen governor stalls the decoder (picbuf → VBUF full →
  busy) and the watchdog fires at ~410 ms, SHORTER than the 1.24 s hold fallback; its
  `sync_rst` would wipe `last_image` → black + re-lock, defeating the hold. Same
  native freeze-suppress pause/stills use; bounded by the 1.24 s fallback.

Verified: `pickup_hold_tb` extended (cold hold = no scans; reload hold = continuous
re-scan in both the starved and frame-waiting phases, `max_gap` bounded, zero
`frame_late`, old frame kept in `output_frame_sav` until release; run against the
pre-fix RTL it fails exactly as diagnosed — scans stop with a frame waiting, a late
fires during the starved window). `gov_field_late_tb` gained a [HOLD] case (field
path: re-scan live, zero debt banked, 1:1 late accounting resumes post-release).
Known accepted residuals (HW watch items): ≤2 stale reorder frames from picbuf drain
at release (same old clip as the held frame — expected to read as "hold, then cut"),
possible partial overwrite of the held frame by the new clip's first I-frame (same
exposure as pause, which is HW-clean), and a distorted hold on a cross-geometry jump
(rare on one disc; contingency = fall back to black when live dims ≠ dims at pickup).

### v5.1 — pre-anchor dispatch hold (the race that kept drift at −455 ms)

Round-6 HW: unchanged, drift still parked ≈ −455 ms. The last race: **audio packs
reach the demux BEFORE the first video PTS**, and in that window (`stc_anchored=0`)
the stale-skip has no jurisdiction — stale frames entered the decode FIFOs and the
first PTS-tagged one latched `play_pts` with a PRE-anchor value (~mux-lag behind the
anchor). `play_pts_valid` then stuck: `aud_caught` could never fire (emu's video hold
expired via its fallback), the release compare was instantly past-due at every offset,
and playback settled right back to arrival-limited. v5.1 **holds audio dispatch in
`S_IDLE` until the STC anchors** (cannot deadlock — the anchor comes from the VIDEO
side of the demux, which flows regardless of audio; a ~1.2 s fallback covers
video-PTS-less streams). Nothing stale can enter the FIFOs anymore; `play_pts` always
latches post-anchor; the v5 sequencing finally runs in order:

```
load → both sides held → STC anchors → audio dispatch opens → stale-skip discards
the pre-anchor mux backlog → play_pts = anchor-fresh → aud_caught → video pickup →
video_live → audio drain releases at stc = play_pts + av_ofs → in sync
```

**HW diagnostic note for the next round:** if MiB *still* sits late with a
working knob (positive offsets shift it later but negatives stop helping), audio is
ARRIVAL-limited beyond the mux lead — the lever is a larger `audio_ring` (BRAM), not
more scheduling.

## PTS-scheduled dispatch (2026-07-02) — SUPERSEDED by v3 above (HW-inert)

The PI slew holds the **rate** but sets the **phase** only asymptotically: with trim
clamped to ±0.5 %, a 150 ms initial phase error takes ~30 s to grind out — and worse,
once the PCM stream is flowing gaplessly the playback phase is effectively **locked at
whatever the first dispatch after a FIFO-empty period happened to be** (consumption is a
fixed 48 kHz; only slew or a discontinuity can move phase). So the start/seek phase used
to be "whenever the data showed up."

Fix — schedule dispatch by timestamp, like a real STD: `dvd_audio_decode` holds a frame
in `S_IDLE` (leaving it in the `audio_ring`) while

```
sched_hold = sched_en && stc_anchored && frame_pts_valid
             && (frame_pts - STC - lead_target) > 0            // early
             && (frame_pts - STC - lead_target) < HOLD_MAX     // ~4 s sanity
```

- **Only delays EARLY frames** — at/past schedule dispatches immediately, so audio-late
  (data-limited) behaviour is unchanged; the gate cannot add lateness.
- **Deadlock-free:** the STC advances every display refresh once anchored, so a held
  frame is always eventually released; un-anchored/PTS-less frames bypass; a PTS more
  than `HOLD_MAX` (≈4 s) ahead is treated as a discontinuity and dispatched (av_sync
  re-anchors off the accompanying video PTS). The `audio_ring` almost_full backpressure +
  ~1.2 s drain watchdog in emu remain the outer safety net.
- **Composition with the genlock:** the schedule sets phase, the PI holds rate — once the
  gate places dispatch at `STC + lead_target`, the loop sees error ≈ 0 and trims only
  residual crystal drift. `sched_en = ~status[13]`, so `O[13] Audio Genlock Off` disables
  BOTH mechanisms and stays a clean free-run diagnostic.
- In steady state (ring parked near-full by backpressure) the gate is what *times* each
  frame's release — the ring becomes a genuine presentation buffer instead of a pure
  elasticity buffer.

## STC reference (v2, 2026-07-02) — the knob-inert bug and its fix

**HW symptom (first test of the A/V Lead knob):** 0 ms and 400 ms produced identical
sync; skew was content-dependent (Matrix ≈ in sync at default, MiB far out).

**Root cause — the STC referenced the demux parse position, not the screen.** Two
compounding flaws in the original anchor logic:

1. **Anchor at parse time.** `vid_pts` is sampled where ps_demux parses it. The STC
   anchored there and started advancing immediately — but the first frame reaches the
   screen only after the buffering/pipeline fill (VBUF flood + decode + governor
   bootstrap), so the STC permanently led the true display by that content-dependent
   amount.
2. **Symmetric ±0.7 s re-anchor.** In normal play the parse position legitimately LEADS
   the display by the whole buffering window: the `audio_ring` time window (~0.6 s at
   448 kb/s AC-3 — *longer for lower audio bitrates*) plus the VBUF fill (seconds, once
   enlarged to 2 MB). Whenever that lead crossed 0.7 s, the "seek detector" snapped the
   STC forward to the demux front — repeatedly. With the STC pinned ahead of the screen,
   the audio target `STC + lead` was **unreachable** (audio can't play data that hasn't
   arrived): the PI pegged at +0.5 %, the dispatch gate never bound, and every lead value
   behaved identically — exactly the observed inert knob. The window's bitrate dependence
   is why Matrix (just under the trip point) looked near-sync while MiB (over it) was far
   out. Each spurious re-anchor also cleared the integrator, so the loop never even
   accumulated authority.

**Fix (two pieces, both in this branch):**

- **`video_live` advance gate.** New sticky level from the display governor
  (`dvd/resample_addrgen.v`: first `STATE_INIT && output_frame_valid` pickup), threaded
  `resample.v → mpeg2video.v → emu` (2-FF CDC, same pattern as `pal_det_s2`) into
  `av_sync`. The STC still anchors on the FIRST parsed `vid_pts` (≈ the first displayed
  frame's PTS) but **holds frozen until `video_live`**, then advances per refresh — so
  `STC(anchor_pts)` starts ticking when that frame is actually on screen. The
  parse-to-display offset is gone, and with it the content dependence. (Bonus: audio
  frames scheduled past the anchor now *wait for video to go live* — the gate holds them
  against the frozen STC — so audio no longer starts while the screen is still black.)
- **One-sided re-anchor.** Forward parse-lead is NORMAL buffering — never a seek inside
  the buffering horizon. Re-anchor only on a **backward** jump (> 0.7 s — impossible in
  linear play) or a forward jump past `FWD_REANCHOR_TICKS` (~15 s, beyond any plausible
  buffering; VBUF 2 MB at a low 2 Mb/s ≈ 8 s worst case). Real seeks (Phase 8) will
  flush + force a re-anchor explicitly anyway.

**Known limitations:** ~~`video_live` is cleared only by core reset~~ — OUTDATED TWICE
OVER: the v5 `pickup_hold` rising edge re-arms `video_live` on every load (a reload
behaves like a cold start), and since 2026-08-28 a file mount also fires the full flush
trio (see "Mid-play mount desync post-mortem" below). A pathological video-less program
stream never sets `video_live`, so scheduled audio would wait — covered by the existing
ring drain-watchdog (degrades to drop-on-full, video-side unaffected).

## Mid-play mount desync post-mortem (2026-08-28, `fix/mount-avsync-flush`)

**Symptom:** loading a new file while another played left audio permanently out of sync;
only a core reload between loads avoided it. **Root cause — a half-flushed pipeline:**
`start_streaming` fired `load_flush` (fresh STC anchor + `av_vid_hold`/`video_live`
re-arm) and `aud_flush` (audio cold start) but NOT the seek/VBUF flush, so 0.5–2 MB of
the OLD file's bitstream survived in the decoder. The STC anchored on the NEW file's
first `vid_pts`; the STD hold released on the new file's audio (`aud_caught`); the
governor's first pickup displayed an OLD-file frame → `video_live=1` → STC advanced →
the drain gate released NEW-file audio against a display a whole VBUF depth stale. The
skew is forward and < 15 s, so the one-sided re-anchor (by design, above) never corrects
it; the rate is locked (NCO trim retired), so it never grinds out either. A cold boot
starts with an empty VBUF — hence "fine after a core reload". This is the exact mirror
of the `il_switch` v1 lesson (VBUF-flush-only ⇒ audio ~1 s LATE; load+aud-only ⇒ audio
EARLY by the residual depth).

**THE FLUSH TRIO RULE (write it on the wall):** any playback discontinuity — mount,
title seek/jump, raster-regime switch — needs ALL THREE of `seek_flush` (VBUF discard) +
`load_flush` (demux/av_sync re-anchor) + `aud_flush` (audio cold start), except the
deliberate keep_vbuf menu-transition and aud_resync carve-outs. The trigger matrix now
lives in `dvd/flush_ctl.sv` with `bench/dvd/flush_ctl_tb.sv` locking every row.

**Film-switch skew — ⛔ ATTEMPTED AND REVERTED (same day; the skew remains a known
issue).** With `Film 24p Out = Auto` (default), the cadence detector engages the
23.976/25 Hz film raster ~2 s AFTER a menu→feature jump established sync at
59.94/50 Hz. The modeline re-walks and `TPR_Q16` muxes to the film rate, but no flush
fires on that edge (`il_switch` watches only `il_eff`) — the raster hand-off leaves a
constant phase error; HW workaround is a chapter skip (= the trio). The obvious fix — a
`filmp_eff` XOR edge ORed into `mode_switch` — **shipped briefly and BROKE T2's
menu→Play logo chain on HW**: Dolby/THX logos flap the detector, each flap fired the
trio at an arbitrary mid-stream byte position (no reader jump ⇒ no VOBU re-alignment,
unlike every other trio consumer), repeated mid-parse flushes produced garbage sequence
headers (186-wide resolution popups), a garbage 576-line parse flipped `pal_eff`
(25 Hz), and `pal_eff` feeds back into `film_want` → another `filmp_eff` edge → a
self-feeding corruption/strobe loop. `il_switch` is only safe because `il_eff` changes
~once/title — **do not re-add a bare filmp edge**. The proper fix is the planned
early-film-detect feature (a parse-front sniffer seeds the detector during the load
hold, so the raster is right BEFORE the first frame and each jump's own trio covers the
transition; a mid-title film_switch then needs hold-suppression + a post-discontinuity
holdoff, TB'd in flush_ctl_tb, with the T2 logo chain as an explicit HW gate). See
`docs/film_24p_plan.md` §13.

**Also fixed in the same pass:** `frame_drop_ctl`'s debt ledger now clears on
`flush_vbuf_eff` (it survived every discontinuity and could fire spurious B-drops from
carried-in stale lateness at the new position). `vbuf_healthy` needs no change — the
VBUF flush zeroes the fill, so the hysteresis drops it to the cold-boot state by itself.

**Considered and DEFERRED (recorded so they aren't re-derived):**
- *Cadence/film/PAL detector confidence re-arm on mount* (`resample_addrgen.v` conf_*
  accumulators, reset by `rst` only): a `pickup_hold`-edge reset would drop film lock on
  EVERY seek (~1.7 s re-lock ⇒ raster churn, and a det-driven mode_switch could re-fire
  the flush). A mount-only reset needs new plumbing CDC'd through
  mpeg2video→resample→addrgen for a bounded, self-correcting ~2 s wrong-cadence window
  on cross-cadence warm mounts. Revisit only if post-fix HW shows a residual constant
  offset there.
- *`vidfeed_cdc` reset on `pipe_rst_n`* (stale clk_sys→clk_dec ES bytes splice ahead of
  the new stream): seeks/jumps have the identical exposure today and are HW-clean (the
  decoder's start-code hunt absorbs the residue); resetting a dual-clock FIFO from a
  clk_sys-timed level adds CDC risk, and widening a flush-reset net has twice failed to
  route in this design (the aud_rst_n Error 11802 note).

**Verification:** `av_sync_tb` check `[0]` (STC frozen through 20 dead refreshes + a 1 s
parse-lead PTS without re-anchor) and `[4a/4b/4c]` (+2.2 s lead → no re-anchor; −2.2 s →
re-anchor; +16 s → re-anchor). Governor cadence TBs re-run green with the new
`video_live` port.

## Plumbing changes

- **`ps_demux`**: added `aud_frame_pts` (held = the PES PTS, already assembled in `S_PTS`) and
  `aud_frame_pts_valid` (per-PES, set at `S_PES_HDR_FLAGS2`; some PES have no PTS). The FSM is
  serial per-PES, so these are correct at `aud_frame_start`.
- **`audio_ring`**: descriptor widened to `{pts_valid, pts[32:0], len[15:0], type[1:0]}` (52 b),
  captured at frame start; surfaced as `frame_pts`/`frame_pts_valid`. **Drop logic unchanged**
  (the PES-granular drop / static-pop fix is a separate effort — see Out of scope).
- **`dvd_audio_decode`**: effective NCO increment `= NCO_INC + nco_trim` (signed); latches the
  frame PTS at dispatch (`S_POP`) and pulses `dispatch_pts`/`dispatch_pts_valid` to av_sync.
- **`emu.sv`**: instantiates `av_sync`, un-parks `vid_pts`, routes `aud_frame_pts` →
  `audio_ring` → `dvd_audio_decode` → `av_sync` → `nco_trim`, and derives `av_refresh_tick`
  from a clk_sys edge-detect on `core_v_sync`.

## Verification

- **Sim (primary gate):** `bench/dvd/av_sync_tb.sv` — STC tracking exact (150150 ticks /
  100 refreshes), control direction correct, **closed-loop convergence** with a behavioural
  audio-clock plant (drift settles near `LEAD_TARGET`, trim bounded), seek re-anchors exactly
  once. `audio_ring_tb` case 4 round-trips per-frame PTS. Regressions green incl. `ps_chain`
  (real Matrix VOB, 50,395 B identical) and `dvd_audio_decode_tb`. **Phase C of
  `dvd_audio_decode_tb` (2026-07-02) gates the PTS-scheduled dispatch:** an early frame is
  held and released exactly at `stc = pts - lead_target`; the wildly-ahead-PTS (`HOLD_MAX`),
  no-PTS, and `sched_en=0` bypasses all dispatch immediately.
  ```bash
  iverilog -g2012 -o /tmp/avs dvd/av_sync.sv bench/dvd/av_sync_tb.sv && vvp /tmp/avs
  iverilog -g2012 -o /tmp/ar  dvd/audio_ring.sv bench/dvd/audio_ring_tb.sv && vvp /tmp/ar
  ```
- **Hardware (real gate):**
  - Clean LPCM/AC-3 clip the decoder sustains: audio stays locked over a long run (no slow
    drift). `audio_ring` overflow row (overlay row 13) should stay flatter; frames row (12)
    stabilises.
  - Chapter skip / seek: clean re-anchor, no runaway.
  - **Tune `A/V Lead` (P1O[23:21])** for lip-sync: audio heard LATE → raise; EARLY → lower.
    (An earlier revision of this doc had the direction backwards.)
  - BBB (compute-bound): confirm graceful slow/under-run, not runaway desync. Pops are
    unchanged (separate fix).

## Out of scope / follow-ups

- **Static-pop drop-granularity bug** (`audio_ring` drops PES chunks, not AC-3 frames): make a
  drop AC-3-frame-aligned or `dvd_audio_decode` resync gracefully. PTS pacing reduces drop
  *frequency*; it does not make a drop silent.
- **Overlay surfacing** of `av_drift` / `av_nco_trim` / `reanchor_count`: deferred — the overlay
  is 16 fixed 4-bit-addressed rows and expanding it has destabilised builds. The debug nets are
  wired in emu and ready. First HW pass reads existing rows 12/13.
- ~~**PAL/25 fps** `REFRESH_MHZ` + governor `SHOW_N`~~ — **DONE (manual toggle).** `av_sync`
  now precomputes both NTSC (`REFRESH_MHZ`) and PAL (`REFRESH_MHZ_PAL=50000`) Q16 ticks and
  selects at runtime via the `refresh_50hz` input (driven by `status[16]`, the O[16] PAL
  toggle in emu). At 50 Hz the STC advances ~1800 ticks/refresh (90000/50) instead of
  ~1501.5; `bench/dvd/av_sync_tb.sv` check `[1p]` verifies 180000 ticks over 100 refreshes.
  The governor's `SHOW_N=2` is unchanged (50/2 = 25 fps). **Still a follow-up:** AUTO-detect
  PAL from the stream `frame_rate_code`/`vertical_size` instead of the manual toggle (needs a
  decoder output port). See `docs/roadmap.md`.
- **Per-sample PTS** threaded through the AC-3 pipeline (subtract `pcm_out` FIFO latency) — only
  if HW shows residual phase error that the `A/V Lead` knob can't absorb.
- ~~**OSD-tunable lead + PTS-scheduled dispatch**~~ — **DONE 2026-07-02** (see the
  "PTS-scheduled dispatch" section above); HW confirm + finding the right default lead
  value for NTSC film (the "audio late" symptom) is the remaining pass.

---

## Periodic mid-title A/V re-sync — analysis (2026-08-02, DEFERRED by user)

Asked after the Film-24p exact-rate fix (§ raster-rate invariant): *can we periodically
re-sync over the course of a long title, as a backstop?* Deferred pending the 1-hour HW
test of the exact raster. These are the load-bearing conclusions so a later session does
not re-derive them.

**Re-anchoring the STC periodically does NOTHING.** It is the intuitive answer and it is
wrong: the STC is a clock. Re-anchoring redefines the timebase without moving the picture
or the audio, so the A/V relationship is unchanged. Only an actuator that changes what is
*played* can correct drift.

**Actuator options — two are closed:**

| actuator | verdict |
|---|---|
| slew the audio rate (`nco_trim` PI) | ❌ RETIRED — see the NCO-trim bullet above; its entry-side set-point differs from the drain-set phase by the buffer occupancy, so the integrator grinds the correct phase away at ±0.5 % |
| skip/insert an audio frame | ❌ this is the static-pops failure mode (`docs/fabric_audio.md`, AC-3 reframer) — a non-aligned hole is an audible pop |
| **slip one video frame** (governor hold / drop) | ✅ the only viable one; both directions already exist and are HW-proven |

**Feedback signal = `av_sync.drift`** (`dispatched_aud_pts − STC`, positive = audio ahead),
already computed every refresh and currently telemetry-only. It is the *correct* signal:
the STC advances one `TICKS_PER_REFRESH` of CONTENT per refresh, so it is a proxy for
video content time, and `drift` is therefore audio-time minus video-content-time. It also
sees a raster-rate error (a slow raster makes a slow STC). `vid_err` is NOT usable here —
it compares content credit against refresh count, both of which move with the raster, so
it stays flat under a raster-rate error (it read flat all through the 24p bug).

**★ The non-obvious trap: a video slip does not move `drift` by itself.** The STC advances
per refresh regardless of *which* picture is shown, so dropping a frame changes the
displayed content without changing the STC — the loop would never see its own correction
and would run away, slipping a frame every cooldown. So the corrector **must bump the STC
by ±1 `TICKS_PER_REFRESH` at the moment it acts**:
- audio behind (`drift < 0`) → governor holds one extra refresh → av_sync SKIPS one TPR advance
- audio ahead (`drift > 0`) → governor advances one refresh early → av_sync ADDS one extra TPR

which also keeps the STC a true proxy for content. (The same identity is why
`frame_drop_ctl`'s ledger is timeline-based: an *unbooked* drop leaks display time — the
round-11 lip-sync root cause.)

**Remaining awkwardness — the speed-up direction at 24p.** With `cur_show > 1` (60 Hz) a
speed-up is just `cur_show − 1` for one frame, symmetric with the hold and decoder-free.
At 24p `cur_show` is already 1, so the only way to advance content is a decoder B-frame
drop — and `frame_drop_ctl` is instantiated with `DROP_THRESHOLD = 2` against a
`drop_cost` of 1 at 24p, so injecting debt to force exactly one drop does not net cleanly.
Resolve that before building.

**Design shape if it is built:** measure `err = drift − drift_ref` where `drift_ref` is
latched after a settle window following each (re)anchor — that makes it a pure RATE
corrector that never fights the HW-tuned `A/V Offset` and is immune to the constant
dispatch-vs-playback pipeline offset. Deadband ≥ 2 × TPR (mode-adaptive; must exceed the
1-TPR correction step or it limit-cycles, and must exceed the documented ±32–64 ms
head-vs-`play_pts` match error). Confirm sustained ~2 s, then act once and cool down ~5 s.
Put it behind a P1 toggle (bit 8, 14 or 18 are free) for an on-hardware A/B. When every
raster is exact it should never fire — that is the property that makes it a backstop
rather than a band-aid.

### Build gotcha found while shipping this (2026-08-02)

`tools/seed_sweep.sh` and `build_release.sh --compile` **fit the same project directory**
(`db/`, `incremental_db/`, `output_files/`). Running them concurrently — e.g. leaving a
sweep going and kicking off a release build — lets two `quartus_fit` processes write the
same state, and the resulting `.sof`/`fit.rpt` cannot be trusted. Note also that killing
the *shell* that launched a sweep does NOT stop it: `seed_sweep.sh` keeps running and
starts the next seed. Kill the script (and its docker container) explicitly, then wipe
`db/ incremental_db/ output_files/DVD.{fit,sta}.rpt output_files/DVD.sof` before rebuilding.
Related trap: [[seed-sweep-is-fit-only-no-ifdef]] (the sweep is fit-only against whatever
netlist `--compile` last synthesised) and the stale-`fit.rpt` trap in
[[quartus-build-flaky-routing]].
