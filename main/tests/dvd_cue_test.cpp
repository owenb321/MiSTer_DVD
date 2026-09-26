// dvd_cue_test.cpp -- host-side tests for .cue sheet support (dvd_cue.cpp).
//
// Two halves. The parser and the layout are pure, so most arms feed sheet TEXT
// and file sizes and check the table. The rest mount real sheets over real
// temporary files and read the byte stream the core would receive, through the
// REAL dvd_cdda.cpp (the virtual WAV) -- so an arm here fails on what the core
// would actually be handed, not on an intermediate the fix names.
//
// Every test file's bytes are a pure function of the LOGICAL disc sector they
// hold (disc_byte), not of the file they sit in. That is what lets two different
// file layouts of one disc -- one file per track with the pregap at the head of
// each file, and EAC's "gaps appended" layout with it at the tail of the previous
// one -- be required to produce the identical stream.
//
// Built and run by main/tests/run_tests.sh, which auto-discovers *_test.cpp.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>

static int fail = 0;
static void check(const char *what, long long got, long long want)
{
	if (got != want) { printf("  FAIL %-58s got %lld want %lld\n", what, got, want); fail = 1; }
	else               printf("  ok   %-58s %lld\n", what, got);
}
static void check_str(const char *what, const char *got, const char *want)
{
	if (strstr(got, want)) printf("  ok   %-58s \"%s\"\n", what, got);
	else { printf("  FAIL %-58s \"%s\" (want \"%s\")\n", what, got, want); fail = 1; }
}

// ---- the Main the module reaches for (the harness stages EMPTY headers) -----
static int      up_count = 0;
static uint8_t  up_blob[512];
static uint32_t up_len = 0;
void user_io_set_index(unsigned char)                   {}
void user_io_set_download(unsigned char, int = 0)       {}
void user_io_file_tx_data(const uint8_t *a, uint32_t n)
{ up_count++; up_len = n; if (n <= sizeof(up_blob)) memcpy(up_blob, a, n); }

static char g_info[256];
static int  g_info_n = 0;
void InfoMessage(const char *m, int = 2000, const char * = 0)
{ g_info_n++; snprintf(g_info, sizeof(g_info), "%s", m); }

static int g_busy = 0;
int dvd_launch_ui_busy(void) { return g_busy; }

// Mount paths in these tests are already absolute.
char *getFullPath(const char *p) { static char b[1024]; snprintf(b, sizeof(b), "%s", p); return b; }

#include "dvd_cdda.h"
#include "dvd_vcd.h"

// The audio source goes through dvd_css in the Main; here it goes straight to the
// real dvd_cdda, which is the part that builds the bytes.
static int g_css_calls = 0;
int dvd_css_open_cdda_source(const dvd_cdda_toc *toc, dvd_cdda_frames_fn rd, void (*on_close)(void))
{ g_css_calls++; return dvd_cdda_open_source(toc, rd, on_close) == 0; }

static int g_vcd_len = -1;
static dvd_vcd_frames_fn g_vcd_rd = 0;
static void (*g_vcd_close)(void) = 0;
int dvd_vcd_open_source(int len, dvd_vcd_frames_fn rd, void (*on_close)(void))
{ g_vcd_len = len; g_vcd_rd = rd; g_vcd_close = on_close; return 0; }

#include "dvd_cdda.cpp"
#include "dvd_cue.cpp"

// ============================================================= fixtures

static uint8_t disc_byte(int dsec, int off)
{
	return (uint8_t)((dsec * 37u + off * 7u + (off >> 9) * 11u + 5u) & 0xFF);
}

static char g_dir[256];

static void path_of(char *out, const char *name) { snprintf(out, 512, "%s/%s", g_dir, name); }

// A file holding logical sectors [d0, d0+n) at `ssize` bytes each.
static void write_sectors(const char *name, int d0, int n, int ssize)
{
	char p[512]; path_of(p, name);
	FILE *f = fopen(p, "wb");
	for (int s = 0; s < n; s++)
		for (int o = 0; o < ssize; o++) fputc(disc_byte(d0 + s, o), f);
	fclose(f);
}

static void write_text(const char *name, const char *text)
{
	char p[512]; path_of(p, name);
	FILE *f = fopen(p, "wb"); fputs(text, f); fclose(f);
}

