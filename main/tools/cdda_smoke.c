/* cdda_smoke.c -- does this drive actually serve CD-DA audio over SG_IO?
 *
 * The one real unknown in physical audio-CD support. DVD_AUTH and READ(10) are
 * proven on this board (dvd_css.cpp uses both), but a DVD data read and a CD
 * AUDIO read are different commands down different firmware paths, and READ(10)
 * cannot read an audio track at all. So this answers, before any feature code
 * exists:
 *
 *   1. can we read the TOC, and does it look like an audio CD?
 *   2. does READ CD (0xBE) with the CD-DA flags return data?
 *   3. is that data plausible PCM rather than zeros or garbage?
 *   4. does the CDROMREADRAW fallback work if 0xBE does not?
 *
 * It writes a .wav of the first track so the answer can also be checked by ear,
 * which is the only way to catch "returns data, but it is the wrong data".
 *
 * Deliberately standalone: no MiSTer headers, no overlay dependencies. Build for
 * the board with the same cross-compiler the Main uses, or natively on a PC with
 * a drive to try it against.
 *
 *   arm-linux-gnueabihf-gcc -O2 -o cdda_smoke cdda_smoke.c
 *   ./cdda_smoke /dev/sr0 [seconds]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <scsi/sg.h>
#include <math.h>
#include <linux/cdrom.h>
#include <limits.h>   /* INT_MAX -- CDSL_CURRENT expands to it via <linux/cdrom.h> */

#define RAW_SECTOR 2352            /* one CD-DA sector: 588 stereo s16 frames */
#define SECTORS_PER_SEC 75
#define MAX_TRACKS 100

struct track { int num, start, end, is_audio; };

/* READ CD (0xBE). flags 0x10 = user data only -> exactly 2352 B/sector of raw
 * PCM; cdb[1]=0x04 declares "expected sector type = CD-DA", which is what makes
 * a drive willing to hand over an audio track at all. */
static int read_cd(int fd, int lba, int count, unsigned char *dst, int timeout_ms,
                   char *why, int whysz)
{
    unsigned char cdb[12] = { 0 }, sense[32] = { 0 };
    struct sg_io_hdr io;

    cdb[0] = 0xBE;
    cdb[1] = 0x04;
    cdb[2] = (lba >> 24) & 0xFF; cdb[3] = (lba >> 16) & 0xFF;
    cdb[4] = (lba >> 8)  & 0xFF; cdb[5] = lba & 0xFF;
    cdb[6] = (count >> 16) & 0xFF; cdb[7] = (count >> 8) & 0xFF;
    cdb[8] = count & 0xFF;
    cdb[9] = 0x10;
    cdb[10] = 0x00;

    memset(&io, 0, sizeof(io));
    io.interface_id = 'S';
    io.cmd_len = sizeof(cdb);
    io.cmdp = cdb;
    io.dxfer_direction = SG_DXFER_FROM_DEV;
    io.dxfer_len = count * RAW_SECTOR;
    io.dxferp = dst;
    io.sbp = sense;
    io.mx_sb_len = sizeof(sense);
    io.timeout = timeout_ms;

    if (ioctl(fd, SG_IO, &io) < 0) {
        snprintf(why, whysz, "SG_IO ioctl failed: %s", strerror(errno));
        return -1;
    }
    if (io.status || io.host_status || io.driver_status) {
        /* Sense key / ASC / ASCQ is the difference between "this drive cannot"
         * and "this disc is not ready yet", and guessing between them wastes a
         * hardware round. */
        snprintf(why, whysz,
                 "SCSI status=0x%02x host=0x%02x driver=0x%02x "
                 "sense key=0x%02x asc=0x%02x ascq=0x%02x",
                 io.status, io.host_status, io.driver_status,
                 sense[2] & 0x0F, sense[12], sense[13]);
        return -2;
    }
    return 0;
}

/* The MSF fallback the stock physical_disc code uses per sector when a burst
 * fails. Worth trying separately: a drive that refuses 0xBE may still serve
 * this, which would change the design rather than kill it. */
