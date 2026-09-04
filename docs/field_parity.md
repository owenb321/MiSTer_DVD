# Field-parity re-engage corrector (2026-09-02, repaired 2026-09-03, hold arm 2026-09-04)

**Status: ✅ RE-ENABLED and ✅ HW-CONFIRMED (2026-09-03, issue #41). Round 1 confirmed the
analog CRT — "this one seems to always get the fields right on the TV", where PR #40 was a
coin flip — and exposed an inverted `VGA_F1`; round 2 confirmed that fix
(`DVD_parityf1_20260903_1253.rbf`). Sim gate: `bench/dvd/field_phase_tb.sv`, RED/GREEN.**

🔧 **HOLD ARM (2026-09-04, branch `fix/field-parity-hold`): the corrector could not act
while the picture was HELD — a menu still, a warning card, a pause — because its cure is
to defer a pickup and a hold has none. Measured 360/360 held fields misaligned over a
6-second hold (the committed gate is the shorter form of that experiment). Fixed by
swapping the held pair's order for one visit; sim-proven RED/GREEN by the new
`field_phase_tb` scenario [8], ⏳ HW-confirm pending. See "The hold gap" below.**

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

## Files

- `rtl/mpeg2/mixer.v` — `frame_top_par_err` output (verdict register only; matcher
  untouched)
- `rtl/mpeg2/mpeg2video.v` — gate + `sync_reg` CDC + routing
- `rtl/mpeg2/resample.v` — pass-through
- `dvd/resample_addrgen.v` — the corrector (`alt_break` / `par_fb` / `par_armed` /
  `pickup_go` / the insertion branch), and the hold arm (`par_hold_ins` / the pair swap
  in the `STATE_REPEAT` image build)
- `bench/dvd/field_phase_tb.sv`, `bench/dvd/run_field_phase.sh` — **the gate**
- `bench/dvd/field_parity_tb.sv`, `bench/dvd/run_field_parity.sh` — the alignment view
  (kept, but it agrees with the RTL by construction: see the caveat above)
- Every TB that instantiates `resample`/`resample_addrgen` directly ties
  `.raster_par_err(1'b0)` (an unconnected input would read X into the interlaced arms)
