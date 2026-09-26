#!/usr/bin/env python3
"""check_field_blend_wiring.py -- the field-blend / progressive-bob seams in
dvd/emu.sv and rtl/mpeg2/mpeg2video.v (docs/field_blend.md).

WHY A SCRIPT: every module bench is handed blend_en / bob_en / the pixel stream by
its parent and is correct for what it is given. What decides whether the features
reach the screen -- on the right raster, from the one Deinterlace option, with Weave
as the default -- is a handful of connections no bench instantiates (emu has no
bench, and the chain bench wires field_blend itself). The
check_field_order_wiring.py pattern.

WHAT IS PINNED
  emu.sv
    1. the Deinterlace option (2026-09-25 merge): exactly the two rows
         "H0O[51:50],Deinterlace,Weave,Bob,Blend;"   (Progressive raster)
         "h0O[51:50],Deinterlace,Weave,Bob;"         (Interlaced raster: no Blend)
       and no other row on bits 50/51. Index 0 = Weave = the DEFAULT. The retired
       rows' bits 11 ("480i Deint") and 49 ("Progressive Deint") are claimed by no
       row and READ BY NOTHING (a stale saved value must not re-arm them).
    2. hps_io.status_menumask = {15'd0, interlaced_eff} -- mask bit 0 is what swaps
       the two rows (H0 hides on a set bit, h0 on a clear one).
    3. deint_mode = status[51:50];
       blend_en = (deint_mode == 2'd2) & ~interlaced_eff;
       bob_en   = (deint_mode == 2'd1) & ~interlaced_eff & ~filmp_eff;
       HDMI_BOB_DEINT = fields_eff & (deint_mode == 2'd1).
       Rejected in the blend/bob gates: fields_eff / il_eff / p240_eff -- 240p is a
       sub-mode of the interlaced raster whose decoder emits FRAMES, so a fields_eff
       gate (what shelved Stage A used) would filter on 240p.
    4. a 2-FF sync of each into clk_dec, and mpeg2video fed the SYNCED nets.
    5. the instruments: blend_act -> core_blend_act -> telemetry flags; bob_act ->
       core_bob_act -> telemetry sched_flags (word 14 bit 8).
  mpeg2video.v
    6. resample.blend_en(blend_en) / .bob_en(bob_en); scan_start, scan_blend,
       scan_bob and scan_bob_bot are each ONE net from resample to field_blend (the
       sideband is useless if its pulse and its bits come from different places).
    7. ORDER: resample -> field_blend -> disp_vscale. field_blend.in_y is
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
    pre = r'(?:[HhDd][0-9A-Va-v])*(?:P\d+)?'      # menu-mask hide/disable prefixes, page
    for m in re.finditer(r'"(%sO\[(\d+)(?::(\d+))?\][^"]*)"' % pre, src):
        hi = int(m.group(2)); lo = int(m.group(3)) if m.group(3) else hi
        rows.append((hi, lo, m.group(1)))
    for m in re.finditer(r'"(%sO([0-9A-Va-v]{1,2}),[^"]*)"' % pre, src):
        ch = m.group(2)
        bits = [int(c, 36) for c in ch]
        rows.append((max(bits), min(bits), m.group(1)))
    return rows


PROG_ROW = 'H0O[51:50],Deinterlace,Weave,Bob,Blend;'
ILACE_ROW = 'h0O[51:50],Deinterlace,Weave,Bob;'


def gate_expr(src, name, bad, rel):
    m = re.search(r'\bwire\s+%s\s*=\s*([^;]+);' % name, src)
    if not m:
        bad(name, 'no `wire %s = ...;` in %s' % (name, rel))
        return None
    return m.group(1)


def mode_eq(expr, val):
    """expr compares deint_mode to 2'd<val> (either operand order)."""
    return bool(re.search(r"\(\s*deint_mode\s*==\s*2'd%d\s*\)" % val, expr) or
                re.search(r"\(\s*2'd%d\s*==\s*deint_mode\s*\)" % val, expr))


