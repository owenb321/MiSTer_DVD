#!/usr/bin/env python3
"""mister.py's key table -- derived from dvd/kbd_map.sv, not transcribed.

If a binding in the RTL has no host-side name, that transport action is simply
unreachable from the harness, and the symptom is "the core ignored my keypress"
-- which reads as a core bug. This asserts every hit[] bit the RTL decodes is
reachable, and spot-checks the PS/2 -> Linux inversion against Main's ev2ps2[].
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import mister  # noqa: E402

fails = 0


def check(name, cond, detail=''):
    global fails
    print(f"  {'PASS' if cond else 'FAIL'} {name}" + (f': {detail}' if detail else ''))
    if not cond:
        fails += 1


print('[every RTL binding is reachable]')
table = mister.kbd_map_table()
names = mister.key_names()
check('kbd_map.sv parsed', len(table) >= 15, f'{len(table)} joy bits decoded')
reachable = set()
for label, code in names.items():
    for bit, codes in table.items():
        for ps2, ext in codes:
            if mister.PS2_TO_LINUX.get((ps2, ext)) == code:
                reachable.add(bit)
missing = sorted(set(table) - reachable)
check('all hit[] bits have a host-side name', not missing,
      f'unreachable bits: {missing}' if missing else f'{len(table)} bits')

print('[every PS/2 code in the RTL has a Linux keycode]')
unmapped = [(hex(c), e) for codes in table.values() for c, e in codes
            if (c, e) not in mister.PS2_TO_LINUX]
check('PS2_TO_LINUX covers the RTL table', not unmapped, str(unmapped))

print('[spot checks against Main ev2ps2[] and the RTL]')
# name -> (linux keycode, why)
for name, code, why in (
        ('display', 32, 'KEY_D -> PS/2 0x23 -> hit[12] B9 Display'),
        ('pause', 57, 'KEY_SPACE -> 0x29 -> hit[4] B1 Pause'),
        ('menu', 59, 'KEY_F1 -> 0x05 -> hit[8] B5 Menu'),
        ('select', 96, 'KP-Enter -> EXT 0x5A -> hit[7] B4 Select'),
        ('up', 103, 'KEY_UP -> EXT 0x75 -> hit[3] D-pad Up'),
        ('osd', 88, 'KEY_F12 -> Main OSD toggle, not a core action')):
    check(f'{name} = {code}', names.get(name) == code, why)

print('[digits select menu buttons]')
check('digit 0 is KEY_0', names.get('0') == 11)
check('digit 1 is KEY_1', names.get('1') == 2)

print('[the two LEVEL actions are present but routed elsewhere]')
# emu.sv masks joy bits 13/14 out of the keyboard path and hands them to
# dpad_seek instead, because an IR "hold" is really ~9 discrete taps a second.
check('fast-fwd named', 'fast-fwd' in names)
check('rewind named', 'rewind' in names)

print('test_key_table:', 'ALL GREEN' if not fails else f'{fails} FAILURE(S)')
sys.exit(1 if fails else 0)
