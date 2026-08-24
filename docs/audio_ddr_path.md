# Audio HPS read path — DDR3 shared-memory design

> **⚠️ SUPERSEDED / RETIRED (2026-06-27).** Audio is now decoded **entirely in FPGA
> fabric** — see [`fabric_audio.md`](fabric_audio.md). This DDR3-ring transport and
> its HPS daemon (`hps/dvd_audio.c`) are no longer built into the core
> (`audio_ddr_pack`/`cdc_req_ack`/`audio_ddr_issue` dropped from `DVD.qsf`; the
> `ddr_arb` audio master is tied off). This document is kept for historical context.

**Status:** design locked 2026-06-25 (branch `feature/audio-ddr-path`). Supersedes the
`ioctl_upload` approach (PR fj#25, `dvd/audio_upload.sv`) — see "Why not ioctl_upload".

This is the **FPGA→HPS transport for compressed audio frames** so the HPS can decode
AC-3/DTS (liba52/libdca) or pass LPCM and play it. It replaces the read side of
`dvd/audio_ring.sv`'s consumer.

---

## The two halves, and why output is already solved

The audio problem has two directions. **Output is free; only input needs building.**

### Output (HPS PCM → HDMI) — provided by the MiSTer framework, no work needed
`sys/sys_top.v` already instantiates an `alsa` module (`sys/alsa.sv`): the HPS's stock
ALSA driver writes decoded PCM into a DDR3 buffer over a **dedicated SPI link**
(`aspi_*`, separate from the main command bus), the FPGA `alsa` module reads it via
`ddr_svc` (the `ram2` f2sdram port, `ch0`), and an audio mixer sums `alsa_l/alsa_r`
with the core's `core_l/core_r` → HDMI/I2S/analog/SPDIF (`sys_top.v` ~line 1582). **Any
userspace process can `snd_pcm_open("default")` + `snd_pcm_writei()` and it lands in HDMI
audio** — no Main_MiSTer fork, no command-bus contention. This is exactly the "ALSA dummy
device auto-mixed into HDMI" path described in `docs/audio.md`. So the HPS daemon's output
side is just standard ALSA writes.

### Input (FPGA compressed frames → HPS) — this document
`ps_demux` → `audio_ring` captures whole compressed frames in the FPGA. We must move them
to the HPS. That is what the rest of this doc designs.

---

## Why not `ioctl_upload` (PR fj#25, superseded)

`dvd/audio_upload.sv` (PR fj#25) bridged `audio_ring` to the MiSTer `ioctl_upload` channel.
Research into Main_MiSTer killed that path for a *streaming, stock-binary* use:

1. **The FPGA command/SPI bus is single-master with no locking** (`fpga_io.cpp` maps the
   HPS lightweight bridge at `0xFF000000` via `/dev/mem` and drives GPO registers with no
   mutex). A second process cannot share it with the running `MiSTer` binary.
2. **`ioctl_upload` handling is hardcoded per-core *inside* the single shared `MiSTer`
   binary** (`user_io_poll()` → `UIO_CHK_UPLOAD` (cmd `0x3C`) → a core handler like
   `c64_save_cart()` → `user_io_set_upload()` + `user_io_file_rx_data()`). There are no
   per-core executables (`Makefile` `PRJ=MiSTer`, compiles `support/*/*.cpp` into one
   binary). So `ioctl_upload` audio would require **forking and shipping a custom `MiSTer`
   binary** that users must install and keep rebased on upstream.

DDR3 shared memory avoids both: it is the framework's own idiom for bulk FPGA→HPS data
(the video framebuffer / ascal scaler live in DDR3 windows read via `/dev/mem`), and a
standalone daemon can `mmap` a distinct physical window with no bus contention and no fork.

PR fj#25's `audio_upload.sv` is retired, but its BRAM-snapshot framing (blob header + frame
table describing `{type,len}` per frame) is reused as the in-DDR3 layout below.

---

## f2sdram port reality (why we share `ram1`)

`sys/sysmem_lite` wires **three** f2sdram command ports, all in use:
- **`ram1`** (64-bit) → the core's `DDRAM` (the MPEG-2 decoder, via `dvd/mem_shim_burst.sv`).
- **`ram2`** (64-bit) → `ddr_svc`, read-only, serving the `alsa` PCM + palette reads.
- **`vbuf`** (128-bit) → the `ascal` scaler.

A 4th port needs regenerating the HPS Qsys (out of scope, like the kernel recompile). So the
audio writer **shares `ram1`** via a thin priority arbiter (decoder wins; audio writes slip
into idle command cycles). This keeps **all changes in `dvd/`** — no `sys/` framework
surgery (contrast: extending `ddr_svc` for writes would mean editing `sys/ddr_svc.sv` +
`sys/sys_top.v` + threading new ports through `emu`).

**Risk is low:** the old "f2sdram read-return reliability fault" diagnosis was a **red
herring** — the real black-screen bug was a display-side picture split (resample emitting
macroblock-padded height; fixed in `dvd/resample_addrgen.v`, see
`docs/history.md`). The `ram1`/`mem_shim_burst`/`DDRAM` path is proven-reliable
on hardware. Audio traffic is tiny (~200 KB/s LPCM worst case ≈ 25k 64-bit words/s; one word
per ~3600 clk @ 90 MHz), so the decoder is never starved.

---

## DDR3 memory map (audio window)

`DDRAM_ADDR` (`ram1_address[28:0]`) is a **64-bit-word** address; byte address = word << 3.
The audio writer drives `DDRAM_ADDR` **directly** (it does NOT go through `mem_shim`'s
`{7'b0011000, addr[21:0]}` formula), so `AUD_WORD_BASE` must be a **full word address**.

> **Window choice (corrected after the first HW test).** The decoder's f2sdram window is
> bytes `0x30000000`..`0x31FFFFFF` (32 MiB; the `{7'b0011000,addr[21:0]}` formula's fixed
> top bits) — proven backed and HPS-visible because video works. Two bounds pin the audio
> window inside it: the MP@ML decoder's top address is the OSD buffer end ≈ word `0x78000`
> (3.75 MiB), and DDR3 is proven backed up to word `0x1c0000` (14 MiB, where the HD map's
> VBUF writes committed on HW). So the audio window sits at **byte `0x30800000`** (8 MiB
> into the window) = **word `0x6100000`** = `{7'b0011000, 22'h100000}` — above the decoder,
> below the proven-backed ceiling, HPS-readable, and not Linux RAM.
> **DO NOT** use a bare offset like `0x0700000` (a dropped-digit version of `0x07000000`):
> that resolves to byte `0x03800000` ≈ 56 MiB — **inside Linux RAM** — and the FPGA writes
> there corrupted the running OS and froze the board on the first hardware test.

```
byte 0x30800000  MAILBOX (64 B, FPGA write-only)        (= FPGA word 0x6100000)
  +0x00  magic           u32  0x41445644  ("DVDA" LE)
  +0x04  write_seq       u32  committed-frame counter (HPS polls this; bumped LAST)
  +0x08  write_bytes     u32  total payload bytes ever written (monotonic)
  +0x0C  overflow_count  u32  frames dropped by audio_ring (lost before DDR)
  +0x10  data_ring_bytes u32  size of the data ring region
  +0x14  desc_count      u32  number of descriptor slots (power of two)
  +0x18.. reserved
byte 0x30800800  DESCRIPTOR RING  (desc_count × 8 B), indexed by seq & (desc_count-1)
  +0  type   u16   0=AC3 1=DTS 2=LPCM 3=unknown
  +2  len    u16   exact payload bytes of this frame
  +4  offset u32   byte offset of this frame within the data ring
byte 0x30810000  DATA RING  (≈ 960 KiB), frame payloads, each 8-byte aligned
```

**Coherency without FPGA reads (write-only FPGA):** for each frame the FPGA writes (1) the
payload bytes into the data ring, (2) the descriptor slot, then (3) increments `write_seq`
**last**. f2sdram preserves write order on a single port, so when the HPS observes a new
`write_seq` the descriptor and payload are already committed. The HPS keeps its own
`read_seq`; if `write_seq - read_seq > desc_count` it detects an overrun (FPGA lapped it),
logs it, and resyncs to the newest frames. No read-back of an HPS pointer is needed, so the
FPGA only ever **writes** DDR3 (the always-reliable direction). On data-ring wrap, the
oldest unread bytes are overwritten — an audio glitch, acceptable for v1 (1 MiB ≈ 20 s of
AC-3, so the HPS only needs to keep up loosely).

---

## RTL decomposition (all in `dvd/`)

`audio_ring` (clk_sys, 27 MHz) → **CDC** → DDR write issuer (clk_mem, 90 MHz) → **arbiter**
→ `DDRAM`. Three new modules + emu replumb:

1. **`dvd/ddr_arb.sv`** — priority arbiter on the `DDRAM` command channel. Inputs: decoder
   master (from `mem_shim_burst`) + audio master (write-only, burstcount 1). Decoder has
   absolute priority; audio is granted only when the decoder isn't issuing a command that
   cycle. Read-response channel (`DDRAM_DOUT/_READY`) routes to the decoder only (audio does
   no reads). Wraps inside the existing `O4` BIST ownership mux in `emu.sv`. *(Build first —
   most isolated, fully sim-testable.)*

2. **`dvd/audio_ddr_pack.sv`** (clk_sys) — drains `audio_ring`'s read side (byte stream +
   descriptor FIFO), packs each frame's bytes into 64-bit words, computes the data-ring
   offset, and emits a sequence of write commands `{word_addr[28:0], data[63:0], be[7:0]}`
   for: payload words → descriptor word → mailbox `write_seq` word. Pushes them into an
   async command FIFO. Tracks `write_bytes`, `write_seq`, ring wrap, and copies
   `audio_ring.overflow_count` into the mailbox.

