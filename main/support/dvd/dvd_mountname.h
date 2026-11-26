// dvd_mountname.h — the name the OSD's "Load Video" row shows for what is mounted.
//
// Stock Main (from upstream 2dd3662, "menu: show mounted file for S option") draws a
// mounted S-slot as "\x16<file name>", reading the name out of sd_image[n].name. That
// field is filled by FileOpen(), and the DVD core's own mounts never call it: a
// physical disc, an .iso (dvd_css_open_image) and a .cue are served by our sources,
// not by an open file. So the row showed the arrow and nothing else -- or, after a
// plain .VOB/.mpg, that earlier file's name, because nothing clears the field.
//
// This module fills the name in for those mounts and marks the row of a disc in the
// drive with its own icon:
//   * an .iso / .cue: the file name, exactly what stock shows for any other file;
//   * the drive: the disc's ISO9660 volume label, or "DVD in drive" / "Video CD in
//     drive" / "Audio CD in drive" when the label is missing or generic;
//   * the drive's row starts with the disc glyph (DVD_MOUNTNAME_GLYPH) instead of
//     stock's arrow, so a disc and a file are told apart at a glance (maintainer,
//     2026-11-25: icon on the disc only, files keep the stock arrow).
// See main/integration/INTEGRATION.md "Steps 63-65".

#ifndef MISTER_DVD_MOUNTNAME_H
#define MISTER_DVD_MOUNTNAME_H

#include <stddef.h>
#include <stdint.h>

// A free slot in Main's OSD font (charrom.cpp defines nothing past 0x96). A custom
// `font=` in MiSTer.ini only replaces this one if it is a full 2 KB font.
#define DVD_MOUNTNAME_GLYPH 0x97

// The volume label out of a primary volume descriptor (sector 16), or 0 when it is
// unusable: empty, not printable ASCII, or one of the generic labels an authoring or
// ripping tool writes in place of a name (measured on the local library: 1,494 of
// 1,618 rebuilt rips read "CDROM"). `out` gets at most n-1 characters; a '/' is
// replaced, because Main shows the text after the last '/'.
int dvd_mountname_from_pvd(const uint8_t *pvd, char *out, size_t n);

// Call from user_io_file_mount() after its dispatch, every time, with the mount's
// outcome. `dvd_src` is 1 when the slot ended up on one of our sources (SD_TYPE_DVDCSS
// or SD_TYPE_VCD), so the name field was never written by FileOpen(). `img_name` is
// sd_image[index].name; `drive_name` is what dvd_phys chose for a disc in the drive.
void dvd_mountname_note(unsigned char index, const char *mount_name, int ok, int dvd_src,
                        char *img_name, size_t img_name_sz, const char *drive_name);

// 1 while slot `index` holds the optical drive (the load row then draws the disc).
int dvd_mountname_is_drive(int index);

#endif
