#!/usr/bin/env python3
"""check_frame_step_wiring.py -- the frame-step seam in dvd/emu.sv.

WHY THIS IS A SCRIPT AND NOT A BENCH (2026-09-16)
-------------------------------------------------
Frame step is TWO arms of one priority mux in emu.sv's transport block, and emu.sv
has no bench. The datapath half is covered -- bench/dvd/pickup_hold_tb.sv scenario 5
drives resample_addrgen's `step_req` directly and proves one pulse = exactly one
pickup. What no module bench can see is which FACT emu puts on that wire and, far
more importantly, WHERE IN THE CHAIN the new pause arm sits:

    if (start_streaming)                         pause_q <= 1'b0;
    else if (pause_edge && !stopped_w)           pause_q <= ~pause_q;
    else if (... ff_edge || rew_edge ...)        pause_q <= 1'b0;
    else if (... dpad_seek_en ...)               pause_q <= 1'b0;
    else if (step_edge && ... && step_ok)        pause_q <= 1'b1;   <-- LAST
    if (jump_ack)                                pause_q <= 1'b0;

That is a priority mux over one register, so POSITION IS SEMANTICS. The new arm can
only ever SET pause. At the bottom it cannot mask a resume; hoisted above any
clear-only arm it turns a coincident resume press into a STUCK PAUSE that only B1
undoes -- and coincident edges are real here (an IR remote sends ~9 taps a second,
and gamepad, keyboard and CEC are all live at once). A reordering like that changes
no term, no port and no expression, so it is invisible to every other gate in the
tree, including a Quartus fit.

Two traps this file is written against, both paid for elsewhere in this project:

  1. strip_comments() IS MANDATORY, FIRST. emu.sv's frame-step comments quote the
     surrounding expressions verbatim -- `pause_q || stopped_w`, `!hold_freeze`,
     `pause_edge && !stopped_w` all appear in prose. A grep-based checker would
     PASS ON A FULLY REVERTED FILE. (check_saver_overlay_wiring.py records the same
     hazard around dbg_blk8.)
  2. Every test is over a TOKEN SET, never a substring. `step_ok`, `step_edge`,
     `step_tgl`, `step_dec` and `stopped_w`/`stopped` are mutual substring hazards,
     so `'step_ok' in expr` is true for a file that never mentions step_ok.

And a lookup that returns None is a NAMED FAIL, never a skip: the
check_subp_map_wiring.py `if body is not None:` shape reports success for a file it
never read.

Exit 0 = wired as designed. Exit 1 = a named term or the priority carries the wrong
fact. Optional argv[1] = a file to check instead of dvd/emu.sv, so a runner can
mutate a copy in $TMP and never write the tree.
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


def connections(src, module):
    """{port: expr} for one module instantiation's named connections."""
    # ⚠ allow an optional #(...) parameter block: emu instantiates both overlays as
    # `transport_hud #(.HUD_QX_ADJ(5)) transport_hud_inst (`, and a regex without it
    # silently finds no instance -- which this file treats as a FAIL, but a checker
    # that treated it as a skip would report success for a file it never read.
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
    """Identifiers in an expression.

    ⚠ Verilog literals leak through as tokens (`1'b1` -> `b1`). Use membership, not
    equality, on any expression that contains one.
    """
    return set(re.findall(r'[A-Za-z_]\w*', expr))


