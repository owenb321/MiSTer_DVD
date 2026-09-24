// dvd_ir.cpp — see dvd_ir.h for why this exists and what it deliberately
// refuses to touch.

#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <linux/input.h>

#include "../../user_io.h"
#include "../../cfg.h"
#include "dvd_ir.h"

// ⚠ CROSS-COMPILE GUARD, and it is not hypothetical: the ARM toolchain
// (gcc-arm-10.2-2020.11) carries older UAPI headers than the build host, and a
// name it lacks is a hard compile error that a host g++ smoke test cannot see
// -- exactly how dvd_vcd.cpp's missing <limits.h> got through. These values are
// UAPI and therefore ABI-stable, so a literal fallback is safe.
#ifndef KEY_ROOT_MENU
#define KEY_ROOT_MENU      0x26a
#endif
#ifndef KEY_MEDIA_TOP_MENU
#define KEY_MEDIA_TOP_MENU 0x26b
#endif
#ifndef KEY_FASTREVERSE
#define KEY_FASTREVERSE    0x275
#endif
// ⚠ ABSENT from the ARM toolchain's own UAPI header (gcc-arm-10.2 ships 446
// KEY_* names against this host's 527), and the cross-compile is the ONLY
// thing that can see that -- caught by tools/check_ir_remap.py running from
// build_main.sh INSIDE the container, before the compiler got to it.
// KEY_ZOOM is the same code (0x174) and IS present there, so this guard is
// what keeps the two spellings interchangeable on both toolchains.
#ifndef KEY_FULL_SCREEN
#define KEY_FULL_SCREEN    0x174
#endif
#ifndef KEY_ASPECT_RATIO
#define KEY_ASPECT_RATIO   0x177
#endif
#ifndef KEY_CONTEXT_MENU
#define KEY_CONTEXT_MENU   0x1b6
#endif
#ifndef KEY_MEDIA_REPEAT
#define KEY_MEDIA_REPEAT   0x1b7
#endif

// A row's `why` names the core button it must land on. It is not a comment:
// tools/check_ir_remap.py parses it, resolves to_play through the stock
// ev2ps2[] table and then through dvd/kbd_map.sv, and FAILS if the key does not
// actually reach the button named here. A table that cannot go stale beats a
// correct one.
struct ir_map { uint16_t from; uint16_t to_play; uint16_t to_osd; const char *why; };

