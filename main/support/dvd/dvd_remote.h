// dvd_remote.h — the DVD-remote buttons that only the HPS can service.
//
// Eject (B19) and Volume Up/Down (B20/B21) ask Main to do things the core
// cannot: Main owns the mount slot and the optical drive, and sys_top's
// vol_att is the framework's ONE attenuator (it covers I2S, the analog DAC
// and S/PDIF together, which is why volume is not a second gain stage in
// fabric).
//
// The requests ride the core's existing CMD_AF telemetry word (0x7B), whose
// layout dvd/dvd_telem.sv documents. Eject is a TOGGLE and the two volume
// requests are WRAPPING COUNTERS, because Main polls: a level would be re-read
// as a fresh request on every poll and one press would eject repeatedly.
//
// ⛔ This runs from user_io_poll(), so it must never raise Info/InfoMessage/
// ProgressMessage without checking dvd_launch_ui_busy() first -- that shape is
// what froze every input path on the machine in issue #48.

#ifndef DVD_REMOTE_H
#define DVD_REMOTE_H

// Called once per user_io_poll(). Self-throttled; does nothing on a non-DVD
// core, and nothing until the core answers CMD_AF with the version bit set.
void dvd_remote_tick(void);

#endif
