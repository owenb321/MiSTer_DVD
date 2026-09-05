#!/usr/bin/env python3
"""docs_check.parse_bits() -- the CONF_STR -> status-bit decoder.

mister.py builds the core's saved-settings blob from this, so a wrong bit span
silently sets the WRONG OPTION on the hardware -- a failure that looks like a
core bug and would be chased there. The expected spans below come from
CLAUDE.md and the emu.sv comments, i.e. from a source independent of the parser.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import docs_check  # noqa: E402

# label -> (start, end), documented independently of the parser
EXPECTED = {
    'Disc Menus': (1, 1),
    'Debug Overlay': (2, 2),          # P1O2
    'Analog Aspect': (3, 4),
    'Audio': (5, 5),
    'Audio Out': (6, 6),              # OX6 -- the X carries no bits
    'SPDIF Byte Order': (7, 7),
    'Video Output': (9, 10),
    '480i Deint': (11, 11),           # OB -- 'B' is base-32 11
    'Frame Drop': (12, 12),
    'Audio Genlock': (13, 13),
    'Line-21 CC': (14, 14),
    'Force 4:3 Subpics': (15, 15),
    'Video Standard': (16, 17),
    'Aspect Ratio': (19, 20),
    'A/V Offset': (21, 23),
    'Film 24p Out': (24, 25),
    'Title VTS Tens': (32, 35),
    'Title VTS Units': (36, 39),
    'Player Language': (40, 43),
    'CC Test Line': (44, 44),
    'D-Pad Seek': (45, 45),
}

fails = 0


def check(name, got, want):
    global fails
    ok = got == want
    print(f"  {'PASS' if ok else 'FAIL'} {name}: {got}" + ('' if ok else f' want {want}'))
    if not ok:
        fails += 1


print('[live CONF_STR from dvd/emu.sv]')
lits = docs_check.extract_conf_str(open(os.path.join(ROOT, 'dvd', 'emu.sv')).read())
table = {lab: (s, e) for lab, s, e, _ in docs_check.parse_bits(lits)}
for label, want in EXPECTED.items():
    check(label, table.get(label), want)

missing = set(EXPECTED) - set(table)
extra = set(table) - set(EXPECTED)
if missing:
    print(f'  FAIL options vanished from CONF_STR: {sorted(missing)}')
    fails += 1
if extra:
    # Not a failure: a new option is expected to appear here one day. Say so
    # loudly, because it also means the manual and this table need updating.
    print(f'  NOTE new option(s) not in this table yet: {sorted(extra)}')

print('[synthetic forms not present in the live CONF_STR]')
cases = [
    ('"O12,Two char,A,B;"', 'Two char', (1, 2)),      # two base-32 chars
    ('"oB,Lower o,A,B;"', 'Lower o', (43, 43)),       # lowercase o adds 32
    ('"P3OX7,Paged X,A,B;"', 'Paged X', (7, 7)),      # page prefix + X skipped
    ('"O[12:4],Range,A,B;"', 'Range', (4, 12)),       # sscanf reads END first
    ('"O[9],Single,A,B;"', 'Single', (9, 9)),
]
for lit, label, want in cases:
    got = {a: (b, c) for a, b, c, _ in docs_check.parse_bits([lit.strip('"')])}
    check(label, got.get(label), want)

print('[rejections -- Main refuses these too]')
for lit in ('"O[3:9],Backwards,A,B;"', '"O[1:0],TooWide,A;"'):
    got = docs_check.parse_bits([lit.strip('"')])
    # end <= start is rejected by user_io_status_bits(); >8 bits likewise
    ok = not got or (got[0][2] - got[0][1] <= 8 and got[0][2] >= got[0][1])
    print(f"  {'PASS' if ok else 'FAIL'} rejects/normalises {lit}")
    if not ok:
        fails += 1

print('test_status_bits:', 'ALL GREEN' if not fails else f'{fails} FAILURE(S)')
sys.exit(1 if fails else 0)
