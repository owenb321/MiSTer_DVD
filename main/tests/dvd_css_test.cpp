// dvd_css_test.cpp — where dvd_css_read() asks libdvdcss for a title key.
//
// Field report 2026-09-17: on a physical disc, Prev/Next Chapter froze the whole
// machine for minutes and then played the chapter. Reproduced by the maintainer on
// their own copy, on a drive with no region set, with the decisive evidence: NEW KEY
// FILES APPEARED IN THE DVDCSS CACHE AS THE SEEKS HAPPENED. It was cracking a title
// key at every skip.
//
// Cause: dvd_css_read() fired DVDCSS_SEEK_KEY on ANY discontinuity, at the ARBITRARY
// target LBA. libdvdcss matches its title cache on the EXACT start LBA -- measured in
// the shipped libdvdcss.so.2 (1.6.0), where _dvdcss_title is inlined into dvdcss_seek:
// list walk, then `cmp (%rdx),%ebx; je <hit>`; the on-disk cache is a file named
// "%.10x" of the block. crack_title_keys() only primes g_vobs[i].start, so every
// chapter start MISSED and re-acquired -- a full statistical crack on a no-region
// drive, on the thread that feeds the core. Linear playback never tripped it
// (lba == css_pos), which is why it only ever showed on a seek.
//
// libdvdread is the oracle: one key per VOB file, taken at the file start and never
// at the read offset (dvd_reader.c DVDReadBlocks()).
//
// The fake p_seek below models the cache the way libdvdcss actually behaves -- a
// SEEK_KEY at a block that has not been asked for before COSTS AN ACQUISITION and is
// then cached. So the test measures the thing the user experiences (how many keys get
// cracked), not a signal the fix names.
//
// MEASURED, not predicted. `run_tests.sh --red` css-rekey-every-seek restores the
// shipped behaviour exactly (re-key on any discontinuity, at the read LBA) and the
// field symptom reproduces -- 5 failures, the first of which is the freeze:
//   [2] title keys acquired over 17 chapter skips  17  (expect 0)   FAIL
//   [3] SEEK_KEY calls at a non-VOB-start block    17  (expect 0)   FAIL
//   [4] title keys acquired crossing VOBs           3  (expect 0)   FAIL
//   [4] SEEK_KEY calls at a non-VOB-start block     3  (expect 0)   FAIL
//   [5] extra SEEK_KEY calls for a same-VOB seek    1  (expect 0)   FAIL
// and css-key-verdict-not-latched, the second (pre-existing) defect, gives:
//   [6] decrypted reads after the key seek failed   3  (expect 0)   FAIL
//   [6] raw reads after the key seek failed         0  (expect 3)   FAIL
//
// ⚠ The test cannot be compiled against the true pre-fix file -- it resets key_ok,
// which did not exist -- so the RED arm restores the BEHAVIOUR by mutation rather
// than checking the old file out of git. That is weaker than the usual R0 arm here;
// what keeps it honest is that the mutation is a one-line restoration of the two
// expressions that changed, and it is spelled out in run_tests.sh.
//
// [1] and [7]-[8] are controls, and css-never-keys is the one that matters most:
// every bug above is trivially "fixed" by never asking for a key at all, which
// would silently stop decrypting instead.
//
// [9]-[11] are issue #112: the VOB TABLE. A VOB missing from it is read raw and
// plays scrambled with nothing logged. [9] is "OZ: The Great and Powerful"'s real
// 91-entry layout (one feature extent filed under 11 title sets); the shipped
// 64-entry, no-dedupe table left its VTS_20 sneak peeks unregistered.
//
// [15]-[19] are issue #122: CSS ENCRYPTED after a chapter skip on physical "Hitch"
// and "Kung Fu Panda", on a drive with no region set. The fake grows a CSS MODEL
// (see model_sector) built from what libdvdcss 1.6.0 was measured to do on those
// discs: a crack that sees 2000 clean sectors caches an ALL-ZERO key, a too-short
// VOB cannot be cracked at all, and a zero key leaves sectors scrambled. The arms
// score what reaches the core -- scrambled sectors, and sectors decrypted to noise
// by a wrong key -- never a signal the fix names.
//
// Host-side: build with main/tests/run_tests.sh. The module is #included so the
// dlopen'd libdvdcss entry points can be replaced with recording stubs.

#include <stdio.h>
#include <string.h>
#include <stdint.h>

// ------------------------------------------------------------------- stubs
// Defined BEFORE the module is included, so they are in scope by the time its own
// "../../menu.h" and "../../file_io.h" (staged empty on purpose) would have
// declared them -- no second copy of Main's API here to drift out of date.
void ProgressMessage(const char * = 0, const char * = 0, int = 0, int = 0) {}
void InfoMessage(const char *, int = 2000, const char * = 0) {}
char *getFullPath(const char *) { static char p[8] = ""; return p; }
int dvd_launch_ui_busy(void) { return 0; }

