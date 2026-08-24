# VCD/SVCD — CDi_MiSTer reference eval + how to share the MPEG decoder

**Status:** research / idea capture (2026-07-09). Not scheduled. Companion to the
"VCD / SVCD playback" section in [`experiments.md`](experiments.md) — that section already
covers the *three pieces of work* (MPEG-1 video quirks, MP2 audio, `ps_demux` `0xC0`/MPEG-1-PES).
This file captures two things that came out of a session studying the
[`MiSTer-devel/CDi_MiSTer`](https://github.com/MiSTer-devel/CDi_MiSTer) core:

1. **Can we lift CDi's MPEG-1 video / MP2 audio decoders as reference?** (what that core
   actually is, and what's reusable)
2. **If we build VCD/SVCD, how do we organize the code vs the DVD core?** — the key decision:
   **share the decoder behind a compile-time flag, don't fork it.**

---

## 1. The CDi_MiSTer MPEG decoder — what it actually is

Directory `rtl/mpeg/` in that repo. **License: GPLv3** (copyleft-compatible with this project,
which descends from `MiSTer_MPEG2`; any reuse must stay GPLv3 + carry attribution).

It is **NOT a clean pure-HDL decoder you can lift one file at a time.** It's a
**soft-CPU + firmware + HDL-accelerator hybrid**:

- `rtl/mpeg/VexiiRiscv.v` — a **RISC-V soft core**.
- **`fmv/` (full-motion video):** HDL accelerators (`dct_coeff_huffman_decoder.sv`,
  `macroblock_worker.sv`, `mpeg_video_start_code_decoder.sv`, DDR luma/chroma line buffers)
  **driven by C firmware** (`decoder_firmware_memory.sv` + `worker_firmware_memory.sv` +
  `firmware.mem`/`firmware2.mem`).
- **`fma/` (full-motion audio = MPEG-1 Layer II / MUSICAM):** `mpeg_audio.sv` (~380 lines) that
  instantiates **`VexiiRiscv` + 28 KB firmware RAM** to do the *bitstream* decode (bit
  allocation, scalefactors, dequant) **in software**, plus an HDL **single time-multiplexed
  MAC** for the synthesis filterbank:
  - the multiply is literally one serialized `mac_vector_accu <= mac_vector_accu +
    temp1 * temp2;` (1 DSP, not a parallel MAC array) — the DSP-frugal design we'd want.
  - window ROM `synth_window.svh` = **512 × 18-bit signed = 1.1 KB** (case statement).
  - buffers: 8 KB input FIFO, 28 KB firmware RAM, L/R output FIFOs.

**So the actual Layer-II decode is firmware on a soft CPU, with hardware only for the
filterbank math.** To reuse `fma/` *directly* you'd import the RISC-V core + a C→`.mem`
firmware toolchain — ~2K ALMs + ~30 M10K + a firmware build dependency. **That's against this
project's pure-HDL grain** (every codec here — `ps_demux`, all of `dvd/ac3/*` — is an HDL FSM,
no soft CPU). **Recommendation: do NOT import the RISC-V.** Use `fma/synth_window.svh` + the
serial-MAC pattern as a *reference spec* for a from-scratch HDL MP2 decoder instead.

