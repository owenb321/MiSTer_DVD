#!/usr/bin/env python3
"""cell_cmd_btn_scan.py -- find TITLE cells whose cell command runs while buttons are up
(issue #176): the cells whose cell command the reader holds until the display reaches the
cell's end, instead of running it when the reader finishes reading the cell.

For every VTS and every title PGC, lists each cell that has a cell command and no still
time (a still cell already waits out its hold before its command runs) and whose last
LOOKBACK seconds carry an HLI with buttons in at least one NAV pack. Those are the cells
where a button pressed in the cell's last second can change what the cell command decides
(Mad Dog McCree: a button sets g[0], the cell command scores it).

    tools/cell_cmd_btn_scan.py [--lookback S] [-v] <iso|dir>...

One line per hit:
    <iso> VTSn pgc=N cell=N dur=S.ss nav_btns=N/M btn_ns=N e_ptm_to_end=S.ss set_only=0|1
        cmd: <the cell command, decoded>

  nav_btns      NAV packs with buttons / NAV packs walked in the last LOOKBACK seconds
  e_ptm_to_end  seconds from the last HLI's hli_e_ptm to the cell's last vobu_e_ptm
                ('forever' for 0xFFFFFFFF)
  set_only      1 = an HLI in those NAV packs is a SCORING highlight (hli_setonly: every
                button Set-or-nothing, at least one Set -- dvd/nav_pci.sv's test); with
                held=1 that cell's window arms early (nav_pci EARLY_LEAD).
  (old)         was: at least one of the buttons has a command that neither links nor
                jumps (it only sets a register) -- the shape whose effect a later cell
                command reads

The summary at the end splits the cells by what the reader does with their command
(CLASSES: held or not, and why) and counts discs and cells. Damaged images are reported
on stderr and skipped.

Limits: language-independent title domain only (menus keep their own loop semantics); an
interleaved (angle / seamless-branch) cell is listed like any other, though the reader does
not hold those; whether a cell is ever reached is not checked.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nav_extract as ne   # noqa: E402

be16, be32 = ne.be16, ne.be32
DSI = 0x407                 # DSI packet data, sector-relative
PREV_VOBU = DSI + 0x13E     # vobu_sri.prev_vobu


def bcd(x):
    return (x >> 4) * 10 + (x & 0x0F)


def pbtm_secs(b):
    """C_PBTM (4 BCD bytes, frame byte carries the rate in its top two bits) -> seconds."""
    rate = 30.0 if (b[3] >> 6) == 3 else 25.0
    return bcd(b[0]) * 3600 + bcd(b[1]) * 60 + bcd(b[2]) + bcd(b[3] & 0x3F) / rate


def title_pgcs(f, ifo):
    f.seek(ifo * 2048)
    mat = f.read(2048)
    vobs, pgcit = be32(mat, 0xC4), be32(mat, 0xCC)
    if not pgcit:
        return 0, []
    base = (ifo + pgcit) * 2048
    f.seek(base)
    n = be16(f.read(8), 0)
    out = []
    for j in range(min(n, 999)):
        f.seek(base + 8 + j * 8)
        out.append((j + 1, base + be32(f.read(8), 4)))
    return ifo + vobs, out


def pgc_cells_and_cmds(f, pa):
    f.seek(pa)
    p = f.read(236)
    nc, cto, cpo = p[3], be16(p, 228), be16(p, 232)
    cells, cmds = [], []
    if nc and cpo:
        f.seek(pa + cpo)
        cb = f.read(nc * 24)
        cells = [cb[i * 24:(i + 1) * 24] for i in range(nc) if len(cb) >= (i + 1) * 24]
    if cto:
        f.seek(pa + cto)
        h = f.read(8)
        npre, npost, ncell = be16(h, 0), be16(h, 2), be16(h, 4)
        f.seek(pa + cto + 8 + (npre + npost) * 8)
        raw = f.read(ncell * 8)
        cmds = [raw[i * 8:(i + 1) * 8] for i in range(ncell)]
    return cells, cmds


def cmd_fixed(cmd):
    """True when a cell command's verdict cannot depend on anything a button press
    changes: the reader runs it at once instead of holding it for the display
    (dvd/dvd_iso_reader.sv cc_fixed_w mirrors this field for field, issue #176).

    Unconditional (compare op, byte1[6:4], is 0) AND either
      - type 0 (byte0[7:5]): Nop / Goto / Break / SetTmpPML, or
      - type 1 jump (byte0[4] = 1): Exit, JumpTT, JumpVTS_*, JumpSS, CallSS, or
      - type 1 link (byte0[4] = 0) with a fixed target: link op (byte1[3:0]) 0
        (none), 4 LinkPGCN, 5 LinkPTTN, 6 LinkPGN, 7 LinkCN, or 1 (LinkSIns) with
        any sub-instruction (byte7[4:0]) but NextC 2, NextPG 6, TailPGC 13 and
        RSM 16. Those four can land in the POST commands or a resume, which read
        registers.
    Types 2-6 all carry a Set, which reads registers: held."""
    b0, b1, b7 = cmd[0], cmd[1], cmd[7]
    if (b1 >> 4) & 7:
        return False
    typ = b0 >> 5
    if typ == 0:
        return True
    if typ != 1:
        return False
    if b0 & 0x10:
        return True
    op = b1 & 0x0F
    if op in (0, 4, 5, 6, 7):
        return True
    return op == 1 and (b7 & 0x1F) not in (2, 6, 13, 16)


CLASSES = (
    ('cond', 'conditional: held (a continuing verdict restarts from a drained VBUF)'),
    ('post', 'NextC/NextPG/TailPGC/RSM: held (POST or a resume reads registers)'),
    ('set', 'carries a Set (types 2-6): held'),
    ('loop', 'fixed loop to its own cell/program: not held (gapless replay kept)'),
    ('nolink', 'fixed, no link (Nop/Goto/Break): not held'),
    ('link', 'fixed link/jump elsewhere: not held (drained before executing anyway)'),
)


def cmd_class(cmd, cell):
    """Which CLASSES row a cell command falls in (cell = its 1-based cell number)."""
    b0, b1, b7 = cmd[0], cmd[1], cmd[7]
    if (b1 >> 4) & 7:
        return 'cond'
    if not cmd_fixed(cmd):
        return 'post' if (b0 >> 5) == 1 else 'set'
    if (b0 >> 5) == 0 or ((b0 >> 5) == 1 and not b0 & 0x10 and (b1 & 0x0F) == 0):
        return 'nolink'
    if (b0 >> 5) == 1 and not b0 & 0x10:
        op, sub = b1 & 0x0F, b7 & 0x1F
        if (op == 1 and sub in (1, 5)) or (op == 7 and b7 == cell):
            return 'loop'
    return 'link'


def btn_kind(c):
    """'none', 'set' or 'link' for one 8-byte BUTTON command -- the test dvd/nav_pci.sv
    applies as the HLI streams past (fb_set / fb_link, issue #176)."""
    t = c[0] >> 5
    if t == 0:
        return 'none'
    if t in (2, 3):
        return 'set' if (c[1] & 0x0F) == 0 else 'link'
    if t in (4, 5, 6):
        return 'set' if c[7] == 0 else 'link'
    return 'link'


def hli_setonly(pci):
    """A SCORING highlight: every button is Set-or-nothing and at least one sets. Its
    buttons do nothing by themselves; a later command reads what they set."""
    ns = pci[0x71] & 0x3F
    kinds = [btn_kind(pci[0x8E + b * 18 + 10:0x8E + b * 18 + 18]) for b in range(ns)]
    return ns > 0 and 'link' not in kinds and 'set' in kinds


def is_link(cmd):
    s = ne.decode_vmcmd(cmd)
    return any(k in s for k in ('Link', 'Jump', 'Call', 'Exit', 'Break', 'Goto'))


def scan_cell(f, vobs, cell, lookback):
    first, lvs = be32(cell, 8), be32(cell, 16)
    rbn, walked, hits, last_hli, set_only, btn_ns, end_ptm = lvs, 0, 0, None, False, 0, None
    while walked < 64:
        f.seek((vobs + rbn) * 2048)
        s = f.read(2048)
        if not ne.is_nav_pack(s):
            break
        pci = s[0x2D:]
        if end_ptm is None:
            end_ptm = be32(pci, 0x10)
        walked += 1
        ss, ns = be16(pci, 0x60) & 3, pci[0x71] & 0x3F
        if ss and ns:
            hits += 1
            btn_ns = max(btn_ns, ns)
            if last_hli is None:
                last_hli = be32(pci, 0x66)
            if hli_setonly(pci):
                set_only = True
        if end_ptm - be32(pci, 0x0C) >= lookback * 90000:
            break
        back = be32(s, PREV_VOBU)
        ok, off = ne.sri_offset(back)
        if not ok or off == 0 or rbn - off < first:
            break
        rbn -= off
    return walked, hits, btn_ns, last_hli, end_ptm, set_only


def selfcheck(iso):
    """Cross-check cmd_fixed() against the decoder's own text over EVERY title cell
    command on a disc: a fixed command must decode with no condition, no Set and no
    link that can reach POST; a held one must show one of those. Returns the
    disagreements."""
    bad = []
    with open(iso, 'rb') as f:
        for v in range(1, 100):
            try:
                ifo = ne.find_vts_ifo(f, v)
            except SystemExit:
                break
            for pgcn, pa in title_pgcs(f, ifo)[1]:
                for cmd in pgc_cells_and_cmds(f, pa)[1]:
                    txt = ne.decode_vmcmd(cmd)
                    if '?' in txt or 'WARNING' in txt:
                        continue                 # malformed: not a claim either way
                    reads = (txt.startswith('if (') or ' = ' in txt or '=' in txt.split(' ')[0]
                             or any(k in txt for k in ('NextC', 'NextPG ', 'TailPGC',
                                                       'RSM', 'SetSTN', 'SetHL_BTNN',
                                                       'SetAMXMode', 'SetGPRMMD',
                                                       'SetNVTMR', ' += ', ' -= ',
                                                       ' *= ', ' /= ', ' %= ', ' &= ',
                                                       ' |= ', ' ^= ', ' <-> ', ' rnd ')))
                    if cmd_fixed(cmd) == reads:
                        bad.append('%s VTS%d pgc=%d %s fixed=%d: %s'
                                   % (os.path.basename(iso), v, pgcn, cmd.hex(),
                                      cmd_fixed(cmd), txt))
    return bad


def scan(iso, lookback, verbose, held_only=False):
    hits = []
    with open(iso, 'rb') as f:
        for v in range(1, 100):          # spec max: 99 title sets
            try:
                ifo = ne.find_vts_ifo(f, v)
            except SystemExit:
                break
            vobs, pgcs = title_pgcs(f, ifo)
            for pgcn, pa in pgcs:
                cells, cmds = pgc_cells_and_cmds(f, pa)
                for i, c in enumerate(cells):
                    still, nr = c[2], c[3]
                    if nr == 0 or still != 0 or nr > len(cmds):
                        continue
                    walked, nb, ns, eptm, endp, so = scan_cell(f, vobs, c, lookback)
                    if not nb:
                        continue
                    fx = cmd_fixed(cmds[nr - 1])
                    if held_only and fx:
                        continue
                    to_end = ('forever' if eptm == 0xFFFFFFFF else
                              '%.2f' % ((endp - eptm) / 90000.0))
                    line = ('%s VTS%d pgc=%d cell=%d dur=%.2f nav_btns=%d/%d btn_ns=%d '
                            'e_ptm_to_end=%s set_only=%d held=%d\n    cmd: %s'
                            % (os.path.basename(iso), v, pgcn, i + 1, pbtm_secs(c[4:8]),
                               nb, walked, ns, to_end, so, not fx,
                               ne.decode_vmcmd(cmds[nr - 1])))
                    print(line, flush=True)
                    hits.append((so, cmd_class(cmds[nr - 1], i + 1), not fx))
    return hits


def isos(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, _, files in os.walk(p):
                for n in sorted(files):
                    if n.lower().endswith('.iso'):
                        yield os.path.join(root, n)
        else:
            yield p


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--lookback', type=float, default=3.0)
    ap.add_argument('-v', action='store_true')
    ap.add_argument('--held', action='store_true',
                    help='list only the cells the reader holds (cmd_fixed is False)')
    ap.add_argument('--selfcheck', action='store_true',
                    help='cross-check cmd_fixed() against the decoded text on every '
                         'title cell command; exit 1 on any disagreement')
    ap.add_argument('paths', nargs='+')
    a = ap.parse_args()
    ndisc = nhit = ncell = nset = 0
    ccells, cdiscs = {}, {}
    nscore = nscored = 0
    rc = 0
    if a.selfcheck:
        nbad = 0
        for iso in isos(a.paths):
            ndisc += 1
            try:
                bad = selfcheck(iso)
            except Exception as e:       # a damaged image must not stop a sweep
                print('%s ERR %s' % (os.path.basename(iso), e), file=sys.stderr)
                continue
            for b in bad:
                print('MISMATCH ' + b)
            nbad += len(bad)
        print('# selfcheck: %d images, %d disagreements' % (ndisc, nbad))
        return 1 if nbad else 0
    for iso in isos(a.paths):
        ndisc += 1
        try:
            h = scan(iso, a.lookback, a.v, a.held)
        except Exception as e:           # a damaged image must not stop a sweep
            print('%s ERR %s' % (os.path.basename(iso), e), file=sys.stderr)
            rc = 1
            continue
        if h:
            nhit += 1
            ncell += len(h)
            nset += sum(so for so, _, _ in h)
            for _, k, _ in h:
                ccells[k] = ccells.get(k, 0) + 1
            for k in set(k for _, k, _ in h):
                cdiscs[k] = cdiscs.get(k, 0) + 1
            sc = sum(1 for so, _, held in h if so and held)
            if sc:
                nscore += sc
                nscored += 1
    for k, label in CLASSES:
        print('# %-6s %6d cells %4d images  %s' % (k, ccells.get(k, 0), cdiscs.get(k, 0), label))
    print('# scoring (held command + scoring highlight, arms early): %d cells on %d images'
          % (nscore, nscored))
    print('# %d images, %d with hits, %d cells (%d with a scoring highlight)'
          % (ndisc, nhit, ncell, nset))
    return rc


if __name__ == '__main__':
    sys.exit(main())
