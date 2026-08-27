# Audio Architecture: MiSTer DVD Player Core

> **⚠️ UPDATED (2026-06-27): audio is now decoded IN FABRIC.** AC-3 (`dvd/ac3/*` via
> `ac3_front`+`pcm_out`) and LPCM (`dvd/lpcm_unpack.sv`) are decoded in the FPGA and
> drive `AUDIO_L/R` directly — the HPS-decode path described below is **retired**.
> See [`fabric_audio.md`](fabric_audio.md). The codec/PES details in this file
> (substream IDs, frame sizes, IEC 61937 constants) are still accurate reference.
> DTS was dropped in fabric; **Path B (IEC 61937 passthrough over optical S/PDIF) is now
> IMPLEMENTED** — `dvd/iec61937_wrap.sv` + `dvd/spdif_pass.sv`, toggle `O6` Audio Out.
> Milestone A (AC-3 passthrough) is sim-verified with a HW gate pending; DTS (Milestone B,
> a DTS reframer) is next. Full design: [`iec61937.md`](iec61937.md).

## Overview

The DVD core uses a **dual-path audio strategy** (Option 3), mirroring how mid-2000s
consumer DVD players worked:

- **Path A — HDMI (primary):** AC-3/DTS decoded to stereo PCM on the HPS ARM core,
  written to the MiSTer ALSA dummy device, auto-mixed into HDMI audio output.
  Works on any TV or monitor with no extra hardware.

- **Path B — S/PDIF optical (IMPLEMENTED, Milestone A):** the undecoded AC-3/DTS
  frames are wrapped in IEC 61937 and biphase-encoded onto the S/PDIF pin for AV
  receivers that decode AC-3/DTS natively. `dvd/iec61937_wrap.sv` (burst formatter +
  async FIFO) + `dvd/spdif_pass.sv` (IEC 60958 encoder with the non-PCM bit set), toggle
  `O6`. See [`iec61937.md`](iec61937.md).

  **Optical is NOT exclusive to the Digital I/O board.** The framework routes its
  S/PDIF signal to *two* destinations (both fed by the same internal `spdif` net in
  `sys/sys_top.v`): the Digital board's TOSLINK via `AUDIO_SPDIF`, **and** the shared
  SD-detect/SPDIF pin `SDCD_SPDIF` (`PIN_AH7`) that the **Analog I/O board's combo
  3.5mm jack** exposes as a mini-TOSLINK optical output. So the Analog board's optical
  jack is a valid passthrough target — same biphase S/PDIF signal, different connector.

  **The real constraint is format, not connector.** Stock MiSTer's `audio_out`
  (`sys_top.v` ~line 1546) generates `spdif` from **PCM** (`core_l/core_r`); there is
  **no compressed/IEC 61937 passthrough path** in the framework. DD/DTS passthrough
  therefore requires us to (1) build `iec61937_wrap.sv` to frame the *undecoded*
  AC-3/DTS elementary frames (preamble + data-type code, IEC 60958 non-PCM channel-status
  bit set), and (2) drive the S/PDIF pin ourselves, bypassing/replacing the framework's
  PCM encoder. We already have the pre-decode compressed frames available
  (`ps_demux → audio_ring`), so no extra capture plumbing is needed.

  Caveats: the specific Analog board revision must actually populate the optical
  transmitter behind the combo jack (official Analog 6.1 does; some clones/older revs
  don't); the sink must be an AVR/soundbar optical *input* (a TV's optical port is
  usually an output).

---

## Codec Detection

Audio stream type is identified by the `substream_id` byte — the first byte
of the PES payload for `stream_id = 0xBD` (private stream 1):

```c
typedef enum { AUDIO_AC3, AUDIO_DTS, AUDIO_LPCM, AUDIO_UNKNOWN } audio_type_t;

audio_type_t detect_audio_type(uint8_t substream_id) {
    if (substream_id >= 0x80 && substream_id <= 0x87) return AUDIO_AC3;
    if (substream_id >= 0x88 && substream_id <= 0x8F) return AUDIO_DTS;
    if (substream_id >= 0xA0 && substream_id <= 0xA7) return AUDIO_LPCM;
    return AUDIO_UNKNOWN;
}
```

