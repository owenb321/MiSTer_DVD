#!/usr/bin/env python3
"""Gate for issue #201: a DTS track on an HDMI sink that lists AC-3 but not DTS.

MiSTer_DVDcss reads the sink's EDID and sets cfg[15] when it names AC-3 at 48 kHz
and not DTS. The core then decodes DTS to stereo PCM in Passthru (aud_route's
dts_dec), so the sink is not sent a burst it cannot decode. AC-3 keeps
bitstreaming. Both legs carry the PCM: one ring consumer per frame, a user
decision recorded in docs/hdmi_bitstream.md §8.

WHY THIS EXISTS: `aud_route_tb` TEST 7 proves the routing, given dts_dec. Whether
dts_dec IS cfg[15] lives in dvd/emu.sv and sys/hps_io.sv, which have no bench, so
a wrong wire there is invisible to it. Arms:

  [1] sys/hps_io.sv: `assign ini_hdmi_no_dts = cfg[15];`, and emu's hps_io
      instance connects .ini_hdmi_no_dts to hdmi_no_dts.
  [2] aud_route .dts_dec is hdmi_no_dts.
  [3] the DTS "unsupported" notice can fire in Passthru when hdmi_no_dts is set
      (DTS is the decoder's there, so a failed codebook copy must say so).
  [4] dvd_telem .af_no_dts is hdmi_no_dts (0x7B bit 13; bit 14 says it is read).
  [5] hdmi_no_dts is NOT on a leg enable or the PCM mute. The routing does the
      work. Gating HDMI_BS_EN or SPDIF_PASS_EN on it would silence AC-3 too.

    python3 tools/check_dts_sink_wiring.py           # exit 0 = wired as designed
    python3 tools/check_dts_sink_wiring.py --red     # each mutation fails EXACTLY its arm

strip_comments() first: the comments beside these lines quote other wiring.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
from check_audio_off_wiring import (strip_comments, instantiation_body, port_net,  # noqa: E402
                                    wire_rhs, assign_rhs, tokens)


def check(raw, hps_raw):
    src = strip_comments(raw)
    hps = strip_comments(hps_raw)
    bad = []

    # [1]
    a = assign_rhs(hps, 'ini_hdmi_no_dts')
    if len(a) != 1 or a[0].replace(' ', '') != 'cfg[15]':
        bad.append(('1', "sys/hps_io.sv ini_hdmi_no_dts is %s -- must be cfg[15]" % a))
    n = port_net(instantiation_body(src, 'hps_io'), 'ini_hdmi_no_dts')
    if n != 'hdmi_no_dts':
        bad.append(('1', "hps_io .ini_hdmi_no_dts is '%s' -- must be hdmi_no_dts" % n))

    # [2]
    n = port_net(instantiation_body(src, 'aud_route'), 'dts_dec')
    if n != 'hdmi_no_dts':
        bad.append(('2', "aud_route .dts_dec is '%s' -- must be hdmi_no_dts, or DTS is "
                         "bitstreamed to an AC-3-only sink" % n))

    # [3]
    u = wire_rhs(src, 'aud_unsupported')
    if len(u) != 1 or 'hdmi_no_dts' not in tokens(u[0]):
        bad.append(('3', "aud_unsupported does not read hdmi_no_dts -- a DTS track decoded "
                         "for an AC-3-only sink would play silent with no notice"))

    # [4]
    n = port_net(instantiation_body(src, 'dvd_telem'), 'af_no_dts')
    if n != 'hdmi_no_dts':
        bad.append(('4', "dvd_telem .af_no_dts is '%s' -- must be hdmi_no_dts" % n))

    # [5]
    for name, rhs in (('HDMI_BS_EN', assign_rhs(src, 'HDMI_BS_EN')),
                      ('SPDIF_PASS_EN', assign_rhs(src, 'SPDIF_PASS_EN')),
                      ('pcm_mute', wire_rhs(src, 'pcm_mute'))):
        if len(rhs) != 1:
            bad.append(('5', '%s: expected exactly one driver, found %d' % (name, len(rhs))))
        elif 'hdmi_no_dts' in tokens(rhs[0]):
            bad.append(('5', "%s reads hdmi_no_dts ('%s') -- that silences AC-3 as well; "
                             "aud_route's routing is the whole fix" % (name, rhs[0])))
    return bad


# (label, file, regex, replacement, the arms it must fail -- exactly)
MUTATIONS = [
    ('M1 cfg bit 14', 'hps', r'(assign\s+ini_hdmi_no_dts\s*=\s*)cfg\[15\]', r'\g<1>cfg[14]', {'1'}),
    ('M1b port open', 'emu', r'\.ini_hdmi_no_dts\s*\(\s*hdmi_no_dts\s*\)', '.ini_hdmi_no_dts()', {'1'}),
    ('M2 routing tied off', 'emu', r'\.dts_dec\s*\(\s*hdmi_no_dts\s*\)', ".dts_dec (1'b0)", {'2'}),
    ('M3 notice ignores the sink', 'emu', r'~\(pass_mode\s*&\s*~hdmi_no_dts\)', '~pass_mode', {'3'}),
    ('M4 telemetry tied off', 'emu', r'\.af_no_dts\s*\(\s*hdmi_no_dts\s*\)', ".af_no_dts (1'b0)", {'4'}),
    ('M5 HDMI leg gated', 'emu', r'(assign\s+HDMI_BS_EN\s*=\s*)pass_mode', r'\g<1>pass_mode & ~hdmi_no_dts', {'5'}),
    ('M5b optical leg gated', 'emu', r'(assign\s+SPDIF_PASS_EN\s*=\s*)pass_mode',
     r'\g<1>pass_mode & ~hdmi_no_dts', {'5'}),
]


def main():
    args = [a for a in sys.argv[1:] if a != '--red']
    emu_path = args[0] if args else os.path.join(ROOT, 'dvd', 'emu.sv')
    hps_path = args[1] if len(args) > 1 else os.path.join(ROOT, 'sys', 'hps_io.sv')
    raw, hps_raw = open(emu_path).read(), open(hps_path).read()
    bad = check(raw, hps_raw)
    if bad:
        for arm, msg in bad:
            print('FAIL [%s] %s' % (arm, msg))
        return 1
    print('OK: cfg[15] -> hdmi_no_dts -> aud_route .dts_dec, the DTS notice and 0x7B bit 13; '
          'no leg enable reads it')
    if '--red' not in sys.argv:
        return 0
    rc = 0
    for label, which, pat, rep, want in MUTATIONS:
        e, h = raw, hps_raw
        if which == 'emu':
            e, n = re.subn(pat, rep, raw, count=1, flags=re.S)
        else:
            h, n = re.subn(pat, rep, hps_raw, count=1, flags=re.S)
        if n == 0:
            print('FAIL %s: the mutation did not apply (anchor moved)' % label)
            rc = 1
            continue
        got = {arm for arm, _ in check(e, h)}
        if not got:
            print('FAIL %s: the mutant PASSED' % label)
            rc = 1
        elif got != want:
            print('FAIL %s: failed arms %s, want %s' % (label, sorted(got), sorted(want)))
            rc = 1
        else:
            print('ok   %s (failed exactly %s)' % (label, sorted(got)))
    return rc


if __name__ == '__main__':
    sys.exit(main())
