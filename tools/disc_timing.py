#!/usr/bin/env python3
"""disc_timing.py -- the authored timing of one title PGC as JSON: the ground truth a
real-time HIL run is scored against (docs/hil_play_harness.md).

    tools/disc_timing.py <iso> <vts> <pgcn> [--cells 2 3] [--every-nav] [-o out.json]

For each cell: its still time, authored duration, sector range (absolute ISO LBA, so a
reference copy of the cell can be cut with `dd`), first and last PTS (vobu_s_ptm of its
first VOBU, vobu_e_ptm of its last), whether the PTS restarts against the previous cell,
its cell command (decoded), and every highlight it commits: hli_ss, hli_s_ptm,
hli_e_ptm (null = 0xFFFFFFFF, "until replaced"), btn_sl_e_ptm, the button count,
fosl/foac, whether the highlight is a scoring one (every button Set-or-nothing, at least
one Set -- dvd/nav_pci.sv's test), and each button's rectangle, links and command.

A NAV pack adds an entry only when it commits a highlight: hli_ss 1 (new) or 3 (equal,
but new commands). hli_ss 2 (equal: a continuation) and 0 (none) add none unless
--every-nav; the cell's `nav_count` still counts every pack walked, so a
cell with no highlight reads `hli: []` with a non-zero `nav_count`, never as a parse
that found nothing.

Runs with the standard library only (plus nav_extract / iso_nav_check from this
directory), so it can be copied to the board and run against an image there.

The IFO walk and the button classification repeat a few lines of
tools/cell_cmd_btn_scan.py (issue #176's branch) rather than importing it, so this tool
does not depend on that branch landing first. When both are on main, import instead.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nav_extract as ne   # noqa: E402

be16, be32 = ne.be16, ne.be32
FOREVER = 0xFFFFFFFF
MAX_NAV_PER_CELL = 20000      # a 9 h cell at 0.4 s VOBUs is ~81k; past this we say so


def _dec(c):
    try:
        return ne.decode_vmcmd(c)
    except Exception:          # an op the decoder does not know: keep the bytes
        return 'RAW ' + c.hex()


def _bcd(x):
    return (x >> 4) * 10 + (x & 0x0F)


def pbtm_secs(b):
    """C_PBTM (4 BCD bytes; the frame byte's top two bits carry the rate) -> seconds."""
    rate = 30.0 if (b[3] >> 6) == 3 else 25.0
    return _bcd(b[0]) * 3600 + _bcd(b[1]) * 60 + _bcd(b[2]) + _bcd(b[3] & 0x3F) / rate


def btn_kind(c):
    """'none', 'set' or 'link' for an 8-byte button command (nav_pci fb_set / fb_link)."""
    t = c[0] >> 5
    if t == 0:
        return 'none'
    if t in (2, 3):
        return 'set' if (c[1] & 0x0F) == 0 else 'link'
    if t in (4, 5, 6):
        return 'set' if c[7] == 0 else 'link'
    return 'link'


def title_pgc_addr(f, ifo, pgcn):
    f.seek(ifo * 2048)
    mat = f.read(2048)
    vobs, pgcit = be32(mat, 0xC4), be32(mat, 0xCC)
    if not pgcit:
        sys.exit('VTS has no title PGCIT')
    base = (ifo + pgcit) * 2048
    f.seek(base)
    n = be16(f.read(8), 0)
    if not 1 <= pgcn <= n:
        sys.exit('PGCN %d out of range (VTS has %d)' % (pgcn, n))
    f.seek(base + 8 + (pgcn - 1) * 8)
    return ifo + vobs, base + be32(f.read(8), 4), n


def pgc_cells_and_cmds(f, pa):
    f.seek(pa)
    p = f.read(236)
    nc, cto, cpo = p[3], be16(p, 228), be16(p, 232)
    cells, pre, post, ccmds = [], [], [], []
    if nc and cpo:
        f.seek(pa + cpo)
        cb = f.read(nc * 24)
        cells = [cb[i * 24:(i + 1) * 24] for i in range(nc) if len(cb) >= (i + 1) * 24]
    if cto:
        f.seek(pa + cto)
        h = f.read(8)
        npre, npost, ncell = be16(h, 0), be16(h, 2), be16(h, 4)
        raw = f.read((npre + npost + ncell) * 8)
        allc = [raw[i * 8:(i + 1) * 8] for i in range(npre + npost + ncell)]
        pre, post, ccmds = allc[:npre], allc[npre:npre + npost], allc[npre + npost:]
    return p, cells, pre, post, ccmds


def buttons(pci):
    out = []
    for b in range(pci[0x71] & 0x3F):
        e = pci[0x8E + b * 18:0x8E + b * 18 + 18]
        w0 = (e[0] << 16) | (e[1] << 8) | e[2]
        w1 = (e[3] << 16) | (e[4] << 8) | e[5]
        out.append({'n': b + 1,
                    'x1': (w0 >> 12) & 0x3FF, 'x2': w0 & 0x3FF,
                    'y1': (w1 >> 12) & 0x3FF, 'y2': w1 & 0x3FF,
                    'coln': (w0 >> 22) & 3, 'auto': (w1 >> 22) & 3,
                    'up': e[6] & 0x3F, 'dn': e[7] & 0x3F,
                    'lf': e[8] & 0x3F, 'rt': e[9] & 0x3F,
                    'kind': btn_kind(e[10:18]), 'cmd': _dec(e[10:18])})
    return out


def hli_entry(lba, pci):
    ss = be16(pci, 0x60) & 3
    btns = buttons(pci) if ss else []
    kinds = [b['kind'] for b in btns]
    e_ptm = be32(pci, 0x66)
    return {'lba': lba, 'vobu_s_ptm': be32(pci, 0x0C), 'vobu_e_ptm': be32(pci, 0x10),
            'ss': ss,
            's_ptm': be32(pci, 0x62) if ss else None,
            'e_ptm': (None if e_ptm == FOREVER else e_ptm) if ss else None,
            'sl_e_ptm': be32(pci, 0x6A) if ss else None,
            'btn_ns': pci[0x71] & 0x3F if ss else 0,
            'fosl': pci[0x74] & 0x3F, 'foac': pci[0x75] & 0x3F,
            'setonly': bool(btns) and 'link' not in kinds and 'set' in kinds,
            'buttons': btns}


def walk_cell(f, vobs, c, every_nav):
    """Every NAV pack of a cell, forward via vobu_sri next_vobu."""
    rbn, last = be32(c, 8), be32(c, 20)
    navs, hli, n, first_ptm, end_ptm, err = 0, [], 0, None, None, None
    while rbn <= last:
        if n >= MAX_NAV_PER_CELL:
            err = 'stopped after %d NAV packs (MAX_NAV_PER_CELL)' % n
            break
        f.seek((vobs + rbn) * 2048)
        s = f.read(2048)
        if not ne.is_nav_pack(s):
            err = 'rbn %d is not a NAV pack' % rbn
            break
        pci = s[0x2D:0x2D + 979]
        navs += 1
        if first_ptm is None:
            first_ptm = be32(pci, 0x0C)
        end_ptm = be32(pci, 0x10)
        ss = be16(pci, 0x60) & 3
        if every_nav or ss in (1, 3):
            hli.append(hli_entry(vobs + rbn, pci))
        ok, off = ne.sri_offset(be32(s, 0x541))
        if not ok or off == 0:
            break
        rbn += off
        n += 1
    return navs, hli, first_ptm, end_ptm, err


def dump(iso, vts, pgcn, want=(), every_nav=False):
    with open(iso, 'rb') as f:
        ifo = ne.find_vts_ifo(f, vts)
        vobs, pa, npgc = title_pgc_addr(f, ifo, pgcn)
        p, cells, pre, post, ccmds = pgc_cells_and_cmds(f, pa)
        out = {'iso': os.path.basename(iso), 'vts': vts, 'pgcn': pgcn, 'pgcs_in_vts': npgc,
               'pgc_dur': pbtm_secs(p[4:8]), 'ptm_hz': 90000,
               'pre': [_dec(c) for c in pre], 'post': [_dec(c) for c in post],
               'cells': []}
        prev_end = None
        for ci, c in enumerate(cells):
            nr = c[3]
            ent = {'cell': ci + 1, 'still': c[2], 'dur': pbtm_secs(c[4:8]),
                   'cat': '%02x%02x' % (c[0], c[1]),
                   'lba_first': vobs + be32(c, 8), 'lba_last': vobs + be32(c, 20),
                   'cmd_nr': nr,
                   'cmd': _dec(ccmds[nr - 1]) if nr and nr <= len(ccmds) else None}
            if not want or ci + 1 in want:
                navs, hli, fp, ep, err = walk_cell(f, vobs, c, every_nav)
                ent.update({'first_ptm': fp, 'end_ptm': ep, 'nav_count': navs, 'hli': hli})
                # a restart: this cell's first PTS does not continue the previous one's end
                # (within 10 ms). Unknown when the previous cell was not walked.
                ent['pts_restart'] = (None if prev_end is None or fp is None
                                      else abs(fp - prev_end) > 900)
                if err:
                    ent['walk_error'] = err
                prev_end = ep
            else:
                prev_end = None
            out['cells'].append(ent)
    return out


_CMP = re.compile(r'^if \(g\[(\d+)\] (!=|==) (0x[0-9a-f]+|\d+)\)')
_SET = re.compile(r'^SetMode Register g\[(\d+)\] = (0x[0-9a-f]+|\d+)$')


def _num(x):
    return int(x, 16) if x.startswith('0x') else int(x)


def homing(buttons):
    """A tap sequence that lands on ONE button from any start, using the authored links
    (a grid whose edge links point back at themselves): Up until nothing moves, then
    Left until nothing moves. Returns (taps, home button) or None if it does not
    converge."""
    B = {b['n']: b for b in buttons}
    cur = set(B)
    taps = []
    for d, key in (('up', 'up'), ('lf', 'left')):
        for _ in range(len(B)):
            nxt = {B[n][d] if B[n][d] in B else n for n in cur}
            if nxt == cur:
                break
            cur = nxt
            taps.append(key)
    return (taps, cur.pop()) if len(cur) == 1 else None


def path(buttons, src, dst):
    """Shortest tap path from src to dst along the authored links (BFS)."""
    B = {b['n']: b for b in buttons}
    prev, todo = {src: None}, [src]
    for n in todo:
        if n == dst:
            break
        for d, key in (('up', 'up'), ('dn', 'down'), ('lf', 'left'), ('rt', 'right')):
            m = B[n][d]
            if m in B and m not in prev:
                prev[m] = (n, key)
                todo.append(m)
    if dst not in prev:
        return None
    out, n = [], dst
    while prev[n]:
        n, key = prev[n]
        out.append(key)
    return out[::-1]


def scoring_targets(iso, vts_list=None):
    """Every scoring window in the title domain with the button(s) that satisfy its
    cell command (`if (g[R] != K) Link...` and a button `SetMode Register g[R] = K`),
    and the taps that aim at the first of them from any selection. Windows whose
    command has another shape are listed with targets [] (aim impossible), never
    silently dropped."""
    out = []
    with open(iso, 'rb') as f:
        vtss = vts_list or range(1, 100)
        for v in vtss:
            try:
                ifo = ne.find_vts_ifo(f, v)
            except SystemExit:
                break
            _, _, npgc = title_pgc_addr(f, ifo, 1)
            for pg in range(1, npgc + 1):
                d = dump(iso, v, pg)
                for c in d['cells']:
                    m = _CMP.match(c['cmd'] or '')
                    for h in c['hli']:
                        if not h['btn_ns']:
                            continue
                        tg = []
                        if m:
                            # `!= K Link`: survive by setting g[R] = K. `== K Link`: survive
                            # by setting g[R] to anything else.
                            reg, op, val = int(m.group(1)), m.group(2), _num(m.group(3))
                            for b in h['buttons']:
                                sm = _SET.match(b['cmd'])
                                if sm and int(sm.group(1)) == reg and (
                                        (_num(sm.group(2)) == val) == (op == '!=')):
                                    tg.append(b['n'])
                        hm = homing(h['buttons'])
                        aim = None
                        if tg and hm:
                            pth = path(h['buttons'], hm[1], tg[0])
                            aim = None if pth is None else hm[0] + pth
                        if not tg and not h['setonly']:
                            continue        # an ordinary menu highlight, not a shot
                        frm = {}
                        if tg:
                            for b in h['buttons']:
                                pth = path(h['buttons'], b['n'], tg[0])
                                if pth is not None:
                                    frm[str(b['n'])] = pth
                        out.append({'vts': v, 'pgcn': pg, 'cell': c['cell'], 'from': frm,
                                    's_ptm': h['s_ptm'], 'e_ptm': h['e_ptm'],
                                    'fosl': h['fosl'], 'targets': tg, 'aim': aim,
                                    'cmd': c['cmd']})
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('iso')
    ap.add_argument('vts', type=int)
    ap.add_argument('pgcn', type=int)
    ap.add_argument('--cells', type=int, nargs='*', default=[],
                    help='walk only these cells\' NAV packs (all cells are still listed)')
    ap.add_argument('--every-nav', action='store_true',
                    help='one entry per NAV pack, including hli_ss 0/3')
    ap.add_argument('-o', '--out')
    a = ap.parse_args()
    d = dump(a.iso, a.vts, a.pgcn, set(a.cells), a.every_nav)
    s = json.dumps(d, indent=1)
    if a.out:
        with open(a.out, 'w') as f:
            f.write(s + '\n')
    else:
        print(s)


if __name__ == '__main__':
    main()