// The CD-DA source shares this module's front door (see the two-source note in
// dvd_css.cpp), so dvd_css.cpp references it even on the pure-CSS path. Stubbed
// out here so this test stays about CSS: cd_audio_probe() says "no audio CD", so
// find_audio_cd() never finds one and dvd_cdda_open() is never reached at all.
// ⚠ dvd_cdda_open() returns 0 on SUCCESS (see dvd_cdda.h), so the stub returns 1.
#include "dvd_cdda.h"   // the types the two newest stubs take
int cd_audio_probe(int) { return 0; }
int dvd_cdda_open(int, const char *) { return 1; }
uint64_t dvd_cdda_size(void) { return 0; }
int dvd_cdda_read(void *, uint32_t, uint32_t) { return -1; }
void dvd_cdda_close(void) {}
int dvd_cdda_open_source(const dvd_cdda_toc *, dvd_cdda_frames_fn, void (*)(void)) { return -1; }
void dvd_cdda_toc_service(void) {}

#include "dvd_css.cpp"
#include "dvd_readahead.cpp"

// --------------------------------------------------------------- fake libdvdcss
#define MAXCALLS 512
static struct { int block, flags; } seeks[MAXCALLS];
static int nseeks;
static int reads_decrypt, reads_raw, last_count;

// Blocks whose title key libdvdcss already holds. crack_title_keys() primes the VOB
// starts at mount; anything else costs an acquisition (the crack) and is then cached
// -- which is exactly why the maintainer saw the cache directory grow.
static int primed[MAXCALLS], nprimed;
static int key_acquisitions;
static int fail_key_at = -1;      // a block whose SEEK_KEY refuses (no key obtainable)

// A tiny ISO9660 image for the enumerate_vobs() arms: sector LBAs -> 2048 bytes.
// Everything else reads as "success, contents unspecified", as before.
#define FIX_MAX 64
static uint32_t fix_lba[FIX_MAX];
static uint8_t  fix_sec[FIX_MAX][2048];
static int      nfix;
static int      cur_block;

static uint8_t *fix_sector(uint32_t lba)
{
    for (int i = 0; i < nfix; i++) if (fix_lba[i] == lba) return fix_sec[i];
    if (nfix >= FIX_MAX) return 0;
    fix_lba[nfix] = lba;
    memset(fix_sec[nfix], 0, 2048);
    return fix_sec[nfix++];
}

// The stamp sits at STAMP, clear of the pack header the CSS model writes at 0x00
// and of the 0x80.. region libdvdcss decrypts (so it can never read as a start code).
#define STAMP 0x40
static void put_stamp(uint8_t *q, uint32_t lba, int dec)
{
    q += STAMP;
    q[0] = lba; q[1] = lba >> 8; q[2] = lba >> 16; q[3] = lba >> 24; q[4] = (uint8_t)dec;
}
static uint32_t get_lba(const uint8_t *q) { q += STAMP; return q[0] | q[1] << 8 | q[2] << 16 | (uint32_t)q[3] << 24; }

// ---- the CSS model (issue #122) ---------------------------------------------
// With model_on, every VOB sector is a real-shaped pack, and CSS behaves the way
// libdvdcss 1.6.0 was measured to behave on the two reported discs:
//  - a title key is a small integer; `scr[]` lists the scrambled sector ranges and
//    the key each was scrambled under;
//  - SEEK_KEY at an unseen block CRACKS (css.c CrackTitleKey): it scans forward
//    from the block and, if 2000 consecutive sectors hold no scrambled one, gives
//    up with an ALL-ZERO key that it caches ("no scrambled sectors found") -- the
//    Hitch failure; a range marked `uncrackable` makes the crack fail outright
//    (-1, nothing cached) -- the Kung Fu Panda VTS_14_1 failure;
//  - a DECRYPT read with key 0 leaves a scrambled sector exactly as it was (bits
//    set); with the right key it clears the bits and the payload carries MPEG
//    start codes; with a WRONG key it clears the bits and the payload is noise.
// So a test can score what reaches the core: good_sectors() below.
static int model_on;
static struct { uint32_t lo, hi; int key, uncrackable; } scr[16];
static int nscr;
static int cur_libkey;                 // libdvdcss's current title key (0 = none/zero)
static int primed_key[MAXCALLS];       // key held for primed[i] (the title list + cache)

static int scr_at(uint32_t lba)
{
    for (int i = 0; i < nscr; i++) if (lba >= scr[i].lo && lba < scr[i].hi) return i;
    return -1;
}
static void add_scr(uint32_t lo, uint32_t hi, int key, int uncrackable)
{
    scr[nscr].lo = lo; scr[nscr].hi = hi; scr[nscr].key = key; scr[nscr].uncrackable = uncrackable;
    nscr++;
}
// CrackTitleKey() from block b: -1 fail, 0 zero key, else the key.
static int model_crack(uint32_t b)
{
    for (uint32_t s = b; s < b + 2000; s++)
    {
        int r = scr_at(s);
        if (r >= 0) return scr[r].uncrackable ? -1 : scr[r].key;
    }
    return 0;
}
static void model_sector(uint8_t *q, uint32_t lba, int decrypt)
{
    memset(q, 0, 2048);
    q[2] = 1; q[3] = 0xBA; q[0x0D] = 0xF8;                 // pack, no stuffing
    q[0x10] = 1; q[0x11] = 0xE0; q[0x14] = 0x80;           // video PES, '10' flags
    int r = scr_at(lba);
    int clear = (r < 0) || (decrypt && cur_libkey != 0);
    int right = (r < 0) || (decrypt && cur_libkey == scr[r].key);
    if (!clear) q[0x14] |= 0x30;                           // still scrambled
    if (right) { q[0x100 + 2] = 1; q[0x100 + 3] = 0xB3; q[0x300 + 2] = 1; q[0x300 + 3] = 0x01; }
    else       memset(q + 0x80, 0xA5, 2048 - 0x80);        // noise: no start codes
}