### The proprietary-ROM caveat is not about the codec
CDi's `vmpega.rom` / `boot2.rom` ("source separately, legal reasons") is the **CD-i cartridge's
host firmware** (needed to emulate the cartridge's 68070-side interface), *not* the codec. The
codec firmware is the `fmv/`/`fma/` `.mem` files, custom-authored for the core (GPLv3). So the
codec itself is reference-able without the proprietary ROM.

### Real-hardware footnote (answers "was CD-i audio software-decoded?")
Yes. The real VMPEG Digital Video Cartridge decoded **MPEG audio in firmware on a Motorola
DSP56002**, paired with a dedicated **MCD251 MPEG-1 video decoder** chip — neither on the CD-i's
main SCC68070 CPU (too slow, same logic as our HPS-vs-fabric split). So MP2 audio decode has
*always* been a light software task on a small processor; only the filterbank wants DSP assist.
CDi_MiSTer's "RISC-V + firmware + HDL MAC" faithfully mirrors that. Sources:
[The World of CD-i — DVC](https://www.theworldofcdi.com/cd-i_encyclopedia/digital-video-cartridge/),
[cdifan/cdichips](https://github.com/cdifan/cdichips).

**Reference-value ranking:**
- **`fma/` (MP2 audio) — highest.** It's the one codec we genuinely lack; use as a spec.
- **`fmv/` (MPEG-1 video) — low.** We already have a HW-proven MPEG-2 decoder; SVCD runs on it
  as-is and VCD's MPEG-1 is a small conditional delta (see `experiments.md`). Extending our own
  decoder beats importing a second, firmware-driven one.

---

## 2. Where MP2 can live — and the fabric-fit reality

Latest DVD fit (2026-07-09, full menu/VM/subpicture/AC-3 stack):
**ALMs 35,894/41,910 = 86 %; DSP 97/112 = 87 % (15 free); RAM 408/553 = 74 %; block-mem 52 %.**

MP2 is the *whole* new cost — video adds ~nothing (SVCD = MPEG-2 already; VCD MPEG-1 = tiny
conditional delta). It **shares almost nothing with AC-3**: `dvd/ac3` is a 512-point **IMDCT**;
MP2 is a **32-band polyphase synthesis filterbank** — different algorithms. Only the *periphery*
is reusable (`bit_reader`/`bit_fifo`, `pcm_out`, the FSM idiom); both decoders need their own
transform core. So there is **no big "free ride" on the AC-3 engine.**

Pure-HDL MP2 estimate (written in our style, serialized): **~2–3.5K ALMs, 1–2 DSP, ~6–10 M10K.**
- DSP: fine (need 1–2, 15 free). RAM: fine (need ~8, 145 free).
- **ALMs are the binding risk:** ~2–3.5K against ~6K free lands the DVD core at **~91–94 %**,
  in the zone where this codebase goes flaky (chroma-fringe `clk_dec` Fmax gate, seed-dependent
  routing, timing marginality). Every added % ALM worsens the fringe and threatens the
  *already-working* DVD datapath.

**Options considered:**

| Option | Fabric cost | Main cost / risk |
|---|---|---|
| Fabric MP2, pure-HDL | ~2–3.5K ALMs, 1–2 DSP → ~91–94 % | Timing-margin risk to the working DVD path |
| Fabric MP2, import CDi RISC-V | ~2K ALMs + ~30 M10K + firmware toolchain | Against pure-HDL grain; GPLv3 firmware dep |
| **HPS-decode MP2** | **~zero fabric** | **VETOED by design principle** (see below) |
| Separate VCD/SVCD `.rbf` | n/a (own device image) | A second build target to maintain (but far simpler) |

### Design principle (hard constraint): one self-contained `.rbf`, no HPS daemon
The project's identity is "a DVD player that is *just an `.rbf`*." **No Linux-side daemon.** So
HPS-decoding MP2 — although trivially cheap and historically how CD-i itself did it — is **off
the table** by user decision (2026-07-09). (Corollary the user noted: if a daemon were ever
allowed, you'd HPS the AC-3 too and the whole fabric-fit problem evaporates — which is exactly
why the no-daemon line is worth holding.) **MP2 must live in fabric.**

---

## 3. ★ The key idea: share the decoder behind a compile-time flag — don't fork

VCD needs MPEG-1 video logic the DVD core never runs, so the tempting move is to **fork** the
decoder into a separate VCD repo. **That's the wrong call, for one decisive reason:**

> **This project's decoder is under constant, heavy development** — motcomp ref-prefetch, the
> frame-drop governor, film 3:2 cadence, `flags_commit`, the whole lip-sync saga, PAL/CRT paths.
> A hard fork means **every one of those fixes has to be hand-ported across two diverging copies
> of a 1000+-line decoder.** They'd drift fast. A fork is only safe when the shared thing is
> stable; ours isn't.

**Instead: one repo, shared RTL, MPEG-1 support behind a compile-time flag, split at the
Quartus *revision* level (not the repo level).**

- MPEG-1 quirks (relax the `sequence_extension_seen` gates in `rtl/mpeg2/vld.v`; supply MPEG-1
  "extension" defaults — progressive, 4:2:0, FRAME structure, frame pred/DCT,
  `intra_vlc_format=0`, zigzag; route motion from the picture-header f_codes with `full_pel` ×2;
  see `experiments.md` for the exact gates/lines) go into the **same** decoder source, guarded by
  `` `ifdef MPEG1 `` / a top-level generate parameter.
- **DVD revision:** flag **off** → MPEG-1 code not synthesized. Decoder bit-identical to today.
  **Zero ALMs, zero `clk_dec`-fringe risk.** Keeps AC-3 + the full DVD nav/IFO/VM/menu stack.
- **VCD revision:** flag **on** → MPEG-1 included; swaps the audio front-end to **MP2** and
  **omits** AC-3 + the entire DVD nav/menu/VM/IFO/CSS stack. That `.rbf` has ample headroom
  precisely because it drops everything DVD-specific.
- **Shared wins for free:** memory system, video output (PAL/CRT/scaling), the governor,
  `av_sync`, `ps_demux` — improvements land in **both** revisions automatically.

Quartus natively supports **multiple revisions in one `.qpf`** (each with its own `.qsf`
file-set + params) — this is the standard way to have two build targets over shared source,
not exotic.

**Why the compile flag dissolves the tension:** you don't have to choose between "keep DVD
clean" and "keep them in sync." The guard gets **both** — single source of truth (sync), DVD
synthesizes none of it (clean). "DVD doesn't need the MPEG-1 logic" is true at *runtime* and is
honored exactly, without paying the fork's maintenance tax.

### The upside worth keeping in view
If a **standalone synth of the MP2 block measures cheap** (say < 2K ALMs, ≤ 4 DSP incremental —
the number we can't pin without building it), then a **single combined `.rbf` that plays DVD
*and* VCD/SVCD** becomes viable — one core, everything, still no daemon, fully consistent with
the one-`.rbf` principle. **The two-revision split is the safe fallback** if MP2 is too heavy to
co-exist with AC-3 on the tight DVD fabric.

**Go/no-go for single-core = one measurement:** synthesize a standalone serial MP2 decoder and
read its true ALM/DSP/RAM cost. Under ~90 % combined total → fold into one core; over → ship the
VCD revision separately. Gate either build behind the existing per-build `clk_dec` Fmax check
(`fmax_check.sh`) so any timing regression on the DVD path is caught immediately.

---

## TL;DR

- CDi's MPEG decoders are a **RISC-V + firmware + HDL-MAC hybrid** (GPLv3). **Don't import the
  RISC-V**; use `fma/synth_window.svh` + its serial-MAC as a **reference** for a from-scratch
  HDL MP2 decoder. `fmv/` MPEG-1 video is low-value — extend our own decoder instead.
- **MP2 is the whole new fabric cost** (~2–3.5K ALMs), it **doesn't share AC-3's transform**,
  and it eats most of the DVD core's remaining headroom → timing-margin risk.
- **Share the decoder, gate MPEG-1 behind `` `ifdef MPEG1 ``, split at the Quartus revision
  level. Never hard-fork a decoder you're still actively tuning.**
- **One measurement decides single-core vs separate `.rbf`:** standalone MP2 synth cost.
