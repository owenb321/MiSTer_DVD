# VCD / SVCD Playback (bin/cue raw-2352 images)

**Status: ✅ HW-CONFIRMED 2026-08-24 (user report, branch
`feature/vcd-svcd-playback`): VCD and SVCD look good on both analog and HDMI, and
seeking works as expected.** Select the rip's **data-track `.bin`** in the OSD and the
movie plays with A/V sync, correct 44.1 kHz audio pitch, seek + pause. No menus/PBC
(v1). The confirming build was the `DVD_vcdsvcd_MARGINAL` rbf (clk_dec 85.46 MHz at
the −40 °C corner, 0.54 under the 86 gate — the release rbf comes from the seed
sweep); sub-items not specifically re-verified stay open in §6 below.

Companion docs: `docs/mpeg1.md` (the MPEG-1 video + MP2 decoders this feature rides on),
`docs/experiments.md` §"VCD / SVCD playback" (the original delta list, now largely
delivered), `docs/hps_handoff_cd_precedent.md` (why bin/cue had to be done in fabric).

## 1. Disc/image format (ground truth from a real PAL VCD)

- VCD and SVCD are both **CD-ROM XA** discs; rips are bin/cue with `TRACK MODE2/2352`.
  Split-bin rips: Track 1 = ISO9660 filesystem (~2 MB), Track 2+ = MPEG data (the bulk).
  Single-bin whole-disc images also exist. `.img` raw dumps are byte-identical to
  `.bin`; `.cue`/`.ccd`/`.mds` sidecars are text/metadata the fabric cannot parse (the
  framework mounts exactly one file and the extension never reaches fabric).
- Raw sector = 12-byte sync (`00 FF×10 00`) + 3-byte MSF + mode byte (@15) + 8-byte XA
  subheader (submode @18; **bit5 = Form 2**) + payload @24 (Form 2 = 2324 B, Form 1 =
  2048 B). MPEG sectors are Form 2, **one MPEG pack per sector, `00 00 01 BA` at payload
  offset 0** — so every sector is a clean pack boundary (seek snap relies on this).
  Submodes seen on a real VCD: 0x20 pregap (zero payload), 0x60 data, 0x62 video,
  0x64 audio.
- **VCD** payload = **MPEG-1 system stream** (ISO 11172-1): 12-byte pack (marker nibble
  `0010`, no stuffing-length byte); PES optional header = `0xFF` stuffing* → optional
  2-byte STD buffer field (`01......`) → `0x2X`+PTS(5) / `0x3X`+PTS(5)+DTS(5) / one
  no-timestamp byte (`0x0F`). Video 352×240@29.97 / 352×288@25, MP2 44.1 kHz.
- **SVCD** payload = MPEG-2 PS (the existing demux path), video 480×480 NTSC /
  480×576 PAL ("2/3 D1"), MP2 44.1 kHz, real DAR codes (4:3 or 16:9 anamorphic) in the
  sequence header. OGT subtitles ride 0xBD substreams 0x00-0x03 → existing
  skip-by-length discard.

## 2. The four deltas (where each lives)

### 2a. Raw-2352 detect + in-fabric deblock — `dvd/dvd_iso_reader.sv`

