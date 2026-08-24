# Prior art: how MiSTer CD cores hand audio/disc processing to the HPS

**Why this doc exists.** This DVD core decodes AC-3/DTS on the HPS (ARM) and feeds PCM
back to the FPGA — a partition some might question as "not really FPGA." It isn't a
compromise: it is the *same* pattern every MiSTer CD-based core already uses. This doc
records exactly how that precedent is built in the upstream `MiSTer-devel/Main_MiSTer`
HPS binary, with verified file/function names, so the architecture choice in
[audio_ddr_path.md](audio_ddr_path.md) has a concrete reference to point at — and so the
one place our transport *must* differ is understood.

All paths below are in **`MiSTer-devel/Main_MiSTer`** (the single HPS userspace binary),
verified against `master` (fetched 2026-06-25). Representative core: **PCE-CD**
(`support/pcecd/`); MegaCD / Saturn / NeoGeo-CD / PSX / 3DO follow the same shape
(`support/{megacd,saturn,neogeo,psx,3do}/`).

---

## The decode that happens on the ARM: libchdr (FLAC)

Discs are stored as **CHD** images. Inside a CHD, the **CD-DA audio tracks are
FLAC-compressed**. The FPGA cannot decompress FLAC, so the HPS does it:

- `lib/libchdr/libchdr_chd.c` — CHD hunk reader/decompressor.
- `lib/libchdr/libchdr_flac.c` — **FLAC decoder, runs on the Cortex-A9.** This is the
  genuine "HPS does the codec the FPGA can't" step, directly analogous to liba52/libdca
  here. (Data tracks use zlib/LZMA via `libchdr_huffman.c`/`libchdr_bitstream.c`.)
- `support/chd/mister_chd.{cpp,h}` — MiSTer's thin wrapper over libchdr:
  - `mister_load_chd(filename, toc_t*)` — open CHD, fill the table of contents.
  - `mister_chd_read_sector(chd, lba, dataoffset, secoffset, len, dest, hunkbuf, &hunknum)`
    — decompress one CD sector into `dest`, with **single-hunk caching** (`hunkbuf`/`hunknum`
    avoid re-decompressing the same hunk for adjacent sectors).
  - `toc_t` (in `cd.h`) holds tracks, frame/sector sizes, `chd_hunksize`.

Net: after `mister_chd_read_sector()`, the ARM holds a **raw 2352-byte CD-DA PCM sector**
(588 stereo 16-bit samples) — decompressed in software. (BIN/CUE images skip the decode:
the audio is already raw PCM, so the HPS just `FileRead`s it.)

**Correction to an earlier verbal claim:** the FPGA does *not* receive re-encoded audio,
and the HPS does *not* run liba52-style decode for CD — the HPS work is the **FLAC/CHD
decompression**, and what crosses to the FPGA is **raw PCM sectors**. The shape is still
identical to our case (compressed-on-disk → ARM decompresses → FPGA gets PCM → FPGA mixes);
only the codec differs (FLAC vs AC-3).

---

## The FPGA⇄HPS handoff: request-driven, over the SPI command + download channels

The CD drive is *emulated on the HPS* and serves the FPGA on demand. Two directions:

### 1. FPGA → HPS: command requests (SPI `user_io` command bus)
`support/pcecd/pcecd.cpp : pcecd_poll()` is called every frame from the framework's
`user_io_poll()` (the main loop). It reads pending CD commands from the core:

```c
spi_uio_cmd_cont(UIO_CD_GET);   // core posts a command (READ6 / PLAY / PAUSE / seek)
... spi_w() ... EnableIO()/DisableIO();
```

and posts status back with `SendStatus()` → `spi_uio_cmd_cont(UIO_CD_SET); spi_w(...)`.

### 2. HPS → FPGA: bulk sector data (the `ioctl_download` channel, index-selected)
The actual sector bytes are pushed via a `SendData` callback. For PCE-CD it is wired in
`pcecd_set_image()` as `pcecdd.SendData = pcecd_send_data`, and:

```c
int pcecd_send_data(uint8_t* buf, int len, uint8_t index) {
    user_io_set_index(index);      // pick the destination "file" channel in the core
    user_io_set_download(1);       // enter download mode
    user_io_file_tx_data(buf, len);// stream bytes to FPGA over SPI
    user_io_set_download(0);
    return 1;
}
```

