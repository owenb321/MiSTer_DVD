#!/usr/bin/env python3
"""Gate for the disc-selected camera angle (Castle in the Sky, 2026-09-15):
check that emu.sv actually carries the VM's SPRM3/AGLN to the reader, and the
user's B6 press back to the VM.

WHY THIS EXISTS
---------------
`dvd_vm` has latched SPRM3 from `SetSTN` since Phase 4 -- and exported only
SPRM1 (`sprm_astn`) and SPRM2 (`sprm_spstn`), so the angle was written and then
DEAD. The reader's `cur_angle` was fed by the B6 button alone, so a disc that
picks its own angle was ignored and angle 1 always played. MEASURED on
CASTLE_IN_THE_SKY: the boot chain sets `g[14] = 2` and the feature PGC's PRE
runs `SetSTN ASTN=g[12] SPSTN=g[13] AGLN=g[14]` -- the disc asks for angle 2
(the English title cards; angle 1 is the Japanese ones).

Both halves are module-provable (`dvd_vm_tb` for the export and the write-back,
the reader benches for the consumption), and each module bench is handed the
other side's value directly -- so a wrong or missing connection in `emu.sv` is
invisible to both, and there is no emu-level bench. That is the issue #81
lesson in one sentence: a single port connection carrying the wrong FACT is
invisible to every module-level test. Same pattern as
`tools/check_subp_map_wiring.py`, `check_hl_btnn_wiring.py`,
`check_p240_wiring.py` -- read the connection out of the file instead of
restating it, because a table that cannot go stale beats a correct one.

What is checked:
  * `dvd_vm` exports `.sprm_agln` and `.pre_done` to plain nets;
  * `dvd_iso_reader` takes `.agl_vm` from the SAME net as `.sprm_agln`
    (a part-select of it is fine -- SPRM3 is 8 bits, the angle is 4);
  * `dvd_iso_reader` takes `.vm_pre_done` from the SAME net as `.pre_done`;
  * `.agl_vm_en` is a plain net, NOT a constant -- tying it to 1'b0 compiles
    and silently restores the whole defect, and tying it to 1'b1 would let a
    disc that never issues SetSTN AGLN pin the angle and make B6 look dead;
  * the write-back exists: `dvd_vm.agl_set` on a plain net.

    python3 tools/check_angle_wiring.py [emu.sv]      # exit 0 = wired right

RED on the pre-fix file (none of the ports exist) and on the plausible
re-regressions: `.agl_vm_en(1'b0)`, `.agl_vm` fed from something other than the
VM's export, `.vm_pre_done(1'b1)` (which reintroduces the ordering defect the
wait exists to fix), or the write-back dropped in a tidy-up.

WARNING Walks to the instantiation's matching ')' and strips comments -- do NOT
"simplify" it to a grep. emu.sv carries commented-out history (the CONF_STR
lesson in CLAUDE.md), and a loose grep finds connections that are not
connections.
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
    """Return the text between the '(' after `module <inst_name>` and its
    matching ')', or None if the module is not instantiated."""
    m = re.search(r'(?m)^\s*' + re.escape(module) + r'\s+(#\s*\(.*?\)\s*)?\w+\s*\(', src, re.S)
    if not m:
        return None
    i = m.end() - 1          # at the '('
    depth = 0
    j = i
    while j < len(src):
        if src[j] == '(':
            depth += 1
        elif src[j] == ')':
            depth -= 1
            if depth == 0:
                return src[i + 1:j]
        j += 1
    return None


def port_net(body, port):
    """The expression connected to `port`, or None. Allows one level of
    brackets so a part-select like vm_agln[3:0] is returned intact."""
    m = re.search(r'\.' + re.escape(port) + r'\s*\(\s*((?:[^()\[\]]|\[[^\]]*\])*?)\s*\)', body)
    return None if not m else m.group(1).strip()


IDENT = re.compile(r'^[A-Za-z_]\w*$')
IDENT_SEL = re.compile(r'^([A-Za-z_]\w*)\s*(\[[^\]]*\])?$')


def base_net(expr):
    """'vm_agln[3:0]' -> 'vm_agln'; a constant or expression -> None."""
    if expr is None:
        return None
    m = IDENT_SEL.match(expr)
    return m.group(1) if m else None


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), '..', 'dvd', 'emu.sv')
    src = strip_comments(open(path).read())
    bad = []

    vm = instantiation_body(src, 'dvd_vm')
    rd = instantiation_body(src, 'dvd_iso_reader')
    if vm is None:
        bad.append('no dvd_vm instantiation found')
    if rd is None:
        bad.append('no dvd_iso_reader instantiation found')
    if bad:
        print('\n'.join('FAIL: ' + b for b in bad))
        return 1

    agln_out = port_net(vm, 'sprm_agln')
    pre_out = port_net(vm, 'pre_done')
    agl_in = port_net(rd, 'agl_vm')
    en_in = port_net(rd, 'agl_vm_en')
    pre_in = port_net(rd, 'vm_pre_done')
    wb = port_net(vm, 'agl_set')

    if agln_out is None:
        bad.append("dvd_vm has no .sprm_agln connection -- SPRM3 is written and then dead, "
                   "so the disc's own angle choice never reaches the reader")
    if agl_in is None:
        bad.append('dvd_iso_reader has no .agl_vm connection')
    if en_in is None:
        bad.append('dvd_iso_reader has no .agl_vm_en connection')
    if pre_out is None:
        bad.append('dvd_vm has no .pre_done connection')
    if pre_in is None:
        bad.append('dvd_iso_reader has no .vm_pre_done connection')
    if wb is None:
        bad.append("dvd_vm has no .agl_set connection -- a B6 press would not write SPRM3 back, "
                   "and a disc that reads AGLN would re-apply a stale angle")

    for who, port, net in (('dvd_vm', 'sprm_agln', agln_out),
                           ('dvd_vm', 'pre_done', pre_out),
                           ('dvd_vm', 'agl_set', wb),
                           ('dvd_iso_reader', 'agl_vm_en', en_in),
                           ('dvd_iso_reader', 'vm_pre_done', pre_in)):
        if net is not None and not IDENT.match(net):
            bad.append("%s .%s is '%s' -- must be a plain net, not a constant or expression "
                       "(a constant here compiles and silently changes the behaviour)"
                       % (who, port, net))

    if agln_out and agl_in and IDENT.match(agln_out):
        if base_net(agl_in) != agln_out:
            bad.append("dvd_iso_reader .agl_vm is fed from '%s', not from the VM's .sprm_agln "
                       "net '%s'" % (agl_in, agln_out))
    if pre_out and pre_in and IDENT.match(pre_out) and IDENT.match(pre_in):
        if pre_in != pre_out:
            bad.append("dvd_iso_reader .vm_pre_done ('%s') and dvd_vm .pre_done ('%s') are "
                       "different nets" % (pre_in, pre_out))

    if bad:
        print('\n'.join('FAIL: ' + b for b in bad))
        return 1
    print('OK: dvd_vm .sprm_agln -> %s -> dvd_iso_reader .agl_vm (enabled by %s)'
          % (agln_out, en_in))
    print('OK: dvd_vm .pre_done -> %s -> dvd_iso_reader .vm_pre_done' % pre_out)
    print('OK: B6 write-back dvd_vm .agl_set <- %s' % wb)
    return 0


if __name__ == '__main__':
    sys.exit(main())
