// dvd_launch.cpp — see dvd_launch.h.

#include <stdio.h>
#include <stdarg.h>
#include <time.h>

#include "../../user_io.h"
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

int dvd_launch_ui_busy(void)
{
	return !mgl_get()->done;
}

void dvd_launch_tick(void)
{
	static time_t pending_since = 0;
	static int    fired         = 0;

	mgl_struct *mgl = mgl_get();

	if (mgl->done)
	{
		// Re-arm for a hypothetical second MGL in the same process. `fired`
		// deliberately does NOT reset: once the watchdog has spoken, saying it
		// again adds nothing and the log stays readable.
		pending_since = 0;
		return;
	}

	time_t now = time(NULL);
	if (!pending_since) { pending_since = now; return; }
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
}
