// dvd_launch.h — what the MiSTer launch sequence is doing, for the DVD overlay.
//
// Exists because of issue #48 ("MGL loading not working"): an MGL launch puts
// HandleUI() into a branch that never calls menu_key_get(), which is the SOLE
// source of every input event -- keyboard menu key, gamepad menu key, the
// physical OSD button and the core's own virtual one. So for as long as the MGL
// state machine has not finished, the MiSTer accepts NO input at all, and the
// MGL's only forward edge (menu.cpp, "menustate == MENU_NONE2 && mgl->state==1")
// is blocked by anything that moves menustate elsewhere.
//
// InfoMessage() moves it: it pins menustate = MENU_INFO. Two DVD overlay pumps
// call InfoMessage once a second from user_io_poll(), BEFORE HandleUI runs, so
// an MGL firing inside one of those windows stalls -- nothing mounts and nothing
// responds. See docs/mgl_launch.md.
//
// Two services here:
//   dvd_launch_ui_busy()  - "do not raise an on-screen notice right now".
//   dvd_launch_tick()     - a watchdog so a stalled MGL costs a failed load,
//                           never a reboot.

#ifndef DVD_LAUNCH_H
#define DVD_LAUNCH_H

// 1 while an MGL launch is still running. Any overlay code that would call
// Info()/InfoMessage()/ProgressMessage() from a user_io_poll() tick MUST check
// this first and defer -- see the pumps in dvd_css.cpp and dvd_hdmi_audio.cpp
// for the pattern (hold the window open, do not consume it).
int dvd_launch_ui_busy(void);

// Called once per user_io_poll(). Bounds how long an MGL may sit unfinished.
void dvd_launch_tick(void);

#endif
