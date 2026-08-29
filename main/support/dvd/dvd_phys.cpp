// dvd_phys.cpp — see dvd_phys.h.
//
// Self-contained: opens /dev/srN read-only-nonblocking for status/probe only,
// and drives the mount through the public user_io_file_mount() entry point. The
// actual sector decryption lives in dvd_css.*; DVD-Video recognition in
// dvd_detect.*. This file adds only "when to mount / unmount".

#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <limits.h>          // INT_MAX — CDSL_CURRENT expands to it via <linux/cdrom.h>
#include <sys/ioctl.h>
#include <linux/cdrom.h>

#include "dvd_phys.h"
#include "dvd_detect.h"
#include "dvd_css.h"
#include "../../user_io.h"   // user_io_file_mount(), is_dvd()

// Poll cadence: a full SCSI probe every tick would hammer the drive, so gate the
// scan to ~1 Hz. The optical drive can sit NOT_READY for a second or two while it
// spins up, so a freshly inserted disc is simply picked up on a later tick.
#define DVD_PHYS_SCAN_PERIOD_S 1

static int    mounted = 0;   // 1 while a DVD-Video disc is mounted into the core
static time_t last_scan = 0;

// Find the first /dev/srN that currently holds a disc reported ready. Fills `out`
// (size >= 16) and returns an fd opened O_RDONLY|O_NONBLOCK, or -1. Mirrors the
// scan in dvd_css.cpp so the two agree on which drive is "the" drive.
static int open_ready_drive(char *out, int out_sz)
{
	for (int i = 0; i < 8; i++)
	{
		char path[16];
		snprintf(path, sizeof(path), "/dev/sr%d", i);
		int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0) continue;
		int status = ioctl(fd, CDROM_DRIVE_STATUS, CDSL_CURRENT);
		if (status == CDS_DISC_OK)
		{
			if (out && out_sz > 0) { strncpy(out, path, out_sz - 1); out[out_sz - 1] = 0; }
			return fd;   // caller closes
		}
		close(fd);
	}
	return -1;
}

void dvd_phys_tick(void)
{
	if (!is_dvd()) return;

	time_t now = time(NULL);
	if (now - last_scan < DVD_PHYS_SCAN_PERIOD_S) return;
	last_scan = now;

	char dev[16] = {0};
	int fd = open_ready_drive(dev, sizeof(dev));

	if (fd < 0)
	{
		// No ready disc. If we had one mounted, the disc was ejected/removed:
		// tear the slot down so the core stops streaming a gone disc.
		if (mounted)
		{
			printf("DVD_PHYS: disc removed, unmounting\n");
			user_io_file_mount("", 0);
			dvd_css_close();
			mounted = 0;
		}
		return;
	}

	if (mounted) { close(fd); return; }   // already playing this disc

	// A disc is ready and nothing is mounted yet. Only mount DVD-Video discs —
	// leave audio CDs / data discs alone (they are not ours to play).
	int is_dvd_video = dvd_video_probe(fd);
	close(fd);
	if (!is_dvd_video) return;

	printf("DVD_PHYS: DVD-Video on %s, mounting\n", dev);
	// The sentinel routes user_io_file_mount() to the CSS-decrypted drive path
	// (see the SD_TYPE_DVDCSS handling in user_io.cpp). dvd_css_open() inside it
	// re-scans for the drive and runs the CSS handshake; a failure there (no
	// libdvdcss on an encrypted disc) surfaces the on-screen install prompt.
	if (user_io_file_mount(DVD_PHYS_SENTINEL, 0)) mounted = 1;
}
