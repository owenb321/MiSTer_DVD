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
#ifndef DVD_CTL_LOG
#define DVD_CTL_LOG    "/tmp/dvd_report.log"
#endif

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

// NAV EVENT FIFO (dvd/nav_trace.sv, docs/hil_play_harness.md "Nav event FIFO
// (fabric)"). While the fast-telemetry arm file exists, each sample also drains
// the core's timestamped navigation events and appends one JSON line per event.
// Must match dvd/nav_trace.sv. 0x7C is free (Main 0x00-0x44, 0x61-63, 0xF0-F9;
// 0x7A/0x7B are dvd_telem). MAGIC has bit 15 clear: a core without the FIFO
// answers 0 (hps_io zeroes io_dout for a command it does not know).
#define UIO_DVD_NAVTRACE   0x7C
#define DVD_NAVTRACE_MAGIC 0x5E01
// Entries per drain, the core's cap. ONE transaction per sample, never a loop:
// 10 header + 5 x 64 = 330 SPI words, on the poll thread that also services the
// core's SD reads. A backlog beyond 64 drains over the following samples.
#define DVD_NAVTRACE_MAXN  64
#ifndef DVD_NAVTRACE_LOG
#define DVD_NAVTRACE_LOG   "/tmp/dvd_navtrace.jsonl"
#endif

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
// nav event FIFO
// ---------------------------------------------------------------------------
// nt_state: 0 = not yet probed since the arm, 1 = present, -1 = absent (stop
// draining until the arm file is re-created). nt_first marks the first drain
// after an arm: its entries may predate the arm, and an entry older than 23.3 s
// has an aliased free tick (the stamp keeps 16 bits of it), so they are tagged
// "backlog".
static int      nt_state = 0;
static int      nt_first = 1;
static int      nt_have_cnt = 0;
static uint16_t nt_ovf_last = 0, nt_merge_last = 0;

static const char *const nt_names[17] = {
	"?", "GPRM", "STC_JUMP", "JOY", "PS2", "BTN_ACT", "CELL_CMD", "HLI_ARM", "ARMED",
	"CELL", "PGC", "FLUSH", "AUD_LOW", "STATE", "X0", "X1", "X2"
};

// One entry's payload -> its decoded fields (leading comma, no braces). Kept apart
// from the SPI so main/tests/dvd_ctl_test.cpp exercises the real decoder.
static int navtrace_fields(char *o, size_t sz, unsigned code, unsigned pl,
                           unsigned long long stc)
{
	switch (code)
	{
	case 1:  return snprintf(o, sz, ",\"g\":%u,\"val\":%u", (pl >> 16) & 15, pl & 0xFFFF);
	case 2:  return snprintf(o, sz, ",\"delta\":%d",
	                         (int)(pl & 0x3FFFFFF) - ((pl & 0x2000000) ? 0x4000000 : 0));
	case 3:  return snprintf(o, sz, ",\"kbd\":%u,\"rise\":\"0x%07x\"", (pl >> 25) & 1, pl & 0x1FFFFFF);
	case 4:  return snprintf(o, sz, ",\"pressed\":%u,\"ext\":%u,\"code\":\"0x%02x\"",
	                         (pl >> 9) & 1, (pl >> 8) & 1, pl & 0xFF);
	case 5:  return snprintf(o, sz, ",\"btn\":%u,\"btn_ns\":%u", pl & 63, (pl >> 6) & 63);
	case 6:  return snprintf(o, sz, ",\"cell\":%u,\"cmd\":%u", (pl >> 8) & 255, pl & 255);
	case 7:
	{
		// how far the STC is past the HLI's authored start, from the low 20 bits
		// of both (signed, +/-5.8 s): > 0 = the buttons went live late
		unsigned sp = pl & 0xFFFFF;
		int late = (int)(((unsigned)stc - sp) & 0xFFFFF);
		if (late & 0x80000) late -= 0x100000;
		return snprintf(o, sz, ",\"btn_ns\":%u,\"sptm_lo\":%u,\"late_ticks\":%d",
		                (pl >> 20) & 63, sp, late);
	}
	case 8:  return snprintf(o, sz, ",\"armed\":%u,\"btn_ns\":%u", (pl >> 6) & 1, pl & 63);
	case 9:  return snprintf(o, sz, ",\"menu\":%u,\"vts\":%u,\"cell\":%u",
	                         (pl >> 16) & 1, (pl >> 8) & 255, pl & 255);
	case 10: return snprintf(o, sz, ",\"menu\":%u,\"vts\":%u,\"pgcn\":%u",
	                         (pl >> 24) & 1, (pl >> 16) & 255, pl & 0xFFFF);
	case 11: return snprintf(o, sz, ",\"load\":%u,\"aud\":%u,\"aud_resync\":%u,\"seek\":%u,"
	                         "\"mount\":%u,\"soft\":%u",
	                         pl & 1, (pl >> 1) & 1, (pl >> 2) & 1, (pl >> 3) & 1,
	                         (pl >> 4) & 1, (pl >> 5) & 1);
	case 12: return snprintf(o, sz, ",\"low\":%u,\"frames\":%u", (pl >> 16) & 1, pl & 0xFFFF);
	case 13: return snprintf(o, sz, ",\"pause\":%u,\"still\":%u,\"video_live\":%u,\"menu\":%u,"
	                         "\"chg\":%u", pl & 1, (pl >> 1) & 1, (pl >> 2) & 1, (pl >> 3) & 1,
	                         (pl >> 4) & 15);
	default: return snprintf(o, sz, ",\"raw\":\"0x%07x\"", pl & 0x3FFFFFF);
	}
}

