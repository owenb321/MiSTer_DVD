# Post-seek reference re-align (issue #45)

> **Status: ✅ FIXED and HW-CONFIRMED 2026-09-03** (build
> `DVD_seekrealign_20260903_1901.rbf`, SEED 5 first roll, clk_dec 91.10/88.28).
> Sim-proven RED/GREEN first; the hardware round then reported exactly the predicted
> outcome — see §5.
> Branch `fix/seek-reference-realign`. RTL: `rtl/mpeg2/vld.v` (+ one port connection
> in `rtl/mpeg2/mpeg2video.v`). Gate: `bench/dvd/run_seek_realign.sh`.
> Engineering note — the user-facing statement lives in
> `site/content/reference/troubleshooting.md`.

## 1. The report, and the one detail that identifies it

Every seek — chapter skip (B2/B3), Fast Fwd / Rewind scrub release, D-Pad Seek (`O[45]`),
menu → Play — shows a short burst of macroblocking as playback resumes. Measured from a
60 Hz HDMI recording: **~6 frames (~100 ms)**. From the same recording:

> *"The macroblocks are a mix of the previous scene and the one we're seeking to. Worth
> noting that the target chapter is decoding and in motion during this macroblocking, but
> it has the residual image overlayed."*

★ **That is the whole diagnosis.** The new content decoding *and moving* rules out the
reader, the demux and the landing point: the stream is correct and the picture is being
built. Only the **prediction** is wrong. A corrupt or truncated picture would be a single
still-wrong frame, not a burst with coherent new motion. So the artefact is motion
compensation against reference frames from where we *were*, and the question is why the
decoder still has them.

Scope: all four transport paths, every disc tried. Not authoring-dependent, so it belongs
to the shared flush contract rather than to any one path.

## 2. Root cause

`flush_vbuf_eff` (`rtl/mpeg2/mpeg2video.v:865`) reaches exactly three sinks:

| sink | line | what it clears |
|---|---|---|
| `vbuf_rst` | :870 | the circular video buffer's write/read FIFOs |
| `frame_drop_ctl.flush` | :1095 | the governor's carried drop debt |
| `framestore.vb_flush` | :1811 | the DDR circular-buffer pointers |

**Nothing else.** `vld` / `getbits` / `motcomp` / `motcomp_picbuf` are on `sync_rst`, and
`mount_flush` (the decoder soft reset) has been MOUNT-ONLY since 2026-08-28. So the flush
discards *buffered bytes* and leaves every bit of decode state standing — including the
reference slots.

`motcomp_picbuf` has **no valid bit on the reference slots at all**:
`forward_reference_frame` / `backward_reference_frame` are pure pointers, and
`motcomp_addrgen` reads them unconditionally for any macroblock with
`macroblock_motion_forward/backward`. Stale *content* is therefore invisible to the
decoder by construction. (`prev_i_p_frame_valid`, which issue #45 originally named, is a
*display* flag — see §5.)

### 2.1 Why the leading B's, and why TWO anchors are needed

`motcomp_picbuf.v:281-291` and `:371-383` — at a non-B `STATE_UPDATE` the module assigns
`current_frame <= forward_reference_frame` while fwd and bwd swap. Trace it across a seek:

| picture | current | fwd after | bwd after | predicts from |
|---|---|---|---|---|
| pre-flush anchor → slot 1 | 1 | 0 | 1 | — |
| **I0** — first post-flush anchor | 0 | 1 | 0 | intra, safe |
| B1, B2 — the open GOP's leading pictures | aux 2/3 | 1 | 0 | fwd = slot 1 = **PRE-FLUSH** |
| **P3** — second post-flush anchor | **1** | 0 | 1 | fwd = I0 ✓, and it *overwrites* slot 1 |
| B4, B5 … | aux | 0 | 1 | both post-flush ✓ |

The first anchor only establishes the **backward** reference. Forward still points at the
slot the old scene lives in, and an open GOP's leading B-pictures — coded after the I,
displayed before it — are precisely the pictures that read it. Only the **second** anchor's
`current_frame <= forward_reference_frame` overwrites that slot. Two coded pictures at
~24–30 fps, expanded by 3:2, is ~6 display frames: the reported number.

⚠ **The rationale `flush_ctl.sv` gave for not soft-resetting on a seek was not being
achieved.** It said a seek is *"where the display must hold the last frame and the
reference frames are same-file valid"*. Same-**file** is not same-**position**, and MPEG
prediction cares about position; and the display was not holding — it was showing ~6
corrupt frames, because `output_frame_valid` stays high straight through a flush.

## 3. The fix

