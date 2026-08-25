# DVD-VM interpreter (`dvd/dvd_vm.sv`) — Phase 4 disc menus

**Status: HW ROUND 1 PASSED core acceptance (2026-07-07, branch `feature/dvd-vm`);
round-2 fixes shipped, re-test pending.** Sim: unit tb (`bench/dvd/dvd_vm_tb.sv`: 27
golden-model vectors bit-exact + 9 dispatch scenarios) + reader+VM end-to-end
(`bench/dvd/iso_reader_vm_tb.sv`) + PTT resolve (`bench/dvd/iso_reader_ptt_tb.sv`).

**HW status (3 rounds): CORE ACCEPTED — merged as PR fj#82.** BBB/MiB/Matrix all
navigate menus and play the correct titles/features. Remaining items are per-disc
nav_pci highlight rendering + transition polish, tracked in
**`docs/dvd_menu_refinements.md`** (a follow-up track, not a phase gate; `O[1]`
defaults Off so normal playback is unaffected). T2 Ultimate — an extreme case
(GPRM timeline state machine) — surfaced highlight fill/offset/visibility +
transition-freeze issues recorded there.

### HW round 1 (what the user confirmed on the DE10-Nano)

**Accepted:** BBB boots the FP chain → menu → **selecting Play runs the correct main
movie** (the headline largest-VTS failure — fixed). POST kicks back to the menu at
feature end (BBB). Menus-Off = clean Phase-3 regression. MiB/Matrix menus navigate.

**Round-2 fixes (HW-confirmed):**
- **OSD track controls stopped working after a disc-menu track pick** ✅ fixed + HW-
  confirmed. The SetSTN→SPRM mux preferred the disc's SPRM permanently. Now most-
  recently-touched wins (`vm_owns_aud`/`vm_owns_sp` clear the instant the OSD control
  moves). See emu.

**Round-3 fix (re-test pending) — Matrix special features all played the main movie:**
Two causes, both needed:
- `JumpVTS_TT`/`JumpTT` used an entry-scan heuristic that falls through to SRP[0] = the
  feature when title PGCs carry no entry markers → added the real **VTS_PTT_SRPT**
  `vts_ttn→pgcn` resolve (reader S_PTT_MAT/OFF/PGC; `iso_reader_ptt_tb`). *(Phase-6
  mechanism pulled forward for the title-jump case; chapter/PTT skip UI still Phase 6.)*
- **The real blocker:** Matrix has **no VMGM VOB** but routes menus through VMGM PGCs
  used as **0-cell command-only dispatchers** (a GPRM state machine — a VTSM Root's
  `pre = JumpSS VMGM pgc 19` reads `g[15]` and jumps to the chosen special's title).
  The reader **rejected any VMGM/VTSM jump when the menu VOB was absent** → `pgc_error`
  → the VM fallback played the feature. Fixed: gate on the VMGI / VTSI only; the menu
  VOB is optional (a 0-cell PGC is a command stub the VM runs; `iso_reader_vmgm_tb`).
  Decoded from the real disc with `tools/nav_extract.py` + `iso_nav_check.py`.

**Open follow-ups (need HW to diagnose; not blocking):**
- *Matrix main-menu highlight arrives one menu-loop late when the intro is skipped*
  (returning from a movie/submenu). The highlight is correct once it appears — this is
  a nav_pci HLI arm-window-vs-re-anchored-STC timing issue after a jump (the Phase-3
  "stream-lead" family), self-heals on the menu's next PCI re-send. Deferred.
- ~~*MiB "Play" cuts the menu's transition animation short with a brief black frame
  before the feature.*~~ **✅ RESOLVED — HW-CONFIRMED 2026-07-14.** MiB "Play" now plays the
  authored menu→feature transition through (the FBI / copyright warning clips) instead of
  cutting out early and jumping straight to the movie. The earlier "VBUF flush discards the
  animation tail" framing was incomplete — the real symptom was the menu→title Play dispatch
  chain (`LinkPGN 5` → `LinkTailPGC` → POST → `JumpSS`/`JumpTT`) landing past the authored
  transition cells; the recent VM navigation corrections fixed the landing (most likely the
  Scene It `JumpVTS_TT`/`JumpVTS_PTT` `jump_vts <= cur_vts` fix, PR fj#120, and/or the
  `V_PGSCAN` program-map fix, PR fj#122). User-confirmed on hardware.
- *Selecting a commentary track silences the menu's own audio* — expected when the
  menu VOB has no such substream; low priority.

## What it is

The DVD Virtual Machine: executes the disc's 8-byte navigation commands (PGC
pre/post/cell command tables, menu button commands) so authored discs behave like
they do in a standalone player / VLC:

- **Boot**: mounting an ISO with `O[1] Disc Menus = On` runs the **First Play PGC**
  instead of auto-playing a heuristic title. BBB's `JumpTT 4` warning-clip chain,
  MiB's logo → conditional menu route — all just work off the disc's own program.
- **Menus route correctly**: MiB's 0-cell **JumpSS trampoline** (root stub →
  `g14=0x3500` → VMGM dispatcher PGC → `JumpSS VTSM vts 2` → `LinkPGCN 5`) executes
  for real — the Phase-2 `best_menu_vts` heuristic becomes a fallback only.
