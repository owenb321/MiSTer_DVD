# Trick play (continuous fast-forward / rewind)

Status: 🔧 design + offline model (`feature/trick-play`, 2026-11-22). Nothing in RTL yet.
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

**Proposed (awaiting the maintainer):** a fixed display cadence of one I-frame every T ms,
T from the drive's p90 for a typical frame, with image reads gated to the same cadence.
Decision 4 then holds by construction: the only difference left is that a late physical read
holds the previous frame a little longer. A tier's speed is its jump ÷ T; at T = 250 ms the
jumps 0.5 / 1 / 2 / 10 / 30 / 60 / 120 s give 2× / 4× / 8× / 40× / 120× / 240× / 480×.

## Open questions

- Cell and PGC edges: `fwda` returns END_OF_CELL near a cell end; the next cell's first VOBU
  must come from the PGC, without running cell commands. At the PGC end, drop to normal play
  so POST runs.
- Angle blocks and seamless-branch ILVUs: whether `fwda` stays inside the playing angle.
- Entering: title domain only, playing, no buttons armed, no still.
- `.mpg` and VCD have no nav packs: out of scope (they keep scrub-to-target).

## Next step

The maintainer picks the cadence T and the tier set; then the offline splice model (build the I-frame stream from an ISO with the ES filter, decode it with ffmpeg and the bit-exact cosim).
