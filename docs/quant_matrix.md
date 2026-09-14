# The quantiser matrix is lost at a VBUF flush ("deep fried" menu stills)

**Status: ⛔ NOT FIXED. The fix REGRESSED on hardware and is being bisected.**
Branch `fix/quant-matrix-flush`, not merged, not pushed. §9 is the live record —
read it before anything else here, because §6's fix is the thing that regressed.

⚠ `bench/dvd/run_quant_matrix.sh` is NOT a safety gate for the vld change. It
measures the quantiser-matrix landing and passed 12/12 on a build that produces
magenta/green garbage on hardware. The real gate is the title->menu re-entry
test on the rig (§9.1).

---

## 1. The report, and what it actually was

A user parking on the main menu of *Wake Up With Elmo* (`/mnt/dvd/tv/WAKE_UP_WITH_ELMO.iso`)
saw the still come up **"deep fried"**: fine texture exploded into vivid speckle,
highlights clipped to white, colours oversaturated, and complementary-colour halos
around the coloured text — yellow around the blue, cyan around the orange. Pressing
Select once repainted it correctly *without* activating the button; a second press
activated.

**Root cause: the still is dequantised with the MPEG *default* intra quantiser matrix
instead of the custom one its own sequence header downloads.**

Those five menu stills each carry `load_intra_quantiser_matrix = 1` with a near-flat
matrix — DC 8, all 63 AC coefficients 4 — where the MPEG default ramps to 83. Decode
with the default and every AC coefficient comes out **4× to 20.75×** too large. The DC
term and the hue are untouched, which is exactly why the picture stays recognisable and
correctly coloured while its *detail* explodes.

### 1.1 How that was established, before any RTL was read

The matrices were bit-patched to the MPEG defaults **in the real elementary stream** and
the result decoded with ffmpeg. It matches the reporter's screenshot detail for detail —
the same halos on the same words, the same speckle in the same background. Two global-gain
explanations were rendered and rejected on the same evidence: a raw ×2 of all three planes
destroys hue, and a ×2 about mid-grey is far too mild and produces no halos at all.

⚠ Worth keeping as method: the artefact was *reproduced offline from the disc* before the
decoder was opened. Three plausible mechanisms died in the time it took to render them.

---

## 2. Why it looked intermittent, and why only stills

- **Only stills.** A moving title re-sends a sequence header every GOP (~0.5 s), so a lost
  download self-heals within half a second and nobody ever sees it. A menu still is
  `SEQ / GOP / one I picture / SEQ_END` — a single VOBU, **one sequence header, ever**. A
  miss is permanent until something re-decodes.
- **Why a press repairs it.** Entering the menu from a title is a full VBUF flush;
  re-entering the menu from inside the menu domain is a `keep_vbuf` hop (`flush_ctl` gates
  `seek_flush` on `~keep_vbuf`), so no VBUF flush and the parser is undisturbed.
- **Why "sometimes".** MEASURED, not argued: sweeping the flush across the parse,
  **8 of 10 positions lose the matrix and 2 survive**. It is a function of where the
  parser stood when the flush landed, not of chance.

### 2.1 ★★ The natural experiment that confirmed it without hardware

The reporter added, unprompted: *on v0.4.0 the fried image flashes for a split second and
then resolves to the good image; on v0.5.0 and current dev builds it holds.*

| tag | date | menu-still cold re-decode |
|---|---|---|
| v0.4.0 | 2026-09-04 | **present** |
| v0.5.0 | 2026-09-10 | **removed** — commit `b900478`, issue #65, 2026-09-08 |

v0.4.0 decoded the still **twice**. The first decode was damaged by the flush (the flash);
the cold re-decode then re-streamed the whole cell from its start, so the sequence header
was parsed cleanly, the matrix landed, and the picture was repainted correctly. Issue #65
removed that re-stream — and with it an accidental repair nobody knew was load-bearing.

