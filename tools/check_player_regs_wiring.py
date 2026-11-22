#!/usr/bin/env python3
"""Gate for the player parameters SPRM14/15/20 (feature/player-regs,
docs/dvd_vm.md "Player parameters SPRM14/15/20"): check that emu.sv feeds
dvd/player_regs.sv from the right signals and hands its outputs to dvd_vm.

WHY THIS EXISTS
---------------
`player_regs_tb` proves the mapping, `dvd_vm_tb` [S26] proves the VM reads its
cfg ports, and `iso_reader_vm_tb` T1/T10 proves the reader's region mask is the
disc's before First Play runs. Each is HANDED its inputs, so a wrong wire in
emu.sv -- which has no bench -- is invisible to all three. The plausible ones:

  * `.aa_sel (status[4:3])`: compiles and looks right, but ignores the B15
    Aspect button (the same trap the subpicture display mode fell into);
  * `.aa_live` on a different gate from the Letterbox/Crop one: SPRM14 would
    tell the disc "4:3 letterbox" while the raster shows Fit, or the reverse;
  * `.dts_ok (1'b1)`: a Decode-mode player without its DTS codebooks would
    claim DTS, and a disc would pick a track the core then mutes;
  * the reader's mask left unconnected, or the VM still tied to constants;
  * the all-prohibited flag dropped from telemetry (the "never silent" rule).

What is checked:
  * dvd_iso_reader .vmg_rmask and player_regs .rmask are the SAME net, wire [7:0];
  * player_regs .aa_sel is aa_osd_sel;
  * player_regs .aa_live is a plain net that appears in BOTH the
    analog_letterbox and analog_crop assigns (the Letterbox/Crop gate);
  * .pass_mode is pass_dts = pass_sel & ~hdmi_no_dts (the Passthru selection, not
    Audio On/Off: issue #197; not when the HDMI sink lists AC-3 only: issue #201)
    and .dts_ok is cb_tables_ok;
  * player_regs .sprm14/.sprm15/.sprm20 and dvd_vm .cfg_sprm14/15/20 are the
    same three nets, each wire [15:0];
  * .rmask_all_prohibited is a net carried by dvd_telem's .sched_flags.

    python3 tools/check_player_regs_wiring.py [emu.sv]   # exit 0 = wired right
    python3 tools/check_player_regs_wiring.py --red      # each mutation must FAIL

⚠ Walks to each instantiation's matching ')' and strips comments -- do NOT
"simplify" it to a grep. emu.sv carries commented-out history, and the
comments beside these very ports quote the wrong wiring ("NOT status[4:3]").
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
            out.append(re.sub(r'[^\n]', ' ', src[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def instantiation_body(src, module):
    m = re.search(r'(?m)^\s*' + re.escape(module) + r'\s+(#\s*\(.*?\)\s*)?\w+\s*\(', src, re.S)
    if not m:
        return None
    i = m.end() - 1
    depth = 0
    for j in range(i, len(src)):
        if src[j] == '(':
            depth += 1
        elif src[j] == ')':
            depth -= 1
            if depth == 0:
                return src[i + 1:j]
    return None


def port_net(body, port):
    """The text inside .port( ... ), with nested parentheses balanced."""
    m = re.search(r'\.' + re.escape(port) + r'\s*\(', body)
    if not m:
        return None
    i = m.end()
    depth = 1
    for j in range(i, len(body)):
        if body[j] == '(':
            depth += 1
        elif body[j] == ')':
            depth -= 1
            if depth == 0:
                return body[i:j].strip()
    return None


def assign_rhs(src, name):
    m = re.search(r'\bassign\s+' + re.escape(name) + r'\s*=\s*(.*?);', src, re.S)
    return None if not m else m.group(1)


def wire_rhs(src, name):
    m = re.search(r'\bwire\s+' + re.escape(name) + r'\s*=\s*(.*?);', src, re.S)
    return None if not m else m.group(1)


def tokens(expr):
    return set(re.findall(r'[A-Za-z_]\w*', expr or ''))


IDENT = re.compile(r'^[A-Za-z_]\w*$')


def check(raw):
    src = strip_comments(raw)
    bad = []
    pr = instantiation_body(src, 'player_regs')
    rd = instantiation_body(src, 'dvd_iso_reader')
    vm = instantiation_body(src, 'dvd_vm')
    tl = instantiation_body(src, 'dvd_telem')
    for name, body in (('player_regs', pr), ('dvd_iso_reader', rd), ('dvd_vm', vm), ('dvd_telem', tl)):
        if body is None:
            bad.append('no %s instantiation found' % name)
    if bad:
        return bad

    def declared(net, width):
        return re.search(r'(?m)^\s*wire\s*\[\s*%d\s*:\s*0\s*\]\s*([\w\s,]*,\s*)?%s\b'
                         % (width - 1, re.escape(net)), src) is not None

    # region mask: reader -> player_regs
    rn, pn = port_net(rd, 'vmg_rmask'), port_net(pr, 'rmask')
    if not rn or not IDENT.match(rn):
        bad.append("dvd_iso_reader .vmg_rmask is '%s' -- must be a plain net" % rn)
    if not pn or not IDENT.match(pn):
        bad.append("player_regs .rmask is '%s' -- must be a plain net (the disc's mask)" % pn)
    if rn and pn and IDENT.match(rn) and IDENT.match(pn):
        if rn != pn:
            bad.append('reader .vmg_rmask (%s) and player_regs .rmask (%s) are different nets' % (rn, pn))
        elif not declared(rn, 8):
            bad.append("net '%s' is not declared as wire [7:0]" % rn)

    # SPRM14 inputs
    if port_net(pr, 'aa_sel') != 'aa_osd_sel':
        bad.append("player_regs .aa_sel is '%s' -- must be aa_osd_sel (the B15 Aspect "
                   "button overrides status[4:3])" % port_net(pr, 'aa_sel'))
    live = port_net(pr, 'aa_live')
    if not live or not IDENT.match(live):
        bad.append("player_regs .aa_live is '%s' -- must be a plain net" % live)
    else:
        for a in ('analog_letterbox', 'analog_crop'):
            rhs = assign_rhs(src, a)
            if rhs is None:
                bad.append('no assign for %s found' % a)
            elif live not in tokens(rhs):
                bad.append("player_regs .aa_live (%s) is not part of the %s gate -- SPRM14 "
                           "would describe a different display from the raster" % (live, a))

    # SPRM15 inputs
    # pass_dts = pass_sel & ~hdmi_no_dts: the Passthru SELECTION (not Audio On/Off,
    # issue #197), less the AC-3-only-sink case where aud_route decodes DTS (#201).
    if port_net(pr, 'pass_mode') != 'pass_dts':
        bad.append("player_regs .pass_mode is '%s' -- must be pass_dts (SPRM15 must not "
                   "follow Audio On/Off, issue #197, nor claim DTS passthrough to an "
                   "AC-3-only sink, issue #201)" % port_net(pr, 'pass_mode'))
    pd = wire_rhs(src, 'pass_dts')
    if pd is None or tokens(pd) != {'pass_sel', 'hdmi_no_dts'} or '~' not in pd:
        bad.append("pass_dts is '%s' -- must be pass_sel & ~hdmi_no_dts" % pd)
    if port_net(pr, 'dts_ok') != 'cb_tables_ok':
        bad.append("player_regs .dts_ok is '%s' -- must be cb_tables_ok (DTS decodes only "
                   "when its codebooks loaded)" % port_net(pr, 'dts_ok'))

    # outputs -> dvd_vm
    for n in ('14', '15', '20'):
        o, c = port_net(pr, 'sprm' + n), port_net(vm, 'cfg_sprm' + n)
        if not o or not IDENT.match(o):
            bad.append("player_regs .sprm%s is '%s' -- must be a plain net" % (n, o))
            continue
        if c != o:
            bad.append("dvd_vm .cfg_sprm%s is '%s', not player_regs' .sprm%s net (%s)" % (n, c, n, o))
        elif not declared(o, 16):
            bad.append("net '%s' is not declared as wire [15:0]" % o)

    # the all-prohibited fallback is visible
    ap = port_net(pr, 'rmask_all_prohibited')
    if not ap or not IDENT.match(ap):
        bad.append("player_regs .rmask_all_prohibited is '%s' -- must be a net, not left "
                   "open (the fallback must never be silent)" % ap)
    elif ap not in tokens(port_net(tl, 'sched_flags')):
        bad.append("dvd_telem .sched_flags does not carry %s (word 14 bit 9)" % ap)
    return bad


MUTATIONS = [
    ('aa_sel from status', r'\.aa_sel\s*\(\s*aa_osd_sel\s*\)', '.aa_sel (status[4:3])'),
    ('aa_live on another gate', r'\.aa_live\s*\(\s*aa_live\s*\)', '.aa_live (fields_eff)'),
    ('dts_ok tied high', r'\.dts_ok\s*\(\s*cb_tables_ok\s*\)', ".dts_ok (1'b1)"),
    ('pass_mode dropped', r'\.pass_mode\s*\(\s*pass_dts\s*\)\s*,', ".pass_mode (1'b0),"),
    ('SPRM15 follows Audio Off', r'\.pass_mode\s*\(\s*pass_dts\s*\)\s*,', ".pass_mode (pass_mode),"),
    ('SPRM15 ignores an AC-3-only sink', r'\.pass_mode\s*\(\s*pass_dts\s*\)\s*,', ".pass_mode (pass_sel),"),
    ('pass_dts not gated', r'(wire\s+pass_dts\s*=\s*)pass_sel\s*&\s*~hdmi_no_dts', r'\g<1>pass_sel'),
    ('reader mask open', r'\.vmg_rmask\s*\(\s*vmg_rmask_w\s*\)', '.vmg_rmask ()'),
    ('VM SPRM20 constant', r'\.cfg_sprm20\s*\(\s*pr_sprm20\s*\)', ".cfg_sprm20 (16'h0001)"),
    ('VM SPRM14/15 swapped', r'\.cfg_sprm14\s*\(\s*pr_sprm14\s*\)', '.cfg_sprm14 (pr_sprm15)'),
    # anchored on the net itself, not on word 14's zero pad (which shrinks as bits are
    # added -- the .BUP flags took bits 10-12 and broke a '{6'd0, ...' anchor)
    ('allp off telemetry', r'(\.sched_flags\s*\(\{[^}]*?)\bpr_rmask_allp\b', r"\g<1>1'b0"),
]


def main():
    args = [a for a in sys.argv[1:] if a != '--red']
    path = args[0] if args else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), '..', 'dvd', 'emu.sv')
    raw = open(path).read()
    if '--red' in sys.argv:
        rc = 0
        if check(raw):
            print('FAIL: the unmutated file does not pass')
            return 1
        for label, pat, rep in MUTATIONS:
            mut, n = re.subn(pat, rep, raw, count=1)
            if n == 0:
                print('FAIL %s: the mutation did not apply (anchor moved)' % label)
                rc = 1
                continue
            found = check(mut)
            if found:
                print('ok   %s -> %s' % (label, found[0]))
            else:
                print('FAIL %s: the mutant PASSED' % label)
                rc = 1
        return rc
    bad = check(raw)
    if bad:
        print('\n'.join('FAIL: ' + b for b in bad))
        return 1
    print('OK: reader .vmg_rmask -> player_regs (aa_osd_sel, Letterbox/Crop gate, pass_mode, '
          'cb_tables_ok) -> dvd_vm .cfg_sprm14/15/20; all-prohibited on telemetry')
    return 0


if __name__ == '__main__':
    sys.exit(main())
