# Fabric budget, memory ports, and the verification rules a failed feature earned

**Written 2026-09-21, after the Stage B deinterlacer attempt was abandoned.** The feature
did not ship; almost everything it taught is unrelated to deinterlacing and is written
down here so the next feature does not pay for it again.

Read §1 and §2 before designing anything that touches DDR3, and §4 before trusting any
gate that says a feature works.

---

## 0. What was abandoned, so that nobody rebuilds it

⚠ **NOTHING deinterlacer-related is on `main`, and that is the decision, not an
oversight.** Both branches exist only locally and unmerged:

- **`feature/deinterlace` — "Stage A"**, a spatial comb detector plus soft blend on the
  progressive output. Built, HW-tested and *accepted on its own terms* (2026-09-20).
- **`feature/deint-hist-ddr3` — "Stage B"**, the temporal term described below.

The maintainer's decision (2026-09-21) is to **stop the whole endeavour**, not merely
Stage B:

> *"The stage A work is fine, but I don't think the trade for the edge shimmer is worth
> any perceived reduced combing. The current progressive video output on `main` is good
> enough, and I've found most users of this core are expecting to watch on 480i CRTs
> anyway."*

★ **That last clause is the strategic point and outranks every measurement in this
document:** on a 480i CRT the *interlaced* path is what the viewer sees, and the
deinterlacer is not on it. Effort spent on progressive deinterlacing is effort spent off
the path most users are on.

⚠ The design notes for both stages (`docs/deinterlace_plan.md`,
`docs/stage_b_temporal_plan.md`) live on those branches and are **not** on `main`. This
document is deliberately self-contained so that it survives their deletion.

### Stage B specifically — why it was rejected

**It was built end to end and REJECTED on picture quality.**
The rule was `temporal = |Y_cur − Y_prev| > Tt`, ANDed into the detector so a pixel that
did not change between pictures could not be called a comb. It was meant to remove the
false positives that round 2's alternating anchor turns into 30 Hz edge shimmer.

Maintainer's verdict on the finished build:

> *"Combing on motion is still present and this also adds a weird effect where objects
> moving vertically on screen leave little lines in their previous location for a frame,
> giving them a kind of 'trail' vertically. Overall I'd say this is poor deinterlace
> quality."*

and, decisively, with the history buffer switched **off**:

> *"disabling the history buffer removes that artifacting and also minimizes the combing"*

★ **Off being better on BOTH axes is the finding.** The term was not merely failing to
help — it was **suppressing real combs**, i.e. removing true positives, which is the
silent-no-op direction the whole plan had been written to avoid. A binary per-pixel veto
can do that; on slow vertical motion the inter-picture difference at a combed edge can
sit under the threshold while the intra-picture field offset still produces visible comb.

⛔ **Do NOT rebuild it on the strength of the offline model's numbers.** The model
(`tools/deint_model.py`) predicted the temporal term sat on a strictly better point of the
curve than any spatial option, and on one cut that comb would *improve* 0.774 → 0.761. The
hardware says otherwise. §4 explains how a green gate and a favourable model coexisted
with a visible regression; that explanation is the reusable part.

The implementation lives on the unmerged, unpushed branch `feature/deint-hist-ddr3`.
Nothing from it is on `main`, and the sections below are the only part intended to
outlive it.

---

## 1. ★ A WHOLE 64-BIT DDR3 PORT IS FREE IN THIS CORE

This is the most valuable thing the attempt found, and it has nothing to do with
deinterlacing.

`sys/sys_top.v` brings out **three** independent f2sdram Avalon ports from the HPS:

| port | width | owner in this fork | free? |
|---|---|---|---|
| `ram1` | 64-bit | the MPEG-2 decoder (`mem_shim_burst` via `ddr_arb`) | no |
| **`ram2`** | **64-bit** | **nothing** | **YES** |
| `vbuf` | 128-bit | ascal's scaler framebuffer | no — see below |

**`ram2` is idle by construction, not by luck**, and both of its consumers are provably
absent in this fork:

