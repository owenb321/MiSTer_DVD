#!/usr/bin/env python3
"""check_audio_off_wiring.py -- Audio Off silences passthrough too (issue #197).

THE DEFECT
----------
The OSD's "Audio: On/Off" (O5, status[5]) only fed `aud_dec_en`, the in-fabric
decoder's enable. In Audio Out = Passthru the AC-3/DTS frames go round the decoder to
iec61937_wrap and out of S/PDIF and HDMI as a bitstream, so Off did nothing: a user
reported "Audio: Off doesn't work, audio keeps playing, also after reset".

THE FIX, AND WHY IT IS SHAPED THIS WAY
--------------------------------------
Audio Off folds into the EFFECTIVE pass_mode (`pass_mode = pass_sel & aud_on`), so an
Off session in Passthru is exactly an Off session in Decode -- the path Off has always
taken, decoder parked and driving zeros, both bitstream legs back on the framework's
PCM encoder. Three seams make that true, and each is one token in dvd/emu.sv, which
has no bench:

  * player_regs reads pass_sel, NOT pass_mode. SPRM15 is the player's audio
    capability, which disc programs read to pick a stream; toggling Audio must not
    change it.
  * dvd_telem's af_bs_session is gated on pass_mode. Main engages the ADV7513's
    non-PCM mode on that bit, and aud_route only updates its verdict under split_en,
    so ungated it goes stale when pass_mode falls: Main would keep the chip claimed
    and raise "Sink does not list AC-3/DTS" with nothing playing.
  * every bitstream consumer (both pin enables, the wrapper, aud_route's split)
    reads pass_mode, not pass_sel -- or Off would leave that leg running.

Named arms; `--red` applies one mutation per claim and requires it to fail EXACTLY
its own arm (the set is compared, not just "something failed"). strip_comments()
first: the comments above these lines quote the pre-fix code.

Exit 0 = wired as designed; 1 = a named failure. Optional argv path = a file to check
instead of dvd/emu.sv.
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
    if body is None:
        return None
    m = re.search(r'\.' + re.escape(port) + r'\s*\(', body)
    if not m:
        return None
    i, depth = m.end(), 1
    for j in range(i, len(body)):
        if body[j] == '(':
            depth += 1
        elif body[j] == ')':
            depth -= 1
            if depth == 0:
                return re.sub(r'\s+', ' ', body[i:j]).strip()
    return None


def wire_rhs(src, name):
    """Every RHS of `wire [..] name = ...;` -- a list, so two drivers are visible."""
    pat = re.compile(r'\bwire\s+(?:\[[^\]]*\]\s*)?' + re.escape(name) + r'\s*=\s*([^;]*);')
    return [re.sub(r'\s+', ' ', m.group(1)).strip() for m in pat.finditer(src)]


def assign_rhs(src, name):
    pat = re.compile(r'\bassign\s+' + re.escape(name) + r'\s*=\s*([^;]*);')
    return [re.sub(r'\s+', ' ', m.group(1)).strip() for m in pat.finditer(src)]


def tokens(expr):
    return set(re.findall(r'[A-Za-z_]\w*', expr or ''))


def one(lst, what, arm, bad):
    if len(lst) != 1:
        bad.append((arm, '%s: expected exactly one driver, found %d' % (what, len(lst))))
        return None
    return lst[0]


def check(raw):
    """A list of (arm, message). Empty = wired as designed."""
    src = strip_comments(raw)
    bad = []

    # [1] aud_on is the OSD's O5 bit, inverted (On = 0, the default).
    r = one(wire_rhs(src, 'aud_on'), 'aud_on', '1', bad)
    if r is not None and r.replace(' ', '') != '~status[5]':
        bad.append(('1', "aud_on is '%s' -- must be ~status[5] (O5 Audio On/Off)" % r))

    # [2] the decoder is still parked by it (Off in Decode, and LPCM/MP2 in Passthru).
    r = one(wire_rhs(src, 'aud_dec_en'), 'aud_dec_en', '2', bad)
    if r is not None and r != 'aud_on':
        bad.append(('2', "aud_dec_en is '%s' -- must be aud_on" % r))
    en = port_net(instantiation_body(src, 'dvd_audio_decode'), 'enable')
    if 'aud_dec_en' not in tokens(en):
        bad.append(('2', "dvd_audio_decode .enable is '%s' -- lost aud_dec_en, Off no longer "
                         "parks the decoder" % en))

    # [3] the effective pass_mode carries Audio Off; the selection does not.
    pm = one(wire_rhs(src, 'pass_mode'), 'pass_mode', '3', bad)
    ps = one(wire_rhs(src, 'pass_sel'), 'pass_sel', '3', bad)
    if pm is not None and tokens(pm) != {'pass_sel', 'aud_on'}:
        bad.append(('3', "pass_mode is '%s' -- must be pass_sel & aud_on, or Audio Off leaves "
                         "the bitstream playing (issue #197)" % pm))
    if ps is not None:
        t = tokens(ps)
        if 'status' not in t or 'aud_on' in t or 'pass_mode' in t:
            bad.append(('3', "pass_sel is '%s' -- must be the Passthru selection (status[6] and "
                             "its session guards), without Audio On/Off" % ps))

    # [4] SPRM15 follows the selection, never Audio On/Off.
    # Through pass_dts (= pass_sel & ~hdmi_no_dts, issue #201): still the selection.
    pr = port_net(instantiation_body(src, 'player_regs'), 'pass_mode')
    if pr == 'pass_dts':
        pr = one(wire_rhs(src, 'pass_dts'), 'pass_dts', '4', bad)
    if pr is None or 'pass_sel' not in tokens(pr) or tokens(pr) & {'pass_mode', 'aud_on'}:
        bad.append(('4', "player_regs .pass_mode is '%s' -- must be pass_sel: SPRM15 would "
                         "change when Audio is toggled" % pr))

    # [5] Main is told a bitstream is playing only while one can be.
    bs = port_net(instantiation_body(src, 'dvd_telem'), 'af_bs_session')
    if tokens(bs) != {'rt_bs_session', 'pass_mode'}:
        bad.append(('5', "dvd_telem .af_bs_session is '%s' -- must be rt_bs_session & pass_mode, "
                         "or Main keeps the ADV7513 in non-PCM mode with Audio Off" % bs))

    # [6] every bitstream consumer reads the effective wire.
    consumers = [
        ('HDMI_BS_EN', one(assign_rhs(src, 'HDMI_BS_EN'), 'HDMI_BS_EN', '6', bad)),
        ('SPDIF_PASS_EN', one(assign_rhs(src, 'SPDIF_PASS_EN'), 'SPDIF_PASS_EN', '6', bad)),
        ('iec61937_wrap .enable', port_net(instantiation_body(src, 'iec61937_wrap'), 'enable')),
        ('aud_route .split_en', port_net(instantiation_body(src, 'aud_route'), 'split_en')),
    ]
    for what, expr in consumers:
        t = tokens(expr)
        if 'pass_mode' not in t or 'pass_sel' in t:
            bad.append(('6', "%s is '%s' -- must read pass_mode (not pass_sel), or Audio Off "
                             "leaves that leg running" % (what, expr)))
    return bad


# (label, regex, replacement, the arms it must fail -- exactly)
MUTATIONS = [
    ('M1 aud_on from the wrong bit', r'(wire\s+aud_on\s*=\s*)~status\[5\]', r'\g<1>~status[4]', {'1'}),
    ('M2 decoder enable ignores Audio', r'\.enable\s*\(\s*aud_dec_en\s*&\s*~cb_busy\s*\)',
     '.enable (~cb_busy)', {'2'}),
    ('M3 the pre-fix pass_mode', r'(wire\s+pass_mode\s*=\s*)pass_sel\s*&\s*aud_on', r'\g<1>pass_sel', {'3'}),
    ('M4 pass_sel picks up Audio', r'(wire\s+pass_sel\s*=\s*status\[6\])', r'\g<1> & aud_on', {'3'}),
    ('M5 SPRM15 follows Audio Off', r'\.pass_mode\s*\(\s*pass_dts\s*\)', '.pass_mode (pass_mode)', {'4'}),
    ('M5b pass_dts follows Audio Off', r'(wire\s+pass_dts\s*=\s*)pass_sel', r'\g<1>pass_mode', {'4'}),
    ('M6 af_bs_session ungated', r'\.af_bs_session\s*\(\s*rt_bs_session\s*&\s*pass_mode\s*\)',
     '.af_bs_session (rt_bs_session)', {'5'}),
    ('M7 optical leg on the selection', r'(assign\s+SPDIF_PASS_EN\s*=\s*)pass_mode', r'\g<1>pass_sel', {'6'}),
    ('M8 HDMI leg on the selection', r'(assign\s+HDMI_BS_EN\s*=\s*)pass_mode', r'\g<1>pass_sel', {'6'}),
    ('M9 wrapper enabled by the selection',
     r'(iec61937_wrap_inst\s*\([^;]*?\.enable\s*\(\s*)pass_mode', r'\g<1>pass_sel', {'6'}),
    ('M10 aud_route splits on the selection', r'\.split_en\s*\(\s*pass_mode\s*\)', '.split_en (pass_sel)', {'6'}),
]


def main():
    args = [a for a in sys.argv[1:] if a != '--red']
    path = args[0] if args else os.path.join(ROOT, 'dvd', 'emu.sv')
    raw = open(path).read()
    bad = check(raw)
    if bad:
        for arm, msg in bad:
            print('FAIL [%s] %s' % (arm, msg))
        return 1
    print('OK: Audio Off reaches every bitstream leg; SPRM15 follows the selection; '
          'Main sees no bitstream session while Off')
    if '--red' not in sys.argv:
        return 0
    rc = 0
    for label, pat, rep, want in MUTATIONS:
        mut, n = re.subn(pat, rep, raw, count=1, flags=re.S)
        if n == 0:
            print('FAIL %s: the mutation did not apply (anchor moved)' % label)
            rc = 1
            continue
        got = {arm for arm, _ in check(mut)}
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
