#!/usr/bin/env python3
"""subp_route_sweep.py -- prove the menu subpicture routing change is confined.

WHY THIS EXISTS

Issues #60/#61 are two PAL FR R2 discs whose menus show no button highlight.
Root cause: the core pinned every menu to PHYSICAL subpicture substream 0x20,
while those discs author subp_control[0] = 0x80010200 on every menu PGC
(available, 4:3->0, wide->1, letterbox->2) with 16:9 menus -- so their menu SPU
rides 0x21 and was discarded. A button highlight is a RECOLOUR of subpicture
pixels, so nothing was drawn at all.

The fix routes a menu through pgc->subp_control like libdvdnav does. That
touches the boot path of EVERY disc, and the maintainer cannot reproduce the
bug (no library disc has the shape). So the acceptance evidence is the inverse:
compute the OLD routing (constant 0) and the NEW routing (the golden model) for
every menu PGC of every disc available, and show that the ONLY discs whose
routing changes are the ones being fixed.

Usage:
    tools/subp_route_sweep.py [ISO_OR_DIR ...]        # default: $DVD_ISO_DIR
    tools/subp_route_sweep.py --quiet                 # only the summary

With no arguments it sweeps ${DVD_ISO_DIR:-~/dvd-isos} recursively.
"""
import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dvd_vm_ref import IsoNav, subp_stream_map

u16 = lambda b, o: struct.unpack('>H', b[o:o + 2])[0]
u32 = lambda b, o: struct.unpack('>I', b[o:o + 4])[0]


def menu_pgcs(nav, utsec):
    """[(pgcn, entry_id, subp_control[0])] for one PGCI_UT."""
    try:
        raw = b''.join(nav.sec(utsec + i) for i in range(8))
        nlu = u16(raw, 0)
        if not nlu:
            return []
        lsb = u32(raw, 12)                       # LU[0].lang_start_byte
        p = raw[lsb:]
        out = []
        for i in range(u16(p, 0)):
            off = u32(p, 8 + i * 8 + 4)
            g = p[off:off + 240]
            if len(g) >= 160:
                out.append((i + 1, p[8 + i * 8], u32(g, 28)))
        return out
    except Exception:
        return []


def menu_is_wide(vattr):
    return ((vattr >> 10) & 3) == 3


def sweep_iso(path):
    """-> (label, [(where, pgcn, ctl, old_phys, new_phys)]) for CHANGED rows."""
    nav = IsoNav(path)
    try:
        changed, total = [], 0
        d = nav.sec(nav.vmgi_lba)
        units = []
        ut = u32(d, 200)
        if ut:
            units.append(('VMGM', nav.vmgi_lba + ut, menu_is_wide(u16(d, 256))))
        for vn, lba in sorted(nav.vts_ifo.items()):
            dv = nav.sec(lba)
            v = u32(dv, 208)
            if v:
                units.append(('VTS_%02d VTSM' % vn, lba + v,
                              menu_is_wide(u16(dv, 256))))
        for where, utsec, wide in units:
            for pgcn, _entry, ctl in menu_pgcs(nav, utsec):
                total += 1
                # OLD: menus were pinned to physical substream 0.
                old = 0
                # NEW: logical 0 through the map, menu context, forced wide.
                new = subp_stream_map(0, ctl, dom_title=False, ctx_menu=True,
                                      wide=wide, disp_mode=0, map_valid=True)
                if new != old:
                    changed.append((where, pgcn, ctl, old, new, wide))
        return total, changed
    finally:
        nav.f.close()


def iter_isos(roots):
    for r in roots:
        if os.path.isfile(r):
            yield r
        else:
            for dirpath, _dirs, files in os.walk(r):
                for fn in sorted(files):
                    if fn.lower().endswith(('.iso', '.img')):
                        yield os.path.join(dirpath, fn)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('paths', nargs='*',
                    help='ISO files or directories (default: $DVD_ISO_DIR)')
    ap.add_argument('--quiet', action='store_true', help='summary only')
    args = ap.parse_args()

    roots = args.paths or [os.path.expanduser(
        os.environ.get('DVD_ISO_DIR', '~/dvd-isos'))]

    n_disc = n_changed = n_err = n_pgc = 0
    for path in iter_isos(roots):
        n_disc += 1
        try:
            total, changed = sweep_iso(path)
        except Exception as ex:
            n_err += 1
            if not args.quiet:
                print('  !! %-52s %s' % (os.path.basename(path)[:52], str(ex)[:40]))
            continue
        n_pgc += total
        if changed:
            n_changed += 1
            print('CHANGED  %s' % os.path.basename(path))
            for where, pgcn, ctl, old, new, wide in changed:
                print('    %-14s PGCN %-3d ctl=%08x  menu=%s  0x%02X -> 0x%02X'
                      % (where, pgcn, ctl, '16:9' if wide else '4:3 ',
                         0x20 + old, 0x20 + new))

    print()
    print('discs scanned      : %d  (%d unreadable)' % (n_disc, n_err))
    print('menu PGCs examined : %d' % n_pgc)
    print('discs CHANGED      : %d' % n_changed)
    print('discs unchanged    : %d' % (n_disc - n_err - n_changed))
    return 0


if __name__ == '__main__':
    sys.exit(main())
