// dvd_css.cpp — see dvd_css.h.
//
// libdvdcss is dlopen'd at runtime (never linked). The only libdvdcss surface we
// use is its published API, declared here so the build needs no libdvdcss headers.

#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <dlfcn.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <dirent.h>
#include <scsi/sg.h>
#include <linux/cdrom.h>
#include <linux/fs.h>

#include "dvd_css.h"
#include "dvd_launch.h"
#include "../../menu.h"      // ProgressMessage() — on-screen feedback during key crack
#include "../../file_io.h"   // getFullPath() — resolve MiSTer's storage-relative mount path

// Status logging: to stdout and to /tmp/dvdcss.log (the latter so the reason for
// a failed mount is visible over SSH, where the core's stdout is not).
#define CSS_LOG_PATH "/tmp/dvdcss.log"
static void css_log(const char *fmt, ...)
{
	char buf[256];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	printf("CSS: %s\n", buf);
	FILE *f = fopen(CSS_LOG_PATH, "a");
	if (f) { fprintf(f, "%s\n", buf); fclose(f); }
}

// --- libdvdcss API (from dvdcss.h; reproduced so we need no external headers) ---
typedef struct dvdcss_s *dvdcss_t;
#define DVDCSS_NOFLAGS       0
#define DVDCSS_READ_DECRYPT (1 << 0)
#define DVDCSS_SEEK_MPEG    (1 << 0)
#define DVDCSS_SEEK_KEY     (1 << 1)

typedef dvdcss_t(*fn_open_t)(const char *);
typedef int (*fn_close_t)(dvdcss_t);
typedef int (*fn_seek_t)(dvdcss_t, int, int);
typedef int (*fn_read_t)(dvdcss_t, void *, int, int);
typedef char *(*fn_error_t)(dvdcss_t);
typedef int (*fn_scram_t)(dvdcss_t);

static void *css_lib = NULL;
static fn_open_t  p_open  = NULL;
static fn_close_t p_close = NULL;
static fn_seek_t  p_seek  = NULL;
static fn_read_t  p_read  = NULL;
static fn_error_t p_error = NULL;
static fn_scram_t p_scram = NULL;   // dvdcss_is_scrambled (optional; absent on old libs)

static dvdcss_t css = NULL;
static uint64_t css_size = 0;   // bytes
static int css_pos = -1;        // last block position, to avoid redundant seeks
static int cur_vob = -1;        // VOB index whose title key is currently selected
static int raw_fd = -1;         // raw drive fd when libdvdcss is absent (no decrypt)
static int region_set = 1;      // 0 if the drive has no CSS region set (keys will crack)
static time_t warn_until = 0;   // deadline for re-asserting the "install libdvdcss" popup

// Candidate locations for the user-supplied library. The install script drops it
// at the first path; the sonames cover a lib already on the default search path.
static const char *css_lib_names[] =
{
	"/media/fat/dvdcss/libdvdcss.so.2",
	"/media/fat/linux/libdvdcss.so.2",
	"libdvdcss.so.2",
	"libdvdcss.so",
	NULL
};

static int load_library(void)
{
	if (css_lib) return 1;

	for (int i = 0; css_lib_names[i]; i++)
	{
		css_lib = dlopen(css_lib_names[i], RTLD_NOW | RTLD_LOCAL);
		if (css_lib) break;
	}
	if (!css_lib)
	{
		css_log("libdvdcss not found — run Scripts/install_dvdcss to play encrypted discs");
		return 0;
	}

	p_open  = (fn_open_t)  dlsym(css_lib, "dvdcss_open");
	p_close = (fn_close_t) dlsym(css_lib, "dvdcss_close");
	p_seek  = (fn_seek_t)  dlsym(css_lib, "dvdcss_seek");
	p_read  = (fn_read_t)  dlsym(css_lib, "dvdcss_read");
	p_error = (fn_error_t) dlsym(css_lib, "dvdcss_error");
	p_scram = (fn_scram_t) dlsym(css_lib, "dvdcss_is_scrambled");

	if (!p_open || !p_close || !p_seek || !p_read)
	{
		css_log("libdvdcss is missing required symbols");
		dlclose(css_lib);
		css_lib = NULL;
		return 0;
	}
	return 1;
}

