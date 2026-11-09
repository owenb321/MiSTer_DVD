#!/usr/bin/env python3
"""check_menu_panscan_wiring.py -- a 16:9 menu's permitted display mode overrides
the Analog Aspect Letterbox/Crop choice (docs/crt_anamorphic.md §12).

WHY THIS IS A SCRIPT AND NOT A BENCH (2026-10-01)
-------------------------------------------------
The feature is a handful of terms in emu.sv's analog_letterbox / analog_crop
resolve, fed by one new reader port (menu_ar_df, the IFO V_ATR permitted_df bits).
emu.sv has no bench, and a module bench would be HANDED the two enables -- it could
not see a wrong term in the resolve or a dropped port. So this reads the resolve
out of dvd/emu.sv and EVALUATES it: every comb definition in the closure of
analog_letterbox/analog_crop is parsed into an expression tree and run across the
whole input space (every combination of FREE, 1,024 points) against the reference
model below. A token grep
would pass a swapped `== 2'd1` / `== 2'd2`, a dropped menu gate, or a `&` that
became `|`; a truth table does not.

The contract (the reference model):
  * Only while a 16:9 MENU is up (menus_on & menu_active & menu_ar_wide_w).
  * permitted_df == 1 (letterbox denied): a Letterbox -- or Auto-on-16:9 -- choice
    becomes Crop. permitted_df == 2 (pan&scan denied): a Crop choice becomes
    Letterbox. df 0 / df 3 and Fit are never touched.
  * Titles (menu_active = 0) on the interlaced raster resolve EXACTLY as before the
    feature -- by user decision the title's own flag is not honoured (935/940
    features deny P&S). (Progressive titles changed deliberately later, with
    feature/progressive-aspect; tools/check_prog_aspect_wiring.py owns that.)
  * The gate wraps everything; the two enables are never both high. The gate is
    aa_live & ~sif_det_s2 since feature/progressive-aspect (docs/crt_anamorphic.md
    §13): the interlaced raster, or an explicit Letterbox/Crop on Progressive; never
    SIF-height content. On the interlaced raster that is the old
    interlaced_eff & ~p240_eff exactly. The swap applies wherever the gate does
    (user decision 2026-10-04: on Progressive too).

Seams checked as well, because "everything downstream follows" is the claim that
made the feature small: the reader port is connected, disp_vscale_en /
disp_hcrop_en ARE the two enables, VIDEO_ARX/ARY and the overlay inverse
(ov_hcrop_mb, crt_ov_map's letterbox_en/crop_en) read them.

Traps written against: strip_comments() FIRST (the comment block above the
resolve quotes the old two-line assigns); a definition that is missing or appears
twice is a NAMED FAIL; an identifier the evaluator cannot resolve is a NAMED FAIL,
never treated as 0.

Exit 0 = wired as designed; 1 = a named failure. Optional argv[1] = a file to check
instead of dvd/emu.sv, so a runner can mutate a copy in $TMP and never touch the tree.
"""
import itertools
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The free inputs of the resolve, with their widths. Anything else in the closure
# must have exactly one comb definition in emu.sv.
FREE = {
    'interlaced_eff': 1, 'sif_det_s2': 1, 'aa_osd_sel': 2,
    'menus_on': 1, 'menu_active': 1, 'menu_ar_wide_w': 1,
    'menu_ar_df_w': 2, 'ar_wide_auto': 1,
}


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


def definitions(src, name):
    """Every RHS of `assign name = ...;` or `wire [..] name = ...;`."""
    pats = [r'\bassign\s+' + re.escape(name) + r'\s*=\s*([^;]*);',
            r'\bwire\s*(?:\[[^\]]*\]\s*)?' + re.escape(name) + r'\s*=\s*([^;]*);']
    out = []
    for p in pats:
        out += [re.sub(r'\s+', ' ', m.group(1)).strip() for m in re.finditer(p, src)]
    return out


# ---- a tiny Verilog expression evaluator ------------------------------------
# Grammar (precedence low -> high): ?: , ||, &&, |, ^, &, == !=, unary ~ !, atoms.
TOK = re.compile(r"\s*(\d+'[bdhBDH][0-9a-fA-F_]+|\d+|[A-Za-z_][A-Za-z0-9_]*|==|!=|&&|\|\||[~!&|^?:()])")


