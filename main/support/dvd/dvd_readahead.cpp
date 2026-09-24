// dvd_readahead.cpp — see dvd_readahead.h for why this exists.
//
// Shape. One ring of RA_CAP sectors, addressed by LBA (slot = lba % RA_CAP), holding
// the contiguous run [base, base + fill). The worker appends at base + fill; the
// consumer's progress moves `base` up to RA_BEHIND sectors behind the last sector it
// was served, which is what frees room for the worker. A retarget (a request that
// is neither in the ring nor on its way) empties the ring at the new LBA and bumps
// `gen`, so a burst read for the old position that completes afterwards is dropped
// rather than stored under the wrong address.
//
// Locking. One mutex over base/fill/gen/stop and the ring bytes. The worker holds it
// only to decide what to read and to copy a finished burst in; the source read itself
// -- the only thing that can take seconds -- runs unlocked, into a private buffer. The
// poll thread holds it only for a memcpy. So the lock-contention objection recorded
// in dvd_cdda.cpp (from before this module) does not apply: nothing slow is ever done
// under it.
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <time.h>

#include "dvd_readahead.h"

#ifndef RA_CAP
#define RA_CAP      16384u   // sectors: 32 MB, ~25 s at the 10.08 Mbps DVD maximum
#endif
#define RA_BURST       32u   // sectors per source read in steady state (64 KB)
#define RA_FIRST        8u   // first read after a retarget: one Main window, so a
                             // seek costs what it cost before this module
#define RA_BEHIND     256u   // kept behind the consumer for the reader's re-requests
#define RA_SLACK      256u   // a request this far past the fill is "on its way"
#define RA_RETRIES      3    // single-sector attempts before a sector is zero-filled
#define RA_WAIT_LOG_MS 100   // log a core wait on an EMPTY ring longer than this
#define RA_LOG_MAX    200
#define RA_LOG_PATH "/tmp/dvdcss.log"

static pthread_mutex_t mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  cv = PTHREAD_COND_INITIALIZER;
static pthread_t       th;
static int             running;      // poll thread only
static int             stop_req;     // under mx
static dvd_ra_source   src;
static uint32_t        total;
static uint8_t        *ring;         // RA_CAP * 2048
static uint8_t        *tmp;          // RA_BURST * 2048, worker only
static uint32_t        base, fill, gen;

// A wait at the head of the ring (not a seek) is the thing this module exists to
// prevent, so its duration is logged: no such lines during a hitch report means the
// stall was absorbed; lines mean the ring ran dry and say for how long.
static int             waiting, wait_seek;
static uint32_t        wait_lba;
static struct timespec wait_t0;
static int             log_n;

static void ra_log(const char *fmt, ...)
{
	if (log_n >= RA_LOG_MAX) return;
	log_n++;
	char buf[256];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	printf("DVD_RA: %s\n", buf);
	FILE *f = fopen(RA_LOG_PATH, "a");
	if (f) { fprintf(f, "readahead: %s\n", buf); fclose(f); }
}

static long ra_ms_since(const struct timespec *t0)
{
	struct timespec t1;
	clock_gettime(CLOCK_MONOTONIC, &t1);
	return (t1.tv_sec - t0->tv_sec) * 1000L + (t1.tv_nsec - t0->tv_nsec) / 1000000L;
}

static void copy_in(uint32_t lba, const uint8_t *p, uint32_t n)
{
	for (uint32_t i = 0; i < n; i++)
		memcpy(ring + (size_t)((lba + i) % RA_CAP) * 2048, p + (size_t)i * 2048, 2048);
}

static void copy_out(uint8_t *p, uint32_t lba, uint32_t n)
{
	for (uint32_t i = 0; i < n; i++)
		memcpy(p + (size_t)i * 2048, ring + (size_t)((lba + i) % RA_CAP) * 2048, 2048);
}

// Under mx. The consumer has been served up to `end`; keep RA_BEHIND behind it.
static void advance(uint32_t end)
{
	uint32_t nb = end > RA_BEHIND ? end - RA_BEHIND : 0;
	if (nb > base)
	{
		uint32_t d = nb - base;
		if (d > fill) d = fill;
		base += d;
		fill -= d;
		pthread_cond_broadcast(&cv);
	}
}

// Under mx. Start over at `lba`.
static void retarget(uint32_t lba)
{
	gen++;
	base = lba;
	fill = 0;
	pthread_cond_broadcast(&cv);
}

// Under mx. Is [lba, end) in the ring? If not, is it on its way, or is this a seek?
static int classify_hit(uint32_t lba, uint32_t end)
{
	if (lba >= base && end <= base + fill) return 1;
	if (lba < base || lba > base + fill + RA_SLACK)
	{
		retarget(lba);
		if (!waiting) { waiting = 1; wait_seek = 1; wait_lba = lba; clock_gettime(CLOCK_MONOTONIC, &wait_t0); }
	}
	else if (!waiting) { waiting = 1; wait_seek = 0; wait_lba = lba; clock_gettime(CLOCK_MONOTONIC, &wait_t0); }
	return 0;
}

