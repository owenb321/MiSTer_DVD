// dvd_cue.cpp — see dvd_cue.h.
//
// A private parser, modelled on stock Main's support/cdi/cdi.cpp load_cue() for
// the rules and deliberately NOT reusing it: every stock parser fills cd.h's
// toc_t, which drags libchdr into an overlay that has stayed dependency-free
// (dvd_cdda.cpp's header says the same about physical_disc.cpp), and all of them
// are file-static anyway.

#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>

#include "dvd_cue.h"
#include "dvd_cdda.h"
#include "dvd_css.h"
#include "dvd_vcd.h"
#include "dvd_launch.h"
#include "../../menu.h"      // InfoMessage() -- the reason a sheet was refused
#include "../../file_io.h"   // getFullPath() -- MiSTer storage path -> absolute

#define CUE_LOG_PATH "/tmp/dvd_cue.log"
static void cue_log(const char *fmt, ...)
{
	char buf[384];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	printf("DVD_CUE: %s\n", buf);
	FILE *f = fopen(CUE_LOG_PATH, "a");
	if (f) { fprintf(f, "%s\n", buf); fclose(f); }
}

static void set_err(char *err, int errsz, const char *fmt, ...)
{
	if (!err || errsz <= 0) return;
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(err, errsz, fmt, ap);
	va_end(ap);
}

// ============================================================== the parser

// Next whitespace-delimited word of `p` into `w`; returns the rest.
static const char *next_word(const char *p, char *w, int wsz)
{
	while (*p == ' ' || *p == '\t') p++;
	int n = 0;
	while (*p && *p != ' ' && *p != '\t')
	{
		if (n < wsz - 1) w[n++] = *p;
		p++;
	}
	w[n] = 0;
	return p;
}

// "mm:ss:ff" -> sectors. ss < 60 and ff < 75 (75 frames per second); mm is left
// unbounded because a sheet for a long single-file image legitimately runs past 99.
static int parse_msf(const char *s, int *out)
{
	int m, sec, f;
	char tail;
	if (sscanf(s, "%d:%d:%d%c", &m, &sec, &f, &tail) != 3) return -1;
	if (m < 0 || sec < 0 || sec >= 60 || f < 0 || f >= 75) return -1;
	*out = (m * 60 + sec) * 75 + f;
	return 0;
}

// TRACK type -> {type, bytes per sector}. -1 when the word is not a cue type.
static int parse_track_type(const char *w, int *type, int *ssize)
{
	static const struct { const char *name; int type, ssize; } tab[] = {
		{ "AUDIO",      DVD_CUE_TT_AUDIO, 2352 },
		{ "MODE2/2352", DVD_CUE_TT_MODE2, 2352 },
		{ "MODE2/2336", DVD_CUE_TT_MODE2, 2336 },
		// Everything below is legal cue syntax but nothing the core plays. It
		// still has a sector size, because its bytes sit in the file between
		// tracks that ARE played and have to be stepped over correctly.
		{ "MODE1/2352", DVD_CUE_TT_OTHER, 2352 },
		{ "MODE1/2048", DVD_CUE_TT_OTHER, 2048 },
		{ "MODE2/2048", DVD_CUE_TT_OTHER, 2048 },
		{ "MODE2/2324", DVD_CUE_TT_OTHER, 2324 },
		{ "CDI/2336",   DVD_CUE_TT_OTHER, 2336 },
		{ "CDI/2352",   DVD_CUE_TT_OTHER, 2352 },
		{ "CDG",        DVD_CUE_TT_OTHER, 2448 },
	};
	for (unsigned i = 0; i < sizeof(tab) / sizeof(tab[0]); i++)
		if (!strcasecmp(w, tab[i].name)) { *type = tab[i].type; *ssize = tab[i].ssize; return 0; }
	return -1;
}

