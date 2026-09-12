// dvd_report.cpp — generate a navigation support bundle from the player itself.
// See dvd_report.h and MiSTer_DVD/docs/support_bundle_hps.md.

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdarg.h>
#include <time.h>
#include <errno.h>
#include <dirent.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>

#include "../../user_io.h"
#include "../../menu.h"
#include "../../osd.h"
#include "../../file_io.h"
#include "dvd_report.h"
#include "dvd_css.h"
#include "dvd_phys.h"
#include "dvd_launch.h"

// ---------------------------------------------------------------------------
// The trigger
// ---------------------------------------------------------------------------
// J1 on this core is fully populated (13 buttons), so any chord also performs
// its own actions. Audio (B7) + Subtitle (B8) is chosen because both are
// edge-triggered single steps with on-screen feedback and both are trivially
// undone — a chord on the transport buttons could leave a seek or a pause.
//
// Suppressing the two bits while the chord is held was considered and rejected:
// it would mean editing the map on its way to the core, so a detection bug would
// make buttons stop working, and it would swallow a legitimate fast double-press.
// Observing only cannot break anything that was working.
//
// JOY_BTN1 is bit 4 (JOY_BTN_SHIFT), so button N is bit (3 + N).
#define BTN_BIT(n)   (1u << (3 + (n)))
#define CHORD_MASK   (BTN_BIT(7) | BTN_BIT(8))
#define HOLD_MS      2000

#define OUT_DIR      "/media/fat/DVD_reports"

// ---------------------------------------------------------------------------
// The child's argv, built OUTSIDE the fork so it can be tested
// ---------------------------------------------------------------------------
// Lives here rather than inline in the child because a missing flag fails
// SILENTLY -- the bundle is written, looks fine, and is simply missing the data
// the report needed. That is exactly how issue #81 arrived: the reporter's bundle
// carried no button data at all and nothing said so. main/tests/dvd_report_test.cpp
// pins this.
//
// ★ --nav-window, not --nav-packs. Both capture NAV packs; they capture DIFFERENT
// ones, and only one of them is affordable here:
//   --nav-packs   scans MENU VOBs (VIDEO_TS.VOB, VTS_nn_0.VOB) up to a 512 MB cap.
//                 It CANNOT see an in-title menu -- a DVD-game or motion-menu disc
//                 authors its menus as TITLE-domain PGCs with the HLI in a TITLE
//                 VOB's NAV packs (Scene It's game menus; issue #81's disc, whose
//                 boot menus live in VTS_02_1.VOB). Measured cost on MEN_IN_BLACK:
//                 4.9 s and 5.6 MB of sectors on a local disk -- which on an
//                 optical disc the core is streaming from means minutes of seeking.
//   --nav-window  one SEQUENTIAL run forward from the sector we were serving,
//                 capturing every NAV pack in it. Measured: 0.28 s end to end,
//                 16 NAV packs, a 38 KB bundle -- and on Scene It's game VTSes
//                 13-20 of ~20 such packs carry MULTI-BUTTON HLI, i.e. exactly
//                 the records the menu-VOB scan cannot reach. No seeks.
// 2048 sectors is ~4 MB; a VOBU is at most 1 s of video, so it always spans
// several, and an HLI is re-sent every VOBU while a menu is up.
//
// Needs the playhead: with no LBA there is nothing to window around, so the flag
// is omitted rather than passed with a meaningless base.
// The window's CAP, in sectors. Two values, because the media differ by ~50x and
// MEASURING said so rather than taste:
//
//   image on SD/USB/CIFS   the whole child runs in 1.4-2.0 s, the window costing
//                          ~0.5 s of that. 2048 sectors is free, so take the wide
//                          one and capture several VOBUs.
//   optical disc           the drive sustains ~90-285 KB/s -- about a SEVENTH of
//                          DVD 1x -- measured while the core was streaming it, and
//                          steady over 84 s, so it is not spin-up. 2048 sectors is
//                          15.7-29.1 s. 512 bounds the no-NAV-pack tail to ~5-10 s,
//                          and the early stop (dvd_report.py --nav-stop, default 2)
//                          means the usual case exits after ~300-500 sectors anyway.
//
// ⚠ The cap is what you pay when the playhead sits somewhere with NO NAV packs --
// a still, a gap, the end of a cell. The early stop cannot help there, which is
// the whole reason the cap is media-dependent rather than just large.
#define NAV_WINDOW_IMAGE   "2048"
#define NAV_WINDOW_OPTICAL "512"

