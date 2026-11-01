// dvd_vmsnap.h -- the transport of the DVD VM's state snapshot and restore
// (dvd/vm_snap.sv, EXT_BUS 0x7D; docs/nav_engine.md §8-§11).
//
// Two users share it: dvd_ctl.cpp's HIL commands (`vmsnap`, `vmload <file>`, written
// as JSON for tools/mister.py) and dvd_sstate.cpp's OSD save states (slot files on
// the SD card). Every function is ONE SPI transaction of a few words, so each is
// safe on the poll thread; none of them waits for the core. Waiting is the caller's
// job, polled at its own rate with its own timeout.
//
// ⚠ Never call from a forked child: SPI is not fork-safe and the parent owns the bus.

#ifndef DVD_VMSNAP_H
#define DVD_VMSNAP_H

#include <stdint.h>

// Must match dvd/vm_snap.sv (tools/check_vm_snap_wiring.py pins all four). 0x7D is
// free (Main 0x00-0x44, 0x61-63, 0xF0-F9; 0x7A/0x7B dvd_telem, 0x7C nav_trace).
// MAGIC has bit 15 clear: a core without the module answers 0.
#define UIO_DVD_VMSNAP      0x7D
#define DVD_VMSNAP_MAGIC    0x5E02
#define DVD_VMSNAP_HDR      19
#define DVD_VMSNAP_MAXW     128

// Header word 2: {busy, vm_en, slot[1:0], load_n[1:0], save_n[1:0], len[7:0]}.
#define VMSNAP_BUSY(w2)     (((w2) >> 15) & 1)
#define VMSNAP_VM_EN(w2)    (((w2) >> 14) & 1)
#define VMSNAP_SLOT(w2)     (((w2) >> 12) & 3)
#define VMSNAP_LOAD_N(w2)   (((w2) >> 10) & 3)
#define VMSNAP_SAVE_N(w2)   (((w2) >> 8) & 3)
#define VMSNAP_LEN(w2)      ((w2) & 0xFF)

// Header word 4 [15:13]: the last LOAD's verdict.
enum { VL_NONE = 0, VL_PENDING, VL_APPLIED, VL_BAD_FMT, VL_BAD_LEN, VL_BAD_SUM,
       VL_BUSY, VL_MENUS_OFF };

// Ask for a snapshot. -> 1 asked (*seq = the core's completed count now: the
// snapshot is ready when it moves), 0 the core has no 0x7D.
int dvd_vmsnap_ask(uint16_t *seq);

// Read the header (h[0..DVD_VMSNAP_HDR-1]) and, once the snapshot asked for at seq0
// is complete (seq moved, not busy), its words into w (DVD_VMSNAP_MAXW of room).
// -> the word count when ready, 0 not yet, -1 the core has no 0x7D.
int dvd_vmsnap_fetch(uint16_t seq0, uint16_t *h, uint16_t *w);

// Read header words 0..2 only: the cheap poll for the OSD's requests.
// -> 1 and *w2 = word 2, or 0 the core has no 0x7D.
int dvd_vmsnap_peek(uint16_t *w2);

// The displayed picture's whole PGC seconds from a snapshot's header, or -1 when it
// cannot be trusted (a load then lands at the saved cell's start). docs/nav_engine.md §10.
int dvd_vmsnap_disp_secs(uint32_t eltm, uint32_t sptm, uint32_t stc, int fresh, int video);
int dvd_vmsnap_disp_secs_h(const uint16_t *h);

// Send a snapshot back as a LOAD: fmt, n words, the landing time (PGC seconds, or
// 0xFFFF = the saved cell's start) and its fallback RBN. The core checks it when the
// transaction ends. -> 1 sent, 0 the core has no 0x7D.
int dvd_vmload_send(uint16_t fmt, const uint16_t *w, int n, uint16_t tm, uint32_t rbn);

// The last LOAD's verdict (VL_*), or -1 the core has no 0x7D.
int dvd_vmload_verdict(void);

#endif
