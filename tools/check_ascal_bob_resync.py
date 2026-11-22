#!/usr/bin/env python3
"""Gate for the ascal Bob resync (docs/field_blend.md "ascal Bob resync").

ascal triple-buffers an interlaced input in two chains (o_ibuf0/o_obuf0 and
o_ibuf1/o_obuf1). Weave advances them on alternate fields; bob writes and reads
every field through one of them. Stock only re-aligns the chains while the input is
progressive (`IF o_inter='0'`), so Bob switched on over an already-interlaced input
could leave them offset: combed output, no line doubling. The fix aligns them while
bob is on as well. sys/ascal.vhd has no bench, so this reads the line out of it:

  [1] the block that sets o_ibuf1<=o_ibuf0 and o_obuf1<=o_obuf0 is guarded by
      o_inter='0' OR o_bob_deint='1'
  [2] o_bob_deint is the output-domain copy of the bob_deint port

    python3 tools/check_ascal_bob_resync.py [--red] [ascal.vhd]
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def strip(src):
    return re.sub(r'--[^\n]*', '', src)


def norm(s):
    return re.sub(r'\s+', '', s).lower()


def check(raw):
    src = strip(raw)
    bad = []
    m = re.search(r"IF\s+([^;]*?)\s+THEN\s+o_ibuf1\s*<=\s*o_ibuf0\s*;\s*o_obuf1\s*<=\s*o_obuf0\s*;",
                  src, re.I)
    if not m:
        bad.append(('1', 'the o_ibuf1<=o_ibuf0 / o_obuf1<=o_obuf0 block was not found'))
    else:
        terms = set(norm(m.group(1)).split('or'))
        if terms != {"o_inter='0'", "o_bob_deint='1'"}:
            bad.append(('1', "the chain resync is guarded by '%s' -- must be "
                             "o_inter='0' OR o_bob_deint='1'" % m.group(1).strip()))
    if not re.search(r'\bo_bob_deint\s*<=\s*bob_deint\s*;', src, re.I):
        bad.append(('2', 'o_bob_deint is not the copy of bob_deint'))
    return bad


MUTATIONS = [
    ('M1 stock guard', r"IF o_inter='0' OR o_bob_deint='1' THEN", "IF o_inter='0' THEN", {'1'}),
    ('M1b AND not OR', r"IF o_inter='0' OR o_bob_deint='1' THEN",
     "IF o_inter='0' AND o_bob_deint='1' THEN", {'1'}),
    ('M2 bob copy tied off', r"o_bob_deint <= bob_deint;", "o_bob_deint <= '0';", {'2'}),
]


def main():
    args = [a for a in sys.argv[1:] if a != '--red']
    path = args[0] if args else os.path.join(ROOT, 'sys', 'ascal.vhd')
    raw = open(path).read()
    bad = check(raw)
    if bad:
        for arm, msg in bad:
            print('FAIL [%s] %s' % (arm, msg))
        return 1
    print("OK: ascal re-aligns its field buffer chains while bob is on")
    if '--red' not in sys.argv:
        return 0
    rc = 0
    for label, pat, rep, want in MUTATIONS:
        if pat not in raw:
            print('FAIL %s: the mutation did not apply (anchor moved)' % label)
            rc = 1
            continue
        got = {a for a, _ in check(raw.replace(pat, rep, 1))}
        if got != want:
            print('FAIL %s: failed arms %s, want %s' % (label, sorted(got), sorted(want)))
            rc = 1
        else:
            print('ok   %s (failed exactly %s)' % (label, sorted(got)))
    return rc


if __name__ == '__main__':
    sys.exit(main())
