// dvd_hdmi_audio.cpp — HDMI IEC 61937 bitstream support for the DVD core.
// See dvd_hdmi_audio.h and MiSTer_DVD/docs/hdmi_bitstream.md.

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#include "../../user_io.h"
#include "../../video.h"
#include "../../cfg.h"
#include "../../hardware.h"
#include "../../menu.h"
#include "dvd_hdmi_audio.h"
#include "dvd_launch.h"

// ---------------------------------------------------------------------------
// EDID: does the sink actually accept a compressed bitstream?
// ---------------------------------------------------------------------------
// Stock Main never looks at audio capability - edid_parse_cea_ext() walks the
// CEA data blocks but only handles tags 0x03/0x07 for VRR, so tag 0x01 (the
// Audio Data Block) falls straight through. Rather than patch that function we
// re-walk the blocks here off the exported buffer, which keeps video.cpp's diff
// to the two things that genuinely need to live there.
//
// Getting this wrong in the permissive direction is the bad failure: telling a
// plain TV to expect non-PCM and then feeding it a data burst is noise. So the
// test is deliberately strict - the sink must NAME AC-3 or DTS and claim 48 kHz.

#define SAD_FMT_AC3   2
#define SAD_FMT_DTS   7

static int scan_sads(const uint8_t *edid, int size)
{
	if (!edid || size < 256) return 0;
	if (edid[126] == 0) return 0;                 // no extension blocks at all

	int nblocks = edid[126];
	for (int b = 1; b <= nblocks; b++)
	{
		int off = 128 * b;
		if (off + 128 > size) break;              // truncated: stop, don't guess
		const uint8_t *cea = edid + off;

		if (cea[0] != 0x02) continue;             // not a CEA extension
		int dtd = cea[2];                         // start of the detailed timings
		if (dtd < 4 || dtd > 128) continue;       // malformed header

		int p = 4;
		while (p < dtd)
		{
			int tag = (cea[p] >> 5) & 0x07;
			int len = cea[p] & 0x1F;
			if (len == 0 || p + 1 + len > dtd) break;

			if (tag == 0x01)                      // Audio Data Block
			{
				// 3-byte Short Audio Descriptors
				for (int s = p + 1; s + 2 < p + 1 + len; s += 3)
				{
					int fmt   = (cea[s] >> 3) & 0x0F;
					int rates = cea[s + 1];
					// bit 2 = 48 kHz, which is the only rate DVD bitstream uses
					if ((fmt == SAD_FMT_AC3 || fmt == SAD_FMT_DTS) && (rates & 0x04))
						return 1;
				}
			}
			p += 1 + len;
		}
	}
	return 0;
}

static int sink_supports_bitstream(void)
{
	static int cached_ver = -1;
	static int cached_ok  = 0;

	uint8_t *buf = 0;
	int size = 0;
	int ver = video_get_edid(&buf, &size);
	if (ver != cached_ver)
	{
		cached_ver = ver;
		cached_ok  = scan_sads(buf, size);
		printf("dvd_hdmi_audio: EDID v%d - sink %s AC-3/DTS bitstream\n",
		       ver, cached_ok ? "ACCEPTS" : "does NOT accept");
	}
	return cached_ok;
}

// ---------------------------------------------------------------------------
// State machine
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Self-reporting. The failure this feature can produce is ambiguous from the
// listening position: "receiver says PCM, no sound" looks identical whether the
// custom Main never ran, the core never declared, EDID said no, or the chip was
// configured and the receiver could not parse our subframes. Rather than make
// the user iterate blind, say on screen which stage was reached.
#define HDMI_LOG_PATH "/tmp/dvd_hdmi_audio.log"

static const char *stage_msg = 0;
static time_t      show_until = 0;

