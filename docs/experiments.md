# Experiments / Speculative Ideas

A parking lot for ideas that are **not committed roadmap items** — things that might be
interesting to try but haven't been decided on (unproven value, uncertain cost, or just
"maybe someday"). Committed/planned work lives in `docs/roadmap.md`; this file is for the
maybes. Move an item to the roadmap once it's decided, or delete it if ruled out.

Format: each entry has the idea, why it might be worth it, the rough approach, the main
risk/cost, and a status. Keep the technical reasoning so a later session doesn't re-derive.

---

## Decoupled analog (CRT) vs HDMI framing

**Idea:** let the analog CRT output show a cropped/pan-scanned 16:9 image while the HDMI
output simultaneously shows the full (uncropped) frame — i.e. different framing per output
at the same time, instead of both mirroring one raster.

**Why it might be worth it:** if you run a CRT (analog) as the primary display and an HDMI
display as a secondary/recording output, you could have the CRT correctly pan-scanned (the
`Crop` mode) while HDMI keeps the whole 16:9 frame.

**Why it's not trivial (the plumbing):** the core produces ONE raster (mixer → `VGA_*`) and
`sys_top` fans that single signal out to both outputs. Today's `Crop`/`Letterbox` happen
*before* that split (in `dvd/disp_hstretch.sv` / `dvd/resample_addrgen.v`), so they're baked
into the shared raster and both outputs mirror them pixel-for-pixel. The framework does give
**HDMI its own scaler** (ascal + `VIDEO_ARX/ARY`), but the **analog path has none** — in CRT
mode (`VGA_SCALER=0`) it's a native passthrough of the core raster. So the only asymmetry
that exists out of the box is the *opposite* of what's wanted: HDMI can be corrected
independently (scale/letterbox), analog cannot; and ascal can letterbox a full frame but
cannot *un-crop* a cropped one.

**Rough approach (if pursued):** leave the core in **Fit** (full frame). HDMI then already
shows correct full 16:9 via `O[20:19] Aspect Ratio = 16:9` (ascal + ARX). Add a **new
horizontal crop+stretch stage on the ANALOG-only branch in `sys_top`** (after the
core→HDMI/analog split), gated on CRT + a "crop analog" mode. Because the post-mixer analog
stream is raw pixels + syncs (no `position` codes), this is a small *raster-domain*
horizontal scaler (crop centre ¾, stretch to full width using `h_pos`/`pixel_en`), not the
stream-repeater trick `disp_hstretch` uses. Net: HDMI = full 16:9 (ascal+ARX), analog =
cropped.

**Risk / cost:** edits upstream `sys/` (which the project deliberately avoids — see CLAUDE.md),
re-implements the stretch in a new place, and adds logic to an already ~88%-full,
routing-flaky device (the fit/fringe lottery — see memories `quartus-build-flaky-routing`,
`chroma-edge-fringe-is-upsample-mode`). Fairly niche benefit (two displays, different
framings, live at once).

**Cheaper alternative (no code):** just pick the core mode per what you're watching — `Crop`
when on the CRT, `Fit` + `Aspect Ratio 16:9` when you care about HDMI.

**Status:** idea only (2026-07-05), raised after `Crop` was HW-confirmed. Not scheduled.

---

## VCD / SVCD playback (spin-off or mode)

> **★ 2026-08-24: DELIVERED as a mode of this core** (`feature/vcd-svcd-playback`,
> `docs/vcd_svcd.md`): MPEG-1 video + MP2 landed earlier (`docs/mpeg1.md`), and
> bin/cue raw-sector deblocking, MPEG-1 system-stream demux, the 44.1 kHz output
> rate, SVCD 480-wide analog fill, and linear seek/pause are all in. The `.DAT →
> .mpg` PC-side extraction this section assumes is no longer needed — the core
> reads the data-track `.bin` directly. The section below is kept as the original
> delta analysis; its "not scheduled / spin-off" framing is historical.

**Idea:** play Video CD (VCD) and Super Video CD (SVCD) rips, either as a separate spin-off
core or as an added mode of this one.

