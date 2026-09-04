// dvd_phys_test.cpp — the slot-ownership rules for the optical drive.
//
// dvd_phys shares slot 0 with every image the user can load, and it got that
// wrong twice in one field report (an MGL launch with a disc in the drive):
//
//   - it auto-mounted the disc on the first poll, so a .mpg named by an MGL
//     waited minutes for CSS key extraction nobody asked for, on a disc that was
//     then replaced by the file anyway;
//   - `mounted` meant "we mounted a disc at some point", not "we still own the
//     slot", so ejecting a disc nobody was watching unmounted the file that WAS
//     playing -- freezing it -- and reset the core.
//
// Those are five interacting flags (mounted / foreign / prev_ready /
// probed_not_video / the launch gate) over a handful of discrete events, which is
// precisely the shape that regresses without anyone noticing. This runs on the
// host: build with main/tests/run_tests.sh.
//
// MEASURED against the pre-fix module (no foreign/ui_busy/probe gating, `mounted`
// sticky) -- both field symptoms reproduce:
//   [1] disc reads while the MGL is pending   1  (expect 0)   FAIL  } "waits for key
//   [1] mounts while the MGL is pending       1  (expect 0)   FAIL  }  extraction first"
//   [3] unmounts on eject                     1  (expect 0)   FAIL  } "playback freezes
//   [3] core resets on eject                  1  (expect 0)   FAIL  }  when the disc is out"
//   [7] disc reads over six scans             6  (expect 1)   FAIL
// [4]-[6] pass either way: they are the controls that stop the fix over-reaching,
// because every one of these bugs is trivially "fixed" by never mounting a disc.
//
// The module is #included rather than linked so the drive scan can be replaced;
// everything else is stubbed at link time. See the DVD_PHYS_TEST seam in
// dvd_phys.cpp -- it is the only conditional line in the module.

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <sys/time.h>
#include <unistd.h>

#include "dvd_phys.h"      // staged on the include path by run_tests.sh

// ---------------------------------------------------------------- fake world
static int  fake_disc_ready   = 0;   // the drive reports a disc ready
static int  fake_disc_is_dvd  = 1;   // ...and it is DVD-Video
static int  fake_launch_busy  = 0;   // an MGL launch is pending
static int  probe_calls       = 0;   // how often we READ the disc
static int  mount_calls       = 0;
static int  reset_asserts     = 0;
static char last_mount[256]   = {0};
static int  scan_calls        = 0;   // how often the drive was probed for readiness
static unsigned fake_probe_ms = 0;   // how long that probe takes (a stalled drive)
static unsigned fake_ms       = 0;   // the millisecond clock the module measures with

#define DVD_PHYS_TEST 1
static int open_ready_drive(char *out, int out_sz)
{
    scan_calls++;
    fake_ms += fake_probe_ms;         // blocking I/O: the clock moves inside the call
    if (!fake_disc_ready) return -1;
    if (out && out_sz > 0) { strncpy(out, "/dev/sr0", out_sz - 1); out[out_sz-1] = 0; }
    return 99;                        // a token fd; close(99) is a harmless EBADF
}

// ------------------------------------------------------------------- stubs
// Defined BEFORE the module is included, so they are in scope by the time its own
// "../../user_io.h" (staged empty on purpose) would have declared them. That is
// why there is no second copy of Main's API here to drift out of date.
char is_dvd() { return 1; }
int  dvd_video_probe(int) { probe_calls++; return fake_disc_is_dvd; }
void dvd_css_close(void) {}
int  dvd_launch_ui_busy(void) { return fake_launch_busy; }

int user_io_file_mount(const char *name, unsigned char index = 0, char = 0, int = 0)
{
    mount_calls++;
    snprintf(last_mount, sizeof(last_mount), "%s", name ? name : "");
    dvd_phys_note_mount(name, index);   // Main calls this at the top of the real one
    return 1;
}
void user_io_status_set(const char *name, uint32_t value, int = 0)
{
    if (!strcmp(name, "[0]") && value) reset_asserts++;
}

// The module reads the wall clock; the harness owns it so every tick is a real
// scan rather than one the 1 Hz gate throws away. Defined after <time.h> so the
// macro cannot mangle the real declaration.
static time_t fake_now = 1000;
#define time(p) (fake_now)
#define gettimeofday(tv, tz) (((tv)->tv_sec = fake_ms / 1000), \
                              ((tv)->tv_usec = (fake_ms % 1000) * 1000), 0)

#include "dvd_phys.cpp"

// ------------------------------------------------------------------ harness
static int errs = 0;
static void check(const char *what, long got, long want)
{
    if (got != want) { printf("  FAIL %-46s got %ld, want %ld\n", what, got, want); errs++; }
    else             { printf("  ok   %-46s %ld\n", what, got); }
}

// The tick rate-limits itself, and the period varies (1 s normally, 5 s while
// somebody else owns the slot, backing off further if the drive probe turns out to
// be slow). So the harness walks the clock in seconds and lets the module decide
// when to scan, rather than assuming one tick == one scan.
static void run_for(int seconds)
{
    for (int i = 0; i < seconds; i++) { fake_now += 1; dvd_phys_tick(); }
}