// Mount and require the virtual WAV to be header + logical sectors [d0, d0+n)
// in order. Returns the number of mismatching bytes.
static long wav_mismatches(int d0, int n)
{
	uint64_t size = dvd_cdda_size();
	if (size != 44ull + (uint64_t)n * 2352) { printf("  (size %llu)\n", (unsigned long long)size); return -1; }
	uint32_t blocks = (uint32_t)((size + 2047) / 2048);
	static uint8_t buf[8 * 2048];
	long bad = 0;
	for (uint32_t b = 0; b < blocks; b += 8)
	{
		uint32_t cnt = (blocks - b < 8) ? blocks - b : 8;
		dvd_cdda_read(buf, b, cnt);
		for (uint32_t i = 0; i < cnt * 2048; i++)
		{
			uint64_t v = (uint64_t)b * 2048 + i;
			if (v < 44 || v >= size) continue;
			uint64_t p = v - 44;
			if (buf[i] != disc_byte(d0 + (int)(p / 2352), (int)(p % 2352))) bad++;
		}
	}
	return bad;
}

static int fd_open(int fd) { return fcntl(fd, F_GETFD) != -1; }

// ============================================================= the arms

static const char *SHEET_SINGLE =
	"\xEF\xBB\xBF" "REM GENRE Rock\r\n"
	"file \"My Album.bin\" binary\r\n"
	"  track 01 audio\r\n"
	"    INDEX 00 00:00:00\r\n"
	"    INDEX 01 00:02:00\r\n"
	"  TRACK 02 AUDIO\r\n"
	"    TITLE \"Two\"\r\n"
	"    INDEX 00 00:26:50\r\n"     // 2000
	"    INDEX 01 00:28:50\r\n"     // 2150
	"    INDEX 02 00:30:00\r\n"     // a sub-index: must move nothing
	"  TRACK 03 AUDIO\r\n"
	"    PREGAP 00:02:00\r\n"
	"    INDEX 01 00:53:25\r\n";    // 4000

static void arm_parse(void)
{
	printf("[1] parse\n");
	dvd_cue_sheet s; char err[200] = "";
	int r = dvd_cue_parse(SHEET_SINGLE, strlen(SHEET_SINGLE), &s, err, sizeof(err));
	check("[1a] BOM/CRLF/lower-case sheet parses", r, 0);
	check("[1b] one FILE", s.nfiles, 1);
	check_str("[1c] quoted name with a space", s.f[0].name, "My Album.bin");
	check("[1d] three TRACKs", s.ntracks, 3);
	check("[1e] TRACK 02 INDEX 00 = 00:26:50 (75 frames/s)", s.t[1].idx0, 2000);
	check("[1f] TRACK 02 INDEX 01 (INDEX 02 ignored)", s.t[1].idx1, 2150);
	check("[1g] TRACK 03 has no INDEX 00", s.t[2].idx0_file, -1);
	check("[1h] TRACK 03 INDEX 01", s.t[2].idx1, 4000);

	const char *unq = "FILE a.bin BINARY\nTRACK 1 MODE2/2352\nINDEX 1 00:00:00\n";
	r = dvd_cue_parse(unq, strlen(unq), &s, err, sizeof(err));
	check("[1i] unquoted name parses", r, 0);
	check_str("[1j] unquoted name", s.f[0].name, "a.bin");
	check("[1k] MODE2/2352 is Mode 2", s.t[0].type, DVD_CUE_TT_MODE2);

	struct { const char *text, *why; } bad[] = {
		{ "TRACK 01 AUDIO\nINDEX 01 00:00:00\n",                    "TRACK before any FILE" },
		{ "FILE a.bin BINARY\nTRACK 01 AUDIO\nINDEX 00 00:00:00\n", "no INDEX 01" },
		{ "FILE a.bin BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:75\n", "bad INDEX" },
		{ "FILE a.bin BINARY\nTRACK 01 AUDIO\nINDEX 01 00:60:00\n", "bad INDEX" },
		{ "FILE a.mp3 MP3\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n",    "MP3 is not supported" },
		{ "FILE a.bin BINARY\nTRACK 01 VIDEO\nINDEX 01 00:00:00\n", "bad TRACK" },
		{ "FILE a.bin BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nINDEX 01 00:01:00\n", "INDEX 01 twice" },
		{ "REM nothing\n",                                           "no TRACKs" },
	};
	for (unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); i++)
	{
		err[0] = 0;
		char what[80]; snprintf(what, sizeof(what), "[1l.%u] refused: %s", i, bad[i].why);
		r = dvd_cue_parse(bad[i].text, strlen(bad[i].text), &s, err, sizeof(err));
		check(what, r, -1);
		check_str(what, err, bad[i].why);
	}

	// The CD maximum is 99 tracks. 99 must parse; the 100th must be REFUSED, never
	// silently dropped (CLAUDE.md "Design to the DVD spec maximum").
	static char big[16384];
	int n = snprintf(big, sizeof(big), "FILE a.bin BINARY\n");
	for (int t = 1; t <= 99; t++)
		n += snprintf(big + n, sizeof(big) - n, "TRACK %02d AUDIO\nINDEX 01 %02d:00:00\n", t, t);
	r = dvd_cue_parse(big, strlen(big), &s, err, sizeof(err));
	check("[1m] 99 TRACKs parse", r, 0);
	check("[1n] ...all 99 kept", s.ntracks, 99);
	snprintf(big + n, sizeof(big) - n, "TRACK 99 AUDIO\nINDEX 01 99:00:00\n");
	r = dvd_cue_parse(big, strlen(big), &s, err, sizeof(err));
	check("[1o] a 100th TRACK is refused", r, -1);
	check_str("[1p] ...with the reason", err, "more than 99 TRACKs");
}

