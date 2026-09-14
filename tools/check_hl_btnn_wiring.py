#!/usr/bin/env python3
"""Gate for the link-button-across-a-flush fix (Scooby-Doo 2 Wickles Manor grid,
2026-09-14): check that emu.sv actually hands the VM's HL_BTNN to nav_pci.

WHY THIS EXISTS
---------------
The defect lived at a SEAM: `dvd_vm` pulses `btn_force` with a link's button
field (`LinkCN 26 (button 16)`) in the same cycle as the seek that link fires;
the seek's load_flush then resets `nav_pci` (it sits on pipe_rst_n) and the
stored button went back to 1. The fix is one new wire: `dvd_vm.hl_btnn` (the
SPRM8 button, on the hard reset) -> `nav_pci.hl_btnn`, from which nav_pci
re-seeds its selection when the reset releases.

Each module's own bench proves its half (`dvd_vm_tb` T6, `nav_pci_tb` T19), and
each is handed the other side's value as a plusarg-style input -- so a wrong or
missing connection in emu.sv is invisible to both, and there is no emu-level
bench. Same shape as issue #81 (`tools/check_subp_map_wiring.py`): a correct
value on the wrong port, which no module bench can see. This reads the
connection out of `dvd/emu.sv` instead of restating it.

What is checked:
  * the `dvd_vm` instantiation connects `.hl_btnn` to a NET (not a constant,
    not left unconnected);
  * the `nav_pci` instantiation connects `.hl_btnn` to the SAME net;
  * that net is declared 6 bits wide.

RED on the pre-fix file (neither port exists) and on the plausible
re-regressions: `.hl_btnn (6'd0)` on nav_pci (compiles, silently restores the
bug), the two ports on different nets, or the nav_pci port dropped after a
"tidy" of the instantiation.

    python3 tools/check_hl_btnn_wiring.py [emu.sv]     # exit 0 = wired right

⚠ Walks to the instantiation's matching ')' and strips comments -- do NOT
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
    m = re.search(r'\.' + re.escape(port) + r'\s*\(\s*([^()]*?)\s*\)', body)
    return None if not m else m.group(1).strip()


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), '..', 'dvd', 'emu.sv')
    src = strip_comments(open(path).read())
    bad = []

    vm = instantiation_body(src, 'dvd_vm')
    nav = instantiation_body(src, 'nav_pci')
    if vm is None:
        bad.append('no dvd_vm instantiation found')
    if nav is None:
        bad.append('no nav_pci instantiation found')
    if bad:
        print('\n'.join('FAIL: ' + b for b in bad))
        return 1

    vm_net = port_net(vm, 'hl_btnn')
    nav_net = port_net(nav, 'hl_btnn')
    if vm_net is None:
        bad.append("dvd_vm has no .hl_btnn connection (the VM's SPRM8 button is not exported)")
    if nav_net is None:
        bad.append('nav_pci has no .hl_btnn connection (the selection is never re-seeded after a flush)')
    ident = re.compile(r'^[A-Za-z_]\w*$')
    for who, net in (('dvd_vm', vm_net), ('nav_pci', nav_net)):
        if net is not None and not ident.match(net):
            bad.append("%s .hl_btnn is '%s' -- must be a plain net, not a constant or expression" % (who, net))
    if vm_net and nav_net and ident.match(vm_net) and ident.match(nav_net) and vm_net != nav_net:
        bad.append("dvd_vm .hl_btnn (%s) and nav_pci .hl_btnn (%s) are different nets" % (vm_net, nav_net))
    if vm_net and ident.match(vm_net):
        decl = re.search(r'(?m)^\s*wire\s*\[\s*5\s*:\s*0\s*\]\s*' + re.escape(vm_net) + r'\b', src)
        if not decl:
            bad.append("net '%s' is not declared as wire [5:0]" % vm_net)

    if bad:
        print('\n'.join('FAIL: ' + b for b in bad))
        return 1
    print('OK: dvd_vm .hl_btnn -> %s -> nav_pci .hl_btnn (wire [5:0])' % vm_net)
    return 0


if __name__ == '__main__':
    sys.exit(main())
