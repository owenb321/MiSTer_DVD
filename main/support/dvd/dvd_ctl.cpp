// dvd_ctl.cpp — see dvd_ctl.h.

#include <stdio.h>
#include <stdarg.h>   // va_list, used by ctl_log
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>

#include "../../user_io.h"
#include "../../spi.h"
#include "../../hardware.h"
#include "dvd_ctl.h"

// Presence of this file ARMS the channel. Absent -- the shipped default -- this
// module does nothing at all: no SPI, no file writes, no FIFO.
//
// A runtime gate rather than an ifdef, deliberately. The whole point of the
// bridge is that telemetry costs no rebuild and no fitter-seed re-roll; a build
// toggle on the HOST side would reinstate a rebuild of the Main for the same
// benefit. This way `touch` enables it and nothing ships active.
//
// It matters because this runs on the poll thread that also services the core's
// SD block reads, where unnecessary work is a video artefact rather than a
// latency nit (see the dvd_phys drive-scan post-mortem in docs/mgl_launch.md).
#define DVD_CTL_ARM    "/media/fat/dvd_hil"

#define DVD_CTL_FIFO   "/tmp/dvd_ctl"
#define DVD_TELEM_FILE "/tmp/dvd_telem.json"
#define DVD_CTL_LOG    "/tmp/dvd_report.log"

// Must match dvd/dvd_telem.sv. 0x7A is free: Main uses 0x00-0x44, 0x61-63, 0xF0-F9.
#define UIO_DVD_TELEM  0x7A
#define DVD_TELEM_MAGIC 0xD7D1
// Word 16 of a core with dvd/dec_duty.sv (docs/decode_pacing.md): words 17..20
// follow. A core built before them answers strobes past 15 with word 15 AGAIN
// (its word counter saturates), so 17..20 are meaningless without this marker.
#define DVD_TELEM_DUTY_MAGIC 0xDD01
// Word 21 of a core with dec_duty's per-picture words (docs/decode_pacing.md §7
// "Instrument"): words 22..24 follow. A separate marker, so word 16 keeps meaning
// what an older Main expects; cores without it answer 0 past word 20.
#define DVD_TELEM_PIC_MAGIC 0xDD02
// Word 25 of a core with the shared audio engine (docs/dts_decoder.md, docs/ac3_engine.md):
// words 26..30 follow -- the DTS codebook copy's verdict and checksum, the engine's
// frames and refusals. Cores without it answer 0 past word 24.
#define DVD_TELEM_AUD_MAGIC 0xDD03
// Word 31 (docs/field_parity.md "Strict first field"): {1, fb_heals[6:0], strict_waits[7:0]}.
// Not behind a marker word -- 31 is the last index the core's word counter reaches -- so
// bit 15 is its FORMAT bit instead: a core built before it answers 0, which must read as
// "absent", not "zero heals".
#define DVD_TELEM_FPAR_PRESENT 0x8000

#define TELEM_PERIOD_MS 250

// HIL-only EVENT CAPTURE (docs/nonseamless_audio.md). At 250 ms a row cannot
// order the events at a cell join (re-anchor, audio reset, gate release, the
// play_err step); they all land in one row. When the harness creates this file
// (text: the period in ms, clamped to 10..1000), dvd_ctl samples at that period
// and ALSO appends every sample to DVD_TELEM_FAST_LOG, so nothing depends on a
// shell poller keeping up. Re-checked with the arm file every 2 s; absent = the
// normal 250 ms snapshot only. Nothing ships active: /tmp is empty at boot.
#define DVD_TELEM_FAST     "/tmp/dvd_telem_fast"
#define DVD_TELEM_FAST_LOG "/tmp/dvd_telem_fast.jsonl"

static int  ctl_fd = -1;
static unsigned last_telem_ms = 0;
static unsigned telem_period_ms = TELEM_PERIOD_MS;
static int telem_fast = 0;

static void ctl_log(const char *fmt, ...)
{
	va_list ap;
	FILE *f = fopen(DVD_CTL_LOG, "a");
	if (!f) return;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fprintf(f, "\n");
	fclose(f);
}

static unsigned now_ms()
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (unsigned)(ts.tv_sec * 1000u + ts.tv_nsec / 1000000u);
}