`rtl/mpeg2/vld.v` gains one input, `vbuf_flush` (driven from `flush_vbuf_eff` — already
clk_dec, already 2-FF synced in `dvd/emu.sv`, so no new CDC), and a small state machine:

- `ra_anchors == 0` → drop every picture that is **not an I**.
- `ra_anchors == 1` → drop **B** pictures.
- the second accepted anchor clears `ra_active`.

Dropping happens through the decoder's existing, HW-proven suppression legs — the same
ones the frame-drop governor uses — so the dropped pictures are invisible downstream:
slices routed to `STATE_NEXT_START_CODE` (`vld.v:721`), `update_picture_buffers` suppressed
so picbuf never allocates or rotates for them, `flags_commit` and `informative_commit`
gated. picbuf therefore never emits them and the display **genuinely holds** the last frame
until the new scene's references are real — which is what `flush_ctl.sv` always claimed a
seek did.

Non-I pictures are dropped before the first I because a title seek lands on a VOBU/GOP
boundary but a flat `.mpg`/`.VOB` seek only hunts a pack and may land anywhere. There, the
pre-fix behaviour was garbage until the next I; now it is a held frame until the next I.

### 3.1 ★ The arm must sit BEFORE the `clk_en` term

`vld.clk_en` is `vld_en`, and `rtl/mpeg2/motcomp.v:257-272` freezes the VLD at **every**
picture header until picbuf has processed the update — picbuf waits there on the display
handshake, i.e. **up to a whole display frame (~1.5 M clk_dec cycles at 93 MHz / 60 Hz)**.
The flush level is ~64 clk_sys cycles ≈ **192 clk_dec cycles**. A `clk_en`-gated capture
would therefore miss the level *routinely*, not occasionally.

The arm is level-dominant for the whole window, which also coalesces repeated flushes for
free: a scrub or a double chapter skip restarts the window instead of being swallowed —
the same property `mode_realign` needed (`docs/single_raster_analog.md` §6).

Bench arm [5] (`+DRAIN=4000`) is the one that proves this, and it carries its own
anti-vacuity guard: it asserts the vld was frozen for the entire flush window
(`vld_en` high for 0 of its cycles), because otherwise the arm would pass without ever
exercising the case.

### 3.2 Anchors are counted off the node picbuf rotates on

`update_picture_buffers`'s header condition is factored out as `hdr_upd_slot`, and the
anchor counter keys on the same wire. Two reasons this is not just tidiness:

- **Correct by construction.** The rule becomes "count an anchor exactly when picbuf
  rotates". In particular a **field-coded I frame is two I field pictures** and must count
  ONCE — it does, because `second_field` reads 1 only at a field pair's *first* header (the
  seq/gop preset convention that `drop_now_comb` already relies on). Writing the condition
  out a second time is how that gets silently wrong.
- **No new fan-out on `picture_structure`** — the register physical synthesis mangled in
  the Thayer `drops=0` round (`vld.v` `drop_ps_lat` note). The new logic reads the same
  node the HW-proven `update_picture_buffers` path reads.

MPEG-1 comes free: `picture_structure` is forced to `FRAME_PICTURE` in mpeg1 mode.

No sibling pair-arm latch is needed. The governor needs `drop_pair_arm` because its
predicate is deliberately restricted to a field pair's first field; this predicate is a
pure function of `getbits[13:11]` and `ra_anchors`, identical at both field headers, so
field-pair atomicity is **structural**.

### 3.3 The ledger split — not hygiene, a real regression if omitted