// How long a disc may sit in the drive before we notice it. The scan backs off to
// at most this, so nothing may take longer.
#define NOTICE_WINDOW_S 10

static void reset_counters(void)
{
    probe_calls = mount_calls = reset_asserts = 0; last_mount[0] = 0;
}

int main(void)
{
    printf("=== [1] MGL launch with a disc in the drive: no disc reads, no mount ===\n");
    fake_disc_ready = 1; fake_launch_busy = 1;
    reset_counters();
    run_for(5);                                // five seconds of MGL delay
    check("[1] disc reads while the MGL is pending", probe_calls, 0);
    check("[1] mounts while the MGL is pending",     mount_calls, 0);

    printf("=== [2] the MGL mounts its file: the drive stands down for good ===\n");
    dvd_phys_note_mount("/media/fat/cifs/Movies/Terminator.mpg", 0);
    fake_launch_busy = 0;
    reset_counters();
    run_for(30);                               // half a minute, disc still sitting there
    check("[2] disc reads after the file is mounted", probe_calls, 0);
    check("[2] mounts after the file is mounted",     mount_calls, 0);

    printf("=== [3] ejecting that disc must not touch the playing file ===\n");
    reset_counters();
    fake_disc_ready = 0;
    run_for(NOTICE_WINDOW_S);
    check("[3] unmounts on eject",       mount_calls,   0);
    check("[3] core resets on eject",    reset_asserts, 0);

    printf("=== [4] inserting a disc afterwards still plays it ===\n");
    reset_counters();
    fake_disc_ready = 1;
    run_for(NOTICE_WINDOW_S);
    check("[4] disc reads (probed once)", probe_calls, 1);
    check("[4] mounts",                   mount_calls, 1);
    if (strcmp(last_mount, DVD_PHYS_SENTINEL)) {
        printf("  FAIL [4] mounted %s, want the drive sentinel\n", last_mount); errs++;
    } else printf("  ok   [4] mounted the drive sentinel\n");

    printf("=== [5] ejecting the disc WE are playing does reset to idle ===\n");
    reset_counters();
    fake_disc_ready = 0;
    run_for(NOTICE_WINDOW_S);
    check("[5] unmounts", mount_calls, 1);
    check("[5] resets",   reset_asserts, 1);
    if (last_mount[0]) { printf("  FAIL [5] unmount path passed %s, want \"\"\n", last_mount); errs++; }
    else printf("  ok   [5] unmounted with an empty path\n");

    printf("=== [6] plain launch, disc in the drive: mounts, probing once ===\n");
    reset_counters();
    fake_disc_ready = 1;
    run_for(NOTICE_WINDOW_S);
    check("[6] disc reads over ten seconds", probe_calls, 1);
    check("[6] mounts",                      mount_calls, 1);

    printf("=== [7] an audio CD is probed once per insertion, not once a second ===\n");
    // eject the DVD, then present a non-DVD-Video disc
    fake_disc_ready = 0; run_for(NOTICE_WINDOW_S);
    reset_counters();
    fake_disc_is_dvd = 0; fake_disc_ready = 1;
    run_for(30);
    check("[7] disc reads over half a minute", probe_calls, 1);
    check("[7] mounts",                        mount_calls, 0);

    printf("=== [8] a slow drive probe must back off ===\n");
    // The field case: a .mpg is playing, the tray is OPEN, and every probe costs
    // hundreds of ms on the same thread that feeds the decoder. Un-backed-off that
    // is ~60 blocking calls a minute, which is what froze the picture.
    fake_disc_ready = 0; run_for(NOTICE_WINDOW_S);
    dvd_phys_note_mount("/media/fat/cifs/Movies/Terminator.mpg", 0);
    fake_disc_is_dvd = 1;
    fake_probe_ms = 400;                       // an open tray, retrying
    reset_counters(); scan_calls = 0;
    run_for(60);
    if (scan_calls > 12) { printf("  FAIL [8] %d probes in 60 s, want <= 12\n", scan_calls); errs++; }
    else printf("  ok   [8] probes in 60 s of a stalled drive       %d (was 60)\n", scan_calls);

    printf("=== [9] ...and recovers once the drive settles ===\n");
    fake_probe_ms = 0;
    run_for(NOTICE_WINDOW_S);                  // let one fast probe reset the backoff
    scan_calls = 0;
    run_for(20);
    // foreign is still set (the .mpg is playing), so the floor is the 5 s
    // insertion-watch period, not 1 s. Four scans is the whole point: fast enough
    // to notice a disc, rare enough to be invisible.
    if (scan_calls < 4) { printf("  FAIL [9] %d probes in 20 s, want >= 4\n", scan_calls); errs++; }
    else printf("  ok   [9] probes in 20 s of a healthy drive       %d\n", scan_calls);

    printf("\n=== dvd_phys tests: %d error(s) ===\n", errs);
    if (errs) { printf("FAILED\n"); return 1; }
    printf("PASS\n");
    return 0;
}
