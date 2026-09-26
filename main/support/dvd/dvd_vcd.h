// dvd_vcd.h — physical Video CD / Super Video CD served over the sd_* block
// interface.
//
// Unlike physical DVD-Video (dvd_css.cpp) there is no decryption here -- VCD
// and SVCD carry no CSS/RPC protection at all: the format has no encrypted
// title-key header of any kind. And unlike physical CD-DA (the parked
// feature/cdda-physical branch) there is no synthetic header to fabricate:
// dvd_iso_reader.sv already auto-detects a raw MODE2/2352 image purely from
// the CD sync pattern at byte 0 -- the same content-sniff that already
// handles a ripped .bin file -- so this module only has to hand the FPGA the
// disc's raw 2352-byte sectors starting at the data track's own first
// sector. No wrapper, no metadata upload, no RTL change.
//
//   virtual byte 0                                        len*2352
//        |  raw disc sector 0 | 1 | ... | len-1                |
//
// v1 scope, matching the existing rip-image VCD/SVCD feature's own
// documented limitation (docs/vcd_svcd.md §5): the disc's own data-track
// SPAN, from the first data track through the last CONSECUTIVE data track
// that follows it, ending at a trailing CD-DA track (hybrid disc) or the
// leadout -- i.e. everything a whole-disc .bin rip would capture as one
// flat file. That span is deliberately NOT "the first data track alone":
// standard VCD/SVCD authoring commonly splits the ISO9660 filesystem into a
// short first data track and puts the actual MPEG payload in the track(s)
// that follow it, all one continuous LBA space (measured on a real burned
// test disc -- see dvd_vcd.cpp). A genuine multi-movie disc, where each
// movie is its OWN separately-navigable span rather than one continuous
// filesystem, is out of v1 scope the same way a rip-image mount already
// requires picking one .bin file per movie.

#ifndef MISTER_DVD_VCD_H
#define MISTER_DVD_VCD_H

#include <stdint.h>

#define DVD_VCD_RAW 2352   // one raw CD sector: sync + header + subheader + user data + EDC/ECC

typedef struct {
	int num;    // 1-based track number
	int lba;    // absolute disc LBA of the track's first sector
	int len;    // sectors
} dvd_vcd_track;

// --- pure helper (no drive, no globals) -- the host test's whole surface ---

// Total size of the virtual raw image in bytes: len*2352.
uint64_t dvd_vcd_image_size(const dvd_vcd_track *trk);

// --- the live source ---------------------------------------------------------

// Find the drive, open it, read the TOC and locate the first DATA track.
// Returns 0 on success. Self-contained, like dvd_css_open() -- called from
// user_io_file_mount()'s dispatch, which has no fd to hand over (dvd_phys.cpp
// closes its own probe fd before the sentinel-triggered mount reaches here,
// same as the DVD-Video path). ⚠ Blocking: CDROMREADTOCENTRY can take
// seconds on a drive that is still spinning up -- call this from the MOUNT
// path, never a poll tick.
int  dvd_vcd_open(void);

// A second source: the same raw image, with its 2352-byte sectors supplied by
// `rd` instead of the drive -- a .cue sheet's data-track span (dvd_cue.cpp).
// The span is `len` sectors numbered 0..len-1 as `rd` sees them. `rd` must fill
// every byte (zero what it cannot read); `on_close`, if given, is called from
// dvd_vcd_close() so the source can release its files. Starts the read-ahead,
// exactly as dvd_vcd_open() does. Returns 0 on success.
typedef int (*dvd_vcd_frames_fn)(int lba, int count, uint8_t *dst);
int  dvd_vcd_open_source(int len, dvd_vcd_frames_fn rd, void (*on_close)(void));

int  dvd_vcd_active(void);
uint64_t dvd_vcd_size(void);

// Fill `cnt` 2048-byte blocks starting at block `lba` with the raw disc
// bytes at that offset into the virtual image. Returns the number of
// blocks filled (>0) or -1. An unreadable sector is zero-filled rather than
// failing the whole window -- on a scratched disc that is a dropout, which
// is what a real player does, and the alternative would stall the core.
int  dvd_vcd_read(void *buf, uint32_t lba, uint32_t cnt);

void dvd_vcd_close(void);

#endif
