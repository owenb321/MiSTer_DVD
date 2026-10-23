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
    low-water compare (`vbuf_fill_s1 <= 8'h01`);
  * nav_trace's .x_ev/.x_pl are not the X0..X1 hooks: x_ev = {1'b0, nav_pci
    .dbg_fb_promo, .dbg_rj}, and the payloads carry 1 / .dbg_rj_ok in bit 0 (X2 tied
    off). A tie-off of X0/X1 would leave the HIL harness's #176 events silently absent.

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

    tr = instantiation_body(src, 'nav_trace')
    if tr is None:
        bad.append('nav_trace instance not found in emu.sv')
        return bad
    xe, xp = port_expr(tr, 'x_ev'), port_expr(tr, 'x_pl')
    if (xe or '').strip() != 'trc_x_ev' or (xp or '').strip() != 'trc_x_pl':
        bad.append("nav_trace .x_ev/.x_pl are '%s'/'%s', want trc_x_ev/trc_x_pl" % (xe, xp))
    nets = {}
    for port in ('dbg_rj', 'dbg_rj_ok', 'dbg_fb_promo'):
        e = (port_expr(np, port) or '').strip()
        if not IDENT.match(e):
            bad.append("nav_pci .%s is '%s' -- must be a plain net" % (port, e))
        nets[port] = e
    m = re.search(r'\bwire\s*\[2:0\]\s*trc_x_ev\s*=\s*([^;]+);', src)
    want = "{1'b0,%s,%s}" % (nets['dbg_fb_promo'], nets['dbg_rj'])
    if not m or re.sub(r'\s+', '', m.group(1)) != want:
        bad.append('trc_x_ev is not %s (%s)' % (want, m.group(1).strip() if m else 'no assign'))
    m = re.search(r'\bwire\s*\[77:0\]\s*trc_x_pl\s*=\s*([^;]+);', src)
    pl = re.sub(r'\s+', '', m.group(1)) if m else ''
    want_pl = "{26'd0,{hl_nxt_sptm_w[24:0],1'b1},{hl_nxt_sptm_w[24:0],%s}}" % nets['dbg_rj_ok']
    if pl != want_pl:
        bad.append('trc_x_pl is %s, want %s' % (pl or 'no assign', want_pl))
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
    ('trace x tied', r'\.x_ev\s*\(trc_x_ev\)', ".x_ev        (3'd0)"),
    ('trace x swap', r"\{1'b0, hl_fb_promo_w, hl_rj_w\}", "{1'b0, hl_rj_w, hl_fb_promo_w}"),
    ('trace rj open', r'\.dbg_rj\s*\(hl_rj_w\)', '.dbg_rj        ()'),
    ('trace pl no verdict', r'\{hl_nxt_sptm_w\[24:0\], hl_rj_ok_w\}', '{hl_nxt_sptm_w[25:0]}'),
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
          'low-water mark; nav_trace X0-X1')
    return 0


if __name__ == '__main__':
    sys.exit(main())
