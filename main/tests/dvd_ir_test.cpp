// dvd_ir_test.cpp — the IR / media-key remap table in dvd_ir.cpp.
//
// WHY THIS NEEDS A TEST
//
// Every failure mode here is SILENT. A wrong target still produces a keypress,
// still reaches the core, and still does *something* -- so a mistake surfaces
// as "the Stop button goes up a menu level", reported weeks later by a user who
// cannot tell our table from the disc's own behaviour. Nothing crashes, nothing
// logs, and the only thing that can catch it early is an assertion naming the
// button each key is supposed to reach.
//
// The properties worth pinning are the ones a careless edit breaks:
//
//   * the ten numerics must land on their OWN digits, in order -- an off-by-one
//     silently shifts every disc-menu button;
//   * no target may itself be a source, or the table could chain or oscillate
//     depending only on row order;
//   * no source may appear twice, because the first match wins and the second
//     row would be dead code that looks live;
//   * the reserved keys (volume, the OSD toggle, Delete, power) must stay
//     unclaimed -- each is owned by Main or by a combo, and taking one is a
//     regression in a path that has nothing to do with DVDs;
//   * the ini gate and the is_dvd() scope must both actually gate.
//
// The module is #included, so this exercises the real table and the real
// lookup rather than a paraphrase of them.

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <linux/input.h>

// ---------------------------------------------------------------- fake world
// The test tree stubs Main's headers as EMPTY files, so whatever dvd_ir.cpp
// reaches for through them must be defined here, before the #include.
struct { uint8_t dvd_ir_remap; } cfg;

static int fake_is_dvd_v = 1;
static int is_dvd(void) { return fake_is_dvd_v; }

#include "dvd_ir.cpp"

// ---------------------------------------------------------------------- rig
static int fails = 0;

static void ck(const char *what, long got, long want)
{
	if (got != want) { printf("  FAIL %-58s got %ld want %ld\n", what, got, want); fails++; }
	else             printf("  ok   %-58s %ld\n", what, got);
}

// Assert a key reaches a given target while playing (osd_open = 0).
static void play(const char *what, uint16_t from, uint16_t want)
{
	ck(what, dvd_ir_target(from, 0), want);
}

static void osd(const char *what, uint16_t from, uint16_t want)
{
	ck(what, dvd_ir_target(from, 1), want);
}

