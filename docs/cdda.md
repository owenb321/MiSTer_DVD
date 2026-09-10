# WAV / CD-DA playback (raw-PCM path)

Engineering note for `feature/wav-audio` (branch 1 of the music-CD work). The
user-facing text lives in `site/content/getting-started/loading.md` and
`site/content/audio/formats.md` — this file is the *why*.

**Status: ✅ HW-CONFIRMED 2026-09-10** (build
`DVD_wavaudio_20260910_1900.rbf`, SEED 7, clk_dec 87.61/88.42 at 98% ALM).** Branch 2
(`feature/cdda-physical`, the physical audio-CD source in `MiSTer_DVDcss`) is
NOT started; this branch deliberately ships the whole core-side path first so
that branch adds only a Main-side sector source on top of a HW-proven fabric.

## Why this exists, and why WAV came first

Standalone DVD players played audio CDs — it is why the "DVD/CD changer" was a
product category. The custom Main already sees an audio CD on every poll tick
and deliberately skips it (`main/support/dvd/dvd_phys.cpp`, the
`if (!is_dvd_video) return;`), so a user who inserts one gets the idle logo and
no explanation.

The work splits cleanly in two, and the split is the point:

* **Core side** — a raw-PCM playback mode that bypasses `ps_demux` and every
  codec. Testable in sim and on hardware *with a plain file*, no Main needed.
* **Main side** — TOC read + `READ CD` (0xBE) audio sectors served over the
  existing block interface.

So branch 1 is `.wav` support, which is a real user-facing feature on its own
AND is the entire core half of CD-DA. **The physical disc will present to the
core as one giant WAV**: the Main prepends a synthetic 44-byte canonical header
to the deblocked audio stream, and the probe below handles it identically. That
decision is what keeps the core at ONE new mode instead of two, and it costs no
signalling — no `cfg[15]` (the last free config bit stays free), no fork of the
`hps_io` mount word. 44 is divisible by 4, so 2048-byte blocks stay L/R-pair
aligned.

⛔ **Image files (bin/cue, CHD) were considered and rejected** (user decision).
ISO9660 cannot hold CD-DA, so it would mean parsing `.cue` sheets — and nobody
archives music that way. The barrier is low if this is ever revisited: stock
Main's `cd.h` `toc_t`, `support/chd/mister_chd.*` and any core's ~150-line
`load_cue()` would drop into our Main and serve the SAME byte stream this core
already plays, with zero RTL change.

## Probe (`dvd_iso_reader.sv`, `S_WAV_HDR`)

`riff_wave` sits beside the existing `riff_cdxa` comparator (both are RIFF; the
form tag at offset 8 disambiguates, and CDXA is tested first). On a hit the
reader chunk-walks **sector 0**, which the byte-0 probe has already left
resident in `parse_buf`:

* from offset 12, each record is `<ckid:4><cksize:4 LE>`, advancing
  `8 + cksize + (cksize & 1)` — the RIFF **pad rule**, which a fixed-44-byte
  assumption gets wrong on any file ffmpeg wrote with metadata;
* `fmt ` captures {format, channels, rate, bits}; `data` captures the payload
  offset/length and ends the walk;
* **accept** = PCM(1) / 2 ch / 16-bit / 44100 or 48000 Hz.

⚠ **A record may only START at offset ≤ 2002.** Each record is read through the
45-byte `rbuf` shadow, which must not cross out of the resident sector — a
cross-refill would swap `parse_buf` mid-walk. The golden model enforces the same
bound, so "data chunk beyond sector 0" is a defined reject, not a lucky escape.

Anything else sets `wav_bad`, which emu turns into `UNSUPPORTED IMAGE`
**immediately** — bypassing the 20-second `img_wd_cnt` patience, because the
header *states* the format and the alternative is playing noise.

⚠ **`S_INIT` no longer skips the byte-0 probe for small files.** It used to jump
straight to the flat fallback under 17 blocks (too small for an ISO PVD), but a
tiny `.wav` is perfectly legal. Small files now probe block 0 and fall back from
`S_CHK_RAW` instead of reading a nonexistent LBA 16. Covered by
`wav_probe_tb` TEST 6b.

