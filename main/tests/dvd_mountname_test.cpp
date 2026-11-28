// dvd_mountname_test.cpp — the OSD load row's name for what is mounted (dvd_mountname.h).
//
// Field report (maintainer, 2026-11-25): with a disc in the drive, the "Load Video"
// row showed the arrow and no text. Stock Main reads sd_image[n].name, which only
// FileOpen() writes, and the drive, an .iso and a .cue never go through it.
//
//   [1] the volume label out of a PVD: trimmed, printable, generic ones refused
//   [2] the drive's mount: named from dvd_phys, marked as the drive, glyph installed
//   [3] an .iso / .cue mount: named by its path (stock shows the part after '/')
//   [4] a plain file, a failed mount and an unmount: the name is left alone (FileOpen
//       wrote it, or the size is 0) and the drive mark is CLEARED
//
// Build with main/tests/run_tests.sh.

#include <stdio.h>
#include <string.h>
#include <stdint.h>

unsigned char charfont[256][8];   // Main's OSD font (charrom.cpp); staged header is empty

#include "dvd_mountname.cpp"

static int errs = 0;
static void check(const char *what, long got, long want)
{
    if (got != want) { printf("  FAIL %-52s got %ld, want %ld\n", what, got, want); errs++; }
    else             { printf("  ok   %-52s %ld\n", what, got); }
}
static void check_str(const char *what, const char *got, const char *want)
{
    if (strcmp(got, want)) { printf("  FAIL %-52s got \"%s\", want \"%s\"\n", what, got, want); errs++; }
    else                   { printf("  ok   %-52s \"%s\"\n", what, got); }
}

static void make_pvd(uint8_t *s, const char *label)
{
    memset(s, 0, 2048);
    s[0] = 1; memcpy(s + 1, "CD001", 5); s[6] = 1;
    memset(s + 40, ' ', 32);
    memcpy(s + 40, label, strlen(label) > 32 ? 32 : strlen(label));
}

