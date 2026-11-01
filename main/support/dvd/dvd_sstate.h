// dvd_sstate.h -- the OSD's save states (save states step 4; docs/nav_engine.md §11).
//
// A DVD save state is the VM's whole navigation state plus the displayed picture's
// time: a snapshot over EXT_BUS 0x7D (dvd/vm_snap.sv, transport in dvd_vmsnap.cpp),
// written to savestates/DVD/<disc id>_N.ss and pushed back as a LOAD. The core cannot
// write a file, so the Main does it; with stock Main the OSD rows do nothing.
//
// The core counts the OSD's "Save to Slot" / "Load Slot" presses and latches the Slot
// row at each (vm_snap header word 2). dvd_sstate_tick() polls those counters and runs
// one save or load at a time, never blocking: a save waits for the snapshot over later
// ticks, a load for the core's verdict.

#ifndef DVD_SSTATE_H
#define DVD_SSTATE_H

#include <stddef.h>
#include <stdint.h>

// .ss slot file, little-endian. Mirrored by tools/vm_snap.py.
//   0   4   "DVS2"  (the shelved branch's DVSS files are a different, retired format)
//   4   2   file version (1)
//   6   2   fmt       the snapshot layout id (nav_isa.snap_fmt): the core refuses a
//                     save from a build with another layout
//   8   2   words     snapshot words that follow
//   10  2   sum       16-bit sum of the words
//   12  8   disc      FNV-1a 64 of the disc id: a renamed file must not load into
//                     another disc
//   20  4   disp_secs the displayed picture's PGC seconds, -1 = land at the cell start
//   24  4   nv_pck_lbn  the time map's fallback sector
//   28  4   eltm      the HUD clock at the save (BCD), for tools only
//   32  32  core      the core's version string at the save, for tools only
//   64  ..  words
#define DVD_SSTATE_MAGIC   "DVS2"
#define DVD_SSTATE_VERSION 1
#define DVD_SSTATE_HDR     64
#define DVD_SSTATE_MAXW    128
#define DVD_SSTATE_MAX     (DVD_SSTATE_HDR + 2 * DVD_SSTATE_MAXW)

// Note what is mounted, and work out the disc's IDENTITY from it.
//
// ★ THE MOUNT PATH CANNOT NAME THE FILE. Every physical disc mounts as the same
// sentinel, so a path-derived name would collapse the whole library onto one set of
// four slots. The identity comes from the disc itself: a hash of the first sector of
// VIDEO_TS.IFO (the VMGI_MAT), found by a short ISO9660 walk. The VMGI_MAT holds only
// IFO-relative data and is never CSS-scrambled, so a physical disc and ANY rip of it
// (raw or rebuilt from its files) share save slots. NOT the ISO9660 volume descriptor,
// which a rebuilt rip replaces (docs/save_states.md on feature/save-states, 2026-09-26).
//
// About four sector reads, once per mount. Pass NULL or "" to forget (an eject).
void dvd_sstate_note_mount(const char *src);

// "<provider>-<16 hex>" (or "DVD-<16 hex>"), or NULL when nothing identifiable is mounted.
const char *dvd_sstate_disc_id(void);

// Poll the core's Save/Load counters and run the request. Self-throttled to 20 ms.
void dvd_sstate_tick(void);

// Build the slot path for the mounted disc (slot 0..3). -> 0 if there is no identity.
int dvd_sstate_slot_path(int slot, char *out, size_t cap);

#endif
