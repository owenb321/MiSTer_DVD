# The STC is a clock — free-running STC, PTS-scheduled display

> **Status (2026-09-06, PR #63, `dev-stcfree`):**
> **Stage 0 — exact PTS→picture association + `disp_lag` telemetry — IN FABRIC,
> sim-proven, built (`DVD_stcfree_20260906_1357.rbf`), no behaviour change;
> ✅ HW-confirmed (superseded by the Stage 1 rounds below).** **Stage 1 — the display scheduler, the free-running
> STC, one clock for every consumer, menus included — IN FABRIC, sim-proven
> (`bench/dvd/run_stc_freerun.sh`), built `DVD_stcfree_20260906_1737.rbf` (SEED 5
> first roll after pipelining the scheduler, clk_dec 89.75/86.02); ✅ **HW-CONFIRMED 2026-09-07** (build `DVD_stcfree_20260907_1646`) after the six defects in §3.7 and §9-§11.** This file is the
> design and status record. Supersedes the timing model in `docs/av_sync.md` ("Model: a
> commercial DVD player") and the two-clocks amendment on the archived branch
> `feature/audio-delay-ddr` (never merged; its §14.9 investigation is summarised
> in §1 below).

## 1. Why

Every A/V-sync defect this core has had since the governor shipped reduces to
one sentence: **the STC counted refreshes from a parse-front anchor, and the
display never consulted a PTS after that anchor.** The picture reached the screen
whenever the governor's cadence got to it, so whatever sat between the demux and
the screen — the VBUF, 0.5–1.8 s, bitrate-dependent — became the A/V offset:

| symptom | mechanism | where recorded |
|---|---|---|
| Film 24p audio ~1 s ahead (APOLLO_13 −945 ms) | 24p raster consumes at exactly the content rate, so the start-up VBUF over-fill never drains; the STC is anchored at the parse front | archived branch §14.9.14/.21 |
| mount / `il_switch` v1 / film-engage / Video Output change skews, "cured by a chapter skip" | the STC sat on a timeline the new raster or buffer no longer matched; only a re-anchor moved it | `docs/av_sync.md` post-mortem, `single_raster_analog.md` §7, `film_24p_plan.md` §13 |
| menu clips with speech never lip-synced | menus were exempted from every hold because the parse-anchored STC stalled across `keep_vbuf` hops | `dvd_menu_refinements.md` §5c/§5d, `iec61937.md` |

The archived branch got film24 to ~−175 ms by scheduling audio against a
decoder-front proxy clock (`stc_disp`, a PTS delayed by VBUF byte position) and
designed a 2 MB DDR audio-delay ring for the rest. Its own measurement said the
residual was display-queue-occupancy dependent — not expressible as a constant.
Both treat the buffer as the problem. This design does what a set-top player
does instead: **a 90 kHz clock that just runs, and both media presented at their
PTS against it.** The 27 MHz `clk_sys` crystal derives the raster (all six
modelines dot-exact, `bench/dvd/crt_syncgen_tb.sv`), the 48 kHz audio NCO and now
the STC (27e6/300 exactly), so rate is locked by construction for all three and
the whole job is phase. Buffer depth becomes latency, not offset.

Decisions overturned, with the reason each one goes, are tabulated in the plan
summary at the head of `docs/av_sync.md`'s new section; the durable ones are:
the STC is no longer "video is the master timebase" (the stated reason — two
crystals — was false); PTS IS threaded through the decoder (a fifth picbuf
attribute beside the four that already ride the `flags_commit` discipline); the
refresh-counting governor deadline is deleted in Stage 1, not kept as a fallback.

## 2. Stage 0 — exact PTS→picture association

The MPEG rule (ISO 13818-1 2.4.3.7): a PES packet's PTS belongs to the first
access unit whose start code lies at or after the first byte of that PES
packet's payload. DVDs carry a video PTS about once per VOBU (~11 pictures —
measured on four discs, 260–372 KB per PTS); flat `.mpg`/VCD about once per
picture; bare `.m2v` never. The association is therefore POSITIONAL, and both
positions are made exact rather than approximated:

```
ps_demux ──vid_mark──▶ vidfeed_cdc (9 b) ──▶ mpeg2video ──▶ vbuf_write (packer)
   │ vid_pts                                     │  stamp = vbuf_pos.stream_pos
   └──pts_cdc──▶ (clk_dec) ─── pairing queue ────┘        = 8·(vbuf_wr_cnt + pending + push) + phase
                                                 ▼
                                          pts_assoc FIFO {pts, stamp}
                                                 ▲
   VBUF ──▶ vbuf_read_fifo ──▶ getbits (bitpos) ──▶ vld: header at bitpos, start code at bitpos-32
                                                 │
                                          tag {valid, pts, 2nd} ──▶ motcomp_picbuf slot ──▶ output_pts ──▶ resample_addrgen
```

**Write side** (`dvd/ps_demux.sv`, `dvd/vidfeed_cdc.sv`, `rtl/mpeg2/vbuf.v`,
`dvd/vbuf_pos.sv`, `rtl/mpeg2/framestore_request.v`): the demux marks the first
payload byte of every PTS-bearing video PES; the mark rides the byte through the
CDC FIFO (widened 8→9 bits) so it can never be separated from it. At the packer,
`vbuf_pos` gives that byte's eventual VBUF position exactly: words the VBW state
has written since the flush (a new monotonic `vbuf_wr_cnt`), plus words pushed
into the write FIFO and not yet written, plus the push strobe of the same cycle
(⚠ `vbuf_write` raises it the cycle AFTER a word's eighth byte, so a mark on the
very next byte would otherwise land one word early — measured −8 B by
`pts_chain_tb` and fixed there), plus the packer's byte phase (its one-hot
`loop`, exported). The PTS value crosses separately (`dvd/pts_cdc.sv`, a toggle
handshake) and may arrive before or after its mark, so `mpeg2video` pairs them
through two 4-deep in-order queues; whichever comes second completes the stamp.

**Read side** (`rtl/mpeg2/getbits.v`, `rtl/mpeg2/vld.v`): `getbits_fifo`
exports `bitpos = 64·words_loaded + cursor − 128`, the offset of the bit the vld
is looking at, counted from the same flush. Stale shifter bits at a flush read
as NEGATIVE positions, which is exactly right. The vld latches it at every
`STATE_PICTURE_HEADER`; the start code itself is 32 bits earlier (the hunt
aligned one byte onto the prefix, `STATE_START_CODE` advanced 24). That constant
is **measured, not derived**: `pts_assoc_tb [A]` requires every picture start
code to sit at the golden byte offset exactly — 57/57 on an APOLLO_13 cut,
220/220 on an ffmpeg `-f dvd` mux, delta 0..0.

**The flush** is where the two coordinates could silently diverge, and did:
up to 2^MEMTAG_DEPTH (32) VBUF reads can be in flight in the memory controller
when `vb_flush` lands, and their responses arrive AFTER `vbuf_read_fifo` was
reset. That reset is a ~192-cycle level, so on hardware the stale words land only
when the memory latency exceeds it (queued behind other traffic under load) —
then the decoder swallowed up to 256 bytes of the old stream as the first words
of the new one. Exactness must not depend on the controller's mood, so reads now carry the flush parity in their
memory tag (`TAG_VBUF`/`TAG_VBUF1`, spare code 7; the epoch flips on the flush's
RISING EDGE — the flush is a ~192-cycle level, a per-cycle toggle would flip an
even number of times) and `framestore_response` routes only the current epoch
into the read FIFO. On the write side a word popped just before the flush and
written just after it is overwritten by the next write (the pointers are held at
`VBUF` for the whole level) and not counted; the packer's partial word is not
reset, so its stale bytes occupy positions 0..phase−1 on BOTH sides — the
consistency `pts_chain_tb [C2]` measures.

**Association** (`dvd/pts_assoc.sv`): a shift-register FIFO of `{pts, stamp}`
(head in slot 0 — a register read, never an async array read). At every header
ONE single-cycle decision: pop the head if its stamp lies at or before the start
code (24-bit modular MSB-of-difference test) and that is this picture's tag.
Entries still at or before the LAST header during the picture body belong to no
picture (a PES carrying a PTS but no access-unit start; or a stamp that arrived
after the vld already passed it) and are popped and discarded: a lost tag, never
a wrong one. A 64 KB stamp rate limit keeps a per-picture-PTS `.mpg` from
overflowing DEPTH 16 across a 2 MB VBUF (DVDs at ~284 KB/PTS and ffmpeg `-f dvd`
at ~85 KB/PTS are untouched; a lost tag is extrapolated, never replaced).

