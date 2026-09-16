#!/usr/bin/env python3
"""Gate for the menu-hop zero-stuffer's seam in dvd/emu.sv (docs/quant_matrix.md 13q).

dvd/es_stuff.sv is correct on its own bench for whatever it is handed. What no
module bench can see is the SEAM: whether emu actually routes ps_demux's video
output THROUGH it into vidfeed_cdc, and arms it from the keep_vbuf hop's ack.
A bypass -- ps_demux.vid_ready wired straight to the CDC again, or the shim
armed from a constant -- leaves a correct module doing nothing, which is the
issue #81 / tools/check_subp_map_wiring.py shape. This reads the connections
out of emu.sv instead of restating them, so it cannot go stale.

What is checked:
  * es_stuff is instantiated with .arm(aud_drop_pulse) -- the keep_vbuf hop's
    ack, the ONE junction with no VBUF flush -- and .pipe_rst_n(pipe_rst_n);
  * ps_demux's .vid_ready is the shim's .in_ready net, not vidfeed_wr_ready;
  * the shim's .in_byte/.in_mark/.in_valid are ps_demux's .vid_byte/.vid_mark/
    .vid_valid nets;
  * vidfeed_cdc's .wr_data/.wr_valid are the shim's .out_data/.out_valid nets,
    and its .wr_ready is the shim's .out_ready net;
  * the shim's reset is NOT pipe_rst_n (it must survive the reset it keys on).

RED on any of those.  python3 tools/check_es_stuff_wiring.py [emu.sv]

Walks to each instantiation's matching ')' and strips comments -- do NOT
"simplify" it to a grep: emu.sv carries commented-out history and the comment
block above the instance names every one of these nets.
"""
import os
import re
import sys


def strip_comments(src):
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
    m = re.search(r'(?m)^\s*' + re.escape(module) + r'\s+(#\s*\(.*?\)\s*)?\w+\s*\(',
                  src, re.S)
    if not m:
        return None
    i = m.end() - 1
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
    ident = re.compile(r'^[A-Za-z_]\w*$')

    sh = instantiation_body(src, 'es_stuff')
    pd = instantiation_body(src, 'ps_demux')
    vc = instantiation_body(src, 'vidfeed_cdc')
    if sh is None:
        bad.append("es_stuff is not instantiated in emu.sv")
    if pd is None:
        bad.append("ps_demux instantiation not found")
    if vc is None:
        bad.append("vidfeed_cdc instantiation not found")
    if bad:
        for b in bad:
            print("  RED:", b)
        return 1

    def net(body, port, who):
        v = port_net(body, port)
        if v is None or not ident.match(v):
            bad.append(f"{who}.{port} is '{v}' -- must be a plain net")
        return v

    arm = net(sh, 'arm', 'es_stuff')
    if arm != 'aud_drop_pulse':
        bad.append(f"es_stuff.arm is '{arm}', must be aud_drop_pulse (the keep_vbuf hop's ack)")
    prn = net(sh, 'pipe_rst_n', 'es_stuff')
    if prn != 'pipe_rst_n':
        bad.append(f"es_stuff.pipe_rst_n is '{prn}', must be pipe_rst_n")
    rst = net(sh, 'rst_n', 'es_stuff')
    if rst == 'pipe_rst_n':
        bad.append("es_stuff.rst_n is pipe_rst_n -- it must survive the reset it keys on")

    # demux -> shim
    for dp, sp in (('vid_byte', 'in_byte'), ('vid_mark', 'in_mark'),
                   ('vid_valid', 'in_valid'), ('vid_ready', 'in_ready')):
        a = net(pd, dp, 'ps_demux')
        b = net(sh, sp, 'es_stuff')
        if a is not None and b is not None and a != b:
            bad.append(f"ps_demux.{dp} ('{a}') != es_stuff.{sp} ('{b}') -- the shim is bypassed")
    # shim -> CDC
    for sp, cp in (('out_data', 'wr_data'), ('out_valid', 'wr_valid'),
                   ('out_ready', 'wr_ready')):
        a = net(sh, sp, 'es_stuff')
        b = net(vc, cp, 'vidfeed_cdc')
        if a is not None and b is not None and a != b:
            bad.append(f"es_stuff.{sp} ('{a}') != vidfeed_cdc.{cp} ('{b}') -- the shim is bypassed")

    if bad:
        for b in bad:
            print("  RED:", b)
        return 1
    print("  es_stuff wiring: OK (ps_demux -> es_stuff -> vidfeed_cdc, armed by aud_drop_pulse)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
