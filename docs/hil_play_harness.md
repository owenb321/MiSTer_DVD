# Real-time play-and-measure harness

**Status:** 🔧 host side working end to end on the rig with the capture card (2026-10-23).
The nav event FIFO (fabric) is merged, fitted and ✅ drains on the board (2026-10-23): "Nav event FIFO (fabric)" below.
**Tools:** `tools/disc_timing.py`, `tools/hil_play.py`, `tools/hil_timeline.py`.
**Built for:** issue #176 (Mad Dog McCree). Every fix there needed another round of the
maintainer play-testing by hand, and each round found a timing problem that the bench
sims and the NAV-packet replays had not predicted.

The harness plays an interactive disc on the real board in real time. It fires inputs at
chosen moments and records the capture card. Then it puts the captured pictures, the
captured audio, the core's telemetry, the presses and the disc's authored timing on one
clock and scores the outcome. Operating notes are in `.claude/skills/hil-testing/SKILL.md`
and the rig mechanics in `docs/hil_harness.md`.

## Decisions and why

| Decision | Why | Rejected |
|---|---|---|
| Timed presses are decided **on the board** by a Python agent. The host only deploys, records and analyses. | An ssh round trip is 1–2 s and the capture is ~0.13 s behind, so a press that must land within ±30 ms of a picture cannot be steered from the host. The agent fires within 15–30 ms of plan. | Host-side vision loop for timed shots. It is kept for slow navigation and checks only. |
| **The capture is the judge.** Scoring (which branch, pictures shown, audio present) comes from the recording. | It is the only thing that sees what a player sees, and it needs nothing inside the core. So it scores every build alike, including v0.9.1 and the earlier dev builds that predate any instrument. An A/B is only fair if both arms are measured the same way. | Scoring from new telemetry. That cannot measure the controls. |
| **Telemetry and the nav FIFO are the explanation** (why a branch was taken, when buttons went live). | One-cycle events (cell-command dispatch, button activation) are invisible to 20 ms snapshots, and only an STC-stamped FIFO keeps their order. | Eight more snapshot words. They are fine for navigation but lose pulses. |
| **Reference = the authored windows** (`hli_s_ptm`/`e_ptm`, the cell command). | They are the contract. Mad Dog was authored against set-top players that honour them, and the maintainer hits every window on one. | A libdvdnav capture. It only adds one implementation's choices about what the spec leaves open: answering buttons on NAV read (where `EARLY_LEAD` came from) and the command at the read end. Those are exactly what is suspected wrong, and its timing depends on host buffering. A short set-top recording is the tie-break if a scene contradicts its authored window. |
| **Navigate by playing the disc's own flow**, closed on telemetry predicates. | GPRM state (lives, branch history) is part of the scene. A direct VM jump would reach a different scene from the one a player reaches. | Debug "goto VTS/PGC" commands. Blind timed key sequences, which were fragile. |

## The three clocks and how they are tied

