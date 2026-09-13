// dvd_remote_test.cpp — the Eject/Volume request decoding in dvd_remote.cpp.
//
// WHY THIS NEEDS A TEST
//
// The core cannot tell Main "do it once". Main POLLS the CMD_AF word, so a
// LEVEL would be re-read as a fresh request on every poll: one Eject press
// would eject repeatedly, and holding Vol Up would run the volume to an end
// stop. The protocol is therefore a toggle plus two wrapping counters, and
// every interesting property is about what Main does BETWEEN two polls:
//
//   * the first valid word must act on NOTHING (whatever the counters hold at
//     core load is history, not a request);
//   * a press burst between polls must apply that many steps, not one;
//   * the counters wrap at 16, so the difference is mod 16;
//   * an old core, or one without the version bit, must produce no requests at
//     all AND must not leave a stale baseline behind;
//   * the direction must match set_volume()'s own convention, which is +1 =
//     louder (user_io.cpp:4274/4279) -- the first draft of the module had both
//     directions positive, which is the ab_repeat jump_dir mistake again.
//
// The module is #included, so this exercises the real decoder.

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>

// ---------------------------------------------------------------- fake world
static uint16_t fake_magic = 0xD7D1;
static uint16_t fake_word  = 0;
static int      fake_is_dvd_v = 1;
static int      fake_ui_busy = 0;

static int      n_eject = 0;         // dvd_phys_eject() calls
static int      vol_net = 0;         // sum of set_volume() arguments
static int      n_vol   = 0;         // number of set_volume() calls
static int      last_vol_arg = 0;

static int  is_dvd(void)                    { return fake_is_dvd_v; }
static int  dvd_launch_ui_busy(void)        { return fake_ui_busy; }

// One poll per tick: the module self-throttles on GetTimer/CheckTimer, and we
// want every tick() call to actually read, so CheckTimer always says "due".
static unsigned long GetTimer(unsigned long) { return 1; }
static int  CheckTimer(unsigned long)        { return 1; }

static uint16_t spi_uio_cmd_cont(uint16_t)   { return fake_magic; }
static uint16_t spi_w(uint16_t)              { return fake_word; }
static void     DisableIO(void)              {}

// Definitions of what the real headers declare.
int  dvd_phys_eject(void)                    { n_eject++; return 1; }
void set_volume(int cmd)                     { n_vol++; vol_net += cmd; last_vol_arg = cmd; }

#include "dvd_remote.cpp"

// ---------------------------------------------------------------------- rig
static int fails = 0;
static void ck(const char *what, long got, long want)
{
	if (got != want) { printf("  FAIL %-52s got %ld want %ld\n", what, got, want); fails++; }
	else             printf("  ok   %-52s %ld\n", what, got);
}

// Build a CMD_AF word. v3=1 unless told otherwise.
static uint16_t mk(int eject_tgl, int volup, int voldn, int v3 = 1)
{
	return (uint16_t)((1u << 15)                  // format v2
	                | ((v3 ? 1u : 0u) << 12)      // format v3
	                | ((voldn & 0xF) << 8)
	                | ((volup & 0xF) << 4)
	                | ((eject_tgl & 1) << 3));
}

static void zero(void) { n_eject = 0; vol_net = 0; n_vol = 0; last_vol_arg = 0; }

// Force the module back to "no baseline", the way a core reload would.
static void drop_baseline(void)
{
	fake_magic = 0x0000;
	dvd_remote_tick();
	fake_magic = 0xD7D1;
}