static int read_raw_msf(int fd, int lba, unsigned char *dst)
{
    union { struct cdrom_msf msf; unsigned char raw[RAW_SECTOR]; } req;
    int f = lba + 150;
    memset(&req, 0, sizeof(req));
    req.msf.cdmsf_min0   = f / (SECTORS_PER_SEC * 60);
    req.msf.cdmsf_sec0   = (f / SECTORS_PER_SEC) % 60;
    req.msf.cdmsf_frame0 = f % SECTORS_PER_SEC;
    if (ioctl(fd, CDROMREADRAW, &req) < 0) return -1;
    memcpy(dst, req.raw, RAW_SECTOR);
    return 0;
}

static void put_le32(unsigned char *p, unsigned v)
{ p[0]=v&0xFF; p[1]=(v>>8)&0xFF; p[2]=(v>>16)&0xFF; p[3]=(v>>24)&0xFF; }
static void put_le16(unsigned char *p, unsigned v)
{ p[0]=v&0xFF; p[1]=(v>>8)&0xFF; }

/* The very header the Main will synthesise, so this doubles as a check that a
 * 44-byte canonical header in front of raw sectors really is a playable file. */
static void wav_header(unsigned char *h, unsigned payload)
{
    memcpy(h, "RIFF", 4);      put_le32(h+4, 36 + payload);
    memcpy(h+8, "WAVEfmt ", 8); put_le32(h+16, 16);
    put_le16(h+20, 1); put_le16(h+22, 2);
    put_le32(h+24, 44100); put_le32(h+28, 44100*4);
    put_le16(h+32, 4); put_le16(h+34, 16);
    memcpy(h+36, "data", 4);   put_le32(h+40, payload);
}

