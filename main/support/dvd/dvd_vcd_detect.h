// dvd_vcd_detect.h — detect a Video CD / Super Video CD in the optical drive.

#ifndef MISTER_DVD_VCD_DETECT_INCLUDED
#define MISTER_DVD_VCD_DETECT_INCLUDED

// True if the open drive fd holds a Video CD (2.0) or Super Video CD: an
// ISO9660 volume with an MPEGAV/ (VCD) or MPEG2/ (SVCD) directory in the root
// -- the ones that hold the playable MPEG streams, as opposed to VCD/ or
// SVCD/ (metadata only, INFO.VCD/INFO.SVD) or SEGMENT/ (still menus, not
// played). Uses READ(10), same as dvd_video_probe() -- a VCD/SVCD's ISO9660
// filesystem sectors are ordinary Mode 2 Form 1, which the drive's block
// layer already translates to plain 2048-byte reads; only the MOVIE DATA
// itself (read by dvd_vcd.cpp) is raw Mode 2 Form 2 and needs the dedicated
// READ CD path there.
//
// Checked from dvd_phys.cpp's mount dispatch AFTER dvd_video_probe() rejects
// a disc (no VIDEO_TS) -- see docs/physical_disc.md's detection table, which
// already lists this disc type as a known-rejected row.
int dvd_vcd_probe(int fd);

#endif
