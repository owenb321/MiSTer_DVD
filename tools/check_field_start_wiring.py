#!/usr/bin/env python3
"""check_field_start_wiring.py -- the strict first-field placement's seams.

WHY THIS IS A SCRIPT AND NOT A BENCH (2026-10-08, docs/field_parity.md "Strict first field")
-------------------------------------------------------------------------------------------
bench/dvd/field_phase_tb.sv proves the mixer places the first field after a start on its
own slot -- but it HANDS the mixer its `interlaced` flag and its `raster_restart` level, so it
cannot see whether rtl/mpeg2/mpeg2video.v feeds the right nets. Each seam below fails
SILENTLY when wrong:

  mixer.interlaced      tied 1'b0 (or fed the clk-domain `interlaced`) = the strict
                        placement never engages (or engages on a stale level) and every
                        start is a coin flip again; tied 1'b1 = Progressive is no longer
                        bit-identical.
  mixer.raster_restart  not the restart's own dot-domain synchroniser = a Video Output
                        switch or a PAL/NTSC walk re-phases the raster with nothing re-armed.
  word 31               the HW gate is a COUNT (fb_heals ~ 0, strict_waits ~ N/2 over N
                        starts). A wrong packing, a dropped format bit, or a Main that stops
                        reading at word 30 turns the gate into a measurement of nothing --
                        "an instrument derived from its subject" (CLAUDE.md).

strip_comments() runs first: every one of these comments quotes the nets it describes, so a
grep would pass a fully reverted file. Tests are on token SETS of the connected expression.
A lookup that returns None is a named FAIL, never a skip.

Usage: check_field_start_wiring.py [--mpeg2video P] [--emu P] [--ctl P]
(the runner mutates copies in $TMP and passes them here; the tree is never written).
Exit 0 = wired as designed.
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
from check_field_order_wiring import strip_comments, tokens  # noqa: E402


def instance(src, module, inst=None):
    """{port: expr} for one instantiation (by instance name when given)."""
    pat = (r'\b%s\s+(?:#\s*\([^;]*?\)\s*)?%s\s*\(' % (re.escape(module), re.escape(inst))
           if inst else r'\b%s\s+(?:#\s*\([^;]*?\)\s*)?(\w+)\s*\(' % re.escape(module))
    m = re.search(pat, src)
    if not m:
        return None
    depth, i, n, body = 0, m.end() - 1, len(src), None
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mpeg2video', default=os.path.join(ROOT, 'rtl/mpeg2/mpeg2video.v'))
    ap.add_argument('--emu', default=os.path.join(ROOT, 'dvd/emu.sv'))
    ap.add_argument('--ctl', default=os.path.join(ROOT, 'main/support/dvd/dvd_ctl.cpp'))
    a = ap.parse_args()
    fails = []

    def bad(what, why):
        fails.append('%s: %s' % (what, why))

    def port_is(conns, inst, port, want, why):
        if conns is None:
            bad(inst, 'instance not found')
            return None
        expr = conns.get(port)
        if expr is None:
            bad('%s.%s' % (inst, port), 'not connected. ' + why)
        elif tokens(expr) != set(want):
            bad('%s.%s' % (inst, port), 'fed `%s`, want exactly {%s}. %s'
                % (expr, ', '.join(sorted(want)), why))
        return expr

    mv = strip_comments(open(a.mpeg2video).read())

    # ---- 1. the mixer's two new inputs and its counter -----------------------------------
    mx = instance(mv, 'mixer')
    port_is(mx, 'mixer', 'interlaced', {'dot_interlaced'},
            'It gates the strict first-field placement; it must be the regfile bit ALREADY '
            'synced to dot_clk (dot_interlaced). A constant disables the fix or breaks '
            'Progressive\'s bit-identity; the raw clk-domain `interlaced` is a missing CDC.')
    rr = port_is(mx, 'mixer', 'raster_restart', {'dot_syncgen_rst_n'},
                 'It re-arms the placement on a modeline write (a Video Output switch, a '
                 'PAL/NTSC walk). Without it a raster restart is healed ~0.5 s late.')
    if rr is not None and not rr.replace(' ', '').startswith('~'):
        bad('mixer.raster_restart', 'fed `%s`: dot_syncgen_rst_n is active-LOW (sync_reset '
                                    'output), the port is active-HIGH -- it must be inverted.' % rr)
    port_is(mx, 'mixer', 'strict_waits', {'dot_strict_waits'},
            'The refused-slot count for telemetry word 31.')

    # ---- 2. the restart's synchroniser: syncgen_rst -> dot_clk ---------------------------
    sr = instance(mv, 'sync_reset', 'dot_syncgen_sreset')
    port_is(sr, 'dot_syncgen_sreset', 'clk', {'dot_clk'}, 'The mixer runs on dot_clk.')
    port_is(sr, 'dot_syncgen_sreset', 'asyncrst', {'syncgen_rst'},
            'It must be the regfile\'s modeline-write reset, the one that resets sync_gen.')
    port_is(sr, 'dot_syncgen_sreset', 'syncrst', {'dot_syncgen_rst_n'}, '')
    sg = instance(mv, 'syncgen_intf')
    port_is(sg, 'syncgen_intf', 'syncgen_rst', {'syncgen_rst'},
            'Anti-vacuity: the net the mixer arms on must be the one that restarts the raster.')

    # ---- 3. fb_heals: the addrgen pulse, counted on hard_rst ----------------------------
    rs = instance(mv, 'resample')
    port_is(rs, 'resample', 'par_heal', {'par_heal'}, 'One pulse per feedback insertion.')
    if not re.search(r'if\s*\(\s*~\s*hard_rst\s*\)\s*dbg_fb_heals\s*<=', mv):
        bad('dbg_fb_heals', 'not reset by hard_rst. On sync_rst it would clear at every soft '
                            'reset -- the event whose consequences it counts.')
    if not re.search(r'else\s+if\s*\(\s*par_heal\s*\)\s*dbg_fb_heals\s*<=\s*dbg_fb_heals\s*\+', mv):
        bad('dbg_fb_heals', 'does not count par_heal.')
    if not re.search(r'assign\s+dbg_strict_waits\s*=\s*dot_strict_waits\s*;', mv):
        bad('dbg_strict_waits', 'not driven by the mixer\'s dot_strict_waits.')

    # ---- 4. emu.sv: word 31's packing ---------------------------------------------------
    em = strip_comments(open(a.emu).read())
    tl = instance(em, 'dvd_telem')
    if tl is None:
        bad('dvd_telem', 'instance not found in emu')
    else:
        fp = tl.get('field_par')
        want = "{1'b1,core_fb_heals[6:0],core_strict_waits}"
        if fp is None:
            bad('dvd_telem.field_par', 'not connected: word 31 floats.')
        elif fp.replace(' ', '') != want:
            bad('dvd_telem.field_par', 'packed `%s`, want `%s`. Bit 15 is the FORMAT bit '
                'Main keys on; the fields must sit where dvd_ctl.cpp unpacks them.' % (fp, want))
    mp = instance(em, 'mpeg2video')
    port_is(mp, 'mpeg2video', 'dbg_fb_heals', {'core_fb_heals'}, '')
    port_is(mp, 'mpeg2video', 'dbg_strict_waits', {'core_strict_waits'}, '')

    # ---- 5. Main reads word 31 and keys on its format bit ------------------------------
    ctl = strip_comments(open(a.ctl).read())
    if not re.search(r'uint16_t\s+w\s*\[\s*32\s*\]', ctl) or \
       not re.search(r'for\s*\(\s*int\s+i\s*=\s*1\s*;\s*i\s*<\s*32\s*;', ctl):
        bad('dvd_ctl.cpp', 'does not read 32 telemetry words; word 31 is never fetched.')
    if not re.search(r'#define\s+DVD_TELEM_FPAR_PRESENT\s+0x8000\b', ctl) or \
       not re.search(r'w\s*\[\s*31\s*\]\s*&\s*DVD_TELEM_FPAR_PRESENT', ctl):
        bad('dvd_ctl.cpp', 'does not gate word 31 on its format bit (0x8000): an older '
                           'core\'s 0 would read as "zero heals".')
    if not re.search(r'\(\s*w\s*\[\s*31\s*\]\s*>>\s*8\s*\)\s*&\s*0x7F\s*,\s*w\s*\[\s*31\s*\]\s*&\s*0xFF', ctl):
        bad('dvd_ctl.cpp', 'does not unpack fb_heals = w[31][14:8], strict_waits = w[31][7:0].')

    if fails:
        sys.stderr.write('check_field_start_wiring: FAIL\n')
        for f in fails:
            sys.stderr.write('  - %s\n' % f)
        return 1
    print('check_field_start_wiring: PASS -- mixer gets dot_interlaced and the modeline '
          'restart (~dot_syncgen_rst_n from syncgen_rst); fb_heals counts par_heal on '
          'hard_rst; word 31 = {1, fb_heals[6:0], strict_waits}; Main reads and gates it')
    return 0


if __name__ == '__main__':
    sys.exit(main())