`drop_this_picture` now latches *either* reason, but a new `drop_gov_picture` latch (the
governor's alone) feeds `drop_slice_hit` and therefore `drop_pic_ack`.

Without the split, 2–3 realign drops on every seek pay credit into `frame_drop_ctl`, whose
`DEBT_FLOOR` is `-4` (`dvd/frame_drop_ctl.sv:120,136`). With `DROP_THRESHOLD = 2` the
governor would then need **6 accrued lates before it could drop again** — exactly during
the post-seek re-lock, when it is most likely to be late. `drop_pic_rff` / `drop_pic_field`
would also export the realign-dropped picture's flags into `drop_cost`, and
`frames_dropped_cnt` telemetry would be polluted.

### 3.4 The give-up cap

`RA_CAP = 48` picture headers. A stream that never delivers an I must not freeze video
forever. It is a `parameter` so the bench can reach the path inside a short fixture
(arm [6], `-Pseek_realign_tb.RA_CAP=2`); the shipped value never is, which would otherwise
make it untested dead code.

### 3.5 Scope: which menu transitions this touches

The re-align arms on `flush_vbuf_eff`, and `dvd/flush_ctl.sv` gates `seek_flush` on
`~keep_vbuf`:

```verilog
wire jump_flush     = jump_ack && ~keep_vbuf;
wire seek_flush_now = seek_ack && ~keep_vbuf;
```

So the split is the Phase-5 menu-transition rule, unchanged and inherited for free:

| transition | `keep_vbuf` | flush | re-align |
|---|---|---|---|
| menu → menu (submenu, page, `next_pgcn` advance) | 1 | none | **never arms** |
| title → menu (Menu key) | 0 | trio | arms, like a seek |
| menu → title (Play) | 0 | trio | arms, like a seek |
| chapter skip / scrub / D-Pad Seek | 0 | trio | arms |
| `Video Output` change | — (`mode_switch`) | trio | arms |

Menu→menu hops — the ones that carry an authored transition animation, and that
`keep_vbuf` exists to protect — are **structurally untouched**: no flush reaches the
decoder, so `ra_active` never sets. Entering and leaving a menu *is* a flushing jump and
was always one of the four paths issue #45 named, so it gets the same treatment as a
chapter skip.

⚠ **The failure mode worth measuring is a menu STILL**, because it is the shape that would
break catastrophically. A still is a whole stream — `SEQ GOP PIC:I SEQ_END` — carrying
**one** I picture and no B's, so if the re-align ever dropped an I the menu would simply
never appear. It does not: an I is always accepted at `ra_anchors == 0`, and bench arm [7]
measures it over `bench/dvd/test_vobs/hp_still_i.hex` (a real still, cut from the Harry
Potter interactive disc for the picbuf slot-alias fix) landed as cut B:
`realign_drops=0, post-flush{hdr=1 upd=1 anchors=1}`.

A second-order effect worth knowing: after a still, `ra_active` stays armed (a still yields
one anchor, never two) until the next anchor or `RA_CAP`. If the user then makes a
`keep_vbuf` hop to a *motion* menu, that menu's leading B's are dropped — which is the
right answer anyway, since they predict from the previous menu's frame. The cost is one
extra held frame at a menu transition, bounded by `RA_CAP`.

## 4. Rejected alternatives

**`closed_gop`** (parsed at `vld.v:1477`, consumed by nothing before or after this change)
would let a genuinely-safe leading B through. **Not honoured, deliberately:** it is a bit
the *encoder wrote*, not a measurement — the same failure class as `progressive_frame` in
the film-evidence gate (`docs/film_24p_plan.md` §14), where an encoder's meaningless
default was being counted as evidence. A disc that lies `closed_gop=1` would leave issue
#45 present **and unfalsifiable on that disc**. It can only ever make the fix weaker, and
it buys two pictures at a landing the user already expects to re-lock.

**Extending `mount_flush` (the decoder soft reset) to seeks** — the blunt version. It
asserts `sync_rst`, which drops `dec_ready` and gates the modeline walk (the boot race in
`docs/single_raster_analog.md` §3.2), and it trades a glitch for a black cut on every
chapter skip. Retained only as the fallback if the re-align proves insufficient on HW.

## 5. What this does NOT fix — a prediction, written before the build

The picture in flight when the flush lands already had its `update_picture_buffers` fire:
it owns a slot, its remaining slices decode against a discarded buffer, and it completes on
the new stream's first start code. It is displayed once at the first post-flush anchor's
update. **With the leading B's dropped it is now held for ~4 picture times instead of ~1.**

Net trade: **~6 frames of macroblocked *motion* → ~1 torn frame held longer.** That is
better, and the *signature* the field report identifies is gone, but it is not clean. The
HW round's question was therefore binary and falsifiable:

> **Is the old scene still visible in motion as residual?**

### ✅ HW round, 2026-09-03 — the prediction held, to the frame

> *"this looks good. the old scene is not in motion, it's frozen and we jump to the target
> seek position with ~1 frame of a misaligned image."*

Three separable claims in one sentence, and each maps onto a specific piece of the design:

- **"the old scene is not in motion"** — the leading B's are no longer decoded and
  displayed. That is the defect issue #45 reported, and it is gone.
- **"it's frozen"** — `output_frame_valid` now stays on the last good frame across the
  landing, because picbuf never sees the dropped pictures. This is the behaviour
  `flush_ctl.sv` claimed a seek already had (§2) and did not.
- **"~1 frame of a misaligned image"** — the truncated in-flight picture, predicted above
  and unchanged by this fix. One frame, not a burst.

★ **Writing the residual down *before* the build is what made this round cheap.** The
report is a confirmation rather than a surprise, and no time was spent re-opening the
anchor accounting to explain a frame that was already accounted for. Had the answer been
"yes, still moving", the next place to look was named in advance (the bench's slot-tag
arms, not the display path) — which is the same discipline `docs/single_raster_analog.md`
§3.9 earned the hard way over five rounds.

The remaining single frame is the v2 item costed in §5.1. It is now the *only* thing left
of issue #45, and it is a different defect class: one corrupt picture, not stale
prediction.

### 5.1 Why the display side was left alone (and what v2 would have to be)

Issue #45's own "fix direction 1" was to clear `prev_i_p_frame_valid` on a flush. Two
findings against doing it in this round:

1. **Insufficient alone.** It suppresses the *display* of one stale anchor and does nothing
   to `forward_reference_frame`, so the leading B's — the reported symptom — still predict
   from the stale slot.
2. **An ordering hazard no bounded level defeats.** picbuf's `update_picture_buffers`
   arrives through the **mvec FIFO** (`motcomp.v:280` packs it into `mvec_wr_dta[1]`;
   `motcomp_addrgen.v:379` drives picbuf from `mvec_rd_update_picture_buffers`). A flush
   wire routed *directly* to picbuf can clear the flag and then have a queued **pre-flush**
   anchor's update re-set it from `current_frame_valid` (which is never cleared except by
   reset). Holding the level for the whole ~192-cycle window does not help: the queued
   update can take a whole field to drain, because picbuf itself blocks on the display
   handshake.

