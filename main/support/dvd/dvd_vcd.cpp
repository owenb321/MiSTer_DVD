// dvd_vcd.cpp — see dvd_vcd.h.
//
// Self-contained on purpose, in the dvd_detect.cpp / dvd_css.cpp style: it
// finds its own drive and issues its own ioctls, with no dependency on stock
// Main's support/physical_disc/physical_disc.cpp. dvd_vcd_open() mirrors
// dvd_css_open()'s shape exactly (its own device scan, its own persistent
// fd) because it is called the same way -- from user_io_file_mount()'s
// dispatch, which has no fd to hand over. Only the READ CD (0xBE) CDB shape
// is adapted from the same command as the parked feature/cdda-physical
// branch's dvd_cdda.cpp (hardware-proven there) -- the one difference is the
// "expected sector type" and "main channel selection" fields, spelled out
// below, because a VCD/SVCD data track mixes Mode 2 Form 1 (filesystem) and
// Form 2 (MPEG payload) sectors while a CD-DA track is one uniform type
// throughout.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>          // INT_MAX -- CDSL_CURRENT expands to it via <linux/cdrom.h>
#include <sys/ioctl.h>
#include <scsi/sg.h>
#include <linux/cdrom.h>

#include "dvd_vcd.h"
#include "dvd_readahead.h"

static int vcd_src_read(void *buf, uint32_t lba, uint32_t cnt);

// Bursts are capped at what one 16 KB transfer could possibly touch:
// 16384/2352 rounds up to 7, +1 headroom. In practice dvd/emu.sv requests one
// 2048-byte block per sd_* round trip today, so most calls ask for a single
// frame's worth or less -- this just bounds the worst case a future change
// might ask for.
#define VCD_BURST_MAX   16
#define VCD_TIMEOUT_MS  3000

static dvd_vcd_track g_trk;
static int           g_fd   = -1;
static int           g_open = 0;
static char          g_dev[16] = {0};
static uint8_t      *g_scratch = 0;      // VCD_BURST_MAX frames
static int           g_readfail = 0;     // rate-limited logging

// ---------------------------------------------------------------- pure helper

uint64_t dvd_vcd_image_size(const dvd_vcd_track *trk)
{
	if (!trk || trk->len <= 0) return 0;
	return (uint64_t)trk->len * DVD_VCD_RAW;
}

// ---------------------------------------------------------------- drive access

// READ CD (0xBE). cdb[1]=0x00 declares "expected sector type = any" (a VCD/
// SVCD data track mixes Mode 2 Form 1 filesystem sectors with Form 2 MPEG
// payload sectors, so nothing narrower is safe) and cdb[9]=0xF8 asks for the
// FULL RAW SECTOR -- Sync(1) + Header=11(header AND subheader) + UserData(1)
// + EDC/ECC(1) -- exactly 2352 bytes matching a .bin rip byte for byte.
// ⚠ This is DELIBERATELY NOT the CD-DA branch's cdb[9]=0x10 ("user data
// only"): a CD-DA sector's "user data" IS all 2352 bytes, but a Mode 2
// sector's is not -- dvd_iso_reader.sv's raw2352 detector reads the 12-byte
// sync pattern and the mode/submode bytes at fixed offsets 15/18, all of
// which sit OUTSIDE "user data" for this sector type and would be missing
// from a 0x10 read.
static int scsi_read_cd(int fd, int lba, int count, uint8_t *dst, int timeout_ms)
{
	uint8_t cdb[12] = { 0 }, sense[32] = { 0 };
	struct sg_io_hdr io;

	cdb[0]  = 0xBE;
	cdb[1]  = 0x00;
	cdb[2]  = (lba >> 24) & 0xFF; cdb[3] = (lba >> 16) & 0xFF;
	cdb[4]  = (lba >> 8)  & 0xFF; cdb[5] = lba & 0xFF;
	cdb[6]  = (count >> 16) & 0xFF; cdb[7] = (count >> 8) & 0xFF;
	cdb[8]  = count & 0xFF;
	cdb[9]  = 0xF8;
	cdb[10] = 0x00;

	memset(&io, 0, sizeof(io));
	io.interface_id    = 'S';
	io.cmd_len         = sizeof(cdb);
	io.cmdp            = cdb;
	io.dxfer_direction = SG_DXFER_FROM_DEV;
	io.dxfer_len       = count * DVD_VCD_RAW;
	io.dxferp          = dst;
	io.sbp             = sense;
	io.mx_sb_len       = sizeof(sense);
	io.timeout         = timeout_ms;

	if (ioctl(fd, SG_IO, &io) < 0) return -1;
	if (io.status || io.host_status || io.driver_status) return -1;
	return 0;
}

