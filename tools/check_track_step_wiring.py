#!/usr/bin/env python3
"""check_track_step_wiring.py -- the show-first Audio/Subtitle seam in dvd/emu.sv.

WHAT IS GATED (2026-10-01, docs/track_selection.md "Show-first Audio/Subtitle")
-----------------------------------------------------------------------------
A set-top player's Audio and Subtitle buttons SHOW the current setting on the
first press and CHANGE it only when pressed again while that setting is on
screen. transport_hud owns the popup slot, so it decides "is my popup up" and
hands back aud_step_o / sub_step_o; transport_hud_tb T26 proves that half. What
no module bench can see is whether emu.sv steps the track on THOSE pulses or on
the raw press -- and the raw press is the pre-change behaviour, one token away:

    if (aud_step_w)  aud_cur <= ...      <- this file's whole point
    if (audio_edge)  aud_cur <= ...      <- the reverted build, still compiles

The VM-ownership release is the same trap with a worse symptom: on the raw edge,
a show-only press silently swaps a menu-chosen track for aud_cur with no cue.

Also gated: the step starts from the EFFECTIVE track (what the popup showed),
the popup shows the effective track, and the saver / stage-2 Stop mask the step
(a popup under them is not on screen).

strip_comments() comes first (the comments quote `if (audio_edge)` verbatim) and
every test is over a token set, never a substring (`aud_step_w` vs
`hud_aud_step_w`). A lookup that finds nothing is a named FAIL, never a skip.

Exit 0 = wired as designed. Optional argv[1] = a file to check instead of
dvd/emu.sv, so bench/dvd/run_track_show.sh can mutate a copy in $TMP.
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


def assign_of(src, name):
    """RHS of `wire/reg/logic ... <name> = <expr>;` (continuous assignment)."""
    m = re.search(r'\b(?:wire|reg|logic)\b[^;=]*?\b%s\s*=\s*([^;]+);' % re.escape(name), src)
    return m.group(1).strip() if m else None


def assign_stmt(src, name):
    """RHS of a standalone `assign <name> = <expr>;` (the net is declared elsewhere)."""
    m = re.search(r'\bassign\s+%s\s*=\s*([^;]+);' % re.escape(name), src)
    return m.group(1).strip() if m else None


def block_after(src, head_re):
    """Text of the single begin..end block opened by head_re (balanced), or None."""
    hits = list(re.finditer(head_re, src))
    if len(hits) != 1:
        return None
    i, depth = hits[0].end(), 1
    for m in re.finditer(r"\b(begin|end)\b", src[i:]):
        depth += 1 if m.group(1) == 'begin' else -1
        if depth == 0:
            return src[i:i + m.start()]
    return None


def connections(src, module):
    """{port: expr} for one module instantiation's named connections."""
    # allow an optional #(...) parameter block (transport_hud is instantiated with one)
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


