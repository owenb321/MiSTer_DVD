# In-fabric audio decode (AC-3 + LPCM)

**Status:** implemented 2026-06-27 on branch `feature/fabric-ac3-audio`.
Replaces the DDR3-ring + HPS-daemon audio path (see `audio_ddr_path.md`, now
superseded). Sim-verified (`bench/dvd/lpcm_unpack_tb.sv`,
`bench/dvd/dvd_audio_decode_tb.sv`); hardware confirmation pending.

## Why

The previous design demuxed audio in fabric but shipped the *compressed* frames
out to DDR3 for a standalone HPS daemon (`hps/dvd_audio.c`, liba52/libdca) to
decode and play via ALSA. That worked but kept a second moving part (a userspace
process you had to launch by hand) and a DDR3 write master sharing the decoder's
memory port. With a working in-fabric AC-3 decoder available (ported from
`MiSTer_AC3`), we can decode AC-3 and LPCM entirely in the FPGA and drive the
framework's `AUDIO_L/R` directly — no HPS process, no DDR3 audio traffic.

## Data flow

```
mpg_streamer → ps_stream_fifo → ps_demux ─┬─ video → mpeg2video (unchanged)
                                          └─ audio bytes (+type, +frame_start)
                                                 │  clk_sys (27 MHz)
                                                 ▼
                                        audio_ring   (dvd/audio_ring.sv — KEEP)
                                                 │  committed byte stream +
                                                 │  {len,type} frame descriptors
                                                 ▼
                              dvd_audio_decode.sv  (dvd/dvd_audio_decode.sv)
                                ├─ dispatch FSM (pop descriptor, route len bytes)
                                ├─ AC-3 (type 0) → ac3_front + pcm_out  (dvd/ac3/*)
                                ├─ LPCM (type 2) → lpcm_unpack          (dvd/lpcm_unpack.sv)
                                ├─ DTS (1)/unknown (3) → consumed & discarded
                                ├─ aud_ce: 48 kHz fractional NCO from clk_sys
                                └─ output mux → audio_l / audio_r (s16)
                                                 │
                                                 ▼
                          emu.sv: AUDIO_L/R = decoded PCM, AUDIO_S = 1
                                                 │
                                  sys/ framework I2S → HDMI @ 48 kHz (unchanged)
```

Everything runs in **clk_sys (~27 MHz)** — the same domain as `ps_demux` and
`audio_ring`, so there is no input clock-domain crossing. `pcm_out`'s built-in
async output FIFO is instantiated with `aud_clk = clk` so its Gray-pointer CDC
degenerates harmlessly. The AC-3 core has ~3000× real-time headroom at 27 MHz.

## dvd_audio_decode.sv

### Dispatch FSM
Drains `audio_ring`'s read side. `S_IDLE` waits for `frame_valid`, latches
`frame_len`/`frame_type`; `S_POP` pulses `frame_pop` (consume the descriptor);
`S_ROUTE` consumes **exactly `frame_len`** bytes from the committed byte stream,
routing each byte to the codec sink chosen by `frame_type`:
- `0` AC-3  → `ac3_front.wr_en/wr_data`
- `2` LPCM  → `lpcm_unpack.wr_en/wr_data`
- `1` DTS / `3` unknown → consumed and dropped (no sink)

`ring_ready` is asserted only when the selected sink can take a byte
(`~ac3_full` / `~lpcm_full`; always-ready for the discard case). Because
`audio_ring` ties its own `aud_ready` high and drops whole frames on overflow,
audio can **never** back-pressure video — that invariant is preserved end to end.

### aud_ce (48 kHz) — fractional NCO
27 MHz / 48 kHz = 562.5, not an integer, so a phase accumulator generates the
sample tick: `acc += INC` each `clk`, `aud_ce` on carry-out, with
`INC = AUD_HZ/CLK_HZ · 2³²`. Average rate is exactly 48 kHz (no long-term drift).

### Output mux
`pcm_out` (AC-3) and `lpcm_unpack` (LPCM) both emit one {L,R} pair per `aud_ce`.
A latched `cur_is_lpcm` (set in `S_POP` from the active *playable* codec, ignoring
DTS/unknown) selects which feeds `audio_l/r`. On each `aud_ce` the registered
output updates from the active source when its `aud_valid` is high, else holds.
A DVD track is one audio type at a time, so only one sink is fed in practice.