// Per-sector MSF fallback, used only when a burst fails. A drive that
// refuses 0xBE mid-disc (a scratch) may still serve this one.
static int ioctl_read_raw(int fd, int lba, uint8_t *dst)
{
	union { struct cdrom_msf msf; uint8_t raw[DVD_VCD_RAW]; } req;
	int f = lba + 150;   // MSF is offset by the 2-second lead-in
	memset(&req, 0, sizeof(req));
	req.msf.cdmsf_min0   = f / (75 * 60);
	req.msf.cdmsf_sec0   = (f / 75) % 60;
	req.msf.cdmsf_frame0 = f % 75;
	if (ioctl(fd, CDROMREADRAW, &req) < 0) return -1;
	memcpy(dst, req.raw, DVD_VCD_RAW);
	return 0;
}

// Read `count` CONSECUTIVE disc sectors, clamped to the track by the caller.
#ifdef DVD_VCD_TEST
// The host test supplies its own, filling each frame from its disc LBA so
// every byte of the virtual image is traceable back to the sector it must
// have come from. This is the ONLY seam in the module: everything else is
// either pure arithmetic or the TOC read.
static int read_frames(int lba, int count, uint8_t *dst);
#else
static int read_frames(int lba, int count, uint8_t *dst)
{
	if (!scsi_read_cd(g_fd, lba, count, dst, VCD_TIMEOUT_MS)) return 0;

	// Burst failed: fall back per sector so one bad frame costs one frame of
	// video, not the whole window.
	for (int i = 0; i < count; i++)
	{
		uint8_t *p = dst + (size_t)i * DVD_VCD_RAW;
		if (!scsi_read_cd(g_fd, lba + i, 1, p, VCD_TIMEOUT_MS)) continue;
		if (!ioctl_read_raw(g_fd, lba + i, p)) continue;
		// Unreadable. Zero-fill so dvd_iso_reader.sv's mode/submode bytes read
		// as a harmless Form-1 sector (mode != 2, skipped by the deblocker)
		// rather than a plausible-looking wrong payload.
		memset(p, 0, DVD_VCD_RAW);
		if (g_readfail < 10)
		{
			g_readfail++;
			printf("DVD_VCD: sector %d unreadable -- zero-filled\n", lba + i);
		}
	}
	return 0;
}
#endif

// ---------------------------------------------------------------- open / close

// Find the first /dev/srN reporting a disc ready. Mirrors dvd_css.cpp's
// find_dvd_device() (its size-query and not-ready fallback are DVD-CSS-only
// concerns, not needed here -- dvd_vcd_open() is called moments after
// dvd_phys.cpp's own probe found the same drive ready, so the common case is
// an immediate re-hit).
#ifndef DVD_VCD_TEST
static int find_vcd_device(char *out, int outsz)
{
	for (int i = 0; i < 8; i++)
	{
		char path[32];
		snprintf(path, sizeof(path), "/dev/sr%d", i);
		int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0) continue;
		int status = ioctl(fd, CDROM_DRIVE_STATUS, CDSL_CURRENT);
		close(fd);
		if (status == CDS_DISC_OK)
		{
			snprintf(out, outsz, "%s", path);
			return 1;
		}
	}
	return 0;
}
#else
// The host test fakes open()/close() too and drives find_vcd_device() through
// its own fake_* state -- see dvd_vcd_test.cpp.
static int find_vcd_device(char *out, int outsz);
#endif

