# DVD menu refinements — per-disc follow-up track (post Phase 4)

Phase 4 (the DVD-VM interpreter, PR fj#82) shipped the **core** menu navigation:
First Play boot, real command execution, button dispatch, CallSS/RSM resume,
JumpTT/VTS_PTT title resolve, SetSTN stream selection, and VOB-less VMGM/VTSM
command-only dispatchers. It is HW-confirmed on **BBB** (boot → menu → correct
feature), **MiB** (trampoline → menu → Play → resume, no regressions), and
**Matrix** (menus + special features play the correct titles).

This file tracks the **remaining per-disc refinements** — mostly nav_pci
highlight rendering and GPRM/state-consistency polish. These are NOT phase gates;
each is a "capture the real disc's behaviour, then tune" task, handled
incrementally with the disc in hand. `O[1] Disc Menus` defaulted **Off** while this
phase work ran, so none of these affected normal playback. ⚠ **As of 2026-08-23 the
default is On** (end-user defaults pass) — menu behaviour is now on the default path,
so anything left open here is user-visible out of the box.

**Method note (learned the hard way on Matrix):** before theorising about a menu
bug, DECODE THE REAL DISC — `tools/nav_extract.py <iso> --vts N --cmds` (button
HLI commands, needs the menu VOB) and `tools/iso_nav_check.py <iso>` (PGC pre/
post/cell commands + menu structure). Menu authoring varies enormously
(Matrix/T2 are GPRM state machines over VOB-less dispatchers; MiB/BBB are simple).

---

## Status roll-up (2026-07-09) — READ THIS FIRST

Every item in this file has **shipped and merged**. The per-section prose below was written
at branch-creation time; some in-section status lines still say "HW gate pending" or name a
`feature/*` branch — those are **stale wording**, not open work. This table is authoritative:

| § | Item | Merged | HW status |
|---|---|---|---|
| 1 | nav_pci highlight render (SPU_CAP 8→32 KB) | PR fj#83, #84 | ✅ HW-confirmed |
| 2 | menu→menu `keep_vbuf` transition (stale-frame / offset highlight) | PR fj#84 | ✅ HW round-2 accepted |
| 3 | GPRM/timeline consistency (T2 "wrong timeline") | PR fj#84 (via §2) | ✅ resolved by §2 |
| 5 | menu-still cold re-decode (clean frame); FAST trigger `menu_snap`‖`vbuf_empty` | PR fj#85 + `feature/menu-still-flush-primer` | 🔧 HW gate pending |
| 5b | trailing-byte flush primer (avoid re-decode) — **TRIED, HW-REVERTED (pixelated stills)** | `feature/menu-still-flush-primer` | ⛔ reverted — primer can't guarantee a clean frame |
| 5c | LEAVING A VIDEO MENU lags — deep-buffer flush + `P1O[18]` Menu Nav toggle | `feature/menu-still-flush-primer` | ⚠️ SUPERSEDED by §5d (toggle removed) |
| 5d | UNIVERSAL menu playback: keep_vbuf + VBUF cap + audio-continuity + reframer rides transitions; **toggle removed** | `feature/menu-still-flush-primer` | ✅ HW-confirmed (both discs); pop fix 🔧 pending |
| 6 | menu aspect 16:9 from IFO V_ATR | PR fj#86 | ✅ HW-confirmed 2026-07-10 |
| 7 | Matrix highlight only on 2nd loop (`spu_decode` `c_pts` guard) | PR fj#87 | ✅ HW-confirmed |
| — | `O[22]` Menu Snap toggle **REMOVED** (functionally unneeded; user request) | Phase 8 branch | fit re-verified by the Phase-8 build |
| 6b | timed/heuristic stills (PAW PATROL) | PR fj#90 | ✅ HW-confirmed 2026-07-10 |
| 8 | T2 boot-menu highlight vanished ~10 s in (forever-HLI disarm immunity) | PR fj#121 | ✅ HW-confirmed 2026-07-14 |

**Every item in this file is now HW-confirmed** (§8 closed 2026-07-14).

---

## 8. T2 boot menu — "theatrical/special" highlight vanished after ~10 s, then Select restarted it

> **✅ HW-CONFIRMED 2026-07-14 (PR fj#121, `DVD_t2menufix_20260714_1746.rbf`).** The highlight holds on
> the idle theatrical/special still and Select picks the highlighted edition; no regression on other
> T2 menus / MiB / BBB.

**Symptom (HW).** T2 boots straight to a **"select theatrical or special edition"** menu. It shows
with a working highlight, but if you wait ~10 s the **highlight box disappears** (the picture stays
identical — no flush) and after that **Select restarts the menu from the beginning**. Only this menu;
other T2 stills hold fine.

**What the disc authors (decoded via `tools/bin/trace_boot` + `nav_extract.py` + `iso_nav_check.py`).**
First-Play `JumpTT 12` → title → `LinkTailPGC` → `CallSS VMGM` → `JumpSS VTSM vts 1 menu 3` → lands in
**VTS_01 Root PGC 1** (menu domain). PGC 1 plays cell 0 (intro) → cell 1 (heuristic 5 s still) →
**cell 2 (a ~9 s fly-in animation)** → **cell 3 = the theatrical/special selector**. Cell 3 is an
**INDEFINITE still** (`still=255`) with an HLI authored **`hli_e_ptm = 0xFFFFFFFF` ("forever")** and
two buttons (`g[3]=1; LinkPGN 5` / `g[3]=2; LinkPGN 6`). Its subpicture is `SET_CONTR [0,0,0,0]` with
**no STP_DSP**, so the visible highlight is the **HLI coli recolour** (nav_pci), not the subpicture.
A real player freezes presentation time on the still, so this highlight holds forever.

**Root cause.** Cell 2's animation NAV packs carry `hli_ss=0` (highlight-off) entries. `nav_pci`
latches the trailing one as a **scheduled disarm** (`off_v`, timed by `vobu_s_ptm` on cell 2's
presentation timeline). When we settle on cell 3's still our STC keeps advancing (we don't freeze it on
a still), and ~10 s in it crosses that **stale** off time → `off_due` fires → `armed` clears. There's
no pipe flush, so the picture is untouched and only the highlight box vanishes; `hl_btns_armed` drops
to 0, so `emu`'s Select routing falls to `key_resume` (`menu_active && !hl_btns_armed`) → the VM
re-enters the menu.

**Fix (`dvd/nav_pci.sv`).** Capture the committed HLI's `e_ptm` as **`h_forever`** (`== 0xFFFFFFFF`)
and gate the disarm: `off_due &= !(armed && h_forever)`. A highlight the disc authored as *forever*
can no longer be torn down by a stale scheduled `ss=0`. Finite-window HLIs (`e_ptm` < 0xFFFFFFFF) still
disarm exactly as before — the gate only protects an already-armed forever highlight; a disarm that
arrives before any arm (`armed==0`) still clears the pending slot. This is a targeted alternative to
freezing the STC on `still_active` (which would drag in av_sync / menu-audio genlock).

**Tests.** `bench/dvd/nav_pci_tb.sv` **T8** (forever HLI + injected `ss=0` disarm while STC is past it
→ highlight SURVIVES; reproduces the bug with the gate disabled) + **T9** (finite-`e_ptm` control →
still disarms, no regression); existing T1–T7 + `ps_demux_ps2_tb` green.

**HW gate:** T2 boots to theatrical/special; leave it idle ≥15 s → highlight still there and Select
picks the highlighted edition (does NOT restart the menu). Other T2 menus / MiB / BBB unchanged;
`O[1] Off` unaffected.
Genuine remaining DVD-nav work (chapters/seek/angles, audio-track select, etc.) lives in
`docs/roadmap.md`, not here.

---

## 1. nav_pci highlight rendering (the biggest cluster) — ✅ RESOLVED (HW-CONFIRMED 2026-07-08, PR fj#84)

**Mission Profiles AND scene-range highlights now render on real hardware.** The saga
(rounds 1–5) chased promotion/timing/routing, but the real blocker was found last by
MEASURING the SPU sizes: `spu_decode`'s SPU buffer was **8 KB** (`SPU_CAP=8192`, 13-bit
addresses), and menu subpictures are large — T2 root 2.8 KB (fit → worked, PR fj#83),
mission-profiles 8.6 KB, scene-range 23.9 KB (both overflowed). The DCSQ table sits at the
END of the SPU, so a too-small cap dropped it and `rd_ptr <= dcsqt_sa[12:0]` truncated its
offset → the decoder never committed → no subpicture → no highlight. Fix: `SPU_CAP` 8 KB →
32 KB + 15-bit addresses. That un-blocked the chain; the earlier round-4/5/6 fixes
(menu_mode visible-window bypass, sp_track=0 for menus, video_live fallback) were all
correct-but-insufficient on their own and remain in place. **Diagnostic tool that cracked
it:** the O[2] on-screen blocks (armed / video_live / subpicture-shown / SPU-arrival) +
rendering the disc's SPU to PNG with `tools/spu_ref.py` (mission-profiles decoded to the
clean cast-list text — proving the content was present and well-formed). Keep the O[2]
diagnostic; it's the tool for the remaining VBUF-lag item (§5).

The historical sub-bullets below are kept for the record.



