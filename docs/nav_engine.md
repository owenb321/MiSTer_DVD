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
| SPRM1/2/3/8 (they are ports), the SPRM8 shadow / activation latch / freeze, the SPRM3 write-back; SPRM6/7, which follow a title as it plays (§5a) | the RAM-resident SPRMs 4, 5, 9, 10, 13 |
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
  - 1,280-word program ROM (5 M10K, an 11-bit pc; 4 M10K and 1K words until the save-state restore, §8);
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

- **Size:** 972 of 1,024 words (1,014 at the merge). It was compacted 2026-10-08 (§7):
  sim-proven by the full gate set on the final tree (`run_vm_ab --red`, every VM runner
  `--red`, and `run_reader_regress` IDENTICAL to `main` on all 51 arms: the compaction
  kept every jump path's instruction count). ⏳ Not yet on a board.
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
| `bench/dvd/run_vm_ab.sh` (snapshots) | every script also carries `pulse snap` steps (§8): old FSM = new RTL proves a snapshot changes nothing; py = new on its words; `;MUT snapram` / `snapsprm`; wrapper arms W8–W10 |
| `bench/dvd/run_vm_snap.sh --red` | the snapshot end to end, real microcode + `dvd/vm_snap.sv` (§8): 8 arms, S1–S10, `tools/check_vm_snap_wiring.py` (12 wiring mutations) |
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
PR #169).**
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
It needs `tools/bin/trace_nav` (`tools/build_dvd_trace.sh`; untracked). A library that keeps
non-DVD-Video images in subdirectories can skip them with `NAV_SKIP_DIRS=dir1,dir2`. Use
`--jobs 4` on a network library; each worker is light now. A model log once took a
worker to 11 GB, and the logs are now dropped after each stimulus.

### 5a. The library sweep (2026-10-08, PR #169)

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
oracle `bench/dvd/ref/dvd_vm_hw.sv` behaves the same, so neither is the microcode's).
**Both are fixed (2026-10-08, PR #169, user decision): ✅ HW-confirmed**;
the fix is described after the list.

1. **SPRM7 (PTTN) and SPRM6 (TT_PGCN) do not follow playback.**
   - libdvdnav updates both as a title plays (`src/vm/getset.c`):
     - `set_PGN`, on every cell start in the title domain, sets `PTTN_REG` from
       `vm_get_current_title_part`. That is the global part, reverse-mapped from
       {pgcN, pgN} through VTS_PTT_SRPT: the same quantity as the reader's `cur_pgm`.
     - `set_PGCN` sets `TT_PGCN_REG = pgcN` on every title-domain PGC.
   - The core writes SPRM7 only at a jump (1, or the part a `JumpVTS_PTT` names), and
     SPRM6 only to 0 (both at mount, and restored by RSM).
   - T3's VTSM PRE copies SPRM7 into g6 after the feature's last chapter: libdvdnav
     2, the core 1.
   - **Library census** (`tools/sprm_census.py`: every PGC's PRE/POST/cell commands;
     button commands are not scanned; type 0/1 compares and type 3 register-source
     sets only), 1,531 discs:
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
   - **Built** (see "The fix" below): wrapper registers fed by the reader's part and
     the PGC load.
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
   - **Built:** the reader mirrors `set_FP_PGC` (`docs/dvd_nav.md`, the domain table).

**The fix (2026-10-08, PR #169).**

- **SPRM6/7 are wrapper registers now**, like SPRM1/2/3/8. The microcode writes them at a
  jump, a resume and a mount through `UOUT_SPRM6/7`, and reads them through the window, so
  `RSM_SAVE` costs 2 cycles less (an `in` where it had an `ld`). The hardware updates them:
  - **SPRM6** takes `cur_pgcn` on a title-domain `pgc_loaded`, before the PRE runs, as
    `set_PGCN` does;
  - **SPRM7** takes the reader's part (`ptt_upd` / `ptt_val`), held until the VM is at
    rest: parked at the idle `wev` with no event, tick or walk pending.
- **Why "at rest" and not "after the PRE".** The reader resolves the part as the first
  cell streams, which can be mid-PRE, and libdvdnav's `set_PGN` runs after the PRE.
  "After the PRE" alone left a one-cycle race with a queued event's RSM save, and the old
  FSM and the sequencer resolved it differently (the A/B found it on seed 15).
- **The reader** publishes the global part from its `cur_pgm` reverse map, on a hit only.
  A PGCN-only title jump (a `LinkPGCN`, a resume) now reads the owning title's PTT table:
  `ttn_pick`, in `docs/dvd_nav.md` "Which title's table". It used to read title 1's, and
  1,139 library discs have a VTS with more than one title.
- **Deliberate differences from libdvdnav's loop:**
  - a reverse-map miss holds SPRM7 (libdvdnav writes 0, but it searches every title);
  - a program past the PGC's last part maps to that part (libdvdnav finds nothing).
- **Gates:**
  - `dvd_vm_tb` S28 a–f;
  - `run_vm_ab.sh --red` W5–W7. The oracle carries the same change as a named DELTA, so the
    A/B still has an independent second implementation;
  - `iso_reader_ptt_tb` asserts SPRM7 on every chapter move;
  - `iso_reader_fpnone_tb` A–F;
  - `check_sprm67_wiring.py`;
  - `bench/dvd/run_sprm67.sh --red`, 7 reader mutations, each caught by its own arm.
- **Reader regress:** verdict-identical; six VM arms shift by 2 cycles, the shorter
  `RSM_SAVE`.
- **HW (rig, A/B vs `dev-navsweep`):**
  - SPRM7 is confirmed. Austin Powers 2's chapter menu, on its second visit from
    chapter 10, opens "Chapters 7-12" with chapter 10 lit; the control opens "Chapters
    1-6" with chapter 1.
  - The First Play fix boots ISLAM_TRAILER's menu but ran into the reader's
    command-before-0xFF-still order. That order was narrowed to looping commands here,
    and removed on 2026-10-10: every 0xFF still now holds before its command, as in
    libdvdnav (`docs/dvd_nav.md` "An indefinite still and its cell command"); the model
    mirrors it.
- **Offline:** T3, D050818_01 and ISLAM_TRAILER now agree with libdvdnav.

**Pass 2 (1,531 discs, the fixed model and oracle, a fresh run):**

| Status | Discs | Notes |
|---|---|---|
| `ok` | 1,492 | 2,025 landings compared and agreed; 515 discs never parked, re-run below |
| `rnd` | 26 | all 9 `DIFF` rows are on these: game discs, plus films with a random trailer or menu (Butterfly Effect, Die Another Day 2, Hot Chick, The Office UK) |
| `oracle-err` | 6 | Harvard Man, Tangled, Lady Highwayman, Matrix Reloaded disc 2, DragBal1, DragBal2 |
| `nolanding` | 3 | the two no-First-Play discs; **Anchorman**, a cap artefact: the model reaches the same menu ~16k blocks later, and at a 200k cap the two agree (and it runs `rnd`) |
| `cap-edge` | 1 | MANONFIRE |
| `ok-gprm` | 1 | **T3** (SPRM7) |
| `udf-only` / error | 1 / 1 | MILLIONAIRERUS / `_hwtest/BADIMAGE` (not ISO9660) |

**The 515 discs that never park** boot straight into playback: libdvdnav does not stop
on a menu inside the cap, so no action runs. Their position at the cap is still the
boot chain's result (First Play → the feature), and it is now compared as a `boot`
row.
- **What it compares:** the sequence of PGCs that played a cell, on both sides. Both
  play into the cap counting blocks differently, so they stop at different points of
  the same chain. One being a prefix of the other is `ok-prefix`; the GPRMs are
  compared only when both end on the same PGC.
- **Result:**
  - 501 agree, 3 of them as a prefix (Horrible Bosses, Mighty Macs, Poseidon
    Adventure: the model one trailer behind);
  - 10 are `oracle-err`: libdvdnav hits `Expected NAV packet` in its first menu or
    trailer (The King's Speech, The Hobbit, HP Prisoner of Azkaban, …);
  - 4 run `rnd`.
- **Can it fail?** `--red gidx` makes the boot row differ on the first six of these
  discs; `setalways` does not, since their boot chains have no false conditional set.

**The whole library, then:** no difference between the microcode and libdvdnav that
the model, a libdvdnav failure, `rnd` or the block cap does not explain, except the
two pre-existing core gaps above (SPRM6/7, no First Play PGC). 16 discs (6 + 10)
cannot be compared, because libdvdnav itself fails on them.

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

- **The ROM has 28 words free (996 / 1,024)** since the state snapshot (§8) took 24.
  The 2026-10-08 compaction (PR #169) had freed them: the domain and VTS setup shared
  by most jumps (`JSETV`, `JSETV0`), and the mount clear as one loop over a contiguous
  RAM range. Past that, a fifth M10K gives 1,280 words. The RSM save could still
  become a table walk.
- **The sequencer's register file has four read ports** (`rs`, `rt`, `rd` for `st`,
  `rk` for `dcmp`). Folding `st` onto `rt` and `dcmp`'s op onto a fixed register is
  the obvious ALM trim inside the 663.
- **The reader's parse** (§10b's real prize, its 4,352 ALM): first the measurement
  split of `dvd_iso_reader`'s states, then the same method.

## 8. State snapshot (save states, step 2)

**Status (2026-10-26): ✅ HW-checked on the rig (below); built, sim-proven and fitted on
`feature/vm-snapshot`.** Read-only:
it changes nothing the VM does. It is the first of the save-state steps agreed with the
maintainer (full save states only, no resume-only feature): (1) the Scooby-Doo 2 freeze
diagnosed (the restore's seek lands in an audio-only VOBU; `docs/roadmap.md` "Save
states"), (2) **this**, (3) a restore exposed only to the HIL harness, (4) the user-facing
feature.

**What it gives.** The whole navigation state, read out of the running core consistently:
`tools/mister.py snap` prints it by name. That is the data RAM (GPRMs, counter modes, the
fallback chain, RSM, the dead-end latch), all 24 SPRMs as a command would read them, the
wrapper's own state (domain, VTS, last menu, LFSR, ...), the reader's read-backs, and the
position of the last NAV pack parsed (see the HW check below: it leads the screen). Uses now: `nav_diff` can compare the whole state at a park (SPRM8 is a
blind spot of §5 today); a bug report can carry it. Step 3 reads the same words back.

**How.**

| Piece | What it does |
|---|---|
| `vm.uasm` `E_SNAP` (24 words) | Three loops stream the words out through `O_SNAP`: data RAM `0x00..0x27`, SPRM `0..23` as `ld M_SPRMI[n] \| in P_SPRMW[n]`, input ports `0..31`. Then `PB_SNAPDONE`. It writes no RAM and no other output; the walk flag makes it count as idle to the wrapper, as the tick does. |
| `dvd_vm` wrapper | `snap_req` sets `snap_pend`, **not** an `ev` latch (E_DISABLED clears every latch). `wev` offers it **last** (`UWEV_SNAP` = 13), only when nothing else is pending **and no SPRM7 part is held** — so a snapshot is always of a VM at rest. `snap_we`/`snap_d` are the output bus at `O_SNAP`; `snap_done` the pulse. |
| `dvd/vm_snap.sv` | 128×16 M10K buffer + the EXT_BUS `0x7D` readout (the `nav_trace` protocol). The request bit (control word, strobe 1) fires `snap_req` **when its transaction ends**, so a buffer is never written while it is read. Latches the position at `snap_done`: NAV-pack LBN, `has_video` (`dsi_1stref_ea != 0`), `prev_video`, cell elapsed time, VOB/cell ids, `pos_fresh` (cleared by `load_flush`, set by `dsi_commit`). |
| `tools/nav_isa.py` | `snap_layout()` names the 96 words; `snap_fmt()` (CRC-16 of the layout, the RAM map and the port list) is the format id the core reports and every reader checks. |
| `dvd_ctl.cpp` `vmsnap` | One request transaction, then polls every 20 ms until `seq` moves with `busy` clear; writes `/tmp/dvd_vmsnap.json` whole (rename); 3 s timeout file if the VM never rests. HIL-armed only (`/media/fat/dvd_hil`). |
| `tools/vm_snap.py` | Decodes the JSON by name; refuses a snapshot whose `fmt` is not this tree's. |

**Why these choices.**
- **A microcode handler, not a hardware read port.** After PR #168 almost all the state is
  in the data RAM, so the copy is a loop: no read mux over flops, no second RAM port, and
  consistency comes free (the handler runs only at rest). The old save-state branch needed
  a 48-way capture mux, a retry protocol and a `coherent` trailer for the same job.
- **`0x7D`, not the nav event FIFO.** A save must not be lossy; the FIFO drops records
  when full. `0x7D` will also carry step 3's restore writes.
- **Wait for a held SPRM7 part.** Found by the A/B (seed 35): the part lands at `vm_rest`,
  and whether `pre_armed` cleared a cycle before the snapshot was taken decided whether the
  snapshot saw it. Waiting makes it always see the landed value (wrapper arm W9).
- **`has_video` and `prev_video` are in the position** because of `docs/roadmap.md` "Save
  states" step 1: a restore must not land in a VOBU without a picture. Step 3 can snap back
  to `prev_video` from what step 2 already records.

**Gates.** `bench/dvd/run_vm_ab.sh --red` (transparency + words + arms), `bench/dvd/
run_vm_snap.sh --red`, `main/tests/run_tests.sh --red` (`dvd_ctl_test` [6]–[11], arms
`ctl-vs-*`), `tools/check_nav_trace_wiring.py` (the three-way reply bus).

**Limits.** A mount aborts a running stream (`busy` stays set; the host times out and asks
again). A request while a jump waits for its verdict waits for the VM's give-up timer
(~0.62 s). The snapshot leaves out `sprm8_frozen`, `ptt_pend` and the sequencer's registers:
none matters at rest, and the format is versioned, so one can be added if step 3 needs it.

**HW check (2026-10-26, rig, `DVD_vmsnap_20261026_1540.rbf` + the branch's Main).**
Scooby-Doo 2 with the nav event FIFO draining from boot; `mister.py snap` at the main
menu and inside the Mystery Inc. HQ minigame (VTS 2 PGC 4). Both snapshots decode to the
expected place (VTSM menu with RSM = title-set 1 PGC 2, the boot chain; then TT, SPRM4 =
10, SPRM6 = 4) and **all 16 GPRMs equal the last value the FIFO logged for each** (46 and
62 writes; in the game g8 = g15 = `0x3e7`, as the PGC's PRE writes). The check can fail:
dropping the single write g15 = `0x3e7` from the log is reported as a g15 mismatch.

⚠ **The position is the last NAV pack the DEMUX parsed, not the picture on screen.** In
the minigame the screen was 5 s into cell 1 while `nv_pck_lbn` was already in cell 2's
sectors: in a low-bitrate cell the decoder's buffers hold seconds of stream. The old
save-state note called `dsi_nv_pck_lbn` "the playhead"; it leads it. A restore landing on it
skips ahead by that lead (the old branch's film bookmarks landed ~1-3 s late, which fits).
Step 3 should save the position of the displayed picture (e.g. the NAV pack whose VOBU
holds the displayed PTS), or step back by the buffered lead.

**Cost, measured** (full fit `DVD_vmsnap_20261026_1540.rbf`, SEED 7, against the
`DVD_playharness_20261025_0214` fit of `main`'s code): `vm_snap` **125 ALM, 220 registers,
1 M10K**; `dvd_vm` 871 → 888 ALM (+17; its registers unchanged at 741, the ROM still 4 M10K);
24 ROM words. About **142 ALM + 1 M10K** attributable. The design total moved 39,080 → 40,838
placed ALMs, but that is the seed (17 → 7): `dvd_telem` and `nav_trace`, untouched, moved
+82 and +45 in the same fit. RAM blocks 530 → 532 / 553. Timing passes: `clk_dec` 90.49 /
**86.81** MHz (100 / −40 °C, gate 86.0 — a thin cold-corner margin, 0.81 MHz), `clk_mem`
94.12 / 97.64.


## 9. Restore (save states, step 3)

**Status (2026-10-26): ✅ HW-checked on the rig (below); built, sim-proven and fitted on
`feature/vm-snapshot`.** Exposed only to the HIL harness (`mister.py vmload`, the `dvd_ctl` FIFO): no OSD rows, no
slot files. Step 4 is the user-facing feature (`docs/roadmap.md` "Save states").

**What it does.** A snapshot taken by §8 goes back in: the VM's data RAM, its SPRMs and
the wrapper's state are restored, and the VM jumps to the saved PGC and **cell**, PRE
skipped. The landing is the cell's start, not a position inside it (below).

**How.**

| Piece | What it does |
|---|---|
| `dvd/vm_snap.sv` LOAD | Control bit 1: the transaction carries fmt, len, a 16-bit checksum and the blob, written into the snapshot buffer. **Checked when the transaction ends** (fmt = `snap_fmt`, len = `WORDS`, every word arrived, the sum); only then `restore_req`. The verdict (header word 4: pending, applied, refused format / length / checksum / busy) and a restore count are readable. A load or a snapshot request while a restore is pending is refused; a load while a snapshot is pending likewise. While pending, the buffer's read port is the VM's (`rst_ra` → `rst_q`). |
| `dvd_vm` wrapper | `restore_req` sets `rst_pend`, offered after the snapshot, at rest, and **only with Disc Menus on** (`UWEV_RST` = 14). `RSTQ` (input port 27, once `ZERO27`) reads the blob word, 0 outside a restore, so a snapshot's copy of it is 0. `RSTW` writes LFSR, domain, VTS, menu_seen and the last-menu latch in that order (`nav_isa.RSTW_PORTS`, asserted contiguous). `FRZ8` freezes SPRM8 until the landing's load. `jump_ttn_hint` rides `O_J_TTN` bit 15. |
| `vm.uasm` `E_RST` (62 words) | RAM 0x00..0x27 and the RAM-resident SPRMs (mask `0x2630`) word for word; SPRM1/2/3/6/7 and (frozen) SPRM8 through their ports; the eight wrapper registers through `RSTW`; then `UPRO` (a new activation), the jump (`JSET`: the saved domain; a title's VTS from the reader's read-back, a menu's from the VM's own, §5f of `save_states.md`; PGCN; cell), `skip_pre = 1`, `tt_resolve = 0`, `RSTDONE`, `JGO0`. |
| `dvd_iso_reader` | `jump_ttn_hint`: the ttn feeds `want_ttn` (the title's chapter map) and `want_pgcn` keeps the exact PGCN. Clear, bit-identical to before. Ported from `feature/save-states`. |
| ROM | 1,280 words (a fifth M10K, an 11-bit pc): the handler did not fit the 28 free. |
| `dvd_ctl.cpp` `vmload <file>` | Reads a `vmsnap` file, sends the LOAD, polls the verdict into `/tmp/dvd_vmload.json`. |

**Decisions.**
- **Cell-granular landing.** Two things found in steps 1-2 make a within-cell landing
  wrong today: the latched position is the last NAV pack DEMUXED, which leads the
  picture by seconds in low-bitrate cells (§8 HW check); and a VOBU may carry no picture
  (`save_states.md` §5g). For the interactive discs the harness drives, state changes at
  cell boundaries, so the cell start is exact. A film needs the displayed picture's
  position: a follow-up.
- **`tt_resolve` is cleared, not restored.** It is a jump's pending "SPRM5 ← the reader's
  resolved ttn" and a snapshot only catches it after a jump timed out. Restored, the
  landing would overwrite the restored SPRM5 with the live `res_ttn` — found by
  `vm_restore_check.py` (arm `rstttr`).
- **Checked before applied.** The shelved branch wrote the VM's registers as the words
  arrived and checked the sum after (§5c of `save_states.md`). Here nothing reaches the
  VM until the whole blob has checked.
- **Existing ports where they exist** (SPRMs, domain, VTS): the microcode's ROM words
  are cheaper than another 16-bit mux input on registers that already have writers,
  which is what cost the shelved branch +288 ALUTs.

**Gates.** `bench/dvd/run_vm_ab.sh --red`: `vm_ab.py --restore` (py = RTL on every stream,
restores interleaved), `tools/vm_restore_check.py` (a restore puts back what the snapshot
took, over random histories; arms `rstram`, `rstw`, `rstfrz`, `rsthint`, `rstttr`), wrapper
arms W11–W13. `bench/dvd/run_vm_snap.sh --red`: [refuse] [load] [pending], S11–S15, the
wiring (hint, restore seam, `WORDS`). `main/tests/run_tests.sh --red`: `dvd_ctl_test`
[12]–[15], `ctl-vl-*`. `run_reader_regress.sh` against the step-2 commit.

**HW check (2026-10-26, rig, `DVD_vmsnap_20261026_1700.rbf` + the branch's Main).**
Scooby-Doo 2. Snapshot A in the HQ minigame (VTS 2 PGC 4, cell 1); Menu to the Additional
Special Features menu (snapshot B differs from A in 27 words: g1, g8, g15, RSM, domain,
last menu, LFSR, ...); `mister.py vmload A`: **applied**, the core lands back on the
minigame's cell 1 and plays on into the HQ room. Snapshot C after the landing differs
from A in 4 words, each accounted for: `fb` (the restore's own jump clears it), SPRM7 and
the reader's cell (playback moved on, cell 1 → 2), `in_jpgcn` (the restore's jump target).
**The §5g case:** a fresh launch, `vmload A` during the WB logo: lands in the minigame,
picture moving, `play_err` 0 — no freeze (the cell start has the picture the §5g landing
lacked). `in_btn0..3` (the last activated button's command, a wrapper latch nothing reads
at rest) is not restored.

**Cost, measured** (`DVD_vmsnap_20261026_1700.rbf`, SEED 7, against step 2's fit):
`vm_snap` 125 → 197 ALM (the LOAD path and its check), `dvd_vm` 888 → 915 ALM, `nav_seq`
576 → 571 ALM: **~98 ALM**. ⚠ **M10K +4, not +1:** Quartus rounds the 1,280-word ROM up to
2,048 deep (8 blocks for `nav_seq`'s ROM). RAM blocks 532 → 536 / 553 (17 free). Splitting
the ROM into 1,024 + 256-word arrays should give 3 back: a follow-up. Timing passes:
`clk_dec` 91.26 / 87.68 MHz, `clk_mem` 99.06 / 99.65.

**The ROM split (2026-10-27).** The 1,280-word ROM was one array, which Quartus rounds up
to 2,048 deep: 8 M10K for 5 blocks' worth of words. It is now two arrays, `rom` (1,024
words, 4 M10K) and `romh` (256, 1 M10K), read on the same clock and picked by the fetch
address's bit 10, registered with them; `tools/nav_isa.py` writes `nav_ucode.mem` and
`nav_ucode_hi.mem` (and `--mutant` / `--mem-out` both images). Same latency, same program:
`vm_ab` is trace- and cycle-identical, and the JumpSS handlers that live above word 1,023
ran 2,218 traced instructions in it. `tools/check_gprm_ram.py` pins both arrays (R6: one
1,280-deep ROM again; R7: a combinational read of the high one).
**Measured** (`DVD_vmsnap_20261027_0410.rbf`, SEED 7): RAM blocks 536 → **533** / 553;
`nav_seq` 9 → 6 M10K (the ROM 5 + the data RAM 1), +23 ALM for the 40-bit select. Timing
passes (`clk_dec` 87.96 / 89.45, `clk_mem` 98.44 / 99.82). Rig smoke: boot chain, Play
Movie, the Menu key (its CallSS/JumpSS handlers run from `romh`), and a restore (+0.36 s,
no picture between the flushes).

**Limits.** A restore waits for the VM's rest and for Disc Menus on; with menus off it
stays pending (verdict 1) and the host times out. A mount aborts a running restore; the
request survives and runs after the boot chain. The disc must be the same one: nothing
checks that yet (step 4's disc identity).

## 10. Exact landing: a restore resumes a film at its picture (save states, step 3b)

**Status (2026-10-26): ✅ HW-measured on the rig (below); built, sim-proven and fitted on
`feature/vm-snapshot`.**

**What.** §9 lands at the saved cell's start: exact for interactive discs, a chapter's
worth wrong for a film. Now a snapshot records the **displayed picture's** PGC time, and a
restore lands at the cell, then seeks to that time through the D-pad's own time-map path
(§2h of `docs/dvd_nav.md`: landings 0.3-0.7 s after the target on hardware).

**The displayed time.** The HUD clock (`whole_eltm`) is the PGC time of the VOBU the demux
just parsed: it leads the picture by the decoder's buffer, ~1 s in a film and seconds in a
low-bitrate cell (§8's HW check). `vm_snap` latches three raw values with the snapshot, on
the same cycle: that clock, that VOBU's `vobu_s_ptm` (newly exported by `nav_pci`), and the
STC (the displayed picture's PTS; telemetry puts the display lag at ~0). The Main computes

    disp_secs = floor( clock - (s_ptm - STC) / 90000 )

rounded to the NEAREST second, and writes it into the snapshot file, or **−1** — land at
the cell start — when it cannot be trusted: no NAV pack since the last flush
(`pos_fresh`), a VOBU with no picture (a still with an audio loop: step 1's no-picture
rule), or a lead outside −1.5..30 s (a PTS discontinuity between the demux front and the
screen). ⚠ **The lead can be slightly negative** — measured −26 ms on the rig just after a
seek, when the buffer is near empty and the picture is a few frames into the front VOBU
itself; the first rule refused every negative lead and lost that snapshot's time.

**The landing.** `vmload` sends `disp_secs` (0xFFFF for none) and the snapshot's NAV-pack
sector (the time map's fallback, for the 3 % of discs without one) with the blob, under
the checksum. `vm_snap` arms on `rst_done`, waits for the landing's `pgc_loaded` and then
its **first NAV pack** (`dsi_commit`; the first picture is the fallback trigger), and fires
**one** `rst_seek_pulse` (§10a). `emu.sv` ORs
it into the scrub's seek in front of `mode_realign` (`seek_any_pulse`) and qualifies it as
a time seek on its own pulse — the D-pad's path exactly, but not a HUD user event. It is
abandoned if a menu landed, another PGC loads first, a disc is mounted, or ~3 s pass.

**Why this way.**
- **Time, not a sector.** A sector for the picture on screen would need the display side
  to track which VOBU each picture came from (a FIFO of NAV packs against PTS). The time
  seek already exists, is HW-confirmed, and goes through the disc's own time map.
- **Host arithmetic, not RTL.** Three 32-bit latches in `vm_snap` cost a few dozen ALMs;
  the BCD conversion, the lead, the bounds and the fallbacks are C, under test
  (`dvd_ctl_test` [16]), and step 4's Main reuses them.
- **At the first NAV pack, not at the load, not at the picture** (§10a).

**Accuracy, measured** (2026-10-26, rig, `DVD_vmsnap_20261026_1856.rbf`, Scooby-Doo 2's
film). Instrument: pause, snapshot F (the saved picture's exact time from its raw clock,
`s_ptm` and STC); Menu; arm the nav event FIFO; `vmload F`; snapshot G 5 s later. The
landing's first picture is the first STC after the time seek's flush in the FIFO, mapped
to PGC time through G's own PTS↔time relationship.
- Rounded DOWN (first build): +0.30, −0.71, −1.05 s — biased early, as the time map lands
  on either side of its target (−0.36..+0.30 s here), not only after it.
- Rounded to the nearest second: **+0.24, +0.17, +0.56, −0.80 s.** The worst is the map's
  own 0.36 s plus the rounding.
- The FIFO shows each restore as: jump flush, the cell start's first picture (~40 ms),
  the time seek's flush on the same tick, the landing's first picture ~175 ms later.
OFFSET/DRIFT time maps (~3.5 % of the library, §2h) land 2-6 s off, as their D-pad seeks do.

**Cost, measured** (`DVD_vmsnap_20261026_1856.rbf`, SEED 7, against §9's fit): `vm_snap`
197 → 306 ALM, 346 → 625 registers (three 32-bit latches, the target and fallback, the
landing state machine); the device is at 41,125 / 41,910 ALM (98 %). `clk_dec` 88.69 /
**86.74** MHz (cold corner 0.74 above the gate), `clk_mem` 100.39 / 101.84.

**Gates.** `bench/dvd/run_vm_snap.sh --red` [land] + [pos] (S16–S20, wiring: the clock,
`s_ptm`, STC, `video_live`); `tools/check_tmap_seek_wiring.py --red` (R9–R12: on its own
pulse, its own time, through `mode_realign`, not a HUD event); `main/tests/run_tests.sh
--red` ([13], [16]; `ctl-vl-lead-added`, `-lead-unbounded`, `-no-video-timed`).

**Limits.** A snapshot whose lead is out of bounds lands at the cell start.

### 10a. One visible transition (2026-10-26)

The first build fired the seek on the landing's first picture, so the cell start showed
for ~40 ms (one or two frames) before the seek's flush: the FIFO logged jump flush → cell
start's picture (+41 ms) → seek flush → landing (+175 ms). Two flushes are unavoidable
without teaching the reader a "jump + time" request; a flash is not.
- **Not at `pgc_loaded`.** `S_PGC_DONE` raises `cell_mode` and `pgc_loaded` together, so a
  seek would be accepted; but `seek_jump` is not gated by the reader's state, and would
  pre-empt the post-load steps (`S_CELL_LOAD`, the angle scan) that a D-pad seek, which
  never arrives microseconds after a load, has never interrupted.
- **At the first NAV pack.** By `dsi_commit` the reader is streaming — where every D-pad
  seek finds it — and the NAV pack leads its VOBU, so the cell start's I-frame is not yet
  decoded; the seek's flush comes at the next block boundary, inside the ~41 ms.
- The first picture stays as the fallback trigger (a cell whose NAV pack the demux never
  reports).

**Measured** (rig, `DVD_vmsnap_20261027_0155.rbf`, Scooby-Doo 2's film, the §10 instrument
plus "was any picture shown between the restore's two flushes", read from the nav FIFO's
`video_live` edges). The instrument sees the old flash: replayed on the previous build's
four trials it reports a picture 40 ms after the jump in every one. This build, four
trials: **no picture between the flushes, which are 11-12 ms apart**; landings +0.22,
−0.31, +0.57, −0.84 s. Timing: `clk_dec` 90.76 / 88.27 MHz.

## 11. The OSD's save states (save states, step 4)

**Status:** ✅ HW-checked on the rig (2026-10-27, below), on `feature/vm-snapshot` (unmerged; by
the 2026-10-27 decision it merges only stacked with a logic reclaim, `docs/roadmap.md` "Save
states"). ⏳ Not yet run: a physical disc, and the maintainer's own play-test.

**What the user sees.** OSD page 2, **Save State**: `Slot` (1-4), `Save to Slot`, `Load Slot`.
Four slots per DISC, in `savestates/DVD/<provider>-<16 hex>_N.ss`; messages from the Main's
notice box. Manual: `site/content/playback/save-states.md`.

**The chain.**
1. `emu.sv` edge-detects `status[55]` / `status[56]` (`R` rows: Main holds the bit for many
   cycles). `vm_snap` counts each press (2-bit, wrapping) and latches the Slot row
   (`status[54:53]`) AT the press, so moving the row afterwards cannot redirect it. All of it
   rides header word 2's spare bits with `vm_en` (= `menus_on` = `dvd_vm`'s enable):
   `{busy, vm_en, slot, load_n, save_n, len}`. The Main polls three words every 20 ms.
2. `main/support/dvd/dvd_sstate.cpp` latches a baseline from the first word it reads (a
   core loaded with moved counters does nothing), then serves one request at a time,
   never blocking the poll thread:
   - **save:** ask for a snapshot (§8), fetch it over later ticks (3 s timeout), write the
     slot file: a 64-byte header (`DVS2`, version, fmt, word count, the words' sum, the
     disc's hash, the landing time and fallback sector the Main computes per §10, the HUD
     clock and core version for tools) and the 96 words.
   - **load:** check the file (magic, version, its sum, the disc hash), send it as a LOAD
     (§9) with its landing, then name the core's verdict.
3. The transport is `dvd_vmsnap.cpp`, shared with the HIL commands in `dvd_ctl.cpp`.

**Disc identity** is the shelved `feature/save-states` branch's, HW-proven there: an FNV-1a
64 hash of `VIDEO_TS.IFO`'s first sector (the VMGI_MAT), named by its provider field. A
disc and any rip of it, raw or rebuilt, share slots; anything without `VIDEO_TS.IFO` gets
no slots. `dvd_phys` now records the drive before the mount so the hook can read a
physical disc (the shelved branch's HW finding).

**Decisions.**
- **Disc Menus off: no save states** (both rows say `Save states need Disc Menus on`; a LOAD
  that reaches a disabled VM is refused as verdict 7 rather than left pending). The shelved
  branch made a menus-off load a bookmark in the playing title; here the restore IS the VM
  (`E_RST`), which is disabled then, and the reader plays the auto-picked title by itself.
  A menus-off bookmark would need a reader-only landing (the auto title + a time seek); not
  built until someone asks.
- **The RNG.** The LFSR is in the snapshot and `RSTW` restores it exactly. But the VM
  stirs it with user-input timing on every button edge while idle (`entropy_stir`, so a
  quiz does not deal the same deck every boot), so outcomes after a load depend on WHEN
  the player presses, as on the original play. A load is not a deterministic replay; the
  dice are as they were, the throw is the player's.
- **A save from another layout** is refused by the core (fmt, verdict 3): "another version
  of the core". `snap_fmt()` changes only with the RAM map or the port list, not every build.
- **2-bit counters.** More than three presses while one request runs fold into one; a
  request runs at most ~3 s.
- **No "SAVE UNAVAILABLE" on stock Main** (the shelved branch's same gap): nothing answers
  the rows. It would need a Main→core acknowledgement that does not exist.

**Gates:** `bench/dvd/run_vm_snap.sh --red` ([ui] [menusoff], S22-S25),
`tools/check_vm_snap_wiring.py --red` (the rows' bits, the edges, `vm_en`, the Main's
word-2 shifts against the RTL), `main/tests/run_tests.sh --red` (`dvd_sstate_test` [1]-[13],
`ss-*` arms; `dvd_phys` [17]), `tools/tests/test_status_bits.py`, `tools/docs_check.py`.

**The user's Audio / Subtitle choice in SPRM1 / SPRM2 (found by the HW round).** The first
OSD save on T2, playing audio 2/4, stored SPRM1 = 0: only the Angle button wrote back to the
VM (`agl_set` → SPRM3); the Audio and Subtitle steps changed `emu.sv`'s registers and left
SPRM1/2 at what the disc last set. So the save lost the track, and any disc command
reading SPRM1/2 read a stream that was not playing (a pre-existing conformance gap: a
set-top player's stream change IS a write of SPRM1/2). `ast_set` / `spst_set` now write
them back, one cycle after the step, from the EFFECTIVE selection; subtitles off keep
SPRM2's stream and clear bit 6 (libdvdnav; the forced-subtitle fallback reads it). A
restore (`vm_rst_done`) syncs `aud_cur` / `sub_on` / `sub_idx` from the restored SPRMs, so
the saved track plays whether or not the write moved the VM's value.

**The highlighted button.** A menu restore lands with SPRM8 restored, but a menu whose PCI
authors a forced select (`fosl_btnn`) highlights that button on entry, as libdvdnav does.
T2's timeline menu forces button 1 (read off the disc's PCI on the rig), so a save on
"Special Edition" loads on "Theatrical". The manual says a disc's menu may start on its
own button.

### 11a. HW round (2026-10-27, rig)

Builds `DVD_vmsnap_20261027_2112.rbf` (the rows) and `_2214.rbf` (+ the write-back), Main
from this branch. Every message read from `/tmp/dvd_report.log` (the Main logs each one it
raises; screenshots cannot see the OSD).
- **T2 menu:** saved on the timeline menu, moved to the main menu, loaded: back on the
  timeline menu (button 1, the PCI's forced select; above).
- **T2 film, landing:** saved at 73 s, skipped to 36:30, loaded: 1:21 eight seconds later.
- **T2 film, tracks (write-back build):** audio 2/4 + subtitles on saved; changed to audio
  4/4 + subtitle stream 2; loaded: popups `AUDIO 2/4`, `SUB 1/2`, SPRM1 = 1, SPRM2 = 0x40,
  landed at 53 s as saved.
- **Scooby-Doo 2 across a boot:** saved in Special Features (GPRM 6 and 10 set), relaunched
  the core, loaded during the boot logos: back in Special Features, GPRMs identical.
- **Refusals:** empty slots say `Slot N is empty`; with Disc Menus switched off live, both
  rows say `Save states need Disc Menus on`.
- **Cost** (`_2214`, SEED 7): 61,776 ALUTs (+17 over the step-3 build), 533 / 553 M10K
  (unchanged), 41,100 ALMs needed (98 %); `clk_dec` 89.24 / 90.24 MHz, `clk_mem` 95.68 /
  96.15, timing PASS.
