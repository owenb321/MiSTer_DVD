#!/usr/bin/env python3
"""Generate bench/dvd/test_vobs/subp_map_vec.hex — golden vectors for
bench/dvd/subp_stream_map_tb.sv, from the reference model
tools/dvd_vm_ref.py subp_stream_map() (the libdvdnav vm_get_subp_stream port,
with this core's documented forced-wide-for-menus deviation).

Vector format, one hex word per line, 42 bits:
  [41:37] expect (phys_streamN)
  [36:5]  ctl_sel   (subp_control[logical])
  [4:1]   logical
  ...packed low bits below

  bit layout, LSB first:
    [0]     map_valid
    [1]     dom_tt
    [2]     menu_dom  (a MENU-DOMAIN PGC is loaded; NOT "menu context" -- #81)
    [3]     wide
    [5:4]   disp_mode
    [9:6]   logical
    [41:10] ctl_sel
    [46:42] expect

Deterministic (seeded) — regenerating always produces the same file.

The DIRECTED cases are the real disc census, not invented numbers:
  0x80010200  both #60/#61 discs, EVERY menu PGC (4:3=0 wide=1 lbox=2)
  0x80000100  16 of the 17 non-identity library discs (wide=0 lbox=1)
  0x80010000  ATFIRSTSIGHT (wide=1, but a 4:3 menu)
  0x00000000  #60's VMGM PGCs (unavailable)
  0x80020300  the Matrix white-rabbit shape already in iso_reader_subpctl_tb
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dvd_vm_ref import subp_stream_map

W_EXPECT = 42


def vec(map_valid, dom_tt, menu_dom, wide, disp_mode, logical, ctl_sel):
    exp = subp_stream_map(logical, ctl_sel, dom_title=bool(dom_tt),
                          menu_dom=bool(menu_dom), wide=bool(wide),
                          disp_mode=disp_mode, map_valid=bool(map_valid))
    v = (int(map_valid) & 1)
    v |= (int(dom_tt) & 1) << 1
    v |= (int(menu_dom) & 1) << 2
    v |= (int(wide) & 1) << 3
    v |= (disp_mode & 3) << 4
    v |= (logical & 0xF) << 6
    v |= (ctl_sel & 0xFFFFFFFF) << 10
    v |= (exp & 0x1F) << W_EXPECT
    return v


REAL = {
    'reporters':   0x80010200,   # #60 + #61, every menu PGC
    'library16':   0x80000100,   # 16/17 non-identity library discs
    'atfirst':     0x80010000,   # wide=1 but a 4:3 menu
    'unavail':     0x00000000,   # #60's VMGM PGCs
    'rabbit':      0x80020300,   # Matrix SetSTN logical 1
    'identity':    0x80000000,   # everything -> 0
}


def main():
    out = []

    # ---- the bug itself, and its controls, across every display mode --------
    for dm in (0, 1, 2):
        # menu context, menu-domain table (dom_tt=0): the shipping arm
        out.append(vec(1, 0, 1, 1, dm, 0, REAL['reporters']))
        out.append(vec(1, 0, 1, 1, dm, 0, REAL['library16']))
        out.append(vec(1, 0, 1, 1, dm, 0, REAL['unavail']))
        out.append(vec(1, 0, 1, 1, dm, 0, REAL['identity']))
        # a 4:3 menu takes the >>24 field whatever the display mode
        out.append(vec(1, 0, 1, 0, dm, 0, REAL['atfirst']))
        out.append(vec(1, 0, 1, 0, dm, 0, REAL['reporters']))

    # ---- the domain gate: a MENU-domain player must REFUSE a title table ---
    out.append(vec(1, 1, 1, 1, 0, 0, REAL['reporters']))   # -> identity 0
    out.append(vec(1, 1, 1, 1, 0, 0, REAL['library16']))
    # ...and a TITLE-domain player must refuse a menu table
    out.append(vec(1, 0, 0, 1, 0, 1, REAL['rabbit']))      # -> identity 1
    out.append(vec(1, 0, 0, 1, 0, 3, REAL['reporters']))

    # ---- issue #81: an IN-TITLE menu is a menu context in the TITLE domain, so
    # its highlight SPU must resolve through the map. dom_tt=1, menu_dom=0.
    for dm in (0, 1, 2):
        out.append(vec(1, 1, 0, 1, dm, 0, REAL['reporters']))   # -> 1 / 2 / 0
        out.append(vec(1, 1, 0, 1, dm, 0, REAL['library16']))

    # ---- mid-parse: map_valid=0 is identity in both contexts ---------------
    for log in range(4):
        out.append(vec(0, 0, 1, 1, 0, log, REAL['reporters']))
        out.append(vec(0, 1, 0, 1, 0, log, REAL['rabbit']))

    # ---- the in-title path (title table, title context) --------------------
    for dm in (0, 1, 2):
        out.append(vec(1, 1, 0, 1, dm, 1, REAL['rabbit']))
        out.append(vec(1, 1, 0, 0, dm, 1, REAL['rabbit']))
        out.append(vec(1, 1, 0, 1, dm, 5, REAL['unavail']))  # unavail -> identity 5

    # ---- every logical index resolves its own word -------------------------
    for log in range(16):
        out.append(vec(1, 1, 0, 1, 0, log, REAL['reporters']))
        out.append(vec(1, 0, 1, 1, 0, log, REAL['reporters']))

    # ---- seeded random sweep ----------------------------------------------
    rnd = random.Random(0x5B9C)
    for _ in range(2000):
        ctl = rnd.getrandbits(32)
        out.append(vec(rnd.getrandbits(1), rnd.getrandbits(1), rnd.getrandbits(1),
                       rnd.getrandbits(1), rnd.randrange(4), rnd.randrange(16), ctl))

    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    dst = os.path.join(here, 'bench', 'dvd', 'test_vobs', 'subp_map_vec.hex')
    with open(dst, 'w') as f:
        for v in out:
            f.write('%012x\n' % v)
    print('%s: %d vectors' % (dst, len(out)))
    return len(out)


if __name__ == '__main__':
    main()