// Find the first /dev/srN that currently holds a disc. Returns 1 and fills `out`
// on success. Mirrors the drive scan in physical_disc.cpp, but opens nothing that
// would collide with libdvdcss (it needs its own handle for the CSS ioctls).
// The disc may report CDS_DRIVE_NOT_READY while it spins up, so a not-ready drive
// with media is accepted as a fallback and left for dvdcss_open to spin up.
static int find_dvd_device(char *out, int outsz)
{
	char fallback[32] = "";
	uint64_t fb_size = 0;

	for (int i = 0; i < 8; i++)
	{
		char path[32];
		snprintf(path, sizeof(path), "/dev/sr%d", i);
		int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0) continue;

		int status = ioctl(fd, CDROM_DRIVE_STATUS, CDSL_CURRENT);
		uint64_t bytes = 0;
		if (ioctl(fd, BLKGETSIZE64, &bytes) < 0) bytes = 0;
		close(fd);

		if (status == CDS_DISC_OK)
		{
			css_size = bytes;
			snprintf(out, outsz, "%s", path);
			return 1;
		}
		if (status == CDS_DRIVE_NOT_READY && fallback[0] == '\0')
		{
			snprintf(fallback, sizeof(fallback), "%s", path);
			fb_size = bytes;
		}
	}

	if (fallback[0])   // disc present but still spinning up -> let dvdcss_open wait
	{
		css_size = fb_size;
		snprintf(out, outsz, "%s", fallback);
		return 1;
	}
	return 0;
}