⛔ **This is NOT a 0.5.0 decoder regression and `b900478` must NOT be reverted.** The defect
is older and was merely masked. The removal was correct on its own terms: the re-stream was
vestigial for the display path and replayed narration audio on stills that carry speech,
which is what issue #65 reported. Anyone bisecting this symptom will land on `b900478`; it
is the unmasker, not the cause.

⚠ The removal note in `dvd/dvd_iso_reader.sv` concluded *"the re-stream was therefore doing
no work the decoder had not already done."* That was wrong in one respect, and the comment
has been amended: it was repairing a lost quantiser matrix.

---

## 3. The mechanism

`rtl/mpeg2/vld.v` resets its state machine **only** on `rst` (= `sync_rst`). A `vbuf_flush`
did not return it to `STATE_NEXT_START_CODE`. `mpeg2video.v` holds the VBUF in reset for the
whole flush level (`.asyncrst(rst && ~flush_vbuf_eff)`), so the parser starves *mid-picture*
and then **resumes in that stale state** when the landing stream arrives — consuming its
leading bytes as if they were the old picture's coefficients. That routinely swallows
`00 00 01 B3` and the 64+64-byte matrix download behind it, after which the parser resyncs
on a later start code (the GOP or picture header) and decodes the still quite happily with
the wrong matrix.

`rtl/mpeg2/iquant.v` then converts a partial loss into a total one. `default_values` is an
**all-or-nothing latch**, cleared only by a write to address `6'h3f`, so losing any part of
the download discards the *entire* custom matrix and silently reverts to the defaults.

### 3.1 ★★ And there is a second half, which the first fix attempt exposed

Forcing the parser back to a start-code hunt recovers **9 of 10** swept flush positions —
and not the tenth. Instrumenting the survivor showed why, and it is the more interesting
half: **`getbits_fifo` was reset by `sync_rst`, not by the flush**, so its 129-bit window
still held up to 16 bytes of the stream that had just been thrown away. Worse, the PTS
work already clears that module's *position* counter at every flush
(`pos_clr(~vbuf_rst)`) — so after a flush the window's **content and position disagreed**.

MEASURED, from the parser's own dispatch log at the failing position. Before:

```
codes = b5 b5 b5 b8 00 b5 01 02      <- the landing's b3 is MISSING
seqhdr_after=0  quant_rst_after=0  downloads=0
```

The parser matched a phantom `00 00 01` inside the stale residue, dispatched on it, and
came out **bit-misaligned** (the 24-bit window shifted by 4 bits between successive hunt
cycles), so the landing's byte-aligned `00 00 01 B3` slid past unseen. After flushing the
window with the VBUF:

```
codes = b3 b5 b5 b8 00 b5 01 02      <- the sequence header is found FIRST
seqhdr_after=1  quant_rst_after=1  downloads=1  dl_bytes=64
```

**Both changes are necessary and they fix different things**: one resets the parser, the
other stops it being handed a dead stream to parse.

⚠ Worth keeping as method: the first fix was declared not to work on the strength of **one**
flush position. It had in fact fixed nine of ten. Sweep before concluding.

★ The no-flush control passes on the **same splice**, which is what isolates the flush as
the variable. It passes because without a flush the parser still has cut A's trailing bytes
to chew, errors out on them and resyncs *before* the landing's sequence header arrives. A
flush discards that tail and hands the stale parser the landing directly.

---

## 4. A second, independent bug found en route — the un-zigzag scan

`iquant.v` un-zigzagged the download using the **live** `alternate_scan`, which at
sequence-header time still holds the **previous picture's** value. ISO 13818-2 **7.3.1**
says the download is always in zigzag (scan 0) order — and the module's own header comment
said exactly that, directly above the code contradicting it. The read side was never
symmetric: `rld.v` un-zigzags the read address with the *current* picture's
`quant_alternate_scan`, so the RAM is indexed in raster order and the write must always use
scan 0.