int dvd_cue_parse(const char *text, size_t len, dvd_cue_sheet *s, char *err, int errsz)
{
	memset(s, 0, sizeof(*s));
	if (!text) { set_err(err, errsz, "empty sheet"); return -1; }

	size_t i = 0;
	if (len >= 3 && (uint8_t)text[0] == 0xEF && (uint8_t)text[1] == 0xBB && (uint8_t)text[2] == 0xBF)
		i = 3;   // UTF-8 BOM, which Windows tools like to write

	int lineno = 0;
	while (i < len)
	{
		char line[512];
		int n = 0;
		while (i < len && text[i] != '\n' && text[i] != '\r')
		{
			if (n < (int)sizeof(line) - 1) line[n++] = text[i];
			i++;
		}
		int ln = lineno + 1;   // this line's number, before its terminator is counted
		while (i < len && (text[i] == '\n' || text[i] == '\r'))
		{
			if (text[i] == '\n') lineno++;
			i++;
		}
		line[n] = 0;

		char kw[32];
		const char *rest = next_word(line, kw, sizeof(kw));
		if (!kw[0]) continue;

		if (!strcasecmp(kw, "FILE"))
		{
			if (s->nfiles >= DVD_CUE_MAX_FILES)
			{
				set_err(err, errsz, "more than %d FILEs", DVD_CUE_MAX_FILES);
				return -1;
			}
			// The type is the LAST word; the name is everything before it, with its
			// quotes (if any) removed. That reads both `FILE "a b.bin" BINARY` and the
			// unquoted `FILE a.bin BINARY` some tools write.
			char tmp[512];
			snprintf(tmp, sizeof(tmp), "%s", rest);
			int tl = (int)strlen(tmp);
			while (tl && isspace((unsigned char)tmp[tl - 1])) tmp[--tl] = 0;
			char *sp = tmp + tl;
			while (sp > tmp && !isspace((unsigned char)sp[-1])) sp--;
			if (sp == tmp) { set_err(err, errsz, "line %d: FILE without a type", ln); return -1; }
			const char *ftype = sp;
			sp[-1] = 0;          // end the name at the blank before the type word
			char *nm = tmp;
			while (*nm == ' ' || *nm == '\t') nm++;
			int nl = (int)strlen(nm);
			while (nl && isspace((unsigned char)nm[nl - 1])) nm[--nl] = 0;
			if (nl >= 2 && nm[0] == '"' && nm[nl - 1] == '"') { nm[nl - 1] = 0; nm++; nl -= 2; }
			if (!nl) { set_err(err, errsz, "line %d: FILE without a name", ln); return -1; }

			dvd_cue_file *f = &s->f[s->nfiles];
			if      (!strcasecmp(ftype, "BINARY"))   f->ftype = DVD_CUE_FT_BINARY;
			else if (!strcasecmp(ftype, "MOTOROLA")) f->ftype = DVD_CUE_FT_MOTOROLA;
			else if (!strcasecmp(ftype, "WAVE"))     f->ftype = DVD_CUE_FT_WAVE;
			else
			{
				// MP3 / AIFF / FLAC: compressed or foreign audio this Main cannot decode.
				set_err(err, errsz, "FILE type %s is not supported (BINARY, MOTOROLA or WAVE)", ftype);
				return -1;
			}
			snprintf(f->name, sizeof(f->name), "%.255s", nm);
			s->nfiles++;
		}
		else if (!strcasecmp(kw, "TRACK"))
		{
			if (!s->nfiles) { set_err(err, errsz, "line %d: TRACK before any FILE", ln); return -1; }
			if (s->ntracks >= DVD_CUE_MAX_TRACKS)
			{
				set_err(err, errsz, "more than %d TRACKs", DVD_CUE_MAX_TRACKS);
				return -1;
			}
			char wn[16], wt[32];
			rest = next_word(rest, wn, sizeof(wn));
			next_word(rest, wt, sizeof(wt));
			int num = atoi(wn);
			dvd_cue_track *t = &s->t[s->ntracks];
			if (num < 1 || num > 99 || parse_track_type(wt, &t->type, &t->ssize))
			{
				set_err(err, errsz, "line %d: bad TRACK \"%s %s\"", ln, wn, wt);
				return -1;
			}
			t->num = num;
			t->idx0_file = t->idx1_file = -1;
			t->idx0 = t->idx1 = -1;
			s->ntracks++;
		}
		else if (!strcasecmp(kw, "INDEX"))
		{
			if (!s->ntracks) { set_err(err, errsz, "line %d: INDEX before any TRACK", ln); return -1; }
			char wn[16], wt[32];
			rest = next_word(rest, wn, sizeof(wn));
			next_word(rest, wt, sizeof(wt));
			int idx = atoi(wn), sec;
			if (idx < 0 || idx > 99 || parse_msf(wt, &sec))
			{
				set_err(err, errsz, "line %d: bad INDEX \"%s %s\"", ln, wn, wt);
				return -1;
			}
			dvd_cue_track *t = &s->t[s->ntracks - 1];
			// INDEX 02..99 are sub-indices inside a track: they move no boundary.
			if (idx > 1) continue;
			int *pf = idx ? &t->idx1_file : &t->idx0_file;
			int *ps = idx ? &t->idx1      : &t->idx0;
			if (*pf >= 0)
			{
				set_err(err, errsz, "line %d: TRACK %02d has INDEX %02d twice", ln, t->num, idx);
				return -1;
			}
			// An index belongs to the FILE most recently opened -- which is not
			// always the track's own: EAC's "gaps appended" layout puts INDEX 00 of
			// track N at the end of track N-1's file.
			*pf = s->nfiles - 1;
			*ps = sec;
		}
		// REM, TITLE, PERFORMER, SONGWRITER, CATALOG, ISRC, FLAGS, CDTEXTFILE:
		// metadata. PREGAP/POSTGAP: silence that is not in the file. Nothing to do.
	}

	if (!s->ntracks) { set_err(err, errsz, "no TRACKs"); return -1; }
	for (int t = 0; t < s->ntracks; t++)
		if (s->t[t].idx1_file < 0)
		{
			set_err(err, errsz, "TRACK %02d has no INDEX 01", s->t[t].num);
			return -1;
		}
	return 0;
}