**Carry** (`rtl/mpeg2/motcomp_picbuf.v`): `current_frame_pts{,_valid,_2nd}` are
latched at `STATE_UPDATE` — ordered by construction, because the tag register is
decided one cycle after the header, STATE_UPDATE lands ≥3 cycles after it
(update → mvec FIFO → picbuf), and the vld is frozen at the header until picbuf
has rotated, so the register cannot change under it: the `flags_commit`
argument. A tag on the SECOND field of a pair arrives after the rotation and is
re-latched on `pts_commit`. The attribute rides `current → prev_i_p → output`
exactly as the flags do, including `STATE_LAST_FRAME` (a menu still is
`SEQ GOP PIC:I SEQ_END`). The vld's tag register is cleared by the flush, so a
queued pre-flush picbuf update can only latch an invalid tag (the
`docs/seek_realign.md` §5.1 mvec-FIFO ordering rule).

**Also new in the vld:** `skip_ack`/`skip_rff`/`skip_field` — a pulse for every
dropped picture for EITHER reason (governor B-drop or post-flush realign), with
the dropped picture's own flags; `drop_pic_ack` stays governor-only for the
ledger. Stage 1's extrapolator needs every skipped duration.

**Telemetry** (`dvd/dvd_telem.sv` words 11–13, `main/support/dvd/dvd_ctl.cpp`):
`disp_lag` = PTS of the picture just DISPLAYED − STC, sampled at each pickup
(`resample_addrgen.disp_pts` → `pts_cdc` → clk_sys), plus `play_err` and
`av_drift`. `disp_lag` is the measurement the whole design is built on: with the
old STC it reads the whole buffering lead (≈ −1 s in Film 24p, ≈ −0.2 s
Interlaced, per the archived branch's decoder-front proxy); once the display is
scheduled by PTS it must read ~0 in every mode. HW round A checks it is
per-picture stable and has that shape BEFORE any behaviour changes.

Known, documented loss: a realign-dropped post-seek picture that carried the
tag loses it (the display anchors untagged at its first pickup and re-anchors at
the next VOBU tag, ≤ 0.5 s). Seek-only, bounded.

### Gate: `bench/dvd/run_pts_assoc.sh`

| bench | what it measures |
|---|---|
| `pts_assoc_tb` [A] | real getbits+vld over real ES: every picture start code at the golden byte offset EXACTLY (57/57 APOLLO_13; 220/220 sync VOB) |
| `pts_assoc_tb` [B] | + real `pts_assoc`: every picture's `{valid, pts}` tag equals `tools/pts_map.py`'s MPEG-rule assignment (5 marks / 16 marks) |
| `pts_chain_tb` [C1] | the REAL VBUF path (packer → write FIFO → framestore_request → latency-modelled memory → framestore_response → read FIFO → getbits → vld): pre-flush stamps and positions exact |
| `pts_chain_tb` [C2] | across a mid-run flush with reads in flight: write and read sides agree on the new stream's origin (one constant, ≤ 16 B) |
| `pts_chain_tb` [C3] | no stale-epoch response reaches the read FIFO; the hazard is asserted to have been exercised |
| `pts_chain_tb` [D] | tags through the real path match the golden in both segments |
| RED arm | `framestore_response` rebuilt from shipping source with the epoch compare removed must FAIL [C2]/[C3] |

Fixtures are cut from real media by `tools/pts_map.py` (gitignored;
`DVD_ISO_DIR` for the DVD cut, `DVD_PTS_VOB` for the Program Stream file).

## 3. Stage 1 — the display scheduler and the free-running STC

**Status: IN FABRIC, sim-proven (`bench/dvd/run_stc_freerun.sh`), ✅ **HW-CONFIRMED 2026-09-07** (build `DVD_stcfree_20260907_1646`) — HW round B
pending.** One timing path, one clock, every consumer — menus included.

### 3.1 The clock (`dvd/disp_sched.sv`, hosted in `mpeg2video`)

`stc` is a 33-bit counter of a 90 kHz tick. The tick is `clk_sys/300` exactly
(`emu.sv`, a 9-bit divider), crossed into clk_dec by a toggle: ticks are ~1000
clk_dec cycles apart, so none is ever lost. It counts while `video_live &&
!pause`. Its phase is set by ANCHORS, never slewed:

| anchor | when | value |
|---|---|---|
| provisional | the first parse-front PTS after a flush, before `video_live` | that PTS, frozen — exactly today's pre-live behaviour, so the STD mux-lead hold and the audio priming work unchanged |
| pickup | the first pickup of a TAGGED picture, or a pickup that is a DISCONTINUITY | the picture's PTS (minus a field if the tag named the second field) |
| untagged first pickup | a stream that never carried a PTS (bare `.m2v`) | 0 |

Every anchor exports its signed delta (`anchor_req`/`anchor_delta`).

**Reset domain: the VBUF flush and the decoder reset — NOT the `keep_vbuf`
pipe reset.** Across a menu→menu hop the display keeps its timeline, old-
timeline audio in the ring becomes due and drains, and the new menu's first
picture re-anchors as a discontinuity. That is what dissolves the menu
exemptions (§3.4) without re-creating the measured ~20 s passthrough stall.

### 3.2 The timeline and the due test

`next_pts` = the last displayed picture's PTS + its content duration, in
eighth-ticks (Q3, so 23.976 fps is exact). Duration = the field count the
image build uses (2/3/4/6 fields from ps/pf/tff/rff; MPEG-1 = 2) × the field
period from `frame_rate_code`, PLUS the duration of every picture the vld
dropped (`skip_ack` with the dropped picture's own flags — governor B-drops AND
post-flush realign drops). Ordering for the depth-1 display queue: an ack that
lands while a picture is waiting at the output belongs AFTER that picture and
is deferred to its pickup; otherwise it is added at once. An anchoring pickup
clears the deferred amount (realign drops all precede the anchor).

A tagged picture RESYNCS the timeline (the once-per-VOBU tag corrects any
cadence drift); an untagged one takes `next_pts`. **Due** when
`stc − pic_pts ≥ −half_scan`, where `half_scan` is half the raster's
IMAGE-SCAN period (750 ticks at 480p and per 480i field, 900 PAL, 1877 film24,
1800 film25 — `emu.sv`, from the resolved mode flags). It is the opportunity
grid, not the content period: on 480i a frame's opportunity comes after two or
three FIELD scans. `resample_addrgen`'s `frame_due` IS `sched_due`; a starved
persistence visit while `sched_next_due` holds is a late (`frame_late` →
`frame_drop_ctl`, unchanged).

**Discontinuity**: a tagged picture more than one frame BEHIND the timeline or
more than 0.5 s AHEAD of it, or more than `LATE_MAX` (350 ms) behind the clock,
re-anchors. Small gaps are waited out (an authored dropped frame); small
lateness is displayed now and recovered by the frame-drop governor, which
makes the decoder run early so later pictures WAIT — the closed loop the
refresh ledger could only approximate. `LATE_MAX` covers a reader-held still
and a cell PTS reset (otherwise every later picture is late forever); it lands
the audio in the early-side path (a gap) rather than the late-side discard.

### 3.3 The mirror (`dvd/av_sync.sv`) and the consumers

`av_sync` is now a clk_sys mirror: `{anchored, stc}` crosses on every tick
(`pts_cdc`, ≤ 11 µs stale), each anchor delta on its own crossing. Its reset
is the core reset only. Consumers of the one clock: `dvd_audio_decode` (the
drain gate, `head_stale`, `head_catchup` unchanged), `iec61937_wrap`,
`spu_decode`, the STD mux-lead hold, `nav_pci`, telemetry. `dvd_audio_decode`
re-bases `play_anchor` by each anchor delta, so a sample-continuous audio
stream across a PTS discontinuity (a menu loop, a cell boundary) is not read
as a phase error by `play_err`.

### 3.4 Menus follow the same rule

`sched_en` and `sync_armed` lost their `~menu_active`; `hl_stc_fresh` is
always 1 (the clock survives a `keep_vbuf` hop and re-anchors on the picture,
so it is always display-coherent — `nav_pci`'s settle/timer fallbacks remain
as safety nets); the STD mux-lead hold is UNIVERSAL with an audio-presence
early release: a load whose ring has received no audio frame within ~155 ms of
the anchor releases at once (menu stills, silent titles, bare ES), a load with
audio waits for it as titles always did. That is the lip-sync menu clips with
speech never had.

### 3.5 What this retired

Deleted: `av_sync`'s refresh-counted STC (`TPR_Q16`, the per-mode tick mux,
`refresh_tick`), the dead PI/`nco_trim`, the parse-front seek detector
(`vbig`); `resample_addrgen`'s `refresh_cnt` and its saturation fix,
`SHOW_N`/`show_next`/`cur_show`/`frame_due`, the film24 one-refresh override,
the `cad_acc` cadence-slip corrector, `menu_ff`; the `vid_err` instrument
(telemetry word 5 now reads 0; word 11 `disp_lag` measures the thing directly);
`emu`'s menu exemptions and `keep_vbuf` distrust of the STC. Retired benches:
`cadence_slip_tb`, `cadence_phase_tb`, `film_drift_tb`, `gov_field_late_tb`,
`menu_ff_tb`, `resample_cadence*_tb` (they tested the deleted machinery).
Demoted to safety nets: `frame_drop_ctl`'s debt ledger and drop cost, the film
detector's role in sync (`filmp_eff` only picks a raster now; §13's "flush on a
film edge" requirement is moot), `nav_pci`'s promotion fallbacks. Kept on
purpose: the persistence hold, the STD backpressure and its watchdog, every
audio hold/gate, the flush trio, `keep_vbuf` audio continuity, the field-parity
corrector (it defers pickups; composes with the due gate unchanged).

