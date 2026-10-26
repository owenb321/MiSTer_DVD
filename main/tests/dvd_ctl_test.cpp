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
// And the VM state snapshot (0x7D, dvd/vm_snap.sv; docs/nav_engine.md "State
// snapshot"), [6]..[11]:
//   * The request carries control word 1 and nothing else; a core without the
//     snapshot gets one {"absent":true} file and no wait.
//   * While the core says busy, or seq has not moved, only the 13 header words are
//     clocked -- never a payload, never a file -- and polls are rate-limited.
//   * A complete snapshot is written whole (via rename), with the position decoded
//     and at most 128 words read whatever len claims; a request that never
//     completes ends in a {"timeout":true} file, not a hang.
//
// And the restore's `vmload <file>` (save states step 3), [12]..[15]:
//   * the file vmsnap wrote is read back: control word 2, then fmt, len, the 16-bit
//     sum of the words, and the words, in one transaction;
//   * a pending verdict is not a result; applied and every refusal are, named.
//   * the landing time sent is the snapshot's displayed time ([16]: the demux lead taken
//     off the clock, -1 when it cannot be trusted), 0xFFFF when it has none.
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
static char vs_path[64];
static char vl_path[64];
#define DVD_NAVTRACE_LOG nt_log_path
#define DVD_CTL_LOG      ctl_log_path
#define DVD_VMSNAP_FILE  vs_path
#define DVD_VMLOAD_FILE  vl_path

// ---------------------------------------------------------------- fake world
static uint16_t reply[2048];
static int      reply_len = 0, reply_pos = 0;
static int      n_cmd = 0, n_words = 0, n_disable = 0;
static uint16_t last_cmd = 0;
static uint16_t reply_cmd = 0x7C;                   // the command the fake core answers
static uint16_t sent[2048];                         // what the host clocked out, per word