int main(void)
{
	printf("### dvd_remote_test\n");

	// ---- [1] the first valid word must act on nothing -------------------
	// A core that has been up for a while holds arbitrary counter values; the
	// first poll after a core load must latch them, not replay them.
	drop_baseline(); zero();
	fake_word = mk(1, 7, 3);
	dvd_remote_tick();
	ck("[1] first word: no eject", n_eject, 0);
	ck("[1] first word: no volume", n_vol, 0);

	// ---- [2] one Vol Up press = one step, in the LOUDER direction -------
	zero();
	fake_word = mk(1, 8, 3);
	dvd_remote_tick();
	ck("[2] one up press -> one call", n_vol, 1);
	ck("[2] ...and it is +1 (louder)", last_vol_arg, +1);

	// ---- [3] one Vol Down press is -1 -----------------------------------
	zero();
	fake_word = mk(1, 8, 4);
	dvd_remote_tick();
	ck("[3] one down press -> one call", n_vol, 1);
	ck("[3] ...and it is -1 (quieter)", last_vol_arg, -1);

	// ---- [4] a BURST between polls applies every press ------------------
	// This is the whole reason the field is a counter and not a toggle.
	zero();
	fake_word = mk(1, 11, 4);        // +3 up
	dvd_remote_tick();
	ck("[4] three presses between polls -> three steps", n_vol, 3);
	ck("[4] ...all louder", vol_net, +3);

	// ---- [5] the counter WRAPS, so the difference is mod 16 -------------
	// Deliberately kept BELOW VOL_MAX_PER_POLL so this arm measures the wrap
	// arithmetic and not the cap -- [8] owns the cap. (The first draft used
	// 11->1 = +6, which the cap clamped to 4, and the two arms then tested the
	// same thing while appearing to test different ones.)
	zero();
	fake_word = mk(1, 14, 4);        // 11 -> 14 = +3
	dvd_remote_tick();
	zero();
	fake_word = mk(1, 1, 4);         // 14 -> 1 = +3 mod 16, NOT -13
	dvd_remote_tick();
	ck("[5] wrap 14->1 is +3 steps (mod 16)", n_vol, 3);

	// ---- [6] no change = no request -------------------------------------
	zero();
	dvd_remote_tick();
	dvd_remote_tick();
	ck("[6] idle polls do nothing (volume)", n_vol, 0);
	ck("[6] idle polls do nothing (eject)", n_eject, 0);

	// ---- [7] the eject TOGGLE acts once per flip ------------------------
	zero();
	fake_word = mk(0, 1, 4);         // toggle 1 -> 0
	dvd_remote_tick();
	ck("[7] toggle flip -> one eject", n_eject, 1);
	dvd_remote_tick();
	dvd_remote_tick();
	ck("[7] ...and NOT again while it holds", n_eject, 1);
	fake_word = mk(1, 1, 4);         // flip back
	dvd_remote_tick();
	ck("[7] the other flip ejects too", n_eject, 2);

	// ---- [8] a volume burst is CAPPED ------------------------------------
	// user_io_poll() can stall for minutes (a CSS crack is synchronous), and
	// the counter wraps, so an unbounded catch-up could run the volume to an
	// end stop from one stale poll.
	zero();
	fake_word = mk(1, 1 + 15, 4);    // 1 -> 0 = +15 up in one gap
	dvd_remote_tick();
	ck("[8] a huge gap is capped", n_vol, 4);

	// ---- [9] an OLD core makes no requests and leaves no baseline -------
	// v3 clear means the field is not there at all; acting on it would eject
	// on the strength of bits that mean nothing.
	drop_baseline(); zero();
	fake_word = mk(1, 5, 5, /*v3=*/0);
	dvd_remote_tick();
	dvd_remote_tick();
	ck("[9] no v3 bit: no eject", n_eject, 0);
	ck("[9] no v3 bit: no volume", n_vol, 0);
	// ...and when a v3 core appears, the first word is still a baseline only.
	fake_word = mk(0, 9, 9, 1);
	dvd_remote_tick();
	ck("[9] first v3 word after that is a baseline", n_eject, 0);

	// ---- [10] a wrong MAGIC is not a request ----------------------------
	drop_baseline(); zero();
	fake_magic = 0x1234;
	fake_word  = mk(0, 3, 3);
	dvd_remote_tick();
	ck("[10] bad magic: nothing", n_eject + n_vol, 0);
	fake_magic = 0xD7D1;

	// ---- [11] a non-DVD core is inert -----------------------------------
	drop_baseline(); zero();
	fake_is_dvd_v = 0;
	fake_word = mk(1, 2, 2);
	dvd_remote_tick();
	dvd_remote_tick();
	ck("[11] not the DVD core: nothing", n_eject + n_vol, 0);
	fake_is_dvd_v = 1;

	// ---- [12] the MGL launch gate ---------------------------------------
	// set_volume() renders an on-screen bar via Info(), and UI work from a
	// poll tick while an MGL is mid-flight is the issue #48 freeze.
	drop_baseline(); zero();
	fake_word = mk(0, 0, 0);
	dvd_remote_tick();                 // baseline
	fake_ui_busy = 1;
	fake_word = mk(1, 2, 0);           // an eject AND two volume presses
	dvd_remote_tick();
	ck("[12] launch busy: no volume", n_vol, 0);
	ck("[12] launch busy: no eject", n_eject, 0);
	fake_ui_busy = 0;

	printf(fails ? "dvd_remote_test: %d FAILURE(S)\n" : "dvd_remote_test: ALL GREEN\n", fails);
	return fails ? 1 : 0;
}
