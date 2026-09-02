// dvd_report.cpp — generate a navigation support bundle from the player itself.
// See dvd_report.h and MiSTer_DVD/docs/support_bundle_hps.md.

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
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
	if (!path || !path[0]) { mounted_path[0] = 0; return; }         // unmount
	if (!strcmp(path, DVD_PHYS_SENTINEL)) { mounted_path[0] = 0; return; }

	// ⚠ Mount paths are RELATIVE to getRootDir() unless they start with '/' --
	// make_fullpath() in file_io.cpp does this expansion, and everything inside
	// Main goes through it. We hand this path to a separate process with its own
	// working directory, so it has to be absolute or python3 simply will not
	// find the file.
	if (path[0] == '/')
		snprintf(mounted_path, sizeof(mounted_path), "%s", path);
	else
		snprintf(mounted_path, sizeof(mounted_path), "%s/%s", getRootDir(), path);
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
		InfoMessage("Load a disc or image first", 3000, "DVD");
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
	// it. CONF_STR's "V,v0.4.0 260901" line is appended to the OSD core name at
	// init (user_io.cpp, the p[0]=='V' arm), so OsdCoreNameGet() reads back
	// "DVD v0.4.0 260901" and everything after the first space is the version.
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

	printf("DVD_REPORT: %s -> %s (lba %s, ver %s)\n",
	       src, out_path, have_lba ? lba : "n/a", ver ? ver : "n/a");

	pid_t p = fork();
	if (p < 0)
	{
		InfoMessage("Could not start bundle generation", 3000, "DVD");
		return;
	}
	if (!p)
	{
		// Child. Nav-tables only: no --nav-packs, because that scans menu VOBs
		// and this should finish in seconds on SD-card media.
		const char *argv[20];
		int i = 0;
		argv[i++] = "python3";
		argv[i++] = script;
		argv[i++] = src;
		argv[i++] = "--no-prompt";
		argv[i++] = "--generated-on";
		argv[i++] = "mister";
		argv[i++] = "-o";
		argv[i++] = out_path;
		if (have_lba) { argv[i++] = "--lba"; argv[i++] = lba; }
		if (cfg)      { argv[i++] = "--cfg"; argv[i++] = cfg; }
		if (ver)      { argv[i++] = "--core-version"; argv[i++] = ver; }
		argv[i] = 0;

		freopen("/tmp/dvd_report.log", "w", stdout);
		dup2(fileno(stdout), fileno(stderr));
		execvp("python3", (char * const *)argv);
		_exit(127);
	}

	child = p;
	InfoMessage("Generating support bundle...", 2000, "DVD");
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
		InfoMessage("Support bundle FAILED\nsee /tmp/dvd_report.log", 5000, "DVD");
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

	if (chord_since && !fired && child < 0 && (now_ms() - chord_since) >= HOLD_MS)
	{
		fired = 1;
		start();
	}
}