static void arm_build_single(void)
{
	printf("[2] layout: one file, INDEX 00 pregaps\n");
	dvd_cue_sheet s; dvd_cue_layout L; char err[200] = "";
	dvd_cue_parse(SHEET_SINGLE, strlen(SHEET_SINGLE), &s, err, sizeof(err));
	uint64_t fb[1] = { 5000ull * 2352 };
	int r = dvd_cue_build(&s, fb, &L, err, sizeof(err));
	check("[2a] builds", r, 0);
	check("[2b] audio CD", L.kind, DVD_CUE_AUDIO);
	// Track 1's own pregap (0..149) is not served; everything after is.
	check("[2c] served sectors = 5000 - track 1 pregap", L.nsectors, 4850);
	check("[2d] one extent (the bytes are contiguous)", L.nextents, 1);
	check("[2e] extent starts at track 1 INDEX 01", (long long)L.e[0].off, 150ll * 2352);
	check("[2f] three tracks", L.ntracks, 3);
	check("[2g] track 1 starts at 0", L.track_vsec[0], 0);
	// A track starts at its INDEX 01; its INDEX 00 pregap is the END of the track
	// before (a CD player, and the physical TOC, both work that way).
	check("[2h] track 2 starts at ITS INDEX 01, not INDEX 00", L.track_vsec[1], 2150 - 150);
	check("[2i] track 3 starts at its INDEX 01", L.track_vsec[2], 4000 - 150);

	// An INDEX past the end of its file is a broken sheet, not a short track.
	uint64_t shortfb[1] = { 3000ull * 2352 };
	r = dvd_cue_build(&s, shortfb, &L, err, sizeof(err));
	check("[2j] INDEX past EOF refused", r, -1);
	check_str("[2k] ...with the reason", err, "past the end");
}