static inline uint32_t rd_le32(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

// Raw READ(10) of `count` 2048-byte sectors at `lba` — used only in the no-
// libdvdcss fallback, which plays unencrypted DVDs (CSS discs come back
// scrambled and the core flags CSS ENCRYPTED). Returns sectors read or -1.
static int raw_read10(int fd, uint32_t lba, void *buf, int count)
{
	uint8_t cdb[10] = { 0x28, 0,
		(uint8_t)(lba >> 24), (uint8_t)(lba >> 16), (uint8_t)(lba >> 8), (uint8_t)lba,
		0, (uint8_t)(count >> 8), (uint8_t)count, 0 };
	uint8_t sense[32];
	struct sg_io_hdr io;
	memset(&io, 0, sizeof(io));
	io.interface_id = 'S';
	io.dxfer_direction = SG_DXFER_FROM_DEV;
	io.cmd_len = sizeof(cdb);
	io.cmdp = cdb;
	io.dxfer_len = (unsigned)count * 2048;
	io.dxferp = buf;
	io.sbp = sense;
	io.mx_sb_len = sizeof(sense);
	io.timeout = 5000;
	if (ioctl(fd, SG_IO, &io) < 0) return -1;
	if (io.status || io.host_status) return -1;
	return count;
}

// Can the drive answer the CSS key exchange? RPC-II drives refuse the title-key
// ioctl (ReadTitleKey) unless a region matching the disc is set, which forces
// libdvdcss into the slow, sometimes-failing per-title crack. Read the RPC state
// via SG_IO REPORT KEY (format 0x08): region_mask 0xff means no region is set,
// and rpc_scheme (byte 6) 0 is an RPC-1 drive, which enforces no region AT ALL —
// it hands keys over whatever the disc's region, so its empty mask is not the
// problem an RPC-II drive's empty mask is. Treating the two alike labelled a
// region-free drive "No drive region: cracking", which is the opposite of true.
static int drive_region_set(const char *dev)
{
	int fd = open(dev, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0) return 1;   // can't check -> assume set (don't nag)

	uint8_t cdb[12] = { 0xA4, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0x08, 0 };   // REPORT KEY, RPC state
	uint8_t buf[8] = { 0 }, sense[32];
	struct sg_io_hdr io;
	memset(&io, 0, sizeof(io));
	io.interface_id = 'S';
	io.dxfer_direction = SG_DXFER_FROM_DEV;
	io.cmd_len = sizeof(cdb);
	io.cmdp = cdb;
	io.dxfer_len = sizeof(buf);
	io.dxferp = buf;
	io.sbp = sense;
	io.mx_sb_len = sizeof(sense);
	io.timeout = 5000;

	int set = 1;
	if (ioctl(fd, SG_IO, &io) == 0 && io.status == 0)
		set = (buf[5] != 0xff)    // region_mask == 0xff -> no region set ...
		   || (buf[6] == 0);      // ... but RPC-1 needs none: nothing to set
	close(fd);
	return set;
}

// Is the disc CSS/CPPM-protected? READ DVD STRUCTURE (0xAD), format 0x01
// (copyright info): response byte 4 (CPST) is 0 for none, non-zero for CSS.
// Asked WITHOUT authentication (a status read), so it works with no libdvdcss —
// which is how we can warn instead of parking on a black screen: many drives
// refuse a plain READ(10) of the scrambled VOB area, so the core would starve
// with no scrambled PES ever reaching its CSS ENCRYPTED detector.
static int disc_is_encrypted(const char *dev)
{
	int fd = open(dev, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0) return 0;

	uint8_t cdb[12] = { 0xAD, 0, 0, 0, 0, 0, 0, 0x01, 0, 8, 0, 0 };   // READ DVD STRUCTURE, copyright
	uint8_t buf[8] = { 0 }, sense[32];
	struct sg_io_hdr io;
	memset(&io, 0, sizeof(io));
	io.interface_id = 'S';
	io.dxfer_direction = SG_DXFER_FROM_DEV;
	io.cmd_len = sizeof(cdb);
	io.cmdp = cdb;
	io.dxfer_len = sizeof(buf);
	io.dxferp = buf;
	io.sbp = sense;
	io.mx_sb_len = sizeof(sense);
	io.timeout = 5000;

	int css = (ioctl(fd, SG_IO, &io) == 0 && io.status == 0) ? (buf[4] != 0) : 0;
	close(fd);
	return css;   // caller logs the outcome (the encrypted-without-libdvdcss case)
}

// Read `count` raw (undecrypted) 2048-byte sectors at `lba` — for the unscrambled
// ISO9660 metadata used to enumerate VOB files. Returns sectors read or -1.
static int css_raw_read(uint32_t lba, void *buf, int count)
{
	if (p_seek(css, (int)lba, DVDCSS_NOFLAGS) < 0) return -1;
	return p_read(css, buf, count, DVDCSS_NOFLAGS);
}

static int name_eq(const char *nm, int nlen, const char *want)
{
	int wl = (int)strlen(want);
	if (nlen != wl) return 0;
	for (int i = 0; i < wl; i++)
		if ((nm[i] | 32) != (want[i] | 32)) return 0;
	return 1;
}

static int name_has_vob(const char *nm, int nlen)
{
	for (int i = 0; i + 4 <= nlen; i++)
		if (nm[i] == '.' && (nm[i + 1] | 32) == 'v' && (nm[i + 2] | 32) == 'o' && (nm[i + 3] | 32) == 'b')
			return 1;
	return 0;
}

// Find a directory child by name (want_dir=1 for a subdirectory).
static int iso_find(uint32_t dir_lba, uint32_t dir_len, const char *name, int want_dir,
                    uint32_t *out_lba, uint32_t *out_len)
{
	uint8_t sec[2048];
	uint32_t nsec = (dir_len + 2047) / 2048;
	for (uint32_t s = 0; s < nsec; s++)
	{
		if (css_raw_read(dir_lba + s, sec, 1) < 1) return 0;
		uint32_t off = 0;
		while (off + 33 < 2048)
		{
			uint8_t rlen = sec[off];
			if (rlen == 0) break;               // rest of the sector is padding
			uint8_t flags = sec[off + 25];
			uint8_t nlen = sec[off + 32];
			const char *nm = (const char *)(sec + off + 33);
			int is_dir = (flags & 0x02) != 0;
			if ((want_dir ? is_dir : !is_dir) && name_eq(nm, nlen, name))
			{
				*out_lba = rd_le32(sec + off + 2);
				*out_len = rd_le32(sec + off + 10);
				return 1;
			}
			off += rlen;
		}
	}
	return 0;
}

// Every *.VOB file's extent [start, start+nsec), discovered at mount. Used to
// (a) pre-crack each title key at its VOB start, and (b) decide per read whether
// to decrypt: VOB sectors get SEEK_KEY(lba)+DECRYPT (the SEEK_KEY is a fast cached
// lookup after the pre-crack); filesystem/IFO sectors are read raw (NOFLAGS) so
// dvdcss can't corrupt them with a wrong current title key.
#define MAX_VOBS 64
static struct { uint32_t start, nsec; } g_vobs[MAX_VOBS];
static int g_nvobs = 0;

// Collect every *.VOB file's extent (start LBA + length in sectors).
static void collect_vobs(uint32_t dir_lba, uint32_t dir_len)
{
	uint8_t sec[2048];
	uint32_t nsec = (dir_len + 2047) / 2048;
	for (uint32_t s = 0; s < nsec; s++)
	{
		if (css_raw_read(dir_lba + s, sec, 1) < 1) break;
		uint32_t off = 0;
		while (off + 33 < 2048)
		{
			uint8_t rlen = sec[off];
			if (rlen == 0) break;
			uint8_t flags = sec[off + 25];
			uint8_t nlen = sec[off + 32];
			const char *nm = (const char *)(sec + off + 33);
			if (!(flags & 0x02) && name_has_vob(nm, nlen) && g_nvobs < MAX_VOBS)
			{
				g_vobs[g_nvobs].start = rd_le32(sec + off + 2);
				g_vobs[g_nvobs].nsec = (rd_le32(sec + off + 10) + 2047) / 2048;
				g_nvobs++;
			}
			off += rlen;
		}
	}
}

// Index of the VOB extent containing `lba` (a sector that may be scrambled), or
// -1 for a filesystem/IFO sector (never scrambled -> must be read raw).
static int vob_index(uint32_t lba)
{
	for (int i = 0; i < g_nvobs; i++)
		if (lba >= g_vobs[i].start && lba < g_vobs[i].start + g_vobs[i].nsec) return i;
	return -1;
}

// Enumerate every VOB extent from ISO9660 (root -> VIDEO_TS). Raw reads only, no keys.
// Returns 1 if at least one VOB was found.
static int enumerate_vobs(void)
{
	g_nvobs = 0;
	uint8_t sec[2048];
	if (css_raw_read(16, sec, 1) < 1) { css_log("vobs: PVD read failed"); return 0; }
	if (memcmp(sec + 1, "CD001", 5) != 0) { css_log("vobs: not ISO9660"); return 0; }

	uint32_t root_lba = rd_le32(sec + 156 + 2);
	uint32_t root_len = rd_le32(sec + 156 + 10);
	uint32_t vts_lba = 0, vts_len = 0;
	if (!iso_find(root_lba, root_len, "VIDEO_TS", 1, &vts_lba, &vts_len))
	{
		css_log("vobs: VIDEO_TS dir not found");
		return 0;
	}
	collect_vobs(vts_lba, vts_len);
	return g_nvobs > 0;
}

// ---------------------------------------------------------------------------
// libdvdcss title-key cache
// ---------------------------------------------------------------------------
// A key that had to be CRACKED costs minutes; read back from the cache it costs
// nothing, so this is the difference between "a first play is slow" and "every
// play is slow". libdvdcss does the caching itself -- all we owe it is a writable
// directory in DVDCSS_CACHE before dvdcss_open().
//
// ⚠ We owed it more than the old two lines gave. mkdir() creates ONE level, and
// /media/fat/dvdcss only exists if libdvdcss was installed by our own Scripts
// entry -- css_lib_names also finds it in /media/fat/linux or on the system path,
// and then the parent is missing, mkdir fails ENOENT, and the return was not
// checked. libdvdcss then does its own single-level mkdir on the same path, fails
// the same way, and disables the cache SILENTLY. Every play re-cracked.
//
// So: create both levels, prove the directory is writable, and say so in the log
// either way. `DVDCSS_CACHE` is unset rather than left pointing at somewhere
// unusable, so the behaviour is at least defined.
#define CSS_CACHE_ROOT "/media/fat/dvdcss"
#define CSS_CACHE_DIR  CSS_CACHE_ROOT "/cache"

// How many per-disc entries libdvdcss has stored. Logged either side of key
// extraction: growing means the cache took, and a non-zero count at open time on a
// disc that is still slow means it is being written but not read back.
static int cache_entries(void)
{
	DIR *d = opendir(CSS_CACHE_DIR);
	if (!d) return -1;
	int n = 0;
	struct dirent *e;
	while ((e = readdir(d)) != NULL)
		if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) n++;
	closedir(d);
	return n;
}