- `ddr_svc` channel 0 is the **ALSA** audio pump, compiled out by
  `MISTER_DISABLE_ALSA=1` (`DVD.qsf`, set during the 2026-09-11 logic reclaim);
- channel 1 is the **MiSTer framebuffer palette**, which needs `MISTER_FB` (not defined
  in `DVD.qsf`) and `FB_EN`.

⛔ **NOT ascal's `vbuf`.** It looks spare because the core drives `VGA_*` directly, but
ascal writes every input frame into it and reads it back scaled — it is the **busiest**
of the three ports, not a spare one. This was the first instinct and it is wrong.

### The wiring recipe, described so it survives the branch being deleted

1. `sys/sys_top.v` — rename the nets `ddr_svc` drives to `svc_*` and leave that instance
   in place with its inputs tied off. ⚠ **Keep `ddr_svc` rather than deleting it:** its
   `ram_bcnt` output still feeds the palette address (`pal_a`), and removing it drags
   `MISTER_FB`'s palette path into a change that is about memory arbitration.
2. Declare fresh `ram2_*` nets **above** the `sysmem_lite` instantiation and pass
   `.ram2_clk(<core mem clock>)` instead of `clk_audio`.
3. Give `emu` a second master (`DDRAM2_CLK/ADDR/BURSTCNT/BUSY/DOUT/DOUT_READY/RD/DIN/BE/WE`)
   and connect those `ram2_*` nets to it.
4. In `dvd/emu.sv`, drive the new port from the new master with plain `assign`s.

⚠ Everything in steps 2–4 is subject to Verilog **declaration order** — see §7.

---

## 2. ★★ THE SCARCE RESOURCE IS ARBITRATION OCCUPANCY, NOT BANDWIDTH

Three independent measurements say the same thing, and it is the single most reusable
design rule here.

**(a) Direction matters far more than volume.** A write pump moving ~10 MB/s through
`ddr_arb` cost **nothing detectable** (lates/drops/vbuf unmoved over 10 alternating
windows). A *read* path of the **same byte rate** cost **+65 % lates**. Bandwidth
saturation cannot tell a read from a write; grant occupancy can.

**(b) Halving the traffic cut the cost 8.7×, not 2×.**

| | lates/s | drops/s | content fps |
|---|---|---|---|
| every line, on `ram1` | 5.375 | 2.683 | 22.33 |
| half the lines, on `ram1` | 0.620 | 0.312 | 24.70 |

A linear response would mean a bandwidth budget being consumed. A strongly super-linear
one means a **contention threshold** being crossed.

**(c) The controlled version: same traffic, different port, zero cost.**

| | lates/s | drops/s | content fps |
|---|---|---|---|
| half the lines, on `ram1` | 0.620 | 0.312 | 24.70 |
| **half the lines, on `ram2`** | **0.000** | **0.000** | **25.03** |
| control arm (pump off) | 0.000 | 0.000 | 25.01 |

Nothing about the DDR3 device or the number of bytes changed — only which master had to
wait for a grant. **0 of 6 windows positive.**

### Why a read is so much more expensive than a write

A write is fire-and-forget into the bridge's buffer: the master hands over beats and is
done. A read holds the grant through **command + memory latency + every return beat**,
with the other master held off by `waitrequest` for the whole slot, because responses are
routed by grant and the grant cannot move while beats are outstanding.

### The rule for future features

> **If a new DDR3 master measurably hurts the decoder, do not reach for smaller data
> first. Ask whether it can have its own port.** Subsampling, lower precision and shorter
> bursts all trade a feature's quality against the wrong variable. `ram2` is free and
> costs no quality at all.

⚠ All three ports reach the **same DDR3 device**, so a port move buys **no bandwidth**.
It removes arbitration occupancy. That is a different (and, here, the binding) resource.

---

## 3. Fabric budget, as measured

From `output_files/DVD.fit.rpt` of the abandoned Stage B build (so `main` has *more*
headroom than this — treat these as a pessimistic floor):