// ⚠⚠ THE INSTALLED SCRIPT MAY PREDATE THE FLAG, AND argparse DOES NOT SHRUG.
// MEASURED on the rig against a release-installed dvd_report.py: the new argv gives
//   dvd_report.py: error: unrecognized arguments: --nav-window 2048
// and NO BUNDLE IS WRITTEN AT ALL -- strictly worse than the missing button data
// this flag exists to fix. The release zip ships Scripts/dvd_report.py beside the
// Main so they normally move together, but a Main updated on its own must degrade,
// not break.
//
// So: ask the script. It names every flag it accepts (argparse cannot accept one it
// does not name), so a substring search over the file is sound in both directions --
// no old tool mentions it, and no new tool can support it silently.
//
// ★ Runs in the CHILD, after the fork: this is file I/O, and user_io_poll() is the
// core's data pump (the dvd_phys drive-probe lesson). Chunked with an overlap so the
// token cannot straddle a read boundary.
int dvd_report_script_supports(const char *script, const char *token)
{
	FILE *f = fopen(script, "rb");
	if (!f) return 0;

	const size_t tlen = strlen(token);
	if (!tlen || tlen >= 256) { fclose(f); return 0; }

	// memmem() is a GNU extension; g++ defines _GNU_SOURCE implicitly for C++ on
	// glibc and the Main's build adds it on the command line, so no #define here --
	// one was added and REMOVED because it warned "redefined" on every build.
	char buf[8192 + 256];
	size_t keep = 0;                      // bytes carried over from the last chunk
	int found = 0;
	for (;;)
	{
		size_t got = fread(buf + keep, 1, 8192, f);
		if (!got) break;
		size_t have = keep + got;
		buf[have < sizeof(buf) ? have : sizeof(buf) - 1] = 0;
		if (memmem(buf, have, token, tlen)) { found = 1; break; }
		// Carry the last tlen-1 bytes so a token split across chunks is still seen.
		keep = (tlen > 1) ? (tlen - 1) : 0;
		if (keep > have) keep = have;
		memmove(buf, buf + have - keep, keep);
	}
	fclose(f);
	return found;
}

// A block device here is the optical drive: dvd_phys binds /dev/srN and nothing
// else in this core hands a block device to the collector. stat() rather than a
// "/dev/sr" prefix match, because the fact that matters is the medium, not the name.
const char *nav_window_for(const char *src)
{
	struct stat st;
	if (src && !stat(src, &st) && S_ISBLK(st.st_mode)) return NAV_WINDOW_OPTICAL;
	return NAV_WINDOW_IMAGE;
}

void dvd_report_build_argv(const char **argv, const char *script, const char *src,
                           const char *out, const char *lba, const char *cfg,
                           const char *ver, int want_window)
{
	int i = 0;
	argv[i++] = "python3";
	argv[i++] = script;
	argv[i++] = src;
	argv[i++] = "--no-prompt";
	argv[i++] = "--generated-on";
	argv[i++] = "mister";
	argv[i++] = "-o";
	argv[i++] = out;
	if (lba)               { argv[i++] = "--lba";          argv[i++] = lba; }
	if (lba && want_window){ argv[i++] = "--nav-window";   argv[i++] = nav_window_for(src); }
	if (cfg)               { argv[i++] = "--cfg";          argv[i++] = cfg; }
	if (ver)               { argv[i++] = "--core-version"; argv[i++] = ver; }
	argv[i] = 0;
}