This is the **same `ioctl_download` path used for ROM loading**, just with a per-core
*index* selecting which sink in the core receives it. PCE-CD uses three indices —
`PCECD_DATA_IO_INDEX` (2048+2 B data sectors), `PCECD_CDDA_IO_INDEX` (2352+2 B audio
sectors), `PCECD_SUBCODE_IO_INDEX` (98+2 B Q-subchannel).

### The drive state machine
`support/pcecd/pcecdd.cpp : pcecdd_t::Update()` drives it, polled from `pcecd_poll()`:
- `PCECD_STATE_READ` → `ReadData()` (via `mister_chd_read_sector`) → `SendData(..., DATA)`
- `PCECD_STATE_PLAY` → `ReadCDDA()` (decompress + **endian byte-swap** to the core's order)
  + `ReadSubcode()` → `SendData(..., CDDA/SUBCODE)`, sector by sector
- `PCECD_STATE_PAUSE` → keeps subcode flowing
- Seek latency is modelled (`get_cd_seek_ms`) so timing matches a real drive.

The FPGA core ingests the CD-DA PCM and **mixes it into its own audio output** — exactly
the role our FPGA audio mixer plays for HPS-decoded AC-3.

---

## Why this matters for us — and the one piece we can't copy

**What it validates:** "HPS decodes/decompresses audio the FPGA can't, FPGA mixes the
PCM" is a first-class, blessed MiSTer pattern, not a hack. Our AC-3/liba52 → PCM → mixer
path is the same architecture with a different codec.

**The transport we cannot reuse, and why:** the CD cores reach the FPGA through the SPI
`user_io` command bus + `ioctl_download` channel **because they are compiled *into* the
single `MiSTer` binary** (`pcecd_poll()` is literally a branch of `user_io_poll()`). That
SPI bus is single-master and unlocked (`fpga_io.cpp` drives it via `/dev/mem` with no
mutex). Our AC-3 decoder runs as a **separate standalone daemon** (`hps/dvd_audio.c`) so
it can ship without forking/rebasing the upstream `MiSTer` binary — and a second process
**cannot share** that SPI bus. That is precisely why our handoff uses **DDR3 shared
memory** instead (FPGA writes a ring; daemon `mmap`s and polls), documented in
[audio_ddr_path.md](audio_ddr_path.md) → "Why not ioctl_upload". 

Direction also differs as a consequence:
| | CD cores (PCE-CD …) | This DVD core |
|---|---|---|
| Who decodes | HPS (libchdr/FLAC) | HPS (liba52/libdca) |
| FPGA gets | raw PCM sectors | raw PCM (after decode) |
| Transport | SPI `ioctl_download` (`SendData`) | DDR3 shared-memory ring |
| Trigger | **FPGA requests** (`UIO_CD_GET`), HPS serves | **FPGA pushes** writes; HPS polls `write_seq` |
| Code lives in | the one `MiSTer` binary | standalone `hps/dvd_audio.c` daemon |
| FPGA does reads? | yes (SPI is bidirectional) | no (write-only to DDR3 — the reliable direction) |

So: take the CD cores as proof the **partition** is correct and idiomatic; take their
in-binary SPI transport as the thing a standalone daemon must replace — which is the DDR3
design already chosen here.

---

## Source map (for follow-up reading)

- libchdr (HPS-side decode): `lib/libchdr/libchdr_chd.c`, `lib/libchdr/libchdr_flac.c`
- CHD wrapper / TOC: `support/chd/mister_chd.{cpp,h}`, `cd.h`
- Representative CD drive: `support/pcecd/pcecdd.cpp` (drive FSM), `support/pcecd/pcecd.cpp`
  (`pcecd_poll`, `pcecd_send_data` — the FPGA glue)
- Same pattern, other cores: `support/megacd/megacdd.cpp`, `support/saturn/saturncdd.cpp`,
  `support/neogeo/neogeocd.cpp`, `support/psx/psx.cpp`, `support/3do/3docdd.cpp`
- Framework handoff primitives: `user_io.cpp` (`user_io_file_tx_data`, `user_io_set_index`,
  `user_io_set_download`, `spi_uio_cmd*`), and the FPGA side in our tree
  [sys/hps_io.sv](../sys/hps_io.sv). Official channel reference:
  https://mister-devel.github.io/MkDocs_MiSTer/developer/hps_io/
- Our analogous output mixer (HPS PCM → DDR3 → mix → HDMI): [sys/alsa.sv](../sys/alsa.sv)
