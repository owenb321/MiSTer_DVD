#!/usr/bin/env python3
"""Gate for issue #81: check WHICH FACTS emu.sv puts on subp_stream_map's inputs.

WHY THIS EXISTS, AND WHY IT IS NOT A UNIT TEST
----------------------------------------------
`subp_stream_map`'s truth table did not change when #81 was fixed. The old
`ctx_menu ? ~dom_tt : dom_tt` is the same function of (dom_tt, that bit) as the
new `dom_tt != menu_dom`; what changed is which of emu's signals is wired to it:

    pre-#81   .ctx_menu (menu_sp_ctx)     <- the menu CONTEXT  (menu_active | in-title menu)
    post-#81  .menu_dom (menu_dom_live)   <- the menu DOMAIN   (menus_on && menu_active)

So the module's own bench cannot fail for the reason the bug existed, and there
is no emu-level testbench in this project. This reads the port connection out of
`dvd/emu.sv` instead of restating it -- the `tools/acmod_scan.py` /
`csync_pipe_tb` pattern: a gate that cannot go stale, because the thing it
asserts is the source file.

Two ports are checked, both of which carried the wrong fact before #81:

  .menu_dom  must be the menu DOMAIN (menus_on && menu_active), never the menu
             CONTEXT (which includes sp_menu_early, the in-title game/motion menu)
  .wide      must reach the TITLE VTS's IFO aspect (title_ar_wide) in the in-title
             MENU context, because libdvdnav's vm_get_video_attr() returns
             vtsi_mat->vts_video_attr in DVD_DOMAIN_VTSTitle -- the MPEG sequence
             header is not what a conforming player reads, and a menu authored 16:9
             anamorphic with a 4:3 sequence-header code would take the 4:3 field

It is RED on the pre-fix file (no `.menu_dom` port at all, and `.wide` on the
sequence header) and RED on the plausible re-regressions (`.menu_dom
(menu_sp_ctx)` -- a context, not a domain; `.wide (ar_wide_auto_eff)`).

    python3 tools/check_subp_map_wiring.py [emu.sv]     # exit 0 = wired right
    git show <pre-fix>:dvd/emu.sv > /tmp/old.sv && \
        python3 tools/check_subp_map_wiring.py /tmp/old.sv    # must exit 1

⚠ Walks to the instantiation's matching ')' and strips comments -- do NOT
"simplify" it to a grep. emu.sv is 5k lines with commented-out history in it
(the CONF_STR lesson in CLAUDE.md), and a loose grep finds connections that are
not connections.
"""
import os
import re
import sys

INST = 'subp_stream_map'


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


def find_instance(src):
    """Return the text between the instantiation's '(' and its matching ')'."""
    # module-type name, then an instance name, then '('
    m = re.search(r'\b%s\s+(\w+)\s*\(' % INST, src)
    if not m:
        return None, None
    depth, i, n = 0, m.end() - 1, len(src)
    while i < n:
        if src[i] == '(':
            depth += 1
        elif src[i] == ')':
            depth -= 1
            if depth == 0:
                return m.group(1), src[m.end():i]
        i += 1
    return m.group(1), None


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
    """The right-hand side of `wire ... <name> = <expr>;` (first match)."""
    m = re.search(r'\b(?:wire|reg|logic)\b[^;=]*?\b%s\s*=\s*([^;]+);' % re.escape(name), src)
    return ' '.join(m.group(1).split()) if m else None


def terms(expr):
    """Identifiers in an expression, minus Verilog literals."""
    return set(re.findall(r'[A-Za-z_]\w*', expr))


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, 'dvd', 'emu.sv')
    src = strip_comments(open(path).read())

    fails = []
    inst, body = find_instance(src)
    if inst is None:
        fails.append('no %s instantiation found in %s' % (INST, path))
        body = None
    elif body is None:
        fails.append('%s instantiation is unterminated (no matching ")")' % INST)

    conn = connections(body) if body else {}

    if 'ctx_menu' in conn:
        fails.append('port .ctx_menu is still connected (%s) -- issue #81 renamed it to '
                     '.menu_dom because "menu context" is not "menu domain"'
                     % conn['ctx_menu'])

    expr = conn.get('menu_dom')
    if expr is None:
        if body is not None:
            fails.append('port .menu_dom is not connected on %s' % (inst,))
    else:
        # Resolve one level of indirection: .menu_dom (menu_dom_live) -> its assign.
        rhs = expr
        if re.fullmatch(r'\w+', expr):
            a = assign_of(src, expr)
            if a is not None:
                rhs = a
        t = terms(rhs)
        if 'menu_active' not in t:
            fails.append('.menu_dom (%s) does not depend on menu_active -- it must be '
                         '"a MENU-DOMAIN PGC is loaded", i.e. menus_on && menu_active'
                         % expr)
        # The #81 defect, exactly: a menu CONTEXT includes the in-title menu.
        for bad in ('sp_menu_early', 'hl_menu_seen', 'in_title_menu', 'in_title_hli',
                    'menu_sp_ctx'):
            if bad in t:
                fails.append('.menu_dom (%s) resolves through `%s` -- that is the menu '
                             'CONTEXT, and a title-domain game/motion menu is a menu '
                             'context in the TITLE domain. This is issue #81.'
                             % (expr, bad))

    # ---- .wide: the IFO's aspect for a menu, not the sequence header's --------
    # Same class of defect as .menu_dom -- a port carrying the wrong FACT -- and it
    # is the one that decides whether #81's fix does anything: the map picks the
    # [28:24] (4:3) field when `wide` is 0, and DVD menus are routinely authored
    # 16:9 anamorphic with a 4:3 sequence-header code. libdvdnav's
    # vm_get_video_attr() returns vtsi_mat->vts_video_attr in DVD_DOMAIN_VTSTitle,
    # so an in-title menu must resolve against the IFO.
    wexpr = conn.get('wide')
    if wexpr is None:
        if body is not None:
            fails.append('port .wide is not connected on %s' % (inst,))
    else:
        wrhs = wexpr
        if re.fullmatch(r'\w+', wexpr):
            a = assign_of(src, wexpr)
            if a is not None:
                wrhs = a
        wt = terms(wrhs)
        if not any('title_ar_wide' in x for x in wt):
            fails.append('.wide (%s) never reaches the TITLE VTS\'s IFO aspect '
                         '(title_ar_wide) -- an in-title menu would resolve its '
                         'subpicture variant against the MPEG sequence header, which '
                         'is not what a conforming player reads (issue #81)' % wexpr)
        if 'sp_menu_early' not in wt:
            fails.append('.wide (%s) does not distinguish the in-title MENU context '
                         '(sp_menu_early) -- the IFO aspect must apply THERE and '
                         'nowhere else, or every subtitle path moves with it' % wexpr)

    if fails:
        print('FAIL  subp_stream_map wiring in %s' % path)
        for f in fails:
            print('   - %s' % f)
        return 1

    print('PASS  subp_stream_map.menu_dom <- %s  (a DOMAIN fact, not a menu context)'
          % expr)
    print('PASS  subp_stream_map.wide     <- %s  (the IFO aspect in a menu context)'
          % wexpr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
