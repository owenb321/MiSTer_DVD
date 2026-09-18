// dvd_vcd_test.cpp — host-side tests for the physical VCD/SVCD source.
//
// dvd_vcd_probe() (the ISO9660 directory walk, same shape as dvd_video_probe())
// and dvd_vcd_open()'s track selection are exercised against a faked drive fd,
// the same technique dvd_phys_test.cpp uses for the optical drive; dvd_vcd_read()'s
// byte assembly is checked against a synthetic disc where every byte is a pure
// function of (disc LBA, offset), so a wrong burst, offset or track-edge overrun
// shows up as a specific wrong byte rather than "the picture is wrong" -- the
// same instrument the parked feature/cdda-physical branch's dvd_cdda_test.cpp
// used for the analogous CD-DA mapping.
//
// Built and run by main/tests/run_tests.sh, which auto-discovers *_test.cpp.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
// These must come in BEFORE the open()/ioctl() macros below -- fcntl.h's
// open() takes a variadic third argument, so a two-argument macro is a hard
// error there, same rule as dvd_phys_test.cpp.
#include <fcntl.h>
#include <sys/ioctl.h>
#include <linux/cdrom.h>
#include <scsi/sg.h>

static int fail = 0;
static void check(const char *what, long long got, long long want)
{
	if (got != want) { printf("  FAIL %-46s got %lld want %lld\n", what, got, want); fail = 1; }
	else               printf("  ok   %-46s %lld\n", what, got);
}

// ---------------------------------------------------------------- fake drive
// One PVD/root sector for dvd_vcd_probe()'s READ(10)s, one TOC for
// dvd_vcd_open()'s CDROMREADTOC* calls. A single fd sees both kinds of
// request, exactly as a real /dev/srN would.

static uint8_t  fake_root[2048];
static int      fake_root_lba = 0;
static uint32_t fake_root_len = 2048;      // bytes; drives dvd_vcd_probe()'s sector-count walk
static uint8_t  fake_root2[2048];          // served at fake_root_lba+1, for the 2-sector arm
static int      fake_root2_valid = 0;
static struct cdrom_tochdr fake_hdr;
static struct { int trk, lba, ctrl; } fake_toc[8];
static int      fake_ntoc = 0;
static int      fake_leadout = 0;

// dvd_vcd.cpp/dvd_vcd_detect.cpp pass real POINTERS as the third ioctl
// argument (sg_io_hdr*, cdrom_tochdr*, cdrom_tocentry*) -- unlike
// dvd_phys_test.cpp's fake, which only ever sees 0. void* accepts all of
// them without a cast at the call site.
#define ioctl(fd, req, arg) test_ioctl(fd, req, arg)

static int test_ioctl(int, unsigned long req, void *arg)
{
	if (req == SG_IO)
	{
		struct sg_io_hdr *io = (struct sg_io_hdr *)arg;
		uint8_t *cdb = (uint8_t *)io->cmdp;
		if (cdb[0] != 0x28) return -1;   // only READ(10) is faked here
		uint32_t lba = ((uint32_t)cdb[2] << 24) | (cdb[3] << 16) | (cdb[4] << 8) | cdb[5];
		uint8_t *dst = (uint8_t *)io->dxferp;
		if (lba == 16)
		{
			memset(dst, 0, 2048);
			memcpy(dst + 1, "CD001", 5);
			dst[158] = fake_root_lba & 0xFF; dst[159] = (fake_root_lba >> 8) & 0xFF;
			dst[160] = (fake_root_lba >> 16) & 0xFF; dst[161] = (fake_root_lba >> 24) & 0xFF;
			dst[166] = fake_root_len & 0xFF; dst[167] = (fake_root_len >> 8) & 0xFF;
			dst[168] = (fake_root_len >> 16) & 0xFF; dst[169] = (fake_root_len >> 24) & 0xFF;
			return 0;
		}
		if ((int)lba == fake_root_lba) { memcpy(dst, fake_root, 2048); return 0; }
		if (fake_root2_valid && (int)lba == fake_root_lba + 1)
		{ memcpy(dst, fake_root2, 2048); return 0; }
		return -1;
	}
	if (req == CDROMREADTOCHDR)
	{
		*(struct cdrom_tochdr *)arg = fake_hdr;
		return 0;
	}
	if (req == CDROMREADTOCENTRY)
	{
		struct cdrom_tocentry *e = (struct cdrom_tocentry *)arg;
		if (e->cdte_track == CDROM_LEADOUT)
		{ e->cdte_addr.lba = fake_leadout; return 0; }
		for (int i = 0; i < fake_ntoc; i++)
			if (fake_toc[i].trk == e->cdte_track)
			{ e->cdte_addr.lba = fake_toc[i].lba; e->cdte_ctrl = fake_toc[i].ctrl; return 0; }
		return -1;
	}
	return -1;
}