int dvd_vcd_open(void)
{
	struct cdrom_tochdr hdr;
	struct cdrom_tocentry e;

	if (g_open) return 0;
	memset(&g_trk, 0, sizeof(g_trk));

	char dev[32];
	if (!find_vcd_device(dev, sizeof(dev)))
	{
		printf("DVD_VCD: no readable disc in an optical drive\n");
		return -1;
	}
	int fd = open(dev, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
	{
		printf("DVD_VCD: cannot open %s\n", dev);
		return -1;
	}

	if (ioctl(fd, CDROMREADTOCHDR, &hdr) < 0)
	{
		printf("DVD_VCD: CDROMREADTOCHDR failed\n");
		close(fd);
		return -1;
	}

	// The FIRST DATA track is where the image STARTS -- not necessarily
	// where the ISO9660 filesystem AND the movie both live; see the span
	// walk below for why a following data track is included, not skipped.
	int found = 0;
	for (int t = hdr.cdth_trk0; t <= hdr.cdth_trk1; t++)
	{
		memset(&e, 0, sizeof(e));
		e.cdte_track  = t;
		e.cdte_format = CDROM_LBA;
		if (ioctl(fd, CDROMREADTOCENTRY, &e) < 0)
		{
			printf("DVD_VCD: CDROMREADTOCENTRY(%d) failed\n", t);
			close(fd);
			return -1;
		}
		if (e.cdte_ctrl & CDROM_DATA_TRACK)
		{
			g_trk.num = t;
			g_trk.lba = e.cdte_addr.lba;
			found = 1;
			break;
		}
	}
	if (!found)
	{
		printf("DVD_VCD: no data track\n");
		close(fd);
		return -1;
	}

	// End of the image: NOT simply "the next track's start". Standard VCD/
	// SVCD authoring commonly splits the disc's ISO9660 filesystem into a
	// SHORT first data track and puts the actual MPEG payload in the data
	// track(s) that follow -- one continuous LBA space that a whole-disc
	// .bin rip captures as ONE flat file, with track boundaries surviving
	// only as .cue metadata this project's raw-sector reader never reads.
	// (Measured on a real burned test disc: track 1 = 1275 sectors of
	// filesystem, track 2 = the video, running to the leadout -- mounting
	// track 1 alone served ~17 seconds of directory structure as "the
	// movie" and nothing ever decoded.) So walk forward past every
	// CONSECUTIVE data track and end at the first NON-data track (a
	// trailing CD-DA track on a hybrid disc) or the leadout.
	int end_track = g_trk.num + 1;
	int have_end  = 0;
	for (; end_track <= hdr.cdth_trk1; end_track++)
	{
		memset(&e, 0, sizeof(e));
		e.cdte_track  = end_track;
		e.cdte_format = CDROM_LBA;
		if (ioctl(fd, CDROMREADTOCENTRY, &e) < 0)
		{
			printf("DVD_VCD: CDROMREADTOCENTRY(%d) failed\n", end_track);
			close(fd);
			return -1;
		}
		if (!(e.cdte_ctrl & CDROM_DATA_TRACK)) { have_end = 1; break; }   // a CD-DA track ends the image
	}
	if (!have_end)
	{
		memset(&e, 0, sizeof(e));
		e.cdte_track  = CDROM_LEADOUT;
		e.cdte_format = CDROM_LBA;
		if (ioctl(fd, CDROMREADTOCENTRY, &e) < 0)
		{
			printf("DVD_VCD: CDROMREADTOCENTRY(end) failed\n");
			close(fd);
			return -1;
		}
	}
	g_trk.len = e.cdte_addr.lba - g_trk.lba;
	if (g_trk.len <= 0)
	{
		printf("DVD_VCD: degenerate track length\n");
		close(fd);
		return -1;
	}

	g_scratch = (uint8_t *)malloc((size_t)VCD_BURST_MAX * DVD_VCD_RAW);
	if (!g_scratch)
	{
		printf("DVD_VCD: out of memory\n");
		close(fd);
		return -1;
	}

	g_fd = fd;
	g_open = 1;
	g_readfail = 0;
	snprintf(g_dev, sizeof(g_dev), "%s", dev);

	printf("DVD_VCD: track %d, %d sectors, %llu-byte virtual image\n",
	       g_trk.num, g_trk.len, (unsigned long long)dvd_vcd_image_size(&g_trk));
	dvd_ra_start(vcd_src_read, (uint32_t)((dvd_vcd_image_size(&g_trk) + 2047) / 2048));
	return 0;
}

int dvd_vcd_active(void) { return g_open; }
uint64_t dvd_vcd_size(void) { return g_open ? dvd_vcd_image_size(&g_trk) : 0; }

void dvd_vcd_close(void)
{
	dvd_ra_stop();   // FIRST: the worker owns g_fd and g_scratch, freed below
	if (g_scratch) { free(g_scratch); g_scratch = 0; }
	if (g_fd >= 0) close(g_fd);
	memset(&g_trk, 0, sizeof(g_trk));
	g_fd = -1;
	g_open = 0;
	g_dev[0] = 0;
	g_readfail = 0;
}

// ---------------------------------------------------------------- the read hook

// The read-ahead worker's source (dvd_readahead.h). While the worker runs it is
// the only caller, so g_fd / g_scratch are touched by that one thread.
static int vcd_src_read(void *buf, uint32_t lba, uint32_t cnt)
{
	if (!g_open || !buf || !cnt) return -1;

	uint8_t *out = (uint8_t *)buf;
	uint64_t size = dvd_vcd_image_size(&g_trk);
	uint64_t b0   = (uint64_t)lba * 2048;
	uint64_t b1   = b0 + (uint64_t)cnt * 2048;

	if (b0 >= size) return -1;
	// Past EOF within the last window: serve what exists and zero the tail,
	// so the core still gets a full block.
	if (b1 > size) { memset(out, 0, (size_t)(b1 - b0)); b1 = size; }

	uint64_t b = b0;
	while (b < b1)
	{
		int frame = (int)(b / DVD_VCD_RAW);
		int off   = (int)(b % DVD_VCD_RAW);
		if (frame >= g_trk.len) break;   // size already clamped this away

		int room = g_trk.len - frame;    // never cross into the next track
		uint64_t need = b1 - b + off;    // bytes still wanted, from frame start
		int frames = (int)((need + DVD_VCD_RAW - 1) / DVD_VCD_RAW);
		if (frames > room)          frames = room;
		if (frames > VCD_BURST_MAX) frames = VCD_BURST_MAX;
		if (frames < 1)             frames = 1;

		read_frames(g_trk.lba + frame, frames, g_scratch);

		size_t avail = (size_t)frames * DVD_VCD_RAW - off;
		size_t want  = (size_t)(b1 - b);
		size_t n     = avail < want ? avail : want;
		memcpy(out + (b - b0), g_scratch + off, n);
		b += n;
	}

	return (int)cnt;
}

// Main's read hook (integration steps 46/47): a copy out of the read-ahead ring
// while it runs (step 48 checked the window is there), else the drive, as before.
int dvd_vcd_read(void *buf, uint32_t lba, uint32_t cnt)
{
	if (dvd_ra_active()) return dvd_ra_read(buf, lba, cnt);
	return vcd_src_read(buf, lba, cnt);
}