### 3.6 Gate

`bench/dvd/run_stc_freerun.sh`: the association suite (§2), `disp_sched_tb`
(13 scenarios: 3:2 on 480i and on the film24 raster, PAL, per-picture PTS, a
late decoder with governor-drop recovery, drops in both orderings, a 5 s and a
200 ms backward jump, 0.3 s gap waited out, 2 s gap re-anchored, `LATE_MAX` after a held
still, second-field tags, a PTS-less stream, pause, the provisional anchor —
every pickup scored against the scenario's TRUE PTS and the DUT's clock, never
the DUT's own wanted time, with the scripted decoder PRE-DECODED so a timeline that
runs early can show a picture early — two mutations were invisible with a
just-in-time decoder — and 5 mutations each caught by its own scenario),
`av_sync_tb` (the mirror), `dvd_audio_decode_tb`, `flush_ctl_tb`, the
telemetry bench, and the display suites re-paced with `sched_due` tied high.

## 3.7 HW rounds B and C (2026-09-06/07) — five defects, all of them mine

**Round B was reported by the maintainer, not by me: I shipped Stage 0 and Stage 1
on simulation evidence and never ran `tools/mister.py` against the rig.** Symptoms:
everything out of sync by an amount that was not fixed and that a chapter seek did
not clear; heavy judder in APOLLO_13's second chapter after seeking to it; Ferris
Bueller never switching to film and out of sync in the interview.

### (1) The film detector was DELETED by the governor surgery

`resample_addrgen`'s auto film detector (the confidence accumulators, `film_pickup`,
`rff_toggled`, and `assign film_det_ntsc/pal`) sat between the `vid_err` instrument
and the `video_live` block. The Stage 1 cut ran from one to the other and took the
detector with it. `film_det_ntsc`/`film_det_pal` were left as outputs with NO DRIVER,
which Quartus ties low, so **`Film 24p Out = Auto` could never engage** — exactly the
Ferris report. Restored verbatim from the pre-surgery commit.

⚠⚠ **`bench/dvd/film_detect_tb.sv` PASSED THROUGHOUT.** Its checker was
`task chk(input cond, ...); if (!cond) fail;` — and `!1'bz` is `x`, so `if (x)` is
false and **every check silently passed on a completely undriven verdict**. The task
now requires `cond === 1'b1` and names x/z in the failure text; verified RED (17
errors) against the dead RTL and GREEN against the restored detector. This is the
`bench-that-cannot-fail` family again, in a third disguise: not constant stimulus and
not a golden model copied from the RTL, but a **pass condition that cannot represent
"unknown"**. Any `if (!cond)` checker in this repo has the same hole.

### (2) Lateness was treated as a discontinuity (`LATE_MAX` 350 ms)

`disc_w` re-anchored the STC whenever the waiting picture was more than 350 ms late.
That is wrong in principle: **when the decoder is starved the right response is to
show the overdue picture — it is already due — and let the frame-drop governor drop
pictures so the decoder runs ahead, after which pictures WAIT and the display returns
to schedule.** That closed loop is the whole point of scheduling by PTS. Re-anchoring
instead redefines "now" as the late picture and drags the AUDIO back with it,
permanently, every time it fires. On this compute-bound core a sub-second stall is
routine (`docs/lipsync_pickup.md` measures ~4 lates/s on healthy content, and a heavy
scene starves the VBUF for longer), so it fired repeatedly at unpredictable times:
an error that varies, that a seek does not clear, and — during the post-seek re-lock,
when starvation is guaranteed — repeated backward yanks of the clock, which is the
judder. One rule explains all three of those observations.

`LATE_MAX` is now 2.7 s: past any starvation the drop path recovers from, and well
under a timed still, which is the case the rule exists for (a reader-held still parks
the display for seconds while the clock runs, and if content then resumes on a
continuous PTS neither jump test fires). Regression: `disp_sched_tb` **[8b]** — a
400 ms starvation burst must re-anchor ZERO extra times and be back on schedule after
it; mutation **M6** puts the threshold back to 350 ms and must fail [8b].

### Build

`DVD_stcfree_20260906_1932.rbf` (SEED 5 first roll, clk_dec 90.4/90.84, 92 % ALM),
with the matching Main in `MiSTer_DVD_dev-stcfree_20260906.zip`.

### (3) The pipeline I added for timing closure lost timeline advances

MEASURED on the rig (this is what the round I skipped would have caught): with
APOLLO_13 playing in Film 24p, telemetry word 11 `disp_lag` drifts **−96 ms per
second** — steadily, without bound. During the still/logo phase before playback
it reads ±8 ms, and the STC ticks at exactly 1.00× real time, so neither the
clock nor the anchor is at fault. The timeline (`next_pts`) is advancing slower
than real time, by about 9.5 %.

Cause: **`disp_sched`'s pipeline was a ROLLING one, and its correctness argument
was false.** The header said a picture "waits at the output for thousands of
cycles" so the stages would always be settled. That holds only while the display
is ahead of the content. At MAXIMUM display rate — one pickup per raster scan,
which is the normal state in Film 24p and the state after any starvation — the
pickup lands within a cycle or two of `output_frame_valid` rising, and
`resample_addrgen`'s FSM leaves `STATE_REPEAT` on a REGISTERED `frame_due` that
was computed while `pic_valid` was still 0 (and is therefore true). The pickup
then applied the PREVIOUS picture's registered duration and want value, so
`next_q3` was re-set to the value it already held: **the timeline lost that
picture's advance entirely.** About 10 % of pickups did so, which is the measured
9.5 %. Every picture is then overdue, the display free-runs at raster rate, and
the audio — slaved to a clock now running ahead of the content — drifts further
out every second. That is "everything out of sync, and not by a fixed amount".
Interlaced was less bad only because 2–3 field scans per picture usually let the
pipeline settle, which is precisely "interlaced better than 24p".

Fix: the pipeline is **edge-captured, not rolling**. `cur_fields`/`cur_pts`/
`cur_2nd`/`cur_tag` are captured on the rising edge of `pic_valid` — one stable
event per picture — the products are computed from the captured copy, and
`pic_due` is gated COMBINATIONALLY on `cur_rdy` (`pic_due_r && (!pic_valid ||
cur_rdy)`) so a pickup cannot beat the capture. Two clk_dec cycles of latency
against a ≥16 ms frame. The timing closure the pipeline bought is kept: the
arithmetic is still registered, just off a value that stops changing.