## Streaming and the pair-phase invariant

Playback reuses the linear whole-file path (single extent, sequential `sd_lba`)
with a **keep filter on the cache write side**, exactly like the raw-2352
deblocker — and sharing its `raw_wcnt` compaction counter, since the two modes
are mutually exclusive. A byte is kept iff its absolute file position lies in
`[cdda_astart, wav_dend)`, so the header, any trailing chunks (`id3`, `LIST`)
and a trailing partial sample pair never reach the decoder.

★ **The payload END needs two guards, and both were RED-proven against the
first cut of this RTL.** `wav_dend` is computed in 35-bit arithmetic, clamped to
EOF, then truncated to a whole pair *relative to the payload start*:

* a **streaming** writer emits `cksize = 0xFFFFFFFF` because the length is not
  known when the header is written. A bare 32-bit `off + 8 + cksize` **wraps** —
  measured `wav_dend = 40` for a data record at offset 36 — so the file played
  **nothing at all**.
* a **truncated / over-claiming** file (a part-copied download) ran past EOF into
  the framework's block padding: measured **852 bytes of 0xEE emitted as audio**,
  ~5 ms of buzz at the end of the file.

Fixtures `streaming.wav` and `truncated.wav` cover both; against the pre-fix
reader they read `cap_n=0 (expect 2800)` and `cap_n=4052 (expect 3200)`.

★ **`cdda_astart` is what makes seeks safe.** On a linear seek to block *B* it is
recomputed as the first byte ≥ *B*×2048 that is **L/R-pair aligned relative to
the data offset** (`bpos ≡ wav_doff mod 4`). Land one byte off and left/right
swap for the rest of playback — a defect that is obvious on headphones and
invisible in a spectrum. `listchunk.wav` exists as a fixture precisely because
its `data_off` is 90 (≡ 2 mod 4), so the naive "resume at the block boundary"
answer is wrong there and right on every canonical 44-byte file.

⚠ Two linear-path traps this mode had to opt out of, both inherited:

* the **flat-PS pack hunt** (`hunt_active`) drops bytes after a seek until
  `00 00 01 BA`. On PCM that never arrives — it would eat the rest of the file.
* `lin_seek_ok_o` required `raw_mode || flat_seek_en`, and `flat_seek_en` means
  "ps_demux saw a pack", which never happens here. Without a `cdda_mode` term
  the transport UI stays dead.

## Audio path — riding LPCM, not a fifth codec

`aud_type` is 2 bits and all four codes are taken (AC3/DTS/LPCM/MP2); widening
it would ripple through ps_demux, audio_ring and the descriptor FIFO to buy
nothing, because CD-DA has no PES framing, no PTS and does not want the dispatch
FSM. Instead `cdda_mode` takes `lpcm_unpack` over wholesale:

| | DVD LPCM | CD-DA / WAV |
|---|---|---|
| bytes from | dispatch FSM (`consume`) | reader `stream_data` direct |
| byte order | big-endian | **little-endian** (new `le` input) |
| `quant` | ps_demux sub-header | forced 0 (plain 16-bit) |
| rate | 48 kHz | `cdda_fs` → NCO (44.1/48) |
| flush | — | `aud_flush` resets assembler + FIFO |

`cdda_mode=0` is bit-identical to before (proven by the unchanged
`lpcm_unpack_tb` / `dvd_audio_decode_tb` / VCD suite). The mode also forces
`sched_en` low (no PTS to schedule against — the drain gate would only ever
release via its ~2.5 s fallback timer) and forces `pass_mode` **off**.