class Expr:
    def __init__(self, text):
        self.toks, pos = [], 0
        text = text.strip()
        while pos < len(text):
            m = TOK.match(text, pos)
            if not m:
                raise ValueError(f'cannot tokenise at `{text[pos:]}`')
            self.toks.append(m.group(1))
            pos = m.end()
        self.i = 0
        self.tree = self.ternary()
        if self.i != len(self.toks):
            raise ValueError(f'trailing tokens {self.toks[self.i:]}')

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else None

    def take(self, want=None):
        t = self.peek()
        if want is not None and t != want:
            raise ValueError(f'expected {want}, got {t}')
        self.i += 1
        return t

    def ternary(self):
        c = self.binop(0)
        if self.peek() == '?':
            self.take('?')
            a = self.ternary()
            self.take(':')
            b = self.ternary()
            return ('?', c, a, b)
        return c

    LEVELS = [['||'], ['&&'], ['|'], ['^'], ['&'], ['==', '!=']]

    def binop(self, lvl):
        if lvl == len(self.LEVELS):
            return self.unary()
        lhs = self.binop(lvl + 1)
        while self.peek() in self.LEVELS[lvl]:
            op = self.take()
            lhs = (op, lhs, self.binop(lvl + 1))
        return lhs

    def unary(self):
        t = self.peek()
        if t in ('~', '!'):
            self.take()
            return (t, self.unary())
        if t == '(':
            self.take('(')
            e = self.ternary()
            self.take(')')
            return e
        self.take()
        m = re.match(r"(\d+)'([bdhBDH])([0-9a-fA-F_]+)$", t)
        if m:
            base = {'b': 2, 'd': 10, 'h': 16}[m.group(2).lower()]
            return ('num', int(m.group(3).replace('_', ''), base), int(m.group(1)))
        if t.isdigit():
            return ('num', int(t), 32)
        return ('id', t)


class Resolver:
    def __init__(self, src):
        self.src, self.trees, self.fails = src, {}, []

    def tree(self, name):
        if name not in self.trees:
            d = definitions(self.src, name)
            if len(d) != 1:
                raise LookupError(f'{name}: expected exactly one comb definition, found {len(d)}')
            self.trees[name] = Expr(d[0]).tree
        return self.trees[name]

    def ev(self, node, env):
        """-> (value, width)"""
        k = node[0]
        if k == 'num':
            return node[1] & ((1 << node[2]) - 1), node[2]
        if k == 'id':
            n = node[1]
            if n in FREE:
                return env[n], FREE[n]
            return self.ev(self.tree(n), env)
        if k == '?':
            c, _ = self.ev(node[1], env)
            a, wa = self.ev(node[2], env)
            b, wb = self.ev(node[3], env)
            return (a if c else b), max(wa, wb)
        if k == '~':
            v, w = self.ev(node[1], env)
            return (~v) & ((1 << w) - 1), w
        if k == '!':
            v, _ = self.ev(node[1], env)
            return int(v == 0), 1
        a, wa = self.ev(node[1], env)
        b, wb = self.ev(node[2], env)
        w = max(wa, wb)
        if k == '&':  return a & b, w
        if k == '|':  return a | b, w
        if k == '^':  return a ^ b, w
        if k == '&&': return int(bool(a) and bool(b)), 1
        if k == '||': return int(bool(a) or bool(b)), 1
        if k == '==': return int(a == b), 1
        if k == '!=': return int(a != b), 1
        raise ValueError(f'unknown node {k}')


def model(e):
    """The reference: what a 4:3 set-top player does with a menu's permitted_df."""
    menu_ctx = e['menus_on'] and e['menu_active']
    wide_eff = e['menu_ar_wide_w'] if menu_ctx else e['ar_wide_auto']
    sel = e['aa_osd_sel']
    want_lb = sel == 2 or (sel == 0 and wide_eff)
    want_crop = sel == 3
    menu169 = menu_ctx and e['menu_ar_wide_w']
    if menu169 and e['menu_ar_df_w'] == 1 and want_lb:      # letterbox denied
        lb, crop = False, True
    elif menu169 and e['menu_ar_df_w'] == 2 and want_crop:  # pan&scan denied
        lb, crop = True, False
    else:
        lb, crop = want_lb, want_crop
    gate = (e['interlaced_eff'] or sel in (2, 3)) and not e['sif_det_s2']
    return int(lb and gate), int(crop and gate)