static const char *SCRIPT_PATHS[] = {
	"/media/fat/Scripts/dvd_report.py",
	"/media/fat/dvd_report.py",
	"/media/fat/Scripts/.dvd/dvd_report.py",
	0
};

static char     mounted_path[1024] = {0};   // full path of the mounted image
static uint32_t chord_since = 0;   // 0 = chord not currently held
static int      fired       = 0;   // one bundle per press-and-hold
static pid_t    child       = -1;
static char     out_path[320];

// Append-only trace. The OSD popup is timed and has to be transcribed by hand,
// which cost several debugging rounds; this can just be cat'd.
static void rep_log(const char *fmt, ...)
{
	va_list ap;
	static int stamped = 0;
	FILE *f = fopen("/tmp/dvd_report.log", "a");
	if (f)
	{
		// Which binary is actually running? Several debugging rounds were lost
		// to a stale copy that was indistinguishable by size, so the log says
		// for itself rather than relying on an md5 taken at another time.
		if (!stamped)
		{
			stamped = 1;
			fprintf(f, "--- dvd_report built " __DATE__ " " __TIME__ " ---\n");
		}
		va_start(ap, fmt);
		vfprintf(f, fmt, ap);
		va_end(ap);
		fputc('\n', f);
		fclose(f);
	}
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
}

static uint32_t now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static const char *find_script(void)
{
	for (int i = 0; SCRIPT_PATHS[i]; i++)
	{
		struct stat st;
		if (!stat(SCRIPT_PATHS[i], &st) && S_ISREG(st.st_mode)) return SCRIPT_PATHS[i];
	}
	return 0;
}

// The saved-settings file carries the user's OSD options. Its name embeds the
// CONF_STR config version ("v,1;" -> DVD_v1.CFG), which is bumped on any
// incompatible option relayout — so glob rather than hardcoding v1, and fall
// back to the unversioned name. Passing the file beats reading the live status
// word: user_io_status_get() spans only two bytes of cur_status[], so the full
// 128-bit word would need its own accessor for a marginal gain.
static const char *find_cfg(char *buf, size_t len)
{
	DIR *d = opendir("/media/fat/config");
	if (!d) return 0;

	char best[64] = {0};
	struct dirent *e;
	while ((e = readdir(d)))
	{
		if (strncasecmp(e->d_name, "DVD", 3)) continue;
		size_t n = strlen(e->d_name);
		if (n < 5 || strcasecmp(e->d_name + n - 4, ".CFG")) continue;
		// "DVD.CFG" or "DVD_v<N>.CFG" only — never another core's file.
		if (e->d_name[3] != '.' && strncasecmp(e->d_name + 3, "_v", 2)) continue;
		if (strcmp(e->d_name, best) > 0) snprintf(best, sizeof(best), "%s", e->d_name);
	}
	closedir(d);
	if (!best[0]) return 0;
	snprintf(buf, len, "/media/fat/config/%s", best);
	return buf;
}

// What is the core reading from right now? An image file gives its path; a
// physical disc gives the drive node, which is safe to hand to the tool because
// every sector it reads is unscrambled (see docs/bug_reports.md).
void dvd_report_note_mount(const char *path)
{
	if (!path || !path[0])
	{
		rep_log("DVD_REPORT: mount hook: (empty) -> cleared");
		mounted_path[0] = 0;
		return;
	}
	if (!strcmp(path, DVD_PHYS_SENTINEL))
	{
		rep_log("DVD_REPORT: mount hook: sentinel -> cleared");
		mounted_path[0] = 0;
		return;
	}

	// ⚠ Mount paths are RELATIVE to getRootDir() unless they start with '/' --
	// make_fullpath() in file_io.cpp does this expansion, and everything inside
	// Main goes through it. We hand this path to a separate process with its own
	// working directory, so it has to be absolute or python3 simply will not
	// find the file.
	if (path[0] == '/')
		snprintf(mounted_path, sizeof(mounted_path), "%s", path);
	else
		snprintf(mounted_path, sizeof(mounted_path), "%s/%s", getRootDir(), path);
	rep_log("DVD_REPORT: mount hook: %s -> %s", path, mounted_path);
}

