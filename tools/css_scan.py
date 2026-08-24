#!/usr/bin/env python3
"""css_scan.py -- vet a DVD-Video ISO (or a directory of them) for CSS-scrambled packs.

Why: the core never sees CSS keys (decryption is a PC-side rip step), so a raw or
partially-decrypted rip green-screens with audio static. Since PR #160 the core
DETECTS this on-board (persistent `CSS ENCRYPTED` HUD popup + audio mute), but the
right place to catch a bad rip is offline, before it ever reaches the SD card --
especially now that the dvd_ripper project mass-produces ISOs.

Detection mirrors dvd/ps_demux.sv S_PES_HDR_FLAGS1 exactly: a pack whose first PES
optional-header flags byte has the '10' marker bits AND PES_scrambling_control
(bits [5:4]) != 0 is scrambled. Layout per sampled 2048-byte sector:
    [0..3]   00 00 01 BA        pack start (DVD sectors are pack-aligned)
    [4..12]  9 fixed pack-header bytes
    [13]     low 3 bits = stuffing count S
    [14+S..] 00 00 01 <sid>     first PES packet
    PES+6    flags byte 1 (only for stream ids that carry an MPEG-2 optional
             header: video E0-EF, MPEG audio C0-DF, private_stream_1 BD).
private_stream_2 (BF, NAV), padding (BE) and system headers (BB) have no
optional header and are skipped, exactly as the RTL skips them.

Motivating case: FAIRYTOPIA.iso -- ~19% of packs scrambled (a raw rip); a clean
rip (e.g. MEN_IN_BLACK.iso) reports 0.

Usage:
    tools/css_scan.py <iso-or-dir> [...]     # sampled scan (~20k packs/disc, seconds)
    tools/css_scan.py --full <iso>           # every sector (minutes on 8 GB)

Exit status: 0 = all scanned images clean, 1 = any scrambling found (scriptable
as a ripper post-check).
"""
import os
import struct
import sys

SEC = 2048
TARGET_SAMPLES = 20000          # sampled mode: aim for this many sectors per image
# stream ids that carry the MPEG-2 PES optional header (=> have a flags byte)
CHECKABLE = set(range(0xE0, 0xF0)) | set(range(0xC0, 0xE0)) | {0xBD}


def scan(path, full=False):
    size = os.path.getsize(path)
    nsec = size // SEC
    stride = 1 if full else max(1, nsec // TARGET_SAMPLES)
    packs = checked = scrambled = 0
    first_hits = []
    with open(path, 'rb') as f:
        for s in range(0, nsec, stride):
            f.seek(s * SEC)
            b = f.read(SEC)
            if len(b) < 64 or b[0:4] != b'\x00\x00\x01\xba':
                continue                      # not a pack (IFO/fs/BUP sector)
            packs += 1
            stuff = b[13] & 0x07
            p = 14 + stuff
            if p + 7 > SEC or b[p:p+3] != b'\x00\x00\x01':
                continue
            sid = b[p+3]
            if sid not in CHECKABLE:
                continue                      # NAV/padding/system: no flags byte
            flags = b[p+6]
            checked += 1
            if (flags & 0xC0) == 0x80 and (flags & 0x30) != 0:
                scrambled += 1
                if len(first_hits) < 3:
                    first_hits.append((s, sid))
    return nsec, stride, packs, checked, scrambled, first_hits


def main(argv):
    full = '--full' in argv
    args = [a for a in argv if a != '--full']
    paths = []
    for a in args:
        if os.path.isdir(a):
            paths += sorted(os.path.join(a, n) for n in os.listdir(a)
                            if n.lower().endswith(('.iso', '.img')))
        else:
            paths.append(a)
    if not paths:
        print(__doc__)
        return 2
    any_bad = False
    for p in paths:
        nsec, stride, packs, checked, scrambled, hits = scan(p, full)
        pct = (100.0 * scrambled / checked) if checked else 0.0
        verdict = "CLEAN" if scrambled == 0 else "ENCRYPTED (%.1f%% of checked packs)" % pct
        if scrambled:
            any_bad = True
        print("%-52s %s" % (os.path.basename(p), verdict))
        print("    sectors=%d stride=%d packs=%d pes_checked=%d scrambled=%d"
              % (nsec, stride, packs, checked, scrambled))
        for s, sid in hits:
            print("    first hit: sector %d stream_id 0x%02X" % (s, sid))
        if checked == 0 and packs == 0:
            print("    ?? no MPEG packs found -- not a DVD-Video image?")
    return 1 if any_bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