// ---------------------------------------------------------------------------
// telemetry
// ---------------------------------------------------------------------------
static void telem_read()
{
	// One transaction: the core latches every counter on the command strobe, so
	// the words below are one consistent SNAPSHOT rather than samples taken a
	// few hundred microseconds apart. That matters because the number this
	// exists to produce is a RATIO of two of them.
	// Words 11-13 (A/V phase) were added with the PTS-scheduled display work.
	// Reading them from an OLDER core is safe: dvd_telem's readout mux answers
	// 16'd0 for any index it does not implement, so they read 0, not garbage.
	uint16_t w[32];
	w[0] = spi_uio_cmd_cont(UIO_DVD_TELEM);
	for (int i = 1; i < 32; i++) w[i] = spi_w(0);
	DisableIO();

	if (w[0] != DVD_TELEM_MAGIC) return;      // no bridge in this core build

	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	double t = ts.tv_sec + ts.tv_nsec / 1e9;

	char line[1536];
	// dec_duty (words 17..20): free-running clk_dec cycle counts / 4096 of where
	// the decoder's time goes -- parked on the display, starved of bitstream,
	// stalled by the decode pipe, recon waiting on reference pixels. 16-bit,
	// they WRAP; the host differences them. Absent (not zero) on a core
	// without them, so a reader cannot mistake "old core" for "idle decoder".
	// Per picture (words 22..24, behind the word-21 marker): the longest single
	// picture decode in the core's last 0.83 s window (cycles/4096, a LEVEL, not a
	// counter), and two wrapping counters -- pictures decoded, and those that took
	// longer than one frame period. Absent on a core without them.
	char duty[400] = "";
	if (w[16] == DVD_TELEM_DUTY_MAGIC)
	{
		int n = snprintf(duty, sizeof(duty),
			"\"dec_disp\":%u,\"dec_starve\":%u,\"dec_back\":%u,\"dec_ref\":%u,",
			w[17], w[18], w[19], w[20]);
		if (w[21] == DVD_TELEM_PIC_MAGIC && n > 0 && n < (int)sizeof(duty))
			n += snprintf(duty + n, sizeof(duty) - n,
				"\"pic_max\":%u,\"pic_n\":%u,\"pic_over\":%u,",
				w[22], w[23], w[24]);
		// the audio engine (behind the word-25 marker): dts_copied / dts_ok are the
		// codebook copy's verdict (dts_ok 0 = DTS discarded), dts_sum its checksum
		if (w[25] == DVD_TELEM_AUD_MAGIC && n > 0 && n < (int)sizeof(duty))
			snprintf(duty + n, sizeof(duty) - n,
				"\"dts_copied\":%u,\"dts_ok\":%u,\"dts_active\":%u,\"eng_last_err\":%u,"
				"\"dts_sum\":\"%04x%04x\",\"eng_frames\":%u,\"eng_refused\":%u,",
				w[26] & 1, (w[26] >> 1) & 1, (w[26] >> 2) & 1, (w[26] >> 8) & 31,
				w[27], w[28], w[29], w[30]);
	}
	// field parity (word 31): fb_heals = the field-parity corrector's feedback insertions
	// (the ~0.5 s heal), strict_waits = frame-top slots the mixer's strict first-field
	// placement refused. Wrapping 7-/8-bit counters, hard-reset only; the host
	// differences them. Absent (not zero) on a core without the word.
	if (w[31] & DVD_TELEM_FPAR_PRESENT)
	{
		size_t n = strlen(duty);
		if (n < sizeof(duty))
			snprintf(duty + n, sizeof(duty) - n, "\"fb_heals\":%u,\"strict_waits\":%u,",
				(w[31] >> 8) & 0x7F, w[31] & 0xFF);
	}
	int len = snprintf(line, sizeof(line),
		"{\"t\":%.6f,%s\"refreshes\":%u,\"pickups\":%u,\"lates\":%u,"
		"\"drops\":%u,\"vid_err\":%d,\"debt\":%d,\"drop_req\":%u,"
		"\"vbuf_fill\":%u,\"aud_frames\":%u,"
		"\"aud_play\":%u,\"aud_gate\":%u,"
		// A/V PHASE, ms. Each is the source value's bits [19:4]: 1 LSB = 16 ticks
		// of the 90 kHz STC = 0.17778 ms. SIGNED. disp_lag = PTS of the picture
		// just displayed minus the STC (the acceptance signal for PTS-scheduled
		// display: ~0 once the display follows its PTS); play_err = audio
		// playback position vs its anchor; av_drift = dispatched audio PTS - STC.
		"\"disp_lag_ms\":%.2f,\"play_err_ms\":%.2f,\"av_drift_ms\":%.2f,"
		"\"sched_frc\":%u,\"sched_ps\":%u,\"sched_pf\":%u,\"sched_tff\":%u,\"sched_rff\":%u,\"reanchors\":%u,\"anch_fwd\":%u,\"anch_bwd\":%u,\"first_tagged\":%u,\"first_seen\":%u,\"prov_seen\":%u,"
		// flags.blend (docs/field_blend.md) = the display scan under way is being
		// field-blended (word 7 flags[5]; 0 on a core without the feature).
		"\"flags\":{\"media\":%u,\"pause\":%u,\"video_live\":%u,"
		// flags.tmap / flags.tmap_fb = the last TIME seek landed through the disc's
		// time map / fell back to its sector estimate (issue #127, word 7
		// flags[6]/[7]; both 0 on a core without the feature, or before one).
		// flags.bob = the display scan under way uses the progressive bob kernel
		// (docs/field_blend.md "Bob"; word 14 bit 8, 0 on a core without it).
		// flags.rgn_allp = the disc's VMGI prohibits EVERY region, so SPRM20 fell
		// back to region 1 (docs/dvd_vm.md "Player parameters"; word 14 bit 9).
		// flags.bup_vmg / bup_vts = the VMGI / a VTSI header was bad and the
		// reader now reads its .BUP; flags.ifo_nogood = a header was bad with no
		// good .BUP (docs/dvd_nav.md "IFO header gate"; word 14 bits 10/11/12,
		// sticky per mount, 0 on a core without the feature).
		// flags.title_probed = the mount's VMGM Title-entry probe ran; flags.title_menu
		// = it found an entry-2 (Title) PGC, so the Title key is live -- 0 with
		// title_probed 1 means the key is a no-op on this disc (audit 10b,
		// docs/dvd_vm.md "Title key"; word 14 bits 13/14, sticky per mount).
		"\"still\":%u,\"menu\":%u,\"blend\":%u,\"tmap\":%u,\"tmap_fb\":%u,\"bob\":%u,\"rgn_allp\":%u,"
		"\"bup_vmg\":%u,\"bup_vts\":%u,\"ifo_nogood\":%u,\"title_probed\":%u,\"title_menu\":%u}}\n",
		t, duty, w[1], w[2], w[3], w[4],
		(int)(int16_t)w[5],                       // vid_err is SIGNED
		(int)((w[6] >> 11) & 0x1F) - (((w[6] >> 15) & 1) ? 32 : 0),
		(unsigned)((w[6] >> 10) & 1),
		(unsigned)(w[7] >> 8), w[8], w[9], w[10],
		(double)(int16_t)w[11] * 16.0 / 90.0,     // ticks/16 -> ms
		(double)(int16_t)w[12] * 16.0 / 90.0,
		(double)(int16_t)w[13] * 16.0 / 90.0,
		(unsigned)((w[14] >> 4) & 0xF), (unsigned)((w[14] >> 3) & 1), (unsigned)((w[14] >> 2) & 1),
		(unsigned)((w[14] >> 1) & 1), (unsigned)(w[14] & 1),
		(unsigned)(w[15] >> 8), (unsigned)((w[15] >> 6) & 3), (unsigned)((w[15] >> 4) & 3),
		(unsigned)((w[15] >> 3) & 1), (unsigned)((w[15] >> 2) & 1), (unsigned)((w[15] >> 1) & 1),
		(unsigned)(w[7] & 1), (unsigned)((w[7] >> 1) & 1),
		(unsigned)((w[7] >> 2) & 1), (unsigned)((w[7] >> 3) & 1),
		(unsigned)((w[7] >> 4) & 1), (unsigned)((w[7] >> 5) & 1),
		(unsigned)((w[7] >> 6) & 1), (unsigned)((w[7] >> 7) & 1),
		(unsigned)((w[14] >> 8) & 1), (unsigned)((w[14] >> 9) & 1),
		(unsigned)((w[14] >> 10) & 1), (unsigned)((w[14] >> 11) & 1),
		(unsigned)((w[14] >> 12) & 1),
		(unsigned)((w[14] >> 13) & 1), (unsigned)((w[14] >> 14) & 1));
	if (len <= 0 || len >= (int)sizeof(line)) return;

	// The IFO header gate's flags are sticky per mount: log each one's rising edge
	// once, so a fallback shows up in dvd_report.log, not only in the JSON.
	static unsigned ifo_seen = 0;
	unsigned ifo_now = (w[14] >> 10) & 7;
	if (ifo_now & ~ifo_seen & 1) ctl_log("DVD_CTL: VIDEO_TS.IFO header bad -- reading VIDEO_TS.BUP");
	if (ifo_now & ~ifo_seen & 2) ctl_log("DVD_CTL: a VTS_xx_0.IFO header bad -- reading its .BUP");
	if (ifo_now & ~ifo_seen & 4) ctl_log("DVD_CTL: an IFO header bad and no good .BUP -- parsed as is");
	ifo_seen = ifo_now;

	// The Title-entry probe's verdict, once per mount (audit 10b): a disc with no
	// Title menu ignores the Title key, and the log says why.
	static unsigned title_seen = 0;
	unsigned title_now = (w[14] >> 13) & 3;
	if ((title_now & 1) && !(title_seen & 1))
		ctl_log((title_now & 2) ? "DVD_CTL: VMGM has a Title menu"
		                        : "DVD_CTL: VMGM has no Title menu -- the Title key is ignored");
	title_seen = title_now;

	// Write via a temp file and rename, so a reader never sees a half-written
	// object. The cost is one extra tmpfs metadata op per sample.
	char tmp[64];
	snprintf(tmp, sizeof(tmp), "%s.tmp", DVD_TELEM_FILE);
	FILE *f = fopen(tmp, "w");
	if (!f) return;
	fputs(line, f);
	fclose(f);
	rename(tmp, DVD_TELEM_FILE);

	if (telem_fast)
	{
		FILE *lf = fopen(DVD_TELEM_FAST_LOG, "a");
		if (lf) { fputs(line, lf); fclose(lf); }
	}
}