| resource | used | total | headroom |
|---|---|---|---|
| ALM | 39,033 | 41,910 | ~2,900 (7 %) |
| M10K | 512 | 553 | 41 (7 %) |
| DSP | 101 | 112 | 11 (10 %) |

Per-module, for estimating future work:

| module | ALM | registers | M10K | what it is |
|---|---|---|---|---|
| `mem_shim_burst` | 1279 | 2193 | 16 | the decoder's burst cache |
| `deint_comb` | 391 | 562 | 6 | Stage A: 2 line delays + blend |
| `deint_detect` | 49 | 136 | 0 | the comb test itself |
| `hist_wr` | **188** | 287 | **6** | **a complete double-buffered DDR3 line pump** |

★ **A DDR3 line pump — burst write, burst read, ping-pong staging, 4 read banks and the
CDC — costs about 190 ALM and 6 M10K.** That is cheap, and it is the number to use when
estimating any future feature that wants a line of external memory per display line.

⚠ **`clk_dec` is the binding clock domain**, not `clk_sys` or `clk_mem`, and the gate is
**86.0 MHz at BOTH slow corners** (100 °C and −40 °C). The design sits at ~88–90 MHz. The
86.0 figure is a **netlist-health canary**, not a cliff — measured decode failure is far
lower — but builds under it are packed `_MARGINAL_` and must not be flashed casually.

---

## 4. ★★★ HOW A FEATURE WITH A FULLY GREEN GATE SHIPPED AS A VISIBLE REGRESSION

Stage B had 42 green arms in `run_deint.sh --red`, 12 mutations each caught by exactly its
own arm in `run_hist_wr.sh --red`, a memory-path A/B, a wiring checker, and an offline
model predicting it would help. It was still a regression on a screen. Every reason below
is general.

### 4.1 The bit-exact model cosim never exercised the feature

`bench/dvd/deint_comb_tb.sv` is the **only** bench that compares the RTL bit-exactly
against `tools/deint_model.py` — the model whose numbers justified building Stage B at
all — over real disc frames. When Stage B's ports were added, that bench tied
`.hist_ok(1'b0)`, the no-history case.

So the feature was validated by: a directed arm (the veto zeroes a weight), a differential
chain arm on synthetic data, and a memory-path bench. **Not once was its output compared
against the model that predicted the benefit.**

> **RULE. When a feature is justified by an offline model, the bit-exact cosim against
> that model MUST exercise the feature. Otherwise the justification is untested, and a
> model/RTL divergence and a wrong model are indistinguishable.**

⚠ This is also why the abandonment is clean rather than frustrating: nobody can currently
say whether Stage B failed because the RTL diverged from the model, or because the model
measured the wrong thing. Closing that gap is the first step for anyone who revisits it.

### 4.2 A bench can PASS vacuously on X — and `!=` is how

`deint_chain_tb` was given four new ports and they were left unconnected. Icarus floats
those Z; `hist_ok` Z made a predicate X, which made the dilated weight X, and because
`mix8`'s multiply propagates X through a *zero* weight, the pass-through anchor lines went
X too — **~1552 of every scan's 4096 pixels, 37 % of everything the bench emitted**.

Every one of those pixels **passed every arm**, because scoring used `!=` and
`x != 169` evaluates to `x`, which `if` treats as false. The bench printed
`RESULT: PASS` with 12,028 X pixels in it, for several commits.

> **RULE. Score benches with `!==`, never `!=`.** It is the only thing that makes this
> class self-reporting rather than silent. Reach for it immediately when a bench reports a
> count of 0 for something that cannot be 0, or is green on RTL you know is incomplete.

⚠ And the general form of the trap: **adding a port to a shared module silently poisons
every bench that instantiates it without the port.** After adding one, grep the benches
and tie it off in the same commit. This happened *twice* in one week here, the second time
in the very bench written to gate the new port.

### 4.3 A fixture chosen to make an arm decisive can make it unrepresentative