static void arm_build_mixed_sizes(void)
{
	printf("[3] layout: a data track then audio in ONE file, different sector sizes\n");
	// A mixed-mode game disc: 1000 sectors of MODE1/2048, then audio at 2352. A
	// sheet's times count SECTORS from the file start, so the audio's byte offset
	// is 1000*2048 -- not 1000*2352.
	const char *t = "FILE g.bin BINARY\n"
	                "TRACK 01 MODE1/2048\nINDEX 01 00:00:00\n"
	                "TRACK 02 AUDIO\nINDEX 00 00:13:25\nINDEX 01 00:15:25\n"   // 1000, 1150
	                "TRACK 03 AUDIO\nINDEX 01 00:20:00\n";                     // 1500
	dvd_cue_sheet s; dvd_cue_layout L; char err[200] = "";
	dvd_cue_parse(t, strlen(t), &s, err, sizeof(err));
	uint64_t fb[1] = { 1000ull * 2048 + 1500ull * 2352 };
	int r = dvd_cue_build(&s, fb, &L, err, sizeof(err));
	check("[3a] builds", r, 0);
	check("[3b] audio CD (a MODE1 first track is not a VCD)", L.kind, DVD_CUE_AUDIO);
	check("[3c] data track skipped, first audio pregap skipped", L.nsectors, 1500 - 150);
	check("[3d] audio byte offset carries the 2048-byte data sectors",
	      (long long)L.e[0].off, 1000ll * 2048 + 150ll * 2352);
	check("[3e] two audio tracks", L.ntracks, 2);
	check("[3f] track numbers keep the sheet's numbering", L.track_num[0], 2);
	check("[3g] track 3 start", L.track_vsec[1], 1500 - 1150);
}

static void arm_build_vcd(void)
{
	printf("[4] layout: Video CD span\n");
	// The shape a burned VCD has: a short filesystem track, the MPEG track (with
	// its 2 s pregap in its own file), then a CD-DA track that must NOT be served.
	const char *t = "FILE \"t1.bin\" BINARY\nTRACK 01 MODE2/2352\nINDEX 01 00:00:00\n"
	                "FILE \"t2.bin\" BINARY\nTRACK 02 MODE2/2352\nINDEX 00 00:00:00\nINDEX 01 00:02:00\n"
	                "FILE \"t3.bin\" BINARY\nTRACK 03 AUDIO\nINDEX 00 00:00:00\nINDEX 01 00:02:00\n";
	dvd_cue_sheet s; dvd_cue_layout L; char err[200] = "";
	dvd_cue_parse(t, strlen(t), &s, err, sizeof(err));
	uint64_t fb[3] = { 300ull * 2352, 700ull * 2352, 400ull * 2352 };
	int r = dvd_cue_build(&s, fb, &L, err, sizeof(err));
	check("[4a] builds", r, 0);
	check("[4b] a Mode 2 first track is a Video CD", L.kind, DVD_CUE_VCD);
	check("[4c] span = both data tracks incl. track 2's pregap, no CD-DA", L.nsectors, 1000);
	check("[4d] two extents (two files)", L.nextents, 2);

	// The same disc as ONE hybrid .bin: the span must still stop at the audio.
	const char *h = "FILE d.bin BINARY\nTRACK 01 MODE2/2352\nINDEX 01 00:00:00\n"
	                "TRACK 02 AUDIO\nINDEX 00 00:13:25\nINDEX 01 00:15:25\n";   // 1000, 1150
	dvd_cue_parse(h, strlen(h), &s, err, sizeof(err));
	uint64_t hb[1] = { 2000ull * 2352 };
	r = dvd_cue_build(&s, hb, &L, err, sizeof(err));
	check("[4e] hybrid single .bin builds", r, 0);
	check("[4f] hybrid: stops at the CD-DA track's pregap", L.nsectors, 1000);

	const char *d = "FILE d.bin BINARY\nTRACK 01 MODE1/2352\nINDEX 01 00:00:00\n";
	dvd_cue_parse(d, strlen(d), &s, err, sizeof(err));
	r = dvd_cue_build(&s, hb, &L, err, sizeof(err));
	check("[4g] a data-only MODE1 disc is refused", r, -1);
	check_str("[4h] ...with the reason", err, "no AUDIO track");
}

// ---- live mounts over real files ---------------------------------------------