**Why it might be worth it:** it reuses almost the whole existing pipeline (frame store,
IDCT, motion comp, display/scaler, `ps_demux`), and — unlike DVD — **VCDs have no copy
protection** (no CSS/DRM; the MPEG-1 sits in the clear in `MPEGAV/*.DAT`). So there's *no
decryption step at all*: rip `.DAT → .mpg` on a PC with a VCD-aware tool (ffmpeg reads VCD
directly; the only nuance is the `.DAT` files are CD-ROM **Mode 2 Form 2** 2324-byte sectors,
so a plain file copy can be dirty — ffmpeg/`vcdimager`/VCDGear extract a clean stream), copy
to SD, play. Content is a plain MPEG-1 (VCD) or MPEG-2 (SVCD) Program/System stream.

**What's actually needed (three pieces):**

1. **Video decode.**
   - **SVCD is already covered** — it's **MPEG-2** (480×480), so it decodes on the *current*
     video path as-is. SVCD only needs the audio + demux work below.
   - **VCD needs MPEG-1 video, which the decoder does NOT do today.** Evidence in
     `rtl/mpeg2/vld.v`: picture/slice decode is gated on `sequence_header_seen &
     sequence_extension_seen` (lines ~551/584) — MPEG-1 has no sequence extension, so a pure
     MPEG-1 stream parses the sequence header then stalls, never decoding a picture. And the
     MPEG-1 picture-header motion fields (`full_pel_forward_vector`/`forward_f_code`, backward)
     are *parsed but never consumed* — motion sizing uses only the MPEG-2 extension f_codes
     (`f_code_00…`, vld.v ~1385); there's no `full_pel` (integer-pel MV ×2) path. D-pictures
     are `$display` stubs (not needed for VCD).
   - **MPEG-1 work = moderate & contained** (heavy datapath is shared): add an `mpeg1` flag
     (sequence header seen, no extension) to relax the two gates; supply the missing
     "extension" context as MPEG-1 defaults (progressive frame, 4:2:0, FRAME structure, frame
     pred/DCT, `intra_vlc_format=0`, zigzag scan); route motion from the picture-header f_codes
     with `full_pel` ×2 scaling. Risk is in those details (full_pel, defaults) → needs testing
     vs real VCD clips. VCD is 352×240/288 @ ~1.15 Mbps CBR — far under the compute ceiling, so
     no throughput/stutter concerns.

2. **MP2 (MPEG-1 Audio Layer II) decode — the real new module.** The in-fabric **AC-3 decoder
   (`dvd/ac3/*`) does NOT help** — MP2 is a different codec (subband polyphase filterbank).
   **DSP cost is small if serialized**, which is the natural choice: audio is ~44.1 kHz against
   the 27 MHz `clk_sys` (~600× headroom), so the 32-subband synthesis filterbank + windowing
   time-multiplex onto ~1–4 DSP MACs — it does **not** blow the DSP budget (last fit: 94/112 =
   84 %, 18 free). The binding constraint on this design is **ALMs/routing**, not DSP, and audio
   decode sits **off the congested decoder→overlay display hotspot** (like the AC-3 path), so it
   costs ALMs elsewhere without worsening the fit lottery. Could ship **video-only first**.

3. **Demux/stream handling.** VCD/SVCD are MPEG-1/2 **System** streams. Video is `stream_id`
   `0xE0` (already routed by `ps_demux`), but **audio is `0xC0`** (MPEG audio), *not* the DVD
   `0xBD` private_stream_1 `ps_demux` routes today. So add `0xC0`→audio routing + MPEG-1 PES
   header parsing (the MPEG-1 PES optional-fields layout differs from MPEG-2). The
   `dvd_iso_reader` ISO nav isn't used (a VCD rip is a flat `.mpg` → the linear flat-file
   streaming path).