// ---------------------------------------------------------------------------
// command FIFO
// ---------------------------------------------------------------------------
static void ctl_open()
{
	if (ctl_fd >= 0) return;
	struct stat st;
	if (stat(DVD_CTL_FIFO, &st) || !S_ISFIFO(st.st_mode))
	{
		unlink(DVD_CTL_FIFO);
		if (mkfifo(DVD_CTL_FIFO, 0666)) return;
	}
	// O_RDWR so the open never blocks and we never see EOF when a writer
	// closes -- the same trick Main uses for /dev/MiSTer_cmd.
	ctl_fd = open(DVD_CTL_FIFO, O_RDWR | O_NONBLOCK | O_CLOEXEC);
}

static void ctl_exec(char *line)
{
	while (*line == ' ') line++;
	if (!*line) return;

	if (!strncmp(line, "osd ", 4))
	{
		char *opt = line + 4;
		char *sp = strchr(opt, ' ');
		if (!sp) { ctl_log("DVD_CTL: bad osd command"); return; }
		*sp = 0;
		uint32_t val = (uint32_t)strtoul(sp + 1, NULL, 0);
		user_io_status_set(opt, val);
		ctl_log("DVD_CTL: osd %s = %u", opt, val);
	}
	else if (!strncmp(line, "mount ", 6))
	{
		user_io_file_mount(line + 6, 0);
		ctl_log("DVD_CTL: mount %s", line + 6);
	}
	else if (!strcmp(line, "ping"))
	{
		ctl_log("DVD_CTL: ping");
	}
	else
	{
		ctl_log("DVD_CTL: unknown command '%s'", line);
	}
}