static void arm_mount_audio_layouts(void)
{
	printf("[5] mounted audio CD: two file layouts of one disc give ONE stream\n");
	// The disc: track 1 = logical sectors 0..999, track 2 = 1000..1899 with a
	// 150-sector pregap (1000..1149), track 3 = 1900..2399 with a 75-sector pregap.
	// Track starts in the served stream: 0, 1150, 1975. 2400 sectors in all.

	// (a) one file per track, each pregap at the HEAD of its own file.
	write_sectors("b1.bin", 0,    1000, 2352);
	write_sectors("b2.bin", 1000,  900, 2352);
	write_sectors("b3.bin", 1900,  500, 2352);
	write_text("pertrack.cue",
		"FILE \"b1.bin\" BINARY\n TRACK 01 AUDIO\n  INDEX 01 00:00:00\n"
		"FILE \"b2.bin\" BINARY\n TRACK 02 AUDIO\n  INDEX 00 00:00:00\n  INDEX 01 00:02:00\n"
		"FILE \"b3.bin\" BINARY\n TRACK 03 AUDIO\n  INDEX 00 00:00:00\n  INDEX 01 00:01:00\n");

	// (b) EAC "gaps appended": each pregap at the TAIL of the previous file.
	write_sectors("c1.bin", 0,    1150, 2352);
	write_sectors("c2.bin", 1150,  825, 2352);
	write_sectors("c3.bin", 1975,  425, 2352);
	write_text("appended.cue",
		"FILE \"c1.bin\" BINARY\n TRACK 01 AUDIO\n  INDEX 01 00:00:00\n"
		" TRACK 02 AUDIO\n  INDEX 00 00:13:25\n"
		"FILE \"c2.bin\" BINARY\n  INDEX 01 00:00:00\n"
		" TRACK 03 AUDIO\n  INDEX 00 00:10:00\n"
		"FILE \"c3.bin\" BINARY\n  INDEX 01 00:00:00\n");

	const char *which[2] = { "pertrack.cue", "appended.cue" };
	for (int k = 0; k < 2; k++)
	{
		char p[512]; path_of(p, which[k]);
		char what[96];
		up_count = 0;
		dvd_cdda_toc_service();
		check(k ? "[5b.0] nothing pending before the mount" : "[5a.0] nothing pending before the mount",
		      up_count, 0);

		int kind = dvd_cue_mount(p);
		snprintf(what, sizeof(what), "[5%c.1] %s mounts as an audio CD", 'a' + k, which[k]);
		check(what, kind, DVD_CUE_AUDIO);
		snprintf(what, sizeof(what), "[5%c.2] stream = logical sectors 0..2399, byte-exact", 'a' + k);
		check(what, wav_mismatches(0, 2400), 0);

		const dvd_cdda_toc *toc = dvd_cdda_get_toc();
		snprintf(what, sizeof(what), "[5%c.3] three tracks", 'a' + k);
		check(what, toc ? toc->ntracks : -1, 3);
		snprintf(what, sizeof(what), "[5%c.4] track 2 starts at its INDEX 01 (1150)", 'a' + k);
		check(what, toc ? toc->tr[1].vsec : -1, 1150);
		snprintf(what, sizeof(what), "[5%c.5] track 3 starts at its INDEX 01 (1975)", 'a' + k);
		check(what, toc ? toc->tr[2].vsec : -1, 1975);

		// The table goes out on the first poll AFTER the mount -- once.
		dvd_cdda_toc_service();
		snprintf(what, sizeof(what), "[5%c.6] table uploaded after the mount", 'a' + k);
		check(what, up_count, 1);
		uint32_t s2 = up_blob[16] | (up_blob[17] << 8) | (up_blob[18] << 16) | ((uint32_t)up_blob[19] << 24);
		snprintf(what, sizeof(what), "[5%c.7] blob: track 2 block = (44+1150*2352)/2048", 'a' + k);
		check(what, s2, (44 + 1150ll * 2352) / 2048);
		dvd_cdda_toc_service();
		snprintf(what, sizeof(what), "[5%c.8] ...and not again on the next poll", 'a' + k);
		check(what, up_count, 1);

		int fd0 = cue_fd[0];
		dvd_cdda_close();
		snprintf(what, sizeof(what), "[5%c.9] closing the source closes the sheet's files", 'a' + k);
		check(what, fd_open(fd0), 0);
	}
}

