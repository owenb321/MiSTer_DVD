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

#include "dvd_css.cpp"

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

static int fake_seek(dvdcss_t, int block, int flags)
{
    if (nseeks < MAXCALLS) { seeks[nseeks].block = block; seeks[nseeks].flags = flags; }
    nseeks++;

    if (flags & DVDCSS_SEEK_KEY)
    {
        if (block == fail_key_at) return -1;
        int hit = 0;
        for (int i = 0; i < nprimed; i++) if (primed[i] == block) hit = 1;
        if (!hit)
        {
            key_acquisitions++;                               // seconds to minutes
            if (nprimed < MAXCALLS) primed[nprimed++] = block; // ...then cached
        }
    }
    return block;
}

static int fake_read(dvdcss_t, void *, int count, int flags)
{
    if (flags & DVDCSS_READ_DECRYPT) reads_decrypt++; else reads_raw++;
    last_count = count;
    return count;
}

static char *fake_error(dvdcss_t) { static char e[] = "stub"; return e; }

// ------------------------------------------------------------------ harness
static int errs = 0;
static void check(const char *what, long got, long want)
{
    if (got != want) { printf("  FAIL %-46s got %ld, want %ld\n", what, got, want); errs++; }
    else             { printf("  ok   %-46s %ld\n", what, got); }
}

// Three VOBs, deliberately NOT starting at 0 and NOT adjacent to each other, so a
// stray 0 or an off-by-one VOB index cannot pass by coincidence.
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

    cur_vob = -1; css_pos = -1; key_ok = 0; raw_fd = -1;
    nseeks = 0; reads_decrypt = reads_raw = 0; last_count = 0;
    key_acquisitions = 0; fail_key_at = -1;

    // What crack_title_keys() leaves behind at mount: one key per VOB, at its start.
    nprimed = 0;
    for (int i = 0; i < g_nvobs; i++) primed[nprimed++] = (int)g_vobs[i].start;
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
    dvd_css_read(buf, VOB0 + VOBN - 3u, 16);
    check("sectors requested of libdvdcss", last_count, 3);

    printf("\ndvd_css_test: %s (%d error%s)\n", errs ? "FAIL" : "PASS", errs, errs == 1 ? "" : "s");
    return errs ? 1 : 0;
}