static void setup_cache(void)
{
	if (mkdir(CSS_CACHE_ROOT, 0755) && errno != EEXIST)
		css_log("cache: cannot create %s (%s)", CSS_CACHE_ROOT, strerror(errno));

	if (mkdir(CSS_CACHE_DIR, 0755) && errno != EEXIST)
	{
		css_log("cache: cannot create %s (%s) -- keys will be re-extracted every play",
		        CSS_CACHE_DIR, strerror(errno));
		unsetenv("DVDCSS_CACHE");
		return;
	}

	// Writable, not merely present: /media/fat is removable and can be mounted
	// read-only after an unclean shutdown, which looks identical from mkdir alone.
	char probe[sizeof(CSS_CACHE_DIR) + 16];
	snprintf(probe, sizeof(probe), "%s/.wtest", CSS_CACHE_DIR);
	int fd = open(probe, O_CREAT | O_WRONLY | O_TRUNC, 0644);
	if (fd < 0)
	{
		css_log("cache: %s is not writable (%s) -- keys will be re-extracted every play",
		        CSS_CACHE_DIR, strerror(errno));
		unsetenv("DVDCSS_CACHE");
		return;
	}
	close(fd);
	unlink(probe);

	setenv("DVDCSS_CACHE", CSS_CACHE_DIR, 1);
	css_log("cache: %s ready, %d entr%s", CSS_CACHE_DIR,
	        cache_entries(), cache_entries() == 1 ? "y" : "ies");
}