- **Buttons execute**: the Phase-3 micro-bridge (LinkPGCN/LinkTailPGC only) is
  deleted; a button's command runs through the same interpreter (SetGPRM dispatch,
  JumpTT to any title, CallSS, SetSTN...).
- **Titles end properly**: POST commands run when a PGC finishes (after the video
  drains), typically jumping back to a menu.
- **Stream selection**: `SetSTN` writes SPRM1/2 and drives the demux audio/subpicture
  track selects (the disc's audio/subtitle menus now actually switch streams).

## Semantics (frozen decode)

A faithful port of **libdvdnav `src/vm/decoder.c` `eval_command`**:

- Compare ops: 1 `&` (bitwise AND ≠ 0), 2 `==`, 3 `!=`, 4 `>=`, 5 `>`, 6 `<=`, 7 `<`;
  op 0 = always true.
- Set ops: mov, swap (`reg2` gets old `reg`), add/mul **clamp to 0xFFFF**, sub
  **clamps to 0**, div/mod **by zero → 0xFFFF**, rnd = 1..data, and/or/xor.
- `Goto` lines are 1-based within the current block; `Break` ends the block and is
  identical to falling off the end (pre → play, post → authored next_pgcn, cell →
  advance).
- Per-type ordering: types 1/2/3/5 evaluate the compare **before** the set
  (`link_cond_l` latched in V_EXEC); **type 4 sets first and compares after**
  (V_LINKEV uses the live `cond_v4`) — this is the `g9 += 1, if (g9 >= 3) LinkTailPGC`
  loop-counter idiom.
- **Deviation**: command types 5/6 use the **vmcmd.c bit layout** (if_version_5 /
  set_version_3). decoder.c marks its own type-5/6 handling "FIXME wrong" (it reads
  bits 51:48 as both compare and set register); our `decode_vmcmd` (a vmcmd.c port)
  validated MiB/Matrix/T2 with zero unknown-bit warnings, so vmcmd.c wins.
- `eval_reg`: bit7 = SPRM (index & 0x1F), else GPRM (& 0x0F). Link-subinstruction op
  = **low 5 bits** of byte 7 (decoder.c `getbits(4,5)`).
- **JumpSS vs CallSS share `lnk_op` 6/8 but DECODE DIFFERENTLY** (decoder.c). For the
  VTSM sub-destination (`getbits(23,2)==2`): **JumpSS_VTSM** = `vtsN getbits(31,8)`,
  `VTS_TTN(SPRM5) getbits(39,8)`, `menu getbits(19,4)` → *opens a new VTSI (changes VTS)*.
  **CallSS_VTSM** = `menu getbits(19,4)`, `rsm_cell getbits(31,8)` → *no vts field; STAYS
  in the current VTS* (vm.c: "Must be called before the domain is changed"). Sharing one
  handler (applying JumpSS's vts field to CallSS) was the **Matrix "Follow the White
  Rabbit" boot bug**: the bumper's `CallSS VTSM (menu 3, rsm_cell 1)` was read as "jump to
  VTS 1", and VTS1's VTSM Root command-stub trampolined `JumpSS VMGM PGC19 → JumpTT 6` =
  the rabbit branch PGCN 6, so the rabbit played for the whole feature. Fixed by splitting
  the VTSM branch on `lnk_op` (CallSS → `jump_vts = cur_vts`, no SPRM5 write). Regression:
  `dvd_vm_tb` [S10]. See [[matrix-white-rabbit-always-on]].
- **In-title `LinkPGCN` must carry `cur_vts`, not `vm_vts`** (the multi-PGC GAME-title VTS
  bug — Tomb Raider "return to a previous choice freezes"; ✅ **HW-CONFIRMED + MERGED PR fj#145**,
  2026-07-29). A title is entered via `JumpTT`,
  which deliberately sets `vm_vts=0` (the title→VTS resolution lives in the reader). An
  in-domain PGC link (`LinkPGCN` / `LinkTopPGC` / `LinkNext/Prev/GoUpPGC`) shipped
  `jump_vts <= vm_vts = 0`, so the reader tried to load "VTS 0" instead of staying in the
  current title → mis-resolve → `S_DONE` dead-end → video freeze. Movies never do a
  cross-PGC in-title `LinkPGCN` (single-PGC titles), so only multi-PGC game titles hit it;
  TR's choices return to earlier PGCs via `LinkPGCN`. Same class as the `JumpVTS_TT` "Scene
  It boot bug". Fix: `link_jump_vts = (vm_dom==DOM_TT) ? cur_vts : vm_vts` at all three
  in-domain PGC-link sites (menu domains keep `vm_vts`, authoritative). Pinned on HW with
  the reach-history overlay (rows 21-26: reader dead-ended `menu_dom=0`, `cur_vts` fell 5→0
  across the PGC chain). Regression: `iso_reader_intitle_link_tb`. NB this also DISPROVES the
  old "VMGM PGC4 1-cell PRE-dispatcher" theory — the freeze is TITLE-domain, and
  `iso_reader_predispatch_tb` shows 1-cell dispatchers already work.
- **Menu-domain `JumpVTS_TT`/`JumpVTS_PTT` must carry `vm_vts`, not `cur_vts`**
  (the **Hobbit boot-loop bug**, `feature/zero-cell-robustness`, 2026-08-19 —
  the mirror image of the two entries above). The Scene It boot fix hardcoded
  `jump_vts <= cur_vts` in both ops; correct *in a title*, but from a MENU the
  "current VTS" is the menu's VTS (`vm_vts`, kept exact by `JumpSS/CallSS_VTSM`)
  and `cur_vts` is the STALE last-played-title VTS. THE_HOBBIT_UNEXPECTED_JOURNEY
  boots FP → `JumpTT 4` (a VTS_03 warning) → … → VTS_01 VTSM pre `JumpVTS_TT 3`,
  which dispatched with vts=3 and reloaded the warning instead of VTS_01's
  settings-trampoline title 3 — so the trampoline POST's `g[6]=1` menu-entry flag
  never set and the boot ping-ponged VMGM ⇄ VTSM ⇄ warning forever (the HW black
  screen with Disc Menus On). Most discs never expose it: their boot never plays
  a title from a *different* VTS before the menu. Fix: both ops now use
  `link_jump_vts` (the domain-dependent rule above) — in-title behaviour is
  bit-identical by construction. Same change retires the documented
  `JumpSS_VTSM` vts==0 quirk (its `vm_vts` fallback → `link_jump_vts`, so a
  title POST's "stay in current VTS" resolves via `cur_vts` instead of shipping
  0 → `pgc_error` → a fallback title replay). Regressions: `dvd_vm_tb` S19/S20
  (the disc's real 34-command trampoline POST + 11-command VTSM pre, golden-model
  register-exact), `bench/dvd/iso_reader_zerocell_tb.sv` (the full boot chain
  over a synthetic ISO with the disc's real command bytes AND its zero-backed
  cells — which the pipeline handles fine; the wedge was never the zeros), and
  the `iso_reader_vm_tb` fixture grew an honest 4-sector title (its old 2-sector
  title relied on the quirk's fallback replay for T2's menu-key timing).
- **Cross-PGC `LinkPTTN` + SPRM5-after-JumpTT** (the Tomb Raider "choice → clip →
  return to the same choice **freezes**" *residual*, after the `LinkPGCN` fix
  above; ✅ **HW-CONFIRMED + MERGED PR fj#145**, 2026-07-29 — open-door + look no
  longer freeze). Pinned on HW with the row-22 last-jump overlay: both freeze spots
  reached title PGCs (VTS5 PGC4, PGC11) whose POST is a `LinkPTT` (LinkPTTN),
  vts correct — so the dead-end was the `LinkPTTN` itself. Our VM only followed a
  `LinkPTT` whose part is a program of the *current* PGC (light `V_PMRD` walk); on
  multi-PGC game titles the part lives in a *different* PGC, so `pg_tgt > nr_pgms`
  overflowed → benign `vm_adv` → `S_DONE` → freeze. **Fix (two coupled parts):**
  (1) `dvd_vm.sv` — on that `V_PMRD` overflow (cross-PGC), fall back to the EXACT
  `VTS_PTT_SRPT` resolve (`jump_ptt`, like `JumpVTS_PTT`), staying in the current
  title (`jump_ttn = SPRM5`), PRE skipped (libdvdnav LinkPTTN); same-PGC /
  single-PGC-movie `LinkPTT` still uses the light `V_PMRD` path, unchanged.
  (2) `dvd_iso_reader.sv` — `res_ttn` (→ SPRM5 = VTS_TTN) was `= want_ttn`, which
  the PTT resolve clears in `S_PTT_PGC` *before* `pgc_loaded`, so on any disc with
  a `VTS_PTT_SRPT` a `JumpTT` left **SPRM5=0** → (1)'s `jump_ttn=SPRM5` resolved
  part N of title 0 = garbage. `res_ttn` now = `cur_ttn` (the persistent
  loaded-title vts_ttn latched in `S_PTTLD_MAT`) — a real latent bug beyond Tomb
  Raider. Regression: `iso_reader_linkptt_tb`. See [[tr-intitle-linkpgcn-vts-freeze]].
- The **golden model is `tools/dvd_vm_ref.py`** (same eval + a vm.c-level dispatcher);
  `dvd_vm_tb` checks the RTL against its emitted vectors **bit-exactly, including the
  rnd LFSR16** (taps 0/2/3/5, seed 0xACE1, stepped once per rnd op).

## Registers

- **GPRM[16]** × 16 bit; `gprm_mode` stores SetGPRMMD's counter bit (the mode bit is
  written even when the guard fails, per decoder.c). Counter-mode GPRMs **tick at 1 Hz**
  (see "DVD-game entropy" below).
- **SPRMs implemented**: 1 ASTN (init 15 = none), 2 SPSTN (init 62), 3 AGLN, 4 TTN,
  5 VTS_TTN, 6 TT_PGCN, 7 PTTN, 8 HL_BTNN (init 0x400), 9/10 NVTMR (stored, never
  fires), 13 PML. Constants per libdvdnav `vm_reset`: SPRM0/16/18 = 'en', 12 = 'US',
  14 = 0x100, 15 = 0x7CFC, 20 = 1 (region free).
- **SPRM8 shadows nav_pci's live selection** while buttons are armed (D-pad moves
  change it outside the VM); `SetHL_BTNN` / link button fields write both `sprm8`
  and nav_pci (via the new `sel_force` port).
