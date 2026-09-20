// dvd_phys.cpp — see dvd_phys.h.
//
// Self-contained: opens /dev/srN read-only-nonblocking for status/probe only,
// and drives the mount through the public user_io_file_mount() entry point. The
// actual sector decryption lives in dvd_css.*; DVD-Video recognition in
// dvd_detect.*; VCD/SVCD recognition and its (decryption-free) reads in
// dvd_vcd_detect.*/dvd_vcd.*. This file adds only "when to mount / unmount /
// which of the two sources".

#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <sys/time.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <limits.h>          // INT_MAX — CDSL_CURRENT expands to it via <linux/cdrom.h>
#include <sys/ioctl.h>
#include <linux/cdrom.h>

#include "dvd_phys.h"
#include "dvd_detect.h"
#include "dvd_vcd_detect.h"
#include "dvd_css.h"
#include "dvd_vcd.h"
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
static int    probed_unrecognized = 0; // this disc was probed and is none of the
                                        // recognized types (DVD-Video / VCD / SVCD)

// ---------------------------------------------------------------------------
// The one teardown path: unmount, drop the CSS session, reset the core to idle
// ---------------------------------------------------------------------------
// Factored out of the disc-removal branch so the Eject BUTTON (B19, arriving
// via dvd_remote.cpp) runs byte-identical steps. Keeping it here rather than
// duplicating it in the caller is deliberate: `mounted` / `mounted_dev` /
// `reset_release_at` are this file's slot-ownership state, and issue #48 was
// exactly what happens when something else decides it owns slot 0.
static void teardown_to_idle(time_t now)
{
	user_io_file_mount("", 0);
	dvd_css_close();
	dvd_vcd_close();
	mounted_dev[0] = 0;
	user_io_status_set("[0]", 1);   // OSD-reset: unload + VM reset -> idle logo
	reset_release_at = now + 1;     // release after ~1 s (see the tick top)
	mounted = 0;
}

// ---------------------------------------------------------------------------
// Scan backoff — the drive probe runs on the thread that feeds the decoder
// ---------------------------------------------------------------------------
// open_ready_drive() is BLOCKING I/O on the same thread as user_io_poll()'s SD
// block service, so however long it takes is time the core gets no data. With a
// settled drive that is microseconds and nobody notices. With an OPEN TRAY it is
// not: the kernel's sr driver answers TEST UNIT READY with a media-change unit
// attention and retries, which can run to hundreds of milliseconds -- every
// second, for as long as the tray stays open, because the state never settles.
//
// Field report that produced this: an MGL-loaded .mpg played fine, and ejecting an
// unrelated disc froze the picture for good while the OSD kept working. Main was
// alive; the core was being starved a large fraction of every second.
//
// So the probe is now self-limiting. A slow scan backs the period off (doubling,
// capped), a fast one restores it. Worst case is one hiccup per DVD_PHYS_SCAN_MAX_S
// instead of one per second, and a disc insertion is still noticed within that.
#define DVD_PHYS_SLOW_MS      50   // above this, the probe is disturbing playback
#define DVD_PHYS_SCAN_MAX_S   10   // hard cap on the backoff

static int    scan_period = DVD_PHYS_SCAN_PERIOD_S;
static int    slow_logged = 0;

static unsigned now_ms(void)
{
	struct timeval tv;
	gettimeofday(&tv, 0);
	return (unsigned)(tv.tv_sec * 1000u + tv.tv_usec / 1000u);
}

