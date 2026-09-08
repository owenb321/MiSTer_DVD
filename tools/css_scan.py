#!/usr/bin/env python3
"""css_scan.py -- vet a DVD-Video ISO (or a directory of them) for CSS-scrambled packs.

Why: the core never sees CSS keys (decryption is a PC-side rip step), so a raw or
partially-decrypted rip green-screens with audio static. Since PR #160 the core
DETECTS this on-board (persistent `CSS ENCRYPTED` HUD popup + audio mute), but the
right place to catch a bad rip is offline, before it ever reaches the SD card --
especially now that the dvd_ripper project mass-produces ISOs.

Detection: a pack whose FIRST PES optional-header flags byte has the '10' marker
bits AND PES_scrambling_control (bits [5:4]) != 0 is scrambled.

★ That "first PES" qualifier used to be undocumented, and the docstring here
claimed this tool "mirrors dvd/ps_demux.sv S_PES_HDR_FLAGS1 exactly". It never
did: this tool has always checked only the first PES after the pack header, while
the RTL checked EVERY checkable PES it dispatched. That divergence is how issue
#59 stayed hidden -- the oracle reported the same media clean while the core
flagged it in the field, because the oracle was quietly applying the stricter and
correct model. The RTL was changed to match this tool (dvd/ps_demux.sv
`pack_fresh`), not the other way round.

Layout per sampled 2048-byte sector:
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

Verdicts follow the CORE's rule (dvd/css_detect.sv), so this tool answers the
question a user actually has -- "will the core mute this?" -- rather than "is
there a single odd byte anywhere on the disc":
    ENCRYPTED  above the core's density knee, 1/(LEAK_CLEAN+1) = 1.5%  -> muted
    MARGINAL   some markers, but below the knee                        -> NOT muted
    CLEAN      none
MARGINAL exits 2 rather than being folded into CLEAN: a rip with stray markers is
worth looking at even though the core will play it.

Usage:
    tools/css_scan.py <iso-or-dir> [...]     # sampled scan (~20k packs/disc, seconds)
    tools/css_scan.py --full <iso>           # every sector (minutes on 8 GB)

Exit status: 0 = every image clean, 1 = any image ENCRYPTED, 2 = none encrypted
but at least one MARGINAL (scriptable as a ripper post-check).
"""
import os
import struct
import sys

SEC = 2048
TARGET_SAMPLES = 20000          # sampled mode: aim for this many sectors per image

# Stream ids the CORE checks -- deliberately the RTL's set and not the wider set of
# ids that merely CARRY an MPEG-2 optional header. dvd/ps_demux.sv routes only
# 0xE0 (video; E1-EF go to the skip-by-length path), 0xBD (private_stream_1) and
# MP2 0xC0-0xC7 to S_PES_HDR_FLAGS1. An oracle that is not the model is how this
# class of bug survives, so match it.
CHECKABLE = {0xE0, 0xBD} | set(range(0xC0, 0xC8))

# The core's density rule, from dvd/css_detect.sv -- SOURCE OF TRUTH IS THAT FILE.
# The bucket rises only while the scrambled fraction exceeds 1/(LEAK_CLEAN+1), so
# that ratio is the threshold between "the core will mute this" and "it will not".
CORE_LATCH_HITS = 16
CORE_LEAK_CLEAN = 64
CORE_KNEE_PCT = 100.0 / (CORE_LEAK_CLEAN + 1)     # 1.54%


def scan(path, full=False):
    size = os.path.getsize(path)
    nsec = size // SEC
    stride = 1 if full else max(1, nsec // TARGET_SAMPLES)
    packs = checked = scrambled = 0
    first_hits = []
    gaps, last_hit = [], None
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
                if last_hit is not None:
                    gaps.append(checked - last_hit)
                last_hit = checked
                if len(first_hits) < 3:
                    first_hits.append((s, sid))
    return nsec, stride, packs, checked, scrambled, first_hits, sorted(gaps)


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
    any_enc = any_marg = False
    for p in paths:
        nsec, stride, packs, checked, scrambled, hits, gaps = scan(p, full)
        pct = (100.0 * scrambled / checked) if checked else 0.0
        if scrambled == 0:
            verdict = "CLEAN"
        elif pct >= CORE_KNEE_PCT:
            verdict = "ENCRYPTED (%.1f%% of checked packs -- the core will mute)" % pct
            any_enc = True
        else:
            # Stray markers. Below the core's knee it plays them, so saying
            # "ENCRYPTED" here would send the user off to install libdvdcss they do
            # not need -- which is exactly what the core itself used to do (#59).
            verdict = ("MARGINAL (%.3f%% -- below the core's %.1f%% threshold, "
                       "it will NOT mute)" % (pct, CORE_KNEE_PCT))
            any_marg = True
        print("%-52s %s" % (os.path.basename(p), verdict))
        print("    sectors=%d stride=%d packs=%d pes_checked=%d scrambled=%d"
              % (nsec, stride, packs, checked, scrambled))
        if gaps:
            # The separation the core's rule keys on: real CSS hits every few
            # headers, a stray leaves thousands of clean ones between.
            print("    gap between hits (checked packs): min=%d median=%d max=%d"
                  % (gaps[0], gaps[len(gaps)//2], gaps[-1]))
        for s, sid in hits:
            print("    first hit: sector %d stream_id 0x%02X" % (s, sid))
        if checked == 0 and packs == 0:
            print("    ?? no MPEG packs found -- not a DVD-Video image?")
    if any_enc:
        return 1
    return 2 if any_marg else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
