#!/usr/bin/env python3
"""check_field_blend_wiring.py -- the field-blend seams in dvd/emu.sv and
rtl/mpeg2/mpeg2video.v (docs/field_blend.md).

WHY A SCRIPT: every module bench is handed blend_en / the pixel stream by its
parent and is correct for what it is given. What decides whether the feature
reaches the screen -- and ONLY on the progressive raster, and OFF by default --
is a handful of connections no bench instantiates (emu has no bench, and the
chain bench wires field_blend itself). The check_field_order_wiring.py pattern.

WHAT IS PINNED
  emu.sv
    1. exactly one CONF_STR row "O[49],Progressive Deint,Off,Blend;" and no other
       row whose bit range covers 49. Index 0 = Off = the DEFAULT (user decision
       2026-09-24) -- a swapped value order would ship the feature ON.
    2. blend_en = status[49] & ~interlaced_eff. Rejected: a NEGATED status[49]
       (that is the default-ON polarity), and fields_eff / il_eff / p240_eff: 240p
       is a sub-mode of the interlaced raster whose decoder emits FRAMES, so a
       fields_eff gate (what shelved Stage A used) would blend on 240p.
    3. a 2-FF sync of blend_en into clk_dec, and mpeg2video fed the SYNCED net.
    4. the instrument: mpeg2video.blend_act -> core_blend_act -> telemetry flags.
  mpeg2video.v
    5. resample.blend_en(blend_en); resample.scan_blend and field_blend.scan_blend
       are the same net, and so are the two scan_start connections (the sideband
       is useless if its pulse and its bit come from different places).
    6. ORDER: resample -> field_blend -> disp_vscale. field_blend.in_y is
       y_resample, and disp_vscale.in_y is field_blend's out_y -- never y_resample
       (a bypass leaves the module instantiated and inert, which every bench of the
       module would still pass).

Traps (paid for elsewhere): strip_comments() FIRST -- the comments beside these
lines quote the rejected forms on purpose; every test is over TOKENS, never
substrings (`il_eff` is inside `fields_eff`... and `blend_en` inside
`blend_en_dec`); a lookup that returns None is a named FAIL, never a skip.

Usage: check_field_blend_wiring.py [--emu PATH] [--mpeg PATH]   (mutated copies)
Exit 0 = wired as designed, 1 = not.
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def strip_comments(src):
    """Blank out // and /* */ comments, preserving offsets and newlines. String
    literals are kept (CONF_STR rows live in them), and a // inside one is not a
    comment."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            j = i + 1
            while j < n and src[j] != '"' and src[j] != '\n':
                j += 2 if src[j] == '\\' else 1
            out.append(src[i:j + 1])
            i = j + 1
        elif c == '/' and i + 1 < n and src[i + 1] == '/':
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


def connections(src, module):
    """{port: expr} for one module instantiation's named connections."""
    m = re.search(r'\b%s\s+(?:#\s*\([^;]*?\)\s*)?(\w+)\s*\(' % re.escape(module), src)
    if not m:
        return None
    depth, i, n = 0, m.end() - 1, len(src)
    body = None
    while i < n:
        if src[i] == '(':
            depth += 1
        elif src[i] == ')':
            depth -= 1
            if depth == 0:
                body = src[m.end():i]
                break
        i += 1
    if body is None:
        return None
    out, i, n = {}, 0, len(body)
    while i < n:
        if body[i] == '.':
            mm = re.match(r'\.\s*(\w+)\s*\(', body[i:])
            if mm:
                depth, j = 0, i + mm.end() - 1
                while j < n:
                    if body[j] == '(':
                        depth += 1
                    elif body[j] == ')':
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                out[mm.group(1)] = ' '.join(body[i + mm.end():j].split())
                i = j
        i += 1
    return out


def tokens(expr):
    return set(re.findall(r'\w+', expr or ''))


def conf_rows(src):
    """(hi, lo, text) for every O-row string literal: "O[h:l],..", "O[n],..", "Ox,.."."""
    rows = []
    for m in re.finditer(r'"((?:P\d+)?O\[(\d+)(?::(\d+))?\][^"]*)"', src):
        hi = int(m.group(2)); lo = int(m.group(3)) if m.group(3) else hi
        rows.append((hi, lo, m.group(1)))
    for m in re.finditer(r'"((?:P\d+)?O([0-9A-Va-v]{1,2}),[^"]*)"', src):
        ch = m.group(2)
        bits = [int(c, 36) for c in ch]
        rows.append((max(bits), min(bits), m.group(1)))
    return rows