static void arm_mount_single_and_case(void)
{
	printf("[6] mounted audio CD: one file; a Windows path in a different case\n");
	write_sectors("DISC.BIN", 0, 5000, 2352);
	// Written on Windows: a drive-letter path, backslashes, and the wrong case.
	write_text("single.cue",
		"FILE \"C:\\Rips\\disc.bin\" BINARY\n"
		"TRACK 01 AUDIO\nINDEX 00 00:00:00\nINDEX 01 00:02:00\n"
		"TRACK 02 AUDIO\nINDEX 00 00:26:50\nINDEX 01 00:28:50\n");
	char p[512]; path_of(p, "single.cue");
	check("[6a] mounts", dvd_cue_mount(p), DVD_CUE_AUDIO);
	check("[6b] stream = logical 150..4999 (track 1 pregap dropped)", wav_mismatches(150, 4850), 0);
	dvd_cdda_close();

	write_sectors("m.bin", 0, 20, 2352);
	write_text("moto.cue", "FILE \"m.bin\" MOTOROLA\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n");
	path_of(p, "moto.cue");
	check("[6c] MOTOROLA mounts", dvd_cue_mount(p), DVD_CUE_AUDIO);
	static uint8_t buf[2048];
	dvd_cdda_read(buf, 0, 1);
	long bad = 0;
	for (int v = 44; v < 2048; v++)
	{
		int q = (v - 44) ^ 1;            // big-endian samples come out swapped pairwise
		if (buf[v] != disc_byte(q / 2352, q % 2352)) bad++;
	}
	check("[6d] MOTOROLA audio is byte-swapped to little-endian", bad, 0);
	dvd_cdda_close();
}

static void put32(FILE *f, uint32_t v) { for (int i = 0; i < 4; i++) fputc((v >> (8 * i)) & 0xFF, f); }
static void put16(FILE *f, uint16_t v) { fputc(v & 0xFF, f); fputc(v >> 8, f); }
static void write_wav(const char *name, int ch, int d0, int n)
{
	char p[512]; path_of(p, name);
	FILE *f = fopen(p, "wb");
	uint32_t data = (uint32_t)n * 2352;
	fputs("RIFF", f); put32(f, 4 + 24 + 14 + 8 + data); fputs("WAVE", f);
	fputs("fmt ", f); put32(f, 16); put16(f, 1); put16(f, (uint16_t)ch); put32(f, 44100);
	put32(f, 44100 * 2 * ch); put16(f, (uint16_t)(2 * ch)); put16(f, 16);
	fputs("LIST", f); put32(f, 5); fputs("abcde", f); fputc(0, f);   // odd size: padded
	fputs("data", f); put32(f, data);
	for (int s = 0; s < n; s++) for (int o = 0; o < 2352; o++) fputc(disc_byte(d0 + s, o), f);
	fclose(f);
}

static void arm_mount_wave(void)
{
	printf("[7] mounted audio CD: WAVE files (EAC's per-track .wav)\n");
	write_wav("w1.wav", 2, 0, 300);
	write_wav("w2.wav", 2, 300, 200);
	write_text("wave.cue",
		"FILE \"w1.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n"
		"FILE \"w2.wav\" WAVE\nTRACK 02 AUDIO\nINDEX 01 00:00:00\n");
	char p[512]; path_of(p, "wave.cue");
	check("[7a] mounts", dvd_cue_mount(p), DVD_CUE_AUDIO);
	check("[7b] stream = the data chunks, past a padded LIST chunk", wav_mismatches(0, 500), 0);
	dvd_cdda_close();

	write_wav("mono.wav", 1, 0, 10);
	write_text("mono.cue", "FILE \"mono.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n");
	path_of(p, "mono.cue");
	g_info_n = 0;
	check("[7c] mono WAVE refused", dvd_cue_mount(p), DVD_CUE_NONE);
	check_str("[7d] ...and says why", g_info, "16-bit stereo 44.1 kHz");
}

