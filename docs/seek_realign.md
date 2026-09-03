# Post-seek reference re-align (issue #45)

> **Status: 🔧 fixed in fabric, sim-proven RED/GREEN, ⏳ HW-confirm pending.**
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
HW round's question is therefore binary and falsifiable:

> **Is the old scene still visible in motion as residual?**

If no, v1 succeeded and the remaining held frame is a separate item. If yes, the anchor
accounting is wrong and the bench's slot-tag arms are where to look — not the display path.

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

| | measured |
|---|---|
| **RED** (`-Pseek_realign_tb.SEEK_REALIGN=0`, the fix's input tied low) | `viol == meta[3]` — the exact leading-B count, and `realign_drops == 0` (the added logic is provably inert when unarmed) |
| **GREEN** | `viol == 0` **and** `realign_drops == meta[3]` — asserted **exactly**, because dropping too much costs display frames at every seek |

The RED arm is a *testbench* parameter, not an RTL one, so the shipped RTL has no
feature-off path and the same binary proves both halves. Its numbers reproduce a run
against pristine, unmodified `vld.v` byte for byte (`viol=2`, `emits=18`, identical emit
gap), which is what makes it a legitimate stand-in for the pre-fix build.

Arms: [1] control, no flush (the re-align must be completely inert over a whole stream);
[2] flush mid-slice — the reported case; [3] flush at a picture header; [4] two flushes on
one seek (the second must restart the window); [5] `+DRAIN` display-blocked — §3.1; [6]
`RA_CAP=2` — the give-up must fire and decoding must resume. Anti-vacuity on every arm:
≥ 8 post-flush pictures must reach picbuf and ≥ 2 post-flush anchors must decode, or
"drop everything forever" would score zero violations and pass.

Regression: `vld_drop_rff_tb` guards the ledger split (§3.3). It was **stale** — its `vld`
and `motcomp_picbuf` instances predated `pic_informative` / `informative_commit` /
`drop_pic_field` / `mpeg1` / `cc_pair*`, so picbuf's two evidence *inputs* were floating,
and its default fixture no longer existed — and was repaired in the same branch before
being trusted as a baseline.

## 7. Fit

Ten registers (`ra_active`, `ra_anchors[1:0]`, `ra_hdrs[5:0]`, `drop_gov_picture`) plus a
few LUTs, all inside the once-per-picture `STATE_PICTURE_HEADER` decision cone, which has
enormous slack. It should not move the limiter — but the netlist changes, so the pinned
fitter SEED is a fresh roll regardless. See the `DVD.qsf` ledger entry.
