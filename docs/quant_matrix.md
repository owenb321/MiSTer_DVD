# The quantiser matrix is lost at a VBUF flush ("deep fried" menu stills)

**Status: ✅ FIXED by a decoder SOFT RESET on VM jumps (2026-09-14, §11) — sim-proven
RED/GREEN and ✅ HW-CONFIRMED 2026-09-14 against its own control (§11.4).** Branch
`fix/quant-matrix-flush`, **merged as PR #92 (`ddb910c`)**. §6's vld-only fix REGRESSED on hardware and is reverted; §9–§10 are the record
of that, and §11 is what replaced it. The two things that survive from the first
attempt are the `iquant.v` 7.3.1 scan fix (§4) and the bench (§7, now gated on the
soft reset).

⚠ `bench/dvd/run_quant_matrix.sh` gates the MATRIX landing (`+SOFTRST=1`, 12/12). It
cannot see a block-count desync that lands in motcomp — the earlier vld-only fix
passed it 12/12 and produced garbage on the board — so the title->menu re-entry test
on the rig (§9.1, §11.3) is part of the gate, not optional.

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
  ⚠ **"undisturbed" is too strong, corrected 2026-09-14.** A `keep_vbuf` hop preserves the
  VBUF but still pulses `load_flush`, and until that date the reader also DROPPED up to
  16 KB of the source cell that it had never delivered — so the decoder could be handed a
  stream cut mid-slice with the landing right behind it. **That does NOT lose the matrix**:
  `bench/dvd/run_menu_junction.sh` measures exactly this splice on the real T2 cells and
  all seven truncation offsets come back 0/64 wrong, because with the bytes CONTIGUOUS the
  parser errors out and resyncs before the landing's header. Losing the matrix needs the
  FLUSH — the tail discarded and the parser frozen mid-picture. The dropped tail was a real
  defect with a different (still open) visible consequence; see
  `docs/dvd_menu_refinements.md` §9.
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

## 11. The fix that replaced §6 — reset the whole pipeline, not one register (2026-09-14)

### 11.1 The chroma HW round: `chroma_format` is exonerated

§10.3's measurement was made. A diagnostic core (state force re-applied on purpose,
telemetry word 5 = `{extsc_n, seqext_n, chroma_format}`) was flashed and the
title->menu re-entry driven from the harness: 4 boots x 3 re-entries, then 3 x 6.

```
  run 1   12 re-entries   3 garbage frames (2 onsets; b2_re2 -> b2_re3 identical,
                          i.e. it PERSISTS, as reported)
  run 2   18 re-entries   0 garbage
  every garbage frame:    chroma_format = 1   (4:2:0 -- correct)
```

So the register that sets blocks-per-macroblock is right at the moment the picture
is wrong. **`chroma_format` is not the cause**; the desync is below it. `seqext_n`
and `extsc_n` had both SATURATED (63 / 255) by the first garbage sample — they reset
at core reset, not at the flush — so §10.3's second question (did the post-flush hunt
dispatch phantom extension codes) went unanswered. It no longer needs answering.

Two measurement lessons, both paid for on the rig:

- ★ **A reference-free garbage classifier must test r(Cb,Cr), not r(Cb,Y).** §10.1
  correlated bad chroma against the GOOD frame's luma. Within one garbage frame the
  luma plane is itself wrong (bad Y tracks good Y only +0.21), so r(Cb,Y) measures
  nothing — the first classifier called a textbook garbage frame PICTURE. What
  survives without a reference: **both chroma planes carry the same signal** (r(Cb,Cr)
  = +0.767 vs −0.40 on the correct menu) and **chroma carries luma-rate detail** —
  3x3 high-pass energy of Cb reads 0.98 on every correct menu and 5.00 / 6.40 on the
  two garbage variants, and 4:2:0 chroma is subsampled, so it physically cannot hold
  that. The second variant (blue-violet, not magenta) has r(Cb,Cr) only +0.24; the
  chroma-AC test catches both.
- ⚠ **`seqext_n` climbing 22 -> 41 between samples was read first as "the story
  played" and then, when the same numbers repeated on every boot, as "the presses
  never landed". Both inferences were unsafe** — it is a per-GOP counter and a
  looping menu re-sends headers too. The garbage frame itself settled it: a garbage
  MENU can only exist if the re-entry happened. Measure the transition (a shot
  during playback), do not infer it from a counter.

### 11.2 The fix

A VBUF flush discards the buffered BYTES and leaves the whole decode pipeline — vld
state, getbits window, rld fifo, iquant, motcomp, picbuf — frozen mid-picture (the
upstream "trick play" flush resets only the VBUF FIFOs). The landing arrives INTO
that. A moving title self-heals at its next GOP header; a menu still is one sequence
header, so whatever the stale pipeline eats at the landing is what you look at.

§6 re-synced ONE register (the vld state machine) and left a partial block in the rld
fifo — hence luma blocks in the chroma planes. The pipeline's state is coupled: reset
all of it or none of it. And the design already has "all of it": the watchdog-
equivalent decoder soft reset a file mount has used since 2026-08-28
(`flush_ctl.mount_flush -> mpeg2video.soft_flush -> reset.soft_rst_n`, HW-proven).

**`dvd/flush_ctl.sv` now raises a new `soft_flush` on a `~keep_vbuf` VM JUMP** —
title->menu on the Menu key, the First Play chain into a menu, menu->title Play — as
well as on a mount. `mount_flush` is kept separate and stays mount-only because
`pal_detect` keys its immediate PAL re-arm on it. Transport seeks (`seek_ack`) and
mode switches are deliberately NOT included, so the seek-realign "hold the last
frame" decision (`flush_ctl.sv` "THE RULE ITSELF STANDS") is untouched: a chapter
skip keeps its held frame; a menu entry/exit becomes a brief black cut — which is what
a set-top player does on exactly those transitions. Maintainer decision, 2026-09-14.

Why this is stronger than v0.4.0, not merely equal: v0.4.0's cold re-decode showed a
fried frame and then repaired it; here the FIRST decode is correct, because the
landing's own sequence header is the first thing a clean parser sees.

### 11.3 Gates

- `bench/dvd/flush_ctl_tb.sv` gains a sixth column. GREEN 11/11; against the pre-fix
  module it fails **exactly row [4]** (`~keep_vbuf jump: soft=0, want 1`).
- `bench/dvd/quant_matrix_tb.sv` `+SOFTRST=1` holds EVERY module on `sync_rst` in
  reset for the flush level — the same thing `reset.soft_rst_n` does — and
  `run_quant_matrix.sh` arm [2g] is gated on it: **12/12** positions recover the
  matrix, with `codes=b3 b5 b5 b8 ...` (the landing header parsed first,
  `downloads=1`, 0/64 mismatches). Arm [2], the same sweep on the shipped decoder,
  is the RED arm and loses **10/12**. `getbits_fifo` is back on `sync_rst` in the
  bench, as shipped.
- `+BSKIP` / `+REFLUSH2` with the soft reset come back VACUOUS: a landing with no
  sequence header decodes nothing after a reset (`sequence_header_seen` gates the
  picture start code), which is the correct behaviour and cannot happen on a VM jump —
  the reader lands every jump on a cell start (NAV pack + sequence header), the same
  guarantee the mount path already relies on.
- ✅ HW gate (§11.4): the §9.1 re-entry test on the reporting disc — no fried frame and
  no garbage, first capture and settled; chapter skips still hold; the cut on menu entry
  is below the harness's resolution.

### 11.4 HW round — the fix confirmed against its own control (2026-09-14)

Build `DVD_quantmatrix_20260914_1221.rbf` (commit `8ba6ba7`, SEED 7 first roll, 91 % ALM,
clk_dec 93.02 @100C / 91.69 @-40C, gate 86.0). Same script on both cores, on the
reporting disc: 2 boots x (a 14-shot burst across the FP chain's landing on the menu +
4 title->menu re-entries, each with a target-side burst from ~0.7 s after the Menu key
plus a settled shot, plus a "playing" shot that proves the transition happened) + a
chapter-skip burst per boot. Verdicts from the reference-free classifier (§11.1);
the fried frame was confirmed by eye.

```
                       pre-fix core (iquant-only, _0556)     fix (_1221)
  re-entries                       8                              8
  FRIED                4 frames = ONE onset (b2_re1), HELD         0
                       through burst + settled; the NEXT
                       re-entry repaired it (the report)
  GARBAGE                          0                              0
  first burst shot     correct menu on 7/8                  correct menu on 8/8
  chapter skip         held frame, no black (3/3 bursts)    held frame, no black (3/3)
  boot landing         1 black frame at ~24 s (both boots)  1 black frame at ~24 s (1 boot)
```

★ **The black cut costs nothing visible that was not already there.** The FP->menu landing
showed a black frame on the PRE-fix core too (the reader's cell load), and on the fix core
the menu is already correct at the first capture ~0.7 s after the Menu key — the soft
reset's cut is shorter than the harness can resolve.

⚠ Harness limits, recorded: the MiSTer `screenshot` path takes ~1 s, so a 0.4 s burst
yields ~3 of 8 frames (~1.2 s apart) — "no fried frame at all" is established at that
resolution, plus the settled shot. The fried rate on the pre-fix core is low (1 onset in 8
here, 1 in 9 and 2 in 7 on earlier rounds), so the control arm exists to prove the
instrument, not to measure a rate. Issue #65 (a narration still must not replay its
audio) is not automated here: structurally the soft reset re-streams nothing and
`aud_flush` already fires on the same `jump_flush`, so a replay has no mechanism —
a maintainer ear-check closes it.

---

## 12. The §11 fix shipped WIDER than its own description, and it drew a resolution popup (2026-09-15)

Branch `fix/soft-reset-scope`. Field report on Scooby-Doo 2's *Monsters Unleashed
Challenge*: the screen flashes black for a frame **and the MiSTer resolution popup
appears** on some transitions between game screens — moving the van on the overworld
map, consistently, at every direction press.

Two separate defects. One is §11's scope; the other is older than §11 and is what
actually draws the popup.

### 12a. `~keep_vbuf` is not "a menu transition"

§11's comment enumerates what it was written for — *"title→menu on the Menu key, the
First Play chain into a menu, menu→title Play"* — and the predicate it shipped was

```systemverilog
wire jump_flush = jump_ack && ~keep_vbuf;      // arms jump_soft_cnt
```

`keep_vbuf` is `menu_dom && (target is a menu)` at every one of its assignment sites in
`dvd_iso_reader.sv`. It is a fact about the **domain**, so `~keep_vbuf` is true for every
title-domain jump as well. On an ordinary movie the intended set and the selected set
nearly coincide and nothing shows. On a **DVD-game disc, whose menus are authored as
TITLE-domain PGCs**, every screen transition is a title→title `LinkPGCN` — so ordinary
gameplay navigation took a full decoder reset.

This is the same shape as issue #81 (*a menu CONTEXT is not a menu DOMAIN*). The durable
rule: **derive a predicate from what it SELECTS, not from the cases it was written for**,
and when a comment enumerates cases, check that the expression below it selects those and
only those.

**Fix.** The reader publishes `jump_cross` beside `keep_vbuf`, from the same two values:

```systemverilog
keep_vbuf  <= menu_dom &&  jdom_is_menu;   // "both sides are menus"  -> hold the VBUF
jump_cross <= menu_dom ^   jdom_is_menu;   // "the sides differ"      -> soft-reset
```

⛔ **They are not complements.** A title→title jump is neither: it flushes the VBUF and
must **not** soft-reset. That gap is the whole reason the port exists — do not
"simplify" `jump_cross` to `~keep_vbuf`, and do not gate on `jump_flush` alone again.

Gate: `flush_ctl_tb` row **[4b]** (title→title jump: trio, NO soft reset), proven RED
against the old predicate (`soft=64`, want 0) and the **only** row that fails, so the arm
is specific rather than merely sensitive. Row [4] keeps its pre-#92 RED.

### 12b. A decoder soft reset was dropping SYNC AT THE PINS

This one predates §11 — it has been true of the **mount** soft reset since 2026-08-28 and
of every **watchdog** expiry — and it is what turns a soft reset into a resolution popup.

`soft_rst_n` folds into `comm_rst` (`reset.v:76`), which drives `clk_rst`, `mem_rst` **and
`dot_rst`**. The display chain is

```
syncgen -> mixer -> mpeg2_osd -> yuv2rgb -> pixel_en / h_sync / v_sync
                                          -> emu.sv -> VGA_DE / VGA_HS / VGA_VS
```

and `mixer`, `mpeg2_osd` and `yuv2rgb` all sat on `dot_rst`, each zeroing its
sync/DE registers on reset. So a soft reset drove DE, HSYNC and VSYNC **low at the pins**
for the ~2.4 µs flush level.