static int fake_seek(dvdcss_t, int block, int flags)
{
    cur_block = block;
    if (nseeks < MAXCALLS) { seeks[nseeks].block = block; seeks[nseeks].flags = flags; }
    nseeks++;

    if (flags & DVDCSS_SEEK_KEY)
    {
        if (block == fail_key_at) return -1;
        int hit = -1;
        for (int i = 0; i < nprimed; i++) if (primed[i] == block) hit = i;
        if (hit >= 0) { cur_libkey = primed_key[hit]; return block; }
        key_acquisitions++;                                   // seconds to minutes
        int k = model_on ? model_crack((uint32_t)block) : 1;
        if (k < 0) return -1;                                 // a failed crack caches nothing
        if (nprimed < MAXCALLS) { primed[nprimed] = block; primed_key[nprimed] = k; nprimed++; }
        cur_libkey = k;
    }
    return block;
}

// Every sector the fake hands back is STAMPED with its own LBA (bytes 0-3) and
// whether it came through the decrypt path (byte 4), so a test can check that each
// slot of a window holds the sector it claims to -- which is exactly what a stale
// slot does not. Reads at or past `fail_read_from` fail: the first sector of the
// call errors (-1), otherwise the call comes back short, as a block device does.
static int fail_read_from = -1;
static int nreadcalls, readcall_count[MAXCALLS];

static int fake_read(dvdcss_t, void *buf, int count, int flags)
{
    if (nreadcalls < MAXCALLS) readcall_count[nreadcalls] = count;
    nreadcalls++;
    if (flags & DVDCSS_READ_DECRYPT) reads_decrypt++; else reads_raw++;
    last_count = count;
    if (fail_read_from >= 0 && cur_block + count > fail_read_from)
    {
        if (cur_block >= fail_read_from) return -1;
        count = fail_read_from - cur_block;
    }
    for (int i = 0; i < nfix && count == 1; i++)
        if ((int)fix_lba[i] == cur_block) { memcpy(buf, fix_sec[i], 2048); cur_block += count; return count; }
    for (int i = 0; i < count; i++)
    {
        uint8_t *q = (uint8_t *)buf + (size_t)i * 2048;
        if (model_on) model_sector(q, (uint32_t)(cur_block + i), (flags & DVDCSS_READ_DECRYPT) != 0);
        else          memset(q, 0, 2048);
        put_stamp(q, (uint32_t)(cur_block + i), (flags & DVDCSS_READ_DECRYPT) ? 1 : 0);
    }
    cur_block += count;
    return count;
}

// ---- ISO9660 fixture writer --------------------------------------------------
static void put_le32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

// Appends one directory record to a directory that starts at `dir_lba`, moving to
// the next sector when it would not fit (records never cross a sector, and a zero
// length byte ends the sector -- exactly what collect_vobs() walks).
static uint32_t dir_sec, dir_off;
static void dir_begin(uint32_t lba) { dir_sec = lba; dir_off = 0; fix_sector(lba); }
static void dir_add(const char *name, uint32_t extent, uint32_t size, int is_dir)
{
    int nlen = (int)strlen(name);
    int rlen = 33 + nlen + ((nlen & 1) ? 0 : 1);
    if (dir_off + rlen > 2048) { dir_sec++; dir_off = 0; }
    uint8_t *r = fix_sector(dir_sec) + dir_off;
    r[0] = (uint8_t)rlen;
    put_le32(r + 2, extent);
    put_le32(r + 10, size);
    r[25] = is_dir ? 0x02 : 0x00;
    r[32] = (uint8_t)nlen;
    memcpy(r + 33, name, nlen);
    dir_off += rlen;
}
static uint32_t dir_bytes(uint32_t first) { return (dir_sec - first + 1) * 2048; }

#define ROOT_LBA 20u
#define VTS_LBA  21u
static void iso_begin(void)
{
    nfix = 0;
    uint8_t *pvd = fix_sector(16);
    pvd[0] = 1; memcpy(pvd + 1, "CD001", 5);
    put_le32(pvd + 156 + 2, ROOT_LBA);
    put_le32(pvd + 156 + 10, 2048);
    dir_begin(VTS_LBA);
}
static void iso_end(void)
{
    uint32_t vts_len = dir_bytes(VTS_LBA);
    dir_begin(ROOT_LBA);
    dir_add("VIDEO_TS", VTS_LBA, vts_len, 1);
}

static char *fake_error(dvdcss_t) { static char e[] = "stub"; return e; }

