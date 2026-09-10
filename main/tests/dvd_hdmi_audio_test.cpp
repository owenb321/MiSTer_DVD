// dvd_hdmi_audio_test.cpp — the ADV7513 engage/release decision table.
//
// This module decides whether the HDMI transmitter is told to expect a compressed
// bitstream, and getting it wrong is not a subtle failure: PCM sent to a sink
// configured for non-PCM is full-scale noise. It had no coverage at all until
// LPCM/MP2 support added a third input to the decision (the core now reports what
// the wire is really carrying, because Passthru is no longer all-or-nothing).
//
// What is asserted here is the ORDERING as much as the outcome. Engage must
// configure the chip BEFORE raising the ack; release must drop the ack BEFORE
// restoring the PCM registers. Either one inverted leaves a window in which the
// sink's expectation and the core's output disagree.
//
// The module is #included rather than linked so its file statics are reachable
// and the surrounding Main can be replaced wholesale.

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

// ---------------------------------------------------------------- fake world
static int      fake_is_dvd        = 1;
static int      fake_passthru      = 0;   // OSD Audio Out = Passthru
static uint16_t fake_afmt_magic    = 0xD7D1;
static uint16_t fake_afmt          = 0;   // bit0 passthru, bit1 pcm session
static int      fake_edid_ver      = 1;
static int      fake_sad_ok        = 1;   // EDID advertises AC-3/DTS
static int      fake_gen           = 1;
static int      fake_launch_busy   = 0;
static unsigned fake_ms            = 0;

// what the module did, in order
static char     trace[64][32];
static int      n_trace            = 0;
static int      cfg_audio_state    = 0;   // last hdmi_config_set_audio() argument

// Read the module's OWN ack state when it pushes cfg[], not a copy the test keeps
// in step by hand -- a hand-kept copy records what the test believes rather than
// what the module did, and the ordering assertion is the whole point here.
int dvd_hdmi_audio_ack(void);

static void note(const char *s)
{
    if (n_trace < 64) snprintf(trace[n_trace++], 32, "%s", s);
}

struct FakeCfg { uint8_t dvd_hdmi_bitstream; uint8_t hdmi_audio_96k; };
static FakeCfg cfg;

static int  is_dvd(void)                       { return fake_is_dvd; }
static int  user_io_status_get(const char *)   { return fake_passthru; }
static void user_io_send_buttons(int)          { note(dvd_hdmi_audio_ack() ? "ack=1" : "ack=0"); }
static int  video_hdmi_config_generation(void) { return fake_gen; }
static void hdmi_config_set_audio(int bs)      { cfg_audio_state = bs;
                                                 note(bs ? "chip=nonpcm" : "chip=pcm"); }
static int  dvd_launch_ui_busy(void)           { return fake_launch_busy; }
static void InfoMessage(const char *, int, const char *) {}
static unsigned long GetTimer(unsigned long d) { return fake_ms + d; }
static int  CheckTimer(unsigned long t)        { return fake_ms >= t; }

static uint8_t fake_edid[256];
static int video_get_edid(uint8_t **buf, int *size)
{
    *buf = fake_edid; *size = (int)sizeof(fake_edid);
    return fake_edid_ver;
}

// The SPI read the module uses to ask the core what the wire is carrying.
static int spi_calls = 0;
static uint16_t spi_uio_cmd_cont(uint16_t) { spi_calls++; return fake_afmt_magic; }
static uint16_t spi_w(uint16_t)            { return fake_afmt; }
static void     DisableIO(void)            {}

#include "dvd_hdmi_audio.cpp"

// ------------------------------------------------------------------ harness
static int errors = 0;

static void check(const char *what, int got, int want)
{
    if (got != want) { printf("  FAIL %s: got %d want %d\n", what, got, want); errors++; }
    else             printf("  ok   %s = %d\n", what, got);
}

static void reset_world(void)
{
    n_trace = 0; spi_calls = 0;
    fake_ms += 1000;                 // past any pending restore timer
    dvd_hdmi_audio_tick();
    n_trace = 0;
}

// Advance far enough that the 20 ms format poll and the 50 ms restore both fire.
static void settle(void)
{
    for (int i = 0; i < 4; i++) { fake_ms += 60; dvd_hdmi_audio_tick(); }
}

