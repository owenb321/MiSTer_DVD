# WAV / CD-DA playback (raw-PCM path)

Engineering note for `feature/wav-audio` (branch 1 of the music-CD work). The
user-facing text lives in `site/content/getting-started/loading.md` and
`site/content/audio/formats.md` — this file is the *why*.

**Status: ✅ BOTH BRANCHES HW-CONFIRMED.** Branch 1 (`feature/wav-audio`, the
core-side raw-PCM path) 2026-09-10. Branch 2 (`feature/cdda-physical`, the
physical audio-CD source in `MiSTer_DVDcss`) 2026-09-10 for the first build and
**2026-09-22 on the post-v0.6.1 REBASE**, which ran the full gate list including
the one that had never been run — see "HW gate (branch 3)" below.
⚠ The sentence that stood here said branch 2 was "NOT started". It was written
when that was true and never flipped; it is exactly the stale marker CLAUDE.md
calls a documentation bug.

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

✅ **`.cue` sheets were ADDED 2026-09-25 (branch `feature/cue-sheets`), reversing an
earlier rejection** — see "`.cue` sheets" below. The rejection (user decision) read:
*"ISO9660 cannot hold CD-DA, so it would mean parsing `.cue` sheets — and nobody
archives music that way."* The prediction beside it held exactly: the Main serves
the SAME byte stream this core already plays, with zero RTL change. ⛔ **CHD is still
not supported** — it would need libchdr in the overlay, which has stayed
dependency-free.

## `.cue` sheets (Main-only, `main/support/dvd/dvd_cue.{h,cpp}`)

The core never sees a file's extension, so a `.cue` is handled entirely in the
Main by building one of the two streams the core already plays. The only fabric
touch is `CUE` in `CONF_STR`'s `S0` list (0 ALMs; it re-rolls the seed like any
`CONF_STR` edit, which every branch's `dev-<slug>` already does).

* **Audio CD** → exactly the physical disc's virtual WAV. `dvd_cdda.cpp` gained a
  second source (`dvd_cdda_open_source()`, a frame-reader callback where the drive's
  `read_frames()` was), so the header, the 2352→2048 repack, the track-edge burst
  split and the `CDTC` blob are all the SAME code the physical path uses. It rides
  `dvd_css`'s CD-DA front door (`dvd_css_open_cdda_source()`), so the slot is
  `SD_TYPE_DVDCSS` and the read path, read-ahead and close needed no new step.
* **Video CD / SVCD** → the physical VCD's raw span, through
  `dvd_vcd_open_source()` (`SD_TYPE_VCD`). A Mode 2 first track is a VCD; the span
  is the consecutive Mode 2 tracks, which is `dvd_vcd_open()`'s rule. This also
  fixes two things the bare `.bin` cannot: a hybrid single-bin's CD-DA tail is left
  out (the core would otherwise stream it, and ~1 random PCM sector in 512 passes
  the Form-2 test), and a `MODE2/2336` rip gets its 16-byte sync+header put back.
* **Track geometry is the physical TOC's**: a track starts at INDEX 01, and the next
  track's INDEX 00 pregap plays at the END of the track before. The first audio
  track's pregap is not served. INDEX 02+ move nothing; PREGAP/POSTGAP are silence
  not in the file. EAC's "gaps appended" layout (INDEX 00 at the tail of the
  previous FILE) and one-file-per-track both work, because every INDEX records the
  FILE it was written under and byte positions are carried forward per file (sector
  SIZES can differ between tracks of one file: MODE1/2048 then AUDIO).
* **FILE types**: BINARY, MOTOROLA (byte-swapped on the way out), WAVE (16-bit
  stereo 44.1 kHz PCM; the `data` chunk is located, odd-size chunks padded). MP3,
  FLAC, AIFF are refused.
* **Spec maxima**: 99 tracks, 99 FILEs; past either the sheet is refused with a
  reason, never truncated.
* **The track table** goes out on the first poll AFTER the mount
  (`dvd_cdda_toc_service()` from `dvd_css_tick()`): the core wipes it on every
  mount, and an OSD mount has no caller like `dvd_phys_tick` to send it afterwards.
  Any open leaves it pending; the upload clears it, so a physical disc still
  uploads once.