// ------------------------------------------------------------------ harness
static int errs = 0;
static void check(const char *what, long got, long want)
{
    if (got != want) { printf("  FAIL %-46s got %ld, want %ld\n", what, got, want); errs++; }
    else             { printf("  ok   %-46s %ld\n", what, got); }
}

// Three VOBs, deliberately NOT starting at 0, so a stray 0 cannot pass by
// coincidence. They ARE contiguous (VOB0 + VOBN == VOB1), like the parts of a real
// title set, which is what [8] and [12] rely on.
#define VOB0 1000u
#define VOB1 501000u
#define VOB2 1001000u
#define VOBN 500000u

static void setup(void)
{
    css = (dvdcss_t)1;
    p_seek = fake_seek; p_read = fake_read; p_error = fake_error;

    g_nvobs = 3;
    g_vobs[0].start = VOB0; g_vobs[0].nsec = VOBN;
    g_vobs[1].start = VOB1; g_vobs[1].nsec = VOBN;
    g_vobs[2].start = VOB2; g_vobs[2].nsec = VOBN;
    for (int i = 0; i < g_nvobs; i++)
    {
        g_vobs[i].key = g_vobs[i].start;     // unnamed extents: keyed at their own start
        g_vobs[i].tt = g_vobs[i].part = -1;
        g_vobs[i].heal_tried = 0;
    }
    model_on = 0; nscr = 0; cur_libkey = 0;
    g_heals = g_heal_ok = g_residual = 0;

    cur_key = -1; css_pos = -1; key_ok = 0; raw_fd = -1;
    nseeks = 0; reads_decrypt = reads_raw = 0; last_count = 0;
    key_acquisitions = 0; fail_key_at = -1;
    fail_read_from = -1; nreadcalls = 0;

    // What crack_title_keys() leaves behind at mount: one key per VOB, at its start.
    nprimed = 0;
    for (int i = 0; i < g_nvobs; i++) { primed_key[nprimed] = 1; primed[nprimed++] = (int)g_vobs[i].start; }
}

static int is_vob_start(int block)
{
    for (int i = 0; i < g_nvobs; i++) if (block == (int)g_vobs[i].start) return 1;
    return 0;
}
static int key_seeks_off_vob_start(void)
{
    int n = 0;
    for (int i = 0; i < nseeks && i < MAXCALLS; i++)
        if ((seeks[i].flags & DVDCSS_SEEK_KEY) && !is_vob_start(seeks[i].block)) n++;
    return n;
}
static int key_seek_count(void)
{
    int n = 0;
    for (int i = 0; i < nseeks && i < MAXCALLS; i++) if (seeks[i].flags & DVDCSS_SEEK_KEY) n++;
    return n;
}

// The reported gesture. Land at a chapter start, read a sector, repeat -- the shape
// of Prev/Next Chapter, which is a cell seek to an authored cell start.
static void skip_to(uint32_t lba)
{
    uint8_t buf[2048];
    dvd_css_read(buf, lba, 1);
}


// ---- issue #122 helpers ------------------------------------------------------
// A mounted disc under the CSS model: nothing primed yet, so enumerate_vobs() +
// crack_title_keys() are the real mount path, cracks and all.
static void model_setup(void)
{
    setup();
    model_on = 1; nscr = 0; cur_libkey = 0;
    nprimed = 0;
    iso_begin();
}
static void model_mount(void)
{
    iso_end();
    enumerate_vobs();
    crack_title_keys("test");
    nseeks = 0; key_acquisitions = 0; reads_decrypt = reads_raw = 0;
}
static void vob(const char *name, uint32_t lba, uint32_t nsec) { dir_add(name, lba, nsec * 2048u, 0); }

// What reached the core. `bad` = still scrambled, `noise` = decrypted with a WRONG
// key (bits clear, no start codes) -- the one outcome worse than CSS ENCRYPTED,
// because nothing mutes it.
static int bad_n, noise_n;
static void score(const uint8_t *b, int n)
{
    for (int i = 0; i < n; i++)
    {
        const uint8_t *q = b + (size_t)i * 2048;
        int sc = (q[0x14] & 0x30) != 0;
        int ok = q[0x102] == 1 && q[0x103] == 0xB3;
        if (sc) bad_n++;
        else if (!ok) noise_n++;
    }
}
static void play(uint32_t lba, int n)
{
    static uint8_t w[8 * 2048];
    if (n > 8) n = 8;
    int r = dvd_css_read(w, lba, (uint32_t)n);
    if (r > 0) score(w, r);
}
static int key_seeks_at(uint32_t b)
{
    int n = 0;
    for (int i = 0; i < nseeks && i < MAXCALLS; i++)
        if ((seeks[i].flags & DVDCSS_SEEK_KEY) && seeks[i].block == (int)b) n++;
    return n;
}