// ============================================================== the layout

typedef struct { int file, sec; } cue_pos;   // sec < 0 = the end of that file

static cue_pos mkpos(int file, int sec) { cue_pos p; p.file = file; p.sec = sec; return p; }

static int pos_cmp(cue_pos a, cue_pos b)
{
	if (a.file != b.file) return a.file < b.file ? -1 : 1;
	return (a.sec > b.sec) - (a.sec < b.sec);
}

typedef struct {
	int      file;
	uint64_t off;
	int      sectors, ssize;
	int      owner;      // track index
	int      pregap;     // between the owner's INDEX 00 and INDEX 01
} cue_piece;

typedef struct {
	const dvd_cue_sheet *s;
	const uint64_t      *fb;
	int       cur_sec[DVD_CUE_MAX_FILES];
	uint64_t  cur_byte[DVD_CUE_MAX_FILES];
	cue_piece p[DVD_CUE_MAX_PIECES];
	int       np;
} cue_walk;

// Carve the sectors of track `ti` from `from` up to (not including) `to` into
// pieces, one per FILE crossed. Sector numbers in a sheet count from each FILE's
// start, but sector SIZES can differ between the tracks of one file (a MODE1/2048
// data track then AUDIO), so byte positions are carried forward per file rather
// than computed as sector*size.
static int emit(cue_walk *w, int ti, cue_pos from, cue_pos to, int pregap, char *err, int errsz)
{
	const dvd_cue_track *t = &w->s->t[ti];
	for (int f = from.file; f <= to.file; f++)
	{
		int a = (f == from.file) ? from.sec : 0;
		if (a < w->cur_sec[f])
		{
			set_err(err, errsz, "TRACK %02d: INDEX points run backwards", t->num);
			return -1;
		}
		// Sectors no track claims (an INDEX 01 past a file's start with no INDEX 00
		// before it, on the first track) are stepped over at this track's size.
		uint64_t byte = w->cur_byte[f] + (uint64_t)(a - w->cur_sec[f]) * t->ssize;
		if (byte > w->fb[f])
		{
			set_err(err, errsz, "TRACK %02d: INDEX is past the end of \"%s\"", t->num, w->s->f[f].name);
			return -1;
		}
		int n;
		if (f == to.file && to.sec >= 0) n = to.sec - a;
		else                             n = (int)((w->fb[f] - byte) / t->ssize);
		if (n < 0 || byte + (uint64_t)n * t->ssize > w->fb[f])
		{
			set_err(err, errsz, "TRACK %02d: INDEX is past the end of \"%s\"", t->num, w->s->f[f].name);
			return -1;
		}
		if (n > 0)
		{
			if (w->np >= DVD_CUE_MAX_PIECES) { set_err(err, errsz, "sheet too fragmented"); return -1; }
			cue_piece *p = &w->p[w->np++];
			p->file = f; p->off = byte; p->sectors = n; p->ssize = t->ssize;
			p->owner = ti; p->pregap = pregap;
		}
		w->cur_sec[f]  = a + n;
		w->cur_byte[f] = byte + (uint64_t)n * t->ssize;
	}
	return 0;
}