// ⚠ InfoMessage renders nothing unless the menu FSM is idle, and the user changes
// Audio Out from INSIDE the OSD - so a single call at the transition is dropped
// every time. dvd_css hit this exact trap with its libdvdcss popup and solved it
// by re-asserting once a second until the launch settles; do the same. The log
// file is the reliable channel regardless of menu state.
//
// ⚠ "Dropped" is the WRONG word for the idle case and that mistake cost issue #48:
// when menustate IS idle, InfoMessage does not no-op, it PINS menustate = MENU_INFO.
// See report_pump() below.
static void report(const char *msg)
{
	if (stage_msg == msg) return;      // only on transition
	stage_msg  = msg;
	show_until = time(NULL) + 6;       // re-assert until the OSD closes
	printf("dvd_hdmi_audio: %s\n", msg);
	FILE *f = fopen(HDMI_LOG_PATH, "a");
	if (f) { fprintf(f, "%s\n", msg); fclose(f); }
}

// ⚠ InfoMessage() PINS menustate = MENU_INFO. An MGL launch advances only out of
// MENU_NONE2, and while it has not finished HandleUI() never calls menu_key_get()
// — the sole source of every input event. So a notice raised from this tick froze
// both the load and the whole UI: issue #48. Defer while the launch is running,
// pushing the window along rather than spending it. See docs/mgl_launch.md.
static void report_pump(void)
{
	if (!show_until || !stage_msg) return;
	time_t now = time(NULL);
	if (now >= show_until) { show_until = 0; return; }
	if (dvd_launch_ui_busy()) { show_until = now + 2; return; }

	static time_t last = 0;
	if (now != last)                   // 2 s timeout bridges the 1 s cadence
	{
		last = now;
		InfoMessage(stage_msg, 2000, "HDMI Audio");
	}
}

// The core reports what the audio wire is really carrying, which is NOT what the
// OSD bit says: in Passthru an LPCM or MP2 track is decoded and leaves as linear
// PCM, and the ADV7513 must be taken OUT of non-PCM mode for it or the sink
// renders PCM as a data burst -- full-scale noise.
//
// ⚠ Its own SPI command (0x7B), not the 0x7A telemetry snapshot: that one's
// reader is gated behind /media/fat/dvd_hil, so a feature depending on it would
// work only on a hardware-in-the-loop rig. Self-limited to ~20 ms because
// user_io_poll() spins with no sleep, and a format change is a track switch --
// rare, and already accompanied by a receiver re-lock.
#define UIO_DVD_AUDFMT   0x7B
#define DVD_TELEM_MAGIC  0xD7D1

static int core_pcm_session = 0;   // 1 = Passthru is carrying PCM content
static int core_bs_session  = 0;   // 1 = Passthru is carrying AC-3/DTS right now
static int core_fmt_v2      = 0;   // the core reports bs_session at all

static void poll_audio_format(void)
{
	static unsigned long next_at = 0;
	if (next_at && !CheckTimer(next_at)) return;
	next_at = GetTimer(20);

	uint16_t magic = spi_uio_cmd_cont(UIO_DVD_AUDFMT);
	uint16_t fmt   = spi_w(0);
	DisableIO();

	// An older core does not answer this command; leave the format unknown and
	// behave exactly as before rather than guessing.
	if (magic != DVD_TELEM_MAGIC) { core_pcm_session = 0; core_bs_session = 0;
	                               core_fmt_v2 = 0; return; }
	// bit0 = passthru, bit1 = pcm session, bit2 = bitstream session,
	// bit15 = this word carries bit 2 at all.
	core_pcm_session = (fmt >> 1) & 1;
	core_bs_session  = (fmt >> 2) & 1;
	core_fmt_v2      = (fmt >> 15) & 1;
}

// What the ADV7513 must be told to expect. ⚠ NOT the inverse of pcm_session:
// that reads 0 both when AC-3 is playing and when NOTHING is, so engaging on it
// put the transmitter into non-PCM mode the moment the core booted with Passthru
// saved -- and the next core inherited it, because stock Main's hdmi_config_init()
// rewrites 0x0C but has no 0x12 entry at all, and so never clears the flag.
// A pre-bs_session core keeps the old rule; its word cannot express the
// difference, and changing behaviour for it would be a guess.
static int content_is_bitstream(void)
{
	return core_fmt_v2 ? core_bs_session : !core_pcm_session;
}