* **Refusals** are logged to `/tmp/dvd_cue.log` and shown as `Cannot play this
  CUE sheet` — except while an MGL launch is busy (`dvd_launch_ui_busy()`), where a
  notice would freeze the launch (issue #48).

⚠ **A stock-Main overflow came with it and is fixed by integration step 50.** The
file picker `strcpy`s a core's extension list into `static char fs_pFileExt[13]`.
Our list was already 24 characters; in the built object the bytes past the buffer
are `menu_visible`, `osd_unlocked` and `config_scale[0]` (a pointer, read only by
the Archie/ST/Amiga cores, and Main restarts at every core load — which is why it
was harmless). `CUE` makes it 27. Step 50 widens the buffer to 256, matching the
buffer it is copied from.

✅ **HW-measured 2026-09-25** (build `DVD_cue_20260926_0019.rbf`), and ✅ confirmed by the
maintainer loading a `.cue` from the OSD file picker. The control arm, the
pre-cue Main, mounts the sheet as a 225-byte text file and plays nothing. The new Main:
- a one-`.bin` tone disc and the same disc as EAC per-track `.wav` both read
  `TR 1/3` 0:00:32;
- track skips land on the right tone (440/660/880 Hz, measured off the capture card);
- the dinosaur VCD plays and seeks as split `.bin` and as a `MODE2/2336` conversion
  (total 0:34:34 = 155,529 sectors);
- a refused sheet ends on the idle logo without freezing its MGL launch.

On the host, both real VCD sheets in the local rips serve their files byte for byte, and
`QG0012` comes to 256,719 sectors, the same span the physical burned disc of that rip
measured on the rig.

Gates: `main/tests/dvd_cue_test.cpp` (parser + layout from text; real temporary
files mounted and read back through the REAL `dvd_cdda.cpp`, byte for byte; two file
layouts of one disc must produce one stream) and 12 mutations in
`main/tests/run_tests.sh --red`, each matched on its own `FAIL` line.

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

## Branch 2 progress — the Main-side source is WORKING on hardware

✅ **Step 0, the gate: 0xBE works on the maintainer's drive** (2026-09-10).
`main/tools/cdda_smoke.c` read the TOC (4 audio tracks, 42:19), pulled 750
frames in 8-sector bursts via READ CD, and the data validated as real audio
rather than something that merely passes a crude test: **97.2 % of frames have
L≠R** (so not a duplicated or mono-ised buffer), **750/750 sectors distinct** (so
not a stuck read), and the envelope runs −70 → −25 dBFS with 45 dB of range —
that first silent window being track 1's lead-in at LBA 37, exactly where it
belongs.

✅ **A physical CD auto-mounts and plays.** `DVD_PHYS: audio CD on /dev/sr0 --
mounting`, and the reported image size is **447891404 bytes — exact**:
44 + 190430 × 2352 for a 42:19 disc. The HUD reads `0:42:20` total (the
documented ≤1 s truncation) and the progress bar fills. Captured audio is
continuous at −27 dBFS on both channels with a varying envelope and **no dropout
windows**.

⚠ **A `CH 0/ 0` on screen was NOT a defect** and is worth recording because it
looked exactly like one. `dbg_mode` (O[2] Debug Overlay) forces the CH field
visible and repurposes it as `{reader PGCN, VTS}`, which on a CD is `0/0`; the
rig's saved config had it on. With it off the field hides as designed. Check the
saved OSD config before believing a HUD anomaly.

✅ **Tracks are in.** `dvd/cdda_toc.sv` receives the boundaries over the generic
ioctl-download channel and turns `lin_blk` back into "track 7 of 12". Everything
downstream reuses machinery that already existed, which is why it is small: track
skip rides `scrub_ctrl`'s pre-resolved jump port (`base` = the absolute track
start, `off` = 0, so the clamp/bar/preview come free), the chapter FSM's existing
debounce becomes the track burst, the track number reuses the HUD's CH field,
and track-relative time is two subtracts on `lin_rate`'s position inputs.
*(Superseded in part by the follow-up below: the field is now labelled `TR`, the
bar is per-track, and the notches are gone.)*