#include "dvd_vcd_detect.cpp"

// ------------------------------------------------------------ dvd_vcd_open()/read()
// dvd_vcd_open() finds its own drive and opens its own fd (mirroring
// dvd_css_open()'s shape), so both are faked here: find_vcd_device() is the
// module's declared test seam (like read_frames below), and open() is
// macro-substituted so the fd it gets back is the same token test_ioctl()
// already answers for.
static int fake_drive_present = 1;
static int find_vcd_device(char *out, int outsz)
{
	if (!fake_drive_present) return 0;
	snprintf(out, outsz, "/dev/sr0");
	return 1;
}
#define open(path, flags) test_open(path, flags)
static int test_open(const char *, int) { return 7; }

// A synthetic disc: every byte is a pure function of (disc LBA, offset), so
// any byte of the virtual image can be checked against the sector it MUST
// have come from.
#include "dvd_vcd.h"
static uint8_t disc_byte(int lba, int off)
{
	return (uint8_t)((lba * 7u + off * 31u + (off >> 8) * 13u) & 0xFF);
}
static int g_frames_read = 0, g_max_burst = 0;
static int read_frames(int lba, int count, uint8_t *dst)
{
	g_frames_read += count;
	if (count > g_max_burst) g_max_burst = count;
	for (int i = 0; i < count; i++)
		for (int o = 0; o < DVD_VCD_RAW; o++)
			dst[(size_t)i * DVD_VCD_RAW + o] = disc_byte(lba + i, o);
	return 0;
}
#define DVD_VCD_TEST 1
#include "dvd_vcd.cpp"

// ---------------------------------------------------------------- ISO9660 helpers

// Write one root-directory record for `name` (a movie-data marker directory)
// into fake_root at `off`, returning the next free offset. Mirrors the real
// on-disc record shape dvd_vcd_probe() walks: length byte, flags at +25
// (bit 1 = directory), name length at +32, name at +33.
static uint32_t put_dir(uint32_t off, const char *name)
{
	uint8_t nlen = (uint8_t)strlen(name);
	uint8_t rlen = 33 + nlen + (nlen % 2 == 0 ? 1 : 0);   // padded to even, like real ISO9660
	fake_root[off] = rlen;
	fake_root[off + 25] = 0x02;   // directory flag
	fake_root[off + 32] = nlen;
	memcpy(fake_root + off + 33, name, nlen);
	return off + rlen;
}

