// dvd_report.h — generate a navigation support bundle from the player itself.
//
// A DVD navigation bug is reproducible from the disc's IFO tables alone, which
// are tiny and unencrypted (see MiSTer_DVD/docs/bug_reports.md). tools/dvd_report.py
// packages them; normally a reporter runs it on a PC against their own rip.
//
// This module offers the same thing without a PC: hold a gamepad chord while the
// DVD core is running and the Main builds a bundle from whatever is currently
// mounted — an image file or the optical drive — and writes it to
// /media/fat/DVD_reports/ for the user to attach to an issue.
//
// It is worth having in the Main rather than only as a PC step for one reason
// beyond convenience: the Main knows the SECTOR BEING SERVED at the moment the
// user hit the chord, which is the one thing a reporter cannot state from memory.
// A bug reported as "somewhere in the menus" arrives with the exact cell.
//
// Design, and the alternatives that were rejected (an OSD row costs a fitter seed
// re-roll; a C++ collector would drift from the Python one):
// MiSTer_DVD/docs/support_bundle_hps.md.

#ifndef MISTER_DVD_REPORT_H
#define MISTER_DVD_REPORT_H

#include <stdint.h>

// Call from user_io_digital_joystick() with the button map, before it is sent on
// to the core. Observes only — the map is not modified, so the chord's own
// buttons still do their normal thing (one audio-track step and one subtitle
// step, both visible and both trivially undone).
void dvd_report_joy(uint32_t map);

// Call every user_io_poll. Fires the deferred generation once the chord has been
// held long enough, and reaps the child. Self-gates on is_dvd(); no-op otherwise.
//
// The work runs in a FORKED CHILD, never inline: this tick shares the poll loop
// with SD block service, and a bundle takes long enough that blocking here would
// starve the core mid-playback.
void dvd_report_tick(void);

#endif