3. **async command FIFO** (clk_sys → clk_mem) — small gray-pointer dual-clock FIFO carrying
   `{word_addr, data, be}` entries. (Use a simple proven async FIFO; ~16–32 deep is plenty
   given the rate.)

4. **`dvd/audio_ddr_issue.sv`** (clk_mem) — pops FIFO entries and presents them to
   `ddr_arb` as the audio master (assert write + addr/data/be, wait for grant+!waitrequest,
   advance). Pure write pump.

`emu.sv`: instantiate `audio_ddr_pack` on the `audio_ring` read side (replacing the parked
`out_ready=1'b0`), the async FIFO, `audio_ddr_issue` in clk_mem, and `ddr_arb` between
`mem_shim_burst`/`audio_ddr_issue` and the `DDRAM` port (inside the `O4` BIST mux).

Each module gets a `bench/dvd/*_tb.sv` (repo convention). A chain TB
(`audio_ring`+pack+FIFO+issue+arb against a DDRAM behavioral model) verifies the full ring
write sequence and coherency ordering.

---

## HPS daemon (separate, after the FPGA side; lives in `hps/`)

Standalone process, runs alongside stock `MiSTer` (no fork):
1. `open("/dev/mem")`, `mmap` physical `0x30800000`, 1 MiB.
2. Verify mailbox magic; init `read_seq = write_seq`.
3. Poll `write_seq`. For each new seq: read `descriptor[seq & (desc_count-1)]` →
   `{type,len,offset}`, copy `len` bytes from the data ring (handle wrap), advance `read_seq`.
   Detect/log overrun if `write_seq - read_seq > desc_count`.
