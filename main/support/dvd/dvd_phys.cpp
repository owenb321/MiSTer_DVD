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
#include "dvd_launch.h"
#include "../../user_io.h"   // user_io_file_mount(), is_dvd()

// Poll cadence: a full SCSI probe every tick would hammer the drive, so gate the
// scan to ~1 Hz. The optical drive can sit NOT_READY for a second or two while it
// spins up, so a freshly inserted disc is simply picked up on a later tick.
#define DVD_PHYS_SCAN_PERIOD_S 1

static int    mounted = 0;         // 1 while WE own slot 0 with the optical drive
static char   mounted_dev[16] = {0};  // its /dev/srN, exported by dvd_phys_device()
static time_t last_scan = 0;
static time_t reset_release_at = 0; // >0 while an eject reset pulse is being held

// Slot 0 is shared with every image the user can load, and the drive is only one
// claimant. `foreign` means somebody else holds it: do not auto-mount over them,
// and do not treat their image as ours to tear down when a disc is removed.
//
// Cleared on a disc INSERTION edge, not on a timer -- putting a disc in is a
// deliberate act and the auto-mount is the only way to play one, so an insertion
// still wins. A disc merely SITTING in the drive never does.
static int    foreign = 0;
static int    prev_ready = 0;      // the drive reported a disc ready on the last scan
static int    probed_not_video = 0; // this disc was probed and is not DVD-Video

// Find the first /dev/srN that currently holds a disc reported ready. Fills `out`
// (size >= 16) and returns an fd opened O_RDONLY|O_NONBLOCK, or -1. Mirrors the
// scan in dvd_css.cpp so the two agree on which drive is "the" drive.
//
// The one seam for main/tests/dvd_phys_test.cpp, which #includes this file and
// supplies its own: everything else the tick touches is an ordinary extern the
// test can stub at link time, but a real /dev/srN cannot be faked (a regular file
// opens fine and then fails CDROM_DRIVE_STATUS). Nothing else is conditional.
#ifndef DVD_PHYS_TEST
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
#endif

void dvd_phys_note_mount(const char *path, unsigned char index)
{
	if (!path || index != 0) return;   // the drive only ever binds slot 0

	if (!path[0])
	{
		// An unmount. If it is ours, dvd_phys_tick() is the one doing it and has
		// already cleared `mounted`; if it is somebody else's, the slot is simply
		// free again and the next insertion may claim it.
		foreign = 0;
		return;
	}

	if (!strcmp(path, DVD_PHYS_SENTINEL)) { foreign = 0; return; }   // that is us

	// A real file went into the slot. Whatever we thought we owned, we do not own
	// it any more -- user_io_file_mount() has already called dvd_css_close() on
	// our source. Forgetting `mounted` here is what stops a later eject from
	// unmounting the user's file and resetting the core out from under it.
	if (mounted) printf("DVD_PHYS: slot taken by %s, releasing the drive\n", path);
	mounted = 0;
	mounted_dev[0] = 0;
	foreign = 1;
}

void dvd_phys_tick(void)
{
	if (!is_dvd()) return;

	time_t now = time(NULL);

	// Release the eject reset pulse once it has been held briefly, so the idle screen
	// (bouncing logo + OSD file picker) runs instead of the core sitting in reset.
	if (reset_release_at && now >= reset_release_at)
	{
		user_io_status_set("[0]", 0);
		reset_release_at = 0;
	}

	if (now - last_scan < DVD_PHYS_SCAN_PERIOD_S) return;
	last_scan = now;

	char dev[16] = {0};
	int fd = open_ready_drive(dev, sizeof(dev));

	if (fd < 0)
	{
		prev_ready = 0;

		// No ready disc. If WE still own the slot, the disc was ejected/removed:
		// tear it down and soft-reset the core back to the idle logo so a gone
		// disc doesn't leave a frozen last frame.
		//
		// ⚠ Only if we still own it. `mounted` used to mean "we mounted a disc at
		// some point", so ejecting a disc nobody was watching unmounted whatever
		// the user had loaded since -- freezing playback (the file handle is gone)
		// and resetting the core. dvd_phys_note_mount() now clears `mounted` the
		// moment another image takes the slot.
		if (mounted)
		{
			printf("DVD_PHYS: disc removed, unmounting + reset to idle\n");
			user_io_file_mount("", 0);
			dvd_css_close();
			mounted_dev[0] = 0;
			user_io_status_set("[0]", 1);   // OSD-reset: unload + VM reset -> idle logo
			reset_release_at = now + 1;      // release after ~1 s (see the tick top)
			mounted = 0;
		}
		return;
	}

	// An insertion edge clears the "somebody else has the slot" latch: putting a
	// disc in is a deliberate act, and the auto-mount is the only way to play one.
	// A disc that was ALREADY sitting in the drive does not get to take the slot
	// back from an image the user asked for. Drive READINESS is the edge, not the
	// DVD-Video verdict, so this costs one ioctl and reads nothing off the disc.
	if (!prev_ready) { foreign = 0; probed_not_video = 0; }
	prev_ready = 1;

	// ⚠ Every reason not to mount is checked BEFORE dvd_video_probe(), which is
	// the first thing here that actually reads the disc. "Do no disc operations
	// when we were launched to play a file" has to mean no reads, not just no
	// mount -- otherwise a spinning drive is probed once a second for the whole
	// session, and on an encrypted disc the mount that follows costs minutes of
	// key extraction the user never asked for.
	//   mounted  - already playing this disc
	//   ui_busy  - an MGL launch is pending; its own <file> lands `delay` seconds
	//              from now and would replace whatever we mounted anyway.
	//              Deferring costs nothing: if no file arrives, the launch settles
	//              and the next scan mounts the disc a second later.
	//   foreign  - an image the user chose is in the slot
	//   probed_not_video - an audio CD or data disc; the verdict cannot change
	//              without an eject, so probe it once per insertion, not once a
	//              second for as long as it sits there
	if (mounted || dvd_launch_ui_busy() || foreign || probed_not_video)
	{
		close(fd);
		return;
	}

	// Only mount DVD-Video discs — leave audio CDs / data discs alone (they are
	// not ours to play).
	int is_dvd_video = dvd_video_probe(fd);
	close(fd);
	if (!is_dvd_video) { probed_not_video = 1; return; }

	printf("DVD_PHYS: DVD-Video on %s, mounting\n", dev);
	// The sentinel routes user_io_file_mount() to the CSS-decrypted drive path
	// (see the SD_TYPE_DVDCSS handling in user_io.cpp). dvd_css_open() inside it
	// re-scans for the drive and runs the CSS handshake; a failure there (no
	// libdvdcss on an encrypted disc) surfaces the on-screen install prompt.
	if (user_io_file_mount(DVD_PHYS_SENTINEL, 0))
	{
		mounted = 1;
		snprintf(mounted_dev, sizeof(mounted_dev), "%s", dev);
	}
}

const char *dvd_phys_device(void)
{
	return mounted_dev[0] ? mounted_dev : 0;
}