DVD audio stream selection should also be read from the IFO file — the IFO
specifies which substream IDs correspond to which language audio tracks.
For v1, default to the first AC-3 stream (0x80) or first DTS stream (0x88).

---

## AC-3 (Dolby Digital)

### Format
- Most common DVD audio format (5.1 or 2.0)
- Bitrate: up to 448 kbit/s
- Frame: 1536 audio samples @ 48kHz = **32ms per frame**
- Max frame size: 1536 bytes

### HPS Decode: liba52
liba52 is a lightweight, GPL-2.0-or-later AC-3 decoder in C. Runs at ~3–5% of one
Cortex-A9 core for a DVD-rate stream.

```c
#include <a52dec/a52.h>
#include <a52dec/mm_accel.h>

// Initialize (call once)
a52_state_t *state = a52_init(0);  // 0 = no SIMD acceleration flags needed

// Per-frame decode (called for each AC-3 frame from ring buffer)
int decode_ac3_frame(uint8_t *frame_data, int frame_len,
                     int16_t *pcm_out, int *pcm_samples) {
    int flags = A52_STEREO;       // downmix to stereo
    int sample_rate, bit_rate;
    sample_t level = 1.0;

    if (a52_syncinfo(frame_data, &flags, &sample_rate, &bit_rate) == 0)
        return -1;  // not a valid AC-3 frame

    flags = A52_STEREO | A52_ADJUST_LEVEL;
    a52_frame(state, frame_data, &flags, &level, 0);

    // AC-3 produces 6 blocks of 256 stereo samples = 1536 total
    *pcm_samples = 0;
    for (int block = 0; block < 6; block++) {
        if (a52_block(state) != 0) return -1;
        sample_t *samples = a52_samples(state);

        // Convert float samples to int16 and interleave L/R
        for (int i = 0; i < 256; i++) {
            pcm_out[(*pcm_samples * 2)]     = (int16_t)(samples[i] * 32767.0);
            pcm_out[(*pcm_samples * 2) + 1] = (int16_t)(samples[256 + i] * 32767.0);
            (*pcm_samples)++;
        }
    }
    return 0;
}
```

### IEC 61937 Wrapper (future S/PDIF)
- Standard: IEC 61937-3
- Burst-info `Pc` value: `0x0001`
- Frame period: 1536 samples @ 48kHz

---

## DTS

### Format
- Less common than AC-3 on DVD, but present on many titles (especially music DVDs,
  concert videos, and some action films)
- Almost never decoded internally by DVD players — always bistreamed to receiver
- Bitrate on DVD: up to 1536 kbit/s
- Frame (DVD core stream): 512 audio samples @ 48kHz = **~10.7ms per frame**
  (DTS sends frames 3× more frequently than AC-3)

### HPS Decode: libdca
libdca (also known as libdts) is the DTS equivalent of liba52 — GPL-2.0-or-later,
similar API pattern.

```c
#include <dca.h>

dca_state_t *state = dca_init(0);

int decode_dts_frame(uint8_t *frame_data, int frame_len,
                     int16_t *pcm_out, int *pcm_samples) {
    int flags = DCA_STEREO;
    int sample_rate, bit_rate, frame_length;

    // Sync and parse frame header
    int hdr_flags = dca_syncinfo(state, frame_data, &flags,
                                  &sample_rate, &bit_rate, &frame_length);
    if (hdr_flags == 0) return -1;

    flags = DCA_STEREO | DCA_ADJUST_LEVEL;
    sample_t level = 1.0;
    dca_frame(state, frame_data, &flags, &level, 0);

    // DTS has a variable number of blocks
    int num_blocks = dca_blocks_num(state);
    *pcm_samples = 0;
    for (int block = 0; block < num_blocks; block++) {
        if (dca_block(state) != 0) return -1;
        sample_t *samples = dca_samples(state);
        // interleave L/R similarly to AC-3 example above
    }
    return 0;
}
```

### IEC 61937 Wrapper (future S/PDIF)
- Standard: IEC 61937-5
- Burst-info `Pc` value: `0x000B` (DTS type I/II/III)
- Frame period: 512 samples @ 48kHz
- Use **wrapped** form (not padded) — required by all compliant AV receivers