⚠ **It is invisible on a flat matrix** — zigzag index 0 maps to raster 0 under both scans,
and every other entry is interchangeable — which is why the disc that exposed the flush
defect could not expose this one. `tools/quant_fixture.py --matrix-probe` patches a
64-distinct-value matrix into the real stream so the bench can see it: RED reports
**58/64 wrong with `permutation=1`**, i.e. the multiset matches exactly and only the
positions moved.

---

## 5. Blast radius, measured

`tools/qmatrix_scan.py` over the library (957 images). ★ It reads the default matrices
**out of `rtl/mpeg2/iquant.v`** rather than restating 64 numbers — the `acmod_scan.py`
lesson: a table that cannot go stale beats a correct one.

| | |
|---|---|
| discs downloading a matrix in a menu VOB | **820 / 957 (86 %)** |
| worst default/custom ratio > 2× | **533 (56 %)** |
| worst ratio > 10× | 292 |
| median worst ratio / maximum | 3.77 / **83.00** |
| discs exposed to the scan bug (varied matrix **and** an `alternate_scan=1` title) | **480** |

Custom matrices in menus are the norm in DVD authoring, not an Elmo quirk. ⚠ Scope stated
honestly in the tool: it samples menu VOB *heads*, so a sequence header deeper than the
window is not counted, and title-domain downloads are out of scope unless `--titles`.

---

## 6. The fix

### 6.0 `rtl/mpeg2/mpeg2video.v` — the bit window is flushed with the VBUF

`getbits_fifo`'s `.rst` moves from `sync_rst` to `vbuf_rst`. See §3.1: the window held
bytes of a discarded stream while its position counter had already been reset, and the
parser matched a phantom start code inside them. One line; it is the half that closes the
flush-at-a-picture-header case.

### 6.1 `rtl/mpeg2/vld.v` — a flush returns the parser to a start-code hunt

A one-bit `flush_resync` sticky, **set ungated by `clk_en`** and dominant over `next`:

- set on `vbuf_flush`, cleared on the first enabled cycle, set beats clear;
- `state <= flush_resync ? STATE_NEXT_START_CODE : next`.

★ Ungated for the same reason the issue-#45 `ra_active` arm is: `motcomp.v` freezes the vld
at every picture header until picbuf's display handshake — up to a whole display frame —
while the flush level is ~192 clk_dec cycles. A `clk_en`-gated capture would miss it
routinely, not rarely.