### Substream / track select (`ps_demux.aud_track`, menu `O68,Audio Track`)
A DVD program can interleave SEVERAL audio substreams of the same type — e.g. the
Matrix VOB carries AC-3 `0x80` (5.1) + `0x81` & `0x82` (stereo). ps_demux must forward
only ONE, or all of them interleave into the single in-fabric AC-3 decoder and the audio
is garbage (constant CRC/sync failure → "audio barely there", observed on Matrix 2026-06-27).
ps_demux now filters by `substream_id[2:0] == aud_track` (low 3 bits = the track number);
non-selected substreams are discarded in `S_SUBSTREAM_ID`. `O68,Audio Track` (status[8:6],
default 0 = substream `0x80`, the conventional main track) chooses it. Sim:
`bench/dvd/ps_demux_substream_tb.sv` (feeds 0x80/0x81/0x82, checks only the chosen one is
emitted). **Known limitation:** filtering is by track number only, so a disc that puts both
an AC-3 and a DTS version at the *same* track number (`0x80` and `0x88`) would pass both;
the AC-3-only decoder would then choke on the DTS frames. Rare; revisit if hit (filter by
full substream_id, or by type+track).

### AC-3 decoder connections (`dvd/ac3/`, copied verbatim from MiSTer_AC3)

(Scope, supported features, `err_unsupported` triggers, golden-reference/cosim setup,
and durable design decisions for the decoder itself: `docs/ac3_decoder.md`; full
module/interface/fixed-point contract: `docs/ac3_decoder_architecture.md`.)

- `ac3_front #(.FIFO_DEPTH(4096))` self-syncs on `0x0B77`; output PCM is Q8.23.
- `pcm_out #(.FIFO_AW(9))` converts Q8.23 → s16 (round-half-toward-+∞, saturate)
  and paces to `aud_ce`. Block handshake: `ac3_front.imdct_done → pcm_out.start`;
  `pcm_out.done → ac3_front.pcm_done` (metering — paces decode to the output rate).
- `pcm_out.pcm_rd_addr` is 9-bit `{ch,idx}`; zero-extended to the 11-bit
  `{ch[2:0],idx[7:0]}` `ac3_front` expects (only channels 0/1 are read after the
  5.1→stereo downmix done inside `imdct_512`).
- 5.1→stereo downmix is performed inside the AC-3 core (`imdct_512.sv` S_DMX).

## LPCM (lpcm_unpack.sv)
DVD LPCM is big-endian; the ps_demux LPCM sub-header (6 bytes) is stripped from
the payload, so the byte stream here is raw interleaved samples. Bytes are
assembled hi-first into s16, interleaved L,R, and pushed as {L,R} pairs into a
small FIFO drained at `aud_ce`.

**Scope:** 48 kHz **stereo**, **16 / 20 / 24-bit** (truncated to 16-bit for the
HDMI `AUDIO_L/R` interface). ps_demux now captures the LPCM sub-header **byte +5**
word-length field (bits[7:6]: 0=16, 1=20, 2=24) and exports it as
`aud_lpcm_quant`, routed to `lpcm_unpack.quant`. **96 kHz** and **multichannel
(>2 ch)** LPCM are still **not** handled (96 kHz needs the audio-NCO ÷2 path;
multichannel needs per-channel deinterleave + downmix).

