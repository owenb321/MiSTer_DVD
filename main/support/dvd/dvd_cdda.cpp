// dvd_cdda.cpp — see dvd_cdda.h.
//
// Self-contained on purpose, in the dvd_detect.cpp style: it takes a bare fd and
// issues its own ioctls. ⛔ It deliberately does NOT reuse stock's
// support/physical_disc/physical_disc.cpp, which would drag cd.h -> libchdr and
// pthreads into an overlay that has stayed dependency-free. Only the SCSI cdb
// shape is borrowed from there, and that is spelled out below.
//
// ⛔ NO PREFETCH RING, NO BACKGROUND THREAD. Stock runs a 10 MB two-lane ring
// with a worker thread because it serves random access. Ours is strictly
// sequential and user_io already gives us an 8-block read-ahead plus a
// speculative next-window prefetch that fires after the current block ships --
// one 16 KB forward read roughly every 93 ms, which is the drive's best case. A
// worker thread would also invert the poll-starvation rule into lock contention
// against the very thread it was meant to protect.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <scsi/sg.h>
#include <linux/cdrom.h>
#include <limits.h>   // INT_MAX -- CDSL_CURRENT expands to it via <linux/cdrom.h>

#include "dvd_cdda.h"
#include "../../user_io.h"

// Bursts are capped at what one 16 KB window can possibly touch: 16384 payload
// bytes span at most ceil(16384/2352)+1 = 8 CD frames. 16 is headroom, not need.
#define CDDA_BURST_MAX   16
#define CDDA_TIMEOUT_MS  3000
// Stock uses a longer timeout for audio specifically -- an audio read makes the
// drive re-seek and re-sync in a way a data read does not.
#define CDDA_AUDIO_MS    900
// CD-DA needs 172 KB/s. An uncapped modern drive spins to 24-48x and screams
// through a music disc; 4x is ~708 KB/s, four times the headroom needed.
#define CDDA_SPEED_NX    4

static dvd_cdda_toc  g_toc;
static int           g_fd   = -1;
static int           g_open = 0;
static char          g_dev[16] = {0};
static uint8_t      *g_scratch = 0;      // CDDA_BURST_MAX frames
static int           g_readfail = 0;     // rate-limited logging

// ---------------------------------------------------------------- pure helpers

uint64_t dvd_cdda_image_size(const dvd_cdda_toc *toc)
{
	if (!toc || toc->nsectors <= 0) return 0;
	return (uint64_t)DVD_CDDA_HDR + (uint64_t)toc->nsectors * DVD_CDDA_RAW;
}

int dvd_cdda_map_sector(const dvd_cdda_toc *toc, int vsec)
{
	if (!toc || vsec < 0 || vsec >= toc->nsectors) return -1;
	// Linear walk: at most 99 tracks, and the caller resolves once per burst,
	// not once per sector. A binary search would be harder to read for no
	// measurable gain.
	for (int i = 0; i < toc->ntracks; i++)
	{
		const dvd_cdda_track *t = &toc->tr[i];
		if (vsec >= t->vsec && vsec < t->vsec + t->len)
			return t->lba + (vsec - t->vsec);
	}
	return -1;
}

static void put_le32(uint8_t *p, uint32_t v)
{ p[0]=v&0xFF; p[1]=(v>>8)&0xFF; p[2]=(v>>16)&0xFF; p[3]=(v>>24)&0xFF; }
static void put_le16(uint8_t *p, uint16_t v)
{ p[0]=v&0xFF; p[1]=(v>>8)&0xFF; }

void dvd_cdda_wav_header(uint8_t *h, uint32_t payload)
{
	memcpy(h, "RIFF", 4);        put_le32(h + 4, 36 + payload);
	memcpy(h + 8, "WAVEfmt ", 8); put_le32(h + 16, 16);
	put_le16(h + 20, 1);          // PCM
	put_le16(h + 22, 2);          // stereo
	put_le32(h + 24, 44100);
	put_le32(h + 28, 44100 * 4);  // byte rate
	put_le16(h + 32, 4);          // block align
	put_le16(h + 34, 16);         // bits
	memcpy(h + 36, "data", 4);   put_le32(h + 40, payload);
}

// ---------------------------------------------------------------- drive access

