// dvd_remote.cpp — see dvd_remote.h.

#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <time.h>

#include "dvd_remote.h"
#include "dvd_phys.h"
#include "dvd_launch.h"
#include "../../user_io.h"
#include "../../spi.h"
#include "../../menu.h"
#include "../../audio.h"
#include "../../hardware.h"   // GetTimer / CheckTimer (as dvd_hdmi_audio.cpp does)

#define UIO_DVD_AUDFMT   0x7B
#define DVD_TELEM_MAGIC  0xD7D1

// CMD_AF word (dvd/dvd_telem.sv): [12] = "this word carries [11:3]",
// [11:8] vol-down counter, [7:4] vol-up counter, [3] eject toggle.
#define AF_V3(w)        (((w) >> 12) & 1)
#define AF_EJECT_TGL(w) (((w) >>  3) & 1)
#define AF_VOLUP(w)     (((w) >>  4) & 0xF)
#define AF_VOLDN(w)     (((w) >>  8) & 0xF)

// ⚠ set_volume()'s convention, READ OFF ITS CALLERS rather than guessed:
// user_io.cpp:4274/4279 do set_volume(-1) for KEY_VOLUMEDOWN and set_volume(+1)
// for KEY_VOLUMEUP (and 0 toggles mute). Internally +1 DECREASES vol_att, i.e.
// less attenuation = louder. A first draft of this file used 1/2 for down/up,
// which would have turned the volume up in both directions -- the same mistake
// as ab_repeat's jump_dir, and the same fix: read the consumer's declaration.
#define VOL_CMD_UP    (+1)
#define VOL_CMD_DOWN  (-1)

// ★ Deliberately NOT gated on hasAPI1_5(), which guards Main's own media keys
// (user_io.cpp:4269-4280). That guard exists so old cores do not surprise a
// user pressing a keyboard's volume key; a button this core itself declares is
// an explicit request, and sys_top.v:442 implements UIO_AUDVOL regardless.

// A press burst must not turn into an unbounded run of steps if a poll is
// missed for a long time (a CSS crack blocks user_io_poll() for MINUTES, and
// the counters wrap at 16). Cap what one poll will apply.
#define VOL_MAX_PER_POLL 4

static int  have_ref = 0;          // we have seen a valid word and latched a baseline
static int  ref_eject = 0;
static int  ref_volup = 0;
static int  ref_voldn = 0;

static void rlog(const char *fmt, ...)
{
	FILE *f = fopen("/tmp/dvd_report.log", "a");
	if (!f) return;
	va_list ap; va_start(ap, fmt);
	vfprintf(f, fmt, ap); va_end(ap);
	fputc('\n', f);
	fclose(f);
}

void dvd_remote_tick(void)
{
	if (!is_dvd()) { have_ref = 0; return; }

	// Self-throttled like poll_audio_format(): user_io_poll() spins with no
	// sleep, so an unthrottled SPI transaction here would be thousands a second.
	static unsigned long next_at = 0;
	if (next_at && !CheckTimer(next_at)) return;
	next_at = GetTimer(20);

	uint16_t magic = spi_uio_cmd_cont(UIO_DVD_AUDFMT);
	uint16_t w     = spi_w(0);
	DisableIO();

	// An older core does not answer, or answers without the version bit. Either
	// way there are no requests to read -- drop the baseline so that loading a
	// newer core re-latches rather than diffing against a stale one.
	if (magic != DVD_TELEM_MAGIC || !AF_V3(w)) { have_ref = 0; return; }

	int e = AF_EJECT_TGL(w), u = AF_VOLUP(w), d = AF_VOLDN(w);

	// First valid word: latch a baseline and act on NOTHING. Whatever the
	// counters hold now is history -- acting on it would eject or change the
	// volume the instant a core loads.
	if (!have_ref)
	{
		have_ref = 1; ref_eject = e; ref_volup = u; ref_voldn = d;
		return;
	}

	// ---- volume: apply the DIFFERENCE since the last poll -----------------
	// 4-bit wrapping counters, so the difference is taken mod 16.
	int nu = (u - ref_volup) & 0xF;
	int nd = (d - ref_voldn) & 0xF;
	ref_volup = u; ref_voldn = d;

	if (nu > VOL_MAX_PER_POLL) nu = VOL_MAX_PER_POLL;
	if (nd > VOL_MAX_PER_POLL) nd = VOL_MAX_PER_POLL;

	// ⚠ set_volume() renders an on-screen bar via Info(), so it is UI work and
	// must not run while an MGL launch is still walking its state machine --
	// that is the issue #48 freeze. Skip the steps rather than queue them: a
	// volume press during a 2-second launch is not worth a deferred queue, and
	// the user can simply press again.
	if ((nu || nd) && !dvd_launch_ui_busy())
	{
		while (nu--) set_volume(VOL_CMD_UP);
		while (nd--) set_volume(VOL_CMD_DOWN);
	}

	// ---- eject: a toggle, so act on a CHANGE ------------------------------
	if (e != ref_eject)
	{
		ref_eject = e;
		// Eject unmounts and resets the core to the idle screen, which is a
		// large, visible action -- but it raises no Info() of its own, so the
		// launch gate applies only to being sure a launch is not mid-flight
		// with a mount of its own about to land.
		if (!dvd_launch_ui_busy())
		{
			int was_disc = dvd_phys_eject();
			rlog("DVD_REMOTE: eject button -- %s",
			     was_disc ? "optical disc unmounted + tray opened"
			              : "image unmounted");
		}
	}
}
