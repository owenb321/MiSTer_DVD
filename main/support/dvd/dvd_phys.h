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
//   - disc removed while WE own the slot -> user_io_file_mount("", 0) + dvd_css_close()
// No-op on non-DVD cores and while nothing changes.
//
// ⚠ "while WE own the slot" is load-bearing and was not always true. The drive
// shares slot 0 with every image the user can load, so an auto-mounted disc that
// is later replaced by a file must be FORGOTTEN, not remembered: otherwise
// ejecting a disc nobody is watching tears down the file that IS playing and
// resets the core. See dvd_phys_note_mount().
void dvd_phys_tick(void);

// Call from user_io_file_mount() with the path and slot it was handed, so this
// module can see slot 0 being taken by something that is not the drive. Slots
// other than 0 are ignored -- the drive only ever binds slot 0, and the core
// declares no other file entry, but Main mounts boot*.vhd across slots 0-3 at
// init and this module must not read one of those as a claim on its slot.
//
// Two things depend on it:
//   - an eject only tears down and resets when the drive still owns the slot;
//   - the auto-mount does not fire over an image the user asked for, which is
//     what an MGL launch does (its <file> mount lands `delay` seconds after the
//     core comes up, so without this the drive would win the race, crack keys
//     for minutes, and then be replaced by the file anyway).
// Observes only.
void dvd_phys_note_mount(const char *path, unsigned char index);

// The /dev/srN node of the disc currently mounted by this module, or NULL when
// nothing is mounted. Exported for dvd_report.cpp, which hands it to
// tools/dvd_report.py: every sector that tool reads is one CSS never scrambles,
// so a support bundle can be built straight off the drive with no decryption.
const char *dvd_phys_device(void);

#endif