⚠ That is precisely what `sw_blank`'s comment in `emu.sv` forbids — *"RGB ONLY —
vga_hs_q/vga_vs_q/vga_de_q below are UNTOUCHED. Dropping sync across a raster change is
the re_interlace S_HUNT defect"* — and the 2026-09-03 single-raster fix had already moved
**`syncgen_intf`** onto `dot_hard_rst` for exactly this class of reason. **It moved the
raster generator but not the pipeline that carries its sync to the pins.** When a fix
protects one stage of a chain from a reset domain, check the rest of the chain.

**Why a popup and not a flicker.** `hps_io`'s `video_calc` counts active dots off DE
(gated by `CE_PIXEL`), rewrites `vid_hcnt` every sampled frame, and **re-arms `resto` on
ANY change**, incrementing `vid_nres` 15 frames later *whether or not the value came
back*. So a transient disturbance is enough; Main runs `video_mode_adjust()` and names the
resolution that is already on screen. (A frame with *zero* DE is skipped by its
`if(hcnt && vcnt)` guard — it is the partial mid-line gap that reports, not a blackout.)

**Fix.** The sync/DE delay line in the three modules takes a new `hard_rst` port, driven
from `dot_hard_rst`. ⚠ Scope is deliberate: the **data** path and `mixer`'s `pixel_rd_en`
handshake stay on `dot_rst`, because `pixel_queue` is reset with them and leaving the
handshake alone would desync the two. With DE live and `state` back at `STATE_INIT` (not a
`displaying` state) `y/u/v_out` take 16/128/128 = black, so the picture goes black for a
few dots while sync keeps running. A black line is invisible; a dropped sync is not.
⚠ `osd.v`'s stages 3–5 run through `alpha_blend_y`'s `dta` pipeline, so that instance
takes `hard_rst` too — resetting the stages either side of a submodule that still zeroed
them would have left the gap open.

### 12c. Measured, on the rig and in sim

Instrument on hardware: Main's own `show_video_info()` log line (`video.cpp:3113`), reached
by setting `debug=2` under `[MiSTer]` (stdout → `/tmp/debug.txt`, `cfg.cpp:447`).
★ A screenshot **cannot** see the popup — captures are the core's raw raster, taken
upstream of the MiSTer OSD — so this log is the only instrument that can count it.

| action | kind | pre-#92 core | shipped #92 |
|---|---|---|---|
| idle playback, 6 s | — | 0 | 0 |
| Play Movie | menu→title crossing | **0** | **1** |
| Menu key | title→menu crossing | **0** | **1** |
| game start | in-PGC cell link (**seek** path) | — | **0** |
| **overworld: Right** | **title→title `LinkPGCN`** | **0** | **1** |

Both arms made the same jump (`CH 1/2` → `CH 4/2`, same target), so the core is the only
variable. Every report reads `720 x 480i` with `AR = 4:3` — the resolution and aspect
already on screen — so nothing about the mode changed. ★ The "some transitions" detail in
the report is confirmed by the game-start row: it changed cell without changing PGCN, took
the seek path, and reported nothing. Only `jump_ack` arms the soft reset.

In sim (`run_sync_integrity.sh --red`): one soft-reset pulse costs **48 active dots** at
the pins and disturbs the emitted sync for **136 cycles** — a 48-dot shortfall on one
line is exactly what makes `video_calc`'s `hcnt` differ and arms Main's report.

### 12d. The gate

**`bench/dvd/run_sync_integrity.sh --red`.** Two identical display chains are driven from
ONE syncgen, so they see the same raster cycle for cycle; chain B takes the `dot_rst`
pulse, chain A does not, and every cycle B's `{pixel_en, h_sync, v_sync}` must equal A's.
It measures the **pins**, never a signal the fix names — a bench asserting "`hard_rst` is
connected" would agree with the RTL by construction.

⚠⚠ **Its first run passed vacuously, with every counter reading 0.** `syncgen`'s counters
are reset *only* by `syncgen_rst`, which in the core is pulsed low by the modeline walk's
register writes (`regfile.v:499`); leaving it high left them at X forever. The bench now
refuses to pass without a live raster (≥100k active dots, ≥100 hsync edges, ≥2 vsync
edges) — a bench that measures the ABSENCE of a difference must prove something was
happening. Same family as `bench-that-cannot-fail`.

### 12e. HW-CONFIRMED (2026-09-15)

Build `DVD_softscope_20260915_1924.rbf`, SEED 7 first roll, clk_dec 94.39/90.27 against
the 86.0 gate, 91 % ALM. Same instrument and same script as §12c, run against the same
two arms, so the three columns are directly comparable:

| action | kind | pre-#92 | shipped #92 | **fixed** |
|---|---|---|---|---|
| idle playback, 6 s | — | 0 | 0 | **0** |
| Play Movie | menu→title crossing | 0 | 1 | **0** |
| Menu key | title→menu crossing | 0 | 1 | **0** |
| **overworld: Right** | **title→title `LinkPGCN`** | 0 | 1 | **0** |

