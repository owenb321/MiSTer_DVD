// dvd_hdmi_audio.cpp — HDMI IEC 61937 bitstream support for the DVD core.
// See dvd_hdmi_audio.h and MiSTer_DVD/docs/hdmi_bitstream.md.

#include <stdio.h>
#include <string.h>
#include <stdint.h>

#include "../../user_io.h"
#include "../../video.h"
#include "../../cfg.h"
#include "../../hardware.h"
#include "../../menu.h"
#include "dvd_hdmi_audio.h"

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
static const char *stage_msg = 0;
static void report(const char *msg)
{
	if (stage_msg == msg) return;      // only on transition
	stage_msg = msg;
	printf("dvd_hdmi_audio: %s\n", msg);
	InfoMessage(msg, 3000, "HDMI Audio");
}

static int declared   = 0;   // the core declared OX6, so it has the HDMI tap
static int acked      = 0;   // cfg[14] is currently set
static int seen_gen   = -1;  // last hdmi_config_init() generation we applied over
static unsigned long restore_at = 0;

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

void dvd_hdmi_audio_tick(void)
{
	if (!declared || !is_dvd())
	{
		if (acked) { set_ack(0); hdmi_config_set_audio(0); }
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
	int want = (mode != 1) && passthru && sink_ok;

	// Name the stage whenever the user has ASKED for passthru but we are not
	// engaging - that is exactly the "no sound and the receiver says PCM" case.
	if (passthru && !want)
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
		hdmi_config_set_audio(1);
		seen_gen = gen;
		set_ack(1);
		return;
	}
	seen_gen = gen;

	if (want && !acked)
	{
		// ORDER MATTERS: configure the chip FIRST, then let the core start.
		hdmi_config_set_audio(1);
		set_ack(1);
		report("HDMI bitstream ENGAGED\n\nADV7513 in IEC958-direct mode");
	}
	else if (!want && acked)
	{
		// ORDER MATTERS the other way: drop the ack FIRST so the core stops
		// emitting, and only restore the PCM registers once it has. In between
		// the core presents digital silence, never PCM into a non-PCM link.
		set_ack(0);
		restore_at = GetTimer(50);
		stage_msg = 0;   // re-arm reporting for the next engage attempt
		printf("dvd_hdmi_audio: HDMI bitstream released\n");
	}

	if (restore_at && CheckTimer(restore_at))
	{
		restore_at = 0;
		if (!acked) hdmi_config_set_audio(0);
	}
}
