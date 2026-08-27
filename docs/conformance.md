# DVD-Video Conformance Matrix

**Purpose.** This is the durable "what's correct / what's missing" map for making the core
play the *general* DVD catalog, not just our test discs. It enumerates the DVD-Video state
machine (VM, IFO tables, in-stream NAV) and marks each feature *implemented / partial /
missing* against our RTL, with the trusted reference for each row. New sessions execute
against this file; keep it current when a gap closes (same discipline as `docs/roadmap.md`).

Strategy background & rationale (three-layer oracle, issue taxonomy A/B/C, corpus tooling)
is summarized in [§ How to use the reference oracles](#how-to-use-the-reference-oracles)
below and cross-linked from `docs/roadmap.md`.

---

## How to use the reference oracles

Do **not** treat any single source as authoritative — verify in increasing order of authority
and cost. **"libdvdnav does X" is a hypothesis to verify, not a conclusion** (we have already
beaten libdvdnav *and* VLC empirically — the Matrix white-rabbit / seamless-branch ILVU fix,
PR fj#112).

1. **libdvdnav + libdvdread** — `$DVD_REPOS/{libdvdnav,libdvdread}`.
   Executable baseline & regression oracle; covers the common bulk. Every `FIXME`/`XXX`/`HACK`/
   `?? ` region is **untrusted** — see [§ Reference-suspect regions](#reference-suspect-regions).
2. **Independent format docs** (a second reverse-engineering that did not inherit libdvdnav's bugs):
   - *Semantic / "what is the correct behavior"* → **Jim Taylor, *DVD Demystified***, at
     `dvd_repos/DVD_Demystified.pdf` (468 pp; `Read` it for the diagrams) +
     `dvd_repos/DVD_Demystified.pages.txt` (page-anchored OCR, grep-searchable). It is a
     *semantic* oracle — byte-level mnemonics like `SPRM` return 0 hits; it explains behavior,
     hierarchy, and intent, not offsets.
   - *Byte-level / "is our parser at the right offset"* → `libdvdread/src/dvdread/ifo_types.h`
     & `nav_types.h`, plus mpucoder "DVD-Video Information" pages and ECMA-167 (UDF layer).
3. **Real hardware DVD player + author intent** — final tie-breaker for the residual where
   reference and docs are wrong or silent (the white-rabbit class). Irreducibly empirical;
   this is our curated HW regression set.

### Finding a topic in *DVD Demystified* (verified recipe)
`DVD_Demystified.pages.txt` carries a form-feed (`\f`) before each page, and the grep-page
maps **exactly** to the PDF page (offset = 0, verified 2026-07-13). To get the page for a term:

```bash
cd $DVD_REPOS
awk -v term="seamless branching" 'BEGIN{p=1}
  { if (index(tolower($0),tolower(term))>0){print "PDF page "p; exit} }
  {p+=gsub(/\f/,"")}' DVD_Demystified.pages.txt
```

Then `Read dvd_repos/DVD_Demystified.pdf pages "<p-1>-<p+1>"` for the figures (read a small
window; a handful of image-only pages emit no `\f`, so allow ±1). Regenerate the index with
`pdftotext DVD_Demystified.pdf DVD_Demystified.pages.txt` if the PDF is ever replaced.

---

## Legend

| Mark | Meaning |
|---|---|
| ✅ | Implemented + HW-confirmed |
| 🟡 | Partial / approximate — works for common discs, known simplification |
| ❌ | Not implemented |
| ⛔ | Deliberately retired / will-not-build (user decision) |
| ⚠️ | Reference itself is suspect here — verify against layer 2/3 before trusting libdvdnav |

RTL under test: `dvd/dvd_vm.sv`, `dvd/dvd_iso_reader.sv`, `dvd/nav_pci.sv`, `dvd/nav_dsi.sv`.
Golden models: `tools/dvd_vm_ref.py`, `tools/iso_nav_check.py`, `tools/nav_extract.py`.

---

## 1. DVD-VM interpreter

Reference: `libdvdnav/src/vm/{decoder.c,vm.c,vmcmd.c,getset.c,play.c}`. Our impl: `dvd/dvd_vm.sv`
(golden `tools/dvd_vm_ref.py`). Semantic behavior: *Demystified* ch. "DVD-Video" (VM / commands).

### 1.1 Command instruction types (`decoder.c:660 eval_command`, 3-bit selector)

| Type | Meaning | Status | Notes |
|---|---|---|---|
| 0 | Special (NOP / Goto / Break / SetTmpPML+Goto) | 🟡 | SetTmpPML (parental) is a no-op accept (see 1.5) |
| 1 | Link / Jump-Call (bit60 selects) | ✅ | |
| 2 | SetSystem (+ opt link) | ✅ | |
| 3 | SetGPRM (+ compare or link) | ✅ | |
| 4 | Set → Compare → LinkSub | ✅ | compare AFTER set (per vmcmd.c) |
| 5 | Compare → (Set + LinkSub) | ✅ ⚠️ | **libdvdnav `decoder.c:703` marks its own 5 "wrong"** — we follow `vmcmd.c`, on-disc-validated. Do not "fix" toward decoder.c. |
| 6 | Compare → Set, always LinkSub | ✅ ⚠️ | as above (`decoder.c:711`) |

### 1.2 Link / Jump / Call commands

| Command group | Status | Notes |
|---|---|---|
| LinkNoLink/TopC/NextC/PrevC/TopPG/NextPG/PrevPG/TopPGC/NextPGC/PrevPGC/GoUpPGC/TailPGC | ✅ | TailPGC→POST dispatch = MiB "Play" |
| LinkRSM (resume) | ✅ | CallSS saves, LinkRSM restores SPRM4-8 + cell |
| LinkPGCN / LinkCN | ✅ | same-PGCIT menu jump |
| LinkPTTN / LinkPGN | ✅ | light in-PGC program link first; a LinkPTTN part overflowing the PGC falls back to the exact cross-PGC `VTS_PTT_SRPT` resolve (PR fj#145) |
| JumpTT (via TT_SRPT → SPRM5) | ✅ | reader `S_TT_RES/S_TT_RES2` resolves vts_ttn |
| JumpVTS_TT / JumpVTS_PTT | ✅ | exact `VTS_PTT_SRPT[ttn][part-1] → {pgcn,pgn}` (Phase 6, `S_PTT_*` + `jump_ptt`); was ptt≈pg |
| JumpSS_FP / VMGM_MENU / VTSM / VMGM_PGC | ✅ | MiB trampoline verified (PR fj#80/#84) |
| CallSS_FP / VMGM_MENU / VTSM / VMGM_PGC (w/ resume cell) | ✅ | |
| Exit | 🟡 | stops; no player-level "eject"/auto-stop semantics |

### 1.3 Compare & set-op ALU

| Group | Reference | Status |
|---|---|---|
| Compare ops `& == != >= > <= <` | `decoder.c:290 eval_compare` | ✅ |
| Set ops `= <-> += -= *= /= %= rnd &= |= ^=` (saturating add/mul, clamp-0 sub, ÷0→0xFFFF) | `decoder.c:561 eval_set_op` | ✅ (LFSR16 rnd, **entropy-seeded at mount + stirred by user-input timing** — libdvdnav does `srand(usec)`, `dvdnav.c:200`; bit-exact vs `dvd_vm_ref.py` for a fixed seed) |

### 1.4 System registers (SPRM0–23) — `vmcmd.c:65 system_reg_table`

| SPRM | Name | Status | Notes (our `dvd_vm.sv` sprm_read) |
|---|---|---|---|
| 0 | Menu language | 🟡 | constant `'en'` |
| 1 | Audio stream # | ✅ | SetSTN → `sprm_astn` → **logical→physical resolution through PGC `audio_control`** (`dvd/aud_stream_map.sv` = `vmget.c` `vm_get_audio_stream` + the `vm_get_audio_active_stream` first-available fallback; menus force logical 0; deviation: an all-unavailable title map resolves to identity, not −1/silence) → demux mux. 2026-08-27, `fix/menu-link-audio-map`; see `docs/track_selection.md`. |
| 2 | Subpicture stream # | ✅ | SetSTN → `sprm_spstn` (bit6 = display enable) |
| 3 | Angle # | 🟡 | stored; angle *block* selection is via B6 gamepad + DSI, not VM-driven (Phase 9) |
| 4 | Title track # | ✅ | |
| 5 | VTS title track # | ✅ | JumpTT resolved |
| 6 | VTS PGC # | ✅ | |
| 7 | PTT # | 🟡 | tracks program (see LinkPTTN) |
| 8 | Highlighted button # | ✅ | shadows live nav_pci selection while armed (`sprm8_eff`) |
| 9 | Navigation timer | 🟡 ⚠️ | stored, **never fires** — and **libdvdnav doesn't fire it either** (`decoder.c:527` stores SPRM9/10, the "Stop SPRM9 Timer" lines in `vm.c` are comments with no timer code). Census: 1/7 discs set it, at 999 s (never fires in practice). Un-referenced → deferred. |
| 10 | Title PGC # for nav timer | 🟡 | stored |
| 11 | Karaoke mix mode | ❌ | not present (no known system-set cmd — `vmcmd.c:381` FIXME) |
| 12 | Country code (parental) | 🟡 | constant `'US'` |
| 13 | Parental level | 🟡 | stored + compared, **not enforced** (see 1.5) |
| 14 | Video config | 🟡 | constant `0x0100` |
| 15 | Audio config | 🟡 | constant |
| 16/17 | Initial audio lang / ext | 🟡 | 16 constant `'en'`; 17 absent |
| 18/19 | Initial subp lang / ext | 🟡 | 18 constant `'en'`; 19 absent |
| 20 | **Player regional code** | 🟡 ⚠️ | constant `0x0001` (region-free). libdvdnav only *warns* on SPRM20 reads (`decoder.c:110` "Suspected RCE"). |
| 21–23 | reserved | n/a | |

### 1.5 General registers & higher-order behavior

| Feature | Status | Notes |
|---|---|---|
| GPRM0–15 (16 general regs) | ✅ | `gprm[0:15]`, bit-exact ALU |
| GPRM counter mode (1 Hz tick) | ✅ HW (PR fj#119) | `gprm_mode` bit + **1 Hz `sec_tick` idle-gated increment** (`dvd_vm.sv`) — counter GPRMs accumulate real seconds. Scene It harvests this for entropy (`g[14] += g[13]`). Mirrors libdvdnav `decoder.c:69 get_GPRM`. **HW-confirmed: Scene It plays a different question each disc load (was identical).** |
| SetSystem sub-ops 1/2/6 (SetSTN, NavTimer+TitlePGC, SetHL button) | ✅ (timer stored only) | |
| Domains FP / VMGM / VTSM / VTS + `process_command` dispatch | ✅ | |
| Resume (RSM) with skip_pre | ✅ | |
| **UOP / user-operation masking** | ❌ | disc can't disable prohibited ops (skip/menu/etc.); we always allow |
| **Parental management enforcement** | ❌ | SetTmpPML "always succeeds" like libdvdnav (`decoder.c:373`); no PTL_MAIT gating |
| **Region enforcement** | ❌ (region-free) | intentional for a homebrew player; keep unless a disc mis-authors around it |

---

## 2. IFO table parsing

Reference: `libdvdread/src/ifo_read.c` + `dvdread/ifo_types.h` (**all fields big-endian**).
Our impl: `dvd/dvd_iso_reader.sv` (golden `tools/iso_nav_check.py`). **Filesystem: ISO9660 only
— no UDF parser** (UDF-only images fail; tracked as a gap). All IFO offsets validated vs
`ifo_types.h`.

| IFO table | Purpose | Status | Our path / notes |
|---|---|---|---|
| VMGI_MAT | VMG master table | ✅ | `@196 tt_srpt`, `@200 vmgm PGCI_UT`, `@132 FP_PGC` |
| VTSI_MAT | VTS master table | ✅ | `@204 VTS_PGCIT`, `@208 VTSM PGCI_UT`, `@200 VTS_PTT_SRPT`, `@0x100 V_ATR` menu aspect |
| TT_SRPT | title → VTS map | ✅ | `S_*` VMGI walk; title-select PR fj#74/#76 |
| FP_PGC | First Play PGC | ✅ | boots the disc's authored FP (PR fj#80) |
| PGCIT (VTS) | title program chains | ✅ | generalized parser (title + menu), `S_PGCIT_HDR/S_PGC_HDR` |
| PGCI_UT (VMGM/VTSM) | menu PGC unit table | ✅ | `S_UT_HDR` + `S_LU_EVAL` language-unit walk (spec-hardening Phase 4): match SPRM0 'en' per libdvdnav `get_MENU_PGCIT`, LU[0] fallback; single-LU = the v1 path bit-identical |
| PGC hdr / GI | still@163, palette@164, cmd tbl, cell tbl | ✅ | palette persists across seek (PR fj#83 lesson) |
| PGC program_map | program → entry cell (chapters) | ✅ | `pmap_mem` BRAM; chapter skip PR fj#96 |
| Cell playback tbl | cell timing / RBN / category | ✅ | `cell_pb_off16`; angle/still/interleave bits |
| Cell position tbl | VOB id / cell id | 🟡 | consumed as needed via extent map |
| **VTS_PTT_SRPT** | part-of-title (chapter) search | ✅ | Phase 6: `S_PTT_*` resolves any `[ttn][part-1] → {pgcn,pgn}` (exact `JumpVTS_PTT`); full table in `ptt_mem` (1024 entries, PR fj#170) → HUD `nr_ptt` total. Cross-PGC *user* skip + global current-chapter `n` wired through the `ptt_mem` read side (`CH_G*` reverse map + internal JumpVTS_PTT-shaped jump; spec-hardening Phase-5 follow-up) |
| C_ADT (cell address tbl) | cell → sector extents | ✅ | via the reader's extent table (RBN→sd_lba) |
| VOBU_ADMAP | VOBU sector map | 🟡 | in-stream DSI used instead of the static ADMAP for nav |
| VTS_TMAPT (time map) | time → sector seek | ⛔ | absolute/TMAP seek RETIRED (Phase 8b, user decision 2026-07-10) |
| VTS_ATRT / VTS attributes | audio/subp stream attrs | ✅ | Phase 10 track enum (`S_ATTR_*`, PR fj#100) |
| **PTL_MAIT** | parental management info | ❌ | not parsed (ties to SPRM13 enforcement) |
| **TXTDT_MGI** | disc/title text names | ❌ | not parsed (no title-name display) |
| DVD-VR / +VR tables (AMG/TIF/RTAV…) | video-recording discs | ❌ | out of scope (commercial DVD-Video only) |

---

## 3. In-stream navigation (NAV packs: PCI / DSI)

Reference: `libdvdread/src/nav_read.c` + `dvdread/nav_types.h`; highlight logic
`libdvdnav/src/highlight.c`. Our impl: `dvd/nav_pci.sv`, `dvd/nav_dsi.sv`
(golden `tools/nav_extract.py`). Demultiplexed by `dvd/ps_demux.sv` (private_stream_2 subs 0x00=PCI, 0x01=DSI).

| Feature | Reference | Status | Notes |
|---|---|---|---|
| PCI general info / PTM | `pci_gi_t` | ✅ | STC arm window |
| HLI highlight info (hl_gi, s/e_ptm, btn_ns, fosl/foac) | `hli_t` | ✅ | double-buffered, ss commit; `video_live` fallback promote (deep menus). foac = forced-SELECT only since 2026-08-27 — the forced-ACTIVATE arm was deleted (libdvdnav doesn't implement foac at all; it was the one nav path that could start playback with no keypress). |
| Button records (btni, coli color/contrast) | `btni_t`,`btn_colit_t` | ✅ | **group selected by display mode** (`btngr_ns`/`dsp_ty` vs the PR fj#115 aspect verdict; group-1 fallback; spec-hardening Phase 3, ✅ HW-confirmed PR fj#168) — note libdvdnav itself reads group 1 only |
| Directional button nav + activate | `highlight.c` | ✅ | D-pad link-walk, activate → btn_cmd (PR fj#84) |
| **CHG_COLCON** (dynamic color-contrast change) | PCI | ❌ | deferred |
| DSI general info / c_eltm (cell elapsed) | `dsi_gi_t` | ✅ | whole-title BCD time (HUD PR fj#103) |
| VOBU seek tables (fwda/bwda) | `vobu_sri_t` | ✅ | ±10 s time scrub uses fwda[3]/bwda[15] (PR fj#96) |
| next/prev VOBU / video pointers | `vobu_sri_t` | ✅ | seamless-branch ILVU follows `next_vobu` at BLOCK\|LAST (PR fj#112) |
| sml_agli angle offsets | `sml_agli_t` | ✅ | multi-angle B6 cycle (Phase 9, PR fj#98) — *note: angle jump uses next_vobu, NOT sml_agli* |

---

## 4. Audio / subpicture / output conformance (summary)

Detailed in `docs/fabric_audio.md`, `docs/iec61937.md`, `docs/subpicture.md`. Quick status:

| Feature | Status | Notes |
|---|---|---|
| AC-3 decode (HDMI stereo downmix) | ✅ | in-fabric `dvd/ac3/*` |
| LPCM 16-bit/48k | ✅ | `dvd/lpcm_unpack.sv` |
| LPCM 24-bit / 96 kHz | ❌ | aspirational only, never confirmed |
| DTS | ✅ passthrough only | IEC 61937 S/PDIF (PR fj#109); **no in-fabric DTS decode** |
| Menu audio | ✅ | plays. (Past bug: an audio-track switch could disable menu audio — resolved.) |
| Subpicture / subtitle (disc palette, RLE) | ✅ | `dvd/spu_decode.sv` + `subpic_blend`; CRT-480i mapped (PR fj#108) |
| Closed captions (line-21 / CC) | ✅ analog line-21 re-insertion — **HW-CONFIRMED 2026-08-26** (C1 on a real TV, MiB/Matrix) | Extracted in `vld.v` from MPEG-2 user_data, re-modulated onto line 21 of the analog raster for the TV to decode (`dvd/cc_line21.sv`, `P1O[14]`, default On). **No on-screen renderer** — nothing on HDMI; kept out by choice (see `docs/closed_captions.md` §5 — the fit rationale expired with the PR #9–#11 reclaim). Prevalence MEASURED: **6/34 local discs** carry live EIA-608 (all NTSC); `tools/cc_scan.py`, `dvd_census.py --captions`. Format + decode design: `docs/closed_captions.md` |
| Multi-angle | ✅ | Phase 9 |
| Audio + subtitle track selection | ✅ | Phase 10 gamepad |
| Audio logical→physical stream mapping (PGC `audio_control`) | ✅ | `dvd/aud_stream_map.sv`, 2026-08-27 — before this the track number was used as a raw substream index, silencing any disc with a non-identity map (31/431 library discs; GET_SMART VTS2 = the boot-silent repro). `docs/track_selection.md` |

---

## Reference-suspect regions

Places where libdvdnav is self-described wrong / hacky / lenient — **do not conform blindly;
cross-check layer 2 (Demystified / mpucoder) and layer 3 (real player) here.** Extracted from
the repo:

- `libdvdnav/src/vm/decoder.c:703,711` — VM command **types 5 & 6 "These are wrong. Need to be
  updated from vmcmd.c."** (We already follow vmcmd.c — do not regress toward decoder.c.)
- `decoder.c:110` — SPRM20 read triggers a *warning only* "Suspected RCE Region Protection".
- `decoder.c:112` — SPRM index masked `& 0x1f` with FIXME "max 24 not 32".
- `decoder.c:373` — parental SetTmpPML "always succeeds" (no enforcement).
- `vm.c:570-596` — "rough fix for strange still situations" on broken discs (BTTF RC2);
  self-described "somewhat broken."
- `vm.c:700` — `DVD_DOMAIN_FirstPlay: FIXME XXX $$$ What should we do here?`
- `ifo_read.c:2308` — `CHECK_VALUE(nr_of_ptts < 1000)` "this assertion breaks Ghostbusters".
- `searching.c:831` — `vts_tmapt` is NULL in the normal open path (TMAP reloaded ad hoc).
- `searching.c:1092,1173` — time-seek "HACK: need +1… not sure why" and "most DVDs have a tmap
  that starts at sector 0" assumption.
- `vmget.c:127,167` — FIXME: does not cross-check VTSI/VMGI status for stream type.
- Many `CHECK_VALUE(... /* ?? */)` bounds in `ifo_read.c` are empirical, not from spec.

---

## Phase 2 — corpus census + golden-trace oracle (2026-07-13, ✅ done)

Phase 2 of the plan is **tooling to measure gap prevalence offline**, so Phase 3 closes gaps
in measured order instead of by guess. Two first-party tools (they reuse OUR validated parsers,
not libdvdread — what they report is what our reader/VM would *see*):

- **`tools/dvd_census.py`** — batch feature census over an ISO library. Reuses `IsoNav`
  (`dvd_vm_ref.py`), `decode_vmcmd` (`iso_nav_check.py`) and `parse_vts_attr` (`nav_extract.py`).
  Per disc it reports: filesystem (ISO9660 vs UDF-only), VTS/title counts, per-title
  `nr_of_ptts` (chapters) + `nr_of_angles` (from TT_SRPT), PTL_MAIT / TXTDT_MGI / VTS_TMAPT
  presence (nonzero master-table pointer — no struct walk needed for a prevalence census),
  region mask, audio codecs + LPCM bit-depth/rate + stream counts, and a VM command-feature
  scan (SetTmpPML / SetMode-Counter / NVTMR / rnd / CallSS / JumpSS + un-decoded-bit count)
  over FP + every menu + every title PGC command block. Run: `tools/dvd_census.py [dir|iso …]`
  (defaults to `$DVD_ISO_DIR`); `--json out.json` dumps raw vectors.
- **`tools/build_dvd_trace.sh`** + **`tools/dvd_trace/*.c`** — the libdvdnav golden-trace
  oracle. Compiles the (in-repo, self-contained) `trace_boot` / `trace_menukey` /
  `trace_menuearly` tracers against the built `libdvdnav.a`/`libdvdread.a` and dumps
  libdvdnav's verbose FP→menu/title VM TRACE. Diff target for `dvd_vm_ref.py` (and ultimately
  `dvd_vm.sv`). **Verified 2026-07-13:** libdvdnav `trace_boot` and our `dvd_vm_ref.py boot`
  both boot MiB to **TT vts=1 PGCN 1 (Title 23)** — VM boot path agrees byte-for-byte on the
  decision. (`tools/bin/` is gitignored; rebuild with the script.)

### Measured prevalence (23-disc local library, re-measured 2026-07-31)

Coarse prior only — a small curated set, not a catalog statistic. Add ISOs to sharpen.
**The library tripled since the first census** (7 → 23 discs; the old 7-disc numbers are
superseded, not merely extended — several "0/7, no test vehicle" rows now have one).
Regenerate with `python3 tools/dvd_census.py`.

| Feature | Discs | Gap | Note |
|---|---|---|---|
| **Chapters (max_ptts > 1)** | **23/23** | **1** | universal — confirms exact-PTT was the right top gap. Scene_It: 798 chapters |
| CallSS / JumpSS | 23/23 | (done) | **0 un-decoded bits across ~122,500 commands** = strong vmcmd-decoder validation |
| VTS_TMAPT present | 19/23 | (retired) | nearly every disc authors a time map, yet TMAP seek was retired (Phase 8b, user) — noted, not reopened |
| **rnd set-op (game entropy)** | **13/23** | 3 | was 3/7 — the library is now game-heavy; `rnd` is mainstream here, not niche |
| Region-locked (partial mask) | 9/23 | 2 | intentionally region-free; no disc has yet mis-authored around it |
| GPRM counter-mode | 6/23 | 3 | ✅ shipped (PR fj#119) |
| Menu GoUp authored | 4/23 | (done) | B13 Return has an authored target (PR fj#152) |
| Title-domain GoUp authored | 3/23 | (done) | B13 acts in-title on these |
| TXTDT_MGI | 2/23 | 4 | still no title-name display |
| Multi-angle | 1/23 | (Phase 9 ✅) | MiB (5 angles) — our test vehicle |
| PTL_MAIT / non-trivial parental_id | 1/23 | 2 | MiB |
| **SetTmpPML parental cmd** | **1/23** | **2** | **`FAIRYTOPIA.iso` — the library's FIRST parental-command vehicle** (was 0/7 "none in library"). *2026-08-17: two post-census Ghibli arrivals (`CASTLE_IN_THE_SKY`, `CASTLE_USD2`) also carry SetTmpPML+PTL_MAIT → 3 vehicles; Castle also brings a 2nd multi-angle disc and the corpus's first UNKBITS command (a no-op SetSTN quirk). See `docs/disc_sweep.md`.* |
| NavTimer (SPRM9 set) | 1/23 | 3 | Scene_It Jr, at 999 s — never fires in practice |
| DTS | 1/23 | (passthrough ✅) | T2 |
| **LPCM 24-bit / 96 kHz** | **0/23** | 4 | still **no vehicle** — 23 discs, incl. two LPCM concert discs, and not one is 24-bit or 96 kHz |
| UDF-only image | 0/23 | 4 | all 23 are ISO9660 (as `docs/test_disc_shopping_list.md` #12 predicted — can't shop for it) |

**Findings that steer the work (re-measured):** (1) **exact chapters/PTT (gap 1) confirmed
universal** at 23/23 — shipped (PR fj#127). (2) **Interactive/game features are now the library's
centre of gravity, not an edge case** — `rnd` 13/23 and GPRM-counter 6/23 (both shipped,
PR fj#119); the remaining gap-3 items (UOP masking, NVTMR fire) are the last un-built pieces of
that cluster. (3) **Parental (gap 2) finally has a test vehicle** — Fairytopia is the only
disc in 23 that issues `SetTmpPML`, which we accept-always as a no-op; it is the single disc
that can tell us whether that no-op mis-branches. (4) **LPCM 24-bit/96k (gap 4) still has no
vehicle after tripling the library** — treat it as unbuildable-on-spec and keep it deferred.
(5) The vmcmd decoder stays clean (**0 unknown bits / 122,529 commands**), so no decode gap
hides in this corpus — VM bugs found from here are *semantic*, not decode.

---

## Prioritized gap list (full-conformance target)

Ordering now backed by the Phase-2 census above (prevalence in the local library):

1. **Exact chapters / PTT** — ✅ **HW-CONFIRMED** (PR fj#127; light test: no regression, movies
   unaffected by construction): `JumpVTS_PTT t:p` resolves the exact `VTS_PTT_SRPT[t][p-1] → {pgcn,pgn}` (was
   `ptt≈pg`); the current title's PTT table loads into `ptt_mem` and the HUD `CH n/N` total
   is the exact `nr_of_ptts`. **Measured finding: the old approximation was already exact on
   every MOVIE disc** (single-PGC, `program==ptt`); PTT only diverges on the Scene It *game*
   discs (multi-PGC), so this fixes game-disc VM chapter branching. The once-deferred
   cross-PGC *user* chapter-skip + PTT-based current-chapter `n` **shipped as the
   spec-hardening Phase-5 follow-up** (`CH_G*` reverse map through `ptt_mem` + an
   internal JumpVTS_PTT-shaped jump; the HW-confirmed `chap_st` program-map path is
   kept bit-identical for within-PGC moves — see `docs/dvd_nav.md` Phase 6). Golden
   model `tools/ptt_ref.py`. **Census: 23/23 discs have chapters (universal).** The old
   256-entry `ptt_mem` bound was **widened to 1024** (PR fj#170) — covers Scene_It's 798,
   PNP0NNS1's 369, and the `JumpVTS_PTT` operand's full 10-bit range.
2. **DVD-game entropy ✅ HW-CONFIRMED (PR fj#119)** — `rnd` is entropy-seeded at mount +
   stirred by user-input timing, and **GPRM counter mode ticks at 1 Hz** (the two sources
   Scene It harvests for question randomization; both were deterministic before → identical
   gameplay every play). **HW: Scene It now plays a different question each disc load** (needs
   O[1] Disc Menus ON). **UOP masking** and **NVTMR fire (SPRM9)** remain deferred (NavTimer
   is un-referenced — libdvdnav doesn't fire it — and 1/23 discs set it at 999 s). See
   `docs/dvd_vm.md` "DVD-game entropy". **Census: rnd 13/23, counter 6/23, NavTimer 1/23** —
   re-measured 2026-07-31; `rnd` went 3/7 → 13/23, so game-VM behaviour is now the library's
   dominant shape, and the untested game discs in `docs/disc_sweep.md` are its exercise.
   **Scene It nav bugs ✅ FIXED (PR fj#120, `65f89c2`):** (a) the boot question-detour
   (booted to a random question before the intended reshuffle → main menu) and (b) the
   how-to-play / HP menu re-playing the logo instead of parking on the authored
   indefinite-still menu are both resolved (in-title multi-button menu nav + boot-path
   ordering + menu park). Remaining deferred here: **UOP masking** and **NVTMR fire (SPRM9)**
   (NavTimer is un-referenced — libdvdnav doesn't fire it — 1/7 discs set it at 999 s).
3. **Parental management + PTL_MAIT + SPRM13 enforcement**, **region (SPRM20)** — required by
   the full-conformance target. **Census: PTL_MAIT 1/23, SetTmpPML 1/23, region-locked 9/23**
   (region kept intentionally free; parental rare on movie discs). **Now testable:**
   three `SetTmpPML` vehicles — `FAIRYTOPIA.iso` (⚠ its current rip is RAW/CSS-scrambled;
   re-rip first) plus the post-census `CASTLE_IN_THE_SKY`/`CASTLE_USD2` — the first chance
   to see whether our accept-always no-op mis-branches on a real disc. See `docs/disc_sweep.md`.
4. **CHG_COLCON**, **multi-group buttons**, **LPCM 24-bit/96k**, **closed captions**,
   **UDF-only images**, **TXTDT title names**. **Census: LPCM 24/96k 0/23 and UDF-only 0/23
   even after the library tripled** (treat both as having no obtainable vehicle);
   TXTDT 2/23 — lowest priority, defer until a disc needs it.

Cross-referenced from `docs/roadmap.md` (Phase 6 "Polish / Known Issues").

**The binding constraint is no longer discs — it's HW test time.** The 2026-07-13 framing
("filling the gaps needs discs we don't own") is superseded: the library tripled to 23 and
now covers LPCM, branching narratives, DVD games, anime, parental commands, and a 50k-command
VM disc. As of 2026-08-17 the library is ripper-fed and still growing (**12+ discs never
played on hardware** — the original 8 plus new arrivals), so the
next conformance evidence comes from running what we already own —
see **`docs/disc_sweep.md`** for the per-disc test cards and the breadth-first sweep protocol.
Only two rows still have genuinely no vehicle after tripling the library (LPCM 24-bit/96 kHz,
UDF-only images); `docs/test_disc_shopping_list.md` remains the map for those.