int main(void)
{
	cfg.dvd_ir_remap = 0;
	fake_is_dvd_v = 1;

	printf("[1] KEY_PAUSE routes to Pause, not the E1 sequence\n");
	// ev2ps2[KEY_PAUSE] is 0xE1, the multi-byte PS/2 Pause sequence kbd_map.sv
	// never binds -- so without a row here the most obvious button is inert.
	play("KEY_PAUSE -> KEY_SPACE (B1)", KEY_PAUSE, KEY_SPACE);

	printf("[2] the five Play/Pause spellings all reach B1\n");
	play("KEY_PLAY -> B1",      KEY_PLAY,      KEY_SPACE);
	play("KEY_PLAYPAUSE -> B1", KEY_PLAYPAUSE, KEY_SPACE);
	play("KEY_PLAYCD -> B1",    KEY_PLAYCD,    KEY_SPACE);
	play("KEY_PAUSECD -> B1",   KEY_PAUSECD,   KEY_SPACE);

	printf("[3] Stop is B14, not Return\n");
	play("KEY_STOP -> KEY_Q (B14)",   KEY_STOP,   KEY_Q);
	play("KEY_STOPCD -> KEY_Q (B14)", KEY_STOPCD, KEY_Q);

	printf("[4] FF/REW reach the 10 s seek keys\n");
	play("KEY_FASTFORWARD -> KEY_TAB (B10)",       KEY_FASTFORWARD, KEY_TAB);
	play("KEY_REWIND -> KEY_BACKSPACE (B11)",      KEY_REWIND,      KEY_BACKSPACE);
	play("KEY_FASTREVERSE -> KEY_BACKSPACE (B11)", KEY_FASTREVERSE, KEY_BACKSPACE);

	printf("[5] Exit and Back go up a level while playing\n");
	play("KEY_EXIT -> KEY_B (B13)", KEY_EXIT, KEY_B);
	play("KEY_BACK -> KEY_B (B13)", KEY_BACK, KEY_B);

	printf("[6] Exit and Back cancel the OSD\n");
	// The one place the two columns must differ: in the OSD, "back" means
	// cancel, not "go up a disc level".
	osd("KEY_EXIT -> KEY_ESC in OSD", KEY_EXIT, KEY_ESC);
	osd("KEY_BACK -> KEY_ESC in OSD", KEY_BACK, KEY_ESC);

	printf("[7] OK activates a menu button\n");
	play("KEY_OK -> KEY_ENTER (B4)",     KEY_OK,     KEY_ENTER);
	play("KEY_SELECT -> KEY_ENTER (B4)", KEY_SELECT, KEY_ENTER);
	osd("KEY_OK -> KEY_ENTER in OSD",    KEY_OK,     KEY_ENTER);

	printf("[8] the green Start button opens the MiSTer OSD\n");
	// KEY_MENU, not KEY_F12 -- user_io.cpp gates plain F12 on a modifier.
	play("KEY_MEDIA -> KEY_MENU",     KEY_MEDIA,    KEY_MENU);
	osd("KEY_MEDIA -> KEY_MENU (OSD)", KEY_MEDIA,   KEY_MENU);
	play("KEY_HOMEPAGE -> KEY_MENU",  KEY_HOMEPAGE, KEY_MENU);

	printf("[9] ten numerics reach ten digit keys, in order\n");
	{
		// KEY_0 is 11 and KEY_1..KEY_9 are 2..10 -- NOT contiguous with KEY_0,
		// which is exactly the shape an off-by-one would survive.
		const uint16_t want[10] = { KEY_0, KEY_1, KEY_2, KEY_3, KEY_4,
		                            KEY_5, KEY_6, KEY_7, KEY_8, KEY_9 };
		for (int d = 0; d < 10; d++)
		{
			char lbl[64];
			snprintf(lbl, sizeof(lbl), "KEY_NUMERIC_%d -> digit %d", d, d);
			play(lbl, (uint16_t)(KEY_NUMERIC_0 + d), want[d]);
		}
	}

	printf("[10] volume is left to Main's one attenuator\n");
	play("KEY_VOLUMEUP untouched",   KEY_VOLUMEUP,   0);
	play("KEY_VOLUMEDOWN untouched", KEY_VOLUMEDOWN, 0);
	play("KEY_MUTE untouched",       KEY_MUTE,       0);

	printf("[11] the OSD toggle is never claimed\n");
	play("KEY_MENU untouched",       KEY_MENU, 0);
	osd("KEY_MENU untouched in OSD", KEY_MENU, 0);

	printf("[12] Delete stays on the reset combo\n");
	play("KEY_DELETE untouched", KEY_DELETE, 0);

	printf("[13] power keys are never a media action\n");
	play("KEY_POWER2 untouched", KEY_POWER2, 0);
	play("KEY_SLEEP untouched",  KEY_SLEEP,  0);
	play("KEY_RECORD untouched", KEY_RECORD, 0);

	printf("[13b] every reserved key is unclaimed, both columns\n");
	for (int i = 0; i < IR_DENY_N; i++)
	{
		char lbl[64];
		snprintf(lbl, sizeof(lbl), "reserved key %u unclaimed", (unsigned)ir_deny[i]);
		ck(lbl, dvd_ir_target(ir_deny[i], 0) | dvd_ir_target(ir_deny[i], 1), 0);
	}

	printf("[14] an ordinary key is passed through\n");
	play("KEY_W untouched",     KEY_W,     0);
	play("KEY_SPACE untouched", KEY_SPACE, 0);

	printf("[15] no target is itself a remap source\n");
	{
		// Proves the table cannot chain or oscillate: whatever we rewrite TO
		// must be a terminal key, whichever order the rows happen to sit in.
		int chains = 0;
		for (int i = 0; i < IR_TBL_N; i++)
		{
			if (dvd_ir_target(ir_tbl[i].to_play, 0)) chains++;
			if (ir_tbl[i].to_osd && dvd_ir_target(ir_tbl[i].to_osd, 0)) chains++;
		}
		ck("rows whose target is also a source", chains, 0);
	}

	printf("[16] no source appears twice\n");
	{
		// A duplicate is dead code that LOOKS live -- the first match wins.
		int dups = 0;
		for (int i = 0; i < IR_TBL_N; i++)
			for (int j = i + 1; j < IR_TBL_N; j++)
				if (ir_tbl[i].from == ir_tbl[j].from) dups++;
		ck("duplicate source rows", dups, 0);
	}

	printf("[16b] every row names the button it must reach\n");
	{
		// tools/check_ir_remap.py resolves this string against kbd_map.sv, so an
		// empty one would make that gate vacuous for the row.
		int blank = 0;
		for (int i = 0; i < IR_TBL_N; i++)
			if (!ir_tbl[i].why || !ir_tbl[i].why[0]) blank++;
		ck("rows with no why string", blank, 0);
	}

	printf("[17] the gate is off when the ini says off\n");
	// ⚠ 1 = ON, 0 = OFF. The opposite sense shipped briefly on the belief that
	// cfg had no defaults pass and 0 therefore had to mean on; cfg_parse() DOES
	// have one (integration step 54 sets cfg.dvd_ir_remap = 1 there), and "1
	// disables a thing" reads backwards to anyone editing MiSTer.ini.
	cfg.dvd_ir_remap = 0;
	ck("DVD_IR_REMAP=0 -> inactive", dvd_ir_active(), 0);
	cfg.dvd_ir_remap = 1;
	ck("DVD_IR_REMAP=1 -> active on the DVD core", dvd_ir_active(), 1);

	printf("[18] another core is not remapped unless asked\n");
	fake_is_dvd_v = 0;
	cfg.dvd_ir_remap = 1;
	ck("non-DVD core, mode 1 -> inactive", dvd_ir_active(), 0);
	cfg.dvd_ir_remap = 2;
	ck("non-DVD core, mode 2 -> active",   dvd_ir_active(), 1);
	fake_is_dvd_v = 1;
	cfg.dvd_ir_remap = 1;

	printf("[19] the A/V feature keys reach their buttons\n");
	play("KEY_TITLE -> KEY_T (B12)",       KEY_TITLE,       KEY_T);
	play("KEY_SUBTITLE -> KEY_S (B8)",     KEY_SUBTITLE,    KEY_S);
	play("KEY_AUDIO -> KEY_A (B7)",        KEY_AUDIO,       KEY_A);
	play("KEY_INFO -> KEY_D (B9)",         KEY_INFO,        KEY_D);
	play("KEY_DVD -> KEY_M (B5)",          KEY_DVD,         KEY_M);
	play("KEY_ANGLE -> KEY_G (B6)",        KEY_ANGLE,       KEY_G);
	play("KEY_FULL_SCREEN -> KEY_Z (B15)", KEY_FULL_SCREEN, KEY_Z);
	play("KEY_NEXT -> KEY_N (B3)",         KEY_NEXT,        KEY_N);
	play("KEY_PREVIOUS -> KEY_P (B2)",     KEY_PREVIOUS,    KEY_P);
	play("KEY_EJECTCD -> KEY_E (B19)",     KEY_EJECTCD,     KEY_E);

	printf("[20] the four homeless functions have a home (decision D3)\n");
	// Guide/RecordedTV/LiveTV/Pictures are meaningless on a DVD player, so they
	// carry the core functions no remote button matches.
	play("KEY_EPG -> KEY_F5 (B16 Chapter Menu)", KEY_EPG,    KEY_F5);
	play("KEY_PVR -> KEY_L (B17 A-B Repeat)",    KEY_PVR,    KEY_L);
	play("KEY_TUNER -> KEY_G (B6 Angle)",        KEY_TUNER,  KEY_G);
	play("KEY_CAMERA -> KEY_DOT (B18 Frame Step)", KEY_CAMERA, KEY_DOT);

	printf("[21] colour keys are aliases of existing buttons\n");
	play("KEY_RED -> KEY_F2 (B12 Title)",    KEY_RED,    KEY_F2);
	play("KEY_GREEN -> KEY_F3 (B7 Audio)",   KEY_GREEN,  KEY_F3);
	play("KEY_YELLOW -> KEY_F4 (B8 Subtitle)", KEY_YELLOW, KEY_F4);
	play("KEY_BLUE -> KEY_F1 (B5 Menu)",     KEY_BLUE,   KEY_F1);

	printf("\n%s: %d failure(s)\n", fails ? "dvd_ir_test FAILED" : "dvd_ir_test PASSED", fails);
	return fails ? 1 : 0;
}