**Separate core vs mode:** a **separate VCD/SVCD core** would DROP the AC-3 decoder and the
DVD nav, freeing lots of ALM/DSP headroom (VCD needs only MPEG-1 video + MP2). Folding it into
*this* core keeps one binary but stacks MP2 on top of AC-3 (still fits DSP-wise; watch ALMs).
See **[`vcd_svcd_mpeg_reuse.md`](vcd_svcd_mpeg_reuse.md)** for the fuller treatment: an eval of
the [`CDi_MiSTer`](https://github.com/MiSTer-devel/CDi_MiSTer) MPEG-1/MP2 decoders as reference
(a RISC-V+firmware hybrid — don't import the soft CPU), the fabric-fit numbers, and the key
organization decision — **share the decoder behind a `` `ifdef MPEG1 `` compile flag and split
at the Quartus *revision* level rather than hard-forking a decoder that's still under active
development**. One measurement (standalone MP2 synth cost) decides single-`.rbf` vs separate core.

**Risk / cost:** MPEG-1 video decode (moderate, needs real-clip validation), a from-scratch MP2
decoder (the main lift), and small `ps_demux` MPEG-1-PES/`0xC0` work. No decryption, no
disc-format grief (rip to `.mpg`).

**Status:** idea only (2026-07-06), raised while discussing a VCD spin-off. Not scheduled.

---

## DVD games & interactive titles (preservation targets)

**Idea:** treat the library of **DVD‑Video games and interactive discs** — not just Scene It —
as a first‑class preservation target for this core, since a MiSTer audience skews heavily toward
game preservation.

**Why it's a strong fit (cheap once the VM works):** almost every "DVD game" is *not* a special
format — it is **plain DVD‑Video authored with the nav VM + `rnd`/GPRM state + menus/branching**.
`dvd/dvd_vm.sv` already implements nearly all of the machinery (see roadmap
"Follow-up idea: interactive DVD games — Optreve engine"). So the marginal cost of supporting
*additional* titles is mostly **verification on real ISOs** plus filling the couple of already‑known
VM gaps (counter‑mode GPRM tick, nav timer SPRM9/NVTMR), not new subsystems. That turns "support
the DVD‑game genre" into a high‑visibility, low‑effort win. The one exception is the FMV/branching
class below, which leans on Phases 7–9 (DSI/seek, seamless branch, multi‑angle) rather than the
trivia‑style VM path.

### A. Laserdisc arcade classics on DVD‑Video — **flagship candidate**

**Dragon's Lair** and **Space Ace** (Don Bluth) were reissued as *playable* **DVD‑Video** games:
gameplay is authored entirely with DVD **multi‑angle + seamless branching + fast seek** (right
move → success branch, wrong move → death branch, all on one timeline). This is the ideal
MiSTer/arcade‑preservation crossover and the strongest stress test of the interactive phases —
it exercises the **DSI/seek + seamless‑branch + angle** path (Phases 7–9), not just menu VM
branching. Recommend as the headline demo disc once Phase 7–9 land.

- **What it needs:** Phase 7 (DSI nav‑pack parse — already the active `feature/nav-dsi-foundation`
  branch), Phase 8 seek/branch, Phase 9 multi‑angle / ILVU chain following. Death/success cuts are
  latency‑sensitive branch jumps → a good real‑world test of seek re‑sync speed.
- **Risk:** timing‑tight branching may expose seek/VBUF‑flush glitches the trivia titles don't.

### B. Purpose‑built DVD adventure games

- **Scourge of Worlds: A D&D Adventure** — a genuine choose‑your‑path DVD‑Video game (combat/route
  choices, branching). Pure VM + menu/branch; validates the interactive path on a **non‑trivia**
  title. Low effort if the VM is solid.

### C. Trivia / board‑game genre — **near‑free once Scene It is confirmed**

All Optreve‑like (same `rnd`/GPRM/menu‑branch pattern as Scene It), so supporting them is chiefly
"decode the ISO, confirm the dispatcher chain runs":

- Rest of the **Scene It** library (Harry Potter, Disney, 007, Star Wars, Music, Sports, TV, …).
- **Trivial Pursuit DVD** (Digital Choice / Genus), **Disney DVD Game World** series,
  **Disney/20Q 20 Questions**, **Wheel of Fortune / Jeopardy / Millionaire / Family Feud** DVD editions.
- **Atmosfear / Nightmare** — cult horror board‑game "Gatekeeper" host DVD; heavy on **timed stills +
  menu audio**, so it doubles as a Phase‑5 (timed‑still/menu‑audio) test with strong preservation appeal.

### D. Mainstream discs as VM/menu regression tests (free test material)

Interactive Easter‑egg games baked into discs people already own — **LOTR Extended Editions**,
*The Matrix* ("follow the white rabbit" branching), etc. Useful, zero‑cost validation of the
menu/VM path on non‑game content.

**Explicitly out of scope:** DVD‑Audio (MLP — different format), and DVD‑ROM "PC game on the disc"
hybrids (need a PC).

**Risk / cost:** mostly verification time on real ISOs + the two known VM gaps. The FMV/branching
class (A/B) is the only part that depends on Phases 7–9 being solid; the trivia class (C/D) rides
the VM that already exists.

**Status:** idea only (2026-07-09), raised while brainstorming preservation‑angle DVD games beyond
Scene It. Not scheduled. Cross‑ref: roadmap "Optreve engine" follow‑up and Phases 7–11.

---

## Other DVD features / fun experiments

**Idea:** a few small, mostly‑covered DVD behaviours that make good demos or exercise existing
subsystems end‑to‑end.

- **Seamless branching / multi‑story playback** — *Clue* (3 endings), *Final Destination 3: Choose
  Their Fate*, branching FMV (*I'm Your Man*). Same DSI/angle machinery as the laserdisc games; a
  fun low‑effort demo once Phase 9 lands.
- **Karaoke DVDs** — lyric **subpicture timing** + **vocal/no‑vocal audio‑track** switching.
  Popular, and a clean end‑to‑end test of subtitle timing + audio‑track selection (Phase 10) with an
  obvious payoff.
- **Music‑video / concert DVDs with angle switching** — natural multi‑angle test content; overlaps
  the existing DTS‑disc note (many concert discs carry DTS + angles).
- **Ambient / screensaver DVDs** (fireplace, aquarium) — trivial, but a nice "it just works"
  showcase of looping menu‑audio stills.

**Risk / cost:** all small; each mainly exercises a subsystem (seamless branch, subtitle timing,
audio‑track mux) that other roadmap work already builds.

**Status:** idea only (2026-07-09), raised alongside the DVD‑games brainstorm. Not scheduled.

---

## Bouncing "DVD" logo idle screen (no‑disc screensaver)

**Idea:** when the core is loaded but **no file is selected yet**, render the classic bouncing
DVD‑logo screensaver (drifts across the screen, changes colour on each edge/corner bounce) as the
idle background, instead of the current black screen behind the OSD.

**Why it might be worth it:** pure delight / on‑theme flourish for a DVD player core, and a
crowd‑pleaser for the "will it hit the corner?" meme. No functional value — it's an idle‑state
cosmetic.

**Is it possible at that point? — yes, in principle.** The core generates a **continuous valid
raster** (syncgen/modeline timing) the whole time it's loaded, even with nothing playing — that's
what the OSD already overlays onto; the idle picture is simply black today. So the hooks exist:

1. **Idle detect.** Gate the effect on "no content yet" — e.g. no file downloaded / streamer not
   started / zero frames decoded. The core already tracks load/stream state, so an `idle` signal is
   cheap to derive; the screensaver runs only while `idle`, and the normal decoder raster takes over
   the instant playback begins.
2. **Sprite render.** A small **logo bitmap in a BRAM/M10K ROM** (1‑bpp mask is plenty), a position
   accumulator with x/y velocity, edge‑bounce logic (flip velocity at the raster bounds), and a
   palette index that advances on each bounce for the colour change. Composite it into the idle
   raster — ideally by **reusing the existing overlay compositor** (`dvd/subpic_blend.sv` /
   `debug_overlay.sv` already prove in‑fabric pixel generation + blend), not a new blender.

**Rough approach:** new tiny `dvd/idle_logo.sv` (ROM + position/velocity/bounce FSM in the raster
clock domain, driven by `h_pos`/`v_pos`/`pixel_en` like the overlay), output blended over black
while `idle`, gated off once the decoder produces its first frame.

**Risk / cost (the real caveats):**
- **It lands in the congested display/overlay hotspot.** The roadmap flags this exact output region
  as routing‑congestion‑marginal *and* the device as approaching the ALM ceiling (see roadmap
  "FPGA congestion / resource cleanup"). The logic is genuinely small (one BRAM + a handful of
  counters), but *where* it goes is the sensitive area — same fit lottery as the fringe/overlay work
  (`quartus-build-flaky-routing`). Do it **after** any pending fabric‑reclaim, and reuse the overlay
  path rather than adding a parallel one.
- **Trademark.** The literal "DVD Video" logo is a licensed mark — ship a **stylised/original
  silhouette** (an homage), not the trademarked artwork.
- Needs a clean `idle` signal that reliably drops the moment real video starts (no logo bleeding over
  frame 1).

**Status: ✅ BUILT (2026-08-26, branch `feature/launch-feedback`) — see `docs/idle_screen.md`,
which supersedes this sketch.** Shipped essentially as outlined above (1-bpp M10K mask,
Q12.4 bounce FSM, reuse of the subpic_blend priority stage, `!media_seen` idle gate,
original artwork) plus a user-replaceable bitmap via the `boot.rom` convention. The
fabric-budget precondition was met by the same branch's reclaim pass (dead mpeg2 OSD
tie-off + dvd_vm mux sharing).
