# Implementation Roadmap: MiSTer DVD Player Core

> Speculative "might-be-interesting" ideas that are **not** committed here live in
> [`docs/experiments.md`](experiments.md). Move an item over once it's decided.

## Guiding Principles

- **★ Self-contained `.rbf` — NO HPS-side daemon (project owner's hard requirement).**
  Everything ships in the FPGA bitstream; the user does not want to run a Linux/ARM daemon
  alongside the core. This has been **proven feasible** for the pieces once assumed to need
  the HPS: audio decode is IN FABRIC (`dvd/dvd_audio_decode.sv` + `dvd/ac3/*`), and DVD
  filesystem/title navigation is IN FABRIC (`dvd/dvd_iso_reader.sv`) because the MiSTer `sd_*`
  block interface is random-access (the framework serves any `sd_lba`, like a `.vhd` core).
  So the remaining nav/IFO/seek/angle work (Phases 7–9) targets **in fabric** too, NOT the HPS
  Option-A/B daemon paths sketched in the older phases below (those are kept only as historical
  "superseded" context). The one PC-side step that stays off-core is **CSS decryption** — the
  disc is ripped to a decrypted `.iso` on a PC (MakeMKV/dvdbackup), which is a one-time
  workflow step, not a running daemon.
- Never modify `sys/` (upstream); `rtl/` edits are now allowed (rule relaxed 2026-06-24, see
  CLAUDE.md) — mark them `// DVD-FORK`. Prefer new `dvd/` modules.
- Test every new module in simulation before touching hardware.
- Each phase produces a testable result on real hardware.

---

## Phase 0 — Environment Setup (Week 1)

**Goal:** Working build environment, upstream core running on hardware.

### Tasks
- [ ] Fork `mrchrisster/MiSTer_MPEG2` → your GitHub account as `MiSTer_DVD`
- [ ] Add upstream as remote: `git remote add upstream https://github.com/mrchrisster/MiSTer_MPEG2.git`
- [ ] Install Quartus **17.0.2** with Cyclone V device support
- [ ] Install VS Code extensions: `mshr-h.verilog`, `teros-technology.teroshdl`, `ms-vscode.cpptools`
- [ ] Set up `.vscode/settings.json` (see CLAUDE.md)
- [x] Rename `.qpf` / `.qsf` / `.qdf` revision from `mpeg2fpga` → `DVD` (done)
- [ ] Compile in Quartus — verify bitstream generates without errors
- [ ] Load on DE10-Nano via USB Blaster, test with a sample `.mpg` file
- [ ] Create directory structure: `dvd/`, `hps/`, `bench/dvd/`
- [ ] Verify lsmod / kernel: `find /lib/modules -name 'sr_mod.ko'` (expect: not found — confirm ISO-only strategy)

**Checkpoint:** Upstream MPEG-2 player works on hardware. You can see video from a `.mpg` file.

---

## Phase 1 — Program Stream Demuxer (Weeks 2–4)

**Goal:** VOB data correctly split into video and audio elementary streams.

### Background
The existing core feeds raw `.mpg` bytes directly to the MPEG-2 decoder.
VOB files are MPEG-2 Program Streams where video, audio, and subtitle data are
interleaved in packets. The demuxer separates them.

### RTL Tasks
- [x] Write `dvd/ps_demux.sv` — see architecture.md for signal definition
  - Parse pack headers (`0x000001BA`)
  - Parse PES headers, extract `stream_id` and `substream_id`
  - Route `0xE0` (video) to MPEG-2 decoder input
  - Route `0xBD` (audio) to audio output port with `aud_type` tag
  - Discard padding (`0xBE`) and handle end code (`0xB9`)
  - Extract PTS from PES headers (33-bit value, split across 5 bytes)
- [x] Write `bench/dvd/ps_demux_tb.sv` + `bench/dvd/ps_chain_tb.sv`
  - Hex-dump a real VOB: `od -An -v -tx1 VIDEO_TS/VTS_01_1.VOB > sample.hex`
  - Feed bytes through testbench, verify routing decisions
  - Check PTS extraction against known values
  - Verified on a real Matrix VOB: 50,395 video bytes, AC-3 frames @ 32 ms
    PTS spacing, identical output under worst-case backpressure
- [x] Wire `ps_demux.sv` into `emu.sv` (copied emu.sv to `dvd/emu.sv`; added
  `dvd/ps_stream_fifo.sv` to bridge mpg_streamer's pulse interface to ps_demux's
  held handshake). Compiles in Quartus, configures on hardware, OSD reached.

### HPS Tasks
- [ ] Modify `hps/main.cpp` to open an ISO instead of a raw `.mpg` file
- [ ] Stub out audio ring buffer read loop (just log audio frame type/size for now)

**Checkpoint:** Video still plays correctly (same quality as Phase 0). Console log
shows audio frames being correctly identified as AC-3/DTS/LPCM with correct sizes.

### ✅ Bring-up resolved — black screen was the demuxer eating elementary streams

**Root cause (found on hardware via the on-screen debug overlay, `dvd/debug_overlay.sv`):**
the core booted to the OSD with valid, locked 720×480/27 MHz/59.94 Hz video sync, but a
black picture. Step-by-step overlay instrumentation (DDR3 read/write counters → feed-chain
byte counters → start-code counters → a first-8-bytes capture) showed the decoder was
*starved*: it inits then sits idle because no video bytes reach it. The capture revealed
**every test file began `00 00 01 B3` (a video sequence header) — they were all bare
elementary streams, not program streams** (the repo's `tools/streams/*.mpg` are ES, and the
"matrix.mpg" on the SD card was an ES/`.m2v` extract too). The PS-only `ps_demux` only
forwards bytes inside a `0xE0` PES, which an ES has none of, so it discarded the entire
stream (`e0_count` stayed 0 — not corruption, just no PES headers).

**Fix:** `ps_demux` now auto-detects a raw ES (first start code is a video-layer code
`<= 0xB8`) and passes it straight through (`S_ES_EMIT` → `S_ES_PASS`), reconstructing the
`00 00 01 <code>` preamble. See architecture.md decision 6; covered by
`bench/dvd/ps_demux_es_tb.sv`. The debug overlay stays in the tree behind the
`O2,Debug Overlay` toggle (default off).

**Diagnostic instrument worth keeping:** `dvd/debug_overlay.sv` renders pipeline counters as
on-screen block-bit rows — no UART cable needed. Toggle it on to inspect the feed/decode
path on hardware.

**Note:** the ES fix got video *bytes* to the decoder, but **playback still does not work** —
it exposed a deeper blocker (next section). Toggle the overlay on and you can see the demux
now forwards video (`vidout` row live) while the decoder stays jammed.

---

### ✅ RESOLVED / HISTORICAL — the HPS DDR3 bridge hang (NOT the current front; do not "start here")

> **⚠️ STALE HEADER, kept for the record.** This was the Phase-1 bring-up blocker. It is
> **long resolved** — the core has decoded correct-color SD/PAL video on real hardware for
> many build iterations, and every dated feature from 2026-07-05 on (ISO nav, PGC timeline,
> subpicture, transport, DVD menus, DVD-VM) is HW-confirmed on the DE10-Nano, which would be
> impossible if DRAM were still dead. The memory path now runs on the HPS f2sdram burst bridge
> (`dvd/mem_shim_burst.sv`). Treat this section as history. The genuine "what's next" is the
> **Remaining follow-ups / interactive-DVD phases** further down, summarised in CLAUDE.md.

**(historical) This core had never been verified to decode video on real hardware** (it was an
unproven fork of `mrchrisster/MiSTer_MPEG2`). On a real DE10-Nano all three cores (the DVD core
+ both upstream `releases/MPEG2_*.rbf`) showed valid, locked 720×480/27 MHz/59.94 Hz video
**sync** but a **black picture**.

**Diagnosis (via the overlay, airtight):** `mem_shim` hangs in state **`0xD` = WRITE/WAIT**
(see `rtl/mem_shim.sv:243`). It issues a write to the HPS DDR3 (`DDRAM`) and `DDRAM_BUSY`
(`ddr3_waitrequest`) sticks high after only ~3 writes. DRAM is effectively dead, so the
decoder can't stage its bitstream in the `VBUF` DRAM buffer, issues **zero reads**
(`rdreq = 0`), its input fills (`vbw_full`), it jams `busy`, and `ps_demux` stalls behind it.
Same root cause in all three cores → none can use DRAM, so none can decode.

**Prime suspect:** `mem_shim` maps every core address to physical DDR3 window `0x30000000`
via the `{7'b0011000, addr[21:0]}` "DENSE" formula (`rtl/mem_shim.sv:71-75,129`). If the
running MiSTer **main**/Linux doesn't reserve the FPGA DDR3 window there, the first writes
land in a region the f2sdram bridge refuses and it deadlocks — exactly the symptom.

**Address-window analysis (done — window is almost certainly NOT the fault):**
Traced the full `DDRAM` path. The core's port is wired to the stock **`ram1`** f2sdram port
(`sys/sys_top.v` → `f2sdram_safe_terminator #(64,8)` → `cyclonev_hps_interface_fpga2sdram`
in `sys/sysmem.sv`) — identical infrastructure to every MiSTer core. The `{7'b0011000,
addr[21:0]}` formula resolves to **byte 0x30000000** (top 7 bits = 24 → 24×32 MB), the exact
same encoding `sys/arcade_video.v` uses for its `0x24000000` buffer (`7'b0010010` = 18×32 MB).
0x30000000 sits above the scaler buffer (`ascal RAMBASE 0x20000000` + 8 MB) and inside the
1 GB DDR3 — a valid, standard, non-colliding window. **Decisive evidence the address is fine:**
the bridge *accepts* ~3 writes (`wr_count` only counts `write && !waitrequest`) before sticking
— an unmapped window would refuse from transaction #1. So the fault is on the
**handshake/flow** side (f2sdram command FIFO fills and never drains), not address decode.

**Next steps (resume here):**
1. [x] **DDR3 stall probe added** (`feature/ddr3-stall-probe`) — overlay rows **12–15** now
   capture, straight off the `DDRAM` port (clk_mem domain, in `dvd/emu.sv`): the exact stuck
   byte address (rows 12/13 — expect `0x3000_00xx` if in-window), the longest consecutive
   BUSY-held run (row 14 — `0xFFFF` = permanent deadlock), and a status word (row 15:
   [15]=stalled-write [14]=stalled-read [13]=latched [12]=saturated [7:0]=transactions
   accepted before the first stall). Toggle `O2,Debug Overlay`. **Read these rows back to
   confirm:** in-window addr + saturated counter ⇒ address theory dead, bridge-liveness fault.
2. [x] **Hardware probe done — root cause found, fix applied.** Overlay readout: stuck addr
   `0x30000E10` (in-window → address theory dead), stall counter saturated (permanent), and
   the decisive pair **`rd_count` 62 > `rsp_count` 61** with `shim_state` = `D` (WRITE/WAIT).
   So the f2sdram bridge *accepted* a read then **never returned its `readdatavalid`**, and the
   decoder's next op — a write — is wedged behind it. The Quartus timing report shows the
   `clk_mem`→`mem_shim`→`DDRAM` datapath **meets timing** (the only negative-slack paths are the
   known false PLL/`h2f` infra paths), so this is not a clock/closure issue. Root cause: the
   original `mem_shim` FSM issues a new command (the write) while a read's response is still
   outstanding — the proven MiSTer DDR3 users (`sys/ddr_svc.sv`, `ascal`) always *drain a read's
   response before the next command*. **Fix:** copied `rtl/mem_shim.sv` → `dvd/mem_shim.sv`
   (qsf now points there; `rtl/` untouched) and added a single-outstanding-read serializer
   (`read_outstanding` gate in S_IDLE). Build: `DVD_memshim_serialize_read`. **Verify on
   hardware:** if it decodes, fixed; if still black, re-read overlay rows 0-2 — `rd==rsp` now
   means the serializer took and the wedge is elsewhere (→ step 3); `rd>rsp` still means a read
   is being dropped at the bridge regardless.
3. [x] **Serializer tested on hardware — it removed the hard deadlock but exposed the real
   defect.** After the fix: `shim_state` = `0` (no longer `D`), `stall_cycles` = 48 (no longer
   `FFFF`), `sdram_busy` no longer pinned — the WRITE/WAIT wedge is GONE. **But `rd_count` 63 >
   `rsp_count` 62 still.** With the serializer only one read is ever in flight, so this proves
   the f2sdram bridge **accepts a read then silently returns no `DDRAM_DOUT_READY`** — command
   interleaving was never the root cause, it only *amplified* it into a hard wedge. The drop is
   intermittent (one bad read after dozens of good ones), the fingerprint of a **read-return
   reliability/timing fault in the bridge**. Decoder starves → `watchdog_rst` fires →
   `frame_cnt` frozen → black. The serializer stays (genuine improvement).
4. [x] **ROOT CAUSE FOUND — the HD memory map puts VBUF in unbacked DRAM.** The read-response
   watchdog (overlay rows 12-15) captured the dropped read at **`0x30E00000` every run** (low
   bits jittered within ~1 KB; row 14 = `FFFF`, row 15 = 1 drop). `0x30E00000 − 0x30000000 =
   0xE00000 = exactly 14 MiB`, and `rtl/mpeg2/mem_codes.v` has `` `define MP_AT_HL `` enabled →
   **`VBUF` (the decoder's bitstream buffer) = word `0x1c0000` = 14 MiB**. The decoder writes the
   bitstream into VBUF (writes are accepted and silently swallowed — no response needed) then
   **reads it back for VLD, and that read at 14 MiB never returns** because VBUF lands outside
   the backed f2sdram region. Frame-store reads (all < 12 MiB) work. Writes-work-reads-hang is
   the textbook signature of an unbacked address. Power-cycle dependence matches the
   `f2sdram_safe_terminator` warning that a broken bridge state persists across soft reloads.
5. [x] **FIX — switch the core to the MP@ML memory map** (correct for SD DVD, 720x480 ≤ ML's
   768x576). Put VBUF at word `0x070000` = 3.5 MiB, whole map < 3.75 MiB, inside the region.
   `mem_codes.v` is an `` `include `` header found via `SEARCH_PATH`, so (keeping `rtl/`
   untouched) added `dvd/mem_override/mem_codes.v` (an MP@ML copy with `MP_AT_HL` disabled) and
   listed `SEARCH_PATH dvd/mem_override` **before** `rtl/mpeg2` in the qsf. Verified with iverilog
   that the override yields `VBUF=0x070000`. Build `DVD_memshim_mpaml`. **Verify on hardware:**
   video should decode; if still black, the watchdog's dropped address tells us — `0x30380000`
   (= ML VBUF) means even 3.5 MiB is unbacked (region smaller than expected); unchanged
   `0x30E00000` means the SEARCH_PATH override didn't take (Quartus used rtl's HD header).
6. [x] **MP@ML tested — relocated VBUF correctly but did NOT fix it; the address was never the
   cause.** Dropped read moved to `0x30380258` = `VBUF(0x070000)+0x4B` (override took). Clean
   overlay (after fixing an earlier wr/rd misread): `wr_count` ~32,837 (the decoder fills the
   entire ML VBUF — **all writes commit**), `rd_count` 57 vs `rsp_count` 56 (**off by one** —
   serializer working perfectly, sim-proven by `bench/dvd/mem_shim_serialize_tb.sv`), `shim_state`
   = `E` (a write held in the skid behind the blocked read), row14=FFFF, 1 drop. So: **writes all
   succeed, reads mostly succeed, then one single read to a just-written, backed VBUF location
   never returns `readdatavalid` — independent of where VBUF lives.** That's a read-after-write /
   read-return reliability fault in the f2sdram path, not an address/mapping bug.
7. [x] **Make `mem_shim` survive a dropped read (fix attempt + decisive test).** Added a read
   give-up timeout to `dvd/mem_shim.sv`: if a read gets no response within `RD_TIMEOUT`=2047
   cycles (>> normal latency; the dropped one waited 65535+), synthesize a zero response and
   clear `read_outstanding` so the decoder keeps running instead of starving. Sim confirms it
   releases ~1 read per window and stays serialized. Build `DVD_memshim_rdtimeout`. **Verify on
   hardware:** occasional drops ⇒ decoder limps to (glitchy) **first-ever video** = datapath
   alive, intermittent read drops; still black + row-15 drop-count skyrockets ⇒ reads fail
   systematically ⇒ next is a standalone DRAM self-test (BIST) driving the f2sdram directly,
   decoupled from the decoder, to settle whether reads work at all on this main.