⚠⚠ **That last one now has the OPPOSITE reasoning from the one it was written
with, and it matters.** When this branch was parked, Passthru meant bitstream-only
and forcing it off simply avoided handing the ring to `iec61937_wrap`. Since
PR #79 Passthru is per-frame: `aud_route` classifies each RING frame and sends
LPCM/MP2 to the decoder as ordinary PCM. CD-DA/WAV never enters the ring at all,
so no frame ever arrives to classify — `rt_pcm_session` would sit at its reset
value 0 for the entire session and
`pcm_mute = (pass_mode & ~rt_pcm_session) | …` would **mute a `.wav` outright in
Passthru**. Forcing `pass_mode` off is how a ring-bypassing source reaches the
same answer PR #79 gives an LPCM track: `af_passthru` then tells Main to put the
ADV7513 in PCM mode, and `SPDIF_PASS_EN`/`HDMI_BS_EN` drop so both legs carry
plain PCM. **HW gate: play a `.wav` with `Audio Out = Passthru`.**

Backpressure composes with no new mechanism: `lpcm_unpack.afull` → `reader_busy`
→ cache fills → `cache_has_room` false → `sd_rd` stops. In this mode
`reader_busy` is *only* that tap; the video-side terms reference a pipeline the
mode never feeds.

## Time readout — `dvd/lin_rate.sv`, not a module of our own

★ **The branch shipped its own `dvd/cdda_time.sv` and the rebase DELETED it.**
While this work was parked, `main` grew `dvd/lin_rate.sv`: one time model shared
by every linear source, with an exact combinational bypass for raw VCD/SVCD and
a measured-PTS path for flat `.mpg`/`.VOB`. CD-DA is the same shape as the
raw-CD arm — a fixed geometry — so it became a **second fixed-rate arm of that
bypass** instead of a parallel module.