int dvd_cue_build(const dvd_cue_sheet *s, const uint64_t *fb, dvd_cue_layout *out,
                  char *err, int errsz)
{
	memset(out, 0, sizeof(*out));
	static cue_walk w;          // ~12 KB; the Main is single-threaded here
	memset(&w, 0, sizeof(w));
	w.s = s;
	w.fb = fb;

	// Every track owns [its first index, the next track's first index). The first
	// index is INDEX 00 when there is one, so a pregap is carved separately and
	// the caller decides whether it is played.
	for (int ti = 0; ti < s->ntracks; ti++)
	{
		const dvd_cue_track *t = &s->t[ti];
		cue_pos i1    = mkpos(t->idx1_file, t->idx1);
		cue_pos first = (t->idx0_file >= 0) ? mkpos(t->idx0_file, t->idx0) : i1;
		if (pos_cmp(first, i1) > 0)
		{
			set_err(err, errsz, "TRACK %02d: INDEX 00 is after INDEX 01", t->num);
			return -1;
		}
		cue_pos end = mkpos(s->nfiles - 1, -1);
		if (ti + 1 < s->ntracks)
		{
			const dvd_cue_track *u = &s->t[ti + 1];
			end = (u->idx0_file >= 0) ? mkpos(u->idx0_file, u->idx0)
			                          : mkpos(u->idx1_file, u->idx1);
			if (pos_cmp(i1, end) > 0)
			{
				set_err(err, errsz, "TRACK %02d starts before TRACK %02d", u->num, t->num);
				return -1;
			}
		}
		if (emit(&w, ti, first, i1, 1, err, errsz)) return -1;
		if (emit(&w, ti, i1, end, 0, err, errsz))   return -1;
	}

	// Which disc is this? See dvd_cue.h.
	int span_end = -1, first_audio = -1;
	if (s->t[0].type == DVD_CUE_TT_MODE2)
	{
		out->kind = DVD_CUE_VCD;
		span_end = 1;
		while (span_end < s->ntracks && s->t[span_end].type == DVD_CUE_TT_MODE2) span_end++;
	}
	else
	{
		for (int ti = 0; ti < s->ntracks; ti++)
			if (s->t[ti].type == DVD_CUE_TT_AUDIO) { first_audio = ti; break; }
		if (first_audio < 0)
		{
			set_err(err, errsz, "no AUDIO track and no Video CD track to play");
			return -1;
		}
		out->kind = DVD_CUE_AUDIO;
	}

	int v = 0, last_owner = -1;
	for (int i = 0; i < w.np; i++)
	{
		const cue_piece *p = &w.p[i];
		const dvd_cue_track *t = &s->t[p->owner];
		int serve;
		if (out->kind == DVD_CUE_VCD)
			serve = p->owner < span_end && !(p->owner == 0 && p->pregap);
		else
			serve = t->type == DVD_CUE_TT_AUDIO && !(p->owner == first_audio && p->pregap);
		if (!serve) continue;

		if (s->f[p->file].ftype == DVD_CUE_FT_WAVE && t->type != DVD_CUE_TT_AUDIO)
		{
			set_err(err, errsz, "TRACK %02d: a data track cannot live in a WAVE file", t->num);
			return -1;
		}

		// A track's INDEX 01 is where its first BODY sector lands. (A body that
		// crosses a FILE boundary arrives as two pieces; only the first counts.)
		if (out->kind == DVD_CUE_AUDIO && !p->pregap && p->owner != last_owner)
		{
			last_owner = p->owner;
			out->track_num[out->ntracks]  = t->num;
			out->track_vsec[out->ntracks] = v;
			out->ntracks++;
		}

		// Merge with the previous extent when the bytes simply continue.
		dvd_cue_extent *e = out->nextents ? &out->e[out->nextents - 1] : 0;
		if (e && e->file == p->file && e->ssize == p->ssize &&
		    e->off + (uint64_t)e->sectors * e->ssize == p->off)
		{
			e->sectors += p->sectors;
		}
		else
		{
			e = &out->e[out->nextents++];
			e->file = p->file; e->off = p->off; e->sectors = p->sectors;
			e->ssize = p->ssize; e->vstart = v;
		}
		v += p->sectors;
	}
	out->nsectors = v;

	if (!v)
	{
		set_err(err, errsz, "the sheet's tracks hold no sectors");
		return -1;
	}
	return 0;
}