static int declared   = 0;   // the core declared OX6, so it has the HDMI tap
static int acked      = 0;   // cfg[14] is currently set
static int seen_gen   = -1;  // last hdmi_config_init() generation we applied over
static unsigned long restore_at = 0;

// What the CHIP is set to, which is NOT `acked`: between dropping the ack and the
// 50 ms register restore the core is already silent while the transmitter is
// still in non-PCM mode. Teardown has to act on the chip's state, not the ack's,
// or a core load landing inside that window leaves the flag set.
static int chip_nonpcm = 0;

static void set_chip(int bitstream)
{
	chip_nonpcm = bitstream;
	hdmi_config_set_audio(bitstream);
}

void dvd_hdmi_audio_declare(void)
{
	if (!declared) printf("dvd_hdmi_audio: core declares HDMI bitstream capability\n");
	declared = 1;
}

int dvd_hdmi_audio_ack(void)
{
	return acked;
}

static void set_ack(int on)
{
	if (acked == on) return;
	acked = on;
	user_io_send_buttons(1);        // pushes cfg[], incl. our bit, to the core
}

// Put the transmitter back before this process hands the machine to another core
// (app_restart) or reboots. NOTHING ELSE WILL: other cores run stock Main, whose
// hdmi_config_init() rewrites 0x0C but never writes 0x12, so the non-PCM flag
// would otherwise survive into a core that is sending plain PCM -- which the sink
// then renders as a data burst, i.e. silence or noise. Our own re-exec cannot do
// it either: user_io_init() hands off to the core's `main=` binary BEFORE
// video_init() runs, so this process never touches the chip again.
void dvd_hdmi_audio_teardown(void)
{
	if (!chip_nonpcm) return;
	printf("dvd_hdmi_audio: teardown - restoring PCM mode for the next core\n");
	FILE *f = fopen(HDMI_LOG_PATH, "a");
	if (f) { fprintf(f, "teardown: restoring PCM mode\n"); fclose(f); }
	// Ack first, then the registers -- the same order as a release, for the same
	// reason, and it leaves the module's state coherent rather than "acked but the
	// chip is PCM". Both call sites have already reset the core, so this is belt
	// and braces; it matters if teardown is ever called from a path that returns.
	set_ack(0);
	set_chip(0);
}

