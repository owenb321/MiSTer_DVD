#!/usr/bin/env python3
"""check_saver_overlay_wiring.py -- gate the BURN-IN POLICY by READING dvd/emu.sv.

WHY THIS EXISTS
---------------
Stop and the screensaver blank the picture and put the bouncing logo up. WHICH LAYERS
go dark with it is decided entirely in emu's overlay priority-mux register stage, and
emu has no testbench. Every module involved -- spu_decode, nav_pci, subpic_blend,
transport_hud, seek_bar, idle_logo, stop_ctl -- is individually correct and individually
benched; the defect was one missing term in the expression that composes them.

That is the `tools/check_subp_map_wiring.py` / `check_p240_wiring.py` pattern: read the
answer out of the RTL instead of restating it, because a table that cannot go stale beats
a correct one. It runs in milliseconds from bench/dvd/run_screensaver.sh.

THE DEFECT IT LOCKS OUT (2026-09-15)
------------------------------------
`pic_blank` took core_r/g/b to black and hud_on_e/bar_on_e suppressed the chrome, but
`sp_q_inside` / `hl_use` carried no gate -- so the SUBPICTURE layer (a subtitle, or a
disc-menu button highlight, which is a recolour of subpicture pixels) composited over the
blanked black frame and stayed there. Reported as: pause on a menu with a button
highlighted, and the highlight is still drawn once the screensaver kicks in.

  A gate on the picture is not a gate on what is drawn OVER the picture.

So this file pins the WHOLE policy, not just the new terms: the pre-existing hud_on_e /
bar_on_e / blend-input gates are un-benched too, they are one sed from deletion, and the
new gate is only meaningful relative to them. And it pins, by REJECTION, the half a future
reader is most likely to get wrong -- the wires that must stay UNGATED.

    python3 tools/check_saver_overlay_wiring.py [emu.sv]    # exit 0 = wired as designed
    git show d4da153^:dvd/emu.sv > /tmp/old.sv && \
        python3 tools/check_saver_overlay_wiring.py /tmp/old.sv    # must exit 1

THREE PARSING TRAPS, EACH OF WHICH SILENTLY INVERTS A RESULT
------------------------------------------------------------
* ⛔ strip_comments() IS MANDATORY, and this region proves it better than any other file
  in the tree: dvd/emu.sv's dbg_blk8 comment contains the literal pre-fix expression
  `hud_on_w | bar_on_w | hl_use` INSIDE A COMMENT (it is explaining a 2026-08-17 fix).
  A grep-based checker passes on a FULLY REVERTED file on the strength of that comment
  alone. Do not "simplify" this to a grep.
* ⛔ `hl_use_e` CONTAINS `hl_use` AS A SUBSTRING. Every presence/absence test here is over
  a TOKEN SET (terms()), never a substring `in`. A future tidy-up to `'hl_use' in rhs`
  inverts two assertions at once: it reads True on the gated expression and the paired
  "must not contain" test then fails on correct RTL.
* ⚠ terms() does NOT strip Verilog literals -- `4'd15` yields the token `d15`, `8'd0`
  yields `d0`. So use MEMBERSHIP (issubset / not-in) on any expression containing a
  literal, and reserve set EQUALITY for the literal-free gate wires.

AND ONE STRUCTURAL RULE: never pin the register block verbatim. The priority chain will
legitimately gain another overlay layer one day, and a verbatim pin would then fail on a
correct file. Each assignment is looked up BY NAME and asserted on its token set.

Every lookup that comes back empty is a FAIL with a named message, never a skip --
check_subp_map_wiring.py's `if body is not None:` shape turns a rename into zero
assertions, which is a gate that reports success for a file it never read.

Exit 0 = wired as designed. Exit 1 = a named term carries the wrong fact.
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


def norm(text):
    """Collapse whitespace so a re-indent or a re-wrap is not a failure."""
    return re.sub(r'\s+', ' ', text)


def find_instance(src, module):
    """Text between a module instantiation's '(' and its matching ')'."""
    m = re.search(r'\b%s\s+(\w+)\s*\(' % re.escape(module), src)
    if not m:
        return None
    depth, i, n = 0, m.end() - 1, len(src)
    while i < n:
        if src[i] == '(':
            depth += 1
        elif src[i] == ')':
            depth -= 1
            if depth == 0:
                return src[m.end():i]
        i += 1
    return None