8. [x] **Timeout/give-up + retry both tested — neither engaged, and `shim_state` revealed why.**
   Give-up (zero-fill) and retry (re-issue) both built; on hardware the decoder stayed black,
   `rd_count` stayed exactly +1 over `rsp_count` (no retry inflation), drop count stayed 1.
   `shim_state` read back **`B` = {READ, saved_valid, state=1 (S_WAIT)}** with `sdram_busy`
   (waitrequest) **HIGH** and everything frozen. So the read is stuck **UNACCEPTED** — the
   f2sdram bridge pins `waitrequest` high and refuses the command. `read_outstanding` is only
   set *after* acceptance, so the response-timeout never even starts — that's why no
   `mem_shim` timeout fired. **This is a bridge wedge (waitrequest stuck high), the same class
   as the very first symptom; no `mem_shim`-level workaround can fix a bridge that won't accept
   commands.** The serializer + timeout/retry stay in (they're correct and harmless) but can't
   address this.
9. [x] **Standalone DRAM self-test (BIST) built** — `dvd/dram_selftest.sv`, O3 toggle. Drives
   DDRAM directly (muxed in `dvd/emu.sv`, decoder + `mem_shim` bypassed), writes 512 sequential
   words to the ML VBUF region then reads them back comparing a unique per-word pattern. Every
   command has a waitrequest-acceptance timeout and every read a response timeout so it can't
   hang; FSM verified by `bench/dvd/dram_selftest_tb.sv`. Build `DVD_dramtest`. **Toggle O3 on,
   read overlay rows 12-15** (all expect `0x200`=512): row12=writes accepted, row13=reads
   accepted, row14=reads returned, row15=[15]done [14]wedged [13]write-phase [12]no-response
   [7:0]mismatches. This settles it cleanly: writes<512 ⇒ write wedges; reads-accepted<512 ⇒
   READ wedges (= the decoder symptom, in isolation ⇒ fundamental f2sdram fault on this main);
   all 512 + 0 mismatches ⇒ f2sdram is fine and the fault is `mem_shim`/decoder-specific.
10. Pending on BIST outcome: if the f2sdram itself wedges on a clean burst, the next move is to
   compare against the proven MiSTer `ddram.sv` controller pattern and/or confirm whether
   upstream `mrchrisster/MiSTer_MPEG2` ever decoded on hardware and on which main.

---

### ⚠️ After DDR3 works: real DVD VOB (program stream) playback

Blocked behind the DDR3 fix above (a VOB can't decode while DRAM is dead). A true multiplexed
DVD VOB (program stream with audio + nav packs) has not been tested end-to-end. Open items:

1. **File selector filters out `.VOB`.** The core's `CONF_STR` (in `dvd/emu.sv`)
   only advertised `mpg`/`mp2`, so the MiSTer file browser hid `.VOB` files.
   - [x] Added `VOB` to the `CONF_STR` extension list
     (`"S0,MPG M2V VOB,Load Video;"`) so VOBs are selectable directly (no rename
     needed). Branch `feature/real-vob-playback`.
2. **Renaming `.VOB`→`.mpg` then loading caused the resolution to re-negotiate
   repeatedly and never showed video.** Likely causes to investigate:
   - [x] **Navigation packs — FIXED in RTL (sim-verified; HW test pending).** DVD
     VOBs interleave `private_stream_2` packets (`stream_id 0xBF`, NV_PCK /
     PCI+DSI). `ps_demux` used to keep hunting on any unrecognised `stream_id`; a
     `00 00 01` byte pattern in a nav-pack payload could false-trigger a start
     code and desync the stream. Now any `stream_id >= 0xBB` that isn't
     pack/video/audio (nav `0xBF`, padding `0xBE`, system header `0xBB`, PSM
     `0xBC`, un-routed audio/video PES) is skipped by its 2-byte
     `PES_packet_length` via new states `S_SYS_LEN_HI`/`S_SYS_LEN_LO`→`S_DISCARD`.
     Covered by `bench/dvd/ps_demux_nav_tb.sv` (embeds a fake `00 00 01 E0` inside
     a nav payload and proves only the real video PES reaches the output); the
     real-Matrix-VOB `ps_chain_tb` still passes byte-for-byte (50,395 bytes).
   - [ ] **Multi-sequence / repeated sequence headers.** Each VOB cell can carry
     its own sequence header; the repeated resolution change suggests the decoder
     is re-initialising per cell or on corrupted headers. Confirm the demuxed
     video ES is a clean, continuous elementary stream (dump `vid_byte` to SD /
     UART and compare against a known-good `.m2v` extracted with `ffmpeg`).
   - [ ] **Unbounded video PES (`PES_packet_length == 0`).** Documented
     limitation in `ps_demux` — rare in VOBs but verify the test file doesn't use
     it; add the start-code-hunt fallback if needed.

---

## Phase 2 — Audio Ring Buffer + LPCM Output (Weeks 5–6)

> **⚠️ ARCHITECTURE CHANGED (2026-06-27): audio is now decoded IN FABRIC.** AC-3 and
> LPCM decode in the FPGA (`dvd/dvd_audio_decode.sv` + `dvd/ac3/*` + `dvd/lpcm_unpack.sv`)
> and drive `AUDIO_L/R` directly. The HPS-daemon plan below (`hps/dvd_audio.c`, DDR3
> ring) is **retired** — see [`fabric_audio.md`](fabric_audio.md). `audio_ring` is kept
> as the elastic frame buffer feeding the in-fabric decoder. DTS is dropped for now
> (future: in-fabric IEC 61937 to the Digital I/O board). The HPS notes below are
> historical.

**Goal:** First audio output — LPCM tracks play on HDMI.

LPCM is the easiest codec (no decode needed) so it's the right first audio target.

### RTL Tasks
- [x] Write `dvd/audio_ring.sv` — **built, sim-verified** (`bench/dvd/audio_ring_tb.sv`).
  - **Revised from the original spec below.** It is a **single-clock (clk_sys)**
    FIFO, not dual-clock + Avalon-MM: the chosen HPS transport is the
    `ioctl_upload` channel (clk_sys domain), so no CDC and no f2sdram slave.
  - Write port fed by `ps_demux.sv`; `aud_ready` tied HIGH and overflow **drops a
    whole frame** so audio can never backpressure (stall) the shared video path.
  - Read side: FWFT byte stream + a per-frame descriptor FIFO `{length, type}` so
    the HPS reads complete frames and knows the codec. Status outputs:
    `frames_available`, `bytes_available`, `overflow_count`.
  - See CLAUDE.md → "audio_ring.sv — Status & design decisions" for the full
    rationale and the length-deferred-finalize limitation.
- [ ] **Next:** wire `audio_ring` into `dvd/emu.sv` (replace the `aud_ready=1'b1`
  park) and expose its status on `status`/debug-overlay bits.
- [ ] **Next:** add the HPS read path — `ioctl_upload` wiring in the `hps_io`
  instance + an HPS-side reader.
  - ~~Read port: Avalon-MM slave, accessible by HPS via `f2sdram` bridge~~
    (superseded — ioctl_upload chosen instead).

### HPS Tasks
- [x] **Transport re-decided: DDR3 shared memory, not ioctl_upload** (see
  `docs/audio_ddr_path.md`). FPGA writes frames to a DDR3 ring; a standalone daemon
  mmaps it. Audio OUTPUT is free — the framework's `alsa.sv` mixer routes HPS ALSA
  PCM to HDMI, so the daemon just `snd_pcm_writei`s (no `alsa_out.c` needed).
- [x] Write `hps/dvd_audio.c` — single daemon: mmap ring + read loop + per-codec
  dispatch + ALSA. LPCM implemented (sub-header already stripped by `ps_demux`, so
  just big-endian→little-endian + write). AC-3/DTS behind `HAVE_A52`/`HAVE_DCA`.
  `hps/Makefile` + `hps/README.md`. Host-compiles clean; **not yet run on hardware**.
- [ ] **Bring-up:** `./dvd_audio --probe` on HW → magic "DVDA" + write_seq climbing;
  then `./dvd_audio` for LPCM playback on an LPCM disc.

**Checkpoint:** DVDs with LPCM audio (find test discs with LPCM track) play with
synchronised audio and video on HDMI. Use a movie with stereo LPCM to test.

---

## Phase 3 — AC-3 Audio Decode (Weeks 7–9)

> **⚠️ SUPERSEDED (2026-06-27): AC-3 is now decoded IN FABRIC, not on the HPS.** See
> `docs/fabric_audio.md` (`dvd/ac3/*` + `dvd/dvd_audio_decode.sv`). The HPS/liba52
> tasks below are obsolete; kept for historical context.

**Goal:** AC-3 (Dolby Digital) audio decoded to stereo PCM on HDMI.
This covers the vast majority of commercial DVD releases.

### HPS Tasks
- [ ] Cross-compile or build liba52 for ARM (or find it in MiSTer's Linux environment)
- [ ] Write AC-3 decode path in `hps/audio_decode.c` (see audio.md for code)
- [ ] Test: `a52dec` command-line tool on MiSTer to verify liba52 works before integrating
- [ ] Integrate into ring buffer read loop
- [ ] Basic A/V sync: dual frame counter approach (see architecture.md)

### Testing
- Most commercial DVDs are AC-3 2.0 or 5.1 — choose a simple 2.0 disc first
- Verify audio doesn't drift relative to video over a 10+ minute period

**Checkpoint:** Standard commercial DVD (AC-3 audio) plays with correct stereo audio.
This is the first "it actually works as a DVD player" moment.

---

## Phase 4 — Filesystem + title navigation (play a real ISO)

**Goal:** Play from real DVD ISO files, navigating to the correct title automatically.

Up to this point you've been manually specifying VOB files. This phase adds the
intelligence to find and navigate them automatically.

> **✅ v1 DONE & HW-CONFIRMED (2026-07-05, PR fj#70, `DVD_isonav`) — IN FABRIC, NOT on the
> HPS.** ISO files play with correct video/audio on real hardware (flat-file fallback still
> works). Known limit: the largest-VTS heuristic doesn't pick the right main title on every
> disc (→ IFO/PGC or a manual OSD title picker, deferred for menus/track-selection work).
> The user requires everything in one `.rbf` (no HPS daemon). The MiSTer `sd_*` block interface is random-access, so navigation moved into
> RTL: `dvd/dvd_iso_reader.sv` detects ISO9660, walks root → `VIDEO_TS`, and plays the
> **largest VTS = main feature**. It is a drop-in `mpg_streamer` replacement; a non-ISO
> image falls back to linear whole-file streaming. Decrypted ISOs only (**CSS stays a
> PC-side rip step**, per the existing workflow — no in-fabric CSS). ISO9660 only for v1
> (UDF-only images deferred). Full design + verification: **`docs/dvd_nav.md`**;
> selection predictor `tools/iso_nav_check.py`. So the **HPS Option A/B below is NOT the
> path taken** for the filesystem/title-selection layer — it's superseded by the
> in-fabric reader. The IFO/PGC parts (chapters/seek/angles) remain future work
> (Phases 7–9), built **in fabric** as an extension of `dvd_iso_reader` (self-contained
> `.rbf` requirement — no HPS daemon). HW-confirmed 2026-07-05.

### HPS Tasks (superseded by the in-fabric reader above — kept for reference)

**Option A (recommended): Use libdvdread + libdvdcss**
These are mature, well-tested libraries (used by VLC) that handle everything:
```c
#include <dvdread/dvd_reader.h>
#include <dvdread/ifo_read.h>
#include <dvdread/nav_read.h>

dvd_reader_t *dvd = DVDOpen("disc.iso");  // libdvdcss integrated
ifo_handle_t *vmgi = ifoOpen(dvd, 0);    // VIDEO_TS.IFO
// navigate to main title, get VOB file list and block ranges
```

**Option B: Write minimal UDF parser**
If you want more control or can't build libdvdread for MiSTer's ARM:
- [ ] `hps/udf.c` — parse UDF Volume Descriptor Sequences
- [ ] Find `VIDEO_TS/` directory, enumerate `.IFO` and `.VOB` files
- [ ] `hps/ifo_parse.c` — parse title structure
  - Read `VIDEO_TS.IFO` → find main title set
  - Read `VTS_XX_0.IFO` → find main PGC (longest = main feature heuristic)
  - Get ordered list of VOB cell addresses

**For v1:** Skip menu navigation. Use "longest PGC = main feature" heuristic.

### CSS Encryption Integration
- [ ] Link libdvdcss into HPS program
- [ ] Replace `open()`/`read()` with `dvdcss_open()`/`dvdcss_read(DVDCSS_READ_DECRYPT)`
- [ ] Test with both unencrypted ISOs and CSS-encrypted rips

**Checkpoint:** Drop an ISO of any commercial DVD onto the SD card. Core automatically
finds the main feature, navigates to it, and plays from start.

---

## Phase 5 — DTS Audio (via IEC 61937 S/PDIF passthrough)

> **⚠️ APPROACH (2026-07-11): DTS is delivered by IEC 61937 bitstream passthrough over
> optical S/PDIF, NOT by decoding** (there is no in-fabric DCA decoder; a from-scratch
> one is out of scope, and the HPS libdca path is retired with the rest of the HPS audio
> daemon). An AV receiver decodes the bitstream. Design: **`docs/iec61937.md`**.

**Goal:** make DTS (and AC-3) tracks audible on an AV receiver with an optical input.

### ✅ Milestone A — passthrough machinery + AC-3 (HW-CONFIRMED 2026-07-11)
- [x] `dvd/spdif_pass.sv` — IEC 60958 biphase encoder (copy of `sys/spdif.v`) with the
  non-PCM channel-status bit set.
- [x] `dvd/iec61937_wrap.sv` — burst formatter + async FIFO; self-paces to the 48 kHz drain.
- [x] `O6` Audio Out (Decode/Passthru) + `O7` SPDIF Byte Order; ring arbitration, HDMI
  PCM mute, `sys_top` pin mux. `bench/dvd/iec61937_wrap_tb.sv` green.
- [x] **✅ HW-CONFIRMED:** AC-3 recognised, 2.0 AND 5.1 play clean, no static/fringe;
  Decode-mode PCM unaffected.

### 🔧 A/V sync — HW round 1 showed video trailing audio ~1 s (passthrough bypassed
av_sync). Fixed by slaving the burst release to the video STC (`head_delta ≥ 0`, reuses
`av_stc`/`av_ofs`); sim-verified (tb TEST 6), **HW re-test pending**.

### 🔧 Milestone B — DTS (RTL + wiring done, sim-verified, HW gate pending)
- [x] `dvd/dts_reframer.sv` — align to `0x7FFE8001`; chained ac3→dts→ring. Ring measures
  `frame_len` from the sync gap (contiguous frames). Verified on a real T2 DTS track.
- [x] iec61937_wrap: Pc=`0x000B` for DTS; LPCM/unknown → silence guard. Burst period = 512
  (T2-correct; NBLKS-snoop deferred, see docs/iec61937.md).
- [ ] **HW gate:** DTS VOB → receiver shows "DTS", plays clean + in sync. (Concert DVDs —
  many have DTS as the primary track. T2 is a known DTS disc.)

---

## Phase 6 — Polish and Known Issues (Weeks 15+)

> **★ General-catalog conformance:** the durable "what DVD-Video feature is implemented /
> partial / missing, and against which trusted reference" map now lives in
> **[`docs/conformance.md`](conformance.md)** (VM, IFO tables, in-stream NAV, plus a
> reference-suspect list of libdvdnav's own FIXME/HACK regions and a prevalence-ordered gap
> list). Work the open Phase-6 nav items (exact PTT/chapters, parental, region, UOP, counter
> GPRMs, menu audio) against that matrix, not disc-by-disc. The method: libdvdnav is a
> *baseline hypothesis*, cross-checked against *DVD Demystified* (`dvd_repos/`) and real-player
> behavior — see the white-rabbit / seamless-branch ILVU precedent (PR fj#112).
> **Phase 2 (corpus census + golden-trace oracle) ✅ done 2026-07-13:** `tools/dvd_census.py`
> (batch feature census) + `tools/build_dvd_trace.sh` (libdvdnav VM-boot trace). The measured
> 7-disc prevalence table + revised gap ordering are in `docs/conformance.md` "Phase 2" —
> **top gap confirmed = exact chapters/PTT (7/7 discs); interactive GPRM-counter/NVTMR promoted
> above parental on measured prevalence (3/7 game discs).** Phase 3 = close gaps in that order.

### PAL/NTSC Framerate Sync
The upstream core had a hardcoded 60Hz NTSC display clock; PAL content (25fps) played
~20% too fast.

**✅ DONE & HW-CONFIRMED (2026-06-30, branch `feature/hres-offbyone-pal`, PR fj#50):** the
same 27 MHz dot clock yields 50.0 Hz with PAL totals (864×625 = 540000 dots/frame), so **no
PLL reconfiguration is needed.** A new **`O[17:16],Video Standard,Auto,NTSC,PAL`** option
switches:
- the **runtime modeline-write walk** (`dvd/emu.sv`) to 720×576p @ 50 Hz timing
  (HORZ_RES 720 / total 864, VERT_RES 576 / total 625, hsync 732..795, vsync 581..586);
- **`av_sync`**'s STC tick rate to 50 Hz via the new `refresh_50hz` input
  (`REFRESH_MHZ_PAL=50000`, ~1800 ticks/refresh);
- the governor needs **no change** — `SHOW_N=2` gives 50/2 = 25 fps directly.

**Auto** (default) detects PAL vs NTSC from the decoder's new `mpeg2video.vertical_size_out`
port (480 = NTSC, 576 = PAL, 2-FF synced into clk_sys); **NTSC/PAL** force the choice (handy
for HW bring-up without a matching disc). PAL is **progressive-only** for now (the O9
Interlaced-Out toggle is forced off under PAL, via `il_eff = status[9] & ~pal_eff`).
HW-confirmed on a real PAL DVD: correct 720×576 geometry, 50 Hz lock, A/V in sync.

> **⚠️ Known limitation — PAL playback stutters (BBB PAL DVD, 2026-06-30).** PAL plays but
> shows some stutter, most likely because the 720×**576** frame is ~20% taller than NTSC's
> 720×480 (1620 vs 1350 macroblocks/frame), pushing more per-frame decode work onto a
> decoder that is **already at its compute ceiling on high-motion content** — see
> [[highmotion-rootcause-reffeed-latency]] / the "compute-bound" memories (BBB was the
> borderline NTSC case too). (Caveat 2026-07-09: those memories used the Matrix opening as
> the worst-case vehicle, which is now known to be a bad-rip artifact — see the frame-drop
> governor item; the PAL BBB stutter itself is real and was fixed by that governor.) This
> is broadly the same class as the NTSC high-motion load,
> just exposed harder by the bigger frame; it is **not** a PAL-timing/pacing bug (geometry
> and 50 Hz lock are correct). No new cheap lever is expected — it rides on the deferred
> decoder motion-comp/IDCT datapath rewrite. **TODO:** confirm with the cache-miss/stage
> profiler overlays whether PAL BBB is purely compute-bound (expected) or whether the larger
> reference reads also re-stress the f2sdram bridge.

### Film 24p Out — progressive-film cadence fix (issue fj#124)

**✅ v1 DONE & HW-CONFIRMED (2026-07-25, branch `feature/film-24p-out`, PR #TBD):** NTSC
progressive-film HDMI had an irregular ~1 s cadence pulse — the decoder missed ~4 frame
deadlines/s + 2 B-drops/s on high-motion film, breaking the 3:2 into an irregular
`3:3:2:3:2:4:3:2…`. Root cause is **throughput contention** (display re-reads the framebuffer
60×/s, saturating the single f2sdram port and starving motion-comp; NOT arbiter-schedulable, see
`hdmi-progressive-film-cadence-judder`). **Fix = demand reduction, not more bandwidth:** output a
**23.976 Hz progressive raster** (`P1O[24],Film 24p Out`; modeline vtotal 1313, `SHOW_N=1`,
av_sync `REFRESH_MHZ_FILM=23976`) and let the framework scaler (ascal) do the 3:2 pulldown to
59.94 Hz HDMI. This cuts the core's framebuffer re-reads 60/s → ~24/s (clustered, big vblank for
motion-comp) so the decoder stops missing deadlines. **HW: film plays correct-speed, in sync,
pulse GONE.** Shipped on **SEED 13** (release netlist; the film24 logic reshuffled placement so
SEED 9 no longer works — seed lottery, `quartus-build-flaky-routing`).

**Phase 2 — ✅ HW-CONFIRMED (2026-07-25, PR fj#126; full work order + landed-code map in
`docs/film_24p_plan.md` §9):** Auto frame-rate switching works on HW (NTSC film engages 24p
menus ON+OFF; non-film does not engage; PAL 25p in sync). **Bonus:** in 24p the high-motion
audio stutter is gone even with Frame Drop OFF — the 60/s→~24/s re-read cut removes the
motion-comp starvation that caused the misses (keep Frame Drop On as a safety net anyway).
- [x] **Automatic film detection** (`P1O[25:24],Film 24p Out,Off,On,Auto`; default Off for HW
  bring-up) — a per-pickup FSM in `dvd/resample_addrgen.v` over the committed
  `progressive_frame`/`repeat_first_field` (no pixel analysis). Two hysteretic verdicts
  (`film_det_ntsc` = progressive + alternating rff 3:2; `film_det_pal` = sustained progressive),
  routed up to emu + 2-FF synced to clk_sys where the mode resolves. **Conservative** (ENGAGE_N=48
  confirming frames; false-positive video→24p = judder regression, false-negative = harmless).
  On/Off overrides kept (hard-telecine, escape hatch). `bench/dvd/film_detect_tb.sv` green.
- [x] **PAL 25p** — exact 1:2 (25→50), exact 25.000 Hz via vtotal 1250 (`dvd/emu.sv` modeline
  `(pal_prev && filmp_prev) -> {576,1249}`; `dvd/av_sync.sv` `REFRESH_MHZ_25=25000`/`refresh_25hz`,
  wins over `refresh_50hz`). Halves PAL display reads 50/s → 25/s = a **throughput** relief for the
  PAL high-motion stutter (PAL 2:2 has no pulse, so the win is stutter not cadence). Reuses the
  `filmp` governor path (SHOW_N=1 rate-agnostic). Same film-only gate (true 50-field PAL video →
  `film_det_pal` excludes `progressive_frame=0`).
- [x] **HW gate PASSED (2026-07-25):** NTSC film Auto engages 24p (menus ON+OFF); non-film does
  not engage; PAL 25p in sync. The menus-ON engagement needed the confidence-accumulator detector
  (a strict consecutive-run counter never locked through menu/VM-path cadence hiccups).

**Remaining follow-ups:**
- [ ] **Motion-comp throughput rewrite (high-motion / PAL stutter)** — staged attack on the
  compute/feed-bound stutter; see `docs/motcomp_throughput.md`. **⚠️ Motivation revisited
  (2026-07-09):** the Matrix opening — long cited as *the* canonical worst case — is a
  SOURCE-FILE defect (its stutter reproduces in VLC on a PC, USER-CONFIRMED), so it is NOT
  evidence of a decoder-throughput deficit and Matrix was a confounded test vehicle. The two
  genuine high-motion cases were both addressed without a datapath rewrite: MiB act 3 by the
  Stage-1 reference prefetch and PAL BBB by the frame-drop governor (both below, HW-confirmed).
  **This rewrite therefore has no live motivating case — park it** unless a genuinely
  decoder-bound stutter shows up on a known-good source. The Stage-1/2 findings stay as
  reference.
  - [x] **Stage 1: reference-read run-ahead prefetch (O[18])** — deepen the fwd/bwd
    reference run-ahead 256→1024 (the reference-side twin of the display prefetch) so recon
    isn't starved of reference pixels (`dbg_ref_stall` was ~91 % on Matrix — but see the
    source-file caveat above; the HW win was measured on MiB). Single-bitstream A/B via
    `dvd/ref_dta_gate.sv`. Implemented + sim-verified (`bench/dvd/ref_prefetch_tb.sv`: deep
    buffers 971 rows, baseline caps 204, no overflow; ps_chain regression green). **HW
    CONFIRMED (2026-06-30) at depth 512 (`DVD_refpf9`):** MiB high-motion stutter gone, no
    blackouts, no fringing, DSP 83/112 unchanged. (Depth was trimmed 1024→512 because the
    1024 build's congestion caused activity-correlated HDMI blackout waves + fringing; 512
    fixed both while keeping the MiB win. See `docs/motcomp_throughput.md`.)
  - [x] **Stage 2 (recon 1-row/cycle) — SHELVED:** the recon 2-cycle cadence is matched to the
    64-bit reference data width, not FSM overhead; a pure FSM rewrite gains nothing, and the
    128-bit cache-serve alternative is bounded/high-risk. See `docs/motcomp_throughput.md`.
- [x] **★ Graceful frame-drop governor — SHIPPED + HW-CONFIRMED (PR fj#57, `O[12] Frame Drop`).**
  The real fix for compute-bound playback: when the decoder misses a frame's deadline, skip a
  B-frame (never a reference → free to drop) to catch up. HW-confirmed it fixes PAL BBB stutter
  at correct speed. Was an opt-in PAL tool because it over-dropped NTSC soft-telecined film
  (~1/7) — see the film-3:2 cadence fix below, which removes that hazard. Full history in
  `docs/motcomp_throughput.md` "HW results".
- [x] **Film-3:2 governor cadence fix — SIM-VERIFIED (2026-07-02, `feature/film-32-governor-cadence`).**
  Two symptoms in one root cause: NTSC film played **~30 fps instead of 24** (sped up) AND
  `O[12]` still over-dropped it. Cause: the governor held every frame for a flat `SHOW_N=2`
  refreshes, and the image-build only granted a pulldown frame its 3rd refresh on `rff &&
  top_field_first` (wrong for progressive frame display — `tff` is a field-order flag). Fix:
  cadence-aware pacing — `cur_show` = 3 refreshes for a `repeat_first_field` progressive frame,
  else `SHOW_N` → correct 3,2,3,2 = 24 fps; and each `rff` frame banks a `film_slack` credit that
  absorbs the following short frame's structural late (so `frame_late` no longer false-fires on
  film). PAL/high-motion (no pulldown) unchanged → real lates still drop. `dvd/resample_addrgen.v`
  (`cur_show`/`film_slack`); `bench/dvd/resample_cadence_tb.sv`. **HW: NTSC film should play 24 fps
  (no speed-up); `O[12]` On → row15 drops ~0; PAL BBB still drops+smooths. If confirmed, consider
  flipping `O[12]` default to On.** (An earlier `frame_late`-only v1 was inert on HW — the pacing
  was the real fix.)
- [x] **VBUF enlargement 256 KB → 2 MB — DONE 2026-07-02** (shipped with the lip-sync
  work, ✅ HW-proven by the drift-saga closure — PR fj#62 round 12). The stock MP@ML 256 KB VBV minimum is only ~0.25 s of an 8 Mb/s DVD
  stream — a thin cushion for the compute-marginal decoder (one long GOP burst drains it and
  trips the starvation guard → slideshow decay). New map: `VBUF = 0x080000..0x0bfffe` (byte
  4..6 MiB, DDRAM 0x30400000+), ~2 s of backlog for zero fabric cost (DRAM only, well inside
  the HW-proven <12 MiB backed region). `dbg_vbuf_fill` (overlay row 10 high byte) rescaled:
  0xFF = 2 MB now; the `vbuf_healthy` hysteresis thresholds stay fractional (25 %/12.5 %),
  so the guard now demands an 8× fatter absolute cushion — the conservative direction.
  Files: `dvd/mem_override/mem_codes.v`, `rtl/mpeg2/framestore_request.v` (tap width).
- [ ] **PAL high-motion stutter** — addressed by the frame-drop governor above (decode-load bound,
  not PAL-specific).
- [x] **PAL interlaced (576i @ 50) — HDMI/ascal — ✅ HW-CONFIRMED + MERGED (PR fj#132)**.
  Mirrors the NTSC-480i per-field modeline (pixel_repetition doubling): new
  `pal_prev & il_prev` walk branch (VER 575/311 => 312 lines/field ~50.06 Hz, per-field
  vsync 292..295, reused pixrep+interlaced VID_MODE). `il_eff` no longer forced low under
  PAL. Plays via `Interlaced Out On`. PAL 576i on the analog **CRT** pins (312/313
  half-line 2:1) is still a follow-up. See `docs/interlaced_auto.md`.
- [x] **Interlaced Out: Off/Auto/On — ✅ HW-CONFIRMED + MERGED (PR fj#132)** (default Off).
  `On` = native 480i/576i fields, A/V-synced (HW). A standard-neutral `det_video` verdict
  in `dvd/resample_addrgen.v` (sustained `progressive_frame==0`) drives **Auto**
  (auto-engage for true-interlaced video; mid-title switch via a full seek-style flush).
  **⚠️ Auto PARKED as opt-in — its mid-title switch still leaves audio slightly out of
  sync on HW; default is Off.** Open follow-up: the residual Auto-switch audio skew.
  The **overlay/OSD horizontal squish in interlaced mode is ✅ FIXED (2026-08-22)** —
  pixrep `h_pos` map + `spu_decode`/`crt_ov_map` `.interlaced` following `il_eff`,
  shipped as a prerequisite of `Analog Out = Native Fields`.
  See `docs/interlaced_auto.md`.
- [ ] **Film 3:2 / PAL-25-from-24** `SHOW_N` cadence handling (separate from the above).

### Composite / Interlaced Analog Output for CRT (primary end goal)

**Goal:** View output on an old CRT TV that has only **composite** input, via the
MiSTer analog (I/O) board. This is the project owner's ultimate target display.

**Status: ✅ HW-CONFIRMED 2026-07-05 (branch `feature/crt-480i-native`, MERGED PR fj#65) —
then REWORKED 2026-07-29 into the DUAL-RASTER architecture, ✅ HW-CONFIRMED + MERGED
2026-07-30 (PR fj#146):** the O[14] whole-core CRT mode is retired; the 15 kHz raster is
now a SECOND simultaneous output (`dvd/re_interlace.sv` → `VGA2_*` → sys_top
direct-chain mux) auto-engaged from MiSTer.ini alone (`vga_scaler=0` +
`composite_sync=1`/ypbpr/sog, or direct_video) with `O[27:26] Analog Out`
Auto/Interlaced/Progressive override — no OSD setup step, HDMI stays progressive
simultaneously, and **PAL 576i analog is included** (⚠️ timing numbers still
sim-derived — not specifically re-verified by the HW confirmation). See
`docs/analog_dual_raster.md`.

**★ Native Fields (field passthrough) — 2026-08-22, ✅ HW-CONFIRMED (core claim), PR fj#178.**
A/B vs the derive path on a measured video-sourced disc (Roger Waters) is noticeably
smoother; 50-min MiB run held A/V sync.
A fourth `Analog Out` mode that fixes the field-pairing defect structurally: it forces
native-fields decoding for the session so `re_interlace` re-times the disc's **authored**
fields 1:1 instead of splitting a woven frame. The defect was worse than documented — a
governor **late** adds an ODD +1 refresh on the progressive path and flips the pairing
parity, and lates run **~4/s on healthy content**, so the pairing is re-randomised several
times a second and phase-alignment cannot fix it (re-arming also blanks the CRT's sync).
Film barely cares; **true 29.97i video is where the combing shows**. Opt-in: HDMI drops to
480i via ascal for the session. Ships with the interlaced overlay-coordinate fix.
Native 15 kHz 2:1 480i plays correctly on a real CRT (see the checklist below — the earlier
"awaiting CRT hardware test" wording is superseded). Full design, framework routing facts, the
field-swap contingency, and the step-by-step HW test plan live in
`docs/crt_480i.md`; the durable record of the FAILED first attempt (pulse-delay
half-line, weave workaround, 1440-wide pixel repetition) is the
`crt-interlace-odd-total-lines` memory — do not repeat those.

- [x] **Generate true 2:1 480i timing** — N64-model interlace in
  `rtl/mpeg2/syncgen.v` (alternating 262/263 field totals + half-line vsync
  COUNTER-reference, armed by `interlaced && halfline!=0`); sim-proven 262.5-line
  vsync cadence (`bench/dvd/crt_syncgen_tb.sv`).
- [x] **Native width via CE** — 13.5 MHz `dot_ce`/`CE_PIXEL` (858 dots = 15.734 kHz),
  not pixel repetition.
- [x] **Analog routing** — `VGA_SCALER=0` in CRT mode (was hardwired 1, hijacking
  the VGA connector with the scaler); framework `csync_vga`/`yc_out` carry the rest.
  User ini: `vga_scaler=0`, `forced_scandoubler=0`, `composite_sync=1`.
- [x] **480i field-path A/V ledger fixes** — pair-repeat late undercount (×2),
  mode-aware `show_next` (rff = 3 field scans), drop-debit `~interlaced` gates,
  `refresh_cnt` saturation (`bench/dvd/gov_field_late_tb.sv`); overlay row 17
  `vid_err` re-added for the HW verdict.
- [x] **Test on the actual CRT** — ✅ HW-CONFIRMED 2026-07-05 (round 2,
  `DVD_crt480i_v2`): image correct (true 2:1, field order right as shipped), audio
  stays in sync. Round 1 caught the pixel_queue CE bug (docs/crt_480i.md §0).
- [x] **HDMI chroma fringe regression** — ✅ FIXED + HW-CONFIRMED 2026-07-09 (PR fj#92,
  `feature/fringe-fmax-gate`). Root cause was clk_dec sitting under its placed Fmax
  (81.41/78.0 MHz on the shipped netlist = marginal), with the "fix" nobody could see failing
  because the seed sweep's Fmax extraction read the WRONG clock row. Shipped: a per-build
  Fmax gate (`tools/fmax_check.sh` row-anchored parse + `build_release.sh --release`) so a
  marginal fit can never pack silently again, and a targeted retime of the MEASURED limiter
  (`dvd/disp_vscale.sv` line-buffer read → blend, top 400 paths) that lifts clk_dec to
  92.38/88.64 MHz at SEED 7. HW: HDMI fringe-free, CRT Letterbox unaffected. Durable rule:
  when the fringe returns, `report_timing` intra-clk_dec and retime the NEW top cluster — the
  limiter moves as features grow. See docs/history.md §8, memory `chroma-edge-fringe-is-upsample-mode`.
- [x] **Chroma fringe root fix — SDC clock groups — ✅ MERGED (PR fj#156) + HW-CONFIRMED
  2026-08-01.** `sys_top.sdc`'s `set_clock_groups` never matched this fork's PLL
  (`emu|sys_pll`, no `pll_inst` level) — the core's clocks were in NO group, so ~40k unclosable
  async crossings (h2f/pll_audio/pll_hdmi/FPGA_CLK2_50 ↔ core) were fully timed, −68k ns TNS
  drowning clk_dec's real −278 ns. One-line pattern fix → the placement lottery COLLAPSED: all
  10 sweep seeds route + close (worst-corner 86.87–92.46, was best-of 82.82 with 3 no-routes),
  fits ~30 → ~12 min, release gate raised to `FMAX_MIN=86.0`, SEED 29 pinned (95.35/92.46). New
  `tools/timing_paths.sh` = one-command intra-clk_dec limiter dump. docs/history.md §10.
- [x] **PAL 576i CRT** — delivered by the dual-raster re-interlacer (312/313 totals,
  halfline 432, MERGED PR fj#146); mechanism HW-confirmed working overall, but the
  exact PAL timing numbers are still sim-derived — not specifically re-verified
  (`docs/analog_dual_raster.md`).
- [x] **16:9 on the 4:3 CRT (Fit / Letterbox / Crop)** — ✅ DONE, HW-CONFIRMED 2026-07-10,
  `docs/crt_anamorphic.md`. `O[4:3] CRT Aspect` Auto/Fit/Letterbox/Crop, CRT-mode only (HDMI
  keeps ascal ARX/ARY). Letterbox = vertical ¾ downscale + bars; Crop = horizontal pan-scan
  (full vertical res). PR fj#66 shipped both (Letterbox nearest-neighbour); branch
  `feature/crt-letterbox-aa` then made **Letterbox anti-aliased** — a true 2-tap vertical
  bilinear blend in the new downstream `dvd/disp_vscale.sv` (addrgen emits FIT vertically, no
  extra read BW; field-parity-safe **only when the decoder emits fields** — see the ⚠
  correction in `dvd/disp_vscale.sv`/`docs/crt_anamorphic.md`: under the default
  dual-raster analog path the addrgen emits a WOVEN frame, so the blend cross-fades the
  two source fields on true-interlaced content), retiring the addrgen NN path.
  - **Crop horizontal anti-aliasing (2026-08-01, PR fj#155) — ✅ HW-CONFIRMED.**
    Closes the last aliasing gap (user report: "the crop mode on analog output looks
    aliased"). `dvd/disp_hstretch.sv` was still pure pixel DUPLICATION (~192 of 528 source
    pixels emitted twice per line = a ~1.36× stair-step); it is now an output-driven 2-tap
    resample, `out[j] = src[k]·(1−f) + src[k+1]·f` with `k + f = j·hsrc/hdst`, the Q0.8 step
    decomposed once by an 8-step divider (no per-pixel divide). `f8` is FLOORed so
    `k + (f8≥128) = round(j·hsrc/hdst)` exactly — the contract `crt_ov_map` now inverts with a
    plain rounding Bresenham. Also emits exactly `hdst` px/line (the `hdst−1` off-by-one is
    retired) and nearest-picks `osd`. New `+hgrad` blend proof in `resample_chain_tb` plus
    `crt_ov_map_tb` T1a/T1b/T1c. Detail: `docs/crt_anamorphic.md` §8b.
  - Remaining follow-ups: native 240p (reuses `disp_vscale`), PAL 576i bars, `osd`-nearest
    back-port to `disp_vscale`.
  - **Overlay alignment under Letterbox/Crop (2026-07-11, PR fj#108) — ✅ HW-CONFIRMED.**
    The subpicture +
    menu-highlight layer queried RASTER space, so it landed offset from the rescaled video
    (the reported "menu highlighting doesn't account for the crop/letterbox CRT options").
    New `dvd/crt_ov_map.sv` inverse-maps the raster position to the displayed SOURCE pixel
    (exact Bresenham inverses of `disp_vscale`/`disp_hstretch`, co-simmed against them in
    `bench/dvd/crt_ov_map_tb.sv`); `spu_decode` row-base adder generalized for the skipping
    line walks; CRT Auto aspect now menu-aware (`ar_wide_auto_eff`, matches HDMI). Detail +
    HW-gate checklist: `docs/crt_anamorphic.md` §9.
- [ ] **HDMI 4:3 output follows the same Fit / Letterbox / Crop setting as the analog CRT.**
  Today `O[4:3] CRT Aspect` (Fit/Letterbox/Crop, `docs/crt_anamorphic.md`) is gated on
  `crt_eff` (analog CRT mode only); HDMI instead gets its aspect from ascal via
  `O[20:19] Aspect Ratio` → `VIDEO_ARX/ARY`. Goal: when a **4:3 HDMI display** shows 16:9
  anamorphic content, let it honor the same Fit/Letterbox/Crop choice (a single "Aspect
  handling" control for both outputs). Design notes / how much is actually new:
  - **Fit** and **Letterbox** on HDMI are essentially FREE via the existing ascal path —
    ascal scales the whole 720×480/576 raster to the output and letter/pillar-boxes to the
    target DAR. Fit = `ARX/ARY = 4:3` (anamorphic shown as-stored); Letterbox = `ARX/ARY =
    16:9` into a 4:3 output (ascal adds the bars). So for these two the work is mostly menu
    plumbing: derive `VIDEO_ARX/ARY` from `O[4:3]` (not only `O[20:19]`) when the HDMI target
    is 4:3, so one setting drives both outputs consistently.
  - **Crop (pan-scan) is the only genuinely new HDMI work**: ascal can scale a whole frame
    but cannot pan-scan/crop the sides, so HDMI Crop needs the core `dvd/disp_hstretch.sv`
    horizontal-crop path (currently only enabled under `crt_eff`) applied to the SHARED
    raster. Un-gate `disp_hcrop_en` from `crt_eff` so it also engages for an HDMI-only /
    4:3-HDMI session (then set `ARX/ARY = 4:3`, since the cropped line is already stretched to
    full width → correct 16:9 geometry with the sides cut). This item now inherits the 2-tap
    resample quality for free — the stretcher is no longer nearest-neighbour (§8b), so an
    un-gated HDMI Crop starts out anti-aliased rather than needing a follow-up pass.
  - **⚠️ Shared-raster coupling:** one raster feeds both outputs, and the scaling stages
    (`disp_vscale`/`disp_hstretch`) are baked into it. Applying the correction for HDMI is
    clean when CRT is off (only HDMI consumes the raster) or when both outputs want the SAME
    framing. Wanting DIFFERENT framing per output simultaneously (e.g. CRT cropped + HDMI full
    16:9) is the separate **decoupled analog/HDMI framing** item — a post-mixer per-output
    split, deliberately deferred (`docs/experiments.md`). This item is the simpler "same
    setting, both outputs" unification, not that split.
  - Menu: fold `O[4:3]` and `O[20:19]` into a coherent scheme (or make `O[4:3]` apply whenever
    the target is 4:3 regardless of CRT). Cross-ref `docs/crt_anamorphic.md` §4 (HDMI
    coexistence) and the "Display Aspect Ratio" item below.

### ✅ Display Aspect Ratio (Auto / 4:3 / 16:9) — DONE

`O[20:19] Aspect Ratio` (Auto default / 4:3 / 16:9) drives the MiSTer scaler output
aspect via `VIDEO_ARX`/`VIDEO_ARY` in `dvd/emu.sv`. The raster stays 720×480 (or
720×576 PAL); the scaler (ascal) letterboxes/pillarboxes it to the selected display AR.

- **Auto** reads the MPEG-2 sequence-header `aspect_ratio_information` (par. 6.3.3;
  DVD emits 2 = 4:3, 3 = 16:9). Exposed from the decoder via a new
  `mpeg2video.aspect_ratio_out` port (tapped from the existing `vld` wire, same pattern
  as `vertical_size_out`), reduced to a 1-bit "wide" flag and 2-FF synced clk_dec→clk_sys
  (mirrors the PAL `pal_det_s2` CDC). 4:3/16:9 force the choice regardless of the stream.
- Only distinguishes code 3 (16:9) from everything else (→4:3); complete for DVD content.
- Note: `Direct Video` (`O[10]`) bypasses the scaler, so ARX/ARY don't apply there.
- Previously the `O1,Aspect Ratio,4:3,16:9` menu entry drove `status[1]`, which was never
  read — the option did nothing and output was always 4:3. Sim/lint clean; **✅ HW-confirmed
  2026-07-10** (the CRT view modes verified on the board).

### HD Modeline Switching
The display block drives a fixed 27MHz SD clock. DVD is 480i/480p so this is fine,
but for future HD content (upscaled output) you'd need dynamic PLL reallocation.
Not needed for DVD spec content.

### FPGA congestion / resource cleanup (technical debt)

**⚠️ UPDATE 2026-07-06: the design is now ALSO approaching a hard ALM ceiling, not just
routing-marginal.** As of the transport-seek/pause build (`feature/transport-seek-pause`)
utilization is **98 % ALMs (≈41,027 / 41,910 on the 5CSEBA6U23I7)** — with the debug overlay
ALREADY compiled out. So the two concerns now compound: the localized routing hotspot below
AND genuine whole-device fullness. **Before the next large fabric block (esp. the graphical
menu renderer), a fabric budget / reclaim pass is required.** Per-entity, the two dominant
consumers are `mpeg2video` (the MPEG-2 decoder — irreducible, it's the core function) and
`dvd_audio_decode`/`ac3_front` (the in-fabric AC-3 decoder: `imdct_512` multipliers,
bit-allocation, exponent/mantissa decode, several BRAMs + dividers). Everything else (nav,
demux, subpicture, av_sync) is comparatively small.
- **✅ IN-FABRIC RECLAIM DONE (2026-07-06, `feature/alm-reclaim-bram`) — AC-3 STAYS IN FABRIC.**
  User vetoed the AC-3→HPS lever below; instead two flop-array/async-read tables were converted
  to sync-read M10Ks (the same discipline that fixed the 226%/106% fit explosions), keeping
  everything in fabric:
  - `dvd/audio_ring.sv` descriptor ring `dmem` (was 2,853 ALMs / 6,880 regs): the four async
    `dmem[d_rd]` taps became a 1 M10K read port fronted by a FWFT head register (`head_desc`/
    `head_v`). Interface-equivalent; `frame_valid` gaps ≤2 clk_sys cycles after a pop, absorbed
    by `dvd_audio_decode` (reads the descriptor only in S_IDLE, then routes hundreds of bytes).
  - `dvd/dvd_iso_reader.sv` extent + group tables (was 5,282 ALMs / 6,864 regs): `all_start`/
    `all_blocks` → `ext_mem` (1 M10K, read at `strm_idx` into registered `ext_start_q`/
    `ext_blocks_q`); `group_*[4]` → `gmem` (1 M10K, read at `sel_i`). Sync-read latency is
    covered by three new wait states (`S_EXT_LOAD`, `S_CELL_SEEK2`, `S_SELECT2`); the sd round
    trip is ~ms so the extra idle cycles are free. State reg widened 5→6 bits (also gives the
    Phase-2 menu-domain states room); `debug_state` low byte repacked `{2'b0, state[5:0]}`.
  - **BUILD RESULT (SEED 9, fitter Successful, 0 errors): ALM 98% → 77% (41,027 → 32,090),
    ~8,900 ALMs reclaimed** — beat the ~5–6k estimate. Per-entity: `audio_ring` 2,853 → 173,
    `dvd_iso_reader` 5,282 → 1,186. M10K 67% → 68% (+6 blocks), DSP unchanged (84%). `.rbf`
    4,016 KB (smaller than the recent HW-confirmed `DVD_transport`/`DVD_titlesel` ~4.1–4.3 MB
    builds — compression applied fine; the script's "~2.9 MB typical" warning is stale for the
    AC-3-in-fabric DVD core). Sim-verified: all `audio_ring`/`iso_reader`/`ac3_reframer_ring`/
    `aud_backpressure` TBs green + a new audio_ring pop-after-commit race case; real-VOB
    `ps_chain_tb`/`iso_reader_real_tb` green. **HW playback regression pending** (user gate).
    Now ~9,800 free ALMs — ample headroom that funds the DVD-VM disc-menu work without touching
    AC-3.
- **(Superseded lever) Move AC-3 decode back to the HPS** (liba52) — the ORIGINAL plan
  (`docs/audio.md` "Option 3", CD-core precedent) would free the most fabric but reintroduces
  the retired HPS audio daemon + re-opens A/V-sync work. **User declined** (keep AC-3 in
  fabric); the sync-BRAM reclaim above is the in-fabric alternative. Kept on record as the
  fallback pressure valve if area gets tight again.
- The MPEG-2 decoder is not shrinkable without deep work (and the motcomp/IDCT rewrite is about
  THROUGHPUT, not area).

The design is ALSO **routing-congestion-marginal**: RAM 43 %, DSP 74 %, but the router
repeatedly fails on a **localized interconnect hotspot** (peak ~90–93 % in the
framestore/decoder→overlay region, e.g. X33_Y11–X44_Y22 on the fit that blocked the frame-drop
reland — Error 11802). Small additions in that region (frame-drop counters, a future UI overlay
renderer) tip it over. This matters specifically before building on-screen UI **rendering**
(Phase 11 / subpicture Phase 10), which lands in the exact congested output region. (In-fabric
nav/seek/track/IFO logic is CONTROL-path, not display-path — it costs modest ALMs elsewhere on
the die but does *not* compete for this display/overlay hotspot. Only display-path RTL does. So
keeping nav in fabric — the self-contained-`.rbf` way, no HPS daemon — does not worsen the
congestion, though it does still consume whole-device ALMs against the ceiling above.)

Levers, cheapest/lowest-risk first:

- [x] **Bake in settled A/B experiment toggles — DONE.** The winners are hard-wired in
  `dvd/emu.sv`: **Ref Prefetch** (`ref_prefetch_en(1'b1)`), **Critical-Word Serve**
  (`cwf_en(1'b1)`), **Dual Outstanding** (`dual_en(1'b1)`). The old O[14]/O[15]/O[18] bits
  were freed and **O[14] repurposed to CRT 480i**. This lever is spent — the remaining
  headroom levers are the release-vs-debug overlay split and the targeted fringe fix below.
- [x] **Remove the debug UART — DONE** (during `feature/frame-drop-reland`, same pass that baked
  O[14/15/18]; see the qsf note). The `uart_debug`/`uart_tx` transmitter is no longer
  instantiated in `dvd/emu.sv` (`UART_TXD` tied idle high, User IO tied off) and is NOT in the
  `DVD.qsf` file list, so it doesn't compile. The `rtl/uart_tx.v` + `rtl/uart_debug.sv` files
  still exist on disk but are dead (safe to delete for tidiness; no fabric impact either way).
- [x] **Removed the `decoder_profile` stage profiler** (2026-07-01, `feature/frame-drop-reland`)
  to route the frame-drop reland — it had served its purpose (confirmed the high-motion
  stutter is compute-bound). Overlay rows 10/11 now read 0; also pruned the `recon_ref_stall`
  deep tap. Pattern to repeat for the items above.
- [x] **★ Targeted fringe fix — DONE + HW-CONFIRMED (PR fj#92, 2026-07-09).** Replaced the blunt
  global `PHYSICAL_SYNTHESIS_*` switch (which had already been turned OFF for routability, so the
  fringe was live) with two things: a **per-build Fmax gate** (`tools/fmax_check.sh` +
  `build_release.sh --release`) that refuses to pack a clk_dec-marginal fit, and a **targeted
  retime of the measured limiter**. Key finding: the limiter was NO LONGER the old
  `mem_req_wr_almost_full → framestore_request` net (PR fj#58 already retimed that) — `report_timing`
  showed the top 400 intra-clk_dec paths had all moved to `dvd/disp_vscale.sv` (letterbox
  line-buffer read → blend). A fabric register + payload-carry stage there lifts clk_dec to
  92.38/88.64 MHz at SEED 7. Costs one cycle of latency, negligible ALMs. Lesson baked into
  history.md §8: the limiter MOVES as features grow — always `report_timing` to find the current
  top cluster rather than re-fixing the last one. See docs/history.md §8.
- [x] **Release-vs-debug split — DONE (PR fj#71).** `dvd/debug_overlay.sv` sits in the hotspot;
  it is now gated behind `` `ifdef DEBUG_OVERLAY `` in `dvd/emu.sv` (default OFF). The shipped
  subpicture release build compiles it out, which was **required** to route/close the fit once
  the subpicture renderer landed in the same corner (playback wedged with it in). Define
  `DEBUG_OVERLAY` (VERILOG_MACRO in DVD.qsf) to bring the O2 overlay back for diagnostics — that
  re-tightens the fit and may need a seed re-sweep. Note the overlay was only ~300 ALMs, but the
  fit relief + the combinational-blend footprint cut together took it off the edge.
- [x] **Fitter seed / effort as a stop-gap (not a fix).** ~~The design is a routing
  "lottery"~~ — **largely RESOLVED 2026-08-01 by the SDC clock-groups fix** (docs/history.md
  §10): with the fitter no longer timing ~40k unclosable async crossings, all 10 sweep seeds
  route AND close 86.87+ MHz on a netlist where 3 of 7 previously failed to route. Seeds are
  still pinned per-netlist for reproducibility, but sweeps should rarely be needed; a fit
  under the 86.0 gate now means the netlist degraded — measure (`tools/timing_paths.sh`) and
  fix, don't re-roll. (`FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION` remains `ALWAYS`.)
- [ ] **Floorplan / LogicLock the hotspot (last resort, heavy effort).** If the logic cuts
  above aren't enough, constrain placement of the framestore/decoder→overlay region (or give
  the overlay/output path its own region) so the router isn't forced to cram it into
  X33_Y11–X44_Y22. High effort and brittle to design changes — only after the cheaper levers.
- Context (not a lever): the other large fabric block is the **in-fabric AC-3 decoder**
  (`dvd/ac3/*`, 12 files); DSP is now ~84 % (subpicture's blend multiplies pushed it up from
  74 %) — both are *functional* (audio decode / motion-comp + IDCT / subtitle blend), a fixed
  budget floor, not something to trim. This is why the cleanup targets diagnostics + settled
  toggles + the blunt physical-synthesis switch, not the decoders. The guideline is about WHERE
  in fabric, not whether: **new heavy nav/seek/IFO/track/angle logic goes in fabric (the
  self-contained-`.rbf` requirement — no HPS daemon) but as CONTROL-path state machines that sit
  OFF the display/overlay hotspot** (like `dvd_iso_reader`), so they cost ALMs elsewhere without
  worsening the congested corner. Only display-path *rendering/blend* competes for the hotspot,
  and that's what to budget carefully. (CSS decryption stays a one-time PC-side rip step, not a
  running daemon — the FPGA only ever sees a decrypted `.iso`.)

Validate empirically (does it route? does the fringe stay gone on HW?), not by chasing the
fit/STA reports to zero — consistent with the project's "validate on hardware" discipline.

### A/V Sync & audio clock (drift handling)

The fabric audio path (`docs/fabric_audio.md`) outputs at a fixed 48 kHz
crystal-derived tick, while audio DATA arrives paced by the frame-rate governor
(locked to the display refresh). If the display field rate doesn't exactly match the
content's native rate, the two **drift** and the audio buffer slowly under/overflows.
The old HPS/ALSA path hid this by slaving audio to the data rate (`snd_pcm_writei`
blocks); the fixed-rate fabric output removed that safety net. Tiered plan:

- [x] **Tier 1 — big buffers** (done 2026-06-27): `audio_ring` 32 KB, LPCM ~85 ms,
  AC-3 ~43 ms. Absorbs bursty delivery; sufficient for short clips / near-zero drift.
  A buffer only *delays* drift, it doesn't cure it — a feature-length movie exposes
  even a ~0.05 % mismatch.
- [ ] **Tier 2 — sample drop/duplicate at watermarks (recommended near-term).** Keep
  the clean fixed 48 kHz output but drop one sample on over-fill / repeat one on
  under-fill. One sample every ~second is inaudible, ~20 lines of RTL, no pitch-wobble
  risk; makes long playback robust regardless of small drift. Cheap insurance.
- [x] **Tier 3 — PTS genlock (the "real DVD player" way)** — IMPLEMENTED 2026-06-28
  (PR fj#36, `dvd/av_sync.sv`, **✅ HW-proven — the drift saga closed on this loop, PR fj#62**). A video-referenced
  System Time Clock (anchored on `ps_demux.vid_pts`, advanced one `TICKS_PER_REFRESH`
  per displayed image off the `core_v_sync` refresh edge) and a PI loop that soft-slews
  the 48 kHz audio NCO (`nco_trim`, ±0.5 %) so the dispatched audio PTS tracks the STC.
  Seek (>0.7 s `vid_pts` jump) re-anchors cleanly. Per-frame PTS rides
  `ps_demux.aud_frame_pts → audio_ring → dvd_audio_decode.dispatch_pts → av_sync`.
  Full design: `docs/av_sync.md`. (Tier 2 sample drop/dup is now subsumed; the bare
  adaptive-NCO stepping stone is moot.)
- [ ] **Flush on load/seek.** Flush all audio buffers + reset decoders on a new
  disc/clip or a seek, so stale audio never plays out or lags video. Cheap, and
  required for seeking (Phase 8). av_sync already re-anchors on a PTS discontinuity;
  this adds the buffer flush so the resync is clean rather than draining stale audio.

#### PTS A/V sync — remaining follow-ups (post-PR-fj#36)

The genlock loop is in and sim-verified; these are the open items, roughly in priority
order. Detail lives in `docs/av_sync.md` "Open follow-ups".

- [x] **OSD-tunable lead + PTS-scheduled dispatch — DONE 2026-07-02**
  (merged via the lip-sync saga, ✅ HW-exercised through PRs fj#60–fj#62; the A/V Offset
  **+100 ms default is HW-verified on Matrix/PAL too, 2026-07-10**). `LEAD_TARGET` is now
  the runtime `lead_target` port on `av_sync`, driven from **`P1O[23:21] A/V Lead`**
  (150 default /200/250/300/400/0/50/100 ms) — dial lip-sync live on HW (audio heard
  LATE → raise, EARLY → lower). And `dvd_audio_decode` now **schedules dispatch by
  timestamp**: an early frame is held in the ring until `STC >= pts - lead_target`, so
  the start/seek phase is correct by construction instead of the ±0.5 % slew grinding it
  out over ~30 s. See `docs/av_sync.md` "PTS-scheduled dispatch".
- [x] **STC reference fix (v2, same branch) — the knob-inert bug.** First HW test showed
  `A/V Lead` INERT (0 ≡ 400 ms) + content-dependent skew. Root cause: the STC referenced
  the demux PARSE position, not the screen — anchor at parse time + a symmetric ±0.7 s
  re-anchor that snapped the STC to the demux front whenever the buffering window
  (audio_ring time window + VBUF fill) exceeded it, pinning the genlock target ahead of
  data availability (loop saturated ⇒ all lead values identical). Fixed: `video_live`
  sticky from the governor gates the STC advance (anchor ticks from first DISPLAY, not
  parse), and the re-anchor is one-sided (backward >0.7 s, forward only >15 s). Also
  fixed the VBUF-enlarge regression: `vbuf_healthy` thresholds made ABSOLUTE (64/32 KB)
  — fractional 25 %-of-2 MB was unreachable on audio-bearing VOBs (ring caps the stream
  run-ahead at ~0.6 s ⇒ VBUF parks ~350-450 KB) and permanently disarmed frame drop.
  See `docs/av_sync.md` §"STC reference (v2)".
- [x] **Playback-referenced phase (v3, same branch) — the dispatch gate was the wrong
  mechanism.** Second HW pass: v2 STC fixes CONFIRMED (audio starts with image; frame
  drop restored on VOBs) but the knob still inert, skew still content-dependent (Matrix
  ~50-100 ms, MiB ~500 ms). Lesson: **scheduling the ENTRY to an elastic buffer cannot
  set its EXIT time** — playback phase = dispatch phase − buffer occupancy, and the
  occupancy absorbs any lead change; phase is settable only at empty→flowing
  transitions. v3: drain gate at the PCM-FIFO exit (hold the 48 kHz tick until
  `STC >= play_pts + av_ofs`; underrun re-arms → re-entry at phase), `O[23:21]` becomes
  signed **A/V Offset** (0 default), NCO trim retired (same-crystal rate lock; an active
  PI would grind the set phase away). See `docs/av_sync.md` §"Playback-referenced phase".
- [x] **v3.1 arm-from-reset (Matrix silence/freeze fix).** Third HW round: v3.0's
  pre-anchor BYPASS armed the gate mid-flow with full FIFOs → release deadlock (Matrix:
  split-second of audio then silence; stalled ring backpressured the stream ~1.2 s =
  the video freeze) or instant-release free-run (MiB unchanged, knob inert). v3.1: gate
  held FROM RESET (FIFOs provably empty at the phase latch), ~2.5 s fallback release
  (never wedge silent), AC-3 stall watchdog exempted while held. See `docs/av_sync.md`
  §"v3.1".
- [x] **v4 stale-skip (mid-title-cut backlog; last knob-inert cause).** Round 4: Matrix
  un-wedged but knob still inert / skews unchanged — VOB cuts put 100s of ms of audio
  with PTS before the first displayable video frame at the FIFO head, so the release was
  past-due at every offset. v4 discards past-due frames while ARMED (never mid-play);
  underrun re-arm now skips missed backlog = true catch-up. See `docs/av_sync.md` §"v4".
- [x] **v5 STD mux-lead hold (measured mux geometry; HW effectiveness UNVERIFIED).**
  `aud_pts_chain_tb` over the real MATRIX.VOB: `first vid_pts − first aud_pts = +470 ms`
  (MiB VTS_21_4.VOB: +667 ms) — DVD muxes audio ~0.5 s behind video (VBV lead).
  Shipped: hold the governor's first pickup until the audio side catches the STC anchor
  (emu `pickup_hold` + `resample_addrgen.ofv_pickup`), per-load `video_live` re-arm,
  audio release waits `video_live`. ⚠️ The ~500 ms start constant it targeted STILL
  shows on HW — do not assume the hold is effective on hardware; see below.
- [x] **★ LIP-SYNC RESIDUALS — ✅ CLOSED 2026-07-04 (PR fj#62, rounds 7–12 in
  `docs/lipsync_pickup.md`).** The "rate drift" root cause was **STALE DISPLAY
  FLAGS**: the upstream decoder captured rff/tff/progressive_frame on the
  picture-HEADER `update_picture_buffers` pulse while they parse in the coding
  EXTENSION — every picture displayed with its coded predecessor's flags
  (invisible on clean 3:2; frame drops leaked ~+1 refresh each → the ~+3.3 %
  video-fast ramp that burned the VBUF and froze lips ~0.9 s audio-behind).
  FIX = `flags_commit` (vld → picbuf post-extension re-latch). HW-confirmed
  (drift9b capture, DVD_drift8): vid_err flat, VBUF parked, lips constant through
  the Shea crash. The "~500 ms start constant" was mostly the same ramp; true
  residual ≈100 ms audio-EARLY (A/V Offset +100 nulls it). Small follow-ups
  in lipsync_pickup.md round 12: shipping offset default (verify Matrix/PAL),
  overlay cleanup debt, why-4-lates/s churn (secondary).
- [ ] **Loop-gain tuning (`KP_SHIFT`/`KI_SHIFT`).** If audio audibly speeds/slows
  ("hunting"), soften `KP` and lean on the integrator. Sim convergence currently uses
  `KP_SHIFT=1`, `KI_SHIFT=9`.
- [x] **PAL / 25 fps (manual toggle).** Done 2026-06-30 (`feature/hres-offbyone-pal`):
  `av_sync` selects 50 Hz at runtime via `refresh_50hz` (O[16]); governor `SHOW_N=2`
  already gives 25 fps at 50 Hz. **Remaining:** drive it from `frame_rate_code` so
  25/50 Hz content syncs *automatically* (no manual toggle) — see "PAL/NTSC Framerate
  Sync" above. Shared TODO with `docs/frame_rate_governor.md`.
- [ ] **Overlay surfacing of drift/trim** (`av_drift`/`av_nco_trim`/`reanchor_count`).
  Deferred in PR fj#36 — the 16-row 4-bit-addressed `debug_overlay` is fragile to expand.
  The debug nets are already wired in `emu.sv`; add a row (or repurpose one) to read
  drift on HW. Needed to *measure* lip-sync rather than eyeball it.
- [ ] **Per-sample PTS through the AC-3 pipeline.** Only if HW shows a residual phase
  error `LEAD_TARGET` can't absorb: carry the frame PTS through decode and subtract the
  live `pcm_out` FIFO occupancy so the loop references the PTS of the sample actually
  *leaving* the speaker, not the one entering the decoder.
- [ ] **Static-*pop* drop fix (related, separate effort).** `audio_ring` drops PES-sized
  chunks, not AC-3 frames, so an overflow drop misaligns the AC-3 stream → `err` →
  self-heal reset → audible pop. PTS pacing reduces drop *frequency* but can't silence a
  drop. Fix: AC-3-frame-aligned drop in `audio_ring`, or graceful mute-and-resync in
  `dvd_audio_decode`. See memory `static-pops-root-cause`.

(Superseded note: the original "Phase 3 dual frame counter" A/V-sync plan is obsolete
— the merged **frame-rate governor**, `dvd/resample_addrgen.v`, paces video to display
refresh; see `docs/frame_rate_governor.md`. Tier 3 PTS genlock above replaced it.)

### IEC 61937 S/PDIF Output (optical — Analog *or* Digital I/O board)
Optical out is not Digital-board-exclusive: the framework's `spdif` net feeds both
`AUDIO_SPDIF` (Digital TOSLINK) and `SDCD_SPDIF`/`PIN_AH7` (Analog board combo-jack
mini-TOSLINK). The blocker is format, not connector — `audio_out` emits PCM only.
- [ ] Complete `dvd/iec61937_wrap.sv` (frame undecoded AC-3/DTS from `ps_demux`/`audio_ring`;
      set the IEC 60958 non-PCM channel-status bit)
- [ ] Bypass MiSTer framework's PCM `audio_out` for bitstream output
- [ ] Drive the S/PDIF pin directly (`AUDIO_SPDIF` and/or `SDCD_SPDIF`)
- [ ] Test with AV receiver via optical (confirm the board revision populates the TOSLINK TX)

### DVD Menu Navigation (stretch goal)
- Parse DVD navigation packets (NAV packs embedded in VOB data)
- Implement PGC state machine
- Add button highlight rendering
- This is a significant undertaking — consider post-v1
- See Phases 7–11 below, which break this and related interactive features down.

### Transport controls (gamepad seek + pause) — SHIPPED, with one follow-up
`feature/transport-seek-pause` (PR fj#77, HW-confirmed 2026-07-06) shipped the reusable
**cell-granular seek** primitive + **pause**, gamepad-driven. Pause works cleanly (freeze
+ silent + in-sync resume); seek jumps video with audio (native `flush_vbuf`). See
`docs/dvd_nav.md` "Transport". Remaining follow-ups:

- [x] **Seek/jump transition glitch — HOLD-FRAME TRANSITIONS ✅ HW-CONFIRMED 2026-07-30
  (PR fj#148).** The black gap was NOT the
  picbuf drain: it was the STD mux-lead hold (`pickup_hold`, armed on every seek/jump)
  gating only `ofv_pickup` — with a frame due, the governor fell out of the persistence
  re-scan into a parked `STATE_INIT` = zero scans = mixer black for the whole hold
  (~0.5–1.24 s). Fixed by giving the hold the pause treatment: shared `hold_freeze`
  gates `ofv_paced` + `ofv_pickup` + `late_raw` (no drop-debt banked at clip start) and
  feeds the watchdog `repeat_frame=31` (else it hard-resets the stalled decoder at
  ~410 ms, inside the hold window). Result = the user's desired UX (2026-07-06): **the
  last frame holds through the transition**, then cuts to the new clip. The ≤2
  stale-picbuf reorder frames at release now play *behind* the held frame (same old
  clip — expected invisible); re-assess on HW. Sim: `pickup_hold_tb` (fails on pre-fix
  RTL exactly as diagnosed) + `gov_field_late_tb` [HOLD]. Detail: `docs/av_sync.md`
  §v5.2.
- [x] **Natural-transition tail cut — TAIL-DRAIN WAIT ✅ HW-CONFIRMED 2026-07-30
  (user report, PR fj#149).** A NATURAL title-domain PGC end (First Play
  logo chains, end-of-title → menu) dispatched POST → jump with `keep_vbuf=0`, and the
  jump's `vbuf_flush` discarded the decoder's ~1 s buffered tail — the end of every logo
  clip was cut (post-PR-fj#148 it read as "freeze early, then cut"). The reader's PGC-end
  dispatch gate now also waits for **`vbuf_empty`** (title domain only; `DRAIN_WD` ~5 s
  watchdog so a wedged decoder degrades to the old behaviour) before pulsing
  `vm_pgc_end`, so the tail plays to the screen and the flush hits an empty buffer.
  User-initiated jumps/seeks stay immediate by construction; menu-domain ends bypass
  (keep_vbuf covers them). Deferred "Phase B": title-domain *cell-command* jumps
  (Thayer's-class) still truncate — needs a VM provenance export. Sim:
  `iso_reader_vm_tb` T6–T8. Design: `docs/dvd_nav.md` "Natural-transition tail drain".
- **Rapid multi-seek robustness** — re-confirm on HW after the round-2 fixes (round-1 showed a
  "skipping record" in the Matrix opening that is a SOURCE-FILE defect, not our decoder — see below).
- **Cell-granular only** — sub-cell / time-based seek is deferred (needs mid-GOP resync glitch
  handling; cells start on clean GOP boundaries so cell seek is clean).

> **NOTE (updated 2026-07-09, USER-CONFIRMED): the Matrix-opening "skipping record" is a
> SOURCE-FILE / rip defect, NOT a decoder problem.** The same stutter/skip in that scene
> **reproduces identically in VLC on a PC** (which decodes MPEG-2 D1 with compute to spare),
> so the defect is in that ISO's encoding, not our real-time throughput. It is neither a seek
> bug nor a decoder-throughput bug — do not chase it via the transport/seek path OR the
> motion-comp rewrite. (Earlier this was misattributed to the "compute-bound high-motion
> stutter" and treated as the project's canonical worst case; that was wrong — Matrix was a
> confounded test vehicle. The genuine high-motion cases MiB act 3 and PAL BBB were fixed by
> the reference prefetch and the frame-drop governor respectively.)

---

## UX / interface strategy (authentic-DVD; gamepad + our own graphic OSD) — read before Phases 7–11

The interactive phases below (7–11) can balloon into a lot of **display-path RTL**, which
is exactly the routing-congested region (`docs/roadmap.md` "FPGA congestion"). Before
building any of it, this is the deliberate scope philosophy — anchored on **what a real
set-top DVD player actually did**, not on modern streaming UIs:

- **No draggable absolute scrubber bar (deferred).** Real DVD players had none, and a
  draggable position bar is the most expensive piece (needs the VTS **TMAP** time-map **+**
  drag input) — was deferred to Phase 8b, now **RETIRED outright (2026-07-10, user decision:
  the shipped seek UX is the final one)**. Note this is *not* the same as showing a **timecode /
  scrub-timestamp / chapter-progress readout**, which IS part of the Phase-11 graphic OSD
  (those need only the DSI/PGC timeline we already parse).
- **Selection is functionally a set of player-side stream switches** (the remote's
  **Audio / Subtitle / Angle** buttons switched which stream the player decoded, live,
  independent of the disc menu). This maps directly onto our pipeline — but the surface is
  the **gamepad's own buttons**, NOT the OSD (see the correction below).

> **★ CORRECTION (2026-07-10, Phase 10):** the OSD is **NOT** a near-free selection surface
> for *track lists*. MiSTer `CONF_STR` value labels are compile-time static, so a per-disc
> audio/subtitle track list (with real languages) cannot be an OSD menu item. Track/angle
> selection therefore lives on **gamepad cycle buttons** (Audio/Subtitle/Angle), which is
> also how a real DVD remote works. The MiSTer OSD is retained only for *fixed hardware/setup*
> choices (Disc Menus on/off, Video Standard, a numeric title override) — **not** for any
> playback interaction, which Phase 11 moves entirely onto the gamepad + our own graphic OSD.

**Three UI surfaces:**

| Surface | Fabric cost | Use for |
|---|---|---|
| **Gamepad buttons** (`joystick_0`) | ~zero | ALL playback interaction: play/pause, hold-to-seek FF/REW, chapter ±, audio/subtitle/angle cycle, disc-menu/select |
| **MiSTer OSD** (`CONF_STR` `O[...]`) | ~zero | HARDWARE/SETUP toggles ONLY (Disc Menus on/off, Video Standard, numeric DVD-title override) — **not part of the playback experience** (static labels, no dynamic lists) |
| **Custom in-fabric graphic OSD** (RTL, display path) | expensive (hotspot) | the Phase-11 transport UI: play/pause/FF/REW state, timecode, scrub-timestamp + chapter `n/N` readouts, audio/subtitle/angle track popups, subpicture bitmaps, disc-menu highlights |
| **Disc's own menus** (PGC nav VM + subpicture highlight) | big (done, Phases 2–5) | authentic root/title menus |

**Recommended build order (drives Phases 7–11 below):**

1. **Audio-track selection via a gamepad cycle button** — the cheapest real feature: pure
   `ps_demux` substream routing bounded by the IFO audio-stream count, **no overlay
   dependency**. (Phase 10, audio half — done, `docs/track_selection.md`.)
2. **Subpicture / subtitles** — forces us to build the **overlay blend layer** (subpicture
   is an RLE 4-colour bitmap composited over video). This is the load-bearing piece:
   the same overlay layer is later reused by transport popups and disc-menu highlights, so
   building it here is the unlock for everything visual. Toggle/track select via the gamepad
   Subtitle button. (Phase 10, subtitle half — done, PR fj#71/#73.)
3. **Chapter skip + hold-to-seek scrub via the gamepad** — needs the IFO/DSI timeline
   (Phase 7) for accurate boundaries; the actions are gamepad buttons, and the *feedback*
   (timecode, chapter `n/N`, scrub timestamp) is drawn by the Phase-11 graphic OSD. (Phases 7–8/8a.)
4. **The custom graphic OSD (Phase 11)** — our own in-fabric transport UI (state icons,
   timecode, scrub/chapter readouts, track-change popups) composited through the Phase-10
   subpicture blend, so **all playback interaction happens without the MiSTer OSD**. Lands in
   the congested corner, so gate it behind the congestion cleanup. (`dvd/debug_overlay.sv` is
   only a primitive rendering reference; the absolute draggable scrubber bar stays deferred.)
5. **Defer the disc's own menus** (Phase 11). The core already auto-plays the main feature
   ("largest VTS", `docs/dvd_nav.md`), so disc menus are polish, not a blocker to watching.

Net: **most of the "DVD remote" experience is gamepad-button plumbing (near-free)**; the one
genuinely new visual system we must build is the **subpicture/overlay layer**, and everything
else authentic (transport popups, the track/language indicator, disc menus) reuses it later. Keep heavy nav/seek/IFO logic
**in fabric but off the DISPLAY path** — it's control-path state-machine work (like the
in-fabric ISO navigator), so it costs modest ALMs but does **not** compete for the congested
display/overlay hotspot. (This is the self-contained-`.rbf` way; no HPS daemon.)

---

## Phase 7 — DVD Navigation Foundation (nav packs / DSI)

**Goal:** Parse the in-stream navigation data that seeking, chapters, and angles all
sit on top of. High-leverage shared infrastructure — build it once.

Right now `dvd/ps_demux.sv` deliberately **skips** nav packs (`private_stream_2` /
`NV_PCK`, stream id `0xBF`) by length so they can't desync the stream. Multi-angle,
chapter, and accurate-seek features need that data **parsed** instead of discarded.

> **In fabric, not the HPS** (self-contained `.rbf` requirement). The `dvd/dvd_iso_reader.sv`
> in-fabric navigator already does random-access sector reads and ISO9660 parsing in RTL —
> the IFO/PGC/DSI work extends that same reader, it does NOT move to a Linux daemon. IFO/PGC
> parsing is small sequential-parse state-machine work (like the ISO9660 walk), so it costs
> modest ALMs and — crucially — lands in the CONTROL path, **not** the congested display
> hotspot (only display-path *rendering* competes there). Same fit discipline as the ISO
> reader: sync-read BRAMs, shadow the active record window into registers (see
> `dvd-iso-navigator` memory).

### Tasks
- [x] **Parse NV_PCK DSI in fabric** (PR fj#95, 2026-07-09 —
  ✅ HW-CONFIRMED no-regression: multiple test ISOs play cleanly with the DSI sink live;
  DSI parse itself sim-proven byte-exact). The nav pack's PCI half already routes to `nav_pci`
  (menu buttons); its **DSI** half (substream `0x01`) was discarded and is now routed out of
  `ps_demux` to a new **`dvd/nav_dsi.sv`** (twin of the PCI path, `dsi_enable` gate + new
  `S_DSI_DATA`). Parses the VOBU's presentation↔sector data: scalars → registers
  (`nv_pck_lbn`, `vobu_ea`, `1stref_ea`, `c_idn`, **`c_eltm`** cell-elapsed time,
  next/prev VOBU+video); the fwda/bwda ±time **seek tables** (Phase 8) and `sml_agli`
  **angle offsets** (Phase 9) → one sync-read M10K `dsi_tbl` (fit-safe), exposed but not
  yet consumed. Current/total time surface on multi-row overlay rows 18/19 (DSI `c_eltm`
  + reader `pgc_playback_time`, `{mm,ss}` BCD via `tools/osd_read.py`) — **but that overlay
  is `` `ifdef DEBUG_OVERLAY `` and compiled OUT of the release build** (in release, `O[2]`
  drives only the menu-highlight blocks), so the on-screen time shows **only in a
  DEBUG_OVERLAY build**. A release-visible readout is a follow-up. **Release HW gate =
  no-regression** (ISO plays with the DSI sink live); the DSI parse is sim-proven (byte-exact
  vs a real MiB sector). Staged: whole-title running current time (cell-duration prefix-sum).
  Tool: `tools/nav_extract.py --dsi`. Tests: `bench/dvd/nav_dsi_tb.sv` + extended
  `ps_demux_ps2_tb.sv`. See **`docs/dvd_nav.md`** "DSI / nav foundation".
- [x] **In-fabric VMGI title selection** (`feature/ifo-title-select`, 2026-07-06): parse
  `VIDEO_TS.IFO` (VMGI) **TT_SRPT** in fabric. **⚠️ RETIRED from Auto (2026-07-06):** "title 1"
  chose a short logo/license clip on multi-feature discs (Big Buck Bunny: title 1 = a 20 s CC
  clip). Sim-verified (`bench/dvd/iso_reader_ifo_tb.sv`, repurposed); parse states retained but
  unreachable for Auto.
- [x] **Title selection: Auto = largest VTS + OSD manual override** (`feature/longest-title-select`,
  ✅ **HW-CONFIRMED 2026-07-06, PR fj#76** — BBB `DVD Title = 2` plays VTS_02; Auto plays MiB):
  Auto plays the **largest VTS** (longest-title proxy); **`O[31:28] DVD Title`** =
  Auto/1..15 picks `VTS_0N` for multi-feature discs where the feature is neither largest nor
  title 1 (BBB → `2` = VTS_02). Investigation confirmed VLC "just knows" because libdvdnav
  **executes the disc's DVD-VM** from the First Play PGC (`VMGI@132`). *(Correction
  2026-07-07: BBB's FP is actually a plain `JumpTT 4` — the "JumpVTS_TT" reading came from
  the pre-rewrite decoder's swapped op codes. Phase 4 now executes it in fabric; see the
  graphical-menu item below.)* `tools/iso_nav_check.py` dumps FP/TT_SRPT/all-VTS durations.
  `docs/dvd_nav.md`.
- [x] **★ Graphical DVD menu (root/title menu navigation)** — the real title/episode selector.
  **HW-confirmed and shipped.** Phases 0-3 (menu domain PR fj#80, PCI/HLI buttons PR fj#81) +
  **Phase 4 = the full DVD-VM interpreter (`dvd/dvd_vm.sv`), MERGED PR fj#82** — the disc's nav
  commands EXECUTE: First Play boot (no auto-play with `O[1]` On), button commands, CallSS/RSM,
  JumpTT via TT_SRPT, POST at title end, SetSTN stream selection. Golden model
  `tools/dvd_vm_ref.py` (faithful libdvdnav port) validated on MiB/BBB/Matrix. The per-disc
  **menu refinements** (highlight render, keep_vbuf transitions, menu-still cold re-decode,
  aspect, 2nd-loop highlight, timed stills) shipped as **PR fj#83–fj#90** and are tracked in
  `docs/dvd_menu_refinements.md` (see its Status roll-up) — all HW-confirmed except §6 aspect
  (PR fj#86) and §6b timed stills (PR fj#90), which await a hardware confirmation pass.
  Remaining genuinely-new nav work: Phase 6 (exact chapters/PTT), Phase 7+ (NV_PCK/DSI, seek,
  angles). See `docs/dvd_vm.md`.
- [x] **In-fabric PGC cell-timeline playback (v1)** (`feature/pgc-cell-timeline`, 2026-07-06,
  ✅ **HW-CONFIRMED** — MiB full feature plays cleanly, no regression): parse the selected
  VTS's `VTS_xx_0.IFO` (VTSI_MAT → VTS_PGCIT → PGC → cell playback table) and stream the PGC's
  **cells in program order** instead of the VTS's title VOBs linearly. Cell RBNs map through
  the extent table into `sd_lba` (no `vtstt_vobs` needed). Any malformed/absent PGC → linear
  whole-VTS fallback. Fit: BRAM cell list (the first build hit 106% ALMs from a 128-entry
  async register file — moved to M10K + reused `strm_idx`). Sim: `bench/dvd/iso_reader_pgc_tb.sv`
  (out-of-order cells → program order + unreferenced sector skipped; malformed → fallback);
  `tools/iso_nav_check.py` dumps the cell list + flags reordered cells. The **cell-reorder**
  path (physically non-monotonic cells) is sim-only. **Seamless-branch interleaved blocks**
  (the `interleaved` cell bit — Matrix "white rabbit" / T2 extended scenes, physically
  monotonic cells with *within-cell* interleaving) are now handled by the ILVU `next_vobu`
  follow (PR fj#112, ✅ HW-CONFIRMED 2026-07-12 — Matrix white-rabbit chapters + T2 extended
  scenes play smoothly) — see `docs/dvd_nav.md` "Seamless-branch interleaved blocks".
  See `docs/dvd_nav.md` "PGC / cell timeline". Deferred on top of it (hooks noted in RTL):
- [x] **Exact TTN→PGC map** via `VTS_PTT_SRPT` — ✅ **HW-CONFIRMED** (PR fj#127, light test:
  no regression, movies unaffected by construction). `JumpVTS_PTT t:p` resolves the exact `VTS_PTT_SRPT[t][p-1] →
  {pgcn,pgn}` (was `ptt≈pg`); the current title's full PTT table loads into `ptt_mem` and
  the HUD `CH n/N` total is now the exact `nr_of_ptts`. See `docs/dvd_nav.md` "Exact
  chapters / PTT (Phase 6)". **Deferred (documented):** cross-PGC user chapter-skip +
  PTT-based current-chapter `n` (would rewrite the HW-confirmed `chap_st`, and only affects
  multi-PGC game discs — no observable movie benefit).
- [ ] **`program_map_offset` seekable timeline** (presentation time ⇄ disc sector) — the
  PGC `palette`@164 and cell category word are already handled (Phases 3/9); the exact
  time↔sector map beyond the DSI ±10 s scrub is unbuilt (Phase-8b TMAP was retired).

**Checkpoint:** The core (in fabric) knows current time / total time / chapter boundaries
at all times, and can map a target time to the sector to start reading from.

---

## Phase 8 — Seeking & Chapters — ✅ HW-CONFIRMED (PR fj#96)

**Goal:** Jump to an arbitrary time (scrub) or chapter, cleanly.

Seeking is a **timeline discontinuity** — you discard the current position and restart
elsewhere — so it needs more than a sector jump. **Design + verification:
`docs/dvd_nav.md` "Seeking / Phase 8".** Both actions build on the existing cell-seek
primitive (block-boundary latch + `seek_ack` → VBUF-flush/A/V-reanchor). Scope this PR =
**chapter skip + relative ±10 s DSI scrub**; absolute-timestamp scrub-bar (VTS TMAP)
was deferred to Phase-8b — **since RETIRED (2026-07-10, user decision), see Phase 8a below.**

### Tasks
- [x] **Sector jump** (in fabric, `dvd_iso_reader`): chapter → entry cell via the PGC
  `program_map` BRAM (`pmap_mem` + `chap_st` resolve FSM, `chap_pulse`/`chap_dir`); time
  scrub → target RBN via the DSI fwda[3]/bwda[15] seek tables → a raw-RBN seek
  (`seek_rbn_pulse`/`seek_rbn`, `S_RBN_SCAN` containing-cell scan).
- [x] **Buffer flush + decoder reset on the jump** — reused from the transport-seek
  contract (`seek_ack` → `load_flush`+`vbuf_flush`; AC-3/ps_demux/audio_ring self-heal).
- [x] **Re-anchor A/V sync** — reused (`av_sync` re-anchors on the >0.7 s PTS discontinuity).
- [x] **Decode-to-I-frame masking** — free: seek targets are VOBU boundaries = GOP/I-frame
  starts, and the existing flush blanks until the first decoded picture. (Revisit only if
  HW shows a glitch frame.)
- [x] **Chapter skip (next/prev)** = seek to a chapter boundary from the PGC program_map.
- Gamepad: **B2/B3 = chapter −/+** (was cell±1), **D-pad L/R = ±10 s scrub** (title only).
- Tests: `nav_dsi_tb` (+10 s target = RBN 9580 byte-exact), `iso_reader_chapter_tb`,
  `iso_reader_seek_tb` TEST4 (mid-cell scrub); golden `tools/nav_extract.py dsi_seek_map` +
  `tools/iso_nav_check.py` chapter map.

**Checkpoint: ✅ MET (HW-confirmed, PR fj#96).** Chapter skip (B2/B3, next + prev) and
±10 s scrub (D-pad L/R) work on real hardware, resuming in sync. Prev-chapter restarts the
current chapter unless <~5 s in (DSI `c_eltm` gate) — HW-confirmed after an initial
cell-granularity bug (fixed 2026-07-10). (Note: the shipped build carries the known,
separate output-path chroma fringe — placement-class, not Phase-8 logic.)

### Phase 8a — Hold-to-seek, SEEK-ON-RELEASE w/ acceleration — ✅ HW-CONFIRMED (PR fj#101)

Hold D-pad Left/Right to choose a seek target (the offset **accelerates** the longer it's
held), then **release to jump there** with one seek. While held the video **pauses** and audio
holds. In `dvd/scrub_ctrl.sv`.

**Why seek-on-release** (two live-still-scan attempts failed on HW): the MPEG-2 decoder
(~1–2 MB VBUF + a watchdog, built for continuous playback) can't cleanly flush→re-lock→show a
still fast enough. Round 1 (paced on `nav_dsi.dsi_commit`, before the I-frame) went mostly
black + played in the gaps; round 2 (paced on `video_live` + freeze/mute) froze on the stale
frame and the un-frozen ~1 s re-lock window **tripped the watchdog** (720×179 resync / black).
So a live still-scan fights this decoder. **Seek-on-release does exactly ONE flush/re-lock, on
release** — robust, like the confirmed single-seek transport. Holding is a plain pause
(`hold_freeze` → the proven pause holds, watchdog suppressed throughout); an accelerating
sector offset (tier step `span >> {10,8,6,5}`) accumulates against the reader's title RBN span;
release clamps and issues one `seek_rbn`. Tests: `scrub_ctrl_tb` (hold→release, acceleration,
backward, clamp, tap no-op, freeze, flip, gate) — all pass.

**Position indicator = Phase 11.** `scrub_ctrl` exposes `bar_*` (playhead + target position)
for an on-screen seek bar, but that's **deferred to the Phase-11 graphic OSD** (per the design
in Phase 11) — so for now holding shows a frozen frame with no cursor. **✅ HW-CONFIRMED
(2026-07-10):** hold Right/Left → video pauses; release → seeks proportionally to how long you
held (further the longer held), in the held direction; a quick tap ≈ no-op; end/start clamps;
menus + chapter B2/B3 unaffected. (The two live-still-scan rounds before this failed — see the
"why seek-on-release" note above.)

~~Follow-up (Phase-8b): absolute arbitrary-time scrub-bar via the VTS TMAP time-map table.~~
**Phase-8b RETIRED (2026-07-10, user decision):** the seek-on-release scrub + chapter skip +
seek bar is the accepted, final seek UX — the TMAP absolute-time scrubber will not be built.
Don't re-propose it.

---

## Phase 9 — Multi-Angle

> **✅ DONE — HW-CONFIRMED 2026-07-10 (PR fj#98; MiB title 13/VTS_14 five-angle B6 cycle verified on the board).**
> Follows the selected angle's ILVU chain **in fabric**; **B6 "Angle"** cycles angles
> seamlessly (time-continuous — no VBUF flush / no A/V re-anchor). Test vehicle: **MiB
> title 13 → VTS_14** (a real 5-angle FX breakdown). Full design + the real disc anatomy:
> `docs/dvd_nav.md` "Multi-angle / Phase 9".

**Goal:** Switch camera angles seamlessly on multi-angle discs.

Angles are stored as **interleaved units (ILVUs)** within an interleaved block; the DSI
in each nav pack points to the selected angle's next ILVU. Unlike seeking, an angle
switch is **time-continuous** (all angles share one timeline), so **no buffer flush or
re-sync is needed** — it's purely a navigation/demux problem, handled **in fabric** in the
`dvd_iso_reader` sector path (not a Linux daemon).

### Tasks
- [x] **Follow the selected angle's ILVU chain** (in fabric): the reader self-parses each
  VOBU's NV_PCK (`sml_pbi.category` + `sml_agli`) at the fetch pointer and does a no-flush
  RBN jump past the sibling angles' ILVUs at each `BLOCK|LAST` boundary. The PGC angle
  block is one cell per angle (category `block_type==1`); the reader picks the `cur_angle`
  cell then follows its ILVU chain and skips the sibling cells.
- [x] Track angle count + current angle; switch at the next ILVU boundary (`cur_angle` read
  live by the snoop, so a switch is seamless).
- [x] Expose angle count / current angle to the UI (`cur_angle`/`angle_count` → debug
  overlay row 20, DEBUG_OVERLAY build; a release-visible indicator is a follow-up).
- [x] (Audio is generally common/aligned across angles; if an angle carries independent
  audio, the AC-3 self-heal covers the brief resync.)

**Checkpoint: ✅ MET (HW-confirmed 2026-07-10, PR fj#98).** On a multi-angle disc, switch
angles during playback with no interruption to the timeline — MiB title 13 (VTS_14) plays
one clean angle and B6 cycles all 5 angles seamlessly on the board.

**Known v1 limits (documented in `docs/dvd_nav.md`):** switch takes effect within ~1 ILVU
(the arm reads `cur_angle` at the previous `BLOCK|LAST`); the DSI `sml_agli` (seamless)
path only — the PCI `nsml_agli` (non-seamless) table is not consulted; a time-scrub landing
inside an interleaved block streams linearly (no angle follow) until the next cell.

---

## Phase 10 — Audio & Subtitle Track Selection

**Goal:** Choose among multiple audio tracks and subtitle (subpicture) tracks.

> **★ SELECTION SURFACE CORRECTED (2026-07-10):** the earlier plan routed both selectors
> through an **OSD list**. That premise is **wrong** — MiSTer `CONF_STR` value labels are
> **compile-time static**, so a per-disc track/language list cannot be an OSD item
> (`sys/hps_io.sv` has `status_menumask` = hide-whole-items + a numeric `info` popup, but
> no dynamic per-value strings). Selection now lives on **gamepad cycle buttons** (the
> authentic DVD-remote surface); the visual track/language indicator is a Phase-11 in-video
> overlay. The **subtitle half is still the load-bearing one** — it forced the subpicture
> overlay-blend layer that every later visual feature reuses (done, PR fj#71/#73).

### Audio + subtitle track enumeration + selection — ✅ HW-CONFIRMED (PR fj#100)
PR fj#100 (`feature/track-enumeration`). Design: **`docs/track_selection.md`**.
A DVD carries up to 8 audio streams (AC-3 `0x80–0x87`, DTS `0x88–0x8F`, LPCM
`0xA0–0xA7`) and up to 32 subpicture streams (`0x20–0x3F`); `ps_demux` already routes ONE
of each via `aud_track`/`sp_track`. What was missing was knowing how many exist.
- [x] **Enumerate from the IFO** — `dvd_iso_reader` S_ATTR sweep parses the title VTSI_MAT
  `vts_audio_attr`@516 / `vts_subp_attr`@598 (counts, codec, channels, ISO-639 language;
  offsets verified byte-exact on MiB VTS_21). Exposes `audio_ntracks`/`subp_ntracks` + a
  per-track metadata readout.
- [x] **Bound the selectors** — a switch is clamped to the real track count, so a pick past
  the count can never feed `ps_demux` a non-existent substream (→ silence/garbage).
- [x] **Gamepad selection** — B7 "Audio" cycles audio tracks, B8 "Subtitle" cycles
  `off → tracks → off`. OSD `O68`/`O[15]`/`O[26:24]` removed.
- [x] On switch: audio-only re-sync (`aud_resync` resets `audio_ring` + `dvd_audio_decode`,
  NOT `ps_demux`) re-phases the audio against the video-continuous STC without disturbing the
  picture. (Rounds 1–3: a `load_flush`/`ps_demux` reset corrupted video; a 4-module reset net
  wouldn't route; the 2-module version fits + works.)
- [x] **HW-CONFIRMED on MiB VTS_21** (2026-07-10): audio 4-track cycle audible, subtitle
  4-track+off visible, no out-of-range garbage, audio switch stays in sync with no video
  corruption.
- [ ] **(Phase 11) On-screen track/language popup** — part of the custom graphic OSD (the
  piece the MiSTer OSD can't do); uses the `attr_*` readout + the subpicture blend.

### Subtitle (subpicture) selection
DVD subtitles are **subpicture** streams (`private_stream_1` substream ids `0x20–0x3F`):
run-length-encoded 4-colour overlay bitmaps with their own PTS and on-screen
coordinates — NOT text. Needs a decoder + a video-overlay blend.

> **✅ v1 DONE (IN FABRIC) — HW-CONFIRMED 2026-07-06, PR fj#71 (`DVD_subpic_rel`).**
> Subtitles render over the video on real hardware. Full design + decisions + the two
> bring-up gotchas (CONF_STR `O[15]` bit form; congestion → combinational blend +
> `debug_overlay` compiled out for the release build): **`docs/subpicture.md`**.

- [x] Route the selected subpicture substream out of `ps_demux` — new `sp_*` port, O[15]
  enable + O[26:24] track (intercepted before the audio-track filter; no sub-header).
- [x] **Subpicture decoder (RTL, `dvd/spu_decode.sv`):** buffers the SPU, parses the DCSQ +
  nibble-RLE into a full-frame 2-bpp bitmap, on/off timed against the `av_sync` STC.
- [x] **Overlay blend (RTL, `dvd/subpic_blend.sv`):** standalone reusable RGB alpha compositor
  at the display tap — **the same layer the transport UI / disc menus reuse (Phase 11).**
- [x] Subtitle on/off + track select via the OSD.
- [x] **CRT-480i field-aware render** (branch `feature/subpic-crt480i`, PR fj#73, ✅ HW-CONFIRMED
  2026-07-06): the render row-base accumulator now steps by `2*STRIDE` and re-bases on the field
  parity when `crt_eff` (interlaced) — `core_v_pos` is already the absolute frame line in 480i.
  Both fields reassemble the golden bitmap in sim; subtitles correct on the real CRT.
- [x] **IFO PGC palette for real colours — DONE (not a fixed fallback).** `spu_decode`
  emits the SET_COLOR 4-bit indices; `emu` looks them up in `dvd/pgc_palette.sv` fed the
  PGC's IFO palette @164 (streamed by the reader via `pgc_pal_we`), so title subtitles AND
  menu highlights render with the disc's authored colours. SET_CONTR alpha honoured.
  Hardened for seeks by the `pgc-palette-seek-reset-bug` fix (palette on `reset_n`, not the
  per-seek pipe reset). The earlier "v1 uses a fixed high-contrast palette" note was stale.
- [ ] **Follow-ups (minor):** HDMI-480i (O9) subtitle (needs the pixrep `q_x` halving — CRT
  is native width so it was addressed first); CHG_COLCON; per-disc subtitle-track
  enumeration (needs IFO — folds into the Phase-10 audio/subp attribute parse); HW
  confirmation on a subtitle disc (progressive + CRT 480i).

**Checkpoint:** Pick audio track and subtitle track from the UI; subtitles render over
the video and can be turned off. *(Subtitle ✅ HW-CONFIRMED, PR fj#71/#73; audio-track OSD
selection is the un-started Phase-10 half — see the follow-ups above.)*

---

## Phase 11 — Transport UI (custom in-fabric graphic OSD)

**Goal:** A **self-contained graphic on-screen display of our own**, rendered in fabric and
composited over the video, that makes **all content interaction possible without ever opening
the MiSTer OSD menu**. The gamepad is the input surface (play/pause, FF/REW jog, chapter ±,
audio/subtitle/angle cycle, disc-menu/select — already plumbed in Phases 8–10); this phase
adds the **visual feedback layer** so the user can actually see state, status, and where they
are in the disc. The MiSTer OSD is demoted to hardware/setup toggles only (Video Standard,
Disc Menus on/off, numeric title override) — it is **not** part of the playback experience.

This is a real graphic OSD (icons + a glyph/font ROM composited through the Phase-10
**subpicture blend layer**, `dvd/subpic_blend.sv`), not the MiSTer `CONF_STR` menu and not
just block-text. `dvd/debug_overlay.sv` (block-bit rows) is only a primitive rendering
reference. Everything here lands in the routing-congested **display hotspot**, so it is gated
behind the congestion cleanup and built incrementally on the proven overlay layer.

### What the OSD shows *(✅ HW-CONFIRMED 2026-07-10, PR fj#103; design: `docs/transport_hud.md`)*
- [x] **Transport state indicator** — play/pause and fast-forward/rewind: `►` / `❚❚` /
  `►►` / `◄◄` with the current scrub speed tier shown as **×1..×4** (since the PR fj#101
  seek-on-release rework the tiers are span-relative step rates, not fixed seconds).
  Appears on a transport action and auto-hides after ~2.5 s.
- [x] **Playback status / timecode** — **whole-title elapsed** (the reader's per-cell
  playback-time BCD prefix sum + DSI `c_eltm`, rate-aware frame carry via
  `dvd/bcd_time_add.sv`) `/` total (`pgc_playback_time`), plus chapter `CH n/N` (new
  reader `cur_pgm` query walk). A **Display button (B9)** toggles a persistent status
  line; otherwise it flashes on state changes. (Readout is parse-front-timed — leads the
  picture by the VBUF depth, the Phase-7 characteristic.)
- [x] **Scrub feedback (seek bar)** — *the original "live timestamp updating as it hops"
  is IMPOSSIBLE post-PR fj#101*: holding is a plain pause (no DSI updates), so feedback is
  `dvd/seek_bar.sv` — fill = the playhead at hold start, an **amber cursor = the
  accumulating release target**, riding scrub_ctrl's `bar_*` outputs against the title
  RBN span; the status line shows `►►×n` + direction while held.
- [x] **Chapter feedback** — on a chapter skip: the `CH 15/23` popup + the progress bar
  pops with the landed position (current program from the reader's query-only pmap walk).
- [x] **Track-change popups** — `AUDIO 2/4 FR`, `SUB 1/3 EN` / `SUB OFF`, `ANGLE 2/3`,
  fed by the Phase-10 `attr_*` per-track metadata. Single slot, last event wins.
  **This is the piece the MiSTer OSD fundamentally cannot do** (dynamic per-disc strings).
- [x] **Progress bar (visual-only) with chapter ticks** — pops on **pause / seek /
  chapter change** with the LIVE playhead + a notch per chapter (tick columns converted
  once per PGC load from shadow copies of the pm/cell-first streams through the bar's
  shared serial divider). **Visual only — no seek-from-the-bar** (that would need drag
  input + the TMAP; deliberately out of scope). Detailed design below.

#### Progress bar — design (feasibility settled 2026-07-10, NOT a liability)

The old "no scrubber" verdict predated the overlay layer, the parsed timeline, and the seek
primitive — all three now exist, so a *visual* bar is a bounded, low-risk feature (only a
*draggable absolute* bar still needs TMAP; a display bar does not). Approach:

- **Position model = sector/RBN-based** (not wall-clock time). `fill = (cur_rbn −
  title_first_rbn) / (title_last_rbn − title_first_rbn)`, clamped [0,1], where
  `cur_rbn = nav_dsi.dsi_nv_pck_lbn` (live), and the title span is captured from the reader's
  cell table at PGC load (`cell_first_mem[0]` … `cell_last_mem[cell_count−1]`). Chosen because
  it (a) needs no BCD decode or per-cell time prefix-sum, (b) is monotonic, and (c) makes the
  fill and the **chapter ticks derive from the same RBN denominator** so they stay consistent.
  Under VBR it's a slight nonlinear approximation of wall-clock — fine for a visual bar; total
  wall-clock time is available (`pgc_playback_time`) if an exact time-based variant is ever
  wanted (needs the staged-out per-cell running-time prefix-sum, see Phase 7).
- **Chapter ticks** = for each program `p` in `1..cmd_nr_pgm`, its start
  `chap_rbn = cell_first_mem[pmap_mem[p] − 1]` → tick column `= (chap_rbn − title_first) ·
  BAR_W / (title_last − title_first)`. The reader enumerates these once at PGC load (walk
  `pmap_mem` → `cell_first_mem`, two dependent sync-BRAM reads per chapter) and streams them to
  the bar; both tables are already fully populated after PGC parse.
- **Math (control path, off the display hotspot)** — one shared sequential shift-subtract
  divider computes `fill_px` (re-run when `cur_rbn` moves) and each `tick_col[k]` (once at
  load). Low rate; no per-pixel division.
- **Renderer (display path)** — a coordinate-addressed compositor keyed on the existing
  `core_h_pos`/`core_v_pos` (12-bit, clk_sys), inserted in the registered output mux at the end
  of `emu.sv` (same stage/pattern as the O[2] debug blocks, over `sub_r/g/b`). Bottom-anchored
  (`pal_eff ? 576 : 480`), ~600 px wide track: dim background, bright fill to `fill_px`, a
  thin border, and chapter notches. To keep the hotspot cheap the ticks render with a **single
  comparator + a monotonic pointer** (`tick_col[]` is sorted ascending, so as the raster scans
  the bar left→right one pointer walks the tick list — no bank of comparators).
- **Pop-up logic** — `visible = paused OR (pop_timer ≠ 0)`; the timer (~3–4 s) is armed by
  `pause_edge | seek_ack` (and `seek_ack` already fires for a scrub hop, a chapter skip, AND a
  plain seek, so all three requested triggers are covered), and it **stays on while paused**.
- **Cost / gating** — lands in the routing-congested display corner (the chroma-fringe / Fmax
  region), but is small (a filled rect + notches, less than the text HUD); gate it behind the
  congestion budget and the per-build `fmax_check` gate. A `progress_bar.sv` module + a sim tb
  (fill math, tick columns, visibility, a few pixel coords) would mirror the `scrub_ctrl`
  pattern.

### How it's built
- [x] **Input / control plumbing** (landed Phases 8–10): audio/subtitle/angle/chapter and the
  Phase-8a hold-to-seek scrub as `joystick_0` buttons writing control registers — the full
  "DVD remote" already works headless; this phase makes it *visible*.
- [x] **Renderer** — `dvd/transport_hud.sv`: a generated glyph ROM (`tools/hud_font.py` →
  `dvd/hud_font.mem`, one M10K) + a 2×32-cell text plane, rendered by a registered pixel
  pipeline that is a **pure function of (x,y)** (interlace-safe by construction — proven
  per-pixel by `hud_frame_tb`'s field-order pass) and **priority-muxed into the ONE
  existing `subpic_blend` register stage** (no second blend, 0 new DSP — the only
  display-hotspot edit). Bottom status line + popup line + `dvd/seek_bar.sv` between them.
- [x] **HUD state machine** — auto-show/auto-hide 2.5 s timers, B9 "Display" persistent
  toggle, event-rate formatter (BCD nibbles → glyphs, snapshot per pass), value feeds from
  the existing reader/nav/attr outputs (+ two small reader additions: the `cur_pgm`
  query-only pmap walk and the `cell_start_mem` prefix sum). Suppressed while a menu is up.
- [x] **Absolute draggable scrubber bar — RETIRED, will not be built** (2026-07-10, user
  decision: the current seek solution is the accepted final UX). It would have needed the VTS
  **TMAP** time-map (Phase 8b, also retired). The Phase-11 OSD's *timecode + chapter progress*
  readouts cover the need without TMAP.

**Checkpoint:** Full DVD control and status entirely via the gamepad and our own on-screen
graphic OSD — transport state (play/pause/FF/REW with speed), whole-title timecode, the
seek-bar cursor while scrubbing, chapter skips with `15/23` progress, and
audio/subtitle/angle change popups with real languages — **without opening the MiSTer OSD**
at any point during playback. *(✅ HW-CONFIRMED 2026-07-10, PR fj#103; the gate checklist =
the checklist in `docs/transport_hud.md`.)*

---

## Public alpha release prep (2026-08-23) — 4 phases

The film/TV playback path is judged release-ready (Akira and Castle in the Sky both
played clean on HW 2026-08-23, incl. the parental `SetTmpPML` no-op — no mis-branch).
Interactive game discs stay **known-incomplete** (see `docs/disc_sweep.md` Pass-2
Clusters A/B). These four phases are the remaining gate to a public alpha drop.

Measured before planning, so they are NOT on the list: **MPEG-1 Layer II audio**
(`ps_demux` skips stream IDs 0xC0–0xDF ⇒ silent playback) and **UDF-only images**
(reader is ISO9660-only ⇒ won't load). A VTSI_MAT audio-attribute census over all 34
library ISOs found **0 MP2 discs** (34 AC-3, 2 LPCM, 2 DTS) and **0 UDF-only images**.
Both are real conformance gaps with no local vehicle → messaging, not decode support.
**⤷ SUPERSEDED for MP2 (2026-08-24, branch `feature/mpeg1-codecs`): MP2 now DECODES
in fabric** — ps_demux routes 0xC0–0xC7 → `dvd/mp2_reframer.sv` → `dvd/mp2/
mp2_decode.sv` (bit-exact vs `tools/mp2_ref.py`), and MPEG-1 VIDEO decode is added
on the same branch. The unsupported-audio notice is narrowed to format 3. See
**`docs/mpeg1.md`**.

| Phase | Branch | Scope | Status |
|---|---|---|---|
| 1 | `feature/enduser-defaults` | Ship end-user defaults, not developer defaults | ✅ this change |
| 2 | `feature/failure-messaging` | On-screen messages for the 3 silent-failure modes | ✅ merged-pending (PR fj#180) |
| 3 | `feature/readme-release` | README, LICENSE + NOTICE, rip + settings docs | ✅ (PR fj#181) |
| 4 | `feature/alpha-release` | Version scheme, tagged build, final soak | ✅ (PR fj#182) — soak is the remaining HW step |

## VCD / SVCD playback (bin/cue direct) — ✅ HW-CONFIRMED 2026-08-24

**2026-08-24, branch `feature/vcd-svcd-playback` — see `docs/vcd_svcd.md`.** Select a
bin/cue rip's data-track `.bin`: in-fabric raw MODE2/2352 deblock (Form-2 payloads,
Form-1/ISO track skipped), MPEG-1 system-stream demux (auto-detected per pack),
44.1/32 kHz MP2 output NCO (closes the "8.8 % fast" item), SVCD 480-wide analog fill
(the `< 720` predicate widening — DVD sub-D1 704/544 now fills too, reversing the
earlier scope), and whole-file seek + pause (raw seeks snap to a sector = pack
boundary; flat `.mpg`/`.VOB` seeks re-sync via a post-seek pack hunt, and now seek
too). Not in v1: VCD menus/PBC, CD-DA tracks, 2336-byte images, 23.976 film VCDs.
✅ HW gate passed 2026-08-24 (user report: VCD/SVCD good on analog + HDMI, seeking
works). Remaining sub-items (NTSC cadence, 16:9 SVCD, release-build DVD regression):
`docs/vcd_svcd.md` §6.

### Phase 1 — end-user defaults ✅ (this change)

Full CONF_STR audit against an end user rather than a developer. **One functional
change:** `O[1] Disc Menus` **Off → On** — a core called a DVD player that ignores the
disc's authored menus by default reads as "menus don't work", and the menus-off path
falls back to the largest-VTS heuristic, which is documented to pick the wrong title on
some discs. Every other default audited and left as-is (Aspect Auto, Audio On, Audio Out
Decode HDMI, Player Language English, Interlaced Out Off, Analog Out Auto, Analog Aspect
Auto, Video Standard Auto, Frame Drop On, Audio Genlock On, Film 24p Auto, A/V Offset
+100 ms, Debug Overlay Off, Title VTS Auto).

**⚠ The saved-status hazard (applies to every future default flip).** A MiSTer
`CONF_STR` value list is positional — status value 0 is the FIRST label — and the
framework persists the whole 128-bit status word per core in
`/media/fat/config/DVD.cfg`. Reordering a list therefore changes what an ALREADY-SAVED
bit means: a stale cfg from an older build decodes `status[1]=1` with the old meaning
and comes up **Off**, i.e. the release whose headline is "menus default on" silently
disables them for every existing user. Mitigations: (1) `menus_on` now inverts the bit
(`~status[1]`), (2) release notes must say *delete `DVD.cfg` after updating*, and
(3) do ALL default reordering in this one phase rather than across several releases.

Also fixed here: two stale option comments — `Frame Drop` claimed "Default Off (safe
A/B)" when its list has been `On,Off` for some time (and PR fj#158's film cadence-slip
corrector does not run with it Off), and the `Disc Menus` block still described
Phase-2 proto-nav with "no button highlights (Phase 3) or nav-command execution
(Phase 4) yet" long after both shipped.

### Phase 2 — silent-failure messaging ✅ (PR fj#180)

Three failure modes produced no explanation on screen, each an undiagnosable bug
report. All three reuse the proven `CSS ENCRYPTED` persistent-HUD path (PR fj#160):
`transport_hud`'s `pop_type` gains 5/6/7 (it was already 3 bits, so 0..7 fits with no
width change), and the detectors live next to the `css_scrambled` latch in `emu.sv`.

1. **Unplayable image** → persistent **`UNSUPPORTED IMAGE`**, menu-exempt.
   **★ The discriminator is deliberately BEHAVIOURAL, not the file extension.** The
   obvious implementation — read `hps_io`'s `ioctl_file_ext` (or infer from
   `ioctl_index[7:6]`) and fire when the user picked `.iso` — was rejected: neither
   encoding is verified in this fork (`ioctl_file_ext` isn't even wired into `emu.sv`),
   and guessing its packing risks firing on every `.VOB`. Instead: the reader falls back
   to whole-file linear streaming for anything non-ISO9660, which is the *intended* path
   for a bare `.VOB`/`.mpg`/`.m2v` — and those decode within a second. An image the
   reader can't navigate (UDF-only, or truncated/garbage) takes the SAME path and never
   produces a picture. So the test is `~iso_mode & ~video_live` sustained for
   `IMG_WD`, sticky until the next load. This is also strictly more general —
   it catches any unplayable file, not just UDF. **The window measures STREAMING time,
   not wall time** (HW round 2 — see below): it advances only while sector data is
   actually being delivered, and is ~20 s wide.
2. **Unsupported audio** → persistent **`AUDIO UNSUPPORTED`**, menu-exempt.
   Driven from the IFO's per-track `audio_format` (`attr_a_fmt`, already parsed for
   track enumeration in PR fj#100) rather than by sniffing PES: formats 2 (MPEG-1
   Layer II) and 3 (MPEG-2 ext) ride `stream_id` 0xC0–0xDF, which `ps_demux` skips by
   design ⇒ silent playback. Suppressed under O5-Off / passthrough (the receiver
   reports format itself). **0/34 library discs use it** — this ships as a message, not
   decode support, because there is no local vehicle to develop a decoder against.
3. **Title-VTS notice** → one-shot **`TITLE VTS nn`** at mount, hidden in menus.
   ⚠ **Re-scoped during implementation:** the original plan showed this on every mount,
   but Phase 1 made Disc Menus On the default, so the disc's own VM picks the title and
   the largest-VTS heuristic — the thing documented to pick wrong — only runs with menus
   **Off**. Gated on `~menus_on` accordingly: it keeps the stated purpose (a wrong pick
   is self-evident, and the P1 `Title VTS` override becomes discoverable) without
   putting a debug-flavoured number over the disc's own menu on the default path.
   Note `O[2]`'s `hud_dbg` already shows reader PGCN/VTS for the diagnostic case.

Arbitration is root-cause ordered — an unplayable image outranks the audio notice,
both sit below `css_warn`, and user events (audio/sub/angle/chapter) still take the slot
for their 2.5 s before any warning re-arms.

Tests: `transport_hud_tb` T14–T16 (text, menu-exemption, image-outranks-audio,
one-shot expiry) — T16 caught a real bug, a `G_NONE` fall-through rendering `~` instead
of a space between "TITLE VTS" and the digits. `hud_frame_tb` (incl. the field-order
interlace-safety proof), `seek_bar_tb` and `bcd_time_add_tb` all still green.

**★ HW ROUND 1 (2026-08-23) — PASSED with two fixes.** Confirmed on hardware:
normal discs show no popup (the false-positive gate, the main risk — CLEAR);
`BADIMAGE.iso` correctly raises `UNSUPPORTED IMAGE`; `TITLE VTS nn` works with menus
Off and correctly stays silent with menus On (**the re-scope is user-accepted — keep
it**); warnings re-appear after a user audio/subtitle popup. Two defects found:

1. **`UNSUPPORTED IMAGE` latched at core load with no image selected.** The watchdog
   armed from reset, and an idle core at the file browser satisfies "flat-file path AND
   no video" trivially — so the failure message became a boot screen. Fix: a sticky
   `media_seen`, set by the first `start_streaming`, gates the counter.
2. **On a CSS-scrambled disc the audio notice appeared first, then CSS.** These levels
   do not assert together: `aud_warn` arms at `nav_ready` (IFO parsed) while
   `css_scrambled` needs 4 scrambled PES, i.e. a moment of real stream — so the
   narrower notice won the slot and held it for its full 2.5 s before the root cause
   could speak. Two-part fix: `aud_unsupported` is now gated on `~css_scrambled` (CSS
   already mutes audio, so a format notice is redundant AND misleading about the
   cause), and `transport_hud` gained **warning preemption** — a higher-priority
   warning takes the slot from a lower-priority one mid-show instead of waiting for it
   to expire. Preemption is scoped to warnings: user events (types 0-3) are never
   preempted, so the "user popup wins" contract is unchanged. Tests: `transport_hud_tb`
   T17a-e.

**★ HW ROUND 2 (2026-08-25) — `UNSUPPORTED IMAGE` false-positive on slow media.
✅ FIXED + HW-CONFIRMED 2026-08-25 (user report).**
User report: an image served off a NAS whose drives spin up on first access raised
`UNSUPPORTED IMAGE`, and because the latch is sticky the popup then sat **over correct
playback** once the image finally loaded. Root cause: `IMG_WD` ran on **wall time from
the mount**, so the entire 5 s window could be spent before the first byte ever arrived —
"no video yet" was true, but for a reason that has nothing to do with the image. Fix
(`dvd/emu.sv`), three parts:

1. **Streaming time, not wall time.** A free-running activity detector (`img_idle_cnt`,
   re-armed by every `sd_buff_wr`, saturating at ~0.5 s) gates the window: any delivery
   stall — spin-up, a slow share, a re-seek — **freezes** the count instead of spending
   it. The watchdog now measures what it always meant: *streamed this long without a
   picture*.
2. **Window widened 5 s → ~20 s** of that active streaming. An unplayable image is not
   urgent to report; a wrong report is expensive.
3. **The latch self-retracts on `video_live`.** The message asserts "this image never
   produces a picture", so a decoded frame disproves it by construction — it must not
   outlive that. Belt-and-braces: even if some future timing surprise trips the window,
   the popup cannot survive over working playback, which was the actual user-visible
   harm.

Coverage is unchanged for a genuinely unplayable file that streams (it still latches,
just later). A junk file that delivers *nothing at all* now stays silent rather than
being reported — a deliberate trade, since "nothing arrived" is a media/transport
problem, not an image-format one.

**Side finding: `SCENEIT_JR.iso` is a RAW (CSS-scrambled) rip** — 27.6 % of packs,
found because it was picked as the MP2-flag test vehicle and the core's own CSS
detector fired on it. That makes it the second known dirty rip after FAIRYTOPIA;
it needs a re-rip, and it is a reminder that `tools/css_scan.py` pre-flight is
mandatory for every arrival (docs/disc_sweep.md).

### Phase 3 — README + licensing ✅ (PR fj#181)

**Licence RESOLVED (2026-08-23).** The investigation found no grant text anywhere in the
tree — `rtl/` headers carry only the BSD *warranty disclaimer*, and no upstream
distribution in the chain (`mpeg2fpga` itself, its preservation mirror, or
`mrchrisster/MiSTer_MPEG2`) ships a LICENSE file; GitHub's licence API returns Not Found
for both repos. The answer was not in any repo: **the author's own OpenCores project page
for `mpeg2fpga` states "License: BSD"**, which is the authoritative statement.

The combined work therefore resolves as follows, and this is derived rather than chosen:
`sys/` is a MIX of "GPL v2 or later" (alsa, arcade_video, iir_filter, ltc2308, spdif,
sys_top, video_freezer, yc_out) and "GPL v3 or later" (ddr_svc, hps_io, scandoubler,
sd_card) — the or-later files can go up to v3 but the v3 files cannot come down to v2,
so the whole is **GPLv3-or-later**. BSD is GPL-compatible, so `rtl/` folds in while
remaining BSD in its own right (copyright headers retained). `rtl/LICENSE-MPEG2` is a
**patent** notice and is independent of all of this. The AC-3 decoder is clean of
liba52's GPL — liba52 is a co-sim *oracle*, never source material.

Shipped: verbatim `LICENSE` (GPL-3.0) + `NOTICE` recording the per-component breakdown
and the OpenCores provenance, so the reasoning survives the next time someone asks.

Everything else shipped:Everything else shipped:

Project-only (no author attribution, user decision 2026-08-23). LICENSE reconciling
BSD-style `rtl/` (Koen De Vleeschauwer) with GPL `sys/`; current architecture and honest
status; rip instructions with `tools/css_scan.py` as pre-flight; a settings reference
covering every OSD option — including the `Analog Out` mode table below and a prominent
**Frame Drop must stay On** warning; `MiSTer.ini` lines for analog/CRT output.

**`Analog Out` — why all four modes stay (2026-08-23 review).** `Native Fields` and
`Interlaced` are NOT redundant. Both force the analog raster on, but `Native Fields`
also forces `il_eff`, which makes the MAIN raster interlaced ⇒ HDMI drops to 480i via
ascal for the session, and ascal is not cadence-aware ⇒ **film regresses on HDMI**.
`Interlaced` keeps HDMI progressive. It also remains the only override for a 15 kHz
RGBHV rig that the ini bits cannot identify, and unlike Native Fields it can be changed
mid-title (Native Fields fires the `il_switch` flush).

| Setup | Mode |
|---|---|
| CRT only, video-sourced (TV, concerts) | **Native Fields** |
| CRT only, film | Native Fields or Auto — little difference (each field lies wholly in one picture) |
| CRT **and** HDMI simultaneously | **Auto / Interlaced** — Native Fields costs HDMI |
| 15 kHz RGBHV rig the ini can't identify | **Interlaced** |

**OSD overrides always beat the ini, and they persist.** `analog_eff` takes the ini
(`analog_want`) only under `analog_mode == 2'd0` (Auto); `Progressive` (mode 2) matches
none of the OR terms so it is unconditionally off. `emu.sv` never drives
`status_set`/`status_in`, so nothing in fabric clobbers a restored selection — picking
`Progressive` with `composite_sync=1` still in MiSTer.ini survives every reload.

### Phase 4 — release engineering ✅ (PR fj#182)

**Version identification.** The OSD version line was hardcoded `"V,v1.0;"` — meaningless,
and it identified nothing. The standard MiSTer mechanism was already wired but UNUSED:
`sys/build_id.tcl` runs as a `PRE_FLOW_SCRIPT_FILE` (DVD.qsf:283) and regenerates
`build_id.v` with `` `define BUILD_DATE "yymmdd" `` on every compile. Now included, and
the line reads `` "V,v",`CORE_VERSION," ",`BUILD_DATE `` → **`v0.1a 260823`** in the OSD.
This is the only way a bug report can identify which build the reporter is running, which
matters a great deal more once the core is public.

**Release naming.** `--release` already existed as a hard timing gate; it now also selects
MiSTer release naming, packing `releases/DVD_YYYYMMDD.rbf` — the convention every other
core and the MiSTer update scripts use — and ignoring `--name`. Feature builds keep the
`<name>_<date>_<time>` form so parallel experiments stay distinguishable on an SD card.
A release is the ONE artifact a user installs and cites, so it gets the plain name.

Also fixed: `build_release.sh` comments quoted the clk_dec gate as **81 MHz** long after
`tools/fmax_check.sh` raised it to **86.0** (2026-08-01, `feature/fringe-sdc-clock-groups`).
The gate itself was always correct — only the prose was stale. The comment now points at
`fmax_check.sh` as the authority instead of restating a number that goes stale.

**Repo note (checked, no action taken).** Tracked tree is 14 MB but `.git` is 648 MB:
history carries `bench/iverilog/sim.log` (99/97/54 MB), a 48 MB `vid.mpg`, and Quartus
`db/` artifacts, all introduced by the very first commit ("Fresh start: MPEG2 core without
large testbench files") and long gone from the tree. **Deliberately NOT rewritten:** the
`docs/` tree cross-references commit SHAs extensively, and any history rewrite invalidates
every one of them — the trail is worth more than the clone size. Note the largest blob is
99 MB, just under GitHub's 100 MB hard limit, so a push will warn but succeed.

**Remaining: the final soak** (film + TV + one game disc on shipping defaults), then tag.

## Test Media Recommendations

> **✅ HW-CONFIRMED 2026-08-18 (PR fj#165): authored cell duration ("real-player cell
> timing").** Weakest Link questions hold for the authored time; no menu-disc regressions.
> Design + status: `docs/dvd_nav.md` "authored cell duration". (WL questions not random =
> separate open issue, Cluster B in `docs/disc_sweep.md`.)
>
> **🔧 2026-08-25, ⏳ HW-confirm pending — the C_PBTM FRAME FIELD (branch
> `fix/cell-duration-frames`).** The duration above was read as hh:mm:ss only, dropping
> the frame field: WL's answer-reveal and money-banked screens are `1 s + 24 f` = 1.96 s
> single-I-frame cells, stored as 1 s, which fell under `RESID_MIN` and so got no hold at
> all — they flashed by in ~0.2 s. The stored duration now rounds the frames in. See
> `docs/disc_sweep.md` "Round-7" + `docs/dvd_nav.md` "Amendment (2026-08-25)".
>
> **★ NEW TRACK (2026-08-18): SPEC HARDENING — design to the DVD spec maximum, phased
> plan in `docs/spec_hardening.md`.** The PGCN and cell-duration bugs were both
> "designed to the test shelf, not the spec". Phase 1 (next session) =
> `tools/spec_audit.py`, a rip-time library audit against the core's implemented limits;
> Phases 2–6 = SPU cap to 53,220 B, HLI button groups by display mode, PGCI_UT language
> units, `ptt_mem`, evidence-gated leftovers.
>
> **★ WHAT'S NEXT (2026-07-31, refreshed 2026-08-17): run the disc sweep — see
> `docs/disc_sweep.md`.** The library is now **ripper-fed and growing** (bulk stored
> off-machine); **12+ discs have never been played on hardware** (the original 8 + carded new
> arrivals incl. Clue and two Ghibli parental/multi-angle vehicles). The prework is done
> (per-disc predicted boot/menu/POST destinations, libdvdnav golden-trace agreement 11/12,
> capacity audit, `tools/css_scan.py` rip pre-flight, watch lists) — what remains is the
> breadth-first HW pass on `DVD_cssdetect_20260806_1419.rbf`+, then batched fixes. The
> binding constraint is HW test time, not disc availability; only LPCM 24-bit/96 kHz and
> UDF-only images still lack a vehicle (`docs/test_disc_shopping_list.md`). ⚠ FAIRYTOPIA's
> current rip is raw (CSS) — re-rip before its card.

| Phase | Test content | Why |
|-------|-------------|-----|
| 0 | Any `.mpg` file (MPEG-2 video, no audio) | Baseline |
| 1 | VOB file hex dump (any DVD) | Demuxer unit test |
| 2 | DVD rip with LPCM audio | LPCM is simplest codec |
| 3 | Standard DVD, AC-3 2.0 audio | Most common codec |
| 4 | Any commercial CSS DVD as ISO | Full navigation test |
| 5 | Concert DVD, DTS primary audio | DTS codec test |
| 7–8 | DVD with chapters / long feature | Nav timeline, seek, chapter skip |
| 9 | Multi-angle disc (e.g. some concert/music DVDs) | Angle switching |
| 10 | Disc with multiple audio + subtitle tracks | Track/subtitle selection |
| 11 | Any disc | Transport UI (custom graphic OSD) / menus |

For simulation testbenches, extract VOB bytes with:
```bash
dd if=VIDEO_TS/VTS_01_1.VOB bs=2048 count=50 | xxd > bench/dvd/test_vobs/sample.hex
```

---

## Git Workflow

```bash
# Start a new feature
git checkout -b feature/ps-demuxer

# Keep up with upstream fixes
git fetch upstream
git rebase upstream/main  # or merge, depending on divergence

# Before every PR / milestone
quartus_sh --flow compile dvd_player  # full build
# Run all simulation testbenches
# Test on hardware
```

### ✅✅ ROOT CAUSE PROVEN & FIXED — f2sdram read path couldn't sustain 108 MHz

The standalone DRAM self-test (O3) settled the entire black-screen saga. At the core's
**108 MHz** `clk_mem` f2sdram clock: all 512 writes accepted, reads accepted, but
**`readdatavalid` never returns** (`0200/0001/0000/9000`). Re-clocked to **27 MHz** (same
`sys_pll` domain): **all 512 writes + reads + returns, 0 mismatches** (`0200/0200/0200/8000`).
So the HPS f2sdram read-return path on the DDRAM/ram1 port simply cannot sustain 108 MHz —
writes tolerated it (why it always looked like "writes work, reads hang"), reads silently never
completed, starving the decoder every time. (`clk_100m` = `HPS_BUS[43]` is a valid 100 MHz clock
but a different domain that wedged ram1 bring-up, so the real fix stays in the `sys_pll` domain.)

**Fix:** lower `clk_mem` 108 → **54 MHz** in `dvd/sys_pll.sv` (copy of `rtl/sys_pll.sv`,
`output_clock_frequency1` → 54; qsf retargeted; `rtl/` untouched). 54 = 2× the proven-good 27,
half the failing 108 — safe headroom, ~432 MB/s, ample for SD. Video runs on `clk_sys` = 27 so
it's unaffected; everything wired to `clk_mem` (mem_shim, decoder `mem_clk`, `DDRAM_CLK`, BIST)
follows automatically. Build `DVD_clk54`. **Verify:** O3 on → BIST rows 12-15 should read
`0200/0200/0200/8000` at 54; then O3 off → **decoder should finally produce video.** If the BIST
fails at 54, drop `clk_mem` further (27 is proven). The serializer + read retry/timeout in
`mem_shim` stay in as belt-and-suspenders but should no longer be needed.

### ✅ HISTORICAL / RETIRED — port memory to the SDRAM add-on board (superseded)

> **⚠️ STALE "NEXT PHASE" header, kept for the record.** This plan is **retired**. The SDRAM
> add-on route was pursued (`dvd/sdram.sv`) and then RETIRED: the core's memory now runs
> entirely on the HPS f2sdram DDRAM burst bridge (`dvd/mem_shim_burst.sv`), and the SDRAM
> controller + its pins were removed 2026-07-01 (`feature/remove-diagnostic-cruft`). Video has
> decoded correctly on HW for many iterations since. This is NOT the next phase — see CLAUDE.md
> and the interactive-DVD phases (7–11) for real remaining work. History: `docs/history.md`.

**(historical) Result of the clk fix:** at `clk_mem`=27 the f2sdram BIST passed but the decoder
still showed no picture, which motivated moving memory to the 128 MB SDRAM add-on board. That
was later reversed once the burst bridge was made to sustain traffic; the add-on path is gone.


## Known framework interaction: DVD ISOs on CIFS/NAS mounts do not load — ✅ ROOT-CAUSED + FIXED (2026-07-08)

**Symptom:** selecting a DVD `.iso` from a CIFS-mounted share = black screen, core idle;
the SAME file from the SD card plays.

**✅ ROOT CAUSE (proven on HW by `strace` of the MiSTer main process, 2026-07-08):** the
framework opens SD-image (`S`-slot) mounts **read-write** and the CIFS server rejected it:

```
openat(AT_FDCWD, ".../MEN_IN_BLACK.iso", O_RDWR|O_SYNC|O_LARGEFILE|O_CLOEXEC) = -1 EACCES
```

`O_LARGEFILE` is present, so it was **never a size / >2 GB / >4 GB problem** — that whole
correlation was a red herring. The mount path picks the open mode from the file's mode bits:

```c
// Main_MiSTer user_io.cpp (user_io_file_mount)
writable = FileCanWrite(name);                                  // file_io.cpp: (st.st_mode & S_IWUSR)
ret = FileOpenEx(&sd_image[index], name, writable ? (O_RDWR | O_SYNC) : O_RDONLY);
```

On CIFS `st_mode` is synthesized from the mount's `file_mode` option (**default `0755` → owner
-write bit set**), so `FileCanWrite()` returns true, main opens the ISO `O_RDWR|O_SYNC`, and a
read-only share / no-write creds returns `EACCES`. The mount fails; the core never receives the
image. Our core never writes (`sd_wr` tied to `1'b0` in `emu.sv`), so the write probe is pure
collateral damage. This is also why ao486 `.vhd` "works over NAS" — those shares are writable.

**✅ FIX (user-confirmed working 2026-07-08):** give the MiSTer's SMB user **read-write access**
to the share so the `O_RDWR` open succeeds. ISOs now load + play over the NAS.

**Alternative fix (no server change):** force the mount to report files read-only so main opens
`O_RDONLY` — add `file_mode=0444,dir_mode=0555` to the CIFS mount options. Note: the `ro` mount
flag ALONE does *not* work — it doesn't change `st_mode`, so `FileCanWrite()` still returns true
and main still attempts `O_RDWR` (now failing `EROFS`). You must drop the owner-write MODE bit.
Downside: makes the whole share read-only to MiSTer, breaking cores that write saves to it
(ao486 vhd, etc.) — so prefer the writable-user fix or a dedicated read-only share for ISOs.

**Diagnostic tooling:** a static ARM `strace` (v4.10, `andrew-d/static-binaries`) run against
`pidof MiSTer` is what nailed this — attach, reproduce the selection, grep for the `openat` on
the `.iso` and its errno. Keep that trick for any future "core won't load a file" mystery: the
framework's file syscalls (open mode + errno) are the ground truth the RTL side can't see.

## ✅ DONE: numeric button entry via keyboard (easter eggs / direct chapter select) — ✅ HW-CONFIRMED (PR fj#134)

**Shipped + HW-CONFIRMED (2026-07-27, PR fj#134). Confirmed on HW by unlocking the T2
`82997` menu easter egg via the keyboard numpad** — which also proves the multi-digit
egg-code chain end-to-end (each digit = one hidden auto-action button activated through
the Phase-4 VM's GPRM arithmetic). DVD remotes' digit keys
perform "select button #N"; discs build multi-digit easter-egg codes (T2 82997, RotS 1138,
Over The Hedge 695) as chains of HIDDEN auto_action buttons whose commands do GPRM
arithmetic (they need the Phase-4 VM, which we have). Implementation: `hps_io.ps2_key`
is now wired into `emu.sv`; a scancode→digit decoder (numpad **and** top-row, 0→button 10)
pulses `nav_pci`'s new `num_sel`/`num_btn` port whenever a menu HLI is armed. nav_pci forces
`btn_sel` then activates from `F_DONE` (`auto_pend`) so the fired command is the freshly-
fetched one, and `dvd_vm.sprm8_eff` already shadows the typed button. Chosen behaviour:
**select+activate on each digit** (one keypress runs a chapter button / one egg-code digit).
Tests: `nav_pci_tb` T10. Full design: **`docs/dvd_nav.md`** "Numpad input". ✅ HW: T2 `82997`
egg unlocked via the numpad (needs a USB keyboard on the MiSTer — a gamepad has no numpad).
A true multi-digit *entry* field (accumulator + timeout) is deferred — no known disc needs it.

## Follow-up idea: interactive DVD games — Optreve engine (Scene It?, etc.)

**Feasibility: HIGH — these games are pure DVD-VM, and `dvd/dvd_vm.sv` already implements
nearly all of it.** Decoded from `Scene_It.iso` (2026-07-08). The "Optreve" game engine is
implemented entirely in DVD nav commands + GPRMs — no special format:

- **Shuffle** = the VM `rnd` command (our LFSR16, bit-exact with `tools/dvd_vm_ref.py`).
  VTS_03 is a chain of dispatcher PGCs: `g[15] rnd 0xE6; if (g[15] < 5) Goto 1 (redraw);
  LinkPGCN 2` etc. (12 `rnd` sites).
- **De-duplication / "clips seen"** = GPRM state, **session-only** (a DVD is read-only —
  there is NO cross-session persistence and no stored seed). `g[15]` = last clip index,
  and `if (g[2] == g[15]) Goto 1` rejects an immediate repeat; `g[14]` counts a round of 5
  clips (`g[14] += 1; if (g[14] > 5) LinkPGCN 13` → menu).
- **Entropy seed** = a **counter-mode GPRM** (`SetMode Counter g[13] = 1`) — a free-running
  ~1 Hz real-time counter folded into the draws (`g[1] += g[13]`, `g[4] += g[13]`, …). This
  is the wall-clock entropy that makes each session's order differ.
- **"Player reset the Optreve system, you may see repeats"** = a GPRM-persistence self-test.
  The warning is the last still cells of `VIDEO_TS.VOB` (VMGM PGCN 6/7, RBN 48703–48743,
  PGCN 6 `still=17` = a 17-unit timed still). VMGM PGCN 1 gates it: `if (g[2] == 0) LinkPGCN 6`
  — i.e. *if my GPRMs are still zero, the player reset me* → show the warning. VLC/libdvdnav
  trips this by resetting GPRMs mid-session where hardware wouldn't.

**Why we fit well:** our VM keeps GPRMs on the `reset_n` domain (they survive jumps/seeks),
so within a session state persists like real hardware — warning only on a genuine cold boot,
no spurious mid-session reset (the exact VLC bug). We already implement `rnd`, GPRM
arithmetic/compares, `Goto`, `LinkPGCN`, `CallSS`/`RSM`, `JumpVTS_TT`, and title-domain
PGC pre/post execution.

**Gaps / tasks (do after the menu-transition round lands; keep off that PR):**
1. **GPRM counter-mode tick** — currently punted (`gprm_mode` stores the bit but the counter
   never increments). Add a ~1 Hz auto-increment for counter-mode GPRMs so `g[13]` provides
   real entropy. Without it the game still *functions* but the shuffle is more repeatable
   (and deterministic across cold boots, since our LFSR resets to a fixed seed). Bounded add
   to `dvd/dvd_vm.sv`.
2. **Scene-It boot test** — verify FP `JumpTT 28` → VTS_03 dispatcher chain runs (rnd →
   dedup `g[2]==g[15]` → round counter `g[14]` → `CallSS VTSM/VMGM` menu → resume). A great
   VM validation disc: if the shuffle-and-dedup chain runs correctly, the VM is solid.
3. **Nav timer (SPRM9/NVTMR)** — stubbed (stored, never fires). Not used by Scene It's clip
   logic (timed answers appear baked into the clip video), but a general fix for any game
   that auto-advances on a timeout. Lower priority; revisit if a disc needs it.
4. **Scale** — 8.4 GB dual-layer ISO; the reader's 32-bit LBA handles it, and it fits on SD
   (NAS/CIFS large-file open is a separate known framework issue, above).