| Stream | Clock | How it reaches host wall time |
|---|---|---|
| Capture frames and samples | host wall time | `ffmpeg -f v4l2 -ts mono2abs … -copyts` (and Pulse's own wall stamps). The container PTS **is** host time, at 1 ms resolution. ⚠ `-t` must be given per input: an output `-t` with `-copyts` writes an empty file. |
| Telemetry rows, presses, agent events | board `CLOCK_MONOTONIC` | 15 ping-pongs over the agent's ssh stdin/stdout before the scenario. The lowest-RTT one sets the offset, with an uncertainty of RTT/2. Measured RTT is 0.9–1.1 ms on the LAN, so ±0.5 ms. |
| Disc PTS | MPEG PTS of the picture on screen | `hil_timeline.py align` identifies every captured frame's (cell, PTS) by matching it against thumbnails decoded from the cell's own sectors. |

**Capture latency** (`report`, per run): for picture k after the agent's `base`, the board
time its pickup counter reached k is set against the capture time that picture first
appeared. The first run measured a median of **0.129 s** (IQR 0.115–0.145 s over 299
pictures). That figure spans the core's pickup→pins delay *and* the card, so removing it
gives the picture the core had picked up at a press. That is the core's own "now", which
is what button timing is judged against, not what a viewer's eye saw at that moment.

## Picture identification (`hil_timeline.py align`)

- **Reference:** each cell's sector range (`disc_timing.py`) is cut out of the image and
  decoded by ffmpeg into 48×32 grey thumbnails stamped with their MPEG PTS (`-copyts`).
  Cells are kept apart because the PTS restarts at most Mad Dog joins.
- **Capture:** the active picture is found by `cropdetect` majority vote. The core
  pillarboxes 4:3 inside the raster: two captures measured 532×480 at x=94 and 528×480
  at x=98, so the area is detected rather than hard-coded. A central band of it is compared, clear of overscan, the HUD blocks in the
  top-left and the transport bar.
- **Match:** normalised correlation of every capture frame against every reference
  picture. Among matches within 0.01 of the best, the one that continues the previous
  frame wins. That tie-break exists because hit and miss branches share footage; without
  it, two identical cells flicker.
- **Saying "nothing":** below `--min-score` (0.80) a frame is `cell: null`, never the
  nearest guess. A uniform frame is `flat`. `margin` (best minus the best match at least
  3 pictures away) marks static shots whose PTS is uncertain. Pace measurements use only
  frames with margin > 0.02.

## What `report` measures

- **Junctions:** the last picture shown of the old cell against its last decoded
  reference picture ("unshown" = authored but never displayed), the gap, and the first
  picture of the new cell.
- **Pace steps:** within a cell, a step of more than 0.1 s in `t − pts` between
  consecutive confident matches. Up is a stall (a picture held), down is a skip (pictures
  never shown).
- **Audio:**
  - The A/V offset comes from envelope correlation against the reference audio, placed
    by the video mapping. It includes the capture chain's own skew; `lipsync_measure.py`
    calibrates that separately.
  - Every stretch where the reference cell is loud (> −35 dB) and the capture is silent
    (< −60 dB) is listed, flagged **EXACT ZERO** when the capture holds digital zero.
    That is the saloon's "gunshot missing" signature.
  - Self-test: one muted second in a real capture is reported as EXACT ZERO, and only
    there.
- **Presses:** each tap placed on the picture the core had picked up.

## Scenario format (`hil_play.py`)

See the docstring. Steps are `wait` (a Python predicate over the newest telemetry
sample: `live`, `menu`, `pause`, `still`, `pictures`, `aud_frames`, and `nav` once the
FIFO exists), `sleep`, `key`, `key` + `at_pts` (the picture-count fit inherited from
`hil_shot_sweep.py`), `base`, and `mark`.
- `"$NAME"` values are filled in by `sweep --vary NAME=a,b,c`.
- `--rbf` is repeated to A/B builds.
- Keep scenarios with a board image path out of the repo: the path names a share layout,
  and it differs between rigs.

Runs go to `tools/streams/hil_runs/<time>/` unless `--out` says otherwise. That directory is
gitignored and on disk. ⚠ Don't point runs at a RAM-backed `/tmp`: the capture is
~3 MB/s, so an autoplayed game is several GB. Twelve trials filled 8.7 GB of a 16 GB
tmpfs before this default existed.

Taps go through the key daemon's FIFO as single `key <code> 30` writes; the queued `keys`
command costs 170 ms per key. Launch aborts if this launch's `mount result` line says
FAILED. A failed mount still tells the core a disc arrived, which otherwise shows up as a
confusing timeout.

## Rigs

- The capture card is on **.236**, the maintainer's rig. Use it only when the maintainer
  says so. .201 has no capture path.
- After a reboot, the rig's CIFS share must be remounted with its own
  `Scripts/cifs_mount.sh`.
- The share layout differs between rigs (`cifs/DVD/...` vs `cifs/games/DVD/...`).
- Check `mister.py state` first, announce to peer sessions, and `mister.py restore` after.

## Findings so far

- **v0.9.1, first shootout, Select at 36.1:** HIT (cell 2 → 3 → 6), matching the hand
  table in `docs/dvd_nav.md`.
- **v0.9.1 cuts command-driven cell ends.** At cell 2→3 and 3→6, the last 0.167 s
  (5 pictures) of the cell never reaches the screen; cell 2's last decoded picture is
  37.518 and the last shown is 37.351. The seamless 1→2 junction is complete. This is
  consistent with the pre-#176 cell command running at the reader's cell end.

- **Overlay ladder, first shootout, no shot.** Debug Overlay block #1 was read from the
  capture; authored window 35.549–37.518:

  | Build | Buttons live at (PTS on screen) | vs `hli_s_ptm` | Dead at |
  |---|---|---|---|
  | v0.9.1 | 35.483 | −0.067 s | 37.351 |
  | hold1 | 35.483 | −0.067 s | 37.351 |
  | hold2 / hold3 / hold4 / hold5 | 34.448 / 34.415 / 34.448 / 34.415 | ≈ −1.1 s | 37.351 |

  `EARLY_LEAD` is visible on screen. **Block #1 means "drawn", not "scored":** v0.9.1
  shows the buttons live up to 37.351 yet misses a shot at 37.3, because its cell command
  took its verdict earlier. Only the FIFO's `CELL_CMD` gives the verdict time.
- **Every PTS-restart junction loses 5+1 pictures, on every build.** The outgoing cell's
  last 0.167 s and the incoming cell's first picture are never displayed, and the gap on
  screen is one frame, so they are skipped, not delayed. The continuous-PTS junction loses
  nothing. It is pre-existing (v0.9.1 has it) and is a separate defect from #176. It cuts
  the tail of every window that runs to its cell's end: about 18 % of VTS 15 cell 2's
  0.93 s window.
- **The FIFO on the board, against the capture** (first shootout, `main`'s navigation):
  - `HLI_ARM` and `ARMED` land at STC 35.549, exactly the authored `hli_s_ptm`.
  - The picture on screen at that moment is 35.483: **the display trails the STC by
    ~0.067 s (2 pictures).** That is why the overlay looks as if it arms 2 pictures early.
  - `CELL_CMD` lands at STC 36.347. That is the verdict, and it matches the
    hand-measured "v0.9.1 window closes ~36.3", 1.17 s before the authored end.
  - 171 events in one run, 0 overflow; 1 merge, reported as a `LOST` line.
  - ⚠ `CELL` / `CELL_CMD` carry the **reader's 0-based** cell index, and the reader runs
    ~1.2 s ahead of the display (its "cell 2" arrives at STC 32.08; cell 2 shows at
    33.28).
- **Key latency, measured:** the agent's FIFO write to the key's arrival in the fabric (the
  `PS2` make event) is 1–4 ms, with one outlier of 13.8 ms in 6 presses.

## Known limits / next

- `at_pts` maps PTS through picture count since `base`, so it is valid only on one
  continuous timeline. After a PTS restart (most later Mad Dog cells) it needs the nav
  FIFO's STC stamps, or a `base` re-armed per cell.
- Navigating deep into a game needs nav state (VTS/PGC/cell). On builds without the FIFO,
  routes are time- and flag-based.
- Thumbnail matching assumes the capture shows the whole picture. A zoom or crop setting
  needs `--box`.

## Nav event FIFO (fabric)

**Status:** 🔧 sim-proven (`bench/dvd/run_nav_trace.sh --red`, `main/tests/run_tests.sh
--red`), wired into `dvd/emu.sv`, **fitted, and ✅ drains on the board** (2026-10-23, the second
rig: `DVD_playharness_20261023_1139.rbf` + Main `MiSTer_DVDcss_hil_d0374658`).

**Fit (2026-10-23, `DVD_playharness_20261023_1139.rbf`, SEED 17, unchanged pin):**
- `nav_trace` takes **296 ALM** by entity (the pre-fit estimate was 200–250) and **2 M10K**,
  inferred as one 256 × 80 simple-dual-port `altsyncram`. Whole design: 530 / 553 RAM
  blocks; 39,080 / 41,910 ALM "needed" (that headline swings ~1.5k between fits).
- Timing PASS: clk_dec 89.29 MHz at the worst corner (gate 86), clk_mem 92.77 MHz (gate
  90). `clock_check` reports 0 fail, 0 warn; clk_hdmi's −2.4 ns is the known stock `ascal`.

### Why

Interactive-disc timing bugs (issue #176, Mad Dog McCree) are questions about *when*: when a
menu's buttons went live relative to the picture, when the cell command ran, when the
audio-low hold released, what `g[0]` was set to, and when a key press reached the fabric. The
0x7A telemetry snapshot cannot answer them. It is a level sampled every 10–250 ms, and these
are events a few frames apart. So the fabric logs each event, stamped on the core's own
clocks, into a FIFO that the HPS drains.

### Pieces

| Piece | File |
|---|---|
| The FIFO, 256 × 80 bit, clk_sys | `dvd/nav_trace.sv` (its header is the contract) |
| Instance, EXT_BUS share with dvd_telem | `dvd/emu.sv`, "NAV EVENT FIFO" beside `nav_pci_inst` |
| GPRM write tap (no new RAM port) | `dvd/dvd_vm.sv` `trc_gprm_*`, off the sequencer's data-RAM write snoop |
| Promoted HLI start PTS | `dvd/nav_pci.sv` `dbg_h_sptm` (= `h_sptm`) |
| HPS drain to JSON lines | `main/support/dvd/dvd_ctl.cpp` `navtrace_drain()` |
| Bench, 8 arms, 13 mutations | `bench/dvd/nav_trace_tb.sv`, `bench/dvd/run_nav_trace.sh` |
| Wiring gate, 10 mutations | `tools/check_nav_trace_wiring.py` |
| Drain unit test, 4 RED cases | `main/tests/dvd_ctl_test.cpp` |

### Entry format (80 bits = five 16-bit words, MSB first)

| Bits | Field | Meaning |
|---|---|---|
| [79:75] | `code` | event code 1..16. 0 is never written, so a 0 read back is a protocol error |
| [74:49] | `payload` | 26 bits, per code (table below) |
| [48:16] | `stc` | `av_stc` (the clk_sys mirror of the 90 kHz STC) at the write cycle |
| [15:0] | `fts` | free-running 90 kHz count, bits [20:5]: 1 LSB = 32 ticks = 0.356 ms, wraps every 23.3 s |

**Why two timestamps (a deviation from the original 64-bit design).** The brief preferred the
STC alone, because displayed PTS = STC + `disp_lag` (telemetry word 11), so the STC is the
clock a "relative to the picture" question needs. Reading `dvd/disp_sched.sv` showed it is not
free-running, though. It holds while paused and before video is live, it is zeroed by a flush,
and it jumps on every re-anchor. An event pair either side of a flush, or a key latency
measured across a pause, cannot be ordered or differenced on it. The free tick can, and it is
also what maps an entry onto the HPS's CLOCK_MONOTONIC. Storing both made the entry 80 bits.
That costs no extra M10K, because 256 × 80 is exactly two 256×40 blocks, the same two that
256 × 64 would occupy. It costs one extra SPI word per entry. The free tick is stored at 1/32
resolution in 16 bits and unwrapped by the host against the full 32-bit `free_now` in the
drain header.

The design brief also proposed a 4-bit code. There are 16 codes plus 0 = invalid, so the code
is 5 bits and the payload 26.

### Event codes

Code = priority index + 1. Lower codes are drained first when events coincide.

| Code | Name | Payload [25:0] | Source (emu.sv) |
|---|---|---|---|
| 1 | GPRM | `{6'd0, idx[3:0], value[15:0]}`: every VM write to GPRM 0..15, including the 1 Hz counter-mode increments and the mount clear | `dvd_vm.trc_gprm_*` |
| 2 | STC_JUMP | `delta[25:0]` = new − previous STC, two's complement mod 2^26 (±372 s). Any change that is not +0/+1: a re-anchor, a flush reset, a pause re-sync. The entry's `stc` is the new value. | `av_stc` |
| 3 | JOY | `{kbd, rise[24:0]}`: `joy_eff` press edges in joystick_0's bit order (D-pad [3:0], B1..B21 [24:4]). `kbd` = at least one came from `kbd_map` | `joy_eff & ~joy_prev`, `kbd_joy` |
| 4 | PS2 | `{16'd0, pressed, extended, scancode[7:0]}`: every `ps2_key` toggle, make and break. Digits never reach `joy_eff`, so they are visible only here | `ps2_key` |
| 5 | BTN_ACT | `{14'd0, btn_ns[5:0], btn_sel[5:0]}`: nav_pci activated a button | `hl_btn_cmd_valid` |
| 6 | CELL_CMD | `{10'd0, cur_cell[7:0], cmdnr[7:0]}`: the reader handed the VM a cell command | `vm_cell_cmd_w`, `cur_cell_cmdnr_w` |
| 7 | HLI_ARM | `{btn_ns[5:0], h_sptm[19:0]}`: an HLI with buttons was promoted onto the screen. `h_sptm` is its authored start PTS, so `stc − h_sptm` (low 20 bits) is how late the buttons went live | `hli_arm_w`, `hl_sptm_w` |
| 8 | ARMED | `{19'd0, btns_armed, btn_ns[5:0]}`: `btns_armed` changed (either edge) | `hl_btns_armed` |
| 9 | CELL | `{9'd0, menu, cur_vts[7:0], cur_cell[7:0]}`: cell or VTS changed | `cur_cell`, `cur_vts` |
| 10 | PGC | `{1'b0, menu, cur_vts[7:0], cur_pgcn[15:0]}`: PGC, VTS or domain changed | `cur_pgcn_rd` |
| 11 | FLUSH | `{20'd0, rise[5:0]}`: [0] load_flush [1] aud_flush [2] aud_resync [3] seek_flush [4] mount_flush [5] soft_flush (rising edges) | `flush_ctl` outputs |
| 12 | AUD_LOW | `{9'd0, low, frames[15:0]}`: emu's `aud_ring_low` hysteresis flag (<6 frames low, ≥12 ok) changed | `aud_ring_low`, `aud_frames_avail` |
| 13 | STATE | `{18'd0, chg[3:0], now[3:0]}`: [0] pause [1] still [2] video_live [3] menu_active | `pause_q`, `still_active`, `video_live_s2`, `menu_active` |
| 14–16 | X0–X2 | `x_pl[k*26 +: 26]` | **tied off on main.** Hooks for issue #176 |

**Issue #176 hooks.** The signals `h_so`, `nxt_early` and `cc_aud_low` exist only on the
issue #176 branch, which has its own `nav_pci`. On that branch, wire them to `x_ev[2:0]` /
`x_pl` of `nav_trace_inst` as X0..X2 (codes 14..16). Main's `dvd_ctl.cpp` logs them as
`"raw"`, and the host decodes them. Main has no `cc_aud_low`. Its nearest equivalent,
`aud_ring_low`, is logged as AUD_LOW.

After a reset the edge detectors start at 0, so the state at reset release is logged once
(CELL, PGC, ARMED, STATE...). That is deliberate: it is the log's baseline.

### Simultaneous events, overflow, ordering

- **One RAM write per cycle.** Each source has a pending bit, and the highest-priority pending
  source is written each cycle. Sixteen events at once take 16 cycles, which is under 1 µs and
  well under one 11 µs STC tick.
- **Merge.** A source that fires again while still pending, and is not being written that
  cycle, has its two events merged into one entry. `merges` counts that. It counts cycles in
  which at least one merge happened, so two sources merging in the same cycle count once.
- GPRM is top priority and its pending bit is set-wins-over-clear, so a write every cycle (the
  mount clear) is logged with no merge (`[simul]`).
- **Latched and live payloads.** Payloads are latched for the sources whose data is transient:
  GPRM, STC_JUMP, JOY, X0–X2, and the FLUSH and STATE change masks, which OR-accumulate while
  pending. They are read live at the write for state that holds: cell, PGC, button counts,
  `ps2_key`, `aud_frames`. That is ~110 flops instead of 16 × 26. A live payload shows the
  value at the write, up to 15 cycles after the event.
- **Full.** When the FIFO is full the event is dropped and `ovf` counts it. Holding the event
  would only mis-time it. Both counters are 16 bits, wrap, are reset only by the core reset,
  and ride every drain header.
- **Order.** Entries are in write order. Events in one cycle are written in priority order. An
  event delayed behind higher-priority ones is at most 15 cycles late, which neither timestamp
  can resolve.

### Readout protocol (UIO command 0x7C)

This is the dvd_telem protocol over hps_io's EXT_BUS: `io_enable` frames a transaction,
`io_strobe` clocks one word, the first strobe carries the command, and the word answered at
strobe k is word k. 0x7C is free: Main uses 0x00–0x44, 0x61–63 and 0xF0–F9, and 0x7A/0x7B are
dvd_telem. dvd_telem takes the bus only for 0x7A/0x7B and nav_trace only for 0x7C. Each
decides on the transaction's first strobe, so the emu OR/mux (`ext_bus[32] = telem_drive |
trc_drive`, `ext_bus[15:0] = trc_drive ? trc_dout : telem_dout`) never sees both drive.

| Word | Content |
|---|---|
| 0 | MAGIC `0x5E01`, with bit 15 clear |
| 1 | N, the entries in this reply: min(fill, 64), latched at the command |
| 2 | fill, the entries in the FIFO at the command (0..256). fill > N means more are waiting |
| 3 | ovf: events dropped because the FIFO was full (wrapping) |
| 4 | merges (wrapping) |
| 5, 6 | `free_now[31:16]`, `free_now[15:0]`: the free tick at the command |
| 7, 8, 9 | `{15'd0, stc_now[32]}`, `stc_now[31:16]`, `stc_now[15:0]` |
| 10 .. 10+5N−1 | N entries, five words each, oldest first |
| beyond | 0 |

- **Absent.** A core without the module never drives the bus for 0x7C, and hps_io zeroes
  `io_dout` on every strobe of a command it does not know (`sys/hps_io.sv`, the
  `io_dout <= 0` at the top of the strobe branch), so word 0 reads 0. Main writes
  `{"absent":true}` once and stops draining until the arm file is re-created.
- **Atomic header.** `free_now` and `stc_now` are snapshotted on the command strobe, so a carry
  between two words cannot tear them.
- **Pop on the last word.** An entry is popped when its fifth word is strobed out. A
  transaction cut short loses nothing, and the partly read entry is read again next time
  (`[proto]`, mutation R9).
- **M10K read-ahead.** The RAM read port is free-running on the read pointer, so the head entry
  is always waiting in `q`, and after a pop the next entry is there one cycle later. Strobes
  must be ≥ 2 clk_sys cycles apart. The HPS's are microseconds apart, and `[proto]` runs a
  drain at exactly 2.

### HPS side (`dvd_ctl.cpp`)

- **When.** Only while `/tmp/dvd_telem_fast` exists (which itself needs `/media/fat/dvd_hil`).
  It drains once per telemetry sample, right after the 0x7A snapshot. It never loops: a backlog
  over 64 entries drains over the following samples.
- **Output.** One JSON line per event, appended to `/tmp/dvd_navtrace.jsonl`:

  ```json
  {"t":12.345678,"t_ev":12.301234,"stc":1234567,"free":987654,"ev":"HLI_ARM",
   "btn_ns":4,"sptm_lo":284280,"late_ticks":300,"ovf":0}
  ```

  - `t` is CLOCK_MONOTONIC at the drain.
  - `t_ev` is the event's own monotonic time: `t − (free_now − free)/90000`, exact to 32
    ticks plus the SPI latency.
  - `stc` and `free` are the raw stamps. `ovf` is the cumulative counter.
  - Payload field names per code are in `navtrace_fields()`. HLI_ARM's `late_ticks` is the
    signed low-20-bit `stc − sptm`, so a positive value means the buttons went live late.
- **Other lines.**
  - The first drain after an arm writes a `DRAIN_START` line (`free_now`, `stc`, fill and the
    counter baselines) and tags its entries `"backlog":true`. They may predate the arm, and an
    entry older than 23.3 s has an aliased `fts`.
  - An `ovf` or `merges` increase writes a `LOST` line (`dropped`, `merged`), so a gap is never
    silent.
- **Cost (estimated, not measured).** A full drain is 10 + 5 × 64 = 330 SPI words on the poll
  thread that also services the core's SD reads. At a few hundred ns per word through the
  HPS–FPGA bridge, that is ~0.1–0.3 ms, and it only happens when 64 events are waiting. An
  empty drain is 10 words. ⏳ Measure on the rig (time `navtrace_drain` with a full FIFO).

### Fabric cost (estimated; no compile was run)

- **M10K:** 2 (256 × 80, inferred via the `dram` idiom: `ramstyle "M10K, no_rw_check"`, write
  and registered read in one `always`). Confirm the "Inferred altsyncram" line for
  `nav_trace|mem` in `DVD.map.rpt` at the first fit.
- **Registers:** ~375:
  - edge-detect copies: 114
  - pending bits and latched payloads: 98. X0–X2's 78 latch bits are constant while tied off,
    and are pruned.
  - pointers and counters: 50
  - readout, including the 65-bit header snapshot: 112
- **ALM:** ~200–250, against the ~200 target. The largest pieces are the 16:1 payload mux,
  the 33-bit STC subtract and the header/entry readout mux.
- **If the fit is tight,** in order of value lost per ALM:
  1. drop the header snapshot and read `free`/`stc` live (−65 FF; a tick between words 5/6 or
     7–9 then tears the value)
  2. drop the PGC source
  3. narrow `ovf`/`merges` to 8 bits
- **Timing.** Everything is clk_sys (27 MHz). Nothing touches clk_dec or clk_mem.

### Limits (never silent)

- `fts` aliases for an entry older than 23.3 s at its drain. The first drain's entries are
  tagged `backlog`.
- STC_JUMP deltas beyond ±372 s alias mod 2^26. The entry's new `stc` is exact.
- Only GPRMs are logged (data RAM 0x00..0x0F). SPRM writes are not.
- HLI_ARM carries `h_sptm[19:0]`. Its lateness wraps at ±5.8 s.
- One code per source. A source firing twice within its drain latency is one entry plus a
  `merges` count.

### Next steps

1. Fit: confirm the 2 M10K and the ALM delta, and re-sweep the seed if needed (CORE_VERSION is
   already per-branch).
2. HIL: arm `/tmp/dvd_telem_fast`, play a menu disc, and check that `/tmp/dvd_navtrace.jsonl`
   shows HLI_ARM / ARMED / BTN_ACT / CELL_CMD / GPRM in the expected order. Measure a uinput
   key's `t_ev − send time`.
3. On the #176 branch: wire `h_so` / `nxt_early` / `cc_aud_low` into X0..X2.