★ **And the bench for it found a real defect.** `cdda_toc`'s entry RAM is written
as bytes ARRIVE, so gating only the header fields at commit was not enough: a
malformed upload overwrote the track starts while leaving `toc_valid` set,
producing a table that passed every header check and pointed at the wrong blocks
— a track skip would have jumped somewhere random. The download START now
invalidates. Getting the bench to see that took two goes, both worth recording:
the first sent the SAME blob with one byte broken and asserted "unchanged",
which passes whether the upload is rejected *or* accepted; the second used an
alternate table whose "truncated" length happened to be exactly valid for the
ntracks it declared.

## HW gate (branch 2) — RUN 2026-09-10, track skip PROVEN, one item blocked

Build `DVD_cddaphys_20260910_2242.rbf` (SEED 9, clk_dec 90.72/88.04), a real
4-track music CD in the drive, `Debug Overlay = Off`.

| # | Gate | Result |
|---|---|---|
| 1 | CD auto-mounts while the core runs | ✅ `audio CD on /dev/sr0 -- mounting`, `slot 0 OK size=447891404` = **exactly** `44 + 190430x2352` |
| 2 | Plays, HUD reads the track | ✅ `[PLAY] 0:00:42/0:11:57 CH  1/ 4` |
| 3 | Clock is TRACK time, not disc time | ✅ total changed 11:57 -> 10:41 across a skip; disc is 42:19 |
| 4 | Next track | ✅ `CH 2/ 4`, clock reset |
| 5 | Prev, >3 s into a track | ✅ restarts the current track |
| 6 | Prev, <3 s into a track | ✅ steps to `CH 1/ 4` |
| 7 | Next on the LAST track | ⛔ **BLOCKED — the drive faulted**, see below |

★ **Gates 5 and 6 are one key producing two different outcomes purely as a
function of playhead position, which is the `skip_tgt` resolver's whole job**
(`(lin_blk - s_lo) > RESTART_BLK ? s_lo : s_prev`, `RESTART_BLK = 258` blocks
~= 3 s). Either result alone proves nothing — a resolver stuck on "restart"
passes gate 5, one stuck on "previous" passes gate 6.

⚠⚠ **AND GATE 6 CANNOT BE DRIVEN OVER SSH — the harness latency is longer than
the window it is testing.** Each `mister.py key` is a fresh ssh round trip
(~1-2 s), so two presses land 2-4 s apart, which is *outside* the 3 s restart
window: both presses restart, every time, and the previous-track arm never
fires. Measured — two ssh-driven presses left the playhead on track 2 twice,
and the identical pair driven **on the target** (`echo "keys 104" >
/tmp/mister_hil; sleep 1.2; echo "keys 104" > ...`) landed on track 1 first try.
★ Generalise it: **when a gate tests a time window, the harness's own latency is
part of the instrument** — an ssh-paced test of a 3 s rule is a bench that
cannot fail, and it would have been read as "the previous-track arm is broken".

### The blocked gate, and what it is NOT

The drive dropped the disc during gate 7 and never came back:

```
sr 0:0:0:0: [sr0] disc change detected.
sr 0:0:0:0: Power-on or device reset occurred
sr 0:0:0:0: [sr0] CDROM not ready yet.      (repeating)
usb 1-1.1: reset high-speed USB device number 9 using dwc2
```

⚠ **The escalation to a USB-level reset is what places this outside our code** —
that is the host re-enumerating the device, not a SCSI command being refused.
Same fault stopped an earlier attempt this session, and it reproduced with the
**MENU core** loaded. Suspect power; a powered hub is the next thing to try.

★ **The symptom it produced first was MISSING SCREENSHOTS, and that is worth
knowing because it reads like a core hang.** `mister.py shot` began failing with
"No such file or directory" while `state` still answered — Main was alive
(pid confirmed) but blocked in the `sr` retry loop, so `user_io_poll()` never
serviced `/dev/MiSTer_cmd`. This is the documented blocking-I/O coupling
(`CLAUDE.md`, MGL round three) arriving through a new symptom. **"Is the picture
frozen or is the machine frozen" does not separate these two** — ask instead
whether *Main's own command FIFO* is being serviced.

⛔ **Reading past the lead-out is NOT the cause** — checked directly rather than
assumed, because the timing invited it. `dvd_cdda_read()` refuses `b0 >= size`,
clamps and zero-fills `b1 > size`, breaks when `dvd_cdda_map_sector()` goes out
of range, and clamps every burst to `room` (the track edge), so no `READ CD`
is ever issued beyond the last audio sector.