void dvd_cue_raw_prefix(uint8_t *p, int lba)
{
	int f = lba + 150;   // MSF counts from the start of the 2-second lead-in
	int m = f / (75 * 60), sec = (f / 75) % 60, fr = f % 75;
	p[0] = 0x00;
	memset(p + 1, 0xFF, 10);
	p[11] = 0x00;
	p[12] = (uint8_t)(((m / 10) << 4) | (m % 10));
	p[13] = (uint8_t)(((sec / 10) << 4) | (sec % 10));
	p[14] = (uint8_t)(((fr / 10) << 4) | (fr % 10));
	p[15] = 0x02;
}

// ============================================================== the live source

static dvd_cue_layout cue_lay;
static int            cue_fd[DVD_CUE_MAX_FILES];
static uint64_t       cue_base[DVD_CUE_MAX_FILES];   // payload offset (a WAVE's data chunk)
static int            cue_swap[DVD_CUE_MAX_FILES];   // MOTOROLA audio
static int            cue_nfd = 0;
static int            cue_last = 0;                  // extent of the previous read
static int            cue_readfail = 0;

void dvd_cue_close(void)
{
	for (int i = 0; i < cue_nfd; i++) if (cue_fd[i] >= 0) close(cue_fd[i]);
	cue_nfd = 0;
	cue_last = 0;
	cue_readfail = 0;
	memset(&cue_lay, 0, sizeof(cue_lay));
}

// Read exactly `n` bytes at `off`, zero-filling whatever the file will not give.
static void pread_full(int fd, uint8_t *dst, size_t n, uint64_t off)
{
	size_t got = 0;
	while (got < n)
	{
		ssize_t r = pread(fd, dst + got, n - got, (off_t)(off + got));
		if (r < 0 && errno == EINTR) continue;
		if (r <= 0) break;
		got += (size_t)r;
	}
	if (got < n)
	{
		memset(dst + got, 0, n - got);
		if (cue_readfail < 10)
		{
			cue_readfail++;
			cue_log("short read at byte %llu (%zu of %zu) -- zero-filled",
			        (unsigned long long)off, got, n);
		}
	}
}

// `n` sectors of extent `e`, from `rel` sectors into it, as raw 2352-byte frames.
static void read_run(const dvd_cue_extent *e, int rel, int n, int vlba, uint8_t *dst)
{
	int      fd   = cue_fd[e->file];
	uint64_t base = cue_base[e->file] + e->off + (uint64_t)rel * e->ssize;

	if (e->ssize == 2352)
	{
		pread_full(fd, dst, (size_t)n * 2352, base);
		if (cue_swap[e->file] && cue_lay.kind == DVD_CUE_AUDIO)
			for (size_t i = 0; i + 1 < (size_t)n * 2352; i += 2)
			{ uint8_t t = dst[i]; dst[i] = dst[i + 1]; dst[i + 1] = t; }
	}
	else if (e->ssize == 2336)
	{
		// Read all n sectors packed at the END of the window, then spread them
		// forward to their 2352-byte slots. Each destination starts at or before
		// its source (16*(i+1-n) <= 0), so ascending memmove never overwrites a
		// sector it has yet to move.
		uint8_t *src = dst + (size_t)n * 16;
		pread_full(fd, src, (size_t)n * 2336, base);
		for (int i = 0; i < n; i++)
			memmove(dst + (size_t)i * 2352 + 16, src + (size_t)i * 2336, 2336);
		for (int i = 0; i < n; i++)
			dvd_cue_raw_prefix(dst + (size_t)i * 2352, vlba + i);
	}
	else
	{
		memset(dst, 0, (size_t)n * 2352);   // dvd_cue_build() never serves one
	}
}

int dvd_cue_read_frames(int vlba, int count, uint8_t *dst)
{
	while (count > 0)
	{
		// Reads are overwhelmingly sequential, so try the last extent first.
		int k = -1;
		for (int j = 0; j < cue_lay.nextents; j++)
		{
			int x = (cue_last + j) % cue_lay.nextents;
			const dvd_cue_extent *e = &cue_lay.e[x];
			if (vlba >= e->vstart && vlba < e->vstart + e->sectors) { k = x; break; }
		}
		if (k < 0) { memset(dst, 0, (size_t)count * 2352); return 0; }
		cue_last = k;

		const dvd_cue_extent *e = &cue_lay.e[k];
		int rel = vlba - e->vstart;
		int n   = e->sectors - rel;
		if (n > count) n = count;
		read_run(e, rel, n, vlba, dst);
		dst   += (size_t)n * 2352;
		vlba  += n;
		count -= n;
	}
	return 0;
}

