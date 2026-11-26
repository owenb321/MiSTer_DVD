# Trick play (continuous fast-forward / rewind)

Status: 🔧 design, offline model, the splice through our RTL decoder in simulation, the ES
filter (`dvd/trick_es_filter.sv`) and the reader's trick walk (`dvd/dvd_iso_reader.sv`),
the audio drop (`ps_demux` `aud_drop`), the display cadence (`disp_sched` `cad_en`) and the
controller (`dvd/trick_ctrl.sv`), all bench-proven and wired into `dvd/emu.sv`; ⏳ the first
hardware round. `feature/trick-play`, 2026-11-24.
The background is `docs/dvd_nav.md` §2d, which records why this is not a seek mode.

## Decisions (maintainer, 2026-11-22)

1. **Hold-FF / hold-REW becomes trick play.** The scrub-to-target behaviour of
   `dvd/scrub_ctrl.sv` gives those buttons up. (The D-pad fixed-time seek, `O[45]`, is
   untouched.)
2. **Speeds are measured, not chosen.** A tier ships only if the rig shows it pulls I-frames
   reliably at that rate. There is no fixed list such as 2×/4×/8×.
3. **No slow motion.**
4. **A disc image gets no advantage over a physical disc.** Trick play on an `.iso` is
   throttled to a measured physical-drive baseline, so both sources show the same tiers at
   the same smoothness. The general principle, by the same decision: a physical disc's
   behaviour is the baseline, and a ripped image extends it only where that costs a physical
   disc nothing.

## Mechanism

Seeking flushes the decoder and lets it re-lock. Trick play must never flush: one flush per
VOBU is the "mostly black + watchdog resync" regime the scrub's early HW rounds proved
fatal (`dvd/dpad_seek.sv` header). Instead:

