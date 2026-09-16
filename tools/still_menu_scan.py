#!/usr/bin/env python3
"""still_menu_scan.py -- which menus are STILL images, and how are they REACHED?

A menu still is `SEQ GOP PIC:I SEQ_END` -- ONE sequence header ever -- so whatever
the decoder loses at the landing (notably the quantiser-matrix download) is what you
look at for as long as the still is up.  docs/quant_matrix.md.

The decoder soft reset that repairs that landing is NOT available everywhere, and the
gap is structural rather than accidental:

    dvd/flush_ctl.sv:  soft_flush = mount OR (jump_ack && ~keep_vbuf && jump_cross)
    reader:            keep_vbuf  = menu_dom && (target is a menu domain)

so a **menu -> menu** hop (`keep_vbuf = 1`) soft-resets on NO build, before or after
PR #92 and PR #98.  A still landed on by such a hop is out of reach by construction.
That is exactly INCREDIBLE_HULK.iso's special-features menu (VTS_06 VTSM PGCN 15,
reached only by PGCN 14's POST LinkPGCN 15), which is fried on every build tried.

This tool sizes that population.  For every menu-domain PGC on a disc it decides
whether the PGC is a STILL, then classifies every inbound route to it:

  menu_hop   a Link* from another PGC in the SAME menu domain   -> keep_vbuf=1, NO reset
  crossing   a JumpSS (domain change), or the PGC is a menu ENTRY (0x82..0x87,
             i.e. reachable by the Menu/Title/Chapter key from a title) -> reset fires
  self       its own next/goup/prev pointer or a self-link
  none       nothing in this domain links to it

★ It reports the routes a still has, not a single verdict, because a still reachable
BOTH ways is only fried on the menu_hop route -- which is precisely why this class of
defect reads as intermittent, and why "I pressed Menu and it was fine" does not clear
a disc.

⚠ Scope, stated honestly: this is a STATIC link graph over the IFOs.  It does not
execute the VM, so a link reached only through a computed GPRM branch is still counted
as an inbound route (it is one), and a PGC that the disc can never actually reach is
still counted as present.  It also does not read the VOBs, so it says nothing about
whether a given still's matrix is varied -- pair it with tools/qmatrix_scan.py, which
answers that and reads its defaults out of rtl/mpeg2/iquant.v.
"""
import sys, os, re, argparse, collections, json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dvd_vm_ref import IsoNav, DOM_VMGM, DOM_VTSM, DOM_TT   # noqa: E402
from iso_nav_check import decode_vmcmd                      # noqa: E402

LINK_RE = re.compile(r'\bLink(PGCN|PGN|PTTN|CN|TailPGC|NextPG|PrevPG|TopPG|TopCell|NextCell|PrevCell|TopPGC|GoUpPGC|NoLink)\b\s*(\d+)?')
JUMPSS_RE = re.compile(r'\bJumpSS\b')
JUMP_RE = re.compile(r'\bJump(TT|VTS_TT|VTS_PTT)\b')

# menu entry_ids that a player can reach directly from a title
ENTRY_IDS = {0x82: 'Title', 0x83: 'Root', 0x84: 'SubPic', 0x85: 'Audio',
             0x86: 'Angle', 0x87: 'Chapter'}


def pgc_is_still(p):
    """A PGC whose displayed content is a held still image.

    Explicit only: at least one cell with still_time == 255 (or the PGC-level
    still). The playtime heuristic in iso_nav_check is deliberately NOT used --
    it would fold in short motion clips and inflate the population.
    """
    if p['nr_cells'] == 0:
        return False
    if p.get('still', 0) == 255:
        return True
    return any(c['still'] == 255 for c in p['cells'])


