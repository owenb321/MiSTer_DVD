#!/usr/bin/env python3
"""check_select_noop.py -- the Select seam in dvd/emu.sv.

WHY THIS IS A SCRIPT AND NOT A BENCH (2026-09-17)
-------------------------------------------------
The fix for "hit Select during a menu transition and it kicks me back to the boot
chain" is a DELETION in emu.sv, and emu.sv has no bench. Until this change the
transport block read:

    if (menu_nav || in_title_menu) begin ... nav_act_p <= sel_edge; end
    else if (in_title_hli && sel_edge)       nav_act_p <= 1'b1;
    if (menus_on && menu_active && sel_edge && !hl_btns_armed)
        key_resume_p <= 1'b1;               <-- RE-INTERPRETED the press

i.e. one button carried TWO meanings, chosen by whether a highlight happened to be
armed. A menu transition is exactly the not-armed window (every cell seek / VM jump
pulses load_flush -> pipe_rst_n -> nav_pci disarms, and a transition cell's NAV packs
carry hli_ss=0 so nothing re-arms for the length of the clip), and dvd_vm's ev_resume
was the one user event NOT invalidated by a PGC load -- so the press outlived the
transition and LinkRSM'd out of the menu that had just arrived.

What no module bench can see is that emu stopped putting a second fact on that edge.
dvd_vm_tb cannot: the port is gone, so there is nothing left to drive. nav_pci_tb
cannot: it is handed nav_act directly and was always correct. The claim lives in one
file that nothing elaborates but Quartus.

So this file asserts the INVARIANT rather than the deletion:

    Select has exactly one meaning. Every statement in dvd/emu.sv that reads
    sel_edge also writes nav_act_p, no net named key_resume* is driven anywhere,
    and the dvd_vm instance has no .key_resume port.

★ The last three checks are ANTI-VACUITY controls, and without them a file that
deleted Select altogether -- or deleted the Menu key, which now solely owns the
resume toggle -- would pass the first three cleanly. "Nothing drives it" is not the
property we want; "one thing drives it, and the paths it must reach are intact" is.

Two traps this file is written against, both paid for elsewhere in this project:

  1. strip_comments() IS MANDATORY, FIRST. The replacement comment in emu.sv quotes
     the DELETED code verbatim -- `key_resume_p <= 1'b1;` and the whole
     `menus_on && menu_active && sel_edge && !hl_btns_armed` condition appear in
     prose, on purpose, so the next reader knows what not to re-add. A grep-based
     checker would therefore FAIL ON THE FIXED FILE and, worse, a differently-worded
     one would PASS ON A FULLY REVERTED FILE. (check_frame_step_wiring.py and
     check_saver_overlay_wiring.py record the same hazard.)
  2. Every test is over a TOKEN SET, never a substring. `key_resume` is a substring
     of nothing here, but `nav_act` is a substring of `nav_act_p`, and `sel_edge` of
     nothing while `menu_edge`/`title_edge` share its suffix -- so `'nav_act' in expr`
     and friends are the wrong shape and are not used.

And a lookup that returns None is a NAMED FAIL, never a skip: the
check_subp_map_wiring.py `if body is not None:` shape reports success for a file it
never read.

Exit 0 = wired as designed. Exit 1 = a named term or a second consumer is present.
Optional argv[1] = a file to check instead of dvd/emu.sv, so a runner can mutate a
copy in $TMP and never write the tree.
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


def terms(expr):
    """Identifiers in an expression. Verilog literals leak through (1'b1 -> b1)."""
    return set(re.findall(r'[A-Za-z_]\w*', expr))


def connections(src, module):
    """{port: expr} for one module instantiation's named connections, or None."""
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


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dvd', 'emu.sv')
    try:
        raw = open(path).read()
    except OSError as e:
        print('FAIL: cannot read %s: %s' % (path, e))
        return 1
    src = strip_comments(raw)
    fails = []

    # ---- 1. sel_edge is still the Select button's edge ----------------------
    m = re.search(r'\b(?:wire|reg|logic)\b[^;=]*?\bsel_edge\s*=\s*([^;]+);', src)
    if not m:
        fails.append('sel_edge: no declaration found (did the Select decode move?)')
    else:
        if 'joy_sel' not in terms(m.group(1)):
            fails.append('sel_edge: no longer derived from joy_sel -- got `%s`'
                         % ' '.join(m.group(1).split()))

    # ---- 2. every statement that READS sel_edge also writes nav_act_p -------
    # Verilog statements end in ';', so splitting there gives whole statements (a
    # chunk may carry trailing begin/end/if-header tokens from its neighbour, which
    # is harmless). A statement that reads the Select edge and writes something
    # ELSE is a second meaning for the button -- the shape of the defect, and the
    # shape the next "Select should also..." patch will take.
    readers = 0
    for chunk in src.split(';'):
        t = terms(chunk)
        if 'sel_edge' not in t:
            continue
        if 'sel_edge' in t and re.search(r'\bsel_edge\s*=', chunk):
            continue                      # the declaration itself, checked above
        readers += 1
        if 'nav_act_p' not in t:
            fails.append('sel_edge has a second consumer: `%s`'
                         % ' '.join(chunk.split())[-160:])
    if readers == 0:
        fails.append('sel_edge: nothing reads it -- Select would do nothing at all')

    # ---- 3. no key_resume* net is driven anywhere ---------------------------
    stray = sorted(w for w in terms(src) if w.startswith('key_resume'))
    if stray:
        fails.append('key_resume is back: %s' % ', '.join(stray))

    # ---- 4/5/6. the instantiated seams ------------------------------------
    vm = connections(src, 'dvd_vm')
    if vm is None:
        fails.append('dvd_vm: no instantiation found (cannot check its ports)')
    else:
        if 'key_resume' in vm:
            fails.append('dvd_vm: the .key_resume port is back -> `%s`'
                         % vm['key_resume'])
        # ANTI-VACUITY: the Menu key now solely owns the resume toggle, so it must
        # still be wired. Deleting it would make check 3 pass for the wrong reason.
        if 'key_menu' not in vm:
            fails.append('dvd_vm: .key_menu is missing -- nothing can resume a title')
        elif 'key_menu_p' not in terms(vm['key_menu']):
            fails.append('dvd_vm: .key_menu no longer carries key_menu_p -> `%s`'
                         % vm['key_menu'])

    nav = connections(src, 'nav_pci')
    if nav is None:
        fails.append('nav_pci: no instantiation found (cannot check its ports)')
    else:
        # ANTI-VACUITY: Select must still REACH the activate path. Without this, a
        # file that removed activation entirely passes checks 2 and 3.
        if 'nav_act' not in nav:
            fails.append('nav_pci: .nav_act is missing -- Select cannot activate')
        elif 'nav_act_p' not in terms(nav['nav_act']):
            fails.append('nav_pci: .nav_act no longer carries nav_act_p -> `%s`'
                         % nav['nav_act'])

    if fails:
        for f in fails:
            print('FAIL: %s' % f)
        return 1
    print('OK: sel_edge -> nav_act_p only (%d reader(s)); no key_resume; '
          'dvd_vm.key_menu and nav_pci.nav_act intact' % readers)
    return 0


if __name__ == '__main__':
    sys.exit(main())
