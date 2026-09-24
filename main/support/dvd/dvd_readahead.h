// dvd_readahead.h — a RAM read-ahead between an optical/encrypted source and the core.
//
// Main services the core's sector requests on its ONE thread (user_io_poll), so a
// source read that stalls -- a dual-layer drive refocusing at the layer change, a
// re-spin, a scratch being retried by the sr driver (~30 s per sector), a network
// share hiccup -- used to stall the core's data AND the OSD, input and telemetry
// with it. The core's own cushion is short (the 32 KB audio ring is ~0.6 s at
// 448 kbps AC-3), so a stall of a second was an audible and visible hitch.
//
// Here one worker thread owns the source exclusively and keeps a ring of sectors
// (RA_CAP, ~32 MB = ~25 s at the DVD maximum mux rate) filled ahead of where the
// core is reading. The poll thread only ever copies out of the ring. A request the
// ring cannot serve yet is NOT waited for: dvd_readahead_ready() says so, Main
// leaves the request pending (the core holds sd_rd until acked) and services it on
// a later poll pass, so the poll thread never blocks on the drive at all.
//
// A request far from the ring (a seek, a chapter skip, the mount's IFO reads)
// retargets the worker to that LBA; the first burst after a retarget is one Main
// window, so a seek costs what it cost before.
//
// Source contract (the same one dvd_css_read / dvd_vcd_read / dvd_cdda_read keep):
// return `count` -- a FULL window, unreadable sectors zero-filled -- or -1 when the
// FIRST sector cannot be read. Never short.
#pragma once
#include <stdint.h>

typedef int (*dvd_ra_source)(void *buf, uint32_t lba, uint32_t count);

// Start the worker over `total` sectors of `src`. 0 on success. On failure the
// caller keeps reading synchronously, exactly as before this module existed.
int  dvd_ra_start(dvd_ra_source src, uint32_t total);
// Stop and join the worker. May wait for one source read already in flight.
void dvd_ra_stop(void);
int  dvd_ra_active(void);

// Non-blocking. 1 when [lba, lba+count) (clipped to the source) is in the ring;
// otherwise 0, retargeting the worker first if `lba` is not on its way.
int  dvd_ra_ready(uint32_t lba, uint32_t count);
// Non-blocking copy. `count` when every sector is in the ring (sectors past the
// source end read as zero), else -1 -- never short.
int  dvd_ra_read(void *buf, uint32_t lba, uint32_t count);

// Main's hook (integration step 48): may the request for `lba` be serviced on this
// poll pass? 1 when the read-ahead is idle (behave as stock), when Main's own
// window `[buffer_lba, buffer_lba + buf_n)` already holds it (a hit needs no
// source read), or when the ring holds the whole window a miss would read.
int  dvd_readahead_ready(uint64_t lba, uint32_t blks, uint64_t buffer_lba, uint32_t buf_n);