int main(int argc, char **argv)
{
    const char *dev = argc > 1 ? argv[1] : "/dev/sr0";
    int secs = argc > 2 ? atoi(argv[2]) : 10;
    struct cdrom_tochdr hdr;
    struct track tr[MAX_TRACKS];
    int ntr = 0, naudio = 0, i, rc, fd;
    char why[160] = { 0 };

    printf("== cdda_smoke: %s ==\n", dev);

    fd = open(dev, O_RDONLY | O_NONBLOCK);
    if (fd < 0) { printf("FAIL: open: %s\n", strerror(errno)); return 1; }

    if (ioctl(fd, CDROM_DRIVE_STATUS, CDSL_CURRENT) != CDS_DISC_OK)
        printf("  note: drive does not report CDS_DISC_OK (continuing anyway)\n");

    /* ---- 1. TOC ---- */
    if (ioctl(fd, CDROMREADTOCHDR, &hdr) < 0) {
        printf("FAIL: CDROMREADTOCHDR: %s\n", strerror(errno));
        close(fd); return 1;
    }
    printf("  TOC: tracks %d..%d\n", hdr.cdth_trk0, hdr.cdth_trk1);

    for (i = hdr.cdth_trk0; i <= hdr.cdth_trk1 && ntr < MAX_TRACKS-1; i++) {
        struct cdrom_tocentry e;
        memset(&e, 0, sizeof(e));
        e.cdte_track = i;
        e.cdte_format = CDROM_LBA;
        if (ioctl(fd, CDROMREADTOCENTRY, &e) < 0) {
            printf("FAIL: CDROMREADTOCENTRY(%d): %s\n", i, strerror(errno));
            close(fd); return 1;
        }
        tr[ntr].num = i;
        tr[ntr].start = e.cdte_addr.lba;
        tr[ntr].is_audio = !(e.cdte_ctrl & CDROM_DATA_TRACK);
        if (ntr > 0) tr[ntr-1].end = tr[ntr].start;
        if (tr[ntr].is_audio) naudio++;
        ntr++;
    }
    {
        struct cdrom_tocentry lead;
        memset(&lead, 0, sizeof(lead));
        lead.cdte_track = CDROM_LEADOUT;
        lead.cdte_format = CDROM_LBA;
        if (ioctl(fd, CDROMREADTOCENTRY, &lead) < 0) {
            printf("FAIL: CDROMREADTOCENTRY(LEADOUT): %s\n", strerror(errno));
            close(fd); return 1;
        }
        if (ntr) tr[ntr-1].end = lead.cdte_addr.lba;
    }

    for (i = 0; i < ntr; i++) {
        int len = tr[i].end - tr[i].start;
        printf("   track %2d  %-5s  lba %7d..%-7d  %3d:%02d\n",
               tr[i].num, tr[i].is_audio ? "AUDIO" : "data",
               tr[i].start, tr[i].end,
               len / (SECTORS_PER_SEC*60), (len / SECTORS_PER_SEC) % 60);
    }
    printf("  %d track(s), %d audio\n", ntr, naudio);
    if (!naudio) {
        printf("FAIL: no audio tracks -- put a music CD in the drive\n");
        close(fd); return 1;
    }

    /* ---- 2/3. READ CD, and is it plausible PCM? ---- */
    {
        int first = -1;
        for (i = 0; i < ntr; i++) if (tr[i].is_audio) { first = i; break; }

        int want = secs * SECTORS_PER_SEC;
        int avail = tr[first].end - tr[first].start;
        if (want > avail) want = avail;

        unsigned char *buf = malloc((size_t)want * RAW_SECTOR);
        if (!buf) { printf("FAIL: malloc\n"); close(fd); return 1; }

        /* Bursts of 8 sectors: what dvd_cdda_read will do to fill a 16 KB
         * window (8 * 2048), so this measures the real access pattern. */
        int got = 0, use_msf = 0;
        while (got < want) {
            int n = want - got; if (n > 8) n = 8;
            rc = read_cd(fd, tr[first].start + got, n, buf + (size_t)got*RAW_SECTOR,
                         3000, why, sizeof(why));
            if (rc) {
                if (got == 0) {
                    printf("  READ CD (0xBE) FAILED: %s\n", why);
                    printf("  trying the CDROMREADRAW (MSF) fallback...\n");
                    if (read_raw_msf(fd, tr[first].start, buf) == 0) {
                        printf("  ...fallback WORKS. 0xBE is unavailable on this\n"
                               "  drive; the feature must use CDROMREADRAW per sector.\n");
                        use_msf = 1; got = 1;
                        while (got < want) {
                            if (read_raw_msf(fd, tr[first].start+got,
                                             buf + (size_t)got*RAW_SECTOR)) break;
                            got++;
                        }
                        break;
                    }
                    printf("FAIL: neither 0xBE nor CDROMREADRAW can read audio.\n");
                    free(buf); close(fd); return 1;
                }
                printf("  note: burst failed at sector %d (%s) -- stopping short\n", got, why);
                break;
            }
            got += n;
        }
        printf("  read %d sectors (%.1f s) via %s\n",
               got, (double)got / SECTORS_PER_SEC, use_msf ? "CDROMREADRAW" : "READ CD 0xBE");
        if (got <= 0) { printf("FAIL: no audio data\n"); free(buf); close(fd); return 1; }

        /* Plausibility. A silent lead-in is normal, so the test is over the whole
         * read: real music is neither all-zero nor rail-to-rail everywhere. */
        {
            long nz = 0, clip = 0, n16 = (long)got * RAW_SECTOR / 2;
            long j; double sum = 0;
            short *s = (short *)buf;
            for (j = 0; j < n16; j++) {
                if (s[j]) nz++;
                if (s[j] > 32000 || s[j] < -32000) clip++;
                sum += (double)s[j] * s[j];
            }
            double rms = n16 ? 20.0 * log10((sqrt(sum / n16) + 1e-9) / 32768.0) : -999.0;
            printf("  nonzero %.1f%%, near-full-scale %.2f%%, RMS %.1f dBFS\n",
                   100.0 * nz / n16, 100.0 * clip / n16, rms);
            if (nz == 0)
                printf("  WARN: every sample is zero -- silent lead-in, or the drive\n"
                       "        returned a zero-filled buffer without erroring.\n");
            else if (clip * 100 > n16 * 50)
                printf("  WARN: mostly full-scale -- looks like garbage, not audio.\n");
            else
                printf("  -> plausible PCM.\n");
        }

        /* ---- 4. a file to check by ear ---- */
        {
            const char *out = "/media/fat/cdda_smoke.wav";
            FILE *f = fopen(out, "wb");
            if (!f) { out = "cdda_smoke.wav"; f = fopen(out, "wb"); }
            if (f) {
                unsigned char h[44];
                unsigned payload = (unsigned)got * RAW_SECTOR;
                wav_header(h, payload);
                fwrite(h, 1, sizeof(h), f);
                fwrite(buf, 1, payload, f);
                fclose(f);
                printf("  wrote %s (%u bytes) -- play it to confirm it is the disc\n",
                       out, payload + 44);
            }
        }
        free(buf);
    }

    close(fd);
    printf("PASS: this drive can serve CD-DA.\n");
    return 0;
}
