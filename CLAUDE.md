# MiSTer DVD Player Core — Claude Code Context

## Project Overview

This project is a **DVD player core for the MiSTer FPGA platform (DE10-Nano / Cyclone V)**,
built as a fork of [`mrchrisster/MiSTer_MPEG2`](https://github.com/mrchrisster/MiSTer_MPEG2).

The goal is to extend the existing working MPEG-2 video decoder into a full DVD player,
adding Program Stream demuxing, UDF/IFO navigation, AC-3 and DTS audio passthrough/decode,
and CSS decryption — all while keeping the proven FPGA video pipeline intact.

See `docs/` for detailed reference on architecture, audio, and implementation roadmap.

---

## Documentation Discipline (read before starting work)

Every non-trivial design decision **must** be written down — either in this `CLAUDE.md`
or in the `docs/` folder. Code without recorded rationale is treated as incomplete.

- **Where to put it:**
  - `CLAUDE.md` — durable, project-wide rules, conventions, and high-level decisions an
    agent needs *before* touching code (architecture choices, toolchain pins, workflow).
  - `docs/architecture.md`, `docs/audio.md`, `docs/roadmap.md`, `docs/references.md` —
    detailed, subject-specific design notes, data flows, FSM descriptions, and rationale.
  - Per-module status (e.g. the `ps_demux.sv` "Status & design decisions" block below) —
    a short summary lives in `CLAUDE.md`, full detail goes in `docs/architecture.md`.

- **When to write it:** at the same time as the code, not "later." Commit docs together
  with the change that motivated them.

- **What to record:** the *why* behind each decision, known limitations / TODOs, design
  alternatives that were rejected (and why), and anything that surprised you or wasn't
  obvious from reading the code.

### Leave a trail to resume work in a new session

Sessions are stateless — after a feature branch merges, the next session starts cold and
has only the committed markdown to go on. Before finishing any feature, ensure the docs
leave enough hints to pick up cleanly:

- Update the relevant **status block** (what's implemented, what's wired in, what isn't)
  and the ✅/❌ checklists in "What Already Works" / "Known Gaps".
- Record the **next concrete step** so the following session knows where to start
  (e.g. "Not yet wired into `emu.sv`" tells you the wiring is the next task).
- List **known limitations** explicitly (e.g. `length == 0` PES not handled) so they
  aren't rediscovered the hard way.
- Cross-reference: point from `CLAUDE.md` summaries to the detailed `docs/` section, and
  name the relevant files/modules/testbenches so they're easy to locate.
- Keep `docs/roadmap.md` current — it's the canonical "what's next" across sessions.

### ★ Update status markers when a feature completes (mandatory — a stale marker is a bug)

The docs went stale once (2026-07-09 reconciliation, PR after fj#93) because status wording
was written at branch-creation time and never updated when the PR merged — so a whole batch
of shipped, HW-confirmed menu work (PR fj#84–fj#90) still read "sim-verified, HW gate pending"
and misdirected a "what's next?" session. To prevent recurrence:

- **When you complete or merge a feature, update its status markers in the SAME change** —
  both `docs/roadmap.md` and any per-feature status header in `docs/` (e.g. section headers
  in `docs/dvd_menu_refinements.md`, `docs/dvd_nav.md`, `docs/dvd_vm.md`).
- Flip the marker to reality: `🔧`/`❌`/`[ ]`/"sim-verified, HW gate pending" →
  `✅ MERGED (PR #NN)` and, once the board test passes, `✅ HW-CONFIRMED`. If merged but not
  yet hardware-tested, say exactly that (`⏳ HW-confirm pending`) — don't leave it reading "gate pending".
- **Retire dead branch names.** A merged feature must not still point at a live `feature/*`
  branch in prose — replace it with the PR number.
- Treat a lingering `🔧`/"HW gate pending"/`feature/*` reference on shipped work as a
  documentation bug: fix it on sight. When in doubt about true status, reconcile against
  `tea pr list --state closed` (what actually merged), not the branch name.

---

## Repository Structure

```
MiSTer_DVD/
├── CLAUDE.md                  ← you are here
├── docs/
│   ├── architecture.md        ← full system design & data flow
│   ├── audio.md               ← AC-3, DTS, LPCM audio strategy
│   ├── roadmap.md             ← phased implementation plan
│   └── references.md          ← key repos, specs, libraries
├── rtl/                       ← UPSTREAM: existing mpeg2fpga decoder (do not modify)
├── sys/                       ← UPSTREAM: MiSTer framework (do not modify)
├── dvd/                       ← YOUR NEW RTL MODULES go here
│   ├── ps_demux.sv            ← Program Stream demuxer (build this first)
│   ├── audio_ring.sv          ← Audio frame ring buffer to HPS
│   └── iec61937_wrap.sv       ← Future: IEC 61937 wrapper for S/PDIF
├── hps/                       ← YOUR HPS-SIDE C CODE goes here
│   ├── main.cpp               ← Main HPS program
│   ├── udf.c                  ← UDF filesystem parser
│   ├── ifo_parse.c            ← IFO/PGC DVD navigation
│   ├── audio_decode.c         ← liba52 (AC-3) + libdca (DTS) integration
│   └── alsa_out.c             ← ALSA write loop → HDMI audio
├── bench/
│   └── dvd/                   ← Simulation testbenches for new modules
│       ├── ps_demux_tb.sv
│       └── test_vobs/         ← Sample VOB hex extracts for sim
└── .vscode/
    └── settings.json
```

**rtl/ may now be modified directly (rule relaxed 2026-06-24, by user decision).**
The earlier "never modify `rtl/`" rule was dropped: chasing the 256-line strobe needs
debug ports and fixes threaded through deep upstream modules (`resample_addrgen`,
`resample`, `mpeg2video`, `mixer`, `syncgen`), and `dvd/` copies of 1700-line files are a
worse maintenance burden than targeted in-place edits. So:
- Editing `rtl/mpeg2/*` is allowed. Mark debug-only additions clearly (e.g. `// DVD-FORK
  DEBUG`) and functional fixes with `// DVD-FORK FIX`, and write down the rationale (docs).
- `sys/` still edited only when unavoidable (see the SDRAM exception below); prefer additive.
- The `dvd/mem_override/` include-shadow mechanism and existing `dvd/` copies (e.g.
  `dvd/resample_addrgen.v`, swapped in the `.qsf`) remain valid and are fine to keep using.
- Mergeability with upstream `mrchrisster/MiSTer_MPEG2` is no longer a hard constraint.

> **Historical note (SDRAM-module port, restore + removal):** `sys/sys_top.v` and `sys/sys.tcl`
> were once edited to *restore* the SDRAM routing so the fork could drive the 128 MB add-on board
> via `dvd/sdram.sv`. That path is now RETIRED — the core's memory runs entirely on the HPS
> f2sdram (DDRAM) burst bridge (`dvd/mem_shim_burst.sv`). As of 2026-07-01
> (branch `feature/remove-diagnostic-cruft`) the SDRAM controller, its self-test, and all
> `SDRAM_*` ports/pin assignments were removed from `dvd/emu.sv`, `sys/sys_top.v`, `sys/sys.tcl`,
> and `DVD.qsf`, taking `sys/` back toward stock. See `docs/history.md`.

---

## Toolchain

- **Quartus:** 17.0.2 exactly — newer versions break MiSTer project compatibility.
  Can be a native install **or** the pinned Docker image `raetro/quartus:mister`
  (Quartus 17.0.2 Build 602 Lite — the exact pinned version). Prefix any build command
  with `USE_DOCKER=1` and it re-execs inside that container (`tools/docker_reexec.sh`,
  wired into `build_release.sh` + `tools/seed_sweep.sh`): repo bind-mounted at its real
  host path, host UID/GID (artifacts stay host-owned), memory unbounded. E.g.
  `USE_DOCKER=1 ./build_release.sh --compile`. Override the image with
  `QUARTUS_DOCKER_IMAGE=...`. NOTE: fitter SEEDs are tied to the EXACT synth/map netlist
  produced by a given Quartus version — the Docker image is the same 17.0.2 Build 602 as
  the canonical native install, so seeds/fmax reproduce; a *different* Quartus version
  would require a seed re-sweep.
- **Device:** Intel Cyclone V (5CSEBA6U23I7) — the DE10-Nano FPGA
- **HDL:** SystemVerilog (`.sv`) for new modules; upstream uses a mix of Verilog + VHDL
- **Simulation:** Icarus Verilog (`iverilog -g2012`) for module-level testbenches
- **HPS compiler:** ARM cross-compiler for the Cortex-A9 (or native compile on MiSTer)
- **IDE:** VS Code with `mshr-h.verilog` and `TerosHDL` extensions

---

## Hardware status (THIS fork, verified 2026-06-21)

- 🔧 **AUDIO IS NOW DECODED IN FABRIC (2026-06-27, branch `feature/fabric-ac3-audio`).**
  AC-3 and LPCM are decoded entirely in the FPGA: `ps_demux` → `audio_ring` →
  `dvd/dvd_audio_decode.sv` (AC-3 via the ported `dvd/ac3/*` `ac3_front`+`pcm_out`,
  5.1→stereo downmix; LPCM via `dvd/lpcm_unpack.sv`) → `AUDIO_L/R` → framework I2S → HDMI.
  **No HPS daemon** — `hps/dvd_audio.c` and the DDR3 audio write chain
  (`audio_ddr_pack`/`cdc_req_ack`/`audio_ddr_issue`) are RETIRED (the `hps/` tree was
  deleted in the pre-release cleanup; `ddr_arb` audio master tied off). DTS is dropped for now (future:
  in-fabric IEC 61937 to the Digital I/O board). Toggle `O5 Audio` (default On). A/V sync
  still rides the **frame-rate governor** (`dvd/resample_addrgen.v`). Design in
  `docs/fabric_audio.md`; sim-verified (`bench/dvd/lpcm_unpack_tb.sv`,
  `bench/dvd/dvd_audio_decode_tb.sv`); **hardware confirmation pending.** Open follow-ups:
  HW confirm, LPCM 24-bit/96 kHz. DTS: no in-fabric decoder, but **IEC 61937 passthrough
  ✅ HW-CONFIRMED 2026-07-11 (PR fj#109)** — AC-3 + DTS both lock and play on a real
  receiver, A/V sync correct; see `docs/iec61937.md`. The earlier startup-lock / track-switch
  re-lock issue is **✅ FIXED + HW-CONFIRMED 2026-07-11 (PR fj#110)**: the receiver couldn't
  acquire across the Pc=0 non-PCM null bursts the producer emitted during A/V-sync holds, so
  the hold path now emits real **linear-PCM silence** (per-pair `nonpcm` flag → `spdif_pass`
  clears the non-PCM channel-status bit) — the receiver sees PCM then one clean PCM→DD/DTS
  switch, like a real player. Locks at startup + through track switching on all tracks.
  - **M19 AREA PASS (2026-07-11, branch `feature/ac3-area-reduction`).** The AC-3
    subtree had bloated to **9,378 ALMs — larger than the MPEG-2 video decoder
    (8,484)** — and the spdif branch FAILED to route at 91% ALMs. Cause: unconverted
    memory (the recurring LUT-RAM pattern): bit_allocation's `expc`/`dbc` register
    file + `baptab`/`latab`/`hthtab0` LUT ROMs (~3.0k ALMs), imdct_512's ~37 kbit of
    schedule/twiddle/window tables in LUTs (~3.3k ALMs), audblk_parse staging arrays.
    All converted to sync-read M10K (M19/M19b/M19c/M19d) + the downmix multipliers
    folded into the shared DSP bank (M19e, −6 DSPs). **Zero value changes** — gate at
    every stage = PCMDUMP byte-identical vs baseline + bit-exact bap cosim. Also
    fixed en route: `run_imdct/imdct256/drc` TBs had been silently FAILING since the
    M17 DRC fix (pre-M17 dynrng convention + vvp exit-0 masking; now `$fatal` on
    fail). Full detail: `docs/ac3_decoder_architecture.md` §4.11.
  - **AC-3 File Test (`O[12]`) — REMOVED 2026-07-01 (`feature/remove-diagnostic-cruft`).**
    This diagnostic loaded a raw `.ac3` elementary stream straight into `ac3_front`
    (bypassing ps_demux/audio_ring/av_sync, free-run NCO) to test the decoder decoupled
    from the pipeline. **Its finding stands: it HW-CONFIRMED (2026-06-28) that raw `.ac3`
    plays back clean, EXONERATING the in-fabric AC-3 decoder** — remaining VOB audio
    glitches are PIPELINE-side (ps_demux/audio_ring/av_sync/governor), not `dvd/ac3/*`.
    The toggle + `raw_mode` path + `.ac3` file handling were then removed as cruft
    (the decoder is proven; chase the pipeline).
  - **AC-3 reframer (static-pops fix, 2026-06-28, branch `feature/ac3-graceful-drop`):**
    new `dvd/ac3_reframer.sv` between `ps_demux` and `audio_ring` regenerates
    `aud_frame_start` on AC-3 `0x0B77` boundaries so the ring's drop unit is a WHOLE
    AC-3 frame — an overflow drop becomes a clean silent gap (`ac3_front` resyncs)
    instead of a non-aligned hole → self-heal reset → POP. Transparent passthrough
    (bytes reach `ac3_front` identical), no decoder change. Genlock-Off HW test
    (PR fj#40) proved the pop is INPUT-side overflow, not the output NCO — this targets
    that. Sim-verified (`bench/dvd/ac3_reframer_tb.sv` + `ac3_reframer_ring_tb.sv`:
    forced overflow, every committed frame starts `0B77`). **HW: v1 GREATLY REDUCED
    BBB pops but some remained (Matrix had none — just compute-bound stutter).** v2
    adds a `frmsizcod` FRAME-LENGTH LOCK so a coincidental in-payload `0x0B77` (~4% at
    640kb/s = the residual-pop cause) can't make a spurious boundary — only accepts a
    sync once a full frame is emitted. **✅ v2 HW-CONFIRMED 2026-06-28 (PR fj#41 merged):
    BBB pops GONE.** Static-pops saga closed; remaining BBB/Matrix artifact is
    compute-bound VIDEO stutter only ([[clock-lever-exhausted-matrix]]), not audio.
    See `docs/fabric_audio.md` §"AC-3 reframer".
- 🔧 **PTS-DRIVEN A/V SYNC (2026-06-28, branch `feature/av-sync-pts`).** Audio is now
  genlocked to the video presentation timeline instead of free-running. `dvd/av_sync.sv`
  builds a video-referenced System Time Clock (STC, anchored on `ps_demux.vid_pts`,
  advanced one `TICKS_PER_REFRESH` per displayed image — `refresh_tick` = `core_v_sync`
  edge in clk_sys) and soft-slews the 48 kHz audio NCO (`nco_trim`, ±0.5 %) so the
  dispatched audio PTS tracks the STC — like a DVD player slaving its audio DAC to the
  recovered STC. Per-frame PTS rides `ps_demux.aud_frame_pts → audio_ring descriptor →
  dvd_audio_decode.dispatch_pts → av_sync`. Seek (>0.7 s `vid_pts` jump) re-anchors
  cleanly. **Sim-verified** (`bench/dvd/av_sync_tb.sv` + extended `audio_ring_tb`,
  regressions incl. real-VOB `ps_chain` green); MERGED PR fj#36. **HW: runs; ships with a
  registered VGA output stage that HW-CONFIRMED fixed the placement-marginal output artifacts
  — column dots GONE and no green fringing (see memory `chroma-fringe-is-intermittent`, a
  recurring multi-session issue now likely cured).** Scope = pacing only: the PES-granular
  `audio_ring` drop (static-*pop*) and overlay surfacing of drift/trim are tracked
  follow-ups. Design: `docs/av_sync.md`.
  - **★ LIP-SYNC SAGA (2026-07-02/03, PR fj#60 MERGED — read `docs/av_sync.md`
    "WHERE THIS STANDS" + `docs/lipsync_pickup.md` before touching A/V sync).**
    Eleven HW rounds. SHIPPED + HW-PROVEN: STC references the SCREEN not the demux
    parse (`video_live` gate, one-sided re-anchor, per-load re-arm); playback phase
    set at the PCM-FIFO EXIT (drain gate + stale-skip + pre-anchor dispatch hold —
    drift telemetry went −455 ms → healthy +91 ms); **`P1O[23:21]` A/V Offset**
    (signed 18-bit, 0/−100..−500/+100/+200 ms, WORKS but binds at (re)start events
    only); STD mux-lead hold (DVD muxes audio 470–667 ms BEHIND video — measured
    on real VOBs by `bench/dvd/aud_pts_chain_tb.sv`); film-aware drop reclaim
    (`cur_show` debit, signed debt); VBUF 256 KB→2 MB; absolute `vbuf_healthy`
    (64/32 KB); NCO trim RETIRED (same-crystal rate lock — keep it retired).
    **PR fj#61 (`feature/lipsync-drift`, MERGED 2026-07-04) = six measurement
    rounds; `docs/lipsync_pickup.md` "START HERE" is the live work order.**
    AUDIO IS FULLY EXONERATED (re-confirmed 2026-07-04 on a CLEAN decode:
    play_err constant to the LSB all run). Three audio-side fixes shipped en
    route (stale-skip confined to the load window; arrival-gated mid-play
    catch-up; drop debit = dropped frame's own rff duration).
    **⛔ ROUND-7 RETRACTION (2026-07-04): the "frame_late ×3 post-crash" bug
    NEVER EXISTED — it was a `tools/osd_read.py` mis-calibration (affine
    sx=2.0 against a true 2.667 full-width capture = a 3:4 column-pitch alias:
    displayed bit k sampled true bit k−⌊k/4⌋, inflating every counter row
    4×–13× value-dependently; row 3 read 414/s instead of 59.94). Reader fixed
    (strict row-3 validation + measured-pitch autocorrelation gate + selftest
    alias trap); the same recording re-decoded cleanly (`rec5.mkv` →
    `drift5d.csv`, not retained). TRUE numbers: lates ~4.2/s pre and ~4.1/s post
    crash (honest governor — also verified by RTL analysis: one REPEAT visit
    per scan), drops 2.0→1.4/s, lates/drops 2.0→3.0 (the rff debit working).
    Rounds 4–6 numeric claims are ALL VOID; the qualitative mechanisms stand.
    **ROUND 8 (same day): lips MEASURED from rec5.mkv vs the source VOB
    (audio envelope xcorr + per-frame template matching — all local, no HW).
    Audio content offset CONSTANT all run (audio perfect, direct proof).
    Video content RAMPS ~+3.3% fast from the start of play — funded by the
    draining VBUF cushion (rates match) — until the cushion exhausts at the
    first heavy scene (t≈62, the "crash"), then video clamps to delivery
    rate and the accumulated ~+1.2 s lead freezes (measured constant to the
    ms, t=80→168) = the user's permanent "audio ~900 ms behind". ENGINE =
    FRAME-DROP DEBIT LEAK: drops (2.04/s) inject each dropped frame's TRUE
    duration (~2.5–3 refr; rff-mixed B population) while the debt controller
    reclaims only ~2.04/drop (the measured lates/drops ratio) ⇒
    `drop_pic_rff` READS 0 ON HW, the round-4 film-aware debit (61b230c) is
    inert; each dropped rff B leaks +1 refresh ≈ +3%. Governor pacing itself
    is HONEST (recording cadence run-lengths = true 3:2 + the honest lates;
    scan-vs-raster locked: resample_chain_tb SCANRATE instrument + mixer
    frame-top-parking analysis). Also ruled out: VOB PTS discontinuities
    (full-file scan clean), STC re-anchor, watchdog resets, scan free-run.
    ROUNDS 9–12 (same day): rounds 9–10 shipped the row-16 drop-debit
    instrument ({debited-3, debited-2}, replacing stc_excess) + sim-exonerated
    the vld drop path (vld_drop_rff_tb over a real MiB ES); round 11 found the
    TRUE ROOT CAUSE when drift7 read identical to drift6: **STALE DISPLAY
    FLAGS — picbuf captured rff/tff/progressive_frame at the picture-HEADER
    update pulse, but they parse in the coding EXTENSION (the vld freezes at
    the header), so every picture displayed with its coded PREDECESSOR's
    flags.** Invisible on clean 3:2 (alternation preserved); frame drops broke
    the pairing and leaked ~+1 refresh per drop = the ramp. FIX =
    `flags_commit` (vld pulses at ext-parsed, never for dropped pics; direct
    wire to picbuf which re-latches the three flags; ordering by the header
    freeze). **✅ ROUND 12 HW-CONFIRMED (drift9b capture, DVD_drift8, 7.5 min MiB
    through the Shea crash): vid_err FLAT ±3 all run, VBUF PARKED (~0.5–1.2 MB,
    rises through the crash), lates/drops 2.03–2.05 constant, play_err
    constant to the LSB, lips constant throughout (user-confirmed). THE DRIFT
    SAGA IS CLOSED.** Bonus: the old "−500 ms start constant" was mostly the
    ramp — the true residual start error is ~−100 ms (audio slightly early;
    user now runs A/V Offset +100). See docs/lipsync_pickup.md rounds 7–12.**
    Follow-ups 1 & 2 SHIPPED (`feature/lipsync-followups`): the **A/V Offset
    default is now +100 ms** (NTSC-film null), menu rebalanced around ±200 ms
    (-300/-400/-500 dropped); the overlay is cleaned up — rows 14/15 restored to
    the AC-3 self-heal reset view (14 ERR, 15 TOTAL, no O[12] mux), drift
    instrument rows retired (overlay NROW 21→17, `stc_excess` emu logic dropped),
    row 16 {drop3,drop2} kept until a Matrix/PAL pass; `tools/osd_read.py`
    ROW_LABELS updated. **+100 ms default ✅ HW-verified on Matrix/PAL too
    (2026-07-10) — treat it as universal.** Remaining: the secondary
    why-4-lates/s-churn curiosity.
    EXONERATED by measurement (do NOT re-chase): PTS chain, anchor value, NCO
    rate, mux geometry as drift, AC-3 self-heal resets, STC-vs-wall rate,
    live-flag cadence sampling, self-sustaining drop churn (both sim-cleared in
    `bench/dvd/cadence_phase_tb.sv`).
    FAILED (do NOT retry): entry-side dispatch scheduling, pre-anchor gate bypass,
    mid-play gate re-arm (full-FIFO deadlock), fractional vbuf thresholds, 16-bit
    offset constants.
  - **`O[13],Audio Genlock,On,Off`** (2026-06-28, branch
  `feature/vob-audio-freerun`): set Off to free-run the audio NCO (`nco_trim=0`)
  while a VOB plays through the full pipeline — a diagnostic to tell av_sync/governor
  PACING apart from `audio_ring` overflow / `ps_demux` filtering, now that AC-3 File
  Test has HW-exonerated the decoder. See `docs/fabric_audio.md` §"Audio Genlock toggle".
  - *(Prior HPS-decode path, retired: FPGA wrote compressed frames to a DDR3 ring at byte
    `0x30800000` for the standalone `hps/dvd_audio.c` daemon (liba52) to mmap/decode/ALSA.
    HW-confirmed 2026-06-25; see `docs/audio_ddr_path.md` for history.)*
- ✅ **Decoded, correct-color SD MPEG-2 video on real hardware** (DE10-Nano + 128 MB SDRAM
  add-on board). This is the first confirmed video; the inherited "✅ decode works" claims below
  were aspirational until now. The path: the HPS f2sdram read path can't sustain the core's
  108 MHz on this board, so the core's memory was ported to the SDRAM module (`dvd/sdram.sv` +
  `dvd/mem_sdram_shim.sv`, branch `feature/sdram-module`, PR fj#6).
- ✅ **Shear (sawtooth) is RESOLVED — NOT a current problem; do not chase it.** The earlier
  sawtooth bandwidth limit was fixed by the DDR3 burst-bridge work plus raising the decoder
  compute clock to 54 MHz (PR fj#10 / `DVD_dec54d` and the f2sdram burst path). 720×480 has not
  sheared for many build iterations. (Historical diagnosis condensed in `docs/history.md`
  §1–2; full logs in git history.)
- ✅ **The "256-line black-frame strobe" is RESOLVED for ≤480 content** (2026-06-24,
  branch `feature/strobe-offset-diagnosis`). It was a PICTURE SPLIT, not memory/black: the
  resample emitted the macroblock-padded height (`mb_height*16`) while the raster active
  region was the true `vertical_size`, so the surplus lines spilled into the next output
  frame. Fixed by (1) ending the emission at `disp_y == vertical_size-1`
  (`dvd/resample_addrgen.v`) and (2) `VERT_RES 479→480` (`modeline.v`, an active-region
  off-by-one). Progressive + 480 clips play clean. Full story in
  `docs/history.md`. **Still open (separate):** vert-res >480 content still spills
  (needs downscale). *(Interlaced ~half-speed field-cadence is addressed by native 480i/576i
  fields output — see the `Interlaced Out: Auto` note below.)*
- ✅ **Interlaced Out (Off/Auto/On) — native 480i/576i fields to ascal — HW-CONFIRMED +
  MERGED (PR fj#132, 2026-07-27).** `O[10:9] Interlaced Out` is 3-way **Off/Auto/On**,
  **default Off** (reverted from Auto 2026-07-27 — see below). `On` gives native interlaced
  fields (NTSC 480i **and** the newly-added **PAL 576i**: `il_eff` no longer forced low under
  PAL; new `pal_prev & il_prev` modeline branch, 312 lines/field ≈ 50 Hz) and plays
  **A/V-synced on HW (confirmed)**. A standard-neutral `det_video` verdict in
  `dvd/resample_addrgen.v` (sustained `progressive_frame==0`, mutually exclusive with the
  film verdicts) drives **Auto**, which auto-engages interlaced for true video-sourced
  content via a mid-title **full seek-style flush** (`il_switch` → load_flush + aud_flush +
  vbuf flush). **⚠️ Auto is NOT the default: its mid-title switch still leaves audio
  SLIGHTLY OUT OF SYNC on HW** (round 1–2, 2026-07-26/27) even after the seek-style
  re-sync — kept as an opt-in to revisit. The **overlay/OSD horizontal squish** in
  interlaced mode is now **✅ FIXED (2026-08-22)** — `ov_h_gen`/`sp_qx` invert the pixrep
  ×2 in `dvd/emu.sv` and `spu_decode`/`crt_ov_map` `.interlaced` follow `il_eff` (their
  +2 field-line walk had never engaged); progressive is bit-identical. Bob/Weave still
  `O11`. PAL 576i on the analog pins is now covered by the dual-raster re-interlacer
  (see the Dual-Raster bullet below). **Dual-raster v1 note:** while the analog raster is
  engaged (`analog_eff`), Interlaced Out is FORCED OFF (the re-interlacer needs the
  standard progressive main raster; the CRT still gets true 480i via the weave frames).
  Sim: `bench/dvd/film_detect_tb.sv`. Design + follow-ups: **`docs/interlaced_auto.md`**.
- ✅ **DUAL-RASTER ANALOG OUTPUT (2026-07-29, HW-CONFIRMED + MERGED PR fj#146,
  2026-07-30) — SUPERSEDES the O[14] whole-core CRT mode below.** User-confirmed
  working on real hardware (analog engages from ini alone, HDMI stays progressive
  simultaneously). ⚠️ The exact PAL 576i timing numbers and the field-dominance
  caveat (see `docs/analog_dual_raster.md`) were not specifically re-verified by
  this confirmation and remain open sub-items.
  The analog CRT now works **from MiSTer.ini alone, like any other core**
  (`vga_scaler=0` + `composite_sync=1`/ypbpr/sog — nothing in the OSD): the core emits
  TWO simultaneous rasters — the unchanged progressive main raster for ascal/HDMI, and
  a native 15 kHz 480i/**576i (PAL now included)** second raster from
  `dvd/re_interlace.sv` (4-line sync-read BRAM + a second N64-model `sync_gen`
  instance, phase-locked by construction: 2 fields = exactly 2 main frames; arming
  skew window (1716,1994) clk27, proven by `bench/dvd/re_interlace_tb.sv`'s
  pixel-exact frame-tag checks). New additive `sys_top.v` `VGA2_*` input muxes the
  direct analog chain (incl. the direct_video tap → HDMI-DAC CRTs work too);
  `hps_io.sv` exports the ini bits (cfg[2]/[3]/[5]/[9]); **`VGA_SCALER=0` always**
  (the forced-1 that made ini `vga_scaler=0` unobservable is gone). `O[27:26] Analog
  Out` = Auto/Interlaced/Progressive override (default Auto). Retired: O[14], the
  13.5 MHz `dot_ce` main-raster pacing (CE_PIXEL≡1 now), the modeline-walk CRT
  branch, `crt_eff` (Analog Aspect + overlay gating now ride `analog_eff`; overlay
  taps are always progressive). Also fixed: the bogus `"O[10],Direct Video"` CONF_STR
  line that collided with `O[10:9] Interlaced Out`. Precedence: analog active ⇒ Film
  24p/25p raster suppressed (can't feed the re-interlacer) and Interlaced Out forced
  off (v1). VIDEO_ARX/ARY force 4:3 while Analog Letterbox/Crop is active (the
  rescale is upstream in the now-shared raster). ⚠ PAL 576i numbers are sim-derived —
  HW gate. Design + HW checklist: **`docs/analog_dual_raster.md`**.
  - **✅ `Analog Out = Native Fields` (field passthrough) — 2026-08-22, HW-CONFIRMED
    (core claim; PR fj#178).** A/B'd vs `Auto` on `ROGER_WATERS_IN_THE_FLESH` — MEASURED
    video-sourced by `tools/video_cadence_census.py`, not assumed — fields output
    **noticeably smoother**; 50-min MiB run held A/V sync (that run also covers the
    FIELD-path governor ledger under rff 3:2, and Letterbox — MiB's title is 16:9
    anamorphic so Auto had it active). Overlays full width in this mode ✅, other
    Analog Out modes unregressed ✅, and `Interlaced Out = On` on HDMI now renders
    overlays correctly ✅ (that half is the standalone fix). **Only PAL-analog is
    unverified** — no PAL CRT available; The Office plays right on HDMI, and PAL
    fieldpass is sim-proven, but PR fj#146's sim-derived PAL 576i raster numbers STAY OPEN. Fourth `O[27:26]` mode: forces `il_eff` for the session so
    the decoder emits **authored** TOP/BOTTOM fields and `re_interlace` re-times them
    1:1 (`fieldpass`: period 900900/1080000, write-port pixrep decimation, `SKEW_FP=858`).
    **This is the structural fix for the field-pairing defect**, and WHY the obvious cheap
    fix was rejected is worth remembering: a governor **late** re-scans one FRAME on the
    progressive path (**+1 refresh = ODD ⇒ the pairing parity FLIPS**) but a FIELD PAIR on
    the field path (+2 = even), and lates run **~4/s on healthy content** — so
    phase-aligning the re-interlacer would hold ~250 ms, and re-arming blanks the CRT's
    sync (`S_HUNT` drops `sg_rst_n`). Film barely cares (each field still lies wholly in
    one picture; only dominance alternates); **true 29.97i video is where combing shows**.
    ★ The main raster does NOT need a half-line — the local `sync_gen` supplies it and the
    source's field durations already alternate 262/263, so the rasters stay line-for-line
    locked (proven pixel-exactly, `re_interlace_tb` [6]/[7]); a half-line on the main
    raster would expose HDMI to the `ff01ac8` hunting issue for nothing. Opt-in: HDMI
    drops to 480i via ascal for the session (ascal isn't cadence-aware ⇒ film regresses
    there). Set it BEFORE loading a disc (a mid-title change fires the `il_switch` flush).
    Ships with the overlay pixrep fix as a hard prerequisite.
- ✅ **CRT 480i — native 15 kHz 2:1 interlace: HW-CONFIRMED 2026-07-05 (PR fj#65,
  `feature/crt-480i-native`) — ⛔ SUPERSEDED by the dual-raster bullet above (O[14]
  removed); the syncgen N64 model, pixel_queue CE-stretch, and field-path ledger
  fixes it delivered still ship.** Round 2 verdict on the real CRT: image CORRECT (true 2:1
  interlace, native width, field order right as shipped) and AUDIO STAYS IN SYNC (the
  field-path ledger fixes hold). Round 1 had confirmed the raster but showed BLACK video →
  root cause = a latent CE bug in `rtl/mpeg2/pixel_queue.v` (the dc-fifo's raw-clock
  `valid` pulse falls entirely inside the disabled 13.5 MHz-CE cycle, so the mixer never
  latches a pixel; audio/overlay kept flowing). Fixed with a CE-stretch shim (bit-identical
  at CE≡1); reproduced + proven end-to-end by `resample_chain_tb +crt=1`.
  **⚠️ Open follow-up: the HDMI chroma fringe REGRESSED on this build** — the known
  clk_dec-Fmax/fit-margin artifact, not the CRT logic (see docs/crt_480i.md status note +
  memories `chroma-edge-fringe-is-upsample-mode`, `quartus-build-flaky-routing`; builds ran
  with an uncommitted SEED 9). See docs/crt_480i.md §0/§8.** `O[14] CRT 480i Out`: native-width 480i for a real
  CRT on the analog board, built to the N64 model after the pulse-delay approach was
  HW-proven never to lock (memory `crt-interlace-odd-total-lines` — the old
  `feature/crt-composite` branch is dead; this is the fresh start). Three legs:
  (1) `rtl/mpeg2/syncgen.v` N64-model interlace, armed by `interlaced && halfline!=0`:
  alternating 262/263 field totals + vsync sampled at a half-line COUNTER reference ⇒
  vsync spacing exactly 262.5 lines every field (`bench/dvd/crt_syncgen_tb.sv`; legacy
  480p/HDMI-480i bit-identical). (2) `dvd/emu.sv`: 13.5 MHz `dot_ce`/`CE_PIXEL` (native
  720-wide, NOT pixel-repetition), a 4th modeline-walk branch (halfline=429, pixrep off),
  and `VGA_SCALER=0` in CRT mode (it was hardwired 1 = forcing the scaler onto the analog
  pins). (3) 480i field-path A/V-ledger fixes (the audio-drifts-ahead blocker from the old
  branch): 2-cycle `frame_late` on pair repeats (the ×2 late undercount — dominant),
  mode-aware `show_next` (rff film = 3 field scans in 480i), `~interlaced` drop-debit
  gates removed (`rtl/mpeg2/mpeg2video.v`), and `refresh_cnt` SATURATION (the 4-bit wrap
  silently ate ~12% of stall lateness in BOTH display modes;
  `bench/dvd/gov_field_late_tb.sv` proves 1:1 late:refresh accounting). Overlay row 17 =
  `vid_err` re-added (NROW 17→18, `tools/osd_read.py` updated + selftest green) — the HW
  verdict is that row staying FLAT through a compute crush in 480i. CRT needs `MiSTer.ini`
  `vga_scaler=0`, `composite_sync=1`. Full design + HW test plan + field-swap contingency:
  `docs/crt_480i.md`. (PAL 576i CRT: ✅ delivered by the dual-raster rework above;
  letterbox/240p vertical scaler still open.)
- 🧰 On-hardware diagnostics: `debug_overlay.sv` (multi-row block-bit counters — rows 0-17 +
  Phase-7 rows 18/19 nav current/total time). ⚠️ **STATUS (2026-07-09): this overlay is
  `` `ifdef DEBUG_OVERLAY `` and COMPILED OUT of the release build** (it shares the display
  hotspot with the subpicture blend; `ov_on` is hardwired 0 — see `emu.sv` ~L2088). In a
  **release `.rbf`, `O[2]` shows NOTHING from this overlay**; instead `O[2]` drives only the
  lightweight **menu-highlight diagnostic blocks** (`status[2] && menus_on`, `dbg_blk1..8`).
  To read the multi-row overlay / `tools/osd_read.py` rows on HW you must **define
  `DEBUG_OVERLAY` in `DVD.qsf` and rebuild** (that re-tightens the congested fit — verify it
  still closes + passes the clk_dec fringe gate). ⚠️ overlay
  watchdog cell polarity gotcha documented above. (The DRAM/SDRAM self-tests, DDR3 burst BIST,
  AC-3 File Test, and the SDRAM controller were removed 2026-07-01 in
  `feature/remove-diagnostic-cruft` to simplify the on-board logic; see `docs/history.md`.)

## What Already Works (Upstream MiSTer_MPEG2)

- ✅ Full hardware MPEG-2 video decode in FPGA fabric (IDCT, motion comp, VLC)
- ✅ High-bandwidth SD card sector streaming (`mpg_streamer.sv`) via `sd_*` block interface
- ✅ DDR3 frame buffer management (`mem_shim.sv`) — pipelined FSM with skid buffer
- ✅ TrustZone-compliant 15.5MB HD frame buffer within MiSTer's 24MB CMA window
- ✅ NTSC 480p/60Hz video output via MiSTer framework
- ✅ Simulation testbench (`bench/`) and debug tooling

## Known Gaps in Upstream (what this project adds)

- ✅ Framerate sync: PAL now supported via a runtime modeline switch — **HW-CONFIRMED**
  (2026-06-30, branch `feature/hres-offbyone-pal`, PR fj#50). The 27 MHz dot clock gives 50.0 Hz
  with PAL totals (864×625), so NO PLL reconfig is needed: `O[17:16] Video Standard`
  (Auto/NTSC/PAL) drives the runtime modeline-write walk (`dvd/emu.sv`) to 720×576p@50 +
  `av_sync`'s 50 Hz STC (`refresh_50hz`); governor `SHOW_N=2` already yields 25 fps at 50 Hz.
  **Auto** detects from the decoder's new `vertical_size_out` port (480=NTSC, 576=PAL). PAL
  progressive (25p) film via Film 25p; **PAL 576i interlaced now supported** (HDMI fields via
  `Interlaced Out`, PR fj#132; analog pins via the dual-raster re-interlacer — see the
  Dual-Raster bullet above, ⏳ HW-pending). Also
  fixed the horizontal off-by-one (`HORZ_RES 719→720`, recovers the 1-col right crop), the
  analogue of the earlier `VERT_RES 479→480`. **⚠️ PAL playback STUTTERS on high-motion (BBB
  PAL DVD):** same compute-bound decoder ceiling as the NTSC high-motion stutter, just exposed
  harder by the ~20% taller 576-line frame (1620 vs 1350 MB/frame) — NOT a PAL timing/pacing
  bug. Rides on the deferred motion-comp/IDCT rewrite. See docs/roadmap.md "PAL/NTSC Framerate
  Sync" and the `*compute-bound*` memories.
- ❌ HD modeline switching: fixed 27MHz SD clock, no dynamic PLL for 720p/1080p
- ❌ Audio: core is video-only, no audio output of any kind
- ✅ **DVD ISO playback (v1) — IN FABRIC, no HPS daemon — HW-CONFIRMED 2026-07-05**
  (PR fj#70, branch `feature/dvd-iso-navigator`, `DVD_isonav`). `dvd/dvd_iso_reader.sv`
  replaces `mpg_streamer`: select a **decrypted DVD-Video `.iso`** and it detects
  ISO9660, walks root → `VIDEO_TS`, and plays the **largest VTS = main feature**. The
  `sd_*` block interface is random-access (framework serves any `sd_lba`), so nav is all
  in fabric — nothing on the HPS. Non-ISO images fall back to linear whole-file streaming
  (`.VOB`/`.mpg`/`.m2v` unchanged, HW-confirmed). **CSS stays a PC-side rip step**
  (MakeMKV/dvdbackup); ISO9660 only (UDF-only images deferred); no IFO/PGC yet
  (chapters/seek/angles = Phases 7–9). **⚠️ The largest-VTS heuristic does NOT pick the
  right main title on every disc** (fix = IFO/PGC or a manual OSD title picker, deferred).
  **Fit gotcha (fixed):** `parse_buf` must be a SYNC-read BRAM — the first build hit 226%
  ALMs because it was read async at ~30 offsets (LUT-RAM explosion); now 81% ALMs, one
  M10K + a 45-byte `rbuf` record shadow. Tests: `bench/dvd/iso_reader_tb.sv` (synthetic) +
  `bench/dvd/iso_reader_real_tb.sv` (real MEN_IN_BLACK metadata → VTS_21). Predictor:
  `tools/iso_nav_check.py`. Design: **`docs/dvd_nav.md`**.
  - **🔧 SD DELIVERY 2048-BYTE BLOCKS (2026-08-03/04, branch `feature/sd-2048-blocks`,
    PR fj#159).** `hps_io BLKSZ=4` → one 2048-byte request per DVD sector (4× fewer HPS
    round-trips; sd_lba = sector LBA = RBN 1:1, the ×4 mapping deleted; NAV/DSI snoop
    offsets now sector-relative). Motivated by the **Thayer's Quest ~3 Hz audio
    skipping** + the disc being authored at the DVD mux ceiling (pack-SCR scan: VTS_02
    sustains 9.47–10.08 Mbps for minutes; clean discs average 5.2–5.5). **⚠ HW verdict
    (2026-08-04): the skip rate was UNCHANGED — delivery is EXONERATED for that symptom**
    (and "VBUF bar low" is NOT a starvation proof: STD backpressure parks it low in
    normal play). The rework stands on its own (headroom for mux-ceiling discs, simpler
    reader, larger CIFS reads); all 27 reader TBs green (chapter_tb cells grown to 16
    sectors — 1-sector cells let the 8-sector cache prefetch outrun the drain, a TB
    artifact). Further lever if needed: `sd_blk_cnt` up to 16 KB/request.
    **★ THAYER SAGA ULTIMATE ROOT CAUSE — ✅ FIXED + HW-CONFIRMED 2026-08-05 (audio
    solid AND in sync): THE DISC IS MOSTLY FIELD-CODED MPEG-2, and the frame-drop
    governor's documented punt on field-picture B's meant its ~10 % video-decode
    deficit (6–7 lates/s, drops=0 by design) could never be reclaimed** — video ran
    slow, audio didn't wait (vid_err +8 refr/s = the audio-early A/V drift), and the
    backed-up buffers entered the VBUF-hard-full jam (demux stalls mid-PES on video,
    the ring backpressure never engages, the audio ring bleeds to 0 with no restoring
    force = the menu/gameplay skipping). Deep `picture_structure` census: VMGM-past-
    head + VTS_02/05/07/11 = top/bottom FIELD pictures; only VTS_09 + VOB lead-ins
    frame-coded (every early ES sample had hit those by luck — census DEEP, not
    heads). **Fix = B FIELD-PAIR DROP (`rtl/mpeg2/vld.v`):** decide at the FIRST
    field (second_field reads 1 there = the update-pulse convention, so the pair's
    update suppresses like a frame-B), `drop_pair_arm` atomically drops the sibling,
    new `drop_pic_field` acks cost/credit **1 per field** (a pair debits exactly the
    2 refreshes it frees). Sim: field ES drops in clean atomic pairs; frame streams
    identical; `vld_drop_rff_tb +DRAIN` display-blocked mode added. Diagnosis
    instruments kept (DEBUG_OVERLAY builds): row 27 flow-control flags, row 16
    in-vld drop probe. ⛔ Two preserve/keep "netlist mangling" rounds en route were a
    GHOST (the probes disproved it; hardening kept as insurance). Flow-control work
    kept on merit: v2 stall grain 0x2C, v3 ring-floor escape, **v4 GLOBAL VBUF SOFT
    CEILING 0xE0/0xD8** (VBUF-hard-full is a death regime — never reach it), and the
    **menu cap halved 0x30→0x18**. Also measured: Thayer's audio mux lead ~33 ms
    (normal 470–667 ms); an inaudible ≤15-LSB AC-3 cpl-exponent divergence (open
    follow-up). See `docs/dvd_menu_refinements.md` §5d amendment + `docs/dvd_nav.md`
    "Block size".
  - **★ HIGHLIGHT PROMOTION MODEL v2 — ✅ HW-CONFIRMED 2026-08-06 (T2 + MiB + Thayer,
    4 probe rounds via overlay row 26).** The branch's sd-2048 speedup exposed that
    nav_pci's promotion paths trusted a parse-anchored clock: highlights painted over
    menu transitions (early) or starved (late). Final model, every path
    display-justified: **STC-scheduled** promotion requires a REAL crossing
    (`nxt_pre`: commit before the window start) AND a TRUSTED clock (`stc_fresh` =
    last load flushed, or `settled_seen` = a still park since load); **scheduled
    DISARMS require the trusted clock too** (stale per-VOBU ss=0 disarms on a
    keep_vbuf timeline starved promotions — off_due outranks nxt_due);
    **settle promotion** (`menu_settled` = reader `still_active` && VBUF ≤ ~24 KB —
    reader-park alone fired with ~0.5–1.5 s of transition still buffered) lands the
    highlight WITH the settled image on parking menus (T2 confirmed great); **timer
    fallback 1.0 s** serves only LOOPING motion menus (MiB pages/root — probes proved
    they never park, so no settle signal exists; sub-second transitions). Probe kept:
    overlay row 26 = {promo_cnt, src 1=sched/2=settle/3=timer, age ~4.85 ms units}.
    See `dvd/nav_pci.sv` header comments.
- ✅ **GAMEPAD TRANSPORT: cell-granular seek + pause (2026-07-06) — HW-PROVEN via the
  later transport stack (chapters/scrub/HUD/pause exercised on the board, PRs fj#96/#101/#103/#106).** The
  reusable **seek primitive** (later unlocks chapters/FF/skip/menu-jump — all reduce to "jump +
  re-sync"): `dvd_iso_reader` gains `seek_pulse`/`seek_cell` (+`seek_ack`/`cur_cell`/`cell_ready`)
  to jump to a PGC cell, **latched and executed at a block boundary** (`seek_jump = seek_pending
  && ~blk_inflight` — let the outstanding `sd` read finish or its beats leak as stale cache bytes)
  by reusing the existing `S_CELL_LOAD→…→S_STREAM` cell-load path. Gamepad (`joystick_0`, prev
  unused; `J1,Pause,Prev Chapter,Next Chapter`): B1=pause, B3/Right=next cell, B2/Left=prev cell.
  **★ HW ROUND-1 exposed two architectural gaps, both from the decoder's ~1 s VBUF cushion +
  audio continuity; fixed via NATIVE decoder trick-play hooks (not a decoder reset):**
  (1) **Seek video lagged ~1 s** (audio jumped immediately, old buffered video played on): `seek_ack`
  now also pulses `mpeg2video.vbuf_flush` (seek-only `seek_flush` level → clk_dec), ORed into the
  regfile's native `flush_vbuf`, discarding the buffered bitstream so video jumps with the audio.
  (2) **Pause → still frame went BLACK + res popup after ~1 s, and audio kept playing** (desync grew
  with pause length): the governor freeze stalled the decoder → the **watchdog** reset it (black
  screen) — now the watchdog is fed `repeat_frame=31` (native freeze-suppress) while paused; and
  **audio is held** by gating `dvd_audio_decode`'s play tick (`aud_ce_play &= ~pause`, reuses the
  drain-hold → silence, seamless resume) + freezing the ring drain watchdog (`aud_bp_wd`). Pause
  now = 4 coordinated holds: governor freeze + watchdog-suppress + STC freeze (`av_sync.pause`) +
  audio hold. Tests: `bench/dvd/iso_reader_seek_tb.sv`, `av_sync_tb.sv` [5]. Design:
  `docs/dvd_nav.md` "Transport". Cell-granular only (cells start on clean GOP boundaries → decoder
  re-locks); sub-cell/time-based seek deferred. **Watch on HW re-test:** rapid multi-seek
  robustness (round-1 "skipping record" + audio-stop) and any brief glitch frame at the VBUF flush.
  **A/V-sync-after-scrub ✅ HW-CONFIRMED (2026-07-10, PR fj#106, `DVD_scrubalign_20260710_2312.rbf`,
  SEED 13 clk_dec 94.36/90.19 MHz):** the hold-to-seek scrub's raw-RBN target landed mid-VOBU → decoder re-locked
  mid-GOP (pixelated) and av_sync anchored the STC on the *next* VOBU's video PTS → permanent
  sub-second audio lead (a chapter jump re-aligned it). The reader now snaps the scrub target
  forward to the first NAV pack (VOBU boundary) via a 1-block parse-probe (`S_NAV_SEEK*`,
  `NAV_CAP=1024`, raw fallback) so a scrub landing matches the chapter-seek contract. Scope:
  the `seek_is_rbn` title path only. See `docs/dvd_nav.md` §2a.
- ✅ **DISC MENUS Phase 2 — menu domain + VM jump interface (2026-07-07, PR fj#80) —
  HW-CONFIRMED via the menu-refinements rounds (PRs fj#84–fj#90; see
  `docs/dvd_menu_refinements.md` status roll-up).** `O[1] Disc Menus` (**default On** as of
  2026-08-23 — the end-user defaults pass; was Off through the phase work) +
  `J1,...,Select,Menu`: Menu jumps from the playing title to the disc's authored
  **VTS root menu** (VTSM PGCI_UT@208 → LU[0] → entry 0x83; fallback chain VTSM→VMGM→
  resume), Menu/Select again resumes the title at the saved cell. Reader gained the
  reusable **VM jump primitive** (`jump_pulse/{domain FP/VMGM/VTSM/TT, vts, pgcn, entry,
  cell}` → `jump_ack` on the seek flush contract + `pgc_loaded/pgc_error`), a
  **generalized PGCIT path** (one parser for title + menu PGCs, mount included), and a
  **sector-crossing byte walker** that parses PGC hdr@156-233 (still@163, palette@164 —
  the Phase-1 straddle-skip is GONE), streams the **full command table** out on `cmd_we`
  (Phase-4 VM BRAM format, frozen), and loads cells WITH `{still_time,cell_cmd_nr}` meta.
  Real-disc findings baked in: MiB's root entry PGC = 0-cell command stub → reader
  follows the last pre-command LinkPGCN (uncond preferred, depth ≤2); menu stills are
  CELL-level (0xFF) → **drain-then-`S_STILL`** with a watchdog-only hold
  (`mpeg2video.freeze_wd`), NOT the 4-hold pause set (the decoder must play out its
  buffered tail to reach the authored still frame — the seek-VBUF lesson in reverse).
  `tools/iso_nav_check.py decode_vmcmd` rewritten as a faithful libdvdnav vmcmd.c port
  (the old ad-hoc decoder had the jump op codes WRONG: op2=JumpTT read as JumpVTS_TT,
  op6=JumpSS as JumpTT) + menu PGCI_UT dumps, validated on MiB/Matrix/T2 (zero
  unknown-bit warnings). Tests: `bench/dvd/iso_reader_menu_tb.sv` (6 scenarios incl.
  straddling-PGC follow) + all existing reader tbs + real-VOB ps_chain green. Design:
  `docs/dvd_nav.md` "Menu domain". **HW ROUND 1 (2026-07-07): Matrix menu WORKS +
  resume works on both discs; MiB = silent black** — root cause from the IFO dump: MiB
  VTS_21's root entry is a 0-cell **JumpSS trampoline** (g14=0x3500 → VMGM dispatcher
  → JumpSS VTSM vts 2 = needs real VM execution); the old VTSM→VMGM fallback landed on
  VMGM PGC1's cells = authored BLACK FILLER. **Round-2 fix (re-test pending): fallback
  chain gained a hop — own VTSM → VTSM of the LARGEST-menu-VOB VTS (`best_menu_vts`;
  MiB: VTS_02_0.VOB 261 MB → its root LinkPGCNs to the real menu) → VMGM → resume.**
  Also HW-learned: menu 4:3 aspect = authored (Auto follows seq hdr, correct); menu
  subpictures invisible with O[15] On = authored contrast 0, visibility comes from HLI
  highlight colours (Phase 3), NOT a decode gap.
- ✅ **DISC MENUS Phase 3 — PCI/HLI button highlights + gamepad nav (2026-07-07) —
  HW-CONFIRMED (highlight render closed by PR fj#83/#84, `docs/dvd_menu_refinements.md` §1).** ps_demux routes
  private_stream_2 substream 0x00 (PCI; SYSTEM syntax, no PES opt header, off
  S_SYS_LEN_LO) → new `dvd/nav_pci.sv` (double-buffered HLI BRAM 0x60-0x315, hli_ss
  commit semantics, fosl/foac, STC arm window, button-record fetch → REGISTERS, D-pad
  link walk, activate = btn_cmd + ~0.6s ACT flash). Highlight render: inside the rect
  the sp pixel class takes the HLI coli nibbles ([Ci3..Ci0 A3..A0], on-disc verified)
  through the SAME pgc_palette→subpic_blend path; spu_decode force-enabled while a menu
  is up (O[15]-independent). Reader gained the CELL-LOOP heuristic (replay a
  button-armed cell with cell_cmd≠0 — MiB's interactive screen is mid-PGC cell 1; the
  authored loop is a cell command). emu micro-bridge: LinkPGCN → same-PGCIT menu jump
  (MiB submenus/Matrix menus WORK), LinkTailPGC → title resume; rest flash-only until
  the Phase-4 VM. Golden tools: `tools/nav_extract.py` (PCI/HLI decoder + NAV fixture
  writer, offsets vs libdvdread nav_types.h). Tests: nav_pci_tb + ps_demux_ps2_tb (real
  MiB NAV sectors, byte-exact), all reader/demux/subpic suites green. Design:
  docs/dvd_nav.md "Menu buttons". **HW gate:** MiB/Matrix menu → highlight visible,
  D-pad follows the authored link graph, Select opens MiB submenus (LinkPGCN) / flashes
  play buttons, menu loops instead of parking. Next: Phase 4 dvd_vm.sv interpreter.
- ✅ **DISC MENUS Phase 4 — DVD-VM interpreter (2026-07-07) — HW-CONFIRMED via the
  menu-refinements rounds (menus work on real discs; see `docs/dvd_menu_refinements.md`).** New `dvd/dvd_vm.sv` EXECUTES the disc's nav
  commands (faithful libdvdnav decoder.c eval; types 5/6 per vmcmd.c — decoder.c's
  own 5/6 is FIXME-wrong; type 4 compares AFTER its set, others before). GPRM×16 +
  SPRM subset, cmd BRAM 2048×8 + program-map BRAM (reader-streamed), serial ALU,
  LFSR16 rnd — all bit-exact vs `tools/dvd_vm_ref.py` (the new golden model,
  validated on MiB/BBB/Matrix: MiB's Menu key executes the FULL JumpSS trampoline
  to the real VTS_02 menu; BBB FP = JumpTT 4 — the old "JumpVTS_TT" reading was the
  pre-rewrite decoder bug). With `O[1]` On: mount boots the **First Play PGC** (no
  auto-play), buttons/menu keys run real commands (CallSS/RSM resume with skip_pre,
  LinkTailPGC→POST dispatch = MiB Play, SetSTN→SPRM1/2→demux track mux), POST runs
  at title end (drain-first), menu loops via vm_replay (gapless). Reader gained
  `vm_mode` S_VM_WAIT verdicts (+0.62s watchdog), JumpTT TT_SRPT resolve +
  title-entry scan, P_PMAP program-map walk; emu's Phase-2/3 proto-nav/micro-bridge
  glue is DELETED (VM owns jumps; nav_pci gained `sel_force` for SetHL_BTNN).
  Menus Off = Phase-3 behaviour exactly. Punted: angles, PTT exactness (Phase 6),
  GPRM counter tick, UOPs, parental. Tests: dvd_vm_tb (27 vectors + 9 scenarios),
  iso_reader_vm_tb (command-driven boot→menu→loop→resume→post), all reader/demux/
  nav suites green. Design: **`docs/dvd_vm.md`**. **HW gate: BBB boots FP→menu→
  correct feature; MiB trampoline/Play/resume; SetSTN switches streams.**
- ✅ **DISC MENUS Phase 5 — menu-transition VBUF hold (2026-07-08, PR fj#84) —
  HW round-2 ACCEPTED (see the ★ notes below + `docs/dvd_menu_refinements.md` §2).** Fixes the T2
  "offset highlight / freeze mid-transition" (and §3 "wrong timeline"): the
  highlight was correct but sat over a **stale/frozen menu image**. Root cause
  (decoded from the disc): a menu→menu transition fired `vbuf_flush`, cold-
  restarting the decoder so the persistence frame (old menu still) stayed while
  nav_pci armed the NEW menu's highlight. Reader now exports **`keep_vbuf`** (1 on
  a menu-internal seek / menu→menu jump / menu next_pgcn advance); emu gates
  `seek_flush_cnt` with `~keep_vbuf` so those transitions pulse **`load_flush`
  only, not `vbuf_flush`** → the decoder plays out the authored transition tail
  then decodes the new menu (no stale frame). Title seeks / menu→title (Play) /
  title→menu (Menu key) keep the flush (A/V-sync). Tests: `iso_reader_menu_tb`
  (T2/T4/T8 keep_vbuf table), `iso_reader_seek_tb` (title seek keeps it 0). Design:
  `docs/dvd_menu_refinements.md` §2, `docs/dvd_nav.md` "Menu-transition VBUF hold".
  **HW gate: T2/Matrix submenu enter + timeline select land on the correct menu
  with the highlight over the matching image; MiB/BBB unchanged; O[1] Off unaffected.**
  **★ HW ROUND 2 (2026-07-08): keep_vbuf ACCEPTED** — transitions + timeline switch
  work. Added **Phase 5b — nav_pci `video_live` fallback promotion**: deep menus
  (Mission Profiles, "Jump Into Timeline" scene-range menu + scene submenu) had
  **highlights that never armed** — nav_pci promotes at `STC >= hli_s_ptm` but av_sync's
  STC is anchored on the demux parse-front (not the screen) and a keep_vbuf hop doesn't
  re-anchor it, so the compare is permanently not-due. nav_pci now takes `video_live` +
  promotes a waiting armed HLI (visible coli `sel=444405ad`) after ~1 s of video-live so
  it ALWAYS appears; STC path kept for Matrix finite windows (`nav_pci_tb` T7). Residual
  keep_vbuf side effects deferred (documented in `docs/dvd_menu_refinements.md` §1/§2):
  1–2 black frames at the LinkPGCN junction (ps_demux reset + cache clear),
  content-appears-late (VBUF-lag: decoder plays the accumulated tail before the settled
  still), highlight-sometimes-early (STC-past-s_ptm).
  **Tail-drain amendment ✅ HW-CONFIRMED 2026-07-30 (user report, PR fj#149):** a NATURAL title-domain PGC end (FP logo chains, end-of-title → menu) used
  to lose its last ~1 s to the `keep_vbuf=0` jump flush; the reader now waits for
  `vbuf_empty` (~5 s `DRAIN_WD` watchdog) before dispatching `vm_pgc_end`, so the clip
  plays out fully. User jumps/seeks stay immediate; menu paths unchanged. See
  `docs/dvd_nav.md` "Natural-transition tail drain".
  **Tail-drain Phase B ✅ HW-CONFIRMED + MERGED 2026-07-31 (PR fj#150):** title-domain
  CELL-COMMAND jump/seek verdicts (Thayer's Quest FMV branch
  points) now tail-drain too. The VM exports `vm_from_wait` provenance
  (= `wait_verdict && nat_src` — `nat_src` tracks WHO STARTED the chain, set only by
  `ev_cellcmd`/`ev_pgcend`; ★ HW round 1 proved blk-only provenance wrong: Tomb
  Raider's Select skip = button `LinkTailPGC`→POST, whose jump read BLK_POST and got
  tail-drain-gated for seconds — `nat_src` keeps every user-started chain immediate;
  every V_IDLE event arm also forces `blk<=BLK_BTN`), the reader gates `jump_go`/`seek_jump` on
  `vbuf_empty`/`DRAIN_WD` for natural title requests (dispatch stays ungated —
  `vm_adv` cell commands never hitch), freezes `vmw_tmr` while gated, and feeds
  `nat_wait_o` back to `dvd_vm.wait_hold` to freeze the V_WAIT give-up timer
  (else `skip_pre`/`tt_resolve` corrupt mid-drain). HW: TR Select scene-skip
  immediate (the round-2 fix), Thayer unchanged — EXPECTED (its choice cells are
  timed stills = already drained; the gate covers no-still branch cells).
  Detail + a known pre-existing `JumpSS_VTSM vts=0` quirk: `docs/dvd_nav.md` "Phase B".
  **★★ HW ROUND 5 — ✅ HIGHLIGHTS FIXED + CONFIRMED (2026-07-08, PR fj#84 merged).** The real
  blocker (found by MEASURING SPU sizes, not guessing): `spu_decode`'s SPU buffer was **8 KB**
  (`SPU_CAP=8192`, 13-bit addrs), but menu subpictures are large (T2 root 2.8 KB=fit→worked;
  mission-profiles 8.6 KB, scene-range 23.9 KB=overflow). The DCSQ sits at the SPU's END, so a
  small cap dropped it and `rd_ptr<=dcsqt_sa[12:0]` truncated its offset → never committed →
  no subpicture → no highlight (which is why every downstream fix did nothing). Fix: SPU_CAP
  8 KB→32 KB + 15-bit addresses (RAM 69%→74%, fits). **Mission Profiles + scene-range
  highlights now render on HW.** Diagnostic that cracked it: O[2] on-screen blocks
  (armed/video_live/subpic-shown/SPU-arrival) + `tools/spu_ref.py` SPU→PNG dump. The round-4/5/6
  fixes (menu_mode visible-window bypass, `sp_track=0` for menus, `video_live` fallback) were
  correct-but-insufficient alone and remain in place. **★ OPEN follow-up = VBUF LAG (new
  session):** the decoder trails the parse by the buffered depth (keep_vbuf), so menus don't
  reach the settled still — scene-range NUMBERS (baked video, cell-0 I-frame) missing on the
  deep first-entry path, mission-profile slide-load flashes, Matrix/MiB scene-page images lag
  ~2–3 s behind the highlight. Fix direction: flush-and-re-decode the still cell on the
  menu-still park (or bound the menu VBUF lead). See `docs/dvd_menu_refinements.md` §5.
- ✅ **TRANSPORT HUD Phase 11 — HW-CONFIRMED 2026-07-10 (PR fj#103)** (release build
  gated green: clk_dec 91.07/88.12 MHz, ALM 90%, DSP unchanged 97/112;
  `releases/DVD_hud_20260710_1955.rbf`). The release-visible playback feedback layer (the multi-row debug
  overlay stays compiled out): `dvd/transport_hud.sv` renders a bottom **status line**
  (`► 0:12:34/1:37:05 CH 12/23`; ❚❚ pause; `►►×n` scrub with the PR-fj#101 span-relative
  tiers) + an **event popup line** (`AUDIO 2/4 FR` / `SUB OFF` / `ANGLE 2/3` / `CH n/N`,
  last-event-wins, Phase-10 `attr_*` languages) from a generated glyph ROM
  (`tools/hud_font.py` → `dvd/hud_font.mem`) + 2×32 text plane; **`dvd/seek_bar.sv`**
  gives the seek-on-release scrub its missing feedback (fill = hold start, amber cursor =
  release target vs the title RBN span) and pops on pause/seek/chapter with the live
  playhead + chapter-tick notches (stretch, severable). New **B9 "Display"** button
  toggles a persistent status line; auto-show 2.5 s on events; hidden in menus.
  Whole-title elapsed = the reader's per-cell BCD prefix sum (+ new `cur_pgm` query walk)
  (+) DSI `c_eltm` via `dvd/bcd_time_add.sv` (rate-aware frame carry, 508 vectors green).
  **Hotspot discipline:** all formatting/division at event rate; display path = (x,y)-pure
  registered pipelines priority-muxed into the ONE existing `subpic_blend` register stage
  (0 new DSP; field-order per-pixel identity proven in sim = CRT-480i safe; HDMI-480i O9
  half-width caveat = subtitle parity). Tests: transport_hud_tb (12 scenarios, text-plane
  ASCII decode), hud_frame_tb (PPM frame + interlace proof), seek_bar_tb (divider/ticks/
  popup), bcd_time_add_tb, extended iso_reader_chapter_tb; all reader/nav/demux/av_sync
  suites + real-VOB ps_chain green. Design + HW-gate checklist: **`docs/transport_hud.md`**.
- ✅ Multi-angle (Phase 9): HW-CONFIRMED 2026-07-10 (PR fj#98, MiB title 13 five-angle B6
  cycle). Timed/heuristic stills: HW-CONFIRMED 2026-07-10 (PR fj#90).
- ❌ DVD-specific remaining: chapters/PTT exactness (Phase 6: VTS_PTT_SRPT), menu audio,
  no UDF-only-image support. (Phase-8b TMAP absolute seek: RETIRED 2026-07-10 by user
  decision — the shipped seek UX is final.)

---

## Key Architectural Decisions

### Why FPGA for video, HPS for audio?
The HPS is an 800MHz dual-core ARM Cortex-A9. When a core runs, one CPU core is
at ~100% handling MiSTer framework I/O. The remaining core cannot do real-time
MPEG-2 video decode (too slow — even ARM chips in the DVD era needed hardware assist).
AC-3/DTS audio decode (liba52/libdca) uses ~3–5% of one core at 48kHz — totally fine.

### Audio output strategy (Option 3: dual-path)
- **HDMI:** Stereo PCM downmix decoded on HPS (liba52/libdca) → ALSA dummy device →
  auto-mixed into MiSTer's HDMI audio output. Works on any TV, no extra hardware.
- **S/PDIF (future):** IEC 61937 bitstream passthrough over optical S/PDIF.
  **Not exclusive to the Digital I/O board** — the framework drives its `spdif` net to
  both `AUDIO_SPDIF` (Digital board TOSLINK) *and* `SDCD_SPDIF` (`PIN_AH7`), the latter
  being the **Analog I/O board's combo 3.5mm mini-TOSLINK** optical out. The real blocker
  is format, not the connector: the framework's `audio_out` only emits **PCM** S/PDIF, so
  passthrough needs our own `iec61937_wrap.sv` framing the *undecoded* AC-3/DTS frames
  (already available pre-decode at `ps_demux → audio_ring`) + driving the S/PDIF pin
  directly with the IEC 60958 non-PCM bit set. Design `iec61937_wrap.sv` now; targets
  whichever board has a populated optical transmitter. See `docs/audio.md` "Path B".

### CSS encryption
Handled entirely on HPS using **libdvdcss**. Replace raw `open()`/`read()` sector calls
with `dvdcss_open()` / `dvdcss_read(DVDCSS_READ_DECRYPT)`. The FPGA never sees
encrypted data. Works on ISO files, not just physical drives.

**CSS-encrypted ISO detect + warn + audio mute — ✅ MERGED + HW-CONFIRMED
2026-08-06 (PR fj#160).** A raw (undecrypted) rip
green-screens with loud audio static (FAIRYTOPIA.iso was the motivating case —
~19% of packs still scrambled; VLC plays it only because libdvdcss decrypts on
the fly). The core now detects `PES_scrambling_control != 0` in `ps_demux`
(`pes_scrambled` pulse), latches sticky `css_scrambled` in emu (4-pulse
threshold; survives jumps — ps_demux resets per-jump via pipe_rst_n; clears on
fresh mount only), shows a **persistent `CSS ENCRYPTED` HUD popup** (visible in
menus too, yields to user popups then re-arms), and **mutes both audio paths**
(decode: `AUDIO_L/R`=0; passthrough: `iec61937_wrap.mute_i` = PCM-silence bursts
that still drain the ring — no STD wedge). Video keeps playing so the disc is
identifiable. Sim: `ps_demux_scram_tb`, `iec61937_wrap_tb` T8, `transport_hud_tb`
T13. Detail: `docs/fabric_audio.md` "CSS mute", `docs/transport_hud.md`.

### No USB DVD-ROM drive support
MiSTer's custom Linux kernel almost certainly lacks `sr_mod` (`CONFIG_BLK_DEV_SR`).
Recompiling the kernel is out of scope. Workflow: rip disc to ISO on PC, copy to SD card,
play from ISO. libdvdcss handles CSS decryption transparently on ISO files.

### ISO-based workflow
User places `.iso` files on the SD card. HPS opens ISO with libdvdcss, parses UDF,
navigates IFO, reads VOB sectors, feeds decrypted data to FPGA ring buffer.

**Test ISOs live in `$DVD_ISO_DIR/`** (decrypted DVD-Video rips, on the dev
machine — used for `tools/nav_extract.py`, `tools/spu_dump_iso.py`, etc.). Current set:
`MEN_IN_BLACK.iso`, `THE_MATRIX_16X9LB_N_AMERICA.ISO`, `ULTIMATE_T2.iso`,
`PAW_PATROL_MEET_EVEREST.iso`, `SCENEIT_HP.iso`/`SCENEIT_JR.iso`/`Scene_It.iso`.

---

## Audio Codec Support Plan

| Codec | Substream ID (PES) | HPS decode library | HDMI out | S/PDIF (future) |
|-------|-------------------|--------------------|----------|-----------------|
| AC-3 (Dolby Digital) | 0x80–0x87 | liba52 | ✅ stereo PCM | IEC 61937-3, Pc=0x0001 |
| DTS | 0x88–0x8F | libdca | ✅ stereo PCM | IEC 61937-5, Pc=0x000B |
| LPCM | 0xA0–0xA7 | none (raw PCM) | ✅ direct | N/A |

DTS support is essentially free once AC-3 works — same IEC 61937 wrapper, different
preamble constant and library. Always detect substream ID before routing audio PES.

---

## First Task: ps_demux.sv

The Program Stream demuxer is the first new RTL module to write. It sits between
`mpg_streamer.sv` (which feeds raw VOB sectors) and the existing MPEG-2 decoder.

It must:
1. Parse MPEG-2 Program Stream pack headers (start code `0x000001BA`)
2. Parse PES packet headers, extract `stream_id` and `substream_id`
3. Route video PES (`stream_id = 0xE0`) to the existing MPEG-2 decoder input
4. Route audio PES (`stream_id = 0xBD`) to the audio ring buffer for HPS pickup
5. Extract and pass through PTS timestamps for A/V sync

Write a testbench (`bench/dvd/ps_demux_tb.sv`) using a real VOB hex extract before
testing on hardware. A VOB file can be hex-dumped with `xxd VIDEO_TS/VTS_01_1.VOB | head -200`.

### Status & design decisions (implemented)

The FSM in `dvd/ps_demux.sv` is implemented and passes `bench/dvd/ps_demux_tb.sv` in
Icarus Verilog. It is now wired into the pipeline via `dvd/emu.sv`
(`mpg_streamer → ps_stream_fifo → ps_demux → mpeg2video`); the `dvd/ps_stream_fifo.sv`
adapter bridges `mpg_streamer`'s pulse (valid+busy) interface to `ps_demux`'s held
(valid+ready) handshake without dropping the in-flight byte. Integration is covered by
`bench/dvd/ps_chain_tb.sv`. Decisions baked in (full detail in `docs/architecture.md`):

- **Pack header is variable length:** 9 fixed bytes after `0xBA`, then a stuffing-length
  byte (low 3 bits) and that many stuffing bytes — not a flat 14.
- **private_stream_1 sub-header is stripped:** drop `substream_id` + 3 bytes (AC-3/DTS) or
  + 6 bytes (LPCM) so the HPS gets raw frames; `aud_frame_start` strobes each frame's first
  byte.
- **`aud_type` is 2-bit:** 0=AC-3, 1=DTS, 2=LPCM, 3=unknown (the 4-bit width in early docs
  is superseded).
- **Backpressure-safe 1:1 passthrough:** `in_ready` follows the active output's ready;
  counters/shift-register advance only on `in_valid && in_ready`.
- **`PES_packet_length` is the master byte counter** for each packet. Known limitation:
  `length == 0` (unbounded video PES) is not yet handled — OK for DVD VOBs, fix later via
  start-code-hunt fallback.
- **Raw elementary streams are auto-detected and passed through.** If the first start code
  is a video-layer code (`<= 0xB8`, e.g. `0xB3` sequence header) rather than a `0xBA` pack,
  `ps_demux` reconstructs the `00 00 01 <code>` preamble and forwards every byte to video
  (`S_ES_EMIT`→`S_ES_PASS`). This was the black-screen bring-up fix — on hardware all test
  files (`tools/streams/*.mpg`, ffmpeg `.m2v` extracts) were bare elementary streams the
  original PS-only demuxer discarded, starving the decoder. Tested by
  `bench/dvd/ps_demux_es_tb.sv`.
- **DVD nav/system packs are skipped by length (real-VOB robustness).** Any `stream_id
  >= 0xBB` that isn't pack/video/audio — esp. `private_stream_2`/NV_PCK nav packs (`0xBF`)
  and padding (`0xBE`) — is consumed in full via its 2-byte `PES_packet_length`
  (`S_SYS_LEN_HI/LO`→`S_DISCARD`) instead of being hunted past, so a `00 00 01` byte pattern
  inside a nav payload can't false-trigger a start code and desync the stream. Also added
  `VOB` to the `CONF_STR` extension list so `.VOB` files are directly selectable. Tested by
  `bench/dvd/ps_demux_nav_tb.sv`; the real-Matrix-VOB `ps_chain_tb` still passes (50,395 B).
  ⚠️ Sim-verified only — not yet confirmed on a real multiplexed VOB on hardware.
- **On-screen debug overlay** (`dvd/debug_overlay.sv`, `O2,Debug Overlay` toggle, default
  off) renders pipeline counters as on-screen block-bit rows — used to diagnose the above
  with no UART cable. **⚠️ COMPILED OUT of the release build** (`` `ifdef DEBUG_OVERLAY ``,
  congestion — see the "On-hardware diagnostics" note above): `O[2]` only shows these rows in
  a `DEBUG_OVERLAY` rebuild. In a release `.rbf`, `O[2]` drives the menu-highlight blocks.

## audio_ring.sv — Status & design decisions (implemented, sim-verified)

`dvd/audio_ring.sv` is the consumer for `ps_demux`'s audio output — a buffer that
holds complete audio frames for the HPS to pull out later (decode AC-3/DTS via
liba52/libdca, or pass LPCM, → ALSA → HDMI). Passes `bench/dvd/audio_ring_tb.sv`
in Icarus. **Built but NOT yet wired into `emu.sv`** (the audio outputs there stay
parked with `aud_ready=1'b1`); wiring it in + the HPS read path are the next steps.

- **Single-clock (clk_sys), no CDC.** The chosen HPS read transport is the
  MiSTer `ioctl_upload` channel, which runs in the clk_sys (27 MHz) domain — the
  same domain as `ps_demux`. So this is a plain single-clock FIFO, *not* the
  dual-clock FIFO the early docs assumed for an f2sdram path.
- **FLOW CONTROL — watchdog-guarded demux backpressure (revised 2026-07-02; the
  old "never backpressure into video" HARD INVARIANT is relaxed).** `ps_demux`
  carries video AND audio on one byte stream. The ring's own `aud_ready` output
  stays tied HIGH (accept-always; on overflow it **drops a whole frame** —
  rewinds bytes, bumps `overflow_count` — keeping boundaries intact), but it now
  also exports **`almost_full`**, and `emu.sv` gates `ps_demux.aud_ready` with
  it: when the ring is nearly full the shared demux STREAM stalls until the
  audio decoder drains (the DVD System-Target-Decoder model). The video PICTURE
  is unaffected — the video decoder rides its multi-MB VBUF bitstream backlog
  through the stall. Why: an overflow drop is a whole AC-3 frame = an audible
  32 ms gap (the low-fps audio "stutter"); backpressure loses nothing. Guard: a
  ~1.2 s drain watchdog in `emu.sv` (armed by `frame_pop`) — audio muted (O5) /
  wedged decoder → backpressure released, reverting to drop-on-full, so the
  stream can never wedge video. The 48 kHz audio NCO stays untouched (same
  crystal as the raster + exact governor cadence ⇒ no drift to correct).
- **Two coupled FIFOs:** a byte ring (`BYTE_DEPTH`, default 8192) + a
  frame-descriptor ring (`FRAME_DEPTH`, default 64) of `{length[15:0], type[1:0]}`,
  one per *completed* frame. HPS pops a descriptor, then reads `frame_len` bytes.
  Both depths must be powers of two (pointers wrap naturally).
- **Committed vs in-progress:** `avail` = readable committed bytes, `fill` = all
  physical bytes. In-progress (or dropped) frame bytes sit ahead of the readable
  region and can never leak to the HPS.
- **LENGTH-DEFERRED FINALIZE (known limitation):** a frame's length is only known
  at the *next* `aud_frame_start`, so frame N commits when frame N+1 starts. The
  trailing frame isn't finalized until another starts — fine for continuous
  playback; a future flush/timeout input can finalize a lone last frame.
- **`aud_pts` not stored yet** (A/V sync is a later phase) — `ps_demux` PTS
  outputs stay parked.

### ⚠️ Debug-overlay gotcha: `watchdog_rst` is ACTIVE-LOW

When reading the **flag row (row 4)**, the watchdog cell (`[5]`) is special: the decoder's
`watchdog_rst` (`rtl/mpeg2/watchdog.v`) is **active-LOW** — it sits HIGH in normal operation
and only pulses LOW for one cycle if the watchdog actually expires. So a raw "green = signal
high" reading is BACKWARDS: green-on-the-raw-signal = NORMAL, not "firing." (This has bitten
multiple sessions.) The overlay now feeds cell `[5]` the **inverted/expiry** sense (`~watchdog_rst`
captured sticky-per-frame), so **green on the watchdog cell = the watchdog FIRED this frame
(BAD), red = healthy.** If you ever see watchdog code/overlay, double-check the polarity before
concluding "the decoder is hanging." The same caution applies to any active-low signal shown as
a flag.

---

## VS Code Settings

```json
{
    "verilog.linting.linter": "iverilog",
    "verilog.linting.iverilog.arguments": "-g2012",
    "files.associations": {
        "*.v": "verilog",
        "*.sv": "systemverilog",
        "*.svh": "systemverilog"
    }
}
```

Recommended extensions: `mshr-h.verilog`, `teros-technology.teroshdl`, `ms-vscode.cpptools`, `eamodio.gitlens`

---

## Simulation Quick Reference

```bash
# Simulate ps_demux module
iverilog -g2012 -o bench/dvd/ps_demux_sim \
    dvd/ps_demux.sv bench/dvd/ps_demux_tb.sv
vvp bench/dvd/ps_demux_sim

# Simulate audio_ring module
iverilog -g2012 -o bench/dvd/audio_ring_sim \
    dvd/audio_ring.sv bench/dvd/audio_ring_tb.sv
vvp bench/dvd/audio_ring_sim

# Full Quartus compile (from project root). The Quartus revision is `DVD`,
# so the output is output_files/DVD.sof
quartus_sh --flow compile DVD
```

---

## Building a MiSTer-loadable core (`.sof` → `.rbf`)

**Use `./build_release.sh` — do not call `quartus_cpf` bare.** MiSTer's HPS FPGA
loader requires a **compressed** Raw Binary File. A plain
`quartus_cpf -c x.sof x.rbf` produces an **uncompressed** bitstream (~7 MB) that
silently fails to configure the FPGA: the core "loads" but gives **no video on
either HDMI or the analog board** (no signal at all, not garbled — a dead
giveaway for a bad pack). A correct compressed `.rbf` for this device is
*4.2 MB**.

```bash
./build_release.sh                 # pack existing .sof -> releases/<name>_<date>.rbf
./build_release.sh --compile       # run the full Quartus compile first, then pack
./build_release.sh --name DVD_foo  # override the release base name
```

**★ Always name builds uniquely (`--name`).** Every build MUST get a distinct,
descriptive `--name DVD_<feature>` tied to the feature/branch (e.g.
`--compile --name DVD_ilauto`) — never leave the generic default, which produces a
meaningless name like `DVD_ps_demux_<date>.rbf` that collides across features and can't be
told apart on the SD card. The date/time suffix is appended automatically.

The script always passes `-o bitstream_compression=on` and warns if the output
exceeds ~4 MB. Copy the resulting `releases/*.rbf` to the SD card to load it.

> **Always build after completing a requested feature.** When an RTL/feature change is
> finished (committed, PR opened), run `./build_release.sh --compile` to produce a fresh
> loadable `.rbf` so it's ready to flash and HW-test — don't leave the user to trigger the
> build. (Long-running Quartus compile: kick it off in the background and report the result.)

**Timing note:** this baseline does not formally close timing — large negative
slack appears on Altera PLL-reconfig / HPS-bridge paths (`~PLL_OUTPUT_COUNTER|divclk`,
`h2f_*`, `pll_audio`). These are infrastructure paths every MiSTer core reports
and are shared with the known-working `releases/*.rbf`; they are not the
functional video datapath. Validate empirically (does video play?), not by
chasing TimeQuest to zero.

---

## References

See `docs/references.md` for full list. Key links:
- Upstream repo: https://github.com/mrchrisster/MiSTer_MPEG2
- MiSTer Template: https://github.com/MiSTer-devel/Template_MiSTer
- MiSTer hps_io docs: https://mister-devel.github.io/MkDocs_MiSTer/developer/hps_io/
- libdvdcss API: https://www.videolan.org/developers/libdvdcss/doc/html/dvdcss_8h.html
- MiSTer forum DVD thread: https://misterfpga.org/viewtopic.php?t=2146

Audio (in-fabric AC-3 + LPCM): `docs/fabric_audio.md`. The AC-3 decoder (`dvd/ac3/*`,
ported from the now-archived `MiSTer_AC3` repo) has its own scope/verification/decisions
reference in `docs/ac3_decoder.md` and module/interface/fixed-point contract in
`docs/ac3_decoder_architecture.md`.


## Source control

**This repository is PUBLIC.** Everything pushed — code, comments, docs, commit messages,
PR titles and descriptions — is visible to anyone, permanently, and is not meaningfully
undone by a later commit. The publishing rules below exist because of that, and they
override the default instinct to push early and open a PR as soon as a branch exists.

- **Never commit directly to `main`.** If `main` is checked out when a feature is requested, automatically create a feature branch (e.g. `feature/<short-description>`) before writing any code.
- **Never push a branch or open a PR until explicitly asked to.** Work locally and commit
  freely; a feature branch is a private workspace until its author decides otherwise.
  Experimental and dead-end branches must not reach the public remote at all. Do not
  "helpfully" push at the end of a task, and do not treat finishing the work, a green
  build, or a passing test as permission. Say the branch is ready and stop.
- **If asked to merge a branch that has not been published, do the missing steps first**,
  in order: push the branch, open the PR, then merge it. A merge request is authorisation
  to publish that branch; it is not retroactive authorisation for anything else.
- Use PRs to merge feature branches into `main`.
- Commit often — after each logical, self-contained change (not just at the end of a task).
- Write clear, descriptive commit messages that explain *what* changed and *why*.

### ★ Never publish personal or workstation-specific information

Applies to **everything that lands in the repository or on the remote**: RTL, scripts,
docs, `.gitignore`, commit messages, and PR text alike.

Never write:

- **Absolute paths from a development machine** — `/home/<user>/...`, `C:\Users\...`,
  `/Users/...`, or any path that only resolves on one workstation.
- **Host, user, or account identifiers** — usernames, hostnames, e-mail addresses,
  self-hosted service URLs, VPN or LAN addresses, SMB/NFS share names, serial numbers.
- **Private infrastructure detail** — internal repo URLs, CI endpoints, home-network
  layout, or anything describing where a machine sits rather than how the code works.

Write instead:

- **Paths relative to the repository root** — `tools/css_scan.py`, `docs/dvd_nav.md`,
  `bench/dvd/test_vobs/`. Scripts resolve their own location rather than assuming a cwd
  (see `build_release.sh` and `tools/seed_sweep.sh` for the pattern).
- **Environment variables with generic fallbacks** for anything outside the repository —
  disc images, external checkouts, capture files. `${DVD_ISO_DIR:-~/dvd-isos}`, not one
  person's library path. Document the variable; do not hardcode a default that only works
  on one machine.
- **Generic placeholders** in examples — `/dev/sr0`, `<disc>.iso`, `<user>/<repo>`.

Two failure modes worth naming, because both happened here:

1. A hardcoded `cd` to one developer's checkout in `tools/seed_sweep.sh` made the script
   fail immediately for everyone else — a functional break, not cosmetic, and it sat in
   the one script a contributor reaches for when a fit comes in marginal.
2. Absolute media paths spread into ten files as *documentation*, where they read as
   authoritative and quietly told every reader to look somewhere that does not exist.

When a real local path is genuinely needed to reproduce a past result, describe it
generically ("the local ISO library") rather than reproducing it.

### Opening a PR after every feature branch

**Only when explicitly asked** (see the rule above — finishing the work is not a cue).
Push the branch first, then open the PR. The remote is **GitHub** — use the `gh` CLI
(authenticated):

```bash
gh pr create --title "<title>" --base main --head <branch> --body-file /tmp/pr_body.md
```

Include a short summary and a markdown test plan checklist in the body. Present the
returned PR URL to the user. Write the body to a file rather than passing `--body` inline —
long markdown with backticks and checklists does not survive shell quoting reliably.

### Merging a PR

```bash
gh pr merge <number> --merge        # or --squash / --rebase
```

### Updating a PR description

```bash
gh pr edit <number> --body-file /tmp/pr_body.md
```

To read a PR's current body back (e.g. to tick test-plan checkboxes):

```bash
gh pr view <number> --json body -q .body
```

### ⚠ Historical `fj#NN` references — do not "fix" them

This project developed in a private **Forgejo** repository before moving to GitHub, and
`docs/` cites those PRs heavily. GitHub numbering restarts at 1, so a bare
`#84` would eventually point at an unrelated GitHub PR — a reference that looks right and
is wrong, which is exactly the class of documentation bug the rules above exist to prevent.

Every historical reference is therefore written **`fj#NN`** (and `issue fj#NN`). These are
Forgejo numbers and have no GitHub equivalent. Leave them alone; do not renumber them, and
do not strip the prefix. New PRs opened on GitHub use plain `#NN` as normal — the two
namespaces are distinguishable on sight and that is the whole point.

The Forgejo history was not migrated: the public repository starts from an upstream-import
commit plus the accumulated work. Commit SHAs quoted in `docs/` likewise refer to the
pre-migration history and will not resolve here.