Cleared on the same term, all of it mid-parse scratch that can mis-route the landing's
first bytes: `drop_this_picture` (a stale verdict routes the landing's slices away),
`drop_gov_picture` (its ledger twin — else a post-flush `drop_pic_ack` pays a credit into
`frame_drop_ctl` for a picture the governor never asked to drop), `skip_d_picture`, and
`picture_header_seen` (the only flag whose stale value admits a slice into a *stale* picture
header — it otherwise clears only at `STATE_SEQUENCE_END`, which a seek never produces).

⚠ **And the line-21 CC snoop**, which is the non-obvious one: it walks `user_data` bytes for
as long as the FSM stays in `STATE_NEXT_START_CODE` — which this fix now *pins it at*. A
flush landing mid-`user_data` would otherwise keep sniffing across the junction and could
synthesise a caption pair out of two unrelated streams.

### 6.2 ⛔ Two clears that were REJECTED, and why

Rejecting these is the load-bearing part of the design, not a detail:

- **`sequence_header_seen`** — `vld.v` refuses the landing's picture start code and every
  slice without it. On a landing whose header is for any reason not parsed, clearing it
  means *nothing decodes at all*: a **black** menu, strictly worse than a fried one.
- **`sequence_extension_seen`** — `mpeg1 <= ~sequence_extension_seen` latches at the next
  picture start code. Clearing it would latch a **false MPEG-1 verdict**, which forces
  `intra_dc_precision` to 0 while these stills code 2, shifting the intra DC by 3 instead of
  1 = **4× on every DC coefficient**. That trades this bug for a worse one.

Neither needs clearing: `sequence_extension_seen` is already re-armed at every
`STATE_SEQUENCE_HEADER`, and with the state forced the landing's own sequence header is now
*parsed* rather than eaten, which is the entire point. **The seen-flags were always
self-healing; the FSM position was not.**

### 6.3 `rtl/mpeg2/iquant.v`

`scan_reverse(1'b0, wr_addr)` in both module copies, and in the two `` `ifdef DEBUG ``
`$display`s that printed the same expression.

⚠ The `alternate_scan` **port is deliberately left in place** though nothing reads it. The
original plan was to delete it so the bug could not return, but `quant_matrix_tb`
instantiates these modules and a bench cannot compile against both a module that has the
port and one that does not — deleting it would make the RED arm unbuildable. The guard is
the bench arm, not the port's absence.

---

## 7. The gate

`bench/dvd/run_quant_matrix.sh` (`--red` runs the pre-fix arms first).
`bench/dvd/quant_matrix_tb.sv` runs the **real** `getbits_fifo` + `vld` + `rld_fifo` + `rld`
+ both matrix RAMs over **real disc bytes**.

★ **It compares the matrix the hardware ends up holding against the bytes on the disc**, not
against any signal the fix names — `default_values` is reported as diagnostic only. A
**shadow pair** of the same two matrix modules, fed the identical `rld` write stream, exists
purely to give the bench a read port (`rld` drives the live RAM's read address). That is the
same RTL with the same stimulus, not a model.

⚠⚠ **The fidelity detail that would silently invert the verdict.** On hardware the VBUF is
in reset for the whole flush level, so no landing byte can reach `getbits` until it drops.
`seek_realign_tb` keeps feeding across its jump; this bench must not. If it did, the
**fixed** forced hunt would eat real landing start codes and the arm would condemn correct
RTL. `+FEEDTHRU=1` reproduces that hazard on purpose as a documented negative arm.

⚠ Two more bench traps, both of which produced a confident wrong reading first:

1. **The matrix RAMs run a 64-cycle `STATE_CLEAR` init out of reset** and writes during it
   are overridden. Feeding immediately let a cold-start download begin inside that window
   and lose its first ten entries — which reads exactly like the defect (`got=0` at the
   first ten *zigzag* positions) and is pure artefact. The feed now waits 200 cycles.
2. **`rld_cmd` is 2 bits.** Declaring it 1 bit made Icarus pad the high bit and would have
   destroyed the QUANT-vs-DCT discrimination the whole bench rests on.

### 7.1 Measured

With **only** the `vld.v` half applied, the sweep reads **9 pass / 1 fried** — the
survivor being the flush that lands at a picture header. With both halves, 10/10.

RED, against genuinely unmodified RTL, sweeping the flush across the parse:

```
control A (same splice, NO flush)   mismatches=0/64  downloads=1   PASS
control B (cold start on the still) mismatches=0/64  downloads=1   PASS
FLUSHDLY=0     63/64  downloads=0  state_at_flush=03  FRIED
FLUSHDLY=60    63/64  downloads=0  state_at_flush=75  FRIED
FLUSHDLY=140   63/64  downloads=0  state_at_flush=76  FRIED
FLUSHDLY=260   63/64  downloads=0  state_at_flush=75  FRIED
FLUSHDLY=400   63/64  downloads=0  state_at_flush=38  FRIED
FLUSHDLY=620   63/64  downloads=0  state_at_flush=76  FRIED
FLUSHDLY=900   63/64  downloads=0  state_at_flush=76  FRIED
FLUSHDLY=1300   0/64  downloads=1  state_at_flush=76  PASS
FLUSHDLY=1800   0/64  downloads=1  state_at_flush=76  PASS
FLUSHDLY=2500  63/64  downloads=0  state_at_flush=76  FRIED
```

`downloads=0` is the sharp end: the download did not merely land wrong, **it never happened
at all** — the sequence header was eaten. `distinct_used` reports 14–19 distinct matrix
values actually used to dequantise a picture whose matrix has **two**.

Scan-bug RED (`--matrix-probe`, no flush): `mismatches=58/64 permutation=1 downloads=1`.

---

## 8. Open / next

- ⏳ **HW confirmation.** Acceptance is **no fried frame at all**, not "as good as v0.4.0":
  v0.4.0 showed one and then repaired it, so a surviving flash would mean the first decode
  is still damaged and only the repair changed. Sample shots across the first ~500 ms after
  the menu appears, not one settled shot. Classification is automatic — correlate against
  the two locally rendered references (correct vs default-matrix), which are trivially
  separable.
- ⏳ The still-open **two-press activation** on this disc is a separate item; see
  `docs/dvd_nav.md`. It is not caused by this defect, though the same press repairs both.


---

## 9. Hardware rounds — the fix regressed, and two theories died (2026-09-14)

### 9.1 ★ The original defect is REPRODUCED on hardware, and the path matters

Rebooting the disc reproduces it about one time in three, which is useless as a
gate. **Title->menu re-entry reproduces it in ~2 minutes**: press Play Story,
wait, press Menu. That is a domain change, so `flush_ctl` gates `seek_flush` on
`~keep_vbuf` and it is a FULL VBUF flush — the exact path §3 is about. Measured
on the pre-fix core (`dev-titlespan`), 7 samples:

    5 CORRECT / 2 FRIED / 0 garbage

That is the RED arm this work never had. Use this path, not reboots.

Every frame is classified three ways (`fry_classify.py` in the session
scratchpad) against two references rendered locally from the same elementary
stream: the still with the disc's own matrix, and with the defaults substituted.
★ **The third verdict, GARBAGE, is not decoration.** A nearest-reference test
can only say "better or worse"; it would have binned the regression below as
whichever reference happened to be nearer and reported a NEW defect as a partial
success.

### 9.2 ⛔ The regression

Flashing the §6 fix gave magenta/green striped garbage on the re-entry path:
hue inverted (magenta where the menu is pale green, green where Elmo is red),
fine horizontal banding, geometry and text intact. It persists through chapter
skips and clears only by remounting the disc. Bisect, same path and instrument:

| build | result |
|---|---|
| pre-fix `dev-titlespan` | 5 CORRECT / 2 FRIED / 0 garbage |
| vld + getbits + iquant | mostly GARBAGE |
| vld + iquant (getbits reverted) | 2 CORRECT / 6 GARBAGE |

So it is **`vld.v`'s `flush_resync`**, not the `getbits_fifo` change that was
reverted first on a wrong call. `iquant` is excluded independently: this disc's
matrix is flat, so a permutation of it is unobservable, and the matrix is not in
the intra DC path at all.

### 9.3 ⛔ REFUTED: the false MPEG-1 verdict / wrapped DC

The best theory, and it fitted every visible element. A false `mpeg1` forces
`intra_dc_precision` to 0; `rld.v:362` then shifts the DC by 3 into a **13-bit**
register from a 12-bit signed level, which overflows and **wraps**; a wrapped
chroma DC is an inverted hue and a wrapped luma DC is the banding; `mpeg1` is
latched on `sync_rst`, so it survives chapter skips and clears on a remount.

**MEASURED AND FALSE.** Telemetry word 5 was repurposed to carry
`{dcprec_chg, mpeg1_rises, intra_dc_precision, mpeg1}` — both signals had been
invisible, so the board could not be asked. Six garbage frames, every one:

    mpeg1=0   intra_dc_precision=2 (the stream's own value)   mpeg1_rises=0

★★ **The durable lesson. Three constructed SIM arms had already failed to
reproduce it** (flush aimed at `STATE_SEQUENCE_HEADER`; a second flush inside
the landing's sequence header; a landing starting past it) **and I read that as
the arms being wrong rather than the theory being wrong.** One instrumented
hardware run settled it in minutes. When a theory needs increasingly specific
scenarios to survive, measure its PREMISE instead of building another scenario.

### 9.4 ⛔ REFUTED: the getbits_fifo reset domain

Three forms were built and the garbage survived all three, so flushing that
window is not the cause of the regression — but two real defects were found on
the way and are recorded in `mpeg2video.v`:

  * `.rst(vbuf_rst)` alone silently dropped the module from the WATCHDOG reset
    and the mount SOFT reset (only `sync_rst` carries those), and let it leave
    reset ahead of the vld/rld/framestore.
  * `.rst(sync_rst && vbuf_rst)` fixed that and cost **7 MHz** — clk_dec 85.46
    @-40C, below the 86.0 gate. ★ A bare AND puts a COMBINATIONAL net on a large
    module's reset tree. Combine before a `sync_reset`; "logically equivalent"
    reset expressions are not equivalent to the fitter.

The change is reverted: it bought one swept flush position in 12 and is not
worth another hardware round.

⚠ Also established: the build the user tested closed timing with margin
(95.53/91.07), so the regression is a FUNCTIONAL defect, not a marginal-fit
artifact. That excludes the placement/fringe class.

### 9.5 ⛔ RESULT: the state force ITSELF is the cause — approach abandoned

The state-force-only build (every clear removed, leaving just
`state <= flush_resync ? STATE_NEXT_START_CODE : next`) **still garbages** on the
re-entry path. So none of the five clears was responsible: **forcing the parser
to a start-code hunt at a VBUF flush is the wrong approach**, and the branch was
abandoned rather than patched a fourth time. `rtl/mpeg2/vld.v` is byte-identical
to `main` again.

⚠ Why it is wrong is NOT established. What is established is that it cannot be
made right by adjusting what it clears. A future attempt needs a different
mechanism, and should note that the parser evidently depends on state that the
forced transition discards — the next thing to measure is what the landing
picture's chroma is built from, since the symptom is a preserved-geometry hue
inversion and the DC-path inputs were measured CORRECT.

### 9.6 What survives, and what is still open

**Still open: the original fried-still defect.** Unfixed, reproducible in ~2
minutes (§9.1), affecting 820/957 discs by the census.

**Kept, all independent of the abandoned fix:**
  * `tools/qmatrix_scan.py` — the census, reading the defaults out of the RTL
  * `tools/quant_fixture.py` — the fixture cutter, with its refusals
  * `bench/dvd/quant_matrix_tb.sv` + `run_quant_matrix.sh` — now a REPRODUCTION
    harness, gating only the controls and the scan fix
  * `rtl/mpeg2/iquant.v` — the 13818-2 7.3.1 un-zigzag fix (480 discs exposed)
  * the ⛔ record in `mpeg2video.v` of the three getbits reset forms
  * this document

### 9.7 Where it stood mid-bisect (superseded by §9.5)

The remaining bisect splits `flush_resync` itself: all five clears removed
(`drop_this_picture`, `drop_gov_picture`, `skip_d_picture`,
`picture_header_seen`, and the line-21 CC snoop), leaving only

    state <= flush_resync ? STATE_NEXT_START_CODE : next;

That is also the minimal form of the fix. If it is clean on the re-entry path it
ships as-is; **if it still garbages, forcing the parser at a flush is the wrong
approach and this branch should be abandoned rather than patched again.** The
salvageable parts are separable and independent of the vld change:
`tools/qmatrix_scan.py`, `tools/quant_fixture.py`, the bench, the 13818-2 7.3.1
scan fix in `iquant.v`, and this document.


---

## 10. The chroma work — what the garbage ACTUALLY is (2026-09-14)

§9.5 left the regression's mechanism unexplained and pointed at the chroma path.
That measurement has now been made, **offline, from frames already captured**,
and it is conclusive about the artefact even though not yet about its cause.

### 10.1 ★★ MEASURED: both chroma planes carry LUMA

Compare a CORRECT menu frame and a GARBAGE one, both 720x480 captures of the
same still from the same board through the same path — no rescale, no re-render,
no alignment guesswork. Convert to BT.601 YCbCr and cross-correlate every plane
pair at 8x8 block DC (an MPEG intra block's DC is its 8x8 mean, and DC is coded
by a different path from the AC coefficients, so averaging separates them):

```
            good Y   good Cb   good Cr     best match
  bad Y      0.212     0.060    -0.193     Y  (+0.21)
  bad Cb     0.726     0.203    -0.691     Y  (+0.73)
  bad Cr     0.701     0.203    -0.649     Y  (+0.70)

  bad Cb =  0.560 * good Y  +  64.3   r=+0.726
  bad Cr =  0.618 * good Y  +  59.3   r=+0.701
```

**Both chroma planes are a linear function of the GOOD frame's LUMA**, with
near-identical coefficients, while bad luma correlates with nothing much.
Reproduced on three independent frames from two different builds.

Plane energies (block-DC std) say the same thing — the energy MOVED:

```
  good   Y 52.62   Cb  9.74   Cr 25.12
  bad    Y 35.52   Cb 40.59   Cr 46.37      <- chroma now carries more than luma
```

and the AC detail energy confirms it: luma detail DOWN to 0.57x, chroma detail
UP 2.0-2.35x.

★ **This explains the screenshot exactly, which is how you know the measurement
is of the right thing.** Cb and Cr both track luma, so where luma is high (the
pale background) both go high — and Cb=Cr high is **magenta**; where luma is low
(Elmo, the text) both go low — and Cb=Cr low is **green**. A magenta background
with a green Elmo is not a hue "inversion" at all. It is the chroma planes being
fed luma.

⚠ The first analysis DID call it an inversion: a naive per-plane fit reported
`bad Cr = -1.08 * good Cr + 302`, a textbook inversion signature. That fit is an
artefact of assuming bad Cr came from good Cr. In this image luma and Cr are
naturally anti-correlated (pale green background = high Y, low Cr; dark red Elmo
= low Y, high Cr), so luma-in-Cr *masquerades* as inverted Cr. **Cross-correlate
every pair before believing a one-to-one fit.**

### 10.2 The inference, and what is NOT established

Luma blocks landing in the chroma planes is a **block-count / component-assignment
desync**. The parameter that sets blocks-per-macroblock is `chroma_format`
(`vld.v:1727`, `:2879`, `:2915` — 6 blocks for 4:2:0, 8 for 4:2:2, 12 for 4:4:4),
it is latched by a `loadreg` whenever `state == STATE_SEQUENCE_EXT`, and
`mpeg1` was measured 0 so the latched value is what is used.

A mechanism exists on paper: the abandoned state force makes the parser HUNT
through post-flush garbage, and a false `00 00 01 B5` in that garbage dispatches
into `STATE_SEQUENCE_EXT`, where `loadreg` latches whatever is in the bit window
into `chroma_format` (and `progressive_sequence`, and the size extension bits).
Before the state force the parser was stuck mid-picture and never hunted, so it
never dispatched on a false extension code.

⛔ **NOT CONFIRMED.** Simulation reports `chroma_format=1` (correct) at every
swept flush position, with exactly the three legitimate extension start codes.
That is the SECOND time this bench has been structurally unable to reproduce a
real defect, and for the same reason both times: **its landing always begins with
a clean sequence header, so the parser never hunts through garbage.** A fixture
whose landing starts mid-stream is the missing arm.

### 10.3 Next step, and why it may unlock the fix

Instrument `chroma_format` and the extension-dispatch count on the board, with
the state force re-applied to reproduce, and read them on a garbage frame. One
run decides it — the same method that killed the MPEG-1 theory in §9.3.

★ If it is confirmed, the fix direction follows immediately and is narrow:
**after a flush, refuse extension start codes until a sequence header has been
parsed**, so a hunt through garbage cannot latch sequence-level parameters. That
would make the whole flush_resync approach viable rather than abandoned.
