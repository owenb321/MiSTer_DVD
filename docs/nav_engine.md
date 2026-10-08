# The DVD VM as microcode (`dvd/dvd_vm.sv` + `dvd/nav/vm.uasm`)

**Status (2026-10-07): ✅ HW-CONFIRMED, ✅ MERGED (PR #168).**
- Built, sim-proven and fitted in the core; timing passes.
- HIL round 1 reproduces the control's `nav_diff` table exactly (§3a).
- The maintainer's hand check passed on build `DVD_navucode_20261007_0640.rbf`
  (2026-10-08).
This is the pilot `docs/logic_reclaim.md` §10b proposed: the VM alone, so the
measurement and the workflow question are answered before the reader is touched.

| Question §10b asked | Answer |
|---|---|
| Does a sequencer + ROM beat the hardwired VM? | **Yes.** **In the core** (full fit, SEED 5, `DVD_navucode_20261007_0640.rbf` vs `main`'s v0.9.0 fit): `dvd_vm` 1,350 → **853 ALM (−498)**, 2,351 → 1,187 ALUTs, 1,040 → 692 registers, 6 → 10 M10K (+4 for the ROM; the design 521 → 525). Timing passes: `clk_dec` 90.63 / 87.87 MHz at the two slow corners against the 86 gate; `clock_check` PASS; `clk_sys` +6.9 ns. The design total, 40,642 → 38,464 ALM, mostly reflects packing, which moves ±1,500 between seeds. **Standalone** (SEED 1, `bench/dvd/vm_fit_top.sv`): 1,635 → 919 ALM, Fmax ≈ 50 MHz both. |
| Is it still the same VM? | **Yes, transaction for transaction.** The old FSM is kept as an oracle and a three-way A/B (old FSM, Python VM, new RTL) agrees on 1,000 generated scripts × 120 steps (217k pulses with the final generator, 271k with the first, and the full VM state at every rest). All 14 VM benches and every runner that touches the VM pass, `--red` included, each mutation still caught by the same named arm. |
| Do navigation changes get easier? | A change is now an edit of `vm.uasm`, scored by the A/B and the benches in minutes, and the same microcode runs offline against libdvdnav over the ISO library (`tools/nav_offline.py`) without the rig. Whether that pays off is the next feature's to say (see "Next"). |

## 1. Architecture

`dvd/dvd_vm.sv` keeps its module name and **every port**, so `emu.sv`, the wiring
checkers and the runners did not change. Inside it are two modules:

- **`dvd_vm`, the wrapper:** everything real-time, and everything a port shows.
- **`nav_seq`, the sequencer:** in the same file, so every runner that compiles
  `dvd/dvd_vm.sv` (by path or by `-y dvd`) picks it up unchanged. It runs
  `dvd/nav/vm.uasm` from a ROM.

| Hardwired in the wrapper | Microcode (`vm.uasm`) |
|---|---|
| event latches (gated by Disc Menus) and their priority, auto-cleared on dispatch | every event handler (the old FSM's V_IDLE arms) |
| the wait timer (~0.62 s, frozen by `wait_hold`) | command fetch and decode: types 0–7, compare, set, link and jump |
| output fields and pulses; the `usr_edge` mask on `vm_adv` | serial mul, div, mod, rnd, as loops; the swap |
| SPRM1/2/3/8 (they are ports), the SPRM8 shadow / activation latch / freeze, the SPRM3 write-back | the RAM-resident SPRMs 4–7, 9, 10, 13 |
| `vm_dom` / `vm_vts`, and on the load event `last_menu_*` and `menu_seen` | the fallback chain, RSM, the boot-chain shortcut, `came_via_menukey` |
| `pre_done` (with its load-bearing `!ev[LOADED]` term) | the POST-only 0-cell dispatch, the title-edge Next/Prev, the dead-end latch |
| the LFSR (step on request, stir while idle) | the counter-mode tick walk, the fuse (4096), the chain guard (63) |
| the command table (2 × 2048 × 8 byte banks) and the program map | |

The rule for the split: anything that must act **in a given cycle** or that a port
shows stays hardware, including every one-cycle pulse that has to latch (the
cross-cutting lesson). Everything that is a *decision* is microcode.

### The sequencer (`tools/nav_isa.py` is its definition)

- **Instruction word:** 40 bits, `op[39:34] rd rs rt imm[21:6] aux[5:0]`, the DTS
  engine's layout.
- **Registers:** 16 × 16 bits; r0 = 0.
- **Memories:**
  - 1K-word program ROM (4 M10K);
  - 256 × 16 single-port data RAM (1 M10K);
  - 4-deep call stack.
- **Timing:** `ld` / `ldc` / `ldp` take 2 cycles, everything else 1.

| Instruction | |
|---|---|
| `alu` / `alui` | add sub and or xor shl shr, `sadd` (clamp 0xFFFF), `ssub` (clamp 0), seq sne sltu sgeu |
| `dcmp rd, rs, rt, rk` | the DVD compare, op = `rk & 7` (libdvdnav `eval_compare`), so a command's compare is one instruction, not a jump table |
| `ld` / `st` | the data RAM |
| `ldc` | a 16-bit word of the command table (a command is 4 words; every DVD command field sits inside one word, so no 64-bit barrel shifter) |
| `ldp` | the program map |
| `in rd, PORT[rs]` | the wrapper's inputs; 32..63 is the live-SPRM window |
| `out` / `outi` | the wrapper's outputs |
| `b<c>` / `b<c>i` / `bbs` / `bbc` | branches (unsigned; `bbs` / `bbc` on one bit) |
| `jmp` / `call` / `ret`, `jr` | jumps, and a jump table |
| `wev LABEL, mode` | park until the wrapper offers an event, then `pc = LABEL + index` |

**`wev` priority.** In idle mode: the tick; then Disc Menus off with anything
pending; then boot, error, loaded, btn, cellcmd, pgcend, chedge, menu, title, cmenu,
return. That is the old V_IDLE order. In wait mode: loaded, error, timeout.

**Reading a SPRM.** A read takes the data RAM's image OR the wrapper's live window.
Each side holds 0 where the other holds the register, so an SPRM read is three
instructions with no table.

**Data RAM map:** generated into `dvd/nav/nav_ucode.svh` and
`bench/dvd/dvd_vm_peek.svh`.

| Address | Contents |
|---|---|
| 0x00–0x0F | GPRMs |
| 0x10 | counter-mode bits |
| 0x11–0x15 | fb, came_via_menukey, skip_pre, tt_resolve, chain |
| 0x18–0x1F | RSM |
| 0x20–0x22 | the dead-end latch |
| 0x40 + n | SPRM n |

### The program

- **Size:** 972 of 1,024 words (1,014 at the merge; compacted 2026-10-08, §7).
- **Layout:** the labels name the old FSM's states (`IDLE`, `WAIT`, `FETCH`, `EXEC`,
  `NEXT`, `PMRD`, ...), so the two read side by side.
- **Wraparound:** every 8- and 9-bit wrap of the old FSM is reproduced with an
  explicit mask. They are visible in the A/B, which is how the one place I missed
  was found.
- **Registers:**

| Register | Use |
|---|---|
| r7 / r8 / r9 | the command index and the block bounds |
| r10 | `{walk, usr_edge, nat_src, blk}`, mirrored to the wrapper's FLAGS |
| r11 | the fuse |
| r12–r15 | the 8-byte command |

## 2. Workflow: changing navigation

1. Edit `dvd/nav/vm.uasm`.
2. Run `tools/nav_isa.py --asm`. It assembles the program and rewrites:
   - `dvd/nav/nav_ucode.mem`, the ROM;
   - `dvd/nav/nav_ucode.svh`;
   - the two `GENERATED` blocks in `dvd/dvd_vm.sv`, the constants the RTL uses
     (an `` `include `` would need `-I` in every runner: Icarus does not search the
     including file's directory);
   - `bench/dvd/dvd_vm_peek.svh`.

   `--asm --check` fails on anything stale. `bench/dvd/run_vm_ab.sh` and
   `run_gprm_ram.sh` run it first.
3. Run `bench/dvd/run_vm_ab.sh`. The three-way A/B says whether behaviour moved.
   For a deliberate change, the old FSM is no longer the reference, so this step
   becomes the change's own bench plus `tools/nav_offline.py`.
4. Run `tools/nav_offline.py` on the affected discs, or `--library`, against
   libdvdnav.
5. Run the VM's benches and runners as before.

**RED arms** live beside the code they break: a `;MUT name: <instruction>` comment
in `vm.uasm`. `tools/nav_isa.py --mutant NAME DIR` writes a runnable `dvd_vm.sv`
whose ROM is that arm, which is how the runners' VM arms work now.

## 3. Gates

| Gate | What it proves |
|---|---|
| `bench/dvd/run_vm_ab.sh` | **GREEN:** the generated files are current; old FSM = Python VM = new RTL over `$VM_AB_SEEDS` (default 300) scripts; the RTL matches the emulator's instruction trace and its cycle count step for step. **RED:** all 16 `;MUT` arms diverge from the old FSM; four wrapper mutations are caught (event priority, the SPRM8 freeze, `pre_done`'s `!ev[LOADED]`, the menu-load latch). |
| `bench/dvd/run_gprm_ram.sh --red` | The GPRM mechanisms as microcode arms: type 4 compares after its set (`t4_inc_hits`), the swap's second write (`T6s`), the tick's write (`T1`), the mount clear (`T7c`), a 4-bit GPRM index (`T1` harvest). `tools/check_gprm_ram.py` now gates all five of the VM's memories. |
| `run_select_noop --red` R5/R6 | microcode arms `werrbtn` / `wtobtn` (S25b / S25a) |
| `run_chap_edge --red` N1–N6 | microcode arms `chnat`, `chnext`, `chfirst`, `chmenu`, `usrstuck`; N2 (the `vm_adv` mask) is a wrapper edit; the same V-arms as before |
| `run_player_regs --red` R4 | the wrapper's SPRM20 window |
| `dvd_vm_tb`, `dvd_vm_atmos_tb`, the 12 reader+VM benches | unchanged in substance; the state that moved into the RAM is reached through `` `VM_GPRM(dut, i) `` etc. `dvd_vm_tb` prints the same 49 lines on both VMs. |
| `run_reader_regress.sh --baseline <main>` | The PR #135 acceptance, met (2026-10-07). Verdicts are identical on all 51 arms. The 38 arms without the VM are bit-identical (log and trace). The 13 with it differ in their traces (a sequencer takes more cycles), and their logs differ only in numbers: `$finish` times, `cap=` cycle counts, printed `vm.state`. |

**How the A/B works** (`tools/vm_ab.py`, `bench/dvd/vm_ab_tb.sv`, `tools/nav_shell.py`):
- A generated script of inputs, command tables, program maps and pulses is applied
  one line at a time, **each at rest**.
- After every line, each VM logs:
  - its pulses with their fields (JUMP's nine, SEEK's cell and `vm_from_wait`, ...)
    in order;
  - the changes of each SPRM output;
  - a dump of the whole VM state: GPRMs, SPRMs, RSM, fb, the event latches, the
    LFSR, the menu latch, chain, fuse, blk/nat/usr.

The old FSM is `bench/dvd/ref/dvd_vm_hw.sv`: `dvd_vm.sv` as it was, unchanged but for
its module name. Two normalisations, each forced by a real difference:
- **SPRM8:** it alone has a hardware shadow that rewrites it every cycle while a menu
  is armed. The old FSM's writes were often back to back and hid the shadow value
  between them; the sequencer's never are. The values the VM *wrote* are compared;
  the settled value is in the state dump.
- **`PREDONE`:** it is logged first in its cycle. The old FSM raises it in the same
  cycle as a dispatch's first pulse, and the PRE it reports resolved before that
  dispatch.

Two artefacts of the old RTL in simulation (never on silicon) are deposited by the
bench:
- `ev_title` / `ev_return` / `ev_cmenu` are missing from its reset block;
- its command and program-map RAMs are never initialised.

**What the A/B cannot see.**
- **Events while the VM runs.** Stimulus arrives only at rest, so no event shares a
  cycle with a microcode clear. "A clear wins over a same-cycle latch" (the old rule)
  is kept by construction (`ev <= ((ev | ev_set) & ~ev_clr) | ev_force`), not by a
  gate.
- **Anything timing-dependent:** how long a chain takes. See §4.

### 3a. HW round 1 (2026-10-07, rig)

**Setup:**
- **Builds:** control `releases/DVD_20261007.rbf` (v0.9.0; RTL identical to this branch's
  base); test `DVD_navucode_20261007_0640.rbf`.
- **Disc set:** the PR #135 set (MiB, Matrix, T2, Scooby-Doo 2, Harry Potter
  Interactive, Scene It HP).
- **Scripts:** one fixed 4-button script per disc, derived from the oracle
  (`nav_offline.auto_script`, seed 7, `.sim`-local), the same on both arms.

**Result: identical tables on every compared step.**

| Disc | Result, both arms |
|---|---|
| MiB | 3 of 3 equal to libdvdnav |
| Matrix | 2 of 2 equal to libdvdnav |
| Scooby-Doo 2 | 1 of 1 equal to libdvdnav |
| T2 | the first button lands on PGCN 6 where libdvdnav says 1. The pre-existing `main` difference PR #135 recorded (it saw 5 with a different button). |

The same steps never reached an armed park on both arms (HP Interactive and Scene It
throughout, the Scooby maze, MiB's and Matrix's last step), so those are not measured.

**The offline diff predicted all of it beforehand:**
- every landing the board compared;
- T2's divergence, to the PGCN: the microcode lands on PGC 6 offline too.

**T2's divergence is press timing, not navigation (diagnosed offline, 2026-10-08,
`feature/nav-sweep`).**
- VTSM 1 PGC 1's cell 2 is one VOBU, 58 sectors, with a 5 s playback time and no still
  time.
- **libdvdnav** holds it as a 5 s still with buttons up: `vm_position_get`'s "rough fix"
  for short single-VOBU cells. `trace_nav` parks there and presses button 2, which is
  LinkPGN 4.
- **The core** holds it too, by serving the cell's authored playback time
  (`docs/dvd_nav.md` "Authored cell duration").
- **The board harness** needs settled, armed screenshots about 1 s apart, so it pressed
  after the 5 s were up. That landed on cell 4, an indefinite still whose button 2 is
  `g3 = 2; LinkPGCN 6`.

Once `tools/nav_offline.py` parks by libdvdnav's rule (`still_of`), T2 agrees on all four
steps. The VM executes the same command libdvdnav does; the two sides pressed at
different screens.

So the model reproduces the board where the board can be read, and it can read the steps
the board cannot (HP Interactive and Scene It agree offline on all four of their steps).

✅ **The maintainer's hand check passed (2026-10-08, the same build, on the rig).** It covered
the paths `nav_diff` cannot reach, as for PR #135:
- Scooby-Doo 2's minigame and maze;
- T2 (Mission Profiles, a slideshow);
- HP Interactive (Player Mode);
- Scene It HP (a game and a question);
- a counter-mode GPRM disc.

Verdict: "all looks good on hardware".

## 4. Timing

| Measure | Value |
|---|---|
| A typical event chain (p99 over the corpus) | ~350 cycles, 13 µs |
| The worst case: a 4,096-command runaway | 1.11 M cycles, 41 ms at 27 MHz (~271 cycles per command; heavy divides) |
| The bounds it must meet | the reader's angle `ANG_PRE_WD` 6.75 M cycles (0.25 s), its VM-wait watchdog 16.7 M (0.62 s) |
| Margin | ≥ 6× |

The fuse bounds the commands per activation, so the worst case is about 4,096 × the
slowest command. The old FSM took ~20–37 cycles per command; the sequencer is ~7×
slower, and that is affordable.

**Behaviour differences, all accepted:**
- A chain takes longer, so a user event arriving mid-chain waits longer before it is
  dispatched (it is latched either way).
- `pre_done` fires a few cycles later.
- `hl_btnn` can show the shadow value for a cycle between two VM writes.
- An entropy stir during the 16-step tick walk is applied, not dropped.
- `state` / `dbg_state[3:0]` reads 0 (idle), 10 (waiting) or 2 (running).
- The LFSR now seeds synchronously. This removes the `emu|dvd_vm|lfsr[8]~15` latch
  every STA run logged.

## 5. The offline libdvdnav diff (`tools/nav_offline.py`)

The same microcode runs under a Python model of the reader's playback (`Player`):
- loads resolve as the reader's jump service does: PTT_SRPT for a title, the entry
  id for a menu, `pgn` 0xFF = the last program;
- cells play, with their still, then their cell command (the VM's verdict), then
  PGCEND and POST, and authored `next_pgcn` on an advance (a command-only PGC too);
- buttons come from the cell's first NV_PCK carrying an HLI;
- playback is charged in sectors against `trace_nav`'s block cap, shared through
  `TRACE_BLOCK_CAP` (`--block-cap`; `trace_nav` defaults to 400,000).

It parks by `trace_nav`'s rule (`tools/dvd_trace/trace_nav.c`): an indefinite still,
or a button cell confirmed by a still or by a loop. **The still is libdvdnav's, not
the IFO's:** `still_of()` mirrors `vm_position_get`'s "rough fix", which holds a
short single-VOBU cell as a still for its playback time. Without it, T2 read as a
navigation difference (§3a).

It compares each action's landing with libdvdnav's: domain, PGCN, VTS in a VTS
domain (libdvdnav keeps the last VTS in VMGM; the core says 0), and the 16 GPRMs,
except those in counter mode (the model has no clock). Program and cell are shown
but not compared, because they are timing-dependent at the block cap. The first
menu call is expected to differ (the boot-chain shortcut), as in `nav_diff.py`.

**A disc's status:**

| Status | Meaning | Lead? |
|---|---|---|
| `ok` | every compared landing agrees | — |
| `ok-gprm` | the same screens, different GPRMs, and libdvdnav ran no `rnd` | **yes** |
| `DIFF` | a different screen | **yes** |
| `nolanding` | the model never reached a landing libdvdnav did | **yes** |
| `rnd` | libdvdnav **executed** a `rnd` set, and a difference (or a second seed) followed it | no: the core's LFSR and libdvdnav's `rand()` differ by design |
| `oracle-err` | libdvdnav could not use the disc after the action: a read error (`Expected NAV packet`), an IFO libdvdread rejects (`ifoRead_PGCIT failed`), a PTT naming PGC 0 (`No such pgcN`) | no |
| `cap-edge` | both stopped at the block cap on the same screen, one park apart (they count blocks differently near it) | no |
| `udf-only` | no `VIDEO_TS` in the ISO9660 tree; the reader cannot open it (a known gap) | no |

`rnd` is decided from libdvdnav's own command trace on stderr (the commands it runs,
not the block listings it prints first). A conditional `rnd` whose condition was
false still counts, which is conservative. An `ok` on a disc that ran `rnd` is re-run
under seed 99, and becomes `rnd` if that moves libdvdnav, since its agreement may have
been luck.

⚠ **`trace_nav`'s seed did not hold before 2026-10-08.** `dvdnav_open()` calls
`srand(time.tv_usec)`, which replaced the seed `trace_nav` had set before opening.
Every run's `rnd` differed, so the two-seed `rnd` test (here and in `nav_diff.py`)
compared two random runs. The seed is now set after the open (`trace_nav.c`,
`trace_wait.c`).

**Limits:**
- There is no clock, no angle blocks, and a model of the reader rather than the reader.
  **A lead is something to reproduce on the rig with `nav_diff.py`, not a verdict.**
- `auto_script` presses buttons only. The Menu and Title keys (`mR`, `mT`) and
  chapter skips are never generated, so the scene-selection-from-a-title path that
  exposes SPRM7 (§5a) is reached only when a disc's own buttons go there.
- `rnd` is decided per disc, so a difference BEFORE the first `rnd` on a game disc is
  hidden too (26 discs in pass 2).
- SPRM8 (the highlighted button) is not compared. A menu that pre-selects a button
  from SPRM7 would read `ok` while highlighting the wrong one.

Usage:
```
tools/nav_offline.py <disc.iso> --script "1 2 mR 1"
tools/nav_offline.py --library --auto 3 --block-cap 100000 --jobs 4 --out r.jsonl
tools/nav_offline.py --library --only leads.txt --out r2.jsonl     # a second pass
tools/nav_offline.py --library --red callss                    # a ;MUT arm must differ
```
It needs `tools/bin/trace_nav` (`tools/build_dvd_trace.sh`; untracked). Use
`--jobs 4` on a network library; each worker is light now. A model log once took a
worker to 11 GB, and the logs are now dropped after each stimulus.

### 5a. The library sweep (2026-10-08, `feature/nav-sweep`)

The whole ISO library, `--auto 3` (three random buttons from libdvdnav's parks), block
cap 100,000.

**Pass 1 (1,530 discs)** ran with the model as it was at the merge:
- 1,503 `ok`, 10 `DIFF`, 11 `nolanding`, 5 `rnd`, 1 error (`_hwtest/BADIMAGE`, not
  ISO9660); one disc never finished (`dvdi/MILLIONAIRERUS`, below).
- **Not what it looked like.** 516 of the `ok` discs compared nothing: libdvdnav never
  parked within the cap, so their script was `w1`, and the model dropped `w` actions.
  The register comparison was folded into `ok`, so 31 `ok-gprm` rows went unread.

**Triage** turned every lead into a model fix or a class:

| Disc | Pass 1 | Cause | Now |
|---|---|---|---|
| T2, Mad Dog, JSPAWN, RSD100, … | DIFF / nolanding | libdvdnav's short-cell still (`still_of`) | `ok` |
| Just One of the Guys, `DVD_VIDEO` | nolanding | the dropped `w` action | `ok` |
| Harvard Man, Tangled | DIFF | libdvdnav read error after the action | `oracle-err` |
| DragBal2 | DIFF | libdvdread rejects a PGCIT; libdvdnav substitutes Exit | `oracle-err` |
| DragBal1 | DIFF | a PTT entry names PGC 0; libdvdnav Exits | `oracle-err` |
| FAIRYTOPIA, Dragon's Lair II, Die Another Day 2, 11 game discs | rnd / DIFF / ok-gprm | `rnd` on the path | `rnd` |
| MANONFIRE, Scene It | nolanding | both at the cap, one park apart | `cap-edge` |
| MILLIONAIRERUS | never finished | no `VIDEO_TS` in ISO9660; the model spun | `udf-only` |
| **D050818_01, ISLAM_TRAILER** | nolanding | **the core: no First Play PGC** (below) | lead |
| **TERMINATOR_3** | ok-gprm | **the core: SPRM7 does not follow playback** (below) | lead |

**Two real differences, both in the core, and the old FSM had both** (the A/B
oracle `bench/dvd/ref/dvd_vm_hw.sv` behaves the same, so neither is the microcode's):

1. **SPRM7 (PTTN) and SPRM6 (TT_PGCN) do not follow playback.**
   - libdvdnav sets `PTTN_REG` whenever a program starts a new part ("this chapter
     FOUND"), and sets `TT_PGCN_REG` to the title PGCN on every title PGC.
   - The core writes SPRM7 only at a jump (1, or the part a `JumpVTS_PTT` names), and
     SPRM6 only to 0 (both at mount, and restored by RSM).
   - T3's VTSM PRE copies SPRM7 into g6 after the feature's last chapter: libdvdnav
     2, the core 1.
   - **Library census** (a scan of every PGC's PRE/POST/cell commands; button
     commands not scanned), 1,531 discs:
     - **SPRM7 is read by 528 discs.** 475 copy it into a GPRM, mostly a VTSM menu
       preamble that saves the SPRMs, as T3's does. 58 branch on it directly, 53 of
       those in VMGM.
     - **SPRM6 is compared by 74 discs,** 66 in VMGM. That is title-menu logic, which
       picks by the title PGC that was playing.
     - A copy matters only if a later command branches on the GPRM. So 528 is the
       ceiling, and 58 + 74 is the floor of discs whose navigation can differ.
   - The reader already resolves the global PTT index for the HUD (`cur_pgm`,
     `dvd_iso_reader.sv`, 8 bits, clamped at 255 for the display), and `dvd_vm` has
     `cur_pgcn`.
   - **Proposed fix (not built):**
     - a title-domain SPRM7 latch fed from a 10-bit `cur_pgm` (the spec allows 999
       parts);
     - SPRM6 = `cur_pgcn` in the title domain;
     - both kept across a menu call, as libdvdnav keeps them;
     - RSM save/restore reconciled.
   - **What a user would see:** a scene-selection menu opened mid-film that pages
     or highlights from SPRM7 opens at chapter 1.
   - **Rig check:** play into chapter 3, press Chapter Menu, see which page and
     button come up.
2. **No First Play PGC (VMGI@0x84 = 0).**
   - libdvdnav's `set_FP_PGC` then plays VMGM PGC 1 in the First Play domain.
   - The reader's `S_JMP_VMGI` raises `pgc_error` instead, so the VM's FB_FP fallback
     goes to the auto title.
   - The census found 2 such discs (D050818_01, ISLAM_TRAILER) and no First Play PGC
     with cells.
   - **Proposed fix (not built):** the reader mirrors `set_FP_PGC`.

**Pass 2 (1,531 discs, the fixed model and oracle, a fresh run):**

| Status | Discs | Notes |
|---|---|---|
| `ok` | 1,492 | 2,025 landings compared and agreed; 515 discs never parked (below) |
| `rnd` | 26 | all 9 `DIFF` rows are on these: game discs, plus films with a random trailer or menu (Butterfly Effect, Die Another Day 2, Hot Chick, The Office UK) |
| `oracle-err` | 6 | Harvard Man, Tangled, Lady Highwayman, Matrix Reloaded disc 2, DragBal1, DragBal2 |
| `nolanding` | 3 | the two no-First-Play discs; **Anchorman**, a cap artefact: the model reaches the same menu ~16k blocks later, and at a 200k cap the two agree (and it runs `rnd`) |
| `cap-edge` | 1 | MANONFIRE |
| `ok-gprm` | 1 | **T3** (SPRM7) |
| `udf-only` / error | 1 / 1 | MILLIONAIRERUS / `_hwtest/BADIMAGE` (not ISO9660) |

**The 515 discs that never park** boot straight into playback: libdvdnav does not stop
on a menu inside the cap, so no action runs. Their position at the cap is still the
boot chain's result (First Play → the feature), and it is now compared as a `boot`
row: ⏳ running.

## 6. Decisions and rejected alternatives

- **Not the audio engine's silicon:** it is 28–45 % busy during playback, which is
  when cell changes and NV_PCKs arrive (§10b). The method is shared, the machine is
  not.
- **No 64-bit barrel shifter:** command fields are byte-aligned inside 16-bit words,
  so a 16-bit shifter does.
- **`dcmp` is an instruction:** the compare op is a runtime field. A jump table per
  compare would have cost ~16 words per use site.
- **The sequencer is in `dvd_vm.sv`:** a separate `dvd/nav/nav_seq.sv` would have
  changed the file lists of six runners and the `-y` search of four more.
- **`J_DE` packs domain and menu entry into one output:** it saved one instruction at
  ~20 jump sites (part of getting the program from 1,080 words to 1,014).
- **The ROM is baked in with `$readmemh`**, not loaded from a file (user decision,
  2026-10-07). A microcode-only change still needs a rebuild. Quartus's update-MIF
  flow might avoid the refit (⏳ unverified on 17.0).

## 7. Next

- **The ROM has 52 words free (972 / 1,024),** after the 2026-10-08 compaction
  (`feature/nav-sweep`): the domain and VTS setup shared by most jumps (`JSETV`,
  `JSETV0`), and the mount clear as one loop over a contiguous RAM range. Past
  that, a fifth M10K gives 1,280 words. The RSM save could still become a table
  walk.
- **The sequencer's register file has four read ports** (`rs`, `rt`, `rd` for `st`,
  `rk` for `dcmp`). Folding `st` onto `rt` and `dcmp`'s op onto a fixed register is
  the obvious ALM trim inside the 663.
- **The reader's parse** (§10b's real prize, its 4,352 ALM): first the measurement
  split of `dvd_iso_reader`'s states, then the same method.
