// dvd_report_test.cpp — the argv handed to tools/dvd_report.py by the chord.
//
// WHY A DECISION THIS SMALL IS WORTH A TEST
//
// Every failure here is SILENT. A missing or misspelled flag still produces a
// bundle: it is written, it self-checks, it looks complete, and it is simply
// missing the data the report needed. That is exactly how issue #81 arrived — a
// menu-highlight bug whose bundle carried no button data at all, with nothing
// anywhere to say so. The diagnosis had to be made structurally from the IFO
// tables instead, and the confirm was never in evidence.
//
// So the argv is built by dvd_report_build_argv() outside the fork, and this pins
// it. The arms that matter are the ones about --nav-window:
//   * it must be passed when there IS a playhead, because that window is the only
//     capture that reaches an in-title menu's buttons (--nav-packs scans menu VOBs
//     and structurally cannot see a title-domain menu);
//   * it must NOT be passed when there is not, because there is nothing to window
//     around and the tool would be given a meaningless base.
//
// The module is #included rather than linked so the builder is reachable with the
// surrounding Main replaced wholesale.

#include <stdio.h>
#include <string.h>
#include <stdint.h>

// ---------------------------------------------------------------- fake world
// dvd_report.cpp reaches into Main for the chord, the mount and the OSD. None of
// that is exercised here, but it all has to resolve, so stub it before the
// include and let the real module compile against these.
struct fileTYPE;

static int          fake_is_dvd = 1;
static const char  *fake_osdname = "DVD dev-subpmapdom 260912";
static uint64_t     fake_last_lba = 0;

static int   is_dvd(void)                              { return fake_is_dvd; }
static const char *OsdCoreNameGet(void)                { return fake_osdname; }
static uint64_t user_io_last_lba(int)                  { return fake_last_lba; }
static void  InfoMessage(const char *, int, const char * = 0) {}
static unsigned long GetTimer(unsigned long d)         { return d; }
static int   CheckTimer(unsigned long)                 { return 1; }
static const char *getRootDir(void)                    { return "/media/fat"; }

// Declared by the real dvd_css.h / dvd_phys.h the module includes, so these are
// DEFINITIONS of those, not shadowing stubs -- the linker takes them.
int         dvd_css_active(void)                       { return 0; }
const char *dvd_phys_device(void)                      { return 0; }

#define DVD_REPORT_TEST 1
#include "dvd_report.cpp"

// ------------------------------------------------------------------ helpers
static int errors = 0;

static int idx_of(const char **argv, const char *flag)
{
    for (int i = 0; i < DVD_REPORT_ARGV_MAX && argv[i]; i++)
        if (!strcmp(argv[i], flag)) return i;
    return -1;
}

// Every slot is pre-filled with a sentinel and the array is scanned only as far
// as DVD_REPORT_ARGV_MAX, so a builder that forgets its terminator is DETECTED
// rather than walked past -- otherwise the helpers below read stale memory and
// the failure surfaces as unrelated noise in an earlier arm.
static const char SENTINEL[] = "<unwritten>";

static int build(const char **argv, const char *script, const char *src,
                 const char *out, const char *lba, const char *cfg,
                 const char *ver)
{
    for (int i = 0; i < DVD_REPORT_ARGV_MAX; i++) argv[i] = SENTINEL;
    dvd_report_build_argv(argv, script, src, out, lba, cfg, ver);
    for (int i = 0; i < DVD_REPORT_ARGV_MAX; i++)
        if (!argv[i]) return i;
    errors++;
    printf("  FAIL argv is not NUL-terminated within DVD_REPORT_ARGV_MAX (%d)\n",
           DVD_REPORT_ARGV_MAX);
    return -1;
}

static int argc_of(const char **argv)
{
    for (int i = 0; i < DVD_REPORT_ARGV_MAX; i++)
        if (!argv[i]) return i;
    return -1;
}

static void want_absent(const char **argv, const char *flag, const char *what)
{
    if (idx_of(argv, flag) >= 0) {
        errors++;
        printf("  FAIL %s: %s must NOT be passed\n", what, flag);
    }
}

static void want_pair(const char **argv, const char *flag, const char *value,
                      const char *what)
{
    int i = idx_of(argv, flag);
    if (i < 0) {
        errors++;
        printf("  FAIL %s: %s is missing\n", what, flag);
        return;
    }
    if (!argv[i + 1] || strcmp(argv[i + 1], value)) {
        errors++;
        printf("  FAIL %s: %s = \"%s\" (want \"%s\")\n",
               what, flag, argv[i + 1] ? argv[i + 1] : "(end)", value);
    }
}

