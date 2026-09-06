# The STC is a clock — free-running STC, PTS-scheduled display

> **Status (2026-09-06, branch `feature/stc-freerun`, `dev-stcfree`):**
> **Stage 0 — exact PTS→picture association + `disp_lag` telemetry — IN FABRIC,
> sim-proven, no behaviour change; ⏳ HW round A pending.**
> Stage 1 (the display scheduler, the free-running STC, one clock for every
> consumer, menus included) — 🔧 next. Plan: `~/.claude/plans/` is not the record;
> this file is. Supersedes the timing model in `docs/av_sync.md` ("Model: a
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
reset — the decoder used to swallow up to 256 stale bytes of the old stream as
the first words of the new one. Reads now carry the flush parity in their
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
a wrong one. A 128 KB stamp rate limit keeps a per-picture-PTS `.mpg` from
overflowing DEPTH 16 across a 2 MB VBUF.

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

🔧 Not yet built. Design as approved in the plan: `dvd/disp_sched.sv` (clk_dec)
owns the master STC (+1 per 90 kHz tick, gated by `video_live` and pause; reset
domain = VBUF flush and mount only, NOT the `keep_vbuf` pipe reset), extrapolates
`next_pts` from the displayed picture's flags and `frame_rate_code` plus
`skip_ack` durations, picks up when `stc − pic_pts ≥ −half_scan` (half the
image-SCAN period of the raster: 750 / 900 / 1877 / 1800 ticks), re-anchors on a
tagged discontinuity (< −1 frame, > +0.5 s) or on `LATE_MAX` lateness; no cadence
fallback (a PTS-less stream anchors at its first pickup and is scheduled by
extrapolation). `av_sync.sv` becomes a mirror + telemetry; every consumer reads
one `stc`; the menu exemptions go and the STD hold becomes universal with an
audio-presence early release. The retirement list is in the plan and will be
recorded here when it lands.
