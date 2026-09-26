#!/usr/bin/env python3
"""Model of the reader's Auto (Disc Menus Off) pick and the chapter table it shows.

dvd/dvd_iso_reader.sv in Auto mode plays the largest VTS (total bytes of its title
VOBs), and inside it the PGC with the longest playback_time among the first
DUR_SCAN_MAX (128) PGCs; a PGC with no cells cannot win, ties keep the earlier one,
and the default is PGCN 1. Issue #132: the chapter table it publishes must be the
one of the title that PGC belongs to, not title 1's.

For every image this prints which case the Auto winner k falls in:

  A  k is title 1's entry PGC                  - title 1's table, as before
  B  k is another title's entry PGC (bit 7)    - the reload changes the table
  C  k has no entry flag                       - split by which tables name k,
                                                 and what entry_id[6:0] says

The C rows are the evidence for the reader's rule "the owning title is
entry_id[6:0] whether or not bit 7 is set": on every C disc where some table
names k, the low 7 bits name exactly that title.

Usage:
  tools/auto_pick_model.py [<iso-or-dir> ...]     # default: $DVD_ISO_DIR
  tools/auto_pick_model.py -v ...                 # list the discs in each case
"""
import collections, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ptt_ref import Disc, load_layout, read_ptt_table   # noqa: E402

DUR_SCAN_MAX = 128


def _bcd(b):
    return (b >> 4) * 10 + (b & 0xF)


def auto_pick(path):
    """-> dict describing the Auto winner and every title table of its VTS, or None."""
    d = Disc(path)
    _, ifo, grp = load_layout(d)
    if not grp:
        return None
    vtsn = max(grp.items(), key=lambda kv: sum(dl for _, dl in kv[1]))[0]
    il = ifo.get(vtsn)
    if il is None:
        return None
    mat = d.sec(il)
    pit = struct.unpack('>I', mat[204:208])[0]
    if not (0 < pit <= 1048575):
        return None
    pa = (il + pit) * 2048
    nsrp = struct.unpack('>H', d.rd(pa, 2))[0]
    if nsrp == 0:
        return None
    srps = []
    for i in range(nsrp):
        e = d.rd(pa + 8 + 8 * i, 8)
        srps.append((e[0], struct.unpack('>I', e[4:8])[0]))
    k = 1
    if nsrp > 1:                                   # the dur_scan
        best = 0
        for i in range(min(nsrp, DUR_SCAN_MAX)):
            h = d.rd(pa + srps[i][1], 8)
            secs = _bcd(h[4]) * 3600 + _bcd(h[5]) * 60 + _bcd(h[6])
            if h[3] != 0 and secs > best:
                best, k = secs, i + 1
    eid = srps[k - 1][0]
    nprog = d.rd(pa + srps[k - 1][1], 4)[2]
    ptt_off = struct.unpack('>I', mat[200:204])[0]
    nsr = 0
    if 0 < ptt_off <= 0xFFFFF:
        nsr = struct.unpack('>H', d.rd((il + ptt_off) * 2048, 2))[0]
    tabs = {t: read_ptt_table(d, il, t)[1] for t in range(1, nsr + 1)}
    return dict(vtsn=vtsn, k=k, eid=eid, nprog=nprog, tabs=tabs,
                owners=[t for t, p in tabs.items() if any(pg == k for pg, _ in p)])


def classify(r):
    tabs, k, eid = r['tabs'], r['k'], r['eid']
    n1 = len(tabs.get(1, []))
    if eid & 0x80:
        ttn = eid & 0x7F
        if ttn == 1:
            return 'A  title 1 entry PGC'
        shown_wrong = len(tabs.get(ttn, [])) != n1
        return 'B  title N entry PGC, %s' % (
            'pre-fix total WRONG' if shown_wrong else 'pre-fix total happened to match')
    low = eid & 0x7F
    own = r['owners']
    if not own:
        return 'C  no entry flag, in no table (nr_ptt -> 0)'
    agrees = (own == [low]) or (low == 0 and own == [1])
    where = 'title 1' if own == [1] else 'another title' if len(own) == 1 else 'several titles'
    return 'C  no entry flag, in %s; entry_id[6:0] %s' % (
        where, 'names it' if agrees else 'DISAGREES')


def gather(paths):
    out = []
    for p in paths:
        if os.path.isdir(p):
            for root, _, files in os.walk(p):
                out += [os.path.join(root, f) for f in files if f.lower().endswith('.iso')]
        else:
            out.append(p)
    return sorted(out)


def main(argv):
    verbose = '-v' in argv
    args = [a for a in argv if a != '-v']
    if not args:
        env = os.environ.get('DVD_ISO_DIR')
        if not env:
            sys.exit('usage: auto_pick_model.py [-v] <iso-or-dir> ...  (or set DVD_ISO_DIR)')
        args = [env]
    cases = collections.defaultdict(list)
    for p in gather(args):
        try:
            r = auto_pick(p)
        except Exception as e:                     # unreadable image
            cases['-  unreadable (%s)' % type(e).__name__].append((p, None))
            continue
        cases[classify(r) if r else '-  no title PGCIT'].append((p, r))
    total = sum(len(v) for v in cases.values())
    print('%d images' % total)
    for c in sorted(cases):
        print('%6d  %s' % (len(cases[c]), c))
    if verbose:
        for c in sorted(cases):
            if c.startswith('A') or c.startswith('-'):
                continue
            print('\n== %s' % c)
            for p, r in cases[c]:
                print('   %-50s VTS %d  PGCN %d  eid 0x%02x  programs %d  owners %s  counts %s' % (
                    os.path.basename(p)[:50], r['vtsn'], r['k'], r['eid'], r['nprog'],
                    r['owners'], {t: len(v) for t, v in list(r['tabs'].items())[:8]}))


if __name__ == '__main__':
    main(sys.argv[1:])