static int trace_index(const char *s)
{
    for (int i = 0; i < n_trace; i++) if (!strcmp(trace[i], s)) return i;
    return -1;
}

int main(void)
{
    cfg.dvd_hdmi_bitstream = 0;      // auto
    fake_sad_ok = 1;
    // A CEA block advertising AC-3 at 48 kHz, so sink_supports_bitstream() passes.
    memset(fake_edid, 0, sizeof(fake_edid));
    fake_edid[126] = 1;              // one extension block -- without this scan_sads
                                     // returns 0 before looking at anything else
    fake_edid[128] = 0x02; fake_edid[129] = 0x03; fake_edid[130] = 0x08;
    fake_edid[132] = (1 << 5) | 3;   // Audio Data Block, 3 bytes
    fake_edid[133] = (2 << 3);       // format 2 = AC-3
    fake_edid[134] = 0x04;           // 48 kHz
    fake_edid[135] = 0x00;

    dvd_hdmi_audio_declare();

    printf("[1] Decode mode: the chip is never put into non-PCM\n");
    fake_passthru = 0; fake_afmt = 0;
    settle();
    check("acked", dvd_hdmi_audio_ack(), 0);

    printf("[2] Passthru with a bitstream track: engage, chip BEFORE ack\n");
    reset_world();
    fake_passthru = 1; fake_afmt = 0x1;         // passthru, not a PCM session
    settle();
    check("acked", dvd_hdmi_audio_ack(), 1);
    check("chip in non-PCM", cfg_audio_state, 1);
    if (trace_index("chip=nonpcm") < 0 || trace_index("ack=1") < 0 ||
        trace_index("chip=nonpcm") > trace_index("ack=1")) {
        printf("  FAIL: engage raised the ack before configuring the chip\n"); errors++;
    } else printf("  ok   engage order: chip then ack\n");

    printf("[3] Track switch to LPCM: release, ack BEFORE the PCM registers\n");
    reset_world();
    fake_afmt = 0x3;                            // passthru AND a PCM session
    settle();
    check("acked", dvd_hdmi_audio_ack(), 0);
    check("chip back in PCM", cfg_audio_state, 0);
    if (trace_index("ack=0") < 0 || trace_index("chip=pcm") < 0 ||
        trace_index("ack=0") > trace_index("chip=pcm")) {
        printf("  FAIL: release restored PCM registers before dropping the ack\n");
        errors++;
    } else printf("  ok   release order: ack then chip\n");

    printf("[4] Back to a bitstream track: re-engage\n");
    reset_world();
    fake_afmt = 0x1;
    settle();
    check("acked", dvd_hdmi_audio_ack(), 1);

    printf("[5] A core that does not answer 0x7B behaves as before\n");
    reset_world();
    fake_afmt_magic = 0x0000;                   // older core, no CMD_AF
    fake_afmt = 0x3;                            // ...would have said PCM
    settle();
    check("acked (unchanged behaviour)", dvd_hdmi_audio_ack(), 1);
    fake_afmt_magic = 0xD7D1;

    printf("[6] EDID refusal still wins over everything\n");
    reset_world();
    fake_edid[133] = (7 << 3); fake_edid[134] = 0x00;   // DTS, but no 48 kHz bit
    fake_edid_ver++;
    fake_afmt = 0x1;
    settle();
    check("acked", dvd_hdmi_audio_ack(), 0);

    printf("[7] the format poll is rate-limited, not run every tick\n");
    reset_world();
    spi_calls = 0;
    for (int i = 0; i < 50; i++) dvd_hdmi_audio_tick();   // same millisecond
    int burst = spi_calls;
    fake_ms += 100;                                       // ...now let time pass
    dvd_hdmi_audio_tick();
    int after = spi_calls - burst;
    printf("  ok   %d read(s) across 50 same-ms ticks, %d after 100 ms\n", burst, after);
    if (burst > 2) {
        printf("  FAIL: polled %d times without the clock moving\n", burst); errors++; }
    // ...and it must still poll at all, or [7] would pass by doing nothing.
    if (after < 1) {
        printf("  FAIL: no SPI read after the interval elapsed\n"); errors++; }

    if (errors) { printf("dvd_hdmi_audio_test: FAILURES\n"); return 1; }
    printf("dvd_hdmi_audio_test: ALL GREEN\n");
    return 0;
}
