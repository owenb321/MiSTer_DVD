# System Architecture: MiSTer DVD Player Core

## Hardware Platform

- **Board:** Terasic DE10-Nano
- **FPGA:** Intel Cyclone V (5CSEBA6U23I7)
  - ~49,000 logic elements
  - ~6MB on-chip block RAM
  - DDR3 SDRAM via HPS (shared with ARM)
- **HPS:** Dual-core ARM Cortex-A9 @ 800MHz, 1GB DDR3
- **Output:** HDMI via ADV7513 on-board chip
- **Storage:** MicroSD card (ISO files), USB storage (game files)

---

## CPU Budget Reality

When a MiSTer core is running, the HPS is divided as follows:

```
Core 0: ~100% — MiSTer framework
         (FPGA event monitoring, SD card I/O, USB HID,
          HDMI config, menu system, core loading)

Core 1: ~free — available for your DVD code
         (UDF parse, IFO navigation, sector feeding,
          audio decode, ALSA write, A/V sync)
```

This is why MPEG-2 video decode **must** stay on the FPGA. Software MPEG-2 decode
on one Cortex-A9 core at 800MHz is not achievable at DVD resolution in real time.
AC-3/DTS audio decode uses ~3–5% of that core — completely fine.

---

## Full Data Flow

```
SD Card (disc.iso)
        │
        ▼
┌───────────────────────────────────┐
│ HPS Linux (C program — hps/)      │
│                                   │
│  libdvdcss                        │
│  dvdcss_open("disc.iso")          │  ← transparent CSS decryption
│  │                                │
│  ▼                                │
│  UDF filesystem parse (udf.c)     │  ← finds VIDEO_TS/VTS_xx_x.VOB
│  │                                │
│  ▼                                │
│  IFO/PGC navigation (ifo_parse.c) │  ← title/chapter ordering
│  │                                │
│  ▼                                │
│  dvdcss_read(DVDCSS_READ_DECRYPT) │  ← decrypted 2048-byte sectors
│  │                                │
│  ▼                                │
│  Sector ring buffer → f2sdram     │  ← feeds FPGA at high bandwidth
└───────────────────────────────────┘
        │
        ▼  (Avalon-MM f2sdram bridge)
┌───────────────────────────────────┐
│ FPGA Fabric                       │
│                                   │
│  mpg_streamer.sv (UPSTREAM)       │  ← reads sectors from ring buffer
│  │                                │    via sd_* block device interface
│  ▼                                │
│  ps_demux.sv (YOU BUILD)          │  ← parses pack/PES headers
│  │                    │           │
│  ▼ video PES          ▼ audio PES │
│  MPEG-2 decoder       audio_ring  │
│  (UPSTREAM)           .sv         │
│  │                    │           │
│  ▼                    ▼           │
│  Frame buffer         f2sdram     │
│  (DDR3 via            bridge      │
│  mem_shim.sv)         │           │
│  │                    │           │
└──┼────────────────────┼───────────┘
   │                    │
   ▼                    ▼
MiSTer video         HPS reads audio frames
framework            │
(pixel clock,        ├── AC-3 → liba52 → stereo PCM
 HDMI output)        ├── DTS  → libdca → stereo PCM
   │                 └── LPCM → direct
   ▼                      │
HDMI video out            ▼
                     ALSA dummy device
                          │
                          ▼
                     MiSTer audio mixer
                          │
                          ▼
                     HDMI audio out (stereo PCM)
```

---

## Key Upstream Modules (do not modify)

### `mpg_streamer.sv`
Reads raw sectors from the SD card using MiSTer's high-bandwidth `sd_*` block device
interface, bypassing the slow `ioctl` byte-by-byte path. Feeds a continuous byte stream
to the downstream decoder. **Your PS demuxer replaces the direct connection between
this module and the MPEG-2 decoder input.**

### `mem_shim.sv`
Custom DDR3 memory interleaver. A 2-state pipelined FSM with a Skid Buffer handles
concurrent dual-clock FIFO reads/writes across MiSTer's `f2sdram` Avalon-MM bridge.
Uses TrustZone-compliant address mapping to pack a 15.5MB HD frame buffer within
MiSTer's restrictive 24MB CMA window without causing Linux `waitrequest` deadlocks.
Do not touch this — it took significant debugging to get right.

### `rtl/` (mpeg2fpga core by Koen De Vleeschauwer)
The full MPEG-2 video decoder: VLC/Huffman entropy decoding, dequantization, IDCT,
motion compensation, frame buffer management. Originally from 2007, ported to MiSTer
by mrchrisster. This is the hard part — it's solved.

---

## New Modules to Build

