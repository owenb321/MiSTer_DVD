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
  * nav_pci .early_ok is not the plain declared net on dvd_iso_reader .cc_scoring (the
    scoring-window lead would be off on every disc, or on for every set-only HLI);
  * dvd_iso_reader .cc_aud_low is not `cc_aud_low`, assigned `aud_ring_low & cc_aud_live`
    (without the ring-low term the hold starves the audio at every scoring join; without
    the liveness term an audio-less title releases every hold at once);
  * nav_trace's .x_ev/.x_pl are not the X0..X2 hooks: x_ev = the three levels
    {cc_aud_low, nav_pci .dbg_nxt_early, .dbg_h_so} XOR their registered copies (an
    event on either edge), each payload carrying its level in bit 0. A tie-off would
    leave the HIL harness's #176 events silently absent.

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

    cs = port_expr(rd, 'cc_scoring')
    eo = port_expr(np, 'early_ok')
    cs = cs.strip() if cs else cs
    eo = eo.strip() if eo else eo
    if not cs or not IDENT.match(cs):
        bad.append("dvd_iso_reader .cc_scoring is '%s' -- must be a plain net" % cs)
    elif not re.search(r'\bwire\b[^;]*\b' + re.escape(cs) + r'\b', src):
        bad.append("net '%s' (.cc_scoring) is not declared as a wire" % cs)
    if eo != cs:
        bad.append("nav_pci .early_ok is '%s', want the reader's .cc_scoring net '%s'" % (eo, cs))

    al = port_expr(rd, 'cc_aud_low')
    if al is None or al.strip() != 'cc_aud_low':
        bad.append("dvd_iso_reader .cc_aud_low is '%s', want cc_aud_low" % al)
    m = re.search(r'\bwire\s+cc_aud_low\s*=\s*([^;]+);', src)
    if not m or sorted(t.strip() for t in m.group(1).split('&')) != ['aud_ring_low', 'cc_aud_live']:
        bad.append("cc_aud_low is not assigned aud_ring_low & cc_aud_live (%s)"
                   % (m.group(1).strip() if m else 'no assign'))

    tr = instantiation_body(src, 'nav_trace')
    if tr is None:
        bad.append('nav_trace instance not found in emu.sv')
        return bad
    xe, xp = port_expr(tr, 'x_ev'), port_expr(tr, 'x_pl')
    if (xe or '').strip() != 'trc_x_ev' or (xp or '').strip() != 'trc_x_pl':
        bad.append("nav_trace .x_ev/.x_pl are '%s'/'%s', want trc_x_ev/trc_x_pl" % (xe, xp))
    so, ne_ = port_expr(np, 'dbg_h_so'), port_expr(np, 'dbg_nxt_early')
    so = (so or '').strip(); ne_ = (ne_ or '').strip()
    lv = '{cc_aud_low,%s,%s}' % (ne_, so)
    q = re.search(r'\btrc_x_q\s*<=\s*(\{[^;]*\})\s*;', src)
    if not so or not ne_:
        bad.append('nav_pci .dbg_h_so / .dbg_nxt_early are not connected')
    elif not q or re.sub(r'\s+', '', q.group(1)) != lv:
        bad.append('trc_x_q is not registered from %s' % lv)
    m = re.search(r'\bwire\s*\[2:0\]\s*trc_x_ev\s*=\s*([^;]+);', src)
    if not m or re.sub(r'\s+', '', m.group(1)) != lv + '^trc_x_q':
        bad.append('trc_x_ev is not %s ^ trc_x_q (%s)' % (lv, m.group(1).strip() if m else 'no assign'))
    m = re.search(r'\bwire\s*\[77:0\]\s*trc_x_pl\s*=\s*([^;]+);', src)
    pl = re.sub(r'\s+', '', m.group(1)) if m else ''
    for lvl in ('cc_aud_low', ne_, so):
        if lvl and not re.search(re.escape(lvl) + r'\}', pl):
            bad.append('trc_x_pl does not carry %s in its payload bit 0' % lvl)
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
    ('early tied', r'\.early_ok\s*\(cc_scoring_w\)', ".early_ok     (1'b1)"),
    ('early open', r'\.early_ok\s*\(cc_scoring_w\)', '.early_ok     ()'),
    ('early on btns', r'\.early_ok\s*\(cc_scoring_w\)', '.early_ok     (hl_btns_armed)'),
    ('scoring open', r'\.cc_scoring\s*\(cc_scoring_w\)', '.cc_scoring     ()'),
    ('aud low tied', r'\.cc_aud_low\s*\(cc_aud_low\)', ".cc_aud_low     (1'b0)"),
    ('aud low no live', r'wire cc_aud_low  = aud_ring_low & cc_aud_live;', 'wire cc_aud_low  = aud_ring_low;'),
    ('trace x tied', r'\.x_ev\s*\(trc_x_ev\)', ".x_ev        (3'd0)"),
    ('trace x level', r'\{cc_aud_low, hl_nxt_early_w, hl_h_so_w\} \^ trc_x_q', '{cc_aud_low, hl_nxt_early_w, hl_h_so_w}'),
    ('trace x swap', r'trc_x_q <= \{cc_aud_low, hl_nxt_early_w, hl_h_so_w\}', 'trc_x_q <= {cc_aud_low, hl_h_so_w, hl_nxt_early_w}'),
    ('trace h_so open', r'\.dbg_h_so\s*\(hl_h_so_w\)', '.dbg_h_so      ()'),
    ('trace pl no level', r'\{hl_nxt_sptm_w\[24:0\], hl_nxt_early_w\}', '{hl_nxt_sptm_w[25:0]}'),
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
          'low-water mark; nav_pci .early_ok = reader .cc_scoring')
    return 0


if __name__ == '__main__':
    sys.exit(main())
