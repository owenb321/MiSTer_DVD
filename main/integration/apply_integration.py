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

print("[integration] done")