// Shares /tmp/dvd_report.log with dvd_report.cpp -- one file to ask a reporter for.
// Only decisions get a line, never the 1 Hz scan, so the log stays readable across
// a whole session. This exists because "eject froze playback" has two completely
// different causes depending on WHICH image was playing, and the console is not
// something most users can capture.
static void phys_log(const char *fmt, ...)
{
	va_list ap;
	FILE *f = fopen("/tmp/dvd_report.log", "a");
	if (!f) return;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fprintf(f, "\n");
	fclose(f);
}

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

	if (!strcmp(path, DVD_PHYS_SENTINEL))     { foreign = 0; return; }   // that is us
	if (!strcmp(path, DVD_PHYS_VCD_SENTINEL)) { foreign = 0; return; }   // that is us too

	// A real file went into the slot. Whatever we thought we owned, we do not own
	// it any more -- user_io_file_mount() has already called dvd_css_close() on
	// our source. Forgetting `mounted` here is what stops a later eject from
	// unmounting the user's file and resetting the core out from under it.
	if (mounted) phys_log("DVD_PHYS: slot taken by %s -- releasing the drive", path);
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

	// Only watching for an INSERTION while somebody else owns the slot, so there
	// is nothing to be quick about; a disc going in is noticed a few seconds later
	// and nothing else changes.
	int period = foreign ? 5 : scan_period;
	if (period < scan_period) period = scan_period;
	if (now - last_scan < period) return;
	last_scan = now;

	unsigned t0 = now_ms();
	char dev[16] = {0};
	int fd = open_ready_drive(dev, sizeof(dev));
	unsigned took = now_ms() - t0;

	if (took >= DVD_PHYS_SLOW_MS)
	{
		int was = scan_period;
		scan_period *= 2;
		if (scan_period > DVD_PHYS_SCAN_MAX_S) scan_period = DVD_PHYS_SCAN_MAX_S;
		if (!slow_logged || scan_period != was)
		{
			slow_logged = 1;
			phys_log("DVD_PHYS: drive probe took %u ms (blocking the poll loop) -- "
			         "backing the scan off to %ds", took, scan_period);
		}
	}
	else if (scan_period != DVD_PHYS_SCAN_PERIOD_S)
	{
		scan_period = DVD_PHYS_SCAN_PERIOD_S;
		slow_logged = 0;
		phys_log("DVD_PHYS: drive probe is fast again (%u ms) -- back to %ds",
		         took, scan_period);
	}

	if (fd < 0)
	{
		int was_ready = prev_ready;
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
		if (!mounted)
		{
			// Nothing of ours to tear down. Say so once per removal: if playback
			// froze at this moment anyway, this line proves it was not us.
			if (was_ready)
				phys_log("DVD_PHYS: disc removed, but the drive does not own slot 0 "
				         "(foreign=%d) -- leaving playback alone", foreign);
			return;
		}

		phys_log("DVD_PHYS: disc removed while playing it -- unmount + reset to idle");
		teardown_to_idle(now);
		return;
	}

	// An insertion edge clears the "somebody else has the slot" latch: putting a
	// disc in is a deliberate act, and the auto-mount is the only way to play one.
	// A disc that was ALREADY sitting in the drive does not get to take the slot
	// back from an image the user asked for. Drive READINESS is the edge, not the
	// verdict, so this costs one ioctl and reads nothing off the disc.
	if (!prev_ready) { foreign = 0; probed_unrecognized = 0; }
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
	//   probed_unrecognized - an audio CD or data disc; the verdict cannot change
	//              without an eject, so probe it once per insertion, not once a
	//              second for as long as it sits there
	if (mounted || dvd_launch_ui_busy() || foreign || probed_unrecognized)
	{
		close(fd);
		return;
	}

	// DVD-Video first, VCD/SVCD second -- both probes are cheap READ(10)s of the
	// ISO9660 root, and a disc is at most one of the two. Leave audio CDs / data
	// discs alone (they are not ours to play).
	int is_dvd_video = dvd_video_probe(fd);
	int is_vcd = !is_dvd_video && dvd_vcd_probe(fd);
	close(fd);
	if (!is_dvd_video && !is_vcd)
	{
		// Say so once per insertion. Without this, "I put a disc in and nothing
		// happened" has no record at all, and the two explanations -- we rejected
		// it, or we never saw it -- look identical from the outside.
		probed_unrecognized = 1;
		phys_log("DVD_PHYS: disc on %s is not DVD-Video or VCD/SVCD "
		         "-- not mounting", dev);
		return;
	}

	const char *sentinel = is_dvd_video ? DVD_PHYS_SENTINEL : DVD_PHYS_VCD_SENTINEL;
	phys_log("DVD_PHYS: %s on %s -- mounting",
	         is_dvd_video ? "DVD-Video" : "VCD/SVCD", dev);
	// The sentinel routes user_io_file_mount() to the matching drive-backed
	// source (SD_TYPE_DVDCSS / SD_TYPE_VCD in user_io.cpp). dvd_css_open()/
	// dvd_vcd_open() inside it re-scan for the drive; a CSS failure (no
	// libdvdcss on an encrypted disc) surfaces the on-screen install prompt --
	// VCD/SVCD has no such handshake to fail.
	if (user_io_file_mount(sentinel, 0))
	{
		mounted = 1;
		snprintf(mounted_dev, sizeof(mounted_dev), "%s", dev);
	}
}

