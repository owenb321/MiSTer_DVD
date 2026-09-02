# Field-parity re-engage corrector (2026-09-02)

**Status: ✅ sim-proven (RED pre-fix / GREEN post-fix, `bench/dvd/field_parity_tb.sv`);
⏳ HW-confirm pending — the gate is the two field reports below (chapter skip / FF /
Analog Aspect change on a CRT in Native Fields no longer needs mode-toggling to fix).**

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

## Proof — `bench/dvd/field_parity_tb.sv` (`bash bench/dvd/run_field_parity.sh`)

The real display chain (resample + addrgen → framestore model → pixel_queue → mixer ←
interlaced sync_gen) with the parity feedback loop closed exactly as in `mpeg2video.v`.
The checker reads **the wire the defect lives on**, hierarchically into the unmodified
mixer: at every accepted frame-top, content field type (`position_in_0`) must match
raster parity (`v_pos`) — it asserts what the screen gets, not a corrector register.
Five windows per run: cold start (at a `+phase`-selected raster parity), two
alternation-break seeks (the chapter-skip model), a clean-seek control, and soft-telecine
film with authored tff toggling (the corrector must stay silent). Both `+phase` arms run.

**RED (pre-fix RTL, `--red`; captured 2026-09-02 against pre-fix
`resample.v`/`resample_addrgen.v`/`mixer.v` extracted from main)** — the coin flip,
verbatim:

```
+phase=0  [1-cold-start]  PASS  16/16 aligned        (lucky landing)
          [2-seek-break]  FAIL  16/16 MISALIGNED     (the break flips the phase...)
          [3-seek-clean]  FAIL  16/16 MISALIGNED     (...and it PERSISTS through a clean seek)
          [4-seek-break-2]PASS  16/16 aligned        (only another break flips it back)
          [5-film-3:2]    PASS  16/16 aligned
+phase=1  [1-cold-start]  FAIL  16/16 MISALIGNED     (unlucky landing — the feedback-only case)
          [2-seek-break]  PASS  16/16 aligned        (two wrongs make a right)
          [3-seek-clean]  PASS  16/16 aligned
          [4-seek-break-2]FAIL  16/16 MISALIGNED
          [5-film-3:2]    FAIL  16/16 MISALIGNED     (stays broken indefinitely)
```

Misalignment is a persistent STATE that perturbations toggle — which is precisely why
the users' "change the setting and change it back, sometimes 3–4 times" ritual worked:
each toggle re-rolled the coin.

**GREEN (fixed RTL)**:

```
+phase=0: all 5 windows 16/16 aligned; worst settle window 0 misaligned tops
          (feed-forward: not a single wrong field ever displayed)
+phase=1: all 5 windows 16/16 aligned; worst settle window 2 misaligned tops
          (the misaligned cold start — feedback corrects within its designed
           ~2-field latency bound, then stays aligned)
```

Also green after the change: `run_prefetch_chain.sh` (progressive chain unchanged),
`gov_field_late_tb` (its stimulus needed a real-disc fix: tff must toggle after an rff
picture — holding it constant is an authored-cadence break the corrector now rightly
handles), `resample_cadence(_rate)_tb`, `pickup_hold_tb`, `menu_ff_tb`,
`cadence_slip_tb`, `resample_persist_tb`, `resample_addr_realstride_tb`,
`run_film_evidence.sh`.

## Consequences for the HW symptom

- Chapter skip / FF / seek: the feed-forward guard aligns the first field of the new
  GOP before it displays — no aliasing window at all.
- Aspect changes, underflow, cold start: the feedback path heals within ~2 fields
  (~33 ms) of the first misaligned frame-top.
- The "toggle Analog Out 3–4 times" ritual is obsolete; a mode toggle still works but
  is never needed.

## Files

- `rtl/mpeg2/mixer.v` — `frame_top_par_err` output (verdict register only; matcher
  untouched)
- `rtl/mpeg2/mpeg2video.v` — gate + `sync_reg` CDC + routing
- `rtl/mpeg2/resample.v` — pass-through
- `dvd/resample_addrgen.v` — the corrector (`alt_break` / `par_fb` / `par_armed` /
  `pickup_go` / the insertion branch)
- `bench/dvd/field_parity_tb.sv`, `bench/dvd/run_field_parity.sh` — the suite
- Every TB that instantiates `resample`/`resample_addrgen` directly ties
  `.raster_par_err(1'b0)` (an unconnected input would read X into the interlaced arms)
