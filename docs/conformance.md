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
     **The 3rd edition** (Taylor, Johnson, Crawford; `dvd_repos/DVD Demystified Third Edition
     -- Taylor, Jim.pdf` + OCR text `dvd_repos/DVD_Demystified_3rd.txt`) is the newer and
     fuller copy. Its ch. 9 "DVD-Video" (txt L13170–15800) *does* tabulate the SPRMs
     (Table 9.13), the VM commands (9.11), the domain transitions (9.12) and the user
     operations (9.15/9.16). Cite it as `3rd ed. p. 9-NN`, plus `L####` for the txt line. The
     page recipe below is for the 2nd-edition `.pages.txt` only. The 3rd-edition OCR has no
     reliable page breaks, so grep it for the section title and read the printed page number
     from the running footer. It is OCR: digits and table cells are sometimes garbled, so
     cross-check any number against `ifo_types.h` or a disc before acting on it. Audit against
     it: [§ 3rd-edition audit](#dvd-demystified-3rd-edition-audit-2026-10-01).
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
| B | Differs from the book (and usually libdvdnav) — see the [3rd-edition audit](#dvd-demystified-3rd-edition-audit-2026-10-01) |

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
| 0 | Menu language | ✅ | `cfg_lang` = the OSD **Player Language** (`O[43:40]`). The same code drives the reader's menu language-unit pick (`lu_lang_pref`, spec-hardening Phase 4, PR fj#176) |
| 1 | Audio stream # | ✅ | SetSTN → `sprm_astn` → **logical→physical resolution through PGC `audio_control`** (`dvd/aud_stream_map.sv` = `vmget.c` `vm_get_audio_stream` + the `vm_get_audio_active_stream` first-available fallback; menus force logical 0; deviation: an all-unavailable title map resolves to identity, not −1/silence) → demux mux. 2026-08-27, `fix/menu-link-audio-map`; see `docs/track_selection.md`. |
| 2 | Subpicture stream # | ✅ | SetSTN → `sprm_spstn` (bit6 = display enable) |
| 3 | Angle # | ✅ | SetSTN AGLN → `vm_agln` → the reader's `agl_vm` (the disc's angle choice), plus the B6 gamepad cycle. See the CLAUDE.md index row "SPRM3 from the VM" and `docs/track_selection.md` |
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
| 14 | Video config | ✅ HW (PR #154) | `dvd/player_regs.sv`: bits 10-11 = the *player's display* (16:9 on Progressive Auto/Fit and Interlaced Fit, else 4:3), bits 8-9 = the active Letterbox/Crop mode, following Analog Aspect (`aa_live`/`aa_sel`). This is the book's semantics (3rd ed. Table 9.13). libdvdnav instead copies the *disc's* aspect into bits 10-11, and only when the application asks. Was the constant `0x0100` (the 3rd-edition audit, #3). `docs/dvd_vm.md` "Player parameters" |
| 15 | Audio config | ✅ HW (PR #154) | `0x5800` (AC-3 + MPEG + DTS). b11 DTS = Passthru or the DTS codebooks loaded, else `0x5000`. SDDS and karaoke are clear. Was libdvdnav's `0x7CFC`, which claimed SDDS and every karaoke mode |
| 16/17 | Initial audio lang / ext | ✅ / 🟡 | 16 = `cfg_lang` (Player Language); 17 reads 0. The core never matches the preference against stream attributes itself. Only disc commands that read SPRM16 act on it (libdvdnav's `dvdnav_audio_language_select` also only writes the register) |
| 18/19 | Initial subp lang / ext | ✅ / 🟡 | 18 = `cfg_lang`; 19 reads 0 |
| 20 | **Player regional code** | ✅ HW (PR #154) | `dvd/player_regs.sv`: one-hot of the **lowest region the disc allows** (VMGI `vmg_category` byte 0x23), the 3rd ed.'s "autoswitching player" (p. 5-21). An all-prohibited mask reads `0x0001` and raises `rmask_all_prohibited` (telemetry word 14 bit 9). Was the constant `0x0001`: **region 1, not region-free**, which libdvdnav sets with a misleading "Region free!" comment (`vm.c:391`) and only *warns* on reading (`decoder.c:110`). 507/1,430 discs read it (the 3rd-edition audit, #2) |
| 21–23 | reserved | n/a | |

### 1.5 General registers & higher-order behavior

| Feature | Status | Notes |
|---|---|---|
| GPRM0–15 (16 general regs) | ✅ | `gprm[0:15]`, bit-exact ALU |
| GPRM counter mode (1 Hz tick) | ✅ HW (PR fj#119) | `gprm_mode` bit + **1 Hz `sec_tick` idle-gated increment** (`dvd_vm.sv`) — counter GPRMs accumulate real seconds. Scene It harvests this for entropy (`g[14] += g[13]`). Mirrors libdvdnav `decoder.c:69 get_GPRM`. **HW-confirmed: Scene It plays a different question each disc load (was identical).** |
| SetSystem sub-ops 1/2/6 (SetSTN, NavTimer+TitlePGC, SetHL button) | ✅ (timer stored only) | |
| Domains FP / VMGM / VTSM / VTS + `process_command` dispatch | ✅ | |
| Resume (RSM) with skip_pre | ✅ | |
| **UOP / user-operation masking** | ⛔ | **Not honoured, by decision (user, 2026-10-01).** None of the three levels is parsed: title (TT_SRPT playback type), PGC (`prohibited_ops` @8) or VOBU (PCI `vobu_uop_ctl`). **1,283/1,430 library discs author PGC-level prohibitions in titles.** Enforcing them would stop users skipping warnings and trailers, and libdvdnav does not enforce them either (`dvdnav_get_restrictions` only reports them). The one *mandatory* user op that was missing, Still off (UOP18), shipped in PR #159 |
| **Parental management enforcement** | ❌ | SetTmpPML "always succeeds" like libdvdnav (`decoder.c:373`); no PTL_MAIT gating |
| **Region enforcement** | ⛔ (never refuse a disc) | The core never refuses a disc for its region mask. What a disc's *own* region check sees is SPRM20, above |

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
| VTS_TMAPT (time map) | time → sector seek | ✅ | **Reopened and shipped** (issue #127; the Phase 8b retirement of 2026-07-10 was revisited). Indexes `tmap_offset[cur_pgcn-1]` and falls back to the caller's sector estimate (`tmap_fell`) when the map is absent, short or implausible. See `docs/dvd_nav.md` §2h. 3rd ed. p. 9-16: only *one_sequential_PGC* titles carry time maps. The reader does not check the title type, and relies on the fallback |
| VTS_ATRT / VTS attributes | audio/subp stream attrs | ✅ | Phase 10 track enum (`S_ATTR_*`, PR fj#100) |
| **PTL_MAIT** | parental management info | ❌ | not parsed (ties to SPRM13 enforcement) |
| **TXTDT_MGI** | disc/title text names | ⛔ | not parsed, and **closed rather than deferred** — measured over 956 images, the strings are authoring-tool junk (`SONY`, `TEXT_DATA`, `Xess_DATA`), not titles. See the gap list. |
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
| sml_agli angle offsets | `sml_agli_t` | ✅ | multi-angle B6 cycle (Phase 9, PR fj#98). The seamless angle jump uses DSI `sml_agli` when present (`snoop_ag_ok`) and falls back to `vobu_sri.next_vobu` (the "Angles: `next_vobu` without `sml_agli`" row of the CLAUDE.md index). **PCI `nsml_agli` (non-seamless angle) is not parsed** (`docs/roadmap.md`) |

---

## 4. Audio / subpicture / output conformance (summary)

Detailed in `docs/fabric_audio.md`, `docs/iec61937.md`, `docs/subpicture.md`. Quick status:

| Feature | Status | Notes |
|---|---|---|
| AC-3 decode | ✅ | in fabric, on the shared audio engine (`dvd/dts/ac3.uasm` since PR #149; `dvd/ac3/*` is the reference). acmod 1–7 → a 2-channel **Lo/Ro** downmix (LFE dropped, `cmixlev`/`surmixlev` honoured); 1+1 dual mono plays Ch1 left, Ch2 right (PR #162). Multichannel reaches a receiver by IEC 61937 passthrough instead. The 3rd ed. (p. 9-43) asks for a Dolby-Surround-compatible (Lt/Rt) downmix. `dynrng` is always applied, with no DRC switch, and `dialnorm`/`compr` are ignored (the 3rd-edition audit, class C) |
| LPCM 16-bit/48k | ✅ | `dvd/lpcm_unpack.sv` |
| LPCM 24-bit / 96 kHz, 1–8 channels | ✅ HW | every DVD-Video form decodes (multichannel downmixed, 96 kHz decimated or native on a 96 kHz link); synthetic streams on the rig, A/B vs `main`. `docs/lpcm_full.md` §12 |
| DTS | ✅ | IEC 61937 passthrough on optical and HDMI (PR fj#109, HDMI bitstream), and **in-fabric DTS core decode** to stereo in `Decode PCM` (PRs #148/#149, `docs/dts_decoder.md`) |
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
| TXTDT_MGI | 2/23 (**re-measured: 219/956 present, 149 printable, 0 useful**) | ⛔ closed | the field carries mastering artifacts, not title names |
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

> **Superseded as the work queue (2026-10-01).** The items below are the 2026-07/08 queue,
> and nearly all of them have shipped. The current open gaps, measured and ranked, are in
> [§ The open items, re-ranked](#the-open-items-re-ranked-2026-10-06), and their branches are
> in `docs/roadmap.md` "2026-10-01 spec-audit". This list is kept for its census evidence.

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
4. **CHG_COLCON**, **multi-group buttons** (✅ since, PR fj#168), **LPCM 24-bit/96k** (✅ since, PR #162), **closed captions** (✅ since, line-21 re-insertion),
   **UDF-only images**. **Census: LPCM 24/96k 0/23 and UDF-only 0/23
   even after the library tripled** (treat both as having no obtainable vehicle).
   ⛔ **TXTDT title names: CLOSED, not deferred (2026-09-13).** The old line here read
   "TXTDT 2/23 — lowest priority, defer until a disc needs it". Re-measured over **956
   images**: 219 set `txtdt_mgi` and 149 of those hold a printable `disc_name`, so the
   field is commoner than 2/23 suggested — but the strings are **authoring-tool
   artifacts, not titles**: `SONY`, `TEXT_DATA`, `Xess_DATA`, `TEXT_FRI`, `ACT_O_V`,
   `AI`, `CIRQUE`, `amore`. There is nothing user-facing to display, so the answer is
   never rather than later. (Reproduce: walk each VMGI's `txtdt_mgi` pointer at
   offset 0xD4 and read `disc_name[12]` + `nr_of_language_units` from that sector.)

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

---

## ISO 13818-2 7.3.1 — the quantiser matrix download is ALWAYS scan 0 (2026-09-13)

`rtl/mpeg2/iquant.v` un-zigzagged the `load_intra_quantiser_matrix` /
`load_non_intra_quantiser_matrix` payload with the **live** `alternate_scan` register,
which at sequence-header time still holds the *previous* picture's value. 7.3.1 says the
download is transmitted in zigzag (scan 0) order unconditionally; the read side already
agreed (`rld.v` un-zigzags the read address with the current picture's scan, so the RAM is
indexed in raster order). Fixed to `scan_reverse(1'b0, …)` in both module copies.

★ The module's own header comment had stated the correct rule all along, directly above the
line contradicting it.

Exposure measured by `tools/qmatrix_scan.py`: **480 of 957 library images** pair a *varied*
download with an `alternate_scan=1` title. It is invisible on a flat matrix, which is why
it survived. Detail: `docs/quant_matrix.md` §4.

---

## DVD Demystified 3rd-edition audit (2026-10-01)

**What was done.** The 3rd edition's player-behaviour text was read in full:
- ch. 9 "DVD-Video" (txt L13170–15800);
- ch. 3 aspect ratios and progressive (L6595–7420);
- ch. 5 APS / CGMS / regions (L8878–9250);
- ch. 7/9 file format (L12257, L12933);
- ch. 10 player outputs and setup (L17962–18420);
- Appendix B "Standards Related to DVD" (L27218–27674).

Every normative claim was checked against the **RTL**, not against this file, because this file
had drifted. That drift was itself a finding (class D, fixed in the same change). The
prevalence numbers are IFO-only sweeps of **1,430 library images on 2026-10-01**. The "boot
diff" numbers come from `tools/dvd_vm_ref.py`, booting each disc twice with one SPRM changed and
comparing where it lands. The census axes are reproducible with `tools/dvd_census.py`. The
boot diffs were run as one-off scripts and are recorded in `docs/status_log.md`.

**Classes:**
- **A** = a standard that is missing.
- **B** = implemented differently from the book. In most cases it also differs from libdvdnav.
- **C** = a deliberate or acceptable deviation, now recorded.
- **D** = a stale doc, now fixed. *(The D fixes landed on `main` with this section on
  2026-10-06, re-derived against the code as it then stood.)*

### A / B — the gaps as found on 2026-10-01, with their outcome

Rows 1–8 have all shipped. Rows 9–11 are re-measured and re-ranked in
[§ The open items, re-ranked](#the-open-items-re-ranked-2026-10-06) below, and their
branches are in `docs/roadmap.md` "2026-10-01 spec-audit". The Finding and Exposure
columns are as written on 2026-10-01.

| # | Finding | 3rd ed. | Where | Exposure (2026-10-01) | Status |
|---|---|---|---|---|---|
| 1 | **Forced subtitles never shown.** The subpicture decoder (`spu_decode`) treats display-control command `0x00` FSTA_DSP (forced start) the same as `0x01` STA_DSP and keeps no "forced" flag. SPRM2's stream is routed (`sp_sel`, `sp_route_en`) only while SPRM2 bit 6 (display) is set. Otherwise the user's own subtitle selection applies, and with subtitles off the SPU PES is dropped before decode. A disc that SetSTNs a forced-subtitle stream with display off, which is exactly the forced-subtitles case, therefore shows nothing. | Table 9.13 SPRM2 (63 = forced); Table 9.3 "forced caption" | `spu_decode` DCC arm; `emu.sv` `sp_sel`, `sp_route_en` | Not yet measured. Needs a `--deep` SPU axis that counts title-domain units carrying DCC `0x00`. | ✅ PR #151 (`docs/subpicture.md` "Forced subtitles") |
| 2 | **SPRM20 = region 1** (see §1.4). | p. 5-19..5-22, Table 9.13 | `dvd_vm.sv` `sprm_read` | 507/1,430 discs read it. In the boot diff, 65/120 of them land somewhere else when the reported region changes. On 5 of 6 decoded examples, the region-2/4 landing is a single-cell PGC with an **indefinite still and no commands**: a dead-end "wrong region" screen. | ✅ PR #154 (§1.4) |
| 3 | **SPRM14 = "4:3, pan-scan" on every setup** (see §1.4). SPRM15 claims DTS, SDDS and karaoke. | Table 9.13 | `dvd_vm.sv` `sprm_read` | SPRM14 is read by 30/1,430 discs. In the boot diff, **10/30 boot a different VTS**, and on the MGM-style discs we play the **4:3 intro on a 16:9 setup**. SPRM15 is read by 6/1,430. | ✅ PR #154 (§1.4) |
| 4 | **Unsupported audio fails silently or scrambled.** This breaks CLAUDE.md's "never truncate silently" rule. LPCM at 96 kHz or with more than 2 channels plays at the wrong rate with the channels mis-paired, because only the word-length bits of the header are read. A DTS track in Decode mode is silent with no message. AC-3 acmod 0 (dual mono) is silent with no message. The "AUDIO UNSUPPORTED" popup fires only for IFO audio format 3. | Tables 9.24–9.29 | `ps_demux` LPCM header, `lpcm_unpack`, `dvd_audio_decode` (DTS drop, acmod-0 self-heal) | The library has DTS tracks. LPCM 96 kHz and multichannel are rare (0/23 in the 2026-07 census). | ✅ PR #162, **reversed by decision**: the formats are now *supported*, not announced (`docs/lpcm_full.md`). DTS decodes since PR #148/#149 |
| 5 | **No user "Still off".** This is a *mandatory* user operation (UOP18). `S_STILL` exits only on its timer, a VM jump or a seek. A timed still (up to 254 s) or an indefinite still without buttons cannot be skipped except by a chapter skip. | Table 9.15 | `dvd_iso_reader.sv` `S_STILL` | Any still without buttons | ✅ PR #159 (`docs/dvd_nav.md` "Still off") |
| 6 | **Colour matrix falls back to BT.709.** When a stream has no `sequence_display_extension` colour description, `yuv2rgb` uses ISO 13818-2's default, BT.709. DVD is SD, so the book's DVD restriction is SMPTE 170M / BT.470 B/G, i.e. 601-style coefficients. The MPEG-1 path also never resets `matrix_coefficients`, so it inherits the previous stream's matrix. The subpicture palette is BT.601 regardless, so subtitles and video can disagree. | Table 9.18 | `rtl/mpeg2/yuv2rgb.v`, `vld.v` | Not measured. Needs an ES census of `colour_description`. | ✅ PR #156 |
| 7 | **Next/Prev at the title's edge.** The cross-PGC chapter skip through `ptt_mem` is HW-confirmed (fj#171) and stays. What is missing is the edge case. Next at the last chapter does nothing, where the book and libdvdnav (`vm.c:662-686`) run the post commands. Prev at the first chapter clamps, where they follow `prev_pgc_nr`. | p. 9-19 | `dvd_iso_reader.sv` `chap_st` | Every title's last chapter | ✅ PR #158. ⚠ This row misquoted the book; see `docs/dvd_nav.md` "Chapter skip at the title's edges" |
| 8 | **No `.BUP` fallback** when an IFO is unreadable (libdvdread falls back to the BUP). | p. 9-2 | reader name match (`.IFO` only) | Physical discs with damage | ✅ PR #163 (`docs/dvd_nav.md` "IFO header gate and .BUP fallback") |
| 9 | **Random/shuffle program playback ignored.** The PGC byte @162 is skipped. libdvdnav implements random, but not shuffle. | p. 9-16, Table 9.9 | `S_PGC_HDR` | **1/1,430** (ROBOTS_43) | ⏳ open |
| 10 | **Menu keys.** (a) Pressing Title again does not resume, though Menu does. (b) A menu table with no matching entry plays that domain's PGC 1 instead of being a no-op, which is what libdvdnav does. | p. 9-26/27 | `dvd_vm.sv` key arms; reader SRP[0] fallback | Minor | (a) ⏳ open; (b) ✅ HW, MERGED PR #173 — the Title key: a mount probe + key gate (`docs/dvd_vm.md` "Title key on a disc with no Title menu"); Chapter Menu keeps its fallback by decision |
| 11 | **`auto_action` fires only when a button is reached by the D-pad.** It does not fire on a forced or VM-set selection. libdvdnav fires on any non-zero value. | p. 9-28 | `nav_pci` `moved` | Minor | ⏳ open (premise corrected below) |

### The open items, re-ranked (2026-10-06)

**Method.**
- **IFO census.** `tools/dvd_census.py` over **1,521** library images (the top level plus
  every DVD subfolder, deduplicated by name; 1 non-ISO9660 skip; 1 tool error on
  MILLIONAIRERUS, a parse exception in the census itself).
- **HLI scan.** `tools/spec_audit.py --deep` (it walks every NAV pack) in two arms, following
  the forced-subtitle precedent in `docs/subpicture.md`:
  - the **24 game discs** in the library's interactive folder (picked: that is where
    auto-action lives);
  - **100** discs drawn at random (seed 20261006).
- **Verification.** Each new axis was checked against a known vehicle (ROBOTS_43,
  BEAST_MASTER, a hand-decoded Thayer's Quest HLI). The auto-action axes were also checked on
  synthetic HLIs, so their zeros are real zeros.
- **Title-key landings.** Driven in `tools/dvd_vm_ref.py`, from VMGM PGC 1 against a normal
  boot, on each affected disc.

**Ranking rule:** measured exposure × what the user sees × how sure we are it is a defect.

| Rank | Item | Exposure | What the user sees | Verdict |
|---|---|---|---|---|
| 1 | **10b Title key, no Title menu** | **88/1,521 (5.8 %)** VMGM PGCI_UTs lack entry 2. Menu key (VTSM lacks Root): **0**. Chapter key lands on a non-Root PGC 1: **1** (THE_RED_FURY) | The reader takes SRP[0] = VMGM PGC 1. On **84/88** that replays the boot chain to the main menu. On **64** of them, opening logos play first (14 s typical, up to 28 s); on 20, PGC 1 has no cells and Title acts like Menu. On 2 it lands on another menu, on 1 in a title-domain menu, and on 1 the model stops (MEN_IN_BLACK, unverified) | **Defect**: the book (p. 9-26) and libdvdnav both no-op. Fix user-key misses only, and keep the documented Chapter → main-menu fallback (1,387 discs author no chapter menu). **✅ Fixed, HW A/B vs `main`, MERGED PR #173** (the reader probes the VMGM at mount, `emu.sv` drops the key); the probe's offline model re-counts 88 misses, plus 5 discs with no VMGM PGCI_UT and 1 with no VMGI that also become no-ops |
| 2 | **Indefinite still + non-loop cell command (title)** | **7 discs, 5 of them games**: BEAST_MASTER (`CallSS VTSM`) and the others: Thayer's Quest and Deal or No Deal (`LinkTailPGC`), HP Hogwarts (`LinkPGCN 6`), Tomb Raider and Land Before Time (`LinkPGN 1`), Space Pirates (`Nop`). Menu domain: 15 | We run the command at the cell's end, where libdvdnav holds the still until a button press. On a game, that can take the "no answer" branch without waiting | **Unverified.** `nav_diff` A/B against libdvdnav first. `Nop` and a `LinkPGN` to the still's own program may be harmless |
| 3 | **10a A second Title press resumes** | **1,428/1,521** author a Title menu | A second Title press restarts the Title menu; Menu already toggles back | **Book-only**: libdvdnav resumes only on `DVD_MENU_Escape`. A user decision |
| 4 | **11 `auto_action`** | `aa_any` 15/24 games and **65/100 random**: auto-action buttons are common on ordinary movie discs. `aa_deadlink` 14/24 and 56/100, which is near-universal and moot (authored auto buttons self-link in all four directions, and arriving already fired them). **Visible case `aa_init_orphan`: 0/24 games, 0/100 random.** `aa_mode23`: 0 | Nothing measured | **Premise corrected** (below). Record and close unless a disc appears |
| 5 | **9 Random playback** | **1/1,521** (ROBOTS_43, one title PGC, mode `0x07`: random first program of 8). Shuffle: 0 | Program 1 always plays first | Real but one vehicle |

**#11's premise, corrected.** The 2026-10-01 row said `auto_action` "does not fire on a forced
or VM-set selection; libdvdnav fires on any non-zero value". libdvdnav calls
`button_auto_action` only from the four D-pad functions (`highlight.c:254-291`), so it does
not fire on a forced or VM selection either. What it does differently:
- (a) it fires after *any* arrow press, even one that goes nowhere; `nav_pci` requires the
  selection to move (`nav_pci.sv` `moved`);
- (b) it fires on any non-zero mode; `nav_pci` fires on `== 1` only.

The book's "activated when selected" reading (fire on the forced or initial selection) is
stricter than both. It shows on 4/24 game discs and **10/100 random discs** (`aa_fosl`/`aa_btn1`). There it
would launch a menu's or a game's button with no keypress. That is the failure the 2026-08-27 menu-link fix removed
on purpose when it deleted `nav_pci`'s forced-ACTIVATE arm. It is not adopted.

**#10's premise, split.** "Title again resumes" (10a) is the book's alone. "No matching entry
is a no-op" (10b) is the book's *and* libdvdnav's. Pressing Title on a disc that lacks a title
menu should do nothing; the book (p. 9-26) notes many Hollywood discs have none.

**Unchanged since 2026-10-01** (re-measured, for the record): SPRM20 read by 516, SPRM14 by
30, SPRM15 by 6; a region mask forbidding region 1 on 5; title UOPs on 1,346; DTS on 90;
LPCM 96 kHz and multichannel on 1 (SpacePirates); PGC still time on 0.

### C — deliberate or acceptable deviations (recorded)

- **UOPs not honoured** — ⛔ by user decision 2026-10-01 (§1.5).
- **APS / Macrovision and CGMS-A** — ⛔ will-not-build (anti-copy), user decision 2026-10-01.
  The PCI's APS trigger bits are not parsed at all, since `nav_pci` captures only the HLI.
- **WSS / CPR-1204 / SCART pin 8** (widescreen signalling on the analog output) — not built.
  It is recorded as a *feature idea* in `docs/roadmap.md`, not as a gap: auto 16:9 switching on
  PAL widescreen CRTs.
- **Parental control** — `SetTmpPML` accepts every request; `ptl_id_mask` / PTL_MAIT are never
  read (§1.5).
- **AC-3 downmix and dynamics:**
  - The downmix is Lo/Ro; the book (p. 9-43) says Dolby-Surround-compatible Lt/Rt. `dsurmod`
    is parsed but unused.
  - `dynrng` is always applied at full cut and full boost, with no user DRC switch. The book
    treats DRC ("midnight mode") as a player setting (p. 10-10).
  - `dialnorm` and `compr` are ignored.
  - DVD's 448 kbps cap is not enforced, which is harmless: A/52's full 640 kbps table is
    accepted.
- **Indefinite cell still with a cell command:** the command runs first. This is deliberate
  ("HW-proven Phase-3 heuristic — MiB/Matrix interactive cells carry both").
  - 2026-10-01 wrote: 41/1,430 discs author it, in 40 of them the command is a loop
    (`LinkTopC`, `LinkCN`, `LinkTopPG`), and the one residual is BEAST_MASTER (`CallSS VTSM`).
  - **Re-measured 2026-10-06 with the command classified, that undercounted.** 9 discs have
    it in a title and 42 in a menu. The command is *not* a loop on **7 title discs** and
    **15 menu discs** (`LinkTailPGC`, `LinkPGN n`, `LinkPGCN`, `Nop`).
  - The title-domain residual is the open item ranked 2 in
    [§ The open items, re-ranked](#the-open-items-re-ranked-2026-10-06). The menu-domain cases
    remain the deliberate heuristic.
- **PGC still time** is never timed and is applied after the POST commands; the book
  (p. 9-29) puts it before them. **0/1,430 discs author a PGC still time**, so this is
  evidence-deferred.
- **Pan & scan** is a fixed 528-px centre crop, analog-only, and the
  `picture_display_extension` vectors are not parsed. The book itself says features
  "essentially" never use those vectors (p. 3-37). Recorded in `docs/crt_anamorphic.md`
  §1/§12.
- **704-wide video is stretched to 720** (~2.3 %) rather than centred. Recorded as a choice in
  `docs/mpeg1.md`.
- **HDMI AVI InfoFrame** (stock Main): picture aspect fixed at 16:9, colorimetry "no data",
  RGB full range. Could move to MiSTer_DVDcss later.
- **IEC 60958 channel status** (optical) is set to category "general" and copyright
  "permitted".
- **96 kHz LPCM on a 96 kHz HDMI link plays natively** (PR #162, `hdmi_audio_96k`), whether or
  not the track is CSS-protected. Optical and 48 kHz links decimate to 48 kHz. The book notes
  that "the CSS license limits protected output to 48 kHz" (p. 9-44, L15195-15197). That is a
  licensing term for commercial players, not a format rule; recorded, not acted on. The library
  has 1 disc with 96 kHz LPCM (SpacePirates).
- **GPRMs are not cleared on a user title search** (p. 9-23). This is unreachable: the core
  has no title-search key, and GPRMs clear on mount and on a full Stop.
- **Already tracked elsewhere:** karaoke (SPRM11 / SetAMXMD), SDDS, the nav
  timer, `nsml_agli`, TXTDT (closed), UDF-only images and CHG_COLCON.
- **Where the book is wrong — do not "fix" toward it:**
  - p. 9-20 says a PGC holds at most "128 commands *in total*". The library disproves it
    (Weakest Link authors 128 *pre* commands alone; Thayer's VMGM PGC 6 holds 134). Keep the
    per-block reading in `docs/spec_hardening.md` (cmem 512).
  - p. 9-24 lists SPRM8 as "1 to 36". Players store `button << 10`, as libdvdnav and
    `sprm8_eff` do.

### Appendix B — "Standards Related to DVD", against this core

| Standard | Status |
|---|---|
| ISO/IEC 13818-1 (PS), 13818-2, 11172-2 video | ✅ |
| SMPTE 170M, ITU-R BT.470 (analog) | ✅ `docs/single_raster_analog.md` |
| ITU-R BT.601 colour | 🟡 the default matrix is BT.709 (A/B #6) |
| EIA/CEA-608 line 21 | ✅ NTSC analog only; field 2 plumbed but unproven (`docs/closed_captions.md`) |
| ATSC A/52 AC-3 | ✅ (deviations listed in class C) |
| ISO/IEC 11172-3 / 13818-3 MPEG audio | ✅ Layer II stereo base; the multichannel extension is ignored |
| IEC 60958 / IEC 61937 | ✅ (channel-status notes in class C) |
| ISO 9660 | ✅ |
| OSTA UDF / ECMA-167 / ECMA TR/71 (UDF Bridge) | ❌ the book (p. 9-2) says "all DVD players shall support UDF and ISO 9660"; UDF-only images fail (tracked gap) |
| ISO 639 / ISO 3166 | ✅ Player Language; the country code is fixed at 'US' |
| ETS 300 294 WSS, IEC 61880 / JEITA CPR-1204, EIA/CEA-805 | ⛔ CGMS-A; WSS is a roadmap idea |
| Macrovision APS | ⛔ |
| CEA-708, SDI, IEEE 1394 / IEC 61883, DTCP, HDCP, ECMAScript/XML (HD formats) | n/a |
| ISRC, TXTDT character sets | n/a (TXTDT closed) |

### D — stale docs fixed by this change

- The SPRM 0/3/14/15/16/18/20 and UOP rows in this file.
- VTS_TMAPT (now shipped) and the `sml_agli` note in this file.
- The AC-3, LPCM and DTS rows in this file, and gap item 4 (CC has shipped).
- `docs/dvd_vm.md` (SPRM0 described as constant; LU[0] always).
- `docs/spec_hardening.md` header (MPEG-1 L2 and menu audio have both shipped).
- `docs/ac3_decoder_architecture.md` (the acmod gate).
- `docs/fabric_audio.md` (DTS passthrough described as a "future plan").
- `docs/hdmi_bitstream.md` (MP2/LPCM described as silent in Passthru).
- `docs/mgl_launch.md` (SMPTE-170M coefficients, which apply only when the stream says so;
  fixed by PR #156 itself).
- `docs/audio.md` (the HPS-era LPCM header).
- CLAUDE.md "Known gaps" (PTT exactness and GPRM counter mode had shipped).
- Two RTL comments were also stale: `mp2_decode.sv` ("44.1 kHz plays fast") and the
  `dvd_audio_decode.sv` header (DTS passthrough as a plan). Both have since been fixed by
  the branches that touched those files.