def connections(body):
    """{port: expression} for .port(expr) named connections."""
    out = {}
    i, n = 0, len(body)
    while i < n:
        if body[i] == '.':
            m = re.match(r'\.\s*(\w+)\s*\(', body[i:])
            if m:
                depth, j = 0, i + m.end() - 1
                while j < n:
                    if body[j] == '(':
                        depth += 1
                    elif body[j] == ')':
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                out[m.group(1)] = ' '.join(body[i + m.end():j].split())
                i = j
        i += 1
    return out


def assign_of(src, name):
    """RHS of `wire/reg/logic ... <name> = <expr>;` (continuous assignment)."""
    m = re.search(r'\b(?:wire|reg|logic)\b[^;=]*?\b%s\s*=\s*([^;]+);' % re.escape(name), src)
    return m.group(1).strip() if m else None


def nb_rhs(src, name):
    """RHS of a non-blocking assignment `<name> <= <expr>;`.

    `[^;]+` is a safe terminator: after comment-stripping none of these expressions
    contains a ';'. Matches the FIRST assignment, which is what we want -- each of the
    registers checked here is assigned exactly once.
    """
    m = re.search(r'\b%s\s*<=\s*([^;]+);' % re.escape(name), src)
    return m.group(1).strip() if m else None


def terms(expr):
    """Identifiers in an expression.

    ⚠ Verilog literals leak through as tokens (`4'd15` -> `d15`). Use membership, not
    equality, on any expression that contains one.
    """
    return set(re.findall(r'[A-Za-z_]\w*', expr))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dvd', 'emu.sv')
    src = norm(strip_comments(open(path, encoding='utf-8').read()))
    rel = os.path.relpath(path, ROOT) if path.startswith(ROOT) else path

    fails = []

    def bad(label, why):
        fails.append('%s: %s' % (label, why))

    def get(kind, name, label):
        """Look a term up; absence is a FAIL, never a skip."""
        rhs = (assign_of if kind == 'wire' else nb_rhs)(src, name)
        if rhs is None:
            bad(label, '`%s` is not assigned anywhere in %s -- was the overlay register '
                       'stage renamed or deleted? This gate asserts nothing it cannot '
                       'find, so an absent term is a failure, not a pass.' % (name, rel))
        return rhs

    def want_terms(label, rhs, required, why):
        if rhs is not None and not set(required).issubset(terms(rhs)):
            missing = sorted(set(required) - terms(rhs))
            bad(label, 'missing %s from `%s`. %s' % (', '.join(missing), rhs, why))

    def reject_terms(label, rhs, forbidden, why):
        if rhs is not None:
            present = sorted(set(forbidden) & terms(rhs))
            if present:
                bad(label, 'must NOT contain %s -- found `%s`. %s'
                           % (', '.join(present), rhs, why))

    def exact_terms(label, rhs, expected, why):
        if rhs is not None and terms(rhs) != set(expected):
            bad(label, 'terms are {%s}, expected exactly {%s} (`%s`). %s'
                       % (', '.join(sorted(terms(rhs))), ', '.join(sorted(expected)),
                          rhs, why))

    def want_inverted(label, rhs, name, why):
        """A term-set check alone passes on `& pic_blank` -- the MISSING '~' is the
        single most plausible edit here and it inverts the whole feature."""
        if rhs is not None and not re.search(r'~\s*%s' % re.escape(name), rhs):
            bad(label, '`%s` is not INVERTED in `%s`. %s' % (name, rhs, why))

    # =====================================================================
    # A. THE FIX -- the gate, and that it is actually consumed
    # =====================================================================
    pic = get('wire', 'pic_blank', 'pic_blank')
    exact_terms('pic_blank', pic, {'stopped_w', 'saver_on_w'},
                'pic_blank is THE "the picture is black" fact and both halves are '
                'load-bearing: a Stop is INDEFINITE (with Screensaver=Off it never ends), '
                'and the screensaver is the reported case. Dropping either one leaves a '
                'menu highlight burning in on that path.')

    sp_on_e = get('wire', 'sp_on_e', 'sp_on_e')
    exact_terms('sp_on_e', sp_on_e, {'sp_q_inside', 'pic_blank'},
                'sp_on_e must be exactly `sp_q_inside & ~pic_blank` -- the subpicture '
                'layer is picture CONTENT and goes dark with the picture.')
    want_inverted('sp_on_e', sp_on_e, 'pic_blank',
                  'Without the ~ the subpicture is shown ONLY while the screen is blanked, '
                  'which is the feature exactly backwards.')

    hl_use_e = get('wire', 'hl_use_e', 'hl_use_e')
    exact_terms('hl_use_e', hl_use_e, {'hl_use', 'pic_blank'},
                'hl_use_e must be exactly `hl_use & ~pic_blank` -- the HLI recolour is the '
                'reported symptom.')
    want_inverted('hl_use_e', hl_use_e, 'pic_blank',
                  'See sp_on_e: without the ~ the highlight appears ONLY on the blanked '
                  'screen.')

    sp_on_q = get('reg', 'sp_on_q', 'sp_on_q')
    want_terms('sp_on_q', sp_on_q, {'sp_on_e'},
               'THE GATE MUST BE USED. subpic_blend draws when ov_on is high '
               '(subpic_blend.sv: `blend = ov_on && ...`), so sp_on_q is the term that '
               'removes the pixel. A declared-but-unconsumed sp_on_e is exactly what a '
               'later "tidy-up" leaves behind, and it restores the defect in full.')
    reject_terms('sp_on_q', sp_on_q, {'sp_q_inside'},
                 'This is the shipped defect: the raw sp_q_inside term composites the '
                 'subtitle / menu button art over the blanked black frame.')

    sp_force_q = get('reg', 'sp_force_q', 'sp_force_q')
    want_terms('sp_force_q', sp_force_q, {'hl_use_e'},
               'ov_force bypasses subpic_blend\'s idx-0 transparency key, which is how a '
               'BACKGROUND-class highlight fill is drawn at all.')
    reject_terms('sp_force_q', sp_force_q, {'hl_use'},
                 'The half-fix: gate sp_on_q but leave the force term raw and an idx-0 '
                 'highlight fill survives through the force path.')

    sp_alpha_q = get('reg', 'sp_alpha_q', 'sp_alpha_q')
    want_terms('sp_alpha_q', sp_alpha_q, {'hl_use_e'},
               'Not load-bearing on its own (ov_on low already stops the blend), but pinned '
               'so the register stage cannot hold a stale highlight alpha behind an off '
               'pixel and so the three terms cannot drift apart.')
    reject_terms('sp_alpha_q', sp_alpha_q, {'hl_use'},
                 'See above -- keep the three gated terms consistent.')

    # =====================================================================
    # B. THE PRE-EXISTING POLICY -- un-benched, and the new gate is only
    #    meaningful relative to it
    # =====================================================================
    stop_full = get('wire', 'stop_full', 'stop_full')
    exact_terms('stop_full', stop_full, {'stopped_w', 'stop_kept_w'},
                'stage 2 is "the position is forgotten", not merely "stopped".')
    want_inverted('stop_full', stop_full, 'stop_kept_w',
                  'stop_full is the stage-2 verdict: kept=1 is stage 1.')

    for name in ('hud_on_e', 'bar_on_e'):
        rhs = get('wire', name, name)
        src_term = 'hud_on_w' if name == 'hud_on_e' else 'bar_on_w'
        exact_terms(name, rhs, {src_term, 'saver_on_w', 'stop_full'},
                    'A static status line burning into a phosphor is precisely what the '
                    'screensaver exists to prevent, and the logo sits BELOW it in the '
                    'chain -- ungated, the logo bounces underneath a pinned HUD.')
        want_inverted(name, rhs, 'saver_on_w', 'The screensaver must suppress it.')
        want_inverted(name, rhs, 'stop_full',
                      'A full Stop shows the bare logo -- the presence or absence of an '
                      'overlay IS the stage readout.')

    # The logo composites into the chrome stage DIRECTLY again: the audio
    # visualizers, and the logo-or-visualizer bg_on_w mux they needed, were dropped
    # 2026-09-22 (user decision -- the bouncing logo is a CD's only visual now).
    want_terms('sp_on_q chrome', sp_on_q, {'hud_on_e', 'bar_on_e', 'logo_on_w'},
               'the chrome layers still compose into the same register stage')
    for label, rhs in (('sp_on_q', sp_on_q), ('sp_force_q', sp_force_q),
                       ('sp_alpha_q', sp_alpha_q),
                       ('sp_r_q', get('reg', 'sp_r_q', 'sp_r_q')),
                       ('sp_g_q', get('reg', 'sp_g_q', 'sp_g_q')),
                       ('sp_b_q', get('reg', 'sp_b_q', 'sp_b_q'))):
        reject_terms(label + ' (ungated chrome)', rhs, {'hud_on_w', 'bar_on_w'},
                     'The mux arm must read the GATED hud_on_e / bar_on_e, never the raw '
                     'module outputs -- re-pointing any one arm re-opens the burn-in the '
                     'screensaver exists to prevent.')

    body = find_instance(src, 'subpic_blend')
    if body is None:
        bad('subpic_blend', 'no subpic_blend instantiation found in %s -- the compositor '
                            'is the whole output stage, so this cannot be a skip.' % rel)
    else:
        conn = connections(body)
        for port, pic_src in (('in_r', 'core_r'), ('in_g', 'core_g'), ('in_b', 'core_b')):
            expr = conn.get(port)
            if expr is None:
                bad('subpic_blend.%s' % port, 'port not connected')
                continue
            want_terms('subpic_blend.%s' % port, expr, {'pic_blank', pic_src},
                       'THE PICTURE BLANK ITSELF. Deleting it is the Stop round-1 '
                       'regression ("one stop was supposed to drop you to the idle logo"). '
                       'It blanks the blend INPUT, not the vga_*_q mux where sw_blank '
                       'lives, so the STOP caption and the logo survive it.')
        for port, reg in (('ov_on', 'sp_on_q'), ('ov_force', 'sp_force_q'),
                          ('ov_alpha', 'sp_alpha_q')):
            expr = conn.get(port)
            if expr is None:
                bad('subpic_blend.%s' % port, 'port not connected')
            elif terms(expr) != {reg}:
                bad('subpic_blend.%s' % port,
                    'must be `%s`, found `%s` -- the gate cannot be allowed to be bypassed '
                    'by re-pointing the compositor at an ungated wire.' % (reg, expr))

    # =====================================================================
    # C. WHAT MUST STAY UNGATED -- the half a future reader gets wrong
    # =====================================================================
    hl_use_q = get('reg', 'hl_use_q', 'hl_use_q')
    exact_terms('hl_use_q (O[2] diagnostic)', hl_use_q, {'hl_use'},
                'dbg_blk8/hlvis_seen answers "did the recolour FIRE?", NOT "was it '
                'DISPLAYED?". Feeding it hl_use_e makes a screensaving board report RED '
                'for a highlight that is working perfectly and sends the next debugger '
                'after a phantom. blk8 was already fixed once for this exact class of '
                'mistake (2026-08-17, when it watched sp_force_q).')

    if not re.search(r"else if \(sp_q_inside\)\s*sp_seen <= 1'b1;", src):
        bad('sp_seen (O[2] diagnostic)',
            "the sp_seen sticky must key on the RAW sp_q_inside, not on sp_on_e -- "
            "dbg_blk3 answers 'did a subpicture pixel decode?', and gating it would report "
            "the SPU pipeline as dead whenever the screen is blanked.")

    sp_sel_col = get('wire', 'sp_sel_col', 'sp_sel_col')
    want_terms('sp_sel_col (pgc_palette address)', sp_sel_col, {'hl_use'},
               'unchanged from before the fix')
    reject_terms('sp_sel_col (pgc_palette address)', sp_sel_col, {'hl_use_e'},
                 'The palette ADDRESS stays ungated: with sp_on_e low the colour cannot '
                 'reach the pins, so gating it changes no pixel -- while adding a term to '
                 'a BRAM address path in the display hotspot and creating a SECOND, subtly '
                 'different definition of "the highlight is active" for the next reader to '
                 'pick the wrong one of.')

    reject_terms('sp_on_e (logo)', sp_on_e, {'logo_on_w'},
                 'The idle logo IS the screensaver -- gating it is the obvious wrong '
                 'generalisation of this fix, and it would leave the blanked screen '
                 'showing nothing at all.')

    if fails:
        sys.stderr.write('check_saver_overlay_wiring: FAIL (%s)\n' % rel)
        for f in fails:
            sys.stderr.write('  - %s\n' % f)
        return 1
    print('check_saver_overlay_wiring: PASS (%s) -- pic_blank -> sp_on_e/hl_use_e; '
          'hud_on_e/bar_on_e and the blend inputs intact; O[2] diagnostics and the '
          'palette address ungated' % rel)
    return 0


if __name__ == '__main__':
    sys.exit(main())