⚠ **This fix has NO SIMULATION GATE, and saying so is the point.** A faithful
model needs the picture to appear at picbuf's output in the same cycle the
display looks at it, at a realistic RATE. Two attempts are recorded in the git
history: the first deadlocked (it relied on inter-`always`-block ordering, which
Icarus does not guarantee), the second failed IDENTICALLY with and without the
fix — i.e. proved nothing, and would have been a bench-that-cannot-fail shipped
as a gate. The acceptance evidence is the measured `disp_lag` slope on hardware:
it must be flat, not −96 ms/s.

### (3b) MEASURED AFTER THE FIX — and a correction to my own diagnosis

With all three fixes in, on the rig, APOLLO_13 in `Video Output=Progressive`,
`Film 24p Out=Auto`, `A/V Offset=0ms`, settled steady state over 60 s:

| measure | reading | expected |
|---|---|---|
| refreshes per picked-up frame | 2.00054 | 2.000 |
| content display rate | 29.962 fps | 29.97 |
| audio samples per raster refresh | 800.795 | 800.800 (6 ppm) |
| `disp_lag` (word 11) | **−16.7 ms, FLAT** | a constant, not a drift |
| `play_err` (word 12) | 0.0 | 0 |
| drain-gate closures | 0 | 0 |
| lates / drops | 0 / 0 | — |

Earlier in the same run, with the raster on 23.976 Hz, `disp_lag` **converged**
from −1174 ms to −17 ms rather than drifting. The runaway is gone.

⚠⚠ **A correction to what §3.7(3) says above, because I got the second half of
that diagnosis wrong and the record should say so.** The −96 ms/s I measured on
the pre-fix build was real, and the rolling pipeline was a real defect. But my
follow-up conclusion — that the *duration model* was also wrong, because the
scheduler was applying ~62 ms where the disc says 42.0 ms — was an artefact of
**my own test**: I had forced `Film 24p Out=On`, and the material at that point
in the title is 30p/60i (studio logos, and a video-sourced section), not 3:2
film. A 23.976 Hz raster cannot present 29.97 fps content, so the display
falls behind by 20 % by construction and `disp_lag` slews at −200 ms/s. That is
the mode being misused, not the scheduler being wrong.

Two things followed from that mistake and are worth keeping:
- **The duration formula is CONFIRMED correct**, independently, against
  ffmpeg's `mpeg_field_start()` (`repeat_pict`, where fields = `repeat_pict + 2`)
  and libmpeg2's `nb_fields`: progressive_sequence ⇒ rff ? (tff ? 6 : 4) : 2;
  else frame picture ⇒ (progressive_frame && rff) ? 3 : 2; field picture ⇒ 1.
  The field period is 1/(2 × frame_rate_code rate) — 16.683 ms for an NTSC DVD,
  *including* 24p film, where the coded rate is 29.97 and the pulldown lives
  entirely in `rff`. (ffmpeg gates the 3-field case on `progressive_frame` and
  libmpeg2 does not; they can only differ on a stream that is non-conformant
  anyway. We match ffmpeg.)
- **Instrument before concluding.** Three samples of `rff` read 0 and I nearly
  called the flag broken; 45 samples showed `rff` toggling and the durations
  alternating 4504/3003 ticks exactly as they should. Telemetry words 14/15
  (`{frame_rate_code, ps, pf, tff, rff}` and the applied duration) exist because
  of this and should be the first thing read next time.

**The −16.7 ms residual is one field period, exactly, and it is CONSTANT.** That
is the pickup-to-screen latency: the scheduler releases a picture at its PTS and
the raster scans it out over the following field. It is a fixed offset, which is
what `A/V Offset` is for — unlike everything above it does not accumulate. Whether
to fold it into the scheduler (release half a field early) or leave it to the
knob is an open question, and it should be settled with the authored SYNC disc
rather than by taste.

### (4) ⛔ RETRACTED IN FULL — "a raster change is a discontinuity" (the diagnosis was wrong too; see (5))

After the three fixes above the timeline was FLAT — and sitting a constant
**−1.83 s** behind the clock, with audio (slaved to that clock) a fixed 1.83 s
ahead of the picture. It was never a runaway: it is a one-off STEP taken at the
video→film transition, which is then carried forever.

**Why the step happens.** A film engage restarts the raster (the modeline walk
keys on `il_eff | pal_eff | filmp_eff`) but deliberately fires **no flush** — a
bare `filmp_eff` edge into the flush trio broke T2's logo chain and is
explicitly forbidden (`dvd/emu.sv`, `docs/film_24p_plan.md` §13). So the clock
free-runs across a transition in which the raster restarts, the decoder re-locks
and nothing is displayed. **And at 24p the display is already at maximum rate**
— one picture per raster scan IS the content rate — so the wall time lost there
can never be worked off.

**Fix TRIED AND RETRACTED — re-anchor at the raster change.** ⛔ See (5).

