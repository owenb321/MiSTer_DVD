#!/usr/bin/env python3
"""Gate spu_decode's .title_menu seam in emu.sv (Mad Dog McCree's purple blip).

spu_decode hides an expired unit and an early decode only when .title_menu is high:
an in-title multi-button menu (sp_menu_early), not a menu-domain menu and not Force
4:3 Subpics (both stay windowless). spu_window_tb drives the input itself and cannot
see a wrong wire, so this reads it out of emu.sv. It fails if .title_menu is not
exactly `sp_menu_early && !force_43_subp`, or if sp_menu_early stops excluding the
menu domain (`menus_on && !menu_active && hl_menu_seen`).

    python3 tools/check_spu_title_menu_wiring.py [emu.sv]   # exit 0 = wired right
    python3 tools/check_spu_title_menu_wiring.py --red      # each mutation must FAIL

Comments are stripped first: emu.sv's comments quote old code.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from check_bup_wiring import strip_comments, instantiation_body, port_expr  # noqa: E402


def check(emu_raw):
    bad = []
    src = strip_comments(emu_raw)
    sp = instantiation_body(src, 'spu_decode')
    if sp is None:
        return ['spu_decode instance not found in emu.sv']
    tm = port_expr(sp, 'title_menu')
    want = 'sp_menu_early&&!force_43_subp'
    if tm is None:
        bad.append('spu_decode .title_menu is not connected (floats Z)')
    elif re.sub(r'\s+|[()]', '', tm) != want:
        bad.append("spu_decode .title_menu is '%s', want sp_menu_early && !force_43_subp"
                   % ' '.join(tm.split()))
    m = re.search(r'\bwire\s+sp_menu_early\s*=\s*([^;]+);', src)
    if not m or sorted(t.strip() for t in m.group(1).split('&&')) != \
            ['!menu_active', 'hl_menu_seen', 'menus_on']:
        bad.append('sp_menu_early is not menus_on && !menu_active && hl_menu_seen (%s)'
                   % (m.group(1).strip() if m else 'no assign'))
    return bad


MUTATIONS = [
    ('tied off', r'\.title_menu \(sp_menu_early && !force_43_subp\)', ".title_menu (1'b0)"),
    ('menu domain too', r'\.title_menu \(sp_menu_early && !force_43_subp\)',
     '.title_menu ((menus_on && menu_active) || sp_menu_early)'),
    ('force43 too', r'\.title_menu \(sp_menu_early && !force_43_subp\)', '.title_menu (sp_menu_early)'),
    ('dropped', r'\s*\.title_menu \(sp_menu_early && !force_43_subp\),', ''),
    ('early in menus', r'wire        sp_menu_early = menus_on && !menu_active && hl_menu_seen;',
     'wire        sp_menu_early = menus_on && hl_menu_seen;'),
]


def main():
    args = [a for a in sys.argv[1:] if a != '--red']
    emu = args[0] if args else os.path.join(HERE, '..', 'dvd', 'emu.sv')
    raw = open(emu).read()
    if '--red' in sys.argv:
        if check(raw):
            print('FAIL: the unmutated file does not pass:', check(raw))
            return 1
        rc = 0
        for label, pat, rep in MUTATIONS:
            mut, n = re.subn(pat, lambda _m: rep, raw, count=1)
            if n == 0:
                print('FAIL %s: the mutation did not apply (anchor moved)' % label)
                rc = 1
                continue
            found = check(mut)
            print(('ok   %s -> %s' % (label, found[0])) if found else ('FAIL %s: the mutant PASSED' % label))
            rc |= 0 if found else 1
        return rc
    bad = check(raw)
    if bad:
        print('\n'.join('FAIL: ' + b for b in bad))
        return 1
    print('OK: spu_decode .title_menu = sp_menu_early && !force_43_subp')
    return 0


if __name__ == '__main__':
    sys.exit(main())
