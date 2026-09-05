// dvd_ctl.h — host control + telemetry channel for the DVD core.
//
// Two jobs, both driven from user_io_poll() via dvd_ctl_tick():
//
//   TELEMETRY  reads the core's pacing counters over the hps_io EXT_BUS
//              extension (command 0x7A, see dvd/dvd_telem.sv) and publishes
//              them as /tmp/dvd_telem.json for tools/mister.py. This exists so
//              A/V pacing can be MEASURED directly instead of decoded from a
//              photographed debug overlay -- and so getting telemetry does not
//              cost a rebuild and a fitter-seed re-roll every time.
//
//   COMMANDS   a non-blocking FIFO at /tmp/dvd_ctl accepting one line each:
//                osd <opt> <value>   set an OSD option live (no relaunch)
//                mount <path>        mount an image (no relaunch)
//                ping
//              Live OSD changes matter because the saved-settings file is read
//              once at core init, so A/B-ing a setting otherwise costs a full
//              relaunch and loses the playback position.
//
// ⚠ Both run on the poll thread, which is also the core's SD block service.
// Blocking I/O here is a video artefact, not a latency nit (see the dvd_phys
// drive-scan post-mortem in docs/mgl_launch.md), so the FIFO is opened
// O_NONBLOCK and the JSON write is throttled and goes to tmpfs.
//
// ⚠ Never raise Info()/InfoMessage() from here: while an MGL is pending,
// HandleUI() skips menu_key_get() entirely and an info popup wedges all input
// (issue #48). Nothing in this module talks to the UI at all.

#ifndef DVD_CTL_H
#define DVD_CTL_H

void dvd_ctl_tick();

#endif