The chain arm scored a *static* region against a *moving* region within one scan — a
differential design, deliberately immune to a detector that simply stopped firing. Good
design. But the "moving" region moved by a fixed **24 code values** per picture, well
above the threshold of 8, because that is what made the arm unambiguous.

Real content moving slowly changes by **less** than the threshold while still combing.
The arm could not have failed for the reason the feature actually failed.

> **RULE. Ask what range of the input space a synthetic fixture spans, and whether the
> failure you fear lives inside it.** A fixture tuned for a clean pass/fail boundary tends
> to sit far from that boundary.

### 4.4 The metric decides the verdict, so ask what it cannot see

The offline study scored *visible shimmer on static pixels* and a *global comb ratio*. It
never scored "comb left on slowly-moving edges", nor "the veto mask's edges are visible as
a one-frame trail" — the two things the maintainer reported. Both are invisible to both
metrics, so a favourable verdict was guaranteed regardless of those artifacts.

> **RULE. Before trusting a model's verdict, enumerate the artifact classes its metric is
> structurally blind to.** A number that cannot go bad for a given defect is not evidence
> about that defect.

### 4.5 When you reduce work, score the SET, not the COUNT

Halving the pump's reads (skipping lines whose history can never be consulted) was
implemented with the parity **inverted** — right algebra applied to the wrong line. It
fetched exactly the half that is never used.

The count was identical either way. The arm caught it in one run *only because* it scored
**which** lines were fetched. A count-based arm would have passed.

> **RULE. An optimisation that does half as much work must be gated on doing the RIGHT
> half. The wrong half has the same count.**

### 4.6 A measurement that can no longer detect its own subject

Once the pump moved to `ram2` its cost hit exactly zero, so the probe's two arms became
indistinguishable — **which is also precisely what a dead pump reads.** "No measurable
cost" and "not running" produce identical telemetry.