def scan_domain(nav, dom, vts):
    """-> (pgcs, inbound)  for one menu domain.

    pgcs[pgcn]   = {'entry':id, 'still':bool, 'cells':n}
    inbound[pgcn] = set of route kinds
    """
    try:
        lst = nav.pgcit(dom, vts)
    except Exception:
        return None, None
    if not lst:
        return None, None
    pgcs, inbound = {}, collections.defaultdict(set)
    parsed = {}
    for i, (eid, abs_) in enumerate(lst, start=1):
        try:
            p = nav.pgc(abs_)
        except Exception:
            continue
        parsed[i] = p
        pgcs[i] = {'entry': eid, 'still': pgc_is_still(p), 'cells': p['nr_cells']}
        if eid in ENTRY_IDS:
            # reachable from a title by a remote key => a menu/title CROSSING
            inbound[i].add('crossing')

    for src, p in parsed.items():
        for blk in ('pre', 'post', 'cellc'):
            for b in p[blk]:
                try:
                    txt = decode_vmcmd(bytes(b))
                except Exception:
                    continue
                if JUMPSS_RE.search(txt):
                    # a JumpSS names a domain explicitly; its target is another
                    # domain, so anything it lands on is reached by a crossing.
                    m = re.search(r'menu (\d+)', txt)
                    if m:
                        pass  # entry-number based; the ENTRY_IDS pass already covers it
                    continue
                for m in LINK_RE.finditer(txt):
                    op, num = m.group(1), m.group(2)
                    if op == 'PGCN' and num:
                        tgt = int(num)
                        if tgt in pgcs:
                            inbound[tgt].add('self' if tgt == src else 'menu_hop')
                    elif op in ('NextPG', 'PrevPG', 'TopPG', 'NextCell', 'PrevCell',
                                'TopCell', 'TopPGC', 'PGN', 'PTTN', 'CN'):
                        inbound[src].add('self')       # stays inside this PGC
                    elif op == 'GoUpPGC':
                        g = p.get('goup', 0)
                        if g in pgcs:
                            inbound[g].add('menu_hop')
                    elif op == 'TailPGC':
                        pass                            # runs this PGC's own POST
        # authored next/goup pointers are followed by the player at a PGC end
        for fld in ('next', 'goup'):
            t = p.get(fld, 0)
            if t and t in pgcs and t != src:
                inbound[t].add('menu_hop')
    return pgcs, inbound


def scan_iso(path, want_title=False):
    nav = IsoNav(path)
    doms = [(DOM_VMGM, 0)]
    for v in sorted(nav.vts_ifo):
        doms.append((DOM_VTSM, v))
    res = {'path': path, 'stills': 0, 'hop_only': 0, 'crossing_reachable': 0,
           'unreached': 0, 'title_stills': 0, 'examples': []}
    for dom, vts in doms:
        pgcs, inbound = scan_domain(nav, dom, vts)
        if not pgcs:
            continue
        for pgcn, info in pgcs.items():
            if not info['still']:
                continue
            res['stills'] += 1
            routes = inbound.get(pgcn, set()) - {'self'}
            if not routes:
                res['unreached'] += 1
            elif routes == {'menu_hop'}:
                res['hop_only'] += 1
                if len(res['examples']) < 4:
                    dn = 'VMGM' if dom == DOM_VMGM else 'VTS_%02d VTSM' % vts
                    res['examples'].append('%s PGCN %d' % (dn, pgcn))
            else:
                res['crossing_reachable'] += 1
    if want_title:
        for v in sorted(nav.vts_ifo):
            pgcs, _ = scan_domain(nav, DOM_TT, v)
            if pgcs:
                res['title_stills'] += sum(1 for i in pgcs.values() if i['still'])
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('images', nargs='*')
    ap.add_argument('--title', action='store_true',
                    help='also count TITLE-domain stills (the DVD-game case)')
    ap.add_argument('--json', metavar='FILE')
    ap.add_argument('--quiet', action='store_true')
    a = ap.parse_args()

    rows, bad = [], 0
    for p in a.images:
        try:
            r = scan_iso(p, a.title)
        except Exception as e:
            bad += 1
            if not a.quiet:
                print('  !! %-58s %s' % (os.path.basename(p)[:58], e))
            continue
        rows.append(r)
        if not a.quiet and r['hop_only']:
            print('  HOP-ONLY %-46s %2d still menu(s), %2d reachable ONLY by a menu hop  %s'
                  % (os.path.basename(p)[:46], r['stills'], r['hop_only'],
                     ', '.join(r['examples'])))

    n = len(rows)
    print()
    print('still_menu_scan: %d image(s) parsed, %d unreadable' % (n, bad))
    if not n:
        return 1
    with_still = [r for r in rows if r['stills']]
    hop_only   = [r for r in rows if r['hop_only']]
    print('  discs with at least one STILL menu        : %d / %d' % (len(with_still), n))
    print('  discs with a still reachable ONLY by a    : %d / %d   <-- out of the soft'
          % (len(hop_only), n))
    print('    menu->menu hop (keep_vbuf, never reset)              reset\'s reach')
    print('  total still menus                         : %d' % sum(r['stills'] for r in rows))
    print('    reachable by a crossing (reset fires)   : %d' % sum(r['crossing_reachable'] for r in rows))
    print('    ONLY by a menu hop (reset never fires)  : %d' % sum(r['hop_only'] for r in rows))
    print('    no inbound link found in this domain    : %d' % sum(r['unreached'] for r in rows))
    if a.title:
        print('  TITLE-domain stills (the DVD-game case)   : %d on %d disc(s)'
              % (sum(r['title_stills'] for r in rows),
                 sum(1 for r in rows if r['title_stills'])))
    if a.json:
        with open(a.json, 'w') as f:
            json.dump(rows, f, indent=1)
        print('  wrote %s' % a.json)
    return 0


if __name__ == '__main__':
    sys.exit(main())
