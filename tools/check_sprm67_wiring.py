#!/usr/bin/env python3
"""Gate for SPRM7 following playback (docs/nav_engine.md 5a, docs/dvd_vm.md): check
that emu.sv hands the reader's part of the playing cell to dvd_vm.

WHY THIS EXISTS
---------------
`dvd_vm_tb` [S28] proves the VM takes a part from its ptt_upd / ptt_val ports, and the
reader benches prove the reader publishes one. Each is HANDED its inputs, so a wrong
wire in emu.sv -- which has no bench -- is invisible to both. The plausible ones:

  * the VM's ports tied off (1'b0 / 11'd0): SPRM7 is set only at a jump again, the
    exact defect the 2026-10-08 library sweep found (T3's VTSM read chapter 1);
  * `.ptt_val (cur_pgm_w)`: compiles, and is right on most discs, but it is the HUD's
    readout -- 8 bits clamped at 255, and the per-PGC program on a reverse-map miss
    where libdvdnav (and SPRM7) says 0;
  * the strobe and the value from different sources, or swapped.

What is checked:
  * dvd_iso_reader .ptt_upd and dvd_vm .ptt_upd are the SAME plain net, a 1-bit wire;
  * dvd_iso_reader .ptt_cur and dvd_vm .ptt_val are the SAME plain net, wire [10:0].

    python3 tools/check_sprm67_wiring.py [emu.sv]   # exit 0 = wired right
    python3 tools/check_sprm67_wiring.py --red      # each mutation must FAIL

SPRM6 needs no wire: the VM takes it from cur_pgcn, which it already has.

Walks to each instantiation's matching ')' and strips comments -- do NOT "simplify" it
to a grep: the comments beside these ports name the wrong source (cur_pgm_w).
"""
import os
import re
import sys


def strip_comments(src):
    """Blank out // and /* */ comments, preserving offsets and newlines."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            j = src.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i))
            i = j
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r'[^\n]', ' ', src[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def instantiation_body(src, module):
    m = re.search(r'(?m)^\s*' + re.escape(module) + r'\s+(#\s*\(.*?\)\s*)?\w+\s*\(', src, re.S)
    if not m:
        return None
    i = m.end() - 1
    depth = 0
    for j in range(i, len(src)):
        if src[j] == '(':
            depth += 1
        elif src[j] == ')':
            depth -= 1
            if depth == 0:
                return src[i + 1:j]
    return None


def port_net(body, port):
    """The text inside .port( ... ), with nested parentheses balanced."""
    m = re.search(r'\.' + re.escape(port) + r'\s*\(', body)
    if not m:
        return None
    i = m.end()
    depth = 1
    for j in range(i, len(body)):
        if body[j] == '(':
            depth += 1
        elif body[j] == ')':
            depth -= 1
            if depth == 0:
                return body[i:j].strip()
    return None


IDENT = re.compile(r'^[A-Za-z_]\w*$')


def check(raw):
    src = strip_comments(raw)
    bad = []
    rd = instantiation_body(src, 'dvd_iso_reader')
    vm = instantiation_body(src, 'dvd_vm')
    for name, body in (('dvd_iso_reader', rd), ('dvd_vm', vm)):
        if body is None:
            bad.append('no %s instantiation found' % name)
    if bad:
        return bad

    def declared(net, width):
        if width == 1:
            pat = r'(?m)^\s*wire\s+([\w\s,]*,\s*)?%s\b' % re.escape(net)
        else:
            pat = (r'(?m)^\s*wire\s*\[\s*%d\s*:\s*0\s*\]\s*([\w\s,]*,\s*)?%s\b'
                   % (width - 1, re.escape(net)))
        return re.search(pat, src) is not None

    for rport, vport, width in (('ptt_upd', 'ptt_upd', 1), ('ptt_cur', 'ptt_val', 11)):
        r, v = port_net(rd, rport), port_net(vm, vport)
        if not r or not IDENT.match(r):
            bad.append("dvd_iso_reader .%s is '%s' -- must be a plain net" % (rport, r))
            continue
        if not v or not IDENT.match(v):
            bad.append("dvd_vm .%s is '%s' -- must be a plain net (the reader's .%s)"
                       % (vport, v, rport))
            continue
        if r != v:
            bad.append("dvd_vm .%s (%s) is not the reader's .%s net (%s)" % (vport, v, rport, r))
        elif not declared(r, width):
            bad.append("net '%s' is not declared as a %s wire"
                       % (r, '1-bit' if width == 1 else '[%d:0]' % (width - 1)))
    return bad


MUTATIONS = [
    ('VM strobe tied off', r'\.ptt_upd\s*\(\s*ptt_upd_w\s*\)(\s*,\s*//[^\n]*\n\s*\.ptt_val)',
     r".ptt_upd       (1'b0)\1"),
    ('VM value from the HUD', r'\.ptt_val\s*\(\s*ptt_cur_w\s*\)', '.ptt_val       (cur_pgm_w)'),
    ('reader value open', r'\.ptt_cur\s*\(\s*ptt_cur_w\s*\)', '.ptt_cur        ()'),
    ('VM value tied off', r'\.ptt_val\s*\(\s*ptt_cur_w\s*\)', ".ptt_val       (11'd0)"),
]


def main():
    args = [a for a in sys.argv[1:] if a != '--red']
    path = args[0] if args else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), '..', 'dvd', 'emu.sv')
    raw = open(path).read()
    if '--red' in sys.argv:
        rc = 0
        if check(raw):
            print('FAIL: the unmutated file does not pass')
            return 1
        for label, pat, rep in MUTATIONS:
            mut, n = re.subn(pat, rep, raw, count=1)
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
    bad = check(raw)
    if bad:
        print('\n'.join('FAIL: ' + b for b in bad))
        return 1
    print('OK: dvd_iso_reader .ptt_upd/.ptt_cur -> dvd_vm .ptt_upd/.ptt_val (SPRM7)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
