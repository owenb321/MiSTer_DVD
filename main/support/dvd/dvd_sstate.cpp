// dvd_sstate.cpp -- see dvd_sstate.h. Design: docs/nav_engine.md §11.
//
// The disc identity and the slot path are the shelved feature/save-states branch's,
// which were HW-proven there (2026-09-26: a menu save, a film bookmark and a physical
// disc all saved and loaded). What is new is everything between the file and the
// core: that branch had its own capture module (EXT_BUS 0x7C, since retaken by
// nav_trace) and a restore that wrote the VM's registers directly; this one stores the
// microcoded VM's snapshot and lets the VM restore itself (E_RST).

#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <strings.h>    // strncasecmp (the ISO9660 walk)
#include <fcntl.h>
#include <unistd.h>
#include <time.h>

#include "../../user_io.h"
#include "../../file_io.h"
#include "../../menu.h"
#include "../../osd.h"        // OsdCoreNameGet
#include "dvd_launch.h"
#include "dvd_phys.h"         // DVD_PHYS_SENTINEL, dvd_phys_device
#include "dvd_css.h"          // dvd_css_active, dvd_css_read
#include "dvd_vmsnap.h"
#include "dvd_sstate.h"

#ifndef DVD_SSTATE_LOG
#define DVD_SSTATE_LOG "/tmp/dvd_report.log"
#endif

// printf goes to Main's stdout, which cfg.cpp discards unless debug=2 -- so a failure
// here would say nothing anywhere. The other DVD modules share /tmp/dvd_report.log.
static void ss_log(const char *fmt, ...)
{
	va_list ap;
	FILE *f = fopen(DVD_SSTATE_LOG, "a");
	if (!f) return;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fprintf(f, "\n");
	fclose(f);
}

#ifdef DVD_SSTATE_NOW_MS
#define ss_now_ms DVD_SSTATE_NOW_MS                // the host test's clock
#else
static unsigned ss_now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (unsigned)(ts.tv_sec * 1000u + ts.tv_nsec / 1000000u);
}
#endif

// ---------------------------------------------------------------------------
// Disc identity: a hash of VIDEO_TS.IFO's first sector (the VMGI_MAT)
// ---------------------------------------------------------------------------
#define SEC_SIZE 2048
#define PVD_LBA  16
// A directory may span several sectors; bound the walk so a corrupt size field
// cannot turn it into a scan of the disc on the poll thread.
#define DIR_MAX_SECTORS 16

static char disc_id[80] = {0};
static unsigned mount_t;          // when the current disc was mounted (autosave's grace)
static int      mounted;           // ... and whether any mount has been seen

typedef int (*sec_read_fn)(void *ctx, uint32_t lba, uint8_t *buf);

