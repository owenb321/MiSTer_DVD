# In-fabric DVD-Video navigation (`dvd/dvd_iso_reader.sv`)

**Status: v1 ✅ HW-CONFIRMED 2026-07-05 (PR fj#70, `DVD_isonav`).** ISO files play with
correct video + audio on real hardware; flat `.VOB`/`.mpg` fallback still works. Fit is
healthy (81% ALMs, `parse_buf` a real M10K after the sync-BRAM rework — the first build
hit 226% ALMs from async multi-offset reads; see the module header note).

**Title selection: IFO-primary (2026-07-06, `feature/ifo-title-select`).** The main
feature is now chosen from the DVD-Video **VMGI** (`VIDEO_TS.IFO`) **Title Search Pointer
Table (TT_SRPT)** — the VTS that holds **title 1** (the conventional main feature) — parsed
entirely in fabric. The old **largest-VTS** heuristic (biggest total title-VOB bytes) is
kept as the **fallback** when the IFO is absent or malformed. This fixes the earlier "largest
VTS mispick" on discs with a larger non-feature title set. Chapters/seek/angles and the VTS
PGC subtitle palette still build on this same reader (Phases 7–9); still deferred, as is a
manual OSD title picker. **✅ HW-CONFIRMED 2026-07-06 (PR fj#74):** the general case picks the
right main feature on real discs. Sim: `bench/dvd/iso_reader_ifo_tb.sv`; `tools/iso_nav_check.py`
prints largest-VTS vs IFO title-1 side by side.

**Known hard case — Big Buck Bunny:** on this disc *title 1 is not the main movie* (it's a
special-feature/license title). Both the old largest-VTS heuristic **and** IFO title-1
selection therefore land on a non-feature title (it plays the CC-license/special clip, then
the VTS ends) — IFO is **no worse** here, just still-not-right. The fix is a **manual OSD
title picker** (a cheap interim: let the user pick the title/VTS when title 1 disappoints);
the PGC/cell timeline (below) fixes *ordering within the chosen title* but not *which title*.
Discs where title 1 *is* the feature (the common case) now play correctly.

**PGC cell-timeline playback (Phase 7, `feature/pgc-cell-timeline`) — ✅ HW-CONFIRMED
2026-07-06 (Men in Black, full feature).** After the title VTS is chosen, the reader now
parses that VTS's `VTS_xx_0.IFO` Program Chain and streams the PGC's **cells** in program
(cell-table) order, instead of streaming the VTS's title VOBs linearly end-to-end. This is
the real playback timeline (cells are sector ranges sequenced by the PGC) — it fixes discs
whose feature is authored as ordered/reordered cells (plays the right thing, in order,
skipping non-referenced sectors). Any malformed/absent PGC falls back to the previous linear
whole-VTS streaming. It's the nav foundation that next unlocks chapters/seek (Phase 8), the
PGC subtitle palette, and angles (Phase 9). See "PGC / cell timeline" below.

> **HW note.** MiB (a monotonic single-feature PGC) played the **entire feature cleanly on
> real hardware** — the reader drives playback from the PGC cell list with no regression.
> The **cell-reorder** path (physically non-monotonic cells) is **sim-verified only**
> (`bench/dvd/iso_reader_pgc_tb.sv`). Note Matrix/T2 are seamless-branch discs but their
> PGCN-1 cells are physically **monotonic** — the interleaving is *within* a cell's range
> (the `interleaved` bit), handled by the ILVU `next_vobu` follow (see "Seamless-branch
> interleaved blocks" below, sim-verified 2026-07-12), not by cell reorder.
> Separately, BBB-class "which title/PGC" mispicks are **not** addressed here (deferred:
> VTS_PTT_SRPT TTN→PGC and/or a manual OSD title picker).

The core can now play a **whole decrypted DVD-Video ISO** directly — select the
`.iso` in the MiSTer file browser and it finds and plays the main feature. All
navigation happens **in fabric, with no HPS daemon**, so the whole thing ships in
the one `.rbf`.

## Why this is possible without a daemon

The MiSTer `sd_*` block interface (the S0 mount) is **random-access**: the core
drives `sd_lba` and the always-present framework `main` binary serves *that* block
from the mounted image — exactly how `.vhd` computer cores do disk I/O. The old
`mpg_streamer` read linearly from block 0 only by choice. So the navigation logic
(decide which sectors to fetch) is all that has to move into RTL; the transport was
already there. No second HPS process, no forking the MiSTer binary, no SPI-bus
contention.

`dvd_iso_reader` is a **drop-in replacement for `mpg_streamer`**: same
`stream_data`/`stream_valid`/`busy` output into `ps_stream_fifo`, same `sd_*` bus,
same clk_sys single-clock domain. `dvd/emu.sv` just swaps the instance; `DVD.qsf`
adds the file.

## Scope (v1)

- **Decrypted ISOs only.** No CSS in fabric. Rip/decrypt on the PC (MakeMKV backup,
  `dvdbackup` + `genisoimage`, etc.) so the image on the SD card is plaintext.
- **ISO9660 filesystem only.** genisoimage/xorriso/MakeMKV bridge images always
  carry ISO9660; UDF-only images are a rare minority (deferred — see "Later").
- **Main-title selection — Auto (largest VTS) + OSD manual override — ✅ HW-CONFIRMED
  2026-07-06 (PR fj#76).** **Auto** plays the **largest VTS** (greatest total `_1.._N`
  title-VOB bytes) = the longest-title proxy. **`O[31:28] DVD Title`**: `Auto` (default) or a number `N` that plays
  `VTS_0N` directly — a manual override for **multi-feature discs** where the wanted feature
  is neither the largest nor title 1 (e.g. Big Buck Bunny: set `DVD Title = 2` → VTS_02).
  Match the number to `tools/iso_nav_check.py`'s `VTS_0N`. Menu VOBs (`_0.vob`) and the VMG
  `VIDEO_TS.VOB` are excluded. *(The earlier VMGI TT_SRPT "title 1" auto-pick was retired —
  it chose short logo/license clips on multi-feature discs; the parse states remain but are
  unreachable for Auto. The real fix for ambiguous discs is a **graphical DVD menu** —
  future work; a flat number can't express TV-series episode order.)*
- **PGC cell-timeline playback (Phase 7):** the selected title's PGC cells are then streamed
  in **program order** (see "PGC / cell timeline" below), not the VTS's VOBs linearly.
  Chapters/seek/angles/manual-title-select build on this and are still deferred.

### IFO title selection (VMGI / TT_SRPT) — offsets (IFO fields are BIG-ENDIAN)

After the VIDEO_TS walk, the reader parses two IFO sectors to find title 1's VTS:

- **VMGI_MAT** (start of `VIDEO_TS.IFO`): offset **196 (0xC4)** = `TT_SRPT` sector pointer,
  BE u32, **relative to the IFO start** ⇒ absolute ISO LBA = `vmgi_lba + tt_srpt_ptr`.
- **TT_SRPT**: offset **0** = `nr_of_srpts` (title count, BE u16); offset **8** = first
  `TT_SRP` entry (12 B each), within which offset **6** = `title_set_nr` ⇒ absolute offset
  **14** = title 1's VTS number (1-based). Compared directly against the walk's `vts_num`
  (`VTS_02_1.VOB` ⇒ 2). Cross-checked vs libdvdread `ifo_types.h`.

`VIDEO_TS.IFO`'s LBA is captured during the VIDEO_TS walk (it name-sorts before any
`VTS_xx` VOB). A small per-group table `{vts, base, cnt}` is built alongside the largest-VTS
tracking so selection is a one-cycle-per-group scan for the target VTS. Any parse failure
(no IFO record, `tt_srpt==0`/out of range, `nr_of_srpts==0`, target VTS not present) funnels
to the largest-VTS fallback (`sel_valid=0`, surfaced on `debug_state[13]`).

### PGC / cell timeline (Phase 7) — offsets (IFO fields are BIG-ENDIAN)

After the title VTS is selected, the reader parses that VTS's `VTS_xx_0.IFO` and builds a
**program-order cell list** `{first_sector, last_sector}`, then streams it. The VTS's
`VTS_xx_0.IFO` LBA is captured during the VIDEO_TS walk (a per-VTS `VTS_xx_0.IFO` latch that
name-sorts just before its group's title VOBs, committed to the open group and carried to
the winner as `eff_ifo_lba`).

Chain (each field read via the same **sync-BRAM `parse_buf` → 45-byte `rbuf` shadow** — set
`fetch_base` to the field's byte offset so it lands in `rbuf[0..15]`; positions tracked as
`(2048-sector LBA, 11-bit offset)` pairs to avoid 34-bit byte math):

- **VTSI_MAT** (`VTS_xx_0.IFO` sector 0): `vts_pgcit` **@204 (0xCC)** = BE u32 sector ptr,
  **relative to VTSI start** ⇒ abs LBA = `eff_ifo_lba + vts_pgcit`. (`vtstt_vobs`@196 is
  **not needed** — see the mapping note below.)
- **VTS_PGCIT**: `nr_of_pgci_srp` **@0** (BE u16); SRP[0] **@8** (8 B each), within it
  `pgc_start_byte` **@+4 ⇒ @12** (BE u32, byte offset **relative to VTS_PGCIT start**).
  v1 uses the **first PGC** (PGCN 1); the exact TTN→PGC map is in `VTS_PTT_SRPT` (deferred).
- **PGC** (at `PGCIT_start + pgc_start_byte`): `nr_of_programs`@2 (u8, chapters — deferred),
  `nr_of_cells`@3 (u8), `palette`@164 (16×4 B — the **subtitle palette**, deferred hook for
  the subpicture feature), `program_map_offset`@230 (BE u16, chapters — deferred),
  `cell_playback_offset`@232 (BE u16). All relative to the PGC start.
- **Cell playback info** (24 B/cell, at `PGC_start + cell_playback_offset`): `first_sector`
  **@8** (BE u32), `last_sector` **@20** (BE u32) — both **2048-sector RBNs relative to
  VTSTT_VOBS** (the title VOB start). The cell category word @0 (angles/seamless) is deferred.

**Why `vtstt_vobs` isn't needed (cell → sd_lba mapping).** Cell RBNs are relative to the
start of the title VOBs (`VTS_xx_1.VOB`), and the reader's extent table already holds the
selected group's title VOBs in order — `all_start[eff_base]` **is** `VTS_xx_1.VOB`'s first
sector. So a cell 2048-sector RBN `S` maps to `sd_lba` directly (2048-byte sd blocks, 1:1)
by walking the selected group's extents (`all_start`/`all_blocks`). `S_CELL_SEEK` finds the
extent containing a cell's start; `S_STREAM` (cell branch) crosses extent boundaries as it
streams to `last+1`, then advances to the next cell in table order.

**Per-cell reads.** Each cell's `first_sector` and `last_sector` are read as **two
independent 4-byte field reads** (shadow at `cell_off+8`, then `cell_off+20`), which
sidesteps any 24-byte-entry straddle of a 2048 boundary. Cells cap at `MAXCELL=128`; a
larger count (or a straddling PGC header, bad pointer, `nr_of_cells==0`) funnels to the
linear whole-VTS fallback (which plays everything, just not reordered).

## Block size: 2048-byte sd blocks (1:1 with ISO/DVD sectors)

The sd interface serves **2048-byte blocks** (`hps_io #(.BLKSZ(4))`, `sd_blk_cnt=0`,
`sd_buff_addr[10:0]` = byte offset within the sector). ISO9660/DVD use 2048-byte
logical sectors, so **`sd_lba` IS the logical-sector LBA** and a DVD RBN maps 1:1:

- **Navigation** reads one sector per request into the 2 KB `parse_buf`.
- **Streaming** works purely in 2048-sectors via a small extent table of
  `{start_sector, sector_count}` ranges (`start = ISO_LBA`, `count = ceil(bytes/2048)`),
  so the same engine serves both the ISO title (winner slice of the table) and the
  flat-file fallback (a single `{0, total_sectors}` range).

**Why 2048 and not the original 512 (2026-08-03, `feature/sd-2048-blocks`, PR fj#159):**
v1 used the hps_io default 512-byte blocks (`sd_lba = N*4 .. N*4+3`), i.e. **four
HPS request round-trips per DVD sector**, single-outstanding — a real throughput
ceiling for discs authored near the DVD mux maximum (**Thayer's Quest**, by
pack-SCR scan: VTS_02 averages 9.47 Mbps with minutes pegged at 10.08 Mbps; a
clean-playing MiB/Matrix averages 5.2–5.5 Mbps, p99 ≈ 8–8.5). One request per
sector cuts round-trips 4×; NAS/CIFS benefits equally (fewer, larger reads).
Further headroom if ever needed: `sd_blk_cnt` multi-block requests up to 16 KB
(framework-supported; needs a bigger stream cache to stay ahead).

**⚠ What this did NOT fix (2026-08-04 HW result):** the Thayer ~3 Hz audio
skipping was UNCHANGED by the 4× round-trip cut — **delivery throughput is
exonerated for that symptom** (and note the trap: a low-riding O[2] VBUF bar is
NOT a starvation proof — under the STD/ring backpressure the VBUF parks low in
healthy play too). Measured during the follow-up: Thayer's **audio mux lead is
~33 ms** (audio PTS − pack SCR; normal discs 470–667 ms), its AC-3 is uniform and
CRC-clean, `ps_demux` extraction is byte-identical to ffmpeg on real Thayer VOB
bytes, and the fabric AC-3 decoder decodes the full stream continuously. The
cause was the **menu-VBUF stop-go throttle** (the intro is menu-domain VMGM
PGC 23; `menu_vbuf_throttle` stalled the whole stream on a 384/192 KB
hysteresis ≈ the observed cadence, delivery-independent) — ✅ confirmed by
osd_read (stream halting 1-in-3 100 ms samples, ring pinned at 0) and fixed by
the **menu-audio guard** (`menu_aud_live` gates the throttle while menu audio
flows). Full story: `docs/dvd_menu_refinements.md` §5d amendment.

## FSM

`S_INIT` (fallback immediately if the image is < 17 sectors) → `S_SECREAD` (gather a
2048 sector) → `S_CHK_VD` (scan sectors 16,17,… for the ISO9660 **CD001** signature
and the type-1 **PVD**; **no CD001 ⇒ flat-file fallback**) → `S_WALK_ROOT` (find the
`VIDEO_TS` directory record) → `S_WALK_VTS` (enumerate `VTS_xx_y.VOB`, single pass,
accumulate per-VTS total + a per-group table, keep the largest, latch `VIDEO_TS.IFO`'s LBA)
→ `S_FINALIZE` (close the last group) → **IFO detour** `S_IFO_MAT` (read VMGI sector,
shadow @196) → `S_IFO_MAT_PARSE` (`tt_srpt` ptr → read TT_SRPT sector) → `S_IFO_TSRPT`
(`nr_of_srpts` + title 1 `title_set_nr`) → `S_SELECT` (scan the group table for that VTS) →
**`S_PGC_BEGIN`** (the convergence point for IFO-selected AND largest-VTS-fallback titles).
`S_PGC_BEGIN` starts the **PGC detour** when `eff_ifo_lba != 0`: `S_PGC_MAT` (VTSI_MAT
`vts_pgcit`) → `S_PGC_PGCIT` (`nr_srp` + SRP[0] `pgc_start_byte`) → `S_PGC_HDR`
(`nr_of_cells`) → `S_PGC_HDR2` (`cell_playback_offset`) → per-cell `S_CELL_F`/`S_CELL_L`
(read each cell's first/last, in table order) → `S_PGC_DONE` (arm cell-mode streaming) →
`S_CELL_SEEK` (map cell 0 to an extent) → `S_STREAM` (cell branch). Any PGC parse failure
(no VTSI, bad pointer, `nr_of_cells` 0/>128, straddle) → **`S_FINAL2`** = linear whole-VTS
setup (`cell_mode=0`, latch the winner slice: IFO selection if it matched, else largest-VTS).
`S_STREAM` feeds the chosen sectors into the 16 KB cache (cell-mode = the PGC cell list;
else the winner's extents back to back); output pipeline drains to `stream_data` → `S_DONE`.
`S_ERROR` = ISO9660 present but no playable title (`iso_error`, surfaced for the overlay).

**ISO9660 directory record** fields used (offsets within a record): `[0]` rec_len
(0 ⇒ skip to next 2048 boundary), `[2..5]` extent LBA (LE), `[10..13]` data length
bytes (LE), `[25]` flags (bit1 = directory), `[32]` name_len, `[33..]` name
(`VTS_01_1.VOB;1`). Records never cross a sector boundary; directories can span
several 2048 sectors (walked sector-by-sector). Directory entries are name-sorted,
so VTS groups are contiguous — enabling the single-pass largest-VTS accumulate
(close a group when the VTS number changes; the winner is the max-total group).

## Verification

- `bench/dvd/iso_reader_tb.sv` — synthetic ISO exercising: ISO9660 detect, root
  walk, **multi-sector VIDEO_TS**, **largest-VTS across a sector boundary**,
  menu/`part 0`/`VIDEO_TS.VOB` exclusion, **non-contiguous multi-VOB concat**; and
  the **flat-file fallback** (no CD001 ⇒ whole file linear). Both PASS.
- `bench/dvd/iso_reader_real_tb.sv` — loads the **real** `MEN_IN_BLACK.iso`
  metadata sectors (16 / 261 / 266-268, `bench/dvd/test_vobs/mib_iso_meta.hex`)
  and confirms the RTL selects **VTS_21** (4 extents, first ISO LBA 1683616) on
  real bytes. (The fixture carries no `VIDEO_TS.IFO` sector, so `vmgi_found=0` and the
  reader selects VTS_21 via the largest-VTS fallback — unchanged.) PASS.
- `bench/dvd/iso_reader_ifo_tb.sv` — **IFO title selection.** A synthetic disc where the
  largest VTS and TT_SRPT **disagree** (VTS_03 is biggest, but TT_SRPT title 1 → VTS_01):
  asserts the reader streams **VTS_01** with `sel_valid=1`; a second pass with a malformed
  IFO (`tt_srpt=0`) asserts it **falls back to VTS_03** with `sel_valid=0`. PASS.
- `bench/dvd/iso_reader_pgc_tb.sv` — **PGC cell-timeline.** A synthetic single-VTS disc whose
  PGC has two cells **out of physical order** (cell0 → RBN 2, cell1 → RBN 0) with a third
  sector (RBN 1) referenced by no cell: asserts the reader streams them in **program order**
  (`0xB2` then `0xB0`, skipping `0xB1`), `cell_mode=1`, `cell_count=2`. A second pass with a
  malformed PGC (`vts_pgcit=0`) asserts the **linear fallback** streams the whole VOB
  (`0xB0,0xB1,0xB2`, 6144 B, `cell_mode=0`). PASS.
- `tools/iso_nav_check.py disc.iso` — host-side predictor mirroring the RTL; prints the
  largest-VTS heuristic, the IFO TT_SRPT title-1 VTS, which one the core will play, **and the
  selected title's PGC cell list in program order** (cell first/last RBN = sd_lba-relative sector).
  Use it before a HW test — pick a disc where the largest-VTS and IFO title **disagree**, and
  compare the printed cell order against the on-screen playback.

```
iverilog -g2012 -o /tmp/s dvd/dvd_iso_reader.sv bench/dvd/iso_reader_tb.sv && vvp /tmp/s
iverilog -g2012 -o /tmp/r dvd/dvd_iso_reader.sv bench/dvd/iso_reader_real_tb.sv && vvp /tmp/r
iverilog -g2012 -o /tmp/i dvd/dvd_iso_reader.sv bench/dvd/iso_reader_ifo_tb.sv && vvp /tmp/i
python3 tools/iso_nav_check.py /path/to/disc.iso
```

## HW test plan

1. Put a decrypted DVD ISO on the SD card; run `tools/iso_nav_check.py` on it first
   to note the expected VTS.
2. Select the `.iso` in the file browser → the main feature should play with
   audio/video in sync.
3. Confirm a bare `.VOB`/`.mpg`/`.m2v` still plays (fallback path unchanged).
4. If it stays black on an ISO: the reader may have hit `S_ERROR` (ISO9660 but no
   VIDEO_TS/title) — a follow-up should surface `iso_error`/state on the debug
   overlay (currently the `debug_state`/`debug_iso_*` taps are wired out of the
   instance but not yet placed on an overlay row).

## Transport: gamepad seek + pause (`feature/transport-seek-pause`)

The reader exposes a **cell-granular seek** and the display pipeline a **pause**, both driven
by the gamepad (`joystick_0`, previously wired to `hps_io` but unused). This is the reusable
seek primitive that later unlocks chapters, fast-forward/skip, and menu "play title" — those
all reduce to "jump the reader to a new location and cleanly re-sync the A/V pipeline."
(Sim-verified: `bench/dvd/iso_reader_seek_tb.sv`, `bench/dvd/av_sync_tb.sv` [5a/5b].
✅ HW-proven via the later transport stack — chapters/scrub/HUD/pause all exercised on the
board through PRs fj#96/#101/#103/#106.)

**Seek (reader).** New ports `seek_pulse`/`seek_cell[7:0]` request a jump to a PGC cell;
`seek_ack` pulses when it executes; `cur_cell`/`cell_ready` read back the current cell and
whether cell-mode is active (seek available). A request is **latched** (`seek_pending`) and
executed only at a **block boundary** (`seek_jump = seek_pending && ~blk_inflight`) — the
outstanding `sd` read must finish first, or the framework's remaining beats would land in the
post-seek cache as stale bytes (this bit the first tb pass). The jump itself reuses the exact
cell-load path the streamer already runs on every cell boundary
(`S_CELL_LOAD → S_CELL_LOAD2 → S_CELL_SEEK → S_STREAM`), which re-maps the target cell's
`first_sector` through the extent table to an `sd_lba`; it just points `cell_i`/`cell_raddr`
at the target and clears the cache (`wr_ptr`) + output pipeline (`rd_ptr`). Cell-mode only —
the flat/linear fallback has no cell table, so a seek there is a no-op (also `seek_cell ≥
cell_count` is ignored, no ack). Cells begin on clean GOP/sequence boundaries (DVD authoring),
so the MPEG-2 decoder re-locks on the next sequence header without a decoder reset. Note
`cur_cell` is the **fetch** cursor; on real multi-MB cells it leads the displayed cell by at
most the 16 KB read-ahead cache (a sub-cell fraction), so it tracks what's on screen.

**Seek pipeline flush (emu).** `seek_ack` fires the existing **clip-load flush**
(`load_flush_cnt <= 64`, `pipe_rst_n`) so ps_stream_fifo / ps_demux / ac3_reframer /
audio_ring / dvd_audio_decode / av_sync all reset — clearing stale bytes/PES/audio and forcing
`av_sync` to re-anchor its STC on the new cell's `vid_pts` (re-arms `av_vid_hold` and, via
`pickup_hold`, the governor's `video_live`, so a seek behaves like a cold start). **Critically it
ALSO flushes the decoder's VBUF** (the ~1 s compressed-video cushion in DDR): `seek_ack` arms a
separate seek-only `seek_flush` level, 2-FF synced to `clk_dec` as `mpeg2video.vbuf_flush`, ORed
into the regfile's native `flush_vbuf` (`rtl/mpeg2/mpeg2video.v`). Without it the audio (small
ring) jumps immediately while the video plays the old buffered ~1 s first — the first HW build's
exact symptom. Seek-only; the known-good clip-load path is untouched.

**Pause = freeze video + audio in lock-step.** Video-referenced-STC (master-clock) design; pause
holds *everything* frozen rather than gating the sector feed (the multi-MB VBUF would keep
playing for seconds). Four coordinated holds:
- **Display:** `resample_addrgen.v` `pause` (threaded emu → mpeg2video → resample, 2-FF to
  `clk_dec`) gates `ofv_pickup`/`ofv_paced`/`late_raw` — the governor keeps taking the
  **persistence re-scan** branch (last image re-scans every refresh = steady freeze frame), never
  picks up a new frame, no drop debt.
- **Watchdog suppress:** freezing the governor stalls the decoder (`busy` high), which the decode
  watchdog (`rtl/mpeg2/watchdog.v`) would otherwise reset after ~1 s → the first HW build's black
  screen + resolution popup. The watchdog is fed `repeat_frame=31` (its native freeze-frame
  suppress) while paused, so it never fires.
- **STC:** `av_sync.sv` `pause` holds `stc_acc` + the PI update.
- **Audio:** `dvd_audio_decode.sv` `pause` gates the play-side sample tick
  (`aud_ce_play = aud_ce && drain_en && ~pause`), reusing the drain-hold — the output FIFO read
  pointer freezes and `audio_l/r` hold silence, so on resume audio continues from the same sample
  (no lost audio → no drift from the pause). The ring drain watchdog (`aud_bp_wd`) is frozen too
  so a long pause can't drop frames. (The first HW build froze only display + STC; audio kept
  playing and desync grew with pause length — fixed here.)
Unpause is instant — nothing is reset, only ungated.

**Hold-frame transitions (2026-07-30, ✅ HW-CONFIRMED, PR fj#148):** the STD mux-lead hold
(`av_vid_hold` → `pickup_hold`, armed on every title-domain load/seek/jump until the
audio catches the new STC anchor) now reuses the first three pause holds — pickup
gate, pacing gate (`ofv_paced` via the shared `hold_freeze = pickup_hold &&
~video_live`), late/debt suppress, and the `repeat_frame=31` watchdog suppress — so a
clip/title transition **holds the last frame on screen** instead of the previous
black gap (the hold used to park the governor in `STATE_INIT` = no scans = mixer
black; menus never showed it because the hold is forced off in menu domain). STC and
audio handling remain the hold's own (release on `aud_caught`, 1.24 s fallback).
Detail: `docs/av_sync.md` §v5.2.

**Gamepad map (inline decode in emu).** Rising-edge detected on the held `joystick_0`; buttons
match the `J1,Pause,Prev Chapter,Next Chapter` CONF_STR list: **B1 Pause [4]** = pause toggle;
**B3 [6] / D-pad Right [0]** = next cell (`seek_cell = cur_cell+1`); **B2 [5] / D-pad Left [1]**
= prev cell. Seeking clears pause. A `dvd_nav` module is the right refactor once chapters/FF/menu
land.

## Menu domain + VM jump interface (Phase 2, `feature/menu-domain`)

**Deliverable:** with `O[1] Disc Menus = On`, the **Menu** gamepad button jumps from a
playing title to the disc's authored **VTS root menu** (video/audio/still), and **Menu or
Select** again resumes the title at the saved cell. No button highlights (Phase 3) or nav
command execution (Phase 4) yet — this phase ships the reusable machinery they run on.

### The jump primitive

`jump_pulse` + `{jump_domain, jump_vts, jump_pgcn, jump_entry, jump_cell}` → `jump_ack`
(pulse, same block-boundary + flush contract as the transport seek: emu ORs it into
`load_flush` **and** `vbuf_flush`), then `pgc_loaded` (parsed + streaming) or `pgc_error`
(menu jump failed; emu runs a fallback chain). Domains follow the DVD-VM encoding:

| domain | meaning | PGC source | cells map into |
|---|---|---|---|
| 0 FP   | First Play PGC | VMGI@132 (BYTE offset) | none (commands only → `S_DONE`) |
| 1 VMGM | VMG menu | VMGI@200 PGCI_UT (sector) | `VIDEO_TS.VOB` |
| 2 VTSM | VTS menu | VTSI@208 PGCI_UT (sector) | `VTS_xx_0.VOB` |
| 3 TT   | title | VTSI@204 VTS_PGCIT | title VOBs via the extent table |

`jump_pgcn` picks `SRP[pgcn−1]`; `pgcn==0` = scan for `jump_entry` (SRP `entry_id`
bit7 set + low nibble match: VMGM 2=Title; VTSM 3=Root 4=SubPic 5=Audio 6=Angle
7=Chapter; no match → SRP[0]). `jump_cell` = start cell (TT resume). Jumps are latched
any time after the VIDEO_TS walk (`nav_ready`) and execute only from a settled state
(`S_STREAM`/`S_DONE`/`S_STILL`) at a block boundary — never mid-parse.

### Generalized PGCIT walk + the sector-crossing walker

`(pit_sec, pit_off)` hold the ACTIVE PGCIT — title (sector-aligned) or menu (byte offset
via the `PGCI_UT` language-unit walk — Phase 4: match SPRM0 'en' against each LU's
lang_code, LU[0] fallback (libdvdnav `get_MENU_PGCIT`); single-LU takes LU[0]
directly, bit-identical to v1) — and persist
while the domain is loaded, so PGC→PGC moves (LinkPGCN follow, `next_pgcn`) re-enter at
`S_SRP_FETCH` without re-walking the IFO. The mount path routes through the same states
(`want_pgcn=1`), so there is exactly one PGC parser.

Everything inside a PGC is read by a **sector-crossing byte walker** (`S_WALK_RD`/
`S_WALK_CAP`, 2 cycles/byte; refills `parse_buf` via `pb_sec` tracking whenever the walk
leaves the resident sector). It walks, in order: the header window @156..233
(`next/prev/goup_pgcn`, `pg_playback_mode`@162, **`still_time`@163**, **palette@164** →
`pgc_palette`, `command_tbl`@228, `cell_playback`@232), the **whole command table**
(counts + pre|post|cell commands, streamed byte-wise on `cmd_we/cmd_waddr/cmd_wdata` —
the Phase-4 VM BRAM write format, frozen now), and the **cell playback table** (cell
BRAMs; the meta BRAM adds `{still_time@2, cell_cmd_nr@3}` per cell). This retires the
Phase-1 "skip palette when the PGC straddles a sector" limitation — Matrix and T2 menu
PGCITs straddle routinely (verified with `tools/iso_nav_check.py`).

### Sector-straddle audit (`feature/straddle-audit-symptom1`)

The walker above handles everything read *inside* a PGC (from byte @156 on). But the
reader also reads a set of multi-byte IFO fields through the **45-byte `rbuf` shadow**
(`S_FETCH` copies `parse_buf[fetch_base .. +44]` → `rbuf`, all field taps read `rbuf`).
The shadow used to **wrap** a byte past offset 2047 to `parse_buf[0]` (garbage). For any
field read at an *arbitrary* byte offset that lands across the 2047 boundary, that
mis-reads. The at-risk shadow reads (offset is arbitrary, field spans > the bytes left in
the sector):

- **SRP `srp_pgc_start`@+4..+7** (`S_SRP_EVAL`) — *positions the PGC*. The SRP table lives
  at `LU[0].lang_start_byte`, not necessarily 8-aligned, so an SRP entry can straddle. A
  mis-read `pgc_start` puts the PGC at a garbage `pgc_off` → wrong `nr_of_cells`/`pgc_error`
  (a **symptom-1-class dead-end**).
- **PGC header pre-walk bytes** `nr_of_programs`@2 / `nr_of_cells`@3 / `playback_time`@4-7
  (`S_PGC_HDR`, `fetch_base=pgc_off`) — a menu PGC whose header starts in the last few
  bytes of a sector. Previously guarded by a `pgc_off > 2044 → pgc_error/linear-fallback`
  **give-up guard** (this is what forced Atmosfear PGC13 at the exact 2044 boundary to be
  fixed once already, ca6f4f6/4f2f5d3).
- **`VTS_PTT_SRPT` / `TT_SRP` entry reads** (`S_PTT_OFF`, `S_PTTLD_OFF`, `S_PTT_PGC`,
  `S_TT_RES2`) — u32/u16 fields at arbitrary offsets, same shape.

**Fix — sector-crossing shadow fetch** (`fetch_xw`/`fetch_cross`/`fi_save`): when a copied
byte index `fetch_base+fi` runs past 2047, `S_FETCH` refills `parse_buf` with `sec_lba+1`
and resumes the same fetch reading the wrapped bytes at `fetch_base+fi-2048` (`FETCH_N`=45
< 2048 ⇒ a shadow spans at most two sectors). This makes **every** rbuf-shadow field read
straddle-safe, so the `S_PGC_HDR` give-up guard is **retired** (a menu PGC at `pgc_off`
2045-2047 now parses). Directory-record shadow reads were already safe (ISO9660 forbids a
record crossing a sector + the `rec_ok` `p+rec_len ≤ sec_bytes` check).

**Symptom-1 (Trivial Pursuit Star Wars) is NOT a straddle.** Ground truth
(`tools/dvd_vm_ref.py` `IsoNav` + `tools/bin/trace_nav`, absolute-byte reads) shows the
0-cell command stubs the notes suspected (VTSM PGC27 `nr_pre=16`, VMGM PGC1 `nr_pre=4`) sit
**mid-sector** — their command tables and SRP entries do not straddle, and the walker reads
them correctly. `tools/straddle_check.py` (which now also enumerates the **SRP table**)
finds **no** straddle of any class on any test ISO (TP_SW 1/2, Atmosfear, MiB, Matrix, T2,
Scene It, Paw Patrol). So the sector-crossing fetch above is **latent-bug hardening** proven
by synthetic sim (`bench/dvd/iso_reader_straddle_tb.sv`: an SRP entry and a PGC header
placed across 2047 — fails on the pre-fix reader, passes on the fixed one), *not* the
symptom-1 root cause.

**Where symptom-1 actually is (pinned, not a straddle, not the reader parse).** HW
`DEBUG_OVERLAY` row 24 `{deadend_vts, deadend_pgcn}` read **`{1, 1}`**, sticky from **boot**
(latched while the question was already playing). Ground truth: the only menu PGCN-1 stubs on
the disc are **VMGM PGC1** (0 cells, `nr_pre=4`, off 88) and **VTSM_01 PGC1** (Root, 0 cells,
`nr_pre=13`, off 248) — both **mid-sector** and both with **real PRE commands** (there is *no*
genuinely 0-cell/0-pre menu PGC on the disc). A real-data reproduction
(`bench/dvd/iso_reader_tpsw_tb.sv`, fixture `test_vobs/tpsw_vtsm_meta.hex` = the actual TP_SW
VTSM sectors) drives a VTSM-Root jump straight at the reader and it delivers **`cmd_nr_pre=13`
correctly** (104 command bytes streamed). `emu.sv` wires `cmd_nr_pre → dvd_vm.nr_pre` as a
plain wire (no stale register). And `trace_nav`/`trace_boot` show libdvdnav's boot goes First
Play → title → **button-armed menus (PARK #1–7)**, never a PGCN-1 dead-end. Conclusion: the
`nr_pre=0` comes from **our VM's boot NAVIGATION reaching menu PGCN 1** (where libdvdnav does
not) via a load path that drops `nr_pre` — a `dvd_vm.sv`/`emu.sv` boot-nav divergence, **not
the reader's PGC parse and not a straddle**. Next step: trace the VM boot on real data (VM +
reader together) to find how it lands on PGCN 1.

**RESOLVED — it's a benign PRE fall-through, and TP_SW plays correctly.** The `{1,1}` latch
comes from `dvd_vm.sv`'s **`V_NEXT` BLK_PRE fall-through** site, NOT the `nr_pre==0` sites (the
"its nr_pre arrived as 0" comment there was a red herring — corrected in-code). TP_SW has **18
titles all in VTS_01**, and **VTSM Root PGC1** is a title dispatcher: `g15 = TTN(SPRM4);
if(g15==2) LinkPGCN 6 … if(g15>=0xc) LinkPGCN 26` — with **no case for TTN=1**. When the VM
reaches Root while still in the boot intro's **TTN=1** context, all 13 PRE run, none link, 0
cells → the fall-through fires and latches `{vts1, pgcn1}`. Golden-model proof:
`eval_block(Root PRE, SPRM4=1) = None`; `SPRM4=2 → LinkPGCN 6`, `5 → 12`, `12 → 26`. The reader
delivers the real `nr_pre=13` correctly. This is **expected disc authoring** (the Root menu has
no submenu for the intro title), and **PR fj#142's recover-to-a-menu is the correct response** —
confirmed on HW: the game plays fine, a question returns to the menu. No fix needed; the row-24
diagnostic simply fires on this legitimate fall-through. **The symptom-1 investigation is
CLOSED** (original "question → copyright" fixed by PR fj#142; residual `{1,1}` understood + benign;
the straddle audit hardened a real latent class and exonerated the reader).

### What the real discs taught us (drove the design)

- **MiB's Root entry PGC has 0 cells** — it is a command stub ending in an unconditional
  `LinkPGCN` to the real, displayable menu PGC. The reader watches PRE commands for
  `LinkPGCN` (byte0=0x20, byte1 low nibble=4; unconditional = compare op bits [6:4]==0,
  preferred over conditional) and **follows it when a menu PGC has no cells**, depth ≤2.
  Matrix/T2 root menus have cells directly (no follow needed).
- **Menu stills are CELL-level** (`cell still_time = 0xFF` on the hold cell; PGC-level
  `still_time` was 0 on all three discs). At any menu cell end with nonzero still the
  reader **drains the stream cache first** (so the authored still frame actually reaches
  the decoder — flushing eagerly would truncate the tail, caught by
  `iso_reader_menu_tb` TEST 4) and parks in `S_STILL`. v1 holds indefinitely (timed
  stills = Phase 5); any jump/seek exits.
- **Menu PGC end policy (no VM yet):** PGC `still_time` → hold; authored `next_pgcn` →
  drain, flush (`seek_ack`), re-enter the PGCIT at that PGC; neither → **hold the last
  frame** (a menu must never black-screen or fall off the end).

### Menu-transition VBUF hold (`keep_vbuf`, Phase-5)

The seek/jump **flush contract** has a third flavour. A **menu→menu** transition (a
LinkPGN transition-cell seek, a LinkPGCN menu jump, or an authored next_pgcn/POST
advance while `menu_dom`) sets the reader output **`keep_vbuf=1`** on its
`seek_ack`/`jump_ack` cycle, and emu then pulses **only `load_flush`, not `vbuf_flush`**.
So the decoder keeps its compressed-video buffer and **plays out the authored transition
animation** instead of cold-restarting on a stale persistence frame. `load_flush` still
resets ps_demux / nav_pci / av_sync (old highlight disarms, STC re-anchors) and does NOT
reset the decoder (`mpeg2video.rst = reset_n`). Title/gamepad transport seeks,
menu→title (Play), title→menu (Menu key) and FP/auto boot keep `keep_vbuf=0` → the VBUF
flushes (A/V-sync critical). This is the fix for the T2 "offset highlight / frozen
transition" — see `docs/dvd_menu_refinements.md` §2.

### Natural-transition tail drain (title-domain PGC end waits for `vbuf_empty`) — ✅ HW-CONFIRMED 2026-07-30 (user report, PR fj#149)

The `keep_vbuf` table above is decided purely by *domain*, never by *who initiated* the
transition — and that cut the end off NATURAL title-domain transitions (First Play logo
chains: logo PGC ends → POST → `JumpSS`/`JumpTT`/`LinkPGCN` with `keep_vbuf=0` →
`vbuf_flush` discards the decoder's ~1 s buffered tail; since the hold-frame work
(PR fj#148) it read as "freeze ~1 s early, then cut" instead of a black gap). The reader's
"drain-first" discipline only drained its own 16 KB stream cache — the *decoder* was
still ~1 s behind.

Fix (2026-07-30): the PGC-end dispatch gate in `S_STREAM` gains a **`tail_wait`** term —
when the ended PGC is **title-domain** (`~menu_dom`), the reader also waits for
**`vbuf_empty`** (the HW-proven menu-still cold-re-decode trigger: compressed VBUF fill
≤ 8 KB = tail displayed to within tens of ms) before pulsing `vm_pgc_end` (or the vm-off
`adv_pend`/still settle). The POST then genuinely runs against the played-out picture,
and its jump's flush hits an empty buffer (A/V re-anchor semantics preserved). Detail:

- **One wait point.** Gating the *dispatch* (not `jump_go`) covers every natural path in
  one place — last-cell PGC end, the angle-block PGC end, the `vmw_last` re-entry, the
  POST fall-through `next_pgcn` (which never goes through `jump_go`), and (routed through
  the same gate now) the timed-still `STILL_PGEND` timeout.
- **User actions stay immediate by construction.** During the wait the reader sits in
  `S_STREAM`, so a VM jump (Menu key, button) hits `jump_go` at once and clears
  `vmw_pgc_pend`; a transport seek likewise. Menu-domain PGC ends bypass the wait
  entirely (their tail rides `keep_vbuf`; menus stay snappy).
- **`DRAIN_WD` watchdog (60 s, module parameter — `dvd_iso_reader.sv:78`; was ~5 s, widened for Weakest Link's 17 s answer cell).** A wedged/never-draining decoder
  degrades to the old dispatch-with-flush behaviour instead of parking the transition.
  Very-low-bitrate tails > 5 s truncate at the bound — still strictly better than before.
- **No decoder-watchdog suppression needed — and it must NOT be added.** The decoder
  watchdog only runs while the decoder is *busy* (input FIFO backpressured,
  `rtl/mpeg2/watchdog.v` `decoder_active <= ~busy`); a draining/starving decoder never
  trips it (a finished title already parks in `S_DONE` starving indefinitely). Wiring
  `freeze_wd` here would force `repeat_frame=31` and *freeze the display* — the tail
  would not play.
- **Hold-frame composes.** The tail plays to its true final frame, the decoder starves
  briefly, the jump's `load_flush` re-arms `pickup_hold` → the *true* last frame holds
  through the transition (not a mid-clip freeze).
- **Phase B — cell-command jump/seek tail drain — ✅ HW-CONFIRMED 2026-07-31 (user
  report, PR fj#150; round 2, the `nat_src` build `DVD_taildrainB2`: Tomb Raider Select
  scene-skip immediate again, Thayer unchanged/no issues).** Title-domain
  **cell-command** verdicts that are a JUMP or
  SEEK (e.g. Thayer's Quest FMV branch points — `LinkTailPGC`/`LinkPGCN` at a choice
  cell) used to execute immediately with `keep_vbuf=0`, flushing the decoder's ~1 s
  buffered tail — the same cut this section fixed for PGC ends. The *dispatch* stays
  ungated (a mid-title GPRM cell command's `vm_adv` verdict must not hitch playback);
  instead the resulting jump/seek **execution** is gated:
  - `dvd_vm.sv` exports **`vm_from_wait = wait_verdict && nat_src`**, sampled on the
    `jump_pulse`/`seek_pulse` cycle. `wait_verdict` = the executing block is
    CELL/POST; **`nat_src`** = the chain was *started* by a reader wait event
    (`ev_cellcmd`/`ev_pgcend` set it; every user/boot/load dispatch — button, Menu
    key, Resume, boot, error fallback, PRE run — clears it), and it is preserved
    across block transitions. **`nat_src` is load-bearing, not hygiene** (HW round 1,
    2026-07-30): Tomb Raider's Select scene-skip buttons are `LinkTailPGC` → the
    button dispatches the POST, whose jump reads `blk=BLK_POST` — with blk-only
    provenance that jump was tagged natural and tail-drain-gated, so the skip waited
    out the whole VBUF (VLC skips instantly). A POST reached via a button keeps
    `nat_src=0` → immediate; the same POST reached from a PGC end is natural. The
    V_IDLE event arms additionally set **`blk <= BLK_BTN`** (belt and braces against
    stale-blk misclassification). `dvd_vm_tb` S15 covers the truth table incl. the
    stale-blk case and the button-TailPGC→POST (TR) + PGC-end→POST control pair.
  - `emu.sv` threads it: reader `jump_natural = vm_from_wait` (all jumps are VM-issued);
    for the shared seek port `seek_natural = vm_seek_pulse & vm_from_wait` so a
    coincident gamepad seek is never tagged natural.
  - `dvd_iso_reader.sv` latches **`jnat_l`/`snat_l`** with the request (qualified
    `~menu_dom` — menu tails ride `keep_vbuf`), and `jump_go`/`seek_jump` gain
    `(~nat || vbuf_empty || drain_wd_hit)`. The **`DRAIN_WD` watchdog is shared**: its
    enable extends to the pending-natural-jump/seek window (a natural jump chained
    after a watchdog-released dispatch re-arms the bound — worst case 2×`DRAIN_WD`
    on a wedged decoder, still strictly bounded). Two interaction fixes: (a)
    **`vmw_tmr` freezes** in `S_VM_WAIT` while a natural jump/seek is pending-and-
    gated (else the 0.62 s fallthrough fires a spurious advance under the pending
    jump); (b) `seek_jump` gains **`~jump_pending`** — the pending-jump window
    widened from ~µs to seconds, so "jump outranks seek" is now explicit.
  - The VM side needs the mirror-image freeze: the reader exports **`nat_wait_o`**
    (natural jump/seek latched and gated) → `dvd_vm.wait_hold`, freezing the
    **V_WAIT give-up timer** (~0.62 s < the gate window; an early give-up would
    clear `skip_pre` and strand `tt_resolve` → wrong-PRE / stale-SPRM5 corruption).
    It drops the moment the jump executes or watchdog-releases, so the guard
    against a never-latched jump is preserved.
  - User actions stay immediate: button/Menu/Resume/boot jumps — and every jump a
    button-started chain produces, incl. through `LinkTailPGC`→POST — sample
    `vm_from_wait=0`; gamepad seeks/scrubs/chapter skips latch `snat_l=0`. Timed-
    still branch commands (the common Thayer case) hit the gate with the VBUF
    already drained by the still park, so they release instantly — which is also
    why Thayer's Quest shows no visible change from Phase B (its choice cells are
    stilled; the gate matters only for branch cells authored WITHOUT a still).

Tests: `iso_reader_vm_tb` T6 (hold while `!vbuf_empty` → release → POST, `keep_vbuf=0`
on the ack), T7 (Menu key mid-hold → immediate jump, POST never runs), T8 (`DRAIN_WD`
bound releases — now the chained 2× case: dispatch bound + the POST jump's own gate),
T9 (Phase B: button jump immediate under `!vbuf_empty`; natural cell-cmd `LinkPGCN`
verdict gated, `nat_wait_o` high, `vmw_tmr` + VM `wait_tmr` frozen, no spurious
advance, release on `vbuf_empty`); `dvd_vm_tb` S15 (`vm_from_wait` provenance truth
table). TBs not testing the wait tie `.vbuf_empty(1'b1)` (= "always drained",
bit-exact pre-drain timing) and `.jump_natural/.seek_natural(1'b0)` /
`.wait_hold(1'b0)`.

> **Quirk RETIRED (fixed on `feature/zero-cell-robustness`, the Hobbit boot-loop
> PR):** a title entered via `JumpTT` leaves `vm_vts = 0`, so a title POST's
> `JumpSS_VTSM` with vts field 0 ("current VTS") used to ship `jump_vts = 0` →
> `pgc_error` → a fallback-chain title replay before the menu. The vts==0
> fallback now resolves through `link_jump_vts` (title → `cur_vts`, menu →
> `vm_vts` — the domain-dependent "current VTS" rule), so the POST lands on the
> menu directly. `iso_reader_vm_tb`'s fixture was updated in the same change —
> its 2-sector title had silently RELIED on the quirk's fallback replay to still
> be "in the title" when T2 pressed the Menu key.

### The still ≠ pause distinction (emu side)

A menu still is an **end-of-stream hold**, not a mid-stream freeze: the decoder must
play out its ~1 s buffered tail (which *ends on* the authored still frame) and then
starve gracefully. So `still_active` drives **only** a watchdog suppress
(`mpeg2video.freeze_wd` → `repeat_frame=31` mux, 2-FF into clk_dec) — NOT the 4-hold
pause set. The governor keeps running (display naturally re-scans the last decoded
frame once nothing new decodes); the drop-debt controller already ignores starvation
lates (`bitstream_ok` gate); audio drains to natural silence; av_sync re-anchors on the
exit jump's `load_flush`. Freezing the governor at `still_active` would hold a frame ~1 s
too early — the transport-seek VBUF lesson in reverse.

A menu still's displayed frame is decoded MID-STREAM (entered via a keep_vbuf transition,
so with stale references) and would show PIXELATED if merely held. So on a still the reader
**cold re-decodes** the still cell (flush + re-stream from its sequence header = a clean
I-frame). Trigger: `menu_snap` (P1O[18] Snappy → immediately, the deep-flush already emptied
the buffer) or `vbuf_empty` (Smooth → after the authored transition drains). Full rationale:
`docs/dvd_menu_refinements.md` §5/§5c. (A trailing-byte "flush primer" that avoided the
re-decode was tried and HW-reverted — it flushed a *corrupt* mid-stream frame; see §5b.)

### Title-domain finite stills — FMV-game timed choices (`feature/title-domain-timed-still`)

FMV-game discs (RDI's **Thayer's Quest**, the LaserDisc-era quick-time genre) author a
**timed choice** as a **title-domain** cell that carries an explicit `still_time` (4/5/10 s)
**and** a `cell_cmd_nr`:

1. the cell plays its "approach" video, then
2. **freezes the last frame for `still_time`** while a **forever HLI** (`hli_e_ptm=0xFFFFFFFF`,
   `fosl` force-select) keeps the on-screen buttons armed, and
3. on **timeout** runs the cell command — the "you weren't fast enough / lose a life" branch.
   A left/right press during the hold fires that button's `LinkTailPGC` and branches early.

Confirmed on the real disc (`tools/nav_extract.py --title-vob` + the `trace_nav` oracle):
e.g. **VTS_02 PGC1 cell 1 = `still_time=4 s`, `cell_cmd_nr=3`**; a 2-button forever-HLI
(left x72..280 / right x408..633); the door subpicture is **FSTA_DSP-only, `SET_CONTR 0000`**
(fully transparent — the visible graphic is the HLI recolour, same as a menu). Nearly every
VTS on the disc carries such cells (still 4/5/10 s + cmd).

**Bug (pre-fix):** the reader's timed-still hold (Phase 5) was **`menu_dom`-only**, so a
title choice cell fell through to the `vm_mode && cell_cmd_nr` branch and ran the timeout
command **instantly** — no selection window. And because the parse front never parked, the
door subpicture was **overwritten by the next cell's SPU ~1 s before the display caught up**
(VBUF lag; `spu_decode` commits one slot at the parse front, no PTS scheduling) → the
"options flash for one frame" symptom. Both symptoms share one cause.

**Fix:** widen the timed-still gate from `menu_dom` to **`(menu_dom || vm_mode)`**
(`dvd/dvd_iso_reader.sv`, S_STREAM cell-end). The existing hold/1 Hz-countdown/`STILL_CMD`
machinery + `nav_pci`'s forever-HLI arming already do the rest; parking the parse front also
stops the SPU from being overwritten, so the highlight persists through the hold. Gated on
`vm_mode` (Disc Menus **on**) — menus-off title playback advances exactly as before, and
libdvdnav honours the same finite title stills. Sim: `bench/dvd/iso_reader_titlestill_tb.sv`
(reader + `dvd_vm`: a title cell with `still=3 s + cmd` HOLDS, no premature command, then runs
the cell command on timeout). **✅ HW-CONFIRMED (2026-07-29, PR fj#144).** Watch on HW: (a) the `eff_still`
heuristic (`vm.c` playback-time rule) can now mark a *heuristic* (implicit) still on a short
single-VOBU title cell under `vm_mode` — matches libdvdnav, but verify normal FMV clips don't
falsely freeze; (b) the frozen choice frame is decoded warm (just-played), so no menu-style
cold re-decode is applied — confirm it isn't pixelated. **✅ ANSWERED 2026-08-26: it WAS
pixelated, but the cause was not the warm decode** — it was the `motcomp_picbuf.v` sequence-end
slot alias (the decoder writing into the slot being scanned out). Fixed in
`rtl/mpeg2/motcomp_picbuf.v`; see `docs/dvd_menu_refinements.md` §5. The `menu_dom`-only gate on
the cold re-decode remains a separate, deliberate open item.

### Proto-nav glue (emu.sv, replaced by the VM in Phase 4)

`J1,Pause,Prev Chapter,Next Chapter,Select,Menu` (buttons = `joystick_0[4..8]`).
Menu during a title: save `{rsm_vts=cur_vts, rsm_cell=cur_cell}` → jump
`{VTSM, cur_vts, entry=3}`. Menu/Select during a menu: jump `{TT, rsm_vts,
jump_cell=rsm_cell}`. D-pad cell seeks are disabled while `menu_active` (the D-pad
becomes button nav in Phase 3).

**Fallback chain (HW round 1 lesson, MiB):** `pgc_error` chains
**own VTSM → VTSM of the VTS with the LARGEST menu VOB (`best_menu_vts`, tracked in
the walk) → VMGM (entry 2) → title resume.** Why the second hop exists: on VM-heavy
discs the feature VTS's root entry is a 0-cell **JumpSS trampoline** with no LinkPGCN
(MiB VTS_21 root sets `g14=0x3500` then `JumpSS VMGM pgc 1`; the VMGM dispatcher PGC
reads `g14` and bounces to `JumpSS VTSM (vts 2, menu 3)` — pure VM execution). The
real menu invariably lives in the VTS with the big menu VOB (MiB: VTS_02_0.VOB =
261 MB vs 32 KB for VTS_21's), and ITS root entry is a plain LinkPGCN stub the reader
can follow. Round-1 HW proved the old chain's VMGM landing plays MiB's VMGM PGC1
cells = authored black filler (a real player never displays them — its pre-commands
always jump away) → silent black screen. Heuristic until Phase 4 executes the
trampoline for real.

### Verification

`bench/dvd/iso_reader_menu_tb.sv`: mount regression through the generalized path, VTSM
Root jump → 0-cell stub → LinkPGCN follow into a PGC that **straddles a sector**
(walker crossing + its palette), menu streaming + cell still, TT resume at `jump_cell`,
VMGM jump + `next_pgcn` follow (drain-first), FP command-only parse, `pgc_error` on a
bad VTS. All pre-existing reader tbs (`iso_reader_{tb,real,ifo,pgc,seek}_tb`) and the
real-VOB `ps_chain_tb` stay green. Menu structures of MEN_IN_BLACK / THE_MATRIX /
ULTIMATE_T2 dumped + eyeballed via the extended `iso_nav_check.py` (whose `decode_vmcmd`
is now a faithful libdvdnav `vmcmd.c` port — the old ad-hoc decoder had JumpTT/JumpSS
op codes swapped).

### Phase-2 limitations (by design; HW round 1 confirmed)

- Menu **buttons don't render or act** yet. Toggling `O[15]` Subtitle on a menu shows
  NOTHING on real discs (HW round 1, Matrix): button subpictures are authored with
  default contrast/alpha = 0 — they only become visible through the HLI highlight
  colours (`btn_coli`), which is exactly Phase 3. `spu_decode` already honours
  FSTA_DSP, so this is data, not a decode gap. Menus with intro cells play them
  through (a real player's cell commands would skip — Phase 4).
- **Menu aspect ratio switches to 4:3** while a menu plays (HW round 1, Matrix):
  correct behaviour — menu VOBs are authored 4:3 and `Aspect Ratio Auto` follows the
  sequence header; it switches back on resume.
- Command tables stream to `cmd_we` but nothing consumes them yet (VM BRAM = Phase 4);
  the emu ports dangle so Quartus prunes the generators until then.
- ~~LU[0] is used unconditionally~~ RETIRED (spec-hardening Phase 4, `feature/lu-selection`):
  multi-LU UTs are language-matched ('en', LU[0] fallback). Timed stills
  and menu audio during stills = Phase 5.
- A PGC whose in-sector offset > 2043 can't read `nr_of_cells` (rbuf window) — bails to
  linear/`pgc_error`. The walker removed every other straddle case.

## Menu buttons: PCI/HLI + highlight + gamepad nav (Phase 3, `feature/menu-buttons`)

**Deliverable:** with a menu up, the authored button highlight renders, the D-pad walks
the disc's button link graph, Select activates (ACT-colour flash + the micro-bridge
executes the two commands real menus actually use), and the menu **loops its
interactive cell** instead of falling off the end.

- **`ps_demux`**: `private_stream_2` (0xBF) has SYSTEM-stream syntax (no PES optional
  header). With `pci_enable` (= O[1]) the substream-0x00 payload forwards on
  `pci_byte/valid/frame_start` (accept-always); DSI/others stay skip-by-length. The
  00 00 01 desync trap inside PCI payloads is covered by `ps_demux_ps2_tb` (plus a
  byte-exact real-NAV-sector check).
- **`dvd/nav_pci.sv`**: double-buffered sync BRAM holds HLI bytes 0x60..0x315; commit
  honours `hli_ss` (1 = new → selection resets to `fosl_btnn`/1, `foac` forced-activate;
  2/3 keep selection; 0 disarms). A fetch sequencer pulls the selected button's 18-byte
  record + its colour group's {sel, act} words into REGISTERS. D-pad pulses walk
  up/dn/lf/rt links (0/out-of-range = stay); activation pulses `btn_cmd[63:0]` and
  flashes the ACT colour ~0.6 s; `auto_action` buttons activate on arrival-by-nav. Arm
  window = 32-bit 90 kHz STC compare (`hli_e_ptm` 0xFFFFFFFF = forever; Matrix's menus
  have FINITE windows, honoured). Verified against real MiB NAV sectors
  (`bench/dvd/nav_pci_tb.sv` + `tools/nav_extract.py`, the golden PCI/HLI decoder).
  - **Forever-HLI disarm immunity** (T2 boot menu, `docs/dvd_menu_refinements.md` §8): a
    scheduled `ss=0` disarm (`off_v`) parked by a *preceding* animation cell must not tear
    down a highlight the disc authored `hli_e_ptm == 0xFFFFFFFF`. On an indefinite still the
    STC keeps advancing (we don't freeze it) and would cross that stale off time ~10 s in,
    killing a "forever" highlight (then Select mis-routed to resume → menu restarted). Fix:
    capture `h_forever` from the committed `e_ptm` and gate `off_due &= !(armed && h_forever)`.
    Finite windows still disarm; only an already-armed forever HLI is immune. Tests: `nav_pci_tb`
    T8 (survives) + T9 (finite still disarms).
- **Highlight render (emu)**: inside the selected rect, the subpicture pixel class takes
  the HLI colour word's palette index + alpha (`[Ci3..Ci0 A3..A0]` nibbles - order
  verified on-disc) instead of the SPU's SET_COLOR/SET_CONTR, through the same
  `pgc_palette` -> `subpic_blend` pipeline. That's how authored buttons (default alpha
  0 = invisible - the Phase-2 HW observation) light up. `spu_decode` is force-enabled
  while a menu is up regardless of the O[15] subtitle toggle. Hotspot discipline kept:
  register-fed comparators/muxes only, `hl_hit_q` aligned to `sp_q_idx`.
- **Cell-loop heuristic (reader)**: a menu cell ending with `cell_cmd_nr != 0` while
  buttons are armed REPLAYS (no flush; clean GOP, av_sync re-anchors). This is what the
  authored cell-command loop does (MiB's interactive screen is mid-PGC cell 1 with a
  LinkTailPGC-class cell command; Phase-2 fell through to a degenerate 1-button still).
  A button activation or the Menu key escapes.
- **Micro-bridge (emu, replaced by the Phase-4 VM)**: `LinkPGCN n` → menu-domain jump to
  PGC n of the CURRENT menu PGCIT (MiB submenus 6..9, Matrix audio/scene menus);
  `LinkTailPGC` → title resume (the tail/post commands almost always launch the
  feature). Conditional-LinkPGCN compares are ignored (approximation). Everything else
  (SetGPRM combos, JumpSS, JumpTT) = flash only until the VM.
- **Input map**: in a button-armed menu the D-pad = button nav and Select = activate;
  otherwise Select = resume (Menu always resumes). Title transport is unchanged.
- **Button groups by display mode (spec-hardening Phase 3, PR fj#168, ✅ HW-CONFIRMED
  2026-08-19)**: the v1 "group 1 only" limit is closed. A disc authors 1..3 button-record
  groups (`hl_gi.btngr_ns`, 36/18/12 records each) tagged by `btngrX_dsp_ty` (3-bit:
  000=4:3-normal, bit0=wide, bit1=letterbox, bit2=pan&scan). The Phase-1 library audit
  measured `btngr_ns=2` on **230/302 discs** — anamorphic menus author group 1 = wide
  rects, group 2 = letterbox (or pan&scan) rects, so group-1-always drew wide rects
  over a letterboxed picture. `nav_pci` now captures `btngr_ns` + the three dsp_ty
  fields through the pending→committed path and offsets the button-record base to the
  FIRST group matching the display verdict (`disp_wide` = emu `ar_wide_auto_eff`,
  menu V_ATR aware; `disp_mode` = emu `sp_disp_mode` — the same signals as the PR fj#115
  subpicture substream map). Group 1 is the fallback (bit-identical for `btngr_ns==1`
  and for 4:3-only group sets); a mode change while armed auto-refetches the current
  button from the new group (selection persists; links/commands are authored identical
  across groups — only the rects move). **★ HW ROUND 1 (2026-08-18, T2/MiB
  screenshots): the group must pair with the RENDERED SUBPICTURE VARIANT, not the raw
  display mode.** Display-space button groups are authored for players that composite
  the highlight at DISPLAY resolution (after letterbox/crop); this core composites
  subpicture+highlight in SOURCE space and scales the composite, so the aspect
  transform already lands on the highlight — feeding the raw display verdict applied
  it twice (T2 Letterbox split its group-2 rects across two options; MiB Crop split
  via its pan&scan group; every breakage was exactly a non-group-1 pick, and the
  pre-Phase-3 group-1-always behavior had been HW-correct on these menus for the same
  reason). emu therefore forces the wide verdict (→ group 1/fallback) for MENU-domain
  highlights (menus force subpicture stream 0 = source-space art; same term as
  `sp_track_eff`, without `force_43_subp`) and passes `sp_disp_mode` only for
  IN-TITLE highlights, whose art is the PR fj#115 mode-mapped substream variant — art
  and rects stay a consistent pair in both cases. This is also WHY libdvdnav gets
  away with reading `btnit[button-1]` unconditionally: for any composite-then-scale
  pipeline, group 1 is geometrically right; the multi-group machinery only serves
  display-resolution compositors (set-top players). Tests: `nav_pci_tb` T11–T15 on a real T2 2-group fixture
  (`test_vobs/t2_menu_2grp.hex`, VTSM RBN 8449: group 2 = the ¾+60 letterbox remap of
  group 1). Still deferred: `btn_se_e_ptm` auto-deselect + CHG_COLCON, JumpTT
  unresolved (needs TT_SRPT-at-jump; Phase 4/6).

### Numpad input: keyboard digit = select+activate — ✅ HW-CONFIRMED (PR fj#134)

The DVD-remote **number-key shortcut**: with a menu HLI armed, pressing a keyboard
digit forces the selection to that button **and activates it in one keypress**
(chapter-select menus; hidden auto-action easter-egg buttons like T2 `82997`, RotS
`1138`, entered as a chain of single-digit activations). Both the numeric keypad and
the top-row digits are accepted; `0` → button 10 (remote convention). **✅ HW-CONFIRMED:
the T2 `82997` menu easter egg unlocks via the keyboard numpad** — end-to-end proof of
the multi-digit egg-code chain (per-digit hidden auto-action buttons → VM GPRM
arithmetic). Needs a USB keyboard attached to the MiSTer (a gamepad has no numpad).

- **`emu.sv` — "NUMPAD MENU INPUT"**: the framework's `ps2_key[10:0]` =
  `{toggle, pressed, extended, scancode[7:0]}` (clk_sys; bit 10 flips on every new key
  event). A combinational case maps the PS/2 set-2 scancode (non-extended only, so
  numpad `Enter`/`/` can't false-match) → digit 0..9. On a *press* edge (toggle change +
  `pressed`) of a digit, while `menus_on && hl_btns_armed`, it pulses `num_sel_p` with
  `num_btn_r` = button number. Gate is armed-HLI-only, covering both a menu-domain menu
  and an in-title HLI menu (Scene It). Out-of-range numbers are dropped in nav_pci.
- **`dvd/nav_pci.sv` — `num_sel`/`num_btn`**: forces `btn_sel <= num_btn`, triggers the
  button-record fetch, and sets `auto_pend` so the activation fires in `F_DONE` **with the
  freshly-loaded `btn_cmd`** — race-free (no stale-command activation, unlike pulsing
  `nav_act` right after a `sel_force`). Because `btn_sel` is set before the activate,
  `dvd_vm`'s `sprm8_eff` (the `btns_armed` SPRM8 shadow) already reflects button N, so a
  command that reads SPRM8 sees the typed value. Verified: `nav_pci_tb` T10 (digit 4 →
  button 4 + LinkPGCN 8 fires; out-of-range digit 10 ignored).
- **Multi-digit codes / >10-button menus**: not accumulated — each digit is one
  select+activate. The easter-egg codes ARE authored as per-digit hidden auto-action
  button chains (GPRM arithmetic in the VM), so single-digit activation is exactly right.
  A true multi-digit numeric *entry* field (rare) would need an accumulator + timeout.

## DVD-VM interpreter (Phase 4, `feature/dvd-vm`)

**The disc's navigation commands now EXECUTE** — see **`docs/dvd_vm.md`** for the
full design. Summary of what changed in this file's terms: with `O[1] Disc Menus =
On` the mount no longer auto-plays (the VM boots the First Play PGC); the Phase-2
proto-nav fallback chain and the Phase-3 micro-bridge moved into `dvd/dvd_vm.sv`
(buttons/menu keys now run the real commands: SetGPRM dispatch, JumpSS trampolines,
CallSS/RSM, SetSTN stream selection); the reader gained `vm_mode` wait states
(cell-command / drained-PGC-end verdicts), the JumpTT TT_SRPT resolve + title-entry
scan (`jump_ttn`), and the program-map walk phase (`jump_pgn`, P_PMAP). With menus
Off everything behaves exactly as Phase 3. Sim-verified end-to-end
(`bench/dvd/iso_reader_vm_tb.sv`); ✅ HW-confirmed through the menu-refinements HW rounds
(2026-07-08, PRs fj#84–fj#90 — see `docs/dvd_menu_refinements.md` status roll-up).

## DSI / nav foundation (Phase 7, PR fj#95) — ✅ HW-CONFIRMED (no-regression, 2026-07-09)

> **Status:** DSI parse sim-proven (byte-exact vs a real MiB sector) + **HW-confirmed
> no-regression** — multiple test ISOs play cleanly (video + audio + menus) with the
> `nav_dsi` sink live (accept-always, never stalls the demux). The on-screen time readout
> (rows 18/19) is a deferred follow-up (release build has the overlay compiled out).

**Goal:** parse each VOBU's **Data Search Information** (DSI) so the core gains a
presentation-time ⇄ disc-sector map — the shared foundation for **seek/scrub/chapter**
(Phase 8) and **multi-angle** (Phase 9). First HW milestone: an on-screen **current /
total time** readout proving the DSI timestamps parse end-to-end.

Each VOBU's nav pack (`private_stream_2`, `stream_id 0xBF`) carries **two** PES: PCI
(substream `0x00`, → `nav_pci`, menu buttons) and **DSI** (substream `0x01`). ps_demux
used to discard the DSI; it now routes it out to a new **`dvd/nav_dsi.sv`**, the exact
twin of the PCI → `nav_pci` path:

- **ps_demux routing:** a `dsi_enable` gate (tied **on** in emu — the time readout is
  wanted during plain title playback, not just menus) + a new `S_DSI_DATA` state
  (accept-always, `dsi_frame_start` on the byte after the `0x01` id). The PS2 substream
  peek now enters on `(pci_enable || dsi_enable)`; `0x00`→PCI, `0x01`→DSI, each only if
  its sink is enabled, else discard-by-length (a floating enable still resolves to the
  discard path, so non-menu demux tbs are behavior-identical).

- **`nav_dsi.sv` field map** (byte index = DSI data start, the byte after the `0x01` id;
  offsets verified vs libdvdread `nav_types.h` and the real MiB fixture byte-exact):
  scalars → **registers** (`nv_pck_lbn`@04, `vobu_ea`@08, `1stref_ea`@0C, `vob_idn`@18,
  `c_idn`@1B, **`c_eltm`@1C** = cell-elapsed BCD dvd_time, `next_vobu`@13A,
  `prev_vobu`@13E, `next_video`@EA, `prev_video`@18E); the seek/angle tables →
  **one sync-read M10K** `dsi_tbl` (fit discipline — never an async register file):
  `fwda[19]`@EE and `bwda[19]`@142 (the ±time seek tables, Phase 8) at addrs 0..18 / 19..37,
  and `sml_agli` address[9]@B4 (seamless-angle offsets, Phase 9) at addrs 38..46. The read
  port (`tbl_raddr`/`tbl_rdata`) is exposed but unconsumed this phase — parsing them **now**
  is the point of the foundation.

- **Time readout (staged) — DEBUG_OVERLAY only, NOT in the release build:** the multi-row
  `dvd/debug_overlay.sv` gains **row 18 = current time** (DSI `c_eltm`, `{mm,ss}` BCD) and
  **row 19 = total time** (`dvd_iso_reader`'s new `pgc_playback_time` = PGC@4 `dvd_time`,
  captured at the PGC header — already resident in the `rbuf` shadow, no extra fetch/BRAM),
  both MM:SS as 4 BCD nibbles via `tools/osd_read.py` (NROW 18→20).
  **⚠️ IMPORTANT (2026-07-09, HW-learned):** that multi-row overlay is wrapped in
  `` `ifdef DEBUG_OVERLAY `` and is **compiled OUT of the release build** (congestion — it
  shares the display hotspot with the subpicture blend; `ov_on` is hardwired 0). In a
  release `.rbf`, `O[2]` instead drives only the lightweight **menu-highlight diagnostic
  blocks** (`status[2] && menus_on`, `dbg_blk1..8` in `emu.sv`) — so **rows 18/19 render
  ONLY in a build with `DEBUG_OVERLAY` defined in `DVD.qsf`.** The wires (`dbg_nav_time`,
  `dbg_nav_total`) are always present and are the hook for a future **release-visible** time
  readout (a follow-up — a small always-compiled numeric strip, done carefully in the
  congested corner). **Staged too:** "current" is **cell-relative** (`c_eltm`); the
  whole-title running time (`cell_start[cur_cell] + c_eltm` prefix-sum in the reader) is a
  deliberate follow-up (really Phase-8 time↔sector territory).

**Golden tool:** `tools/nav_extract.py --dsi` decodes the DSI packet (dsi_gi / vobu_sri /
sml_agli), offsets cross-checked against `nav_types.h`. **Tests:**
`bench/dvd/nav_dsi_tb.sv` (drives the real MiB DSI sector — `nv_pck_lbn=6836`, `vobu_ea=136`,
`c_idn=2`, `next_vobu=0x80000089`, `prev_vobu=END_OF_CELL`, `fwda[2]=0x7fffffff`,
`fwda[3]=0xc0000ab8` — byte-exact) + extended `bench/dvd/ps_demux_ps2_tb.sv` (DSI `0x01`
reaches the dsi sink, 1017 bytes byte-exact, while PCI `0x00` still reaches `nav_pci`). All
reader/demux/menu/VM/nav_pci suites green.

**HW gate (release `.rbf`):** DSI routing is active but has **no on-screen readout in the
release build** (see the overlay note above). So the release HW check is a **no-regression**
test: a DVD ISO still plays correctly (video + audio + menus) with the DSI sink live —
`nav_dsi` is accept-always and must never stall the shared demux stream. The DSI **parse**
itself is taken as **sim-proven** (byte-exact vs a real MiB disc sector). To actually *see*
the current/total time on HW, build a **`DEBUG_OVERLAY` variant** and read rows 18/19 via
`tools/osd_read.py` (menus OFF so the title auto-plays and `c_eltm` increments). Phase 8 then
drives `dvd_iso_reader`'s seek primitive from a DSI/IFO-derived target sector.

## Exact chapters / PTT (Phase 6, `feature/exact-chapters-ptt`)

**Status: ✅ HW-CONFIRMED (PR fj#127, 2026-07-25 — light test: no regression, boots + plays;
movies unaffected by construction).** Promotes the chapter machinery from the `program ≈ PTT`
approximation toward the exact DVD `VTS_PTT_SRPT` model. Golden model: `tools/ptt_ref.py`
(faithful ports of libdvdnav `set_VTS_PTT` forward + `vm_get_current_title_part` reverse).

**What shipped (sim-verified + HW-confirmed):**
1. **Forward resolve (the load-bearing fix)** — `JumpVTS_PTT t:p` now resolves the *exact*
   `VTS_PTT_SRPT[t][p-1] → {pgcn, pgn}` and lands on the right PGC + program (was `ptt ≈ pg`).
   Fixes disc-VM chapter branching on multi-PGC (game) discs; unchanged on movies.
2. **Resident `ptt_mem` + `nr_ptt`** — the current title's full chapter table is loaded at
   mount (P_PTT walker), and the **HUD `CH n/N` total is now the exact `nr_of_ptts`** (equal
   to `nr_of_programs` on every single-PGC movie title, so no visible movie change; correct
   on multi-PGC titles, clamped through the 99/100 HUD/notch limits).

**Deferred (ptt_mem foundation is in place; documented decision, 2026-07-25):** the
**user B2/B3 chapter-skip crossing PGC boundaries** and the **PTT-based current-chapter `n`**
(reverse map) were intentionally NOT built. They would restructure the HW-confirmed
`chap_st` FSM (PR fj#96), and measurement shows they only differ from today on **multi-PGC
titles**, which in the whole test library are *only* the Scene It game discs — all with
>99 chapters (the HUD caps at 99) and where user chapter-skip is not a real use case. Every
movie title is single-PGC, so today's program-based skip is *already* the exact PTT answer
there. Net: zero observable benefit on any disc a chapter number is visible on, vs. real
regression risk. The reverse-map count rule (`chapter = #{ptt : pgcn<cur_pgcn or
(pgcn==cur_pgcn and pgn≤cur_prog)}`) and the cross-PGC skip (look up `ptt_mem[c±1]`; same
`pgcn` → program seek, else an internal TT jump) are specified below for when a disc needs
them.

### The gap, measured (do NOT re-chase the movie case)

A DVD **chapter = a "part of title" (PTT)**. `VTS_PTT_SRPT[vts_ttn]` lists, per chapter,
a `{pgcn, pgn}` pair — *which PGC* and *which program in it*. The count is
`nr_of_ptts` (VMGI `TT_SRPT`), **not** the entry-PGC's `nr_of_programs`. Until Phase 6 the
reader approximated a chapter as "program N of the entry PGC" (`pmap_mem`), which is exact
**iff** the title is single-PGC with `pgn == chapter`.

`tools/ptt_ref.py` over the local library (7 discs) shows that approximation is:
- **EXACT on every movie disc** — MiB (27 ch), Matrix (38), T2 (73), PAW: all TRIVIAL
  (one PGC, `pgn == chapter`, `nr_of_ptts == nr_of_programs`). So exact-PTT changes
  **nothing visible** on movies; the value is spec-correctness + not regressing them.
- **DIVERGES only on the Scene It game discs** — multi-PGC titles, `nr_of_ptts` ≫ programs
  (798 chapters over 241 PGCs on `Scene_It`). There the disc's own VM drives navigation via
  `JumpVTS_PTT`/`LinkPTTN`, so the load-bearing fix is the FORWARD resolve.

### IFO layout (BIG-ENDIAN)

```
VTSI_MAT.vts_ptt_srpt   @200  u32 sector ptr (rel VTSI)   -> VTS_PTT_SRPT
VTS_PTT_SRPT.nr_of_srpts  @0  u16   (titles in this VTS)
             last_byte    @4  u32   (last byte, rel VTS_PTT_SRPT)
             ttu_offset[i] @8+4i u32 (byte offset of title i+1's PTT array, rel VTS_PTT_SRPT)
  PTT_SRP (title i, chapter c) @ ttu_offset[i] + 4c : { pgcn u16@0, pgn u16@2 }
  nr_of_ptts(title i) = (ttu_offset[i+1] - ttu_offset[i]) / 4   (last: (last_byte+1 - off)/4)
```

### Forward resolve — `set_VTS_PTT(vts_ttn, part)` → `{pgcn, pgn}`  (the load-bearing fix)

Used by `JumpVTS_PTT t:p`, `LinkPTTN p`, and user "skip to chapter". The existing
`S_PTT_MAT/OFF/PGC` states already resolve **PTT[0]** of `want_ttn` (that is how the Matrix
white-rabbit `JumpVTS_PTT(ttn=6)` lands on PGCN 6). Phase 6 generalizes them to **PTT[part-1]**:
`fetch_base = ttu_off + 4*(part-1)` → `{pgcn, pgn}` → `want_pgcn = pgcn`, start program
`= pgn` (the existing `jpgn_l` / `P_PMAP` start-cell latch). `part` defaults to **1** when the
VM gives none (so ttn-only jumps like the white rabbit are unchanged — PTT[0]).

VM bit-fields (libdvdnav `decoder.c`, verified): `JumpVTS_PTT` data1(ttn)=`getbits(22,7)`,
data2(part)=`getbits(41,10)`. `LinkPTTN` data1(part)=`getbits(9,10)` (current title's
`vts_ttn`), data2(button)=`getbits(15,6)`. `jump_pgn` is repurposed from "program n" to
"PTT part n" via a new `jump_pgn_is_ptt` flag so `LinkPGN` (a real program link) still resolves
directly against `pmap_mem`.

### Resident PTT table for the CURRENT title — reverse map + user skip
### ✅ read side WIRED — HW-CONFIRMED + MERGED (PR fj#171, 2026-08-19)

`ptt_mem[0:PTT_CAP-1]` (sync-read M10K, `{pgcn[15:0], pgn[7:0]}` — the pgcn high byte was
restored by the 15-bit-PGCN fix, PR fj#164 — **PTT_CAP=1024** since PR fj#170; a beyond-cap title
clamps the user-skip/HUD gracefully, VM jumps are unaffected since they resolve on-demand).
Loaded at title mount for `cur_ttn = (want_ttn ? want_ttn : 1)` by a **`P_PTT` walker phase**
(reuses the sector-crossing byte walker; 4 bytes/entry).
`nr_ptt = min((ttu_off[ttn]-ttu_off[ttn-1])/4, PTT_CAP)`.

The table sat write-only ("swept dead logic", the PR fj#170 fit finding) until the Phase-5
follow-up wired its read side into the `chap_st` mini-FSM (states `CH_G0/CH_G/CH_GR/CH_T/CH_T2`,
between the program-map walk and the legacy resolve). One shared scan serves both consumers:

- **Reverse (HUD `CH n/N`):** after the `pmap_mem` walk settles the current *program*
  (`chap_best`), `CH_G` scans `ptt_mem` one entry/cycle (sync-read, pipelined address — fit
  discipline, ≤ 1024 cycles ≈ 38 µs) for the **last entry with `pgcn == cur_pgcn` and
  `pgn <= program`** = the global chapter `g_best`. The HUD query publishes
  `cur_pgm = g_best+1` (**the GLOBAL PTT index** — consistent with the `nr_ptt` total on
  multi-PGC titles; 8-bit display clamp at 255 matching emu's `hud_nr_ch`). On a trivial
  (movie) title this equals the program — identical to before. No reverse-map hit → the
  per-PGC program as before.
- **User skip (B2/B3):** the same scan also records `g_pgc_first/g_pgc_last` (the current
  PGC's entry-run bounds). `CH_GR` first re-checks the **legacy within-PGC resolve** — taken
  whenever the move resolves inside the loaded PGC *or* clamps at a title end living in this
  PGC. Single-PGC titles satisfy that structurally (`g_pgc_first==0 && g_pgc_last==nr_ptt-1`),
  so **every movie disc stays bit-identical on the HW-proven program-map path** (asserted in
  the tb). Only when the target leaves the PGC's entry run does it go global:
  `g_t = g_best ± mag` (prev keeps the restart-current-chapter rule via `chap_dec`; both ends
  clamp to `[0, nr_ptt-1]`), then `CH_T/CH_T2` read `ptt_mem[g_t] = {pgcn', pgn'}`:
  - `pgcn' == cur_pgcn` → within-PGC after all (clamped magnitude): the existing
    `CH_C/CH_D` program-map seek to `pmap_mem[pgn'-1]`.
  - else → **cross-PGC**: latch an internal **JumpVTS_PTT-shaped jump** (`jump_pending`,
    domain TT, `jvts = play_vtsn`, `jttn = cur_ttn`, `jptt = g_t+1`) — the exact
    `S_PTT_MAT/OFF/PGC → want_pgcn + jpgn_l` machinery the VM uses, re-resolved from disc.
    User action ⇒ `jnat_l = 0` (immediate, no tail-drain gate — the Phase-B provenance
    rule) and the title-domain jump takes the full seek-flush contract
    (`jump_ack` → load_flush + vbuf_flush → A/V re-anchor), like a chapter jump today.
    A VM jump latched the same cycle outranks it. (`jptt_l` widened 10→11 bits so the
    internal path can address chapter 1024 = the table's last entry; the VM operand
    stays 10-bit.)

The skip arm also relaxed: `chap_go` fires when `cmd_nr_pgm > 1 || nr_ptt > 1`, so a
1-program PGC inside a multi-chapter title (the Scene_It shape) can skip *out* of its PGC.
Known trade-offs (documented, accepted): a cross-PGC skip re-enters `S_PGC_DONE`, which
resets the camera angle to 1 (angle titles are single-PGC in practice); the reverse map
assumes each PGC's PTT entries form one contiguous run (true of real authoring).

Verified: `bench/dvd/iso_reader_ptt_tb.sv` T-I..T-P — within-PGC next stays on the seek
path (path-asserted via `seek_ack` vs `jump_ack`), next/prev across the PGC boundary jump
(incl. from/to a 1-program PGC), clamps at both title ends, prev restart mid-chapter,
multi-magnitude cross clamp, single-chapter no-arm, and global `cur_pgm` on landings.

### Why this shape (risk control)

The movie chapter path is HW-CONFIRMED (PR fj#96). Phase 6 keeps `pmap_mem` + `chap_st` as the
**within-PGC mechanics** and layers the PTT table on top as the chapter⇄position oracle, so on
every movie title the resolved numbers are provably identical (a different path to the same
answer — asserted in the tbs). Cross-PGC skip and >1-program-per-chapter only ever fire on the
game discs. Fit discipline: `ptt_mem` is sync-read BRAM, `P_PTT` reuses the existing walker,
no async table indexing (the repeated 106%/226% ALM trap).

### Verification

- `tools/ptt_ref.py <iso>` — per-title PTT dump + TRIVIAL/DIVERGES verdict + reverse
  self-check; `--vectors` emits `$readmemh` PTT tables + resolve/reverse vectors for the tb.
- `bench/dvd/iso_reader_ptt_tb.sv` — (1) a TRIVIAL movie table: reverse == program, skip ==
  existing path (bit-identical); (2) a synthetic multi-PGC table: forward `part→{pgcn,pgn}`,
  reverse straddle rule, cross-PGC skip issues an internal jump.
- Existing `iso_reader_chapter_tb` / `iso_reader_vm_tb` / real-VOB `ps_chain` stay green.

## Seeking / Phase 8 — chapter skip + time scrub (`feature/dvd-seek-chapters`)

Phase 8 turns the Phase-7 DSI seek tables + the PGC program_map into two interactive
transport actions, both built **on the existing cell-seek primitive** (block-boundary
latch + `seek_ack` → the VBUF-flush/A/V-reanchor contract; see "Transport" above). A
seek always lands on a **VOBU boundary = a GOP/sequence-header = an I-frame**, so the
decoder re-locks cleanly and the existing flush already blanks until the first decoded
picture — no separate decode-to-I mask was needed. **✅ HW-CONFIRMED (PR fj#96).**

### 1. Chapter skip (precise, B2/B3) — resolved in the reader

A chapter boundary **is** a cell boundary, so chapter skip reduces to "seek to the cell
that starts program N±1". The PGC `program_map`@230 (already streamed to the VM as
`pm_we/pm_waddr/pm_wdata`) is shadowed into a **sync-read M10K `pmap_mem`** in
`dvd_iso_reader` (`pmap[p]` = 1-based entry cell of program/chapter p+1). A small
mini-FSM (`chap_st`: `CH_A/B/R/C/D`, parallel to the main FSM) walks it on `chap_pulse`:

- Scan `pmap[0..nr_pgm-1]`, tracking `chap_best` = the largest program whose entry cell
  ≤ the current cell (`cell_i`), and its start cell `chap_best_cell`.
- **Next:** target = `chap_best+1` (a **no-op at the last chapter** — `chap_do=0`).
- **Prev:** **restart the current chapter** (the standard player behaviour) unless we're
  right at its start — `chap_at_start` (from emu: DSI `c_eltm` cell-elapsed ≤ ~5 s) **and**
  we're in the chapter's first cell (`cell_i == chap_best_cell`) — in which case step to the
  previous chapter. So a double-tap from the start walks back. (Cell granularity alone is
  insufficient: most chapters are a single cell, so `cell_i > chap_best_cell` is never true
  and prev would *always* step back — the `c_eltm` time gate is what fixes that.)
- Resolve reads `pmap[target]` and arms `seek_pending`/`seek_cell_l` → the normal
  `seek_jump` executes it. A dedicated **`CH_R` settle state** exists because the last
  program's `chap_best` update and the resolve would otherwise collide in one cycle
  (non-blocking hazard — caught by `iso_reader_chapter_tb` T4).

Full 99-chapter support, control-path only. Requires `nr_pgm > 1` **or `nr_ptt > 1`**
(single-chapter titles → ignored; the `nr_ptt` arm is the cross-PGC relaxation). Chosen
over an earlier emu-side `chap_cell[32]` async map (32-chapter cap + a self-correcting
`cur_chap` lag) — the reader BRAM is fit-disciplined and accurate.

**Cross-PGC (spec-hardening Phase-5 follow-up):** the walk above is now the *within-PGC
fast path*. When a PTT table is resident, the `CH_G*` states reverse-map the position
through `ptt_mem` and a target leaving the current PGC dispatches an internal
JumpVTS_PTT-shaped jump instead — multi-PGC titles (Scene_It, PNP0NNS1) can finally
skip across PGC boundaries, and the HUD `CH n` becomes the global PTT index. See
"Resident PTT table" in the Phase-6 section above for the full mechanics.

**Multi-press debounce (`feature/chapter-skip-debounce`).** A single B2/B3 press used to
fire an immediate seek, so a rapid multi-press *scrubbed* — the video visibly jumped through
every intermediate scene before landing. emu now **debounces** presses: each B2/B3 edge
adjusts a signed net accumulator (`chap_net`, +next/−prev, saturating ±31) and (re)arms a
~500 ms timer (`CHAP_DEBOUNCE`, `13.5 M` clk_sys ticks). Only when the window elapses with
no further press does emu fire **one** `chap_pulse` carrying the net **direction** (`chap_dir`)
and **magnitude** (`chap_mag`, held registered until the next burst). The reader jumps the
whole distance at once: `CH_R` latches `chap_mag_l` and resolves the target as `chap_best +
mag` (next) or `chap_best − dec` (prev), clamped to `[0, nr_pgm-1]`. The prev restart-nuance
generalises: the **first** prev step restarts the current chapter (unless past its start), so
`dec = past_start ? mag−1 : mag`. A net of 0 (equal next/prev in one window) fires nothing.
Single-press behaviour is `mag = 1` → identical to before. Covered by `iso_reader_chapter_tb`
T8–T11 (next×2, prev×2, and oversized bursts clamping at the ends).

**Live OSD preview.** Because the seek is deferred to the end of the window, the HUD's
`CH n/N` field would otherwise sit on the *current* chapter while the user is still tapping —
you couldn't tell which chapter you were selecting. emu therefore feeds the HUD a **projected
target** (`hud_cur_ch`) that mirrors the reader's resolve in 1-based chapter space (`next: cur
+ |net|`; `prev: cur − dec`, `dec = past_start ? |net|−1 : |net|`, `past_start ≈ !chap_at_start`),
clamped to `[1, N]`, so the number counts up/down **immediately on every press** (the chapter
popup already pops on the raw B2/B3 edge). A small registered latch (`chap_disp_hold`/
`chap_disp_act`, ~1 s safety timeout) holds the final target through the seek settle so the
number never flickers back to the old chapter between the burst firing and the reader resolving
`cur_pgm`. Idle → the real `cur_pgm_w`.

### 2. Time scrub (sub-cell, D-pad L/R) — DSI fwda/bwda + raw-RBN seek

A ±time scrub reads the **DSI VOBU_SRI** seek tables. Interval for entry `i` is
`stime[i]/2` seconds with `stime[19]={240,120,60,20,15,14,…,2,1}` (libdvdread
`nav_print.c`), so **+10 s = fwda[3]**, **−10 s = bwda[15]** (`dsi_tbl` addr 3 / 19+15=34).
`dvd/scrub_ctrl.sv` reads that entry via `nav_dsi.tbl_raddr/tbl_rdata` (§2a extends this to a
held, accelerating scrub across the four tiers):

```
offset  = entry & 0x3fffffff                 (low-30-bits-all-ones = END_OF_CELL sentinel)
valid   = entry[31] && offset != 0x3fffffff  (a real forward/back pointer sets bit31)
target  = dsi_nv_pck_lbn ± offset            (fwd +, back −)   [VTSTT_VOBS RBN space]
```

If the ±10 s VOBU isn't present near a cell edge (END_OF_CELL), emu falls back to the
`dsi_next_vobu`/`dsi_prev_vobu` ±1-VOBU pointer so a scrub always makes progress. The
target RBN is handed to the reader's new **raw-RBN seek** (`seek_rbn_pulse`/`seek_rbn`):
`S_RBN_SCAN` walks the cell table for the cell whose `[first,last]` RBN range contains the
target (keeping `cur_cell`/`play_end` coherent — a scrub can cross cells), then streams
from that exact RBN via the existing extent map. Out-of-range clamps to the last cell.

This is a **relative** scan ("skip ±10 s"), not an absolute scrub-bar — arbitrary-timestamp
seek needs the VTS **TMAP** time-map (libdvdnav does time seek via TMAP, not fwda/bwda).
**Phase-8b (TMAP absolute seek) is RETIRED (2026-07-10, user decision): the shipped
seek-on-release scrub + chapter skip is the accepted final seek UX — don't re-propose it.**

### 2a. Hold-to-seek — SEEK-ON-RELEASE with acceleration (`dvd/scrub_ctrl.sv`)

The one-shot ±10 s scrub became **HOLD-to-seek, seek-on-release**: hold the **Fast Fwd (B10) /
Rewind (B11)** buttons to choose a target (the offset **accelerates** the longer it's held),
then **release to jump there** with one seek. While held, the video simply **pauses** and audio
holds. Implemented in `dvd/scrub_ctrl.sv` (unit-tested by `bench/dvd/scrub_ctrl_tb.sv`).

> **★ Seek is on dedicated buttons, NOT the D-pad (2026-07-28).**
> **⚠ AMENDED 2026-08-27 — now CONDITIONAL, not absolute: see §2b.** The *hold-to-seek scrub*
> is still exclusively Fast Fwd/Rewind and the D-pad is still pure navigation **by default**,
> but the opt-in `O[45]` **D-Pad Seek** toggle puts fixed-time jumps on the D-pad for users who
> want them. The original conflict is contained three ways: the toggle **defaults Off**, it is
> suppressed by `menu_nav`/`in_title_menu` exactly like the rest of the title transport, and it
> never touches the held scrub. The reasoning below is why it must stay opt-in.
>
> The scrub originally rode
> D-pad Left/Right, which collided with interactive/game DVDs whose title video is *seekable*
> yet the game expects left/right *directional* input (the core's `in_title_menu` heuristic
> couldn't always tell the two apart). Splitting the scrub onto its own **Fast Fwd/Rewind**
> buttons makes the D-pad **always** pure navigation — no heuristic, no conflict. `scrub_ctrl`
> is unchanged (it just takes `held_right`/`held_left` levels); emu now wires those to
> `joystick_0[13]`/`joystick_0[14]` instead of the D-pad bits.

**★ Why seek-on-release, not a live still-scan (HW rounds 1–2 dead end, 2026-07-10).** Two
earlier attempts tried to show live still I-frames while holding: (round 1) pace hops on
`nav_dsi.dsi_commit` — but that parses at the VOBU **start**, before the I-frame, so it
re-flushed before any frame displayed (**mostly black**) and played in the gaps (**motion +
audio**); (round 2) pace on `video_live` and freeze/mute — but the decoder (built for
continuous playback, ~1–2 MB VBUF + a watchdog) can't cleanly flush→re-lock→show a still fast
enough: it froze on the *stale* frame, and the un-frozen ~1 s re-lock window **tripped the
watchdog** (→ 720×179 resync / black). **Conclusion: rapid repeated flush/re-lock fights this
decoder.** Seek-on-release does exactly **one** flush/re-lock (on release) = robust, exactly
like the confirmed single-seek transport.

Mechanics (all in `scrub_ctrl`, sector/RBN-based against the title span
`title_first_rbn..title_last_rbn` from the reader):
- **Hold** = a plain pause: `hold_freeze` (= a direction held in a title) is ORed into emu's
  pause holds — `pause_gov` (governor + `av_sync.pause` STC) and `pause_aud`
  (`dvd_audio_decode.pause` + drain-watchdog freeze). This is the *same* stable hold as a manual
  pause (the watchdog is suppressed the whole time), so there is no re-lock/watchdog problem.
- **Accumulate** = on the press edge it latches `base_rbn = cur_rbn` (the live playhead
  `dsi_nv_pck_lbn`); every ~0.06 s tick it adds a **tier-scaled** step `span >> {10,8,6,5}`
  sectors (tier 0→3 by hold time 0/1.5/3/5 s) to a signed offset, capped at the title span. A
  direction flip restarts the accumulation the other way.
- **Release** = `target = clamp(base_rbn ± offset, first, last)`; if anything accumulated it
  pulses **one** `seek_rbn` (the reader's `S_RBN_SCAN` finds the containing cell). A sub-tick
  tap accumulates nothing → no-op.
- **`bar_*` outputs** (`bar_active`, `bar_base_rbn`, `bar_tgt_rbn`) expose the playhead + target
  position for the Phase-11 on-screen position bar — **✅ built: `dvd/seek_bar.sv`**
  (✅ HW-CONFIRMED 2026-07-10, PR fj#103): fill = playhead at hold start, amber cursor = the
  accumulating release target, + a pause/seek progress popup with chapter ticks. The status
  line shows `►►×n` while held (`hud_tier`/`hud_dir` exports). See `docs/transport_hud.md`.

### Golden references + tests

- `tools/nav_extract.py` `dsi_seek_map()`: fwda/bwda → target sector, printed per NAV
  sector. Validated on the real MiB fixture: `fwda[3]=0xc0000ab8` → `6836+0xab8 = RBN 9580`.
  Now also prints a **scrub tiers** block (the four `scrub_ctrl` jumps + their `tbl_raddr`).
- `bench/dvd/scrub_ctrl_tb.sv`: `scrub_ctrl` seek-on-release unit test — hold→release seeks in
  the held direction; a longer hold seeks further (acceleration); backward; clamp at
  title start/end; a sub-tick tap does nothing; `hold_freeze` high only while held;
  direction-flip restarts; in_title gate.

> **Note:** §2a (seek-on-release, sector/RBN-based) is the shipped **hold-to-seek** on
> Fast Fwd/Rewind, and `scrub_ctrl` itself never reads the fwda/bwda tables.
> **★ AMENDED 2026-08-27:** the tables are **no longer dead** — §2's mechanism is exactly what
> the opt-in `O[45]` **D-Pad Seek** (§2b) resurrects, via `dvd/dpad_seek.sv` on the
> `nav_dsi.tbl_raddr/tbl_rdata` port that `emu.sv` had tied to 0 since Phase 7. The
> `tools/nav_extract.py` "scrub tiers" dump stays historical, but the new
> **`--dpad`** dump is the live golden model.

### 2b. D-Pad fixed-time seek — `O[45]` (`dvd/dpad_seek.sv`) — ✅ HW-CONFIRMED 2026-08-27 (PR #15)

**Opt-in, default Off.** With it On, while a title plays: **Left/Right = ∓10 s,
Down/Up = ∓60 s** — VLC-style *fixed-time* jumps, as opposed to §2a's span-relative
("percent of title") scrub. Presses inside a **~400 ms window coalesce into ONE seek**,
and each further tap re-arms the window, so **keep tapping and the total keeps growing** —
tap Up twenty times and you get one 20-minute jump. There is no small artificial ceiling:
`UNIT_CAP` exists only so the **MM:SS** readout stays exact (99:50 is the widest it can
render), and what actually bounds a jump is `scrub_ctrl`'s clamp to the title span.
Whatever the total, it is still ONE seek and ONE decoder flush.

The HUD shows the running total as **`SEEK FWD 12:30`** while you tap. The accumulator
counts units of 10 s, so the readout needs `units/6` and `units%6`; rather than a divider
that would sit idle 99.99 % of the time, `dpad_seek` converts by **repeated subtraction
across the idle cycles of the coalesce window** (≤99 iterations against a ~400 ms window),
which keeps the module free of any wide arithmetic.

**Where the target comes from.** The DSI VOBU_SRI tables of §2, addressed as:

| gesture | seconds | fwd index | `dsi_tbl` addr |
|---|---|---|---|
| Right / Up | +10 / +60 | `fwda[3]` / `fwda[1]` | 3 / 1 |
| Left / Down | −10 / −60 | mirror | 34 / 36 |

The backward mirror of forward index `a` is address `37 − a`. Decoding is §2's:
`offset = entry[29:0]`, `valid = entry[31] && offset != 0x3fffffff`,
`target = jump_base ± offset`. The target goes to **`scrub_ctrl`'s jump port**, which
applies the existing title-span clamp and issues the ONE proven `seek_rbn` — so the
reader's `S_NAV_SEEK` VOBU-snap (§2a) applies unchanged and every landing is an I-frame.

**Why a greedy ladder, not N × the 10 s entry.** All entries are offsets from the *same*
`nv_pck_lbn`, so a multi-term sum is only time-linear if the bitrate is flat over the
window. Decomposing greedily over the coarse ladder `{120,60,30,10}` s minimises terms,
which makes the common gestures **exact single lookups**:

| presses | seconds | naive N×10 s | greedy ladder |
|---|---|---|---|
| 1×R | 10 | exact | **exact** `fwda[3]` |
| 3×R | 30 | 3 terms | **exact** `fwda[2]` |
| 6×R / 1×U | 60 | 6 terms | **exact** `fwda[1]` |
| 2×U | 120 | — | **exact** `fwda[0]` |
| 2×R | 20 | 2 terms | 2 terms (no 20 s rung exists) |

A long tap burst lands on a large total, which simply decomposes into more 120 s rungs
(bounded by `MAXTERMS = 64`, a few cycles each) — 20 minutes is 10 rungs.

**END_OF_CELL cascade.** Descend one coarse rung, crediting the leftover seconds (only the
rung actually *used* is subtracted) → below 10 s, walk the fine rungs (7.5 s … 2 s) and take
the first valid one, then **stop** (a bounded partial jump) → if the whole ladder is dead:
forward takes `dsi_next_vobu`, else `dsi_vobu_ea + 1` (the head of the next cell in RBN
order, which `S_RBN_SCAN` re-selects); **backward with no `dsi_prev_vobu` is a NO-OP**, not a
guess. A partial result already accumulated is kept rather than mixed with a VOBU pointer.

**⚠ The stale-table trap — read before touching this.** `nav_dsi.rst_n` is `pipe_rst_n`, so
every load/seek/jump clears `dsi_nv_pck_lbn` to 0, but `dsi_tbl`/`tbl_rdata` are written by a
**separate, unreset** always block and keep the *previous* VOBU's offsets. Resolving in that
window computes `0 ± stale_offset`, which the clamp turns into **a jump to the start of the
title** — and "tap, then tap again 200 ms later" is exactly what a user does. So `dpad_seek`
keeps a `dsi_fresh` latch (set by `dsi_commit`, cleared by `load_flush`) that gates entry to
the resolve; `load_flush` or a new DSI packet mid-resolve **restarts** it; the base is latched
**once** on entry and exported as `jump_base` so `scrub_ctrl` can never pair it with another
VOBU's offsets; and a resolve that cannot get a trustworthy base within ~2 s is **dropped**.
`dsi_commit` is the correct set point — it fires at DSI byte `0x191`, after the last `bwda`
write at `0x18D`, so scalars and table belong to the same VOBU. The contract is now recorded
in `nav_dsi.sv`'s header for the next consumer.

**Why coalesce and never auto-repeat.** A held direction firing a jump per VOBU is exactly
the rapid flush/re-lock regime that HW rounds 1–2 of the scrub proved fatal (mostly-black
playback, watchdog resync — see §2a). The debounce shape is the chapter-skip burst's.
Unlike the scrub, a D-pad tap does **not** freeze video (an instantaneous hop has nothing to
freeze for, and the chapter-skip precedent doesn't either).

**Non-DVD content.** Raw VCD/SVCD `.bin` has no DSI, but a CD is a fixed 75 sectors/s of
2352 B and the reader's linear `seek_rbn` unit is a 2048-byte **file block**, so
`75·2352/2048 = 86.13 blk/s` → **10 s = 861 blocks** (exact for VCD's CBR mux; approximate on
VBR SVCD). Flat `.mpg`/`.VOB` has no derivable rate and is **deliberately inert** on the
D-pad — B10/B11 still scrub it.

**Conflict containment.** The D-pad is taken **only** where the nav layer has not claimed it:
`menu_nav` (disc menu) and `in_title_menu` (in-title game menu) both suppress it, exactly like
the rest of the title transport. Combined with the default-Off toggle, the 2026-07-28
guarantee below is preserved for anyone who does not ask for this.

**Feedback.** `pend_evt` joins `hud_user_evt`, so the position bar pops on the **first** press;
the status line renders the tap count in the shared `►►×n` field; and a new popup type reads
**`SEEK FWD  30S` / `SEEK BACK 60S`** (the sign is *spelled* because the glyph ROM has no `+`,
which keeps `tools/hud_font.py` and the committed `dvd/hud_font.mem` untouched).

**Known characteristics (properties of the data, not bugs):**
- `dsi_nv_pck_lbn` is **parse-front timed**, ~1 s ahead of the displayed picture, so `+10 s`
  lands ≈ +11 s and `−10 s` ≈ −9 s *relative to what is on screen*. More noticeable on a fixed
  10 s hop than on the eyeballed scrub. No VBUF-corrected playhead exists today.
- `bwda`'s 60 s rung is END_OF_CELL for the first 60 s of **every** cell, so a backward 60 s
  there cascades down to ~10 s or the cell start.
- This does **not** reopen Phase-8b/TMAP absolute seek, which stays RETIRED (see §2).

**Golden + tests:** `tools/nav_extract.py <iso> --title-vob N --dpad` prints the four gestures
per NAV pack with the rung or fallback each used — `dpad_resolve()` is a faithful mirror of the
RTL FSM. `bench/dvd/dpad_seek_tb.sv` drives the **real `nav_dsi`** from a synthetic DSI payload
(24 scenarios: exact lookups, both cascade tiers, both structural fallbacks, the stale-table
trap, mid-resolve restart, coalescing, linear mode, saturation, every inert-guard);
`bench/dvd/scrub_ctrl_tb.sv` T9–T12 cover the jump port; `bench/dvd/transport_hud_tb.sv`
T18–T20 the popup. `bench/dvd/run_dpad_seek.sh` runs the lot.

> **✅ RESOLVED — HW-CONFIRMED (2026-07-10, PR fj#106): A/V sync off after a scrub seek**
> (audio ahead <1 s, permanent; re-scrub / audio-track
> change don't fix it; a chapter jump does). **Root cause:** the scrub's raw-RBN seek
> (`seek_rbn_pulse` from `scrub_ctrl`) streamed from an arbitrary **mid-VOBU** sector
> (`dvd_iso_reader.sv` S_CELL_LOAD2 `seek_target = {seek_rbn_l,2'b00}`), so (a) the decoder
> re-locked **mid-GOP** → the pixelated-then-clean picture, and (b) DVD video PES carry a PTS
> only on each **VOBU-first** pack, so `ps_demux` recovered the **next** VOBU's I-frame PTS as
> the STC anchor while `video_live` re-armed on the earlier partial-GOP frames → the STC sat
> `T1−T0` (≤1 VOBU, <1 s) ahead of the screen → constant audio lead. Nothing re-anchors in
> linear play (forward-skew threshold ~15 s), so it never recovered — a chapter jump re-lands
> on a VOBU/cell boundary and re-anchors clean, which is why chapters "fixed" it. The reader's
> reset/flush contract was NOT the problem: both seek kinds fire identical
> `seek_ack`/`load_flush`/`vbuf_flush`/`pipe_rst_n` (av_sync/ps_demux/audio re-anchor the same
> way); the sole divergence was the unaligned start sector. **Fix:** the reader now snaps the
> scrub target **forward to the first NAV pack** (VOBU boundary) before the containing-cell
> scan — a 1-block-per-sector parse-probe (`S_NAV_SEEK`/`S_NAV_SEEK2`/`S_NAV_CHK`) matching
> `00 00 01 BA`@0 + `00 00 01 BB`@14 + `00 00 01 BF`@38, budget `NAV_CAP=1024`, raw-target
> fallback if no NAV is found / the extents or title-end are exceeded. A scrub landing is now
> byte-identical to the proven chapter-seek contract. Only the `seek_is_rbn` title path is
> affected — cell/chapter seeks, menu jumps, and the ILVU angle jump are untouched. Sim:
> `bench/dvd/iso_reader_seek_tb.sv` TEST4-8. **✅ HW-CONFIRMED (2026-07-10): scrub-release lands
> clean (no lasting pixelation) and audio stays in sync after a scrub in both directions;
> chapter/menu/angle unchanged.** (A/V Offset baseline is +100 ms.)
- `tools/iso_nav_check.py`: PGC `program_map` → chapter → entry cell → sd sector.
- `bench/dvd/nav_dsi_tb.sv`: the +10 s target math byte-exact (`RBN 9580`) vs the fixture.
- `bench/dvd/iso_reader_chapter_tb.sv`: 3-chapter disc — next/prev/no-op-at-ends land on
  the right entry cell.
- `bench/dvd/iso_reader_seek_tb.sv` TEST4-8 (VOBU-align): scrub to RBN 25 (mid cell2) now
  **snaps forward to the NAV pack at RBN 26** (TEST4); an on-NAV target does not shift
  (TEST5); a target whose next NAV is in the following cell re-selects that cell (TEST6,
  cross-cell); a NAV-free stretch falls back to the raw target when the probe budget
  (`NAV_CAP`) exhausts (TEST7) or the title end is reached (TEST8).

### HW status — ✅ CONFIRMED (PR fj#96)

On a real disc: **B2/B3** jump chapters cleanly (audio+video resync, no stale frame);
**Fast Fwd/Rewind (B10/B11)** scrub and resume in sync; both no-op safely at the ends;
the D-pad always walks buttons in a menu / in-title HLI (scrub/chapter are title-only,
`!menu_active`). Prev-chapter
HW-confirmed after the cell-granularity → `c_eltm`-gated fix (2026-07-10). The shipped build
carries the separate, known output-path chroma fringe (placement-class; not Phase-8 logic).

## Multi-angle / Phase 9 (`feature/dvd-multiangle`)

> **Status: ✅ HW-CONFIRMED 2026-07-10 (PR fj#98 — MiB title 13/VTS_14 plays one clean angle,
> B6 cycles all five seamlessly on the board).** Follows the selected camera angle's ILVU
> chain in fabric so a multi-angle title plays ONE clean angle; a new **B6 "Angle"**
> gamepad button cycles angles seamlessly (time-continuous — **no VBUF flush / no A/V
> re-anchor**, unlike a seek). Test vehicle: **MiB title 13 → VTS_14** (a real 5-angle FX
> breakdown, see the anatomy below).

### The real disc: MiB VTS_14 (measured, `tools/nav_extract.py --angles`)

A multi-angle segment is authored as an **interleaved block**: the PGC holds **one CELL
per angle**, all sharing the same physical VOB range, and each angle's data is chopped
into **interleaved units (ILVUs)** laid down round-robin `[a1·i1][a2·i1]…[aN·i1][a1·i2]…`.
MiB VTS_14 PGC1 (6 cells, 2 programs):

```
cell 1 cat=0x57 bm=1 bt=1 first=0    last=155664   <- angle 1  (bm=1 FIRST cell of block)
cell 2 cat=0x97 bm=2 bt=1 first=198  last=155948   <- angle 2  (bm=2 cell IN block)
cell 3 cat=0x97 bm=2 bt=1 first=391  last=156232   <- angle 3
cell 4 cat=0x97 bm=2 bt=1 first=584  last=156516   <- angle 4
cell 5 cat=0xd7 bm=3 bt=1 first=777  last=156815   <- angle 5  (bm=3 LAST cell of block)
cell 6 cat=0x0b bm=0 bt=0 first=156816 ...          <- common ending (NOT an angle cell)
```

Cell category byte@0: `block_mode=[7:6]` (0 not-in-block, 1 first, 2 in, 3 last),
`block_type=[5:4]` (1 = angle block). So the **angle count = the run of `bt=1` cells**
(here 5) and the angle-N cell = `block_first + (N-1)`; its `first_sector` is angle N's
first ILVU. **The sibling angle cells must be SKIPPED in normal program flow** — after the
chosen angle finishes you advance to `block_first + angle_count` (cell 6), never cell+1.

Within the chosen cell the ranges OVERLAP the whole block (angle 1 = RBN 0..155664 which
physically contains all 5 angles), so linear streaming = garbage. You must **follow the
ILVU chain**: each VOBU's DSI (`sml_pbi.category` ILVU flags + `sml_agli.data[9]`) says
whether it is the **last VOBU of an ILVU** and where the current angle's **next** ILVU is.
From the real fixture (`bench/dvd/test_vobs/mib_angle_dsi.hex`, RBNs 0/20/37 = angle-1 ILVU
#1, a 3-VOBU unit):

```
RBN  0 cat=0x6000 [BLOCK|FIRST] vobu_ea=19   agli: a1->971 a2->1308 a3->1638 a4->1968 a5->2298
RBN 20 cat=0x4000 [BLOCK]       vobu_ea=16   agli: a1->971 ...(same absolute targets)
RBN 37 cat=0x5000 [BLOCK|LAST]  vobu_ea=160  agli: a1->971 a2->1308 a3->1638 a4->1968 a5->2298
```

`target = nv_pck_lbn ± (sml_agli.data[angle-1].address & 0x3fffffff)` (bit31 = sign,
`0x7fffffff` = none) — faithful to **libdvdnav `dvdnav.c` ~L452-468**, which fires the jump
**only** at `(category & 0xF000) == (BLOCK|LAST)`. Note the per-angle target is *constant
within an ILVU* (0+971 = 20+951 = 37+934 = **971**); the ILVU ends at
`nv_pck_lbn + vobu_ea` (37+160 = **197**), and RBN 198 is angle 2's first ILVU. So playing
angle 1: stream 0..197, jump to 971, stream that ILVU, jump again, … bounded by the cell's
`last_sector` (155664).

### Why the parse must live in the reader (not emu/`nav_dsi`)

The downstream `nav_dsi` sits at the **ps_demux output** — after the reader's 16 KB cache —
so it LAGS the reader's *fetch* pointer. In an interleaved cell the reader free-runs the
*contiguous* RBN range (= all angles), so by the time `nav_dsi` reported `ILVU_LAST` the
reader would already have pulled the wrong angle into the cache/decoder, and it never
starts clean. libdvdnav avoids this by reading one VOBU at a time and parsing its nav pack
**before** choosing the next read. The fabric equivalent: **the reader self-parses the
NV_PCK at the fetch pointer.** The DSI sits at the fixed offset **`0x407`** in every
2048-byte NAV sector (a NAV pack = the VOBU's first sector, identified by `00 00 01 BF` at
`0x26`), so the reader **snoops the needed fields off the `sd_buff` write stream** as it
caches the sector (contention-free — piggybacks on the existing cache write, no cache
read-port fight):

- `category`  @ sector `0x427` (`= 0x407 + 0x20`, u16 BE) → `ilvu_last`
- `vobu_ea`   @ sector `0x40F` (u32 BE) → ILVU end = `sector_rbn + vobu_ea`
- `sml_agli[cur_angle-1].address` @ `0x4BB + 6·(cur_angle-1)` (u32 BE) → jump offset

`nav_dsi.category` is still added (cheap) but only feeds a UI "angle" indicator and the
golden cross-check — it does **not** drive the fetch.

### Reader mechanism (`dvd_iso_reader.sv`)

1. **Cell category** `@0` is captured into `cell_cat_mem` (sync-read M10K, like
   first/last/meta). On loading a cell with `block_type==1 && block_mode==1` (angle-block
   first cell) the reader computes `angle_block` extent (`block_first`, `angle_count` =
   run of `bt=1` cells) and loads `block_first + min(cur_angle,angle_count) - 1` instead.
2. **ILVU follow** while streaming an angle-block cell: snoop each cached NAV sector; on a
   `BLOCK|LAST` VOBU whose jump `target ≤ cell.last_sector`, arm `ilvu_jump` to fire when
   `play_blk` reaches the end of that VOBU (`ilvu_end_rbn`). The jump reuses the extent
   remap (`S_CELL_SEEK` with `seek_target = target·4`) but keeps `cell_i`/`play_end` and
   pulses **`keep_vbuf` (no flush) + no `seek_ack`** → the timeline is continuous
   (`av_sync` untouched). If `target > last_sector` (or no `sml_agli` entry) there is no
   jump — `play_end` bounds the final ILVU and the cell ends normally.
3. **Block skip**: an angle-block cell's end advances to `block_first + angle_count`
   (the common cell 6), skipping the sibling angle cells.
4. **Angle switch**: `angle_pulse` (emu B6) increments `cur_angle` (wrap 1..`angle_count`);
   it takes effect at the **next ILVU boundary** (the jump reads `cur_angle` live), so the
   switch is seamless. Outside an angle block the pulse just updates the number for the UI.
5. **Exposed**: `cur_angle` / `angle_count` (0 when not in an angle block) → emu status/UI.

Non-interleaved cells and all earlier phases are byte-for-byte unchanged (the snoop +
angle-cell logic is gated on `block_type==1`). Golden tool: `tools/nav_extract.py --angles
--title-vob 1` (ILVU flags + per-angle target map). Tests: `bench/dvd/iso_reader_angle_tb.sv`
(synthetic 2-angle interleaved block with distinct per-angle marker bytes — proves only the
selected angle streams, in order, and a clean mid-block switch) + the real MiB fixture for
byte-exact target math, plus `nav_dsi_tb` category assertions; all reader/demux/nav suites
stay green.

## In-title MULTI-button menus — DVD-game discs (Scene It) — ⏳ HW-confirm pending (`feature/scene-it-menu-nav`)

> **The big Scene It fix.** Scene It (and the other DVD-game discs) author their ENTIRE
> interactive game — main menu, ring-select, timer, yes/no, submenus — as **in-title HLI
> multi-button menus in the TITLE domain** (not the menu/VMGM domain). The white-rabbit
> support below only handled a *single* auto-selected in-title button riding a movie, so
> these multi-button game menus had no D-pad walk: left/right scrubbed (HUD/seek) and the
> highlight couldn't be moved = the user's "behaves like a video, no highlights".

**Disc map (decoded with `tools/bin/trace_nav`, the new scriptable libdvdnav button tracer —
`trace_nav <iso> "5"` presses main-menu button 5 and dumps the next screen's domain/PGC +
every button rect+cmd):**

| Screen | Domain | Buttons | Button command shape |
|--------|--------|---------|----------------------|
| Main game menu = VTS3 **Title 6 / PGCN 18** | **title** | 6 (fosl=2) | `SetGPRM g[15]=N; LinkTailPGC` (POST dispatches) |
| Ring-select ("which ring 1/2/3") = **Title 36** | **title** | 3 (fosl=0) | `SetGPRM g[13]=0x400/0x800/0xc00; LinkTailPGC` |
| Submenu (btn1) = **Title 37** | **title** | 5 | `LinkPGN` / `CallSS VMGM` |
| btn2 → **VMGM PGCN1** | menu (title=0) | 13 | `JumpTT` game modes — this one already worked via `menu_nav` |
| btn5 → **Title 33** tutorial (3 parts) → VMGM 6-btn menu | title→menu | — | "How to Play"; ends at a menu (our core loops the video = issue fj#8, HW-observe) |
| Menu key → VMGM 1-btn message | menu | 1 | `LinkPGCN 2` — the "random not supported" screen (issue fj#3, likely authored) |

**Fix (`emu.sv`):** a third nav mode alongside `menu_nav` (menu domain) and the single-button
white-rabbit path — `in_title_menu = in_title_hli && (hl_btn_ns > 1)` (button count from
`nav_pci.dbg_btn_ns`, now wired). When set: the D-pad walks the button link graph via `nav_pci`
(same feed as `menu_nav`) + Select activates, and the scrub/chapter/angle/pause-on-L-R transport
is suppressed so left/right walks buttons instead of seeking. `btn_ns==1` stays the white-rabbit
case (scrub + Select-only) so Matrix is unaffected. The highlight subpicture is forced to stream 0
+ windowless (`menu_mode`) like a menu-domain menu so the selected-button highlight renders.

**Boot ordering (issues #1/#2) is NOT a bug:** `tools/dvd_vm_ref.py runboot` (new full-playback
driver) parks on PGC18 (main menu) matching libdvdnav; the pre-menu "actor" clip is short
authored VTS3 intro (2/11/7/19s), never a question VTS. See the `scene-it-in-title-hli-menus` memory.

**Open (HW-observe in the batch test):** #3 Menu→"random not supported" (menu_call lands on an
authored VMGM message screen — same path libdvdnav takes; now dismissible with the fix); #8
How-to-Play video loops instead of ending at its VMGM menu (Title 33 POST/JumpSS — confirm on HW).

## In-title PCI/HLI buttons — Matrix "Follow the White Rabbit" (PR fj#113) — ✅ HW-CONFIRMED 2026-07-12

> **HW verdict (2026-07-12, `DVD_rabbit_20260712_1009.rbf`, SEED 9):** WORKS end-to-end — the
> rabbit icon renders + highlights, Select plays the featurette, and it returns to the movie.
> The transport-HUD-pops-on-featurette-enter/return follow-up is ✅ FIXED + HW-CONFIRMED (PR fj#114:
> HUD status line auto-shows on user gamepad transport only, not VM-driven clip starts). MiB
> visual-commentary annotation art is still not drawn (the "set to 4:3" warning shows) — tracked
> separately.

Full anatomy of the white-rabbit feature, measured on the real disc (all numbers verified with
`tools/nav_extract.py` / `tools/iso_nav_check.py`). The rabbit is **not** an in-title button on
the movie you are watching — it is an entire **alternate branch** you switch to.

**Path to the rabbit:**
1. The disc menu's "Follow the White Rabbit" button runs `JumpVTS_PTT(ttn=6)`.
   `VTS_02 VTS_PTT_SRPT`: **TTN 6 → PGCN 6**. So the rabbit version of the movie is **PGCN 6**
   (`pgc_cat=0x86`, 106 cells), distinct from the plain movie PGCN 1. Our reader already has the
   `jump_ttn`/`jump_pgn` primitive + the VM executes JumpVTS_PTT, so this path exists.
2. PGCN 6's interleaved cells start at the **sibling ILVUs** (e.g. 68180) that PGCN 1 skips —
   these carry the HLI rabbit buttons. With the ILVU `next_vobu` follow (PR fj#112) PGCN 6 now
   plays its branch **cleanly** (before PR fj#112 it played garbled linear-interleave = the user's
   "white on white, no rabbit").
3. PGCN 6 pre-command 3 = **`SetSTN SPSTN=0x41`** → enables subpicture **logical stream 1**.
4. The rabbit HLI button (`tools/nav_extract.py --cmds` @ a sibling NAV pack): 1 button, rect
   **x519..579 y349..434** (lower-left), `btn_coli sel=eeee00f0` (the graphic is invisible
   except via the HLI highlight colour), command **`SetGPRM g[9]=1; LinkTailPGC`** → the PGC
   POST commands `CallSS VMGM (pgc 10..18)` based on `g[9]` → the behind-the-scenes featurette.

**What is done (this branch):**
- **Render un-gate** (`emu.sv`): `in_title_hli = menus_on && !menu_active && hl_btns_armed`
  feeds `sp_route_en` so an in-title armed HLI routes its button subpicture (the highlight
  recolour path `hl_use` is already menu-independent). NB the `SetSTN` also routes it via the
  existing `vm_owns_sp` path.
- **Activation** (`emu.sv`): in-title **Select** pulses `nav_act_p` (the rabbit is a single
  `fosl=1` auto-selected button, so no D-pad nav needed — D-pad stays chapter/scrub);
  `nav_pci → hl_btn_cmd → dvd_vm` then runs the button commands.

**Subpicture display-mode substream mapping (IMPLEMENTED).** `SetSTN` selects *logical* stream 1,
but the rabbit graphic rides *physical* substream **0x22/0x23**, and `ps_demux` matches
`substream_id[2:0] == sp_track`; with the raw logical value (1) it found nothing. DVD maps
logical→physical via `pgc->subp_control[subpN]` (32-bit @ PGC offset **0x1C + subpN*4**) by video
display mode (libdvdnav `vmget.c vm_get_subp_stream`): `present = ctl>>31`; 4:3 = `(ctl>>24)&0x1f`;
16:9 wide = `(ctl>>16)&0x1f`; 16:9 letterbox = `(ctl>>8)&0x1f`; 16:9 pan&scan = `ctl&0x1f`;
substream = `0x20 + streamN`. Verified: Matrix PGCN 6 `subp_control[1]=0x80020300` → **wide=0x22,
letterbox=0x23** (video aspect 16:9). Golden tool: `tools/nav_extract.py --vts 2 --subp-map 6`.
  - **Reader** (`dvd_iso_reader.sv`): a `P_SUBP` walk phase (title PGCs only) parses
    `subp_control[0..15]` (PGC @0x1C, 64 B) and streams it out (the palette-streaming
    pattern) BEFORE the @156 `P_HDR` walk (`bench/dvd/iso_reader_subpctl_tb.sv` proves
    the capture). **2026-08-27 (`fix/menu-link-audio-map`): the bus is now the shared
    `pgc_ctl_we/waddr[4:0]/wdata`** — waddr 0–15 = these subp words (unchanged), waddr
    16–23 = **`audio_control[8]`** (PGC @0x0C, u16 in wdata[15:0]), parsed by a new
    `P_ACTL` phase that runs FIRST in **every** domain (the two tables are contiguous,
    so a title PGC rolls from P_ACTL into P_SUBP with no re-seek; menu/FP re-seek to
    @156 as before). Plus `pgc_ctl_valid` (all 8 audio words landed; cleared at
    S_PGC_HDR) and `pgc_dom_tt` (the loaded PGC's domain). This is the audio sibling of
    this subpicture mapping — `dvd/aud_stream_map.sv` resolves the logical audio pick →
    physical substream (libdvdnav `vm_get_audio_stream`); full design + the
    silence-bug story in `docs/track_selection.md` "Logical→physical audio mapping".
  - **emu** (`emu.sv`): `subp_ctl_mem[16]` BRAM; for the VM-selected stream computes the display
    mode (`status[4:3]`: Crop→pan&scan, Letterbox→letterbox, else wide — 16:9 "Fit"/HDMI → wide
    → 0x22 is the common case, HW-tunable) and drives `sp_track_eff = mapped_streamN[2:0]`. The
    user subtitle path is unchanged **unless `Force 4:3 Subpics` (P1O[15]) is on** — see that
    section below, which extends this same mapping to the gamepad-selected stream.
- **Featurette jump + return** (likely works via the VM): `LinkTailPGC → POST → CallSS VMGM
  (pgc = 9+g[9]) → RSM`. To confirm on HW once the button renders + activates.

**HW test (once the mapping lands):** O[1] Disc Menus on → menu → "Follow the White Rabbit" →
movie plays (PGCN 6) → rabbit icon (lower-left) renders + highlights at the 9 chapter points →
Select jumps to the featurette → returns.

## Force 4:3 Subpics override — MiB "visual commentary" (`P1O[15]`) — ✅ HW-CONFIRMED 2026-07-12 (PR fj#115)

Some discs author **different subpicture content per display mode** on the SAME logical stream.
The motivating case is the **Men in Black "visual commentary"** (VTS_21, subpicture logical
stream 3): `subp_control[3] = 0x80030400` → **16:9-wide → physical 0x23**, **letterbox → 0x24**,
4:3/pan&scan → 0x20. Measured with `tools/spu_dump_iso.py --vts 21 --sub 0x23/0x24` +
`tools/nav_extract.py --vts 21 --subp-map 1` (see memory
`mib-visual-commentary-letterbox-substream`):
- **0x23 (wide)** = one 4934-byte SPU repeated every VOBU = a persistent yellow warning:
  *"In order to properly view the video commentary you must set your DVD player to 4x3 display
  mode. Consult your DVD player manual for specific instructions."*
- **0x24 (letterbox)** = the actual art: the yellow **silhouettes of the two commentators** at
  screen bottom (MST3K-style) + telestrator annotation strokes (162 distinct SPUs).

So a 16:9 (anamorphic / HDMI) player — ours **and VLC** — correctly shows only the warning; this
is authored behaviour, not a decode bug. To reveal the art the player must present as a
**4:3/letterbox** display so the subp_control mapping selects **0x24**.

`P1O[15] Force 4:3 Subpics` (Debug submenu, default Off) does exactly that (`emu.sv`
`force_43_subp`):
1. Forces `sp_disp_mode = letterbox` in the subp_control mapping (→ picks the `[12:8]` field
   → 0x24 for MiB logical 3), overriding the O[4:3]-derived mode.
2. **Extends the mapping to the USER (gamepad B8) subtitle path** — previously the white-rabbit
   mapping was VM-selected-streams only. Now `sp_user_phys` runs the same
   `subp_control[sp_user_log]` display-mode resolve so a user-selected commentary track (MiB
   logical 3) resolves to 0x24 instead of 0x23. The 3-bit `ps_demux substream_id[2:0]` match
   stays unambiguous (active substreams 0x20/21/22/23/24 → 0/1/2/3/4). Off = byte-identical.

**The art is a FLIPBOOK, not a static overlay (HW round 1, 2026-07-12).** Measured on 0x24:
**~15 SPUs/second** (250 units in 16.5 s), each `STA_DSP`-only with **zero `STP_DSP`** — a
persistent-frame animation where each frame replaces the previous (vs 0x20/0x21/0x22 normal
subtitles at ~0.3/s WITH show+hide windows). `spu_decode`'s non-menu path gates display on
`stc >= c_show && stc < c_hide`, but `c_show` is the demux **parse-front** PTS, which leads the
displayed frame by the VBUF depth; at 15 fps it's overwritten ~15× before the STC reaches any
given frame, so the window never opens → **nothing animates** (a track switch resets `c_valid`
and briefly shows one stale frame — the "still figures" symptom). Fix: Force 4:3 Subpics also
drives `spu_decode.menu_mode` (WINDOWLESS display — show the committed frame until the next
replaces it), the same lead-compensation menus already use. **HW-CONFIRMED 2026-07-12: the animation plays
well** — the theorised mid-decode frame-skip (the FSM only re-arms in `S_IDLE`) is not visible
in practice at 15 fps, so the double-buffer follow-up is unnecessary.

**Caveat — geometry:** the silhouettes are drawn for a letterboxed 4:3 frame (they sit at
y≈360–479, i.e. in the bottom black bar). On the anamorphic HDMI output (full-height 16:9) they
overlap the bottom of the picture; for correct framing combine with a **letterbox OUTPUT** mode
(CRT `O[4:3]=Letterbox`). Revealing the art (subpicture selection) and re-framing the picture are
separate concerns; this toggle only does the former.

**HW test:** MiB, play VTS_21, enable audio commentary (B7) + subtitle stream 3 (B8) → warning
shows; turn on `Debug → Force 4:3 Subpics` → the commentator silhouettes + annotations appear
(substream 0x24). Off → warning returns. Any 4:3-authored disc is unaffected (`!ar_wide_auto`
path uses the 4:3 field regardless).

## Seamless-branch interleaved blocks (PR fj#112) — ✅ HW-CONFIRMED 2026-07-12

> **Status: ✅ HW-CONFIRMED 2026-07-12 (PR fj#112).** Playback of the Matrix white-rabbit chapters
> and T2 extended scenes is smooth on real hardware — the skipping is gone at the problem spots.
> This closes the long-standing Matrix "skipping" and T2 "extended-scene stutter" that were
> previously (wrongly) filed as "bad-rip source / compute-bound".

**The symptom & root cause.** Matrix's "Follow the White Rabbit" chapters (1, 10, 15, 23, 24,
29, 30, 32, 33) and T2 Ultimate's extended scenes played back with a rhythmic **skipping**.
Decoding the PGC cell table (`tools/nav_extract.py --ilvu`, `tools/iso_nav_check.py`) shows the
truth: these are **seamless-branch interleaved blocks**. The affected cells carry the cell
category **`interleaved` bit** (byte0 **bit 2**) with `block_mode=0`/`block_type=0` — **NOT**
the multi-angle `block_type==1` encoding the Phase-9 machinery was gated on. Matrix VTS_02
PGCN 1 has **9 interleaved cell-pairs** (one per white-rabbit chapter); T2 VTS_01 PGCN 1 has
**35** interleaved cells. Each cell's `[first..last]` range physically **interleaves this
branch's ILVUs with sibling-branch (other-TTN) ILVUs**; the reader's linear `play_blk+1` walk
read main-ILVU/sibling-ILVU/main-ILVU = the skipping. (This also explains VLC skipping on the
same chapters — reading the VOB without ILVU navigation hits the identical interleave; the
earlier "VLC repros ⇒ bad rip" inference was wrong.)

**The follow pointer: `vobu_sri.next_vobu`, NOT `sml_agli`.** Traced live on both discs
(following `next_vobu` from each cell's `first_sector`): at a `BLOCK|LAST` VOBU (`category &
0xF000 == 0x5000`) **`sml_agli` is empty** — it is a multi-angle-only field. `next_vobu`
already points **past** the sibling ILVU to this branch's next ILVU (Matrix cell 4: RBN 68018
LAST, `next_vobu = +654` → RBN 68672, skipping sibling `[68180..68671]`). This is libdvdnav's
**default** `vobu_next` path (`dvdnav.c:434`); the `sml_agli` special-case there is gated on
`num_angle != 0`, which doesn't apply to a single-branch seamless title. `next_vobu` is
**always forward** — bit 31 is the SRI "valid" flag, **not** a sign bit (unlike the angle
`sml_agli` address).

**Reader mechanism (`dvd_iso_reader.sv`)** — reuses the Phase-9 snoop→arm→jump wholesale:

1. `cc_interleaved = cc_rd[2]`; `seamless_active <= cc_interleaved && !cc_is_angle` set at
   `S_CELL_LOAD` (interleaved cells fall through to the title path — `cc_blk_first` needs
   `cc_is_angle`). `ilvu_active = angle_active || seamless_active` gates the NV_PCK snoop.
2. The snoop additionally captures `vobu_sri.next_vobu` (DSI-rel 0x13A → sector 0x541 →
   block-2 offset 0x141). On a `BLOCK|LAST` VOBU in a seamless cell, arm the jump with
   `ilvu_end_rbn = snoop_rbn + vobu_ea` (= `first_ilvu_end_sector`) and
   **`ilvu_target = snoop_rbn + (next_vobu & 0x3fffffff)`** (forward, valid unless
   `== 0x3fffffff` = SRI_END_OF_CELL) when `target ≤ cell.last_sector`.
3. The fire path is shared; for the seamless case it **stays on the same cell**
   (`cell_raddr <= cell_i`, no angle re-point), reloading via `rbn_override` — **no VBUF flush,
   no `seek_ack`, no A/V re-anchor** (time-continuous, like the angle jump). When
   `next_vobu == END_OF_CELL` no jump arms and the cell's final ILVU tail plays to `last_sector`
   linearly; cell-to-cell advance stays linear (`cell_i+1`, no sibling-cell skipping).

**Golden tool:** `tools/nav_extract.py --vts N --ilvu` follows each interleaved cell's chain
and prints ILVUs / jumps / played / skipped(sibling) / `nav_ok` (validated on Matrix VTS_02 +
T2 VTS_01: every cell reaches END_OF_CELL). **Test:** `bench/dvd/iso_reader_ilvu_tb.sv`
(synthetic interleaved block with distinct branch-A vs sibling-B marker bytes — proves the
reader follows `next_vobu`, streams only branch A, and skips every sibling ILVU). All existing
reader/angle/nav/demux suites stay green (the new path is gated on the `interleaved` bit, so
angles and normal titles are byte-for-byte unchanged).

**HW verdict (✅ 2026-07-12):** Matrix white-rabbit chapters + T2 extended scenes play smoothly
at the problem spots (skipping gone). Confirmed on real hardware.

**Not in scope (deferred, separate feature gaps that share the "in-title, not menu" theme):**
the in-title PCI/HLI **button highlight** (the white-rabbit *icon* itself; `nav_pci` arms
in-title but the subpicture-graphic plumbing in `emu.sv` is menu-gated → renders "white on
white"), and the transport-HUD-overlaps-subtitle bug (MiB visual commentary).

## Known limitations / later phases

- **UDF-only images** land on the flat-file fallback today (which would play
  garbage). A UDF parser is the v2 fallback for raw disc images; until then, author
  ISOs with genisoimage/MakeMKV (ISO9660 guaranteed).
- **PGC cell timeline: v1 = cell-ordered playback only** (`feature/pgc-cell-timeline`,
  sim-verified — HW pending). The reader now streams the selected title's PGC **cells in
  program order** (Phase 7), but the following build **on top** of it and are still deferred:
  - **Exact TTN→PGC map:** v1 plays the **first PGC** (PGCN 1). The precise title-number →
    PGC map is in `VTS_PTT_SRPT` — a refinement for multi-PGC VTSes.
  - **Chapters/seek (Phase 8): ✅ HW-CONFIRMED (PR fj#96) — see "Seeking / Phase 8"
    above.** Chapter skip (B2/B3) resolves the PGC `program_map`@230 in a reader BRAM;
    time scrub (D-pad L/R) consumes the DSI fwda/bwda seek tables (±10 s = fwda[3]/bwda[15])
    → a raw-RBN seek. (Phase-8b absolute-timestamp scrub-bar: RETIRED 2026-07-10, user decision.)
  - **Angles (Phase 9):** DSI `sml_agli` per-angle offsets are now parsed into `dsi_tbl`;
    the cell category word @0 (block_mode/block_type) selects the angle block. v1 still plays
    cells in table order (angle 1 / no interleaving assumed) — Phase 9 follows the ILVU chain.
  - **Subtitle palette:** the PGC `palette`@164 (16×4 B) — the hook for the subpicture
    feature to use IFO colours instead of the built-in fallback.
  - **`MAXCELL=128`** cap and a straddling PGC header / bad pointer / `nr_of_cells==0` all
    funnel to the **linear whole-VTS fallback** (plays everything, just not reordered).
- **Which title** is still IFO TT_SRPT title 1 (or largest-VTS fallback); title 1 isn't
  *always* the main feature (rare authoring, e.g. Big Buck Bunny) — a manual OSD title picker
  remains a follow-up. The PGC timeline fixes ordering *within* the chosen title, not the
  choice of title.
- **Multi-extent ISO9660 files / extended attribute records** are not handled; DVD
  VOBs don't use them (verified on the real discs above), but a non-standard image
  could trip the parser.
- **`iso_error` not yet on the overlay** (see HW test plan step 4).
- The 2 KB `parse_buf` is async-read distributed RAM (a few MLABs); the extent
  table is ≤64 entries of `{start,blocks}`. Nav logic sits at the pipeline front
  (streamer/memory region), away from the congested decoder→overlay hotspot.

---

## Authored cell duration ("real-player cell timing")

> **Phase-6 widening (2026-08-19, `feature/cell-duration-clamp`):** the whole
> duration chain is 16-bit to the C_PBTM spec max 9:59:59 = 35,999 s (was an
> 8-bit 255 s clamp; any-hours BCD clamped too). The cell-meta word is 33 bits
> `{heur, pb_secs[15:0], still, cmd_nr}`; heuristic stills carry a flag so the
> timed hold uses the full duration (their still BYTE clamps at 254, also
> fixing the 255→indefinite alias). `iso_reader_celldur_tb` T5–T7.

**Status: ✅ HW-CONFIRMED 2026-08-18 (PR fj#165).** Weakest Link's questions hold for the
authored time and are answerable; no regressions on the other menu discs. (WL's questions
are NOT random — a separate, pre-existing issue: it joins the Cluster-B entropy family in
`docs/disc_sweep.md`, alongside Brain Game / Family Feud II.) Motivated and fully
diagnosed by the Weakest Link answer-window bug; evidence and the failed alternatives are
in `docs/disc_sweep.md` "Round-6". User decision: implement it **the way a real player
does**, i.e. the general model below — not a single-frame special case. Implementation
summary at the end of this section.

### The defect

`dvd_iso_reader.sv` ends a cell when its **sectors have been delivered**. That is not what a
cell is. **A DVD cell's presentation lasts its authored playback time (`C_PBTM`)**, and it
ends when that time has elapsed *on the display timeline*.

For ordinary cells the two nearly coincide (the display trails the parse front by the VBUF
depth, and the `vbuf_empty` gate bridges it). For a **still-image cell they diverge totally**:

> Weakest Link, VTS 8 PGC 51, cell 0 — the quiz answer window.
> 311 sectors, `pbtime = 17 s`, `still_time = 0`, and the video ES contains
> **1 picture header / 1 GOP header** (64,837 bytes). One I-frame, authored to be held for
> 17 seconds. We delivered it in ~0.2 s, saw "cell done", ran the cell command and jumped to
> the timeout branch **1.5 s** after the question appeared.

Note the trap that burned two rounds: **`vbuf_empty` is genuinely TRUE here** (one frame
decodes instantly), so the Phase-B tail-drain gate passes immediately. Raising `DRAIN_WD`
cannot help. Do not re-try that.

### The model to implement

1. A cell's end is **`C_PBTM` elapsed on the display timeline**, not data exhaustion.
2. When content runs out before that, **hold the last decoded frame** until the authored time
   elapses, then run the cell command / advance.
3. The clock must be **display-referenced**. Use the displayed-frame tick the governor already
   produces (`refresh_tick` / `core_v_sync`, the same reference `av_sync` uses to advance the
   STC) — **never** clk_sys wall time and **never** the parse front. This is the standing
   lesson from the lip-sync saga (`docs/av_sync.md`).

### Where the pieces already are

| Piece | Location |
|---|---|
| Per-cell authored duration | **already captured** as `pt_c` (BCD `hh mm ss rate\|frames`) at `cell_bi == 5'd4..7`, [dvd_iso_reader.sv](../dvd/dvd_iso_reader.sv) ~L1281. Currently only prefix-summed into `cell_start_mem` for the HUD — **add per-cell storage** (a `cell_dur_mem`, or widen `cell_meta_mem`). |
| BCD arithmetic | `dvd/bcd_time_add.sv` (rate-aware frame carry, 508 vectors green) |
| Freeze/hold machinery | `still_secs` / `still_timed` / `still_pend` / `S_STILL` / `still_next` / `STILL_CMD` — the PR fj#90 + PR fj#144 timed-still path, already HW-proven on Thayer's Quest |
| Decoder freeze without a watchdog reset | `mpeg2video.freeze_wd` (the menu-still hold) |
| Where "cell done" is decided | the `strm_done` / cell-end branch chain, [dvd_iso_reader.sv](../dvd/dvd_iso_reader.sv) ~L3248–3310 |

### Risks to design against

- **Seamless branching / ILVU and angle blocks** — interleaved cells must not gain a hold
  (memory `seamless-branch-ilvu-navigation`, PR fj#112).
- **`pbtime == 0` or malformed** — fall back to today's behaviour, never wedge.
- **Ordinary playback must not hitch** at cell boundaries. For a normal cell the authored time
  has all but elapsed when data runs out, so the hold should be a no-op or ~the same wait
  `vbuf_empty` already imposes.
- **The HUD/chapter prefix sums** (`cell_start_mem`, `nav_dsi` `c_eltm`) must stay consistent.
- **Trick play** — user seeks/chapter skips must remain immediate (the `nat_src` provenance
  discipline from PR fj#150 applies).

### Verification

- New reader TB case: a cell whose `pbtime` greatly exceeds its data (the WL shape) holds for
  the authored time, then runs its cell command.
- Regression: `iso_reader_{,menu_,seek_,chapter_,real_,vm_}tb`, `dvd_vm_tb`, `dvd_vm_atmos_tb`.
- HW gate: **Weakest Link** — the question holds ~17 s and is answerable; **Thayer's Quest**
  timed choices unchanged (PR fj#144); **MiB/Matrix** menus and a normal movie unchanged.

### How it was implemented (2026-08-18)

All in `dvd/dvd_iso_reader.sv` + a two-port emu hookup; **zero new FSM states** — the
residual is served through the existing HW-proven timed-still machinery (PR fj#90/#144).

- **Per-cell duration storage:** `cell_meta_mem` widened 16→24 bits to
  `{pb_secs, still_time, cell_cmd_nr}`. `pb_secs` is the already-computed `pb_c` (C_PBTM
  → binary seconds, clamped 255) captured during the P_CELL walk — no new memory, no new
  converter. `cm_rd[23:16]` reads it back for the playing cell.
- **Display-referenced elapsed clock:** new reader inputs `disp_tick` (emu: the same
  `core_v_sync`-edge pulse `av_sync` advances the STC with) and `disp_fps` (emu resolves
  60/50/24/25 incl. the Film rasters). `cell_secs` counts saturating display seconds since
  the cell's `S_CELL_LOAD` entry; an `rbn_override` entry (raw-RBN scrub, ILVU hop,
  mid-block angle switch) sets `cell_partial` instead of resetting, disabling the hold for
  that cell (a mid-cell entry breaks the "elapsed since load" measurement).
- **The hold:** at CELL FINISHED, `dur_hold = vm_mode && !menu_dom && !angle_active &&
  !seamless_active && !cell_partial && dur!=0 && cell_secs<dur && (dur-cell_secs)>=2`.
  It applies ONLY on the two cell-end paths that dispatch to the VM — the **cell-command**
  path (`still_next=STILL_CMD`: the command evaluates SPRM8 etc. at the cell's *authored*
  end, which is the WL semantics) and the **PGC-end** path (`still_next=STILL_PGEND`,
  which inherits the Phase-B tail drain before POST). The residual `dur - cell_secs` loads
  `still_secs`; drain → `S_STILL` → 1 Hz countdown → deferred dispatch. Buttons stay armed
  through the hold and a user activation exits early via `jump_go`, exactly like Thayer.
- **Why the plain mid-PGC advance is untouched:** there the parse front *leads* the
  display by the buffered VBUF depth by design, so "authored time not yet elapsed since
  load" is the normal steady state of seamless playback, not a still — holding would
  drain the pipe and hitch every flush-entered cell boundary. On the two VM-dispatch
  paths the same lead means the countdown runs concurrently with the decoder playing out
  its buffered tail (the still freeze is watchdog-suppression only), so a normal video
  cell's hold converges on the same wait the `vbuf_empty` tail-drain already imposes.
- **`RESID_MIN = 2 s`** absorbs load→display latency and sub-second truncation; cells
  whose rounded authored duration leaves under 2 s unspent stay instant.
  ⚠️ *This bullet used to read "WL's 1-second answer-branch cells … stay instant" as if
  that were correct. It was the bug fixed on 2026-08-25 — see the amendment below: those
  cells are not 1-second cells.*
- **Known limitations:** durations clamp at 255 s (`pb_c`) and `cell_secs` saturates to
  match, so a >4 min still-shaped cell holds at most ~4 min (no real disc authors this);
  the elapsed clock keeps counting through a user pause (raster keeps ticking — parity
  with the existing still countdown); under a Film 24p/25p raster `disp_fps` tracks the
  reduced tick rate.
- **Tests:** `bench/dvd/iso_reader_celldur_tb.sv` — T1 the WL shape (17 s hold, command
  deferred, `still_secs==17`); T2 timeout → command → advance, with a monitor proving the
  plain cell1→cell2 advance never raises `still_active`; T3 delivery stalled while 6
  display-seconds tick → hold is the residual 4 s only; T4 PGC-end hold then POST.
  Cross-checked against the real disc: WL VTS 8 PGC 51 cell 0 reads
  `pbtm 0:00:17, still=0, cmd=1, 311 sectors` (matches Round-6 exactly).

### Amendment (2026-08-25) — the C_PBTM FRAME FIELD: short screens flashed by

**Status: ✅ HW-CONFIRMED 2026-08-25** (user report: "the hold durations are correct now",
`DVD_celldurfrm_MARGINAL` build; branch `fix/cell-duration-frames`).

**Symptom.** On Weakest Link the questions held for the authored time (the fix above
works), but the **correct/wrong answer reveal** after choosing an answer, and the
**"money banked"** screen after pressing Bank, both flashed past in well under a second
where a real player shows them for about two.

**Root cause — half of the authored duration was never read.** `C_PBTM` is a BCD
`dvd_time {hh, mm, ss, rate|frames}`, and `pb_c` (the value stored per cell and used as
the hold source) summed **hh:mm:ss only**, discarding the frame field. Interactive discs
author their short screens as *"N seconds + (fps−1) frames"* — i.e. N+1 seconds minus one
frame:

| screen | disc location | C_PBTM | real length | stored (before) |
|---|---|---|---|---|
| answer reveal | VTS 18 PGC 29 cells 1–6 | `0:00:01` + **24 f** @25 fps | **1.96 s** | 1 s |
| money banked | VTS 02 PGC 248 cell 0 | `0:00:01` + **24 f** | **1.96 s** | 1 s |
| chain/bank status | VTS 02 PGC 1381 cells 0–6 | `0:00:03` + 23 f | 3.92 s | 3 s |
| question (works) | VTS 18 PGC 29 cell 0 | `0:00:17` + 23 f | 17.92 s | 17 s |

Every one of these cells is **a single I-frame** (`pics=1 gops=1` over the whole cell —
same shape as the Round-6 question cell), so the authored duration is the *only* thing
holding them on screen. With 1.96 s stored as 1 s the residual was 1 s, which is **under
`RESID_MIN` (2 s)** — so no hold was served at all and the frame flashed by in the time
the pipeline needed to decode it (~0.2 s). The 17 s question cleared `RESID_MIN` easily,
which is exactly why one worked and the other did not. Both this disc's screens are also
reached by a **user button press**, which is what made them look like a provenance /
tail-drain problem; they are not — the same cells flash on any path.

**Fix.** The frame field is rounded into the stored duration (`pb_dur_w` at the cell-meta
write): 1 s + 24 f → 2, 3 s + 23 f → 4, 17 s + 23 f → 18. Rate bits pick the threshold
(2'b01 = 25 fps → ≥13 frames rounds up, otherwise ≥15).

Deliberate scope limits, both load-bearing:

- **`pb_c` stays truncated for the libdvdnav still HEURISTIC** (`heur_hit_w`, the
  `size/time > 30` test) — that code is a port of `vm.c get_current_position`, which
  truncates, and `tools/iso_nav_check.py` mirrors it. Only the *hold* uses the rounded
  value.
- **`RESID_MIN` stays 2 s.** With rounding a genuine 2 s screen now qualifies, while
  sub-second cells (`0 s + n f`) round to 1 and still take no hold — Deal or No Deal
  alone authors ~1,800 half-second cells, and lowering the threshold would give every one
  of them a ~0.4 s freeze they do not have today.

**Residual imprecision (accepted, documented):** the hold countdown is 1 Hz, so a hold is
quantised to whole seconds — ±0.5 s worst case, +40 ms on the "N s + (fps−1) f" shape
that dominates real discs. Frame-granular holding would need a sub-second countdown in
`S_STILL` and a wider `cell_meta_mem`; not worth it until a disc shows a symptom.

**Tests:** `bench/dvd/iso_reader_celldur_tb.sv` T8 (1 s + 24 f holds 2 s — the reveal
shape), T9 (1 s + 2 f stays 1 s, monitored so it never holds), T10 (3 s + 23 f → 4 s
PGC-end hold). T1–T7 unchanged and green.

**HW gate:** Weakest Link — answer reveal and the banked-money screen each stay up ~2 s;
questions still hold ~18 s and stay answerable; MiB/Matrix/T2 menus, Thayer's timed
choices and a normal movie unchanged.