`S_INIT` probes **file byte 0 first** (block-aligned, free): the 12-byte sync + mode-2
signature (`raw2352` rbuf tap) or a `RIFF….CDXA` tag (extracted `.DAT`; its 44-byte
header is skipped by pre-loading `raw_pos` so the header reads as the tail of a phantom
sector). Not raw → the unchanged LBA-16 `CD001` probe. A DVD ISO has zeros at LBA 0 —
no false fire. New state `S_CHK_RAW` (6'd58; 5 slots remain).

Raw mode streams the whole file linearly (flat-fallback extent setup) through an
in-line deblocker:

- `raw_pos` = free-running **mod-2352 byte position**. Blocks are requested strictly
  in order on the linear path, so it just accumulates across 2048-byte blocks — the
  2352>2048 sector/block straddle needs no special case.
- Per sector: `raw_m2` latched @15, `raw_sec_pass` (= m2 && submode bit5) @18; the
  cache write port passes **only Form-2 payload bytes [24, 2348)**, compacted via
  `raw_wcnt`; `wr_ptr` advances by the counted `raw_wcnt` instead of `+BLK`.
- `raw_sec_pass` **clears at every sector wrap** → a stream entered mid-sector (seek /
  CDXA skip) drops the partial sector and starts clean at the next boundary.
- **Form-1 sectors are skipped entirely** (deviation from `tools/vcd_to_vob.sh`, which
  passes their 2048 bytes): they are ISO-filesystem data (single-bin images) that could
  false-sync the demux hunter; skipping them also makes single-bin whole-disc images
  play (the ISO track is silently dropped). Zero-payload Form-2 pregap sectors pass as
  zeros — harmless to the start-code hunter.

Golden model: **`tools/cd_deblock_ref.py`** (byte-exact contract, incl. `start_pos`
preload semantics). TB: `bench/dvd/iso_reader_raw_tb.sv`.

### 2b. MPEG-1 system-stream demux — `dvd/ps_demux.sv`

Per-pack flavour latch `mpeg1_ps` from the marker after `0xBA` (`0010`=MPEG-1 12-byte
pack, `01`=MPEG-2 — disjoint, re-latched every pack). MPEG-1 PES headers get two new
states (`S_M1_HDR`/`S_M1_STD`); the 5-byte timestamp packing is identical to MPEG-2's,
so the existing `S_PTS` assembler is reused (entered with `pts_buf[0]` preloaded:
PTS-only lands on the header-done dispatch, PTS+DTS falls into `S_PES_HDR_SKIP` with
exactly the 5 DTS bytes left). `vid_pts`/`aud_frame_pts` arrive identically → av_sync
needs nothing. `pes_scrambled` (CSS) is never touched on the MPEG-1 path; ES
passthrough and all MPEG-2/DVD behaviour bit-identical (all demux TBs green).
Golden model: **`tools/mpeg1_ps_ref.py`**. TB: `bench/dvd/ps_demux_m1_tb.sv`
(real VCD packs, byte-exact ES + PTS sequences, no scramble pulses).

SVCD needs **zero demux work** (MPEG-2 PS; MP2 on 0xC0 already routed).

### 2c. 44.1/32 kHz audio clock — `dvd/mp2/mp2_decode.sv` + `dvd/dvd_audio_decode.sv`

`mp2_decode.fs_o` exports the header sampling rate (0=44.1, 1=48, 2=32; valid while
`synced`). `dvd_audio_decode` muxes the NCO increment on it whenever the active codec
is MP2 (44.1 k = 7014363, 32 k = 5085177 at 27 MHz; AC-3/DTS/LPCM stay 48 k), latched
**only while the drain gate is closed** (`!draining`) so a swap lands at a (re)start
event — load / seek / underrun re-arm — never mid-drain (no phase kick). The framework
needs nothing: `sys/audio_out.v` zero-order-holds `AUDIO_L/R` at its own fixed 48 kHz,
so a 44.1 kHz core tick gives correct pitch (nearest-neighbour resample artifacts only,
same as any non-48 k core). The `dbg_play_err` tracker slope is now rate-exact
(1+7/8 / 2+2/49 / 2+13/16 ticks/sample). This closes docs/mpeg1.md's
"44.1 kHz plays ~8.8 % fast" limitation. av_sync is rate-agnostic (90 kHz-tick
arithmetic); its `TRIM_CLAMP` `AUD_HZ` param is inert (nco_trim retired, tied 0).
TB: `bench/dvd/vcd_chain_tb.sv` — real VCD slice through the FULL chain, PCM
bit-exact vs `tools/mp2_ref.py`, measured tick cadence exact (±1 % assertion,
actual within 1 tick over a 16.9 M-cycle window), and the no-swap-while-draining
contract asserted in `+SCHED` (real drain gate) mode.

### 2d. Display — one predicate (analog); HDMI needed nothing

- **HDMI**: ascal scales the DE rectangle (= decoded size) into `VIDEO_ARX/ARY`;
  SVCD's real MPEG-2 DAR codes drive the existing `ar_wide_auto` latch (16:9
  anamorphic SVCDs included). VCD (MPEG-1 pixel-AR codes never match) holds the 4:3
  default — also correct. Zero work.
- **Analog**: `emu.sv` `sif_h_dec` widened `<=360` → `< 720` (user decision
  2026-08-24, reversing the earlier SIF-only scope): ANY sub-720 width now fills via
  the fractional `disp_hstretch` — SVCD 480→720 is an exact 2:3, and DVD sub-D1
  704/544 content fills too. 720-wide stays un-stretched (hsrc<hdst contract).
  SVCD vertical (480/576) is raster-native — `sif_v_dec` (≤288, the v2x line repeat)
  untouched. Modeline auto-detect already correct (SVCD 480→NTSC, 576→PAL, VCD
  288→PAL). TBs: `crt_ov_map_tb` T1d grew 480/544/704→720 exactness cases;
  `resample_chain_tb` grew `+hfill=1` (480×480 h-fill-only, composes with `+hgrad`
  blend proof and `+crt`).