Symptoms seen across Matrix submenus and T2:
- **Highlight sometimes doesn't appear** — ✅ FIXED (fallback), sim-verified, HW gate
  pending (branch `feature/menu-transition`, 2026-07-08). **Confirmed root cause** after
  the keep_vbuf transition fix (§2) shipped: the HLI **never promotes**. nav_pci promotes
  a pending HLI when `STC >= hli_s_ptm`, but av_sync's STC is anchored on the demux
  **parse-front**, not the screen; a keep_vbuf menu→menu transition doesn't re-anchor it,
  so after a hop or two the STC sits permanently off the new menu's `hli_s_ptm` and the
  compare never becomes due → no highlight (HW round 2: Mission Profiles, the
  "Jump Into Timeline" scene-range menu, and its scene submenu all showed a **visible-coli
  highlight (`sel=444405ad`) that never armed**). **Fix:** nav_pci gains a **`video_live`**
  input and a **fallback promotion** — a pending ARM that has waited > `PROMOTE_FALLBACK`
  (~1 s) with video live promotes anyway, so the highlight ALWAYS eventually appears. The
  STC-scheduled path is unchanged for the correctly-timed case (Matrix finite windows), and
  the emu render still gates `hl_hit_q` on `video_live_s2`, so the highlight shows *with* the
  displayed menu. Sim: `nav_pci_tb` T7 (STC stuck below s_ptm → fallback arms; respects the
  video-live gate + age threshold).
  - **⚠️ HW ROUND 3 (2026-07-08): the fallback DID NOTHING — deep-menu highlights + the
    scene-range menu's baked-in numbers still missing.** Real root cause found:
    **`pickup_hold` (`av_vid_hold`, emu) freezes menus and pins `video_live=0`.** It's the
    STD **mux-lead lip-sync hold** — it defers the first FEATURE frame ~0.5 s so audio muxed
    behind the video can catch up, and it re-arms `video_live` on every load flush, releasing
    only on `aud_caught` OR a **~1.24 s fallback**. Menus aren't lip-synced and often have no
    dispatchable audio, so `aud_caught` never fires → **every keep_vbuf menu hop holds the
    full ~1.24 s AND re-arms `video_live=0`.** Deep menus (several hops) stack these freezes:
    the settled frame (numbers) is never picked up, and `video_live=0` blocks BOTH the
    highlight render gate (`hl_hit_q <= hl_on_w && video_live_s2`) AND the nav_pci fallback
    (which requires `video_live`). That's why the fallback changed nothing — its own gate was
    held low. **Fix: force `av_vid_hold=0` while `menu_active`** (menus display immediately;
    `video_live` stays set). Titles keep the lip-sync hold (`menu_active=0` during the
    feature, even with menus On).
  - **✅ HW ROUND 4 (2026-07-08) — ROOT CAUSE PROVEN by on-screen diagnostic; fix shipped.**
    The `av_vid_hold` fix made transitions **seamless** (HW-confirmed, no black frames) but
    highlights STILL didn't appear. Added a toggleable diagnostic (`O[2]`): three corner
    blocks (armed / video_live / **subpicture-shown**) + a magenta rect border. On T2 Mission
    Profiles the readout was **block1 GREEN (armed), block2 GREEN (video_live), block3 RED (no
    subpicture), border correctly around the selected option.** So promotion, video_live, and
    coordinates were all fine — **the highlight had no subpicture to recolour**
    (`subpic_blend.ov_on = sp_q_inside`). Decisive user clue: T2's scene-range **numbers are a
    SUBPICTURE overlay, not baked video** (shared cube background, different numbers per
    screen), flashing one frame after a flush then vanishing. Real cause:
    `spu_decode.visible = c_valid && (stc >= c_show) && (stc < c_hide)` — the STC leads the
    displayed frame by the VBUF depth, so by the time the menu frame is on screen the STC has
    passed `c_hide` → the menu subpicture is declared expired → never shown → numbers gone AND
    the highlight has nothing to recolour. **Fix: `spu_decode` ignores the STC show/hide window
    in `menu_mode`** (`visible = enable && c_valid && (menu_mode || (stc-window))`); a menu
    shows its subpicture the whole time it's up, and `pipe_rst_n` clears `c_valid` per jump so
    nothing stale leaks. Subtitles keep the authored window. Sim: `spu_decode_tb` menu-mode
    visibility test + `subpic_chain_tb` green. Surfaces BOTH the numbers and the highlight.
    **Open:** *highlight sometimes early* — a menu highlight now shows as soon as its
    subpicture commits (~parse front), slightly before the settled frame; acceptable, deferred.
- **Highlight offset from the button** (Matrix submenus badly, T2 "very offset").
  `SP_QX_ADJ` (emu, currently 13) was HW-calibrated on the **main** menu. Submenus
  / other discs position buttons differently; if the offset is CONSTANT it's a
  single-tap lead-compensation, but a menu that's scaled (16:9 anamorphic, or a
  letterboxed sub-window) would need the button rect coordinates scaled too. Check
  whether the offset is constant across menus (→ alignment tap) or proportional to
  position (→ a scale factor, i.e. the btni rect is in a different coordinate space
  than `core_h/v_pos`).
- **Highlight has an outline but no fill** (T2 — should be solid red).
  **✅ FIXED — HW-CONFIRMED 2026-07-08 (branch `feature/subpic-render`, PR fj#83): the T2
  menu highlights now fill SOLID.** DECODING T2 first (per the method) redirected the
  diagnosis:
  - T2's VTS_01 root menu (the timeline-select carousel: btn3 `g[3]=1`, btn4 `g[3]=2`,
    both `LinkPGCN 24` — this is also symptom #3) authors its buttons as **tiny edge
    hotspots** with **`coli = 0x44440000`, i.e. all four contrast/alpha nibbles = 0**
    (a pure navigation hotspot, no recolor). The `coli` byte-order was verified against
    the raw bytes + libdvdread layout (high 16 = colour nibbles, low 16 = contrast).
    So T2's visible highlight lives in the **subpicture graphic**, not the HLI coli.
  - **Bug found:** our renderer *unconditionally* overrode colour+alpha inside the button
    rect (`hl_hit_q ? hl_a : sp_alpha`). With an all-zero-contrast coli that **zeroes the
    subpicture's own pixels inside the rect** → the button graphic's fill vanishes inside
    the hotspot (only the part outside the small rect survives = "outline but no fill").
  - **Fix (two parts, both guarded, no new pipeline stage — hotspot-safe):**
    1. `hl_use = hl_hit_q && (hl_a != 0)` in `emu.sv`: inside the rect a class is
       recoloured by the coli **only if its contrast nibble is nonzero**; a contrast-0
       class KEEPS its authored subpicture pixel. Matrix/MiB main menus (nonzero coli on
       the graphic classes) are byte-identical; only contrast-0 classes change behaviour.
    2. `subpic_blend.ov_force` (driven by `hl_use`): a recoloured class blends on **alpha
       alone**, so a **background-class (idx 0) highlight fill** can show — the `ov_idx!=0`
       transparent key is right for subtitles but wrong for a menu fill. Spec: the coli
       applies to all four classes incl. background.
  - **HW result (2026-07-08):** T2 menu highlights now show a **solid colour fill** (was
    outline-only). Still worth a glance on the next round: confirm no regression on
    Matrix/MiB highlights or on subtitles (the fix is byte-identical for nonzero-coli
    menus, so none expected). The *offset* and *GPRM/timeline* halves of T2 (below, §2/§3)
    are separate and deferred.

## 2. Menu transition animations freeze / cut to a still — ✅ MERGED PR fj#84 (HW round-2 ACCEPTED)

> Status: shipped and HW-accepted (keep_vbuf). The "HW gate (next round)" note further down
> refers only to the two deferred *residual* side-effects (mid-transition black frame,
> content-appears-late), which were folded into §5; the core fix is done.

**Branch `feature/menu-transition` (2026-07-08).** The "offset highlight" reframe was
correct: the highlight is drawn at the right menu coordinates (pixel-locked to the
subtitle path); the apparent misalignment is a **stale/frozen menu IMAGE under a
freshly-armed highlight**, and the freeze is the **VBUF flush on a menu transition**.

**Root cause (decoded from the real disc).** T2's Root menu button (still cell 3,
`still=0xFF`) runs `SetGPRM g[3]=1; LinkPGN 5` (btn1) / `g[3]=2; LinkPGN 6` (btn2) —
a program link to a **transition cell** (Root PGCN 1 cell 4/5, `still=0`,
`cell_cmd=1/2`) that then `LinkPGCN 5`/`6` into the theatrical/special timeline menu.
So a timeline select is **two** pipeline events: a menu-internal **seek** (still →
transition cell) and a menu→menu **jump** (transition cell → timeline PGC). BOTH
fired `seek_ack`/`jump_ack`, and emu pulsed **`vbuf_flush`** on each, which resets the
decoder's compressed-video buffer (`rtl/mpeg2/mpeg2video.v` `flush_vbuf_eff`). A cold
re-lock discards the authored transition tail and leaves the **persistence frame (the
old menu still)** on screen while `nav_pci` — fed by the fast NAV/PCI stream — arms the
**new** menu's highlight over it. Result: highlight for menu B over the frozen image of
menu A = "very offset / freeze mid-transition / highlight over a still with no text."

**Fix — hold the VBUF on menu→menu transitions (`keep_vbuf`).** `vbuf_flush` is
essential for **title seeks / menu→title (Play)** (A/V sync: the picture must jump with
the audio), but a **menu→menu** transition is not A/V-sync-critical and *should* play
its buffered tail out. The reader now exports **`keep_vbuf`** (valid on the
`seek_ack`/`jump_ack` cycle):

| transition | `keep_vbuf` | vbuf_flush? |
|---|---|---|
| menu-internal seek (LinkPGN transition cell), source `menu_dom` | 1 | **no** |
| menu→menu jump (LinkPGCN), pre-`menu_dom` && dest VMGM/VTSM | 1 | **no** |
| menu next_pgcn / POST advance (adv_pend), `menu_dom` | 1 | **no** |
| menu→title (Play), title→menu (Menu key), FP/auto boot | 0 | yes |
| title/gamepad transport seek (`menu_dom`=0) | 0 | yes |

emu gates `seek_flush_cnt` with `~keep_vbuf`; **`load_flush` still fires** on every
seek/jump (ps_demux / nav_pci / av_sync re-anchor — so the OLD highlight disarms and the
NEW one arms cleanly, and the decoder is NOT reset by `load_flush`: `mpeg2video.rst =
reset_n`, not `pipe_rst_n`). So a menu→menu transition keeps decoding continuously: the
buffered transition animation plays out, then the new menu's cell decodes, then it parks
on its still — no cold-restart, no stale frame. `still_active`'s existing "play out the
buffered tail then starve on the authored still" behaviour does the rest.

This also fixes **§3 (GPRM/timeline divergence)**: with the image no longer frozen a
transition behind, the timeline menu's graphic and its highlight both come from the same
freshly-decoded PGC — they can't diverge. (The VM already sets `g[3]` *before* it links,
so there was no GPRM-ordering bug; the divergence was purely the stale image.)