★ **The durable rule:** anything that must correct an `update_picture_buffers` decision
either **rides the mvec FIFO** or is **decided in the vld**. It cannot bypass the FIFO and
arrive on time.

So the designed v2, if the residual is judged worth it, is a per-picture `pic_realigned`
flag widened into `mvec_wr_dta` (188 → 189 bits) so picbuf clears the flag *in order*, by
construction. Costed, not built — it is a second, independent behavioural delta on an
87–88 % ALM design.

A cheaper v2 candidate with no decoder change at all: extend `mode_realign`'s existing
switch blank to fire on `seek_ack`/`jump_ack && ~keep_vbuf`. It blanks the torn frame and
the hold, reuses mutation-checked machinery, and lives entirely in `dvd/`. The
counter-argument is `docs/single_raster_analog.md` §6.8's own reason not to blank a seek —
display continuity — which is weaker than it looks when the thing being held is torn. **A
UX call, deferred by user decision (2026-09-03): one behavioural delta this round.**

⚠ **The HW round sharpens the cost/benefit for this one.** What the screen now does at a
landing is *freeze, then cut to the new scene with one bad frame in between* — which is
already close to a hard cut, so blanking that single frame would cost very little display
continuity and would make the transition clean. The v1 argument for leaving it (never blank
a seek) was written when the alternative was six frames of visible garbage; it is a weaker
argument against blanking one.

## 6. The gate

`bench/dvd/seek_realign_tb.sv`, driven by `bench/dvd/run_seek_realign.sh`. Real
`getbits_fifo` + real `vld` + real `motcomp_picbuf` over **two cuts from different points
of a real title**. Partway through cut A the bench does what hardware does: asserts the
flush level *and* jumps the read pointer to cut B. `getbits` is deliberately **not** reset,
so its 129-bit window keeps up to 16 bytes of cut A and the in-flight picture truncates
exactly as on hardware.

**The measurement is slot provenance, not a restatement of the fix.** A shadow `slot_tag[]`
records which *cut* last wrote each of picbuf's frame slots; every picture that reaches
picbuf is then checked against the slots it actually predicts from (fwd for P, fwd+bwd for
B; I is intra). A post-flush picture reading a slot tagged with the pre-flush cut is a
violation. That names no signal in the fix, so it cannot degenerate into a golden model
that agrees with its RTL by construction (memory `bench-that-cannot-fail`).

Fixture: `tools/seek_fixture.py`, which **refuses** to emit a fixture whose cut B has a
closed first GOP or no leading B's — either would make the RED arm measure zero and the
whole gate vacuous — and refuses a cut A containing a sequence end, which would pre-clear
the references for free.

