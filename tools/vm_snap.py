#!/usr/bin/env python3
"""vm_snap.py -- decode a DVD VM state snapshot (docs/nav_engine.md "State snapshot").

The core streams the VM's whole state as raw 16-bit words (dvd/vm_snap.sv, EXT_BUS
0x7D); the custom Main writes them to /tmp/dvd_vmsnap.json (dvd_ctl.cpp `vmsnap`).
This names them. The names come from tools/nav_isa.py snap_layout() -- the same list
the microcode's E_SNAP and the Python model stream in -- and are trusted only when the
snapshot's `fmt` equals nav_isa.snap_fmt(): a snapshot taken by a core built from a
different RAM map or port list is refused, never read against the wrong names.

Usage:
    tools/vm_snap.py snap.json            # print it by name
    tools/vm_snap.py snap.json --json     # {name: value, ...} plus the position
    tools/mister.py snap                  # take one on the rig and print it

As a module: decode(obj) -> dict, or raises ValueError on a format mismatch.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import nav_isa as N  # noqa: E402

DOMS = {0: 'FP', 1: 'VMGM', 2: 'VTSM', 3: 'TT'}
FBS = {v: k for k, v in N.FB_CODES.items()}


def bcd_time(v):
    """dvd_time_t {hh, mm, ss, ff|rate} (BCD) -> 'h:mm:ss'."""
    b = lambda x: (x >> 4) * 10 + (x & 15)   # noqa: E731
    return '%d:%02d:%02d' % (b((v >> 24) & 0xFF), b((v >> 16) & 0xFF), b((v >> 8) & 0xFF))


def decode(obj):
    """-> {'state': {name: value}, 'pos': {...}, 'seq': n} from the Main's JSON."""
    if obj.get('absent'):
        raise ValueError('the core has no VM snapshot (0x7D): an older build')
    if obj.get('timeout'):
        raise ValueError('the snapshot timed out: the VM never came to rest (busy=%s)' % obj.get('busy'))
    want = N.snap_fmt()
    if obj['fmt'] != want:
        raise ValueError('snapshot format %04x, this tree is %04x: a core built from a '
                         'different RAM map or port list' % (obj['fmt'], want))
    names = N.snap_layout()
    words = obj['words']
    if len(words) != len(names):
        raise ValueError('%d words, the layout has %d' % (len(words), len(names)))
    pos = {k: obj[k] for k in ('pos_fresh', 'has_video', 'nv_pck_lbn', 'prev_video',
                               'c_eltm', 'vob_idn', 'c_idn')}
    return {'seq': obj['seq'], 'state': dict(zip(names, words)), 'pos': pos}


def show(d):
    s, p = d['state'], d['pos']
    print('snapshot seq %d' % d['seq'])
    print('  where     VM %s vts %d   reader vts %d pgcn %d cell %d/%d   menu_active %d' % (
        DOMS.get(s['in_vm_dom'], '?'), s['in_vm_vts'], s['in_cur_vts'], s['in_cur_pgcn'],
        s['in_cur_cell'], s['in_cell_count'], s['in_menu_active']))
    print('  position  lbn %d  vob %d cell %d  %s  %s  %s' % (
        p['nv_pck_lbn'], p['vob_idn'], p['c_idn'], bcd_time(p['c_eltm']),
        'has video' if p['has_video'] else 'NO VIDEO in this VOBU',
        'fresh' if p['pos_fresh'] else 'STALE (flushed since the last NAV pack)'))
    print('  GPRM      ' + ' '.join('%04x' % s['g%d' % i] for i in range(16)))
    print('  counters  %04x (one bit per GPRM in counter mode)' % s['gmode'])
    print('  SPRM      ' + ' '.join('%d:%04x' % (n, s['sprm%d' % n]) for n in range(24)))
    print('  RSM       vts %d pgcn %d cell %d  regs %s' % (
        s['rsm_vts'], s['rsm_pgcn'], s['rsm_cell'],
        ' '.join('%04x' % s['rsm_r%d' % n] for n in range(4, 9))))
    print('  fallback  %s  came_via_menukey %d  skip_pre %d  tt_resolve %d  chain %d' % (
        FBS.get(s['fb'], s['fb']), s['cvm'], s['skip_pre'], s['tt_resolve'], s['chain']))
    print('  last menu valid %d  %s vts %d pgcn %d   menu_seen %d   lfsr %04x' % (
        s['in_lm_v'], DOMS.get(s['in_lm_dom'], '?'), s['in_lm_vts'], s['in_lm_pgcn'],
        s['in_menu_seen'], s['in_lfsr']))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('file')
    ap.add_argument('--json', action='store_true')
    a = ap.parse_args()
    try:
        d = decode(json.load(open(a.file)))
    except ValueError as e:
        print('vm_snap: %s' % e, file=sys.stderr)
        return 1
    if a.json:
        print(json.dumps(d, indent=1))
    else:
        show(d)
    return 0


if __name__ == '__main__':
    sys.exit(main())
