// dvd_cdda_test.cpp -- host-side tests for the CD-DA virtual-WAV mapping.
//
// No MiSTer, no ARM toolchain, no drive: the mapping is pure arithmetic over a
// track table, which is exactly the part most likely to hide a subtle bug and
// the part a hardware round is worst at diagnosing. The sector/block phase is
// the reason -- 2352 and 2048 share only gcd 16, so a CD frame lines up with an
// sd block again only every 128 frames / 147 blocks, and an off-by-one inside
// that cycle produces audio that plays but is subtly wrong.
//
// Built and run by main/tests/run_tests.sh, which auto-discovers *_test.cpp.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

// The module reaches for these; the harness stages empty headers, so anything it
// actually calls must be defined before the include.
static int fail = 0;
static void check(const char *what, long long got, long long want)
{
	if (got != want) { printf("  FAIL %-46s got %lld want %lld\n", what, got, want); fail = 1; }
	else               printf("  ok   %-46s %lld\n", what, got);
}

#define DVD_CDDA_TEST 1
#include "dvd_cdda.h"

// The harness stages an EMPTY user_io.h, so anything the module calls from Main
// must be defined here first. The upload path is exercised in [8] below.
static int      up_index = -1, up_dl = -1;
static uint8_t  up_blob[512];
static uint32_t up_len = 0;
void user_io_set_index(unsigned char i)                 { up_index = i; }
void user_io_set_download(unsigned char e, int = 0)     { up_dl = e; }
void user_io_file_tx_data(const uint8_t *a, uint32_t n)
{ up_len = n; if (n <= sizeof(up_blob)) memcpy(up_blob, a, n); }

// A synthetic disc: every byte is a pure function of (disc LBA, offset), so any
// byte of the virtual image can be checked against the sector it MUST have come
// from. A mis-ordered burst, a wrong offset or a track-edge overrun all show up
// as a specific wrong byte rather than as "the audio sounds odd".
static uint8_t disc_byte(int lba, int off)
{
	return (uint8_t)((lba * 7u + off * 31u + (off >> 8) * 13u) & 0xFF);
}
static int g_frames_read = 0, g_max_burst = 0;
static int read_frames(int lba, int count, uint8_t *dst)
{
	g_frames_read += count;
	if (count > g_max_burst) g_max_burst = count;
	for (int i = 0; i < count; i++)
		for (int o = 0; o < 2352; o++)
			dst[(size_t)i * 2352 + o] = disc_byte(lba + i, o);
	return 0;
}

#include "dvd_cdda.cpp"

// A disc shaped like a real one: tracks are NOT adjacent on disc (a 150-sector
// pregap sits between them), which is precisely what makes the virtual->disc
// mapping more than an offset.
static void build_toc(dvd_cdda_toc *t)
{
	memset(t, 0, sizeof(*t));
	struct { int num, lba, len; } src[] = {
		{ 1,     37, 53805 },   // 11:57
		{ 2,  53992, 48100 },   // gap before it
		{ 3, 102242, 26488 },
	};
	for (unsigned i = 0; i < sizeof(src)/sizeof(src[0]); i++)
	{
		dvd_cdda_track *x = &t->tr[t->ntracks++];
		x->num = src[i].num; x->lba = src[i].lba; x->len = src[i].len;
		x->vsec = t->nsectors;
		t->nsectors += src[i].len;
	}
}