int main(void)
{
	// ============================================================ dvd_vcd_probe
	printf("=== dvd_vcd_probe ===\n");

	memset(fake_root, 0, sizeof(fake_root));
	fake_root_lba = 100;
	uint32_t p = 0;
	p = put_dir(p, "VCD");
	p = put_dir(p, "MPEGAV");
	p = put_dir(p, "SEGMENT");
	check("[1] VCD 2.0 root (MPEGAV present)", dvd_vcd_probe(7), 1);

	memset(fake_root, 0, sizeof(fake_root));
	p = 0;
	p = put_dir(p, "SVCD");
	p = put_dir(p, "MPEG2");
	p = put_dir(p, "EXT");
	check("[2] SVCD root (MPEG2 present)", dvd_vcd_probe(7), 1);

	memset(fake_root, 0, sizeof(fake_root));
	p = 0;
	p = put_dir(p, "VIDEO_TS");   // a DVD-Video disc, not VCD/SVCD
	check("[3] DVD-Video root has neither marker", dvd_vcd_probe(7), 0);

	memset(fake_root, 0, sizeof(fake_root));
	p = 0;
	p = put_dir(p, "VCD");   // metadata only, no MPEGAV -- e.g. a truncated rip
	check("[4] VCD/ alone (no MPEGAV) is not enough", dvd_vcd_probe(7), 0);

	// Not ISO9660 at all: no CD001 signature.
	memset(fake_root, 0, sizeof(fake_root));
	check("[5] no CD001 signature", dvd_vcd_probe(99), 0);

	// The marker sits in the SECOND root sector -- proves the multi-sector
	// walk (root_len > one sector -> nsec > 1), not just a single lucky read.
	memset(fake_root, 0, sizeof(fake_root));   // sector 0: unrelated entries only
	p = 0;
	p = put_dir(p, "VCD");
	p = put_dir(p, "SEGMENT");
	memset(fake_root2, 0, sizeof(fake_root2));
	put_dir(0, "MPEGAV");                       // sector 1: the marker
	fake_root_lba = 100;
	fake_root_len = 2048 + 1;                   // one byte into a second sector
	fake_root2_valid = 1;
	check("[6] marker found in the SECOND root sector", dvd_vcd_probe(7), 1);
	fake_root2_valid = 0;
	fake_root_len = 2048;                       // restore for the arms below

	// ============================================================ dvd_vcd_open
	printf("=== dvd_vcd_open: track selection ===\n");

	// [7] a single data track, the ordinary case.
	memset(&fake_hdr, 0, sizeof(fake_hdr));
	fake_hdr.cdth_trk0 = 1; fake_hdr.cdth_trk1 = 1;
	fake_ntoc = 0;
	fake_toc[fake_ntoc++] = { 1, 0, CDROM_DATA_TRACK };
	fake_leadout = 34500;   // ~7 minutes, a plausible VCD length
	check("[7] single-track open succeeds",  dvd_vcd_open(), 0);
	check("[7a] picks track 1",              g_trk.num, 1);
	check("[7b] starts at LBA 0",            g_trk.lba, 0);
	check("[7c] length runs to the leadout", g_trk.len, fake_leadout);
	check("[7d] dvd_vcd_active()",           dvd_vcd_active(), 1);
	check("[7e] size = len*2352",            (long long)dvd_vcd_size(),
	      (long long)fake_leadout * DVD_VCD_RAW);
	dvd_vcd_close();
	check("[7f] closed",                     dvd_vcd_active(), 0);

	// [8] data track first, CD-DA audio tracks after: length must stop at the
	// NEXT track, never run into the audio.
	memset(&fake_hdr, 0, sizeof(fake_hdr));
	fake_hdr.cdth_trk0 = 1; fake_hdr.cdth_trk1 = 3;
	fake_ntoc = 0;
	fake_toc[fake_ntoc++] = { 1, 0,     CDROM_DATA_TRACK };
	fake_toc[fake_ntoc++] = { 2, 20000, 0 };            // CD-DA
	fake_toc[fake_ntoc++] = { 3, 40000, 0 };            // CD-DA
	fake_leadout = 60000;
	check("[8] hybrid disc open succeeds",  dvd_vcd_open(), 0);
	check("[8a] picks the data track",      g_trk.num, 1);
	check("[8b] stops at the NEXT track",   g_trk.len, 20000);
	dvd_vcd_close();

	// [9] the data track is NOT track 1 -- the first DATA track, wherever it
	// sits, is what gets played; its length still stops at the FOLLOWING
	// track regardless of that track's own type.
	memset(&fake_hdr, 0, sizeof(fake_hdr));
	fake_hdr.cdth_trk0 = 1; fake_hdr.cdth_trk1 = 3;
	fake_ntoc = 0;
	fake_toc[fake_ntoc++] = { 1, 0,     0 };                 // CD-DA (ignored)
	fake_toc[fake_ntoc++] = { 2, 5000,  CDROM_DATA_TRACK };  // the one played
	fake_toc[fake_ntoc++] = { 3, 45000, 0 };
	fake_leadout = 60000;
	check("[9] finds a non-first data track", dvd_vcd_open(), 0);
	check("[9a] picks track 2",               g_trk.num, 2);
	check("[9b] length to track 3, not track 1's span", g_trk.len, 40000);
	dvd_vcd_close();

	// [10] the data track is the LAST track -- length runs to the leadout.
	memset(&fake_hdr, 0, sizeof(fake_hdr));
	fake_hdr.cdth_trk0 = 1; fake_hdr.cdth_trk1 = 2;
	fake_ntoc = 0;
	fake_toc[fake_ntoc++] = { 1, 0,     0 };
	fake_toc[fake_ntoc++] = { 2, 5000,  CDROM_DATA_TRACK };
	fake_leadout = 50000;
	check("[10] last-track open succeeds", dvd_vcd_open(), 0);
	check("[10a] picks track 2",           g_trk.num, 2);
	check("[10b] length to the leadout",   g_trk.len, 45000);
	dvd_vcd_close();

	// [11] no data track at all (a plain audio CD reaching this far would be
	// a dvd_phys.cpp dispatch bug, but this module must refuse it too).
	memset(&fake_hdr, 0, sizeof(fake_hdr));
	fake_hdr.cdth_trk0 = 1; fake_hdr.cdth_trk1 = 2;
	fake_ntoc = 0;
	fake_toc[fake_ntoc++] = { 1, 0,     0 };
	fake_toc[fake_ntoc++] = { 2, 20000, 0 };
	fake_leadout = 50000;
	check("[11] no data track is refused", dvd_vcd_open(), -1);
	check("[11a] not left open",           dvd_vcd_active(), 0);

	// ============================================================ dvd_vcd_read
	printf("=== dvd_vcd_read: byte assembly against a synthetic disc ===\n");
	{
		g_trk.num = 1; g_trk.lba = 200; g_trk.len = 20000;   // not at LBA 0 --
		                                                       // proves the offset
		                                                       // is genuinely used
		g_open = 1;
		g_scratch = (uint8_t *)malloc((size_t)16 /* VCD_BURST_MAX mirror */ * DVD_VCD_RAW);

		uint64_t size = dvd_vcd_image_size(&g_trk);

		int bad = 0, checked = 0;
		uint32_t starts[] = { 0, 1, 8, 16,
		                      (uint32_t)(size / 2048) - 8 };
		uint8_t win[8 * 2048];

		for (unsigned k = 0; k < sizeof(starts) / sizeof(starts[0]); k++)
		{
			uint32_t lba = starts[k];
			memset(win, 0xAA, sizeof(win));
			if (dvd_vcd_read(win, lba, 8) <= 0) { bad++; continue; }

			for (int i = 0; i < 8 * 2048; i++)
			{
				uint64_t b = (uint64_t)lba * 2048 + i;
				if (b >= size) break;
				int frame = (int)(b / DVD_VCD_RAW), off = (int)(b % DVD_VCD_RAW);
				uint8_t want = disc_byte(g_trk.lba + frame, off);
				checked++;
				if (win[i] != want)
				{
					if (bad < 5)
						printf("  ..byte %llu: got %02x want %02x\n",
						       (unsigned long long)b, win[i], want);
					bad++;
				}
			}
		}
		check("[12a] bytes checked (test is not vacuous)", checked > 50000, 1);
		check("[12b] every byte matches its source sector", bad, 0);

		// [12c] the cap itself, under a window big enough to need MORE than 16
		// frames if it were uncapped (40 blocks = 81920 B > 16*2352 = 37632 B).
		// g_scratch here is deliberately oversized (not the real VCD_BURST_MAX
		// allocation) so an uncapped mutant overruns nothing in THIS process --
		// the assertion below is what catches the missing clamp, not a crash.
		{
			free(g_scratch);
			g_scratch = (uint8_t *)malloc(64 * DVD_VCD_RAW);
			g_max_burst = 0;
			uint8_t bigwin[40 * 2048];
			int r = dvd_vcd_read(bigwin, 0, 40);
			check("[12g] a large request still succeeds", r > 0, 1);
			check("[12c] bursts never exceed the cap", g_max_burst <= 16, 1);
			free(g_scratch);
			g_scratch = (uint8_t *)malloc((size_t)16 * DVD_VCD_RAW);   // restore for below
		}

		// Past EOF must be refused, not served as garbage.
		check("[12d] past EOF is refused", dvd_vcd_read(win, (uint32_t)(size / 2048) + 8, 8), -1);

		// A window straddling the end must zero-fill the tail rather than
		// leave stale/garbage bytes past the last real byte.
		memset(win, 0xAA, sizeof(win));
		uint32_t last_lba = (uint32_t)((size - 1) / 2048);
		int r = dvd_vcd_read(win, last_lba, 8);
		check("[12e] a straddling-EOF read is still served", r > 0, 1);
		uint64_t last_b0 = (uint64_t)last_lba * 2048;
		uint64_t tail_off = size - last_b0;
		check("[12f] the byte just past EOF is zero-filled",
		      win[tail_off] == 0 ? 1 : 0, 1);

		free(g_scratch); g_scratch = 0; g_open = 0;
	}

	// [13] a track shorter than one block, and an empty (zero-length) track.
	{
		dvd_vcd_track s; s.num = 1; s.lba = 500; s.len = 1;
		check("[13a] 1-sector image size", (long long)dvd_vcd_image_size(&s),
		      (long long)DVD_VCD_RAW);
		dvd_vcd_track z; z.num = 0; z.lba = 0; z.len = 0;
		check("[13b] zero-length track has no size", (long long)dvd_vcd_image_size(&z), 0);
	}

	printf("\n=== dvd_vcd tests: %d error(s) ===\n", fail);
	if (fail) { printf("FAILED\n"); return 1; }
	printf("PASS\n");
	return 0;
}