// Physical "Hitch", its real VTS_01 layout. The first 2000 sectors of parts 2..5
// hold NO scrambled sector (measured); part 1 and the menu VOB are scrambled from
// their second sector. One title key throughout (the drive's own answer).
#define H_MENU  158392u
#define H_P1    239944u
#define H_PN    524287u
static const uint32_t h_part[5] = {239944u, 764231u, 1288518u, 1812805u, 2337092u};
static void hitch_layout(int with_menu, int part1_uncrackable)
{
    vob("VIDEO_TS.VOB;1", 158249u, 57u);                    // never scrambled
    if (with_menu) { vob("VTS_01_0.VOB;1", H_MENU, 81552u); add_scr(H_MENU + 1, H_MENU + 81552u, 7, 0); }
    for (int p = 0; p < 5; p++)
    {
        char nm[24];
        snprintf(nm, sizeof nm, "VTS_01_%d.VOB;1", p + 1);
        uint32_t n = p == 4 ? 118005u : H_PN;
        vob(nm, h_part[p], n);
        add_scr(h_part[p] + (p ? 2000u : 1u), h_part[p] + n, 7, p == 0 ? part1_uncrackable : 0);
    }
}
static void poison(uint32_t b) { primed[nprimed] = (int)b; primed_key[nprimed] = 0; nprimed++; }