## Branch 2 — BUILT (2026-09-10)

Shipped as described: TOC via `CDROMREADTOCHDR`/`CDROMREADTOCENTRY`, audio
sectors via SG_IO `READ CD` (0xBE, `cdb[1]=0x04`, `cdb[9]=0x10`) repacked
2352->2048 behind the synthetic WAV header, served through the existing
`SD_TYPE_DVDCSS` hooks so `apply_integration.py` needed **zero** new steps; the
track table rides the generic ioctl-download channel into `dvd/cdda_toc.sv`.
The SG_IO smoke test (`main/tools/cdda_smoke.c`) was run first and passed, which
is what let the rest be written as plumbing.

**Remaining:** gate 7 above (next on the last track) — **no longer blocked**: the
drive that dropped its disc mid-test was a POWER problem, not a faulty unit, and
was replaced with a lower-power one the MiSTer USB hub sustains (2026-09-12) — and
the fork's one-line `AUDIOCD=DVD` arm in `menu_audio_mgl()` (opt-in; not needed
for a disc inserted while our core is already running).

## Follow-up (`dev-cddaphys2`, 2026-09-10) — visualizers, a per-track bar, `TR`

Five user-requested changes after the first CD build. **Sim-green, ⏳ not yet run
on hardware.**

### Visualizers — `dvd/cdda_viz.sv`

A CD starts on the **bouncing logo**, and Angle switches to **copper bars** and
back (user decision 2026-09-12 — the visualizer is opt-in rather than something
to dismiss); an OSD Reset returns to the logo. Angle was free: the angle switch
acts only while `cell_ready`, which a CD never is. The mode register lives in
`dvd/cdda_screen.sv`, and
the visualizer shares `idle_logo`'s overlay slot — the two are mutually exclusive
by mode, and `cdda_viz` has the same three registered display stages and the same
`VIZ_QX_LEAD = 12`.

It reads ONE analysis: a peak envelope of `(|L|+|R|)` (instant attack at
~6.6 kHz, ~12 %/frame decay), a slow average of it, and a `kick` timer armed when
the envelope jumps well above the average.

★ **The budget is the design** — the core is at 98 % ALM:

- **No framebuffer.** Every pixel is a function of `(x, y)` and a few per-frame
  registers, so nothing scales with screen area.
- **Copper is per LINE, not per pixel.** On a `v_pos` change the three bars are
  tested serially — one comparator, four clocks, all inside the first dozen
  clocks of the line (the display lead hides them) — and the colour is held for
  the line. Bar positions are solved once per FRAME, also serially, with
  shift-add amplitude steps (×0.5 / 0.75 / 1 / 1.25 by loudness). No multiplier,
  no DSP block.
- **The oscillator is a TRIANGLE** (2026-09-12). The quarter-wave mirror was
  already there for the sine, so the magnitude is now a doubled ramp —
  `sq = {sq_i, 1'b0}`, a wire — instead of a 64-entry LUT. The bars bounce
  linearly instead of easing at the ends, which is the look that was asked for,
  and the table was the largest single cost in this file.
⛔ **Lissajous (L against R) was not built:** it needs a 2-D bitplane, and even a
small one costs several M10Ks.

### The scope was built, then dropped (`dev-cddaphys5`, 2026-09-11)

A third visualizer — a two-trace oscilloscope, L above R, triggered on L's rising
zero crossing — shipped in `dev-cddaphys2` through `dev-cddaphys4`. It worked. It
was removed at the user's request, to be conservative with logic.

**What it cost was measured, not estimated.** Synthesising `cdda_viz` alone with
`mode` tied to each constant, so Quartus prunes the other arms:

| arm | ALMs | memory |
|---|---|---|
| copper | ~120 | — |
| scope | ~105 | **1 M10K** |
| xor | ~60 | — |

The scope stored precomputed screen ROWS, not samples (`row = centre + s>>9 +
s>>10`, ±96 rows, 360 entries × 20 bits = exactly one M10K), so the display path
only compared — which is what made it cheap in ALMs and expensive in memory. With
RAM at 90 % and the design in the congestion regime at 98 % ALM, **the memory block
was the expensive half**, and that is why the scope went rather than a cheaper-
looking arm.

## Follow-up 5 (`dev-cddaphys6`, 2026-09-12) — XOR dropped, copper slimmed, logo default