def check_emu(src, rel, bad):
    rows = conf_rows(src)
    for want, what in ((PROG_ROW, 'Progressive'), (ILACE_ROW, 'Interlaced')):
        n = sum(1 for r in rows if r[2] == want)
        if n != 1:
            bad('CONF_STR', 'expected exactly one %s Deinterlace row "%s", found %d. Rows on '
                            'bits 50/51: %s' % (what, want, n,
                                                [r[2] for r in rows if r[1] <= 51 and r[0] >= 50]))
    others = [r[2] for r in rows if r[1] <= 51 and r[0] >= 50 and r[2] not in (PROG_ROW, ILACE_ROW)]
    if others:
        bad('CONF_STR', 'another row claims status[51:50]: %s' % others)
    for bit, old in ((11, '480i Deint'), (49, 'Progressive Deint')):
        claim = [r[2] for r in rows if r[1] <= bit <= r[0]]
        if claim:
            bad('CONF_STR', 'bit %d (the retired "%s") is claimed again: %s' % (bit, old, claim))
        if re.search(r'\bstatus\s*\[\s*%d\s*\]' % bit, src):
            bad('status[%d]' % bit, ('is still READ; the retired "%s" bit must be read by '
                                     'nothing, or a stale saved value re-arms it.') % old)

    hp = connections(src, 'hps_io')
    if hp is None:
        bad('hps_io instance', 'not found in %s' % rel)
    elif not re.fullmatch(r"\{\s*15'd0\s*,\s*interlaced_eff\s*\}", hp.get('status_menumask') or ''):
        bad('hps_io.status_menumask', 'connected to `%s`, want {15\'d0, interlaced_eff}: mask '
                                      'bit 0 set = the Interlaced raster, which H0 hides the '
                                      'Blend row on.' % hp.get('status_menumask'))

    m = re.search(r'\bwire\s*\[\s*1\s*:\s*0\s*\]\s*deint_mode\s*=\s*([^;]+);', src)
    if not m or not re.fullmatch(r'status\s*\[\s*51\s*:\s*50\s*\]', m.group(1).strip()):
        bad('deint_mode', 'want `wire [1:0] deint_mode = status[51:50];`, found `%s`'
            % (m.group(1) if m else None))

    for name, val, extra in (('blend_en', 2, ()), ('bob_en', 1, ('filmp_eff',))):
        expr = gate_expr(src, name, bad, rel)
        if expr is None:
            continue
        tk = tokens(expr)
        if not mode_eq(expr, val):
            bad(name, "`%s` does not test (deint_mode == 2'd%d)." % (expr, val))
        if 'status' in tk:
            bad(name, '`%s` reads status directly; it must decode deint_mode.' % expr)
        if not re.search(r'~\s*interlaced_eff\b', expr):
            bad(name, '`%s` is not gated on ~interlaced_eff (the progressive raster).' % expr)
        for t in extra:
            if not re.search(r'~\s*%s\b' % t, expr):
                bad(name, '`%s` is not gated on ~%s: the Film 24p/25p raster scans a picture '
                          'about once, so a bob there drops a field.' % (expr, t))
        for t in ('fields_eff', 'il_eff', 'p240_eff', 'il_prev', 'fields_prev'):
            if t in tk:
                bad(name, '`%s` uses %s. 240p is a sub-mode of the interlaced raster '
                          'whose decoder emits FRAMES; only ~interlaced_eff excludes it.'
                    % (expr, t))

    m = re.search(r'\bassign\s+HDMI_BOB_DEINT\s*=\s*([^;]+);', src)
    if not m:
        bad('HDMI_BOB_DEINT', 'no assign in %s' % rel)
    else:
        expr = m.group(1)
        if not re.match(r'\s*fields_eff\s*&', expr) or not mode_eq(expr, 1) or 'status' in tokens(expr):
            bad('HDMI_BOB_DEINT', "`%s`, want fields_eff & (deint_mode == 2'd1): ascal bobs "
                                  "only on Bob, and a saved Blend weaves (what the Interlaced "
                                  "row then shows)." % expr)

    for n in ('blend', 'bob'):
        if not re.search(r'\b%s_s1_dec\s*<=\s*%s_en\s*;' % (n, n), src) or \
           not re.search(r'\b%s_en_dec\s*<=\s*%s_s1_dec\s*;' % (n, n), src):
            bad('%s_en CDC' % n, 'no 2-FF %s_en -> %s_s1_dec -> %s_en_dec in %s' % (n, n, n, rel))

    mv = connections(src, 'mpeg2video')
    if mv is None:
        bad('mpeg2video instance', 'not found in %s' % rel)
    else:
        for port, want in (('blend_en', 'blend_en_dec'), ('bob_en', 'bob_en_dec'),
                           ('blend_act', 'core_blend_act'), ('bob_act', 'core_bob_act')):
            if tokens(mv.get(port)) != {want}:
                bad('mpeg2video.%s' % port, 'connected to `%s`, want %s.' % (mv.get(port), want))
    tl = connections(src, 'dvd_telem')
    if tl is None:
        bad('dvd_telem instance', 'not found in %s' % rel)
    else:
        if 'core_blend_act' not in tokens(tl.get('flags')):
            bad('dvd_telem.flags', '`%s` does not carry core_blend_act -- the HW round cannot '
                                   'see engagement.' % tl.get('flags'))
        if 'core_bob_act' not in tokens(tl.get('sched_flags')):
            bad('dvd_telem.sched_flags', '`%s` does not carry core_bob_act (word 14 bit 8).'
                % tl.get('sched_flags'))


def check_mpeg(src, rel, bad):
    rs = connections(src, 'resample')
    fb = connections(src, 'field_blend')
    vs = connections(src, 'disp_vscale')
    for name, c in (('resample', rs), ('field_blend', fb), ('disp_vscale', vs)):
        if c is None:
            bad('%s instance' % name, 'not found in %s' % rel)
    if rs is None or fb is None or vs is None:
        return
    for p in ('blend_en', 'bob_en'):
        if tokens(rs.get(p)) != {p}:
            bad('resample.%s' % p, 'fed `%s`, want the mpeg2video input %s.' % (rs.get(p), p))
    for p in ('scan_start', 'scan_blend', 'scan_bob', 'scan_bob_bot'):
        a_, b_ = tokens(rs.get(p)), tokens(fb.get(p))
        if not a_ or a_ != b_:
            bad(p, 'resample drives `%s`, field_blend reads `%s` -- not one net.'
                % (rs.get(p), fb.get(p)))
    if tokens(fb.get('bob_act')) != {'bob_act'}:
        bad('field_blend.bob_act', 'connected to `%s`, want the mpeg2video output bob_act.'
            % fb.get('bob_act'))
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
    print('check_field_blend_wiring: PASS -- one Deinterlace option O[51:50] Weave/Bob/Blend '
          '(default Weave; two rows swapped by the menu mask, no Blend on Interlaced), bits 11/49 '
          'retired; blend/bob gated on ~interlaced_eff (bob also ~filmp_eff), synced into '
          'clk_dec, instrumented; resample -> field_blend -> disp_vscale with one sideband')
    return 0


if __name__ == '__main__':
    sys.exit(main())