**Why the fix is small (20/24-bit depacking).** Per FFmpeg `libavcodec/pcm-dvd.c`,
a DVD LPCM group spans 2 sample-times per channel. For stereo the group is the four
high 16-bit words in stream order `L0 R0 L1 R1` (8 bytes) — the SAME layout as plain
16-bit — followed by the low bits: 20-bit adds **2** trailing nibble-bytes, 24-bit adds
**4** trailing bytes. Since `AUDIO_L/R` is 16-bit we keep the four high words and DISCARD
the trailing low bytes. So `lpcm_unpack` assembles two {L,R} pairs exactly as at 16-bit,
then skips `skip_n` bytes (0 / 2 / 4) per group. quant=16 => skip_n=0 => byte-for-byte the
original 16-bit-only behaviour. Verified: `bench/dvd/lpcm_unpack_tb.sv` (16/20/24-bit) +
`bench/dvd/ps_demux_lpcm_tb.sv` (byte-+5 capture + framing).
**✅ HW-CONFIRMED (2026-07-27, PR fj#133):** `ROGER_WATERS_IN_THE_FLESH.iso` (20-bit) plays
clean stereo — the loud static is gone — and `DMDC8200_THREE_TENORS.iso` (16-bit) still plays
fine (no regression). Test vehicles: 20-bit target = Roger Waters, 16-bit control = Three Tenors.

**Hi-res LPCM (24-bit / 96 kHz bit-perfect) — separately planned as S/PDIF PCM.** The HDMI
`AUDIO_L/R` interface is a hard **16-bit** cap, so the path above truncates 24-bit to 16.
For bit-perfect 24-bit and 96 kHz, the plan routes LPCM **out S/PDIF as linear PCM**
(24-bit-native subframe), reusing the HW-confirmed `spdif_pass` encoder — see
`docs/iec61937.md` "Hi-res LPCM over S/PDIF (PLANNED)". The HDMI path here stays the
16/48 fallback for receiver-less setups.

## DTS
No fabric DTS decoder exists, so DTS frames are detected (`frame_type==1`) and
**dropped** (consumed, silent). Future plan: in-fabric **IEC 61937 bitstream
passthrough to the Digital I/O board** (Toslink S/PDIF), not HPS decode.

## Buffering & rate (hardware tuning, 2026-06-27)

Audio data is delivered **bursty** by the demux: the frame-rate governor releases
~one frame of audio then holds, so a steady 48 kHz output underruns small buffers
→ choppy (LPCM) / decode stalls (AC-3). Buffers were enlarged to ride this out:
- `audio_ring` `BYTE_DEPTH` 8192→32768 (compressed-frame elastic buffer; near-empty
  in steady state, so no added latency — just a higher overflow ceiling).
- `lpcm_unpack` pair FIFO `FIFO_AW` 9→12 (~85 ms).
- `pcm_out` FIFO `FIFO_AW` 9→11 (~43 ms).

**Open question / next lever:** if audio is still choppy *throughout* (not just
occasional), the cause is a **sustained** rate mismatch — the content is delivered
slightly slower than the fixed 48 kHz output (the old HPS/ALSA path hid this by
slaving audio to the data rate). The fix is to **genlock `aud_ce`** to an output
buffer fill level (adaptive NCO) instead of free-running. Not yet implemented —
gated on confirming jitter vs. sustained mismatch on hardware.

## Known issue: AC-3 choppy on high-bitrate content = VIDEO starvation (not audio)

Hardware 2026-06-27: a 7.8 Mbit/s BBB DVD (5.1 AC-3 448k) plays AC-3 **choppy**, while
a lower-bitrate LPCM clip is flawless. This was traced to **video-pipeline starvation,
not the audio chain**, and the audio chain is proven correct end-to-end:

- `ps_demux` AC-3 extraction is **byte-exact** vs ffmpeg ground truth
  (`bench/dvd/ps_demux_vob_extract_tb.sv` on the real VOB — 326,588 B identical).
- The AC-3 decoder is **bit-exact** vs liba52 on this exact BBB content
  (`bench/ac3/run_front_cosim.sh`).
- Overlay diagnostics during BBB: row 15 (self-heal resets) **steady** (no decode
  errors), row 14 (`pcm_out` underruns) **climbing/wrapping** (output starving).

Mechanism: the MPEG-2 decoder/DDR3 path can't sustain 7.8 Mbit/s at 30 fps, so video
runs slow; the multiplexed AC-3 therefore arrives slower than the fixed 48 kHz output
consumes it → continuous underrun → choppy. The audio is the canary for a (pre-existing)
**video-throughput** limit on high-bitrate DVDs — fabric audio *exposed* it (the old
HPS/ALSA path slaved audio to the slow data rate, masking it as slow-but-continuous).

Implications:
- Audio is correct on content the decoder can sustain in real time (LPCM clip is clean).
- No audio-side change makes BBB smooth — the AC-3 bytes physically aren't arriving in
  time. The real fix is **video throughput** for high-bitrate content (separate effort:
  decoder-clock / DDR3-bandwidth frontier — see memory `f2sdram-90mhz-ceiling`,
  `ao486-cache-hitrate-lever`).
- Genlock-to-data (Tier 3) would make BBB audio *continuous but slow* (synced to the
  slow video) instead of choppy — a nicer failure mode, but it masks rather than fixes
  the video limit.

## AC-3 self-heal

`ac3_front.err_unsupported` is **sticky** and puts the decoder in P_HALT — one
frame it rejects would silence AC-3 for the rest of the disc. `dvd_audio_decode`
watches `err_unsupported` **and** a decode-stall watchdog (no `imdct_done` for
~0.6 s while AC-3 is the active codec) and pulses a local reset (`ac3_core_rst`) so
the front-end re-syncs on the next `0x0B77` (brief glitch, then resumes) instead of
dying. This is the likely cause of the first-observed "AC-3 plays a split second
then silence."

## A/V sync — now PTS-driven (`dvd/av_sync.sv`, 2026-06-28)
The frame-rate governor (`dvd/resample_addrgen.v`) paces video to the display
refresh and back-pressures the shared demux byte stream. Audio rides the same
stream, so audio bytes arrive at video rate. **The 48 kHz `aud_ce` NCO is no longer
free-running** — `dvd/av_sync.sv` builds a video-referenced System Time Clock (STC,
anchored on `vid_pts`, advanced one `TICKS_PER_REFRESH` per displayed image) and
soft-slews the NCO (`nco_trim`, ±0.5 %) so the dispatched audio PTS tracks the STC.
This genlocks audio to the HDMI-locked video like a DVD player slaving its audio DAC
to the recovered STC, removing the two-crystal drift and giving audio its own
real-time clock instead of riding video's bursty delivery. Per-frame PTS is carried
`ps_demux.aud_frame_pts → audio_ring descriptor → dvd_audio_decode.dispatch_pts →
av_sync`. **Full design: `docs/av_sync.md`.** (Note: this paces audio; it does not
fix the PES-granular `audio_ring` drop that makes a dropped frame *pop* — that
remains a separate follow-up. A sustained compute-bound video deficit (BBB) still
under-runs audio gracefully; the real fix there is video throughput.)

## O5 toggle
`"O5,Audio,On,Off;"` — `status[5]==0` (default) = On. `enable` (= `~status[5]`)
gates the dispatch FSM and forces silent output when off (audio_ring then drops
frames; video is unaffected).

## Files
- New: `dvd/dvd_audio_decode.sv`, `dvd/lpcm_unpack.sv`, `dvd/ac3/*` (copied)
- Edited: `dvd/emu.sv` (AUDIO_L/R driven; DDR audio write chain removed; ddr_arb
  audio master tied off), `DVD.qsf`
- Tests: `bench/dvd/lpcm_unpack_tb.sv`, `bench/dvd/dvd_audio_decode_tb.sv`
- Removed 2026-07-01 (`feature/remove-diagnostic-cruft`): `hps/dvd_audio.c`,
  `dvd/audio_ddr_pack.sv`, `dvd/cdc_req_ack.sv`, `dvd/audio_ddr_issue.sv` (retired
  DDR3-ring + HPS-daemon audio path — deleted, recoverable from git)

## Simulation
```bash
# LPCM unpacker
iverilog -g2012 -o bench/dvd/lpcm_sim dvd/lpcm_unpack.sv bench/dvd/lpcm_unpack_tb.sv
vvp bench/dvd/lpcm_sim                                  # -> PASS: lpcm_unpack

# Dispatch + AC-3 sync integration
iverilog -g2012 -I dvd/ac3 -o bench/dvd/dad_sim \
    dvd/ac3/*.sv dvd/lpcm_unpack.sv dvd/dvd_audio_decode.sv \
    bench/dvd/dvd_audio_decode_tb.sv
vvp bench/dvd/dad_sim                                   # -> PASS: dvd_audio_decode

# AC-3 reframer (unit + reframer->audio_ring overflow integration)
iverilog -g2012 -o bench/dvd/rf_sim dvd/ac3_reframer.sv bench/dvd/ac3_reframer_tb.sv
vvp bench/dvd/rf_sim                                    # -> PASS: ac3_reframer
iverilog -g2012 -o bench/dvd/rfr_sim \
    dvd/ac3_reframer.sv dvd/audio_ring.sv bench/dvd/ac3_reframer_ring_tb.sv
vvp bench/dvd/rfr_sim          # -> PASS: every committed frame starts 0B77 across N drops
```
(iverilog prints benign `sorry: constant selects ...` notes from the AC-3 core,
which targets Verilator/Quartus; they do not affect the result. Full AC-3 PCM
correctness is covered by the AC-3 core's own Verilator/liba52 cosim.)

## AC-3 reframer (static-pops fix) — `dvd/ac3_reframer.sv`

> **✅ HW-CONFIRMED 2026-06-28 (PR fj#41):** reframer **v1** greatly reduced the BBB
> static pops; **v2** (the `frmsizcod` frame-length lock below) eliminated the
> residual — **BBB plays with no audible pops.** The static-pops issue is closed;
> the remaining BBB/Matrix artifact is compute-bound *video* stutter only, not audio.

**Problem.** `ps_demux` sets `aud_frame_start` once per **PES payload** (~2 KB), so
`audio_ring`'s drop unit is a PES chunk, **not** a decodable AC-3 frame. When the
frame-rate governor floods the ring during high-action video (`static-pops-root-cause`),
`audio_ring` drops a whole "frame" = a PES chunk, which cuts an AC-3 frame mid-stream
→ `ac3_front` desyncs → self-heal reset → **audible POP**. (HW-confirmed 2026-06-28:
disabling the av_sync genlock changed nothing — the pop is input-side overflow, not
the output NCO.)

**Fix.** Insert `ac3_reframer` between `ps_demux` and `audio_ring`. It is a
transparent 1-byte-delay passthrough of the audio byte stream that **regenerates
`frame_start` on AC-3 frame (`0x0B77` sync) boundaries** for AC-3 (`type==0`),
ignoring the PES-granular `frame_start`. `audio_ring`'s frames then ARE AC-3 frames,
so an overflow drop removes whole AC-3 frames — a clean silent gap that `ac3_front`
resyncs past on the next sync — instead of a non-aligned hole. (Proven harmless:
`static-pops-root-cause` cosim — a clean AC-3-frame drop gave 0 liba52 errors.) The
PES PTS is carried to the next regenerated `frame_start` (MPEG: a PES PTS refers to
the first access unit that *starts* in that packet). LPCM/DTS `frame_start` passes
through unchanged. **No decoder (`ac3_front`) changes**; bytes reach `ac3_front`
byte-identical, so the reframer is transparent when no overflow occurs.

- **Frame-length lock (v2 — robust to in-payload `0x0B77`):** v1 keyed purely on the
  sync word, so a coincidental `0x0B77` inside AC-3 payload (~4 % of frames at
  640 kb/s) made a spurious boundary; a drop landing there was non-aligned → the
  residual pop seen on BBB after v1 (HW 2026-06-28). v2 parses each header — the byte
  at frame offset 4 is `{fscod, frmsizcod}`; for 48 kHz (`fscod==0`) the frame size is
  a fixed function of `frmsizcod` (A/52 Table 5.18) — computes the frame length and
  **only accepts the next `0x0B77` once a full frame has been emitted**
  (`foff >= frame_len`). The reframer's input is the complete demuxed stream (drops
  happen later in `audio_ring`), so offsets are exact and the lock is deterministic;
  it re-locks on the next real frame if it ever slips. Non-48 kHz (decoder-unsupported)
  falls back to plain sync detection.
- **Sim:** `bench/dvd/ac3_reframer_tb.sv` (unit: length-locked reframing + **spurious
  in-payload `0x0B77` rejected** + PTS carry + LPCM passthrough) and
  `bench/dvd/ac3_reframer_ring_tb.sv` (integration: real `bbb_short_5p1.ac3` through
  reframer→audio_ring with a small ring + throttled consumer → forces overflow drops,
  asserts **every committed frame starts `0B 77`** AND the locked `frame_len` matches
  each real header's `frmsizcod`).

## AC-3 File Test mode (decoder isolation) — REMOVED 2026-07-01

This was a diagnostic (`O[12],AC-3 File Test`) that loaded a raw `.ac3` elementary
stream and routed it straight into `ac3_front` — bypassing `ps_demux`/`audio_ring`/
`av_sync` (a `raw_mode` path in `dvd_audio_decode.sv`, free-run NCO) — to test the
AC-3 decoder decoupled from the A/V pipeline. It loaded via the SD sector streamer
(not the OSD-blocking ioctl loader).

**Its finding is the reason it could be retired:** ✅ **HW-CONFIRMED 2026-06-28** that
raw `.ac3` files play back **clean, no glitches** — **exonerating the in-fabric AC-3
decoder** (`dvd/ac3/*` + `pcm_out` + the 48 kHz NCO + output mux). So any remaining
VOB audio glitches (pops, cutouts) are **pipeline-side** (`ps_demux` substream
filtering / `audio_ring` drop-on-overflow / `av_sync` genlock / frame-rate governor
pacing), not the decoder. Matches `static-pops-root-cause` / `matrix-throughput-bound`.

With the decoder proven, the toggle, the `.ac3` file handling (dropped from the `S0`
extension list), the `raw_mode` bypass in `dvd_audio_decode.sv`, and the emu.sv
routing mux were removed as cruft (branch `feature/remove-diagnostic-cruft`). The
normal VOB path is unchanged: `mpg_streamer → ps_stream_fifo → ps_demux → ac3_reframer
→ audio_ring → dvd_audio_decode → ac3_front → AUDIO_L/R`.

## A/V Sync toggle (scheduler free-run) — `O[13]`

⚠ **RENAMED 2026-09-07 (PR #66): `Audio Genlock` → `A/V Sync`** (`P1O[13],A/V Sync,On,Off`; bit
span unchanged, `wire av_freerun = status[13]` unchanged). The old name described a
mechanism that had been dead for two months and hid the one this bit actually controls.

**What it was.** Off forced `dvd_audio_decode.nco_trim` to 0 so the 48 kHz audio NCO
free-ran instead of being slewed to track the video-referenced STC — a diagnostic to tell
`av_sync`/governor *pacing* apart from `audio_ring` overflow and `ps_demux` filtering.
That reading died with the **NCO trim retirement** (2026-07-02, lip-sync v3): `emu.sv` now
declares `wire signed [21:0] dec_nco_trim = 22'sd0` unconditionally, so the trim is 0 with
the option On or Off. See `docs/av_sync.md` for why the slew is gone and must stay gone.

**What it is.** PR #63 (`docs/stc_freerun.md`) made the free-running 90 kHz STC the single
clock everything presents against, and wired this bit to the enable of that scheduling in
three places at once:

| Consumer | `sched_en`/`sync_armed` = 0 | Effect |
|---|---|---|
| `disp_sched.sv` (`sched_en_dec`, 2-FF into clk_dec) | `pic_due_r`/`next_due_r` forced 1 | every picture is due immediately ⇒ **the display free-runs at raster rate with no PTS pacing** — video, not audio |
| `dvd_audio_decode.sv` | `drain_en = draining \|\| !sched_en` | bypasses the PTS-scheduled drain start, plus `head_stale`, `head_catchup` and `pre_anchor_hold` |
| `iec61937_wrap.sv` (`sync_armed`) | `sync_en = sync_armed && stc_anchored` | passthrough free-runs, no A/V hold |

So Off is **"no A/V sync at all"**, for both media — not an audio-rate experiment. It is
strictly worse for playback and is not a fallback for a sync complaint.

**Why the row survives** (reviewed 2026-09-07): it is the only on-hardware way to remove
the whole scheduler as a variable, on a scheduler that is three days old at time of
writing. "Set A/V Sync Off and tell me if the disc plays" separates a scheduler fault from
a source/decode one in one message, where the alternative is a custom build and a tester
round-trip. It sits on the `P1,Debug` page, and the rename is what keeps a user from
reaching for it to *fix* something — the failure mode that got `Field Order` and the
`Analog CSync` `Stock` arm deleted before release (see `CLAUDE.md`).

## CSS mute (scrambled-source audio protection, 2026-08-06; density verdict 2026-09-08 — ✅ HW-CONFIRMED)

A CSS-encrypted rip (raw disc copy without decryption) still *plays* — the
IFOs and PES headers are never scrambled, so navigation works and the ~80%
unscrambled sectors show recognizable video — but the scrambled AC-3/DTS/LPCM
payloads decode to **loud static bursts**. Detection: `ps_demux` pulses
`pes_scrambled` for a PES whose `PES_scrambling_control != 0` (bits [5:4] of the
first PES-flags byte, checked with the `'10'` marker bits), and `pes_hdr_ok` for
every checkable PES header whether marked or not; `dvd/css_detect.sv` turns the
ratio into a sticky `css_scrambled` verdict. It survives jumps (ps_demux itself
resets on every `load_flush` via `pipe_rst_n` — a demux-local latch would flap and
leak pops at every menu jump/seek) and clears only on a fresh media mount, an
eject, or a core reset.

### ⚠ The rule was "4 markers, ever" until 2026-09-08, and it false-positived (issue #59, PR #76)

**The sentence that used to stand here said the `'10'` marker gate made "false
positives impossible". That is true of the marker BITS and false of the VERDICT,
and believing it is what let this ship.** A random byte passes `'10'` one time in
four, and three of those four carry a non-zero scrambling field — so any byte the
demux mistakes for a PES-flags byte is a marker with probability ~3/16. Two ways
that happens on a disc with nothing wrong with it:

1. **A lost frame.** Payload is length-counted, so a `00 00 01 E0` inside a payload
   is normally invisible. After a resync it is not: `S_HUNT` locks onto whatever
   byte-aligned start code it finds. The known hazards are the unhandled
   `PES_packet_length == 0` and a flush that does not land on a pack boundary.
2. **A marker that survived decryption.** libdvdcss (`src/libdvdcss.c`) clears the
   bits with `_p_buffer[0x14] &= 0x8f` — at a FIXED sector offset, and only in the
   non-zero-title-key branch; an all-zero key takes a branch that neither
   descrambles nor clears.

Either gives a handful of markers in a session. The old rule counted four, anywhere,
however far apart, and latched **permanently** — so a disc that plays perfectly lost
all of its audio and told its owner to go and install libdvdcss they did not need.
Multiple users reported it; the reported case was a physical disc being decrypted
correctly by `MiSTer_DVDcss`.

**Two changes fix it.**

**(1) `ps_demux` scores a marker only on a pack's own PES** (`pack_fresh`, armed at
the `0xBA` dispatch, spent in `S_PES_HDR_FLAGS1`). A DVD pack is 2048 bytes and
carries exactly one checkable PES — a NAV pack's `0xBB`/`0xBF` and a short PES's
`0xBE` padding never reach that state — so this loses no genuine marker, while a
header found after losing framing is by construction not preceded by a pack header.
⚠ It must be spent in `S_PES_HDR_FLAGS1` and **not** at the `S_HUNT` dispatch: the
dispatch is two states earlier, so clearing there clears the arm before the flags
byte is ever examined and nothing can score at all (measured — every bench arm read
zero). ★ `tools/css_scan.py` had **always** used this model while claiming to mirror
the RTL; the divergence between an oracle and its subject is what hid the bug, and
the RTL was changed to match the tool.

**(2) The verdict is a density, not a count** (`dvd/css_detect.sv`): a marker adds
one to a bucket, every `LEAK_CLEAN` clean headers repay one, and the verdict latches
at `LATCH_HITS`. The bucket therefore rises only while the scrambled *fraction*
exceeds `1/(LEAK_CLEAN+1)`. With `LEAK_CLEAN=64`, `LATCH_HITS=16` that knee is
**1.54 %**, measured by `bench/dvd/css_detect_tb.sv`:

| source | scrambled fraction | headers to latch |
|---|---|---|
| real CSS (FAIRYTOPIA, measured by `css_scan.py`) | 0.19 | **92** (~0.15 s of stream) |
| lightly scrambled | 0.05 | 289 |
| 0.03 | 0.03 | 543 |
| knee | 0.0154 | — |
| one marker per VOBU | ~0.004 | never |
| a handful per session | ≤1e-4 | never |

⛔ **Not "reset the counter after N consecutive clean headers"**, which is the
obvious form and was written first. It has no density interpretation, only a longest
tolerable gap — and **a VOBU is 200–500 packs**, so a stray produced once per VOBU
never sees an N=512 clean run and latches anyway. Raising N only moves the
resonance. Bench arm A5 is that adversary and finds the boundary by search.

⚠ **Below the knee the bucket is a random walk with negative drift, not a pinned
zero.** Measured at p=0.008 (about half the knee): still latched, after ~67,000
headers. The honest claim is "exponentially longer the further below p\*", and a
session is finite. The false positive being fixed is three orders of magnitude
lower. ⚠ The knee rests on **one** measured real-CSS density (19 %, FAIRYTOPIA — the
image is not in the local library). If a genuinely encrypted rip is ever measured
below ~5 %, raise `LEAK_CLEAN` (the knee moves as `1/(K+1)`) and move the bench's
knee band with it; the bench fails if the two disagree.

⚠ **This fix is mechanism-justified, not reproduced.** It closes both routes above
without knowing which one the reporter's disc took, and if it is the wrong one the
warning simply persists — nothing regresses, because the change only makes the
detector harder to trip. The acceptance test was therefore hardware, and it passed:
✅ **HW-CONFIRMED 2026-09-08** (`DVD_cssdensity_20260908_2056.rbf`) in **both**
directions — encrypted discs still detected and muted, unencrypted discs no longer
flagged. ⏳ Not separately reported, so still open: whether a static burst is
audible at mount on an encrypted disc now the latch takes ~92 checked headers
rather than ~21. If one ever is, the answer is **not** a smaller `LATCH_HITS` but a
provisional mute on the first marker that the bucket confirms or releases.

**Accepted trade:** a genuinely encrypted source below the 1.5 % knee no longer
mutes, so the user hears occasional ticks instead of silence. Below the knee fewer
than one audio frame in 60 is garbage, so the regime where a miss costs least is the
regime where the rule declines to act — against total, permanent, unexplained
silence on a disc that plays perfectly, which is what shipped.

While latched:

- **Decode path:** `AUDIO_L/R` forced to 0 at the emu output mux (the decoder
  keeps running and pacing normally — same STD behaviour, just silent out).
- **Passthrough path:** `iec61937_wrap.mute_i` — a muted codec frame is
  consumed through the normal `S_PA..S_PAD` walk (payload bytes still DRAIN
  from the ring at the burst cadence, keeping `rd_ptr` in step with the
  descriptors and the STD backpressure behaving exactly like normal playback)
  but every committed word is forced to 0 with `cur_nonpcm=0`: the receiver
  hears clean linear-PCM silence instead of raw scrambled bitstream. The sync
  hold is skipped while muted (silence either way; consuming prevents a
  backpressure wedge).
- **Video keeps playing** (green garbage) so the user can identify the disc,
  and the transport HUD shows the persistent `CSS ENCRYPTED` popup
  (`docs/transport_hud.md`).

Sim: **`bench/dvd/run_css.sh`** — `css_detect_tb` (10 arms; A1 asserts that the
DELETED rule latches on 4 strays 4096 headers apart while the new one does not, so
the issue #59 regression is an assertion and not a comment; mutation-checked, 8
mutations each caught) and `ps_demux_scram_tb` (8 arms; T2/T4 are RED against the
pre-fix demux, which `--red` rebuilds out of git). Also `iec61937_wrap_tb` TEST 8/8b
(mute = zero words + drain + consume, unmute resumes real bursts) and
`transport_hud_tb` T13 (popup text, menu exemption, slot yield/re-arm, clear).

## Demux backpressure vs a HELD decoder — `aud_bp_wd` (2026-09-08)

**Status: ✅ HW-CONFIRMED 2026-09-08** on Family Feud II, Weakest Link, Thayer's Quest and
Harry Potter (Hogwarts Challenge). Branch `fix/aud-bp-decode-hold`.

**Report.** On Harry Potter's player-selection screen the speech was **truncated**, and the
HUD timecode **sped up and jumped to the cell's end (00:01:19)** before stopping. Correct in
v0.4.0; introduced by PR #63.

★ **The racing timecode is what identified it.** A clock that runs fast means the PARSE
FRONT is running fast — nothing is throttling delivery — which points at flow control, not
at the audio decoder. Both symptoms are then one cause.

**Mechanism.** `emu.sv` re-arms the ring drain watchdog `aud_bp_wd` on `aud_frame_pop`, and
`frame_pop` only fires in the dispatcher's `S_POP` state. While the drain gate is shut the
48 kHz tick is withheld, the codec's PCM FIFO fills, `sink_ready` drops, `consume` stops and
the dispatcher stalls in `S_ROUTE` — **never reaching `S_POP`**. After ~1.24 s the watchdog
reads that deliberate hold as a wedged consumer and disengages demux backpressure
(`ps_aud_ready` is forced high). The shared stream then races through the cell at disc
speed: the ring overflows and drops whole frames (the truncated speech) while the parse
front runs away (the racing timecode, stopping when the cell's data is exhausted).

⚠ **Why PR #63 exposed it.** That PR moved the playback release from `stc_anchored` (the
parse front) to `disp_anchored` (the display's first tagged pickup), which is strictly
later — so on a screen whose display anchors slowly the gate stays shut past the watchdog.
The gate itself is older; what changed is how long it can stay shut.

★★ **The identical failure had already been found and fixed on the PASSTHROUGH path** —
the IEC 61937 lock flap, where a deliberate A/V-sync hold produced no pop, backpressure
stayed disengaged and the ring dropped ~25 frames/s for ~46 s (`docs/iec61937.md` "FLAP
ROOT CAUSE"). Its fix added `pass_hold_active` to the re-arm term, and its comment states
*"the decode path is unaffected (its stale-skip pops keep the watchdog fed the same way it
always was)"*. That was true while the gate opened at the parse front. **PR #63 made it
false, and the comment kept asserting it.** This fix is the decode-path twin of that term.

**Change.** One extra re-arm term:

```
else if (aud_frame_pop || (pass_mode && pass_hold_active)
                       || (aud_dec_en && dbg_aud_play_pts_valid && ~dbg_aud_draining))
```

⚠⚠ **The predicate is NOT a bare `~draining`, and that distinction is load-bearing.**
`draining` is 0 both when the gate is deliberately shut AND before the decode side has ever
produced anything — **including when it is dead**. Re-arming on that alone would pin
backpressure on, stall the shared demux and with it VIDEO: exactly the wedge that the
"unarmed until the first pop proves the decode side is alive" rule exists to prevent.
`play_pts_valid` is the proof of life — latched when a PTS-tagged frame has DISPATCHED — so
`play_pts_valid && ~draining` reads "audio arrived and the gate is holding it back". Bounded
the same way as the passthrough hold: the gate opens on the release compare or the ~2.5 s
`arm_timer` fallback. `aud_dec_en` is load-bearing too: with audio OFF the decode path never
drains and never pops.

⚠ **No sim gate, deliberately.** A bench case was written to pin the premise (a shut gate
starves `frame_pop`). It measured `frame_pop x0` with the gate shut — but its **control
failed**: pops did not resume when the gate reopened, so it could not distinguish "held"
from "dead", and it was removed rather than shipped as false proof. The premise rests on the
code (`frame_pop = (state == S_POP)`; a full PCM FIFO drops `sink_ready`, so `consume`
stops) plus the two measured HW symptoms. `emu.sv` has no bench, so the HW A/B is the gate —
the same standing recorded for `joy_eff` and the subpicture glue.

★ **Choosing the HW discs was a measurement, not a guess.** The failure needs a short cell
carrying speech that parks on a still, so `tools/dvd_probe_title_stills.py` was run across
the interactive library and ranked by title-domain still count: Family Feud II/III **936**
stills / 890 short cells, Weakest Link 76/76, Harry Potter 25/54, Thayer's Quest 20/55.
Family Feud is ~37× the density of the reported disc, so it fails within seconds if the
watchdog still mis-fires. ⚠ Atmosfear reads **0** title stills — its stills are
menu-domain, which is why it was the issue #65 repro and is NOT a test for this one.
⚠ A film disc is the negative control: this changes when backpressure engages on EVERY
disc, and the failure mode of an insufficient guard is the opposite symptom — a FREEZE of
picture and sound together, since backpressure stalls the shared demux and video with it.

## Open follow-ups
- DTS in-fabric + IEC 61937 bitstream → Digital I/O board (Toslink).
- LPCM: 20/24-bit @ 48 kHz stereo ✅ HW-CONFIRMED (PR fj#133, top-16 truncation for HDMI;
  see the LPCM section above). Still open: **96 kHz** (audio-NCO ÷2) and **multichannel**
  LPCM, plus the bit-perfect 24-bit-over-S/PDIF path (`docs/iec61937.md`).
- PTS-driven A/V sync correction (ps_demux `aud_pts`).
- Area/timing: ✅ addressed by the **M19 area pass** (2026-07-11, branch
  `feature/ac3-area-reduction` — see `docs/ac3_decoder_architecture.md` §4.11).
  The AC-3 subtree had grown to 9,378 ALMs (larger than the MPEG-2 decoder) and
  the spdif branch failed to route at 91% ALMs; M19 converted every remaining
  async-read array/LUT ROM (bit_allocation expc/dbc register file + baptab/
  latab/hthtab0, all imdct twiddle/schedule/window tables, audblk_parse staging)
  to sync-read M10K and folded the downmix multipliers into the shared DSP bank
  (−6 DSPs), PCM byte-identical at every step.