- **Read only each VOBU's first reference picture**: sectors `[nv_pck .. nv_pck +
  vobu_1stref_ea]` (DSI `0x0C`, already parsed by `dvd/nav_dsi.sv` and dead-stripped today).
- **Splice those reads into one continuous stream.** Every splice is a pack boundary, so
  `ps_demux` needs nothing new for the splice itself.
- **Pick the next VOBU from the DSI's VOBU_SRI table**: `fwda[19]` / `bwda[19]` at
  120, 60, 30, 10, 7.5 … 0.5 s. Forward and reverse are the same machine.
- **Filter the video ES** so the decoder only ever sees whole pictures: pass the sequence
  header, GOP header and the reference frame (both fields when field-coded), drop from the
  next picture start code to the next sequence header. Needed because `1stref_ea` is a
  sector, and the cut sector carries the start of the next picture (measured: see below).
- **Drop audio and subpicture packs** while in trick play (the audio ring would otherwise
  back-pressure the demux), and mute.
- **Show each I-frame for N refreshes**, ignoring PTS; the HUD clock follows each VOBU's
  `c_eltm`.
- **Leave with an ordinary seek** to the VOBU on screen (the proven seek path).

## Library measurements

`tools/trick_scan.py` walks the main feature of each disc by `fwda` at 10 s (itself a
trick-play walk) and measures the premises above from the bitstream, not from the IFO.

**2026-11-22, seeded sample of 150 discs (`--limit 150 --seed 1`), 56,442 VOBUs:**

| Premise | Measured | Consequence |
|---|---|---|
| A VOBU starts with an I-frame | 56,400 of 56,401 with video (one `no_pic`) | the splice works on every disc sampled |
| Frame-coded or field-coded | 56,400 frame pictures, **0 field pairs** | field pairs must still be handled (spec maximum rule), but no sampled disc exercises it: a bench needs a synthetic stream |
| VOBUs with no video (`1stref_ea` = 0) | 41 (0.07 %) | skip them: show nothing, jump again |
| Cost of one I-frame read | per-disc p95: median 57 sectors (117 KB), worst 117; largest single 127 sectors (260 KB) | the read budget per frame is ~60–130 sectors |
| The cut sector holds the start of the next picture | 56,165 of 56,401 (99.6 %) | the ES filter is **required**, not defensive |
| `fwda` valid, by rung | 0.5 s 97.8 %, 1 s 95.3 %, 2 s 90.3 %, 10 s 71.2 %, 60 s 58.2 %, 120 s 44.2 % | long rungs fall into END_OF_CELL often (short cells, cell ends). A tier on a long rung needs a fallback: step down a rung, or go to the next cell |
| `bwda` valid, by rung | 0.5 s 95.9 %, 10 s 92.2 %, 120 s 59.0 % | the same, backwards |
| VOBUs inside an ILVU block | 581 (1.0 %) | angle / branch handling is not rare enough to skip |

⚠ **The sweep's walk starts at the title VOB's first sector, not at the PGC's first cell.**
Copy-protected discs put zero-filled or decoy sectors there (CASTLE_USD2: over 1,000 zero
sectors; 19 discs needed resyncs, 6 of them gave up). The core follows cells, so this does
not affect the design, but those discs' rows under-sample. Starting the walk from the
title PGC's cells is a TODO for the tool.

## The splice model

`tools/trick_splice.py` builds the stream trick play feeds the decoder, from a real ISO, and
decodes it with ffmpeg: one clean picture per VOBU, or FAIL.

**2026-11-22, 24 discs from the sweep (seeded), every tier, both directions, 30 frames:
192 / 192 clean, 0 decoder errors.** The `--raw` control (the cut sectors as read, no filter)
decodes twice as many pictures, all of them corrupt (78–102 errors on Men in Black 3): the
partial B-frame each read carries is real, and the filter is what removes it.

**The filter rule, as the RTL must implement it:**
- drop until the VOBU's first sequence header (`00 00 01 B3`);
- pass the reference frame: one frame picture, or the first two pictures when the first is
  field-structured (the pair; the second field is not checked, `pair_n` counts pairs);
- cut at the next **picture start code, recognised from its 4 bytes alone** (`00 00 01 00`).
  The first model needed 6 bytes of header and let a picture start split by the read's end
  through: 6 of 193 runs failed with "ignoring seq ext after 100";
- at the end of a read, drop a dangling `00 00 01`. Zero bytes left before the next sequence
  header are legal stuffing and can stay. 5 of the 24 discs end a read this way.

**Cell edges are required, in both directions.** Reverse stops at a cell's first VOBU, where
every `bwda` entry and `prev_vobu` say END_OF_CELL:

| Jump | forward reached 30 | reverse reached 30 |
|---|---|---|
| 0.5 s | 24 / 24 | 24 / 24 |
| 2 s (really 1.5 s, see below) | 24 / 24 | 20 / 24 |
| 10 s | 24 / 24 | 6 / 24 (median 14) |
| 30 s | 24 / 24 | 1 / 24 (median 7) |

Forward crossed only because the model fell back to the next sector, which is wrong wherever
the play order is not the physical order (`docs/dvd_nav.md` §2f) or inside an ILVU block.
So at END_OF_CELL the reader takes the next (or previous) cell from the PGC's cell table:
its first VOBU going forward, its last VOBU (`last_vobu_start_sector`) going back. It does
not run cell commands.

## The physical-drive baseline

**2026-11-22, rig .236, Dell DW316 (USB), a pressed dual-layer CSS film disc**, read through
libdvdcss (the drive refuses scrambled sectors until authenticated, so raw `/dev/sr0` reads
fail and their timings are meaningless). Twelve reads per row at fresh positions, at 15 %,
50 % and 85 % into the feature, both directions; 0 errors in 1,152 reads. The script is a
one-off (`drive_jump.py`, run on the rig); the method is what to repeat.

| Jump (≈ sectors) | 60 sectors: median, p90 | 127 sectors: median, p90 |
|---|---|---|
| 0.5 s (200) | 68–101, 102 ms | 78–146, 189 ms |
| 2 s (800) | 68–105, 106 ms | 163–247, 247 ms |
| 10 s (4,000) | 91–112, 125 ms | 187–283, 292 ms |
| 30 s (12,000) | 101–133, 154 ms | 198–295, 319 ms |
| 60 s (24,000) | 121–155, 266 ms | 196–324, 354 ms |
| 120 s (48,000) | 128–170, 208 ms | 245–368, 409 ms |

- **Transfer, not seek, dominates.** The extra 67 sectors cost 100–150 ms (≈ 1× DVD speed on
  random reads); seek distance adds only 30–70 ms across the whole range.
- With the next frame prefetched while the current one shows, the drive sustains about
  6–9 typical I-frames per second and 2.5–4 of the largest.
- A sample of one drive and one disc. USB drives vary widely, so the baseline must be
  conservative.

**Decided (maintainer, 2026-11-22): T = 250 ms, and the hold steps through 2×, 8×, 40×,
120×** (⚠ superseded 2026-11-24 by 16× / 40× / 120× / 480×: see "The speed ladder, raised") (jumps of 0.5, 2, 10 and 30 s; valid 98 / 90 / 71 / 66 % of the time in the sweep, the
rest falling back to a shorter jump). The mechanism: a fixed display cadence of one I-frame every T ms,
T from the drive's p90 for a typical frame, with image reads gated to the same cadence.
Decision 4 then holds by construction: the only difference left is that a late physical read
holds the previous frame a little longer. A tier's speed is its jump ÷ T; at T = 250 ms the
jumps 0.5 / 1 / 2 / 10 / 30 / 60 / 120 s give 2× / 4× / 8× / 40× / 120× / 240× / 480×.

## Open questions

- The PGC's edges: at the last cell going forward, drop to normal play so POST runs; at the
  first cell going back, stop at its first VOBU and resume there.
- ~~Angle blocks: whether `fwda` stays inside the playing angle.~~ It does (41-disc sweep,
  "Angle blocks: the walk stays in its angle"). So do seamless-branch cells (below).
- Entering: title domain only, playing, no buttons armed, no still.
- `.mpg` and VCD have no nav packs: out of scope (they keep scrub-to-target).

## The splice through our decoder

`bench/dvd/run_trick_decode.sh` (gate, `--red`) runs the spliced stream through the WHOLE
video decoder, `rtl/mpeg2/mpeg2video.v` as `dvd/emu.sv` instantiates it, behind a memory
model (`bench/dvd/trick_decode_tb.sv`, the tree's first full-decoder bench).
`bench/dvd/trick_decode_score.py` rebuilds each reconstructed picture from the framestore
writes and compares it with ffmpeg's decode.

**2026-11-23, Men in Black 3, 6× forward** (the model's "2 s" rung was the 1.5 s entry; see "The reader"): every complete picture matches ffmpeg to within
one code value (Y 67.3–67.5 dB, Cb/Cr 65.7–66.7 dB, max |diff| 1; 5 of 5 on a 6-VOBU walk,
3 of 3 in the gate), no watchdog, no decoder error. The RED arm feeds the raw cut sectors
and scores them against the filtered pictures: the decoder raises `error` twice and the arm
fails, so the filter is load-bearing in our decoder, not only in ffmpeg.

What the bench taught, for whoever extends it:
- **The decoder holds a picture's last 8 words until the next picture starts** (388,792 of
  388,800 words for 6 pictures). The stream's final picture never completes, so the runner
  splices one VOBU more than it scores. In trick play there is always a next picture, but
  the *exit* path must not assume the last shown I-frame is fully written: leaving is an
  ordinary seek, which flushes, so this is not expected to matter. Note it if it ever does.
- Framestore pixels are stored signed (pixel − 128), and **Cb is the plane after luma, then
  Cr**.
- `mem_req_prefetch` is a standard FIFO, not first-word-fall-through: `valid` follows
  `rd_en` by a cycle.
- Icarus speed: ~1,750 `clk_dec` cycles/s, ~8 min per 720×480 picture. The gate scores 3.
- A preloaded 8 MB `reg` array read through `always @*` hung Icarus's compile for 18 h; the
  bench reads the `.m2v` with `$fgetc`.
- `rtl/mpeg2/mpeg2video.v` used eight signals before declaring them (Quartus accepts it,
  Icarus does not); the declarations moved up, no logic changed (`DVD-FORK FIX`).

## The ES filter in RTL

`dvd/trick_es_filter.sv`: the rule above, streamed. It goes between `ps_demux`'s video
output and `es_stuff`, and is a wire when `en` = 0. **Not wired into `dvd/emu.sv` or
named in `DVD.qsf` yet** (that comes with the reader's trick FSM, which drives `en`).

- **Holding, not buffering.** A byte leaves as soon as no later byte can change its fate.
  Only a tail that might begin a start code (`00`, `00 00`, `00 00 01`) is held, plus the
  first picture's code and two header bytes until `picture_coding_type` is known: never
  more than 6 bytes. A picture's last bytes therefore never wait for the next read, which
  would hold a whole frame for one cadence period.
- **The dangling `00 00 01`.** It arrives followed by the next read's `00 00 01 B3`, so the
  wire carries `00 00 01 00 00 01 B3`. The first four bytes form a picture start code and
  make the cut, and its last byte stays held as the first byte of the header. In a valid
  ES `00 00 01 00 00 01` cannot occur (it would be picture_coding_type 0, forbidden).
- **A first picture that is not an I-picture:** the read's headers have already passed
  when the type is known, so they stay and the picture is dropped (`skip_n` counts it).
  The model (`tools/trick_splice.py` es_filter) was changed to do the same, so the two
  stay byte-exact. A sequence header with no picture before the next one is harmless to
  the vld, which dispatches on whichever start code comes next. 0 such VOBUs in the sweep.
- **Field pairs** pass both fields (`pair_n` counts them); `picture_structure` is read from
  the first picture's coding extension, and MPEG-1 (no extension) is always a frame.
- **Rate:** one byte per two `clk_sys` cycles in trick play (13.5 MB/s; a trick read is
  ~0.5 MB/s).

**Gate: `bench/dvd/run_trick_es_filter.sh` (`--red`).** It is byte-exact against the model
on 8 discs drawn with a fixed seed from `$DVD_ISO_DIR` (every tier, both directions), with
random input gaps and output backpressure. Six synthetic streams cover what no disc in the
sweep contains: a field pair, a first picture that is not an I, MPEG-1, a dangling
`00 00 01`, trailing zero stuffing, and junk with start-code-like bytes around the
headers. One RED mutation per rule fails its own case: the held byte, picture_structure,
picture_coding_type, cutting at the first picture, and the `en` = 0 wire.
Icarus moves only ~18 KB/s through this bench, so the runner keeps walks to 3 reads and
runs cases 6 at a time.

## The reader

`dvd/dvd_iso_reader.sv`, the TRICK PLAY note in the file. Ports `trick_en`, `trick_tier`
(0.5 / 2 / 10 / 30 s), `trick_rev`, `trick_go` (the cadence gate) in; `trick_vobu`,
`trick_nav`, `trick_eltm`, `trick_edge`, `trick_xcell_n` out. **Not wired into
`dvd/emu.sv` yet**: every reader bench ties the inputs off.

- **It rides the ILVU jump.** The reader already snoops each NAV pack's DSI as the sector
  streams (for angle blocks) and has a jump that moves the fetch pointer **without a
  flush** (`seek_rbn_l` + `rbn_override` + `S_CELL_LOAD`). Trick play adds fields to that
  snoop (`vobu_1stref_ea`, `c_eltm`, `prev_vobu` and the four tier rungs for the current
  direction) and arms a jump at every NAV pack: the fetch ends at `nv + 1stref_ea`, then
  jumps.
- **Target:** the tier's rung; END_OF_CELL crosses; a 0 rung falls through to a shorter
  one, an all-zero table to `next_vobu`/`prev_vobu` (rule revised 2026-11-24, see "Second
  hardware round").
  An entry is usable when its low 30 bits are neither 0 nor `0x3FFFFFFF` (END_OF_CELL)
  **and** the target lies in the current cell. Otherwise the neighbouring cell in play
  order: its first sector going forward, its last VOBU going back (a new
  `cell_lv_mem`, 256 × 32 bits, one M10K, holding each cell's `last_vobu_start_sector`).
  Past the PGC's first or last cell, `trick_edge` rises and the reader holds. Cell
  commands never run.
- **Only the four tier rungs are captured,** not all 19 + 19 entries (≈ 128 flops
  rather than 1,216). The fallback therefore steps down through the tiers' rungs, not
  every rung; the model does the same.
- **The cadence gate:** at the end sector, the jump waits until `trick_go` has been seen
  since the last jump (a one-pulse credit), and no further sector is read meanwhile.
  Free-running (`trick_go` held high) is one VOBU after another.
- **Trick play ending without a seek** (the controller is expected to seek; this is the
  floor): the reader carries on from the sector after the reference picture.
- **A whole-sector guard (`tk_sec_ok`):** only a sector whose first byte arrived with
  `trick_en` high can arm. Without it, trick play re-entered partway through a video
  sector armed on it, because the snoop still held the last session's NAV signature.
- **⚠ The 2 s rung is fwda[15], not [16].** The vobu_sri table runs 120, 60, 30, 10, 7.5,
  7, 6.5 … 1, 0.5 s. `tools/trick_splice.py` had 16 (1.5 s) until 2026-11-24, so the
  splice-model and decoder runs labelled 2 s or 8× above were 1.5 s and 6×. Neither result
  depends on the exact jump. The library sweep's per-rung figures were always labelled
  correctly.
- **Angle blocks** (resolved 2026-11-25, see "Angle blocks: the walk stays in its angle"):
  a crossing steps over a block as one cell (`cell_after`, `block_first - 1`), a walk
  inside one stays in its angle (measured on 41 discs), and a backward entry now walks back
  to the block's first cell so the chosen angle is picked.

**Gate: `bench/dvd/run_trick_reader.sh` (`--red`).** `bench/dvd/iso_reader_trick_tb.sv`
serves the reader sectors from the real `.iso` (`$fseek` in steps: Icarus's offset is a
signed 32-bit integer, and title VOBs sit past 2 GB), seeks into the title and turns
trick play on. `bench/dvd/trick_reader_check.py` walks `walk_cells` over the cell table
the reader itself parsed and requires the same VOBUs, the same end sectors and exactly
those sectors streamed. Six arms on Men in Black 3: forward and backward at 2 s and 30 s
(the 30 s walks cross cells both ways), the PGC's edge, and the cadence gate. Every arm
also checks that each armed sector is a NAV pack, that the reader keeps reading when trick
play ends without a seek, and a second session entered at sector byte 0x500. Seven RED
mutations, each failing its own arm: the 2 s rung, cell crossing, the backward landing,
the gate, 1stref_ea, the whole-sector guard and the edge hold. With trick play off,
`bench/dvd/run_reader_regress.sh` is bit-identical to the previous reader on every arm.

## Audio and subpicture

`dvd/ps_demux.sv` `aud_drop`: while high, every audio PES (MP2 stream `0xC0`–`0xC7` and
private_stream_1 audio) takes the path a non-selected track already takes (skip by
length). Without it, the audio ring fills in trick play, its backpressure stops the demux,
and the video stalls with it: measured on Men in Black 3's trick reads, the demux stops
after 22,560 of 618,496 bytes. Subpicture and PCI need nothing new: `sp_enable` and
`pci_enable` exist and `dvd/emu.sv` will gate them with trick play, so no subtitle unit
and no button highlight arms over trick frames. DSI keeps flowing.

**Gate: `bench/dvd/run_trick_demux.sh` (`--red`).** A synthetic stream with video, MP2,
AC-3 and a subpicture, and the raw sectors of 6 trick reads of Men in Black 3. With
`aud_drop` and the audio ring full: no audio out, no stall, video byte-identical. The
controls show the audio does flow without `aud_drop` (so the zero is not vacuous) and that
a full ring stalls the demux. One RED mutation per discard site (MP2 and
private_stream_1). Every bench that instantiates `ps_demux` ties `aud_drop` low;
`dvd/emu.sv` ties it, and the reader's trick inputs, low until the controller exists.

## The display cadence

`dvd/disp_sched.sv` `cad_en` (through `rtl/mpeg2/mpeg2video.v` `trick_cad`). While high,
each picture is due `CAD_TICKS` (22,500 ticks, 250 ms) after the previous pickup, with the
usual half-scan rounding onto the raster's pickup grid; the first is due at once. PTS is
ignored, and `cad_en` overrides A/V Sync Off.
- **A late picture** (a slow physical read) is shown at the first opportunity after it
  arrives: the previous frame simply holds longer, which is decision 4's only visible
  difference between a drive and an image.
- **Nothing is late:** `next_due` stays low, so neither `frame_late` nor the frame-drop
  governor ever acts on a trick frame, and there is no catch-up drop.
- **A pickup does not anchor or move the timeline.** Every trick I-frame is a PTS jump;
  on the normal path each one would re-anchor the clock and pulse `anchor_disc`, which
  re-phases audio. Leaving trick play is a seek, whose flush restarts the timeline.
  Caption credits (`cc_credit_valid`) stop with the pickup branch, so no line-21 data is
  paced out of trick frames.

**Gate: `bench/dvd/run_disp_sched.sh`, scenarios [15a]-[15c], mutations M15-M18.**
[15a]: 8 ready pictures with PTS jumping 30 s forward and back: the first at the first
opportunity, then 22,522 ticks apart (15 NTSC scans), 0 anchors, 0 catch-up drops. [15b]:
a picture ready 60,000 ticks after the previous pickup is shown at 60,080, and the wait
counts no late (run with A/V Sync off, where `next_due` would otherwise be forced high).
[15c]: the cadence holds with A/V Sync off. Mutations: the cadence ignored, a wait counted
late, a pickup anchoring, the first picture waiting.

## The controller and the wiring

`dvd/trick_ctrl.sv` (gate `bench/dvd/run_trick_ctrl.sh --red`: 9 scenarios, 7 mutations).
A press in a DVD title that trick play `allowed` (cell mode, not a menu or in-title menu,
no armed buttons, not a still, not stopped) enters with ONE seek to the playhead: its flush
throws away the normal video buffered ahead, so the first trick frame comes at once, and the
reader (trick_en already high) arms at the landing's first NAV pack. The tier steps at 2 /
4.5 / 8 s held (`scrub_ctrl`'s dwells); `trick_go` pulses every 250 ms. Release, the other
button, `allowed` falling or the reader's edge exit with ONE seek to the VOBU on screen (the
one armed before the latest: the reader fetches one ahead), and `active` drops in the same
cycle. After an exit both buttons must be released before trick play can start again
(`owns` covers that gap, so `scrub_ctrl` does not pick the held button up either).

`dvd/emu.sv` (gate `tools/check_trick_wiring.py --red`, 15 RED arms):
- `scrub_ctrl` sees FF/REW only through `~trick_claim` (= `trick_allowed | trick_owns`): it
  keeps `.mpg`/VCD and the DVD states trick play refuses;
- trick play's seeks join `seek_any_*` (mode_realign's arbitration) and are SECTOR seeks to
  NAV packs, so not part of `seek_tm_req` (`tools/check_tmap_seek_wiring.py` updated);
- the reader's ports, `ps_demux` `aud_drop`, `sp_enable` and `pci_enable` gated off;
- `dvd/trick_es_filter.sv` between `ps_demux` and `es_stuff`, reset by `pipe_rst_n`
  (`tools/check_es_stuff_wiring.py` follows the chain through it);
- `trick_cad` = `trick_active` through two `clk_dec` flops;
- the HUD: the status line stays up (`bar_active | trick_active`, not the seek bar, whose
  base and target are the scrub's) and the speed arrows are the tier. The clock needs
  nothing: `nav_dsi` parses each spliced VOBU's DSI as it passes the demux;
- `DVD.qsf` names `dvd/trick_ctrl.sv` and `dvd/trick_es_filter.sv`.
`tools/lint_undriven.sh` passes.

**Open, for the maintainer:** a tap of the GAMEPAD's FF/REW on a DVD now enters and leaves
trick play at once and lands back on the VOBU on screen; on `scrub_ctrl` a tap nudged ~1 s.

## Keyboard and remote: tap or hold

Decided 2026-11-24 (maintainer): a keyboard / remote FF/REW **hold** drives trick play too,
and a **tap** stays the 10 s jump. Keyboard, CEC and IR keys reach the core as press pulses
only (`dvd/kbd_map.sv`), and `emu.sv` kept them off every hold path because an IR remote
"holds" as ~9 discrete taps a second. Now:
- `kbd_map` also emits RELEASE pulses for FF/REW (`rel`), still pulses only;
- `dvd/kbd_hold.sv` turns press/release into a run: gaps under 200 ms are bridged (the
  remote's tap stream is one run), a run of 400 ms is a HOLD (`held`), a shorter one is a
  TAP pulsed 200 ms after its last release; a key "down" 60 s with no event ends the run
  (a lost release). CEC sends its releases (stock Main `hdmi_cec.cpp`, with a deadline);
  Main drops keyboard auto-repeat, so a held key is one press and one release.
- `emu.sv`: `trick_ctrl` takes `joy_ff | kbd_ff_held`; where trick play claims FF/REW the
  10 s jump comes from the TAP (`kbd_ff_jump = trick_claim ? kbd_ff_tap : kbd_joy[13]`),
  elsewhere from the raw press as before, so a VCD / `.mpg` is unchanged. Trick play's
  seeks also unpause, so a keyboard hold from pause shows its frames.

Gate `bench/dvd/run_kbd_hold.sh --red` (5 scenarios: tap, keyboard hold, IR tap stream,
two taps, lost release; 4 mutations); `tools/check_trick_wiring.py` R16-R18;
`bench/dvd/run_kbd.sh` unchanged. This is also what makes trick play testable from the HIL
harness, whose key daemon is a keyboard.

## The first fit (2026-11-24)

`releases/DVD_trickplay_20261124_1513.rbf`, SEED 7, timing PASS: clk_dec 96.4 / 91.6 MHz
(100 / −40 °C, floor 86), clk_mem 99.8 / 102.7 (floor 90). Against v0.11.0 on the same
seed: **+866 ALM (91 % → 93 %), +1 M10K (`cell_lv_mem`, inferred as an altsyncram), +0
DSP.** About 2,760 ALM and 32 M10K remain. The first attempt failed elaboration: Quartus 17
rejects the ES filter's `z[i+1]`/`o[i+2]` on a 6-bit vector even where the guard never
selects them (error 10232); Icarus and Verilator accept it. The vectors are 8 bits now.

## The first hardware round (2026-11-24)

Rig .236, `releases/DVD_trickplay_20261124_1606.rbf` (`d59bd8a`, SEED 7, timing PASS; fit
97 % ALMs needed, packing difficulty High with ~1,100 ALM recoverable by dense packing; the
two `kbd_hold` instances are ~115 ALM of it, the rest is this fit's packing). Holds sent as
keyboard Tab / Backspace through the HIL key daemon (`key 15 <ms>`), which is what the
keyboard path made possible. HUD read from screenshots, pacing from 2 Hz telemetry.

| Run | Result |
|---|---|
| Men in Black 3 image, FF held 10 s from 0:22 | trick play for 9.5 s; **4.0 pictures/s**, audio 0, 0 re-anchors, 0 drops; HUD `►►►►` mid-hold; landed ~6:06 (≈ 364 s; the ladder predicts 404) and played on with audio |
| Same, REW held 6 s from ~6:57 | trick play the full 6 s; landed ~6:02 and played on |
| Same, REW held 14 s from ~6:51 | the **edge**: trick play ended after ~10.5 s while still held, play resumed at 0:00, no re-entry while held |
| Same, a 50 ms Tab tap | **+10 s jump**, as before |
| The Force Awakens, **physical** DW316, FF held 10 s from ~1:37 | 3.63 pictures/s (min 2.0); landed ~3:43 (≈ 126 s) |
| The Force Awakens **image**, FF held 10 s from ~1:45 | 3.91 pictures/s (min 1.9); landed ~3:47 (≈ 122 s) |

**Decision 4 holds on the same film:** an image and the physical drive travel the same
distance in the same hold; the drive shows a picture a little longer now and then. Normal
playback on this build: 0 lates, 0 drops, audio at rate; the keyboard 10 s jump unchanged.
MIB3 travels farther than TFA in the same hold because of the discs' structure (cells and
rung validity), not the source.

**Found:**
- `lates` ticks 1-2 per half second during trick play. Not the decode-miss term (that needs
  `sched_next_due`, low in the cadence mode): it is `par_late_r`, the field-parity
  corrector slipping a field as the picture changes abruptly. Nothing was dropped (no
  B-frames to drop), but it banks into `frame_drop_ctl`; gate it with the cadence mode.
- The ladder's distances fall ~10 % short of prediction (entry re-lock before the first
  frame, rung fallbacks at cell ends). Not a defect; worth a closer measurement if the
  speeds feel wrong.

## The speed ladder, raised (maintainer, 2026-11-24)

On the rig the maintainer found hold-to-scrub "much slower than previous core versions". It was
the ladder, not the decoder: the cadence held ~4 pictures/s at every tier (image and drive),
each just jumping a short way. The old scrub (`dvd/scrub_ctrl.sv`) moves ~15 / 60 / 240 / 960
content-seconds per second; 2× / 8× / 40× / 120× was ~8× slower at every tier.

**Decided: 16× / 40× / 120× / 480×**, jumps of 4 / 10 / 30 / 120 s (fwda 11/3/2/0, bwda
7/15/16/18; the reader's `rg0_d..rg3_d` and `tools/trick_splice.py` `RUNG_*`/`TIER_S`).
- vobu_sri offers 0.5–7.5 s in 0.5 s steps, 10, 30, 60, 120 s, so one jump per picture tops
  out at 480×. 15 s does not exist, so tier 1 is 40× (old scrub: 60).
- Rejected: two chained jumps per picture for 960× (more reader logic at 97 % ALM); keeping a
  2× first tier (the maintainer chose the scrub-like ladder).
- The fallback is unchanged: a rung that is END_OF_CELL steps down through the shorter tier
  rungs, then next/prev_vobu. The 120 s rung was valid 44 % (fwd) / 59 % (bwd) in the sweep,
  so the top tier often lands on a 30 s jump near cell ends.
- ⏳ The physical drive's seek for a 120 s jump is longer than for 30 s; HIL to confirm the
  drive still holds ~4 pictures/s at the top tier.

## Second hardware round: the cell-end crawl and the clock jump-back (2026-11-24)

The maintainer, on the raised ladder: the HUD clock "goes up then jumps back to a lower
number" during a hold, more on the physical drive than on a NAS image, and it still felt
slow. **Instrument:** `mister.py snap` returns in ~0.22 s and carries the HUD clock
(`eltm` = `whole_eltm_w`), `disp_secs` and the demux's `nv_pck_lbn`, so a hold is sampled at
~4 Hz (screenshots now take ~5 s). There is no trick-play telemetry word.

- **The crawl (image and drive).** The Matrix image, FF 12 s: 16x was +4 s per 0.25 s as
  designed, but 0.5-1.5 s at a time the clock moved +0/+1 per sample: ~2.5 s of the 12 s.
  Cell ends: inside a cell's last few seconds every rung is END_OF_CELL, and the walk fell
  back to next_vobu, one VOBU (~0.5 s) per picture to the cell's end. Harmless with the old
  0.5 s shortest rung; ~2 s per cell end with 4 s. **Fix:** the adjacent VOBU only when the
  shortest rung is 0 (no SRI authored); END_OF_CELL there crosses to the next cell
  (`tk_e0`, `walk_cells`; `run_trick_reader.sh` R8).
- **The jump-back (drive >> image).** TFA from the drive, FF 12 s: five samples read a whole
  cell ahead with an UNCHANGED NAV sector (1:41 -> 3:15 -> 1:42, +94 / -93 s). The HUD clock
  was `cur_cell_start` (reader-timed: the cell it streams NOW) + `dsi_c_eltm` (demux-timed:
  the last NAV pack parsed). At a crossing the reader moves first; until the new cell's
  first NAV pack reaches the demux the clock read new start + old elapsed. A drive seek
  makes that window ~0.1-0.2 s, a NAS image's much shorter. Normal play has the same race
  for as long as the reader leads the demux, which is why nobody saw it. **Fix:** `emu.sv`
  latches the pair together at `dsi_commit` (`hud_cs_l`, `hud_eltm_l`, dropped by
  `pipe_rst_n`; before the first NAV pack after a flush the start follows the reader as
  before). Gated by `check_trick_wiring.py` R19-R21. `vm_snap`'s `eltm` and `seek_time`'s
  live time read the same clock and get the consistent pair too.
- The top tier on TFA: +120 s jumps did fire (two samples of +120), and a 12 s hold
  travelled 25 s -> 8:11 (~466 s) against the Matrix image's 22:42 -> 32:01 (~560 s).
- **Re-measured on `dev-trickplay3`:** TFA from the drive, no jump-back in the hold, 0:26 ->
  9:08 in 12 s (was 0:25 -> 8:11). The one dip after release (9:18 -> 9:08) is the exit
  seek to the picture on screen (the walk had read one more VOBU), by design. The Matrix
  image: no jump-back, but the 40x/120x tiers still sat at +3/+4 s for several pictures.
- **So the rule was wrong one level up too:** END_OF_CELL on ANY rung stepped down to the
  next shorter one, and the walk crept to the cell's end in 4 s steps. **Rule now: the
  tier's own rung decides.** A usable offset in the cell is the jump; END_OF_CELL (or a
  target outside the cell) crosses now, skipping less than one jump; only a rung the disc
  left 0 falls through to a shorter one, and an all-zero table to next/prev_vobu.
  `tk_c3..tk_c0` in the reader, `walk_cells` in the model, `run_trick_reader.sh` R8.
- **The PGC's edge lands on its boundary VOBU** (the cell's first going back, `cf_rd`; its
  last going forward, `lv_rd`) and then holds (R9). Crossing on END_OF_CELL would
  otherwise stop up to one jump short of the edge: a rewind to the start ending ~2 min in
  at 480x.

- **Re-measured on `dev-trickplay4`:** TFA from the drive, FF 12 s: 0:26 -> 16:44 (was
  9:08), 120 s jumps firing, no jump-back. REW 14 s from 16:12 reached the PGC's first
  cell but resumed at 0:07 (sector 1339, cell 1's LAST VOBU), not 0:00. The reader was
  right (`iso_reader_trick_tb` on the TFA image: 116429 -> 115707 -> 1339 -> 0, edge at
  0). **The controller was not:** the reader arms the edge VOBU and raises `trick_edge` in
  the same clock, and `trick_ctrl` exited on `nav_last` before that arm updated it. Same
  off-by-one for a release landing on an arm's clock (`nav_prev`). Fix: the exit reads
  `ex_last`/`ex_prev`/`ex_n`, the registers with this clock's arm applied
  (`trick_ctrl_tb` [10]/[11], `run_trick_ctrl.sh` M8/M9). On MIB3 in round 1 it looked
  right only because the edge VOBU there was one VOBU from the start.
- **Confirmed on `dev-trickplay5`** (TFA, drive): REW 13 s from 6:12 lands on 0:00 (first
  picture shown 0:00, sector 105) and plays on while still held, no re-entry.
- Seen in passing, the angle walk (still ⏳): TFA's opening crawl is two 3-angle blocks
  (cells 2-4 and 5-7). Rewinding through them the walk steps sibling to sibling (cell 6 ->
  3 -> 2 -> 1) rather than skipping the block: `tk_prev_base` is `block_first` only
  while `angle_active`, and a trick crossing clears it. Harmless here (each sibling is
  one picture), but a walk inside an angle block is not designed yet.

- **Progress bar (maintainer: "why is there no progress bar when scrubbing?").** The
  wiring kept the seek bar's SCRUB mode off (its base/target are scrub_ctrl's and stale in
  trick play) and never turned on its LIVE mode. Now `seek_bar .force_show` includes
  `trick_active`: with `bar_active` low the bar fills from `cur_rbn` = `dsi_nv_pck_lbn`
  (each trick picture's VOBU) with chapter notches and no cursor
  (`check_trick_wiring.py` R22).

## Maintainer review and three follow-ups (2026-11-24)

The maintainer tried `dev-trickplay5` hands-on: "this looks good with both a physical disc
and iso image", apart from the missing progress bar (above). Then decided:

- **A gamepad tap jumps 10 s** ("quick tap should nudge 10s like the other modes").
  `dvd/pad_hold.sv`: B10/B11 released before 400 ms = one `tap_*` pulse at the release,
  routed to `dpad_seek` while trick play claims the buttons (`pad_*_jump = trick_claim &
  pad_*_tap`); down for 400 ms = `held_*` to `trick_ctrl`. No bridge (the pad is a level,
  never repeats); the other button joining aborts the run. One shared 24-bit counter.
  Where trick play does not claim the buttons the raw levels still drive `scrub_ctrl`.
  Gates: `run_pad_hold.sh --red` (M1-M4), `check_trick_wiring.py` R23-R25.
- **The field-parity corrector is off in trick play.** Every new trick picture is an
  alternation break, so the pickup arm slipped a field on nearly each one and
  `par_late_r` pulsed `frame_late` (the `lates` ticking in round 1, 0 drops). `trick_cad`
  (already in `clk_dec` for `disp_sched`) now reaches `dvd/resample_addrgen.v` through
  `rtl/mpeg2/resample.v`, and gates `par_ins` and `par_hold_ins`. The counters keep
  watching, so the corrector acts normally after the exit seek. Every bench instantiating
  `resample`/`resample_addrgen` ties it off. Gate: `field_phase_tb` [T-trick] (the [2]/[4]
  break seeks and an [8] misaligned hold under `trick_cad`: triggers seen, 0 insertions,
  0 late pulses) and [T-after] (the corrector heals again); `run_field_phase.sh --red`
  T1/T2.
- **An OSD option, `Trick Play` On/Off** (`O[30]`, Playback page): "users might not want
  to seek so often on a physical disc". Off clears `trick_allowed`, so a held FF/REW
  scrubs as before (one seek on release), keyboard/remote taps jump 10 s on the press,
  and a pad tap nudges the scrub. Bit 30 was never allocated (checked in both CONF_STR
  syntaxes), so no saved config carries a stale 1 and no `"v,N"` bump. On is index 0.
  `check_trick_wiring.py` R26; manual: settings + controls.
- **Angle blocks:** Castle in the Sky's film has three 2-angle blocks (0:00 12 s, 3:52
  99 s, 121:07 184 s). Backward entry lands on the block's last sibling without an angle
  resolve and walks both siblings; forward entry resolves. ⏳ Next: enter a block
  backwards at `block_first + angle - 1` and skip the siblings; check forward jumps
  inside an interleaved block on Castle in the bench.

## Third hardware round: `dev-trickplay6` (2026-11-25)

SEED 9 fit: clk_dec 89.34 / clk_mem 92.46 MHz worst corner, `clock_check` PASS. TFA from
the share, keyboard keys through the harness (it has no gamepad):

- **Lates during a hold: 0.** A 10 s FF hold walked the whole ladder (4 → 10 → 30 → 120 s
  rungs, HUD 14:53 → 31:47, never backwards) with no late and no drop until the release.
  `dev-trickplay2` counted ~20-30 lates over the same hold (`fwd1`/`ifwd1`/`pfwd1`), so
  the corrector was where they came from.
- **The release costs 2-3 lates and at most one drop**, the same as an ordinary 10 s jump
  measured right after (1-3 lates per jump): it is the landing seek, not trick play.
- **Progress bar** up for the whole gesture, beside the arrows.
- **Keyboard tap**: FF +10 s, REW −10 s, exactly.
- **Trick Play = Off** with the keyboard: a hold is one 10 s jump at the press, then normal
  play. That is the pre-trick-play keyboard behaviour (FF/REW keys never reached
  `scrub_ctrl`; `joy_eff` masks them), and the manual now says so; the gamepad scrubs.
- ⏳ Not measurable here: the gamepad tap and the gamepad's scrub with Off (maintainer).

## Trick pictures are field stills (maintainer, 2026-11-25)

Maintainer on `dev-trickplay6`: "the held images during trick play look like they have a
similar issue we used to have with paused video where it flickers between fields". Each
trick picture is held ~15 refreshes, and on the interlaced raster the persistence loop
re-scans its two fields alternately -- the pre-2026-09-18 pause flicker, because the pause
field still (`still_want`, `dvd/resample_addrgen.v`) engaged only on `pause`. Now
`still_want` takes `(pause || trick_cad)`: the pin carries across pickups as it does
across frame steps, so the walk shows one field of each picture, steady; film pictures
keep their weave (`cur_ilace`). `trick_cad` drops at the release, the lock with it.

Gate: `run_pause_still.sh --red` gains `trick_pin_top`/`_bottom`/`trick_film` (+trick=1:
trick_cad, not pause, holds; the next picture is an ordinary pickup) and M9 (the trick term
dropped): M9 scores 4/8 still scans, the alternation the maintainer saw. Every other bench
ties `still_en` or `trick_cad` off, so nothing else moves.

⚠ The progressive raster is not this path: Weave shows a trick picture combed but static,
and Bob keeps the first field on the pickup scan and the second after, so a held picture
shifts once, half a line, as it lands.

## Angle blocks: the walk stays in its angle; a backward entry now picks it (2026-11-25)

**The measurement (the open question "whether `fwda` stays inside the playing angle").**
Every VOBU on every angle's chain of every angle block in the feature title set, on the 41
library discs that have one (104,789 VOBUs; Castle in the Sky, TFA's crawl, Grave of the
Fireflies, Beauty and the Beast ...): of the four trick rungs in each direction, 599,255
usable entries land on a NAV pack of the SAME angle (`vobu_vob_idn`/`vobu_c_idn` equal), 0 on
a sibling angle, 0 outside the block. A jump that would leave the angle is authored
END_OF_CELL (239,038 entries), which crosses. 19 targets that are not NAV packs and 28 broken
`next_vobu` chains sit on two discs (Closer, Beauty and the Beast) and are disc faults, not
sibling landings. So a walk inside a block needed nothing.

**Seamless-branch cells too** (interleaved, block_type 0: the Matrix's white-rabbit scenes,
T2's extended cut). The same sweep over every such cell's `next_vobu` chain, 30 discs,
133,863 VOBUs: 717,252 usable rungs land on the cell's own branch (`vobu_vob_idn`), 0 on the
other branch, 0 outside the cell; 353,622 are END_OF_CELL. One disc (The Internship) has 30
non-NAV targets and 5 broken chains. The reader needs nothing for these: a branch cell is
one cell in play order, and its rungs never leave its branch.

**The bug was the backward entry.** A backward crossing loads the cell before the one it
leaves; for a block that is its LAST angle (block_mode 3). The angle pick runs only on a
block's FIRST cell, so the reader streamed the last sibling with `angle_active` low, and its
next backward crossing stepped to the sibling before it (TFA's crawl: cell 6 -> 3 -> 2 -> 1,
one copy of the segment per angle). Forward entry always resolved: it lands on the first cell.

**The fix** (`dvd/dvd_iso_reader.sv`, S_CELL_LOAD2 "TRICK PLAY, BACKWARDS INTO AN ANGLE
BLOCK"): with `trick_lv` set and an angle cell that is not the block's first and not yet
resolved, step `cell_i` back one cell per S_CELL_LOAD pass (the cell table's read latency;
the 6-bit state space has no free code) until the first cell, where the normal scan and pick
run. `trick_lv` survives, so the chosen angle's cell lands on its last VOBU with
`angle_active` set; its next backward crossing then leaves from `block_first`, skipping the
siblings. A malformed block (no block_mode 1) ends the walk on the title path; cell 0 bounds
it.

**Gate:** `run_trick_reader.sh --red` gains three arms on Castle in the Sky's last block
(cells 33-34, 2 angles, 184 s): `ab1`/`ab2` backward at 10 s from cell 35 with angle 1 / 2,
`af2` forward on angle 2 through the earlier block (cells 4-5, 99 s; the control). The checker's model
(`trick_reader_check.py play_order`) collapses each block to the chosen angle, read from the
cell category bytes the bench now logs; `+ANGLE=n` drives `agl_vm`/`agl_vm_en`. R10 (the walk
removed) must fail `ab1`. Without Castle (`TRICK_ANGLE_ISO`, else `CASTLE_IN_THE_SKY*.iso`
under `DVD_ISO_DIR`) the arms SKIP and the verdict line says so.

**On the rig (2026-11-26, `dev-trickplay8`, .236, TFA image, Disc Menus Off):** the nav event
FIFO's CELL events (`/tmp/dvd_navtrace.jsonl`, 90 kHz `free` stamps), REW held through the
crawl from the film (cell 8, 0-based):
- angle 1: `8 -> 7 -> 6,5,4 -> 3,2,1 -> 0`, then play from the edge `-> 1`. Each `x,y,z` run
  has one timestamp: that is the walk to `block_first` (no sector read), then the pick lands
  on angle 1. One picture per block (~0.25 s apart), all the English crawl.
- angle 2 (Angle key in the crawl; angle 2 is the French crawl): `8 -> 7 -> 6,5,4 -> 5 ->
  3,2,1 -> 2 -> 0`, then `-> 1 -> 2` playing on. The picks land on cells 5 and 2, angle 2's
  copies; no sibling is visited. On `dev-trickplay5` the same rewind stepped 6 -> 3 -> 2 -> 1.
- A rewind started inside the block on angle 2 left from `block_first` straight to cell 0,
  showing only French pictures.

1. The maintainer's hands-on: gamepad tap, gamepad hold, Trick Play = Off on the pad, and
   the field still on the interlaced raster.
2. ~~Angle blocks on the rig~~ done 2026-11-26 (above): TFA both angles. Castle on the rig
   is optional; its blocks are covered by the bench arms.
3. The fit's ALM margin (97 %): a seed sweep, or trimming `kbd_hold`'s counters.

Earlier plan, kept for reference: a hardware round on the rig:
an image and the physical drive, both directions, every tier, the edge both ways, release
landing on the picture on screen, audio back after release, a disc with angle blocks.