**The reasoning at the time, preserved because it is exactly the trap:** This is
a re-anchor on a KNOWN EVENT, not on lateness, and that distinction is the whole
of §3.9: every reference player re-anchors on a discontinuity it can name and
none moves the clock merely because output was late. `disp_sched` watches
`half_scan` — which IS the raster, changing exactly when the modeline does — and
forces an anchor at the next TAGGED picture (anchoring on an untagged one would
re-anchor to the clock's own value and change nothing). ⚠ It touches the CLOCK
ONLY: no demux, VBUF or audio-ring reset, so it cannot reopen the T2 failure,
which was caused by flushing the parse.

**Kept as the fallback: discharge lateness by DROPPING** (`catchup_late` →
`frame_late` → `frame_drop_ctl` → a VLD B-drop), rate-limited to one request per
4 pickups and armed only past ~50 ms. That is for lateness which arrives with no
event to key on; a mode change now never reaches it.

MEASURED on the rig after this fix, APOLLO_13 launched straight into the feature
(the natural video→film transition), 100 s: **`disp_lag` −15.8 → −16.7 ms, slope
−0.01 ms/s**, `play_err` 0.0, drain-gate closures 0. ⚠⚠ **AND THE USER STILL HEARD
AUDIO 1.6 s AHEAD.** Every instrument read clean and the defect was untouched. That
is (5).

### (5) ★★ AUDIO COMMITTED ITS PHASE TO THE PROVISIONAL (PARSE-FRONT) CLOCK — the measured root cause

Report, in the exact configuration: APOLLO_13, Film 24p Auto, **Disc Menus off**,
Progressive, A/V Offset 0 — *"the audio is still 1.6 s ahead of the video"*. Reproduced
on the rig, where `disp_lag` read **−27 ms** and `play_err` **−98 ms**. Both instruments
said the player was in sync while it was 1.6 s out.

**★ First, `play_err` had been made unable to report.** It computes
`stc − play_anchor − pos_ticks`: the clock, minus the PTS playback started at, minus how
far into that audio the DAC has got — precisely how far apart the two media are. Step 4
of the plan said to *"re-base `play_anchor` by the re-anchor delta so a sample-continuous
stream across a PTS discontinuity is not misread as a phase error"*. That is true of a
genuine stream discontinuity, but it was applied at **every** re-anchor, so every
re-anchor forced `play_err` back toward zero. Removed; the reasoning is a ⛔ comment at
the site so it cannot be re-derived.

**★ Then the defect itself, MEASURED rather than reasoned.** Two 90 s captures through
`tools/mister.py launch --telem-log`, watching word 13 `av_drift` (dispatched audio PTS
− STC):

| run | raster | what av_drift did |
|---|---|---|
| Film 24p Auto | changes 59.94 → 23.976 at t≈10.9 s | decays to +98 ms, **steps to +1640 ms** at t=12.3 s, holds |
| Film 24p **Off** | 59.94 throughout, no change at all | decays to +319 ms, **steps to +1615 ms** at t=11.3 s, holds |

The second run settles it: the step happens with **no raster change**, so it is not a
mode switch, and `pickups`, `refreshes`, `lates`, `drops` and `vbuf_fill` are undisturbed
across it, so nothing stalled. `disp_lag` also reads −18 ms on both sides of the step —
**by construction**, because a re-anchor sets `stc := pic_pts` and forces that difference
to zero. `disp_lag` cannot see a re-anchor; only a clock-to-audio measure can.

**The sequence.** On a cold mount `disp_sched` anchors **provisionally** on the first
parse-front PTS, and the parse front is up to ~1.6 s ahead of the display — that lead
*is* the VBUF depth, the very thing this design exists to remove. `dvd_audio_decode`'s
drain gate released against that clock (`stc_anchored`, which the provisional anchor
sets), and **`play_anchor` is latched exactly once at release and playback is never
re-phased**. The display's first pickup was **untagged**, so it anchored to the clock's
own parse-front value and changed nothing; the first **tagged** picture then arrived and
re-anchored the clock ~1.6 s backward. Audio, already committed, stayed where it was.
Permanent, with no correcting force anywhere in the system.

> **A clock that is ahead of the display must never be the reference against which audio
> commits a one-shot phase.** Retarding the clock afterwards does not move audio: those
> samples have already left the DAC.

**Fix: a second flag, `disp_anchored`** — set only when an anchor is taken at a pickup of
a **TAGGED** picture, i.e. when the clock is genuinely on the display's own timeline.
Audio's playback release waits for that instead of `stc_anchored`.
⚠ **Not circular with the video pickup-hold.** That hold releases on audio *arrival* —
the `play_pts` latch, taken at DISPATCH, which runs freely while the drain gate is shut.
The order is dispatch → `play_pts` → `pickup_hold` releases → first pickup →
`disp_anchored` → playback releases. `aud_caught` therefore stays on `stc_anchored`, with
a comment saying why.
⚠ A stream that never yields a tagged picture (bare `.m2v`) never sets the flag and takes
the existing ~2.5 s `arm_timer` fallback, which is what it does today.

**★ The passthrough wrapper had the same trigger but not the same disease, and the
difference is worth keeping.** `iec61937_wrap` paces **every frame** against the clock
(`hold_frame` on `head_delta < 0`) instead of latching a phase once, so a backward
re-anchor costs it a hold and it re-syncs. It was still released on the provisional
anchor, which makes it emit real bursts and then hold ~1.6 s — a real→hold→real flap,
exactly the receiver-acquisition failure its own `sync_en` comment describes. It now
takes `disp_anchored` too. ⏳ HW-gate that on a receiver; the decoded path is the
user-reported case.

**★ Also retracted from (4): the backward raster re-anchor.** It was not the cause of the
1.6 s — run 2 above has no raster change and the same defect — and it is wrong on its own
terms, for the reason in the rule above. Deleted. Lateness with no event to key on keeps
its own discharge (`catchup_late` → `frame_late` → a VLD B-drop, one request per 4
pickups, armed past ~50 ms), which advances the video to meet the audio rather than
moving the clock away from it.

**Gates.** `disp_sched_tb` **[13]** asserts the flag in three parts — not set by the
provisional anchor, **not set by an untagged pickup** (the case that actually bit), set at
the first tagged one — with mutation **M9** (`disp_anchored` set on any pickup) caught by
it. `dvd_audio_decode_tb` **[C1]** gains a step that holds `disp_anchored` low with
`stc_anchored` and `video_live` both high and the schedule reached, and requires no
samples to leave; `run_stc_freerun.sh` carries a **RED arm** that rebuilds the module with
the old release condition and requires that step to fail.
⚠ **Word 15 was repurposed** from `sched_dur` (whose job, pinning the duration model, is
done, and whose picture flags survive in word 14) to the clock's own history:
`{reanchors, first_anchor_tagged, first_seen, prov_seen}`. Every instrument in this
design referenced the clock to itself, which is how two rounds in a row shipped a fix that
measured clean and was wrong.

### (6) ★★★ THE PTS NEVER REACHED THE DECODER AT ALL — the CDC was never instantiated

The round-C build was deployed and measured, and word 15 answered in one line:

    reanchors=1  first_tagged=0  first_seen=1  prov_seen=0

`prov_seen=0` — no parse-front PTS ever arrived. `first_tagged=0` — no picture ever
carried a tag. One anchor, ever, taken at an **untagged** pickup, whose `anchor_val` is
`(prov_seen ? stc : 0)` = **zero**. The clock was anchored to 0 at the first picture and
free-ran from there, for every disc, in every mode.

**Cause: `dvd/emu.sv` declared `dec_pts_in` / `dec_pts_in_valid`, wired them into
`mpeg2video`, and never instantiated the CDC that drives them.** `mpeg2video`'s own port
comment reads *"pts_in is that PTS, already crossed into clk (emu pts_cdc)"* — naming an
instance that did not exist. Quartus tied both low. One `pts_cdc #(.W(33))` fixes it.

That also explains the +1.6 s exactly, and better than (5) did: with the clock starting at
0 and audio anchoring on its own real PTS via the fallback, the offset is simply the
audio PTS at the start of playback — which is why it measured **1599.9 ms and 1601.5 ms in
two different raster configurations**, identical to within a millisecond. A dynamic
mechanism does not reproduce to 0.1 %; a stream constant does.

**★★ Why four instruments and two hardware rounds missed it, which is the lesson.**

- Not an implicit net: the wire was properly declared, so `default_nettype none` and the
  Quartus 10236 gate were both silent. Those catch a missing DECLARATION; this was a
  missing DRIVER.
- No bench sees it: `pts_assoc_tb` and `pts_chain_tb` drive `pts_in` directly and are
  byte-exact, and there is no emu-level bench. **The association was correct; it was
  simply never given anything to associate.**
- And the telemetry read healthy, because **with no tags `want_pts` falls back to the
  scheduler's own extrapolation, so `disp_lag` compares the clock against a number
  derived from the clock**. It read ≈0 and was taken as evidence the scheduler worked.

> **An instrument derived from the thing it measures reports health at exactly the moment
> that thing is absent.** Word 15 found this on its first run precisely because it reports
> the clock's own HISTORY — how many times it moved, and whether anything real ever moved
> it — rather than a difference against it.

**★ And the netlist had said so plainly all along.** The map report's register-merging
table listed `pts_assoc|tag_pts[1..32]` as *"Merged with tag_pts[0]"* — 33 bits of PTS
collapsed into one, which only happens when the input is constant. That is now a build
gate: **`tools/netlist_canary.sh`**, a short allowlist of wide registers that must not be
constant-folded, advisory on a dev build and fatal on `--release`. It is proven RED against
the broken build's own report. Same family as the dead-stripped `dsi_tbl` (16 ALMs / 0
memory bits) that the D-pad seek work had to notice by hand — but mechanical this time.

### (7) THE AUDIT — a second dead path, and two gates so this class stops being found by hand

The missing `pts_cdc` was found by an instrument. Asked whether anything else was
disconnected, the answer came from `verilator --lint-only -Wwarn-UNDRIVEN` over
**the file list in `DVD.qsf`** — not a glob, because the fork swaps
`dvd/resample_addrgen.v` in for the upstream copy and a glob lints whichever it
reaches first, i.e. possibly not the one that is built.

**★ It found a second one, in the same surgery: `frame_late` had no driver.** It is
declared `output reg` in `dvd/resample_addrgen.v`, and the cut that removed
`refresh_cnt`/`cur_show`/`cad_acc` took its `always` block with it. So the **entire
lateness → `frame_drop_ctl` ledger was dead**: `late_raw` was computed correctly and
consumed by nothing, O[12] Frame Drop could not act on a real decode miss, and the
`lates`/`drops` counters in telemetry were reporting only `sched_catchup_late` — my own
catch-up request — while looking exactly like a working governor.

Restored as `late_raw | late_ext | par_late_r`. ⚠ `late_ext` is **kept**, against the
plan, which listed the two-cycle stretch as retired: on the field path a REPEAT visit
re-scans a PAIR, so one miss costs two refreshes and the ledger must count two. Nothing
measured said to remove it, and an under-counting ledger starves exactly the drops that
PTS scheduling needs to catch a late display up. `cad_late_r` is genuinely gone with the
cadence corrector; `par_late_r` stays because the field-parity corrector stays.

**Two gates, both cheap, both proven against the real defects:**

- **`tools/lint_undriven.sh`** — fails on any declared, consumed, undriven signal, with a
  two-name allowlist for stock `hps_io`'s disabled `PS2DIV` block. Validated by running it
  against the commit before the CDC fix, where it names `dec_pts_in` and
  `dec_pts_in_valid`. Runs **before** the compile, so it costs seconds.
