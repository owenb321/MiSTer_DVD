# WAV / CD-DA playback (raw-PCM path)

Engineering note for `feature/wav-audio` (branch 1 of the music-CD work). The
user-facing text lives in `site/content/getting-started/loading.md` and
`site/content/audio/formats.md` — this file is the *why*.

**Status: 🔧 sim-complete, ⏳ HW-confirm pending.** Branch 2
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
release via its ~2.5 s fallback timer) and forces `pass_mode` **off**, because
Passthru would hand the audio ring's read side to `iec61937_wrap` and there is
no bitstream to wrap.

Backpressure composes with no new mechanism: `lpcm_unpack.afull` → `reader_busy`
→ cache fills → `cache_has_room` false → `sd_rd` stops. In this mode
`reader_busy` is *only* that tap; the video-side terms reference a pipeline the
mode never feeds.

## Time readout (`dvd/cdda_time.sv`)

Linear audio has no DSI/PGC clock — the known "HUD time zero in linear modes"
gap. Time comes from **stream position**, `seconds = (blocks × K) >> 20`, which
is seek-proof and monotonic; a sample counter would desync on every seek.
Worst-case error is ≤1 s over a 700k-block sweep and is bounded by the shift
truncation, not the constant, so a finer K buys nothing. Output is dvd_time BCD
so it drops onto the existing HUD ports.

## Screen

There is no video, so the **idle logo keeps bouncing** (`logo_vis` gains a
`cdda_mode` term — `media_seen`/`img_streaming` would otherwise hide it the
moment blocks start arriving) and the **HUD status line is forced on** for the
session via a new `force_show` input, giving elapsed/total time like a player's
front panel. Both composite through the existing register stage; the raster
free-runs black underneath, so this costs nothing in the display hotspot.

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
  test cannot pass by accident); `cdda_time` BCD spot checks.
* Regressions in the same script: `lpcm_unpack`, `dvd_audio_decode`,
  `transport_hud`, `hud_frame`, and the whole VCD/MP2 suite.

⚠ TB gotcha worth remembering: the bare-unpacker rig first "failed" because it
set a byte and *then* waited for the edge, racing the DUT's own `always_ff` at
that timestep — bytes silently duplicated. Drive after the edge (`@(posedge);
#1;`).

## HW gate (branch 1)

1. 44.1 kHz and 48 kHz `.wav` play clean; pitch matches a PC playing the same file.
2. Pause/resume; D-pad time jumps; logo bounces with the HUD time advancing and
   surviving seeks.
3. A reject fixture shows `UNSUPPORTED IMAGE` immediately.
4. DVD + VCD regression pass on the same build.

## Next (branch 2)

`main/support/dvd/dvd_cdda.cpp`: TOC via `CDROMREADTOCHDR`/`CDROMREADTOCENTRY`,
audio sectors via SG_IO `READ CD` (0xBE, `cdb[9]=0x10`, `cdb[1]=0x04`), repacked
2352→2048 behind the synthetic WAV header, served through the existing
`SD_TYPE_DVDCSS` hooks so `apply_integration.py` needs **zero** new steps. A
track table rides the generic ioctl-download channel (the PSX `disk_t`
precedent) to a new `dvd/cdda_toc.sv`, feeding tracks-as-chapters and the
seek-bar notches. **Run an SG_IO smoke test on the board before writing any of
it** — that 0xBE audio reads work on the user's drive is the one real unknown.