// Pre-crack each VOB's title key at its start sector (fast cached lookups thereafter).
// With a drive region set this is instant (ioctl); with none — or an image file with no
// drive at all — it is a slow crack, so show a bar (it blocks the main loop) with the
// caller's `text`. The message never changes what libdvdcss does.
static void crack_title_keys(const char *text)
{
	const char *title = "DVD";   // sidebar ~9 chars; main line capped at 27 (ProgressMessage)
	ProgressMessage();   // reset so the first update renders
	int keyed = 0;
	for (int i = 0; i < g_nvobs; i++)
	{
		ProgressMessage(title, text, i, g_nvobs);
		if (p_seek(css, (int)g_vobs[i].start, DVDCSS_SEEK_KEY) >= 0) keyed++;
	}
	ProgressMessage();   // clear
	css_log("%d VOBs, %d title keys (region %s), cache now %d entr%s",
	        g_nvobs, keyed, region_set ? "set" : "NOT set",
	        cache_entries(), cache_entries() == 1 ? "y" : "ies");
	css_pos = -1;
}

// Are the actual VOB SECTORS CSS-scrambled? This is what decides whether to decrypt —
// distinct from dvdcss_is_scrambled(), which only reports the disc's CSS *structure* and
// so reads 1 for a DECRYPTED rip of a CSS disc too. We read VOB payload sectors raw and
// look at the CSS scrambling_control bits in the (clear) PES header. The NAV pack (VOBU
// sector 0) is never scrambled, so we sample later sectors; and a single sector's first
// PES may be unscrambled on an encrypted disc, so we must scan and only conclude
// "plaintext" after finding NONE scrambled.
//   returns 1 = a scrambled sector was found (encrypted; must decrypt)
//           0 = valid PES seen, none scrambled (plaintext — decrypted rip or never-CSS)
//          -1 = inconclusive (no parseable PES sampled) -> caller falls back to the lib flag
static int image_is_scrambled(void)
{
	int saw_pes = 0;
	for (int i = 0; i < g_nvobs; i++)
	{
		for (uint32_t s = 1; s < g_vobs[i].nsec && s <= 8; s++)
		{
			uint8_t sec[2048];
			if (css_raw_read(g_vobs[i].start + s, sec, 1) < 1) break;
			if (!(sec[0] == 0 && sec[1] == 0 && sec[2] == 1 && sec[3] == 0xBA)) continue;
			int po = 14 + (sec[13] & 0x07);              // pack header + stuffing -> first PES
			if (po + 6 >= 2048) continue;
			if (!(sec[po] == 0 && sec[po + 1] == 0 && sec[po + 2] == 1)) continue;
			uint8_t sid = sec[po + 3];
			if (sid == 0xBD || (sid >= 0xC0 && sid <= 0xEF))   // stream carries a PES ext header
			{
				uint8_t flags = sec[po + 6];
				if ((flags & 0xC0) == 0x80)                    // valid '10' PES marker
				{
					saw_pes = 1;
					if ((flags & 0x30) != 0) return 1;         // PES_scrambling_control set
				}
			}
		}
	}
	return saw_pes ? 0 : -1;
}