### `dvd/ps_demux.sv` — Program Stream Demuxer (BUILD FIRST)

Sits between `mpg_streamer.sv` output and the MPEG-2 decoder input.

MPEG-2 Program Stream packet structure (VOB file):
```
Pack Header:     0x000001BA  (start code)
                 pack_header data (14 bytes)

PES Packet:      0x000001xx  (start code, xx = stream_id)
  stream_id:
    0xE0         = video (route to MPEG-2 decoder)
    0xBD         = private stream 1 (audio — check substream_id)
    0xBE         = padding (discard)
    0xB9         = end code

  For stream_id = 0xBD, first byte of PES data payload = substream_id:
    0x80–0x87   = AC-3 audio
    0x88–0x8F   = DTS audio
    0xA0–0xA7   = LPCM audio
```

Key signals to expose:
```systemverilog
module ps_demux (
    input  logic        clk, rst_n,

    // Input: byte stream from mpg_streamer
    input  logic [7:0]  in_byte,
    input  logic        in_valid,
    output logic        in_ready,

    // Output: video elementary stream → MPEG-2 decoder
    output logic [7:0]  vid_byte,
    output logic        vid_valid,
    input  logic        vid_ready,

    // Output: audio frames → HPS ring buffer
    output logic [7:0]  aud_byte,
    output logic        aud_valid,
    output logic [3:0]  aud_type,   // 0=AC3, 1=DTS, 2=LPCM
    input  logic        aud_ready,

    // PTS timestamps for A/V sync
    output logic [32:0] vid_pts,
    output logic        vid_pts_valid,
    output logic [32:0] aud_pts,
    output logic        aud_pts_valid
);
```

**Status:** implemented and wired into the pipeline (`dvd/emu.sv`). Passes its module
testbench (`bench/dvd/ps_demux_tb.sv`) and the integration testbench
(`bench/dvd/ps_chain_tb.sv`) in Icarus Verilog simulation.

**Design decisions (locked in during implementation):**

1. **MPEG-2 pack header is variable length, not a flat 14 bytes.** After the `0x000001BA`
   start code there are 6 bytes SCR + 3 bytes program_mux_rate + 1 byte whose low 3 bits
   are `pack_stuffing_length`, followed by that many stuffing bytes. The FSM skips 9 fixed
   bytes, reads the 10th to get the stuffing count, then skips the stuffing.
2. **The private_stream_1 sub-header is stripped before audio reaches the ring buffer.**
   For `stream_id 0xBD`, the first payload byte is the `substream_id`; AC-3/DTS then have a
   3-byte sub-header (frame count + first-access-unit pointer) and LPCM a 6-byte sub-header.
   These are dropped so the HPS (liba52 / libdca) receives raw frames with intact boundaries.
3. **`aud_type` encoding is 0=AC-3, 1=DTS, 2=LPCM, 3=unknown** (2 bits). Note this differs
   from the 4-bit sketch above; the implemented port is `logic [1:0] aud_type` plus an
   `aud_frame_start` strobe pulsed on the first byte of each audio frame.
4. **1:1 combinational passthrough with real backpressure.** `in_ready` follows the active
   output's ready (`vid_ready`/`aud_ready`) in the data-forwarding states; everywhere else
   it is high. Counters and the start-code shift register advance only on actual consumption
   (`in_valid && in_ready`), so a downstream stall can never double-count a byte.
5. **`PES_packet_length` is the master per-packet byte counter.** Every byte from the PES
   optional header onward decrements it; the packet ends (returns to start-code hunting)
   when it reaches zero. **Limitation:** `PES_packet_length == 0` (unbounded video PES,
   legal per spec) is not yet handled — fine for DVD VOBs, which always set a length. The
   future fix is to fall back to start-code hunting for the zero-length case.
6. **Raw elementary streams are auto-detected and passed through (added after the
   on-hardware bring-up below).** If the *first* start code is a video-layer code
   (`<= 0xB8`: picture `0x00`, slices `0x01–0xAF`, user `0xB2`, seq-header `0xB3`, ext
   `0xB5`, seq-end `0xB7`, GOP `0xB8`) instead of a `0xBA` pack, the stream is a bare
   elementary stream with no PS wrapper. `ps_demux` then reconstructs the consumed
   `00 00 01 <code>` preamble (states `S_ES_EMIT` → `S_ES_PASS`) and forwards every byte
   unchanged to the video output. A `ever_seen_pack` latch locks the demuxer into PS mode
   once a `0xBA` pack appears, so this never false-triggers on PS content. This was the
   fix for the black-screen bring-up: on hardware *every* test file (the repo's reference
   `tools/streams/*.mpg`, and ffmpeg-produced `.m2v` extracts) turned out to be an
   elementary stream beginning `00 00 01 B3`, which the original PS-only demuxer silently
   discarded — starving the decoder. Covered by `bench/dvd/ps_demux_es_tb.sv`.