static void arm_mount_vcd(void)
{
	printf("[8] mounted Video CD\n");
	write_sectors("v1.bin", 0,   300, 2352);
	write_sectors("v2.bin", 300, 700, 2352);
	write_sectors("v3.bin", 5000, 50, 2352);
	write_text("vcd.cue",
		"FILE \"v1.bin\" BINARY\nTRACK 01 MODE2/2352\nINDEX 01 00:00:00\n"
		"FILE \"v2.bin\" BINARY\nTRACK 02 MODE2/2352\nINDEX 00 00:00:00\nINDEX 01 00:02:00\n"
		"FILE \"v3.bin\" BINARY\nTRACK 03 AUDIO\nINDEX 01 00:00:00\n");
	char p[512]; path_of(p, "vcd.cue");
	g_vcd_len = -1;
	check("[8a] mounts as a Video CD", dvd_cue_mount(p), DVD_CUE_VCD);
	check("[8b] VCD source gets the data span only", g_vcd_len, 1000);

	static uint8_t fr[32 * 2352];
	long bad = 0;
	for (int v = 0; v < 1000; v += 16)
	{
		int n = (1000 - v < 16) ? 1000 - v : 16;
		g_vcd_rd(v, n, fr);
		for (int s = 0; s < n; s++)
			for (int o = 0; o < 2352; o++)
				if (fr[(size_t)s * 2352 + o] != disc_byte(v + s, o)) bad++;
	}
	check("[8c] frames = logical sectors 0..999 across the file edge", bad, 0);
	int fd0 = cue_fd[0];
	g_vcd_close();
	check("[8d] the VCD close hook closes the files", fd_open(fd0), 0);

	// MODE2/2336: the rip dropped the sync and header. The core needs the sync at
	// image byte 0 and mode 2 at byte 15, so they are put back.
	write_sectors("x.bin", 0, 20, 2336);
	write_text("x.cue", "FILE \"x.bin\" BINARY\nTRACK 01 MODE2/2336\nINDEX 01 00:00:00\n");
	path_of(p, "x.cue");
	check("[8e] MODE2/2336 mounts as a Video CD", dvd_cue_mount(p), DVD_CUE_VCD);
	check("[8f] ...20 sectors", g_vcd_len, 20);
	g_vcd_rd(0, 20, fr);
	static const uint8_t sync[12] = { 0,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0 };
	check("[8g] sector 0 starts with the CD sync pattern", memcmp(fr, sync, 12), 0);
	check("[8h] ...MSF 00:02:00 (lba 0 + the lead-in)", (fr[12] << 16) | (fr[13] << 8) | fr[14], 0x000200);
	check("[8i] ...mode 2", fr[15], 2);
	check("[8j] sector 19 MSF = 00:02:19 (BCD)", (fr[19 * 2352 + 12] << 16) | (fr[19 * 2352 + 13] << 8) | fr[19 * 2352 + 14], 0x000219);
	bad = 0;
	for (int s = 0; s < 20; s++)
		for (int o = 0; o < 2336; o++)
			if (fr[(size_t)s * 2352 + 16 + o] != disc_byte(s, o)) bad++;
	check("[8k] each 2336-byte sector follows its 16-byte prefix", bad, 0);
	g_vcd_close();
}

static void arm_mount_failures(void)
{
	printf("[9] refused sheets\n");
	write_text("missing.cue", "FILE \"nope.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n");
	char p[512]; path_of(p, "missing.cue");
	g_info_n = 0; g_busy = 0;
	check("[9a] a missing FILE refuses the mount", dvd_cue_mount(p), DVD_CUE_NONE);
	check_str("[9b] ...naming the file", g_info, "nope.bin");
	check("[9c] no source was attached", dvd_cdda_active(), 0);

	// During an MGL launch a notice would freeze the launch (issue #48): the
	// refusal is logged, never shown.
	g_info_n = 0; g_busy = 1;
	check("[9d] refused during an MGL launch too", dvd_cue_mount(p), DVD_CUE_NONE);
	check("[9e] ...but raises NO notice while the launch is busy", g_info_n, 0);
	g_busy = 0;
}

int main(void)
{
	snprintf(g_dir, sizeof(g_dir), "/tmp/dvd_cue_test.XXXXXX");
	if (!mkdtemp(g_dir)) { printf("mkdtemp failed\n"); return 1; }
	printf("dvd_cue_test: fixtures in %s\n", g_dir);

	arm_parse();
	arm_build_single();
	arm_build_mixed_sizes();
	arm_build_vcd();
	arm_mount_audio_layouts();
	arm_mount_single_and_case();
	arm_mount_wave();
	arm_mount_vcd();
	arm_mount_failures();

	char cmd[300]; snprintf(cmd, sizeof(cmd), "rm -rf '%s'", g_dir);
	if (system(cmd)) {}

	printf(fail ? "dvd_cue_test: FAIL\n" : "dvd_cue_test: PASS\n");
	return fail;
}
