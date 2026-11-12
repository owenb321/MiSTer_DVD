#!/usr/bin/env python3
"""Gate for the subpicture overlay CONTEXT (docs/crt_anamorphic.md §9a, §9c).

WHY THIS EXISTS
---------------
Under the analog Letterbox/Crop modes the overlay query is either RAW (1:1 raster
coordinates) or MAPPED (crt_ov_map's inverse of the picture's scale). emu.sv picks
one per frame (sp_ctx_mapped_w), and emu.sv has no bench, so this reads the select
out of the file:

  1. sp_user_path is the complement of sp_track_eff's select -- the SAME set of
     terms, and the select's true arm is the disc-chosen sp_phys_streamN -- so
     "the user's own stream is displayed" cannot drift from the mux that decides it.
  2. sp_ctx_mapped_w carries an armed HLI ONLY over disc-chosen art
     (hl_btns_armed & ~sp_user_path), never bare. The Matrix arms its white-rabbit
     HLI through the feature; a bare term flipped English chosen with the Subtitle
     button to the mapped space at every rabbit window (2026-11-11).
  3. ...and keeps every disc-chosen context mapped: menu domain, sp_menu_early,
     vm_owns_route, force_43_subp.

and the claim that decides vm_owns_route in the first place:

  4. The user's Subtitle choice written back to SPRM2 (spst_wb) must not re-claim the
     stream for the VM: vm_owns_sp feeds vm_owns_route, a mapped context term. From
     v0.10.0 until 2026-11-11 it did, one cycle after every Subtitle press, so a
     button-chosen subtitle drew mapped (3/4 tall under Letterbox, 1.36x wide under Crop).

    python3 tools/check_subp_ctx_wiring.py [emu.sv]    # exit 0 = wired right
    git show main:dvd/emu.sv > old.sv && \\
        python3 tools/check_subp_ctx_wiring.py old.sv    # pre-fix: must exit 1 (1, 2, 4)

Comments are stripped first: emu.sv quotes old code in its comments.
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


def tokens(expr):
    return set(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", expr or '')) - {'d0', 'b0', 'b1'}


def or_terms(expr):
    """Top-level | terms of a squashed expression (parentheses respected)."""
    terms, depth, cur = [], 0, ''
    for ch in expr:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == '|' and depth == 0:
            terms.append(cur)
            cur = ''
        else:
            cur += ch
    terms.append(cur)
    return [t for t in terms if t]


def unparen(t):
    while t.startswith('(') and t.endswith(')'):
        depth = 0
        for i, ch in enumerate(t):
            depth += ch == '('
            depth -= ch == ')'
            if depth == 0 and i != len(t) - 1:
                return t
        t = t[1:-1]
    return t


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, '..', 'dvd', 'emu.sv')
    src = strip_comments(open(path).read())
    bad = []

    def need(ok, msg):
        if not ok:
            bad.append(msg)

    # 1. sp_user_path == ~(select of sp_track_eff)
    te = stmt(src, r'sp_track_eff')
    up = stmt(src, r'sp_user_path')
    need(te is not None, '1. sp_track_eff not found')
    need(up is not None, '1. sp_user_path not found')
    if te and up:
        m = re.match(r'^(.*)\?sp_phys_streamN:sp_user_log$', te)
        need(m is not None, '1. sp_track_eff is not <select> ? sp_phys_streamN : sp_user_log: %s' % te)
        need(up.startswith('~('), '1. sp_user_path is not ~(...): %s' % up)
        if m and up.startswith('~('):
            sel = set(unparen(t) for t in or_terms(unparen(m.group(1))))
            neg = set(unparen(t) for t in or_terms(unparen(up[1:])))
            need(sel == neg, '1. sp_user_path terms %s != sp_track_eff select %s'
                 % (sorted(neg), sorted(sel)))

    # 2/3. the context select
    cm = stmt(src, r'sp_ctx_mapped_w')
    need(cm is not None, '2. sp_ctx_mapped_w not found')
    if cm:
        terms = [unparen(t) for t in or_terms(cm)]
        need('hl_btns_armed' not in terms,
             '2. sp_ctx_mapped_w maps on a BARE hl_btns_armed (the user\'s stream goes mapped under an HLI)')
        need(any(t in ('hl_btns_armed&~sp_user_path', '~sp_user_path&hl_btns_armed') for t in terms),
             '2. sp_ctx_mapped_w lacks (hl_btns_armed & ~sp_user_path): %s' % cm)
        for want in ('menus_on&&menu_active', 'sp_menu_early', 'vm_owns_route', 'force_43_subp'):
            need(want in terms, '3. sp_ctx_mapped_w lost the disc-chosen context %s' % want)

    # 4. the Subtitle write-back must not re-claim the stream for the VM
    claim = re.search(r'if\s*\(([^;]*?vm_spstn\s*!=\s*vm_spstn_p[^;]*?)\)\s*vm_owns_sp\s*<=\s*1\'b1', src)
    need(claim is not None, '4. the vm_owns_sp claim (vm_spstn != vm_spstn_p ... vm_owns_sp <= 1) not found')
    if claim:
        need('!spst_wb_landing' in squash(claim.group(1)),
             '4. the vm_owns_sp claim must exclude !spst_wb_landing (our own SPRM2 write-back '
             're-claimed the stream: the user\'s subtitle drew MAPPED, v0.10.0): %s' % squash(claim.group(1)))
    wl = stmt(src, r'spst_wb_landing')
    need(wl is not None and tokens(wl) == {'spst_wb', 'spst_wb_mask', 'vm_spstn', 'spst_wb_val'}
         and 'vm_spstn==spst_wb_val' in wl,
         '4. spst_wb_landing must be (spst_wb | spst_wb_mask) && (vm_spstn == spst_wb_val): %s' % wl)
    need(re.search(r'if\s*\(\s*spst_wb\s*\)\s*spst_wb_mask\s*<=\s*1\'b1', src) is not None,
         '4. spst_wb_mask must be set by spst_wb')

    if bad:
        print('check_subp_ctx_wiring: FAIL (%s)' % path)
        for b in bad:
            print('  ' + b)
        return 1
    print('check_subp_ctx_wiring: PASS (overlay context: the user\'s stream stays raw under an HLI)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