- Reset domain: **`reset_n`, NOT `pipe_rst_n`** — GPRM/RSM state must survive seeks
  and jumps (the pgc-palette seek-reset lesson). A mount (`start`) runs `vm_reset`.

## DVD-game entropy (Scene It et al.) — ✅ HW-CONFIRMED (PR fj#119)

**HW (2026-07-13, `DVD_gameentropy_20260713_1839.rbf`, O[1] Disc Menus ON):** Scene It plays
a **different question on each disc load** (the old build always replayed the same clip). The
"Optreve reset / re-shuffle" screen is Optreve's normal behaviour (→ main menu). Separate,
still-open Scene It nav bugs (NOT entropy): boots to a question before the Optreve-reshuffle →
main menu (boot-path ordering); HP Menu re-plays the logo instead of parking on the authored
indefinite-still menu. Trace with `tools/bin/trace_boot` / `trace_menukey`.

**The only entropy on a real DVD player is wall-clock time.** Game discs (Scene It,
DVD trivia titles) randomize question order from it. libdvdnav's analogues:
`srand(time.tv_usec)` at init (`dvdnav.c:200`) seeds `rand()` for the `rnd` set-op, and
counter-mode GPRMs return wall-clock elapsed seconds (`decoder.c:69 get_GPRM`). **Before
this feature both were deterministic in our core** (fixed LFSR seed 0xACE1 reset each mount;
counter never ticked) → Scene It asked *identical questions in identical order every play*.