- **`tools/netlist_canary.sh`** — fails when a wide data register is constant-folded
  (`pts_assoc|tag_pts[1..32]` "Merged with `tag_pts[0]`"). Catches the case where a path is
  driven but by a constant, which the lint cannot see. Proven RED on the broken build's own
  map report.

Both are advisory on a dev build and fatal on `--release`.

⚠ **Deliberately NOT changed, but recorded.** `vld.pic_hdr_upd` is exported to
`mpeg2video` and consumed by nothing — `pts_assoc` pops on `hdr_pulse` and distinguishes
fields with `hdr_second` instead. It looks like a leftover probe rather than a defect
(the association is byte-exact against `tools/pts_map.py` over real disc bytes), but it is
the one place the audit could not fully clear by inspection, so it is written down: if
field-coded content mis-associates, start here. Same for `dvd_audio_decode`'s now-inert
`anchor_pulse`/`anchor_delta` ports, left in place with the ⛔ note at the old use site.

### (8) MEASURED WITH A LIVE PTS PATH (2026-09-07, build `DVD_stcfree_20260907_0335`)

SEED 5 first roll, clk_dec 91.41 @100C / 90.51 @-40C, 92 % ALM. `netlist_canary` PASS
(`tag_pts` no longer constant-folded). Same two configurations as (5), same script:

| | before (dead PTS path) | after |
|---|---|---|
| `av_drift`, Film 24p Auto | **+1599.9 ms** | **−0.3 ms** |
| `av_drift`, Film 24p Off | **+1601.5 ms** | **+0.2 ms** |
| clock history | `prov_seen=0 first_tagged=0` | `prov_seen=1 first_tagged=1` |
| re-anchors over 80 s | 1 (to zero, untagged) | 1 (to a real picture PTS) |

The clock history line is the part that is not self-referential: it says a real tagged
picture anchored the clock, rather than the clock agreeing with a number derived from it.

**★ And the A/V Offset default should now be 0 ms, measured rather than assumed.** The
plan's Step 5 predicted this ("+100 ms was the null of the old parse-front residual") and
it holds exactly:

| A/V Offset | `play_err` (clock − audio playback position) | `av_drift` |
|---|---|---|
| **0 ms** | **−0.0 ms** | +100.1 ms |
| +100 ms | +99.9 ms | −0.3 ms |

At 0 ms audio plays exactly at its PTS against a clock anchored on the displayed
picture's PTS, which is the definition of correct. The +100 ms residual on `av_drift`
there is the dispatch-to-DAC latency — a real buffer, not an error. ⏳ **Not changed in
the CONF_STR yet: the default is user-visible, the verdict is ears, and changing it also
re-rolls the pinned fitter seed** (`CONF_STR` is in the netlist).

⚠ **This is telemetry, and telemetry is what was wrong twice today.** It is much stronger
evidence than before — the clock history cannot report health when the path is absent, and
`av_drift` is referenced to the audio stream's own timestamps — but the verdict is a
listening test.

### (9) MENU REGRESSION (2026-09-07) — the exemptions were load-bearing, and the deleted comment said so

HW report after (8): titles confirmed good (APOLLO_13, MiB, Ferris; no judder after a
chapter skip) and **four interactive discs regressed** — Thayer's Quest and Tomb Raider
froze before reaching a menu, Harry Potter Interactive and Scene It lost their highlights
(Scene It reporting no highlight TARGETS at all).

**Both classes came from two Stage-1 changes, and in each case the text that was deleted
or overridden had already described the failure.**

1. **`av_vid_hold`'s `menu_active` force-off.** Stage 1 removed it and substituted an
   escape that fires only when NO audio has arrived (`!aud_seen && tmr[22]`, ~155 ms).
   Menus with an intro, a logo chain or background music HAVE audio, so for exactly those
   the full ~1.24 s hold returned — **per `keep_vbuf` hop**, and hops can arrive faster
   than that, so it never released. The deleted comment: *"freezing deep menus (numbers
   never picked up) and keeping video_live=0 (which blocks the highlight render gate +
   nav_pci fallback)"* — which is both reported classes in one sentence.
2. **`hl_stc_fresh` tied to 1.** That makes `nav_pci`'s `stc_trusted` permanently true, and
   `nav_pci`'s own comment records the cost: a stale per-VOBU `ss=0` DISARM is then
   perpetually due, and `off_due` OUTRANKS `nxt_due` in the apply block, so it clears arms
   and starves promotions. That is "no highlight targets present" — a teardown, not a
   render failure. ★ Display-coherence is necessary to trust the clock, **not sufficient**:
   an HLI's `s_ptm` belongs to the timeline its NAV pack was parsed on, and a `keep_vbuf`
   hop crosses timelines without a flush.

**MEASURED, before → after (`DVD_stcfree_20260907_1249`, SEED 5, 93.18/92.01):**

| | before | after |
|---|---|---|
| Tomb Raider pickups in 60 s | 410, then **0/s from t≈32 s** (`video_live`=0, `av_drift` frozen) | **1313, never stalls**, `video_live` high throughout |
| Thayer pickups / `av_drift` | 928 / **+1500 ms** | 1357 / **+270…+465 ms** |
| Harry Potter highlight | absent | **present, and MOVES on a D-pad press** (screenshot A→B) |

★ The highlight was verified by **pressing Down and watching the underline move from
"Play Game" to "Trailers"** — an interactive check that touches no core-derived
instrument, which is the standard this session had to learn.

⚠ **STILL OPEN: menu AUDIO scheduling.** `sched_en`/`sync_armed` keep their menu
exemption removed (that is what the maintainer asked for), but menus re-anchor the clock
**4–6 times a minute** — every `keep_vbuf` hop, cell and PGC boundary — and **nothing
re-times audio across a re-anchor**, so each one leaves a step the system cannot heal.
`play_err` is correspondingly meaningless there (Thayer mean −3123 ms; Tomb Raider ranging
−3562…+4975 ms): it accumulates the sum of every clock jump since its one-shot anchor.
⛔ Do NOT "fix" that by re-basing `play_anchor` on a re-anchor — see (5); that hides a real
title-domain error. Menu lip-sync needs either far fewer re-anchors or a genuine audio
re-time at one, and neither exists yet. The fallback, if the offset is still audible, is to
restore `~menu_active` on `sched_en`/`sync_armed` and accept free-running menu audio.

### (10) THE HIGHLIGHT HALF WAS NOT THIS BRANCH — A/B'd against pre-STC `main`

Of the four discs reported after (8), **two regressions were ours and two were not**, and
the separation was made by deploying `DVD_main_20260906_0112` (`dev-main`, predating all
of this work) and reaching the same screen by the same key sequence.

| disc | verdict |
|---|---|
| Tomb Raider — freeze | **OURS. FIXED.** 410 pickups then 0/s permanently → **1313, no stall** |
| Thayer's Quest — freeze + 1.4 s | **OURS. FIXED.** `av_drift` +1500 ms → +270…465 ms, 928 → 1357 pickups |
| Harry Potter — Player Mode highlight | **PRE-EXISTING.** Identical on pre-STC: same missing highlight, same block pattern, same partial rect |
| Scene It — Play game highlight | **PRE-EXISTING.** Visually identical on pre-STC at matched timing |

★ **The Harry Potter ROOT menu highlight does work**, verified interactively: pressing Down
moved the underline from "Play Game" to "Trailers". The failing one is the screen AFTER
selecting Play Game, and it fails the same way on `main`.

**What the O[2] diagnostic says about the two pre-existing ones**, decoded from a
screenshot rather than read by eye (blocks are 16 px squares at x 8/28/48/68):

- Harry Potter Player Mode: `blk1` armed **GREEN**, `blk2` video_live GREEN, `blk3`
  subpicture shown GREEN, but **`blk7` (`hl_on_w` = armed AND FETCHED) RED** — the button
  RECORD fetch never completes, which is also why the magenta rect draws as a partial
  L instead of a box.
