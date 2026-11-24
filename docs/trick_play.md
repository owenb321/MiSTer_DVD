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
120×** (jumps of 0.5, 2, 10 and 30 s; valid 98 / 90 / 71 / 66 % of the time in the sweep, the
rest falling back to a shorter jump). The mechanism: a fixed display cadence of one I-frame every T ms,
T from the drive's p90 for a typical frame, with image reads gated to the same cadence.
Decision 4 then holds by construction: the only difference left is that a late physical read
holds the previous frame a little longer. A tier's speed is its jump ÷ T; at T = 250 ms the
jumps 0.5 / 1 / 2 / 10 / 30 / 60 / 120 s give 2× / 4× / 8× / 40× / 120× / 240× / 480×.

## Open questions

- The PGC's edges: at the last cell going forward, drop to normal play so POST runs; at the
  first cell going back, stop at its first VOBU and resume there.
- Angle blocks and seamless-branch ILVUs: whether `fwda` stays inside the playing angle.
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
- **Target:** the tier's rung, then each shorter tier rung, then `next_vobu`/`prev_vobu`.
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
- **Not handled yet:** angle blocks beyond the play-order step (a crossing uses
  `cell_after` and `block_first - 1`, so it steps over an angle block as one cell, but a
  walk inside one follows `fwda` and may leave the chosen angle). Measuring that is the
  ILVU open question above.

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

## Next step

A hardware round on the rig:
an image and the physical drive, both directions, every tier, the edge both ways, release
landing on the picture on screen, audio back after release, a disc with angle blocks.