7. **System / nav / padding streams are skipped by length, not hunted past (DVD VOB
   robustness).** Any `stream_id >= 0xBB` that isn't a pack (`0xBA`), video (`0xE0`) or
   audio (`0xBD`) — i.e. system header `0xBB`, program_stream_map `0xBC`, padding `0xBE`,
   `private_stream_2` / NV_PCK navigation packs `0xBF`, and un-routed MPEG audio
   (`0xC0–0xDF`) / extra video (`0xE1–0xEF`) PES — is consumed in full by reading its
   2-byte PES length (`S_SYS_LEN_HI`/`S_SYS_LEN_LO`) and discarding exactly that many
   payload bytes (`S_DISCARD`). The motivation is DVD VOBs: they interleave `0xBF` NV_PCK
   packs whose PCI/DSI payload routinely contains `00 00 01` byte patterns. The old default
   (keep hunting on any unknown `stream_id`) would let such a pattern false-trigger a start
   code and desync the demuxer mid-stream. Skipping by declared length steps cleanly over
   the whole packet so the next *genuine* start code re-syncs. `0xB9` (program end) has no
   length field and is still simply hunted past. Covered by `bench/dvd/ps_demux_nav_tb.sv`.

#### Pipeline integration & the `ps_stream_fifo` input adapter

`ps_demux` is spliced between `mpg_streamer` and `mpeg2video` inside `dvd/emu.sv`
(a copy of `rtl/emu.sv`; the upstream file is left untouched and the `.qsf`
repointed at `dvd/emu.sv`):

```
mpg_streamer ─▶ ps_stream_fifo ─▶ ps_demux ─▶ mpeg2video
```

**Why the FIFO is necessary — an interface impedance mismatch:**

- `mpg_streamer` and `mpeg2video` speak a **valid + busy** protocol. `mpg_streamer`
  pulses `stream_valid` for a single cycle and does **not** hold the byte until it
  is accepted; it only gates *new* reads on a registered `busy`. Because of its
  internal `read_valid_pipe` stage, one byte is still in flight the cycle after
  `busy` asserts.
- `ps_demux` speaks a **valid + ready** protocol and assumes `in_byte`/`in_valid`
  persist until `in_ready` is high (it stalls `in_ready` during payload
  forwarding when the active output is backpressured).

Driving `mpg_streamer.busy = !ps_demux.in_ready` directly would drop the
in-flight byte whenever `ps_demux` stalls. `dvd/ps_stream_fifo.sv` is a small
(DEPTH=16) first-word-fall-through FIFO that absorbs the one-cycle write pulses
and presents a proper held handshake to `ps_demux`. Its `almost_full` (asserted
with ≥2 free slots) drives `mpg_streamer.busy`, guaranteeing room for the
in-flight byte.

**The output edge needs no buffer.** `ps_demux.vid_ready` is wired to
`~core_busy`. `mpeg2video.busy` is an *almost-full* signal (it has slack), and
`ps_demux` holds `vid_valid` until consumed, so the held-handshake → write-enable
conversion is purely combinational: `mpeg2video.stream_valid = vid_valid & ~core_busy`.

**Resulting backpressure chain:** `core_busy` stalls `ps_demux` video forwarding
→ the input FIFO fills → `almost_full` stalls `mpg_streamer`. Verified end-to-end
by `bench/dvd/ps_chain_tb.sv`, which toggles `core_busy` every cycle (worst case)
and confirms the forwarded video elementary stream matches the expected payloads
byte-for-byte with no drops.

**Parked until later:** the audio path (`aud_*`) and PTS outputs are left
unconnected; `aud_ready` is tied high so audio PES never stalls the shared
`in_ready` and blocks video. Audio is discarded until `audio_ring.sv` exists.

### `dvd/audio_ring.sv` — Audio Frame Buffer  *(built, sim-verified)*

A ring buffer holding audio frames extracted by `ps_demux.sv`, with frame
boundaries kept intact (liba52/libdca expect complete frames).

