// dvd_detect.h — detect a DVD-Video disc in the optical drive.

#ifndef MISTER_DVD_DETECT_INCLUDED
#define MISTER_DVD_DETECT_INCLUDED

// True if the open drive fd holds a DVD-Video disc: an ISO9660 volume with a
// VIDEO_TS directory in the root. Uses READ(10), which works on DVD media
// (unlike the CD layer's READ CD / 2352 path). Called from the shared disc
// identification dispatch (physical_disc_identify).
int dvd_video_probe(int fd);

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