// --------------------------------------------------------------- file helpers

// Open FILE `name` from the sheet's folder `dir`. Sheets are often written on
// Windows, so try, in order: the name as written (backslashes as slashes), its
// bare file name, and a case-insensitive match of that file name in `dir` (a
// CIFS share is case-sensitive where the ripping PC was not).
static int open_track_file(const char *dir, const char *name, char *used, int usedsz)
{
	char nm[256];
	snprintf(nm, sizeof(nm), "%s", name);
	for (char *c = nm; *c; c++) if (*c == '\\') *c = '/';

	char path[1024];
	if (nm[0] == '/') snprintf(path, sizeof(path), "%s", nm);
	else              snprintf(path, sizeof(path), "%s/%s", dir, nm);
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd >= 0) { snprintf(used, usedsz, "%s", path); return fd; }

	const char *base = strrchr(nm, '/');
	base = base ? base + 1 : nm;
	snprintf(path, sizeof(path), "%s/%s", dir, base);
	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd >= 0) { snprintf(used, usedsz, "%s", path); return fd; }

	DIR *d = opendir(dir);
	if (!d) return -1;
	struct dirent *de;
	while ((de = readdir(d)))
		if (!strcasecmp(de->d_name, base))
		{
			snprintf(path, sizeof(path), "%s/%s", dir, de->d_name);
			fd = open(path, O_RDONLY | O_CLOEXEC);
			if (fd >= 0) snprintf(used, usedsz, "%s", path);
			break;
		}
	closedir(d);
	return fd;
}

static uint32_t le32(const uint8_t *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }

// Locate a WAVE file's PCM payload. Only CD audio can stand in for CD frames:
// 16-bit stereo 44.1 kHz, plain PCM (or the EXTENSIBLE wrapper around it).
static int wave_payload(int fd, uint64_t fsize, uint64_t *off, uint64_t *len, char *err, int errsz)
{
	uint8_t h[12];
	if (pread(fd, h, 12, 0) != 12 || memcmp(h, "RIFF", 4) || memcmp(h + 8, "WAVE", 4))
	{
		set_err(err, errsz, "not a RIFF/WAVE file");
		return -1;
	}
	uint64_t pos = 12;
	int fmt_ok = 0;
	while (pos + 8 <= fsize)
	{
		uint8_t c[8];
		if (pread(fd, c, 8, (off_t)pos) != 8) break;
		uint32_t sz = le32(c + 4);
		if (!memcmp(c, "fmt ", 4))
		{
			uint8_t f[16];
			if (sz < 16 || pread(fd, f, 16, (off_t)(pos + 8)) != 16) break;
			uint16_t tag = le16(f), ch = le16(f + 2), bits = le16(f + 14);
			uint32_t rate = le32(f + 4);
			if ((tag != 1 && tag != 0xFFFE) || ch != 2 || rate != 44100 || bits != 16)
			{
				set_err(err, errsz, "WAVE must be 16-bit stereo 44.1 kHz PCM (got %u ch, %u Hz, %u bit)",
				        ch, rate, bits);
				return -1;
			}
			fmt_ok = 1;
		}
		else if (!memcmp(c, "data", 4))
		{
			if (!fmt_ok) break;
			*off = pos + 8;
			*len = sz;
			if (*off + *len > fsize) *len = fsize - *off;   // a truncated or streamed file
			return 0;
		}
		pos += 8 + (uint64_t)sz + (sz & 1);
	}
	set_err(err, errsz, "WAVE has no playable fmt/data chunks");
	return -1;
}

static int cue_fail(const char *path, const char *why)
{
	cue_log("%s: %s", path, why);
	// A notice raised while an MGL launch is in flight pins MENU_INFO and freezes
	// the launch (issue #48, docs/mgl_launch.md). The log line above always lands.
	if (!dvd_launch_ui_busy())
	{
		char msg[200];
		snprintf(msg, sizeof(msg), "Cannot play this CUE sheet\n\n%.150s", why);
		InfoMessage(msg, 4000, "DVD");
	}
	dvd_cue_close();
	return DVD_CUE_NONE;
}

