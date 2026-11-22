#!/usr/bin/env python3
"""Gate for HDMI passthrough on I2S-DAC boards (docs/hdmi_bitstream.md §9).

On an MCP23009 board (`mcp_en`, e.g. the SuperStation One) or with SW[0] set, the
analog jack is an I2S DAC on AUDIO_L/R/SPDIF. Stock fed it HDMI_SCLK/I2S/LRCLK, so
the HDMI bitstream was refused on those boards (hdmi_bs_ok had a ~(SW[0] | mcp_en)
term) and HDMI passthrough was silent there. The fix feeds the DAC the PCM
serializer directly and drops the term. sys_top.v has no bench, so this reads it:

  [1] AUDIO_L/R/SPDIF, under (SW[0] | mcp_en), read i2s_bclk/data/lrclk_pcm and
      never HDMI_*: otherwise a bitstream reaches the DAC as full-scale noise.
  [2] hdmi_bs_ok does not read mcp_en or SW: otherwise HDMI passthrough is silent
      on those boards again.
  [3] HDMI_SCLK/LRCLK/I2S are muxed on hdmi_bs_ok between the core's bitstream
      and i2s_*_pcm, so with no bitstream they ARE the DAC's signals (bit-for-bit stock).

    python3 tools/check_hdmi_bs_dac_wiring.py [--red]
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
from check_audio_off_wiring import strip_comments, assign_rhs, wire_rhs, tokens  # noqa: E402

DAC = (('AUDIO_L', 'i2s_bclk_pcm'), ('AUDIO_R', 'i2s_data_pcm'), ('AUDIO_SPDIF', 'i2s_lrclk_pcm'))
HDMI = (('HDMI_SCLK', 'hdmi_bs_sck', 'i2s_bclk_pcm'), ('HDMI_LRCLK', 'hdmi_bs_ws', 'i2s_lrclk_pcm'),
        ('HDMI_I2S', 'hdmi_bs_sd', 'i2s_data_pcm'))


def check(raw):
    src = strip_comments(raw)
    bad = []
    for pin, want in DAC:
        r = assign_rhs(src, pin)
        if len(r) != 1:
            bad.append(('1', '%s: expected one assign, found %d' % (pin, len(r))))
            continue
        t = tokens(r[0])
        if want not in t or any(x.startswith('HDMI_') for x in t):
            bad.append(('1', "%s is '%s' -- the I2S DAC must read %s, not HDMI_*" % (pin, r[0], want)))
    ok = wire_rhs(src, 'hdmi_bs_ok')
    if len(ok) != 1 or tokens(ok[0]) & {'mcp_en', 'SW'} or 'hdmi_bs_en' not in tokens(ok[0]):
        bad.append(('2', "hdmi_bs_ok is %s -- must be hdmi_bs_en with no SW/mcp_en term" % ok))
    for pin, bs, pcm in HDMI:
        r = assign_rhs(src, pin)
        if len(r) != 1 or tokens(r[0]) != {'hdmi_bs_ok', bs, pcm}:
            bad.append(('3', "%s is %s -- must be hdmi_bs_ok ? %s : %s" % (pin, r, bs, pcm)))
    return bad


MUTATIONS = [
    ('M1 DAC back on HDMI_SCLK', r"\? i2s_bclk_pcm  : analog_l", '? HDMI_SCLK  : analog_l', {'1'}),
    ('M1b DAC data on HDMI_I2S', r"\? i2s_data_pcm  : analog_r", '? HDMI_I2S  : analog_r', {'1'}),
    ('M2 the old guard', r'(wire hdmi_bs_ok = )hdmi_bs_en;', r'\g<1>hdmi_bs_en & ~(SW[0] | mcp_en);', {'2'}),
    ('M3 HDMI data off the PCM path', r'(assign HDMI_I2S\s*=\s*hdmi_bs_ok\s*\?\s*hdmi_bs_sd\s*:\s*)i2s_data_pcm',
     r"\g<1>1'b0", {'3'}),
]


def main():
    args = [a for a in sys.argv[1:] if a != '--red']
    path = args[0] if args else os.path.join(ROOT, 'sys', 'sys_top.v')
    raw = open(path).read()
    bad = check(raw)
    if bad:
        for arm, msg in bad:
            print('FAIL [%s] %s' % (arm, msg))
        return 1
    print('OK: the I2S DAC reads the PCM serializer; HDMI carries a bitstream on every board')
    if '--red' not in sys.argv:
        return 0
    rc = 0
    for label, pat, rep, want in MUTATIONS:
        mut, n = re.subn(pat, rep, raw, count=1)
        if n == 0:
            print('FAIL %s: the mutation did not apply (anchor moved)' % label)
            rc = 1
            continue
        got = {a for a, _ in check(mut)}
        if got != want:
            print('FAIL %s: failed arms %s, want %s' % (label, sorted(got), sorted(want)))
            rc = 1
        else:
            print('ok   %s (failed exactly %s)' % (label, sorted(got)))
    return rc


if __name__ == '__main__':
    sys.exit(main())
