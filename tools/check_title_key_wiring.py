#!/usr/bin/env python3
"""Gate the Title key's no-op on a disc with no Title menu (audit 10b) in dvd/emu.sv.

`bench/dvd/run_title_probe.sh` proves the reader's mount probe raises vmgm_probed /
vmgm_title_ok. Nothing downstream has a bench: emu.sv drops the Title key unless
title_ok is set, and packs both flags into dvd_telem's word 14, which dvd_ctl.cpp
publishes. A module bench is handed the value and cannot see a wrong wire, so this
reads the seam out of the files. It fails if:

  * dvd_iso_reader .vmgm_title_ok / .vmgm_probed are not plain declared nets
    (open or tied off, the key would be dead on every disc or live on all);
  * any `key_title_p <= 1'b1` sits under an `if` that does not test the
    reader's title_ok net (the press would reach the VM and replay the logos);
  * dvd_vm .key_title is not key_title_p (the gate would gate nothing);
  * word 14 bits [15:13] are not {1'b0, title_ok, probed};
  * dvd_ctl.cpp does not read title_probed / title_menu from w[14] bits 13 / 14.

    python3 tools/check_title_key_wiring.py [emu.sv [dvd_ctl.cpp]]   # exit 0 = wired right
    python3 tools/check_title_key_wiring.py --red                    # each mutation must FAIL

⚠ Comments are stripped first: the comment above the gate quotes the old code.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from check_bup_wiring import strip_comments, instantiation_body, port_expr  # noqa: E402

IDENT = re.compile(r'^[A-Za-z_]\w*$')


def set_sites(src, reg):
    """Each `reg <= 1'b1;` with the condition of the `if` that owns it ('' if none)."""
    out = []
    for m in re.finditer(r'\b' + re.escape(reg) + r"\s*<=\s*1'b1\s*;", src):
        head = src[:m.start()]
        # the nearest `if (` ... `)` that this statement follows
        k = head.rfind('if')
        cond = ''
        while k >= 0:
            if re.match(r'if\s*\(', head[k:]) and (k == 0 or not head[k - 1].isalnum()):
                i = head.index('(', k)
                depth = 0
                for j in range(i, len(head)):
                    if head[j] == '(':
                        depth += 1
                    elif head[j] == ')':
                        depth -= 1
                        if depth == 0:
                            cond = head[i + 1:j]
                            break
                break
            k = head.rfind('if', 0, k)
        out.append(cond)
    return out


def check(emu_raw, ctl_raw):
    bad = []
    src = strip_comments(emu_raw)
    rd = instantiation_body(src, 'dvd_iso_reader')
    vm = instantiation_body(src, 'dvd_vm')
    tl = instantiation_body(src, 'dvd_telem')
    if rd is None or vm is None or tl is None:
        return ['dvd_iso_reader / dvd_vm / dvd_telem instance not found in emu.sv']

    nets = {}
    for port in ('vmgm_probed', 'vmgm_title_ok'):
        e = port_expr(rd, port)
        if not e or not IDENT.match(e):
            bad.append("dvd_iso_reader .%s is '%s' -- must be a plain net" % (port, e))
            continue
        if not re.search(r'\bwire\b[^;]*\b' + re.escape(e) + r'\b', src):
            bad.append("net '%s' (.%s) is not declared as a wire" % (e, port))
        nets[port] = e

    kt = port_expr(vm, 'key_title')
    if kt != 'key_title_p':
        bad.append("dvd_vm .key_title is '%s', want key_title_p (the gated pulse)" % kt)

    ok = nets.get('vmgm_title_ok')
    sites = set_sites(src, 'key_title_p')
    if not sites:
        bad.append("no `key_title_p <= 1'b1` found -- the Title key is dead")
    for cond in sites:
        if not ok or not re.search(r'(?<![!~])\b' + re.escape(ok) + r'\b', cond):
            bad.append("key_title_p is set under 'if (%s)' -- it must test %s "
                       "(audit 10b: no Title menu = no-op)" % (' '.join(cond.split()), ok))

    sf = port_expr(tl, 'sched_flags')
    m = re.match(r'^\{(.*)\}$', sf or '', re.S)
    if not m:
        bad.append("dvd_telem .sched_flags is '%s' -- expected a concatenation" % sf)
    elif len(nets) == 2:
        top = [p.strip() for p in m.group(1).split(',')][:3]
        want = ["1'b0", nets['vmgm_title_ok'], nets['vmgm_probed']]
        if top != want:
            bad.append("word 14 bits [15:13] are %s, want {%s}" % (top, ', '.join(want)))

    csrc = strip_comments(ctl_raw)
    for key in ('title_probed', 'title_menu'):
        if '\\"%s\\"' % key not in ctl_raw:
            bad.append('dvd_ctl.cpp: no "%s" JSON key' % key)
    # the two reads, in key order, straight after the bit-12 (ifo_nogood) read
    m = re.search(r'\(w\[14\]\s*>>\s*12\)\s*&\s*1\)\s*,\s*'
                  r'\(unsigned\)\(\(w\[14\]\s*>>\s*(\d+)\)\s*&\s*1\)\s*,\s*'
                  r'\(unsigned\)\(\(w\[14\]\s*>>\s*(\d+)\)\s*&\s*1\)', csrc)
    if not m:
        bad.append('dvd_ctl.cpp: the title_probed/title_menu reads of w[14] do not '
                   'follow the ifo_nogood (bit 12) read')
    elif tuple(int(x) for x in m.groups()) != (13, 14):
        bad.append('dvd_ctl.cpp reads title_probed/title_menu from w[14] bits %s, '
                   'emu.sv packs them at 13/14' % (m.groups(),))
    return bad


MUTATIONS = [
    ('gate dropped', 'emu', r'title_edge && vmgm_title_ok_w\)', 'title_edge)'),
    ('gate inverted', 'emu', r'title_edge && vmgm_title_ok_w\)', 'title_edge && !vmgm_title_ok_w)'),
    ('gate on probed', 'emu', r'title_edge && vmgm_title_ok_w\)', 'title_edge && vmgm_probed_w)'),
    ('port tied', 'emu', r'\.vmgm_title_ok\s*\(\s*vmgm_title_ok_w\s*\)', ".vmgm_title_ok (1'b1)"),
    ('port open', 'emu', r'\.vmgm_probed\s*\(\s*vmgm_probed_w\s*\)', '.vmgm_probed ()'),
    ('undeclared', 'emu', r'wire\s+vmgm_probed_w,\s*vmgm_title_ok_w;', 'wire        vmgm_probed_w;'),
    ('vm ungated', 'emu', r'\.key_title\s*\(\s*key_title_p\s*\)', '.key_title     (title_edge)'),
    ('telem swapped', 'emu', r'vmgm_title_ok_w, vmgm_probed_w, ifo_nogood_w',
     'vmgm_probed_w, vmgm_title_ok_w, ifo_nogood_w'),
    ('ctl wrong bit', 'ctl', r'\(w\[14\] >> 14\) & 1\)', '(w[14] >> 15) & 1)'),
    ('ctl key dropped', 'ctl', r'\\"title_menu\\":%u', '\\"title\\":%u'),
]


def main():
    args = [a for a in sys.argv[1:] if a != '--red']
    emu = args[0] if args else os.path.join(HERE, '..', 'dvd', 'emu.sv')
    ctl = args[1] if len(args) > 1 else os.path.join(HERE, '..', 'main', 'support', 'dvd',
                                                     'dvd_ctl.cpp')
    emu_raw, ctl_raw = open(emu).read(), open(ctl).read()
    if '--red' in sys.argv:
        rc = 0
        if check(emu_raw, ctl_raw):
            print('FAIL: the unmutated files do not pass')
            for b in check(emu_raw, ctl_raw):
                print('  ' + b)
            return 1
        for label, which, pat, rep in MUTATIONS:
            src = emu_raw if which == 'emu' else ctl_raw
            mut, n = re.subn(pat, lambda _m: rep, src, count=1)
            if n == 0:
                print('FAIL %s: the mutation did not apply (anchor moved)' % label)
                rc = 1
                continue
            found = check(mut, ctl_raw) if which == 'emu' else check(emu_raw, mut)
            if found:
                print('ok   %s -> %s' % (label, found[0]))
            else:
                print('FAIL %s: the mutant PASSED' % label)
                rc = 1
        return rc
    bad = check(emu_raw, ctl_raw)
    if bad:
        print('\n'.join('FAIL: ' + b for b in bad))
        return 1
    print('OK: Title key gated on the reader\'s .vmgm_title_ok; word 14 bits 13/14 -> '
          'dvd_ctl.cpp title_probed/title_menu')
    return 0


if __name__ == '__main__':
    sys.exit(main())
