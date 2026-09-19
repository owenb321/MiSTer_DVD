# Field-parity re-engage corrector (2026-09-02, repaired 2026-09-03, hold arm 2026-09-04)

**Status: ✅ RE-ENABLED and ✅ HW-CONFIRMED (2026-09-03, issue #41). Round 1 confirmed the
analog CRT — "this one seems to always get the fields right on the TV", where PR #40 was a
coin flip — and exposed an inverted `VGA_F1`; round 2 confirmed that fix
(`DVD_parityf1_20260903_1253.rbf`). Sim gate: `bench/dvd/field_phase_tb.sv`, RED/GREEN.**

✅ **HOLD ARM (2026-09-04, branch `fix/field-parity-hold`) — sim-proven RED/GREEN and
✅ HW-CONFIRMED 2026-09-04 (build `DVD_holdparity_20260904_1902.rbf`, SEED 5 first roll,
clk_dec 91.72/87.62): the corrector could not act while the picture was HELD — a menu
still, a warning card, a pause — because its cure is to defer a pickup and a hold has
none. Measured 360/360 held fields misaligned over a 6-second hold (the committed gate is
the shorter form of that experiment). Fixed by swapping the held pair's order for one
visit. See "The hold gap" below.**

The HW round covered all six checks the fix could plausibly have broken: the reported FOX
warning card on both HDMI Weave and the CRT, the second and third cards behind it, a
mid-movie pause, menu stills, sustained playback on compute-heavy content (the churn
budget — the failure mode that forced PR #37's withdrawal), and chapter skips (the
untouched feed-forward arm). All good.

★ **HW ROUND 1 (2026-09-03) — the corrector is right, and it exposed an INVERTED
`VGA_F1` (fixed; ✅ confirmed in round 2).** With the field phase now deterministic, HDMI Weave went from a coin flip to
**consistently combed** while the CRT became consistently correct. Two outputs disagreeing
by exactly one field is what pins this to the flag rather than to the corrector: the analog
pins never look at `VGA_F1` (the raster half-line carries the CRT's interleave), so only
HDMI can be affected by it.

`sys/ascal.vhd` samples the flag into `i_flm` at every DE rising edge, and the
write-placement decision that consumes it runs in the SAME clocked process on the field's
first active pixel — so it reads the value latched at the PREVIOUS DE rise, i.e. the last
active line of the PREVIOUS field. `i_flm='0'` then offsets the CURRENT field's base
address by one line. Net convention: **F1 = 0 on the top field, 1 on the bottom** — the
standard "F1 = second field" reading. `dvd/emu.sv` emitted the inverse
(`~core_v_pos[0]`), so ascal stored the top field in the odd rows: a pairwise line swap,
which is Weave combing on a STILL. Fixed to `core_v_pos[0]`.

⚠ **This was invisible for as long as the parity was random** — with a coin-flip phase,
HDMI was right half the time and nobody could tell a flag polarity error from the parity
bug. The comment on that line had said "polarity may need flipping on HW if the two fields
come out swapped" since it was written; determinism is what finally made the question
answerable. There is no ascal model in this repo (it is VHDL, the benches are Icarus), so
this one is HW-gated by construction — it cannot be closed in sim. Round 2 closed it.

★ **The withdrawal (PR #40) and what actually caused it.** As shipped in PR #37 the
corrector made both displayed fields carry the SAME source lines — a still measured
**+0.00** frame lines of field-to-field offset where a correct interlaced still measures
**+0.50**, i.e. a combed still under Weave and a picture that jumps a field line under
Bob, on **every** output. `par_ins` was tied 0 in `dvd/resample_addrgen.v` until this
repair.

**Root cause: the FEEDBACK arm was chasing STARVATION.** Its cure is a REPEATED field —
re-showing `last_image` is the only insertion that lands the resumed stream aligned (see
the XOR table below) — and it was firing at field rate. What made it fire that often is
the pixel queue running dry: when the mixer reaches a frame-top opportunity with no pixel
to show it displays nothing there, and every following content field lands one raster slot
later. **That is a genuine parity error**, but this core is compute-bound on heavy content
and does it repeatedly, so the "error" churns back and forth — and one repeated field per
starve is a far worse picture than the half-line offset it removes. The churn rate is
already on the record from an unrelated investigation: `docs/roadmap.md` measured governor
**lates at ~4/s on healthy content** and noted that the old derive path's field pairing was
"re-randomised several times a second" by exactly this class of event. The old hysteresis
(`par_armed` + a **4-refresh** liveness re-arm) capped insertions at one per five
refreshes — 12 repeated fields a second, which is what a still measuring +0.00 looks
like; the bench's four starvation events land inside that cap, one insertion each.

**Reproduced in RTL**, `bench/dvd/field_phase_tb.sv` scenario [6] — four framestore stalls
starving the pixel queue:

| build | repeated fields over 4 starvation events |
|---|---|
| corrector disabled (PR #40 … #41) | **0** |
| corrector as shipped in PR #37 | **4** — one per starve |
| corrector with the stability gate | **0** |

**The fix — the feedback arm only acts on a STABLE error.**

- `PAR_CONFIRM` (30 refreshes, ~0.5 s): the mixer's verdict must hold across that many
  completed image scans before an insertion. A genuine phase flip (cold start, an
  `il_switch`/aspect raster restart, an isolated underflow slip) is a **step** — it
  persists until corrected, so it heals ~0.5 s in and stays healed. Churn resets the count
  and is ignored. This also subsumes the old `par_armed`/`par_tmo` hysteresis: after an
  insertion the count restarts, so the feedback latency can never double-insert.
- `PAR_HOLD` (120 refreshes, ~2 s): a hard budget on top, so that whatever the starvation
  rate turns out to be on a given disc, a repeated field can never appear more often than
  once per two seconds. It starts saturated, so the first correction of a session is not
  delayed. Feed-forward insertions do not spend it.
- The **feed-forward arm is unchanged and ungated** — it inserts the OPPOSITE field, so it
  can never repeat one, and it must act before a wrong field displays. It is also the arm
  that handles the reported symptom (a chapter skip), which is why the repair keeps the
  reported bug fixed while removing the cure's cost.

⚠ **`bench/dvd/field_parity_tb.sv` stayed GREEN throughout the defect.** Two reasons, both
worth reading before trusting it again: its behavioural framestore returns a CONSTANT word
(no displayed pixel carries evidence of which source line it came from), and its pass
condition is the SAME EXPRESSION as the RTL's `frame_top_par_err` (it restates the design's
convention instead of checking an external one — the POST-only PGC trap again). It is kept
as the alignment view; **`bench/dvd/field_phase_tb.sv` is the gate** (see "Proof" below).

*(Historical status:)* ✅ MERGED (PR #37, 2026-09-02); ⛔ disabled in PR #40 after five HW
rounds mis-attributed the symptom to sync shape (`docs/single_raster_analog.md` §3.9); the
analog delivery under it later changed (`re_interlace` is gone, the interlaced main raster
drives the CRT directly).

## The field reports

Two independent CRT users (SuperStationOne + SuperDock → YPbPr → Sony KV-25FS120; a
second user playing The Shining), both on `Analog Out = Native Fields`:

1. *"If you skip a chapter, back or fastforward, the image becomes super aliased; you
   need to change the Analog Output option to another setting and then return, but
   sometimes you need to do it 3 or 4 times in order to work. This also happens …
   simply while watching the movie (I suspect at the beginning of each new chapter)."*
2. *"If I change analog aspect it can become jittery, almost like a screen door type
   effect. If I flip back through the aspects quickly it might fix itself again."*

"Toggle repeatedly until it fixes itself" is the signature of a **50/50 parity roll**:
each toggle re-rolls a coin and it lands right about half the time.

## Root cause

On an interlaced display the chain is: `dvd/resample_addrgen.v` emits one field image
(TOP/BOTTOM) per refresh → `pixel_queue` → `rtl/mpeg2/mixer.v` maps each image onto the
next raster field. Two facts combine into the defect:

1. **The mixer's frame-top matcher deliberately accepts either parity slot**
   (`display_first_pixel`, mixer.v — the fork's 3:2/drop "black fields" fix). A field's
   first line carries `ROW_0_COL_0` (TOP) or `ROW_1_COL_0` (BOTTOM); upstream only
   started a picture when that code matched the free-running raster parity (`v_pos==0`
   top / `v_pos==1` bottom), which emitted a black field at every 3:2/drop alternation
   break. The relaxed matcher displays every field — at whichever slot comes next. Its
   cost note ("offset ≤1 line, irrelevant for bob") predates the fieldpass CRT path.
2. **Nothing carried the raster's field parity back to the pickup decision.** The
   addrgen's schedule (`image_0..image_5`, ordered by `top_field_first`) is consumed
   one entry per refresh; authored cadence and the `STATE_REPEAT` persistence re-scan
   both preserve strict TOP/BOTTOM alternation, so in steady state content parity and
   raster parity stay locked — but **one odd perturbation flips the phase permanently**:
   every TOP image then scans out during a bottom raster field and vice versa. The whole
   picture sits one scan-line set off — "super aliased" on a field display (fieldpass
   CRT, ascal Weave), nearly invisible under ascal **Bob** (HDMI's default), which is
   why it shipped unseen.

Observed odd perturbations: a seek/flush released on an arbitrary first `tff` (the new
GOP's field order is a coin flip vs the held frame's tail — chapter skips, and natural
cell boundaries whose first GOP happens to break alternation), the `il_switch` raster
restart, an Analog Aspect walk's syncgen restart, a mixer underflow, and cold-start
luck. Toggling `Analog Out` fires the full il_switch flush = another coin flip —
exactly the users' "3–4 tries".

`re_interlace` was ruled out: in fieldpass its lock is period-based and the raster
free-runs straight through a seek — it never re-arms there and has no opportunity to
mislock.

## The fix

Closed-loop parity feedback plus a feed-forward alternation guard. Progressive display
is bit-identical by construction (every new term is qualified by `interlaced`).

- **`mixer.v`**: new output `frame_top_par_err` — a field-rate LEVEL latched at each
  accepted frame-top: 1 if the picture's first line began on the wrong raster parity.
  The relaxed matcher itself is untouched (it must stay — mid-stream 3:2/drop breaks
  still need to display).
- **`mpeg2video.v`**: gates it with `dot_interlaced` and syncs dot→clk with the
  existing `sync_reg` pattern → `raster_par_err` → through `resample.v` → addrgen.
- **`dvd/resample_addrgen.v`** — the corrector, at the pickup decision (`STATE_INIT`):
  - **Feed-forward `alt_break`**: the pending picture's first field would repeat the
    parity of the last displayed field (schedule head == `last_image`). Catches a
    seek-released tff break *before a single wrong field displays*.
  - **Feedback `par_fb`**: the mixer reports a misaligned frame-top. Catches what the
    schedule cannot see (cold start, raster restarts, underflow slips). `par_armed`
    hysteresis (one insertion per error assertion, re-armed when the level clears,
    plus a 4-refresh liveness timeout) absorbs the ~1–2-field + CDC feedback latency
    so one error causes exactly one insertion.
  - **On a trigger, defer the pickup one refresh and insert ONE field of the HELD
    frame** (persistence-style — the screen shows real content; worst cost one refresh,
    16.7 ms). Every pickup-conditioned latch rides a new `pickup_go` qualifier so the
    pending frame stays unconsumed and its schedule intact; the FSM still scans the
    inserted field.
  - A `frame_late` pulse hands the inserted refresh to the frame-drop ledger (the
    `cad_late_r` pattern); a B-drop removes an even field count on video content, so
    the reclaim can never re-break parity.

### ★ The triggers compose by XOR, and the inserted field's type depends on the trigger

This was the subtle part — the first design ("insert the opposite field on either
trigger") **livelocks on the feedback path**. Slot arithmetic (fields land on strictly
alternating raster slots; a frame-top is accepted at whichever slot comes next):

| situation | raster | content | action |
|---|---|---|---|
| `alt_break` only | aligned | breaks alternation | insert the **OPPOSITE** field — fills the slot the break would have skipped; stream stays alternating |
| `par_fb` only | misaligned | intact | re-show the **SAME** field — it lands aligned on the next slot; one junction break, absorbed by the relaxed matcher |
| both at once | misaligned | breaks alternation | **insert nothing** — two wrongs make a right: the break itself lands the new head aligned |

Hence `par_ins = alt_break ^ par_fb`. Inserting "opposite" on a `par_fb` would keep the
misalignment *and* manufacture a new alternation break for `alt_break` to un-fix on the
next pickup — an oscillation that never converges.

### Rejected alternatives

- **Strict mixer matching** (revert the relaxed matcher): re-introduces the black-field
  regression on every legitimate 3:2/drop alternation break.
- **A flush-driven discontinuity flag** (arm the corrector from `vbuf_flush` /
  `mode_switch`): misses the Analog Aspect walk (no flush is issued) and mixer
  underflow slips, and cannot see cold-start luck. The alternation break and the
  observed parity error *are* the discontinuity detectors.
- **Deriving `VGA_F1` from content instead of raster parity**: fixes only ascal's view;
  the CRT's half-line sequence is fixed alternating and cannot follow content — the
  alignment must happen at the source.

## Proof — `bench/dvd/field_phase_tb.sv` (`bash bench/dvd/run_field_phase.sh`)

The gate. Same display chain (resample + addrgen → framestore model → pixel_queue → mixer
← interlaced sync_gen) with the parity feedback loop closed exactly as in `mpeg2video.v`,
but it measures the picture instead of restating the RTL's convention:

- the behavioural framestore is **LINE-STAMPED** — every returned word carries a code that
  is constant along a source line and steps with the line number, so a displayed pixel
  names the source line it came from (`field_parity_tb` returns a constant here, which is
  why it cannot see a content-phase error at all);
- each displayed field is reduced to its first picture line's stamp, the raster field it
  landed in, and an FNV hash of every luma sample the mixer emitted;
- **A** consecutive fields must carry DIFFERENT source lines (offset ±1 — the RTL
  equivalent of the screenshot's +0.50); **B** the content repeats with period 2;
  **C** an even (top) source line must land in an even (top) raster field — and the line
  parity comes from the DATA, with source line 0 identified as the smaller of the two
  first-line stamps ever observed, so the check cannot agree with the RTL by construction.

Seven windows per run, both raster-phase arms (`+phase=0/1`): cold start at the selected
raster parity, two alternation-break seeks (the chapter skip), a clean-seek control,
soft-telecine film, **[6] four framestore stalls (starvation)**, and the recovery after
them. `+dbg` prints the per-field table.

**RED, corrector disabled (`main` at PR #40):** the coin flip, measured externally —

```
+phase=0  [1-cold-start]   PASS
          [2-seek-break]   FAIL  16/16 MISALIGNED   (the break flips the phase...)
          [3-seek-clean]   FAIL  16/16 MISALIGNED   (...and it PERSISTS through a clean seek)
          [4-seek-break-2] PASS
          [5-film-3:2]     PASS
          [6-stutter]      PASS  4 starves, 0 repeated fields
+phase=1  [1-cold-start]   FAIL  16/16 MISALIGNED   (the feedback-only case)
          [4-seek-break-2] FAIL
          [5-film-3:2]     FAIL                     (stays broken indefinitely)
```

**RED, corrector as shipped in PR #37** — every window aligned, but:

```
+phase=0  [6-stutter]  FAIL  4 starvation events cost 4 repeated field(s)  <- the HW defect
```

**GREEN, with the stability gate:** all seven windows in both arms, and [6] costs zero
repeated fields.

Also green after the change: `run_field_parity.sh` (its cold-start window's settle was
lengthened to the feedback arm's new latency — an expectation change, not a stimulus one),
`run_prefetch_chain.sh`, `gov_field_late_tb`, `resample_cadence(_rate)_tb`,
`pickup_hold_tb`, `menu_ff_tb`, `cadence_slip_tb`, `resample_persist_tb`,
`resample_addr_realstride_tb`, `film_detect_tb`.

## The hold gap (2026-09-04) — the corrector could not act while the picture was HELD

★ **The blind spot was written down as a reassurance.** "Root cause" point 2 above says
the `STATE_REPEAT` persistence re-scan "preserves strict TOP/BOTTOM alternation, so in
steady state content parity and raster parity stay locked". That is TRUE, and it is
exactly the problem: preserving alternation is what **freezes a bad phase**. A hold
neither breaks a good phase nor heals a bad one, and the corrector's only cure — defer a
pickup — needs a pickup that a hold does not have.

**Reported symptom.** A disc (`RINGER_WS`) whose first content after the mount is a
7-second FOX/FBI warning card: Weave combing on HDMI and field jitter on a CRT for the
whole card, clean the moment the movie starts. It reads as a disc bug and is not one —
the card is a single clean I-frame (720×480, `progressive_frame=1`, `tff=1`, `rff=0`,
`interlaced_frame=0` per ffprobe). Its boot chain is FP → VMGM PGC 10 (1 cell,
`still=7`) → PGC 13 (2 cells, `still=7`) → `JumpTT 22`; each cell is one I-frame and
nothing else.

**Why a still is the worst case, twice over.** It is the content most sensitive to a
one-line error (frozen dense text — every stroke combs), and it is the state in which
the corrector is most thoroughly disabled. `par_slip` requires `state == STATE_INIT &&
ofv_pickup`, but `STATE_REPEAT` returns straight to `STATE_NEXT_IMG` while a frame is
held, so `STATE_INIT` is never re-entered. For a menu still it is unreachable **by
construction**: `mpeg2video.v`'s `freeze_wd` comment records that a still is an
end-of-stream hold, so `output_frame_valid` is 0 — there is no frame to pick up, ever.
So the mount's coin-flip landing is displayed, uncorrected, for as long as the still
lasts.

**Measured** — the diagnostic form of the experiment: a `field_phase_tb` variant that
cold-starts at the `+phase`-selected raster parity, takes ONE pickup, then holds for six
seconds. (Scenario [8] below is the short, committed form of the same thing; it reports
16/16 after burning its settle cap rather than 360/360, because it stops measuring
sooner.)

| landing phase | misaligned fields during the hold | on resume |
|---|---|---|
| aligned | 0 / 360 | clean |
| misaligned | **360 / 360** | heals in ~2 fields |

### The fix — swap the held pair's order for one visit

`par_hold_ins` in `dvd/resample_addrgen.v` reuses `par_fb` **unchanged**, so the hold arm
inherits the whole stability contract (`PAR_CONFIRM` = 30 held-error refreshes,
`PAR_HOLD` = 120-refresh budget) and adds *opportunities to act*, not *permissions*. The
counters advance during a hold: `refresh_done` ticks on repeat re-scans, and the mixer
re-latches its verdict at every held field's frame top.

In the `STATE_REPEAT` image build, the pair is emitted in the other order for that one
visit ({BOTTOM,TOP} → {TOP,BOTTOM}). The junction repeats a field — an **odd** shift of
the content-to-slot mapping, i.e. the re-alignment — and on a frozen picture a repeated
field is invisible, which is why this arm is cheap where the pickup-time one is not.

⛔ **Not the obvious one-field form** (`image_0 <= last_image; image_1 <= NO_OUTPUT`).
It emits an identical stream, but two things ride on the visit being a PAIR:

1. `late_pair`/`late_ext` stretch `frame_late` to two cycles *because* a repeat visit is
   two refreshes. A one-field visit on a plain decode-stall hold would bank one refresh
   of phantom drop debt per correction — an unearned B-drop, a visible ~33 ms skip.
2. It leaves the tail on the same parity, so a `tff=1` resume re-fires `alt_break` for a
   phase already fixed. The pair swap flips the tail, so the resume is clean.

**No `frame_late` from this arm.** The addrgen free-runs against the raster: re-ordering
a held pair adds no raster field, no image scan and no STC tick (`av_refresh_tick` comes
from `core_v_sync`, not from this schedule). Nothing was retarded, unlike a deferred
pickup. Pulsing it would also land one clock after a `STATE_REPEAT` cycle — where
`late_ext` asserts — and since `frame_late` is an OR of pulses the two would merge and
*under*-bank a real late.

**Both counters clear on the insertion.** This is the anti-double-correction mechanism,
not hygiene: the verdict is 1–2 refreshes + a CDC stale, so clearing only `par_cnt` lets
the first `STATE_INIT` after the hold fire `par_fb` again on the same error and re-break
the phase it just fixed.

✅ **The arm is live in the shipped configuration** — worth checking, because it rides a
path the benches tie on by hand. `persistence` is 1 both from `regfile.v`'s hard-reset
default and from every `trick_w` write `emu.sv` makes (`[4] persistence = on`,
`[9:5] repeat_frame = 0`), in both Interlaced and Progressive. So the persistence branch
is the one a real hold takes, and the `repeat_cnt == 0` exclusion never disables the arm
in practice — nothing in the fork drives a non-zero `repeat_frame` into `resample`
(`mpeg2video.v` forces 31 only into the *watchdog*).

**Exclusions.** `~hold_freeze`: a clip-load hold belongs to the *outgoing* clip, and
spending the 120-refresh budget there could delay the incoming clip's correction by up to
2 s — the exact latency `par_age`'s saturated reset exists to avoid. `repeat_cnt == 0`
keeps the decoder's native freeze/slow-motion path bit-identical. `pause` is deliberately
**allowed**: a paused still is precisely when someone is staring at the comb, and
`av_sync` freezes the STC under pause anyway.

⛔ Also rejected: routing the hold through `STATE_INIT` (no valid frame — it parks there,
the pixel queue drains and the mixer goes BLACK, the failure `hold_freeze` was written to
prevent); re-picking-up the held frame (re-latches `cur_show` and fires the pickup into
`vid_content_refr` for a frame that never advanced, corrupting `vid_err` and the drop
reclaim to fix a cosmetic phase); an emu-side "a still is starting" hint (the error is
only observable *after* the first field displays, by which time the reader has parked).

### Gate — scenario [8], and a coverage gap it exposed in [6]

`[8-hold-heal]` breaks the phase deliberately, then holds. ★ **`force_misaligned()`
MEASURES the break and retries rather than assuming it**: a stall can eat one field or
two, so a hold scenario keyed on the cold-start landing would be vacuous on whichever
`+phase` arm happened to start aligned — which is precisely why `[7-post-stutter]` passes
on both arms today. It `$fatal`s rather than run a window that proves nothing. The settle
may spend at most ONE repeated field (this arm's churn budget), then `NCHK` **held**
fields must be clean. `[9-post-hold]` guards the resume — and **passes pre-fix**, so it
must not be mistaken for the RED.

⚠ **`[6-stutter]` did not guard the new arm at all.** Its `mem_stall` parks the FSM in
`STATE_WAIT`, which never reaches the persistence branch. It now drops
`output_frame_valid` for the duration of each stall — a compute-bound core starves the
queue and misses the frame together — so the churn budget covers both arms.

⚠ Scenario placement is load-bearing: the feedback arm needs `par_age == PAR_HOLD`, and
`[1]` is the only earlier window that spends it, so `[8]` sits after `[5]` where ~120
refreshes have elapsed. Moved earlier it would wait the budget out instead of measuring.

## Consequences for the HW symptom

- Chapter skip / FF / seek: the feed-forward guard aligns the first field of the new
  GOP before it displays — no aliasing window at all.
- Aspect changes, underflow, cold start: the feedback path heals within ~2 fields
  (~33 ms) of the first misaligned frame-top.
- The "toggle Analog Out 3–4 times" ritual is obsolete; a mode toggle still works but
  is never needed.
- Menu stills, authored warning cards and pause (2026-09-04): a hold entered misaligned
  now heals ~0.5 s in (`PAR_CONFIRM`) instead of staying wrong for the whole hold. A
  mount whose first content is a several-second still — the case that made this look
  disc-specific — is the one that needed it.

## ★ A SECOND, INDEPENDENT AXIS: WHICH SOURCE FIELD IS THE *FIRST INSTANT*

*(2026-09-18, field report on Thayer's Quest: "looks like it's not interlaced properly,
even when playing back on a CRT". Fix: `rtl/mpeg2/vld.v` `first_field_top` +
the seam in `rtl/mpeg2/mpeg2video.v`. Gate: `bench/dvd/run_field_order.sh --red`.
✅ **HW-CONFIRMED 2026-09-18** on the maintainer's CRT, build
`DVD_fieldorder_20260918_1439.rbf` (SEED 9): Thayer's Quest shows smooth motion and no
visible combing; The Matrix and a concert DVD unregressed.)*

⚠⚠ **EVERYTHING ABOVE IS ABOUT RASTER PARITY — which raster slot a field lands in.
It says nothing about TEMPORAL ORDER, and this document previously had no field-coded
case at all.** The whole model above assumes `resample_addrgen` *splits a decoded
frame* into TOP/BOTTOM images. That is true of frame-coded content. It is not the only
thing a disc can contain.

**A field-coded picture is not a split frame.** `picture_structure` 1 (TOP) or 2
(BOTTOM), rather than 3 (FRAME), means the encoder coded each field as its own
picture. `vld.v`'s `hdr_upd_slot` already fires `update_picture_buffers` once per
field *pair*, so `motcomp_picbuf` still receives one correctly woven frame — decode was
never wrong. What was lost is **which of the two fields is the earlier instant**.

### The syntax element is empty here, and the spec says so

ISO 13818-2 **6.3.10 requires `top_field_first == 0` whenever `picture_structure` is a
field picture.** It carries no information there: the display order is given by **which
parity is CODED FIRST** in the pair. `dvd/resample_addrgen.v`'s image build (`:1035-1036`
and `:1049-1050`, and `nxt_first_top` at `:493`) read `top_field_first` and nothing else,
so every field-coded picture was emitted **`BOTTOM` then `TOP`, unconditionally**.

★ **This is why the 2026-09-06 field-order work (`FIELD1_VPOS`, §3.12 of
`docs/single_raster_analog.md`) did not catch it, and was not wrong.** That work fixed
the *raster* assignment and was validated on frame-coded content. `docs/single_raster_
analog.md` already records the reason the rest of the library is insensitive:

> *"Film-sourced content barely cares — 3:2 material is progressive frames split into
> fields, so both fields of a frame are the same instant and swapping them costs the
> line assignment but **no temporal error**."*

On **true-interlaced field-coded** content the two fields are distinct instants
1/59.94 s apart, so swapping them is a real temporal inversion: the display sequence
becomes `t1, t0, t3, t2, …`.

### Measured three independent ways

| evidence | result |
|---|---|
| Bitstream, GOP-anchored pairing (`tools/video_cadence_census.py --field-order`) | **93.9–100 %** of pairs coded **TOP-first** per VTS; `tff = 0` on **100 %** of field pictures |
| ffmpeg — an independent decoder | `top_field_first = 1` on **400 / 400** frames |
| The pixels — field-sequence total variation | TOP-first zig-zag **0.043** vs BOT-first **0.625**; TOP-first 1.3–1.5× lower total variation |

Robust across four separate scenes of VTS_01 plus VTS_02 and VTS_05 (alternation
0.002–0.112 TOP-first against 0.352–0.646 BOT-first). **Control:** Thayer's VTS_09 is
frame-coded with `tff = 1`; both orderings measure identical to four decimals and the
core was already correct there — the metric discriminates *exactly* on field-coding.

### The fix is two files, and it does not add a port below the vld

`rtl/mpeg2/vld.v` derives **`first_field_top`** — on a frame picture it is
`top_field_first` exactly; on a field picture it is the parity coded first — latched at
`STATE_PICTURE_CODING_EXT0` and gated on `pic_hdr_upd`. `rtl/mpeg2/mpeg2video.v` then
feeds **motcomp's existing `top_field_first` input** from it. `motcomp_picbuf` stores it
as `output_top_field_first`, which is what `resample_addrgen` already reads — so
nothing below the vld gains a port, and the ~9 benches instantiating
`resample_addrgen` are untouched.

⚠ **The `pic_hdr_upd` gate is load-bearing.** `flags_commit` pulses at *every* picture's
coding extension, the pair's second field included — and that field's `picture_structure`
is the opposite parity, so an ungated latch clobbers the value with its own inverse on
every pair. Mutation **M2** is that arm.

### Why nothing else moves — provable, not statistical

- `top_field_at_bottom` (`vld.v:2247`, the only decode-math consumer) is explicitly
  `picture_structure == FRAME_PICTURE` gated.
- `disp_sched`'s `pic_tff` / `skip_tff` are only reached under `pic_ps` / `skip_ps` =
  **progressive_sequence**, which the spec forbids alongside field pictures. Measured on
  the disc, not merely argued: `progressive_sequence == 0` in every sequence extension
  of Thayer VTS 01/02/05/09.
- `repeat_first_field` and `progressive_frame` are 0 on field pictures by spec, so the
  `else` arm at `resample_addrgen.v:1047` is the only reachable branch.

⇒ **The only behaviour that can change is the field order of field-coded pictures.**
Sampled 296 discs (1-in-4 of the library): **291 have < 5 % field-coded content** and
cannot move at all. The affected set is the laserdisc-FMV genre — Thayer's Quest,
Mad Dog 2, Dragon's Lair II, Time Traveler, Angel And The Badman.

⚠⚠ **That count is a LOWER BOUND, and the reason is a trap worth remembering.** The
sweep sampled each disc's *largest* VTS, and Thayer's largest (VTS_09) is the one
frame-coded VTS on the disc — so it reported **Thayer itself as 0.0 % field-coded**.
That is the "Thayer trap" (`tools/video_cadence_census.py`'s own header) one level up:
the wrong **VTS**, not the wrong part of a VTS. Use `--field-order --all-vts`.

⚠ On the hand-drawn titles (Dragon's Lair II, Time Traveler) the *pixel* metric cannot
discriminate — their content carries little per-field motion, so both orderings measure
the same. The bitstream evidence is uniform across all of them and the fix is correct
for all; the **visible** benefit concentrates on genuine 60-field FMV.

### The chain is covered end to end, by two benches with different jobs — measured

`run_field_order.sh` stops at **motcomp_picbuf's output pin**: it proves the right FACT
reaches the display path. It deliberately does not reach the last link — the ordering
expression in `dvd/resample_addrgen.v:1049-1050` that turns that fact into TOP/BOTTOM
images.

★ **That link is already covered, and this was MEASURED rather than assumed.** Swapping
`image_0`/`image_1` in that branch and running `bench/dvd/run_field_phase.sh` fails
immediately and by name:

```
  field 211 MISALIGNED:   even (top) source line 0 displayed in the BOTTOM raster field
  field 212 MISALIGNED: odd (bottom) source line 1 displayed in the    TOP raster field
  [9-post-hold] FAIL ...   [6-stutter] FAIL ...
```

★★ **And the swap's failure PATTERN reproduces the whole story inside the test suite:
`[5-film-3:2]` PASSES under it** — *"16 fields, every one carries the OTHER field's lines
on the matching raster parity"* — while `[4-seek-break-2]`, `[9-post-hold]` and
`[6-stutter]` all fail. A 3:2 film arm is insensitive to field order for exactly the
reason the real library is, so the bench agrees with the field: **the one arm that cannot
see this defect is the one made of film.**

So no new arm was added there. The division of labour is worth keeping straight for
whoever touches this next:

| bench | question it answers |
|---|---|
| `run_field_order.sh` | does the *right field-order fact* reach `motcomp_picbuf`? |
| `run_field_phase.sh` | is that fact *honoured all the way to emitted pixels*? |
| `check_field_order_wiring.py` | is the one port connection between them still right? |

### Interaction with the corrector above

The emitted order flips from `B,T` to `T,B`. Both alternate, so `alt_break` stays quiet
in steady state, but the initial content/raster phase flips — so `par_fb` spends **one
inserted field** (`PAR_CONFIRM` ≈ 0.5 s) healing it once after a mode change or seek.
That is by design and is exactly what `field_phase_tb`'s invariant C guards.

⚠ **Scope across outputs, checked in the RTL rather than assumed.** `dvd/emu.sv:4515`
drives `deinterlace = ~fields_prev` while the regfile's `interlaced` bit IS `fields_prev`,
so on this core the two are exact complements and the combination `~deinterlace &&
~interlaced` never occurs. That makes the branch selection clean: a **Progressive** raster
always takes `resample_addrgen.v:1018`'s single woven `FRAME`, where no field-order
question arises; the tff-ordered branches (`:1033`, `:1047`) are reached **exactly when the
interlaced raster is up**. So the fix applies whenever `Video Output = Interlaced` (or Auto
resolving to it) — which is **both the analog CRT and HDMI**, since that mode also feeds
HDMI 480i through ascal. It is not CRT-only, and it changes nothing in Progressive.

⚠ **Telemetry semantics moved with it:** `disp_sched.sv`'s `dbg_flags` → `dvd_telem.sv`
word 14 "tff" now reads the *display-order* verdict on field-coded content, not the raw
syntax element. Do not read that bit as the bitstream value in a future HW round.

⛔ **Out of scope, deliberately:** on the progressive/HDMI path this content is woven
into a frame, which combs because the two fields are different instants. Fixing that
needs a real deinterlacer — a much larger feature, not a field-order change.

## Pause shows one field (2026-09-18, branch `fix/pause-field-still`)

**Report:** pausing on interlaced content flickers — the paused picture flips between its
two fields instead of holding still. Seen on the CRT and on HDMI 480i under Bob.

### Why it happened

While paused, `resample_addrgen`'s persistence loop (STATE_REPEAT → STATE_NEXT_IMG) keeps
re-scanning the **held picture's own two fields**, T,B,T,B… — the hold gap section above
relies on exactly that alternation to keep raster parity locked. For a film or progressive
picture it is a correct woven still: both fields are the same instant. For a
**true-interlaced** picture (`progressive_frame = 0`) they are two instants 1/59.94 s
apart, so the pause shows two different images alternating at 30 Hz. Under HDMI Weave that
is a static comb; on a CRT and under Bob it is the reported flicker.

### The fix — a field still

What a set-top player does: while paused on a true-interlaced picture, both raster slots
show **one** source field. The slot of that field's own parity shows it natively; the
opposite slot shows it **interpolated to the half-line position** that slot sits at, so the
two slots describe the same picture and Bob sees no bounce.

- `dvd/resample_addrgen.v` — `cur_ilace` latches the displayed picture's
  `progressive_frame` at the real pickup (the input describes the picture *waiting*, not
  the one held). `still_want` = paused, no step pending, field path, interlaced picture,
  `still_en`. `pin_bot` pins the field **on screen** when the pause lands (`last_image`),
  and holds it across frame steps (a run of steps shows one field of each picture).
  For the off-parity slot (`half_scan`) the walk reads the **pinned** field and emits
  **H+1** lines with one end duplicated:
  - pinned TOP in the bottom slot: `T0 … T(H-1) T(H-1)`;
  - pinned BOTTOM in the top slot: `B0 B0 B1 … B(H-1)`.
- `dvd/disp_vscale.sv` — **HALF** mode averages each of those lines with the one before
  and skips the first, giving H lines: raster line 2k+1 gets (T_k+T_k+1)/2, raster line 2k
  gets (B_k-1+B_k)/2, and the image edges clamp.
- **The frame-top tag is untouched.** `disp_y_sat` still follows `image_0`, so the mixer's
  placement, `raster_par_err`, `par_fb` and the hold arm (`par_hold_ins`) see exactly the
  stream they always did — only the source lines behind the off-parity slot change.

★ **How the mode reaches `disp_vscale`.** A scan's mode is not visible in the pixel stream,
and the resample pipeline between the two modules holds a variable number of lines. So the
addrgen pushes one bit per frame-top scan (`scan_start`/`scan_half`) into a 4-deep queue in
`disp_vscale`, which pops one per **frame-top pixel** it receives. Scans are strictly
ordered and a scan needs all its lines through the pipeline before the next starts, so no
more than two frame-tops are ever in flight.

★ **Letterbox is covered, and it had to be.** `analog_letterbox` is on for any Interlaced
session showing 16:9 content under the default `Analog Aspect = Auto`, and it applies to the
whole raster (HDMI 480i too) — so leaving it out would have left most widescreen discs
flickering. The addrgen side is identical; `disp_vscale` runs mode **M_LBH**: the same 4/3
Letterbox step with its phase advanced **half a source line**. Under Letterbox each field is
resampled on its own (output field line j ← source field line 4j/3), so the off-parity slot
must sit at 4j/3 ± ½ of the pinned field; with the duplicated end both signs become +½ on the
input line index. That needs the Bresenham remainder in **sixths** instead of thirds; plain
Letterbox only ever lands on 0, 2/6, 4/6, whose weights (0/85/171) are the ones it always
used, so it is bit-identical (the resample_chain letterbox arms are the check).

★ **Routing without reordering.** `disp_vscale` used to be a static mux: Letterbox on means
everything goes through its line buffer, off means a wire. The still switches per scan, so
the route is now chosen at each frame-top pixel — through the buffered path if Letterbox is
on, the scan is HALF, **or the buffered path has not yet drained**; the pass-through only
resumes once the buffered path is idle. A scan that arrives behind a draining one runs in a
third mode, **PLAIN** (buffered, unblended, every line emitted), so output order is kept.
Each queued pixel carries its scan's mode, so a scan keeps its mode while it drains. With
Letterbox off and no pause the buffered path never fills and the module is the same wire
as before.

### Deliberate limits

- **Film/progressive pictures keep the woven still** (full vertical resolution, already
  static). A disc that marks true-interlaced content `progressive_frame = 1` still
  flickers; the flag is the encoder's claim (the `progressive_frame` caveat in the film
  detector), and taking the still for every pause would halve the resolution of every film
  pause to cover a mis-authored minority.
- **SIF** (MPEG-1, the `sif2x` walk) is excluded; MPEG-1 has no interlaced pictures.
- **Progressive output** is untouched: it weaves the frame and never alternates.

### Gate — `bench/dvd/run_pause_still.sh --red`

`bench/dvd/pause_still_tb.sv` (`+lb=1` for Letterbox) runs the real chain (addrgen, dta, bilinear, disp_vscale,
disp_hstretch, pixel_queue, mixer, syncgen) over a **line-stamped framestore**: top line
2k returns code 8k, bottom line 2k+1 returns 8k+1, and every line the pixel queue receives
is checked for EQUALITY against the value its source position and 2-tap weight give. It
scores each scan the pixel queue receives against the exact sequence (line count and
pixels per line included, so an H+1 emission cannot pass) before the pause, while paused,
across a frame step, and after resume, for both pin parities. `+pfr=1` is the control (the
weave must survive), `+still_en=0` is the RED arm (the pre-fix behaviour), and eight
mutations each must fail. The expected value of every output line is computed from its
source POSITION (in sixths of an input line) and the 2-tap weight, so one model covers Fit,
Letterbox and both interpolated slots.

⚠ The stamp is taken at the addrgen's **issue** strobe (`disp_valid_in` /
`disp_delta_y`), not from `disp_y` at the address FIFO: the first cut sampled there and
the codes drifted by several lines per scan, because the `mem_addr` pipeline sits between
the two.

⚠ **Two geometry traps, both found by a mutation surviving.** Lines 4 codes apart could
not tell weight 43 from 85 (both round to +1), so a wrong sixths table passed (M8): lines
are 8 codes apart now. And a 64×16 field is exactly the pixel queue's 1024 pixels, so the
buffered path never backed up behind the raster and the reorder hazard could not occur —
M5 (routing without the drain-busy term) passed. The bench field is 128 wide (2048 px)
for that reason; do not shrink it to make the run faster.

**Build:** `DVD_fieldstill_20260919_0209.rbf` — SEED 9 first roll, clk_dec 92.05 @100C /
91.95 @-40C (gate 86.0), 38,514 ALMs (92 %), 500/553 RAM blocks.

⏳ **HW gate:** the maintainer's eye on the CRT and under HDMI Bob, pausing
video-sourced content (Thayer's Quest, or any title `tools/video_cadence_census.py` calls
video). A screenshot cannot show a 30 Hz alternation. Control arm first on the current
build, then the fix build; check a film pause still has full resolution, frame step, and
resume.

## Files

- `rtl/mpeg2/mixer.v` — `frame_top_par_err` output (verdict register only; matcher
  untouched)
- `rtl/mpeg2/mpeg2video.v` — gate + `sync_reg` CDC + routing
- `rtl/mpeg2/resample.v` — pass-through
- `dvd/resample_addrgen.v` — the corrector (`alt_break` / `par_fb` / `par_armed` /
  `pickup_go` / the insertion branch), and the hold arm (`par_hold_ins` / the pair swap
  in the `STATE_REPEAT` image build)
- `bench/dvd/field_phase_tb.sv`, `bench/dvd/run_field_phase.sh` — **the gate** (raster parity)
- `rtl/mpeg2/vld.v` `first_field_top` + the seam in `rtl/mpeg2/mpeg2video.v` — **temporal**
  field order on field-coded content (the 2026-09-18 section above)
- `bench/dvd/field_order_tb.sv`, `bench/dvd/run_field_order.sh` — **that gate**;
  `tools/field_order_fixture.py` cuts the fixtures, `tools/check_field_order_wiring.py`
  polices the one port connection no module bench can see
- `tools/video_cadence_census.py --field-order --all-vts` — the golden model
- `bench/dvd/field_parity_tb.sv`, `bench/dvd/run_field_parity.sh` — the alignment view
  (kept, but it agrees with the RTL by construction: see the caveat above)
- `dvd/resample_addrgen.v` `still_*`/`half_*` + `dvd/disp_vscale.sv` HALF/PLAIN modes —
  the pause field still; `bench/dvd/pause_still_tb.sv`, `bench/dvd/run_pause_still.sh`
- Every TB that instantiates `resample`/`resample_addrgen` directly ties
  `.raster_par_err(1'b0)` (an unconnected input would read X into the interlaced arms)
