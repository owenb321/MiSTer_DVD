// dvd_cue.h — .cue sheets (audio CD and Video CD / Super Video CD rips),
// served to the core with NO fabric change.
//
// The core never sees a file's extension; it decides what an image is from its
// first bytes (dvd_iso_reader.sv S_CHK_RAW). So a .cue is handled entirely here,
// by building one of the two byte streams the core already plays:
//
//   AUDIO  the physical-CD "one giant WAV" (dvd_cdda.h): a 44-byte RIFF header,
//          then every AUDIO track's 2352-byte frames concatenated, plus the track
//          table on ioctl index 250 so the HUD reads "TR n/N" and skips work.
//   VCD    the raw MODE2/2352 span a physical VCD serves (dvd_vcd.h): track 1
//          through the last CONSECUTIVE Mode 2 track, sync pattern at byte 0.
//          CD-DA tracks on a hybrid disc are left out -- which a whole-disc .bin
//          picked directly cannot do, since the core streams the whole file.
//
// The cue's FILEs are the sectors; they are never copied or rewritten, only read
// by the read-ahead worker (dvd_readahead.h) through dvd_cue_read_frames().
//
// Which one it is: a Mode 2 first track is a Video CD (that is how every VCD and
// SVCD is laid out); otherwise, any AUDIO track makes it an audio CD, and the
// data tracks of a mixed-mode or CD-Extra disc are skipped just as the physical
// path skips them. A Mode 2 image that is not actually a VCD (a PlayStation game,
// say) behaves exactly as picking its .bin always has: the core finds no MPEG and
// says UNSUPPORTED IMAGE.
//
// Track geometry follows a real CD, and the physical path, exactly: a track
// STARTS at its INDEX 01, and the next track's INDEX 00 pregap plays at the END
// of the track before it. The first audio track's own pregap is not served.
// INDEX 02..99 are sub-indices and move nothing. PREGAP/POSTGAP describe silence
// that is NOT in the file, so there is nothing to serve for them.
//
// Sizes are the CD maxima (99 tracks; 99 FILEs, the one-file-per-track rip),
// never a sample of rips. A sheet past either is refused with a log line rather than
// truncated -- see CLAUDE.md "Design to the DVD spec maximum".
//
// The parser and the layout are PURE (text in, table out) so the host test can
// exercise every rule without files; dvd_cue_mount() is the only part that
// touches the filesystem.

#ifndef MISTER_DVD_CUE_H
#define MISTER_DVD_CUE_H

#include <stdint.h>
#include <stddef.h>

#define DVD_CUE_MAX_TRACKS  99
#define DVD_CUE_MAX_FILES   99
// Every track contributes a pregap span and a body span, and a span crossing a
// FILE boundary splits once per boundary it crosses.
#define DVD_CUE_MAX_PIECES  (2 * DVD_CUE_MAX_TRACKS + DVD_CUE_MAX_FILES + 2)
#define DVD_CUE_MAX_TEXT    (256 * 1024)   // a 99-track sheet is ~10 KB

enum { DVD_CUE_NONE = 0, DVD_CUE_AUDIO = 1, DVD_CUE_VCD = 2 };

// FILE types. MOTOROLA is big-endian 16-bit audio (swapped on the way out);
// WAVE is a .wav per track, as EAC and most rippers write.
enum { DVD_CUE_FT_BINARY = 0, DVD_CUE_FT_MOTOROLA, DVD_CUE_FT_WAVE };

// TRACK types this module can serve. Everything else (MODE1/*, MODE2/2048, CDG,
// CDI/*) parses as OTHER: it is never served, and it ends a Video CD's span.
enum { DVD_CUE_TT_AUDIO = 0, DVD_CUE_TT_MODE2, DVD_CUE_TT_OTHER };

typedef struct {
	char name[256];     // as written in the sheet (relative to the sheet's folder)
	int  ftype;
} dvd_cue_file;

typedef struct {
	int num;            // TRACK nn
	int type;           // DVD_CUE_TT_*
	int ssize;          // bytes per sector in the file (2352, 2336, 2048, ...)
	int idx0_file, idx0;   // INDEX 00: FILE index and sector from that file's start; -1 = none
	int idx1_file, idx1;   // INDEX 01 (required)
} dvd_cue_track;

typedef struct {
	dvd_cue_file  f[DVD_CUE_MAX_FILES];
	int           nfiles;
	dvd_cue_track t[DVD_CUE_MAX_TRACKS];
	int           ntracks;
} dvd_cue_sheet;

// A run of consecutive served sectors, all from one FILE.
typedef struct {
	int      file;
	uint64_t off;       // byte offset of the first sector within the file's payload
	int      sectors;
	int      ssize;
	int      vstart;    // first virtual sector (the core-facing numbering)
} dvd_cue_extent;

typedef struct {
	int            kind;                        // DVD_CUE_AUDIO / DVD_CUE_VCD
	dvd_cue_extent e[DVD_CUE_MAX_PIECES];
	int            nextents;
	int            nsectors;                    // total served sectors
	// AUDIO only: where each audio track's INDEX 01 lands in the served stream.
	int            ntracks;
	int            track_num[DVD_CUE_MAX_TRACKS];
	int            track_vsec[DVD_CUE_MAX_TRACKS];
} dvd_cue_layout;

// --- pure (no files, no globals) -- the host test's main surface ------------

// Parse a sheet. Returns 0 and fills `out`, or -1 with a one-line reason in
// `err`. Keywords are case-insensitive; CRLF and a UTF-8 BOM are accepted; lines
// it has no use for (REM, TITLE, PERFORMER, CATALOG, ISRC, FLAGS, CDTEXTFILE,
// SONGWRITER, PREGAP, POSTGAP) are ignored.
int dvd_cue_parse(const char *text, size_t len, dvd_cue_sheet *out, char *err, int errsz);

// Lay the sheet out against its files. `file_bytes[i]` is the playable length of
// FILE i: the whole file for BINARY/MOTOROLA, the `data` chunk for a WAVE.
// Returns 0 and fills `out`, or -1 with a reason.
int dvd_cue_build(const dvd_cue_sheet *s, const uint64_t *file_bytes,
                  dvd_cue_layout *out, char *err, int errsz);

// The 16 bytes a MODE2/2336 sector is missing to become a raw 2352-byte one:
// the sync pattern, the BCD MSF of `lba` (+150, the lead-in) and mode 2.
// dvd_iso_reader.sv needs the sync at image byte 0 and the mode at byte 15.
void dvd_cue_raw_prefix(uint8_t *p, int lba);

// --- the live source ----------------------------------------------------------

// Parse `path` (a MiSTer storage path, as user_io_file_mount() receives it), open
// its FILEs, and attach the result to the matching source: an audio CD through
// dvd_css (so the slot is SD_TYPE_DVDCSS), a Video CD through dvd_vcd
// (SD_TYPE_VCD). Returns the DVD_CUE_* kind, or DVD_CUE_NONE on any failure (the
// reason is logged and, when a notice is safe to raise, shown).
int  dvd_cue_mount(const char *path);

// Read `count` consecutive virtual sectors as raw 2352-byte frames: the source
// callback handed to dvd_cdda / dvd_vcd. Fills every byte; zero-fills what it
// cannot read.
int  dvd_cue_read_frames(int vlba, int count, uint8_t *dst);

// Release the files. Called by dvd_cdda_close() / dvd_vcd_close() through the
// source's on_close hook, after the read-ahead has stopped.
void dvd_cue_close(void);

#endif
