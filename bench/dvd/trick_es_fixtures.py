#!/usr/bin/env python3
"""trick_es_fixtures.py <outdir> [--discs N] [--frames N]

Fixtures for bench/dvd/run_trick_es_filter.sh. Each case is a pair:
  <case>.in   the video ES as ps_demux emits it in trick play (each read's ES, spliced)
  <case>.exp  what dvd/trick_es_filter.sv must emit, byte for byte
plus a line in <outdir>/cases.txt: "<case> <skip_n> <pair_n>" (the counters expected;
'-' = not checked).

Every input ends with one closing sequence header (00 00 01 B3) so the last read's tail
is decided; the expected output ends with it too.

Real discs: tools/trick_splice.py's walk over N discs drawn (seeded) from $DVD_ISO_DIR,
every tier, both directions; expected = the model's es_filter. Synthetic: the cases no
disc in the 150-disc sweep contains (field pairs, a first picture that is not an I,
MPEG-1, reads split inside a start code), expected written by hand from the rule.
"""
import argparse, glob, os, random, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'tools'))
from trick_splice import walk, es_filter, TIER_S          # noqa: E402
from trick_scan import title_extents, SEC                  # noqa: E402
from nav_extract import is_nav_pack                        # noqa: E402

SEQ_END = b'\x00\x00\x01\xb3'


def sc(code):
    return b'\x00\x00\x01' + bytes([code])


def seq_hdr(mpeg2=True):
    h = sc(0xB3) + bytes([0x2D, 0x01, 0xE0, 0x34, 0xFF, 0xFF, 0xE0, 0x18])   # 720x480
    if mpeg2:
        h += sc(0xB5) + bytes([0x14, 0x8A, 0x00, 0x01, 0x00, 0x00])            # seq ext
    return h + sc(0xB8) + bytes([0x00, 0x08, 0x00, 0x40])                      # GOP


def pic(pct, structure=3, mpeg2=True, tr=0):
    """picture header (+ picture_coding_extension) + two slices of filler."""
    b1 = ((tr & 3) << 6) | (pct << 3)
    h = sc(0x00) + bytes([(tr >> 2) & 0xFF, b1, 0xFF, 0xF8])
    if mpeg2:
        h += sc(0xB5) + bytes([0x8F, 0xFF, 0xF0 | structure, 0x80, 0x80])
    body = b''
    for s in (1, 2):
        body += sc(s) + bytes((s * 37 + k * 11) & 0xFE | 0x02 for k in range(40))
    return h + body


def synthetic():
    """[(name, in, exp, skip_n, pair_n)]"""
    I, P, B = 1, 2, 3
    out = []
    # field pair: I top + P bottom pass; the B after them is cut
    r = seq_hdr() + pic(I, 1) + pic(P, 2, tr=1) + pic(B, 3, tr=2)[:30]
    e = seq_hdr() + pic(I, 1) + pic(P, 2, tr=1)
    out.append(('syn_field_pair', r * 3, e * 3, 0, 3))
    # first picture not an I: its headers pass, the picture does not; next read normal
    r1 = seq_hdr() + pic(P, 3) + pic(B, 3, tr=1)[:20]
    r2 = seq_hdr() + pic(I, 3) + pic(B, 3, tr=1)[:25]
    out.append(('syn_first_not_i', r1 + r2, seq_hdr() + seq_hdr() + pic(I, 3), 1, 0))
    # MPEG-1: no extensions, always a frame
    r = seq_hdr(False) + pic(I, 3, False) + pic(B, 3, False, tr=1)[:33]
    out.append(('syn_mpeg1', r * 2, (seq_hdr(False) + pic(I, 3, False)) * 2, 0, 0))
    # a read ending with a dangling 00 00 01 (the next read's 00 00 01 B3 follows it)
    r = seq_hdr() + pic(I, 3) + b'\x00\x00\x01'
    out.append(('syn_dangling', r * 3, (seq_hdr() + pic(I, 3)) * 3, 0, 0))
    # a read ending in zero stuffing: legal, kept
    r = seq_hdr() + pic(I, 3) + b'\x00\x00'
    out.append(('syn_zeros', r * 2, r * 2, 0, 0))
    # junk before the first header (the head of a read that is not ES-aligned) and
    # after the cut, with start-code-like bytes in it
    junk = b'\x00\x01\x00\x00\x00\x01\x01\x55\x00\x00\x01\x00\x12\x34\x00\x00'
    r = junk + seq_hdr() + pic(I, 3) + pic(B, 3, tr=1)[:40] + junk
    out.append(('syn_junk', r * 2, (seq_hdr() + pic(I, 3)) * 2, 0, 0))
    return out


def disc_cases(iso, frames):
    out = []
    with open(iso, 'rb') as f:
        ext = title_extents(f)
        if not ext:
            return out
        vts = max(ext, key=lambda v: sum(d for _, d in ext[v]))
        lo = min(e for e, _ in ext[vts])
        hi = max(e + (d + SEC - 1) // SEC for e, d in ext[vts])
        start = lo + int((hi - lo) * 0.3)
        while start < hi:
            f.seek(start * SEC)
            if is_nav_pack(f.read(SEC)):
                break
            start += 1
        for tier in range(4):
            for fwd in (True, False):
                raw, exp = bytearray(), bytearray()
                for _, chunk in walk(f, lo, hi, start, TIER_S[tier], fwd, frames):
                    raw += chunk
                    cut, _ = es_filter(chunk)
                    if cut is not None:
                        exp += cut
                if raw:
                    out.append(('%s_t%d_%s' % (os.path.basename(iso)[:24].replace(' ', '_'),
                                               tier, 'fwd' if fwd else 'rev'),
                                bytes(raw), bytes(exp), '-', '-'))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('outdir')
    ap.add_argument('--discs', type=int, default=8)
    ap.add_argument('--frames', type=int, default=20)
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)
    cases = synthetic()
    lib = os.environ.get('DVD_ISO_DIR', '')
    isos = sorted(glob.glob(os.path.join(lib, '**', '*.iso'), recursive=True)) if lib else []
    if isos:
        for iso in random.Random(1).sample(isos, min(a.discs, len(isos))):
            try:
                cases += disc_cases(iso, a.frames)
            except Exception as e:                       # an unreadable image: say so
                print('  skip %s: %s' % (os.path.basename(iso), e))
    else:
        print('NOTE: no DVD_ISO_DIR, synthetic cases only')
    with open(os.path.join(a.outdir, 'cases.txt'), 'w') as m:
        for name, raw, exp, sk, pr in cases:
            open(os.path.join(a.outdir, name + '.in'), 'wb').write(raw + SEQ_END)
            open(os.path.join(a.outdir, name + '.exp'), 'wb').write(exp + SEQ_END)
            m.write('%s %s %s\n' % (name, sk, pr))
    print('%d cases (%d real)' % (len(cases), sum(1 for c in cases if c[3] == '-')))


if __name__ == '__main__':
    main()