void dvd_report_note_mount_result(const char *path, int index, int ok, uint64_t size)
{
	rep_log("DVD_REPORT: mount result: slot %d %s size=%llu path=%s",
	        index, ok ? "OK" : "FAILED", (unsigned long long)size,
	        (path && path[0]) ? path : "(eject)");
	if (!ok || !size)
		rep_log("DVD_REPORT:   ^ the core is still told a disc arrived (UIO_SET_SDSTAT "
		        "is sent regardless) -- expect no picture");
}

static const char *find_source(void)
{
	// A physical disc first: dvd_phys owns the drive and its node is what the
	// tool should read (every sector it touches is unscrambled).
	if (dvd_css_active())
	{
		const char *dev = dvd_phys_device();
		if (dev && *dev) return dev;
	}
	// Otherwise the mounted image, captured at mount time. Do NOT use
	// fileTYPE::path here -- user_io.cpp only fills it in the pre-create branch
	// (`if (!ret && pre)`), so a normally-mounted ISO leaves it empty and this
	// reported "Load a disc or image first" with a disc plainly loaded.
	if (mounted_path[0]) return mounted_path;
	return 0;
}

static void start(void)
{
	const char *script = find_script();
	if (!script)
	{
		InfoMessage("Support bundle needs dvd_report.py\n"
		            "in /media/fat/Scripts/", 4000, "DVD");
		return;
	}

	const char *src = find_source();
	if (!src)
	{
		// Say what was actually seen, not just that nothing was found. The
		// three inputs fail for different reasons -- an old Main with no
		// step-26 hook looks identical to a genuinely empty slot otherwise,
		// and one screenshot should tell them apart.
		char msg[220];
		const char *dev = dvd_phys_device();
		snprintf(msg, sizeof(msg),
		         "Nothing to bundle\n\ncss active: %d\ndrive: %s\nmounted: %s",
		         dvd_css_active(), dev ? dev : "(none)",
		         mounted_path[0] ? mounted_path : "(not captured)");
		InfoMessage(msg, 8000, "DVD");
		rep_log("DVD_REPORT: NO SOURCE (css=%d dev=%s mount=%s)",
		        dvd_css_active(), dev ? dev : "-",
		        mounted_path[0] ? mounted_path : "-");
		return;
	}

	mkdir(OUT_DIR, 0777);

	time_t t = time(0);
	struct tm tm;
	localtime_r(&t, &tm);
	snprintf(out_path, sizeof(out_path), OUT_DIR "/dvdreport-%04d%02d%02d-%02d%02d%02d.zip",
	         tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
	         tm.tm_hour, tm.tm_min, tm.tm_sec);

	char lba[24] = {0};
	uint64_t l = user_io_last_lba(0);
	int have_lba = (l != (uint64_t)-1);
	if (have_lba) snprintf(lba, sizeof(lba), "%llu", (unsigned long long)l);

	char cfgbuf[128];
	const char *cfg = find_cfg(cfgbuf, sizeof(cfgbuf));

	// The core version, without a human having to read it off the OSD and type
	// it. CONF_STR's "V,<version> <yymmdd>" line is appended to the OSD core name
	// at init (user_io.cpp, the p[0]=='V' arm), so OsdCoreNameGet() reads back
	// "DVD v0.4.0 260901" (a release) or "DVD dev-seekrealign 260903" (a test
	// build), and everything after the FIRST space is the version. The two shapes
	// are deliberate and distinguishable: a bundle from a pre-release build can
	// no longer look like one from a release. See dvd/emu.sv "VERSIONING".
	// This matters more here than on the PC route: there is no reporter in the
	// loop to supply it, and it is the only thing that identifies a build.
	const char *ver = 0;
	const char *osdname = OsdCoreNameGet();
	if (osdname)
	{
		const char *sp = strchr(osdname, ' ');
		// No space means no V line was parsed -- pass nothing rather than
		// recording the bare core name as if it were a version.
		if (sp && sp[1]) ver = sp + 1;
	}

	rep_log("DVD_REPORT: src=%s out=%s lba=%s ver=%s",
	        src, out_path, have_lba ? lba : "n/a", ver ? ver : "n/a");

	pid_t p = fork();
	if (p < 0)
	{
		InfoMessage("Could not start bundle generation", 3000, "DVD");
		return;
	}
	if (!p)
	{
		const char *argv[DVD_REPORT_ARGV_MAX];
		dvd_report_build_argv(argv, script, src, out_path,
		                      have_lba ? lba : 0, cfg, ver,
		                      dvd_report_script_supports(script, "--nav-window"));

		freopen("/tmp/dvd_report_run.log", "w", stdout);
		dup2(fileno(stdout), fileno(stderr));
		execvp("python3", (char * const *)argv);
		_exit(127);
	}

	child = p;
	// ⚠ 8 s, not the 2 s this used to carry. The job takes ~1.4-2.0 s (MEASURED on
	// the rig, image media), so a 2 s message happened to stay up for exactly as
	// long as the work took -- but that was a COINCIDENCE of two unrelated numbers,
	// not a design. Anything slower (an optical disc, a drive spinning up, a bigger
	// window) drops the message before reap() posts the result, and the user sees
	// the "Generating" notice vanish with nothing after it -- which reads as a
	// failure and invites a second chord press. The result message replaces this one
	// the moment it arrives, so a longer timeout costs nothing in the fast case.
	//
	// It stays well under dvd_launch's 20 s MGL watchdog, and the MGL guard below is
	// why extending it is safe at all.
	InfoMessage("Generating support bundle...", 8000, "DVD");
}

