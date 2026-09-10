// dvd_cdda.h — physical audio CD (CD-DA) served to the core as one giant WAV.
//
// The core has no CD-DA mode and does not need one. It already probes a mounted
// image for RIFF/WAVE and plays 16-bit stereo PCM (feature/wav-audio), so this
// presents the disc as exactly that: a synthetic 44-byte canonical WAV header
// followed by the disc's audio sectors, repacked from the CD's 2352-byte frames
// into the 2048-byte blocks the sd interface delivers.
//
//   virtual byte 0                      44                    44 + N*2352
//        |  canonical WAV header  |  audio sector 0 | 1 | ... | N-1 |
//
// N is the total of the AUDIO tracks' sectors, concatenated in track order.
// Data tracks on an enhanced/mixed-mode disc are skipped, so their sectors do
// not appear in the virtual image at all — the audio plays and the data track
// is simply not part of the file.
//
// ★ 44 is divisible by 4, so every 2048-byte block boundary stays aligned to an
// L/R sample pair. That is what lets the core seek to any block without ever
// swapping the channels.
//
// Sector geometry is why the mapping is not a straight copy: 2352 and 2048 share
// only gcd 16, so the phase between a CD frame and an sd block repeats every 128
// sectors / 147 blocks. dvd_cdda_map_sector() is kept a PURE function of the
// track table precisely so that arithmetic can be tested on a host with no drive
// (main/tests/dvd_cdda_test.cpp).

#ifndef DVD_CDDA_H
#define DVD_CDDA_H

#include <stdint.h>

#define DVD_CDDA_RAW        2352      // one CD frame: 588 stereo s16 samples
#define DVD_CDDA_HDR        44        // canonical RIFF/WAVE header
#define DVD_CDDA_MAX_TRACKS 100

// One AUDIO track's place in the virtual image. `vsec` is the running total of
// audio sectors BEFORE this track, so virtual sector s belongs to track i when
// vsec[i] <= s < vsec[i] + len.
typedef struct {
	int num;        // 1-based track number as printed on the sleeve
	int lba;        // absolute disc LBA of the track's first sector
	int len;        // sectors
	int vsec;       // first virtual audio-sector index
} dvd_cdda_track;

typedef struct {
	dvd_cdda_track tr[DVD_CDDA_MAX_TRACKS];
	int ntracks;    // AUDIO tracks only
	int nsectors;   // total audio sectors = sum of len
} dvd_cdda_toc;

// --- pure helpers (no drive, no globals) — the host test's whole surface ----

// Total size of the virtual WAV image in bytes: 44 + nsectors*2352.
uint64_t dvd_cdda_image_size(const dvd_cdda_toc *toc);

// Virtual audio-sector index -> absolute disc LBA. Returns -1 when out of range.
int dvd_cdda_map_sector(const dvd_cdda_toc *toc, int vsec);

// Fill the 44-byte canonical header for a payload of `payload` bytes.
void dvd_cdda_wav_header(uint8_t *hdr, uint32_t payload);

// --- the live source --------------------------------------------------------

// Read the TOC from an already-open drive fd and build the table. Returns 0 on
// success. ⚠ Blocking: CDROMREADTOCENTRY can take seconds on a drive that is
// still spinning up, so call this from the MOUNT path, never from a poll tick.
int  dvd_cdda_open(int fd, const char *dev);

int  dvd_cdda_active(void);
uint64_t dvd_cdda_size(void);
const dvd_cdda_toc *dvd_cdda_get_toc(void);

// Fill `cnt` 2048-byte blocks starting at block `lba`. Returns the number of
// blocks filled (>0) or -1. Unreadable sectors are zero-filled rather than
// failing the whole window: on a CD that is a dropout, which is what a real
// player does, and the alternative would stall the core.
int  dvd_cdda_read(void *buf, uint32_t lba, uint32_t cnt);

void dvd_cdda_close(void);

#endif
