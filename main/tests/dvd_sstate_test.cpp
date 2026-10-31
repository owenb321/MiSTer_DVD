// dvd_sstate_test.cpp -- the OSD's save states in the Main (support/dvd/dvd_sstate.cpp
// over dvd_vmsnap.cpp; docs/nav_engine.md §11).
//
// WHAT THIS PINS
//   [1]  a disc's identity is the hash of VIDEO_TS.IFO's first sector, named by its
//        provider field -- and a REBUILT rip (another volume descriptor, another
//        layout) gets the same identity; a relative mount path is resolved
//   [2]  an image without VIDEO_TS.IFO gets no identity, so no slots
//   [3]  FNV-1a 64 is the published one (the offset basis was one digit short once)
//   [4]  the first word read is a BASELINE: counters already non-zero do nothing
//   [5]  a Save press asks for a snapshot, waits while the core is busy, then writes
//        savestates/DVD/<id>_<slot+1>.ss with the header the format names
//   [6]  a Load press sends that file back as a LOAD (fmt, words, sum, the landing time
//        and RBN); a pending verdict is not a result, applied says "Loaded slot N"
//   [7]  an empty slot says so and sends nothing
//   [8]  another disc's file, renamed onto this one, is refused and sends nothing
//   [9]  a damaged file (a flipped word, a truncation) is refused and sends nothing
//   [10] Disc Menus off: neither a save nor a load is attempted, and the core's own
//        refusal (verdict 7) says the same thing
//   [11] the core's verdicts are named: format -> another version of the core, Disc
//        Menus off as it landed (7), a checksum the transfer broke (5)
//   [12] a snapshot that never comes ends in a message at 3 s, not a hang
//   [13] nothing happens while an MGL launch is running; the press is served after
//
// The modules are #included, so this exercises the real code. The core is a model of
// dvd/vm_snap.sv's 0x7D protocol (its header comment), scripted per arm.

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>

static char log_path[64];
#define DVD_SSTATE_LOG log_path
static unsigned fake_now = 1000;
#define DVD_SSTATE_NOW_MS() fake_now

// ---------------------------------------------------------------- the fake core
static int      core_present = 1;
static uint16_t core_seq = 4, core_fmt = 0x3f84, core_w2_req = 0;   // w2 bits 13:7 (slot 13:11, load_n 10:9, save_n 8:7)
static int      core_vm_en = 1;
static int      core_busy = 0, core_busy_for = 0;      // fetches answered busy
static int      core_len = 0;
static uint16_t core_words[128];
static uint16_t core_hdr[19];                          // words 4..18 as the core reports them
static int      core_verdict = 0, core_verdict_override = -1;
static int      core_pending_for = 0;                  // verdict polls still answered pending
// the transaction
static int      tx_k = -1;                             // strobe index, -1 = not 0x7D
static uint16_t tx_ctl;
static uint16_t tx_in[300];
static int      tx_n = 0;
static int      n_asks = 0, n_loads = 0;
// the last LOAD as the core received it
static uint16_t ld_fmt, ld_len, ld_sum, ld_tm, ld_rbnh, ld_rbnl, ld_w[128];
static int      ld_n;