**Important:** The higher frame rate (512 vs 1536 samples) means your HPS audio
loop runs 3× more frequently for DTS. Design the audio ring buffer and HPS read
loop to handle both cadences cleanly.

---

## LPCM (Linear PCM)

### Format
- Raw uncompressed audio — the simplest case
- Typically 48kHz or 96kHz, 16-bit or 24-bit, 2–8 channels
- Common on older DVD releases, some region-specific discs, and music DVDs

### Implementation
No decode library needed. Read LPCM PES payload, strip the 3-byte audio header
(that precedes actual sample data in DVD LPCM streams), and write directly to ALSA.
Handle byte-order: DVD LPCM is big-endian, ALSA expects little-endian.

```c
// DVD LPCM PES private header (3 bytes before samples):
// Byte 0: substream_id (0xA0–0xA7)
// Byte 1: number of audio frames
// Byte 2: offset to first audio frame
// Byte 3: audio emphasis / mute / reserved / quantization / sample freq / channels

// After stripping header, swap bytes for little-endian output:
for (int i = 0; i < sample_count; i++) {
    int16_t sample = (frame_data[offset + i*2] << 8) | frame_data[offset + i*2 + 1];
    pcm_out[i] = sample;  // now little-endian
}
```

---

## ALSA Output

MiSTer exposes a dummy ALSA device that mixes HPS audio directly into the
HDMI audio stream. Write stereo 16-bit PCM at 48kHz.

```c
#include <alsa/asoundlib.h>

snd_pcm_t *alsa_init(void) {
    snd_pcm_t *handle;
    snd_pcm_hw_params_t *params;

    snd_pcm_open(&handle, "default", SND_PCM_STREAM_PLAYBACK, 0);
    snd_pcm_hw_params_alloca(&params);
    snd_pcm_hw_params_any(handle, params);
    snd_pcm_hw_params_set_access(handle, params, SND_PCM_ACCESS_RW_INTERLEAVED);
    snd_pcm_hw_params_set_format(handle, params, SND_PCM_FORMAT_S16_LE);
    snd_pcm_hw_params_set_channels(handle, params, 2);           // stereo
    unsigned int rate = 48000;
    snd_pcm_hw_params_set_rate_near(handle, params, &rate, 0);
    snd_pcm_hw_params(handle, params);

    return handle;
}

void alsa_write_frames(snd_pcm_t *handle, int16_t *pcm, int sample_count) {
    snd_pcm_sframes_t written = snd_pcm_writei(handle, pcm, sample_count);
    if (written == -EPIPE) {
        snd_pcm_prepare(handle);  // recover from underrun
    }
}
```

---

## IEC 61937 Frame Format (Reference for Future S/PDIF)

```
Byte offset  Content
──────────── ───────────────────────────────────────────────
0–1          Pa = 0xF872  (sync word, IEC 60958 preamble)
2–3          Pb = 0x4E1F  (sync word)
4–5          Pc = burst-info (data type, error flag, subtype)
             AC-3: 0x0001 | DTS: 0x000B
6–7          Pd = length of burst payload in BITS (not bytes)
8…           Payload: raw AC-3 or DTS frame bytes (big-endian)
…            Padding: zero-fill to complete the frame period
             AC-3: pad to 1536 × 4 bytes = 6144 bytes total
             DTS:  pad to 512 × 4 bytes = 2048 bytes total
```

The non-PCM channel status bit (bit 1 of IEC 60958 channel status word) **must**
be set. If it isn't, the receiver treats the payload as PCM and outputs noise.
This is the most common cause of "bitstream passthrough produces static."

---

## Audio Summary Table

| Codec | Substream | Library | HPS CPU | Frame period | S/PDIF Pc |
|-------|-----------|---------|---------|--------------|-----------|
| AC-3 | 0x80–0x87 | liba52 | ~3–5% | 32ms (1536 samples) | 0x0001 |
| DTS | 0x88–0x8F | libdca | ~4–6% | ~10.7ms (512 samples) | 0x000B |
| LPCM | 0xA0–0xA7 | none | ~1% | variable | N/A |
