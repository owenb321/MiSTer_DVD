// dvd_readahead_test.cpp — the RAM read-ahead between a disc source and the core.
//
// Field reports: a hitch in playback on physical discs, attributed to the dual-layer
// change. Main served every core request synchronously on its one thread, so ANY
// source stall -- a layer change, a re-spin, a scratch the sr driver retries for
// ~30 s, a network share hiccup -- reached the core, whose own cushion is ~0.6 s
// of audio at 448 kbps AC-3. dvd_readahead.cpp moves the source onto a worker that
// keeps a RAM ring ahead of the core, and the poll thread only copies out of it.
//
// The fake source below stamps every sector with its own LBA and can be told to
// STALL at an LBA or to FAIL one, so the arms score what the core would receive
// (was the window there when asked for, and is every sector the one it claims to
// be), never a signal the module names.
//
// Host-side: build with main/tests/run_tests.sh.

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <time.h>

#define RA_CAP 1024u      // small ring, so a few thousand sectors wrap it
#include "dvd_readahead.cpp"

// ------------------------------------------------------------------ fake source
static volatile uint32_t stall_at  = 0xFFFFFFFFu;   // a read covering this LBA stalls once
static volatile int      stall_ms  = 0;
// A read COVERING this LBA fails, always -- a raw READ(10) fails the whole command
// for one bad sector. (Failing only a read that STARTS here would let the worker's
// retry path go unexercised: its bursts straddle the sector, and [5] then passes on
// a worker that never retries or zero-fills anything.)
static volatile uint32_t bad_lba   = 0xFFFFFFFFu;
static volatile int      per_call_ms = 0;           // every call costs this much
static volatile int      calls;
static volatile int      fail_all  = 0;             // every read fails: an open tray

static void put_stamp(uint8_t *q, uint32_t lba) { memcpy(q, &lba, 4); q[4] = 0x5A; }
static uint32_t stamp_of(const uint8_t *q) { uint32_t v; memcpy(&v, q, 4); return v; }

static int fake_src(void *buf, uint32_t lba, uint32_t count)
{
	calls++;
	if (per_call_ms) usleep(per_call_ms * 1000);
	if (lba <= stall_at && stall_at < lba + count && stall_ms)
	{
		int ms = stall_ms;
		stall_ms = 0;                 // once
		usleep(ms * 1000);
	}
	if (fail_all) return -1;
	if (lba <= bad_lba && bad_lba < lba + count) return -1;
	for (uint32_t i = 0; i < count; i++)
	{
		put_stamp((uint8_t *)buf + (size_t)i * 2048, lba + i);
	}
	return (int)count;
}

static void reset_src(void)
{
	stall_at = 0xFFFFFFFFu; stall_ms = 0; bad_lba = 0xFFFFFFFFu; per_call_ms = 0; calls = 0;
	fail_all = 0;
}

// ------------------------------------------------------------------ harness
static int errs = 0;
static void check(const char *what, long got, long want)
{
	if (got != want) { printf("  FAIL %-50s got %ld, want %ld\n", what, got, want); errs++; }
	else             { printf("  ok   %-50s %ld\n", what, got); }
}

static long now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

// Main's shape: a request for `lba` is serviced when ready, else deferred to the
// next poll pass (here: 1 ms later). Returns the number of passes deferred, or -1
// if it never became ready within `limit_ms`.
static int serve(uint8_t *win, uint32_t lba, uint32_t n, long limit_ms)
{
	long t0 = now_ms();
	int deferred = 0;
	while (!dvd_ra_ready(lba, n))
	{
		if (now_ms() - t0 > limit_ms) return -1;
		deferred++;
		usleep(1000);
	}
	if (dvd_ra_read(win, lba, n) != (int)n) return -1;
	return deferred;
}

// Count sectors in `win` that are not the sector they claim to be.
static int wrong_in(const uint8_t *win, uint32_t lba, uint32_t n)
{
	int bad = 0;
	for (uint32_t i = 0; i < n; i++) if (stamp_of(win + (size_t)i * 2048) != lba + i) bad++;
	return bad;
}