## 3. Transport (seek + pause)

Pause already worked (decoder-side, not cell-gated). Seek: the reader accepts the
gamepad RBN scrub in linear modes (`lin_seek_ok` = raw mode always; a plain flat file
only once `ps_demux.saw_pack` proves the stream has packs). A `!cell_mode` seek_jump
branch restarts the single-extent stream at the target:

- **Raw**: block → containing sector (`r·128/147` by shift-subtract, −0.07 % early
  bias), stream restarts at that byte's block with `raw_pos` pre-loaded and the pass
  latch cleared → emission resumes at the next sector = **a clean MPEG pack boundary**
  (the raw analogue of the DVD NAV-pack snap).
- **Flat PS** (`.mpg`, directly-selected `.VOB`): restart at the raw block + a
  **post-seek pack hunt** in the output pipeline (drop until `00 00 01 BA`, then
  re-emit the consumed preamble from constants — the ps_demux `S_ES_EMIT` trick).
  Why it's required: ps_demux resets per-jump, and if the first start code it saw
  were a video slice/picture code it would mis-latch into raw-ES passthrough
  (video-only, no audio, wedged until the next load). MPEG start codes cannot be
  emulated in-stream, so hunting `000001BA` is reliable.
- **Raw ES** (`.m2v` — no packs, no audio): stays linear-only by the `saw_pack` gate.

emu: transport gates widened `cell_ready` → `(cell_ready || lin_seek_ok)`; the
scrub/seek-bar playhead muxes to the reader's linear block; the linear title span
(0..total_blocks−1) publishes on `title_first/last_rbn`. Chapters/angles stay
DVD-only. HUD time shows 0:00 in linear modes (no DSI timecodes — see limitations).

## 4. Tests

One entry point: **`bench/dvd/run_vcd.sh`** (raw reader TB + MPEG-1 demux TB + full
chain in free-run and `+SCHED` modes; generates the PCM golden from the committed
audio-ES fixture). Committed fixtures (`bench/dvd/test_vobs/vcd_*.hex`,
`svcd_slice*.hex`) are cut from a real PAL VCD + a synthetic ffmpeg NTSC-SVCD wrap by
**`tools/vcd_fixtures.py`** (`VCD_TRACK_BIN=<track2.bin>`), which cross-checks the ES
goldens against `ffmpeg -c copy` at generation time. Plus: `crt_ov_map_tb`,
`resample_chain_tb +hfill` variants, all existing demux/reader/MP2 regressions.

## 5. Known limitations (v1)

- **No menus / PBC / segment stills** (VCD 2.0 SEGMENT items are skipped only insofar
  as they live in the ISO track region of single-bin images; a stray Form-2 segment
  before the movie would play briefly).
- **Multi-track discs**: pick each track's `.bin` separately (multi-movie VCDs).
  CD-DA audio tracks are not playable.
- **2336-byte sector images** (Mode-2-without-sync rips) are not detected.
- **23.976-coded NTSC film VCDs play ~25 % fast**: MPEG-1 has no repeat_first_field,
  so the film detector cannot see them and the governor shows every frame for 2
  refreshes. Rare; revisit if a real disc surfaces (would key on frame_rate_code).
- **HUD time blank/zero in linear modes** (no DSI). A VCD-only elapsed clock from the
  75-sector/s CBR geometry is a possible follow-up; SVCD is VBR.
- **EOF tail**: the final partial 2048-block may emit a few stale in-window bytes —
  end-of-play junk, harmless.
- IEC 61937 MP2 passthrough unchanged (passthrough mode silences MP2, as on DVD).

## 6. HW gate checklist (✅ core gate passed 2026-08-24, user report)

- [x] Real VCD: plays with correct pitch and A/V sync; seeking works as expected.
- [x] SVCD: looks good on HDMI **and** analog (the 480→720 fill confirmed).
- [ ] NTSC VCD 29.97 cadence (the confirming discs' standards weren't itemised).
- [ ] 16:9 anamorphic SVCD DAR latch (no such disc tested yet).
- [ ] DVD regression pass on the RELEASE build: an ISO with menus + a flat
      `.VOB`/`.mpg` (now seekable) + a `.m2v` (still linear-only); DVD 704/544
      sub-D1 disc now fills on analog.
- [ ] CSS-encrypted ISO still warns (scramble detect untouched on the MPEG-2 path).