// READ CD (0xBE). cdb[1]=0x04 declares "expected sector type = CD-DA" and
// cdb[9]=0x10 asks for user data only, so the transfer is exactly 2352 bytes per
// frame of raw little-endian stereo PCM -- already the WAV payload, no byte swap
// (that is a CHD-only concern). Proven on the maintainer's drive by
// main/tools/cdda_smoke.c before any of this was written.
static int scsi_read_cd(int fd, int lba, int count, uint8_t *dst, int timeout_ms)
{
	uint8_t cdb[12] = { 0 }, sense[32] = { 0 };
	struct sg_io_hdr io;

	cdb[0]  = 0xBE;
	cdb[1]  = 0x04;
	cdb[2]  = (lba >> 24) & 0xFF; cdb[3] = (lba >> 16) & 0xFF;
	cdb[4]  = (lba >> 8)  & 0xFF; cdb[5] = lba & 0xFF;
	cdb[6]  = (count >> 16) & 0xFF; cdb[7] = (count >> 8) & 0xFF;
	cdb[8]  = count & 0xFF;
	cdb[9]  = 0x10;
	cdb[10] = 0x00;

	memset(&io, 0, sizeof(io));
	io.interface_id    = 'S';
	io.cmd_len         = sizeof(cdb);
	io.cmdp            = cdb;
	io.dxfer_direction = SG_DXFER_FROM_DEV;
	io.dxfer_len       = count * DVD_CDDA_RAW;
	io.dxferp          = dst;
	io.sbp             = sense;
	io.mx_sb_len       = sizeof(sense);
	io.timeout         = timeout_ms;

	if (ioctl(fd, SG_IO, &io) < 0) return -1;
	if (io.status || io.host_status || io.driver_status) return -2;
	return 0;
}

// Per-sector MSF fallback, used only when a burst fails. A drive that refuses
// 0xBE mid-disc (a scratch, a hybrid session) may still serve this one.
static int ioctl_read_raw(int fd, int lba, uint8_t *dst)
{
	union { struct cdrom_msf msf; uint8_t raw[DVD_CDDA_RAW]; } req;
	int f = lba + 150;   // MSF is offset by the 2-second lead-in
	memset(&req, 0, sizeof(req));
	req.msf.cdmsf_min0   = f / (75 * 60);
	req.msf.cdmsf_sec0   = (f / 75) % 60;
	req.msf.cdmsf_frame0 = f % 75;
	if (ioctl(fd, CDROMREADRAW, &req) < 0) return -1;
	memcpy(dst, req.raw, DVD_CDDA_RAW);
	return 0;
}

// Read `count` CONSECUTIVE disc sectors. Never spans a track boundary -- the
// caller splits there, because consecutive VIRTUAL sectors are not consecutive
// on the disc across a track edge.
#ifdef DVD_CDDA_TEST
// The host test supplies its own, filling each frame from its disc LBA so every
// byte of the virtual image is traceable back to the sector it must have come
// from. This is the ONLY seam in the module: everything else is either pure
// arithmetic or the TOC read.
static int read_frames(int lba, int count, uint8_t *dst);
#else
static int read_frames(int lba, int count, uint8_t *dst)
{
	if (!scsi_read_cd(g_fd, lba, count, dst, CDDA_AUDIO_MS)) return 0;

	// Burst failed: fall back per sector so one bad frame costs one frame of
	// audio, not the whole window.
	for (int i = 0; i < count; i++)
	{
		uint8_t *p = dst + (size_t)i * DVD_CDDA_RAW;
		if (!scsi_read_cd(g_fd, lba + i, 1, p, CDDA_AUDIO_MS)) continue;
		if (!ioctl_read_raw(g_fd, lba + i, p)) continue;
		// Unreadable. A CD has no L-EC over audio, so a real player emits the
		// dropout and moves on; stalling here would starve the core instead.
		memset(p, 0, DVD_CDDA_RAW);
		if (g_readfail < 10)
		{
			g_readfail++;
			printf("DVD_CDDA: sector %d unreadable -- silence\n", lba + i);
		}
	}
	return 0;
}
#endif

// ---------------------------------------------------------------- open / close

// Keep the drive quiet. CD-DA needs 172 KB/s and an uncapped drive is audible
// across a room on a music disc.
static void apply_speed_cap(int fd)
{
	if (ioctl(fd, CDROM_SELECT_SPEED, CDDA_SPEED_NX) < 0)
		printf("DVD_CDDA: speed selection not supported, drive keeps its default\n");
	else
		printf("DVD_CDDA: speed capped at %dx (~%d KB/s, need 172)\n",
		       CDDA_SPEED_NX, CDDA_SPEED_NX * 177);
}