static uint16_t spi_uio_cmd_cont(uint16_t cmd)
{
	n_cmd++; last_cmd = cmd; reply_pos = 1;
	return (cmd == reply_cmd && reply_len > 0) ? reply[0] : 0;
}
static uint16_t spi_w(uint16_t x)
{
	if (n_words < 2048) sent[n_words] = x;
	n_words++;
	return (last_cmd == reply_cmd && reply_pos < reply_len) ? reply[reply_pos++] : 0;
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

	// ------------------------------------------------------------ the VM snapshot
	snprintf(vs_path, sizeof(vs_path), "/tmp/dvd_ctl_test_vs_%d.json", (int)getpid());
	static char vsbuf[8192];
	#define READ_VS() do { vsbuf[0] = 0; FILE *vf = fopen(vs_path, "r"); \
		if (vf) { size_t vn = fread(vsbuf, 1, sizeof(vsbuf) - 1, vf); vsbuf[vn] = 0; fclose(vf); } } while (0)

	printf("[6] vmsnap on a core without the snapshot\n");
	fresh(); reply_cmd = 0x7D; unlink(vs_path);
	vmsnap_request();
	READ_VS();
	check(strstr(vsbuf, "\"absent\":true") != NULL, "one {\"absent\":true} file");
	check(!vs_wait, "no wait for an absent core");

	printf("[7] the request\n");
	fresh(); reply_cmd = 0x7D;
	reply[0] = 0x5E02; reply[1] = 4; reply_len = 2;
	vmsnap_request();
	check(n_cmd == 1 && n_words == 1 && n_disable == 1, "one transaction: command + one word");
	check(sent[0] == 1, "control word 1 (take a snapshot when this transaction ends)");
	check(vs_wait && vs_seq0 == 4, "waits for seq to move from 4");
	READ_VS();
	check(vsbuf[0] == 0, "a stale snapshot file is removed at the request");

	printf("[8] polls while busy, or before seq moves\n");
	unsigned t0 = vs_t0;
	reply[0] = 0x5E02; reply[1] = 5; reply[2] = 0x8060; reply_len = 2048;   // seq moved, but busy
	n_words = 0;
	vmsnap_poll(t0 + 5);
	check(n_words == 0, "a poll within 20 ms of the last does nothing");
	vmsnap_poll(t0 + 25);
	check(n_words == 18, "busy: only the 19 header words are clocked");
	reply[1] = 4; reply[2] = 0x0060;                      // not busy, but seq still 4
	n_words = 0;
	vmsnap_poll(t0 + 50);
	check(n_words == 18, "seq unchanged: only the header");
	READ_VS();
	check(vsbuf[0] == 0 && vs_wait, "no file yet, still waiting");

	printf("[9] a complete snapshot\n");
	reply[1] = 5; reply[2] = 96; reply[3] = 0xC7D5; reply[4] = 0x0002;     // fresh, no video
	reply[5] = 0x0001; reply[6] = 0x5513; reply[7] = 0xBFFF; reply[8] = 0xFF3C;
	reply[9] = 0x0001; reply[10] = 0x1823; reply[11] = 7; reply[12] = 4;
	// the clock 0:12:51 + 10 frames at 30 fps, its VOBU 0.8 s ahead of the screen
	reply[13] = 0x0012; reply[14] = 0x51D0;
	reply[15] = 0x0001; reply[16] = 0x1940;                // sptm = 72000 + 90000
	reply[17] = 0x0001; reply[18] = 0x5F90 - 0x4650;       // stc  = sptm - 72000 (0.8 s)
	for (int i = 0; i < 96; i++) reply[19 + i] = (uint16_t)(0x1000 + i);
	reply[19 + 96] = 0xDEAD;                              // past len: must not be read
	n_words = 0;
	vmsnap_poll(t0 + 75);
	check(n_words == 18 + 96, "header + exactly len words");
	check(!vs_wait, "done");
	READ_VS();
	check(strstr(vsbuf, "\"seq\":5,\"fmt\":51157,\"pos_fresh\":1,\"has_video\":0,") != NULL,
	      "seq, fmt, flags");
	check(strstr(vsbuf, "\"nv_pck_lbn\":87315,\"prev_video\":3221225276,\"c_eltm\":71715,"
	             "\"vob_idn\":7,\"c_idn\":4,") != NULL, "the position");
	check(strstr(vsbuf, "\"words\":[4096,4097,") != NULL && strstr(vsbuf, ",4191]}") != NULL,
	      "the 96 words, in order");
	// no picture in that VOBU (reply[4] bit 0 = 0): no displayed time, land at the cell
	check(strstr(vsbuf, "\"disp_secs\":-1,") != NULL, "a VOBU without a picture has no displayed time");
	check(strstr(vsbuf, "57005") == NULL, "nothing past len");

	printf("[10] a reply claiming more words than the buffer\n");
	vs_wait = 1; vs_seq0 = 5; vs_t0 = vs_last = t0;
	reply[1] = 6; reply[2] = 200;
	n_words = 0;
	vmsnap_poll(t0 + 100);
	check(n_words == 18 + 128, "reads at most 128 words");

	printf("[11] a request that never completes\n");
	vs_wait = 1; vs_seq0 = 6; vs_t0 = vs_last = t0; unlink(vs_path);
	reply[1] = 6; reply[2] = 0x8060;
	vmsnap_poll(t0 + 1000);
	check(vs_wait, "still waiting at 1 s");
	vmsnap_poll(t0 + 3100);
	READ_VS();
	check(!vs_wait && strstr(vsbuf, "\"timeout\":true,\"busy\":1") != NULL, "times out at 3 s, says busy");

	// ------------------------------------------------------------ the restore
	snprintf(vl_path, sizeof(vl_path), "/tmp/dvd_ctl_test_vl_%d.json", (int)getpid());
	static char vlbuf[512];
	#define READ_VL() do { vlbuf[0] = 0; FILE *lf = fopen(vl_path, "r"); \
		if (lf) { size_t ln_ = fread(vlbuf, 1, sizeof(vlbuf) - 1, lf); vlbuf[ln_] = 0; fclose(lf); } } while (0)

	printf("[12] vmload of a file that is not a snapshot\n");
	fresh(); reply_cmd = 0x7D;
	vmload_request("/nonexistent/snap.json");
	READ_VL();
	check(strstr(vlbuf, "\"unreadable\":true") != NULL && n_cmd == 0, "refused before any SPI");

	printf("[13] vmload sends the snapshot back\n");
	// a snapshot file as vmsnap writes it: fmt 51157, words 4096..4191
	{
		FILE *sf = fopen(vs_path, "w");
		fprintf(sf, "{\"t\":1.0,\"seq\":5,\"fmt\":51157,\"pos_fresh\":1,\"nv_pck_lbn\":87315,"
		        "\"disp_secs\":770,\"words\":[");
		for (int i = 0; i < 96; i++) fprintf(sf, "%s%d", i ? "," : "", 0x1000 + i);
		fprintf(sf, "]}\n");
		fclose(sf);
	}
	fresh(); reply_cmd = 0x7D; reply[0] = 0x5E02; reply_len = 2048;
	vmload_request(vs_path);
	unsigned want_sum = 770 + 0x0001 + 0x5513;            // tm + the fallback RBN's halves
	for (int i = 0; i < 96; i++) want_sum += 0x1000 + i;
	check(n_cmd == 1 && n_disable == 1, "one transaction");
	check(n_words == 7 + 96, "control + fmt + len + sum + tm + rbn x2 + 96 words");
	check(sent[0] == 2, "control word 2 (LOAD)");
	check(sent[1] == 51157 && sent[2] == 96, "fmt and len from the file");
	check(sent[3] == (uint16_t)want_sum, "the checksum is the 16-bit sum of the words");
	check(sent[4] == 770, "the landing time is the file's displayed time");
	check(sent[5] == 0x0001 && sent[6] == 0x5513, "the fallback sector is the file's nv_pck_lbn");
	check(sent[7] == 0x1000 && sent[102] == 0x105F, "the words, in order");
	check(vl_wait, "waits for the verdict");
	{
		// a snapshot with no displayed time lands at the cell start
		FILE *sf = fopen(vs_path, "w");
		fprintf(sf, "{\"fmt\":51157,\"nv_pck_lbn\":5,\"disp_secs\":-1,\"words\":[1,2,3]}\n");
		fclose(sf);
		fresh(); reply_cmd = 0x7D; reply[0] = 0x5E02; reply_len = 2048;
		vmload_request(vs_path);
		check(sent[4] == 0xFFFF, "no displayed time: tm 0xFFFF (the cell start)");
	}

	printf("[14] the verdict: pending is not a result, applied is\n");
	unsigned l0 = vl_t0;
	unlink(vl_path);
	reply[4] = (1u << 13);                                // pending
	vmload_poll(l0 + 25);
	READ_VL();
	check(vl_wait && vlbuf[0] == 0, "pending: still waiting, no file");
	reply[4] = (2u << 13) | (1u << 8);                    // applied, count 1
	vmload_poll(l0 + 50);
	READ_VL();
	check(!vl_wait && strstr(vlbuf, "\"verdict\":2,\"result\":\"applied\"") != NULL, "applied");

	printf("[15] a refusal is named\n");
	vl_wait = 1; vl_t0 = vl_last = l0;
	reply[4] = (5u << 13);
	vmload_poll(l0 + 25);
	READ_VL();
	check(!vl_wait && strstr(vlbuf, "\"result\":\"refused: checksum\"") != NULL, "refused: checksum");

	printf("[16] the displayed picture's time\n");
	// 0:12:51 + 10 frames (30 fps) at the demux front, which is 0.8 s ahead: 770.53 s -> 771
	check(vmsnap_disp_secs(0x001251D0, 162000, 90000, 1, 1) == 771, "front time minus the lead, to the nearest second");
	check(vmsnap_disp_secs(0x001251D0, 90000 + 45000, 90000, 1, 1) == 771, "770.83 s rounds up, not down");
	check(vmsnap_disp_secs(0x001251D0, 90000, 90000, 1, 1) == 771, "no lead: the front time");
	check(vmsnap_disp_secs(0x00125150, 90000, 90000, 1, 1) == 771, "25 fps frames (rate bits 01)");
	check(vmsnap_disp_secs(0x001251D0, 90000, 162000, 1, 1) == 772, "a small negative lead: the picture is into the front VOBU");
	check(vmsnap_disp_secs(0x001251D0, 90000, 270000, 1, 1) == -1, "a lead below -1.5 s (a PTS discontinuity)");
	check(vmsnap_disp_secs(0x001251D0, 90000 + 31 * 90000, 90000, 1, 1) == -1, "a lead over 30 s");
	check(vmsnap_disp_secs(0x001251D0, 162000, 90000, 0, 1) == -1, "a stale position (no NAV since a flush)");
	check(vmsnap_disp_secs(0x001251D0, 162000, 90000, 1, 0) == -1, "a VOBU without a picture");
	check(vmsnap_disp_secs(0x00000000, 162000, 90000, 1, 1) == 0, "a lead past the clock clamps to 0");
	check(vmsnap_disp_secs(0x001261D0, 90000, 90000, 1, 1) == -1, "a malformed clock (61 s)");

	unlink(vl_path);
	unlink(vs_path);
	unlink(nt_log_path);
	unlink(ctl_log_path);
	printf(fails ? "dvd_ctl_test: %d FAILURE(S)\n" : "dvd_ctl_test: ALL GREEN\n", fails);
	return fails ? 1 : 0;
}
