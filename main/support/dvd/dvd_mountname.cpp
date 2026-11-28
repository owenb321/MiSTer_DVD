// dvd_mountname.cpp — see dvd_mountname.h.

#include <stdio.h>
#include <string.h>
#include <strings.h>

#include "dvd_mountname.h"
#include "dvd_phys.h"         // the drive's sentinel names
#include "../../charrom.h"    // charfont[][]: Main draws the OSD text from it itself

// Labels that name the tool, not the disc. Every entry here was seen in the local
// library (2026-11-25 sweep); add one only on the same kind of evidence, because a
// real title that happens to match would lose its name.
static const char *const generic_labels[] = { "CDROM", "DVDVOLUME", "DVD_VIDEO", "DVDVIDEO" };

int dvd_mountname_from_pvd(const uint8_t *pvd, char *out, size_t n)
{
	if (!n) return 0;
	out[0] = 0;
	if (pvd[0] != 1 || memcmp(pvd + 1, "CD001", 5)) return 0;

	// Volume identifier: bytes 40-71, space-padded (ECMA-119 8.4.6).
	char lab[33];
	memcpy(lab, pvd + 40, 32);
	lab[32] = 0;
	int len = 32;
	while (len > 0 && (lab[len - 1] == ' ' || lab[len - 1] == 0)) lab[--len] = 0;
	int start = 0;
	while (lab[start] == ' ') start++;
	if (!lab[start]) return 0;
	for (int i = start; lab[i]; i++)
	{
		if ((uint8_t)lab[i] < 0x20 || (uint8_t)lab[i] > 0x7E) return 0;
		if (lab[i] == '/') lab[i] = '_';
	}
	for (size_t g = 0; g < sizeof(generic_labels) / sizeof(generic_labels[0]); g++)
		if (!strcasecmp(lab + start, generic_labels[g])) return 0;

	snprintf(out, n, "%s", lab + start);
	return 1;
}

// The disc, 7x7: a solid disc with a pin hole. Main's font is column-major, one
// byte per column, bit 0 at the top (compare charrom.cpp's 0x16 arrow). Columns 0-6
// like the letters, so column 7 is the one-pixel gap before the name -- the same
// gap the stock arrow leaves.
//   ..###..
//   .#####.
//   #######
//   ###.###
//   #######
//   .#####.
//   ..###..
static const unsigned char disc_glyph[8] = { 0x1C, 0x3E, 0x7F, 0x77, 0x7F, 0x3E, 0x1C, 0x00 };

#define MAX_SLOTS 16
static unsigned char drive_slot[MAX_SLOTS];

void dvd_mountname_note(unsigned char index, const char *mount_name, int ok, int dvd_src,
                        char *img_name, size_t img_name_sz, const char *drive_name)
{
	if (index >= MAX_SLOTS) return;

	const char *m = mount_name ? mount_name : "";
	int is_drive = !strcmp(m, DVD_PHYS_SENTINEL) || !strcmp(m, DVD_PHYS_VCD_SENTINEL);
	drive_slot[index] = ok && dvd_src && is_drive;

	// Only our own sources: everything else went through FileOpen(), which wrote the
	// name itself (and a failed mount sets the size to 0, so the row stops reading it).
	if (!ok || !dvd_src || !img_name || !img_name_sz) return;

	if (is_drive)
	{
		memcpy(charfont[DVD_MOUNTNAME_GLYPH], disc_glyph, sizeof(disc_glyph));
		snprintf(img_name, img_name_sz, "%s", (drive_name && *drive_name) ? drive_name : "Disc in drive");
	}
	else
	{
		if (img_name != m) snprintf(img_name, img_name_sz, "%s", m);   // shown: the part after the last '/'
	}
}

int dvd_mountname_is_drive(int index)
{
	return index >= 0 && index < MAX_SLOTS && drive_slot[index];
}
