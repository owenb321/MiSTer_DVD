// dvd_launch.cpp — see dvd_launch.h.

#include <stdio.h>
#include <stdarg.h>
#include <time.h>
#include <string.h>

#include "../../user_io.h"
#include "../../menu.h"
#include "../arcade/mra_loader.h"
#include "dvd_launch.h"

#define DVD_LAUNCH_LOG "/tmp/dvd_report.log"

// The MGL state machine has no timeout of its own: states 1 and 2 are advanced
// only by the menustate FSM, so every way that FSM can fail to reach the right
// case is an unbounded stall with all input dead. 20 s is far longer than any
// legitimate MGL (the delay= attribute is seconds and the dispatch itself takes
// a handful of HandleUI iterations), and short enough that a user reaches for
// the OSD rather than the power switch.
#define DVD_MGL_WD_S 20

static void launch_log(const char *fmt, ...)
{
	va_list ap;
	FILE *f = fopen(DVD_LAUNCH_LOG, "a");
	if (!f) return;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fprintf(f, "\n");
	fclose(f);
}

void dvd_launch_note_status(const char *opt, unsigned value)
{
	if (!opt) return;

	// Only the reset bit, and only for our core. Every other status write is an
	// ordinary OSD option change and would bury the one line that matters.
	// "[0]" is what dvd_phys and the framework pass; the generic menu hands the
	// option string past its type letter, so an "R0,Reset" row arrives as
	// "0,Reset".
	int is_bit0 = !strncmp(opt, "[0]", 3) ||
	              (opt[0] == '0' && (opt[1] == 0 || opt[1] == ','));
	if (!is_bit0 || !is_dvd()) return;

	launch_log("DVD_LAUNCH: status[0] <= %u (opt \"%s\", mgl done=%d)",
	           value, opt, mgl_get()->done);
}

int dvd_launch_ui_busy(void)
{
	return !mgl_get()->done;
}

void dvd_launch_tick(void)
{
	static time_t pending_since = 0;
	static time_t last_tick     = 0;
	static int    fired         = 0;

	mgl_struct *mgl = mgl_get();
	time_t now = time(NULL);

	// ⚠ Measure only time the poll loop was actually TURNING. Several things
	// legitimately block user_io_poll() for minutes -- a CSS title-key crack is
	// the one that bites here: dvd_phys_tick() mounts an optical disc on the very
	// first poll, long before a delay=N MGL fires, and crack_title_keys() then
	// runs synchronously for minutes on an uncached disc. Wall-clock timing would
	// read that as a stall and kill a perfectly healthy pending MGL, losing the
	// user's auto-load to a fix meant to protect it. A gap between ticks means we
	// were not running, so it cannot be time the MGL spent stuck.
	time_t gap = (last_tick && now > last_tick) ? (now - last_tick) : 0;
	last_tick = now;

	if (mgl->done)
	{
		// Re-arm for a hypothetical second MGL in the same process. `fired`
		// deliberately does NOT reset: once the watchdog has spoken, saying it
		// again adds nothing and the log stays readable.
		pending_since = 0;
		return;
	}

	if (!pending_since) { pending_since = now; return; }
	if (gap > 1) pending_since += gap;              // discount the blocked span
	if (now - pending_since < DVD_MGL_WD_S) return;

	// Stalled. Give the user their input back. The load is lost either way;
	// what this buys is that the OSD, the gamepad and the menu key come alive
	// so the file can be picked by hand instead of power-cycling the board.
	if (!fired)
	{
		fired = 1;
		launch_log("DVD_LAUNCH: MGL stalled %ds in state=%d current=%d/%d -- releasing the UI",
		           (int)(now - pending_since), mgl->state, mgl->current, mgl->count);
		printf("DVD_LAUNCH: MGL stalled in state %d, releasing the UI\n", mgl->state);
	}
	mgl->done = 1;
	pending_since = 0;

	// Leave the menu FSM somewhere sane. Without this the stall is usually
	// abandoned in MENU_GENERIC_MAIN2 with the OSD disabled (an MGL opens the
	// menu invisibly), so the user's first Menu press is spent closing a menu
	// they cannot see. MenuHide() re-enters HandleUI once -- the same thing
	// InfoMessage does, and by now mgl->done is 1, so it takes the ordinary
	// branch.
	MenuHide();
}