const char *dvd_phys_device(void)
{
	return mounted_dev[0] ? mounted_dev : 0;
}

// ---------------------------------------------------------------------------
// dvd_phys_eject() -- the Eject button's action (see dvd_phys.h)
// ---------------------------------------------------------------------------
int dvd_phys_eject(void)
{
	time_t now = time(NULL);
	int  had_disc = mounted;
	char dev[sizeof(mounted_dev)];

	// Remember which /dev/srN it was: the teardown clears mounted_dev.
	dev[0] = 0;
	if (mounted && mounted_dev[0]) strncpy(dev, mounted_dev, sizeof(dev) - 1);
	dev[sizeof(dev) - 1] = 0;

	// ⚠⚠ TEARDOWN FIRST, THEN THE TRAY. The first build did the opposite and
	// the tray never opened: at that point the mounted file and the libdvdcss
	// session still hold /dev/srN OPEN, so the kernel refuses to eject a busy
	// device. user_io_file_mount("") + dvd_css_close() are what release it.
	phys_log("DVD_PHYS: eject button -- unmount + reset to idle%s",
	         had_disc ? " (optical disc)" : " (image)");
	teardown_to_idle(now);

	// ⚠⚠ AND STOP THE AUTO-MOUNT TAKING THE SAME DISC STRAIGHT BACK. The scan
	// runs at ~1 Hz and the disc is still sitting in the drive for at least as
	// long as the tray takes to open -- and forever if there is no tray motor,
	// or if the eject is refused. The field report was exactly this: "eject
	// does not eject the disc, instead it reloads it... we see the key cracking
	// message again and the disc starts over".
	//
	// `foreign` is the existing mechanism for "do not auto-mount", and its
	// clear condition is already the right one: a disc INSERTION EDGE. So if
	// the tray opens and a disc is put back, readiness goes 0 -> 1, the edge
	// clears this, and auto-mount resumes. If the tray never opens, readiness
	// never drops and the disc stays un-mounted until the user does something
	// deliberate. No new state, and no timer to tune.
	foreign = 1;
	probed_unrecognized = 0;
	// (prev_ready is deliberately NOT forced: the last scan already saw the
	// disc ready, so the next one cannot read an insertion edge anyway, and
	// forcing it would only delay a genuine re-insertion.)

	// Now the tray, with the device released. Advisory: a failure just means it
	// stays shut, which is the same outcome as a machine with no drive -- but
	// log the errno, because "the tray did not open" has several causes and
	// only this line tells them apart.
	if (dev[0])
	{
		int fd = open(dev, O_RDONLY | O_NONBLOCK);
		if (fd < 0)
		{
			phys_log("DVD_PHYS: eject: cannot open %s (errno %d)", dev, errno);
		}
		else
		{
			ioctl(fd, CDROM_LOCKDOOR, 0);            // a playing disc may be locked
			if (ioctl(fd, CDROMEJECT, 0) < 0)
				phys_log("DVD_PHYS: eject: tray would not open on %s (errno %d)",
				         dev, errno);
			else
				phys_log("DVD_PHYS: eject: tray opened on %s", dev);
			close(fd);
		}
	}

	return had_disc;
}
