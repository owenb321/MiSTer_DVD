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

#define DVD_CTL_FIFO   "/tmp/dvd_ctl"
#define DVD_TELEM_FILE "/tmp/dvd_telem.json"
#define DVD_CTL_LOG    "/tmp/dvd_report.log"

// Must match dvd/dvd_telem.sv. 0x7A is free: Main uses 0x00-0x44, 0x61-63, 0xF0-F9.
#define UIO_DVD_TELEM  0x7A
#define DVD_TELEM_MAGIC 0xD7D1

#define TELEM_PERIOD_MS 250

static int  ctl_fd = -1;
static unsigned last_telem_ms = 0;

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
	uint16_t w[11];
	w[0] = spi_uio_cmd_cont(UIO_DVD_TELEM);
	for (int i = 1; i < 11; i++) w[i] = spi_w(0);
	DisableIO();

	if (w[0] != DVD_TELEM_MAGIC) return;      // no bridge in this core build

	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	double t = ts.tv_sec + ts.tv_nsec / 1e9;

	// Write via a temp file and rename, so a reader never sees a half-written
	// object. The cost is one extra tmpfs metadata op every 250 ms.
	char tmp[64];
	snprintf(tmp, sizeof(tmp), "%s.tmp", DVD_TELEM_FILE);
	FILE *f = fopen(tmp, "w");
	if (!f) return;
	fprintf(f,
		"{\"t\":%.6f,\"refreshes\":%u,\"pickups\":%u,\"lates\":%u,"
		"\"drops\":%u,\"vid_err\":%d,\"debt\":%d,\"drop_req\":%u,"
		"\"vbuf_fill\":%u,\"aud_frames\":%u,"
		"\"aud_play\":%u,\"aud_gate\":%u,"
		"\"flags\":{\"media\":%u,\"pause\":%u,\"video_live\":%u,"
		"\"still\":%u,\"menu\":%u}}\n",
		t, w[1], w[2], w[3], w[4],
		(int)(int16_t)w[5],                       // vid_err is SIGNED
		(int)((w[6] >> 11) & 0x1F) - (((w[6] >> 15) & 1) ? 32 : 0),
		(unsigned)((w[6] >> 10) & 1),
		(unsigned)(w[7] >> 8), w[8], w[9], w[10],
		(unsigned)(w[7] & 1), (unsigned)((w[7] >> 1) & 1),
		(unsigned)((w[7] >> 2) & 1), (unsigned)((w[7] >> 3) & 1),
		(unsigned)((w[7] >> 4) & 1));
	fclose(f);
	rename(tmp, DVD_TELEM_FILE);
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

void dvd_ctl_tick()
{
	if (!is_dvd()) return;

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
	if (t - last_telem_ms >= TELEM_PERIOD_MS)
	{
		last_telem_ms = t;
		telem_read();
	}
}