// Physical-drive path: enumerate + crack. dvdcss_is_scrambled is reliable here (drive
// ioctls are available); assume scrambled if the lib is too old to tell.
static void build_vob_list(void)
{
	if (!enumerate_vobs()) return;
	// The region matters only for a scrambled disc — an unencrypted DVD needs no key,
	// so don't warn about cracking there. dvdcss_is_scrambled is optional; assume
	// scrambled if the lib is too old to tell (rather than hide a real warning).
	int scrambled = p_scram ? (p_scram(css) != 0) : 1;
	crack_title_keys((!region_set && scrambled) ? "No drive region: cracking" : "Preparing disc");
}

int dvd_css_open(void)
{
	if (css || raw_fd >= 0) return 1;

	char dev[32];
	if (!find_dvd_device(dev, sizeof(dev)))
	{
		css_log("no readable disc in an optical drive");
		return 0;
	}

	region_set = drive_region_set(dev);
	if (!region_set)
		css_log("drive is RPC-II with NO region set — title keys must be cracked (slow); see README");

	if (load_library())
	{
		// Use libdvdcss's default method: fetch each title key from the DRIVE via
		// the CSS key ioctls (fast — a REPORT KEY per title) when the drive
		// supports them, and fall back to CRACKING the key from the data only when
		// it doesn't (the crack can be slow, minutes on some discs). Either way the
		// key is fetched at the VOB START (build_vob_list below), where both paths
		// are reliable. (We used to force DVDCSS_METHOD=title, i.e. always crack;
		// that predates seeking at the VOB start and was needlessly slow.)

		// Persist keys per disc: a slow crack becomes a one-time cost, and
		// re-inserting the same disc reads the keys back instantly.
		setup_cache();

		// Default method: fetch each title key from the drive via the CSS ioctls
		// (instant) when a region is set, falling back to cracking otherwise.
		css = p_open(dev);
		if (!css)
		{
			css_log("dvdcss_open(%s) failed", dev);
			return 0;
		}
	}
	else
	{
		// No libdvdcss: raw fallback. Unencrypted DVDs play; a CSS disc can't be
		// descrambled here — and many drives won't even hand over the scrambled
		// VOB sectors without auth, so the core would just sit black with no data
		// to trip its CSS ENCRYPTED detector. Detect CSS up front and say so.
		if (disc_is_encrypted(dev))
		{
			css_log("encrypted disc but no libdvdcss — run install_dvdcss");
			// InfoMessage only renders when menustate <= MENU_INFO (core idle), but
			// the mount runs mid-launch when the menu FSM is in a high state, so a
			// call here is dropped. Defer it: dvd_css_tick() (from user_io_poll)
			// re-asserts it until the launch settles to MENU_NONE1 and it shows.
			// ⚠ And that tick must NOT re-assert while an MGL launch is still
			// running -- pinning menustate there stalls the load and every input
			// path on the machine (issue #48). dvd_css_tick() gates on
			// dvd_launch_ui_busy(); this 8 s window is pushed along, not spent.
			warn_until = time(NULL) + 8;
		}
		raw_fd = open(dev, O_RDONLY | O_CLOEXEC);
		if (raw_fd < 0)
		{
			css_log("cannot open %s", dev);
			return 0;
		}
	}

	// If the size was not available at scan time (drive was still spinning up),
	// read it now that the device is open and the disc is ready.
	if (css_size == 0)
	{
		int fd = open(dev, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd >= 0)
		{
			uint64_t bytes = 0;
			if (ioctl(fd, BLKGETSIZE64, &bytes) == 0) css_size = bytes;
			close(fd);
		}
	}

	css_pos = -1;
	css_log("opened %s (%llu MB)%s", dev, (unsigned long long)(css_size >> 20),
	        css ? "" : " raw — no libdvdcss, unencrypted discs only");

	// Discover the VOB layout and pre-crack every title key at its VOB start.
	if (css) build_vob_list();
	return 1;
}

