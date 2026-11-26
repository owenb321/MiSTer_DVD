// dvd_detect.h — detect a DVD-Video disc in the optical drive.

#ifndef MISTER_DVD_DETECT_INCLUDED
#define MISTER_DVD_DETECT_INCLUDED

#include <stddef.h>

// True if the open drive fd holds a DVD-Video disc: an ISO9660 volume with a
// VIDEO_TS directory in the root. Uses READ(10), which works on DVD media
// (unlike the CD layer's READ CD / 2352 path). Called from the shared disc
// identification dispatch (physical_disc_identify).
int dvd_video_probe(int fd);

// The disc's ISO9660 volume label (what the OSD's load row shows for a disc in the
// drive, see dvd_mountname.h), read from sector 16 with the same READ(10). 1 and the
// label in `out` when it is usable; 0 when it cannot be read or is missing/generic.
// DVD and Video CD alike: an audio CD has no sector 16 to read, so do not call it there.
int dvd_volume_label(int fd, char *out, size_t n);

// True if the open drive fd holds a disc with at least one AUDIO track — a music
// CD, or an enhanced/mixed-mode disc whose audio tracks we can still play.
//
// ⚠ Deliberately BROADER than stock physical_disc's PHYSICAL_DISC_DISC_AUDIO,
// which requires the disc to have NO data track at all. The two do not collide:
// stock decides at the MENU, where a mixed disc should be typed by its data
// content (a PSX game must still launch PSX), whereas this only ever runs once
// the user is already sitting in the DVD core.
//
// Cheap by construction: it walks the TOC and reads no disc data. It is still
// not free — CDROMREADTOCENTRY can block for seconds on a drive that is spinning
// up — so callers must keep it behind a once-per-insertion latch, never on every
// poll tick. See the poll-starvation note in dvd_phys.cpp.
int cd_audio_probe(int fd);

#endif
