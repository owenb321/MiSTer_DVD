#!/usr/bin/env python3
"""Gate for forced subtitles (PR #151; docs/subpicture.md "Forced subtitles").

WHY THIS EXISTS
---------------
spu_decode's bench (bench/dvd/spu_forced_tb.sv) proves the decoder shows only
FSTA_DSP units when its forced_only input is high. It is HANDED that input, so it
cannot see whether emu.sv asserts it at the right time, routes the right stream, or
leaves the display-ON paths alone. emu.sv has no bench, so this reads the seam out of
the file (the check_subp_map_wiring.py pattern):

  1. spu_decode's .forced_only is fs_route.
  2. fs_route is derived from sp_disp_on (the display-ON terms), not restated, and is
     gated to a parsed TITLE-domain PGC that declares a subpicture stream.
  3. sp_disp_on carries the display-ON terms of the old sp_route_en, so a SetSTN
     display-on, Scene It (sp_menu_early) and menu domains can never fall into the
     forced-only route.
  3b. ...and NOT in_title_hli (issue #178): an armed in-title button with subtitles
     off must take the forced route. As a display-on term it routed the user's
     stream unfiltered, and Dinosaur showed its whole SDH track with SUB OFF.
  4. sp_route_en = ~sp_user_absent & (sp_disp_on | fs_route).
  5. sp_sel_log selects fs_log for fs_route, AFTER the menu and VM arms.
  6. sp_track_eff resolves fs_route through the map (sp_phys_streamN), like SPRM2.
  7. fs_log uses SPRM2 only when it names a declared stream 0..31 (vm_spstn[5]
     clear: 62/63 are "none"/"forced", not streams) and otherwise falls back to the
     first declared stream -- never an aliasing truncation of 62 / 63. (All 32
     streams since PR #152; it was 0..15 with a [5:4] guard.)
  8. sp_user_absent does not mute the forced route.

    python3 tools/check_forced_subs_wiring.py [emu.sv]     # exit 0 = wired right
    git show <pre-#178 commit>:dvd/emu.sv > old.sv && \\
        python3 tools/check_forced_subs_wiring.py old.sv    # must exit 1 (3b)

Comments are stripped first: emu.sv quotes old code in its comments, and a loose
grep finds connections that are not connections.
"""
import os
import re
import sys


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


def squash(s):
    return re.sub(r'\s+', '', s)


def stmt(src, lhs_regex):
    """The right-hand side of `wire ... NAME = ...;` or `assign NAME = ...;`, squashed."""
    m = re.search(r'(?:\bwire\b[^;=]*?|\bassign\s+)\b' + lhs_regex + r'\s*=\s*([^;]*);', src)
    return squash(m.group(1)) if m else None


def instance_port(src, module, port):
    m = re.search(r'\b%s\s+(\w+)\s*\(' % module, src)
    if not m:
        return None
    depth, i, n = 0, m.end() - 1, len(src)
    start = i
    while i < n:
        if src[i] == '(':
            depth += 1
        elif src[i] == ')':
            depth -= 1
            if depth == 0:
                break
        i += 1
    body = src[start:i + 1]
    pm = re.search(r'\.%s\s*\(([^()]*)\)' % port, body)
    return squash(pm.group(1)) if pm else None


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, '..', 'dvd', 'emu.sv')
    src = strip_comments(open(path, encoding='utf-8', errors='replace').read())
    bad = []

    def need(cond, msg):
        if not cond:
            bad.append(msg)

    fo = instance_port(src, 'spu_decode', 'forced_only')
    need(fo == 'fs_route', '1. spu_decode .forced_only is %r, want fs_route' % fo)

    fr = stmt(src, r'fs_route')
    need(fr is not None, '2. fs_route is not declared')
    if fr:
        for t in ('~sp_disp_on', 'pgc_ctl_valid', 'pgc_dom_tt'):
            need(t in fr, '2. fs_route lacks %s: %s' % (t, fr))
        need('subp_declared' in fr or 'subp_any_present' in fr or 'subp_any_decl' in fr,
             '2. fs_route is not gated on a declared subpicture stream: %s' % fr)

    dp = stmt(src, r'sp_disp_on')
    need(dp is not None, '3. sp_disp_on is not declared')
    if dp:
        for t in ('sub_on', 'menus_on&&menu_active', 'vm_owns_sp&&vm_spstn[6]',
                  'sp_menu_early'):
            need(t in dp, '3. sp_disp_on lacks the display-ON term %s: %s' % (t, dp))
        # Neither the name nor its definition (hl_btns_armed): either one makes an
        # armed button a display-on path again.
        for t in ('in_title_hli', 'hl_btns_armed', 'in_title_menu'):
            need(not re.search(r'\b%s\b' % t, dp),
                 '3b. sp_disp_on holds %s, so an armed in-title button shows the '
                 'user stream unfiltered with subtitles off (issue #178): %s' % (t, dp))

    re_ = stmt(src, r'sp_route_en')
    need(re_ is not None, '4. sp_route_en assignment not found')
    if re_:
        need(re_.startswith('~sp_user_absent&'), '4. sp_route_en lost ~sp_user_absent: %s' % re_)
        need('sp_disp_on' in re_ and 'fs_route' in re_,
             '4. sp_route_en is not (sp_disp_on | fs_route): %s' % re_)

    sl = stmt(src, r'sp_sel_log')
    need(sl is not None, '5. sp_sel_log not found')
    if sl:
        need('fs_route?fs_log' in sl, '5. sp_sel_log has no fs_route ? fs_log arm: %s' % sl)
        im, iv, ifs = sl.find('menu_sp_ctx?'), sl.find('vm_owns_route?'), sl.find('fs_route?')
        need(0 <= im < iv < ifs, '5. sp_sel_log priority must be menu, VM, then forced: %s' % sl)

    te = stmt(src, r'sp_track_eff')
    need(te is not None, '6. sp_track_eff not found')
    if te:
        sel = te.split('?')[0]
        need('fs_route' in sel and 'sp_phys_streamN' in te,
             '6. sp_track_eff does not map fs_route through sp_phys_streamN: %s' % te)

    fl = stmt(src, r'fs_log')
    ok = stmt(src, r'fs_vm_ok')
    need(fl is not None and ok is not None, '7. fs_log / fs_vm_ok not found')
    if fl and ok:
        need(fl == 'fs_vm_ok?vm_spstn[4:0]:subp_first_decl',
             '7. fs_log must be fs_vm_ok ? vm_spstn[4:0] : subp_first_decl, got %s' % fl)
        need('!vm_spstn[5]' in ok and 'subp_declared[vm_spstn[4:0]]' in ok,
             '7. fs_vm_ok must reject SPRM2 62/63 (bit 5) and undeclared streams: %s' % ok)

    ua = stmt(src, r'sp_user_absent')
    need(ua is not None and 'fs_route' in ua,
         '8. sp_user_absent can mute the forced route: %s' % ua)

    if bad:
        print('check_forced_subs_wiring: FAIL (%s)' % path)
        for b in bad:
            print('  ' + b)
        return 1
    print('check_forced_subs_wiring: PASS (forced route, forced_only and stream choice wired)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