// Open a CSS-encrypted DVD-Video ISO *image file* (no optical drive needed) and
// claim it only if it is actually scrambled — a decrypted ISO must keep the fast
// direct-file mount, not pay per-sector libdvdcss. Returns 1 (use dvd_css_read for
// this slot) or 0 (not encrypted / no libdvdcss / not a DVD -> caller falls back to
// the normal file path). libdvdcss reads image files directly; with no drive to
// authenticate, title keys are cracked from the data (the same slow path as a
// no-region drive), cached under DVDCSS_CACHE so it is a one-time cost per disc.
int dvd_css_open_image(const char *path)
{
	if (css || raw_fd >= 0) return 0;   // a source is already open
	if (!path) return 0;

	// Decrypting an image needs libdvdcss. Without it, let the normal file path
	// handle the mount: a decrypted ISO plays; an encrypted one trips the core's
	// CSS ENCRYPTED notice (raw scrambled sectors), same as before this existed.
	if (!load_library()) { css_log("image %s: no libdvdcss -> direct path", path); return 0; }

	// MiSTer passes a storage-relative path (e.g. "cifs/games/DVD/x.iso"); stat() and
	// dvdcss_open() need the absolute path. getFullPath() returns a shared static buffer,
	// so copy it before any later getFullPath call clobbers it.
	char full[1024];
	snprintf(full, sizeof(full), "%s", getFullPath(path));

	struct stat st;
	if (stat(full, &st) != 0 || st.st_size <= 0) { css_log("image %s: stat(%s) failed", path, full); return 0; }

	// Persist cracked keys per disc (shared with the drive path).
	setup_cache();

	dvdcss_t h = p_open(full);
	if (!h) { css_log("dvdcss_open(image) FAILED: %s", full); return 0; }

	css = h;
	css_size = (uint64_t)st.st_size;
	region_set = 1;    // no drive; keys are cracked from data regardless of region
	css_pos = -1;
	cur_vob = -1;

	if (!enumerate_vobs())
	{
		css_log("image %s: no VIDEO_TS/VOBs -> direct path", path);
		dvd_css_close();
		return 0;
	}

	// Decide from the BITSTREAM (are the sectors actually scrambled?), NOT from
	// dvdcss_is_scrambled() — the lib flag reports the disc's CSS *structure*, so it reads
	// 1 for a DECRYPTED rip of a CSS disc too and would waste time cracking keys for an
	// already-plaintext image. Fall back to the lib flag only when the sample was
	// inconclusive (bs == -1: no parseable PES to judge). Log both so divergence is visible.
	int lib_scr = p_scram ? (p_scram(css) != 0) : -1;
	int bs_scr  = image_is_scrambled();
	int scrambled = (bs_scr >= 0) ? bs_scr : (lib_scr > 0);
	css_log("image %s: %d VOBs, scrambled=%d (bitstream=%d lib=%d)",
	        path, g_nvobs, scrambled, bs_scr, lib_scr);
	if (!scrambled)
	{
		// Plaintext image (decrypted rip or never-CSS) -> keep the fast direct-file mount.
		dvd_css_close();
		return 0;
	}

	// No drive -> always a crack, but an image's random I/O is far quicker than an
	// optical drive's seeks, so this is fast in practice (and cached after) — no "slow".
	crack_title_keys("Decrypting ISO");
	css_log("encrypted ISO %s (%llu MB) — decrypting via libdvdcss",
	        path, (unsigned long long)(css_size >> 20));
	return 1;
}

