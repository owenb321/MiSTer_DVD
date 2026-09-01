#!/usr/bin/env python3
# apply_integration.py — apply the MiSTer_DVDcss overlay to a stock Main_MiSTer tree.
#
# Idempotent and anchor-based: each edit is skipped if already present and errors
# loudly (naming the INTEGRATION.md step) if its anchor is missing, so a stock
# version bump that moves code fails visibly instead of silently mis-patching.
#
# Usage: apply_integration.py <stock_main_dir>

import sys, os, re

if len(sys.argv) != 2:
    sys.exit("usage: apply_integration.py <stock_main_dir>")
ROOT = sys.argv[1]

def read(p):
    with open(p, "r", encoding="utf-8", errors="surrogateescape") as f:
        return f.read()

def write(p, s):
    with open(p, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(s)

def indent_of(line):
    return line[:len(line) - len(line.lstrip())]

def fail(step, why):
    sys.exit(f"[integration] STEP {step} FAILED: {why}\n"
             f"  -> apply this edit by hand per main/integration/INTEGRATION.md, "
             f"then re-run without this step.")

def insert_after(text, anchor, block, step, marker):
    if marker in text:
        print(f"[integration] step {step}: already applied, skipping")
        return text
    i = text.find(anchor)
    if i < 0:
        fail(step, f"anchor not found: {anchor!r}")
    eol = text.find("\n", i)
    if eol < 0:
        fail(step, "anchor at EOF")
    return text[:eol + 1] + block + text[eol + 1:]

def insert_before(text, anchor, block, step, marker):
    if marker in text:
        print(f"[integration] step {step}: already applied, skipping")
        return text
    i = text.find(anchor)
    if i < 0:
        fail(step, f"anchor not found: {anchor!r}")
    bol = text.rfind("\n", 0, i) + 1
    ind = indent_of(text[bol:])
    body = "".join(ind + l + "\n" if l else "\n" for l in block.strip("\n").split("\n"))
    return text[:bol] + body + text[bol:]

# ---------------------------------------------------------------- user_io.cpp
uio_path = os.path.join(ROOT, "user_io.cpp")
if not os.path.exists(uio_path):
    fail(0, f"{uio_path} not found — is this a Main_MiSTer tree?")
u = read(uio_path)

# 1. includes
u = insert_after(u, '#include "ide_cdrom.h"',
    '#include "support/dvd/dvd_css.h"\n#include "support/dvd/dvd_phys.h"\n',
    1, 'support/dvd/dvd_css.h')

# 2. slot type
u = insert_after(u, '#define  SD_TYPE_A2 2',
    '#define  SD_TYPE_DVDCSS 4   // physical DVD-Video, CSS-decrypted via libdvdcss\n',
    2, 'SD_TYPE_DVDCSS')

# 3. is_dvd()
u = insert_after(u, 'return (is_3do_type == 1);',
    None if False else '', 3, 'is_dvd()')  # placeholder to keep marker check simple
if 'is_dvd()' not in u:
    anchor = 'return (is_3do_type == 1);'
    i = u.find(anchor)
    if i < 0: fail(3, "is_3do() anchor not found")
    close = u.find('\n}', i)
    if close < 0: fail(3, "end of is_3do() not found")
    fn = ('\n\nstatic int is_dvd_type = 0;\n'
          'char is_dvd()\n{\n'
          '\tif (!is_dvd_type) is_dvd_type = strcasecmp(orig_name, "DVD") ? 2 : 1;\n'
          '\treturn (is_dvd_type == 1);\n}')
    u = u[:close + 2] + fn + u[close + 2:]
else:
    print("[integration] step 3: already applied, skipping")

# 4. reset in user_io_read_core_name(). Anchor on the TAB-indented reset line so
# we land inside the function, not on the global 'static int is_uneon_type = 0;'
# declaration (which also contains 'is_uneon_type = 0;'). Unique tag marker too.
u = insert_after(u, '\tis_uneon_type = 0;',
    '\tis_dvd_type = 0;   // dvdcss:reset\n', 4, '// dvdcss:reset')

# 5. close CSS handle on remount
u = insert_after(u, 'sd_image_cangrow[index] = (pre != 0);',
    '\tif (sd_type[index] == SD_TYPE_DVDCSS) dvd_css_close();\n',
    5, 'if (sd_type[index] == SD_TYPE_DVDCSS) dvd_css_close();')

# 6. mount dispatch — turn the first x2trd branch into our branch + else-if
if 'DVD_PHYS_SENTINEL' not in u:
    m = re.search(r'^([ \t]*)if \(x2trd_ext_supp\(name\)\)', u, re.M)
    if not m: fail(6, "x2trd_ext_supp mount branch not found")
    ind = m.group(1)
    branch = (
        f'{ind}if (!strcmp(name, DVD_PHYS_SENTINEL) && is_dvd())\n'
        f'{ind}{{\n'
        f'{ind}\t// Physical DVD-Video: libdvdcss serves CSS-decrypted 2048-byte\n'
        f'{ind}\t// sectors (drive-backed, read-only). Absent libdvdcss falls back\n'
        f'{ind}\t// to raw reads so unencrypted discs still play.\n'
        f'{ind}\tif (dvd_css_open())\n'
        f'{ind}\t{{\n'
        f'{ind}\t\tsd_type[index] = SD_TYPE_DVDCSS;\n'
        f'{ind}\t\tsd_image[index].size = dvd_css_size();\n'
        f'{ind}\t\twritable = 0;\n'
        f'{ind}\t\tret = 1;\n'
        f'{ind}\t}}\n'
        f'{ind}}}\n'
        f'{ind}else if (is_dvd() && len > 4 && !strcasecmp(name + len - 4, ".iso")\n'
        f'{ind}         && dvd_css_open_image(name))\n'
        f'{ind}{{\n'
        f'{ind}\t// CSS-encrypted ISO image (no drive needed): serve it CSS-decrypted\n'
        f'{ind}\t// too. dvd_css_open_image() claims the mount only when the image is\n'
        f'{ind}\t// actually scrambled; a decrypted ISO returns 0 and takes the normal\n'
        f'{ind}\t// direct-file path below.\n'
        f'{ind}\tsd_type[index] = SD_TYPE_DVDCSS;\n'
        f'{ind}\tsd_image[index].size = dvd_css_size();\n'
        f'{ind}\twritable = 0;\n'
        f'{ind}\tret = 1;\n'
        f'{ind}}}\n'
        f'{ind}else if (x2trd_ext_supp(name))'
    )
    u = u[:m.start()] + branch + u[m.end():]
else:
    print("[integration] step 6: already applied, skipping")

# 7. poll ticks
u = insert_after(u, 'add_frame_callback(screenshot_cb);',
    '\n\tdvd_css_tick();    // deferred "install libdvdcss" popup once launch settles\n'
    '\tdvd_phys_tick();   // auto-mount / unmount the optical drive\n',
    7, 'dvd_phys_tick();')

# 8. read source A (the "done = 1" site). Unique tag marker — SD_TYPE_DVDCSS and
# the css_read call also appear in other steps.
u = insert_before(u, 'else if (sd_image[disk].size)',
    'else if (sd_type[disk] == SD_TYPE_DVDCSS)   // dvdcss:readA\n'
    '{\n'
    '\tdiskled_on();\n'
    '\tif (dvd_css_read(buffer[disk], lba, buf_n) > 0)\n'
    '\t{\n'
    '\t\tdone = 1;\n'
    '\t\tbuffer_lba[disk] = lba;\n'
    '\t}\n'
    '}\n',
    8, '// dvdcss:readA')

# 9. read source B (the FileSeek fallback site). Unique tag marker — memset(buffer..)
# pre-exists in stock, so keying on it would wrongly skip this insert.
u = insert_before(u, 'else if (FileSeek(&sd_image[disk], lba * blksz, SEEK_SET)',
    'else if (sd_type[disk] == SD_TYPE_DVDCSS)   // dvdcss:readB\n'
    '{\n'
    '\tif (dvd_css_read(buffer[disk], lba, buf_n) > 0)\n'
    '\t{\n'
    '\t\tbuffer_lba[disk] = lba;\n'
    '\t}\n'
    '\telse\n'
    '\t{\n'
    '\t\tmemset(buffer[disk], 0, sizeof(buffer[disk]));\n'
    '\t\tbuffer_lba[disk] = -1;\n'
    '\t}\n'
    '}\n',
    9, '// dvdcss:readB')

write(uio_path, u)
print("[integration] user_io.cpp patched")

# ---------------------------------------------------------------- user_io.h
h_path = os.path.join(ROOT, "user_io.h")
h = read(h_path)
h = insert_after(h, 'char is_3do();', 'char is_dvd();\n', 10, 'char is_dvd();')
write(h_path, h)
print("[integration] user_io.h patched")

# ---------------------------------------------------------------- Makefile
mk_path = os.path.join(ROOT, "Makefile")
mk = read(mk_path)
if ' -ldl ' not in mk and '-ldl' not in mk:
    mk2 = re.sub(r'(^LFLAGS\s*=\s*-lc -lstdc\+\+ -lm -lrt)', r'\1 -ldl', mk, count=1, flags=re.M)
    if mk2 == mk:
        fail(11, "LFLAGS line not found for -ldl insert")
    write(mk_path, mk2)
    print("[integration] Makefile: added -ldl")
else:
    print("[integration] Makefile: -ldl already present")

# =============================================================================
# HDMI IEC 61937 bitstream (steps 12-21). See INTEGRATION.md.
# The overlay's FIRST edits to video.cpp / video.h / cfg.* — re-verify these
# specifically on a MAIN_MISTER_REF bump.
# =============================================================================

# ---------------------------------------------------------------- user_io.cpp
u = read(uio_path)

# 12. include
u = insert_after(u, '#include "support/dvd/dvd_phys.h"',
    '#include "support/dvd/dvd_hdmi_audio.h"\n',
    12, 'support/dvd/dvd_hdmi_audio.h')

# 13. poll tick (reuses the step-7 tick site)
u = insert_after(u, 'dvd_phys_tick();   // auto-mount / unmount the optical drive',
    '\tdvd_hdmi_audio_tick();  // ADV7513 non-PCM mode + the cfg[14] ack\n',
    13, 'dvd_hdmi_audio_tick();')

# 14. the ack into the cfg[] word sent to the core
u = insert_after(u, 'if (vga_fb) map |= CONF_VGA_FB;',
    '\tif (dvd_hdmi_audio_ack()) map |= CONF_DVD_HDMI_BS;   // dvd:hdmibs\n',
    14, '// dvd:hdmibs')

# 15. capability declaration off the OX arm. The core marks Audio Out as OX6 so
# Main learns the build HAS the HDMI tap; a core without it never declares, and
# we never reconfigure the chip for a core that cannot drive it.
u = insert_after(u, 'printf("found OX option: %s: %d\\n", p, x);',
    '\t\t\t\tif (is_dvd() && p[2] == \'6\') dvd_hdmi_audio_declare();\n',
    15, 'dvd_hdmi_audio_declare()')

write(uio_path, u)
print("[integration] user_io.cpp patched (hdmi bitstream)")

# ---------------------------------------------------------------- user_io.h
h = read(h_path)
# 16. cfg[] bit 14. Stock defines up to CONF_DIRECT_VIDEO2 (bit 13); 14 and 15
# are the only free bits, so this is the last cheap one - if a future stock
# version claims it, this step must move rather than silently collide.
h = insert_after(h, '#define CONF_DIRECT_VIDEO2      0b0010000000000000',
    '#define CONF_DVD_HDMI_BS        0b0100000000000000\n',
    16, 'CONF_DVD_HDMI_BS')
write(h_path, h)
print("[integration] user_io.h patched (hdmi bitstream)")

# ---------------------------------------------------------------- video.h
vh_path = os.path.join(ROOT, "video.h")
vh = read(vh_path)
# 17. exports
vh = insert_after(vh, 'int   video_get_edid(uint8_t **buf, int *size);',
    'void  hdmi_config_set_audio(int bitstream);   // dvd:hdmibs\n'
    'int   video_hdmi_config_generation(void);\n',
    17, 'hdmi_config_set_audio')
write(vh_path, vh)
print("[integration] video.h patched")

# ---------------------------------------------------------------- video.cpp
vc_path = os.path.join(ROOT, "video.cpp")
vc = read(vc_path)

# 18. generation counter storage, with the other file statics
vc = insert_after(vc, 'static int edid_version = 0;',
    'static int hdmi_cfg_generation = 0;   // dvd:hdmibs\n',
    18, 'hdmi_cfg_generation')

# 19. bump it whenever the full init rewrites the audio block. Anchored on the
# write loop's header, NOT on "hdmi_config_set_csc();" - that string also occurs
# later in the file and insert_after takes the FIRST match, which would land the
# bump in the wrong function.
vc = insert_before(vc, 'for (uint i = 0; i < sizeof(init_data); i += 2)',
    'hdmi_cfg_generation++;   // dvd:hdmibs - audio block is about to revert to PCM\n',
    19, 'hdmi_cfg_generation++')

# 20. the audio-only register writer
vc = insert_before(vc, 'static void hdmi_config_set_hdr()', r"""
// dvd:hdmibs - switch the ADV7513's audio input between PCM I2S and IEC958
// direct (IEC 61937 bitstream), writing ONLY the audio registers.
//
// Deliberately not a hdmi_config_init() call: that rewrites ~50 registers plus
// the CSC and would blank the picture on every Audio Out toggle.
//
// IEC958-direct (0x0C[1:0]=3) is how the mainline Linux adv7511 driver carries
// IEC958 subframe data, and it is the mode where channel status travels inside
// the subframe - so the non-PCM flag stays dynamic exactly as it is on S/PDIF,
// instead of being pinned high for the whole session.
void hdmi_config_set_audio(int bitstream)
{
	if (hdmi_main_fd < 0) return;

	// dvd_hdmi_bs_tweak: an ini-selectable sweep of the values that had to be
	// ASSUMED, so trying a candidate costs a core reload rather than a 30-minute
	// Quartus fit. HW round 2 proved optical carries both DD and DTS on the SAME
	// build, so the 61937 word stream is right and only the chip's reading of it
	// is in question.
	//   bit 0  word length 24-bit instead of 16-bit (0x14). If the chip counts the
	//          sample up from timeslot 4 rather than 12, "16-bit" makes it read
	//          our zero padding instead of the payload.
	//   bit 1  invert the I2S bit clock (0x0B[6]). Wrong latching edge shifts
	//          every bit.
	// Route: plain 16-bit standard I2S with channel status from the register map.
	// 0x0C[6]=1 selects the register source; 0x12[7] is the non-PCM bit ("audio
	// sample word", Programming Guide Table 84). HW-CONFIRMED 2026-08-31.

	uint8_t audio_data[] = {
		0x0A, 0x00,                              // [6:4] audio select = I2S
		// [2] I2S0 en; [1:0] 3 = IEC958 direct / 0 = standard I2S;
		// [6] = 1 takes channel status from the register map (route i)
		0x0C, (uint8_t)(bitstream ? 0x44 : 0x04),
		// Channel status byte 0 via Table 84: [7] audio sample word
		// (1 = NOT linear PCM), [6] consumer use = 0, [5] copyright
		// (1 = not protected). Only consulted when 0x0C[6] = 1.
		0x12, (uint8_t)(bitstream ? 0xA0 : 0x20),
		0x14, 0x02,                              // audio word length = 16 bit
		0x15, (uint8_t)((cfg.hdmi_audio_96k ? 0x80 : 0) | 0x20),   // 48 kHz
		0x73, 0x01,                              // Channel Count = 1 (stereo).
		                                         // NOT 0: Programming Guide 4.4.1.1 -
		                                         // "If I2S0 only is needed, setting the
		                                         // Channel Count register (0x73[2:0]) and
		                                         // I2S enable (0x0C[2]) to 1 will select
		                                         // this". CC also drives the Audio Sample
		                                         // Packet layout bit and sample_present.spX
		                                         // (Figure 23), so 0 mis-frames the packet.
		                                         // A 61937 burst is a 2-channel carrier, so
		                                         // stereo is right for bitstream too.
	};

	for (uint i = 0; i < sizeof(audio_data); i += 2)
	{
		int res = i2c_smbus_write_byte_data(hdmi_main_fd, audio_data[i], audio_data[i + 1]);
		if (res < 0) printf("i2c: audio write error (%02X %02X): %d\n",
		                    audio_data[i], audio_data[i + 1], res);
	}
	// Read back what the chip DETECTED, rather than assuming it agrees with us.
	// 0x42[3]: SCLK periods per LRCLK period - 0 = 32-bit mode, 1 = 64-bit mode.
	// AES3-direct carries 32 bits per channel and so REQUIRES 64-bit mode; if
	// this reads 0 the chip is only taking half of every subframe.
	const char *mode = bitstream ? "std-I2S+CSreg" : "PCM I2S";
	printf("ADV7513: audio input set to %s\n", mode);
	FILE *lf = fopen("/tmp/dvd_hdmi_audio.log", "a");
	if (lf) { fprintf(lf, "adv7513: %s\n", mode); fclose(lf); }
}

int video_hdmi_config_generation(void)
{
	return hdmi_cfg_generation;
}

""", 20, 'hdmi_config_set_audio')

write(vc_path, vc)
print("[integration] video.cpp patched")

# ---------------------------------------------------------------- cfg.h / cfg.cpp
cfgh_path = os.path.join(ROOT, "cfg.h")
ch = read(cfgh_path)
# 21. ini field. 0 = auto (EDID-gated), 1 = off, 2 = force.
ch = insert_after(ch, '\tuint8_t hdmi_audio_96k;',
    '\tuint8_t dvd_hdmi_bitstream;   // dvd:hdmibs 0=auto 1=off 2=force\n',
    21, 'dvd_hdmi_bitstream')
write(cfgh_path, ch)

cfgc_path = os.path.join(ROOT, "cfg.cpp")
cc = read(cfgc_path)
cc = insert_after(cc, '{ "HDMI_AUDIO_96K", (void*)(&(cfg.hdmi_audio_96k)), UINT8, 0, 1 },',
    '\t{ "DVD_HDMI_BITSTREAM", (void*)(&(cfg.dvd_hdmi_bitstream)), UINT8, 0, 2 },\n',
    21, 'DVD_HDMI_BITSTREAM')
write(cfgc_path, cc)
print("[integration] cfg.h/cfg.cpp patched")

# =============================================================================
# On-player support bundle (steps 22-25). See INTEGRATION.md and
# MiSTer_DVD/docs/support_bundle_hps.md.
# =============================================================================

u = read(uio_path)

# 22. include
u = insert_after(u, '#include "support/dvd/dvd_hdmi_audio.h"',
    '#include "support/dvd/dvd_report.h"\n',
    22, 'support/dvd/dvd_report.h')

# 23. poll tick (reuses the step-7 tick site)
u = insert_after(u, 'dvd_hdmi_audio_tick();  // ADV7513 non-PCM mode + the cfg[14] ack',
    '\tdvd_report_tick();      // support-bundle chord: fire + reap\n',
    23, 'dvd_report_tick();')

# 24. observe the gamepad for the chord. Placed at the TOP of the function, and
# it only reads `map` - the map is passed to the core unchanged, so a bug here
# cannot stop a button working.
# NOTE the anchor is the function's FIRST BODY LINE, not its signature.
# insert_after() splits on the first newline AFTER the anchor, so a two-line
# 'signature\n{' anchor lands the call BETWEEN the signature and its brace --
# which compiles as "expected initializer before 'dvd_report_joy'".
u = insert_after(u, '\tuint8_t joy = (joystick>1 || !joyswap) ? joystick : joystick ^ 1;',
    '\tdvd_report_joy(map);   // dvd:report — observe only, never modifies map\n',
    24, 'dvd_report_joy(map)')

# 25. expose the last-served sector. buffer_lba[] is file-static, and it is the
# one thing the on-player bundle knows that a reporter cannot state from memory:
# where playback actually was when the problem was seen.
u = insert_after(u,
    '\t\t\t\t\t\t\t\t   ULLONG_MAX,ULLONG_MAX,ULLONG_MAX,ULLONG_MAX };',
    '\nuint64_t user_io_last_lba(int index)   // dvd:report\n'
    '{\n'
    '\tif (index < 0 || index >= 16) return (uint64_t)-1;\n'
    '\treturn buffer_lba[index];\n'
    '}\n',
    25, 'user_io_last_lba')

write(uio_path, u)
print("[integration] user_io.cpp patched (support bundle)")

h = read(h_path)
h = insert_after(h, 'char is_dvd();',
    'uint64_t user_io_last_lba(int index);   // dvd:report\n',
    25, 'user_io_last_lba')
write(h_path, h)
print("[integration] user_io.h patched (support bundle)")

print("[integration] done")