int dvd_cue_mount(const char *path)
{
	static dvd_cue_sheet sheet;   // ~27 KB: keep it off the stack
	char err[200] = { 0 };
	char full[1024];

	dvd_cue_close();
	snprintf(full, sizeof(full), "%s", getFullPath(path));

	// ---- the sheet itself
	int cfd = open(full, O_RDONLY | O_CLOEXEC);
	if (cfd < 0) return cue_fail(path, "cannot open the sheet");
	struct stat st;
	if (fstat(cfd, &st) || st.st_size <= 0 || st.st_size > DVD_CUE_MAX_TEXT)
	{
		close(cfd);
		return cue_fail(path, "the sheet is empty or too large to be a cue sheet");
	}
	char *text = (char *)malloc((size_t)st.st_size);
	if (!text) { close(cfd); return cue_fail(path, "out of memory"); }
	uint8_t *tp = (uint8_t *)text;
	size_t tlen = (size_t)st.st_size;
	pread_full(cfd, tp, tlen, 0);
	close(cfd);
	int pr = dvd_cue_parse(text, tlen, &sheet, err, sizeof(err));
	free(text);
	if (pr) return cue_fail(path, err);

	// ---- its FILEs, resolved from the sheet's own folder
	char dir[1024];
	snprintf(dir, sizeof(dir), "%s", full);
	char *slash = strrchr(dir, '/');
	if (slash) *slash = 0; else snprintf(dir, sizeof(dir), ".");

	uint64_t fbytes[DVD_CUE_MAX_FILES];
	for (int i = 0; i < sheet.nfiles; i++)
	{
		char used[1024] = { 0 };
		int fd = open_track_file(dir, sheet.f[i].name, used, sizeof(used));
		if (fd < 0)
		{
			snprintf(err, sizeof(err), "missing FILE \"%.150s\"", sheet.f[i].name);
			return cue_fail(path, err);
		}
		cue_fd[cue_nfd++] = fd;
		struct stat fs;
		if (fstat(fd, &fs)) return cue_fail(path, "cannot stat a FILE");
		cue_base[i] = 0;
		cue_swap[i] = sheet.f[i].ftype == DVD_CUE_FT_MOTOROLA;
		fbytes[i] = (uint64_t)fs.st_size;
		if (sheet.f[i].ftype == DVD_CUE_FT_WAVE)
		{
			char why[160];
			if (wave_payload(fd, (uint64_t)fs.st_size, &cue_base[i], &fbytes[i], why, sizeof(why)))
			{
				snprintf(err, sizeof(err), "\"%.60s\": %.130s", sheet.f[i].name, why);
				return cue_fail(path, err);
			}
		}
	}

	if (dvd_cue_build(&sheet, fbytes, &cue_lay, err, sizeof(err))) return cue_fail(path, err);
	cue_last = 0;
	cue_readfail = 0;

	// ---- hand it to the source that plays it
	if (cue_lay.kind == DVD_CUE_AUDIO)
	{
		static dvd_cdda_toc toc;
		memset(&toc, 0, sizeof(toc));
		for (int i = 0; i < cue_lay.ntracks; i++)
		{
			dvd_cdda_track *t = &toc.tr[toc.ntracks++];
			int next = (i + 1 < cue_lay.ntracks) ? cue_lay.track_vsec[i + 1] : cue_lay.nsectors;
			t->num  = cue_lay.track_num[i];
			t->vsec = cue_lay.track_vsec[i];
			t->lba  = t->vsec;           // our own numbering: virtual == source sector
			t->len  = next - t->vsec;
		}
		toc.nsectors = cue_lay.nsectors;
		if (!dvd_css_open_cdda_source(&toc, dvd_cue_read_frames, dvd_cue_close))
			return cue_fail(path, "could not start the audio source");
		cue_log("%s: audio CD, %d track(s), %d sectors from %d file(s)",
		        path, toc.ntracks, cue_lay.nsectors, sheet.nfiles);
		return DVD_CUE_AUDIO;
	}

	if (dvd_vcd_open_source(cue_lay.nsectors, dvd_cue_read_frames, dvd_cue_close))
		return cue_fail(path, "could not start the Video CD source");
	cue_log("%s: Video CD span, %d sectors from %d file(s)", path, cue_lay.nsectors, sheet.nfiles);
	return DVD_CUE_VCD;
}