int main(void)
{
    uint8_t pvd[2048];
    char out[64];

    printf("=== [1] the volume label ===\n");
    make_pvd(pvd, "STAR_WARS_TFA");
    check("[1] a real label is usable", dvd_mountname_from_pvd(pvd, out, sizeof(out)), 1);
    check_str("[1] ...trailing padding trimmed", out, "STAR_WARS_TFA");
    make_pvd(pvd, "SUPERMAN_LAST_SON_OF_KRYPTON_XYZ");   // all 32 bytes used
    dvd_mountname_from_pvd(pvd, out, sizeof(out));
    check_str("[1] a full 32-character label kept whole", out, "SUPERMAN_LAST_SON_OF_KRYPTON_XYZ");
    make_pvd(pvd, "AC/DC LIVE");
    dvd_mountname_from_pvd(pvd, out, sizeof(out));
    check_str("[1] '/' replaced (Main shows the text after it)", out, "AC_DC LIVE");
    const char *generic[] = { "CDROM", "DVDVOLUME", "DVD_VIDEO", "dvdvideo", "", "    " };
    for (unsigned i = 0; i < sizeof(generic) / sizeof(generic[0]); i++)
    {
        make_pvd(pvd, generic[i]);
        char what[80]; snprintf(what, sizeof(what), "[1] \"%s\" is refused", generic[i]);
        check(what, dvd_mountname_from_pvd(pvd, out, sizeof(out)), 0);
    }
    make_pvd(pvd, "BAD\x01LABEL");
    check("[1] a control character is refused", dvd_mountname_from_pvd(pvd, out, sizeof(out)), 0);
    make_pvd(pvd, "NO_PVD"); pvd[1] = 'X';
    check("[1] a sector that is not a PVD is refused", dvd_mountname_from_pvd(pvd, out, sizeof(out)), 0);
    make_pvd(pvd, "TRUNCATED_LABEL");
    char tiny[6];
    dvd_mountname_from_pvd(pvd, tiny, sizeof(tiny));
    check_str("[1] bounded by the output size", tiny, "TRUNC");

    printf("=== [2] the drive ===\n");
    char name[261];
    strcpy(name, "STALE.VOB");                 // what a previous plain-file mount left
    memset(charfont[DVD_MOUNTNAME_GLYPH], 0, 8);
    dvd_mountname_note(0, DVD_PHYS_SENTINEL, 1, 1, name, sizeof(name), "STAR_WARS_TFA");
    check_str("[2] DVD: the slot is named by dvd_phys", name, "STAR_WARS_TFA");
    check("[2] DVD: the drive owns slot 0", dvd_mountname_is_drive(0), 1);
    check("[2] the disc glyph is installed", !memcmp(charfont[DVD_MOUNTNAME_GLYPH], disc_glyph, 8), 1);
    check("[2] ...and it is not blank", charfont[DVD_MOUNTNAME_GLYPH][3] != 0, 1);
    dvd_mountname_note(0, DVD_PHYS_VCD_SENTINEL, 1, 1, name, sizeof(name), "Video CD in drive");
    check_str("[2] VCD: named too", name, "Video CD in drive");
    check("[2] VCD: the drive owns slot 0", dvd_mountname_is_drive(0), 1);

    printf("=== [3] an .iso / .cue ===\n");
    dvd_mountname_note(0, "games/DVD/Star Wars TFA.iso", 1, 1, name, sizeof(name), "STAR_WARS_TFA");
    check_str("[3] .iso: the path (the row shows its basename)", name, "games/DVD/Star Wars TFA.iso");
    check("[3] .iso: not the drive", dvd_mountname_is_drive(0), 0);
    dvd_mountname_note(0, "cd/album.cue", 1, 1, name, sizeof(name), "STAR_WARS_TFA");
    check_str("[3] .cue: the path", name, "cd/album.cue");

    printf("=== [4] a plain file, a failure, an unmount ===\n");
    dvd_mountname_note(0, DVD_PHYS_SENTINEL, 1, 1, name, sizeof(name), "STAR_WARS_TFA");
    strcpy(name, "film.VOB");                  // FileOpen() wrote it
    dvd_mountname_note(0, "dvd/film.VOB", 1, 0, name, sizeof(name), "STAR_WARS_TFA");
    check_str("[4] plain file: FileOpen's name left alone", name, "film.VOB");
    check("[4] plain file: the drive mark is cleared", dvd_mountname_is_drive(0), 0);
    dvd_mountname_note(0, DVD_PHYS_SENTINEL, 1, 1, name, sizeof(name), "STAR_WARS_TFA");
    dvd_mountname_note(0, DVD_PHYS_SENTINEL, 0, 0, name, sizeof(name), "STAR_WARS_TFA");
    check("[4] a failed drive mount is not the drive", dvd_mountname_is_drive(0), 0);
    dvd_mountname_note(0, DVD_PHYS_SENTINEL, 1, 1, name, sizeof(name), "STAR_WARS_TFA");
    dvd_mountname_note(0, "", 0, 0, name, sizeof(name), "STAR_WARS_TFA");
    check("[4] an unmount clears the drive mark", dvd_mountname_is_drive(0), 0);
    dvd_mountname_note(1, DVD_PHYS_SENTINEL, 1, 1, name, sizeof(name), "X");
    check("[4] slots are separate (slot 1 marked)", dvd_mountname_is_drive(1), 1);
    check("[4] ...slot 0 untouched", dvd_mountname_is_drive(0), 0);
    dvd_mountname_note(1, "", 0, 0, name, sizeof(name), "X");
    check("[4] out-of-range slot is never the drive", dvd_mountname_is_drive(99), 0);

    printf("\n=== dvd_mountname tests: %d error(s) ===\n", errs);
    if (errs) { printf("FAILED\n"); return 1; }
    printf("PASS\n");
    return 0;
}