def check_emu(src, rel, bad):
    rows = conf_rows(src)
    ours = [r for r in rows if r[2] == 'O[49],Progressive Deint,Off,Blend;']
    if len(ours) != 1:
        bad('CONF_STR', 'expected exactly one "O[49],Progressive Deint,Off,Blend;" row, '
                        'found %d. Index 0 must be Off (the default). Rows mentioning 49: %s'
                        % (len(ours), [r[2] for r in rows if r[1] <= 49 <= r[0]]))
    others = [r[2] for r in rows if r[1] <= 49 <= r[0] and r[2] != 'O[49],Progressive Deint,Off,Blend;']
    if others:
        bad('CONF_STR', 'another row claims status[49]: %s' % others)

    m = re.search(r'\bwire\s+blend_en\s*=\s*([^;]+);', src)
    if not m:
        bad('blend_en', 'no `wire blend_en = ...;` in %s' % rel)
    else:
        expr = m.group(1)
        tk = tokens(expr)
        if not re.search(r'(?<![~!])\bstatus\s*\[\s*49\s*\]', expr):
            bad('blend_en', '`%s` does not read status[49] UN-negated. Index 1 = Blend, so '
                            'the feature is on when the bit is SET; ~status[49] ships it '
                            'ON by default.' % expr)
        if not re.search(r'~\s*interlaced_eff\b', expr):
            bad('blend_en', '`%s` is not gated on ~interlaced_eff (the progressive raster).' % expr)
        for t in ('fields_eff', 'il_eff', 'p240_eff', 'il_prev', 'fields_prev'):
            if t in tk:
                bad('blend_en', '`%s` uses %s. 240p is a sub-mode of the interlaced raster '
                                'whose decoder emits FRAMES; only ~interlaced_eff excludes it.'
                    % (expr, t))

    if not re.search(r'\bblend_s1_dec\s*<=\s*blend_en\s*;', src) or \
       not re.search(r'\bblend_en_dec\s*<=\s*blend_s1_dec\s*;', src):
        bad('blend_en CDC', 'no 2-FF blend_en -> blend_s1_dec -> blend_en_dec in %s' % rel)

    mv = connections(src, 'mpeg2video')
    if mv is None:
        bad('mpeg2video instance', 'not found in %s' % rel)
    else:
        if tokens(mv.get('blend_en')) != {'blend_en_dec'}:
            bad('mpeg2video.blend_en', 'fed `%s`, want the synced blend_en_dec (clk_dec).'
                % mv.get('blend_en'))
        if tokens(mv.get('blend_act')) != {'core_blend_act'}:
            bad('mpeg2video.blend_act', 'connected to `%s`, want core_blend_act.' % mv.get('blend_act'))
    tl = connections(src, 'dvd_telem')
    if tl is None:
        bad('dvd_telem instance', 'not found in %s' % rel)
    elif 'core_blend_act' not in tokens(tl.get('flags')):
        bad('dvd_telem.flags', '`%s` does not carry core_blend_act -- the HW round cannot '
                               'see engagement.' % tl.get('flags'))


def check_mpeg(src, rel, bad):
    rs = connections(src, 'resample')
    fb = connections(src, 'field_blend')
    vs = connections(src, 'disp_vscale')
    for name, c in (('resample', rs), ('field_blend', fb), ('disp_vscale', vs)):
        if c is None:
            bad('%s instance' % name, 'not found in %s' % rel)
    if rs is None or fb is None or vs is None:
        return
    if tokens(rs.get('blend_en')) != {'blend_en'}:
        bad('resample.blend_en', 'fed `%s`, want the mpeg2video input blend_en.' % rs.get('blend_en'))
    sb_r, sb_f = tokens(rs.get('scan_blend')), tokens(fb.get('scan_blend'))
    if not sb_r or sb_r != sb_f:
        bad('scan_blend', 'resample drives `%s`, field_blend reads `%s` -- not one net.'
            % (rs.get('scan_blend'), fb.get('scan_blend')))
    ss_r, ss_f = tokens(rs.get('scan_start')), tokens(fb.get('scan_start'))
    if not ss_r or ss_r != ss_f:
        bad('scan_start', 'resample drives `%s`, field_blend reads `%s` -- not one net.'
            % (rs.get('scan_start'), fb.get('scan_start')))
    if tokens(fb.get('in_y')) != {'y_resample'}:
        bad('field_blend.in_y', 'fed `%s`, want y_resample (it sits right after resample).'
            % fb.get('in_y'))
    out_y = tokens(fb.get('out_y'))
    if not out_y or tokens(vs.get('in_y')) != out_y:
        bad('disp_vscale.in_y', 'fed `%s`, want field_blend.out_y `%s`. A disp_vscale fed '
                                'y_resample leaves field_blend instantiated and INERT.'
            % (vs.get('in_y'), fb.get('out_y')))
    for p in ('in_wr', 'in_pos'):
        if tokens(vs.get(p)) != tokens(fb.get('out_' + p[3:])):
            bad('disp_vscale.%s' % p, 'fed `%s`, want field_blend.out_%s `%s`.'
                % (vs.get(p), p[3:], fb.get('out_' + p[3:])))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--emu', default=os.path.join(ROOT, 'dvd/emu.sv'))
    ap.add_argument('--mpeg', default=os.path.join(ROOT, 'rtl/mpeg2/mpeg2video.v'))
    a = ap.parse_args()
    fails = []

    def bad(what, why):
        fails.append('%s: %s' % (what, why))

    for path, fn in ((a.emu, check_emu), (a.mpeg, check_mpeg)):
        rel = os.path.relpath(path, ROOT) if path.startswith(ROOT) else path
        try:
            src = strip_comments(open(path).read())
        except OSError as e:
            bad(rel, 'unreadable: %s' % e)
            continue
        fn(src, rel, bad)

    if fails:
        sys.stderr.write('check_field_blend_wiring: FAIL\n')
        for f in fails:
            sys.stderr.write('  - %s\n' % f)
        return 1
    print('check_field_blend_wiring: PASS -- O[49] Off/Blend (default Off), gated on '
          '~interlaced_eff, synced into clk_dec, instrumented; resample -> field_blend -> '
          'disp_vscale with one sideband')
    return 0


if __name__ == '__main__':
    sys.exit(main())