- Scene It Play game: `blk1`/`blk2`/`blk3`/**`blk7` all GREEN** — armed, fetched,
  subpicture shown — and still no visible recolour. That points at the coli/alpha end
  (`hl_use = hl_hit_q && (hl_a != 4'd0)`), not at promotion or delivery.

⏳ Both are real open bugs and neither belongs to this branch. Recorded here only because
this is where they were measured; they want their own issue.
⚠ **The technique is the point, and it is the one CLAUDE.md already recommends: A/B TWO OF
OUR OWN BUILDS.** Four symptoms arrived in one report, all in the menu domain, all
plausible consequences of the same change — and two of them had nothing to do with it. A
shared symptom class is not shared causation.

## 11. EVERYTHING ON ONE CLOCK (2026-09-07) — nav_pci and the captions

Asked to make the whole design uniform, an audit found exactly two presentation paths
still off the STC. Both are now on it, and both are ✅ HW-CONFIRMED
(`DVD_stcfree_20260907_1646`, SEED 5 first roll, clk_dec 94.46/89.01, 92 % ALM).

**`nav_pci` — trust that measures the clock instead of guessing.** An HLI's `s_ptm`
belongs to the timeline its NAV pack was parsed on, so comparing `stc` against it is
informative only while `stc` still measures that timeline. `nav_pci` now takes
`stc_reanchor` (`disp_sched`'s `anchor_disc`) and tracks `hli_coherent`: was this PTM
committed AFTER the clock's most recent re-anchor. That is what `stc_fresh <= ~keep_vbuf`
was reaching for and could not express — a guess about which HOPS tend to skew the clock,
made when no signal existed for "the clock moved".
⚠ **The settle/timer fallbacks STAY**, and are not redundant: they cover the incoherent
case, which is real. Tying `stc_fresh` to 1 effectively deleted them and that is what cost
Harry Potter and Scene It their highlights (§9). Gate: `nav_pci_tb` T18 requires no
scheduled promotion after a re-anchor; **T18b requires the fallback to promote it anyway**,
so coherence gates the scheduled path only and never strands a highlight.
⚠ Wired to `rephase_req`, not the rate-limited `aud_disc_rephase`: coherence is a fact
about the clock, not something to throttle.

**Captions — released by the display, not the raster.** `cc_line21`'s own comment already
had the mechanism: the pairs for a whole GOP arrive as ONE BURST at the GOP header and then
leave two per frame, so the queue's steady occupancy is a GOP (~0.5 s). Draining on raster
fields matches the RATE — same crystal — and preserves whatever phase the queue settled at,
for ever. `disp_sched` now emits a credit per display pickup carrying that picture's FIELD
count; EIA-608 is one pair per field with the 3:2 already expanded by the encoder, so
"release this many pairs" and "display this picture" are the same event.
⚠ Failure mode is deliberate: credits SATURATE so un-captioned content cannot bank them,
and a ~1 s watchdog frees the drain if a non-empty queue stops being served — worst case
degrades to the old free-running behaviour, never to silence.
⚠ **`[1]`–`[7]` of `cc_line21_tb` ALL PASS with the credit gate removed** — they grant a
credit per frame anyway, so they cannot tell display-paced from free-running. `[8]` is the
arm that makes it load-bearing, and it fails both halves without the gate.

**Three traps, all mine, all recorded at their sites:**

- The `dec_clk` toggle had **no reset**: X forever in simulation (`~X` is X) and undefined
  at power-up in silicon. Every pop blocked; it presented as a completely dead DUT.
  ★ Verilator would NOT have caught this — it 2-states X — which is the reason it is a
  fast second opinion here and not a replacement for the Icarus gate.
- `hli_commit_p`'s default clear sat before an async-reset `if`, which **Quartus refuses to
  infer** (Error 10818) while Icarus accepts it happily. Caught by the build, not by sim.
- `bench` stimulus must be driven from the **negedge** and in the **producer's** clock
  domain. Both violations made scenarios fail against correct RTL.

### What is deliberately NOT on the STC

Named so the next audit does not re-litigate them: still durations and the reader's cell
clock (raster vsyncs ÷ `disp_fps` — a WALL clock, which is what a `still_time` needs), the
HUD/seek-bar clock (DSI `c_eltm`), and every timeout (`av_vid_hold`, `DRAIN_WD`,
`arm_timer`, `vmw_tmr` — plain `clk_sys` counters, rate-exact, none of which schedules
presentation). `spu_decode`'s `menu_mode` bypass also stays: a menu subpicture is shown for
as long as the menu is up, not on an authored window.

### Still open after these fixes

⏳ **The provisional-anchor fix is BUILT AND SIM-PROVEN, NOT HW-CONFIRMED.** The evidence
for it is a hardware measurement of the DEFECT (word 13 stepping to +1.6 s and holding, in
two configurations, one with no raster change at all) plus RED/GREEN benches for the fix.
Neither of those is a measurement of the fix working. Word 15 now reports the clock's own
history — `{reanchors, first_anchor_tagged, first_seen, prov_seen}` — specifically so the
next round can say which of these actually happened instead of inferring it from the
absence of a symptom.

Expected on the next capture, in the user's exact configuration (APOLLO_13, Film 24p Auto,
Disc Menus off, Progressive, A/V Offset 0):

- `av_drift` settles near 0 and does **not** step by ~1.6 s.
- `play_err` is now an honest instrument, so if any residual remains it will show it.
- `first_tagged` says whether the first display anchor came from a real picture PTS.

★ **THE NAMED NEXT SUSPECT, if a residual survives: `head_stale`.** It is the OTHER
one-shot decision taken against the provisional clock, and it has the same shape.
`head_stale` discards arriving audio when `stc − frame_pts > 50 ms`, gated on
`!video_live` — i.e. exactly the window in which `stc` holds the parse-front value, up to
~1.6 s ahead of the display. DVD muxes audio ~470–667 ms behind video, so every frame
arriving in that window looks late against a parse-front clock and can be discarded. Audio
that is discarded is audio the display will still need, and the result is audio content
running ahead by however much was thrown away — the same symptom by a different route.

It is **NOT** changed in this round, deliberately, for two reasons. First, this project's
own rule: one behavioural delta per hardware round, or a green result names nothing.
Second, the data favours the release mechanism over this one — `av_drift` steps at the end
of its decay to zero, i.e. at the moment of RELEASE, not during the earlier discard window,
and the step size matches the parse-front lead. Gating it on `disp_anchored` would be safe
(the `play_pts` latch does not depend on skipping, so the documented deadlock is not
reachable), and `dbg_skip_cnt` is already exported, so a round that still shows a residual
can check the skip count before changing anything.

⏳ Also untouched and still open: the `iec61937_wrap` half (HW-gate on a receiver), and the
pre-existing film-detector flapping on mixed content.

## 12. THE PARSE-FRONT AUDIT (2026-09-08) — two consumers #63 changed without touching

Reported from the field on The Matrix, after #63: **the "Follow the White Rabbit" icon
flashes instead of staying solid, and there is an audio dropout at each white-rabbit
point — whether or not white-rabbit mode is entered.**

Two separate defects, one shared cause class. §11 audited which presentation paths were
still off the STC. It did not ask the other question:

> **which consumers were comparing a PARSE-FRONT value against `stc`, and therefore
> changed meaning when `stc` moved onto the display?**

Both defects here are that question's answer, and neither module was edited by #63.

### 12.1 `spu_decode` — a single bitmap committed at the parse front

`spu_decode` decodes an arriving SPU straight into its one full-frame bitmap and commits
`c_show` from the SPU PES's parse-front PTS, while visibility is
`stc >= c_show && stc < c_hide`. While `stc` LED the display by the VBUF depth a unit was
already due at commit; with `disp_lag ≈ 0` each unit now commits a window ~a VBUF depth in
the FUTURE, and the arriving unit destroys the one on screen before its authored window
has expired.

**MEASURED on the disc.** The icon is one `FSTA_DSP` at PTS 101885 and one `STP_DSP` at
866659 — **8.4975 s solid, no intermediate stop** — with the same unit re-sent
**byte-identically 8 times, 90090 ticks (1.001 s) apart**, and an HLI whose 17 records
alternate `hli_ss = 1,2,1,2…` over windows that are exactly back-to-back
(`s_ptm[n] == e_ptm[n-1]`). Solid is unambiguously the authored behaviour, and the
predicted blink period is the re-send period. `spu_decode.sv`'s own header had already
described this failure for MENUS and scoped its guard to them, ending *"Titles keep the
decode-early pipeline (their subpics are muxed near their PTS and are NOT re-sent)"* —
false for an in-title HLI button graphic, which is authored exactly like a menu's.

The rabbit escapes the menu guard because `menu_mode` rides `nav_pci.hli_seen`, which
requires **more than one button** (`nxt_btn_ns > 1`); the rabbit is a single `fosl=1`
button.

⚠ **The same defect quietly truncates every ordinary subtitle** — line B arrives a VBUF
depth early and blanks line A before A's window ends. Nobody reported it because dialogue
gaps usually exceed the lead.

**Fixed at the mechanism, not with another `menu_mode` exemption.** The RLE decode is the
only destructive step and `DCSQ_END` is its single entry point, reached with `w_show` /
`w_hide` / DAREA / palette all known:

- a **hold** between `DCSQ_END` and `RLE_LINE`, leaving on due / a new unit start / a
  bounded ~700 ms cap;
- a **contiguity clamp** at `COMMIT`: when the author wrote no gap between the outgoing
  unit and this one, show immediately rather than invent a hole. A persistent unit (no
  `STP_DSP` ⇒ all-ones `c_hide`) is contiguous with every successor by construction, which
  is exactly the re-send chain;
- `S_IDLE` now resumes at a genuine unit start (`sp_frame_start && sp_pts_valid`, the rule
  `S_DRAIN` already used), because the hold lengthens the busy window.

⛔ **Double-buffering was not available**: 720×576 at 2 bpp is ~102 M10Ks for a second copy
and the design fits in 498/553 RAM blocks at 98 % ALMs.

★ **The hold's bound is MEASURED, not picked.** Cutting the hold short costs nothing (the
clamp stops it opening a hole), but being *in* the hold when the next unit arrives costs
that unit its head bytes — `spu_decode` has no backpressure onto `ps_demux`. On a real
subtitle stream consecutive units are **never closer than 1034 ms** (n=36, p10 1335 ms,
median 2369 ms; mux lead measured at ≈0, median −50 ms), so a bound below that can never
be the reason a line is lost.

**Gate: `bench/dvd/run_spu_window.sh` (+ `--red`).** Three mutations, each caught by the
arm it exists for: `red-clamp` by [A] (the icon blinks — the bench reports exactly 7 blinks
across the 7 re-sends), `red-hold` by [B] (the subtitle truncates), `red-both` by all. [D]
is the control: an authored gap must still go dark, or a fix that simply never blanks would
pass. ⚠ The RED harness **fails a mutation that does not compile**, because that proves
nothing about the bench — two arms initially "passed" on a build error.
⚠ [B] first passed against broken RTL because the watcher was armed *after* feeding line B,
sampling an already-low `sp_active`. `red-hold` is what reported it.

### 12.2 A seamless-branch junction is not a content change

`disc_rephase` (§3.7) turns the display's re-anchor into `aud_resync`, which resets
`audio_ring` **and** `dvd_audio_decode`. It was accepted on the note at `dvd/emu.sv`:
*"titles re-anchor about once per playback (MEASURED: reanchors=1 over 80 s on
APOLLO_13)"*.

**APOLLO_13 is one continuous title. A seamless-branch title is not.** Matrix VTS_02 PGCN 1
— the PLAIN movie — carries **9 interleaved cell-pairs**, the same ones as the rabbit
PGCN 6, which is why the dropout is independent of white-rabbit mode.

**MEASURED on the disc:**

| | |
|---|---|
| entering each interleaved cell (4/23/35/55/60/74/80/86/91) | the PTS **restarts near zero** — audio steps of **−2 s to −64 s** |
| the ILVU splices *inside* the block | **continuous**: 0 irregular steps in 238 AC-3 PTS samples along the real played sector walk |
| authored audio gap (`sml_pbi.vob_a[8]`) | **none** — every entry zero on every junction |
| cell category byte | **0x0e** on all nine: `seamless_play=1` AND `stc_discontinuity=1` |

So the timestamps renumber and the soundtrack plays straight through. Flushing costs ~1 s
of audio twice over: the queued ring frames are discarded, and the drain gate then cannot
re-open until the display clock walks up to a `play_pts` re-latched from the parse front.
Video runs through the silence untouched (`av_vid_hold` arms off `load_flush`, not
`aud_resync`) — the reported shape exactly.

**Fix: ask the disc.** `cell_playback_t` byte 0 bit 3 `seamless_play` is the author saying
"this cell continues the previous one". The whole byte was already in `cell_cat_mem`; only
three bits were ever decoded. `dvd_iso_reader` now exports `cell_seamless`, and
`flush_ctl` withholds the audio flush on such a cell. **The CLOCK still re-anchors** — the
display must follow a real timeline change — only the audio flush narrows, which is why
`anchor_disc` is a distinct qualifier from `disc_w` in the first place.

★ This is the direction `dvd/disp_sched.sv` already named — key on the AUTHORED event
rather than an inferred PTS step — reached from the opposite side: the backward leg does
not under-cover, it **over-covers**.
⛔ **Deliberately NOT a "was there a seek/jump recently" window**: a looping menu cell
re-anchors with genuinely restarting audio and pulses no `seek_ack`, so a navigation-event
gate would silently drop the menu case #63 was built for. `cell_seamless` is 0 in every
menu — the `menu_dom` branch of `S_CELL_LOAD2` never latches it — so menus are untouched
structurally, not by luck.

⚠ **The gate is broad inside a title and that is deliberate:** 104 of the Matrix's 106
cells are `seamless_play=1`, so within a feature the audio re-phase now fires only at the
2 authored non-seamless cells. That is consistent with the FAMILY FEUD II measurement,
where a title-domain re-phase discarded the ring and cost the host's question its middle.

**Gate: `bench/dvd/run_seamless_audio.sh` (+ `--red`).** ⚠ Two bench lessons worth keeping:
the fixture needed a **third** cell that is `seamless_play=1` but NOT `interleaved`
(byte0 `0x08`, the commonest category on a real feature — 68 of 106) because with only the
white-rabbit category bits 3 and 2 coincide and reading the wrong bit passes unnoticed —
it did. And the per-cell sample must be phased against **the reader's own `cell_i`**, not
against the delivered byte pattern: the reader runs ~2 sectors ahead of the byte stream, so
the first version of the arm compared cell N's level with cell N+1's data and failed
against correct RTL.

### 12.3 What is still open here

⏳ **Neither fix is HW-confirmed.** Both are sim-proven with RED/GREEN arms against measured
disc data.
⏳ **`nav_pci`'s `hli_coherent` is untouched and may be a second contributor to the icon.**
The icon needs the highlight as well as the subpicture (`SET_CONTR[0,0,0,0]` — the SPU is
invisible on its own), and #63 tightened `stc_trusted` from a disjunction to a conjunction
whose new term clears on every re-anchor. It should *delay* an arm rather than make it
flap, because `off_due` requires the same trust and disarms are held off too — but it is
not measured. Fixing 12.2 removes most re-anchors at these junctions and so quiets it
either way. The `O[2]` blocks separate the two on hardware: `blk1`/`blk7` flickering is
`nav_pci`; `blk1`/`blk7` steady with `blk3`/`blk8` flickering is `spu_decode`.

## 4. HW rounds

- **Round A (Stage 0 build `DVD_stcfree_20260906_1357.rbf`, SEED 5 first roll,
  clk_dec 87.73/89.67, 91 % ALM):** `disp_lag` per mode on APOLLO_13 and MiB —
  must be per-picture stable with the known ≈ −1 s film24 / ≈ −0.2 s
  interlaced shape. ⏳
- **Round B (Stage 1 build `DVD_stcfree_20260906_1737.rbf`):** film24 vs interlaced A/V difference ≈ 0 ± one picture
  on APOLLO_13 and MiB (`tools/av_mode_diff.py`); PAL; Thayer (field-coded);
  a VCD; seek storms; timed stills; menus — T2/MiB/Matrix transitions, Harry
  Potter stills, a menu clip with speech; passthrough through menus; Ferris
  film↔video. Then re-measure the `A/V Offset` default at 0 ms (+100 ms was
  the null of the old parse-front residual). ⏳ Manual pages (`film-24p.md`
  limitations, `settings.md` A/V Offset, `compatibility.md` 23.976 VCD, menu
  lip-sync) are updated when round B confirms, not before.