void dvd_hdmi_audio_tick(void)
{
	report_pump();

	if (!declared || !is_dvd())
	{
		if (acked) { set_ack(0); set_chip(0); }
		// A core built before the HDMI tap never declares OX6. Say so, but only
		// once the user actually selects passthru, so it cannot nag.
		if (is_dvd() && !declared && user_io_status_get("6"))
			report("Core has no HDMI bitstream\n\nOld .rbf - rebuild/reflash");
		return;
	}

	// cfg.dvd_hdmi_bitstream: 0 = auto (EDID-gated), 1 = off, 2 = force.
	// "force" exists because a sink can decode a format it fails to advertise,
	// and because ARC/soundbar topologies routinely mis-report.
	int mode = cfg.dvd_hdmi_bitstream;
	int passthru = user_io_status_get("6");       // Audio Out = Passthru
	int sink_ok  = (mode == 2) || sink_supports_bitstream();

	// Passthru is no longer all-or-nothing: the core bitstreams AC-3/DTS and sends
	// LPCM/MP2 as PCM, so the chip has to follow the CONTENT, not the OSD bit.
	// Releasing the ack here puts the ADV7513 back into PCM mode and hands HDMI
	// audio to the framework's own I2S path, which is where the decoded samples
	// already are. The existing release ordering (ack first, registers 50 ms
	// later) is what keeps the gap silent rather than noisy.
	//
	// PCM IS THE RESTING STATE: content_is_bitstream() is false at idle, in menus
	// before any audio, and once a disc is ejected, so the transmitter is only
	// claimed while a DD/DTS track is actually playing. That bounds what a crash
	// or a hardware reset (neither of which can run the teardown below) can leave
	// behind for the next core.
	poll_audio_format();
	int want = (mode != 1) && passthru && sink_ok && content_is_bitstream();

	// Name the stage whenever the user has ASKED for passthru but we are not
	// engaging - that is exactly the "no sound and the receiver says PCM" case.
	static int last_dbg = -1;
	int dbg = (passthru ? 1 : 0) | (sink_ok ? 2 : 0) | (declared ? 4 : 0) | (mode << 3)
	        | (core_pcm_session ? 0x100 : 0) | (core_bs_session ? 0x200 : 0)
	        | (core_fmt_v2 ? 0x400 : 0);
	if (dbg != last_dbg)
	{
		last_dbg = dbg;
		FILE *f = fopen(HDMI_LOG_PATH, "a");
		if (f)
		{
			fprintf(f, "state: passthru=%d sink_ok=%d declared=%d ini_mode=%d acked=%d pcm_session=%d bs_session=%d fmt_v2=%d\n",
			        passthru, sink_ok, declared, mode, acked, core_pcm_session,
			        core_bs_session, core_fmt_v2);
			fclose(f);
		}
	}

	// Only when the CONTENT wants a bitstream: "we are not engaging because an
	// LPCM track is playing" is the feature working, not a stage to report.
	if (passthru && !want && content_is_bitstream())
	{
		if (mode == 1)      report("Bitstream disabled\n\ndvd_hdmi_bitstream=1 in MiSTer.ini");
		else if (!sink_ok)  report("Sink does not list AC-3/DTS\n\nSet dvd_hdmi_bitstream=2 to force");
	}

	// A full hdmi_config_init() (boot, and video_reinit() on hotplug) rewrites
	// the audio block back to PCM behind our back. Watch its generation counter
	// and re-apply, dropping the ack across the gap so the core cannot be
	// emitting a bitstream while the chip is momentarily back in PCM mode.
	int gen = video_hdmi_config_generation();
	if (acked && gen != seen_gen)
	{
		printf("dvd_hdmi_audio: ADV7513 re-initialised, re-applying non-PCM\n");
		set_ack(0);
		set_chip(1);
		seen_gen = gen;
		set_ack(1);
		return;
	}
	seen_gen = gen;

	if (want && !acked)
	{
		// ORDER MATTERS: configure the chip FIRST, then let the core start.
		set_chip(1);
		set_ack(1);
		// ⚠ NO ON-SCREEN NOTICE HERE, deliberately. Engaging used to be a
		// once-per-session event worth confirming, so it raised one. It is now a
		// per-TRACK event: Passthru follows the content, so every AC-3 <-> LPCM
		// change releases and re-engages, and a disc that alternates (The
		// Residents Commercial DVD does, repeatedly) would paper the screen with
		// a message reporting that things are working. A success notice on a
		// routine event is noise. The failure notices below stay -- those are the
		// cases the user cannot otherwise explain.
		// The log keeps the full record: /tmp/dvd_hdmi_audio.log.
		// NOT "IEC958-direct" -- that route was removed after four failed HW
		// rounds (dvd/hdmi_bs_i2s.sv:14-19). What we set is standard I2S with the
		// channel status taken from the register map (0x0C[6]=1, non-PCM 0x12[7]).
		printf("dvd_hdmi_audio: HDMI bitstream ENGAGED (ADV7513 set to non-PCM)\n");
	}
	else if (!want && acked)
	{
		// ORDER MATTERS the other way: drop the ack FIRST so the core stops
		// emitting, and only restore the PCM registers once it has. In between
		// the core presents digital silence, never PCM into a non-PCM link.
		set_ack(0);
		restore_at = GetTimer(50);
		// Let an explanatory notice be shown again after a state change, even if
		// it repeats an earlier string. (It no longer re-arms an engage message --
		// there isn't one.)
		stage_msg = 0;
		printf("dvd_hdmi_audio: HDMI bitstream released\n");
	}

	if (restore_at && CheckTimer(restore_at))
	{
		restore_at = 0;
		if (!acked) set_chip(0);
	}
}