int dvd_cdda_open(int fd, const char *dev)
{
	struct cdrom_tochdr hdr;
	struct cdrom_tocentry e;
	int lba[DVD_CDDA_MAX_TRACKS], is_audio[DVD_CDDA_MAX_TRACKS], num[DVD_CDDA_MAX_TRACKS];
	int n = 0, leadout = 0;

	if (g_open) return 0;
	memset(&g_toc, 0, sizeof(g_toc));

	if (ioctl(fd, CDROMREADTOCHDR, &hdr) < 0)
	{
		printf("DVD_CDDA: CDROMREADTOCHDR failed: %s\n", strerror(errno));
		return -1;
	}

	for (int t = hdr.cdth_trk0; t <= hdr.cdth_trk1 && n < DVD_CDDA_MAX_TRACKS - 1; t++)
	{
		memset(&e, 0, sizeof(e));
		e.cdte_track  = t;
		e.cdte_format = CDROM_LBA;
		if (ioctl(fd, CDROMREADTOCENTRY, &e) < 0)
		{
			printf("DVD_CDDA: CDROMREADTOCENTRY(%d) failed: %s\n", t, strerror(errno));
			return -1;
		}
		num[n]      = t;
		lba[n]      = e.cdte_addr.lba;
		is_audio[n] = !(e.cdte_ctrl & CDROM_DATA_TRACK);
		n++;
	}

	memset(&e, 0, sizeof(e));
	e.cdte_track  = CDROM_LEADOUT;
	e.cdte_format = CDROM_LBA;
	if (ioctl(fd, CDROMREADTOCENTRY, &e) < 0)
	{
		printf("DVD_CDDA: CDROMREADTOCENTRY(LEADOUT) failed: %s\n", strerror(errno));
		return -1;
	}
	leadout = e.cdte_addr.lba;

	// Keep the AUDIO tracks only, concatenated in track order. A data track on an
	// enhanced disc is skipped: its sectors never enter the virtual image, so the
	// audio plays and the data is simply not part of the file.
	for (int i = 0; i < n; i++)
	{
		int end = (i + 1 < n) ? lba[i + 1] : leadout;
		int len = end - lba[i];
		if (!is_audio[i] || len <= 0) continue;

		dvd_cdda_track *t = &g_toc.tr[g_toc.ntracks++];
		t->num  = num[i];
		t->lba  = lba[i];
		t->len  = len;
		t->vsec = g_toc.nsectors;
		g_toc.nsectors += len;
	}

	if (!g_toc.ntracks)
	{
		printf("DVD_CDDA: no audio tracks\n");
		return -1;
	}

	g_scratch = (uint8_t *)malloc((size_t)CDDA_BURST_MAX * DVD_CDDA_RAW);
	if (!g_scratch) { printf("DVD_CDDA: out of memory\n"); return -1; }

	g_fd = fd;
	g_open = 1;
	g_readfail = 0;
	snprintf(g_dev, sizeof(g_dev), "%s", dev ? dev : "");
	apply_speed_cap(fd);

	printf("DVD_CDDA: %d audio track(s), %d sectors, %llu-byte virtual WAV\n",
	       g_toc.ntracks, g_toc.nsectors,
	       (unsigned long long)dvd_cdda_image_size(&g_toc));
	return 0;
}

int dvd_cdda_active(void) { return g_open; }
uint64_t dvd_cdda_size(void) { return g_open ? dvd_cdda_image_size(&g_toc) : 0; }
const dvd_cdda_toc *dvd_cdda_get_toc(void) { return g_open ? &g_toc : 0; }

void dvd_cdda_close(void)
{
	if (g_scratch) { free(g_scratch); g_scratch = 0; }
	memset(&g_toc, 0, sizeof(g_toc));
	g_fd = -1;
	g_open = 0;
	g_dev[0] = 0;
	g_readfail = 0;
}

// ---------------------------------------------------------------- the read hook