Liveness was proven separately: the DDR3 region *changes* with the pump on and *freezes*
with it off (with the decoder's own framestore as the control, to show playback was live),
and the pump's FSM is serial, so writes continuing proves its reads complete.

> **RULE. When an effect reaches zero, the instrument that measured it can no longer tell
> you the mechanism is present. Prove liveness by a different route before reporting
> "free".**

---

## 5. Timing technique that worked

### ★ Gate at the register, not inside the producing cone

A one-bit term was ANDed into a combinational result inside `deint_detect`. That put it in
the module's critical cone, which was already the binding path. Two consecutive builds
missed the gate (**91.42/85.08**, then **82.52/84.73** against 86.0) and each needed a
fitter seed sweep.

The term reached the output through exactly one gate, and the output was already zero
whenever that gate was false — so tying the input to `1'b1` and applying the term at the
**register** instead (`q <= term ? result : 0`) is algebraically identical, and lifts it
out of the cone entirely.

Result: **89.81 @100 °C / 88.36 @−40 °C, passing on the FIRST fit**, ~2.4 MHz of margin,
no sweep.

> **RULE. When a new term only ever *suppresses* an existing result, apply it at the
> register that captures the result, not inside the logic that produces it.**

### The cold corner usually binds, and the tool defaults to the hot one

`fmax_check` gates **both** slow corners and −40 °C is frequently the worse one, while
`tools/timing_paths.tcl` defaults to 100 °C. Pass `TIMING_TEMP=-40` or you will retime a
path that is not the one failing — which has cost this project two wasted retimes.

### A netlist change invalidates the pinned seed

`DVD.qsf`'s pinned `SEED` is tied to the exact synthesis netlist. A seed that closes one
build can be far below the gate on the next: **SEED 5 passed at 88.61/87.63 and then
returned 74.76/79.39** after the RTL changed. Expect to re-sweep after any real change,
and treat a first-fit pass as luck rather than entitlement.

---

## 6. Hardware-in-the-loop measurement discipline

- **An EMPTY `vbuf` is upstream starvation, not memory contention.** A decoder held off by
  the bus stops *consuming* and its buffer fills; a buffer that drains to zero means bytes
  are not arriving. Reading this correctly stopped a wrong diagnosis ("the pump is
  starving the arbiter") that was already half-written.
- **Test on LOCAL media.** The first probe attempt ran from a CIFS share and produced
  playback stalls that looked exactly like a core defect. A network hiccup and an arbiter
  bug present identically in telemetry. The stalls were never attributed and should not be
  cited in either direction.
- **A paired, alternating, within-build comparison cancels netlist quality.** That is what
  made it defensible to measure on a `_MARGINAL_` build: both arms run inside one netlist,
  so any weakness applies to both. ⚠ It licenses *relative* claims only — never picture
  quality, never anything cross-build.
- **Content drift is the same order as the effect.** Two consecutive same-arm windows on
  different scenes differed as much as the effect under test, which is why the arms must
  interleave rather than run as one Off block and one On block.
- **Check the feature is even engaged before measuring it.** Much of this work was
  measured on content where the deinterlacer never blended a pixel (`comb_density = 0`).
  That is fine for a *traffic* question and worthless for a *quality* one — and confusing
  the two is how a feature gets declared "free" the day before it is rejected.

---

## 7. Recurring papercuts, none of them interesting, all of them expensive

- **Verilog declaration-after-use** cost ~5 build/elaboration failures across this work,
  in both benches and `sys_top.v`. Icarus and Quartus both reject it; neither says
  "move the declaration up".
- **A port left as `input` while the module drives it internally** is a *multiple-driver*
  error that **neither the linter nor any bench can see** — `lint_undriven.sh` asks about
  nets with *no* driver, and every bench instantiates the leaf modules directly rather
  than the wrapper. Only the fitter catches it, as `Error (12014)`, ~30 seconds into a
  40-minute compile. When a signal stops leaving a module, delete it from the port list in
  the same edit.
- **`pgrep -f <pattern>`** matches the shell running the command that contains the
  pattern. An `until ! pgrep -f build.sh` loop waits forever on itself. Match on a
  container name or a PID.
- **A renamed OSD option must move with its manual row** (`tools/docs_check.py` enforces
  parity) — and, less mechanically, **a row whose description stops being true is a
  documentation bug**: this feature's row said it "changes only memory traffic, never the
  picture", which silently became false the moment the term consumed it.

---

## 8. If anyone revisits deinterlacing

⛔ **Not a recommendation to do so.** The maintainer's position (§0) is that `main`'s
progressive output is good enough and that most users watch on 480i CRTs, where the
deinterlacer is not in the path at all. Treat the following as a shortcut for someone who
has *already* decided to revisit it, not as an argument for revisiting it:

- **The spatial class is already bounded.** Edge-directed interpolation measured
  dominance **D = 1.00** — indistinguishable from the existing soft-span knob — and an
  *oracle* picking the best candidate closed only 0.10–0.42 of the gap, under the
  pre-registered 0.50 stop. yadif's spatial half is that same class.
- **A gate is the wrong shape for temporal information.** Stage B's veto could *suppress
  a true comb*, which is what killed it. yadif and bwdif never gate: they interpolate
  unconditionally and then **clamp** the result into a temporally plausible range, which
  structurally cannot do worse than the spatial prediction. That difference — not the
  quality of the interpolator — is the thing worth prototyping.
- **The blockers are fabric and causality, not bandwidth** (§1 removed bandwidth):
  ~2,900 ALM and 41 M10K spare, `clk_dec` already the limiter, and yadif's temporal check
  is **non-causal** — it needs the *next* field, i.e. one full picture of display latency,
  which touches A/V anchoring, the pause/still paths and the governor.
- **Prototype in `tools/deint_model.py` first, and add a metric for the artifacts that
  killed this attempt** (comb surviving on slowly-moving edges; mask edges visible as a
  one-frame trail). That discipline killed the ELA idea for a few hours of work instead of
  several hardware rounds — and §4.4 is the reason the same discipline failed here.
