#!/usr/bin/env python3
"""Gate for the IFO header gate's flags (audit item 8, docs/dvd_nav.md "IFO header
gate and .BUP fallback"): check that emu.sv carries the reader's three sticky
flags into telemetry word 14, and that the Main reads them from the same bits.

WHY THIS EXISTS
---------------
`iso_reader_bup_tb` proves the reader raises ifo_bup_vmg / ifo_bup_vts /
ifo_nogood. Nothing downstream has a bench: emu.sv packs them into dvd_telem's
.sched_flags, and main/support/dvd/dvd_ctl.cpp unpacks word 14 into JSON. A flag
left open, tied off, or packed at the wrong bit would make a fallback silent --
which is exactly what the "never truncate silently" rule forbids. The plausible
mistakes:

  * a reader port left unconnected or tied to 1'b0;
  * two flags swapped in the concatenation (bup_vmg reported as bup_vts);
  * the Main reading a different bit from the one emu.sv packs.

What is checked:
  * dvd_iso_reader .ifo_bup_vmg/.ifo_bup_vts/.ifo_nogood are plain nets,
    declared, each used nowhere as a constant;
  * dvd_telem .sched_flags is {<pad>, nogood, bup_vts, bup_vmg, pr_rmask_allp,
    core_bob_act, core_sched_flags} -- i.e. the three nets land on bits 12/11/10
    above the existing 10 bits (bits [9:0] are pr_rmask_allp, core_bob_act and
    the 8-bit core_sched_flags);
  * dvd_ctl.cpp reads "bup_vmg"/"bup_vts"/"ifo_nogood" from w[14] >> 10/11/12.

    python3 tools/check_bup_wiring.py [emu.sv [dvd_ctl.cpp]]   # exit 0 = wired right
    python3 tools/check_bup_wiring.py --red                    # each mutation must FAIL

⚠ Walks each instantiation to its matching ')' and strips comments -- do NOT
"simplify" it to a grep: the comment beside .sched_flags spells out the bits.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FLAGS = ('ifo_bup_vmg', 'ifo_bup_vts', 'ifo_nogood')
IDENT = re.compile(r'^[A-Za-z_]\w*$')


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


def port_expr(body, port):
    """The text inside .port( ... ), matching nested parens/braces; None if absent."""
    m = re.search(r'\.' + re.escape(port) + r'\s*\(', body)
    if not m:
        return None
    i = m.end()
    depth = 1
    for j in range(i, len(body)):
        if body[j] in '({':
            depth += 1
        elif body[j] in ')}':
            depth -= 1
            if depth == 0:
                return body[i:j].strip()
    return None


def check(emu_raw, ctl_raw):
    bad = []
    src = strip_comments(emu_raw)
    rd = instantiation_body(src, 'dvd_iso_reader')
    tl = instantiation_body(src, 'dvd_telem')
    if rd is None or tl is None:
        return ['dvd_iso_reader / dvd_telem instance not found in emu.sv']

    nets = {}
    for f in FLAGS:
        e = port_expr(rd, f)
        if not e or not IDENT.match(e):
            bad.append("dvd_iso_reader .%s is '%s' -- must be a plain net (the fallback "
                       "must never be silent)" % (f, e))
            continue
        if not re.search(r'\bwire\b[^;]*\b' + re.escape(e) + r'\b', src):
            bad.append("net '%s' (.%s) is not declared as a wire" % (e, f))
        nets[f] = e

    sf = port_expr(tl, 'sched_flags')
    if not sf:
        return bad + ['dvd_telem .sched_flags not found']
    m = re.match(r'^\{(.*)\}$', sf, re.S)
    if not m:
        return bad + ["dvd_telem .sched_flags is '%s' -- expected a concatenation" % sf]
    parts = [p.strip() for p in m.group(1).split(',')]
    # LSB end: core_sched_flags (8) + core_bob_act + pr_rmask_allp = bits [9:0]
    want_low = ['pr_rmask_allp', 'core_bob_act', 'core_sched_flags']
    if parts[-3:] != want_low:
        bad.append("word 14 bits [9:0] are not {pr_rmask_allp, core_bob_act, "
                   "core_sched_flags}: %s" % parts[-3:])
    elif len(nets) == 3:
        got = parts[-6:-3]
        want = [nets['ifo_nogood'], nets['ifo_bup_vts'], nets['ifo_bup_vmg']]
        if got != want:
            bad.append("word 14 bits [12:10] are %s, want {%s} (nogood, bup_vts, bup_vmg)"
                       % (got, ', '.join(want)))
        # Bits [15:13] above: {1'b0, title_ok, probed} since audit 10b, which
        # tools/check_title_key_wiring.py checks net by net; here only that the
        # word still totals 16 bits.
        pad = parts[:-6]
        if pad != ["1'b0", 'vmgm_title_ok_w', 'vmgm_probed_w']:
            bad.append("word 14 above bit 12 is %s, want {1'b0, vmgm_title_ok_w, "
                       "vmgm_probed_w} (16 bits total)" % pad)

    csrc = strip_comments(ctl_raw)
    for key, bit in (('bup_vmg', 10), ('bup_vts', 11), ('ifo_nogood', 12)):
        if '\\"%s\\"' % key not in ctl_raw:
            bad.append('dvd_ctl.cpp: no "%s" JSON key' % key)
    # the three reads, in key order, straight after the bit-9 (rgn_allp) read
    m = re.search(r'\(w\[14\]\s*>>\s*9\)\s*&\s*1\)\s*,\s*'
                  r'\(unsigned\)\(\(w\[14\]\s*>>\s*(\d+)\)\s*&\s*1\)\s*,\s*'
                  r'\(unsigned\)\(\(w\[14\]\s*>>\s*(\d+)\)\s*&\s*1\)\s*,\s*'
                  r'\(unsigned\)\(\(w\[14\]\s*>>\s*(\d+)\)\s*&\s*1\)', csrc)
    if not m:
        bad.append('dvd_ctl.cpp: the bup_vmg/bup_vts/ifo_nogood reads of w[14] '
                   'do not follow the rgn_allp (bit 9) read')
    elif tuple(int(x) for x in m.groups()) != (10, 11, 12):
        bad.append('dvd_ctl.cpp reads bup_vmg/bup_vts/ifo_nogood from w[14] bits %s, '
                   'emu.sv packs them at 10/11/12' % (m.groups(),))
    return bad


MUTATIONS = [
    ('vmg port open', 'emu', r'\.ifo_bup_vmg\s*\(\s*ifo_bup_vmg_w\s*\)', '.ifo_bup_vmg ()'),
    ('vts tied off', 'emu', r'\.ifo_bup_vts\s*\(\s*ifo_bup_vts_w\s*\)', ".ifo_bup_vts (1'b0)"),
    ('nogood undeclared', 'emu', r'wire\s+ifo_bup_vmg_w,\s*ifo_bup_vts_w,\s*ifo_nogood_w;',
     'wire        ifo_bup_vmg_w, ifo_bup_vts_w;'),
    ('vmg/vts swapped', 'emu', r'ifo_nogood_w, ifo_bup_vts_w, ifo_bup_vmg_w, pr_rmask_allp',
     'ifo_nogood_w, ifo_bup_vmg_w, ifo_bup_vts_w, pr_rmask_allp'),
    ('flag off telemetry', 'emu', r"vmgm_probed_w, ifo_nogood_w, ", "vmgm_probed_w, 1'b0, "),
    ('ctl wrong bit', 'ctl', r'\(w\[14\] >> 11\) & 1\)', '(w[14] >> 13) & 1)'),
    ('ctl key dropped', 'ctl', r'\\"ifo_nogood\\":%u', '\\"nogood\\":%u'),
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
    print('OK: reader .ifo_bup_vmg/.ifo_bup_vts/.ifo_nogood -> telemetry word 14 bits '
          '10/11/12 -> dvd_ctl.cpp bup_vmg/bup_vts/ifo_nogood')
    return 0


if __name__ == '__main__':
    sys.exit(main())