Three things fell out for free: the HUD elapsed/total clock, the **seek-preview**
clock (the number tracks the bar's cursor during a gesture instead of freezing),
and a **48 kHz D-pad step that is now exact**. The parked branch had reused the
44.1 kHz constant 861 for both rates — about 8.6 % short at 48 kHz — and had
shipped that as a documented limitation; `lin_rate` carries `BLK10_441 = 861`
and `BLK10_48 = 938` and picks on `cdda_fs`.

⚠ **The bypass is not an optimisation, it is required.** A PCM source carries no
PTS at all, so `lin_rate`'s measurement window can never close on one. Gating the
D-pad on a *measured* rate (which is what `main`'s `lin_mode_w && lin_blk10_ok_w`
does) would leave the D-pad permanently inert and the clock at `0:00:00` on every
`.wav` and every audio CD.

★ The general lesson for the next parked branch: **rebasing is a chance to delete
your own code.** The question to ask of every module the branch added is not "does
it still apply cleanly" but "did `main` grow the right home for this while I was
away".

## Screen

There is no video, so the **idle logo keeps bouncing** (`logo_vis` gains a
`cdda_mode` term — `media_seen`/`img_streaming` would otherwise hide it the
moment blocks start arriving), the **HUD status line is forced on** for the
session, and so is the **seek bar, acting as a progress bar**. Both got the same
one-line treatment: a `force_show` level input ORed into their existing `vis`
expression, still yielding to `menu_active` so neither can fight the HLI layer.

★ The progress bar needed **no position work at all**. `seek_bar` resolves
`cur_rbn` against `title_first_rbn..title_last_rbn`, and the reader already
publishes the whole file as the title span in linear mode while `cur_rbn` is
already `lin_blk` there — so the bar was correct the moment it was allowed to
draw. Chapter notches come from `nr_pgm`, which is 0 for a WAV, so it renders as
a plain progress bar rather than a chaptered one. That is why this was cheap:
the ask was for a *display* change, and every input it needed was already right.

Both composite through the existing register stage; the raster free-runs black
underneath, so this costs nothing in the display hotspot.

## Tests

`bench/dvd/run_wav.sh` — golden model `tools/wav_ref.py` generates fixtures and
PCM goldens into the gitignored `bench/dvd/test_wav/` (synthetic, deterministic
xorshift32 PCM: no float/libm variance, nothing large committed).

* `wav_probe_tb` — 4 accepts byte-exact through the REAL reader, all 5 reject
  shapes refused with **zero bytes out**, flat large/small regressions, and the
  seek pair-phase check on `listchunk`.
* `cdda_audio_tb` — end-to-end reader → `dvd_audio_decode` → `AUDIO_L/R`, PCM
  **bit-exact** vs the golden; 44.1/48 kHz NCO cadence measured (612.24 /
  562.50 cycles per pair); pause continuity; post-seek channel-swap guard; the
  **RED-first `le` proof** (the same bytes with `le=0` must NOT match, so the
  test cannot pass by accident).
* `lin_rate_tb` TEST 14 — the fixed-rate arm: 861 at 44.1 kHz and **938** at
  48 kHz with **no PTS ever presented**, plus the clock arming off the same
  edge. Presenting no PTS is the point: it is what the measured path cannot do.
* `seek_bar_tb` T10 — the progress bar: hidden with nothing asserted, up on
  `force_show` alone, fill tracking the playhead, and still yielding to a menu.
* Regressions in the same script: `lpcm_unpack`, `dvd_audio_decode`,
  `transport_hud`, `hud_frame`, and the whole VCD/MP2 suite.

⚠ TB gotcha worth remembering: the bare-unpacker rig first "failed" because it
set a byte and *then* waited for the edge, racing the DUT's own `always_ff` at
that timestep — bytes silently duplicated. Drive after the edge (`@(posedge);
#1;`).

## HW gate (branch 1) — ✅ RUN 2026-09-10, all green

Driven from here over the HIL harness rather than handed to the maintainer, with
purpose-built material (`tools/wav_testgen.py`): a chromatic ladder stepping one
semitone per 10 s, left and right an octave apart. Both choices are load-bearing
below.

| # | Gate | Result |
|---|---|---|
| 1 | 44.1 kHz plays; screen correct | ✅ logo + status line + progress bar all render; HUD reads `0:00:12/0:03:00` on a file that is exactly 180.0 s |
| 2 | 48 kHz rate constant | ✅ total reads **0:02:59** on the same 180.0 s file. **This is the sharp one:** with the parked branch's 861 it would read **0:03:16** |
| 3 | D-pad 10 s jump | ✅ at both rates (+10 s over the natural elapse, 44.1 kHz and 48 kHz) |
| 4 | Pause | ✅ icon flips and the clock FREEZES (`0:00:25` across 4 s) |
| 5 | Unsupported shape | ✅ mono → `UNSUPPORTED IMAGE` immediately, and NO status line (cdda_mode never engaged) |
| 6 | **`Audio Out = Passthru`** | ✅ **−15.3 dBFS flat across 20 windows**, indistinguishable from Decode PCM (−16.0) |
| 7 | DVD regression, same build | ✅ MEN_IN_BLACK plays clean video, and the HUD is correctly HIDDEN — proving `force_show` does not leak out of CD-DA mode |

★ **Gate 6's control arm is what makes it evidence.** "Audio is present" proves
nothing unless the instrument can report its absence, so `Audio=Off` was measured
on the same path: **−999.0 dBFS** (digital silence) across every window after the
capture buffer drained. ⚠ And the AGGREGATE was misleading — whole-capture RMS
read −36.9 dBFS with the peak unchanged, because the setting landed partway
through. The 0.25 s **envelope** is the instrument that answers cleanly; an
average over a transition does not.

⏳ Not covered by this round: VCD regression (sim-green only), and the
seek-preview clock during a held FF/REW gesture.

## Next (branch 2)

`main/support/dvd/dvd_cdda.cpp`: TOC via `CDROMREADTOCHDR`/`CDROMREADTOCENTRY`,
audio sectors via SG_IO `READ CD` (0xBE, `cdb[9]=0x10`, `cdb[1]=0x04`), repacked
2352→2048 behind the synthetic WAV header, served through the existing
`SD_TYPE_DVDCSS` hooks so `apply_integration.py` needs **zero** new steps. A
track table rides the generic ioctl-download channel (the PSX `disk_t`
precedent) to a new `dvd/cdda_toc.sv`, feeding tracks-as-chapters and the
seek-bar notches. **Run an SG_IO smoke test on the board before writing any of
it** — that 0xBE audio reads work on the user's drive is the one real unknown.