Three more user decisions, all on the same theme of being conservative with logic.

**The XOR pattern is gone.** ~60 ALMs on its own, but it was the **only per-PIXEL
consumer** in the module, so dropping it also retired the `a_xv`/`a_yv`/`b_m`
coordinate pipeline and the `sx`/`sy`/`tc` scroll registers. Copper's colour is a
per-LINE register, so nothing rides the display pipeline any more — its two stages
survive purely to match `idle_logo`'s 3-cycle output latency.

**Copper was slimmed rather than dropped:** a **triangle** oscillator instead of the
quarter-wave sine (bars bounce linearly), and **three bars instead of five**. The
triangle is the bigger win — the mirror already existed, so the 64-entry LUT became
`{sq_i, 1'b0}`, a wire.

**The logo is now the default** and Angle opts into the visualizer. Implemented by
NUMBERING the logo as mode 0 rather than resetting a copper-is-0 register to 1, so
"reset value = default" stays true.

⚠ **The cycle is now TWO stops** (`viz_mode` wraps at 1). It was four, then three
when the scope went, and the explicit wrap has been load-bearing every time:
`viz_mode` is 2 bits because emu passes it through, so letting the counter roll on
its width leaves dead modes and Angle lands on a blank screen — which reads as the
player having hung. `cdda_screen_tb` `[3b]` is RED-proven against that mutation.

### Ejecting a disc did not return the core to idle — and Main was not at fault

Field report on `dev-cddaphys5`. The Main-side log settled the blame immediately:
it detected the eject, unmounted the slot and pulsed `status[0]`. The defect was
core-side and had two halves.

`dvd_iso_reader` cleared `cdda_mode` **only in its `start` branch**, and issue #48
gates `start_streaming` on a non-zero `img_size` — but an **eject arrives as a
ZERO-SIZE mount**, so `start` never fires. The bit was not in the reset branch
either, so it survived even the eject's own reset. ★ `iso_mode` *was* reset there
all along; `cdda_mode` and `raw_mode` were simply the odd ones out, which is what
marks this as an oversight rather than a decision.

Then `emu.sv`'s `logo_vis` takes a CD branch that follows `viz_logo` alone and
**ignores `media_seen`**, so with the mode bit stuck the screen stayed on the
visualizer for ever.

Fixed at both ends — the reader resets `cdda_mode`/`raw_mode`/`wav_bad`, and the
screen arm is gated on `media_seen` (`cd_screen`), so a stale mode cannot strand the
display on its own.

⚠ **Making the logo the default would have MASKED this.** `viz_logo` is 1 after a
reset, so the picture looks right while `cdda_mode` stays high and every other
consumer of it — HUD `force_show`, `ticks_off`, the transport's CD arms, `pass_mode`
suppression — remains wrongly in CD mode. Fix the bit, not the symptom.

**Gate:** `wav_probe_tb` **TEST 8** — a reset with no `start`, which is exactly the
eject case. RED-proven against the pre-fix reader (`cdda=1` survives), and it carries
a precondition that `cdda_mode` was set going in, so it cannot pass vacuously.

### Per-track bar, FF/REW at the track edges

Both the seek bar and `scrub_ctrl`'s clamp take `[cur_start, cur_end]` on a CD
with a track table. ★ **That single substitution implements both edge rules:**
REW stops at the track start because that is the clamp's lower bound, and FF
that runs to the end lands on `cur_end` — which is the **next track's first
block**, so "FF to the end skips to the next track" needed no new logic. On the
last track `cur_end` is clipped to the disc's end and playback finishes. D-pad
time jumps ride the same clamp.

⚠ **A track skip must not see the narrowed span**: previous-track targets a block
before `cur_start`, which the clamp would pin to this track's start. The skip uses
the same jump port and `scrub_ctrl` resolves it in the cycle after `jump_fire`, so
`cdda_skip_win` holds the disc span for that window.

### No notches — and why they never worked

The disc bar's track notches never rendered on hardware. `seek_bar` converts its
tick list only on a `pgc_loaded` **rise**, and a CD never produces one — so the
boundaries `cdda_toc` replayed into the `cellf_*` ports were never converted.
Worse, a DVD played earlier in the session leaves `tick_ok` set with ITS list,
which would have drawn the DVD's notches on the CD bar. The replay is deleted from
`cdda_toc`, and new `seek_bar.ticks_off` gates both the notches and the
chapter-skip cursor.

