# The STC is a clock — free-running STC, PTS-scheduled display

> **Status (2026-09-06, branch `feature/stc-freerun`, `dev-stcfree`):**
> **Stage 0 — exact PTS→picture association + `disp_lag` telemetry — IN FABRIC,
> sim-proven, built (`DVD_stcfree_20260906_1357.rbf`), no behaviour change;
> ⏳ HW round A pending.** **Stage 1 — the display scheduler, the free-running
> STC, one clock for every consumer, menus included — IN FABRIC, sim-proven
> (`bench/dvd/run_stc_freerun.sh`); ⏳ HW round B pending.** This file is the
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

**Status: IN FABRIC, sim-proven (`bench/dvd/run_stc_freerun.sh`), ⏳ HW round B
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

## 4. HW rounds

- **Round A (Stage 0 build `DVD_stcfree_20260906_1357.rbf`, SEED 5 first roll,
  clk_dec 87.73/89.67, 91 % ALM):** `disp_lag` per mode on APOLLO_13 and MiB —
  must be per-picture stable with the known ≈ −1 s film24 / ≈ −0.2 s
  interlaced shape. ⏳
- **Round B (Stage 1):** film24 vs interlaced A/V difference ≈ 0 ± one picture
  on APOLLO_13 and MiB (`tools/av_mode_diff.py`); PAL; Thayer (field-coded);
  a VCD; seek storms; timed stills; menus — T2/MiB/Matrix transitions, Harry
  Potter stills, a menu clip with speech; passthrough through menus; Ferris
  film↔video. Then re-measure the `A/V Offset` default at 0 ms (+100 ms was
  the null of the old parse-front residual). ⏳ Manual pages (`film-24p.md`
  limitations, `settings.md` A/V Offset, `compatibility.md` 23.976 VCD, menu
  lip-sync) are updated when round B confirms, not before.
