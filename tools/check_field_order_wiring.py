#!/usr/bin/env python3
"""check_field_order_wiring.py -- the field-order seam in rtl/mpeg2/mpeg2video.v.

WHY THIS IS A SCRIPT AND NOT A BENCH (2026-09-18)
-------------------------------------------------
The whole fix for the field-coded field-order defect is ONE PORT CONNECTION:

    motcomp ... .top_field_first(first_field_top)      <-- the DISPLAY ORDER
                                                           (was: top_field_first,
                                                            the raw syntax element)

motcomp forwards it to motcomp_picbuf, which stores it as output_top_field_first,
which is what dvd/resample_addrgen.v orders the two field images from. Reverting
that one connection restores the defect in full -- and NO module bench can see it:
every module is handed a value by its parent and is correct for the value it is
given. bench/dvd/field_order_tb.sv covers the DATAPATH by replicating this seam
under a SEAM parameter, but a bench replicating a seam cannot also police it; that
is the check_subp_map_wiring.py lesson (issue #81), where a single port carrying
the wrong FACT was invisible to a module bench whose truth table never changed.

Three traps this file is written against, all paid for elsewhere in this project:

  1. strip_comments() IS MANDATORY, FIRST. The seam comment in mpeg2video.v quotes
     `top_field_first`, `first_field_top` and `output_top_field_first` verbatim, on
     purpose, to explain the distinction -- so a grep-based checker would PASS ON A
     FULLY REVERTED FILE. (check_saver_overlay_wiring.py records the same hazard.)
  2. Every test is over a TOKEN SET, never a substring. `top_field_first` is a
     SUBSTRING of `output_top_field_first`, and `first_field_top` shares most of its
     characters with both -- so `'top_field_first' in expr` is true for a file that
     never mentions it on its own.
  3. A lookup that returns None is a NAMED FAIL, never a skip.

Exit 0 = wired as designed. Exit 1 = the seam carries the wrong fact.
Optional argv[1] = a file to check instead of rtl/mpeg2/mpeg2video.v, so a runner
can mutate a copy in $TMP and never write the tree.
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


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'rtl/mpeg2/mpeg2video.v')
    rel = os.path.relpath(path, ROOT) if path.startswith(ROOT) else path
    src = strip_comments(open(path).read())
    fails = []

    def bad(what, why):
        fails.append('%s: %s' % (what, why))

    # ---- 1. vld must actually EXPORT the derived display order ---------------
    vld = connections(src, 'vld')
    if vld is None:
        bad('vld instance', 'no `vld` instantiation found in %s -- cannot check the '
                            'seam at all.' % rel)
    else:
        if 'first_field_top' not in vld:
            bad('vld.first_field_top',
                'the vld instance does not connect .first_field_top. Without it the '
                'display order is never exported and the seam below has nothing to '
                'carry.')
        elif 'first_field_top' not in tokens(vld['first_field_top']):
            bad('vld.first_field_top',
                'connected to `%s`, which does not carry the first_field_top net.'
                % vld['first_field_top'])

    # ---- 2. THE SEAM: motcomp must be fed the DISPLAY ORDER ------------------
    mc = connections(src, 'motcomp')
    if mc is None:
        bad('motcomp instance', 'no `motcomp` instantiation found in %s.' % rel)
    else:
        expr = mc.get('top_field_first')
        if expr is None:
            bad('motcomp.top_field_first',
                'the motcomp instance does not connect .top_field_first. It feeds '
                'motcomp_picbuf -> output_top_field_first -> resample_addrgen, which '
                'is the entire field-order path.')
        else:
            tk = tokens(expr)
            if 'first_field_top' not in tk:
                bad('motcomp.top_field_first',
                    'fed `%s`. THIS IS THE DEFECT: on a FIELD-coded picture ISO '
                    '13818-2 6.3.10 forces the top_field_first syntax element to 0, so '
                    'ordering the two field images from it emits BOTTOM-then-TOP '
                    'unconditionally and inverts the temporal field order. It must be '
                    'fed vld\'s first_field_top. See docs/field_parity.md.' % expr)
            if 'top_field_first' in tk:
                # ⚠ trap 2: `top_field_first` is a SUBSTRING of the port NAME, so this
                # test must run on the connected EXPRESSION only, which it does.
                bad('motcomp.top_field_first',
                    'fed `%s`, which still references the RAW top_field_first net. The '
                    'display path must take first_field_top alone; mixing the two (a '
                    'mux, an OR) would reintroduce the syntax element on exactly the '
                    'pictures where it is meaningless.' % expr)

    # ---- 3. ANTI-VACUITY: the display path must still READ picbuf's output ---
    # Without this, a file that simply deleted the field-order path entirely would
    # pass checks 1 and 2 -- "nothing is wrong because nothing is wired" is not the
    # property wanted. (The R2/R3 controls in check_select_noop.py, same idea.)
    rs = connections(src, 'resample')
    if rs is None:
        bad('resample instance', 'no `resample` instantiation found in %s.' % rel)
    else:
        expr = rs.get('top_field_first')
        if expr is None:
            bad('resample.top_field_first',
                'the resample instance does not connect .top_field_first -- the field '
                'order would reach nothing.')
        elif 'output_top_field_first' not in tokens(expr):
            bad('resample.top_field_first',
                'fed `%s` rather than motcomp_picbuf\'s output_top_field_first. The '
                'display flags must ride picbuf, not come live from the vld -- that is '
                'the round-11 stale-display-flags defect (docs/lipsync_pickup.md).'
                % expr)

    if fails:
        sys.stderr.write('check_field_order_wiring: FAIL (%s)\n' % rel)
        for f in fails:
            sys.stderr.write('  - %s\n' % f)
        return 1
    print('check_field_order_wiring: PASS (%s) -- vld exports first_field_top; motcomp '
          '(-> picbuf -> resample_addrgen) is fed the DISPLAY ORDER, not the syntax '
          'element; resample still reads picbuf\'s output' % rel)
    return 0


if __name__ == '__main__':
    sys.exit(main())