static uint16_t word2(void)
{
	return (uint16_t)((core_busy ? 0x8000 : 0) | (core_vm_en ? 0x4000 : 0) |
	                  (core_w2_req & 0x3F80) | (core_busy ? 0 : core_len));
}
static uint16_t spi_uio_cmd_cont(uint16_t cmd)
{
	tx_n = 0; tx_ctl = 0;
	if (cmd != 0x7D || !core_present) { tx_k = -1; return 0; }
	tx_k = 0;
	if (core_busy && core_busy_for-- <= 0) { core_busy = 0; core_seq++; core_len = 96; }
	return 0x5E03;
}
static uint16_t spi_w(uint16_t x)
{
	if (tx_k < 0) return 0;
	tx_k++;
	if (tx_n < 300) tx_in[tx_n++] = x;
	if (tx_k == 1) { tx_ctl = x; return core_seq; }
	if (tx_k == 2) return word2();
	if (tx_k == 3) return core_fmt;
	if (tx_k == 4) {
		int v = core_verdict;
		if (v == 1 && core_pending_for-- <= 0)
			v = core_verdict = (core_verdict_override >= 0 ? core_verdict_override : 2);
		return (uint16_t)(v << 13 | core_hdr[4]);
	}
	if (tx_k < 19) return core_hdr[tx_k];
	int i = tx_k - 19;
	return (!core_busy && i < core_len) ? core_words[i] : 0;
}
static void DisableIO(void)
{
	if (tx_k < 0) return;
	if (tx_ctl & 1) { n_asks++; core_busy = 1; }
	if (tx_ctl & 2) {
		n_loads++;
		ld_fmt = tx_in[1]; ld_len = tx_in[2]; ld_sum = tx_in[3]; ld_tm = tx_in[4];
		ld_rbnh = tx_in[5]; ld_rbnl = tx_in[6];
		ld_n = tx_n - 7;
		for (int i = 0; i < ld_n && i < 128; i++) ld_w[i] = tx_in[7 + i];
		uint16_t acc = (uint16_t)(ld_tm + ld_rbnh + ld_rbnl);
		for (int i = 0; i < ld_n; i++) acc += ld_w[i];
		core_verdict = !core_vm_en ? 7 : ld_fmt != core_fmt ? 3 :
		               (ld_len != 96 || ld_n != 96) ? 4 : acc != ld_sum ? 5 : 1;
	}
	tx_k = -1;
}

// ---------------------------------------------------------------- the rest of Main
static int  fake_ui_busy = 0;
static char last_info[128];
static int  n_info = 0;
static int is_dvd(void) { return 1; }
static const char *OsdCoreNameGet(void) { return "DVD dev-vmsnap 261027"; }
static void InfoMessage(const char *m, int = 0, const char * = 0)
{
	snprintf(last_info, sizeof(last_info), "%s", m ? m : ""); n_info++;
}
int dvd_launch_ui_busy(void) { return fake_ui_busy; }
static char fake_root[64];
static const char *getRootDir(void) { return fake_root; }
static char save_dir[96];
#define SAVESTATE_DIR save_dir
#define CoreName2     "DVD"
static void create_path(const char *base, const char *sub)
{
	char p[256];
	mkdir(base, 0777);
	snprintf(p, sizeof(p), "%s/%s", base, sub);
	mkdir(p, 0777);
}
struct fileTYPE { FILE *fp; };
static int FileOpenEx(fileTYPE *f, const char *name, int, char = 0, int = 1)
{ f->fp = fopen(name, "w+b"); return f->fp != NULL; }
static int FileOpen(fileTYPE *f, const char *name, char = 0)
{ f->fp = fopen(name, "rb"); return f->fp != NULL; }
static void FileClose(fileTYPE *f) { if (f->fp) fclose(f->fp); f->fp = 0; }
static int FileWriteAdv(fileTYPE *f, void *b, int n, int = 0)
{ return f->fp ? (int)fwrite(b, 1, n, f->fp) : -1; }
static int FileReadAdv(fileTYPE *f, void *b, int n, int = 0)
{ return f->fp ? (int)fread(b, 1, n, f->fp) : -1; }
static int FileExists(const char *name, int = 1)
{ FILE *fp = fopen(name, "rb"); if (!fp) return 0; fclose(fp); return 1; }
const char *dvd_phys_device(void) { return 0; }
int dvd_css_active(void) { return 0; }
int dvd_css_read(void *, uint32_t, uint32_t) { return 0; }

#include "dvd_vmsnap.cpp"
#include "dvd_sstate.cpp"

// ---------------------------------------------------------------- helpers
static int fails = 0;
static void check(int cond, const char *what)
{
	printf("  %s %s\n", cond ? "ok  " : "FAIL", what);
	if (!cond) fails++;
}