**Still using vbuf_flush (by design):** MiB **"Play"** (menu→title) keeps the flush.
**✅ (2026-07-14) The "cut the transition / go straight to the movie" symptom is RESOLVED
— HW-CONFIRMED:** MiB "Play" now plays the authored transition through (FBI / copyright
warnings) rather than jumping past it. That was not the VBUF flush — it was the menu→title
Play *dispatch* (`LinkPGN 5` → `LinkTailPGC` → POST → `JumpSS`/`JumpTT`) landing past the
transition cells, fixed by the recent VM navigation corrections (Scene It `JumpVTS_TT`
`jump_vts <= cur_vts`, PR fj#120, and/or the `V_PGSCAN` fix, PR fj#122). Any residual *cosmetic*
black frame at the flush itself is by design (holding the VBUF would make the feature video
lag its audio by ~1 s — the transport-seek lesson).

Sim: `bench/dvd/iso_reader_menu_tb.sv` T2/T4/T8 assert `keep_vbuf` per the table;
`bench/dvd/iso_reader_seek_tb.sv` asserts a title transport seek keeps it 0.

**Tail-drain amendment (✅ HW-CONFIRMED 2026-07-30, PR fj#149):** the table above is unchanged, but a NATURAL
title-side PGC end (First Play logo chains, end-of-title → menu POST) no longer loses its
buffered tail to the `keep_vbuf=0` flush: the reader now **waits for `vbuf_empty` before
dispatching `vm_pgc_end`** (title domain only, ~5 s watchdog), so the tail plays out and
the flush hits an empty buffer. User-initiated jumps/seeks are untouched (still
immediate). This **defers** the flush until there is nothing left to cut — it does NOT
remove a flush, i.e. it is explicitly NOT the reverted PR fj#89 approach (§6b warning).
Design: `docs/dvd_nav.md` "Natural-transition tail drain".

**HW ROUND 2 (2026-07-08): keep_vbuf ACCEPTED — transitions + timeline switch work.**
Submenus reachable, timeline switching loads the correct root menu. Residual keep_vbuf
side effects (the video pipeline is now continuous but the display lags the parse by the
un-flushed VBUF depth):
- **A black frame or two mid-transition** (at the LinkPGCN jump, "where it used to
  freeze"). The jump keeps the VBUF but still pulses `load_flush` (ps_demux reset) and
  clears the reader's 16 KB stream cache (`wr_ptr=0`), dropping the transition tail's last
  ~16 KB + a partial PES → a 1–2 frame junction glitch. Menus decode fast (shallow VBUF),
  so the decoder can't bridge the re-parse gap. Not yet fixed — a fully-continuous
  transition (preserve the reader cache + don't reset ps_demux, only nav_pci) is the
  candidate, but it touches the audio path and av_sync re-anchor; deferred pending a
  focused HW round.
- **Content appears late** (e.g. the scene-range menu's baked-in numbers / a profile's
  first slide). The decoder plays the accumulated VBUF (previous-menu tail + transition +
  the still cell's animation) at display rate before reaching the settled still frame, so
  the final content (numbers, first slide) lands ~1–2 s after entry. Clicking during that
  window activates the already-armed button and skips the settled frame ("you don't get to
  the first slide until clicking on the frozen transition"). The `video_live` highlight
  fallback (§1) makes the highlight appear ~with the settled content; the underlying
  content-lag needs the VBUF-lag work (bound the accumulated lead) — deferred.

**HW gate (next round, T2 + Matrix, HDMI progressive, O[1] On):** entering a submenu /
selecting a timeline should play the transition and land on the correct menu with the
highlight over the *matching* image (no frozen pre-transition still, no apparent offset);
Matrix submenus similarly; MiB/BBB menus unchanged; normal playback (O[1] Off) unaffected.

## 3. GPRM / menu-state consistency (T2 "wrong timeline") — likely resolved by §2, HW-confirm

> **Update (2026-07-08):** decoding T2 showed the timeline buttons run
> `SetGPRM g[3]=N` **before** the link, and the graphic + highlight of the target
> timeline menu both come from the **same jumped-to PGC** — so there is no genuine
> GPRM-ordering divergence. The observed "highlight = one timeline, image = the other"
> is the **stale/frozen image** during the transition (§2). The §2 `keep_vbuf` fix
> should make the image match the highlight; re-confirm on HW before closing this item.

- **T2**: you pick a "timeline" (Theatrical vs Special Edition) and the menu graphic
  changes accordingly. Observed: the HIGHLIGHT shows one timeline's options while the
  menu IMAGE is the other timeline's. The menu graphic (which PGC/cell plays) and the
  HLI (which button set) are both selected by GPRM state (a g15-style selector); they
  have diverged. Either (a) the VM's GPRM at PGC-select time differs from what the
  displayed HLI expects (a stream-lead: an old HLI shown over new video, the Phase-3
  double-buffer issue at yet another layer), or (b) a GPRM the VM sets isn't the one
  the reader used to pick the PGC. Decode T2's timeline-menu PGCs (`iso_nav_check.py`)
  + the button commands, and trace the GPRM that gates the graphic vs the highlight.

## 4. Smaller / expected

- **Commentary track silences the menu's own audio** — expected when the menu VOB
  has no such substream; low priority.

---

## 5. Menu stills don't reach their final frame — cold re-decode (clean), with a FAST trigger

> **★ 2026-08-26 — SEPARATE ROOT CAUSE FOUND for the PIXELATED half: the decoder was
> writing the new picture INTO the frame slot the display was scanning out.**
> `rtl/mpeg2/motcomp_picbuf.v`'s `STATE_UPDATE` guards `current_frame` (:268/:278) and
> `prev_i_p_frame` (:355) with `~vld_last_frame`, but the **forward/backward reference swap
> (:322/:327) was NOT guarded**, so at every `sequence_end_code` the slot pointers rotated one
> extra step. `STATE_LAST_FRAME` then emits `prev_i_p_frame` for display *and* clears
> `prev_i_p_frame_valid`; the next sequence's first I therefore took
> `current_frame <= forward_reference_frame` — which the extra swap had just made equal to the
> displayed slot — while `output_frame_valid == 0` let `STATE_IP_FRAME_0`'s `~output_frame_valid`
> shortcut (:164) release the VLD with no display handshake. The picture then painted into the
> slot `dvd/resample_addrgen.v` was persistence-re-scanning (`output_frame_sav`, :1065) =
> "blocky, like it hasn't finished loading". **Fix: add `~vld_last_frame` to the swap** —
> the alias becomes structurally impossible (`fwd`/`bwd` are always a distinct {0,1} pair, and
> at a sequence end `output_frame == prev_i_p_frame == bwd`). Sim:
> `bench/dvd/motcomp_picbuf_tb.sv` scenario [A] fails pre-fix, passes post-fix; a new
> `` `ifdef CHECK `` assertion in the module catches any recurrence in every picbuf bench.
>
> ⛔ **Do NOT "harden" the `STATE_IP_FRAME_0` shortcut instead** — gating it on slot inequality
> DEADLOCKS the core: `dvd/resample_addrgen.v:543` gates pickup on `output_frame_valid`, which
> is 0 in exactly the scenario such a gate would try to catch, so `output_frame_rd` can never
> arrive. (It also aliases legitimately at video start, where all the slot regs reset to 0.)
>
> **What this does and does not explain.** MEASURED over 70 real cells of
> `Harry Potter Interactive DVD Game (HOGWARTS CHALLENGE)`: every `still_time=255` still cell is
> `SEQ GOP PIC:I SEQ_END` with the `B7` ending a video PES (so `ps_demux`'s `S_VID_FLUSH` filler
> fires and the VLD really does reach `STATE_SEQUENCE_END`), while every video/transition cell
> ends on a coded **B**. Since the swap is `!= B_TYPE`-gated, **a still arms the collision for
> whatever decodes next** — so still→still menu navigation collided every time, and video→still
> did not. It therefore does **not** explain the reported "clean when jumped to, pixelated when
> landing naturally" asymmetry (video transitions never armed it), nor the "pixelated for a few
> seconds" duration (the filler fires, so the still's I-frame does fully decode — this predicts
> a blocky flash of a frame or two). Any residual after the fix has a second cause.


> **Status (2026-07-12): the PR fj#85 cold re-decode is the CORRECT mechanism and is KEPT.**
> The §5b trailing-byte flush primer that briefly replaced it was **HW-reverted** — it made
> the still appear fast but **PIXELATED** (see §5b), because it shoves out the *mid-stream*
> decoded frame (stale references) instead of re-decoding the cell cleanly. So the cold
> re-decode is restored. Its old drawback was the 2-3 s lag from waiting for the buffer to
> DRAIN (`vbuf_empty`) before re-decoding; that's fixed by a **faster trigger**: in Snappy
> (`menu_snap`, §5c) the §5c deep-flush has already emptied the buffer, so the re-decode fires
> **immediately** (fast *and* clean); in Smooth it still waits `vbuf_empty` so the authored
> transition plays out first. Reader: `S_STILL` fires the flush+re-stream when
> `menu_dom && !still_flushed && (menu_snap || vbuf_empty)`. The `feature/menu-vbuf-lag`
> branch reference and "HW gate pending" wording below are historical.

**Original problem (kept for the record). HW-observed on T2.**
Symptoms, all one root cause:
- **Scene-range "Jump Into Timeline" numbers missing on first entry.** cell 0 of PGCN 8
  IS the numbered still (confirmed: ffmpeg-decoded that single I-frame shows all cubes
  `01/06 … Main Menu` — the numbers are BAKED VIDEO, not a subpicture). On the deep entry
  path the display is stuck on the buffered blank **entry-transition** and never drains
  through to cell 0's numbered frame. Re-entering from a range (shorter path) DOES show the
  numbers — less backlog.
- **Mission-profile slide load: blank slide; a click flashes the first slide for one frame
  then jumps to the second.** Same thing — the still frame is buffered behind the transition;
  the reader has parked + armed the next action while the display still trails, so a click
  advances past the frame that's only just about to show.
- **Matrix/MiB scene-page nav: highlight jumps immediately, images change ~2–3 s later.** The
  highlight (nav_pci, parse-front) leads the video (decoder, trailing by the buffered depth).

**Root cause.** `keep_vbuf` (§2, correct + HW-good for seamless transitions) means a
menu→menu transition does NOT flush the decoder VBUF, so the reader/parse runs ahead of the
display by the buffered depth (seconds on deep paths). The reader parks in `S_STILL` and the
HLI/PCI (nav_pci) update immediately, but the DISPLAYED frame lags — so the settled still
(the numbered/first-slide frame) shows late or, on the deepest paths, effectively never
(user clicks through it). av_sync's STC is anchored on the demux parse-front, which is why
everything PTS-scheduled (SPU show window, HLI arm) also leads the screen.

**Fix direction (still open).** Make the decoder reach the settled still frame promptly
without reintroducing the transition black frame — **and without cutting a legitimate
transition animation.** Candidates:
- **(a) flush-and-re-decode the still cell** at the menu-still park (`still_pend → S_STILL`):
  a brief cold-decode of the single still I-frame shows the numbers immediately.
  **⛔ TRIED — PR fj#85 (`feature/menu-vbuf-lag`), HW-REJECTED, REVERTED (commit 189c41b).**
  Built as "flush + re-decode the still cell *when the VBUF is deeply backed up*"
  (`vbuf_backed_up = core_vbuf_fill >= 0x20` ≈ 256 KB, once per menu entry). **HW result: it
  over-fired and CUT the transitions** — "T2 menus all hold on an image ~1 s too early";
  "Matrix transitions don't play the full transition video between menus" (submenus fine after);
  MiB unaffected. **Why the occupancy gate can't work:** `keep_vbuf` *intentionally* runs the
  parse ahead of the display, so at **every** menu still-park the VBUF is *already* ~1 s backed
  up — that is the NORMAL, healthy state, not a "deep stuck" signal. The occupancy is elevated
  for a normal single transition exactly as much as (or indistinguishably from) a deep path, so
  any threshold low enough to catch the deep case also fires on normal transitions and flushes
  their ~1 s buffered tail (= "holds ~1 s early"). MiB's simple menus never buffer past the
  threshold, so they slipped through. **Occupancy at the still-park is not a usable
  discriminator** — do not re-attempt candidate (a) gated on VBUF fill.
- **(b) bound the accumulated VBUF lead** for menus so the parse can't run seconds ahead.
  **Analysis (not built): does NOT solve the numbers-missing symptom.** The deep-entry lateness
  is the *amount of transition CONTENT* (a longer authored entry path = more animation cells),
  not just how far the reader buffered ahead. Bounding the buffer backpressures the reader but
  the display still plays every transition frame at refresh rate, so the numbers appear no
  sooner. It *would* reduce the highlight-leads-image skew and the click-through window (the
  reader parks / nav_pci arms closer to the display), but it can't make a several-second
  authored transition reach its settled still faster. Useful only for the highlight-lead half.
- **(c) catch the display up by fast-draining** the VBUF — advance the display/decode faster
  than refresh until it reaches the parse-front, then resume. The only candidate that reaches
  the settled frame promptly **while still playing the transition** (fast-forwarded, not cut).
  **🔧 BUILT — branch `feature/menu-vbuf-lag` (2026-07-08), sim-verified, HW gate pending. See
  "Fix as built" below.**

**Key lesson (this round):** the whole point of `keep_vbuf` is that the parse leads the display,
so "the VBUF is backed up at the still-park" is *always true* and cannot distinguish
keep-the-transition from catch-up-now. A DESTRUCTIVE fix gated on that signal (flush) is wrong;
a NON-destructive one (fast-forward) tolerates the same imprecise signal because over-triggering
only speeds a transition up a little — it never cuts.

### ✅ ROOT CAUSE FOUND (decoded the disc + O[2] measurement) — it was never pacing

Both timing fixes below failed on HW; the real cause is the **decoder's display-reorder /
end-of-stream flush**, not pacing. Found by decoding the actual disc and reading the O[2]
diagnostic at the stuck blank-cubes frame.

**The T2 scene-range path (decoded via `tools/iso_nav_check.py` + ffmpeg cell decode):**
- PGCN 5 cell 5 = the "Jump Into Timeline" transition (`still=0`, **3.9 MB** fly-in) — its
  **last frame is BLANK cubes** (ffmpeg-confirmed). `cell_cmd=5 → LinkPGCN 8`.
- PGCN 8 cell 0 (`still=255`) = the **NUMBERED** cubes (ffmpeg-confirmed) — **3 pictures +
  a `sequence_end_code (000001b7)` + a padding stream (`000001be`, ~30 KB of `0xFF`)**.

**Why the numbers never show:** `motcomp_picbuf` reorders display — an I/P frame is held as the
backward reference and only pushed to the screen when the **next** I/P frame arrives *or* the VLD
hits the `sequence_end_code` (`STATE_LAST_FRAME` flush). At the still-park the reader stops, and
**ps_demux drops the trailing padding stream**, so the VLD starves right at the `seq_end` and
never reaches `STATE_SEQUENCE_END`. ⚠ **STALE as written (corrected 2026-08-26):** `ps_demux`
now synthesizes 24 filler bytes after a `000001B7` at a PES end (`S_VID_FLUSH`, `ps_demux.sv:187-203`),
so the VLD *does* reach `STATE_SEQUENCE_END` on real still cells — verified on the Harry Potter
disc. The surviving lag mechanism is the buffered-depth lead plus the reorder hold, not seq_end
starvation. cell 0's frame stays in the reorder hold → the screen keeps
the forward reference = **cell 5's blank last frame**. keep_vbuf (continuous decode, no flush)
is what exposes it; re-entry from a range only *looks* right because that source transition's
last frame already carries numbers (cell 0's frame isn't displayed there either — it's masked).

**O[2] measurement at the stuck frame confirmed it:** `blk5` RED (VBUF never got deep → fast-drain
never fired — retired), `blk6` GREEN (reader **is** parked on the still), VBUF bar small and
draining to nothing (cell 0's bytes **are** consumed) — decoded but never flushed to display.

### Fix as built (menu still COLD RE-DECODE, gated on VBUF-empty)

Candidate (a)'s cold re-decode *did* display the numbers (a clean cold decode shows cell 0's
frame via the normal reorder as its next frame decodes) — it just fired mid-fly-in and cut the
transition. The correction is the **trigger**: wait until the buffered transition has **fully
played out** (`vbuf_empty`), *then* flush + re-decode just the still cell.

- **emu.sv** derives **`vbuf_empty`** (`core_vbuf_fill <= 0x01` ≈ drained) from the framestore
  occupancy tap and feeds it to the reader. (Fast-drain's `menu_ff` chain is **retired/tied 0** —
  `blk5` proved it never engaged; the governor ports remain but are bit-identical at 0.)
- **dvd_iso_reader.sv** — in `S_STILL`, if `menu_dom && !still_flushed && vbuf_empty`: pulse
  `seek_ack` with **`keep_vbuf=0`** (emu → `load_flush` + `vbuf_flush`) and re-load `cell_i` via
  `S_CELL_LOAD` — a **clean cold decode of just the still cell**. The still frame then displays
  normally. Done **once per menu entry** (`still_flushed`, re-armed on every jump / seek /
  next_pgcn / PGC-load). Menu stills only; a real jump/seek still exits S_STILL first.
- **Why waiting for `vbuf_empty` matters:** the whole fly-in decodes and displays before the
  VBUF drains, so the authored transition is **NOT cut** (candidate (a)'s failure). After it
  drains, the cold re-decode brings up the numbers. Net UX: fly-in plays in full → brief hold →
  numbers.

Sim: `bench/dvd/iso_reader_menu_tb.sv` TEST 9 — `vbuf_empty=0` stays parked (no flush, no
re-stream); `vbuf_empty=1` pulses exactly one `seek_ack` with `keep_vbuf=0` and re-streams the
still cell, then re-parks (proves the cold re-decode + the `still_flushed` loop-guard). All
reader/menu/VM tbs green.

**HW gate (T2 + Matrix, HDMI progressive, O[1] On):** the Jump-Into-Timeline fly-in plays in
full, then the **numbered cubes appear**; mission-profile slides fill in after their load
transition; MiB/BBB menus + title playback + O[1] Off unchanged. If numbers still don't show,
the O[2] `blk6` (still_active) + VBUF bar tell whether the re-decode fired and drained.

**Tooling in place:** the **O[2]** on-screen diagnostic (blocks armed / video_live /
subpicture-shown / SPU-arrival + rect border) and `tools/spu_ref.py` / ffmpeg cell decode.

---

## 5b. Trailing-byte flush primer — ⛔ TRIED, HW-REVERTED (pixelated stills)

> **HW verdict (2026-07-12): reverted.** The primer flushed the still frame *fast* but
> **PIXELATED** on transition-entry menus (T2 "mission profiles" first slide, both Snappy and
> Smooth; user: *"stays pixelated"*). Root cause: the primer only pushes the **already-buffered**
> frame out of the reorder hold — and that frame was decoded **mid-stream** (entered via a
> keep_vbuf transition, so with stale references), so it's corrupt. The old cold re-decode
> avoided this by re-decoding the cell **cleanly from its sequence header** (self-contained
> I-frame). Speed alone isn't worth a corrupt frame, so the primer + its module
> (`dvd/vidfeed_flush_primer.sv`) and tb are **removed**, and §5's cold re-decode is restored
> (with the §5c fast trigger so it's fast too). The design write-up below is kept for the record.

**(Superseded — this is why the primer looked attractive.)** The §5 cold re-decode made the
still frame appear but only after a **2-3 s lag** on every still menu — the user's report:
*"navigating to a still-image submenu, the
highlight appears instantly but the menu image takes 2-3 s; video-background submenus are
fine; paging through scene-selection pages each take a few seconds."* That lag is inherent
to how §5 worked: (1) wait for the buffered transition to fully DRAIN (`vbuf_empty`), then
(2) FLUSH + **re-stream and re-decode the whole still cell** — a second full round trip.

**Why the still needed *any* nudge (§5 root cause, still valid).** A DVD menu still cell
ends in a `sequence_end_code` (`00 00 01 B7`) followed by a padding stream that `ps_demux`
drops. The decoder's `getbits` (`rtl/mpeg2/getbits.v`) needs a full 64-bit word of
**trailing** data past the `B7` to slide its window into the VLD's `STATE_SEQUENCE_END`
(`rtl/mpeg2/vld.v:557`), which asserts **`last_frame`** so `motcomp_picbuf` **emits** the
held still frame (its `STATE_LAST_FRAME`). With no trailing bytes the VLD starves right at
the `B7`, the still frame stays stuck in the display-reorder hold, and the screen keeps
showing the previous (transition) frame. Video-background menus never hit this — they
continuously produce fresh frames, so nothing is ever stuck.

**Fix: synthesize the trailing bytes a real bitstream would carry.** New module
`dvd/vidfeed_flush_primer.sv` sits on the video ES between `ps_demux` and `vidfeed_cdc`
(clk_sys). When the reader parks on a still (`still_active`) and the ps_demux video output
goes **idle** (⇒ the `B7` is already in the FIFO), it appends a short run of **`0xFF`
filler** (`PRIME_BYTES = 64`, after `PRIME_IDLE = 32` idle cycles) behind the still cell.
That un-stalls `getbits`, the VLD processes the `seq_end`, `last_frame` fires, and the still
frame flushes to the display **as soon as the buffered transition finishes playing** — like
a real player, with **no re-decode and no drain-then-restream round trip**. Scene-selection
paging (little/no transition) becomes near-instant.

**Why it's robust to timing.** `0xFF` is **inert** to the VLD start-code hunt (never forms
`00 00 01`), so a mis-timed injection can only ever be **skipped** by the VLD — it can never
corrupt a frame. And the idle guard rides `ps_vid_valid`, which stays HIGH while ps_demux is
still emitting the tail (through the `B7`), so the filler is only ever appended AFTER the
real `seq_end` — never before it. An `armed`-on-video-activity gate injects **one** run per
video burst (so a parked still doesn't spew filler forever) and re-arms for the **next** cell
(menu page-next / timed-still chain).

**What was removed.** `dvd_iso_reader.sv` S_STILL no longer does the cold re-decode
(`still_flushed`, the `menu_dom && vbuf_empty` re-stream); the reader's `vbuf_empty` input
and emu's `vbuf_empty` derivation are deleted (the O[2] `core_vbuf_fill`/`vbuf_deep` bar tap
stays). S_STILL now only runs the timed-still countdown and otherwise holds. Timed stills
(ads/copyright/menu-end) get their frame from the primer too (they also set `still_active`).

**Sim.** `bench/dvd/vidfeed_flush_primer_tb.sv` (passthrough when idle; one `0xFF` run
appended after a `00 00 01 B7` tail, order preserved, exactly `PRIME_BYTES`; no forever-spew;
re-arm per burst; byte-integrity under `out_ready` backpressure). `iso_reader_menu_tb` TEST 9
now asserts the reader **holds** the still with **no** `seek_ack`/re-stream;
`iso_reader_timedstill_tb` asserts a timed still advances with no cold re-decode. All
reader/nav/vm suites green.

**HW gate (T2 + Matrix, HDMI progressive, O[1] On):** entering a still submenu / paging
scene-selection pages should show the menu image **promptly** (transition plays, then the
still — no multi-second blank), highlight over the matching frame; video-background menus,
MiB/BBB menus, title playback, and O[1] Off all unchanged. If a still still lags, check that
`still_active` is asserting (O[2] `blk6`) and consider raising `PRIME_BYTES` (getbits may need
more trailing slack than 64 bytes on some cells).

---

## 5c. Leaving a VIDEO menu lags (video→video AND video→still) — 🔧 flush the deep buffer on the jump (HW gate pending)

**HW-observed (2026-07-12, after §5b landed the still-display flush):** still→still paging
became snappy, but **leaving a VIDEO menu still lags ~2 s** — the destination (a still page
*or the next video menu*) appears seconds after the highlight. On MiB the scene-selection
pages are **video** menus, and returning from them to the root menu shows the same lag, so
this is **not** still-specific — §5b's flush primer (which only fixes the still's *display*
flush) can't help it.

**Root cause — the `keep_vbuf` display lag itself.** A video menu continuously buffers
~1-2 MB of bitstream **ahead** of the display (the parse runs ahead; that's what
`core_vbuf_fill`/`vbuf_deep` measure). §2's `keep_vbuf` *deliberately* does NOT flush that
buffer on a menu→menu transition (so an authored transition tail can play without a cold
re-lock). The cost: the display must **drain the whole video backlog** before it reaches the
destination, so the highlight (nav_pci, parse-front) leads the picture by that backlog =
seconds. A **still** source doesn't have this — the decoder starves on the still and its
buffer DRAINS, which is exactly why still→still (§5b) is already snappy.

**Fix — a user toggle, because MiB and T2 CONFLICT.** MiB's laggy scene pages are
video→video (want them flushed/snappy); **T2's rich menu transitions are ALSO video→video
but you want them KEPT** (uncut animation). DVDs carry no reliable "this buffered content is
an authored animation, keep it" flag, so no single automatic rule satisfies both — and this
exact area has repeatedly mispredicted HW. So §5c is a **toggle**, `P1O[18] Menu Nav`:
- **Snappy (default, `menu_snap=1`):** override `keep_vbuf` and **FLUSH** on a menu→menu
  jump/seek **when the source buffer is deep** (`emu.sv`: `jump_flush = jump_ack &&
  (~keep_vbuf || (vbuf_deep && menu_snap))`, same for `seek_flush_now`).
- **Smooth (`menu_snap=0`):** the proven §2 `keep_vbuf` — deep menu→menu keeps the buffer so
  authored **transition animations play uncut** (T2), accepting the pre-destination lag.

`still→still` paging is snappy in BOTH modes (the §5b flush primer is independent of this
bit). In Snappy mode:

| transition | source buffer | result |
|---|---|---|
| leaving a **video** menu (→ still or → video) | DEEP (`vbuf_deep=1`) | **FLUSH** → display snaps to the destination after a ~0.3 s decoder re-lock |
| still → still (page-next) | shallow (drained) | no flush → smooth `keep_vbuf` path, §5b primer shows the still |
| still → video | shallow | no flush |
| title transport seek | — (`keep_vbuf=0`) | flushes as before (unchanged) |

`vbuf_deep` (hysteresis 0x40 on / 0x18 off ≈ 512/192 KB) cleanly separates a *buffering*
video menu from a *drained* still, so the flush fires exactly on the laggy cases and never on
the already-good ones. **This is NOT the rejected §5 candidate (a)** (which flushed at the
still-*park* on occupancy and cut transitions because *every* still-park used to look deep) —
here the gate is at the **jump**, and §5b having drained the still source is what makes
`vbuf_deep` a valid discriminator now.

**Trade-off (why it's a toggle, Snappy mode):** an authored video-menu→menu **transition
animation** that was buffered is cut, and there's a brief (~0.3 s) "old frame + new highlight"
flash while the destination re-locks — i.e. a *much shorter* version of the very "highlight
leads image" symptom this fixes (~2 s → ~0.3 s). This re-introduces, on purpose, the menu→menu
flush that §2 removed for smoothness. On transition-heavy discs (**T2**) that cut is visible,
so **Smooth (`P1O[18]=1`)** restores the proven §2 `keep_vbuf` and the full animations. `O[1]`
Off and title playback are unaffected either way (no menu jumps).

**HW gate (MiB + T2 + Matrix, HDMI progressive, O[1] On):**
- *Snappy (default):* leaving a video menu (MiB scene pages → root; entering a still submenu)
  lands on the destination promptly (brief re-lock flash, not a multi-second lag); highlights
  arm over the correct frame (nav_pci `video_live` fallback re-arms on the flush's `load_flush`);
  still→still paging unchanged; MiB/BBB simple menus + title playback unchanged.
- *Smooth:* T2's menu-to-menu transition animations play uncut (the pre-§5c behaviour), still→still
  still snappy (primer).
- **A/B question for the user:** does Snappy visibly harm any T2 transition (dropped/cut animation)
  enough to prefer Smooth there? The answer decides whether a smarter per-transition discriminator
  is worth pursuing over the global toggle (see the note below).

**If a no-compromise rule is wanted later:** the blocker is that MiB and T2 lag on the *same*
transition type (video→video), so a discriminator must key on a *structural* property (destination
still-vs-video, transition kind — `LinkPGCN`/`next_pgcn`/replay-loop, or a cell flag), decided from
the HW A/B of which transitions must stay smooth. Not built speculatively — DVDs don't cleanly flag
"this is an animation," and this area has mispredicted HW before.

**Menu-audio free-run (Smooth audio dropout fix).** HW (2026-07-12): in **Smooth** mode, T2
had **audio dropouts *during* the transition animations**. Cause: Smooth keeps the video
buffer deep during a transition, so the video-referenced STC runs behind, and
`dvd_audio_decode`'s STC scheduling (`sched_en`: drain gate / head-stale / pre-anchor hold)
starves the menu audio against that lagging clock. Menu audio is background music (no
lip-sync), so it shouldn't be genlocked at all: `emu.sv` now forces
`sched_en = ~av_freerun & ~(menus_on & menu_active)` — the menu-audio drain **free-runs**
while a disc menu is active (harmless in Snappy, where the video is already current;
independent of the Menu Nav bit). The STC scheduling re-engages on the menu→title exit
(which flushes and re-anchors anyway).

---

## 5d. Toward a UNIVERSAL menu setting — audio-continuity + menu VBUF cap (🔧 HW gate pending)

**HW (2026-07-13) corrected two earlier wrong turns and set the direction: the user wants ONE
setting that works for every disc (no per-disc Snappy/Smooth toggling).**

**Corrected diagnosis of the T2/Smooth audio dropout.** It is NOT backpressure starving the ring
(the 64 KB bump — §5c draft — was reverted; the ring is *reset*, so its size is irrelevant). At
EVERY menu→menu jump, `load_flush` pulses `pipe_rst_n`, which resets the whole demux+audio chain
(ps_demux, reframer, audio_ring, dvd_audio_decode). For VIDEO that's fine — ps_demux re-parses the
new stream into the KEPT decoder buffer (keep_vbuf), whose ~1 s of frames bridge the re-parse gap,
so video rides smoothly. But the audio ring/decoder were also wiped, so the queued menu audio
vanished and the *next clip's* audio dropped out right at the junction (exactly where menus used
to freeze pre-keep_vbuf). Fix (**audio-continuity**, `emu.sv`): gate the AUDIO reset with
`keep_vbuf`, symmetrically with the video `vbuf_flush` — `aud_rst_n = reset_n & ~aud_flush &
~aud_resync`, where `aud_flush` pulses on `start_streaming || ((seek_ack||jump_ack) &&
~keep_vbuf)`. So a keep_vbuf menu→menu transition no longer resets audio_ring/dvd_audio_decode;
the queued audio keeps draining while ps_demux/reframer (still reset) re-sync and refill it behind
the old audio. Real flushes (clip load, title seek, menu→title Play, Snappy deep-flush) still
reset audio to stay aligned with the video flush. (ac3_reframer stays on pipe_rst_n; it self-heals
on the next 0x0B77, bridged by the ring — keeps the high-fanout `aud_rst_n` net at 2 modules.)

**Menu VBUF cap (make Smooth universal, no flush).** The "leaving a video menu lags" symptom (MiB
scene pages / return-to-root, and any keep_vbuf transition) is just the display trailing the parse
by the KEPT buffer depth. Instead of flushing it (Snappy — which cuts T2's transition animations
and drops their opening frames on re-lock), the reader is simply **throttled while a menu is
active** whenever the decoder's compressed buffer exceeds ~384 KB (`menu_vbuf_over`, hysteresis
0x30/0x18; `reader_busy = fifo_almost_full | (menus_on & menu_active & menu_vbuf_over &
~menu_snap)`). The buffer stays shallow → a menu→menu transition has only a short backlog to play
out (small lag) yet is NOT flushed (the authored animation still decodes continuously). Menus are
low-bitrate so a shallow buffer doesn't starve video; audio rides the throttle's brief
oscillations via its (now-un-wiped) ring. Scoped to Smooth (`~menu_snap`) so the proven-great MiB
Snappy path is untouched — the intent is that **Smooth becomes the universal behaviour** and the
toggle is later removed. Cap is tunable (lower = snappier but risks video stutter / audio
oscillation).

> **★ 2026-08-04 amendment — MENU-AUDIO STALL GRAIN (Thayer's Quest ~3 Hz menu-audio
> skipping).** The "audio rides the throttle's brief oscillations via its ring" assumption
> above is FALSE for a **just-in-time mux**: Thayer's Quest authors audio only **~33 ms ahead
> of its delivery schedule** (audio PTS − pack SCR; normal discs 470–667 ms), so the ring
> cushion at the cap is small and the original release point — drain 0x30 → 0x18 ≈ a
> **~250 ms full-stream stall per cycle** — outlasted it. HW-proven via `osd_read` on the
> DEBUG_OVERLAY build: the stream feed halted one 100 ms sample in three (VBUF sawtooth 29↔41
> = the cap's hysteresis band, a metronomic ~3.3 Hz stop-go), the audio ring pinned at 0
> frames, rows 13/14/15 flat (no drops, no decoder resets) — pure supply starvation. Delivery
> throughput, the AC-3 stream, ps_demux (byte-exact vs ffmpeg), and the fabric decoder
> (full-stream cosim) were all exonerated first; the 4× sd-block rework (PR fj#159) changed the
> skip rate not at all, which is what pointed away from delivery.
>
> **Fix (v3): keep the cap + a RING-FLOOR ESCAPE VALVE.** The quantitative story (byte-level
> interleave scan, per-cell monotonic): Thayer's audio sits up to **+122 KB (p90 +42 KB)
> behind its concurrent video in the stream** — a normal interleave — but the intro's
> bitrate is high, so the 0x30 cap is only **~0.3 s of demux-front lead in time**; minus the
> interleave lag and the audio pipeline's hold, the equilibrium ring cushion lands at ≈ ZERO.
> The cap sits exactly at this disc's viability threshold — which is why v2 (stall grain
> 0x18→0x2C, ~40–80 ms stalls) still starved: solid audio lasted only until the VBUF first
> reached the cap (~3 s), then the ring drained and parked at 0. MiB/T2 menus are low-bitrate
> with generous margin (−196..+72 KB), which is why the cap never hurt them (and v2's finer
> grain DID fix the v1 highlight/sluggishness regressions — it stays).
> **v3:** while menu audio is LIVE (`menu_aud_live`, retriggerable ~0.7 s on `rf_aud_valid`)
> AND the ring is LOW (`aud_ring_low`: < 6 committed frames, hysteresis to 12), the cap
> releases until the ring recovers. Self-adjusting: margin-rich discs never trip the floor
> (cap-only, full §5d polish); a tight menu holds its VBUF slightly above the cap — exactly
> the extra lead its mux needs, bounded per release burst, and VBUF-full stays impossible.
>
> **⛔ v1 REJECTED on HW (same day) — do not retry unbounded suppress-the-cap:** a
> `menu_aud_live` guard that DISABLED the cap outright while menu audio flows. Two failures:
> (1) most real menus have music, so the cap died everywhere — ~1 s sluggish menu
> transitions + the highlight-appears-before-the-image regression returned on all menus;
> (2) with the reader free-running, the **VBUF filled to TRUE FULL in ~10 s**, after which
> the shared stream is paced by VIDEO consumption at the vbuf-write stall — the audio ring
> has no restoring force in that regime (it receives exactly realtime, never
> re-accumulates), so it drained once and parked at 0: solid audio for ~10 s, then permanent
> skipping. Only a BOUNDED, ring-closed release is safe.
>
> **★★ FINAL RESOLUTION (2026-08-05, ✅ HW-CONFIRMED — audio solid AND in sync on
> Thayer): the ultimate root cause was NOT flow control at all.** Thayer is mostly
> FIELD-CODED MPEG-2 and the frame-drop governor's documented punt on field-picture
> B's meant its ~10 % video-decode deficit was never reclaimed — video ran slow,
> vid_err climbed (+8 refr/s = the audio-early gameplay drift), and the backed-up
> buffers entered the VBUF-hard-full jam below. Fixed by the **B FIELD-PAIR DROP**
> (`rtl/mpeg2/vld.v`: first-field decision, `drop_pair_arm` atomic sibling,
> `drop_pic_field` cost 1/field). The flow-control amendments below remain shipped on
> merit (the ceiling prevents a genuine death regime; the shrunk cap closes the
> highlight-early gap), but they were TREATING SYMPTOMS of the unreclaimed deficit.
>
> **★ v4 (2026-08-05) — GLOBAL VBUF SOFT CEILING (0xE0/0xD8), the row-27 verdict.** The
> overlay's new row-27 flow-control instrument settled it: v3's floor cycles correctly
> (ring 4–12, audio solid) but each release nets VBUF growth (110→241 in 9 s) until
> **hard-full, where the stall source flips THR→FIFO (demux jammed mid-PES on video) and
> never leaves** — the ring backpressure (BP) never engages and the ring bleeds to 0.
> Crucially the climb also proved audio is SOLID on just 4–12 ring frames — the ring never
> needs to be deep; the VBUF just must never hard-jam. And clip 2 showed **titles live in
> the same jam** (vbuf=255 FIFO through most of gameplay). v4 = a reader-side stall at
> 0xE0 (release 0xD8, ~60–100 ms drains the ring rides through) outranking everything:
> normal discs regulate via ring backpressure far below it; Thayer-class menus park at the
> ceiling — slower transitions on those menus, correct audio. The remaining TITLE-side
> issue is separate: video runs ~10–13 % slow (6–7 lates/s, drops=0 → vid_err +8/s = the
> user's audio-early A/V drift) — a decode-throughput/governor matter, not flow control.

**HW round 1 (2026-07-13) — ✅ CONFIRMED on both discs (Menu Nav = Smooth):** T2 menu audio plays
continuously through the transition animations (no junction dropout); MiB scene pages /
return-to-root have only a short (~0.4 s) lag, acceptable; T2 animations uncut; stills clean.

**HW round 1 residual + final consolidation (toggle removed).** One residual: an occasional
**static POP** when leaving the ROOT menu (MiB + Matrix; NOT T2). Cause: the audio-continuity fix
keeps the `audio_ring` across a keep_vbuf transition, but the **AC-3 reframer was still reset**
(`pipe_rst_n`), so during its re-sync it could push one **mis-aligned** AC-3 frame into the
preserved ring → `ac3_front` self-heal reset → pop ([[static-pops-root-cause]]). Fix: the AC-3 and
DTS reframers now use **`aud_pipe_rst_n = reset_n & ~aud_flush`** — the same keep_vbuf-aware reset
as the ring (kept a SEPARATE net from `aud_rst_n`, which additionally carries `~aud_resync`, so the
audio-reset fanout stays split across two small nets, not one 4-load net). Un-reset, the reframer
self-heals on the next `0x0B77`/`0x7FFE8001` with the frmsizcod lock (no spurious boundary) = a
clean splice.

**Since HW confirmed the keep+cap+audio-continuity path is universal, the `P1O[18]` Menu Nav
toggle (Snappy/deep-flush) is REMOVED** — menu→menu always keeps the buffer (no flush), the VBUF
cap handles the lag, and `status[18]` is freed. The flush is back to the pure `keep_vbuf` rule
(flush only a title transport seek / menu→title Play). Removing the toggle also relieves the
routing congestion the §5d build hit (which made SEED 9 marginal). The menu VBUF cap now applies
whenever a menu is active (no `~menu_snap` gate); the still cold-re-decode always waits `vbuf_empty`
(prompt because the cap keeps the buffer shallow). Cap `MENU_CAP_ON` still tunable.

**HW gate (both discs):** no static pop leaving the root menu; T2 audio/animations + MiB lag +
stills unchanged from round 1; no per-disc setting needed.

### 5e. MiB root-menu loop cut to black after one pass — ✅ HW-CONFIRMED 2026-07-14 (PR fj#122)

**Symptom (HW).** With `O[1]` On, the MiB root-menu montage plays (intro + animated clips)
then, at the end of the first loop, the screen goes **black**, **Select stops responding**, and
only the **Menu** key still works (it resumes to the movie). Present in every build since the
menu work landed; flagged open in `41371e7` ("pre-existing DVD-VM cell-loop path").

**HW diagnosis (O[2] overlay = the disambiguator).** The `O[2]` debug blocks read: buttons
**armed** (blk1) + highlight fetched/recoloured (blk7/blk8) over a **still** (blk6 `still_active`
GREEN = the reader is PARKED in `S_STILL`) with the VBUF **empty** (blk5 RED = black frame). The
`O[2]` HUD "CH n/N" (repurposed to `{reader PGCN, VTS}`) showed **PGCN 5** (the correct root
menu), and the whole-title time froze **near the END** (~1:29/1:33). So the reader did **not**
loop — it played *through* the montage and parked on a black still cell.

**Root cause (reproduced in sim — `bench/dvd/iso_reader_montage_tb.sv`).** The MiB root menu is
`VTSM vts=2 PGCN 5`, 6 cells; the montage is `cell 0` (28 s intro) → `cell 1` (cell-cmd
`LinkPGN 3` → seek to program 3 = cell 2) → `cell 2` (cell-cmd `LinkTopPG` → restart the current
program = **replay cell 2**). libdvdnav loops cell 2 forever. The reader's `dvd_vm` was supposed
to answer `LinkTopPG → vm_replay`, but instead answered **`seek cell 3`** (the still) → the reader
advanced to cell 3, parked, black.

The bug was in **`dvd/dvd_vm.sv` `V_PGSCAN`** (the program-map scan that resolves `cur_pg`).
`pmem_q` is a **registered** read of `pmem[pm_raddr]`, and `pm_raddr <= pg_i` is nonblocking — so
in the old two-phase-per-entry loop, `pg_hit` compared `pm[pg_i-1]` (one entry STALE). Whenever a
program follows the current cell's program (MiB cell 2 is program 3 of 6), the stale value kept
`pg_hit` asserted one entry too long, over-counting `cur_pg`/`pg_final` by 1. So `LinkTopPG`
(which links to `pg_final`) resolved to program 4 = cell 3 and issued a **seek** instead of a
**replay**. Fix: a **three-phase** `V_PGSCAN` (`pg_ph` = set-addr / settle / evaluate) so `pg_hit`
sees `pmem_q == pm[pg_i]`. Zero effect on the other paths.

**Why Matrix/T2 were unaffected:** the Matrix root menu loops cell 2 via **`LinkCN 3`** — a direct
cell link (`(ins-1)==cur_cell → vm_replay`) that never touches `V_PGSCAN`. Only `LinkTopPG /
LinkNextPG / LinkPrevPG` (program links with a program map) hit the bug. That is exactly why
Matrix looped fine and MiB didn't, on the *same* build.

Tests: **new `bench/dvd/iso_reader_montage_tb.sv`** (full reader+VM, MiB montage shape — asserts
the reader LOOPS cell 2 via `vm_replay`, never advances to the still; FAILS on the pre-fix VM,
PASSES after) + **`dvd_vm_tb` S4b** (unit: `LinkTopPG → vm_replay` / `LinkPGN 3 → seek cell 2`
with `nr_pgms=6 > current program` — the condition that triggers the off-by-one). All
reader/menu/nav/vm/ps2 suites green. **HW-CONFIRMED (2026-07-14):** MiB root menu (O[1] On)
loops indefinitely with the highlight armed and Select responsive; Matrix menu still works.

---

## 6. Menu aspect ratio — 16:9 anamorphic menu shown squished as 4:3 — ✅ HW-CONFIRMED 2026-07-10 (PR fj#86, IFO V_ATR)

> Status: the IFO-V_ATR fix merged as PR fj#86; a hardware confirmation pass is still open
> (memory `menu-aspect-from-ifo`). The `feature/menu-aspect-ifo` branch reference below is historical.

**Branch `feature/menu-aspect-ifo` (2026-07-08).** HW-observed on Matrix: the VTS_02
root menu displays **4:3 (squished / tall)** while VLC shows the same disc's menu in
**16:9**.

**Root cause (decoded from the disc).** DVD menus are routinely authored **16:9
anamorphic** but the menu VOB's **MPEG sequence header still carries the 4:3 aspect
code**. Measured on `THE_MATRIX_16X9LB`:

| source | Matrix VTS_02 **menu** | Matrix VTS_02 **title** |
|---|---|---|
| IFO video attr (VTSM/VTS_V_ATR@0x100/0x200, display AR bits 11:10) | **16:9** (raw 0x4D00) | 16:9 (raw 0x4E80) |
| MPEG sequence-header `aspect_ratio_information` | **4:3** (code 2) | 16:9 (code 3) |

Our Auto aspect (`emu.sv` `ar_wide_auto`) followed the **sequence header**, so the title
came out 16:9 (its seq-hdr is right) but the menu came out squished 4:3 (its seq-hdr lies).
A spec-correct player takes the display aspect from the **IFO video attribute**, which is
what VLC does — the sequence-header code is not authoritative for DVD.

**Fix.** `dvd_iso_reader` now captures the menu domain's IFO aspect at each VTSM/VMGM
load: after reading the VTSI/VMGI `_MAT` for the PGCI_UT pointer (@208 / @200), a new
state `S_MENU_VATR` grabs `V_ATR@0x100` (high byte, display-AR bits = 0x0C ⇒ 16:9) from
the still-resident MAT sector and drives `menu_ar_wide`. `emu.sv` Auto uses it **only
while a menu is active** (`ar_wide_auto_eff = (menus_on && menu_active) ? menu_ar_wide :
ar_wide_auto`); titles keep the proven seq-header path. The capture completes during the
menu LOAD (before `menu_active`), so `VIDEO_ARX/ARY` stays stable across the title→menu
transition whenever the movie and its menu share an aspect (the common case — no scaler
re-init). This is HDMI (ascal `VIDEO_ARX/ARY`); the CRT-480i path has its own `O[4:3]`
CRT Aspect control (`docs/crt_anamorphic.md`) and is unchanged.

Sim: `bench/dvd/iso_reader_menu_tb.sv` TEST2 now seeds `VTSM_V_ATR@0x100=0x4D00` and
asserts `menu_ar_wide==1`; all reader/menu/vm/pgc/ifo/seek/vmgm/ptt tbs green.

**HW gate (Matrix, HDMI, O[1] On):** the VTS_02 root menu should fill 16:9 (not squished)
matching VLC; MiB/BBB 4:3 menus unchanged; title aspect unchanged; O[1] Off unaffected.

---

## 7. Matrix MAIN menu highlight appears only on the SECOND loop — ✅ FIXED + HW-CONFIRMED (PR fj#87, `spu_decode` `c_pts` guard)

> Status: the `spu_decode` menu re-send guard (compare vs the COMMITTED SPU's PTS) merged as
> PR fj#87 and is HW-confirmed (user: "working well without menu snap enabled" — see HW round 2
> below). `O[22] Menu Snap` was retained for fit stability (PR fj#88) and has since been
> REMOVED (Phase 8, functionally unneeded — see the Status roll-up table). The "fix HW-gated" /
> "HW gate pending" wording below is historical.

**HW-observed on Matrix (O[1] On): the main-menu button highlight does NOT appear the
first time through the interactive loop; it shows on the second loop.**

**Disc structure (decoded — `iso_nav_check.py` + a NAV/PCI + video-PTS scan of the ISO).**
The VTS_02 root menu is PGCN 1, entry 0x83, **3 cells**, played cell0→cell1→cell2 with
cell2 looping (`cellcmd=1 → LinkCN 3`, the VM `vm_replay`, no flush):

| cell | first video PTS | subpicture PES | HLI (PCI) | role |
|---|---|---|---|---|
| 0 | 0.1 s | **none** | ss=0, btn_ns=0 | fly-in animation |
| 1 | 24.3 s | **none** | ss=1, btn_ns=4, s_ptm 24.7 s | "menu appears" (buttons defined) |
| 2 | 52.4 s | **2 packets** | ss=1, btn_ns=4, s_ptm 52.8 s | the interactive LOOP |

**Key structural finding: the button-highlight SUBPICTURE lives ONLY in cell 2.** The
Matrix highlight is a `coli` **recolour of the subpicture** (nonzero-contrast HLI), so it
can only render where the subpicture graphic exists — i.e. only in cell 2. (Cell 1 arms
the HLI but has no subpicture to recolour, so no highlight there — correct, not a bug.)
So the whole question reduces to: **why does cell 2's highlight take a full loop to
appear** instead of showing on the first cell-2 pass.

**Suspected mechanism (the recurring parse-vs-display VBUF skew, §5).** The reader parses
seconds ahead of the display and the cell boundaries are big **forward PTS jumps**
(0.1→24.3→52.4 s, each > `FWD_REANCHOR` 15 s) so av_sync re-anchors the STC to the parse
front, while the loop's backward jump re-anchors it back — the STC thrashes relative to
the screen. On the first cell-2 pass the subpicture is committed at PARSE time (menu_mode
persists it) and the HLI arms (STC-sched or the ~1 s `video_live` fallback), but the
DISPLAY only reaches cell 2 a loop later. Static analysis can't pin the exact off-by-one
loop — it's an emergent timing property, the same family as §5.

**Decisive next step (HW): read the O[2] diagnostic on the FIRST cell-2 loop.** The four
corner blocks say exactly which stage is missing on loop 1:
- block1 (armed) RED ⇒ nav_pci never promoted the HLI (STC/fallback) → nav_pci promotion.
- block3 (subpicture-shown) RED, block4 (SPU-arrived) GREEN ⇒ SPU reached spu_decode but
  didn't commit/show on pass 1 (the menu re-send SKIP guard or a stale `c_valid`) → spu_decode.
- block3 RED + block4 RED ⇒ ps_demux didn't route the cell-2 SP on pass 1.
- all GREEN but no colour ⇒ a `coli`/render issue, not timing.

Do NOT ship a blind fix here — every plausible cause has a different one-line fix and the
wrong one is a wasted HW round. The O[2] readout on loop 1 is the disambiguator (tools:
O[2] blocks + `tools/nav_extract.py` / `tools/spu_ref.py`).

### HW round 1 (2026-07-08) — narrowed to the keep_vbuf return path

**Refined symptom (user):** the highlight **works on the initial root-menu load**; it's
missing (needs ~one loop) **only when RETURNING to the root menu from a submenu.** O[2]:
**blocks 1–4 all GREEN** on both the failing and working loops; the **magenta rect border
is present and correctly positioned** over the intended button on the failing loop; and the
**menu IMAGE is the correct root menu** (not lagging/submenu).

**Decoded the Matrix root-menu cell-2 HLI + SPU** (`nav_extract.py` + a DCSQ dump):
- `btn_coli[grp1] sel=0x00000f70` — Ci=0000, α: class0=0, class1=7, class2=15, class3=0.
  So the highlight = the SUBPICTURE's **class-1/2 pixels recoloured to palette idx 0**,
  made visible by the coli inside the selected button's rect. **Constant across all NAVs.**
- 4 buttons, rects x315..533 / y271..399, coln=1, cmds LinkPGCN 2/3/6 + LinkTailPGC. All
  constant and correct.
- The SPU's own `SET_CONTR 0000` = transparent by default (that's why it needs the coli).

**So everything the recolour needs is confirmed present/correct EXCEPT the recolour firing.**
Ruled out this round: aspect, video-lag (image is right), button rect (border right), coli
(decoded constant), armed, video_live, SPU arrival.

**The ONLY difference between the working and failing case is the transition path:**
- **initial load** = title→menu / boot = **`keep_vbuf=0` → VBUF FLUSH** (§2 table) →
  display snaps to the menu → recolour aligns. ✅
- **return from submenu** = menu→menu LinkPGCN = **`keep_vbuf=1` → NO flush** → the decoder
  plays its buffered tail while the parse/nav/SPU chain is already at the root menu (all
  blocks green) → the recolour can't align to the displayed frame for ~one loop. ❌
  (Matrix's return goes straight to cell 2 via `LinkCN 3` — **no animated transition to
  preserve**, unlike a forward root→submenu hop.)

### HW round 2 (2026-07-09) — ✅ ROOT CAUSE FOUND + FIXED + HW-CONFIRMED (spu_decode menu re-send guard)

**✅ HW-CONFIRMED (2026-07-09, user): "working well without menu snap enabled"** — the
spu_decode `c_pts` guard alone makes the highlight appear on the FIRST loop when returning
from a submenu. `O[22] Menu Snap` is NOT needed functionally (default-Off; it targets only the
residual VBUF display lag). PR fj#87.

**Menu Snap toggle REMOVED (Phase 8, user request — "no longer needed").** The `O[22]`
Menu Snap experiment was functionally superseded by the `spu_decode` `c_pts` guard (PR fj#87,
HW-confirmed "working well without menu snap enabled") and is now deleted. `O[22]` is freed.
**History (why it was once retained — PR fj#88):** an earlier cleanup build that DELETED the
toggle (`DVD_menufix`) was HW-BROKEN (garbled green video / stuck resolution popup) — the
classic congestion/`clk_dec`-Fmax placement lottery ([[quartus-build-flaky-routing]],
[[chroma-edge-fringe-is-upsample-mode]]), even though the RTL was functionally identical to
the HW-good `DVD_menuret2`. Removing a default-off toggle just reshuffled placement onto a bad
fit. Since then the per-build **Fmax gate** (PR fj#92, `tools/fmax_check.sh` / `build_release.sh
--release`) makes a marginal fit fail the pack instead of shipping silently, so this removal is
gated: the Phase-8 release build must pass the clk_dec Fmax gate (≥81 MHz both slow corners)
before it flashes. Lesson still stands — a "no-op" edit can tip the fit on this
congestion-marginal design; the Fmax gate is now what catches it.


**HW readout (user), O[2] blocks 7/8 added this round:**
- initial load (highlight visible): blk7 (armed+fetched) GREEN, blk8 (recolour fires) GREEN.
- return, no snap (no highlight): blk7 GREEN, **blk8 RED**.
- return, `O[22] Menu Snap` On: blk7 GREEN, **blk8 GREEN — but still no highlight until loop 2.**

blk8 green + invisible was the key: `subpic_blend` only shows a recoloured pixel where
`ov_on = sp_q_inside` (the subpicture is COMMITTED-visible). blk8 (`sp_force_q`) fires on the
subpicture *class* (which can read stale bitmap RAM), so the recolour computed but the
subpicture wasn't committed. **The missing thing was the subpicture COMMIT.**

**Root cause (decoded the disc, `spu2.py` DCSQ dump):** Matrix's root cell 2 sends **TWO**
subpictures per loop on substream 0x20 — a tiny transparent **DUMMY** (Unit A, pts 52.298 s,
DAREA 16‑23) then the **REAL full-screen highlight overlay** (Unit B, pts 52.798 s, DAREA
0‑719/2‑479, `SET_CONTR 0000` so it needs the HLI coli). `spu_decode`'s menu re-send guard
skipped a new SPU when `stc < sp_pts`. On return, A commits first (`c_valid=1`), then B is
**skipped** because the screen-referenced STC (≈52.36 s) hasn't reached B's pts (52.798 s) —
B only gets accepted a full loop later when the STC crawls past it. That is the "2nd loop."
On the initial load the parse had already run seconds ahead so the STC was well past B's pts,
so B committed immediately — which is why initial load worked. Menu Snap fixed the *video*
alignment (blk8 fires) but not the SPU commit, so it alone didn't help.

**Fix (`spu_decode.sv`, ✅ HW-confirmed — see the §7 header):** the menu re-send guard now compares
the new SPU's PTS against the **committed** SPU's PTS (`c_pts`) instead of `stc`: SKIP only a
re-send of the committed-or-older unit (`sp_pts <= c_pts`), ACCEPT a genuinely newer one
(`sp_pts > c_pts`) immediately; a fresh `c_valid=0` (post-flush) always accepts. So Unit B is
accepted on the FIRST loop → the highlight appears immediately, and the looping re-sends of A
(older) and B (same) are still skipped (no churn, dummy never reverts). Subtitles
(`menu_mode=0`) are untouched. This removes the fragile `stc` dependency that made the behaviour
loop-count-dependent. Sim: `spu_decode_tb` new menu re-send test (newer accepted at `stc=0`,
older re-send skipped); `subpic_chain_tb` (real VOB) green.

**`O[22] Menu Snap`** was retained for a while (default Off) as an independent option for the
*residual* VBUF display lag (on a keep_vbuf return the decoder plays its buffered tail ~1 s
before the root menu is on screen); the spu fix makes the highlight correct once that frame
shows. It has since been **removed** (Phase 8) — see the roll-up table / the "REMOVED" note
above. The residual VBUF lag is tracked separately (§5 menu-still cold re-decode).

**Superseded leading-fix note (kept for the record):** make the menu→menu RETURN flush the VBUF
(like the initial load) so the display snaps to the menu and the recolour aligns
immediately. Risk: `keep_vbuf` on menu→menu was chosen (§2) to preserve **forward**
animated transitions (T2 root→submenu); a blanket flip to flush could reintroduce the §2
black-frame / cut a real transition. The clean discriminator (return vs forward hop) isn't
available at jump time. Options to scope it: flush only menu→menu **jumps that re-enter a
PGC via goup/prev** (a "back"), or only when the destination is the interactive LOOP cell.
Watch T2 forward transitions on the HW round. Lower-risk alternative to probe first:
whether the recolour's `fetched`/subpicture-coverage simply isn't surviving the keep_vbuf
STC skew (a nav_pci/spu_decode fix that doesn't touch keep_vbuf) — needs a waveform or a
targeted O[2] on `fetched`.

---

## §6b — Timed / heuristic stills (PAW PATROL: MEET EVEREST) — ✅ HW-CONFIRMED 2026-07-10 (PR fj#90)

> Status: the libdvdnav still-heuristic + timed holds merged as PR fj#90; a hardware
> confirmation pass is still open. The `feature/dvd-timed-stills` branch reference below is historical.

**Symptom (HW, `O[1]` On):** the logo plays, then the disc "flashes through" the ad,
copyright, and menu screens at ~one frame each and auto-plays an episode. A **real
set-top box** instead: plays the logo → **holds the ad screen** (waiting for a Continue
button) → plays the **copyright for a timer** → goes to the **root menu and holds**.

**⚠️ First diagnosis was WRONG (do not revisit it).** I first blamed a `keep_vbuf`
menu↔title *flush* cutting short "video" cells (a candidate fix shipped as PR fj#89 and was
**reverted** — it changed nothing on HW). The real answer came from building the user's
**libdvdnav** clone with `-DTRACE` (`$DVD_REPOS/`, meson in a
venv) and tracing the disc:

- **Our DVD-VM is byte-exact identical to headless libdvdnav** on this disc (boot path,
  GPRM state, JumpSS/JumpTT chain — all match). RCE region protection is just a libdvdnav
  *warning* (`SPRM20=0x1`, same branch as us); SPRM defaults match. So the VM is correct.
- **The stills are NOT in the IFO `still_time` field (all 0).** libdvdnav infers them with a
  heuristic (`src/vm/vm.c` `get_current_position` 561-596): if `still_time==0` and a cell is
  small (`last_sector - first_sector < 1024`) and single-VOBU (`last_sector ==
  last_vobu_start_sector`), the cell's authored **playback_time** (which exceeds its content
  duration) IS the still. On this disc that yields the exact set-top sequence — **ad = 10 s,
  copyright = 5 s, root-menu intro = 20 s**, then the `0xFF` interactive menus — confirmed
  against the libdvdnav TRACE and reproduced by `tools/iso_nav_check.py` (prints `pbtime`
  + `*** HELD Ns`). Our reader read only `still_time` (=0), applied no heuristic, and
  auto-advanced through all three in ~1 frame = the flashing.

**Fix (shipped PR fj#90, ✅ HW-confirmed 2026-07-10):**
implement the libdvdnav still heuristic + honour the resulting holds. In
`dvd/dvd_iso_reader.sv`:
1. **Detect** — the cell walker (`P_CELL`) now also captures `last_vobu_start_sector` (@16)
   and `playback_time` (@4-7, BCD→seconds), and the cell-meta write computes the effective
   still via the heuristic (`eff_still_w`), stored in `cell_meta_mem` so downstream sees a
   nonzero hold for these cells.
2. **Hold** — at cell-end a **timed** still (1–254 s) drains, parks in `S_STILL`, counts
   down at 1 Hz (`SEC_DIV` prescaler; a `parameter` so sims run fast), then runs the action
   the cell-end WOULD have taken (`STILL_NEXT`/`STILL_CMD`/`STILL_PGEND`). An **indefinite**
   (`0xFF`) still keeps the existing behaviour (so MiB/Matrix `0xFF+cmd` loop-holds are
   untouched — the discriminator is timed-vs-`0xFF`, checked *before* the cmd branch). A
   menu **button** that fires a VM jump still exits early via the existing `jump_go` (that's
   the "Continue" on the ad screen and menu navigation — Stage-3 early-advance rides the
   button→VM→jump path already in place).

Non-regression: heuristic **only fires in `menu_dom`** (title cells are large → never
match); MiB/Matrix/BBB compute **no** heuristic holds; T2 matches libdvdnav's 5 s + the
indefinite park. Tests: `bench/dvd/iso_reader_timedstill_tb.sv` (heuristic detect + timed
hold + auto-advance + indefinite park, `SEC_DIV=1000`), full reader/vm suite green.

**HW gate:** PAW PATROL boots → logo plays → ad holds (Continue advances) → copyright ~5 s
→ root menu holds; MiB/Matrix/T2/BBB menus + play unaffected. Oracle for any menu-VM
question: the libdvdnav TRACE build in `dvd_repos/` (see memory
`paw-patrol-vm-matches-libdvdnav`).

---

## Historical: where to start (now fully superseded — all items merged; see the Status roll-up at top)

- ~~Highlight visibility~~ — ✅ done (PR fj#84, SPU_CAP).
- ~~Highlight fill (T2)~~ — ✅ done (PR fj#83).
- ~~VBUF lag / settled-frame reach~~ — cold re-decode (PR fj#85) SUPERSEDED by the §5b
  trailing-byte flush primer (`feature/menu-still-flush-primer`, removes the 2-3 s lag).

All per-disc menu refinements tracked in this file have shipped. Only §6 (aspect, PR fj#86) and
§6b (timed stills, PR fj#90) still want a hardware confirmation pass; everything else is
HW-confirmed. New DVD-nav work (chapters/seek/angles, audio-track select) is in `docs/roadmap.md`.
