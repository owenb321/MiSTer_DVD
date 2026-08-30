// dvd_phys.h — standalone physical-DVD auto-mount for the DVD core's custom Main.
//
// In the MiSTer Physical Disc fork, the fork's own launcher detected a disc and
// called user_io_file_mount(PHYSICAL_DISC_SENTINEL) to hand the drive to the DVD
// core. This module replaces that trigger so the DVD core plays physical discs on
// STOCK MiSTer, with no fork installed: it watches /dev/srN itself, and when a
// DVD-Video disc appears it mounts it into the core over the generic sd_* block
// interface (served CSS-decrypted by dvd_css.*). Removing the disc unmounts it.
//
// The fork (Auto Disc Discovery) remains an OPTIONAL convenience: it only adds
// launching the DVD core automatically from another core / the menu. Once the DVD
// core is open, this module — not the fork — owns the disc.

#ifndef MISTER_DVD_PHYS_H
#define MISTER_DVD_PHYS_H

// Sentinel image name that tells user_io_file_mount() to bind the slot to the
// optical drive (CSS-decrypted) instead of a file. Must not collide with a real
// path; the fork used "*PHYSICAL_DISC*" for the same purpose.
#define DVD_PHYS_SENTINEL "*DVD_PHYS*"

// Call every user_io_poll (only meaningful while the DVD core is loaded — it
// self-gates on is_dvd()). Debounced drive scan:
//   - DVD-Video disc appears  -> user_io_file_mount(DVD_PHYS_SENTINEL, 0)
//   - disc removed while mounted -> user_io_file_mount("", 0) + dvd_css_close()
// No-op on non-DVD cores and while nothing changes.
void dvd_phys_tick(void);

#endif