// Under mx, on a hit: close out a wait that was in progress.
static void wait_done(void)
{
	if (!waiting) return;
	waiting = 0;
	long ms = ra_ms_since(&wait_t0);
	if (!wait_seek && ms >= RA_WAIT_LOG_MS)
		ra_log("ring ran dry: the core waited %ld ms at LBA %u", ms, wait_lba);
}

static int stopping_or_moved(uint32_t g)
{
	pthread_mutex_lock(&mx);
	int r = stop_req || g != gen;
	pthread_mutex_unlock(&mx);
	return r;
}

static void *worker(void *)
{
	pthread_mutex_lock(&mx);
	while (!stop_req)
	{
		uint32_t head = base + fill;
		if (head >= total || fill >= RA_CAP) { pthread_cond_wait(&cv, &mx); continue; }

		uint32_t n = fill ? RA_BURST : RA_FIRST;
		if (n > RA_CAP - fill) n = RA_CAP - fill;
		if (n > total - head)  n = total - head;
		uint32_t g = gen;
		pthread_mutex_unlock(&mx);

		// The source returns a full window or fails on its FIRST sector. A failed
		// burst is retried a sector at a time (a raw READ(10) fails the whole
		// command for one bad sector, so a failed burst says nothing about which),
		// and only a sector that keeps failing is zero-filled -- a hole, never a
		// stall: playback carries on from the ring while this is going on.
		int r = src(tmp, head, n);
		if (r < 0)
		{
			n = 1;
			for (int t = 0; t < RA_RETRIES && r < 0 && !stopping_or_moved(g); t++)
				r = src(tmp, head, 1);
			if (r < 0)
			{
				memset(tmp, 0, 2048);
				ra_log("LBA %u unreadable after %d tries, zero-filled", head, RA_RETRIES);
			}
		}

		pthread_mutex_lock(&mx);
		if (stop_req || g != gen) continue;   // retargeted meanwhile: drop it
		copy_in(head, tmp, n);
		fill += n;
	}
	pthread_mutex_unlock(&mx);
	return 0;
}

int dvd_ra_start(dvd_ra_source s, uint32_t n)
{
	dvd_ra_stop();
	if (!s || !n) return -1;

	ring = (uint8_t *)malloc((size_t)RA_CAP * 2048);
	tmp  = (uint8_t *)malloc((size_t)RA_BURST * 2048);
	if (!ring || !tmp)
	{
		free(ring); free(tmp); ring = tmp = 0;
		ra_log("out of memory for a %u-sector ring; reading synchronously", RA_CAP);
		return -1;
	}

	src = s;
	total = n;
	base = fill = 0;
	gen = 0;
	stop_req = 0;
	waiting = 0;
	log_n = 0;
	if (pthread_create(&th, 0, worker, 0) != 0)
	{
		free(ring); free(tmp); ring = tmp = 0;
		ra_log("worker thread failed to start; reading synchronously");
		return -1;
	}
	running = 1;
	return 0;
}

void dvd_ra_stop(void)
{
	if (!running) return;
	pthread_mutex_lock(&mx);
	stop_req = 1;
	pthread_cond_broadcast(&cv);
	pthread_mutex_unlock(&mx);
	pthread_join(th, 0);   // waits out one source read already in flight
	running = 0;
	free(ring); free(tmp);
	ring = tmp = 0;
	src = 0;
	total = 0;
}

int dvd_ra_active(void) { return running; }

int dvd_ra_ready(uint32_t lba, uint32_t count)
{
	if (!running) return 1;
	if (lba >= total) return 1;           // past the end: served as zeros
	uint32_t end = (count > total - lba) ? total : lba + count;

	pthread_mutex_lock(&mx);
	int hit = classify_hit(lba, end);
	if (hit) wait_done();
	pthread_mutex_unlock(&mx);
	return hit;
}

int dvd_ra_read(void *buf, uint32_t lba, uint32_t count)
{
	if (!running || !buf || !count) return -1;
	uint8_t *p = (uint8_t *)buf;
	if (lba >= total) { memset(p, 0, (size_t)count * 2048); return (int)count; }
	uint32_t end = (count > total - lba) ? total : lba + count;

	pthread_mutex_lock(&mx);
	if (!classify_hit(lba, end)) { pthread_mutex_unlock(&mx); return -1; }
	wait_done();
	copy_out(p, lba, end - lba);
	advance(end);
	pthread_mutex_unlock(&mx);

	if (end - lba < count) memset(p + (size_t)(end - lba) * 2048, 0, (size_t)(count - (end - lba)) * 2048);
	return (int)count;
}

int dvd_readahead_ready(uint64_t lba, uint32_t blks, uint64_t buffer_lba, uint32_t buf_n)
{
	if (!running) return 1;
	if (buffer_lba != (uint64_t)-1 && lba >= buffer_lba && lba + blks - buffer_lba <= buf_n)
		return 1;                          // Main's own window has it: no source read
	return dvd_ra_ready((uint32_t)lba, buf_n);
}
