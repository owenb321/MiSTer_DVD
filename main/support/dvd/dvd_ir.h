// dvd_ir.h — normalise an IR receiver's / media keyboard's keycodes into the
// ordinary keys this core already binds.
//
// WHY THIS EXISTS. A remote reaches Main as an ordinary keyboard, and stock
// Main then drops nearly everything it sends. Three stacked ceilings, all
// measured against the pinned stock tree:
//
//   1. input.cpp:3602  `ev->code >= 256` is routed to the JOYSTICK BUTTON
//      handler and never reaches the keyboard path at all. That is 39 of the
//      63 keycodes a Media Center receiver emits -- Title, Subtitle, Audio,
//      DVD, Info, Next/Prev and the whole numeric pad.
//   2. input.cpp:1409  get_ps2_code() returns NONE for key > 255.
//   3. input.cpp:367   ev2ps2[] is 256 entries AND most media keys are NONE
//      in it anyway: PLAY, STOP, REWIND, FASTFORWARD, PLAYPAUSE, EJECTCD,
//      EXIT, MEDIA ... all silently dropped.
//
// Net effect without this module: arrows, Enter and volume work. Nothing else
// does -- on any remote, not just Media Center ones.
//
// ★ THE TABLE IS KEYED ON LINUX KEYCODES, WHICH IS THE VENDOR-NEUTRAL LAYER.
// That is what makes one table serve every "flavour": RC6 Media Center
// handsets, NEC clones, a Flirc's profiles, 2.4 GHz RF media remotes, HDMI-CEC
// and plain USB media keyboards all converge on the same KEY_* set.
//
// ⚠ SCOPE. This cannot help a receiver the kernel never turns into an input
// device. MiSTer's kernel ships no IR support at all (no CONFIG_RC_CORE on any
// kernel line), so an eHome/mceusb receiver produces no /dev/input node and
// there is nothing here to remap. That is a kernel matter, not a core one --
// dvd_ir_probe_summary() reports it, and the manual documents both the
// supported path (a receiver that presents as a USB HID keyboard) and the DIY
// kernel-module route for users who want their mceusb dongle to work.
//
// ⛔ Volume and mute are DELIBERATELY NOT REMAPPED. Main already drives the
// framework's ONE attenuator (sys_top.v vol_att, covering I2S, the analog DAC
// and S/PDIF together) from user_io.cpp:4266-4280. A second route would desync
// from the OSD bar and could not touch passthrough at all. See ir_deny[].

#ifndef DVD_IR_H
#define DVD_IR_H

#include <stdint.h>

// Is the remap live? Cheap -- this is called for every EV_KEY event.
// Gated by cfg.dvd_ir_remap (0 = on for the DVD core, 1 = off, 2 = on for
// every core) and, in mode 0, by is_dvd(). Runs the one-shot probe.
//
// ★ No caching here on purpose, and it is not an oversight to "fix" later:
// stock is_dvd() already memoises (user_io.cpp:428 -- one strcasecmp ever,
// then an int compare), and cfg.dvd_ir_remap is a byte. A local cache would
// add a staleness bug for nothing. The probe is the only costly part, and it
// is one-shot; Main re-execs on a core load, so one-shot per process IS
// one-shot per core load.
int dvd_ir_active(void);

// The replacement keycode for `code`, or 0 to leave the event alone.
// `osd_open` selects the second column: a row may want a different key while
// the MiSTer OSD is up (Back cancels rather than going up a disc level), and a
// row with no OSD opinion passes through UNTOUCHED rather than being
// suppressed.
uint16_t dvd_ir_target(uint16_t code, int osd_open);

// One line for the log/support bundle: table size, cfg mode, and whether the
// kernel has any IR support at all.
const char *dvd_ir_probe_summary(void);

#endif
