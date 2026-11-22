#!/usr/bin/env python3
"""dynrng_census.py -- what dynamic range compression do the library's AC-3 tracks author?

The census behind the OSD's Dynamic Range (issue #189, docs/status_log.md "Dynamic
Range"). For every title set declaring AC-3 it samples windows of the title VOBS
(tools/ac3_scan.py's stream rebuild), decodes each block with tools/ac3_model.py and
records the histogram of the block's dynrng byte, plus each block's largest
coefficient times its Normal and Night gain (Night uncapped: it shows whether the
square alone would push a coefficient past full scale). Then a summary: blocks by
exponent, the largest boost and cut, and how many streams reach Night's cap (e >= 2).

Usage:
    tools/dynrng_census.py [--limit N] [--jobs N] [--json out.jsonl]   # $DVD_ISO_DIR
    tools/dynrng_census.py --summary out.jsonl
"""
import argparse
import collections
import glob
import json
import math
import os
import struct
import sys
from multiprocessing import Pool

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ac3_model as M                                           # noqa: E402
import ac3_scan as S                                            # noqa: E402
from dvd_vm_ref import IsoNav                                   # noqa: E402
from nav_extract import parse_vts_attr                          # noqa: E402


def exp(d):
    e = d >> 5
    return e - 8 if e & 4 else e


def gain(d):
    return (32 + (d & 31)) / 32 * 2.0 ** exp(d)


def scan_iso(job):
    path, windows, window = job
    try:
        return _scan_iso(path, windows, window)
    except Exception:                   # not a DVD-Video image, or one the parse refuses
        return []


def _scan_iso(path, windows, window):
    rows = []
    nav = IsoNav(path)
    try:
        for vn, ifo_lba in sorted(nav.vts_ifo.items()):
            mat = nav.sec(ifo_lba)
            if not any(a[0] == S.FMT_AC3 for a in parse_vts_attr(mat)[2]):
                continue
            last_vts = struct.unpack('>I', mat[0x0C:0x10])[0]
            last_ifo = struct.unpack('>I', mat[0x1C:0x20])[0]
            tt = struct.unpack('>I', mat[0xC4:0xC8])[0]
            if not tt:
                continue
            start = ifo_lba + tt
            span = ifo_lba + last_vts - (last_ifo + 1) - start
            if span < window:
                continue
            per = {}
            for i in range(windows):
                pos = start + (span - window) * i // max(windows - 1, 1)
                for ssid, data in S.ac3_streams(nav.f, pos, window).items():
                    per.setdefault(ssid, []).append(data)
            for ssid, wins in per.items():
                r = dict(image=os.path.basename(path), vts=vn, ssid=ssid, blocks=0, hist={},
                         peak_n=0.0, peak_night=0.0, over_n=0, over_night=0)
                for data in wins:
                    dec = M.Decoder()
                    for _, fr in M.frames(bytes(data)):
                        try:
                            _, bl = dec.frame(fr)
                        except Exception:
                            break
                        for b in bl:
                            d = b['dynrng']
                            r['hist'][d] = r['hist'].get(d, 0) + 1
                            r['blocks'] += 1
                            mx = max((abs(c) for ch in b['coeff'] for c in ch), default=0) / (1 << 23)
                            g = gain(d)
                            r['peak_n'] = max(r['peak_n'], mx * g)
                            r['peak_night'] = max(r['peak_night'], mx * g * g)
                            r['over_n'] += mx * g > 1.0
                            r['over_night'] += mx * g * g > 1.0
                rows.append(r)
    finally:
        nav.f.close()
    return rows


def summary(rows):
    rows = [r for r in rows if r['blocks']]
    h = collections.Counter()
    for r in rows:
        h.update({int(k): v for k, v in r['hist'].items()})
    tot = sum(h.values())
    by_e = collections.Counter()
    for d, v in h.items():
        by_e[exp(d)] += v
    db = {d: 20 * math.log10(gain(d)) for d in h}
    cap = [r for r in rows if any(exp(int(d)) >= 2 for d in r['hist'])]
    print(f'images {len({r["image"] for r in rows})}, streams {len(rows)}, blocks {tot}')
    print(f'unity (0x00) {h[0] / tot:.3f}; by exponent ' +
          ', '.join(f'{e:+d}: {v / tot:.4f}' for e, v in sorted(by_e.items())))
    print(f'largest boost {max(db.values()):+.2f} dB, largest cut {min(db.values()):+.2f} dB')
    print(f'Night cap (e >= 2): {len(cap)} streams on {len({r["image"] for r in cap})} images, '
          f'{sum(v for d, v in h.items() if exp(d) >= 2)} blocks')
    print(f'largest coefficient x gain: Normal {max(r["peak_n"] for r in rows):.3f}, '
          f'Night uncapped {max(r["peak_night"] for r in rows):.3f}; '
          f'streams past full scale under Night: {sum(1 for r in rows if r["over_night"])}')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--limit', type=int, default=0, help='images, spread evenly over the library')
    ap.add_argument('--windows', type=int, default=3)
    ap.add_argument('--window', type=int, default=120, help='sectors a window')
    ap.add_argument('--jobs', type=int, default=max(1, (os.cpu_count() or 2) // 2))
    ap.add_argument('--json', help='write one row a stream')
    ap.add_argument('--summary', help='summarise a --json file and stop')
    a = ap.parse_args()
    if a.summary:
        summary([json.loads(line) for line in open(a.summary)])
        return 0
    root = os.environ.get('DVD_ISO_DIR')
    if not root:
        ap.error('set DVD_ISO_DIR')
    isos = sorted(glob.glob(os.path.join(root, '*.iso')))
    if a.limit:
        isos = isos[::max(1, len(isos) // a.limit)][:a.limit]
    rows = []
    out = open(a.json, 'w') if a.json else None
    with Pool(a.jobs) as p:
        for rs in p.imap_unordered(scan_iso, [(i, a.windows, a.window) for i in isos]):
            rows += rs
            if out:
                out.writelines(json.dumps(r) + '\n' for r in rs)
    summary(rows)
    return 0


if __name__ == '__main__':
    sys.exit(main())
