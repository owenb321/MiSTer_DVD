// dvd_ctl_test.cpp — the nav event FIFO drain in dvd_ctl.cpp (0x7C,
// dvd/nav_trace.sv; docs/hil_play_harness.md "Nav event FIFO (fabric)").
//
// WHAT THIS PINS
//
//   * A core without the FIFO answers 0 to 0x7C. The drain must write ONE
//     {"absent":true} line and then never issue the command again: it runs on
//     the poll thread, and a probe every sample would be dead SPI traffic.
//   * The entry format is decoded from the documented bit layout, re-derived
//     here by an independent packer -- so a shift error in either is caught.
//   * Whatever N the reply claims, at most 64 entries are read (the buffer and
//     the poll thread's budget).
//   * The free stamp is 16 bits of a 90 kHz/32 count and must unwrap against the
//     header's free_now ACROSS a 16-bit wrap, or every event 23 s into a run
//     lands an hour in the past.
//   * Dropped and merged events are cumulative wrapping counters in the header;
//     an increase is reported as its own LOST line, never silently.
//
// The module is #included, so this exercises the real code.

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdarg.h>
#include <unistd.h>

static char nt_log_path[64];
static char ctl_log_path[64];
#define DVD_NAVTRACE_LOG nt_log_path
#define DVD_CTL_LOG      ctl_log_path

// ---------------------------------------------------------------- fake world
static uint16_t reply[2048];
static int      reply_len = 0, reply_pos = 0;
static int      n_cmd = 0, n_words = 0, n_disable = 0;
static uint16_t last_cmd = 0;

static uint16_t spi_uio_cmd_cont(uint16_t cmd)
{
	n_cmd++; last_cmd = cmd; reply_pos = 1;
	return (cmd == 0x7C && reply_len > 0) ? reply[0] : 0;
}
static uint16_t spi_w(uint16_t)
{
	n_words++;
	return (last_cmd == 0x7C && reply_pos < reply_len) ? reply[reply_pos++] : 0;
}
static void DisableIO(void)                         { n_disable++; }
static int  is_dvd(void)                            { return 1; }
static void user_io_status_set(const char *, uint32_t) {}
static void user_io_file_mount(const char *, int)   {}

#include "dvd_ctl.cpp"

// ---------------------------------------------------------------- helpers
static int fails = 0;
static void check(int cond, const char *what)
{
	printf("  %s %s\n", cond ? "ok  " : "FAIL", what);
	if (!cond) fails++;
}

// The documented 80-bit entry: {code[4:0], payload[25:0], stc[32:0], fts[15:0]}.
static void pack(uint16_t *o, unsigned code, unsigned pl, unsigned long long stc, unsigned fts)
{
	o[0] = (uint16_t)((code << 11) | ((pl >> 15) & 0x7FF));
	o[1] = (uint16_t)(((pl & 0x7FFF) << 1) | ((stc >> 32) & 1));
	o[2] = (uint16_t)(stc >> 16);
	o[3] = (uint16_t)stc;
	o[4] = (uint16_t)fts;
}

static void header(unsigned n, unsigned fill, unsigned ovf, unsigned merges,
                   unsigned free_now, unsigned long long stc_now)
{
	reply[0] = 0x5E01; reply[1] = n; reply[2] = fill; reply[3] = ovf; reply[4] = merges;
	reply[5] = free_now >> 16; reply[6] = free_now & 0xFFFF;
	reply[7] = (stc_now >> 32) & 1; reply[8] = (stc_now >> 16) & 0xFFFF; reply[9] = stc_now & 0xFFFF;
	reply_len = 10;
}

static char logbuf[65536];
static void read_log()
{
	logbuf[0] = 0;
	FILE *f = fopen(nt_log_path, "r");
	if (!f) return;
	size_t n = fread(logbuf, 1, sizeof(logbuf) - 1, f);
	logbuf[n] = 0;
	fclose(f);
}
static int count_lines() { int n = 0; for (char *p = logbuf; *p; p++) n += (*p == '\n'); return n; }
static const char *line(int k)
{
	static char l[1024];
	char *p = logbuf;
	for (int i = 0; i < k && p; i++) { p = strchr(p, '\n'); if (p) p++; }
	if (!p || !*p) return "";
	char *e = strchr(p, '\n');
	size_t n = e ? (size_t)(e - p) : strlen(p);
	if (n >= sizeof(l)) n = sizeof(l) - 1;
	memcpy(l, p, n); l[n] = 0;
	return l;
}
static double num(const char *l, const char *key)
{
	const char *p = strstr(l, key);
	return p ? atof(p + strlen(key)) : -1e30;
}
static void fresh()
{
	unlink(nt_log_path);
	nt_state = 0; nt_first = 1; nt_have_cnt = 0;
	n_cmd = n_words = n_disable = 0; reply_len = 0;
}

