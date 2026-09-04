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

// Call from user_io_file_mount() with the path it was handed. Nothing else in
// Main keeps the full path of a mounted image: fileTYPE::name is the basename
// only, and fileTYPE::path is populated solely in the pre-create branch -- so a
// normally-mounted ISO has neither, and the bundle had nothing to work from.
// Observes only; the empty string (an unmount) clears it.
void dvd_report_note_mount(const char *path);

// Call from user_io_file_mount() just before it notifies the core, with what the
// mount actually achieved. Purely a log line, and it earns its keep: Main sends
// UIO_SET_SDSTAT even when the open FAILED (with size 0), and the core cannot
// tell that apart from a real mount by looking at the pulse. When a load produces
// a blank screen, this line is the difference between "the file never opened" and
// "the file opened and the core did nothing with it" -- which are fixed in
// completely different places. Issue #48; see docs/mgl_launch.md.
void dvd_report_note_mount_result(const char *path, int index, int ok, uint64_t size);

#endif
