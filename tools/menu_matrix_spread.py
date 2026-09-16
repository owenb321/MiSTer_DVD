#!/usr/bin/env python3
"""menu_matrix_spread.py -- how BAD would a menu still look if it inherited a
neighbouring menu's quantiser matrix instead of loading its own?

A menu still is `SEQ GOP PIC:I SEQ_END` -- one sequence header ever -- and a
menu->menu hop does not soft-reset the decoder (keep_vbuf), so if the landing's
header is eaten the still is dequantised with whatever matrix the PREVIOUS menu
left in the registers.  docs/quant_matrix.md §13.

The severity of that is NOT a disc's worst default/custom ratio (what
qmatrix_scan reports).  It is the worst ratio between the matrices the disc's own
menus download, because that is what actually gets substituted.  A disc whose
menus all share one matrix cannot show the defect however varied that matrix is;
a disc with a varied matrix AND a flat one can look dramatic.

  INCREDIBLE_HULK.iso: VTS_1 menus varied (distinct=17), VTS_2..7 menus FLAT
  (distinct=1) -- measured fried on hardware.

Reported per disc: the number of DISTINCT menu matrices, and the worst
coefficient ratio between any two of them (`spread`).  The default matrices are
included as a candidate "previous" matrix, since a decoder that has just been
reset holds those.

⚠ Scope: reads the head of each menu VOB (like qmatrix_scan), so a matrix that
first appears deeper in a VOB is not sampled -- this is a LOWER bound on the
spread.  It does not decode pictures; pair it with tools/still_menu_scan.py for
whether such a still is actually reachable by a hop.
"""
import sys, os, argparse, json, itertools

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qmatrix_scan import (default_matrices, parse_seq_headers,   # noqa: E402
                          BitReader, ZIGZAG)                     # noqa: E402
from dvd_vm_ref import IsoNav                                    # noqa: E402


def menu_es(nav, lba, sectors):
    """Demux the video elementary stream out of the head of a menu VOB."""
    out = bytearray()
    for s in range(sectors):
        try:
            sec = nav.sec(lba + s)
        except Exception:
            break
        if len(sec) < 2048 or sec[:4] != b'\x00\x00\x01\xba':
            continue
        i = 14 + (sec[13] & 7)
        while i + 6 <= 2048:
            if sec[i:i+3] != b'\x00\x00\x01':
                break
            sid = sec[i+3]
            ln = (sec[i+4] << 8) | sec[i+5]
            body = sec[i+6:i+6+ln]
            if sid == 0xE0 and len(body) >= 3:
                hl = body[2]
                out += body[3+hl:]
            i += 6 + ln
    return bytes(out)


def worst_pair(a, b):
    w = 1.0
    for k in range(64):
        x, y = a[k], b[k]
        if x <= 0 or y <= 0:
            continue
        w = max(w, x / y, y / x)
    return w


def scan(path, sectors, include_default):
    nav = IsoNav(path)
    mats = []
    # IsoNav's walk already located every menu VOB: {vts: (lba, bytes)}.
    for vts, (lba, size) in sorted(nav.menu_vob.items()):
        es = menu_es(nav, lba, min(sectors, max(1, size // 2048)))
        for h in parse_seq_headers(es):
            if h['intra']:
                mats.append(tuple(h['intra']))
    uniq = sorted(set(mats))
    if include_default:
        di = default_matrices()[0]
        uniq.append(tuple(di))
    spread = 1.0
    for a, b in itertools.combinations(uniq, 2):
        spread = max(spread, worst_pair(a, b))
    return {'image': os.path.basename(path), 'n_matrices': len(set(mats)),
            'spread': spread}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('images', nargs='+')
    ap.add_argument('--sectors', type=int, default=600)
    ap.add_argument('--no-default', action='store_true',
                    help='do not treat the MPEG defaults as a possible inherited matrix')
    ap.add_argument('--json', metavar='FILE')
    a = ap.parse_args()
    rows = []
    for p in a.images:
        try:
            rows.append(scan(p, a.sectors, not a.no_default))
        except Exception as e:
            print('  !! %-50s %s' % (os.path.basename(p)[:50], e))
    rows.sort(key=lambda r: -r['spread'])
    for r in rows[:40]:
        print('  %7.2fx  %-52s %d distinct menu matri%s'
              % (r['spread'], r['image'][:52], r['n_matrices'],
                 'x' if r['n_matrices'] == 1 else 'ces'))
    if a.json:
        json.dump(rows, open(a.json, 'w'), indent=1)
        print('  wrote %s' % a.json)
    return 0


if __name__ == '__main__':
    sys.exit(main())