static void reap(void)
{
	if (child < 0) return;

	int st = 0;
	pid_t r = waitpid(child, &st, WNOHANG);
	if (r != child) return;
	child = -1;

	if (WIFEXITED(st) && !WEXITSTATUS(st))
	{
		const char *name = strrchr(out_path, '/');
		char msg[256];
		snprintf(msg, sizeof(msg),
		         "Support bundle written to\nDVD_reports/%s\n\nAttach it to a GitHub issue.",
		         name ? name + 1 : out_path);
		InfoMessage(msg, 6000, "DVD");
	}
	else
	{
		// python3 missing, an unreadable disc, or a tool error. The child's
		// output is in /tmp/dvd_report.log — say so rather than swallowing it.
		InfoMessage("Support bundle FAILED\nsee /tmp/dvd_report_run.log", 5000, "DVD");
	}
}

void dvd_report_joy(uint32_t map)
{
	if (!is_dvd()) return;

	if ((map & CHORD_MASK) == CHORD_MASK)
	{
		if (!chord_since) chord_since = now_ms();
	}
	else
	{
		chord_since = 0;
		fired = 0;               // re-arm only after the chord is released
	}
}

void dvd_report_tick(void)
{
	if (!is_dvd()) return;

	reap();

	// ⚠ This tick raises InfoMessage, and that is the exact shape that froze MGL
	// launches (issue #48): while mgl->done == 0, HandleUI takes the MGL branch and
	// InfoMessage pins menustate = MENU_INFO, so the FSM never reaches MENU_NONE2.
	// In practice the chord needs a deliberate 2 s human hold and so cannot collide
	// with a launch -- but "cannot happen" is what the pumps that DID freeze it were
	// assumed to be, the rule in INTEGRATION.md admits no exception, and the message
	// above is now 8 s rather than 2. Deferring costs the user one more press of a
	// chord they are vanishingly unlikely to be holding.
	if (dvd_launch_ui_busy()) return;

	if (chord_since && !fired && child < 0 && (now_ms() - chord_since) >= HOLD_MS)
	{
		fired = 1;
		start();
	}
}