### `TR n/N`

`transport_hud.trk_mode` swaps the `CH` label for `TR` on the status line and on
the skip popup. `Debug Overlay` keeps `CH`, since it repurposes that field.
`tools/hud_read.py` accepts both and reports which in `label`.

### Tests

- `bench/dvd/cdda_viz_tb.sv` rasters real frames and checks **rendered pixels**,
  not internal state: copper full coverage, one colour per line, bar cores that
  move between frames; XOR variation and scroll; both gates. ⚠ **The retired scope
  arm left a lesson worth more than the feature:** its continuity check first
  counted lit COLUMNS — which a dotted plot also lights, so it passed a trace drawn
  as dots — and only counting PIXELS (~4,700 continuous vs ~720 dotted) could fail
  it. Reach for the pixel count the next time anything draws a line.
- `transport_hud_tb` T22 (label on and back off), `seek_bar_tb` T8d/T9f (a
  converted tick list stays hidden, and the chapter cursor drops).
- `run_wav.sh` now runs `cdda_toc_tb` and `cdda_viz_tb`.

## Follow-up 2 (`dev-cddaphys3`) — HUD out of the way; a track-relative seek preview

Two reports from the first hardware look at `dev-cddaphys2`. **Sim-green, ⏳ not yet
re-run on hardware.**

**The seek preview showed DISC time.** Holding FF/REW over a track read, say,
`0:24:10` in a 10-minute track. `lin_rate` had been handed a track-relative
`lin_blk` and `total_blk` for the clock, but its preview input `prev_rbn` was still
the absolute `bar_tgt_rbn`, so the preview converted a disc position against a track
origin. Now it gets `bar_tgt_rbn − cur_start` too, floored at zero because a
previous-track skip's target lies before `cur_start` (the unsigned subtract would
otherwise preview ~2³² blocks for the moment before the skip lands). ★ D-pad
previews were already right, and it is worth knowing why rather than assuming the
fix covered them: `seek_time`'s delta arm reads `lin_cur_bcd` and
`lin_total_secs`, which were track-relative from the start — so only the
FF/REW path, which goes through `lin_rate`'s preview, was wrong.
⚠ No bench covers it: the mapping lives in `emu.sv`, two lines from the clock
mapping that had the same shape. It is the kind of asymmetry to look for whenever
one of a module's inputs is re-based and its siblings are not.