4. Decode per `type`: AC-3→liba52, DTS→libdca, LPCM→strip header + endian-swap (see
   `docs/audio.md`). Output stereo S16LE.
5. `snd_pcm_writei("default", ...)` → framework mixes to HDMI.
6. A/V sync (PTS) is a later phase; `aud_pts` not carried yet.

Poll cadence: AC-3 frame = 32 ms, DTS = ~10.7 ms; a ~2–5 ms poll keeps latency low at
negligible CPU.

---

## Build order / checklist

- [x] `dvd/ddr_arb.sv` + `bench/dvd/ddr_arb_tb.sv` (incl. gapped-burst no-interleave)
- [x] `dvd/cdc_req_ack.sv` (single-entry req/ack CDC, chosen over an async FIFO) + TB
- [x] `dvd/audio_ddr_pack.sv` + chain TB
- [x] `dvd/audio_ddr_issue.sv` (verified in the chain TB)
- [x] emu.sv replumb: pack → cdc → issue → ddr_arb between mem_shim_burst and DDRAM,
      gated by `O5,Audio DDR Write` (default Off; off during the O4 BIST). Parse- and
      port-checked; full gate is the Quartus build.
- [x] `hps/dvd_audio.c` daemon: mmap + ring read + ALSA. LPCM implemented; AC-3/DTS
      behind `HAVE_A52`/`HAVE_DCA` (liba52/libdca). `--probe` mode for bring-up.
      Host-compiles clean; `hps/Makefile` + `hps/README.md` included. NOT yet run on HW.
- [x] Close PR fj#25 as superseded
- [ ] **Hardware bring-up (next):** load core with O5 On; `./dvd_audio --probe` →
      expect magic "DVDA" + write_seq climbing; then `./dvd_audio` for LPCM playback.
      Confirm video unaffected (toggle O5 to A/B test the arbiter).
- [ ] liba52/libdca for the target; A/V sync (carry PTS into the ring); 20/24-bit LPCM.
```
```