| | asserted | measured (Matrix Revolutions VTS01, `lead_b = 2`) |
|---|---|---|
| **RED** (`-Pseek_realign_tb.SEEK_REALIGN=0`, the fix's input tied low) | `viol == meta[3]`, `realign_drops == 0` | `viol=2` — both leading B's predicting `fwd = slot 1`, tagged cut A |
| **GREEN** | `viol == 0` **and** `realign_drops == meta[3]` | `viol=0 realign_drops=2 post-flush{hdr=14 upd=12 anchors=5}` |

The GREEN drop count is asserted **exactly**, not as `>= 1`: dropping too much is a failure
too, because it costs display frames at every seek.

The RED arm is a *testbench* parameter, not an RTL one, so the shipped RTL has no
feature-off path and the same binary proves both halves. Its numbers reproduce a run
against pristine, unmodified `vld.v` **byte for byte** (`viol=2`, `emits=18`, emit gap
285962 cycles), which is what makes it a legitimate stand-in for a pre-fix build.

All eight arms green (`bench/dvd/run_seek_realign.sh --red`, 2026-09-03).

**Arms.** [1] control, no flush — the re-align must be inert over a whole stream
(`realign_drops=0` over 19 pictures); [2] flush mid-slice, the reported case; [3] flush at
a picture header; [4] two flushes on one seek — they must **coalesce** onto one re-align,
which is structural because `ra_active`/`ra_anchors` are a level rather than an edge count
(the same property that makes the repeated-mid-parse-flush loop which killed the film-mode
edge unreachable here); [5] `+DRAIN=4000` display-blocked — §3.1; [6] `RA_CAP=1`, the
give-up; [7] a **menu still** as the landing — §3.5.

Anti-vacuity on every arm: ≥ 8 post-flush pictures must reach picbuf and ≥ 2 post-flush
anchors must decode, or "drop everything forever" would score zero violations and pass.

Three things the arms taught, all worth keeping:

- ⚠ **The truncated in-flight picture EATS cut B's sequence header.** The bench originally
  asserted that a sequence header must be parsed between the flush and the first post-flush
  picture header, as a guard that the cut-A/cut-B tagging was trustworthy. Arms [3] and [5]
  failed it on correct RTL: the truncated picture consumes the new stream's opening bytes
  as its own payload, and since `sequence_header_seen` is already set from cut A the vld
  simply decodes on. The guard is now a **count** — post-flush frame headers must equal the
  fixture's cut-B picture count (14 = 14); one leaked cut-A header would make it 15.
- ⚠ **`RA_CAP` must be small enough to shorten the window by more than one picture.** The
  give-up clears `ra_active`, but `realign_now_comb` is combinational off the *pre*-clear
  value, so the header that trips the cap is still judged normally. At `RA_CAP=2` the arm
  measured `realign_drops=2` — identical to an uncapped run, i.e. "the cap fired" and "the
  cap is dead code" were indistinguishable. `RA_CAP=1` separates them.
- ★ **The give-up arm measures `viol=1`, and that is the design, not a miss.** Cutting the
  window short lets one leading B through to predict from the stale slot. The cap trades a
  bounded amount of the very artifact this change fixes for a guarantee that video can
  never freeze on a stream that stops delivering anchors. `RA_CAP=48` is far beyond any
  real GOP, so the trade is never taken on a real disc — but the arm shows exactly what it
  costs when it is.
- The `+DRAIN` arm's own guard reports `vld_en high for 0 of the 192 flush-window cycles` —
  the freeze really did cover the whole window, so the arm genuinely exercised §3.1.

**Regression: the governor's ack ledger must not move.** `vld_drop_rff_tb` measured
`pictures=18 drops=11 ack_rff1=5 ack_rff0=6` against the **pre-fix** vld on this fixture,
and the same numbers after the split — asserted as a literal string by the runner. That
bench was **stale** and had to be repaired before it could be trusted as a baseline: its
`vld` and `motcomp_picbuf` instances predated `pic_informative` / `informative_commit` /
`drop_pic_field` / `mpeg1` / `cc_pair*` (two of which are picbuf *inputs*, so they were
floating to `z`), and its default fixture no longer existed — `$readmemh` on a missing file
leaves the array all-X, so it would have "passed" having decoded nothing.

Other benches over the shared `vld`, all green: `film_evidence_tb` (35/35 pictures, every
verdict matches golden), `cc_extract_tb` (180/180 caption pairs byte-exact), `vld_mpeg1_tb`
(115 pictures, 0 errors), `motcomp_picbuf_tb` (50 release-point checks, 0 fails).

## 7. Fit

Ten registers (`ra_active`, `ra_anchors[1:0]`, `ra_hdrs[5:0]`, `drop_gov_picture`) plus a
few LUTs, all inside the once-per-picture `STATE_PICTURE_HEADER` decision cone, which has
enormous slack. It should not move the limiter — but the netlist changes, so the pinned
fitter SEED is a fresh roll regardless. See the `DVD.qsf` ledger entry.