int main(void)
{
    const char *argv[DVD_REPORT_ARGV_MAX];

    // ---- [0] terminated, and inside the bound -----------------------------
    // FIRST, because execvp reads until the NUL: without it every other arm here
    // is reading stale memory and would report the failure as something else.
    // build() pre-fills the array with a sentinel, so this is a real detection
    // rather than a walk off the end.
    int n0 = build(argv, "s.py", "/dev/sr0", "/o.zip", "1", "c", "v");
    if (n0 >= 0) {
        if (n0 + 1 > DVD_REPORT_ARGV_MAX) {
            errors++;
            printf("  FAIL [0] bounds: %d entries + NUL exceeds DVD_REPORT_ARGV_MAX %d\n",
                   n0, DVD_REPORT_ARGV_MAX);
        }
        printf("  [0] bounds: fullest case %d entries + NUL, max %d\n",
               n0, DVD_REPORT_ARGV_MAX);
    }

    // ---- [1] the full case: a playhead, a CFG and a version ---------------
    // --nav-window is the arm this test exists for. 2048 sectors is ~4 MB, one
    // sequential run, measured at 0.28 s end to end and a 38 KB bundle.
    build(argv, "/media/fat/Scripts/dvd_report.py", "/dev/sr0",
          "/media/fat/DVD_reports/x.zip", "903500",
          "/media/fat/config/DVD_v2.CFG", "dev-subpmapdom 260912");
    want_pair(argv, "--lba", "903500", "[1] full");
    want_pair(argv, "--nav-window", "2048", "[1] full");
    want_pair(argv, "--cfg", "/media/fat/config/DVD_v2.CFG", "[1] full");
    want_pair(argv, "--core-version", "dev-subpmapdom 260912", "[1] full");
    want_pair(argv, "-o", "/media/fat/DVD_reports/x.zip", "[1] full");
    want_pair(argv, "--generated-on", "mister", "[1] full");
    if (idx_of(argv, "--no-prompt") < 0) {
        errors++;
        printf("  FAIL [1] full: --no-prompt is missing (the child has no tty)\n");
    }
    // The image/device is positional and must be argv[2], after python3 and the
    // script -- a flag inserted ahead of it would make the tool read the script
    // as its disc.
    if (argc_of(argv) < 3 || strcmp(argv[2], "/dev/sr0")) {
        errors++;
        printf("  FAIL [1] full: argv[2] = \"%s\" (want the source path)\n",
               argc_of(argv) > 2 ? argv[2] : "(end)");
    }
    // --nav-packs is the EXPENSIVE capture and must never be here: measured 4.9 s
    // and 5.6 MB on MEN_IN_BLACK locally, which on the optical disc the core is
    // streaming from means minutes of seeking.
    want_absent(argv, "--nav-packs", "[1] full");
    printf("  [1] full argv: %d entries, --nav-window 2048 present\n", argc_of(argv));

    // ---- [2] no playhead: no window ---------------------------------------
    // A linear image mounted with no served sector yet. There is nothing to
    // window around, so the flag must be omitted rather than passed a base of 0
    // -- which would silently capture the NAV packs at the START of the disc,
    // i.e. confidently wrong data rather than none.
    build(argv, "s.py", "/media/fat/x.iso", "/o.zip", 0, 0, 0);
    want_absent(argv, "--lba", "[2] no playhead");
    want_absent(argv, "--nav-window", "[2] no playhead");
    want_absent(argv, "--cfg", "[2] no playhead");
    want_absent(argv, "--core-version", "[2] no playhead");
    if (argc_of(argv) != 8) {
        errors++;
        printf("  FAIL [2] no playhead: %d entries (want the 8 unconditional ones)\n",
               argc_of(argv));
    }
    printf("  [2] no playhead: %d entries, no --lba and no --nav-window\n",
           argc_of(argv));

    // ---- [3] a playhead but nothing else ----------------------------------
    // The window rides the playhead, not the CFG or the version: a disc reported
    // from a build whose OSD name carried no V line must still capture buttons.
    build(argv, "s.py", "/dev/sr1", "/o.zip", "12", 0, 0);
    want_pair(argv, "--lba", "12", "[3] lba only");
    want_pair(argv, "--nav-window", "2048", "[3] lba only");
    want_absent(argv, "--cfg", "[3] lba only");
    printf("  [3] playhead only: --nav-window still present\n");

    if (errors) {
        printf("dvd_report_test: %d FAILURE(S)\n", errors);
        return 1;
    }
    printf("dvd_report_test: ALL GREEN (4 arms)\n");
    return 0;
}