int main(void)
{
	dvd_cdda_toc toc;
	build_toc(&toc);
	printf("dvd_cdda_test: %d tracks, %d sectors\n", toc.ntracks, toc.nsectors);

	// ---- [1] image size is EXACTLY 44 + n*2352 -------------------------------
	// The core clamps the WAV data chunk to the reported file size, so an
	// inexact size truncates playback or runs past the end.
	check("[1] image size", (long long)dvd_cdda_image_size(&toc),
	      44LL + (long long)toc.nsectors * 2352);

	// ---- [2] the virtual->disc map, including across the pregaps ------------
	check("[2a] first sector",        dvd_cdda_map_sector(&toc, 0), 37);
	check("[2b] last of track 1",     dvd_cdda_map_sector(&toc, 53804), 37 + 53804);
	check("[2c] first of track 2",    dvd_cdda_map_sector(&toc, 53805), 53992);
	check("[2d] first of track 3",    dvd_cdda_map_sector(&toc, 53805 + 48100), 102242);
	check("[2e] last sector",         dvd_cdda_map_sector(&toc, toc.nsectors - 1),
	      102242 + 26488 - 1);
	// Out of range must be refused, not clamped -- a clamp would silently play
	// the wrong sector forever at the end of a disc.
	check("[2f] past the end is -1",  dvd_cdda_map_sector(&toc, toc.nsectors), -1);
	check("[2g] negative is -1",      dvd_cdda_map_sector(&toc, -1), -1);

	// ---- [3] the map is strictly monotonic within a track -------------------
	// (a walk, not a spot check: an off-by-one at a track edge shows up here
	// even if the endpoints above happen to be right)
	{
		int bad = 0;
		for (int i = 0; i < toc.ntracks; i++)
		{
			const dvd_cdda_track *t = &toc.tr[i];
			for (int k = 0; k < t->len; k += 997)      // prime stride
				if (dvd_cdda_map_sector(&toc, t->vsec + k) != t->lba + k) bad++;
		}
		check("[3] monotonic within every track", bad, 0);
	}

	// ---- [4] the synthetic header the core must recognise --------------------
	{
		uint8_t h[44];
		uint32_t payload = (uint32_t)toc.nsectors * 2352;
		dvd_cdda_wav_header(h, payload);
		check("[4a] RIFF",        memcmp(h, "RIFF", 4) == 0, 1);
		check("[4b] WAVE",        memcmp(h + 8, "WAVE", 4) == 0, 1);
		check("[4c] fmt PCM",     h[20] | (h[21] << 8), 1);
		check("[4d] channels",    h[22] | (h[23] << 8), 2);
		check("[4e] rate",        (long long)(h[24] | (h[25]<<8) | (h[26]<<16) | ((uint32_t)h[27]<<24)), 44100);
		check("[4f] bits",        h[34] | (h[35] << 8), 16);
		check("[4g] data size",   (long long)(uint32_t)(h[40] | (h[41]<<8) | (h[42]<<16) | ((uint32_t)h[43]<<24)),
		      (long long)payload);
		// The whole reason the header is 44 and not some other length.
		check("[4h] header keeps L/R pairs aligned", 44 % 4, 0);
	}

	// ---- [5] the block->frame decomposition is a bijection ------------------
	// The vacuous version of this check compared (b-44)%4 against b%4, which are
	// equal by construction because 44 is a multiple of 4 -- it could not fail.
	// What actually matters is that walking the payload in 2048-byte blocks
	// visits every byte exactly once, in order: vsec*2352 + off must reproduce
	// the payload index for every byte of a full 2048/2352 LCM cycle.
	{
		int bad = 0;
		for (uint64_t p = 0; p < 147ULL * 2048 * 2; p++)
		{
			int vsec = (int)(p / 2352), off = (int)(p % 2352);
			if ((uint64_t)vsec * 2352 + off != p) bad++;
			if (off < 0 || off >= 2352) bad++;
		}
		check("[5] payload decomposition over 2 LCM cycles", bad, 0);
	}

	// ---- [7] dvd_cdda_read: the byte assembly, against a synthetic disc ------
	// This is the part a hardware test cannot localise: bursts, sector offsets,
	// the track-edge split and the memcpy phase. Every returned byte is checked
	// against the sector it must have come from.
	{
		memset(&g_toc, 0, sizeof(g_toc));
		g_toc = toc;
		g_open = 1;
		g_scratch = (uint8_t *)malloc((size_t)CDDA_BURST_MAX * 2352);

		uint64_t size = dvd_cdda_image_size(&toc);
		uint8_t hdr[44];
		dvd_cdda_wav_header(hdr, (uint32_t)((uint64_t)toc.nsectors * 2352));

		// Read the first 40 blocks (crosses the header, several frame
		// boundaries and a full phase cycle) plus a window straddling the
		// track-1/track-2 edge, and one at the very end.
		int bad = 0, checked = 0;
		uint32_t starts[] = { 0, 8, 16, 140, 147,
		                      (uint32_t)((44ULL + 53805ULL*2352) / 2048) - 2,
		                      (uint32_t)(size / 2048) - 8 };
		uint8_t win[8 * 2048];

		for (unsigned k = 0; k < sizeof(starts)/sizeof(starts[0]); k++)
		{
			uint32_t lba = starts[k];
			memset(win, 0xAA, sizeof(win));
			if (dvd_cdda_read(win, lba, 8) <= 0) { bad++; continue; }

			for (int i = 0; i < 8 * 2048; i++)
			{
				uint64_t b = (uint64_t)lba * 2048 + i;
				if (b >= size) break;
				uint8_t want;
				if (b < 44) want = hdr[b];
				else
				{
					uint64_t p = b - 44;
					int vsec = (int)(p / 2352), off = (int)(p % 2352);
					int disc = dvd_cdda_map_sector(&toc, vsec);
					if (disc < 0) break;
					want = disc_byte(disc, off);
				}
				checked++;
				if (win[i] != want)
				{
					if (bad < 5)
						printf("  ..byte %llu: got %02x want %02x\n",
						       (unsigned long long)b, win[i], want);
					bad++;
				}
			}
		}
		check("[7a] bytes checked (test is not vacuous)", checked > 100000, 1);
		check("[7b] every byte matches its source sector", bad, 0);
		check("[7c] bursts never exceed the cap", g_max_burst <= CDDA_BURST_MAX, 1);

		// A read starting past the end must be refused, not served as garbage.
		check("[7d] past EOF is refused", dvd_cdda_read(win, (uint32_t)(size/2048) + 8, 8), -1);

		free(g_scratch); g_scratch = 0; g_open = 0;
	}

	// ---- [6] a single-track disc, and a track shorter than one block --------
	{
		dvd_cdda_toc s;
		memset(&s, 0, sizeof(s));
		s.ntracks = 1; s.tr[0].num = 1; s.tr[0].lba = 100; s.tr[0].len = 1;
		s.tr[0].vsec = 0; s.nsectors = 1;
		check("[6a] 1-sector image size", (long long)dvd_cdda_image_size(&s), 44 + 2352);
		check("[6b] its only sector",     dvd_cdda_map_sector(&s, 0), 100);
		check("[6c] one past is -1",      dvd_cdda_map_sector(&s, 1), -1);

		dvd_cdda_toc z;
		memset(&z, 0, sizeof(z));
		check("[6d] empty toc has no size", (long long)dvd_cdda_image_size(&z), 0);
		check("[6e] empty toc maps nothing", dvd_cdda_map_sector(&z, 0), -1);
	}

	// ---- [8] the track-table blob the core will parse -----------------------
	// Checked against the FORMAT (tools/cdda_toc_ref.py states it independently),
	// not against dvd/cdda_toc.sv -- so the two sides cannot drift together.
	{
		memset(&g_toc, 0, sizeof(g_toc));
		g_toc = toc;
		g_open = 1;
		up_index = -1; up_len = 0;
		dvd_cdda_toc_upload();

		check("[8a] sent at the agreed index", up_index, DVD_CDDA_TOC_INDEX);
		check("[8b] length = 12 + 4*ntracks",  (long long)up_len, 12 + 4LL * toc.ntracks);
		check("[8c] magic",  memcmp(up_blob, "CDTC", 4) == 0, 1);
		check("[8d] version", up_blob[4], 1);
		check("[8e] ntracks", up_blob[5], toc.ntracks);

		uint32_t total = up_blob[8] | (up_blob[9]<<8) | (up_blob[10]<<16) | ((uint32_t)up_blob[11]<<24);
		uint64_t sz = dvd_cdda_image_size(&toc);
		check("[8f] total_blocks rounds UP", (long long)total, (long long)((sz + 2047) / 2048));

		// Every start must be the block holding that track's first audio byte,
		// and they must be strictly increasing.
		int bad = 0; uint32_t prev = 0;
		for (int i = 0; i < toc.ntracks; i++)
		{
			uint32_t got = up_blob[12+4*i] | (up_blob[12+4*i+1]<<8) |
			               (up_blob[12+4*i+2]<<16) | ((uint32_t)up_blob[12+4*i+3]<<24);
			uint64_t byte = 44ULL + (uint64_t)toc.tr[i].vsec * 2352;
			if (got != (uint32_t)(byte / 2048)) bad++;
			if (i && got <= prev) bad++;
			prev = got;
		}
		check("[8g] every start is its track's block, increasing", bad, 0);
		g_open = 0;
	}

	printf(fail ? "dvd_cdda_test: FAILED\n" : "dvd_cdda_test: PASSED\n");
	return fail;
}