**The HUD is hidden over a visualizer** (user request) and **Display toggles it**
in any mode. New `dvd/cdda_screen.sv` holds both the visualizer mode (moved out of
`emu.sv`) and `hud_show`: cycling into a visualizer hides the status line and
progress bar, cycling into the logo shows them, Display flips them, and a new disc
resets them to match the mode. Both overlays go together — a lone progress bar
floating over copper bars looks like a glitch. Transport events (pause, skip,
seek) still pop them for a couple of seconds, via `transport_hud`'s and
`seek_bar`'s own auto-show, unchanged.
⚠ **On a CD the HUD's own Display toggle is gated off** (`display_edge &
~cdda_mode`). `transport_hud` already keeps a `persist_q` that Display flips;
leaving it live would be a second copy of the same state, and the two would drift
the first time one of them was reset without the other.
Gate: `bench/dvd/cdda_screen_tb.sv` (cycle, per-mode default, Display in both
kinds of mode, new-disc reset, and no effect outside CD mode), in `run_wav.sh`.

## Follow-up 3 (`dev-cddaphys4`) — track skips stack

**Report:** pressing Next or Previous several times quickly on a CD moved one track,
where the same burst on a DVD skips that many chapters. **Sim-green, ⏳ not yet run on
hardware.**

The press counting was never the problem. `emu.sv`'s chapter debounce already turns a
burst into ONE `chap_pulse` carrying `chap_mag`, and the DVD reader uses it — but
`cdda_toc`'s resolver only ever took the pulse and the direction, so it always
answered "the next track" or "the previous track".

`cdda_toc` now takes `skip_mag` and resolves the burst to a track **index**: `cur + N`
forward (past the last track = the disc's end, as a single press already did), and
backward the restart of the current track counts as the first step when more than
~3 s in, then one track per press, clamped at track 1. ★ The table has ONE read port
(the fit-failure lesson in this module's header), so an arbitrary entry cannot be read
on demand — the resolver waits for the continuous walk to reach the index and captures
its start then. That is at most two sweeps, a few hundred clocks, invisible after a
500 ms debounce. ⚠ `cdda_toc_tb`'s skip helper had waited 4 cycles for the fire, which
this latency would have failed; its "no table, no skip" arm now waits as long as a real
fire may take, or a late spurious fire would pass it.

**The HUD counts through tracks as you press.** The chapter projection in `emu.sv`
(`chap_proj_clamp` → `chap_disp_hold` → `hud_cur_ch`) was keyed on the DVD chapter
number, which is 0 on a CD, so it never engaged. On a CD it now uses the current track,
the track total and — for the restart rule — `cdda_toc`'s own exported `past_start`,
so the number on screen and the place the skip lands come from one rule. DVDs see the
exact same terms as before. `seek_time`'s chapter arm reads DVD maps, so its
`chap_prev` is gated off on a CD.

The track-table wires moved up beside the chapter burst in `emu.sv`, which read
`cdda_tracks_on` above its declaration — something both tools tolerated.

Gate: `cdda_toc_tb` [7] — next ×3, prev ×2 past and at a track start, overshoot at both
ends, and the exported `past_start` verdict — each arm starting where a single press
would land somewhere else, so an implementation ignoring `skip_mag` fails.


## HW gate (branch 3) — the REBASED build, 2026-09-22: every gate, including 7

Build `DVD_cddaphys7_20260922_0453.rbf` (SEED 9 first roll, clk_dec 91.17 @100C /
90.60 @-40C, 94 % ALM), the branch rebased onto post-v0.6.1 `main`, a real
**12-track** music CD, `Debug Overlay = Off`, custom Main cross-compiled from the
rebased tree.

⚠ **The rig had FOUR optical drives and the disc was in `/dev/sr3`.**
`/proc/sys/dev/cdrom/info` lists `sr0..sr3` as *names*, but only `sr3` had a device
node. Both `find_audio_cd()` and `open_ready_drive()` scan `sr0..sr7`, so it was
found — but a probe that had stopped at `sr0` would have reported "no disc" on a rig
with a disc in it.

| # | Gate | Result |
|---|---|---|
| 1 | CD auto-mounts while the core runs | ✅ `audio CD on /dev/sr3 -- mounting`, `size=467554124` = **exactly** `44 + 198790x2352` (44:10) |
| 2 | Plays, HUD reads the track | ✅ `[PLAY] 0:00:35/0:04:35 TR  1/12`, maxerr 0 |
| 3 | Clock is TRACK time, not disc time | ✅ the total tracks the track: 4:35 -> 3:08 -> 4:42 -> 2:32 -> 3:05 across skips |
| 4 | Next track | ✅ `TR 2/12`, clock reset, total = track 2's own 3:08 |
| 5 | Prev, >3 s into a track | ✅ 0:00:24 -> restarts at 0:00:01, still `TR 2/12` |
| 6 | Prev, <3 s into a track | ✅ TR 3 -> next -> TR 4 -> prev @1.2 s -> back to `TR 3/12` |
| 7 | **Next on the LAST track** | ✅ **RUN AT LAST** — see below |
| 8 | Track skips STACK | ✅ a 9-press burst from TR 3 landed on `TR 12/12` exactly |
| 9 | FF past a track end carries into the next | ✅ TR 3 @1:49 -> burst -> `TR 4/12` @0:00:04, total 2:32 |
| 10 | REW at a track start clamps | ✅ 0:00:03 -> REW -> 0:00:03 on the SAME track (it seeked: an un-seeked clock would have advanced) |
| 11 | Angle -> visualizer, HUD hidden | ✅ lit 8,766 px -> **342,720** (the whole active area), 169 colours, `hud_visible` True -> False |
| 12 | Angle WRAPS to the logo | ✅ back to 9,706 px / 2 colours — not a dead fourth mode |
| 13 | Display toggles the HUD over a visualizer | ✅ `hud_visible=True` with the visualizer up |
| 14 | Pause holds, and resumes | ✅ `[PAUSE] 0:00:10/0:03:05 TR 5/12`, audio silent, resumes advancing |
| 15 | Audio is actually audible | ✅ mean **−21.3 dBFS**, peak −5.1 |
| 16 | Eject returns to the idle logo | ✅ visualizer (342,720 px) -> **4,686 px** = the bare logo |
| 17 | Eject opens the tray | ⛔ **NOT OURS — stock Main holds the drive**, see below |

★ **Gate 15's control is the setting, not a sibling track.** A music CD has one
stream, so the `audio_check.py` "the disc's other tracks are the control" trick has
nothing to compare against. `Audio=Off` and `Pause` were used instead, and they agree:
−57.0 and −57.7 dBFS mean against −21.3 playing. **Two independent ways of producing
silence landing on the same floor is what identifies that floor as the CAPTURE CHAIN
rather than the core** — without the second one, `Audio=Off` reading −57 instead of
digital silence looks like a mute that does not mute.

### Gate 7, finally run: it ends the disc, and that is the design

Next on track 12 of 12 seeks to `total_blk` (the disc end) — `cdda_toc`'s resolver
does this deliberately, "past the last track = the disc's end". Playback then ends.

⚠ **What it LOOKS like is a hang, and it is not.** The HUD falls back to
`[PLAY] 0:00:00/0:04:35 TR  1/12` and the clock sits frozen there — the playhead is
back at block 0, so the track walk resolves track 1, while the icon still says PLAY.
**Measured: the clock read 0:00:00 at four samples over 20 s.** But the machine is
live — any transport press resumes normally (`next` -> `TR 2/12`, clock advancing).
So the residual is a READOUT that claims to be playing when the disc has finished,
not a wedge. A set-top player would stop and say so.

### Gate 17: the tray — a real leak of ours, and a red herring I chased

**We leaked the drive fd, and that is FIXED** (`dvd_cdda_close()` dropped `g_fd` without
closing it; `dvd_cdda_open()` takes ownership, so every mount leaked one descriptor on
`/dev/srN`). Gated by `dvd_cdda_test` arm [9] and the `cdda-fd-leak` RED mutation.

✅ **AND EJECT WORKS. The tray opens** — confirmed 2026-09-22 on a freshly rebooted rig:
`DVD_PHYS: eject: tray opened on /dev/sr0`, the drive reporting `TRAY_OPEN`, no holders
left on the device, the core on its idle logo, and no re-mount loop (`disc removed, but
the drive does not own slot 0 (foreign=1)`).

⚠⚠ **AND THE EBUSY I SPENT A LONG TIME ON WAS AN ARTEFACT OF A RIG THAT HAD BEEN UP FOR
DAYS — the maintainer suggested the reboot, and it was the right call.** What I had
measured, and what the reboot changed:

| | days of uptime | fresh boot |
|---|---|---|
| the drive's node | `/dev/sr3` (sr0/1/2 re-enumerated away) | `/dev/sr0` |
| handles on it, idle | **6** held by Main — 1 live + **5 stale `(deleted)`** | **0** |
| handles while a CD is mounted | 2 (ours + a plain `O_RDONLY` one) | **1** (ours) |
| `CDROMEJECT` | `EBUSY` | **tray opens** |

`cdrom_ioctl_eject()` refuses with `-EBUSY` unless `use_count == 1` — the ejecting fd must
be the ONLY open handle. Repeated USB re-enumeration over days had left Main holding
descriptors for drives that no longer existed, so the count could never reach 1.

★ **The lesson is the harness rule one level up: "would this change if you changed
something unrelated to the core?" — and a machine's UPTIME is one of those things.** I
had ruled our code out correctly (every one of our optical opens carries
`O_NONBLOCK`/`O_CLOEXEC`; the blocking handle had neither; it persisted with nothing
mounted) and then drew the wrong conclusion from it — "stock Main holds the drive, so
this can never work" — when the right one was "this machine is in an accumulated state".
The maintainer's own report that **DVD eject works today** was the contradiction that
should have stopped me, and I recorded it as an unexplained discrepancy instead of
treating it as evidence against my own conclusion.

⚠ Two smaller things seen in the same log and worth fixing on the way past:
`DVD_REMOTE: eject button -- optical disc unmounted + tray opened` is printed
**unconditionally**, so it claimed success in the very log line above the failure; and
one Eject press produced **two** events (the optical path, then the image path).