def terms(expr):
    """Identifiers in an expression (Verilog literals leak through: `1'b1` -> `b1`)."""
    return set(re.findall(r'[A-Za-z_]\w*', expr))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dvd', 'emu.sv')
    src = norm(strip_comments(open(path, encoding='utf-8').read()))
    rel = os.path.relpath(path, ROOT) if path.startswith(ROOT) else path
    fails = []

    def bad(label, why):
        fails.append('%s: %s' % (label, why))

    def one_guard(label, stmt_re, what):
        """The condition of the single `if (<cond>) <stmt_re>` in the file."""
        hits = re.findall(r'\bif\s*\(([^()]*)\)\s*' + stmt_re, src)
        if len(hits) != 1:
            bad(label, 'expected exactly one `if (...) %s`, found %d' % (what, len(hits)))
            return None
        return hits[0]

    def guard_is(label, guard, want, why):
        if guard is not None and terms(guard) != {want}:
            bad(label, 'guarded by `%s`, want `%s`. %s' % (guard.strip(), want, why))

    # A1/A2 -- the selection steps on the STEP pulse, not the press.
    g = one_guard('A1', r"aud_cur\s*<=\s*\(", 'aud_cur <= (...)')
    guard_is('A1', g, 'aud_step_w',
             'The Audio press must only SHOW; a raw-edge guard is the old cycle-on-every-press.')
    # Since PR #152 the Subtitle step has TWO branches inside `if (sub_step_w)`:
    # step over the PGC's declared streams, or (no table) over the stream count. So
    # the rule is structural: every `if (!sub_on_eff)` step branch in the file must
    # lie inside the single `if (sub_step_w) begin ... end` block.
    sub_blk = block_after(src, r"\bif\s*\(\s*sub_step_w\s*\)\s*begin")
    n_all = len(re.findall(r"\bif\s*\(\s*!\s*sub_on_eff\s*\)", src))
    if sub_blk is None:
        bad('A2', 'expected exactly one `if (sub_step_w) begin ... end` block')
    else:
        n_in = len(re.findall(r"\bif\s*\(\s*!\s*sub_on_eff\s*\)", sub_blk))
        if n_in == 0 or n_in != n_all:
            bad('A2', '%d of %d `if (!sub_on_eff)` step branches are inside `if (sub_step_w)`. '
                      'The Subtitle press must only SHOW; a raw-edge guard is the old '
                      'cycle-on-every-press.' % (n_in, n_all))

    # A3 -- the VM SetSTN ownership is released by a STEP, never a show press.
    g = one_guard('A3', r"vm_owns_aud\s*<=\s*1'b0\s*;", "vm_owns_aud <= 1'b0;")
    guard_is('A3', g, 'aud_step_w',
             'A show-only press would silently swap the menu-chosen audio track for aud_cur.')
    g = one_guard('A3', r"vm_owns_sp\s*<=\s*1'b0\s*;", "vm_owns_sp <= 1'b0;")
    guard_is('A3', g, 'sub_step_w',
             'A show-only press would silently drop the menu-chosen subtitle.')

    # A4/A5 -- the step is the HUD's pulse, masked by what hides the HUD outside it.
    for net, hud_net in (('aud_step_w', 'hud_aud_step_w'), ('sub_step_w', 'hud_sub_step_w')):
        rhs = assign_of(src, net)
        if rhs is None:
            bad('A4', '`wire %s = ...` not found' % net)
        elif terms(rhs) != {hud_net, 'hud_hidden_w'} or '~' not in rhs or '|' in rhs:
            bad('A4', '`%s = %s`, want `%s & ~hud_hidden_w`. The step must be the HUD\'s '
                      'own "popup is up" pulse, masked when the HUD is blanked.'
                % (net, rhs, hud_net))
    rhs = assign_stmt(src, 'hud_hidden_w')
    if rhs is None:
        bad('A5', '`assign hud_hidden_w = ...` not found')
    elif terms(rhs) != {'saver_on_w', 'stop_full'} or '&' in rhs:
        bad('A5', '`hud_hidden_w = %s`, want saver_on_w | stop_full -- the two masks on '
                  'hud_on_e. A popup under either is not on screen, so it must not step.' % rhs)

    # A6 -- the HUD gets the RAW presses (every press shows / refreshes the popup)
    # and hands the step pulses back.
    hud = connections(src, 'transport_hud')
    if hud is None:
        bad('A6', 'no transport_hud instance found')
    else:
        for port, want in (('aud_evt', 'audio_edge'), ('sub_evt', 'sub_edge'),
                           ('aud_step_o', 'hud_aud_step_w'), ('sub_step_o', 'hud_sub_step_w')):
            if hud.get(port) != want:
                bad('A6', '.%s(%s), want .%s(%s)' % (port, hud.get(port), port, want))
        # A7 -- the popup answers with the EFFECTIVE selection: the show press is
        # a query, and when a menu SetSTN owns the track aud_cur is not the answer.
        for port, need in (('aud_no', 'aud_log'), ('sub_enabled', 'sub_on_eff'),
                           ('sub_no', 'sp_sel')):
            e = hud.get(port)
            if e is None or need not in terms(e) or {'aud_cur', 'sub_idx', 'sub_on'} & terms(e):
                bad('A7', '.%s(%s) must show the effective selection (%s)' % (port, e, need))
    rdr = connections(src, 'dvd_iso_reader')
    if rdr is None:
        bad('A7', 'no dvd_iso_reader instance found')
    else:
        for port, want in (('attr_a_sel', 'aud_log'), ('attr_s_sel', 'sp_sel')):
            if rdr.get(port) != want:
                bad('A7', '.%s(%s), want %s -- the popup language must belong to the '
                          'track the popup number names' % (port, rdr.get(port), want))

    # A8 -- the step starts from what the popup SHOWED, so "AUD 2" steps to 3.
    # (the step's assignment, not the restore's sync from SPRM1 -- docs/nav_engine.md §11)
    m = re.search(r"if\s*\(\s*aud_step_w\s*\)\s*aud_cur\s*<=\s*\(([^;]*);", src)
    if not m or 'aud_log' not in terms(m.group(1)) or 'aud_cur' in terms(m.group(1)):
        bad('A8', 'the Audio step must advance from aud_log (the effective track), not aud_cur')
    # Every ADVANCING subtitle step must come from sp_sel: directly (`sp_sel + 1`, the
    # no-table branch) or as subp_next_decl, the subp_decl instance's .next output,
    # whose .cur must be sp_sel (the next declared stream above the effective track).
    # subp_first_decl is the start from OFF, not an advance. Nothing may read sub_idx.
    steps = re.findall(r"sub_idx\s*<=\s*([^;]*);", sub_blk) if sub_blk else []
    dec = connections(src, 'subp_decl') or {}
    above = ('subp_declared %s' % dec.get('cur', '')) if dec.get('next') == 'subp_next_decl' \
        else (assign_of(src, 'subp_above') or '')
    moving = [r for r in steps if terms(r) - {'d0'} - {'subp_first_decl'}]
    def from_sel(r):
        t = terms(r)
        if 'sub_idx' in t:
            return False
        if 'sp_sel' in t:
            return True
        return t == {'subp_next_decl'} and 'sp_sel' in terms(above) \
            and 'subp_declared' in terms(above)
    if not moving or not all(from_sel(r) for r in moving):
        bad('A8', 'the Subtitle step must advance from sp_sel (the effective track), '
                  'got sub_idx <= %s (subp_above = %s)' % (moving or None, above or None))

    # A9 -- nothing else consumes the raw presses (a new reader of audio_edge is
    # a new place a show press could change state).
    for net in ('audio_edge', 'sub_edge'):
        n = len(re.findall(r'\b%s\b' % net, src))
        if n != 2:
            bad('A9', '`%s` appears %d times; want 2 (its definition and the HUD\'s '
                      'event port). A new consumer is a place a show press acts.' % (net, n))

    if fails:
        print('check_track_step_wiring: FAIL (%s)' % rel)
        for f in fails:
            print('  ' + f)
        return 1
    print('check_track_step_wiring: OK (%s) -- A1-A9: steps on the HUD step pulse, '
          'shows the effective track' % rel)
    return 0


if __name__ == '__main__':
    sys.exit(main())
