#!/usr/bin/env python3
"""check_spdif_bs_hold_wiring.py -- the post-reset hold on BOTH bitstream legs.

WHY THIS IS A SCRIPT AND NOT A BENCH (2026-09-23)
-------------------------------------------------
Every audio-track switch and aud_flush pulses rst_audio_n, which cold-resets
iec61937_wrap mid-burst and re-phases its subframe pacing (measured: 509 clk_audio
instead of 512 for the first pair -- iec61937_wrap_tb TEST 9). emu.sv's `bs_hold`
mutes the bitstream for ~100 ms across that so a receiver sees clean silence and ONE
switch instead of a torn burst (docs/iec61937.md finding 3).

The HDMI leg had that hold from the start. The optical S/PDIF leg did not:

    assign SPDIF_PASS_EN = pass_mode;                          // pre-fix
    assign SPDIF_PASS_EN = pass_mode & ~|bs_hold;              // fixed

The defect is one term in a bare `assign` to a pin mux. It has no port a module
bench could drive and emu.sv has no bench at all, so this reads the connection out of
dvd/emu.sv (the check_hl_btnn_wiring.py / check_frame_step_wiring.py pattern).

It also refuses the WRONG-DIRECTION fix. hdmi_bs_ack is the HPS's report that the
ADV7513's I2C non-PCM register is set; S/PDIF carries its non-PCM flag in-band, per
block, and has no such register. `SPDIF_PASS_EN = pass_mode & hdmi_bs_ack & ...`
reads like symmetry and silences optical passthrough on every rig whose HDMI sink
has not acked -- which includes every stock-Main rig and every sink without AC-3.

Traps written against (both paid for elsewhere in this tree):
  1. strip_comments() FIRST. The comment block above these assigns quotes the
     pre-fix line and names hdmi_bs_ack in prose; a grep would read both.
  2. Token sets, never substrings: `bs_hold` vs `bs_hold_n`, `pass_mode` vs
     `pass_mode_q` would otherwise match each other.
A lookup that finds nothing, or finds two drivers, is a NAMED FAIL, never a skip.

Exit 0 = wired as designed; 1 = a named failure. Optional argv[1] = a file to check
instead of dvd/emu.sv, so a runner can mutate a copy in $TMP and never touch the tree.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


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
            out.append(''.join(ch if ch == '\n' else ' ' for ch in src[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def assigns_of(src, name):
    """Every RHS of `assign <name> = ...;` (whitespace-collapsed)."""
    pat = re.compile(r'\bassign\s+' + re.escape(name) + r'\s*=\s*([^;]*);')
    return [re.sub(r'\s+', ' ', m.group(1)).strip() for m in pat.finditer(src)]


def terms(expr):
    return set(re.findall(r'[A-Za-z_][A-Za-z0-9_]*', expr))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dvd', 'emu.sv')
    src = strip_comments(open(path).read())
    fails = []

    def one(name):
        rhs = assigns_of(src, name)
        if len(rhs) != 1:
            fails.append(f'{name}: expected exactly one continuous assign, found {len(rhs)}')
            return None
        return rhs[0]

    hdmi = one('HDMI_BS_EN')
    spdif = one('SPDIF_PASS_EN')

    if hdmi is not None:
        missing = {'pass_mode', 'hdmi_bs_ack', 'bs_hold'} - terms(hdmi)
        if missing:
            fails.append(f'HDMI_BS_EN lost {sorted(missing)} -- the HDMI leg\'s own '
                         f'post-reset hold / ack gate regressed: `{hdmi}`')

    if spdif is not None:
        t = terms(spdif)
        if 'bs_hold' not in t:
            fails.append('SPDIF_PASS_EN is not gated on bs_hold -- a track switch puts '
                         'the cold-reset wrapper\'s torn bursts on the optical output '
                         f'(docs/iec61937.md finding 3): `{spdif}`')
        if 'pass_mode' not in t:
            fails.append(f'SPDIF_PASS_EN no longer requires pass_mode: `{spdif}`')
        if 'hdmi_bs_ack' in t:
            fails.append('SPDIF_PASS_EN is coupled to hdmi_bs_ack -- that is the '
                         'ADV7513\'s I2C register, which optical does not have; it '
                         'silences S/PDIF passthrough on any rig whose HDMI has not '
                         f'acked: `{spdif}`')

    if fails:
        for f in fails:
            print(f'FAIL: {f}')
        return 1
    print(f'OK: both bitstream legs hold across an audio reset '
          f'(HDMI_BS_EN = {hdmi}; SPDIF_PASS_EN = {spdif})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
