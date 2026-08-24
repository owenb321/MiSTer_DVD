# Spec Hardening — design to the DVD spec maximum, not the test shelf

**Status: Phase 1 ✅ DONE (PR fj#167, 2026-08-18) — `tools/spec_audit.py` shipped; local
library + BOTH NAS collections measured (302 discs total, ~2 TB deep-scanned),
Phases 2–6 re-ranked on the evidence (see "Phase-1 findings" below).
Phase 3 (HLI button groups) ✅ HW-CONFIRMED + MERGED (PR fj#168).
Phase 2 (SPU spec max) ✅ HW-CONFIRMED + MERGED (PR fj#169).
Phase 5 (ptt_mem 1024) ✅ HW-CONFIRMED + MERGED (PR fj#170).
Cross-PGC chapter skip through ptt_mem (the follow-up that makes Phase 5 real —
the table's read side is now consumed, no longer swept) ✅ HW-CONFIRMED + MERGED
(PR fj#171, 2026-08-19; see Phase 5 below).
title_sel widening DEPRIORITIZED (user decision 2026-08-19: the manual title
override is a debug aid, not a user feature — fold a widened picker into the
DEBUG menu as a rider on a future feature branch, no dedicated PR).
Phase 4 (LU selection + Player Language OSD) ✅ HW-CONFIRMED (PR fj#176,
2026-08-19: Hobbit BONUS serves the correct unit per Player Language —
Japanese shows its authored JIMCA warning cards before the menu, English
does not, exactly per-unit authoring; UNEXPECTED_JOURNEY boots; no
regression on other discs).
Phase 6 cell-duration clamp ✅ HW-CONFIRMED + MERGED (PR fj#177, 2026-08-19:
no-regression gate passed on the board; the >255 s positive path stays
sim-proven until a repro disc appears — spec_audit is the tripwire). THE TRACK'S WORK QUEUE IS NOW EMPTY: everything below-spec is
fixed or evidence-deferred; remaining gaps live in docs/conformance.md
(MPEG-1 L2 audio, menu audio, UDF-only images).**

## Why this document exists

Two shipped bugs were the same failure in different clothes:

- **15-bit PGCN (PR fj#164):** every PGCN path was 8-bit because no test disc had more than
  255 PGCs — until Weakest Link's VTS_02 arrived with **1394**.
- **Authored cell duration (PR fj#165):** cells ended at sector exhaustion because on every
  test disc that was close enough — until WL authored a 17-second single-I-frame cell.

Both were avoidable by **designing to the spec maximum instead of waiting for a disc to
break**. There are more discs in the world than we will ever test (user decision,
2026-08-18): close the remaining below-spec gaps proactively, and where a behavior can't
be verified blind, **measure the rip library** instead of waiting for an HW failure.

Companion documents: `docs/conformance.md` (the feature-level what's-implemented matrix —
this doc is the *capacity/limits* sibling and feeds findings back into it),
`docs/disc_sweep.md` (the empirical HW campaign).

## The audit (2026-08-18): where we stand vs spec

Audited: every table size, counter width, and hardcoded "common case" in
`dvd/dvd_iso_reader.sv`, `dvd/dvd_vm.sv`, `dvd/nav_pci.sv`, `dvd/spu_decode.sv` against
libdvdread `ifo_types.h`/`nav_types.h` + *DVD Demystified* (both under
`~/Programming/MiSTer/dvd_repos/`).

### ✅ Verified AT or ABOVE spec — do not re-audit

| Item | Ours | Spec max |
|---|---|---|
| PGC command table | 4096 B BRAM = 512 cmds (`dvd_vm.sv` cmem, reader clamp 511; the "2048 B = 256" first written here was stale — the BRAM was doubled when a >256-command menu dispatcher broke nav) | **128 cmds per pre/post/cell block = 384/PGC** (Demystified p.~13971 txt) — headroom intact |
| Cells per PGC (`MAXCELL`) | 255 | 255 (u8) — exact |
| PGCN / SRP scan / next·prev·goup | 16-bit | 15-bit (fixed PR fj#164) |
| Programs (`pm` BRAM) | 128 | 99 |
| VTS groups (`MAXGRP`/`MAXEXT`) | 100 | 99 |
| HLI buttons / colour groups | 36 / 3 (incl. `coln=0` quirk) | 36 / 3 |
| Angles | 9 | 9 |
| `jump_ptt` | 10-bit | 99 |
| NAV scrub probe (`NAV_CAP`) | 1024 sectors | > max legal VOBU (~756 @ 10.08 Mbps) |
| GPRM / SPRM | 16 × u16 / subset per conformance.md | spec |

### ⚠️ BELOW spec / hardcoded common case — the work queue

| # | Item | Ours | Spec allows | Failure mode | Cost |
|---|---|---|---|---|---|
| 1 | **SPU buffer** `spu_decode.SPU_CAP` | 32 KB | **53,220 B**/frame | Silent DCSQ loss → subpicture+highlight invisible. **This exact cap has bitten twice** (8 KB, PR fj#84) | ~+17 M10K (RAM blocks 80%, bits 56% — fits) |
| 2 | **HLI button groups** `nav_pci` | group 1 always | **3 groups by display mode** (4:3/wide/LB), `hl_gi.btngr_ns` | Wrong button rects/links on anamorphic discs played wide — the *button* half of the MiB letterbox-substream lesson (PR fj#115); the display-mode plumbing from that fix already exists | RTL, moderate |
| 3 | **PGCI_UT language unit** | `LU[0]` always | up to 99 LUs, matched by language | Wrong menu PGCs on multi-language discs — looks exactly like past "menu jumps wrong" bugs | RTL, small-moderate |
| 4 | **`ptt_mem`** | 256 entries | `nr_of_ptts` u16; game titles author hundreds | Graceful (HUD/user-skip clamp only; VM `JumpVTS_PTT` resolves on-demand, exact) | +2–3 M10K |
| 5 | ~~Cell-duration clamp~~ ✅ FIXED (Phase 6, 2026-08-19): 16-bit seconds to the C_PBTM max 35,999 s | was 255 s | C_PBTM 9:59:59 | (was: still-shaped cell > 4 min 15 s under-holds) | done |
| 6 | ~~OSD Title override~~ ✅ FIXED (PR fj#175): P1 Debug two-digit picker, VTS 1..99 | was 4-bit | 99 VTS | (was: picker clamps) | done |

### Known feature gaps, deliberately out of scope here

Tracked in `docs/conformance.md` with rationale: **MPEG-1 L2 audio** (common on PAL discs;
demuxer currently discards 0xC0–0xDF — a codec project, not a limit), menu audio, UDF-only
images, UOP masking, NVTMR/SPRM9 fire (libdvdnav doesn't fire it either; census 1/7 discs,
at 999 s), CHG_COLCON.

---

## Phases

Order = evidence first, then fixes ranked by (legal-to-author × blast radius × cost).
**Update the status line of each phase when it lands (the stale-marker rule in CLAUDE.md).**

**Re-ranked 2026-08-18 by the Phase-1 sweeps (local + both NAS collections, 302
discs — see "Phase-1 findings" below): the work order is now
3 → 2 → 5 → 4 → 6(title_sel) → 6(rest).** Phase numbers are kept stable (they are
referenced elsewhere); only the order changed. (Phase 4 was briefly "deferred" on
the local-only evidence; the NAS sweep un-deferred it — 44 multi-LU discs, Hobbit
repro candidate.)

### Phase 1 — `tools/spec_audit.py`: measure the library against OUR limits ✅ DONE (PR fj#167)

The structural answer to "I can't test every disc": a rip-time audit tool that scans an
ISO (or a directory of them) and reports, per disc, every axis where the disc's authoring
approaches or exceeds **this core's implemented limits** — turning "no test disc" into
either "here is the repro disc" or "nothing in N discs authors it, defer with evidence".

Measures (IFO-side, cheap): PTT count per title vs 256; cells with `pbtime > 255 s`;
cells with pbtime ≫ data size (still-shaped, the PR fj#165 class); `nr_of_lus > 1` per
PGCI_UT (+ which languages); command-table sizes vs 128/256; audio attrs per title
(flags MPEG-audio-only titles); PGC/SRP counts (regression-watch for #164).
Measures (VOB-scan, `--deep`): max SPU size per domain vs 32 KB/53,220 B (substreams
0x20–0x3F, size from the SPU's first u16); `hl_gi.btngr_ns > 1` sites + which display
modes; anything with `foac != 0` (forced-activate census).

Build on the existing parsers — do NOT rewrite them: `tools/iso_nav_check.py` (ISO9660 +
IFO walk), `tools/nav_extract.py` (PCI/HLI decode, offsets validated vs nav_types.h),
`tools/spu_dump_iso.py` / `tools/spu_ref.py` (SPU), `tools/dvd_census.py` +
`tools/css_scan.py` (library-sweep + rip pre-flight patterns to follow — spec_audit
should slot next to css_scan as a standard rip-time check).

Deliverables: the tool; a `## Phase-1 findings` section appended BELOW in this doc with
the per-disc table over `$DVD_ISO_DIR/` (the ripper library bulk is
off-machine — the tool must take arbitrary paths/globs so the user can run it there);
re-ranked Phases 2–6 based on what the library actually authors.

### Phase 2 — SPU buffer to the spec maximum (53,220 B) ✅ HW-CONFIRMED + MERGED (PR fj#169)

**Fit gate ✅ (`DVD_spucap_20260819_0030.rbf`): clk_dec 92.59/92.38 MHz (≥ 86 both
corners); RAM 464/553 (84%) = exactly the predicted +20 M10K, block bits 59%,
ALM 88% unchanged. ✅ HW-CONFIRMED 2026-08-19 (user: menus + subpics good).**

**2026-08-19 (PR fj#169):** `SPU_CAP` 32768 → **53,248** (≥ the
53,220 spec max). NOTE the plan's "16-bit addressing already" claim was WRONG — the
pointers were 15-bit (`[14:0]`), so rd/wr pointers widened to 16-bit and the
`[14:0]` truncations of the u16 offsets (`dcsqt_sa`/`w_top`/`w_bot`/`dcsq_next`)
dropped. Improvement over the planned "keep existing overflow semantics": a
malformed > cap unit whose DCSQ start lies beyond the buffer is now DROPPED
CLEANLY into a drain state (released by the next PTS-carrying packet — the unit
boundary rule from the Phase-1 scanner lesson) instead of parsing garbage at an
aliased 15-bit address, and the drain keeps the unit's tail bytes from being
misread as a new unit header. Verified: `spu_decode_tb` + synthetic 53,220 B unit
(tiny bitmap, dead padding, DCSQ at the tail = the twice-bitten shape) decodes
with tail params intact; a 60,000 B over-spec unit drops cleanly keeping the
committed unit; post-drain decode works; 480i render suite green.

**Phase-1 evidence (2026-08-18, 302 discs): no disc anywhere exceeds the 32 KB cap.
High-water mark = 28,556 B (87% of cap), authored TWICE — identical size on Radio and
I Spy title-domain sub 0x27 (both early-2000s Sony; likely the same authoring-house
asset). T2 menus 27,396 B, TR title 21,596 B. Real discs push close, so the spec-max
raise stays queued on the bitten-twice principle. No repro disc: verify with the
synthetic max-size SPU as planned.**

`dvd/spu_decode.sv` `SPU_CAP` 32768 → ≥ 53,220 (16-bit addressing already; keep the
existing overflow-drop semantics for malformed > spec). The DCSQ sits at the SPU's END,
so an overflow drops the whole control sequence — the twice-bitten failure mode (8 KB →
PR fj#84 raised to 32 KB; spec says a disc can legally author 53,220). Verify: extend
`bench/dvd/` SPU tests with a synthetic max-size SPU (bitmap padded to 53,220, DCSQ at
the tail) → decodes; a > 53,220 SPU still drops cleanly. Watch the fit: +~17 M10K on a
444/553-block build — check RAM % + the clk_dec ≥ 86 MHz gate after.

### Phase 3 — HLI button groups by display mode ✅ HW-CONFIRMED + MERGED (PR fj#168)

**Fit gate ✅ (`DVD_btngrp_20260818_2248.rbf`): clk_dec 92.22/88.26 MHz (≥ 86 both
corners); ALM 88%, RAM 444/553, DSP 94/112 — all unchanged vs baseline (the group
logic is register-only).**

**2026-08-18 (PR fj#168):** `dvd/nav_pci.sv` captures
`btngr_ns` + the three `btngrX_dsp_ty` fields (PCI 0x6E/0x6F) through the
pending→committed HLI path and offsets the button-record base to the first group
matching the display verdict (emu `ar_wide_auto_eff` + `sp_disp_mode` — the PR fj#115
signals, as planned). Group 1 fallback = bit-identical v1 behavior for `btngr_ns==1`;
a display-mode change while armed auto-refetches the selected button from the new
group. Verified: `nav_pci_tb` T11–T15 on a real T2 2-group fixture (VTSM RBN 8449,
dsp_ty {wide, letterbox}; group 2 = the ¾+60 letterbox remap) + T1–T10 regression
green (MiB fixture unchanged under the wide default).
**★ HW ROUND 1 (same day): raw-display-mode selection REGRESSED T2 (Letterbox) and
MiB (Crop) menu highlights — split rects. Root cause: display-space groups assume a
display-resolution compositor; this core composites in SOURCE space and scales the
composite, so the aspect transform already covers the highlight. Fix: pair the group
with the RENDERED subpicture variant — menus (stream-0 source-space art) force the
wide verdict = group 1 (the previously HW-correct behavior), in-title keeps the
mode-mapped pairing. See docs/dvd_nav.md "Button groups" for the full mechanism.
**✅ HW ROUND 2 CONFIRMED (2026-08-19, `DVD_btngrp2`): highlights correct across
all discs and all O[4:3] modes (user-verified, incl. the two round-1 regression
cases).**

**Phase-1 evidence (2026-08-18, 302 discs): 230/302 (76%) author `btngr_ns=2` —
local 12/27, sattler NAS 100/122, isos2 NAS 118/152. By far the highest-prevalence
gap, with named repro discs and an HW gate: The Matrix authors it IN-TITLE (TT
VTS_02, the white-rabbit branch, dsp_ty {4:3, wide}), and T2 / MiB (21 menu
domains) / Castle in the Sky / PAW Patrol / Fairytopia (19 title domains) in menus,
overwhelmingly dsp_ty {4:3, letterbox}. NO disc anywhere authors 3 groups (the one
apparent 3-group site — Before the Devil Knows You're Dead, dummy VTS_11 — is junk
HLI bytes: btn_ns=0, fosl=47; the tool now gates the census on btn_ns > 0).**

`dvd/nav_pci.sv`: select the button-record group from `hl_gi.btngr_ns`/`btngr*_dsp_ty`
matching the active display mode (the same 4:3/wide/letterbox verdict that drives the
subpicture substream map from PR fj#115 — reuse that mode signal, don't re-derive). Group
1 stays the fallback (exactly today's behavior when `btngr_ns == 1`, which must be
bit-identical). Verify: `bench/dvd/nav_pci_tb.sv` cases with 2–3 groups + mode switch;
golden fixtures via `tools/nav_extract.py` from any multi-group disc Phase 1 finds
(else synthetic). HW gate only needed if the library has a real multi-group disc.

### Phase 4 — PGCI_UT language-unit selection ✅ HW-CONFIRMED (PR fj#176, 2026-08-19)

**Shipped:** `S_UT_HDR` + new `S_LU_EVAL` walk multi-LU PGCI_UTs matching the
player language against each LU's lang_code — the exact libdvdnav
`get_MENU_PGCIT` rule (getset.c): full-u16 match of SPRM0 (a constant
16'h656E 'en' in `dvd_vm`), **LU[0] on no match**, no wildcard-0xFFFF special
case. Single-LU UTs take the v1 LU[0] path bit-identically (and single-LU is
the arm for the whole scan, so 258/302 discs are untouched by construction).
The UT sector stays resident in `parse_buf` and the whole LU list fits in it
(8 + 99×8 < 2048), so each step is a cheap `S_FETCH` re-shadow — zero extra
sd reads. Verified: new `bench/dvd/iso_reader_lu_tb.sv` (en at LU[2] among
{fr,de,en} with per-unit distinct menus; {fr,es} no-match → LU[0] fallback;
single wildcard-LU → v1 path) + full reader/vm/zerocell regression identical
to main.

**★ Content census (2026-08-19, 149 reachable discs local+sattler; the
"likely a no-op" guess was WRONG):** 17 non-Hobbit multi-LU discs all put
`en` at LU[0] → pick unchanged. **BOTH Hobbit discs now pick the en unit at
LU[1] — and its content genuinely DIFFERS from the wildcard LU[0] unit**
(UNEXPECTED_JOURNEY: 858 differing bytes in the first 4 KB; BONUS: 77;
structures parallel — 8 SRPs at identical offsets — with different PGC
content, i.e. per-language command operands / stream defaults). libdvdnav
picks the en unit on these discs (its VMGM warning in the VLC log was the
1-LU wildcard VMGM, not the VTSM); we now match it. HW gate: both Hobbit
discs' menus (BONUS = the clean pressing, the primary vehicle); any
single-LU disc as a no-change regression. ✅ HW round 1 (2026-08-19): BONUS
selects the correct language unit per Player Language — the ja unit fronts
two authored JIMCA (Japan copyright association) warning cards before its
menu that the en unit does not author, i.e. the per-language content
difference the census measured, rendered faithfully. UNEXPECTED_JOURNEY
still boots to its menu; other discs unchanged.

**Player Language OSD option (same branch, user request):** `O[43:40]
Player Language` (16 languages, default English) drives ONE ISO-639 code
into BOTH consumers — the reader's LU match (`lu_lang_pref`) and
`dvd_vm.cfg_lang`, which now backs SPRM0 (menu language) **and SPRM16/18**
(audio/subtitle preference) — so the LU pick and the disc's own
language-reading nav commands can never disagree, and discs that
auto-select streams from SPRM16/18 (the Hobbit trampoline's
`g3 = SPRM16; if g3=='fr'…` pattern) honor the setting too. Takes effect
at the next menu jump / mount. `iso_reader_lu_tb` T4: switching the
preference to 'de' picks the de unit over both fr and en.

**Fit (`DVD_luselect_20260819_1556.rbf`): clk_dec 91.84/91.29 MHz both
corners ✅ (gate ≥ 86); ALM 89 % (+252 for the LU walk + language LUT),
M10K/DSP unchanged.**

*(Original queued-phase notes below, kept for the evidence trail.)*

**Phase-1 evidence (2026-08-18): the local library had 0 multi-LU discs, but the NAS
collections have 44/274 (`multi_lu` axis). 42 of them put `en` at LU[0] (benign for
LU[0]-always today), but BOTH Hobbit discs author LU[0] with language code 0xFFFF
(a no-specific-language wildcard) and the real `en` unit at LU[1] — the named repro
candidates for "LU[0] picks the wrong unit". Worth an HW check of Hobbit's menus
before the RTL work to see whether the wildcard LU differs.**

**★ Hobbit HW check round 1 + off-line triage (2026-08-19) — the LU work is
BLOCKED behind a new black-video investigation.** On the board
`THE_HOBBIT_UNEXPECTED_JOURNEY_20260809_152912.iso` (sattler NAS) shows only
"mostly black with a few scattered colored macroblocks"; VLC refuses the ISO;
mpv plays it only as a flat file (back-to-back multilanguage warning cards, no
menus — expected for flat-file playback, mpv has no nav there). Full off-line
triage says **the rip is CLEAN — this is NOT a bad rip**:
- `tools/css_scan.py`: CLEAN (7,501 PES sampled, 0 scrambled). Proper dd-style
  UDF-bridge image (CD001 + BEA01/NSR02 + AVDP@256); ripper meta: 0 errors,
  ISO size == disc size.
- The ripper's own screenshots (extracted from THIS iso via the IsoNav extent
  map — the same math the RTL uses) decode perfectly, including a mid-movie
  frame. All four domains (VMGM, VTS_01 M+TT, VTS_02, VTS_03) probe as
  bog-standard 720×480 MPEG-2 Main + AC-3.
- `iso_nav_check`: ISO9660 walk fine, Auto → VTS_01 (7.7 GB, 8 VOBs), title
  PGC1 = 34 physically-monotonic cells, no interleave. `trace_boot`
  (libdvdnav oracle): FP → JumpTT 4 → VTS_03 PGC1 = a warning clip; chain OK.
- `ps_chain_tb` on 100 real sectors of BOTH the title VOB (RBN 0) and the
  VTS_03 boot clip: demux bit-exact, AC-3 frames clean. The demux layer is
  exonerated.
So every predictor is green and the failure is downstream of the demux or in
runtime delivery.

**★ HW round 2 discriminator (user, 2026-08-19): with `O[1] Disc Menus = OFF`
the disc Auto-selects the film title and plays PERFECTLY (same NAS source).**
That kills the delivery/CIFS theory outright (same path, same data) and
exonerates every shared layer: ISO parse, VTS select, extent walk, streaming,
demux, decode, display. **The bug lives exclusively in the menus-ON boot
chain** — the screen showing black + scattered macroblocks (= the
uninitialized framebuffer) means the VM/reader wedged before ANY video
streamed, i.e. at or shortly after the First Play dispatch.

**★★ ROOT CAUSE FOUND (2026-08-19, round 3): THE PRESSING IS DEFECTIVE —
the IFOs reference ZERO-FILLED regions as playable cells.** The "why does
VLC fail too?" question cracked it: VLC 3.0.23 run locally against the ISO
reproduces the user's failure, and its log names the class — right after the
boot jump its demux reads **`00 00 00 (should be 0x000001)`** (literal
zeros), then tears down and restarts in an endless loop ("won't load").
An extent-aware census of every title cell against the actual sector content
confirms the disc:
- VTS_01 TT PGCN 1 (the movie): **17 of 34 cells point at zeros** — real
  data ends ~RBN 1.1 M (≈ the first 2 GB ≈ cells 0-9 ≈ chapters 1-10), then
  ~3.3 GB of the image is literal zero-fill with scattered real patches.
- VTS_01 TT PGCN 2 and PGCN 3: **every cell zero-backed** — and PGCN 3 is
  in the authored boot chain (VTSM PGC1 pre `JumpVTS_TT 3`).
- VTS_02 + VTS_03 (warning titles): last cell of each zero-backed.
- All VMGM/VTSM *menu* cells are real.
The rip is a faithful copy of a bad disc (ripper: zero read errors; css_scan
CLEAN; the zeros are on the pressing — bootleg padding, matching the
"Asian copy"/INTERPOL-card presentation). Every consumer then fails in its
own way: **VLC** follows nav → reads zeros → demux-error restart loop;
**our RTL** wedges black in the boot chain (which routes through zero-backed
cells); **metadata-only traces** (`trace_boot`, `dvd_vm_ref`) sail through
because they never read sector data; **mpv flat-file** ignores nav and plays
whatever real data exists in mux order. Menus-off "plays perfectly" because
the movie's first ~2 GB is real — **prediction: it dies around chapter 11**
(cell 10 = the first zero cell; a 2-second chapter-skip test on HW confirms).

Actionable follow-ups:
1. **Robustness hardening — ✅ RESOLVED as a VM NAV BUG, not a zero-cell
   hardening job — ✅ HW-CONFIRMED (PR fj#175, 2026-08-19: menus-On now boots
   through the warnings to a fully-working menu).** The full boot chain rebuilt in sim over a synthetic ISO with
   the disc's REAL command bytes + zero-backed cells
   (`bench/dvd/iso_reader_zerocell_tb.sv`) reproduced the black screen and
   pinned it: **the zero cells stream through the pipeline harmlessly** (the
   reader is content-agnostic, ps_demux discards non-PES bytes) — the wedge
   was the VTSM pre's `JumpVTS_TT 3` dispatching with the STALE
   last-played-title VTS (`cur_vts`=3, the warning) instead of the menu's
   own (`vm_vts`=1), so the g6=1 settings-trampoline never ran and the boot
   ping-ponged VMGM ⇄ VTSM ⇄ warning forever. FIX: `JumpVTS_TT`/`JumpVTS_PTT`
   now use the domain-dependent `link_jump_vts` (the PR-fj#145 rule); the
   `JumpSS_VTSM` vts==0 stale-`vm_vts` quirk (documented in dvd_nav.md,
   fallback title replay) is retired by the same rule. Full detail:
   `docs/dvd_vm.md` "Menu-domain JumpVTS_TT". Regressions: `dvd_vm_tb`
   S19/S20 (real blocks, golden-model exact) + the zerocell chain TB + the
   `iso_reader_vm_tb` fixture made honest (it had silently relied on the
   quirk). With the fix the disc boots to its (real-data) menu and plays
   what exists — the movie still dies at its zero region (~chapter 11), as
   it must. HW round 3 detail, fully explained: the boot shows ~2 s of a
   macroblocky WB logo first — the warning clips themselves are hollow on
   this pressing (VTS_03 = 93 % zero sectors, VTS_02 = 96 %; only their
   heads are real — the earlier census checked first-sectors only), so the
   decoder renders the 6 % of bitstream that exists. The menu VOB scans
   100 % real. A set-top player would show the same garbage seconds. **Fit (`DVD_hobbitboot_20260819_1425.rbf`): clk_dec 86.82/87.11
   both corners ✅ (gate ≥ 86); ALM 89 % (+47 for the debug picker), M10K
   467 unchanged, DSP 94 unchanged.**
2. **Phase 4 vehicle switch:** `THE_HOBBIT_PART_1_BONUS_DISC` censuses
   CLEAN (84/84 title cells real-backed) and also authors wildcard-0xFFFF
   LU[0] — use IT for the LU work. Evidence so far (golden model + VLC both
   land the correct menu through the wildcard unit) says the LU fix is
   likely a verify/no-op.
3. **title_sel debug-picker rider (shipped with #1, per the user decision):**
   the main-page `O[31:28] DVD Title` option is retired (bits left dead one
   release, the O[14] pattern) and replaced by a P1 Debug two-digit picker
   (`P1O[35:32]` tens / `P1O[39:36]` units → VTS 1..99, 0/0 = Auto);
   `title_sel` widened 4→7 bits through emu + the reader. Reaches VTS_16+
   on the ~9 % of the library the old 4-bit option could not (Atmosfear 75).

`dvd/dvd_iso_reader.sv` `S_UT_HDR`: walk the LU list matching a preferred language
(2-byte ISO-639 from an OSD option or fixed "en" first pass; SPRM0 already exists in
the VM) with LU[0] fallback (today's behavior when no match / one LU). Verify:
`iso_reader_menu_tb` fixture with 2 LUs; Phase-1 census says which library discs
author `nr_of_lus > 1` and whether LU[0] was ever wrong for them.

### Phase 5 — `ptt_mem` 256 → 1024 ✅ HW-CONFIRMED + MERGED (PR fj#170)

**2026-08-19 (PR fj#170):** `PTT_CAP` 256 → 1024 (`ptt_mem`
1024 × 24, pointers 8→10-bit, `nr_ptt` 9→11-bit through the reader and emu's
`nr_ptt_w`). 1024 covers the JumpVTS_PTT operand's full 10-bit range; a
hypothetical > 1024 title still clamps gracefully. The HUD "CH n/N" total keeps
its 8-bit display clamp at 255 (cosmetic format limit, noted in emu). Verified:
`iso_reader_ptt_tb` grew a 400-PTT title (the Scene_It class — loads fully past
the old cap, TTU spans sector boundaries) and an 1100-PTT title (clamps at 1024
with the tail entry intact); full reader regression green (chapter, menu, seek,
ifo, celldur, angle, linkptt, vm).

**★ Fit finding (`DVD_pttmem_20260819_0101.rbf`, clk_dec 89.69/88.65 ✅): the
resident PTT table was DEAD LOGIC — `ptt_raddr` was never driven and `ptt_rd_q`
never read, so Quartus swept the whole BRAM (zero RAM delta; true of the
256-entry version too — the table had NEVER existed in silicon).** It was built
(Phase 6, PR fj#127) for a cross-PGC user-skip / HUD reverse map that was never
wired; user chapter skip resolved via the program map, within-PGC only. This
phase therefore shipped the widened `nr_ptt` count path + LATENT zero-cost
capacity. ✅ HW-CONFIRMED 2026-08-19 (regression pass — no behavior change possible).

**Follow-up — cross-PGC chapter skip through `ptt_mem` — ✅ HW-CONFIRMED +
MERGED (PR fj#171, 2026-08-19: Scene_It skip crosses PGC boundaries on the
board; movie-disc skip/HUD unchanged).** The
`ptt_mem` read side is wired: new `chap_st` states (`CH_G0/CH_G/CH_GR/CH_T/CH_T2`)
reverse-map `{cur_pgcn, program} → global chapter` (one entry/cycle, sync-read —
fit discipline) for both the HUD `CH n` (now the GLOBAL PTT index, consistent with
the `nr_ptt` total) and the B2/B3 skip; a target leaving the current PGC
dispatches an internal JumpVTS_PTT-shaped jump (`jttn=cur_ttn`, `jptt=target+1` —
the existing `S_PTT_*`/`want_pgcn`+`jpgn_l` machinery; user action ⇒ immediate,
full seek-flush contract). The within-PGC program-map path is kept bit-identical
(single-PGC movie titles take it structurally). `jptt_l` widened 10→11 bits
(internal chapter-1024 reach). On Scene_It (798 PTTs across 241 PGCs) and
PNP0NNS1 (369) B2/B3 could never leave the current PGC before. Verified:
`iso_reader_ptt_tb` T-I..T-P (path-asserted seek-vs-jump, boundary crossings both
ways, end clamps, prev-restart, mag clamp, single-chapter no-arm, global HUD);
full reader regression green (atmos/tpsw_boot pre-existing fails only). **Fit
(`DVD_xpgcskip_20260819_0158.rbf`): the table finally EXISTS in silicon —
`ptt_mem_rtl_0` = 1024×24 simple-dual-port, exactly +3 M10K (464 → 467/553);
clk_dec 93.5/93.61 MHz both corners ✅ (gate ≥ 86); ALM 89 %, DSP unchanged
94/112.** Detail: `docs/dvd_nav.md` Phase 6 "Resident PTT table". HW gate:
Scene_It chapter skip crosses PGC boundaries; a movie disc's chapter skip and
HUD unchanged.

**Phase-1 evidence (2026-08-18): TWO discs exceed the cap — Scene_It title 1 authors
798 PTTs and PNP0NNS1 (sattler NAS) authors 369 (the sweeps' only hard EXCEEDS;
degradation stays graceful: HUD/user-skip clamp; VM JumpVTS_PTT resolves exactly).
Tomb Raider sits exactly AT the 256 cap. 1024 covers all with headroom.**

`dvd/dvd_iso_reader.sv`: PTT_CAP/addr widths 8→10-bit, +3 M10K. Purely capacity; the
clamp today is graceful, so this rides on Phase-1 evidence (any library title > 256
PTTs?). Extend `iso_reader_ptt_tb` / `iso_reader_chapter_tb` with a > 256-PTT fixture.

### Phase 6 — conditional leftovers ✅ BOTH DONE (cell-duration: HW-CONFIRMED PR fj#177)

`title_sel` width: ✅ shipped as the P1 Debug "Title VTS" picker (PR fj#175).

**Cell-duration clamp ✅ HW-CONFIRMED + MERGED (PR fj#177, 2026-08-19 —
no-regression gate passed on the board; census still 0/302 repro discs,
`spec_audit` remains the tripwire for the >255 s positive path).** The whole duration
chain widened 8→16-bit to the C_PBTM spec max 9:59:59 = **35,999 s**:
`pb_c` (full hh·3600 term — the old code clamped ANY-hours to 255),
`cell_secs`, `dur_resid`, `still_secs`, `RESID_MIN`, and the cell-meta BRAM
word (24→33 bits: `{heur, pb_secs[15:0], still, cmd_nr}` — the still-byte and
cmd_nr positions unchanged). Two bonus fixes fell out:
- **heur flag**: a heuristic (libdvdnav playback-time) still now stores a
  flag so the timed-still hold uses the FULL 16-bit duration; the still BYTE
  clamps at 254 — which also fixes a latent alias where a 255 s heuristic
  cell would have parked as an INDEFINITE (0xFF) still.
- `spec_audit.py` axes refreshed: `pbtime_clamp` threshold 255→35,999 (an
  EXCEEDS now means illegal BCD authoring) and the stale `title_sel` 15→99
  (MEN_IN_BLACK now audits fully PASS).
Verified: `iso_reader_celldur_tb` T5–T7 (a heur-shaped **600 s** still holds
the full duration via the flag; C_PBTM **9:59:59** captures as exactly
35,999 s in the meta; 16-bit PGC-end residual end-to-end) + T1–T4 untouched
(the HW-proven Weakest Link shapes, bit-for-bit) + full reader/vm/zerocell
regression identical to main. HW gate: WL answer window + Thayer choices
unchanged (the machinery below 255 s, board-testable).
**Fit (`DVD_celldur16_20260819_1720.rbf`): clk_dec 90.34/87.21 MHz both
corners ✅ (gate ≥ 86); ALM 90 % (+54), M10K 467 unchanged (the 33-bit meta
word rides the M10K's native x36 width, as predicted), DSP unchanged.**

**Phase-1 evidence (2026-08-18, 302 discs):**
- **`title_sel` widening: PROMOTED (5th in line, trivial).** 26/302 discs have > 15 VTS
  (Atmosfear 75, Cluedo 35, WL 29, TR 25, Fairytopia 24, …) — the manual OSD picker
  can't reach VTS_16+ on ~9% of the library. Auto unaffected.
- **Cell-duration clamp > 255 s: library-clean, DEFERRED.** Most discs author
  data-backed cells > 255 s (harmless — the cell ends at data exhaustion,
  `dur_resid` ≈ 0), but **zero of 302** author a still-shaped cell > 255 s, which is
  the only case that under-holds. The audit flags a future one as EXCEEDS
  `pbtime_clamp` automatically.

---

## Working rules for these phases

- One phase per PR, branch `feature/spec-audit-tool`, `feature/spu-spec-cap`, … Update
  THIS doc's phase status lines + `docs/conformance.md` rows in the same PR (the
  stale-marker rule). RTL phases: full reader/nav/spu TB regression + a release build
  (`USE_DOCKER=1 ./build_release.sh --compile --name DVD_<phase>`), clk_dec ≥ 86 MHz
  both corners, note ALM/M10K deltas here.
- Known pre-existing TB failures on main (NOT regressions, 2026-08-18):
  `iso_reader_atmos_tb` (PGC13 not loaded), `iso_reader_tpsw_boot_tb` (VMGM PGC1
  nr_pre) — fail identically before and after; don't chase them inside these phases.
- The spec numbers above cite *DVD Demystified* + `ifo_types.h`; anything new should
  cite its source the same way (the three-layer oracle discipline, conformance.md).

---

## Phase-1 findings (2026-08-18, PR fj#167)

Sweep: `tools/spec_audit.py --deep $DVD_ISO_DIR/` — 27 discs, ~2 min
(IFO-side alone is < 1 s for the whole library). The bulk ripper library is
off-machine; the tool takes arbitrary paths/globs, so re-run it there and append a
second table when convenient. **Run `tools/css_scan.py` first** — the deep scan
assumes a decrypted rip (FAIRYTOPIA's current raw rip scanned anyway, but its VOB
numbers are untrustworthy until re-ripped).

Tool self-checks passed before trusting the sweep: WL VTS_02 = 1394 PGCs (PR fj#164),
WL VTS 8 PGC 51 cell 0 = 17 s / 311 sectors / cmd 1 (PR fj#165), and the T2 menu SPUs
that broke the 8 KB cap (PR fj#84) appear in `--deep` (23,908 B scene-range +
8,640 B mission-profiles; domain max 27,396 B).

### Per-disc table

Columns: max PTTs in any title (cap 256); max PGCs in any PGCIT (8-bit would break
> 255); max commands in any PGC (cmem 512, spec 128/block); still-shaped (held)
cells; largest SPU found by `--deep` (cap 32,768 / spec 53,220); domains authoring
`btngr_ns > 1`; NAV packs with `foac != 0`.

| Disc | Verdict | VTS | max PTT | max PGCs | max cmds | still cells | max SPU (domain) | btngr>1 doms | foac |
|---|---|---|---|---|---|---|---|---|---|
| 24_DVD_BOARD_GAME | WARN | 22 | 76 | 86 | 46 | 0 | 5220 B (TT VTS_19) | 0 | 0 |
| ATMOSFEAR_NTSC | WARN | 75 | 29 | 84 | 109 | 97 | 11764 B (VTSM VTS_01) | 1 | 0 |
| Akira (1988) | WARN | 4 | 37 | 34 | 118 | 15 | 5408 B (TT VTS_04) | 1 | 0 |
| CASTLE_IN_THE_SKY | WARN | 10 | 13 | 24 | 24 | 46 | 4292 B (TT VTS_02) | 2 | 0 |
| CASTLE_USD2 | WARN | 1 | 13 | 8 | 12 | 7 | 1372 B (VMGM) | 2 | 0 |
| CLUE | WARN | 2 | 15 | 19 | 8 | 24 | 5524 B (VTSM VTS_01) | 1 | 0 |
| Cluedo_AUS_PAL | WARN | 35 | 166 | 166 | 107 | 242 | 4268 B (VMGM) | 0 | 0 |
| DMDC8200_THREE_TENORS | PASS | 2 | 17 | 4 | 31 | 8 | 2868 B (VMGM) | 0 | 0 |
| ELMOPALOOZA | PASS | 1 | 12 | 9 | 23 | 38 | 4912 B (TT VTS_01) | 0 | 0 |
| FAIRYTOPIA ⚠raw rip | WARN | 24 | 97 | 32 | 106 | 2 | 5232 B (TT VTS_16) | 19 | 0 |
| FAMILYFEUDII | WARN | 25 | 235 | 78 | 46 | 3727 | 2164 B (VTSM VTS_01) | 0 | 0 |
| Harry Potter HOGWARTS | WARN | 21 | 6 | 223 | 128 | 399 | 7596 B (TT VTS_09) | 0 | 0 |
| MEN_IN_BLACK | WARN | 21 | 27 | 11 | 71 | 1229 | 8752 B (VTSM VTS_03) | 21 | 0 |
| PAW_PATROL_MEET_EVEREST | WARN | 5 | 8 | 14 | 28 | 11 | 1752 B (VTSM VTS_02) | 2 | 0 |
| ROGER_WATERS_IN_THE_FLESH | WARN | 3 | 26 | 7 | 39 | 58 | 8386 B (VTSM VTS_02) | 1 | 0 |
| SCENEIT_HP | PASS | 6 | 80 | 57 | 106 | 92 | 3916 B (VMGM) | 0 | 0 |
| SCENEIT_JR | PASS | 4 | 90 | 39 | 32 | 14 | 1736 B (VMGM) | 0 | 0 |
| SPEED RACER CRUCIBLE | PASS | 5 | 52 | 16 | 121 | 28 | 5298 B (TT VTS_05) | 0 | 0 |
| Scene_It | **EXCEEDS** | 7 | **798** | 243 | 127 | 214 | 6682 B (VTSM VTS_03) | 0 | 0 |
| THEBRAINGAME | PASS | 9 | 185 | 41 | 9 | 662 | 7060 B (TT VTS_02) | 0 | 0 |
| THE_MATRIX_16X9LB | WARN | 3 | 99 | 19 | 54 | 41 | 7092 B (VTSM VTS_02) | 2 | 0 |
| TP_SW_DVD_1 | PASS | 1 | 56 | 131 | 46 | 270 | 4660 B (VTSM VTS_01) | 0 | 0 |
| TP_SW_DVD_2 | PASS | 1 | 56 | 131 | 46 | 271 | 4660 B (VTSM VTS_01) | 0 | 0 |
| Thayer's Quest | PASS | 11 | 63 | 23 | 134 | 348 | 10126 B (TT VTS_01) | 0 | 1 |
| ULTIMATE_T2 | WARN | 5 | 81 | 34 | 127 | 158 | **27396 B** (VTSM VTS_01) | 1 | 0 |
| WEAKEST_LINK_DES | WARN | 29 | 29 | **1394** | 128 | 1220 | 4686 B (TT VTS_21) | 0 | 0 |
| tomb_raider_pal | WARN | 25 | 256 | 256 | 96 | 141 | 21596 B (TT VTS_03) | **46** | 0 |

Axis prevalence (discs flagging each / 27): data-backed cells > 255 s **15**,
`btngr_ns > 1` **12**, > 15 VTS (`title_sel` reach) **9**, > 255 PGCs (PR fj#164
class) **2** (WL 1394, TR 256), PTTs > 256 **1** (Scene_It), `foac != 0` **1**
(Thayer's Quest), multi-LU **0**, MPEG-audio-only titles **0**, cells > MAXCELL
**0**, commands > cmem **0**, still-shaped cells > 255 s **0**.

### What the sweep changes (the re-rank)

1. **Phase 3 (HLI button groups) is now first.** 12/27 discs author `btngr_ns = 2`
   — by far the widest real exposure, and it includes our standard test vehicles:
   The Matrix authors it **in-title** (TT VTS_02 = the white-rabbit branch, dsp_ty
   {4:3, wide} — the icon-substream half of this was PR fj#113/#115; the *button*
   half is live), MiB authors it across 21 menu domains, T2/Castle/PAW in menus.
   HW gate: play a 16:9 disc with the display mode set to wide vs 4:3 and confirm
   the highlight rectangles move to the right group's coordinates.
2. **Phase 2 (SPU spec max) second.** Library-clean vs the 32 KB cap, but T2 menus
   reach 84% of it — the class keeps growing; do the cheap raise, verify synthetic.
3. **Phase 5 (`ptt_mem`) third — repro disc found.** Scene_It 798 PTTs (only hard
   EXCEEDS in the sweep); TR sits exactly at 256.
4. **`title_sel` widening promoted out of Phase 6 (fourth, trivial).** 9/27 discs
   are unreachable by the manual picker past VTS_15.
5. **Phase 4 (LU selection) deferred on evidence** — zero multi-LU discs.
6. **Cell-duration clamp deferred on evidence** — zero still-shaped cells > 255 s
   (all 15 discs' > 255 s cells are data-backed = clamp harmless).

Bonus census: WL authors **exactly 128 pre-commands** (the spec's per-block max) and
Thayer's VMGM PGC 6 totals 134 commands — both comfortably inside cmem 512;
Thayer's Quest is the library's only `foac != 0` author (forced-activate buttons),
consistent with its FMV branch-choice authoring.

### NAS library sweeps (2026-08-18, same day — 275 more discs, ~2 TB deep-scanned)

Two ripper-fed collections measured with the same tool: **sattler NAS**
(`/mnt/sattler/games/DVD/`, 122 discs, 2.5 GbE, ~170 MB/s) and **isos2**
(sshfs, 153 discs, 1 GbE, ~118 MB/s), swept in parallel on separate NICs.
IFO-side for both took seconds; the deep scans ~2 h each. Raw JSON vectors kept in
the session scratchpad; re-run any time with
`tools/spec_audit.py --deep <path>`. Two isos2 discs hit sshfs I/O errors mid-read
(CHEERLEADER_NINJAS all-over, DCU_JUSTICE_LEAGUE_WAR deep-only) — re-scan those
after checking the rips.

**Two scanner bugs were found and fixed against this data (both in PR fj#167):**

1. **SPU unit boundaries must key on the PES PTS flag, not byte count.** The first
   sattler sweep reported five title-domain SPUs of 53–59 KB (above even the spec
   max). All fake: an SPU truncated at a cell/ILVU boundary desyncs a byte-count
   tracker, and mid-unit bytes get read as a giant SPDSZ. Real units always START
   in a PTS-carrying PES (the marker ffmpeg/VLC use). Proven on Robin Hood: the
   "59,785 B unit" had garbage DCSQ chains and no PTS; after the fix its real title
   max is 4,518 B (40 truncated units detected — the desync sites). T2 ground truth
   unchanged (trunc=0). `tools/spu_ref.py extract_unit` shares the weakness when a
   scan window opens mid-unit — fine for its menu diagnostics, noted for the record.
2. **Junk-HLI packs must not count as button evidence.** Before the Devil Knows
   You're Dead carries NAV-shaped packs in a dummy VTS with `hli_ss=1` but
   `btn_ns=0`, `fosl=47` (invalid), garbage rects — they faked the library's only
   `btngr_ns=3` site. The census now requires `btn_ns > 0`.

**Corrected aggregates (local 27 + sattler 122 + isos2 152/153):**

| Axis | Local | sattler | isos2 | Verdict |
|---|---|---|---|---|
| `btngr_ns=2` discs | 12/27 | 100/122 | 118/152 | **76% of the library — Phase 3 confirmed first** |
| `btngr_ns=3` | 0 | 0 | 0 (1 junk) | nobody authors 3 groups |
| max SPU | 27,396 (T2) | **28,556** (Radio) | **28,556** (I Spy) | 87% of cap, 0 EXCEEDS in 302 |
| multi-LU discs | 0 | 18 | 26 | 44 total; **Hobbit ×2 author wildcard-0xFFFF LU[0]** = Phase-4 repro |
| PTTs > 256 | Scene_It 798 | PNP0NNS1 369 | 0 (max 202) | 2 repro discs for Phase 5 |
| > 255 PGCs/PGCIT | WL 1394, TR 256 | PNP0NNS1 282 | Benchwarmers 298 (**VTSM!**) | PR fj#164 class incl. a MENU domain |
| `foac != 0` discs | Thayer | 8 | 9 | 18 total (Right Stuff: 212 packs/disc) |
| still-shaped > 255 s | 0 | 0 | 0 | Phase-6 clamp stays deferred |
| MPEG-audio-only titles | 0 | 0 | 0 | gap stays theoretical for this library |
| > 15 VTS (`title_sel`) | 9 | 5 | 12 | 26 discs unreachable by the manual picker |

Notable singles: the 28,556 B SPU maximum appears at the **identical size on two
different early-2000s Sony discs** (Radio, I Spy — title-domain sub 0x27), so it is
one authoring-house asset, not coincidence. Benchwarmers' 298-PGC VTSM (478 PGCs /
8,918 menu commands across the disc) is a generated GPRM state-machine authoring
style — Sony menu webs run 3–10× other studios in every era (MiB 1997 already has
97 menu PGCs), Benchwarmers is just its extreme; the >255-PGC lesson now provably
reaches menu domains.