// ⚠ ONE ROW PER LINE. main/tests/run_tests.sh mutates with line-based sed, so a
// row split across lines cannot be targeted by its own RED arm.
//
// to_osd == 0 means "while the MiSTer OSD is up, leave this key alone". It
// never means "suppress it".
static const struct ir_map ir_tbl[] = {
	// -- transport ----------------------------------------------------------
	// ★ KEY_PAUSE is the marquee fix: ev2ps2[119] is 0xE1, the multi-byte PS/2
	// Pause sequence dvd/kbd_map.sv deliberately never binds -- so the most
	// obvious button on the remote is inert today for a reason unrelated to
	// the 255 ceiling everyone points at.
	{ KEY_PLAY,             KEY_SPACE,      0,              "B1 Pause" },
	{ KEY_PAUSE,            KEY_SPACE,      0,              "B1 Pause" },
	{ KEY_PLAYPAUSE,        KEY_SPACE,      0,              "B1 Pause" },
	{ KEY_PLAYCD,           KEY_SPACE,      0,              "B1 Pause" },
	{ KEY_PAUSECD,          KEY_SPACE,      0,              "B1 Pause" },
	{ KEY_STOP,             KEY_Q,          0,              "B14 Stop" },
	{ KEY_STOPCD,           KEY_Q,          0,              "B14 Stop" },
	{ KEY_FASTFORWARD,      KEY_TAB,        0,              "B10 Fast Fwd" },
	{ KEY_REWIND,           KEY_BACKSPACE,  0,              "B11 Rewind" },
	{ KEY_FASTREVERSE,      KEY_BACKSPACE,  0,              "B11 Rewind" },
	{ KEY_NEXT,             KEY_N,          KEY_PAGEDOWN,   "B3 Next Chapter" },
	{ KEY_NEXTSONG,         KEY_N,          KEY_PAGEDOWN,   "B3 Next Chapter" },
	{ KEY_PREVIOUS,         KEY_P,          KEY_PAGEUP,     "B2 Prev Chapter" },
	{ KEY_PREVIOUSSONG,     KEY_P,          KEY_PAGEUP,     "B2 Prev Chapter" },
	{ KEY_EJECTCD,          KEY_E,          0,              "B19 Eject" },
	{ KEY_EJECTCLOSECD,     KEY_E,          0,              "B19 Eject" },
	// -- navigation ---------------------------------------------------------
	// ⚠ KEY_MENU (139), NOT KEY_F12: user_io.cpp:4357 gates plain F12 on a
	// modifier condition, while KEY_MENU takes the same branch unconditionally
	// and is folded to F12 one line later. Same effect, one fewer dependency.
	{ KEY_OK,               KEY_ENTER,      KEY_ENTER,      "B4 Select" },
	{ KEY_SELECT,           KEY_ENTER,      KEY_ENTER,      "B4 Select" },
	{ KEY_EXIT,             KEY_B,          KEY_ESC,        "B13 Return" },
	{ KEY_BACK,             KEY_B,          KEY_ESC,        "B13 Return" },
	{ KEY_DVD,              KEY_M,          0,              "B5 Menu" },
	{ KEY_ROOT_MENU,        KEY_M,          0,              "B5 Menu" },
	{ KEY_TITLE,            KEY_T,          0,              "B12 Title" },
	{ KEY_MEDIA_TOP_MENU,   KEY_T,          0,              "B12 Title" },
	{ KEY_CONTEXT_MENU,     KEY_F5,         0,              "B16 Chapter Menu" },
	{ KEY_MEDIA,            KEY_MENU,       KEY_MENU,       "MiSTer OSD" },
	{ KEY_HOMEPAGE,         KEY_MENU,       KEY_MENU,       "MiSTer OSD" },
	{ KEY_CONFIG,           KEY_MENU,       KEY_MENU,       "MiSTer OSD" },
	// -- the numeric pad (dvd/emu.sv decodes these itself for menu buttons) --
	// ⚠ IN ORDER. An off-by-one here silently shifts every disc-menu button,
	// which is why the test asserts all ten against their own digits.
	{ KEY_NUMERIC_0,        KEY_0,          KEY_0,          "digit" },
	{ KEY_NUMERIC_1,        KEY_1,          KEY_1,          "digit" },
	{ KEY_NUMERIC_2,        KEY_2,          KEY_2,          "digit" },
	{ KEY_NUMERIC_3,        KEY_3,          KEY_3,          "digit" },
	{ KEY_NUMERIC_4,        KEY_4,          KEY_4,          "digit" },
	{ KEY_NUMERIC_5,        KEY_5,          KEY_5,          "digit" },
	{ KEY_NUMERIC_6,        KEY_6,          KEY_6,          "digit" },
	{ KEY_NUMERIC_7,        KEY_7,          KEY_7,          "digit" },
	{ KEY_NUMERIC_8,        KEY_8,          KEY_8,          "digit" },
	{ KEY_NUMERIC_9,        KEY_9,          KEY_9,          "digit" },
	// -- A/V feature keys ---------------------------------------------------
	// ⚠ KEY_ZOOM IS KEY_FULL_SCREEN and KEY_SCREEN IS KEY_ASPECT_RATIO -- they
	// are aliases, not four codes. Listing all four would be a duplicate source
	// row, which the test sweeps for.
	{ KEY_INFO,             KEY_D,          0,              "B9 Display" },
	{ KEY_SUBTITLE,         KEY_S,          0,              "B8 Subtitle" },
	{ KEY_LANGUAGE,         KEY_A,          0,              "B7 Audio" },
	{ KEY_AUDIO,            KEY_A,          0,              "B7 Audio" },
	{ KEY_FULL_SCREEN,      KEY_Z,          0,              "B15 Aspect" },
	{ KEY_ASPECT_RATIO,     KEY_Z,          0,              "B15 Aspect" },
	{ KEY_ANGLE,            KEY_G,          0,              "B6 Angle" },
	{ KEY_MEDIA_REPEAT,     KEY_L,          0,              "B17 A-B Repeat" },
	{ KEY_SLOW,             KEY_DOT,        0,              "B18 Frame Step" },
	{ KEY_CHANNELUP,        KEY_N,          KEY_PAGEUP,     "B3 Next Chapter" },
	{ KEY_CHANNELDOWN,      KEY_P,          KEY_PAGEDOWN,   "B2 Prev Chapter" },
	// -- media-source buttons a Media Center handset has, reused for the four
	// core functions with no natural remote button (maintainer decision D3).
	// These are meaningless on a DVD player, so nothing is lost.
	{ KEY_EPG,              KEY_F5,         0,              "B16 Chapter Menu" },
	{ KEY_PVR,              KEY_L,          0,              "B17 A-B Repeat" },
	{ KEY_TUNER,            KEY_G,          0,              "B6 Angle" },
	{ KEY_TV,               KEY_G,          0,              "B6 Angle" },
	{ KEY_CAMERA,           KEY_DOT,        0,              "B18 Frame Step" },
	// -- teletext colour keys: ALIASES ONLY -----------------------------------
	// ⚠ No core function is parked solely here. European/teletext handsets have
	// these; the maintainer's does not, which is why D3 above puts the four
	// homeless functions on buttons that physically exist on a US handset.
	// Mapping matches the CEC convention already in the manual.
	{ KEY_RED,              KEY_F2,         0,              "B12 Title" },
	{ KEY_GREEN,            KEY_F3,         0,              "B7 Audio" },
	{ KEY_YELLOW,           KEY_F4,         0,              "B8 Subtitle" },
	{ KEY_BLUE,             KEY_F1,         0,              "B5 Menu" },
};