int dvd_css_active(void)
{
	return css != NULL || raw_fd >= 0;
}

// Called every user_io_poll. Re-asserts the "encrypted disc, install libdvdcss"
// popup ~once/second until its window closes, and renders once menustate settles
// to idle (core running).
//
// ⚠ The original comment here claimed "InfoMessage no-ops while the launch FSM is
// busy". It does not — it PINS menustate = MENU_INFO whenever menustate is idle,
// which is exactly the state an MGL launch needs to advance out of. That belief
// cost issue #48: a notice raised from this tick froze the MGL and, with it,
// every input path on the machine. Hence the dvd_launch_ui_busy() gate, which
// holds the window open rather than consuming it. See docs/mgl_launch.md.
void dvd_css_tick(void)
{
	if (!warn_until) return;
	time_t now = time(NULL);
	if (now >= warn_until) { warn_until = 0; return; }

	// Defer, don't spend: push the window along so the notice still appears
	// once the launch settles.
	if (dvd_launch_ui_busy()) { warn_until = now + 2; return; }

	static time_t last = 0;
	if (now != last)   // at most once per second — the 2 s InfoMessage timeout bridges the gap
	{
		last = now;
		InfoMessage("Encrypted DVD\n\nRun install_dvdcss", 2000, "DVD");
	}
}

uint64_t dvd_css_size(void)
{
	return (css || raw_fd >= 0) ? css_size : 0;
}

int dvd_css_read(void *buf, uint32_t lba, uint32_t count)
{
	if (raw_fd >= 0) return raw_read10(raw_fd, lba, buf, (int)count);   // no-libdvdcss fallback
	if (!css) return -1;

	int vi = vob_index(lba);
	int decrypt = (vi >= 0);

	if (decrypt)
	{
		// Don't let one read span two titles (different keys): clamp to this VOB.
		uint32_t vob_end = g_vobs[vi].start + g_vobs[vi].nsec;
		if (lba + count > vob_end) count = vob_end - lba;

		// Select this VOB's (pre-cracked) title key. SEEK_KEY is a fast cached
		// lookup now; only needed on a title change or a discontinuity.
		if (vi != cur_vob || (int)lba != css_pos)
		{
			if (p_seek(css, (int)lba, DVDCSS_SEEK_KEY) < 0)
			{
				if (p_seek(css, (int)lba, DVDCSS_NOFLAGS) < 0)
				{
					static int sf = 0;
					if (sf < 10) { sf++; css_log("seek %u failed: %s", lba, p_error ? p_error(css) : "?"); }
					css_pos = -1; cur_vob = -1; return -1;
				}
				decrypt = 0;   // no key -> read raw rather than corrupt
			}
			cur_vob = vi;
		}
	}
	else
	{
		// Filesystem/IFO sector: raw positioning, NEVER decrypt (would corrupt it).
		if ((int)lba != css_pos)
		{
			if (p_seek(css, (int)lba, DVDCSS_NOFLAGS) < 0)
			{
				static int sf2 = 0;
				if (sf2 < 10) { sf2++; css_log("seek %u failed: %s", lba, p_error ? p_error(css) : "?"); }
				css_pos = -1; return -1;
			}
		}
		cur_vob = -1;
	}

	int n = p_read(css, buf, (int)count, decrypt ? DVDCSS_READ_DECRYPT : DVDCSS_NOFLAGS);
	if (n < 0)
	{
		static int rf = 0;
		if (rf < 10) { rf++; css_log("read %u@%u failed: %s", count, lba, p_error ? p_error(css) : "?"); }
		css_pos = -1;
		return -1;
	}

	css_pos = (int)(lba + n);
	return n;
}

void dvd_css_close(void)
{
	if (css && p_close) p_close(css);
	if (raw_fd >= 0) close(raw_fd);
	css = NULL;
	raw_fd = -1;
	css_pos = -1;
	cur_vob = -1;
	g_nvobs = 0;
	css_size = 0;
	warn_until = 0;
}