Verified mechanism (SCENEIT_JR, traced with `tools/dvd_vm_ref.py` + `decode_vmcmd`):
```
PGCN 1: SetMode Counter g[13] = 0x79   ; g13 becomes a wall-clock-seconds counter
PGCN 3: g[13] = 0                       ; re-seed the counter (still counting)
PGCN 8: g[14] += g[13]                  ; HARVEST elapsed seconds (entropy)
        SetMode Register g[13] = 0x400  ; done sampling; g13 back to a register
        g[2] += g[14] ; g[2] %= 0x27    ; time-entropy picks the question index
```

The core now injects real entropy (emu drives a **free-running `clk_sys` counter** —
session-lifetime, not reset by mount/seek — into `dvd_vm`):

1. **`rnd_seed`** — the entropy counter, latched into the LFSR at mount (`start`),
   forced nonzero (an all-zero LFSR locks at 0). Our `srand(usec)` analogue.
2. **`entropy_stir` / `entropy_val`** — any gamepad edge folds the counter into the LFSR
   (`lfsr ^= entropy_val`, idle-gated) so `rnd` varies per play from **user-navigation
   timing** even for discs (e.g. Scene It HP) that seed only from `rnd`.
3. **`sec_tick`** — a 1 Hz pulse; counter-mode GPRMs `+1` per elapsed second, applied
   **only in `V_IDLE`** (never while a command is writing a GPRM, so it can't race). One
   pending flag is enough — commands finish in ≪ 1 s.

Bit-exactness: the golden model and `dvd_vm_tb` PART 1/2 drive the fixed 0xACE1 seed with
no ticks/stir, so all existing vectors are unchanged. `dvd_vm_tb` PART 3 + `dvd_vm_ref.py
Regs.tick()` cover the tick, seed variation, stir, and the zero-seed guard.

Deferred (still): **NVTMR fire (SPRM9)** — libdvdnav doesn't fire it either (stores only;
`decoder.c:527`), and the census found 1/7 discs set it at 999 s (never fires in practice).

## Execution model

Events, serviced one at a time from V_IDLE (all latched):

