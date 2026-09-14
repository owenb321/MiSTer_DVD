#!/usr/bin/env python3
"""qmatrix_scan.py -- which discs DOWNLOAD a quantiser matrix, and how far is it
from the MPEG default the decoder falls back to?

A sequence header may carry `load_intra_quantiser_matrix` / `load_non_intra_
quantiser_matrix` and replace the default matrices wholesale (ISO 13818-2
6.3.11).  If that download does not take effect, every AC coefficient is scaled
by `default[k] / custom[k]` -- which on a menu still authored with a flat matrix
is up to 20.75x, and looks "deep fried": clipped highlights, speckled texture,
complementary-colour ringing on text.  That is the defect this tool exists to
size (docs/quant_matrix.md).

★ IT READS THE DEFAULT MATRICES OUT OF rtl/mpeg2/iquant.v, and that is as much
the point of the tool as the scan is.  The previous census of this kind lived
only as prose in CLAUDE.md; when the RTL moved, the prose did not, and a later
session spent hardware time chasing a defect that had been fixed months earlier
(see tools/acmod_scan.py, same lesson).  A table that cannot go stale beats a
correct one.

⚠ Scope, stated honestly: it samples the FIRST `--sectors` of each menu VOB
(VIDEO_TS.VOB and VTS_nn_0.VOB).  A sequence header deeper than that window is
not sampled, and title-domain downloads are out of scope unless --titles.  That
is the right window for this defect: menu stills are what hold a single
sequence header on screen indefinitely, while a title re-sends one every GOP and
so repairs itself within half a second.

Usage:
    tools/qmatrix_scan.py                      # the whole library
    tools/qmatrix_scan.py <iso> [<iso> ...]
    tools/qmatrix_scan.py --first-hit          # print one usable fixture source
    tools/qmatrix_scan.py --json out.json
"""
import argparse
import glob
import json
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dvd_vm_ref import IsoNav                                   # noqa: E402
from video_cadence_census import video_payload                  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IQUANT = os.path.join(REPO, 'rtl', 'mpeg2', 'iquant.v')

# par. 7.3.1: the download is transmitted in zigzag (scan 0) order.
ZIGZAG = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
          12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
          35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
          58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]


def default_matrices():
    """Read default_intra_quant()'s casex table out of rtl/mpeg2/iquant.v.

    ⚠ THIS IS THE POINT OF THE TOOL AS MUCH AS THE SCAN IS -- see the module
    docstring.  The non-intra default is a flat 16 and is a single constant in
    the RTL (iquant.v, non_intra_quant_matrix: `dta_out <= 8'd16`), so we read
    that one too rather than assuming it.  If either shape stops matching we say
    so loudly instead of guessing.
    """
    try:
        src = open(IQUANT).read()
    except OSError:
        return [0] * 64, 16, 'ASSUMED (iquant.v unreadable)'

    body = src.split('function [7:0]default_intra_quant', 1)
    if len(body) < 2:
        return ([8, 16, 19, 22, 26, 27, 29, 34] + [0] * 56, 16,
                'ASSUMED (no default_intra_quant function)')
    body = body[1].split('endfunction', 1)[0]
    raster = [None] * 64
    for idx, val in re.findall(r"6'd(\d+)\s*:\s*default_intra_quant\s*=\s*(\d+)", body):
        raster[int(idx)] = int(val)
    if any(v is None for v in raster):
        return ([8] + [16] * 63, 16, 'ASSUMED (incomplete casex table)')

    m = re.search(r"dta_out\s*<=\s*8'd(\d+)\s*;\s*//\s*Default non intra", src)
    nonintra = int(m.group(1)) if m else 16
    prov = 'from iquant.v' if m else 'intra from iquant.v, non-intra ASSUMED 16'
    return raster, nonintra, prov