int main(void)
{
    uint8_t buf[2048];

    // [1] CONTROL: uninterrupted linear playback. It was always fine -- lba tracked
    //     css_pos, so no key was ever asked for after the first. If this regresses,
    //     the fix has made ordinary playback do work it never did.
    printf("[1] linear playback\n");
    setup();
    for (uint32_t i = 0; i < 64; i++) dvd_css_read(buf, VOB0 + i, 1);
    check("title keys acquired during playback", key_acquisitions, 0);
    check("SEEK_KEY calls over 64 linear reads", key_seek_count(), 1);
    check("reads decrypted", reads_decrypt, 64);

    // [2] THE GATE. 17 chapter skips inside one VOB (the shape of the reported
    //     disc: VTS_01 PGCN 1, 17 programs, one cell each). Not one of those
    //     landings is a VOB start, so pre-fix each one cracked a key.
    printf("[2] chapter skips inside one VOB\n");
    setup();
    dvd_css_read(buf, VOB0, 1);                       // start playing
    for (int ch = 1; ch <= 17; ch++) skip_to(VOB0 + 12345u * ch);
    check("title keys acquired over 17 chapter skips", key_acquisitions, 0);
    check("chapters actually read", reads_decrypt, 18);

    // [3] ...stated as the invariant rather than as a count, so a differently
    //     shaped seek pattern cannot slip past: a key is only ever requested at a
    //     block crack_title_keys() primed.
    check("SEEK_KEY calls at a non-VOB-start block", key_seeks_off_vob_start(), 0);

    // [4] CONTROL against the lazy "fix" of never keying at all: crossing into
    //     another VOB MUST re-key, at that VOB's own start, or the sectors come
    //     back scrambled. Three crossings, three key seeks, no acquisitions.
    printf("[4] crossing VOB boundaries\n");
    setup();
    dvd_css_read(buf, VOB0 + 700u, 1);
    dvd_css_read(buf, VOB1 + 900u, 1);
    dvd_css_read(buf, VOB0 + 800u, 1);
    check("SEEK_KEY calls over three VOB crossings", key_seek_count(), 3);
    check("title keys acquired crossing VOBs", key_acquisitions, 0);
    check("SEEK_KEY calls at a non-VOB-start block", key_seeks_off_vob_start(), 0);
    check("reads decrypted across the crossings", reads_decrypt, 3);

    // [5] CONTROL: a seek WITHIN a VOB must not re-key at all. This is the work the
    //     fix removes; if it comes back the acquisitions come back with it on any
    //     disc whose cache is cold.
    printf("[5] a seek within one VOB\n");
    setup();
    dvd_css_read(buf, VOB0, 1);
    int before = key_seek_count();
    dvd_css_read(buf, VOB0 + 400000u, 1);
    check("extra SEEK_KEY calls for a same-VOB seek", key_seek_count() - before, 0);

    // [6] The latch. When no key can be had we fall back to a RAW read rather than
    //     corrupt the sector -- and that verdict has to survive into the following
    //     reads. It used to be a local set only on the failing read, while cur_vob
    //     advanced anyway, so the NEXT sequential read skipped the whole block and
    //     decrypted with a key that had never been obtained.
    printf("[6] the key seek fails\n");
    setup();
    fail_key_at = (int)VOB0;
    for (uint32_t i = 0; i < 3; i++) dvd_css_read(buf, VOB0 + i, 1);
    check("decrypted reads after the key seek failed", reads_decrypt, 0);
    check("raw reads after the key seek failed", reads_raw, 3);

    // [7] CONTROL: a filesystem/IFO sector is outside every VOB. It must never be
    //     decrypted (that would corrupt it) and never costs a key.
    printf("[7] a non-VOB sector\n");
    setup();
    dvd_css_read(buf, 16, 1);                          // the PVD
    check("SEEK_KEY calls for an IFO sector", key_seek_count(), 0);
    check("decrypted reads for an IFO sector", reads_decrypt, 0);
    check("raw reads for an IFO sector", reads_raw, 1);

    // [8] CONTROL: one read may not span two VOBs, because they have different
    //     keys. Unchanged by the fix, and the reason keying per VOB is sound.
    printf("[8] a read spanning the VOB end\n");
    setup();
    static uint8_t big[16 * 2048];
    check("sectors returned for a 16-sector window", dvd_css_read(big, VOB0 + VOBN - 3u, 16), 16);
    check("first libdvdcss read stops at the VOB end", readcall_count[0], 3);
    check("the rest comes from the next VOB, decrypted", reads_decrypt, 2);

    // [9] ISSUE #112, on the disc's real layout. "OZ: The Great and Powerful" lists
    //     91 VOBs: VTS_08..18 each file the SAME 7-part feature extent. The table used
    //     to stop at 64 entries, so everything sorting after VTS_15_5 was never
    //     registered -- including VTS_20, the sneak peeks that play right after the
    //     language menu. vob_index() said "not a VOB", the sectors were read raw, and
    //     the core showed green garbage with CSS ENCRYPTED. LBAs/sizes are the disc's.
    printf("[9] OZ: 91 VOB entries, 21 distinct extents\n");
    setup();
    iso_begin();
    {
        static const struct { const char *n; uint32_t lba, size; } lone[] = {
            {"VIDEO_TS.VOB;1", 523, 1941504},       {"VTS_01_1.VOB;1", 1497, 32768},
            {"VTS_02_1.VOB;1", 1527, 133120},       {"VTS_03_1.VOB;1", 1606, 411648},
            {"VTS_04_0.VOB;1", 1824, 2267136},      {"VTS_04_1.VOB;1", 2931, 6967296},
            {"VTS_05_1.VOB;1", 6350, 10256384},     {"VTS_06_1.VOB;1", 11376, 619196416},
            {"VTS_07_0.VOB;1", 313760, 236089344},  {"VTS_07_1.VOB;1", 429038, 10240},
        };
        static const uint32_t part_lba[7] = {429605, 953892, 1478179, 2002466,
                                              2526753, 3051040, 3575327};
        dir_add("VIDEO_TS.IFO;1", 504, 38912, 0);           // non-VOB: must be skipped
        for (unsigned i = 0; i < sizeof lone / sizeof lone[0]; i++)
            dir_add(lone[i].n, lone[i].lba, lone[i].size, 0);
        for (int vts = 8; vts <= 18; vts++)
            for (int p = 1; p <= 7; p++)
            {
                char nm[24];
                snprintf(nm, sizeof nm, "VTS_%02d_%d.VOB;1", vts, p);
                dir_add(nm, part_lba[p - 1], p == 7 ? 407252992u : 1073739776u, 0);
            }
        dir_add("VTS_19_0.VOB;1", 3774720, 272384, 0);
        dir_add("VTS_19_1.VOB;1", 3774853, 1341440, 0);
        dir_add("VTS_20_1.VOB;1", 3775523, 346552320, 0);   // the sneak peeks
        dir_add("VTS_21_1.VOB;1", 3944751, 32768, 0);
    }
    iso_end();
    check("enumerate_vobs() found VOBs", enumerate_vobs(), 1);
    check(".VOB directory entries seen", g_vob_entries, 91);
    check("distinct extents registered", g_nvobs, 21);
    check("distinct extents dropped", g_vobs_dropped, 0);
    check("VTS_20 sneak peeks resolve to a VOB", vob_index(3775523u + 5000u) >= 0, 1);
    check("VTS_21 (last on the disc) resolves", vob_index(3944751u) >= 0, 1);
    check("feature part 7 resolves", vob_index(3575327u + 100u) >= 0, 1);
    check("IFO sector is still not a VOB", vob_index(504u), -1);
    nseeks = 0;
    crack_title_keys("test");
    // One key block per title set domain (issue #122): the feature's parts 2..7 are
    // keyed at part 1, so 21 extents need 15 key blocks.
    check("SEEK_KEY calls priming the disc", key_seek_count(), 15);

    // [10] The largest disc the spec allows: 99 title sets x (menu + 9 parts), plus
    //      the VMG's VIDEO_TS.VOB = 991 distinct VOBs. Every one must register.
    printf("[10] a spec-maximum disc: 991 distinct VOBs\n");
    setup();
    iso_begin();
    {
        uint32_t lba = 1000;
        dir_add("VIDEO_TS.VOB;1", lba, 2048, 0); lba += 10;
        for (int vts = 1; vts <= 99; vts++)
            for (int p = 0; p <= 9; p++)
            {
                char nm[24];
                snprintf(nm, sizeof nm, "VTS_%02d_%d.VOB;1", vts, p);
                dir_add(nm, lba, 2048, 0); lba += 10;
            }
    }
    iso_end();
    enumerate_vobs();
    check("distinct extents registered", g_nvobs, 991);
    check("distinct extents dropped", g_vobs_dropped, 0);

    // [11] Past anything a conformant disc can hold, the table fills -- and that
    //      must be COUNTED (and logged), never silent, because a dropped VOB plays
    //      scrambled with no other signal.
    printf("[11] more distinct VOBs than the table holds\n");
    setup();
    iso_begin();
    for (int i = 0; i < MAX_VOBS + 6; i++)
    {
        char nm[24];
        snprintf(nm, sizeof nm, "X%04d.VOB;1", i);
        dir_add(nm, 1000u + 10u * i, 2048, 0);
    }
    iso_end();
    enumerate_vobs();
    check("distinct extents registered (full)", g_nvobs, MAX_VOBS);
    check("distinct extents counted as dropped", g_vobs_dropped, 6);

    // [12] THE STALE-SECTOR BUG. Main's readA/readB cache a window as all buf_n
    //      sectors whenever the read returns > 0, so a SHORT return leaves the
    //      window's tail holding the previous window's sectors, served as these.
    //      Every read clamps at a VOB end, and a DVD's VOB parts are contiguous and
    //      524287 sectors long (odd), so an 8-sector window almost always straddles
    //      the VTS_xx_1 -> _2 boundary: up to 7 stale sectors per 1 GB of film.
    printf("[12] an 8-sector window straddling two contiguous VOB parts\n");
    setup();
    {
        static uint8_t win[8 * 2048];
        memset(win, 0xEE, sizeof win);                 // "the previous window"
        uint32_t at = VOB0 + VOBN - 3u;
        check("sectors returned", dvd_css_read(win, at, 8), 8);
        int stale = 0, wrong = 0, clear = 0;
        for (int i = 0; i < 8; i++)
        {
            const uint8_t *q = win + i * 2048;
            if (q[0] == 0xEE && q[1] == 0xEE) stale++;
            else if (get_lba(q) != at + (uint32_t)i) wrong++;
            else if (q[STAMP + 4] != 1) clear++;
        }
        check("stale sectors left in the window", stale, 0);
        check("sectors carrying another LBA", wrong, 0);
        check("VOB sectors NOT decrypted", clear, 0);
        check("key seeks (part 1, then part 2 at its START)", key_seek_count(), 2);
        check("SEEK_KEY calls at a non-VOB-start block", key_seeks_off_vob_start(), 0);
        check("title keys acquired", key_acquisitions, 0);
    }

    // [13] What cannot be read. A failure partway through the window zero-fills the
    //      rest (a hole, never a stale sector); a failure on the FIRST sector is a
    //      failure, so Main retries the window rather than caching a hole at its head.
    printf("[13] unreadable sectors\n");
    setup();
    {
        static uint8_t win[8 * 2048];
        memset(win, 0xEE, sizeof win);
        fail_read_from = (int)(VOB0 + 100u + 5u);
        check("window with an unreadable tail: sectors returned", dvd_css_read(win, VOB0 + 100u, 8), 8);
        check("readable head is intact", get_lba(win + 4 * 2048), VOB0 + 104u);
        int zero = 1;
        for (int i = 5 * 2048; i < 8 * 2048; i++) if (win[i]) zero = 0;
        check("unreadable tail is zero-filled", zero, 1);
        check("window whose first sector is unreadable fails",
              dvd_css_read(win, VOB0 + 105u, 8), -1);
    }

    // [14] libdvdcss's own handle to the drive must not outlive the Main. It opens
    //      with plain O_RDONLY; a core switch re-execs the Main, the handle carried
    //      over, and after a few sessions the kernel refused Eject with EBUSY
    //      (measured: four such handles in the running Main). Stand-in for the
    //      library's open: a plain open() of a file, then the marking.
    printf("[14] the library's handle is made close-on-exec\n");
    {
        char path[] = "/tmp/dvd_css_test_XXXXXX";
        int tfd = mkstemp(path);
        int lib = open(path, O_RDONLY);                 // what libdvdcss does
        check("the library's fd starts inheritable", (fcntl(lib, F_GETFD) & FD_CLOEXEC) != 0, 0);
        check("handles marked", mark_cloexec_to(path), 2);   // mkstemp's too
        check("the library's fd is close-on-exec", (fcntl(lib, F_GETFD) & FD_CLOEXEC) != 0, 1);
        close(lib); close(tfd); unlink(path);
    }


    // [15] ISSUE #122, "Hitch" on a drive with no region set. The feature's parts
    //      2..5 used to be keyed at their OWN starts, where the crack sees 2000 clean
    //      sectors and caches a ZERO key: everything past the first 1 GB reached the
    //      core scrambled. Keyed at part 1, as libdvdread does, nothing needs a heal.
    printf("[15] Hitch: a title set's parts share part 1's key\n");
    model_setup();
    hitch_layout(1, 0);
    nseeks = 0;
    iso_end(); enumerate_vobs(); crack_title_keys("test");
    check("[15] SEEK_KEY calls priming Hitch", key_seek_count(), 3);   // VMG, menu, part 1
    nseeks = 0; key_acquisitions = 0; bad_n = noise_n = 0;
    play(h_part[2] + 300000u, 8);                        // Next Chapter into part 3
    play(h_part[4] + 50000u, 8);                         // ...and part 5
    play(h_part[1] - 3u, 8);                             // linear across part 1 -> 2
    play(h_part[1] + 5u, 8);
    check("[15] sectors reaching the core scrambled", bad_n, 0);
    check("[15] sectors decrypted with a wrong key", noise_n, 0);
    int at_parts = 0;
    for (int p = 1; p < 5; p++) at_parts += key_seeks_at(h_part[p]);
    check("[15] SEEK_KEY calls at a VTS_01_2..5 start", at_parts, 0);
    check("[15] heals needed", g_heals, 0);
    check("[15] title keys cracked by the seeks", key_acquisitions, 0);

    // [16] The same failure one level up: part 1 ITSELF holds a zero key (a crack
    //      that saw 2000 clean sectors there, cached for good). The data says so --
    //      a decrypted sector still carries its scrambling bits -- and the title
    //      set's other key block (the menu VOB's) is tried and PROVEN on the data.
    printf("[16] a poisoned part-1 key is healed from the menu VOB's key\n");
    model_setup();
    hitch_layout(1, 0);
    poison(H_P1);
    model_mount();
    bad_n = noise_n = 0;
    play(h_part[2] + 300000u, 8);
    play(h_part[2] + 300008u, 8);
    play(h_part[0] + 1000u, 8);
    check("[16] sectors reaching the core scrambled", bad_n, 0);
    check("[16] sectors decrypted with a wrong key", noise_n, 0);
    check("[16] heals attempted", g_heals, 1);
    check("[16] heals proven", g_heal_ok, 1);

    // [16b] ...and with no menu VOB to borrow from, a key taken AT the scrambled
    //       sector: the crack then starts inside scrambled data.
    printf("[16b] a poisoned part-1 key with no sibling: a fresh key at the sector\n");
    model_setup();
    hitch_layout(0, 0);
    poison(H_P1);
    model_mount();
    bad_n = noise_n = 0;
    play(h_part[2] + 300000u, 8);
    play(h_part[3] + 1000u, 8);
    check("[16b] sectors reaching the core scrambled", bad_n, 0);
    check("[16b] sectors decrypted with a wrong key", noise_n, 0);
    check("[16b] heals proven", g_heal_ok, 1);

    // [17] Nothing can be proven: no sibling, and the scrambled data resists every
    //      crack. ONE attempt per key domain per session, then reads carry on --
    //      never a crack per read on the thread that feeds the core.
    printf("[17] a heal that cannot succeed is tried once\n");
    model_setup();
    hitch_layout(0, 1);
    for (int i = 0; i < nscr; i++) scr[i].uncrackable = 1;
    poison(H_P1);
    model_mount();
    for (int i = 0; i < 20; i++) play(h_part[2] + 1000u + 5000u * (uint32_t)i, 8);
    check("[17] heal attempts over 20 reads", g_heals, 1);
    check("[17] cracks attempted over 20 reads", key_acquisitions, 1);
    check("[17] sectors counted as reaching the core scrambled", g_residual > 0, 1);

    // [18] "Kung Fu Panda" VTS_14: the title VOB is 169 sectors and cannot be
    //      cracked from any block (measured, 0/11 attacks at every start). Its true
    //      key is the menu VOB's, which cracks at once. The failed crack leaves
    //      key_ok = 0 -- a RAW read -- so the data check must cover that path too.
    printf("[18] Panda: an uncrackable title VOB takes its menu VOB's proven key\n");
    model_setup();
    vob("VTS_14_0.VOB;1", 3187180u, 187u);
    vob("VTS_14_1.VOB;1", 3187367u, 169u);
    add_scr(3187181u, 3187180u + 187u, 9, 0);
    add_scr(3187368u, 3187367u + 169u, 9, 1);
    model_mount();
    bad_n = noise_n = 0;
    for (uint32_t o = 0; o < 168u; o += 8) play(3187367u + o, 8);
    check("[18] sectors reaching the core scrambled", bad_n, 0);
    check("[18] sectors decrypted with a wrong key", noise_n, 0);
    check("[18] heals proven", g_heal_ok, 1);

    // [18b] ...but a sibling key is only a GUESS until the data proves it. A menu VOB
    //       whose key differs must be refused: garbage with the scrambling bits
    //       cleared would play unmuted, which is worse than CSS ENCRYPTED.
    printf("[18b] a sibling key the data does not prove is refused\n");
    model_setup();
    vob("VTS_14_0.VOB;1", 3187180u, 187u);
    vob("VTS_14_1.VOB;1", 3187367u, 169u);
    add_scr(3187181u, 3187180u + 187u, 5, 0);            // a DIFFERENT key
    add_scr(3187368u, 3187367u + 169u, 9, 1);
    model_mount();
    bad_n = noise_n = 0;
    for (uint32_t o = 0; o < 168u; o += 8) play(3187367u + o, 8);
    check("[18b] sectors decrypted with a wrong key", noise_n, 0);
    check("[18b] heals proven", g_heal_ok, 0);

    // [19] A part with no part 1 to key from keeps its own start (the old
    //      behaviour) and is counted, never silent.
    printf("[19] VTS_03_2 with no VTS_03_1\n");
    model_setup();
    vob("VTS_03_0.VOB;1", 5000u, 100u);
    vob("VTS_03_2.VOB;1", 6000u, 100u);
    iso_end(); enumerate_vobs();
    check("[19] orphan parts counted", g_orphan_parts, 1);
    check("[19] the orphan keys at its own start", (long)g_vobs[vob_index(6000u)].key, 6000);

    printf("\ndvd_css_test: %s (%d error%s)\n", errs ? "FAIL" : "PASS", errs, errs == 1 ? "" : "s");
    return errs ? 1 : 0;
}
