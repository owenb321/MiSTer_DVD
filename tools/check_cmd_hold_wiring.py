#!/usr/bin/env python3
"""Gate the cell-command hold's emu.sv seam (issue #176).

`bench/dvd/run_cmd_hold.sh` proves the reader holds a title cell command while
.cc_btns is high, until .vbuf_empty says the display has caught up. The bench drives
both inputs itself, so it cannot see a wrong wire in emu.sv. This reads the seam out of
the file. It fails if:

  * dvd_iso_reader .cc_btns is not exactly the OR of the two nets on nav_pci's
    .btns_armed and .btns_pend (armed alone misses a window that opens in the cell's
    last second, still pending when the reader reaches the cell end; a tie-off turns the
    hold off on every disc, or on every cell);
  * nav_pci .btns_armed / .btns_pend are not plain declared nets;
  * dvd_iso_reader .vbuf_empty is not the `vbuf_empty` register assigned from the VBUF
    low-water compare (`vbuf_fill_s1 <= 8'h01`).

    python3 tools/check_cmd_hold_wiring.py [emu.sv]   # exit 0 = wired right
    python3 tools/check_cmd_hold_wiring.py --red      # each mutation must FAIL

Comments are stripped first: emu.sv's comments quote old code.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from check_bup_wiring import strip_comments, instantiation_body, port_expr  # noqa: E402

IDENT = re.compile(r'^[A-Za-z_]\w*$')


def check(emu_raw):
    bad = []
    src = strip_comments(emu_raw)
    rd = instantiation_body(src, 'dvd_iso_reader')
    np = instantiation_body(src, 'nav_pci')
    if rd is None or np is None:
        return ['dvd_iso_reader / nav_pci instance not found in emu.sv']

    nets = []
    for port in ('btns_armed', 'btns_pend'):
        e = port_expr(np, port)
        if not e or not IDENT.match(e.strip()):
            bad.append("nav_pci .%s is '%s' -- must be a plain net" % (port, e))
            continue
        e = e.strip()
        if not re.search(r'\bwire\b[^;]*\b' + re.escape(e) + r'\b', src):
            bad.append("net '%s' (nav_pci .%s) is not declared as a wire" % (e, port))
        nets.append(e)

    cc = port_expr(rd, 'cc_btns')
    if cc is None:
        bad.append('dvd_iso_reader .cc_btns is not connected (floats Z: the hold never runs)')
    elif len(nets) == 2:
        expr = re.sub(r'\s+', '', cc)
        expr = re.sub(r'^\((.*)\)$', r'\1', expr)
        terms = expr.split('|')
        if sorted(terms) != sorted(nets) or '||' in expr:
            bad.append("dvd_iso_reader .cc_btns is '%s', want %s | %s (buttons on screen "
                       "OR on the way)" % (' '.join(cc.split()), nets[0], nets[1]))

    ve = port_expr(rd, 'vbuf_empty')
    if ve is None or ve.strip() != 'vbuf_empty':
        bad.append("dvd_iso_reader .vbuf_empty is '%s', want vbuf_empty" % ve)
    if not re.search(r"\bvbuf_empty\s*<=\s*\(\s*vbuf_fill_s1\s*<=\s*8'h01\s*\)\s*;", src):
        bad.append("vbuf_empty is not assigned from (vbuf_fill_s1 <= 8'h01)")
    return bad


MUTATIONS = [
    ('armed only', r'\.cc_btns\s*\(hl_btns_armed \| hl_btns_pend\)', '.cc_btns        (hl_btns_armed)'),
    ('pend only', r'\.cc_btns\s*\(hl_btns_armed \| hl_btns_pend\)', '.cc_btns        (hl_btns_pend)'),
    ('AND', r'\.cc_btns\s*\(hl_btns_armed \| hl_btns_pend\)', '.cc_btns        (hl_btns_armed & hl_btns_pend)'),
    ('tied off', r'\.cc_btns\s*\(hl_btns_armed \| hl_btns_pend\)', ".cc_btns        (1'b0)"),
    ('tied on', r'\.cc_btns\s*\(hl_btns_armed \| hl_btns_pend\)', ".cc_btns        (1'b1)"),
    ('port dropped', r'\.cc_btns\s*\(hl_btns_armed \| hl_btns_pend\),', ''),
    ('pend open', r'\.btns_pend\s*\(hl_btns_pend\)', '.btns_pend  ()'),
    ('vbuf tied', r'\.vbuf_empty\s*\(vbuf_empty\)', ".vbuf_empty     (1'b1)"),
    ('vbuf threshold', r"vbuf_empty <= \(vbuf_fill_s1 <= 8'h01\);", "vbuf_empty <= (vbuf_fill_s1 <= 8'h40);"),
]


def main():
    args = [a for a in sys.argv[1:] if a != '--red']
    emu = args[0] if args else os.path.join(HERE, '..', 'dvd', 'emu.sv')
    emu_raw = open(emu).read()
    if '--red' in sys.argv:
        base = check(emu_raw)
        if base:
            print('FAIL: the unmutated file does not pass')
            for b in base:
                print('  ' + b)
            return 1
        rc = 0
        for label, pat, rep in MUTATIONS:
            mut, n = re.subn(pat, lambda _m: rep, emu_raw, count=1)
            if n == 0:
                print('FAIL %s: the mutation did not apply (anchor moved)' % label)
                rc = 1
                continue
            found = check(mut)
            if found:
                print('ok   %s -> %s' % (label, found[0]))
            else:
                print('FAIL %s: the mutant PASSED' % label)
                rc = 1
        return rc
    bad = check(emu_raw)
    if bad:
        print('\n'.join('FAIL: ' + b for b in bad))
        return 1
    print('OK: reader .cc_btns = nav_pci btns_armed | btns_pend; .vbuf_empty = the '
          'low-water mark')
    return 0


if __name__ == '__main__':
    sys.exit(main())