class BitReader:
    def __init__(self, buf, byte_pos):
        self.b, self.p = buf, byte_pos * 8

    def u(self, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | ((self.b[self.p >> 3] >> (7 - (self.p & 7))) & 1)
            self.p += 1
        return v


def parse_seq_headers(es):
    """-> [dict] for every sequence header in this elementary stream.

    Fields: pos, intra (64 raster-order values or None), nonintra (ditto).
    `alt_scan` is the alternate_scan of the last picture coding extension seen
    BEFORE this header WITHIN THIS BUFFER, which is 0 at the head of a menu VOB.
    The value that actually reaches the un-zigzag is whatever the previously
    DECODED stream left behind -- on a title->menu jump, the title's -- so the
    caller probes that separately (`title_alt_scan`).  Saying "0" here without
    that probe would understate the second bug's blast radius.
    """
    out = []
    alt_scan = 0
    i = 0
    n = len(es)
    while i + 4 <= n:
        j = es.find(b'\x00\x00\x01', i)
        if j < 0 or j + 4 > n:
            break
        code = es[j + 3]
        if code == 0xB5 and j + 8 <= n and (es[j + 4] >> 4) == 8:
            # picture coding extension. Byte 3 of the payload is
            # {tff, frame_pred_frame_dct, concealment_mv, q_scale_type,
            #  intra_vlc_format, alternate_scan, rff, chroma_420_type} --
            # the same layout tools/video_cadence_census.py:scan_pictures
            # reads tff/rff out of. ⚠ alternate_scan is bit 2, NOT bit 7:
            # bit 7 is top_field_first, and reading it there silently
            # reports a field-order flag as a scan-order flag.
            alt_scan = (es[j + 7] >> 2) & 1
        elif code == 0xB3:
            try:
                r = BitReader(es, j + 4)
                r.u(12 + 12 + 4 + 4 + 18 + 1 + 10 + 1)   # size..constrained
                intra = nonintra = None
                if r.u(1):
                    zz = [r.u(8) for _ in range(64)]
                    intra = [0] * 64
                    for k, v in enumerate(zz):
                        intra[ZIGZAG[k]] = v
                if r.u(1):
                    zz = [r.u(8) for _ in range(64)]
                    nonintra = [0] * 64
                    for k, v in enumerate(zz):
                        nonintra[ZIGZAG[k]] = v
                out.append(dict(pos=j, intra=intra, nonintra=nonintra,
                                alt_scan=alt_scan))
            except IndexError:
                pass                                   # truncated tail
        i = j + 3
    return out


def ratios(custom, default):
    """-> (worst default/custom, worst custom/default, index of the worst)."""
    up = dn = 1.0
    worst = 0
    for k in range(64):
        c, d = custom[k], default[k]
        if c <= 0 or d <= 0:
            continue
        if d / c > up:
            up, worst = d / c, k
        dn = max(dn, c / d)
    return up, dn, worst


def probe_title_alt_scan(nav, sectors=24):
    """alternate_scan of the disc's main title -- the value the decoder is
    holding when it walks into a menu's sequence header (rtl/mpeg2/iquant.v:85
    un-zigzags the download with it, which is wrong per 13818-2 7.3.1).
    """
    parts = nav.groups.get(nav.best_vts) or []
    if not parts:
        return None
    ext, dl = parts[0]
    seen = set()
    for i in range(min(sectors, max(1, dl // 2048))):
        nav.f.seek((ext + i) * 2048)
        es = video_payload(nav.f.read(2048))
        j = 0
        while True:
            j = es.find(b'\x00\x00\x01\xb5', j)
            if j < 0 or j + 8 > len(es):
                break
            if (es[j + 4] >> 4) == 8:
                seen.add((es[j + 7] >> 7) & 1)
            j += 4
    return sorted(seen) or None


def scan_iso(path, args, dflt_intra, dflt_nonintra):
    nav = IsoNav(path)
    vobs = []
    for vn, (ext, dl) in sorted(nav.menu_vob.items()):
        vobs.append(('menu', vn, ext, dl))
    if args.titles:
        for vn, parts in sorted(nav.groups.items()):
            if parts:
                vobs.append(('title', vn, parts[0][0], parts[0][1]))

    rows = []
    for kind, vn, ext, dl in vobs[:args.max_vts or None]:
        nsec = min(args.sectors, max(1, dl // 2048))
        es = []
        for i in range(nsec):
            nav.f.seek((ext + i) * 2048)
            es.append(video_payload(nav.f.read(2048)))
        es = b''.join(es)
        if not es:
            continue
        for h in parse_seq_headers(es):
            if h['intra'] is None and h['nonintra'] is None:
                rows.append(dict(kind=kind, vts=vn, load=0, up=1.0, dn=1.0,
                                 worst=0, alt_scan=h['alt_scan'],
                                 flat=False, pos=h['pos']))
                continue
            up = dn = 1.0
            worst = 0
            if h['intra']:
                up, dn, worst = ratios(h['intra'], dflt_intra)
            if h['nonintra']:
                u2, d2, w2 = ratios(h['nonintra'], [dflt_nonintra] * 64)
                if u2 > up:
                    up, worst = u2, w2
                dn = max(dn, d2)
            rows.append(dict(kind=kind, vts=vn, load=1, up=up, dn=dn,
                             worst=worst, alt_scan=h['alt_scan'],
                             flat=bool(h['intra']) and len(set(h['intra'])) <= 2,
                             pos=h['pos'],
                             distinct=len(set(h['intra'])) if h['intra'] else 0))
    title_alt = probe_title_alt_scan(nav)
    for r in rows:
        r['title_alt_scan'] = title_alt
    nav.f.close()
    return rows


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('images', nargs='*')
    ap.add_argument('--sectors', type=int, default=64,
                    help='sectors of each menu VOB to sample (default 64)')
    ap.add_argument('--max-vts', type=int, default=0,
                    help='stop after N VOBs per disc (0 = all)')
    ap.add_argument('--titles', action='store_true',
                    help='also sample the head of each title VOB')
    ap.add_argument('--first-hit', action='store_true',
                    help='print the first disc usable as a bench fixture and stop')
    ap.add_argument('--perm-risk', action='store_true',
                    help='--first-hit: also require the title to use alternate_scan=1')
    ap.add_argument('--distinct', type=int, default=0,
                    help='--first-hit: require >= N distinct matrix values')
    ap.add_argument('--json', metavar='FILE')
    args = ap.parse_args()

    dflt_intra, dflt_nonintra, prov = default_matrices()
    if not args.first_hit:
        print(f'qmatrix_scan: default intra matrix {prov}; '
              f'peak {max(dflt_intra)}, non-intra {dflt_nonintra}')

    images = args.images
    if not images:
        root = os.environ.get('DVD_ISO_DIR', os.path.expanduser('~/dvd-isos'))
        images = sorted(glob.glob(os.path.join(root, '**', '*.iso'),
                                  recursive=True) +
                        glob.glob(os.path.join(root, '**', '*.ISO'),
                                  recursive=True))
        if not args.first_hit:
            print(f'qmatrix_scan: {len(images)} images under {root}')

    out, n_load, n_bad, n_err = [], 0, 0, 0
    for path in images:
        name = os.path.basename(path)
        try:
            rows = scan_iso(path, args, dflt_intra, dflt_nonintra)
        except Exception as e:                          # noqa: BLE001
            n_err += 1
            if not args.first_hit:
                print(f'  ERR       {name}: {e}')
            continue
        loads = [r for r in rows if r['load']]
        up = max((r['up'] for r in loads), default=1.0)
        if args.first_hit:
            cand = [r for r in loads
                    if r['up'] > 1.0 and r.get('distinct', 0) >= args.distinct]
            if args.perm_risk:
                talt = loads[0].get('title_alt_scan') if loads else None
                if not (talt and 1 in talt):
                    cand = []
            if cand:
                print(path)
                return 0
            continue
        if loads:
            n_load += 1
            if up > 2.0:
                n_bad += 1
            talt = loads[0].get('title_alt_scan')
            perm = ' PERM-RISK' if talt and 1 in talt and \
                max((r.get('distinct', 0) for r in loads), default=0) > 2 else ''
            print(f'  DOWNLOAD  {name:52s} {len(loads):3d}/{len(rows):3d} seq hdrs  '
                  f'worst default/custom {up:6.2f}  title alternate_scan {talt}{perm}')
        else:
            print(f'  default   {name:52s} {len(rows):3d} seq hdrs')
        out.append(dict(image=name, rows=rows, worst=up))

    if args.first_hit:
        print('qmatrix_scan: no usable fixture source found', file=sys.stderr)
        return 1

    n = len(out) + n_err
    n_perm = sum(1 for d in out for r in d['rows']
                 if r['load'] and r.get('distinct', 0) > 2 and
                 (r.get('title_alt_scan') or []) and 1 in r['title_alt_scan'])
    print(f'\nqmatrix_scan: {n_load}/{n} discs download a quantiser matrix in a '
          f'menu VOB; {n_bad} exceed 2x ({n_err} unreadable)')
    print(f'qmatrix_scan: {n_perm} downloads are BOTH varied and follow an '
          f'alternate_scan=1 title (the iquant.v:85 permutation case)')
    if args.json:
        with open(args.json, 'w') as f:
            json.dump(out, f, indent=1)
        print(f'qmatrix_scan: wrote {args.json}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