// Re-checked periodically so the channel can be armed without restarting Main,
// but not on every poll: this is a stat() on the SD card.
static int armed = 0;
static unsigned last_arm_ms = 0;

void dvd_ctl_tick()
{
	if (!is_dvd()) return;

	unsigned now = now_ms();
	if (!last_arm_ms || now - last_arm_ms >= 2000)
	{
		last_arm_ms = now ? now : 1;
		struct stat st;
		int was = armed;
		armed = (stat(DVD_CTL_ARM, &st) == 0);
		if (armed != was) ctl_log("DVD_CTL: %s (%s)",
		                          armed ? "armed" : "disarmed", DVD_CTL_ARM);
		// event-capture knob (see DVD_TELEM_FAST)
		unsigned period = TELEM_PERIOD_MS;
		int fast = 0;
		FILE *kf = armed ? fopen(DVD_TELEM_FAST, "r") : NULL;
		if (kf)
		{
			unsigned ms = 0;
			if (fscanf(kf, "%u", &ms) == 1)
			{
				period = ms < 10 ? 10 : ms > 1000 ? 1000 : ms;
				fast = 1;
			}
			fclose(kf);
		}
		if (fast != telem_fast || period != telem_period_ms)
			ctl_log("DVD_CTL: telemetry every %u ms%s", period,
			        fast ? " (event capture -> " DVD_TELEM_FAST_LOG ")" : "");
		telem_fast = fast;
		telem_period_ms = period;
		if (!armed && ctl_fd >= 0)
		{
			close(ctl_fd);
			ctl_fd = -1;
			unlink(DVD_CTL_FIFO);
			unlink(DVD_TELEM_FILE);
		}
	}
	if (!armed) return;

	ctl_open();
	if (ctl_fd >= 0)
	{
		// Non-blocking, and at most one buffer per tick: this thread also
		// services the core's SD reads.
		char buf[512];
		int n = read(ctl_fd, buf, sizeof(buf) - 1);
		if (n > 0)
		{
			buf[n] = 0;
			char *p = buf;
			while (p && *p)
			{
				char *nl = strchr(p, '\n');
				if (nl) *nl = 0;
				ctl_exec(p);
				p = nl ? nl + 1 : NULL;
			}
		}
	}

	unsigned t = now_ms();
	if (t - last_telem_ms >= telem_period_ms)
	{
		last_telem_ms = t;
		telem_read();
	}
}