// Keys this table must NEVER claim. An omission is not a decision, so each one
// is listed with its reason and tools/check_ir_remap.py fails if any of them
// ever appears as a `from` above.
static const uint16_t ir_deny[] = {
	KEY_MUTE,            // Main owns the one attenuator -- user_io.cpp:4266
	KEY_VOLUMEUP,        //   "
	KEY_VOLUMEDOWN,      //   "
	KEY_MENU,            // the OSD toggle, and many remotes' only route to it
	KEY_DELETE,          // folded into the ctrl-alt-del reset combo, input.cpp:3799
	KEY_POWER2,          // never bind a power key to a media action
	KEY_SLEEP,           //   "
	KEY_RECORD,          // no core action; binding it would surprise
	KEY_BRIGHTNESSUP,    // Main uses pseudo-codes 0xBE/0xBF, not these
	KEY_BRIGHTNESSDOWN,  //   "
};

// Considered and DELIBERATELY left unbound, so a later reader does not assume
// they were forgotten: KEY_RADIO, KEY_PLAYER, KEY_VIDEO, KEY_MODE,
// KEY_PRESENTATION, KEY_MESSENGER, KEY_PRINT, KEY_NUMERIC_STAR,
// KEY_NUMERIC_POUND, KEY_CLEAR, KEY_GOTO, KEY_LIST, KEY_CHANNEL, KEY_SHUFFLE,
// KEY_RESTART, KEY_LAST, KEY_SETUP, KEY_CYCLEWINDOWS, KEY_VIDEO_NEXT.
// An unbound key is honest; a wrongly bound one is a support ticket.

#define IR_TBL_N  ((int)(sizeof(ir_tbl) / sizeof(ir_tbl[0])))
#define IR_DENY_N ((int)(sizeof(ir_deny) / sizeof(ir_deny[0])))

static char g_summary[192] = "ir: not probed";
static int  g_probed = 0;

static void irlog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void irlog(const char *fmt, ...)
{
	FILE *f = fopen("/tmp/dvd_report.log", "a");
	if (!f) return;
	va_list ap; va_start(ap, fmt);
	vfprintf(f, fmt, ap); va_end(ap);
	fputc('\n', f);
	fclose(f);
}

// One shot, at the first EV_KEY after a core load. Everything here is a small
// bounded read -- this runs on the thread that also services the core's SD
// blocks, so it must not be a scan.
static void ir_probe(void)
{
	struct stat st;
	int have_rc = (stat("/sys/class/rc", &st) == 0);

	snprintf(g_summary, sizeof(g_summary),
		 "ir: %d entries, %d reserved, DVD_IR_REMAP=%d, kernel rc-core %s",
		 IR_TBL_N, IR_DENY_N, (int)cfg.dvd_ir_remap,
		 have_rc ? "present" : "ABSENT");
	irlog("%s", g_summary);

	if (!have_rc)
	{
		irlog("ir:   no CONFIG_RC_CORE on this kernel, so an eHome/mceusb IR");
		irlog("ir:   receiver cannot appear as an input device at all. Use a");
		irlog("ir:   receiver that presents as a USB HID KEYBOARD (Flirc, a");
		irlog("ir:   2.4GHz RF media remote, or a dock's own receiver). This is");
		irlog("ir:   a MiSTer_Linux kernel matter, not a core or Main one.");
	}

	// Name the keyboard-class devices we can actually see, capped -- on a
	// "my remote does nothing" report this line alone usually settles whether
	// the receiver enumerated at all.
	FILE *f = fopen("/proc/bus/input/devices", "r");
	if (f)
	{
		char line[256], name[160] = "";
		int shown = 0;
		while (shown < 16 && fgets(line, sizeof(line), f))
		{
			if (!strncmp(line, "N: Name=", 8)) { snprintf(name, sizeof(name), "%s", line + 8); name[strcspn(name, "\r\n")] = 0; }
			else if (!strncmp(line, "H: Handlers=", 12) && strstr(line, "kbd") && name[0])
			{
				irlog("ir:   keyboard-class input device: %s", name);
				name[0] = 0; shown++;
			}
		}
		fclose(f);
	}
}

int dvd_ir_active(void)
{
	if (!g_probed) { g_probed = 1; ir_probe(); }

	// 0 = on for the DVD core (the default -- cfg is memset to zero and there
	// is no separate defaults pass, so 0 MUST be the on value),
	// 1 = off, 2 = on for every core this Main runs.
	if (cfg.dvd_ir_remap == 1) return 0;
	if (cfg.dvd_ir_remap == 2) return 1;
	return is_dvd() ? 1 : 0;
}

uint16_t dvd_ir_target(uint16_t code, int osd_open)
{
	for (int i = 0; i < IR_TBL_N; i++)
	{
		if (ir_tbl[i].from != code) continue;
		return osd_open ? ir_tbl[i].to_osd : ir_tbl[i].to_play;
	}
	return 0;
}

const char *dvd_ir_probe_summary(void)
{
	return g_summary;
}
