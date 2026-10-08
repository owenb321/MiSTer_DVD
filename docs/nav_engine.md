# The DVD VM as microcode (`dvd/dvd_vm.sv` + `dvd/nav/vm.uasm`)

**Status (2026-10-07, branch `feature/nav-ucode`): ✅ HW-CONFIRMED.**
- Built, sim-proven and fitted in the core; timing passes.
- HIL round 1 reproduces the control's `nav_diff` table exactly (§3a).
- The maintainer's hand check passed on build `DVD_navucode_20261007_0640.rbf`
  (2026-10-08).
- Not yet pushed or merged.
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

- **Size:** 1,014 of 1,024 words.
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
  PGCEND and POST, and authored `next_pgcn` on an advance;
- buttons come from the cell's first NV_PCK carrying an HLI;
- playback is charged in sectors against `trace_nav`'s 400,000-block cap.

It parks by `trace_nav`'s rule (`tools/dvd_trace/trace_nav.c`): an indefinite still,
or a button cell confirmed by a still or by a loop. It compares each action's landing
with libdvdnav's: domain, VTS (title and VTSM), PGCN, and the 16 GPRMs. Program and
cell are shown but not compared, because they are timing-dependent at the block cap.

It skips discs that use `rnd`, and treats the first menu call as expected to differ
(the boot-chain shortcut), as `nav_diff.py` does.

**Limits:** no clock, no angle blocks, and a model of the reader rather than the
reader. **A difference is a lead to reproduce on the rig with `nav_diff.py`, not a
verdict.**

Usage:
```
tools/nav_offline.py <disc.iso> --script "1 2 mR 1"
tools/nav_offline.py --library --auto 3 --out results.jsonl    # $DVD_ISO_DIR
tools/nav_offline.py --library --red callss                    # a ;MUT arm must differ
```
It needs `tools/bin/trace_nav` (`tools/build_dvd_trace.sh`; untracked).

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

- **The ROM is full (1,014 / 1,024).** The next microcode addition needs either
  compaction or a fifth M10K (1,280 words is 5 × 256 × 40). Candidates for
  compaction:
  - jump-field setup at each call site;
  - the RSM save, which a table walk could replace.
- **The sequencer's register file has four read ports** (`rs`, `rt`, `rd` for `st`,
  `rk` for `dcmp`). Folding `st` onto `rt` and `dcmp`'s op onto a fixed register is
  the obvious ALM trim inside the 663.
- **The reader's parse** (§10b's real prize, its 4,352 ALM): first the measurement
  split of `dvd_iso_reader`'s states, then the same method.
