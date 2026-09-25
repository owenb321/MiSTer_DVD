#!/usr/bin/env python3
"""Gate for the D-pad TIME seek (Phase 8b reopened, issue #127): check that emu.sv
hands the reader the right time, on the right pulse, and keeps it on the HUD.

WHY THIS EXISTS
---------------
bench/dvd/iso_reader_tmap_tb.sv proves the reader's time-map lookup, but it is
HANDED seek_tm_req / seek_tm_secs, and emu.sv has no bench. Each of these compiles,
passes every module bench, and quietly breaks the feature:
  * .seek_tm_req on seek_rbn_pulse (the ARBITRATED pulse): mode_realign's own
    re-align seeks share it, and would be taken as time seeks to a stale time;
  * .seek_tm_secs not seek_time's D-pad answer: the reader seeks to one time while
    the HUD previews another -- the defect this feature exists to remove;
  * dpad_tm_v set outside a DVD title (a linear file, a menu): a time map that is
    not the playing title's, or none;
  * seek_time's bar left ungated / the HUD mux not holding the answer: after the
    fire the preview becomes an interpolation of the fallback sector again.

Reads the connections out of dvd/emu.sv with the comment-stripping parser of
tools/check_hl_btnn_wiring.py (a grep would match the comments quoting them).

    python3 tools/check_tmap_seek_wiring.py [emu.sv]
    python3 tools/check_tmap_seek_wiring.py --red   # must FAIL main's emu.sv and
                                                    # each re-regression
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..')
sys.path.insert(0, HERE)
from check_hl_btnn_wiring import strip_comments, instantiation_body  # noqa: E402


def port_expr(body, port):
    m = re.search(r'\.' + re.escape(port) + r'\s*\(', body or '')
    if not m:
        return None
    i, depth = m.end() - 1, 0
    for j in range(i, len(body)):
        if body[j] == '(':
            depth += 1
        elif body[j] == ')':
            depth -= 1
            if depth == 0:
                return ' '.join(body[i + 1:j].split())
    return None


def toks(e):
    return set(re.findall(r'[A-Za-z_]\w*', e or ''))


def check(path):
    src = strip_comments(open(path).read())
    bad = []
    rd = instantiation_body(src, 'dvd_iso_reader')
    req = port_expr(rd, 'seek_tm_req')
    if req is None:
        return ['dvd_iso_reader has no .seek_tm_req: no seek is ever a time seek']
    if toks(req) != {'scrub_seek_pulse', 'dpad_tm_v'}:
        bad.append("dvd_iso_reader .seek_tm_req is '%s' -- must be scrub_seek_pulse & dpad_tm_v "
                   "(seek_rbn_pulse also carries mode_realign's sector seeks)" % req)
    if port_expr(rd, 'seek_tm_secs') != 'dpad_tm_s':
        bad.append("dvd_iso_reader .seek_tm_secs is '%s', must be dpad_tm_s" % port_expr(rd, 'seek_tm_secs'))

    # (the reset also assigns it: look for the latch among every assignment)
    if 'seek_prev_secs_w' not in [x.strip() for x in re.findall(r'dpad_tm_s\s*<=\s*([^;]*);', src)]:
        bad.append("dpad_tm_s is not latched from seek_time's answer (seek_prev_secs_w)")
    m = re.search(r'dpad_tm_v\s*<=\s*(cell_ready[^;]*);', src)
    if not m or not {'cell_ready', 'menu_active', 'seek_prev_ok_w'} <= toks(m.group(1)) \
            or '!menu_active' not in m.group(1).replace(' ', ''):
        bad.append('dpad_tm_v must require cell_ready && !menu_active && seek_prev_ok_w')

    st = instantiation_body(src, 'seek_time')
    ba = port_expr(st, 'bar_active')
    if not ba or not re.search(r'~\s*dpad_hold', ba):
        bad.append("seek_time .bar_active is '%s' -- must be gated by ~dpad_hold" % ba)

    m = re.search(r'wire\s+\[31:0\]\s+hud_prev_time\s*=\s*([^;]*);', src)
    if not m or not re.match(r'\(\s*dpad_hold\s*\|\|\s*dpad_pend\s*\)\s*\?\s*seek_prev_time_w', m.group(1).strip()):
        bad.append('hud_prev_time does not hold seek_time\'s answer while dpad_hold')
    m = re.search(r'wire\s+hud_prev_ok\s*=\s*([^;]*);', src)
    if not m or not m.group(1).strip().startswith('dpad_hold'):
        bad.append('hud_prev_ok does not keep the preview up while dpad_hold')
    return bad


def red():
    emu = open(os.path.join(ROOT, 'dvd', 'emu.sv')).read()
    if check(os.path.join(ROOT, 'dvd', 'emu.sv')):
        print('  GREEN FAILS on the working tree -- fix that first')
        return 1
    rc = 0
    cases = []
    try:
        cases.append(('R0 main\'s emu.sv out of git',
                      subprocess.run(['git', '-C', ROOT, 'show', 'main:dvd/emu.sv'],
                                     capture_output=True, text=True, check=True).stdout))
    except subprocess.CalledProcessError:
        pass
    muts = [
        ('R1 qualifier on the arbitrated pulse', '.seek_tm_req    (scrub_seek_pulse & dpad_tm_v),',
         '.seek_tm_req    (seek_rbn_pulse & dpad_tm_v),'),
        ('R2 the time is not seek_time\'s', 'dpad_tm_s     <= seek_prev_secs_w;', 'dpad_tm_s     <= 17\'d0;'),
        ('R3 time seeks outside a DVD title', 'dpad_tm_v     <= cell_ready && !menu_active && seek_prev_ok_w;',
         'dpad_tm_v     <= seek_prev_ok_w;'),
        ('R4 seek_time bar left ungated', '.bar_active      (bar_active_w & ~dpad_hold),',
         '.bar_active      (bar_active_w),'),
        ('R5 HUD does not hold the answer', 'wire [31:0] hud_prev_time = (dpad_hold || dpad_pend) ? seek_prev_time_w',
         'wire [31:0] hud_prev_time = (dpad_pend) ? seek_prev_time_w'),
    ]
    for label, a, b in muts:
        if emu.count(a) != 1:
            print('  BROKEN %s: anchor found %d times' % (label, emu.count(a)))
            rc = 1
            continue
        cases.append((label, emu.replace(a, b)))
    cases.append(('R6 connection only in a comment',
                  emu.replace('.seek_tm_req    (scrub_seek_pulse & dpad_tm_v),',
                              ".seek_tm_req    (1'b0), // was (scrub_seek_pulse & dpad_tm_v)")))
    for label, text in cases:
        with tempfile.NamedTemporaryFile('w', suffix='.sv', delete=False) as f:
            f.write(text)
            tmp = f.name
        bad = check(tmp)
        os.unlink(tmp)
        print(('  ok     %s -> %s' % (label, bad[0])) if bad else ('  MISSED %s' % label))
        rc |= 0 if bad else 1
    return rc


def main():
    if sys.argv[1:2] == ['--red']:
        return red()
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dvd', 'emu.sv')
    bad = check(path)
    if bad:
        print('\n'.join('FAIL: ' + b for b in bad))
        return 1
    print('OK: D-pad time seeks reach the reader on the scrub pulse, and the HUD holds their time')
    return 0


if __name__ == '__main__':
    sys.exit(main())