// A minimal ISO9660 image holding VIDEO_TS/VIDEO_TS.IFO. `variant` moves the
// directories and changes the volume descriptor's label, as a rebuilt rip would.
static void dirent(uint8_t *p, uint32_t lba, uint32_t size, const char *name)
{
	size_t nl = strlen(name);
	p[0] = (uint8_t)(33 + nl + ((nl & 1) ? 0 : 1));
	memcpy(p + 2, &lba, 4); memcpy(p + 10, &size, 4);
	p[32] = (uint8_t)nl; memcpy(p + 33, name, nl);
}
static void make_iso(const char *path, int variant, const char *provider, int dvd)
{
	static uint8_t img[40 * 2048];
	memset(img, 0, sizeof(img));
	uint32_t root = variant ? 25 : 20, vts = variant ? 27 : 21, ifo = variant ? 30 : 22;
	uint8_t *pvd = img + 16 * 2048;
	pvd[0] = 1; memcpy(pvd + 1, "CD001", 5);
	memcpy(pvd + 40, variant ? "CDROM" : "MY_DISC", variant ? 5 : 7);
	dirent(pvd + 156, root, 2048, "\0");
	dirent(img + root * 2048, dvd ? vts : 0, 2048, dvd ? "VIDEO_TS" : "MPEGAV");
	dirent(img + vts * 2048, ifo, 2048, "VIDEO_TS.IFO;1");
	uint8_t *mat = img + ifo * 2048;
	memcpy(mat, "DVDVIDEO-VMG", 12);
	if (provider) memcpy(mat + 64, provider, strlen(provider));
	mat[300] = 0x42;                                   // some IFO-relative content
	FILE *f = fopen(path, "wb"); fwrite(img, 1, sizeof(img), f); fclose(f);
}

static void tick(void) { fake_now += 25; dvd_sstate_tick(); }
static void press(int save, int slot)
{
	int sv = (core_w2_req >> 7) & 3, ld = (core_w2_req >> 9) & 3;
	if (save) sv = (sv + 1) & 3; else ld = (ld + 1) & 3;
	core_w2_req = (uint16_t)(slot << 11 | ld << 9 | sv << 7);
}
static void snapshot_state(void)
{
	for (int i = 0; i < 96; i++) core_words[i] = (uint16_t)(0x1000 + i * 7);
	memset(core_hdr, 0, sizeof(core_hdr));
	core_hdr[4] = 3;                                   // fresh, has video
	core_hdr[5] = 0x0001; core_hdr[6] = 0x5513;        // nv_pck_lbn
	core_hdr[13] = 0x0012; core_hdr[14] = 0x51D0;      // eltm 0:12:51 frame 10 @30
	core_hdr[15] = 0; core_hdr[16] = 0xC350;           // sptm 50000
	core_hdr[17] = 0; core_hdr[18] = 0xC350;           // stc: no lead -> 771 s
}