static void sanitize(char *p)
{
	// A filename, so keep it to what every filesystem and every human can handle.
	for (; *p; p++)
		if (!((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') ||
		      (*p >= '0' && *p <= '9') || *p == '-' || *p == '_'))
			*p = '_';
}

static uint32_t le32(const uint8_t *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }

// Find `name` (case-insensitive, any ";N" version dropped) in a directory extent.
static int dir_find(sec_read_fn rd, void *ctx, uint32_t lba, uint32_t size,
                    const char *name, uint32_t *out_lba, uint32_t *out_size)
{
	uint8_t sec[SEC_SIZE];
	uint32_t nsec = (size + SEC_SIZE - 1) / SEC_SIZE;
	if (nsec > DIR_MAX_SECTORS) nsec = DIR_MAX_SECTORS;
	size_t nl = strlen(name);
	for (uint32_t s = 0; s < nsec; s++)
	{
		if (rd(ctx, lba + s, sec) <= 0) return 0;
		for (uint32_t i = 0; i + 33 < SEC_SIZE;)
		{
			uint8_t len = sec[i];
			if (len == 0) break;                          // rest of this sector unused
			if (i + len > SEC_SIZE || len < 34) break;
			uint8_t fl = sec[i + 32];
			const char *fn = (const char *)sec + i + 33;
			uint8_t n = fl;
			for (uint8_t k = 0; k < fl; k++) if (fn[k] == ';') { n = k; break; }
			if (n == nl && !strncasecmp(fn, name, nl))
			{
				*out_lba  = le32(sec + i + 2);
				*out_size = le32(sec + i + 10);
				return 1;
			}
			i += len;
		}
	}
	return 0;
}

// 64-bit FNV-1a. ⚠ The offset basis is 14695981039346656037 (0xcbf29ce484222325);
// the shelved branch first shipped one digit short, which no outside tool computing
// "FNV-1a of VIDEO_TS.IFO" could reproduce. Test [3] pins the published vectors.
static uint64_t fnv1a64(const void *buf, size_t len)
{
	const uint8_t *b = (const uint8_t *)buf;
	uint64_t h = 14695981039346656037ULL;
	for (size_t i = 0; i < len; i++) { h ^= b[i]; h *= 1099511628211ULL; }
	return h;
}

// Walk to VIDEO_TS.IFO and set disc_id from its first sector. -> 1 on success; 0 for
// anything that is not DVD-Video (a VCD .bin, a flat .mpg, a plain ISO), which gets
// NO slots rather than an invented identity that could collide with a real disc's.
static int identity_from_disc(sec_read_fn rd, void *ctx, const char *what)
{
	uint8_t sec[SEC_SIZE];
	if (rd(ctx, PVD_LBA, sec) <= 0) { ss_log("DVD_SSTATE: cannot read sector 16 of %s", what); return 0; }
	if (sec[0] != 1 || memcmp(sec + 1, "CD001", 5))
	{
		ss_log("DVD_SSTATE: %s has no ISO9660 PVD -- no save slots", what);
		return 0;
	}
	uint32_t root_lba = le32(sec + 156 + 2), root_size = le32(sec + 156 + 10);
	uint32_t vt_lba, vt_size, ifo_lba, ifo_size;
	if (!dir_find(rd, ctx, root_lba, root_size, "VIDEO_TS", &vt_lba, &vt_size) ||
	    !dir_find(rd, ctx, vt_lba, vt_size, "VIDEO_TS.IFO", &ifo_lba, &ifo_size))
	{
		ss_log("DVD_SSTATE: %s has no VIDEO_TS.IFO -- not DVD-Video, no save slots", what);
		return 0;
	}
	if (rd(ctx, ifo_lba, sec) <= 0 || memcmp(sec, "DVDVIDEO-VMG", 12))
	{
		ss_log("DVD_SSTATE: %s: VIDEO_TS.IFO is not a VMGI -- no save slots", what);
		return 0;
	}

	// The readable part of the name: the VMG's provider field when the authoring house
	// filled it in, else "DVD". Both halves come from the IFO, so a disc and its rip
	// get the SAME file name -- the volume label would not (a rebuilt rip's is "CDROM").
	char prov[33];
	memcpy(prov, sec + 64, 32);
	prov[32] = 0;
	for (int i = 31; i >= 0 && (prov[i] == ' ' || !prov[i]); i--) prov[i] = 0;
	int printable = prov[0] != 0;
	for (int i = 0; prov[i]; i++) if ((uint8_t)prov[i] < 0x20 || (uint8_t)prov[i] > 0x7E) printable = 0;
	if (!printable) snprintf(prov, sizeof(prov), "DVD");
	sanitize(prov);

	uint64_t h = fnv1a64(sec, SEC_SIZE);
	snprintf(disc_id, sizeof(disc_id), "%s-%016llx", prov, (unsigned long long)h);
	ss_log("DVD_SSTATE: disc identity %s (%s)", disc_id, what);
	return 1;
}

static int fd_read(void *ctx, uint32_t lba, uint8_t *buf)
{
	int fd = *(int *)ctx;
	return pread(fd, buf, SEC_SIZE, (off_t)lba * SEC_SIZE) == SEC_SIZE ? 1 : -1;
}

static int css_read(void *, uint32_t lba, uint8_t *buf)
{
	return dvd_css_read(buf, lba, 1);
}

// A physical disc whose identity could not be read at mount time: resolved at the
// first save or load instead (see dvd_sstate_note_mount).
static int phys_pending = 0;

static void resolve_pending_phys(void)
{
	if (!phys_pending || disc_id[0] || !dvd_css_active()) return;
	phys_pending = 0;
	identity_from_disc(css_read, 0, "the physical disc, read through the disc source");
}

void dvd_sstate_note_mount(const char *src)
{
	// The old disc is still playing here (the core has not seen the new mount yet), so
	// this is the moment to keep its place. A no-op when nothing was playing.
	dvd_sstate_autosave_flush();
	mount_t = ss_now_ms(); mounted = 1;
	disc_id[0] = 0;
	phys_pending = 0;
	if (!src || !*src) return;

	char full[1024];

	// ⚠ A PHYSICAL DISC DOES NOT PASS A PATH. dvd_phys mounts a sentinel and owns the
	// drive; the node to read is its own. Every sector read here is unscrambled.
	if (!strcmp(src, DVD_PHYS_SENTINEL))
	{
		const char *dev = dvd_phys_device();
		if (!dev || !*dev)
		{
			// ⚠ NOT every sentinel mount comes through dvd_phys: Main's own remount of
			// the last image at core load passes the sentinel straight to
			// user_io_file_mount(), before the disc source is open. Resolve at the
			// first save or load, through the disc source, which is open by then.
			phys_pending = 1;
			ss_log("DVD_SSTATE: physical mount with no device yet -- identity deferred");
			return;
		}
		snprintf(full, sizeof(full), "%s", dev);
	}
	// ⚠ MOUNT PATHS ARE RELATIVE to getRootDir() unless they start with '/'.
	else if (src[0] == '/')
		snprintf(full, sizeof(full), "%s", src);
	else
		snprintf(full, sizeof(full), "%s/%s", getRootDir(), src);

	int fd = open(full, O_RDONLY);
	if (fd < 0) { ss_log("DVD_SSTATE: cannot open %s for identity", full); return; }
	identity_from_disc(fd_read, &fd, full);
	close(fd);
}

const char *dvd_sstate_disc_id(void)
{
	return disc_id[0] ? disc_id : 0;
}

int dvd_sstate_slot_path(int slot, char *out, size_t cap)
{
	resolve_pending_phys();
	if (!disc_id[0] || slot < 0 || slot > DVD_SSTATE_AUTO || cap < 8) return 0;
	// The framework's directory and naming (savestates/<core>/<name>_N.ss, relative to
	// getRootDir() like every other file Main opens), keyed on the DISC.
	//
	// ⛔ NOT stock FileGenerateSavestatePath(): at our pinned Main it strips an
	// extension with no else, so a name without a '.' (every disc id) reaches
	// sprintf(NULL) -- that SIGSEGV is what killed the Main on the shelved branch's
	// first rig round (docs/save_states.md §5b there).
	create_path(SAVESTATE_DIR, CoreName2);
	int n = slot == DVD_SSTATE_AUTO
		? snprintf(out, cap, "%s/%s/%s_auto.ss", SAVESTATE_DIR, CoreName2, disc_id)
		: snprintf(out, cap, "%s/%s/%s_%d.ss", SAVESTATE_DIR, CoreName2, disc_id, slot + 1);
	return n > 0 && (size_t)n < cap;
}

// ---------------------------------------------------------------------------
// The slot file
// ---------------------------------------------------------------------------
static void put16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put32(uint8_t *p, uint32_t v) { put16(p, (uint16_t)v); put16(p + 2, (uint16_t)(v >> 16)); }
static uint16_t get16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t get32(const uint8_t *p) { return get16(p) | ((uint32_t)get16(p + 2) << 16); }

static uint64_t disc_hash(void) { return fnv1a64(disc_id, strlen(disc_id)); }

// header h[] and words w[0..n-1] from the core -> a file image in buf; -> its length
static size_t build_file(uint8_t *buf, const uint16_t *h, const uint16_t *w, int n)
{
	memset(buf, 0, DVD_SSTATE_HDR);
	memcpy(buf, DVD_SSTATE_MAGIC, 4);
	put16(buf + 4, DVD_SSTATE_VERSION);
	put16(buf + 6, h[3]);
	put16(buf + 8, (uint16_t)n);
	uint16_t sum = 0;
	for (int i = 0; i < n; i++) sum = (uint16_t)(sum + w[i]);
	put16(buf + 10, sum);
	uint64_t dh = disc_hash();
	for (int i = 0; i < 8; i++) buf[12 + i] = (uint8_t)(dh >> (8 * i));
	put32(buf + 20, (uint32_t)dvd_vmsnap_disp_secs_h(h));
	put32(buf + 24, ((uint32_t)h[5] << 16) | h[6]);
	put32(buf + 28, ((uint32_t)h[13] << 16) | h[14]);
	// Recorded, never gated on: CONF_STR's "V," line is appended to the OSD core name,
	// so everything after the first space is the version.
	const char *osd = OsdCoreNameGet();
	const char *sp = osd ? strchr(osd, ' ') : 0;
	if (sp && sp[1]) snprintf((char *)buf + 32, 32, "%s", sp + 1);
	for (int i = 0; i < n; i++) put16(buf + DVD_SSTATE_HDR + 2 * i, w[i]);
	return DVD_SSTATE_HDR + 2u * (size_t)n;
}

// Check a file image. -> the word count, 0 = damaged, -1 = another disc's.
static int check_file(const uint8_t *buf, int len)
{
	if (len < DVD_SSTATE_HDR || memcmp(buf, DVD_SSTATE_MAGIC, 4) ||
	    get16(buf + 4) != DVD_SSTATE_VERSION) return 0;
	int n = get16(buf + 8);
	if (n <= 0 || n > DVD_SSTATE_MAXW || len < DVD_SSTATE_HDR + 2 * n) return 0;
	uint16_t sum = 0;
	for (int i = 0; i < n; i++) sum = (uint16_t)(sum + get16(buf + DVD_SSTATE_HDR + 2 * i));
	if (sum != get16(buf + 10)) return 0;
	// ⚠ A save belongs to its disc. The filename carries the identity, but a file can
	// be copied or renamed, and another disc's GPRMs jump into a PGC that means
	// something else entirely.
	uint64_t dh = disc_hash();
	for (int i = 0; i < 8; i++) if (buf[12 + i] != (uint8_t)(dh >> (8 * i))) return -1;
	return n;
}

// ---------------------------------------------------------------------------
// The requests
// ---------------------------------------------------------------------------
#define SS_POLL_MS     20
#define SS_TIMEOUT_MS  3000

enum { SS_IDLE, SS_SAVING, SS_LOADING };
static int      op = SS_IDLE;
static int      op_slot;
static unsigned op_t0;
static uint16_t op_seq0;

static void say(const char *fmt, int slot)
{
	char msg[96];
	// The Autosave is not a numbered slot: "Loaded slot %d" -> "Loaded autosave",
	// "Slot %d is empty" -> "Autosave is empty".
	const char *p = slot == DVD_SSTATE_AUTO ? strstr(fmt, "lot %d") : 0;
	if (p)
	{
		snprintf(msg, sizeof(msg), "%.*s%s%s", (int)(p - 1 - fmt), fmt,
		         p[-1] == 'S' ? "Autosave" : "autosave", p + 6);
	}
	else snprintf(msg, sizeof(msg), fmt, slot + 1);
	ss_log("DVD_SSTATE: %s", msg);
	InfoMessage(msg, 2500, "DVD");
}

// Shared by save and load: what stops either before it starts.
static int refuse_common(uint16_t w2, char *path, size_t cap, int slot)
{
	// The VM is disabled with Disc Menus off: the reader plays the longest title by
	// itself and nothing a load restores would run (the core refuses it as verdict 7).
	if (!VMSNAP_VM_EN(w2))
	{
		say("Save states need Disc Menus on", slot);
		return 1;
	}
	if (!dvd_sstate_slot_path(slot, path, cap))
	{
		say("This disc has no save slots", slot);
		return 1;
	}
	return 0;
}

static void start_save(uint16_t w2, int slot)
{
	char path[1024];
	if (slot == DVD_SSTATE_AUTO) { say("Autosave is written for you", slot); return; }
	if (refuse_common(w2, path, sizeof(path), slot)) return;
	if (!dvd_vmsnap_ask(&op_seq0)) return;            // no 0x7D: cannot happen after a peek
	op = SS_SAVING; op_slot = slot; op_t0 = ss_now_ms();
}

static void poll_save(unsigned now)
{
	uint16_t h[DVD_VMSNAP_HDR];
	static uint16_t w[DVD_VMSNAP_MAXW];
	int n = dvd_vmsnap_fetch(op_seq0, h, w);
	if (n <= 0)
	{
		if (n < 0 || now - op_t0 > SS_TIMEOUT_MS)
		{
			op = SS_IDLE;
			ss_log("DVD_SSTATE: slot %d: no snapshot in 3 s (busy %d)", op_slot + 1, h[2] >> 15);
			say("Could not save: the player stayed busy. Try again", op_slot);
		}
		return;
	}
	op = SS_IDLE;
	char path[1024];
	if (!dvd_sstate_slot_path(op_slot, path, sizeof(path))) { say("This disc has no save slots", op_slot); return; }
	static uint8_t buf[DVD_SSTATE_MAX];
	size_t len = build_file(buf, h, w, n);
	fileTYPE f = {};
	if (!FileOpenEx(&f, path, O_CREAT | O_TRUNC | O_RDWR | O_SYNC))
	{
		ss_log("DVD_SSTATE: cannot create %s", path);
		say("Could not write the save file", op_slot);
		return;
	}
	int wrote = FileWriteAdv(&f, buf, (int)len);
	FileClose(&f);
	if (wrote != (int)len) { say("Could not write the save file", op_slot); return; }
	ss_log("DVD_SSTATE: slot %d -> %s: %d words, fmt %04x, land at %d s", op_slot + 1, path,
	       n, h[3], dvd_vmsnap_disp_secs_h(h));
	say("Saved to slot %d", op_slot);
}

static void start_load(uint16_t w2, int slot)
{
	char path[1024];
	if (refuse_common(w2, path, sizeof(path), slot)) return;
	if (!FileExists(path)) { say("Slot %d is empty", slot); return; }
	fileTYPE f = {};
	if (!FileOpen(&f, path)) { say("Could not read the save file", slot); return; }
	static uint8_t buf[DVD_SSTATE_MAX + 1];
	int got = FileReadAdv(&f, buf, sizeof(buf));
	FileClose(&f);
	int n = check_file(buf, got);
	if (n < 0) { say("That save is from a different disc", slot); return; }
	if (n == 0) { say("That save file is damaged", slot); return; }
	static uint16_t w[DVD_SSTATE_MAXW];
	for (int i = 0; i < n; i++) w[i] = get16(buf + DVD_SSTATE_HDR + 2 * i);
	int32_t disp = (int32_t)get32(buf + 20);
	uint16_t tm = (disp >= 0 && disp < 0xFFFF) ? (uint16_t)disp : 0xFFFF;
	if (!dvd_vmload_send(get16(buf + 6), w, n, tm, get32(buf + 24))) return;
	ss_log("DVD_SSTATE: slot %d <- %s: %d words, land at %d s", slot + 1, path, n, tm == 0xFFFF ? -1 : tm);
	op = SS_LOADING; op_slot = slot; op_t0 = ss_now_ms();
}

static void poll_load(unsigned now)
{
	int v = dvd_vmload_verdict();
	if (v == VL_PENDING || v <= VL_NONE)
	{
		if (now - op_t0 > SS_TIMEOUT_MS)
		{
			op = SS_IDLE;
			say("Could not load: the player stayed busy. Try again", op_slot);
		}
		return;
	}
	op = SS_IDLE;
	switch (v)
	{
	case VL_APPLIED:   say("Loaded slot %d", op_slot); break;
	case VL_BAD_FMT:   say("That save is from another version of the core", op_slot); break;
	case VL_BAD_LEN:
	case VL_BAD_SUM:   say("That save file is damaged", op_slot); break;
	case VL_BUSY:      say("Could not load: the player stayed busy. Try again", op_slot); break;
	case VL_MENUS_OFF: say("Save states need Disc Menus on", op_slot); break;
	}
}

// ---------------------------------------------------------------------------
// Autosave (docs/nav_engine.md §11i)
// ---------------------------------------------------------------------------
#define AUTO_WAIT_MS   300      // the most a mount or a core switch waits for the VM to rest
#define AUTO_STEP_MS   10
#define AUTO_GRACE_MS  10000    // a disc younger than this has not played anything worth keeping
#ifndef DVD_SSTATE_SLEEP_MS
#define DVD_SSTATE_SLEEP_MS(ms) usleep((ms) * 1000)
#endif

static void abs_path(const char *p, char *out, size_t cap)
{
	if (p[0] == '/') snprintf(out, cap, "%s", p);
	else snprintf(out, cap, "%s/%s", getRootDir(), p);
}

void dvd_sstate_autosave_flush(void)
{
	if (!is_dvd()) return;
	// ⚠ A boot is not progress. A disc mounted a moment ago is at its logos or its first
	// menu, and keeping THAT would replace the place the user actually left it at (the
	// core's own remount of the last disc at load, then an immediate core switch). The
	// snapshot's pos_fresh / armed bits below catch a core that has played nothing at all.
	if (!mounted || ss_now_ms() - mount_t < AUTO_GRACE_MS) return;
	char path[1024];
	if (!dvd_sstate_slot_path(DVD_SSTATE_AUTO, path, sizeof(path))) return;
	uint16_t w2, w4;
	if (!dvd_vmsnap_peek4(&w2, &w4) || !VMSNAP_VM_EN(w2)) return;

	op = SS_IDLE;               // a manual request in flight dies with the disc
	uint16_t seq0, h[DVD_VMSNAP_HDR];
	static uint16_t w[DVD_VMSNAP_MAXW];
	if (!dvd_vmsnap_ask(&seq0)) return;
	int n;
	unsigned t0 = ss_now_ms();
	while ((n = dvd_vmsnap_fetch(seq0, h, w)) == 0)
	{
		if (ss_now_ms() - t0 >= AUTO_WAIT_MS) break;
		DVD_SSTATE_SLEEP_MS(AUTO_STEP_MS);
	}
	if (n <= 0) { ss_log("DVD_SSTATE: autosave skipped: no snapshot in %d ms", AUTO_WAIT_MS); return; }
	if (!VMSNAP_FRESH(h[4]) && !VMSNAP_ARMED(h[4]))
	{
		ss_log("DVD_SSTATE: autosave skipped: no NAV pack or buttons since the last flush");
		return;
	}
	static uint8_t buf[DVD_SSTATE_MAX];
	size_t len = build_file(buf, h, w, n);
	// Written beside the file and renamed over it: a power cut mid-write must leave the
	// previous autosave, not half of the new one.
	char tmp[1100], a_tmp[1200], a_dst[1200];
	snprintf(tmp, sizeof(tmp), "%s.tmp", path);
	fileTYPE f = {};
	if (!FileOpenEx(&f, tmp, O_CREAT | O_TRUNC | O_RDWR | O_SYNC))
	{
		ss_log("DVD_SSTATE: autosave: cannot create %s", tmp);
		return;
	}
	int wrote = FileWriteAdv(&f, buf, (int)len);
	FileClose(&f);
	abs_path(tmp, a_tmp, sizeof(a_tmp));
	abs_path(path, a_dst, sizeof(a_dst));
	if (wrote != (int)len || rename(a_tmp, a_dst))
	{
		ss_log("DVD_SSTATE: autosave: could not write %s", path);
		remove(a_tmp);
		return;
	}
	ss_log("DVD_SSTATE: autosave -> %s: %d words, fmt %04x, land at %d s", path, n, h[3],
	       dvd_vmsnap_disp_secs_h(h));
}

void dvd_sstate_tick(void)
{
	// Another core is running: the next DVD core load is a fresh session, whatever mount
	// it replays first (autosave's grace starts again at that mount).
	if (!is_dvd()) { mounted = 0; return; }

	// Self-throttled: user_io_poll() spins with no sleep.
	static unsigned last = 0;
	unsigned now = ss_now_ms();
	if (now - last < SS_POLL_MS) return;
	last = now;

	// ⚠ Never raise UI while an MGL launch is still running: HandleUI() takes the MGL
	// branch and stops calling menu_key_get(), so an InfoMessage there pins the menu
	// FSM (docs/mgl_launch.md). Defer; the counters wait.
	if (dvd_launch_ui_busy()) return;

	if (op == SS_SAVING)  { poll_save(now); return; }
	if (op == SS_LOADING) { poll_load(now); return; }

	static int have_ref = 0;
	static int ref_save = 0, ref_load = 0;
	uint16_t w2, w4;
	if (!dvd_vmsnap_peek4(&w2, &w4))
	{
		// An older core: drop the baseline, so a newer core re-latches rather than
		// diffing against a stale one.
		have_ref = 0;
		return;
	}
	int sv = VMSNAP_SAVE_N(w2), ld = VMSNAP_LOAD_N(w2);
	// The first valid word is a baseline, acted on NOT AT ALL: whatever the counters
	// hold now is history, and acting on it would save or load as a core loads.
	if (!have_ref)
	{
		have_ref = 1; ref_save = sv; ref_load = ld;
		return;
	}
	// 2-bit wrapping counts: act if one MOVED, once, whatever it moved by. Two presses
	// between polls are one save of the state as it is now.
	int slot = VMSNAP_AUTO(w4) ? DVD_SSTATE_AUTO : VMSNAP_SLOT(w2);
	if (sv != ref_save) { ref_save = sv; start_save(w2, slot); return; }
	if (ld != ref_load) { ref_load = ld; start_load(w2, slot); return; }
}
