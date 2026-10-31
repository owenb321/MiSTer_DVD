// dvd_vmsnap.cpp -- see dvd_vmsnap.h. The protocol is dvd/vm_snap.sv's header comment.

#include <stdint.h>

#include "../../spi.h"
#include "dvd_vmsnap.h"

// One transaction: the command, then the control word (bit 0 = take a snapshot when
// this transaction ends). The core never writes the buffer while a transaction is
// open, so asking and reading are always separate transactions.
int dvd_vmsnap_ask(uint16_t *seq)
{
	uint16_t m = spi_uio_cmd_cont(UIO_DVD_VMSNAP);
	uint16_t cur = spi_w(1);
	DisableIO();
	if (m != DVD_VMSNAP_MAGIC) return 0;
	*seq = cur;
	return 1;
}

// The header; once the snapshot is complete (seq moved, not busy), its words follow in
// the same transaction. Otherwise only the header words are clocked.
int dvd_vmsnap_fetch(uint16_t seq0, uint16_t *h, uint16_t *w)
{
	h[0] = spi_uio_cmd_cont(UIO_DVD_VMSNAP);
	for (int i = 1; i < DVD_VMSNAP_HDR; i++) h[i] = spi_w(0);
	int busy = h[2] >> 15;
	unsigned len = VMSNAP_LEN(h[2]);
	int ready = h[0] == DVD_VMSNAP_MAGIC && !busy && h[1] != seq0 && len;
	if (len > DVD_VMSNAP_MAXW) len = DVD_VMSNAP_MAXW;      // never past our buffer
	if (ready) for (unsigned i = 0; i < len; i++) w[i] = spi_w(0);
	DisableIO();
	if (h[0] != DVD_VMSNAP_MAGIC) return -1;
	return ready ? (int)len : 0;
}

int dvd_vmsnap_peek(uint16_t *w2)
{
	uint16_t m = spi_uio_cmd_cont(UIO_DVD_VMSNAP);
	spi_w(0);
	uint16_t v = spi_w(0);
	DisableIO();
	if (m != DVD_VMSNAP_MAGIC) return 0;
	*w2 = v;
	return 1;
}

// THE DISPLAYED PICTURE'S TIME (docs/nav_engine.md §10). The core's clock (eltm, BCD
// dvd_time) is the PGC time of the VOBU the demux just parsed, which leads the picture
// by the decoder's buffer -- seconds in a low-bitrate cell. sptm is that VOBU's start
// PTS and stc the displayed picture's, so the lead is sptm - stc. -> whole PGC seconds of
// the picture on screen, or -1 when it cannot be trusted: no NAV pack since the last
// flush, a VOBU with no picture (a still with an audio loop: land at the cell start,
// docs/save_states.md §5g), or a lead outside -1.5..30 s (a PTS discontinuity between the
// demux and the screen). The lead may be slightly NEGATIVE: with the decoder's buffer
// near empty (just after a seek) the picture on screen is a few frames into the front
// VOBU itself -- measured -26 ms on the rig (docs/nav_engine.md §10) -- and the
// formula adds it. Rounded to the NEAREST second: the time map lands on either side of
// its target (measured -0.36..+0.30 s), so rounding down only biased every landing early
// (three rig trials -0.49 s on average; docs/nav_engine.md §10).
int dvd_vmsnap_disp_secs(uint32_t eltm, uint32_t sptm, uint32_t stc, int fresh, int video)
{
	if (!fresh || !video || !sptm) return -1;
	int32_t lead = (int32_t)(sptm - stc);
	if (lead < -135000 || lead > 30 * 90000) return -1;
	unsigned b0 = eltm >> 24, b1 = (eltm >> 16) & 0xFF, b2 = (eltm >> 8) & 0xFF, b3 = eltm & 0xFF;
	unsigned hh = (b0 >> 4) * 10 + (b0 & 15);
	unsigned mm = (b1 >> 4) * 10 + (b1 & 15);
	unsigned ss = (b2 >> 4) * 10 + (b2 & 15);
	unsigned ff = ((b3 >> 4) & 3) * 10 + (b3 & 15);
	unsigned fps = ((b3 >> 6) == 1) ? 25 : 30;            // dvd_time rate bits (11 = 30)
	if (mm > 59 || ss > 59 || ff >= fps) return -1;
	int64_t ticks = (int64_t)((hh * 60 + mm) * 60 + ss) * 90000 + (int64_t)ff * 90000 / fps - lead;
	return ticks < 0 ? 0 : (int)((ticks + 45000) / 90000);
}

int dvd_vmsnap_disp_secs_h(const uint16_t *h)
{
	return dvd_vmsnap_disp_secs(((uint32_t)h[13] << 16) | h[14], ((uint32_t)h[15] << 16) | h[16],
	                            ((uint32_t)h[17] << 16) | h[18], (h[4] >> 1) & 1, h[4] & 1);
}

// A LOAD, in one transaction: control word 2, fmt, len, the checksum (the 16-bit sum of
// everything from the landing time on), the landing time, the RBN, the words. The core
// checks it as the transaction ends and applies it only if every check passes.
int dvd_vmload_send(uint16_t fmt, const uint16_t *w, int n, uint16_t tm, uint32_t rbn)
{
	uint16_t sum = (uint16_t)(tm + (rbn >> 16) + (rbn & 0xFFFF));
	for (int i = 0; i < n; i++) sum += w[i];
	uint16_t m = spi_uio_cmd_cont(UIO_DVD_VMSNAP);
	if (m != DVD_VMSNAP_MAGIC)
	{
		DisableIO();
		return 0;
	}
	spi_w(2);                                   // control: LOAD
	spi_w(fmt);
	spi_w((uint16_t)n);
	spi_w(sum);
	spi_w(tm);
	spi_w((uint16_t)(rbn >> 16));
	spi_w((uint16_t)rbn);
	for (int i = 0; i < n; i++) spi_w(w[i]);
	DisableIO();                                // the core checks it as this ends
	return 1;
}

int dvd_vmload_verdict(void)
{
	uint16_t h[5];
	h[0] = spi_uio_cmd_cont(UIO_DVD_VMSNAP);
	for (int i = 1; i < 5; i++) h[i] = spi_w(0);
	DisableIO();
	if (h[0] != DVD_VMSNAP_MAGIC) return -1;
	return (h[4] >> 13) & 7;
}
