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
exact symptom.

> **Mount flush (2026-08-28, `fix/mount-avsync-flush`) — the "Seek-only; the known-good
> clip-load path is untouched" exclusion is RETIRED.** That wording dated from when the
> seek flush was introduced: the clip-load path had just been stabilized and, crucially,
> `video_live` was then cleared only by core reset, so a warm reload kept the old STC
> advancing and the un-flushed VBUF cost only a small bounded offset. The lip-sync v5
> `pickup_hold`→`video_live` re-arm (PR fj#60) changed that — a reload re-anchors the STC
> on the NEW file's first `vid_pts` like a cold start — which turned the surviving
> 0.5–2 MB of OLD-file VBUF into a *permanent* audio lead of the whole residual depth
> (the governor's first pickup showed an OLD frame against the NEW anchor; a forward skew
> < ~15 s never re-anchors). HW symptom: loading a new file mid-play desynced audio until
> a core reload. `start_streaming` now fires the full flush trio (seek/vbuf + load + aud)
> exactly like `il_switch` and a chapter seek, ungated by `keep_vbuf` (a stale menu-hop
> level must not suppress a mount flush). The trigger matrix now lives in
> `dvd/flush_ctl.sv` and is locked by `bench/dvd/flush_ctl_tb.sv`.

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
  - `dvd_iso_reader.sv` latches **`jnat_l`/`snat_l`** with the request, and
    `jump_go`/`seek_jump` gain `(~nat || nat_drained || drain_wd_hit)`.
    ★ **The menu domain was exempt until 2026-09-14** ("menu tails ride
    `keep_vbuf`") and that was wrong: `keep_vbuf` preserves the DECODER's buffer,
    not the bytes still in the reader's own 16 KB cache — which this FSM stops
    delivering the moment it leaves `S_STREAM` for `S_VM_WAIT` at the cell's last
    block read. On ULTIMATE_T2's Mission Profiles that dropped the transition
    clip's tail and the first slide of every slideshow decoded wrong. `streaming`
    now covers `S_VM_WAIT` and the gate applies in every domain. See
    `docs/dvd_menu_refinements.md` §9; gate `bench/dvd/run_menudrain.sh`.
    ⚠ **The gate is `nat_drained`, not `vbuf_empty`.** `vbuf_empty` is a decoder
    LOW-WATER MARK, so a merely-starving decoder reads "drained" while the cache
    is still full — exactly a throttled menu transition. `nat_drained` also wants
    the cache empty, no block in flight, the output pipeline quiet, and 255
    settled cycles so `ps_stream_fifo` and `ps_demux` (which `load_flush` resets
    too) have drained. The **`DRAIN_WD` watchdog is shared**: its
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
table); **`iso_reader_menudrain_tb` (the MENU domain, 2026-09-14)** — the real reader +
VM + `flush_ctl` + `ps_stream_fifo` + `ps_demux`, scoring the video elementary bytes the
decoder would receive. TBs not testing the wait tie `.vbuf_empty(1'b1)` (= "always drained",
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

⛔ **STALE AS WRITTEN UNTIL 2026-09-14 — the reader does NOT cold re-decode a still any
more.** This paragraph used to say that a menu still entered through a `keep_vbuf`
transition "would show PIXELATED if merely held", so the reader flushed and re-streamed the
still cell from its own sequence header. That re-decode was **removed in v0.5.0**
(`b900478`, issue #65: it replayed the cell's audio, and two later decoder fixes were
believed to have made it unnecessary). `vbuf_empty` and `menu_snap` survive as ports;
`menu_snap` has been tied low since the Snappy/Smooth toggle went, and `vbuf_empty` now
feeds the natural-transition drain gate instead.

⚠ **The claim the sentence was making turned out to be TRUE, and removing the re-decode is
what exposed it**: on ULTIMATE_T2's Mission Profiles the first slide of each slideshow came
up pixelated and stayed so. The cause is that the reader stopped delivering the transition
cell's tail (see the Phase-B note above and `docs/dvd_menu_refinements.md` §9), not
anything about holding a still. History of the earlier attempts — including a trailing-byte
"flush primer" that was HW-reverted for flushing a *corrupt* mid-stream frame — is in
`docs/dvd_menu_refinements.md` §5/§5b/§5c/§5g.

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
  honours `hli_ss` (1 = new → selection resets to `fosl_btnn`/1 — see the
  forced-select note below, which is where that promise was NOT kept until
  2026-08-30, `foac` = forced-SELECT
  hop only since 2026-08-27 (the forced-ACTIVATE arm was deleted — see
  `docs/dvd_vm.md` "Failed-menu-link re-enter");
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

## Keyboard / CEC input

Two independent decoders share the `ps2_key` scancode space, and keeping them disjoint is
a standing constraint: the **digit** path below (menu button by number, shipped 2026-07-27)
and the **transport** map in `dvd/kbd_map.sv` (issue #35, 2026-09-03).

### Transport: `dvd/kbd_map.sv` — ✅ HW-CONFIRMED 2026-09-04

Confirmed on the board (build `DVD_kbdmap_20260904_0226.rbf`): the issue #35 case itself
(`Enter` activates the highlighted button in a disc menu with no Define-buttons mapping in
place), menu navigation and the transport keys, the keyboard 10 s seek, and the **gamepad
unregressed** — that last one being the only gate the `joy_eff` substitution has, since
there is no emu-level bench. ⏳ Still ungated: **HDMI-CEC** (the maintainer's board cannot
run CEC at all, see the ⚠⚠ note below) and the **tap-repeating IR remote burst** (no
receiver available; covered in sim by `dpad_seek_tb` T19a).

**Why it exists.** MiSTer's own *Define buttons* already maps keys onto a core's `J1`
buttons, so a built-in keymap looks redundant — until you find that **Main refuses to bind
`Enter` or `Esc` to any button at all.** `input.cpp:3276` guards the capture block with
`!((mapping_type < 2 || !mapping_button) && (cancel || enter))`, and a keyboard session is
`mapping_type == 0` (`input.cpp:3353`), so those two keys are excluded for *every* button.
They are not merely dropped, either: `Enter` is the OSD's own confirm key, so it reaches
`menu.cpp:4419` (`else if (select || menu || …) finish_map_setting(...)`) and **ends and
saves the mapping session** — which is exactly why a user reports that it "registered" and
then does nothing. `start_map_setting()` even calls `user_io_kbd(KEY_ENTER, 0)` to un-stick
Enter on entry (`input.cpp:1772`), confirming which key drives that UI.

★ **That was the whole of issue #35**, and it was reproduced on a stock MiSTer with a plain
USB keyboard: a mapped `Enter` does not activate a highlighted DVD-menu button while the
gamepad's own Select does, in the same menu. The disc and the core were both blameless. It
matters far beyond one report — on a console dock remote `OK` and `Exit` **are** Enter and
Esc, i.e. its two most important buttons are precisely the two MiSTer will not map.

★ **And for HDMI-CEC this is the only path that exists.** Main injects CEC button presses as
KEYBOARD events (`hdmi_cec.cpp:290-319`) and never runs them through the joystick mapping,
so before this a TV remote could drive nothing here except menu digits. The key choices are
therefore led by CEC's fixed table, which is the constrained resource; keyboard aliases
follow DVD-remote/VLC convention afterwards.
⚠ **CEC's own Root Menu / Exit is unreachable and cannot be fixed here:** it maps to
`menu_present() ? KEY_BACK : KEY_MENU`, and `menu_present()` means "the OSD is on screen
right now" (`menu.cpp:8137`) — so during playback it is `KEY_MENU`, which Main eats as the
OSD toggle, while `KEY_BACK` has `NONE` in the PS/2 table. Hence Menu/Title/Audio/Subtitle
ride the CEC **colour keys** (`F1`–`F4`). Verified against `hdmi_cec.cpp` as of 2026-09.

⚠⚠ **CEC IS NOT AVAILABLE ON EVERY BOARD, AND THE MAINTAINER'S IS ONE IT FAILS ON — do NOT
treat it as a supported path or gate this feature on it.** MEASURED 2026-09-04: I2C to the
ADV7513 is fine (no `main register setup failed`), but the clock probe reports
`clock probe TX elapsed=150 finished=0` → `CEC: no clock detected.` → `CEC: init failed.`
The chip's CEC transmitter never completes a frame, i.e. its CEC engine has no working clock
(or the CEC line is not routed/pulled up, so arbitration never sees the bus idle). Either
way it is a board fact, not a configuration one.
⛔ **`hdmi_cec_clock=` DOES NOT FIX IT — and that wrong suggestion was already made once.**
`cec_detect_clock` takes the ini value as `proposed_clock` and only consults it in the
`else if (proposed_clock)` branch (`hdmi_cec.cpp:559`), which is reached **after** a
successful probe TX. A failing probe fails identically whatever is configured: the setting
picks *between* clock rates once the engine is known to run, it cannot start one.
★ It fails CLEANLY, worth knowing before anyone chases a startup hang: `cec_can_try` is set
true only *after* `cec_clock()` succeeds (`hdmi_cec.cpp:1060`), so a clock failure prints
`CEC: init failed.`, sets `cfg.hdmi_cec = 0` and gives up — no 3 s retry loop, just a one-off
~300 ms probe. `hdmi_cec=0` skips even that.
★★ **The recommended remote route is a USB IR receiver that presents as a HID keyboard**
(Flirc, a generic MCE dongle, or a console dock's own receiver): no CEC, no ini, and it lands
on exactly the `ps2_key` path this module already decodes. The manual leads with that and
files CEC under "worth trying".
⚠ **Main discards its own log by default** (`cfg.cpp:452`:
`stdout = (cfg.debug == 2) ? debug_file : cfg.debug ? orig_stdout : dev_null`), so any CEC
diagnosis starts with `debug=2` under `[MiSTer]` and reading `/tmp/debug.txt`. Raw button
codes are logged **only in the menu core** (`if (is_menu())`, `hdmi_cec.cpp:276`), so "is the
TV sending anything at all?" has to be tested from the MiSTer main menu, not from inside the
player.

**Shape.** `kbd_map` emits a 17-bit vector in `joystick_0`'s own bit order and `emu.sv` ORs
it in: `joy_eff = joystick_0 | {15'd0, kbd_joy & ~17'h0_6000}`. Every button wire, edge
detector, the chapter debounce, the menu walk, the HUD and `vm_entropy_stir` then read
`joy_eff`, so a key and a gamepad button are the same signal by the time anything acts on
them and **no consumer had to change**. Four substitution sites, of which
`joy_prev <= joy_eff` is the one that silently breaks everything if missed (a pulse would
produce a phantom edge every cycle it is high).

★ **OR-ing cannot double-fire**, which is what makes this safe: Main hands a key to the
joystick mapper *or* to the PS/2 stream, never both — `input.cpp:3807-3821` matches the
user's map and **returns**, so the scancode is never sent. A user's own mapping therefore
shadows the built-in one, which can only fire on keys that would otherwise have done
nothing. Enter and Esc are the exception that motivated the feature, and they can never be
shadowed because they can never be mapped.

★ **Every bit is a one-cycle PULSE; there is no level anywhere in the module.** Main drops
keyboard auto-repeat (`user_io.cpp:4059`, `if (press > 1 && !use_ps2ctl) return;` — this
core does not set `use_ps2ctl`), so a held key is one make and one break and a level would
buy nothing except failure modes. A lost release becomes a non-event, and a stuck key is
structurally impossible. (An all-levels design has a subtler trap too: a stuck bit swallows
the *next* press, because there is no rising edge left to detect, and the key looks dead.)

★★ **`[14:13]` Fast Fwd / Rewind are masked out of `joy_eff` and go to `dvd/dpad_seek.sv`,
not to `dvd/scrub_ctrl.sv`'s hold-to-scrub.** They are the design's only LEVEL consumers
(`scrub_ctrl.sv:84`), and a keyboard-like device cannot drive a level safely, for two
reasons that are measured rather than argued:

1. **Tap-repeating IR remotes turn a hold into a burst of seeks.** Retro Remake's SuperDock
   receiver firmware (`Retro-Remake/DockIR`, `src/main.c`) sends `key-down → 80 ms →
   key-up` **per NEC repeat frame**, ~110 ms apart — a long press is ~9 discrete taps a
   second, not a hold. `scrub_ctrl`'s accumulate tick is 60 ms (`TICK = 1_620_000` @
   27 MHz), so an 80 ms tap leaves `pending_off != 0` and *every* release issues a real
   seek: ~9 flush/re-locks per second, precisely the regime HW rounds 1-2 recorded as fatal
   (headers of `scrub_ctrl.sv` and `dpad_seek.sv`). Under coalescing the identical burst
   builds ONE jump — `dpad_seek_tb` **T19a** replays it and measures exactly one `jump_fire`.
2. **A stuck level hangs the picture.** `held_right` stuck with `in_title` leaves `want`
   high forever → `hold_freeze` → frozen video with the bar up and no seek issued (the seek
   happens on *release*), and the reflex recovery — tap it again — delivers a break with
   `pending_off` already ramped to the title span, i.e. **one seek straight to the end of
   the title**.

The gamepad's hold-to-scrub is untouched: neither `scrub_ctrl.sv` nor `dpad_seek.sv` is
modified by this feature. `dpad_seek`'s `en` is read in exactly one place
(`seek_ok = en && in_title && (dvd_mode || lin_mode)`, `dpad_seek.sv:170`), so `emu.sv` ties
it to 1 and applies the `O[45]` gate to the four **D-pad edges** instead, leaving the
keyboard's Fast Fwd/Rewind ungated — `O[45]` exists solely to stop the *D-pad* fighting a
game disc that wants directional input, and a dedicated seek key has no such conflict.
Keyboard seek needs a `kbd_joy[13]|kbd_joy[14]` term of its own in the pause-clear chain,
for the same two reasons (masked out of `joy_eff`, and not gated on `O[45]`).
⚠ Known gap: `dpad_seek` needs DSI tables or a measured linear rate, so keyboard seek is
inert on a bare `.m2v` where the gamepad scrub still works.

**Keymap.** PS/2 **set 2** throughout (what Main sends — confirmed by the digit decoder
below): arrows `E0 75/72/6B/74`; `Enter 5A` and `E0 5A` → Select; `Space 29` → Pause;
`E0 7D`/`P 4D` → Prev Chapter; `E0 7A`/`N 31` → Next Chapter; `F1 05`/`M 3A`/`X 22` → Menu;
`G 34` → Angle; `F3 04`/`A 1C` → Audio; `F4 0C`/`S 1B` → Subtitle; `D 23` → Display;
`Tab 0D`/`F 2B` → Fast Fwd; `Backspace 66`/`R 2D` → Rewind; `F2 06`/`T 2C` → Title;
`Esc 76`/`B 32` → Return. `X` is bound to Menu because it is the SuperDock remote's only
spare key and that remote's own Menu button is `F12` = the MiSTer OSD. `Esc` is bound
deliberately: CEC's real back button is unreachable, so without it a CEC user has no way up
a menu level, and GoUp is a harmless no-op where the disc authors no parent.

**DVD-remote additions (2026-09-13, B14..B18).** `Q 15` → Stop; `Z 1A` → Aspect;
`F5 03` → Chapter Menu; `L 4B` → A-B Repeat (VLC's "loop"); `. 49` → Frame Step. All five
were checked free against the three claimants that own this space — `kbd_map`'s existing
table, emu's numpad digit block, and the never-bind list below. `kbd_map.joy` and emu's
`kbd_joy` widened 17 → 22 bits for them, and ⚠ **the FF/REW mask widened with them**
(`17'h0_6000` → `22'h00_6000`): that mask is what keeps bits 14:13 out of `joy_eff`, and a
mask left at the old width would silently hand the design's only LEVEL consumers to a
tap-repeating IR remote.

⚠ **Eject and Volume are deliberately NOT in this table.** They need a core→Main request
channel that does not exist yet (the `CMD_AF` payload word in `dvd/dvd_telem.sv` has free
bits for it), and a named button that does nothing is worse than a missing one. They append
as B19..B21 when that lands. Volume additionally cannot use `KEY_MUTE`/`KEY_VOLUMEUP`/
`KEY_VOLUMEDOWN` at all — Main consumes those in `user_io.cpp:4283-4296` before they reach
`ps2_key` — and MiSTer already has a framework volume (`sys_top.v` `vol_att` → `audio_out`)
that attenuates I2S, the analog DAC **and** S/PDIF together, so the right shape is to ask
Main to call `set_volume()` rather than to build a second attenuator in fabric.

⚠ **Never bind**, all verified against Main: `F12` (`07`) and `KEY_MENU` (OSD toggle),
`KEY_PAUSE` (`E1`, no break code at all), `KEY_SYSRQ`, NumLock/ScrollLock (Main's
`EMU_SWITCH_1/2`), Alt/Meta.

⚠ **The extended bit is load-bearing.** Six of the codes above are bit-identical to numpad
digits and differ ONLY by the `E0` prefix — `75`/numpad-8, `72`/numpad-2, `6B`/numpad-4,
`74`/numpad-6, `7D`/numpad-9, `7A`/numpad-3. The digit block requires `!ps2_key[8]`;
`kbd_map` requires `ps2_key[8]` for exactly those six. `5A` is the one code accepted with
either polarity (Enter and KP-Enter both mean OK). **Digits are not decoded in `kbd_map` at
all** — all twenty scancodes belong to the digit path, and binding them twice would make one
keypress do two things.

**Gate: `bench/dvd/run_kbd.sh`.** `kbd_map_tb` is mutation-checked — five targeted RTL
mutations (level-instead-of-pulse, numpad-8 leak, fire-on-break, digit leak, Esc unbound)
are each caught by their own scenario, because level assertions on a decoder are exactly the
shape that passes without proving anything. `dpad_seek_tb` T19a/T19b own the IR-burst
routing. `scrub_ctrl_tb` must pass **completely unchanged** — that is the gate proving the
gamepad scrub was not touched. ⚠ `emu.sv`'s `joy_eff` substitution has **no** simulation
gate (there is no emu-level bench); it is review-only plus Quartus elaboration.

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


### Forced select (`fosl_btnn`) must apply on a NEW HLI, not a not-armed edge (2026-08-30)

**The bug (user-submitted disc: Scooby-Doo 2, "Monsters Unleashed Challenge"):** *"the
floor maze in Wickles Manor starts the player in the wrong position (should start at
the bottom with the player moving forward)."*

**Mechanism.** The maze's HLI (VTS_02 title VOB, in-title HLI — this is a title-domain
game like Tomb Raider, not a menu) authors **5 buttons**:

| btn | rect | auto | role |
|---|---|---|---|
| 1 | x125–135 y92–102 | **1** | left  (`g15=3`) |
| 2 | x217–227 y92–105 | **1** | right (`g15=4`) |
| 3 | x167–177 y62–75  | **1** | forward (`g15=5`) |
| 4 | x167–177 y132–145| **1** | back  (`g15=6`) |
| 5 | x167–177 y92–105 | 0 | **neutral centre** (`LinkTopPG`) |

Buttons 1–4 are `auto_action`: *landing* the highlight on one FIRES it. `fosl=5` exists
precisely to park the highlight on the inert centre so the player is not moved before
they press anything.

`nav_pci.sv` gated the forced select on `!armed`. In that always-block `armed` reads its
**pre-assignment** value, so `fosl` only ever applied on a not-armed → armed transition
and was silently dropped whenever one HLI replaced another *while the highlight stayed
armed* — which is exactly what a maze does VOBU to VOBU. The highlight therefore stayed
on the default button 1 = **left**, auto-activated, and the player moved on entry.

**The fix.** Apply `fosl` when the HLI is **NEW** (`nxt_ss == 1`), which is the same
test the `foac` commit one line above already uses:

```systemverilog
if (nxt_fosl != 6'd0 && nxt_fosl <= nxt_btn_ns && (!armed || nxt_ss == 2'd1))
    btn_sel <= nxt_fosl;
```

⚠ The `hli_ss == 2/3` **continuation** case must stay excluded: those VOBUs re-send the
same HLI, and re-applying `fosl` on each one would drag the highlight back to centre
every VOBU and fight the player's own D-pad. This disc sends the maze HLI as **both**
`ss=1` and `ss=2`, so both halves of the rule are load-bearing.

**Tests:** `nav_pci_tb` **T16** arms the 7-button MiB fixture, moves the selection to
button 4, then delivers a NEW HLI carrying `fosl=5` while still armed and requires the
selection to become 5 — **RED pre-fix** (stays 4). **T17** is the control: the same
packet as an `hli_ss=2` continuation must leave the selection at 4 (passes both ways by
design, so it guards the exclusion).

⚠ **HW result 2026-08-31 — PARTIAL PASS.** Fresh entry is FIXED: the Wickles Manor
floor maze now starts at the bottom facing forward. But **re-entry after falling into a
trap, and the next room after clearing the first, both still land on the upper-left of
the grid** — i.e. the highlight is still defaulting to button 1 (= left), which
auto-activates and moves the player before any input.

⛔ **The "leading theory" that stood here (the re-entries arrive as `hli_ss == 2` and the
`fosl` gate should key on a cell/PGC change) was WRONG, and it was wrong in a way the
disc shows in one line: the re-entry HLIs carry `fosl = 0`.** No `fosl` rule of any
shape could have parked them. Root-caused 2026-09-14 — next section.

⚠ **Gotcha when scanning this yourself:** a DVD NAV pack carries a **system header**
before the `000001BF` PCI packet, so PCI data starts at sector offset **0x2D**, not
`14 + stuffing + 7`. Computing it the naive way finds ZERO HLIs and looks like "this VOB
has no buttons" rather than like a bug — it cost a scan here. `nav_pci_tb`'s
`localparam PCI = 'h2D` is the authority.

### Link button fields across a flush: `LinkCN 26 (button 16)` must land on 16 (2026-09-14)

**The report (same disc, HIL session 2026-09-14 + maintainer):** in the Wickles Manor
entrance grid (reader `PGCN 28`, a 21-tile directional-cursor trap/clue grid), every trap
resets the highlight to the **same absolute tile — the upper-left one — whatever tile the
player fell from**; solving it and entering the next room (and the room after) lands the
highlight upper-left instead of bottom-middle. The 5-button maze's trap re-entry and
room 2 (the PARTIAL above) are the same defect.

**Measured from the disc, before the decoder was opened.** VTS_02 PGCN 28's own commands
say how the cursor is meant to be parked, and it is not `fosl`:

| where | command | meaning |
|---|---|---|
| PRE (grid entry) | `LinkPGN 2 (button 18)` | enter the grid on tile 18 = bottom-middle |
| cell 5 / 6 cell-cmd (trap exits) | `LinkCN 26 (button 16)` / `LinkCN 26 (button 3)` | back to the grid, re-parked on the tile you fell from |
| cell 9 cell-cmd (room solved) | `LinkCN 10 (button 17)` | next room, bottom-middle |
| POST | `LinkCN 26 (button 18)` | the grid again, bottom-middle |
| the grid HLI itself (RBN 178948) | `btn_ns=21 fosl=0 hli_ss=1` | 21 tiles, **no forced select** |

The 5-button maze's re-entries are the same mechanism one PGC over: `PGCN 4` PRE
`if (g[15] == 0x14..0x19) LinkPGN 15 (button 1..6)`, `PGCN 7` PRE `LinkPGN 5 (button
1..6)`. And where this disc wants a RESET it says so: `LinkPGN 1 (button 1)`,
`LinkPGN 22 (button 1)` — 40-odd links carry an explicit `(button 1)`. A disc authored
that way is authored against a player whose HL_BTNN **persists**.

**The mechanism.** `dvd_vm.sv` handled the field correctly: every link op writes
`sprm8 <= {sub_btn, 10'd0}` and pulses `btn_force` → `nav_pci.sel_force`, and nav_pci
stored it ("with no HLI armed the value is stored so the next arm's persistence rule
keeps it"). But the link that carries the button is **the same link that fires the
seek** (`LinkCN` → `seek_pulse`, `LinkPGN` → `V_PMRD` → seek), the seek's `seek_ack`
raises `load_flush`, and `nav_pci` sits on `pipe_rst_n` — so ~a hundred cycles after
storing 16 it was reset to its constant `btn_sel <= 6'd1`. Upper-left tile, every time,
from every trap. The VM's own `sprm8` (on `reset_n`) still held 16 the whole way.

**libdvdnav, the oracle:** `HL_BTNN_REG` is written at links (`vm.c:772-958`),
`SetHL_BTNN`, `fosl` (`dvdnav.c:814`, at the SPU-stream-change event = once per jump) and
user select (`highlight.c:416/448`); the ONLY reset is `vm_reset` = the disc open. Nothing
in `play_PGC`/`set_PGCN`/a jump clears it.

**The fix = one wire, in the direction the register already lived.** `dvd_vm` exports
`hl_btnn = sprm8[15:10]`; `nav_pci` takes it as an input and, in the FIRST cycle after
its reset releases, re-seeds `btn_sel` from it (`seeded` flag; 0 = "no opinion", the
default 1 stands). It is placed first in the clocked block so every later same-cycle
write — `sel_force`, the arm's persistence rule, `fosl` — still wins, which keeps the
priority libdvdnav has (fosl is applied AFTER the link wrote the register). And the VM's
`sprm8` now **tracks the live selection while an HLI is armed and not frozen** (it
already READ that way through `sprm8_eff`; the register just did not remember it after
the menu tore down), so a D-pad move that was never activated survives a jump the way
`dvdnav_button_select` writes `HL_BTNN_REG`.

⚠ **This is a semantic change for every jump, not only this disc's:** a menu entered by
activating button k now arms on k when it has ≥ k buttons and the link carries no button
of its own, where it used to arm on 1. That IS what libdvdnav and a set-top player do
and what authoring tools assume (hence the explicit `(button 1)`s above); a disc that
relied on our reset-to-1 would have to be one that reads wrong on a real player.
✅ **HW-CONFIRMED 2026-09-14 by the maintainer** (build `DVD_linkbtn_20260914_1834.rbf`,
SEED 7 first roll, clk_dec 91.04/87.54, 90 % ALM): the Scooby-Doo grid section plays
correctly, and the T2 and Matrix menus look right under the persistence change.

**Gate: `bench/dvd/run_link_button.sh --red`** — three arms, one per place the fix
lives, and six mutations each caught by exactly its own arm:
- `nav_pci_tb` **T19** (the consumer): the REAL grid NAV pack
  (`bench/dvd/test_vobs/scooby_grid_pci.hex`, 21 buttons, fosl=0); `sel_force(16)` →
  reset → the grid arms on **16** (T19a, RED pre-fix: 1), the room entry from an ARMED
  grid lands on 17 (T19b), controls for `hl_btnn=0` (default 1) and an out-of-range
  value (1 at the arm), and `fosl` on a NEW HLI outranking the seed (T19e).
- `dvd_vm_tb` **T6** (the producer): the trap exit verbatim (`LinkCN 26 (button 16)` →
  seek to cell index 25 AND `hl_btnn == 16`), select write-back after tear-down, and the
  frozen guard (an activated button is not overwritten by `btn_sel` drift — the S12b
  contract).
- **`tools/check_hl_btnn_wiring.py`** (the seam): reads `dvd/emu.sv` and requires both
  `.hl_btnn` ports on ONE declared 6-bit net — the `check_subp_map_wiring.py` pattern,
  because a wrong value on a correct port is invisible to both module benches and emu
  has none. RED on the pre-fix file, on `.hl_btnn (6'd0)` and on a dropped connection.

★ **Reusable lesson:** a one-cycle request into a module that the SAME action later
resets is a value that will not be there when it is needed. `nav_pci` on `pipe_rst_n`
was right for everything a flush should forget (pending HLIs, timers, banks); the
selection is a VM register that merely has a shadow here, and a shadow must be
re-derived from its source after a reset, not from a constant.

### A sequence of HLI windows is not a looping menu (2026-09-14)

**The report (same disc, the Old Tyme Mining Town whack-a-mole, reader `PGCN 26`):** a
monster appears, the player presses that direction, the core says MISS, plays the "all
the monsters mock you" clip and restarts the round. Filed 2026-08-30 as "not
root-caused"; it is not the deleted forced-ACTIVATE (`foac` reads 0 across this disc).

**What the disc authors.** Cells 14–17 of `PGCN 26` are the four rounds (5 / 23 / 27 /
27 s of video). Each is cut into consecutive HLI **time windows**: the window's own
`hli_ss=1` NAV pack arrives one VOBU (~66 ms) before it starts, and every VOBU in
between re-sends the same HLI as `hli_ss=2`. Cell 15's first four packs:

| RBN | VOBU start | `hli_ss` | window `s_ptm..e_ptm` |
|---|---|---|---|
| 141675 | 8484 | **1** | 8484..98574 — nothing on screen (1.0 s) |
| 141832 | 47523 | 2 | 8484..98574 |
| 142009 | 92568 | **1** | 98574..455931 — monster LEFT (4.0 s) |
| 142189 | 137613 | 2 | 98574..455931 |

Every window carries the same five buttons — 1 left / 2 top / 3 right / 4 bottom, all
`auto_action=1` (landing the highlight FIRES the command), and 5 the neutral centre with
`fosl=5`. In a *nothing* window all four directions carry the same `LinkCN <miss cell>`;
in a *monster* window the monster's direction carries the hit (`g[12]=0`, keep playing,
or `LinkCN 7/8`). **The same button is a hit or a miss depending on which window is
armed**, and the miss cell's own cell command restarts the round.

**Root cause.** `nav_pci` has ONE pending slot and an earliest-`s_ptm`-wins park policy
(the 2026-08-05 Matrix "dark with blips" fix), whose comment says a repeated commit is
harmless because "identical content re-parks after each promote anyway". That is true of
a **looping menu**, which re-sends one HLI for ever, and false of a disc that authors a
**sequence**. Two rules were wrong for it:

1. a continuation of the window already on screen re-parked it, with `nxt_pre=0` — no
   authored time left to wait for, so only the ~1 s `PROMOTE_FALLBACK` could move it;
2. a commit that could still be **scheduled** was held behind a pending one that could
   only **time out**, because the pending's `s_ptm` was earlier.

Together the armed set trailed the picture by up to ~1.5 s, jittering with the VBUF
depth. A player reacting a few hundred ms after the monster appeared was still armed on
the previous window, whose command for that direction is the miss. A *slow* press hit —
which is why it reads as "it says I missed when I didn't".

**The fix (`dvd/nav_pci.sv`) is four rules.** The first round shipped two of them and
the maintainer reported the game now progressing but still "definitely hitting a monster
and it counts as a miss sometimes" — which a sweep then reproduced exactly.

```systemverilog
wire arm_is_cont    = armed && (f_ss == 2'd2) && (f_sptm == h_sptm);
wire sched_outranks = nxt_v && !nxt_pre && ($signed(stc[31:0] - f_sptm) < 0);
wire nxt_future     = stc_trusted && nxt_pre && nxt_dist[31] &&
                      (nxt_ahead < FUTURE_HORIZON);
// ...plus a SECOND pending stage (nx2_*), so more than one authored window can
// be in flight between the parse front and the display.
```

1. **`arm_is_cont`** — a continuation of the window already on screen must not re-park.
   `h_sptm` (the armed window's own `s_ptm`) was removed by the 2026-09-10 area pass as
   write-only and is read again for this; telling the window ON SCREEN apart from the one
   being committed is what the rule needs. ⚠ `hli_ss=3` is **not** suppressed (that is
   "same buttons, CHANGED commands"), and a continuation while nothing is armed still
   parks, because a seek landing mid-window has only continuations to arm from.
2. **`sched_outranks`** — a commit that can still be scheduled outranks a pending one
   that can only time out.
3. **A SECOND PENDING STAGE** — with a ~1.4 s parse lead several authored windows are in
   flight at once; one slot discarded the later ones, and by the time the head promoted
   the front had moved past them so nothing of that window was ever offered again.
   ⚠ Bank budget: 4 banks = display + head + stage 2 + fill, exactly. A third stage would
   need the HLI store to grow. ⚠ And a window can legitimately reach the queue first and
   the head afterwards, so taking one into the head **drops its duplicate** — left in
   place the duplicate shifted back into the head when the real one promoted and blocked
   every later commit for that window.
4. **`nxt_future`** — and this is the one that mattered most, *and it is not from this
   branch at all*.

★★★ **THE BIGGEST REMAINING DEFECT WAS PRE-EXISTING AND POINTED THE OTHER WAY: THE
FALLBACK TIMER WAS PROMOTING WINDOWS ~1 s EARLY.** `PROMOTE_FALLBACK` exists for a
pending whose STC compare will never come due (the keep_vbuf skew). It was also firing on
pendings that were simply **early**: whenever the parse front leads the display by more
than the ~1 s timer — and a title at this disc's ~10 Mbps mux buffers about that — every
window was committed more than a second before its start, aged out, and promoted ahead of
the picture. So the *next* window's buttons answered a press aimed at the monster on
screen. The guard is a measurement rather than a timer: with a **trusted** clock (the same
test the scheduled path uses) and a commit made before its window, a compare that says
"not yet" is informative and must be waited out; an untrusted clock still falls back, so
the menu rescue is untouched.
⚠ **Bounded by `FUTURE_HORIZON` (4 s), and `nav_pci_tb` T7 is why.** "Wait for a window
that has not started" must not become "wait for ever": T7 parks a pending 28.7 s ahead and
requires the timer to rescue it. A real parse lead is bounded by the VBUF (2 MB at a DVD's
~1 MB/s of video ≈ 2 s), so inside the horizon is plausibly early and beyond it is not
this mechanism. The unbounded first cut passed every arm of the new bench and was caught
by the menu suite — which is why that suite is part of this gate.

**MEASURED over the real cell-17 NAV packs** (16 windows, the shortest 0.50 s and 0.73 s),
counting monster windows that answer a +300 ms press with their hit:

| VBUF lead | shipped v0.5.x | + rules 1–2 | + rules 3–4 |
|---|---|---|---|
| 300 ms | 9/9 | 9/9 | 9/9 |
| 600–1100 ms | 8/9 | 8/9 | **9/9** |
| 1300–1600 ms | 7/9 | 8/9 | **9/9** |
| 1800 ms | 5/9 | 6/9 | **9/9** |

★★ **MEASUREMENT REVERSED THE STORY TWICE, AND THE PLAN HAD IT BACKWARDS BOTH TIMES.**
The continuation re-park is the obvious culprit and reads like the whole bug; ablation says
`sched_outranks` is what fixes the *reported* case, `arm_is_cont` owns a late re-commit
reaching the display at all (arm [F]), and the *largest* effect at realistic buffer depths
belongs to a timer defect that predates this disc entirely. Every rule was kept only
because disabling it costs measured hits, and one that did not — a "refresh the queued
entry's schedulability" wire added while chasing [F] — was **deleted** once the duplicate
fix made it dead: no mutation could catch its removal and the sweep was unchanged at every
lead.

⚠ **`sched_outranks` keeps its `!nxt_pre` guard, and that guard is the Matrix rule.**
Without it the policy degenerates into newest-schedulable-wins, which is exactly what
"every VOBU overwrites the pending with a later start before it comes due" meant.
Measured: it is a no-op for repeated identical content (those commits share an `s_ptm`,
and `stc` only advances, so a later commit of the same window can never regain
schedulability an earlier one lacked), so it can only matter for a genuine sequence.

⏳ **Known residual, measured not argued (arm [G]): a round's FIRST window is
fallback-timed.** The round is entered by a `LinkCN` seek, so that window is committed
while the clock still measures the previous cell — `stc` is past its `s_ptm` before it
arrives, the compare carries no information, and it reaches the screen on the ~1 s timer.
Every later window is display-scheduled (+0 ms). On this disc the opening window of each
round is a *nothing* window, so no input is lost. Tightening it means touching
`hli_coherent`, which is what cost Harry Potter and Scene It their highlights
(`docs/stc_freerun.md` §11, `nav_pci_tb` T18/T18b) — so it is bounded by the bench, not
chased. Arm [I] is the control that makes the number readable: the same round entered
with a low entry clock answers a press from the start.

**Gate: `bench/dvd/run_hli_window.sh --red`.** `bench/dvd/hli_window_tb.sv` runs the real
`nav_pci` over the real NAV packs (`bench/dvd/test_vobs/scooby_mole_pci.hex`, 14 sectors =
4 windows) and **measures what the player experiences: press a direction at a display
time, record which command fired.** It reads no signal the fix names, and the expected
command comes from the fixture's own button records, so it cannot become a golden model
that agrees with its RTL. It models the two clocks that matter — a display clock, and a
parse front running a sweepable VBUF lead ahead of it, with the round entered on the
previous cell's timeline and re-anchoring once. `nav_pci_tb` runs in the same gate,
because this touches the promotion timer every disc menu depends on. Arms [A]–[J]; nine
mutations, each required to fail EXACTLY its own arms (M1→F, M2→E2, M3→F, M4→A B F, M5→J,
M6→A, M7→D, M8→F, M9→the menu suite).

✅ **HW-CONFIRMED over two rounds, 2026-09-14/15** (builds `DVD_molewindow_20260914_2217`
then `DVD_molewindow2_20260915_0202`, SEED 7 first roll, clk_dec 94.20/89.84, 91 % ALM).
Round 1 made the game progress and hits generally register but left the "sometimes it says
I missed" residual that the lead sweep above reproduced; round 2 closed it and **the
maintainer can beat the minigame**, with the disc's own yellow highlight on a hit and red on
a miss, and the T2 / Matrix menus unregressed by the promotion-timer change.

⏳ **Two symptoms remain on this disc and are NOT this defect** — they are A/V sync at a cell
transition and want their own investigation: Shaggy's win commentary is cut off, and one
round's speech does not lip-sync. Two measurements point the way. Every cell in this game
**restarts its PTS near zero** (rounds at 0.094 s, the commentary clips at 0.122 s), so
every transition is a clock discontinuity plus an audio re-phase. And the commentary clips
are **single-picture still cells**:

| cell | video pictures carrying a PTS | audio |
|---|---|---|
| 7 (win clip) | 1 | 100 packets, 8.3 s |
| 8 (win clip) | 1 | 104 packets, 8.7 s |
| 19 (commentary) | 1 | 265 packets, 22.2 s |

`disp_sched` anchors the clock on video PICKUPS, so such a cell gives it exactly ONE anchor
and then free-runs for the whole clip while the audio plays against it. ★ Start on hardware
with the drift counters rather than offline: a drifting single-anchor clock and audio
dropped at the seek produce the same symptom, and `av_drift_ms` / `play_err_ms` /
`disp_lag_ms` separate them in one reading.

⚠⚠ **A bench bug worth knowing, found by making the bench faster:** the scene clock had
two drivers — a task's blocking reset and the tick process's nonblocking increment. At 3
clk per tick the reset survived because the increment ran on one edge in three; at 1 clk
per tick it was overwritten every edge, scenes never restarted their clock, and every
press landed in the wrong window. It presented as "the fix regressed". The tick process
owns the counter outright now, and the scene asserts it actually reset.

⚠ **HIL session 2026-09-14 (recorded here because its characterisation was what
localised the bug):** driving the challenge live (HQ → mission hub → Wickles Manor
entrance grid, reader `PGCN 28`), every trap — three distinct ones, triggered both by
`select` on a tile and by a bare directional landing — reset the highlight to the **exact
same absolute tile**, the upper-left one, however far from it the player had walked. "A
hardcoded default, not a wrong-direction offset" is exactly right: it was `nav_pci`'s
constant reset value. The reading that it "does not change the leading theory" was
wrong — see the section above: the grid has `fosl = 0`, and the two puzzles are one
defect through one mechanism (the link's button field).

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

> **Three things reposition the reader through this machinery:** the user's chapter skip and
> hold-to-seek scrub (§1, §2a), the opt-in D-Pad fixed-time seek (§2b), and — since
> 2026-09-03 — a live `Video Output` change, which re-aligns to the current VOBU instead of
> flushing mid-parse (§2c, issue #42). Anything new that wants to move the reader should
> read §2c's arbitration and stale-playhead rules before adding a fourth.

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
`title_first_rbn..title_last_rbn` from the reader). ⚠ **The two ends are NOT
symmetric and that is deliberate** — `title_first_rbn` is the FIRST PROGRAM
cell's `first_sector`, `title_last_rbn` is the **MAXIMUM** `last_sector` over the
PGC's cells. See §2f for why taking the minimum at the low end would re-create
the very bug the maximum at the high end removes:
- **Hold** = a plain pause: `hold_freeze` (= a direction held in a title) is ORed into emu's
  pause holds — `pause_gov` (governor + `av_sync.pause` STC) and `pause_aud`
  (`dvd_audio_decode.pause` + drain-watchdog freeze). This is the *same* stable hold as a manual
  pause (the watchdog is suppressed the whole time), so there is no re-lock/watchdog problem.
- **Accumulate** = on the press edge it latches `base_rbn = cur_rbn` (the live playhead
  `dsi_nv_pck_lbn`); every ~0.06 s tick it adds a **tier-scaled** step (tier 0→3 by hold time
  0/2/4.5/8 s) to a signed offset, capped at the title span. A direction flip restarts the
  accumulation the other way.
  ★★ **THE STEP IS AN ABSOLUTE CONTENT RATE, NOT A FRACTION OF THE TITLE (2026-09-12).**
  This paragraph used to end *"steps are span-RELATIVE, so the feel is the same
  fraction-of-title on a 5-minute clip and a 3-hour epic — keep it that way"*, and that is
  the decision the change overturns. A fraction of a **short** title is a crawl: MEASURED at
  tier 0 with `span >> 12`, a 2 h feature moves **29 content-seconds per second**, a 3-minute
  clip **0.58**, a 30-second clip **0.19** — the shorter the title, the slower the scrub,
  which is backwards from what the gesture is for. The shift also **truncated** what little
  was left (`15504 >> 12 = 3`, losing 21 %; `2584 >> 12 = 0`, losing all of it — the `| 1`
  floor was the only thing still moving the cursor).
  Two step sources now, both in content-seconds:
  - **Linear** (`.mpg`/VCD/SVCD, `lin_rate_ok`): `(lin_blk10 * 6) >> LSn`. `lin_blk10` is
    blocks per 10 s (`dvd/lin_rate.sv`), so the shift **is** the rate — `1000 / 2^LSn` s/s,
    and `{6,4,2,0}` ≈ **16 / 63 / 250 / 1000 s/s**.
    ★★ **The `* 6` aligns two lattices that otherwise cannot meet.** Unscaled this path can
    only produce `166.7 / 2^n` while the DVD path produces `120000 / 2^m` at the anchor;
    those differ by `720 = 2^9.49` — **half a power of two** — so no choice of `SHn`/`LSn`
    brings them closer than **41 %**. Scaling by 6 lands them on one lattice (7 % apart) and
    removes the negative shifts the unscaled match would need at the top tiers. Cost: two
    shifts and an adder. ⚠ Gated on the rate being VALID (the `dpad_seek` precedent), never
    on a zero slipping through; an untrusted rate falls back to the span path.
  - **DVD**: `span >> (SHn + log2(title_secs) − SECS_REF)`. The span **cancels** out of the
    content rate algebraically — `(span >> sh)` divided by `(span / title_secs)` is
    `title_secs / 2^sh` — so biasing the shift by the title's **duration bucket** (a
    leading-one position, a priority encoder, no divide) fixes the rate. `SECS_REF = 12`
    anchors it: any title in **4096…8191 s (68–136 min)** gets bias 0 and a **bit-identical**
    step to what shipped, so the 2 h feel that passed hardware is untouched and only titles
    far from 2 h move. `title_secs == 0` (not yet known) likewise keeps the old step.
  ⛔ **Do NOT "improve" the bucket into `span / title_secs`.** On a seamless-branch disc the
  span holds the other branch's ILVUs (885–1679 sectors/s against a ~600 ceiling,
  ALIEN_VS_PREDATOR_SE, issue #49) and that inflation hits the bucketed shift and the divide
  **identically** — the divide fixes nothing and costs area. ⚠ The *area* objection to a
  divide has expired (post-reclaim `main` fits at ~87 %); area was never the load-bearing
  reason, so do not re-derive "we have area now, so divide".
  ★ **THE TWO LADDERS AGREE, AND THAT COST THE 2 h IDENTITY — deliberately** (maintainer,
  2026-09-12: *"these both should have the same seek steps — maybe we meet in the middle"*).
  The first cut pinned `SHn = {12,10,8,6}` so a 2 h title's step was bit-identical to the
  hardware-signed-off build, but that left a DVD at 29/117/469/1875 s/s against a `.mpg` at
  5/21/83/167 — the same tier meaning a 5–10× different speed depending on what was mounted,
  which is the defect this whole section exists to remove. Meeting in the middle **halves the
  DVD ladder**: both sources now run **~15 / 60 / 240 / 960 s/s**. The anchor MECHANISM is
  untouched and still load-bearing — it is what makes the rate absolute rather than
  span-relative; only its value moved.
  ⚠ **Residual, and it is now the LARGER error:** the bucket is a power of two, so within one
  bucket the DVD rate still varies **2×** with title length (a 68-minute title scrubs at
  8.3 s/s in tier 0, a 2h16 title at 16.7). Removing that means dividing by `title_secs`, and
  since the step is in SECTORS that is `span / title_secs` — the divide this design refuses.
  The DVD/linear gap is now smaller than this spread, which is the honest place to stop.
  ⚠ To retune the feel, move **`SHn` and `LSn` together** — one shift is one factor of two on
  either side. `scrub_ctrl_tb` T19 fails if they drift apart.
  ✅ **HW-CONFIRMED 2026-09-12 — THE FEEL, WHICH IS THE ONLY THING THAT COULD SETTLE IT**
  (build `DVD_scrubtiers_20260912_2135.rbf`, flashed to the rig and held on a physical
  disc; maintainer: *"that scrub speed feels good"*).
  ★ **The harness could not have answered this and never will:** `dvd/kbd_map.sv`
  deliberately routes keyboard Fast Fwd/Rewind to `dvd/dpad_seek.sv`, never to
  `scrub_ctrl`'s hold-to-scrub — an IR "hold" is ~9 discrete taps a second, which on the
  hold path is ~9 flush/re-locks a second, the regime HW rounds 1–2 proved fatal. So
  `joy_eff` masks those keys out and the gesture is reachable **only from a gamepad**. A
  tier ladder is a feel setting whose instrument is a person, and this is the second
  retune (2026-09-03 was the first) decided the same way.
  ✅ **AND THE REST OF THE ROUND CAME BACK GOOD THE SAME DAY** (maintainer: *"all those
  open scrub questions look and feel good on the board"*), so the branch is confirmed
  whole rather than on its easiest path: the **LINEAR half** held at the same tiers —
  which is the parity claim itself, felt rather than only pinned in sim to 7 % — a
  **SHORT title**, which is the 0.58 s/s crawl the change exists for and the case the
  first disc could not exercise (an ordinary feature sits in the anchor bucket, the one
  length whose behaviour moved least), and the **arrow readout** that replaced `×1..×4`.
  ★ Worth keeping straight for anyone retuning this: those two are different mechanisms,
  not one test twice. A linear file's rate comes from `lin_blk10` and is independent of
  its length; a DVD's comes from the duration bucket and is nothing but its length. The
  short-title arm is the only one that exercises `secs_lz` at all.
  ⚠ **The ladders and the dwells are `scrub_ctrl` parameters (`SH0..SH3`, `LS0..LS3`,
  `T1..T3`, `SECS_REF`).** The span ladder was relaxed once already on 2026-09-03 after a
  user report that the scrub "ramps up too fast": the original `{10,8,6,5}` / 0-1.5-3-5 s
  ladder moved ~2 **minutes** of a 2 h title per second even in tier 0 — no fine-positioning
  tier at all, and 5 s of holding crossed 77 minutes. Gate:
  `bench/dvd/run_scrub_tiers.sh --red` (T16 the anchor, T17 the short-title rate in
  content-ms per tick, T18 the linear ladder in content-seconds per second, one mutant per
  claim). Pinned by
  `scrub_ctrl_tb` T13 (the ladder, MEASURED off `bar_tgt_rbn` rather than read out of the
  DUT), T14 (the tier boundaries) and T15 (the shipped default parameters, so a retune is
  deliberate). A retune must also move `dvd/scrub_ctrl.sv`'s header, `dvd/dpad_seek.sv`'s
  header and `docs/transport_hud.md`.
- **Release** = `target = clamp(base_rbn ± offset, first, last)`; if anything accumulated it
  pulses **one** `seek_rbn` (the reader's `S_RBN_SCAN` finds the containing cell). A sub-tick
  tap accumulates nothing → no-op.
- **`bar_*` outputs** (`bar_active`, `bar_base_rbn`, `bar_tgt_rbn`) expose the playhead + target
  position for the Phase-11 on-screen position bar — **✅ built: `dvd/seek_bar.sv`**
  (✅ HW-CONFIRMED 2026-07-10, PR fj#103): fill = playhead at hold start, amber cursor = the
  accumulating release target, + a pause/seek progress popup with chapter ticks. The status
  line shows 2-5 direction arrows while held, one per speed tier (`hud_tier`/`hud_dir`
  exports; it printed `►►×n` until 2026-09-12 — see `docs/transport_hud.md` for why a
  multiplier was the wrong glyph for an ordinal).

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
Down/Up = ∓60 s** — VLC-style *fixed-time* jumps, as opposed to §2a's hold-to-scrub,
which picks a RATE and lets the user stop when the bar looks right (that scrub's step
stopped being "percent of title" on 2026-09-12 — see §2a). Presses inside a **~400 ms window coalesce into ONE seek**,
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

**Non-DVD content — ✅ ALL LINEAR SOURCES WITH PACKS, since 2026-09-03 (issue #39).** There
is no DSI outside a DVD title, so `lin_mode` takes its step from the **`lin_blk10` port**
(blocks per 10 s of file) instead of a constant. `dvd/lin_rate.sv` supplies it:

- **Raw VCD/SVCD `.bin`** — a CD is a fixed 75 sectors/s of 2352 B and the reader's linear
  `seek_rbn` unit is a 2048-byte **file block**, so `75·2352/2048 = 86.13 blk/s` →
  **10 s = 861 blocks**. Exact for VCD's CBR mux, approximate on VBR SVCD. This is a
  *combinational bypass* in `lin_rate` — the same constant with the same timing it had when
  it was `dpad_seek`'s own `LIN_10S` parameter, so the path that already worked is
  structurally unchanged.
- **Flat `.mpg` / directly-selected `.VOB`** — the rate is **measured** from the stream's own
  PTS against blocks consumed. This was issue #39: the D-pad was inert here for want of a
  derivable rate, and the one blocking term was `emu.sv`'s `.lin_mode` being ANDed with
  `raw_mode_w`. Design, windows, rejection rules and the accuracy caveat:
  **`docs/vcd_svcd.md` §3a**.
- **Bare `.m2v`** — still inert, and **structurally so rather than by policy**: an elementary
  stream carries no packs, so `ps_demux.saw_pack` never asserts, `lin_seek_ok` is 0, and
  *neither* the D-pad *nor* B10/B11 engage. Enabling it is a real piece of work, not a flag:
  the post-seek hunt would have to target `00 00 01 B3` (a sequence header) instead of the
  pack code so the decoder has somewhere to re-lock, and the rate would need a source with no
  PTS available — either `bit_rate` exported out of `rtl/mpeg2/vld.v` (parsed at `vld.v:293`,
  currently consumed by nothing) or wall-clock block counting. Deliberately deferred; `.m2v`
  is an ffmpeg-extraction debug format, not something users load.

Note that the step is a **rate**, so a flat-file jump is only as good as the rate model: on a
bursty VBR file a "+10 s" can land ±20 % out. `emu.sv` gates `lin_mode` on the estimate being
valid, so a tap in the ~0.5 s before it arms does nothing rather than firing a jump resolved
against nothing.

**Conflict containment.** The D-pad is taken **only** where the nav layer has not claimed it:
`menu_nav` (disc menu) and `in_title_menu` (in-title game menu) both suppress it, exactly like
the rest of the title transport. Combined with the default-Off toggle, the 2026-07-28
guarantee below is preserved for anyone who does not ask for this.

**Feedback.** `pend_evt` joins `hud_user_evt`, so the position bar pops on the **first** press;
the status line renders **direction arrows only** in the shared icon field (it rendered the
tap COUNT there until 2026-09-12 — a count is not a speed, and the field now draws speed as
an arrow count, so four taps would have read as the fastest scrub tier; the magnitude was
always the popup's job anyway); and a new popup type reads
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
> chapter/menu/angle unchanged.** (A/V Offset baseline was +100 ms; it is 0 ms from 2026-09-07.)
- `tools/iso_nav_check.py`: PGC `program_map` → chapter → entry cell → sd sector.
- `bench/dvd/nav_dsi_tb.sv`: the +10 s target math byte-exact (`RBN 9580`) vs the fixture.
- `bench/dvd/iso_reader_chapter_tb.sv`: 3-chapter disc — next/prev/no-op-at-ends land on
  the right entry cell.
- `bench/dvd/iso_reader_seek_tb.sv` TEST4-8 (VOBU-align): scrub to RBN 25 (mid cell2) now
  **snaps forward to the NAV pack at RBN 26** (TEST4); an on-NAV target does not shift
  (TEST5); a target whose next NAV is in the following cell re-selects that cell (TEST6,
  cross-cell); a NAV-free stretch falls back to the raw target when the probe budget
  (`NAV_CAP`) exhausts (TEST7) or the title end is reached (TEST8).

### 2c. Mode-switch re-align — the third producer of a reader reposition (`dvd/mode_realign.sv`) — 🔧 issue #42, ⏳ HW-confirm pending

Until 2026-09-03 the reader's raw-RBN seek port had exactly one producer (`scrub_ctrl`,
with `dpad_seek` feeding its jump port). It now has two: a **live raster-mode change**
(`Video Output`) issues one as well.

**Why.** A mode switch used to fire the flush trio through `flush_ctl` **without moving
the reader**, so the decoder resumed mid-VOBU with no GOP boundary and could freeze on a
malformed frame (issue #42 — and it is not PAL-specific, despite the original report). A
chapter seek cleared it because a seek is the same trio *plus* a reader jump. So the mode
switch now becomes a seek and lets `seek_ack` drive the trio: the same contract §2a's
scrub landings use, and the one that is HW-proven to re-sync cleanly.

**The target is the playhead's own VOBU** — `dsi_nv_pck_lbn`, which already *is* a NAV-pack
RBN. `S_NAV_SEEK` therefore hits on candidate #1 and snaps nowhere: **one sector read**.
That is not an assumption; `bench/dvd/iso_reader_seek_tb.sv` TEST9 measures the probe walk
at one read per candidate over three points (on-NAV 3 reads, one-short 4, five-short 8), so
targeting the *next* VOBU instead would cost up to `NAV_CAP = 1024` reads. Re-reading the
VOBU being parsed also re-supplies roughly what the VBUF flush discards, so nothing is
skipped.

**Arbitration lives in `mode_realign`, and the scrub always wins the mux.** Even in a state
its FSM does not allow, the reader latches the user's target rather than the re-align's,
and the resulting `seek_ack` completes the arm — self-healing, with no cycle in which the
reader can see a pulse carrying the wrong target. `emu.sv` keeps `seek_rbn_pulse`/`seek_rbn`
as the reader-facing names; `scrub_ctrl` now drives `scrub_seek_pulse`/`scrub_seek_rbn`.
⚠ `hud_user_evt` must watch the **scrub's** pulse: a re-align is not a user transport
action and must not pop the HUD.

**Inherited rules, both load-bearing:**

- The **stale-table rule** from §2b applies verbatim. `nav_dsi` is on `pipe_rst_n`, so any
  `load_flush` — including the one this seek itself causes — zeroes `dsi_nv_pck_lbn`, and
  the containing-cell clamp turns a zero target into a jump to the start of the title. The
  base is gated on a `dsi_fresh` latch and latched exactly **once**, on the issuing cycle.
- A **`keep_vbuf` ack is not a completion.** A menu→menu hop fires `load_flush` only, so it
  does not give the mode switch the trio it needs; such an ack leaves the arm open and the
  watchdog fires the in-place fallback — correct, because by then we are in a menu, where
  the VOBU snap is bypassed anyway.

**Where a re-align is impossible, behaviour is exactly as it was:** the menu domain, a raw
`.m2v` (`lin_seek_ok_o` is already low for a bare elementary stream), a reader parked on a
still, or a seek unacknowledged within ~0.5 s — all take `flush_ctl.mode_switch`, the
in-place trio. Note `seek_jump` has **no state qualifier** (unlike `jump_go`), which is
why `still_active` has to be excluded explicitly: a re-align would otherwise fire from
`S_STILL` and restart a title-domain timed still.

**Path exactness by media type:**

| media | landing |
|---|---|
| DVD title (cell mode) | exact — the target is a NAV pack, snap is a no-op |
| flat `.mpg` / `.VOB` | exact (`strm_blk <= ls_tgt`) **and** arms the `00 00 01 BA` pack hunt |
| raw MODE2/2352 `.bin` (VCD/SVCD) | ≈ **0.07 % early** (`ls_sec = r − r/8 − r/256 − r/1024`), i.e. up to ~2–3 s of rewind late in a long image — the same landing every VCD scrub already produces |
| raw `.m2v` | not seekable; takes the fallback |

Design + the RED/GREEN evidence: `docs/single_raster_analog.md` §6. Suite:
`bench/dvd/run_mode_realign.sh`.

### 2d. Trick play (continuous 2×/4×/… playback) — ❌ NOT BUILT, and NOT a variation on seeking

Recorded 2026-09-03 so the next session starts from facts. Everything above **repositions**
the reader and lets the flush contract re-lock; trick play must do the opposite — never flush
at all — and that is why it is a separate feature rather than another seek mode.

**Scaffolding that already exists** (check the map report after wiring any of it):

- `dvd/nav_dsi.sv` already parses **`dsi_1stref_ea`** — the end of each VOBU's first reference
  picture, i.e. the I-frame-masking field a trick mode needs (`nav_dsi.sv:51`; the comment
  says exactly that). It is **unconnected in `emu.sv`** and therefore dead-stripped today.
  Wiring it back will resurrect logic, exactly as re-wiring `dsi_tbl_raddr` did for D-Pad Seek
  — that one showed `nav_dsi` at **16 ALMs / 0 memory bits** in the fit report beforehand.
- The decoder's upstream `REG_WR_TRICK` register carries `repeat_frame[9:5]` + `persistence`
  and is already used to hold a picture during pause — the native hook for showing each
  I-frame for N refreshes.
- `dvd/transport_hud.sv` already renders the tier as an arrow count, and `dvd/scrub_ctrl.sv` already owns
  FF/REW with an acceleration tier.

**The hard constraint.** The splice must be **flush-free**. `dvd/dpad_seek.sv`'s header
records that a jump per VOBU is "exactly the rapid flush/re-lock regime that HW rounds 1–2 of
the scrub proved fatal (mostly-black playback + watchdog resync)" — so the reader must deliver
`[nv_pck_lbn .. +1stref_ea]` per VOBU and splice VOBUs back to back into **one continuous
bitstream** (every splice is a pack boundary, so `ps_demux` is fine), with `av_sync`
free-running and audio muted. Reverse uses `bwda`/`prev_vobu` the same way. It is **DVD-only**:
flat and VCD sources have no DSI and would need GOP-header scanning instead.

It also carries a UX decision — whether hold-FF *becomes* trick play or the proven
scrub-to-target keeps B10/B11 — and it needs its own HW round.

### 2e. Seamless-branch discs break the position→time map — ❌ OPEN (2026-09-03)

Recorded from a field report on `ALIEN_VS_PREDATOR_SE_DISC1` after the cell-gap
fix (§2d/`docs/transport_hud.md`) resolved the simpler case. **This is a
different defect and it affects SEEKING, not just the readout.**

**Measured** (`tools/iso_nav_check.py` + a direct IFO walk of VTS_03 PGC1):

- 66 cells, monotonic, non-overlapping, only 2.7 % gaps — so the §2d gap fix
  does **not** cover it.
- **23 of the 66 cells have the `interleaved` bit set** (cell category `0x0c` /
  `0x0e`, bit 2 of playback byte 0). The disc is a seamless-branch title:
  theatrical and extended cuts share sectors, interleaved in ILVUs.
- Consequence: an interleaved cell's `first…last` range **contains the other
  branch's ILVUs**, so `last − first` overstates its played sectors. Those cells
  compute at **885–1679 sectors/s against a DVD ceiling of ~600**, a 12.7× spread
  across the title. Any RBN→time model that trusts the cell extent is wrong there
  by roughly the interleave factor.

**Two distinct problems, and the second is the important one:**

1. *The preview interpolates over sectors that are not the cell's.* Bounded and
   cosmetic. Cheap mitigation if wanted: the reader already parses the category
   byte into `cell_cat_mem`, so `seek_time` could refuse to interpolate inside an
   interleaved cell and report the cell boundary instead of a confidently wrong
   time. Exact interpolation needs ILVU-level knowledge (the DSI carries ILVU
   pointers, parsed by `nav_dsi`).
2. **A raw-RBN seek into an interleaved region can resolve to the wrong branch.**
   Field report: "seeking back and forth I can get it in a state where the live
   timeline reports a couple of seconds in when it's really much further". The
   live clock is `cur_cell_start + dsi_c_eltm`, which is EXACT when `cell_i` is
   right — so a wrong readout there means the reader's RBN→cell scan
   (`S_RBN_SCAN`) landed on the wrong cell, which means playback itself resumed
   in the wrong branch. ⚠ Note the asymmetry: normal ILVU **playback** is
   HW-CONFIRMED (PR fj#112, see "Seamless-branch interleaved blocks" below)
   because it follows the DSI's ILVU pointers. Raw-RBN **seeking** into that
   space is a different path and was never covered.

⚠ **"Seeking jumps to the end" had TWO mechanisms and this is only one of them.**
The dominant one — the title span itself collapsing on a PGC whose cells are not
in physical order — is **fixed** (§2f, 2026-09-13) and covered 44 of the 51
affected library discs. What is left here is the interleave: 7 discs whose PGC
cells are genuinely SCATTERED, plus the seamless-branch class below, where a
cell's sector extent lies about how much of it is played. §2f's change 2 also
removed the "a miss plays the LAST cell" fallback that made a gap landing look
exactly like this defect, so a report of "it jumped to the end" on a
seamless-branch disc now really is about branch resolution and not about either
of those.

**Where to start:** `S_RBN_SCAN` (`dvd_iso_reader.sv`, the `S_RBN_SCAN2`/`S_RBN_SCAN`
pair — ⚠ the old "~3714-3766" here was already stale and is deliberately not
replaced with another line number) and the
`seek_is_rbn` landing contract in §2a. The likely shape is that a seek target
inside an interleaved block must be snapped to an ILVU boundary of the branch
being played, the way `S_NAV_SEEK` already snaps a scrub target to the next NAV
pack. ⚠ That is the reader's seek path — the boot path for every disc — so it
wants the full 33-testbench gate and its own HW round, not a rider on a readout
fix.

### 2f. Program order is not physical order — FOUR defects, one assumption — ✅ FIXED + HW-CONFIRMED 2026-09-14

Field report: on `A_MILLION_WAYS_TO_DIE_IN_THE_WEST` (physical disc *and* the
decrypted ISO) **any seek jumped to the end of the movie**, the **chapter notches
were missing** from the seek bar, and the **bar was a solid grey block**. All
three are one defect, and it is in the reader's span capture, not in any of the
three modules that show the symptom.

**Root cause.** `dvd_iso_reader.sv`'s PGC cell walk took `title_last_rbn` from the
LAST-WRITTEN cell, and said so:

```systemverilog
// title_last tracks the last-written cell's last_sector (cells are
// captured in order, so after the walk this is the title's end RBN).
title_last_rbn <= {wacc, pb_rdata};
```

★ **The assumption is stated in the comment, and it is false.** Program order is
not physical order. Measured from the disc (VTS_07 PGCN 1, 22 cells, 1:55:54):

| | |
|---|---|
| cells 0..20 | RBN 4 … 3,359,267, perfectly ascending |
| **cell 21 (the LAST program)** | **RBN 0 … 3 — 4 sectors, physically at the FRONT of the VOBS** |

so the reader published `title_first_rbn = 4`, **`title_last_rbn = 3`**.

**One wrong number, three symptoms**, each in a module that is itself correct:

| symptom | mechanism |
|---|---|
| any seek jumps to the end | `scrub_ctrl.sv` `span = (last > first) ? last-first : 1` → **1**, and the clamp pins every target at `title_last_rbn` = 3. `S_RBN_SCAN` resolves RBN 3 to **cell 21 — the last program** → 4 sectors play and the PGC ends. |
| solid grey bar | `seek_bar.sv` `dv_delta = (dv_v >= last_rbn) ? span` → quotient 512 → `fill_px = 512`, the full bar width. |
| no chapter notches | the same saturation puts every `tick_col[]` at 512, outside the 0…511 raster. |

⚠ The playhead is always above 3, so **backward seeks clamp there too** — the
report's "will not tolerate a seek" is exact, not loose. And `scrub_ctrl`'s
**jump port** shares that clamp, so **D-pad fixed-time seek (`O[45]`) and A-B
repeat are broken by the identical mechanism** on these discs.

#### Blast radius — measured over the 958-ISO library

**51 discs (5.3 %)**: 45 publish `last <= first` (span 1, completely unseekable)
and 6 more publish a materially short span. Classified by coverage
(`sum(cell lengths) / (max last − min first + 1)`):

| class | count | the fix below |
|---|---|---|
| **CONTIGUOUS** (≥ 95 %) — one physical run plus a displaced cell | **44** | repaired completely |
| **PARTLY SCATTERED** (~50 %) — GoT S1 D2/D5, GoT S3 D1, ELEMENT_YOGA | 4 | improved, not repaired |
| **SCATTERED** (< 40 %) — VINYL S1 D2, PAW_PATROL_MEET_EVEREST, CYOA-ABOMINABLE_SNOWMAN | 3 | improved, not repaired |

The dominant shape is `first = k, last = k − 1` — the last program cell occupying
RBN `[0, k−1]`, with k measured at 4, 5, 30, 78, 142, 145, 200, 248, 373, 430,
690 and 32,693 on different discs.

Replaying the new rule offline over all 955 parseable images:

| | before | after |
|---|---|---|
| discs whose `title_last_rbn` changes | — | 48 |
| degenerate spans (`last <= first`) | 45 | **0** |
| mean fraction of played sectors inside the published span | 0.9483 | 0.9948 |
| discs with < 99 % of played sectors inside the span | 51 | **5** |
| **discs made worse** | — | **0** |

#### Change 1 — `title_last_rbn` is the MAXIMUM over the PGC's cells

```systemverilog
if (cell_wi == 8'd0 || cell_last_w > title_last_rbn)
    title_last_rbn <= cell_last_w;
```

★ **STRUCTURAL, not merely better.** `max(last) >= cell[0].last >= cell[0].first
= title_first_rbn`, so a degenerate span is now **impossible by construction** for
any PGC with a well-formed cell 0 — not merely unlikely, and not dependent on any
property of the disc.

★ **The `cell_wi == 8'd0` seed is load-bearing twice, and both were measured, not
argued.** `cell_wi` is zeroed only in `S_PGC_CELLCHK`, immediately before every
walk, and nothing else clears `title_last_rbn` between PGCs (the mount re-init
does not touch it). Without the seed:

1. a feature title's span **leaks into the next PGC** — including the menu the
   user returns to, and a second title after a remount (`title_span_tb` arm F);
2. on the **first** walk the reader's *linear* branch has already published
   `total_blocks - 1`, so a bare `max()` keeps the whole IMAGE's last block and
   the forward clamp stops clamping at all (arm D).

The second one was found by the mutation harness, not by design — the arm was
expected to catch F alone and caught D as well.

#### The mirror shape, and why ONE number could not serve both

⚠⚠ **The first cut of this fix kept `title_first_rbn` as cell 0's `first_sector`
and argued at length that the minimum would be wrong. The argument was sound and
the conclusion was still incomplete** — because the disc population is symmetric
and a single value has to be wrong for one half of it:

| shape | who | one value as `cell[0].first` | one value as `min(first)` |
|---|---|---|---|
| **last** program parked at RBN 0 | A_MILLION_WAYS, ~34 more | correct | a rewind past the start lands in it = **jump to the END** |
| **first** program parked at the TOP | BIG_TROUBLE_LITTLE_CHINA + 4 | span collapses, the low clamp fires on every seek = **back to the BEGINNING** | correct |

The second row was found on hardware after the first cut shipped to the rig:
*"seeking always brings you back to the beginning of the title"*, on a disc whose
`cell[0]` sits at RBN 2,032,273 of 2,032,309 with the other 59 cells below it. ★
The bar there did **not** go solid — it went **EMPTY**, because the playhead
spends the film *below* `title_first_rbn` and `dv_delta` floors to 0 instead of
saturating, with 44 of 45 notches piling up at column 0. Same degenerate span,
opposite direction.

**So the reader publishes FOUR numbers, not two:**

| | | answers |
|---|---|---|
| `title_first_rbn` | `min(first_sector)` | how wide is the title, and what may a target address |
| `title_last_rbn` | `max(last_sector)` | ″ |
| `title_start_rbn` | `cell[0].first_sector` | where does "rewind past the beginning" land |
| `title_end_rbn` | `cell[N-1].last_sector` | where does "wind past the end" land |

and `scrub_ctrl` stops a gesture that **CROSSES** a program end *from inside*:

```systemverilog
wire cross_lo = ~pending_dir && (bar_base_rbn >= title_start_rbn)
                             && (tgt_acc      <  title_start_rbn);
wire cross_hi =  pending_dir && (bar_base_rbn <= title_end_rbn)
                             && (tgt_acc      >  title_end_rbn);
```

★ **Written as a CROSSING and not as a clamp, and that is the whole trick.** The
"from inside" test is what keeps it inert on a disc whose playhead legitimately
sits outside `[start, end]` in RBN terms — which is exactly BIG_TROUBLE. A plain
low clamp cannot tell "you rewound off the front of the film" from "you are
simply below cell 0's address", and firing on the second is the reported bug.

★★ **The property that makes this safe: on a well-ordered PGC `start == first`
and `end == last`, so both rules reduce EXACTLY to the clamps they replace and
ordinary discs are bit-identical.** MEASURED over the library: `start`/`end`
differ from `first`/`last` on **51 of 955** discs — precisely the affected set —
so **904 discs cannot be moved by this change at all**. And the envelope now
covers 100 % of played sectors on *every* disc (worst case 1.0000), so a
degenerate or under-covering span is impossible rather than merely unlikely.

⚠ The whole of `scrub_ctrl_tb` passes **unchanged** with `start`/`end` defaulted
equal to `first`/`last`, which is that bit-identity claim made executable.

⚠ **Accepted, bounded residual:** the max now lets any malformed cell record
inflate the span, where before only a malformed *last* cell could.
`nr_cells > MAXCELL` already routes garbage PGCs to the linear fallback and
`S_CELL_SEEK` already skips `cf_rd > cl_rd` cells, so this was not worth a second
comparator.

⚠ **Cosmetic residual:** the bar still maps PHYSICAL RBN, so on a disc whose
program order is not its physical order the playhead moves around the bar out of
order — on A_MILLION_WAYS the final 4-sector cell draws its notch at column 0,
and on BIG_TROUBLE the first program draws at the far right. Seeking is correct;
only the picture of *where you are* is scrambled, and only on these 51 discs.
Fixing that properly is the position-space model, below.

#### Change 2 — a `S_RBN_SCAN` miss must not play the LAST cell

```systemverilog
// not found -> clamp to the last cell, play from its start
cell_i <= cell_count - 8'd1;
```

★ **"Play the last program cell" IS "jump to the end of the movie"** — the same
user-visible symptom as change 1, arriving by a second route. After change 1 it
is unreachable on the 44 contiguous discs (every clamped target lies inside some
cell), but it remains reachable wherever a PGC's cells are not contiguous, and
for any target below every cell. ⚠ An earlier draft tied that to "the 7 scattered
discs"; the post-fix measurement above shows that set is not what is left, so the
justification here is the MECHANISM, not a disc count.

The miss now lands on the cell that **starts nearest below** the target
(`rbn_best_*`, tracked during the scan and evaluated combinationally so the
exhaustion arm can use a candidate found on the final cycle), with
`rbn_override` cleared — the target is in a gap, so streaming from `seek_rbn_l`
would read sectors that are not that cell's. Below every cell it lands on
**program cell 0**: a target under the first cell is a rewind past the start, not
a jump to the end.

⚠ This does **not** fix the scattered discs; it stops them landing at the *wrong
end*. `iso_reader_scrub_tb` TEST 4 (out-of-range RBN on an in-order 4-cell disc)
picks the same cell under both rules and is byte-identical, which is what
confines the delta to real-world shapes.

#### Gate — `bench/dvd/run_title_span.sh [--red]`

★ **A reader-only bench CANNOT catch this, and that is the reusable lesson.**
`title_last_rbn` reaches the reader's own behaviour in exactly one place — the
`nav_cand > title_last_rbn` bail in `S_NAV_SEEK`, which only shortens the
VOBU-align probe and then falls back to the raw target anyway. A bench that
drives `seek_rbn_pulse` directly (`iso_reader_scrub_tb` does) lands at the same
RBN with or without the fix. The defect lives at the **seam**: the reader
publishes the span, `scrub_ctrl` clamps to it, the reader lands on the clamped
value. Same shape as the A-B `jump_dir` miss — *assert against the consumer's
contract, across the seam*.

`bench/dvd/title_span_tb.sv` therefore instantiates **both** modules over a
synthetic disc that mirrors the measured shape (4 cells × 10 sectors, program
cell 3 at RBN 0…9 and cells 0…2 at 10…39, every sector filled with a byte equal
to its own RBN). Every arm measures the **landing** — the first bytes actually
delivered plus the cell they came from — never a signal the fix names.

★ The `SHn` ladder is left at its shipping values on purpose: `span 29 >> 13` and
`span 1 >> 13` both floor to a 1-sector step, so the accumulate is identical
pre- and post-fix and **the clamp is the only variable**.

| arm | GREEN | RED (pre-fix) |
|---|---|---|
| A fixture sanity | RBN 10, cell 0 | same — not a gate |
| B forward 15 → 23 | RBN 23, cell 1 | RBN 9, **cell 3 = the last program** |
| C backward 35 → 27 | RBN 27, cell 1 | RBN 9, cell 3 |
| D forward clamp | RBN 39 (the real end) | RBN 9, cell 3 |
| E backward underflow | RBN 10 (cell 0's start) | RBN 9, cell 3 |
| F per-PGC re-seed | VTS_02 clamps to its OWN 9 | (mutation-only) |
| G gap landing (`+TITLE_SPAN_GAP`) | the cell below the gap | the last cell |

⚠ Arm D asserts the **byte only**. Its target *is* the title's final sector, so
there is one sector of runway and the reader's prefetch has already advanced
`cell_i` by the time the byte reaches the output. The byte still pins the landing
uniquely (cell 3 holds RBN 0…9, whose sectors can never contain byte 39).

`--red` runs five sed mutations of the reader and requires that **exactly** the
designed arms fail — no more, no fewer, because a mutation caught by everything
says nothing about which arm is load-bearing:

| mutation | must fail |
|---|---|
| M1 the pre-fix last-written rule | B C D E |
| M2 drop the cell-0 re-seed | D and F |
| M3 take the MIN instead of the MAX | B C D E F |
| M4 `title_first` becomes `min(first)` | **E only** |
| M5 change 2 reverted to the last cell | **G only** |

`scrub_ctrl_tb` TEST 20 is a **contract arm, not a gate**: it drives the real
measured pair (`first = 4, last = 3`) and asserts `scrub_ctrl` pins both
directions at 3 — i.e. that the consumer is *correct given a correct span*, so a
future session fixes the producer rather than loosening the clamp.

⛔ **No committed library-sweep tool** (user decision, 2026-09-13), reversing the
`tools/acmod_scan.py` precedent for this one case: the structural guarantee above
means a degenerate span cannot recur, so a standing sweep would only ever confirm
what the RTL makes impossible. The measurements in this section were taken with
throwaway scripts; reproduce them by walking each VTS's `VTS_PGCIT` PGC cell
table and comparing `cell[nr-1].last_sector` against `max(last_sector)`.

#### HW round — ✅ CONFIRMED 2026-09-13, on the reported disc

Build `DVD_titlespan_20260913_2203.rbf` (SEED 7 first roll despite the new
registers, clk_dec 94.32 @100C / 92.1 @-40C against the 86.0 gate, 88 % ALM),
driven over the HIL harness on `A_MILLION_WAYS_TO_DIE_IN_THE_WES`. The board
reported `CH 1/7` under `Debug Overlay=On` — reader PGCN 1, VTS 7, i.e. **the
exact title this section measures** — with `1:55:54` and `21` chapters matching
the IFO.

★ **The notches were checked against the DISC, not against the core.**
`seek_bar`'s own published formula was applied to the chapter table read
straight out of the ISO, and the expected columns compared with the columns
measured in a screenshot. A core that placed its notches somewhere
self-consistent but wrong would still fail this.

| measurement | pre-fix (predicted) | measured on the board |
|---|---|---|
| bar fill at 0:02:03 of 1:55:54 | 512/512 — a solid block | **column 5 of 512** |
| chapter notches | none (all pushed to 512) | **19**, total residual **1 px over 19** |
| forward burst (8 taps) | jump to the end | **0:07:16 → 0:08:52** (+87 s), playback continues |
| backward burst (8 taps) | jump to the end | **0:09:24 → 0:08:18** (−75 s) |
| A-B repeat (shares the clamp) | escapes / runs away | held **0:09:08–0:09:28** for 90 s |

⚠ **The +10 px offset between the nominal `X0` and the captured raster is
harness geometry, not the core** — it is fitted, not assumed, and it matches the
`xoff -9` the harness's own HUD decoder reports independently. An unfitted first
pass read a constant −10 on 18 of 19 notches and looked exactly like a
systematic placement error.

★ **The predicted residual was confirmed as predicted:** chapters **1 and 21**
both resolve to column 0 and sit inside the fill. Chapter 21 is the displaced
4-sector cell — written down before the build, found after it.

⚠ **What this round did NOT test: the gamepad HOLD-to-scrub gesture.**
`dvd/kbd_map.sv` deliberately masks `kbd_joy[14:13]` out of `joy_eff` and routes
keyboard Fast Fwd/Rewind to `dvd/dpad_seek.sv`, because an IR "hold" is ~9
discrete taps a second — the flush/re-lock regime HW rounds 1–2 proved fatal. So
the measurements above exercise `scrub_ctrl`'s **jump** port. That port shares
the identical `target` clamp, which is the thing under test, but the held
gesture itself needs a physical gamepad.

★ Control: a disc from the healthy 903 (`1NIGHT_MCCOOLS`) seeks normally in both
directions on the same build (+87 s / −37 s, matching the tap counts).

#### HW round 2 — ✅ CONFIRMED 2026-09-14 on BIG_TROUBLE_LITTLE_CHINA

Build `DVD_titlespan_20260914_0100.rbf` (SEED 7 first roll, clk_dec 94.25/90.11
against the 86.0 gate, 90 % ALM). The maintainer confirmed seeking and chapter
markers on the test discs; the measurements below are from the harness.

| symptom | before | after |
|---|---|---|
| chapter notches | 2 marks, 44 of 45 misplaced, residual **5116 px** | **42 marks, 0 of 45 misplaced, residual 6 px** |
| forward seek | to the beginning of the title | `0:00:42 → 0:02:19` (+87 s) |
| backward seek | to the beginning of the title | `0:02:47 → 0:02:25` (−32 s) |
| preview clock | `0:00:00` for the whole gesture | tracks the target |

★★ **The preview clock could not be measured until the press and the captures
were sequenced ON THE TARGET.** The preview lives for the gesture's ~400 ms
window plus `scrub_ctrl`'s ~1.5 s linger — about 2 s — while ssh-paced
screenshots land ~5 s apart, so the first attempt sampled *around* it three
times and saw nothing. Injecting the key and then firing four `screenshot`
commands from one ssh session, with `sleep`s between them on the box, put the
samples where they were needed:

```
pre-fix, paused at 0:03:07        fixed, paused at 0:00:31
  t1 (~0.25 s): 0:03:17             t1 (~0.25 s): 0:00:41
  t2 (~0.85 s): 0:00:00   <-- bug   t3 (~1.45 s): 0:00:42
  t3 (~1.45 s): 0:00:00   <-- bug   t4 (~3.45 s): 0:00:44
  t4 (~3.45 s): 0:03:20
```

⚠ Same sample point, both builds, so it is a matched comparison rather than an
absence of evidence. ⚠ Roughly one capture in four does not get written at a
0.6 s spacing — the shot writer needs longer — so read a missing sample as
missing, not as clean.

✅ **The gamepad HOLD-to-scrub gesture is CONFIRMED too (maintainer, 2026-09-14:
"hold to scrub works fine").** That was the one arm the harness structurally
cannot reach — `kbd_map.sv` routes keyboard Fast Fwd/Rewind to `dpad_seek`, so
every measurement above goes through `scrub_ctrl`'s JUMP port instead. Same
`target` clamp, different gesture, and it needed a person with a pad.
⚠ It also retires the open question about burst size: roughly one 8-tap harness
burst in three moved ~+9 s rather than ~+87 s, which was attributed to taps
landing outside the ~400 ms coalescing window over ssh rather than to the core.
A held gesture does not coalesce at all, so a clean hold is the control that
attribution wanted.

#### ⛔ Non-goals — do not re-derive these

1. **Position-space progress** (cumulative played sectors instead of physical
   RBN) is the only model that is correct on a PGC whose cells are neither
   contiguous nor in order, and the only thing that puts the displaced cell's
   notch in the right place. (The 5 `cell[0]`-is-late discs above do NOT need it
   — they need the cheaper third-signal split described there.) **It is
   measured useless for the seamless-branch class** — see §2e: an interleaved
   cell's sector extent contains the other branch's ILVUs, so the per-cell
   sector length is itself inflated (`ULTIMATE_T2` VTS_01 PGCN 1: 122 cells,
   physically **monotonic**, 35 interleaved, 32 of them over-stating their
   playtime by 1.3×–4.6×, up to **2,786 sectors/s** against a ~600 DVD ceiling;
   `ALIEN_VS_PREDATOR_SE` measures the same way). A **time**-based bar
   (`C_PBTM` prefix sum, already in `cell_start_mem`/`cellf_secs`, plus DSI
   `c_eltm`, already used by `transport_hud`) is the model that would cover both
   classes. Its own change, its own HW round.
2. **`cellf_idx = cell_wi[6:0]`** is a latent 7-bit alias into `seek_bar`'s
   `cellf_ram[0:127]`. **Measured unreachable:** zero discs in the 958-image
   library have a played PGC over 128 cells (the histogram tops out in the
   96…127 bucket with 8 discs).
3. **`scrub_ctrl` and `seek_bar` are NOT changed.** Both are correct given a
   correct span; a defensive span floor there would mask the producer.

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
   `play_blk` reaches the end of that VOBU (`ilvu_end_rbn`). The jump routes through the
   `rbn_override` cell-load (streams from the raw target RBN) but does **not** reset
   `wr_ptr` and does **not** pulse `seek_ack` → the timeline is continuous (`av_sync`
   untouched). If `target > last_sector` there is no jump — `play_end` bounds the final
   ILVU and the cell ends normally.
   The target comes from `sml_agli[cur_angle-1]` when the disc authors one and from
   `vobu_sri.next_vobu` when it does not — see "No `sml_agli`" below.
   *(Corrected 2026-09-15: this step used to describe an `S_CELL_SEEK` remap with
   `seek_target = target·4` and a `keep_vbuf` pulse. The shipped code has used
   `rbn_override`/`seek_rbn_l` since the sd-2048 rework; the old wording was stale.)*
3. **Block skip**: an angle-block cell's end advances to `block_first + angle_count`
   (the common cell 6), skipping the sibling angle cells.
4. **Angle switch**: `angle_pulse` (emu B6) increments `cur_angle` (wrap 1..`angle_count`);
   with an `sml_agli` table it takes effect at the **next ILVU boundary** (the jump reads
   `cur_angle` live), so the switch is seamless. The pulse is a **no-op outside an angle
   block** — it is guarded on `angle_count >= 2`.
   *(Corrected 2026-09-15: this used to say the pulse "just updates the number for the UI"
   outside a block. It does not; the RTL guards it.)*
4b. **The disc's own choice**: a PGC's PRE commands may set the angle with
   `SetSTN ... AGLN`, which the VM latches in SPRM3. `dvd_vm.sprm_agln` → emu's
   `vm_owns_angle` arbitration (identical in shape to the audio/subpicture one) →
   the reader's `agl_vm`/`agl_vm_en`, consumed at `S_ANGLE_PICK`. A B6 press releases
   the VM's claim **and writes SPRM3 back** (`agl_set`), because discs read `AGLN`
   into a GPRM and re-apply it. See "The disc picks the angle" below.
5. **Exposed**: `cur_angle` / `angle_count` (0 when not in an angle block) → emu status/UI.

Non-interleaved cells and all earlier phases are byte-for-byte unchanged (the snoop +
angle-cell logic is gated on `block_type==1`). Golden tool: `tools/nav_extract.py --angles
--title-vob 1` (ILVU flags + per-angle target map). Tests: `bench/dvd/iso_reader_angle_tb.sv`
(synthetic 2-angle interleaved block with distinct per-angle marker bytes — proves only the
selected angle streams, in order, and a clean mid-block switch) + the real MiB fixture for
byte-exact target math, plus `nav_dsi_tb` category assertions; all reader/demux/nav suites
stay green.

### No `sml_agli`: the follow pointer is `vobu_sri.next_vobu` (2026-09-15, Studio Ghibli)

> **Status: ✅ HW-CONFIRMED 2026-09-15** (build `DVD_anglefollow_20260916_0353.rbf`, SEED 7
> first roll, clk_dec 94.41/90.40 vs the 86.0 gate). Field report on
> `CASTLE_IN_THE_SKY.iso`: *"there are multiplexed versions of the title to show the
> localized or Japanese version. Currently the core switches rapidly between the two angles
> rather than sticking to one."* A second user, on unnamed Ghibli discs: *"starts playing
> the English version then makes a pop noise and then switches to Japanese for a second then
> back to English... There are 2 different versions of the logo and text when the movie
> starts."*

★★ **A MULTI-ANGLE DISC NEED NOT AUTHOR `sml_agli` AT ALL, AND PHASE 9 REQUIRED IT.**
The arm was `snoop_done && angle_active && snoop_is_last && snoop_valid`, where
`snoop_valid` means `sml_agli[cur_angle-1] != 0`. MEASURED with
`tools/nav_extract.py --angles --title-vob 1`: on **CASTLE_IN_THE_SKY VTS_02 PGC1** and
**DIEANOTHERDAY_D1_PS VTS_05 PGC1**, *every* VOBU of *every* angle block reports
`sml_agli: (none)` while `vobu_sri.next_vobu` is populated and correct — Castle RBN 491
`BLOCK|LAST` → `next_vobu = +755` → RBN 1246, which is angle 1's next ILVU, stepping over
angle 2's ILVU at 692..1245. So no jump ever armed and the reader streamed the cell's
`[first..last]` **linearly** — and that range physically contains both angles.

★★ **libdvdnav never has this problem because the preference order is the other way round.**
`dvdnav.c:434` sets `vobu_next = vobu_sri.next_vobu` as the BASE for every VOBU, and the
`sml_agli` block at `:452-468` only *overrides* it at an ILVU boundary. We made the override
mandatory. **The fix restores the reference order**: `sml_agli` when present, `next_vobu`
otherwise. The `next_vobu` decode is not new — it is the HW-proven seamless-branch path
(PR fj#112), which is why this costs no new snoop bytes.

⛔ **NOT `sml_pbi.next_ilvu_sa`** (DSI 0x26). It yields the identical target on both measured
discs, but it is a new snoop field and a new decode where `next_vobu` is already captured at
sector `0x541`, already validated, and is literally what the reference player uses.

⛔ **NOT the cell's `seamless_angle` bit** (category byte 0, bit 0), even though it predicts
`sml_agli` presence perfectly across all 23 swept discs. That is a DECLARATION in the IFO,
and this fork has been burned repeatedly trusting declarations over measurement
(`progressive_frame`, IFO channel counts, the 205-of-216 empty angle-menu stubs). Key on the
snooped VALUE. `seamless_angle` is used only as the library-sweep discriminator below.

**It is an AUDIO defect too, which is the second reporter's "pop".** Each angle's ILVU
carries the SAME timespan of audio — MEASURED on Castle, angle 1 ILVU 1 = PTS 0.243..2.387 s
and angle 2 ILVU 1 = 0.243..2.259 s, with **all three substreams (0x80 en 5.1 / 0x81 ja 2.0 /
0x82 fr 2.0) present in both**. Linear streaming therefore delivers every timespan twice and
the PTS jumps **backward ~2 s at every junction**, past `disp_sched`'s 0.5 s re-anchor
threshold; the partial AC-3 frame straddling the junction is dropped by `ac3_reframer` as a
silent gap. The cells carry `stc_discontinuity = 1` because each ILVU is its own STC epoch.
⚠ Scope stated honestly: on *Castle* both angles carry the identical substream set, so a
fixed track filter stays in one language and the reported "switches to Japanese" is most
likely the Japanese title card plus the repeat; on another disc the angles could carry
different audio sets and the language would flip outright. The fix cures both — the sibling
ILVUs stop reaching the demux at all.

**Blast radius — swept, not guessed.** Every `.iso` in the library, scanning all title PGCs
of every VTS a multi-angle title points at: **23 discs have `block_type==1` angle blocks**,
split cleanly by `seamless_angle`:

| `seamless_angle` | `sml_agli` | discs | examples |
|---|---|---|---|
| 0 | absent, so **was broken** | **4** | `CASTLE_IN_THE_SKY` (3 blocks), `DIEANOTHERDAY_D1_PS` VTS05 (**19** blocks across a 2:12 feature), `MISSMARS` VTS05 (3 angles), `WITHOUTAPADDLE43` VTS03 (9 blocks) |
| 1 | present, already correct | 19 | `MEN_IN_BLACK` (the fj#98 HW vehicle), `Beauty_and_the_Beast`, `BOOK_OF_LIFE`, `GOLDMEMBER`, `DIE_ANOTHER_DAY_DISC2` |

⚠ **Known limitation, deliberate (maintainer decision):** on a disc with no `sml_agli` a
mid-block **B6 press takes effect at the next angle block**, not at the next ILVU. There is
no per-angle table to retarget with — `next_vobu` follows the chain of the angle whose VOBU
was just read and says nothing about the siblings, so re-pointing `cell_i` at another angle's
cell would bound this angle's target by the wrong cell. `ilvu_from_agli` records which source
armed the jump and gates the re-point accordingly. ⛔ Do **not** "fix" this with a flushing
seek to the sibling cell's `first_sector`: that restarts the segment, and on Castle the third
angle block is the 3-minute end credits.

**Gate: `bench/dvd/run_angle.sh --red`.** `angle_noagli_tb` runs the real reader over a
synthetic 2-angle block using Castle's own cell-category bytes (`0x56`/`0xD6`), with
`sml_agli` zeroed and the chain only in `next_vobu`, and scores **the delivered byte stream**
(which angle's marker bytes came out) plus **the PTS carried in it** — never a signal the fix
names. Pre-fix it measures `A2=4068` (the sibling angle's bytes) and PTS
`100 100 200 200 300` (the duplicated timespans); post-fix `A2=0` and `100 200 300 400 500`.
`iso_reader_angle_tb` (the `sml_agli` MiB shape) and `iso_reader_ilvu_tb` (seamless branch)
are **byte-identical** to the pre-change reader, which is what confines the delta to those 4
discs.

★ **Golden model: `tools/nav_extract.py --vts N --ilvu-angles`.** `--ilvu` used to
`continue` on `block_type == 1`, so it could not describe an angle block at all; the new flag
walks each angle's `next_vobu` chain and reports whether the disc authors `sml_agli`. It is
the same walker the seamless-branch predictor uses, which is itself the point — the two cases
follow the same pointer. Measured:

```
CASTLE_IN_THE_SKY  --vts 2  --ilvu-angles
  cell  0 [bm=1 bt=1 il=1 sa=0]  sml_agli ALL ZERO
          first=0      ilvu_end=691     last=8236    ILVUs=5  jumps=4  played=4591  skipped=3646   nav_ok OK
  cell  1 [bm=3 bt=1 il=1 sa=0]  sml_agli ALL ZERO
          first=692    ilvu_end=1245    last=8852    ILVUs=5  jumps=4  played=4262  skipped=3899   nav_ok OK
  cell 32 [bm=1 bt=1 il=1 sa=0]  (end credits)  ILVUs=86 jumps=85 played=69967 skipped=69469  nav_ok OK

MEN_IN_BLACK       --vts 14 --ilvu-angles      (the CONTROL)
  cell  0 [bm=1 bt=1 il=1 sa=1]  sml_agli populated 0x3cb 0x51c 0x666 0x7b0 0x8fa
          first=0      ilvu_end=197     last=155664  ILVUs=90 jumps=89 played=30540 skipped=125125 nav_ok OK
```

Every chain on both discs reaches `END_OF_CELL`, and the played/skipped split is ~1/2 on
Castle (2 angles) and ~1/5 on MiB (5 angles) — so `next_vobu` is a complete, same-angle chain
on a disc that *has* `sml_agli` as well as on one that does not. That is the independent
evidence that the fallback is sound rather than merely convenient.

⚠ **Two fixtures were too weak to catch their own mutations, and the RTL was not at fault
either time** — worth knowing because both look like passing gates:
`iso_reader_angle_tb` wrote **no `next_vobu` at all**, so a mutation that PREFERRED
`next_vobu` over `sml_agli` was a no-op there (M2 passed). It now writes the same-angle
successor, which is what a real disc carries — MEASURED on MiB RBN 37, `next_vobu = +934 =
RBN 971 = sml_agli[angle 1]`, i.e. the two AGREE for the angle you are playing and DISAGREE
for every other one, which is exactly why `sml_agli` must win. And `angle_noagli_tb`'s final
hop originally pointed somewhere harmless, so dropping the `target <= cl_rd` bound changed
nothing (M4 passed); it now points past the cell into the sibling's range.

★ **Bench sweep, all 38 reader/VM benches** (the new ports are tied off in every one — a
floating input is X, and X on `agl_vm_en` would poison the angle resolve): **36 pass**, and
the two that fail — `iso_reader_atmos_tb` and `iso_reader_tpsw_boot_tb` — were re-diffed
against the pre-change reader and are **byte-identical**, so they are the pre-existing
failures CLAUDE.md already records, not a regression from this branch.

### Adjacent angle blocks: the count ran across the boundary (2026-09-15, Grave of the Fireflies)

> **Status: ✅ HW-CONFIRMED 2026-09-15** — maintainer: *"Grave of the Fireflies does report 2
> angles now, and playing past 8 minutes does roll into chapter 2"*, i.e. the count AND the
> block skip both measured on the board. Field report:
> *"playing that back on the core showed 9 angles to choose from but no auto-switching
> that I saw. Is that normal behavior?"*

**No — the disc declares TWO.** `TT_SRPT` title 1 says `nr_of_angles = 2`, and its NAV
packs carry exactly two `sml_agli` entries. The **9 was the core's cap**, not the disc.

★★ **THE SCAN COUNTED `block_type` AND NEVER RE-CHECKED `block_mode`, SO IT WALKED OUT OF
THE BLOCK IT WAS MEASURING.** A block is authored `block_mode` **1** (FIRST), then **2**
(IN BLOCK)…, then **3** (LAST), and the next block starts at 1 again. `S_ANGLE_SCAN`
counted the run of consecutive `block_type==1` cells and stopped only at a non-angle cell
or its `angle_count < 9` limit — fine while every angle block is followed by a normal cell,
which is every disc Phase 9 was built and proven on.

**Grave of the Fireflies VTS_01 PGC1 is 13 back-to-back 2-angle pairs** — one per chapter,
`bm=1,3, 1,3, …` — with only the final cell of the PGC normal:

```
cell  1 cat=0x57 bm=1 bt=1  first=0        last=339620    VOB=1 CELL=1   chapter 1, angle 1
cell  2 cat=0xd7 bm=3 bt=1  first=457      last=340206    VOB=2 CELL=1   chapter 1, angle 2
cell  3 cat=0x5d bm=1 bt=1  first=340207   last=643132    VOB=1 CELL=2   chapter 2, angle 1
cell  4 cat=0xdd bm=3 bt=1  first=340879   last=643778    VOB=2 CELL=2   chapter 2, angle 2
…                                                                        (13 pairs)
cell 27 cat=0x03 bm=0 bt=0  first=3779283  last=3802205   VOB=5 CELL=1   the only normal cell
```

So the scan counted 1,2,3,… and stopped at **9**, its cap.

★★★ **AND THE WRONG COUNT IS NOT THE WORST OF IT — `block_last` FOLLOWS IT.**
`block_last = block_first + angle_count - 1` = cell 8 (0-based), so the end-of-block skip
lands on `block_last + 1` = 0-based cell 9 = **1-based cell 10 = chapter 5's ANGLE-2 cell**.
After chapter 1 (8:00) playback jumps forward over chapters 2, 3 and 4 —
**6:56 + 6:59 + 8:22 ≈ 22 minutes of the film** — and resumes in the other angle.
⚠ It then compounds: that landing cell has `bm=3`, so `cc_blk_first` is false and
`angle_resolved` was just cleared, which makes it **neither `angle_active` nor
`seamless_active`** (`seamless_active` requires `!cc_is_angle`). With no ILVU follow it
streams that interleaved range linearly — the alternating-angles symptom again, reached by
a completely different route from the no-`sml_agli` case above.

**FIX = libdvdnav's own rule**: continue only while the next cell is IN or LAST of the SAME
block (`block_mode >= 2`), which is exactly `play_Cell_post`'s
`while (block_mode >= 2) cellN++`. The next block's `block_mode == 1` ends the walk.
⚠ The 9 cap STAYS — it is the `sml_agli` table size and the DVD spec's angle limit, so it
bounds a malformed block. It is simply no longer what ends a well-formed one.
⛔ **A "have I consumed the LAST cell" latch was written and then DELETED.** On any
well-formed layout `block_mode >= 2` already stops at the boundary, so no fixture could
distinguish it — and libdvdnav has no such latch either. A claim no mutation can catch is
not a gated claim.

**Blast radius — swept over 808 angle blocks in the library.** The old rule disagrees with
this one on **12 of the 23 multi-angle discs**:

| disc | adjacent blocks | old count | correct | declared |
|---|---|---|---|---|
| `TimeTraveler` | **463** | 4/6/8/9 | 2 | 2 |
| `Beauty_and_the_Beast` | **54** | 4/6/8 | 2 | 2 |
| `HOW_GREAT_IS_OUR_GOD` | 14 | 4/6/8/9 | 2 | 2 |
| `Grave of the Fireflies` | 12 | 4/6/8/9 | 2 | 2 |
| `BOOK_OF_LIFE` | 6 | 6/9 | 3 | 3 |
| `A_BEAUTIFUL_MIND`, `Signs`, `BRIDGET_JONES`, `MUSIC_OF_THE_HEART`, `WITHOUTAPADDLE43`, `blast`, `THE_KID` | 1–3 each | 4 or 6 | 2 or 3 | 2 or 3 |

★ **The rule is cross-checked against what the DISC declares, not just against itself:**
the block count equals `TT_SRPT nr_of_angles` on **21 of 23** discs. The two exceptions are
one disc (`AGENT_CODY_BANKS`) whose blocks genuinely hold **3** and **4** angles under a
title declaring **5** — `nr_of_angles` is a TITLE-level maximum, so per-block counting is
the *more* precise of the two, not a contradiction. That is also why the reader counts
cells rather than reading `nr_of_angles`: the per-block value is the one `block_last` needs.

**Gate: `iso_reader_angle_tb` TEST C** — a second 2-angle block placed immediately after the
first with no normal cell between (the Grave shape), scoring the delivered marker bytes.
RED on the pre-fix reader: `angle_count=4` and **`B1=0`, i.e. the second block was skipped
entirely** — the 22-minute jump, reproduced. Mutation **M5** restores the old rule and must
fail TEST C while leaving `angle_noagli_tb` green, which is what shows the COUNT rule is the
variable rather than the angle machinery generally.
★ Control, and the strongest form of it: with **both** of this branch's reader fixes applied,
`main`'s own unmodified `iso_reader_angle_tb` (single block, 3 cells) is **byte-identical** to
`main`'s own reader. Neither fix moves the single-block path at all.

### Seeking inside an angle block (2026-09-15, Grave of the Fireflies, HW-found)

> **Status: ✅ HW-CONFIRMED 2026-09-16** (build `DVD_anglefollow_20260916_0353.rbf`) —
> maintainer: *"no angle switching after a seek on grave of the fireflies and the timestamps
> are correct"*. Found by the maintainer while confirming the two fixes above: *"seeking at any point shows an incorrect preview time
> (+8 minutes when seeking during the beginning chapter) and starts alternating the 2
> available angles at 1hz."* **Both are PRE-EXISTING** — the fixes above are what let the
> disc play far enough to reach them.

Two symptoms, two mechanisms, one shared root: **a sibling angle cell is indistinguishable
from sequential content to anything that maps an RBN to a cell or accumulates time.**

#### (a) The preview time — a block occupied N slots on the timeline instead of one

The cell walk's prefix sum (`run_eltm` / `run_secs` → `cell_start_mem`, `cellf_secs`,
`title_secs_o`) added **every** cell's `playback_time`, siblings included. A 2-angle block
is one span of film offered two ways; the viewer sees one of them.

MEASURED on Grave of the Fireflies (VTS_01 PGC1, 13 back-to-back 2-angle pairs = the whole
film): the 13 angle-1 cells plus the closing cell sum to **5396 s = 1:29:56**, which matches
the PGC's declared `01:30:03` to frame rounding. Counting all 26 gives **10725 s = 2:58:45**
— the elapsed readout ran to nearly double the film.

★★ **And that is what produced the reported +8:00, through `seek_time`.** A block's two
cells OVERLAP but do not coincide — chapter 1 is cell 0 at RBN 0…339620 and cell 1 at
457…340206 — and `seek_time` resolves a target by keeping the **nearest at-or-below**
(`dvd/seek_time.sv:353`). For any target past sector 457 the nearest is the **sibling**,
whose prefix start was 8:00: chapter 1's own length, to the second.

**FIX = the prefix sum, in one place.** A sibling (`block_type==1` with `block_mode >= 2`)
inherits the block-first cell's start and adds nothing to the running total. ★ That makes
`seek_time`'s pick **harmless rather than wrong** — both cells of a block now report the
same start — so the preview, the live clock and the title total are corrected together and
`seek_time` needs no change at all. `dvd_iso_reader.sv` has carried *"multi-angle blocks
over-count — documented limitation"* since Phase 11; this removes it.

★ **A fourth consumer is corrected as a side effect, and it is worth knowing about because
it is not obvious from the symptom.** `scrub_ctrl` sizes the hold-to-scrub step from the
title's duration — `step = span >> (SHn + log2(title_secs) - SECS_REF)`, so the content
rate is `title_secs / 2^shift`. Reporting Grave as 2:58 instead of 1:29 put `log2` one
bucket high, which put the shift one high, which **halved the scrub rate** on that disc.
The bucket now comes from the true running time. ⚠ Only the 12 discs whose blocks are
adjacent enough to move `title_secs` across a power-of-two boundary can shift bucket at
all; the rest keep their exact step.

#### (b) The 1 Hz alternation — a seek never armed the angle machinery

The angle-block entry was gated `cc_blk_first && !angle_resolved && **!rbn_override**`, and a
raw-RBN scrub sets `rbn_override`. So **a seek into an angle block never ran the angle
scan**: `angle_count` stayed 0, `angle_active` with it, and `seamless_active` requires
`!cc_is_angle` so that was 0 too. With neither arm set there is no ILVU follow and the
interleaved range streamed **linearly** — the two angles alternating once per ILVU. Grave's
first ILVU is ~457 sectors, about a second: the reported 1 Hz.

★ **The seek path's own comment already said the opposite** — *"a transport seek re-scans
any angle/interleaved block it lands in"* (`dvd_iso_reader.sv`, where the seek clears
`angle_resolved`). The term prevented exactly what the code said it did.

⚠ **The mid-block ILVU hop is excluded by `!angle_resolved`, not by that term.** The hop
fires only while `angle_active`, which requires `angle_resolved`, and the hop does not clear
it — the clears are reset, transport seek, `S_PGC_DONE`, and the end-of-block skip. So the
term was removable; `iso_reader_angle_tb` TEST A/B drive the hop and are unchanged.
⚠ The `!rbn_override` term dates to the original Phase 9 import with no recorded rationale,
which is why it was checked against the benches rather than reasoned away.

⚠ **Residual, small and deliberate.** The two cells of a block overlap but do not coincide,
so a target landing in the sibling's TAIL — past the block-first cell's `last_sector` —
matches only the sibling, which is not `cc_blk_first`, so the scan still does not run. On
Grave chapter 1 that window is **586 of ~340,000 sectors (0.17 %)**. Fixing it means walking
back to `block_first` from a sibling landing; not done, because the reader's VOBU-align snap
already puts most landings on the block-first cell's chain and the added scan state would be
hard to gate honestly.

#### (c) The snap landed on whichever angle the target fell in — a coin flip

Arming the follow is not enough: the raw-RBN scrub is snapped FORWARD to the next NAV pack,
and the angles' ILVUs are laid down **round-robin**, so the landing belongs to whichever
angle's ILVU the target happened to fall in. MEASURED on Grave, per angle across all 13
blocks: **48–52 %**. The field report — *"seeking always lands on angle 2, so there's a quick
glance of the storyboard angle before it settles on the film"* — is a coin flip seen a few
times, and the "settles" is the `sml_agli` follow converging after one ILVU (~1 s; Grave's
ILVUs are ~460–620 sectors).

⚠⚠ **And on a disc with NO `sml_agli` it never converges at all.** `next_vobu` follows the
chain of the angle you are standing in, so on `CASTLE_IN_THE_SKY` / `DIEANOTHERDAY_D1_PS` a
seek into a block would play the **rest of that block in the wrong angle** — strictly worse
than the reported symptom, and not yet observed only because those discs' blocks are a title
card, an opening sequence and the end credits.

**FIX = make the snap angle-aware, using `dsi_gi.vobu_vob_idn`** (DSI 0x18 → sector `0x41F`).
MEASURED premise on all three discs: every angle cell of a block has a **distinct VOB_ID**,
and every VOBU inside that angle's ILVUs carries it — Grave's round-robin reads vob 1 at
RBN 0…456, vob 2 at 457…1074, vob 1 at 1075…
⚠ The VOB_IDs are **not** consecutive from 1 (Castle uses 1/2, 4/5, 8/9), so
`first + angle - 1` would be wrong; the cell's own value has to be read.

Three passes, all inside the seek path:

1. **PLAIN** — the existing unfiltered snap lands on the next NAV pack.
2. **LEARN** — once `S_ANGLE_PICK` has chosen the angle cell, `cf_rd` is that cell's
   `first_sector`, which is by construction the first VOBU of that angle's own chain. Probe
   it and read its `vob_idn`. **One** extra sector read per scrub into an angle block, against
   a seek that already costs a flush and a decoder re-lock.
3. **FILT** — re-snap forward from the original landing, accepting a NAV pack only if it
   carries that VOB_ID. If the landing was already correct this accepts immediately.

★ **Reading `vob_idn` costs no extra reads.** The probe leaves the whole sector resident in
`parse_buf` (`pb_sec`), and `rbuf` is only a 45-byte window copy of it — so the `0x41F`
window is a second `S_FETCH`, not a second disk read. That is also why the signature test
(bytes 0…41) and `vob_idn` cannot share one window, and the state machine re-fetches.

⚠ **The angle passes must NOT fall back into `S_RBN_SCAN` when the probe budget runs out** —
that re-resolves the cell and would undo the angle choice. They fall back to streaming the
unfiltered landing, i.e. exactly the behaviour that shipped before this existed.

⚠⚠ **THE DIVERT IS GATED ON `ang_snap_pend`, NOT ON `rbn_override`, AND THAT DISTINCTION IS
LOAD-BEARING.** `rbn_override` is set by TWO things: a raw-RBN scrub landing **and the
mid-block ILVU hop**. The hop keeps `angle_resolved` set, so the first version of this divert
fired on the first hop of a block reached by ORDINARY PLAYBACK and put a LEARN probe read
into the one path whose contract is that it is time-continuous — no flush, no `seek_ack`, no
A/V re-anchor, HW-proven since PR fj#98.
★ **No bench caught it, and none could have as written:** the outcome was still *correct*,
just with an extra read and added mid-stream latency, so TEST A/B stayed green. It would have
reached hardware as a stutter at an angle-block ILVU boundary and been attributed to
something else. `ang_snap_pend` means exactly "the most recent SCRUB has not yet had its
landing angle verified": set when a scrub is armed, cleared as soon as any landing resolves
(including a non-angle one, so it cannot sit armed and fire on a later hop), and never set by
the hop. ★ The tell that the fix works is `iso_reader_angle_tb` TEST D's `A1` returning to
2048 — it read 2489 while the probe was firing on the hop.

⛔ **Why not parse the cell position table (C_POSI) for VOB_IDs instead?** It was the first
plan and was dropped on inspection: all eight `wphase` codes (`P_HDR`…`P_ACTL`) are in use,
so it needs the shared PGC walk phase widened to `[3:0]` across 15 sites in a parser every
disc and every domain goes through — and it would **not** remove the second pass anyway,
because the snap runs before the cell is resolved. The probe keeps the risk inside the seek
path at the cost of one read.

**Gate: `iso_reader_angle_tb` TEST G** — seek to a NAV pack belonging to angle 2 while angle
1 is selected, and require no `0xA2` bytes at all. The fixture's NAV packs carry `vob_idn`
(block 1 = VOB 1/2, block 2 = VOB **3/4**, deliberately not 1/2 again and not consecutive
with block 1's, so a rule derived from the angle index fails).

⚠⚠ **THE FIXTURE'S "NAV PACKS" WERE NEVER NAV PACKS, AND THAT IS WHY TEST G FAILED FIRST.**
`put_nav` wrote the DSI (PES header at `0x400`, `vobu_ea`, category, `sml_agli`, `next_vobu`)
but none of the three signatures the reader's own probe tests — pack start `00 00 01 BA` @0,
PS system header `00 00 01 BB` @14, PCI PES `00 00 01 BF` @38. So `nav_sig_hit` was false for
every sector, the VOBU-align probe exhausted `NAV_CAP` on every scrub and fell back to the
raw target. **The snap had never been exercised by this bench at all**, and TEST D was green
because its raw target happened to be a NAV sector — the right answer for the wrong reason.
The signatures are written now.
★ Same family as the other fixture gaps this branch turned up (`iso_reader_angle_tb` carrying
no `next_vobu`; `angle_noagli_tb`'s harmless last hop): **a mutation or an arm that fails is a
claim about the FIXTURE first and the RTL second.** Here the arm failed on the *fixed* reader,
which is the tell — the stimulus never reached the code under test.

**Gates: `iso_reader_angle_tb` TEST D and TEST E.**
- **TEST D** scrubs to a NAV-aligned RBN inside a block and requires only the selected
  angle's marker bytes afterwards. RED on the pre-fix reader: **`A2=4096`**, the entire
  sibling cell delivered. ⚠ The landing is NAV-aligned on purpose — the reader's own
  `S_NAV_SEEK` snap (the fj#106 scrub fix) moves a raw target forward to the next NAV pack,
  so that is what a real disc produces; a landing PAST a nav pack has no DSI to snoop and
  cannot arm the follow for the ILVU it lands in, which is a property of ILVU navigation
  rather than of this fix.
  ⚠ TEST D deliberately does **not** assert `angle_count`: it is a peak, and the block was
  already scanned during the settling play before the scrub, so it reads 2 on the pre-fix
  reader too — an assertion that cannot fail for this defect.
- **TEST E** gives the fixture real durations (block 1 = 10 s, block 2 = 20 s, common 5 s)
  and requires `title_secs_o == 35`. Summing siblings gives **65**, which is the Grave
  1:30 → 2:58 error in miniature.

### The disc picks the angle — SPRM3 was written and never read (2026-09-15)

★★ **`dvd_vm` has latched SPRM3 from `SetSTN` since Phase 4 and exported only SPRM1 and
SPRM2, so the angle was dead.** The reader's `cur_angle` was fed by the B6 button alone.
MEASURED on Castle, the disc's own boot chain:

```
FP PGC          -> JumpSS VMGM pgc 2
VMGM PGC2 post  -> g[8]=1  g[12]=0  g[13]=0  g[14]=2   *** angle 2 is the disc's default
VTS02 PGC1 pre  -> if (g[8] != 1) Goto 5
                   SetSTN ASTN=g[12] SPSTN=g[13] AGLN=g[14]
VTS02M Audio menu buttons:  SetSTN ASTN=0 AGLN=2  (English 5.1)
                            SetSTN ASTN=1 AGLN=1  (Japanese 2.0)
                            SetSTN ASTN=2 AGLN=2  (French 2.0)
VTSM PGCs 19/20/21/24 pre:  g[14] = AGLN          *** it reads the angle BACK
```

So angle 1 = Japanese title cards, angle 2 = English/localized, the disc's default is **2**,
and **the angle is welded to the audio language through the disc's own Audio menu**. The core
played angle 1 regardless.

⛔ **It is NOT driven by `Player Language`, and must not be.** A full decode of every PGC
command on the disc finds **zero** references to SPRM0 (menu language), 16/17 (audio
language), 18/19 (subtitle language) or 20 (region). Coupling the OSD language option to the
angle would invent behaviour no disc asks for.

★ **A SECOND disc does the same, so this is not one disc's quirk.** `Grave of the
Fireflies` VTS_01 PGC1's PRE block reads:

```
pre#3: if (g[8] == g[0]) SetSTN AGLN = 0x1
pre#4: if (g[8] != g[0]) SetSTN AGLN = 0x2
```

— the feature picks angle 1 or 2 from a GPRM its setup menu wrote (VTS_01M PGC3's POST sets
the same pair), again with no language SPRM anywhere in it. Both discs found so far that use
angles for a localized title choose the angle **themselves**, which is what makes the SPRM3
export load-bearing rather than a tidy-up.

★★★ **AND THE READER PICKED THE CELL BEFORE THE DISC COULD SPEAK — DETERMINISTICALLY.**
`pgc_loaded` pulses at `S_PGC_DONE`; the reader reaches the `S_ANGLE_SCAN` resolve about
**8 cycles** later (2 × `S_CELL_LOAD`, 2 × 2 for a two-cell scan). The VM only *starts*
`BLK_PRE` on that same pulse and needs many cycles per command (serial ALU + an 8-byte BRAM
fetch). This is not a race that is usually lost — it is always lost. libdvdnav's order is
unambiguous: `play_PGC` runs PRE, *then* `play_Cell` does `cellN += AGL_REG - 1`.
Fix: `dvd_vm.pre_done` (PRE ran, linked away, or there was none) → the reader latches
`pre_seen` and holds in the new `S_ANGLE_PRE` before `S_ANGLE_PICK`.
⚠ **The `ANG_PRE_WD` watchdog (~0.25 s) is load-bearing, not belt-and-braces:** a PRE command
that itself jumps leaves the VM in `V_WAIT` awaiting a `pgc_loaded` that a stalled reader
would never produce. Only the FIRST angle block after a PGC load can ever wait; mid-title
blocks find `pre_seen` already set.
⚠ **`pre_done`'s `!ev_loaded` term is equally load-bearing:** `pgc_loaded` only *latches* the
event and the VM can sit in `V_IDLE` for a cycle or two before consuming it, so without that
term the pulse fires **before** the PRE block runs — the same defect, one level down.

★ **The write-back matters because the disc reads AGLN back.** A B6 press pulses
`dvd_vm.agl_set` with the reader's settled `cur_angle` (taken from the reader's OUTPUT, never
predicted in emu — predicting it would need a second copy of the wrap rule). Without it,
Castle's `g[14] = AGLN` menus would store a stale angle and re-apply it at the next title
entry, silently undoing the user's choice.

★ **Seam gate: `tools/check_angle_wiring.py`** reads the `.sprm_agln` / `.agl_vm` /
`.agl_vm_en` / `.pre_done` / `.vm_pre_done` / `.agl_set` connections out of `dvd/emu.sv`.
emu has no bench and each module bench is handed the other side's value, so a wrong or
missing connection is invisible to both — the issue #81 lesson. RED on the pre-fix file and
on three re-regressions (`.agl_vm_en(1'b0)`, `.vm_pre_done(1'b1)`, `.agl_vm` fed from
something other than the VM's export). `dvd_vm_tb` **T7** drives the disc's real instruction
bytes (`71 00 00 0e 00 02 00 00` then `41 00 00 8c 8d 8e 00 00`) and asserts the export, the
single `pre_done` pulse per load, the write-back, and that a `g[5] = AGLN` command reads the
user's choice back.

⚠ With `Disc Menus = Off` there is no VM, so `agl_vm_en` is low and angle 1 plays — which is
also what the disc itself asks for on that path, since its own `if (g[8] != 1) Goto 5` skips
the `SetSTN` when the boot chain did not run.

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

⚠ **"Forced to stream 0" means LOGICAL 0, and until issue #81 (2026-09-12) that logical
number never reached the disc's `subp_control` map on this path.** `subp_stream_map`'s domain
gate was handed the menu *context*, so it required a menu-*domain* table and fell back to the
identity index for every in-title menu — fine while the disc maps logical 0 → physical 0
(every Scene It disc does), and invisible highlights on one that does not. The reported disc
is *Aniki, mon Frère* (**BROTHER**) PAL FR R2, whose title-domain motion menus author
`subp_control[0] = 0x80010200` (wide → `0x21`). Fixed by asking the gate the question it
needs — "is the table from the domain the player is IN" — see
`docs/track_selection.md` "The domain gate asked the wrong question".

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

**THE ICON IS AUTHORED SOLID — MEASURED, so it never has to be re-established
(2026-09-08).** A field report after PR #63 said the icon had started flashing. It had, and
the disc settles what "correct" means:

| | |
|---|---|
| subpicture (physical 0x22, via `SetSTN SPSTN=0x41` -> `subp_control[1]=0x80020300`) | `SPDSZ=1572`, ONE DCSQ: `FSTA_DSP SET_COLOR[14,14,14,14] SET_CONTR[0,0,0,0] SET_DSPXA(4,769) SET_DAREA(0,719,2,479)` |
| display window | one `FSTA_DSP` at PTS **101885**, one `STP_DSP` at **866659** = **8.4975 s continuous**, with **no intermediate stop command anywhere** |
| delivery | the same unit re-sent **byte-identically 8 times**, exactly **90090 ticks (1.001 s)** apart -- a conforming player treats a re-send as a no-op |
| HLI | 17 records alternating `hli_ss = 1,2,1,2...` whose windows are **exactly back-to-back** (`s_ptm[n] == e_ptm[n-1]`: 101885 -> 191975 -> ... -> 867650), identical button content throughout, `fosl` 1 then 0 = arm once and hold |

★ The re-sends and the repeated `ss=1` exist for random access and ILVU branch entry, not
to blink. ⚠ `SET_CONTR[0,0,0,0]` means the SPU is **invisible on its own** -- the icon
appears only through the HLI recolour -- so a flash can come from EITHER the subpicture or
the highlight, and the `O[2]` blocks are what separate them (`blk1`/`blk7` = the arm,
`blk3`/`blk8` = the subpicture).

**⚠ THE SINGLE-BUTTON HLI FALLS OUTSIDE `menu_mode`, AND THAT MATTERED.** `emu.sv`'s
`sp_menu_early` rides `nav_pci.hli_seen`, which requires **more than one button**
(`nxt_btn_ns > 1`); the rabbit is one `fosl=1` button, so `menu_mode` is 0 and it runs
`spu_decode`'s windowed path. That was harmless while the STC led the display, and became
the reported blink when PR #63 put the STC on the displayed picture. Fixed in
`spu_decode` itself (a display-order hold + a contiguity clamp) rather than by widening
`menu_mode` -- the same defect was truncating ordinary subtitles. See
`docs/stc_freerun.md` §12.1 and `docs/subpicture.md`.
⚠ `dvd/emu.sv`'s note that the rabbit "doesn't need" the early gate is true of
`sp_route_en` (its `SetSTN` pre-command opens routing) and was read as covering
`menu_mode` too. It does not.

**⚠ THE DISC OFFERS NO SUBTITLES IN RABBIT MODE, AND FORCING ONE USED TO SHOW
UNREADABLE TEXT (2026-09-08).** Field report: *"subtitles in the white rabbit mode are
missing the black outline -- white on white and hard to read."* MEASURED, and the cause is
neither colour sharing with the rabbit nor a decode fault:

| substream | content | authored colours |
|---|---|---|
| 0x20 / 0x21 | the real subtitles (wide / letterbox) | `COLOR[0,8,9,0] CONTR[15,15,15,0]` |
| 0x22 / 0x23 | the rabbit icon ONLY -- no subtitles anywhere | `COLOR[14,14,14,14] CONTR[0,0,0,0]` |

PGCN 1 declares logical stream 0 only; **PGCN 6 declares logical stream 1 only**. Pressing
the Subtitle button releases the VM's claim (`emu.sv`: `if (sub_edge) vm_owns_sp <= 1'b0`),
after which the USER path resolves logical 0 **by raw index** to 0x20 -- which really is the
subtitle stream -- and draws it with **PGCN 6's palette**:

    PGCN 1 palette  [0] Y=16   [8] Y=128  [9] Y=176   -> fill, outline, black edge
    PGCN 6 palette  [0] Y=128  [8] Y=128  [9] Y=128   -> one flat grey, no outline

PGCN 6's palette has only two meaningful entries (14 = white, the rabbit; 15 = green),
because nothing else is meant to draw with it. Showing that stream is our invention, not the
disc's intent. `subp_stream_map` now reports `stream_absent` and `emu` withholds the USER
path's route. ⚠ **The rule is narrowed on a measurement**: applying the available bit
unconditionally (as libdvdnav does) would strip subtitles from the **586 class-B PGCs** (up
to 168 discs) that rely on the identity fallback -- see `dvd/subp_stream_map.sv` for the
221-disc sweep and the A/B/C classes. Gate: `subp_stream_map_tb`'s six directed
`stream_absent` arms, whose RED arm is the unconditional version.

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

**★ THE JUNCTION IS TIME-CONTINUOUS, AND SINCE 2026-09-08 THAT IS ENFORCED AGAINST THE
DISPLAY SCHEDULER TOO.** The reader has always performed the ILVU hop with no flush, no
`seek_ack` and no A/V re-anchor because it is continuous. PR #63 then added a path that
INFERRED a discontinuity from the stream and flushed audio behind the reader's back
(`disp_sched.anchor_disc` -> `flush_ctl.disc_rephase` -> `aud_resync`), which is what the
field reported as an audio dropout at every white-rabbit point -- in the PLAIN movie as
much as the rabbit branch, because **PGCN 1 carries the same 9 interleaved cell-pairs**.

MEASURED on the disc, and worth recording because the obvious guess is wrong:

| | |
|---|---|
| the ILVU splices *inside* a block | **continuous** -- 0 irregular steps in 238 AC-3 PTS samples along the real played sector walk of cell 4 |
| entering the interleaved cell | the PTS **restarts near zero**: audio steps of **-2 s to -64 s** across cells 4/23/35/55/60/74/80/86/91 |
| authored audio gap (`sml_pbi.vob_a[8].{stp_ptm,gap_len}`, DSI-rel 0x34) | **none** -- every entry zero. ⚠ Neither `nav_dsi.sv` nor `nav_extract.py` parses these fields at all; that is a real gap, just not this bug |
| cell category byte | **0x0e** on all nine -- `seamless_play=1` AND `stc_discontinuity=1` |

So the timestamps renumber at the block entry while the soundtrack plays straight through.
`dvd_iso_reader` now decodes `cell_playback_t` byte 0 **bit 3 `seamless_play`** (the whole
byte was already in `cell_cat_mem`; only three bits were ever used) and exports
`cell_seamless`, which `flush_ctl` uses to withhold the audio flush. The clock still
re-anchors -- the display must follow a real timeline change -- only the audio flush
narrows. Gate: `bench/dvd/run_seamless_audio.sh`. Full reasoning and the measurements:
`docs/stc_freerun.md` §12.2.
⚠ 104 of the Matrix's 106 cells are `seamless_play=1`, so inside a feature the re-phase now
fires only at the 2 authored non-seamless cells. Menus are structurally untouched: the
`menu_dom` branch of `S_CELL_LOAD2` never latches the level.

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

---

## ⏳ OPEN: two presses to activate a menu button (WAKE_UP_WITH_ELMO, 2026-09-13)

Reported alongside the "deep fried" menu still (`docs/quant_matrix.md`, a decoder
defect and a separate thing): on this disc's main menu the FIRST Select press does
not activate "Play Story" — it only repaints the picture — and a second press works.

**Not yet root-caused. What is measured about the disc:**

- The menu is **VTS_01 VTSM PGCN 7**, one cell, `still_time = 0xFF`, `cell_cmd = 0`,
  a **single VOBU**, so exactly ONE NAV pack and ONE HLI are ever sent. `hli_ss = 1`
  (new button set), `fosl = 0`, `foac = 0`, `auto_action_mode = 0` on all four
  buttons. There is no second PCI to re-arm from, and no forced select.
- **Every button's PCI command is byte-identical: `LinkTailPGC`, button field 0.**
  No button carries its own action. All dispatch happens in the PGC's POST, which
  reads **SPRM8** (`HL_BTNN`), divides by `0x400` and compares against 1..4.
- The initial selection comes from a `SetHL_BTNN` **pre**-command
  (`HL_BTNN = 0x400` = button 1) that runs *before* the menu VOBU — and therefore
  before its HLI — has been read. `nav_pci.sv` takes that on the `sel_force && !armed`
  path, which only stores `btn_sel` for the next arm.

**Leading hypothesis, to be tested before any code is written.** If SPRM8 is not
holding `0x400` when the POST runs, the POST matches none of its four compares, falls
off the end, and the PGC ends with `next_pgcn = 0`. Re-entering PGCN 7 then re-runs
the pre (re-asserting `HL_BTNN`) **and replays cell 0**, which is a second decode of
the still. That single mechanism would produce both reported symptoms at once — the
dead first press and the repaint — which is why they arrived in one report.

⚠ Do not assume it; the quant-matrix work has already shown this disc can produce two
symptoms from unrelated causes. The cheap discriminator is `dvd_vm.sv`'s `sprm8` /
`sprm8_frozen` at the first activate, and whether `nav_pci` promoted the stored
`btn_sel` into SPRM8 before the POST read it.

★ Note the repaint is **no longer** evidence for this hypothesis on a fixed core: with
the VM-jump soft reset in place (`docs/quant_matrix.md` §11) the first decode is already
correct, so a re-decode changes
nothing visible. If the two-press behaviour survives the quant-matrix fix, that is the
clean report.