// Drain at most ONE transaction (at most 64 entries). t = CLOCK_MONOTONIC seconds
// at the drain; every line carries it, and t_ev is the event's own time on that
// clock, from the entry's free tick against the header's free_now.
static void navtrace_drain(double t)
{
	if (nt_state < 0) return;

	uint16_t h[10];
	h[0] = spi_uio_cmd_cont(UIO_DVD_NAVTRACE);
	if (h[0] != DVD_NAVTRACE_MAGIC)
	{
		DisableIO();
		nt_state = -1;
		FILE *f = fopen(DVD_NAVTRACE_LOG, "a");
		if (f) { fprintf(f, "{\"t\":%.6f,\"absent\":true}\n", t); fclose(f); }
		ctl_log("DVD_CTL: core has no nav event FIFO (0x7C) -- not draining");
		return;
	}
	for (int i = 1; i < 10; i++) h[i] = spi_w(0);
	// never read past our buffer, whatever the reply claims
	unsigned n = h[1] > DVD_NAVTRACE_MAXN ? DVD_NAVTRACE_MAXN : h[1];
	static uint16_t e[DVD_NAVTRACE_MAXN * 5];
	for (unsigned i = 0; i < n * 5; i++) e[i] = spi_w(0);
	DisableIO();
	nt_state = 1;

	uint16_t ovf = h[3], merges = h[4];
	unsigned free_now = ((unsigned)h[5] << 16) | h[6];
	unsigned long long stc_now = ((unsigned long long)(h[7] & 1) << 32) |
	                             ((unsigned)h[8] << 16) | h[9];
	int first = nt_first;
	nt_first = 0;
	// The counters are cumulative and wrap. A loss is reported as a line of its
	// own, so a gap in the log is never silent; the first drain sets the baseline.
	unsigned d_ovf = nt_have_cnt ? (uint16_t)(ovf - nt_ovf_last) : 0;
	unsigned d_mrg = nt_have_cnt ? (uint16_t)(merges - nt_merge_last) : 0;
	nt_ovf_last = ovf; nt_merge_last = merges; nt_have_cnt = 1;
	if (!n && !d_ovf && !d_mrg && !first) return;

	FILE *f = fopen(DVD_NAVTRACE_LOG, "a");
	if (!f) return;
	if (first)
		fprintf(f, "{\"t\":%.6f,\"ev\":\"DRAIN_START\",\"free_now\":%u,\"stc\":%llu,"
		        "\"fill\":%u,\"ovf\":%u,\"merges\":%u}\n",
		        t, free_now, stc_now, h[2], ovf, merges);
	if (d_ovf || d_mrg)
		fprintf(f, "{\"t\":%.6f,\"ev\":\"LOST\",\"dropped\":%u,\"merged\":%u,\"ovf\":%u,\"merges\":%u}\n",
		        t, d_ovf, d_mrg, ovf, merges);
	for (unsigned k = 0; k < n; k++)
	{
		const uint16_t *x = e + k * 5;
		unsigned code = x[0] >> 11;
		unsigned pl = ((unsigned)(x[0] & 0x7FF) << 15) | (x[1] >> 1);
		unsigned long long stc = ((unsigned long long)(x[1] & 1) << 32) |
		                         ((unsigned)x[2] << 16) | x[3];
		// the 16-bit free stamp (units of 32 ticks) unwrapped against free_now
		unsigned now32 = free_now >> 5;
		unsigned ago32 = (uint16_t)(now32 - x[4]);
		unsigned ev_free = (now32 - ago32) << 5;
		double t_ev = t - (double)(free_now - ev_free) / 90000.0;
		char fl[200];
		if (navtrace_fields(fl, sizeof(fl), code, pl, stc) >= (int)sizeof(fl)) fl[0] = 0;
		fprintf(f, "{\"t\":%.6f,\"t_ev\":%.6f,\"stc\":%llu,\"free\":%u,\"ev\":\"%s\"%s,"
		        "\"ovf\":%u%s}\n",
		        t, t_ev, stc, ev_free, code <= 16 ? nt_names[code] : "?", fl, ovf,
		        first ? ",\"backlog\":true" : "");
	}
	fclose(f);
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
		// a fresh arm re-probes the nav FIFO and starts a new baseline
		if (fast && !telem_fast) { nt_state = 0; nt_first = 1; nt_have_cnt = 0; }
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
		if (telem_fast)
		{
			struct timespec ts;
			clock_gettime(CLOCK_MONOTONIC, &ts);
			navtrace_drain(ts.tv_sec + ts.tv_nsec / 1e9);
		}
	}
}