def guarded_assign(src, target, value):
    """Find `<target> <= <value>;` and return (keyword, guard, index).

    keyword is 'if' / 'else if' / None (an unguarded assignment). guard is the
    condition text. index is the offset of the assignment, for ordering tests.

    Scans LEFT from the assignment to the '(' that opens its condition, matching
    parens, so a guard containing its own parens still parses.
    """
    pat = re.compile(r'\b%s\s*<=\s*%s\s*;' % (re.escape(target), re.escape(value)))
    m = pat.search(src)
    if not m:
        return None
    head = src[:m.start()].rstrip()
    if not head.endswith(')'):
        # e.g. `else pause_q <= 1'b1;` or a bare statement in a begin/end block
        kw = 'else' if re.search(r'\belse\s*$', head) else None
        return (kw, '', m.start())
    depth, i = 0, len(head) - 1
    while i >= 0:
        if head[i] == ')':
            depth += 1
        elif head[i] == '(':
            depth -= 1
            if depth == 0:
                break
        i -= 1
    if i < 0:
        return (None, '', m.start())
    guard = head[i + 1:len(head) - 1]
    before = head[:i].rstrip()
    if re.search(r'\belse\s+if\s*$', before):
        kw = 'else if'
    elif re.search(r'\bif\s*$', before):
        kw = 'if'
    else:
        kw = None
    return (kw, guard, m.start())


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dvd', 'emu.sv')
    src = norm(strip_comments(open(path, encoding='utf-8').read()))
    rel = os.path.relpath(path, ROOT) if path.startswith(ROOT) else path

    fails = []

    def bad(label, why):
        fails.append('%s: %s' % (label, why))

    def want_terms(label, expr, required, why):
        if expr is not None and not set(required).issubset(terms(expr)):
            missing = sorted(set(required) - terms(expr))
            bad(label, 'missing %s from `%s`. %s' % (', '.join(missing), expr, why))

    def reject_terms(label, expr, forbidden, why):
        if expr is not None:
            present = sorted(set(forbidden) & terms(expr))
            if present:
                bad(label, 'must NOT contain %s -- found `%s`. %s'
                           % (', '.join(present), expr, why))

    def exact_terms(label, expr, expected, why):
        if expr is not None and terms(expr) != set(expected):
            bad(label, 'terms are {%s}, expected exactly {%s} (`%s`). %s'
                       % (', '.join(sorted(terms(expr))), ', '.join(sorted(expected)),
                          expr, why))

    def want_inverted(label, expr, name, why):
        """A term-set check alone passes on `&& menu_active` -- a dropped '!' is the
        single most plausible edit here and it inverts the whole feature. Accepts
        either Verilog negation, since this file mixes `!` and `~`."""
        if expr is not None and not re.search(r'[~!]\s*%s\b' % re.escape(name), expr):
            bad(label, '`%s` is not INVERTED in `%s`. %s' % (name, expr, why))

    # =====================================================================
    # A1/A2. step_ok -- ONE predicate, read by BOTH halves of the gesture
    # =====================================================================
    step_ok = assign_of(src, 'step_ok')
    if step_ok is None:
        bad('step_ok', '`step_ok` is not assigned anywhere in %s. It is THE shared '
                       'frame-step predicate; this gate asserts nothing it cannot find, '
                       'so an absent term is a failure, not a pass.' % rel)
    exact_terms('step_ok', step_ok, {'cell_ready', 'menu_active', 'hold_freeze'},
                'The pausing press and the stepping press must agree about where frame '
                'step is legal -- if they can disagree, the button pauses a title it can '
                'never step, a dead-end pause only B1 undoes. cell_ready is the shipped '
                'scope (widening to a flat .mpg via lin_seek_ok_w must widen BOTH halves '
                'at once); ~hold_freeze is what makes emu agree with the datapath, since '
                'resample_addrgen.v:451,458 gate ofv_paced AND ofv_pickup on ~hold_freeze '
                'unconditionally -- step_arm does NOT bypass it.')
    want_inverted('step_ok', step_ok, 'menu_active',
                  'Without the ! frame step would work ONLY inside a disc menu, which is '
                  'the feature exactly backwards.')
    want_inverted('step_ok', step_ok, 'hold_freeze',
                  'Without the ! frame step would act ONLY during a held FF/REW scrub -- '
                  'the one state in which it can advance nothing, and the state whose '
                  'release (a seek_ack, not a jump_ack) leaves the pause uncleared.')

    # =====================================================================
    # A3/A4/A5/A7. the new arm: the ONLY thing that sets pause_q
    # =====================================================================
    n_set = len(re.findall(r"\bpause_q\s*<=\s*1'b1\s*;", src))
    if n_set != 1:
        bad("pause_q <= 1'b1",
            'found %d such assignments, expected exactly 1. Frame step is the only route '
            'that SETS pause_q (every other arm clears it or toggles it); a second setter '
            'is an unreviewed second way into the four coordinated pause holds.' % n_set)

    arm = guarded_assign(src, 'pause_q', "1'b1")
    if arm is None:
        bad('frame-step pause arm',
            "no `pause_q <= 1'b1;` in %s -- this IS the shipped behaviour this gate "
            "exists to prevent returning to: B18 does nothing at all during playback." % rel)
    else:
        kw, guard, arm_at = arm
        # The guard is the single named wire step_pause_go, shared with the step_paused
        # latch so the two cannot drift; its TERMS are asserted at A15.
        exact_terms('frame-step pause arm', guard, {'step_pause_go'},
                    'The arm must be guarded by the shared `step_pause_go` wire -- an '
                    'inline copy here would be free to drift from the step_paused latch, '
                    'and then a pause could be a step pause for the overlays but not for '
                    'the chain, or the reverse.')
        if kw != 'else if':
            bad('frame-step pause arm',
                'guarded by `%s`, expected `else if`. A bare `if` at the tail of the chain '
                'overrides EVERY resume arm above it -- exactly the priority laundering '
                'that the arm\'s position exists to prevent.' % (kw or 'nothing'))

    # =====================================================================
    # A6. ORDERING -- a set-only arm must sit below every clear-only arm
    # =====================================================================
    if arm is not None:
        arm_at = arm[2]

        def order(label, needle, why, must_precede=True):
            i = src.find(needle)
            if i < 0:
                bad(label, 'cannot find `%s` in %s -- the pause_q chain has been '
                           'restructured, so this gate can no longer prove the frame-step '
                           'arm\'s priority. Re-derive it before editing.' % (needle, rel))
            elif must_precede and i > arm_at:
                bad(label, 'the frame-step arm (which only ever SETS pause) comes BEFORE '
                           'this arm, so it MASKS it on a coincident press. %s' % why)
            elif not must_precede and i < arm_at:
                bad(label, 'the frame-step arm comes AFTER this, so this no longer wins. '
                           '%s' % why)

        order('priority vs start_streaming', "if (start_streaming) pause_q <= 1'b0;",
              'A step press coincident with a fresh mount must not pause the new title.')
        order('priority vs the B1 toggle', "pause_edge && !stopped_w) pause_q <= ~pause_q;",
              'Pause+Step on one cycle must behave as Pause; the B1 button stays '
              'authoritative over its own register.')
        order('priority vs FF/REW resume', 'ff_edge || rew_edge',
              'THIS is the case step_ok\'s ~hold_freeze cannot cover: on the ff_edge cycle '
              'hold_freeze has not risen yet, so PRIORITY is the only thing that stops a '
              'coincident step press from pausing a scrub that was just starting.')
        order('priority vs D-pad seek resume', 'dpad_seek_en &&',
              'A D-pad seek is an explicit resume; a coincident step press must not '
              'override it.')
        order('priority vs jump_ack', "if (jump_ack) pause_q <= 1'b0;",
              'A VM jump must still clear pause -- a paused governor would freeze the menu '
              'the VM is jumping to.', must_precede=False)

    # =====================================================================
    # A8/A9. the STEP arm, and that both halves share one predicate
    # =====================================================================
    step_arm = guarded_assign(src, 'step_tgl', '~step_tgl')
    if step_arm is None:
        bad('frame-step step arm',
            'no `step_tgl <= ~step_tgl;` in %s -- the CDC toggle that carries a press to '
            'the decoder is gone, so nothing steps at all.' % rel)
    else:
        want_terms('frame-step step arm', step_arm[1],
                   {'step_edge', 'pause_q', 'stopped_w', 'step_ok'},
                   '(pause_q || stopped_w) is what keeps the FIRST press on a live title '
                   'from also arming a step: while live an ordinary pickup happens every '
                   'frame and pause_dec is 2 CDC flops deep where step_dec needs 3, so an '
                   'arm raised on the pausing press is eaten by a pickup that was going to '
                   'happen anyway -- one press would advance one frame or two depending '
                   'only on raster phase. step_ok must be the SHARED predicate, not an '
                   'inline copy that can drift from the pause arm\'s.')

    # =====================================================================
    # A10. the exact inversion -- frame step must never RESUME
    # =====================================================================
    for m in re.finditer(r"\bpause_q\s*<=\s*1'b0\s*;", src):
        # re-scan each clear arm's own guard from its own position
        head = src[:m.start()].rstrip()
        if head.endswith(')'):
            depth, i = 0, len(head) - 1
            while i >= 0:
                if head[i] == ')':
                    depth += 1
                elif head[i] == '(':
                    depth -= 1
                    if depth == 0:
                        break
                i -= 1
            if i >= 0 and 'step_edge' in terms(head[i + 1:len(head) - 1]):
                bad('a pause_q clear arm',
                    'contains step_edge (`%s`) -- frame step must never RESUME playback. '
                    'That is the feature inverted: the first press would un-pause instead '
                    'of pausing.' % head[i + 1:len(head) - 1])

    # =====================================================================
    # A11. the pause must actually freeze something
    # =====================================================================
    for name in ('pause_gov', 'pause_aud'):
        rhs = assign_of(src, name)
        if rhs is None:
            bad(name, '`%s` is not assigned in %s -- it is what carries pause_q to the '
                      'governor/audio holds.' % (name, rel))
        exact_terms(name, rhs, {'pause_q', 'hold_freeze', 'stopped_w'},
                    'If %s loses pause_q the new pause freezes NOTHING and the feature is '
                    'a silent no-op -- no error anywhere, the button just stops working.'
                    % name)

    # =====================================================================
    # A12. the CDC must stay an EDGE, and the decoder must read it
    # =====================================================================
    step_dec = assign_of(src, 'step_dec')
    if step_dec is None:
        bad('step_dec', '`step_dec` is not assigned in %s -- it is the one-cycle pulse the '
                        'decoder\'s step_arm latches.' % rel)
    exact_terms('step_dec', step_dec, {'step_t2', 'step_t3'},
                'step_dec must be the toggle-difference `step_t2 ^ step_t3`. A LEVEL here '
                '(step_tgl, say) holds resample_addrgen\'s step_arm open and lets many '
                'pickups through per press -- one press would run, not step.')

    mv = connections(src, 'mpeg2video')
    if mv is None:
        bad('mpeg2video instance', 'not found in %s -- cannot prove the step pulse reaches '
                                   'the decoder.' % rel)
    elif 'step_req' not in mv:
        bad('mpeg2video .step_req', 'port not connected in %s. Quartus would tie it low and '
                                    'frame step would do nothing, silently.' % rel)
    else:
        exact_terms('mpeg2video .step_req', mv['step_req'], {'step_dec'},
                    'The decoder must receive the one-cycle pulse, not the raw toggle.')

    # =====================================================================
    # A14. stepping must be able to REFILL the VBUF it consumes
    # =====================================================================
    # MEASURED on the rig 2026-09-16: with the audio backpressure frozen ARMED under
    # pause, stepping got 17 frames and then died with vbuf_fill at 0; with the audio
    # path out of the way, 35 presses gave 35 steps and vbuf_fill never moved. `pause`
    # never reaches the vld, so each step consumes a picture out of the VBUF, and the
    # frozen watchdog stops the shared demux stream from refilling it.
    aud_rdy = assign_of(src, 'ps_aud_ready') or assign_stmt(src, 'ps_aud_ready')
    if aud_rdy is None:
        bad('ps_aud_ready', '`ps_aud_ready` is not assigned in %s -- it is the demux audio '
                            'backpressure that starves the VBUF a step consumes.' % rel)
    exact_terms('ps_aud_ready', aud_rdy,
                {'aud_ring_almost_full', 'aud_bp_armed', 'step_session'},
                'Without step_session the audio backpressure stays engaged for the whole '
                'pause (the drain watchdog is deliberately FROZEN there), the shared demux '
                'byte stream never refills the VBUF, and frame step dies after however many '
                'pictures happened to be buffered -- MEASURED at 17 on the rig. This is the '
                'reported "only about 20 frames" defect.')
    want_inverted('ps_aud_ready', aud_rdy, 'step_session',
                  'A step session must RELEASE the backpressure. Un-inverted it would '
                  'engage backpressure only while stepping, which is the defect made '
                  'permanent.')

    # The set term must be a step_tgl TRANSITION, not step_edge: only step_tgl records a
    # press the transport block actually accepted, so a press in a menu or during a held
    # scrub cannot start a session.
    sess_blk = re.search(r'step_tgl_q <= step_tgl;.{0,400}?end', src)
    if sess_blk is None:
        bad('step_session', 'cannot find the step_session block in %s -- it must latch on a '
                            '`step_tgl` transition and clear on ~pause_aud.' % rel)
    else:
        blk = sess_blk.group(0)
        want_terms('step_session', blk, {'step_tgl', 'step_tgl_q', 'pause_aud'},
                   'The session latches on a step_tgl TRANSITION (only an ACCEPTED press '
                   'toggles it -- step_edge would also fire in a menu or during a scrub) '
                   'and clears on ~pause_aud, which covers every resume in one term.')
        reject_terms('step_session', blk, {'step_edge'},
                     'step_edge is the raw press and fires where frame step is illegal; '
                     'step_tgl only moves for a press the transport block accepted.')

    # =====================================================================
    # A15. a frame-step pause must NOT hold the overlays up, and B9 must still work
    # =====================================================================
    # 2026-09-17, by user decision: a pause the user asked for with B1 keeps the status
    # line and seek bar up; a pause the FRAME STEP button started does not. The disc is
    # paused either way, so transport_hud's ICON must keep reading the real pause_q --
    # only the "hold it up" term follows step_paused.
    go = assign_of(src, 'step_pause_go')
    if go is None:
        bad('step_pause_go', '`step_pause_go` is not assigned in %s. TWO things must agree '
                             'on "this press starts a frame-step pause" -- the pause_q arm '
                             'and the step_paused latch -- so it is one named wire.' % rel)
    exact_terms('step_pause_go', go, {'step_edge', 'pause_q', 'stopped_w', 'step_ok'},
                'See the pause arm: step_edge is the press, !pause_q and !stopped_w keep '
                'the two frame-step arms exclusive, step_ok is the shared predicate.')

    sp_blk = re.search(r"if \(~pause_q\)\s*step_paused\s*<=\s*1'b0;\s*"
                       r"else if \(step_pause_go\)\s*step_paused\s*<=\s*1'b1;", src)
    if sp_blk is None:
        bad('step_paused', "the step_paused latch is not `if (~pause_q) 0; else if "
                           "(step_pause_go) 1;` in %s. Clearing on ~pause_q is what makes a "
                           "B1 pause come up visible (pause_q is low on the cycle B1 sets "
                           "it, so the clear arm holds it 0); clearing on ~pause_aud instead "
                           "would let a Stop or a held scrub count as a frame-step pause."
                           % rel)

    hud = connections(src, 'transport_hud')
    if hud is None:
        bad('transport_hud instance', 'not found in %s.' % rel)
    else:
        for port, want in (('pause_q', {'pause_q'}),
                           ('pause_vis', {'pause_q', 'step_paused'})):
            if port not in hud:
                bad('transport_hud .%s' % port,
                    'port not connected in %s. .pause_q is the STATE (the icon) and '
                    '.pause_vis is the hold; they are deliberately different facts and '
                    'both must be driven.' % rel)
            else:
                exact_terms('transport_hud .%s' % port, hud[port], want,
                            'The icon must read the real pause state, and the hold must be '
                            'masked by step_paused. Swapping them makes a frame-step pause '
                            'either invisible-but-showing-PLAY or visible again.')
        want_inverted('transport_hud .pause_vis', hud.get('pause_vis'), 'step_paused',
                      'Un-inverted, the line would be held up ONLY during a frame-step '
                      'pause -- the feature exactly backwards.')

    bar = connections(src, 'seek_bar')
    if bar is None:
        bad('seek_bar instance', 'not found in %s.' % rel)
    elif 'pause_vis' not in bar:
        bad('seek_bar .pause_vis', 'port not connected in %s -- the bar would never come up '
                                   'on a pause (or, if still named pause_q, would carry a '
                                   'wrong fact on a correctly-named port).' % rel)
    else:
        exact_terms('seek_bar .pause_vis', bar['pause_vis'], {'pause_q', 'step_paused'},
                    'The seek bar has no icon, so it takes the hold only -- same mask as '
                    'the status line, or the two overlays disagree about one pause.')
        want_inverted('seek_bar .pause_vis', bar['pause_vis'], 'step_paused',
                      'See transport_hud .pause_vis.')

    # =====================================================================
    # A13. hud_user_evt stays OUT of this -- pinned BY REJECTION
    # =====================================================================
    hud = assign_of(src, 'hud_user_evt')
    if hud is None:
        bad('hud_user_evt', '`hud_user_evt` is not assigned in %s.' % rel)
    reject_terms('hud_user_evt', hud, {'step_edge'},
                 'The HUD already handles this WITHOUT an event: transport_hud.sv:288 and '
                 'seek_bar.sv:139 take pause_q as a visibility LEVEL (its port comment is '
                 '"manual pause (keeps the line up)"), so the pausing press raises the '
                 'status line with the pause icon and holds it for the whole pause. Adding '
                 'step_edge would instead re-arm the ~2.5 s show timer on EVERY press of a '
                 'stepping burst, changing behaviour the 2026-09-13 HW round signed off. '
                 'If parity is ever wanted, add a named step_pause_evt (the pausing press '
                 'only), never the raw edge.')

    if fails:
        sys.stderr.write('check_frame_step_wiring: FAIL (%s)\n' % rel)
        for f in fails:
            sys.stderr.write('  - %s\n' % f)
        return 1
    print('check_frame_step_wiring: PASS (%s) -- step_ok shared by both arms; the pause '
          'arm is the LAST else-if and the only pause_q setter; step_dec is an edge into '
          'the decoder; hud_user_evt untouched' % rel)
    return 0


if __name__ == '__main__':
    sys.exit(main())
