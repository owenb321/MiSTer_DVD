#!/usr/bin/env python3
"""sprm_census.py -- which discs' navigation READS SPRM 5/6/7 (docs/nav_engine.md 5a).

The core sets SPRM6 (TT_PGCN) and SPRM7 (PTTN) only at a jump, where libdvdnav updates
them as a title plays (set_PGCN / set_PGN). This counts the discs whose commands could
see the difference, split by how they read the register:

    cmp   a type 0/1 compare names it (reg1, or reg2 when not immediate):
          the disc branches on it directly
    set   a type 3 set takes it as the register source: the disc copies it into a
          GPRM, which matters only if a later command branches on that GPRM

Every PGC of every domain (VMGM, each VTSM, each title set) is scanned: PRE, POST and
cell commands. Button commands live in the VOBs' HLI and are NOT scanned. The decode is
deliberately narrow (types 4-6 also carry compares and sets), so the counts are a
floor for `cmp`.

Usage:
    tools/sprm_census.py [--jobs N] [--out census.json]        # $DVD_ISO_DIR
"""
import argparse
import collections
import concurrent.futures
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dvd_vm_ref as R                                   # noqa: E402

LIB = os.path.expanduser(os.environ.get('DVD_ISO_DIR', '~/dvd-isos'))
WATCH = {0x85: 5, 0x86: 6, 0x87: 7}                      # SPRM 5/6/7 as register operands
SKIP_DIRS = {d for d in os.environ.get('NAV_SKIP_DIRS', '').split(',') if d}   # as nav_offline


def reads(c):
    """-> {(kind, sprm)} this 8-byte command reads."""
    c = bytes(c)
    t = c[0] >> 5
    out = set()
    if t in (0, 1) and (c[1] >> 4) & 7:                  # a compare is present
        if c[3] in WATCH:
            out.add(('cmp', WATCH[c[3]]))
        if not c[1] & 0x80 and c[5] in WATCH:
            out.add(('cmp', WATCH[c[5]]))
    elif t == 3 and not c[0] & 0x10 and c[5] in WATCH:   # set, register source
        out.add(('set', WATCH[c[5]]))
    return out


def one(path):
    name = os.path.relpath(path, LIB)
    try:
        d = R.IsoNav(path)
    except Exception as e:
        return name, {'err': repr(e)[:60]}
    hits = collections.Counter()
    doms = [(R.DOM_VMGM, 0)] + [(dm, v) for v in sorted(d.vts_ifo)
                                for dm in (R.DOM_VTSM, R.DOM_TT)]
    for dm, v in doms:
        try:
            pit = d.pgcit(dm, v) or []
        except Exception:
            continue
        for _, a in pit:
            try:
                p = d.pgc(a)
            except Exception:
                continue
            for c in p['pre'] + p['post'] + p['cellc']:
                for kind, s in reads(c):
                    hits[f'{R.DOM_NAME[dm]}:{kind}:{s}'] += 1
    return name, dict(hits)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--jobs', type=int, default=2)
    ap.add_argument('--out', help='write the per-disc counts as JSON')
    a = ap.parse_args()
    isos = sorted(os.path.join(dp, f) for dp, _, fs in os.walk(LIB) for f in fs
                  if f.lower().endswith('.iso')
                  and not (set(os.path.relpath(dp, LIB).split(os.sep)) & SKIP_DIRS))
    with concurrent.futures.ProcessPoolExecutor(a.jobs) as ex:
        rs = dict(ex.map(one, isos))
    if a.out:
        json.dump(rs, open(a.out, 'w'), indent=1)
    per = collections.Counter(k for h in rs.values() for k in h)
    print(f'{len(rs)} discs; discs per domain:kind:SPRM')
    for k, n in sorted(per.items()):
        print(f'  {k:14} {n}')
    for s in (5, 6, 7):
        cmp_ = sum(1 for h in rs.values() if any(k.endswith(f'cmp:{s}') for k in h))
        any_ = sum(1 for h in rs.values() if any(k.endswith(f':{s}') for k in h))
        print(f'SPRM{s}: branched on by {cmp_} discs, read at all by {any_}')


if __name__ == '__main__':
    main()