int main(void)
{
	static uint8_t win[16 * 2048];

	// [1] THE GATE. Play linearly at a steady rate while the source stalls for
	//     300 ms part-way in. With the ring ahead of the core, not one request may
	//     find its window missing: the stall must not reach the core at all.
	printf("[1] a 300 ms source stall mid-stream is absorbed\n");
	reset_src();
	stall_at = 600; stall_ms = 300;
	dvd_ra_start(fake_src, 100000);
	usleep(20000);                                   // the ring gets going
	{
		int late = 0, wrong = 0, lost = 0;
		for (uint32_t lba = 0; lba < 1200; lba += 8)
		{
			int d = serve(win, lba, 8, 2000);
			if (d < 0) { lost++; continue; }
			if (lba > 0 && d > 0) late++;            // the first window is a cold start
			wrong += wrong_in(win, lba, 8);
			usleep(4000);                            // ~2 MB/s, the core's pace x ~1.6
		}
		check("windows the core had to wait for", late, 0);
		check("windows never served", lost, 0);
		check("sectors that were not what they claim", wrong, 0);
	}
	dvd_ra_stop();

	// [2] CONTROL: a stall longer than the ring's lead DOES reach the core, and
	//     says so -- otherwise [1] could pass on a harness that never stalls.
	printf("[2] a stall longer than the lead is felt (control for [1])\n");
	reset_src();
	per_call_ms = 1;
	stall_at = 1000; stall_ms = 600;           // past RA_STEADY windows of streaming
	dvd_ra_start(fake_src, 100000);
	{
		int late = 0;
		for (uint32_t lba = 0; lba < 1300; lba += 8)
		{
			int d = serve(win, lba, 8, 3000);
			if (lba > 0 && d > 0) late++;
		}
		check("the core waited at least once", late > 0, 1);
		check("...and the wait was logged", log_n > 0, 1);
	}
	dvd_ra_stop();

	// [3] A seek. The worker has a burst IN FLIGHT for the old position when the
	//     request moves; that burst must be dropped, not stored under the new
	//     address, and the landing must be served with exactly its own sectors.
	printf("[3] a seek while a burst is in flight\n");
	reset_src();
	per_call_ms = 20;                                // every read is slow: one is in flight
	dvd_ra_start(fake_src, 100000);
	usleep(5000);
	{
		check("far request is not ready at once", dvd_ra_ready(50000, 8), 0);
		int d = serve(win, 50000, 8, 2000);
		check("the landing is served", d >= 0, 1);
		check("landing sectors that are not what they claim", wrong_in(win, 50000, 8), 0);
		// Immediately ask for MORE than the first burst: only what is really
		// there may be served (a half-filled window must not pass as full).
		int r = dvd_ra_read(win, 50000, 16);
		check("a window reaching past the fill is refused or exact",
		      r < 0 ? 0 : wrong_in(win, 50000, 16), 0);
		d = serve(win, 50008, 8, 2000);
		check("playback continues after the landing", d >= 0 && !wrong_in(win, 50008, 8), 1);
	}
	dvd_ra_stop();

	// [4] Wrap the ring several times: 4000 sectors through a 1024-sector ring.
	//     Every sector must be the right one, and the ring must keep freeing room
	//     behind the consumer or the worker parks and playback stops.
	printf("[4] sequential playback wraps the ring\n");
	reset_src();
	dvd_ra_start(fake_src, 100000);
	{
		int lost = 0, wrong = 0;
		for (uint32_t lba = 0; lba < 4000; lba += 8)
		{
			if (serve(win, lba, 8, 1000) < 0) { lost++; break; }
			wrong += wrong_in(win, lba, 8);
		}
		check("windows never served", lost, 0);
		check("sectors that were not what they claim", wrong, 0);
	}
	dvd_ra_stop();

	// [5] An unreadable sector. The source keeps failing it; after the retries it
	//     becomes a zero-filled HOLE and playback carries on past it.
	printf("[5] an unreadable sector\n");
	reset_src();
	bad_lba = 300;
	dvd_ra_start(fake_src, 100000);
	{
		int lost = 0, wrong = 0, zero = 1;
		for (uint32_t lba = 296; lba < 400; lba += 8)
		{
			if (serve(win, lba, 8, 2000) < 0) { lost++; break; }
			for (uint32_t i = 0; i < 8; i++)
			{
				const uint8_t *q = win + (size_t)i * 2048;
				if (lba + i == 300) { for (int k = 0; k < 2048; k++) if (q[k]) zero = 0; }
				else if (stamp_of(q) != lba + i) wrong++;
			}
		}
		check("playback continues past it", lost, 0);
		check("the unreadable sector is zeros", zero, 1);
		check("its neighbours are intact", wrong, 0);
	}
	dvd_ra_stop();

	// [6] The end of the source: a window reaching past it is served in full, the
	//     tail as zeros (Main caches all 8), and a request past it is ready at once.
	printf("[6] the end of the source\n");
	reset_src();
	dvd_ra_start(fake_src, 1000);
	{
		memset(win, 0xEE, sizeof win);
		check("the last window is served", serve(win, 996, 8, 1000) >= 0, 1);
		check("its real sectors are right", wrong_in(win, 996, 4), 0);
		int zero = 1;
		for (int k = 4 * 2048; k < 8 * 2048; k++) if (win[k]) zero = 0;
		check("its tail past the end is zeros", zero, 1);
		check("a request past the end is ready", dvd_ra_ready(1000, 8), 1);
	}
	dvd_ra_stop();

	// [7] The poll thread never blocks: a miss returns at once whatever the
	//     source is doing, and Main's own window short-circuits the ring.
	printf("[7] nothing on the poll thread blocks\n");
	reset_src();
	per_call_ms = 300;
	dvd_ra_start(fake_src, 100000);
	{
		long t0 = now_ms();
		int r = dvd_ra_read(win, 70000, 8);
		check("a miss is refused", r, -1);
		check("...without waiting for the source", now_ms() - t0 < 50, 1);
		check("Main's own window is a hit", dvd_readahead_ready(70003, 1, 70000, 8), 1);
		t0 = now_ms();
		dvd_ra_stop();
		check("stop waits out the one read in flight, no more", now_ms() - t0 < 700, 1);
	}
	// [8] A wait while the ring is still filling from a (re)start is not a stall:
	//     the mount's scattered IFO reads and every seek look like this. Logged as
	//     "ring ran dry", it put false alarms in the one log a hitch report reads.
	printf("[8] a cold-start wait is not reported as the ring running dry\n");
	reset_src();
	per_call_ms = 150;
	dvd_ra_start(fake_src, 100000);
	serve(win, 0, 8, 2000);
	serve(win, 8, 8, 2000);
	check("cold-start waits logged as a dry ring", log_n, 0);
	dvd_ra_stop();

	// [9] The tray opened: every read fails. The worker must leave the drive IDLE
	//     between attempts, promptly, because dvd_phys_tick() only probes an idle
	//     drive and the probe is what notices the eject. Measured on the rig before
	//     this: failing reads back to back kept it ~80 % busy and the eject took
	//     ~8 s to notice while the ring played on.
	printf("[9] a failing drive is left idle between attempts\n");
	reset_src();
	per_call_ms = 50;
	dvd_ra_start(fake_src, 100000);
	usleep(80000);                              // the ring is streaming
	fail_all = 1;                               // tray opens
	{
		long t0 = now_ms(), first_idle = -1;
		int saw_busy = 0;
		while (now_ms() - t0 < 600)
		{
			int b = dvd_ra_source_busy();
			if (b) saw_busy = 1;
			else if (saw_busy && first_idle < 0 && calls > 0) first_idle = now_ms() - t0;
			usleep(2000);
		}
		check("the worker was reading when the tray opened", saw_busy, 1);
		check("drive idle within 300 ms of the tray opening", first_idle >= 0 && first_idle < 300, 1);
	}
	dvd_ra_stop();

	check("idle: every request may be serviced (stock behaviour)", dvd_readahead_ready(123, 1, (uint64_t)-1, 8), 1);

	printf("\ndvd_readahead_test: %s (%d error%s)\n", errs ? "FAIL" : "PASS", errs, errs == 1 ? "" : "s");
	return errs ? 1 : 0;
}