int main(void)
{
	snprintf(nt_log_path, sizeof(nt_log_path), "/tmp/dvd_ctl_test_nt_%d.jsonl", (int)getpid());
	snprintf(ctl_log_path, sizeof(ctl_log_path), "/tmp/dvd_ctl_test_log_%d.txt", (int)getpid());

	printf("[1] a core without the FIFO\n");
	fresh();
	navtrace_drain(1.0);
	navtrace_drain(2.0);
	navtrace_drain(3.0);
	read_log();
	check(count_lines() == 1 && strstr(line(0), "\"absent\":true"), "one {\"absent\":true} line");
	check(n_cmd == 1, "absent probed once, then never again");
	check(n_words == 0 && n_disable == 1, "no data words read from an absent core, IO closed");

	printf("[2] first drain: decode, backlog tag, t_ev\n");
	fresh();
	unsigned free_now = 1000000;                        // ticks
	unsigned long long stc_now = 0x123456789ULL;
	header(3, 3, 5, 2, free_now, stc_now);
	pack(reply + 10, 1, (0u << 16) | 0xBEEF, 0x100000000ULL, (free_now - 9000) >> 5);
	// HLI promoted 300 ticks after its authored start (low 20 bits of both)
	pack(reply + 15, 7, (9u << 20) | 0x45678, 0x000045678ULL + 300, (free_now - 4500) >> 5);
	pack(reply + 20, 2, (unsigned)(-1000) & 0x3FFFFFF, 0x50ULL, free_now >> 5);
	reply_len = 25;
	navtrace_drain(10.0);
	read_log();
	check(n_cmd == 1 && n_words == 9 + 15, "9 header + 3 x 5 entry words");
	check(count_lines() == 4, "DRAIN_START + 3 entries");
	check(strstr(line(0), "\"ev\":\"DRAIN_START\"") && strstr(line(0), "\"fill\":3"), "DRAIN_START line");
	check(strstr(line(0), "\"stc\":4886718345") != NULL, "DRAIN_START stc_now (33-bit)");
	check(strstr(line(1), "\"ev\":\"GPRM\",\"g\":0,\"val\":48879") != NULL, "GPRM g0 = 0xBEEF");
	check(strstr(line(1), "\"stc\":4294967296") != NULL, "entry stc bit 32");
	check(strstr(line(1), "\"backlog\":true") != NULL, "first drain's entries tagged backlog");
	double tev = num(line(1), "\"t_ev\":");
	check(tev > 9.8996 && tev < 9.9004, "t_ev = t - 9000 ticks / 90 kHz (0.1 s)");
	check(strstr(line(2), "\"ev\":\"HLI_ARM\",\"btn_ns\":9,\"sptm_lo\":284280,\"late_ticks\":300") != NULL,
	      "HLI_ARM: buttons, start PTS, 300 ticks late");
	check(strstr(line(3), "\"ev\":\"STC_JUMP\",\"delta\":-1000") != NULL, "STC_JUMP signed delta");

	printf("[3] later drain: losses reported, no backlog tag\n");
	header(1, 1, 8, 2, free_now + 900, stc_now);
	pack(reply + 10, 5, (5u << 6) | 3, 0x60ULL, (free_now + 900) >> 5);
	reply_len = 15;
	navtrace_drain(11.0);
	read_log();
	check(count_lines() == 6, "a LOST line + the entry");
	check(strstr(line(4), "\"ev\":\"LOST\",\"dropped\":3,\"merged\":0") != NULL, "ovf 5 -> 8: 3 dropped");
	check(strstr(line(5), "\"ev\":\"BTN_ACT\",\"btn\":3,\"btn_ns\":5") != NULL, "BTN_ACT decode");
	check(strstr(line(5), "backlog") == NULL, "no backlog tag after the first drain");
	// an empty drain with no loss writes nothing
	header(0, 0, 8, 2, free_now + 1000, stc_now);
	navtrace_drain(12.0);
	read_log();
	check(count_lines() == 6, "empty drain: nothing written");

	printf("[4] a reply claiming more than 64 entries\n");
	header(500, 500, 8, 2, free_now, stc_now);
	for (int i = 0; i < 500 * 5 && 10 + i < 2048; i++) reply[10 + i] = 0;
	for (int k = 0; k < 64; k++) pack(reply + 10 + 5 * k, 14, k, 0, free_now >> 5);
	reply_len = 2048;
	n_words = 0;
	navtrace_drain(13.0);
	check(n_words == 9 + 64 * 5, "reads exactly 64 entries");

	printf("[5] the free stamp unwraps across its 16-bit wrap\n");
	fresh();
	free_now = (0x30005u << 5) + 7;                     // now32 = 0x30005: the stamp has wrapped 3 times
	header(1, 1, 0, 0, free_now, 0);
	pack(reply + 10, 14, 1, 0, 0xFFF0);                 // 0x15 units (672 ticks) earlier
	reply_len = 15;
	navtrace_drain(20.0);
	read_log();
	check(strstr(line(1), "\"free\":6290944,") != NULL, "free = 0x2FFF0 << 5, not a wrap away");
	tev = num(line(1), "\"t_ev\":");
	check(tev > 19.9923 && tev < 19.9926, "t_ev 679 ticks (7.5 ms) before the drain");

	unlink(nt_log_path);
	unlink(ctl_log_path);
	printf(fails ? "dvd_ctl_test: %d FAILURE(S)\n" : "dvd_ctl_test: ALL GREEN\n", fails);
	return fails ? 1 : 0;
}
