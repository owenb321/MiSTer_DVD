# Disc sweep — the never-tested ISOs (prework + test cards)

**Status: Pass 1 PARTIALLY RUN (2026-08-17) — 6 of 12 discs played on
`DVD_cssdetect_20260806_1419.rbf`; triage below, with a first round of measurements
already answered (see "Round-2 measurements"). Remaining discs: Fairytopia (needs a clean
re-rip), 24 Board Game, Akira, both Castles, Elmopalooza.**
Results are recorded per card; **[Pass 2 triage](#pass-2-triage-2026-08-17) ranks the root
causes** and names the one decisive measurement each needs before any code is written.

## Why this file exists

The local library grew 7 → 23 discs, but **8 had never been played on hardware or mentioned
in any doc**. `docs/conformance.md`'s old framing ("filling the gaps needs discs we don't
own") is superseded: the binding constraint is now HW test time, not disc availability. Every
fix from PR fj#137–fj#151 came from one loop — play an untested disc → capture the symptom →
diagnose offline against the golden models → fix. This file is the *prework half* of that
loop done up front, so the hardware pass is a fast structured sweep against printed
predictions instead of open-ended poking.

**The library is now ripper-fed and keeps growing** (the `dvd_ripper` project auto-rips to
ISO; the bulk of the collection lives off this dev machine). That changes the workflow in two
ways: (1) every new rip gets the **pre-flight** below before it earns a test card, and
(2) the census must be re-run wherever the ISOs live — see "Carding a new arrival".

Companion to `docs/conformance.md` (what's implemented) and
`docs/test_disc_shopping_list.md` (what's still unbuyable).

---

## Since the prework (PRs fj#155–fj#161) — what changed under this sweep

The sweep hasn't run yet, but the core moved. These change what the cards predict and what
counts as a bug:

- **CSS-encrypted rip detect + mute (PR fj#160, ✅ HW-CONFIRMED).** Motivating case was
  **FAIRYTOPIA.iso from this very sweep list** — its rip is RAW (not decrypted; ~30% of
  checked packs scrambled). The core now shows a persistent **`CSS ENCRYPTED`** popup and
  mutes both audio paths while video (garbage) keeps playing so the disc is identifiable.
  Fairytopia's card is amended below, and a **pre-flight scan is now part of the protocol**.
- **Thayer saga closed (PR fj#159, ✅ HW-CONFIRMED).** Three deltas that touch game discs:
  (1) **mostly-FIELD-CODED MPEG-2 discs now play** (B field-pair drop in `vld` — before this,
  such a disc ran ~10% video-slow into an audio-skipping VBUF jam, which would have looked
  like a mysterious sweep failure); (2) sd delivery is now **2048-byte blocks** (headroom for
  discs authored at the DVD mux ceiling); (3) **menu highlight promotion is model v2**
  (display-justified: STC-scheduled needs a trusted clock, settle promotion on parking menus,
  1 s timer only for looping menus). The v2 code is fresh — on every game-disc menu, watch
  highlight *timing*: late/missing on parking menus, painted-over-transition on looping ones.
  (Thayer's Quest itself is heavily HW-tested now and is NOT part of this sweep.)
- **Film 24p exact-rate + cadence-slip corrector (PR fj#158, ✅ HW-CONFIRMED).** Affects the
  Akira card: the progressive-film path is now drift-free over a 45-min clip. The cadence
  corrector lives in the frame-drop governor path — **Frame Drop must be On** for it.
- **SDC clock-groups root fix (PR fj#156).** Builds now close reliably (≥86 MHz both corners);
  the fringe lottery is dead. No protocol impact — it just makes Pass-3 batch builds cheap.

### Pre-flight for every rip (new, mandatory before a disc earns SD-card time)

```bash
tools/css_scan.py <iso|dir>       # exit 1 if ANY scrambling found; seconds per disc
```

`tools/css_scan.py` (new) mirrors `ps_demux`'s detection rule exactly (PES flags byte at
`14+stuffing+6`, `'10'` marker + scrambling bits [5:4]) and samples ~20k packs per image.
A dirty rip is a **ripper problem, not a core bug** — re-rip it; don't burn sweep time on it.
**★ FULL-LIBRARY CENSUS (2026-08-23, all 34 ISOs): 31 CLEAN, 3 ENCRYPTED.**

| Disc | Scrambled packs | Note |
|---|---|---|
| `FAIRYTOPIA.iso` | 29.7 % | known since PR fj#160 |
| `SCENEIT_JR.iso` | 27.6 % | **NEW** — found when it was picked as a Phase-2 test vehicle and the core's own CSS detector fired on it |
| `deal_or_no_deal.iso` | 39.6 % | **NEW** — never played on HW; would have presented as a mystery sweep failure |

All three need a re-rip; none is a core bug. The two new ones went undetected because
the pre-flight had only ever been run on individual arrivals, never swept across the
whole library — worth re-running after any bulk import. Both are game discs, i.e.
exactly the category whose sweep failures are hardest to attribute.

Validated: FAIRYTOPIA = ENCRYPTED (29.7% of checked packs), MEN_IN_BLACK and all four new
arrivals = CLEAN.

### Carding a new arrival (the ripper-era loop)

The census/prediction tools are plain Python over the ISO — portable to whatever host holds
the library. Copy `tools/{dvd_census.py, dvd_vm_ref.py, iso_nav_check.py, nav_extract.py,
css_scan.py}` (the first needs the next three importable beside it). Per disc:

```bash
tools/css_scan.py  <iso>                      # pre-flight (above)
tools/dvd_census.py <iso>                     # structure one-liner + feature flags
tools/dvd_vm_ref.py boot    <iso>             # predicted boot landing
tools/dvd_vm_ref.py menu    <iso>             # predicted Menu-key landing
tools/dvd_vm_ref.py postend <iso>             # predicted title-end POST dispatch
tools/bin/trace_boot <iso>                    # libdvdnav cross-check (build once with
                                              #   tools/build_dvd_trace.sh; needs UDF!)
```

Then add a card here in the same shape as the ones below. If the census prints an
interesting flag (SetTmpPML, UNKBITS, angles, ≥4 audio streams), that's the watch list.
Reminder if ISOs get served to the MiSTer from a NAS: the framework opens them `O_RDWR`,
so the SMB share must be writable (memory `cifs-iso-load-eacces-rdwr`).

---

## Sweep protocol — breadth first, then batched depth

**Pass 1 — breadth (one sitting, current `.rbf`, no fixes).** Play all 8 discs, run the same
sequence on each, fill in only the Result lines: what happened, at which step, versus the
prediction. **Do not stop to diagnose.** If a disc won't mount or boot at all, log it and move
on — that's a different failure class and doesn't need in-the-moment context.

Why breadth first:
- **Build economics.** A fix cycle costs a full Quartus compile + reflash. Batching turns
  ~15 build cycles into ~3.
- **Symptoms cluster, and the cluster is only visible from above.** 5 of the 8 are game/VM
  discs; one root cause plausibly explains several. The Tomb Raider freeze turned out to be
  *three* distinct in-title nav bugs, and the first single-disc diagnosis of it was wrong
  (memory `game-disc-freeze-hw-diagnosis` records the retraction).
- **Depth-first has order bias** — it sinks the session into whatever the first disc happens
  to break on, possibly a rare quirk, while a systemic bug waits.

**Pass 2 — triage.** Group symptoms by suspected root cause, not by disc; rank by how many
discs a cause explains. For freezes read `rd_state` FIRST (memory
`game-disc-freeze-hw-diagnosis`); the row-22 last-jump overlay was the decisive instrument on
Tomb Raider.

**Pass 3 — batched fixes.** One `feature/*` branch per root cause → sim regressions → PR →
then **one** `./build_release.sh --compile --name DVD_<batch>` covering the batch, so a single
reflash verifies all of them.

### The standard sequence (identical on every disc)

Run with **`O[1] Disc Menus` = On** (the VM only boots the authored First Play with it on).
Buttons per the current map, `dvd/emu.sv` `CONF_STR` `J1`:

| # | Action | Button | What to check |
|---|---|---|---|
| 1 | Boot the ISO | — | lands where the card predicts |
| 2 | Menu | B5 Menu | lands where the card predicts (**sometimes that means "resumes the movie" — see Akira**) |
| 3 | D-pad walk | ↑↓←→ | highlight moves along the authored link graph |
| 4 | Select | B4 Select | activates the highlighted button |
| 5 | Chapter skip | B3 / B2 | HUD `CH n/N`; N matches the card's chapter count |
| 6 | Scrub | B10 Fast Fwd / B11 Rewind | seek bar + A/V stays in sync after release |
| 7 | Audio / Subtitle | B7 / B8 | popup lists the card's stream counts |
| 8 | Title / Return | B12 / B13 | acts only where the disc authored it (see GoUp column) |
| 9 | Display | B9 | status line toggles |
| 10 | Pause / resume | B1 | still frame holds, audio resumes seamlessly |

---

## Prework findings (before any hardware)

Three things fell out of the offline pass. Two are recorded; one was fixed here.

### 1. ✅ FIXED — `tools/straddle_check.py` carried a stale RTL model (false alarms)

Its `rtl_genuine_bug()` still described the **pre-PR-fj#143** reader (single-sector `rbuf`
shadow ⇒ `nr_of_cells` unreadable at `pgc_off > 2044` ⇒ FSM bails). It therefore reported
**7 "GENUINE … FSM bails" PGCs at `pgc_off=2046`** — Weakest Link ×5, Hogwarts Challenge ×1,
24 Board Game ×1 — which would have sent the sweep chasing a phantom on three of the eight
discs.

Re-verified against the RTL: the shadow fetch is **sector-crossing** since PR fj#143. Mid-fetch,
when `fetch_base+fi > 2047` the FSM refills `parse_buf` with `sec_lba+1` and resumes the same
fetch with `fi` preserved ([dvd_iso_reader.sv:1945](../dvd/dvd_iso_reader.sv#L1945)), so
`rbuf[0..7]` reads correctly at **any** `pgc_off`; `S_PGC_HDR`'s give-up guard was deleted with
it. The tool's model is now refreshed and section B reports none on all 8 discs. *(Standard
lesson: our own tools go stale exactly like status markers do.)*

### 2. `THEBRAINGAME.iso` is **ISO9660-only — libdvdnav cannot open it, we can**

`tools/bin/trace_boot` fails outright: `DVDOpenFileUDF:UDFFindFile /VIDEO_TS/VIDEO_TS.IFO
failed … vm: failed to read VIDEO_TS.IFO`. Cause: the image's volume-recognition sequence has
**`CD001` only, no `BEA01`/`NSR02`/`TEA01`** — there is no UDF filesystem at all (compare
Akira: `CD001, CD001, BEA01, NSR02, TEA01` = a proper UDF-Bridge). libdvdread requires UDF.

This is the **exact inverse** of our documented gap ("ISO9660 only — UDF-only images fail"):
here our ISO9660-first reader plays a disc that libdvdnav/VLC cannot. Consequences:
- **No golden trace exists for Brain Game** — judge its sweep result against our model and a
  real player only.
- Worth keeping as the standing regression vehicle for the ISO9660 path.

### 3. Fixed-table capacity audit — headroom fine except one bound

Scanned every PGC in all 23 ISOs against the reader/VM fixed tables:

| Table | Cap | Library max | Verdict |
|---|---|---|---|
| VM command BRAM ([dvd_vm.sv:176](../dvd/dvd_vm.sv#L176)) | 2048 B = 256 cmds | 134 (Thayer's Quest) | OK |
| `pmap_mem` ([dvd_iso_reader.sv:624](../dvd/dvd_iso_reader.sv#L624)) | 128 programs | 99 (Matrix) | OK |
| `cell_*_mem` `MAXCELL` ([dvd_iso_reader.sv:539](../dvd/dvd_iso_reader.sv#L539)) | 255 cells | 132 (T2) | OK |
| **`ptt_mem`** ([dvd_iso_reader.sv:663](../dvd/dvd_iso_reader.sv#L663)) | **256 chapters** | **798 (Scene It)** | **truncates** |

Only `ptt_mem` is exposed: a title with >256 chapters silently truncates the resident PTT
table (HUD `CH n/N` total, `JumpVTS_PTT` for high parts). **Family Feud II at 235 chapters is
the closest of the 8 to the edge** — deliberately not widened on spec; step 5 of its card is
the test.

### 4. Golden-trace agreement: 7/8 (8th unavailable)

Our `tools/dvd_vm_ref.py` and libdvdnav agree on the boot landing for **all seven discs
libdvdnav can open**; the eighth is Brain Game (finding 2). No VM divergence to chase before
hardware — so a VM symptom found in the sweep is new information, not a known model gap.

---

## Test cards

Chapter/stream/flag data from `tools/dvd_census.py` (2026-07-31). Predictions from
`tools/dvd_vm_ref.py {boot,menu,postend}`, cross-checked against `tools/bin/trace_boot`.

---

### 1. `FAIRYTOPIA.iso` — ★ the parental-command vehicle

> **⚠️ 2026-08-17: THE CURRENT RIP IS RAW (CSS-scrambled) — re-rip before running this
> card.** This disc was PR fj#160's motivating case: `tools/css_scan.py` reports ~30% of
> checked packs scrambled. On the old image the core will show the persistent
> **`CSS ENCRYPTED`** popup, mute all audio, and play green/artifacted video — that is the
> **correct shipped behaviour, not a sweep finding** (and seeing the popup fire IS a free HW
> re-confirm of PR fj#160). The prediction lines below still hold (IFO metadata is never
> scrambled — the offline traces parsed fine), but the play/menu/A-V steps need a clean rip.

- **Structure:** 24 VTS / 24 titles / max 97 chapters / 1 angle · audio ≤6 streams · subp ≤1 ·
  region 0xfd · flags: **SetTmpPML**, TMAP(3), rnd
- **Boot:** FP → `JumpSS_VMGM_PGC 2` → `LinkPGCN 4` → `JumpSS_VTSM vts=2 PGCN 3` cell 0
  — **libdvdnav agrees** (`Video Title Menu Domain: VTS:2 PGC:3`)
- **Menu key:** long trampoline → `CallSS_VMGM_PGC 5` → `JumpTT 5` → TT vts=5 PGCN 1, `LinkPGN 1`
- **Title end (POST):** VTSM vts=2 PGCN 4 → `JumpSS_VMGM_PGC 5` → `JumpTT 3` → TT vts=3 PGCN 1
- **★ Watch:** first `SetTmpPML` vehicle found (no longer the only one — the two Ghibli
  arrivals below also carry it, so parental vehicles are now **3**). We accept-always as a
  no-op (`docs/conformance.md` §1.5, gap 2). If parental gating drives content selection
  here, the symptom is *playing the wrong cut* or a menu branch dead-ending — **not** an error.
  Note precisely which menu item was pressed and what played.
- **Result (2026-08-17):** ⚠️ **★ SUSPECTED REGRESSION** (user: "pretty sure this worked in an earlier build"). Main menu loads ✅. **'Brain Training' does nothing** (stays on the menu); **'Start' does nothing**; **'How to Play' → black screen, no audio** (Menu key escapes). → Cluster C (top suspect, with a 1-minute discriminator).

### 2. `WEAKEST_LINK_DES.iso` — ★ the VM scale stress

- **Structure:** 29 VTS / 29 titles / 29 chapters · **50,138 VM commands** (largest in the
  library by ~3×) · audio ≤2 · subp ≤10 · flags: GPRMcounter, rnd
- **Boot:** FP → `JumpTT 21` → TT vts=21 PGCN 1 → `LinkPGCN 29` → **TT vts=21 PGCN 29 cell 0**
  — **libdvdnav agrees** (`VTS:21 PGC:29`)
- **Menu key:** → `JumpSS_VMGM_PGC 4` → `JumpTT 21` → PGCN 1 → `LinkPGCN 30` → `LinkCN 1`
- **Title end (POST):** `LinkPGCN 24` — **libdvdnav agrees** (`VTS:21 PGC:24`)
- **Watch:** game-VM churn at scale — `V_WAIT` give-up timer, tail-drain gating on
  cell-command branches (`docs/dvd_nav.md` "Phase B"), GPRM counter tick + `rnd` (answers
  should differ between two cold boots). Its PGCNs run into the hundreds (PGCN 917 exists), so
  this is the disc most likely to expose a PGCN-width or table-walk assumption.
- **Result (2026-08-17):** ⚠️ **Menu OK; game dispatcher lands on the wrong PGC.** Boot + menu correct. Single-player plays the long intro, then *at the point it should ask the first question* it cuts to a **'Round winnings 7500 GBP'** screen where Select/D-pad do nothing (Menu key does return to player select). Multi-player identical. HUD showed **`CH 92/2`** (chapter 92 of 2) at the failure. → Cluster B + note C.

### 3. `SPEED RACER CRUCIBLE CHALLENGE.iso` — ★ the track-enumeration stress

- **Structure:** 5 VTS / 5 titles / 52 chapters · **audio ≤8 streams** (most in the library) ·
  subp ≤1 · 1601 VM commands · flags: rnd
- **Boot:** FP → `JumpTT 5` → TT vts=5 PGCN 1 → `LinkPGCN 9` → **TT vts=5 PGCN 9 cell 0**
  — **libdvdnav agrees** (`VTS:5 PGC:9`)
- **Menu key:** → VMGM PGCN 2 → `JumpTT 5` → PGCN 1 → `LinkPGCN 14` → `LinkPGCN 13` → TT vts=5 PGCN 13
- **Title end (POST):** `LinkPGCN 12`. ⚠️ libdvdnav's play-through reaches PGCN **13** later —
  different entry point, not a proven divergence; if the sweep shows a wrong post-title jump,
  start here.
- **Watch:** B7 audio cycle across **8 streams** — HUD `AUDIO n/N` total and the per-switch
  re-sync (Phase 10, `docs/track_selection.md`); audio-switch re-sync resets *only* audio_ring
  + dvd_audio_decode.
- **Result (2026-08-17):** ⚠️ **Main-menu highlight missing on the FIRST loop, appears on the second** (user: "similar to the early issue we had with the Matrix main menu"); debug overlay shows the button rects the whole time. Gameplay otherwise good, but the correct/incorrect **video branches hitch ~0.5 s** instead of being seamless. → Cluster A + Cluster D.

### 4. `Harry Potter Interactive DVD Game (HOGWARTS CHALLENGE).iso`

- **Structure:** 2.7 GB · worst PGC 128 commands · game
- **Boot:** FP → `JumpTT 16` → **TT vts=16 PGCN 1 cell 0** — **libdvdnav agrees** (`VTS:16 PGC:1`)
- **Menu key:** VTSM vts=16 PGCN 1 → `JumpSS_VMGM_PGC 11` → `JumpTT 5` → PGCN 1 → `LinkPGCN 13`
- **Title end (POST):** `LinkPGCN 5` → TT vts=16 PGCN 5
- **Watch:** in-title multi-button HLI menus (the Scene It class — memory
  `scene-it-in-title-hli-menus`: D-pad nav gated on `dbg_btn_ns>1`, scrub suppressed);
  timed-still FMV choices (PR fj#144).
- **Result (2026-08-17):** ⚠️ Boot ✅, Menu ✅. **'Play Game' → Player Mode screen shows NO highlight** (debug overlay shows the rects; Select still works and picks the right option). **Skipping the transition video with Select makes the highlight appear correctly.** Also: skipping menu transitions sometimes leaves the static image **pixelated for a few seconds** before it resolves; and the in-game **score-card screen flashes ~2 s** then returns (expected to hold longer). → Cluster A + Cluster D + Cluster E.

### 5. `24_DVD_BOARD_GAME.iso`

- **Structure:** 22 VTS / 27 titles / 76 chapters · subp ≤6 · 2474 VM commands · flags: TMAP(2), rnd
- **Boot:** FP → `JumpSS_VMGM_PGC 2` → **VMGM PGCN 2 cell 0 (5 cells)** — **libdvdnav agrees**
- **Menu key:** VTSM vts=2 PGCN 1 → `JumpSS_VMGM_PGC 9` → `JumpSS_VTSM vts=1 entry 6` → VTSM vts=1 PGCN 3
- **Title end (POST):** `JumpSS_VTSM vts=1 entry 4` → VTSM vts=1 PGCN 2
- **Watch:** boots straight into a **VMGM menu with real cells** (not a stub) — the FP path
  most likely to expose menu-still / cold-re-decode behaviour (`docs/dvd_menu_refinements.md` §5).
- **Result:** _(pending)_

### 6. `FAMILYFEUDII.iso` — ★ the `ptt_mem` edge case

- **Structure:** 25 VTS / 26 titles / **235 chapters** · 904 VM commands · flags: GPRMcounter, rnd
- **Boot:** FP → `JumpSS_VMGM_PGC 2` → **VMGM PGCN 2 cell 0** — **libdvdnav agrees**
- **Menu key:** VTSM vts=1 PGCN 1 → `LinkPGCN 4` → VTSM vts=1 PGCN 4
- **Title end (POST):** `JumpSS_VTSM vts=1 entry 3` → PGCN 1 → `LinkPGCN 4`
- **★ Watch:** 235 chapters vs the **256-entry `ptt_mem`** (finding 3). Check the HUD `CH n/N`
  **total** on the 235-chapter title and that a high chapter number skips correctly — this is
  the closest the library gets to the bound without crossing it.
- **Result (2026-08-17):** ⚠️ Menu ✅. **New game always shows the SAME question** (no apparent randomisation). Watching 'How to Play' and then choosing 'Start' lands on the **'Fast Money' end-of-game round** instead of the game start. → Cluster B + Cluster F.

### 7. `THEBRAINGAME.iso` — ★ ISO9660-only (no golden trace)

- **Structure:** 9 VTS / 12 titles / 185 chapters · 328 VM commands · flags: TMAP(9),
  GPRMcounter, rnd · **no UDF filesystem** (finding 2)
- **Boot:** FP → `JumpSS_VTSM vts=2 entry 3` → VTSM vts=2 PGCN 1 → `LinkPGCN 2` →
  **VTSM vts=2 PGCN 2 cell 0** — ⚠️ **no libdvdnav cross-check available** (it can't open the image)
- **Menu key:** VTSM vts=3 PGCN 1 → `JumpSS_VMGM_PGC 2` → `JumpSS_VTSM vts=2 entry 3` →
  PGCN 1 → `LinkPGCN 5` → VTSM vts=2 PGCN 5
- **Title end (POST):** chain through VTSM vts=2 PGCN 7 (self-linking) → `LinkPGCN 3`
- **★ Watch:** it mounting at all is the headline result — a disc VLC can't open. The POST
  chain self-links `PGCN 7 → 7` before escaping to 3; if it parks, that loop is the suspect.
- **Result:** _(pending)_

### 8. `Akira (1988).iso` — the film regression vehicle

- **Structure:** 4 VTS / 5 titles / 37 chapters · audio ≤2 · subp ≤2 · UDF-Bridge
- **Boot:** FP → `JumpTT 1` → **TT vts=1 PGCN 1 cell 0** (straight to the movie, no menu)
  — **libdvdnav agrees** (`VTS:1 PGC:1`)
- **★ Menu key:** VTSM vts=1 root PGC has **0 cells and its PRE is `LinkRSM`** → it immediately
  **resumes the movie**. So *"Menu appears to do nothing"* on this disc is **AUTHORED AND
  CORRECT** — do not file it as a bug. (Same class as the PAW Patrol and Cluedo lessons:
  memories `paw-patrol-vm-matches-libdvdnav`, `cluedo-select-resume-park`.)
- **Title end (POST):** VTSM vts=1 PGCN 5 → `LinkPGCN 22` → `JumpSS_VMGM_PGC 2` → `JumpTT 2`
- **Watch:** the only straight *film* disc of the eight — use it as the A/V regression: 3:2
  film cadence, A/V Offset default +100 ms, subtitle render, chapter skip, scrub. If testing
  the **Film 24p** progressive raster, the PR fj#158 cadence-slip corrector needs **Frame Drop
  On** (memory `hdmi-progressive-film-cadence-judder`); drift-free was HW-proven on a 45-min
  MiB clip — Akira is the second-disc confirmation.
- **Result:** _(pending)_

---

## New arrivals (carded 2026-08-17 — ripper output, all CSS-CLEAN, boot agrees with libdvdnav 4/4)

Four ISOs landed locally since the prework. Same protocol; abbreviated cards. Future ripper
arrivals get carded the same way ("Carding a new arrival" above).

### 9. `CLUE.iso` — ★ the branching-narrative vehicle (shopping-list Tier-1 #4, acquired)

- **Structure:** 2 VTS / 7 titles / 15 chapters · audio ≤2 · subp ≤1 · region 0xfe · flags: TMAP(2), **rnd**
- **Boot:** FP → `JumpSS_VMGM_PGC 3` → **VMGM PGCN 3 cell 0** (2 cells) — **libdvdnav agrees**
- **Menu key:** VTSM vts=1 PGCN 1 → `LinkPGCN 12` → `LinkPGCN 7` → VTSM vts=1 PGCN 7
- **Title end (POST):** same VTSM chain → PGCN 7 (back to the menu)
- **★ Watch:** *Clue (1985)* is THE classic multiple-endings disc — 7 titles for one film =
  the ending variants. Pick "random ending" twice across two cold boots: the `rnd` draw
  should vary (PR fj#119 entropy) and each ending should play out fully (tail-drain, PR fj#149/150).
- **Result (2026-08-17):** ✅ **CLEAN — random endings work with no issues.** The Tier-1 branching-narrative gap is closed on hardware.

### 10. `CASTLE_IN_THE_SKY.iso` — ★ parental vehicle #2 + the first non-MiB multi-angle disc

- **Structure:** 10 VTS / 21 titles / 13 chapters · **2 angles** · audio ≤3 · subp ≤2 ·
  region 0xfe · flags: **PTL_MAIT, SetTmpPML**, TMAP(10), **UNKBITS=1**
- **Boot:** FP → `JumpSS_VMGM_PGC 2` → **VMGM PGCN 2 cell 0** — **libdvdnav agrees**
- **Menu key:** VTSM vts=2 PGCN 1 → `LinkPGCN 8` → VTSM vts=2 PGCN 8
- **Title end (POST):** VMGM PGCN 6 → `JumpSS_VTSM vts=2` → `JumpSS_VMGM_PGC 5` → VMGM PGCN 5
- **★ Watch:** (a) **the corpus's first un-decoded VM bit** — `TT v4 pgc8 pre[1]` =
  `5100000000000000`, a `SetSTN` that sets nothing with one reserved bit set; decodes as a
  no-op, so expect **no visible effect** (if v4/pgc8 misbehaves, start here); (b) **2 angles**
  — B6 cycle on a second vehicle besides MiB; (c) SetTmpPML/PTL_MAIT same watch as Fairytopia;
  (d) Ghibli disc = many-audio-track anime class (JP/EN + commentary).
- **Result:** _(pending)_

### 11. `CASTLE_USD2.iso` — parental vehicle #3 (bonus disc)

- **Structure:** 1 VTS / 2 titles / 13 chapters · audio ≤2 · subp 0 · region 0xfe ·
  flags: **PTL_MAIT, SetTmpPML**, TMAP(1)
- **Boot:** FP → `JumpSS_VMGM_PGC 5` → **VMGM PGCN 5 cell 0** — **libdvdnav agrees**
- **Menu key:** VTSM vts=1 PGCN 1 → `LinkPGCN 2` → VTSM vts=1 PGCN 2
- **Title end (POST):** VTSM PGCN 4 → `LinkPGCN 1` → `LinkPGCN 2` → VTSM PGCN 2
- **Watch:** low-complexity disc; mainly a second data point for the SetTmpPML no-op.
- **Result:** _(pending)_

### 12. `ELMOPALOOZA.iso`

- **Structure:** 1 VTS / 1 title / 12 chapters · audio ≤2 · subp ≤3 · flags: TMAP(1)
- **Boot:** FP → `JumpSS_VMGM_PGC 1` → **VMGM PGCN 1 cell 0** (2 cells) — **libdvdnav agrees**
- **Menu key:** VTSM vts=1 PGCN 1 → `LinkPGCN 5` → VTSM vts=1 PGCN 5
- **Title end (POST):** `JumpSS_VTSM entry 3` → PGCN 1 → `LinkPGCN 5` → VTSM PGCN 5
- **Watch:** simplest disc in the sweep — a good warm-up/regression disc; 3 subpicture
  streams on a sing-along disc (B8 cycle).
- **Result:** _(pending)_

---

## Pass 2 triage (2026-08-17)

6 discs played, **5 with findings, 1 clean (Clue)**. Grouped by suspected root cause and
ranked by discs explained. **Nothing here is fixed yet** — each cluster names the ONE
measurement that discriminates it, because several of these have look-alike symptoms with
different roots (the Tomb Raider lesson).

Offline work already done for this triage: full VM dumps of the failing dispatchers, and a
count of how hard each disc leans on `HL_BTNN` (SPRM8) and the GPRM counter:

| Disc | VM cmds | reads HL_BTNN | writes HL_BTNN | SetMode Counter | rnd |
|---|---|---|---|---|---|
| Harry Potter | 20637 | 0 | 403 | 1 | 260 |
| **Weakest Link** | 50138 | **1426** | 90 | 1 | 2 |
| Speed Racer | 1601 | 0 | 9 | 0 | 15 |
| Family Feud II | 904 | 3 | 2 | 1 | 29 |
| Brain Game | 328 | 9 | 13 | 1 | 1 |
| Clue (clean) | 72 | 0 | 4 | 0 | 1 |

---

### Cluster A — highlight invisible on first entry (Harry Potter, Speed Racer) — 2 discs

**It is NOT a promotion bug.** The O[2] debug rects are gated on `hl_btns_armed` =
nav_pci `armed && btn_ns != 0`, and `armed` is only set inside the promote block
([nav_pci.sv](../dvd/nav_pci.sv) — `if (nxt_due)`). **The user sees the rects, so promotion
already succeeded** and the button records are fetched. What is missing is the **render**:
the highlight is drawn by *recolouring subpicture pixels* inside the button rect through
`pgc_palette → subpic_blend`, so **no subpicture bitmap = no visible highlight**, however
correct the HLI is. This is the PR fj#87 family (memory `matrix-menu-highlight-2nd-loop`:
"computes ≠ visible"), and Speed Racer's "appears on the second loop" is that signature
verbatim.

Both discs read `HL_BTNN` **zero** times, so SPRM8 is not involved — cleanly separating this
from Cluster B despite both being "menu misbehaves".

Candidate roots, in order:
1. **`spu_decode`'s menu re-send guard discards the new menu's SPU.** `S_IDLE` skips when
   `menu_mode && c_valid && sp_pts <= c_pts` ([spu_decode.sv:296](../dvd/spu_decode.sv#L296)).
   A menu whose SPU carries a *lower* PTS than the previously committed one is dropped
   outright. Harry Potter's "skip the transition and the highlight appears" fits: a user skip
   is a jump → `load_flush` → `pipe_rst_n` → `c_valid = 0` → the next SPU is always accepted.
   ⚠️ But `pipe_rst_n = reset_n & ~load_flush` and a `keep_vbuf` menu hop *does* pulse
   `load_flush`, so this only bites where the SPU and the menu are in the **same** PGC as a
   preceding transition (no jump between them) — which is exactly Harry Potter's shape.
2. **SPU arrives before `menu_active`**, so `menu_mode` is 0 and the *windowed* path gates it
   out against a parse-front-leading STC (`sp_menu_early` exists for this; it may not cover
   the in-title case).
3. Substream/routing — least likely, since the same menus render on a later pass.

> **★ Decisive measurement (2 minutes, no build):** with O[2] on, park on the Harry Potter
> Player Mode screen and the Speed Racer first-loop main menu, and report the colour of
> **blocks 3, 4, 7, 8** (second row, left to right — green = true):
> - **blk4 `spb_seen` red** → no SPU bytes reached the decoder at all → demux/substream routing
> - **blk4 green, blk3 `sp_seen` red** → bytes arrived but no subpicture pixel displayed →
>   root #1 or #2 above (the re-send guard / window)
> - **blk3 green, blk8 `hlvis_seen` red** → subpicture shows but the recolour never fired →
>   rect/coli/`hl_use` path (PR fj#83 family)
> - **blk7 `hl_on_w` red** → promotion/fetch after all, and the rect must be coming from
>   somewhere else — retract the reasoning above and start over
>
> These four probes were built for exactly this question; they turn a guess into a verdict.

### Cluster B — game dispatchers take the wrong branch (Weakest Link, Family Feud II, Brain Game) — 3 discs ★ TOP PRIORITY

All three are `HL_BTNN`/GPRM **dispatcher** discs: the button press itself does little, and
the real routing happens in a PRE/POST chain that reads SPRM8 or a GPRM and jumps. Weakest
Link reads `HL_BTNN` **1426 times** — by far the most SPRM8-dependent disc we own.

Symptoms: WL cuts to "Round winnings" exactly where the first question should appear; FF
"How to Play → Start" lands on the end-of-game Fast Money round; BG's buttons return to the
menu.

We have prior art here — SPRM8 has been wrong twice before, in ways that produce precisely
"the dispatcher picked the wrong option": PR fj#135 (`sprm8` not latched on `btn_cmd_valid`
→ menus always picked option 1, memory `sprm8-hlbtnn-latch`) and PR fj#137 (a POST read saw
the *drifting* live `btn_sel` shadow → `sprm8_frozen`, memory `atmosfear-sprm8-frozen`).
**PR fj#159 reworked promotion/arming — the layer that feeds `btn_sel` — so an SPRM8-shadow
regression is a live possibility and should be the first thing checked.**

Brain Game folds in here (see Cluster C's retraction): its buttons must set `g[3]` to
2/3/4/6 to escape the menu, and "does nothing" is exactly what an unset `g[3]` produces.

> **★ Decisive measurement — see "Round-2 measurements" below for the full version.**
> Weakest Link is the instrument (1426 `HL_BTNN` reads, and a golden `trace_nav` capture of
> the screen we never reach). Probe **SPRM8 + g[0], g[4], g[5], g[13]** at the divergence.

### Cluster C — ⛔ **RETRACTED** (counter-inflated dispatcher loop) — hypothesis was WRONG

The original theory: Brain Game's `PGC7` self-loops `LinkPGCN 7` `g[0]` times where
`g[0] = 6 + seconds-on-menu` (seeded from a counter-mode GPRM), so PR fj#119's 1 Hz tick
turned a 6-load dispatcher into a 6–50-load one = the black screen.

> **⛔ REFUTED on hardware 2026-08-17.** Pressing Start after **2 s** and after **60 s**
> produced **identical** behaviour. Dwell time does not change the outcome, so the loop
> count is not the mechanism. **Do not re-chase this.** The disc's machine as decoded below
> is still accurate and still useful — only the *inflation* theory is dead.

The IFO decode stands and is worth keeping, because it shows what Brain Game needs in
order to work at all (`VTSM vts=2`):

```
FP:    g[2]=1; g[3]=0x63; JumpSS VTSM(vts 2, menu 3)     <- boot landing is authored
PGC1:  if g[3]==0x63 -> PGC2 ... else -> PGC3            <- dispatcher (g[3]=0x63 at boot)
PGC2:  HL_BTNN=btn1; g[3]=0x62; SetMode Counter g[1]=6
       POST: g[2]=HL_BTNN/0x400; LinkPGCN 6
PGC6:  g[0]=g[1]; if g[0]>0x32 g[0]=0x23; SetMode Register g[1]=0; LinkPGCN 7
PGC7:  g[1]=0x3e8; g[1] rnd g[1]; g[0]-=1;
       if (g[0] > 0) LinkPGCN 7
       if (g[3]==0) LinkPGCN 3;  if (g[3]==0x62) LinkPGCN 3;  else LinkPGCN 8
PGC8:  dispatch g[3] -> JumpVTS_TT 1/2/3
```

**The surviving reading:** the tail of that chain routes to `PGC3` (the menu) whenever
`g[3]` is still 0 or 0x62, and only reaches the `JumpVTS_TT` dispatcher (`PGC8`) when
**`g[3]` has been set to 2/3/4/6 by the pressed button's command**. "The button does
nothing" is therefore consistent with **`g[3]` never being set** — i.e. the button's
command not taking effect — which is the same failure shape as Cluster B, so **Brain Game
is folded into Cluster B** below.

Also verified **not** a bug en route: Brain Game's odd boot landing (dispatcher takes the
`g[3]==0x63` branch at cold boot) is **authored** — First Play sets `g[3]=0x63` itself.

### Round-2 measurements (2026-08-17) — what the first probes settled

**★ My block-numbering instruction in round 1 was WRONG and is corrected here:**
blocks **1–4 are the FIRST row** (`blk1` hl_btns_armed, `blk2` video_live, `blk3` sp_seen,
`blk4` spb_seen) and **5–8 the SECOND row** (`blk5` vbuf_deep, `blk6` still_active,
`blk7` hl_on_w, `blk8` hlvis_seen). I asked for "blocks 3,4,7,8 (second row)" — those are
not the same row, and the reported second row is therefore **blk5–blk8**.

Reported second row (`blk5 blk6 blk7 blk8`):

| Disc | vbuf_deep | still_active | **hl_on_w** | hlvis_seen |
|---|---|---|---|---|
| Harry Potter (Player Mode screen) | red | red | **GREEN** | green |
| Speed Racer (first-loop main menu) | GREEN | red | **GREEN** | green |

**What this proves:**
- **`blk7` GREEN on both = `hl_on_w` (nav_pci `armed` AND `fetched`) is true.** Promotion
  *and* the button-record fetch complete. **Cluster A is definitively not a promotion or
  fetch fault** — that half of the round-1 reasoning is confirmed, and PR fj#159's promotion
  model v2 is exonerated for these two discs.
- **`blk6` red on both = the reader is NOT parked on a still**, so both are *motion/looping*
  menus. `menu_settled` cannot fire on either (it requires `still_active`), so promotion here
  came from the 1 s timer — the documented behaviour for looping menus, working as designed.
- **`blk8` GREEN is NOT trustworthy as reported.** ⚠️ The probe watched `sp_force_q`, which
  is `hud_on_w | bar_on_w | hl_use` — it reads green whenever the **transport HUD or seek bar**
  draws any pixel, regardless of the highlight. A HUD auto-popup alone turns it green.
  **Fixed in this change** ([emu.sv](../dvd/emu.sv), `hl_use_q`): blk8 now watches the
  highlight term only. The green readings above must be re-taken on the next build.
  *(Same lesson as the stale `straddle_check` model earlier in this sweep: our own probes go
  stale and lie. A probe that can be green for two different reasons answers no question.)*

**Still needed for Cluster A — the FIRST row, blocks 3 and 4** (`sp_seen`, `spb_seen`), plus
the corrected blk8:
- **blk4 red** → no SPU bytes reached the decoder → demux/substream routing.
- **blk4 green, blk3 red** → bytes arrived, no subpicture pixel displayed → `spu_decode`
  commit (the menu re-send guard, or the show window).
- **blk3 green, corrected blk8 red** → subpicture displays but the recolour never fires →
  rect/coli/`hl_use` path (PR fj#83 family).
- **blk3 green AND corrected blk8 green** → the recolour genuinely fires and is still
  invisible → the failure is downstream: the **PGC palette** lookup or the blend output.
  (Both discs recover after a PGC re-load — Harry Potter when a skip forces one, Speed Racer
  on the next loop — which fits a palette that is stale or unloaded for the new menu; see
  memory `pgc-palette-seek-reset-bug`.)

### Cluster B measurements — what came back

- **Weakest Link: "ALL menu options that start the game land on the same Round Winnings
  screen."** A dispatcher receiving a *constant* regardless of which button was pressed is
  the signature of an SPRM8/GPRM that is not tracking the activation (`sprm8` resets to
  `0x0400` = button 1). This strengthens Cluster B considerably.
- **Family Feud II: the same question no matter how long you wait** — so dwell time is not
  the entropy on this disc, and cluster F does not close for free.
- Brain Game's dwell test (above) also showed no time dependence.

Together those say **the GPRM/entropy state these discs read is not varying with time**, and
Weakest Link's says **it does not vary with the button either**. Both point at the same
place: the register state the dispatchers read.

**Ruled out by direct comparison against libdvdnav (do not re-chase):**
- **The ALU.** `tools/dvd_vm_ref.py set_op` matches `libdvdnav decoder.c eval_set_op`
  case-for-case for ops 1–7 and 9–11 (including `/=` and `%=`, and ÷0 → 0xFFFF). Weakest
  Link's engine leans on `g[5] %= 0x35f` and `g[13] = g[0] / 0x10`, and both are correct.
- **`Goto` indexing.** DVD command numbers are 1-based and the RTL does
  `pc <= blk_base + ins[7:0] - 1` ([dvd_vm.sv:1027](../dvd/dvd_vm.sv#L1027)); the python
  model matches. A jump-table off-by-one would have explained "everything lands in one
  place", but it is not present.
- **The entropy machinery is wired**: free-running `entropy_ctr`, 1 Hz `sec_tick`,
  mount-latched `rnd_seed`, gamepad `entropy_stir` ([emu.sv](../dvd/emu.sv) ~L1223).
  Whether the *tick reaches counter-mode GPRMs in practice* is still unmeasured — the tick
  is applied only in `V_IDLE` ([dvd_vm.sv:678](../dvd/dvd_vm.sv#L678)).

**Weakest Link golden-oracle reference (captured for the next round).** `tools/bin/trace_nav`
drives libdvdnav interactively, and on this disc it reaches the real game:

```
tools/bin/trace_nav WEAKEST_LINK_DES.iso "1 1"
  PARK #1  title=21 part=1  buttons=1   -> btn1 cmd 71 04 00 0e 00 00 00 19  = g[14]=0, LinkPGCN 25
  PARK #2  TT vts=21 PGC:30  buttons=12  GPRM[4]=708 GPRM[5]=118   <- the QUESTION screen
     btn1-4,7-9: HL_BTNN = 0x2c00 (button 11), LinkCN <n>
     btn5:       g[0] = 0x11, LinkPGCN 31
     btn6:       HL_BTNN = 0x1800 (button 6), LinkPGCN 42
  PGC30 PRE: g[5] += g[4]; g[5] %= 0x35f; g[13] = g[0]; g[13] /= 0x10; if (g[13]==N) Goto ...
  PGC30 POST: LinkPGCN 30 (loop)
```

So **libdvdnav reaches the 12-button question screen where our hardware shows Round
Winnings** — a confirmed divergence with a golden trace to diff against. `g[5]` (question
index, mod 863) and `g[0] >> 4` (screen dispatch) are the two values to probe.

> **★ Decisive measurement for Cluster B:** put **SPRM8 and GPRM g[0], g[4], g[5], g[13]**
> on the debug overlay, then walk Weakest Link to the failure with `trace_nav` open beside
> it and diff the registers at the divergence point. Cheap pre-check needing no build:
> on the Weakest Link player-select menu pick the **second** option rather than the first —
> if the failure is identical, a stuck SPRM8 is near-certain.

### Round-3 (2026-08-17) — ★ WEAKEST LINK ROOT CAUSE FOUND: PGCN is 8 bits, the disc needs 11

**This one is solved, offline, with high confidence.**

`tools/bin/trace_nav WEAKEST_LINK_DES.iso "1 5"` (boot → the player-select screen → SINGLE
PLAYER) shows libdvdnav walking to the question bank at **VTS 2, PGC 1381**. Our hardware
shows a "Round winnings" screen instead, for *every* option on that menu.

**Why every option:** the disc's question PGCs live in a huge PGCIT, and

| Disc | VTS_PGCIT `nr_of_srp` |
|---|---|
| **WEAKEST_LINK_DES** | **TT_02 = 1394**, TT_23 = 1021, TT_22 = 355 |
| tomb_raider_pal | TT_04 = 256 (exactly at the edge) |
| *every other disc in the library* | < 256 |

…while **our PGCN is 8 bits everywhere**:
`jump_pgcn [7:0]`, `cur_pgcn [7:0]`, `next/prev/goup_pgcn [7:0]`, `want_pgcn [7:0]`,
`link_pgcn_u/c [7:0]`, `ptt_pgcn_c [7:0]`, `rsm_pgcn [7:0]`, `deadend_pgcn [7:0]`
([dvd_iso_reader.sv](../dvd/dvd_iso_reader.sv), [dvd_vm.sv](../dvd/dvd_vm.sv)) — and the
link operand is taken as **`jump_pgcn <= ins[7:0]`**
([dvd_vm.sv:1302](../dvd/dvd_vm.sv#L1302)) when **the DVD `LinkPGCN` field is 15 bits**.

So `LinkPGCN 1381` (0x565) becomes `0x65` = **101**. The alias is *deterministic*, which is
exactly why **all** paths land on the same wrong screen rather than behaving randomly. The
intro plays normally first because PGC31's PRE/POST are reached correctly (its own PGCNs are
small) — only the jump into the question bank aliases.

Ruled out en route, by direct comparison against the golden trace (do not re-chase):
- **The ALU is exact.** Replaying PGC31's whole POST block through `dvd_vm_ref` from
  libdvdnav's entry registers reproduces `g[2]=1, g[3]=25, g[8]=2800 (the winnings!),
  g[9]=4096, g[13]=1, g[6]=0` — every value matches, including the saturating `*=`, the
  register-source `|=` bitfield pack and `/=`.
- **`Goto` indexing** (1-based, correct in both RTL and model) and the **PTT tables**
  (WL's VTS 2 title has `nr_of_ptts = 1`; max 29 across the disc — the `ptt_mem` 256 bound
  is nowhere near).

**✅ FIXED (2026-08-17, `feature/pgcn-16bit`) — see the fix note at the end of this
section.** Original fix shape: widen the PGCN path from 8 to 16 bits end-to-end — the reader's
jump/current/next/prev/goup/want/link/rsm/deadend registers and the VM's `jump_pgcn` plus
`ins[14:0]` extraction for `LinkPGCN` — and raise the PGCIT SRP walk beyond 255. Note the
golden models share the ceiling: `dvd_vm_ref.pgcit()` caps at `min(nr_srp, 99)`, so widen
that too or the model can't validate the fix.

> **⚠️ Audit gap worth remembering:** the prework capacity audit (max commands / programs /
> cells per PGC) *missed this* because it walked PGCs through `pgcit()`, which silently caps
> at 99 SRPs — the audit never saw a PGC count. **A capacity audit must measure the table
> the code indexes, not the table the tool happens to enumerate.**

#### ✅ The fix (2026-08-17) — 15-bit PGCN end-to-end

**Root of the root cause:** the DVD `LinkPGCN` operand is a **15-bit** field
(`libdvdnav decoder.c eval_link_instruction`: `getbits(14, 15)`), and
`JumpSS_VMGM_PGC`'s `pgcN` is `getbits(46, 15)`. We extracted `ins[7:0]` and
`ins[39:32]` respectively. Everything downstream was 8 bits to match.

Changed (`dvd/dvd_vm.sv`, `dvd/dvd_iso_reader.sv`, `dvd/emu.sv` wiring):

| Site | Was | Now |
|---|---|---|
| `LinkPGCN` operand | `ins[7:0]` | **`ins[14:0]`** |
| `JumpSS_VMGM_PGC` pgcN | `ins[39:32]` | **`ins[46:32]`** |
| `jump_pgcn`, `cur_pgcn`, `next/prev/goup_pgcn`, `want_pgcn`, `link_pgcn_u/c`, `jpgcn_l`, `rsm_pgcn`, `deadend_pgcn`, `srp_i` | `[7:0]` | `[15:0]` |
| PGC header `next/prev/goup` capture | low byte only (@157/159/161) | **full u16** (@156–161) |
| PRE-scan `LinkPGCN` target | byte 7 only | **`{byte6[6:0], byte7}`** |
| `ptt_mem` entry | `{pgcn_lo, pgn_lo}` (16 b) | **`{pgcn u16, pgn_lo}` (24 b)** |
| PTT resolve | `nr_pgci_srp > 255 → "garbage" → PGCN 1` | full u16 (that guard *was* the clamp) |
| SRP fetch address | 17-bit `pit_off + 8 + srp_i*8` | **21-bit** (`srp_i*8` needs 19) |

**Regression test — `dvd_vm_tb` S13**, which reproduces the bug exactly when the fix is
reverted: `LinkPGCN 1381` → **`got pgcn=101`**, the precise `1381 & 0xFF` alias predicted
from the disc analysis. S13 covers a large `LinkPGCN`, a small one (no regression on normal
discs), and a large `JumpSS_VMGM_PGC`.

**Golden model:** `IsoNav.pgcit()` capped enumeration at `min(nr_srp, 99)`, which is why the
prework capacity audit never saw a PGC count. Raised to the spec bound; it now enumerates all
1394 of Weakest Link's VTS_02 PGCs.

**Regression status:** `dvd_vm_tb`, `dvd_vm_atmos_tb`, `iso_reader_tb`, `iso_reader_menu_tb`,
`iso_reader_seek_tb`, `iso_reader_chapter_tb`, `iso_reader_real_tb`, `iso_reader_vm_tb` — all
green.

> **HW gate:** Weakest Link → pick any number of players + LET'S PLAY (or SINGLE PLAYER) →
> the **first question** should appear instead of the Round Winnings screen. The golden path
> to diff against is `tools/bin/trace_nav WEAKEST_LINK_DES.iso "1 5"` → VTS 2, PGC 1381.
> Also re-check a normal disc (MiB/Matrix) for no menu regression, and Tomb Raider, whose
> TT_04 PGCIT sits at exactly 256.

### Round-4 (2026-08-18) — Weakest Link plays, but the answer window is cut: DRAIN_WD < an authored cell

**HW after the PGCN fix:** the game now reaches the real questions ✅. New symptom: *"there is
a timer for answering (not visible on screen) and it expires as soon as the highlight appears,
showing 'Too Late!' and moving to the next player."*

**Decoded from the disc.** The answer screen is **VTS 8 PGC 51**, and its cell table is the
whole story:

| cell | sectors | size | authored pbtime |
|---|---|---|---|
| **0 (the answer window)** | 32961–33271 = **311** | **0.6 MB** | **17 s** |
| 1–6 (the "time's up" branches) | ~69 each | 0.14 MB | 1 s |

`cell[0].cmd_nr = 1` → `cellc[0] = LinkCN 2`, i.e. when cell 0 ends the disc jumps into the
timeout branch. Its POST reads the answer out of `HL_BTNN`
(`g[14] = HL_BTNN; if (g[14]==0x1400) …` — button 5 = 0x1400 is the neutral/no-answer
position that `fosl` selects, and the answer buttons 1/2/4 are `auto_action`).

**The mechanism:** 0.6 MB **fits entirely inside the 2 MB VBUF**. So the reader parses the
whole 17-second cell in a fraction of a second, hits the cell end, and the cell command's
verdict is produced at the **parse front** while the display is still at the start of the
question. The Phase-B tail drain (PR fj#150) is exactly the guard for this — a natural
cell-command verdict waits for `vbuf_empty` — and it *does* engage here (`ev_cellcmd` →
`nat_src` → `vm_from_wait` → `snat_l`). But it is bounded by **`DRAIN_WD`, which was 5.0 s**,
and `vbuf_empty` cannot arrive until the decoder has displayed all 17 s. **The watchdog fired
first and truncated a 17-second answer window to 5 seconds.**

**Fix:** `DRAIN_WD` 5 s → **60 s**, sized from the thing that actually bounds the wait: the
time for the decoder to *display* a full VBUF. 2 MB at the ~300 kbit/s these screens are
authored at is ~56 s. Normal transitions are unaffected — they exit early on `vbuf_empty`;
the bound only ever fires when `vbuf_empty` never arrives (a wedged decoder), which is
already a failure state. `drain_tmr` widened 28 → 31 bits.

> **⚠️ This fix may be necessary but not sufficient — flagged before testing.** The same
> parse-vs-display skew applies to the *button* timeline: because the entire cell buffers at
> once, every PCI/HLI packet in those 17 seconds is parsed within a fraction of a second, so
> nav_pci sees the whole arm/disarm schedule up front and only the (parse-anchored) STC paces
> it. If the highlight still appears at the wrong moment after this fix, that is the next
> thread — and it is the same family as Cluster A. Watch specifically whether the answer
> buttons are *responsive* before they are *visible*.

### Round-5 (2026-08-18) — the DRAIN_WD fix did NOT change it; the symptom is re-framed

**HW report:** *"still too fast, seems the same speed as before. The buttons are responsive
before the highlight — it turns out the highlight is a different colour depending on whether
you got the answer right or wrong, and the highlight I was seeing was revealing the correct
answer, not a highlight for selection."*

Two things follow, and they matter more than the timing question:

1. **The answer buttons ARE armed and responsive during the window** — so nav_pci's HLI
   handling on this screen is working. This confirms the caveat filed with the DRAIN_WD fix:
   the button timeline runs at the parse front.
2. **There is no visible SELECTION highlight at all.** The only thing that ever becomes
   visible is the disc's answer *reveal*. So Weakest Link is unplayable for the same reason as
   Speed Racer and Harry Potter — **Cluster A, the highlight render** — not (or not only) a
   timer bug. You cannot answer a question when you cannot see which answer is selected.

**Offline finding that gives Cluster A a WL-specific lead.** Scanning the answer cell's
sectors (VTS_08 title VOB, RBN 32961+) shows what is multiplexed there:

```
stream 0xE0 (video) 33   substream 0x80 (audio) 55
substream 0x20 0x21 0x22 0x23 0x24 0x25 0x26 0x27 0x28 0x29   <- TEN subpicture streams
```

The screen carries **ten subpicture substreams**, each sent as a small one-shot SPU — and
`ps_demux` filters to **exactly one** substream. If the selection graphic lives on a stream we
are not routing, no amount of correct HLI handling will make it appear. The disc also uses
`SPSTN` (SPRM2, the *subpicture stream number*) as a **game variable** — VTS2 PGC1381's POST
does `g[13] = SPSTN; g[13] %= 0x40;` and scores the answer from it (`g[7] += 0/2/5/10/20/30/45`),
and the disc issues `SetSTN` 9 times across VTS2/VTS8. So on this disc the subpicture stream
selection is *gameplay state*, not a user preference.

**On the timing half:** the gate chain was traced and is correct in principle —
`ev_cellcmd` → `blk=BLK_CELL` + `nat_src=1` ([dvd_vm.sv:827](../dvd/dvd_vm.sv#L827)) →
`vm_from_wait` → `seek_natural_mux` ([emu.sv:1322](../dvd/emu.sv#L1322)) → `snat_l` → the seek
waits on `vbuf_empty`. Since the observed speed did not change, either the build under test
predates the fix, or the display is not in fact being cut and the "fast" impression comes
entirely from the invisible selection highlight. **Not chasing it further until that is
measured** — two hypotheses on this symptom have already died (`foac`, which is 0 on every
HLI this disc authors, and `auto_action`-on-arm, which cannot fire because `moved` is set only
by D-pad navigation).

> **★ Two measurements needed (both cheap):**
> 1. **Which `.rbf` was under test** — `DVD_pgcn16_drain_20260818_1149.rbf` carries the
>    DRAIN_WD fix; `DVD_pgcn16_MARGINAL_*` does not.
> 2. **Roughly how many seconds the question stays up before the reveal.** ~17 s ⇒ the cell
>    plays correctly and this is purely a render bug (fold into Cluster A). ~1–5 s ⇒ the cell
>    IS being cut and the drain gate is not doing its job.
> 3. Optional but decisive for the render half: the O[2] **first-row** blocks (blk3 `sp_seen`,
>    blk4 `spb_seen`) on the answer screen — with ten substreams multiplexed, blk4 red would
>    mean we are routing a substream that carries nothing on this screen.

### Round-6 (2026-08-18) — ★ ROOT CAUSE: the answer cell is ONE I-FRAME held for 17 s

Measurements: the **drain build was under test**, the question holds **~1.5 s**, and the O[2]
first row on the question screen reads **green green green green** (armed, video_live,
sp_seen, spb_seen) before flipping to red at the transition.

**Decoding the cell's actual content settles it.** Extracting the video ES from all 311
sectors of VTS 8 PGC 51 cell 0:

```
video ES bytes = 64837   picture headers = 1   GOP headers = 1
```

**One picture.** The 17-second answer window is a **single I-frame that the disc expects the
player to HOLD for the cell's authored playback time** (`pbtime = 17 s`, with
`still_time = 0` — the hold is expressed by the cell's *duration*, not by a still flag).

That explains every observation at once, including the two failed fixes:

- **~1.5 s, not 5 s and not 60 s.** The tail-drain gate is not timing out — it is **passing
  immediately**, because `vbuf_empty` is *true*: there is only one frame to decode, 64 KB
  drains instantly, and the compressed buffer really is empty while the frame is still meant
  to be on screen for another 16.5 s. **Raising `DRAIN_WD` could never have helped**, which is
  exactly what the hardware said.
- **The buttons are responsive** — the NAV packs across all 311 sectors are parsed within that
  same fraction of a second, so the HLI arms correctly and early.
- **`spb_seen` red at the transition** — the cell command's seek executes with a flush.
- **All four first-row probes green on the question screen** — the subpicture *does* arrive and
  display here, so Weakest Link is **not** blocked on the Cluster-A render bug after all. Its
  selection highlight is invisible for a different reason (or is simply not authored as a
  recoloured subpicture on this screen); the window closing in 1.5 s is the whole problem.

**Why our model of "cell end" is wrong.** The reader ends a cell when its **sectors are
delivered**. For ordinary cells that is close enough (the display trails by the VBUF depth,
and `vbuf_empty` bridges the gap). For a **still-image cell** the two diverge completely:
the data is exhausted in ~0.2 s while the authored presentation time is 17 s. A real player
ends a cell when its **authored playback time has elapsed on the display timeline**.

**Fix direction (next change).** This is the sibling of PR fj#144, which honoured an explicit
`still_time` on title-domain cells; here the hold is authored as `pbtime` with
`still_time = 0`. Hold such a cell for its authored duration before running the cell command:
reuse the existing `still_secs`/`still_timed`/`STILL_CMD` machinery (the freeze path is already
HW-proven for Thayer's Quest timed choices), sourcing the duration from the cell playback time
the reader already reads for the HUD (`cell_start_mem` prefix sums). Scope it the same way
PR fj#144 was — title domain + `vm_mode` + the cell carries a cell command — so ordinary movie
playback is untouched. The natural trigger is "content exhausted (`vbuf_empty`) but the cell's
authored time has not elapsed".

⛔ **Retracted by this finding:** the `DRAIN_WD` 5 s → 60 s change (previous round) was
predicated on the wait timing out. It does not, so the raise is inert for this disc. It is
harmless and arguably still correct as a deadlock bound, but it is **not** the fix and must not
be recorded as one.

> **✅ FIXED + HW-CONFIRMED 2026-08-18 (PR fj#165):** the general real-player model — a
> title-domain (vm_mode) cell end that dispatches to the VM (cell command / PGC end) with
> ≥2 s of its authored `C_PBTM` unspent on the DISPLAY clock serves the residual as a
> timed still first, so the cell command evaluates at the cell's authored end. Design +
> implementation detail: `docs/dvd_nav.md` "Authored cell duration". HW verdict: WL
> questions hold for the correct time and are answerable; no regressions on the other
> menu discs. **New finding from the same HW round: WL's questions are NOT random** —
> the same question sequence every run. That is a separate issue: WL joins the
> **Cluster-B entropy family** below (Brain Game / Family Feud II — dispatcher registers
> not varying), it is NOT part of the cell-timing fix.

### Round-7 (2026-08-25) — ★ the OTHER half of the authored duration: the C_PBTM FRAME FIELD

**HW report:** gameplay works, but the **correct/wrong answer reveal** shown after choosing
an answer and the **"money banked"** screen shown after pressing Bank both flash past in
**under a second**; a real player (checked against gameplay footage) holds each for about
**two**. Questions themselves hold for the right time — i.e. the Round-6 fix is working.

**Decoded from the disc — the screens are 1.96-second cells stored as 1 second.** The
gameplay loop was traced with `tools/bin/trace_nav WEAKEST_LINK_DES.iso "1 5 1 1 1 …"`:
answering a question runs the button's auto-action → POST → `LinkCN 5`, so the reveal is
**VTS 18 PGC 29 cell 5**; banking lands on **VTS 02 PGC 248 cell 0**. Dumping their cell
records and demuxing their video:

| screen | cell | C_PBTM | pictures in the cell | real length |
|---|---|---|---|---|
| answer reveal | VTS18 PGC29 cells 1–6 | `0:00:01` + **24 f** @25 fps | **1** | **1.96 s** |
| money banked | VTS02 PGC248 cell 0 | `0:00:01` + **24 f** | **1** | **1.96 s** |
| chain/bank status | VTS02 PGC1381 cells 0–6 | `0:00:03` + 23 f | 1 | 3.92 s |
| question (works) | VTS18 PGC29 cell 0 | `0:00:17` + 23 f | 1 | 17.92 s |

`C_PBTM` is `{hh, mm, ss, rate|frames}` and the reader summed **hh:mm:ss only**, dropping
the frame field. This disc (PAL, 25 fps) authors its short screens as *N seconds +
(fps−1) frames* = N+1 seconds minus a frame, so 1.96 s stored as **1 s** — and 1 s is
**below `RESID_MIN` (2 s)**, so the Round-6 hold was never armed and the single I-frame
flashed by in decode time. The 17 s question cleared the threshold, which is precisely why
one screen worked and the other did not. Same authoring style is everywhere on this disc:
**5,279 cells at exactly `1 s + 24 f`**.

⛔ **Ruled out before the disc was decoded** (worth recording — both fit the symptom):
the mid-PGC plain-advance path (which by design serves no hold) is not involved — every
gameplay cell on this disc carries a cell command; and the user-button provenance
(`nat_src`, PR fj#150) is not involved either — these cells flash on any path, the press
just happens to be how you reach them.

> **🔧 FIXED, ⏳ HW-confirm pending (branch `fix/cell-duration-frames`):** the stored
> per-cell duration now rounds the frame field to the nearest second (`pb_dur_w`), so the
> reveal and banked screens hold 2 s and the status screens 4 s. `pb_c` stays truncated
> where the libdvdnav still HEURISTIC reads it (lockstep with `vm.c`), and `RESID_MIN`
> stays 2 s so sub-second cells — Deal or No Deal authors ~1,800 of them — keep their
> current no-hold behaviour. Detail + the accepted ±0.5 s quantisation:
> `docs/dvd_nav.md` "Authored cell duration → Amendment (2026-08-25)".

### Round-3 — Cluster A SPLITS: the two highlight bugs have DIFFERENT roots

First-row probes (`blk1` hl_btns_armed, `blk2` video_live, `blk3` sp_seen, `blk4` spb_seen):

| Disc | armed | video_live | **sp_seen** | **spb_seen** | Verdict |
|---|---|---|---|---|---|
| Speed Racer (1st-loop menu) | green | green | **RED** | **RED** | **no SPU bytes reach the decoder at all** |
| Harry Potter (Player Mode) | green | green | **green** | **green** | SPU arrives *and* subpicture pixels display |

**A1 — Speed Racer: the subpicture never arrives.** `spb_seen` is latched from `ps_sp_valid`
and cleared by `pipe_rst_n`, so since the last jump **not one subpicture byte has been routed
out of `ps_demux`**. That is a *demux-side* fault, upstream of `spu_decode` entirely — so the
re-send guard, the show window and the palette are all irrelevant here. Prime suspect: the
subpicture enable/substream gate (`sp_en` drives both `spu_decode.enable` and
`ps_demux.sp_enable`) rises only once `menu_active` asserts, by which time the menu cell's
SPU packet — which sits at the top of the cell — has already streamed past and been
discarded. The next loop re-sends it with the gate up, which is precisely the observed
"appears on the second loop".

**A2 — Harry Potter: the subpicture is there and displaying, but no highlight.** Bytes arrive
and a subpicture pixel lands inside the frame, with the HLI armed and fetched (`blk7`). So the
failure is downstream of the bitmap: either the recolour never fires (`hl_use`) or it fires
and resolves to an invisible colour (PGC palette). **This needs the corrected `blk8`** — the
old one was aliased to the HUD (see Round 2), so its green told us nothing.

**Consequence for Pass 3:** these are two separate fixes, not one. Lumping them in round 1 was
wrong; the measurement split them.

### Cluster B splits too

- **B1 — Weakest Link: SOLVED** (8-bit PGCN, above).
- **B2 — Brain Game + Family Feud II + Weakest Link: still open.** (WL added 2026-08-18:
  with the answer window fixed by PR fj#165, its question sequence is measurably identical
  every run — the same non-varying-registers family.) Their PGCITs are well under 255, so the
  PGCN truncation does **not** explain them; they need the SPRM8/GPRM probe. Brain Game needs
  a button to set `g[3]` to 2/3/4/6; Family Feud shows the same question regardless of dwell.

### Cluster D — transitions/branches not seamless (Harry Potter, Speed Racer) — 2 discs

- **Speed Racer:** ~0.5 s hitch at the race's correct/incorrect **video branches**. That is
  the seamless-branch/ILVU path (PR fj#112, memory `seamless-branch-ilvu-navigation`) — either
  the branch is not being followed via `next_vobu` or it is taking a flushing jump.
- **Harry Potter:** skipping a transition leaves the static image **pixelated for a few
  seconds**. The menu still cold re-decode (PR fj#116) is supposed to give a clean image; a
  few seconds of macroblocking says the re-decode started mid-GOP rather than on the still's
  I-frame.

Both are quality-of-transition, not navigation — genuinely lower priority than A/B/C, but
they share the "what happens at a cell boundary" surface, so triage them together.

### Cluster E — still/timed-still duration (Harry Potter score card) — 1 disc

The in-game score card holds ~2 s and should hold longer. Timed stills are PR fj#90/#144
territory (`still_time`, and the title-domain gate widened to `menu_dom || vm_mode`).
Worth checking whether the card's cell authors a finite `still_time` that we are honouring
with the wrong time base, or an indefinite still we are cutting short. Low cost to check
offline once the exact PGC is identified.

### Cluster F — Family Feud II always asks the same question (1 disc)

FF authors 29 `rnd` sites and one `SetMode Counter`, so it is the same entropy family as
Brain Game — and Cluster C establishes that the counter **does** tick. **Before treating this
as a bug, vary the input:** if the disc seeds its draw from the counter (as Brain Game does),
then *dwell time before pressing New Game is the entropy*, and starting a game after a
different wait should change the question. Real hardware behaves the same way.

> **⛔ MEASURED 2026-08-17: the question is identical no matter how long you wait.** So this
> does NOT close as authored — dwell time is not the entropy here. Family Feud stays open and
> merges into the Cluster B investigation (the registers its dispatcher reads are not
> varying), together with the unmeasured question of whether `sec_tick` actually reaches
> counter-mode GPRMs in `V_IDLE`.

### Note G — `CH 92/2` on Weakest Link is a known deferred limitation, not a new bug

The HUD showed chapter 92 of a 2-chapter total. `docs/conformance.md` §1 already records
that PTT-based current-chapter `n` is **deferred for multi-PGC game discs** (the resident
`ptt_mem` + `chap_st` walk assume the movie-disc shape). Cosmetic; useful mainly as
confirmation that WL's failure happens deep inside a multi-PGC dispatcher title.

---

## Recommended Pass-3 order

1. **B1 — 16-bit PGCN widening (Weakest Link).** Root cause proven offline; a self-contained
   RTL change with a golden trace to verify against. Highest confidence, do it first.
2. **A1 — Speed Racer's missing subpicture** (`sp_en` gate vs the cell's leading SPU packet).
   Also self-contained, and the "2nd loop" recovery is a built-in test.
3. **A2 — Harry Potter's invisible highlight** — needs the corrected `blk8` readout first
   (no new build required beyond the probe fix already in this change).
4. **B2 — Brain Game + Family Feud** — needs the SPRM8/GPRM overlay probe.
5. **Clusters D/E** — transition/still quality, after the navigation bugs.

**Next build should carry:** the de-aliased blk8 probe (in this change), the 16-bit PGCN
widening, and an SPRM8/GPRM readout — so one flash tests B1, A2 and B2 together.
⛔ **Cluster C is retracted, not pending** — do not spend another build on it.

---

## After the sweep

1. Fill in every Result line (including "clean").
2. Triage per Pass 2 above; write the root-cause list here before opening any branch.
3. Update `docs/conformance.md` for any gap the sweep closes or newly exposes, and flip this
   file's status line at the top.