int main(void)
{
	char tmpl[] = "/tmp/dvd_sstate_testXXXXXX";
	char *dir = mkdtemp(tmpl);
	snprintf(fake_root, sizeof(fake_root), "%s", dir);
	snprintf(save_dir, sizeof(save_dir), "%s/savestates", dir);
	snprintf(log_path, sizeof(log_path), "%s/log", dir);
	char iso[128], rip[128], vcd[128];
	snprintf(iso, sizeof(iso), "%s/disc.iso", dir);
	snprintf(rip, sizeof(rip), "%s/rebuilt.iso", dir);
	snprintf(vcd, sizeof(vcd), "%s/vcd.iso", dir);
	make_iso(iso, 0, "ACME_VIDEO", 1);
	make_iso(rip, 1, "ACME_VIDEO", 1);
	make_iso(vcd, 0, NULL, 0);

	printf("[1] identity from VIDEO_TS.IFO\n");
	dvd_sstate_note_mount(iso);
	char id1[80]; snprintf(id1, sizeof(id1), "%s", dvd_sstate_disc_id() ? dvd_sstate_disc_id() : "");
	check(!strncmp(id1, "ACME_VIDEO-", 11) && strlen(id1) == 27, "named <provider>-<16 hex>");
	dvd_sstate_note_mount("rebuilt.iso");              // relative: under getRootDir()
	check(dvd_sstate_disc_id() && !strcmp(dvd_sstate_disc_id(), id1),
	      "a rebuilt rip (relative path) has the disc's identity");

	printf("[2] no VIDEO_TS.IFO, no slots\n");
	dvd_sstate_note_mount(vcd);
	char p[256];
	check(dvd_sstate_disc_id() == NULL && !dvd_sstate_slot_path(0, p, sizeof(p)), "a VCD-like image has no identity");

	printf("[3] FNV-1a 64\n");
	check(fnv1a64("", 0) == 0xcbf29ce484222325ULL, "offset basis");
	check(fnv1a64("a", 1) == 0xaf63dc4c8601ec8cULL, "the published vector for \"a\"");

	dvd_sstate_note_mount(iso);
	snapshot_state();

	printf("[4] the first word is a baseline\n");
	core_w2_req = 2 << 11 | 1 << 9 | 1 << 7;          // slot 2, load_n 1, save_n 1
	tick(); tick(); tick();
	check(n_asks == 0 && n_loads == 0 && n_info == 0, "counters already set do nothing");

	printf("[5] save\n");
	press(1, 2);
	core_busy_for = 3;
	tick();
	check(n_asks == 1, "a Save press asks for one snapshot");
	tick();
	char path[256];
	snprintf(path, sizeof(path), "%s/DVD/%s_3.ss", save_dir, id1);
	check(!FileExists(path), "no file while the core is busy");
	for (int i = 0; i < 6; i++) tick();
	check(!strcmp(last_info, "Saved to slot 3"), "says Saved to slot 3");
	uint8_t fb[400]; int fl = 0;
	FILE *f = fopen(path, "rb");
	if (f) { fl = (int)fread(fb, 1, sizeof(fb), f); fclose(f); }
	check(fl == 64 + 192, "the file is the 64-byte header + 96 words");
	check(!memcmp(fb, "DVS2", 4) && get16(fb + 4) == 1 && get16(fb + 6) == 0x3f84 && get16(fb + 8) == 96,
	      "magic, version, fmt, word count");
	check((int32_t)get32(fb + 20) == 771 && get32(fb + 24) == 0x00015513,
	      "the landing time (771 s) and the fallback sector");
	check(get16(fb + 64) == 0x1000 && get16(fb + 64 + 2 * 95) == (uint16_t)(0x1000 + 95 * 7), "the words");
	check(!strncmp((char *)fb + 32, "dev-vmsnap 261027", 17), "the core version, for tools");

	printf("[6] load\n");
	int n0 = n_info;
	press(0, 2);
	core_pending_for = 2;
	tick();
	check(n_loads == 1, "a Load press sends one LOAD");
	uint16_t sum = (uint16_t)(ld_tm + ld_rbnh + ld_rbnl);
	for (int i = 0; i < ld_n; i++) sum += ld_w[i];
	check(ld_fmt == 0x3f84 && ld_len == 96 && ld_n == 96 && ld_sum == sum, "fmt, length and checksum");
	check(ld_tm == 771 && ld_rbnh == 0x0001 && ld_rbnl == 0x5513, "the landing time and RBN");
	check(ld_w[0] == 0x1000 && ld_w[95] == (uint16_t)(0x1000 + 95 * 7), "the saved words");
	tick();
	check(n_info == n0, "pending: nothing said yet");
	for (int i = 0; i < 4; i++) tick();
	check(!strcmp(last_info, "Loaded slot 3"), "applied: says Loaded slot 3");

	printf("[7] empty slot\n");
	n0 = n_loads;
	press(0, 1); tick();
	check(!strcmp(last_info, "Slot 2 is empty") && n_loads == n0, "Slot 2 is empty, nothing sent");

	printf("[8] another disc's file\n");
	char other[256];
	snprintf(other, sizeof(other), "%s/DVD/%s_4.ss", save_dir, id1);
	{   // the same file, its disc field another disc's
		uint8_t b2[400]; memcpy(b2, fb, fl); b2[12] ^= 0x55;
		FILE *g = fopen(other, "wb"); fwrite(b2, 1, fl, g); fclose(g);
	}
	press(0, 3); tick();
	check(!strcmp(last_info, "That save is from a different disc") && n_loads == n0, "refused, nothing sent");

	printf("[9] damaged files\n");
	{
		uint8_t b2[400]; memcpy(b2, fb, fl); b2[64 + 20] ^= 1;
		FILE *g = fopen(other, "wb"); fwrite(b2, 1, fl, g); fclose(g);
	}
	press(0, 3); tick();
	check(!strcmp(last_info, "That save file is damaged") && n_loads == n0, "a flipped word: refused");
	{
		FILE *g = fopen(other, "wb"); fwrite(fb, 1, fl - 2, g); fclose(g);
	}
	snprintf(last_info, sizeof(last_info), "-");
	press(0, 3); tick();
	check(!strcmp(last_info, "That save file is damaged") && n_loads == n0, "truncated: refused");

	printf("[10] Disc Menus off\n");
	core_vm_en = 0;
	int a0 = n_asks;
	snprintf(last_info, sizeof(last_info), "-");
	press(1, 0); tick();
	check(!strcmp(last_info, "Save states need Disc Menus on") && n_asks == a0, "a save is not attempted");
	snprintf(last_info, sizeof(last_info), "-");
	press(0, 2); tick();
	check(!strcmp(last_info, "Save states need Disc Menus on") && n_loads == n0, "a load is not sent");
	core_vm_en = 1;

	printf("[11] the core's verdicts\n");
	core_fmt = 0x1111;                                 // a core built from another layout
	press(0, 2); tick(); tick(); tick();
	check(!strcmp(last_info, "That save is from another version of the core"), "format -> another version");
	core_fmt = 0x3f84;
	core_verdict_override = 7;                         // Disc Menus turned off as it landed
	press(0, 2); tick(); tick(); tick();
	check(!strcmp(last_info, "Save states need Disc Menus on"), "verdict 7 -> Disc Menus");
	core_verdict_override = 5;
	press(0, 2); tick(); tick(); tick();
	check(!strcmp(last_info, "That save file is damaged"), "checksum -> damaged");
	core_verdict_override = -1;

	printf("[12] a snapshot that never comes\n");
	core_busy_for = 1000000;
	press(1, 0);
	for (int i = 0; i < 100; i++) tick();              // 2.5 s
	check(strcmp(last_info, "Could not save: the player stayed busy. Try again") != 0, "still waiting at 2.5 s");
	for (int i = 0; i < 40; i++) tick();
	check(!strcmp(last_info, "Could not save: the player stayed busy. Try again"), "gives up at 3 s and says so");
	core_busy = 0; core_busy_for = 0;

	printf("[13] an MGL launch defers it\n");
	fake_ui_busy = 1;
	a0 = n_asks;
	press(1, 1); tick(); tick();
	check(n_asks == a0, "nothing while the launch runs");
	fake_ui_busy = 0;
	core_busy_for = 0;
	for (int i = 0; i < 4; i++) tick();
	check(n_asks == a0 + 1 && !strcmp(last_info, "Saved to slot 2"), "served once it settles");

	printf("[14] eight slots: slot 8 is _8.ss, saved and loaded\n");
	core_busy_for = 0;
	press(1, 7);
	for (int i = 0; i < 6; i++) tick();
	check(!strcmp(last_info, "Saved to slot 8"), "says Saved to slot 8");
	snprintf(path, sizeof(path), "%s/DVD/%s_8.ss", save_dir, id1);
	check(FileExists(path), "the slot 8 file is _8.ss");
	int l8 = n_loads;
	press(0, 7);
	for (int i = 0; i < 10; i++) tick();
	check(n_loads == l8 + 1, "a Load of slot 8 sends it");

	printf(fails ? "dvd_sstate_test: %d FAILED\n" : "dvd_sstate_test: ALL GREEN\n", fails);
	return fails ? 1 : 0;
}