int dvd_cdda_read(void *buf, uint32_t lba, uint32_t cnt)
{
	if (!g_open || !buf || !cnt) return -1;

	uint8_t *out = (uint8_t *)buf;
	uint64_t size = dvd_cdda_image_size(&g_toc);
	uint64_t b0   = (uint64_t)lba * 2048;
	uint64_t b1   = b0 + (uint64_t)cnt * 2048;

	if (b0 >= size) return -1;
	// Past EOF within the last window: serve what exists and zero the tail, so
	// the core still gets a full block and buffer_lba stays usable.
	if (b1 > size) { memset(out, 0, (size_t)(b1 - b0)); b1 = size; }

	uint64_t b = b0;

	// The header lives only in block 0.
	if (b < DVD_CDDA_HDR)
	{
		uint8_t hdr[DVD_CDDA_HDR];
		dvd_cdda_wav_header(hdr, (uint32_t)((uint64_t)g_toc.nsectors * DVD_CDDA_RAW));
		size_t n = (size_t)((b1 < DVD_CDDA_HDR ? b1 : DVD_CDDA_HDR) - b);
		memcpy(out, hdr + b, n);
		b += n;
	}

	while (b < b1)
	{
		uint64_t p    = b - DVD_CDDA_HDR;        // payload byte
		int      vsec = (int)(p / DVD_CDDA_RAW);
		int      off  = (int)(p % DVD_CDDA_RAW);

		// How many consecutive virtual sectors can be read in one burst? Stop at
		// the track edge -- virtual sectors are contiguous, disc LBAs are not.
		int disc = dvd_cdda_map_sector(&g_toc, vsec);
		if (disc < 0) break;

		int room = 0;
		for (int i = 0; i < g_toc.ntracks; i++)
		{
			const dvd_cdda_track *t = &g_toc.tr[i];
			if (vsec >= t->vsec && vsec < t->vsec + t->len)
			{ room = t->vsec + t->len - vsec; break; }
		}

		uint64_t need = b1 - b + off;            // bytes still wanted, from sector start
		int frames = (int)((need + DVD_CDDA_RAW - 1) / DVD_CDDA_RAW);
		if (frames > room)            frames = room;
		if (frames > CDDA_BURST_MAX)  frames = CDDA_BURST_MAX;
		if (frames < 1)               frames = 1;

		read_frames(disc, frames, g_scratch);

		size_t avail = (size_t)frames * DVD_CDDA_RAW - off;
		size_t want  = (size_t)(b1 - b);
		size_t n     = avail < want ? avail : want;
		memcpy(out + (b - b0), g_scratch + off, n);
		b += n;
	}

	return (int)cnt;
}

// ---------------------------------------------------------------- toc upload

void dvd_cdda_toc_upload(void)
{
	if (!g_open || !g_toc.ntracks) return;

	// 12-byte header + one 4-byte start per track. Little-endian throughout,
	// matching tools/cdda_toc_ref.py, which is the independent statement of this
	// format -- deliberately not derived from this code or from the RTL.
	uint8_t blob[12 + DVD_CDDA_MAX_TRACKS * 4];
	int n = 0;

	blob[n++] = 'C'; blob[n++] = 'D'; blob[n++] = 'T'; blob[n++] = 'C';
	blob[n++] = 1;                                   // version
	blob[n++] = (uint8_t)g_toc.ntracks;
	blob[n++] = 0; blob[n++] = 0;                    // reserved

	// The image end, so the LAST track has an upper bound. Blocks, rounded up:
	// the final CD frame does not fill its 2048-byte block.
	uint64_t size = dvd_cdda_image_size(&g_toc);
	uint32_t total_blocks = (uint32_t)((size + 2047) / 2048);
	put_le32(blob + n, total_blocks); n += 4;

	for (int i = 0; i < g_toc.ntracks; i++)
	{
		// First BLOCK of this track's first audio byte. Block granularity is
		// ~12 ms of audio -- inaudible on a skip, and it keeps every comparison
		// in the reader's own linear-block units.
		uint64_t byte = (uint64_t)DVD_CDDA_HDR + (uint64_t)g_toc.tr[i].vsec * DVD_CDDA_RAW;
		put_le32(blob + n, (uint32_t)(byte / 2048)); n += 4;
	}

	user_io_set_index(DVD_CDDA_TOC_INDEX);
	user_io_set_download(1);
	user_io_file_tx_data(blob, (uint32_t)n);
	user_io_set_download(0);

	printf("DVD_CDDA: sent %d-track table (%d bytes, %u blocks)\n",
	       g_toc.ntracks, n, total_blocks);
}