★ **The two crossings are the sharp result, not the van move.** They STILL soft-reset
(that is 12a's design — only the title→title case was removed) and they report **zero**,
which is 12b working on its own: the reset happens and is invisible at the pins. The van
move is 12a.

**The soft reset demonstrably still fires**, incidentally measured: the capture taken
right after the Play Movie crossing came back **σ = 0.0, uniformly black** — the accepted
black cut, still there.

**Blockiness (§12f's risk), measured with the metric from #96** — image energy on the
8-pixel DCT grid ÷ energy off it, ~1.0 clean and ~1.9 fried:

| capture | value | σ |
|---|---|---|
| Scooby title-domain still, room A (in-title navigation) | **1.093** | 67.8 |
| Scooby title-domain still, room B (after a title→title jump) | **1.105** | 52.8 |
| Scooby overworld, fixed vs control | 1.012 vs **1.012** | 35 |
| Scooby game title still, fixed vs control | 1.069 vs **1.069** | 47 |
| T2 timeline menu / main menu after a title→menu re-entry | **1.044** | 37 |

Nothing approaches the fried band, the fix/control pairs are identical to three decimals,
and the two rooms are the risk case itself — detailed title-domain stills reached by
in-title navigation, which no longer soft-reset.

**Unregressed on T2** (the menu disc, and the one whose logo chain has broken flush changes
before): the timeline menu renders with its highlight, a menu→menu hop, menu→title Play
(the Dolby/THX logo chain runs), and a title→menu re-entry that lands on the full main
menu **un-fried at 1.044** — that last one is the crossing #92 exists to protect, so it is
the load-bearing unregression. All four report zero. Scooby's own menus, submenus, game
entry and in-game room navigation all unregressed.

✅ **MAINTAINER-CONFIRMED on their own rig (2026-09-15), including the two arms this
harness could not reach:** Scooby-Doo 2 good; **T2 Mission Profiles** good (the #96
slideshow path); and **the Elmo disc launched 20 times with no fried image** — against an
original onset rate of roughly 1 in 8 re-entries, which is the arm that matters most,
since a clean single pass would have proved nothing.

⚠ **One PAL disc IS still fried, and it is PRE-EXISTING — `INCREDIBLE_HULK.iso`, the
special features menu.** A/B'd by the maintainer against the `quantmatrix` build that
fixed Elmo: **fried there too**, so neither this branch nor #92 caused or cures it.
Measured offline, and the reason it is out of #92's reach is structural:

* `tools/qmatrix_scan.py`: 7/7 menu-VOB sequence headers download a matrix, worst
  `default/custom` **29.00** (Elmo's was 20.75) — so a lost matrix here is dramatic.
* The menu is **VTS_06 VTSM PGCN 15**, a single `still=255` cell, and the only thing that
  reaches it is **PGCN 14's POST `LinkPGCN 15`** — PGCN 14 being a 70 s motion clip in the
  same menu domain.
* So the landing is a **menu→menu hop**: `keep_vbuf = 1`, and a `keep_vbuf` hop
  soft-resets on **no** build. §11's fix is gated on `~keep_vbuf` and 12a narrows that
  further, so this junction was never in scope either before or after.

⛔ It is therefore a THIRD case, not a regression of either: #92 covers `~keep_vbuf`
jumps, #96 covers the same junction from the delivery side (`nat_drained`) and fixed T2's
slideshow, and this one is still losing something. Chase it on its own, and start by
deciding between the two live hypotheses — the drain not engaging on this particular path,
or the `alternate_scan` permutation (§4), which `qmatrix_scan` flags on all 7 of this
disc's downloads. `tools/quant_fixture.py --junction` over the real PGCN 14 → 15 bytes
plus an ffmpeg decode is the measurement that separates them, exactly as it did for #96.

### 12f. Accepted risk

Narrowing 12a means a title-domain jump landing on a **still** no longer gets the pipeline
reset. Measured on the reported disc: `VTS_02_1.VOB` downloads a quantiser matrix on 20 of
36 sampled sequence headers, and the title PGCs carry real held stills (PGCN 2 cells 1–5,
PGCN 3 cell 3 are all `still=255`). Mitigating: severity here is a worst
`default/custom` of **2.38×** (`tools/qmatrix_scan.py`) against the reported disc's
20.75×; v0.5.0 shipped with no jump soft reset at all and several HW rounds on this disc
never reported fried in-title images; and a moving cell self-heals at its next GOP header,
so only a still is exposed.

**Contingency if a HW round shows frying:** extend the predicate with "the landing cell is
a still" — the reader knows `still_time` at `S_CELL_LOAD`, before the landing's first
bytes are streamed. ⛔ Do **not** reach for the issue-#65 menu-still cold re-decode; it
replays audio and was removed for that reason.

---

## 13. The gap between #92 and #96: a BUTTON-activated menu→menu hop (2026-09-15)

`INCREDIBLE_HULK.iso` (PAL) reported a fried special-features menu on the shipped core
AND on the `quantmatrix` build that fixed Elmo. ⚠ That made it look "pre-existing", but
measured against v0.4.0 it is a REGRESSION -- see §13c-quater. Root-caused here. Branch `fix/menu-hop-still-matrix`.

### 13a. Reproduced deterministically, with a clean control on the SAME still

Measured on the rig with the blockiness metric (energy on the 8-px DCT grid ÷ energy off
it; ~1.0 clean). The menu is **VTS_01 VTSM PGCN 14** — the core's own `CH 14/ 1` readout,
NOT the VTS_06 PGCN 15 that the IFO link graph suggested. ⚠ **Ask the core what it is
playing before analysing a disc** — the same mistake as the AFTER_EARTH VTS mix-up.

| route to PGCN 14 | blockiness | n |
|---|---|---|
| after a title→menu **crossing** (soft reset fires) | **1.071** | 2 |
| by menu→menu **hops** only | **1.560** | 8 |

Identical content, identical PGC; only the route differs. The fried arm is the same value
to three decimals on all 8 entries — **deterministic**, unlike Elmo's ~1-in-8 onset.

### 13b. The mechanism, and why two obvious theories were refuted first

⛔ **Not the delivery-side cut at a natural PGC end.** `quant_fixture.py --junction`
REFUSES to build this disc's PGCN 14 → 15 junction: *"cut A contains a sequence_end_code
-- it would resync the parser for free and the junction would prove nothing."*
⛔ **Not the `alternate_scan` permutation (§4).** The still's own download, run through
`quant_matrix_tb` with `--matrix-probe` (64 distinct values), comes back
`mismatches=0/64 permutation=0 distinct_used=63`.

What it is: **the hop is a BUTTON press, so it is neither drained nor reset.**

* `dvd_vm.sv:899` — a button event sets `nat_src <= 1'b0` (*"event jump: never 'natural'
  provenance"*); `nat_src` is 1 only for `ev_cellcmd`/`ev_pgcend` (`:1079`, `:1092`).
* So `vm_from_wait = wait_verdict && nat_src` is 0 ⇒ `jump_natural` 0 ⇒ `jnat_l` 0 ⇒
  **`jump_go` is NOT gated on `nat_drained`** — #96's drain does not apply. The jump
  executes at once and `wr_ptr <= 0` discards the undelivered cache tail.
* And it is menu→menu, so `keep_vbuf = 1` ⇒ **no VBUF flush and no `soft_flush`** — #92
  and #98 do not apply either.
* The landing's one sequence header is therefore eaten mid-stream while
  `sequence_header_seen` is still set, so the still decodes with the PREVIOUS menu's
  matrix. On a disc whose menus differ by 29× that is the reported artefact; on T2 (2.38×)
  it is invisible, which is why T2's 20 hop-only stills look fine.

★ **It sits exactly in the gap between the two fixes:** #92/#98 cover `~keep_vbuf` jumps,
#96 covers `keep_vbuf` hops with NATURAL provenance (T2's slideshow, `LinkNextPG` and cell
commands). A **user-activated** `keep_vbuf` hop is covered by neither.

### 13c. Blast radius, swept (970 images)

New `tools/still_menu_scan.py` classifies every menu-domain PGC as a still and every
inbound route as `crossing` / `menu_hop` / `self` / none; paired with `qmatrix_scan.py`:

| | discs | still menus |
|---|---|---|
| at least one still menu | 921 / 970 | 11,906 |
| reachable by a crossing (reset fires) | — | 3,026 |
| **ONLY by a menu→menu hop** | **735 / 970** | **6,379** |

| menu matrix ratio | discs | with a hop-only still |
|---|---|---|
| none / flat | 408 | 248 |
| 2–5× (mild) | 244 | 208 |
| 5–10× (visible) | 4 | 3 |
| **≥10× (dramatic)** | **313** | **275** |

**Intersection: 275 discs (28 %)** carry a hop-only still whose matrix is dramatic enough
for a loss to be obvious.

★★ **BOTH axes were necessary, and axis 1 alone would have misled.** T2 has 20 hop-only
stills and is confirmed good on hardware — but its worst ratio is 2.38× and The Matrix
downloads no matrix at all, so neither disc *could* show this defect. Reading "T2 works"
as "the menu-hop path is safe" is exactly the wrong conclusion, and only the second axis
prevents it. Same lesson as the Angle-menu scope cut: a declared capability is not a
used one.

⚠ 970 of 1064 images were swept; the rest have quote characters in their filenames and
were dropped by `xargs`. Not a sampling decision, just a shell artefact — re-run with
`-0` if the exact denominator matters.

### 13c-bis. The severity metric that actually predicts it (2026-09-15)

⛔ **"Worst default/custom ratio" (what `qmatrix_scan` reports) is the WRONG severity
number for this defect, and using it would have mis-sized the population.** What a
fried still is dequantised with is not the MPEG default, it is **the matrix the previous
menu left in the registers**. So the severity is the worst ratio between the matrices a
disc's own menus download -- new `tools/menu_matrix_spread.py`. A disc whose menus all
share ONE matrix cannot show this however varied that matrix is.

Validated against all three discs whose hardware behaviour is known:

| disc | spread | distinct menu matrices | HW |
|---|---|---|---|
| INCREDIBLE_HULK | **29.00x** | 2 | **fried** |
| ULTIMATE_T2 | 2.38x | **1** | clean |
| THE_MATRIX | 1.00x | **0** | clean |

★ **T2 is the case that makes the metric necessary:** it has 20 hop-only stills and is
HW-confirmed good, because it downloads exactly ONE menu matrix -- every hop inherits the
same matrix it would have loaded. Its 2.38x is purely against the DEFAULTS, which is only
reachable straight after a reset.

Swept over 970 images and intersected with `still_menu_scan`:

| menu-matrix spread | discs | with a hop-only still | with >=2 menu matrices |
|---|---|---|---|
| <1.5x (cannot show) | 372 | 219 | **0** |
| 1.5-3x (subtle) | 47 | 45 | 5 |
| 3-10x (visible) | 229 | 188 | 79 |
| >=10x (dramatic) | 322 | 283 | 210 |

**AT RISK = a hop-only still AND >=2 distinct menu matrices AND spread >=3x:
267 discs, 27.5 % of the library.** Worst spreads reach **127x** (NACHO_LIBRE_WS: 9
distinct menu matrices, 12 hop-only stills).

⚠ Lower bound: like `qmatrix_scan` it samples the head of each menu VOB, so a matrix
appearing deeper is not counted.

### 13c-ter. A two-route A/B is NOT a sound oracle -- recorded so it is not retried

The obvious HW test ("reach the still by a hop, then by a crossing, compare") was built
and **abandoned**. On Hulk's PGCN 14/VTS_1 it gives hop 1.560 / crossing 1.071, but on
PGCN 14/VTS_6 the sign INVERTS (hop 1.071 / crossing 1.560). Both arms end
`root -> submenu`; what differs is what ROOT itself inherited, so the sign depends on the
disc's menu layout rather than on the route. The direction of the effect is not a
property of hop-vs-crossing, and a sweep built on it would have produced confident
nonsense.
⚠ The prober that produced this also reported "not reproduced" on a disc reproduced by
hand 8/8 -- a format bug (`sigma= 57.2` is PADDED, so splitting on '=' yielded an empty
string and every measurement became None). It was caught ONLY because it was validated
against a known positive first. Validate an instrument on a case whose answer you
already know, before trusting it on cases you do not.

### 13c-quater. ⛔ THE NACHO LIBRE "SECOND DISC" WAS RETRACTED (2026-09-15)

**It was never a defect. Do not re-derive it.** NACHO_LIBRE_WS renders correctly on the
current core; the maintainer confirmed it on the actual display. The claim that it was
fried, and the whole "regression from `b900478`" story built on top of it, are WITHDRAWN.

What the mistaken claim rested on, and why each part was worthless:

* **Blockiness.** 0.785 on the board against 1.058 for the ffmpeg ground truth. That is
  the metric saying the board was CLEANER, and it was read as a defect anyway. This disc's
  menu art is a posterised screen-print whose strong OFF-grid edges swell the denominator,
  so the number is meaningless here -- which was already written down in this file before
  it was used to support the claim.
* **High-frequency energy.** First computed over the FULL FRAME, which included the `O[2]`
  debug blocks and the HUD -- i.e. it measured the harness's own overlay. Recomputed over
  the picture body the board still reads high (72.5 vs 24.8 for v0.4.0), and that number
  is STILL UNEXPLAINED -- plausibly capture timing (a menu mid-build) or an interlaced
  weave in the capture. **An unexplained number is not evidence of a defect.**
* **A visual read**, made after the maintainer had raised the possibility -- so it was
  primed, not independent.

★★ **The lesson, and it is the expensive one here: the maintainer's eye on the real
display outranks a harness metric that has not been validated ON THAT CONTENT.** The
maintainer flagged the risk in advance ("that menu has a lot of posterization styling that
may read as 'fried' -- check with me on the screenshot before deciding"), and the right
response was to treat every number from that disc as suspect until a same-content control
existed. Instead the numbers were used to overturn the warning.

⚠ Everything §13c-bis says about the severity metric and the 267-disc population still
stands as OFFLINE analysis -- it predicts which discs COULD show a matrix substitution --
but it now has **zero** confirmed discs in the authored-still class. Do not describe it as
a sized defect population until one is confirmed.

### 13c-quinquies-bis. ★ IT IS ONE DEFECT AFTER ALL -- v0.4.0 UN-FRIES THE HULK MENU

⚠ Maintainer correction (2026-09-15): *"if I stay on the hulk menu for a bit in 0.4.0 it
gets un-fried."* That is the **cold re-decode working**, and it is the same sentence the
field used about Elmo -- *"on 0.4.0 the fried image flashes for a split second then
resolves; on 0.5.0 it holds."*

So Hulk is NOT a separate mechanism. It is fried AT THE LANDING on both versions; v0.4.0
repairs it a moment later and the current core cannot. That collapses the three discs into
one defect with one story:

| disc | landing | on v0.4.0 | now |
|---|---|---|---|
| ELMO | `~keep_vbuf` CROSSING | fries, then resolves | **fixed by #92** |
| NACHO_LIBRE | `keep_vbuf` menu hop | fries, then resolves | fries ~1 in 5, HOLDS |
| INCREDIBLE_HULK | `keep_vbuf` menu hop | **fries, then resolves** | fries, HOLDS |

⛔ **Two of my own claims are withdrawn by this.** (1) "Hulk is a second, unexplained
mechanism" -- it is not; the §13b landing story covers it. (2) "The v0.4.0 mask could not
reach Hulk because its cell is `still_time = 0` and the re-decode only ran on a parked
still" -- wrong, and too literal: the reader also parks **heuristic** stills (timed /
last-cell, PR fj#90), so a `still_time = 0` cell that holds its last frame parks and the
re-decode reaches it. Do not re-derive the split from the `still_time` field alone.

★ **What the "deterministic 8/8" on Hulk actually measured** is therefore not a different
defect: once fried on a core with no mask, it HOLDS -- so every sample in a session reads
fried. That also explains why both captures in the mistaken Nacho session read 2.53x
including the "crossing" one. **Within one parked menu the state is sticky; the rate lives
across LANDINGS, not across captures.** Any rate measurement must re-land, not re-shoot.

### 13c-quinquies. What is actually confirmed

**INCREDIBLE_HULK.iso, VTS_06 VTSM PGCN 14** fries on the current core and on v0.4.0 --
but v0.4.0 UN-FRIES it a moment later (§13c-quinquies-bis), so "pre-existing" means the
LANDING has always been wrong, not that the user ever had to look at it.

⚠ Residual puzzle, worth keeping but no longer a separate defect: that cell is
`still_time = 0` and all 14 sequence headers in the first 1500 sectors of its VTS_06 menu
VOB carry a matrix download, so a MOVING menu should self-heal within a GOP. It parks as a
heuristic still, so what is on screen is one held frame decoded at the landing -- which is
consistent -- but the §13a route asymmetry (1.560 by hop vs 1.071 via a crossing) was
measured in ONE session and, per §13c-quinquies-bis, a session's state is sticky. **Re-do
that comparison across separate LANDINGS before treating the route asymmetry as real.**

⚠ `tools/still_menu_scan.py` counts `still_time == 255` only, so it misses heuristic-still
menus like this one and UNDER-counts the population.

### 13c-sexies. Nacho Libre REINSTATED -- but as an INTERMITTENT case (2026-09-15)

⚠ The retraction above was right on the evidence I had and wrong about the disc. The
maintainer re-tested by launching the menu repeatedly: **4 clean, the 5th FRIED** -- so
NACHO_LIBRE_WS *is* affected, at roughly **1 in 5 launches**. That is the same character
as Elmo's original ~1 in 8, and it is why single captures were worthless: at those odds
one shot each side of a version comparison is a coin toss, which is exactly how the
"regression from b900478" story got built. **That story stays retracted** -- it rested on
one sample per version.

Characters, which are NOT the same and may not share a mechanism:

| disc | rate | landing |
|---|---|---|
| ELMO | was ~1 in 8; **fixed by #92 and still fixed** | menu entry = a `~keep_vbuf` CROSSING |
| NACHO_LIBRE | **~1 in 5** | menu hop, `still_time=255` |
| INCREDIBLE_HULK | **deterministic, 8/8** | menu hop, `still_time=0` (not a still) |

★ Intermittent vs deterministic is a real clue: an intermittent loss is
FLUSH-POSITION dependent (where in the parse the cut lands -- the §7 sweep's shape),
while a deterministic one is structural.

**Instrument: `tools/fry_detect.py`** compares a board capture against **ffmpeg's decode
of that menu's own bytes** -- a same-content reference, so it works where blockiness does
not. Validated on Nacho: v0.4.0 capture 0.87x, a fried softscope capture 2.53x.
⚠ Both of the softscope captures from the mistaken session read 2.53x, INCLUDING the one
taken by the "crossing" route -- i.e. that whole session was a single fried instance and
the route comparison in §13a measured nothing on this disc. Route conclusions need a rate,
not a pair.

### 13c-septies. BASELINE RATE, measured -- the number a fix must beat

`NACHO_LIBRE_WS`, VTS_07 VTSM PGCN 13, current core (`dev-softscope`), **10 separate
LANDINGS** (relaunch + navigate each time -- not 10 captures of one landing, which the
sticky-state note above makes worthless), scored by `tools/fry_detect.py` against the
ffmpeg ground truth:

    2 / 10 FRIED   (2.51x, 2.51x)
    8 / 10 clean   (0.87x x6, 0.75x x2)

★ The distribution is **bimodal with nothing in between** -- a 2.9x gap between the clean
and fried clusters -- and the fried captures are unambiguous by eye (blown highlights,
flattened colour, blocky texture). So the instrument is trustworthy and so is the rate:
**20 %, matching the maintainer's independent "4 clean, the 5th fried".**

⚠ **Gate arithmetic for any fix.** At a 20 % baseline, a clean run of N landings happens
by luck with probability 0.8^N: N=10 is 11 % (not evidence), **N=20 is 1.2 %**. So a fix
arm needs **at least 20 landings** and the PRE-fix core must be run through the same
script as the control -- the fried rate is low enough that a clean fix arm alone proves
nothing (the same trap recorded for the #92 HW round).

### 13c-octies. ⚠ `run_menu_junction.sh` EXITS FAIL BY DESIGN -- do not "fix" it

It reports `[J1]: 0/7 truncation offsets lose the landing's matrix` and then
`FAIL: [J1] reproduced nothing -- the mechanism is refuted`. **That refutation IS the
recorded result of PR #96** (see the CLAUDE.md menu-slideshow bullet: the arms were
"committed BEFORE the fix, as standing evidence"). The suite is a standing record that a
contiguous-but-truncated junction does NOT lose the matrix; losing it needs the flush.

It is provably unaffected by anything in the reader -- it compiles only
`vld/getbits/rld/iquant/wrappers` and contains no reference to `dvd_iso_reader` -- so a
reader change cannot move it. But because it exits non-zero, a future session running
the full bench set will read it as a regression it caused. Treat a FAIL here as expected
until someone converts it into an explicit "must not reproduce" arm.

### 13d. The fix (implemented 2026-09-15, branch `fix/menu-hop-still-matrix`)

⚠⚠ **THE CONSTRAINT IS A BALANCING ACT, and it is the maintainer's observation, not a
theoretical worry:** *"there's a bit of a balancing act with these fry fixes, where moving
too far to fix one may cause other issues (e.g. black screens on menu navigation in
Scooby Doo)."* That is the whole history of this defect in one sentence --

* #92 widened the decoder soft reset to every `~keep_vbuf` jump and fixed Elmo, and its
  cost was a black cut on every title-domain screen transition (PR #98).
* #98 narrowed it to menu/title CROSSINGS, which removed the black cut and kept Elmo
  fixed -- confirmed by the maintainer over 20 launches.
* Widening it again to cover `keep_vbuf` hops would put a black cut on **every menu button
  press**, which is worse than the defect it fixes.

So the fix must make the LANDING parse correctly without adding a visible discontinuity.
The drain-gate direction (extend Phase B to user-activated menu hops so the landing meets
a parser at a start-code boundary) satisfies that in principle -- it delays rather than
blanks -- but it spends that delay on a USER action, where #96's natural transitions had
slack. Measure the added latency on the rig before calling it a fix.
⛔ NOT the cold re-decode (the mask, replays audio, #65). ⛔ NOT a wider `soft_flush`.

**What was built.** `dvd/dvd_iso_reader.sv` gains a SECOND drain gate, `hop_drained`,
selected per jump by a new `khop_l` latch (`menu_dom && target-is-a-menu` -- the same
predicate `keep_vbuf` uses at `jump_go`, latched at the request because the gate must know
before executing):

```
hop_quiet   = ~cache_has_data && ~blk_inflight && ~stream_valid && ~read_valid_pipe
hop_drained = hop_quiet && (&hop_settle)          // same 255-cycle settle as nat_settle
jump_go    &= (~khop_l || jnat_l || hop_drained || drain_wd_hit)
```

⚠⚠ **It deliberately omits `vbuf_empty`, and that is the whole reason it is a second gate
rather than a reuse of `nat_drained`.** On a `keep_vbuf` hop the decoder's buffer is KEPT
-- that is what makes the transition seamless -- so `nat_drained` would block until the
decoder had played out the whole menu loop: SECONDS, on a button press. What the landing
actually needs is only that the READER's own path is empty, so the demux is not cut
mid-PES.

★ **The latency worry above was MEASURED, not argued away.** `iso_reader_menudrain_tb`
arm [D]'s user jump goes **378 -> 81600 cycles = 0.014 ms -> 3.0 ms** at 27 MHz.
Imperceptible, and it is a DELAY rather than a blank, so it cannot reintroduce the black
cut. `DRAIN_WD` still bounds it.

**Gate: `iso_reader_menudrain_tb` arm [H]** -- at a `keep_vbuf` USER hop the reader's path
must be empty, i.e. there was nothing left to discard. Proven RED against the pre-fix
reader **with the new arm in place** (`reader path NOT empty at the hop`); note that
stashing both the RTL and the bench makes the RED arm vacuous, which happened on the first
attempt. Arm **[D]** is the other half of the contract and must keep passing: it runs to
completion with `vbuf_empty = 0`, which is what proves the decoder is still not waited on.
[A][B][C][G], `iso_reader_vm_tb` T1-T9, `flush_ctl_tb`, `run_dpad_seek`,
`run_link_button`, `run_hli_window`, `run_mgl`, `run_scrub_tiers`, `run_title_span` and
`run_seamless_audio` all unchanged and green.

⚠ **Arm [H] first failed against the CORRECT fix.** It sampled at `jump_ack`, but
`wr_ptr <= 0` lands with `jump_go` while `rd_ptr <= 0` only lands on the following cycle,
so `cache_has_data = (0 != rd_ptr)` reads spuriously 1 there. It samples the cycle before
the jump executes. **A measurement taken one cycle late fails a good fix** -- check the
instrument before concluding the RTL is wrong.

### 13e. ⛔ THAT FIX WAS REVERTED -- IT DEADLOCKS EVERY MENU (2026-09-15)

Build `DVD_hopdrain_20260915_2329.rbf` went to the rig and the maintainer reported:
*"the title menu button doesn't do anything, and select does nothing in the menus, so I
can't get anywhere past the root menu"* -- on BOTH discs. Reverted the same day.

**Two compounding errors, and the second is the fatal one.**

1. `drain_tmr`'s enable is `vmw_pgc_pend || (jump_pending && jnat_l) ||
   (seek_pending && snat_l)`. `khop_l` was never added to it, so `drain_wd_hit` can
   never fire for a hop: the new wait had NO watchdog bound at all.
2. ⛔⛔ **`hop_quiet` IS UNREACHABLE ON A LOOPING MENU.** It wants the reader's cache
   empty and no block in flight -- but a looping menu streams CONTINUOUSLY, refilling
   the cache as fast as it drains. The condition is essentially never true, so
   `jump_go` never fires and the button is dead. Forever.

★★ **WHY THE BENCH PASSED IT, and this is the reusable part: the fixture's cells END.**
`iso_reader_menudrain_tb` plays a finite transition cell, so its cache does empty and arm
[H] was satisfiable. A real menu LOOPS. That is `bench-that-cannot-fail` in a new
costume -- not a stimulus that is too constant, but a fixture whose content TERMINATES
where the real thing does not. **Any gate that waits for a reader-side quiescent state
must be tested against a cell that never ends**, and `iso_reader_menudrain_tb` has no such
arm. Add one before attempting this class of fix again.

⚠ Arm [D] did not catch it either, although it is the "user jumps must not be gated" arm:
it measured 81600 cycles against a 200000-cycle threshold and passed. The threshold was
generous enough to hide a wait that is unbounded in reality.

**So the fix direction in §13d is DEAD as stated.** A reader-side drain cannot work for a
looping menu. What the landing needs is that the VLD is not left mid-picture -- and the
reader cannot deliver that by waiting, because there is no quiet point to wait for. The
next attempt should look at the DECODER side (a vld re-sync that is not a full soft reset,
i.e. not the §9/§10 route that produced luma-in-chroma garbage) or at making the cut land
on a pack boundary rather than wherever `wr_ptr <= 0` happens to fall.

⚠ The `fry_detect.py` instrument, the 20 %/20-landing gate arithmetic (§13c-septies) and
the population sweep all stand -- only the fix does not.

### 13g. ⛔ A READER-SIDE DRAIN CANNOT WORK -- PROVEN IN SIM (2026-09-15)

The §13e fix was rebuilt with the ordering libdvdnav uses (stop the source FIRST, then
drain, bounded by the watchdog): a `hop_hold` that gates the `S_STREAM` read issue,
`khop_l` added to `drain_tmr`'s enable, `hop_drained` excluding `vbuf_empty`. It passes
arm [I]. **It still does not work, and now the bench says so without a hardware round.**

New arm **[J]** stalls the sink COMPLETELY (`hard_stall`) -- what the decoder does on a
parked or looping menu once the menu VBUF cap is reached -- and then presses a user menu
hop. Result with the drain fix in place:

    [J] released by the DRAIN WATCHDOG after 600006 cycles   (= DRAIN_WD exactly)

On hardware `DRAIN_WD` is **60 s**, so that is a minute-long dead button: precisely the
field report. ★ **With the sink stopped, the reader's cache cannot drain AT ALL** -- not
because the reader refills it (the §13e diagnosis, which was only half right) but because
nothing is taking bytes out. No amount of reader-side sequencing changes that.

⚠ Note what [I] alone would have told you: the fix "works" there, in 180096 cycles. [I]
uses the `slow` sink, which still accepts 64 cycles in 512, so the cache drains on its
own. **A gate that waits is only testable against a sink that STOPS.** That is the third
form of `bench-that-cannot-fail` this defect has produced -- after constant stimulus and
after a fixture whose cells terminate, now a fixture whose consumer never stops.

**Bench contract now, and the two arms are different in kind:**

* **[I]** -- the OPEN DEFECT. On the shipping reader it prints
  `the hop executed with the reader's path NOT drained -- bytes discarded` and a
  `KNOWN OPEN` notice, so the suite stays a usable regression gate. Run
  `+expect_fixed=1` to make it a hard failure: **the fix is done when that is green.**
* **[J]** -- the REGRESSION GUARD, a hard failure ALWAYS. It is not describing the
  defect; it is protecting against the fix that killed every menu button. Any future
  attempt must keep it green.

**Where that leaves the fix.** Waiting is dead (13g). The partial decoder re-syncs are
HW-refuted (§9/§10). What is left:

1. **Full soft reset on a `keep_vbuf` hop, with the black hidden** -- reuse the
   HW-proven reset and stop the display going black through it (picbuf clears, so
   `output_frame_valid` drops and the mixer emits black; that is what would have to be
   held). Known-good mechanism, new display-side work.
2. **Do not create the gap in the first place** -- rather than draining before the jump,
   let the landing's bytes follow the undelivered ones CONTIGUOUSLY (no `wr_ptr <= 0`).
   #96's [J1] measured contiguous truncation as safe, and §13 measured the gap as fatal
   at 5000 B on Nacho's real cells. This neither waits nor resets.

⛔ NOT the cold re-decode (the mask, replays audio, #65). ⛔ NOT a wider `soft_flush`
without (1)'s display work.

### 13h. THE FIX: don't create the gap (2026-09-15, `fix/menu-hop-still-matrix`)

Waiting is dead (§13g) and the partial decoder re-syncs are HW-refuted (§9/§10). What is
left is not to wait or reset, but to **not create the discontinuity in the first place**.

`dvd/dvd_iso_reader.sv`: on a USER menu->menu hop the jump no longer clears the stream
cache, so the landing's bytes follow the undelivered ones **contiguously**.

```
hop_keep_w = menu_dom && ~jnat_l && (jdom_l is a menu domain)
jump_go:   if (!hop_keep_w) wr_ptr <= 0;   contig_l <= hop_keep_w;
pipeline:  else if (start || seek_jump || (jump_ack && !contig_l) || seek_ack)
```

Why it is the right shape:

* **Nothing waits**, so it cannot hang -- arm [J] (sink fully stalled) executes in
  **6 cycles**, against DRAIN_WD (60 s) for the drain attempt.
* **Nothing resets**, so there is no black cut -- the objection that killed widening
  `soft_flush`.
* It is what #96's `[J1]` already measured as SAFE: a contiguous-but-truncated junction
  keeps its matrix at all seven offsets; *"losing the matrix needs the FLUSH."*
* Cost: up to one cache (16 KB) of the source menu still plays after the press -- which
  is what `keep_vbuf` exists to allow, and it is SMALL: a full cache is **16.4 ms** at the
  8 Mbps DVD mux ceiling, **26 ms** at a typical 5 Mbps menu rate, **65 ms** at 2 Mbps,
  and the bench's measured 10125 B is **~16 ms**. About one frame, so it should not read
  as button lag. ⚠ If a user ever DOES report lag on a menu press, this is the term to
  suspect and the number to check it against.

⚠ **USER hops only (`~jnat_l`), and this was found by a failing arm, not by design.** A
NATURAL menu verdict is already drained by #96, so its cache is empty and there is
nothing to carry -- and arm **[A]** asserts the first byte after such a jump is the
LANDING's. The first cut omitted `~jnat_l`, delivered the source's tail there instead,
and [A] failed with `first byte = d1 (want e5)` and `LD=0`.

**Gates.** Arm **[I]** re-expressed: the contract is **"nothing was discarded"**, not
"the path drained" -- draining is unreachable with a stalled sink. It measures the BYTES:
the source cell's cached data must keep arriving after the jump.

    shipping reader   [I] source bytes after the hop: 0 (none) -- DISCARDED   FAIL
    contiguous fix    [I] kept the cache: 10125 more source bytes delivered   ok

with `[J]` green in both (6 cycles). `run_menudrain`, `run_mode_realign`,
`run_dpad_seek`, `run_link_button`, `run_hli_window`, `run_mgl`, `run_scrub_tiers`,
`run_title_span`, `run_seamless_audio` all green.

⏳ **HW gate not yet run.** §13c-septies applies: 20 % baseline, so **20 landings** are
needed (0.8^20 = 1.2 %), scored with `tools/fry_detect.py`. And watch the two failure
modes the previous attempts produced: a **dead menu button** (arm [J]'s shape) and a
**black flash** on menu navigation.

### 13i. ⛔ THE CONTIGUOUS FIX DID NOT WORK EITHER -- and what that refutes

Build `DVD_contighop_20260916_0214.rbf` on the rig (maintainer): **Nacho fried on the 2nd
try, Hulk fried on the 1st.** Reverted.

★ **The regression guard DID hold:** *"menu and select work again with no black screen."*
Arm [J] did its job -- this attempt did not repeat §13e.

**What it refutes, and this is the value of the round: the byte-level gap at the READER
is not the mechanism.** The fix demonstrably achieved contiguity there -- arm [I]
measured 10125 source bytes still delivered after the jump where the shipping reader
delivers 0 -- and the stills fried anyway.

★ **The likely reason, and it is checkable:** `ps_stream_fifo` and `ps_demux` sit on
`pipe_rst_n`, which drops on EVERY jump, `keep_vbuf` included (`dvd/emu.sv:3093,3109`).
So preserving the reader's cache does not preserve the STREAM: the 16-byte FIFO and the
demux's partial-PES state are wiped downstream of the cache, re-creating the
discontinuity in the bytes that actually reach the VBUF. The fix was applied one stage
too early.

⚠⚠ **THE REAL LESSON IS ABOUT THE GATES, NOT THE RTL. Every arm built for this defect so
far measures a PROXY, and each proxy was satisfiable without fixing anything:**

| arm | measures | satisfied by a non-fix? |
|---|---|---|
| [H] (reverted) | the reader's path is empty at the hop | yes -- §13e shipped and deadlocked |
| [I] | source bytes not discarded at the reader | **yes -- §13i shipped and still fried** |
| [J] | the hop does not hang | it is a guard, not a fix gate |

None of them can see **the matrix the decoder ends up holding**, which is the actual
defect. `quant_matrix_tb` CAN -- it scores the matrix against the disc -- but it is fed a
hand-built byte stream, not the one the reader and demux really produce.

**So the prerequisite for any further attempt is a gate that spans the whole chain:
reader -> ps_stream_fifo -> ps_demux -> the decoder's matrix**, scoring
`mismatches/64` and `downloads`, over a REAL menu-hop junction from one of the two
confirmed discs. Until that exists, a green bench means nothing here -- three builds have
now proved that empirically.

⛔ Do not attempt another fix before that gate exists.

### 13j. OPTION A step 1: the eaten-header DETECTOR works (2026-09-16)

Maintainer constraint: **no unauthored black frames.** That rules out crossing
semantics (§13d), anything that waits (§13g) and any partial decoder re-sync (§9/§10).
Option A instead DETECTS the failing landing and repairs only that one, holding the
previous frame meanwhile -- no black, and only the ~1-in-5 bad landings pay anything.

Step 1 was to validate the detection ALONE, before any plumbing or build.

`rtl/mpeg2/vld.v` gains two ports and one register:

```
input  hop_mark;    // the PARSE reached the junction
output hdr_eaten;   // a picture header arrived with no sequence header since the mark
```

A still is `SEQ GOP PIC:I SEQ_END`, so its sequence header always precedes its one
picture: a picture header reached while still awaiting one means the header was eaten.
(Clear wins over set in the same cycle -- a header AT the junction is the landing's.)

**MEASURED over the seven Nacho offsets (`NOFLUSH`, i.e. a real keep_vbuf hop):**

| trunc | mismatches | downloads | **eaten** |
|---|---|---|---|
| 0, 8, 100, 300, 1000, 2600 | 0/64 | 2 | **0** |
| **5000** | **63/64** | **1** | **1** |

It tracks the defect exactly: fires on the one failing offset, silent on all six clean
ones. No false positive, no false negative. ★ This is the first gate in this whole
investigation that measures **the matrix the decoder ends up holding** rather than a
reader-side proxy -- the three shipped fixes all passed proxies and failed on hardware.

⚠⚠ **BUT THE MARK'S POSITION ACCURACY IS UNTESTED, AND THIS FIXTURE CANNOT TEST IT.**
§13's plan asserted that `hop_mark` must ride the byte stream (the `vid_mark` /
`pts_assoc` pattern) because a mark raised at JUMP TIME would clear on one of the old
cell's own GOP headers still in the VBUF. A mutation was written to prove that --
`+MARK_AT_FEED=1` raises the mark when the FEED reaches the junction instead of the
PARSE, which is what a jump-time mark is -- and **it does not fail**:

    MUTATION feed-time mark, trunc 100    eaten=0   (same as parse-time)
    MUTATION feed-time mark, trunc 5000   eaten=1   (same as parse-time)

The reason is the fixture, not the RTL: `quant_fixture --junction` trims cut A to its
last sequence header plus two pictures (`hdrs_after_mark=1` in every arm), so feed and
parse reach the junction within the same header. On hardware the kept VBUF holds ~1 s of
the old menu -- many GOPs, each with its own sequence header -- which is exactly the gap
the mutation was meant to open.

**So: detection is proven; the MARK is not.** The `pts_assoc`-style plumbing is still
required by the argument above, but **this bench will not catch it if it is wrong**, and
a wrong mark fails in the worst way -- `hdr_eaten` on a CLEAN landing triggers a
re-stream that was not needed. Before step 2 ships, either extend the fixture to carry
several old GOPs after the mark point (so `hdrs_after_mark > 1` and the mutation bites),
or gate the mark in `pts_chain_tb`, which already models the VBUF depth.

⏳ Not built: the consumer (drop the picture, re-stream the still cell, suppress its
audio per issue #65). No RTL outside `vld.v` changed; no build made.

### 13k. THE MARK CANNOT BE VALIDATED IN SIM TODAY -- measured, twice (2026-09-16)

§13j left one thing unproven: that `hop_mark` must fire when the PARSE reaches the
junction, not when the jump happens. The argument is that the kept VBUF holds ~1 s of the
OLD menu -- many GOPs, each with its own sequence header -- so a jump-time mark clears on
one of those and misses the landing. Two benches were tried as the gate. **Neither can
produce the gap, and the reason is the same in both: nothing throttles the decoder, so
the VBUF never accumulates.**

| bench | feed-to-parse separation | why |
|---|---|---|
| `quant_matrix_tb` | **16 bytes** (measured, `feed_lead_bytes`) | the feed is backpressured by `getbits_fifo`; extending cut A cannot change it |
| `pts_chain_tb` | **0 bytes** (measured) | it carries the REAL VBUF path, but the vld consumes as fast as it is fed |

★ So the `+MARK_AT_FEED=1` mutation passing in §13j was **not** evidence that position
accuracy is unnecessary -- it is evidence that the fixture is blind to the question.
⚠ **Extending the fixture, which was the obvious next move, is provably futile**: the
coupling is BACKPRESSURE, not content.

`pts_chain_tb` *could* be made to show it -- its `getbits_fifo.motcomp_busy` is tied
`1'b0`, and driving it stalls the vld so the VBUF fills. That was attempted and is NOT
committed: gating the stall on "wait until the VBUF lead reaches 32 KB" did not converge
within ~35 minutes of simulation and risks an unbounded stall, which would poison a suite
other work depends on. A bounded form (stall for a fixed number of cycles, then measure
whatever lead was achieved, and FAIL if it is under some threshold rather than waiting
for one) is the shape to try.

### 13k-bis. ✅ RESOLVED -- the bounded stall works, and the mark IS load-bearing

The bounded form landed. `pts_chain_tb`'s `getbits_fifo.motcomp_busy` is now driven for a
FIXED window (`MC_STALL_START`/`MC_STALL_LEN`), so the vld is held off while the feed
keeps filling the real VBUF path. MEASURED:

    [M] VBUF lead: 226902 B at the arm, 342669 B peak
    PASS: pts_chain_tb — pre-flush 8 pictures + 2 marks exact; post-flush 19 pictures
          + 2 marks agree (origin +0 B); 9 stale responses crossed the flush, none
          delivered; 3 tags all golden
    == ALL GREEN ==   (and the RED arm still failed as it must, 3 FAIL lines)

★★ **So a feed-time (jump-time) `hop_mark` is wrong by ~227 KB of stream** -- many GOPs,
each carrying its own sequence header. The §13j argument was right and is now a
measurement rather than an argument: **the mark must be position-accurate.**

★ It also confirms §13k's diagnosis of the earlier blindness: the same bench measured a
**0 B** separation before, and the only change is that the decoder is now throttled. The
fixture was never too small -- its consumer was never stopped.

⚠ The arm refuses to pass on a lead under 1 KB (`VACUOUS`), so if a future change removes
the throttle it says so instead of silently going blind again. And the stall is bounded by
construction: a fixed cycle window, never "stall until the lead reaches N" -- that form
did not converge in ~35 min and risked poisoning a suite other work depends on.

**Status of option A: step 1 (detection) proven, step 1b (the mark) now has a working
gate, and the remaining work is the consumer.** A wrong mark fails in the dangerous
direction -- `hdr_eaten` on a CLEAN landing triggers an unnecessary re-stream -- so this
is not a step to skip.

⛔ **And the general rule this defect keeps teaching, now four times over:** every
instrument built for it has been blind in a way that only showed up when something
downstream failed. Constant stimulus, a fixture whose cells terminate, a consumer that
never stops, and now a consumer that is never throttled. **Before trusting any bench
here, ask what the REAL system does continuously that the fixture never does.**

### 13l. OPTION A step 2: the consumer (2026-09-16, `fix/menu-hop-still-matrix`)

Detection was step 1 (§13j) and the position-accurate mark was step 1b (§13k-bis). This is
what the core now DOES with the verdict, and it is the first part that changes behaviour on
the board.

**The constraint that shapes all of it:** *"I want no black frames that aren't authored."*
Every earlier attempt at this defect either flushed (a black frame) or did nothing. This
route does neither: the fried picture is **dropped**, so the display HOLDS the outgoing
menu, and the cell is handed over again with **no flush at all**.

#### The chain, end to end

| where | what |
|---|---|
| `dvd/emu.sv` | `hop_arm` marks the FIRST video byte `ps_demux` emits after a `keep_vbuf` hop. Both `ps_stream_fifo` and `ps_demux` are on `pipe_rst_n`, which `load_flush` pulses there, so everything they held is discarded and that byte IS the landing's first. |
| `dvd/vidfeed_cdc.sv` | carries 10 bits instead of 9 (`parameter W`, default 9 so `vidfeed_cdc_tb` keeps the original contract). |
| `rtl/mpeg2/mpeg2video.v` | stamps the marked byte's VBUF position with the same `dvd/vbuf_pos.sv` the PTS chain uses, and pulses `hop_mark` when getbits' `bitpos` reaches it. |
| `rtl/mpeg2/vld.v` | `hdr_eaten` (§13j) plus `eaten_now_comb` -- the same condition taken combinationally, so the existing header-time suppression legs drop that picture. |
| `dvd/emu.sv` | `hdr_eaten` crosses back on the `wd_tgl` toggle pattern; `hop_tries` allows a BOUNDED number of repairs per hop (§13n). |
| `dvd/dvd_iso_reader.sv` | `restream_pulse` -> `restream_go`: `vm_replay`'s restart, reached from `S_STREAM`/`S_STILL`/`S_VM_WAIT`. `restreaming` is the level emu suppresses audio with. |
| `dvd/audio_ring.sv` | `drop_hold`, a LEVEL. |

#### Three design points worth not re-deriving

★ **The compare is a MODULAR DIFFERENCE, not a `>=`.** Both positions are 24-bit bytes (the
width `pts_assoc` already uses) and a menu session streams far more than 16 MB, so a raw
`>=` fires the instant the counter wraps past the mark -- a false junction every 16 MB on a
looping menu. `pts_assoc`'s `d = a - b; !d[PW-1]` idiom is the right one and was already
in the file.

⛔ **The re-stream pulses NO ack.** `jump_ack`/`seek_ack` put emu on the flush contract:
`load_flush` at minimum -- which resets `ps_demux` and `nav_pci`, taking the highlight with
it -- and a VBUF flush whenever `keep_vbuf` is not set, which is a black frame at exactly
the moment the picture is meant to be repaired. `iso_reader_menudrain_tb` arm [K] asserts
the absence of both, and mutation M2 (pulse `seek_ack` on the restart) is caught by that
line alone.

★ **`drop_hold` is a LEVEL because `drop_pulse` is a four-frame BUDGET.** A re-delivery is
however long the cell is, and a still's narration playing twice is issue #65 -- the reason
the previous attempt at this repair (the v0.4.0 cold re-decode) was removed. `restreaming`
releases when the READER settles, but the last bytes are still walking
`ps_stream_fifo -> ps_demux`, so emu extends it ~0.19 s. Arm [K] MEASURES that remainder:
**4036 of 4050 re-delivered bytes arrive under the level, 14 after it.** If that number ever
grows past the tail window, the tail is too short -- it is a measurement, not a guess.

#### Two bounds, because this route's failure modes are a wedge and silence

- `hop_tries` (emu): a BOUNDED repair budget per hop, cleared at the next hop. ⚠ It was ONE,
  and §13n records why one is wrong: if the re-streamed copy is also eaten, a single shot
  leaves the menu fried until the user navigates away. The BOUND is what stops a runaway,
  not the count.
- `RESTREAM_WD` (reader, ~1.5 s): `restreaming` expires on its own. The failure this level
  can cause is SILENCE, so it must not be able to outlive its cell.

#### What is gated, and -- more importantly -- what is NOT

Gated:

- **`iso_reader_menudrain_tb` [K]** -- the real reader + `ps_stream_fifo` + `ps_demux`,
  scoring the landing still's tag at `ps_demux`'s VIDEO output (what the decoder receives),
  plus the absence of both acks. 4 mutations: M1 (never latch the request), M2 (pulse
  `seek_ack`), M3 (never raise the level) are each caught by their own assertion. **M4
  (clear the stream cache on the restart) is NOT caught**, and the reader's comment says so
  rather than claiming the choice is load-bearing: by the time a landing still reports
  eaten, the reader has parked and the cache is empty anyway.
- **`audio_ring_drop_tb` T3/T4** -- 12 frames, three times `drop_pulse`'s budget, commit
  nothing under the hold; committing resumes when it drops. ★ The `has_space` term
  `drop_hold` was first written into was **DELETED**: no mutation could catch it, and
  measured on its own it is strictly WEAKER than the `cur_dropping` leg (11 of 12 dropped
  rather than 12 -- it lets the frame that was already open when the level rose commit,
  which is precisely the truncated splice frame).

#### ★★ Arm [8]: the drop IS gated, and the fixture reproduces the mechanism

`seek_realign_tb` already instantiates the real `vld` + `getbits` + `motcomp_picbuf` over a
real **menu still** as the landing (`hp_still_i.hex`), and it turns out that fixture
**loses the landing's sequence header for real**. Measured, printed by the arm every run:

    SEQ entries total=1 post-flush=0 | PIC entries total=5 post-flush=1
    sequence_header_seen at flush=1 | post-flush slices=0

The still's ONE sequence header is never parsed; its picture header is accepted anyway
because `sequence_header_seen` survived the flush. **That is §13's mechanism, in full.**
⚠ Read the scope exactly: this is the pre-#92 **FLUSHING** path — the bench drives
`vbuf_flush` into the vld and does not model the soft reset #92 added — so it shows the
behaviour that fix prevents. What it establishes is that the SHAPE is reachable and the
consumer can be tested against it; the `keep_vbuf` hop, which has no soft reset on any
build, is the live case.

So arm [8] raises `hop_mark` at the flush (where the parse front really does reach the
junction), nothing clears it, and the landing reports eaten. It asserts:

| | |
|---|---|
| `eaten_n == 1` | the arm actually staged it |
| `upds_b == 0` | picbuf never rotated for that picture — no fried frame displayed |
| `post-flush slices == 0` | ...and it was not DECODED either |
| `emits > 0`, run completes | the display is **holding**, not blanked, and not wedged |

★★ **The load-bearing assertion is the run completing, and it needs no new machinery:**
`motcomp` freezes the vld at EVERY picture header until picbuf processes the update, and
this arm suppresses that update for a still's only picture — so "does picbuf release the
freeze anyway" is the real question, and a wedge shows up as the bench's existing run
watchdog. **Dropping an I has never been done before this change** (the re-align rule
deliberately keeps them — arm [7] is that refusal made executable).

★ **The slice assertion exists because a mutation survived without it.** Removing
`eaten_now_comb` from `drop_this_picture` while leaving it in `update_picture_buffers`
passed every other check — but it leaves the slices decoding into `current_frame`, a slot
nobody rotated and the display may be scanning out. That is exactly the `motcomp_picbuf`
slot-alias defect, and it also un-suppresses `flags_commit` (the round-11 stale-flags bug).
Mutations E1/E2/E3 are each caught by their own assertion.

⚠⚠ **And the ports were FLOATING.** `seek_realign_tb` instantiated the real `vld` with
`hop_mark`/`hdr_eaten` unconnected — an undriven input on the DUT, the exact shape that
makes a green bench meaningless ([[new-rtl-port-floats-z-in-benches]]). It passed only
because Icarus treats `if (1'bz)` as false. Connected now.

⚠ **NOT gated, and this is the honest statement of where the route stands: nothing in sim
exercises `hdr_eaten` firing on a `keep_vbuf` hop, which is the live case.** `quant_matrix_tb` can raise the mark
only in its `noflush` arm -- the arm that models a `keep_vbuf` hop -- and there the parser
resyncs cleanly before the landing's sequence header, so `eaten=0`. That is the same
finding `run_menu_junction.sh` recorded: **a contiguous junction does not lose the matrix in
sim.** The flush arms cannot raise the mark at all, because the flush breaks the position
coordinate the mark lives in (§13k).

So the mechanism is reproduced and the CONSUMER is gated, but the claim that it is what
happens on a **`keep_vbuf` hop** -- the case Hulk and Nacho actually hit -- is still a
hypothesis only the board can test.

★★ **Which is why `O[2]` block 14 exists, and it is the most important part of this
change.** Second row, x 88..104 — ⚠ SUPERSEDED by the three-way split in §13n, which
reports the detector, the reader's action and a second eat separately.

| on the rig | means |
|---|---|
| still fried, block 14 **GREEN** | the mechanism is right and the repair is not enough -- tune it |
| still fried, block 14 **RED** | **the eaten header is NOT the mechanism.** Stop tuning this route |
| still clean, block 14 GREEN | it fired and it worked |
| still clean, block 14 RED | it never fired; this hop was not the defect (the rate is ~1 in 5 on Nacho -- take several) |

A probe that can say *nothing real happened* is worth more here than another arm that
passes, and this defect has now produced four instruments that were blind
(§13k-bis). ⚠ `O[2]` also needs `menus_on` for that row to draw.

### 13m. ✅ HW ROUND 1: THE MECHANISM IS CONFIRMED -- AND THE REPAIR WAS SCOPED WRONG (2026-09-16)

Build `DVD_hoprestream_20260916_1438.rbf` (SEED 9, clk_dec 91.07/92.52), maintainer's rig.

**✅ THE FRIED STILLS ARE GONE. 20+ launches across Hulk, Elmo and Nacho, not one fried
image.** Against a measured baseline of ~1 in 5 on Nacho and a reproducible fry on Hulk,
that settles §13's open question: **the eaten sequence header IS the mechanism**, the
position-accurate mark finds it, and dropping the picture + re-streaming the cell repairs
it with no black frame. The hypothesis §13l said only the board could test has been tested.

**⛔ AND EVERY MOTION MENU GOT WORSE.** Reported, all four on the same build:

- menus sluggish, not snappy after a button press
- highlights appearing EARLY, ahead of the content
- transitions "decoding into each other" -- macroblocking as one scene becomes the next
- **MiB: a menu transition starts playing, artifacts, then RESTARTS the animation**

★★ **The last one is the diagnosis, and it is not a bug in the repair -- it is the repair
firing where nothing was broken.** MiB's root menu is a LOOPING MOTION menu, so every loop
is a `keep_vbuf` transition: mark → the junction eats that landing's header the same way →
`hdr_eaten` → **re-stream**, which re-delivers the cell from its first byte. "Starts,
artifacts, restarts" is that, exactly.

★★★ **AND §11 HAD ALREADY WRITTEN DOWN WHY ONLY STILLS CAN BE DAMAGED:**

> a moving title re-sends a sequence header every GOP; a menu still is
> `SEQ GOP PIC:I SEQ_END`, **one sequence header ever**.

A motion landing that loses its header heals itself at the next GOP, a fraction of a second
later and invisibly. Repairing it costs a visible restart and buys nothing. **The sentence
explaining the whole defect was in the file, and the repair was still applied to every
landing.** ⚠ Same class as #92's own scope error (`~keep_vbuf` is a DOMAIN fact, not a
transition-kind fact) and issue #81 (*a menu CONTEXT is not a menu DOMAIN*): **a predicate
reasoned about from the case it was written for rather than derived from what it selects.**
Third time. The habit that catches it is to ask *what else does this fire on*, in writing,
before the build.

★ **Scooby-Doo 2's minigame was unaffected, and that is a free confirmation of the
producer's gating:** `aud_drop_pulse` requires `keep_vbuf`, which is `menu_dom`-gated, so
the mark never arms in the title domain at all. The interactive disc never entered this
code path.

#### The fix: gate the MARK, not the re-stream

New reader output **`cell_is_still`** -- an authored `still_time`, or the playback-time
heuristic that covers stills authored with `still_time == 0` (the same two the `S_STREAM`
park branch already uses). It is valid from `S_CELL_LOAD2`, i.e. **before that cell's first
byte is ever delivered**, which is precisely when the mark would go out. `emu` gates
`ps_hop_mark` on it.

★ **Gating the MARK rather than the re-stream is what makes this complete:** with no mark
there is no detection, no DROP and no re-stream. That matters because the drop was a second
contributor to the macroblocking on its own -- dropping the I at the head of a motion GOP
leaves the following P/B pictures predicting from the outgoing scene, which is the issue #45
shape. Gating only `restream_go` would have left that half in place.

⚠ **The arm is still SPENT on the first byte either way** (`hop_spend` ignores
`cell_is_still`); only the mark is withheld. Otherwise a withheld arm would drift onto a
later cell in the same PGC that happened to be a still, and mark a junction that is not one.

#### Gates

- **`iso_reader_menudrain_tb` arm [L]** -- the reader's verdict over a real cell walk:
  `cell_is_still` reads **0** deep inside the 12-sector MOTION transition cell and **1**
  parked on the landing still. ⚠ Sampled MID-CELL: the reader runs ~2 sectors ahead of what
  `ps_demux` has emitted (the phasing trap this bench already records), so a sample at a
  cell edge reads the NEXT cell's meta and proves nothing.
- **`tools/check_hop_mark_wiring.py`** -- because the gate itself lives in `emu.sv`, which
  has **no bench**. Reads the connection out of the file (the `check_subp_map_wiring.py`
  pattern); RED on the ungated `assign`, on the reader port tied off, and on `1'b1`.
  Runs from `run_menudrain.sh` in milliseconds.

⚠ Arm [K] (the re-stream itself) and `seek_realign_tb` arm [8] (the drop) are unchanged and
still pass -- this narrows WHEN the machinery arms, not what it does once armed.

### 13n. HW ROUND 2: motion menus repaired, Hulk residual 1-in-5 (2026-09-16)

Build `DVD_hoprestream_20260916_1513.rbf` (the still-scoped repair), maintainer's rig:

- ✅ **highlights, snappiness and MiB all good** — the §13m scope fix landed; the four
  motion-menu regressions are gone.
- ✅ **Elmo and Nacho: 20 launches each, never fried.**
- ⛔ **Hulk: one fried image on the 5th try.**

#### What the disc says, so this is not re-derived from theory

Measured with `iso_nav_check.py` on the real image — VTS_06 VTSM:

    PGCN 14: cell 0  still=0   cell_cmd=1 (LinkCN 1)  pbtime=70s   <- looping MOTION clip
             post[10]: LinkPGCN 15
    PGCN 15: cell 0  still=255 cell_cmd=0  RBN 26878..26991        <- the landing, 114 sectors

So **the landing IS an explicit `still=255`** and `cell_is_still` marks it: §13m's scoping is
not what is failing here. And PGCN 14 loops its clip, so the transition is reached by a
BUTTON — a USER hop, `jnat_l = 0`, no tail drain. That is the junction `iso_reader_menudrain_tb`
arm **[I]** records as KNOWN OPEN and arm **[J]** proved no reader-side drain can close (with
the sink stalled the cache cannot drain at all). Up to 16 KB the reader never delivered is
discarded at `wr_ptr <= 0`, so this junction carries a byte-level CUT on top of everything else.

#### ⛔ Three candidates remain and NONE can be separated from here

1. the detector never fired on that run — the header was not eaten and the fry has another cause;
2. it fired but the reader refused to re-stream (its state gate);
3. it fired, the cell was re-streamed, and **the re-streamed copy was eaten too** — which the
   ONE-shot budget could not repair, leaving the menu fried until the user navigates away,
   i.e. exactly the reported symptom.

★ **Guessing further is the `theory-vs-premise` trap.** The probe exists for this; it just
could not tell these apart, because one bit conflated "requested" with "happened".

#### Two things the disc settles, so the next session does not re-derive them

**(1) `cell_is_still` misses NOTHING on this disc.** Every cell of VTS_06's VTSM, from the
same walk:

| PGCN | still | marked? |
|---|---|---|
| 4 (Chapter menu) cells 0-4 | `255` explicit | ✅ |
| 10, 11, 12 | 0, playtimes 30/39/3 s | — (motion) |
| 13 | 0 but **HELD 41 s (HEURISTIC)** | ✅ via the heuristic bit |
| 14, 16 | 0, 70 s, `LinkCN 1` loops | — (motion, correctly excluded) |
| 15, 17 | `255` explicit | ✅ |

So **"the gate missed the landing" is eliminated** — seven explicit stills and one heuristic,
all marked; the only unmarked cells are genuine motion clips. ★ This is also why including
the heuristic bit in `cell_is_still` was not optional: PGCN 13 is a still with
`still_time == 0` and nothing else would have caught it.

**(2) PGCN 14's clip ENDS with a `sequence_end_code`** — `tools/quant_fixture.py --junction`
refuses to build a fixture from it for exactly that reason (*"cut A contains a
sequence_end_code -- it would resync the parser for free and the junction would prove
nothing"*). ⚠ That is a fact about the clip's END, and the real transition is a BUTTON press
landing anywhere in a 70 s loop, i.e. almost always mid-picture. It does mean an offline
junction fixture for this disc cannot be built with the tool as it stands: the cut would have
to be taken MID-clip, which `--tail-pics`/`--trunc` cannot express (both work from the end).
That is why this round goes to the rig rather than to a bench.

#### The round's two changes

**(1) `O[2]` row 2 splits three ways** (cleared at every `keep_vbuf` hop):

| block | x | GREEN means |
|---|---|---|
| 14 | 88..103 | the DETECTOR fired (`hdr_eaten` ≥ 1) |
| 15 | 108..123 | the READER re-streamed (`restreaming` asserted) |
| 16 | 128..143 | it was eaten AGAIN after a repair (`hdr_eaten` ≥ 2) |

and a still that is still fried reads directly:

| reading | conclusion |
|---|---|
| 14 RED | the eaten header is **not** the mechanism there — stop tuning this route |
| 14 GREEN, 15 RED | detected, but the reader's state gate refused — fix `restream_go` |
| 14 + 15 GREEN, 16 RED | the re-stream is not sufficient — the repair itself is wrong |
| 16 GREEN | it was double-eaten, and the retry below is the fix |

**(2) `hop_tries`: the one-shot budget becomes a bounded 4.** ⚠ This is a real behavioural
delta, taken deliberately rather than waiting a round, because **one is wrong independently
of which candidate is true**: a single shot means any damaged repair leaves the menu fried
for as long as the user stays on it, and that is the symptom. **The BOUND is what prevents a
runaway, not the count** — and each attempt is separately bounded by the reader's
`RESTREAM_WD`. Block 16 keeps the reading unambiguous either way: if Hulk comes back clean
with 16 GREEN, the double-eat was the cause and is now measured rather than assumed.

### 13o. ★★★ `still_time` IS NOT A PROPERTY OF THE STREAM -- HW ROUND 3 (2026-09-16)

The §13m build's probe answered in one reading. On a fried Hulk still, `O[2]` row 2 read
**`R R G G R R R`**:

| block | signal | reading |
|---|---|---|
| 5 | `vbuf_deep` | R |
| 6 | **`still_active`** | **R -- the reader is NOT parked on a still** |
| 7 | `hl_on_w` | G |
| 8 | recolour fired | G |
| 14 | **detector fired** | **R -- no eaten header was detected** |
| 15 | reader re-streamed | R |
| 16 | eaten again | R |

★ And the comparison that settles it was already in hand: **round 1, which repaired EVERY
landing, left Hulk clean over 20+ runs.** Scoping to `cell_is_still` brought the fry back. So
the fried landing is one the gate excludes.

#### The measurement

`tools/menu_seq_census.py` counts start codes per menu cell straight out of the image:

    cell                        ES bytes  SEQ b3  GOP b8  PIC 00  END b7
    PGCN10 loop 30s              5510099      22      22     231       0
    PGCN11 39s                   5537891      26      26     220       0
    PGCN12 3s                    1975764      11      11      96       0
    PGCN13 heur-still 41s         224757       1       1       1       1
    PGCN14 loop 70s               224701       1       1       1       1   <-- !!
    PGCN15 STILL 255              224615       1       1       1       1
    PGCN16 loop 70s               224587       1       1       1       1   <-- !!
    PGCN17 STILL 255              224542       1       1       1       1

**PGCN 14 and 16 declare `still_time = 0` with a 70 s playback time and are
`SEQ GOP PIC:I SEQ_END` -- one picture plus 70 s of audio, looped by a cell command.** The
disc implements a 70-second still by looping a single-picture cell instead of setting
`still_time`. They fry exactly like a declared still, and no metadata says so.

★★★ **So §11's rule was right about the STREAM and I bound it to the wrong predicate.**
`still_time` is a number the AUTHORING TOOL wrote -- the `progressive_frame` failure class,
which this project has now hit with `closed_gop`, the IFO channel count, the declared angle
menus, and here. ⚠ **Ask whether a field is a MEASUREMENT or a CLAIM before gating on it.**

★★ **Field observation that confirms it independently:** *"the fried image goes away when the
menu audio loops."* The cell's own `LinkCN 1` loop re-delivers those bytes from the top into
a parser that is now clean -- **the disc performs the same repair, 70 seconds late.** That
also pins the fried cell to 14/16 rather than 15/17.

#### The fix: ask the STREAM, not the IFO

The verdict moves into the vld, where it is a measurement:

| | |
|---|---|
| `hdr_eaten` | a picture was decoded with an eaten header — the DETECTOR, unchanged |
| **`hdr_orphan`** | ...then a `sequence_end_code` with NO header in between = this cell carries one header for its whole length and **nothing will ever heal it**. The REPAIR trigger. |
| **`hdr_healed`** | ...then a sequence header = the next GOP fixed it for free. Do nothing. |

★ **A genuinely moving menu therefore stops triggering BY CONSTRUCTION rather than by a
gate** — which is what the round-2 regressions actually needed, and it needs no metadata and
no timer to tune.

⚠ `cell_is_still` is KEPT, but now gates only the **DROP** (`mpeg2video.drop_eaten_en`):
dropping an anchor is the one genuinely new behaviour here, so it stays restricted to cells
the disc itself calls stills. Elsewhere the fried picture is shown until the repair lands —
the v0.4.0 "flashes then resolves" behaviour, which is better than leaving an anchor-less GOP
to macroblock.

#### Gates

- **`seek_realign_tb` [8]** — the one-header landing: `eaten=1 orphan=1 healed=0`, dropped,
  not decoded, run completes.
- **`seek_realign_tb` [8m]** — ★ **the round-2 regression made executable.** The same eaten
  header on a MOVING landing (a multi-GOP cut B): `eaten=1 healed=1 orphan=0`, so the repair
  is never requested. ⚠ The mark has to be placed AFTER that fixture's own sequence header —
  measured, `SEQ post-flush = 2`, so a mark at the flush is simply cleared and the arm would
  stage nothing.
- 3 mutations, each caught by the arm that names the real failure: orphan at the eaten header
  instead of at the sequence end (→ [8m] reports the regression verbatim), a heal that does
  not clear the pending verdict (→ [8m]), and never setting it (→ [8]).
- **`tools/check_hop_mark_wiring.py`** now guards BOTH seams — `cell_is_still` →
  `drop_eaten_en`, and `hop_restream` keying on the orphan verdict rather than the raw
  detector. RED on all three re-regressions.

### 13p. ✅ HW ROUND 4 -- the stream-measured verdict works (2026-09-16)

Build `DVD_hoprestream_20260916_1738.rbf` (SEED 9, clk_dec 92.03/92.82), maintainer's rig:

- ✅ **Hulk settles on the correct image.** PGCN 14/16 are now detected by their STREAM shape
  rather than their metadata, so the repair lands in a fraction of a second instead of the
  ~70 s the disc's own cell loop took.
- ✅ **The other menus remain un-fried**, and **motion feels good** -- the round-2 regressions
  stay fixed, which is the `hdr_healed` cancel working by construction rather than by a gate.

⏳ **NOT merged: broader maintainer testing in progress.** Branch `fix/menu-hop-still-matrix`,
unpushed.

#### ⚠ Accepted residual, reported and deliberate: Hulk FLASHES fried before it settles

*"the fried flash does happen on hulk but it does settle on the correct image."* That is the
v0.4.0 behaviour and it is by design here: the **DROP** still keys on `cell_is_still`, which
reads 0 for PGCN 14/16 precisely because those cells lie about `still_time` (§13o). So the
fried picture is displayed until the re-stream lands, rather than held.

★ **The remedy is known and small -- gate the drop on the ORPHAN verdict too** -- and it was
deliberately NOT taken in this round. The orphan verdict is only available at the cell's
`sequence_end_code`, i.e. AFTER the picture has been decoded and displayed, so using it to
drop means dropping on evidence that arrives too late for that picture; it would only help
the NEXT visit. Dropping an anchor on a cell the disc does not declare a still is also the
riskiest half of this whole change (it has never been done -- `seek_realign_tb` arm [7] exists
to forbid the re-align rule from doing it). ⚠ If the flash is ever judged worth removing, the
honest options are: remember the orphan verdict per cell and drop on the SECOND visit, or
widen `cell_is_still` with a measured stream property -- not simply tying `drop_eaten_en` high.

### 13q. ★★★ OPTION A RETIRED -- the header cannot be eaten if the junction carries zero_byte stuffing (2026-09-16, branch `fix/menu-hop-zero-stuff`)

A second session reviewed `fix/menu-hop-still-matrix` cold (no context from the
sessions that built it) and replaced it. The old branch is kept, unmerged and
unpushed, as the fallback. This section is the reasoning; the verdict on option A
is in 13q.1, the replacement in 13q.2, the measurements in 13q.3.

#### 13q.1 What was wrong with option A

Option A worked on the discs it was tested on. It was retired for four reasons,
two of them defects and two of them cost:

1. **The detector cannot see the worst eat.** If the parser swallows the landing's
   sequence header AND its picture header, it resyncs on a *slice* start code,
   which `vld.v:907-909` accepts because `sequence_header_seen` /
   `sequence_extension_seen` / `picture_header_seen` are all still set from the
   old cell (they clear only at `STATE_SEQUENCE_END`). `STATE_PICTURE_HEADER` is
   never visited for the landing, so `hdr_eaten` never pulses, `eaten_pend` stays 0,
   and at the still's `SEQ_END` the `hdr_orphan` branch (guarded on `eaten_pend`)
   does not fire: **no repair, the fried still stays, and `await_hdr` is left
   stuck**. The landing's slices are also painted into the OLD open picture under
   the old picture header. Nothing in sim or on HW bounded how often a real cut
   lands there.
2. **The mark is a one-cycle pulse on the last arm of an if/else chain**
   (`vld.v:1442-1444`). Coinciding with `clk_en && state==STATE_PICTURE_HEADER &&
   await_hdr` (or the `SEQ_END` branch) it is dropped, not deferred, and that hop
   is unprotected.
3. **Its accepted residual was the original symptom.** Hulk-class cells
   (`still_time=0`, one picture + 70 s of audio) still showed the fried picture
   until the re-stream landed, because the DROP was gated on `cell_is_still` -- an
   authoring-tool claim the branch itself had just proved unreliable (13o).
4. **Footprint.** Six modules (`vld`, `mpeg2video`, `vidfeed_cdc` 9→10 bits,
   `dvd_iso_reader`, `audio_ring`, `emu`), ten new ports, forty bench tie-off
   edits, a wiring checker, a retry budget, a reader watchdog, three `O[2]`
   probes, an audio hold with a 0.19 s tail -- and the record's own admission that
   *"nothing in sim exercises `hdr_eaten` firing on a `keep_vbuf` hop"*. A re-read
   of the cell's sectors with the audio muted was the answer to "the bit pointer
   was mid-VLC".

The whole apparatus repairs a picture that need never be decoded wrong.

#### 13q.2 The fix: MPEG-2 zero_byte stuffing at the junction

ISO 13818-2 6.2.1 requires a decoder to skip any number of `zero_byte`s before a
start code, and this vld does (`STATE_NEXT_START_CODE` walks one byte per visit;
`24'h000000 != 24'h000001`, `vld.v:867`). So **`dvd/es_stuff.sv` puts 128 bytes
of `0x00` between the last byte of the outgoing cell and the first byte of the
landing.** From ANY state the cut left the parser in, an all-zero string cannot be
parsed as valid data for long -- read out of `vld.v` and `vlc_tables.v`, not
argued:

| parser state at the cut | what the zeros do | where it lands |
|---|---|---|
| mid-VLC (MBA, mb_type, motion_code, CBP) | every table returns `length 0` on zeros (`vlc_tables.v` defaults) | `STATE_ERROR` (`vld.v:1029/1051/1079/1089/1100`) → `1166` → hunt |
| mid DCT coefficient (B.14/B.15) | `[15:11]==0` on 16 zero bits | `STATE_DCT_ERROR` (`1134/1142/1148`) → `STATE_NON_CODED_BLOCK` pads the macroblock to its full block count → `1117` → hunt |
| mid fixed-length field (DC diff, escape 12 b, motion residual, quant scale) | taken as the value (≤ 18 bits) | the next state is a VLC state → as above |
| macroblock boundary | the spec's 23-zero `nextbits()` test (`vld.v:1117`) | hunt |
| mid header (fields, extensions, user_data) | every "another field follows" flag reads 0 | hunt within ~10 bytes |
| **inside a 64-entry quantiser-matrix download** (`STATE_LD_*_QUANT0`, `vld.v:942`) | **the loop is counter-driven and eats up to 64 zero bytes as entries** | hunt after ≤ 64 bytes |

That last row is why the run is **128 bytes and not 16**: `N >= 68` is the bound,
128 leaves margin and costs nothing (128 bytes of VBUF, ~256 clk_dec of hunting).
The hunt then finds `00 00 01 B3` intact -- a zero run followed by `00 00 01` is a
legal prefix from **any byte alignment**, which also disposes of the bit-alignment
half of the problem -- the header is parsed, the matrix downloaded, and the still
decodes correctly the **first** time. No fried picture, no drop, no re-stream, no
duplicate audio, and no black frame: nothing is flushed or reset.

★★ **Why this is not the 9 state force in a new hat.** 9's `flush_resync` forced
`state <= STATE_NEXT_START_CODE` from *anywhere*, including from inside a block,
so the block in flight never got its end marker; `rld.v` closes a block only on
that marker (`rld.v:167/181/261`), the next block merged into it, and every
following block shifted by one -- the measured luma-in-both-chroma-planes of 10.1.
The **natural** error paths cannot do that: `STATE_ERROR` fires only from states
that precede `STATE_BLOCK`, i.e. before `motion_vector_valid` announces the
macroblock to motcomp and before any coefficient enters the rld fifo, and
`STATE_DCT_ERROR` completes the announced macroblock with synthetic empty blocks.
Those are the paths that already resync 4 landings in 5 cleanly today; the stuffer
merely makes them unconditional.

★ **Why zeros and not `0xFF`.** The reverted `vidfeed_flush_primer` used `0xFF`
because it is inert to the start-code hunt. It is also inert to the *error*: a run
of 1s decodes as valid B.14 coefficients indefinitely (`11` = run 0, level 1). Only
zeros provoke the exit. Precedent in this very pipeline: `ps_demux`'s
`S_VID_FLUSH` emits 24 zero bytes after every still's `B7`, HW-proven since Phase 5.

**Where it lives.** A standalone shim between `ps_demux`'s `vid_*` output and
`vidfeed_cdc`'s write port in `dvd/emu.sv` -- **no port on any existing module
changes**, so no 40-bench tie-off sweep and no golden-bench churn. Armed by
`aud_drop_pulse` = `(jump_ack | seek_ack) & keep_vbuf`, the ONE junction with no
VBUF flush. The run goes in front of the first byte `ps_demux` presents after
that hop's pipe reset, which is the landing's first byte by construction.
⚠ **The spend waits for `pipe_rst_n` to have been LOW since the arm** (`rst_seen`):
in the cycle between the ack and `load_flush` taking `pipe_rst_n` low, `ps_demux`
can still present a byte of the OUTGOING cell, and a run in front of *that* puts
`<zeros> XX 00 00 01 B3` on the wire -- if `XX == 0x01` the hunt reads
`00 00 01 00`, a picture start code, and eats the real header from the other side.
`es_stuff_tb` T3 and mutation M1 are that case. The zeros ride the ordinary byte
path (CDC → packer → `vbuf_pos`), so the PTS-association coordinate stays exact
and the mark stays on the landing's real byte (`ps_demux` holds it, with
`mark_pending`, while `in_ready` is low). Reset domain `reset_n`, never
`pipe_rst_n`.

⚠ **Scope, deliberately narrow:** the `keep_vbuf` hop only. Stuffing on every
`load_flush` (chapter seeks, menu crossings) would be equally legal and probably
beneficial -- 11 records that a flush leaves the parser frozen mid-picture and the
first landing GOP's header can be eaten there too -- but those paths are covered
by the soft reset / the #45 realign and are HW-proven; one behavioural delta per
HW round. Recorded as a follow-up, not done.

#### 13q.3 Measured, before any RTL was written

`tools/quant_fixture.py` gained `--gap N` (N zero bytes between cut A and cut B)
and `--trunc-range` (one ISO walk per sweep). Everything below is
`quant_matrix_tb +NOFLUSH=1` -- the real `vld`/`getbits`/`rld`/`iquant` over real
cells, scoring **the matrix the decoder ends up holding** against the disc -- on
NACHO_LIBRE_WS VTSM07 **PGC10 cell0 → PGC13 cell0** (the looping motion menu →
the 10-button still; cut A's matrix peaks at 127, cut B's at 15, so a wrong matrix
is unmistakable).

| arm | trunc | gap | mismatches | downloads | verdict |
|---|---|---|---|---|---|
| control | 0 | 0 | 0/64 | 2 | PASS |
| **the eat (13j's offset)** | 5000 | 0 | **63/64** | **1** | **FRIED** |
| **the fix** | 5000 | **128** | **0/64** | **2** | **PASS** |
| cut INSIDE cut A's matrix download | 27520 | 16 | 62/64 | 1 | FRIED |
| same, sized by the table above | 27520 | **128** | **0/64** | 2 | **PASS** |

The mid-download pair is the sizing argument made executable: 16 zeros are eaten as
matrix entries and the landing's header goes with them; 128 are not.

★★ **The sweep, run on `main`'s RTL (not the option-A build): 251 offsets, `--trunc
4000..6000 step 8`, the same two cells.**

| gap | offsets | PASS | FRIED |
|---|---|---|---|
| 0 | 251 | 110 | **141 (56 %)** -- first at 4000, last at 5992, spread across the whole range |
| **128** | 251 | **251** | **0** |

Two things that number settles. First, the parser is vulnerable at far more cut
offsets than the board's ~1-in-5 suggested: the field rate is a property of where
a button press happens to land in a looping cell, not of how rarely the eat can
happen. Second, the option-A record's belief that "at most cut offsets this parser
errors out on the partial slice and resyncs BEFORE the landing's sequence header"
(vld.v's own comment, and 13j's six-of-seven) was an artefact of the seven offsets
chosen -- and its detector was never exercised in sim on the real cells at all
(13l), so nothing could have corrected it. The stuffed run is the first
measurement over a dense set of offsets, and it is 0 for 251.

Gates: **`bench/dvd/run_es_stuff.sh --red`** (six scoreboard arms -- passthrough,
arm/reset/land, the ack-cycle window, backpressure inside the run, two hops, arm
without a reset -- and seven mutations, each caught by its own arm),
**`tools/check_es_stuff_wiring.py`** (the seam read out of `emu.sv`; RED on a
bypass, a tied-off arm, and `main`'s own `emu.sv`), and
**`bench/dvd/run_menu_junction.sh`**, whose T2-only `[J1]` (8/8 PASS, "FAIL by
design") is now recorded rather than gated and whose gate is the Nacho trio
`[J1n]` RED / `[J3]` GREEN / `[J4]` sizing. `tools/lint_undriven.sh` PASS.

⏳ HW: the same protocol option A used -- control arm first (`main` on Nacho over
20 RE-landings, baseline ~1 in 5), then the fix on Nacho / Elmo / Hulk × 20,
expecting 0 fried **and Hulk correct on the FIRST view** (option A's flash residual
has no mechanism here); T2 / MiB / Matrix motion menus, Scooby-Doo 2, menu→title
Play, a chapter skip, and a still's narration not doubled, unregressed.

#### 13q.4 HW test plan (maintainer-run, control arm first)

Flash only the `.rbf` (`releases/DVD_hopstuff_<date>_<time>.rbf`, OSD line
`DVD dev-hopstuff 260916`); the Main is unchanged by this branch. Every arm below
counts RE-LANDINGS, not captures: once a still is fried it holds, so re-shooting a
parked menu measures nothing (13c-quinquies-bis). 20 landings is the minimum that
means anything against a 1-in-5 rate (0.8^20 = 1.2 %).

**Arm 0 -- control, on the CURRENT `main`/release core, same session, same discs.**
Nacho: 20 landings on the VTS_07 still (the one that fried ~1 in 5); expect ~4
fried. Hulk: 5 landings on the VTS_06 special-features still (PGCN 15, reached by a
button from the 70 s looping clip); expect it fried, holding until the clip's audio
loops (~70 s) and then clean. If the control does NOT reproduce, stop -- the rig or
the route has changed and the fix arm would measure nothing.

**Arm 1 -- the fix, same routes.**

| disc / route | presses | pass |
|---|---|---|
| NACHO_LIBRE_WS, VTS_07 menu -> the still that fried | 20 landings | **0 fried** |
| INCREDIBLE_HULK, VTS_06 special features (button from the 70 s clip) | 10 landings | **correct on the FIRST view, no flash** -- a flash-then-settle means the eat still happened and the cell loop repaired it, i.e. the stuffer did not reach that junction |
| WAKE_UP_WITH_ELMO main menu (the #92 crossing path) | 10 launches | 0 fried (unregression; this route is the soft reset's, not the stuffer's) |
| ULTIMATE_T2 Mission Profiles, first slide of each actor (the #96 natural-drain path) | every actor once | first slide clean (unregression) |

**Arm 2 -- the motion menus that option A round 1 broke.** The stuffer fires on
EVERY `keep_vbuf` hop, including a looping motion menu's own loop, so this is the
arm that can show a cost: MEN_IN_BLACK root menu (loops), THE_MATRIX menus, T2
main menu. Watch for: an animation restarting, highlights ahead of the picture,
sluggish response after a press, macroblocking at a transition. Expect none -- a
zero run before a start code is what the stream would contain if the authoring
tool had padded it.

**Arm 3 -- untouched paths, one each.** Scooby-Doo 2 minigame (title-domain, no
`keep_vbuf`, must be identical); menu -> title Play; a chapter skip during a
title; a menu still with narration (the audio must play once -- there is no
re-stream here, so this cannot regress, but it is the issue-#65 arm and costs one
press); Stop and resume.

**What to report per arm:** landings / fried, and for any fried image whether it
HOLDS or resolves, and on which disc and menu. `Debug Overlay` is not needed --
this fix has no probe and no state; a fried still under it means the zeros are
not being inserted at that junction, and the next step is `tools/check_es_stuff_wiring.py`
on the built `emu.sv` and a `keep_vbuf` trace of the route, not tuning `N`.
If a capture is in doubt, `tools/fry_detect.py` scores a screenshot against
ffmpeg's decode of the same menu's own bytes (>= 1.5x = fried).

**If arm 1 fails:** the fallback is `fix/menu-hop-still-matrix` (option A, HW-confirmed,
unpushed) -- not a re-derivation. Record the measurement here first.

### 13f. WHAT A REAL PLAYER DOES -- asked of the oracle, not reasoned about

libdvdnav is the independent oracle for this project (docs/dvd_vm.md, the POST-only PGC
bug). Asked directly, it has **two** protections at this junction and we have neither on a
`keep_vbuf` hop.

**(1) The NAVIGATOR raises a sync point, at exactly our case.** `libdvdnav/src/dvdnav.c:869`:

```c
/* we are about to leave a cell, so a lot of state changes could occur;
 * under certain conditions, the application should get in sync with us before this,
 * otherwise it might show stills or menus too shortly */
if ((this->position_current.still || this->pci.hli.hl_gi.hli_ss) && !this->sync_wait_skip)
    this->sync_wait = 1;                       /* -> DVDNAV_WAIT */
```

`still || hli_ss` is "a still, or a cell carrying menu buttons" -- the exact population
§13c-bis sizes. MEASURED with a new tracer, `tools/dvd_trace/trace_wait.c` (a fork of
trace_nav that REPORTS the wait instead of swallowing it):

| disc | DVDNAV_WAITs | where |
|---|---|---|
| INCREDIBLE_HULK | 7 | VTSM/VMGM menu PGCs incl. `vts=6 pgc=10` (x2), `pgc=15` |
| NACHO_LIBRE_WS | 3 | incl. `vts=7 pgc=10` (x2) -- VTS_07 is the menu set that fries |

★★ **AND THE SOURCE STOPS.** libdvdnav hands out no further blocks until the app calls
`dvdnav_wait_skip()`. VLC drains its decoder there **with a timeout**
(`modules/access/dvdnav.c` DVDNAV_WAIT: `EsOutDrainOnce` -> `ES_OUT_IS_EMPTY` ->
`WaitEmptyTimeout`).

⛔⛔ **THAT IS EXACTLY WHAT §13e's FIX GOT WRONG.** It waited for a quiet point *while the
reader kept streaming the loop*, so the quiet point never came. The reference design
**stops the source first, then drains, and bounds it with a timeout.** Same idea; the
ordering is the entire difference between a fix and a dead menu button.

**(2) The DECODER discards everything until a fresh intra frame.**
`vlc/modules/packetizer/mpegvideo.c`: `PacketizeReset` sets `b_waiting_iframe` and flags
`BLOCK_FLAG_DISCONTINUITY`; `PacketizeValidate` then returns `VLC_EGENERIC` for every
access unit that is not an I ("waiting on intra frame"). So a software player never
decodes a picture assembled across a discontinuity. Ours does -- the vld keeps
`sequence_header_seen` set, accepts the landing's picture start code, and dequantises with
the stale matrix.

★ **We already own mechanism (2):** `rtl/mpeg2/vld.v`'s seek-realign (issue #45) drops
leading non-I pictures after a discontinuity. It is gated on `vbuf_flush`, which by
definition does not fire on a `keep_vbuf` hop -- so it is present, HW-proven, and simply
not armed here.

⚠ VLC/MPlayer/xine/Kodi all navigate through libdvdnav and inherit (1); only VLC's
handler was read here, so do not assume the others' specifics without checking.
⛔ Do NOT reach for the issue-#65 menu-still cold re-decode; it replays audio.