> **Implementation differs from the original sketch below.** It is a
> **single-clock (clk_sys) FIFO**, *not* a dual-clock FIFO read over `f2sdram`:
> the chosen HPS transport is the MiSTer `ioctl_upload` channel, which lives in
> the clk_sys domain — so there is no clock-domain crossing and no Avalon-MM
> slave. `aud_ready` is tied HIGH and overflow drops a whole frame so audio can
> never backpressure the shared video stream. Frame boundaries are carried by a
> separate per-frame descriptor FIFO (`{length, type}`). Full rationale and the
> length-deferred-finalize limitation are in CLAUDE.md →
> "audio_ring.sv — Status & design decisions". Not yet wired into `emu.sv`.
>
> *Original sketch (superseded):* "A simple dual-clock FIFO / ring buffer … HPS
> reads frames out via the `f2sdram` bridge using the same Avalon-MM pattern as
> the existing video path."

### `dvd/iec61937_wrap.sv` — IEC 61937 Wrapper (future)

For future S/PDIF bitstream output when the user adds a Digital I/O board.
Design it now as a clean module even if not yet connected.

```
IEC 61937 frame structure (for AC-3):
  Pa = 0xF872  (sync word 1)
  Pb = 0x4E1F  (sync word 2)
  Pc = 0x0001  (data type: AC-3) / 0x000B (DTS)
  Pd = length in bits
  payload = raw AC-3/DTS frame (big-endian)
  padding = zeros to fill 1536-sample period (AC-3) or 512-sample (DTS)
```

---

## HPS Software Modules

### `hps/udf.c` — UDF Filesystem Parser
Parse UDF Volume Descriptor Sequences to locate `VIDEO_TS/` directory.
Find `VTS_XX_X.VOB` files and return their LBA (Logical Block Address) ranges.
Can be adapted from existing open-source UDF parsers (libdvdread does this).

**Recommendation:** Use **libdvdread** instead of writing from scratch.
libdvdread + libdvdcss together give you UDF parsing, IFO parsing, and CSS
decryption in one well-tested stack used by VLC.

### `hps/ifo_parse.c` — IFO Navigation
Parse `VIDEO_TS.IFO` and `VTS_XX_0.IFO` to determine:
- Title/chapter structure (PGC — Program Chain)
- VOB file ordering for the main feature
- Audio stream mappings (which substream ID is the primary audio)

For v1: skip menus entirely, just find the longest PGC (main feature) and
play it linearly. IFO menu navigation can come later.

### `hps/audio_decode.c` — Audio Decode
```c
// AC-3 via liba52
a52_state_t *state = a52_init(0);
a52_syncinfo(frame_data, &flags, &sample_rate, &bit_rate);
a52_frame(state, frame_data, &flags, &level, 0);
for (int block = 0; block < 6; block++) {  // 6 blocks × 256 = 1536 samples
    a52_block(state);
    sample_t *pcm = a52_samples(state);
    alsa_write(pcm, 256);
}

// DTS via libdca (identical pattern, different library calls)
dca_state_t *state = dca_init(0);
// ... similar block structure
```

### `hps/alsa_out.c` — ALSA Output
Write decoded stereo PCM to MiSTer's ALSA dummy device. The MiSTer kernel
mixes this automatically into the HDMI audio stream.
```c
snd_pcm_t *handle;
snd_pcm_open(&handle, "default", SND_PCM_STREAM_PLAYBACK, 0);
// configure: 48000 Hz, S16_LE, 2 channels
snd_pcm_writei(handle, pcm_buffer, frame_count);
```

---

## A/V Sync Strategy

Each AC-3 frame = 1536 samples @ 48kHz = 32ms of audio.
Each MPEG-2 video frame = 33.3ms @ 29.97fps or 40ms @ 25fps.

**Phase 1 (simple):** Dual frame counters with drift correction.
- FPGA exposes a video frame counter register readable by HPS
- HPS tracks audio frames written to ALSA
- HPS adjusts ALSA write rate slightly to maintain sync

**Phase 2 (proper):** PTS-based sync using timestamps extracted by `ps_demux.sv`.
VOB streams carry PTS (Presentation Time Stamps) in PES headers. Pass these
through the ring buffer alongside frame data; HPS uses them for precise sync.

---

## Resource Budget (Cyclone V, ~49K LEs)

| Subsystem | Est. LEs | Status |
|---|---|---|
| MPEG-2 video decoder (mpeg2fpga) | ~20,000–25,000 | ✅ existing |
| MiSTer framework / hps_io | ~2,000 | ✅ existing |
| mem_shim / DDR3 controller | ~1,500 | ✅ existing |
| mpg_streamer | ~500 | ✅ existing |
| ps_demux (new) | ~800–1,200 | 🔨 build |
| audio_ring buffer (new) | ~400 | 🔨 build |
| iec61937_wrap (future) | ~300 | 📋 planned |
| **Total estimated** | **~26,000–31,000** | fits comfortably |

The design fits well within the Cyclone V's capacity with room to spare.