| event | action |
|---|---|
| `nav_ready` rise | jump FP (boot); FP absent/broken → auto title (`auto_vts`) |
| `pgc_loaded` | run the PRE block (skipped after an RSM resume — `skip_pre`) |
| `vm_pgc_end` | run the POST block (the reader has already **drained** — its stream cache AND, for a title-domain PGC, the decoder VBUF via the tail-drain wait; see `docs/dvd_nav.md` "Natural-transition tail drain") |
| `vm_cell_cmd` | run that one cell command |
| `btn_cmd_valid` | run the button's command (directly from the 64-bit register) |
| `key_menu` | title: synthesized `CallSS VTSM Root` (sets `came_via_menukey`); menu: `LinkRSM` **only if `came_via_menukey`** (the movie menu↔title toggle), else re-invoke `CallSS VTSM Root`. The **first** menu invocation of a mount retargets to `best_menu_vts` — see "Boot-chain menu shortcut" below |
| `key_resume` | `LinkRSM` (Select with no buttons armed) — **only if `came_via_menukey`**, same gate as `key_menu` (see the Cluedo note below) |
| `key_title` | B12 "Title" (the real-remote **Top Menu** key) — **✅ HW-CONFIRMED 2026-07-31 (PR fj#152)**: jump to the **VMGM Title menu** (entry 2) from anywhere. From a playing title also saves RSM + sets `came_via_menukey` (Menu/Select toggle back, like `key_menu`); from a menu it jumps **without touching RSM or the toggle** — a disc-driven menu's RSM is the boot trampoline and must not be re-blessed. `fb=FB_VMGM` (no VMGM Title entry → resume/auto-title). Tests: `dvd_vm_tb` [S17], `iso_reader_cluedo_menu_tb` [B] |
| `key_return` | B13 "Return" (**GoUp**, libdvdnav `dvdnav_go_up`) — **✅ HW-CONFIRMED 2026-07-31 (PR fj#152)**: in-domain jump to the loaded PGC's authored `goup_pgcn` — the menu hierarchy's "one level up" pointer; mirrors the `LinkGoUpPGC` command exec (`fb=FB_NONE`). `goup_pgcn==0` (no authored parent — most discs, 16/22 in the library census) = strict no-op. HW: Atmosfear submenus return properly; Akira's goup targets its Root DISPATCHER whose fall-through is `RSM`, so Return there resumes the title (mid-film) or replays the boot warning (post-boot) — **authored**, identical under libdvdnav. Test: `dvd_vm_tb` [S18] |

### Boot-chain menu shortcut — ⚠ DELIBERATE DEVIATION from libdvdnav (2026-08-25)

**Symptom (user report, Atmosfear).** Press Menu while the copyright/warning screen the
disc's First Play chain puts up is on screen, and instead of the main menu you get a clip
that looks like it came from the end of the game.

**It is the disc, not us — and that is exactly why we had to deviate.** Traced on the real
ISO:

```
FP: g5=0x2000; g5=1; g3=0x44; JumpTT 68        <- VTS_68 = the FBI warning card (5 s)
Menu -> menu_call(Root) on the PLAYING VTS, per spec
VTSM(68) PGC1 pre:  ... g2 = 7 ; JumpSS VMGM 6
VMGM  PGC6  pre:    g2 < 0x2c -> JumpSS VTSM(1, Root)
VTSM(1)  PGC1 pre:  g2 != 0 -> LinkPGCN 5 -> (dispatch on g2==7) -> LinkPGCN 48
VTSM(1)  PGC48 pre: g15 = rnd 6 ; g5 = g15 ; g3 = 1 ; JumpSS VMGM 2  -> JumpTT 1
TT(1) plays program g5 = a random ~35 s Gatekeeper clip in the lava cavern
  ...then its cell command (CallSS VMGM 9) finally reaches the main menu.
```

Every VTS's VTSM Root on this disc sets `g[2] = 7` — that PGC is **not a menu**, it is a
dispatcher that records *"the player pressed Menu inside a VTS"* and routes on it. The
disc's own VMGM Title entry (0x82) does the same thing, so `key_title` lands there too.
**libdvdnav behaves identically** — verified by building its `examples/trace_menuearly.c`
against the real ISO: `[CELL #1] Title=68` → `menu_call(Root)` → `[CELL #2] Title=1` → menu
domain. There are **no UOP bits** to lean on either: the PGC `prohibited_ops` word and every
PCI `vobu_uop_ctl` on this disc are zero, so nothing tells a player to refuse the key. A
faithful VM cannot help the user here; only a deviation can.

**The deviation, and how its blast radius is bounded.** While **no menu-domain PGC has
loaded since the mount** (`menu_seen == 0` — the disc has never yet shown the user a menu),
the Menu key skips the playing title's VTSM Root and jumps straight to the Root menu of
**`best_menu_vts`** (the VTS holding the largest menu VOB — the same heuristic the error
fallback chain has always trusted). Because the current VTS's Root PGC never runs, `g[2]`
stays 0 and Atmosfear's `VTSM(1)` Root takes its `g1==0 && g2==0` path → `LinkPGCN 7` = the
real main menu. Four things keep this safe:

- **Self-limiting.** That very press loads a menu, which latches `menu_seen`, so every
  subsequent Menu press for the rest of the mount is the unmodified spec path.
- **Fallback preserves the spec path.** New `fb = FB_BOOTM`: if the shortcut's target has
  no Root menu, the chain tries **this title's own VTSM Root** *before* widening to VMGM.
  A bad `best_menu_vts` guess cannot cost a menu that used to work.
- **Inert where it cannot help.** `best_menu_vts == 0` (no menu VOB) or
  `best_menu_vts == cur_vts` (the common movie disc, menus in the VTS already playing)
  → unchanged behaviour.
- **`menu_seen` latches on the LOAD EVENT** (`pgc_loaded && vm_dom` in a menu domain), not
  on the bare `menu_active` level — a level still stale from the previous disc for a cycle
  after a mount would otherwise disable the shortcut for a whole session, silently.

**Library sweep (141 discs, `tools/dvd_vm_ref.py`, old vs new landing).** 135 unchanged;
**6 changed, all in the same direction** — the old spec path landed the Menu key in the
**title** domain (the disc bounced it into content), the new one lands in a **menu**:

| disc | old landing | new landing |
|---|---|---|
| `ATMOSFEAR_NTSC` | TT vts=1 pgcn=1 (Gatekeeper clip) | VTSM vts=1 pgcn=7 (main menu) |
| `A_Good_Man` | TT vts=9 pgcn=1 | VTSM vts=1 pgcn=7 |
| `GMEN_FROM_HELL` | TT vts=2 pgcn=1 | VTSM vts=1 pgcn=8 |
| `RETURN_OF_THE_LIVING_DEAD` (both rips) | TT vts=8/9 pgcn=1 | VTSM vts=1 pgcn=7 |
| `STARWARP` | TT vts=3 pgcn=1 | VTSM vts=1 pgcn=9 |

Tests: `dvd_vm_tb` [S2] (first press retargets, `fb == FB_BOOTM`) and **[S21]** (target /
`FB_BOOTM`→own-VTS fallback → VMGM / self-limiting after a menu load). Mirrored in
`tools/dvd_vm_ref.py` (`menu_seen`, `_menu_call_root`) so the golden model stays in
lockstep. ⏳ **HW-confirm pending.**

**Menu key `came_via_menukey` gate (Trivial Pursuit Star Wars).** The Menu key used to
`LinkRSM` unconditionally from any menu. On a **single-VTS game disc whose VTS1/title1 IS the
First-Play copyright+intro** (TP Star Wars: FP `JumpTT 1` → intro → menu, and boot's
`CallSS_VMGM_PGC` leaves RSM = that intro), pressing Menu inside one of the game's *authored*
menus (which you did **not** reach via the Menu key) resumed RSM = the intro → "hitting Menu in
a question replays the copyright." Fix: `came_via_menukey` is set only when the Menu key is
pressed **from a playing title** (title → `CallSS VTSM Root`) and cleared whenever a title
plays again (the `ev_loaded` handlers in both `V_IDLE` and `V_WAIT`, gated on `vm_dom==DOM_TT`).
A Menu press in a menu resumes (toggles back to the title) only while `came_via_menukey` holds;
otherwise it re-invokes the Root menu. Movies keep the menu↔title toggle; the game menus go to
a real menu instead of the copyright. Test: `dvd_vm_tb` [S13]; mirrored in
`tools/dvd_vm_ref.py` `menu_key`/`_menu_call_root`.

**Select-resume `came_via_menukey` gate (Cluedo "Please Wait, Processing" park, 2026-07-31)
— ✅ HW-CONFIRMED same day (Select during the intro is a no-op; plays through to the menu).**
The same class of bug through the *other* resume entry point: `key_resume` (emu's "Select with
no buttons armed" convenience) used to `LinkRSM` whenever `rsm_vts != 0`. Cluedo (AUS PAL)
boots FP → `JumpTT 1` → VTS1 PGC1, whose PRE is a GPRM5 game-state dispatch ending in
`CallSS VMGM pgc2` — that disc-driven CallSS **saves RSM = VTS1 PGC1 cell 1** and starts the
copyright → logos → intro chain (VMGM PGC2–5, which arm **zero** HLI buttons). Pressing Select
during the intro therefore fired `key_resume` and RSM'd into VTS1 PGC1: `skip_pre` (correct
RSM semantics) skips the dispatch PRE, so its lone 3 s cell plays — literally the disc's
"Please Wait, Processing" card — and the PGC has **no POST commands and no next_pgcn**, so the
VM parked forever (only the Menu key escaped, restarting the disc). A real player treats Enter
with no armed buttons as a **no-op**; RSM is only a valid *user* destination when the *user*
created it (Menu from a playing title). Fix: `ev_resume` takes the same `came_via_menukey`
gate as `ev_menu` — Select in a disc-driven menu chain now does nothing, while the
Menu-then-Select resume toggle for user-entered menus is unchanged. (Side effect: the
*accidental* "Select skips the intro" behaviour on some movie discs — really an RSM into the
boot trampoline's saved position — is gone; that skip was never authored and parked any disc
whose trampoline title is a non-resumable stub, e.g. TP Star Wars class discs too.)
Test: `dvd_vm_tb` [S16] (gated no-op + user-toggle-still-resumes).

**Cluedo Menu-key follow-up (2026-07-31): the copyright replay on Menu is AUTHORED — do not
"fix" it.** After the S16 fix, HW showed Menu during the intro (or at the game menu)
restarting from the copyright. Real-data sim (`bench/dvd/iso_reader_cluedo_menu_tb.sv`,
fixture `tools/cluedo_fixture.py`) proved this **matches the disc's own commands**: Cluedo's
VTSM **Root entry (0x83) exists** and its PRE is `{g5 = 0; JumpVTS_TT 1}` — the authored root
menu *clears the game state and restarts the presentation* (title 1 PRE → `CallSS VMGM pgc2`
→ copyright → logos → intro → menu). libdvdnav's `menu_call(Root)` runs the identical chain.
(⚠️ An earlier analysis claimed the VTSM had no Root entry and blamed our SRP[0] scan
fallback — WRONG, the 0x82 entry it cited is the **VMGM's** Title entry; a reader
scan-exhaust→`pgc_error` change was written and then REVERTED, no motivating case.) The
user-facing remedy is the **Title key** (above): VMGM Title (PGC1) → `LinkPGCN 12` → the
PGC12 GPRM dispatcher → `LinkPGCN 6` = the game menu **directly**, no copyright.

> **Symptom 1 (question completes → copyright, then menu) is NOT fixed here** — it is a
> reader-side (`dvd_iso_reader.sv` FSM / sector-load) failure at one of the return-chain links
> (reveal `CallSS_VTSM` → VTSM Root → result menu → `LinkPGCN` → 0-cell VTSM stub → `JumpSS_VMGM`
> → wheel). The **VM logic is correct** — `tools/dvd_vm_ref.py` walks that whole chain to the
> wheel with no error — so when a link fails the VM's `ev_error` fallback lands on
> `auto_vts`/title-1 = the intro (single-VTS ⇒ copyright→menu). A blind `ev_error` "menu-domain
> error → menu chain" promotion was tried and **reverted**: it hijacked the reader's normal,
> relied-upon auto-title recovery (regressed `iso_reader_vm_tb` T2/T4). Pinning the exact failing
> link needs the on-HW reader diagnostic (freeze-diagnostic overlay: `rd_state` + `{cur_vts,cur_pgcn}`).
| `pgc_error` | fallback chain (below) |

Fetch = 8 sync-BRAM reads (cmd BRAM 2048×8, reader-written; button slot bypasses the
BRAM). ALU: 1-cycle simple ops; serial 16-cycle mul (MSB-first shift-add) and
restoring div/mod/rnd. Program-map links scan/read the pm BRAM (2 cycles/entry).

**Reader-wait contract**: every `vm_cell_cmd` / `vm_pgc_end` is answered with exactly
one of `vm_adv` (continue authored behaviour), `vm_replay` (replay the current cell,
**no flush** — the menu loop), `seek_pulse`, or `jump_pulse`. The reader also has a
~0.62 s watchdog that treats a missing verdict as `vm_adv`.

> **`V_PGSCAN` timing (2026-07-14 fix):** the program-map scan resolves `cur_pg` by reading
> `pmem_q`, a **registered** BRAM read, so `pg_hit` needs a settle cycle — three phases per
> entry (`pg_ph`: set-addr / settle / evaluate). An earlier two-phase loop compared the
> PREVIOUS entry (`pm[pg_i-1]`) and over-counted `pg_final` by 1 whenever a program follows
> the current cell's program, so `LinkTopPG` on the last cell of a program SEEKED to the next
> cell instead of replaying — the MiB root-menu montage (`cell 2 LinkTopPG`) advanced to the
> cell-3 still and went black. `LinkCN`-based loops (Matrix/T2) never hit the scan and were
> unaffected. See `docs/dvd_menu_refinements.md` §5e; regression tests
> `bench/dvd/iso_reader_montage_tb.sv` + `dvd_vm_tb` S4b.

**Link dispatch** (vm.c `process_command` parity):

- LinkTopC → `vm_replay`; LinkNextC/PrevC → cell seek (past the last cell → POST);
  LinkCN n → replay if n-1 == cur_cell else seek.
- LinkTopPG/NextPG/PrevPG → program-map scan for cur_pg, then pm[pg−1]−1 seek
  (NextPG past the last program → POST); no program map → cell approximations.
- LinkPGN/LinkPTTN → pm lookup (PTT ≈ program until Phase 6).
- LinkTopPGC → re-enter the current PGC (pre re-runs); LinkNext/Prev/GoUpPGC → jump
  to the authored next/prev/goup PGCN (0 → hold).
- LinkTailPGC → chain into the POST block **now** (MiB Play buttons).
- LinkRSM → restore SPRM4-8 + jump {TT, rsm} with `skip_pre`.
- JumpTT n → reader resolves via TT_SRPT (`jump_ttn`, `jump_vts=0`); SPRM4=n,
  SPRM5=resolved vts_ttn (`res_ttn` latched at load), SPRM7=1.
- JumpVTS_TT / JumpVTS_PTT → title-entry scan in the current VTS (+ start program).
- JumpSS FP / VMGM menu / VTSM (vts,title,menu) / VMGM pgc → the four reader domains.
- CallSS_* → save RSM {cur_vts, cur_pgcn, cell (command's rsm_cell field − 1, else
  cur_cell), SPRM4-8} first, then like JumpSS.
- Exit / LinkNoLink → `vm_adv` (the reader parks: menu → still hold, title → done).
- Any link's button field ≠ 0 → SPRM8 = btn<<10 + nav_pci `sel_force`.

**Guards**: 4096-instruction fuse per activation; 63-jump chain guard (authored
jump loops stop chaining, playback continues); V_WAIT timeout ~0.62 s (a jump the
reader never latched).

**Fallback chain** (ported from the Phase-2/3 emu glue): a failed menu jump walks
own VTSM → `best_menu_vts` VTSM Root → VMGM Title → RSM resume / auto title; a
failed FP or title jump goes to the auto title once (`FB_GAVEUP` stops error loops).

## Reader coupling (`dvd_iso_reader.sv`, `vm_mode` input = O[1])

- **Mount**: after the VIDEO_TS walk the reader **idles in S_DONE** (no auto-play);
  the VM boots FP. With menus Off everything behaves exactly as Phase 3.
- **S_VM_WAIT**: cell end with `cell_cmd_nr != 0` → pulse + wait (the Phase-3
  armed-button cell-loop heuristic is bypassed — the VM executes the real command);
  PGC end → **drain the cache first, and (title domain) wait for the decoder VBUF
  to empty** (`vbuf_empty`, ~5 s `DRAIN_WD` watchdog — the natural-transition tail
  drain, `docs/dvd_nav.md`), then pulse + wait (POST runs against the genuinely
  played-out picture — the menu-still lesson in the other direction). `vm_replay`
  re-enters S_CELL_LOAD with no flush (gapless, the HW-proven Phase-3 loop path).
- **0-cell PGCs with commands** report `pgc_loaded` as command stubs (the VM runs
  the pre); the Phase-2 LinkPGCN-follow heuristic remains for vm_mode-off only.
- **JumpTT service** (`jump_ttn` + `jump_vts==0`): re-reads VMGI@196 → TT_SRPT entry
  (12 B each from @8; `title_set_nr`@+6, `vts_ttn`@+7) → group scan → **title-entry
  scan** (PGCIT SRP `entry_id` bit7 + low7 == ttn; miss → SRP[0]).
- **P_PMAP walk phase**: the PGC walker also streams the program map (@230,
  `nr_of_programs`@2 clamped to 99) to the VM's pm BRAM, latching `jump_pgn`'s
  start cell in passing (JumpVTS_PTT). `wphase` widened 2→3 bits.
- New read-backs: `nav_ready_o`, `auto_vts`, `cell_count_o`, `res_ttn`, `cmd_nr_pgm`.

## emu.sv

The ~220-line proto-nav/micro-bridge always block is deleted. emu keeps gamepad
decode only: pause + title cell seeks (D-pad, unchanged), Phase-3 button-nav pulses,
and Menu/Select key pulses into the VM. The VM owns the reader's jump port; its cell
seeks mux onto the seek port. `jump_ack` clears pause. Stream mux:
`aud_track = (menus_on && SPRM1 < 8) ? SPRM1 : O[8:6]` (SPRM1 = 15 "none" keeps the
OSD in control until the disc selects); `sp_track/sp display` from SPRM2 (bit6),
with `O[15]` still forcing subtitles on.

## Punted (documented, not planned soon)

Angle blocks (AGL fixed 1), karaoke/audio-mix modes, parental enforcement (SetTmpPML
stores the level), NVTMR expiry (un-referenced — see "DVD-game entropy"), UOP enforcement,
PTT exactness (`VTS_PTT_SRPT` = Phase 6 — PTT ≈ program until then), language-unit selection
(LU[0] always; SPRM0 is a constant), TTN reverse-lookup on JumpSS_VTSM (SPRM4 kept).

## Verification

```
python3 tools/dvd_vm_ref.py selftest            # 27/27 golden eval vectors
python3 tools/dvd_vm_ref.py boot  <disc.iso>    # trace the FP boot chain
python3 tools/dvd_vm_ref.py menu  <disc.iso> N  # trace a Menu-key press
# library sweep (old vs new Menu-key landing): force vm.menu_seen = True for the
# pre-shortcut path and compare -- how the 141-disc table above was produced.
iverilog -g2012 -o /tmp/v dvd/dvd_vm.sv bench/dvd/dvd_vm_tb.sv && vvp /tmp/v
iverilog -g2012 -o /tmp/r dvd/dvd_iso_reader.sv dvd/dvd_vm.sv \
    bench/dvd/iso_reader_vm_tb.sv && vvp /tmp/r
```

Real-disc golden traces (2026-07-07): **BBB** FP = `JumpTT 4` (5 s clip; post
`CallSS_VMGM_PGC 2` dispatcher chains onward — the old memory "FP=JumpVTS_TT 4" was
the pre-rewrite decoder's op-code bug). **MiB** Menu key executes the full trampoline
to VTS_02 PGCN 5 (the real 6-cell menu), with the VMGM dispatcher PGC branching
differently on the two visits because g14 changes — GPRM state observably working.
**Matrix** root menu pre ends `LinkCN 1`.

## HW gate (Phase-4 acceptance)

- BBB: boot plays the authored FP chain (warning clip(s) → menu); picking the
  feature from the disc's menu plays the CORRECT title (the documented largest-VTS
  failure case).
- MiB: boot → logo chain; Menu mid-title → root menu (via the real trampoline, watch
  for `best_menu_vts` fallback NOT firing); Play button launches the feature through
  SetGPRM+LinkTailPGC+post dispatch; Menu again resumes at the saved cell.
- Matrix: menus/pagination/chapter buttons as in Phase 3, now via real execution.
- Titles: POST commands at feature end return to a menu instead of parking.
- Audio/subtitle menus switch streams (SetSTN → track mux).
- Menus Off (O[1] default): behaviour identical to Phase 3 (regression).