def pre_feature(e):
    """The v0.8.0 resolve, verbatim -- interlaced titles must still match it exactly.
    (p240_eff = interlaced_eff & sif_det_s2, emu.sv.)"""
    menu_ctx = e['menus_on'] and e['menu_active']
    wide_eff = e['menu_ar_wide_w'] if menu_ctx else e['ar_wide_auto']
    p240 = e['interlaced_eff'] and e['sif_det_s2']
    gate = e['interlaced_eff'] and not p240
    sel = e['aa_osd_sel']
    return int(gate and (sel == 2 or (sel == 0 and wide_eff))), int(gate and sel == 3)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'dvd', 'emu.sv')
    src = strip_comments(open(path).read())
    fails = []

    # 1. the reader port reaches the resolve's input
    conns = re.findall(r'\.menu_ar_df\s*\(\s*([^)]*?)\s*\)', src)
    if conns != ['menu_ar_df_w']:
        fails.append(f'dvd_iso_reader .menu_ar_df must connect to menu_ar_df_w exactly once; '
                     f'found {conns} -- the override reads a floating flag')

    # 2. the resolve, evaluated over the whole input space
    r = Resolver(src)
    names = sorted(FREE)
    widths = [range(1 << FREE[n]) for n in names]
    bad, bad_title, both, points = [], [], 0, 0
    try:
        for vals in itertools.product(*widths):
            e = dict(zip(names, vals))
            got = (r.ev(('id', 'analog_letterbox'), e)[0], r.ev(('id', 'analog_crop'), e)[0])
            points += 1
            if got[0] and got[1]:
                both += 1
            if got != model(e):
                bad.append((e, got, model(e)))
            if e['interlaced_eff'] and not e['menu_active'] and got != pre_feature(e):
                bad_title.append((e, got, pre_feature(e)))
    except (LookupError, ValueError, KeyError) as ex:
        fails.append(f'cannot evaluate the resolve: {ex}')
    else:
        if bad:
            e, got, want = bad[0]
            fails.append(f'resolve disagrees with the model at {len(bad)}/{points} points; first: '
                         f'{e} -> (lb,crop)={got}, want {want}')
        if bad_title:
            e, got, want = bad_title[0]
            fails.append(f'interlaced TITLE resolve changed at {len(bad_title)} points (menus only, by '
                         f'user decision); first: {e} -> {got}, v0.8.0 gave {want}')
        if both:
            fails.append(f'analog_letterbox and analog_crop both high at {both} points')

    # 3. the downstream seams that make the feature "free"
    def one(name):
        d = definitions(src, name)
        if len(d) != 1:
            fails.append(f'{name}: expected exactly one definition, found {len(d)}')
            return None
        return d[0]

    # Standard Convert (docs/standard_convert.md) ORs its analog path into the vertical scale;
    # the Letterbox term must still be the override-resolved analog_letterbox and nothing else.
    for name, wants in (('disp_vscale_en', ('analog_letterbox', 'analog_letterbox | std_conv_an')),
                        ('disp_hcrop_en', ('analog_crop',))):
        d = one(name)
        if d is not None and d not in wants:
            fails.append(f'{name} = `{d}`, want one of {wants} -- the decoder would not follow the override')
    for name in ('VIDEO_ARX', 'VIDEO_ARY'):
        d = one(name)
        if d is not None and not {'analog_letterbox', 'analog_crop'} <= set(re.findall(r'\w+', d)):
            fails.append(f'{name} no longer reads both enables -- a menu<->title swap between '
                         f'Letterbox and Crop would re-init the scaler: `{d}`')
    d = one('ov_hcrop_mb')
    if d is not None and 'analog_crop' not in re.findall(r'\w+', d):
        fails.append(f'ov_hcrop_mb does not follow analog_crop -- the highlight would miss '
                     f'the cropped buttons: `{d}`')
    # .letterbox_en may read disp_vscale_en, which is itself held to analog_letterbox above.
    for port, ens in (('letterbox_en', ('analog_letterbox', 'disp_vscale_en')), ('crop_en', ('analog_crop',))):
        c = re.findall(r'\.' + port + r'\s*\(([^;]*?)\)\s*,', src)
        if len(c) != 1 or not set(ens) & set(re.findall(r'\w+', c[0])):
            fails.append(f'crt_ov_map .{port} must read one of {ens}; found {c}')

    if fails:
        for f in fails:
            print(f'FAIL: {f}')
        return 1
    print(f'OK: menu permitted_df overrides Letterbox/Crop as modelled over {points} points; '
          f'titles unchanged; decoder, ARX/ARY and overlay inverse follow')
    return 0


if __name__ == '__main__':
    sys.exit(main())
