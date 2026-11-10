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

**Status: ✅ MERGED (PR #9, 2026-08-26) — see `docs/idle_screen.md`,
which supersedes this sketch.** Shipped essentially as outlined above (1-bpp M10K mask,
Q12.4 bounce FSM, reuse of the subpic_blend priority stage, `!media_seen` idle gate,
original artwork) plus a user-replaceable bitmap via the `boot.rom` convention. The
fabric-budget precondition was met by the same branch's reclaim pass (dead mpeg2 OSD
tie-off + dvd_vm mux sharing).

---

## PWM on the 6-bit analog DAC (the "PWM cores" method)

**Idea:** replace or extend `Analog Dither` with the method used by the community PWM builds
of the N64, PSX and Saturn cores (`Jokippo/MiSTer_PWM_Cores`; binaries only, the source is in
the author's N64 fork as `sys/vga_pwm.sv`; forum thread "PWM on 18-bit DAC to get 24-bit
Color", misterfpga.org t=7565). Groovy_MiSTer ships it as standard.

**How it works.** About 20 lines in sys_top. A 2-bit `phase` counts on `clk_vid` and is
cleared during hsync (or csync). Each channel outputs `din[7:2] + (phase < din[1:0])`, held
at 63. Over four clocks the DAC shows the top six bits, plus one for `din[1:0]` of those four
clocks, so the time-average equals the 8-bit value. Algebraically this is **an ordered
dither with thresholds 3, 2, 1, 0 along the line**. It has no line term and no frame term:
every line gets the same ramp.

**Why it works in those cores.** Their `clk_vid` is far faster than the dot clock: the N64
runs 48.68 MHz, 4–8 clocks per pixel. So the whole 4-phase cycle sits inside one pixel, the
modulation lands at ≥12 MHz, and the display's low-pass averages it away. No spatial pattern
is left. That is what earns the name PWM.

**Why it does not transfer here (evaluated 2026-10-06, ruled out at our clock).**
- `CLK_VIDEO` is 27 MHz, 1 clock per pixel on 480p and 2 on 480i/240p. Dropped in as is,
  the method becomes a 4-pixel (480p) or 2-pixel (480i) pattern with the same offset in the
  same columns on every line and every frame, i.e. vertical lines on flat colour.
  `dvd/dac_dither.sv` already does better, with a line term and per-field inversion.
- A forum critic of the PWM builds made the same two points: the hsync-reset counter gives
  vertical lines on solid colours, and a clock that is not a multiple of 4 pixel clocks
  gives errors. The second does not apply to us (27 MHz is exactly 1× or 2× the dot rate);
  the first does.
- **Copying it as is would also skew colour against sync.** `vga_pwm` delays the data by 3–4
  register stages and `VGA_HS` by 1. That is a fraction of a pixel at the N64's clock and
  about 4 pixels on 480p here.
- The critic's real point, a dither whose every line sums to the same value, was taken. It
  exposed that our own 4×4 Bayer matrix's top two bits were a 2×2 pattern that was not exact
  per line. The fix is a Latin-square matrix, HW-confirmed on a CRT: less crosshatching
  (PR #164, `docs/single_raster_analog.md` §8 "The matrix").

**What genuine sub-pixel PWM would take (the open maybe).** A clock faster than the dot
clock, on the DAC word only:
- **54 MHz** divides cleanly from `sys_pll`'s 810 MHz VCO (phase-locked to the 27). That
  gives 4 phases per 480i pixel, the PSX/N64 640-wide condition, but only 2 per 480p pixel.
- **108 MHz** does not divide from 810 MHz. Retuning the VCO moves `clk_dec`/`clk_mem` and
  means a seed re-sweep.
- **A faster `CLK_VIDEO` itself** touches every `clk_vid` consumer in sys_top, including the
  composite subcarrier NCO, whose `PhaseInc` Main derives from the reported pixel clock.
  `dvd/emu.sv` (~6073) records metastability from the last time `CLK_VIDEO` ran at 108 MHz.
- Either way: a new clock domain, a CDC for the 24-bit word, an SDC entry, and fabric at
  ~97 % ALM. It can be combined with the Latin-square dither, which stays as the
  spatial/temporal term.

**Risk / cost:**
- **Unmeasurable with the current rig.** The RetroTINK samples at the dot rate, so
  sub-pixel modulation is invisible to `tools/dither_ab.py`, and only a CRT by eye can judge
  it. Upscalers on the analog port would also need re-clocking to see it (the critic's
  p.s.).
- **54 MHz edges on the resistor-ladder DAC.** Proven at ~50–60 MHz by the PWM builds on
  the same I/O boards, but not at 108 MHz.
- **Little left to gain.** The maintainer judged the 27 MHz Latin-square dither an
  improvement on the CRT.

**Status:** evaluated 2026-10-06. The as-is port was ruled out (weaker than `dac_dither`).
The faster-clock variant is not scheduled; revisit only if the CRT still shows dither
texture worth removing.

---

## Cached thumbnails for the scrub preview

**Idea:** while a held Fast Fwd / Rewind scrub moves its cursor, show a small picture of the
content at the cursor, from a set of thumbnails decoded once per disc and kept in memory.
Today the video freezes and only the seek bar moves (`dvd/scrub_ctrl.sv`).

**Why it is worth it:** the scrub's tiers run at about 15 / 60 / 240 / 960 content-seconds per
second (`docs/transport_hud.md`), so nobody can tell where they are from the clock alone at the
fast end. A thumbnail answers that at every speed, and the release seek stays the one exact
TMAP seek it is now.

**Why cached, not decoded live.** The first answer considered was a live I-frame preview: splice
the I-frame at the cursor into the decoder without flushing, the same engine trick play would
need (`docs/dvd_nav.md` §2d). It is the regime the 2026-07-10 HW rounds proved fatal (flush and
re-lock per hop: black frames, watchdog resyncs), made safe only by never flushing and by
keeping one or two pictures in flight, and it needs its own HW round. Finding the I-frames was
never the problem: `VTS_TMAP` gives each VOBU's address, and the I-frame follows the NAV pack,
ending at `dsi_1stref_ea`. Cached thumbnails avoid the fabric decoder entirely. Trick play at
×2 to ×8 still needs the splice engine; that is a separate feature.

**Rough approach:**
- **Produced by Main, not the fabric.** The fabric decoder has one set of reference frames and
  one display schedule, so a side decode means a second context in upstream `rtl/mpeg2`.
  A low-priority Main thread (CPU 1; the read-ahead worker is on CPU 0, and `user_io_poll()`
  must never block) does, for each grid point: a TMAP lookup, a read of the NAV pack and the
  I-frame, a software decode (libmpeg2 or FFmpeg's), a downscale, and a write into a DDR3 table.
  CSS is already handled by Main's read path.
- **Size:** 160×90 at 4:2:0 is ~22 KB, so one every 10 s of a 2 h film (720) is ~16 MB. Full
  720×480 frames (~518 KB each, ~373 MB) are too much. The FPGA's DDR3 half has room above the
  core's 32 MiB window at `0x30000000` (`docs/audio_ddr_path.md`); pick a fixed region.
- **Saved to the SD card** under the disc ID, as save states are (`savestates/DVD/<disc id>_N.ss`),
  so a disc is indexed once and later loads are instant. Coarse grid first (one a minute),
  then fill to every 10 s, nearest the playback position first. Unindexed stretches scrub as
  today, cursor only.
- **Shown in a box above the seek bar** at the cursor (the streaming-player look), not full
  screen: a 160×90 thumbnail scaled to the whole screen looks poor. Needs a DDR3 read master
  sharing `ram2` with the DTS codebooks through an arbiter (`docs/hw_budget_and_lessons.md`),
  a line buffer, and a blend next to the seek bar. A DDR3 line pump measured ~190 ALM + 6 M10K,
  so expect a few hundred ALM in all. Video is paused during a scrub, so bandwidth is not the
  issue.

**Physical discs.** Done naively, the index pass thrashes the drive and starves playback.
Scheduled, it does not:
- Only fetch while the read-ahead ring is full: 32 MB, ~25 s at the DVD maximum bitrate
  (`docs/physical_disc.md`). Slow reads after a seek measured 100–313 ms on the rig's drive,
  so a thumbnail costs an estimated 0.2–0.6 s (seek away, ~100 KB, seek back). A batch of
  10–15 per full ring leaves margin.
- Batch in LBA order (short forward hops), finish one layer before crossing to the other, and
  index freely while paused, in a menu or idle.
- Once per disc ever, thanks to the SD-card cache.
- Unmeasured estimate: a full 10 s grid in about 10 minutes of playback, the coarse grid in
  the first couple. Measure on the rig: batch timing, the ring's lowest fill, `lates`.
- The real cost is noise: the drive stays spun up. Wear is not a concern (libdvdcss key
  cracking at mount is already seek-heavy). A "Scrub Previews" option could restrict physical
  discs to pause/idle indexing, or turn it off.

**Risk / cost:** a software MPEG-2 decoder in Main (licence check against Main's GPL); the
fabric preview box at ~8 % ALM headroom; custom Main only (stock Main keeps today's scrub);
linear files (`.mpg`, VCD) have no TMAP and would need a GOP-header scan. A new OSD option
must land in `site/content/playback/settings.md` (`tools/docs_check.py` enforces it).

**Status:** idea, chosen as the preferred direction for the scrub preview (maintainer,
2026-11-09). Not scheduled.

---

## Pointer input: mouse and light guns on disc menus

**Idea:** aim at a menu button and click or pull the trigger to select it. Every HLI button
already carries its rectangle, so this is a coordinate-to-button lookup plus "select".
libdvdnav has the same operation (`dvdnav_mouse_select`). It turns the DVD shooting games
(Mad Dog McCree is already in the HIL suite) into light-gun games, and makes every menu
pointable. The maintainer is on board with mouse support (2026-11-09).

**Two kinds of gun:**
1. **IR / USB guns** (Sinden, Gun4IR, AimTrak, Retro Shooter): any display, HDMI or CRT.
   MiSTer passes them to a core as an absolute analog axis or a mouse, so they share the mouse
   path. Cost beyond mouse support: close to nothing.
2. **CRT light guns over SNAC** (GunCon-class, as the PSX and NES cores support): the
   photodiode fires as the beam passes the aim point, and the core latches its own h/v
   counters. DVD games were written for remotes and never flash a target, so the core must
   flash one white field on the trigger, as Zapper games do. Needs user-port wiring, the
   flash, the latch and a calibration step. Later, if asked.

**Rough approach:** the aim point goes through the inverse of the current framing
(`dvd/crt_ov_map.sv` already inverts Letterbox/Crop for the overlays) into HLI coordinates,
then a hit test against the current button set (`dvd/nav_pci.sv`). Hovering moves the
selection, the click activates it. Optional cursor sprite on the overlay path. `emu.sv`
takes no mouse or analog input today.

**Risk / cost:** small (a hit test over at most 36 buttons, plus input plumbing). A new
input must land in `site/content/playback/controls.md` (`tools/docs_check.py` enforces it).

**Status:** idea, maintainer interested in mouse support (2026-11-09). Not scheduled.

---

## CD+G karaoke graphics

**Idea:** show the CD+G graphics carried in an audio CD's R–W subchannel while the CD plays.
We already play audio CDs (physical, `.cue`/`.bin`, WAV) and have an overlay compositor.
CD+G is 300×216 in 16 colours from a small, publicly documented command set (tile blocks,
memory preset, border, scroll, colour tables). The maintainer called it a good candidate
(2026-11-09).

**Rough approach:** subchannel data in (raw `READ CD` with R–W subchannel from a drive,
`.sub`/CloneCD `.img`+`.sub`+`.ccd`, or a `.cdg` sidecar next to a `.wav`/`.bin`); decode
the commands into a 300×216×4-bit frame (~32 KB, likely M10K or DDR3); composite it scaled
to the raster. Main could also decode the commands and write the frame, which keeps the
fabric to a display path.

**Test material:**
- Real discs: CD+G karaoke discs (Sound Choice, Chartbuster, Pocket Songs, …) are cheap
  second-hand.
- The rig's drive must return raw R–W subchannel, and drives differ: **probe it first**.
- Rips need the subchannel too (`cdrdao read-cd --read-subchan rw_raw`, or CloneCD format).
- A synthetic generator (as `tools/dts_writer.py` is for DTS) gives benches with known
  answers before a disc arrives.
- ⚠ MP3+G (`.mp3` + `.cdg`) is the common file form today, and MP3 (Layer III) is far beyond
  our MP2 decoder. Out of scope unless Main decodes the MP3.

**Risk / cost:** the subchannel read path in Main (drive variance, de-interleaving and
error correction of the R–W packs), and the overlay's M10K. CD+G mode also has CD+EG and
the Karaoke VCD/DVD forms, which are separate.

**Status:** idea, candidate feature (2026-11-09). Next step: probe the rig's drive for R–W
subchannel reads. Not scheduled.

---

## VCD 2.0 playback control (PBC), driven from Main

**Idea:** the menus, selection lists and segment stills of VCD 2.0 / SVCD, which karaoke and
Asian-market VCDs rely on. `docs/vcd_svcd.md` lists "No menus / PBC / segment stills".

**Why it can be conservative:** the maintainer will not give up fabric logic for this
(2026-11-09), so the PBC engine must live in Main, as DVD-VR's navigation does. Main parses
`PSD.VCD` / `LOT.VCD` (play lists, selection lists with number keys and
Prev/Next/Return/Default, end lists) and tells the core which sector range to play. Number
keys already reach the core ("Select menu button by number").

**What the fabric would still need:** a "play this sector range, report its end" interface
on the `.bin` reader, and segment stills (MPEG stills, which the decoder already holds as DVD
menu stills; VCD 2.0's 704×480 stills need checking). Estimate: tens of ALMs. ⏳ Check how
the raw-CD reader would take a range command before committing.

**Risk / cost:** custom Main only (stock Main keeps today's linear VCD); physical VCDs and
`.cue` images both need the range path.

**Status:** idea, acceptable only as a Main-side design (2026-11-09). Not scheduled.

---

## DVD-VR recorder discs (already built, unmerged)

Not an idea any more: implemented on branch `feature/dvd-vr` (2026-09-19), design record
`docs/dvd_vr.md` on that branch. Main reads the UDF filesystem itself and serves the
recordings in program order as a flat stream, with no RTL change. Host-proven against
libudfread and dvd-vr and one real recorder IFO; ⏳ HW-confirm pending. The maintainer
considers VR discs a real gap (2026-11-09).

**Next step:** the branch is ~800 commits behind `main`, and `main/` has changed a lot since
(the read-ahead ring among others). Rebase it, then a HIL round with a recorder image (the
archive.org disc its doc names). Known limits are in that doc §6: no chapter or
next-recording buttons yet, no playlists, captions stored in RDI packs not shown.

---

## Zoom and pan

**Idea:** the 2× / 3× zoom with panning that set-top players offer.

**Rough approach:** the same machinery as Crop and Letterbox with new ratios: a programmable
ratio in `dvd/disp_hstretch.sv` (fixed 528→720 today), 2×/3× line ratios in
`dvd/disp_vscale.sv`, pan offsets in `resample_addrgen`'s read window (whole macroblocks,
plus an `hstretch` phase offset for smooth horizontal pan), `crt_ov_map` generalised so
subtitles and highlights follow, and a control mode.

**Cost:** today's entities (fit report, `feature/std-convert`, 2026-11-09):
`disp_hstretch` ~246 ALM, `disp_vscale` ~359, `crt_ov_map` ~147, `resample_addrgen` ~749.
Extending them, an estimated ~150–300 ALM, no new M10K, perhaps a DSP or two (not
measured). The larger cost is verification: zoom against Letterbox, Crop, Standard Convert,
240p and Interlaced.

**Status:** idea, low priority (2026-11-09). Not scheduled.

---

## Smaller ideas from the 2026-11-09 brainstorm (unranked)

- **FMV files from other consoles:** PS2 `.pss` (MPEG-2 PS + Sony ADPCM) and Sofdec `.sfd`
  (MPEG-1 + ADX). Video is already decoded; both audio codecs are simple ADPCM, a candidate
  fourth program on the shared audio engine.
- **DVD-Audio LPCM tracks** (`AUDIO_TS/*.AOB`, not MLP), up to 192 kHz stereo over HDMI. Many
  such discs are CPPM-encrypted; sweep the library first.
- **Headphone virtual surround:** a crossfeed / binaural program for the 5.1 downmix. Pairs
  with issue #189 (dynamic range).
- **HDCD decoding** for audio CDs.
- **A richer audio-CD visualiser**, our own design.
- **"Tape mode":** an optional VHS / LaserDisc look (chroma bleed, softening, light noise) in
  the pixel path, which sits in the crowded display region.

**Ruled out (2026-11-09, maintainer):**
- **A laserdisc arcade host:** other efforts cover laserdisc, and this core stays
  DVD-focused.
- **Field-sequential (HQFS) 3D with shutter glasses:** skipped. The note for anyone
  revisiting it: those discs need interlaced output with every field shown once and in
  order (no 3:2 repeat, Bob or Blend), and external controllers sync from the video signal,
  so it may already work on a CRT with Video Output = Interlaced.
